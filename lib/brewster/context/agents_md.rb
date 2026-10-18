module Brewster
  # Builds the system prompt from AGENTS.md files: walk cwd upward to the
  # containing git repo (inclusive), nearest first, then ~/.agents/AGENTS.md.
  # Budget 16 000 chars; stop adding whole files once exceeded and mark it.
  module AgentsMd
    BUDGET = 16_000
    MARKER = "# (AGENTS.md truncated at budget)"

    module_function

    def build(cwd, home: Dir.home)
      files = collect_files(File.expand_path(cwd), home)
      parts = []
      total = 0
      files.each do |path|
        break if total >= BUDGET
        body = File.read(path)
        part = "# From #{path}\n#{body}"
        parts << part
        total += part.length
      end
      prompt = parts.join("\n\n")
      prompt += "\n\n#{MARKER}" if total >= BUDGET
      prompt
    end

    def collect_files(cwd, home)
      dirs = []
      dir = File.expand_path(cwd)
      loop do
        dirs << dir
        break if File.exist?(File.join(dir, ".git")) || dir == "/"
        dir = File.dirname(dir)
      end
      files = dirs.filter_map { |d| p = File.join(d, "AGENTS.md"); File.exist?(p) ? p : nil }
      global = File.join(home.to_s, ".agents", "AGENTS.md")
      files << global if File.exist?(global)
      files
    end
  end
end