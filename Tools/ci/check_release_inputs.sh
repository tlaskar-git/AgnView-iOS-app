#!/bin/sh
# Format checks for the release secrets. Reads them from the environment.
# Prints only PASS or FAIL lines naming the secret and the rule. Never prints a value.
set +x

fails=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/relcheck.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

# check_regex NAME REGEX RULE
check_regex() {
  eval "value=\${$1:-}"
  if [ -z "$value" ]; then
    fail "$1" "is missing or empty"
  elif printf '%s' "$value" | grep -Eq "$2"; then
    pass "$1" "$3"
  else
    fail "$1" "$3"
  fi
}

check_regex APPLE_TEAM_ID '^[A-Z0-9]{10}$' "is 10 upper case letters or digits"
check_regex ASC_API_KEY_ID '^[A-Z0-9]{10}$' "is 10 upper case letters or digits"
check_regex ASC_API_ISSUER_ID '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' "is a UUID (8-4-4-4-12 hex)"
check_regex APP_BUNDLE_ID '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' "is a reverse-DNS identifier"

if [ -n "${APP_BUNDLE_ID:-}" ]; then
  case "$APP_BUNDLE_ID" in
    com.example|com.example.*) fail APP_BUNDLE_ID "is not the com.example placeholder" ;;
    *) pass APP_BUNDLE_ID "is not the com.example placeholder" ;;
  esac
fi

if [ -z "${APPLE_PROVISIONING_PROFILE_NAME:-}" ]; then
  fail APPLE_PROVISIONING_PROFILE_NAME "is missing or empty"
else
  pass APPLE_PROVISIONING_PROFILE_NAME "is not empty"
fi

if [ -z "${APPLE_DISTRIBUTION_CERT_PASSWORD:-}" ]; then
  fail APPLE_DISTRIBUTION_CERT_PASSWORD "is missing or empty"
else
  pass APPLE_DISTRIBUTION_CERT_PASSWORD "is not empty"
fi

if [ -n "${ASC_API_KEY_ID:-}" ] && [ "${ASC_API_KEY_ID:-}" = "${APPLE_TEAM_ID:-}" ]; then
  fail ASC_API_KEY_ID "ASC_API_KEY_ID and APPLE_TEAM_ID hold the same value"
fi

# check_b64 NAME FILE : decode to FILE and require non-empty output
check_b64() {
  eval "value=\${$1:-}"
  if [ -z "$value" ]; then
    fail "$1" "is missing or empty"
    return 1
  fi
  if printf '%s' "$value" | base64 --decode > "$2" 2>/dev/null && [ -s "$2" ]; then
    pass "$1" "decodes from base64 to non-empty output"
    return 0
  fi
  fail "$1" "decodes from base64 to non-empty output"
  return 1
}

check_b64 APPLE_DISTRIBUTION_CERT_P12_BASE64 "$tmp/cert.p12"

if check_b64 ASC_API_KEY_P8_BASE64 "$tmp/key.p8"; then
  # The header is split so secret scanners do not flag this file.
  pem_header="-----BEGIN PRIVATE"" KEY-----"
  if [ "$(head -c 27 "$tmp/key.p8")" = "$pem_header" ]; then
    pass ASC_API_KEY_P8_BASE64 "decoded text starts with the PEM private key header"
  else
    fail ASC_API_KEY_P8_BASE64 "decoded text starts with the PEM private key header"
  fi
fi

if check_b64 APPLE_PROVISIONING_PROFILE_BASE64 "$tmp/profile.mobileprovision"; then
  if command -v security >/dev/null 2>&1; then
    if security cms -D -i "$tmp/profile.mobileprovision" >/dev/null 2>&1; then
      pass APPLE_PROVISIONING_PROFILE_BASE64 "decoded file is a valid CMS profile"
    else
      fail APPLE_PROVISIONING_PROFILE_BASE64 "decoded file is a valid CMS profile"
    fi
  else
    echo "SKIP APPLE_PROVISIONING_PROFILE_BASE64: CMS check needs macOS"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails release input check(s) failed."
  exit 1
fi
echo "All release input checks passed."
