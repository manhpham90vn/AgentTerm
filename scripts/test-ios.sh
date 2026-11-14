#!/usr/bin/env bash
# Runs the iPhone UI test in the iOS Simulator against two throwaway hosts.
#
#   ./scripts/test-ios.sh                   # asks which simulator
#   ./scripts/test-ios.sh "iPhone 17 Pro"   # a simulator by name, or by UDID
#   ./scripts/test-ios.sh --list            # show the simulators and stop
#   SHOTS=/some/folder ./scripts/test-ios.sh    # also save screenshots there
#   AGENTTERM_LAUNCH="Start Claude Code" ./scripts/test-ios.sh
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

swift build --product agenttermd
AGENTTERMD="$(swift build --show-bin-path)/agenttermd"
# Something for the first host to show: a project with uncommitted changes,
# a conversation an agent had in it, and folders to browse.
PROJECT="$STATE/project"
FAKE_HOME="$STATE/home"
mkdir -p "$PROJECT" "$FAKE_HOME/Projects/demo"
git -C "$PROJECT" init -q -b main
# The test commits from the phone: an identity of its own, and no signing,
# whatever this machine is set up with.
git -C "$PROJECT" config user.name t
git -C "$PROJECT" config user.email t@example.com
git -C "$PROJECT" config commit.gpgsign false
printf 'first line\n' > "$PROJECT/notes.txt"
git -C "$PROJECT" add . && git -C "$PROJECT" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m init
# A remote the project follows, so the commit made from the phone can be pushed.
REMOTE="$STATE/remote.git"
git init -q --bare -b main "$REMOTE"
git -C "$PROJECT" remote add origin "$REMOTE"
git -C "$PROJECT" push -q -u origin main
# Hosts for the SSH menu. Nothing connects to them.
mkdir -p "$FAKE_HOME/.ssh"
printf 'Host build-server\n  HostName 127.0.0.1\nHost *.internal\n' > "$FAKE_HOME/.ssh/config"
# A change long and wide enough that its diff has to scroll both ways.
{
    printf 'first line\nsecond line\n'
    printf 'a wide line %s\n' "$(printf 'x%.0s' $(seq 1 300))"
    for i in $(seq 1 150); do printf 'line %s\n' "$i"; done
} > "$PROJECT/notes.txt"
HISTORY="$FAKE_HOME/.claude/projects/$(printf '%s' "$PROJECT" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$HISTORY"
printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"write tests for the parser"}}\n' "$PROJECT" > "$HISTORY/c-1.jsonl"
# A repository of its own inside the project, which the project's git does not see.
git init -q -b main "$PROJECT/web"
printf 'web\n' >> "$PROJECT/.git/info/exclude"
printf '["%s"]' "$PROJECT" > "$STATE/folders.json"

# A host that died on the first Mac before the one started here, with two
# sessions: the first host has to tell the phone (HOST-8). What a host
# leaves behind while it runs is a marker that names its process and its
# sessions; a process that is gone stands for the one that died.
sh -c 'exit 0' &
DEAD=$!
wait "$DEAD" || true
printf '{"pid":%s,"startedAt":%s,"sessions":[{"name":"build","cwd":"%s"},{"name":"tests","cwd":"%s"}]}' \
    "$DEAD" "$(date +%s)" "$PROJECT" "$PROJECT" > "$STATE/host-$PORT.json"

# Two hosts with their own state, standing in for two Macs.
HOME="$FAKE_HOME" ZDOTDIR="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" AGENTTERM_STATE_DIR="$STATE" "$AGENTTERMD" --port "$PORT" --local-only --home "$FAKE_HOME" > "$STATE/daemon.log" 2>&1 &
DAEMON=$!
# The second one says it is of an older release, to see the phone's warning.
AGENTTERM_STATE_DIR="$SECOND_STATE" "$AGENTTERMD" --port "$SECOND_PORT" --local-only --protocol-version 1 > "$SECOND_STATE/daemon.log" 2>&1 &
SECOND_DAEMON=$!
# SET-4: once the phone keeps the second Mac awake, that Mac goes out of
# reach, for the phone to show its settings as they were and not change them.
( while ! grep -q '"keepAwake":true' "$SECOND_STATE/settings.json" 2>/dev/null; do sleep 0.3; done; kill "$SECOND_DAEMON" ) &
GONE_WATCH=$!
trap 'kill "$DAEMON" "$SECOND_DAEMON" "$GONE_WATCH" 2>/dev/null || true; rm -rf "$STATE" "$SECOND_STATE"' EXIT
for _ in $(seq 1 50); do [ -s "$STATE/token" ] && [ -s "$SECOND_STATE/token" ] && break; sleep 0.1; done
[ -s "$STATE/token" ] && [ -s "$SECOND_STATE/token" ] || { echo "test-ios.sh: the hosts did not start" >&2; cat "$STATE/daemon.log" "$SECOND_STATE/daemon.log" >&2; exit 1; }

(cd iOS && xcodegen generate --quiet)
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl keychain "$DEVICE" reset

# TEST_RUNNER_ variables are handed to the test process without the prefix.
XCODEBUILD=(xcodebuild -project iOS/AgentTerm.xcodeproj -scheme AgentTerm
    -destination "platform=iOS Simulator,id=$DEVICE"
    -derivedDataPath .build/ios -skipPackagePluginValidation)

# Build first: a pairing link only lives five minutes, and a clean build can
# take longer than that.
if ! "${XCODEBUILD[@]}" build-for-testing > "$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" | cut -c1-300 >&2
    echo "test-ios.sh: build failed, full log in $LOG" >&2
    exit 1
fi

export TEST_RUNNER_AGENTTERM_PAIR_URL="$(AGENTTERM_STATE_DIR="$STATE" "$AGENTTERMD" pairing-link --port "$PORT" --host 127.0.0.1 --name "First Mac")"
export TEST_RUNNER_AGENTTERM_SECOND_PAIR_URL="$(AGENTTERM_STATE_DIR="$SECOND_STATE" "$AGENTTERMD" pairing-link --port "$SECOND_PORT" --host 127.0.0.1 --name "Second Mac")"
export TEST_RUNNER_AGENTTERM_LAUNCH="${AGENTTERM_LAUNCH:-Start Shell}"
export TEST_RUNNER_AGENTTERM_TEST_PROJECT=1
export TEST_RUNNER_AGENTTERM_EXPECT_HOST_DIED=1
if [ -n "${SHOTS:-}" ]; then mkdir -p "$SHOTS"; export TEST_RUNNER_AGENTTERM_SHOT_DIR="$SHOTS"; fi
# LANDSCAPE=only looks at the app with the phone on its side and nothing else.
if [ "${LANDSCAPE:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_LANDSCAPE=1; fi
# SCROLL=only measures how smoothly a long terminal scrolls, and nothing else.
if [ "${SCROLL:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_SCROLL=1; fi
# IDLE=only measures how long the steps around a session's menu wait for the
# app to be idle (#65), and nothing else. The figures are in the log.
if [ "${IDLE:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_IDLE=1; fi
# PAGES=only checks that a long session's earlier lines come a page at a time.
if [ "${PAGES:-}" = only ]; then export TEST_RUNNER_AGENTTERM_ONLY_HISTORY=1; fi
# TAKEOVER=1 has something play the Mac: once the phone has a session open,
# it is taken at a Mac's size, with output to scroll through. TAKEOVER=only
# checks nothing else.
if [ -n "${TAKEOVER:-}" ]; then
    export TEST_RUNNER_AGENTTERM_EXPECT_MAC_TAKEOVER=1
    [ "$TAKEOVER" = only ] && export TEST_RUNNER_AGENTTERM_ONLY_MAC_TAKEOVER=1
    AGENTTERM_STATE_DIR="$STATE" "$AGENTTERMD" take-control --port "$PORT" --after 8 --hold 60 --type 'seq 1 400' > "$STATE/takeover.log" 2>&1 &
    TAKEOVER_PID=$!
    trap 'kill "$DAEMON" "$SECOND_DAEMON" "$GONE_WATCH" "$TAKEOVER_PID" 2>/dev/null || true; rm -rf "$STATE" "$SECOND_STATE"' EXIT
fi

if "${XCODEBUILD[@]}" test-without-building > "$LOG" 2>&1; then
    # The test arranged the sessions; the host has to have kept that.
    if [ "${TAKEOVER:-}" = only ]; then echo "iOS UI test passed (Mac takeover only)."; rm -f "$LOG"; exit 0; fi
    if [ "${LANDSCAPE:-}" = only ]; then echo "iOS UI test passed (landscape only)."; rm -f "$LOG"; exit 0; fi
    if [ "${PAGES:-}" = only ]; then echo "iOS UI test passed (paged history only)."; rm -f "$LOG"; exit 0; fi
    if [ "${IDLE:-}" = only ]; then grep -E "MEASURE idle" "$LOG" | sed 's/^.*MEASURE //' | cut -c1-200; echo "iOS UI test passed (idle waits measured)."; rm -f "$LOG"; exit 0; fi
    if [ "${SCROLL:-}" = only ]; then grep -E "Measured \[|average:" "$LOG" | cut -c1-300; echo "iOS UI test passed (scrolling measured)."; rm -f "$LOG"; exit 0; fi
    grep -q '"Group 1 api"' "$STATE/tabs.json" || { echo "test-ios.sh: the host did not save the arrangement of the sessions" >&2; exit 1; }
    # The test committed and pushed from the phone; the remote has to have it.
    [ "$(git -C "$REMOTE" log -1 --format=%s main)" = "test: add a second line" ] || { echo "test-ios.sh: the push from the phone did not reach the remote" >&2; exit 1; }
    grep -E "Test Case .* (passed|failed)|Executed [0-9]+ test" "$LOG" | tail -3
    echo "iOS UI test passed."
    rm -f "$LOG"
else
    grep -E "error:|Test Case .* failed|XCTAssert|BUILD FAILED|TEST FAILED" "$LOG" | cut -c1-300 >&2
    echo "test-ios.sh: failed, full log in $LOG" >&2
    exit 1
fi
