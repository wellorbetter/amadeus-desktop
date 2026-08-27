#!/usr/bin/env bash
set -euo pipefail

frames_dir="${1:?usage: frames_to_video.sh FRAMES_DIR OUTPUT_MP4}"
output_path="${2:?usage: frames_to_video.sh FRAMES_DIR OUTPUT_MP4}"

mkdir -p "$(dirname "$output_path")"
ffmpeg -y -loglevel warning -framerate 0.25 \
  -i "$frames_dir/frame-%02d.png" -c:v libx264 -r 15 \
  -pix_fmt yuv420p -movflags +faststart "$output_path"
test -s "$output_path"
