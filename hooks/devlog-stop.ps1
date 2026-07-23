# Stop hook: if this session has not yet updated today's journal, block the
# end of the turn once and ask for an entry. "Updated this session" means the
# journal file's mtime is at or after the session start time recorded by the
# SessionStart hook (the enforce-once pattern).
#
# Stop fires at the end of EVERY turn, not once per session — the marker
# comparison is what turns "block every turn" into "block at most until the
# journal is written". stop_hook_active guards against infinite block loops.
#
# Design rules shared by all three hooks (rationale: docs/hook-engineering.md):
# - Fail-open AND fail-silent: any error or unjudgeable state means "allow,
#   say nothing on stderr" (always exit 0; cmdlet errors promoted below).
# - Output is written as raw UTF-8 bytes (prevents mojibake).
# - No Set-StrictMode: absent JSON properties must evaluate to $null.
# - Saved as UTF-8 with BOM for Windows PowerShell 5.1 compatibility.

# --- Configuration -----------------------------------------------------------
# Devlog root resolution order: CLAUDE_DEVLOG_DIR, then $DefaultDevlogDir
# (leave '' to use <home>/claude-devlog).
$DefaultDevlogDir = ''

# Message language: 'ja' or 'en'. Override with CLAUDE_DEVLOG_LANG.
$DefaultLang = 'ja'
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
    $raw = [Console]::In.ReadToEnd()
    $data = $null
    if ($raw) { try { $data = $raw | ConvertFrom-Json } catch { $data = $null } }

    # Already continuing because a Stop hook blocked: allow, to avoid loops.
    # Require the protocol's actual JSON boolean. PowerShell's loose equality
    # would otherwise coerce the defensive string "true" to $true and silently
    # suppress this session's enforce-once block.
    if ($data -and ($data.stop_hook_active -is [bool]) -and $data.stop_hook_active) { exit 0 }

    $sid = if ($data -and $data.session_id) { [string]$data.session_id } else { $null }
    if (-not $sid) { exit 0 }   # unknown session: allow

    $devlogDir = Resolve-DevlogRoot
    $lang = Resolve-MessageLang

    # No marker (hook installed mid-session, marker pruned, or SessionStart
    # never ran) means "cannot judge" - allow.
    $markerDir = Join-Path $devlogDir '.devlog-markers'
    $safeSid = ($sid -replace '[^A-Za-z0-9_.-]', '_')
    $markerPath = Join-Path $markerDir "$safeSid.start"
    if (-not (Test-Path -LiteralPath $markerPath)) { exit 0 }

    $startEpoch = 0
    try { $startEpoch = [int64]((Get-Content -LiteralPath $markerPath -Raw).Trim()) } catch { exit 0 }

    $today = Get-Date -Format 'yyyy-MM-dd'
    $daily = Join-Path (Join-Path $devlogDir 'daily') "$today.md"

    $mtime = 0
    if (Test-Path -LiteralPath $daily) {
        $dt = (Get-Item -LiteralPath $daily).LastWriteTimeUtc
        # Wrap the cast in parentheses: method binding is stronger than casts.
        $mtime = ([DateTimeOffset]$dt).ToUnixTimeSeconds()
    }

    if ($mtime -ge $startEpoch) { exit 0 }   # journal updated this session: allow

    # Not updated yet: block once with instructions.
    if ($lang -eq 'en') {
        $reason = @"
📓 Today's dev journal has not been updated this session. Before ending the turn, append this session's notes to:
$daily

Suggested format:
## Session (HH:MM) [one-line summary]
- **Done**: ...
- **Learned, stuck, solved**: ...
- **Next**: ...
- Links: [[topic-slug]] / #tag

- Write at a granularity your future self can search and reuse. Distill recurring, general lessons into topics/<slug>.md as well.
- For a genuinely trivial session, a single line "Trivial: <gist>" is fine.
- Never write secrets, tokens, or real user data. Once appended, ending the turn is fine.
"@
    } else {
        $reason = @"
📓 開発ログが未記入です。ターンを終える前に、このセッションの内容を次のファイルへ追記してください:
$daily

推奨フォーマット:
## セッション(HH:MM) 〔1行要約〕
- **やったこと**: ...
- **学び・詰まり・解決**: ...
- **次回**: ...
- 関連: [[topic-slug]] ／ #tag

・後で検索・参照しやすい粒度で書く。再発・汎用の知見は topics/<slug>.md にも蒸留する。
・記録不要な軽微セッションなら一行「軽微: <要旨>」でも可。
・secret / token / 実データは書かない。追記したら通常どおり終了してOKです。
"@
    }

    $out = @{ decision = 'block'; reason = $reason }
    Write-Utf8Stdout ($out | ConvertTo-Json -Depth 5 -Compress)
    exit 0
} catch {
    exit 0   # Fail-open: allow.
}
