# Pipe-test harness for the three devlog hooks.
#
# Fail-open hooks swallow their own bugs: a broken hook exits 0 and looks
# exactly like a hook that decided to allow. Exit codes alone therefore prove
# nothing. Every case here checks output bytes (raw stdout captured through
# the Process API, because PowerShell redirection re-decodes and can mask
# encoding bugs) and side effects (marker files) as well.
#
# Each case runs against a throwaway devlog root under the system temp
# directory, selected via the CLAUDE_DEVLOG_DIR environment variable, so the
# suite never touches a real journal.
#
# Usage:
#   pwsh -NoProfile -File ./scripts/test-hooks.ps1
#   pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell powershell
#   pwsh -NoProfile -File ./scripts/test-hooks.ps1 -HookShell bash
# -HookShell picks the shell that executes the hooks: 'pwsh', 'powershell',
# 'bash', or a full path. Default: pwsh if available, otherwise powershell.

[CmdletBinding()]
param(
    [string]$Path = '',
    [string]$HookShell = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}
$root = (Resolve-Path -LiteralPath $Path).Path

if ([string]::IsNullOrWhiteSpace($HookShell)) {
    $shellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -eq $shellCommand) {
        $shellCommand = Get-Command powershell -ErrorAction Stop
    }
} else {
    $shellCommand = Get-Command $HookShell -ErrorAction Stop
}
$shellPath = $shellCommand.Source
$shellLeaf = [System.IO.Path]::GetFileName($shellPath)
$isBashHook = ($shellLeaf -match '^(?i:bash)(?:\.exe)?$')
$isWslBash = ($shellPath -match '(?i)[\\/]Windows[\\/]System32[\\/]bash\.exe$')
$hookExtension = if ($isBashHook) { '.sh' } else { '.ps1' }

$hookSessionStart = Join-Path $root ('hooks/devlog-session-start' + $hookExtension)
$hookNudge = Join-Path $root ('hooks/devlog-prompt-nudge' + $hookExtension)
$hookStop = Join-Path $root ('hooks/devlog-stop' + $hookExtension)
$requiredHooks = @($hookSessionStart, $hookNudge, $hookStop)
if ($isBashHook) {
    $requiredHooks += (Join-Path $root 'hooks/devlog-common.sh')
}
foreach ($hook in $requiredHooks) {
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
        throw "Missing hook script: $hook"
    }
}

# Report the exact shell under test; PS 5.1 vs 7 differences matter here.
# Scope ErrorActionPreference down for the probe: Windows PowerShell 5.1
# turns redirected native stderr into terminating errors under 'Stop'.
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    if ($isBashHook) {
        $shellVersion = (& $shellPath --version 2>$null | Select-Object -First 1 | Out-String).Trim()
    } else {
        $shellVersion = (& $shellPath -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Out-String).Trim()
    }
} finally {
    $ErrorActionPreference = $previousEap
}
$shellFamily = if ($isBashHook) { 'Bash' } else { 'PowerShell' }
Write-Host "Testing hooks with: $shellPath ($shellFamily $shellVersion)"

# Japanese assertion needle, kept as escapes so this file stays ASCII-only
# (an ASCII-only .ps1 parses identically under PS 5.1 and 7, BOM or not).
$jaNeedle = [regex]::Unescape('\u958b\u767a\u30ed\u30b0')   # kanji for "dev log"

function Get-NowEpoch {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

$hookPathCache = @{}
function ConvertTo-HookPath {
    # Git Bash and WSL receive native Windows paths from this PowerShell
    # harness. Convert only the synthetic devlog root; hook script paths stay
    # relative to the repository working directory.
    param([Parameter(Mandatory = $true)][string]$NativePath)

    if (-not $isBashHook -or $env:OS -ne 'Windows_NT') {
        return $NativePath
    }
    if ($hookPathCache.ContainsKey($NativePath)) {
        return [string]$hookPathCache[$NativePath]
    }

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($isWslBash) {
            # The legacy WSL bash.exe wrapper drops positional parameters
            # following `-c`; call wslpath through wsl.exe instead.
            $converted = (& wsl.exe -e wslpath -u $NativePath 2>$null | Out-String).Trim()
        } else {
            # Git for Windows ships cygpath beside its Bash runtime.
            $gitRoot = Split-Path -Parent (Split-Path -Parent $shellPath)
            $cygpath = Join-Path $gitRoot 'usr/bin/cygpath.exe'
            if (-not (Test-Path -LiteralPath $cygpath -PathType Leaf)) {
                throw "Could not locate cygpath beside Bash: $shellPath"
            }
            $converted = (& $cygpath -u $NativePath 2>$null | Out-String).Trim()
        }
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) {
            throw "Could not convert a Windows fixture path for Bash: $NativePath"
        }
    } finally {
        $ErrorActionPreference = $previousEap
    }

    $hookPathCache[$NativePath] = $converted
    return $converted
}

function Invoke-Hook {
    param(
        [Parameter(Mandatory = $true)][string]$HookPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StdinText,
        [Parameter(Mandatory = $true)][hashtable]$ChildEnvironment
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $shellPath
    if ($isBashHook) {
        # A relative path avoids MSYS/WSL drive-path ambiguity while the
        # working directory keeps source-relative helper loading stable.
        $hookName = [System.IO.Path]::GetFileName($HookPath)
        $psi.Arguments = '--noprofile --norc "hooks/' + $hookName + '"'
        $psi.WorkingDirectory = $root
    } else {
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # Deterministic child environment: strip ambient devlog variables first,
    # then apply exactly what the case asked for.
    foreach ($name in @('CLAUDE_DEVLOG_DIR', 'CLAUDE_DEVLOG_LANG')) {
        if ($psi.EnvironmentVariables.ContainsKey($name)) {
            $psi.EnvironmentVariables.Remove($name)
        }
    }
    foreach ($key in $ChildEnvironment.Keys) {
        $value = [string]$ChildEnvironment[$key]
        if ($isBashHook -and $key -eq 'CLAUDE_DEVLOG_DIR') {
            $value = ConvertTo-HookPath -NativePath $value
        }
        $psi.EnvironmentVariables[$key] = $value
    }
    if ($isWslBash) {
        # WSL imports opt-in Windows variables through WSLENV. Values are
        # already converted above, so no /p translation flag is needed.
        $psi.EnvironmentVariables['WSLENV'] = 'CLAUDE_DEVLOG_DIR:CLAUDE_DEVLOG_LANG'
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdinBytes = [System.Text.Encoding]::UTF8.GetBytes($StdinText)
        $process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()

        # Drain stderr asynchronously while stdout is drained synchronously,
        # so neither pipe can fill up and deadlock the child.
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdoutBuffer = New-Object System.IO.MemoryStream
        $process.StandardOutput.BaseStream.CopyTo($stdoutBuffer)

        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch { }
            throw "Hook timed out after 30 seconds: $HookPath"
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdoutBytes = $stdoutBuffer.ToArray()
            Stderr = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function ConvertFrom-HookStdout {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if ($Bytes.Length -eq 0) {
        throw 'Assertion failed: expected JSON output but stdout was empty.'
    }
    # Structured hook output must be a bare JSON object with no BOM or prefix.
    if ($Bytes[0] -ne 0x7B) {
        throw ("Assertion failed: stdout does not start with '{{' (first byte: 0x{0:X2})." -f $Bytes[0])
    }
    # Strict decoder: throws on any invalid UTF-8 sequence.
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $text = $strictUtf8.GetString($Bytes)
    return ($text | ConvertFrom-Json)
}

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Allowed {
    # A silent allow is exit 0 with zero stdout bytes and empty stderr.
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Assert-Condition ($Result.ExitCode -eq 0) "$Label should exit 0 (got $($Result.ExitCode))."
    Assert-Condition ($Result.StdoutBytes.Length -eq 0) "$Label should produce no stdout (got $($Result.StdoutBytes.Length) bytes)."
    Assert-Condition ([string]::IsNullOrWhiteSpace($Result.Stderr)) "$Label should produce no stderr (got: $($Result.Stderr))."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-code-devlog-hooks-test-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

$caseCounter = 0
function New-CaseRoot {
    # Returns a fresh devlog root for one case. The root itself is created
    # unless -LeaveMissing is set (used to prove the hook creates it).
    param(
        [switch]$LeaveMissing,
        [switch]$WithMarkerDir
    )
    $script:caseCounter++
    $caseRoot = Join-Path $tempRoot ('case-' + $script:caseCounter)
    if (-not $LeaveMissing) {
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        if ($WithMarkerDir) {
            New-Item -ItemType Directory -Path (Join-Path $caseRoot '.devlog-markers') | Out-Null
        }
    }
    return $caseRoot
}

function Set-Marker {
    param(
        [Parameter(Mandatory = $true)][string]$DevlogRoot,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $markerDir = Join-Path $DevlogRoot '.devlog-markers'
    if (-not (Test-Path -LiteralPath $markerDir)) {
        New-Item -ItemType Directory -Path $markerDir | Out-Null
    }
    $markerPath = Join-Path $markerDir ($SessionId + '.start')
    Set-Content -LiteralPath $markerPath -Value $Content -NoNewline -Encoding ascii
    return $markerPath
}

function Set-DailyJournal {
    # Creates today's journal under the case root with the given mtime age.
    # NOTE: the date is computed at call time; a midnight rollover between
    # fixture setup and hook execution can skew a case (see README known
    # limitations - the hooks themselves share this property).
    param(
        [Parameter(Mandatory = $true)][string]$DevlogRoot,
        [Parameter(Mandatory = $true)][double]$AgeSeconds
    )
    $dailyDir = Join-Path $DevlogRoot 'daily'
    if (-not (Test-Path -LiteralPath $dailyDir)) {
        New-Item -ItemType Directory -Path $dailyDir | Out-Null
    }
    $today = Get-Date -Format 'yyyy-MM-dd'
    $daily = Join-Path $dailyDir ($today + '.md')
    Set-Content -LiteralPath $daily -Value '# synthetic journal fixture' -Encoding UTF8
    (Get-Item -LiteralPath $daily).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-$AgeSeconds)
    return $daily
}

function Get-ExpectedDailyPath {
    param([Parameter(Mandatory = $true)][string]$DevlogRoot)
    $today = Get-Date -Format 'yyyy-MM-dd'
    if ($isBashHook) {
        $hookRoot = ConvertTo-HookPath -NativePath $DevlogRoot
        return ($hookRoot.TrimEnd('/') + '/daily/' + $today + '.md')
    }
    return (Join-Path (Join-Path $DevlogRoot 'daily') ($today + '.md'))
}

$cases = New-Object System.Collections.Generic.List[object]
function Add-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $cases.Add([pscustomobject]@{ Name = $Name; Body = $Body }) | Out-Null
}

# --- SessionStart cases ------------------------------------------------------

Add-Case 'session-start-writes-marker-and-context' {
    $caseRoot = New-CaseRoot -LeaveMissing   # prove the hook creates the root
    $before = Get-NowEpoch
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":"alpha-1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    $after = Get-NowEpoch

    Assert-Condition ($result.ExitCode -eq 0) "SessionStart should exit 0 (got $($result.ExitCode))."
    Assert-Condition ([string]::IsNullOrWhiteSpace($result.Stderr)) "SessionStart should produce no stderr (got: $($result.Stderr))."

    $markerPath = Join-Path (Join-Path $caseRoot '.devlog-markers') 'alpha-1.start'
    Assert-Condition (Test-Path -LiteralPath $markerPath) 'SessionStart should create the session marker.'
    $epoch = [int64]((Get-Content -LiteralPath $markerPath -Raw).Trim())
    Assert-Condition ($epoch -ge ($before - 60) -and $epoch -le ($after + 60)) "Marker epoch $epoch should be near the current time."

    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.hookEventName -eq 'SessionStart') 'hookEventName should be SessionStart.'
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains($jaNeedle)) 'Default context should be Japanese.'
    $expectedDaily = Get-ExpectedDailyPath -DevlogRoot $caseRoot
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains($expectedDaily)) 'Context should name the daily journal path.'
}

Add-Case 'session-start-prunes-old-markers' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    $oldMarker = Set-Marker -DevlogRoot $caseRoot -SessionId 'stale-session' -Content '1000'
    (Get-Item -LiteralPath $oldMarker).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    $freshMarker = Set-Marker -DevlogRoot $caseRoot -SessionId 'fresh-session' -Content "$(Get-NowEpoch)"

    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":"beta-2"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-Condition ($result.ExitCode -eq 0) 'SessionStart should exit 0.'
    Assert-Condition (-not (Test-Path -LiteralPath $oldMarker)) 'Markers older than the retention window should be pruned.'
    Assert-Condition (Test-Path -LiteralPath $freshMarker) 'Recent markers should survive pruning.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path (Join-Path $caseRoot '.devlog-markers') 'beta-2.start')) 'The new session marker should exist.'
}

Add-Case 'session-start-sanitizes-session-id' {
    $caseRoot = New-CaseRoot
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":"we/ird:id"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Condition ($result.ExitCode -eq 0) 'SessionStart should exit 0.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path (Join-Path $caseRoot '.devlog-markers') 'we_ird_id.start')) 'Unsafe characters in session_id should be replaced for the marker filename.'
}

Add-Case 'session-start-no-session-id-uses-unknown' {
    $caseRoot = New-CaseRoot
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Condition ($result.ExitCode -eq 0) 'SessionStart should exit 0.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path (Join-Path $caseRoot '.devlog-markers') 'unknown.start')) 'Missing session_id should fall back to the unknown marker.'
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.hookEventName -eq 'SessionStart') 'Context should still be emitted without a session_id.'
}

Add-Case 'session-start-invalid-stdin-still-injects' {
    $caseRoot = New-CaseRoot
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText 'this is not json' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Condition ($result.ExitCode -eq 0) 'SessionStart should exit 0 on unparseable stdin.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path (Join-Path $caseRoot '.devlog-markers') 'unknown.start')) 'Unparseable stdin should degrade to the unknown marker.'
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Length -gt 0) 'Context should still be emitted on unparseable stdin.'
}

Add-Case 'session-start-en-language' {
    $caseRoot = New-CaseRoot
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":"lang-en"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot; CLAUDE_DEVLOG_LANG = 'en' }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains('Dev journal routine')) 'CLAUDE_DEVLOG_LANG=en should switch the context to English.'
    Assert-Condition (-not $json.hookSpecificOutput.additionalContext.Contains($jaNeedle)) 'English context should not contain the Japanese needle.'
}

# --- UserPromptSubmit (nudge) cases ------------------------------------------

Add-Case 'nudge-silent-on-young-session' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$(Get-NowEpoch)" | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge on a young session'
}

Add-Case 'nudge-silent-when-recently-updated' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    Set-DailyJournal -DevlogRoot $caseRoot -AgeSeconds 0 | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with a recently updated journal'
}

Add-Case 'nudge-fires-when-journal-missing' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Condition ($result.ExitCode -eq 0) 'Nudge should exit 0.'
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.hookEventName -eq 'UserPromptSubmit') 'hookEventName should be UserPromptSubmit.'
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains($jaNeedle)) 'Default nudge should be Japanese.'
    $expectedDaily = Get-ExpectedDailyPath -DevlogRoot $caseRoot
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains($expectedDaily)) 'Nudge should name the daily journal path.'
}

Add-Case 'nudge-fires-on-stale-journal' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    Set-DailyJournal -DevlogRoot $caseRoot -AgeSeconds 2000 | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.hookEventName -eq 'UserPromptSubmit') 'Nudge should fire when both gates pass.'
}

Add-Case 'nudge-silent-without-marker' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"no-marker"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge without a session marker'
}

Add-Case 'nudge-silent-without-session-id' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge without a session_id'
}

Add-Case 'nudge-silent-on-corrupt-marker' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content 'not-a-number' | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with a corrupt marker (fail-open)'
}

Add-Case 'nudge-en-language' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot; CLAUDE_DEVLOG_LANG = 'en' }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains('Dev journal nudge')) 'CLAUDE_DEVLOG_LANG=en should switch the nudge to English.'
}

# --- Stop cases ---------------------------------------------------------------

Add-Case 'stop-allows-when-stop-hook-active' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1","stop_hook_active":true}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with stop_hook_active (loop prevention)'
}

Add-Case 'stop-allows-without-session-id' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop without a session_id'
}

Add-Case 'stop-allows-without-marker' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"no-marker"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop without a session marker'
}

Add-Case 'stop-blocks-when-journal-stale' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Condition ($result.ExitCode -eq 0) 'Stop should exit 0 even when blocking.'
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.decision -eq 'block') 'Stop should block when the journal was not updated this session.'
    Assert-Condition ($json.reason.Contains($jaNeedle)) 'Default block reason should be Japanese.'
    $expectedDaily = Get-ExpectedDailyPath -DevlogRoot $caseRoot
    Assert-Condition ($json.reason.Contains($expectedDaily)) 'Block reason should name the daily journal path.'
}

Add-Case 'stop-blocks-when-journal-older-than-session' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 50)" | Out-Null
    Set-DailyJournal -DevlogRoot $caseRoot -AgeSeconds 3600 | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.decision -eq 'block') 'A journal last touched before session start should still block.'
}

Add-Case 'stop-allows-after-journal-update' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    Set-DailyJournal -DevlogRoot $caseRoot -AgeSeconds 0 | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop after the journal was updated this session'
}

Add-Case 'stop-allows-on-corrupt-marker' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content 'not-a-number' | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with a corrupt marker (fail-open)'
}

Add-Case 'stop-allows-on-invalid-stdin' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText 'this is not json' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with unparseable stdin (fail-open)'
}

Add-Case 'stop-allows-on-invalid-nested-json' {
    # The dependency-free Bash reader still validates nested JSON grammar.
    # A malformed ignored field must not turn otherwise invalid input into an
    # enforceable session.
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1","nested":[tru e]}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with malformed nested JSON (fail-open)'
}

Add-Case 'stop-en-language' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot; CLAUDE_DEVLOG_LANG = 'en' }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.decision -eq 'block') 'English Stop should still block.'
    Assert-Condition ($json.reason.Contains('dev journal')) 'CLAUDE_DEVLOG_LANG=en should switch the block reason to English.'
}

# --- Fail-silent regression cases ----------------------------------------------
# Non-terminating cmdlet errors bypass try/catch and leak to stderr unless the
# hooks promote them to terminating; these cases pin the fail-SILENT contract
# on write/read failures (found by adversarial review before v0.1.0).

Add-Case 'session-start-unwritable-root-warns-silently' {
    # A devlog root whose parent is a regular FILE cannot be created. The hook
    # must stay fail-silent (exit 0, no stderr), still inject the routine, and
    # disclose that enforcement is off for the session (warning sign in text).
    $caseRoot = New-CaseRoot
    $blocker = Join-Path $caseRoot 'blocker'
    Set-Content -LiteralPath $blocker -Value 'file in the way' -Encoding ascii
    $badRoot = Join-Path $blocker 'sub'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":"bad-root"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $badRoot }
    Assert-Condition ($result.ExitCode -eq 0) "SessionStart should exit 0 on an unwritable root (got $($result.ExitCode))."
    Assert-Condition ([string]::IsNullOrWhiteSpace($result.Stderr)) "SessionStart should keep stderr silent on an unwritable root (got: $($result.Stderr))."
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.hookEventName -eq 'SessionStart') 'Context should still be injected on an unwritable root.'
    $warningSign = [string][char]0x26A0   # the warning sign prefixes the disclosure line
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains($warningSign)) 'Context should disclose that enforcement is off.'
}

Add-Case 'stop-allows-on-directory-marker' {
    # A directory occupying the marker path makes the marker read fail; the
    # hook must allow with nothing on stdout OR stderr.
    $caseRoot = New-CaseRoot -WithMarkerDir
    New-Item -ItemType Directory -Path (Join-Path (Join-Path $caseRoot '.devlog-markers') 's1.start') | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with a directory where the marker should be'
}

Add-Case 'nudge-silent-on-directory-marker' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    New-Item -ItemType Directory -Path (Join-Path (Join-Path $caseRoot '.devlog-markers') 's1.start') | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with a directory where the marker should be'
}

Add-Case 'stop-blocks-when-stop-hook-active-is-string-false' {
    # The spec sends stop_hook_active as a boolean. A defensive string value
    # "false" must not be treated as truthy (which would skip enforcement).
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1","stop_hook_active":"false"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.decision -eq 'block') 'A non-boolean stop_hook_active value should not suppress the block.'
}

Add-Case 'stop-blocks-when-stop-hook-active-is-string-true' {
    # Only the JSON boolean true activates the loop guard. A string that
    # merely spells "true" must not weaken enforce-once behavior.
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1","stop_hook_active":"true"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.decision -eq 'block') 'A string stop_hook_active value should not suppress the block.'
}

Add-Case 'stop-blocks-when-stop-hook-active-is-nested-only' {
    # A text search for the field would confuse nested payload data with the
    # top-level protocol guard. Both implementations must inspect the root.
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1","nested":{"stop_hook_active":true}}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.decision -eq 'block') 'A nested stop_hook_active value should not suppress the block.'
}

# POSIX permits quote, backslash, and control characters in filenames (NUL
# and slash excepted). These synthetic Bash-only cases prove that hand-built
# JSON remains valid and round-trips the exact path without adding jq or
# exposing a real journal path. Windows cannot create these fixture names.
if ($isBashHook -and $env:OS -ne 'Windows_NT') {
    function New-SpecialPathCaseRoot {
        $script:caseCounter++
        $segment = 'json-"quote"-\backslash-' + [char]0x09 + 'tab-' + [char]0x0A + 'newline-' + [char]0x01 + 'control'
        $caseRoot = Join-Path $tempRoot ('case-' + $script:caseCounter + '-' + $segment)
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        return $caseRoot
    }

    Add-Case 'bash-session-start-json-escapes-special-path' {
        $caseRoot = New-SpecialPathCaseRoot
        $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":"json-session"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
        Assert-Condition ($result.ExitCode -eq 0) 'Bash SessionStart should exit 0 for a special-character path.'
        Assert-Condition ([string]::IsNullOrWhiteSpace($result.Stderr)) 'Bash SessionStart should keep stderr silent for a special-character path.'
        $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
        $expectedDaily = Get-ExpectedDailyPath -DevlogRoot $caseRoot
        Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains($expectedDaily)) 'SessionStart JSON should round-trip quote, backslash, and control characters in the path.'
        Assert-Condition (Test-Path -LiteralPath (Join-Path (Join-Path $caseRoot '.devlog-markers') 'json-session.start')) 'SessionStart should write its marker under the special-character path.'
    }

    Add-Case 'bash-nudge-json-escapes-special-path' {
        $caseRoot = New-SpecialPathCaseRoot
        Set-Marker -DevlogRoot $caseRoot -SessionId 'json-nudge' -Content "$((Get-NowEpoch) - 2000)" | Out-Null
        $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"json-nudge"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
        $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
        $expectedDaily = Get-ExpectedDailyPath -DevlogRoot $caseRoot
        Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains($expectedDaily)) 'Nudge JSON should round-trip quote, backslash, and control characters in the path.'
    }

    Add-Case 'bash-stop-json-escapes-special-path' {
        $caseRoot = New-SpecialPathCaseRoot
        Set-Marker -DevlogRoot $caseRoot -SessionId 'json-stop' -Content "$((Get-NowEpoch) - 100)" | Out-Null
        $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"json-stop"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
        $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
        $expectedDaily = Get-ExpectedDailyPath -DevlogRoot $caseRoot
        Assert-Condition ($json.decision -eq 'block') 'Bash Stop should still block for a special-character path.'
        Assert-Condition ($json.reason.Contains($expectedDaily)) 'Stop JSON should round-trip quote, backslash, and control characters in the path.'
    }
}

# --- Runner --------------------------------------------------------------------

$failures = New-Object System.Collections.Generic.List[string]
try {
    foreach ($case in $cases) {
        try {
            & $case.Body
            Write-Host "PASS $($case.Name)"
        } catch {
            $failures.Add("$($case.Name): $($_.Exception.Message)") | Out-Null
            Write-Host "FAIL $($case.Name): $($_.Exception.Message)"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "Hook pipe-test failed ($($failures.Count) of $($cases.Count) cases):"
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host ''
Write-Host "Hook pipe-test passed ($($cases.Count) cases) with $shellPath."
exit 0
