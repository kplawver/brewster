require "io/console"

module Brewster
  module Client
    # Raw-mode stdin reader: printable chars, Backspace, Enter=submit,
    # Ctrl-J=newline, Up/Down history, bracketed paste, Ctrl-C/Ctrl-D events.
    class Input
      Key = Struct.new(:type, :data)
      ENTER = :enter
      CHAR = :char
      BS = :backspace
      CTRL_C = :ctrl_c
      CTRL_D = :ctrl_d
      CTRL_J = :ctrl_j
      UP = :up
      DOWN = :down
      PASTE = :paste

      def initialize(out: $stdout)
        @out = out
        @history = []
        @history_index = nil
        @line = +""
      end

      def current_line = @line.dup

      def start
        # Raw mode is owned by App#run ($stdin.raw wrapping the whole run);
        # Input only decodes bytes.
        self
      end

      # Blocks for one key event; decodes ANSI sequences. Returns a Key with
      # `data` re-encoded as UTF-8 (getc yields single bytes in raw mode).
      def read_key
        c = $stdin.getc
        return nil if c.nil?
        case c
        when "\r", "\n" then return Key.new(ENTER, nil)
        when "\x03" then return Key.new(CTRL_C, nil)
        when "\x04" then return Key.new(CTRL_D, nil)
        when "\x7f" then return Key.new(BS, nil)
        when "\e"
          seq = read_escape
          return decode_escape(seq)
        end
        Key.new(CHAR, c.dup.force_encoding(Encoding::UTF_8))
      end

      def history_push(line)
        @history << line
        @history_index = nil
      end

      def history_up
        return nil if @history.empty?
        @history_index = @history_index.nil? ? @history.length - 1 : [@history_index - 1, 0].max
        @history[@history_index]
      end

      def history_down
        return nil if @history_index.nil?
        @history_index += 1
        if @history_index >= @history.length
          @history_index = nil
          return ""
        end
        @history[@history_index]
      end

      def restore
        @out.print(Render::CURSOR_SHOW)
      rescue StandardError
        nil
      end

      private

      def read_escape
        seq = +""
        $stdin.read_nonblock(8, exception: false) # rubocop:disable Style/HashLikeCase
        seq
      rescue StandardError
        seq
      end

      def decode_escape(seq)
        case seq
        when "[A" then Key.new(UP, nil)
        when "[B" then Key.new(DOWN, nil)
        when /\[200~(.*)\]?\z/m then Key.new(PASTE, $1)
        when "" then Key.new(CHAR, "\e") # bare escape
        else Key.new(CHAR, "\e#{seq}")
        end
      end
    end
  end
end