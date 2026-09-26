#!/usr/bin/env python3
"""Pick the simulator for the App Store screenshots.

Usage: pick_screenshot_sim.py iphone|ipad

Prints key=value lines for $GITHUB_OUTPUT: udid, name, exact, prefix, size.

The App Store needs 6.9-inch iPhone screenshots (1320x2868, iPhone 16 Pro Max
or iPhone 17 Pro Max) and 13-inch iPad screenshots (2064x2752, iPad Pro
13-inch). When the runner has no such model, the script falls back to the
largest phone or tablet it has. It then sets exact=false, a fallback prefix
and size=report, so the job reports the real pixel size instead of failing.
"""
import json
import re
import subprocess
import sys

EXACT = {
    "iphone": (r"^iPhone (\d+) Pro Max$", "iphone-6.9", "1320x2868"),
    "ipad": (r"^iPad Pro 13-inch", "ipad-13", "2064x2752"),
}
FALLBACK = {
    "iphone": [r"Pro Max$", r"Plus$", r"^iPhone"],
    "ipad": [r"^iPad Pro \(12\.9-inch\)", r"^iPad Air 13-inch", r"^iPad Pro", r"^iPad"],
}


def newest_devices():
    out = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                         capture_output=True, text=True, check=True).stdout
    best = None
    for runtime, devices in json.loads(out)["devices"].items():
        match = re.search(r"iOS-(\d+)-(\d+)$", runtime)
        if not match or not devices:
            continue
        key = (int(match.group(1)), int(match.group(2)))
        if best is None or key > best[0]:
            best = (key, devices)
    return best[1] if best else []


def main():
    family = sys.argv[1]
    devices = [d for d in newest_devices() if d.get("isAvailable", True)]
    family_name = "iPhone" if family == "iphone" else "iPad"
    devices = [d for d in devices if d["name"].startswith(family_name)]
    if not devices:
        print("no %s simulator found" % family, file=sys.stderr)
        sys.exit(1)
    pattern, prefix, size = EXACT[family]
    exact = [d for d in devices if re.search(pattern, d["name"])]
    if exact:
        # The highest model number first, for example iPhone 17 Pro Max.
        exact.sort(key=lambda d: [int(n) for n in re.findall(r"\d+", d["name"])], reverse=True)
        chosen, is_exact = exact[0], True
    else:
        chosen, is_exact = None, False
        for pat in FALLBACK[family]:
            found = [d for d in devices if re.search(pat, d["name"])]
            if found:
                found.sort(key=lambda d: d["name"], reverse=True)
                chosen = found[0]
                break
        chosen = chosen or devices[0]
    print("udid=%s" % chosen["udid"])
    print("name=%s" % chosen["name"])
    print("exact=%s" % ("true" if is_exact else "false"))
    print("prefix=%s" % (prefix if is_exact else family + "-fallback"))
    print("size=%s" % (size if is_exact else "report"))


if __name__ == "__main__":
    main()
