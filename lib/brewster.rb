require "json"
require "securerandom"
require "socket"
require "thread"
require "fileutils"
require "async"
require "async/websocket/adapters/rack"
require "ruby_llm"

if ENV["BREWER_LLM_API_KEY"]
  RubyLLM.configure do |c|
    c.openai_api_key = ENV["BREWER_LLM_API_KEY"]
    c.openai_api_base = ENV.fetch("BREWER_LLM_BASE_URL")
  end
end

require_relative "brewster/config"
require_relative "brewster/protocol"
require_relative "brewster/event_log"
require_relative "brewster/bridge"
require_relative "brewster/permissions"
require_relative "brewster/session"
require_relative "brewster/server/ws"

module Brewster
end