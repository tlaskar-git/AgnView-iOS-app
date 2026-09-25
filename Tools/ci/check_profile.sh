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

# Certificate SHA-1 fingerprints in the temporary keychain.
security find-certificate -a -Z "$keychain" 2>/dev/null \
  | sed -n 's/^SHA-1 hash: *//p' | tr 'a-f' 'A-F' > "$tmp/keychain.sha1"

matched=0
i=0
while :; do
  b64="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$plist" 2>/dev/null)" || break
  [ -n "$b64" ] || break
  sum="$(printf '%s' "$b64" | base64 --decode 2>/dev/null | shasum -a 1 | cut -d ' ' -f 1 | tr 'a-f' 'A-F')"
  mask "$sum"
  if [ -n "$sum" ] && grep -qx "$sum" "$tmp/keychain.sha1"; then
    matched=1
  fi
  i=$((i + 1))
done

if [ "$matched" -eq 1 ]; then
  pass "DeveloperCertificates contains the imported certificate (match)"
else
  fail "DeveloperCertificates does not contain the imported certificate (mismatch)"
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails profile check(s) failed."
  exit 1
fi
echo "All profile checks passed."
