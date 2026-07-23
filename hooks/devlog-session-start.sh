#!/usr/bin/env bash
#
# SessionStart hook for macOS/Linux: inject the dev-journal routine and write
# the epoch marker consumed by the nudge and Stop hooks.
#
# Contract:
# - Fail-open and fail-silent: every error still exits 0 with no stderr.
# - Structured output is emitted with Bash printf as raw UTF-8 bytes.
# - One devlog root variable drives daily/, topics/, and .devlog-markers/.

set +e
set +u
set +o pipefail 2>/dev/null || :

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) 2>/dev/null || exit 0
# shellcheck source=devlog-common.sh
. "$SCRIPT_DIR/devlog-common.sh" 2>/dev/null || exit 0

DEFAULT_DEVLOG_DIR=
DEFAULT_LANG=ja
MARKER_RETENTION_DAYS=7

main() {
    local raw_input safe_session marker_dir marker_path enforcement_on
    local daily topics_dir context

    raw_input=$(cat) || raw_input=
    if ! devlog_parse_input "$raw_input"; then
        DEVLOG_HAS_SESSION=0
        DEVLOG_SESSION_ID=
        DEVLOG_STOP_ACTIVE=0
    fi

    safe_session=$DEVLOG_SESSION_ID
    [ "$DEVLOG_HAS_SESSION" = "1" ] && [ -n "$safe_session" ] || safe_session=unknown

    devlog_resolve_root || return 0
    devlog_resolve_lang
    devlog_now_epoch || return 0
    devlog_today || return 0

    marker_dir=$DEVLOG_ROOT/.devlog-markers
    marker_path=$marker_dir/$safe_session.start
    enforcement_on=1

    # Marker failure disarms the later layers, so continue with context but
    # disclose the degraded enforcement in the same structured response.
    if mkdir -p "$marker_dir" 2>/dev/null &&
        printf '%s' "$DEVLOG_NOW" >"$marker_path" 2>/dev/null; then
        :
    else
        enforcement_on=0
    fi

    # Pruning is best-effort and must never suppress the useful context.
    devlog_prune_markers "$marker_dir" "$DEVLOG_NOW" "$MARKER_RETENTION_DAYS" || :

    daily=$DEVLOG_ROOT/daily/$DEVLOG_TODAY.md
    topics_dir=$DEVLOG_ROOT/topics

    if [ "$DEVLOG_LANG" = "en" ]; then
        context="📓 Dev journal routine (every session, little and often):
- Before starting, search $topics_dir for prior lessons. When stuck, look there first.
- Append to today's journal: $daily. Do not save it up for the end — add one item each time you learn something, resolve a problem, decide a direction, or reach a good stopping point.
- Ending a turn without updating today's journal makes the Stop hook block once (it stays silent once the journal is updated). If the journal stays stale for long, the UserPromptSubmit hook nudges without blocking.
- Format: \"## Session (HH:MM) [one-line summary]\" with bullets **Done** / **Learned, stuck, solved** / **Next** / Links: [[topic]] / #tag. Appending bullets under an existing session heading is fine.
- Distill recurring, general lessons into topics/<slug>.md and connect them with [[wikilinks]]. Never write secrets, tokens, or real user data."
    else
        context="📓 開発ログ運用（毎セッション・こまめに何度でも）:
- 着手前に $topics_dir を検索し、過去の轍を確認する。困ったらまずここ。
- 当日ログ $daily に追記する。最後にまとめてではなく、学びを得た / 詰まりを解決した / 方針が決まった / 区切りがついた、のたびに1項目ずつ追記する。
- 未追記のままターンを終えると Stop hook が一度だけブロックします（追記済みなら邪魔しません）。長く未更新だと UserPromptSubmit hook が非ブロックでそっと追記を促します。
- 形式: 「## セッション(HH:MM) 〔1行要約〕 / **やったこと** / **学び・詰まり・解決** / **次回** / 関連 [[topic]]・#tag」。既存セッション見出しへの箇条書き追記でも可。
- 再発・汎用の知見は topics/<slug>.md に蒸留し [[wikilink]] で繋ぐ。secret / token / 実データは書かない。"
    fi

    if [ "$enforcement_on" -ne 1 ]; then
        if [ "$DEVLOG_LANG" = "en" ]; then
            context="$context
⚠ Could not write the session marker under $marker_dir — the Stop-hook enforcement and staleness nudges are OFF for this session. Check that CLAUDE_DEVLOG_DIR points to a writable directory."
        else
            context="$context
⚠ セッションマーカーを $marker_dir に書き込めなかったため、このセッションでは Stop hook の強制と催促は無効です。CLAUDE_DEVLOG_DIR が書き込み可能なディレクトリを指しているか確認してください。"
        fi
    fi

    devlog_json_escape "$context"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$DEVLOG_ESCAPED"
    return 0
}

main 2>/dev/null || :
exit 0
