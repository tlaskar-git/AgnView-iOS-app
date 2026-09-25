#!/bin/sh
# Consistency checks between the provisioning profile, the secrets and the
# imported signing certificate. macOS only. Prints only PASS or FAIL lines.
# Usage: check_profile.sh <profile.mobileprovision> <keychain>
# Reads APPLE_TEAM_ID, APP_BUNDLE_ID and APPLE_PROVISIONING_PROFILE_NAME from the environment.
set +x

profile="${1:-}"
keychain="${2:-}"
if [ -z "$profile" ] || [ -z "$keychain" ] || [ ! -f "$profile" ]; then
  echo "usage: check_profile.sh <profile.mobileprovision> <keychain>"
  exit 2
fi

fails=0
pass() { echo "PASS profile: $1"; }
fail() { echo "FAIL profile: $1"; fails=$((fails + 1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/profcheck.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
plist="$tmp/profile.plist"

if ! security cms -D -i "$profile" > "$plist" 2>/dev/null; then
  fail "decodes as a CMS file"
  exit 1
fi
pass "decodes as a CMS file"

pb=/usr/libexec/PlistBuddy
read_key() { "$pb" -c "Print :$1" "$plist" 2>/dev/null; }
mask() { [ -n "$1" ] && echo "::add-mask::$1"; }

name="$(read_key Name)"
team="$(read_key TeamIdentifier:0)"
appid="$(read_key Entitlements:application-identifier)"
expiry="$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null)"
mask "$name"
mask "$team"
mask "$appid"

if [ -n "$name" ] && [ "$name" = "${APPLE_PROVISIONING_PROFILE_NAME:-}" ]; then
  pass "Name matches APPLE_PROVISIONING_PROFILE_NAME"
else
  fail "Name does not match APPLE_PROVISIONING_PROFILE_NAME"
fi

if [ -n "$team" ] && [ "$team" = "${APPLE_TEAM_ID:-}" ]; then
  pass "TeamIdentifier matches APPLE_TEAM_ID"
else
  fail "TeamIdentifier does not match APPLE_TEAM_ID"
fi

if [ -n "$appid" ] && [ "$appid" = "${APPLE_TEAM_ID:-}.${APP_BUNDLE_ID:-}" ]; then
  pass "application-identifier matches APPLE_TEAM_ID.APP_BUNDLE_ID"
else
  fail "application-identifier does not match APPLE_TEAM_ID.APP_BUNDLE_ID"
fi

exp_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" +%s 2>/dev/null)"
now_epoch="$(date -u +%s)"
if [ -z "$exp_epoch" ]; then
  fail "ExpirationDate cannot be read"
elif [ "$exp_epoch" -gt "$now_epoch" ]; then
  pass "profile has not expired"
else
  fail "profile has expired"
fi

# Certificates: the profile lists DER certificates, the keychain lists imported
# identities. cert_match.py compares SHA-1 fingerprints and prints counts only.
# find-identity runs without -v so identities that are not yet trusted still list.
here="$(cd "$(dirname "$0")" && pwd)"
security find-identity -p codesigning "$keychain" > "$tmp/identities.txt" 2>/dev/null
python3 "$here/cert_match.py" "$plist" "$tmp/identities.txt" > "$tmp/match.txt" 2>&1
match_rc=$?
sed 's/^/profile certs: /' "$tmp/match.txt"
if [ "$match_rc" -eq 0 ]; then
  pass "DeveloperCertificates contains an imported signing identity"
else
  fail "DeveloperCertificates does not contain an imported signing identity"
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails profile check(s) failed."
  exit 1
fi
echo "All profile checks passed."
