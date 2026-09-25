#!/usr/bin/env python3
"""Collect the named screenshot attachments from an exported xcresult.

Usage: export_screenshots.py <export_dir> <out_dir> <device>
Reads manifest.json written by `xcresulttool export attachments`, copies PNGs
whose name starts with "<device>-" into out_dir and writes summary.txt.
"""
import json
import os
import shutil
import sys


def main():
    src, out, device = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)
    copied = []
    with open(os.path.join(src, "manifest.json"), encoding="utf-8") as fh:
        manifest = json.load(fh)
    for test in manifest:
        for att in test.get("attachments", []):
            human = att.get("suggestedHumanReadableName", "")
            if not human.startswith(device + "-"):
                continue
            base = human.split("_")[0]
            ext = os.path.splitext(att["exportedFileName"])[1] or ".png"
            dest = os.path.join(out, base + ext)
            shutil.copyfile(os.path.join(src, att["exportedFileName"]), dest)
            copied.append(os.path.basename(dest))
    with open(os.path.join(out, "summary.txt"), "w", encoding="utf-8") as fh:
        fh.write("device: %s\nscreenshots: %d\n" % (device, len(copied)))
        for name in sorted(copied):
            fh.write(name + "\n")
    print("copied %d screenshots" % len(copied))


if __name__ == "__main__":
    main()
