#!/usr/bin/env python3
"""Check a running AgnView hub against what the app decoders need.

Usage: check_contract.py BASE_URL [EXPECTATIONS_JSON]
The token comes from the environment variable HUB_TOKEN and is never printed.
Every endpoint the app calls is exercised against the live hub. The check
fails, naming the endpoint and the key, when a key the app needs is missing or
has a type the app cannot read. Standard library only.
"""
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = sys.argv[1].rstrip("/")
EXPECT_PATH = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "app_expectations.json")
TOKEN = os.environ["HUB_TOKEN"]

with open(EXPECT_PATH, encoding="utf-8") as fh:
    EXPECT = json.load(fh)
HEADER = EXPECT["token_header"]
failures = []
passes = []


def type_name(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def type_ok(value, allowed):
    actual = type_name(value)
    for name in allowed.split("|"):
        if name == actual or (name == "number" and actual == "integer"):
            return True
    return False


def check(value, schema, endpoint, path):
    """Append a failure for every mismatch between value and schema."""
    if isinstance(schema, str):
        schema = {"type": schema}
    allowed = schema.get("type", "object")
    if not type_ok(value, allowed):
        failures.append("%s: %s: expected %s, got %s" % (endpoint, path or "body", allowed, type_name(value)))
        return
    if isinstance(value, dict):
        for key, sub in (schema.get("required") or {}).items():
            if key not in value:
                failures.append("%s: %s: required key is missing" % (endpoint, join(path, key)))
            else:
                check(value[key], sub, endpoint, join(path, key))
        for key, sub in (schema.get("optional") or {}).items():
            if key in value:
                check(value[key], sub, endpoint, join(path, key))
        if "values" in schema:
            for key, item in value.items():
                check(item, schema["values"], endpoint, join(path, key))
    elif isinstance(value, list):
        sub = schema.get("items") or schema.get("values")
        if sub is not None:
            for index, item in enumerate(value):
                check(item, sub, endpoint, "%s[%d]" % (path, index))


def join(path, key):
    return "%s.%s" % (path, key) if path else key


def request(method, path, body=None, token=True, extra=None, timeout=20):
    headers = {"Accept": "application/json"}
    if token is True:
        headers[HEADER] = TOKEN
    elif token:
        headers[HEADER] = token
    headers.update(extra or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as err:
        status, raw = err.code, err.read()
    try:
        parsed = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        parsed = None
    return status, parsed


def expect_ok(name, method, path, schema_key, body=None, timeout=20, non_empty=False):
    endpoint = "%s %s" % (method, path.split("?")[0])
    status, parsed = request(method, path, body, timeout=timeout)
    if status != 200:
        failures.append("%s: expected status 200, got %s" % (endpoint, status))
        return None
    before = len(failures)
    check(parsed, EXPECT[schema_key], endpoint, "")
    if non_empty and isinstance(parsed, list) and not parsed:
        failures.append("%s: expected at least one element after seeding, got an empty list" % endpoint)
    if len(failures) == before:
        passes.append(endpoint)
    return parsed


def check_events():
    endpoint = "GET /api/events"
    req = urllib.request.Request(BASE + "/api/events", headers={HEADER: TOKEN, "Accept": "text/event-stream"})

    def trigger():
        request("POST", "/api/console/dispatch", {"agent": "codex", "prompt": "event contract check"})

    lines = []
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            ctype = resp.headers.get("Content-Type", "")
            if "text/event-stream" not in ctype:
                failures.append("%s: expected content type text/event-stream, got %s" % (endpoint, ctype))
                return
            threading.Timer(1.0, trigger).start()
            end = time.time() + 6
            while time.time() < end:
                raw = resp.readline()
                if not raw:
                    break
                lines.append(raw.decode("utf-8", "replace").rstrip("\r\n"))
    except (urllib.error.URLError, OSError) as err:
        failures.append("%s: could not read the stream: %s" % (endpoint, err))
        return
    events = []
    current = {}
    for line in lines:
        if line == "":
            if current:
                events.append(current)
            current = {}
        elif line.startswith(":"):
            continue
        elif ":" in line:
            field, _, value = line.partition(":")
            current[field] = value[1:] if value.startswith(" ") else value
    before = len(failures)
    if not events or events[0].get("event") != "connected":
        failures.append("%s: first event must be named connected, got %r" % (endpoint, events[:1]))
    for event in events:
        if "data" not in event:
            failures.append("%s: event %r has no data line" % (endpoint, event.get("event")))
            continue
        try:
            json.loads(event["data"])
        except ValueError:
            failures.append("%s: event %r data is not JSON" % (endpoint, event.get("event")))
    if len(events) < 2:
        failures.append("%s: expected an event after a dispatch, got only %d event(s)" % (endpoint, len(events)))
    if len(failures) == before:
        passes.append(endpoint)


def main():
    # Token handling: the header the app sends, a wrong value and none.
    expect_ok("status", "GET", "/api/mobile/status", "status")
    for label, token in (("wrong token", "wrong-token-value"), ("no token", False)):
        status, parsed = request("GET", "/api/usage/accounts", token=token)
        endpoint = "GET /api/usage/accounts (%s)" % label
        if status != 401:
            failures.append("%s: expected status 401, got %s" % (endpoint, status))
        else:
            before = len(failures)
            check(parsed, EXPECT["error_body"], endpoint, "")
            if len(failures) == before:
                passes.append(endpoint)

    # Seed through the API so every list has an element to check.
    seed_status, _ = request("POST", "/api/jobs", {
        "id": "contract-job", "title": "Contract job", "description": "",
        "tasks": [
            {"id": "contract-one", "title": "One", "assigned_agent": "codex"},
            {"id": "contract-two", "title": "Two", "assigned_agent": "claude_code",
             "dependencies": ["contract-one"]}]})
    if seed_status != 200:
        failures.append("POST /api/jobs (seed): expected status 200, got %s" % seed_status)
    request("POST", "/api/usage/accounts",
            {"provider": "claude", "name": "Contract claude", "auth_type": "session_token"}, timeout=40)

    expect_ok("usage", "GET", "/api/usage/accounts", "usage_accounts", timeout=40, non_empty=True)
    expect_ok("jobs", "GET", "/api/jobs", "jobs", non_empty=True)
    expect_ok("sessions", "GET", "/api/console/live-sessions", "live_sessions")

    dispatched = expect_ok("dispatch", "POST", "/api/console/dispatch", "dispatch_response",
                           body=EXPECT["dispatch_request"])
    if dispatched is not None and not str(dispatched.get("session_id", "")):
        failures.append("POST /api/console/dispatch: session_id is empty")
    for _ in range(30):
        status, rows = request("GET", "/api/console/logs?agent=all&limit=200")
        if status == 200 and isinstance(rows, list) and rows:
            break
        time.sleep(1)
    expect_ok("logs", "GET", "/api/console/logs?agent=all&limit=200", "console_logs", non_empty=True)
    status, parsed = request("GET", "/api/console/logs?agent=all&limit=200&after_id=999999")
    if status != 200 or parsed != []:
        failures.append("GET /api/console/logs (after_id past the end): expected 200 and an empty list, got %s %r"
                        % (status, parsed))
    else:
        passes.append("GET /api/console/logs (after_id past the end)")

    check_events()

    # The old app request keys must still be refused clearly, and a lock-out
    # must answer with a detail message. The lock-out is not required.
    for _ in range(12):
        status, parsed = request("GET", "/api/mobile/status", token="wrong-token-value")
        if status == 429:
            before = len(failures)
            check(parsed, EXPECT["error_body"], "GET /api/mobile/status (rate limit)", "")
            if len(failures) == before:
                passes.append("GET /api/mobile/status (rate limit)")
            break

    print("passed %d checks:" % len(passes))
    for item in passes:
        print("  ok   %s" % item)
    if failures:
        print("")
        print("CONTRACT BROKEN: %d problem(s)" % len(failures))
        for item in failures:
            print("  FAIL %s" % item)
        sys.exit(1)
    print("contract holds")


if __name__ == "__main__":
    main()
