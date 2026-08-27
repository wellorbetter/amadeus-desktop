#!/usr/bin/env bash
set -euo pipefail

app_path="${1:?usage: record_linux.sh APP_PATH OUTPUT_MP4}"
output_path="${2:?usage: record_linux.sh APP_PATH OUTPUT_MP4}"
display_id="${AMADEUS_DEMO_DISPLAY:-:99}"

mkdir -p "$(dirname "$output_path")"
Xvfb "$display_id" -screen 0 1280x800x24 -nolisten tcp >/tmp/amadeus-xvfb.log 2>&1 &
amadeus_xvfb_pid=$!
export DISPLAY="$display_id"
openbox >/tmp/amadeus-openbox.log 2>&1 &
amadeus_openbox_pid=$!

cleanup() {
  if [[ -n "${amadeus_app_pid:-}" ]]; then
    kill "$amadeus_app_pid" 2>/dev/null || true
  fi
  kill "$amadeus_openbox_pid" 2>/dev/null || true
  kill "$amadeus_xvfb_pid" 2>/dev/null || true
}
trap cleanup EXIT

sleep 2
ffmpeg -y -loglevel warning -f x11grab -framerate 15 \
  -video_size 1280x800 -i "$display_id" -t 28 \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p "$output_path" &
amadeus_recorder_pid=$!

sleep 1
AMADEUS_ACCEPTANCE_DEMO=1 "$app_path" --acceptance-demo &
amadeus_app_pid=$!
sleep 6
kill -0 "$amadeus_app_pid"
wait "$amadeus_recorder_pid"
test -s "$output_path"
