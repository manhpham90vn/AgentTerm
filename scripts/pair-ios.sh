#!/usr/bin/env bash
# Pairs the AgentTerm app in the iOS Simulator with AgentTerm running on this Mac.
#
#   ./scripts/pair-ios.sh                   # asks which simulator
#   ./scripts/pair-ios.sh "iPhone 17 Pro"   # a simulator by name, or by UDID
#   ./scripts/pair-ios.sh --list            # show the simulators and stop
#
# The simulator has no camera to scan the QR code with, so this asks the
# running host for a pairing link and opens it in the simulator. The
# simulator shares this Mac's network, so the link points at 127.0.0.1 and
# Tailscale is not involved. AgentTerm must be open on the Mac, and the app
# installed in the simulator (./scripts/run-ios.sh).
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib-simulator.sh
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then print_simulators; exit 0; fi
choose_simulator "${1:-}" "iPhone 17"
DEVICE="$SIM_UDID"
PORT="${AGENTTERM_PORT:-7717}"

swift build --product agenttermd >/dev/null
LINK="$("$(swift build --show-bin-path)/agenttermd" pairing-link --port "$PORT" --host 127.0.0.1)"
xcrun simctl openurl "$DEVICE" "$LINK"
echo "Sent a pairing link to $SIM_NAME. If it asks \"Open in AgentTerm?\", choose Open."
echo "The link works once and for five minutes."
