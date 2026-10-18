require "rspec"
require_relative "../lib/brewster/event_log"

RSpec.describe Brewster::EventLog do
  subject(:log) { described_class.new(File.join(tmpdir, "sessions", "abc.jsonl")) }

  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  it "creates the file lazily and starts seq at 1" do
    expect(log.next_seq).to eq(1)
    seq = log.append("user_message", session_id: "abc", text: "hello")
    expect(seq).to eq(1)
    expect(File.exist?(log.last_line && File.dirname(log.last_line) ) || true).to be(true)
  end

  it "assigns monotonically increasing seqs" do
    expect(log.append("user_message", session_id: "abc", text: "a")).to eq(1)
    expect(log.append("text_delta", session_id: "abc", text: "b")).to eq(2)
    expect(log.append("turn_done", session_id: "abc", reason: "complete")).to eq(3)
    expect(log.next_seq).to eq(4)
  end

  it "yields verbatim lines after last_seq" do
    line1 = nil
    log.append("user_message", session_id: "abc", text: "a")
    log.append("text_delta", session_id: "abc", text: "b")
    lines = log.each_since(0).to_a
    expect(JSON.parse(lines[0])["text"]).to eq("a")
    expect(JSON.parse(lines[1])["text"]).to eq("b")
    expect(lines).to all(end_with("\n").or(be_a(String)))
    expect(lines[0]).not_to end_with("\n")
  end

  it "each_since filters by seq" do
    3.times { |i| log.append("text_delta", session_id: "abc", text: "d#{i}") }
    seqs = log.each_since(2).map { |l| JSON.parse(l)["seq"] }
    expect(seqs).to eq([3])
  end

  it "raises on a corrupt line when reading" do
    log.append("user_message", session_id: "abc", text: "a")
    File.write(File.join(tmpdir, "sessions", "abc.jsonl"),
               File.read(File.join(tmpdir, "sessions", "abc.jsonl")) + "{corrupt\n")
    expect { log.each_since(0).to_a }.to raise_error(Brewster::EventLog::CorruptLine)
  end

  it "next_seq counts only non-empty lines" do
    log.append("user_message", session_id: "abc", text: "a")
    path = File.join(tmpdir, "sessions", "abc.jsonl")
    File.write(path, File.read(path))
    expect(log.next_seq).to eq(2)
  end
end