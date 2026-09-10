#!/bin/bash
# --smk  encodes a generated clip and checks the output profile
# --perf drives the installed native backend and samples the menu app and extension
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${SWIFTPM_BUILD_DIR:-$ROOT/.build}/release/aerialite"
WORK="$ROOT/output/misc/test"
REPORTS="$ROOT/tests/reports"
MEDIA_HELPER="$WORK/media-helper"
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
  xcrun swiftc -parse-as-library -O -gnone \
    "$ROOT/tests/media-helper.swift" -framework AVFoundation -framework CoreVideo \
    -o "$MEDIA_HELPER"
  "$MEDIA_HELPER" make "$WORK/source.mov"
}

probe() { "$MEDIA_HELPER" probe "$2" | awk -F= -v key="$1" '$1 == key { print $2 }'; }
agent() { launchctl print "gui/$UID/com.apple.wallpaper.agent" >/dev/null 2>&1 && echo up || echo gone; }

smoke() {
  local out="$WORK/source.aerialite.mp4"
  echo "== smoke =="
  # -o is mandatory: prep defaults into Wallpapers/, which the suite must never touch
  "$BIN" prep "$WORK/source.mov" -o "$out" --size 320x180 --keep 0.5 --bitrate 1000000 > "$WORK/prep.log" || {
    echo "  FAIL  prep exited nonzero"; FAILED=$((FAILED + 1)); return; }
  check "format"     "$(probe format "$out")"  "hvc1"
  check "width"      "$(probe width "$out")"   "320"
  check "height"     "$(probe height "$out")"  "180"
  check "fps"        "$(probe fps "$out")"     "30"
  check "frames"     "$(probe frames "$out")"  "60"
  # native wallpaper playback instantiates no audio path, so an audio track would be dead weight
  check "streams"    "$(probe streams "$out")" "1"
}

# footprint is the only honest memory number here, but it blocks indefinitely on some hosts rather
# than failing, which hangs the whole suite at the last line it prints. Bound it and say so.
footprint_of() {
  local out
  out="$(
    /usr/bin/footprint -p "$1" 2>/dev/null &
    local reader=$!
    ( sleep 10; kill -9 "$reader" 2>/dev/null ) 2>/dev/null &
    local guard=$!
    wait "$reader" 2>/dev/null
    kill "$guard" 2>/dev/null
  )"
  out="$(printf '%s' "$out" | grep phys_footprint: | tr -s ' ')"
  if [ -n "$out" ]; then printf '%s' "$out"; else printf 'unavailable, footprint did not answer'; fi
}

perf() {
  local aerialite="/Users/Shared/AeriaLite"
  local app="${AERIALITE_APP:-$HOME/Applications/aerialite.app}"
  local app_bin="$app/Contents/MacOS/aerialite"
  local extension="$app/Contents/Extensions/AeriaLiteWallpaperExtension.appex"
  local extension_bin="$extension/Contents/MacOS/AeriaLiteWallpaperExtension"
  local owns_app=0

  echo "== perf =="
  # play takes the installed config and library, with nothing to override either, so the run
  # records the settings its numbers were taken under. The extension must already be installed
  # and selected; the app intentionally has no alternate renderer.
  echo "  live config, $(find "$aerialite/Wallpapers" -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ') clips in the library:"
  sed 's/^/  /' "$aerialite/config.json" 2>/dev/null || echo "  absent, so defaults"
  if [ ! -x "$app_bin" ]; then
    echo "  FAIL  installed app is missing: $app_bin"
    FAILED=$((FAILED + 1))
    return
  fi
  codesign --verify --deep --strict "$app" 2>/dev/null
  check "bundle signature" "$?" "0"
  check "extension sdk" "$(xcrun vtool -show-build "$extension_bin" 2>/dev/null \
    | awk '$1 == "sdk" { print $2; exit }')" "26.5"
  local provider_count
  provider_count="$(plutil -convert xml1 -o - \
    "$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist" 2>/dev/null \
    | grep -c 'com.jacksonadams.aerialite.wallpaper-extension' | tr -d ' ')"
  if [ "${provider_count:-0}" -gt 0 ]; then
    echo "  pass  provider selected in $provider_count wallpaper slots"
  else
    echo "  FAIL  provider is not selected in the wallpaper store"
    FAILED=$((FAILED + 1))
  fi

  local pid
  pid="$(pgrep -f "$app_bin" | head -1)"
  if [ -z "$pid" ]; then
    "$app_bin" play > "$WORK/play.log" 2>&1 &
    pid=$!
    owns_app=1
  fi
  sleep 5
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "  FAIL  menu app died: $(cat "$WORK/play.log")"
    FAILED=$((FAILED + 1))
    return
  fi

  local extension_pid
  extension_pid="$(pgrep -x AeriaLiteWallpaperExtension | head -1)"
  if [ -z "$extension_pid" ]; then
    echo "  FAIL  native extension is not active; install and select AeriaLite first"
    FAILED=$((FAILED + 1))
    if [ "$owns_app" = 1 ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    return
  fi

  # WallpaperAgent owns native placement, Spaces, Mission Control, and menu-bar tinting.
  check "apple agent while playing" "$(agent)" "up"

  echo "  process                         rss_kb %cpu"
  for _ in 1 2 3 4 5 6; do
    ps -o comm=,rss=,pcpu= -p "$pid","$extension_pid"
    if ! kill -0 "$extension_pid" 2>/dev/null; then
      echo "  FAIL  native extension exited during sampling"
      FAILED=$((FAILED + 1))
      break
    fi
    sleep 2
  done
  echo "  menu footprint: $(footprint_of "$pid")"
  echo "  extension footprint: $(footprint_of "$extension_pid")"
  if [ "$owns_app" = 1 ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  sleep 1
  check "apple agent after quit" "$(agent)" "up"
}

case "${1:-}" in
  --smk) mode=smk ;;
  --perf) mode=perf ;;
  *) echo "usage: run-tests.sh --smk | --perf"; exit 2 ;;
esac
setup "$1" || exit $?
REPORT="$REPORTS/${DATE}_${mode}.md"
exec > >(tee "$REPORT") 2>&1
echo "# aerialite $1 $DATE"
echo
echo '```'
if [ "$mode" = "smk" ]; then smoke; else perf; fi
echo '```'
echo
echo "failures: $FAILED"

exit $((FAILED > 0))
