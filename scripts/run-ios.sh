#!/usr/bin/env bash
# Builds the iPhone app and runs it in the iOS Simulator.
#
#   ./scripts/run-ios.sh                    # asks which simulator
#   ./scripts/run-ios.sh "iPhone 17 Pro"    # a simulator by name, or by UDID
#   ./scripts/run-ios.sh --list             # show the simulators and stop
#   SIMULATOR="iPhone 17" ./scripts/run-ios.sh
#
# Without a name, and when not run from a terminal, it takes the booted
# simulator, or "iPhone 17".
#
# Needs xcodegen (brew install xcodegen). To run on a real iPhone, open
# iOS/AgentTerm.xcodeproj in Xcode and pick your team under Signing.
set -euo pipefail

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "run-ios.sh: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }

source scripts/lib-simulator.sh
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then print_simulators; exit 0; fi
choose_simulator "${1:-}" "iPhone 17"
DEVICE="$SIM_UDID"
echo "Using $SIM_NAME ($SIM_UDID)."

(cd iOS && xcodegen generate --quiet)
# Boot the simulator if needed, wait until it is usable, and show its window.
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || true

LOG="$(mktemp)"
if ! xcodebuild -project iOS/AgentTerm.xcodeproj -scheme AgentTerm \
    -destination "platform=iOS Simulator,id=$DEVICE" \
    -derivedDataPath .build/ios -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO build > "$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" | cut -c1-300 >&2
    echo "run-ios.sh: build failed, full log in $LOG" >&2
    exit 1
fi
rm -f "$LOG"

xcrun simctl install "$DEVICE" .build/ios/Build/Products/Debug-iphonesimulator/AgentTerm.app
xcrun simctl launch "$DEVICE" com.manhpham.agentterm >/dev/null
echo "AgentTerm is running on $SIM_NAME."
echo "The simulator has no camera. With AgentTerm open on this Mac, pair it with: ./scripts/pair-ios.sh \"$SIM_NAME\""
