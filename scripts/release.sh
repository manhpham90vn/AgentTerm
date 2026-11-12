#!/usr/bin/env bash
# Runs a fastlane lane with the secrets it needs, read from the private
# dotfiles repo. No secret is printed, and none is kept in this repository.
#
#   scripts/release.sh ios build         build the iPhone app signed for the App Store
#   scripts/release.sh ios beta          ... and upload it to TestFlight
#   scripts/release.sh mac sign          build AgentTerm.app, sign with Developer ID, make a .dmg
#   scripts/release.sh mac release       ... and notarize it
#   scripts/release.sh --check           show which secrets were found, run nothing
#
# Anything after the lane goes to fastlane, e.g. `ios build create:true`
# to let match make the provisioning profile the first time.
#
#   DOTFILES   the dotfiles repo (default: ../dotfiles next to this repo)
#   VERSION    version to build (default: the one in the VERSION file)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DOTFILES=${DOTFILES:-$ROOT/../dotfiles}
PROJECT_ENV=$DOTFILES/projects/agentterm/release.env

fail() { echo "release.sh: $*" >&2; exit 1; }

# KEY=VALUE lines into the environment, without letting the shell expand
# the values: they may hold $, quotes or spaces.
load_env() {
    [ -f "$1" ] || fail "$1 not found"
    local key value
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in ''|'#'*) continue ;; esac
        export "$key=$value"
    done < "$1"
}

load_env "$PROJECT_ENV"
[ -n "${APPLE_ACCOUNT:-}" ] || fail "APPLE_ACCOUNT is not set in $PROJECT_ENV"
APPLE_DIR=$DOTFILES/accounts/apple/$APPLE_ACCOUNT
load_env "$APPLE_DIR/apple.env"

key_file=$(ls "$APPLE_DIR"/AuthKey_*.p8 2>/dev/null | head -1 || true)
[ -n "$key_file" ] || fail "no AuthKey_*.p8 in $APPLE_DIR"
export ASC_KEY_PATH=$key_file
# The key id is in the file's name when apple.env does not give it.
: "${ASC_KEY_ID:=$(basename "$key_file" .p8 | sed 's/^AuthKey_//')}"
export ASC_KEY_ID
export DEVELOPER_ID_P12=$APPLE_DIR/certs/developer_id_application.p12

if [ "${1:-}" = "--check" ]; then
    # Names only: whether each is there, never what it is.
    for name in APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID MATCH_GIT_URL MATCH_PASSWORD; do
        if [ -n "${!name:-}" ]; then echo "$name: set"; else echo "$name: MISSING"; fi
    done
    [ -s "$ASC_KEY_PATH" ] && echo "App Store Connect key file: found" || echo "App Store Connect key file: MISSING"
    [ -s "$DEVELOPER_ID_P12" ] && echo "Developer ID certificate: found" || echo "Developer ID certificate: MISSING"
    command -v fastlane >/dev/null && echo "fastlane: $(fastlane --version 2>/dev/null | tail -1)" || echo "fastlane: MISSING (brew install fastlane)"
    command -v xcodegen >/dev/null && echo "xcodegen: found" || echo "xcodegen: MISSING (brew install xcodegen)"
    exit 0
fi

[ $# -ge 2 ] || fail "usage: release.sh <ios|mac> <lane> [options], or release.sh --check"
command -v fastlane >/dev/null || fail "fastlane is required (brew install fastlane)"

cd "$ROOT"
# fastlane must not ask for anything or phone home about the run.
export FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 FASTLANE_OPT_OUT_USAGE=1 CI=${CI:-}
exec fastlane "$@"
