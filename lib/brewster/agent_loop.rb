require "set"
require_relative "log"

module Brewster
  # Runs the agent conversation on the session's turn thread.
  #
  # M0/M2 concurrency findings (validated in the M0 spike, 2026-10-18):
  #
  # - WS IO stays on Falcon fibers. The agent turn (RubyLLM streaming via
  #   net/http + subprocess popen) runs on a dedicated plain Thread. Running
  #   chat.ask inside an async fiber starves the reactor and corrupts
  #   concurrent WS frame reads (observed in the spike before this design).
  # - RubyLLM 2.1.1 API (read from gem source + exercised in spike):
  #   * ask/complete/step all accept a streaming block receiving Chunk
  #     (use chunk.content; nil when the chunk carries no text).
  #   * with_instructions(text) REPLACES existing system messages by default
  #     (append: false), so a fresh prompt per turn is safe on one chat.
  #   * Tools declared with `requires_approval` pause the loop:
  #     complete?/waiting? drive the loop; awaiting_approval? +
  #     pending_approvals list calls; approve(tc)/deny(tc) record decisions;
  #     a second complete continues the turn. Denied calls get a structured
  #     denial result fed back to the model.
  #   * chat.cancel is a cross-thread flag; the in-flight turn raises
  #     RubyLLM::CancelledError at the next checkpoint.
  #   * before_tool_call fires at execution time (after approval), receiving
  #     the ToolCall; approval_request events are therefore emitted from this
  #     loop when awaiting_approval?, not from the callback.
  #   * after_tool_result receives only the result (no id); pair it with the
  #     id captured in before_tool_call (execution is sequential in the POC).
  #   * Denied calls never execute, so no callbacks run for them; this loop
  #     emits their tool_output itself when recording the denial.
  class AgentLoop
    def initialize(session, system_prompt:, chat_factory:, on_event:)
      @session = session
      @system_prompt = system_prompt
      @chat_factory = chat_factory
      @on_event = on_event
      @emitted_approvals = Set.new
      @current_tool_call_id = nil
    end

    def run(user_text)
      reason = "complete"
      chat = @chat_factory.call(@system_prompt)
      chat.before_tool_call do |tool_call|
        @current_tool_call_id = tool_call.id
        @on_event.call(:tool_call, id: tool_call.id, name: tool_call.name,
                                   args: tool_call.arguments)
      end
      chat.after_tool_result do |result|
        @on_event.call(:tool_output, id: @current_tool_call_id,
                                     output: result.is_a?(String) ? result : JSON.generate(result))
      end

      @on_event.call(:user_message, text: user_text)
      chat.ask(user_text) { |chunk| stream(chunk) }

      until chat.complete?
        if chat.awaiting_approval?
          chat.pending_approvals.each do |tc|
            next if @emitted_approvals.include?(tc.id)
            @emitted_approvals << tc.id
            @on_event.call(:approval_request, id: tc.id, name: tc.name, args: tc.arguments)
          end
          cmd = @session.commands.pop
          case cmd[:type]
          when "approve" then chat.approve(cmd[:tool_call_id])
          when "deny"
            chat.deny(cmd[:tool_call_id])
            @on_event.call(:tool_output, id: cmd[:tool_call_id],
                                         output: "user denied this tool call")
          when "cancel" then chat.cancel
          end
          chat.complete { |chunk| stream(chunk) }
        else
          chat.complete { |chunk| stream(chunk) }
        end
      end
      reason = "cancelled" if chat.respond_to?(:cancelled?) && chat.cancelled?
    rescue RubyLLM::CancelledError
      reason = "cancelled"
    rescue StandardError => e
      Log.exception("session=#{@session.id} turn_error", e)
      @on_event.call(:error, code: "turn_error", message: "#{e.class}: #{e.message}")
      reason = "error"
    ensure
      @on_event.call(:turn_done, reason: reason)
    end

    private

    def stream(chunk)
      @on_event.call(:text_delta, text: chunk.content) if chunk.content
    end
  end
end