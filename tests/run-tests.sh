#!/bin/bash
# --smk  encodes a generated clip and checks the output profile
# --perf plays it and samples the renderer's cost
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/kino"
WORK="$ROOT/output/misc/test"
REPORTS="$ROOT/tests/reports"
DATE="$(date +%Y-%m-%d)"
FAILED=0

check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  pass  $1 = $2"
  else echo "  FAIL  $1 = $2, wanted $3"; FAILED=$((FAILED + 1)); fi
}

setup() {
  command -v ffmpeg >/dev/null || { echo "ffmpeg required for the fixture"; exit 2; }
  [ -x "$BIN" ] || { echo "build first: swift build -c release -Xswiftc -gnone"; exit 2; }
  mkdir -p "$WORK" "$REPORTS"
  [ -f "$WORK/source.mov" ] || ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=3840x2160:rate=60:duration=8" \
    -c:v hevc_videotoolbox -b:v 40M -tag:v hvc1 "$WORK/source.mov"
}

probe() { ffprobe -v error -select_streams v:0 -show_entries "$1" -of default=nk=1:nw=1 "$2"; }

smoke() {
  local out="$WORK/source.kino.mp4"
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
  # its own file at native size, or it silently inherits whatever smoke downscaled to
  local out="$WORK/native.kino.mp4"
  [ -f "$out" ] || "$BIN" prep "$WORK/source.mov" -o "$out"
  mkdir -p "$WORK/cfg/kino"
  printf "{ \"downloads\": { \"framesKept\": 1 } }\n" > "$WORK/cfg/kino/config.json"

  echo "== perf =="
  XDG_CONFIG_HOME="$WORK/cfg" "$BIN" play > "$WORK/play.log" 2>&1 &
  local pid=$!
  sleep 5
  if ! kill -0 $pid 2>/dev/null; then echo "  FAIL  renderer died: $(cat "$WORK/play.log")"; FAILED=$((FAILED + 1)); return; fi

  local state; state="$(grep -c playing "$WORK/play.log")"
  if [ "$state" -eq 0 ]; then
    echo "  SKIP  gated (fullscreen space or a stuck full-display overlay), cost numbers meaningless"
  fi
  echo "  rss_kb %cpu"
  for _ in 1 2 3 4 5 6; do ps -o rss=,pcpu= -p $pid; sleep 2; done
  echo "  footprint: $(/usr/bin/footprint -p $pid 2>/dev/null | grep phys_footprint: | tr -s ' ')"
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
}

setup
REPORT="$REPORTS/${DATE}_$( [ "${1:-}" = "--perf" ] && echo perf || echo smk ).md"
{
  echo "# drift ${1:-} $DATE"
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
