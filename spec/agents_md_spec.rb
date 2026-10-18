require "rspec"
require_relative "../lib/brewster/context/agents_md"

RSpec.describe Brewster::AgentsMd do
  let(:tmpdir) { Dir.mktmpdir }
  let(:fake_home) { File.join(tmpdir, "home") }

  after { FileUtils.remove_entry(tmpdir) }

  def write(path, content)
    File.expand_path(path, tmpdir).tap do |p|
      FileUtils.mkdir_p(File.dirname(p))
      File.write(p, content)
    end
  end

  it "collects nearest-first from cwd up to the git root, then the global file" do
    write("repo/.git/HEAD", "ref: refs/heads/main")
    write("repo/AGENTS.md", "root rules")
    write("repo/sub/AGENTS.md", "sub rules")
    write("repo/sub/deep/AGENTS.md", "deep rules")
    global = write("home/.agents/AGENTS.md", "global rules")
    deep_dir = File.join(tmpdir, "repo", "sub", "deep")

    prompt = described_class.build(deep_dir, home: fake_home)

    expect(prompt).to include("# From #{File.join(deep_dir, 'AGENTS.md')}")
    deep_pos = prompt.index("deep rules")
    sub_pos = prompt.index("sub rules")
    root_pos = prompt.index("root rules")
    global_pos = prompt.index("global rules")
    expect(deep_pos).to be < sub_pos
    expect(sub_pos).to be < root_pos
    expect(root_pos).to be < global_pos
    expect(prompt).to include("# From #{global}")
  end

  it "walks to / when no .git exists, collecting what exists" do
    write("plain/a/AGENTS.md", "a rules")
    prompt = described_class.build(File.join(tmpdir, "plain", "a"), home: fake_home)
    expect(prompt).to include("a rules")
    expect(prompt.scan("# From ").count).to eq(1)
  end

  it "returns the base prompt untouched when no AGENTS.md exists" do
    prompt = described_class.build(tmpdir, home: fake_home)
    expect(prompt).to eq("")
  end

  it "stops adding files once the budget is exceeded and marks truncation" do
    write("repo/.git/HEAD", "")
    big = "x" * 10_000
    write("repo/AGENTS.md", big)
    write("repo/sub/AGENTS.md", big)
    write("repo/sub/deep/AGENTS.md", big)

    prompt = described_class.build(File.join(tmpdir, "repo", "sub", "deep"),
                                   home: fake_home)
    # deep + sub fit; adding repo would double the budget, so it is excluded
    expect(prompt).to include("# From #{File.join(tmpdir, 'repo', 'sub', 'deep', 'AGENTS.md')}")
    expect(prompt).to include("# From #{File.join(tmpdir, 'repo', 'sub', 'AGENTS.md')}")
    expect(prompt).not_to include("# From #{File.join(tmpdir, 'repo', 'AGENTS.md')}")
    expect(prompt).to include(described_class::MARKER)
  end
end