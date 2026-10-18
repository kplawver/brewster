# brewster

A proof-of-concept coding harness in Ruby: a local LLM agent loop with approval-gated tools, streamed over WebSocket to a terminal client. Not production software.

## How it works

```
user ──stdin──▶ client ──WS frame──▶ WS task (Falcon fiber)
                                        │ commands (send/approve/deny/cancel)
                                        ▼
                                     Queue ──▶ turn thread (AgentLoop + RubyLLM)
                                                 │ emit
                              EventLog ◀─────────┤
                              (JSONL, seq = line number)
                                                 │
                              Bridge pipes ◀─────┘
                                                 │
              client renderer ◀── WS frames ◀── WS task (only writer)
```

- **Server** (Falcon + Sinatra): binds `127.0.0.1` only, checks a bearer token and rejects browser `Origin` headers. WS IO runs on Falcon fibers; the agent turn runs on a plain thread (a blocking `chat.ask` inside a fiber starves the reactor). Events fan out thread→fibers through per-subscriber pipes.
- **Agent loop** ([RubyLLM](https://github.com/crmne/ruby_llm)): streams deltas; every tool call pauses for approval. Denying feeds the model a structured denial result; cancelling raises at the next checkpoint and kills the running tool's process group (TERM → KILL escalation).
- **Tools**: `read`, `write`, `edit`, `bash` — every call requires approval. `bash` runs in its own process group with per-stream 64 KiB and 256 KiB total output caps.
- **Sessions**: append-only JSONL log per session (`$BREWSTER_HOME/sessions/<id>.jsonl`); `seq` is the line number, 1-based, never reused. Reconnect replays `each_since(last_seq)` exactly once, in order; a 64-line ring buffer covers late attachers.
- **Context**: `AGENTS.md` files are rebuilt every turn — nearest-first from cwd to the git root (inclusive), then `~/.agents/AGENTS.md`, 16 000-char budget with a truncation marker.

## Requirements

- Ruby 4.0.5 (pinned in `Gemfile` and `.mise.toml`; `mise install`)
- Bundler (`bundle install`)

## Configuration

| Variable | Required | Meaning |
|---|---|---|
| `BREWSTER_LLM_BASE_URL` | serve | OpenAI-compatible endpoint base URL |
| `BREWSTER_LLM_API_KEY` | serve | API key for that endpoint |
| `BREWSTER_LLM_MODEL` | serve | Model name |
| `BREWSTER_HOME` | no | Data dir (default `~/.brewster`) |
| `BREWSTER_FAKE_CHAT=1` | no | Swap in a scripted no-network chat (echoes input) |

`serve` exits non-zero if any required variable is missing.

## Usage

```sh
bin/brewster serve [--port 7333] [--count 1]
bin/brewster chat  [--port 7333] [--session <id>]
```

`--count N` starts N Falcon workers, but sessions live in a per-process in-memory hash (`Server::App::SESSIONS`), so with N > 1 a reconnect that lands on another worker silently attaches to a fresh empty session under the same id — reattach/replay break with no error. **Use `--count 1` until sessions are shared across workers.**

First `serve` creates the data dir and a token at `$BREWSTER_HOME/token` (mode 0600). `chat` reads the same file, so server and client must share a home. Without `--session`, each client gets a fresh session; pass a previous id to reattach and replay its transcript.

Client keys: Enter sends, Ctrl-J inserts a newline, bracketed paste works, history with arrows. Ctrl-C cancels the running turn; a second Ctrl-C within 2 s quits. Ctrl-D quits when the input line is empty. The terminal state is restored on exit.

## Wire protocol

One JSON object per WebSocket text frame.

- Server → client events: `attached`, `user_message`, `text_delta`, `tool_call`, `tool_output`, `approval_request`, `turn_done`, `error` — with `seq`, `session_id`, `ts`.
- Client → server commands: `attach` (`session_id`, `last_seq`), `send`, `approve`, `deny`, `cancel`.

## Development

```sh
bundle exec rspec                 # full suite (random order; prints the seed)
bundle exec rspec spec/...        # single file
BREWSTER_FAKE_CHAT=1 ...            # e2e paths without network
```

See [AGENTS.md](AGENTS.md) for architecture notes and invariants before changing the concurrency or shutdown paths.

## License

MIT — see [LICENSE](LICENSE).
