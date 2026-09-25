#!/usr/bin/env python3
"""Probe a running AgnView hub and record what every endpoint the app calls
really returns. Standard library only.

Usage: probe_hub.py BASE_URL OUT_DIR
The token comes from the environment variable HUB_TOKEN and is never printed
or written: every recorded text has it replaced, and IPv4 addresses are
replaced with a documentation address.
"""
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request

BASE = sys.argv[1].rstrip("/")
OUT = sys.argv[2]
TOKEN = os.environ["HUB_TOKEN"]
CAP = 6000
IPV4 = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")
records = []


def scrub(text):
    text = text.replace(TOKEN, "<token>")
    return IPV4.sub("192.0.2.1", text)


def call(name, method, path, body=None, headers=None, token=True, timeout=15):
    hdrs = {"Accept": "application/json"}
    if token is True:
        hdrs["X-AgnView-Token"] = TOKEN
    elif token:
        hdrs["X-AgnView-Token"] = token
    hdrs.update(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status, raw, ctype = resp.status, resp.read(), resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as err:
        status, raw, ctype = err.code, err.read(), err.headers.get("Content-Type", "")
    text = scrub(raw.decode("utf-8", "replace"))
    try:
        parsed = json.loads(text)
    except ValueError:
        parsed = None
    rec = {"name": name, "method": method, "path": path, "status": status,
           "content_type": ctype, "json": parsed, "text": None if parsed is not None else text}
    records.append(rec)
    show(rec)
    return rec


def show(rec):
    if rec["json"] is not None:
        body = json.dumps(rec["json"], indent=2)
    else:
        body = rec["text"] or ""
    if len(body) > CAP:
        body = body[:CAP] + "\n... [cut]"
    print("=== %s: %s %s -> %s (%s)" % (rec["name"], rec["method"], rec["path"], rec["status"], rec["content_type"]))
    print(body)
    sys.stdout.flush()


def stream_events(seconds, trigger):
    """Read raw lines of /api/events for a few seconds while trigger() runs."""
    req = urllib.request.Request(BASE + "/api/events", headers={
        "X-AgnView-Token": TOKEN, "Accept": "text/event-stream"})
    chunks = []
    with urllib.request.urlopen(req, timeout=seconds + 10) as resp:
        status, ctype = resp.status, resp.headers.get("Content-Type", "")
        timer = threading.Timer(1.0, trigger)
        timer.start()
        end = time.time() + seconds
        while time.time() < end:
            line = resp.readline()
            if not line:
                break
            chunks.append(line)
    raw = scrub(b"".join(chunks).decode("utf-8", "replace"))
    rec = {"name": "events_stream", "method": "GET", "path": "/api/events", "status": status,
           "content_type": ctype, "json": None, "text": raw}
    records.append(rec)
    show(rec)


def main():
    os.makedirs(OUT, exist_ok=True)
    # Header behaviour
    call("status_ok", "GET", "/api/mobile/status")
    call("status_no_token", "GET", "/api/mobile/status", token=False)
    call("status_bad_token", "GET", "/api/mobile/status", token="wrong-token-value")
    call("status_alt_header", "GET", "/api/mobile/status", token=False, headers={"X-Agent-Relay-Token": TOKEN})
    call("status_bearer", "GET", "/api/mobile/status", token=False, headers={"Authorization": "Bearer " + TOKEN})
    call("status_old_app_header", "GET", "/api/mobile/status", token=False, headers={"X-Pairing-Key": TOKEN})
    call("usage_accounts", "GET", "/api/usage/accounts")
    call("usage_accounts_bad_token", "GET", "/api/usage/accounts", token="wrong-token-value")

    # Seed jobs through the API
    call("jobs_create_a", "POST", "/api/jobs", {
        "id": "job-probe-a", "title": "Probe pipeline A", "description": "Two tasks with a dependency",
        "tasks": [
            {"id": "a-build", "title": "Build", "description": "First task", "assigned_agent": "claude_code"},
            {"id": "a-review", "title": "Review", "description": "Second task", "assigned_agent": "codex",
             "dependencies": ["a-build"]}]})
    call("jobs_create_b", "POST", "/api/jobs", {
        "id": "job-probe-b", "title": "Probe pipeline B", "description": "",
        "tasks": [
            {"id": "b-one", "title": "One", "assigned_agent": "codex"},
            {"id": "b-two", "title": "Two", "assigned_agent": "antigravity", "dependencies": ["b-one"]}]})
    call("jobs_create_invalid", "POST", "/api/jobs", {"title": "", "tasks": []})
    call("jobs_list_fresh", "GET", "/api/jobs")
    call("task_claim", "POST", "/api/tasks/a-build/claim", {"agent": "claude_code"})
    call("jobs_list_in_progress", "GET", "/api/jobs")
    call("task_complete", "POST", "/api/tasks/a-build/complete", {"summary": "Built it", "artifacts": ["out.txt"]})
    call("task_claim_b", "POST", "/api/tasks/b-one/claim", {"agent": "codex"})
    call("task_fail_b", "POST", "/api/tasks/b-one/fail", {"reason": "Probe failure"})
    call("jobs_list_after", "GET", "/api/jobs")
    call("job_get", "GET", "/api/jobs/job-probe-a")
    call("job_get_missing", "GET", "/api/jobs/does-not-exist")
    call("jobs_bad_token", "GET", "/api/jobs", token="wrong-token-value")

    # Dispatch and console rows
    call("live_sessions_empty", "GET", "/api/console/live-sessions")
    call("logs_empty", "GET", "/api/console/logs?agent=all&limit=200")
    call("dispatch_codex", "POST", "/api/console/dispatch",
         {"agent": "codex", "prompt": "probe prompt", "working_directory": None, "session_id": None})
    call("dispatch_app_shape", "POST", "/api/console/dispatch",
         {"target_agent": "codex", "prompt": "probe prompt", "working_dir": None, "session_id": None})
    rows = []
    for _ in range(30):
        time.sleep(1)
        rec = call("logs_poll", "GET", "/api/console/logs?agent=all&limit=200")
        rows = rec["json"] if isinstance(rec["json"], list) else []
        if len(rows) >= 2:
            break
    if rows:
        call("logs_after_id", "GET", "/api/console/logs?agent=all&limit=200&after_id=%s" % rows[0].get("id"))
    call("logs_after_end", "GET", "/api/console/logs?agent=all&limit=200&after_id=999999")
    call("live_sessions_after", "GET", "/api/console/live-sessions")
    call("logs_bad_token", "GET", "/api/console/logs", token="wrong-token-value")

    def trigger():
        try:
            urllib.request.urlopen(urllib.request.Request(
                BASE + "/api/console/dispatch", method="POST",
                data=json.dumps({"agent": "codex", "prompt": "event probe"}).encode(),
                headers={"X-AgnView-Token": TOKEN, "Content-Type": "application/json"}), timeout=10).read()
        except Exception:
            pass

    stream_events(4, trigger)
    call("events_bad_token", "GET", "/api/events", token="wrong-token-value")

    # Rate limit last: ten failures inside a minute lock the address out.
    for i in range(12):
        rec = call("rate_limit_%02d" % (i + 1), "GET", "/api/mobile/status", token="wrong-token-value")
        if rec["status"] == 429:
            break
    call("status_after_limit", "GET", "/api/mobile/status")

    with open(os.path.join(OUT, "probe.json"), "w", encoding="utf-8") as fh:
        json.dump(records, fh, indent=2)
    for rec in records:
        with open(os.path.join(OUT, rec["name"] + ".json"), "w", encoding="utf-8") as fh:
            json.dump(rec, fh, indent=2)


if __name__ == "__main__":
    main()
