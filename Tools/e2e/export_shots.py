#!/usr/bin/env python3
"""Copy the e2e screenshot attachments out of an exported xcresult.

Usage: export_shots.py EXPORT_DIR OUT_DIR
Reads manifest.json from `xcresulttool export attachments` and copies every
attachment whose name starts with "e2e-". Nothing else leaves the result
bundle, which can hold the launch environment.
"""
import json
import os
import shutil
import sys


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(src, "manifest.json"), encoding="utf-8") as fh:
        manifest = json.load(fh)
    names = []
    for test in manifest:
        for att in test.get("attachments", []):
            human = att.get("suggestedHumanReadableName", "")
            if not human.startswith("e2e-"):
                continue
            base = human.split("_")[0]
            ext = os.path.splitext(att["exportedFileName"])[1] or ".png"
            shutil.copyfile(os.path.join(src, att["exportedFileName"]), os.path.join(out, base + ext))
            names.append(base + ext)
    with open(os.path.join(out, "summary.txt"), "w", encoding="utf-8") as fh:
        fh.write("screenshots: %d\n" % len(names))
        fh.write("\n".join(sorted(names)) + "\n")
    print("copied %d screenshots" % len(names))


if __name__ == "__main__":
    main()
