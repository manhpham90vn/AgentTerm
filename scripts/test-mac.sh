#!/usr/bin/env bash
# Runs the Mac app's UI tests: the app is started against a host of its own,
# with stand-in agents, and driven through accessibility.
#
#   ./scripts/test-mac.sh                # all of them
#   ./scripts/test-mac.sh GitTests       # one class, or any name `swift test --filter` takes
#   SHOTS=/some/folder ./scripts/test-mac.sh   # a picture of the window for each test that fails
#   SHOTS=/some/folder ALL_SHOTS=1 ./scripts/test-mac.sh   # one for each test, at its end
#
# The terminal this runs in has to be allowed under System Settings >
# Privacy & Security > Accessibility. No pointer is moved and no key is sent:
# the tests press and read the app's own elements, as VoiceOver does.
# Nothing of the installed app is touched: the host, its port, its state,
# the home folder and the app's preferences are all the tests' own.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --build-tests
export AGENTTERM_MAC_UI=1
if [ -n "${SHOTS:-}" ]; then mkdir -p "$SHOTS"; export AGENTTERM_SHOT_DIR="$SHOTS"; fi
if [ -n "${ALL_SHOTS:-}" ]; then export AGENTTERM_SHOT_ALWAYS=1; fi
# MEASURE=1 runs the measurements of the app's main thread (#21), which the
# tests otherwise skip, and prints their figures: nothing fails on a figure.
if [ -n "${MEASURE:-}" ]; then export AGENTTERM_MEASURE_UI=1; fi
FILTER="AgentTermMacUITests"
if [ -n "${1:-}" ]; then FILTER="AgentTermMacUITests\..*$1"; fi
# The half of the test with the iPhone app is run by test-both.sh.
LOG="$(mktemp)"
if swift test --skip-build --filter "$FILTER" --skip "CrossTests" > "$LOG" 2>&1; then
    grep -E "^MEASURE " "$LOG" | sed 's/^MEASURE //' || true
    grep -E "Test Case .* (passed|skipped)|Executed [1-9][0-9]* test" "$LOG" | sed 's/^Test Case .-\[AgentTermMacUITests\.//; s/\]. / /' | uniq
    echo "Mac UI tests passed."
    rm -f "$LOG"
else
    grep -E "error:|Test Case .* failed" "$LOG" | cut -c1-600 >&2
    echo "test-mac.sh: failed, full log in $LOG" >&2
    exit 1
fi
