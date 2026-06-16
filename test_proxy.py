#!/usr/bin/env python3
"""
test_proxy — self-contained tests for trace_proxy.py (no real API keys needed).

Spins up:
  - a mock upstream that emits canned SSE in three wire formats
    (anthropic / openai chat / openai responses), with deliberate inter-chunk
    delays so we can prove the proxy streams rather than buffers;
  - trace_proxy serving three profiles (one per format) pointed at the mock,
    each writing to its own temp directory.

Then it asserts, for each profile:
  (a) the client receives the byte-identical stream,
  (b) chunks arrive incrementally (time-to-first-byte << full duration),
  (c) the reconstructed .response.json contains the text + reasoning/thinking,
  (d) the raw .response.sse is saved,
  (e) request + response land in the correct per-profile directory,
  (f) API keys are redacted from saved traces,
  (g) /cc-trace/health and /cc-trace/config endpoints work and are not traced.

Run:  ./venv/bin/python test_proxy.py     (from tracing-setup/, after setup deps)
or:   python3 test_proxy.py               (with httpx/starlette/uvicorn available)
"""

import asyncio
import base64
import json
import os
import sys
import tempfile
import time

import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

import trace_proxy

MOCK_PORT = 8999
CHUNK_DELAY = 0.05  # seconds between SSE chunks emitted by the mock upstream

# ── Canned SSE bodies (chunked) ────────────────────────────────────────────────

ANTHROPIC_SSE_CHUNKS = [
    'event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-4-8","content":[],"usage":{"input_tokens":10,"output_tokens":0}}}\n\n',
    'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me reason"}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" about this."}}\n\n',
    'event: content_block_start\ndata: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" world"}}\n\n',
    'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}\n\n',
    'event: message_stop\ndata: {"type":"message_stop"}\n\n',
]

OPENAI_CHAT_SSE_CHUNKS = [
    'data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"gpt-x","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}\n\n',
    'data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"gpt-x","choices":[{"index":0,"delta":{"reasoning_content":"Thinking hard"},"finish_reason":null}]}\n\n',
    'data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"gpt-x","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}\n\n',
    'data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"gpt-x","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}\n\n',
    'data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"gpt-x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":7}}\n\n',
    'data: [DONE]\n\n',
]

OPENAI_RESPONSES_SSE_CHUNKS = [
    'data: {"type":"response.created","response":{"id":"resp_1","object":"response"}}\n\n',
    'data: {"type":"response.reasoning_summary_text.delta","delta":"Reasoning step"}\n\n',
    'data: {"type":"response.output_text.delta","delta":"Hello"}\n\n',
    'data: {"type":"response.output_text.delta","delta":" world"}\n\n',
    # The authoritative terminal event carries the complete output, including a
    # reasoning item — this mirrors the real Responses API.
    'data: {"type":"response.completed","response":{"id":"resp_1","object":"response","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Reasoning step"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello world"}]}],"usage":{"input_tokens":10,"output_tokens":7}}}\n\n',
]

CASES = {
    "anthropic": {"path": "/v1/messages", "chunks": ANTHROPIC_SSE_CHUNKS},
    "openai": {"path": "/v1/chat/completions", "chunks": OPENAI_CHAT_SSE_CHUNKS},
    "responses": {"path": "/v1/responses", "chunks": OPENAI_RESPONSES_SSE_CHUNKS},
}


# ── Mock upstream ───────────────────────────────────────────────────────────────

def _chunks_for(path: str):
    if "/chat/completions" in path:
        return OPENAI_CHAT_SSE_CHUNKS
    if "/responses" in path:
        return OPENAI_RESPONSES_SSE_CHUNKS
    return ANTHROPIC_SSE_CHUNKS


async def mock_upstream(request: Request) -> Response:
    # Echo the received Authorization header (used to test auth_token override).
    if "echo-auth" in request.url.path:
        return JSONResponse({"authorization": request.headers.get("authorization", "")})
    # Echo that we saw an auth header (proves headers are forwarded as-is).
    assert request.headers.get("authorization") or request.headers.get("x-api-key"), \
        "auth header was not forwarded upstream"
    chunks = _chunks_for(request.url.path)

    async def gen():
        for c in chunks:
            yield c.encode("utf-8")
            await asyncio.sleep(CHUNK_DELAY)

    return StreamingResponse(gen(), media_type="text/event-stream")


async def mock_models(request: Request) -> Response:
    return JSONResponse({"data": [{"id": "mock-model"}]})


def build_mock():
    return Starlette(routes=[
        Route("/v1/models", mock_models, methods=["GET"]),
        Route("/{path:path}", mock_upstream,
              methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]),
    ])


# ── Test orchestration ──────────────────────────────────────────────────────────

class ServerThread:
    """Run a single uvicorn server in its own background thread/loop."""
    def __init__(self, app, port):
        self.server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port,
                                                     log_level="error"))
        import threading
        self.thread = threading.Thread(target=self.server.run, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.server.should_exit = True
        self.thread.join(timeout=5)


class ProxyCluster:
    """Run all proxy profiles in ONE event loop in a single background thread —
    mirroring production (trace_proxy.serve_all), where the shared httpx client
    lives on one loop. Running each profile on its own loop would bind the shared
    client to the first loop and break the others."""
    def __init__(self, profiles):
        self.servers = [
            uvicorn.Server(uvicorn.Config(trace_proxy.build_app(p), host="127.0.0.1",
                                          port=p["port"], log_level="error"))
            for p in profiles.values()
        ]
        import threading
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        asyncio.run(self._serve())

    async def _serve(self):
        await asyncio.gather(*(s.serve() for s in self.servers))

    def start(self):
        self.thread.start()

    def stop(self):
        for s in self.servers:
            s.should_exit = True
        self.thread.join(timeout=5)


def wait_for(url, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = httpx.get(url, timeout=1)
            if r.status_code < 500:
                return True
        except Exception:
            pass
        time.sleep(0.1)
    return False


def files_in(d):
    return sorted(os.listdir(d))


PASS, FAIL = "\033[32mPASS\033[0m", "\033[31mFAIL\033[0m"
results = []


def check(name, cond, detail=""):
    results.append(cond)
    print(f"  [{PASS if cond else FAIL}] {name}" + (f"  — {detail}" if detail and not cond else ""))


def main():
    tmp = tempfile.mkdtemp(prefix="trace-test-")
    profiles = {
        "claude":   {"port": 8801, "upstream": f"http://127.0.0.1:{MOCK_PORT}",
                     "trace_dir": os.path.join(tmp, "claude-traces"),   "format": "anthropic"},
        "codex":    {"port": 8802, "upstream": f"http://127.0.0.1:{MOCK_PORT}",
                     "trace_dir": os.path.join(tmp, "codex-traces"),    "format": "openai"},
        "opencode": {"port": 8803, "upstream": f"http://127.0.0.1:{MOCK_PORT}",
                     "trace_dir": os.path.join(tmp, "responses-traces"),"format": "openai"},
        # forwarding profile: no fixed upstream, format auto-detected per request
        "forward":  {"port": 8804, "upstream": "",
                     "trace_dir": os.path.join(tmp, "forward-traces"),  "format": "auto"},
    }
    profiles_path = os.path.join(tmp, "profiles.json")
    with open(profiles_path, "w") as f:
        json.dump(profiles, f)

    # Point trace_proxy at our temp profiles + ensure redaction on.
    os.environ["CC_TRACE_PROFILES"] = profiles_path
    os.environ["CC_TRACE_REDACT"] = "1"
    # reload module-level config that depends on env
    trace_proxy.PROFILES_PATH = profiles_path
    trace_proxy.REDACT_KEYS = True

    loaded = trace_proxy.load_profiles()

    # Mock upstream in its own thread/loop (it doesn't touch the shared client);
    # all proxy profiles share ONE loop, like production.
    mock = ServerThread(build_mock(), MOCK_PORT)
    cluster = ProxyCluster(loaded)
    mock.start()
    cluster.start()

    try:
        assert wait_for(f"http://127.0.0.1:{MOCK_PORT}/v1/models"), "mock upstream did not start"

        # ---- per-profile request/response checks ----
        # Map profile -> (path, expected text, expected reasoning substring)
        plan = {
            "claude":   ("/v1/messages", "Hello world", "Let me reason about this."),
            "codex":    ("/v1/chat/completions", "Hello world", "Thinking hard"),
            "opencode": ("/v1/responses", None, "Reasoning step"),  # responses: final object
        }

        for pname, (path, exp_text, exp_reason) in plan.items():
            prof = loaded[pname]
            base = f"http://127.0.0.1:{prof['port']}"
            assert wait_for(f"{base}/cc-trace/health"), f"{pname} proxy did not start"

            print(f"\n[{pname}] {path}  ({prof['format']})")

            # (g) health + config endpoints
            h = httpx.get(f"{base}/cc-trace/health").json()
            check("health reports profile", h.get("profile") == pname)
            cfgres = httpx.post(f"{base}/cc-trace/config",
                                json={"upstream": prof["config"]["upstream"]})
            check("config endpoint ok", cfgres.status_code == 200)

            # Stream a request through the proxy, timing chunk arrival.
            expected_body = "".join(_chunks_for(path))
            received = []
            t0 = time.time()
            first_byte_at = None
            with httpx.stream("POST", f"{base}{path}",
                              headers={"authorization": "Bearer sk-secret-test-key",
                                       "x-api-key": "sk-secret-test-key",
                                       "x-claude-code-session-id": "sess-abc",
                                       "x-claude-code-agent-id": "agent-123",
                                       "x-claude-code-parent-agent-id": "parent-9",
                                       "content-type": "application/json"},
                              content=json.dumps({"model": "m", "messages": [{"role": "user", "content": "hi"}]}),
                              timeout=30) as r:
                for chunk in r.iter_raw():
                    if chunk:
                        if first_byte_at is None:
                            first_byte_at = time.time() - t0
                        received.append(chunk)
            total = time.time() - t0
            body = b"".join(received).decode("utf-8")

            # (a) byte-identical passthrough
            check("client stream byte-identical to upstream", body == expected_body,
                  f"got {len(body)}B vs {len(expected_body)}B")
            # (b) incremental streaming (not buffered): first byte well before end
            n = len(_chunks_for(path))
            check("streamed incrementally (first byte early)",
                  first_byte_at is not None and first_byte_at < total - CHUNK_DELAY,
                  f"ttfb={first_byte_at:.2f}s total={total:.2f}s")

            # Give the finally-block a moment to flush trace files.
            time.sleep(0.3)
            tdir = prof["trace_dir"]
            fs = files_in(tdir)
            req_files = [x for x in fs if x.endswith(".request.json")]
            resp_json = [x for x in fs if x.endswith(".response.json")]
            resp_sse = [x for x in fs if x.endswith(".response.sse")]

            # (e) request+response landed in this profile's dir
            check("request saved to profile dir", len(req_files) == 1, str(fs))
            check("response.json saved", len(resp_json) == 1, str(fs))
            # (d) raw sse saved
            check("response.sse saved", len(resp_sse) == 1, str(fs))

            if resp_json:
                with open(os.path.join(tdir, resp_json[0])) as f:
                    resp = json.load(f)
                blob = json.dumps(resp)
                # (c) reasoning + text captured
                check("reasoning/thinking captured", exp_reason in blob,
                      f"missing {exp_reason!r}")
                if exp_text:
                    check("assistant text captured", exp_text in blob, f"missing {exp_text!r}")

            # (f) redaction: secret key must not appear in saved request
            if req_files:
                with open(os.path.join(tdir, req_files[0])) as f:
                    req_saved = f.read()
                check("api key redacted in saved request",
                      "sk-secret-test-key" not in req_saved)

            # (g) request headers saved, with sub-agent ids preserved + auth redacted
            hdr_files = [x for x in fs if x.endswith(".request.headers.json")]
            check("request headers saved", len(hdr_files) == 1, str(fs))
            if hdr_files:
                hd = json.load(open(os.path.join(tdir, hdr_files[0])))
                check("subagent headers captured (agent/session/parent)",
                      hd.get("x-claude-code-agent-id") == "agent-123"
                      and hd.get("x-claude-code-session-id") == "sess-abc"
                      and hd.get("x-claude-code-parent-agent-id") == "parent-9")
                check("auth redacted in headers file",
                      "sk-secret-test-key" not in json.dumps(hd))

        # ---- cross-profile isolation: each dir has exactly one request ----
        print("\n[isolation]")
        for pname in plan:
            cnt = len([x for x in files_in(loaded[pname]["trace_dir"])
                       if x.endswith(".request.json")])
            check(f"{pname} dir isolated (1 request)", cnt == 1, f"found {cnt}")

        # ---- auth_token override (Friendli mode): proxy rewrites upstream auth ----
        # Runs last because it sends an extra traced request to the claude dir.
        print("\n[auth_token override]")
        prof = loaded["claude"]; base = f"http://127.0.0.1:{prof['port']}"
        r = httpx.post(f"{base}/cc-trace/config", json={"auth_token": "FRIENDLI_SENTINEL"})
        check("config accepts auth_token (redacted in reply)",
              r.status_code == 200 and r.json().get("auth_token") == "[set]")
        h = httpx.get(f"{base}/cc-trace/health").json()
        check("health never leaks the token", h.get("auth_token") == "[set]")
        echo = httpx.post(f"{base}/v1/echo-auth",
                          headers={"authorization": "Bearer agent-placeholder-key",
                                   "content-type": "application/json"},
                          content=json.dumps({"model": "m", "messages": []})).json()
        check("upstream received the overridden Bearer token",
              echo.get("authorization") == "Bearer FRIENDLI_SENTINEL",
              f"got {echo.get('authorization')!r}")
        httpx.post(f"{base}/cc-trace/config", json={"auth_token": ""})  # reset

        # ---- forwarding mode: upstream encoded in the path, format auto-detected ----
        print("\n[forwarding /__cc__/]")
        fbase = f"http://127.0.0.1:{loaded['forward']['port']}"
        enc = base64.urlsafe_b64encode(f"http://127.0.0.1:{MOCK_PORT}".encode()).decode().rstrip("=")
        # OpenAI-shaped provider path
        with httpx.stream("POST", f"{fbase}/__cc__/{enc}/v1/chat/completions",
                          headers={"authorization": "Bearer k", "content-type": "application/json"},
                          content=json.dumps({"model": "m", "messages": [{"role": "user", "content": "hi"}]}),
                          timeout=30) as r:
            body = "".join(c.decode() for c in r.iter_raw() if c)
        # raw stream carries the deltas separately ("Hello" + " world")
        check("forwarded OpenAI call streamed through", "Hello" in body and "world" in body)
        # Anthropic-shaped provider path (same proxy, format auto-detected)
        with httpx.stream("POST", f"{fbase}/__cc__/{enc}/v1/messages",
                          headers={"authorization": "Bearer k", "content-type": "application/json"},
                          content=json.dumps({"model": "m", "messages": [{"role": "user", "content": "hi"}]}),
                          timeout=30) as r:
            list(r.iter_raw())
        time.sleep(0.4)
        fdir = loaded["forward"]["trace_dir"]
        fresp = sorted(x for x in files_in(fdir) if x.endswith(".response.json"))
        check("forwarding traced 2 responses to its dir", len(fresp) == 2, str(files_in(fdir)))
        blobs = [open(os.path.join(fdir, x)).read() for x in fresp]
        joined = "\n".join(blobs)
        check("openai format auto-detected (reasoning captured)", "Thinking hard" in joined)
        check("anthropic format auto-detected (thinking captured)",
              "Let me reason about this." in joined)

    finally:
        cluster.stop()
        mock.stop()

    print()
    if all(results):
        print(f"\033[32mALL {len(results)} CHECKS PASSED\033[0m  (traces in {tmp})")
        sys.exit(0)
    else:
        print(f"\033[31m{results.count(False)}/{len(results)} CHECKS FAILED\033[0m  (traces in {tmp})")
        sys.exit(1)


if __name__ == "__main__":
    main()
