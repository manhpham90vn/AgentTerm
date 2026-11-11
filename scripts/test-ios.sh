#!/usr/bin/env bash
# Runs the iPhone UI test in the iOS Simulator against two throwaway hosts.
#
#   ./scripts/test-ios.sh                   # asks which simulator
#   ./scripts/test-ios.sh "iPhone 17 Pro"   # a simulator by name, or by UDID
#   ./scripts/test-ios.sh --list            # show the simulators and stop
#   SHOTS=/some/folder ./scripts/test-ios.sh    # also save screenshots there
#   AGENTTY_LAUNCH="Start Claude Code" ./scripts/test-ios.sh
#
# The hosts use their own state folders and ports, so your real pairing,
# folders and sessions are not touched. The keychain of the simulator the test
# runs in is reset, so anything paired in that simulator has to pair again.
set -euo pipefail

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "test-ios.sh: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
source scripts/lib-simulator.sh
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then print_simulators; exit 0; fi
# The fallback is not the simulator run-ios.sh falls back to: this test
# resets the simulator's keychain, which unpairs the app you are trying out.
if [ -z "${1:-}" ] && [ -z "${SIMULATOR:-}" ] && [ -t 0 ] && [ -t 1 ]; then
    echo "This test resets the chosen simulator's keychain: an app paired there has to pair again."
fi
# Unlike the other scripts, never the booted simulator by default: that is
# most likely the one in use.
if [ -z "${1:-}" ] && [ -z "${SIMULATOR:-}" ] && ! { [ -t 0 ] && [ -t 1 ]; }; then
    choose_simulator "iPhone Air" "iPhone Air"
else
    choose_simulator "${1:-}" "iPhone Air"
fi
DEVICE="$SIM_UDID"
echo "Testing on $SIM_NAME ($SIM_UDID)."
PORT=7798
SECOND_PORT=7799
STATE="$(mktemp -d)"
SECOND_STATE="$(mktemp -d)"
LOG="$(mktemp)"

swift build --product agenttyd
AGENTTYD="$(swift build --show-bin-path)/agenttyd"
# Something for the first host to show: a project with uncommitted changes,
# a conversation an agent had in it, and folders to browse.
PROJECT="$STATE/project"
FAKE_HOME="$STATE/home"
mkdir -p "$PROJECT" "$FAKE_HOME/Projects/demo"
git -C "$PROJECT" init -q -b main
printf 'first line\n' > "$PROJECT/notes.txt"
git -C "$PROJECT" add . && git -C "$PROJECT" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m init
printf 'first line\nsecond line\n' > "$PROJECT/notes.txt"
HISTORY="$FAKE_HOME/.claude/projects/$(printf '%s' "$PROJECT" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$HISTORY"
printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"write tests for the parser"}}\n' "$PROJECT" > "$HISTORY/c-1.jsonl"
printf '["%s"]' "$PROJECT" > "$STATE/folders.json"

# Two hosts with their own state, standing in for two Macs.
AGENTTY_STATE_DIR="$STATE" "$AGENTTYD" --port "$PORT" --local-only --home "$FAKE_HOME" > "$STATE/daemon.log" 2>&1 &
DAEMON=$!
AGENTTY_STATE_DIR="$SECOND_STATE" "$AGENTTYD" --port "$SECOND_PORT" --local-only > "$SECOND_STATE/daemon.log" 2>&1 &
SECOND_DAEMON=$!
trap 'kill "$DAEMON" "$SECOND_DAEMON" 2>/dev/null || true; rm -rf "$STATE" "$SECOND_STATE"' EXIT
for _ in $(seq 1 50); do [ -s "$STATE/token" ] && [ -s "$SECOND_STATE/token" ] && break; sleep 0.1; done
[ -s "$STATE/token" ] && [ -s "$SECOND_STATE/token" ] || { echo "test-ios.sh: the hosts did not start" >&2; cat "$STATE/daemon.log" "$SECOND_STATE/daemon.log" >&2; exit 1; }

(cd iOS && xcodegen generate --quiet)
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl keychain "$DEVICE" reset

# TEST_RUNNER_ variables are handed to the test process without the prefix.
XCODEBUILD=(xcodebuild -project iOS/Agentty.xcodeproj -scheme Agentty
    -destination "platform=iOS Simulator,id=$DEVICE"
    -derivedDataPath .build/ios -skipPackagePluginValidation)

# Build first: a pairing link only lives five minutes, and a clean build can
# take longer than that.
if ! "${XCODEBUILD[@]}" build-for-testing > "$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" | cut -c1-300 >&2
    echo "test-ios.sh: build failed, full log in $LOG" >&2
    exit 1
fi

export TEST_RUNNER_AGENTTY_PAIR_URL="$(AGENTTY_STATE_DIR="$STATE" "$AGENTTYD" pairing-link --port "$PORT" --host 127.0.0.1 --name "First Mac")"
export TEST_RUNNER_AGENTTY_SECOND_PAIR_URL="$(AGENTTY_STATE_DIR="$SECOND_STATE" "$AGENTTYD" pairing-link --port "$SECOND_PORT" --host 127.0.0.1 --name "Second Mac")"
export TEST_RUNNER_AGENTTY_LAUNCH="${AGENTTY_LAUNCH:-Start Shell}"
export TEST_RUNNER_AGENTTY_TEST_PROJECT=1
if [ -n "${SHOTS:-}" ]; then mkdir -p "$SHOTS"; export TEST_RUNNER_AGENTTY_SHOT_DIR="$SHOTS"; fi

if "${XCODEBUILD[@]}" test-without-building > "$LOG" 2>&1; then
    grep -E "Test Case .* (passed|failed)|Executed [0-9]+ test" "$LOG" | tail -3
    echo "iOS UI test passed."
    rm -f "$LOG"
else
    grep -E "error:|Test Case .* failed|XCTAssert|BUILD FAILED|TEST FAILED" "$LOG" | cut -c1-300 >&2
    echo "test-ios.sh: failed, full log in $LOG" >&2
    exit 1
fi
