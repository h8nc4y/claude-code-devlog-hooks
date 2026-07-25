[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = [System.IO.Path]::GetDirectoryName(
        $MyInvocation.MyCommand.Path
    )
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = [System.IO.Path]::GetDirectoryName($scriptRoot)
}

$root = [System.IO.Path]::GetFullPath($Path)
$selfTestScriptPath = (
    Resolve-Path -LiteralPath $MyInvocation.MyCommand.Path
).Path
$scanner = Join-Path $root 'scripts/scan-private-markers.ps1'
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
    throw "Missing scanner script: $scanner"
}
$processBoundary = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-process.ps1'
)
if (-not (Test-Path -LiteralPath $processBoundary -PathType Leaf)) {
    throw "Missing process boundary script: $processBoundary"
}
$firstInvocationPolicy = [System.IO.Path]::Combine(
    $root,
    'scripts/private-marker-first-invocation-policy.ps1'
)
if (-not (Test-Path -LiteralPath $firstInvocationPolicy -PathType Leaf)) {
    throw "Missing first-invocation policy script: $firstInvocationPolicy"
}
. $firstInvocationPolicy
. $processBoundary

$currentPowerShellExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ([string]::IsNullOrWhiteSpace($currentPowerShellExecutable) -or
    -not (Test-Path -LiteralPath $currentPowerShellExecutable -PathType Leaf)) {
    $hostExecutableName = if ($PSVersionTable.PSVersion.Major -le 5) {
        'powershell.exe'
    } elseif (Test-PrivateMarkerWindowsHost) {
        'pwsh.exe'
    } else {
        'pwsh'
    }
    $currentPowerShellExecutable = Join-Path $PSHOME $hostExecutableName
}
if (-not (Test-Path -LiteralPath $currentPowerShellExecutable -PathType Leaf)) {
    throw "Cannot resolve the current PowerShell host executable: $currentPowerShellExecutable"
}

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

# external setsidはBusyBoxとutil-linuxの共通operand形だけを使う。
# optionを足す回帰をOS非依存のpure argument builderで検出する。
$portableSetsidArguments = @(
    Get-PrivateMarkerPosixSetsidArguments `
        -PowerShellExecutable '/synthetic/pwsh' `
        -EncodedCommand 'synthetic-encoded-command'
)
$expectedPortableSetsidArguments = @(
    '/synthetic/pwsh',
    '-NoProfile',
    '-EncodedCommand',
    'synthetic-encoded-command'
)
if ($portableSetsidArguments.Count -ne
        $expectedPortableSetsidArguments.Count -or
    [string]::Join(
        [char]0,
        [string[]]$portableSetsidArguments
    ) -cne
    [string]::Join(
        [char]0,
        [string[]]$expectedPortableSetsidArguments
    )) {
    Add-Failure 'Expected external setsid arguments to use the portable option-free operand contract.'
}

function Test-ByteArrayContainsSequence {
    param(
        [byte[]]$Haystack,
        [byte[]]$Needle
    )

    if ($Needle.Length -eq 0) {
        return $true
    }
    if ($Haystack.Length -lt $Needle.Length) {
        return $false
    }
    for ($offset = 0;
        $offset -le ($Haystack.Length - $Needle.Length);
        $offset++) {
        $matched = $true
        for ($needleIndex = 0;
            $needleIndex -lt $Needle.Length;
            $needleIndex++) {
            if ($Haystack[$offset + $needleIndex] -ne $Needle[$needleIndex]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Test-ByteArraysEqual {
    param(
        [byte[]]$Expected,
        [byte[]]$Actual
    )

    if ($Expected.Length -ne $Actual.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            return $false
        }
    }
    return $true
}

function Assert-FirstPrivateMarkerProcessValidatorRegressions {
    # 未実行定義は除外しつつ、wrapper/alias/function object/dynamic callを
    # helperの先行実行経路として拒否する。native Application lookupは維持する。
    $cases = @(
        [pscustomobject]@{
            Name = 'direct-before'
            Expected = $false
            Source = @'
Invoke-PrivateMarkerProcess
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'shadow-target-function'
            Expected = $false
            Source = @'
function Invoke-PrivateMarkerProcess {
    return 'shadow'
}
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
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
            Name = 'retarget-target-alias'
            Expected = $false
            Source = @'
Set-Alias Invoke-PrivateMarkerProcess Write-Output
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
            Name = 'function-before'
            Expected = $true
            Source = @'
function Invoke-Deferred {
    Invoke-PrivateMarkerProcess
}
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoked-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
Invoke-Early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'transitive-function-before'
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
            Name = 'scoped-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
global:Invoke-Early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'risky-function-alias'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
Set-Alias EarlyAlias Invoke-Early
EarlyAlias
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-expression-alias'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
Set-Alias Run-Early Invoke-Expression
Run-Early 'Invoke-Early'
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-command-alias'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
Set-Alias Run-Early Invoke-Command
Run-Early -ScriptBlock ${function:Invoke-Early}
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'alias-provider-mutation'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
Set-Item -Path Alias:EarlyAlias -Value Invoke-Early
EarlyAlias
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
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
            Name = 'wrapped-set-content-risky-alias-provider'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
function Set-EarlyAlias {
    Set-Content Alias:EarlyAlias Invoke-Early
    EarlyAlias
}
Set-EarlyAlias
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-alias-provider-mutation'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$aliasPath = 'Alias:EarlyAlias'
Set-Item -Path $aliasPath -Value Invoke-Early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'target-function-provider-shadow'
            Expected = $false
            Source = @'
Set-Item -Path Function:Invoke-PrivateMarkerProcess -Value { 'shadow' }
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'target-function-provider-shadow-positional'
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
            Name = 'dynamic-alias-import'
            Expected = $false
            Source = @'
Import-Alias ./synthetic-aliases.csv
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-alias-target'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$targetName = 'Invoke-Early'
Set-Alias EarlyAlias $targetName
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-function-call-operator'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$functionName = 'Invoke-Early'
& $functionName
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-function-dot-source'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$functionName = 'Invoke-Early'
. $functionName
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
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
            Name = 'get-content-function-scriptblock-wrapper'
            Expected = $false
            Source = @'
function Invoke-Early {
    . './synthetic-early.ps1'
}
$early = Get-Content Function:Invoke-Early
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
            Name = 'stored-scriptblock-get-item-variable-provider'
            Expected = $false
            Source = @'
$stored = { . './synthetic-early.ps1' }
$early = (Get-Item Variable:stored).Value
1 | ForEach-Object -Process $early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-get-child-item-variable-provider'
            Expected = $false
            Source = @'
$stored = { . './synthetic-early.ps1' }
$early = (Get-ChildItem Variable:stored).Value
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
            Name = 'dormant-function-literal-dot-source'
            Expected = $true
            Source = @'
function Invoke-Later {
    . './synthetic-later.ps1'
}
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dormant-stored-scriptblock-literal-dot-source'
            Expected = $true
            Source = @'
$later = { . './synthetic-later.ps1' }
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'literal-dot-source-after-binary-fixture'
            Expected = $true
            Source = @'
$binaryPipeResult = Invoke-PrivateMarkerProcess
. './synthetic-later.ps1'
'@
        },
        [pscustomobject]@{
            Name = 'reassigned-bootstrap-dot-source'
            Expected = $false
            Source = @'
$processBoundary = Join-Path $root 'scripts/private-marker-process.ps1'
$processBoundary = './synthetic-early.ps1'
. $processBoundary
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
            Name = 'wrapped-set-variable-bootstrap-dot-source'
            Expected = $false
            Source = @'
function Set-EarlyBoundary {
    Set-Variable -Name processBoundary -Value ./synthetic.ps1 -Scope 1
}
$processBoundary = Join-Path $root 'scripts/private-marker-process.ps1'
Set-EarlyBoundary
. $processBoundary
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'get-command-function-scriptblock'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
(Get-Command Invoke-Early).ScriptBlock.Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'get-command-alias-function-scriptblock'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
(gcm Invoke-Early).ScriptBlock.Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'module-qualified-get-command-function-scriptblock'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
(Microsoft.PowerShell.Core\Get-Command Invoke-Early).ScriptBlock.Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'get-item-function-scriptblock'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
(Get-Item function:Invoke-Early).ScriptBlock.Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-get-command'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$functionName = 'Invoke-Early'
(Get-Command $functionName).ScriptBlock.Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-invoke-expression'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$expression = 'Invoke-Early'
Invoke-Expression $expression
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-scriptblock-invoke'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$expression = 'Invoke-Early'
[scriptblock]::Create($expression).Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'execution-context-invoke-script'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$ExecutionContext.InvokeCommand.InvokeScript('Invoke-Early')
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-execution-context-invoke-script'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
function Invoke-Dynamic {
    $ExecutionContext.InvokeCommand.InvokeScript('Invoke-Early')
}
Invoke-Dynamic
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-constructor-helper'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
[EarlyClass]::new()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-method-invoke'
            Expected = $false
            Source = @'
class EarlyClass {
    [void] Invoke() {
        Invoke-PrivateMarkerProcess
    }
}
[EarlyClass]::new().Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'new-object-class-constructor'
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
            Name = 'new-object-alias-class-constructor'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
Set-Alias New-Early New-Object
$early = New-Early EarlyClass
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'activator-class-constructor'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
$early = [Activator]::CreateInstance([EarlyClass])
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'converted-class-constructor'
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
    [void] Run() {
    }
}
$early = [EarlyClass]::Instance
$early.Run()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'static-member-risky-class-wrapper-argument'
            Expected = $false
            Source = @'
class EarlyClass {
    static [EarlyClass] $Instance = [EarlyClass]::new()
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
    [void] Run() {
    }
}
function Invoke-Early($Value) {
    $Value.Run()
}
Invoke-Early ([EarlyClass]::Instance)
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-new-class-constructor'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
$earlyType = [EarlyClass]
$early = $earlyType::new()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapped-new-object-class-constructor'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
function Invoke-Early {
    New-Object EarlyClass
}
Invoke-Early
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'typed-parameter-class-conversion'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerProcess
    }
}
function Invoke-Early([EarlyClass]$Value) {
    return $Value
}
Invoke-Early @{}
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'transitive-risky-class-constructor'
            Expected = $false
            Source = @'
class InnerClass {
    InnerClass() {
        Invoke-PrivateMarkerProcess
    }
}
class OuterClass {
    OuterClass() {
        [InnerClass]::new()
    }
}
$early = [OuterClass]::new()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-expression-literal-helper'
            Expected = $false
            Source = @'
Invoke-Expression 'Invoke-PrivateMarkerProcess'
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'foreach-function-provider'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
1 | ForEach-Object ${function:Invoke-Early}
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'literal-native-application-lookup'
            Expected = $true
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
$gitCommand = Get-Command git -CommandType Application
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'function-provider-reference'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
${function:Invoke-Early}.Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-command-function-provider-reference'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerProcess
}
Invoke-Command -ScriptBlock ${function:Invoke-Early}
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'uninvoked-scriptblock'
            Expected = $true
            Source = @'
$unused = { Invoke-PrivateMarkerProcess }
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
            Name = 'stored-scriptblock-invoke'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerProcess }
$stored.Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-call-operator'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerProcess }
& $stored
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
        },
        [pscustomobject]@{
            Name = 'nested-inner'
            Expected = $false
            Source = @'
$binaryPipeResult = Invoke-PrivateMarkerProcess -Value $(Invoke-PrivateMarkerProcess)
'@
        },
        [pscustomobject]@{
            Name = 'invoked-scriptblock-member'
            Expected = $false
            Source = @'
({ Invoke-PrivateMarkerProcess }).Invoke()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoked-scriptblock-return-as-is'
            Expected = $false
            Source = @'
({ Invoke-PrivateMarkerProcess }).InvokeReturnAsIs()
$binaryPipeResult = Invoke-PrivateMarkerProcess
'@
        }
    )
    foreach ($case in $cases) {
        $actual = Test-FirstPrivateMarkerProcessInvocationIsBinaryTransport `
            -Source $case.Source
        if ($actual -ne $case.Expected) {
            Add-Failure "First-invocation validator regression failed: $($case.Name)."
        }
    }

    # generic ExecutionContext除外はconsumerの形だけを判定する。直接Get/Setは
    # 後段の変数名検査へ渡し、returnされたtableはその場でfail closedにする。
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

function Assert-ReturnedPsVariableTableMutatesScriptScope {
    # AST validatorが閉じるreturn-wrapper経路は実際にscript scopeを書き換える。
    # PS5.1/PS7の双方で挙動を実測し、fixtureが架空の脅威へ退行しないよう固定する。
    $originalRoot = $script:root
    $proofRoot = 'private-marker-return-wrapper-proof'
    try {
        function Get-ProofVariableTable {
            return $ExecutionContext.SessionState.PSVariable
        }
        function Set-ProofScriptRoot {
            (Get-ProofVariableTable).Set('script:root', $proofRoot)
        }

        Set-ProofScriptRoot
        if ($script:root -cne $proofRoot) {
            Add-Failure 'Expected returned PSVariable table to mutate script:root at runtime.'
        }
    }
    finally {
        # self-test後段の実repo scanへproof値を漏らさない。
        $script:root = $originalRoot
    }
}

function Assert-FirstPrivateMarkerProcessInvocationIsBinaryTransport {
    # 実fileも同じpure validatorへ通し、fixture追加時の呼出し順退行を検出する。
    $source = [System.IO.File]::ReadAllText($selfTestScriptPath)
    if (-not (Test-FirstPrivateMarkerProcessInvocationIsBinaryTransport `
        -Source $source)) {
        Add-Failure 'Expected binary transport to be the first executable bounded helper invocation.'
    }
}

function Get-ProcessEnvironmentSnapshot {
    $snapshot = @{}
    $environment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($name in $environment.Keys) {
        $snapshot["$name"] = [string]$environment[$name]
    }
    return $snapshot
}

function Assert-ProcessEnvironmentUnchanged {
    param(
        [hashtable]$Expected,
        [string]$Context
    )

    $actual = Get-ProcessEnvironmentSnapshot
    $differentNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Expected.Keys + $actual.Keys) | Sort-Object -Unique) {
        if ($Expected.ContainsKey($name) -ne $actual.ContainsKey($name) -or
            ($Expected.ContainsKey($name) -and $Expected[$name] -cne $actual[$name])) {
            # 周辺環境には秘密値があり得るため、差分は変数名だけを報告する。
            $differentNames.Add("$name") | Out-Null
        }
    }
    if ($differentNames.Count -gt 0) {
        Add-Failure "$Context changed parent environment variables: $($differentNames -join ', ')."
    }
}

function Invoke-Scanner {
    param(
        [string]$ScanPath,
        [hashtable]$EnvironmentOverrides = @{},
        [string[]]$AdditionalArguments = @(),
        [string]$ScannerPath = $scanner
    )

    $arguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $arguments += @('-ExecutionPolicy', 'Bypass')
    }
    $arguments += @('-File', $ScannerPath, '-Path', $ScanPath)
    $arguments += $AdditionalArguments
    $result = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $arguments `
        -WorkingDirectory $root `
        -EnvironmentOverrides $EnvironmentOverrides `
        -MaximumStandardOutputBytes 4194304 `
        -TimeoutMilliseconds 30000
    return ConvertTo-TestProcessResult -Result $result
}

function Assert-FixedProcessBoundaryFailure {
    param(
        [pscustomobject]$Result,
        [string]$Context,
        [string[]]$ForbiddenPaths,
        [ValidateSet('process-boundary', 'regex-timeout')]
        [string]$Integrity = 'process-boundary'
    )

    $expected = (
        'Private marker scan failed closed ' +
        "(integrity: $Integrity)."
    )
    $expectedStderrBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
        $expected + [Environment]::NewLine
    )
    if ($Result.ExitCode -ne 2 -or
        $Result.Output.Trim() -cne $expected -or
        $Result.StandardOutputBytes.Length -ne 0 -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedStderrBytes `
            -Actual $Result.StandardErrorBytes)) {
        Add-Failure (
            "$Context must return fixed redacted stderr and exit 2. " +
            "Exit: $($Result.ExitCode); " +
            "stdout bytes: $($Result.StandardOutputBytes.Length); " +
            "stderr bytes: $($Result.StandardErrorBytes.Length)."
        )
        return
    }
    $pathComparison = if (Test-PrivateMarkerWindowsHost) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    foreach ($forbiddenPath in $ForbiddenPaths) {
        if ([string]::IsNullOrWhiteSpace($forbiddenPath)) {
            continue
        }
        $pathForms = @(
            $forbiddenPath,
            $forbiddenPath.Replace('\', '/'),
            $forbiddenPath.Replace('/', '\')
        ) | Sort-Object -Unique
        foreach ($pathForm in $pathForms) {
            if ($Result.Output.IndexOf($pathForm, $pathComparison) -ge 0) {
                Add-Failure "$Context leaked an absolute boundary path."
                return
            }
        }
    }
}

function Invoke-HermeticGit {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments,
        [string]$IsolationRoot,
        [byte[]]$StandardInputBytes = $null
    )

    # function objectとの曖昧性を排除し、native Gitだけを固定して選ぶ。
    $gitCommands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    if ($gitCommands.Count -eq 0) {
        throw 'Native Git is required for the private-marker scanner self-test.'
    }
    $gitCommand = $gitCommands[0]
    $result = Invoke-PrivateMarkerProcess `
        -FileName $gitCommand.Source `
        -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -SanitizeGitEnvironment `
        -IsolationRoot $IsolationRoot `
        -StandardInputBytes $StandardInputBytes `
        -TimeoutMilliseconds 20000
    return ConvertTo-TestProcessResult -Result $result
}

function ConvertTo-TestProcessResult {
    param([pscustomobject]$Result)

    $stdout = [System.Text.UTF8Encoding]::new($false).GetString(
        $Result.StandardOutputBytes
    )
    $stderr = [System.Text.UTF8Encoding]::new($false).GetString(
        $Result.StandardErrorBytes
    )
    $healthyBoundary = $Result.StreamsCompleted -and
        $Result.TreeStopped -and
        -not $Result.TimedOut -and
        -not $Result.OutputLimitExceeded -and
        -not $Result.InputWriteFailed -and
        -not $Result.PipeLeakDetected
    $exitCode = if ($healthyBoundary) { $Result.ExitCode } else { -1 }
    $diagnostics = New-Object System.Collections.Generic.List[string]
    if (-not $Result.StreamsCompleted) { $diagnostics.Add('streams-incomplete') }
    if (-not $Result.TreeStopped) { $diagnostics.Add('tree-cleanup-failed') }
    if ($Result.TimedOut) { $diagnostics.Add('timed-out') }
    if ($Result.OutputLimitExceeded) { $diagnostics.Add('output-limit') }
    if ($Result.InputWriteFailed) { $diagnostics.Add('input-write') }
    if ($Result.PipeLeakDetected) { $diagnostics.Add('pipe-leak') }
    $output = (@($stdout, $stderr) -join [Environment]::NewLine).TrimEnd()
    if ($diagnostics.Count -gt 0) {
        $output += [Environment]::NewLine + (
            'bounded-process-failure: ' + ($diagnostics -join ',')
        )
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        RawExitCode = $Result.ExitCode
        Output = $output
        TimedOut = $Result.TimedOut
        OutputLimitExceeded = $Result.OutputLimitExceeded
        InputWriteFailed = $Result.InputWriteFailed
        PipeLeakDetected = $Result.PipeLeakDetected
        StreamsCompleted = $Result.StreamsCompleted
        TreeStopped = $Result.TreeStopped
        StandardOutputBytes = [byte[]]$Result.StandardOutputBytes
        StandardErrorBytes = [byte[]]$Result.StandardErrorBytes
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-code-devlog-hooks-scan-test-" + [System.Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tempRoot)
$emptyCommandPath = Join-Path $tempRoot 'empty-command-path'
[void][System.IO.Directory]::CreateDirectory($emptyCommandPath)
$preexistingScannerIsolationRoots = @(
    [System.IO.Directory]::EnumerateDirectories(
        [System.IO.Path]::GetTempPath(),
        'claude-code-devlog-hooks-git-*',
        [System.IO.SearchOption]::TopDirectoryOnly
    ) |
        ForEach-Object { [System.IO.Path]::GetFileName($_) }
)

try {
    Assert-FirstPrivateMarkerProcessValidatorRegressions
    Assert-FirstPrivateMarkerProcessInvocationIsBinaryTransport

    # helperの初回実行をBOM-less `-File` childに固定する。3 byte単位の部分read、
    # EOF、独立stderr、nonzero exitを同時に測り、Windowsのsuspended
    # CreateProcessW→handle allowlist→Job→resume境界をraw byteで検証する。
    $binaryEchoPath = Join-Path $tempRoot 'BinaryEcho.ps1'
    $binaryEchoSource = @'
$inputStream = [Console]::OpenStandardInput()
$readBuffer = New-Object byte[] 3
$outputStream = [Console]::OpenStandardOutput()
$readCount = $inputStream.Read($readBuffer, 0, $readBuffer.Length)
while ($readCount -gt 0) {
    $outputStream.Write($readBuffer, 0, $readCount)
    $outputStream.Flush()
    $readCount = $inputStream.Read($readBuffer, 0, $readBuffer.Length)
}
$errorBytes = [byte[]]@(255, 254, 128, 127, 13, 10, 1, 0)
$errorStream = [Console]::OpenStandardError()
$errorStream.Write($errorBytes, 0, 3)
$errorStream.Flush()
$errorStream.Write($errorBytes, 3, $errorBytes.Length - 3)
$errorStream.Flush()
exit 37
'@
    [System.IO.File]::WriteAllText(
        $binaryEchoPath,
        $binaryEchoSource,
        [System.Text.UTF8Encoding]::new($false)
    )
    [byte[]]$binaryProbeBytes = @(
        0x00, 0x80, 0xFF, 0x01, 0x0A, 0x0D,
        0x7F, 0xFE, 0x02, 0x81, 0xFD, 0x03
    )
    $binaryHostArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $binaryHostArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $binaryPipeResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments ($binaryHostArguments + @('-File', $binaryEchoPath)) `
        -StandardInputBytes $binaryProbeBytes `
        -WorkingDirectory $tempRoot `
        -MaximumStandardInputBytes $binaryProbeBytes.Length `
        -MaximumStandardOutputBytes $binaryProbeBytes.Length `
        -MaximumStandardErrorBytes 8 `
        -TimeoutMilliseconds 10000
    [byte[]]$expectedBinaryErrorBytes = @(
        0xFF, 0xFE, 0x80, 0x7F, 0x0D, 0x0A, 0x01, 0x00
    )
    if ($binaryPipeResult.ExitCode -ne 37 -or
        $binaryPipeResult.TimedOut -or
        $binaryPipeResult.OutputLimitExceeded -or
        $binaryPipeResult.InputWriteFailed -or
        $binaryPipeResult.PipeLeakDetected -or
        -not $binaryPipeResult.StreamsCompleted -or
        -not $binaryPipeResult.TreeStopped -or
        -not (Test-ByteArraysEqual `
            -Expected $binaryProbeBytes `
            -Actual $binaryPipeResult.StandardOutputBytes) -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedBinaryErrorBytes `
            -Actual $binaryPipeResult.StandardErrorBytes)) {
        Add-Failure 'Expected the first BOM-less -File child to preserve binary stdin/stdout/stderr, EOF, and exit code exactly.'
    }

    # 初回bounded helper成立後にだけ危険なruntime proofを動かす。これ以前へ
    # 移動するとself-test自身が検証対象のfirst-invocation policyへ違反する。
    Assert-ReturnedPsVariableTableMutatesScriptScope

    # PowerShell childはUTF-8 preambleを自身のinputとして受理し得るため、
    # native Git batch protocolでもstdin/stdoutの完全一致とcaller encoding不変を測る。
    $rawGitCommands = @(
        Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    )
    if ($rawGitCommands.Count -eq 0) {
        Add-Failure 'Expected native Git to be available for the raw transport regression.'
    } else {
        $rawGitRoot = Join-Path $tempRoot 'raw-git-transport'
        $rawGitIsolationRoot = Join-Path $tempRoot 'raw-git-isolation'
        New-Item -ItemType Directory -Path $rawGitRoot | Out-Null
        New-Item -ItemType Directory -Path $rawGitIsolationRoot | Out-Null
        $rawGitPath = $rawGitCommands[0].Source

        $rawGitInitResult = Invoke-HermeticGit `
            -WorkingDirectory $rawGitRoot `
            -IsolationRoot $rawGitIsolationRoot `
            -Arguments @('init', '-q')
        if ($rawGitInitResult.ExitCode -ne 0 -or
            -not $rawGitInitResult.StreamsCompleted -or
            -not $rawGitInitResult.TreeStopped) {
            Add-Failure 'Expected the native Git raw transport fixture to initialize.'
        } else {
            [byte[]]$rawGitBlobBytes = @(
                0x00, 0x80, 0xFF, 0x0A, 0x0D, 0x01, 0x02
            )
            [System.IO.File]::WriteAllBytes(
                (Join-Path $rawGitRoot 'blob.bin'),
                $rawGitBlobBytes
            )
            $rawGitHashResult = Invoke-HermeticGit `
                -WorkingDirectory $rawGitRoot `
                -IsolationRoot $rawGitIsolationRoot `
                -Arguments @('hash-object', '-w', '--', 'blob.bin')
            $rawGitObjectId = [System.Text.Encoding]::ASCII.GetString(
                $rawGitHashResult.StandardOutputBytes
            ).Trim()
            if ($rawGitHashResult.ExitCode -ne 0 -or
                -not $rawGitHashResult.StreamsCompleted -or
                -not $rawGitHashResult.TreeStopped -or
                $rawGitObjectId -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
                Add-Failure 'Expected the native Git raw transport fixture to create a blob object.'
            } else {
                $inputCodePageBefore = [Console]::InputEncoding.CodePage
                $inputPreambleBefore = [Convert]::ToBase64String(
                    [Console]::InputEncoding.GetPreamble()
                )
                [byte[]]$rawGitBatchInput =
                    [System.Text.Encoding]::ASCII.GetBytes(
                        "$rawGitObjectId`n"
                    )
                $rawGitBatchResult = Invoke-HermeticGit `
                    -WorkingDirectory $rawGitRoot `
                    -IsolationRoot $rawGitIsolationRoot `
                    -Arguments @('cat-file', '--batch') `
                    -StandardInputBytes $rawGitBatchInput
                [byte[]]$rawGitHeaderBytes =
                    [System.Text.Encoding]::ASCII.GetBytes(
                        "$rawGitObjectId blob $($rawGitBlobBytes.Length)`n"
                    )
                [byte[]]$expectedRawGitOutput = @(
                    @($rawGitHeaderBytes) +
                    @($rawGitBlobBytes) +
                    @(0x0A)
                )
                if ($rawGitBatchResult.ExitCode -ne 0 -or
                    -not $rawGitBatchResult.StreamsCompleted -or
                    -not $rawGitBatchResult.TreeStopped -or
                    $rawGitBatchResult.StandardErrorBytes.Length -ne 0 -or
                    -not (Test-ByteArraysEqual `
                        -Expected $expectedRawGitOutput `
                        -Actual $rawGitBatchResult.StandardOutputBytes)) {
                    Add-Failure 'Expected native git cat-file batch transport to remain byte-exact without a UTF-8 preamble.'
                }
                if ([Console]::InputEncoding.CodePage -ne
                        $inputCodePageBefore -or
                    [Convert]::ToBase64String(
                        [Console]::InputEncoding.GetPreamble()
                    ) -ne $inputPreambleBefore) {
                    Add-Failure 'Expected raw input transport to preserve the caller console input encoding.'
                }
            }
        }
    }

    # Prefix・UTF-8 multibyte・実platform改行をすべて含めたraw byte数で、
    # exact limitは成功し、1 byte超過だけがbounded failureになることを確認する。
    $boundaryEmitterPath = Join-Path $tempRoot 'RawBoundaryEmitter.ps1'
    $boundaryEmitterSource = @'
param([int]$TotalBytes)
$prefixText = ([char]0x5883).ToString() + [char]0x754C + ':'
$prefixBytes = [System.Text.Encoding]::UTF8.GetBytes($prefixText)
$newlineBytes = [System.Text.Encoding]::UTF8.GetBytes(
    [Environment]::NewLine
)
if ($TotalBytes -lt ($prefixBytes.Length + $newlineBytes.Length)) {
    throw 'Requested payload is too small.'
}
$payload = New-Object byte[] $TotalBytes
[Array]::Copy($prefixBytes, 0, $payload, 0, $prefixBytes.Length)
for ($index = $prefixBytes.Length;
    $index -lt ($payload.Length - $newlineBytes.Length);
    $index++) {
    $payload[$index] = [byte][char]'x'
}
[Array]::Copy(
    $newlineBytes,
    0,
    $payload,
    $payload.Length - $newlineBytes.Length,
    $newlineBytes.Length
)
$stream = [Console]::OpenStandardOutput()
$stream.Write($payload, 0, $payload.Length)
$stream.Flush()
'@
    [System.IO.File]::WriteAllText(
        $boundaryEmitterPath,
        $boundaryEmitterSource,
        [System.Text.UTF8Encoding]::new($true)
    )
    $boundaryHostArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $boundaryHostArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $boundaryLimit = 65536
    $withinBoundaryResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments (
            $boundaryHostArguments +
            @('-File', $boundaryEmitterPath, $boundaryLimit)
        ) `
        -WorkingDirectory $tempRoot `
        -MaximumStandardOutputBytes $boundaryLimit `
        -MaximumStandardErrorBytes 8192 `
        -TimeoutMilliseconds 10000
    $expectedBoundaryPrefix = [System.Text.Encoding]::UTF8.GetBytes(
        ([char]0x5883).ToString() + [char]0x754C + ':'
    )
    $expectedBoundaryNewline = [System.Text.Encoding]::UTF8.GetBytes(
        [Environment]::NewLine
    )
    $boundaryPrefixMatches =
        $withinBoundaryResult.StandardOutputBytes.Length -ge
            $expectedBoundaryPrefix.Length
    if ($boundaryPrefixMatches) {
        for ($index = 0;
            $index -lt $expectedBoundaryPrefix.Length;
            $index++) {
            if ($withinBoundaryResult.StandardOutputBytes[$index] -ne
                $expectedBoundaryPrefix[$index]) {
                $boundaryPrefixMatches = $false
                break
            }
        }
    }
    $boundaryNewlineMatches =
        $withinBoundaryResult.StandardOutputBytes.Length -ge
            $expectedBoundaryNewline.Length
    if ($boundaryNewlineMatches) {
        $newlineOffset =
            $withinBoundaryResult.StandardOutputBytes.Length -
            $expectedBoundaryNewline.Length
        for ($index = 0;
            $index -lt $expectedBoundaryNewline.Length;
            $index++) {
            if ($withinBoundaryResult.StandardOutputBytes[
                    $newlineOffset + $index
                ] -ne $expectedBoundaryNewline[$index]) {
                $boundaryNewlineMatches = $false
                break
            }
        }
    }
    if ($withinBoundaryResult.ExitCode -ne 0 -or
        $withinBoundaryResult.OutputLimitExceeded -or
        -not $withinBoundaryResult.StreamsCompleted -or
        -not $withinBoundaryResult.TreeStopped -or
        $withinBoundaryResult.StandardOutputBytes.Length -ne $boundaryLimit -or
        -not $boundaryPrefixMatches -or
        -not $boundaryNewlineMatches) {
        Add-Failure 'Expected the exact raw UTF-8 output boundary, including prefix and platform newline, to pass.'
    }

    $overBoundaryResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments (
            $boundaryHostArguments +
            @('-File', $boundaryEmitterPath, ($boundaryLimit + 1))
        ) `
        -WorkingDirectory $tempRoot `
        -MaximumStandardOutputBytes $boundaryLimit `
        -MaximumStandardErrorBytes 8192 `
        -TimeoutMilliseconds 10000
    if (-not $overBoundaryResult.OutputLimitExceeded -or
        -not $overBoundaryResult.TreeStopped -or
        $overBoundaryResult.StandardOutputBytes.Length -gt $boundaryLimit) {
        Add-Failure 'Expected one raw UTF-8 byte beyond the output boundary to stop fail-closed.'
    }

    # Hostile user pathはResolve-Path前後のprovider例外からもraw出力しない。
    $hostilePathPrefix =
        'hostile-nonexistent-' + [System.Guid]::NewGuid().ToString('N')
    $hostilePathCharacters = @(
        [char]0x202E,
        [char]0x2028,
        [char]0x2029
    )
    $hostileMissingPath = Join-Path $tempRoot (
        $hostilePathPrefix +
        ($hostilePathCharacters -join '-') +
        '-spoof'
    )
    $hostileArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $hostileArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $hostileArguments += @(
        '-File',
        $scanner,
        '-Path',
        $hostileMissingPath
    )
    $hostilePathResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $hostileArguments `
        -WorkingDirectory $root `
        -MaximumStandardOutputBytes 256 `
        -MaximumStandardErrorBytes 512 `
        -TimeoutMilliseconds 10000
    $hostileCombinedBytes = New-Object byte[] (
        $hostilePathResult.StandardOutputBytes.Length +
        $hostilePathResult.StandardErrorBytes.Length
    )
    [Array]::Copy(
        $hostilePathResult.StandardOutputBytes,
        0,
        $hostileCombinedBytes,
        0,
        $hostilePathResult.StandardOutputBytes.Length
    )
    [Array]::Copy(
        $hostilePathResult.StandardErrorBytes,
        0,
        $hostileCombinedBytes,
        $hostilePathResult.StandardOutputBytes.Length,
        $hostilePathResult.StandardErrorBytes.Length
    )
    $hostileFixedDiagnostic =
        'Private marker scan failed closed (integrity: scan-root-missing).'
    $expectedHostileStdout = New-Object byte[] 0
    $expectedHostileStderr = [System.Text.Encoding]::UTF8.GetBytes(
        $hostileFixedDiagnostic + [Environment]::NewLine
    )
    $hostileLeakDetected = $false
    # exact bytesだけでframing混入は検出できるが、絶対pathとUnicode制御の
    # 非出力契約も個別に残し、regressionの原因を一意にする。
    foreach ($sensitiveText in @(
        $scanner,
        $hostileMissingPath,
        $hostilePathPrefix
    )) {
        foreach ($encoding in @(
            [System.Text.Encoding]::UTF8,
            [System.Text.Encoding]::Unicode,
            [System.Text.Encoding]::BigEndianUnicode
        )) {
            if (Test-ByteArrayContainsSequence `
                    -Haystack $hostileCombinedBytes `
                    -Needle $encoding.GetBytes($sensitiveText)) {
                $hostileLeakDetected = $true
            }
        }
    }
    foreach ($hostileCharacter in $hostilePathCharacters) {
        if (Test-ByteArrayContainsSequence `
                -Haystack $hostileCombinedBytes `
                -Needle (
                    [System.Text.Encoding]::UTF8.GetBytes(
                        [string]$hostileCharacter
                    )
                )) {
            $hostileLeakDetected = $true
        }
    }
    if ($hostilePathResult.ExitCode -ne 2 -or
        $hostilePathResult.OutputLimitExceeded -or
        -not $hostilePathResult.StreamsCompleted -or
        -not $hostilePathResult.TreeStopped -or
        $hostilePathResult.StandardOutputBytes.Length -gt 256 -or
        $hostilePathResult.StandardErrorBytes.Length -gt 512 -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedHostileStdout `
            -Actual $hostilePathResult.StandardOutputBytes) -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedHostileStderr `
            -Actual $hostilePathResult.StandardErrorBytes) -or
        $hostileLeakDetected) {
        Add-Failure 'Expected hostile nonexistent scan paths to emit exactly one fixed stderr code plus the platform newline.'
    }

    # helper欠落でもPowerShellのErrorRecord framingへscanner/helper絶対pathを
    # 渡さず、process-boundary共通の固定exit 2だけを返す。
    $missingBoundaryRoot = Join-Path $tempRoot 'missing boundary'
    New-Item -ItemType Directory -Path $missingBoundaryRoot | Out-Null
    $scannerWithoutBoundary = Join-Path `
        $missingBoundaryRoot `
        'scan-private-markers.ps1'
    Copy-Item -LiteralPath $scanner -Destination $scannerWithoutBoundary
    $missingBoundaryResult = Invoke-Scanner `
        -ScanPath $root `
        -ScannerPath $scannerWithoutBoundary
    Assert-FixedProcessBoundaryFailure `
        -Result $missingBoundaryResult `
        -Context 'Missing process helper' `
        -ForbiddenPaths @(
            $root,
            $tempRoot,
            $scannerWithoutBoundary,
            $processBoundary
        )

    # helper自身がpath-bearing成功出力の後に例外化しても、dot-source出力と
    # ErrorRecord framingをどちらも破棄して固定stderrだけを返す。
    $throwingBoundaryRoot = Join-Path $tempRoot 'throwing boundary'
    New-Item -ItemType Directory -Path $throwingBoundaryRoot | Out-Null
    $scannerWithThrowingBoundary = Join-Path `
        $throwingBoundaryRoot `
        'scan-private-markers.ps1'
    $throwingBoundary = Join-Path `
        $throwingBoundaryRoot `
        'private-marker-process.ps1'
    Copy-Item -LiteralPath $scanner -Destination $scannerWithThrowingBoundary
    $boundaryLeakPayload = (
        $root + '|' +
        $tempRoot + '|' +
        $scannerWithThrowingBoundary + '|' +
        $throwingBoundary
    ).Replace("'", "''")
    Set-Content `
        -LiteralPath $throwingBoundary `
        -Encoding UTF8 `
        -Value @(
            "Write-Output '$boundaryLeakPayload'",
            "throw '$boundaryLeakPayload'"
        )
    $throwingBoundaryResult = Invoke-Scanner `
        -ScanPath $root `
        -ScannerPath $scannerWithThrowingBoundary
    Assert-FixedProcessBoundaryFailure `
        -Result $throwingBoundaryResult `
        -Context 'Throwing process helper' `
        -ForbiddenPaths @(
            $root,
            $tempRoot,
            $scannerWithThrowingBoundary,
            $throwingBoundary,
            $processBoundary
        )

    if (-not (Test-PrivateMarkerWindowsHost)) {
        # BusyBox互換shimは先頭optionを拒否してから実setsidへ委譲する。
        # override seam経由で実起動し、pure helperだけでなくhandshake全体を検証する。
        $realSetsidPath = @('/usr/bin/setsid', '/bin/setsid') |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        $chmodPath = @('/usr/bin/chmod', '/bin/chmod') |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        $busyBoxSetsidShim = $null
        $busyBoxSetsidInvokedPath = Join-Path `
            $tempRoot `
            'posix-busybox-setsid-invoked.txt'
        if (-not [string]::IsNullOrWhiteSpace($realSetsidPath) -and
            -not [string]::IsNullOrWhiteSpace($chmodPath)) {
            $busyBoxSetsidShim = Join-Path `
                $tempRoot `
                'posix-busybox-setsid-shim'
            $busyBoxSetsidTemplate = @'
#!/bin/sh
case "$1" in
    -*) exit 64 ;;
esac
printf '%s' 'invoked' > "__INVOKED__"
exec "__REAL_SETSID__" "$@"
'@
            $busyBoxSetsidScript = $busyBoxSetsidTemplate.Replace(
                '__INVOKED__',
                $busyBoxSetsidInvokedPath
            ).Replace(
                '__REAL_SETSID__',
                $realSetsidPath
            )
            [System.IO.File]::WriteAllText(
                $busyBoxSetsidShim,
                $busyBoxSetsidScript,
                [System.Text.UTF8Encoding]::new($false)
            )
            & $chmodPath '+x' $busyBoxSetsidShim
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'Expected the BusyBox-compatible setsid shim to become executable.'
                $busyBoxSetsidShim = $null
            }
        }

        # direct parentが終了済みでも、同じprocess groupの孫をsignalして
        # inherited pipeと遅延sentinelの両方を確実に閉じる。
        $posixSurvivedSentinels =
            New-Object System.Collections.Generic.List[string]
        $posixGateCases = @(
            [pscustomobject]@{
                Label = 'setsid-default'
                ForceNative = $false
                SetsidOverride = ''
            },
            [pscustomobject]@{
                Label = 'native'
                ForceNative = $true
                SetsidOverride = ''
            }
        )
        if (-not [string]::IsNullOrWhiteSpace($busyBoxSetsidShim)) {
            $posixGateCases += [pscustomobject]@{
                Label = 'setsid-busybox-shim'
                ForceNative = $false
                SetsidOverride = $busyBoxSetsidShim
            }
        }
        foreach ($posixGateCase in $posixGateCases) {
            $gateLabel = $posixGateCase.Label
            $startedSentinel =
                Join-Path $tempRoot "posix-$gateLabel-started.txt"
            $survivedSentinel =
                Join-Path $tempRoot "posix-$gateLabel-survived.txt"
            $posixSurvivedSentinels.Add($survivedSentinel) | Out-Null
            $escapedStartedSentinel = $startedSentinel.Replace("'", "''")
            $escapedSurvivedSentinel = $survivedSentinel.Replace("'", "''")
            $posixGrandchildTemplate = @'
[System.IO.File]::WriteAllText(
    '__STARTED__',
    'started',
    [System.Text.UTF8Encoding]::new($false)
)
Start-Sleep -Milliseconds 1500
[System.IO.File]::WriteAllText(
    '__SURVIVED__',
    'survived',
    [System.Text.UTF8Encoding]::new($false)
)
[Console]::Out.Write('late-output')
'@
            $posixGrandchildScript = $posixGrandchildTemplate.Replace(
                '__STARTED__',
                $escapedStartedSentinel
            ).Replace(
                '__SURVIVED__',
                $escapedSurvivedSentinel
            )
            $posixGrandchildEncoded = [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes(
                    $posixGrandchildScript
                )
            )
            $escapedPowerShellExecutable =
                $currentPowerShellExecutable.Replace("'", "''")
            $posixParentTemplate = @'
$ErrorActionPreference = 'Stop'
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = '__HOST__'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.ArgumentList.Add('-NoProfile')
$startInfo.ArgumentList.Add('-EncodedCommand')
$startInfo.ArgumentList.Add('__PAYLOAD__')
$child = [System.Diagnostics.Process]::Start($startInfo)
try {
    $started = $false
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if ([System.IO.File]::Exists('__STARTED__')) {
            $started = $true
            break
        }
        Start-Sleep -Milliseconds 10
    }
    if (-not $started) {
        exit 125
    }
}
finally {
    $child.Dispose()
}
'@
            $posixParentScript = $posixParentTemplate.Replace(
                '__HOST__',
                $escapedPowerShellExecutable
            ).Replace(
                '__PAYLOAD__',
                $posixGrandchildEncoded
            ).Replace(
                '__STARTED__',
                $escapedStartedSentinel
            )
            $posixParentEncoded = [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes($posixParentScript)
            )
            $posixInvokeParameters = @{
                FileName = $currentPowerShellExecutable
                Arguments = [string[]]@(
                    '-NoProfile',
                    '-EncodedCommand',
                    $posixParentEncoded
                )
                WorkingDirectory = $tempRoot
                IsolationRoot = (
                    Join-Path $tempRoot "posix-$gateLabel-isolation"
                )
                TimeoutMilliseconds = 10000
                StreamCompletionWaitMilliseconds = 250
                StreamCleanupWaitMilliseconds = 2000
                ForceNativePosixSessionGate =
                    [bool]$posixGateCase.ForceNative
            }
            if (-not [string]::IsNullOrWhiteSpace(
                    $posixGateCase.SetsidOverride
                )) {
                $posixInvokeParameters.PosixSetsidExecutableOverride =
                    $posixGateCase.SetsidOverride
            }
            $posixPipeResult = Invoke-PrivateMarkerProcess `
                @posixInvokeParameters
            if (-not $posixPipeResult.PipeLeakDetected -or
                $posixPipeResult.StreamsCompleted -or
                -not $posixPipeResult.TreeStopped -or
                -not $posixPipeResult.ContainmentEstablished -or
                $posixPipeResult.TimedOut -or
                $posixPipeResult.OutputLimitExceeded -or
                $posixPipeResult.InputWriteFailed) {
                Add-Failure "Expected POSIX $gateLabel containment to detect the child-held pipe and stop the process group."
            }
            if (-not (Test-Path -LiteralPath $startedSentinel -PathType Leaf)) {
                Add-Failure "Expected POSIX $gateLabel containment fixture to prove that its descendant started."
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($busyBoxSetsidShim) -and
            -not (Test-Path `
                -LiteralPath $busyBoxSetsidInvokedPath `
                -PathType Leaf)) {
            Add-Failure 'Expected the BusyBox-compatible setsid override to execute.'
        }

        if (-not [string]::IsNullOrWhiteSpace($busyBoxSetsidShim)) {
            # external launcherが即時forkしてtracked親だけ先にexitしても、
            # wrapper completion fileが実payloadの完了と非0 exit codeを返す。
            $earlyForkSetsidShim = Join-Path `
                $tempRoot `
                'posix-early-fork-setsid-shim'
            $earlyForkParentExitedPath = Join-Path `
                $tempRoot `
                'posix-early-fork-parent-exited.txt'
            $earlyForkTargetSentinel = Join-Path `
                $tempRoot `
                'posix-early-fork-target-ran.txt'
            $earlyForkSetsidTemplate = @'
#!/bin/sh
case "$1" in
    -*) exit 64 ;;
esac
(
    exec "__REAL_SETSID__" "$@"
) &
printf '%s' 'parent-exiting' > "__PARENT_EXITED__"
exit 0
'@
            $earlyForkSetsidScript = $earlyForkSetsidTemplate.Replace(
                '__REAL_SETSID__',
                $realSetsidPath
            ).Replace(
                '__PARENT_EXITED__',
                $earlyForkParentExitedPath
            )
            [System.IO.File]::WriteAllText(
                $earlyForkSetsidShim,
                $earlyForkSetsidScript,
                [System.Text.UTF8Encoding]::new($false)
            )
            & $chmodPath '+x' $earlyForkSetsidShim
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'Expected the early-fork setsid shim to become executable.'
            } else {
                $escapedEarlyForkSentinel =
                    $earlyForkTargetSentinel.Replace("'", "''")
                $earlyForkTargetScript = @"
Start-Sleep -Milliseconds 600
[System.IO.File]::WriteAllText(
    '$escapedEarlyForkSentinel',
    'ran',
    [System.Text.UTF8Encoding]::new(`$false)
)
exit 7
"@
                $earlyForkTargetEncoded = [Convert]::ToBase64String(
                    [System.Text.Encoding]::Unicode.GetBytes(
                        $earlyForkTargetScript
                    )
                )
                $earlyForkResult = Invoke-PrivateMarkerProcess `
                    -FileName $currentPowerShellExecutable `
                    -Arguments @(
                        '-NoProfile',
                        '-EncodedCommand',
                        $earlyForkTargetEncoded
                    ) `
                    -WorkingDirectory $tempRoot `
                    -IsolationRoot (
                        Join-Path $tempRoot 'posix-early-fork-isolation'
                    ) `
                    -TimeoutMilliseconds 5000 `
                    -PosixSetsidExecutableOverride $earlyForkSetsidShim
                if (-not (Test-Path `
                        -LiteralPath $earlyForkParentExitedPath `
                        -PathType Leaf) -or
                    -not (Test-Path `
                        -LiteralPath $earlyForkTargetSentinel `
                        -PathType Leaf) -or
                    $earlyForkResult.ExitCode -ne 7 -or
                    $earlyForkResult.TimedOut -or
                    $earlyForkResult.PipeLeakDetected -or
                    -not $earlyForkResult.StreamsCompleted -or
                    -not $earlyForkResult.TreeStopped -or
                    -not $earlyForkResult.ContainmentEstablished) {
                    Add-Failure 'Expected early-fork POSIX completion to preserve payload execution and exit code.'
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($busyBoxSetsidShim)) {
            # delayed shimはpayloadをreleaseする前にcaller deadlineを消費する。
            # operation timeout後も独立cleanup猶予で返り、targetは未実行を保つ。
            $delayedSetsidShim = Join-Path `
                $tempRoot `
                'posix-delayed-setsid-shim'
            $delayedTargetSentinel = Join-Path `
                $tempRoot `
                'posix-delayed-target-ran.txt'
            $delayedSetsidTemplate = @'
#!/bin/sh
case "$1" in
    -*) exit 64 ;;
esac
sleep 1
exec "__REAL_SETSID__" "$@"
'@
            [System.IO.File]::WriteAllText(
                $delayedSetsidShim,
                $delayedSetsidTemplate.Replace(
                    '__REAL_SETSID__',
                    $realSetsidPath
                ),
                [System.Text.UTF8Encoding]::new($false)
            )
            & $chmodPath '+x' $delayedSetsidShim
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'Expected the delayed setsid shim to become executable.'
            } else {
                $escapedDelayedSentinel =
                    $delayedTargetSentinel.Replace("'", "''")
                $delayedTargetScript = @"
[System.IO.File]::WriteAllText(
    '$escapedDelayedSentinel',
    'ran',
    [System.Text.UTF8Encoding]::new(`$false)
)
"@
                $delayedTargetEncoded = [Convert]::ToBase64String(
                    [System.Text.Encoding]::Unicode.GetBytes(
                        $delayedTargetScript
                    )
                )
                $deadlineClock =
                    [System.Diagnostics.Stopwatch]::StartNew()
                $deadlineFailure = $null
                try {
                    [void](Invoke-PrivateMarkerProcess `
                            -FileName $currentPowerShellExecutable `
                            -Arguments @(
                                '-NoProfile',
                                '-EncodedCommand',
                                $delayedTargetEncoded
                            ) `
                            -WorkingDirectory $tempRoot `
                            -IsolationRoot (
                                Join-Path `
                                    $tempRoot `
                                    'posix-delayed-isolation'
                            ) `
                            -TimeoutMilliseconds 250 `
                            -PosixSetsidExecutableOverride `
                                $delayedSetsidShim)
                }
                catch {
                    $deadlineFailure = $_.Exception.Message
                }
                $deadlineClock.Stop()
                if ([string]::IsNullOrWhiteSpace($deadlineFailure) -or
                    $deadlineFailure -notmatch
                        'bounded POSIX session gate') {
                    Add-Failure 'Expected the delayed setsid handshake to fail closed at the caller deadline.'
                }
                if ($deadlineClock.ElapsedMilliseconds -gt 7000) {
                    Add-Failure 'Expected POSIX handshake timeout cleanup to use an independent finite slack.'
                }
                Start-Sleep -Milliseconds 1250
                if (Test-Path -LiteralPath $delayedTargetSentinel) {
                    Add-Failure 'Expected the timed-out POSIX handshake never to release its target payload.'
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($busyBoxSetsidShim)) {
            # tracked shimを先に終了させ、operation deadline後にbackground childが
            # 実setsidへexecしてready PIDを公開する。late-ready pollingがその
            # 新しいPGIDを回収し、release前に停止したことをPID消滅で直接測る。
            $lateReadySetsidShim = Join-Path `
                $tempRoot `
                'posix-late-ready-setsid-shim'
            $lateReadyChildPidPath = Join-Path `
                $tempRoot `
                'posix-late-ready-child.pid'
            $lateReadyParentExitedPath = Join-Path `
                $tempRoot `
                'posix-late-ready-parent-exited.txt'
            $lateReadyAwakePath = Join-Path `
                $tempRoot `
                'posix-late-ready-awake.txt'
            $lateReadyTargetSentinel = Join-Path `
                $tempRoot `
                'posix-late-ready-target-ran.txt'
            $lateReadySetsidTemplate = @'
#!/bin/sh
case "$1" in
    -*) exit 64 ;;
esac
(
    sleep 1
    printf '%s' 'awake' > "__AWAKE__"
    exec "__REAL_SETSID__" "$@"
) &
late_pid=$!
printf '%s' "$late_pid" > "__CHILD_PID__"
printf '%s' 'parent-exiting' > "__PARENT_EXITED__"
exit 0
'@
            $lateReadySetsidScript = $lateReadySetsidTemplate.Replace(
                '__AWAKE__',
                $lateReadyAwakePath
            ).Replace(
                '__REAL_SETSID__',
                $realSetsidPath
            ).Replace(
                '__CHILD_PID__',
                $lateReadyChildPidPath
            ).Replace(
                '__PARENT_EXITED__',
                $lateReadyParentExitedPath
            )
            [System.IO.File]::WriteAllText(
                $lateReadySetsidShim,
                $lateReadySetsidScript,
                [System.Text.UTF8Encoding]::new($false)
            )
            & $chmodPath '+x' $lateReadySetsidShim
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'Expected the late-ready setsid shim to become executable.'
            } else {
                $escapedLateReadySentinel =
                    $lateReadyTargetSentinel.Replace("'", "''")
                $lateReadyTargetScript = @"
[System.IO.File]::WriteAllText(
    '$escapedLateReadySentinel',
    'ran',
    [System.Text.UTF8Encoding]::new(`$false)
)
"@
                $lateReadyTargetEncoded = [Convert]::ToBase64String(
                    [System.Text.Encoding]::Unicode.GetBytes(
                        $lateReadyTargetScript
                    )
                )
                $lateReadyClock =
                    [System.Diagnostics.Stopwatch]::StartNew()
                $lateReadyFailure = $null
                try {
                    [void](Invoke-PrivateMarkerProcess `
                            -FileName $currentPowerShellExecutable `
                            -Arguments @(
                                '-NoProfile',
                                '-EncodedCommand',
                                $lateReadyTargetEncoded
                            ) `
                            -WorkingDirectory $tempRoot `
                            -IsolationRoot (
                                Join-Path `
                                    $tempRoot `
                                    'posix-late-ready-isolation'
                            ) `
                            -TimeoutMilliseconds 250 `
                            -PosixSetsidExecutableOverride `
                                $lateReadySetsidShim)
                }
                catch {
                    $lateReadyFailure = $_.Exception.Message
                }
                $lateReadyClock.Stop()
                if ([string]::IsNullOrWhiteSpace($lateReadyFailure) -or
                    $lateReadyFailure -notmatch
                        'bounded POSIX session gate') {
                    Add-Failure 'Expected the late-ready setsid handshake to fail closed at the caller deadline.'
                }
                if ($lateReadyClock.ElapsedMilliseconds -gt 7000) {
                    Add-Failure 'Expected late-ready POSIX cleanup to stay within the shared finite cleanup budget.'
                }
                if (-not (Test-Path `
                        -LiteralPath $lateReadyParentExitedPath `
                        -PathType Leaf) -or
                    -not (Test-Path `
                        -LiteralPath $lateReadyAwakePath `
                        -PathType Leaf) -or
                    -not (Test-Path `
                        -LiteralPath $lateReadyChildPidPath `
                        -PathType Leaf)) {
                    Add-Failure 'Expected the late-ready fixture to prove parent exit and delayed child wakeup.'
                } else {
                    $lateReadyChildPidText = (
                        [System.IO.File]::ReadAllText(
                            $lateReadyChildPidPath
                        )
                    ).Trim()
                    $lateReadyChildPid = 0
                    if (-not [int]::TryParse(
                            $lateReadyChildPidText,
                            [ref]$lateReadyChildPid
                        ) -or
                        $lateReadyChildPid -le 0) {
                        Add-Failure 'Expected a positive late-ready child PID.'
                    } else {
                        $lateReadyChildAlive = $true
                        for ($attempt = 0;
                            $attempt -lt 200 -and $lateReadyChildAlive;
                            $attempt++) {
                            try {
                                $lateReadyChildProcess =
                                    [System.Diagnostics.Process]::GetProcessById(
                                        $lateReadyChildPid
                                    )
                                try {
                                    $lateReadyChildAlive =
                                        -not $lateReadyChildProcess.HasExited
                                }
                                finally {
                                    $lateReadyChildProcess.Dispose()
                                }
                            }
                            catch {
                                $lateReadyChildAlive = $false
                            }
                            if ($lateReadyChildAlive) {
                                Start-Sleep -Milliseconds 10
                            }
                        }
                        if ($lateReadyChildAlive) {
                            Add-Failure 'Expected late-ready cleanup to terminate the recovered process group.'
                        }
                    }
                }
                if (Test-Path -LiteralPath $lateReadyTargetSentinel) {
                    Add-Failure 'Expected late-ready cleanup never to release the target payload.'
                }
            }
        }

        Start-Sleep -Milliseconds 1750
        foreach ($survivedSentinel in $posixSurvivedSentinels) {
            if (Test-Path -LiteralPath $survivedSentinel) {
                Add-Failure 'Expected POSIX process-group cleanup to stop every delayed descendant sentinel.'
                break
            }
        }

        # kill(2)の戻り値-1は同じでも、ESRCHだけを「既に停止済み」と
        # みなし、EPERM/EACCESをTreeStopped成功へ昇格させない。
        if (-not [PrivateMarker.PosixSignal]::IsSuccessfulResult(0, 0) -or
            -not [PrivateMarker.PosixSignal]::IsSuccessfulResult(-1, 3) -or
            [PrivateMarker.PosixSignal]::IsSuccessfulResult(-1, 1) -or
            [PrivateMarker.PosixSignal]::IsSuccessfulResult(-1, 13)) {
            Add-Failure 'Expected POSIX cleanup to accept success/ESRCH and reject EPERM/EACCES.'
        }
    }

    if (Test-PrivateMarkerWindowsHost) {
        # success pathもFileStream ownershipをContainedProcessへ移し、wrapperの
        # finallyで明示Disposeする。40回後のGCで線形handle増加が残らないことを測る。
        $handleProbeExecutable = [Environment]::GetEnvironmentVariable(
            'ComSpec',
            'Process'
        )
        if ([string]::IsNullOrWhiteSpace($handleProbeExecutable) -or
            -not (Test-Path `
                -LiteralPath $handleProbeExecutable `
                -PathType Leaf)) {
            Add-Failure 'Expected a Windows command host for the success-handle regression.'
        } else {
            $handleProbeArguments = @('/d', '/c', 'exit', '/b', '0')
            $handleProbeWarmup = Invoke-PrivateMarkerProcess `
                -FileName $handleProbeExecutable `
                -Arguments $handleProbeArguments `
                -WorkingDirectory $tempRoot `
                -TimeoutMilliseconds 5000
            if ($handleProbeWarmup.ExitCode -ne 0 -or
                $handleProbeWarmup.TimedOut -or
                -not $handleProbeWarmup.StreamsCompleted -or
                -not $handleProbeWarmup.TreeStopped) {
                Add-Failure 'Expected the Windows success-handle warmup to complete cleanly.'
            }
            $handleProbeWarmup = $null
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            [GC]::Collect()

            $hostProcess = [System.Diagnostics.Process]::GetCurrentProcess()
            try {
                $hostProcess.Refresh()
                $handleCountBefore = $hostProcess.HandleCount
                $handleProbeIterations = 40
                $allHandleProbesHealthy = $true
                for ($handleProbeIndex = 0;
                    $handleProbeIndex -lt $handleProbeIterations;
                    $handleProbeIndex++) {
                    $handleProbeResult = Invoke-PrivateMarkerProcess `
                        -FileName $handleProbeExecutable `
                        -Arguments $handleProbeArguments `
                        -WorkingDirectory $tempRoot `
                        -TimeoutMilliseconds 5000
                    if ($handleProbeResult.ExitCode -ne 0 -or
                        $handleProbeResult.TimedOut -or
                        $handleProbeResult.OutputLimitExceeded -or
                        $handleProbeResult.InputWriteFailed -or
                        $handleProbeResult.PipeLeakDetected -or
                        -not $handleProbeResult.StreamsCompleted -or
                        -not $handleProbeResult.TreeStopped) {
                        $allHandleProbesHealthy = $false
                    }
                }
                $handleProbeResult = $null
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                [GC]::Collect()
                Start-Sleep -Milliseconds 100
                $hostProcess.Refresh()
                $handleCountAfterGc = $hostProcess.HandleCount
                if (-not $allHandleProbesHealthy -or
                    $handleCountAfterGc -gt ($handleCountBefore + 16)) {
                    Add-Failure (
                        'Expected repeated Windows success-path process calls ' +
                        'to dispose all transferred standard-stream handles.'
                    )
                }
            }
            finally {
                $hostProcess.Dispose()
            }
        }

        # resume後の実target自身からJob所属を問い合わせ、suspended create後の
        # assignが単なるparent-side flagではなくkernel境界として有効なことを測る。
        $jobIdentityScript = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SyntheticJobIdentityProbe
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsProcessInJob(
        IntPtr process,
        IntPtr job,
        out bool result
    );
    public static bool IsInJob()
    {
        bool result;
        return IsProcessInJob(
            GetCurrentProcess(),
            IntPtr.Zero,
            out result
        ) && result;
    }
}
"@
[Console]::Out.Write(
    [SyntheticJobIdentityProbe]::IsInJob().ToString()
)
'@
        $jobIdentityEncoded = [Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes($jobIdentityScript)
        )
        $jobIdentityResult = Invoke-PrivateMarkerProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-EncodedCommand',
                $jobIdentityEncoded
            ) `
            -WorkingDirectory $tempRoot `
            -TimeoutMilliseconds 10000 `
            -MaximumStandardOutputBytes 64 `
            -MaximumStandardErrorBytes 65536
        $jobIdentityText = [System.Text.Encoding]::UTF8.GetString(
            $jobIdentityResult.StandardOutputBytes
        )
        if ($jobIdentityResult.ExitCode -ne 0 -or
            $jobIdentityResult.TimedOut -or
            $jobIdentityResult.OutputLimitExceeded -or
            -not $jobIdentityResult.StreamsCompleted -or
            -not $jobIdentityResult.TreeStopped -or
            $jobIdentityText -cne 'True') {
            Add-Failure 'Expected the resumed Windows target to execute inside an assigned Job.'
        }

        # assign前とresume前のsynthetic failureはtargetを一度も実行せず、
        # cleanup APIの成否確認後にPIDを有限時間でprocess tableから除去する。
        foreach ($launchFailureMode in @('assign', 'resume')) {
            $launchFailureSentinel = Join-Path `
                $tempRoot `
                "windows-launch-failure-$launchFailureMode"
            $escapedLaunchFailureSentinel =
                $launchFailureSentinel.Replace("'", "''")
            $launchFailureScript = @"
[System.IO.File]::WriteAllText(
    '$escapedLaunchFailureSentinel',
    'ran',
    [System.Text.UTF8Encoding]::new(`$false)
)
"@
            $launchFailureEncoded = [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes(
                    $launchFailureScript
                )
            )
            $launchFailureStopwatch =
                [System.Diagnostics.Stopwatch]::StartNew()
            $launchFailureObserved = $false
            try {
                [void](Invoke-PrivateMarkerProcess `
                    -FileName $currentPowerShellExecutable `
                    -Arguments @(
                        '-NoProfile',
                        '-ExecutionPolicy',
                        'Bypass',
                        '-EncodedCommand',
                        $launchFailureEncoded
                    ) `
                    -WorkingDirectory $tempRoot `
                    -TimeoutMilliseconds 10000 `
                    -ForceWindowsLaunchFailure $launchFailureMode)
            }
            catch {
                $launchFailureObserved = $true
            }
            $launchFailureStopwatch.Stop()
            $launchFailureProcessId =
                [PrivateMarker.ContainedProcess]::
                    LastSyntheticFailureProcessId
            $launchFailureProcessGone = $false
            if ($launchFailureProcessId -gt 0) {
                # API戻り値だけでなくkernel process tableからの消失を
                # 最大1秒で再確認し、handle closeだけの誤実装を検出する。
                for ($pidCheckAttempt = 0;
                    $pidCheckAttempt -lt 20;
                    $pidCheckAttempt++) {
                    if ($null -eq (Get-Process `
                        -Id $launchFailureProcessId `
                        -ErrorAction SilentlyContinue)) {
                        $launchFailureProcessGone = $true
                        break
                    }
                    Start-Sleep -Milliseconds 50
                }
            }
            Start-Sleep -Milliseconds 100
            if (-not $launchFailureObserved -or
                $launchFailureProcessId -le 0 -or
                -not $launchFailureProcessGone -or
                $launchFailureStopwatch.ElapsedMilliseconds -ge 6000 -or
                (Test-Path -LiteralPath $launchFailureSentinel)) {
                Add-Failure "Expected $launchFailureMode launch failure to remove its PID without resuming the suspended target."
            }
        }

        # native境界へ期限0を直接渡し、Job割当後・ResumeThread直前の
        # deadline checkがsuspended targetを実行せず回収することを実測する。
        # Invoke側の事前checkを経由しないため、C#側の最終防御そのものを検証できる。
        $windowsPreResumeDeadlineSentinel = Join-Path `
            $tempRoot `
            'windows-pre-resume-deadline-target-ran'
        $escapedPreResumeDeadlineSentinel =
            $windowsPreResumeDeadlineSentinel.Replace("'", "''")
        $preResumeDeadlineScript = @"
[System.IO.File]::WriteAllText(
    '$escapedPreResumeDeadlineSentinel',
    'ran',
    [System.Text.UTF8Encoding]::new(`$false)
)
"@
        $preResumeDeadlineEncoded = [Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes(
                $preResumeDeadlineScript
            )
        )
        $preResumeDeadlineEnvironment =
            [Environment]::GetEnvironmentVariables('Process')
        $preResumeDeadlineStopwatch =
            [System.Diagnostics.Stopwatch]::StartNew()
        $preResumeDeadlineObserved = $false
        try {
            [void][PrivateMarker.ContainedProcess]::Start(
                $currentPowerShellExecutable,
                [string[]]@(
                    '-NoProfile',
                    '-ExecutionPolicy',
                    'Bypass',
                    '-EncodedCommand',
                    $preResumeDeadlineEncoded
                ),
                $preResumeDeadlineEnvironment,
                $tempRoot,
                'deadline',
                '',
                0
            )
        }
        catch {
            $preResumeDeadlineObserved =
                $_.Exception.Message -match
                    'deadline expired before resume'
        }
        $preResumeDeadlineStopwatch.Stop()
        $preResumeDeadlineProcessId =
            [PrivateMarker.ContainedProcess]::LastSyntheticFailureProcessId
        $preResumeDeadlineProcessGone = $false
        if ($preResumeDeadlineProcessId -gt 0) {
            # launch cleanupのAPI成功だけでなく、kernel process tableからの
            # 実消失を最大1秒で確認する。
            for ($pidCheckAttempt = 0;
                $pidCheckAttempt -lt 20;
                $pidCheckAttempt++) {
                if ($null -eq (Get-Process `
                    -Id $preResumeDeadlineProcessId `
                    -ErrorAction SilentlyContinue)) {
                    $preResumeDeadlineProcessGone = $true
                    break
                }
                Start-Sleep -Milliseconds 50
            }
        }
        Start-Sleep -Milliseconds 100
        if (-not $preResumeDeadlineObserved -or
            $preResumeDeadlineProcessId -le 0 -or
            -not $preResumeDeadlineProcessGone -or
            $preResumeDeadlineStopwatch.ElapsedMilliseconds -ge 6000 -or
            (Test-Path -LiteralPath $windowsPreResumeDeadlineSentinel)) {
            Add-Failure 'Expected the native pre-resume deadline to remove its PID without executing the suspended target.'
        }

        # CloseJob失敗時もhandle/disposed stateを保持し、次回Disposeが同じ
        # Job handleをretryできることをinstance APIで直接測る。
        $disposeRetryScript = @'
Start-Sleep -Seconds 5
'@
        $disposeRetryEncoded = [Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes(
                $disposeRetryScript
            )
        )
        $disposeRetryEnvironment =
            [Environment]::GetEnvironmentVariables('Process')
        $disposeRetryProcess =
            [PrivateMarker.ContainedProcess]::Start(
                $currentPowerShellExecutable,
                [string[]]@(
                    '-NoProfile',
                    '-ExecutionPolicy',
                    'Bypass',
                    '-EncodedCommand',
                    $disposeRetryEncoded
                ),
                $disposeRetryEnvironment,
                $tempRoot,
                '',
                'once',
                5000
            )
        $firstDisposeFailed = $false
        $secondDisposeSucceeded = $true
        try {
            $disposeRetryProcess.Dispose()
        }
        catch {
            $firstDisposeFailed = $true
        }
        try {
            $disposeRetryProcess.Dispose()
        }
        catch {
            $secondDisposeSucceeded = $false
        }
        if (-not $firstDisposeFailed -or
            -not $secondDisposeSucceeded -or
            [PrivateMarker.ContainedProcess]::LastSyntheticJobCloseAttempts -ne 2 -or
            -not [PrivateMarker.ContainedProcess]::LastSyntheticJobCloseRetrySucceeded) {
            Add-Failure 'Expected Dispose to retain and retry a Job handle after the first close failure.'
        }

        # 通常のStop経路では最初のJob close失敗後にdirect targetをterminateし、
        # retained handleをfinallyの次回closeで回収する。delayed side effectも拒否する。
        $closeFailurePidPath = Join-Path `
            $tempRoot `
            'windows-close-failure-pid.txt'
        $closeFailureSentinel = Join-Path `
            $tempRoot `
            'windows-close-failure-survived.txt'
        $escapedCloseFailurePidPath =
            $closeFailurePidPath.Replace("'", "''")
        $escapedCloseFailureSentinel =
            $closeFailureSentinel.Replace("'", "''")
        $closeFailureScript = @"
[System.IO.File]::WriteAllText(
    '$escapedCloseFailurePidPath',
    "`$PID",
    [System.Text.UTF8Encoding]::new(`$false)
)
Start-Sleep -Seconds 3
[System.IO.File]::WriteAllText(
    '$escapedCloseFailureSentinel',
    'survived',
    [System.Text.UTF8Encoding]::new(`$false)
)
"@
        $closeFailureEncoded = [Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes(
                $closeFailureScript
            )
        )
        $closeFailureResult = Invoke-PrivateMarkerProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-EncodedCommand',
                $closeFailureEncoded
            ) `
            -WorkingDirectory $tempRoot `
            -TimeoutMilliseconds 750 `
            -ForceWindowsJobCloseFailure once
        $closeFailureProcessGone = $false
        if (Test-Path -LiteralPath $closeFailurePidPath -PathType Leaf) {
            $closeFailureProcessId = 0
            if ([int]::TryParse(
                (Get-Content -LiteralPath $closeFailurePidPath -Raw).Trim(),
                [ref]$closeFailureProcessId
            )) {
                for ($pidCheckAttempt = 0;
                    $pidCheckAttempt -lt 20;
                    $pidCheckAttempt++) {
                    if ($null -eq (Get-Process `
                        -Id $closeFailureProcessId `
                        -ErrorAction SilentlyContinue)) {
                        $closeFailureProcessGone = $true
                        break
                    }
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        Start-Sleep -Milliseconds 2500
        if (-not $closeFailureResult.TimedOut -or
            $closeFailureResult.TreeStopped -or
            -not $closeFailureProcessGone -or
            (Test-Path -LiteralPath $closeFailureSentinel) -or
            [PrivateMarker.ContainedProcess]::LastSyntheticJobCloseAttempts -lt 2 -or
            [PrivateMarker.ContainedProcess]::LastSyntheticDirectTerminateAttempts -lt 1 -or
            -not [PrivateMarker.ContainedProcess]::LastSyntheticJobCloseRetrySucceeded) {
            Add-Failure 'Expected Job close failure to retain the handle, terminate the direct target, and succeed on retry.'
        }

        # Git が存在して timeout した場合は working-tree fallback へ降格しない。
        $syntheticGitDirectory = Join-Path $tempRoot 'synthetic-git'
        $syntheticGitPath = Join-Path $syntheticGitDirectory 'git.exe'
        $slowGitSentinel = Join-Path $tempRoot 'slow-git-survived.txt'
        New-Item -ItemType Directory -Path $syntheticGitDirectory | Out-Null
        $syntheticGitSourcePath = Join-Path $syntheticGitDirectory 'SyntheticGit.cs'
        $syntheticGitCompilerPath = Join-Path $syntheticGitDirectory 'compile-synthetic-git.ps1'
        $syntheticGitSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class SyntheticGitProgram
{
    private static string QuoteArgument(string argument)
    {
        if (String.IsNullOrEmpty(argument))
        {
            return "\"\"";
        }
        if (argument.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return argument;
        }

        var output = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var character in argument)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                output.Append('\\', (backslashes * 2) + 1);
                output.Append('"');
                backslashes = 0;
                continue;
            }
            output.Append('\\', backslashes);
            backslashes = 0;
            output.Append(character);
        }
        output.Append('\\', backslashes * 2);
        output.Append('"');
        return output.ToString();
    }

    private static int Run(string fileName, string[] arguments, int timeoutMilliseconds)
    {
        var forwardsInput = Array.IndexOf(arguments, "cat-file") >= 0 &&
            Array.IndexOf(arguments, "--batch") >= 0;
        var startInfo = new ProcessStartInfo {
            FileName = fileName,
            Arguments = String.Join(" ", Array.ConvertAll(arguments, QuoteArgument)),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = forwardsInput,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var process = Process.Start(startInfo))
        {
            var stdoutTask = process.StandardOutput.BaseStream.CopyToAsync(
                Console.OpenStandardOutput());
            var stderrTask = process.StandardError.BaseStream.CopyToAsync(
                Console.OpenStandardError());
            if (forwardsInput)
            {
                var inputTask = Console.OpenStandardInput().CopyToAsync(
                    process.StandardInput.BaseStream);
                if (!inputTask.Wait(5000))
                {
                    process.Kill();
                    process.WaitForExit(5000);
                    return 123;
                }
                process.StandardInput.Close();
            }
            if (!process.WaitForExit(timeoutMilliseconds))
            {
                process.Kill();
                process.WaitForExit(5000);
                return 124;
            }
            if (!Task.WaitAll(new[] { stdoutTask, stderrTask }, 5000))
            {
                return 125;
            }
            Console.Out.Flush();
            Console.Error.Flush();
            return process.ExitCode;
        }
    }

    private static bool IsStageListing(string[] arguments)
    {
        return Array.IndexOf(arguments, "ls-files") >= 0 &&
            Array.IndexOf(arguments, "--stage") >= 0 &&
            Array.IndexOf(arguments, "-z") >= 0 &&
            Array.IndexOf(arguments, "--debug") < 0;
    }

    private static bool IsDebugStageListing(string[] arguments)
    {
        return Array.IndexOf(arguments, "ls-files") >= 0 &&
            Array.IndexOf(arguments, "--stage") >= 0 &&
            Array.IndexOf(arguments, "-z") >= 0 &&
            Array.IndexOf(arguments, "--debug") >= 0;
    }

    private static int NextStageListingCount(string counterPath)
    {
        using (var stream = new FileStream(
            counterPath,
            FileMode.OpenOrCreate,
            FileAccess.ReadWrite,
            FileShare.None))
        {
            if (stream.Length > 32)
            {
                throw new InvalidDataException("Synthetic Git counter is invalid.");
            }
            var bytes = new byte[(int)stream.Length];
            var offset = 0;
            while (offset < bytes.Length)
            {
                var read = stream.Read(bytes, offset, bytes.Length - offset);
                if (read == 0)
                {
                    throw new EndOfStreamException();
                }
                offset += read;
            }

            var count = 0;
            if (bytes.Length > 0 &&
                !Int32.TryParse(Encoding.ASCII.GetString(bytes), out count))
            {
                throw new InvalidDataException("Synthetic Git counter is invalid.");
            }
            count++;
            var nextBytes = Encoding.ASCII.GetBytes(count.ToString());
            stream.Position = 0;
            stream.SetLength(0);
            stream.Write(nextBytes, 0, nextBytes.Length);
            stream.Flush(true);
            return count;
        }
    }

    public static int Main(string[] args)
    {
        if (String.Equals(
            Environment.GetEnvironmentVariable("PRIVATE_MARKER_SYNTHETIC_GIT_MODE"),
            "index-mutation",
            StringComparison.Ordinal))
        {
            var realGit = Environment.GetEnvironmentVariable("PRIVATE_MARKER_REAL_GIT");
            var counterPath = Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_COUNTER");
            if (IsStageListing(args) && NextStageListingCount(counterPath) == 2)
            {
                var mutationExit = Run(
                    realGit,
                    new[] {
                        "-C",
                        Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_REPO"),
                        "add",
                        "--",
                        Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_REPLACEMENT"),
                        Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_ADDITION")
                    },
                    5000);
                if (mutationExit != 0)
                {
                    return 90;
                }
                File.WriteAllText(
                    Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_MUTATION_SENTINEL"),
                    "mutated",
                    new UTF8Encoding(false));
            }
            return Run(realGit, args, 20000);
        }

        if (String.Equals(
            Environment.GetEnvironmentVariable("PRIVATE_MARKER_SYNTHETIC_GIT_MODE"),
            "flags-mutation",
            StringComparison.Ordinal))
        {
            var realGit = Environment.GetEnvironmentVariable("PRIVATE_MARKER_REAL_GIT");
            var counterPath = Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_COUNTER");
            if (IsDebugStageListing(args) && NextStageListingCount(counterPath) == 2)
            {
                var repository =
                    Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_REPO");
                var relativePath =
                    Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_REPLACEMENT");
                var removeExit = Run(
                    realGit,
                    new[] {
                        "-C",
                        repository,
                        "update-index",
                        "--force-remove",
                        "--",
                        relativePath
                    },
                    5000);
                var intentExit = removeExit == 0
                    ? Run(
                        realGit,
                        new[] {
                            "-C",
                            repository,
                            "add",
                            "-N",
                            "--",
                            relativePath
                        },
                        5000)
                    : removeExit;
                if (removeExit != 0 || intentExit != 0)
                {
                    return 91;
                }
                File.WriteAllText(
                    Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_MUTATION_SENTINEL"),
                    "flags-mutated",
                    new UTF8Encoding(false));
            }
            return Run(realGit, args, 20000);
        }

        Thread.Sleep(5000);
        File.WriteAllText(
            Environment.GetEnvironmentVariable("PRIVATE_MARKER_SLOW_GIT_SENTINEL"),
            "survived");
        return 0;
    }
}
'@
        $immediateSpawnerPath = Join-Path $syntheticGitDirectory 'ImmediateSpawner.exe'
        $immediateSpawnerSourcePath = Join-Path $syntheticGitDirectory 'ImmediateSpawner.cs'
        $immediateSpawnerSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

public static class ImmediateSpawnerProgram
{
    public static int Main(string[] args)
    {
        if (args.Length == 1 &&
            String.Equals(args[0], "--child", StringComparison.Ordinal))
        {
            File.WriteAllText(
                Environment.GetEnvironmentVariable("PRIVATE_MARKER_PIPE_STARTED_SENTINEL"),
                "started",
                new UTF8Encoding(false));
            Thread.Sleep(1000);
            File.WriteAllText(
                Environment.GetEnvironmentVariable("PRIVATE_MARKER_PIPE_SURVIVED_SENTINEL"),
                "survived",
                new UTF8Encoding(false));
            return 0;
        }

        // root process は意図的な猶予を置かず、最初の処理で pipe 継承 child を起動する。
        var startInfo = new ProcessStartInfo {
            FileName = Assembly.GetExecutingAssembly().Location,
            Arguments = "--child",
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using (var child = Process.Start(startInfo))
        {
            if (child == null)
            {
                return 20;
            }
        }
        Console.Out.WriteLine("parent-exit");
        return 0;
    }
}
'@
        $syntheticGitCompiler = @'
param(
    [string]$SourcePath,
    [string]$OutputPath
)
Add-Type `
    -Path $SourcePath `
    -OutputAssembly $OutputPath `
    -OutputType ConsoleApplication
'@
        [System.IO.File]::WriteAllText(
            $syntheticGitSourcePath,
            $syntheticGitSource,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            $immediateSpawnerSourcePath,
            $immediateSpawnerSource,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            $syntheticGitCompilerPath,
            $syntheticGitCompiler,
            [System.Text.UTF8Encoding]::new($true)
        )
        $windowsPowerShell = Get-Command powershell -ErrorAction Stop
        $compileResult = Invoke-PrivateMarkerProcess `
            -FileName $windowsPowerShell.Source `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $syntheticGitCompilerPath,
                '-SourcePath',
                $syntheticGitSourcePath,
                '-OutputPath',
                $syntheticGitPath
            ) `
            -WorkingDirectory $syntheticGitDirectory `
            -TimeoutMilliseconds 30000
        if ($compileResult.ExitCode -ne 0 -or
            -not $compileResult.StreamsCompleted -or
            -not $compileResult.TreeStopped -or
            -not (Test-Path -LiteralPath $syntheticGitPath -PathType Leaf)) {
            Add-Failure 'Expected bounded synthetic Git compilation to succeed.'
        }
        $spawnerCompileResult = Invoke-PrivateMarkerProcess `
            -FileName $windowsPowerShell.Source `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $syntheticGitCompilerPath,
                '-SourcePath',
                $immediateSpawnerSourcePath,
                '-OutputPath',
                $immediateSpawnerPath
            ) `
            -WorkingDirectory $syntheticGitDirectory `
            -TimeoutMilliseconds 30000
        if ($spawnerCompileResult.ExitCode -ne 0 -or
            -not $spawnerCompileResult.StreamsCompleted -or
            -not $spawnerCompileResult.TreeStopped -or
            -not (Test-Path -LiteralPath $immediateSpawnerPath -PathType Leaf)) {
            Add-Failure 'Expected bounded immediate-spawner compilation to succeed.'
        } else {
            # 目的 process が最初の処理で child を起動しても、direct target は
            # suspended 中にJob所属済みなのでkill-on-close境界から逃げられない。
            $pipeSurvivedSentinels = New-Object System.Collections.Generic.List[string]
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                $pipeStartedSentinel = Join-Path `
                    $tempRoot `
                    "pipe-grandchild-started-$attempt.txt"
                $pipeSurvivedSentinel = Join-Path `
                    $tempRoot `
                    "pipe-grandchild-survived-$attempt.txt"
                $pipeSurvivedSentinels.Add($pipeSurvivedSentinel) | Out-Null
                $pipeResult = Invoke-PrivateMarkerProcess `
                    -FileName $immediateSpawnerPath `
                    -WorkingDirectory $tempRoot `
                    -EnvironmentOverrides @{
                        PRIVATE_MARKER_PIPE_STARTED_SENTINEL = $pipeStartedSentinel
                        PRIVATE_MARKER_PIPE_SURVIVED_SENTINEL = $pipeSurvivedSentinel
                    } `
                    -TimeoutMilliseconds 10000 `
                    -StreamCompletionWaitMilliseconds 500 `
                    -StreamCleanupWaitMilliseconds 1000
                if (-not $pipeResult.PipeLeakDetected -or
                    $pipeResult.StreamsCompleted -or
                    -not $pipeResult.TreeStopped) {
                    Add-Failure "Expected immediate-spawner attempt $attempt to detect and stop a child-held pipe."
                }
                if (-not (Test-Path -LiteralPath $pipeStartedSentinel)) {
                    Add-Failure "Expected immediate-spawner attempt $attempt to prove that its child started."
                }
            }

            # 全 attempt の child が artifact を書く期限を一度だけ bounded に待つ。
            Start-Sleep -Milliseconds 1250
            foreach ($pipeSurvivedSentinel in $pipeSurvivedSentinels) {
                if (Test-Path -LiteralPath $pipeSurvivedSentinel) {
                    Add-Failure 'Expected atomic Job assignment to stop every immediate child before artifact creation.'
                    break
                }
            }
        }

        $timeoutRoot = Join-Path $tempRoot 'timeout-root'
        New-Item -ItemType Directory -Path $timeoutRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $timeoutRoot 'README.md') -Value 'synthetic clean timeout fixture' -Encoding UTF8
        $timeoutResult = Invoke-Scanner `
            -ScanPath $timeoutRoot `
            -EnvironmentOverrides @{
                PATH = $syntheticGitDirectory
                PRIVATE_MARKER_SLOW_GIT_SENTINEL = $slowGitSentinel
            } `
            -AdditionalArguments @('-GitCommandTimeoutMilliseconds', '750')
        Assert-FixedProcessBoundaryFailure `
            -Result $timeoutResult `
            -Context 'Timed-out Git probe' `
            -ForbiddenPaths @(
                $root,
                $tempRoot,
                $timeoutRoot,
                $scanner,
                $processBoundary,
                $syntheticGitDirectory,
                $syntheticGitPath,
                $slowGitSentinel
            )
        if (Test-Path -LiteralPath $slowGitSentinel) {
            Add-Failure 'Expected the timed-out synthetic Git process tree to be stopped before artifact creation.'
        }
    }

    # success 側の規約例を 1 fixture へ集約し、各例を個別 process で再走査しない。
    $cleanRoot = Join-Path $tempRoot 'clean accepted examples'
    New-Item -ItemType Directory -Path $cleanRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanRoot 'README.md') -Value @(
        '# Clean synthetic fixture'
        'A completion notice is a claim, not evidence. Verify artifacts first.'
        'Use a placeholder path such as C:\path\to\repo in examples.'
        'You can also write C:\Users\<name>\project to describe a user directory.'
        ('Own repo: ' + (('https://github' + '.com/') + 'h8nc4y/claude-code-devlog-hooks'))
        ('Own clone URL: ' + (('https://github' + '.com/') + 'h8nc4y/claude-code-devlog-hooks.git'))
    ) -Encoding UTF8

    $cleanResult = Invoke-Scanner -ScanPath $cleanRoot
    if ($cleanResult.ExitCode -ne 0) {
        Add-Failure "Expected clean fixture to pass, but scanner exited $($cleanResult.ExitCode): $($cleanResult.Output.Trim())"
    }
    $noGitFallbackResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($noGitFallbackResult.ExitCode -ne 0 -or
        $noGitFallbackResult.Output -notmatch 'working-tree') {
        Add-Failure "Expected a true non-Git directory to retain fallback when Git is unavailable. Output: $($noGitFallbackResult.Output.Trim())"
    }

    # ValidateRange/ValidateSetをpublic binderへ任せず、range外・nonnumeric・
    # overflow・未知probeをすべて固定redacted stderr + exit 2へ畳む。
    $invalidPublicParameterCases = @(
        [pscustomobject]@{
            Name = 'Git timeout below minimum'
            Arguments = @('-GitCommandTimeoutMilliseconds', '249')
        },
        [pscustomobject]@{
            Name = 'Git timeout above maximum'
            Arguments = @('-GitCommandTimeoutMilliseconds', '15001')
        },
        [pscustomobject]@{
            Name = 'Git timeout nonnumeric'
            Arguments = @('-GitCommandTimeoutMilliseconds', 'not-an-integer')
        },
        [pscustomobject]@{
            Name = 'Git timeout overflow'
            Arguments = @(
                '-GitCommandTimeoutMilliseconds',
                '999999999999999999999999'
            )
        },
        [pscustomobject]@{
            Name = 'Scan deadline below minimum'
            Arguments = @('-ScanDeadlineMilliseconds', '0')
        },
        [pscustomobject]@{
            Name = 'Scan deadline above maximum'
            Arguments = @('-ScanDeadlineMilliseconds', '120001')
        },
        [pscustomobject]@{
            Name = 'Scan deadline nonnumeric'
            Arguments = @('-ScanDeadlineMilliseconds', 'not-an-integer')
        },
        [pscustomobject]@{
            Name = 'Unknown process-boundary probe'
            Arguments = @('-ProcessBoundaryFailureProbe', 'unknown-probe')
        }
    )
    foreach ($parameterCase in $invalidPublicParameterCases) {
        $invalidParameterResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -AdditionalArguments $parameterCase.Arguments
        Assert-FixedProcessBoundaryFailure `
            -Result $invalidParameterResult `
            -Context $parameterCase.Name `
            -ForbiddenPaths @(
                $root,
                $tempRoot,
                $cleanRoot,
                $scanner,
                $processBoundary
            )
    }

    # scan-wide 期限は実運用の120秒を延長できず、self-testだけがlower-only値で
    # 最終報告まで同じ時計に含まれる fail-closed 経路を短時間で再現する。
    $scanDeadlineResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath } `
        -AdditionalArguments @('-ScanDeadlineMilliseconds', '1')
    if ($scanDeadlineResult.ExitCode -eq 0 -or
        $scanDeadlineResult.TimedOut -or
        $scanDeadlineResult.Output -notmatch
            'Private marker scan exceeded its scan-wide time budget\.' -or
        $scanDeadlineResult.Output -match 'Private marker scan passed') {
        Add-Failure "Expected the lower-only scan-wide deadline to fail before final success output. Output: $($scanDeadlineResult.Output.Trim())"
    }

    # non-Git fallback は nested `.git` directory だけでなく leaf gitfile も読まない。
    $nestedGitLeafRoot = Join-Path $cleanRoot 'nested-git-leaf'
    New-Item -ItemType Directory -Path $nestedGitLeafRoot | Out-Null
    $nestedGitLeafPath = Join-Path $nestedGitLeafRoot '.git'
    $nestedGitLeafMarker = ('g' + 'hp_') + 'synthetic_gitfile_marker'
    Set-Content `
        -LiteralPath $nestedGitLeafPath `
        -Value $nestedGitLeafMarker `
        -Encoding UTF8
    $nestedGitLeafResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($nestedGitLeafResult.ExitCode -ne 0 -or
        $nestedGitLeafResult.Output -notmatch 'working-tree' -or
        $nestedGitLeafResult.Output.Contains($nestedGitLeafMarker)) {
        Add-Failure "Expected a nested .git leaf to remain excluded from fallback scanning. Output: $($nestedGitLeafResult.Output.Trim())"
    }
    [System.IO.File]::Delete($nestedGitLeafPath)
    [System.IO.Directory]::Delete($nestedGitLeafRoot)

    if (-not (Test-PrivateMarkerWindowsHost)) {
        # POSIXではlowercase `.git` だけがspecial。通常の大文字 `.GIT`
        # directory/leafをPowerShell既定の大小無視比較で誤除外しない。
        $upperGitDirectory = Join-Path $cleanRoot '.GIT'
        $upperGitMarker = ('g' + 'hp_') + 'synthetic_upper_git_marker'
        New-Item -ItemType Directory -Path $upperGitDirectory | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $upperGitDirectory 'visible.md') `
            -Value "synthetic marker: $upperGitMarker" `
            -Encoding UTF8
        $upperGitDirectoryResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -EnvironmentOverrides @{ PATH = $emptyCommandPath }
        if ($upperGitDirectoryResult.ExitCode -eq 0 -or
            -not $upperGitDirectoryResult.Output.Contains(
                '.GIT/visible.md'
            ) -or
            $upperGitDirectoryResult.Output.Contains($upperGitMarker)) {
            Add-Failure 'Expected POSIX fallback to scan an ordinary uppercase .GIT directory.'
        }
        Remove-Item -LiteralPath $upperGitDirectory -Recurse -Force

        $upperGitLeafPath = Join-Path $cleanRoot '.GIT'
        Set-Content `
            -LiteralPath $upperGitLeafPath `
            -Value "synthetic marker: $upperGitMarker" `
            -Encoding UTF8
        $upperGitLeafResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -EnvironmentOverrides @{ PATH = $emptyCommandPath }
        if ($upperGitLeafResult.ExitCode -eq 0 -or
            -not $upperGitLeafResult.Output.Contains('.GIT') -or
            $upperGitLeafResult.Output.Contains($upperGitMarker)) {
            Add-Failure 'Expected POSIX fallback to scan an ordinary uppercase .GIT leaf.'
        }
        [System.IO.File]::Delete($upperGitLeafPath)
    }

    # OS は ambient 変数ではなく runtime API で判定する。unset/empty/forgedでも挙動を固定する。
    foreach ($osCase in @(
        @{ Label = 'unset'; Value = $null },
        @{ Label = 'present-empty'; Value = '' },
        @{ Label = 'forged-posix'; Value = 'forged-posix' },
        @{ Label = 'forged-windows'; Value = 'Windows_NT' }
    )) {
        $osEnvironment = @{
            PATH = $emptyCommandPath
            OS = $osCase.Value
        }
        $osResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -EnvironmentOverrides $osEnvironment
        if ($osResult.ExitCode -ne 0 -or
            $osResult.Output -notmatch 'working-tree') {
            Add-Failure "Expected ambient OS case '$($osCase.Label)' not to change runtime detection. Output: $($osResult.Output.Trim())"
        }
    }

    # content byte数が0でも entry数で必ず停止し、空file群を無制限に保持しない。
    $zeroByteRoot = Join-Path $tempRoot 'zero-byte-entry-limit'
    New-Item -ItemType Directory -Path $zeroByteRoot | Out-Null
    for ($zeroIndex = 0; $zeroIndex -le 10000; $zeroIndex++) {
        $zeroPath = Join-Path $zeroByteRoot (
            'zero-{0:D5}' -f $zeroIndex
        )
        $zeroStream = [System.IO.File]::Create($zeroPath)
        $zeroStream.Dispose()
    }
    $zeroByteResult = Invoke-Scanner `
        -ScanPath $zeroByteRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($zeroByteResult.ExitCode -eq 0 -or
        $zeroByteResult.Output -notmatch 'entry limit' -or
        $zeroByteResult.Output.Length -gt 16384) {
        Add-Failure "Expected zero-byte file amplification to hit the bounded entry limit. Output: $($zeroByteResult.Output.Trim())"
    }

    # Higher-recall cloud / PEM prefixes, with one redaction regression each.
    # finding 側も 1 directory へ集約するが、rule と固有 file 名を全件確認して
    # どれか 1 件だけの成功を matrix 全体の成功と誤認しない。
    $findingRoot = Join-Path $tempRoot 'combined findings'
    New-Item -ItemType Directory -Path $findingRoot | Out-Null
    $syntheticMarker = ('g' + 'hp_') + 'synthetic_placeholder_only'

    # finding件数の上限内でもserialized payloadが64KiBを超える場合、
    # partial tableを出さず固定codeだけへ縮退する。
    $findingOutputCapRoot = Join-Path $tempRoot 'finding-output-cap'
    New-Item -ItemType Directory -Path $findingOutputCapRoot | Out-Null
    for ($fileIndex = 0; $fileIndex -lt 8; $fileIndex++) {
        $longFileName = (
            'finding-output-{0}-' -f $fileIndex
        ) + ('x' * 96) + '.txt'
        Set-Content `
            -LiteralPath (Join-Path $findingOutputCapRoot $longFileName) `
            -Value @(
                for ($lineIndex = 0; $lineIndex -lt 64; $lineIndex++) {
                    $syntheticMarker
                }
            ) `
            -Encoding UTF8
    }
    $findingOutputCapResult = Invoke-Scanner `
        -ScanPath $findingOutputCapRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($findingOutputCapResult.ExitCode -eq 0 -or
        $findingOutputCapResult.Output -notmatch
            'scan-diagnostic-output-limit' -or
        $findingOutputCapResult.Output -match '<redacted>' -or
        $findingOutputCapResult.Output.Length -gt 16384) {
        Add-Failure 'Expected over-limit finding output to collapse to one bounded diagnostic without a partial table.'
    }

    $adjacentContent = 'synthetic marker after UTF-8: ' + [char]0x30C8 + $syntheticMarker
    [System.IO.File]::WriteAllText(
        (Join-Path $findingRoot 'utf8-adjacent.md'),
        $adjacentContent,
        [System.Text.UTF8Encoding]::new($false)
    )
    $prefixCases = @(
        @{ Rule = 'openai-api-key-prefix';            Marker = ('s' + 'k-') + 'SyntheticOpenAI000000000000' }
        @{ Rule = 'aws-access-key-id';                Marker = ('A' + 'KIA') + 'EXAMPLE0000000000000' }
        @{ Rule = 'gcp-api-key-prefix';               Marker = ('AIza') + 'Synthetic0000000000000000000000000000' }
        @{ Rule = 'slack-user-token-prefix';          Marker = ('xo' + 'xp-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-legacy-app-token-prefix';    Marker = ('xo' + 'xa-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-app-level-token-prefix';     Marker = ('xa' + 'pp-') + 'synthetic-placeholder' }
        @{ Rule = 'stripe-live-secret-key';           Marker = ('s' + 'k') + '_live_SyntheticPlaceholder0000' }
        @{ Rule = 'pem-private-key-block';            Marker = '-----' + ('BEGIN ' + 'OPENSSH PRIVATE KEY') + '-----' }
    )

    foreach ($case in $prefixCases) {
        Set-Content `
            -LiteralPath (Join-Path $findingRoot ("$($case.Rule).txt")) `
            -Value "synthetic marker: $($case.Marker)" `
            -Encoding UTF8
    }

    # windows-absolute-path: private-looking paths should be findings.
    # Split the literal so this test file does not make the scanner flag itself.
    $realWinPath = 'C' + ':\Users\realperson\Secrets\config'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot 'windows-path.md') `
        -Value "See $realWinPath for details." `
        -Encoding UTF8

    # non-allowlisted GitHub URL も同一 finding scan で検査する。
    # URLs are split so this test file does not make the scanner flag itself.
    $foreignUrl = ('https://github' + '.com/') + 'someone-else/private-repo'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot 'github-url.md') `
        -Value "See $foreignUrl for details." `
        -Encoding UTF8

    # Cf/bidi と Unicode line/paragraph separator は terminal 上で必ず escape する。
    $diagnosticControlCharacters = @(
        [char]0x202E,
        [char]0x2028,
        [char]0x2029
    )
    $diagnosticControlName =
        'diagnostic-' +
        ($diagnosticControlCharacters -join '-') +
        '-spoof.md'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot $diagnosticControlName) `
        -Value "synthetic marker: $syntheticMarker" `
        -Encoding UTF8

    $findingResult = Invoke-Scanner -ScanPath $findingRoot
    if ($findingResult.ExitCode -eq 0) {
        Add-Failure 'Expected the combined synthetic finding fixture to fail.'
    }
    $expectedRules = @(
        'github-classic-token-prefix'
        $prefixCases.Rule
        'windows-absolute-path'
        'non-allowlisted-github-repo-url'
    )
    foreach ($rule in $expectedRules) {
        if ($findingResult.Output -notmatch [regex]::Escape($rule)) {
            Add-Failure "Expected combined finding output to name $rule. Output: $($findingResult.Output.Trim())"
        }
    }
    if ($findingResult.Output -notmatch 'utf8-adjacent\.md') {
        Add-Failure 'Expected the BOM-less UTF-8 adjacent marker file to appear in findings.'
    }
    foreach ($rawValue in @(
        $syntheticMarker
        $prefixCases.Marker
        $realWinPath
        $foreignUrl
    )) {
        if ($findingResult.Output.Contains($rawValue)) {
            Add-Failure 'Expected every combined finding value to stay redacted.'
        }
    }
    if ($findingResult.Output -notmatch '<redacted>') {
        Add-Failure "Expected combined findings to report '<redacted>'. Output: $($findingResult.Output.Trim())"
    }
    foreach ($diagnosticCharacter in $diagnosticControlCharacters) {
        if ($findingResult.Output.Contains([string]$diagnosticCharacter)) {
            Add-Failure 'Expected diagnostic control characters not to appear raw in scanner output.'
        }
    }
    foreach ($escapedDiagnostic in @('\u202E', '\u2028', '\u2029')) {
        if (-not $findingResult.Output.Contains($escapedDiagnostic)) {
            Add-Failure "Expected scanner output to contain escaped diagnostic text $escapedDiagnostic."
        }
    }

    # 同一行のURL列挙は finding を1件へ畳み、出力サイズを URL 数で増幅させない。
    $urlAmplificationRoot = Join-Path $tempRoot 'url-amplification'
    New-Item -ItemType Directory -Path $urlAmplificationRoot | Out-Null
    $foreignUrls = (
        1..200 |
            ForEach-Object { "${foreignUrl}?fixture=$_" }
    ) -join ' '
    Set-Content `
        -LiteralPath (Join-Path $urlAmplificationRoot 'many-urls.md') `
        -Value $foreignUrls `
        -Encoding UTF8
    $urlAmplificationResult = Invoke-Scanner -ScanPath $urlAmplificationRoot
    $urlRuleCount = [regex]::Matches(
        $urlAmplificationResult.Output,
        'non-allowlisted-github-repo-url'
    ).Count
    if ($urlAmplificationResult.ExitCode -eq 0 -or
        $urlRuleCount -ne 1 -or
        $urlAmplificationResult.Output.Length -gt 16384) {
        Add-Failure "Expected same-line URL findings to stay deduplicated and bounded. Output length: $($urlAmplificationResult.Output.Length)"
    }

    # allowlisted URL だけでも NextMatch 回数を固定し、巨大な match 列挙を fail-closed にする。
    $allowedUrl = ('https://github' + '.com/') +
        'h8nc4y/claude-code-devlog-hooks'
    $allowedUrlAmplificationRoot =
        Join-Path $tempRoot 'allowed-url-amplification'
    New-Item -ItemType Directory -Path $allowedUrlAmplificationRoot | Out-Null
    Set-Content `
        -LiteralPath (
            Join-Path $allowedUrlAmplificationRoot 'many-allowed-urls.md'
        ) `
        -Value ((1..300 | ForEach-Object { $allowedUrl }) -join ' ') `
        -Encoding UTF8
    $allowedUrlAmplificationResult =
        Invoke-Scanner -ScanPath $allowedUrlAmplificationRoot
    if ($allowedUrlAmplificationResult.ExitCode -eq 0 -or
        $allowedUrlAmplificationResult.Output -notmatch
            'per-line URL match limit' -or
        $allowedUrlAmplificationResult.Output.Length -gt 16384) {
        Add-Failure "Expected allowed-URL amplification to fail inside a bounded diagnostic. Output: $($allowedUrlAmplificationResult.Output.Trim())"
    }

    # 1行全体を split 配列へ複製せず、bounded substring の前に行長で拒否する。
    $overlongLineRoot = Join-Path $tempRoot 'overlong-line-limit'
    New-Item -ItemType Directory -Path $overlongLineRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $overlongLineRoot 'overlong.txt'),
        [string]::new([char]'a', (1MB + 1)),
        [System.Text.UTF8Encoding]::new($false)
    )
    $overlongLineResult = Invoke-Scanner -ScanPath $overlongLineRoot
    if ($overlongLineResult.ExitCode -eq 0 -or
        $overlongLineResult.Output -notmatch 'overlong line' -or
        $overlongLineResult.Output.Length -gt 16384) {
        Add-Failure "Expected an overlong line to fail before unbounded line scanning. Output: $($overlongLineResult.Output.Trim())"
    }

    # 上限近傍でもregex開始候補を持たない安全な単一行はtimeout扱いにしない。
    # adversarial negativeだけでなく、false-positive側の対照も同じdeadlineで固定する。
    $regexSafeNearLimitRoot = Join-Path $tempRoot 'regex-safe-near-limit'
    New-Item -ItemType Directory -Path $regexSafeNearLimitRoot | Out-Null
    $regexSafeNearLimitPath =
        Join-Path $regexSafeNearLimitRoot 'safe-near-limit.txt'
    [System.IO.File]::WriteAllText(
        $regexSafeNearLimitPath,
        [string]::new([char]' ', 900000),
        [System.Text.UTF8Encoding]::new($false)
    )
    $regexSafeNearLimitClock = [System.Diagnostics.Stopwatch]::StartNew()
    $regexSafeNearLimitResult = Invoke-Scanner `
        -ScanPath $regexSafeNearLimitRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath } `
        -AdditionalArguments @('-ScanDeadlineMilliseconds', '5000')
    $regexSafeNearLimitClock.Stop()
    if ($regexSafeNearLimitResult.ExitCode -ne 0 -or
        $regexSafeNearLimitResult.TimedOut -or
        -not $regexSafeNearLimitResult.StreamsCompleted -or
        -not $regexSafeNearLimitResult.TreeStopped -or
        $regexSafeNearLimitResult.Output -notmatch
            'Private marker scan passed' -or
        $regexSafeNearLimitClock.ElapsedMilliseconds -gt 10000) {
        Add-Failure (
            'Expected a safe near-limit line to pass inside the scanner ' +
            "deadline. Elapsed: " +
            "$($regexSafeNearLimitClock.ElapsedMilliseconds) ms."
        )
    }

    # 1MiB line上限を下回るno-matchでも、email regexは開始位置ごとの再走査で
    # scan-wide deadlineを占有できる。regex自身の有限timeoutと固定診断を実測する。
    $regexTimeoutRoot = Join-Path $tempRoot 'regex-match-timeout'
    New-Item -ItemType Directory -Path $regexTimeoutRoot | Out-Null
    $regexTimeoutPath = Join-Path $regexTimeoutRoot 'adversarial.txt'
    [System.IO.File]::WriteAllText(
        $regexTimeoutPath,
        ('a.' * 500000),
        [System.Text.UTF8Encoding]::new($false)
    )
    $regexTimeoutClock = [System.Diagnostics.Stopwatch]::StartNew()
    $regexTimeoutResult = Invoke-Scanner `
        -ScanPath $regexTimeoutRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath } `
        -AdditionalArguments @('-ScanDeadlineMilliseconds', '5000')
    $regexTimeoutClock.Stop()
    Assert-FixedProcessBoundaryFailure `
        -Result $regexTimeoutResult `
        -Context 'Regex match timeout' `
        -Integrity 'regex-timeout' `
        -ForbiddenPaths @(
            $root,
            $tempRoot,
            $regexTimeoutRoot,
            $regexTimeoutPath,
            $scanner,
            $processBoundary
        )
    if ($regexTimeoutResult.TimedOut -or
        -not $regexTimeoutResult.StreamsCompleted -or
        -not $regexTimeoutResult.TreeStopped -or
        $regexTimeoutClock.ElapsedMilliseconds -gt 10000) {
        Add-Failure (
            'Expected adversarial regex no-match to fail inside the scanner ' +
            "deadline. Elapsed: $($regexTimeoutClock.ElapsedMilliseconds) ms."
        )
    }

    # finding は file 単位と scan 全体の双方で上限を持つ。
    $perFileFindingRoot = Join-Path $tempRoot 'per-file-finding-limit'
    New-Item -ItemType Directory -Path $perFileFindingRoot | Out-Null
    $perFileMarkerLines = (
        1..65 |
            ForEach-Object { "synthetic line $_ $syntheticMarker" }
    )
    Set-Content `
        -LiteralPath (Join-Path $perFileFindingRoot 'many-findings.md') `
        -Value $perFileMarkerLines `
        -Encoding UTF8
    $perFileFindingResult = Invoke-Scanner -ScanPath $perFileFindingRoot
    if ($perFileFindingResult.ExitCode -eq 0 -or
        $perFileFindingResult.Output -notmatch 'per-file finding limit' -or
        $perFileFindingResult.Output.Length -gt 16384 -or
        $perFileFindingResult.Output.Contains($syntheticMarker)) {
        Add-Failure "Expected per-file finding amplification to fail closed without exposing values. Output: $($perFileFindingResult.Output.Trim())"
    }

    $totalFindingRoot = Join-Path $tempRoot 'total-finding-limit'
    New-Item -ItemType Directory -Path $totalFindingRoot | Out-Null
    foreach ($fileIndex in 1..9) {
        $totalMarkerLines = (
            1..60 |
                ForEach-Object {
                    "synthetic file $fileIndex line $_ $syntheticMarker"
                }
        )
        Set-Content `
            -LiteralPath (
                Join-Path $totalFindingRoot ("findings-{0:D2}.md" -f $fileIndex)
            ) `
            -Value $totalMarkerLines `
            -Encoding UTF8
    }
    $totalFindingResult = Invoke-Scanner -ScanPath $totalFindingRoot
    if ($totalFindingResult.ExitCode -eq 0 -or
        $totalFindingResult.Output -notmatch 'total finding limit' -or
        $totalFindingResult.Output.Length -gt 16384 -or
        $totalFindingResult.Output.Contains($syntheticMarker)) {
        Add-Failure "Expected total finding amplification to fail closed without exposing values. Output: $($totalFindingResult.Output.Trim())"
    }

    $localMarkerRoot = Join-Path $tempRoot 'local-marker'
    New-Item -ItemType Directory -Path $localMarkerRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $localMarkerRoot '.private-markers.local') -Value 'local-only-marker' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $localMarkerRoot 'leak.txt') -Value 'synthetic local-only-marker fixture' -Encoding UTF8

    $localMarkerResult = Invoke-Scanner -ScanPath $localMarkerRoot
    if ($localMarkerResult.ExitCode -eq 0) {
        Add-Failure 'Expected local marker fixture to fail, but scanner exited 0.'
    }
    if ($localMarkerResult.Output -notmatch 'local-private-marker-1') {
        Add-Failure "Expected local marker output to name local-private-marker-1. Output: $($localMarkerResult.Output.Trim())"
    }

    if (Test-PrivateMarkerWindowsHost) {
        # Explicit scan root 自体が junction の場合も、外部 target を列挙する前に拒否する。
        $rootJunctionPath = Join-Path $tempRoot 'root junction'
        $rootJunctionTarget = Join-Path $tempRoot 'root junction external target'
        New-Item -ItemType Directory -Path $rootJunctionTarget | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $rootJunctionTarget 'clean.md') `
            -Value 'synthetic clean root-junction content' `
            -Encoding UTF8
        try {
            New-Item `
                -ItemType Junction `
                -Path $rootJunctionPath `
                -Target $rootJunctionTarget |
                Out-Null
            $rootJunctionResult = Invoke-Scanner -ScanPath $rootJunctionPath
            if ($rootJunctionResult.ExitCode -eq 0 -or
                $rootJunctionResult.Output -notmatch 'Explicit scan root must not be') {
                Add-Failure "Expected an explicit root junction to fail closed. Output: $($rootJunctionResult.Output.Trim())"
            }
        }
        finally {
            if (Test-Path -LiteralPath $rootJunctionPath) {
                [System.IO.Directory]::Delete($rootJunctionPath)
            }
        }

        # Dangling .git junction は target 解決で消えたように見えても Git 境界として fail-closed にする。
        $danglingGitRoot = Join-Path $tempRoot 'dangling git marker'
        $danglingGitTarget = Join-Path $tempRoot 'deleted git marker target'
        $danglingGitMarker = Join-Path $danglingGitRoot '.git'
        New-Item -ItemType Directory -Path $danglingGitRoot | Out-Null
        New-Item -ItemType Directory -Path $danglingGitTarget | Out-Null
        try {
            New-Item -ItemType Junction -Path $danglingGitMarker -Target $danglingGitTarget | Out-Null
            [System.IO.Directory]::Delete($danglingGitTarget)
            $danglingGitResult = Invoke-Scanner -ScanPath $danglingGitRoot
            Assert-FixedProcessBoundaryFailure `
                -Result $danglingGitResult `
                -Context 'Dangling .git marker with Git' `
                -ForbiddenPaths @(
                    $root,
                    $tempRoot,
                    $danglingGitRoot,
                    $danglingGitMarker,
                    $scanner,
                    $processBoundary
                )
            $danglingNoGitResult = Invoke-Scanner `
                -ScanPath $danglingGitRoot `
                -EnvironmentOverrides @{ PATH = $emptyCommandPath }
            Assert-FixedProcessBoundaryFailure `
                -Result $danglingNoGitResult `
                -Context 'Dangling .git marker without Git' `
                -ForbiddenPaths @(
                    $root,
                    $tempRoot,
                    $danglingGitRoot,
                    $danglingGitMarker,
                    $scanner,
                    $processBoundary,
                    $emptyCommandPath
                )
        }
        finally {
            $danglingGitEntry = Get-ChildItem `
                -LiteralPath $danglingGitRoot `
                -Force `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ceq '.git' } |
                Select-Object -First 1
            if ($null -ne $danglingGitEntry) {
                $danglingGitEntry.Delete()
            }
        }
    }

    # 敵対的な Git 環境は scanner の子だけへ渡す。親の absent / present-empty は変更しない。
    $trackedRoot = Join-Path $tempRoot 'git tracked target'
    $decoyRoot = Join-Path $tempRoot 'git decoy'
    $fixtureIsolationRoot = Join-Path $tempRoot 'fixture-git-isolation'
    $ambientRoot = Join-Path $tempRoot 'ambient-git'
    foreach ($directory in @($trackedRoot, $decoyRoot, $fixtureIsolationRoot, $ambientRoot)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $targetInit = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $fixtureIsolationRoot
    if ($targetInit.ExitCode -ne 0 -or $targetInit.TimedOut -or -not $targetInit.TreeStopped) {
        Add-Failure "Expected bounded target git init to succeed. Output: $($targetInit.Output.Trim())"
    }

    # 標準linked worktreeのroot `.git` はdirectoryではなくgitfileである。
    # 有効gitfileをfallback用leaf扱いで拒否せず、exact Git rootとして走査する。
    $linkedSourceRoot = Join-Path $tempRoot 'linked source repository'
    $linkedWorktreeRoot = Join-Path $tempRoot 'linked worktree target'
    New-Item -ItemType Directory -Path $linkedSourceRoot | Out-Null
    $linkedInit = Invoke-HermeticGit `
        -WorkingDirectory $linkedSourceRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $fixtureIsolationRoot
    Set-Content `
        -LiteralPath (Join-Path $linkedSourceRoot 'README.md') `
        -Value 'synthetic clean linked-worktree fixture' `
        -Encoding UTF8
    $linkedAdd = Invoke-HermeticGit `
        -WorkingDirectory $linkedSourceRoot `
        -Arguments @('add', '--', 'README.md') `
        -IsolationRoot $fixtureIsolationRoot
    $linkedFixtureEmail = 'synthetic' + '@example.invalid'
    $linkedCommit = Invoke-HermeticGit `
        -WorkingDirectory $linkedSourceRoot `
        -Arguments @(
            '-c',
            'user.name=Synthetic Fixture',
            '-c',
            "user.email=$linkedFixtureEmail",
            '-c',
            'commit.gpgSign=false',
            'commit',
            '--quiet',
            '-m',
            'synthetic linked source'
        ) `
        -IsolationRoot $fixtureIsolationRoot
    $linkedWorktreeAdded = $false
    if ($linkedInit.ExitCode -ne 0 -or
        $linkedAdd.ExitCode -ne 0 -or
        $linkedCommit.ExitCode -ne 0) {
        Add-Failure 'Expected the linked-worktree source fixture to initialize.'
    } else {
        $linkedWorktreeAdd = Invoke-HermeticGit `
            -WorkingDirectory $linkedSourceRoot `
            -Arguments @(
                'worktree',
                'add',
                '--quiet',
                '--detach',
                $linkedWorktreeRoot
            ) `
            -IsolationRoot $fixtureIsolationRoot
        $linkedWorktreeAdded = (
            $linkedWorktreeAdd.ExitCode -eq 0 -and
            -not $linkedWorktreeAdd.TimedOut -and
            $linkedWorktreeAdd.TreeStopped
        )
        if (-not $linkedWorktreeAdded) {
            Add-Failure 'Expected standard linked worktree creation to succeed.'
        } else {
            try {
                $linkedGitFile = Join-Path $linkedWorktreeRoot '.git'
                if (-not (Test-Path `
                        -LiteralPath $linkedGitFile `
                        -PathType Leaf) -or
                    (Test-Path `
                        -LiteralPath $linkedGitFile `
                        -PathType Container)) {
                    Add-Failure 'Expected a standard linked worktree root to expose a .git file.'
                }
                $linkedScanResult = Invoke-Scanner `
                    -ScanPath $linkedWorktreeRoot
                if ($linkedScanResult.ExitCode -ne 0 -or
                    $linkedScanResult.Output -notmatch 'git-tracked') {
                    Add-Failure 'Expected a valid linked-worktree gitfile root to scan in git-tracked mode.'
                }
            }
            finally {
                $linkedWorktreeRemove = Invoke-HermeticGit `
                    -WorkingDirectory $linkedSourceRoot `
                    -Arguments @(
                        'worktree',
                        'remove',
                        '--force',
                        $linkedWorktreeRoot
                    ) `
                    -IsolationRoot $fixtureIsolationRoot
                if ($linkedWorktreeRemove.ExitCode -ne 0 -or
                    $linkedWorktreeRemove.TimedOut -or
                    -not $linkedWorktreeRemove.TreeStopped) {
                    Add-Failure 'Expected linked-worktree fixture cleanup to succeed.'
                }
            }
        }
    }

    # regex timeoutとGit isolation cleanup failureを同時に起こし、先行stderrと
    # finally由来stderrが二重化しないことをgit-tracked経路で固定する。
    $trackedRegexTimeoutName = 'regex-timeout-cleanup.txt'
    $trackedRegexTimeoutPath =
        Join-Path $trackedRoot $trackedRegexTimeoutName
    [System.IO.File]::WriteAllText(
        $trackedRegexTimeoutPath,
        ('a.' * 500000),
        [System.Text.UTF8Encoding]::new($false)
    )
    $trackedRegexAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', $trackedRegexTimeoutName) `
        -IsolationRoot $fixtureIsolationRoot
    try {
        if ($trackedRegexAdd.ExitCode -ne 0 -or
            $trackedRegexAdd.TimedOut -or
            -not $trackedRegexAdd.TreeStopped) {
            Add-Failure (
                'Expected tracked regex-timeout fixture staging to succeed.'
            )
        } else {
            $trackedRegexCleanupFailure = Invoke-Scanner `
                -ScanPath $trackedRoot `
                -AdditionalArguments @(
                    '-ScanDeadlineMilliseconds',
                    '5000',
                    '-ProcessBoundaryFailureProbe',
                    'isolation-remove'
                )
            Assert-FixedProcessBoundaryFailure `
                -Result $trackedRegexCleanupFailure `
                -Context 'Regex timeout with isolation cleanup failure' `
                -ForbiddenPaths @(
                    $root,
                    $tempRoot,
                    $trackedRoot,
                    $trackedRegexTimeoutPath,
                    $scanner,
                    $processBoundary
                )
        }
    }
    finally {
        $trackedRegexRemove = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @(
                'rm',
                '--cached',
                '--force',
                '--',
                $trackedRegexTimeoutName
            ) `
            -IsolationRoot $fixtureIsolationRoot
        if ($trackedRegexAdd.ExitCode -eq 0 -and
            ($trackedRegexRemove.ExitCode -ne 0 -or
                $trackedRegexRemove.TimedOut -or
                -not $trackedRegexRemove.TreeStopped)) {
            Add-Failure (
                'Expected tracked regex-timeout fixture index cleanup to succeed.'
            )
        }
        if (Test-Path -LiteralPath $trackedRegexTimeoutPath -PathType Leaf) {
            Remove-Item -LiteralPath $trackedRegexTimeoutPath -Force
        }
    }

    # isolation create/removeとhelper exceptionを同じ固定exit 2へ畳み、
    # repo/temp/helper absolute pathをstdout/stderrへ一切展開しない。
    foreach ($boundaryProbe in @(
        'isolation-create',
        'helper',
        'isolation-remove'
    )) {
        $boundaryFailureResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -AdditionalArguments @(
                '-ProcessBoundaryFailureProbe',
                $boundaryProbe
            )
        Assert-FixedProcessBoundaryFailure `
            -Result $boundaryFailureResult `
            -Context "Process boundary probe '$boundaryProbe'" `
            -ForbiddenPaths @(
                $root,
                $tempRoot,
                $trackedRoot,
                $scanner,
                $processBoundary
            )
    }

    if ((Test-PrivateMarkerWindowsHost) -and
        (Test-Path -LiteralPath $syntheticGitPath -PathType Leaf)) {
        # final raw stage listing の直前に、実 index へ replacement と addition を
        # 同時適用し、開始 snapshot との差分を fail-closed で検出する。
        $indexMutationRoot = Join-Path $tempRoot 'index mutation target'
        $indexMutationIsolationRoot = Join-Path `
            $tempRoot `
            'index-mutation-git-isolation'
        foreach ($directory in @(
            $indexMutationRoot,
            $indexMutationIsolationRoot
        )) {
            New-Item -ItemType Directory -Path $directory | Out-Null
        }
        $replacementRelative = 'race-replaced.env'
        $additionRelative = 'race-added.env'
        $replacementPath = Join-Path $indexMutationRoot $replacementRelative
        $additionPath = Join-Path $indexMutationRoot $additionRelative
        Set-Content `
            -LiteralPath $replacementPath `
            -Value 'synthetic baseline replacement' `
            -Encoding UTF8
        $mutationInit = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $indexMutationIsolationRoot
        $mutationBaselineAdd = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('add', '--', $replacementRelative) `
            -IsolationRoot $indexMutationIsolationRoot
        $oldReplacementOid = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('rev-parse', ":$replacementRelative") `
            -IsolationRoot $indexMutationIsolationRoot

        Set-Content `
            -LiteralPath $replacementPath `
            -Value 'synthetic changed replacement' `
            -Encoding UTF8
        Set-Content `
            -LiteralPath $additionPath `
            -Value 'synthetic added during scan' `
            -Encoding UTF8
        $expectedReplacementOid = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('hash-object', '--', $replacementRelative) `
            -IsolationRoot $indexMutationIsolationRoot

        if (@(
            $mutationInit,
            $mutationBaselineAdd,
            $oldReplacementOid,
            $expectedReplacementOid
        ) | Where-Object {
            $_.ExitCode -ne 0 -or
            -not $_.StreamsCompleted -or
            -not $_.TreeStopped
        }) {
            Add-Failure 'Expected index-mutation fixture setup to succeed.'
        } else {
            $indexMutationCounter = Join-Path $tempRoot 'index-mutation-counter.txt'
            $indexMutationSentinel = Join-Path $tempRoot 'index-mutation-complete.txt'
            $realGitPath = (Get-Command git -ErrorAction Stop).Source
            $indexMutationResult = Invoke-Scanner `
                -ScanPath $indexMutationRoot `
                -EnvironmentOverrides @{
                    PATH = $syntheticGitDirectory
                    PRIVATE_MARKER_SYNTHETIC_GIT_MODE = 'index-mutation'
                    PRIVATE_MARKER_REAL_GIT = $realGitPath
                    PRIVATE_MARKER_INDEX_COUNTER = $indexMutationCounter
                    PRIVATE_MARKER_INDEX_REPO = $indexMutationRoot
                    PRIVATE_MARKER_INDEX_REPLACEMENT = $replacementRelative
                    PRIVATE_MARKER_INDEX_ADDITION = $additionRelative
                    PRIVATE_MARKER_INDEX_MUTATION_SENTINEL = $indexMutationSentinel
                }
            if ($indexMutationResult.ExitCode -eq 0 -or
                -not $indexMutationResult.StreamsCompleted -or
                -not $indexMutationResult.TreeStopped -or
                $indexMutationResult.TimedOut -or
                $indexMutationResult.OutputLimitExceeded -or
                $indexMutationResult.PipeLeakDetected -or
                -not $indexMutationResult.Output.Contains(
                    'Git index changed during the private marker scan.'
                )) {
                Add-Failure "Expected raw index drift to fail through a healthy boundary. Output: $($indexMutationResult.Output.Trim())"
            }
            if (-not (Test-Path -LiteralPath $indexMutationCounter) -or
                (Get-Content -LiteralPath $indexMutationCounter -Raw).Trim() -cne '2') {
                Add-Failure 'Expected exactly two raw stage listings in the index-mutation fixture.'
            }
            if (-not (Test-Path -LiteralPath $indexMutationSentinel)) {
                Add-Failure 'Expected the real staged mutation to complete before final index verification.'
            }

            $addedIndexEntry = Invoke-HermeticGit `
                -WorkingDirectory $indexMutationRoot `
                -Arguments @(
                    'ls-files',
                    '--error-unmatch',
                    '--',
                    $additionRelative
                ) `
                -IsolationRoot $indexMutationIsolationRoot
            $newReplacementOid = Invoke-HermeticGit `
                -WorkingDirectory $indexMutationRoot `
                -Arguments @('rev-parse', ":$replacementRelative") `
                -IsolationRoot $indexMutationIsolationRoot
            if ($addedIndexEntry.ExitCode -ne 0) {
                Add-Failure 'Expected the mutation proxy to add a real index entry.'
            }
            if ($newReplacementOid.ExitCode -ne 0 -or
                $newReplacementOid.Output.Trim() -ceq $oldReplacementOid.Output.Trim() -or
                $newReplacementOid.Output.Trim() -cne $expectedReplacementOid.Output.Trim()) {
                Add-Failure 'Expected the mutation proxy to replace the staged blob with the changed worktree blob.'
            }
        }

        # mode/OID/pathが同一のまま CE_INTENT_TO_ADD flagだけ変わる race も、
        # final raw debug snapshot の byte比較で検出する。
        $flagsMutationRoot = Join-Path $tempRoot 'flags mutation target'
        $flagsMutationIsolationRoot =
            Join-Path $tempRoot 'flags-mutation-git-isolation'
        New-Item -ItemType Directory -Path $flagsMutationRoot | Out-Null
        New-Item `
            -ItemType Directory `
            -Path $flagsMutationIsolationRoot |
            Out-Null
        $flagsRelative = 'flags-only-empty.md'
        $flagsPath = Join-Path $flagsMutationRoot $flagsRelative
        [System.IO.File]::WriteAllBytes($flagsPath, [byte[]]@())
        $flagsInit = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $flagsMutationIsolationRoot
        $flagsAdd = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments @('add', '--', $flagsRelative) `
            -IsolationRoot $flagsMutationIsolationRoot
        $flagsStageArguments = @(
            '-c',
            'core.quotepath=false',
            'ls-files',
            '-z',
            '--stage',
            '--',
            $flagsRelative
        )
        $flagsDebugArguments = @(
            '-c',
            'core.quotepath=false',
            'ls-files',
            '-z',
            '--stage',
            '--debug',
            '--',
            $flagsRelative
        )
        $flagsStageBefore = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments $flagsStageArguments `
            -IsolationRoot $flagsMutationIsolationRoot
        $flagsDebugBefore = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments $flagsDebugArguments `
            -IsolationRoot $flagsMutationIsolationRoot
        if (@(
            $flagsInit,
            $flagsAdd,
            $flagsStageBefore,
            $flagsDebugBefore
        ) | Where-Object {
            $_.ExitCode -ne 0 -or
            -not $_.StreamsCompleted -or
            -not $_.TreeStopped
        }) {
            Add-Failure 'Expected flags-only mutation fixture setup to succeed.'
        } else {
            $flagsMutationCounter =
                Join-Path $tempRoot 'flags-mutation-counter.txt'
            $flagsMutationSentinel =
                Join-Path $tempRoot 'flags-mutation-complete.txt'
            $realGitPath = (Get-Command git -ErrorAction Stop).Source
            $flagsMutationResult = Invoke-Scanner `
                -ScanPath $flagsMutationRoot `
                -EnvironmentOverrides @{
                    PATH = $syntheticGitDirectory
                    PRIVATE_MARKER_SYNTHETIC_GIT_MODE = 'flags-mutation'
                    PRIVATE_MARKER_REAL_GIT = $realGitPath
                    PRIVATE_MARKER_INDEX_COUNTER = $flagsMutationCounter
                    PRIVATE_MARKER_INDEX_REPO = $flagsMutationRoot
                    PRIVATE_MARKER_INDEX_REPLACEMENT = $flagsRelative
                    PRIVATE_MARKER_INDEX_MUTATION_SENTINEL =
                        $flagsMutationSentinel
                }
            if ($flagsMutationResult.ExitCode -eq 0 -or
                -not $flagsMutationResult.StreamsCompleted -or
                -not $flagsMutationResult.TreeStopped -or
                $flagsMutationResult.TimedOut -or
                $flagsMutationResult.OutputLimitExceeded -or
                $flagsMutationResult.PipeLeakDetected -or
                -not $flagsMutationResult.Output.Contains(
                    'Git index metadata changed during the private marker scan.'
                )) {
                Add-Failure "Expected flags-only index drift to fail through a healthy boundary. Output: $($flagsMutationResult.Output.Trim())"
            }
            if (-not (Test-Path -LiteralPath $flagsMutationCounter) -or
                (Get-Content -LiteralPath $flagsMutationCounter -Raw).Trim() -cne
                    '2') {
                Add-Failure 'Expected exactly two raw debug listings in the flags-only mutation fixture.'
            }
            if (-not (Test-Path -LiteralPath $flagsMutationSentinel)) {
                Add-Failure 'Expected the real flags-only mutation to complete before final metadata verification.'
            }

            $flagsStageAfter = Invoke-HermeticGit `
                -WorkingDirectory $flagsMutationRoot `
                -Arguments $flagsStageArguments `
                -IsolationRoot $flagsMutationIsolationRoot
            $flagsDebugAfter = Invoke-HermeticGit `
                -WorkingDirectory $flagsMutationRoot `
                -Arguments $flagsDebugArguments `
                -IsolationRoot $flagsMutationIsolationRoot
            if ($flagsStageAfter.ExitCode -ne 0 -or
                $flagsStageAfter.Output -cne $flagsStageBefore.Output) {
                Add-Failure 'Expected flags-only mutation to preserve exact stage listing bytes.'
            }
            if ($flagsDebugAfter.ExitCode -ne 0 -or
                $flagsDebugAfter.Output -ceq $flagsDebugBefore.Output -or
                $flagsDebugAfter.Output -notmatch 'flags: 2000[0-9a-fA-F]{4}') {
                Add-Failure 'Expected flags-only mutation to change only the raw debug metadata snapshot.'
            }
        }
    }

    $trackedMarker = ('g' + 'hp_') + 'synthetic_tracked_placeholder'
    $untrackedMarker = ('xo' + 'xb-') + 'synthetic_untracked_placeholder'
    $trackedDirectory = Join-Path $trackedRoot 'nested'
    New-Item -ItemType Directory -Path $trackedDirectory | Out-Null
    $trackedLeakPath = Join-Path $trackedDirectory 'leak.md'
    Set-Content -LiteralPath $trackedLeakPath -Value "synthetic marker: $trackedMarker" -Encoding UTF8
    $trackedMarkerBytes = [System.IO.File]::ReadAllBytes($trackedLeakPath)
    Set-Content -LiteralPath (Join-Path $trackedRoot 'untracked.md') -Value "synthetic marker: $untrackedMarker" -Encoding UTF8
    $targetAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($targetAdd.ExitCode -ne 0 -or $targetAdd.TimedOut -or -not $targetAdd.TreeStopped) {
        Add-Failure "Expected bounded target git add to succeed. Output: $($targetAdd.Output.Trim())"
    }
    # index にだけ marker を残し、clean な worktree で上書きして staged blob 検査を証明する。
    Set-Content `
        -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
        -Value 'synthetic clean worktree content' `
        -Encoding UTF8

    $decoyInit = Invoke-HermeticGit `
        -WorkingDirectory $decoyRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $fixtureIsolationRoot
    if ($decoyInit.ExitCode -ne 0 -or $decoyInit.TimedOut -or -not $decoyInit.TreeStopped) {
        Add-Failure "Expected bounded decoy git init to succeed. Output: $($decoyInit.Output.Trim())"
    }

    $ambientHooks = Join-Path $ambientRoot 'hooks'
    $ambientTemplate = Join-Path $ambientRoot 'template'
    $ambientObjects = Join-Path $decoyRoot (Join-Path '.git' 'objects')
    foreach ($directory in @($ambientHooks, $ambientTemplate)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $traceSentinel = Join-Path $ambientRoot 'git-trace.log'
    $trace2Sentinel = Join-Path $ambientRoot 'git-trace2.json'
    $hookSentinel = Join-Path $ambientRoot 'hook-fired.txt'
    $filterSentinel = Join-Path $ambientRoot 'filter-fired.txt'
    $ambientAttributes = Join-Path $ambientRoot 'attributes'
    $ambientExcludes = Join-Path $ambientRoot 'excludes'
    $ambientConfig = Join-Path $ambientRoot 'hostile.gitconfig'
    [System.IO.File]::WriteAllText($ambientAttributes, "*.md filter=synthetic`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($ambientExcludes, "nested/leak.md`n", [System.Text.UTF8Encoding]::new($false))
    $hookScript = @"
#!/bin/sh
printf '%s\n' 'hook-fired' > '$($hookSentinel.Replace([string][char]92, '/'))'
"@
    [System.IO.File]::WriteAllText(
        (Join-Path $ambientHooks 'post-index-change'),
        $hookScript,
        [System.Text.UTF8Encoding]::new($false)
    )
    $hostileConfigContent = @"
[core]
    hooksPath = $($ambientHooks.Replace([string][char]92, '/'))
    attributesFile = $($ambientAttributes.Replace([string][char]92, '/'))
    excludesFile = $($ambientExcludes.Replace([string][char]92, '/'))
[init]
    templateDir = $($ambientTemplate.Replace([string][char]92, '/'))
[filter "synthetic"]
    clean = sh -c "printf filter-fired > '$($filterSentinel.Replace([string][char]92, '/'))'; cat"
    required = true
"@
    [System.IO.File]::WriteAllText($ambientConfig, $hostileConfigContent, [System.Text.UTF8Encoding]::new($false))

    $decoyGitDirectory = Join-Path $decoyRoot '.git'
    $decoyIndex = Join-Path $decoyGitDirectory 'index'
    $adversarialEnvironment = @{
        GIT_DIR = $decoyGitDirectory
        GIT_WORK_TREE = $decoyRoot
        GIT_INDEX_FILE = $decoyIndex
        GIT_OBJECT_DIRECTORY = $ambientObjects
        GIT_ALTERNATE_OBJECT_DIRECTORIES = $ambientObjects
        GIT_CONFIG_GLOBAL = $ambientConfig
        GIT_CONFIG_SYSTEM = $ambientConfig
        GIT_CONFIG_NOSYSTEM = '0'
        GIT_CONFIG_COUNT = '2'
        GIT_CONFIG_KEY_0 = 'core.worktree'
        GIT_CONFIG_VALUE_0 = $decoyRoot
        GIT_CONFIG_KEY_1 = 'core.hooksPath'
        GIT_CONFIG_VALUE_1 = $ambientHooks
        GIT_TRACE = $traceSentinel
        GIT_TRACE2_EVENT = $trace2Sentinel
        GIT_TERMINAL_PROMPT = '1'
        GIT_NO_LAZY_FETCH = '0'
        GIT_NO_REPLACE_OBJECTS = '0'
        GIT_HYGIENE_PRESENT_EMPTY = ''
        HOME = $ambientRoot
        USERPROFILE = $ambientRoot
        XDG_CONFIG_HOME = $ambientRoot
    }

    $repositoryWithoutGitResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    Assert-FixedProcessBoundaryFailure `
        -Result $repositoryWithoutGitResult `
        -Context 'Tracked repository without Git' `
        -ForbiddenPaths @(
            $root,
            $tempRoot,
            $trackedRoot,
            $scanner,
            $processBoundary,
            $emptyCommandPath
        )

    $beforeAdversarialScan = Get-ProcessEnvironmentSnapshot
    $adversarialFailure = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    Assert-ProcessEnvironmentUnchanged `
        -Expected $beforeAdversarialScan `
        -Context 'Adversarial failing scanner child'
    if (-not $adversarialEnvironment.ContainsKey('GIT_HYGIENE_PRESENT_EMPTY') -or
        $adversarialEnvironment['GIT_HYGIENE_PRESENT_EMPTY'] -cne '') {
        Add-Failure 'Expected the controlled present-empty Git variable to remain present-empty.'
    }
    if ($adversarialFailure.TimedOut -or -not $adversarialFailure.TreeStopped) {
        Add-Failure "Expected adversarial failing scanner child to finish within bounds. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.ExitCode -eq 0) {
        Add-Failure 'Expected hostile Git variables not to empty or redirect the tracked-file scan.'
    }
    if ($adversarialFailure.Output -notmatch 'git-tracked') {
        Add-Failure "Expected adversarial fixture to retain git-tracked mode. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.Output -notmatch 'nested/leak\.md') {
        Add-Failure "Expected adversarial fixture to report the target repository marker. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.Output -notmatch '\bindex\b') {
        Add-Failure "Expected staged-only marker output to identify the index source. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.Output -match 'untracked\.md') {
        Add-Failure 'Expected git-tracked mode not to scan an untracked marker.'
    }
    if ($adversarialFailure.Output.Contains($trackedMarker) -or
        $adversarialFailure.Output.Contains($untrackedMarker)) {
        Add-Failure 'Expected adversarial findings to stay redacted.'
    }

    # refs/replace が staged blob を clean blob へ差し替えても、index の実体を検査する。
    $markerOidResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('rev-parse', ':nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    $cleanOidResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('hash-object', '-w', '--', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    $markerOid = $markerOidResult.Output.Trim()
    $cleanOid = $cleanOidResult.Output.Trim()
    if ($markerOidResult.ExitCode -ne 0 -or
        $cleanOidResult.ExitCode -ne 0 -or
        $markerOid -notmatch '^[0-9a-f]{40,64}$' -or
        $cleanOid -notmatch '^[0-9a-f]{40,64}$') {
        Add-Failure 'Expected replace-ref fixture object setup to succeed.'
    } else {
        $replaceAdd = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('replace', $markerOid, $cleanOid) `
            -IsolationRoot $fixtureIsolationRoot
        if ($replaceAdd.ExitCode -ne 0) {
            Add-Failure "Expected replace-ref fixture setup to succeed. Output: $($replaceAdd.Output.Trim())"
        } else {
            $replaceResult = Invoke-Scanner `
                -ScanPath $trackedRoot `
                -EnvironmentOverrides $adversarialEnvironment
            if ($replaceResult.ExitCode -eq 0 -or
                $replaceResult.Output -notmatch 'nested/leak\.md' -or
                $replaceResult.Output -notmatch '\bindex\b') {
                Add-Failure "Expected replace refs not to hide the staged marker. Output: $($replaceResult.Output.Trim())"
            }
            if ($replaceResult.Output.Contains($trackedMarker)) {
                Add-Failure 'Expected replace-ref finding to keep the staged marker redacted.'
            }
            $replaceDelete = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments @('replace', '-d', $markerOid) `
                -IsolationRoot $fixtureIsolationRoot
            if ($replaceDelete.ExitCode -ne 0) {
                Add-Failure "Expected replace-ref fixture cleanup to succeed. Output: $($replaceDelete.Output.Trim())"
            }
        }
    }

    # Partial clone の不足 blob は remote から補完せず、local-only 境界で即座に拒否する。
    if ($markerOid -match '^[0-9a-f]{40,64}$') {
        $promisorRemoteRoot = Join-Path $tempRoot 'promisor remote'
        $promisorRemoteDirectory = Join-Path $promisorRemoteRoot 'nested'
        New-Item -ItemType Directory -Path $promisorRemoteDirectory | Out-Null
        $promisorInit = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $fixtureIsolationRoot
        [System.IO.File]::WriteAllBytes(
            (Join-Path $promisorRemoteDirectory 'leak.md'),
            $trackedMarkerBytes
        )
        $promisorAdd = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @('add', '--', 'nested/leak.md') `
            -IsolationRoot $fixtureIsolationRoot
        $fixtureEmail = 'synthetic' + '@example.invalid'
        $promisorCommit = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @(
                '-c',
                'user.name=Synthetic Fixture',
                '-c',
                "user.email=$fixtureEmail",
                '-c',
                'commit.gpgSign=false',
                'commit',
                '--quiet',
                '-m',
                'synthetic promisor source'
            ) `
            -IsolationRoot $fixtureIsolationRoot
        $promisorOidResult = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @('rev-parse', ':nested/leak.md') `
            -IsolationRoot $fixtureIsolationRoot
        if ($promisorInit.ExitCode -ne 0 -or
            $promisorAdd.ExitCode -ne 0 -or
            $promisorCommit.ExitCode -ne 0 -or
            $promisorOidResult.Output.Trim() -cne $markerOid) {
            Add-Failure 'Expected synthetic promisor remote setup to preserve the staged blob OID.'
        } else {
            $partialCloneConfigResults = @(
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'extensions.partialClone', 'origin') `
                    -IsolationRoot $fixtureIsolationRoot
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'remote.origin.promisor', 'true') `
                    -IsolationRoot $fixtureIsolationRoot
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'remote.origin.partialclonefilter', 'blob:none') `
                    -IsolationRoot $fixtureIsolationRoot
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'remote.origin.url', $promisorRemoteRoot) `
                    -IsolationRoot $fixtureIsolationRoot
            )
            if ($partialCloneConfigResults | Where-Object { $_.ExitCode -ne 0 }) {
                Add-Failure 'Expected synthetic partial-clone configuration to succeed.'
            } else {
                $objectRelativePath = Join-Path `
                    $markerOid.Substring(0, 2) `
                    $markerOid.Substring(2)
                $localMarkerObject = Join-Path `
                    (Join-Path (Join-Path $trackedRoot '.git') 'objects') `
                    $objectRelativePath
                if (-not [System.IO.File]::Exists($localMarkerObject)) {
                    Add-Failure 'Expected the staged marker fixture to use a removable loose object.'
                } else {
                    $localMarkerObjectBytes = [System.IO.File]::ReadAllBytes($localMarkerObject)
                    try {
                        # Git for Windows は loose object を read-only にする場合があるため、
                        # synthetic fixture の退避前だけ通常属性へ戻す。
                        [System.IO.File]::SetAttributes(
                            $localMarkerObject,
                            [System.IO.FileAttributes]::Normal
                        )
                        [System.IO.File]::Delete($localMarkerObject)
                        $partialCloneResult = Invoke-Scanner `
                            -ScanPath $trackedRoot `
                            -EnvironmentOverrides $adversarialEnvironment
                        if ($partialCloneResult.ExitCode -eq 0) {
                            Add-Failure 'Expected a missing promisor blob to fail closed without lazy fetch.'
                        }
                        if ($partialCloneResult.Output.Contains($trackedMarker)) {
                            Add-Failure 'Expected missing-promisor diagnostics not to expose marker content.'
                        }
                        $postScanMissingCheck = Invoke-HermeticGit `
                            -WorkingDirectory $trackedRoot `
                            -Arguments @('cat-file', '-e', "$markerOid`^{blob}") `
                            -IsolationRoot $fixtureIsolationRoot
                        if ($postScanMissingCheck.ExitCode -eq 0) {
                            Add-Failure 'Expected the scanner not to fetch the missing promisor blob.'
                        }
                    }
                    finally {
                        # 回帰で同一 OID が再取得済みなら上書きせず、未取得時だけ退避 bytes を戻す。
                        if (-not [System.IO.File]::Exists($localMarkerObject)) {
                            [System.IO.File]::WriteAllBytes(
                                $localMarkerObject,
                                $localMarkerObjectBytes
                            )
                        }
                    }
                }
            }
            foreach ($configKey in @(
                'extensions.partialClone',
                'remote.origin.promisor',
                'remote.origin.partialclonefilter',
                'remote.origin.url'
            )) {
                $configCleanup = Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', '--unset-all', $configKey) `
                    -IsolationRoot $fixtureIsolationRoot
                if ($configCleanup.ExitCode -ne 0) {
                    Add-Failure "Expected partial-clone fixture cleanup to remove $configKey."
                }
            }
        }
    }

    # 同じ敵対環境で成功経路も通し、失敗時だけの cleanup 漏れを見逃さない。
    Set-Content -LiteralPath (Join-Path $trackedDirectory 'leak.md') -Value 'synthetic clean tracked content' -Encoding UTF8
    $targetRestage = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($targetRestage.ExitCode -ne 0 -or $targetRestage.TimedOut -or -not $targetRestage.TreeStopped) {
        Add-Failure "Expected bounded target git restage to succeed. Output: $($targetRestage.Output.Trim())"
    }

    $beforeAdversarialSuccess = Get-ProcessEnvironmentSnapshot
    $adversarialSuccess = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    Assert-ProcessEnvironmentUnchanged `
        -Expected $beforeAdversarialSuccess `
        -Context 'Adversarial successful scanner child'
    if ($adversarialSuccess.ExitCode -ne 0 -or
        $adversarialSuccess.TimedOut -or
        -not $adversarialSuccess.TreeStopped -or
        $adversarialSuccess.Output -notmatch 'git-tracked') {
        Add-Failure "Expected hostile Git variables not to break a clean tracked scan. Output: $($adversarialSuccess.Output.Trim())"
    }

    # Secretを含みやすい名前と拡張子を、index-only / worktree-only の
    # 両方向でまとめて固定する。各path/sourceを確認してmatrixの取りこぼしを防ぐ。
    $textCandidateCases = @(
        @{ Path = '.env';            Marker = ('g' + 'hp_') + 'synthetic_env_root' }
        @{ Path = '.env.local';      Marker = ('g' + 'hp_') + 'synthetic_env_variant' }
        @{ Path = 'production.env';  Marker = ('g' + 'hp_') + 'synthetic_env_suffix' }
        @{ Path = 'certificate.pem'; Marker = ('g' + 'hp_') + 'synthetic_pem' }
        @{ Path = 'private.key';     Marker = ('g' + 'hp_') + 'synthetic_key' }
        @{ Path = 'LICENSE';         Marker = ('g' + 'hp_') + 'synthetic_extensionless' }
        @{ Path = '.npmrc';          Marker = ('g' + 'hp_') + 'synthetic_dotfile' }
    )
    foreach ($case in $textCandidateCases) {
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic marker: $($case.Marker)" `
            -Encoding UTF8
    }
    $candidatePaths = @($textCandidateCases.Path)
    $candidateIndexAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments (@('add', '--') + $candidatePaths) `
        -IsolationRoot $fixtureIsolationRoot
    if ($candidateIndexAdd.ExitCode -ne 0) {
        Add-Failure "Expected text-candidate index fixture setup to succeed. Output: $($candidateIndexAdd.Output.Trim())"
    }
    foreach ($case in $textCandidateCases) {
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic clean worktree content: $($case.Path)" `
            -Encoding UTF8
    }
    $candidateIndexResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($candidateIndexResult.ExitCode -eq 0) {
        Add-Failure 'Expected index-only text-candidate markers to fail the scan.'
    }
    foreach ($case in $textCandidateCases) {
        $escapedPath = [regex]::Escape($case.Path)
        if ($candidateIndexResult.Output -notmatch "(?m)^\s*$escapedPath\s+index\s+") {
            Add-Failure "Expected index-only text candidate $($case.Path) to be reported from index. Output: $($candidateIndexResult.Output.Trim())"
        }
        if ($candidateIndexResult.Output.Contains($case.Marker)) {
            Add-Failure "Expected index-only text candidate $($case.Path) to stay redacted."
        }
    }

    $candidateCleanAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments (@('add', '--') + $candidatePaths) `
        -IsolationRoot $fixtureIsolationRoot
    if ($candidateCleanAdd.ExitCode -ne 0) {
        Add-Failure "Expected clean text-candidate baseline to be staged. Output: $($candidateCleanAdd.Output.Trim())"
    }
    foreach ($case in $textCandidateCases) {
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic marker: $($case.Marker)" `
            -Encoding UTF8
    }
    $candidateWorktreeResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($candidateWorktreeResult.ExitCode -eq 0) {
        Add-Failure 'Expected worktree-only text-candidate markers to fail the scan.'
    }
    foreach ($case in $textCandidateCases) {
        $escapedPath = [regex]::Escape($case.Path)
        if ($candidateWorktreeResult.Output -notmatch "(?m)^\s*$escapedPath\s+working-tree\s+") {
            Add-Failure "Expected worktree-only text candidate $($case.Path) to be reported from working-tree. Output: $($candidateWorktreeResult.Output.Trim())"
        }
        if ($candidateWorktreeResult.Output.Contains($case.Marker)) {
            Add-Failure "Expected worktree-only text candidate $($case.Path) to stay redacted."
        }
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic clean worktree content: $($case.Path)" `
            -Encoding UTF8
    }
    $candidateCleanup = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments (@('add', '--') + $candidatePaths) `
        -IsolationRoot $fixtureIsolationRoot
    if ($candidateCleanup.ExitCode -ne 0) {
        Add-Failure "Expected text-candidate fixture cleanup to succeed. Output: $($candidateCleanup.Output.Trim())"
    }

    $worktreeOnlyMarker = ('xo' + 'xb-') + 'synthetic_worktree_only'
    Set-Content `
        -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
        -Value "synthetic marker: $worktreeOnlyMarker" `
        -Encoding UTF8
    $worktreeOnlyResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($worktreeOnlyResult.ExitCode -eq 0 -or
        $worktreeOnlyResult.Output -notmatch '\bworking-tree\b' -or
        $worktreeOnlyResult.Output -notmatch 'nested/leak\.md') {
        Add-Failure "Expected worktree-only marker to be scanned beside the clean index blob. Output: $($worktreeOnlyResult.Output.Trim())"
    }
    if ($worktreeOnlyResult.Output.Contains($worktreeOnlyMarker)) {
        Add-Failure 'Expected the worktree-only marker to stay redacted.'
    }
    Set-Content `
        -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
        -Value 'synthetic clean tracked content' `
        -Encoding UTF8

    $subdirectoryResult = Invoke-Scanner `
        -ScanPath $trackedDirectory `
        -EnvironmentOverrides $adversarialEnvironment
    if ($subdirectoryResult.ExitCode -eq 0 -or
        $subdirectoryResult.Output -notmatch 'exact Git worktree root') {
        Add-Failure "Expected a Git subdirectory scan to fail closed instead of falling back. Output: $($subdirectoryResult.Output.Trim())"
    }

    # worktree から消えた tracked file も index blob から検査し、silent skip を防ぐ。
    $missingMarker = ('g' + 'hp_') + 'synthetic_missing_worktree'
    $missingPath = Join-Path $trackedRoot 'missing.md'
    Set-Content -LiteralPath $missingPath -Value "synthetic marker: $missingMarker" -Encoding UTF8
    $missingAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', 'missing.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($missingAdd.ExitCode -ne 0) {
        Add-Failure "Expected missing-worktree fixture add to succeed. Output: $($missingAdd.Output.Trim())"
    }
    [System.IO.File]::Delete($missingPath)
    $missingResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($missingResult.ExitCode -eq 0 -or
        $missingResult.Output -notmatch 'missing\.md' -or
        $missingResult.Output -notmatch '\bindex\b') {
        Add-Failure "Expected an index-only missing-worktree marker to fail the scan. Output: $($missingResult.Output.Trim())"
    }
    if ($missingResult.Output.Contains($missingMarker)) {
        Add-Failure 'Expected the missing-worktree index marker to stay redacted.'
    }
    $missingRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'missing.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($missingRemove.ExitCode -ne 0) {
        Add-Failure "Expected missing-worktree fixture cleanup to succeed. Output: $($missingRemove.Output.Trim())"
    }

    # local marker file は untracked 専用であり、index に現れた時点で内容を公開対象にしない。
    $trackedLocalMarkerPath = Join-Path $trackedRoot '.private-markers.local'
    $trackedLocalMarker = 'synthetic-tracked-local-marker'
    Set-Content `
        -LiteralPath $trackedLocalMarkerPath `
        -Value $trackedLocalMarker `
        -Encoding UTF8
    $trackedLocalAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '-f', '--', '.private-markers.local') `
        -IsolationRoot $fixtureIsolationRoot
    if ($trackedLocalAdd.ExitCode -ne 0) {
        Add-Failure "Expected tracked local-marker fixture setup to succeed. Output: $($trackedLocalAdd.Output.Trim())"
    } else {
        $trackedLocalResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($trackedLocalResult.ExitCode -eq 0 -or
            $trackedLocalResult.Output -notmatch 'must remain untracked') {
            Add-Failure "Expected a tracked .private-markers.local file to fail closed. Output: $($trackedLocalResult.Output.Trim())"
        }
        if ($trackedLocalResult.Output.Contains($trackedLocalMarker)) {
            Add-Failure 'Expected tracked local-marker diagnostics not to expose marker content.'
        }
    }
    $trackedLocalRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', '.private-markers.local') `
        -IsolationRoot $fixtureIsolationRoot
    if ($trackedLocalRemove.ExitCode -ne 0) {
        Add-Failure "Expected tracked local-marker fixture cleanup to succeed. Output: $($trackedLocalRemove.Output.Trim())"
    }
    [System.IO.File]::Delete($trackedLocalMarkerPath)

    # `ls-files --stage` では normal empty blob と同じOIDに見えるため、
    # CE_INTENT_TO_ADD flagを直接検査して present/missing worktree の双方を拒否する。
    $intentPath = Join-Path $trackedRoot 'intent.md'
    Set-Content -LiteralPath $intentPath -Value 'synthetic intent-to-add content' -Encoding UTF8
    $intentAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '-N', '--', 'intent.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($intentAdd.ExitCode -ne 0) {
        Add-Failure "Expected intent-to-add fixture setup to succeed. Output: $($intentAdd.Output.Trim())"
    }
    $intentResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($intentResult.ExitCode -eq 0 -or
        $intentResult.Output -notmatch 'intent-to-add') {
        Add-Failure "Expected present-worktree intent-to-add state to fail closed. Output: $($intentResult.Output.Trim())"
    }
    [System.IO.File]::Delete($intentPath)
    $missingIntentResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($missingIntentResult.ExitCode -eq 0 -or
        $missingIntentResult.Output -notmatch 'intent-to-add') {
        Add-Failure "Expected missing-worktree intent-to-add state to fail closed. Output: $($missingIntentResult.Output.Trim())"
    }
    $intentRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'intent.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($intentRemove.ExitCode -ne 0) {
        Add-Failure "Expected intent-to-add fixture cleanup to succeed. Output: $($intentRemove.Output.Trim())"
    }

    # CE_INTENT_TO_ADDを持たない通常の staged empty blob は正当なtextとして通す。
    $ordinaryEmptyRoot = Join-Path $tempRoot 'ordinary-empty-target'
    $ordinaryEmptyIsolationRoot =
        Join-Path $tempRoot 'ordinary-empty-git-isolation'
    New-Item -ItemType Directory -Path $ordinaryEmptyRoot | Out-Null
    New-Item -ItemType Directory -Path $ordinaryEmptyIsolationRoot | Out-Null
    $ordinaryEmptyRelative = 'ordinary-empty.md'
    $ordinaryEmptyPath = Join-Path $ordinaryEmptyRoot $ordinaryEmptyRelative
    [System.IO.File]::WriteAllBytes($ordinaryEmptyPath, [byte[]]@())
    $ordinaryEmptyInit = Invoke-HermeticGit `
        -WorkingDirectory $ordinaryEmptyRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $ordinaryEmptyIsolationRoot
    $ordinaryEmptyAdd = Invoke-HermeticGit `
        -WorkingDirectory $ordinaryEmptyRoot `
        -Arguments @('add', '--', $ordinaryEmptyRelative) `
        -IsolationRoot $ordinaryEmptyIsolationRoot
    if ($ordinaryEmptyInit.ExitCode -ne 0 -or
        $ordinaryEmptyAdd.ExitCode -ne 0) {
        Add-Failure "Expected ordinary empty-file fixture setup to succeed. Output: $($ordinaryEmptyAdd.Output.Trim())"
    } else {
        $ordinaryEmptyResult = Invoke-Scanner `
            -ScanPath $ordinaryEmptyRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($ordinaryEmptyResult.ExitCode -ne 0 -or
            $ordinaryEmptyResult.Output -match 'intent-to-add') {
            Add-Failure "Expected an ordinary staged empty blob to pass without intent-to-add classification. Output: $($ordinaryEmptyResult.Output.Trim())"
        }
    }

    # Index mode 120000 / 160000 は外部参照や別 repository へ進まず拒否する。
    $hashResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('hash-object', '-w', '--', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    $fixtureOid = $hashResult.Output.Trim()
    if ($hashResult.ExitCode -ne 0 -or $fixtureOid -notmatch '^[0-9a-f]{40,64}$') {
        Add-Failure "Expected fixture blob hashing to succeed. Output: $($hashResult.Output.Trim())"
    } else {
        foreach ($modeCase in @(
            @{ Mode = '120000'; Path = 'synthetic-link.md'; Label = 'symlink' },
            @{ Mode = '160000'; Path = 'synthetic-gitlink'; Label = 'gitlink' }
        )) {
            $modeAdd = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments @(
                    'update-index',
                    '--add',
                    '--cacheinfo',
                    "$($modeCase.Mode),$fixtureOid,$($modeCase.Path)"
                ) `
                -IsolationRoot $fixtureIsolationRoot
            if ($modeAdd.ExitCode -ne 0) {
                Add-Failure "Expected $($modeCase.Label) index fixture setup to succeed. Output: $($modeAdd.Output.Trim())"
                continue
            }
            $modeResult = Invoke-Scanner `
                -ScanPath $trackedRoot `
                -EnvironmentOverrides $adversarialEnvironment
            if ($modeResult.ExitCode -eq 0 -or
                $modeResult.Output -notmatch 'unsupported mode') {
                Add-Failure "Expected $($modeCase.Label) index mode to fail closed. Output: $($modeResult.Output.Trim())"
            }
            $modeRemove = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments @('update-index', '--force-remove', '--', $modeCase.Path) `
                -IsolationRoot $fixtureIsolationRoot
            if ($modeRemove.ExitCode -ne 0) {
                Add-Failure "Expected $($modeCase.Label) fixture cleanup to succeed. Output: $($modeRemove.Output.Trim())"
            }
        }
    }

    # Regular index entryをplatform linkへ差し替え、外部targetをfollowしないことを確認する。
    $directoryLinkItemType = if (Test-PrivateMarkerWindowsHost) {
        'Junction'
    } else {
        'SymbolicLink'
    }
    $reparsePath = Join-Path $trackedRoot 'reparse.md'
    $reparseTarget = Join-Path $tempRoot 'reparse-external-target'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $reparseTarget 'outside.md') -Value "synthetic marker: $trackedMarker" -Encoding UTF8
    Set-Content -LiteralPath $reparsePath -Value 'synthetic regular index content' -Encoding UTF8
    $reparseAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', 'reparse.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($reparseAdd.ExitCode -ne 0) {
        Add-Failure "Expected reparse fixture add to succeed. Output: $($reparseAdd.Output.Trim())"
    }
    [System.IO.File]::Delete($reparsePath)
    try {
        New-Item `
            -ItemType $directoryLinkItemType `
            -Path $reparsePath `
            -Target $reparseTarget |
            Out-Null
        $reparseResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($reparseResult.ExitCode -eq 0 -or
            $reparseResult.Output -notmatch 'not a regular local file') {
            Add-Failure "Expected a tracked reparse path to fail closed without following it. Output: $($reparseResult.Output.Trim())"
        }
    }
    finally {
        if (Test-Path -LiteralPath $reparsePath) {
            (Get-Item -LiteralPath $reparsePath -Force).Delete()
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $reparseTarget 'outside.md'))) {
        Add-Failure 'Expected reparse cleanup not to alter the external synthetic target.'
    }
    $reparseRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'reparse.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($reparseRemove.ExitCode -ne 0) {
        Add-Failure "Expected reparse fixture cleanup to succeed. Output: $($reparseRemove.Output.Trim())"
    }

    # leaf がregular fileでもparent platform linkなら外部directoryを辿るため拒否する。
    $parentReparseDirectory = Join-Path $trackedRoot 'parent-reparse'
    $parentReparsePath = Join-Path $parentReparseDirectory 'inside.md'
    $parentReparseTarget = Join-Path $tempRoot 'parent-reparse-external-target'
    New-Item -ItemType Directory -Path $parentReparseDirectory | Out-Null
    New-Item -ItemType Directory -Path $parentReparseTarget | Out-Null
    Set-Content `
        -LiteralPath $parentReparsePath `
        -Value 'synthetic regular parent-chain content' `
        -Encoding UTF8
    $parentReparseAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', 'parent-reparse/inside.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($parentReparseAdd.ExitCode -ne 0) {
        Add-Failure "Expected parent-reparse fixture add to succeed. Output: $($parentReparseAdd.Output.Trim())"
    }
    [System.IO.File]::Delete($parentReparsePath)
    [System.IO.Directory]::Delete($parentReparseDirectory)
    Set-Content `
        -LiteralPath (Join-Path $parentReparseTarget 'inside.md') `
        -Value 'synthetic external parent-chain content' `
        -Encoding UTF8
    try {
        New-Item `
            -ItemType $directoryLinkItemType `
            -Path $parentReparseDirectory `
            -Target $parentReparseTarget |
            Out-Null
        $parentReparseResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($parentReparseResult.ExitCode -eq 0 -or
            $parentReparseResult.Output -notmatch 'parent directory is a symlink or reparse point') {
            Add-Failure "Expected a tracked parent junction to fail closed without following it. Output: $($parentReparseResult.Output.Trim())"
        }
    }
    finally {
        if (Test-Path -LiteralPath $parentReparseDirectory) {
            (Get-Item -LiteralPath $parentReparseDirectory -Force).Delete()
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $parentReparseTarget 'inside.md'))) {
        Add-Failure 'Expected parent-junction cleanup not to alter the external synthetic target.'
    }
    $parentReparseRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'parent-reparse/inside.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($parentReparseRemove.ExitCode -ne 0) {
        Add-Failure "Expected parent-reparse fixture cleanup to succeed. Output: $($parentReparseRemove.Output.Trim())"
    }

    # Corrupt index は working-tree fallback に降格せず、Git present のまま拒否する。
    $targetIndexPath = Join-Path (Join-Path $trackedRoot '.git') 'index'
    $targetIndexBackup = [System.IO.File]::ReadAllBytes($targetIndexPath)
    try {
        [System.IO.File]::WriteAllBytes($targetIndexPath, [byte[]](1, 2, 3, 4))
        $malformedIndexResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        Assert-FixedProcessBoundaryFailure `
            -Result $malformedIndexResult `
            -Context 'Malformed Git index' `
            -ForbiddenPaths @(
                $root,
                $tempRoot,
                $trackedRoot,
                $targetIndexPath,
                $scanner,
                $processBoundary,
                $fixtureIsolationRoot
            )
    }
    finally {
        [System.IO.File]::WriteAllBytes($targetIndexPath, $targetIndexBackup)
    }

    # 実在する add/add conflict を作り、stage 1/2/3 のどれも blob scanへ進めない。
    $baseBranchResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('branch', '--show-current') `
        -IsolationRoot $fixtureIsolationRoot
    $baseBranch = $baseBranchResult.Output.Trim()
    $syntheticEmail = 'synthetic' + '@example.invalid'
    $identityArguments = @(
        '-c',
        'user.name=Synthetic Fixture',
        '-c',
        "user.email=$syntheticEmail",
        '-c',
        'commit.gpgSign=false'
    )
    $baseCommit = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments ($identityArguments + @('commit', '--quiet', '-m', 'synthetic base')) `
        -IsolationRoot $fixtureIsolationRoot
    if ($baseBranchResult.ExitCode -ne 0 -or
        [string]::IsNullOrWhiteSpace($baseBranch) -or
        $baseCommit.ExitCode -ne 0) {
        Add-Failure "Expected conflict fixture base commit to succeed. Output: $($baseCommit.Output.Trim())"
    } else {
        $sideSwitch = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('switch', '-c', 'synthetic-conflict-side') `
            -IsolationRoot $fixtureIsolationRoot
        $conflictPath = Join-Path $trackedRoot 'conflict.md'
        Set-Content -LiteralPath $conflictPath -Value 'synthetic side content' -Encoding UTF8
        $sideAdd = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('add', '--', 'conflict.md') `
            -IsolationRoot $fixtureIsolationRoot
        $sideCommit = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments ($identityArguments + @('commit', '--quiet', '-m', 'synthetic side')) `
            -IsolationRoot $fixtureIsolationRoot
        $baseSwitch = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('switch', $baseBranch) `
            -IsolationRoot $fixtureIsolationRoot
        Set-Content -LiteralPath $conflictPath -Value 'synthetic base content' -Encoding UTF8
        $baseAdd = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('add', '--', 'conflict.md') `
            -IsolationRoot $fixtureIsolationRoot
        $mainCommit = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments ($identityArguments + @('commit', '--quiet', '-m', 'synthetic main')) `
            -IsolationRoot $fixtureIsolationRoot
        if (@(
            $sideSwitch,
            $sideAdd,
            $sideCommit,
            $baseSwitch,
            $baseAdd,
            $mainCommit
        ) | Where-Object { $_.ExitCode -ne 0 }) {
            Add-Failure 'Expected conflict fixture branch setup to succeed.'
        } else {
            $mergeResult = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments ($identityArguments + @(
                    'merge',
                    '--no-edit',
                    'synthetic-conflict-side'
                )) `
                -IsolationRoot $fixtureIsolationRoot
            if ($mergeResult.ExitCode -eq 0 -or
                -not $mergeResult.StreamsCompleted -or
                -not $mergeResult.TreeStopped -or
                $mergeResult.Output -notmatch 'CONFLICT') {
                Add-Failure "Expected synthetic merge to produce a bounded conflict. Output: $($mergeResult.Output.Trim())"
            } else {
                $conflictResult = Invoke-Scanner `
                    -ScanPath $trackedRoot `
                    -EnvironmentOverrides $adversarialEnvironment
                if ($conflictResult.ExitCode -eq 0 -or
                    $conflictResult.Output -notmatch 'unresolved conflict') {
                    Add-Failure "Expected unresolved index stages to fail closed. Output: $($conflictResult.Output.Trim())"
                }
            }
            if (Test-Path -LiteralPath (Join-Path (Join-Path $trackedRoot '.git') 'MERGE_HEAD')) {
                $mergeAbort = Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('merge', '--abort') `
                    -IsolationRoot $fixtureIsolationRoot
                if ($mergeAbort.ExitCode -ne 0) {
                    Add-Failure "Expected conflict fixture cleanup to succeed. Output: $($mergeAbort.Output.Trim())"
                }
            }
        }
    }

    foreach ($sentinel in @($traceSentinel, $trace2Sentinel, $hookSentinel, $filterSentinel)) {
        if (Test-Path -LiteralPath $sentinel) {
            Add-Failure "Expected scanner Git children not to create ambient artifact: $(Split-Path -Leaf $sentinel)"
        }
    }

    # scanner が fixture 外の system temp に残す isolation root も差分で検出する。
    $remainingScannerIsolationRoots = @(
        Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
            -Directory `
            -Filter 'claude-code-devlog-hooks-git-*' `
            -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }
    )
    $newScannerIsolationRoots = @(
        Compare-Object `
            -ReferenceObject $preexistingScannerIsolationRoots `
            -DifferenceObject $remainingScannerIsolationRoots |
            Where-Object { $_.SideIndicator -eq '=>' } |
            ForEach-Object { "$($_.InputObject)" }
    )
    if ($newScannerIsolationRoots.Count -gt 0) {
        Add-Failure "Expected scanner isolation roots to be cleaned: $($newScannerIsolationRoots -join ', ')."
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'Private marker scan self-test failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host 'Private marker scan self-test passed.'
exit 0
