#!/usr/bin/env bash
# Runs the iPhone UI test in the iOS Simulator against a throwaway host.
#
#   ./scripts/test-ios.sh                   # "iPhone 17"
#   ./scripts/test-ios.sh "iPhone 17 Pro"
#   SHOTS=/some/folder ./scripts/test-ios.sh    # also save screenshots there
#   AGENTTY_LAUNCH="Start Claude Code" ./scripts/test-ios.sh
#
# The host uses its own state folder and port, so your real pairing, folders
# and sessions are not touched. The simulator's keychain is reset.
set -euo pipefail

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "test-ios.sh: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
DEVICE="${1:-iPhone 17}"
PORT=7798
STATE="$(mktemp -d)"
LOG="$(mktemp)"

swift build --product agenttyd
AGENTTY_STATE_DIR="$STATE" "$(swift build --show-bin-path)/agenttyd" --port "$PORT" --local-only > "$STATE/daemon.log" 2>&1 &
DAEMON=$!
trap 'kill "$DAEMON" 2>/dev/null || true; rm -rf "$STATE"' EXIT
for _ in $(seq 1 50); do [ -s "$STATE/token" ] && break; sleep 0.1; done
[ -s "$STATE/token" ] || { echo "test-ios.sh: the host did not start" >&2; cat "$STATE/daemon.log" >&2; exit 1; }

(cd iOS && xcodegen generate --quiet)
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl keychain "$DEVICE" reset

# TEST_RUNNER_ variables are handed to the test process without the prefix.
# A pairing link works once and for five minutes, which covers the build below.
export TEST_RUNNER_AGENTTY_PAIR_URL="$(AGENTTY_STATE_DIR="$STATE" "$(swift build --show-bin-path)/agenttyd" pairing-link --port "$PORT" --host 127.0.0.1)"
export TEST_RUNNER_AGENTTY_LAUNCH="${AGENTTY_LAUNCH:-Start Shell}"
if [ -n "${SHOTS:-}" ]; then mkdir -p "$SHOTS"; export TEST_RUNNER_AGENTTY_SHOT_DIR="$SHOTS"; fi

if xcodebuild -project iOS/Agentty.xcodeproj -scheme Agentty \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath .build/ios -skipPackagePluginValidation test > "$LOG" 2>&1; then
    grep -E "Test Case .* (passed|failed)|Executed [0-9]+ test" "$LOG" | tail -3
    echo "iOS UI test passed."
    rm -f "$LOG"
else
    grep -E "error:|Test Case .* failed|XCTAssert|BUILD FAILED|TEST FAILED" "$LOG" | cut -c1-300 >&2
    echo "test-ios.sh: failed, full log in $LOG" >&2
    exit 1
fi
