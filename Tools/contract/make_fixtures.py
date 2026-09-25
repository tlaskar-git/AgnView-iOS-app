#!/usr/bin/env python3
"""Turn the probe results of one hub version into sanitised decode fixtures.

Usage: make_fixtures.py PROBE_DIR OUT_DIR
PROBE_DIR holds the probe.json written by probe_hub.py. Structure and value
types are kept exactly. Host names, addresses, ports and machine paths are
replaced with placeholders. Standard library only.
"""
import json
import os
import re
import sys

PROBE_DIR, OUT_DIR = sys.argv[1], sys.argv[2]

# probe name -> fixture file name
JSON_FIXTURES = {
    "status_ok": "status.json",
    "status_bad_token": "error_401.json",
    "rate_limit_10": "error_429.json",
    "usage_accounts": "usage_accounts_empty.json",
    "usage_accounts_seeded": "usage_accounts.json",
    "jobs_list_fresh": "jobs_fresh.json",
    "jobs_list_in_progress": "jobs_in_progress.json",
    "jobs_list_after": "jobs_after.json",
    "job_get": "job_single.json",
    "job_get_missing": "error_404.json",
    "jobs_create_invalid": "error_400.json",
    "dispatch_codex": "dispatch_response.json",
    "dispatch_app_shape": "error_422.json",
    "logs_poll": "console_logs.json",
    "logs_after_end": "console_logs_empty.json",
    "live_sessions_empty": "live_sessions_empty.json",
}


def clean(text):
    text = re.sub(r"runner[A-Za-z0-9]+", "hub-host", text)
    text = text.replace("/home/runner/work/_temp/home", "/home/example")
    text = re.sub(r"(https?://[A-Za-z0-9.\-]+):\d{2,5}", r"\1:8765", text)
    text = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", "192.0.2.1", text)
    text = re.sub(r"hub-host", "hub.example.test", text)
    return text


def main():
    with open(os.path.join(PROBE_DIR, "probe.json"), encoding="utf-8") as fh:
        records = {r["name"]: r for r in json.load(fh)}
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, target in JSON_FIXTURES.items():
        rec = records[name]
        body = json.loads(clean(json.dumps(rec["json"])))
        with open(os.path.join(OUT_DIR, target), "w", encoding="utf-8", newline="\n") as fh:
            json.dump(body, fh, indent=2)
            fh.write("\n")
    events = clean(records["events_stream"]["text"])
    with open(os.path.join(OUT_DIR, "events_stream.txt"), "w", encoding="utf-8", newline="") as fh:
        fh.write(events)
    print("wrote %d fixtures to %s" % (len(JSON_FIXTURES) + 1, OUT_DIR))


if __name__ == "__main__":
    main()
