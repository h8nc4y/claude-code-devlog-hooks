#!/usr/bin/env bash
#
# Shared, dependency-free helpers for the Bash hook implementations.
# The public hooks source this file and keep all failures fail-open and silent.
# Bash 3.2 compatibility is intentional so the scripts work with the system
# Bash shipped by older macOS releases as well as current Linux distributions.

# Parse only the top-level protocol fields used by these hooks. This compact
# parser avoids jq/Python/Node dependencies while still distinguishing the JSON
# boolean true from strings and ignoring same-named fields inside nested data.
# The session id is reduced directly to the marker filename alphabet; decoded
# control/unicode escapes become "_" because marker paths never need the
# original display value.
devlog_parse_input() {
    local raw_input=$1
    local parsed

    parsed=$(
        printf '%s' "$raw_input" |
            LC_ALL=C awk '
                function is_ws(ch) {
                    return ch == " " || ch == "\t" || ch == "\r" || ch == "\n"
                }

                function skip_ws() {
                    while (pos <= source_len && is_ws(substr(source, pos, 1))) {
                        pos++
                    }
                }

                function parse_string(    ch, escaped, hex, value) {
                    if (substr(source, pos, 1) != "\"") {
                        return 0
                    }
                    pos++
                    value = ""

                    while (pos <= source_len) {
                        ch = substr(source, pos, 1)
                        pos++

                        if (ch == "\"") {
                            parsed_string = value
                            return 1
                        }
                        if (ch == "\\") {
                            if (pos > source_len) {
                                return 0
                            }
                            escaped = substr(source, pos, 1)
                            pos++

                            if (escaped == "\"" || escaped == "\\" || escaped == "/") {
                                value = value escaped
                            } else if (escaped == "b" || escaped == "f" || escaped == "n" ||
                                       escaped == "r" || escaped == "t") {
                                value = value "_"
                            } else if (escaped == "u") {
                                hex = substr(source, pos, 4)
                                if (length(hex) != 4 || hex ~ /[^0-9A-Fa-f]/) {
                                    return 0
                                }
                                pos += 4
                                value = value "_"
                            } else {
                                return 0
                            }
                        } else {
                            # JSON strings cannot carry literal C0 controls.
                            if (ch ~ /[[:cntrl:]]/) {
                                return 0
                            }
                            value = value ch
                        }
                    }
                    return 0
                }

                function parse_primitive(    start, ch, token) {
                    start = pos
                    while (pos <= source_len) {
                        ch = substr(source, pos, 1)
                        if (is_ws(ch) || ch == "," || ch == "}" || ch == "]") {
                            break
                        }
                        pos++
                    }
                    token = substr(source, start, pos - start)
                    if (token == "true" || token == "false" || token == "null" ||
                        token ~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) {
                        parsed_primitive = token
                        return 1
                    }
                    return 0
                }

                function sanitize_session(value,    i, ch, safe) {
                    safe = ""
                    for (i = 1; i <= length(value); i++) {
                        ch = substr(value, i, 1)
                        safe = safe (ch ~ /^[A-Za-z0-9_.-]$/ ? ch : "_")
                    }
                    return safe
                }

                function parse_value(    ch, ok) {
                    skip_ws()
                    ch = substr(source, pos, 1)

                    if (ch == "\"") {
                        ok = parse_string()
                        if (ok) {
                            parsed_type = "string"
                            parsed_value = parsed_string
                        }
                        return ok
                    }
                    if (ch == "{") {
                        ok = parse_object(0)
                        if (ok) {
                            parsed_type = "object"
                            parsed_value = ""
                        }
                        return ok
                    }
                    if (ch == "[") {
                        ok = parse_array()
                        if (ok) {
                            parsed_type = "array"
                            parsed_value = ""
                        }
                        return ok
                    }
                    if (!parse_primitive()) {
                        return 0
                    }

                    parsed_value = parsed_primitive
                    if (parsed_value == "true" || parsed_value == "false") {
                        parsed_type = "boolean"
                    } else if (parsed_value == "null") {
                        parsed_type = "null"
                    } else {
                        parsed_type = "number"
                    }
                    return 1
                }

                function parse_array(    ch) {
                    if (substr(source, pos, 1) != "[") {
                        return 0
                    }
                    pos++
                    skip_ws()

                    if (substr(source, pos, 1) == "]") {
                        pos++
                        return 1
                    }

                    while (pos <= source_len) {
                        if (!parse_value()) {
                            return 0
                        }
                        skip_ws()
                        ch = substr(source, pos, 1)
                        if (ch == ",") {
                            pos++
                            skip_ws()
                        } else if (ch == "]") {
                            pos++
                            return 1
                        } else {
                            return 0
                        }
                    }
                    return 0
                }

                function parse_object(capture_protocol,    key, ch, value_type, value) {
                    if (substr(source, pos, 1) != "{") {
                        return 0
                    }
                    pos++
                    skip_ws()

                    if (substr(source, pos, 1) == "}") {
                        pos++
                        return 1
                    }

                    while (pos <= source_len) {
                        if (!parse_string()) {
                            return 0
                        }
                        key = parsed_string
                        skip_ws()
                        if (substr(source, pos, 1) != ":") {
                            return 0
                        }
                        pos++

                        if (!parse_value()) {
                            return 0
                        }
                        value_type = parsed_type
                        value = parsed_value

                        if (capture_protocol) {
                            if (key == "session_id") {
                                if (value_type == "string") {
                                    has_session = 1
                                    safe_session = sanitize_session(value)
                                } else {
                                    has_session = 0
                                    safe_session = ""
                                }
                            } else if (key == "stop_hook_active") {
                                stop_active = (value_type == "boolean" && value == "true") ? 1 : 0
                            }
                        }

                        skip_ws()
                        ch = substr(source, pos, 1)
                        if (ch == ",") {
                            pos++
                            skip_ws()
                        } else if (ch == "}") {
                            pos++
                            return 1
                        } else {
                            return 0
                        }
                    }
                    return 0
                }

                function parse_document() {
                    skip_ws()
                    if (!parse_object(1)) {
                        return 0
                    }
                    skip_ws()
                    return pos > source_len
                }

                {
                    # Reinsert record separators so multi-line JSON remains
                    # parseable while literal newlines inside strings fail.
                    source = source $0 "\n"
                }

                END {
                    source_len = length(source)
                    pos = 1
                    has_session = 0
                    safe_session = ""
                    stop_active = 0

                    if (parse_document()) {
                        printf "%d\t%s\t%d\n", has_session, safe_session, stop_active
                    }
                }
            '
    ) || return 1

    [ -n "$parsed" ] || return 1
    IFS=$'\t' read -r DEVLOG_HAS_SESSION DEVLOG_SESSION_ID DEVLOG_STOP_ACTIVE <<<"$parsed"
    [ "$DEVLOG_HAS_SESSION" = "0" ] || [ "$DEVLOG_HAS_SESSION" = "1" ] || return 1
    [ "$DEVLOG_STOP_ACTIVE" = "0" ] || [ "$DEVLOG_STOP_ACTIVE" = "1" ] || return 1
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
            *)
                printf -v code '%d' "'$ch"
                if [ "$code" -lt 32 ]; then
                    printf -v escaped '\\u%04x' "$code"
                    DEVLOG_ESCAPED=$DEVLOG_ESCAPED$escaped
                else
                    DEVLOG_ESCAPED=$DEVLOG_ESCAPED$ch
                fi
                ;;
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

devlog_read_marker() {
    local marker_path=$1
    local value

    [ -f "$marker_path" ] || return 1
    value=$(cat "$marker_path" 2>/dev/null) || return 1
    devlog_is_epoch "$value" || return 1
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
