module Brewster
  # Owns the single wire schema: one JSON object per WS text frame.
  # Server->client frames carry the full envelope (type, seq, session_id, ts).
  # Client->server frames carry a command (type + fields, no seq).
  module Protocol
    EVENTS = %w[
      attached user_message text_delta tool_call tool_output
      approval_request turn_done error
    ].freeze
    COMMANDS = %w[attach send approve deny cancel].freeze

    class BadFrame < StandardError; end

    module_function

    def encode(type, session_id:, seq: nil, **payload)
      frame = {"type" => type, "session_id" => session_id,
               "ts" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")}
      frame["seq"] = seq if seq
      frame.merge!(stringify(payload))
      JSON.generate(frame)
    end

    # Returns {type:, **fields}. Raises BadFrame on non-JSON or unknown shape.
    def parse(raw)
      obj = JSON.parse(raw)
      raise BadFrame, "frame is not a JSON object" unless obj.is_a?(Hash)
      type = obj["type"]
      raise BadFrame, "missing type" unless type.is_a?(String)
      unless COMMANDS.include?(type) || EVENTS.include?(type)
        raise BadFrame, "unknown type #{type.inspect}"
      end
      {type: type}.merge(obj.reject { |k, _| k == "type" }.transform_keys(&:to_sym))
    rescue JSON::ParserError => e
      raise BadFrame, "invalid JSON: #{e.message}"
    end

    def stringify(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end
  end
end