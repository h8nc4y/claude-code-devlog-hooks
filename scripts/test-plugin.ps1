# Static contract tests for the Claude Code plugin package.
#
# The suite intentionally does not install or load the plugin. It validates the
# checked-in package shape with synthetic assertions that also run on Windows
# PowerShell 5.1.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure([string]$Message) {
    $failures.Add($Message) | Out-Null
}

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        Add-Failure $Message
    }
}

function Get-PropertyNames($Object) {
    if ($null -eq $Object) {
        return @()
    }
    return @($Object.PSObject.Properties.Name)
}

function Read-Utf8Text([string]$Path) {
    # Windows PowerShell 5.1 treats a BOM-less UTF-8 file as the active ANSI
    # code page. JSON is UTF-8 by contract, so decode it explicitly and fail
    # on invalid bytes instead of letting localized status text become mojibake.
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return [System.IO.File]::ReadAllText($Path, $utf8)
}

function Read-JsonFile([string]$RelativePath) {
    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Failure "Missing required plugin file: $RelativePath"
        return $null
    }

    try {
        return (Read-Utf8Text -Path $path | ConvertFrom-Json)
    }
    catch {
        Add-Failure "Invalid JSON in ${RelativePath}: $($_.Exception.Message)"
        return $null
    }
}

function Assert-GitExecutable([string]$RelativePath) {
    # Windows filesystems do not expose the Unix execute bit reliably. The Git
    # index mode is the portable contract that determines a Linux/macOS
    # checkout, so inspect it directly instead of trusting Test-Path.
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Add-Failure "Cannot verify executable mode without git: $RelativePath"
        return
    }

    $entry = @(& $git.Source -C $repoRoot ls-files --stage -- $RelativePath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $entry.Count -ne 1) {
        Add-Failure "Cannot resolve one Git index entry for: $RelativePath"
        return
    }

    $mode = ([string]$entry[0] -split '\s+')[0]
    Assert-Condition ($mode -eq '100755') "$RelativePath must be executable in the Git index (got $mode)."
}

$manifest = Read-JsonFile '.claude-plugin/plugin.json'
$hookConfig = Read-JsonFile 'hooks/hooks.json'
$launcherPath = Join-Path $repoRoot 'hooks/devlog-plugin-launcher.sh'
$skillPath = Join-Path $repoRoot 'SKILL.md'
$skillsDirectory = Join-Path $repoRoot 'skills'

Assert-Condition (Test-Path -LiteralPath $launcherPath -PathType Leaf) 'Missing shared plugin launcher.'
Assert-Condition (Test-Path -LiteralPath $skillPath -PathType Leaf) 'Root SKILL.md must remain the plugin skill.'
Assert-Condition (-not (Test-Path -LiteralPath $skillsDirectory -PathType Container)) 'Single root skill contract must not add a skills directory.'
Assert-GitExecutable 'hooks/devlog-plugin-launcher.sh'
Assert-GitExecutable 'scripts/test-plugin-launcher.sh'

if ($null -ne $manifest) {
    Assert-Condition ($manifest.name -eq 'claude-code-devlog-hooks') 'Manifest name must be claude-code-devlog-hooks.'
    Assert-Condition ($manifest.version -eq '0.2.0') 'Manifest version must be 0.2.0.'
    Assert-Condition ($manifest.hooks -eq './hooks/hooks.json') 'Manifest must point to the reviewed hooks/hooks.json.'
    Assert-Condition (-not ((Get-PropertyNames $manifest) -contains 'skills')) 'Root skill discovery must not be replaced by a custom skills path.'

    $configNames = Get-PropertyNames $manifest.userConfig
    Assert-Condition ($configNames.Count -eq 2) 'Manifest must expose exactly two userConfig options.'
    Assert-Condition ($configNames -contains 'devlog_dir') 'Manifest must expose devlog_dir.'
    Assert-Condition ($configNames -contains 'devlog_lang') 'Manifest must expose devlog_lang.'
    if ($configNames -contains 'devlog_dir') {
        Assert-Condition ($manifest.userConfig.devlog_dir.type -eq 'directory') 'devlog_dir must use the directory type.'
        Assert-Condition (-not $manifest.userConfig.devlog_dir.sensitive) 'devlog_dir must not be marked as a secret.'
    }
    if ($configNames -contains 'devlog_lang') {
        Assert-Condition ($manifest.userConfig.devlog_lang.type -eq 'string') 'devlog_lang must use the string type.'
        Assert-Condition (-not $manifest.userConfig.devlog_lang.sensitive) 'devlog_lang must not be marked as a secret.'
    }
}

if ($null -ne $hookConfig) {
    $expectedEvents = @('SessionStart', 'UserPromptSubmit', 'Stop')
    $eventNames = Get-PropertyNames $hookConfig.hooks
    Assert-Condition ($eventNames.Count -eq $expectedEvents.Count) 'hooks.json must register exactly three events.'
    foreach ($eventName in $expectedEvents) {
        Assert-Condition ($eventNames -contains $eventName) "hooks.json is missing $eventName."
    }

    $expectedArguments = @{
        SessionStart = 'session-start'
        UserPromptSubmit = 'prompt-nudge'
        Stop = 'stop'
    }
    $expectedStatus = @{
        SessionStart = [string]([char]0x958b) + [char]0x767a + [char]0x30ed + [char]0x30b0
        UserPromptSubmit = [string]([char]0x958b) + [char]0x767a + [char]0x30ed + [char]0x30b0
        Stop = [string]([char]0x958b) + [char]0x767a + [char]0x30ed + [char]0x30b0
    }

    foreach ($eventName in $expectedEvents) {
        if (-not ($eventNames -contains $eventName)) {
            continue
        }

        $groups = @($hookConfig.hooks.$eventName)
        Assert-Condition ($groups.Count -eq 1) "$eventName must have exactly one matcher group."
        if ($groups.Count -ne 1) {
            continue
        }

        Assert-Condition (-not ((Get-PropertyNames $groups[0]) -contains 'matcher')) "$eventName must keep the matcher omitted."
        $handlers = @($groups[0].hooks)
        Assert-Condition ($handlers.Count -eq 1) "$eventName must have exactly one runtime handler."
        if ($handlers.Count -ne 1) {
            continue
        }

        $handler = $handlers[0]
        $expectedCommand = '"${CLAUDE_PLUGIN_ROOT}"/hooks/devlog-plugin-launcher.sh ' + $expectedArguments[$eventName]
        Assert-Condition ($handler.type -eq 'command') "$eventName must use a command hook."
        Assert-Condition ($handler.shell -eq 'bash') "$eventName must use Claude Code's selected Bash shell."
        Assert-Condition ($handler.command -eq $expectedCommand) "$eventName must invoke the fixed, quoted plugin-root launcher."
        Assert-Condition (-not ((Get-PropertyNames $handler) -contains 'args')) "$eventName must not spawn an arbitrary PATH bash in exec form."
        Assert-Condition ($handler.timeout -eq 15) "$eventName timeout must be 15 seconds."
        Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handler.statusMessage)) "$eventName must declare a statusMessage."
        Assert-Condition ([string]$handler.statusMessage -like ($expectedStatus[$eventName] + '*')) "$eventName statusMessage must be Japanese."
    }
}

foreach ($relativePath in @('.claude-plugin/plugin.json', 'hooks/hooks.json')) {
    $path = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        continue
    }
    $raw = Read-Utf8Text -Path $path
    Assert-Condition ($raw -notmatch '\$\{user_config\.') "$relativePath must not interpolate userConfig into command text."
    Assert-Condition ($raw -notmatch '(?i)(?:[A-Z]:[\\/](?:Users|Agent)[\\/]|/(?:Users|home)/)') "$relativePath must not contain a local absolute path."
    Assert-Condition ($raw -notmatch '(?i)(?:sk-[a-z0-9_-]{8,}|api[_-]?key\s*[:=])') "$relativePath must not contain a secret-like value."
}

if ($failures.Count -gt 0) {
    Write-Error ("Plugin contract test failed ({0}):`n- {1}" -f $failures.Count, ($failures -join "`n- "))
    exit 1
}

Write-Host 'Plugin contract test passed (manifest, root skill, and three hook registrations).'
