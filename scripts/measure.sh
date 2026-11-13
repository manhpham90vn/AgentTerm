#!/usr/bin/env bash
# Takes the figures of docs/PERFORMANCE.md again (#21): heavy cases made in
# a folder of the test's own, each timed or weighed, on this Mac. Prints the
# figures; nothing fails on them. A release build is what users run:
#
#   ./scripts/measure.sh            # a debug build, as the tests run
#   CONFIGURATION=release ./scripts/measure.sh
#
# Nothing of the user's is touched: the host it starts has a state folder,
# a port and a home folder of its own.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-debug}"
AGENTTERM_MEASURE=1 swift test -c "$CONFIGURATION" --filter PerformanceMeasurements 2>&1 | grep -E "^MEASURE |error:|Executed [0-9]+ test" | sed 's/^MEASURE //'
