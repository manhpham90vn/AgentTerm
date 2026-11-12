#!/usr/bin/env bash
# Builds and opens the Mac app (AgentTerm Dev), builds and opens the iPhone
# app in a simulator, and pairs the two: run-mac.sh, run-ios.sh and
# pair-ios.sh in one go.
#
#   ./scripts/run-all.sh                       # asks which simulator, once
#   ./scripts/run-all.sh "iPhone 18 Pro Max"   # a simulator by name, or by UDID
#   ./scripts/run-all.sh --keep-sessions "iPhone 17"   # leave the running host and its sessions alone
#
# Like run-mac.sh it restarts the development host, which ends the sessions
# it holds, unless --keep-sessions is given.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib-simulator.sh

MAC_OPTIONS=()
WANTED=""
for argument in "$@"; do
    case "$argument" in
        --keep-sessions|--release) MAC_OPTIONS+=("$argument") ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "run-all.sh: unknown option $argument" >&2; exit 2 ;;
        *) WANTED="$argument" ;;
    esac
done

# Chosen once, here, so the two iPhone steps use the same simulator and
# neither asks again.
choose_simulator "$WANTED" "iPhone 17"

./scripts/run-mac.sh ${MAC_OPTIONS[@]+"${MAC_OPTIONS[@]}"}
./scripts/run-ios.sh "$SIM_UDID"

# The Mac app starts its host when it opens. Pairing asks that host, so
# wait until it answers rather than fail on a host that is a moment away.
for attempt in $(seq 1 20); do
    if ./scripts/pair-ios.sh "$SIM_UDID" 2>/dev/null; then exit 0; fi
    sleep 1
done
echo "run-all.sh: the host did not answer. Is AgentTerm Dev open? Then run: ./scripts/pair-ios.sh \"$SIM_NAME\"" >&2
exit 1
