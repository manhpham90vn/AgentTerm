#!/usr/bin/env bash
# Announces a release in a Discord channel, through a webhook of that channel.
#
#   DISCORD_WEBHOOK_URL=… scripts/announce-discord.sh 0.3.0-beta.3
#   DRY_RUN=1 scripts/announce-discord.sh 0.3.0-beta.3     # print what would be posted
#
# The message is the version's release notes (packaging/release-notes), with
# links to the GitHub release and to TestFlight. The webhook's address is a
# secret: whoever has it can post in the channel. The release workflow gets
# it from the DISCORD_WEBHOOK_URL secret and skips this when it is not set.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: announce-discord.sh VERSION (without the v prefix)}
VERSION=${VERSION#v}
REPO="https://github.com/manhpham90vn/AgentTerm"
NOTES=$(scripts/check-release-notes.sh "$VERSION")

# Discord allows 4096 characters in an embed's description.
PAYLOAD=$(python3 - "$VERSION" "$NOTES" "$REPO" <<'PY'
import json, re, sys
version, notes, repo = sys.argv[1:4]
text = open(notes, encoding="utf-8").read().strip()
# Discord draws "## " as a heading too large for a channel; bold reads better.
text = re.sub(r"^#{1,6}\s*(.+)$", r"**\1**", text, flags=re.M)
if len(text) > 3800:
    text = text[:3800].rsplit("\n", 1)[0] + "\n…"
print(json.dumps({
    "username": "AgentTerm",
    "embeds": [{
        "title": f"AgentTerm {version}",
        "url": f"{repo}/releases/tag/v{version}",
        "description": text,
        "color": 0x5C8DF6,
        "fields": [
            {"name": "Mac", "value": f"[Download]({repo}/releases/tag/v{version}) · `brew upgrade --cask agentterm`", "inline": True},
            {"name": "iPhone", "value": "[TestFlight](https://testflight.apple.com/join/Ny2JKHUp)", "inline": True},
        ],
    }],
    # Nobody is pinged, whatever the notes contain.
    "allowed_mentions": {"parse": []},
}))
PY
)

if [ -n "${DRY_RUN:-}" ]; then
    printf '%s\n' "$PAYLOAD" | python3 -m json.tool
    exit 0
fi
# No apostrophe in this message: inside ${...:?} newer versions of bash take one for the start of a quote.
: "${DISCORD_WEBHOOK_URL:?announce-discord.sh: DISCORD_WEBHOOK_URL must hold the webhook address of the channel}"
# The address is not echoed, and curl's errors do not print it either.
status=$(printf '%s' "$PAYLOAD" | curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- "$DISCORD_WEBHOOK_URL" 2>/dev/null || true)
case "$status" in
    2*) echo "[ok]      announced AgentTerm $VERSION on Discord" ;;
    *) echo "announce-discord.sh: Discord answered ${status:-nothing}" >&2; exit 1 ;;
esac
