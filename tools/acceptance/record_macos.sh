#!/usr/bin/env bash
set -euo pipefail

app_bundle="${1:?usage: record_macos.sh APP_BUNDLE OUTPUT_MOV}"
output_path="${2:?usage: record_macos.sh APP_BUNDLE OUTPUT_MOV}"
executable="$app_bundle/Contents/MacOS/Amadeus"

mkdir -p "$(dirname "$output_path")"
AMADEUS_ACCEPTANCE_DEMO=1 "$executable" --acceptance-demo &
amadeus_app_pid=$!

cleanup() {
  kill "$amadeus_app_pid" 2>/dev/null || true
}
trap cleanup EXIT

sleep 6
kill -0 "$amadeus_app_pid"

# macOS requires Screen Recording consent even for CI shells. This succeeds on
# a developer Mac after Terminal has been authorized; GitHub-hosted runners may
# reject it, while the launch smoke check above still remains valid.
screencapture -x -v -V 24 "$output_path"
test -s "$output_path"
