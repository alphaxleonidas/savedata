#!/usr/bin/env bash
# game-stats.sh -- show Twitch stream/viewer counts for every game in a list.
#
# Input: the output of game-list.sh (default: ~/game-list.md).
# Only bulleted lines (" - ...") are looked at. Per line:
#   Steam  " - [1272160] [Game] The Life and Suffering of Sir Brante"
#            -> id and type tag are dropped; [Game], [Demo] and [Beta] are
#               kept, everything else (Tool, DLC, Application, Music, ...)
#               is skipped.
#   Epic   " - Alan Wake"                    -> scanned as is
#   GOG    " - Syberia [Not Installed]"      -> install tag dropped
# Any name containing the word "DLC" is skipped.
#
# The name that is sent to Twitch is cleaned first. Removed:
#   * (R) (TM) symbols
#   * the words Demo, Beta, Open/Closed Beta, Playtest, Public Testing
#   * the word Multiplayer
#   * "Chapter N" / "(Chapter N)" (including a leading " - " or ": ")
#   * "EP N" / "Episode N" (and a quoted subtitle after "EP N:")
#   * bracketed years such as (1999)
#   * edition tags: Deluxe / Definitive / Gold / Desktop / Enhanced (Plus) /
#     (The) Complete / Spacer's Choice / Game of the Year / Anniversary ...
#     Edition (+ trailing "Pack"), plus any other "<word> Edition"
#   * Remaster(ed) and Prologue
# Headers, separators, the Steam summary block etc. are not bulleted and are
# therefore ignored. Duplicate names are scanned once.
#
# Usage:  game-stats.sh [-n|--dry-run] [game-list-file]
#   -n, --dry-run   only print the names that WOULD be scanned (no Twitch
#                   credentials or network needed)
set -e

DRY_RUN=0
GAME_FILE=""
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) GAME_FILE="$arg" ;;
    esac
done
GAME_FILE="${GAME_FILE:-$HOME/game-list.md}"

# parse_entry LINE -> prints the cleaned game name, or returns 1 if the line
# is not a scannable game.
parse_entry() {
    local line="${1%$'\r'}" name tag type

    # Must be a bullet: "- ", "* " or "1. "
    if [[ "$line" =~ ^[[:space:]]*(-|\*|[0-9]+\.)[[:space:]]+(.*)$ ]]; then
        name="${BASH_REMATCH[2]}"
    else
        return 1
    fi

    # Optional Steam prefix: "[appid] [Type] Name" (the appid part is optional)
    if [[ "$name" =~ ^(\[[0-9]+\][[:space:]]*)?\[([^]]+)\][[:space:]]*(.*)$ ]]; then
        type="${BASH_REMATCH[2],,}"
        name="${BASH_REMATCH[3]}"
        case "$type" in
            game|demo|beta) ;;     # keep
            *) return 1 ;;         # tool, dlc, application, music, ...
        esac
    fi

    # DLC is not a game (catches Epic entries, which carry no type tag)
    local lower="${name,,}"
    [[ "$lower" =~ (^|[^[:alnum:]])dlc([^[:alnum:]]|$) ]] && return 1

    # GOG trailing install state
    name=$(printf '%s' "$name" | sed -E 's/[[:space:]]*\[(Not )?Installed\][[:space:]]*$//I')

    # Clean the name. Rules run top to bottom; \b keeps whole words only so
    # e.g. "Demon", "Demolition" or "Castlevania Anniversary Collection" survive.
    name=$(printf '%s' "$name" | sed -E '
        # trademark symbols (alternation, not a bracket, to stay UTF-8 safe)
        s/(®|™|©|℠)//g

        # bracketed years: (1999) [1999]
        s/\([[:space:]]*(19|20)[0-9]{2}[[:space:]]*\)//g
        s/\[[[:space:]]*(19|20)[0-9]{2}[[:space:]]*\]//g

        # bracketed noise: (Demo) (Test branch) (formerly X) (Chapter 1)
        s/\([[:space:]]*(demo|beta|playtest|test branch)[[:space:]]*\)//Ig
        s/\([[:space:]]*formerly [^)]*\)//Ig
        s/\([[:space:]]*chapter[^)]*\)//Ig

        # beta / testing
        s/\bpublic testing\b//Ig
        s/\b(open|closed|tech) beta\b//Ig
        s/\b(closed |open )?playtest\b//Ig
        s/\b(beta|demo)\b//Ig

        # multiplayer
        s/\bmultiplayer\b//Ig

        # chapters: "Chapter 1", "- Chapter 1", ": Chapter One", "CHAPTER II"
        s/([[:space:]]*(-|–|—|:))?[[:space:]]*\bchapter[[:space:]]+([0-9]+|[ivxl]+|one|two|three|four|five|six|seven|eight|nine|ten)\b[[:space:]]*(:|-)?//Ig

        # episodes: ", EP 1: "Subtitle"", ", Episode One", "- Episode 2"
        s/([[:space:]]*(,|-|–|—|:))?[[:space:]]*\b(ep|episode)\.?[[:space:]]+([0-9]+|[ivxl]+|one|two|three|four|five|six|seven|eight|nine|ten)\b([[:space:]]*:[[:space:]]*"[^"]*")?//Ig

        # editions
        s/\bgame of the year( edition)?\b//Ig
        s/\b(the )?complete edition\b//Ig
        s/\benhanced( plus)? edition\b//Ig
        s/\b([0-9]+(st|nd|rd|th) )?anniversary (edition|remaster(ed)?)\b//Ig
        s/\bspacer.?s choice edition\b//Ig
        s/\b(deluxe|definitive|gold|desktop|standard|special|collector.?s|ultimate|premium|premier) edition( pack)?\b//Ig
        s/[^[:space:]]+[[:space:]]+edition( pack)?\b//Ig
        s/\bedition( pack)?\b//Ig
        s/\bremaster(ed)?\b//Ig
        s/\bprologue\b//Ig

        # tidy up what is left
        s/\([[:space:]]*\)//g
        s/[[:space:]]+/ /g
        s/[[:space:]]+(:|,)/\1/g
        s/^([[:space:]]|:|-|–|—|\|)+//
        s/([[:space:]]|:|,|-|–|—|\|)+$//
    ')

    # Skip launcher helper entries that are not games
    [[ "$name" =~ [Rr]edistributable ]] && return 1

    # Twitch names do not like apostrophes in the lookup
    name="${name//\'/}"

    [ -z "$name" ] && return 1
    printf '%s' "$name"
}

if [ ! -f "$GAME_FILE" ]; then
    echo "Error: Game list file '$GAME_FILE' not found." >&2
    exit 1
fi

# Already-scanned names, newline separated. (Deliberately NOT an associative
# array keyed by game name: odd titles such as  3 out of 10, EP 1: "Welcome..."
# can break array subscripts and make bash try to run words of the title as
# commands -- "ep: command not found".)
SEEN=$'\n'
is_seen()   { [[ "$SEEN" == *$'\n'"$1"$'\n'* ]]; }
mark_seen() { SEEN+="$1"$'\n'; }

if [ "$DRY_RUN" -eq 1 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        game_name=$(parse_entry "$line") || continue
        key="${game_name,,}"
        is_seen "$key" && continue
        mark_seen "$key"
        printf '%s\n' "$game_name"
    done < "$GAME_FILE"
    exit 0
fi

for cmd in curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required tool '$cmd' is not installed." >&2
        exit 1
    fi
done

if [ -z "${TWITCH_CLIENT_ID-}" ] || [ -z "${TWITCH_CLIENT_SECRET-}" ]; then
    echo "Error: Twitch credentials are not set." >&2
    echo "Please export them before running the script:" >&2
    echo "  export TWITCH_CLIENT_ID='your_client_id'" >&2
    echo "  export TWITCH_CLIENT_SECRET='your_client_secret'" >&2
    exit 1
fi

echo "Authenticating with Twitch API..."
TOKEN_RESPONSE=$(curl -s -X POST "https://id.twitch.tv/oauth2/token" \
    -d "client_id=$TWITCH_CLIENT_ID" \
    -d "client_secret=$TWITCH_CLIENT_SECRET" \
    -d "grant_type=client_credentials")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Failed to obtain Twitch OAuth token. Check your credentials." >&2
    exit 1
fi

echo ""
printf "%-30s | %-16s | %-15s\n" "Game Name" "Active Streams" "Total Viewers"
printf "%-30s-+-%-16s-+-%-15s\n" "----------------------------------" "------------------" "---------------"

while IFS= read -r line || [ -n "$line" ]; do
    game_name=$(parse_entry "$line") || continue

    key="${game_name,,}"
    is_seen "$key" && continue
    mark_seen "$key"

    encoded_name=$(printf "%s" "$game_name" | jq -Rr @uri)

    game_response=$(curl -s -X GET "https://api.twitch.tv/helix/games?name=$encoded_name" \
        -H "Client-Id: $TWITCH_CLIENT_ID" \
        -H "Authorization: Bearer $ACCESS_TOKEN")

    game_id=$(echo "$game_response" | jq -r '.data[0].id // empty' 2>/dev/null || true)

    if [ -z "$game_id" ]; then
        printf "%-30s | %-16s | %-15s\n" "$game_name" "Not Found" "-"
        continue
    fi

    streams_response=$(curl -s -X GET "https://api.twitch.tv/helix/streams?game_id=$game_id&first=100" \
        -H "Client-Id: $TWITCH_CLIENT_ID" \
        -H "Authorization: Bearer $ACCESS_TOKEN")

    stream_count=$(echo "$streams_response" | jq '[.data[]] | length' 2>/dev/null || echo "0")
    total_viewers=$(echo "$streams_response" | jq '[.data[].viewer_count] | add // 0' 2>/dev/null || echo "0")

    printf "%-30s | %-16s | %-15s\n" "$game_name" "$stream_count" "$total_viewers"
    sleep 0.2
done < "$GAME_FILE"
