#!/usr/bin/env python3
"""Check that a PNG is a valid App Store Connect app icon.

Requires exactly 1024x1024 pixels and a colour type without alpha
(0 = greyscale, 2 = RGB). Prints only dimensions and colour type.
Uses the standard library only.
"""
import struct
import sys

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
COLOUR_TYPES = {0: "greyscale", 2: "rgb", 3: "palette", 4: "greyscale+alpha", 6: "rgba"}


def main(argv):
    if len(argv) != 2:
        print("usage: check_icon.py <icon.png>")
        return 2
    try:
        with open(argv[1], "rb") as handle:
            head = handle.read(33)
    except OSError:
        print("FAIL icon: file cannot be read")
        return 1
    if len(head) < 33 or head[:8] != PNG_SIGNATURE or head[12:16] != b"IHDR":
        print("FAIL icon: not a PNG file")
        return 1
    width, height, bit_depth, colour_type = struct.unpack(">IIBB", head[16:26])
    name = COLOUR_TYPES.get(colour_type, "unknown")
    print("icon: %dx%d, bit depth %d, colour type %d (%s)"
          % (width, height, bit_depth, colour_type, name))
    ok = True
    if (width, height) != (1024, 1024):
        print("FAIL icon: must be exactly 1024x1024")
        ok = False
    if colour_type not in (0, 2):
        print("FAIL icon: must not have an alpha channel or a palette (colour type 0 or 2)")
        ok = False
    if ok:
        print("PASS icon: 1024x1024, no alpha channel")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
