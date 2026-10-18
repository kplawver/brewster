require_relative "lib/brewster"
require_relative "lib/brewster/server/app"

# Shutdown hardening: on falcon's graceful stop (INT/TERM), kill any tool
# subprocess groups still running and close every subscriber pipe. The trap
# covers the case where async-container hard-kills the worker before at_exit
# would run; at_exit is the belt, the trap is the suspenders.
trap_fired = false
shutdown = lambda do
  next if trap_fired
  trap_fired = true
  begin
    Brewster::Permissions.kill_all!
    Brewster::Server::App::SESSIONS.each_value { |s| s.bridge.close_all }
  rescue StandardError
    nil
  end
  exit!(0)
end
Signal.trap("INT") { shutdown.call }
Signal.trap("TERM") { shutdown.call }
at_exit { shutdown.call }

run Brewster::Server::App.new
