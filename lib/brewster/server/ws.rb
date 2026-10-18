# M0 finding (2026-10-18): WS endpoint pattern validated in spike.
# GET /ws must be a Sinatra route that hands the env to
# Async::WebSocket::Adapters::Rack.open(env, protocols: ["ws"]) { |conn| ... }.
# When the request is not an upgrade, adapters#open returns nil and the route
# falls through to a plain 200.

module Brewster
  module Server
    module Ws
      def self.handle(env)
        Async::WebSocket::Adapters::Rack.open(env, protocols: ["ws"]) do |conn|
          yield conn
        end
      end
    end
  end
end