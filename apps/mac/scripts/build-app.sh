#!/bin/zsh
# Builds a runnable Prism.app from the Swift package.
#
#   scripts/build-app.sh            # release build, "Prism Dev.app" with bundle ID dev.prism.native-dev
#   CONFIG=debug scripts/build-app.sh   # debug, host architecture only
#   ARCHS=arm64 scripts/build-app.sh    # release for one architecture (faster)
#
# The development bundle ID keeps its data, permissions and hotkey separate from the installed Prism.
# Release packaging with the persistent signing identity is a separate step; never overwrite
# /Applications/Prism.app with this ad-hoc signed build.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${CONFIG:-release}
BUNDLE_ID=${BUNDLE_ID:-dev.prism.native-dev}
APP_NAME=${APP_NAME:-Prism Dev}
# Release bundles keep the Tauri executable name, so the Tauri updater's restart finds the new binary.
EXECUTABLE=${EXECUTABLE:-Prism}
VERSION=${VERSION:-0.2.0}
SCRATCH=${SCRATCH:-.build}
OUTPUT=${OUTPUT:-$SCRATCH/app}

# Release builds are universal like the Tauri app; debug builds only target this Mac.
if [[ "$CONFIG" == release ]]; then ARCHS=${ARCHS:-arm64 x86_64}; else ARCHS=${ARCHS:-}; fi
ARCH_FLAGS=()
for arch in ${=ARCHS}; do ARCH_FLAGS+=(--arch "$arch"); done

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --scratch-path "$SCRATCH" --product Prism
BIN_DIR=$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --scratch-path "$SCRATCH" --show-bin-path)

APP="$OUTPUT/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Prism" "$APP/Contents/MacOS/$EXECUTABLE"
# Release builds drop local symbols, which are more than half of the binary.
[[ "$CONFIG" == release ]] && strip -x "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Prism.icns "$APP/Contents/Resources/Prism.icns"
# Empty main-bundle localizations tell macOS which languages the app supports; strings live in module bundles.
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/ko.lproj"
cp Resources/ko.lproj/InfoPlist.strings "$APP/Contents/Resources/ko.lproj/"
for bundle in "$BIN_DIR"/Prism_*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>Prism</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>Prism uses the microphone for dictation.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Prism captures a screen region you select to ask AI about it.</string>
  <key>NSAppleEventsUsageDescription</key><string>Prism uses automation to run system commands and scripts you choose.</string>
</dict>
</plist>
PLIST

# Development builds are ad-hoc signed; scripts/package-native-release.mjs re-signs release bundles.
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "$APP"
