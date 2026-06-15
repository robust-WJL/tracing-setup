#!/usr/bin/env bash
#
# setup.sh — one-time setup for multi-agent LLM trace capture (with reasoning).
#
# Model:
#   - Claude Code: ALWAYS-ON. A single lightweight proxy runs as a background
#     service so both the terminal and the IDE extension are traced and never
#     break (Claude Code hard-fails if its base URL is down). Traces ->
#     ~/fai-traces/claude-traces.
#   - Codex / OpenCode: ON-DEMAND. Their proxy starts only when you launch them
#     through the installed `codex` / `opencode` wrappers, and self-stops after
#     inactivity. Launching them directly (not via the wrapper) runs them
#     normally, untraced — so nothing breaks when the proxy is down.
#
# All traces live under ~/fai-traces/<agent>-traces. Manage with
# `fai-trace status|logs|restart|stop|dirs`. Opt one Claude run out of tracing
# with `claude --tracing=none` (also works for `codex` / `opencode`).
#
# Flags:
#   --friendli                  configure all agents to use the Friendli Model API
#                               (sets upstreams + injects the Friendli key at the
#                               proxy). Reads FRIENDLI_API_KEY / FRIENDLI_MODEL
#                               from the env, or prompts.
#   --codex / --opencode        force-wire that agent even if not auto-detected
#   --skip-codex / --skip-opencode   never wire that agent
#   --no-service                terminal-only Claude (no always-on service; the
#                               IDE extension will NOT be traced)
#   --service-all               always-on service serves ALL profiles
#
set -euo pipefail

INSTALL_DIR="${CC_TRACE_HOME:-$HOME/.cc-trace}"
PORT_CLAUDE="${CC_TRACE_PORT_CLAUDE:-8788}"
PORT_CODEX="${CC_TRACE_PORT_CODEX:-8789}"
PORT_OPENCODE="${CC_TRACE_PORT_OPENCODE:-8790}"
TRACE_ROOT="${CC_TRACE_ROOT:-$HOME/fai-traces}"
DIR_CLAUDE="$TRACE_ROOT/claude-traces"
DIR_CODEX="$TRACE_ROOT/codex-traces"
DIR_OPENCODE="$TRACE_ROOT/opencode-traces"
UPSTREAM_ANTHROPIC="${CC_TRACE_UPSTREAM_ANTHROPIC:-https://api.anthropic.com}"
UPSTREAM_OPENAI="${CC_TRACE_UPSTREAM_OPENAI:-https://api.openai.com}"
IDLE_TIMEOUT="${CC_TRACE_IDLE_TIMEOUT:-1800}"   # on-demand proxies self-stop after this
FRIENDLI_BASE="https://api.friendli.ai/serverless"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

# launchctl/systemctl operate on a GLOBAL per-user namespace (the service label
# is not scoped to $HOME). Set CC_TRACE_NO_LAUNCHCTL=1 to skip all of them — used
# for sandboxed testing so a test run can't disturb a real, live install.
NO_LAUNCHCTL="${CC_TRACE_NO_LAUNCHCTL:-0}"
lc() { [ "$NO_LAUNCHCTL" = "1" ] && return 0; launchctl "$@"; }
sc() { [ "$NO_LAUNCHCTL" = "1" ] && return 0; systemctl "$@"; }

# --- parse flags ---
FORCE_CODEX=auto; FORCE_OPENCODE=auto; INSTALL_SERVICE=1; SERVICE_ONLY="claude"; FRIENDLI=0
for arg in "$@"; do
  case "$arg" in
    --friendli)      FRIENDLI=1 ;;
    --codex)         FORCE_CODEX=yes ;;
    --skip-codex)    FORCE_CODEX=no ;;
    --opencode)      FORCE_OPENCODE=yes ;;
    --skip-opencode) FORCE_OPENCODE=no ;;
    --no-service)    INSTALL_SERVICE=0 ;;
    --service-all)   SERVICE_ONLY="" ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Installing multi-agent LLM trace capture"
mkdir -p "$INSTALL_DIR" "$DIR_CLAUDE" "$DIR_CODEX" "$DIR_OPENCODE"

# ── Friendli: resolve key + model, point upstreams at Friendli ─────────────────
AUTH_TOKEN=""; FRIENDLI_MODEL_ID=""
if [ "$FRIENDLI" = "1" ]; then
  echo "==> Friendli mode: routing all agents through the Friendli Model API"
  AUTH_TOKEN="${FRIENDLI_API_KEY:-}"
  FRIENDLI_MODEL_ID="${FRIENDLI_MODEL:-}"
  if [ -z "$AUTH_TOKEN" ]; then
    if [ -t 0 ]; then read -rsp "    Friendli API key: " AUTH_TOKEN; echo
    else echo "ERROR: set FRIENDLI_API_KEY (non-interactive)"; exit 1; fi
  fi
  if [ -z "$FRIENDLI_MODEL_ID" ]; then
    if [ -t 0 ]; then read -rp "    Friendli model id (e.g. zai-org/GLM-5.1): " FRIENDLI_MODEL_ID
    else echo "ERROR: set FRIENDLI_MODEL (non-interactive)"; exit 1; fi
  fi
  [ -z "$AUTH_TOKEN" ] && { echo "ERROR: no Friendli API key"; exit 1; }
  [ -z "$FRIENDLI_MODEL_ID" ] && { echo "ERROR: no Friendli model id"; exit 1; }
  UPSTREAM_ANTHROPIC="$FRIENDLI_BASE"
  UPSTREAM_OPENAI="$FRIENDLI_BASE"
fi

# ── 1. drop the proxy next to its install dir ──────────────────────────────────
if [ -f "$SCRIPT_DIR/trace_proxy.py" ]; then
  cp "$SCRIPT_DIR/trace_proxy.py" "$INSTALL_DIR/trace_proxy.py"
else
  echo "ERROR: trace_proxy.py not found next to setup.sh" >&2; exit 1
fi
PROXY="$INSTALL_DIR/trace_proxy.py"

# ── 2. python deps in a dedicated venv ─────────────────────────────────────────
echo "==> Creating virtual environment and installing deps (httpx, starlette, uvicorn)"
VENV="$INSTALL_DIR/venv"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/python" -m pip install --quiet httpx starlette uvicorn
PYTHON_BIN="$VENV/bin/python"

# ── 3. write profiles.json (all three; service/wrappers pick which to run) ─────
echo "==> Writing $INSTALL_DIR/profiles.json"
cat > "$INSTALL_DIR/profiles.json" << EOF
{
  "claude":   { "port": $PORT_CLAUDE,   "upstream": "$UPSTREAM_ANTHROPIC", "trace_dir": "$DIR_CLAUDE",   "format": "anthropic", "auth_token": "$AUTH_TOKEN" },
  "codex":    { "port": $PORT_CODEX,    "upstream": "$UPSTREAM_OPENAI",    "trace_dir": "$DIR_CODEX",    "format": "openai",    "auth_token": "$AUTH_TOKEN" },
  "opencode": { "port": $PORT_OPENCODE, "upstream": "$UPSTREAM_ANTHROPIC", "trace_dir": "$DIR_OPENCODE", "format": "anthropic", "auth_token": "$AUTH_TOKEN" }
}
EOF
chmod 600 "$INSTALL_DIR/profiles.json" 2>/dev/null || true
echo "$UPSTREAM_ANTHROPIC" > "$INSTALL_DIR/claude.upstream"  # for the --tracing=none bypass
# Friendli key file, read by the codex wrapper (codex needs a key in its env).
if [ "$FRIENDLI" = "1" ]; then
  printf '%s' "$AUTH_TOKEN" > "$INSTALL_DIR/friendli.key"; chmod 600 "$INSTALL_DIR/friendli.key"
else
  rm -f "$INSTALL_DIR/friendli.key"
fi

# ── 4. on-demand launcher used by the codex/opencode wrappers ──────────────────
cat > "$INSTALL_DIR/fai-trace-up" << EOF
#!/usr/bin/env bash
# fai-trace-up <claude|codex|opencode> — start that agent's proxy if it isn't
# already listening, then wait until healthy. Self-stops after inactivity.
set -euo pipefail
agent="\${1:?usage: fai-trace-up <claude|codex|opencode>}"
case "\$agent" in
  claude) port=$PORT_CLAUDE ;; codex) port=$PORT_CODEX ;; opencode) port=$PORT_OPENCODE ;;
  *) echo "fai-trace-up: unknown agent \$agent" >&2; exit 1 ;;
esac
if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:\${port}/cc-trace/health" 2>/dev/null; then exit 0; fi
CC_TRACE_HOME="$INSTALL_DIR" CC_TRACE_IDLE_TIMEOUT="\${CC_TRACE_IDLE_TIMEOUT:-$IDLE_TIMEOUT}" \\
  nohup "$PYTHON_BIN" "$PROXY" --only "\$agent" > "$INSTALL_DIR/\${agent}.log" 2>&1 &
for _ in \$(seq 1 30); do
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:\${port}/cc-trace/health" 2>/dev/null && break
  sleep 0.2
done
EOF
chmod +x "$INSTALL_DIR/fai-trace-up"

# ── 5. always-on Claude service ────────────────────────────────────────────────
install_service() {
  case "$OS" in
    Darwin)
      local plist="$HOME/Library/LaunchAgents/ai.friendli.cc-trace.plist"
      mkdir -p "$HOME/Library/LaunchAgents"
      sed -e "s|@PYTHON@|$PYTHON_BIN|g" -e "s|@PROXY@|$PROXY|g" \
          -e "s|@CC_TRACE_HOME@|$INSTALL_DIR|g" -e "s|@ONLY@|$SERVICE_ONLY|g" \
          "$SCRIPT_DIR/service/ai.friendli.cc-trace.plist.template" > "$plist"
      lc bootout "gui/$(id -u)/ai.friendli.cc-trace" 2>/dev/null || true
      if ! lc bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
        lc unload "$plist" 2>/dev/null || true
        lc load "$plist" 2>/dev/null || true
      fi
      lc kickstart -k "gui/$(id -u)/ai.friendli.cc-trace" 2>/dev/null || true
      echo "    launchd agent installed: $plist  (serves: ${SERVICE_ONLY:-all})"
      ;;
    Linux)
      if command -v systemctl >/dev/null 2>&1; then
        local unit="$HOME/.config/systemd/user/cc-trace.service"
        mkdir -p "$HOME/.config/systemd/user"
        sed -e "s|@PYTHON@|$PYTHON_BIN|g" -e "s|@PROXY@|$PROXY|g" \
            -e "s|@CC_TRACE_HOME@|$INSTALL_DIR|g" -e "s|@ONLY@|$SERVICE_ONLY|g" \
            "$SCRIPT_DIR/service/cc-trace.service.template" > "$unit"
        sc --user daemon-reload
        sc --user enable --now cc-trace.service
        sc --user restart cc-trace.service
        echo "    systemd user service installed: $unit  (serves: ${SERVICE_ONLY:-all})"
      else
        echo "    systemd not available; Claude will be terminal-only via the wrapper."; return 1
      fi
      ;;
    *) echo "    Unsupported OS for auto-start; Claude will be terminal-only."; return 1 ;;
  esac
  return 0
}

SERVICE_OK=0
if [ "$INSTALL_SERVICE" = "1" ]; then
  echo "==> Installing always-on Claude proxy service"
  echo "    (this restarts the Claude proxy — any ACTIVE Claude session, terminal"
  echo "     or IDE, will briefly disconnect; run this when none are mid-task)"
  if install_service; then SERVICE_OK=1; fi
else
  if [ "$OS" = "Darwin" ]; then
    lc bootout "gui/$(id -u)/ai.friendli.cc-trace" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/ai.friendli.cc-trace.plist"
  elif command -v systemctl >/dev/null 2>&1; then
    sc --user disable --now cc-trace.service 2>/dev/null || true
  fi
  echo "==> --no-service: Claude will be traced in the terminal only (IDE not traced)"
fi

# ── 6. JSON merge helper ───────────────────────────────────────────────────────
merge_json() {  # merge_json <file> <python-snippet on dict `d`>
  "$PYTHON_BIN" - "$1" << PYEOF
import json, os, sys, shutil
path = sys.argv[1]
d = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        if not isinstance(d, dict):
            print(f"   (skipping {path}: not a JSON object)"); sys.exit(0)
    except json.JSONDecodeError:
        print(f"   (skipping {path}: not valid JSON — edit it manually)"); sys.exit(0)
    shutil.copy2(path, path + ".pre-cc-trace.bak")
os.makedirs(os.path.dirname(path), exist_ok=True)
${2}
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2); f.write("\n")
print(f"   (updated {path})")
PYEOF
}

# ── 7. Claude Code wiring (settings.json) ──────────────────────────────────────
CLAUDE_EXTRA=""
if [ "$FRIENDLI" = "1" ]; then
  # Claude Code needs an auth token present and a model selected; the proxy also
  # injects the Friendli key, but setting it here keeps Claude happy.
  CLAUDE_EXTRA="
env['ANTHROPIC_AUTH_TOKEN'] = '${AUTH_TOKEN}'
d['model'] = '${FRIENDLI_MODEL_ID}'"
fi
if [ "$SERVICE_OK" = "1" ]; then
  echo "==> Wiring Claude Code (~/.claude/settings.json -> proxy)"
  merge_json "$HOME/.claude/settings.json" "
env = d.get('env', {})
env['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:${PORT_CLAUDE}'
env['ENABLE_TOOL_SEARCH'] = 'true'
d['env'] = env
d['showThinkingSummaries'] = True${CLAUDE_EXTRA}
"
else
  echo "==> Removing Claude base URL from settings.json (terminal-only mode)"
  merge_json "$HOME/.claude/settings.json" "
env = d.get('env', {})
env.pop('ANTHROPIC_BASE_URL', None)
d['env'] = env
d['showThinkingSummaries'] = True${CLAUDE_EXTRA}
"
fi

# ── 8. Codex wiring (custom provider over HTTP — avoids the WebSocket auth bug) ─
wire_codex() {
  local cfg="$HOME/.codex/config.toml"
  mkdir -p "$HOME/.codex"
  CC_MODEL="$FRIENDLI_MODEL_ID" "$PYTHON_BIN" - "$cfg" "http://127.0.0.1:${PORT_CODEX}/v1" << 'PYEOF'
import os, re, sys, shutil
path, base = sys.argv[1], sys.argv[2]
model = os.environ.get("CC_MODEL", "")
existing = ""
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        existing = f.read()
    shutil.copy2(path, path + ".pre-cc-trace.bak")
# Remove anything a previous version of this setup injected.
existing = re.sub(r'^# cc-trace:.*\n', '', existing, flags=re.M)
existing = re.sub(r'^openai_base_url\s*=.*\n', '', existing, flags=re.M)
model_line = f'model = "{model}"\n' if model else ''
block = (
    '\n# cc-trace: traced provider (plain HTTP, no WebSocket). Used via `--profile fai-trace`.\n'
    '[model_providers.fai-trace]\n'
    'name = "FAI Trace (proxy)"\n'
    f'base_url = "{base}"\n'
    'env_key = "OPENAI_API_KEY"\n'
    'wire_api = "chat"   # switch to "responses" if your model requires it\n'
    '\n[profiles.fai-trace]\n'
    'model_provider = "fai-trace"\n'
    f'{model_line}'
)
if "[model_providers.fai-trace]" not in existing:
    existing = existing.rstrip("\n") + "\n" + block
    print(f"   (codex: added [model_providers.fai-trace] -> {base})")
else:
    print("   (codex: fai-trace provider already present — left as is)")
with open(path, "w", encoding="utf-8") as f:
    f.write(existing)
PYEOF
}

# ── 9. OpenCode wiring (separate trace config; main config untouched) ──────────
wire_opencode() {
  local cfg="$INSTALL_DIR/opencode-trace.json"
  CC_KEY="$AUTH_TOKEN" CC_MODEL="$FRIENDLI_MODEL_ID" \
  "$PYTHON_BIN" - "$cfg" "http://127.0.0.1:${PORT_OPENCODE}/v1" << 'PYEOF'
import json, os, sys
path, base = sys.argv[1], sys.argv[2]
key, model = os.environ.get("CC_KEY", ""), os.environ.get("CC_MODEL", "")
opts = {"baseURL": base}          # MUST end in /v1 (AI SDK appends /messages)
if key:
    opts["apiKey"] = key
models = {"claude-sonnet-4-6": {"name": "Claude Sonnet 4.6"},
          "claude-opus-4-8": {"name": "Claude Opus 4.8"}}
if model:
    models[model] = {"name": model}
d = {"$schema": "https://opencode.ai/config.json",
     "provider": {"anthropic": {"options": opts, "models": models}}}
if model:
    d["model"] = f"anthropic/{model}"
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2); f.write("\n")
print(f"   (opencode: trace config at {path} -> {base})")
PYEOF
  local real="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
  if [ -f "$real" ]; then
    "$PYTHON_BIN" - "$real" << 'PYEOF'
import json, sys
path = sys.argv[1]
try: d = json.load(open(path, encoding="utf-8"))
except Exception: sys.exit(0)
opts = d.get("provider", {}).get("anthropic", {}).get("options", {})
if isinstance(opts.get("baseURL"), str) and "127.0.0.1:879" in opts["baseURL"]:
    opts.pop("baseURL", None)
    json.dump(d, open(path, "w", encoding="utf-8"), indent=2)
    print(f"   (opencode: removed old injected baseURL from {path})")
PYEOF
  fi
}

detect() { command -v "$1" >/dev/null 2>&1; }

DO_CODEX=0
case "$FORCE_CODEX" in
  yes) DO_CODEX=1 ;; no) DO_CODEX=0 ;;
  auto) { detect codex || [ -d "$HOME/.codex" ]; } && DO_CODEX=1 ;;
esac
if [ "$DO_CODEX" = "1" ]; then echo "==> Wiring Codex (~/.codex/config.toml)"; wire_codex
else echo "==> Skipping Codex (not detected; re-run with --codex)"; fi

DO_OPENCODE=0
case "$FORCE_OPENCODE" in
  yes) DO_OPENCODE=1 ;; no) DO_OPENCODE=0 ;;
  auto) { detect opencode || [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/opencode" ]; } && DO_OPENCODE=1 ;;
esac
if [ "$DO_OPENCODE" = "1" ]; then echo "==> Wiring OpenCode (on-demand trace config)"; wire_opencode
else echo "==> Skipping OpenCode (not detected; re-run with --opencode)"; fi

# ── 10. `fai-trace` management command ─────────────────────────────────────────
cat > "$INSTALL_DIR/fai-trace" << EOF
#!/usr/bin/env bash
# fai-trace — manage the trace proxies.  fai-trace status|logs [agent]|restart|stop|dirs
set -euo pipefail
HOME_DIR="$INSTALL_DIR"; OS="$OS"
case "\${1:-status}" in
  status)
    for p in claude:$PORT_CLAUDE codex:$PORT_CODEX opencode:$PORT_OPENCODE; do
      name="\${p%%:*}"; port="\${p##*:}"
      if curl -s --max-time 1 "http://127.0.0.1:\${port}/cc-trace/health" >/dev/null 2>&1; then
        echo "  \$name  127.0.0.1:\${port}  UP"
      else
        echo "  \$name  127.0.0.1:\${port}  down (on-demand: starts when you launch it)"
      fi
    done ;;
  logs)  tail -n "\${3:-40}" -f "\$HOME_DIR/\${2:-proxy}.log" 2>/dev/null || tail -n 40 -f "\$HOME_DIR/proxy.log" ;;
  restart)
    if [ "\$OS" = "Darwin" ]; then launchctl kickstart -k "gui/\$(id -u)/ai.friendli.cc-trace" 2>/dev/null && echo "claude service restarted" || echo "no claude service"
    elif command -v systemctl >/dev/null 2>&1; then systemctl --user restart cc-trace.service 2>/dev/null && echo "claude service restarted" || echo "no claude service"; fi
    pkill -f "trace_proxy.py --only" 2>/dev/null || true; echo "on-demand proxies cleared (restart on next use)" ;;
  stop)
    if [ "\$OS" = "Darwin" ]; then launchctl bootout "gui/\$(id -u)/ai.friendli.cc-trace" 2>/dev/null || true
    elif command -v systemctl >/dev/null 2>&1; then systemctl --user stop cc-trace.service 2>/dev/null || true; fi
    pkill -f "trace_proxy.py" 2>/dev/null || true; echo "all proxies stopped" ;;
  dirs)  echo "  $DIR_CLAUDE"; echo "  $DIR_CODEX"; echo "  $DIR_OPENCODE" ;;
  *) echo "usage: fai-trace [status|logs [agent] [N]|restart|stop|dirs]"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/fai-trace"
rm -f "$INSTALL_DIR/cc-trace" "$INSTALL_DIR/claude-trace" "$INSTALL_DIR/trace" "$INSTALL_DIR/trace-up"  # old names

# ── 11. shell rc: PATH + agent wrappers ────────────────────────────────────────
RC=""
case "${SHELL##*/}" in
  zsh)  RC="$HOME/.zshrc" ;; bash) RC="$HOME/.bashrc" ;; *) RC="$HOME/.profile" ;;
esac
if [ -f "$RC" ] && grep -qF "# >>> cc-trace >>>" "$RC"; then
  "$PYTHON_BIN" - "$RC" << 'PYEOF'
import sys, re
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"\n?# >>> cc-trace >>>.*?# <<< cc-trace <<<\n?", "\n", s, flags=re.S)
open(p, "w", encoding="utf-8").write(s)
PYEOF
fi

cat >> "$RC" << EOF
# >>> cc-trace >>>
export PATH="$INSTALL_DIR:\$PATH"
# Claude Code: traced by default. Opt out for one run:  claude --tracing=none
claude() {
  local tracing=on; local args=()
  for a in "\$@"; do
    case "\$a" in --tracing=none|--tracing=off) tracing=off ;; *) args+=("\$a") ;; esac
  done
  [ "\${CC_TRACE:-}" = "off" ] && tracing=off
  if [ "\$tracing" = "off" ]; then
    local up; up="\$(cat "$INSTALL_DIR/claude.upstream" 2>/dev/null || echo https://api.anthropic.com)"
    ANTHROPIC_BASE_URL="\$up" command claude "\${args[@]}"
  else
    "$INSTALL_DIR/fai-trace-up" claude 2>/dev/null || true
    ANTHROPIC_BASE_URL="http://127.0.0.1:${PORT_CLAUDE}" ENABLE_TOOL_SEARCH=true command claude "\${args[@]}"
  fi
}
# Codex: on-demand. Traced via the fai-trace profile; --tracing=none runs normally.
codex() {
  local tracing=on; local args=()
  for a in "\$@"; do
    case "\$a" in --tracing=none|--tracing=off) tracing=off ;; *) args+=("\$a") ;; esac
  done
  [ "\${CC_TRACE:-}" = "off" ] && tracing=off
  if [ "\$tracing" = "off" ]; then
    command codex "\${args[@]}"
  else
    # Friendli mode stores the key here so Codex has one in its env.
    [ -f "$INSTALL_DIR/friendli.key" ] && [ -z "\${OPENAI_API_KEY:-}" ] && \\
      export OPENAI_API_KEY="\$(cat "$INSTALL_DIR/friendli.key")"
    "$INSTALL_DIR/fai-trace-up" codex 2>/dev/null || true
    command codex --profile fai-trace "\${args[@]}"
  fi
}
# OpenCode: on-demand. Traced via a layered config; --tracing=none runs normally.
opencode() {
  local tracing=on; local args=()
  for a in "\$@"; do
    case "\$a" in --tracing=none|--tracing=off) tracing=off ;; *) args+=("\$a") ;; esac
  done
  [ "\${CC_TRACE:-}" = "off" ] && tracing=off
  if [ "\$tracing" = "off" ]; then
    command opencode "\${args[@]}"
  else
    "$INSTALL_DIR/fai-trace-up" opencode 2>/dev/null || true
    OPENCODE_CONFIG="$INSTALL_DIR/opencode-trace.json" command opencode "\${args[@]}"
  fi
}
# <<< cc-trace <<<
EOF
echo "==> Added cc-trace block to $RC"

# ── done ───────────────────────────────────────────────────────────────────────
echo ""
echo "==> Done.  Open a new terminal (or: source $RC)"
echo ""
echo "    Traces under $TRACE_ROOT/:"
echo "      Claude Code -> $DIR_CLAUDE   (always-on)"
echo "      Codex       -> $DIR_CODEX    (on-demand)"
echo "      OpenCode    -> $DIR_OPENCODE (on-demand)"
echo ""
echo "    Opt a Claude run out of tracing:  claude --tracing=none"
echo "    Manage:                           fai-trace status | logs | restart | stop | dirs"
echo ""
if [ "$FRIENDLI" = "1" ]; then
  echo "    Friendli mode: all agents -> $FRIENDLI_BASE  (model: $FRIENDLI_MODEL_ID)"
  echo "    The Friendli key is injected by the proxy; agents need no separate key."
fi
if [ "$SERVICE_OK" = "1" ]; then
  echo "    Claude proxy runs as a background service (serves: ${SERVICE_ONLY:-all profiles})."
else
  echo "    NOTE: --no-service — Claude is traced in the terminal only; IDE NOT traced."
fi
if [ "$DO_CODEX" = "1" ] && [ "$FRIENDLI" != "1" ]; then
  echo ""
  echo "    Codex needs an API key:  export OPENAI_API_KEY=sk-...  (Chat/Responses access)."
  echo "    ChatGPT-subscription login can't be traced this way."
fi
