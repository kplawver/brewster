require "ruby_llm/tool"

require_relative "permissions"

module Brewster
  module Tools
    MAX_OUTPUT = 256 * 1024 # 256 KiB cap per tool result

    def self.cap(output)
      if output.bytesize > MAX_OUTPUT
        output.byteslice(0, MAX_OUTPUT) +
          "\n... [truncated #{output.bytesize - MAX_OUTPUT} bytes]"
      else
        output
      end
    end

    class Read < RubyLLM::Tool
      description "Reads a text file and returns its lines, numbered from 1."
      requires_approval


      parameter :path, type: :string, description: "Absolute or cwd-relative file path"
      parameter :offset, type: :integer, description: "1-based first line to read (default 1)",
                    required: false
      parameter :limit, type: :integer, description: "Max lines to return (default 2000)",
                   required: false

      def execute(path:, offset: 1, limit: 2000)
        content = File.read(path)
        lines = content.lines
        window = lines[(offset - 1).clamp(0, lines.length), limit]
        window ||= []
        out = window.each_with_index
                    .map { |line, i| "#{offset + i}: #{line.chomp}" }.join("\n")
        out = "(empty file)" if out.empty?
        Tools.cap(out)
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end
    end

    class Write < RubyLLM::Tool
      description "Creates or overwrites a file with the given content. " \
                  "Creates parent directories. Returns the byte count written."
      requires_approval

      parameter :path, type: :string, description: "Absolute or cwd-relative file path"
      parameter :content, type: :string, description: "Full file content to write"

      def execute(path:, content:)
        FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
        File.write(path, content)
        "wrote #{content.bytesize} bytes to #{path}"
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end
    end

    class Edit < RubyLLM::Tool
      description "Replaces exactly one occurrence of old_string with new_string " \
                  "in a file. Refuses when old_string matches zero or multiple " \
                  "times; the error states the match count."
      requires_approval

      parameter :path, type: :string, description: "Absolute or cwd-relative file path"
      parameter :old_string, type: :string, description: "Exact text to replace"
      parameter :new_string, type: :string, description: "Replacement text"

      def execute(path:, old_string:, new_string:)
        content = File.read(path)
        count = content.scan(old_string).count
        if count != 1
          return "ERROR: old_string matches #{count} times in #{path} " \
                 "(need exactly 1); file unchanged"
        end
        File.write(path, content.sub(old_string, new_string))
        "edited #{path} (1 replacement)"
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end
    end

    class Bash < RubyLLM::Tool
      description "Runs a command through bash -lc in its own process group. " \
                  "Captures stdout+stderr (64 KiB per stream, truncated)."
      requires_approval

      parameter :command, type: :string, description: "Shell command to run"
      parameter :timeout_s, type: :integer, description: "Seconds before TERM/KILL (default 30)",
                       required: false

      def execute(tool_call: nil, command:, timeout_s: 30)
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        # No -l: a login shell enables job control, putting each command in
        # its own process group — which would dodge our group-KILL on cancel.
        pid = Process.spawn("bash", "-c", command,
                            pgroup: true, out: out_w, err: err_w)
        [out_w, err_w].each(&:close)
        if tool_call
          Permissions.register(tool_call.id, pid)
          @tool_call_id = tool_call.id
        end

        drain_out = drain(out_r, 64 * 1024)
        drain_err = drain(err_r, 64 * 1024)

        status = nil
        status = wait_with_timeout(pid, timeout_s)
        stdout = drain_out.value
        stderr = drain_err.value
        result = +""
        result << stdout if stdout && !stdout.empty?
        if stderr && !stderr.empty?
          result << "\n" unless result.empty?
          result << "[stderr]\n" << stderr
        end
        unless status.nil? || status.success?
          detail = status.exited? ? status.exitstatus : "signal #{status.termsig}"
          result << "\n" unless result.empty?
          result << "[exit #{detail}]"
        end
        result = "(no output)" if result.empty?
        Tools.cap(result)
      ensure
        Permissions.unregister(@tool_call_id) if @tool_call_id
        # out_r/err_r belong to the drain threads; only kill a still-running
        # child whose wait loop was interrupted (e.g. by session.cancel).
        kill_group_quietly(pid) if status.nil? && pid
      end

      private

      # Drains io into a capped string, joined from reader chunks.
      def drain(io, cap)
        Thread.new do
          data = io.read(cap + 1)
          data = data[0, cap] << "\n... [stream truncated]" if data && data.bytesize > cap
          data
        ensure
          io.close unless io.closed?
        end
      end

      def wait_with_timeout(pid, timeout_s)
        deadline = Time.now + timeout_s
        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return status if status
          raise Timeout::Error if Time.now > deadline
          sleep 0.05
        end
      rescue Timeout::Error
        Permissions.kill_group(pid, "-TERM")
        wait_for(pid, 2) || (Permissions.kill_group(pid, "-KILL") && wait_for(pid, 2))
      end

      def wait_for(pid, seconds)
        deadline = Time.now + seconds
        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return status if status
          return nil if Time.now > deadline
          sleep 0.05
        end
      rescue Errno::ECHILD
        nil
      end

      def kill_group_quietly(pid)
        Permissions.kill_group(pid, "-KILL")
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
    end
  end
end