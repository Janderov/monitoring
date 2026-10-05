#!/usr/bin/env bash
# Builds Monitor.app (menu bar app) from this Swift package. Run on a Mac:
#   app/scripts/build-app.sh [version]
# The result is app/dist/Monitor.app, signed ad hoc (no Apple Developer account).
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:-0.0.0-dev}"
case "$version" in [0-9]*) ;; v[0-9]*) version="${version#v}" ;; *) version="0.0.0-$version" ;; esac

swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Monitor"

app=dist/Monitor.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Monitor"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.janderov.monitor</string>
  <key>CFBundleName</key><string>Monitor</string>
  <key>CFBundleDisplayName</key><string>Мониторинг</string>
  <key>CFBundleExecutable</key><string>Monitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$app"
codesign --verify "$app"
echo "built $app ($version)"
