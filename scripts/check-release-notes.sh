#!/usr/bin/env bash
# Checks that the version being released has its notes written, and prints
# the file's path. The notes are packaging/release-notes/v<version>.md, one
# file for a version and its pre-releases; the GitHub release shows them and
# TestFlight gets them as "What to Test".
#
#   scripts/check-release-notes.sh            # the version in VERSION
#   scripts/check-release-notes.sh 0.2.1-beta.1
set -euo pipefail
cd "$(dirname "$0")/.."

GIVEN=${1:-$(tr -d ' \t\r\n' <VERSION)}
GIVEN=${GIVEN#refs/tags/}
GIVEN=${GIVEN#v}
NOTES=packaging/release-notes/v${GIVEN%%-*}.md

if [ ! -s "$NOTES" ]; then
    echo "::error::$NOTES is missing or empty - write what changed in ${GIVEN%%-*} there and commit it" >&2
    exit 1
fi

echo "$NOTES"
