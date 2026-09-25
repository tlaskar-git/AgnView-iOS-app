#!/usr/bin/env python3
"""Print the UDID of the first available simulator of a family.

Usage: pick_sim.py iPhone|iPad
Reads `xcrun simctl list devices available` and prefers the newest iOS runtime.
"""
import re
import subprocess
import sys


def main():
    family = sys.argv[1]
    out = subprocess.run(["xcrun", "simctl", "list", "devices", "available"],
                         capture_output=True, text=True, check=True).stdout
    runtime = None
    found = {}
    for line in out.splitlines():
        header = re.match(r"^-- iOS (\d+)\.(\d+) --", line)
        if header:
            runtime = (int(header.group(1)), int(header.group(2)))
            continue
        if line.startswith("-- "):
            runtime = None
            continue
        if runtime is None:
            continue
        m = re.match(r"^\s+(%s.*?) \(([0-9A-F-]{36})\)" % family, line)
        if m and runtime not in found:
            found[runtime] = m.group(2)
    if not found:
        print("no %s simulator found" % family, file=sys.stderr)
        sys.exit(1)
    print(found[max(found)])


if __name__ == "__main__":
    main()
