#!/usr/bin/env bash
set -euo pipefail

app_path="${1:?usage: record_linux.sh APP_PATH OUTPUT_MP4}"
output_path="${2:?usage: record_linux.sh APP_PATH OUTPUT_MP4}"
display_id="${AMADEUS_DEMO_DISPLAY:-:99}"

mkdir -p "$(dirname "$output_path")"
Xvfb "$display_id" -screen 0 1280x800x24 -nolisten tcp >/tmp/amadeus-xvfb.log 2>&1 &
amadeus_xvfb_pid=$!
export DISPLAY="$display_id"
display_number="${display_id#:}"
display_number="${display_number%%.*}"
for _ in {1..50}; do
  [[ -S "/tmp/.X11-unix/X$display_number" ]] && break
  sleep 0.1
done
if [[ ! -S "/tmp/.X11-unix/X$display_number" ]]; then
  cat /tmp/amadeus-xvfb.log >&2
  kill "$amadeus_xvfb_pid" 2>/dev/null || true
  exit 1
fi
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
if ! kill -0 "$amadeus_openbox_pid" 2>/dev/null; then
  cat /tmp/amadeus-openbox.log >&2
  exit 1
fi
AMADEUS_ACCEPTANCE_DEMO=1 "$app_path" --acceptance-demo &
amadeus_app_pid=$!
# Cold CI runners may keep the GTK window alive before it is first mapped.
# Give it enough time to paint so the artifact starts on product UI, not black.
sleep 7
kill -0 "$amadeus_app_pid"

ffmpeg -y -loglevel warning -f x11grab -framerate 15 \
  -video_size 1280x800 -i "$display_id" -t 28 \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p "$output_path" &
amadeus_recorder_pid=$!
wait "$amadeus_recorder_pid"
test -s "$output_path"
