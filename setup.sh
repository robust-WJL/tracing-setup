#!/usr/bin/env bash
#
# setup.sh — one-time setup for multi-agent LLM trace capture (with reasoning).
#
# What this does:
#   1. Installs a single local pass-through proxy + its Python deps (in a venv).
#   2. Writes a profiles config so the proxy can trace several agents at once,
#      each on its own port -> its own upstream -> its own trace directory.
#   3. Installs a background service (launchd on macOS, systemd --user on Linux)
#      so the proxy is ALWAYS running — no command to remember.
#   4. Wires up each detected agent to route through the proxy:
#        - Claude Code : ANTHROPIC_BASE_URL in ~/.claude/settings.json  (terminal + IDE)
#        - Codex       : openai_base_url in ~/.codex/config.toml
#        - OpenCode    : provider.anthropic.options.baseURL in opencode.json
#   5. Adds a `claude` shell function so plain `claude` is traced, with a
#      per-launch opt-out:  `claude --tracing=none`  (or  CC_TRACE=off claude).
#
# After running this once, just use your agents normally. Traces appear in:
#   ~/claude-traces  ~/codex-traces  ~/opencode-traces
#
# Flags:
#   --codex / --opencode        force-wire that agent even if not auto-detected
#   --skip-codex / --skip-opencode   never wire that agent
#   --no-service                install everything but don't install the service
#
set -euo pipefail

INSTALL_DIR="${CC_TRACE_HOME:-$HOME/.cc-trace}"
PORT_CLAUDE="${CC_TRACE_PORT_CLAUDE:-8788}"
PORT_CODEX="${CC_TRACE_PORT_CODEX:-8789}"
PORT_OPENCODE="${CC_TRACE_PORT_OPENCODE:-8790}"
DIR_CLAUDE="${CC_TRACE_DIR_CLAUDE:-$HOME/claude-traces}"
DIR_CODEX="${CC_TRACE_DIR_CODEX:-$HOME/codex-traces}"
DIR_OPENCODE="${CC_TRACE_DIR_OPENCODE:-$HOME/opencode-traces}"
UPSTREAM_ANTHROPIC="${CC_TRACE_UPSTREAM_ANTHROPIC:-https://api.anthropic.com}"
UPSTREAM_OPENAI="${CC_TRACE_UPSTREAM_OPENAI:-https://api.openai.com}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

# --- parse flags ---
FORCE_CODEX=auto; FORCE_OPENCODE=auto; INSTALL_SERVICE=1
for arg in "$@"; do
  case "$arg" in
    --codex)         FORCE_CODEX=yes ;;
    --skip-codex)    FORCE_CODEX=no ;;
    --opencode)      FORCE_OPENCODE=yes ;;
    --skip-opencode) FORCE_OPENCODE=no ;;
    --no-service)    INSTALL_SERVICE=0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Installing multi-agent LLM trace capture"
mkdir -p "$INSTALL_DIR" "$DIR_CLAUDE" "$DIR_CODEX" "$DIR_OPENCODE"

# ── 1. drop the proxy next to its install dir ──────────────────────────────────
if [ -f "$SCRIPT_DIR/trace_proxy.py" ]; then
  cp "$SCRIPT_DIR/trace_proxy.py" "$INSTALL_DIR/trace_proxy.py"
else
  echo "ERROR: trace_proxy.py not found next to setup.sh" >&2
  exit 1
fi
PROXY="$INSTALL_DIR/trace_proxy.py"

# ── 2. python deps in a dedicated venv (avoids PEP 668 / Homebrew issues) ──────
echo "==> Creating virtual environment and installing deps (httpx, starlette, uvicorn)"
VENV="$INSTALL_DIR/venv"
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/python" -m pip install --quiet httpx starlette uvicorn
PYTHON_BIN="$VENV/bin/python"

# ── 3. write profiles.json ─────────────────────────────────────────────────────
echo "==> Writing $INSTALL_DIR/profiles.json"
cat > "$INSTALL_DIR/profiles.json" << EOF
{
  "claude":   { "port": $PORT_CLAUDE,   "upstream": "$UPSTREAM_ANTHROPIC", "trace_dir": "$DIR_CLAUDE",   "format": "anthropic" },
  "codex":    { "port": $PORT_CODEX,    "upstream": "$UPSTREAM_OPENAI",    "trace_dir": "$DIR_CODEX",    "format": "openai" },
  "opencode": { "port": $PORT_OPENCODE, "upstream": "$UPSTREAM_ANTHROPIC", "trace_dir": "$DIR_OPENCODE", "format": "anthropic" }
}
EOF

# cache the claude upstream so the `claude --tracing=none` opt-out can bypass
# the proxy and talk to the real upstream directly.
echo "$UPSTREAM_ANTHROPIC" > "$INSTALL_DIR/claude.upstream"

# ── 4. background service (always-on proxy) ────────────────────────────────────
install_service() {
  case "$OS" in
    Darwin)
      local plist="$HOME/Library/LaunchAgents/ai.friendli.cc-trace.plist"
      mkdir -p "$HOME/Library/LaunchAgents"
      sed -e "s|@PYTHON@|$PYTHON_BIN|g" \
          -e "s|@PROXY@|$PROXY|g" \
          -e "s|@CC_TRACE_HOME@|$INSTALL_DIR|g" \
          "$SCRIPT_DIR/service/ai.friendli.cc-trace.plist.template" > "$plist"
      # reload cleanly (bootout old, bootstrap new); fall back to load/unload
      launchctl bootout "gui/$(id -u)/ai.friendli.cc-trace" 2>/dev/null || true
      if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then :; else
        launchctl unload "$plist" 2>/dev/null || true
        launchctl load "$plist"
      fi
      launchctl kickstart -k "gui/$(id -u)/ai.friendli.cc-trace" 2>/dev/null || true
      echo "    launchd agent installed: $plist"
      ;;
    Linux)
      if command -v systemctl >/dev/null 2>&1; then
        local unit="$HOME/.config/systemd/user/cc-trace.service"
        mkdir -p "$HOME/.config/systemd/user"
        sed -e "s|@PYTHON@|$PYTHON_BIN|g" \
            -e "s|@PROXY@|$PROXY|g" \
            -e "s|@CC_TRACE_HOME@|$INSTALL_DIR|g" \
            "$SCRIPT_DIR/service/cc-trace.service.template" > "$unit"
        systemctl --user daemon-reload
        systemctl --user enable --now cc-trace.service
        echo "    systemd user service installed: $unit"
      else
        echo "    systemd not available; will rely on lazy-start (see note below)."
        return 1
      fi
      ;;
    *)
      echo "    Unsupported OS for auto-start; will rely on lazy-start."
      return 1
      ;;
  esac
  return 0
}

SERVICE_OK=0
if [ "$INSTALL_SERVICE" = "1" ]; then
  echo "==> Installing always-on proxy service"
  if install_service; then SERVICE_OK=1; fi
fi

# Always (re)start once now so the proxy is up immediately, even without service.
if [ "$SERVICE_OK" != "1" ]; then
  if ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${PORT_CLAUDE}/cc-trace/health" 2>/dev/null; then
    CC_TRACE_HOME="$INSTALL_DIR" nohup "$PYTHON_BIN" "$PROXY" > "$INSTALL_DIR/proxy.log" 2>&1 &
  fi
fi

# wait for the proxy to answer on the claude port
for _ in $(seq 1 30); do
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${PORT_CLAUDE}/cc-trace/health" 2>/dev/null && break
  sleep 0.2
done

# ── 5. helper: merge JSON settings via python ──────────────────────────────────
# usage: merge_json <file> <python-snippet operating on dict `d`>
merge_json() {
  local file="$1"; local snippet="$2"
  "$PYTHON_BIN" - "$file" << PYEOF
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
${snippet}
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2); f.write("\n")
print(f"   (updated {path})")
PYEOF
}

# ── 6. Claude Code wiring (settings.json) ──────────────────────────────────────
echo "==> Wiring Claude Code (~/.claude/settings.json)"
merge_json "$HOME/.claude/settings.json" "
env = d.get('env', {})
env['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:${PORT_CLAUDE}'
# A non-first-party base URL disables MCP tool search by default; keep it on so
# MCP plugins (Figma, etc.) behave exactly as they do without the proxy.
env['ENABLE_TOOL_SEARCH'] = 'true'
d['env'] = env
# Needed so the API returns summarized reasoning text (otherwise it is omitted).
d['showThinkingSummaries'] = True
"

# ── 7. Codex wiring (~/.codex/config.toml) ─────────────────────────────────────
wire_codex() {
  local cfg="$HOME/.codex/config.toml"
  mkdir -p "$HOME/.codex"
  "$PYTHON_BIN" - "$cfg" "http://127.0.0.1:${PORT_CODEX}/v1" << 'PYEOF'
import os, sys, shutil
path, base = sys.argv[1], sys.argv[2]
existing = ""
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        existing = f.read()
    shutil.copy2(path, path + ".pre-cc-trace.bak")
if "openai_base_url" in existing:
    print("   (codex: openai_base_url already set — left as is; "
          f"point it at {base} to trace)")
    sys.exit(0)
# Top-level keys must precede any [table]; prepend to stay valid TOML.
header = (f'# cc-trace: route the built-in openai provider through the proxy\n'
          f'openai_base_url = "{base}"\n\n')
with open(path, "w", encoding="utf-8") as f:
    f.write(header + existing)
print(f"   (codex: set openai_base_url = {base})")
PYEOF
}

# ── 8. OpenCode wiring (opencode.json) ─────────────────────────────────────────
wire_opencode() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
  mkdir -p "$(dirname "$cfg")"
  "$PYTHON_BIN" - "$cfg" "http://127.0.0.1:${PORT_OPENCODE}" << 'PYEOF'
import json, os, sys, shutil
path, base = sys.argv[1], sys.argv[2]
d = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except json.JSONDecodeError:
        print("   (skipping opencode.json: not valid JSON — edit manually)"); sys.exit(0)
    shutil.copy2(path, path + ".pre-cc-trace.bak")
d.setdefault("$schema", "https://opencode.ai/config.json")
prov = d.setdefault("provider", {})
anth = prov.setdefault("anthropic", {})
opts = anth.setdefault("options", {})
opts["baseURL"] = base
# Newer OpenCode requires a models block under the provider.
anth.setdefault("models", {
    "claude-sonnet-4-6": {"name": "Claude Sonnet 4.6"},
    "claude-opus-4-8":   {"name": "Claude Opus 4.8"},
})
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2); f.write("\n")
print(f"   (opencode: set provider.anthropic.options.baseURL = {base})")
PYEOF
}

detect() { command -v "$1" >/dev/null 2>&1; }

# Codex
DO_CODEX=0
case "$FORCE_CODEX" in
  yes) DO_CODEX=1 ;;
  no)  DO_CODEX=0 ;;
  auto) { detect codex || [ -d "$HOME/.codex" ]; } && DO_CODEX=1 ;;
esac
if [ "$DO_CODEX" = "1" ]; then
  echo "==> Wiring Codex (~/.codex/config.toml)"
  wire_codex
else
  echo "==> Skipping Codex (not detected; re-run with --codex to wire it)"
fi

# OpenCode
DO_OPENCODE=0
case "$FORCE_OPENCODE" in
  yes) DO_OPENCODE=1 ;;
  no)  DO_OPENCODE=0 ;;
  auto) { detect opencode || [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/opencode" ]; } && DO_OPENCODE=1 ;;
esac
if [ "$DO_OPENCODE" = "1" ]; then
  echo "==> Wiring OpenCode (opencode.json)"
  wire_opencode
else
  echo "==> Skipping OpenCode (not detected; re-run with --opencode to wire it)"
fi

# ── 9. claude-trace launcher (back-compat, always traced) ──────────────────────
cat > "$INSTALL_DIR/claude-trace" << EOF
#!/usr/bin/env bash
# Always-traced launcher (back-compat). Forces the proxy base URL for this run.
set -euo pipefail
PYTHON="$PYTHON_BIN"; PROXY="$PROXY"; HOME_DIR="$INSTALL_DIR"; PORT=$PORT_CLAUDE
# lazy-start if the service isn't running for some reason
if ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:\${PORT}/cc-trace/health" 2>/dev/null; then
  CC_TRACE_HOME="\$HOME_DIR" nohup "\$PYTHON" "\$PROXY" > "\$HOME_DIR/proxy.log" 2>&1 &
  for _ in \$(seq 1 20); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:\${PORT}/cc-trace/health" 2>/dev/null && break
    sleep 0.2
  done
fi
export ANTHROPIC_BASE_URL="http://127.0.0.1:\${PORT}"
export ENABLE_TOOL_SEARCH=true
exec command claude "\$@"
EOF
chmod +x "$INSTALL_DIR/claude-trace"

# ── 10. cc-trace management command ────────────────────────────────────────────
cat > "$INSTALL_DIR/cc-trace" << EOF
#!/usr/bin/env bash
# cc-trace — manage the trace proxy.
#   cc-trace status | logs | restart | dirs
set -euo pipefail
HOME_DIR="$INSTALL_DIR"; OS="$OS"
case "\${1:-status}" in
  status)
    for p in claude:$PORT_CLAUDE codex:$PORT_CODEX opencode:$PORT_OPENCODE; do
      name="\${p%%:*}"; port="\${p##*:}"
      if curl -s --max-time 1 "http://127.0.0.1:\${port}/cc-trace/health" >/dev/null 2>&1; then
        echo "  \$name  127.0.0.1:\${port}  UP"
      else
        echo "  \$name  127.0.0.1:\${port}  DOWN"
      fi
    done ;;
  logs)    tail -n "\${2:-40}" -f "\$HOME_DIR/proxy.log" ;;
  restart)
    if [ "\$OS" = "Darwin" ]; then
      launchctl kickstart -k "gui/\$(id -u)/ai.friendli.cc-trace" && echo "restarted (launchd)"
    elif command -v systemctl >/dev/null 2>&1; then
      systemctl --user restart cc-trace.service && echo "restarted (systemd)"
    else
      pkill -f trace_proxy.py 2>/dev/null || true
      echo "killed; it will lazy-start on next agent launch"
    fi ;;
  dirs)
    echo "  $DIR_CLAUDE"; echo "  $DIR_CODEX"; echo "  $DIR_OPENCODE" ;;
  *) echo "usage: cc-trace [status|logs [N]|restart|dirs]"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/cc-trace"

# ── 11. shell rc: PATH + `claude` function with opt-out ────────────────────────
RC=""
case "${SHELL##*/}" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) RC="$HOME/.bashrc" ;;
  *)    RC="$HOME/.profile" ;;
esac

# Remove any previous cc-trace block, then append a fresh one (idempotent).
if [ -f "$RC" ] && grep -qF "# >>> cc-trace >>>" "$RC"; then
  "$PYTHON_BIN" - "$RC" << 'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r"\n?# >>> cc-trace >>>.*?# <<< cc-trace <<<\n?", "\n", s, flags=re.S)
open(p, "w", encoding="utf-8").write(s)
PYEOF
fi

cat >> "$RC" << EOF
# >>> cc-trace >>>
export PATH="$INSTALL_DIR:\$PATH"
# Trace plain \`claude\` by default. Opt out for one launch with:
#   claude --tracing=none      (or)   CC_TRACE=off claude
claude() {
  local tracing=on; local args=()
  for a in "\$@"; do
    case "\$a" in
      --tracing=none|--tracing=off) tracing=off ;;
      *) args+=("\$a") ;;
    esac
  done
  [ "\${CC_TRACE:-}" = "off" ] && tracing=off
  if [ "\$tracing" = "off" ]; then
    local up; up="\$(cat "$INSTALL_DIR/claude.upstream" 2>/dev/null || echo https://api.anthropic.com)"
    ANTHROPIC_BASE_URL="\$up" command claude "\${args[@]}"
  else
    ANTHROPIC_BASE_URL="http://127.0.0.1:${PORT_CLAUDE}" ENABLE_TOOL_SEARCH=true command claude "\${args[@]}"
  fi
}
# <<< cc-trace <<<
EOF
echo "==> Added cc-trace block to $RC"

# ── done ───────────────────────────────────────────────────────────────────────
echo ""
echo "==> Done."
echo "    Open a new terminal (or run: source $RC)"
echo ""
echo "    Use your agents normally — tracing is automatic:"
echo "      Claude Code -> $DIR_CLAUDE"
echo "      Codex       -> $DIR_CODEX"
echo "      OpenCode    -> $DIR_OPENCODE"
echo ""
echo "    Opt out for one Claude Code launch:  claude --tracing=none"
echo "    Manage the proxy:                    cc-trace status | logs | restart | dirs"
echo ""
if [ "$SERVICE_OK" = "1" ]; then
  echo "    The proxy runs as a background service and starts automatically at login."
else
  echo "    NOTE: no background service installed; the proxy lazy-starts when you"
  echo "          launch an agent from the terminal. For the IDE extension to be"
  echo "          traced reliably, install the service (see README)."
fi
