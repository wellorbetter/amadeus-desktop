#!/usr/bin/env bash
set -euo pipefail

app_path="${1:?usage: smoke_linux.sh APP_PATH}"
display_id="${AMADEUS_SMOKE_DISPLAY:-:98}"
smoke_data="$(mktemp -d)"

Xvfb "$display_id" -screen 0 1280x800x24 -nolisten tcp >/tmp/amadeus-smoke-xvfb.log 2>&1 &
amadeus_xvfb_pid=$!
export DISPLAY="$display_id"
openbox >/tmp/amadeus-smoke-openbox.log 2>&1 &
amadeus_openbox_pid=$!

cleanup() {
  if [[ -n "${amadeus_app_pid:-}" ]]; then
    kill "$amadeus_app_pid" 2>/dev/null || true
  fi
  kill "$amadeus_openbox_pid" 2>/dev/null || true
  kill "$amadeus_xvfb_pid" 2>/dev/null || true
  rm -rf -- "$smoke_data"
}
trap cleanup EXIT

sleep 2
XDG_DATA_HOME="$smoke_data" "$app_path" &
amadeus_app_pid=$!
sleep 8
kill -0 "$amadeus_app_pid"
