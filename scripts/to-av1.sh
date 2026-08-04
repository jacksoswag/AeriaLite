#!/bin/bash
# Re-encodes the wallpapers from HEVC to AV1, which the M3 decodes in hardware and which
# carries the same picture in roughly half the bits. Resolution and timing are untouched;
# this is a codec change only.
#
#   to-av1.sh [CRF]     default 45, lower is bigger and better
#
# VideoToolbox cannot encode AV1 on this hardware, so this goes through libsvtav1 in software.
# That is one lossy generation on top of the HEVC files: acceptable at their 5 to 8 Mbps, but
# encoding from the original masters would be marginally cleaner.
set -uo pipefail

DEST="${DEST:-$HOME/Library/Wallpapers}"
CRF="${1:-45}"
PRESET="${PRESET:-6}"
command -v ffmpeg >/dev/null || { echo "ffmpeg required"; exit 2; }
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libsvtav1 || { echo "this ffmpeg has no libsvtav1"; exit 2; }

before=$(du -sk "$DEST" | cut -f1)
done_count=0; failed=0

for f in "$DEST"/*.mp4; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .mp4)"
  [ "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$f")" = "av1" ] && {
    printf "  %-46s already av1\n" "$name"; continue; }

  tmp="${f%.mp4}.av1.mp4"
  old=$(stat -f%z "$f")
  if err=$(ffmpeg -y -hide_banner -loglevel error -i "$f" \
             -c:v libsvtav1 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p10le \
             -an -movflags +faststart "$tmp" 2>&1) \
     && [ -s "$tmp" ] \
     && [ "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$tmp")" = "av1" ]; then
    new=$(stat -f%z "$tmp")
    mv -f "$tmp" "$f"
    printf "  %-46s %6.0f -> %5.0f MB  (%.0f%%)\n" "$name" \
      "$(echo "$old/1e6"|bc -l)" "$(echo "$new/1e6"|bc -l)" "$(echo "100*$new/$old"|bc -l)"
    done_count=$((done_count + 1))
  else
    rm -f "$tmp"; echo "  FAILED: $name: ${err:-not av1 on probe}"; failed=$((failed + 1))
  fi
done

after=$(du -sk "$DEST" | cut -f1)
printf "converted %d, failed %d, %.0f MB -> %.0f MB\n" "$done_count" "$failed" \
  "$(echo "$before/1024"|bc -l)" "$(echo "$after/1024"|bc -l)"
