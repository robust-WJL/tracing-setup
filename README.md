# Multi-Agent LLM Trace Capture

Capture the **full request + response** — including extended-thinking / reasoning
and the request **headers** (session / sub-agent ids) — of your coding agents,
into per-agent folders on disk.

You **choose which agents to trace** when you run `setup.sh`. Only those are
wired and kept traced by a single always-on local proxy; the rest are left
normal. To change the selection, just re-run `setup.sh`. There are **no shell
wrappers, profiles, or per-launch flags** — each agent is routed purely by its
own persistent config.

```
agent ──► 127.0.0.1:<port> ──► the provider you actually use ──► response streamed back byte-for-byte
(traced)     trace_proxy          (upstream encoded per-request; nothing hardcoded)
                 └─► writes  <ts>_<id>.request.json / .request.headers.json / .response.json / .response.sse
```

| Agent       | Port   | Traces in                      | How it's routed |
|-------------|--------|--------------------------------|-----------------|
| Claude Code | `8788` | `~/fai-traces/claude-traces`   | `ANTHROPIC_BASE_URL` in `~/.claude/settings.json` |
| Codex       | `8789` | `~/fai-traces/codex-traces`    | `model_provider` → traced provider in `~/.codex/config.toml` (OpenAI API key) |
| OpenCode    | `8790` | `~/fai-traces/opencode-traces` | per-provider `baseURL` in `~/.config/opencode/opencode.json` |

---

## Quick start

```bash
cd tracing-setup
./setup.sh                  # interactive — pick agents
# or non-interactive:
./setup.sh claude codex opencode      # trace these
./setup.sh all                        # all three
./setup.sh claude --friendli          # route Claude through the Friendli Model API
```

> Installing restarts the proxy, so any **active** Claude session (terminal or
> IDE) briefly disconnects. Run it when nothing is mid-task.

Then use `claude` / `codex` / `opencode` normally — no special command. Verify:

```bash
fai-trace status
claude -p "say hi" ; ls ~/fai-traces/claude-traces
```

To trace a **different** set later, re-run `./setup.sh <agents>` — agents you
drop are reverted to normal; agents you add are wired.

---

## How it works

- **One always-on proxy** serves exactly the agents you chose (launchd on macOS,
  systemd-user on Linux). One idle async process per agent (~0% CPU). It must be
  up because the agents' configs point at it — so it's a service, not on-demand.
- **No pinned upstream.** Codex and OpenCode talk to whatever provider/model you
  pick. Their base URL is rewritten to
  `http://127.0.0.1:<port>/__cc__/<base64 of the provider's real API>`; the proxy
  decodes the real upstream per request and forwards there. Wire format is
  auto-detected (`/messages`→Anthropic, `/chat/completions` or `/responses`→OpenAI).
  Claude is single-provider, so it uses a fixed upstream (Anthropic, or Friendli
  with `--friendli`).
- **Headers are saved** (`*.request.headers.json`, auth redacted) — they carry the
  session / sub-agent ids that aren't in the payload.

---

## Per-agent notes

### Claude Code
Routed via `~/.claude/settings.json`, so the terminal **and** the VSCode /
JetBrains extension are both traced. Captures `thinking` (with signature),
`tool_use` (with reconstructed input), text, and usage. Verified: 100+ multi-turn
calls in one session.

### Codex  *(tested with 0.139 — requires an OpenAI API key)*
Setup adds a traced provider and sets `model_provider` in `~/.codex/config.toml`,
so all Codex traffic routes through the proxy to `api.openai.com` over plain HTTP
(a custom provider, so the built-in WebSocket auth-drop bug
[codex#15492](https://github.com/openai/codex/issues/15492) doesn't apply).

**Prerequisites:** `export OPENAI_API_KEY=sk-...` and a model your key can access
(set `model` in `~/.codex/config.toml`, or `CC_TRACE_CODEX_MODEL` at setup) — the
default `gpt-5.5` is ChatGPT-only and 404s on the API.

> **ChatGPT-subscription login cannot be traced** (verified empirically). In
> ChatGPT mode, `chatgpt_base_url` only redirects **auxiliary** REST calls
> (`/plugins/*`, `/api/codex/apps`, analytics); the actual model **`/responses`**
> call goes to an endpoint that **no base-URL setting overrides**, so it bypasses
> the proxy entirely (the model reply still arrives, but nothing is captured —
> 0 `/responses` seen). The API-key path works because a **custom provider's
> `base_url` does govern the model call**. (The Cloudflare 403 you may see is only
> the non-essential `codex_apps` MCP feature, unrelated to tracing.) Point Codex
> at another OpenAI-compatible gateway with `CC_TRACE_CODEX_API`.

### OpenCode  *(tested with 1.17.7)*
OpenCode talks to many providers and only reads its **global** `opencode.json`
(the `OPENCODE_CONFIG` env var is **not** honored in this version). Setup merges a
forwarding `baseURL` into **each provider you use** (from your OpenCode auth +
`models.dev`), so every provider/model is traced to its real endpoint — verified
with Friendli (`zai-org/GLM-5.1`), correct model in the trace, multi-turn.

> Earlier "everything logged as `claude-sonnet`" was the proxy seeing only
> OpenCode's Anthropic **title-generation** sub-agent while the real chat used a
> different provider. Forwarding every provider fixes it.

---

## Friendli Model API

```bash
./setup.sh claude --friendli      # prompts for key + model (or FRIENDLI_API_KEY / FRIENDLI_MODEL)
```

Points Claude's upstream at `https://api.friendli.ai/serverless` (Anthropic-Messages
compatible) and sets `ANTHROPIC_AUTH_TOKEN` + `model`. OpenCode's Friendli provider
is already traced automatically if you have it configured (it's forwarded to
`https://api.friendli.ai/serverless/v1`). Based on the official guides
([Claude Code](https://friendli.ai/docs/integrate/agents/claude-code),
[OpenCode](https://friendli.ai/docs/integrate/agents/opencode)) — the only
difference is traffic goes through the local proxy first.

---

## Turning tracing off

- **One agent:** re-run `./setup.sh` without it (its config is reverted).
- **Everything:** `fai-trace stop` (stops the service), or `./setup.sh` and pick none.
- Uninstall: `fai-trace stop`; restore configs from the `*.pre-cc-trace.bak`
  backups; remove the `# >>> cc-trace >>>` line from your shell rc; delete `~/.cc-trace`.

---

## Troubleshooting

- **`fai-trace status` shows an agent `off` / agent can't connect** — the service
  may not have started, or an old proxy held the port. `setup.sh` kills stale
  proxies on every run, so re-running it fixes a stuck state. Check `fai-trace logs`.
- **A Claude session blipped** — restarting the proxy (`fai-trace restart`,
  re-running setup) briefly drops the port and Claude Code has no retry. Do it
  when no session is mid-task.
- **Figma / MCP plugins** — unaffected: `ANTHROPIC_BASE_URL` doesn't touch MCP
  connections, and there's no wrapper anymore. (`ENABLE_TOOL_SEARCH=true` is set so
  a non-first-party base URL doesn't disable MCP tool search.)
- **Codex `Missing OPENAI_API_KEY`** — `export OPENAI_API_KEY=sk-...` (Codex
  tracing needs API-key billing; ChatGPT-subscription login can't be traced).
- **Codex 404 / `{"detail":"Not Found"}`** — your `model` isn't API-accessible
  (e.g. `gpt-5.5`). Set `model` in `~/.codex/config.toml` to a model your key can use.
- **Login / auth** — untouched; the proxy forwards every auth header as-is. Keys
  are redacted from saved traces.

---

## Reference

### `fai-trace`
```
fai-trace status     # UP/off per agent port
fai-trace logs [N]   # tail the proxy log
fai-trace restart    # restart the service
fai-trace stop       # stop everything
fai-trace dirs       # print trace directories
```

### Files
- `~/.cc-trace/` — `trace_proxy.py`, `venv/`, `profiles.json`, `proxy.log`, `fai-trace`.
- Agent configs (each backed up to `*.pre-cc-trace.bak`): `~/.claude/settings.json`,
  `~/.codex/config.toml`, `~/.config/opencode/opencode.json`.

### Trace file layout — per call `<timestamp>_<id>`
- `.request.json` — request body (API keys redacted)
- `.request.headers.json` — request headers (auth redacted): `X-Claude-Code-Session-Id`
  / `-Agent-Id` / `-Parent-Agent-Id`, Codex `x-codex-turn-metadata` / `session-id`,
  OpenCode `x-session-id`
- `.response.json` — reconstructed response (text + reasoning/thinking, tool calls, usage)
- `.response.sse` — raw stream, ground truth

### `profiles.json`
```json
{
  "claude":   { "port": 8788, "upstream": "https://api.anthropic.com", "trace_dir": "~/fai-traces/claude-traces",   "format": "anthropic" },
  "codex":    { "port": 8789, "upstream": "",                          "trace_dir": "~/fai-traces/codex-traces",    "format": "auto" },
  "opencode": { "port": 8790, "upstream": "",                          "trace_dir": "~/fai-traces/opencode-traces", "format": "auto" }
}
```
`format: "auto"` + empty `upstream` = forwarding mode (upstream from the `/__cc__/`
path). The service serves only the agents you selected (`CC_TRACE_ONLY`).

### Environment variables
| Variable | Default | Meaning |
|----------|---------|---------|
| `CC_TRACE_HOME` | `~/.cc-trace` | install dir |
| `CC_TRACE_ROOT` | `~/fai-traces` | trace-dir parent |
| `CC_TRACE_ONLY` | (chosen agents) | comma-separated profiles the proxy serves |
| `CC_TRACE_REDACT` | `1` | redact API keys in saved traces |
| `CC_TRACE_NO_LAUNCHCTL` | `0` | skip launchctl/systemctl + stale-proxy kill (testing) |
| `CC_TRACE_CODEX_API` | `https://api.openai.com/v1` | Codex upstream (OpenAI-compatible) |
| `CC_TRACE_CODEX_MODEL` | (unset) | Codex model id (must be API-accessible) |
| `CC_TRACE_PORT_CLAUDE` / `_CODEX` / `_OPENCODE` | 8788/8789/8790 | ports |

### Tests
```bash
~/.cc-trace/venv/bin/python test_proxy.py    # or: python3 test_proxy.py
```
Mock upstream + all wire formats: byte-identical streaming, incremental delivery,
reconstruction with reasoning, forwarding (both formats), per-agent isolation,
redaction, header/sub-agent capture, health/config. Isolated ports — won't disturb
a live install.
