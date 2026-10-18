module Brewster
  # Append-only JSONL event log, one file per session. Each line is a
  # complete server->client frame; line number == seq (1-based, never reused).
  class EventLog
    class CorruptLine < StandardError; end

    def initialize(path)
      @path = path
      @mutex = Mutex.new
      @last_line = nil
      FileUtils.mkdir_p(File.dirname(path))
    end

    attr_reader :last_line, :path

    # Appends an event; assigns seq = last + 1 (first is 1). Returns seq.
    def append(type, session_id:, **payload)
      @mutex.synchronize do
        seq = next_seq
        line = Protocol.encode(type, session_id: session_id, seq: seq, **payload)
        File.open(@path, "a") { |f| f.write(line + "\n"); f.flush }
        @last_line = line
        seq
      end
    end

    # Yields each stored line (verbatim JSON string) whose seq > last_seq.
    def each_since(last_seq)
      return enum_for(:each_since, last_seq) unless block_given?
      return unless File.exist?(@path)
      File.foreach(@path).with_index(1) do |line, lineno|
        next if lineno <= last_seq
        line = line.strip
        next if line.empty?
        parse_or_raise(line)
        yield line
      end
    end

    def next_seq
      return 1 unless File.exist?(@path)
      count = 0
      File.foreach(@path) { |line| count += 1 unless line.strip.empty? }
      count + 1
    end

    private

    def parse_or_raise(line)
      obj = JSON.parse(line)
      raise CorruptLine, "line is not an object" unless obj.is_a?(Hash)
      raise CorruptLine, "line missing seq" unless obj["seq"].is_a?(Integer)
    rescue JSON::ParserError => e
      raise CorruptLine, "line #{e.message}"
    end
  end
end