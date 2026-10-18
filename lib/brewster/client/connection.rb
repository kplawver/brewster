require "async"
require "async/websocket/client"
require "async/http/endpoint"
require "json"
require_relative "../log"

module Brewster
  module Client
    # Async WS connection with reconnect + re-attach. Yields parsed frames
    # (plus :connected/:disconnected markers) to the given block via a Queue.
    class Connection
      def initialize(url:, token:, session_id:, last_seq:, out:)
        @url = url
        @token = token
        @session_id = session_id
        @last_seq = last_seq
        @out = out
        @stop = false
        @conn = nil
      end

      def stop
        @stop = true
      end

      def run
        backoff = 0.5
        until @stop
          begin
            connect_once
            backoff = 0.5
          rescue StandardError => e
            Log.warn("ws=disconnected url=#{@url} #{e.class}: #{e.message}")
            @out << [:disconnected, e.message]
          end
          break if @stop
          sleep backoff
          backoff = [backoff * 2, 5.0].min
        end
        @out << [:stopped, nil]
      end

      def update_seq(seq)
        @last_seq = seq if seq > @last_seq
      end

      # Writes a client command on the live connection (no-op when down).
      def send_frame(hash)
        conn = @conn
        return unless conn
        conn.write(JSON.generate(hash))
        conn.flush
        true
      rescue StandardError
        false
      end

      private

      def connect_once
        endpoint = Async::HTTP::Endpoint.parse("#{@url}/ws")
        Async::WebSocket::Client.connect(endpoint, protocols: ["ws"], headers: headers) do |conn|
          @conn = conn
          @out << [:connected, nil]
          Log.info("ws=connect url=#{@url} session=#{@session_id || 'new'} last_seq=#{@last_seq}")
          conn.write(JSON.generate(
            type: "attach", session_id: @session_id, last_seq: @last_seq
          ))
          while (frame = conn.read)
            msg = JSON.parse(frame.to_str)
            @out << [:frame, msg]
            seq = msg["seq"]
            update_seq(seq) if seq.is_a?(Integer)
          end
        rescue Async::Wrapper::Stopped, IOError, Errno::ECONNREFUSED, Errno::EPIPE
          nil
        ensure
          @conn = nil
        end
      end

      def headers
        {authorization: "Bearer #{@token}"}
      end
    end
  end
end