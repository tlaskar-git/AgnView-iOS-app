#!/bin/sh
# Runs AgnViewUITests/ReviewPathTests ITERATIONS times, each on a simulator
# created for that run and deleted after it, so every run is a new install.
# Odd runs tap Try the demo as soon as it shows, even runs wait 5 s first.
# On an iPad, runs 3-4, 7-8 and so on start in landscape.
#
# Inputs (environment): DEVICE, CONFIG, TSAN, DEVTYPE, RUNTIME, DEVNAME,
# ITERATIONS, RUNNER_TEMP. Writes to $RUNNER_TEMP/review and appends a table
# to $GITHUB_STEP_SUMMARY. Exits 1 when any run failed.
set -u

OUT="$RUNNER_TEMP/review"
mkdir -p "$OUT/logs" "$OUT/crashes" "$OUT/results" "$OUT/tsan"
XCTESTRUN="$(ls "$RUNNER_TEMP"/dd/Build/Products/*.xctestrun | head -1)"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$REPORTS"
SUMMARY="$OUT/summary.md"
failed=0

{
  echo "### review path: $DEVICE, $CONFIG, tsan $TSAN"
  echo
  echo "Device type: $DEVNAME ($DEVTYPE). Runtime: $RUNTIME. Runs: $ITERATIONS."
  echo
  echo "| run | delay | landscape | result | seconds | crash | log findings |"
  echo "|---|---|---|---|---|---|---|"
} > "$SUMMARY"

i=1
while [ "$i" -le "$ITERATIONS" ]; do
  delay=0
  if [ $((i % 2)) -eq 0 ]; then delay=5; fi
  land=0
  if [ "$DEVICE" = "ipad" ] && [ $(((i - 1) / 2 % 2)) -eq 1 ]; then land=1; fi

  udid="$(xcrun simctl create "review-$i" "$DEVTYPE" "$RUNTIME")"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1
  marker="$OUT/.marker-$i"
  touch "$marker"
  # The app's own lifecycle lines, and every error or fault in its process.
  xcrun simctl spawn "$udid" log stream --level info --style compact \
    --predicate 'process == "AgnView" AND (subsystem == "com.example.agnview" OR messageType == error OR messageType == fault)' \
    > "$OUT/logs/device-$i.log" 2>&1 &
  logpid=$!

  tsanlog=""
  if [ "$TSAN" = "true" ]; then tsanlog="$OUT/tsan/run-$i"; fi
  started=$(date +%s)
  TEST_RUNNER_AGNVIEW_REVIEW_PATH=1 \
  TEST_RUNNER_AGNVIEW_REVIEW_DELAY="$delay" \
  TEST_RUNNER_AGNVIEW_REVIEW_LANDSCAPE="$land" \
  TEST_RUNNER_AGNVIEW_REVIEW_TSAN_LOG="$tsanlog" \
  xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:AgnViewUITests/ReviewPathTests \
    -resultBundlePath "$OUT/results/run-$i.xcresult" > "$OUT/logs/xcodebuild-$i.log" 2>&1
  rc=$?
  seconds=$(( $(date +%s) - started ))
  sleep 2
  kill "$logpid" 2>/dev/null
  wait "$logpid" 2>/dev/null

  crash="no"
  for f in $(find "$REPORTS" -newer "$marker" -type f -iname '*AgnView*' 2>/dev/null); do
    crash="yes"
    cp "$f" "$OUT/crashes/run-$i-$(basename "$f")"
  done
  # Lines in the app's own log that point at a fault, a crash or a SwiftUI
  # runtime warning.
  findings="$(grep -Eic ' (E|F|Er|Fa) +AgnView\[|fatal error|precondition|unexpectedly found nil|publishing changes from within view updates|modifying state during view update|watchdog fired|stream terminated|stream ended' "$OUT/logs/device-$i.log" 2>/dev/null || true)"
  grep 'REVIEW-PATH:' "$OUT/logs/xcodebuild-$i.log" | sed 's/^.*REVIEW-PATH: //' > "$OUT/logs/steps-$i.txt"

  if [ "$rc" -eq 0 ] && [ "$crash" = "no" ]; then
    result="pass"
    rm -rf "$OUT/results/run-$i.xcresult"
  else
    result="FAIL ($rc)"
    failed=$((failed + 1))
    echo "---- run $i failed (exit $rc, crash $crash) ----"
    cat "$OUT/logs/steps-$i.txt"
    grep -E 'error: |failed \(' "$OUT/logs/xcodebuild-$i.log" | head -20
    echo "-- app lifecycle (last 40 lines) --"
    grep 'com.example.agnview' "$OUT/logs/device-$i.log" | tail -40
  fi
  echo "run $i: delay $delay landscape $land -> $result in ${seconds}s, crash $crash, log findings $findings"
  echo "| $i | $delay | $land | $result | $seconds | $crash | $findings |" >> "$SUMMARY"

  xcrun simctl shutdown "$udid" > /dev/null 2>&1
  xcrun simctl delete "$udid" > /dev/null 2>&1
  i=$((i + 1))
done

{
  echo
  echo "Failed runs: $failed of $ITERATIONS."
  if ls "$OUT"/tsan/run-* > /dev/null 2>&1; then
    echo
    echo "Thread Sanitizer reports: $(ls "$OUT"/tsan/run-* | wc -l | tr -d ' ') files."
    echo
    echo '```'
    grep -h -A12 'WARNING: ThreadSanitizer' "$OUT"/tsan/run-* | head -120
    echo '```'
  fi
} >> "$SUMMARY"
cat "$SUMMARY" >> "$GITHUB_STEP_SUMMARY"
cat "$SUMMARY"
[ "$failed" -eq 0 ]
