#!/usr/bin/env bash
# Builds AgentTerm.app into dist/. The app is ad-hoc signed, which is enough to
# run it on the Mac that built it.
#
#   CONFIG=debug ./scripts/bundle-mac.sh    # default: release
#   VERSION=0.2.0 ./scripts/bundle-mac.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
CONFIG="${CONFIG:-release}"
APP="dist/AgentTerm.app"

swift build -c "$CONFIG" --product AgentTermMac
swift build -c "$CONFIG" --product agenttermd
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/AgentTermMac" "$APP/Contents/MacOS/AgentTerm"
cp "$BIN/agenttermd" "$APP/Contents/MacOS/agenttermd"

# Packages ship files of their own (the syntax highlighter's grammars and
# themes, for one) as resource bundles next to the binaries. Without them in
# the app, those packages only work on the machine that built it.
mkdir -p "$APP/Contents/Resources"
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# The icon is drawn by scripts/make-icons.swift and checked in.
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentTerm</string>
    <key>CFBundleDisplayName</key><string>AgentTerm</string>
    <key>CFBundleIdentifier</key><string>com.manhpham.agentterm</string>
    <key>CFBundleExecutable</key><string>AgentTerm</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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

codesign --force --sign - "$APP/Contents/MacOS/agenttermd"
codesign --force --sign - "$APP"
echo "Built $APP"
