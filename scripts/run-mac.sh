#!/usr/bin/env bash
# Builds Agentty and opens it on this Mac.
#
#   ./scripts/run-mac.sh                  # debug build, restart the host daemon
#   ./scripts/run-mac.sh --release        # optimized build
#   ./scripts/run-mac.sh --keep-sessions  # leave the running daemon and its sessions alone
#
# The host daemon outlives the app on purpose, so by default this script stops
# it to make sure the freshly built one is used. That ends running sessions.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG=debug
KEEP_SESSIONS=0
for argument in "$@"; do
    case "$argument" in
        --release) CONFIG=release ;;
        --keep-sessions) KEEP_SESSIONS=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "run-mac.sh: unknown option $argument" >&2; exit 2 ;;
    esac
done

CONFIG="$CONFIG" ./scripts/bundle-mac.sh

# Quit a running copy so the new build is the one that opens.
pkill -x Agentty 2>/dev/null || true
if [ "$KEEP_SESSIONS" -eq 0 ]; then
    pkill -x agenttyd 2>/dev/null || true
fi
sleep 0.5

open dist/Agentty.app
echo "Agentty is running. Daemon log: ~/Library/Application Support/Agentty/agenttyd.log"
