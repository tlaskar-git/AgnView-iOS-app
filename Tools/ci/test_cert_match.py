#!/usr/bin/env python3
"""Tests for cert_match.py. Builds throwaway self-signed certificates with
openssl in a temporary directory. Nothing is committed or printed."""
import hashlib
import os
import plistlib
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cert_match as cm


def make_der(tmp, tag):
    key, pem, der = (os.path.join(tmp, tag + ext) for ext in (".key", ".pem", ".der"))
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                    "-out", pem, "-days", "1", "-subj", "/CN=test-" + tag],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["openssl", "x509", "-in", pem, "-outform", "DER", "-out", der],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(der, "rb") as f:
        return f.read()


def identity_text(der_list):
    lines = ['  %d) %s "Fake Identity %d"' % (i + 1, hashlib.sha1(d).hexdigest().upper(), i)
             for i, d in enumerate(der_list)]
    return "\n".join(lines + ["     %d identities found" % len(der_list)])


def main():
    with tempfile.TemporaryDirectory() as tmp:
        a, b, c = make_der(tmp, "a"), make_der(tmp, "b"), make_der(tmp, "c")
        prof = plistlib.dumps({"DeveloperCertificates": [a, b]})
        empty = plistlib.dumps({})
        pset = cm.profile_fingerprints(prof)
        assert len(pset) == 2

        # match: keychain holds a, profile lists a and b
        n, m, k = cm.compare(pset, cm.identity_fingerprints(identity_text([a])))
        lines, ok = cm.report(n, m, k)
        assert (n, m, k) == (2, 1, 1) and ok and lines[-1] == "PASS", lines

        # no match: keychain holds c only
        n, m, k = cm.compare(pset, cm.identity_fingerprints(identity_text([c])))
        lines, ok = cm.report(n, m, k)
        assert (n, m, k) == (2, 1, 0) and not ok and lines[-1] == "FAIL"
        assert any(l.startswith("hint: the profile was created") for l in lines)
        assert not any("no identity" in l for l in lines)

        # empty keychain
        n, m, k = cm.compare(pset, cm.identity_fingerprints("     0 identities found"))
        lines, ok = cm.report(n, m, k)
        assert (n, m, k) == (2, 0, 0) and not ok
        assert any("imported no identity" in l for l in lines)

        # empty profile
        n, m, k = cm.compare(cm.profile_fingerprints(empty), cm.identity_fingerprints(identity_text([a])))
        lines, ok = cm.report(n, m, k)
        assert (n, m, k) == (0, 1, 0) and not ok

        # output never carries a fingerprint or a name
        text = "\n".join(lines)
        assert "Fake Identity" not in text and hashlib.sha1(a).hexdigest().upper() not in text

        # command line path
        pp, ip = os.path.join(tmp, "p.plist"), os.path.join(tmp, "i.txt")
        with open(pp, "wb") as f:
            f.write(prof)
        with open(ip, "w") as f:
            f.write(identity_text([b]))
        assert cm.main(["x", pp, ip]) == 0
    print("test_cert_match: all checks passed")


if __name__ == "__main__":
    main()
