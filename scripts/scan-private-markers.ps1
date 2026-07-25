[CmdletBinding()]
param(
    [string]$Path = '',

    # 公開引数の型・範囲エラーをPowerShell binderへ渡すとscript絶対pathを
    # 出力し得る。objectで受け、body内の固定診断へ必ず畳む。
    [object]$GitCommandTimeoutMilliseconds = 15000,

    # 実運用のscan-wide上限は120秒から延長できない。こちらも文字列や
    # overflowをbody内で検証し、parameter binding由来のpath漏えいを防ぐ。
    [object]$ScanDeadlineMilliseconds = 120000,

    # self-test専用。process boundaryの失敗分岐だけを強制し、scan成功へ
    # bypassできないone-way fault injectionとして固定診断を検証する。
    [string]$ProcessBoundaryFailureProbe = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PrivateMarkerDiagnosticText {
    param(
        [AllowNull()]
        [string]$Value,
        [int]$MaximumCodeUnits = 512
    )

    if ($null -eq $Value) {
        return '<null>'
    }

    # Terminal 制御・bidi 制御・Unicode 改行を必ず可視化し、
    # path や環境変数名から偽の診断行を作れないようにする。
    $builder = New-Object System.Text.StringBuilder
    $length = [Math]::Min($Value.Length, $MaximumCodeUnits)
    for ($index = 0; $index -lt $length; $index++) {
        $character = $Value[$index]
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory(
            $character
        )
        if ($category -in @(
            [System.Globalization.UnicodeCategory]::Control,
            [System.Globalization.UnicodeCategory]::Format,
            [System.Globalization.UnicodeCategory]::LineSeparator,
            [System.Globalization.UnicodeCategory]::ParagraphSeparator,
            [System.Globalization.UnicodeCategory]::Surrogate
        )) {
            [void]$builder.Append('\u')
            [void]$builder.Append(
                ([int]$character).ToString(
                    'X4',
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            )
        } else {
            [void]$builder.Append($character)
        }
    }
    if ($Value.Length -gt $MaximumCodeUnits) {
        [void]$builder.Append('...<truncated>')
    }
    return $builder.ToString()
}

function Stop-PrivateMarkerProcessBoundaryFailure {
    # exception本文やErrorRecordを出すとrepo/temp/helperのabsolute pathが
    # PowerShell framingへ混ざる。全boundary failureを固定ASCII 1行へ畳む。
    [Console]::Error.WriteLine(
        'Private marker scan failed closed (integrity: process-boundary).'
    )
    exit 2
}

function Stop-PrivateMarkerRegexTimeout {
    # RegexMatchTimeoutExceptionをそのまま出すとPowerShell framingにscript pathが
    # 混ざり得る。input/pattern/exceptionを再掲せず、固定ASCII 1行へ畳む。
    [Console]::Error.WriteLine(
        'Private marker scan failed closed (integrity: regex-timeout).'
    )
    exit 2
}

function ConvertTo-PrivateMarkerBoundedIntegerParameter {
    param(
        [AllowNull()]
        [object]$Value,
        [int]$Minimum,
        [int]$Maximum
    )

    try {
        # invariantな十進整数だけを受理し、nonnumeric/overflow/range外を
        # 同じprocess-boundary診断へ畳む。raw値は一切出力しない。
        [int]$candidate = 0
        $text = if ($null -eq $Value) { '' } else { [string]$Value }
        $parsed = [int]::TryParse(
            $text,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$candidate
        )
        if (-not $parsed -or
            $candidate -lt $Minimum -or
            $candidate -gt $Maximum) {
            Stop-PrivateMarkerProcessBoundaryFailure
        }
        return $candidate
    }
    catch {
        Stop-PrivateMarkerProcessBoundaryFailure
    }
}

# binderより後・path解決より前に全公開test seamを検証する。これにより
# invalid parameterでもstdoutは空、stderrは固定ASCII 1行、exitは2となる。
$GitCommandTimeoutMilliseconds =
    ConvertTo-PrivateMarkerBoundedIntegerParameter `
        -Value $GitCommandTimeoutMilliseconds `
        -Minimum 250 `
        -Maximum 15000
$ScanDeadlineMilliseconds =
    ConvertTo-PrivateMarkerBoundedIntegerParameter `
        -Value $ScanDeadlineMilliseconds `
        -Minimum 1 `
        -Maximum 120000
try {
    if ($ProcessBoundaryFailureProbe -cnotin @(
        '',
        'isolation-create',
        'isolation-remove',
        'helper'
    )) {
        Stop-PrivateMarkerProcessBoundaryFailure
    }
}
catch {
    Stop-PrivateMarkerProcessBoundaryFailure
}

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

try {
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}
catch {
    # provider例外を再throwするとPowerShell自身のframingがscanner絶対pathを
    # stderrへ付加する。固定ASCII診断を一度だけ書き、host側例外化を避ける。
    [Console]::Error.WriteLine(
        'Private marker scan failed closed (integrity: scan-root-missing).'
    )
    exit 2
}
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw 'Private marker scan path must be a directory.'
}
try {
    $processBoundary = Join-Path `
        $scriptRoot `
        'private-marker-process.ps1' `
        -ErrorAction Stop
    if (-not (Test-Path `
            -LiteralPath $processBoundary `
            -PathType Leaf `
            -ErrorAction Stop)) {
        Stop-PrivateMarkerProcessBoundaryFailure
    }

    # helperが誤って成功出力を返してもscanner stdoutへ流さず、
    # dot-source中の例外だけを固定process-boundary診断へ変換する。
    $null = . $processBoundary
}
catch {
    Stop-PrivateMarkerProcessBoundaryFailure
}

# この公開skill自身だけを許可する。既存契約を広げず、関連repoへのURLも
# publish前の明示的な審査なしには通さない。
$allowedRepoUrlPattern = '^https://github\.com/h8nc4y/claude-code-devlog-hooks(?:\.git)?$'

$maximumScanMilliseconds = $ScanDeadlineMilliseconds
$scanClock = [System.Diagnostics.Stopwatch]::StartNew()
$maximumRegexMatchMilliseconds = 250
$regexMatchTimeoutMilliseconds = [Math]::Max(
    1,
    [Math]::Min(
        $maximumRegexMatchMilliseconds,
        $maximumScanMilliseconds
    )
)
$regexMatchTimeout = [TimeSpan]::FromMilliseconds(
    $regexMatchTimeoutMilliseconds
)

function New-PrivateMarkerBoundedRegex {
    param(
        [string]$Pattern,
        [System.Text.RegularExpressions.RegexOptions]$Options
    )

    # .NET 4.5 / Windows PowerShell 5.1互換の3引数constructorで、
    # scan-wide checkが介入できない単一Match/IsMatchにも有限上限を持たせる。
    return [regex]::new(
        $Pattern,
        $Options,
        $regexMatchTimeout
    )
}

# Gitやpathの構造検証もcandidate ruleと同じ有限timeoutを共有する。
# PowerShellの`-match`/`-split`や2引数static Matchへ戻すと既定timeoutが無限に
# なるため、regexが必要な構造判定はすべてこのobject群へ固定する。
$internalRegexOptions =
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
$gitNotRepositoryErrorMatcher = New-PrivateMarkerBoundedRegex `
    -Pattern '(?m)^fatal: not a git repository\b' `
    -Options $internalRegexOptions
$gitRawDiffHeaderMatcher = New-PrivateMarkerBoundedRegex `
    -Pattern '^:(?<oldMode>[0-9]{6}) (?<newMode>[0-9]{6}) (?<oldOid>[0-9a-f]{40}|[0-9a-f]{64}) (?<newOid>[0-9a-f]{40}|[0-9a-f]{64}) (?<status>[A-Z])(?<score>[0-9]{0,3})$' `
    -Options $internalRegexOptions
$gitIndexEntryMatcher = New-PrivateMarkerBoundedRegex `
    -Pattern '(?s)^(?<mode>[0-9]{6}) (?<oid>[0-9a-f]{40}|[0-9a-f]{64}) (?<stage>[0-3])\t(?<path>.+)$' `
    -Options $internalRegexOptions
$allZeroOidMatcher = New-PrivateMarkerBoundedRegex `
    -Pattern '^0+$' `
    -Options $internalRegexOptions
$controlCharacterMatcher = New-PrivateMarkerBoundedRegex `
    -Pattern '[\x00-\x1F\x7F]' `
    -Options $internalRegexOptions
$gitBatchHeaderMatcher = New-PrivateMarkerBoundedRegex `
    -Pattern '^(?<oid>[0-9a-fA-F]{40}|[0-9a-fA-F]{64}) blob (?<size>0|[1-9][0-9]*)$' `
    -Options $internalRegexOptions

$maximumScanRules = 256
$maximumRulePatternCharacters = 4096
$rules = New-Object System.Collections.Generic.List[object]

function Add-ScanRule {
    param(
        [string]$Name,
        [string]$Pattern,
        [ValidateSet('literal', 'regex')]
        [string]$Kind,
        # Optional: suppress regex matches whose value is a known-safe placeholder.
        # This keeps documentation examples from becoming noisy findings.
        [string]$Allowlist = ''
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return
    }
    if ($Pattern.Length -gt $maximumRulePatternCharacters) {
        throw 'Private marker rule exceeded its pattern-length limit.'
    }
    if ($rules.Count -ge $maximumScanRules) {
        throw 'Private marker scan exceeded its rule-count limit.'
    }

    $rules.Add([pscustomobject]@{
        Name = $Name
        Pattern = $Pattern
        Kind = $Kind
        Allowlist = $Allowlist
        Matcher = if ($Kind -eq 'regex') {
            New-PrivateMarkerBoundedRegex `
                -Pattern $Pattern `
                -Options (
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
                )
        } else {
            $null
        }
        AllowlistMatcher = if ([string]::IsNullOrEmpty($Allowlist)) {
            $null
        } else {
            New-PrivateMarkerBoundedRegex `
                -Pattern $Allowlist `
                -Options (
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
                )
        }
    }) | Out-Null
}

Add-ScanRule -Name 'openai-api-key-prefix' -Pattern '(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}' -Kind 'regex'
Add-ScanRule -Name 'github-classic-token-prefix' -Pattern ('g' + 'hp_') -Kind 'literal'
Add-ScanRule -Name 'github-fine-grained-token-prefix' -Pattern ('github' + '_pat_') -Kind 'literal'
Add-ScanRule -Name 'slack-bot-token-prefix' -Pattern ('xo' + 'xb-') -Kind 'literal'
Add-ScanRule -Name 'bearer-token-header' -Pattern ('Bearer' + ' ') -Kind 'literal'
Add-ScanRule -Name 'private-key-block' -Pattern ('BEGIN ' + 'PRIVATE KEY') -Kind 'literal'
Add-ScanRule -Name 'email-address' -Pattern '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b' -Kind 'regex'
# windows-absolute-path detects private-looking absolute Windows paths while allowing
# documented placeholders. The regex stops before bracketed placeholder segments and
# can also greedily include trailing prose, so the allowlist suppresses either:
#   (a) values ending at a path separator with only placeholder or parent words, or
#   (b) full placeholder-only paths, with optional trailing prose.
# Real-looking paths with non-placeholder child segments remain findings.
# Keep literal absolute paths out of comments so this script does not flag itself.
$winPathPlaceholderWord = '(?:path|to|repo|you|your|example|placeholder|dir|folder|project|projects)'
$winPathParentWord = '(?:users|user|home|documents|appdata|local|roaming)'
$windowsPathPlaceholderAllowlist = '(?ix)^[A-Za-z]:\\(?:' +
    # (a) Placeholder or parent words only, ending at a separator.
    "(?:(?:$winPathPlaceholderWord|$winPathParentWord)\\)+" +
    '|' +
    # (b) Full placeholder-only paths, optionally followed by prose.
    "(?:$winPathPlaceholderWord\\?)+(?:\s.*)?" +
    ')$'
Add-ScanRule -Name 'windows-absolute-path' -Pattern '\b[A-Za-z]:\\(?:[^\\/:*?"<>|\r\n]+\\?){2,}' -Kind 'regex' -Allowlist $windowsPathPlaceholderAllowlist

# Additional cloud / key-block prefixes for higher secret recall.
# Prefixes are split so this scanner does not match its own rule definitions.
Add-ScanRule -Name 'aws-access-key-id' -Pattern ('A' + 'KIA') -Kind 'literal'
Add-ScanRule -Name 'gcp-api-key-prefix' -Pattern ('AIza' + '[0-9A-Za-z_\-]{35}') -Kind 'regex'
Add-ScanRule -Name 'slack-user-token-prefix' -Pattern ('xo' + 'xp-') -Kind 'literal'
Add-ScanRule -Name 'slack-legacy-app-token-prefix' -Pattern ('xo' + 'xa-') -Kind 'literal'
Add-ScanRule -Name 'slack-app-level-token-prefix' -Pattern ('xa' + 'pp-') -Kind 'literal'
Add-ScanRule -Name 'stripe-live-secret-key' -Pattern ('(s' + 'k|rk)_live_[0-9A-Za-z]{16,}') -Kind 'regex'
Add-ScanRule -Name 'pem-private-key-block' -Pattern ('BEGIN ' + '(RSA|EC|OPENSSH|ENCRYPTED) PRIVATE KEY') -Kind 'regex'

$localMarkerIndex = 0

function Add-LocalMarker {
    param([string]$Marker)

    $trimmed = $Marker.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
        return
    }
    if ($trimmed.Length -gt $maximumRulePatternCharacters) {
        throw 'Local private marker exceeded its length limit.'
    }

    $script:localMarkerIndex++
    Add-ScanRule -Name "local-private-marker-$script:localMarkerIndex" -Pattern $trimmed -Kind 'literal'
}

$localMarkerFile = Join-Path $root '.private-markers.local'

$githubUrlPattern = 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?'
$githubUrlMatcher = New-PrivateMarkerBoundedRegex `
    -Pattern $githubUrlPattern `
    -Options (
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
$allowedRepoUrlMatcher = New-PrivateMarkerBoundedRegex `
    -Pattern $allowedRepoUrlPattern `
    -Options (
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
$findings = New-Object System.Collections.Generic.List[object]

# Binary noiseを避けつつ、secretを含みやすい拡張子と名前を明示的に含める。
# Extensionless と high-signal dotfile（.npmrc等）も text candidate に含める。
$textExtensions = @(
    '.md', '.markdown', '.txt', '.ps1', '.psm1', '.psd1', '.yml', '.yaml',
    '.json', '.jsonc', '.toml', '.ini', '.cfg', '.conf', '.xml', '.csv',
    '.sh', '.bash', '.bat', '.cmd', '.py', '.js', '.ts', '.css', '.html',
    '.htm', '.editorconfig', '.gitattributes', '.gitignore', '.env', '.pem',
    '.key'
)
$textExtensionSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$textExtensions, [System.StringComparer]::OrdinalIgnoreCase)
$textFileNameSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        '.env',
        '.npmrc',
        '.yarnrc',
        '.netrc',
        '.pypirc',
        '.git-credentials'
    ),
    [System.StringComparer]::OrdinalIgnoreCase
)

function Test-IsTextFile {
    param([string]$FullPath)

    $fileName = [System.IO.Path]::GetFileName($FullPath)
    if ($textFileNameSet.Contains($fileName) -or
        $fileName.StartsWith('.env.', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($fileName.StartsWith(
            '.',
            [System.StringComparison]::Ordinal
        ) -and
        $fileName.IndexOf(
            '.',
            1,
            [System.StringComparison]::Ordinal
        ) -lt 0) {
        # `.GIT`のような単一leading-dot名はPOSIXでは通常のextensionless
        # dotfileである。metadata除外は列挙側のexact `.git` 判定だけに任せる。
        return $true
    }
    $extension = [System.IO.Path]::GetExtension($FullPath)
    if ([string]::IsNullOrEmpty($extension)) {
        # Treat extensionless files as text.
        return $true
    }
    return $textExtensionSet.Contains($extension)
}

function Get-ProcessEnvironmentSnapshot {
    $snapshot = @{}
    $environment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($name in $environment.Keys) {
        $snapshot["$name"] = [string]$environment[$name]
    }
    return $snapshot
}

function Get-ChangedEnvironmentVariableNames {
    param([hashtable]$Expected)

    $actual = Get-ProcessEnvironmentSnapshot
    $differentNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Expected.Keys + $actual.Keys) | Sort-Object -Unique) {
        if ($Expected.ContainsKey($name) -ne $actual.ContainsKey($name) -or
            ($Expected.ContainsKey($name) -and $Expected[$name] -cne $actual[$name])) {
            # 秘密値を出力しない。境界違反の診断に必要な変数名だけを保持する。
            $differentNames.Add(
                (ConvertTo-PrivateMarkerDiagnosticText "$name")
            ) | Out-Null
        }
    }
    return @($differentNames)
}

$maximumTrackedEntries = 10000
$maximumTextBytes = 5MB
$maximumTotalTextBytes = 50MB
$maximumGitListBytes = 8MB
$maximumGitDebugBytes = $maximumGitListBytes + ($maximumTrackedEntries * 192)
$maximumLineCharacters = 1MB
$maximumLinesPerTarget = 100000
$maximumTotalScannedLines = 500000
$maximumMatchesPerRulePerLine = 256
$maximumFindingsPerFile = 64
$maximumTotalFindings = 512
$maximumFindingOutputBytes = 64KB
$totalTextBytes = 0L
$totalScannedLines = 0L
$scanTargets = New-Object System.Collections.Generic.List[object]
$findingCountByFile = [System.Collections.Generic.Dictionary[string, int]]::new(
    [System.StringComparer]::Ordinal
)
try {
    $canonicalRoot =
        [System.IO.Path]::GetFullPath($root).TrimEnd([char]92, [char]47)
}
catch {
    throw 'Private marker scan root could not be canonicalized.'
}
$rootPrefix = $canonicalRoot + [System.IO.Path]::DirectorySeparatorChar
$pathComparison = if (Test-PrivateMarkerWindowsHost) {
    [StringComparison]::OrdinalIgnoreCase
} else {
    [StringComparison]::Ordinal
}
$gitIndexArguments = @(
    '-C',
    $canonicalRoot,
    '-c',
    'core.quotepath=false',
    'ls-files',
    '-z',
    '--stage',
    '--'
)
$gitIndexDebugArguments = @(
    '-C',
    $canonicalRoot,
    '-c',
    'core.quotepath=false',
    'ls-files',
    '-z',
    '--stage',
    '--debug',
    '--'
)

function Assert-PrivateMarkerScanDeadline {
    # Git childだけでなく、file列挙・decode・regex・結果serializeも同じ時計へ
    # 収める。capの各段階で呼び、CPU側へdeadline外処理を逃がさない。
    if ($scanClock.ElapsedMilliseconds -ge $maximumScanMilliseconds) {
        throw 'Private marker scan exceeded its scan-wide time budget.'
    }
}

function Add-BoundedFinding {
    param(
        [string]$File,
        [string]$Source,
        [int]$Line,
        [string]$Rule
    )

    Assert-PrivateMarkerScanDeadline
    $safeFile = ConvertTo-PrivateMarkerDiagnosticText $File
    $safeSource = ConvertTo-PrivateMarkerDiagnosticText $Source
    $safeRule = ConvertTo-PrivateMarkerDiagnosticText $Rule
    $fileFindingCount = 0
    [void]$findingCountByFile.TryGetValue($safeFile, [ref]$fileFindingCount)
    if ($fileFindingCount -ge $maximumFindingsPerFile) {
        throw "Private marker scan exceeded the per-file finding limit: $safeFile."
    }
    if ($findings.Count -ge $maximumTotalFindings) {
        throw 'Private marker scan exceeded its total finding limit.'
    }

    $findingCountByFile[$safeFile] = $fileFindingCount + 1
    $findings.Add([pscustomobject]@{
        File = $safeFile
        Source = $safeSource
        Line = $Line
        Rule = $safeRule
        Match = '<redacted>'
    }) | Out-Null
}

function Invoke-BoundedLineAction {
    param(
        [string]$Content,
        [string]$Context,
        [scriptblock]$Action
    )

    # Regex.Split / -split は行数に比例する配列を複製するため使わない。
    # 1行ずつ bounded substring を渡し、行長・file行数・全体行数を独立に制限する。
    $offset = 0
    $lineNumber = 1
    while ($true) {
        Assert-PrivateMarkerScanDeadline
        if ($lineNumber -gt $maximumLinesPerTarget) {
            throw "Text scan target exceeded its line-count limit: $Context."
        }
        $script:totalScannedLines++
        if ($script:totalScannedLines -gt $maximumTotalScannedLines) {
            throw 'Private marker scan exceeded its total line-count limit.'
        }

        $carriageReturnIndex = $Content.IndexOf([char]13, $offset)
        $lineFeedIndex = $Content.IndexOf([char]10, $offset)
        if ($carriageReturnIndex -lt 0) {
            $lineEnd = $lineFeedIndex
        } elseif ($lineFeedIndex -lt 0) {
            $lineEnd = $carriageReturnIndex
        } else {
            $lineEnd = [Math]::Min($carriageReturnIndex, $lineFeedIndex)
        }

        if ($lineEnd -lt 0) {
            $lineLength = $Content.Length - $offset
        } else {
            $lineLength = $lineEnd - $offset
        }
        if ($lineLength -gt $maximumLineCharacters) {
            throw "Text scan target contains an overlong line: $Context."
        }

        $line = $Content.Substring($offset, $lineLength)
        & $Action $line $lineNumber
        if ($lineEnd -lt 0) {
            break
        }

        $offset = $lineEnd + 1
        if ($Content[$lineEnd] -eq [char]13 -and
            $offset -lt $Content.Length -and
            $Content[$offset] -eq [char]10) {
            $offset++
        }
        if ($offset -ge $Content.Length) {
            break
        }
        $lineNumber++
    }
}

function Get-RemainingGitTimeoutMilliseconds {
    Assert-PrivateMarkerScanDeadline
    $remaining = $maximumScanMilliseconds - [int]$scanClock.ElapsedMilliseconds
    if ($remaining -le 0) {
        throw 'Private marker scan exceeded its overall Git time budget.'
    }
    return [Math]::Min($GitCommandTimeoutMilliseconds, $remaining)
}

function Invoke-ScannerGit {
    param(
        [string[]]$Arguments,
        [int]$MaximumStandardOutputBytes,
        [byte[]]$StandardInputBytes = $null
    )

    try {
        if ($ProcessBoundaryFailureProbe -eq 'helper') {
            throw 'Synthetic process helper failure.'
        }
        return Invoke-PrivateMarkerProcess `
            -FileName $gitExe.Source `
            -Arguments $Arguments `
            -StandardInputBytes $StandardInputBytes `
            -WorkingDirectory $canonicalRoot `
            -SanitizeGitEnvironment `
            -IsolationRoot $gitIsolationRoot `
            -TimeoutMilliseconds (Get-RemainingGitTimeoutMilliseconds) `
            -MaximumStandardOutputBytes $MaximumStandardOutputBytes
    }
    catch {
        Stop-PrivateMarkerProcessBoundaryFailure
    }
}

function Assert-HealthyGitBoundary {
    param(
        [pscustomobject]$Result,
        [string]$Context,
        [switch]$AllowNonzeroExit
    )

    try {
        # helperの戻り値形状が壊れている場合もStrictMode例外を外へ出さず、
        # process-boundary failureとして同じ固定診断へ畳む。
        if ($Result.TimedOut -or
            $Result.OutputLimitExceeded -or
            $Result.InputWriteFailed -or
            $Result.PipeLeakDetected -or
            -not $Result.StreamsCompleted -or
            -not $Result.TreeStopped) {
            Stop-PrivateMarkerProcessBoundaryFailure
        }
        if (-not $AllowNonzeroExit -and $Result.ExitCode -ne 0) {
            Stop-PrivateMarkerProcessBoundaryFailure
        }
    }
    catch {
        Stop-PrivateMarkerProcessBoundaryFailure
    }
}

function Remove-PrivateMarkerGitIsolationRoot {
    param([string]$IsolationRoot)

    try {
        if ($ProcessBoundaryFailureProbe -eq 'isolation-remove') {
            throw 'Synthetic isolation cleanup failure.'
        }
        if (Test-Path -LiteralPath $IsolationRoot -ErrorAction Stop) {
            Remove-Item `
                -LiteralPath $IsolationRoot `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
    }
    catch {
        if ($ProcessBoundaryFailureProbe -eq 'isolation-remove') {
            # fault injectionでだけ初回removeを失敗させる。test residueを残さず、
            # recovery失敗も外部へ展開しないbest-effort retryを行う。
            try {
                if (Test-Path -LiteralPath $IsolationRoot -ErrorAction Stop) {
                    Remove-Item `
                        -LiteralPath $IsolationRoot `
                        -Recurse `
                        -Force `
                        -ErrorAction Stop
                }
            }
            catch {
                # 共通固定診断へ畳むため、retryのpath-bearing例外は破棄する。
            }
        }
        Stop-PrivateMarkerProcessBoundaryFailure
    }
}

function Test-GitMarkerInAncestry {
    $directory = New-Object System.IO.DirectoryInfo($canonicalRoot)
    $nameComparison = if (Test-PrivateMarkerWindowsHost) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    while ($null -ne $directory) {
        # Marker 自体を直接解決すると dangling symlink / junction を「存在しない」と誤認し得る。
        # 親 directory を非再帰で列挙し、reparse target を辿らず entry 名だけを確認する。
        try {
            $ancestryEntries = @(
                Get-ChildItem `
                    -LiteralPath $directory.FullName `
                    -Force `
                    -Filter '.git' `
                    -ErrorAction Stop |
                    Select-Object -First 2
            )
        }
        catch {
            throw 'Private marker scan could not inspect the .git ancestry.'
        }
        foreach ($entry in $ancestryEntries) {
            if ([string]::Equals($entry.Name, '.git', $nameComparison)) {
                return $true
            }
        }
        $directory = $directory.Parent
    }
    return $false
}

function Test-ByteArraysEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Test-SafeWorktreeParentChain {
    param([string]$RelativePath)

    $safeRelativePath = ConvertTo-PrivateMarkerDiagnosticText $RelativePath
    # Root 自体と leaf までの全 parent を確認し、途中の junction / symlink 経由で
    # explicit scan root 外の worktree content を読まない。
    try {
        $rootItem = Get-Item `
            -LiteralPath $canonicalRoot `
            -Force `
            -ErrorAction Stop
    }
    catch {
        throw 'Explicit scan root could not be inspected safely.'
    }
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Explicit scan root must not be a symlink or reparse point.'
    }
    if (-not $rootItem.PSIsContainer) {
        throw 'Explicit scan root must remain a directory.'
    }

    # path separatorはregexでなくliteral charとして分割し、timeout無しの
    # PowerShell `-split`をproduction pathへ持ち込まない。
    $components = @(
        $RelativePath.Split(
            [char[]]@([char]47),
            [System.StringSplitOptions]::None
        )
    )
    $currentPath = $canonicalRoot
    for ($componentIndex = 0; $componentIndex -lt $components.Count - 1; $componentIndex++) {
        Assert-PrivateMarkerScanDeadline
        $currentPath = Join-Path $currentPath $components[$componentIndex]
        try {
            $parentItem = Get-Item `
                -LiteralPath $currentPath `
                -Force `
                -ErrorAction Stop
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            # Parent ごと消えた tracked file は worktree content が無いため index のみ検査する。
            return $false
        }
        catch {
            throw "Tracked worktree parent path could not be inspected: $safeRelativePath."
        }
        if (($parentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Tracked worktree parent directory is a symlink or reparse point: $safeRelativePath."
        }
        if (-not $parentItem.PSIsContainer) {
            throw "Tracked worktree parent path is not a directory: $safeRelativePath."
        }
    }
    return $true
}

function Add-TextTarget {
    param(
        [string]$RelativePath,
        [string]$Source,
        [byte[]]$Bytes
    )

    $safeRelativePath = ConvertTo-PrivateMarkerDiagnosticText $RelativePath
    $safeSource = ConvertTo-PrivateMarkerDiagnosticText $Source
    if ($Bytes.Length -gt $maximumTextBytes) {
        throw "Text scan target exceeds the per-file byte limit: $safeRelativePath ($safeSource)."
    }
    $script:totalTextBytes += $Bytes.Length
    if ($script:totalTextBytes -gt $maximumTotalTextBytes) {
        throw 'Private marker scan exceeded its total text byte limit.'
    }
    if ([Array]::IndexOf($Bytes, [byte]0) -ge 0) {
        throw "Text scan target contains a NUL byte: $safeRelativePath ($safeSource)."
    }
    $content = ConvertFrom-PrivateMarkerUtf8Bytes `
        -Bytes $Bytes `
        -Context "$safeRelativePath ($safeSource)"
    $scanTargets.Add([pscustomobject]@{
        File = $safeRelativePath
        Source = $safeSource
        Content = $content
    }) | Out-Null
}

function Read-StableWorktreeBytes {
    param(
        [string]$FullPath,
        [string]$RelativePath
    )

    $safeRelativePath = ConvertTo-PrivateMarkerDiagnosticText $RelativePath
    if (-not (Test-SafeWorktreeParentChain -RelativePath $RelativePath)) {
        throw "Tracked worktree parent path disappeared before bounded read: $safeRelativePath."
    }
    try {
        $itemBefore = Get-Item `
            -LiteralPath $FullPath `
            -Force `
            -ErrorAction Stop
    }
    catch {
        throw "Tracked worktree path could not be inspected: $safeRelativePath."
    }
    if (($itemBefore.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Tracked worktree path is a symlink or reparse point: $safeRelativePath."
    }
    if ($itemBefore.PSIsContainer) {
        throw "Tracked worktree path is not a regular file: $safeRelativePath."
    }
    if ($itemBefore.Length -gt $maximumTextBytes) {
        throw "Tracked worktree file exceeds the per-file byte limit: $safeRelativePath."
    }

    try {
        $stream = New-Object System.IO.FileStream(
            $FullPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
    }
    catch {
        throw "Tracked worktree file could not be opened: $safeRelativePath."
    }
    try {
        if ($stream.Length -gt $maximumTextBytes) {
            throw "Tracked worktree file grew beyond the per-file byte limit: $safeRelativePath."
        }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            Assert-PrivateMarkerScanDeadline
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                throw "Tracked worktree file ended during bounded read: $safeRelativePath."
            }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) {
            throw "Tracked worktree file changed during bounded read: $safeRelativePath."
        }

        # Handle を保持したまま path chain と leaf を再確認し、読取り直後の差替え窓を閉じる。
        if (-not (Test-SafeWorktreeParentChain -RelativePath $RelativePath)) {
            throw "Tracked worktree parent path changed while it was scanned: $safeRelativePath."
        }
        try {
            $itemAfter = Get-Item `
                -LiteralPath $FullPath `
                -Force `
                -ErrorAction Stop
        }
        catch {
            throw "Tracked worktree path disappeared after bounded read: $safeRelativePath."
        }
        if (($itemAfter.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $itemAfter.PSIsContainer -or
            $itemAfter.Length -ne $itemBefore.Length -or
            $itemAfter.LastWriteTimeUtc.Ticks -ne $itemBefore.LastWriteTimeUtc.Ticks) {
            throw "Tracked worktree file changed while it was scanned: $safeRelativePath."
        }
    }
    finally {
        $stream.Dispose()
    }
    return ,$bytes
}

function Get-SafeFallbackFiles {
    $files = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    try {
        $fallbackRoot = Get-Item `
            -LiteralPath $canonicalRoot `
            -Force `
            -ErrorAction Stop
    }
    catch {
        throw 'Working-tree fallback root could not be inspected safely.'
    }
    $pending.Push($fallbackRoot)
    $visitedEntries = 0
    while ($pending.Count -gt 0) {
        Assert-PrivateMarkerScanDeadline
        $directory = $pending.Pop()
        try {
            $remainingEntryCapacity =
                ($maximumTrackedEntries - $visitedEntries) + 1
            $directoryEntries = @(
                Get-ChildItem `
                    -LiteralPath $directory.FullName `
                    -Force `
                    -ErrorAction Stop |
                    Select-Object -First $remainingEntryCapacity
            )
        }
        catch {
            throw 'Working-tree fallback could not enumerate a directory safely.'
        }
        foreach ($item in $directoryEntries) {
            Assert-PrivateMarkerScanDeadline
            $visitedEntries++
            if ($visitedEntries -gt $maximumTrackedEntries) {
                throw 'Working-tree fallback exceeded its entry limit.'
            }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Working-tree fallback encountered a symlink or reparse point.'
            }
            # `.git` は directory だけでなく gitfile 形式の leaf も列挙対象外にする。
            if ([string]::Equals($item.Name, '.git', $pathComparison)) {
                continue
            }
            if ($item.PSIsContainer) {
                if ($item.Name -notin @('node_modules', '.cache')) {
                    $pending.Push($item)
                }
                continue
            }
            if ($item.Name -ne '.private-markers.local' -and
                (Test-IsTextFile $item.FullName)) {
                $files.Add($item) | Out-Null
            }
        }
    }
    return $files.ToArray()
}

# Empty directory でも root reparse を見逃さないよう、列挙や local marker 読取りより先に固定する。
[void](Test-SafeWorktreeParentChain -RelativePath '.')

try {
    $hasLocalMarker = Test-Path `
        -LiteralPath $localMarkerFile `
        -ErrorAction Stop
}
catch {
    throw 'Local private marker path could not be inspected safely.'
}
if ($hasLocalMarker) {
    try {
        $localMarkerItem = Get-Item `
            -LiteralPath $localMarkerFile `
            -Force `
            -ErrorAction Stop
    }
    catch {
        throw 'Local private marker file could not be inspected safely.'
    }
    if (($localMarkerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $localMarkerItem.PSIsContainer) {
        throw 'Local private marker file must be a regular local file.'
    }
    $localMarkerBytes = Read-StableWorktreeBytes `
        -FullPath $localMarkerFile `
        -RelativePath '.private-markers.local'
    $localMarkerText = ConvertFrom-PrivateMarkerUtf8Bytes `
        -Bytes $localMarkerBytes `
        -Context '.private-markers.local'
    Invoke-BoundedLineAction `
        -Content $localMarkerText `
        -Context '.private-markers.local' `
        -Action {
            param($line, $lineNumber)
            Add-LocalMarker -Marker $line
        }
}
$environmentMarkers = [Environment]::GetEnvironmentVariable(
    'CLAUDE_CODE_DEVLOG_HOOKS_PRIVATE_MARKERS'
)
if (-not [string]::IsNullOrWhiteSpace($environmentMarkers)) {
    Invoke-BoundedLineAction `
        -Content $environmentMarkers `
        -Context 'CLAUDE_CODE_DEVLOG_HOOKS_PRIVATE_MARKERS' `
        -Action {
            param($line, $lineNumber)
            Add-LocalMarker -Marker $line
        }
}

$verifyGitIndexAtScanEnd = $false
$initialGitIndexBytes = $null
$initialGitIndexDebugBytes = $null
try {
    $gitExe = @(
        Get-Command `
            git `
            -CommandType Application `
            -ErrorAction SilentlyContinue
    ) | Select-Object -First 1
}
catch {
    Stop-PrivateMarkerProcessBoundaryFailure
}
if ($null -eq $gitExe) {
    if (Test-GitMarkerInAncestry) {
        Stop-PrivateMarkerProcessBoundaryFailure
    }
    $scanMode = 'working-tree'
    foreach ($file in Get-SafeFallbackFiles) {
        $relative = $file.FullName.Substring($canonicalRoot.Length)
        $relative = $relative.TrimStart([char]92, [char]47)
        $relative = $relative.Replace([string][char]92, '/')
        Add-TextTarget `
            -RelativePath $relative `
            -Source 'working-tree' `
            -Bytes (Read-StableWorktreeBytes -FullPath $file.FullName -RelativePath $relative)
    }
} else {
    $environmentBeforeGit = Get-ProcessEnvironmentSnapshot
    $changedEnvironmentNames = @()
    $gitIsolationRoot = $null
    try {
        $gitIsolationRoot = Join-Path `
            ([System.IO.Path]::GetTempPath()) `
            ("claude-code-devlog-hooks-git-" +
                [System.Guid]::NewGuid().ToString('N')) `
            -ErrorAction Stop
        if ($ProcessBoundaryFailureProbe -eq 'isolation-create') {
            throw 'Synthetic isolation creation failure.'
        }
        New-Item `
            -ItemType Directory `
            -Path $gitIsolationRoot `
            -ErrorAction Stop |
            Out-Null
    }
    catch {
        Stop-PrivateMarkerProcessBoundaryFailure
    }
    $gitPreparationRegexTimedOut = $false
    try {
        $rootProbe = Invoke-ScannerGit `
            -Arguments @('-C', $canonicalRoot, 'rev-parse', '--show-toplevel') `
            -MaximumStandardOutputBytes 65536
        Assert-HealthyGitBoundary `
            -Result $rootProbe `
            -Context 'Git root probe' `
            -AllowNonzeroExit

        if ($rootProbe.ExitCode -ne 0) {
            try {
                $rootError = ConvertFrom-PrivateMarkerUtf8Bytes `
                    -Bytes $rootProbe.StandardErrorBytes `
                    -Context 'Git root probe stderr'
                $explicitNotRepository = $rootProbe.ExitCode -eq 128 -and
                    -not (Test-GitMarkerInAncestry) -and
                    $gitNotRepositoryErrorMatcher.IsMatch($rootError)
            }
            catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
                # outer catchへ型を保って返し、isolation cleanup後にだけ
                # 単一の固定diagnosticをemitする。
                throw
            }
            catch {
                Stop-PrivateMarkerProcessBoundaryFailure
            }
            if (-not $explicitNotRepository) {
                Stop-PrivateMarkerProcessBoundaryFailure
            }

            $scanMode = 'working-tree'
            foreach ($file in Get-SafeFallbackFiles) {
                $relative = $file.FullName.Substring($canonicalRoot.Length)
                $relative = $relative.TrimStart([char]92, [char]47)
                $relative = $relative.Replace([string][char]92, '/')
                Add-TextTarget `
                    -RelativePath $relative `
                    -Source 'working-tree' `
                    -Bytes (Read-StableWorktreeBytes -FullPath $file.FullName -RelativePath $relative)
            }
        } else {
            try {
                $reportedRootText = ConvertFrom-PrivateMarkerUtf8Bytes `
                    -Bytes $rootProbe.StandardOutputBytes `
                    -Context 'Git root probe stdout'
            }
            catch {
                Stop-PrivateMarkerProcessBoundaryFailure
            }
            $reportedRootLines = @(
                $reportedRootText.Split(
                    [char[]]@([char]13, [char]10),
                    [System.StringSplitOptions]::RemoveEmptyEntries
                ) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            if ($reportedRootLines.Count -ne 1) {
                Stop-PrivateMarkerProcessBoundaryFailure
            }
            try {
                $reportedRoot = [System.IO.Path]::GetFullPath(
                    $reportedRootLines[0]
                ).TrimEnd([char]92, [char]47)
            }
            catch {
                Stop-PrivateMarkerProcessBoundaryFailure
            }
            if (-not [string]::Equals(
                $canonicalRoot,
                $reportedRoot,
                $pathComparison
            )) {
                throw 'Scan path must be the exact Git worktree root; subdirectories are rejected.'
            }

            $indexProbe = Invoke-ScannerGit `
                -Arguments $gitIndexArguments `
                -MaximumStandardOutputBytes $maximumGitListBytes
            Assert-HealthyGitBoundary -Result $indexProbe -Context 'Git index enumeration'
            $indexText = ConvertFrom-PrivateMarkerUtf8Bytes `
                -Bytes $indexProbe.StandardOutputBytes `
                -Context 'Git index enumeration'
            if ($indexText.Length -gt 0 -and -not $indexText.EndsWith("`0")) {
                throw 'Git index enumeration returned an unterminated record.'
            }

            # ls-files --stage は intent-to-add を empty blob として表示するため、
            # worktree 対 index の raw 差分も厳密に解析して zero-stage entry を拒否する。
            $rawDiffProbe = Invoke-ScannerGit `
                -Arguments @(
                    '-C',
                    $canonicalRoot,
                    'diff',
                    '--raw',
                    '-z',
                    '--no-abbrev',
                    '--no-ext-diff',
                    '--no-textconv',
                    '--'
                ) `
                -MaximumStandardOutputBytes $maximumGitListBytes
            Assert-HealthyGitBoundary -Result $rawDiffProbe -Context 'Git worktree/index diff'
            $rawDiffText = ConvertFrom-PrivateMarkerUtf8Bytes `
                -Bytes $rawDiffProbe.StandardOutputBytes `
                -Context 'Git worktree/index diff'
            if ($rawDiffText.Length -gt 0 -and -not $rawDiffText.EndsWith("`0")) {
                throw 'Git worktree/index diff returned an unterminated record.'
            }
            $rawDiffParts = @(
                if ($rawDiffText.Length -gt 0) {
                    $rawDiffText.Substring(
                        0,
                        $rawDiffText.Length - 1
                    ).Split(
                        [char[]]@([char]0),
                        [System.StringSplitOptions]::None
                    )
                }
            )
            $rawIndex = 0
            while ($rawIndex -lt $rawDiffParts.Count) {
                $header =
                    $gitRawDiffHeaderMatcher.Match($rawDiffParts[$rawIndex])
                if (-not $header.Success) {
                    throw 'Git worktree/index diff returned a malformed header.'
                }
                $rawIndex++
                $pathCount = if ($header.Groups['status'].Value -in @('R', 'C')) {
                    2
                } else {
                    1
                }
                if ($rawIndex + $pathCount -gt $rawDiffParts.Count) {
                    throw 'Git worktree/index diff omitted a path record.'
                }
                for ($pathIndex = 0; $pathIndex -lt $pathCount; $pathIndex++) {
                    if ([string]::IsNullOrEmpty($rawDiffParts[$rawIndex + $pathIndex])) {
                        throw 'Git worktree/index diff returned an empty path.'
                    }
                }
                if ($header.Groups['oldMode'].Value -eq '000000' -and
                    $header.Groups['status'].Value -eq 'A') {
                    throw 'Git index contains an intent-to-add entry.'
                }
                $rawIndex += $pathCount
            }

            $records = @(
                if ($indexText.Length -gt 0) {
                    $indexText.Substring(
                        0,
                        $indexText.Length - 1
                    ).Split(
                        [char[]]@([char]0),
                        [System.StringSplitOptions]::None
                    )
                }
            )
            if ($records.Count -gt $maximumTrackedEntries) {
                throw 'Git index enumeration exceeded its entry limit.'
            }

            # `ls-files --stage` のOIDだけでは、通常のempty blobと
            # CE_INTENT_TO_ADD付きempty blobを区別できない。debug streamの
            # header順序をstage列挙と照合し、extended flagを直接検査する。
            $indexDebugProbe = Invoke-ScannerGit `
                -Arguments $gitIndexDebugArguments `
                -MaximumStandardOutputBytes $maximumGitDebugBytes
            Assert-HealthyGitBoundary `
                -Result $indexDebugProbe `
                -Context 'Git index metadata enumeration'
            $indexDebugText = ConvertFrom-PrivateMarkerUtf8Bytes `
                -Bytes $indexDebugProbe.StandardOutputBytes `
                -Context 'Git index metadata enumeration'
            $debugBlockPattern = New-PrivateMarkerBoundedRegex `
                -Pattern (
                    '\G  ctime: [0-9]{1,20}:[0-9]{1,10}\n' +
                    '  mtime: [0-9]{1,20}:[0-9]{1,10}\n' +
                    '  dev: [0-9]{1,20}\tino: [0-9]{1,20}\n' +
                    '  uid: [0-9]{1,20}\tgid: [0-9]{1,20}\n' +
                    '  size: [0-9]{1,20}\tflags: (?<flags>[0-9a-fA-F]{1,16})\n'
                ) `
                -Options (
                    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
                )
            $debugOffset = 0
            foreach ($record in $records) {
                $expectedPrefix = "$record`0"
                if (($debugOffset + $expectedPrefix.Length) -gt
                        $indexDebugText.Length -or
                    [string]::CompareOrdinal(
                        $indexDebugText,
                        $debugOffset,
                        $expectedPrefix,
                        0,
                        $expectedPrefix.Length
                    ) -ne 0) {
                    throw 'Git index metadata did not match the staged entry order.'
                }
                $debugOffset += $expectedPrefix.Length
                try {
                    $debugMatch = $debugBlockPattern.Match(
                        $indexDebugText,
                        $debugOffset
                    )
                }
                catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
                    throw
                }
                if (-not $debugMatch.Success) {
                    throw 'Git index metadata returned a malformed debug block.'
                }
                $debugFlags = [uint64]0
                if (-not [uint64]::TryParse(
                    $debugMatch.Groups['flags'].Value,
                    [System.Globalization.NumberStyles]::HexNumber,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$debugFlags
                )) {
                    throw 'Git index metadata returned invalid flags.'
                }
                if (($debugFlags -band [uint64]0x20000000) -ne 0) {
                    $tabOffset = $record.IndexOf([char]9)
                    $intentPath = if ($tabOffset -ge 0) {
                        $record.Substring($tabOffset + 1)
                    } else {
                        '<malformed>'
                    }
                    $safeIntentPath =
                        ConvertTo-PrivateMarkerDiagnosticText $intentPath
                    throw "Git index contains an intent-to-add entry: $safeIntentPath."
                }
                $debugOffset = $debugMatch.Index + $debugMatch.Length
            }
            if ($debugOffset -ne $indexDebugText.Length) {
                throw 'Git index metadata returned trailing bytes.'
            }

            $pathComparer = if (Test-PrivateMarkerWindowsHost) {
                [System.StringComparer]::OrdinalIgnoreCase
            } else {
                [System.StringComparer]::Ordinal
            }
            $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
                $pathComparer
            )
            $indexEntries = New-Object System.Collections.Generic.List[object]
            foreach ($record in $records) {
                Assert-PrivateMarkerScanDeadline
                $parsed = $gitIndexEntryMatcher.Match($record)
                if (-not $parsed.Success) {
                    throw 'Git index enumeration returned a malformed record.'
                }
                $mode = $parsed.Groups['mode'].Value
                $oid = $parsed.Groups['oid'].Value.ToLowerInvariant()
                $stage = $parsed.Groups['stage'].Value
                $relative = $parsed.Groups['path'].Value
                $safeRelative =
                    ConvertTo-PrivateMarkerDiagnosticText $relative
                if ($stage -ne '0') {
                    throw "Git index contains an unresolved conflict: $safeRelative."
                }
                if ($mode -notin @('100644', '100755')) {
                    throw "Git index contains a symlink, gitlink, or unsupported mode: $safeRelative."
                }
                if ($allZeroOidMatcher.IsMatch($oid)) {
                    throw "Git index contains an intent-to-add entry: $safeRelative."
                }
                if ([string]::IsNullOrWhiteSpace($relative) -or
                    $controlCharacterMatcher.IsMatch($relative) -or
                    [System.IO.Path]::IsPathRooted($relative) -or
                    -not $seenPaths.Add($relative)) {
                    throw 'Git index contains an unsafe or duplicate path.'
                }
                if ([string]::Equals(
                    $relative,
                    '.private-markers.local',
                    $pathComparison
                )) {
                    throw 'The local private marker file must remain untracked.'
                }

                try {
                    $fullPath = [System.IO.Path]::GetFullPath(
                        (Join-Path $canonicalRoot $relative)
                    )
                }
                catch {
                    throw 'Git index contains a path that cannot be canonicalized.'
                }
                if (-not $fullPath.StartsWith($rootPrefix, $pathComparison)) {
                    throw 'Git index path escaped the explicit scan root.'
                }

                $worktreeItem = $null
                if (Test-SafeWorktreeParentChain -RelativePath $relative) {
                    try {
                        $worktreeItem = Get-Item `
                            -LiteralPath $fullPath `
                            -Force `
                            -ErrorAction Stop
                    }
                    catch [System.Management.Automation.ItemNotFoundException] {
                        # leaf が無い場合も staged index blob は後段で検査する。
                        $worktreeItem = $null
                    }
                    catch {
                        throw "Tracked worktree path could not be inspected: $safeRelative."
                    }
                }
                if ($null -ne $worktreeItem -and
                    (($worktreeItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                        $worktreeItem.PSIsContainer)) {
                    throw "Tracked worktree path is not a regular local file: $safeRelative."
                }

                if (-not (Test-IsTextFile $relative)) {
                    continue
                }

                $indexEntries.Add([pscustomobject]@{
                    Oid = $oid
                    RelativePath = $relative
                    DiagnosticPath = $safeRelative
                    FullPath = $fullPath
                    WorktreeItem = $worktreeItem
                }) | Out-Null
            }

            # text candidate の unique blob を1回の binary-safe batch で読む。
            # suspended process 境界を OID ごとに起動せず、process 数と runtime を一定に保つ。
            $blobCache = @{}
            $blobOids = New-Object System.Collections.Generic.List[string]
            $blobOidSet = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal
            )
            foreach ($entry in $indexEntries) {
                Assert-PrivateMarkerScanDeadline
                if ($blobOidSet.Add($entry.Oid)) {
                    $blobOids.Add($entry.Oid) | Out-Null
                }
            }
            if ($blobOids.Count -gt 0) {
                $batchInputBytes = [System.Text.Encoding]::ASCII.GetBytes(
                    (($blobOids -join "`n") + "`n")
                )
                $batchOutputLimit = [int](
                    $maximumTotalTextBytes + ($blobOids.Count * 160) + 1
                )
                $batchProbe = Invoke-ScannerGit `
                    -Arguments @(
                        '-C',
                        $canonicalRoot,
                        'cat-file',
                        '--batch'
                    ) `
                    -MaximumStandardOutputBytes $batchOutputLimit `
                    -StandardInputBytes $batchInputBytes
                Assert-HealthyGitBoundary `
                    -Result $batchProbe `
                    -Context 'Git index blob batch read'

                $batchOffset = 0
                $batchBlobTotal = 0L
                foreach ($expectedOid in $blobOids) {
                    Assert-PrivateMarkerScanDeadline
                    $headerEnd = -1
                    $headerSearchLimit = [Math]::Min(
                        $batchProbe.StandardOutputBytes.Length,
                        $batchOffset + 256
                    )
                    for ($offset = $batchOffset;
                        $offset -lt $headerSearchLimit;
                        $offset++) {
                        if ($batchProbe.StandardOutputBytes[$offset] -eq 10) {
                            $headerEnd = $offset
                            break
                        }
                    }
                    if ($headerEnd -lt 0) {
                        throw 'Git index blob batch returned a malformed header.'
                    }
                    for ($offset = $batchOffset;
                        $offset -lt $headerEnd;
                        $offset++) {
                        if ($batchProbe.StandardOutputBytes[$offset] -gt 127) {
                            throw 'Git index blob batch returned a non-ASCII header.'
                        }
                    }
                    $batchHeader = [System.Text.Encoding]::ASCII.GetString(
                        $batchProbe.StandardOutputBytes,
                        $batchOffset,
                        $headerEnd - $batchOffset
                    )
                    $batchHeaderMatch =
                        $gitBatchHeaderMatcher.Match($batchHeader)
                    if (-not $batchHeaderMatch.Success -or
                        -not $batchHeaderMatch.Groups['oid'].Value.Equals(
                            $expectedOid,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )) {
                        throw 'Git index blob batch returned an unexpected object.'
                    }
                    $blobSize = 0L
                    if (-not [long]::TryParse(
                        $batchHeaderMatch.Groups['size'].Value,
                        [System.Globalization.NumberStyles]::None,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [ref]$blobSize
                    ) -or
                        $blobSize -gt $maximumTextBytes) {
                        throw 'Git index blob size is invalid or exceeds the limit.'
                    }
                    $batchBlobTotal += $blobSize
                    if ($batchBlobTotal -gt $maximumTotalTextBytes) {
                        throw 'Git index blobs exceeded the total text byte limit.'
                    }

                    $blobStart = $headerEnd + 1
                    $blobEnd = $blobStart + [int]$blobSize
                    if ($blobEnd -ge $batchProbe.StandardOutputBytes.Length -or
                        $batchProbe.StandardOutputBytes[$blobEnd] -ne 10) {
                        throw 'Git index blob batch returned an invalid byte boundary.'
                    }
                    $indexBytes = New-Object byte[] ([int]$blobSize)
                    if ($blobSize -gt 0) {
                        [Array]::Copy(
                            $batchProbe.StandardOutputBytes,
                            $blobStart,
                            $indexBytes,
                            0,
                            [int]$blobSize
                        )
                    }
                    $blobCache[$expectedOid] = [pscustomobject]@{
                        Bytes = $indexBytes
                    }
                    $batchOffset = [int]($blobEnd + 1)
                }
                if ($batchOffset -ne $batchProbe.StandardOutputBytes.Length) {
                    throw 'Git index blob batch returned trailing bytes.'
                }
            }

            foreach ($entry in $indexEntries) {
                Assert-PrivateMarkerScanDeadline
                if (-not $blobCache.ContainsKey($entry.Oid)) {
                    throw "Git index blob batch omitted an object: $($entry.DiagnosticPath)."
                }
                $indexBytes = [byte[]]$blobCache[$entry.Oid].Bytes
                Add-TextTarget `
                    -RelativePath $entry.RelativePath `
                    -Source 'index' `
                    -Bytes $indexBytes

                if ($null -ne $entry.WorktreeItem) {
                    $worktreeBytes = Read-StableWorktreeBytes `
                        -FullPath $entry.FullPath `
                        -RelativePath $entry.RelativePath
                    if (-not (Test-ByteArraysEqual -Left $indexBytes -Right $worktreeBytes)) {
                        Add-TextTarget `
                            -RelativePath $entry.RelativePath `
                            -Source 'working-tree' `
                            -Bytes $worktreeBytes
                    }
                }
            }

            $initialGitIndexBytes = [byte[]]$indexProbe.StandardOutputBytes
            $initialGitIndexDebugBytes =
                [byte[]]$indexDebugProbe.StandardOutputBytes
            $verifyGitIndexAtScanEnd = $true
            $scanMode = 'git-tracked'
        }
    }
    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
        # finallyより前には出力しない。cleanup失敗と競合しても固定行を
        # 2本emitせず、cleanup成功後にregex-timeout 1行だけを返す。
        $gitPreparationRegexTimedOut = $true
    }
    finally {
        $changedEnvironmentNames = @(
            Get-ChangedEnvironmentVariableNames -Expected $environmentBeforeGit
        )
        if (-not $verifyGitIndexAtScanEnd) {
            Remove-PrivateMarkerGitIsolationRoot `
                -IsolationRoot $gitIsolationRoot
        }
    }
    if ($changedEnvironmentNames.Count -gt 0) {
        if ($verifyGitIndexAtScanEnd) {
            Remove-PrivateMarkerGitIsolationRoot `
                -IsolationRoot $gitIsolationRoot
        }
        throw "Hermetic Git boundary changed scanner environment variables: $($changedEnvironmentNames -join ', ')."
    }
    if ($gitPreparationRegexTimedOut) {
        Stop-PrivateMarkerRegexTimeout
    }
}

$finalGitEnvironmentChanges = @()
$finalRegexTimedOut = $false
try {
    foreach ($target in $scanTargets) {
        Assert-PrivateMarkerScanDeadline
        Invoke-BoundedLineAction `
            -Content $target.Content `
            -Context "$($target.File) ($($target.Source))" `
            -Action {
                param($line, $lineNumber)

                try {
                    # 同一行の URL は bounded NextMatch で探索し、ruleごとの
                    # finding は1件に畳む。全regex操作を同じtimeout catchへ収める。
                    $urlMatchCount = 0
                    $urlMatch = $githubUrlMatcher.Match($line)
                    while ($urlMatch.Success) {
                        Assert-PrivateMarkerScanDeadline
                        $urlMatchCount++
                        if ($urlMatchCount -gt $maximumMatchesPerRulePerLine) {
                            throw 'Private marker scan exceeded its per-line URL match limit.'
                        }
                        if (-not $allowedRepoUrlMatcher.IsMatch($urlMatch.Value)) {
                            Add-BoundedFinding `
                                -File $target.File `
                                -Source $target.Source `
                                -Line $lineNumber `
                                -Rule 'non-allowlisted-github-repo-url'
                            break
                        }
                        Assert-PrivateMarkerScanDeadline
                        $urlMatch = $urlMatch.NextMatch()
                    }

                    foreach ($rule in $rules) {
                        Assert-PrivateMarkerScanDeadline
                        $matched = $false
                        if ($rule.Kind -eq 'literal') {
                            $matched = $line.Contains($rule.Pattern)
                        } elseif ($null -eq $rule.AllowlistMatcher) {
                            $matched = $rule.Matcher.IsMatch($line)
                        } else {
                            # Allowlist付き regex も全match配列を作らず、
                            # 上限内で先頭から判定する。
                            $ruleMatchCount = 0
                            $ruleMatch = $rule.Matcher.Match($line)
                            while ($ruleMatch.Success) {
                                Assert-PrivateMarkerScanDeadline
                                $ruleMatchCount++
                                if ($ruleMatchCount -gt
                                        $maximumMatchesPerRulePerLine) {
                                    throw 'Private marker scan exceeded its per-line rule match limit.'
                                }
                                if (-not $rule.AllowlistMatcher.IsMatch(
                                        $ruleMatch.Value
                                    )) {
                                    $matched = $true
                                    break
                                }
                                Assert-PrivateMarkerScanDeadline
                                $ruleMatch = $ruleMatch.NextMatch()
                            }
                        }

                        if ($matched) {
                            Add-BoundedFinding `
                                -File $target.File `
                                -Source $target.Source `
                                -Line $lineNumber `
                                -Rule $rule.Name
                        }
                    }
                }
                catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
                    throw
                }
            }
    }

    if ($verifyGitIndexAtScanEnd) {
        # marker 解析が完了した成功判定直前に、開始時と同じ raw stage
        # listing を再取得し、解析中の追加・差替えも成功結果へ混入させない。
        $indexVerifyProbe = Invoke-ScannerGit `
            -Arguments $gitIndexArguments `
            -MaximumStandardOutputBytes $maximumGitListBytes
        Assert-HealthyGitBoundary `
            -Result $indexVerifyProbe `
            -Context 'Git index verification'
        if (-not (Test-ByteArraysEqual `
                -Left $initialGitIndexBytes `
                -Right $indexVerifyProbe.StandardOutputBytes)) {
            throw 'Git index changed during the private marker scan.'
        }
        $indexDebugVerifyProbe = Invoke-ScannerGit `
            -Arguments $gitIndexDebugArguments `
            -MaximumStandardOutputBytes $maximumGitDebugBytes
        Assert-HealthyGitBoundary `
            -Result $indexDebugVerifyProbe `
            -Context 'Git index metadata verification'
        if (-not (Test-ByteArraysEqual `
                -Left $initialGitIndexDebugBytes `
                -Right $indexDebugVerifyProbe.StandardOutputBytes)) {
            throw 'Git index metadata changed during the private marker scan.'
        }
    }
}
catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
    # Git isolation cleanupが完了するまでdiagnosticを遅延し、同時cleanup failure
    # のprocess-boundary診断と二重出力しない。
    $finalRegexTimedOut = $true
}
finally {
    if ($verifyGitIndexAtScanEnd) {
        $finalGitEnvironmentChanges = @(
            Get-ChangedEnvironmentVariableNames -Expected $environmentBeforeGit
        )
        Remove-PrivateMarkerGitIsolationRoot `
            -IsolationRoot $gitIsolationRoot
    }
}
if ($finalGitEnvironmentChanges.Count -gt 0) {
    throw "Hermetic Git boundary changed scanner environment variables: $($finalGitEnvironmentChanges -join ', ')."
}
if ($finalRegexTimedOut) {
    Stop-PrivateMarkerRegexTimeout
}

if ($findings.Count -gt 0) {
    # prefix/header/rowを明示LFの単一payloadへ積み、actual UTF-8 byte数で
    # 上限判定してから一度だけ出す。platform newline差とpartial tableを防ぐ。
    $outputBuilder = New-Object System.Text.StringBuilder
    $outputPrefix = "Private marker scan failed (scan target: $scanMode):"
    $outputHeader = "File`tSource`tLine`tRule`tMatch"
    [void]$outputBuilder.Append($outputPrefix)
    [void]$outputBuilder.Append([char]10)
    [void]$outputBuilder.Append($outputHeader)
    [void]$outputBuilder.Append([char]10)
    $outputByteCount = (
        [System.Text.Encoding]::UTF8.GetByteCount($outputPrefix) +
        1 +
        [System.Text.Encoding]::UTF8.GetByteCount($outputHeader) +
        1
    )
    foreach ($finding in $findings | Sort-Object File, Source, Line, Rule) {
        Assert-PrivateMarkerScanDeadline
        $outputLine = "{0}`t{1}`t{2}`t{3}`t{4}" -f @(
            $finding.File,
            $finding.Source,
            $finding.Line,
            $finding.Rule,
            $finding.Match
        )
        $outputByteCount += (
            [System.Text.Encoding]::UTF8.GetByteCount($outputLine) + 1
        )
        if ($outputByteCount -gt $maximumFindingOutputBytes) {
            Assert-PrivateMarkerScanDeadline
            Write-Host 'Private marker scan aborted: scan-diagnostic-output-limit'
            exit 1
        }
        [void]$outputBuilder.Append($outputLine)
        [void]$outputBuilder.Append([char]10)
    }
    [byte[]]$outputBytes = [System.Text.Encoding]::UTF8.GetBytes(
        $outputBuilder.ToString()
    )
    if ($outputBytes.Length -ne $outputByteCount -or
        $outputBytes.Length -gt $maximumFindingOutputBytes) {
        Assert-PrivateMarkerScanDeadline
        Write-Host 'Private marker scan aborted: scan-diagnostic-output-limit'
        exit 1
    }
    $standardOutput = [Console]::OpenStandardOutput()
    try {
        # serialize と stream取得の後、write直前に共通時計を再確認する。
        Assert-PrivateMarkerScanDeadline
        $standardOutput.Write($outputBytes, 0, $outputBytes.Length)
        $standardOutput.Flush()
    }
    finally {
        $standardOutput.Dispose()
    }
    exit 1
}

# clean 判定も emit 直前に再確認し、最終probe後の期限超過を成功にしない。
Assert-PrivateMarkerScanDeadline
Write-Host "Private marker scan passed (scan target: $scanMode)."
exit 0
