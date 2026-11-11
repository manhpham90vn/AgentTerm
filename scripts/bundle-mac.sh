#!/usr/bin/env bash
# Builds a release Agentty.app into dist/. The app is ad-hoc signed, which is
# enough to run it on the Mac that built it.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="dist/Agentty.app"

swift build -c release --product AgenttyMac
swift build -c release --product agenttyd
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/AgenttyMac" "$APP/Contents/MacOS/Agentty"
cp "$BIN/agenttyd" "$APP/Contents/MacOS/agenttyd"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Agentty</string>
    <key>CFBundleDisplayName</key><string>Agentty</string>
    <key>CFBundleIdentifier</key><string>click.manhdev.agentty</string>
    <key>CFBundleExecutable</key><string>Agentty</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/agenttyd"
codesign --force --sign - "$APP"
echo "Built $APP"
