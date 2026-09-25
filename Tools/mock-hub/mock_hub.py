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

# Shapes copied from a real AgnView 0.1.8 hub (see Tools/contract). Only the
# values are placeholders.
STATUS = {
    "app": "AgnView",
    "status": "healthy",
    "endpoints": {"local": "http://localhost:8765", "localhost": "http://127.0.0.1:8765",
                  "lan": "http://127.0.0.1:8765", "hostname": "http://mock-hub.example.test:8765"},
    "bind_mode": "loopback",
    "transport_label": "Loopback only",
    "resolved_transport": "offline",
    "iroh": {"name": "iroh", "state": "disabled", "error": "mock", "ticket": None, "node_id": None,
             "relay_url": None, "configured_relay_url": None, "direct_addresses": [],
             "connections": 0, "last_resolved_transport": None},
}


def _window(label, amount, percent, countdown, sub=None, severity=None, active=False, breakdown=None):
    return {
        "key": label.lower().replace(" ", "_"), "label": label, "sub_label": sub,
        "unit": "percent" if percent is not None else "requests",
        "amount_text": amount, "percent_used": percent, "has_bar": percent is not None,
        "used": percent, "limit": 100.0 if percent is not None else None,
        "severity": severity, "is_active": active, "window_start": None, "window_end": None,
        "countdown_text": countdown, "breakdown": breakdown or [],
    }


def _account(acc_id, provider, name, plan, source, age_seconds, stale, windows, status,
             tokens=None, requests=None, error=None):
    checked = NOW if windows else None
    return {
        "id": acc_id, "provider": provider, "name": name, "auth_type": "session_token",
        "credential": "****", "org_id": None, "plan_name": plan,
        "requests_used": requests, "requests_limit": None, "requests_remaining": None,
        "tokens_used": tokens, "tokens_limit": None, "tokens_remaining": None,
        "cost_used_usd": None, "cost_limit_usd": None, "reset_time": None,
        "percent_used": None, "status": status, "last_checked": checked,
        "error_message": error, "base_url": None, "plan_label": plan,
        "session_percent_used": None, "weekly_percent_used": None,
        "observation": {"source": "placeholder", "windows": [], "plan": None},
        "usage": {"source": "placeholder", "source_label": source, "confidence": "high",
                  "measured_at": checked, "age_seconds": age_seconds,
                  "age_text": "measured 3m ago", "is_stale": stale, "error": error,
                  "plan_name": plan, "plan_label": plan, "windows": windows},
        "masked_credential": "****", "last_synced_at": checked, "needs_telemetry_sync": False,
    }


# Order as the real hub returns it: AntiGravity, ChatGPT, Claude, Gemini. The
# windows follow render.py of hub 0.1.12. amount_text is null when nothing was
# measured for a window.
USAGE = [
    _account("acc-agy", "antigravity", "Example AntiGravity", "Pro", "AntiGravity usage panel", 180.0, False, [
        _window("Five Hour Limit", "91% used", 91.0, "Resets in 1h 12m", severity="warning", active=True, breakdown=[
            _window("Gemini models", "91% used", 91.0, "Resets in 1h 12m", sub="Example Flash, Example Pro"),
            _window("Claude and GPT models", "0% used", 0.0, None, sub="Example models"),
        ]),
        _window("Weekly Limit", "48% used", 48.0, "Resets in 5d 4h"),
    ], "warning", tokens=402500, requests=58),
    _account("acc-chatgpt", "chatgpt", "Example ChatGPT", "Plus", "ChatGPT account usage", 2520.0, True, [
        _window("Session, 5 hours", "1% used", 1.0, "Resets in 3h 12m"),
        _window("Weekly", "2% used", 2.0, "Resets in 4d 6h"),
    ], "active"),
    _account("acc-claude", "claude", "Example Claude", "Max (5x)", "Anthropic account usage", 60.0, False, [
        _window("Current session", "4% used", 4.0, "Resets in 1h 34m", active=True),
        _window("Weekly limit", "1% used", 1.0, "Resets in 6d 22h", breakdown=[
            _window("Claude Code", "1% used", 1.0, None),
            _window("Chat", "0% used", 0.0, None),
        ]),
        _window("Weekly, Example model", "2% used", 2.0, "Resets in 6d 22h"),
    ], "active", tokens=184200, requests=96),
    _account("acc-gemini", "gemini", "Example Gemini", "Standard", "Google Code Assist tier", 300.0, False, [
        _window("Requests per day", "128 of 1,500 requests", 8.5, "Resets in 9h 4m"),
        _window("Weekly limit", None, None, None, sub="Google publishes no weekly figure for this tier"),
    ], "active", requests=128),
]


def _task(task_id, title, agent, status, deps, summary=None):
    return {"id": task_id, "job_id": "job-1", "title": title, "description": "Placeholder task",
            "assigned_agent": agent, "executed_by": None, "dependencies": deps, "status": status,
            "output_summary": summary, "artifacts": [], "revisions": [],
            "created_at": NOW, "updated_at": NOW, "completed_at": None}


# The hub sends tasks as an object keyed by task id, not as an array.
JOBS = [
    {"id": "job-1", "title": "Example pipeline", "description": "Placeholder job",
     "status": "in_progress", "created_at": NOW, "updated_at": NOW,
     "tasks": {
         "task-1": _task("task-1", "Example task", "example-agent", "ready", []),
         "task-2": _task("task-2", "Follow-up task", "example-agent", "pending", ["task-1"]),
     }},
]

LOGS = [
    {"id": 1, "agent": "system", "source": "system_notice",
     "content": "Mock hub started", "timestamp": NOW, "session_id": None, "metadata": {}},
    {"id": 2, "agent": "claude_code", "source": "stdout",
     "content": "Example output line", "timestamp": NOW, "session_id": "session-1", "metadata": {}},
    {"id": 3, "agent": "user", "source": "user_input",
     "content": "Example prompt", "timestamp": NOW, "session_id": "session-1", "metadata": {}},
]

LIVE_SESSIONS = [
    {"agent": "claude_code", "working_directory": "example-project", "dialect": "claude",
     "session_id": "session-1", "cli_session_id": None, "busy": False, "alive": True,
     "queued_turns": 0, "turns_completed": 1, "started_at": 1767225600.0,
     "uptime_seconds": 60.0, "idle_seconds": 12.0, "pid": 4242},
]

EVENTS = [
    ("connected", {"status": "connected", "transport": "lan"}),
    ("job_created", {"event_type": "job_created", "job_id": "job-1"}),
    ("agent_output_chunk", {"event_type": "agent_output_chunk", "agent": "claude_code",
                            "content": "Example output line"}),
]

CAPABILITIES = {
    "installed_agents": {"claude_code": {"installed": False, "path": None}},
    "installed_clis": [{"id": "claude_code", "name": "Claude Code", "available": False},
                       {"id": "codex", "name": "Codex", "available": False}],
    "connected_providers": [], "total_accounts": 0, "skills": [],
    "models": {
        "claude_code": [{"id": "example-model-large", "name": "Example Large"},
                        {"id": "example-model-small", "name": "Example Small"}],
        "codex": [{"id": "example-codex", "name": "Example Codex"}],
        "antigravity": [{"id": "example-flash", "name": "Example Flash"}],
        "all": [{"id": "auto", "name": "Auto"}],
    },
    "efforts": ["low", "medium", "high"],
    "efforts_by_provider": {
        "claude_code": [{"id": "default", "name": "Default"}, {"id": "low", "name": "Low Effort"},
                        {"id": "high", "name": "High Effort"}],
        "codex": [{"id": "default", "name": "Default"}, {"id": "low", "name": "Low Reasoning"},
                  {"id": "high", "name": "High Reasoning"}],
        "antigravity": [{"id": "default", "name": "Default"}, {"id": "low", "name": "Low Reasoning"}],
        "all": [{"id": "default", "name": "Auto"}],
    },
    "current_cwd": "/example/project", "default_cwd": "/example/project",
    "recent_paths": ["/example/project"], "autostart_enabled": False,
}

FILES = {"files": ["README.md", "docs/example-notes.md", "src/example.py"], "cwd": "/example/project"}

ROUTES = {
    "/api/system/capabilities": CAPABILITIES,
    "/api/system/files": FILES,
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
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            payload = None
        if not isinstance(payload, dict):
            self._send(422, {"detail": "invalid body"})
            return
        if path == "/api/jobs":
            self._create_job(payload)
            return
        if path == "/api/usage/refresh-all":
            self._send(200, USAGE)
            return
        if path.startswith("/api/tasks/") and path.endswith("/request-revision"):
            if not payload.get("feedback"):
                self._send(422, {"detail": "A revision needs feedback."})
                return
            self._send(200, {"id": "rev-1", "task_id": path.split("/")[3], "status": "open"})
            return
        if path.startswith("/api/tasks/") and path.endswith("/fail"):
            if not str(payload.get("reason") or "").strip():
                self._send(422, {"detail": "A failure reason is required."})
                return
            self._send(200, {"id": path.split("/")[3], "status": "failed"})
            return
        if path != "/api/console/dispatch":
            self._send(404, {"detail": "not found"})
            return
        # The real hub reads "agent" and answers 422 when it is missing.
        agent = payload.get("agent")
        if not isinstance(agent, str) or not agent or len(agent) > 64:
            self._send(422, {"detail": [{"type": "missing", "loc": ["body", "agent"],
                                         "msg": "Field required"}]})
            return
        self._send(200, {
            "status": "dispatched",
            "agent": agent,
            "session_id": "sess-00000000",
            "message": "Placeholder dispatch accepted.",
        })

    def do_DELETE(self):
        if not self._gate():
            return
        path = self.path.split("?", 1)[0]
        if path.startswith("/api/jobs/"):
            job_id = path[len("/api/jobs/"):]
            before = len(JOBS)
            JOBS[:] = [job for job in JOBS if job["id"] != job_id]
            if len(JOBS) == before:
                self._send(404, {"detail": "Job '%s' not found." % job_id})
            else:
                self._send(200, {"message": "Job '%s' deleted successfully." % job_id})
            return
        self._send(404, {"detail": "not found"})

    def _create_job(self, payload):
        """Same checks as the real hub: a title, one task, unique ids and no cycles."""
        title = str(payload.get("title") or "").strip()
        tasks = payload.get("tasks")
        if not title:
            self._send(400, {"detail": "Job title cannot be empty."})
            return
        if not isinstance(tasks, list) or not tasks:
            self._send(400, {"detail": "A job must contain at least one task."})
            return
        ids = [t.get("id") for t in tasks if isinstance(t, dict)]
        if len(set(ids)) != len(tasks):
            self._send(400, {"detail": "Duplicate task IDs detected in job specification."})
            return
        job_id = payload.get("id") or "job-%d" % (len(JOBS) + 1)
        built = {}
        for spec in tasks:
            deps = spec.get("dependencies") or []
            if any(dep not in ids for dep in deps):
                self._send(400, {"detail": "Task '%s' references a non-existent dependency." % spec.get("id")})
                return
            task = _task(spec["id"], spec.get("title") or "", spec.get("assigned_agent") or "example-agent",
                         "ready" if not deps else "pending", deps)
            task["job_id"] = job_id
            task["description"] = spec.get("description") or ""
            built[spec["id"]] = task
        job = {"id": job_id, "title": title, "description": payload.get("description") or "",
               "status": "pending", "created_at": NOW, "updated_at": NOW, "tasks": built}
        JOBS.append(job)
        self._send(200, job)

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
