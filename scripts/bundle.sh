#!/bin/bash
# Builds aerialite.app: a menu bar agent with no dock icon. The same binary still serves the CLI,
# so `aerialite prep` works from inside the bundle too.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_APP="${APP:-$ROOT/output/aerialite.app}"
TARGET_PARENT="$(dirname "$TARGET_APP")"
mkdir -p "$TARGET_PARENT"
STAGE_ROOT="$(mktemp -d "$TARGET_PARENT/.aerialite-bundle.XXXXXX")"
APP="$STAGE_ROOT/aerialite.app"
CONTENTS="$APP/Contents"
VERSION="1.0"
BUILD_VERSION="${BUILD_VERSION:-$(date -u +%Y%m%d%H%M%S)}"
SIGN_IDENTITY="${AERIALITE_SIGN_IDENTITY:--}"
cleanup() { rm -rf "$STAGE_ROOT"; }
trap cleanup EXIT

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
HOST_BUILD="$(sw_vers -buildVersion)"
XCODE_BUILD="$(xcodebuild -version | awk '/^Build version / { print $3; exit }')"
XCODE_NUMBER="$(xcodebuild -version | awk '/^Xcode / {
  split($2, parts, "."); printf "%d%d0", parts[1], parts[2]
}')"
case "$SDK_VERSION" in
  26.*) ;;
  *)
    echo "aerialite: the native wallpaper backend requires Xcode 26 or newer (found SDK $SDK_VERSION)" >&2
    exit 1
    ;;
esac

# CommandLineTools ships no dsymutil, and swift build treats that as fatal in release
swift build --package-path "$ROOT" -c release -Xswiftc -gnone

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 "${SWIFTPM_BUILD_DIR:-$ROOT/.build}/release/aerialite" "$CONTENTS/MacOS/aerialite"

# Native-only backend built against macOS's private WallpaperExtensionKit. That framework ships a
# link stub in the SDK but no .swiftmodule, so vendor/WallpaperExtensionKit.swiftinterface supplies
# the declarations and is compiled to a module here; see its header for how the ABI was recovered.
EXT="$CONTENTS/Extensions/AeriaLiteWallpaperExtension.appex"
EXT_CONTENTS="$EXT/Contents"
mkdir -p "$EXT_CONTENTS/MacOS"
MODULES="$STAGE_ROOT/modules"
mkdir -p "$MODULES"
xcrun swift-frontend -compile-module-from-interface \
  -target "$(uname -m)-apple-macos26.0" -sdk "$SDK" \
  -F "$SDK/System/Library/PrivateFrameworks" \
  -module-name WallpaperExtensionKit \
  -o "$MODULES/WallpaperExtensionKit.swiftmodule" \
  "$ROOT/vendor/WallpaperExtensionKit.swiftinterface"
xcrun swiftc -parse-as-library -O -gnone -swift-version 5 -application-extension \
  -target "$(uname -m)-apple-macos26.0" \
  -I "$MODULES" \
  -F "$SDK/System/Library/PrivateFrameworks" \
  "$ROOT/src/aerialite/NativeIPC.swift" \
  "$ROOT/src/wallpaper-extension/main.swift" \
  -framework AVFoundation -framework QuartzCore -framework WallpaperExtensionKit \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT_CONTENTS/MacOS/AeriaLiteWallpaperExtension"

work="$STAGE_ROOT/tools"
mkdir -p "$work"
xcrun swiftc -O -gnone -o "$work/make-icon" "$ROOT/scripts/make-icon.swift"
"$work/make-icon" "$work/icon.png" "$ROOT/scripts/astronaut.png"

set -- 16 16 32 32 128 128 256 256 512 512
mkdir -p "$work/AppIcon.iconset"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
            512:icon_512x512 1024:icon_512x512@2x; do
  sips -z "${spec%%:*}" "${spec%%:*}" "$work/icon.png" --out "$work/AppIcon.iconset/${spec##*:}.png" >/dev/null
done
iconutil -c icns "$work/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"
# the same silhouette drives the menu bar, loaded as a template so AppKit tints it
install -m 644 "$ROOT/scripts/astronaut.png" "$CONTENTS/Resources/MenuIcon.png"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>BuildMachineOSBuild</key><string>$HOST_BUILD</string>
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>DTPlatformBuild</key><string>$SDK_BUILD</string>
  <key>DTPlatformName</key><string>macosx</string>
  <key>DTPlatformVersion</key><string>$SDK_VERSION</string>
  <key>DTSDKBuild</key><string>$SDK_BUILD</string>
  <key>DTSDKName</key><string>macosx$SDK_VERSION</string>
  <key>DTXcode</key><string>$XCODE_NUMBER</string>
  <key>DTXcodeBuild</key><string>$XCODE_BUILD</string>
  <key>CFBundleName</key><string>AeriaLite</string>
  <key>CFBundleDisplayName</key><string>AeriaLite</string>
  <key>CFBundleIdentifier</key><string>com.jacksonadams.aerialite</string>
  <key>CFBundleExecutable</key><string>aerialite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$EXT_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>BuildMachineOSBuild</key><string>$HOST_BUILD</string>
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>DTPlatformBuild</key><string>$SDK_BUILD</string>
  <key>DTPlatformName</key><string>macosx</string>
  <key>DTPlatformVersion</key><string>$SDK_VERSION</string>
  <key>DTSDKBuild</key><string>$SDK_BUILD</string>
  <key>DTSDKName</key><string>macosx$SDK_VERSION</string>
  <key>DTXcode</key><string>$XCODE_NUMBER</string>
  <key>DTXcodeBuild</key><string>$XCODE_BUILD</string>
  <key>CFBundleName</key><string>AeriaLite Wallpaper</string>
  <key>CFBundleDisplayName</key><string>AeriaLite</string>
  <key>CFBundleIdentifier</key><string>com.jacksonadams.aerialite.wallpaper-extension</string>
  <key>CFBundleExecutable</key><string>AeriaLiteWallpaperExtension</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>EXAppExtensionAttributes</key>
  <dict>
    <key>EXExtensionPointIdentifier</key><string>com.apple.wallpaper</string>
  </dict>
</dict>
</plist>
PLIST

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then SIGN_ARGS+=(--options runtime); fi
if [ "${AERIALITE_CODESIGN_TIMESTAMP:-}" = "none" ]; then SIGN_ARGS+=(--timestamp=none); fi
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/scripts/wallpaper-extension.entitlements" "$EXT"
codesign "${SIGN_ARGS[@]}" "$APP"
plutil -lint "$CONTENTS/Info.plist" "$EXT_CONTENTS/Info.plist" >/dev/null
codesign --verify --deep --strict "$APP"
if ! xcrun vtool -show-build "$EXT_CONTENTS/MacOS/AeriaLiteWallpaperExtension" \
    | grep -Eq 'sdk +26\.'; then
  echo "aerialite: extension was not stamped with a supported macOS SDK" >&2
  exit 1
fi
# The host launches an .appex at NSExtensionMain, which performs the ExtensionKit check-in before
# handing control to the Swift @main type. Entering at the Swift entry point instead compiles,
# signs and registers exactly the same, then exits 0 the moment WallpaperAgent connects.
ENTRY_OFFSET="$(otool -l "$EXT_CONTENTS/MacOS/AeriaLiteWallpaperExtension" \
  | awk '/LC_MAIN/ { found = 1 } found && /entryoff/ { print $2; exit }')"
ENTRY_ADDRESS="$(printf '0x%016x' "$((0x100000000 + ENTRY_OFFSET))")"
if ! otool -Iv "$EXT_CONTENTS/MacOS/AeriaLiteWallpaperExtension" \
    | grep -q "^$ENTRY_ADDRESS .* _NSExtensionMain$"; then
  echo "aerialite: extension does not start at NSExtensionMain" >&2
  exit 1
fi

# A failed build never disturbs the last complete artifact. Only after compilation, plist checks,
# and deep signature verification succeed do we replace it with the single new bundle.
rm -rf "$TARGET_APP"
mv "$APP" "$TARGET_APP"
echo "$TARGET_APP"
