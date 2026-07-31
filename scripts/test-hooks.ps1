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
#   pwsh -NoProfile -File ./scripts/test-hooks.ps1 -CaseName <exact-case-name>
# -HookShell picks the shell that executes the hooks: 'pwsh', 'powershell',
# 'bash', or a full path. Default: pwsh if available, otherwise powershell.

[CmdletBinding()]
param(
    [string]$Path = '',
    [string]$HookShell = '',
    [string]$CaseName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# CopyToAsync must keep both child pipes draining, but an adversarial or broken
# hook must not make the test runner retain unbounded output before its deadline.
if ($null -eq ('DevlogBoundedCaptureStream' -as [type])) {
    $captureStreamSource = @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public sealed class DevlogBoundedCaptureStream : Stream
{
    private readonly long maximumBytes;
    private readonly MemoryStream inner = new MemoryStream();

    public DevlogBoundedCaptureStream(long maximumBytes)
    {
        if (maximumBytes < 1) throw new ArgumentOutOfRangeException("maximumBytes");
        this.maximumBytes = maximumBytes;
    }

    private void EnsureWithinLimit(int count)
    {
        if (count < 0 || inner.Length + count > maximumBytes)
            throw new IOException("Hook output capture limit exceeded.");
    }

    public byte[] ToArray()
    {
        return inner.ToArray();
    }

    public override bool CanRead { get { return false; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return true; } }
    public override long Length { get { return inner.Length; } }
    public override long Position
    {
        get { return inner.Position; }
        set { throw new NotSupportedException(); }
    }

    public override void Flush()
    {
        inner.Flush();
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        throw new NotSupportedException();
    }

    public override long Seek(long offset, SeekOrigin origin)
    {
        throw new NotSupportedException();
    }

    public override void SetLength(long value)
    {
        throw new NotSupportedException();
    }

    public override void Write(byte[] buffer, int offset, int count)
    {
        EnsureWithinLimit(count);
        inner.Write(buffer, offset, count);
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        EnsureWithinLimit(count);
        return inner.WriteAsync(buffer, offset, count, cancellationToken);
    }

    /* DEVLOG_MODERN_WRITE_OVERRIDE */

    public override void WriteByte(byte value)
    {
        EnsureWithinLimit(1);
        inner.WriteByte(value);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) inner.Dispose();
        base.Dispose(disposing);
    }
}
'@
    # .NET 7+ lets Stream.CopyToAsync dispatch directly to the memory-based
    # overload. Add that override only where the target framework exposes it;
    # Windows PowerShell 5.1 compiles the same wrapper without modern types.
    $modernWriteOverride = if ($PSVersionTable.PSVersion.Major -ge 7) {
        @'
public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken)
    {
        EnsureWithinLimit(buffer.Length);
        return inner.WriteAsync(buffer, cancellationToken);
    }
'@
    } else {
        ''
    }
    $captureStreamSource = $captureStreamSource.Replace('/* DEVLOG_MODERN_WRITE_OVERRIDE */', $modernWriteOverride)
    Add-Type -TypeDefinition $captureStreamSource
}

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
} else {
    $requiredHooks += (Join-Path $root 'hooks/devlog-common.ps1')
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
$warningSign = [string][char]0x26A0
$journalEmoji = [char]::ConvertFromUtf32(0x1F4D3)
$identityWarningJa = [regex]::Unescape('\u26a0 \u30bb\u30c3\u30b7\u30e7\u30f3ID\u3092\u78ba\u7acb\u3067\u304d\u306a\u3044\u305f\u3081\u3001\u3053\u306e\u30bb\u30c3\u30b7\u30e7\u30f3\u3067\u306f Stop hook \u306e\u5f37\u5236\u3068\u50ac\u4fc3\u306f\u7121\u52b9\u3067\u3059\u3002')
$identityWarningEn = [regex]::Unescape('\u26a0 Session identity could not be established. Stop-hook enforcement and staleness nudges are OFF for this session.')
$syntheticPrivateSentinel = 'SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT'
$maxHookInputBytes = 1048576
$maxCapturedStreamBytes = 1048576
$strictNonJsonSamples = @(
    @{ Name = 'unquoted-key'; Text = '{session_id:"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}' },
    @{ Name = 'single-quoted-key'; Text = "{'session_id':'SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT'}" },
    @{ Name = 'comment'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"/*comment*/}' },
    @{ Name = 'trailing-comma'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT",}' },
    @{ Name = 'leading-zero'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","n":01}' },
    @{ Name = 'nan'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","n":NaN}' },
    @{ Name = 'infinity'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","n":Infinity}' },
    @{ Name = 'incomplete-fraction'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","n":1.}' },
    @{ Name = 'incomplete-exponent'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","n":1e}' },
    @{ Name = 'incomplete-exponent-sign'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","n":1e+}' },
    @{ Name = 'leading-plus'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","n":+1}' },
    @{ Name = 'leading-decimal-point'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","n":.1}' },
    @{ Name = 'invalid-escape-uppercase-b'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT\B"}' },
    @{ Name = 'invalid-escape-uppercase-f'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT\F"}' },
    @{ Name = 'invalid-escape-uppercase-n'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT\N"}' },
    @{ Name = 'invalid-escape-uppercase-r'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT\R"}' },
    @{ Name = 'invalid-escape-uppercase-t'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT\T"}' },
    @{ Name = 'invalid-escape-uppercase-u-field'; Text = '{"\U0073ession_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}' },
    @{ Name = 'invalid-escape-uppercase-u-value'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT\U0041"}' },
    @{ Name = 'lone-high-surrogate'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT\uD800"}' },
    @{ Name = 'lone-low-surrogate'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT\uDC00"}' },
    @{ Name = 'high-surrogate-followed-by-scalar'; Text = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT\uD800\u0041"}' }
)

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
        [AllowEmptyString()][string]$StdinText = '',
        [byte[]]$StdinBytes = $null,
        [Parameter(Mandatory = $true)][hashtable]$ChildEnvironment,
        [switch]$AllowEarlyStdinClose,
        [switch]$DirectScript,
        [ValidateRange(100, 120000)][int]$TimeoutMilliseconds = 30000
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $shellPath
    if ($isBashHook) {
        if ($DirectScript) {
            # Direct helper probes live under the synthetic temp root and need
            # an explicit runtime-native path.
            $directPath = ConvertTo-HookPath -NativePath $HookPath
            $psi.Arguments = '--noprofile --norc "' + $directPath + '"'
        } else {
            # A relative path avoids MSYS/WSL drive-path ambiguity while the
            # working directory keeps source-relative helper loading stable.
            $hookName = [System.IO.Path]::GetFileName($HookPath)
            $psi.Arguments = '--noprofile --norc "hooks/' + $hookName + '"'
        }
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
    foreach ($name in @('CLAUDE_DEVLOG_DIR', 'CLAUDE_DEVLOG_LANG', 'DEVLOG_TEST_REPO_ROOT')) {
        if ($psi.EnvironmentVariables.ContainsKey($name)) {
            $psi.EnvironmentVariables.Remove($name)
        }
    }
    foreach ($key in $ChildEnvironment.Keys) {
        $value = [string]$ChildEnvironment[$key]
        if ($isBashHook -and ($key -eq 'CLAUDE_DEVLOG_DIR' -or $key -eq 'DEVLOG_TEST_REPO_ROOT')) {
            $value = ConvertTo-HookPath -NativePath $value
        }
        $psi.EnvironmentVariables[$key] = $value
    }
    if ($isWslBash) {
        # WSL imports opt-in Windows variables through WSLENV. Values are
        # already converted above, so no /p translation flag is needed.
        $psi.EnvironmentVariables['WSLENV'] = 'CLAUDE_DEVLOG_DIR:CLAUDE_DEVLOG_LANG:DEVLOG_TEST_REPO_ROOT'
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdoutBuffer = New-Object -TypeName DevlogBoundedCaptureStream -ArgumentList ([long]$maxCapturedStreamBytes)
    $stderrBuffer = New-Object -TypeName DevlogBoundedCaptureStream -ArgumentList ([long]$maxCapturedStreamBytes)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $stdinClosed = $false

    function Wait-HookTask {
        param(
            [Parameter(Mandatory = $true)][System.Threading.Tasks.Task]$Task,
            [Parameter(Mandatory = $true)][string]$Operation,
            [switch]$MonitorDrains
        )

        # A child can overflow stdout/stderr while refusing stdin. Observe the
        # drain tasks during writes so capture overflow is reported immediately
        # instead of being misclassified as a later stdin deadline.
        while (-not $Task.IsCompleted) {
            if ($MonitorDrains) {
                if ($stdoutTask.IsFaulted) { $stdoutTask.Wait() }
                if ($stderrTask.IsFaulted) { $stderrTask.Wait() }
            }
            $remaining = $TimeoutMilliseconds - [int]$timer.ElapsedMilliseconds
            if ($remaining -le 0) {
                throw [System.TimeoutException]::new("$Operation exceeded the hook deadline.")
            }
            try {
                [void]$Task.Wait([Math]::Min($remaining, 50))
            } catch {
                # A concurrent capture overflow can close the child's stdin in
                # the same scheduling slice. Prefer that deterministic harness
                # failure over the secondary pipe-closed exception.
                if ($MonitorDrains) {
                    if ($stdoutTask.IsFaulted) { $stdoutTask.Wait() }
                    if ($stderrTask.IsFaulted) { $stderrTask.Wait() }
                }
                throw
            }
        }
        # Wait again only after completion so task faults are surfaced without
        # introducing another unbounded wait.
        if ($MonitorDrains) {
            if ($stdoutTask.IsFaulted) { $stdoutTask.Wait() }
            if ($stderrTask.IsFaulted) { $stderrTask.Wait() }
        }
        $Task.Wait()
    }

    try {
        # Start draining both pipes before writing stdin. A child can therefore
        # never deadlock the harness by filling stdout/stderr while the parent
        # is still supplying a large boundary fixture.
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutBuffer)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrBuffer)
        $payloadBytes = if ($null -ne $StdinBytes) {
            $StdinBytes
        } else {
            [System.Text.Encoding]::UTF8.GetBytes($StdinText)
        }
        # PowerShell unwraps a zero-length array result to `$null`; restore an
        # explicit byte[] so empty-stdin probes exercise the child, not StrictMode.
        if ($null -eq $payloadBytes) { $payloadBytes = New-Object byte[] 0 }
        try {
            $writeTask = $process.StandardInput.BaseStream.WriteAsync($payloadBytes, 0, $payloadBytes.Length)
            Wait-HookTask -Task $writeTask -Operation 'stdin write' -MonitorDrains
            $flushTask = $process.StandardInput.BaseStream.FlushAsync()
            Wait-HookTask -Task $flushTask -Operation 'stdin flush' -MonitorDrains
        } catch {
            # A hook that proves its size cap may close stdin before a caller
            # finishes a deliberately oversized fixture. Other cases retain
            # the strict write-success assertion.
            if (-not $AllowEarlyStdinClose -or $_.Exception -is [System.TimeoutException]) { throw }
        }
        try {
            $process.StandardInput.Close()
            $stdinClosed = $true
        } catch {
            if (-not $AllowEarlyStdinClose) { throw }
        }

        # Poll in short bounded slices so a capture-limit fault terminates the
        # child immediately instead of waiting for a blocked pipe to time out.
        while (-not $process.HasExited) {
            if ($stdoutTask.IsFaulted) { $stdoutTask.Wait() }
            if ($stderrTask.IsFaulted) { $stderrTask.Wait() }
            $remaining = $TimeoutMilliseconds - [int]$timer.ElapsedMilliseconds
            if ($remaining -le 0) {
                throw [System.TimeoutException]::new('process exit exceeded the hook deadline.')
            }
            $slice = [Math]::Min($remaining, 50)
            if ($process.WaitForExit($slice)) { break }
        }
        Wait-HookTask -Task $stdoutTask -Operation 'stdout drain'
        Wait-HookTask -Task $stderrTask -Operation 'stderr drain'

        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdoutBytes = $stdoutBuffer.ToArray()
            Stderr = $strictUtf8.GetString($stderrBuffer.ToArray())
        }
    }
    catch {
        $caughtError = $_
        if (-not $process.HasExited) {
            try { $process.Kill() } catch { }
            try { $null = $process.WaitForExit(2000) } catch { }
        }
        # A timed-out WriteAsync may still own the pipe. Kill and bounded-wait
        # first; only then close stdin so Dispose cannot defeat the deadline.
        if (-not $stdinClosed) {
            try { $process.StandardInput.Close(); $stdinClosed = $true } catch { }
        }
        if ($caughtError.Exception -is [System.TimeoutException]) {
            throw "Hook timed out after $TimeoutMilliseconds ms: $HookPath ($($caughtError.Exception.Message))"
        }
        throw $caughtError
    }
    finally {
        $timer.Stop()
        if (-not $stdinClosed) {
            try { $process.StandardInput.Close() } catch { }
        }
        $stdoutBuffer.Dispose()
        $stderrBuffer.Dispose()
        $process.Dispose()
    }
}

function ConvertTo-StrictUtf8Text {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if ($Bytes.Length -eq 0) {
        throw 'Assertion failed: expected JSON output but stdout was empty.'
    }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return $strictUtf8.GetString($Bytes)
}

function ConvertFrom-HookStdout {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    # Structured hook output must be a bare JSON object with no BOM or prefix.
    if ($Bytes[0] -ne 0x7B) {
        throw ("Assertion failed: stdout does not start with '{{' (first byte: 0x{0:X2})." -f $Bytes[0])
    }
    # Strict decoder: throws on any invalid UTF-8 sequence.
    $text = ConvertTo-StrictUtf8Text -Bytes $Bytes
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

function Assert-UnjudgeableSessionStart {
    # Identity failures still return the routine, but the fixed warning must
    # disclose disabled enforcement without reflecting any protocol input.
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$DevlogRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedWarning,
        [Parameter(Mandatory = $true)][string]$Label,
        [string[]]$SensitiveNeedles = @()
    )

    Assert-Condition ($Result.ExitCode -eq 0) "$Label should exit 0 (got $($Result.ExitCode))."
    Assert-Condition ([string]::IsNullOrWhiteSpace($Result.Stderr)) "$Label should produce no stderr (got: $($Result.Stderr))."
    $stdoutText = ConvertTo-StrictUtf8Text -Bytes $Result.StdoutBytes
    $json = ConvertFrom-HookStdout -Bytes $Result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.hookEventName -eq 'SessionStart') "$Label should emit SessionStart context."
    $context = [string]$json.hookSpecificOutput.additionalContext
    Assert-Condition ($context.EndsWith($ExpectedWarning, [System.StringComparison]::Ordinal)) "$Label should end with the exact fixed identity warning."

    foreach ($needle in $SensitiveNeedles) {
        Assert-Condition ($stdoutText.IndexOf($needle, [System.StringComparison]::Ordinal) -lt 0) "$Label must not reflect the synthetic private sentinel to stdout."
        Assert-Condition ($Result.Stderr.IndexOf($needle, [System.StringComparison]::Ordinal) -lt 0) "$Label must not reflect the synthetic private sentinel to stderr."
        $markerDir = Join-Path $DevlogRoot '.devlog-markers'
        if (Test-Path -LiteralPath $markerDir) {
            foreach ($entry in Get-ChildItem -LiteralPath $markerDir -Force) {
                Assert-Condition ($entry.Name.IndexOf($needle, [System.StringComparison]::Ordinal) -lt 0) "$Label must not reflect the synthetic private sentinel to a marker name."
            }
        }
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-code-devlog-hooks-test-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

# Build one ASCII-only child script for direct helper-state assertions. These
# probes distinguish "valid object without a session" from parse failure,
# which the public fail-open hooks intentionally expose in the same way.
$parserProbePath = Join-Path $tempRoot ('parser-probe' + $hookExtension)
if ($isBashHook) {
    $parserProbeSource = @'
#!/usr/bin/env bash
set +e
set +u
set +o pipefail 2>/dev/null || :

if ! . "$DEVLOG_TEST_REPO_ROOT/hooks/devlog-common.sh"; then
    printf 'PARSE_ERROR\n'
    exit 0
fi
if devlog_parse_input; then
    printf '%s|%s|%s\n' "$DEVLOG_HAS_SESSION" "$DEVLOG_SESSION_ID" "$DEVLOG_STOP_ACTIVE"
else
    printf 'PARSE_ERROR\n'
fi
exit 0
'@
} else {
    $parserProbeSource = @'
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $env:DEVLOG_TEST_REPO_ROOT 'hooks/devlog-common.ps1')
    $data = Read-DevlogHookInput
    if ($null -eq $data) {
        [Console]::Out.Write("PARSE_ERROR`n")
        exit 0
    }
    $hasSession = if ($data.HasSession) { '1' } else { '0' }
    $stopActive = if ($data.StopActive) { '1' } else { '0' }
    [Console]::Out.Write($hasSession + '|' + [string]$data.SessionId + '|' + $stopActive + "`n")
} catch {
    [Console]::Out.Write("PARSE_ERROR`n")
}
exit 0
'@
}
[System.IO.File]::WriteAllText(
    $parserProbePath,
    ($parserProbeSource -replace "`r`n", "`n"),
    (New-Object System.Text.UTF8Encoding($false))
)

# Exercise the harness itself with the classic full-duplex pipe deadlock:
# the child writes more than one pipe buffer before reading a large stdin.
$harnessProbePath = Join-Path $tempRoot ('harness-probe' + $hookExtension)
if ($isBashHook) {
    $harnessProbeSource = @'
#!/usr/bin/env bash
set -e
LC_ALL=C head -c 131072 /dev/zero | LC_ALL=C tr '\000' x
LC_ALL=C head -c 1048576 >/dev/null
'@
} else {
    $harnessProbeSource = @'
$stdout = [Console]::OpenStandardOutput()
$output = New-Object byte[] 131072
for ($index = 0; $index -lt $output.Length; $index++) { $output[$index] = 0x78 }
$stdout.Write($output, 0, $output.Length)
$stdout.Flush()
$stdin = [Console]::OpenStandardInput()
$buffer = New-Object byte[] 8192
while ($stdin.Read($buffer, 0, $buffer.Length) -gt 0) { }
'@
}
[System.IO.File]::WriteAllText(
    $harnessProbePath,
    ($harnessProbeSource -replace "`r`n", "`n"),
    (New-Object System.Text.UTF8Encoding($false))
)

# A child that never consumes stdin proves timeout cleanup kills before closing
# a pending asynchronous write. A second child pins the per-pipe capture cap.
$timeoutProbePath = Join-Path $tempRoot ('timeout-probe' + $hookExtension)
$overflowProbePath = Join-Path $tempRoot ('overflow-probe' + $hookExtension)
if ($isBashHook) {
    $timeoutProbeSource = @'
#!/usr/bin/env bash
exec sleep 10
'@
    $overflowProbeSource = @'
#!/usr/bin/env bash
printf '%1048577s' ''
'@
} else {
    $timeoutProbeSource = @'
Start-Sleep -Seconds 10
'@
    $overflowProbeSource = @'
$stdout = [Console]::OpenStandardOutput()
$output = New-Object byte[] 1048577
$stdout.Write($output, 0, $output.Length)
$stdout.Flush()
'@
}
foreach ($probe in @(
    @{ Path = $timeoutProbePath; Source = $timeoutProbeSource },
    @{ Path = $overflowProbePath; Source = $overflowProbeSource }
)) {
    [System.IO.File]::WriteAllText(
        $probe.Path,
        ($probe.Source -replace "`r`n", "`n"),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Assert-ParserProbe {
    param(
        [AllowEmptyString()][string]$StdinText = '',
        [byte[]]$StdinBytes = $null,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $invokeArguments = @{
        HookPath = $parserProbePath
        DirectScript = $true
        ChildEnvironment = @{ DEVLOG_TEST_REPO_ROOT = $root }
    }
    if ($null -eq $StdinBytes) {
        $invokeArguments.StdinText = $StdinText
    } else {
        $invokeArguments.StdinBytes = $StdinBytes
    }
    $result = Invoke-Hook @invokeArguments
    Assert-Condition ($result.ExitCode -eq 0) "$Label should exit 0 (got $($result.ExitCode))."
    Assert-Condition ([string]::IsNullOrWhiteSpace($result.Stderr)) "$Label should keep stderr empty (got: $($result.Stderr))."
    $actual = (ConvertTo-StrictUtf8Text -Bytes $result.StdoutBytes).TrimEnd([char[]]@([char]0x0D, [char]0x0A))
    Assert-Condition ($actual -ceq $Expected) "$Label should return '$Expected' (got: '$actual')."
}

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
    $markerPath = Get-MarkerPath -DevlogRoot $DevlogRoot -SessionId $SessionId
    Set-Content -LiteralPath $markerPath -Value $Content -NoNewline -Encoding ascii
    return $markerPath
}

function Get-MarkerFileName {
    param([Parameter(Mandatory = $true)][string]$SessionId)

    # Mirror the public runtime contract independently so assertions inspect
    # the actual portable key instead of assuming a raw session filename.
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in [System.Text.Encoding]::ASCII.GetBytes($SessionId)) {
        [void]$builder.Append($byte.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture))
    }
    return ('~sid-' + $builder.ToString() + '.start')
}

function Get-MarkerPath {
    param(
        [Parameter(Mandatory = $true)][string]$DevlogRoot,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    return (Join-Path (Join-Path $DevlogRoot '.devlog-markers') (Get-MarkerFileName -SessionId $SessionId))
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

function New-EmbeddedNulInputBytes {
    param([Parameter(Mandatory = $true)][string]$SessionId)

    # Removing this NUL would produce valid JSON. The parser must observe and
    # reject the original bytes before any shell can normalize them.
    $prefix = [System.Text.Encoding]::UTF8.GetBytes('{"session_id":"' + $SessionId + '"')
    $suffix = [System.Text.Encoding]::UTF8.GetBytes('}')
    $bytes = New-Object byte[] ($prefix.Length + 1 + $suffix.Length)
    [Array]::Copy($prefix, 0, $bytes, 0, $prefix.Length)
    $bytes[$prefix.Length] = 0
    [Array]::Copy($suffix, 0, $bytes, $prefix.Length + 1, $suffix.Length)
    return $bytes
}

function New-InvalidUtf8InputBytes {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][byte[]]$InvalidBytes
    )

    $prefix = [System.Text.Encoding]::UTF8.GetBytes('{"session_id":"' + $SessionId + '","padding":"')
    $suffix = [System.Text.Encoding]::UTF8.GetBytes('"}')
    $bytes = New-Object byte[] ($prefix.Length + $InvalidBytes.Length + $suffix.Length)
    [Array]::Copy($prefix, 0, $bytes, 0, $prefix.Length)
    [Array]::Copy($InvalidBytes, 0, $bytes, $prefix.Length, $InvalidBytes.Length)
    [Array]::Copy($suffix, 0, $bytes, $prefix.Length + $InvalidBytes.Length, $suffix.Length)
    return $bytes
}

function New-SizedInputBytes {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][int]$TargetLength
    )

    # Keep the fixture valid JSON when read in full. Only the explicit byte
    # ceiling should distinguish max from max+1.
    $prefix = [System.Text.Encoding]::UTF8.GetBytes('{"session_id":"' + $SessionId + '","padding":"')
    $suffix = [System.Text.Encoding]::UTF8.GetBytes('"}')
    $paddingLength = $TargetLength - $prefix.Length - $suffix.Length
    Assert-Condition ($paddingLength -gt 0) 'Sized fixture needs positive padding.'
    $bytes = New-Object byte[] $TargetLength
    [Array]::Copy($prefix, 0, $bytes, 0, $prefix.Length)
    for ($index = $prefix.Length; $index -lt ($prefix.Length + $paddingLength); $index++) {
        $bytes[$index] = 0x78
    }
    [Array]::Copy($suffix, 0, $bytes, $prefix.Length + $paddingLength, $suffix.Length)
    return $bytes
}

function New-NestedArrayInput {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [ValidateRange(2, 1000)][int]$JsonDepth
    )

    # The root object is depth 1. Repeated arrays make the deepest container
    # exactly JsonDepth; a scalar leaf then proves the limit applies only to
    # containers rather than rejecting a value inside the deepest valid one.
    $arrayCount = $JsonDepth - 1
    return ('{"session_id":"' + $SessionId + '","nested":' +
        ('[' * $arrayCount) + '0' + (']' * $arrayCount) + '}')
}

function New-ValueBudgetInput {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [ValidateRange(0, 10000)][int]$ArrayElements
    )

    $arrayText = if ($ArrayElements -eq 0) { '' } else { ('0,' * ($ArrayElements - 1)) + '0' }
    return ('{"session_id":"' + $SessionId + '","values":[' + $arrayText + ']}')
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

    $markerPath = Get-MarkerPath -DevlogRoot $caseRoot -SessionId 'alpha-1'
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
    Assert-Condition (Test-Path -LiteralPath (Get-MarkerPath -DevlogRoot $caseRoot -SessionId 'beta-2')) 'The new session marker should exist.'
}

Add-Case 'session-start-rejects-unsafe-or-oversized-session-id' {
    # Lossy filename replacement would map both ids to a_b.start and let one
    # session consume another session marker. Unsafe identities now fail open.
    $collisionRoot = New-CaseRoot -WithMarkerDir
    $collisionMarker = Join-Path (Join-Path $collisionRoot '.devlog-markers') 'a_b.start'
    Set-Content -LiteralPath $collisionMarker -Value "$((Get-NowEpoch) - 2000)" -NoNewline -Encoding ascii
    foreach ($unsafeId in @('a/b', 'a?b')) {
        $stdin = '{"session_id":"' + $unsafeId + '"}'
        $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $collisionRoot }
        Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $collisionRoot -ExpectedWarning $identityWarningJa -Label ("SessionStart with unsafe session id $unsafeId")
        Assert-Condition (Test-Path -LiteralPath $collisionMarker) 'An unsafe session id must not consume or replace a colliding marker.'
    }
    $nudgeResult = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"a/b"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $collisionRoot }
    Assert-Allowed -Result $nudgeResult -Label 'Nudge with an unsafe id colliding with a marker name'
    $stopResult = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"a?b"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $collisionRoot }
    Assert-Allowed -Result $stopResult -Label 'Stop with an unsafe id colliding with a marker name'

    $supplementaryRoot = New-CaseRoot -LeaveMissing
    $supplementaryResult = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":"emoji-\ud83d\ude00"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $supplementaryRoot }
    Assert-UnjudgeableSessionStart -Result $supplementaryResult -DevlogRoot $supplementaryRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with a supplementary session id'

    $maximumId = 's' * 64
    $maximumRoot = New-CaseRoot -LeaveMissing
    $maximumResult = Invoke-Hook -HookPath $hookSessionStart -StdinText ('{"session_id":"' + $maximumId + '"}') -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $maximumRoot }
    Assert-Condition ($maximumResult.ExitCode -eq 0) 'A 64-character safe session id should be accepted.'
    Assert-Condition (Test-Path -LiteralPath (Get-MarkerPath -DevlogRoot $maximumRoot -SessionId $maximumId)) 'A 64-character safe session id should retain an injective marker key.'

    $oversizedId = 's' * 65
    $oversizedRoot = New-CaseRoot -LeaveMissing
    $oversizedResult = Invoke-Hook -HookPath $hookSessionStart -StdinText ('{"session_id":"' + $oversizedId + '"}') -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $oversizedRoot }
    Assert-UnjudgeableSessionStart -Result $oversizedResult -DevlogRoot $oversizedRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with a 65-character session id'

    # Case variants and Windows reserved basenames must remain distinct without
    # depending on filesystem case behavior. The legacy raw marker namespace is
    # also disjoint from the new `~sid-` hex namespace during rolling upgrades.
    $portableRoot = New-CaseRoot -WithMarkerDir
    $portableIds = @('A', 'a', 'NUL', 'CON', 'COM1')
    foreach ($portableId in $portableIds) {
        $portableResult = Invoke-Hook -HookPath $hookSessionStart -StdinText ('{"session_id":"' + $portableId + '"}') -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $portableRoot }
        Assert-Condition ($portableResult.ExitCode -eq 0) "SessionStart should accept portable identity $portableId."
        $portablePath = Get-MarkerPath -DevlogRoot $portableRoot -SessionId $portableId
        Assert-Condition (Test-Path -LiteralPath $portablePath -PathType Leaf) "Portable marker $portableId should exist under its encoded key."
        Assert-Condition ([System.IO.Path]::GetFileName($portablePath).StartsWith('~sid-', [System.StringComparison]::Ordinal)) 'Every encoded marker must use the disjoint namespace prefix.'
    }
    $caseInsensitiveKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($portableId in $portableIds) {
        [void]$caseInsensitiveKeys.Add((Get-MarkerFileName -SessionId $portableId))
    }
    Assert-Condition ($caseInsensitiveKeys.Count -eq $portableIds.Count) 'Case variants and reserved names must have distinct portable marker keys.'

    $legacyMarker = Join-Path (Join-Path $portableRoot '.devlog-markers') 'sid-6162.start'
    Set-Content -LiteralPath $legacyMarker -Value "$(Get-NowEpoch)" -NoNewline -Encoding ascii
    $legacyResult = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":"ab"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $portableRoot }
    Assert-Condition ($legacyResult.ExitCode -eq 0) 'SessionStart should accept an identity resembling a legacy raw marker.'
    Assert-Condition (Test-Path -LiteralPath $legacyMarker -PathType Leaf) 'A fresh legacy raw marker must not collide with the new namespace.'
    Assert-Condition (Test-Path -LiteralPath (Get-MarkerPath -DevlogRoot $portableRoot -SessionId 'ab') -PathType Leaf) 'The new encoded marker should coexist with its legacy collision candidate.'
}

Add-Case 'session-start-missing-session-id-disables-enforcement' {
    # Pre-seed an old marker: an unjudgeable SessionStart must not prune it or
    # create an enforcement-looking unknown marker.
    $caseRoot = New-CaseRoot -WithMarkerDir
    $oldMarker = Set-Marker -DevlogRoot $caseRoot -SessionId 'keep-stale' -Content '1000'
    (Get-Item -LiteralPath $oldMarker).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    $stdin = '{"other":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart without a session_id' -SensitiveNeedles @($syntheticPrivateSentinel)
    Assert-Condition (Test-Path -LiteralPath $oldMarker) 'An unjudgeable SessionStart must not prune existing markers.'
    Assert-Condition (-not (Test-Path -LiteralPath (Get-MarkerPath -DevlogRoot $caseRoot -SessionId 'unknown'))) 'An unjudgeable SessionStart must not create an unknown marker.'
    Assert-ParserProbe -StdinText '{}' -Expected '0||0' -Label 'Direct parser with an empty object'
}

Add-Case 'session-start-empty-session-id-disables-enforcement' {
    $caseRoot = New-CaseRoot -LeaveMissing
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":""}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with an empty session_id'
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $caseRoot '.devlog-markers'))) 'An empty session_id must not create a marker directory.'
}

Add-Case 'session-start-non-string-session-id-disables-enforcement' {
    $caseRoot = New-CaseRoot -LeaveMissing
    $stdin = '{"session_id":{"private":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}}'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with a non-string session_id' -SensitiveNeedles @($syntheticPrivateSentinel)
    $markerDir = Join-Path $caseRoot '.devlog-markers'
    Assert-Condition (-not (Test-Path -LiteralPath $markerDir)) 'A non-string session_id must not create a marker directory.'
}

Add-Case 'session-start-malformed-stdin-disables-enforcement' {
    $caseRoot = New-CaseRoot -LeaveMissing
    $stdin = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with malformed stdin' -SensitiveNeedles @($syntheticPrivateSentinel)
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $caseRoot '.devlog-markers'))) 'Malformed stdin must not create a marker directory.'
}

Add-Case 'session-start-array-root-disables-enforcement' {
    # A one-element array must stay an array; PowerShell must not scalarize it
    # into an enforceable object through pipeline enumeration.
    $caseRoot = New-CaseRoot -WithMarkerDir
    $oldMarker = Set-Marker -DevlogRoot $caseRoot -SessionId 'keep-array-stale' -Content '1000'
    (Get-Item -LiteralPath $oldMarker).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    $stdin = '[{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}]'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with an array root' -SensitiveNeedles @($syntheticPrivateSentinel)
    Assert-Condition (Test-Path -LiteralPath $oldMarker) 'An array-root SessionStart must not prune existing markers.'
}

Add-Case 'session-start-case-alias-disables-enforcement' {
    $caseRoot = New-CaseRoot -LeaveMissing
    $stdin = '{"SESSION_ID":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with a case-alias session field' -SensitiveNeedles @($syntheticPrivateSentinel)
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $caseRoot '.devlog-markers'))) 'A case-alias session field must not create a marker directory.'
}

Add-Case 'session-start-duplicate-session-id-disables-enforcement' {
    $caseRoot = New-CaseRoot -LeaveMissing
    $stdin = '{"session_id":"first","session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with a duplicate session field' -SensitiveNeedles @($syntheticPrivateSentinel)
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $caseRoot '.devlog-markers'))) 'A duplicate session field must not create a marker directory.'
}

Add-Case 'session-start-session-id-case-collision-disables-enforcement' {
    $caseRoot = New-CaseRoot -LeaveMissing
    $stdin = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","SESSION_ID":"alias"}'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with a session field case collision' -SensitiveNeedles @($syntheticPrivateSentinel)
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $caseRoot '.devlog-markers'))) 'A session field case collision must not create a marker directory.'
}

Add-Case 'session-start-accepts-unicode-escaped-exact-field-name' {
    # JSON escapes are decoded before protocol names are compared, so this is
    # the exact field name rather than an alias.
    $caseRoot = New-CaseRoot -LeaveMissing
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"\u0073ession_id":"escaped-key"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-Condition ($result.ExitCode -eq 0) 'SessionStart should accept an escaped exact session field name.'
    Assert-Condition ([string]::IsNullOrWhiteSpace($result.Stderr)) 'SessionStart should keep stderr silent for an escaped exact session field name.'
    Assert-Condition (Test-Path -LiteralPath (Get-MarkerPath -DevlogRoot $caseRoot -SessionId 'escaped-key')) 'An escaped exact session field name should create the expected marker.'
}

Add-Case 'session-start-rejects-non-rfc-json-extensions' {
    foreach ($sample in $strictNonJsonSamples) {
        $caseRoot = New-CaseRoot -WithMarkerDir
        $oldMarker = Set-Marker -DevlogRoot $caseRoot -SessionId ('keep-' + $sample.Name) -Content '1000'
        (Get-Item -LiteralPath $oldMarker).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
        $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $sample.Text -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
        $label = 'SessionStart with non-RFC JSON extension ' + $sample.Name

        Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label $label -SensitiveNeedles @($syntheticPrivateSentinel)
        Assert-Condition (Test-Path -LiteralPath $oldMarker) "$label must not prune an existing marker."
    }
}

Add-Case 'session-start-rejects-embedded-nul-without-side-effects' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    $oldMarker = Set-Marker -DevlogRoot $caseRoot -SessionId 'keep-nul-stale' -Content '1000'
    (Get-Item -LiteralPath $oldMarker).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    $stdinBytes = New-EmbeddedNulInputBytes -SessionId $syntheticPrivateSentinel
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinBytes $stdinBytes -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with embedded NUL' -SensitiveNeedles @($syntheticPrivateSentinel)
    Assert-Condition (Test-Path -LiteralPath $oldMarker) 'An embedded-NUL SessionStart must not prune an existing marker.'
}

Add-Case 'session-start-accepts-unique-escaped-unicode-unknown-fields' {
    $caseRoot = New-CaseRoot -LeaveMissing
    $stdin = '{"session_id":"unicode-unknown","":0,"\u4e00":1,"\u4e01":2}'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-Condition ($result.ExitCode -eq 0) 'SessionStart should accept distinct escaped Unicode unknown fields.'
    Assert-Condition ([string]::IsNullOrWhiteSpace($result.Stderr)) 'SessionStart should keep stderr silent for distinct escaped Unicode unknown fields.'
    Assert-Condition (Test-Path -LiteralPath (Get-MarkerPath -DevlogRoot $caseRoot -SessionId 'unicode-unknown')) 'Distinct escaped Unicode unknown fields must preserve the valid session marker.'
    Assert-ParserProbe -StdinText '{"session_id":"number-ok","a":-0,"b":0.1,"c":1e+2,"d":-3.4E-5}' -Expected '1|number-ok|0' -Label 'Direct parser with valid JSON number forms'
}

Add-Case 'session-start-rejects-literal-escaped-exact-field-duplicate' {
    $caseRoot = New-CaseRoot -LeaveMissing
    $stdin = '{"session_id":"first","\u0073ession_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}'
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with literal/escaped exact field duplicate' -SensitiveNeedles @($syntheticPrivateSentinel)
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $caseRoot '.devlog-markers'))) 'A literal/escaped exact field duplicate must not create a marker directory.'

    $supplementaryRoot = New-CaseRoot -LeaveMissing
    $supplementary = [char]::ConvertFromUtf32(0x1F600)
    $supplementaryInput = '{"session_id":"supplementary-duplicate","' + $supplementary + '":1,"\ud83d\ude00":2}'
    $supplementaryResult = Invoke-Hook -HookPath $hookSessionStart -StdinText $supplementaryInput -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $supplementaryRoot }
    Assert-UnjudgeableSessionStart -Result $supplementaryResult -DevlogRoot $supplementaryRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart with literal/escaped supplementary property duplicate'
}

Add-Case 'session-start-enforces-parser-resource-boundaries' {
    $harnessInput = New-Object byte[] $maxHookInputBytes
    $harnessResult = Invoke-Hook -HookPath $harnessProbePath -DirectScript -StdinBytes $harnessInput -ChildEnvironment @{} -TimeoutMilliseconds 10000
    Assert-Condition ($harnessResult.ExitCode -eq 0) 'The full-duplex harness probe should exit 0.'
    Assert-Condition ($harnessResult.StdoutBytes.Length -eq 131072) 'The harness must drain stdout while it writes a large stdin.'
    Assert-Condition ($harnessResult.StdoutBytes[0] -eq 0x78 -and $harnessResult.StdoutBytes[131071] -eq 0x78) 'The harness probe should preserve raw stdout bytes.'

    $timeoutInput = New-Object byte[] $maxHookInputBytes
    $timeoutClock = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutFailure = $null
    try {
        Invoke-Hook -HookPath $timeoutProbePath -DirectScript -StdinBytes $timeoutInput -ChildEnvironment @{} -TimeoutMilliseconds 1000 | Out-Null
    } catch {
        $timeoutFailure = $_.Exception
    } finally {
        $timeoutClock.Stop()
    }
    Assert-Condition ($null -ne $timeoutFailure -and $timeoutFailure.Message.StartsWith('Hook timed out after 1000 ms:', [System.StringComparison]::Ordinal)) 'A child that never reads stdin must hit the shared deadline.'
    Assert-Condition ($timeoutClock.ElapsedMilliseconds -lt 5000) 'Timeout cleanup must kill before closing a pending stdin write.'

    $overflowClock = [System.Diagnostics.Stopwatch]::StartNew()
    $overflowFailure = $null
    try {
        Invoke-Hook -HookPath $overflowProbePath -DirectScript -StdinBytes $timeoutInput -ChildEnvironment @{} -TimeoutMilliseconds 5000 | Out-Null
    } catch {
        $overflowFailure = $_.Exception
    } finally {
        $overflowClock.Stop()
    }
    $overflowMessage = if ($null -eq $overflowFailure) { '' } else { $overflowFailure.GetBaseException().Message }
    Assert-Condition ($overflowMessage.Contains('Hook output capture limit exceeded.')) ('A child exceeding the per-pipe capture cap must fail the harness. Actual: ' + $(if ([string]::IsNullOrEmpty($overflowMessage)) { '<no failure>' } else { $overflowMessage }))
    Assert-Condition ($overflowClock.ElapsedMilliseconds -lt 7000) 'Capture overflow must terminate the child within a bounded interval.'

    Assert-ParserProbe -StdinText '' -Expected 'PARSE_ERROR' -Label 'Direct parser with empty stdin'

    $exactBytes = New-SizedInputBytes -SessionId 'exact-max' -TargetLength $maxHookInputBytes
    Assert-ParserProbe -StdinBytes $exactBytes -Expected '1|exact-max|0' -Label 'Direct parser at the exact 1,048,576-byte limit'

    $caseRoot = New-CaseRoot -WithMarkerDir
    $oldMarker = Set-Marker -DevlogRoot $caseRoot -SessionId 'keep-oversized-stale' -Content '1000'
    (Get-Item -LiteralPath $oldMarker).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    $stdinBytes = New-SizedInputBytes -SessionId $syntheticPrivateSentinel -TargetLength ($maxHookInputBytes + 1)
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinBytes $stdinBytes -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot } -AllowEarlyStdinClose

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label 'SessionStart over the byte limit' -SensitiveNeedles @($syntheticPrivateSentinel)
    Assert-Condition (Test-Path -LiteralPath $oldMarker) 'An oversized SessionStart must not prune an existing marker.'

    $propertyAtLimit = '{"session_id":"property-256","' + ('p' * 256) + '":0}'
    Assert-ParserProbe -StdinText $propertyAtLimit -Expected '1|property-256|0' -Label 'Direct parser with a 256-scalar property name'
    $propertyOverLimit = '{"session_id":"property-257","' + ('p' * 257) + '":0}'
    Assert-ParserProbe -StdinText $propertyOverLimit -Expected 'PARSE_ERROR' -Label 'Direct parser with a 257-scalar property name'

    $numberAtLimit = '{"session_id":"number-1024","n":' + '1' + ('0' * 1023) + '}'
    Assert-ParserProbe -StdinText $numberAtLimit -Expected '1|number-1024|0' -Label 'Direct parser with a 1,024-character number'
    $numberOverLimit = '{"session_id":"number-1025","n":' + '1' + ('0' * 1024) + '}'
    Assert-ParserProbe -StdinText $numberOverLimit -Expected 'PARSE_ERROR' -Label 'Direct parser with a 1,025-character number'

    Assert-ParserProbe -StdinText (New-ValueBudgetInput -SessionId 'values-4096' -ArrayElements 4094) -Expected '1|values-4096|0' -Label 'Direct parser with exactly 4,096 JSON values'
    Assert-ParserProbe -StdinText (New-ValueBudgetInput -SessionId 'values-4097' -ArrayElements 4095) -Expected 'PARSE_ERROR' -Label 'Direct parser with 4,097 JSON values'

    Assert-ParserProbe -StdinText (New-NestedArrayInput -SessionId 'depth-127' -JsonDepth 127) -Expected '1|depth-127|0' -Label 'Direct parser at JSON container depth 127'
    Assert-ParserProbe -StdinText (New-NestedArrayInput -SessionId 'depth-128' -JsonDepth 128) -Expected '1|depth-128|0' -Label 'Direct parser at JSON container depth 128 with a scalar leaf'
    Assert-ParserProbe -StdinText (New-NestedArrayInput -SessionId 'depth-129' -JsonDepth 129) -Expected 'PARSE_ERROR' -Label 'Direct parser at JSON container depth 129'
}

Add-Case 'session-start-rejects-invalid-utf8-without-side-effects' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    $oldMarker = Set-Marker -DevlogRoot $caseRoot -SessionId 'keep-invalid-utf8-stale' -Content '1000'
    (Get-Item -LiteralPath $oldMarker).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    $invalidSamples = @(
        @{ Name = 'invalid-lead'; Bytes = [byte[]]@(0xFF) },
        @{ Name = 'overlong'; Bytes = [byte[]]@(0xC0, 0xAF) },
        @{ Name = 'utf8-surrogate'; Bytes = [byte[]]@(0xED, 0xA0, 0x80) },
        @{ Name = 'above-unicode-max'; Bytes = [byte[]]@(0xF4, 0x90, 0x80, 0x80) },
        @{ Name = 'truncated'; Bytes = [byte[]]@(0xE2, 0x82) }
    )
    foreach ($sample in $invalidSamples) {
        $stdinBytes = New-InvalidUtf8InputBytes -SessionId $syntheticPrivateSentinel -InvalidBytes $sample.Bytes
        $result = Invoke-Hook -HookPath $hookSessionStart -StdinBytes $stdinBytes -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
        $label = 'SessionStart with invalid UTF-8 form ' + $sample.Name
        Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningJa -Label $label -SensitiveNeedles @($syntheticPrivateSentinel)
        Assert-Condition (Test-Path -LiteralPath $oldMarker) "$label must not prune an existing marker."
    }
}

Add-Case 'session-start-en-language' {
    $caseRoot = New-CaseRoot
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{"session_id":"lang-en"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot; CLAUDE_DEVLOG_LANG = 'en' }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains('Dev journal routine')) 'CLAUDE_DEVLOG_LANG=en should switch the context to English.'
    Assert-Condition (-not $json.hookSpecificOutput.additionalContext.Contains($jaNeedle)) 'English context should not contain the Japanese needle.'
}

Add-Case 'session-start-unjudgeable-en-language' {
    $caseRoot = New-CaseRoot -LeaveMissing
    $result = Invoke-Hook -HookPath $hookSessionStart -StdinText '{}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot; CLAUDE_DEVLOG_LANG = 'en' }

    Assert-UnjudgeableSessionStart -Result $result -DevlogRoot $caseRoot -ExpectedWarning $identityWarningEn -Label 'English SessionStart without a session_id'
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains('Dev journal routine')) 'English unjudgeable context should keep the English routine.'
    Assert-Condition (-not $json.hookSpecificOutput.additionalContext.Contains($identityWarningJa)) 'English unjudgeable context should not contain the Japanese identity warning.'
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $caseRoot '.devlog-markers'))) 'English unjudgeable input must not create a marker directory.'
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
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1","":0}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
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

Add-Case 'nudge-silent-with-empty-session-id' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 'unknown' -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":""}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with an empty session_id'
}

Add-Case 'nudge-silent-with-non-string-session-id' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId '123' -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":123}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with a non-string session_id'
}

Add-Case 'nudge-silent-on-malformed-stdin' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with malformed stdin'
}

Add-Case 'nudge-silent-on-array-root' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId $syntheticPrivateSentinel -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '[{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}]' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with an array root'
}

Add-Case 'nudge-silent-on-case-alias-session-id' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId $syntheticPrivateSentinel -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"SESSION_ID":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with a case-alias session field'
}

Add-Case 'nudge-silent-on-duplicate-session-id' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId $syntheticPrivateSentinel -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $stdin = '{"session_id":"first","session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT"}'
    $result = Invoke-Hook -HookPath $hookNudge -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with a duplicate session field'
}

Add-Case 'nudge-silent-on-session-id-case-collision' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId $syntheticPrivateSentinel -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $stdin = '{"session_id":"SYNTHETIC_PRIVATE_VALUE_DO_NOT_REFLECT","SESSION_ID":"alias"}'
    $result = Invoke-Hook -HookPath $hookNudge -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with a session field case collision'
}

Add-Case 'nudge-silent-on-non-rfc-json-extensions' {
    foreach ($sample in $strictNonJsonSamples) {
        $caseRoot = New-CaseRoot -WithMarkerDir
        Set-Marker -DevlogRoot $caseRoot -SessionId $syntheticPrivateSentinel -Content "$((Get-NowEpoch) - 2000)" | Out-Null
        $result = Invoke-Hook -HookPath $hookNudge -StdinText $sample.Text -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
        Assert-Allowed -Result $result -Label ('Nudge with non-RFC JSON extension ' + $sample.Name)
    }
}

Add-Case 'nudge-silent-on-embedded-nul' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId $syntheticPrivateSentinel -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $stdinBytes = New-EmbeddedNulInputBytes -SessionId $syntheticPrivateSentinel
    $result = Invoke-Hook -HookPath $hookNudge -StdinBytes $stdinBytes -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with embedded NUL'
}

Add-Case 'nudge-silent-on-literal-escaped-unicode-unknown-duplicate' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId $syntheticPrivateSentinel -Content "$((Get-NowEpoch) - 2000)" | Out-Null
    $eAcute = [string][char]0x00E9
    $stdin = '{"session_id":"' + $syntheticPrivateSentinel + '","' + $eAcute + '":1,"\u00e9":2}'
    $result = Invoke-Hook -HookPath $hookNudge -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with literal/escaped Unicode unknown duplicate'
}

Add-Case 'nudge-silent-on-corrupt-marker' {
    foreach ($sample in @(
        @{ Name = 'non-decimal'; Content = 'not-a-number' },
        @{ Name = 'leading-zero'; Content = '0123456789' }
    )) {
        $caseRoot = New-CaseRoot -WithMarkerDir
        Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content $sample.Content | Out-Null
        $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
        Assert-Allowed -Result $result -Label ('Nudge with a corrupt marker: ' + $sample.Name)
    }
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
    Assert-ParserProbe -StdinText '{"session_id":null,"stop_hook_active":true}' -Expected '0||1' -Label 'Direct parser with null session and active Stop guard'
}

Add-Case 'stop-allows-without-session-id' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop without a session_id'
}

Add-Case 'stop-allows-with-empty-session-id' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 'unknown' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":""}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with an empty session_id'
}

Add-Case 'stop-allows-with-non-string-session-id' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId '123' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":123}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with a non-string session_id'
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
    foreach ($sample in @(
        @{ Name = '19-byte-decimal'; Content = ('9' * 19) },
        @{ Name = 'one-megabyte'; Content = ('9' * 1048576) }
    )) {
        $caseRoot = New-CaseRoot -WithMarkerDir
        Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content $sample.Content | Out-Null
        $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
        Assert-Allowed -Result $result -Label ('Stop with an oversized marker: ' + $sample.Name)
    }
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

Add-Case 'stop-allows-on-array-root' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '[{"session_id":"s1"}]' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with an array root'
}

Add-Case 'stop-ignores-case-alias-stop-hook-active' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1","STOP_HOOK_ACTIVE":true}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.decision -eq 'block') 'A case-alias stop field must not activate the loop guard.'
}

Add-Case 'stop-allows-on-duplicate-stop-hook-active' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $stdin = '{"session_id":"s1","stop_hook_active":true,"stop_hook_active":false}'
    $result = Invoke-Hook -HookPath $hookStop -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with a duplicate loop-guard field'
}

Add-Case 'stop-allows-on-stop-hook-active-case-collision' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $stdin = '{"session_id":"s1","stop_hook_active":false,"STOP_HOOK_ACTIVE":true}'
    $result = Invoke-Hook -HookPath $hookStop -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with a loop-guard field case collision'
}

Add-Case 'stop-allows-on-duplicate-unknown-field' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $stdin = '{"session_id":"s1","metadata":1,"metadata":2}'
    $result = Invoke-Hook -HookPath $hookStop -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with a duplicate unknown field'
}

Add-Case 'stop-allows-on-unknown-field-case-collision' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $stdin = '{"session_id":"s1","metadata":1,"METADATA":2}'
    $result = Invoke-Hook -HookPath $hookStop -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with an unknown field case collision'
}

Add-Case 'stop-allows-on-non-rfc-json-extensions' {
    foreach ($sample in $strictNonJsonSamples) {
        $caseRoot = New-CaseRoot -WithMarkerDir
        Set-Marker -DevlogRoot $caseRoot -SessionId $syntheticPrivateSentinel -Content "$((Get-NowEpoch) - 100)" | Out-Null
        $result = Invoke-Hook -HookPath $hookStop -StdinText $sample.Text -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
        Assert-Allowed -Result $result -Label ('Stop with non-RFC JSON extension ' + $sample.Name)
    }
}

Add-Case 'stop-allows-on-embedded-nul' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId $syntheticPrivateSentinel -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $stdinBytes = New-EmbeddedNulInputBytes -SessionId $syntheticPrivateSentinel
    $result = Invoke-Hook -HookPath $hookStop -StdinBytes $stdinBytes -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with embedded NUL'
}

Add-Case 'stop-blocks-with-distinct-non-ascii-case-pair' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $upperAumlaut = [string][char]0x00C4
    $lowerAumlaut = [string][char]0x00E4
    $stdin = '{"session_id":"s1","' + $upperAumlaut + '":1,"' + $lowerAumlaut + '":2}'
    $result = Invoke-Hook -HookPath $hookStop -StdinText $stdin -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    $json = ConvertFrom-HookStdout -Bytes $result.StdoutBytes
    Assert-Condition ($json.decision -eq 'block') 'Distinct non-ASCII case-pair fields must not invalidate a normal Stop block.'
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
    Assert-Condition ($json.hookSpecificOutput.additionalContext.Contains($warningSign)) 'Context should disclose that enforcement is off.'
}

Add-Case 'stop-allows-on-directory-marker' {
    # A directory occupying the marker path makes the marker read fail; the
    # hook must allow with nothing on stdout OR stderr.
    $caseRoot = New-CaseRoot -WithMarkerDir
    New-Item -ItemType Directory -Path (Get-MarkerPath -DevlogRoot $caseRoot -SessionId 's1') | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Stop with a directory where the marker should be'
}

Add-Case 'nudge-silent-on-directory-marker' {
    $caseRoot = New-CaseRoot -WithMarkerDir
    New-Item -ItemType Directory -Path (Get-MarkerPath -DevlogRoot $caseRoot -SessionId 's1') | Out-Null
    $result = Invoke-Hook -HookPath $hookNudge -StdinText '{"session_id":"s1"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
    Assert-Allowed -Result $result -Label 'Nudge with a directory where the marker should be'
}

Add-Case 'stop-blocks-when-stop-hook-active-is-string-false' {
    # The spec sends stop_hook_active as a boolean. A defensive string value
    # "false" must not be treated as truthy (which would skip enforcement).
    $caseRoot = New-CaseRoot -WithMarkerDir
    Set-Marker -DevlogRoot $caseRoot -SessionId 's1' -Content "$((Get-NowEpoch) - 100)" | Out-Null
    $result = Invoke-Hook -HookPath $hookStop -StdinText '{"session_id":"s1","":0,"stop_hook_active":"false"}' -ChildEnvironment @{ CLAUDE_DEVLOG_DIR = $caseRoot }
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
        # Include multi-byte UTF-8 beside JSON syntax and C0 bytes. This catches
        # Bash 3.2 signed-byte corruption without making this .ps1 non-ASCII.
        $segment = 'json-' + $jaNeedle + '-' + $journalEmoji + '-' + $warningSign + '-"quote"-\backslash-' + [char]0x09 + 'tab-' + [char]0x0A + 'newline-' + [char]0x01 + 'control'
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
        Assert-Condition (Test-Path -LiteralPath (Get-MarkerPath -DevlogRoot $caseRoot -SessionId 'json-session')) 'SessionStart should write its marker under the special-character path.'

        # POSIX can expose non-UTF-8 environment bytes that .NET strings cannot
        # construct directly. A wrapper injects one under a synthetic parent;
        # the hook must fail open before output or filesystem mutation.
        $invalidParent = New-CaseRoot
        $invalidRootWrapper = Join-Path $tempRoot 'invalid-root-wrapper.sh'
        $invalidRootSource = @'
#!/usr/bin/env bash
invalid_byte=$(printf '\377')
export CLAUDE_DEVLOG_DIR="${DEVLOG_INVALID_PARENT}/${invalid_byte}"
exec bash "$DEVLOG_TEST_REPO_ROOT/hooks/devlog-session-start.sh"
'@
        [System.IO.File]::WriteAllText($invalidRootWrapper, ($invalidRootSource -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $invalidRootResult = Invoke-Hook -HookPath $invalidRootWrapper -DirectScript -StdinText '{"session_id":"invalid-root"}' -ChildEnvironment @{ DEVLOG_INVALID_PARENT = $invalidParent; DEVLOG_TEST_REPO_ROOT = $root }
        Assert-Allowed -Result $invalidRootResult -Label 'Bash SessionStart with a non-UTF-8 root'
        Assert-Condition (@(Get-ChildItem -LiteralPath $invalidParent -Force).Count -eq 0) 'A non-UTF-8 root must not create marker or journal state.'
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
    $expectedCaseCount = if ($isBashHook -and $env:OS -ne 'Windows_NT') { 68 } else { 65 }
    Assert-Condition ($cases.Count -eq $expectedCaseCount) "Hook suite case count drifted: expected $expectedCaseCount, got $($cases.Count)."
    $selectedCases = New-Object System.Collections.Generic.List[object]
    foreach ($candidateCase in $cases) {
        if ([string]::IsNullOrWhiteSpace($CaseName) -or $candidateCase.Name -ceq $CaseName) {
            $selectedCases.Add($candidateCase) | Out-Null
        }
    }
    Assert-Condition ($selectedCases.Count -gt 0) "No hook case matched -CaseName '$CaseName'."
    foreach ($case in $selectedCases) {
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
    Write-Host "Hook pipe-test failed ($($failures.Count) of $($selectedCases.Count) selected cases):"
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host ''
Write-Host "Hook pipe-test passed ($($selectedCases.Count) selected of $($cases.Count) total cases) with $shellPath."
exit 0
