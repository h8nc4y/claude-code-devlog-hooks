# Shared, dependency-free input parser for the PowerShell hook entrypoints.
#
# Windows PowerShell 5.1 and PowerShell 7 intentionally use the same bounded
# byte reader and RFC 8259 parser. Runtime JSON conveniences are deliberately
# avoided because their accepted grammar, root scalarization, duplicate-name
# handling, and Unicode case behavior differ between the two runtimes.

$script:DevlogMaximumInputBytes = 1048576
$script:DevlogMaximumJsonDepth = 128
$script:DevlogMaximumJsonValues = 4096
$script:DevlogMaximumJsonNumberCharacters = 1024
$script:DevlogMaximumPropertyNameScalars = 256
$script:DevlogMaximumSessionIdCharacters = 64

function Get-DevlogAsciiFoldedName {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)

    # Only ASCII A-Z are folded. Non-ASCII pairs such as U+00C4/U+00E4 stay
    # distinct, so property identity does not depend on the host locale.
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Name.ToCharArray()) {
        $code = [int]$character
        if ($code -ge 0x41 -and $code -le 0x5A) {
            [void]$builder.Append([char]($code + 0x20))
        } else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-DevlogUnicodeScalarCount {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $count = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ([char]::IsHighSurrogate($character)) {
            if (($index + 1) -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$index + 1])) {
                throw 'Invalid Unicode scalar sequence.'
            }
            $index++
        } elseif ([char]::IsLowSurrogate($character)) {
            throw 'Invalid Unicode scalar sequence.'
        }
        $count++
    }
    return $count
}

function Get-DevlogMarkerFileName {
    param([Parameter(Mandatory = $true)][string]$SessionId)

    # Windows compares ordinary filenames case-insensitively and reserves
    # names such as CON and NUL. Encode every accepted ASCII byte as lowercase
    # hex, then use a namespace prefix that the legacy raw/sanitized scheme
    # could never emit. The mapping is injective and portable across filesystems.
    if ($SessionId -cnotmatch ('\A[A-Za-z0-9_.-]{1,' + $script:DevlogMaximumSessionIdCharacters + '}\z')) {
        throw 'Invalid session id for marker encoding.'
    }
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in [System.Text.Encoding]::ASCII.GetBytes($SessionId)) {
        [void]$builder.Append($byte.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture))
    }
    return ('~sid-' + $builder.ToString() + '.start')
}

function Get-DevlogFileSystemState {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        # File.GetAttributes maps to a final-entry attribute query on Windows;
        # unlike provider lookup, it does not enumerate or normalize through a
        # reparse target before exposing the ReparsePoint flag.
        return [pscustomobject]@{
            Exists = $true
            Error = $false
            Attributes = [System.IO.File]::GetAttributes($Path)
        }
    } catch [System.IO.FileNotFoundException] {
        return [pscustomobject]@{ Exists = $false; Error = $false; Attributes = 0 }
    } catch [System.IO.DirectoryNotFoundException] {
        return [pscustomobject]@{ Exists = $false; Error = $false; Attributes = 0 }
    } catch {
        # Access, malformed-path, and other I/O failures are unjudgeable rather
        # than equivalent to a missing entry that may safely be created.
        return [pscustomobject]@{ Exists = $false; Error = $true; Attributes = 0 }
    }
}

function Test-DevlogMarkerDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    # The configured root is the trust anchor, but its marker child must be a
    # real directory. Resolving a reparse target would cross that boundary.
    $state = Get-DevlogFileSystemState -Path $Path
    if ($state.Error -or -not $state.Exists) { return $false }
    if (($state.Attributes -band [System.IO.FileAttributes]::Directory) -eq 0) { return $false }
    return (($state.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
}

function Test-DevlogMarkerLeaf {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowMissing
    )

    $state = Get-DevlogFileSystemState -Path $Path
    if ($state.Error) { return $false }
    if (-not $state.Exists) { return [bool]$AllowMissing }
    if (($state.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { return $false }
    return (($state.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
}

function Initialize-DevlogMarkerDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $existing = Get-DevlogFileSystemState -Path $Path
        if ($existing.Error) { return $false }
        if ($existing.Exists) {
            return (Test-DevlogMarkerDirectory -Path $Path)
        }
        [void][System.IO.Directory]::CreateDirectory($Path)
        return (Test-DevlogMarkerDirectory -Path $Path)
    } catch {
        return $false
    }
}

function Write-DevlogMarkerEpoch {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int64]$Epoch
    )

    $stream = $null
    try {
        $directory = [System.IO.Path]::GetDirectoryName($Path)
        if ([string]::IsNullOrWhiteSpace($directory) -or
            -not (Test-DevlogMarkerDirectory -Path $directory)) { return $false }

        # Never truncate an existing entry. Removing the local name first keeps
        # another hard-link name unchanged; CreateNew refuses a raced symlink.
        $existing = Get-DevlogFileSystemState -Path $Path
        if ($existing.Error) { return $false }
        if ($existing.Exists) {
            if (-not (Test-DevlogMarkerLeaf -Path $Path)) { return $false }
            [System.IO.File]::Delete($Path)
        }
        if (-not (Test-DevlogMarkerDirectory -Path $directory) -or
            -not (Test-DevlogMarkerLeaf -Path $Path -AllowMissing)) { return $false }

        $text = $Epoch.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        if ($text -cnotmatch '\A[1-9][0-9]{0,17}\z') { return $false }
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($text)
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $stream.Dispose()
        $stream = $null

        return [bool]((Test-DevlogMarkerDirectory -Path $directory) -and
            (Test-DevlogMarkerLeaf -Path $Path))
    } catch {
        return $false
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertFrom-DevlogHookInput {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$RawInput)

    # Mutable parser state keeps recursive helpers PS 5.1-compatible without
    # reflecting malformed input in an exception or diagnostic.
    $state = @{
        Text = $RawInput
        Length = $RawInput.Length
        Index = 0
        HasSessionProperty = $false
        SessionValue = $null
        HasStopProperty = $false
        StopValue = $null
        ValueCount = 0
        ExactNames = (New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal))
        FoldedNames = (New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal))
    }

    function Skip-DevlogJsonWhitespace {
        while ($state.Index -lt $state.Length) {
            $code = [int]$state.Text[$state.Index]
            if ($code -ne 0x20 -and $code -ne 0x09 -and $code -ne 0x0A -and $code -ne 0x0D) {
                break
            }
            $state.Index++
        }
    }

    function Get-DevlogHexDigit {
        param([char]$Character)

        $code = [int]$Character
        if ($code -ge 0x30 -and $code -le 0x39) { return ($code - 0x30) }
        if ($code -ge 0x41 -and $code -le 0x46) { return ($code - 0x41 + 10) }
        if ($code -ge 0x61 -and $code -le 0x66) { return ($code - 0x61 + 10) }
        throw 'Invalid JSON Unicode escape.'
    }

    function Read-DevlogHexCodeUnit {
        if (($state.Index + 4) -gt $state.Length) {
            throw 'Incomplete JSON Unicode escape.'
        }
        $value = 0
        for ($count = 0; $count -lt 4; $count++) {
            $value = ($value * 16) + (Get-DevlogHexDigit -Character $state.Text[$state.Index])
            $state.Index++
        }
        return $value
    }

    function Read-DevlogJsonString {
        if ($state.Index -ge $state.Length -or $state.Text[$state.Index] -ne [char]0x22) {
            throw 'Expected a JSON string.'
        }
        $state.Index++
        $builder = New-Object System.Text.StringBuilder

        while ($state.Index -lt $state.Length) {
            $character = $state.Text[$state.Index]
            $state.Index++

            if ($character -eq [char]0x22) {
                return $builder.ToString()
            }

            if ($character -eq [char]0x5C) {
                if ($state.Index -ge $state.Length) {
                    throw 'Incomplete JSON escape.'
                }
                $escaped = $state.Text[$state.Index]
                $state.Index++

                if ($escaped -eq [char]0x22 -or $escaped -eq [char]0x5C -or $escaped -eq [char]0x2F) {
                    [void]$builder.Append($escaped)
                    continue
                }
                if ($escaped -ceq 'b') { [void]$builder.Append([char]0x08); continue }
                if ($escaped -ceq 'f') { [void]$builder.Append([char]0x0C); continue }
                if ($escaped -ceq 'n') { [void]$builder.Append([char]0x0A); continue }
                if ($escaped -ceq 'r') { [void]$builder.Append([char]0x0D); continue }
                if ($escaped -ceq 't') { [void]$builder.Append([char]0x09); continue }
                if ($escaped -cne 'u') {
                    throw 'Invalid JSON escape.'
                }

                # Escaped supplementary scalars must use one valid surrogate
                # pair. Lone surrogate code units are rejected.
                $codeUnit = Read-DevlogHexCodeUnit
                if ($codeUnit -ge 0xD800 -and $codeUnit -le 0xDBFF) {
                    if (($state.Index + 2) -gt $state.Length -or
                        $state.Text[$state.Index] -ne [char]0x5C -or
                        $state.Text[$state.Index + 1] -cne 'u') {
                        throw 'Incomplete JSON surrogate pair.'
                    }
                    $state.Index += 2
                    $lowCodeUnit = Read-DevlogHexCodeUnit
                    if ($lowCodeUnit -lt 0xDC00 -or $lowCodeUnit -gt 0xDFFF) {
                        throw 'Invalid JSON surrogate pair.'
                    }
                    [void]$builder.Append([char]$codeUnit)
                    [void]$builder.Append([char]$lowCodeUnit)
                    continue
                }
                if ($codeUnit -ge 0xDC00 -and $codeUnit -le 0xDFFF) {
                    throw 'Lone low surrogate in JSON string.'
                }
                [void]$builder.Append([char]$codeUnit)
                continue
            }

            if ([int]$character -lt 0x20) {
                throw 'Literal control character in JSON string.'
            }

            # Strict UTF-8 decoding already guarantees raw supplementary
            # characters arrive as a valid UTF-16 surrogate pair.
            if ([char]::IsHighSurrogate($character)) {
                if ($state.Index -ge $state.Length -or -not [char]::IsLowSurrogate($state.Text[$state.Index])) {
                    throw 'Invalid raw surrogate pair in JSON string.'
                }
                [void]$builder.Append($character)
                [void]$builder.Append($state.Text[$state.Index])
                $state.Index++
                continue
            }
            if ([char]::IsLowSurrogate($character)) {
                throw 'Lone raw low surrogate in JSON string.'
            }
            [void]$builder.Append($character)
        }

        throw 'Unterminated JSON string.'
    }

    function New-DevlogJsonValue {
        param(
            [Parameter(Mandatory = $true)][string]$Kind,
            $Value = $null
        )
        return [pscustomobject]@{ Kind = $Kind; Value = $Value }
    }

    function Test-DevlogJsonDigit {
        param([char]$Character)
        $code = [int]$Character
        return ($code -ge 0x30 -and $code -le 0x39)
    }

    function Read-DevlogJsonNumber {
        $numberStart = $state.Index
        if ($state.Text[$state.Index] -eq '-') {
            $state.Index++
            if ($state.Index -ge $state.Length) { throw 'Incomplete JSON number.' }
        }

        if ($state.Text[$state.Index] -eq '0') {
            $state.Index++
            if ($state.Index -lt $state.Length -and (Test-DevlogJsonDigit -Character $state.Text[$state.Index])) {
                throw 'Leading zero in JSON number.'
            }
        } elseif ([int]$state.Text[$state.Index] -ge 0x31 -and [int]$state.Text[$state.Index] -le 0x39) {
            do {
                $state.Index++
                if (($state.Index - $numberStart) -gt $script:DevlogMaximumJsonNumberCharacters) {
                    throw 'JSON number length limit exceeded.'
                }
            } while ($state.Index -lt $state.Length -and (Test-DevlogJsonDigit -Character $state.Text[$state.Index]))
        } else {
            throw 'Invalid JSON number.'
        }

        if ($state.Index -lt $state.Length -and $state.Text[$state.Index] -eq '.') {
            $state.Index++
            if ($state.Index -ge $state.Length -or -not (Test-DevlogJsonDigit -Character $state.Text[$state.Index])) {
                throw 'Incomplete JSON fraction.'
            }
            while ($state.Index -lt $state.Length -and (Test-DevlogJsonDigit -Character $state.Text[$state.Index])) {
                $state.Index++
                if (($state.Index - $numberStart) -gt $script:DevlogMaximumJsonNumberCharacters) {
                    throw 'JSON number length limit exceeded.'
                }
            }
        }

        if ($state.Index -lt $state.Length -and
            ($state.Text[$state.Index] -ceq 'e' -or $state.Text[$state.Index] -ceq 'E')) {
            $state.Index++
            if ($state.Index -lt $state.Length -and
                ($state.Text[$state.Index] -eq '+' -or $state.Text[$state.Index] -eq '-')) {
                $state.Index++
            }
            if ($state.Index -ge $state.Length -or -not (Test-DevlogJsonDigit -Character $state.Text[$state.Index])) {
                throw 'Incomplete JSON exponent.'
            }
            while ($state.Index -lt $state.Length -and (Test-DevlogJsonDigit -Character $state.Text[$state.Index])) {
                $state.Index++
                if (($state.Index - $numberStart) -gt $script:DevlogMaximumJsonNumberCharacters) {
                    throw 'JSON number length limit exceeded.'
                }
            }
        }

        if (($state.Index - $numberStart) -gt $script:DevlogMaximumJsonNumberCharacters) {
            throw 'JSON number length limit exceeded.'
        }

        return (New-DevlogJsonValue -Kind 'number')
    }

    function Read-DevlogJsonLiteral {
        param(
            [Parameter(Mandatory = $true)][string]$Literal,
            [Parameter(Mandatory = $true)][string]$Kind,
            $Value = $null
        )

        if (($state.Index + $Literal.Length) -gt $state.Length -or
            $state.Text.Substring($state.Index, $Literal.Length) -cne $Literal) {
            throw 'Invalid JSON literal.'
        }
        $state.Index += $Literal.Length
        return (New-DevlogJsonValue -Kind $Kind -Value $Value)
    }

    function Read-DevlogJsonArray {
        param([int]$Depth)

        if ($Depth -gt $script:DevlogMaximumJsonDepth) {
            throw 'JSON nesting limit exceeded.'
        }
        $state.Index++
        Skip-DevlogJsonWhitespace
        if ($state.Index -lt $state.Length -and $state.Text[$state.Index] -eq ']') {
            $state.Index++
            return (New-DevlogJsonValue -Kind 'array')
        }

        while ($true) {
            $null = Read-DevlogJsonValue -Depth ($Depth + 1)
            Skip-DevlogJsonWhitespace
            if ($state.Index -ge $state.Length) { throw 'Unterminated JSON array.' }
            if ($state.Text[$state.Index] -eq ']') {
                $state.Index++
                return (New-DevlogJsonValue -Kind 'array')
            }
            if ($state.Text[$state.Index] -ne ',') { throw 'Invalid JSON array separator.' }
            $state.Index++
            Skip-DevlogJsonWhitespace
        }
    }

    function Read-DevlogJsonObject {
        param(
            [bool]$CaptureProtocol,
            [int]$Depth
        )

        if ($Depth -gt $script:DevlogMaximumJsonDepth) {
            throw 'JSON nesting limit exceeded.'
        }
        $state.Index++
        Skip-DevlogJsonWhitespace
        if ($state.Index -lt $state.Length -and $state.Text[$state.Index] -eq '}') {
            $state.Index++
            return (New-DevlogJsonValue -Kind 'object')
        }

        while ($true) {
            $name = Read-DevlogJsonString
            if ((Get-DevlogUnicodeScalarCount -Value $name) -gt $script:DevlogMaximumPropertyNameScalars) {
                throw 'JSON property name length limit exceeded.'
            }
            if ($CaptureProtocol) {
                # Decode names before applying exact identity and deterministic
                # ASCII-only case-collision checks across every top-level key.
                if (-not $state.ExactNames.Add($name)) {
                    throw 'Duplicate top-level JSON property.'
                }
                $foldedName = Get-DevlogAsciiFoldedName -Name $name
                if (-not $state.FoldedNames.Add($foldedName)) {
                    throw 'ASCII case collision in top-level JSON property.'
                }
            }

            Skip-DevlogJsonWhitespace
            if ($state.Index -ge $state.Length -or $state.Text[$state.Index] -ne ':') {
                throw 'Missing JSON object colon.'
            }
            $state.Index++
            $value = Read-DevlogJsonValue -Depth ($Depth + 1)

            if ($CaptureProtocol) {
                if ([string]::Equals($name, 'session_id', [System.StringComparison]::Ordinal)) {
                    $state.HasSessionProperty = $true
                    $state.SessionValue = $value
                } elseif ([string]::Equals($name, 'stop_hook_active', [System.StringComparison]::Ordinal)) {
                    $state.HasStopProperty = $true
                    $state.StopValue = $value
                }
            }

            Skip-DevlogJsonWhitespace
            if ($state.Index -ge $state.Length) { throw 'Unterminated JSON object.' }
            if ($state.Text[$state.Index] -eq '}') {
                $state.Index++
                return (New-DevlogJsonValue -Kind 'object')
            }
            if ($state.Text[$state.Index] -ne ',') { throw 'Invalid JSON object separator.' }
            $state.Index++
            Skip-DevlogJsonWhitespace
        }
    }

    function Read-DevlogJsonValue {
        param([int]$Depth)

        $state.ValueCount++
        if ($state.ValueCount -gt $script:DevlogMaximumJsonValues) {
            throw 'JSON value count limit exceeded.'
        }
        Skip-DevlogJsonWhitespace
        if ($state.Index -ge $state.Length) { throw 'Missing JSON value.' }
        $character = $state.Text[$state.Index]

        if ($character -eq [char]0x22) {
            return (New-DevlogJsonValue -Kind 'string' -Value (Read-DevlogJsonString))
        }
        if ($character -eq '{') {
            return (Read-DevlogJsonObject -CaptureProtocol $false -Depth $Depth)
        }
        if ($character -eq '[') {
            return (Read-DevlogJsonArray -Depth $Depth)
        }
        if ($character -ceq 't') {
            return (Read-DevlogJsonLiteral -Literal 'true' -Kind 'boolean' -Value $true)
        }
        if ($character -ceq 'f') {
            return (Read-DevlogJsonLiteral -Literal 'false' -Kind 'boolean' -Value $false)
        }
        if ($character -ceq 'n') {
            return (Read-DevlogJsonLiteral -Literal 'null' -Kind 'null')
        }
        if ($character -eq '-' -or (Test-DevlogJsonDigit -Character $character)) {
            return (Read-DevlogJsonNumber)
        }
        throw 'Invalid JSON value.'
    }

    try {
        Skip-DevlogJsonWhitespace
        if ($state.Index -ge $state.Length -or $state.Text[$state.Index] -ne '{') {
            return $null
        }
        $null = Read-DevlogJsonObject -CaptureProtocol $true -Depth 1
        Skip-DevlogJsonWhitespace
        if ($state.Index -ne $state.Length) {
            return $null
        }
    } catch {
        return $null
    }

    $hasSession = [bool]($state.HasSessionProperty -and
        $null -ne $state.SessionValue -and
        $state.SessionValue.Kind -ceq 'string' -and
        ([string]$state.SessionValue.Value -cmatch ('\A[A-Za-z0-9_.-]{1,' + $script:DevlogMaximumSessionIdCharacters + '}\z')))
    $stopActive = [bool]($state.HasStopProperty -and
        $null -ne $state.StopValue -and
        $state.StopValue.Kind -ceq 'boolean' -and
        [bool]$state.StopValue.Value)

    return [pscustomobject]@{
        HasSession = $hasSession
        SessionId = if ($hasSession) { [string]$state.SessionValue.Value } else { '' }
        StopActive = $stopActive
    }
}

function Read-DevlogMarkerEpoch {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Marker files are produced as one canonical ASCII epoch without a
    # newline. Reject linked namespace entries before opening, then enforce a
    # bounded size so an unexpectedly large marker is never copied into memory.
    $stream = $null
    try {
        $directory = [System.IO.Path]::GetDirectoryName($Path)
        if ([string]::IsNullOrWhiteSpace($directory) -or
            -not (Test-DevlogMarkerDirectory -Path $directory) -or
            -not (Test-DevlogMarkerLeaf -Path $Path)) { return $null }
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $length = [int64]$stream.Length
        if ($length -lt 1 -or $length -gt 18) { return $null }

        $bytes = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { return $null }
            $offset += $read
        }
        if ($stream.Length -ne $length -or
            -not (Test-DevlogMarkerDirectory -Path $directory) -or
            -not (Test-DevlogMarkerLeaf -Path $Path)) { return $null }

        foreach ($byte in $bytes) {
            if ($byte -lt 0x30 -or $byte -gt 0x39) { return $null }
        }
        if ($bytes.Length -gt 1 -and $bytes[0] -eq 0x30) { return $null }

        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $value = [int64]0
        if (-not [int64]::TryParse(
            $text,
            [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$value
        )) { return $null }
        return $value
    } catch {
        return $null
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-DevlogHookInput {
    # Read at most max+1 bytes from stdin before decoding. NUL, invalid UTF-8,
    # and an over-limit stream all become one silent, fail-open parse failure.
    $memory = $null
    try {
        $stream = [Console]::OpenStandardInput()
        $memory = New-Object System.IO.MemoryStream
        $buffer = New-Object byte[] 8192

        while ($true) {
            $remaining = ($script:DevlogMaximumInputBytes + 1) - [int]$memory.Length
            if ($remaining -le 0) { break }
            $readLength = [Math]::Min($buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $readLength)
            if ($read -le 0) { break }
            $memory.Write($buffer, 0, $read)
        }

        if ($memory.Length -gt $script:DevlogMaximumInputBytes) { return $null }
        $bytes = $memory.ToArray()
        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { return $null }

        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $rawInput = $strictUtf8.GetString($bytes)
        return (ConvertFrom-DevlogHookInput -RawInput $rawInput)
    } catch {
        return $null
    } finally {
        if ($null -ne $memory) { $memory.Dispose() }
    }
}
