# Multi-Agent LLM Trace Capture

Capture every request + response (incl. reasoning, headers, status, latency) of
your coding agents into `~/fai-traces/<agent>-traces/`. You pick which agents to
trace; a tiny always-on local proxy does the rest. No wrappers, no per-launch flags.

| Agent | Port | Traces in | Notes |
|-------|------|-----------|-------|
| Claude Code | 8788 | `~/fai-traces/claude-traces` | terminal + IDE |
| Codex | 8789 | `~/fai-traces/codex-traces` | needs `OPENAI_API_KEY` |
| OpenCode | 8790 | `~/fai-traces/opencode-traces` | any provider/model you use |

## Setup

```bash
cd tracing-setup
./setup.sh                      # interactive: pick agents
./setup.sh claude codex opencode   # or name them
./setup.sh all
./setup.sh claude --friendli       # route Claude via the Friendli Model API
```

Then open a new terminal (or `source ~/.zshrc`) and use your agents normally.

- **Codex** needs an OpenAI API key: `export OPENAI_API_KEY=sk-...` (and a model
  your key can access — set `model` in `~/.codex/config.toml` if the default 404s).
- Re-run `./setup.sh <agents>` anytime to change the set (dropped agents revert).
- Installing restarts the proxy, so run it when no agent session is mid-task.

## What you get

Per model call, four files named `<timestamp>_<id>.*`:

| File | Contents |
|------|----------|
| `.request.json` | request body (API keys redacted) |
| `.request.headers.json` | request headers — incl. session / sub-agent ids |
| `.response.json` | response, reconstructed (text + reasoning/thinking, tool calls, usage) |
| `.meta.json` | HTTP status, `ttft_ms`, `duration_ms`, and response headers (request-id, rate-limit, retry-after, timing) |
| `.response.sse` | raw stream (ground truth), for streamed responses |

## Manage

```bash
fai-trace status     # which agent proxies are up
fai-trace logs       # tail the proxy log
fai-trace restart    # restart the proxy
fai-trace stop       # stop tracing (everything)
fai-trace dirs       # print trace directories
```

The proxy runs as a background service (`launchd` / `systemd --user`) and starts
automatically at login. To stop tracing an agent, re-run `./setup.sh` without it.

## How routing works (brief)

Each agent's config points its API base URL at the proxy; the proxy forwards to
the real provider and saves a copy. Codex/OpenCode encode their real endpoint in
the URL, so **any provider/model is traced with no hardcoded upstream**. Claude
uses a fixed upstream (Anthropic, or Friendli with `--friendli`). MCP plugins
(Figma, etc.) are unaffected — only model-API calls go through the proxy.

## IDE extensions & MCP plugins (Figma)

The proxy works the same in IDEs as in the terminal — extensions read the same
config files, so no extra setup beyond `./setup.sh` (just keep the proxy up; it
auto-starts at login — check `fai-trace status`).

- **Claude Code (VS Code / JetBrains):** Already traced. The extension shares
  `~/.claude/settings.json` with the CLI, so the `ANTHROPIC_BASE_URL` setup wrote
  applies to both. Nothing else to do.
- **Codex (VS Code extension):** Reads the same `~/.codex/config.toml`, so it's
  traced too — but a GUI-launched IDE may not see your shell's `OPENAI_API_KEY`.
  Either launch the IDE from a terminal that has `export OPENAI_API_KEY=...`, or
  set it for GUI apps once: `launchctl setenv OPENAI_API_KEY sk-...` (macOS) and
  restart the IDE.
- **Figma (and any MCP plugin):** Work normally with tracing on. `ANTHROPIC_BASE_URL`
  only redirects **model-API** calls — it does **not** touch MCP server
  connections, so the Figma MCP server connects directly as usual. Configure the
  Figma MCP in Claude Code as you normally would; the model calls that use Figma
  context are traced, and the plugin itself is unaffected. (Setup sets
  `ENABLE_TOOL_SEARCH=true` so MCP tool search keeps working behind the proxy.)

## Troubleshooting

- **Agent shows `off` in `fai-trace status`** → `fai-trace restart` (re-running
  `./setup.sh` also clears any stale proxy holding a port).
- **A Claude call failed right after login/restart** → the proxy was briefly
  starting; retry. It auto-starts at login.
- **Codex `Missing OPENAI_API_KEY` / 404** → export the key; set `model` to one
  your key can access (the Codex default `gpt-5.5` is not on the API).
- Auth is never altered; API keys are redacted from saved traces.

## Reference

- **Trace dirs:** `~/fai-traces/{claude,codex,opencode}-traces` (`CC_TRACE_ROOT` to change).
- **Config touched** (backed up to `*.pre-cc-trace.bak`): `~/.claude/settings.json`,
  `~/.codex/config.toml`, `~/.config/opencode/opencode.json`.
- **Friendli:** `./setup.sh claude --friendli` (reads `FRIENDLI_API_KEY` / `FRIENDLI_MODEL`).
- **Codex endpoint:** override with `CC_TRACE_CODEX_API` (default `https://api.openai.com/v1`).
- **Tests:** `~/.cc-trace/venv/bin/python test_proxy.py` (mock upstream; isolated ports).
