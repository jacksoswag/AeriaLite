#!/bin/bash
# Installs aerialite.app into ~/Applications, puts the same binary on PATH for `aerialite prep`,
# and registers a login agent so the wallpaper is up before you are.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS="${APPS:-$HOME/Applications}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aerialite"
LABEL="com.jacksonadams.aerialite"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$APPS/aerialite.app"

if [ "${AERIALITE_USE_EXISTING_BUNDLE:-0}" = "1" ]; then
  [ -d "$ROOT/output/aerialite.app" ] || {
    echo "aerialite: the prebuilt output/aerialite.app is missing" >&2
    exit 1
  }
  codesign --verify --deep --strict "$ROOT/output/aerialite.app"
else
  APP="$ROOT/output/aerialite.app" "$ROOT/scripts/bundle.sh" > /dev/null
fi
EXTENSION="$ROOT/output/aerialite.app/Contents/Extensions/AeriaLiteWallpaperExtension.appex"
app_team="$(codesign -dv --verbose=4 "$ROOT/output/aerialite.app" 2>&1 \
  | sed -n 's/^TeamIdentifier=//p' | head -1)"
extension_team="$(codesign -dv --verbose=4 "$EXTENSION" 2>&1 \
  | sed -n 's/^TeamIdentifier=//p' | head -1)"
if [ -z "$app_team" ] || [ "$app_team" = "not set" ] || [ "$app_team" != "$extension_team" ]; then
  echo "aerialite: native wallpaper installation requires the app and extension to use the same Apple-issued team identity" >&2
  echo "a free Xcode Personal Team can provide the required Apple Development identity" >&2
  echo "set AERIALITE_SIGN_IDENTITY to that Apple Development identity" >&2
  exit 1
fi
mkdir -p "$APPS" "$BIN_DIR" "$CONF_DIR"

# Stage the complete signed bundle on the destination volume before disturbing the running copy.
# A rename then makes the actual replacement atomic.
STAGE_DIR="$(mktemp -d "$APPS/.aerialite-install.XXXXXX")"
# Keep temporary payload names free of the .app suffix. PluginKit watches ~/Applications and
# would otherwise register the staging path before the atomic rename, leaving a stale record.
STAGED_APP="$STAGE_DIR/payload"
# The rollback copy is kept outside ~/Applications entirely. Every change under a directory pkd
# watches costs another re-registration, and re-registration removes the extension instance
# WallpaperAgent is presenting, so all churn there has to finish before activation rather than
# after it.
KEEP_DIR="$HOME/Library/Caches/AeriaLite/rollback.$$"
PREVIOUS_APP="$KEEP_DIR/aerialite.app"
ROLLBACK=0
cleanup() {
  status=$?
  set +e
  if [ "$ROLLBACK" = 1 ]; then
    /usr/bin/pluginkit -r "$APP/Contents/Extensions/AeriaLiteWallpaperExtension.appex" >/dev/null 2>&1
    rm -rf "$APP"
    if [ -e "$PREVIOUS_APP" ]; then mv "$PREVIOUS_APP" "$APP"; fi
    echo "aerialite: installation rolled back; the previous app was restored but left stopped" >&2
  fi
  rm -rf "$STAGE_DIR" "$KEEP_DIR"
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$KEEP_DIR"
cp -R "$ROOT/output/aerialite.app" "$STAGED_APP"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -f "aerialite.app/Contents/MacOS/aerialite" 2>/dev/null || true
# Let the old agent finish its termination handler before bootstrapping; a job still tearing down
# answers EIO.
for _ in $(seq 20); do
  launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
if [ -e "$APP" ]; then mv "$APP" "$PREVIOUS_APP"; fi
mv "$STAGED_APP" "$APP"
ROLLBACK=1
# Nothing else may touch $APPS until activation has settled.
rm -rf "$STAGE_DIR"

# Registration and selection are mandatory. If Apple's native extension cannot be activated,
# installation stops here; there is deliberately no desktop-window fallback.
"$APP/Contents/MacOS/aerialite" activate-native
ROLLBACK=0
rm -rf "$KEEP_DIR"
ln -sf "$APP/Contents/MacOS/aerialite" "$BIN_DIR/aerialite"

# Deliberately not launched from here. macOS 26 files a menu bar item under the app that is
# responsible for the process that created it, and that grouping is persistent and per-bundle-id.
# An installer run from a terminal or an agent therefore welds the menu bar item to *that* tool's
# entry in group.com.apple.controlcenter's trackedApplications, and if the tool is not allowed to
# add menu bar items the icon is blocked forever after, on every later launch, no matter who starts
# it. ControlCenter reports this only as "Moving host to blocked list" at debug level. Launching
# from Finder, Spotlight or the login item keeps the item under AeriaLite's own entry.
rm -f "$PLIST"
count=$(find "/Users/Shared/AeriaLite/Wallpapers" -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ')
echo "$APP installed, $count wallpapers, log at $CONF_DIR/aerialite.log"
echo "open AeriaLite from Finder or Spotlight to start it; it registers itself as a login item"
[ "$count" = "0" ] && echo "nothing to play yet: scripts/fetch-aerials.sh, or aerialite prep <file>"
exit 0
