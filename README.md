# Multi-Agent LLM Trace Capture

Capture the **full request + response** — including extended-thinking / reasoning
content — of your coding agents, automatically, into per-agent folders on disk.

Works with **Claude Code**, **Codex**, and **OpenCode** out of the box. A small
local pass-through proxy sits between the agent and the model API: it streams
every response back untouched (so there's no latency hit) and writes a copy to
disk on the way through.

```
agent  ──►  127.0.0.1:<port>  ──►  upstream API (Anthropic / OpenAI / Friendli / …)
(traced)        trace_proxy            (response streamed back byte-for-byte)
                   │
                   └─► writes  <ts>_<id>.request.json / .response.json / .response.sse
```

| Agent        | Default port | Traces land in     | Wire format            |
|--------------|--------------|--------------------|------------------------|
| Claude Code  | `8788`       | `~/claude-traces`  | Anthropic Messages     |
| Codex        | `8789`       | `~/codex-traces`   | OpenAI Chat/Responses  |
| OpenCode     | `8790`       | `~/opencode-traces`| Anthropic Messages     |

---

## Quick start

```bash
cd tracing-setup
./setup.sh
# then open a new terminal (or: source ~/.zshrc)
```

That's it. Use your agents exactly as before — `claude`, `codex`, `opencode` —
and traces appear automatically. **No `claude-trace` to remember.**

To check it's working:

```bash
cc-trace status        # shows which proxy ports are UP
claude -p "say hi"     # then look in ~/claude-traces
```

### Wiring extra agents

`setup.sh` auto-detects Codex and OpenCode (by their CLI or config dir). To force
or skip:

```bash
./setup.sh --codex --opencode      # wire both even if not detected
./setup.sh --skip-codex            # leave Codex's config untouched
./setup.sh --no-service            # don't install the background service
```

Re-running `setup.sh` is safe and idempotent — every config file it touches is
backed up first to `<file>.pre-cc-trace.bak`, existing keys are preserved, and
the shell snippet is replaced in place (never duplicated).

---

## What gets installed / changed

Everything lives under `~/.cc-trace/` (override with `CC_TRACE_HOME`):

```
~/.cc-trace/
  trace_proxy.py        the proxy
  venv/                 its Python deps (httpx, starlette, uvicorn)
  profiles.json         port → upstream → trace-dir → format, per agent
  claude.upstream       real upstream, for the --tracing=none bypass
  proxy.log             proxy stdout/stderr
  claude-trace          back-compat always-traced launcher
  cc-trace              management command (status/logs/restart/dirs)
```

Config files modified (each backed up first):

- `~/.claude/settings.json` — adds `env.ANTHROPIC_BASE_URL`,
  `env.ENABLE_TOOL_SEARCH`, `showThinkingSummaries: true`.
- `~/.codex/config.toml` — adds `openai_base_url` (only if Codex is wired).
- `~/.config/opencode/opencode.json` — sets `provider.anthropic.options.baseURL`
  (only if OpenCode is wired).
- Your shell rc (`~/.zshrc` / `~/.bashrc`) — a `# >>> cc-trace >>>` block adding
  `~/.cc-trace` to `PATH` and defining the `claude` shell function.

Background service so the proxy is always running (covers the IDE too):

- **macOS** — `~/Library/LaunchAgents/ai.friendli.cc-trace.plist` (launchd,
  starts at login, restarts on crash).
- **Linux** — `~/.config/systemd/user/cc-trace.service` (systemd user service).

---

## Turning tracing off

Tracing is on by default. To bypass the proxy for **one** Claude Code launch:

```bash
claude --tracing=none      # this run talks to the real upstream directly
CC_TRACE=off claude        # same thing, via env var
```

To turn it off globally, either stop the service or remove the base URL:

```bash
# macOS
launchctl bootout gui/$(id -u)/ai.friendli.cc-trace
# Linux
systemctl --user disable --now cc-trace.service
```

(Editing `~/.claude/settings.json` to drop `ANTHROPIC_BASE_URL` also disables it
for both terminal and IDE.)

---

## Per-agent details

### Claude Code

Wired via `~/.claude/settings.json` `env` block, so **both the terminal CLI and
the VSCode / JetBrains extension** route through the proxy — they share that file.
No wrapper needed.

Verify:

```bash
claude -p "say hi"
ls ~/claude-traces      # newest *.response.json should contain your reply
```

### Codex

Wired via `openai_base_url` in `~/.codex/config.toml`, pointed at
`http://127.0.0.1:8789/v1`. This is the supported way to redirect Codex's
built-in `openai` provider (overriding `[model_providers.openai]` directly is
ignored by Codex). Codex's default provider uses the OpenAI **Responses API**;
the proxy decodes both Responses and Chat Completions formats.

Verify: run `codex` on a small task, then check `~/codex-traces`.

### OpenCode

Wired via `provider.anthropic.options.baseURL` in `opencode.json`, pointed at
`http://127.0.0.1:8790`. A minimal `models` block is added because newer OpenCode
versions reject a provider config without one.

> If OpenCode returns a 401 "no API key" with a custom `baseURL`, you've hit a
> known OpenCode bug with `@ai-sdk/anthropic` + custom base URLs. Workaround:
> define an OpenAI-compatible provider instead, or pin an OpenCode version where
> it works. Tracing itself is unaffected — the proxy forwards whatever auth the
> agent sends.

Verify: run `opencode`, then check `~/opencode-traces`.

---

## Other agents (manual, partial)

### Cursor — chat/plan panel only

Cursor can point at a custom endpoint, **but only its chat/plan panel honors it.**
Composer (the coding agent), inline edit/apply, and Tab autocomplete are locked to
Cursor's own backend and **cannot be traced** — those requests never leave
Cursor's servers in a form you can intercept.

To trace the chat panel:

1. Add a `cursor` profile to `~/.cc-trace/profiles.json`, e.g.
   `{ "port": 8791, "upstream": "https://api.openai.com", "trace_dir": "~/cursor-traces", "format": "openai" }`
   and `cc-trace restart`.
2. Cursor → Settings → Models → **Override OpenAI Base URL** → `http://127.0.0.1:8791/v1`
   (include `/v1`; Cursor appends `/chat/completions`), set an OpenAI API key, and verify.

What you get: chat-panel prompts/responses in `~/cursor-traces`. What you don't:
anything from Composer/agent/apply/Tab. There is no workaround — it's a Cursor
architectural limitation, not a proxy limitation.

### GitHub Copilot — not supported

Copilot has **no supported custom-endpoint setting**; it connects to
`api.githubcopilot.com` with its own client. The only way to intercept it is a
system-wide HTTPS MITM proxy with a locally-trusted CA certificate — which is
fragile, and bulk/automated traffic through such a setup can trip GitHub's
abuse-detection and get your Copilot access suspended. **We deliberately do not
wire this up.** If you need traced completions, use one of the supported agents
above instead.

---

## Edge cases & troubleshooting

### Figma (and other MCP plugins) "don't work with tracing"

**This is fixed by the new setup.** The old approach required launching
`claude-trace` instead of `claude`. The IDE extension always calls the real
`claude` binary, so the wrapper never applied there — and people couldn't use
Figma/MCP in the IDE *and* have tracing. The terminal had the same wrapper
friction.

Now tracing is configured in `settings.json`, which the terminal **and** the IDE
extension both read, so plain `claude` is always traced and there's no wrapper to
conflict with.

Separately: **`ANTHROPIC_BASE_URL` does not affect MCP connections.** MCP servers
(Figma, GitHub, etc.) connect directly and independently of the model API. The
proxy only ever sees model calls, so MCP plugins behave exactly as they do
without it. (One subtlety: a non-first-party base URL disables MCP *tool search*
by default — setup sets `ENABLE_TOOL_SEARCH=true` to preserve normal behavior.)

If an MCP plugin still misbehaves, it is unrelated to tracing — confirm by
running `claude --tracing=none` and reproducing.

### VSCode / JetBrains extension

Covered automatically — the extension reads the same `~/.claude/settings.json`.
For this to work the proxy must be running, which the background service ensures.
If the IDE isn't being traced, check `cc-trace status`; if the proxy is down, see
below.

### Login / authentication

Auth is untouched. The proxy forwards every header (OAuth token, `x-api-key`,
`Authorization`) to the upstream as-is. Logging in, switching accounts, and
`/login` all work normally. API keys are **redacted from the saved trace files**
(not from the live request) so traces are safe to share.

### `cc-trace status` shows a port DOWN / agent can't connect

The proxy probably isn't running, or that port is taken.

```bash
cc-trace status          # which ports are up
cc-trace logs            # tail proxy.log (look for "could not serve … port in use")
cc-trace restart         # bounce the service
```

If a port is already in use by something else, change it in
`~/.cc-trace/profiles.json`, update the matching agent config (e.g. the
`ANTHROPIC_BASE_URL` in `settings.json`), and `cc-trace restart`. A single port
conflict only disables that one profile — the others keep serving.

### Reasoning / thinking isn't in the trace

For Claude, `showThinkingSummaries: true` (set by setup) makes the API return
summarized reasoning. Trivial prompts may legitimately produce no thinking
(`thinking_tokens: 0`). The raw `.response.sse` always holds the exact stream as
ground truth if reconstruction ever misses something.

### Using Friendli or another upstream

Each profile has its own `upstream` in `profiles.json`. Point the `claude`
profile at Friendli and restart, or change it live without a restart:

```bash
curl -X POST 127.0.0.1:8788/cc-trace/config \
  -H 'content-type: application/json' \
  -d '{"upstream":"https://api.friendli.ai/serverless"}'
```

For non-Anthropic providers that reject `thinking.display`, add
`"strip_thinking_display": true` to that profile (or POST it to `/cc-trace/config`).
`inject_fields` merges extra JSON into every model call. See
`claude_friendli_setup.sh` for switching Claude Code's account to Friendli; set
that profile's `upstream` to the Friendli URL so it's traced.

### Uninstall

```bash
# stop + remove the service
launchctl bootout gui/$(id -u)/ai.friendli.cc-trace 2>/dev/null   # macOS
systemctl --user disable --now cc-trace.service 2>/dev/null       # Linux
# restore configs from the .pre-cc-trace.bak backups, remove the
# "# >>> cc-trace >>>" block from your shell rc, and delete ~/.cc-trace
```

---

## Reference

### `cc-trace` command

```
cc-trace status      # UP/DOWN per profile port
cc-trace logs [N]    # tail -f the proxy log (default 40 lines)
cc-trace restart     # restart the proxy (service or lazy)
cc-trace dirs        # print the trace directories
```

### `profiles.json`

```json
{
  "claude":   { "port": 8788, "upstream": "https://api.anthropic.com", "trace_dir": "~/claude-traces",   "format": "anthropic" },
  "codex":    { "port": 8789, "upstream": "https://api.openai.com",     "trace_dir": "~/codex-traces",    "format": "openai" },
  "opencode": { "port": 8790, "upstream": "https://api.anthropic.com", "trace_dir": "~/opencode-traces", "format": "anthropic" }
}
```

Per-profile optional keys: `strip_thinking_display` (bool), `inject_fields` (object).

### Proxy endpoints (per port)

- `GET  /cc-trace/health` — status + live config (not traced)
- `POST /cc-trace/config` — update `upstream` / `strip_thinking_display` /
  `inject_fields` at runtime, no restart
- everything else — forwarded to the upstream and traced

### Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `CC_TRACE_HOME` | `~/.cc-trace` | install dir |
| `CC_TRACE_PROFILES` | `$CC_TRACE_HOME/profiles.json` | profiles file |
| `CC_TRACE_REDACT` | `1` | redact API keys in saved traces |
| `CC_TRACE_MAX_AGE_DAYS` | `0` (off) | delete traces older than N days |
| `CC_TRACE_MAX_FILES` | `0` (off) | keep at most N requests per profile |
| `CC_TRACE_PORT_CLAUDE` / `_CODEX` / `_OPENCODE` | 8788/8789/8790 | ports (setup time) |
| `CC_TRACE_DIR_CLAUDE` / `_CODEX` / `_OPENCODE` | `~/<agent>-traces` | trace dirs (setup time) |

### Trace file layout

For each model call `<timestamp>_<id>`:

- `.request.json` — the full request (API keys redacted)
- `.response.json` — reconstructed response object (text + reasoning/thinking,
  tool calls, usage)
- `.response.sse` — the raw server-sent-events stream, as ground truth

### Tests

```bash
cd tracing-setup
~/.cc-trace/venv/bin/python test_proxy.py    # reuse the venv setup.sh created
# or, with httpx/starlette/uvicorn already available:
python3 test_proxy.py
```

The harness starts a mock upstream emitting all three wire formats and asserts
byte-identical streaming, incremental (non-buffered) delivery, correct
reconstruction with reasoning, per-agent directory isolation, redaction, and the
health/config endpoints — no real API keys required.
