#!/usr/bin/env python3
"""Wait until the mock hub answers on the given port (default 18081)."""
import sys
import time
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18081
KEY = "test-key-not-real"


def main():
    for _ in range(30):
        try:
            req = urllib.request.Request("http://127.0.0.1:%d/api/mobile/status" % PORT)
            req.add_header("X-Pairing-Key", KEY)
            with urllib.request.urlopen(req, timeout=2) as resp:
                if resp.status == 200:
                    print("mock hub ready")
                    return
        except OSError:
            pass
        time.sleep(1)
    print("mock hub did not start")
    sys.exit(1)


if __name__ == "__main__":
    main()
