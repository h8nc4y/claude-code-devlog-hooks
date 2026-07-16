# SessionStart hook: inject the dev-journal routine into the session context
# and record the session start time as a marker file. The marker is what lets
# the companion Stop hook enforce "one journal update per session" and the
# UserPromptSubmit hook time its nudges.
#
# Design rules shared by all three hooks (rationale: docs/hook-engineering.md):
# - Fail-open: any error means "allow and stay silent" (try/catch around
#   everything, always exit 0). A journaling aid must never break a session.
# - Output is written as raw UTF-8 bytes so non-ASCII text survives regardless
#   of the console code page (prevents mojibake).
# - No Set-StrictMode: the logic relies on absent JSON properties evaluating
#   to $null. Under strict mode they would throw, hit the fail-open catch, and
#   silently disable the hook.
# - Saved as UTF-8 with BOM so Windows PowerShell 5.1 parses the non-ASCII
#   message text correctly; PowerShell 7 accepts the BOM as well.

# --- Configuration -----------------------------------------------------------
# One variable drives everything: the devlog root directory. Resolution order:
#   1. CLAUDE_DEVLOG_DIR environment variable (recommended)
#   2. $DefaultDevlogDir below
# Conventional layout under the root (see README.md):
#   daily/YYYY-MM-DD.md  - today's journal; written by the agent, never by hooks
#   topics/<slug>.md     - distilled evergreen notes; never touched by hooks
#   .devlog-markers/     - session-start markers written by this hook
$DefaultDevlogDir = Join-Path $HOME 'claude-devlog'

# Message language: 'ja' or 'en'. Override with CLAUDE_DEVLOG_LANG.
$DefaultLang = 'ja'

# Marker files older than this are deleted on each session start. SessionStart
# fires on startup/resume/compact, so markers accumulate without cleanup.
$MarkerRetentionDays = 7
# -----------------------------------------------------------------------------

function Write-Utf8Stdout([string]$s) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
    $stream = [Console]::OpenStandardOutput()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Resolve-DevlogRoot {
    $dir = [Environment]::GetEnvironmentVariable('CLAUDE_DEVLOG_DIR')
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $DefaultDevlogDir }
    return $dir
}

function Resolve-MessageLang {
    $lang = [Environment]::GetEnvironmentVariable('CLAUDE_DEVLOG_LANG')
    if ([string]::IsNullOrWhiteSpace($lang) -or ($lang -notin @('ja', 'en'))) { $lang = $DefaultLang }
    return $lang
}

try {
    $raw = [Console]::In.ReadToEnd()
    $data = $null
    if ($raw) { try { $data = $raw | ConvertFrom-Json } catch { $data = $null } }

    # SessionStart still runs with a placeholder id when the input is unusable:
    # injecting the routine is useful even if the marker cannot be per-session.
    $sid = if ($data -and $data.session_id) { [string]$data.session_id } else { 'unknown' }

    $devlogDir = Resolve-DevlogRoot
    $lang = Resolve-MessageLang

    $markerDir = Join-Path $devlogDir '.devlog-markers'
    if (-not (Test-Path -LiteralPath $markerDir)) {
        # -Force creates missing parents, including the devlog root on first run.
        New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
    }

    $safeSid = ($sid -replace '[^A-Za-z0-9_.-]', '_')
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Set-Content -LiteralPath (Join-Path $markerDir "$safeSid.start") -Value "$now" -NoNewline -Encoding ascii

    # Prune old markers so the directory does not grow forever.
    try {
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-$MarkerRetentionDays)
        Get-ChildItem -LiteralPath $markerDir -Filter '*.start' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }

    $today = Get-Date -Format 'yyyy-MM-dd'
    $daily = Join-Path (Join-Path $devlogDir 'daily') "$today.md"
    $topicsDir = Join-Path $devlogDir 'topics'

    if ($lang -eq 'en') {
        $ctx = @"
📓 Dev journal routine (every session, little and often):
- Before starting, search $topicsDir for prior lessons. When stuck, look there first.
- Append to today's journal: $daily. Do not save it up for the end — add one item each time you learn something, resolve a problem, decide a direction, or reach a good stopping point.
- Ending a turn without updating today's journal makes the Stop hook block once (it stays silent once the journal is updated). If the journal stays stale for long, the UserPromptSubmit hook nudges without blocking.
- Format: "## Session (HH:MM) [one-line summary]" with bullets **Done** / **Learned, stuck, solved** / **Next** / Links: [[topic]] / #tag. Appending bullets under an existing session heading is fine.
- Distill recurring, general lessons into topics/<slug>.md and connect them with [[wikilinks]]. Never write secrets, tokens, or real user data.
"@
    } else {
        $ctx = @"
📓 開発ログ運用（毎セッション・こまめに何度でも）:
- 着手前に $topicsDir を検索し、過去の轍を確認する。困ったらまずここ。
- 当日ログ $daily に追記する。最後にまとめてではなく、学びを得た / 詰まりを解決した / 方針が決まった / 区切りがついた、のたびに1項目ずつ追記する。
- 未追記のままターンを終えると Stop hook が一度だけブロックします（追記済みなら邪魔しません）。長く未更新だと UserPromptSubmit hook が非ブロックでそっと追記を促します。
- 形式: 「## セッション(HH:MM) 〔1行要約〕 / **やったこと** / **学び・詰まり・解決** / **次回** / 関連 [[topic]]・#tag」。既存セッション見出しへの箇条書き追記でも可。
- 再発・汎用の知見は topics/<slug>.md に蒸留し [[wikilink]] で繋ぐ。secret / token / 実データは書かない。
"@
    }

    $out = @{
        hookSpecificOutput = @{
            hookEventName     = 'SessionStart'
            additionalContext = $ctx
        }
    }
    Write-Utf8Stdout ($out | ConvertTo-Json -Depth 5 -Compress)
} catch {
    # Fail-open: stay silent.
}
exit 0
