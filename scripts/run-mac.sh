#!/usr/bin/env bash
# Builds the development app, "AgentTerm Dev", and opens it on this Mac. It
# has its own data folder and port, so an installed AgentTerm and its
# sessions are left alone.
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

CONFIG="$CONFIG" CHANNEL=dev ./scripts/bundle-mac.sh

# Quit a running copy so the new build is the one that opens. Only the
# development app and its own daemon: the installed app is not ours to stop.
pkill -f "AgentTerm Dev.app/Contents/MacOS/AgentTerm" 2>/dev/null || true
if [ "$KEEP_SESSIONS" -eq 0 ]; then
    pkill -f "AgentTerm Dev.app/Contents/MacOS/agenttermd" 2>/dev/null || true
fi
sleep 0.5

open "dist/AgentTerm Dev.app"
echo "AgentTerm Dev is running. Daemon log: ~/Library/Application Support/AgentTerm Dev/agenttermd.log"
