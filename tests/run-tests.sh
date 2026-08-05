#!/bin/bash
# --smk  encodes a generated clip and checks the output profile
# --perf plays the installed library and samples the renderer's cost
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${SWIFTPM_BUILD_DIR:-$ROOT/.build}/release/aerialite"
WORK="$ROOT/output/misc/test"
REPORTS="$ROOT/tests/reports"
DATE="$(date +%Y-%m-%d)"
FAILED=0

check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  pass  $1 = $2"
  else echo "  FAIL  $1 = $2, wanted $3"; FAILED=$((FAILED + 1)); fi
}

setup() {
  [ -x "$BIN" ] || { echo "build first: swift build -c release -Xswiftc -gnone"; exit 2; }
  mkdir -p "$WORK" "$REPORTS"
  [ "${1:-}" = "--smk" ] || return 0        # only smoke encodes, and only it needs the master
  command -v ffmpeg >/dev/null || { echo "ffmpeg required for the fixture"; exit 2; }
  [ -f "$WORK/source.mov" ] || ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=3840x2160:rate=60:duration=8" \
    -c:v hevc_videotoolbox -b:v 40M -tag:v hvc1 "$WORK/source.mov"
}

probe() { ffprobe -v error -select_streams v:0 -show_entries "$1" -of default=nk=1:nw=1 "$2"; }
agent() { launchctl print "gui/$UID/com.apple.wallpaper.agent" >/dev/null 2>&1 && echo up || echo gone; }

smoke() {
  local out="$WORK/source.aerialite.mp4"
  echo "== smoke =="
  # -o is mandatory: prep defaults into persistent/, which the suite must never touch
  "$BIN" prep "$WORK/source.mov" -o "$out" --size 1280x720 --keep 0.5 --bitrate 3000000 > "$WORK/prep.log" || {
    echo "  FAIL  prep exited nonzero"; FAILED=$((FAILED + 1)); return; }
  check "codec"      "$(probe stream=codec_name "$out")"       "hevc"
  check "tag"        "$(probe stream=codec_tag_string "$out")" "hvc1"
  check "width"      "$(probe stream=width "$out")"            "1280"
  check "height"     "$(probe stream=height "$out")"           "720"
  check "fps"        "$(probe stream=r_frame_rate "$out")"     "30/1"
  check "frames"     "$(probe stream=nb_frames "$out")"        "240"
  # the renderer instantiates no audio path, so an audio track would be dead weight
  check "streams"    "$(ffprobe -v error -show_entries format=nb_streams -of default=nk=1:nw=1 "$out")" "1"
}

perf() {
  local aerialite="$HOME/Library/Application Support/AeriaLite"

  echo "== perf =="
  # play takes the installed config and library, with nothing to override either, so the run
  # records the settings its numbers were taken under
  echo "  live config, $(find "$aerialite/Wallpapers" -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ') clips in the library:"
  sed 's/^/  /' "$aerialite/config.json" 2>/dev/null || echo "  absent, so defaults"
  "$BIN" play > "$WORK/play.log" 2>&1 &
  local pid=$!
  sleep 5
  if ! kill -0 $pid 2>/dev/null; then echo "  FAIL  renderer died: $(cat "$WORK/play.log")"; FAILED=$((FAILED + 1)); return; fi

  check "apple agent while playing" "$(agent)" "gone"

  local state; state="$(grep -c playing "$WORK/play.log")"
  if [ "$state" -eq 0 ]; then
    echo "  SKIP  gated (fullscreen space or a stuck full-display overlay), cost numbers meaningless"
  fi
  echo "  rss_kb %cpu"
  for _ in 1 2 3 4 5 6; do ps -o rss=,pcpu= -p $pid; sleep 2; done
  echo "  footprint: $(/usr/bin/footprint -p $pid 2>/dev/null | grep phys_footprint: | tr -s ' ')"
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  sleep 1
  check "apple agent after quit" "$(agent)" "up"
}

setup "${1:-}"
REPORT="$REPORTS/${DATE}_$( [ "${1:-}" = "--perf" ] && echo perf || echo smk ).md"
{
  echo "# aerialite ${1:-} $DATE"
  echo
  echo '```'
  case "${1:-}" in
    --smk)  smoke ;;
    --perf) perf ;;
    *) echo "usage: run-tests.sh --smk | --perf"; exit 2 ;;
  esac
  echo '```'
  echo
  echo "failures: $FAILED"
} 2>&1 | tee "$REPORT"

exit $((FAILED > 0))
