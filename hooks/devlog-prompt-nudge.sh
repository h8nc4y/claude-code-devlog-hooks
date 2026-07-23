#!/usr/bin/env bash
#
# UserPromptSubmit hook for macOS/Linux: inject a non-blocking reminder only
# when both the session-age and journal-staleness gates reach 20 minutes.

set +e
set +u
set +o pipefail 2>/dev/null || :

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) 2>/dev/null || exit 0
# shellcheck source=devlog-common.sh
. "$SCRIPT_DIR/devlog-common.sh" 2>/dev/null || exit 0

DEFAULT_DEVLOG_DIR=
DEFAULT_LANG=ja
THRESHOLD_SEC=1200

main() {
    local raw_input marker_path daily minutes message

    raw_input=$(cat) || return 0
    devlog_parse_input "$raw_input" || return 0
    [ "$DEVLOG_HAS_SESSION" = "1" ] && [ -n "$DEVLOG_SESSION_ID" ] || return 0

    devlog_resolve_root || return 0
    devlog_resolve_lang
    devlog_now_epoch || return 0

    # Gate 1: an absent, unreadable, corrupt, or young marker is unjudgeable
    # or too early, so the high-frequency hook remains silent.
    marker_path=$DEVLOG_ROOT/.devlog-markers/$DEVLOG_SESSION_ID.start
    devlog_read_marker "$marker_path" || return 0
    [ $((DEVLOG_NOW - DEVLOG_MARKER_EPOCH)) -ge "$THRESHOLD_SEC" ] || return 0

    # Gate 2: a missing journal is stale; an existing journal must have a
    # portable GNU/BSD stat mtime old enough to justify the reminder.
    devlog_today || return 0
    daily=$DEVLOG_ROOT/daily/$DEVLOG_TODAY.md
    if [ -e "$daily" ]; then
        devlog_file_mtime "$daily" || return 0
        [ $((DEVLOG_NOW - DEVLOG_MTIME)) -ge "$THRESHOLD_SEC" ] || return 0
    fi

    minutes=$((THRESHOLD_SEC / 60))
    if [ "$DEVLOG_LANG" = "en" ]; then
        message="📝 Dev journal nudge: $daily has not been updated for ~${minutes} min. If you learned something, resolved a problem, decided a direction, or reached a milestone, append one item now (little and often — do not batch it up at the end). If there is truly nothing to record, ignore this."
    else
        message="📝 開発ログ追記の合図: 直近~${minutes}分 $daily が未更新です。学んだこと・解決した詰まり・決まった方針・区切りがあれば、いま1項目だけ追記してください（最後にまとめずその都度）。本当に何も無ければスルーでOK。"
    fi

    devlog_json_escape "$message"
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}' "$DEVLOG_ESCAPED"
    return 0
}

main 2>/dev/null || :
exit 0
