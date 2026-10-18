require "logger"

module Brewster
  # Process-wide structured logger. Default target is stdout so `brewster
  # serve` is observable in a terminal / `foreman` / container logs; set
  # BREWSTER_LOG to "stderr", "off", or a file path to override. Relative
  # file paths resolve under Config.home.
  #
  # Logger writes are mutex-guarded, so the turn thread and Falcon fibers
  # can both log safely.
  module Log
    OFF = Logger.new(File::NULL)

    module_function

    def logger
      @logger ||= build
    end

    def config_path
      raw = Config.log_target
      File.expand_path(raw, Config.home)
    end

    # Human-readable destination for startup logging.
    def target_description
      case Config.log_target
      when "off", "stdout", "stderr" then Config.log_target
      else config_path
      end
    end

    def build
      target = Config.log_target
      case target
      when "off" then OFF
      when "stdout" then Logger.new($stdout)
      when "stderr" then Logger.new($stderr)
      else
        FileUtils.mkdir_p(File.dirname(config_path))
        Logger.new(config_path, 7, 10 * 1024 * 1024) # rotate at 10 MiB
      end.tap do |l|
        l.level = level_from_env
        l.formatter = proc do |severity, time, _prog, msg|
          "#{time.utc.strftime('%Y-%m-%dT%H:%M:%S.%3NZ')} #{severity.ljust(5)} #{msg}\n"
        end
      end
    rescue SystemCallError, IOError => e
      warn "brewster: cannot open log target #{target.inspect} (#{e.class}: #{e.message}); logging to stderr"
      Logger.new($stderr)
    end

    # BREWSTER_LOG_LEVEL: debug|info|warn|error (default info).
    def level_from_env
      name = ENV.fetch("BREWSTER_LOG_LEVEL", "info").to_s.upcase
      Logger.const_defined?(name) ? Logger.const_get(name) : Logger::INFO
    end

    def info(msg) = logger.info(msg)
    def debug(msg) = logger.debug(msg)
    def warn(msg) = logger.warn(msg)
    def error(msg) = logger.error(msg)

    def exception(prefix, err)
      logger.error("#{prefix}: #{err.class}: #{err.message}\n  #{Array(err.backtrace).first(5).join("\n  ")}")
    end
  end
end
