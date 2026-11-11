#!/usr/bin/env bash
# Builds the iPhone app and runs it in the iOS Simulator.
#
#   ./scripts/run-ios.sh                    # the booted simulator, or "iPhone 17"
#   ./scripts/run-ios.sh "iPhone 17 Pro"    # a simulator by name
#
# Needs xcodegen (brew install xcodegen). To run on a real iPhone, open
# iOS/Agentty.xcodeproj in Xcode and pick your team under Signing.
set -euo pipefail

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "run-ios.sh: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
    DEVICE="$(xcrun simctl list devices booted | sed -n 's/^ *\(iPhone[^(]*\) (.*/\1/p' | head -1 | sed 's/ *$//')"
    DEVICE="${DEVICE:-iPhone 17}"
fi

(cd iOS && xcodegen generate --quiet)
# Boot the simulator if needed, wait until it is usable, and show its window.
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || true

LOG="$(mktemp)"
if ! xcodebuild -project iOS/Agentty.xcodeproj -scheme Agentty \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath .build/ios -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO build > "$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" | cut -c1-300 >&2
    echo "run-ios.sh: build failed, full log in $LOG" >&2
    exit 1
fi
rm -f "$LOG"

xcrun simctl install "$DEVICE" .build/ios/Build/Products/Debug-iphonesimulator/Agentty.app
xcrun simctl launch "$DEVICE" click.manhdev.agentty.ios >/dev/null
echo "Agentty is running on $DEVICE."
echo "The simulator has no camera. Pair it with: xcrun simctl openurl \"$DEVICE\" '<pairing link>'"
