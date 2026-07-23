#!/usr/bin/env bash
#
# Stop hook for macOS/Linux: block at most until today's journal mtime reaches
# the session-start marker epoch. Only the JSON boolean stop_hook_active=true
# activates the loop guard; strings never do.

set +e
set +u
set +o pipefail 2>/dev/null || :

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) 2>/dev/null || exit 0
# shellcheck source=devlog-common.sh
. "$SCRIPT_DIR/devlog-common.sh" 2>/dev/null || exit 0

DEFAULT_DEVLOG_DIR=
DEFAULT_LANG=ja

main() {
    local raw_input marker_path daily mtime reason

    raw_input=$(cat) || return 0
    devlog_parse_input "$raw_input" || return 0

    # Claude Code sets a real JSON boolean when continuing from a prior Stop
    # block. Returning silently here prevents an infinite block loop.
    [ "$DEVLOG_STOP_ACTIVE" = "1" ] && return 0
    [ "$DEVLOG_HAS_SESSION" = "1" ] && [ -n "$DEVLOG_SESSION_ID" ] || return 0

    devlog_resolve_root || return 0
    devlog_resolve_lang

    # Missing/corrupt markers cannot establish session start, so fail open.
    marker_path=$DEVLOG_ROOT/.devlog-markers/$DEVLOG_SESSION_ID.start
    devlog_read_marker "$marker_path" || return 0

    devlog_today || return 0
    daily=$DEVLOG_ROOT/daily/$DEVLOG_TODAY.md
    mtime=0
    if [ -e "$daily" ]; then
        devlog_file_mtime "$daily" || return 0
        mtime=$DEVLOG_MTIME
    fi

    [ "$mtime" -ge "$DEVLOG_MARKER_EPOCH" ] && return 0

    if [ "$DEVLOG_LANG" = "en" ]; then
        reason="📓 Today's dev journal has not been updated this session. Before ending the turn, append this session's notes to:
$daily

Suggested format:
## Session (HH:MM) [one-line summary]
- **Done**: ...
- **Learned, stuck, solved**: ...
- **Next**: ...
- Links: [[topic-slug]] / #tag

- Write at a granularity your future self can search and reuse. Distill recurring, general lessons into topics/<slug>.md as well.
- For a genuinely trivial session, a single line \"Trivial: <gist>\" is fine.
- Never write secrets, tokens, or real user data. Once appended, ending the turn is fine."
    else
        reason="📓 開発ログが未記入です。ターンを終える前に、このセッションの内容を次のファイルへ追記してください:
$daily

推奨フォーマット:
## セッション(HH:MM) 〔1行要約〕
- **やったこと**: ...
- **学び・詰まり・解決**: ...
- **次回**: ...
- 関連: [[topic-slug]] ／ #tag

・後で検索・参照しやすい粒度で書く。再発・汎用の知見は topics/<slug>.md にも蒸留する。
・記録不要な軽微セッションなら一行「軽微: <要旨>」でも可。
・secret / token / 実データは書かない。追記したら通常どおり終了してOKです。"
    fi

    devlog_json_escape "$reason"
    printf '{"decision":"block","reason":"%s"}' "$DEVLOG_ESCAPED"
    return 0
}

main 2>/dev/null || :
exit 0
