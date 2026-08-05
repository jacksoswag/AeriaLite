#!/bin/bash
# Installs aerialite.app into ~/Applications, puts the same binary on PATH for `aerialite prep`,
# and registers a login agent so the wallpaper is up before you are.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS="${APPS:-$HOME/Applications}"
BIN_DIR="${BIN_DIR:-$HOME/Utils/local/bin}"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aerialite"
LABEL="com.jacksonadams.aerialite"
OLD="com.jacksonadams.kino"          # the install this project shipped under before the rename
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$APPS/aerialite.app"

APP="$ROOT/output/aerialite.app" "$ROOT/scripts/bundle.sh" > /dev/null
mkdir -p "$APPS" "$BIN_DIR" "$CONF_DIR"

for label in "$OLD" "$LABEL"; do launchctl bootout "gui/$UID/$label" 2>/dev/null || true; done
pkill -f "kino.app/Contents/MacOS/kino" 2>/dev/null || true
pkill -f "aerialite.app/Contents/MacOS/aerialite" 2>/dev/null || true
# quitting restores Apple's wallpaper agent before the process goes, and bootstrapping against a
# job still tearing down answers EIO. Both labels, since the old agent restoring the wallpaper
# after the new one culled it leaves macOS drawing a second picture underneath.
for _ in $(seq 20); do
  launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || launchctl print "gui/$UID/$OLD" >/dev/null 2>&1 || break
  sleep 0.5
done
rm -rf "$APP" "$APPS/kino.app" "$HOME/Library/LaunchAgents/$OLD.plist" "$BIN_DIR/kino"
cp -R "$ROOT/output/aerialite.app" "$APP"
ln -sf "$APP/Contents/MacOS/aerialite" "$BIN_DIR/aerialite"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/aerialite</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$CONF_DIR/aerialite.log</string>
  <key>StandardErrorPath</key><string>$CONF_DIR/aerialite.log</string>
</dict>
</plist>
PLIST_EOF

launchctl bootstrap "gui/$UID" "$PLIST"
count=$(find "$HOME/Library/Application Support/AeriaLite/Wallpapers" -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ')
echo "$APP installed and running, $count wallpapers, log at $CONF_DIR/aerialite.log"
[ "$count" = "0" ] && echo "nothing to play yet: scripts/fetch-aerials.sh, or aerialite prep <file>"
exit 0
