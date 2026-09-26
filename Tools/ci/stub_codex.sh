#!/bin/sh
# Stub for the codex CLI on a CI runner. It prints one plain line and then one
# Codex JSON event whose text is the arguments it was given, so a test can see
# the model and effort the app asked for. Quotes, backslashes and line breaks
# in the arguments become spaces, which keeps the event valid JSON.
echo "stub agent line one"
args="$(printf '%s' "$*" | tr '\n\r"\' '    ')"
printf '{"type":"item.completed","item":{"type":"agent_message","text":"stub args: %s"}}\n' "$args"
exit 0
