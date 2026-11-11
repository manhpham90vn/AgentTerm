#!/usr/bin/env bash
# Pairs the Agentty app in the iOS Simulator with Agentty running on this Mac.
#
#   ./scripts/pair-ios.sh                   # the booted simulator
#   ./scripts/pair-ios.sh "iPhone 17 Pro"
#
# The simulator has no camera to scan the QR code with, so this asks the
# running host for a pairing link and opens it in the simulator. The
# simulator shares this Mac's network, so the link points at 127.0.0.1 and
# Tailscale is not involved. Agentty must be open on the Mac, and the app
# installed in the simulator (./scripts/run-ios.sh).
set -euo pipefail

cd "$(dirname "$0")/.."
DEVICE="${1:-booted}"
PORT="${AGENTTY_PORT:-7717}"

swift build --product agenttyd >/dev/null
LINK="$("$(swift build --show-bin-path)/agenttyd" pairing-link --port "$PORT" --host 127.0.0.1)"
xcrun simctl openurl "$DEVICE" "$LINK"
echo "Sent a pairing link to the simulator. If it asks \"Open in Agentty?\", choose Open."
echo "The link works once and for five minutes."
