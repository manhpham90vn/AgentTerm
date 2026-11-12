#!/usr/bin/env bash
# Builds the Mac app into dist/. The app is ad-hoc signed, which is enough to
# run it on the Mac that built it.
#
#   CONFIG=debug ./scripts/bundle-mac.sh    # default: release
#   VERSION=0.2.0 ./scripts/bundle-mac.sh
#   CHANNEL=release ./scripts/bundle-mac.sh # default: dev
#
# CHANNEL decides which app this is. "dev", the default, builds
# "AgentTerm Dev.app" (com.manhpham.agentterm.dev): it has its own data
# folder, port and pairing links, so it runs next to an installed AgentTerm
# without touching its sessions or paired devices. "release" builds
# AgentTerm.app itself, which is what the release lanes do.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
CONFIG="${CONFIG:-release}"
CHANNEL="${CHANNEL:-dev}"
case "$CHANNEL" in
    release) NAME="AgentTerm"; BUNDLE_ID="com.manhpham.agentterm" ;;
    dev) NAME="AgentTerm Dev"; BUNDLE_ID="com.manhpham.agentterm.dev" ;;
    *) echo "bundle-mac.sh: CHANNEL must be dev or release" >&2; exit 2 ;;
esac
APP="dist/$NAME.app"

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
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>AgentTerm</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- macOS holds a terminal responsible for what runs inside it. Without
         these, a program in a session that wants one of these things is
         refused without the user ever being asked. -->
    <key>NSAppleEventsUsageDescription</key><string>A program running in ${NAME} wants to control another app.</string>
    <key>NSCameraUsageDescription</key><string>A program running in ${NAME} wants to use the camera.</string>
    <key>NSMicrophoneUsageDescription</key><string>A program running in ${NAME} wants to use the microphone.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>A program running in ${NAME} wants to use speech recognition.</string>
    <key>NSLocalNetworkUsageDescription</key><string>${NAME} lets your iPhone reach its sessions, and programs running in it may use the local network.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>A program running in ${NAME} wants to use Bluetooth.</string>
    <key>NSCalendarsUsageDescription</key><string>A program running in ${NAME} wants to access your calendars.</string>
    <key>NSContactsUsageDescription</key><string>A program running in ${NAME} wants to access your contacts.</string>
    <key>NSRemindersUsageDescription</key><string>A program running in ${NAME} wants to access your reminders.</string>
    <key>NSPhotoLibraryUsageDescription</key><string>A program running in ${NAME} wants to access your photos.</string>
    <key>NSLocationUsageDescription</key><string>A program running in ${NAME} wants to use your location.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>A program running in ${NAME} wants to use your location.</string>
    <key>NSDesktopFolderUsageDescription</key><string>A program running in ${NAME} wants to access files in your Desktop folder.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>A program running in ${NAME} wants to access files in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>A program running in ${NAME} wants to access files in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>A program running in ${NAME} wants to access files on a removable volume.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>A program running in ${NAME} wants to access files on a network volume.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>A program running in ${NAME} wants to access your calendars.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>A program running in ${NAME} wants to access your reminders.</string>
    <key>NSPhotoLibraryAddUsageDescription</key><string>A program running in ${NAME} wants to add to your photos.</string>
    <key>NSAppleMusicUsageDescription</key><string>A program running in ${NAME} wants to access your media library.</string>
    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key><string>A program running in ${NAME} wants to use your location.</string>
    <key>NSFileProviderDomainUsageDescription</key><string>A program running in ${NAME} wants to access files kept by a cloud storage app.</string>
    <key>NSAudioCaptureUsageDescription</key><string>A program running in ${NAME} wants to record this Mac's audio.</string>
    <key>NSInputMonitoringUsageDescription</key><string>A program running in ${NAME} wants to watch the keyboard.</string>
    <key>NSSystemAdministrationUsageDescription</key><string>A program running in ${NAME} wants to administer this Mac.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - --entitlements assets/AgentTerm.entitlements "$APP/Contents/MacOS/agenttermd"
codesign --force --sign - --entitlements assets/AgentTerm.entitlements "$APP"
echo "Built $APP"
