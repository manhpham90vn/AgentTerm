#!/usr/bin/env bash
# Takes the pictures of both apps again: the three of the Mac app in
# docs/screenshots (the README and the product page show them) and the six
# of the iPhone app in fastlane/screenshots/en-US (the App Store and the
# product page).
#
#   ./scripts/screenshots.sh                  # both, the iPhone's on the simulator "iPhone Air"
#   ./scripts/screenshots.sh "iPhone Air"     # a simulator by name, or by UDID
#   ONLY=mac ./scripts/screenshots.sh         # only the Mac's
#   ONLY=ios ./scripts/screenshots.sh         # only the iPhone's
#   KEEP=/some/folder ./scripts/screenshots.sh  # put them there instead, to look at first
#
# What they show is made up here and the same every time: a small project
# with changes, a second folder, and stand-in agents (scripts/demo-agent.py)
# that draw an agent's screen and report usage without any account. Nothing
# of the installed apps is touched: the app is built into a folder of its
# own, and the host, its port, its state, the home folder and the app's
# preferences are this script's. The Mac app is driven through accessibility,
# so the terminal this runs in has to be allowed under System Settings >
# Privacy & Security > Accessibility. The keychain of the simulator is reset,
# so anything paired in that simulator has to pair again.
#
# The App Store wants the iPhone's pictures at 1260 x 2736, which is the
# iPhone Air: another simulator gives pictures the store does not take.
set -euo pipefail

cd "$(dirname "$0")/.."
ONLY="${ONLY:-both}"
PORT=7790
# Not in the temporary folder: its path has a symbolic link in it, and a
# file is shown by its place in the project, which it is not found to be in
# when the two are named differently.
ROOT="$PWD/.build/screenshots"
rm -rf "$ROOT"
STATE="$ROOT/state"
FAKE_HOME="$ROOT/home"
AGENTS="$ROOT/agents"
PROJECT="$ROOT/my-app"
WEBSITE="$ROOT/website"
SHOTS="$ROOT/shots"
LOG="$(mktemp)"
# The app's preferences are kept under its identifier, so it gets one of
# its own: with the development app's it would read and write that app's.
IDENTIFIER=com.manhpham.agentterm.screenshots
defaults delete "$IDENTIFIER" >/dev/null 2>&1 || true
mkdir -p "$STATE" "$FAKE_HOME" "$AGENTS" "$PROJECT/src" "$PROJECT/docs" "$WEBSITE" "$SHOTS/mac" "$SHOTS/ios"

if [ "$ONLY" != mac ]; then
    command -v xcodegen >/dev/null || { echo "screenshots.sh: xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
    source scripts/lib-simulator.sh
    choose_simulator "${1:-iPhone Air}" "iPhone Air"
    DEVICE="$SIM_UDID"
    echo "The iPhone's pictures are taken on $SIM_NAME ($SIM_UDID)."
fi

# The demo project: one change staged, one file changed, one new.
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.name demo
git -C "$PROJECT" config user.email demo@example.com
git -C "$PROJECT" config commit.gpgsign false
cat > "$PROJECT/src/Parser.swift" <<'SWIFT'
import Foundation

struct Parser {
    func parse(_ text: String) -> [String] {
        text.split(separator: ",").map(String.init)
    }
}
SWIFT
printf '# my-app\n\nA small demo project.\n\n## Usage\n\nRun `swift run`.\n' > "$PROJECT/README.md"
printf '# Notes\n\nWhat the parser does not do yet.\n' > "$PROJECT/docs/notes.md"
git -C "$PROJECT" add . && git -C "$PROJECT" commit -q -m init
cat > "$PROJECT/src/Parser.swift" <<'SWIFT'
import Foundation

struct Parser {
    /// Splits a line on commas, trimming the spaces around each field.
    func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
SWIFT
git -C "$PROJECT" add src/Parser.swift
cat > "$PROJECT/src/ParserTests.swift" <<'SWIFT'
import XCTest

final class ParserTests: XCTestCase {
    func testFieldsAreTrimmed() {
        XCTAssertEqual(Parser().parse("a, b ,c"), ["a", "b", "c"])
    }
}
SWIFT
cat >> "$PROJECT/README.md" <<'MARKDOWN'

## How it works

```mermaid
flowchart LR
    A[Input line] --> B(Parser)
    B --> C[Fields]
    C --> D{Empty?}
    D -- no --> E[Trim spaces]
    D -- yes --> F[Drop]
```

| File | What |
|---|---|
| `src/Parser.swift` | splits a line into fields |
| `src/ParserTests.swift` | its tests |
MARKDOWN
git -C "$WEBSITE" init -q -b main
printf '["%s","%s"]' "$PROJECT" "$WEBSITE" > "$STATE/folders.json"
for agent in claude codex agy copilot; do cp scripts/demo-agent.py "$AGENTS/$agent"; chmod +x "$AGENTS/$agent"; done

# The app as it is released, but for its name: built into a folder of its
# own, since dist may hold a copy that is running.
IDENTIFIER="$IDENTIFIER" OUT="$ROOT/app" CONFIG=debug CHANNEL=dev ./scripts/bundle-mac.sh > "$LOG" 2>&1 || { tail -20 "$LOG" >&2; echo "screenshots.sh: the app did not build" >&2; exit 1; }
APP="$ROOT/app/AgentTerm Dev.app/Contents/MacOS"
swift build --build-tests > "$LOG" 2>&1 || { grep -E "error:" "$LOG" | cut -c1-300 >&2; echo "screenshots.sh: the tests did not build" >&2; exit 1; }

AGENTTERM_STATE_DIR="$STATE" "$APP/agenttermd" --port "$PORT" --local-only --no-account-usage --home "$FAKE_HOME" --agents "$AGENTS" > "$STATE/daemon.log" 2>&1 &
DAEMON=$!
MAC=""
cleanup() {
    [ -n "$MAC" ] && kill "$MAC" 2>/dev/null || true
    kill "$DAEMON" 2>/dev/null || true
    defaults delete "$IDENTIFIER" >/dev/null 2>&1 || true
    [ -n "${DEVICE:-}" ] && xcrun simctl status_bar "$DEVICE" clear 2>/dev/null || true
    rm -rf "$ROOT"
}
trap cleanup EXIT
for _ in $(seq 1 50); do [ -s "$STATE/token" ] && break; sleep 0.1; done
[ -s "$STATE/token" ] || { echo "screenshots.sh: the host did not start" >&2; cat "$STATE/daemon.log" >&2; exit 1; }
sleep 0.5

export AGENTTERM_SHOTS_PORT="$PORT" AGENTTERM_SHOTS_TOKEN="$STATE/token" AGENTTERM_SHOTS_OUT="$SHOTS/mac"
export AGENTTERM_SHOTS_PROJECT="$PROJECT" AGENTTERM_SHOTS_WEBSITE="$WEBSITE" AGENTTERM_SHOTS_HOME="$FAKE_HOME"

part() {
    local name="$1"
    shift
    if "$@" > "$LOG" 2>&1; then
        echo "  done: $name"
    else
        grep -E "error:|Test Case .* failed|XCTAssert|TEST FAILED" "$LOG" | cut -c1-900 >&2
        echo "screenshots.sh: failed in: $name. Full log in $LOG" >&2
        exit 1
    fi
}

if [ "$ONLY" != ios ]; then
    AGENTTERM_STATE_DIR="$STATE" AGENTTERM_PORT="$PORT" CFFIXED_USER_HOME="$FAKE_HOME" "$APP/AgentTerm" > "$STATE/mac.log" 2>&1 &
    MAC=$!
    AGENTTERM_SHOTS_PID="$MAC" part "the Mac app's pictures" swift test --skip-build --filter "AgentTermMacUITests.ScreenshotTests/testPart1"
    kill "$MAC" 2>/dev/null || true
    MAC=""
    sleep 1
else
    # The session the Mac's part would have left.
    export AGENTTERM_SHOTS_FIRST=1
fi

if [ "$ONLY" != mac ]; then
    part "the sessions for the iPhone" swift test --skip-build --filter "AgentTermMacUITests.ScreenshotTests/testPart2"
    (cd iOS && xcodegen generate --quiet)
    xcrun simctl bootstatus "$DEVICE" -b >/dev/null
    xcrun simctl keychain "$DEVICE" reset
    XCODEBUILD=(xcodebuild -project iOS/AgentTerm.xcodeproj -scheme AgentTerm
        -destination "platform=iOS Simulator,id=$DEVICE"
        -derivedDataPath .build/ios -skipPackagePluginValidation)
    part "building the iPhone app" "${XCODEBUILD[@]}" build-for-testing
    # The status bar the App Store's pictures have.
    xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
    export TEST_RUNNER_AGENTTERM_PAIR_URL="$(AGENTTERM_STATE_DIR="$STATE" "$APP/agenttermd" pairing-link --port "$PORT" --host 127.0.0.1 --name "MacBook Pro")"
    export TEST_RUNNER_AGENTTERM_SCREENSHOTS=1 TEST_RUNNER_AGENTTERM_SHOT_DIR="$SHOTS/ios"
    part "the iPhone app's pictures" "${XCODEBUILD[@]}" test-without-building -only-testing:AgentTermUITests/ScreenshotTests
fi

MAC_OUT="${KEEP:+$KEEP/mac}"
IOS_OUT="${KEEP:+$KEEP/ios}"
MAC_OUT="${MAC_OUT:-docs/screenshots}"
IOS_OUT="${IOS_OUT:-fastlane/screenshots/en-US}"
mkdir -p "$MAC_OUT" "$IOS_OUT"
[ "$ONLY" = ios ] || cp "$SHOTS/mac/"*.png "$MAC_OUT/"
[ "$ONLY" = mac ] || cp "$SHOTS/ios/"*.png "$IOS_OUT/"
echo "The pictures are in ${KEEP:-docs/screenshots and fastlane/screenshots/en-US}. Look at them before they are committed."
rm -f "$LOG"
