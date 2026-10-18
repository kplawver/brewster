module Brewster
  module Config
    module_function

    def home
      ENV.fetch("BREWSTER_HOME") { File.expand_path("~/.brewster") }
    end

    def sessions_dir
      File.join(home, "sessions")
    end

    def token_path
      File.join(home, "token")
    end

    # BREWSTER_LOG: "stdout" (default), "stderr", "off", or a file path
    # ("~" expanded). Relative file paths resolve under Config.home.
    def log_target
      raw = ENV["BREWSTER_LOG"].to_s.strip
      raw.empty? ? "stdout" : raw
    end

    def default_port
      7333
    end
  end
end