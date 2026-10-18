require "socket"
require "json"

module Helpers
  module_function

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def spawn_falcon(port, config_path, log: File::NULL)
    # Pass the path itself: `log.to_i` on a String is 0, which redirects to
    # fd 0 (stdin) and both loses the output and breaks the child's writes.
    pid = Process.spawn(
      "bundle", "exec", "falcon", "serve", "--count", "1",
      "--bind", "http://127.0.0.1:#{port}", "--config", config_path,
      pgroup: true, out: log, err: log
    )
    pid
  end

  def kill_tree(pid)
    Process.kill("TERM", -pid)
  rescue Errno::ESRCH
    nil
  ensure
    sleep 1
    begin
      Process.kill("KILL", -pid) if Process.kill(0, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  def wait_port(port, timeout = 15, log: "/tmp/brewster-falcon-spec.log")
    deadline = Time.now + timeout
    loop do
      begin
        TCPSocket.new("127.0.0.1", port).close
        return
      rescue Errno::ECONNREFUSED
        if Time.now > deadline
          detail = File.exist?(log) ? File.read(log)[-2000..] : "(no log)"
          raise "falcon did not start on #{port}\n#{detail}"
        end
        sleep 0.2
      end
    end
  end

  def ws_connect(base_url, token: nil)
    require "async"
    require "async/websocket/client"
    require "async/http/endpoint"
    endpoint = Async::HTTP::Endpoint.parse("#{base_url}/ws")
    headers = token ? {authorization: "Bearer #{token}"} : {}
    Sync do |parent|
      parent.async do
        Async::WebSocket::Client.connect(endpoint, protocols: ["ws"], headers: headers) do |conn|
          yield conn
        end
      end.wait
    end
  end

  # Raw upgrade probe; returns the HTTP status of the /ws handshake.
  def upgrade_status(base_url, headers)
    require "async"
    require "async/http/endpoint"
    require "async/http/client"
    Sync do
      endpoint = Async::HTTP::Endpoint.parse(base_url)
      client = Async::HTTP::Client.new(endpoint)
      base = {"connection" => "Upgrade", "upgrade" => "websocket",
              "sec-websocket-key" => "dGhlIHNhbXBsZSBub25jZQ==",
              "sec-websocket-version" => "13"}
      response = client.get("/ws", base.merge(headers))
      status = response.status
      response.close
      status
    end
  end
end