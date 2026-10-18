require "set"

module Brewster
  module Testing
    # Minimal scripted chat for e2e runs with BREWER_FAKE_CHAT=1: echoes the
    # user text as one delta. Mirrors the RubyLLM::Chat API subset the
    # AgentLoop drives. Never touches the network.
    class ScriptedChat
      ToolCall = Struct.new(:id, :name, :arguments)

      def initialize
        @cancelled = false
        @pending = []
        @decisions = {}
        @unfinished = false
      end

      def with_instructions(_text) = self
      def with_tools(*_tools) = self
      def before_tool_call(&b) = (@before = b)
      def after_tool_result(&b) = (@after = b)

      def ask(text, &stream)
        stream&.call(Struct.new(:content).new("echo: #{text}"))
        self
      end

      def complete(&)
        raise RubyLLM::CancelledError if @cancelled
        self
      end

      def complete? = !@unfinished
      def waiting? = false
      def awaiting_approval? = false
      def pending_approvals = []
      def approve(_id) = self
      def deny(_id) = self
      def cancel = (@cancelled = true; self)
      def cancelled? = @cancelled
    end
  end
end