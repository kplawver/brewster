require "rspec"
require_relative "../lib/brewster/session"

# Scripted fake chat: no network. Replays canned chunks/tool calls and
# mirrors the RubyLLM::Chat API subset AgentLoop uses.
class FakeChat
  attr_reader :instructions, :tools, :calls
  attr_accessor :cancelled

  ToolCall = Struct.new(:id, :name, :arguments)

  def initialize(script)
    @script = script
    @calls = []
    @instructions = nil
    @cancelled = false
    @pending = []
    @decisions = {}
    @before_tool = nil
    @after_tool = nil
  end

  def with_instructions(text)
    @instructions = text
    self
  end

  def with_tools(*tools)
    @tools = tools
    self
  end

  def before_tool_call(&block)
    @before_tool = block
  end

  def after_tool_result(&block)
    @after_tool = block
  end

  def ask(_text, &stream)
    @calls << :ask
    emit_chunks(@script[:ask_chunks], stream)
    stage_tool_calls(@script[:ask_tool_calls])
  end

  def complete(&stream)
    @calls << :complete
    raise RubyLLM::CancelledError if @cancelled

    stage_tool_calls(@script[:complete_tool_calls])
    loop do
      run_pending_tools
      break if waiting? # undecided calls remain: real complete pauses here
      unless @final_emitted
        @final_emitted = true
        emit_chunks(@script[:final_chunks], stream)
      end
      break
    end
    self
  end

  def complete?
    @pending.empty? && !@script[:respond_with_tools] && !@unfinished
  end

  def waiting?
    @pending.any? && @pending.all? { |tc| @decisions[tc.id].nil? }
  end

  def awaiting_approval?
    waiting? && pending_approvals.any?
  end

  def pending_approvals
    @pending.reject { |tc| @decisions.key?(tc.id) }
  end

  def approve(id)
    @decisions[id] = true
    self
  end

  def deny(id)
    @decisions[id] = false
    self
  end

  def cancel
    @cancelled = true
    self
  end

  private

  def stage_tool_calls(list)
    return unless list&.any?
    @unfinished = true
    @pending.concat(list.map { |h| ToolCall.new(h[:id], h[:name], h[:args]) })
  end

  def run_pending_tools
    @pending.dup.each do |tc|
      decision = @decisions[tc.id]
      next if decision.nil? # still awaiting
      @pending.delete(tc)
      if decision
        @before_tool&.call(tc)
        out = @script[:tool_impl]&.call(tc) || "ok: #{tc.name}"
        @after_tool&.call(out)
      end
    end
    @unfinished = false if @pending.empty?
  end

  def emit_chunks(list, stream)
    list&.each do |text|
      stream&.call(Struct.new(:content).new(text))
    end
  end
end

RSpec.describe Brewster::AgentLoop do
  let(:events) { [] }
  let(:log) { Brewster::EventLog.new(File.join(Dir.mktmpdir, "s.jsonl")) }
  let(:session) do
    Brewster::Session.new(id: "t1", log: log,
                          chat_factory: ->(_p) { @fake })
  end
  let(:loop) do
    described_class.new(session, system_prompt: "spec prompt",
                                    chat_factory: ->(_p) { @fake },
                                    on_event: collector)
  end
  let(:collector) { ->(type, payload) { events << [type, payload] } }

  before do
    # start_turn builds its own AgentLoop; point its event sink at `events`
    session.event_listener = collector
  end

  def run_loop(text = "hi")
    loop.run(text)
  end

  it "runs a multi-tool turn emitting tool_call, tool_output, text_delta in order" do
    tc1 = {id: "t1", name: "read", args: {path: "a.txt"}}
    tc2 = {id: "t2", name: "bash", args: {command: "ls"}}
    @fake = FakeChat.new(
      ask_chunks: ["thinking"],
      ask_tool_calls: [tc1, tc2],
      final_chunks: ["done"],
      tool_impl: ->(tc) { "result-of-#{tc.name}" }
    )

    Thread.new do
      sleep 0.05 until events.any? { |t, _| t == :approval_request }
      session.commands.push({type: "approve", tool_call_id: "t1"})
      session.commands.push({type: "approve", tool_call_id: "t2"})
    end

    run_loop

    types = events.map(&:first)
    expect(types).to eq(%i[user_message text_delta approval_request approval_request
                           tool_call tool_output tool_call tool_output text_delta turn_done])
    expect(events.first).to eq([:user_message, text: "hi"])
    expect(events.last).to eq([:turn_done, reason: "complete"])
    tool_outputs = events.select { |t, _| t == :tool_output }
    expect(tool_outputs.map { |_, p| p[:output] }).to eq(["result-of-read", "result-of-bash"])
    deltas = events.select { |t, _| t == :text_delta }.map { |_, p| p[:text] }.join
    expect(deltas).to eq("thinkingdone")
    # approval_request emitted once per tool call
    expect(events.count { |t, _| t == :approval_request }).to eq(2)
  end

  it "continues the turn after a denial, feeding the model the denial result" do
    tc = {id: "t9", name: "write", args: {path: "/tmp/x", content: "y"}}
    @fake = FakeChat.new(
      ask_tool_calls: [tc],
      final_chunks: ["acknowledged"],
      tool_impl: ->(_tc) { "SHOULD-NOT-RUN" }
    )

    Thread.new do
      sleep 0.05 until events.any? { |t, _| t == :approval_request }
      session.commands.push({type: "deny", tool_call_id: "t9"})
    end

    run_loop

    expect(events.last).to eq([:turn_done, reason: "complete"])
    denied_output = events.find { |t, p| t == :tool_output && p[:id] == "t9" }
    expect(denied_output[1][:output]).to include("denied")
    expect(events.select { |t, _| t == :tool_output }.count).to eq(1)
    deltas = events.select { |t, _| t == :text_delta }.map { |_, p| p[:text] }.join
    expect(deltas).to include("acknowledged")
  end

  it "reports errors as an error event plus turn_done{error}" do
    @fake = FakeChat.new(ask_chunks: [])
    def @fake.ask(*)
      raise "boom"
    end

    run_loop
    expect(events).to include([:error, hash_including(code: "turn_error")])
    expect(events.last).to eq([:turn_done, reason: "error"])
  end

  it "cancelling mid-bash kills the subprocess and ends with turn_done{cancelled}" do
    tc = {id: "bash-1", name: "bash", args: {command: "sleep 30"}}
    @fake = FakeChat.new(
      ask_tool_calls: [tc],
      final_chunks: [],
      tool_impl: ->(_) do
        Brewster::Tools::Bash.new.call(
          tool_call: Struct.new(:id).new("bash-1"),
          command: "sleep 30", timeout_s: 25
        )
      end
    )

    started = session.start_turn("run sleep")
    expect(started).to be(true)

    sleep 0.05 until events.any? { |t, _| t == :approval_request }
    session.commands.push({type: "approve", tool_call_id: "bash-1"})
    sleep 0.3 # let the bash tool spawn and register the pid
    expect(Brewster::Permissions.running_pids).not_to be_empty

    session.cancel
    session.turn_thread.join(5)
    expect(session.turn_thread).not_to be_alive
    expect(Brewster::Permissions.running_pids).to be_empty
    expect(events.last).to eq([:turn_done, reason: "cancelled"])
  end

  it "session.start_turn runs the loop on a thread and rejects a second turn" do
    @fake = FakeChat.new(ask_chunks: ["hey"], final_chunks: [])
    started = session.start_turn("hello")
    expect(started).to be(true)
    expect(session.state).to eq(:running).or eq(:idle)
    session.turn_thread.join(5)
    expect(session.turn_thread).not_to be_alive
    expect(session.state).to eq(:idle)
  end

  it "captures a fresh AGENTS.md prompt on each turn" do
    dir = Dir.mktmpdir
    md = File.join(dir, "AGENTS.md")
    File.write(md, "rule v1")
    captured = []
    factory = ->(prompt) { captured << prompt; FakeChat.new(ask_chunks: ["ok"]) }
    session2 = Brewster::Session.new(id: "t2",
                                     log: Brewster::EventLog.new(File.join(Dir.mktmpdir, "s2.jsonl")),
                                     chat_factory: factory)
    allow(Dir).to receive(:pwd).and_return(dir)

    session2.start_turn("one")
    session2.turn_thread.join(5)
    File.write(md, "rule v2")
    session2.start_turn("two")
    session2.turn_thread.join(5)

    expect(captured.length).to eq(2)
    expect(captured[0]).to include("rule v1")
    expect(captured[1]).to include("rule v2")
    expect(captured[0]).not_to include("rule v2")
  end
end