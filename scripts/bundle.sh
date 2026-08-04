#!/bin/bash
# Builds kino.app: a menu bar agent with no dock icon. The same binary still serves the CLI,
# so `kino prep` works from inside the bundle too.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP:-$ROOT/output/kino.app}"
CONTENTS="$APP/Contents"
VERSION="1.0"

# CommandLineTools ships no dsymutil, and swift build treats that as fatal in release
swift build --package-path "$ROOT" -c release -Xswiftc -gnone

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 "$ROOT/.build/release/kino" "$CONTENTS/MacOS/kino"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
swiftc -O -gnone -o "$work/make-icon" "$ROOT/scripts/make-icon.swift"
"$work/make-icon" "$work/icon.png"

set -- 16 16 32 32 128 128 256 256 512 512
mkdir -p "$work/AppIcon.iconset"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
            512:icon_512x512 1024:icon_512x512@2x; do
  sips -z "${spec%%:*}" "${spec%%:*}" "$work/icon.png" --out "$work/AppIcon.iconset/${spec##*:}.png" >/dev/null
done
iconutil -c icns "$work/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kino</string>
  <key>CFBundleDisplayName</key><string>Kino</string>
  <key>CFBundleIdentifier</key><string>com.jacksonadams.kino</string>
  <key>CFBundleExecutable</key><string>kino</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing failed, app still runs"
echo "$APP"
