#!/bin/bash

# ============================================================
# Game Library List
#
# Steam + Epic + GOG
#
# Steam data is read entirely from Steam's LOCAL cache.
# No downloads.
# No Steam API.
# No external Python packages.
#
# Requirements:
#   bash
#   python3
#   find
#   grep
#   jq
# ============================================================

set -u

# ============================================================
# FIND STEAM
# ============================================================

STEAM_ROOT=""

STEAM_PATHS=(
    "$HOME/.steam/steam"
    "$HOME/.steam/root"
    "$HOME/.local/share/Steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
)

for path in "${STEAM_PATHS[@]}"; do
    if [ -d "$path" ]; then
        STEAM_ROOT="$path"
        break
    fi
done


# ============================================================
# FIND HEROIC
# ============================================================

HEROIC_CACHE="$HOME/.config/heroic/store_cache"

if [ ! -d "$HEROIC_CACHE" ]; then
    if [ -d "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/store_cache" ]; then
        HEROIC_CACHE="$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/store_cache"
    fi
fi


# ============================================================
# STEAM
# ============================================================

echo "========================================"
echo "          STEAM GAMES"
echo "========================================"

if [ -z "$STEAM_ROOT" ]; then

    echo "[!] Steam installation not found."

else

    STEAM_CACHE="$STEAM_ROOT/appcache/librarycache"
    APPINFO="$STEAM_ROOT/appcache/appinfo.vdf"

    echo "[-] Steam root:"
    echo "    $STEAM_ROOT"

    # --------------------------------------------------------
    # Check Steam files
    # --------------------------------------------------------

    if [ ! -d "$STEAM_CACHE" ]; then

        echo "[!] Steam library cache not found:"
        echo "    $STEAM_CACHE"

    elif [ ! -f "$APPINFO" ]; then

        echo "[!] Steam appinfo.vdf not found:"
        echo "    $APPINFO"

    elif ! command -v python3 >/dev/null 2>&1; then

        echo "[!] python3 is required."

    else

        # ----------------------------------------------------
        # Get AppIDs from librarycache
        # ----------------------------------------------------

        folder_ids=$(
            find "$STEAM_CACHE" \
                -maxdepth 1 \
                -mindepth 1 \
                -type d \
                -printf '%f\n' 2>/dev/null |
            grep -E '^[0-9]+$' |
            sort -n
        )

        if [ -z "$folder_ids" ]; then

            echo "[!] No numeric Steam AppIDs found."

        else

            TOTAL=$(echo "$folder_ids" | wc -l)

            echo "[-] Found $TOTAL Steam AppIDs."
            echo "[-] Reading local appinfo.vdf..."
            echo

            # =================================================
            # Embedded Steam appinfo.vdf parser
            #
            # Supports Steam appinfo v40 and v41.
            #
            # v41 uses a string table for keys.
            # =================================================

            PARSER=$(mktemp)

            cat > "$PARSER" <<'PYTHON'
#!/usr/bin/env python3

import sys
import struct


# Steam appinfo.vdf magic numbers
MAGIC_V40 = 0x07564428
MAGIC_V41 = 0x07564429


def read_string_table(data, offset):
    """
    Read Steam v41 string table.

    Layout:
        uint32 string_count
        null-terminated strings...
    """

    if offset < 0 or offset + 4 > len(data):
        raise ValueError("Invalid string table offset")

    count = struct.unpack_from("<I", data, offset)[0]

    table = []
    pos = offset + 4

    for _ in range(count):

        end = data.find(b"\x00", pos)

        if end == -1:
            raise ValueError("Invalid string table")

        table.append(
            data[pos:end].decode("utf-8", errors="replace")
        )

        pos = end + 1

    return table


def read_cstring(data, pos):
    end = data.find(b"\x00", pos)

    if end == -1:
        raise ValueError("Invalid string")

    return (
        data[pos:end].decode("utf-8", errors="replace"),
        end + 1
    )


def parse_kv(data, pos, end, string_table):
    """
    Parse Steam binary KeyValues.

    Returns:
        dict, new_position
    """

    result = {}

    while pos < end:

        value_type = data[pos]
        pos += 1

        # ----------------------------------------------------
        # End object
        # ----------------------------------------------------

        if value_type == 0x08:
            return result, pos

        # ----------------------------------------------------
        # Read key
        # ----------------------------------------------------

        if string_table is not None:

            if pos + 4 > end:
                raise ValueError("Truncated key index")

            key_index = struct.unpack_from("<I", data, pos)[0]
            pos += 4

            if key_index >= len(string_table):
                raise ValueError("Invalid string table index")

            key = string_table[key_index]

        else:

            key, pos = read_cstring(data, pos)

        # ----------------------------------------------------
        # Object
        # ----------------------------------------------------

        if value_type == 0x00:

            value, pos = parse_kv(
                data,
                pos,
                end,
                string_table
            )

            result[key] = value

        # ----------------------------------------------------
        # String
        # ----------------------------------------------------

        elif value_type == 0x01:

            value, pos = read_cstring(data, pos)

            result[key] = value

        # ----------------------------------------------------
        # Int32
        # ----------------------------------------------------

        elif value_type == 0x02:

            if pos + 4 > end:
                raise ValueError("Truncated int32")

            value = struct.unpack_from(
                "<i",
                data,
                pos
            )[0]

            pos += 4

            result[key] = value

        # ----------------------------------------------------
        # Float
        # ----------------------------------------------------

        elif value_type == 0x03:

            if pos + 4 > end:
                raise ValueError("Truncated float")

            value = struct.unpack_from(
                "<f",
                data,
                pos
            )[0]

            pos += 4

            result[key] = value

        # ----------------------------------------------------
        # Pointer / uint32
        # ----------------------------------------------------

        elif value_type == 0x04:

            if pos + 4 > end:
                raise ValueError("Truncated pointer")

            value = struct.unpack_from(
                "<I",
                data,
                pos
            )[0]

            pos += 4

            result[key] = value

        # ----------------------------------------------------
        # Wide string
        # ----------------------------------------------------

        elif value_type == 0x05:

            start = pos

            while pos + 1 < end:

                if data[pos] == 0 and data[pos + 1] == 0:
                    break

                pos += 2

            if pos + 1 >= end:
                raise ValueError("Truncated wide string")

            raw = data[start:pos]

            result[key] = raw.decode(
                "utf-16le",
                errors="replace"
            )

            pos += 2

        # ----------------------------------------------------
        # Color
        # ----------------------------------------------------

        elif value_type == 0x06:

            if pos + 4 > end:
                raise ValueError("Truncated color")

            result[key] = data[pos:pos + 4]

            pos += 4

        # ----------------------------------------------------
        # UInt64
        # ----------------------------------------------------

        elif value_type == 0x07:

            if pos + 8 > end:
                raise ValueError("Truncated uint64")

            value = struct.unpack_from(
                "<Q",
                data,
                pos
            )[0]

            pos += 8

            result[key] = value

        # ----------------------------------------------------
        # Unknown
        # ----------------------------------------------------

        else:

            raise ValueError(
                f"Unknown VDF type: {value_type:#x}"
            )

    return result, pos


def extract_names(filename):

    with open(filename, "rb") as f:
        data = f.read()

    if len(data) < 8:
        raise ValueError("appinfo.vdf is too small")

    magic = struct.unpack_from("<I", data, 0)[0]

    if magic == MAGIC_V41:

        if len(data) < 16:
            raise ValueError("Invalid v41 header")

        string_table_offset = struct.unpack_from(
            "<q",
            data,
            8
        )[0]

        string_table = read_string_table(
            data,
            string_table_offset
        )

        pos = 16

    elif magic == MAGIC_V40:

        string_table = None
        pos = 8

    else:

        raise ValueError(
            f"Unsupported appinfo.vdf format: {magic:#x}"
        )

    names = {}

    data_len = len(data)

    # --------------------------------------------------------
    # Read application records
    # --------------------------------------------------------

    while pos + 8 <= data_len:

        appid = struct.unpack_from(
            "<I",
            data,
            pos
        )[0]

        # Steam's end marker
        if appid == 0:
            break

        size = struct.unpack_from(
            "<I",
            data,
            pos + 4
        )[0]

        if size < 60:
            break

        record_end = pos + 8 + size

        if record_end > data_len:
            break

        # ----------------------------------------------------
        # App record:
        #
        # AppID              4
        # Size               4
        # InfoState          4
        # LastUpdated        4
        # PICS token         8
        # SHA1              20
        # Change number      4
        # Binary SHA1       20
        #
        # Total after size = 60
        # ----------------------------------------------------

        kv_start = pos + 8 + 60

        try:

            kv, _ = parse_kv(
                data,
                kv_start,
                record_end,
                string_table
            )

            # Typical structure:
            #
            # appinfo
            #   common
            #       name
            #       type

            appinfo = kv.get("appinfo", {})

            if not isinstance(appinfo, dict):
                pos = record_end
                continue

            common = appinfo.get("common", {})

            if not isinstance(common, dict):
                pos = record_end
                continue

            name = common.get("name")
            app_type = common.get("type", "unknown")

            if isinstance(name, str) and name.strip():

                name = (
                    name
                    .replace("\t", " ")
                    .replace("\n", " ")
                    .replace("\r", " ")
                    .strip()
                )

                names[str(appid)] = (
                    name,
                    str(app_type)
                )

        except Exception:
            # Don't let one malformed entry stop the entire scan.
            pass

        pos = record_end

    return names


# ============================================================
# MAIN
# ============================================================

if len(sys.argv) != 2:
    print(
        f"Usage: {sys.argv[0]} appinfo.vdf",
        file=sys.stderr
    )
    sys.exit(1)

try:

    names = extract_names(sys.argv[1])

    for appid in sorted(
        names,
        key=lambda x: int(x)
    ):

        name, app_type = names[appid]

        print(
            f"{appid}\t{app_type}\t{name}"
        )

except Exception as e:

    print(
        f"[!] Parser error: {e}",
        file=sys.stderr
    )

    sys.exit(1)

PYTHON

            chmod +x "$PARSER"

            # =================================================
            # Parse appinfo.vdf
            # =================================================

            APPINFO_TSV=$(mktemp)

            if ! python3 "$PARSER" "$APPINFO" > "$APPINFO_TSV"; then

                echo "[!] Failed to parse appinfo.vdf."

                rm -f "$PARSER" "$APPINFO_TSV"

            else

                # ------------------------------------------------
                # Build lookup arrays
                # ------------------------------------------------

                declare -A STEAM_NAME
                declare -A STEAM_TYPE

                while IFS=$'\t' read -r appid type name; do

                    if [ -n "${appid:-}" ] && [ -n "${name:-}" ]; then

                        STEAM_NAME["$appid"]="$name"
                        STEAM_TYPE["$appid"]="$type"

                    fi

                done < "$APPINFO_TSV"


                # =================================================
                # Display games
                # =================================================

                FOUND=0
                UNKNOWN=0

                while IFS= read -r appid; do

                    if [ -n "${STEAM_NAME[$appid]+x}" ]; then

                        name="${STEAM_NAME[$appid]}"
                        type="${STEAM_TYPE[$appid]}"

                        printf " - [%s] [%s] %s\n" \
                            "$appid" \
                            "$type" \
                            "$name"

                        FOUND=$((FOUND + 1))

                    else

                        printf " - [%s] Unknown\n" \
                            "$appid"

                        UNKNOWN=$((UNKNOWN + 1))

                    fi

                done <<< "$folder_ids"


                # ------------------------------------------------
                # Summary
                # ------------------------------------------------

                echo
                echo "----------------------------------------"
                echo "Steam summary"
                echo "----------------------------------------"
                echo "AppIDs found : $TOTAL"
                echo "Names found  : $FOUND"
                echo "Unknown      : $UNKNOWN"
                echo "----------------------------------------"


                rm -f "$PARSER" "$APPINFO_TSV"

            fi

        fi
    fi
fi


# ============================================================
# EPIC GAMES
# ============================================================

echo
echo "========================================"
echo "          EPIC GAMES (Heroic)"
echo "========================================"

EPIC_FOUND=0

if [ -d "$HEROIC_CACHE" ]; then

    for json_file in \
        "$HEROIC_CACHE"/*legendary*.json \
        "$HEROIC_CACHE"/*epic*.json; do

        if [ -f "$json_file" ]; then

            titles=$(
                jq -r '
                    (.library // .gamesOverride // .)[]?
                    | .title
                    // .about.title
                    // empty
                ' "$json_file" 2>/dev/null
            )

            if [ -n "$titles" ]; then

                EPIC_FOUND=1

                echo "--- Found in: $(basename "$json_file") ---"

                while IFS= read -r title; do
                    echo " - $title"
                done <<< "$titles"

            fi

        fi

    done

else

    echo "[!] Heroic cache not found:"
    echo "    $HEROIC_CACHE"

fi

if [ "$EPIC_FOUND" -eq 0 ]; then
    echo "[!] No Epic Games library files found."
fi


# ============================================================
# GOG GAMES
# ============================================================

echo
echo "========================================"
echo "          GOG GAMES (Heroic)"
echo "========================================"

GOG_FILE="$HEROIC_CACHE/gog_library.json"

if [ -f "$GOG_FILE" ]; then

    jq -r '
        if type == "array" then
            .[]
        elif type == "object" then
            (.games // .)
            | to_entries[]
            | .value
        else
            empty
        end
        |
        select(.title != null)
        |
        " - \(.title) [\(if .is_installed then "Installed" else "Not Installed" end)]"
    ' "$GOG_FILE" 2>/dev/null ||
        echo "[!] Error parsing GOG JSON file."

else

    echo "[!] GOG library file not found:"
    echo "    $GOG_FILE"

fi


# ============================================================
# DONE
# ============================================================

echo
echo "========================================"
echo "Done!"
echo "========================================"
