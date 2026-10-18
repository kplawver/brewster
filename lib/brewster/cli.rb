require "open3"

module Brewster
  module Cli
    module_function

    def serve(port:, count:)
      missing = %w[BREWER_LLM_BASE_URL BREWER_LLM_API_KEY BREWER_LLM_MODEL].reject { |v| ENV[v] }
      unless missing.empty?
        warn "brewster serve: missing environment variable(s) #{missing.join(', ')}"
        warn "set BREWER_LLM_BASE_URL, BREWER_LLM_API_KEY and BREWER_LLM_MODEL (OpenAI-compatible endpoint)"
        exit 1
      end
      ensure_home
      ENV["BREWER_BIND_URL"] = "http://127.0.0.1:#{port}"
      exec("bundle", "exec", "falcon", "serve",
           "--count", count.to_s,
           "--no-restart",
           "--bind", "http://127.0.0.1:#{port}",
           "--config", File.expand_path("../../config.ru", __dir__))
    end

    def chat(port:, session:)
      require_relative "client/app"
      url = "http://127.0.0.1:#{port}"
      token = read_token
      Client::App.new(url: url, token: token, session_id: session).run
    rescue Errno::ECONNREFUSED, Async::WebSocket::ConnectionError => e
      warn "brewster chat: cannot reach #{url} (#{e.class})"
      exit 1
    end

    def ensure_home
      FileUtils.mkdir_p(Config.sessions_dir)
      return if File.exist?(Config.token_path)
      File.write(Config.token_path, SecureRandom.hex(32))
      File.chmod(0o600, Config.token_path)
    end

    def read_token
      path = Config.token_path
      unless File.exist?(path)
        warn "brewster chat: missing #{path} — run the server once to create it"
        exit 1
      end
      File.read(path).strip
    end
  end
end