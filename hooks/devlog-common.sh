#!/usr/bin/env bash
#
# Shared portable helpers for the Bash hook implementations.
# The public hooks source this file and keep all failures fail-open and silent.
# Bash 3.2 compatibility is intentional so the scripts work with the system
# Bash shipped by older macOS releases as well as current Linux distributions.

# Read stdin without ever storing raw bytes in a Bash variable. head enforces a
# max+1-byte read, od preserves NUL and invalid UTF-8 as hex, and the C-locale
# AWK parser applies the same strict RFC JSON and property-identity rules as the
# PowerShell implementation.
devlog_parse_input() {
    local parsed

    parsed=$(
        # The entrypoint stays fail-open, but this local pipeline must not turn
        # a partial head/od read into an apparently valid protocol object.
        set -o pipefail
        LC_ALL=C head -c 1048577 |
            LC_ALL=C od -An -v -tx1 |
            LC_ALL=C awk '
                function hex_digit(ch) {
                    ch = tolower(ch)
                    return index("0123456789abcdef", ch) - 1
                }

                function hex_byte(token,    high, low) {
                    high = hex_digit(substr(token, 1, 1))
                    low = hex_digit(substr(token, 2, 1))
                    if (length(token) != 2 || high < 0 || low < 0) {
                        return -1
                    }
                    return (high * 16) + low
                }

                function is_ws(value) {
                    return value == 32 || value == 9 ||
                           value == 13 || value == 10
                }

                function skip_ws() {
                    while (pos <= byte_len && is_ws(bytes[pos])) {
                        pos++
                    }
                }

                function is_continuation(value) {
                    return value >= 128 && value <= 191
                }

                # Decode one already-buffered UTF-8 scalar. The function sets
                # decoded_codepoint/decoded_width and rejects overlong forms,
                # surrogate scalars, values above U+10FFFF, and truncation.
                function decode_utf8_at(offset,    b1, b2, b3, b4) {
                    b1 = bytes[offset]
                    decoded_codepoint = 0
                    decoded_width = 0

                    if (b1 >= 0 && b1 <= 127) {
                        decoded_codepoint = b1
                        decoded_width = 1
                        return 1
                    }
                    if (b1 >= 194 && b1 <= 223) {
                        if (offset + 1 > byte_len) {
                            return 0
                        }
                        b2 = bytes[offset + 1]
                        if (!is_continuation(b2)) {
                            return 0
                        }
                        decoded_codepoint = (b1 - 192) * 64 + (b2 - 128)
                        decoded_width = 2
                        return 1
                    }
                    if (b1 >= 224 && b1 <= 239) {
                        if (offset + 2 > byte_len) {
                            return 0
                        }
                        b2 = bytes[offset + 1]
                        b3 = bytes[offset + 2]
                        if (!is_continuation(b3)) {
                            return 0
                        }
                        if (b1 == 224) {
                            if (b2 < 160 || b2 > 191) {
                                return 0
                            }
                        } else if (b1 == 237) {
                            if (b2 < 128 || b2 > 159) {
                                return 0
                            }
                        } else if (!is_continuation(b2)) {
                            return 0
                        }
                        decoded_codepoint = (b1 - 224) * 4096 + (b2 - 128) * 64 + (b3 - 128)
                        decoded_width = 3
                        return 1
                    }
                    if (b1 >= 240 && b1 <= 244) {
                        if (offset + 3 > byte_len) {
                            return 0
                        }
                        b2 = bytes[offset + 1]
                        b3 = bytes[offset + 2]
                        b4 = bytes[offset + 3]
                        if (!is_continuation(b3) || !is_continuation(b4)) {
                            return 0
                        }
                        if (b1 == 240) {
                            if (b2 < 144 || b2 > 191) {
                                return 0
                            }
                        } else if (b1 == 244) {
                            if (b2 < 128 || b2 > 143) {
                                return 0
                            }
                        } else if (!is_continuation(b2)) {
                            return 0
                        }
                        decoded_codepoint = (b1 - 240) * 262144 + (b2 - 128) * 4096 + (b3 - 128) * 64 + (b4 - 128)
                        decoded_width = 4
                        return 1
                    }
                    return 0
                }

                function validate_input(    cursor) {
                    if (byte_len > 1048576) {
                        return 0
                    }
                    cursor = 1
                    while (cursor <= byte_len) {
                        # Raw NUL must remain observable and invalid even when
                        # deleting it would reveal otherwise valid JSON.
                        if (bytes[cursor] == 0 || !decode_utf8_at(cursor)) {
                            return 0
                        }
                        cursor += decoded_width
                    }
                    return 1
                }

                function hex_value_at(offset,    value, count, digit) {
                    if (offset + 3 > byte_len) {
                        return -1
                    }
                    value = 0
                    for (count = 0; count < 4; count++) {
                        digit = bytes[offset + count]
                        if (digit >= 48 && digit <= 57) {
                            digit -= 48
                        } else if (digit >= 65 && digit <= 70) {
                            digit = digit - 65 + 10
                        } else if (digit >= 97 && digit <= 102) {
                            digit = digit - 97 + 10
                        } else {
                            return -1
                        }
                        value = value * 16 + digit
                    }
                    return value
                }

                # String mode keeps large ordinary values O(n): only bounded
                # property identities and valid session ids are accumulated.
                #   0 = validate/skip value, 1 = top-level property identity,
                #   2 = nested property name, 3 = session-id candidate.
                function append_string_codepoint(codepoint, mode,    folded) {
                    if (mode == 1 || mode == 2) {
                        string_property_scalars++
                        if (string_property_scalars > 256) {
                            return 0
                        }
                    }

                    if (mode == 1) {
                        string_identity = string_identity sprintf("%06x;", codepoint)
                        folded = codepoint
                        if (folded >= 65 && folded <= 90) {
                            folded += 32
                        }
                        string_folded = string_folded sprintf("%06x;", folded)

                        # Protocol names are ASCII. Canonical scalar identity
                        # remains authoritative for duplicate detection.
                        if (codepoint >= 32 && codepoint <= 126) {
                            string_ascii = string_ascii sprintf("%c", codepoint)
                        } else {
                            string_ascii_only = 0
                        }
                    } else if (mode == 3) {
                        string_session_scalars++
                        if (string_session_scalars > 64) {
                            string_session_valid = 0
                        } else if ((codepoint >= 65 && codepoint <= 90) ||
                                   (codepoint >= 97 && codepoint <= 122) ||
                                   (codepoint >= 48 && codepoint <= 57) ||
                                   codepoint == 95 || codepoint == 46 ||
                                   codepoint == 45) {
                            if (string_session_valid) {
                                string_session = string_session sprintf("%c", codepoint)
                            }
                        } else {
                            string_session_valid = 0
                            string_session = ""
                        }
                    }
                    return 1
                }

                function parse_string(mode,    value, escaped, high, low, codepoint) {
                    if (bytes[pos] != 34) {
                        return 0
                    }
                    pos++
                    string_identity = ""
                    string_folded = ""
                    string_ascii = ""
                    string_ascii_only = 1
                    string_property_scalars = 0
                    string_session = ""
                    string_session_scalars = 0
                    string_session_valid = 1

                    while (pos <= byte_len) {
                        value = bytes[pos]
                        if (value == 34) {
                            pos++
                            parsed_string_identity = string_identity
                            parsed_string_folded = string_folded
                            parsed_string_ascii = string_ascii
                            parsed_string_ascii_only = string_ascii_only
                            parsed_string_session = string_session
                            parsed_string_session_valid = (mode == 3 &&
                                string_session_valid && string_session_scalars >= 1 &&
                                string_session_scalars <= 64)
                            return 1
                        }
                        if (value == 92) {
                            pos++
                            if (pos > byte_len) {
                                return 0
                            }
                            escaped = bytes[pos]
                            pos++
                            if (escaped == 34 || escaped == 92 || escaped == 47) {
                                if (!append_string_codepoint(escaped, mode)) { return 0 }
                                continue
                            }
                            if (escaped == 98) {
                                if (!append_string_codepoint(8, mode)) { return 0 }
                                continue
                            }
                            if (escaped == 102) {
                                if (!append_string_codepoint(12, mode)) { return 0 }
                                continue
                            }
                            if (escaped == 110) {
                                if (!append_string_codepoint(10, mode)) { return 0 }
                                continue
                            }
                            if (escaped == 114) {
                                if (!append_string_codepoint(13, mode)) { return 0 }
                                continue
                            }
                            if (escaped == 116) {
                                if (!append_string_codepoint(9, mode)) { return 0 }
                                continue
                            }
                            if (escaped != 117) {
                                return 0
                            }

                            high = hex_value_at(pos)
                            if (high < 0) {
                                return 0
                            }
                            pos += 4
                            if (high >= 55296 && high <= 56319) {
                                if (pos + 5 > byte_len ||
                                    bytes[pos] != 92 ||
                                    bytes[pos + 1] != 117) {
                                    return 0
                                }
                                pos += 2
                                low = hex_value_at(pos)
                                if (low < 56320 || low > 57343) {
                                    return 0
                                }
                                pos += 4
                                codepoint = 65536 + (high - 55296) * 1024 + (low - 56320)
                            } else {
                                if (high >= 56320 && high <= 57343) {
                                    return 0
                                }
                                codepoint = high
                            }
                            if (!append_string_codepoint(codepoint, mode)) { return 0 }
                            continue
                        }

                        if (value < 32 || !decode_utf8_at(pos)) {
                            return 0
                        }
                        if (!append_string_codepoint(decoded_codepoint, mode)) { return 0 }
                        pos += decoded_width
                    }
                    return 0
                }

                function is_digit(value) {
                    return value >= 48 && value <= 57
                }

                function advance_number() {
                    number_characters++
                    if (number_characters > 1024) {
                        return 0
                    }
                    pos++
                    return 1
                }

                # Validate JSON number grammar in one pass without building a
                # potentially megabyte-sized AWK string.
                function parse_number(    value) {
                    number_characters = 0
                    if (bytes[pos] == 45 && !advance_number()) { return 0 }
                    if (pos > byte_len) { return 0 }

                    value = bytes[pos]
                    if (value == 48) {
                        if (!advance_number()) { return 0 }
                        if (pos <= byte_len && is_digit(bytes[pos])) { return 0 }
                    } else if (value >= 49 && value <= 57) {
                        do {
                            if (!advance_number()) { return 0 }
                        } while (pos <= byte_len && is_digit(bytes[pos]))
                    } else {
                        return 0
                    }

                    if (pos <= byte_len && bytes[pos] == 46) {
                        if (!advance_number()) { return 0 }
                        if (pos > byte_len || !is_digit(bytes[pos])) { return 0 }
                        do {
                            if (!advance_number()) { return 0 }
                        } while (pos <= byte_len && is_digit(bytes[pos]))
                    }

                    if (pos <= byte_len && (bytes[pos] == 69 || bytes[pos] == 101)) {
                        if (!advance_number()) { return 0 }
                        if (pos <= byte_len && (bytes[pos] == 43 || bytes[pos] == 45)) {
                            if (!advance_number()) { return 0 }
                        }
                        if (pos > byte_len || !is_digit(bytes[pos])) { return 0 }
                        do {
                            if (!advance_number()) { return 0 }
                        } while (pos <= byte_len && is_digit(bytes[pos]))
                    }

                    parsed_type = "number"
                    parsed_value = ""
                    return 1
                }

                function parse_primitive(    value) {
                    value = bytes[pos]
                    if (value == 116 && bytes[pos + 1] == 114 &&
                        bytes[pos + 2] == 117 && bytes[pos + 3] == 101) {
                        pos += 4
                        parsed_type = "boolean"
                        parsed_value = "true"
                        return 1
                    }
                    if (value == 102 && bytes[pos + 1] == 97 &&
                        bytes[pos + 2] == 108 && bytes[pos + 3] == 115 &&
                        bytes[pos + 4] == 101) {
                        pos += 5
                        parsed_type = "boolean"
                        parsed_value = "false"
                        return 1
                    }
                    if (value == 110 && bytes[pos + 1] == 117 &&
                        bytes[pos + 2] == 108 && bytes[pos + 3] == 108) {
                        pos += 4
                        parsed_type = "null"
                        parsed_value = ""
                        return 1
                    }
                    if (value == 45 || is_digit(value)) {
                        return parse_number()
                    }
                    return 0
                }

                function parse_value(depth, capture_session,    value, ok) {
                    value_count++
                    if (value_count > 4096) {
                        return 0
                    }
                    skip_ws()
                    if (pos > byte_len) {
                        return 0
                    }
                    value = bytes[pos]
                    if (value == 34) {
                        ok = parse_string(capture_session ? 3 : 0)
                        if (ok) {
                            parsed_type = "string"
                            parsed_value = parsed_string_session
                            parsed_session_valid = parsed_string_session_valid
                        }
                        return ok
                    }
                    if (value == 123) {
                        ok = parse_object(0, depth)
                        if (ok) {
                            parsed_type = "object"
                            parsed_value = ""
                            parsed_session_valid = 0
                        }
                        return ok
                    }
                    if (value == 91) {
                        ok = parse_array(depth)
                        if (ok) {
                            parsed_type = "array"
                            parsed_value = ""
                            parsed_session_valid = 0
                        }
                        return ok
                    }
                    if (!parse_primitive()) {
                        return 0
                    }
                    parsed_session_valid = 0
                    return 1
                }

                function parse_array(depth,    value) {
                    if (depth > 128 || bytes[pos] != 91) {
                        return 0
                    }
                    pos++
                    skip_ws()
                    if (bytes[pos] == 93) {
                        pos++
                        return 1
                    }
                    while (pos <= byte_len) {
                        if (!parse_value(depth + 1, 0)) {
                            return 0
                        }
                        skip_ws()
                        value = bytes[pos]
                        if (value == 93) {
                            pos++
                            return 1
                        }
                        if (value != 44) {
                            return 0
                        }
                        pos++
                        skip_ws()
                    }
                    return 0
                }

                function parse_object(capture_protocol, depth,    key_identity, key_folded,
                                      key_ascii, key_ascii_only, capture_session, value,
                                      value_type, value_session_valid) {
                    if (depth > 128 || bytes[pos] != 123) {
                        return 0
                    }
                    pos++
                    skip_ws()
                    if (bytes[pos] == 125) {
                        pos++
                        return 1
                    }

                    while (pos <= byte_len) {
                        if (!parse_string(capture_protocol ? 1 : 2)) {
                            return 0
                        }
                        key_identity = parsed_string_identity
                        key_folded = parsed_string_folded
                        key_ascii = parsed_string_ascii
                        key_ascii_only = parsed_string_ascii_only

                        if (capture_protocol) {
                            if (key_identity in seen_exact_names) {
                                return 0
                            }
                            if (key_folded in seen_folded_names) {
                                return 0
                            }
                            seen_exact_names[key_identity] = 1
                            seen_folded_names[key_folded] = 1
                        }

                        skip_ws()
                        if (bytes[pos] != 58) {
                            return 0
                        }
                        pos++
                        capture_session = (capture_protocol && key_ascii_only &&
                            key_ascii == "session_id") ? 1 : 0
                        if (!parse_value(depth + 1, capture_session)) {
                            return 0
                        }
                        value_type = parsed_type
                        value = parsed_value
                        value_session_valid = parsed_session_valid

                        if (capture_protocol && key_ascii_only) {
                            if (key_ascii == "session_id") {
                                if (value_type == "string" && value_session_valid) {
                                    has_session = 1
                                    safe_session = value
                                } else {
                                    has_session = 0
                                    safe_session = ""
                                }
                            } else if (key_ascii == "stop_hook_active") {
                                stop_active = (value_type == "boolean" && value == "true") ? 1 : 0
                            }
                        }

                        skip_ws()
                        value = bytes[pos]
                        if (value == 125) {
                            pos++
                            return 1
                        }
                        if (value != 44) {
                            return 0
                        }
                        pos++
                        skip_ws()
                    }
                    return 0
                }

                function parse_document() {
                    skip_ws()
                    if (!parse_object(1, 1)) {
                        return 0
                    }
                    skip_ws()
                    return pos > byte_len
                }

                {
                    for (field = 1; field <= NF; field++) {
                        value = hex_byte($field)
                        if (value < 0) {
                            byte_error = 1
                        } else {
                            bytes[++byte_len] = value
                        }
                    }
                }

                END {
                    if (byte_error || !validate_input()) {
                        exit
                    }
                    pos = 1
                    has_session = 0
                    safe_session = ""
                    stop_active = 0
                    if (parse_document()) {
                        printf "%d|%s|%d\n", has_session, safe_session, stop_active
                    }
                }
            '
    ) || return 1

    [ -n "$parsed" ] || return 1
    # The marker-safe alphabet excludes "|". Unlike whitespace IFS, this
    # delimiter preserves the empty middle field in "0||0" and "0||1".
    IFS='|' read -r DEVLOG_HAS_SESSION DEVLOG_SESSION_ID DEVLOG_STOP_ACTIVE <<<"$parsed"
    [ "$DEVLOG_HAS_SESSION" = "0" ] || [ "$DEVLOG_HAS_SESSION" = "1" ] || return 1
    [ "$DEVLOG_STOP_ACTIVE" = "0" ] || [ "$DEVLOG_STOP_ACTIVE" = "1" ] || return 1
    return 0
}

# Encode accepted ASCII identities into a case-insensitive-filesystem-safe key.
# The `~sid-` namespace cannot collide with the former raw/sanitized marker
# scheme because `~` was outside the accepted alphabet and was replaced there.
devlog_marker_name() {
    local value=$1 index=0 character code encoded=

    [ ${#value} -ge 1 ] && [ ${#value} -le 64 ] || return 1
    while [ "$index" -lt "${#value}" ]; do
        character=${value:$index:1}
        case $character in
            [A-Za-z0-9_.-]) ;;
            *) return 1 ;;
        esac
        LC_ALL=C printf -v code '%02x' "'$character" || return 1
        encoded=$encoded$code
        index=$((index + 1))
    done
    DEVLOG_MARKER_NAME="~sid-${encoded}.start"
    return 0
}

# Resolve the single configuration root without trimming or re-encoding it.
# A whitespace-only override follows the PowerShell implementation and falls
# back to DEFAULT_DEVLOG_DIR, then HOME/claude-devlog.
devlog_resolve_root() {
    local candidate=${CLAUDE_DEVLOG_DIR-}
    if [ -z "${candidate//[[:space:]]/}" ]; then
        candidate=${DEFAULT_DEVLOG_DIR-}
    fi
    if [ -z "${candidate//[[:space:]]/}" ]; then
        [ -n "${HOME-}" ] || return 1
        candidate=$HOME/claude-devlog
    fi

    # Environment variables can contain non-UTF-8 bytes on POSIX. Reject such
    # a root before any marker/journal mutation or JSON output is attempted.
    if ! (
        set -o pipefail
        printf '%s' "$candidate" | LC_ALL=C iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
    ); then
        return 1
    fi
    DEVLOG_ROOT=$candidate
    return 0
}

devlog_resolve_lang() {
    case ${CLAUDE_DEVLOG_LANG-} in
        ja | en) DEVLOG_LANG=$CLAUDE_DEVLOG_LANG ;;
        *) DEVLOG_LANG=${DEFAULT_LANG:-ja} ;;
    esac
    case $DEVLOG_LANG in
        ja | en) ;;
        *) DEVLOG_LANG=ja ;;
    esac
}

# JSON strings require quotes, backslashes, and every C0 control byte to be
# escaped. Iterate in the C locale so UTF-8 bytes >= 0x20 pass through exactly
# while synthetic path controls become \u00xx. Bash variables cannot contain
# NUL, which is also forbidden in Unix environment variables and filenames.
devlog_json_escape() {
    local input=$1
    local index ch code escaped
    local LC_ALL=C

    DEVLOG_ESCAPED=
    index=0
    while [ "$index" -lt "${#input}" ]; do
        ch=${input:$index:1}
        case $ch in
            '"') DEVLOG_ESCAPED=$DEVLOG_ESCAPED'\"' ;;
            \\) DEVLOG_ESCAPED=$DEVLOG_ESCAPED'\\' ;;
            [[:cntrl:]])
                # Bash 3.2 sign-extends UTF-8 bytes passed to printf %d. Only
                # classify ASCII controls numerically so bytes 0x80-0xff keep
                # their original UTF-8 representation.
                printf -v code '%d' "'$ch"
                if [ "$code" -lt 32 ]; then
                    printf -v escaped '\\u%04x' "$code"
                    DEVLOG_ESCAPED=$DEVLOG_ESCAPED$escaped
                else
                    DEVLOG_ESCAPED=$DEVLOG_ESCAPED$ch
                fi
                ;;
            *) DEVLOG_ESCAPED=$DEVLOG_ESCAPED$ch ;;
        esac
        index=$((index + 1))
    done
}

devlog_now_epoch() {
    DEVLOG_NOW=$(date -u +%s 2>/dev/null) || return 1
    devlog_is_epoch "$DEVLOG_NOW"
}

devlog_today() {
    DEVLOG_TODAY=$(date +%Y-%m-%d 2>/dev/null) || return 1
    case $DEVLOG_TODAY in
        ????-??-??) return 0 ;;
        *) return 1 ;;
    esac
}

devlog_is_epoch() {
    local value=$1
    case $value in
        '' | *[!0-9]*) return 1 ;;
    esac
    # Stay comfortably inside signed 64-bit arithmetic. Current epoch values
    # are ten digits; larger inputs are unjudgeable and therefore fail open.
    [ "${#value}" -le 18 ]
}

# GNU stat (Linux) and BSD stat (macOS) use different format flags.
devlog_file_mtime() {
    local path=$1
    local value

    value=$(stat -c %Y "$path" 2>/dev/null)
    if ! devlog_is_epoch "$value"; then
        value=$(stat -f %m "$path" 2>/dev/null) || return 1
    fi
    devlog_is_epoch "$value" || return 1
    DEVLOG_MTIME=$value
    return 0
}

devlog_file_size() {
    local path=$1
    local value

    value=$(stat -c %s "$path" 2>/dev/null)
    case $value in
        '' | *[!0-9]*) value=$(stat -f %z "$path" 2>/dev/null) || return 1 ;;
    esac
    case $value in
        '' | *[!0-9]*) return 1 ;;
    esac
    DEVLOG_FILE_SIZE=$value
    return 0
}

devlog_read_marker() {
    local marker_path=$1
    local value size_before
    local LC_ALL=C

    [ -f "$marker_path" ] || return 1
    devlog_file_size "$marker_path" || return 1
    size_before=$DEVLOG_FILE_SIZE
    [ "$size_before" -ge 1 ] && [ "$size_before" -le 18 ] || return 1

    # Read no more than max+1 bytes and verify the file did not change size
    # around the read. Command substitution strips newlines, so the byte-count
    # equality also rejects newline-terminated marker content.
    value=$(head -c 19 "$marker_path" 2>/dev/null) || return 1
    devlog_file_size "$marker_path" || return 1
    [ "$DEVLOG_FILE_SIZE" = "$size_before" ] || return 1
    [ "${#value}" -eq "$size_before" ] || return 1
    devlog_is_epoch "$value" || return 1
    [ "${#value}" -eq 1 ] || [ "${value#0}" = "$value" ] || return 1
    DEVLOG_MARKER_EPOCH=$value
    return 0
}

devlog_prune_markers() {
    local marker_dir=$1
    local now=$2
    local retention_days=$3
    local cutoff marker_path

    devlog_is_epoch "$now" || return 1
    case $retention_days in
        '' | *[!0-9]*) return 1 ;;
    esac
    cutoff=$((now - retention_days * 86400))

    for marker_path in "$marker_dir"/*.start; do
        [ -f "$marker_path" ] || continue
        if devlog_file_mtime "$marker_path" && [ "$DEVLOG_MTIME" -lt "$cutoff" ]; then
            rm -f "$marker_path" 2>/dev/null || :
        fi
    done
    return 0
}
