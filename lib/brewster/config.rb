module Brewster
  module Config
    module_function

    def home
      ENV.fetch("BREWER_HOME") { File.expand_path("~/.brewster") }
    end

    def sessions_dir
      File.join(home, "sessions")
    end

    def token_path
      File.join(home, "token")
    end

    def default_port
      7333
    end
  end
end