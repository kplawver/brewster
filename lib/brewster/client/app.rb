require "async"
require "json"
require "io/console"
require_relative "connection"
require_relative "render"
require_relative "input"

module Brewster
  module Client
    # Terminal app: three async tasks (stdin, socket pump, SIGWINCH
    # self-pipe) + frame dispatch into the renderer.
    class App
      def initialize(url:, token:, session_id:)
        @url = url
        @token = token
        @session_id = session_id
        @render = Render.new(out: $stdout)
        @input = Input.new
        @events = Queue.new
        @quit = false
        @ctrl_c_at = nil
        @last_seq = 0
        @winch_r, @winch_w = IO.pipe
        @model = ENV.fetch("BREWSTER_LLM_MODEL", "unknown")
      end

      def run
        # Some environments deny termios (sandboxed ptys); degrade to cooked
        # line mode — the UI still renders, input is line-based.
        termios_ok = begin
          $stdin.winsize
          true
        rescue StandardError
          false
        end
        if termios_ok
          begin
            $stdin.raw { inner_run }
          rescue Errno::ENODEV, Errno::ENOTTY, Errno::ENOENT
            inner_run
          end
        else
          inner_run
        end
      end

      def inner_run
        @input.start

        Async do |task|
          install_winch(task)
          conn = Connection.new(url: @url, token: @token, session_id: @session_id,
                                last_seq: @last_seq, out: @events)
          socket_task = task.async { conn.run }
          # stdin getc() is a blocking read: it must run on a plain thread,
          # not an async task (blocking the reactor freezes the whole client).
          @stdin_thread = Thread.new do
            Thread.current.report_on_exception = false
            read_stdin_forever
          end

          until @quit
            # Queue#pop would block the reactor thread; poll non-blockingly
            # and yield (async-aware sleep) when idle.
            begin
              kind, payload = @events.pop(true)
            rescue ThreadError
              sleep 0.02
              next
            end
            case kind
            when :frame then dispatch(payload, conn)
            when :connected then @render.set_status("connected · session #{@session_id || 'new'} · #{@model}")
            when :disconnected then @render.set_status("reconnecting (#{payload})")
            when :stopped then break
            when :line then submit(payload)
            when :key then handle_key(payload, conn)
            when :resize then @render.resize!
            end
          end
          conn.stop
          socket_task&.stop
          $stdin.close unless $stdin.closed? # wakes the blocking getc
          @stdin_thread&.join(0.5)
          # The reactor waits for children at block end; the winch watcher
          # never ends by itself, so stop everything explicitly.
          task.stop
        ensure
          cleanup
        end
      end

      private

      def install_winch(task)
        Signal.trap("WINCH") { @winch_w.write_nonblock("r") rescue nil }
        task.async do
          while @winch_r.wait_readable(3600)
            @winch_r.read_nonblock(16) rescue break
            @events << [:resize, nil]
          end
        rescue Async::Stop, IOError, Errno::EBADF
          nil
        end
      end

      def read_stdin_forever
        while (key = @input.read_key)
          @events << [:key, key]
        end
      rescue StandardError, IOError
        nil
      end

      def dispatch(payload, conn)
        case payload["type"]
        when "__send" then conn.send_frame(type: "send", text: payload["text"])
        when "__cancel" then conn.send_frame(type: "cancel")
        else handle_frame(payload)
        end
      end

      def handle_frame(msg)
        case msg["type"]
        when "attached"
          @session_id = msg["session_id"]
          @render.set_status("connected · session #{@session_id} · #{@model}")
        when "user_message"
          @render.block("you: #{msg['text']}")
        when "text_delta"
          @last_seq = msg["seq"] if msg["seq"]
          @render.append_live(msg["text"])
        when "tool_call"
          args = msg["args"].is_a?(Hash) ? msg["args"].map { |k, v| "#{k}=#{v}" }.join(" ") : msg["args"].to_s
          @render.tool_line(msg["name"], args)
          @render.flush_live
        when "tool_output"
          @render.output_preview(msg["output"])
        when "approval_request"
          @render.flush_live
          @render.set_approval("Approve #{msg['name']} #{truncate_args(msg['args'])}? [y/n]")
        when "turn_done"
          @render.flush_live
          @render.block("– #{msg['reason']} –", color: Render::DIM) if msg["reason"] != "complete"
          @render.set_status("idle · session #{@session_id} · #{@model}")
        when "error"
          @render.error_line("#{msg['code']}: #{msg['message']}")
          @render.set_status("error · session #{@session_id} · #{@model}")
        end
      end

      def handle_key(key, conn)
        case key.type
        when Input::CHAR
          line = @render.input_line + key.data
          @render.set_input(line)
        when Input::BACKSPACE
          @render.set_input(@render.input_line[0...-1].to_s)
        when Input::ENTER
          line = @render.input_line
          if line.empty?
            nil
          else
            @input.history_push(line)
            @render.set_input("")
            submit(line)
          end
        when Input::CTRL_J
          @render.set_input(@render.input_line + "\n")
        when Input::UP
          @render.set_input(@input.history_up || @render.input_line)
        when Input::DOWN
          @render.set_input(@input.history_down || @render.input_line)
        when Input::CTRL_D
          quit if @render.input_line.empty?
        when Input::CTRL_C
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if @ctrl_c_at && now - @ctrl_c_at < 2
            quit
          else
            @ctrl_c_at = now
            conn.send_frame(type: "cancel")
            @render.set_status("cancelling… · session #{@session_id} · #{@model}")
          end
        end
      end

      def submit(line)
        @render.block("you: #{line}")
        @render.set_status("thinking · session #{@session_id} · #{@model}")
      end

      def truncate_args(args)
        s = args.is_a?(Hash) ? args.map { |k, v| "#{k}=#{v}" }.join(" ") : args.to_s
        s.length > 60 ? s[0, 60] + "…" : s
      end

      def quit
        @quit = true
        @events << [:stopped, nil]
      end

      def cleanup
        @input.restore
        @render.restore
      end
    end
  end
end