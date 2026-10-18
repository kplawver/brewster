require "ruby_llm"
require_relative "event_log"
require_relative "bridge"
require_relative "log"
require_relative "agent_loop"
require_relative "tools"
require_relative "context/agents_md"
require_relative "testing"

module Brewster
  # One chat session: owns the EventLog, the Bridge, the command queue and
  # the turn thread. All event emission goes through #emit.
  class Session
    BASE_SYSTEM_PROMPT =
      "You are brewster, a careful coding assistant working in a local " \
      "repository. Prefer the provided tools over printing file contents " \
      "from memory. Never run destructive shell commands without asking."

    attr_reader :id, :log, :bridge, :commands, :turn_thread
    attr_reader :state

    # Optional in-process sink for turn events (tests embed their collector
    # here; the WS path consumes the log/bridge instead).
    attr_accessor :event_listener

    def initialize(id: SecureRandom.hex(8), log: nil, bridge: Bridge.new,
                   chat_factory: method(:default_chat_factory))
      @id = id
      @log = log || EventLog.new(File.join(Config.sessions_dir, "#{id}.jsonl"))
      @bridge = bridge
      @commands = ::Queue.new
      @chat_factory = chat_factory
      @state = :idle
      @mutex = Mutex.new
    end

    # state: :idle | :running | :awaiting_approval (mutex-guarded)
    def state
      @mutex.synchronize { @state }
    end

    def emit(type, **payload)
      seq = @log.append(type, session_id: @id, **payload)
      @bridge.write(@log.last_line)
      log_event(type, payload)
      seq
    end

    def push_command(cmd)
      @commands << cmd
    end

    # Spawns the turn thread; returns false when a turn is already running.
    # AGENTS.md is rebuilt every turn so edits apply on the next turn.
    def start_turn(text)
      return false unless @mutex.synchronize do
        if @state == :idle
          @state = :running
          true
        end
      end

      prompt = AgentsMd.build(Dir.pwd) + "\n\n---\n\n" + BASE_SYSTEM_PROMPT
      loop = AgentLoop.new(self, system_prompt: prompt,
                                chat_factory: @chat_factory,
                                on_event: method(:turn_event))
      Log.info("session=#{@id} turn=start chars=#{text.length} model=#{model}")
      @turn_thread = Thread.new do
        Thread.current.report_on_exception = false
        loop.run(text)
      end
      true
    end

    # Cross-thread cancel: chat flag + kill every running subprocess group.
    def cancel
      Log.info("session=#{@id} turn=cancel")
      Permissions.kill_all!
      @turn_thread&.raise(RubyLLM::CancelledError)
      nil
    end

    def model
      ENV.fetch("BREWSTER_LLM_MODEL", "unknown")
    end

    private

    # Per-event log line: streaming chunks would flood the log, so
    # text_delta is debug-only; tool traffic and lifecycle are info.
    def log_event(type, payload)
      case type
      when :text_delta
        Log.debug("session=#{@id} text_delta chars=#{payload[:text].to_s.length}")
      when :tool_call
        Log.info("session=#{@id} tool_call name=#{payload[:name]} id=#{payload[:id]}")
      when :tool_output
        Log.info("session=#{@id} tool_output id=#{payload[:id]} bytes=#{payload[:output].to_s.length}")
      when :approval_request
        Log.info("session=#{@id} approval_request name=#{payload[:name]} id=#{payload[:id]}")
      when :error
        Log.error("session=#{@id} turn_error code=#{payload[:code]} message=#{payload[:message]}")
      else
        Log.info("session=#{@id} #{type}")
      end
    end

    # AgentLoop callback: emits and tracks awaiting_approval state.
    def turn_event(type, **payload)
      case type
      when :approval_request
        @mutex.synchronize { @state = :awaiting_approval }
      when :turn_done
        @mutex.synchronize { @state = :idle }
      end
      emit(type, **payload)
      @event_listener&.call(type, payload)
      nil
    end

    # Default factory: fresh chat per turn. The prompt (AGENTS.md + persona)
    # is built by start_turn; with_instructions REPLACES the system message
    # (append defaults to false), so this is safe even on a reused chat.
    # BREWSTER_FAKE_CHAT=1 swaps in the scripted no-network chat (e2e specs).
    def default_chat_factory(prompt)
      return Testing::ScriptedChat.new if ENV["BREWSTER_FAKE_CHAT"] == "1"
      RubyLLM.chat(
        model: ENV.fetch("BREWSTER_LLM_MODEL"),
        provider: :openai,
        assume_model_exists: true
      ).with_instructions(prompt)
       .with_tools(Tools::Read, Tools::Write, Tools::Edit, Tools::Bash)
    end
  end
end