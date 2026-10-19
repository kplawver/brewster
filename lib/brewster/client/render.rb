require "io/console"

module Brewster
  module Client
    # stdlib-ANSI renderer: scrollback of finished blocks + a 3-line live
    # region at the bottom (streaming text, input line, status line).
    class Render
      CLEAR_LINE = "\e[2K\r"
      # Raw mode disables OPOST: a bare "\n" moves down without returning the
      # carriage, so every row the renderer emits between lines needs CRLF.
      EOL = "\r\n"
      CURSOR_SHOW = "\e[?25h"
      CURSOR_HIDE = "\e[?25l"
      RESET = "\e[0m"
      DIM = "\e[2m"
      BOLD = "\e[1m"
      RED = "\e[31m"
      GREEN = "\e[32m"
      YELLOW = "\e[33m"
      CYAN = "\e[36m"

      def initialize(out: $stdout)
        @out = out
        @live_text = +""
        @input = +""
        @status = "connecting"
        @approval = nil
        @width = width
        @drawn = 0 # live-region rows the cursor is parked below
      end

      def width
        w = IO.console.winsize&.last || 80
        w < 20 ? 80 : w
      rescue StandardError
        80
      end

      def restore
        @out.print(CURSOR_SHOW)
        @out.flush
      end

      def set_status(text)
        return if @status == text
        @status = text
        redraw
      end

      def append_live(text)
        @live_text << text
        redraw
      end

      def flush_live
        return if @live_text.empty?
        scroll(@live_text)
        @live_text = +""
        redraw
      end

      def block(content, color: nil)
        lines = content.is_a?(Array) ? content : content.to_s.lines.map(&:chomp)
        scroll(lines.map { |l| color ? color + l + RESET : l }.join(EOL))
        redraw
      end

      def tool_line(name, args_summary)
        scroll("#{CYAN}● #{name}#{RESET} #{args_summary}")
        redraw
      end

      def output_preview(text, lines = 3)
        return if text.nil? || text.empty?
        preview = text.lines.first(lines).map { |l| "  #{DIM}#{l.chomp}#{RESET}" }
        scroll(preview.join(EOL))
        redraw
      end

      def error_line(text)
        scroll("#{RED}error: #{text}#{RESET}")
        redraw
      end

      def set_input(text)
        @input = text
        redraw
      end

      def input_line
        @input
      end

      def set_approval(question)
        @approval = question
        redraw
      end

      def clear_approval
        @approval = nil
        redraw
      end

      def resize!
        @width = width
        redraw
      end

      private

      # Live region: streaming text (last line), optional approval prompt,
      # input line, status line.
      #
      # Cursor invariant: redraw() ALWAYS enters and exits with the cursor at
      # the region's top row (= the input row when the region shrinks). Entry
      # states are "parked at top" (after any prior redraw) or "clean line at
      # column 0" (fresh start / after scroll, where @drawn == 0); CLEAR_LINE's
      # \r makes even a mid-line cursor safe. There is deliberately no
      # cursor-up at the start: the previous redraw already parked us there,
      # and moving up again would shift the region a row higher every keypress.
      # @drawn tracks the region HEIGHT so scroll() knows how far down the
      # next scrollback line starts.
      def redraw
        rows = []
        live = @live_text.lines.last&.chomp
        rows << "#{CYAN}#{live}#{RESET}" if live && !live.empty?
        rows << "#{YELLOW}#{@approval}#{RESET}" if @approval
        rows << "#{BOLD}> #{RESET}#{@input}"
        rows << "#{DIM}#{@status}#{RESET}"
        rows = rows.map { |r| truncate(r) }

        @out.print(CLEAR_LINE)
        @out.print(rows.join("\e[K\r\n"))
        # Cursor is on the last row. Wipe it and anything stale below (a
        # shrinking region), then climb back to the top row for the next call.
        @out.print("\e[K\e[J")
        @out.print("\e[#{rows.length - 1}A") if rows.length > 1
        @out.print("\r")
        @out.print(CURSOR_HIDE)
        @out.flush
        @drawn = rows.length
      end

      # Prints finished content to scrollback. Enter: cursor at the region
      # top (redraw parks it there; scroll leaves it there). Text is written
      # starting AT that line, overwriting the live region top-down, then
      # everything below is wiped. Exit: column 0 of the line under the text
      # = where the next redraw draws.
      def scroll(text)
        lines = wrap(text).split("\r\n", -1)
        @out.print(CLEAR_LINE)
        @out.print(lines.map { |l| "#{l}\e[K" }.join("\r\n"))
        @out.print("\r\n\e[J")
        @out.flush
        @drawn = 0
      end

      def truncate(line)
        plain = line.gsub(/\e\[[0-9;]*m/, "")
        return line if @width < 3 || plain.length <= @width
        cut = plain_length_index(line, @width - 1)
        line[0...cut] + "…"
      end

      def plain_length_index(line, max)
        len = 0
        i = 0
        while i < line.length
          if line[i] == "\e"
            i += 1 while i < line.length && line[i] != "m"
          else
            len += 1
            return i if len > max
          end
          i += 1
        end
        line.length
      end

      def wrap(text)
        text.lines.map { |l| truncate(l.chomp) }.join("\r\n")
      end
    end
  end
end