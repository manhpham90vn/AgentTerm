# Sourced by the iOS scripts to decide which simulator to use.
#
#   choose_simulator "<name or UDID, may be empty>" "<fallback name>"
#
# Sets SIM_UDID and SIM_NAME. With no name given it asks, when run from a
# terminal, and otherwise takes the booted simulator or the fallback.
# `SIMULATOR=<name or UDID>` in the environment counts as a given name.

# One line per available iPhone simulator: UDID|name|state|runtime
list_simulators() {
    xcrun simctl list devices available | awk '
        /^-- / { runtime = $0; gsub(/^-- | --$/, "", runtime); next }
        match($0, /\([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\)/) {
            name = substr($0, 1, RSTART - 1); gsub(/^ +| +$/, "", name)
            if (name !~ /^iPhone/) next
            udid = substr($0, RSTART + 1, RLENGTH - 2)
            state = ($0 ~ /\(Booted\)/) ? "Booted" : "Shutdown"
            print udid "|" name "|" state "|" runtime
        }'
}

print_simulators() {
    list_simulators | awk -F'|' '{ printf "  %-22s %-12s %s%s\n", $2, $4, $1, ($3 == "Booted" ? "  (booted)" : "") }'
}

choose_simulator() {
    local wanted="${1:-${SIMULATOR:-}}" fallback="${2:-iPhone 17}" all line
    all="$(list_simulators)"
    if [ -z "$all" ]; then
        echo "No iPhone simulator is installed. Add one in Xcode > Settings > Components." >&2
        return 1
    fi

    if [ -n "$wanted" ]; then
        # A UDID, or a name. Among simulators of the same name the booted one wins.
        line="$(printf '%s\n' "$all" | awk -F'|' -v w="$wanted" '$1 == w' | head -1)"
        [ -n "$line" ] || line="$(printf '%s\n' "$all" | awk -F'|' -v w="$wanted" '$2 == w && $3 == "Booted"' | head -1)"
        [ -n "$line" ] || line="$(printf '%s\n' "$all" | awk -F'|' -v w="$wanted" '$2 == w' | head -1)"
        if [ -z "$line" ]; then
            echo "No simulator is called \"$wanted\". Available:" >&2
            print_simulators >&2
            return 1
        fi
    elif [ -t 0 ] && [ -t 1 ]; then
        # Asked from a terminal: show the list and let the user pick.
        local preferred count choice
        preferred="$(printf '%s\n' "$all" | awk -F'|' '$3 == "Booted" { print NR; exit }')"
        [ -n "$preferred" ] || preferred="$(printf '%s\n' "$all" | awk -F'|' -v w="$fallback" '$2 == w { print NR; exit }')"
        preferred="${preferred:-1}"
        count="$(printf '%s\n' "$all" | wc -l | tr -d ' ')"
        echo "Which simulator?"
        printf '%s\n' "$all" | awk -F'|' '{ printf "  %2d) %-22s %-12s%s\n", NR, $2, $4, ($3 == "Booted" ? " (booted)" : "") }'
        while :; do
            printf 'Number [%s]: ' "$preferred"
            read -r choice || choice=""
            choice="${choice:-$preferred}"
            case "$choice" in
                ''|*[!0-9]*) ;;
                *) [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ] && break ;;
            esac
            echo "Enter a number from 1 to $count."
        done
        line="$(printf '%s\n' "$all" | sed -n "${choice}p")"
    else
        # Not a terminal (a script, CI): the booted simulator, or the fallback.
        line="$(printf '%s\n' "$all" | awk -F'|' '$3 == "Booted"' | head -1)"
        [ -n "$line" ] || line="$(printf '%s\n' "$all" | awk -F'|' -v w="$fallback" '$2 == w' | head -1)"
        [ -n "$line" ] || line="$(printf '%s\n' "$all" | head -1)"
    fi

    SIM_UDID="${line%%|*}"
    SIM_NAME="$(printf '%s' "$line" | cut -d'|' -f2)"
}
