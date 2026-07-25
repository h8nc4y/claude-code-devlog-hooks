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
    $Path = [System.IO.Path]::GetDirectoryName($scriptRoot)
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

$firstInvocationPolicyRelativePath =
    'scripts/private-marker-first-invocation-policy.ps1'
$firstInvocationPolicyPath = Get-RepoFilePath `
    -RelativePath $firstInvocationPolicyRelativePath
if (Test-Path -LiteralPath $firstInvocationPolicyPath -PathType Leaf) {
    try {
        . $firstInvocationPolicyPath
    }
    catch {
        Add-Failure (
            "Cannot load first-invocation policy: " +
            "$($_.Exception.Message)"
        )
    }
}
else {
    Add-Failure (
        "Missing required file: $firstInvocationPolicyRelativePath"
    )
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

function Assert-FileHasUtf8Bom {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (UTF-8 BOM contract)"
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -lt 3 -or
        $bytes[0] -ne 0xEF -or
        $bytes[1] -ne 0xBB -or
        $bytes[2] -ne 0xBF) {
        Add-Failure "$RelativePath must keep a UTF-8 BOM because Windows PowerShell 5.1 executes its Japanese comments."
    }
}

function Assert-FirstTopLevelProcessInvocationIsBinary {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (first process invocation contract)"
        return
    }

    $policyCommand = Get-Command `
        Test-FirstPrivateMarkerProcessInvocationIsBinaryTransport `
        -CommandType Function `
        -ErrorAction SilentlyContinue
    if ($null -eq $policyCommand) {
        Add-Failure (
            "$RelativePath cannot verify its first process invocation " +
            'because the shared AST policy did not load.'
        )
        return
    }
    try {
        $source = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        Add-Failure (
            "$RelativePath must be valid UTF-8 for its first process " +
            'invocation contract.'
        )
        return
    }

    # self-testとreadinessで同じpure policyを使い、direct/transitive wrapper、
    # alias、scope付きcall、function object、dynamic resolutionを同時に閉じる。
    if (-not (Test-FirstPrivateMarkerProcessInvocationIsBinaryTransport `
        -Source $source `
        -RequiredOuterCommandPattern `
            '(?s)-StandardInputBytes\s+\$binaryProbeBytes\b')) {
        Add-Failure "$RelativePath must use the exact binary fixture for its first top-level bounded-process invocation."
    }
}

function Assert-FirstInvocationPolicyValidatorRegressions {
    $policyCommand = Get-Command `
        Test-FirstPrivateMarkerProcessInvocationIsBinaryTransport `
        -CommandType Function `
        -ErrorAction SilentlyContinue
    if ($null -eq $policyCommand) {
        return
    }

    # readiness単体でもreviewで再現したnamed/transitive/alias/function-object迂回と、
    # native Application lookupの安全側を固定する。
    $validSource = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$gitCommand = Get-Command git -CommandType Application
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
    $cases = @(
        [pscustomobject]@{
            Name = 'valid-native-application-lookup'
            Expected = $true
            Source = $validSource
        },
        [pscustomobject]@{
            Name = 'wrapped-script-scope-target-function-shadow'
            Expected = $false
            Source = @'
function Set-EarlyHelper {
    function script:Invoke-PrivateMarkerProcess {
        return 'shadow'
    }
}
Set-EarlyHelper
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-wrapped-local-target-function'
            Expected = $true
            Source = @'
function Set-LocalHelper {
    function Invoke-PrivateMarkerProcess {
        return 'local-only'
    }
}
Set-LocalHelper
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-script-scope-target-alias-shadow'
            Expected = $false
            Source = @'
function Set-EarlyHelper {
    Set-Alias Invoke-PrivateMarkerProcess Write-Output -Scope Script
}
Set-EarlyHelper
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-abbreviated-script-scope-target-alias-shadow'
            Expected = $false
            Source = @'
function Set-EarlyHelper {
    Set-Alias Invoke-PrivateMarkerProcess Write-Output -S Script
}
Set-EarlyHelper
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'typed-script-scope-target-alias-shadow'
            Expected = $false
            Source = @'
class EarlyHelperShadow {
    static [void] SetAlias() {
        Set-Alias Invoke-PrivateMarkerProcess Write-Output -Scope Script
    }
}
[EarlyHelperShadow]::SetAlias()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-wrapped-local-target-alias'
            Expected = $true
            Source = @'
function Set-LocalHelper {
    Set-Alias Invoke-PrivateMarkerProcess Write-Output -Scope Local
}
Set-LocalHelper
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-called-wrapper-with-unused-scriptblock'
            Expected = $true
            Source = @'
function Save-Later {
    $later = { Invoke-PrivateMarkerProcess }
}
Save-Later
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'called-wrapper-exports-stored-scriptblock'
            Expected = $false
            Source = @'
function Save-Later {
    $script:later = { Invoke-PrivateMarkerProcess }
}
Save-Later
1 | ForEach-Object -Process $later
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'called-wrapper-passes-inline-assigned-scriptblock'
            Expected = $false
            Source = @'
function Invoke-Later {
    1 | ForEach-Object -Process ($later = {
        Invoke-PrivateMarkerProcess
    })
}
Invoke-Later
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'called-wrapper-reads-stored-scriptblock-through-provider'
            Expected = $false
            Source = @'
function Invoke-Later {
    $later = { Invoke-PrivateMarkerProcess }
    1 | ForEach-Object -Process (
        Get-Variable later -ValueOnly
    )
}
Invoke-Later
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'called-wrapper-invokes-stored-scriptblock'
            Expected = $false
            Source = @'
function Invoke-Later {
    $later = { Invoke-PrivateMarkerProcess }
    & $later
}
Invoke-Later
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-called-wrapper-with-unused-risky-type-scriptblock'
            Expected = $true
            Source = @'
class LaterRiskyType {
    LaterRiskyType() {
        Invoke-PrivateMarkerProcess
    }
}
function Save-LaterType {
    $later = { [LaterRiskyType]::new() }
}
Save-LaterType
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'called-wrapper-invokes-stored-risky-type-scriptblock'
            Expected = $false
            Source = @'
class LaterRiskyType {
    LaterRiskyType() {
        Invoke-PrivateMarkerProcess
    }
}
function Invoke-LaterType {
    $later = { [LaterRiskyType]::new() }
    & $later
}
Invoke-LaterType
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-default-path-initialization'
            Expected = $true
            Source = @'
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = [System.IO.Path]::GetDirectoryName($scriptRoot)
}
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-default-path-with-dormant-split-path-shadow'
            Expected = $true
            Source = @'
function Split-Path {
    './synthetic-root'
}
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = [System.IO.Path]::GetDirectoryName($scriptRoot)
}
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'untrusted-script-root-before-default-path'
            Expected = $false
            Source = @'
$scriptRoot = './synthetic-root'
if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = [System.IO.Path]::GetDirectoryName($scriptRoot)
}
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-script-root-before-default-path'
            Expected = $false
            Source = @'
function Set-EarlyScriptRoot {
    $script:scriptRoot = './synthetic-root'
}
$scriptRoot = $PSScriptRoot
Set-EarlyScriptRoot
if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = [System.IO.Path]::GetDirectoryName($scriptRoot)
}
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'pre-root-path-reassignment'
            Expected = $false
            Source = @'
$Path = './synthetic-root'
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-script-path-reassignment'
            Expected = $false
            Source = @'
function Set-EarlyPath {
    $script:Path = './synthetic-root'
}
Set-EarlyPath
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-called-local-path-binding'
            Expected = $true
            Source = @'
function Set-LocalPath {
    $Path = './local-only'
    return $Path
}
Set-LocalPath
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-get-variable-execution-context-psvariable-set'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    (Get-Variable ExecutionContext -ValueOnly).SessionState.PSVariable.Set(
        'script:root',
        './synthetic-root'
    )
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-index-mutation-does-not-bind-local-root'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $root[0] = 'synthetic-index-mutation'
    $rootReference = [ref]$root
    $rootReference.Value = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-member-mutation-does-not-bind-local-root'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $root.Value = 'synthetic-member-mutation'
    $rootReference = [ref]$root
    $rootReference.Value = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'named-wrapper'
            Expected = $false
            Source = $validSource.Replace(
                '$gitCommand = Get-Command git -CommandType Application',
                'Invoke-Early'
            )
        },
        [pscustomobject]@{
            Name = 'transitive-wrapper'
            Expected = $false
            Source = @'
function Invoke-Inner {
    Invoke-PrivateMarkerProcess
}
function Invoke-Outer {
    Invoke-Inner
}
Invoke-Outer
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'scoped-wrapper'
            Expected = $false
            Source = $validSource.Replace(
                '$gitCommand = Get-Command git -CommandType Application',
                'global:Invoke-Early'
            )
        },
        [pscustomobject]@{
            Name = 'risky-alias'
            Expected = $false
            Source = $validSource.Replace(
                '$gitCommand = Get-Command git -CommandType Application',
                "Set-Alias EarlyAlias Invoke-Early`nEarlyAlias"
            )
        },
        [pscustomobject]@{
            Name = 'function-object'
            Expected = $false
            Source = $validSource.Replace(
                '$gitCommand = Get-Command git -CommandType Application',
                '(Get-Command Invoke-Early).ScriptBlock.Invoke()'
            )
        },
        [pscustomobject]@{
            Name = 'dynamic-function-lookup'
            Expected = $false
            Source = $validSource.Replace(
                '$gitCommand = Get-Command git -CommandType Application',
                "`${name} = 'Invoke-Early'`n(Get-Command `${name}).ScriptBlock.Invoke()"
            )
        },
        [pscustomobject]@{
            Name = 'invoke-expression-alias'
            Expected = $false
            Source = $validSource.Replace(
                '$gitCommand = Get-Command git -CommandType Application',
                "Set-Alias Run-Early Invoke-Expression`nRun-Early 'Invoke-Early'"
            )
        },
        [pscustomobject]@{
            Name = 'alias-provider-mutation'
            Expected = $false
            Source = $validSource.Replace(
                '$gitCommand = Get-Command git -CommandType Application',
                "Set-Item Alias:EarlyAlias Invoke-Early`nEarlyAlias"
            )
        },
        [pscustomobject]@{
            Name = 'target-alias-provider-shadow'
            Expected = $false
            Source = @'
Set-Item Alias:Invoke-PrivateMarkerProcess Write-Output
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'set-content-risky-alias-provider'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
Set-Content Alias:EarlyAlias Invoke-Early
EarlyAlias
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-dot-source'
            Expected = $false
            Source = $validSource.Replace(
                '$gitCommand = Get-Command git -CommandType Application',
                "`${name} = 'Invoke-Early'`n. `${name}"
            )
        },
        [pscustomobject]@{
            Name = 'allowed-process-boundary-bootstrap-dot-source'
            Expected = $true
            Source = @'
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-first-invocation-policy-bootstrap-dot-source'
            Expected = $true
            Source = @'
$root = [System.IO.Path]::GetFullPath($Path)
$firstInvocationPolicy = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-first-invocation-policy.ps1'
)
. $firstInvocationPolicy
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-bootstrap-with-dormant-instance-member-function'
            Expected = $true
            Source = @'
function Invoke-Later {
    $value.ToString()
}
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-bootstrap-with-dormant-root-assignment-function'
            Expected = $true
            Source = @'
function Set-LaterRoot {
    $root = './later'
}
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-bootstrap-with-dormant-instance-member-type'
            Expected = $true
            Source = @'
class LaterType {
    [string] Normalize([object]$value) {
        return $value.ToString()
    }
}
$root = [System.IO.Path]::GetFullPath($Path)
$firstInvocationPolicy = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-first-invocation-policy.ps1'
)
. $firstInvocationPolicy
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-bootstrap-after-called-local-root-function'
            Expected = $true
            Source = @'
function Read-LocalRoot {
    $root = 'local-only'
    return $root
}
$root = [System.IO.Path]::GetFullPath($Path)
Read-LocalRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-bootstrap-after-called-local-root-reference'
            Expected = $true
            Source = @'
function Read-LocalRoot {
    $root = 'local-only'
    $rootReference = [ref]$root
    $rootReference.Value = 'changed-locally'
    return $root
}
$root = [System.IO.Path]::GetFullPath($Path)
Read-LocalRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-bootstrap-after-unrelated-getvalue'
            Expected = $true
            Source = @'
function Read-Config {
    $config.GetValue('root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Read-Config
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-bootstrap-after-unrelated-setvalue'
            Expected = $true
            Source = @'
function Write-Config {
    $config.SetValue('root', 'local-only')
}
$root = [System.IO.Path]::GetFullPath($Path)
Write-Config
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-bootstrap-after-local-psvariable-set'
            Expected = $true
            Source = @'
function Set-LocalRoot {
    $ExecutionContext.SessionState.PSVariable.Set(
        'root',
        'local-only'
    )
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-LocalRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'allowed-bootstrap-after-safe-command-expression'
            Expected = $true
            Source = @'
function Set-LocalObject {
    $localObject = [pscustomobject]@{ Value = 'local-only' }
    $wrappedObject = Write-Output -NoEnumerate $localObject
    $wrappedObject.Value = 'updated-local-only'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-LocalObject
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'literal-bootstrap-dot-source'
            Expected = $false
            Source = @'
. './synthetic-early.ps1'
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'literal-bootstrap-ampersand'
            Expected = $false
            Source = @'
& './synthetic-early.ps1'
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'bare-relative-script-command'
            Expected = $false
            Source = @'
./synthetic-early.ps1
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'bare-script-name-command'
            Expected = $false
            Source = @'
synthetic-early.ps1
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-literal-bootstrap-dot-source'
            Expected = $false
            Source = @'
function Invoke-Early {
    . './synthetic-early.ps1'
}
Invoke-Early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-literal-bootstrap-ampersand'
            Expected = $false
            Source = @'
function Invoke-Early {
    & './synthetic-early.ps1'
}
Invoke-Early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'get-child-item-function-scriptblock-wrapper'
            Expected = $false
            Source = @'
function Invoke-Early {
    . './synthetic-early.ps1'
}
$early = (Get-ChildItem Function:Invoke-Early).ScriptBlock
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'function-shadowed-join-path-bootstrap'
            Expected = $false
            Source = @'
$root = [System.IO.Path]::GetFullPath($Path)
function Join-Path {
    './synthetic-early.ps1'
}
$processBoundary = Join-Path $root 'scripts/private-marker-process.ps1'
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'alias-shadowed-join-path-bootstrap'
            Expected = $false
            Source = @'
$root = [System.IO.Path]::GetFullPath($Path)
Set-Alias Join-Path Write-Output
$processBoundary = Join-Path $root 'scripts/private-marker-process.ps1'
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'reassigned-root-bootstrap-dot-source'
            Expected = $false
            Source = @'
$root = [System.IO.Path]::GetFullPath($Path)
$root = './synthetic-root'
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-reassigned-root-bootstrap-dot-source'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $script:root = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-psvariable-script-root-bootstrap-dot-source'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $ExecutionContext.SessionState.PSVariable.Set(
        'script:root',
        './synthetic-root'
    )
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-psvariable-root-handle-bootstrap-dot-source'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $rootVariable = $ExecutionContext.SessionState.PSVariable.Get('root')
    $rootVariable.Value = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-parenthesized-psvariable-root-handle'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $rootVariable = (
        $ExecutionContext.SessionState.PSVariable
    ).Get('root')
    $rootVariable.Value = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-deep-parenthesized-psvariable-root-handle'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $rootVariable = (((((((((((((((((((((((((((((((((((((($ExecutionContext.SessionState.PSVariable)))))))))))))))))))))))))))))))))))))))).Get('root')
    $rootVariable.Value = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-subexpression-psvariable-root-handle'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $rootVariable = $(
        $ExecutionContext.SessionState.PSVariable
    ).Get('root')
    $rootVariable.Value = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-array-indexed-psvariable-root-handle'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $rootVariable = @(
        $ExecutionContext.SessionState.PSVariable
    )[0].Get('root')
    $rootVariable.Value = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-cast-indexed-psvariable-root-handle'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $rootVariable = @(
        $ExecutionContext.SessionState.PSVariable
    )[[int]0].Get('root')
    $rootVariable.Value = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'execution-context-psvariable-return-wrapper-before'
            Expected = $false
            Source = @'
function Get-VariableTable {
    return $ExecutionContext.SessionState.PSVariable
}
function Set-EarlyRoot {
    (Get-VariableTable).Set('script:root', './synthetic-root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'execution-context-psvariable-array-getvalue-return-wrapper-before'
            Expected = $false
            Source = @'
function Get-VariableTable {
    return @(
        $ExecutionContext.SessionState.PSVariable
    ).GetValue(0)
}
function Set-EarlyRoot {
    (Get-VariableTable).Set('script:root', './synthetic-root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'execution-context-psvariable-cast-getvalue-return-wrapper-before'
            Expected = $false
            Source = @'
function Get-VariableTable {
    return (
        [object[]]$ExecutionContext.SessionState.PSVariable
    ).GetValue(0)
}
function Set-EarlyRoot {
    (Get-VariableTable).Set('script:root', './synthetic-root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'execution-context-psvariable-command-argument-before'
            Expected = $false
            Source = @'
function Pass-VariableTable {
    param($Table)
    return $Table
}
function Set-EarlyRoot {
    (Pass-VariableTable $ExecutionContext.SessionState.PSVariable).Set(
        'script:root',
        './synthetic-root'
    )
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'execution-context-psvariable-pipeline-before'
            Expected = $false
            Source = @'
function Pass-VariableTable {
    process {
        return $_
    }
}
function Set-EarlyRoot {
    ($ExecutionContext.SessionState.PSVariable |
        Pass-VariableTable).Set('script:root', './synthetic-root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'execution-context-psvariable-assignment-before'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $variableTable = $ExecutionContext.SessionState.PSVariable
    $variableTable.Set('script:root', './synthetic-root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-aliased-psvariable-script-root-bootstrap-dot-source'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $variableTable = $ExecutionContext.SessionState.PSVariable
    $variableTable.Set('script:root', './synthetic-root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-parenthesized-psvariable-table-alias'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $variableTable = ($ExecutionContext.SessionState.PSVariable)
    $variableTable.Set('script:root', './synthetic-root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-cast-psvariable-table-alias'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $variableTable = [object]$ExecutionContext.SessionState.PSVariable
    $variableTable.Set('script:root', './synthetic-root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-command-output-psvariable-table-alias'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $variableTable = Write-Output -NoEnumerate $ExecutionContext.SessionState.PSVariable
    $variableTable.Set('script:root', './synthetic-root')
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-global-execution-context-psvariable-set'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $global:ExecutionContext.SessionState.PSVariable.Set(
        'script:root',
        './synthetic-root'
    )
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-aliased-execution-context-psvariable-set'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $context = $ExecutionContext
    $context.SessionState.PSVariable.Set(
        'script:root',
        './synthetic-root'
    )
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-parameterized-execution-context-psvariable-set'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    param($context)
    $context.SessionState.PSVariable.Set(
        'script:root',
        './synthetic-root'
    )
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot $ExecutionContext
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-unbound-root-reference-bootstrap-dot-source'
            Expected = $false
            Source = @'
function Set-EarlyRoot {
    $rootReference = [ref]$root
    $rootReference.Value = './synthetic-root'
}
$root = [System.IO.Path]::GetFullPath($Path)
Set-EarlyRoot
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'tuple-reassigned-root-bootstrap-dot-source'
            Expected = $false
            Source = @'
$root = [System.IO.Path]::GetFullPath($Path)
$root, $discarded = './synthetic-root', $null
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'tuple-reassigned-bootstrap-dot-source'
            Expected = $false
            Source = @'
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
$processBoundary, $discarded = './synthetic-early.ps1', $null
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'psvariable-reassigned-root-bootstrap-dot-source'
            Expected = $false
            Source = @'
$root = [System.IO.Path]::GetFullPath($Path)
$ExecutionContext.SessionState.PSVariable.Set(
    'root',
    './synthetic-root'
)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'reference-reassigned-bootstrap-dot-source'
            Expected = $false
            Source = @'
$root = [System.IO.Path]::GetFullPath($Path)
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
$boundaryReference = [ref]$processBoundary
$boundaryReference.Value = './synthetic-early.ps1'
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-literal-dot-source'
            Expected = $false
            Source = @'
$early = { . './synthetic-early.ps1' }
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-literal-ampersand'
            Expected = $false
            Source = @'
$early = { & './synthetic-early.ps1' }
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-get-variable'
            Expected = $false
            Source = @'
$stored = { . './synthetic-early.ps1' }
$early = Get-Variable stored -ValueOnly
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-psvariable-get-value'
            Expected = $false
            Source = @'
$stored = { . './synthetic-early.ps1' }
$early = $ExecutionContext.SessionState.PSVariable.GetValue('stored')
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-stored-scriptblock-psvariable-get-value'
            Expected = $false
            Source = @'
function Get-StoredBlock {
    $ExecutionContext.SessionState.PSVariable.GetValue('stored')
}
$stored = { . './synthetic-early.ps1' }
1 | ForEach-Object -Process (Get-StoredBlock)
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'typed-stored-scriptblock-psvariable-get-value'
            Expected = $false
            Source = @'
class StoredBlockReader {
    [object] GetBlock() {
        return $ExecutionContext.SessionState.PSVariable.GetValue('stored')
    }
}
$stored = { . './synthetic-early.ps1' }
1 | ForEach-Object -Process ([StoredBlockReader]::new().GetBlock())
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'scriptblock-create-literal-dot-source'
            Expected = $false
            Source = @'
$early = [scriptblock]::Create(". './synthetic-early.ps1'")
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-type-scriptblock-create'
            Expected = $false
            Source = @'
$scriptBlockType = [scriptblock]
$early = $scriptBlockType::Create(". './synthetic-early.ps1'")
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-command-new-scriptblock-literal-ampersand'
            Expected = $false
            Source = @'
$early = $ExecutionContext.InvokeCommand.NewScriptBlock(
    "& './synthetic-early.ps1'"
)
1 | Where-Object -FilterScript $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'parser-get-scriptblock-literal-dot-source'
            Expected = $false
            Source = @'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    ". './synthetic-early.ps1'",
    [ref]$tokens,
    [ref]$errors
)
$early = $ast.GetScriptBlock()
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'get-command-external-script-scriptblock'
            Expected = $false
            Source = @'
$early = (
    Get-Command './synthetic-early.ps1' -CommandType ExternalScript
).ScriptBlock
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-command-intrinsics-get-command-scriptblock'
            Expected = $false
            Source = @'
$command = $ExecutionContext.InvokeCommand.GetCommand(
    './synthetic-early.ps1',
    [System.Management.Automation.CommandTypes]::ExternalScript
)
$early = $command.ScriptBlock
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'script-path-set-alias-wrapper'
            Expected = $false
            Source = @'
Set-Alias Invoke-Early './synthetic-early.ps1'
Invoke-Early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'script-path-new-alias-wrapper'
            Expected = $false
            Source = @'
New-Alias Invoke-Early './synthetic-early.ps1'
Invoke-Early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'set-variable-bootstrap-dot-source'
            Expected = $false
            Source = @'
$processBoundary = Join-Path $root 'scripts/private-marker-process.ps1'
Set-Variable processBoundary ./synthetic.ps1
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-script-member'
            Expected = $false
            Source = $validSource.Replace(
                '$gitCommand = Get-Command git -CommandType Application',
                "`$ExecutionContext.InvokeCommand.InvokeScript('Invoke-Early')"
            )
        },
        [pscustomobject]@{
            Name = 'new-object-risky-class'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
$early = New-Object EarlyClass
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'risky-class-conversion'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
$early = [EarlyClass]@{}
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'as-operator-class-constructor'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
$early = @{} -as [EarlyClass]
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'static-member-risky-class-provenance'
            Expected = $false
            Source = @'
class EarlyClass {
    static [EarlyClass] $Instance = [EarlyClass]::new()
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
$early = [EarlyClass]::Instance
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'target-function-provider-shadow'
            Expected = $false
            Source = @'
Set-Item Function:Invoke-PrivateMarkerProcess { 'shadow' }
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-new-item-target-function-shadow'
            Expected = $false
            Source = @'
$providerPath = 'Function:Invoke-PrivateMarkerProcess'
New-Item -Path $providerPath -ItemType Directory -Value { 'shadow' }
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-foreach-argument'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerProcess }
1 | ForEach-Object $stored
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-where-argument'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerProcess }
1 | Where-Object $stored
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'compound-unknown-invoke-receiver'
            Expected = $false
            Source = @'
Set-Variable -Name x -Value { Invoke-PrivateMarkerProcess }
(Write-Output (Get-Variable x -ValueOnly) -Verbose:$safe).Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        }
    )
    foreach ($case in $cases) {
        $actual = Test-FirstPrivateMarkerProcessInvocationIsBinaryTransport `
            -Source $case.Source
        if ($actual -ne $case.Expected) {
            Add-Failure (
                'First-invocation policy validator regression failed: ' +
                "$($case.Name)."
            )
        }
    }

    # generic ExecutionContext除外の責務を単体で固定する。直接receiverは後段へ
    # 渡す一方、returnによるtable escapeはここで拒否しなければならない。
    $receiverCases = @(
        [pscustomobject]@{
            Name = 'direct-getvalue-receiver'
            Expected = $true
            Source = '$ExecutionContext.SessionState.PSVariable.GetValue(''localOnly'')'
        },
        [pscustomobject]@{
            Name = 'direct-set-receiver'
            Expected = $true
            Source = '$ExecutionContext.SessionState.PSVariable.Set(''localOnly'', ''value'')'
        },
        [pscustomobject]@{
            Name = 'indexed-array-set-receiver'
            Expected = $true
            Source = '@($ExecutionContext.SessionState.PSVariable)[0].Set(''localOnly'', ''value'')'
        },
        [pscustomobject]@{
            Name = 'array-getvalue-is-not-direct-receiver'
            Expected = $false
            Source = '@($ExecutionContext.SessionState.PSVariable).GetValue(0)'
        },
        [pscustomobject]@{
            Name = 'cast-getvalue-is-not-direct-receiver'
            Expected = $false
            Source = '([object[]]$ExecutionContext.SessionState.PSVariable).GetValue(0)'
        },
        [pscustomobject]@{
            Name = 'return-wrapper-escape'
            Expected = $false
            Source = 'return $ExecutionContext.SessionState.PSVariable'
        }
    )
    foreach ($receiverCase in $receiverCases) {
        $receiverTokens = $null
        $receiverErrors = $null
        $receiverAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $receiverCase.Source,
            [ref]$receiverTokens,
            [ref]$receiverErrors
        )
        $executionContextReferences = @(
            $receiverAst.FindAll(
                {
                    param($node)
                    return $node -is
                            [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.VariablePath.UserPath -eq 'ExecutionContext'
                },
                $true
            )
        )
        if ($receiverErrors.Count -ne 0 -or
            $executionContextReferences.Count -ne 1) {
            Add-Failure "Direct PSVariable receiver fixture parse failed: $($receiverCase.Name)."
            continue
        }
        $actualReceiver = (
            Test-PrivateMarkerExecutionContextReferenceIsDirectPsVariableReceiver `
                -Variable $executionContextReferences[0]
        )
        if ($actualReceiver -ne $receiverCase.Expected) {
            Add-Failure "Direct PSVariable receiver regression failed: $($receiverCase.Name)."
        }
    }
}

function Assert-FinalScanDeadlineContract {
    param(
        [string]$RelativePath
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (final scan deadline contract)"
        return
    }

    # finding payload と clean result のどちらも、emit直前に同じscan-wide時計を
    # 再確認する。途中のdeadline callが存在するだけでは最終窓を閉じられない。
    $source = Get-Content -LiteralPath $filePath -Raw
    $findingWritePattern = (
        '(?m)^[ \t]*\$standardOutput\.Write\(')
    $guardedFindingWritePattern = (
        '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
        '[ \t]*\$standardOutput\.Write\(')
    $outputLimitWritePattern = (
        '(?m)^[ \t]*Write-Host[ \t]+' +
        '''Private marker scan aborted: scan-diagnostic-output-limit''' +
        '[ \t]*$')
    $guardedOutputLimitWritePattern = (
        '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
        '[ \t]*Write-Host[ \t]+' +
        '''Private marker scan aborted: scan-diagnostic-output-limit''' +
        '[ \t]*$')
    $successEmitPattern = (
        '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
        '[ \t]*Write-Host[ \t]+' +
        '"Private marker scan passed \(scan target: \$scanMode\)\."[ \t]*$')
    $findingWriteCount = [regex]::Matches(
        $source,
        $findingWritePattern
    ).Count
    $guardedFindingWriteCount = [regex]::Matches(
        $source,
        $guardedFindingWritePattern
    ).Count
    $openStandardOutputCount = [regex]::Matches(
        $source,
        '\[Console\]::OpenStandardOutput\(\)'
    ).Count
    if ($findingWriteCount -ne 1 -or
        $guardedFindingWriteCount -ne $findingWriteCount -or
        $openStandardOutputCount -ne 1) {
        Add-Failure "$RelativePath must recheck the scan-wide deadline immediately before writing finding stdout."
    }
    $outputLimitWriteCount = [regex]::Matches(
        $source,
        $outputLimitWritePattern
    ).Count
    $guardedOutputLimitWriteCount = [regex]::Matches(
        $source,
        $guardedOutputLimitWritePattern
    ).Count
    $writeHostCount = [regex]::Matches(
        $source,
        '(?m)^[ \t]*Write-Host\b'
    ).Count
    if ($outputLimitWriteCount -ne 2 -or
        $guardedOutputLimitWriteCount -ne $outputLimitWriteCount -or
        $writeHostCount -ne 3) {
        Add-Failure "$RelativePath must guard every bounded diagnostic output with an immediate scan-wide deadline check."
    }
    if ($source -notmatch $successEmitPattern) {
        Add-Failure "$RelativePath must recheck the scan-wide deadline immediately before success output."
    }
}

function Test-WorkflowEnvelopeSource {
    param(
        [string]$Source,
        [string[]]$ExpectedJobNames
    )

    # mutation regressionからも使えるpure判定。YAML parser依存を追加せず、
    # このsmall workflowが許可するactive envelopeだけを厳密に比較する。
    $lines = @($Source -split '\r?\n')
    $activeTopLevelLines = @(
        $lines |
            Where-Object { $_ -match '^[^ \t#]' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedTopLevelLines = @(
        'name: Validate',
        'on:',
        'permissions:',
        'jobs:'
    )
    if ($activeTopLevelLines.Count -ne $expectedTopLevelLines.Count -or
        ($activeTopLevelLines -join "`n") -cne
            ($expectedTopLevelLines -join "`n")) {
        return $false
    }

    $onStart = [Array]::IndexOf($lines, 'on:')
    $permissionsStart = [Array]::IndexOf($lines, 'permissions:')
    $jobsStart = [Array]::IndexOf($lines, 'jobs:')
    if ($onStart -lt 0 -or
        $permissionsStart -le $onStart -or
        $jobsStart -le $permissionsStart) {
        return $false
    }
    $onActiveLines = @(
        $lines[$onStart..($permissionsStart - 1)] |
            Where-Object { $_ -notmatch '^\s*(?:#.*)?$' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedOnLines = @(
        'on:',
        '  pull_request:',
        '  push:',
        '    branches:',
        '      - main'
    )
    if ($onActiveLines.Count -ne $expectedOnLines.Count -or
        ($onActiveLines -join "`n") -cne ($expectedOnLines -join "`n")) {
        return $false
    }

    $permissionActiveLines = @(
        $lines[$permissionsStart..($jobsStart - 1)] |
            Where-Object { $_ -notmatch '^\s*(?:#.*)?$' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedPermissionLines = @(
        'permissions:',
        '  contents: read'
    )
    if ($permissionActiveLines.Count -ne $expectedPermissionLines.Count -or
        ($permissionActiveLines -join "`n") -cne
            ($expectedPermissionLines -join "`n")) {
        return $false
    }

    $jobLines = @($lines[($jobsStart + 1)..($lines.Count - 1)])
    if (@($jobLines | Where-Object {
        $_ -match '^(?i:    (?:"permissions"|''permissions''|permissions):)'
    }).Count -ne 0) {
        return $false
    }
    $activeJobIdLines = @(
        $jobLines |
            Where-Object { $_ -match '^  [^ \t#]' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedJobIdLines = @(
        $ExpectedJobNames |
            ForEach-Object { "  ${_}:" } |
            Sort-Object
    )
    return $activeJobIdLines.Count -eq $expectedJobIdLines.Count -and
        (@($activeJobIdLines | Sort-Object) -join "`n") -ceq
            ($expectedJobIdLines -join "`n")
}

function Assert-WorkflowEnvelope {
    param(
        [string]$RelativePath,
        [string[]]$ExpectedJobNames
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing workflow file: $RelativePath"
        return
    }

    # top-level key、trigger、permissions、job ID集合をjob内部とは独立に固定する。
    # pull_request_target、権限追加、extra/duplicate jobによる迂回を許さない。
    try {
        $source = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        Add-Failure "Workflow file '$RelativePath' must be valid UTF-8."
        return
    }
    if (-not (Test-WorkflowEnvelopeSource `
        -Source $source `
        -ExpectedJobNames $ExpectedJobNames)) {
        Add-Failure "Workflow '$RelativePath' failed its exact envelope contract."
    }
    $lines = @($source -split '\r?\n')
    $activeTopLevelLines = @(
        $lines |
            Where-Object { $_ -match '^[^ \t#]' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedTopLevelLines = @(
        'name: Validate',
        'on:',
        'permissions:',
        'jobs:'
    )
    if ($activeTopLevelLines.Count -ne $expectedTopLevelLines.Count -or
        ($activeTopLevelLines -join "`n") -cne
            ($expectedTopLevelLines -join "`n")) {
        Add-Failure "Workflow '$RelativePath' must contain only the name/on/permissions/jobs top-level keys."
    }

    $onStart = [Array]::IndexOf($lines, 'on:')
    $permissionsStart = [Array]::IndexOf($lines, 'permissions:')
    $jobsStart = [Array]::IndexOf($lines, 'jobs:')
    if ($onStart -lt 0 -or $permissionsStart -lt 0 -or $jobsStart -lt 0) {
        Add-Failure "Workflow '$RelativePath' is missing an exact on/permissions/jobs mapping."
        return
    }

    # comment/blankを除くactive trigger行のsequenceを固定し、別triggerを拒否する。
    $onEnd = $permissionsStart - 1
    $onActiveLines = @(
        $lines[$onStart..$onEnd] |
            Where-Object { $_ -notmatch '^\s*(?:#.*)?$' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedOnLines = @(
        'on:',
        '  pull_request:',
        '  push:',
        '    branches:',
        '      - main'
    )
    if ($onActiveLines.Count -ne $expectedOnLines.Count -or
        ($onActiveLines -join "`n") -cne ($expectedOnLines -join "`n")) {
        Add-Failure "Workflow '$RelativePath' must trigger only on pull_request and pushes to main."
    }

    # repository既定権限はcontents:readだけに限定する。job単位overrideは
    # Assert-WorkflowJobShapeのexact job key数でも拒否する。
    $permissionsEnd = $jobsStart - 1
    $permissionActiveLines = @(
        $lines[$permissionsStart..$permissionsEnd] |
            Where-Object { $_ -notmatch '^\s*(?:#.*)?$' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedPermissionLines = @(
        'permissions:',
        '  contents: read'
    )
    if ($permissionActiveLines.Count -ne $expectedPermissionLines.Count -or
        ($permissionActiveLines -join "`n") -cne
            ($expectedPermissionLines -join "`n")) {
        Add-Failure "Workflow '$RelativePath' must grant only contents: read."
    }

    $activeJobIdLines = @(
        $lines[($jobsStart + 1)..($lines.Count - 1)] |
            Where-Object { $_ -match '^  [^ \t#]' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedJobIdLines = @(
        $ExpectedJobNames |
            ForEach-Object { "  ${_}:" } |
            Sort-Object
    )
    if ($activeJobIdLines.Count -ne $expectedJobIdLines.Count -or
        (@($activeJobIdLines | Sort-Object) -join "`n") -cne
            ($expectedJobIdLines -join "`n")) {
        Add-Failure "Workflow '$RelativePath' must contain exactly these job IDs: $($ExpectedJobNames -join ', ')."
    }
}

function Assert-WorkflowEnvelopeValidatorRegressions {
    # trigger、全active top-level/job ID、job権限overrideの代表的な
    # quoted/flow YAML迂回をpure validatorへ固定する。
    $validSource = @'
name: Validate
on:
  pull_request:
  push:
    branches:
      - main
permissions:
  contents: read
jobs:
  validate:
    name: Windows
  bash-hooks:
    name: Ubuntu
'@
    $cases = @(
        [pscustomobject]@{
            Name = 'valid'
            Expected = $true
            Source = $validSource
        },
        [pscustomobject]@{
            Name = 'pull-request-target'
            Expected = $false
            Source = $validSource.Replace(
                '  pull_request:',
                '  pull_request_target:'
            )
        },
        [pscustomobject]@{
            Name = 'extra-job'
            Expected = $false
            Source = $validSource + "`n" + @'
  extra:
    name: Extra
'@
        },
        [pscustomobject]@{
            Name = 'quoted-flow-extra-job'
            Expected = $false
            Source = $validSource + "`n" + @'
  "extra": {name: Extra, runs-on: ubuntu-24.04, timeout-minutes: 1, permissions: {contents: write}, steps: []}
'@
        },
        [pscustomobject]@{
            Name = 'duplicate-job'
            Expected = $false
            Source = $validSource + "`n" + @'
  validate:
    name: Duplicate
'@
        },
        [pscustomobject]@{
            Name = 'job-permissions-override'
            Expected = $false
            Source = $validSource.Replace(
                "  validate:`n    name: Windows",
                "  validate:`n    permissions:`n      contents: write`n    name: Windows"
            )
        },
        [pscustomobject]@{
            Name = 'quoted-top-level-concurrency'
            Expected = $false
            Source = $validSource.Replace(
                'jobs:',
                '"concurrency": {cancel-in-progress: true}' + "`n" + 'jobs:'
            )
        },
        [pscustomobject]@{
            Name = 'quoted-flow-job-permissions'
            Expected = $false
            Source = $validSource.Replace(
                "  validate:`n    name: Windows",
                "  validate:`n    `"permissions`": {contents: write}`n    name: Windows"
            )
        }
    )
    foreach ($case in $cases) {
        $actual = Test-WorkflowEnvelopeSource `
            -Source $case.Source `
            -ExpectedJobNames @('validate', 'bash-hooks')
        if ($actual -ne $case.Expected) {
            Add-Failure "Workflow envelope validator regression failed: $($case.Name)."
        }
    }
}

function Get-WorkflowJobLines {
    param(
        [string]$RelativePath,
        [string]$JobName
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing workflow file: $RelativePath"
        return @()
    }

    # workflowはUTF-8/LFでBOMを持たない。Windows PowerShell 5.1 の
    # locale既定decodeでは日本語comment末尾と次行が結合し得るため明示decodeする。
    try {
        $workflowSource = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        Add-Failure "Workflow file '$RelativePath' must be valid UTF-8."
        return @()
    }
    $lines = @($workflowSource -split '\r?\n')
    $jobStart = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $jobMatch = [regex]::Match(
            $lines[$index],
            '^  (?<name>[A-Za-z0-9_-]+):[ \t]*$'
        )
        if ($jobMatch.Success -and
            $jobMatch.Groups['name'].Value -ceq $JobName) {
            $jobStart = $index
            break
        }
    }
    if ($jobStart -lt 0) {
        Add-Failure "Workflow job '$JobName' is missing."
        return @()
    }

    $jobEnd = $lines.Count
    for ($index = $jobStart + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^  [A-Za-z0-9_-]+:[ \t]*$') {
            $jobEnd = $index
            break
        }
    }
    return @($lines[$jobStart..($jobEnd - 1)])
}

function Get-WorkflowSteps {
    param(
        [string[]]$Lines,
        [string]$JobName
    )

    $stepStartCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+' }
    ).Count
    $namedStepCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+name:[ \t]+' }
    ).Count
    if ($stepStartCount -ne $namedStepCount) {
        Add-Failure "Workflow job '$JobName' must give every active step an explicit name."
    }

    $steps = New-Object System.Collections.Generic.List[object]
    $currentStep = $null

    foreach ($line in $Lines) {
        $nameMatch = [regex]::Match($line, '^      -[ \t]+name:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$')
        if ($nameMatch.Success) {
            if ($null -ne $currentStep) {
                $steps.Add($currentStep) | Out-Null
            }
            $currentStep = [pscustomobject]@{
                Name = $nameMatch.Groups['value'].Value.Trim("'`"")
                Shell = ''
                Run = ''
                Uses = ''
                ShellCount = 0
                RunCount = 0
                UsesCount = 0
            }
            continue
        }

        if ($null -eq $currentStep) {
            continue
        }

        $shellMatch = [regex]::Match($line, '^        shell:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$')
        if ($shellMatch.Success) {
            $currentStep.Shell = $shellMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.ShellCount++
            continue
        }

        $runMatch = [regex]::Match($line, '^        run:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$')
        if ($runMatch.Success) {
            $currentStep.Run = $runMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.RunCount++
            continue
        }

        $usesMatch = [regex]::Match($line, '^        uses:[ \t]*(?<value>[^#\r\n]+?)[ \t]*(?:#.*)?$')
        if ($usesMatch.Success) {
            $currentStep.Uses = $usesMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.UsesCount++
        }
    }

    if ($null -ne $currentStep) {
        $steps.Add($currentStep) | Out-Null
    }

    return $steps.ToArray()
}

function Assert-WorkflowJobValue {
    param(
        [string[]]$Lines,
        [string]$JobName,
        [string]$Key,
        [string]$ExpectedValue
    )

    $pattern = (
        '^    ' +
        [regex]::Escape($Key) +
        ':[ \t]*' +
        [regex]::Escape($ExpectedValue) +
        '[ \t]*(?:#.*)?$')
    # `$Matches` は -match が更新するautomatic変数なので、結果collectionへ
    # 同名（PowerShellはcase-insensitive）を使わずPS5.1/PS7差を避ける。
    $keyPattern = '^    ' + [regex]::Escape($Key) + ':[ \t]*'
    $keyLines = @($Lines | Where-Object { $_ -match $keyPattern })
    $matchingLines = @($keyLines | Where-Object { $_ -match $pattern })
    if ($keyLines.Count -ne 1 -or $matchingLines.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must declare exactly one '${Key}: $ExpectedValue' value (total keys $($keyLines.Count), expected values $($matchingLines.Count))."
    }
}

function Assert-WorkflowStepCount {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [int]$ExpectedCount
    )

    if ($Steps.Count -ne $ExpectedCount) {
        Add-Failure "Workflow job '$JobName' must contain exactly $ExpectedCount named steps (found $($Steps.Count))."
    }
}

function Assert-WorkflowJobShape {
    param(
        [string[]]$Lines,
        [string]$JobName,
        [int]$ExpectedStepCount,
        [int]$ExpectedShellCount,
        [int]$ExpectedRunCount
    )

    # expected keyを残したまま `if: false`、continue-on-error、別action等を
    # 足してvalidationを無効化できないよう、indent別の全active entryも数える。
    $jobEntryCount = @(
        $Lines | Where-Object { $_ -match '^    (?![ #\r\n]).+$' }
    ).Count
    $nameKeyCount = @(
        $Lines | Where-Object { $_ -match '^    name:[ \t]*' }
    ).Count
    $stepsKeyCount = @(
        $Lines | Where-Object { $_ -match '^    steps:[ \t]*' }
    ).Count
    $stepItemCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+' }
    ).Count
    $stepPropertyCount = @(
        $Lines | Where-Object { $_ -match '^        (?![ #\r\n]).+$' }
    ).Count
    $shellKeyCount = @(
        $Lines | Where-Object { $_ -match '^        shell:[ \t]*' }
    ).Count
    $runKeyCount = @(
        $Lines | Where-Object { $_ -match '^        run:[ \t]*' }
    ).Count
    $usesKeyCount = @(
        $Lines | Where-Object { $_ -match '^        uses:[ \t]*' }
    ).Count
    $expectedStepPropertyCount =
        1 + $ExpectedShellCount + $ExpectedRunCount

    if ($jobEntryCount -ne 4 -or
        $nameKeyCount -ne 1 -or
        $stepsKeyCount -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain only one name/runs-on/timeout-minutes/steps mapping."
    }
    if ($stepItemCount -ne $ExpectedStepCount) {
        Add-Failure "Workflow job '$JobName' must contain exactly $ExpectedStepCount step items (found $stepItemCount)."
    }
    if ($stepPropertyCount -ne $expectedStepPropertyCount -or
        $shellKeyCount -ne $ExpectedShellCount -or
        $runKeyCount -ne $ExpectedRunCount -or
        $usesKeyCount -ne 1) {
        Add-Failure "Workflow job '$JobName' contains an unexpected, missing, or duplicate step-level key."
    }
}

function Assert-WorkflowStep {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [string]$Name,
        [string]$Shell,
        [string]$Run
    )

    $matches = @($Steps | Where-Object { $_.Name -ceq $Name })
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain exactly one active step named '$Name' (found $($matches.Count))."
        return
    }

    $step = $matches[0]
    if ($step.ShellCount -ne 1 -or
        $step.RunCount -ne 1 -or
        $step.UsesCount -ne 0) {
        Add-Failure "Workflow job '$JobName' step '$Name' must contain exactly one shell/run and no uses key."
    }
    if (-not $step.Shell.Equals($Shell, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure "Workflow job '$JobName' step '$Name' must use shell '$Shell' (found '$($step.Shell)')."
    }
    if ($step.Run -cne $Run) {
        Add-Failure "Workflow job '$JobName' step '$Name' must run '$Run' (found '$($step.Run)')."
    }
}

function Assert-WorkflowUsesStep {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [string]$Name,
        [string]$Uses
    )

    $matches = @($Steps | Where-Object { $_.Name -ceq $Name })
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain exactly one active step named '$Name' (found $($matches.Count))."
        return
    }

    $step = $matches[0]
    if ($step.UsesCount -ne 1 -or
        $step.ShellCount -ne 0 -or
        $step.RunCount -ne 0) {
        Add-Failure "Workflow job '$JobName' step '$Name' must contain exactly one uses key and no shell/run key."
    }
    if ($step.Uses -cne $Uses) {
        Add-Failure "Workflow job '$JobName' step '$Name' must use '$Uses' (found '$($step.Uses)')."
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
    param([string]$RelativePath)

    # PowerShell hook は fail-open と raw UTF-8 出力を維持し、
    # machine 固有の絶対 path を再導入しない。
    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }

    Assert-FileContains -RelativePath $RelativePath -Pattern 'CLAUDE_DEVLOG_DIR' -Description 'devlog root resolution via CLAUDE_DEVLOG_DIR'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'Write-Utf8Stdout' -Description 'UTF-8 byte output helper'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'exit 0' -Description 'fail-open exit'
    Assert-FileNotContains -RelativePath $RelativePath -Pattern '[A-Za-z]:\\[^\r\n]*\\' -Description 'hardcoded absolute Windows paths'
    Assert-FileHasUtf8Bom -RelativePath $RelativePath
}

function Assert-BashHookFile {
    param([string]$RelativePath)

    # Bash entrypoint は checked-in helper だけに依存し、
    # stderr を漏らさず fail-open する境界を固定する。
    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }

    Assert-FileContains -RelativePath $RelativePath -Pattern '(?m)^#!/usr/bin/env bash$' -Description 'portable Bash shebang'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'devlog-common\.sh' -Description 'shared Bash helper loading'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'main 2>/dev/null' -Description 'fail-silent main boundary'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'exit 0' -Description 'fail-open exit'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'printf ' -Description 'raw UTF-8 output via printf'
    Assert-FileNotContains -RelativePath $RelativePath -Pattern '[A-Za-z]:\\[^\r\n]*\\' -Description 'hardcoded absolute Windows paths'
    Assert-FileNotContains -RelativePath $RelativePath -Pattern '(?m)^\s*jq(?:\s|$)' -Description 'jq runtime invocation'

    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        Add-Failure "$RelativePath must be UTF-8 without BOM for Unix shebang execution."
    }
}

function Assert-BashCommonFile {
    param([string]$RelativePath)

    # 共通 helper の設定・JSON escape・mtime portability 契約を、
    # entrypoint とは分離して検査する。
    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }

    Assert-FileContains -RelativePath $RelativePath -Pattern 'CLAUDE_DEVLOG_DIR' -Description 'devlog root resolution via CLAUDE_DEVLOG_DIR'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'CLAUDE_DEVLOG_LANG' -Description 'message language resolution via CLAUDE_DEVLOG_LANG'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'devlog_json_escape' -Description 'manual JSON string escaping'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'stop_hook_active' -Description 'top-level boolean loop-guard parsing'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'stat -c %Y' -Description 'GNU stat mtime support'
    Assert-FileContains -RelativePath $RelativePath -Pattern 'stat -f %m' -Description 'BSD stat mtime support'
    Assert-FileNotContains -RelativePath $RelativePath -Pattern '(?m)^\s*jq(?:\s|$)' -Description 'jq runtime invocation'

    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        Add-Failure "$RelativePath must be UTF-8 without BOM for Bash sourcing."
    }
}

function Test-ExampleSettings {
    param([string]$RelativePath)

    # 公開 JSON 例は parse できることに加え、3 event をすべて登録する。
    $settingsPath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return
    }

    $parsed = $null
    try {
        $parsed = (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json)
    } catch {
        Add-Failure "$RelativePath must be valid JSON."
        return
    }

    foreach ($eventName in @('SessionStart', 'Stop', 'UserPromptSubmit')) {
        if ($null -eq ($parsed.hooks.PSObject.Properties[$eventName])) {
            Add-Failure "$RelativePath must register the $eventName event."
        }
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

$requiredFiles = @(
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/config.yml',
    '.github/pull_request_template.md',
    '.github/workflows/validate.yml',
    '.claude-plugin/plugin.json',
    'CHANGELOG.md',
    'CODE_OF_CONDUCT.md',
    'CONTRIBUTING.md',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'SKILL.md',
    'docs/SKILL.ja.md',
    'docs/hook-engineering.md',
    'docs/posix-hooks-design.md',
    'docs/posix-hooks-test-plan.md',
    'docs/plugin-requirements.md',
    'docs/plugin-architecture.md',
    'docs/plugin-detailed-design.md',
    'docs/plugin-test-plan.md',
    'examples/hooks-settings.json',
    'examples/hooks-settings.bash.json',
    'examples/journal-entry-template.md',
    'HANDOFF.md',
    'hooks/devlog-common.sh',
    'hooks/devlog-session-start.sh',
    'hooks/devlog-prompt-nudge.sh',
    'hooks/devlog-stop.sh',
    'hooks/hooks.json',
    'hooks/devlog-plugin-launcher.sh',
    'hooks/devlog-session-start.ps1',
    'hooks/devlog-prompt-nudge.ps1',
    'hooks/devlog-stop.ps1',
    'scripts/private-marker-first-invocation-policy.ps1',
    'scripts/private-marker-process.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-plugin.ps1',
    'scripts/test-plugin-launcher.sh',
    'scripts/test-hooks.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)

foreach ($requiredFile in $requiredFiles) {
    Assert-FileExists -RelativePath $requiredFile
}

foreach ($japaneseCommentedScript in @(
    'scripts/private-marker-first-invocation-policy.ps1',
    'scripts/private-marker-process.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)) {
    Assert-FileHasUtf8Bom -RelativePath $japaneseCommentedScript
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
Assert-FileContains -RelativePath 'README.md' -Pattern 'claude plugin validate \. --strict' -Description 'strict plugin validation command'
Assert-FileContains -RelativePath 'README.md' -Pattern 'Manual settings fallback' -Description 'manual settings fallback'
Assert-FileContains -RelativePath 'README.md' -Pattern 'docs/plugin-architecture\.md' -Description 'plugin architecture link'
Assert-FileContains -RelativePath '.gitignore' -Pattern '\.private-markers\.local' -Description 'ignore local private marker files'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern '(?im)no token|never.*token|secret' -Description 'secret-safe contribution guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?im)do not.*public|private|security' -Description 'private vulnerability reporting guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?i)fail(?:s|ed)? closed' -Description 'fail-closed scanner boundary'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'ProcessBoundaryFailureProbe' -Description 'one-way process-boundary failure seam'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'Private marker scan failed closed \(integrity: process-boundary\)\.' -Description 'fixed redacted process-boundary diagnostic'
Assert-FileNotContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'Missing process boundary script:' -Description 'path-bearing process helper diagnostic'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'CLAUDE_CODE_DEVLOG_HOOKS_PRIVATE_MARKERS' -Description 'existing local marker environment contract'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'h8nc4y/claude-code-devlog-hooks' -Description 'repository-only GitHub URL allowlist'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'Assert-PrivateMarkerScanDeadline' -Description 'scan-wide deadline enforcement'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'leading-dot' -Description 'POSIX ordinary single-dot filename scanning'
Assert-FileNotContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '\[ValidateRange\(250,\s*15000\)\]' -Description 'public Git timeout binder diagnostic that can expose script paths'
Assert-FileNotContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '\[ValidateRange\(1,\s*120000\)\]' -Description 'public scan deadline binder diagnostic that can expose script paths'
Assert-FileNotContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '\[ValidateSet\(''.*isolation-create.*helper' -Description 'public process-probe binder diagnostic that can expose script paths'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'ConvertTo-PrivateMarkerBoundedIntegerParameter' -Description 'body-level bounded integer parameter validation'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '(?s)-Minimum\s+250\s+.*-Maximum\s+15000' -Description 'bounded Git timeout self-test seam'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '(?s)-Minimum\s+1\s+.*-Maximum\s+120000' -Description 'lower-only scan-wide deadline self-test seam'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '\$ProcessBoundaryFailureProbe\s+-cnotin' -Description 'body-level process-boundary probe validation'
Assert-FinalScanDeadlineContract -RelativePath 'scripts/scan-private-markers.ps1'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'maximumFindingOutputBytes' -Description 'actual UTF-8 finding output cap'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'StandardInputEncoding' -Description 'BOM-less redirected stdin encoding'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'ForceWindowsLaunchFailure' -Description 'Windows pre-resume cleanup fault injection'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'ForceWindowsJobCloseFailure' -Description 'Windows Job-close retry fault injection'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'LastSyntheticFailureProcessId' -Description 'Windows cleanup PID evidence'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'windows-pre-resume-deadline-target-ran' -Description 'Windows native pre-resume deadline regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'deadline expired before resume' -Description 'Windows native deadline branch evidence'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '(?s)ProcessBoundary\.Close\(handle\);.{0,300}jobHandle = IntPtr\.Zero;' -Description 'Job ownership released only after successful close'
Assert-FileNotContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '(?s)jobHandle = IntPtr\.Zero;\s*ProcessBoundary\.Close\(handle\);' -Description 'premature Job handle ownership release'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'public void Terminate\(\)' -Description 'direct target termination fallback'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '\$ContainedProcess\.Terminate\(\)' -Description 'Job-close failure direct termination path'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'Contained child launch cleanup failed' -Description 'launch and cleanup failure aggregation'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '\$containedProcess\.Dispose\(\)' -Description 'explicit success-path standard-stream disposal'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'getpgid\(int pid\)' -Description 'kernel-backed POSIX process-group verification'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'Get-PrivateMarkerPosixSetsidArguments' -Description 'portable option-free setsid argument builder'
Assert-FileNotContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '\$effectiveArguments\s*=\s*@\(''--''' -Description 'util-linux-only setsid option'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '(?s)\$operationClock\s*=\s*\[System\.Diagnostics\.Stopwatch\]::StartNew\(\).{0,300}\$processCleanupWaitMilliseconds\s*=\s*5000.{0,300}\btry\s*\{' -Description 'operation deadline starts before process preparation with independent cleanup slack'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '\$cleanupClock\s*=\s*\[System\.Diagnostics\.Stopwatch\]::StartNew\(\)' -Description 'cleanup-wide finite total budget'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'Get-PrivateMarkerRemainingCleanupWaitMilliseconds' -Description 'invocation-wide remaining cleanup budget'
Assert-FileNotContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '-WaitMilliseconds\s+\$(?:processCleanupWaitMilliseconds|StreamCompletionWaitMilliseconds|StreamCleanupWaitMilliseconds)' -Description 'per-phase cleanup budget reset'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '(?s)\$process\.StartInfo\s*=\s*\$startInfo.{0,400}\$operationClock\.ElapsedMilliseconds\s+-ge\s*\$TimeoutMilliseconds.{0,400}\$processStarted\s*=\s*\$process\.Start\(\)' -Description 'POSIX launch deadline recheck immediately before Process.Start'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'lateProcessGroupId' -Description 'late external setsid ready-PID recovery'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'Get-PrivateMarkerPosixGateCompletion' -Description 'fork-safe POSIX payload completion tracking'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'ContainmentEstablished\s*=\s*\$containmentEstablished' -Description 'explicit process-containment evidence'
Assert-FileContains -RelativePath 'scripts/private-marker-first-invocation-policy.ps1' -Pattern 'riskyCallableNames' -Description 'transitive risky function call graph'
Assert-FileContains -RelativePath 'scripts/private-marker-first-invocation-policy.ps1' -Pattern 'Get-PrivateMarkerAliasDefinition' -Description 'risky function alias tracking'
Assert-FileContains -RelativePath 'scripts/private-marker-first-invocation-policy.ps1' -Pattern 'CommandType.*Application' -Description 'safe native application lookup boundary'
Assert-FileContains -RelativePath 'scripts/private-marker-first-invocation-policy.ps1' -Pattern 'Test-PrivateMarkerAllowedBootstrapDotSource' -Description 'constrained bootstrap dot-source boundary'
Assert-FileContains -RelativePath 'scripts/private-marker-first-invocation-policy.ps1' -Pattern 'Test-PrivateMarkerCommandConstructsRiskyType' -Description 'risky type constructor propagation'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner self-test'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'private-marker-first-invocation-policy\.ps1' -Description 'shared first-invocation AST policy'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'Assert-FixedProcessBoundaryFailure' -Description 'fixed process-boundary output regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern '\$handleProbeIterations\s*=\s*40' -Description 'repeated Windows success-handle regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'linked-worktree gitfile root' -Description 'standard linked-worktree gitfile regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'uppercase \.GIT (?:directory|leaf)' -Description 'POSIX exact lowercase .git exclusion regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'Unknown process-boundary probe' -Description 'public parameter binding redaction regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'Throwing process helper' -Description 'path-bearing process helper exception regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'execution-context-invoke-script' -Description 'InvokeScript bypass regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'target-function-provider-shadow' -Description 'Function provider shadow regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'PosixSignal.*IsSuccessfulResult' -Description 'POSIX errno cleanup regression coverage'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'posix-busybox-setsid-shim' -Description 'BusyBox-compatible external setsid execution fixture'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'posix-early-fork-setsid-shim' -Description 'POSIX pre-deadline fork completion fixture'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'posix-delayed-setsid-shim' -Description 'POSIX handshake deadline fixture'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'posix-late-ready-setsid-shim' -Description 'POSIX late-ready process-group recovery fixture'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'wrapped-aliased-execution-context-psvariable-set' -Description 'aliased ExecutionContext receiver regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'wrapped-get-variable-execution-context-psvariable-set' -Description 'provider-read ExecutionContext receiver regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'execution-context-psvariable-return-wrapper-before' -Description 'returned PSVariable table receiver regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'execution-context-psvariable-array-getvalue-return-wrapper-before' -Description 'array GetValue PSVariable receiver regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'execution-context-psvariable-cast-getvalue-return-wrapper-before' -Description 'cast GetValue PSVariable receiver regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'execution-context-psvariable-command-argument-before' -Description 'PSVariable command-argument receiver regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'execution-context-psvariable-pipeline-before' -Description 'PSVariable pipeline receiver regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'execution-context-psvariable-assignment-before' -Description 'PSVariable assignment receiver regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'Expected returned PSVariable table to mutate script:root at runtime' -Description 'PSVariable return-wrapper runtime mutation proof'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'allowed-called-wrapper-with-unused-risky-type-scriptblock' -Description 'dormant wrapper scriptblock regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern '(?s)\[byte\[\]\]\$binaryProbeBytes\s*=\s*@\(\s*0x00,\s*0x80,\s*0xFF,' -Description 'BOM-less binary standard-stream fixture'
Assert-FileContains -RelativePath 'scripts/private-marker-first-invocation-policy.ps1' -Pattern 'InvokeMemberExpressionAst' -Description 'invoked scriptblock AST classification'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern '\.Invoke\(\)' -Description 'invoked scriptblock validator regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern '\.InvokeReturnAsIs\(\)' -Description 'alternate invoked scriptblock validator regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern "(?s)cat-file'.*'--batch" -Description 'native Git binary batch regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern "foreach \(\`$launchFailureMode in @\('assign', 'resume'\)\)" -Description 'Windows assign/resume cleanup regressions'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'LastSyntheticJobCloseRetrySucceeded' -Description 'Windows Job-close ownership retry regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'IsProcessInJob' -Description 'resumed target Job-membership regression'
Assert-FirstInvocationPolicyValidatorRegressions
Assert-FirstTopLevelProcessInvocationIsBinary `
    -RelativePath 'scripts/test-scan-private-markers.ps1'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'scan-diagnostic-output-limit' -Description 'finding output amplification regression coverage'
Assert-FileContains -RelativePath 'CHANGELOG.md' -Pattern '0\.1\.0' -Description 'v0.1.0 release notes'

# job blockを先に切り出し、timeout/runs-on/checkout/stepを所有job内だけで
# 検証する。後続jobへ跨ぐregexによる誤合格を許さない。
$workflowPath = '.github/workflows/validate.yml'
$checkoutRevision = 'actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09'
Assert-WorkflowEnvelopeValidatorRegressions
Assert-WorkflowEnvelope `
    -RelativePath $workflowPath `
    -ExpectedJobNames @('validate', 'bash-hooks')
$windowsJobName = 'validate'
$windowsJobLines = @(Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName $windowsJobName)
$windowsSteps = @(Get-WorkflowSteps `
    -Lines $windowsJobLines `
    -JobName $windowsJobName)
Assert-WorkflowJobValue -Lines $windowsJobLines -JobName $windowsJobName `
    -Key 'runs-on' -ExpectedValue 'windows-latest'
Assert-WorkflowJobValue -Lines $windowsJobLines -JobName $windowsJobName `
    -Key 'timeout-minutes' -ExpectedValue '25'
Assert-WorkflowStepCount -Steps $windowsSteps -JobName $windowsJobName `
    -ExpectedCount 11
Assert-WorkflowJobShape -Lines $windowsJobLines -JobName $windowsJobName `
    -ExpectedStepCount 11 -ExpectedShellCount 10 -ExpectedRunCount 10
Assert-WorkflowUsesStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Check out repository' -Uses $checkoutRevision
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Validate OSS readiness' -Shell 'pwsh' `
    -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test plugin package (PowerShell 7)' -Shell 'pwsh' `
    -Run './scripts/test-plugin.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test plugin package (Windows PowerShell 5.1)' -Shell 'powershell' `
    -Run './scripts/test-plugin.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test plugin launcher (Git Bash)' -Shell 'bash' `
    -Run './scripts/test-plugin-launcher.sh'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test hooks (pipe tests, PowerShell 7)' -Shell 'pwsh' `
    -Run './scripts/test-hooks.ps1 -HookShell pwsh'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test hooks (pipe tests, Windows PowerShell 5.1)' -Shell 'pwsh' `
    -Run './scripts/test-hooks.ps1 -HookShell powershell'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test private marker scan (PowerShell 7)' -Shell 'pwsh' `
    -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test private marker scan (Windows PowerShell 5.1)' `
    -Shell 'powershell' -Run '.\scripts\test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Scan for private markers' -Shell 'pwsh' `
    -Run './scripts/scan-private-markers.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Check whitespace' -Shell 'pwsh' `
    -Run 'git diff-tree --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD'

$ubuntuJobName = 'bash-hooks'
$ubuntuJobLines = @(Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName $ubuntuJobName)
$ubuntuSteps = @(Get-WorkflowSteps `
    -Lines $ubuntuJobLines `
    -JobName $ubuntuJobName)
Assert-WorkflowJobValue -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -Key 'runs-on' -ExpectedValue 'ubuntu-24.04'
Assert-WorkflowJobValue -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -Key 'timeout-minutes' -ExpectedValue '10'
Assert-WorkflowStepCount -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -ExpectedCount 9
Assert-WorkflowJobShape -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -ExpectedStepCount 9 -ExpectedShellCount 8 -ExpectedRunCount 8
Assert-WorkflowUsesStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Check out repository' -Uses $checkoutRevision
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Validate OSS readiness on Ubuntu' -Shell 'pwsh' `
    -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Check Bash syntax' -Shell 'bash' `
    -Run 'bash --noprofile --norc -n hooks/*.sh scripts/*.sh'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Test plugin package' -Shell 'pwsh' `
    -Run './scripts/test-plugin.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Test plugin launcher' -Shell 'bash' `
    -Run './scripts/test-plugin-launcher.sh'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Test hooks (shared pipe tests plus POSIX path cases)' -Shell 'pwsh' `
    -Run './scripts/test-hooks.ps1 -HookShell bash'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Test private marker scan (PowerShell 7 on Ubuntu)' -Shell 'pwsh' `
    -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Scan for private markers on Ubuntu' -Shell 'pwsh' `
    -Run './scripts/scan-private-markers.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Check whitespace' -Shell 'pwsh' `
    -Run 'git diff-tree --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD'

Assert-HookFile -RelativePath 'hooks/devlog-session-start.ps1'
Assert-HookFile -RelativePath 'hooks/devlog-prompt-nudge.ps1'
Assert-HookFile -RelativePath 'hooks/devlog-stop.ps1'
Assert-FileContains -RelativePath 'hooks/devlog-stop.ps1' -Pattern '-is \[bool\]' -Description 'strict JSON boolean stop_hook_active guard'
Assert-BashCommonFile -RelativePath 'hooks/devlog-common.sh'
Assert-BashHookFile -RelativePath 'hooks/devlog-session-start.sh'
Assert-BashHookFile -RelativePath 'hooks/devlog-prompt-nudge.sh'
Assert-BashHookFile -RelativePath 'hooks/devlog-stop.sh'
Assert-FileContains -RelativePath 'hooks/devlog-plugin-launcher.sh' -Pattern 'CLAUDE_PLUGIN_OPTION_DEVLOG_DIR' -Description 'official plugin devlog directory export'
Assert-FileContains -RelativePath 'hooks/devlog-plugin-launcher.sh' -Pattern 'CLAUDE_PLUGIN_OPTION_DEVLOG_LANG' -Description 'official plugin language export'
Assert-FileContains -RelativePath 'hooks/devlog-plugin-launcher.sh' -Pattern '(?m)^\s*exec ' -Description 'single-runtime process replacement'
Assert-FileNotContains -RelativePath 'hooks/hooks.json' -Pattern '\$\{user_config\.' -Description 'shell userConfig interpolation'
Assert-FileNotContains -RelativePath 'hooks/devlog-plugin-launcher.sh' -Pattern '(?m)^\s*eval(?:\s|$)' -Description 'eval of configuration values'

Test-SkillFrontmatter
Test-ExampleSettings -RelativePath 'examples/hooks-settings.json'
Test-ExampleSettings -RelativePath 'examples/hooks-settings.bash.json'

if ($failures.Count -gt 0) {
    Write-Host 'OSS readiness validation failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host "OSS readiness validation passed for $root"
exit 0
