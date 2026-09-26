#!/usr/bin/env python3
"""Collect the App Store screenshot attachments from an exported xcresult.

Usage: export_appstore_screenshots.py <export_dir> <out_dir> <prefix> <expected_count>

Reads manifest.json written by `xcrun xcresulttool export attachments`, copies
the PNGs whose name starts with "<prefix>-" into out_dir and exits with 1
when the count differs from the expected one.
"""
import json
import os
import re
import shutil
import sys

# xcresulttool writes "<name>_<index>_<UUID>" and puts the suffix before the
# last dot of the name, so iphone-6.9-01-console becomes
# iphone-6_0_<UUID>.9-01-console. This puts the name back together.
SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")


def clean_name(human):
    return SUFFIX.sub("", human, count=1)


def main():
    src, out, prefix, expected = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    os.makedirs(out, exist_ok=True)
    copied = []
    with open(os.path.join(src, "manifest.json"), encoding="utf-8") as fh:
        manifest = json.load(fh)
    for test in manifest:
        for att in test.get("attachments", []):
            base = clean_name(att.get("suggestedHumanReadableName", ""))
            if not base.startswith(prefix + "-"):
                continue
            ext = os.path.splitext(att["exportedFileName"])[1] or ".png"
            shutil.copyfile(os.path.join(src, att["exportedFileName"]), os.path.join(out, base + ext))
            copied.append(base + ext)
    print("copied %d screenshots" % len(copied))
    for name in sorted(copied):
        print(name)
    if len(copied) != expected:
        print("expected %d screenshots" % expected)
        sys.exit(1)


if __name__ == "__main__":
    main()
