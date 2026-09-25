#!/usr/bin/env python3
"""Placeholder-only mock hub for CI and local UI tests.

Binds to 127.0.0.1 only. Every request needs the header X-Pairing-Key with
the literal test value below. Headers and bodies are never logged.
All data is fake.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TEST_KEY = "test-key-not-real"
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
    {"id": "log-1", "agent": "system", "source": "system_notice",
     "content": "Mock hub started", "timestamp": NOW, "session_id": None},
    {"id": "log-2", "agent": "claude_code", "source": "stdout",
     "content": "Example output line", "timestamp": NOW, "session_id": "session-1"},
    {"id": "log-3", "agent": "user", "source": "user_input",
     "content": "Example prompt", "timestamp": NOW, "session_id": "session-1"},
]

ROUTES = {
    "/api/mobile/status": STATUS,
    "/api/usage/accounts": USAGE,
    "/api/jobs": JOBS,
    "/api/console/logs": LOGS,
}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.headers.get("X-Pairing-Key") != TEST_KEY:
            self._send(401, {"error": "unauthorized"})
            return
        path = self.path.split("?", 1)[0]
        if path in ROUTES:
            self._send(200, ROUTES[path])
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, format, *args):  # noqa: A002
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18081
    server = HTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
