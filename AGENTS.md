# AGENTS.md

Guidance for agents and humans working on brewster — a POC local coding harness (Ruby 4.0.5, pinned in `.mise.toml` and `Gemfile`). The agent-consumption mechanics you are reading this file through are implemented in `lib/brewster/context/agents_md.rb`.

## Commands

```sh
mise install          # Ruby 4.0.5
bundle install
bundle exec rspec     # full suite, random order (seed printed on failure)
bundle exec rspec spec/session_spec.rb:212   # single example
bin/brewster serve    # server; requires BREWSTER_LLM_{BASE_URL,API_KEY,MODEL}
bin/brewster chat     # terminal client
```

`BREWSTER_FAKE_CHAT=1` swaps RubyLLM for `Brewster::Testing::ScriptedChat` (echoes input, never touches the network) — used by e2e specs and for manual runs without API access.

Test loading: there is no gemspec. rspec-core auto-adds `lib/` and `spec/` to `$LOAD_PATH` from the project root, which is how `require "brewster"` and `require "spec_helper"` resolve. Plain `bundle exec ruby -e 'require "brewster"'` does NOT resolve — don't copy that pattern into new tooling.

## Logging

`Brewster::Log` (`lib/brewster/log.rb`) is the only logger. Default target is **stdout** (`BREWSTER_LOG=stdout`), so `brewster serve` is observable where it was started; `BREWSTER_LOG=off|stderr|<path>` overrides (relative paths resolve under `BREWSTER_HOME`, 10 MiB rotation). `BREWSTER_LOG_LEVEL` defaults to `info`; `text_delta` is debug-only so streams don't flood. Specs set `BREWSTER_LOG=off`.

## Layout

| Path | Responsibility |
|---|---|
| `bin/brewster` | Thor CLI: `serve`, `chat` |
| `config.ru` | Falcon app; INT/TERM/`at_exit` hardening (kills tool process groups, closes bridges) |
| `lib/brewster.rb` | Deps, RubyLLM config from env |
| `lib/brewster/config.rb` | `BREWSTER_HOME` paths, default port 7333 |
| `lib/brewster/protocol.rb` | The single wire schema: `Protocol.encode`/`parse`, event + command names |
| `lib/brewster/event_log.rb` | Append-only JSONL; `seq` = line number; `each_since` replay |
| `lib/brewster/log.rb` | Process-wide `Logger` (stdout default; `BREWSTER_LOG`/`BREWSTER_LOG_LEVEL`) |
| `lib/brewster/bridge.rb` | Thread→fiber event fan-out via per-subscriber pipes; 64-line replay ring |
| `lib/brewster/permissions.rb` | Approval gate (all tools), `tool_call_id` → pid registry, group kill |
| `lib/brewster/session.rb` | Owns EventLog, Bridge, command Queue, turn thread; state `idle`/`running`/`awaiting_approval` |
| `lib/brewster/agent_loop.rb` | RubyLLM turn driver: approval pause/resume, cancel; header documents RubyLLM 2.1.1 API findings |
| `lib/brewster/tools.rb` | `read`/`write`/`edit`/`bash`; 256 KiB result cap, 64 KiB/stream for bash |
| `lib/brewster/context/agents_md.rb` | AGENTS.md collection: nearest-first to git root, then `~/.agents/AGENTS.md`, 16k budget |
| `lib/brewster/cli.rb` | `serve`/`chat` impls, env validation, token creation (0600) |
| `lib/brewster/server/app.rb` | Sinatra app: bearer-token + Origin auth, WS upgrade, session attach |
| `lib/brewster/server/ws.rb` | `Async::WebSocket::Adapters::Rack` bridge; must be a Sinatra route |
| `lib/brewster/client/{app,connection,input,render}.rb` | Terminal client: dispatch, reconnect+reattach, raw stdin, stdlib-ANSI render |
| `lib/brewster/testing.rb` | `ScriptedChat` for `BREWSTER_FAKE_CHAT=1` |

## Invariants — check before touching these areas

**Threading model.** WS IO lives on Falcon fibers; the agent turn (RubyLLM streaming + subprocess popen) runs on a dedicated plain `Thread` per turn. Never run `chat.ask`, `Queue#pop`, or `$stdin.getc` inside an async task — all three block/starve the reactor (validated in the M0 spike; see `agent_loop.rb` header).

**Frame ownership.** The WS connection task is the only frame writer. The turn thread never touches sockets: `Session#emit` appends to the EventLog and writes to Bridge subscriber pipes; the WS task pumps those pipes.

**Sequence numbers.** `seq` = JSONL line number, 1-based, never reused, assigned under the log mutex. Replay after reconnect must deliver each stored event exactly once, in order. Don't add a second numbering scheme.

**Approval gating.** Every tool requires approval (`Permissions.requires_approval?` is unconditionally true in the POC). Denied calls never execute — no `before_tool_call`/`after_tool_result` callbacks run for them; the loop emits their `tool_output` itself. Approval frames are emitted from the loop (not RubyLLM's callback) because the callback fires after execution.

**Process-group kills.** The bash tool spawns with `bash -c` + `pgroup: true`. Never switch to `bash -lc`: a login shell enables job control, putting the command in its own pgid that the group-KILL misses. Cancel and shutdown rely on `Permissions.kill_group`/`kill_all!` (TERM, then KILL after 2 s). Signal the group as `Process.kill("TERM", -pid)` — on Ruby 4 the `"-TERM"` + negative-pid double negative raises `Errno::EINVAL`.

**Shutdown.** `config.ru` traps INT/TERM and also runs at `at_exit` (Falcon's `--no-restart` keeps workers alive for it). Both paths must keep killing tool process groups and closing bridges; losing either leaks subprocesses or hangs workers.

**System prompt.** `with_instructions` REPLACES the system message by default (`append: false`), so rebuilding AGENTS.md + persona fresh every turn is safe on a reused chat. Don't "optimize" it to append.

**Auth.** Server rejects bad bearer tokens and any browser `Origin` header (403); bind is loopback-only. Any new route must go through `authorized?`.

**Sessions are per-process.** `Server::App::SESSIONS` is a plain in-memory Hash; `attach_session` silently creates a blank session on a cache miss. With `serve --count N` (N > 1) a reconnect can land on a worker that lacks the session and replay nothing, with no error — `--count 1` is the only supported mode until sessions are shared or persisted across workers. `serve` also runs Falcon with `--no-restart`: a crashed worker stays down until someone restarts the server.

## Gotchas

- A blocking `chat.ask` in an async fiber corrupts concurrent WS frame reads — this is why the two-world split exists; don't unify them.
- An `Async` block waits for child tasks at block end; a never-ending watcher child hangs exit unless you `task.stop` it.
- Falcon silently falls back to a default app when `--config` points at a missing file — "server boots" is not proof your config loaded.
- RubyLLM 2.1.1: streaming chunks may carry `nil` content; `chat.cancel` is a cross-thread flag that raises `RubyLLM::CancelledError` at the next checkpoint; approval state is polled via `complete?`/`waiting?`/`awaiting_approval?`/`pending_approvals`.
- This file is consumed by brewster itself under a 16 000-char budget shared with any other AGENTS.md up the tree — keep it lean.
