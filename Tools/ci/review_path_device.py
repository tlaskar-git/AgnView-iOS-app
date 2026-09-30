#!/usr/bin/env python3
"""Pick the simulator device type and runtime for the review-path workflow.

Usage: review_path_device.py iphone|ipad

Prints key=value lines for $GITHUB_OUTPUT: devicetype, runtime, name,
runtime_name. The runtime is the newest iOS runtime installed. The iPad is
the model App Review used when the runtime has it (iPad Air 11-inch (M3)),
then the nearest iPad Air 11-inch, then any iPad.
"""
import json
import re
import subprocess
import sys

PREFERRED = {
    "ipad": [r"^iPad Air 11-inch \(M3\)$", r"^iPad Air 11-inch", r"^iPad Air", r"^iPad Pro 11-inch", r"^iPad"],
    "iphone": [r"^iPhone 17 Pro$", r"^iPhone 16 Pro$", r"^iPhone \d+ Pro$", r"^iPhone"],
}


def simctl(*args):
    out = subprocess.run(["xcrun", "simctl", "list", *args, "-j"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def main():
    family = sys.argv[1]
    runtimes = [r for r in simctl("runtimes")["runtimes"]
                if r.get("isAvailable") and r.get("platform", "iOS") == "iOS"
                and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")]
    if not runtimes:
        print("no iOS runtime found", file=sys.stderr)
        sys.exit(1)
    runtimes.sort(key=lambda r: [int(n) for n in re.findall(r"\d+", r["version"])])
    runtime = runtimes[-1]
    supported = runtime.get("supportedDeviceTypes") or simctl("devicetypes")["devicetypes"]
    for pattern in PREFERRED[family]:
        found = [d for d in supported if re.search(pattern, d["name"])]
        if found:
            found.sort(key=lambda d: d["name"], reverse=True)
            chosen = found[0]
            break
    else:
        print("no %s device type found" % family, file=sys.stderr)
        sys.exit(1)
    print("devicetype=%s" % chosen["identifier"])
    print("name=%s" % chosen["name"])
    print("runtime=%s" % runtime["identifier"])
    print("runtime_name=%s" % runtime["name"])


if __name__ == "__main__":
    main()
