require "rspec"
require "net/http"
require_relative "../lib/brewster/server/app"
require_relative "support/ws_client"

RSpec.describe "Brewster server e2e" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:port) { Helpers.free_port }
  let(:base) { "http://127.0.0.1:#{port}" }

  around do |example|
    FileUtils.mkdir_p(File.join(tmpdir, "sessions"))
    env_home = ENV["BREWSTER_HOME"]
    ENV["BREWSTER_HOME"] = tmpdir
    env_bind = ENV["BREWSTER_BIND_URL"]
    ENV["BREWSTER_BIND_URL"] = base
    File.write(File.join(tmpdir, "token"), "testtoken")
    File.chmod(0o600, File.join(tmpdir, "token"))
    env_fake = ENV["BREWSTER_FAKE_CHAT"]
    ENV["BREWSTER_FAKE_CHAT"] = "1"
    server = Helpers.spawn_falcon(port, File.expand_path("../config.ru", __dir__),
                                  log: "/tmp/brewster-falcon-spec.log")
    begin
      Helpers.wait_port(port)
      example.run
    ensure
      Helpers.kill_tree(server)
      env_fake ? ENV["BREWSTER_FAKE_CHAT"] = env_fake : ENV.delete("BREWSTER_FAKE_CHAT")
      env_home ? ENV["BREWSTER_HOME"] = env_home : ENV.delete("BREWSTER_HOME")
      env_bind ? ENV["BREWSTER_BIND_URL"] = env_bind : ENV.delete("BREWSTER_BIND_URL")
      FileUtils.remove_entry(tmpdir)
    end
  end

  def connect(&block)
    Helpers.ws_connect(base, token: "testtoken", &block)
  end

  def attach(conn, session_id: nil, last_seq: 0)
    frame = {type: "attach", last_seq: last_seq}
    frame[:session_id] = session_id if session_id
    conn.write(JSON.generate(frame))
    JSON.parse(conn.read.to_str)
  end

  def log_path(session_id)
    File.join(tmpdir, "sessions", "#{session_id}.jsonl")
  end

  def inject(session_id, type, **payload)
    Brewster::EventLog.new(log_path(session_id)).append(type, session_id: session_id, **payload)
  end

  it "attaches, replays stored events in order exactly once, and streams live" do
    connect do |conn|
      attached = attach(conn)
      expect(attached).to include("type" => "attached", "next_seq" => 1)
      session_id = attached["session_id"]

      # inject stored events on disk the way the turn thread would
      inject(session_id, "user_message", text: "one")
      inject(session_id, "text_delta", text: "tw")
      inject(session_id, "text_delta", text: "o")
      inject(session_id, "turn_done", reason: "complete")

      # reconnect with last_seq=0 -> attached + all four, verbatim, in order
      reconnect = Helpers.ws_connect(base, token: "testtoken") do |conn2|
        a2 = attach(conn2, session_id: session_id, last_seq: 0)
        expect(a2).to include("type" => "attached", "session_id" => session_id)
        lines = 4.times.map { conn2.read.to_str }
        expect(lines.map { |l| JSON.parse(l)["seq"] }).to eq([1, 2, 3, 4])
        expect(JSON.parse(lines[2])["text"]).to eq("o")
        expect(JSON.parse(lines[3])["reason"]).to eq("complete")
      end
      expect(reconnect).to be(true)

      # disconnect mid-stream: read only 2 of the replayed events
      mid = Helpers.ws_connect(base, token: "testtoken") do |conn3|
        attach(conn3, session_id: session_id, last_seq: 0)
        2.times { conn3.read.to_str }
      end
      expect(mid).to eq(2)

      # reconnect with last_seq=2 -> events 3,4 again, exactly once
      Helpers.ws_connect(base, token: "testtoken") do |conn4|
        attach(conn4, session_id: session_id, last_seq: 2)
        lines = 2.times.map { conn4.read.to_str }
        expect(lines.map { |l| JSON.parse(l)["seq"] }).to eq([3, 4])
      end

      # live event through the pipe bridge: send over the wire, receive echo
      Helpers.ws_connect(base, token: "testtoken") do |conn5|
        attach(conn5, session_id: session_id, last_seq: 4)
        conn5.write(JSON.generate({type: "send", text: "hello live"}))
        live = JSON.parse(conn5.read.to_str)
        expect(live).to include("type" => "user_message", "text" => "hello live", "seq" => 5)
      end
    end
  end

  it "delivers live turn events while attached without dropping any" do
    connect do |conn|
      attach(conn)

      frames = []
      3.times do |i|
        conn.write(JSON.generate({type: "send", text: "m#{i}"}))
        3.times { frames << JSON.parse(conn.read.to_str) }
      end
      expect(frames.map { |f| f["type"] }).to eq(
        %w[user_message text_delta turn_done] * 3
      )
      expect(frames.select { |f| f["type"] == "text_delta" }
                    .map { |f| f["text"] }).to eq(["echo: m0", "echo: m1", "echo: m2"])
      expect(frames.map { |f| f["seq"] }).to eq((1..9).to_a)
    end
  end

  it "rejects bad token and browser origins, accepts direct dial" do
    # no token -> 403
    expect(Helpers.upgrade_status(base, {})).to eq(403)
    # wrong token -> 403
    expect(Helpers.upgrade_status(base, {authorization: "Bearer nope"})).to eq(403)
    # browser origin (even with token) -> 403
    expect(Helpers.upgrade_status(base,
                                  {authorization: "Bearer testtoken",
                                   origin: "http://evil.example"})).to eq(403)
    # token, no origin -> upgrade
    expect(Helpers.upgrade_status(base, {authorization: "Bearer testtoken"})).to eq(101)
    # localhost origin with matching port is allowed
    expect(Helpers.upgrade_status(base,
                                  {authorization: "Bearer testtoken",
                                   origin: "http://localhost:#{port}"})).to eq(101)
  end

  it "replies bad_frame for garbage and keeps the connection open" do
    connect do |conn|
      attach(conn)
      conn.write("this is not json")
      err = JSON.parse(conn.read.to_str)
      expect(err).to include("type" => "error", "code" => "bad_frame")
      # connection still usable: a send runs a turn through the same socket
      conn.write(JSON.generate({type: "send", text: "still here"}))
      frames = 3.times.map { JSON.parse(conn.read.to_str) }
      expect(frames.map { |f| f["type"] }).to eq(%w[user_message text_delta turn_done])
      expect(frames[1]["text"]).to eq("echo: still here")
    end
  end
end