#!/bin/bash
# Shortens every wallpaper to a LENGTH-second loop by stream copy, so nothing is re-encoded
# and no quality is lost. A wallpaper is glanced at, not watched, and the full clips run three
# to five minutes each.
#
#   trim.sh [LENGTH]                 middle LENGTH seconds of every clip
#   FROM_START="Seals Hawaii" trim.sh   those clips take their opening instead
#
# Cuts land on the nearest preceding keyframe, which the 2-second keyframe interval bounds.
set -uo pipefail

DEST="${DEST:-$HOME/Library/Wallpapers}"
LENGTH="${1:-60}"
FROM_START="${FROM_START:-}"
kept=0; skipped=0; failed=0

for f in "$DEST"/*.mp4; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .mp4)"
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null)
  [ -z "$dur" ] && { echo "  unreadable: $name"; failed=$((failed + 1)); continue; }

  if awk -v d="$dur" -v l="$LENGTH" 'BEGIN{exit !(d <= l + 1)}'; then
    printf "  %-46s %6.0fs already short\n" "$name" "$dur"; skipped=$((skipped + 1)); continue
  fi

  start=0
  for pat in $FROM_START; do case "$name" in *"$pat"*) start=-1;; esac; done
  [ "$start" = "-1" ] && start=0 || start=$(awk -v d="$dur" -v l="$LENGTH" 'BEGIN{printf "%.3f", (d-l)/2}')

  # scratch name keeps the .mp4 extension, or ffmpeg cannot infer a muxer and every cut fails
  tmp="${f%.mp4}.trim.mp4"
  # -ss ahead of -i seeks by keyframe; reset+make_zero rebase the segment onto a zero start
  if err=$(ffmpeg -y -hide_banner -loglevel error -ss "$start" -i "$f" -t "$LENGTH" \
             -c copy -avoid_negative_ts make_zero -reset_timestamps 1 "$tmp" 2>&1) \
     && [ -s "$tmp" ] \
     && new=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp" 2>/dev/null) \
     && [ -n "$new" ]; then
    mv -f "$tmp" "$f"
    printf "  %-46s %6.0fs -> %.0fs  from %.0fs\n" "$name" "$dur" "$new" "$start"
    kept=$((kept + 1))
  else
    rm -f "$tmp"; echo "  FAILED: $name: ${err:-probe returned no duration}"; failed=$((failed + 1))
  fi
done

echo "trimmed $kept, left $skipped alone, failed $failed"
du -sh "$DEST"
