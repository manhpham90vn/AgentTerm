#!/usr/bin/env bash
# Checks that the version being released has its notes written, and prints
# the file's path. A pre-release may have notes of its own,
# packaging/release-notes/v0.3.0-beta.4.md; otherwise the version's are
# used, v0.3.0.md. The GitHub release and Discord show them. TestFlight's
# "What to Test" is a file next to it ending in .testflight.md, when there
# is one, and these notes when there is not.
#
#   scripts/check-release-notes.sh            # the version in VERSION
#   scripts/check-release-notes.sh 0.2.1-beta.1
set -euo pipefail
cd "$(dirname "$0")/.."

GIVEN=${1:-$(tr -d ' \t\r\n' <VERSION)}
GIVEN=${GIVEN#refs/tags/}
GIVEN=${GIVEN#v}
NOTES=packaging/release-notes/v$GIVEN.md
[ -s "$NOTES" ] || NOTES=packaging/release-notes/v${GIVEN%%-*}.md

if [ ! -s "$NOTES" ]; then
    echo "::error::$NOTES is missing or empty - write what changed in ${GIVEN%%-*} there and commit it" >&2
    exit 1
fi

echo "$NOTES"
