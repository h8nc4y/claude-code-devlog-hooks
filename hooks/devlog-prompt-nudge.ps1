# UserPromptSubmit hook: if the session has been running for a while and
# today's journal has gone stale, gently ask for one journal item — without
# blocking. Silent in every other case.
#
# The double gate keeps this from becoming a nag:
#   Gate 1: the session is at least $ThresholdSec old (marker written by the
#           SessionStart hook). Fresh sessions are never nudged — SessionStart
#           has already injected the routine.
#   Gate 2: today's journal has not been modified for at least $ThresholdSec.
# Only when both gates pass does the hook inject a nudge via
# hookSpecificOutput.additionalContext (UserPromptSubmit never blocks here).
#
# Design rules shared by all three hooks (rationale: docs/hook-engineering.md):
# - Fail-open: any error means "allow and stay silent" (always exit 0).
# - Output is written as raw UTF-8 bytes (prevents mojibake).
# - No Set-StrictMode: absent JSON properties must evaluate to $null.
# - Saved as UTF-8 with BOM for Windows PowerShell 5.1 compatibility.

# --- Configuration -----------------------------------------------------------
# Devlog root resolution order: CLAUDE_DEVLOG_DIR, then $DefaultDevlogDir.
$DefaultDevlogDir = Join-Path $HOME 'claude-devlog'

# Message language: 'ja' or 'en'. Override with CLAUDE_DEVLOG_LANG.
$DefaultLang = 'ja'

# Both gates use this threshold. Lower = chattier, higher = quieter.
$ThresholdSec = 1200   # 20 minutes
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
    $sid = if ($data -and $data.session_id) { [string]$data.session_id } else { $null }
    if (-not $sid) { exit 0 }

    $devlogDir = Resolve-DevlogRoot
    $lang = Resolve-MessageLang
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # Gate 1: session age. No marker (hook installed mid-session, marker
    # pruned, or SessionStart never ran) means "cannot judge" - stay silent.
    $markerDir = Join-Path $devlogDir '.devlog-markers'
    $safeSid = ($sid -replace '[^A-Za-z0-9_.-]', '_')
    $markerPath = Join-Path $markerDir "$safeSid.start"
    if (-not (Test-Path -LiteralPath $markerPath)) { exit 0 }
    $startEpoch = 0
    try { $startEpoch = [int64]((Get-Content -LiteralPath $markerPath -Raw).Trim()) } catch { exit 0 }
    if (($now - $startEpoch) -lt $ThresholdSec) { exit 0 }   # session too young

    # Gate 2: journal staleness. A recently touched journal means no nudge.
    # A missing journal file counts as stale.
    $today = Get-Date -Format 'yyyy-MM-dd'
    $daily = Join-Path (Join-Path $devlogDir 'daily') "$today.md"
    if (Test-Path -LiteralPath $daily) {
        $dt = (Get-Item -LiteralPath $daily).LastWriteTimeUtc
        # Wrap the cast in parentheses: method binding is stronger than casts.
        $mtime = ([DateTimeOffset]$dt).ToUnixTimeSeconds()
        if (($now - $mtime) -lt $ThresholdSec) { exit 0 }    # recently updated
    }

    $mins = [math]::Round($ThresholdSec / 60)
    if ($lang -eq 'en') {
        $msg = "📝 Dev journal nudge: $daily has not been updated for ~${mins} min. If you learned something, resolved a problem, decided a direction, or reached a milestone, append one item now (little and often — do not batch it up at the end). If there is truly nothing to record, ignore this."
    } else {
        $msg = "📝 開発ログ追記の合図: 直近~${mins}分 $daily が未更新です。学んだこと・解決した詰まり・決まった方針・区切りがあれば、いま1項目だけ追記してください（最後にまとめずその都度）。本当に何も無ければスルーでOK。"
    }

    $out = @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $msg } }
    Write-Utf8Stdout ($out | ConvertTo-Json -Depth 5 -Compress)
} catch {
    # Fail-open: stay silent.
}
exit 0
