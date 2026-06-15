# Multi-Agent LLM Trace Capture

Capture the **full request + response** — including extended-thinking / reasoning
content — of your coding agents, automatically, into per-agent folders on disk.

Works with **Claude Code**, **Codex**, and **OpenCode**. A small local
pass-through proxy sits between the agent and the model API: it streams every
response back untouched (no latency hit) and writes a copy to disk on the way
through.

```
agent  ──►  127.0.0.1:<port>  ──►  upstream API (Anthropic / OpenAI / Friendli / …)
(traced)        trace_proxy            (response streamed back byte-for-byte)
                   │
                   └─► writes  <ts>_<id>.request.json / .response.json / .response.sse
```

| Agent        | Port   | Traces land in                 | Wire format           | Proxy runs… |
|--------------|--------|--------------------------------|-----------------------|-------------|
| Claude Code  | `8788` | `~/fai-traces/claude-traces`   | Anthropic Messages    | always-on   |
| Codex        | `8789` | `~/fai-traces/codex-traces`    | OpenAI Chat/Responses | on-demand   |
| OpenCode     | `8790` | `~/fai-traces/opencode-traces` | Anthropic Messages    | on-demand   |

### Why Claude is always-on but Codex/OpenCode are on-demand

Claude Code **hard-fails with no retry** if its API base URL is unreachable, and
it reads that base URL from `settings.json` for both the terminal *and* the IDE
extension. So its proxy must always be up — it runs as a tiny background service
(one idle async process, ~0% CPU).

Codex and OpenCode are routed **per-launch** by their wrappers, which start the
proxy on demand and let it **self-stop after 30 min idle**. Launching them
*without* the wrapper just runs them normally (untraced) — so a stopped proxy
never breaks them. Net effect: nothing runs unless you actually use it, and only
the always-critical Claude proxy stays resident.

---

## Quick start

```bash
cd tracing-setup
./setup.sh
# then open a new terminal (or: source ~/.zshrc)
```

> Installing restarts the Claude proxy, so any **active** Claude session
> (terminal or IDE) will briefly disconnect. Run `setup.sh` when nothing is
> mid-task.

Use your agents exactly as before — `claude`, `codex`, `opencode`. Verify:

```bash
fai-trace status        # which proxy ports are up
claude -p "say hi"      # then look in ~/fai-traces/claude-traces
```

### Options

```bash
./setup.sh --friendli           # route every agent through the Friendli Model API (see below)
./setup.sh --codex --opencode   # force-wire both even if not auto-detected
./setup.sh --skip-codex         # leave Codex's config untouched
./setup.sh --no-service         # terminal-only Claude (IDE NOT traced, no daemon)
./setup.sh --service-all        # always-on service serves ALL three (heavy IDE users)
```

Re-running is safe and idempotent — every config file is backed up to
`<file>.pre-cc-trace.bak`, existing keys are preserved, the shell snippet is
replaced in place (never duplicated), and any base URL a previous version
injected is migrated to the current scheme.

Codex needs an API key: `export OPENAI_API_KEY=sk-...` (see the Codex section).

---

## What gets installed / changed

Everything lives under `~/.cc-trace/` (override with `CC_TRACE_HOME`):

```
~/.cc-trace/
  trace_proxy.py        the proxy
  venv/                 its Python deps (httpx, starlette, uvicorn)
  profiles.json         port → upstream → trace-dir → format, per agent
  claude.upstream       real upstream, for the --tracing=none bypass
  opencode-trace.json   layered OpenCode config the wrapper applies
  proxy.log             always-on Claude proxy log
  codex.log/opencode.log on-demand proxy logs
  fai-trace             management command
  fai-trace-up          on-demand launcher used by the wrappers
  friendli.key          Friendli key (only in --friendli mode; chmod 600)
```

Config files modified (each backed up first):

- `~/.claude/settings.json` — `env.ANTHROPIC_BASE_URL`, `env.ENABLE_TOOL_SEARCH`,
  `showThinkingSummaries: true`. (`--no-service` removes the base URL instead.)
- `~/.codex/config.toml` — adds a `[model_providers.fai-trace]` + `[profiles.fai-trace]`
  (only if Codex is wired). Your default `codex` is untouched.
- OpenCode: your `opencode.json` is **not** modified (a layered trace config is
  applied per-launch via `OPENCODE_CONFIG`).
- Shell rc (`~/.zshrc` / `~/.bashrc`) — a `# >>> cc-trace >>>` block adding
  `~/.cc-trace` to `PATH` and defining `claude` / `codex` / `opencode` wrappers.

Background service (Claude only, unless `--service-all`):

- **macOS** — `~/Library/LaunchAgents/ai.friendli.cc-trace.plist` (launchd).
- **Linux** — `~/.config/systemd/user/cc-trace.service` (systemd user).

---

## Turning tracing off

Per launch (works for all three agents):

```bash
claude --tracing=none      # this run talks to the real upstream directly
codex  --tracing=none      # runs your normal, untraced codex
opencode --tracing=none
CC_TRACE=off claude        # env form, same effect
```

Globally:

```bash
fai-trace stop             # stop every proxy (Claude included)
# or remove the service entirely:
launchctl bootout gui/$(id -u)/ai.friendli.cc-trace     # macOS
systemctl --user disable --now cc-trace.service         # Linux
```

---

## Using with the Friendli Model API

Many people run these agents against the **Friendli Model API**. One command
points all three at Friendli and traces them:

```bash
./setup.sh --friendli
# prompts for your Friendli API key + model id (e.g. zai-org/GLM-5.1),
# or read them from the env non-interactively:
FRIENDLI_API_KEY=flp_... FRIENDLI_MODEL=zai-org/GLM-5.1 ./setup.sh --friendli --codex --opencode
```

What it does:

- Sets every profile's `upstream` to `https://api.friendli.ai/serverless`
  (Friendli's endpoint is Anthropic-Messages-compatible for Claude/OpenCode and
  OpenAI-compatible for Codex).
- Stores your key once and has the **proxy inject it** as the upstream
  `Authorization` header — so you don't configure a Friendli key inside each
  agent. (The key is never written into saved traces.)
- Sets the chosen model: Claude `model`, Codex `[profiles.fai-trace] model`,
  OpenCode `model` (`anthropic/<id>`).

Then just use `claude` / `codex` / `opencode` as usual; traces land in
`~/fai-traces/...` as always. To switch the model later, edit each agent's config
(or re-run `./setup.sh --friendli`). To change only the upstream/key live without
a re-run:

```bash
curl -X POST 127.0.0.1:8788/cc-trace/config \
  -H 'content-type: application/json' \
  -d '{"upstream":"https://api.friendli.ai/serverless","auth_token":"flp_..."}'
```

Notes:
- This is built on the official integration guides
  ([Claude Code](https://friendli.ai/docs/integrate/agents/claude-code),
  [OpenCode](https://friendli.ai/docs/integrate/agents/opencode)); the difference
  is that traffic goes through the local proxy first so it's captured.
- Codex: if your Friendli model rejects Chat Completions, set `wire_api = "responses"`
  in `~/.codex/config.toml`.
- To go back to direct providers, re-run `./setup.sh` without `--friendli`.

---

## Per-agent details

### Claude Code

Routed via `~/.claude/settings.json`, so the terminal **and** the VSCode /
JetBrains extension are both traced (they share that file). Confirmed to capture
`thinking` blocks (with signature), `tool_use` blocks (with reconstructed input),
text, and usage.

```bash
claude -p "say hi"
ls ~/fai-traces/claude-traces
```

### Codex

Codex's built-in `openai` provider, pointed at a custom base URL, tries a
**WebSocket first and drops the auth header when it falls back to HTTP** → 401s
([codex#15492](https://github.com/openai/codex/issues/15492)). To avoid that, we
add a **custom provider that uses plain HTTP**, opted into via a profile:

```toml
[model_providers.fai-trace]
name = "FAI Trace (proxy)"
base_url = "http://127.0.0.1:8789/v1"
env_key = "OPENAI_API_KEY"
wire_api = "chat"          # switch to "responses" if your model requires it
[profiles.fai-trace]
model_provider = "fai-trace"
```

The `codex` wrapper runs `codex --profile fai-trace`. Requirements:

- **API key:** `export OPENAI_API_KEY=sk-...` (a key with Chat/Responses access).
  Codex silently prefers `OPENAI_API_KEY` over ChatGPT login, so this is what the
  traced provider uses.
- **ChatGPT-subscription login is not traceable** this way — it talks to ChatGPT's
  backend, not `api.openai.com`. Use an API key for traced Codex.
- If your model rejects Chat Completions, change `wire_api` to `"responses"` in
  `~/.codex/config.toml` (the proxy decodes both).
- Friendli/other gateway: set that profile's `upstream` in `profiles.json` and
  `fai-trace restart`.

Verify: `codex` (via wrapper) on a small task, then check `~/fai-traces/codex-traces`.

### OpenCode

OpenCode's Anthropic provider (Vercel AI SDK) appends `/messages` to `baseURL`,
so the base URL **must end in `/v1`** or you get `POST /messages → 404`
([opencode#5163](https://github.com/anomalyco/opencode/issues/5163)). The wrapper
applies a layered config (`OPENCODE_CONFIG`) with `baseURL: http://127.0.0.1:8790/v1`
— your own `opencode.json` is left alone.

> If OpenCode returns 401 "no API key" with a custom baseURL, that's a known
> OpenCode bug with `@ai-sdk/anthropic`
> ([opencode#21737](https://github.com/anomalyco/opencode/issues/21737)). Tracing
> itself is unaffected — the proxy forwards whatever auth the agent sends.

Verify: `opencode` (via wrapper), then check `~/fai-traces/opencode-traces`.

---

## Other agents (manual, partial)

### Cursor — chat/plan panel only

Cursor's custom base URL is honored **only by its chat/plan panel**; Composer,
inline edit/apply, and Tab stay on Cursor's backend and **cannot be traced**.

1. Add a `cursor` profile to `~/.cc-trace/profiles.json`
   (`{ "port": 8791, "upstream": "https://api.openai.com", "trace_dir": "~/fai-traces/cursor-traces", "format": "openai" }`)
   and run it: `~/.cc-trace/venv/bin/python ~/.cc-trace/trace_proxy.py --only cursor &`
2. Cursor → Settings → Models → **Override OpenAI Base URL** → `http://127.0.0.1:8791/v1`
   (include `/v1`), set an OpenAI key, verify.

### GitHub Copilot — not supported

Copilot has **no supported custom endpoint**; intercepting it requires a
system-wide HTTPS MITM with a trusted CA cert, and bulk traffic through that can
trip GitHub's abuse-detection and suspend your access. We deliberately don't wire
it up — use a supported agent for traced completions.

---

## Edge cases & troubleshooting

### Figma (and other MCP plugins) "don't work with tracing"

**Fixed.** The old approach required launching `claude-trace` instead of `claude`;
the IDE extension calls the real `claude` binary, so the wrapper never applied
there and people couldn't have Figma/MCP in the IDE *and* tracing. Now tracing is
configured in `settings.json`, which the terminal and IDE both read — plain
`claude` is always traced, no conflicting wrapper.

Also, **`ANTHROPIC_BASE_URL` does not affect MCP connections** — MCP servers
(Figma, GitHub, …) connect independently, so the proxy never touches them. (Setup
sets `ENABLE_TOOL_SEARCH=true` because a non-first-party base URL otherwise
disables MCP tool search.) If an MCP plugin still misbehaves, it's unrelated to
tracing — confirm with `claude --tracing=none`.

### A Claude session disconnected for a second

Restarting the Claude proxy (`fai-trace restart`, re-running `setup.sh`, or anything
that bounces the service) briefly drops port 8788, and Claude Code has no
connection retry — so an in-flight request can fail. Restart the proxy only when
no Claude session is mid-task. (This is also why `setup.sh` warns before
installing.)

### VSCode / JetBrains extension

Covered automatically (shares `settings.json`) **as long as the Claude service is
running** — which it is by default. With `--no-service`, the IDE is not traced
(only the terminal wrapper is). Use `--service-all` if you also want Codex/OpenCode
traced inside IDEs.

### Login / authentication

Auth is untouched: the proxy forwards every header (OAuth token, `x-api-key`,
`Authorization`) as-is. API keys are **redacted from the saved trace files** (not
from the live request), so traces are safe to share.

### `fai-trace status` shows a port down / agent can't connect

```bash
fai-trace status        # claude should be UP; codex/opencode "down" is normal until used
fai-trace logs [agent]  # tail the log; look for "could not serve … port in use"
fai-trace restart       # restart Claude service + clear on-demand proxies
```

A port already in use only disables that one profile — the others keep serving.
To change a port, edit `~/.cc-trace/profiles.json` (and the matching base URL in
the agent's config), then `fai-trace restart`.

### Reasoning / thinking isn't in the trace

`showThinkingSummaries: true` (set by setup) makes Claude return summarized
reasoning. Trivial prompts may legitimately produce none. The raw `.response.sse`
always holds the exact stream as ground truth.

### Using Friendli or another upstream

Each profile has its own `upstream` in `profiles.json`. Change it live without a
restart:

```bash
curl -X POST 127.0.0.1:8788/cc-trace/config \
  -H 'content-type: application/json' \
  -d '{"upstream":"https://api.friendli.ai/serverless"}'
```

For providers that reject `thinking.display`, add `"strip_thinking_display": true`
to that profile. `inject_fields` merges extra JSON into every model call. See
`claude_friendli_setup.sh` for switching Claude's account to Friendli.

### Uninstall

```bash
fai-trace stop
launchctl bootout gui/$(id -u)/ai.friendli.cc-trace 2>/dev/null   # macOS
systemctl --user disable --now cc-trace.service 2>/dev/null       # Linux
# restore configs from the .pre-cc-trace.bak backups, remove the
# "# >>> cc-trace >>>" block from your shell rc, and delete ~/.cc-trace
```

---

## Reference

### `fai-trace` command

```
fai-trace status         # UP/down per profile port
fai-trace logs [agent]   # tail -f a proxy log (default: claude/proxy.log)
fai-trace restart        # restart Claude service; clear on-demand proxies
fai-trace stop           # stop everything
fai-trace dirs           # print the trace directories
```

### `profiles.json`

```json
{
  "claude":   { "port": 8788, "upstream": "https://api.anthropic.com", "trace_dir": "~/fai-traces/claude-traces",   "format": "anthropic" },
  "codex":    { "port": 8789, "upstream": "https://api.openai.com",     "trace_dir": "~/fai-traces/codex-traces",    "format": "openai" },
  "opencode": { "port": 8790, "upstream": "https://api.anthropic.com", "trace_dir": "~/fai-traces/opencode-traces", "format": "anthropic" }
}
```

Per-profile optional keys: `strip_thinking_display` (bool), `inject_fields`
(object), `auth_token` (string — when set, the proxy rewrites the upstream
`Authorization` header to `Bearer <auth_token>`, used by `--friendli` mode).

### Proxy endpoints (per port)

- `GET  /cc-trace/health` — status + live config (not traced)
- `POST /cc-trace/config` — update `upstream` / `strip_thinking_display` /
  `inject_fields` at runtime, no restart
- everything else — forwarded to the upstream and traced

### Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `CC_TRACE_HOME` | `~/.cc-trace` | install dir |
| `CC_TRACE_ROOT` | `~/fai-traces` | parent of the per-agent trace dirs (setup time) |
| `CC_TRACE_PROFILES` | `$CC_TRACE_HOME/profiles.json` | profiles file |
| `CC_TRACE_ONLY` | (all) | comma-separated profiles to serve (also `--only` CLI) |
| `CC_TRACE_IDLE_TIMEOUT` | `0` proxy / `1800` on-demand | seconds idle before self-stop (0 = never) |
| `CC_TRACE_REDACT` | `1` | redact API keys in saved traces |
| `CC_TRACE_MAX_AGE_DAYS` / `CC_TRACE_MAX_FILES` | `0` (off) | trace rotation |
| `CC_TRACE_NO_LAUNCHCTL` | `0` | skip all launchctl/systemctl calls (testing safety) |
| `CC_TRACE_PORT_CLAUDE` / `_CODEX` / `_OPENCODE` | 8788/8789/8790 | ports (setup time) |

### Trace file layout

Per model call `<timestamp>_<id>`:

- `.request.json` — full request (API keys redacted)
- `.response.json` — reconstructed response (text + reasoning/thinking, tool calls, usage)
- `.response.sse` — raw server-sent-events stream, ground truth

### Tests

```bash
cd tracing-setup
~/.cc-trace/venv/bin/python test_proxy.py    # or: python3 test_proxy.py
```

Starts a mock upstream emitting all three wire formats and asserts byte-identical
streaming, incremental (non-buffered) delivery, reconstruction with reasoning,
per-agent directory isolation, redaction, and the health/config endpoints — no
real API keys required. Uses isolated ports (8801–8803), so it won't disturb a
live install.
