#!/usr/bin/env python3
"""Placeholder-only mock hub for CI and local UI tests.

Binds to 127.0.0.1 only. Every request needs the header X-AgnView-Token
(or Authorization: Bearer) with the literal test value below, as the real
hub expects. Headers and bodies are never logged. All data is fake.

MOCK_MODE selects the behaviour:
  ok    normal answers (default)
  401   every request is refused with 401
  429   every request is refused with 429
  slow  every answer waits longer than the 800 ms LAN budget
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TEST_KEY = "test-key-not-real"
MODE = os.environ.get("MOCK_MODE", "ok")
SLOW_SECONDS = 1.2
KEEP_ALIVE_SECONDS = 10
NOW = "2026-01-01T00:00:00Z"

STATUS = {
    "status": "healthy",
    "service": "AgnView Mock Hub",
    "version": "0.0.0-mock",
    "endpoints": {"local": "http://127.0.0.1"},
    "paired_agents_online": 3,
}

USAGE = [
    {"id": "acc-claude", "name": "Example Claude", "provider": "claude",
     "plan_name": "Example plan", "tokens_used": 120000, "tokens_limit": 500000,
     "cost_used": 12.5, "cost_limit": 100.0, "requests_count": 42,
     "last_probed": NOW, "is_active": True},
    {"id": "acc-chatgpt", "name": "Example ChatGPT", "provider": "chatgpt",
     "plan_name": "Example plan", "tokens_used": 80000, "tokens_limit": 400000,
     "cost_used": 8.0, "cost_limit": 50.0, "requests_count": 21,
     "last_probed": NOW, "is_active": True},
    {"id": "acc-gemini", "name": "Example Gemini", "provider": "gemini",
     "plan_name": "Example plan", "tokens_used": 30000, "tokens_limit": None,
     "cost_used": 0.0, "cost_limit": None, "requests_count": 9,
     "last_probed": None, "is_active": False},
]

JOBS = [
    {"id": "job-1", "title": "Example pipeline", "description": "Placeholder job",
     "status": "in_progress", "created_at": NOW, "updated_at": NOW,
     "tasks": [
         {"id": "task-1", "job_id": "job-1", "title": "Example task",
          "description": "Placeholder task", "assigned_agent": "example-agent",
          "status": "ready", "dependencies": [], "output_summary": None},
     ]},
]

LOGS = [
    {"id": 1, "agent": "system", "source": "system_notice",
     "content": "Mock hub started", "timestamp": NOW, "session_id": None},
    {"id": 2, "agent": "claude_code", "source": "stdout",
     "content": "Example output line", "timestamp": NOW, "session_id": "session-1"},
    {"id": 3, "agent": "user", "source": "user_input",
     "content": "Example prompt", "timestamp": NOW, "session_id": "session-1"},
]

LIVE_SESSIONS = [
    {"agent": "claude_code", "session_id": "session-1", "working_directory": "example-project",
     "busy": False, "idle_seconds": 12},
]

EVENTS = [
    ("connected", {"status": "connected", "transport": "lan"}),
    ("job_created", {"event_type": "job_created", "job_id": "job-1"}),
    ("agent_output_chunk", {"event_type": "agent_output_chunk", "agent": "claude_code",
                            "content": "Example output line"}),
]

ROUTES = {
    "/api/mobile/status": STATUS,
    "/api/usage/accounts": USAGE,
    "/api/jobs": JOBS,
    "/api/console/logs": LOGS,
    "/api/console/live-sessions": LIVE_SESSIONS,
}

MAX_BODY = 64 * 1024


def authorised(headers):
    token = headers.get("X-AgnView-Token")
    if token is None:
        auth = headers.get("Authorization") or ""
        if auth.startswith("Bearer "):
            token = auth[7:].strip()
    return token == TEST_KEY


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _gate(self):
        """Returns True when the request may continue."""
        if MODE == "slow":
            time.sleep(SLOW_SECONDS)
        if MODE == "429":
            self._send(429, {"detail": "Too many failed authentication attempts. Please try again later."})
            return False
        if MODE == "401" or not authorised(self.headers):
            self._send(401, {"detail": "Unauthorized: Invalid or missing AgnView authentication token."})
            return False
        return True

    def _events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            for name, data in EVENTS:
                frame = "event: %s\ndata: %s\n\n" % (name, json.dumps(data))
                self.wfile.write(frame.encode("utf-8"))
                self.wfile.flush()
            while True:
                time.sleep(KEEP_ALIVE_SECONDS)
                self.wfile.write(b"event: ping\ndata: {}\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def do_GET(self):
        if not self._gate():
            return
        path = self.path.split("?", 1)[0]
        if path == "/api/events":
            self._events()
        elif path in ROUTES:
            self._send(200, ROUTES[path])
        else:
            self._send(404, {"detail": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            self._send(413, {"detail": "too large"})
            return
        raw = self.rfile.read(length) if length else b""
        if not self._gate():
            return
        path = self.path.split("?", 1)[0]
        if path != "/api/console/dispatch":
            self._send(404, {"detail": "not found"})
            return
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            payload = None
        if not isinstance(payload, dict):
            self._send(422, {"detail": "invalid body"})
            return
        agent = payload.get("target_agent") or payload.get("agent") or "claude_code"
        if not isinstance(agent, str) or len(agent) > 64:
            agent = "claude_code"
        self._send(200, {
            "status": "dispatched",
            "agent": agent,
            "session_id": "sess-00000000",
            "message": "Placeholder dispatch accepted.",
        })

    def log_message(self, format, *args):  # noqa: A002
        pass


IROH_ALPN = b"agnview/console/1"


async def serve_iroh(ticket_path):
    """Serve the console protocol over iroh with placeholder data.

    Writes the ephemeral ticket to ticket_path (never to the log). Needs
    `pip install iroh==1.1.0`. Used only by the optional loopback CI job.
    """
    import asyncio
    import iroh

    endpoint = await iroh.Endpoint.bind(iroh.EndpointOptions(
        preset=iroh.preset_n0(), alpns=[IROH_ALPN]))
    ticket = str(iroh.EndpointTicket.from_addr(endpoint.addr()))
    tmp = ticket_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(ticket)
    os.replace(tmp, ticket_path)
    print("iroh console ready")
    sys.stdout.flush()

    async def write(send, frame):
        await send.write_all((json.dumps(frame) + "\n").encode("utf-8"))

    def classify(conn):
        try:
            paths = list(conn.paths())
        except Exception:
            return "iroh-relay"
        selected = [p for p in paths if getattr(p, "is_selected", False)] or paths
        for path in selected:
            if getattr(path, "is_ip", False) and not getattr(path, "is_relay", False):
                return "iroh-direct"
        return "iroh-relay"

    async def handle(incoming):
        conn = None
        try:
            conn = await (await incoming.accept()).connect()
            bi = await conn.accept_bi()
            send, recv = bi.send(), bi.recv()
            raw = await recv.read_to_end(64 * 1024)
            try:
                request = json.loads(raw.decode("utf-8") or "{}")
            except ValueError:
                request = None
            if not isinstance(request, dict) or request.get("token") != TEST_KEY:
                detail = "unauthorised" if isinstance(request, dict) else "malformed request"
                await write(send, {"type": "error", "detail": detail})
                await send.finish()
                await asyncio.sleep(1)
                return
            await write(send, {"type": "hello", "app": "AgnView", "protocol": 1,
                               "hostname": "example-host", "transport": classify(conn)})
            for row in LOGS:
                frame = dict(row)
                frame["type"] = "log"
                await write(send, frame)
            for _ in range(8):
                await asyncio.sleep(15)
                await write(send, {"type": "ping", "transport": classify(conn)})
        except Exception:
            return
        finally:
            if conn is not None:
                try:
                    result = conn.close(0, b"bye")
                    if asyncio.iscoroutine(result):
                        await result
                except Exception:
                    pass

    tasks = []
    while True:
        incoming = await endpoint.accept_next()
        if incoming is None:
            break
        tasks.append(asyncio.ensure_future(handle(incoming)))


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--iroh":
        import asyncio
        asyncio.run(serve_iroh(sys.argv[2]))
        return
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18081
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
