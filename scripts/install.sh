#!/bin/bash
# Installs kino.app into ~/Applications, puts the same binary on PATH for `kino prep`,
# and registers a login agent so the wallpaper is up before you are.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS="${APPS:-$HOME/Applications}"
BIN_DIR="${BIN_DIR:-$HOME/Utils/local/bin}"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/kino"
LABEL="com.jacksonadams.kino"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$APPS/kino.app"

APP="$ROOT/output/kino.app" "$ROOT/scripts/bundle.sh" > /dev/null
mkdir -p "$APPS" "$BIN_DIR" "$CONF_DIR"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -f "kino.app/Contents/MacOS/kino" 2>/dev/null || true
# quitting restores Apple's wallpaper agent before the process goes, and bootstrapping against a
# job still tearing down answers EIO
for _ in $(seq 20); do launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
rm -rf "$APP"
cp -R "$ROOT/output/kino.app" "$APP"
ln -sf "$APP/Contents/MacOS/kino" "$BIN_DIR/kino"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/kino</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$CONF_DIR/kino.log</string>
  <key>StandardErrorPath</key><string>$CONF_DIR/kino.log</string>
</dict>
</plist>
PLIST_EOF

launchctl bootstrap "gui/$UID" "$PLIST"
count=$(find "$HOME/Library/Application Support/Kino/Wallpapers" -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ')
echo "$APP installed and running, $count wallpapers, log at $CONF_DIR/kino.log"
[ "$count" = "0" ] && echo "nothing to play yet: scripts/fetch-aerials.sh, or kino prep <file>"
exit 0
