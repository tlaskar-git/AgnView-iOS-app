#!/usr/bin/env python3
"""Tests for redact_log.py with fake values only."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import redact_log as r

SECRETS = ["fakepassword123", "FAKEBUNDLE.example.test"]


def check(text, must_not, must_keep=()):
    out = r.redact_line(text, SECRETS)
    for bad in must_not:
        assert bad not in out, "leaked %r in %r" % (bad, out)
    for keep in must_keep:
        assert keep in out, "lost %r in %r" % (keep, out)


def main():
    check('  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Distribution: Test Person (ABCDE12345)"',
          ["Test Person", "ABCDE12345", "0123456789ABCDEF"], ["Apple Distribution:"])
    check("codesign with identity iPhone Distribution: Example Co Ltd (ZZZZZ99999)",
          ["Example Co", "ZZZZZ99999"])
    check("Apple Development: Someone Else (QWERTY1234)", ["Someone", "QWERTY1234"])
    check('    Signing Identity:     "Apple Development: Test Person (ABCDE12345)"', ["Test Person"])
    check('    Signing Identity:     "Apple Distribution"', [], ["Apple Distribution"])
    check('    Signing Identity:     "-"', [], ['"-"'])
    check("    Signing Identity:     Some Other Identity", ["Some Other"])
    check("CODE_SIGN_IDENTITY=Apple Distribution DEVELOPMENT_TEAM=x", [], ["CODE_SIGN_IDENTITY=Apple Distribution"])
    check("CODE_SIGN_IDENTITY=-", [], ["CODE_SIGN_IDENTITY=-"])
    check("CODE_SIGN_IDENTITY=Fake Identity Name", ["Fake Identity"])
    check("build setting PROVISIONING_PROFILE_SPECIFIER = My Profile Name", ["My Profile"])
    check("uses profile 12345678-1234-1234-1234-123456789abc now", ["12345678-1234"])
    check("hash 0123456789abcdef0123456789abcdef01234567 end", ["0123456789abcdef"])
    check("copy to ~/Library/MobileDevice/Provisioning Profiles/abc.mobileprovision",
          ["Provisioning Profiles", "abc.mobileprovision"])
    check("password is fakepassword123 ok", ["fakepassword123"], ["***"])
    check("bundle FAKEBUNDLE.example.test built", ["FAKEBUNDLE"])
    check("error: no such file or directory", [], ["error: no such file or directory"])
    check("error: Signing requires a development team (exit 65)", [], ["Signing requires a development team"])
    os.environ["REDACT_ENV_NAMES"] = "MY_EXTRA"
    os.environ["MY_EXTRA"] = "extra-secret-value"
    assert "extra-secret-value" in r.load_secrets()
    assert "***" in r.redact_line("x extra-secret-value y", r.load_secrets())
    print("test_redact_log: all checks passed")


if __name__ == "__main__":
    main()
