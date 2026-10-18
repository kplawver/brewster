require "rspec"
require_relative "../lib/brewster/protocol"

RSpec.describe Brewster::Protocol do
  describe ".encode" do
    it "builds the full envelope with seq" do
      line = described_class.encode("text_delta", session_id: "abc", seq: 3, text: "hi")
      obj = JSON.parse(line)
      expect(obj).to eq("type" => "text_delta", "session_id" => "abc", "seq" => 3,
                        "ts" => obj["ts"], "text" => "hi")
      expect(obj["ts"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/)
    end

    it "omits seq for server frames without one" do
      obj = JSON.parse(described_class.encode("error", session_id: "x", code: "busy", message: "m"))
      expect(obj).not_to have_key("seq")
      expect(obj["code"]).to eq("busy")
    end
  end

  describe ".parse" do
    it "parses a command with symbolized keys" do
      cmd = described_class.parse('{"type":"send","text":"hi","client_msg_id":"c1"}')
      expect(cmd).to eq(type: "send", text: "hi", client_msg_id: "c1")
    end

    it "parses every known event type" do
      %w[attached user_message text_delta tool_call tool_output
         approval_request turn_done error].each do |t|
        expect { described_class.parse(JSON.generate({type: t})) }.not_to raise_error
      end
    end

    it "raises BadFrame on garbage" do
      expect { described_class.parse("not json {") }.to raise_error(Brewster::Protocol::BadFrame)
    end

    it "raises BadFrame on JSON arrays and missing/unknown types" do
      expect { described_class.parse("[1,2]") }.to raise_error(Brewster::Protocol::BadFrame)
      expect { described_class.parse('{"text":"x"}') }.to raise_error(Brewster::Protocol::BadFrame)
      expect { described_class.parse('{"type":"nope"}') }.to raise_error(Brewster::Protocol::BadFrame)
    end
  end

  it "round-trips encode -> parse" do
    line = described_class.encode("tool_call", session_id: "s1", seq: 9,
                                                 id: "t1", name: "read", args: {path: "a"})
    cmd = described_class.parse(line)
    expect(cmd[:type]).to eq("tool_call")
    expect(cmd[:id]).to eq("t1")
    expect(cmd[:seq]).to eq(9)
  end
end