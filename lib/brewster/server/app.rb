require "openssl"
require "uri"
require_relative "../config"
require_relative "../protocol"
require_relative "../event_log"
require_relative "../bridge"
require_relative "../session"

module Brewster
  module Server
    class App
      SESSIONS = {}
      TOKEN_PATH = Config.token_path

      def call(env)
        return forbidden unless authorized?(env)
        case env["PATH_INFO"]
        when "/ws"
          Ws.handle(env) { |conn| serve_ws(conn) } ||
            [200, {"Content-Type" => "text/plain"}, ["brewster ws"]]
        else
          [404, {"Content-Type" => "text/plain"}, ["not found"]]
        end
      end

      private

      def authorized?(env)
        token = File.read(TOKEN_PATH).strip
        auth = env["HTTP_AUTHORIZATION"].to_s
        bearer = auth.start_with?("Bearer ") ? auth[7..] : nil
        return false unless bearer && OpenSSL.secure_compare(bearer, token)
        origin = env["HTTP_ORIGIN"]
        return true if origin.nil?
        allowed = ["http://127.0.0.1:#{port}", "http://localhost:#{port}"]
        allowed.include?(origin)
      rescue Errno::ENOENT
        false
      end

      def port
        @port ||= URI.parse(ENV.fetch("BREWSTER_BIND_URL", "http://127.0.0.1:#{Config.default_port}")).port
      end

      def forbidden
        [403, {"Content-Type" => "text/plain"}, ["forbidden"]]
      end

      # Frame flow: this task (the connection task) is the ONLY writer.
      # After attach, one child task reads inbound frames; the parent pumps
      # stored + live events out. Client close breaks the reader, which
      # closes the pipe to wake the pump.
      def serve_ws(conn)
        session = nil
        inbound = nil
        reader = nil
        msg = nil
        begin
          # first frame must be attach
          loop do
            frame = conn.read or return
            msg = Protocol.parse(frame.to_str)
            break if msg[:type] == "attach"
            conn.write(error_frame("no_session", "attach first", msg[:client_msg_id]))
            conn.flush
          end
          session = attach_session(msg)
          conn.write(Protocol.encode("attached", session_id: session.id,
                                              next_seq: session.log.next_seq))
          conn.flush

          buf = +""
          reader = session.bridge.subscribe(replay: session.log.each_since(msg[:last_seq] || 0).to_a)
          inbound = inbound_pump(conn, session, reader)
          loop do
            until (nl = buf.index("\n")).nil?
              conn.write(buf.slice!(0..nl).chomp)
              conn.flush
            end
            break if inbound.dead?
            reader.wait_readable(60) or break
            chunk = reader.read_nonblock(4096)
            break if chunk.nil?
            buf << chunk
          end
        rescue Protocol::BadFrame => e
          conn.write(error_frame("bad_frame", e.message))
          conn.flush
          retry
        rescue Async::Stop, IOError, Errno::EPIPE, Errno::EBADF
          nil
        ensure
          inbound&.stop
          session&.bridge&.unsubscribe(reader) if reader
          reader&.close unless reader&.closed?
        end
      end

      def inbound_pump(conn, session, reader)
        Async do |task|
          def task.dead?
            !alive?
          end
          while (frame = conn.read)
            handle_inbound(session, Protocol.parse(frame.to_str), reader)
          end
        rescue Protocol::BadFrame => e
          # bad frames keep the connection: surface via session error event
          session.emit("error", code: "bad_frame", message: e.message) if session
          retry
        rescue Async::Stop, IOError, Errno::EPIPE, Errno::EBADF
          nil
        ensure
          # wake the outbound pump when the client goes away
          reader.close unless reader.closed?
        end
      end

      def handle_inbound(session, msg, reader)
        case msg[:type]
        when "send"
          if session.start_turn(msg[:text])
            nil # turn events flow through the bridge
          else
            session.emit("error", code: "busy", message: "turn in progress")
          end
        when "approve", "deny"
          session.push_command(msg)
        when "cancel"
          session.cancel
        end
      end

      def attach_session(msg)
        id = msg[:session_id]
        if id && SESSIONS[id]
          SESSIONS[id]
        else
          id ||= SecureRandom.hex(8)
          SESSIONS[id] = Session.new(id: id)
        end
      end

      def error_frame(code, message, client_msg_id = nil)
        payload = {code: code, message: message}
        payload[:client_msg_id] = client_msg_id if client_msg_id
        Protocol.encode("error", session_id: "system", **payload)
      end
    end
  end
end