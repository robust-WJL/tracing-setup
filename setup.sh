#!/usr/bin/env bash
#
# setup.sh — trace the coding agents you choose, into ~/fai-traces/<agent>-traces.
#
# You pick the agents at install time. ONLY those are wired and kept traced by a
# single always-on proxy service; the others are reverted to normal. To change
# which agents are traced, just re-run with a different selection. There are no
# shell wrappers, profiles, or per-launch flags — each agent is routed purely by
# its own persistent config.
#
# Usage:
#   ./setup.sh                    # interactive: choose agents
#   ./setup.sh claude codex       # trace these (others reverted to normal)
#   ./setup.sh all                # trace all three
#   ./setup.sh claude --friendli  # route Claude through the Friendli Model API
#
# Opt out: re-run without that agent, or `fai-trace stop` to stop everything.
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
# Codex: ChatGPT-subscription login can't be traced (chatgpt.com is Cloudflare-
# bot-protected). Tracing uses an OpenAI API key against api.openai.com.
CODEX_API="${CC_TRACE_CODEX_API:-https://api.openai.com/v1}"
CODEX_MODEL="${CC_TRACE_CODEX_MODEL:-}"
FRIENDLI_BASE="https://api.friendli.ai/serverless"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

# launchctl/systemctl act on a GLOBAL per-user namespace; CC_TRACE_NO_LAUNCHCTL=1
# skips them (and the stale-proxy kill) for safe sandboxed testing.
NO_LAUNCHCTL="${CC_TRACE_NO_LAUNCHCTL:-0}"
lc() { [ "$NO_LAUNCHCTL" = "1" ] && return 0; launchctl "$@"; }
sc() { [ "$NO_LAUNCHCTL" = "1" ] && return 0; systemctl "$@"; }

# ── parse: agent names (+ all) and --friendli ─────────────────────────────────
FRIENDLI=0; AGENTS=()
for arg in "$@"; do
  case "$arg" in
    --friendli) FRIENDLI=1 ;;
    all) AGENTS=(claude codex opencode) ;;
    claude|codex|opencode) AGENTS+=("$arg") ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg (expected: claude codex opencode all --friendli)" >&2; exit 1 ;;
  esac
done
if [ ${#AGENTS[@]} -eq 0 ]; then
  if [ -t 0 ]; then
    echo "Which agents do you want to trace? (space-separated: claude codex opencode)"
    read -r line || true
    for a in ${line:-}; do case "$a" in claude|codex|opencode) AGENTS+=("$a") ;; all) AGENTS=(claude codex opencode) ;; esac; done
  fi
  [ ${#AGENTS[@]} -eq 0 ] && AGENTS=(claude)
fi
# de-duplicate, preserving order
AGENTS=($(printf '%s\n' "${AGENTS[@]}" | awk '!seen[$0]++'))
chosen() { printf '%s\n' "${AGENTS[@]}" | grep -qx "$1"; }
CC_ONLY=$(IFS=,; echo "${AGENTS[*]}")

echo "==> Tracing: ${AGENTS[*]}   (traces -> $TRACE_ROOT)"
mkdir -p "$INSTALL_DIR" "$DIR_CLAUDE" "$DIR_CODEX" "$DIR_OPENCODE"

# ── Friendli (Claude upstream) ─────────────────────────────────────────────────
FRIENDLI_KEY=""; FRIENDLI_MODEL_ID=""
if [ "$FRIENDLI" = "1" ]; then
  echo "==> Friendli mode for Claude"
  FRIENDLI_KEY="${FRIENDLI_API_KEY:-}"; FRIENDLI_MODEL_ID="${FRIENDLI_MODEL:-}"
  [ -z "$FRIENDLI_KEY" ] && { [ -t 0 ] && read -rsp "    Friendli API key: " FRIENDLI_KEY && echo || { echo "set FRIENDLI_API_KEY"; exit 1; }; }
  [ -z "$FRIENDLI_MODEL_ID" ] && { [ -t 0 ] && read -rp "    Friendli model id (e.g. zai-org/GLM-5.1): " FRIENDLI_MODEL_ID || { echo "set FRIENDLI_MODEL"; exit 1; }; }
  UPSTREAM_ANTHROPIC="$FRIENDLI_BASE"
fi

# ── proxy + venv ───────────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/trace_proxy.py" "$INSTALL_DIR/trace_proxy.py"
PROXY="$INSTALL_DIR/trace_proxy.py"
echo "==> venv + deps (httpx, starlette, uvicorn)"
VENV="$INSTALL_DIR/venv"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/python" -m pip install --quiet httpx starlette uvicorn
PYTHON_BIN="$VENV/bin/python"
b64() { "$PYTHON_BIN" -c "import base64,sys;print(base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip('='))" "$1"; }

# ── profiles.json — Claude has a fixed upstream (single-provider); Codex/OpenCode
# forward (the real endpoint is encoded into each agent's base URL). ────────────
cat > "$INSTALL_DIR/profiles.json" << EOF
{
  "claude":   { "port": $PORT_CLAUDE,   "upstream": "$UPSTREAM_ANTHROPIC", "trace_dir": "$DIR_CLAUDE",   "format": "anthropic" },
  "codex":    { "port": $PORT_CODEX,    "upstream": "",                    "trace_dir": "$DIR_CODEX",    "format": "auto" },
  "opencode": { "port": $PORT_OPENCODE, "upstream": "",                    "trace_dir": "$DIR_OPENCODE", "format": "auto" }
}
EOF

# ── clear stale proxies so the new config/ports bind cleanly (real installs) ───
if [ "$NO_LAUNCHCTL" != "1" ]; then
  pkill -f "trace_proxy.py" 2>/dev/null || true
  sleep 0.5
fi

# ── always-on service (serves exactly the chosen agents) ───────────────────────
install_service() {
  case "$OS" in
    Darwin)
      local plist="$HOME/Library/LaunchAgents/ai.friendli.cc-trace.plist"
      mkdir -p "$HOME/Library/LaunchAgents"
      sed -e "s|@PYTHON@|$PYTHON_BIN|g" -e "s|@PROXY@|$PROXY|g" \
          -e "s|@CC_TRACE_HOME@|$INSTALL_DIR|g" -e "s|@ONLY@|$CC_ONLY|g" \
          "$SCRIPT_DIR/service/ai.friendli.cc-trace.plist.template" > "$plist"
      lc bootout "gui/$(id -u)/ai.friendli.cc-trace" 2>/dev/null || true
      lc bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || lc load "$plist" 2>/dev/null || true
      lc kickstart -k "gui/$(id -u)/ai.friendli.cc-trace" 2>/dev/null || true
      echo "    launchd service installed (serves: $CC_ONLY)" ;;
    Linux)
      command -v systemctl >/dev/null 2>&1 || { echo "    no systemd; starting proxy directly"; return 1; }
      local unit="$HOME/.config/systemd/user/cc-trace.service"; mkdir -p "$(dirname "$unit")"
      sed -e "s|@PYTHON@|$PYTHON_BIN|g" -e "s|@PROXY@|$PROXY|g" \
          -e "s|@CC_TRACE_HOME@|$INSTALL_DIR|g" -e "s|@ONLY@|$CC_ONLY|g" \
          "$SCRIPT_DIR/service/cc-trace.service.template" > "$unit"
      sc --user daemon-reload; sc --user enable --now cc-trace.service; sc --user restart cc-trace.service
      echo "    systemd user service installed (serves: $CC_ONLY)" ;;
    *) return 1 ;;
  esac
}
echo "==> Installing always-on proxy service"
echo "    (restarts the proxy — any active Claude session briefly disconnects)"
if ! install_service; then
  CC_TRACE_HOME="$INSTALL_DIR" CC_TRACE_ONLY="$CC_ONLY" nohup "$PYTHON_BIN" "$PROXY" > "$INSTALL_DIR/proxy.log" 2>&1 &
fi
# wait for the first chosen agent's port
case "${AGENTS[0]}" in
  codex) FIRST_PORT=$PORT_CODEX ;; opencode) FIRST_PORT=$PORT_OPENCODE ;; *) FIRST_PORT=$PORT_CLAUDE ;;
esac
for _ in $(seq 1 40); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${FIRST_PORT}/cc-trace/health" 2>/dev/null && break; sleep 0.2; done

# ── JSON merge helper ──────────────────────────────────────────────────────────
merge_json() {  # merge_json <file> <python on dict `d`>
  "$PYTHON_BIN" - "$1" << PYEOF
import json, os, shutil, sys
path = sys.argv[1]; d = {}
if os.path.exists(path):
    try: d = json.load(open(path, encoding="utf-8"))
    except json.JSONDecodeError: print(f"   (skip {path}: invalid JSON)"); sys.exit(0)
    if not isinstance(d, dict): print(f"   (skip {path}: not an object)"); sys.exit(0)
    shutil.copy2(path, path + ".pre-cc-trace.bak")
os.makedirs(os.path.dirname(path), exist_ok=True)
${2}
json.dump(d, open(path, "w", encoding="utf-8"), indent=2); open(path,"a").write("\n")
print(f"   (updated {path})")
PYEOF
}

# ── Claude ─────────────────────────────────────────────────────────────────────
wire_claude() {
  echo "==> Claude -> ~/.claude/settings.json"
  local extra=""
  [ "$FRIENDLI" = "1" ] && extra="
env['ANTHROPIC_AUTH_TOKEN'] = '${FRIENDLI_KEY}'
d['model'] = '${FRIENDLI_MODEL_ID}'"
  merge_json "$HOME/.claude/settings.json" "
env = d.get('env', {})
env['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:${PORT_CLAUDE}'
env['ENABLE_TOOL_SEARCH'] = 'true'
d['env'] = env
d['showThinkingSummaries'] = True${extra}"
}
unwire_claude() {
  [ -f "$HOME/.claude/settings.json" ] || return 0
  echo "==> Claude: reverting (removing proxy base URL)"
  merge_json "$HOME/.claude/settings.json" "
env = d.get('env', {}); env.pop('ANTHROPIC_BASE_URL', None); d['env'] = env"
}

# ── Codex (OpenAI API key: route the built-in flow via a traced provider) ──────
# model_provider is a top-level user-config key (allowed; blocked only in project
# config), so ALL codex runs use the traced provider with no profile/wrapper.
codex_config() {  # codex_config set|unset
  local mode="$1"; local cfg="$HOME/.codex/config.toml"
  mkdir -p "$HOME/.codex"; rm -f "$HOME/.codex/fai-trace.config.toml"   # drop old overlay
  CC_MODE="$mode" CC_MODEL="$CODEX_MODEL" \
  CC_BASE="http://127.0.0.1:${PORT_CODEX}/__cc__/$(b64 "$CODEX_API")" \
  "$PYTHON_BIN" - "$cfg" << 'PYEOF'
import os, re, sys, shutil
path, mode, base, model = sys.argv[1], os.environ["CC_MODE"], os.environ["CC_BASE"], os.environ.get("CC_MODEL","")
s = ""
if os.path.exists(path):
    s = open(path, encoding="utf-8").read(); shutil.copy2(path, path + ".pre-cc-trace.bak")
# strip every past cc-trace injection (top-level keys + our tables)
s = re.sub(r'^# cc-trace:.*\n', '', s, flags=re.M)
s = re.sub(r'^(chatgpt_base_url|openai_base_url|model_provider|model)\s*=.*\n', '', s, flags=re.M)
s = re.sub(r'\n?\[model_providers\.fai-trace\][^\[]*', '\n', s)
s = re.sub(r'\n?\[profiles\.fai-trace\][^\[]*', '\n', s)
if mode == "set":
    head = '# cc-trace: route Codex through the proxy (OpenAI API key)\nmodel_provider = "fai-trace"\n'
    if model: head += f'model = "{model}"\n'
    tail = ('\n# cc-trace\n[model_providers.fai-trace]\nname = "FAI Trace (proxy)"\n'
            f'base_url = "{base}"\nenv_key = "OPENAI_API_KEY"\nwire_api = "responses"\n')
    s = head + s.lstrip("\n").rstrip("\n") + "\n" + tail
open(path, "w", encoding="utf-8").write(s)
print(f"   (codex: {'model_provider=fai-trace -> proxy' if mode=='set' else 'reverted'})")
PYEOF
}
wire_codex()  { echo "==> Codex -> ~/.codex/config.toml (OpenAI API key via proxy)"; codex_config set; }
unwire_codex() { [ -f "$HOME/.codex/config.toml" ] && { echo "==> Codex: reverting"; codex_config unset; } || rm -f "$HOME/.codex/fai-trace.config.toml"; }

# ── OpenCode (global config: forward each provider you use) ────────────────────
opencode_config() {  # opencode_config set|unset
  local mode="$1"; local real="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
  [ "$mode" = "unset" ] && [ ! -f "$real" ] && return 0
  mkdir -p "$(dirname "$real")"
  CC_MODE="$mode" CC_PORT="$PORT_OPENCODE" CC_HOME="$HOME" \
  "$PYTHON_BIN" - "$real" << 'PYEOF'
import base64, json, os, shutil, sys
path, mode = sys.argv[1], os.environ["CC_MODE"]
port, home = os.environ["CC_PORT"], os.environ["CC_HOME"]
def b64(u): return base64.urlsafe_b64encode(u.encode()).decode().rstrip("=")
DEFAULTS = {"anthropic": "https://api.anthropic.com/v1", "openai": "https://api.openai.com/v1"}
md = {}
try: md = json.load(open(os.path.join(home, ".cache/opencode/models.json"), encoding="utf-8"))
except Exception: pass
d = {}
if os.path.exists(path):
    try: d = json.load(open(path, encoding="utf-8"))
    except json.JSONDecodeError: print("   (skip opencode.json: invalid JSON)"); sys.exit(0)
    shutil.copy2(path, path + ".pre-cc-trace.bak")
prov = d.get("provider", {})
if mode == "unset":
    for p in prov.values():
        o = p.get("options", {}) if isinstance(p, dict) else {}
        if isinstance(o.get("baseURL"), str) and ("/__cc__/" in o["baseURL"] or "127.0.0.1:879" in o["baseURL"]):
            o.pop("baseURL", None)
    print("   (opencode: reverted)")
else:
    # Override EVERY provider OpenCode knows that has a real HTTP API — not just
    # the ones you've authed. You can pick any model at runtime (incl. free Zen
    # models like nemotron-3-ultra-free under the 'opencode' provider, which needs
    # no auth and is therefore absent from auth.json), and it's still traced.
    apis = dict(DEFAULTS)
    for pid, info in (md or {}).items():
        api = (info or {}).get("api")
        if api and "${" not in api:   # skip template-var endpoints we can't encode
            apis[pid] = api
    apis.update({pid: DEFAULTS[pid] for pid in DEFAULTS})  # ensure built-ins
    d.setdefault("$schema", "https://opencode.ai/config.json")
    prov = d.setdefault("provider", {})
    for pid in sorted(apis):
        prov.setdefault(pid, {}).setdefault("options", {})["baseURL"] = \
            f"http://127.0.0.1:{port}/__cc__/{b64(apis[pid])}"
    print(f"   (opencode: traced {len(apis)} providers, incl. 'opencode' free Zen models)")
json.dump(d, open(path, "w", encoding="utf-8"), indent=2); open(path,"a").write("\n")
PYEOF
}
wire_opencode()  { echo "==> OpenCode -> ~/.config/opencode/opencode.json"; opencode_config set; }
unwire_opencode() { echo "==> OpenCode: reverting"; opencode_config unset; }

# ── apply: wire chosen, revert the rest ────────────────────────────────────────
if chosen claude;   then wire_claude;   else unwire_claude;   fi
if chosen codex;    then wire_codex;    else unwire_codex;    fi
if chosen opencode; then wire_opencode; else unwire_opencode; fi

# ── fai-trace management command ───────────────────────────────────────────────
cat > "$INSTALL_DIR/fai-trace" << EOF
#!/usr/bin/env bash
# fai-trace — status | logs [N] | restart | stop | dirs
set -euo pipefail
HOME_DIR="$INSTALL_DIR"; OS="$OS"
case "\${1:-status}" in
  status) for p in claude:$PORT_CLAUDE codex:$PORT_CODEX opencode:$PORT_OPENCODE; do
            n="\${p%%:*}"; pt="\${p##*:}"
            curl -s --max-time 1 "http://127.0.0.1:\${pt}/cc-trace/health" >/dev/null 2>&1 \\
              && echo "  \$n  127.0.0.1:\${pt}  UP" || echo "  \$n  127.0.0.1:\${pt}  off"
          done ;;
  logs)    tail -n "\${2:-40}" -f "\$HOME_DIR/proxy.log" ;;
  restart) if [ "\$OS" = "Darwin" ]; then launchctl kickstart -k "gui/\$(id -u)/ai.friendli.cc-trace"
           else systemctl --user restart cc-trace.service; fi; echo "restarted" ;;
  stop)    if [ "\$OS" = "Darwin" ]; then launchctl bootout "gui/\$(id -u)/ai.friendli.cc-trace" 2>/dev/null || true
           else systemctl --user stop cc-trace.service 2>/dev/null || true; fi
           pkill -f "trace_proxy.py" 2>/dev/null || true; echo "stopped" ;;
  dirs)    echo "  $DIR_CLAUDE"; echo "  $DIR_CODEX"; echo "  $DIR_OPENCODE" ;;
  *) echo "usage: fai-trace [status|logs [N]|restart|stop|dirs]"; exit 1 ;;
esac
EOF
chmod +x "$INSTALL_DIR/fai-trace"
rm -f "$INSTALL_DIR/cc-trace" "$INSTALL_DIR/claude-trace" "$INSTALL_DIR/trace" \
      "$INSTALL_DIR/trace-up" "$INSTALL_DIR/fai-trace-up" "$INSTALL_DIR/opencode-trace.json" \
      "$INSTALL_DIR/claude.upstream" "$INSTALL_DIR/friendli.key" 2>/dev/null || true

# ── shell rc: just PATH (no wrappers) ──────────────────────────────────────────
RC=""; case "${SHELL##*/}" in zsh) RC="$HOME/.zshrc";; bash) RC="$HOME/.bashrc";; *) RC="$HOME/.profile";; esac
if [ -f "$RC" ] && grep -qF "# >>> cc-trace >>>" "$RC"; then
  "$PYTHON_BIN" - "$RC" << 'PYEOF'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(re.sub(r"\n?# >>> cc-trace >>>.*?# <<< cc-trace <<<\n?", "\n", s, flags=re.S))
PYEOF
fi
printf '\n# >>> cc-trace >>>\nexport PATH="%s:$PATH"\n# <<< cc-trace <<<\n' "$INSTALL_DIR" >> "$RC"

# ── done ───────────────────────────────────────────────────────────────────────
echo ""
echo "==> Done. Tracing: ${AGENTS[*]}"
echo "    Open a new terminal (or: source $RC), then use your agents normally."
echo "    Traces: $TRACE_ROOT/<agent>-traces   |   Manage: fai-trace status|logs|stop"
if chosen codex; then
  echo "    Codex needs an OpenAI API key (ChatGPT-subscription login can't be traced —"
  echo "    chatgpt.com is Cloudflare-protected). Set in your shell:  export OPENAI_API_KEY=sk-..."
  echo "    and use an API-accessible model: set 'model' in ~/.codex/config.toml or CC_TRACE_CODEX_MODEL."
fi
[ "$FRIENDLI" = "1" ] && echo "    Claude -> Friendli ($FRIENDLI_MODEL_ID)."
echo "    To change which agents are traced, re-run: ./setup.sh <agents>"
