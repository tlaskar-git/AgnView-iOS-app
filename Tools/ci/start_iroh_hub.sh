#!/bin/sh
# Start a real AgnView hub on a free loopback port with iroh on, an empty home
# directory and stub agent CLIs. Then read the pairing payload from the hub the
# way the hub allows (loopback, Host header with the port, no Origin header),
# mask the ticket and the key, and hand both to later steps through GITHUB_ENV.
# Only for a CI runner. Never run this on a machine that has a real hub.
# Needs HUB_TOKEN (already masked), HUB_BIN (the agnview executable),
# RUNNER_TEMP and GITHUB_ENV. Prints no values.
set +x
set -eu

home="$RUNNER_TEMP/home-e2e"
stubs="$RUNNER_TEMP/stubs-e2e"
mkdir -p "$home" "$stubs"

printf '#!/bin/sh
echo "stub agent line one"
echo "stub agent line two"
exit 0
' > "$stubs/claude"
chmod +x "$stubs/claude"
# The codex stub prints the arguments it was given as a Codex JSON event.
cp "$(dirname "$0")/stub_codex.sh" "$stubs/codex"
chmod +x "$stubs/codex"

# Agent adapters that place the model and effort in the codex command.
mkdir -p "$home/.agnview"
cp "$(dirname "$0")/e2e_agents.yaml" "$home/.agnview/agents.yaml"

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"

env -u AGNVIEW_IROH -u AGNVIEW_IROH_API \
  HOME="$home" \
  AGENT_RELAY_TOKEN="$HUB_TOKEN" \
  AGENT_RELAY_DB_PATH="$home/hub.db" \
  PATH="$stubs:$PATH" \
  nohup "$HUB_BIN" serve --port "$port" > "$RUNNER_TEMP/hub-e2e.log" 2>&1 &
pid=$!

i=0
ready=""
while [ "$i" -lt 60 ]; do
  i=$((i + 1))
  if curl -fsS -H "X-AgnView-Token: $HUB_TOKEN" "http://127.0.0.1:$port/api/mobile/status" > /dev/null 2>&1; then
    ready="yes"
    break
  fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "FAIL: the hub did not start"
  tail -40 "$RUNNER_TEMP/hub-e2e.log"
  exit 1
fi
echo "hub ready after $i tries"

# The ticket appears once the iroh endpoint is bound.
i=0
ticket=""
key=""
while [ "$i" -lt 90 ]; do
  i=$((i + 1))
  body="$(curl -fsS -H "X-AgnView-Token: $HUB_TOKEN" "http://127.0.0.1:$port/api/mobile/pairing" 2> /dev/null || true)"
  if [ -n "$body" ]; then
    ticket="$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("pairing") or {}).get("iroh_ticket") or "")' 2> /dev/null || true)"
    key="$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("pairing_token") or "")' 2> /dev/null || true)"
  fi
  if [ -n "$ticket" ] && [ -n "$key" ]; then
    break
  fi
  sleep 1
done
if [ -z "$ticket" ] || [ -z "$key" ]; then
  echo "FAIL: no iroh ticket from the pairing route"
  state="$(curl -fsS -H "X-AgnView-Token: $HUB_TOKEN" "http://127.0.0.1:$port/api/transport" 2> /dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("iroh_state") or d.get("state") or "unknown")' 2> /dev/null || echo unknown)"
  echo "iroh state: $state"
  tail -40 "$RUNNER_TEMP/hub-e2e.log"
  exit 1
fi

echo "::add-mask::$ticket"
echo "::add-mask::$key"
{
  echo "AGNVIEW_E2E_TICKET=$ticket"
  echo "AGNVIEW_E2E_KEY=$key"
  echo "HUB_PID=$pid"
} >> "$GITHUB_ENV"
echo "pairing payload read, ticket and key masked"
