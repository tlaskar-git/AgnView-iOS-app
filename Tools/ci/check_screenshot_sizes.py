#!/usr/bin/env python3
"""Check the pixel size of PNG screenshots.

Usage: check_screenshot_sizes.py <dir> <WIDTHxHEIGHT|report> [expected_count]

Reads the width and height from each PNG header (standard library only).
With WIDTHxHEIGHT every file must match, or the script exits with 1. With
report it prints the sizes and exits with 0. Exits with 1 when the folder
holds no PNG or fewer than expected_count files.
"""
import os
import struct
import sys

SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_size(path):
    with open(path, "rb") as fh:
        head = fh.read(24)
    if len(head) < 24 or head[:8] != SIGNATURE or head[12:16] != b"IHDR":
        raise ValueError("not a PNG file: %s" % path)
    return struct.unpack(">II", head[16:24])


def main():
    folder, want = sys.argv[1], sys.argv[2]
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    files = sorted(f for f in os.listdir(folder) if f.lower().endswith(".png"))
    bad = 0
    for name in files:
        width, height = png_size(os.path.join(folder, name))
        size = "%dx%d" % (width, height)
        ok = want == "report" or size == want
        print("%s %s %s" % ("ok  " if ok else "FAIL", size, name))
        if not ok:
            bad += 1
    if len(files) < count:
        print("FAIL expected at least %d PNG files, found %d" % (count, len(files)))
        sys.exit(1)
    if bad:
        print("FAIL %d file(s) are not %s" % (bad, want))
        sys.exit(1)
    print("checked %d file(s), size %s" % (len(files), want))


if __name__ == "__main__":
    main()
