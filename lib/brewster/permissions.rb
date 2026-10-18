module Brewster
  # Approval gate registry. Every tool requires approval in the POC.
  # Also owns tool_call_id -> pid for the cancel path.
  module Permissions
    @running = {} # tool_call_id => pid (process group leader)
    @mutex = Mutex.new

    class << self
      def requires_approval?(_tool_name)
        true
      end

      def register(tool_call_id, pid)
        @mutex.synchronize { @running[tool_call_id] = pid }
      end

      def unregister(tool_call_id)
        @mutex.synchronize { @running.delete(tool_call_id) }
      end

      def running_pids
        @mutex.synchronize { @running.values.dup }
      end

      # TERM each process group; escalates to KILL after 2s on its own thread.
      def kill_all!
        pids = running_pids
        return if pids.empty?
        pids.each { |pid| kill_group(pid, "-TERM") }
        Thread.new do
          sleep 2
          running_pids.each { |pid| kill_group(pid, "-KILL") }
        end
      end

      def kill_group(pid, signal)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end