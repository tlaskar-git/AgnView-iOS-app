#!/bin/sh
# Start an AgnView hub on a free loopback port with an empty home directory.
# Only for a CI runner. Never run this on a machine that has a real hub.
# Usage: start_hub.sh NAME
# Needs HUB_TOKEN (already masked), HUB_BIN (the agnview executable) and
# RUNNER_TEMP. Writes HUB_PORT and HUB_PID to GITHUB_ENV.
set -eu

name="$1"
home="$RUNNER_TEMP/home-$name"
mkdir -p "$home" "$RUNNER_TEMP/stubs"

# Stub for the codex CLI: prints two lines and exits.
printf '#!/bin/sh\necho "stub agent line one"\necho "stub agent line two"\nexit 0\n' > "$RUNNER_TEMP/stubs/codex"
chmod +x "$RUNNER_TEMP/stubs/codex"

port="$(python -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"

HOME="$home" \
AGNVIEW_IROH=off \
AGENT_RELAY_TOKEN="$HUB_TOKEN" \
AGENT_RELAY_DB_PATH="$home/hub.db" \
PATH="$RUNNER_TEMP/stubs:$PATH" \
nohup "$HUB_BIN" serve --port "$port" > "$RUNNER_TEMP/hub-$name.log" 2>&1 &
pid=$!

i=0
while [ "$i" -lt 60 ]; do
  i=$((i + 1))
  if curl -fsS -H "X-AgnView-Token: $HUB_TOKEN" "http://127.0.0.1:$port/api/mobile/status" > /dev/null 2>&1; then
    echo "hub $name ready after $i tries"
    {
      echo "HUB_PORT=$port"
      echo "HUB_PID=$pid"
    } >> "$GITHUB_ENV"
    exit 0
  fi
  sleep 1
done
echo "hub $name did not start. Log follows (the token is masked)."
tail -60 "$RUNNER_TEMP/hub-$name.log"
exit 1
