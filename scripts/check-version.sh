#!/usr/bin/env bash
# Checks that a version being released is the one in the VERSION file.
#
#   scripts/check-version.sh v0.2.1          # a tag
#   scripts/check-version.sh 0.2.1-beta.1    # a version given by hand
#   scripts/check-version.sh                 # $GITHUB_REF, when that is a tag
#
# A suffix after a dash (-beta.1) is a pre-release of that version and is
# allowed. Anything that is not a version or a tag passes: there is nothing
# to check on an ordinary push.
set -euo pipefail
cd "$(dirname "$0")/.."

REF=${1:-${GITHUB_REF:-}}
VERSION=$(tr -d ' \t\r\n' <VERSION)

case "$REF" in
refs/tags/v*) GIVEN=${REF#refs/tags/v} ;;
v[0-9]*) GIVEN=${REF#v} ;;
[0-9]*) GIVEN=$REF ;;
*)
    echo "not a version (${REF:-none}) - VERSION is $VERSION, nothing to check"
    exit 0
    ;;
esac

if [ "${GIVEN%%-*}" != "$VERSION" ]; then
    echo "::error::$GIVEN is not a release of VERSION ($VERSION) - run 'make bump V=${GIVEN%%-*}' and commit, or release $VERSION"
    exit 1
fi

echo "$GIVEN matches VERSION $VERSION"
