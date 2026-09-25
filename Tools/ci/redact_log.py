#!/usr/bin/env python3
"""Redact sensitive values from tool output for a public CI log.

Reads stdin, writes stdout line by line. Standard library only.
Error text stays, so failures remain diagnosable.

Secret values are read from the environment. The names are in SECRET_ENV_NAMES
plus any names in REDACT_ENV_NAMES (space or comma separated).
"""
import os
import re
import sys

SECRET_ENV_NAMES = [
    "APPLE_TEAM_ID", "APP_BUNDLE_ID", "APPLE_PROVISIONING_PROFILE_NAME",
    "ASC_API_KEY_ID", "ASC_API_ISSUER_ID", "APPLE_DISTRIBUTION_CERT_PASSWORD",
    "APPLE_DISTRIBUTION_CERT_P12_BASE64", "APPLE_PROVISIONING_PROFILE_BASE64",
    "ASC_API_KEY_P8_BASE64", "KEYCHAIN_PASSWORD", "PROFILE_UUID",
]
MIN_SECRET_LEN = 4
ALLOWED_IDENTITIES = {"Apple Distribution", "-"}

_CERT_NAME = re.compile(
    r"((?:Apple Distribution|iPhone Distribution|Apple Development|iPhone Developer|"
    r"Mac Developer|Developer ID Application|3rd Party Mac Developer Application):)[^\"\r\n]*")
_SIGNING_IDENTITY = re.compile(r"(Signing Identity:[ \t]*)(.*)$")
_CSI = re.compile(
    r"(CODE_SIGN_IDENTITY(?:\[[^\]]*\])?[ \t]*[=:][ \t]*)"
    r"(\"[^\"]*\"|'[^']*'|Apple(?:\\ | )Distribution|\S*)")
_TEAM = re.compile(r"\([A-Z0-9]{10}\)")
_UUID = re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")
_HEX40 = re.compile(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{40}(?![0-9A-Fa-f])")
_MOBILEDEVICE = re.compile(r"[^\s\"']*Library/MobileDevice/[^\"\r\n]*")


def load_secrets(env=None):
    env = os.environ if env is None else env
    names = list(SECRET_ENV_NAMES)
    names += [n for n in re.split(r"[ ,]+", env.get("REDACT_ENV_NAMES", "")) if n]
    values = {env.get(n, "") for n in names}
    values = {v for v in values if len(v) >= MIN_SECRET_LEN}
    return sorted(values, key=len, reverse=True)


def _csi_value(m):
    prefix, value = m.group(1), m.group(2)
    bare = value.strip().strip("\"'").replace("\\ ", " ")
    return m.group(0) if bare in ALLOWED_IDENTITIES else prefix + "[redacted]"


def _signing_identity_value(m):
    bare = m.group(2).strip().strip("\"'")
    return m.group(0) if bare in ALLOWED_IDENTITIES else m.group(1) + "[redacted]"


def redact_line(line, secrets):
    for s in secrets:
        line = line.replace(s, "***")
    if "PROVISIONING_PROFILE_SPECIFIER" in line:
        return "[line redacted: PROVISIONING_PROFILE_SPECIFIER]"
    line = _CERT_NAME.sub(lambda m: m.group(1) + " [redacted]", line)
    line = _SIGNING_IDENTITY.sub(_signing_identity_value, line)
    line = _CSI.sub(_csi_value, line)
    line = _MOBILEDEVICE.sub("[path redacted]", line)
    line = _TEAM.sub("([redacted])", line)
    line = _UUID.sub("[uuid]", line)
    line = _HEX40.sub("[hash]", line)
    return line


def main():
    secrets = load_secrets()
    for raw in sys.stdin:
        end = "\n" if raw.endswith("\n") else ""
        sys.stdout.write(redact_line(raw.rstrip("\r\n"), secrets) + end)
        sys.stdout.flush()


if __name__ == "__main__":
    main()
