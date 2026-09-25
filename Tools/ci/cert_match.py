#!/usr/bin/env python3
"""Compare the certificates in a provisioning profile with the signing
identities in a keychain. Standard library only.

Usage: cert_match.py <profile.plist> <find-identity-output.txt>

The plist comes from `security cms -D -i <profile> -o <plist>`. The text file
comes from `security find-identity -p codesigning <keychain>` (no -v, so
identities that are not trusted yet still list).

Prints counts and PASS or FAIL only. It never prints a fingerprint, a name or
a path. Exit code 0 on a match, 1 on no match, 2 on bad input.
"""
import hashlib
import plistlib
import re
import sys

_IDENTITY_LINE = re.compile(r"^\s*\d+\)\s+([0-9A-Fa-f]{40})\b")


def profile_fingerprints(plist_bytes):
    """SHA-1 (upper case hex) of each DER certificate in DeveloperCertificates."""
    data = plistlib.loads(plist_bytes)
    certs = data.get("DeveloperCertificates") or []
    return {hashlib.sha1(bytes(c)).hexdigest().upper() for c in certs}


def identity_fingerprints(find_identity_text):
    """Only the 40-hex-digit fingerprints. The rest of each line holds names."""
    found = set()
    for line in find_identity_text.splitlines():
        m = _IDENTITY_LINE.match(line)
        if m:
            found.add(m.group(1).upper())
    return found


def compare(profile_set, keychain_set):
    return len(profile_set), len(keychain_set), len(profile_set & keychain_set)


def report(n, m, k):
    """Return (lines, ok). The lines never carry sensitive values."""
    lines = [
        "profile lists %d certificate(s)" % n,
        "keychain has %d signing identit%s" % (m, "y" if m == 1 else "ies"),
        "%d in common" % k,
    ]
    if k == 0:
        lines.append("hint: the profile was created for a different certificate than the one in the .p12")
        if n >= 1 and m == 0:
            lines.append("hint: the .p12 imported no identity (wrong password or no private key in the .p12)")
    lines.append("PASS" if k > 0 else "FAIL")
    return lines, k > 0


def main(argv):
    if len(argv) != 3:
        print("usage: cert_match.py <profile.plist> <find-identity-output.txt>")
        return 2
    try:
        with open(argv[1], "rb") as f:
            pset = profile_fingerprints(f.read())
        with open(argv[2], "r", errors="replace") as f:
            kset = identity_fingerprints(f.read())
    except Exception as exc:  # report the type only, never the message
        print("cannot read input (%s)" % type(exc).__name__)
        return 2
    lines, ok = report(*compare(pset, kset))
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
