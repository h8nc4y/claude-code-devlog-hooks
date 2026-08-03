# SessionStart hook: inject the dev-journal routine into the session context
# and record the session start time as a marker file. The marker is what lets
# the companion Stop hook enforce "one journal update per session" and the
# UserPromptSubmit hook time its nudges.
#
# Design rules shared by all three hooks (rationale: docs/hook-engineering.md):
# - Fail-open AND fail-silent: any error means "allow, say nothing on stderr"
#   (try/catch around everything, cmdlet errors promoted to terminating,
#   always exit 0). A journaling aid must never break or clutter a session.
# - Output is written as raw UTF-8 bytes so non-ASCII text survives regardless
#   of the console code page (prevents mojibake).
# - Protocol input is parsed by the sibling shared helper, which enforces one
#   object root, unique property names, and ordinal exact field names.
# - Saved as UTF-8 with BOM so Windows PowerShell 5.1 parses the non-ASCII
#   message text correctly; PowerShell 7 accepts the BOM as well.

# --- Configuration -----------------------------------------------------------
# One variable drives everything: the devlog root directory. Resolution order:
#   1. CLAUDE_DEVLOG_DIR environment variable (recommended)
#   2. $DefaultDevlogDir below (leave '' to use <home>/claude-devlog)
# Conventional layout under the root (see README.md):
#   daily/YYYY-MM-DD.md  - today's journal; written by the agent, never by hooks
#   topics/<slug>.md     - distilled evergreen notes; never touched by hooks
#   .devlog-markers/     - session-start markers written by this hook
$DefaultDevlogDir = ''

# Message language: 'ja' or 'en'. Override with CLAUDE_DEVLOG_LANG.
$DefaultLang = 'ja'

# Marker files older than this are deleted on each session start. SessionStart
# fires on startup/resume/clear/compact, so markers accumulate without cleanup.
$MarkerRetentionDays = 7
# -----------------------------------------------------------------------------

# Cmdlet errors are NON-terminating by default: they bypass try/catch, print
# to stderr, and continue — which breaks the fail-silent contract. Promote
# them to terminating so the catch blocks below decide quietly instead.
$ErrorActionPreference = 'Stop'

function Write-Utf8Stdout([string]$s) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
    $stream = [Console]::OpenStandardOutput()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Resolve-DevlogRoot {
    $dir = [Environment]::GetEnvironmentVariable('CLAUDE_DEVLOG_DIR')
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $DefaultDevlogDir }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path $HOME 'claude-devlog' }
    return $dir
}

function Resolve-MessageLang {
    $lang = [Environment]::GetEnvironmentVariable('CLAUDE_DEVLOG_LANG')
    if ([string]::IsNullOrWhiteSpace($lang) -or ($lang -notin @('ja', 'en'))) { $lang = $DefaultLang }
    return $lang
}

try {
    . (Join-Path $PSScriptRoot 'devlog-common.ps1')
    $inputData = Read-DevlogHookInput

    # Establish identity only from the protocol's bounded marker-safe string.
    # Unjudgeable input still receives the routine, but must not create or
    # prune enforcement-looking marker state.
    $identityEstablished = [bool]($null -ne $inputData -and $inputData.HasSession)
    $sid = if ($identityEstablished) { [string]$inputData.SessionId } else { '' }

    $devlogDir = Resolve-DevlogRoot
    $lang = Resolve-MessageLang
    $markerDir = Join-Path $devlogDir '.devlog-markers'

    $enforcementOn = $false
    if ($identityEstablished) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        # Marker writes get their own catch: on an unwritable devlog root the
        # routine below is still worth injecting, but the user must be told
        # that enforcement is off.
        try {
            # A reversible hex key keeps exact identities distinct even on
            # Windows case-insensitive filesystems and for reserved basenames.
            $markerName = Get-DevlogMarkerFileName -SessionId $sid
            if ((Initialize-DevlogMarkerDirectory -Path $markerDir) -and
                (Write-DevlogMarkerEpoch -Path (Join-Path $markerDir $markerName) -Epoch $now)) {
                $enforcementOn = $true
            }
        } catch {
            $enforcementOn = $false
        }

        # Prune only after the current marker proves the namespace safe. Each
        # leaf is checked again so a reparse entry is never inspected/deleted.
        if ($enforcementOn) {
            try {
                $cutoff = (Get-Date).ToUniversalTime().AddDays(-$MarkerRetentionDays)
                if (Test-DevlogMarkerDirectory -Path $markerDir) {
                    Get-ChildItem -LiteralPath $markerDir -Filter '*.start' -File -Force -ErrorAction SilentlyContinue |
                        Where-Object {
                            (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -and
                            $_.LastWriteTimeUtc -lt $cutoff
                        } |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }

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

    if (-not $identityEstablished) {
        if ($lang -eq 'en') {
            $ctx += "`n" + "⚠ Session identity could not be established. Stop-hook enforcement and staleness nudges are OFF for this session."
        } else {
            $ctx += "`n" + "⚠ セッションIDを確立できないため、このセッションでは Stop hook の強制と催促は無効です。"
        }
    } elseif (-not $enforcementOn) {
        if ($lang -eq 'en') {
            $ctx += "`n" + "⚠ Could not write the session marker under $markerDir — the Stop-hook enforcement and staleness nudges are OFF for this session. Check that CLAUDE_DEVLOG_DIR points to a writable directory."
        } else {
            $ctx += "`n" + "⚠ セッションマーカーを $markerDir に書き込めなかったため、このセッションでは Stop hook の強制と催促は無効です。CLAUDE_DEVLOG_DIR が書き込み可能なディレクトリを指しているか確認してください。"
        }
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
