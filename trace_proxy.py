#!/usr/bin/env python3
"""
trace_proxy — a transparent, multi-agent pass-through proxy for coding agents.

A coding agent (Claude Code, OpenCode, Codex, ...) is pointed at this proxy by
overriding its API base URL. The proxy relays every request to the upstream API
and streams the response back chunk-by-chunk as it arrives (no buffering, so
time-to-first-token is unaffected). On stream completion it writes the full
request and response — including extended-thinking / reasoning content — to JSON
files on disk.

Multiple agents are supported at once via *profiles*. Each profile binds its own
local port and forwards to its own upstream, writing traces into its own
directory and decoding its own wire format:

    claude    127.0.0.1:8788  -> https://api.anthropic.com   ~/claude-traces    (anthropic)
    codex     127.0.0.1:8789  -> https://api.openai.com      ~/codex-traces     (openai)
    opencode  127.0.0.1:8790  -> https://api.anthropic.com   ~/opencode-traces  (anthropic)

Profiles are read from $CC_TRACE_HOME/profiles.json (default ~/.cc-trace). One
process serves them all, so a single background service keeps every agent traced.

Auth headers are forwarded as-is and the bytes the client sees are identical to
what the upstream returned. API keys are redacted from the *saved* traces only.

Wire formats decoded for the reconstructed `.response.json`:
  - anthropic         /v1/messages          (text + thinking blocks)
  - openai chat       /v1/chat/completions  (choices[].delta, reasoning_content)
  - openai responses  /v1/responses         (response.* streaming events)
The raw stream is always also saved as `.response.sse`, so nothing is ever lost
even if a format is unrecognized.
"""

import asyncio
import json
import os
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

try:
    import httpx
    from starlette.applications import Starlette
    from starlette.requests import Request
    from starlette.responses import JSONResponse, Response, StreamingResponse
    from starlette.routing import Route
    import uvicorn
except ImportError:
    sys.stderr.write(
        "Missing dependencies. Install with:\n"
        "  pip install --user httpx starlette uvicorn\n"
    )
    sys.exit(1)


# ── Global configuration ──────────────────────────────────────────────────────

CC_TRACE_HOME = os.path.expanduser(os.environ.get("CC_TRACE_HOME", "~/.cc-trace"))
PROFILES_PATH = os.environ.get("CC_TRACE_PROFILES", os.path.join(CC_TRACE_HOME, "profiles.json"))

# Redaction is on by default; rotation is opt-in. These are process-global.
REDACT_KEYS = os.environ.get("CC_TRACE_REDACT", "1") == "1"
TRACE_MAX_AGE_DAYS = int(os.environ.get("CC_TRACE_MAX_AGE_DAYS", "0"))   # 0 = disabled
TRACE_MAX_FILES = int(os.environ.get("CC_TRACE_MAX_FILES", "0"))        # 0 = disabled, per profile

# On-demand: serve only these profiles (comma-separated names). Empty = all.
# Set by the per-agent launcher so e.g. `codex` only spins up the codex proxy.
ONLY_PROFILES = [s.strip() for s in os.environ.get("CC_TRACE_ONLY", "").split(",") if s.strip()]

# Idle auto-shutdown: exit after this many seconds with no traced request and
# nothing in flight. 0 = never (used for the always-on Claude service). The
# per-agent launcher passes a value so lazily-started proxies don't linger.
IDLE_TIMEOUT = float(os.environ.get("CC_TRACE_IDLE_TIMEOUT", "0"))

# Liveness tracking for idle shutdown.
ACTIVITY = {"last": 0.0, "inflight": 0}

# Headers we must NOT forward upstream (hop-by-hop / host-specific).
SKIP_REQUEST_HEADERS = {"host", "content-length", "accept-encoding", "connection"}
SKIP_RESPONSE_HEADERS = {"content-length", "content-encoding", "transfer-encoding", "connection"}

# One shared client: connection pooling + keep-alive across all profiles.
CLIENT = httpx.AsyncClient(timeout=None)


# ── Default profiles ──────────────────────────────────────────────────────────
# Used when no profiles.json exists yet (setup.sh writes a real one). Keeping a
# sane default here means `python trace_proxy.py` works out of the box.
DEFAULT_PROFILES = {
    "claude": {
        "port": 8788,
        "upstream": "https://api.anthropic.com",
        "trace_dir": "~/fai-traces/claude-traces",
        "format": "anthropic",
    },
    "codex": {
        "port": 8789,
        "upstream": "https://api.openai.com",
        "trace_dir": "~/fai-traces/codex-traces",
        "format": "openai",
    },
    "opencode": {
        "port": 8790,
        "upstream": "https://api.anthropic.com",
        "trace_dir": "~/fai-traces/opencode-traces",
        "format": "anthropic",
    },
}


def _parse_inject(raw: str) -> dict:
    try:
        v = json.loads(raw or "{}")
        return v if isinstance(v, dict) else {}
    except json.JSONDecodeError:
        sys.stderr.write("[trace] inject_fields is not valid JSON; ignoring\n")
        return {}


def load_profiles() -> dict:
    """Load profiles.json, falling back to DEFAULT_PROFILES. Each profile gets
    a mutable live `config` (upstream / strip_thinking_display / inject_fields)
    that POST /cc-trace/config can update without a restart."""
    raw = DEFAULT_PROFILES
    if os.path.exists(PROFILES_PATH):
        try:
            with open(PROFILES_PATH, encoding="utf-8") as f:
                loaded = json.load(f)
            if isinstance(loaded, dict) and loaded:
                raw = loaded
        except (OSError, json.JSONDecodeError) as e:
            sys.stderr.write(f"[trace] could not read {PROFILES_PATH} ({e}); using defaults\n")

    profiles = {}
    for name, p in raw.items():
        if ONLY_PROFILES and name not in ONLY_PROFILES:
            continue
        if not isinstance(p, dict) or "port" not in p:
            sys.stderr.write(f"[trace] skipping invalid profile '{name}'\n")
            continue
        trace_dir = os.path.expanduser(p.get("trace_dir", f"~/{name}-traces"))
        os.makedirs(trace_dir, exist_ok=True)
        profiles[name] = {
            "name": name,
            "port": int(p["port"]),
            "trace_dir": trace_dir,
            "format": p.get("format", "anthropic"),
            # Live, mutable config (mirrors the original single-profile proxy):
            "config": {
                "upstream": str(p.get("upstream", "https://api.anthropic.com")).rstrip("/"),
                "strip_thinking_display": bool(p.get("strip_thinking_display", False)),
                "inject_fields": _parse_inject(json.dumps(p.get("inject_fields", {}))),
                # When set, the proxy rewrites the upstream Authorization header to
                # `Bearer <auth_token>` (used for e.g. Friendli, so agents don't
                # need the real key configured). Empty = forward the agent's auth.
                "auth_token": str(p.get("auth_token", "")),
            },
        }
    return profiles


# ── Helpers ───────────────────────────────────────────────────────────────────

def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%f")


def _write(path: str, data) -> None:
    try:
        with open(path, "w", encoding="utf-8") as f:
            if isinstance(data, (bytes, bytearray)):
                f.write(data.decode("utf-8", errors="replace"))
            else:
                f.write(data)
    except Exception as e:  # never let logging break the proxy
        sys.stderr.write(f"[trace] failed to write {path}: {e}\n")


_REDACT_KEY_RE = re.compile(
    r"(anthropic[-_]?auth[-_]?token|x-api-key|authorization|api[-_]?key)",
    re.IGNORECASE,
)
_REDACT_VALUE_PATTERN = re.compile(r"^(sk-|key-|Bearer\s+)", re.IGNORECASE)


def _redact(obj):
    """Recursively redact API-key-like values in dicts/lists (saved traces only)."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if isinstance(v, str) and _REDACT_KEY_RE.search(k):
                out[k] = "[REDACTED]"
            elif isinstance(v, str) and _REDACT_VALUE_PATTERN.match(v):
                out[k] = "[REDACTED]"
            else:
                out[k] = _redact(v)
        return out
    if isinstance(obj, list):
        return [_redact(i) for i in obj]
    return obj


def _maybe_redact(obj):
    return _redact(obj) if REDACT_KEYS else obj


def _rotate_traces(trace_dir: str) -> None:
    """Remove old traces if rotation is configured. Groups files by request id
    (the stem before the first dot) so a request's request/response/sse files
    are removed together."""
    if TRACE_MAX_AGE_DAYS <= 0 and TRACE_MAX_FILES <= 0:
        return
    try:
        path = Path(trace_dir)
        files = [f for f in path.iterdir() if f.is_file()]
        if TRACE_MAX_AGE_DAYS > 0:
            cutoff = time.time() - TRACE_MAX_AGE_DAYS * 86400
            for f in list(files):
                if f.stat().st_mtime < cutoff:
                    f.unlink(missing_ok=True)
            files = [f for f in files if f.exists()]
        if TRACE_MAX_FILES > 0:
            rids: dict[str, float] = {}
            for f in files:
                stem = f.name.split(".")[0]
                rids[stem] = max(rids.get(stem, 0.0), f.stat().st_mtime)
            if len(rids) > TRACE_MAX_FILES:
                ordered = sorted(rids.items(), key=lambda x: x[1])
                for rid, _ in ordered[: len(rids) - TRACE_MAX_FILES]:
                    for f in path.iterdir():
                        if f.name.startswith(rid + "."):
                            f.unlink(missing_ok=True)
    except Exception as e:
        sys.stderr.write(f"[trace] rotation error in {trace_dir}: {e}\n")


# ── Request body rewriting (per-profile live config) ────────────────────────────

def _strip_display(req_json):
    """Remove thinking.display from the request (providers that reject it)."""
    if not isinstance(req_json, dict):
        return req_json, False
    thinking = req_json.get("thinking")
    if not isinstance(thinking, dict) or "display" not in thinking:
        return req_json, False
    new = dict(req_json)
    new_thinking = dict(thinking)
    new_thinking.pop("display", None)
    new["thinking"] = new_thinking
    return new, True


# ── SSE reconstruction: Anthropic Messages API ──────────────────────────────────

def _parse_anthropic_sse(raw_text: str):
    """Rebuild the final Messages API response object from a streamed SSE body,
    including `thinking` blocks. Best-effort; returns None on failure."""
    message = None
    blocks = {}  # index -> block dict
    for line in raw_text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            evt = json.loads(payload)
        except json.JSONDecodeError:
            continue
        etype = evt.get("type")
        if etype == "message_start":
            message = evt.get("message", {})
            message["content"] = []
        elif etype == "content_block_start":
            idx = evt.get("index")
            blocks[idx] = dict(evt.get("content_block", {}))
            for k in ("text", "thinking", "partial_json"):
                if k in blocks[idx] and blocks[idx][k] is None:
                    blocks[idx][k] = ""
        elif etype == "content_block_delta":
            idx = evt.get("index")
            delta = evt.get("delta", {})
            b = blocks.setdefault(idx, {})
            dt = delta.get("type")
            if dt == "text_delta":
                b["text"] = b.get("text", "") + delta.get("text", "")
            elif dt == "thinking_delta":
                b["thinking"] = b.get("thinking", "") + delta.get("thinking", "")
            elif dt == "signature_delta":
                b["signature"] = b.get("signature", "") + delta.get("signature", "")
            elif dt == "input_json_delta":
                b["partial_json"] = b.get("partial_json", "") + delta.get("partial_json", "")
        elif etype == "message_delta":
            if message is not None:
                d = evt.get("delta", {})
                message.update({k: v for k, v in d.items()})
                if "usage" in evt:
                    message.setdefault("usage", {}).update(evt["usage"])
    if message is None:
        return None
    for b in blocks.values():
        if b.get("type") == "tool_use" and "partial_json" in b:
            try:
                b["input"] = json.loads(b.pop("partial_json") or "{}")
            except json.JSONDecodeError:
                pass
    message["content"] = [blocks[i] for i in sorted(blocks.keys())]
    return message


# ── SSE reconstruction: OpenAI Chat Completions ─────────────────────────────────

def _parse_openai_chat_sse(raw_text: str):
    """Rebuild a Chat Completions response from a streamed SSE body. Accumulates
    `choices[].delta.content`, tool calls, and reasoning (`reasoning_content` or
    `reasoning`, as emitted by reasoning models / OpenAI-compatible gateways)."""
    base = None
    # choice index -> accumulator
    acc: dict[int, dict] = {}
    for line in raw_text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            evt = json.loads(payload)
        except json.JSONDecodeError:
            continue
        if base is None:
            base = {k: evt.get(k) for k in ("id", "object", "created", "model")}
        if "usage" in evt and evt["usage"]:
            base["usage"] = evt["usage"]
        for ch in evt.get("choices", []) or []:
            idx = ch.get("index", 0)
            a = acc.setdefault(idx, {"content": "", "reasoning": "", "role": "assistant",
                                     "tool_calls": {}, "finish_reason": None})
            if ch.get("finish_reason"):
                a["finish_reason"] = ch["finish_reason"]
            delta = ch.get("delta", {}) or {}
            if delta.get("role"):
                a["role"] = delta["role"]
            if delta.get("content"):
                a["content"] += delta["content"]
            # reasoning models expose one of these
            for rk in ("reasoning_content", "reasoning"):
                if delta.get(rk):
                    a["reasoning"] += delta[rk]
            for tc in delta.get("tool_calls", []) or []:
                tidx = tc.get("index", 0)
                slot = a["tool_calls"].setdefault(
                    tidx, {"id": tc.get("id"), "type": tc.get("type", "function"),
                           "function": {"name": "", "arguments": ""}})
                if tc.get("id"):
                    slot["id"] = tc["id"]
                fn = tc.get("function", {}) or {}
                if fn.get("name"):
                    slot["function"]["name"] += fn["name"]
                if fn.get("arguments"):
                    slot["function"]["arguments"] += fn["arguments"]
    if base is None:
        return None
    choices = []
    for idx in sorted(acc.keys()):
        a = acc[idx]
        msg = {"role": a["role"], "content": a["content"] or None}
        if a["reasoning"]:
            msg["reasoning_content"] = a["reasoning"]
        if a["tool_calls"]:
            msg["tool_calls"] = [a["tool_calls"][i] for i in sorted(a["tool_calls"].keys())]
        choices.append({"index": idx, "message": msg, "finish_reason": a["finish_reason"]})
    base["choices"] = choices
    return base


# ── SSE reconstruction: OpenAI Responses API ────────────────────────────────────

def _parse_openai_responses_sse(raw_text: str):
    """Rebuild a Responses API object from streamed `response.*` events. Codex's
    default `openai` provider uses this wire format. We prefer the terminal
    `response.completed`/`response.incomplete` event's full `response` object;
    otherwise we accumulate text + reasoning deltas as a fallback."""
    final = None
    text_acc = ""
    reasoning_acc = ""
    for line in raw_text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            evt = json.loads(payload)
        except json.JSONDecodeError:
            continue
        etype = evt.get("type", "")
        if etype in ("response.completed", "response.incomplete") and evt.get("response"):
            final = evt["response"]
        elif etype == "response.output_text.delta" and evt.get("delta"):
            text_acc += evt["delta"]
        elif etype == "response.reasoning_summary_text.delta" and evt.get("delta"):
            reasoning_acc += evt["delta"]
        elif etype == "response.reasoning_text.delta" and evt.get("delta"):
            reasoning_acc += evt["delta"]
    if final is not None:
        return final
    if not text_acc and not reasoning_acc:
        return None
    # Fallback object when no terminal event was seen.
    out = {"object": "response", "_reconstructed": True}
    if reasoning_acc:
        out["reasoning_summary"] = reasoning_acc
    if text_acc:
        out["output_text"] = text_acc
    return out


def _reconstruct(fmt: str, path: str, raw_text: str):
    """Pick a reconstruction strategy by format + request path."""
    if fmt == "openai":
        if "/responses" in path:
            return _parse_openai_responses_sse(raw_text)
        # default OpenAI streaming format
        rebuilt = _parse_openai_chat_sse(raw_text)
        if rebuilt is None and "/responses" not in path:
            rebuilt = _parse_openai_responses_sse(raw_text)
        return rebuilt
    # anthropic (default)
    return _parse_anthropic_sse(raw_text)


def _save_response(profile: dict, rid: str, raw: bytes, ctype: str, path: str) -> None:
    """Write the captured response to disk (reconstructing SSE if streamed)."""
    trace_dir = profile["trace_dir"]
    fmt = profile["format"]
    if "text/event-stream" in ctype:
        text = raw.decode("utf-8", errors="replace")
        rebuilt = _reconstruct(fmt, path, text)
        if rebuilt is not None:
            _write(os.path.join(trace_dir, f"{rid}.response.json"),
                   json.dumps(_maybe_redact(rebuilt), ensure_ascii=False, indent=2))
        # always keep the raw stream too, as ground truth
        _write(os.path.join(trace_dir, f"{rid}.response.sse"), text)
        return
    try:
        parsed = json.loads(raw)
        _write(os.path.join(trace_dir, f"{rid}.response.json"),
               json.dumps(_maybe_redact(parsed), ensure_ascii=False, indent=2))
    except json.JSONDecodeError:
        _write(os.path.join(trace_dir, f"{rid}.response.raw"), raw)


# ── Endpoint handlers (per profile, bound via closures) ─────────────────────────

def _redacted_config(cfg: dict) -> dict:
    """Config for display — never expose the raw auth token."""
    out = dict(cfg)
    out["auth_token"] = "[set]" if cfg.get("auth_token") else ""
    return out


def make_health(profile: dict):
    async def health(request: Request) -> Response:
        """Local health endpoint: answered by the proxy itself, never forwarded
        or traced. Reports the live config so `curl` shows the current upstream."""
        return JSONResponse({
            "status": "ok",
            "profile": profile["name"],
            "format": profile["format"],
            "trace_dir": profile["trace_dir"],
            **_redacted_config(profile["config"]),
        })
    return health


def make_set_config(profile: dict):
    async def set_config(request: Request) -> Response:
        """Update this profile's live config (upstream / strip / inject) without
        a restart. Omitted keys are left unchanged."""
        try:
            data = json.loads(await request.body())
            assert isinstance(data, dict)
        except Exception:
            return JSONResponse({"error": "body must be a JSON object"}, status_code=400)
        cfg = profile["config"]
        if "upstream" in data:
            cfg["upstream"] = str(data["upstream"]).rstrip("/")
        if "strip_thinking_display" in data:
            cfg["strip_thinking_display"] = data["strip_thinking_display"] in (True, 1, "1", "true")
        if "inject_fields" in data:
            cfg["inject_fields"] = data["inject_fields"] if isinstance(data["inject_fields"], dict) else {}
        if "auth_token" in data:
            cfg["auth_token"] = str(data["auth_token"])
        sys.stderr.write(f"[trace:{profile['name']}] config updated "
                         f"(upstream={cfg['upstream']}, auth_token={'set' if cfg['auth_token'] else 'none'})\n")
        return JSONResponse(_redacted_config(cfg))
    return set_config


def make_handler(profile: dict):
    name = profile["name"]
    trace_dir = profile["trace_dir"]

    async def handler(request: Request) -> Response:
        body = await request.body()
        path = request.url.path
        query = ("?" + request.url.query) if request.url.query else ""

        # Only trace requests that carry a body (model calls etc.); plain GETs
        # (health probes, model lists) are forwarded but not written to disk.
        trace = bool(body)
        rid = f"{_ts()}_{uuid.uuid4().hex[:8]}" if trace else None

        # --- parse + save request ---
        req_json = None
        if body:
            try:
                req_json = json.loads(body)
            except json.JSONDecodeError:
                pass
        if trace:
            if req_json is not None:
                _write(os.path.join(trace_dir, f"{rid}.request.json"),
                       json.dumps(_maybe_redact(req_json), ensure_ascii=False, indent=2))
            else:
                _write(os.path.join(trace_dir, f"{rid}.request.raw"), body)

        # --- optionally rewrite the FORWARDED body (live config) ---
        cfg = profile["config"]
        upstream_base = cfg["upstream"]
        inject = cfg["inject_fields"]
        fwd_body = body
        if isinstance(req_json, dict):
            new_json, changed = req_json, False
            if cfg["strip_thinking_display"]:
                new_json, changed = _strip_display(new_json)
            if inject and "model" in new_json and "messages" in new_json:
                merged = dict(new_json)
                merged.update(inject)
                new_json, changed = merged, True
            if changed:
                fwd_body = json.dumps(new_json).encode("utf-8")

        fwd_headers = {k: v for k, v in request.headers.items()
                       if k.lower() not in SKIP_REQUEST_HEADERS}

        # Optionally override the upstream auth (e.g. Friendli): replace whatever
        # the agent sent with our configured bearer token.
        token = cfg.get("auth_token")
        if token:
            fwd_headers = {k: v for k, v in fwd_headers.items()
                           if k.lower() not in ("authorization", "x-api-key")}
            fwd_headers["authorization"] = f"Bearer {token}"

        started = time.time()
        upstream_req = CLIENT.build_request(
            request.method, f"{upstream_base}{path}{query}",
            headers=fwd_headers, content=fwd_body,
        )
        try:
            upstream = await CLIENT.send(upstream_req, stream=True)
        except httpx.HTTPError as e:
            sys.stderr.write(f"[trace:{name}] upstream error for {path}: {e}\n")
            return JSONResponse(
                {"error": f"trace proxy: upstream unreachable ({e})"}, status_code=502)

        ctype = upstream.headers.get("content-type", "")
        status = upstream.status_code
        out_headers = {k: v for k, v in upstream.headers.items()
                       if k.lower() not in SKIP_RESPONSE_HEADERS}

        async def relay():
            """Yield chunks to the client as they arrive; save trace at the end."""
            chunks = []
            ACTIVITY["inflight"] += 1
            try:
                async for chunk in upstream.aiter_bytes():
                    chunks.append(chunk)
                    yield chunk
            finally:
                await upstream.aclose()
                ACTIVITY["inflight"] -= 1
                ACTIVITY["last"] = time.time()
                if trace:
                    _save_response(profile, rid, b"".join(chunks), ctype, path)
                    _rotate_traces(trace_dir)
                sys.stderr.write(
                    f"[trace:{name}] {request.method} {path} -> {status} "
                    f"({(time.time()-started)*1000:.0f}ms)"
                    + (f" saved {rid}\n" if trace else "\n")
                )

        return StreamingResponse(relay(), status_code=status, headers=out_headers)

    return handler


def build_app(profile: dict) -> Starlette:
    return Starlette(routes=[
        Route("/cc-trace/health", make_health(profile), methods=["GET"]),
        Route("/cc-trace/config", make_set_config(profile), methods=["POST"]),
        Route("/{path:path}", make_handler(profile),
              methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]),
    ])


# ── Multi-profile serving ───────────────────────────────────────────────────────

def _parse_cli_only(argv: list) -> None:
    """Allow `trace_proxy.py --only claude,codex` in addition to CC_TRACE_ONLY."""
    global ONLY_PROFILES
    for i, a in enumerate(argv):
        if a == "--only" and i + 1 < len(argv):
            ONLY_PROFILES = [s.strip() for s in argv[i + 1].split(",") if s.strip()]
        elif a.startswith("--only="):
            ONLY_PROFILES = [s.strip() for s in a.split("=", 1)[1].split(",") if s.strip()]


async def _idle_watchdog(servers: list) -> None:
    """Exit the process once it has been idle (no traced request, nothing in
    flight) for IDLE_TIMEOUT seconds. No-op when IDLE_TIMEOUT == 0."""
    if IDLE_TIMEOUT <= 0:
        return
    ACTIVITY["last"] = time.time()
    while True:
        await asyncio.sleep(min(15.0, IDLE_TIMEOUT))
        if ACTIVITY["inflight"] == 0 and (time.time() - ACTIVITY["last"]) > IDLE_TIMEOUT:
            sys.stderr.write(f"[trace] idle for {IDLE_TIMEOUT:.0f}s; shutting down.\n")
            for s in servers:
                s.should_exit = True
            return


async def serve_all(profiles: dict) -> None:
    servers = [
        uvicorn.Server(uvicorn.Config(build_app(p), host="127.0.0.1",
                                      port=p["port"], log_level="warning"))
        for p in profiles.values()
    ]

    async def run(server, profile):
        try:
            await server.serve()
        except asyncio.CancelledError:
            raise
        except BaseException as e:
            sys.stderr.write(
                f"[trace:{profile['name']}] could not serve on 127.0.0.1:{profile['port']} "
                f"({type(e).__name__}: {e}); is the port already in use? "
                f"This profile is disabled; others continue.\n"
            )

    tasks = [run(s, p) for s, p in zip(servers, profiles.values())]
    tasks.append(_idle_watchdog(servers))
    await asyncio.gather(*tasks)


def main() -> None:
    _parse_cli_only(sys.argv[1:])
    profiles = load_profiles()
    if not profiles:
        sys.stderr.write(
            f"[trace] no profiles to serve (only={ONLY_PROFILES or 'all'}); exiting\n")
        sys.exit(1)
    sys.stderr.write(f"[trace] home={CC_TRACE_HOME} profiles={PROFILES_PATH}\n")
    for p in profiles.values():
        sys.stderr.write(
            f"[trace] {p['name']:<10} 127.0.0.1:{p['port']} -> {p['config']['upstream']} "
            f"[{p['format']}] -> {p['trace_dir']}\n"
        )
    sys.stderr.write(
        f"[trace] redact={REDACT_KEYS} rotate_age={TRACE_MAX_AGE_DAYS}d "
        f"rotate_max={TRACE_MAX_FILES} idle_timeout={IDLE_TIMEOUT:.0f}s\n"
    )
    try:
        asyncio.run(serve_all(profiles))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
