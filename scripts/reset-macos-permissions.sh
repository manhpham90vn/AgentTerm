#!/usr/bin/env bash
# Takes back every privacy permission macOS has given AgentTerm, so the
# prompts and Settings > Permissions can be tried from a clean start.
#
#   scripts/reset-macos-permissions.sh                 # the development build only
#   scripts/reset-macos-permissions.sh --released      # the released app too
#   scripts/reset-macos-permissions.sh --bundle-id ID  # only this one; repeatable
#
# The apps are quit first: macOS keeps a running app's grants until it is
# started again. Sessions keep running in the host. Nothing is deleted.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=com.manhpham.agentterm.dev
RELEASED=com.manhpham.agentterm
BUNDLE_IDS=("$DEV")
CHOSEN=()

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
    --released) BUNDLE_IDS=("$DEV" "$RELEASED") ;;
    --bundle-id)
        shift
        CHOSEN+=("${1:?--bundle-id needs a value}")
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "reset-macos-permissions.sh: unknown argument '$1'" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
done
[ ${#CHOSEN[@]} -eq 0 ] || BUNDLE_IDS=("${CHOSEN[@]}")

[ "$(uname)" = Darwin ] || { echo "reset-macos-permissions.sh: macOS only." >&2; exit 1; }

for bundle_id in "${BUNDLE_IDS[@]}"; do
    echo "==> quitting $bundle_id"
    osascript -e "quit app id \"$bundle_id\"" 2>/dev/null || true
done

for bundle_id in "${BUNDLE_IDS[@]}"; do
    echo "==> resetting privacy grants for $bundle_id"
    # What Settings > Permissions lists, by the names tccutil knows them.
    for service in Accessibility ScreenCapture AppleEvents SystemPolicyAllFiles Microphone Camera; do
        if tccutil reset "$service" "$bundle_id" >/dev/null 2>&1; then
            echo "    $service: cleared"
        else
            echo "    $service: nothing to clear"
        fi
    done
    # And the rest: folders, contacts, calendars, photos and so on.
    tccutil reset All "$bundle_id" >/dev/null 2>&1 || true
done

echo "Done. Open the app again and grant what it asks for."
