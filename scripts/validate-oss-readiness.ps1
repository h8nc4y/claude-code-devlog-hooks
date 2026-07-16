[CmdletBinding()]
param(
    [string]$Path = ''
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
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Get-RepoFilePath {
    param([string]$RelativePath)
    return Join-Path $root $RelativePath
}

function Assert-FileExists {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Missing required file: $RelativePath"
    }
}

function Assert-FileContains {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    $content = Get-Content -LiteralPath $filePath -Raw
    if ($content -notmatch $Pattern) {
        Add-Failure "$RelativePath is missing: $Description"
    }
}

function Assert-FileNotContains {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    $content = Get-Content -LiteralPath $filePath -Raw
    if ($content -match $Pattern) {
        Add-Failure "$RelativePath must not contain: $Description"
    }
}

function Assert-HookFile {
    # Hooks must be parameterized (no machine-specific absolute paths), keep
    # the fail-open contract, and carry a UTF-8 BOM so Windows PowerShell 5.1
    # parses their non-ASCII message text correctly.
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return   # Assert-FileExists already reported it.
    }

    Assert-FileContains -RelativePath $RelativePath -Pattern 'CLAUDE_DEVLOG_DIR' -Description 'devlog root resolution via CLAUDE_DEVLOG_DIR'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'Write-Utf8Stdout' -Description 'UTF-8 byte output helper'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'exit 0' -Description 'fail-open exit'
    # A drive-letter path would mean a machine-specific path slipped back
    # in; the hooks are placeholder-free by design. (Single-quoted string:
    # the regex engine receives \r \n as CR/LF classes, not letters.)
    Assert-FileNotContains -RelativePath $RelativePath -Pattern '[A-Za-z]:\\[^\r\n]*\\' -Description 'hardcoded absolute Windows paths'

    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        Add-Failure "$RelativePath must start with a UTF-8 BOM (required for Windows PowerShell 5.1)."
    }
}

function Test-SkillFrontmatter {
    $skillPath = Get-RepoFilePath -RelativePath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        return
    }

    $lines = Get-Content -LiteralPath $skillPath
    if ($lines.Count -lt 4 -or $lines[0] -ne '---') {
        Add-Failure 'SKILL.md must start with YAML frontmatter.'
        return
    }

    $closingIndex = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq '---') {
            $closingIndex = $index
            break
        }
    }

    if ($closingIndex -lt 0) {
        Add-Failure 'SKILL.md frontmatter must be closed with --- before content.'
        return
    }

    $frontmatter = $lines[1..($closingIndex - 1)] -join "`n"
    if ($frontmatter -notmatch '(?m)^name:\s*claude-code-devlog-hooks\s*$') {
        Add-Failure 'SKILL.md frontmatter must declare name: claude-code-devlog-hooks.'
    }
    if ($frontmatter -notmatch '(?m)^description:\s*\S') {
        Add-Failure 'SKILL.md frontmatter must include a non-empty description.'
    }
    if ($frontmatter.Length -gt 1024) {
        Add-Failure 'SKILL.md frontmatter must stay under 1024 characters.'
    }
}

function Test-ExampleSettings {
    $settingsPath = Get-RepoFilePath -RelativePath 'examples/hooks-settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return   # Assert-FileExists already reported it.
    }

    $parsed = $null
    try {
        $parsed = (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json)
    } catch {
        Add-Failure 'examples/hooks-settings.json must be valid JSON.'
        return
    }

    foreach ($eventName in @('SessionStart', 'Stop', 'UserPromptSubmit')) {
        if ($null -eq ($parsed.hooks.PSObject.Properties[$eventName])) {
            Add-Failure "examples/hooks-settings.json must register the $eventName event."
        }
    }
}

$requiredFiles = @(
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/config.yml',
    '.github/pull_request_template.md',
    '.github/workflows/validate.yml',
    'CHANGELOG.md',
    'CODE_OF_CONDUCT.md',
    'CONTRIBUTING.md',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'SKILL.md',
    'docs/SKILL.ja.md',
    'docs/hook-engineering.md',
    'examples/hooks-settings.json',
    'examples/journal-entry-template.md',
    'hooks/devlog-session-start.ps1',
    'hooks/devlog-prompt-nudge.ps1',
    'hooks/devlog-stop.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-hooks.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)

foreach ($requiredFile in $requiredFiles) {
    Assert-FileExists -RelativePath $requiredFile
}

Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Install' -Description 'installation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Uninstall' -Description 'uninstall instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Validation' -Description 'validation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Contributing' -Description 'contribution guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Security' -Description 'security reporting guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern 'CONTRIBUTING\.md' -Description 'link to CONTRIBUTING.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'SECURITY\.md' -Description 'link to SECURITY.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'docs/SKILL\.ja\.md' -Description 'link to the Japanese skill version'
Assert-FileContains -RelativePath 'README.md' -Pattern 'docs/hook-engineering\.md' -Description 'link to the hook engineering notes'
Assert-FileContains -RelativePath 'README.md' -Pattern 'CLAUDE_DEVLOG_DIR' -Description 'devlog root configuration variable'
Assert-FileContains -RelativePath '.gitignore' -Pattern '\.private-markers\.local' -Description 'ignore local private marker files'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern '(?im)no token|never.*token|secret' -Description 'secret-safe contribution guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?im)do not.*public|private|security' -Description 'private vulnerability reporting guidance'
Assert-FileContains -RelativePath 'CHANGELOG.md' -Pattern '0\.1\.0' -Description 'v0.1.0 release notes'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'validate-oss-readiness\.ps1' -Description 'OSS readiness validation in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'scan-private-markers\.ps1' -Description 'private marker scan in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'test-scan-private-markers\.ps1' -Description 'private marker scan self-test in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'test-hooks\.ps1' -Description 'hook pipe-test in CI'

Assert-HookFile -RelativePath 'hooks/devlog-session-start.ps1'
Assert-HookFile -RelativePath 'hooks/devlog-prompt-nudge.ps1'
Assert-HookFile -RelativePath 'hooks/devlog-stop.ps1'

Test-SkillFrontmatter
Test-ExampleSettings

if ($failures.Count -gt 0) {
    Write-Host 'OSS readiness validation failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host "OSS readiness validation passed for $root"
exit 0
