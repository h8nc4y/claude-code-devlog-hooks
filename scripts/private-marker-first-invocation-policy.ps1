# private-marker scanner self-test の最初の helper 実行を構文木で固定する。
# この file は pure validator だけを定義し、process や外部 command は実行しない。

function Test-PrivateMarkerProcessCommandIsDeferredDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Command
    )

    # function/type 定義はその場では実行されない。一方 scriptblock は、
    # command 引数や .Invoke*() の receiver なら即時実行され得るため eager とみなす。
    $ancestor = $Command.Parent
    while ($null -ne $ancestor) {
        if ($ancestor -is
                [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $ancestor -is
                [System.Management.Automation.Language.FunctionMemberAst] -or
            $ancestor -is
                [System.Management.Automation.Language.TypeDefinitionAst]) {
            return $true
        }
        if ($ancestor -is
            [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $container = $ancestor.Parent
            $expressionCanExecuteScriptBlock = $false
            while ($null -ne $container) {
                if ($container -is
                        [System.Management.Automation.Language.FunctionDefinitionAst] -or
                    $container -is
                        [System.Management.Automation.Language.FunctionMemberAst] -or
                    $container -is
                        [System.Management.Automation.Language.TypeDefinitionAst]) {
                    return $true
                }
                if ($container -is
                        [System.Management.Automation.Language.CommandAst] -or
                    $container -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    $expressionCanExecuteScriptBlock = $true
                    break
                }
                $container = $container.Parent
            }
            if (-not $expressionCanExecuteScriptBlock) {
                return $true
            }
        }
        $ancestor = $ancestor.Parent
    }
    return $false
}

function ConvertTo-PrivateMarkerCallableName {
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    # module qualification、function provider、scope prefixを順に除き、
    # 同じlocal functionを参照する表記をcase-insensitive setへ正規化する。
    $normalized = $Name.Trim()
    $moduleSeparator = $normalized.LastIndexOf('\')
    if ($moduleSeparator -ge 0) {
        $normalized = $normalized.Substring($moduleSeparator + 1)
    }
    $normalized = [regex]::Replace(
        $normalized,
        '^(?i:function:)[\\/]*',
        ''
    )
    return [regex]::Replace(
        $normalized,
        '^(?i:(?:global|script|local|private):)',
        ''
    )
}

function Get-PrivateMarkerStaticAstValue {
    param(
        [AllowNull()]
        [System.Management.Automation.Language.Ast]$ValueAst
    )

    if ($null -eq $ValueAst) {
        return [pscustomobject]@{
            Resolved = $false
            Value = ''
        }
    }
    if ($ValueAst -is
        [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [pscustomobject]@{
            Resolved = $true
            Value = [string]$ValueAst.Value
        }
    }
    if ($ValueAst -is
            [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
        @($ValueAst.NestedExpressions).Count -eq 0) {
        return [pscustomobject]@{
            Resolved = $true
            Value = [string]$ValueAst.Value
        }
    }
    return [pscustomobject]@{
        Resolved = $false
        Value = ''
    }
}

function Get-PrivateMarkerStaticCommandArgument {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command,
        [string[]]$ParameterNames,
        [int]$PositionalIndex = -1
    )

    # named argumentを優先する。位置引数は最初のparameterより前だけを認め、
    # parameter bindingを再実装して誤ってdynamic値をsafe扱いしない。
    $elements = @($Command.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot
            [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }
        if ($ParameterNames -notcontains $element.ParameterName) {
            continue
        }

        $argumentAst = $element.Argument
        if ($null -eq $argumentAst -and
            ($index + 1) -lt $elements.Count -and
            $elements[$index + 1] -isnot
                [System.Management.Automation.Language.CommandParameterAst]) {
            $argumentAst = $elements[$index + 1]
        }
        return Get-PrivateMarkerStaticAstValue -ValueAst $argumentAst
    }

    if ($PositionalIndex -lt 0) {
        return Get-PrivateMarkerStaticAstValue -ValueAst $null
    }
    $leadingPositionals = New-Object `
        'System.Collections.Generic.List[System.Management.Automation.Language.Ast]'
    for ($index = 1; $index -lt $elements.Count; $index++) {
        if ($elements[$index] -is
            [System.Management.Automation.Language.CommandParameterAst]) {
            break
        }
        $leadingPositionals.Add($elements[$index]) | Out-Null
    }
    if ($PositionalIndex -ge $leadingPositionals.Count) {
        return Get-PrivateMarkerStaticAstValue -ValueAst $null
    }
    return Get-PrivateMarkerStaticAstValue `
        -ValueAst $leadingPositionals[$PositionalIndex]
}

function Get-PrivateMarkerAliasDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $commandName = ConvertTo-PrivateMarkerCallableName `
        -Name $Command.GetCommandName()
    $directAliasCommands = @('Set-Alias', 'New-Alias', 'sal', 'nal')
    $providerMutationCommands = @(
        'Set-Item',
        'si',
        'New-Item',
        'ni',
        'Set-Content',
        'sc',
        'Add-Content',
        'ac',
        'Clear-Item',
        'cli',
        'Copy-Item',
        'cpi',
        'cp',
        'copy',
        'Move-Item',
        'mi',
        'mv',
        'move',
        'Rename-Item',
        'rni',
        'ren',
        'Remove-Item',
        'ri',
        'rm',
        'rmdir',
        'del',
        'erase',
        'rd'
    )
    if (@('Import-Alias', 'ipal') -contains $commandName) {
        # external alias fileの内容を静的に証明できないため常にfail closed。
        return [pscustomobject]@{
            IsAliasCommand = $true
            Resolved = $false
            Name = ''
            Target = ''
        }
    }
    if ($directAliasCommands -notcontains $commandName -and
        $providerMutationCommands -notcontains $commandName) {
        return [pscustomobject]@{
            IsAliasCommand = $false
            Resolved = $true
            Name = ''
            Target = ''
        }
    }

    if ($directAliasCommands -contains $commandName) {
        $nameResult = Get-PrivateMarkerStaticCommandArgument `
            -Command $Command `
            -ParameterNames @('Name', 'N') `
            -PositionalIndex 0
        $targetResult = Get-PrivateMarkerStaticCommandArgument `
            -Command $Command `
            -ParameterNames @('Value', 'V') `
            -PositionalIndex 1
    }
    else {
        $pathResult = Get-PrivateMarkerStaticCommandArgument `
            -Command $Command `
            -ParameterNames @('Path', 'LiteralPath') `
            -PositionalIndex 0
        if (-not $pathResult.Resolved) {
            # dynamic provider pathはAlias/Function/Variableへ解決し得る。
            # ItemTypeがFile/Directoryでもprovider側が無視できるため免除しない。
            return [pscustomobject]@{
                IsAliasCommand = $true
                Resolved = $false
                Name = ''
                Target = ''
            }
        }

        $providerMatch = [regex]::Match(
            $pathResult.Value,
            '^(?i)(?:Microsoft\.PowerShell\.Core\\)?' +
                '(?<provider>Alias|Function|Variable):{1,2}[\\/]*(?<name>.+)$'
        )
        if (-not $providerMatch.Success) {
            return [pscustomobject]@{
                IsAliasCommand = $false
                Resolved = $true
                Name = ''
                Target = ''
            }
        }
        if ($providerMatch.Groups['provider'].Value -in @(
                'Function',
                'Variable'
            ) -or
            $commandName -notin @('Set-Item', 'si', 'New-Item', 'ni')) {
            # Function/Variable providerやcontent/remove/move相当は実行identityを
            # 任意に変えられるため、個別のsafe mutationとして扱わない。
            return [pscustomobject]@{
                IsAliasCommand = $true
                Resolved = $false
                Name = ''
                Target = ''
            }
        }
        $nameResult = [pscustomobject]@{
            Resolved = $true
            Value = $providerMatch.Groups['name'].Value
        }
        $targetResult = Get-PrivateMarkerStaticCommandArgument `
            -Command $Command `
            -ParameterNames @('Value') `
            -PositionalIndex 1
    }

    if (-not $nameResult.Resolved -or
        -not $targetResult.Resolved) {
        return [pscustomobject]@{
            IsAliasCommand = $true
            Resolved = $false
            Name = ''
            Target = ''
        }
    }

    $aliasName = ConvertTo-PrivateMarkerCallableName -Name $nameResult.Value
    $aliasTarget = ConvertTo-PrivateMarkerCallableName -Name $targetResult.Value
    return [pscustomobject]@{
        IsAliasCommand = $true
        Resolved = (
            -not [string]::IsNullOrWhiteSpace($aliasName) -and
            -not [string]::IsNullOrWhiteSpace($aliasTarget)
        )
        Name = $aliasName
        Target = $aliasTarget
    }
}

function Test-PrivateMarkerAliasMutationEscapesDefinitionScope {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $commandName = ConvertTo-PrivateMarkerCallableName `
        -Name $Command.GetCommandName()
    if (@('Set-Alias', 'New-Alias', 'sal', 'nal') -notcontains
        $commandName) {
        return $false
    }

    # Set-Alias/New-Alias の既定 scope は呼出し中 function の local なので、
    # helper 呼出し後には残らない。明示 scope は static Local だけを許可し、
    # Script/Global/numeric/dynamic scope は後続 binary call を shadow し得るため拒否する。
    $scopeParameter = @(
        $Command.CommandElements |
            Where-Object {
                $_ -is
                    [System.Management.Automation.Language.CommandParameterAst] -and
                $_.ParameterName -imatch '^S(?:c(?:o(?:p(?:e)?)?)?)?$'
            }
    )
    if ($scopeParameter.Count -eq 0) {
        return $false
    }
    if ($scopeParameter.Count -ne 1) {
        return $true
    }

    $elements = @($Command.CommandElements)
    $scopeIndex = [Array]::IndexOf($elements, $scopeParameter[0])
    $scopeAst = $scopeParameter[0].Argument
    if ($null -eq $scopeAst -and
        ($scopeIndex + 1) -lt $elements.Count -and
        $elements[$scopeIndex + 1] -isnot
            [System.Management.Automation.Language.CommandParameterAst]) {
        $scopeAst = $elements[$scopeIndex + 1]
    }
    $scopeResult = Get-PrivateMarkerStaticAstValue -ValueAst $scopeAst
    return -not $scopeResult.Resolved -or $scopeResult.Value -ine 'Local'
}

function Test-PrivateMarkerFunctionDefinitionEscapesDefinitionScope {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.FunctionDefinitionAst]$Function
    )

    # unqualified/local/private nested function は wrapper 終了時に消える。
    # script/global prefix だけが後続の transport helper identity を永続変更する。
    return $Function.Name -match '^(?i)(?:script|global):'
}

function Test-PrivateMarkerNameIsScriptPath {
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    # bare command/alias targetはscript pathも実行できる。separatorを含むnameと、
    # 正規化時にdirectoryが除かれた.ps1 basenameを両方閉じる。
    return $Name -match '[\\/]' -or
        $Name -match '(?i)\.ps1$'
}

function Test-PrivateMarkerNameMatchesRiskyCallable {
    param(
        [AllowEmptyString()]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$RiskyCallableNames
    )

    $normalized = ConvertTo-PrivateMarkerCallableName -Name $Name
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }
    if ($RiskyCallableNames.Contains($normalized)) {
        return $true
    }

    # Get-Command/Get-Itemはwildcardを受理するため、static patternも
    # risky functionへ展開し得るかを全件比較する。
    if ($normalized.IndexOfAny([char[]]'*?[') -ge 0) {
        foreach ($riskyName in $RiskyCallableNames) {
            if ($riskyName -like $normalized) {
                return $true
            }
        }
    }
    return $false
}

function Get-PrivateMarkerFunctionReferenceRisk {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$RiskyCallableNames
    )

    $commandName = ConvertTo-PrivateMarkerCallableName `
        -Name $Command.GetCommandName()
    if (@('Get-Command', 'gcm') -contains $commandName) {
        $nameResult = Get-PrivateMarkerStaticCommandArgument `
            -Command $Command `
            -ParameterNames @('Name') `
            -PositionalIndex 0
        $commandTypeResult = Get-PrivateMarkerStaticCommandArgument `
            -Command $Command `
            -ParameterNames @('CommandType', 'Type') `
            -PositionalIndex -1

        # binary fixture準備で必要なnative Git lookupだけをexact allowlist化する。
        # それ以外はExternalScriptInfo.ScriptBlock等を返し得るためfail closed。
        if (-not $nameResult.Resolved -or
            -not $commandTypeResult.Resolved) {
            return 'Unresolved'
        }
        if ($nameResult.Value -ieq 'git' -and
            $commandTypeResult.Value -ieq 'Application') {
            return 'Safe'
        }
        return 'Risky'
    }

    if (@(
            'Get-Item',
            'gi',
            'Get-ChildItem',
            'gci',
            'dir',
            'ls',
            'Get-Content',
            'gc',
            'cat',
            'type'
        ) -contains $commandName) {
        $pathResult = Get-PrivateMarkerStaticCommandArgument `
            -Command $Command `
            -ParameterNames @('Path', 'LiteralPath') `
            -PositionalIndex 0
        if (-not $pathResult.Resolved) {
            return 'Unresolved'
        }
        if ($pathResult.Value -notmatch '^(?i:function:)') {
            return 'Safe'
        }
        if (Test-PrivateMarkerNameMatchesRiskyCallable `
            -Name $pathResult.Value `
            -RiskyCallableNames $RiskyCallableNames) {
            return 'Risky'
        }
        return 'Safe'
    }

    return 'NotApplicable'
}

function Test-PrivateMarkerScriptBlockExpressionIsDormantInFunction {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ScriptBlockExpressionAst]$Expression,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.FunctionDefinitionAst]$Function
    )

    # assignment へ保存した local scriptblock は、同じ wrapper 内で一度も
    # 再参照されなければ実行も外部 escape もしない。inline command 引数や
    # Invoke receiver、複雑な格納先は用途を静的に証明せず eager 扱いを維持する。
    $assignment = $Expression.Parent
    while ($null -ne $assignment -and
        -not [object]::ReferenceEquals($assignment, $Function)) {
        if ($assignment -is
                [System.Management.Automation.Language.CommandAst] -or
            $assignment -is
                [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            return $false
        }
        if ($assignment -is
            [System.Management.Automation.Language.AssignmentStatementAst]) {
            break
        }
        if ($assignment -is
                [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $assignment -is
                [System.Management.Automation.Language.FunctionMemberAst] -or
            $assignment -is
                [System.Management.Automation.Language.TypeDefinitionAst]) {
            return $false
        }
        $assignment = $assignment.Parent
    }
    if ($assignment -isnot
            [System.Management.Automation.Language.AssignmentStatementAst] -or
        $assignment.Left -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        (Test-PrivateMarkerVariableEscapesDefinitionScope `
            -Name $assignment.Left.VariablePath.UserPath)) {
        return $false
    }

    # `ForEach-Object -Process ($later = { ... })` のようにassignment自体が
    # eager command引数なら、後続参照がなくても格納と同時に実行され得る。
    $outerContainer = $assignment.Parent
    while ($null -ne $outerContainer -and
        -not [object]::ReferenceEquals($outerContainer, $Function)) {
        if ($outerContainer -is
                [System.Management.Automation.Language.CommandAst] -or
            $outerContainer -is
                [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            return $false
        }
        if ($outerContainer -is
                [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $outerContainer -is
                [System.Management.Automation.Language.FunctionMemberAst] -or
            $outerContainer -is
                [System.Management.Automation.Language.TypeDefinitionAst]) {
            return $false
        }
        $outerContainer = $outerContainer.Parent
    }

    $storedVariableName = ConvertTo-PrivateMarkerVariableName `
        -Name $assignment.Left.VariablePath.UserPath
    $laterReferences = @(
        $Function.FindAll(
            {
                param($node)
                if ($node.Extent.StartOffset -lt
                    $assignment.Extent.EndOffset) {
                    return $false
                }
                if ($node -is
                    [System.Management.Automation.Language.VariableExpressionAst]) {
                    return (ConvertTo-PrivateMarkerVariableName `
                        -Name $node.VariablePath.UserPath) -ieq
                            $storedVariableName
                }
                if ($node -is
                    [System.Management.Automation.Language.CommandAst]) {
                    return Test-PrivateMarkerCommandReadsVariable `
                        -Command $node `
                        -VariableName $storedVariableName
                }
                if ($node -is
                    [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    return Test-PrivateMarkerMemberReadsVariable `
                        -Invocation $node `
                        -VariableName $storedVariableName
                }
                return $false
            },
            $true
        )
    )
    return $laterReferences.Count -eq 0
}

function Test-PrivateMarkerAstOwnedByFunction {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Node,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.FunctionDefinitionAst]$Function
    )

    # nested functionのbodyを外側functionのcall graphへ混ぜない。さらに、
    # local変数へ保存したまま未参照のscriptblockは実行経路へ混ぜない。
    $scriptBlockExpression = $null
    $ancestor = $Node.Parent
    while ($null -ne $ancestor) {
        if ($null -eq $scriptBlockExpression -and
            $ancestor -is
                [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $scriptBlockExpression = $ancestor
        }
        if ($ancestor -is
            [System.Management.Automation.Language.FunctionDefinitionAst]) {
            if (-not [object]::ReferenceEquals($ancestor, $Function)) {
                return $false
            }
            if ($null -ne $scriptBlockExpression -and
                (Test-PrivateMarkerScriptBlockExpressionIsDormantInFunction `
                    -Expression $scriptBlockExpression `
                    -Function $Function)) {
                return $false
            }
            return $true
        }
        if ($ancestor -is
                [System.Management.Automation.Language.FunctionMemberAst] -or
            $ancestor -is
                [System.Management.Automation.Language.TypeDefinitionAst]) {
            return $false
        }
        $ancestor = $ancestor.Parent
    }
    return $false
}

function ConvertTo-PrivateMarkerVariableName {
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    # scope/Variable provider-qualified variableも同一bindingへの変更・参照として
    # 数える。一方、許可するprovenance assignment自体はunqualified名に限定する。
    return [regex]::Replace(
        $Name.Trim(),
        '^(?i:(?:(?:global|script|local|private|variable):)+)',
        ''
    )
}

function Test-PrivateMarkerVariableEscapesDefinitionScope {
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    # function/type内のunqualified/local/private変数は呼出し元のbootstrap bindingを
    # 変更しない。script/global scopeへ明示的に抜ける参照だけを外部mutationとみなす。
    return $Name.Trim() -match
        '^(?i)(?:(?:variable):)*(?:script|global):'
}

function Test-PrivateMarkerAstIsRawSessionStatePsVariable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    if ($Ast -isnot
            [System.Management.Automation.Language.MemberExpressionAst] -or
        $Ast.Member -isnot
            [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $Ast.Member.Value -ine 'PSVariable' -or
        $Ast.Expression -isnot
            [System.Management.Automation.Language.MemberExpressionAst]) {
        return $false
    }
    $sessionState = $Ast.Expression
    if ($sessionState.Member -isnot
            [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $sessionState.Member.Value -ine 'SessionState' -or
        $sessionState.Expression -isnot
            [System.Management.Automation.Language.VariableExpressionAst]) {
        return $false
    }
    return (ConvertTo-PrivateMarkerVariableName `
            -Name $sessionState.Expression.VariablePath.UserPath) -ieq
        'ExecutionContext'
}

function Test-PrivateMarkerExecutionContextReferenceIsDirectPsVariableReceiver {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.VariableExpressionAst]$Variable
    )

    if ((ConvertTo-PrivateMarkerVariableName `
            -Name $Variable.VariablePath.UserPath) -ine 'ExecutionContext') {
        return $false
    }

    # raw tableを見つけただけでは安全とみなさない。return、assignment、
    # command argument、複数要素pipelineへ渡すと別wrapperが後でSetできるため、
    # まずexactなSessionState.PSVariable chainを特定する。
    $rawPsVariable = $null
    $ancestor = $Variable.Parent
    for ($depth = 0; $depth -lt 16 -and $null -ne $ancestor; $depth++) {
        if ($ancestor -is
                [System.Management.Automation.Language.MemberExpressionAst] -and
            (Test-PrivateMarkerAstIsRawSessionStatePsVariable `
                -Ast $ancestor)) {
            $rawPsVariable = $ancestor
            break
        }
        if ($ancestor -is
                [System.Management.Automation.Language.StatementAst] -or
            $ancestor -is
                [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $ancestor -is
                [System.Management.Automation.Language.TypeDefinitionAst]) {
            break
        }
        $ancestor = $ancestor.Parent
    }
    if ($null -eq $rawPsVariable) {
        return $false
    }

    # object identityを保つ唯一childのwrapperだけを上へ辿る。最終consumerが
    # exact Get/GetValue/Set/SetValue receiverなら、protected名かどうかは
    # Test-PrivateMarkerMemberReads/WritesVariableへ委ねられる。それ以外へ
    # tableがescapeする経路はgeneric ExecutionContext riskとして拒否する。
    $current = $rawPsVariable
    for ($depth = 0; $depth -lt 128; $depth++) {
        $parent = $current.Parent
        if ($null -eq $parent) {
            return $false
        }
        if ($parent -is
            [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            return [object]::ReferenceEquals(
                    $parent.Expression,
                    $current
                ) -and
                $parent.Member -is
                    [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $parent.Member.Value -imatch '^(?:Get|GetValue|Set|SetValue)$'
        }

        # ConvertExpressionは型変換でobject identityを変え得るためdirect receiver
        # には数えない。taint保持側のunwrapとは責務が異なる。
        $transparent = $false
        if ($parent -is
            [System.Management.Automation.Language.CommandExpressionAst]) {
            $transparent = [object]::ReferenceEquals(
                $parent.Expression,
                $current
            )
        }
        elseif ($parent -is
            [System.Management.Automation.Language.ParenExpressionAst]) {
            $transparent = [object]::ReferenceEquals(
                $parent.Pipeline,
                $current
            )
        }
        elseif ($parent -is
            [System.Management.Automation.Language.PipelineAst]) {
            $pipelineElements = @($parent.PipelineElements)
            $transparent = $pipelineElements.Count -eq 1 -and
                [object]::ReferenceEquals(
                    $pipelineElements[0],
                    $current
                )
        }
        elseif ($parent -is
            [System.Management.Automation.Language.SubExpressionAst]) {
            $transparent = [object]::ReferenceEquals(
                $parent.SubExpression,
                $current
            )
        }
        elseif ($parent -is
            [System.Management.Automation.Language.ArrayExpressionAst]) {
            # @(...).GetValue(0) のreceiverはPSVariable tableではなくObject[]。
            # array自体を許可せず、直後のindexが唯一要素へ戻す形だけを通す。
            $indexParent = $parent.Parent
            $transparent = [object]::ReferenceEquals(
                    $parent.SubExpression,
                    $current
                ) -and
                $indexParent -is
                    [System.Management.Automation.Language.IndexExpressionAst] -and
                [object]::ReferenceEquals(
                    $indexParent.Target,
                    $parent
                )
        }
        elseif ($parent -is
            [System.Management.Automation.Language.StatementBlockAst]) {
            $statements = @($parent.Statements)
            $transparent = $statements.Count -eq 1 -and
                [object]::ReferenceEquals(
                    $statements[0],
                    $current
                )
        }
        elseif ($parent -is
            [System.Management.Automation.Language.ArrayLiteralAst]) {
            $elements = @($parent.Elements)
            $indexParent = $parent.Parent
            $transparent = $elements.Count -eq 1 -and
                [object]::ReferenceEquals(
                    $elements[0],
                    $current
                ) -and
                $indexParent -is
                    [System.Management.Automation.Language.IndexExpressionAst] -and
                [object]::ReferenceEquals(
                    $indexParent.Target,
                    $parent
                )
        }
        elseif ($parent -is
            [System.Management.Automation.Language.IndexExpressionAst]) {
            $transparent = [object]::ReferenceEquals(
                $parent.Target,
                $current
            )
        }
        if (-not $transparent) {
            return $false
        }
        $current = $parent
    }
    return $false
}

function Test-PrivateMarkerAstIsSessionStatePsVariable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    # 任意のGetValue()/SetValue()をPSVariable操作と誤認しないよう、
    # $ExecutionContext.SessionState.PSVariable のmember chainをASTで固定する。
    # 括弧、subexpression、identity cast、array/indexはobject identityを保てる
    # 経路があるためunwrapする。深さ上限だけでなく、未知のcommand/call等へ
    # 到達した場合も、そのsubtree内にraw chainが残ればfail closedにする。
    for ($depth = 0; $depth -lt 128; $depth++) {
        $nextAst = $null
        if ($Ast -is
            [System.Management.Automation.Language.CommandExpressionAst]) {
            $nextAst = $Ast.Expression
        }
        elseif ($Ast -is
            [System.Management.Automation.Language.ParenExpressionAst]) {
            $nextAst = $Ast.Pipeline
        }
        elseif ($Ast -is
            [System.Management.Automation.Language.ConvertExpressionAst]) {
            $nextAst = $Ast.Child
        }
        elseif ($Ast -is
            [System.Management.Automation.Language.PipelineAst]) {
            $pipelineElements = @($Ast.PipelineElements)
            if ($pipelineElements.Count -eq 1) {
                $nextAst = $pipelineElements[0]
            }
        }
        elseif ($Ast -is
                [System.Management.Automation.Language.SubExpressionAst] -or
            $Ast -is
                [System.Management.Automation.Language.ArrayExpressionAst]) {
            $nextAst = $Ast.SubExpression
        }
        elseif ($Ast -is
            [System.Management.Automation.Language.StatementBlockAst]) {
            $statements = @($Ast.Statements)
            if ($statements.Count -eq 1) {
                $nextAst = $statements[0]
            }
        }
        elseif ($Ast -is
            [System.Management.Automation.Language.ArrayLiteralAst]) {
            $elements = @($Ast.Elements)
            if ($elements.Count -eq 1) {
                $nextAst = $elements[0]
            }
        }
        elseif ($Ast -is
            [System.Management.Automation.Language.IndexExpressionAst]) {
            # single-element arrayは0/-1/dynamic coercionで同じtableを返し得る。
            # index値を証明しようとせずtarget側のPSVariable provenanceを保守的に追う。
            $nextAst = $Ast.Target
        }
        if ($null -eq $nextAst -or
            [object]::ReferenceEquals($nextAst, $Ast)) {
            break
        }
        $Ast = $nextAst
    }

    # unsupported terminalを「安全」と推定しない。PowerShell commandは
    # -NoEnumerate等で引数objectをそのまま返せるため、残ったraw provenanceを
    # subtree検索で保守的に引き継ぐ。
    $rawReferences = @(
        $Ast.FindAll(
            {
                param($node)
                return Test-PrivateMarkerAstIsRawSessionStatePsVariable `
                    -Ast $node
            },
            $true
        )
    )
    return $rawReferences.Count -gt 0
}

function Test-PrivateMarkerCommandReadsVariable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory = $true)]
        [string]$VariableName
    )

    $commandName = ConvertTo-PrivateMarkerCallableName `
        -Name $Command.GetCommandName()
    if (@('Get-Variable', 'gv') -contains $commandName) {
        $nameResult = Get-PrivateMarkerStaticCommandArgument `
            -Command $Command `
            -ParameterNames @('Name') `
            -PositionalIndex 0
        if (-not $nameResult.Resolved) {
            return $true
        }
        return $VariableName -like
            (ConvertTo-PrivateMarkerVariableName -Name $nameResult.Value)
    }

    $variableProviderReaders = @(
        'Get-Item',
        'gi',
        'Get-ChildItem',
        'gci',
        'dir',
        'ls',
        'Get-Content',
        'gc',
        'cat',
        'type'
    )
    if ($variableProviderReaders -notcontains $commandName) {
        return $false
    }
    $pathResult = Get-PrivateMarkerStaticCommandArgument `
        -Command $Command `
        -ParameterNames @('Path', 'LiteralPath') `
        -PositionalIndex 0
    if (-not $pathResult.Resolved) {
        # risky stored blockが存在する間のdynamic provider readはVariable:へ
        # 解決し得るため、用途を推測せずfail closedにする。
        return $true
    }
    $providerMatch = [regex]::Match(
        $pathResult.Value,
        '^(?i)(?:Microsoft\.PowerShell\.Core\\)?' +
            'Variable:{1,2}[\\/]*(?<name>.*)$'
    )
    if (-not $providerMatch.Success) {
        return $false
    }
    $namePattern = $providerMatch.Groups['name'].Value
    return [string]::IsNullOrWhiteSpace($namePattern) -or
        $VariableName -like
            (ConvertTo-PrivateMarkerVariableName -Name $namePattern)
}

function Test-PrivateMarkerMemberReadsVariable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.InvokeMemberExpressionAst]$Invocation,
        [Parameter(Mandatory = $true)]
        [string]$VariableName
    )

    if (-not (Test-PrivateMarkerAstIsSessionStatePsVariable `
            -Ast $Invocation.Expression) -or
        $Invocation.Member -isnot
            [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $Invocation.Member.Value -inotmatch '^(?:Get|GetValue)$') {
        return $false
    }
    $arguments = @($Invocation.Arguments)
    if ($arguments.Count -eq 0) {
        return $true
    }
    $nameResult = Get-PrivateMarkerStaticAstValue -ValueAst $arguments[0]
    if (-not $nameResult.Resolved) {
        return $true
    }
    return $VariableName -like
        (ConvertTo-PrivateMarkerVariableName -Name $nameResult.Value)
}

function Test-PrivateMarkerMemberWritesVariable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.InvokeMemberExpressionAst]$Invocation,
        [Parameter(Mandatory = $true)]
        [string]$VariableName
    )

    # SessionState.PSVariable.Set/SetValueは通常のassignment ASTを作らない。
    # function/type内ではscript/global scopeを明示したprotected名だけが外へ作用する。
    if (-not (Test-PrivateMarkerAstIsSessionStatePsVariable `
            -Ast $Invocation.Expression) -or
        $Invocation.Member -isnot
            [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $Invocation.Member.Value -inotmatch '^(?:Set|SetValue)$') {
        return $false
    }
    $arguments = @($Invocation.Arguments)
    if ($arguments.Count -eq 0) {
        return $true
    }
    $nameResult = Get-PrivateMarkerStaticAstValue -ValueAst $arguments[0]
    if (-not $nameResult.Resolved) {
        return $true
    }
    return (Test-PrivateMarkerVariableEscapesDefinitionScope `
            -Name $nameResult.Value) -and
        $VariableName -like
            (ConvertTo-PrivateMarkerVariableName -Name $nameResult.Value)
}

function Test-PrivateMarkerAssignmentTargetsVariable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.AssignmentStatementAst]$Assignment,
        [Parameter(Mandatory = $true)]
        [string]$VariableName
    )

    # tuple/index/member左辺も含め、assignment target側にprotected variableが
    # 一度でも現れたらmutationとして数える。単純Leftだけを見ると多重代入で抜ける。
    $targets = @(
        $Assignment.Left.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    (ConvertTo-PrivateMarkerVariableName `
                        -Name $node.VariablePath.UserPath) -ieq $VariableName
            },
            $true
        )
    )
    return $targets.Count -gt 0
}

function Test-PrivateMarkerAssignmentDirectlyBindsVariable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.AssignmentStatementAst]$Assignment,
        [Parameter(Mandatory = $true)]
        [string]$VariableName
    )

    if ([string]$Assignment.Operator -ne 'Equals') {
        return $false
    }

    # direct assignment と tuple の direct element だけが新しい local binding を
    # 作る。index/member 左辺に現れる variable は既存 object のmutationであり、
    # 後続 [ref] を親 scope から切り離した証拠にはならない。
    $directTargets = if ($Assignment.Left -is
        [System.Management.Automation.Language.VariableExpressionAst]) {
        @($Assignment.Left)
    }
    elseif ($Assignment.Left -is
        [System.Management.Automation.Language.ArrayLiteralAst]) {
        @(
            $Assignment.Left.Elements |
                Where-Object {
                    $_ -is
                        [System.Management.Automation.Language.VariableExpressionAst]
                }
        )
    }
    else {
        @()
    }
    foreach ($target in $directTargets) {
        if (-not (Test-PrivateMarkerVariableEscapesDefinitionScope `
                -Name $target.VariablePath.UserPath) -and
            (ConvertTo-PrivateMarkerVariableName `
                -Name $target.VariablePath.UserPath) -ieq $VariableName) {
            return $true
        }
    }
    return $false
}

function Test-PrivateMarkerAstIsDirectTopLevelStatement {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Node,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ScriptBlockAst]$SourceAst
    )

    # branch/loop/function内の代入は実行が保証できない。root、path builder、
    # dot-sourceはsource直下のstatementだけをbootstrap provenanceに認める。
    $ancestor = $Node.Parent
    while ($null -ne $ancestor -and
        -not [object]::ReferenceEquals($ancestor, $SourceAst)) {
        if ($ancestor -isnot
                [System.Management.Automation.Language.PipelineAst] -and
            $ancestor -isnot
                [System.Management.Automation.Language.NamedBlockAst]) {
            return $false
        }
        $ancestor = $ancestor.Parent
    }
    return [object]::ReferenceEquals($ancestor, $SourceAst)
}

function Test-PrivateMarkerIfConditionIsNullOrWhiteSpaceVariable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.IfStatementAst]$IfStatement,
        [Parameter(Mandatory = $true)]
        [string]$VariableName
    )

    if (@($IfStatement.Clauses).Count -ne 1 -or
        $null -ne $IfStatement.ElseClause) {
        return $false
    }
    $conditionElements = @($IfStatement.Clauses[0].Item1.PipelineElements)
    if ($conditionElements.Count -ne 1 -or
        $conditionElements[0] -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $conditionElements[0].Expression -isnot
            [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        return $false
    }
    $conditionCall = $conditionElements[0].Expression
    $conditionArguments = @($conditionCall.Arguments)
    return $conditionCall.Static -and
        $conditionCall.Expression -is
            [System.Management.Automation.Language.TypeExpressionAst] -and
        $conditionCall.Expression.TypeName.FullName -ieq 'string' -and
        $conditionCall.Member -is
            [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $conditionCall.Member.Value -ieq 'IsNullOrWhiteSpace' -and
        $conditionArguments.Count -eq 1 -and
        $conditionArguments[0] -is
            [System.Management.Automation.Language.VariableExpressionAst] -and
        $conditionArguments[0].VariablePath.UserPath -ceq $VariableName
}

function Test-PrivateMarkerScriptRootInitializationIsTrusted {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ScriptBlockAst]$SourceAst,
        [int]$BeforeOffset
    )

    $assignments = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    (Test-PrivateMarkerAssignmentTargetsVariable `
                        -Assignment $node `
                        -VariableName 'scriptRoot') -and
                    $node.Extent.StartOffset -lt $BeforeOffset -and
                    -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                        -Command $node)
            },
            $true
        ) |
            Sort-Object { $_.Extent.StartOffset }
    )
    if ($assignments.Count -lt 1 -or $assignments.Count -gt 2) {
        return $false
    }

    $primary = $assignments[0]
    if ($primary.Left -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        $primary.Left.VariablePath.UserPath -cne 'scriptRoot' -or
        [string]$primary.Operator -ne 'Equals' -or
        -not (Test-PrivateMarkerAstIsDirectTopLevelStatement `
            -Node $primary `
            -SourceAst $SourceAst) -or
        $primary.Right -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $primary.Right.Expression -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        $primary.Right.Expression.VariablePath.UserPath -cne 'PSScriptRoot') {
        return $false
    }
    if ($assignments.Count -eq 1) {
        return $true
    }

    $fallback = $assignments[1]
    if ($fallback.Left -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        $fallback.Left.VariablePath.UserPath -cne 'scriptRoot' -or
        [string]$fallback.Operator -ne 'Equals') {
        return $false
    }
    $statementBlock = $fallback.Parent
    if ($statementBlock -isnot
            [System.Management.Automation.Language.StatementBlockAst] -or
        @($statementBlock.Statements).Count -ne 1 -or
        $statementBlock.Parent -isnot
            [System.Management.Automation.Language.IfStatementAst]) {
        return $false
    }
    $ifStatement = $statementBlock.Parent
    if (-not [object]::ReferenceEquals(
            $ifStatement.Clauses[0].Item2,
            $statementBlock
        ) -or
        $ifStatement.Parent -isnot
            [System.Management.Automation.Language.NamedBlockAst] -or
        -not [object]::ReferenceEquals(
            $ifStatement.Parent.Parent,
            $SourceAst
        ) -or
        -not (Test-PrivateMarkerIfConditionIsNullOrWhiteSpaceVariable `
            -IfStatement $ifStatement `
            -VariableName 'scriptRoot')) {
        return $false
    }

    if ($fallback.Right -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $fallback.Right.Expression -isnot
            [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        return $false
    }
    $fallbackArguments = @($fallback.Right.Expression.Arguments)
    if ($fallbackArguments.Count -ne 1 -or
        -not (Test-PrivateMarkerStaticPathInvocation `
            -ValueAst $fallback.Right `
            -MethodName 'GetDirectoryName' `
            -ExpectedArguments $fallbackArguments)) {
        return $false
    }
    $invocationPath = $fallbackArguments[0]
    return $invocationPath -is
            [System.Management.Automation.Language.MemberExpressionAst] -and
        $invocationPath.Member -is
            [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $invocationPath.Member.Value -ceq 'Path' -and
        $invocationPath.Expression -is
            [System.Management.Automation.Language.MemberExpressionAst] -and
        $invocationPath.Expression.Member -is
            [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $invocationPath.Expression.Member.Value -ceq 'MyCommand' -and
        $invocationPath.Expression.Expression -is
            [System.Management.Automation.Language.VariableExpressionAst] -and
        $invocationPath.Expression.Expression.VariablePath.UserPath -ceq
            'MyInvocation'
}

function Test-PrivateMarkerPathAssignmentIsAllowedDefaultInitialization {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.AssignmentStatementAst]$Assignment,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ScriptBlockAst]$SourceAst
    )

    if ($Assignment.Left -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        $Assignment.Left.VariablePath.UserPath -cne 'Path' -or
        [string]$Assignment.Operator -ne 'Equals' -or
        $Assignment.Right -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $Assignment.Right.Expression -isnot
            [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        return $false
    }

    # 公開scriptの既定値補完だけを厳密に許可する。任意のpre-root代入を
    # 許すと、見た目が正しい GetFullPath($Path) へ攻撃者指定rootを注入できる。
    $pathArguments = @($Assignment.Right.Expression.Arguments)
    if ($pathArguments.Count -ne 1 -or
        $pathArguments[0] -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        $pathArguments[0].VariablePath.UserPath -cne 'scriptRoot' -or
        -not (Test-PrivateMarkerStaticPathInvocation `
            -ValueAst $Assignment.Right `
            -MethodName 'GetDirectoryName' `
            -ExpectedArguments $pathArguments)) {
        return $false
    }

    $statementBlock = $Assignment.Parent
    if ($statementBlock -isnot
            [System.Management.Automation.Language.StatementBlockAst] -or
        @($statementBlock.Statements).Count -ne 1 -or
        $statementBlock.Parent -isnot
            [System.Management.Automation.Language.IfStatementAst]) {
        return $false
    }
    $ifStatement = $statementBlock.Parent
    if (-not [object]::ReferenceEquals(
            $ifStatement.Clauses[0].Item2,
            $statementBlock
        ) -or
        $ifStatement.Parent -isnot
            [System.Management.Automation.Language.NamedBlockAst] -or
        -not [object]::ReferenceEquals(
            $ifStatement.Parent.Parent,
            $SourceAst
        ) -or
        -not (Test-PrivateMarkerIfConditionIsNullOrWhiteSpaceVariable `
            -IfStatement $ifStatement `
            -VariableName 'Path')) {
        return $false
    }
    return Test-PrivateMarkerScriptRootInitializationIsTrusted `
        -SourceAst $SourceAst `
        -BeforeOffset $Assignment.Extent.StartOffset
}

function Test-PrivateMarkerFunctionVariableHasPriorLocalBinding {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.VariableExpressionAst]$Variable,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.FunctionDefinitionAst]$Function
    )

    $rawName = $Variable.VariablePath.UserPath
    if ($rawName -match
        '^(?i)(?:(?:variable):)*(?:local|private):') {
        # 明示local/private scopeは親script bindingへ解決されない。
        return $true
    }
    if (Test-PrivateMarkerVariableEscapesDefinitionScope -Name $rawName) {
        return $false
    }
    $variableName = ConvertTo-PrivateMarkerVariableName -Name $rawName

    # function declaration形式とbody内param block形式の両方をlocal bindingとして扱う。
    $parameters = @(
        @($Function.Parameters) +
            @(
                if ($null -ne $Function.Body.ParamBlock) {
                    @($Function.Body.ParamBlock.Parameters)
                }
            ) |
            Where-Object { $null -ne $_ }
    )
    foreach ($parameter in $parameters) {
        if ((ConvertTo-PrivateMarkerVariableName `
                -Name $parameter.Name.VariablePath.UserPath) -ieq
            $variableName) {
            return $true
        }
    }

    # unqualified [ref] は、同じfunction scopeに先行bindingがなければ動的scopeの
    # 親変数を直接参照する。必ず実行されるsource直下の先行assignmentだけを認める。
    $priorAssignments = @(
        $Function.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Extent.EndOffset -le $Variable.Extent.StartOffset -and
                    (Test-PrivateMarkerAstOwnedByFunction `
                        -Node $node `
                        -Function $Function) -and
                    (Test-PrivateMarkerAstIsDirectTopLevelStatement `
                        -Node $node `
                        -SourceAst $Function.Body)
            },
            $true
        )
    )
    foreach ($assignment in $priorAssignments) {
        if (Test-PrivateMarkerAssignmentDirectlyBindsVariable `
            -Assignment $assignment `
            -VariableName $variableName) {
            return $true
        }
    }
    return $false
}

function Test-PrivateMarkerStaticPathInvocation {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$ValueAst,
        [Parameter(Mandatory = $true)]
        [string]$MethodName,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast[]]$ExpectedArguments
    )

    # PowerShell command resolutionはfunction/aliasでshadow可能なため、bootstrap
    # path構築ではSystem.IO.Pathのstatic methodだけを正確なAST形状で許可する。
    if ($ValueAst -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $ValueAst.Expression -isnot
            [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        return $false
    }
    $invocation = $ValueAst.Expression
    if (-not $invocation.Static -or
        $invocation.Expression -isnot
            [System.Management.Automation.Language.TypeExpressionAst] -or
        $invocation.Expression.TypeName.FullName -ine 'System.IO.Path' -or
        $invocation.Member -isnot
            [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $invocation.Member.Value -ine $MethodName) {
        return $false
    }

    $actualArguments = @($invocation.Arguments)
    if ($actualArguments.Count -ne $ExpectedArguments.Count) {
        return $false
    }
    for ($index = 0; $index -lt $actualArguments.Count; $index++) {
        if (-not [object]::ReferenceEquals(
                $actualArguments[$index],
                $ExpectedArguments[$index]
            )) {
            return $false
        }
    }
    return $true
}

function Test-PrivateMarkerCommandUsesScriptInvocationOperator {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    return @('Dot', 'Ampersand') -contains
        [string]$Command.InvocationOperator
}

function Test-PrivateMarkerAllowedBootstrapDotSource {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ScriptBlockAst]$SourceAst
    )

    if ([string]$Command.InvocationOperator -ne 'Dot' -or
        @($Command.CommandElements).Count -ne 1 -or
        $Command.CommandElements[0] -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        -not (Test-PrivateMarkerAstIsDirectTopLevelStatement `
            -Node $Command `
            -SourceAst $SourceAst) -or
        $Command.Parent -isnot
            [System.Management.Automation.Language.PipelineAst] -or
        @($Command.Parent.PipelineElements).Count -ne 1) {
        return $false
    }
    $variableName = $Command.CommandElements[0].VariablePath.UserPath
    $expectedRelativePath = switch -Exact ($variableName) {
        'firstInvocationPolicy' {
            'scripts/private-marker-first-invocation-policy.ps1'
            break
        }
        'processBoundary' {
            'scripts/private-marker-process.ps1'
            break
        }
        default {
            return $false
        }
    }

    # 許可するdot-source変数は、source直下で一度だけ固定rootとliteral
    # repo-relative pathから構築し、再代入や任意script pathへの差替えを拒否する。
    $indirectAssignments = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Extent.StartOffset -lt $Command.Extent.StartOffset -and
                    -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                        -Command $node) -and
                    $node.Left -isnot
                        [System.Management.Automation.Language.VariableExpressionAst]
            },
            $true
        )
    )
    $instanceInvocations = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    -not $node.Static -and
                    $node.Extent.StartOffset -lt $Command.Extent.StartOffset -and
                    -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                        -Command $node)
            },
            $true
        )
    )
    $referenceEscapes = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.ConvertExpressionAst] -and
                    $node.Type.TypeName.FullName -ieq 'ref' -and
                    $node.Extent.StartOffset -lt $Command.Extent.StartOffset -and
                    -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                        -Command $node)
            },
            $true
        )
    )
    $psVariableReferences = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.MemberExpressionAst] -and
                    (Test-PrivateMarkerAstIsSessionStatePsVariable -Ast $node) -and
                    $node.Extent.StartOffset -lt $Command.Extent.StartOffset -and
                    -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                        -Command $node)
            },
            $true
        )
    )
    if ($indirectAssignments.Count -gt 0 -or
        $instanceInvocations.Count -gt 0 -or
        $referenceEscapes.Count -gt 0 -or
        $psVariableReferences.Count -gt 0) {
        # tuple/member mutation、PSVariable.Set、[ref] escapeはstatic provenanceを
        # 破壊できる。PSVariable table自体のeager alias化も含め、承認bootstrap
        # より前では用途を問わず保守的に拒否する。
        return $false
    }

    $assignments = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    (Test-PrivateMarkerAssignmentTargetsVariable `
                        -Assignment $node `
                        -VariableName $variableName) -and
                    $node.Extent.StartOffset -lt $Command.Extent.StartOffset -and
                    -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                        -Command $node)
            },
            $true
        )
    )
    if ($assignments.Count -ne 1 -or
        $assignments[0].Left.VariablePath.UserPath -ine $variableName -or
        [string]$assignments[0].Operator -ne 'Equals' -or
        -not (Test-PrivateMarkerAstIsDirectTopLevelStatement `
            -Node $assignments[0] `
            -SourceAst $SourceAst)) {
        return $false
    }

    # rootもsource直下の単一代入に固定する。scope付き代入や再代入を数え漏らすと、
    # 正しい見た目のbuilderへ任意rootを注入できるためcanonical名で集計する。
    $rootAssignments = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    (Test-PrivateMarkerAssignmentTargetsVariable `
                        -Assignment $node `
                        -VariableName 'root') -and
                    $node.Extent.StartOffset -lt $Command.Extent.StartOffset -and
                    -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                        -Command $node)
            },
            $true
        )
    )
    if ($rootAssignments.Count -ne 1 -or
        $rootAssignments[0].Left.VariablePath.UserPath -ine 'root' -or
        [string]$rootAssignments[0].Operator -ne 'Equals' -or
        $rootAssignments[0].Extent.StartOffset -ge
            $assignments[0].Extent.StartOffset -or
        -not (Test-PrivateMarkerAstIsDirectTopLevelStatement `
            -Node $rootAssignments[0] `
            -SourceAst $SourceAst)) {
        return $false
    }

    $pathAssignmentsBeforeRoot = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    (Test-PrivateMarkerAssignmentTargetsVariable `
                        -Assignment $node `
                        -VariableName 'Path') -and
                    $node.Extent.StartOffset -lt
                        $rootAssignments[0].Extent.StartOffset -and
                    -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                        -Command $node)
            },
            $true
        )
    )
    foreach ($pathAssignment in $pathAssignmentsBeforeRoot) {
        if (-not (Test-PrivateMarkerPathAssignmentIsAllowedDefaultInitialization `
            -Assignment $pathAssignment `
            -SourceAst $SourceAst)) {
            return $false
        }
    }

    $rootRight = $rootAssignments[0].Right
    $rootArguments = @(
        $rootRight.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.VariablePath.UserPath -ieq 'Path'
            },
            $true
        )
    )
    if ($rootArguments.Count -ne 1 -or
        -not (Test-PrivateMarkerStaticPathInvocation `
            -ValueAst $rootRight `
            -MethodName 'GetFullPath' `
            -ExpectedArguments $rootArguments)) {
        return $false
    }

    $pathRight = $assignments[0].Right
    if ($pathRight -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $pathRight.Expression -isnot
            [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        return $false
    }
    $pathArguments = @($pathRight.Expression.Arguments)
    if ($pathArguments.Count -ne 2 -or
        $pathArguments[0] -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        $pathArguments[0].VariablePath.UserPath -ine 'root' -or
        -not (Test-PrivateMarkerStaticPathInvocation `
            -ValueAst $pathRight `
            -MethodName 'Combine' `
            -ExpectedArguments $pathArguments)) {
        return $false
    }
    $relativePath = Get-PrivateMarkerStaticAstValue -ValueAst $pathArguments[1]
    return $relativePath.Resolved -and
        $relativePath.Value -ceq $expectedRelativePath
}

function ConvertTo-PrivateMarkerTypeName {
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    $normalized = $Name.Trim()
    if ($normalized.Length -ge 2 -and
        $normalized[0] -eq [char]91 -and
        $normalized[$normalized.Length - 1] -eq [char]93) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2)
    }
    return $normalized.Trim()
}

function Test-PrivateMarkerAstReferencesRiskyType {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$RiskyTypeNames,
        [AllowNull()]
        [System.Management.Automation.Language.FunctionDefinitionAst]$FunctionOwner =
            $null
    )

    $typeReferences = @(
        $Ast.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.TypeExpressionAst] -or
                    $node -is
                        [System.Management.Automation.Language.TypeConstraintAst] -or
                    $node -is
                        [System.Management.Automation.Language.ConvertExpressionAst]
            },
            $true
        )
    )
    foreach ($reference in $typeReferences) {
        if ($null -ne $FunctionOwner -and
            -not (Test-PrivateMarkerAstOwnedByFunction `
                -Node $reference `
                -Function $FunctionOwner)) {
            continue
        }
        $typeName = if ($reference -is
            [System.Management.Automation.Language.TypeExpressionAst]) {
            $reference.TypeName.FullName
        }
        elseif ($reference -is
            [System.Management.Automation.Language.TypeConstraintAst]) {
            $reference.TypeName.FullName
        }
        else {
            $reference.Type.TypeName.FullName
        }
        if ($RiskyTypeNames.Contains(
                (ConvertTo-PrivateMarkerTypeName -Name $typeName)
            )) {
            return $true
        }
    }
    return $false
}

function Test-PrivateMarkerInvokeMemberIsRisky {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.InvokeMemberExpressionAst]$Invocation,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$RiskyTypeNames
    )

    # member名がdynamicならInvoke系へ解決し得る。static名でもInvoke familyと
    # reflection constructorは任意script/type初期化へ到達するため拒否する。
    $memberName = if ($Invocation.Member -is
        [System.Management.Automation.Language.StringConstantExpressionAst]) {
        [string]$Invocation.Member.Value
    }
    else {
        ''
    }
    $staticTypeName = if ($Invocation.Expression -is
        [System.Management.Automation.Language.TypeExpressionAst]) {
        ConvertTo-PrivateMarkerTypeName `
            -Name $Invocation.Expression.TypeName.FullName
    }
    else {
        ''
    }
    $scriptBlockCreate = (
        $memberName -ieq 'Create' -and
        $staticTypeName -in @(
            'scriptblock',
            'System.Management.Automation.ScriptBlock'
        )
    )
    $dynamicStaticCreate = (
        $memberName -ieq 'Create' -and
        $Invocation.Static -and
        $Invocation.Expression -isnot
            [System.Management.Automation.Language.TypeExpressionAst]
    )
    if ([string]::IsNullOrWhiteSpace($memberName) -or
        $memberName -match '(?i)invoke' -or
        $memberName -in @(
            'GetCommand',
            'GetScriptBlock',
            'NewScriptBlock'
        ) -or
        $scriptBlockCreate -or
        $dynamicStaticCreate -or
        $memberName -ieq 'CreateInstance' -or
        ($memberName -ieq 'new' -and
            $Invocation.Expression -isnot
                [System.Management.Automation.Language.TypeExpressionAst])) {
        return $true
    }
    return Test-PrivateMarkerAstReferencesRiskyType `
        -Ast $Invocation `
        -RiskyTypeNames $RiskyTypeNames
}

function Test-PrivateMarkerCommandConstructsRiskyType {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$ConstructorCallableNames,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$RiskyTypeNames
    )

    $commandName = ConvertTo-PrivateMarkerCallableName `
        -Name $Command.GetCommandName()
    if (-not $ConstructorCallableNames.Contains($commandName)) {
        return $false
    }

    # New-Objectのtypeがdynamicならrisky classへ解決し得るためfail closed。
    $typeResult = Get-PrivateMarkerStaticCommandArgument `
        -Command $Command `
        -ParameterNames @('TypeName') `
        -PositionalIndex 0
    if (-not $typeResult.Resolved) {
        return $true
    }
    return $RiskyTypeNames.Contains(
        (ConvertTo-PrivateMarkerTypeName -Name $typeResult.Value)
    )
}

function Test-FirstPrivateMarkerProcessInvocationIsBinaryTransport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [string]$RequiredOuterCommandPattern = ''
    )

    # line/regex ではなく AST ownership を検証する。binary fixture の代入右辺は
    # helper 1 callだけを直接所有し、先行 eager callやnested callを許さない。
    $tokens = $null
    $parseErrors = $null
    $sourceAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        return $false
    }

    $binaryAssignments = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq 'binaryPipeResult'
            },
            $true
        )
    )
    if ($binaryAssignments.Count -ne 1 -or
        $binaryAssignments[0].Right -isnot
            [System.Management.Automation.Language.PipelineAst]) {
        return $false
    }

    $pipelineElements = @($binaryAssignments[0].Right.PipelineElements)
    if ($pipelineElements.Count -ne 1 -or
        $pipelineElements[0] -isnot
            [System.Management.Automation.Language.CommandAst] -or
        (ConvertTo-PrivateMarkerCallableName `
            -Name $pipelineElements[0].GetCommandName()) -ine
                'Invoke-PrivateMarkerProcess') {
        return $false
    }
    $binaryOuterCommand = $pipelineElements[0]
    if (-not [string]::IsNullOrWhiteSpace($RequiredOuterCommandPattern) -and
        $binaryOuterCommand.Extent.Text -notmatch $RequiredOuterCommandPattern) {
        return $false
    }

    $allHelperCalls = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.CommandAst] -and
                    (ConvertTo-PrivateMarkerCallableName `
                        -Name $node.GetCommandName()) -ieq
                            'Invoke-PrivateMarkerProcess'
            },
            $true
        )
    )
    $nestedCalls = @(
        $binaryAssignments[0].Right.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.CommandAst] -and
                    (ConvertTo-PrivateMarkerCallableName `
                        -Name $node.GetCommandName()) -ieq
                            'Invoke-PrivateMarkerProcess'
            },
            $true
        )
    )
    if ($nestedCalls.Count -ne 1 -or
        (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
            -Command $binaryOuterCommand)) {
        return $false
    }

    $functionDefinitions = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.StartOffset
            },
            $true
        )
    )
    foreach ($functionDefinition in $functionDefinitions) {
        if ((ConvertTo-PrivateMarkerCallableName `
                -Name $functionDefinition.Name) -ieq
                    'Invoke-PrivateMarkerProcess' -and
            -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                -Command $functionDefinition)) {
            # raw target名のtop-level function定義自体がhelperをshadowする。
            return $false
        }
    }
    $allCommands = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                    [System.Management.Automation.Language.CommandAst]
            },
            $true
        )
    )
    $riskyCallableNames = (
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    )
    foreach ($riskyName in @(
        'Invoke-PrivateMarkerProcess',
        'Invoke-Expression',
        'iex',
        'Invoke-Command',
        'icm',
        'Import-Alias',
        'ipal',
        'Import-Module',
        'ipmo',
        'Remove-Module',
        'rmo',
        'Set-Variable',
        'sv',
        'New-Variable',
        'nv',
        'Clear-Variable',
        'clv',
        'Remove-Variable',
        'rv'
    )) {
        [void]$riskyCallableNames.Add($riskyName)
    }
    $constructorCallableNames = (
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    )
    [void]$constructorCallableNames.Add('New-Object')
    $providerMutationTargets = @(
        'Set-Item',
        'si',
        'New-Item',
        'ni',
        'Set-Content',
        'sc',
        'Add-Content',
        'ac',
        'Clear-Item',
        'cli',
        'Copy-Item',
        'cpi',
        'cp',
        'copy',
        'Move-Item',
        'mi',
        'mv',
        'move',
        'Rename-Item',
        'rni',
        'ren',
        'Remove-Item',
        'ri',
        'rm',
        'rmdir',
        'del',
        'erase',
        'rd'
    )
    $bootstrapVariableNames = @(
        'Path',
        'scriptRoot',
        'root',
        'firstInvocationPolicy',
        'processBoundary'
    )
    $riskyTypeNames = (
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    )
    $typeDefinitions = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.TypeDefinitionAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.StartOffset
            },
            $true
        )
    )

    # callable alias、wrapper、risky type、constructor/conversionを相互に
    # fixed pointまで伝播する。型をparameter bindingで間接生成する関数や、
    # risky classをさらに生成するclassも一段ずつ取りこぼさない。
    do {
        $riskySetChanged = $false

        foreach ($command in $allCommands) {
            if ($command.Extent.StartOffset -ge
                $binaryOuterCommand.Extent.EndOffset) {
                continue
            }
            $alias = Get-PrivateMarkerAliasDefinition -Command $command
            if (-not $alias.IsAliasCommand -or -not $alias.Resolved) {
                continue
            }
            if ($riskyCallableNames.Contains($alias.Target) -and
                $riskyCallableNames.Add($alias.Name)) {
                $riskySetChanged = $true
            }
            if ((Test-PrivateMarkerNameIsScriptPath `
                    -Name $alias.Target) -and
                $riskyCallableNames.Add($alias.Name)) {
                $riskySetChanged = $true
            }
            if ($constructorCallableNames.Contains($alias.Target) -and
                $constructorCallableNames.Add($alias.Name)) {
                $riskySetChanged = $true
            }
            if ($providerMutationTargets -contains $alias.Target -and
                $riskyCallableNames.Add($alias.Name)) {
                $riskySetChanged = $true
            }
        }

        foreach ($functionDefinition in $functionDefinitions) {
            $functionName = ConvertTo-PrivateMarkerCallableName `
                -Name $functionDefinition.Name
            if ($riskyCallableNames.Contains($functionName)) {
                continue
            }

            $ownedCommands = @(
                $functionDefinition.FindAll(
                    {
                        param($node)
                        return $node -is
                                [System.Management.Automation.Language.CommandAst] -and
                            (Test-PrivateMarkerAstOwnedByFunction `
                                -Node $node `
                                -Function $functionDefinition)
                    },
                    $true
                )
            )
            $functionIsRisky = $false
            $persistentHelperDefinitions = @(
                $functionDefinition.FindAll(
                    {
                        param($node)
                        return $node -is
                                [System.Management.Automation.Language.FunctionDefinitionAst] -and
                            -not [object]::ReferenceEquals(
                                $node,
                                $functionDefinition
                            ) -and
                            (Test-PrivateMarkerAstOwnedByFunction `
                                -Node $node `
                                -Function $functionDefinition) -and
                            (Test-PrivateMarkerFunctionDefinitionEscapesDefinitionScope `
                                -Function $node) -and
                            (ConvertTo-PrivateMarkerCallableName `
                                -Name $node.Name) -ieq
                                    'Invoke-PrivateMarkerProcess'
                    },
                    $true
                )
            )
            if ($persistentHelperDefinitions.Count -gt 0) {
                # wrapperがscript/global helperを定義すると、wrapper終了後の
                # binary transport callまで同じ名前を永続shadowする。
                $functionIsRisky = $true
            }
            $ownedBootstrapMutations = @(
                $functionDefinition.FindAll(
                    {
                        param($node)
                        if (-not (Test-PrivateMarkerAstOwnedByFunction `
                                -Node $node `
                                -Function $functionDefinition)) {
                            return $false
                        }
                        if ($node -is
                                [System.Management.Automation.Language.ConvertExpressionAst] -and
                            $node.Type.TypeName.FullName -ieq 'ref') {
                            foreach ($bootstrapVariableName in
                                $bootstrapVariableNames) {
                                $protectedReferences = @(
                                    $node.FindAll(
                                        {
                                            param($child)
                                            return $child -is
                                                    [System.Management.Automation.Language.VariableExpressionAst] -and
                                                (ConvertTo-PrivateMarkerVariableName `
                                                    -Name $child.VariablePath.UserPath) -ieq
                                                        $bootstrapVariableName
                                        },
                                        $true
                                    )
                                )
                                foreach ($protectedReference in
                                    $protectedReferences) {
                                    if ((Test-PrivateMarkerVariableEscapesDefinitionScope `
                                            -Name $protectedReference.VariablePath.UserPath) -or
                                        -not (Test-PrivateMarkerFunctionVariableHasPriorLocalBinding `
                                            -Variable $protectedReference `
                                            -Function $functionDefinition)) {
                                        return $true
                                    }
                                }
                            }
                            return $false
                        }
                        if ($node -isnot
                            [System.Management.Automation.Language.AssignmentStatementAst]) {
                            return $false
                        }
                        if (Test-PrivateMarkerAstIsSessionStatePsVariable `
                            -Ast $node.Right) {
                            # PSVariable tableをlocal aliasへ退避してからGet/Setする
                            # 二段経路も、wrapperが実行される場合はfail closedにする。
                            return $true
                        }
                        foreach ($bootstrapVariableName in
                            $bootstrapVariableNames) {
                            $externalTargets = @(
                                $node.Left.FindAll(
                                    {
                                        param($target)
                                        return $target -is
                                                [System.Management.Automation.Language.VariableExpressionAst] -and
                                            (Test-PrivateMarkerVariableEscapesDefinitionScope `
                                                -Name $target.VariablePath.UserPath) -and
                                            (ConvertTo-PrivateMarkerVariableName `
                                                -Name $target.VariablePath.UserPath) -ieq
                                                    $bootstrapVariableName
                                    },
                                    $true
                                )
                            )
                            if ($externalTargets.Count -gt 0) {
                                return $true
                            }
                        }
                        return $false
                    },
                    $true
                )
            )
            if ($ownedBootstrapMutations.Count -gt 0) {
                # 定義だけなら遅延扱いだが、先行呼出しされたwrapper内のprotected
                # assignmentと[ref] escapeは直接実行と同様に拒否する。
                $functionIsRisky = $true
            }
            if (-not $functionIsRisky) {
                $ownedExecutionContextReferences = @(
                    $functionDefinition.FindAll(
                        {
                            param($node)
                            return $node -is
                                    [System.Management.Automation.Language.VariableExpressionAst] -and
                                (Test-PrivateMarkerAstOwnedByFunction `
                                    -Node $node `
                                    -Function $functionDefinition) -and
                                (ConvertTo-PrivateMarkerVariableName `
                                    -Name $node.VariablePath.UserPath) -ieq
                                    'ExecutionContext' -and
                                -not (
                                    Test-PrivateMarkerExecutionContextReferenceIsDirectPsVariableReceiver `
                                        -Variable $node
                                )
                        },
                        $true
                    )
                )
                if ($ownedExecutionContextReferences.Count -gt 0) {
                    # ExecutionContextはPSVariable tableやInvokeCommandへのaliasを
                    # 任意段で作れる。先行実行wrapper内では用途を推測せず拒否する。
                    $functionIsRisky = $true
                }
            }
            foreach ($ownedCommand in $ownedCommands) {
                if ($functionIsRisky) {
                    break
                }
                $ownedName = ConvertTo-PrivateMarkerCallableName `
                    -Name $ownedCommand.GetCommandName()
                $unresolvedOperator =
                    [string]::IsNullOrWhiteSpace($ownedName)
                $scriptInvocationOperator =
                    Test-PrivateMarkerCommandUsesScriptInvocationOperator `
                        -Command $ownedCommand
                $scriptPathCommand = Test-PrivateMarkerNameIsScriptPath `
                    -Name $ownedCommand.GetCommandName()
                $alias = Get-PrivateMarkerAliasDefinition `
                    -Command $ownedCommand
                $referenceRisk = Get-PrivateMarkerFunctionReferenceRisk `
                    -Command $ownedCommand `
                    -RiskyCallableNames $riskyCallableNames
                $commandReadsBootstrapVariable = $false
                foreach ($bootstrapVariableName in
                    $bootstrapVariableNames) {
                    if (Test-PrivateMarkerCommandReadsVariable `
                        -Command $ownedCommand `
                        -VariableName $bootstrapVariableName) {
                        $commandReadsBootstrapVariable = $true
                        break
                    }
                }
                $commandReadsExecutionContext =
                    Test-PrivateMarkerCommandReadsVariable `
                        -Command $ownedCommand `
                        -VariableName 'ExecutionContext'
                if ($riskyCallableNames.Contains($ownedName) -or
                    $unresolvedOperator -or
                    $scriptInvocationOperator -or
                    $scriptPathCommand -or
                    $commandReadsBootstrapVariable -or
                    $commandReadsExecutionContext -or
                    ($alias.IsAliasCommand -and
                        $alias.Resolved -and
                        $alias.Name -ieq 'Invoke-PrivateMarkerProcess' -and
                        (Test-PrivateMarkerAliasMutationEscapesDefinitionScope `
                            -Command $ownedCommand)) -or
                    ($alias.IsAliasCommand -and -not $alias.Resolved) -or
                    @('Risky', 'Unresolved') -contains $referenceRisk -or
                    (Test-PrivateMarkerCommandConstructsRiskyType `
                        -Command $ownedCommand `
                        -ConstructorCallableNames $constructorCallableNames `
                        -RiskyTypeNames $riskyTypeNames)) {
                    $functionIsRisky = $true
                    break
                }
            }
            if (-not $functionIsRisky) {
                $ownedInvokeMembers = @(
                    $functionDefinition.FindAll(
                        {
                            param($node)
                            return $node -is
                                    [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                                (Test-PrivateMarkerAstOwnedByFunction `
                                    -Node $node `
                                    -Function $functionDefinition)
                        },
                        $true
                    )
                )
                foreach ($invocation in $ownedInvokeMembers) {
                    $memberAccessesBootstrapVariable = $false
                    foreach ($bootstrapVariableName in
                        $bootstrapVariableNames) {
                        if ((Test-PrivateMarkerMemberReadsVariable `
                                -Invocation $invocation `
                                -VariableName $bootstrapVariableName) -or
                            (Test-PrivateMarkerMemberWritesVariable `
                                -Invocation $invocation `
                                -VariableName $bootstrapVariableName)) {
                            $memberAccessesBootstrapVariable = $true
                            break
                        }
                    }
                    $memberReadsScriptVariable = (
                        (Test-PrivateMarkerAstIsSessionStatePsVariable `
                            -Ast $invocation.Expression) -and
                        $invocation.Member -is
                            [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $invocation.Member.Value -imatch '^(?:Get|GetValue)$'
                    )
                    if ($memberAccessesBootstrapVariable -or
                        $memberReadsScriptVariable -or
                        (Test-PrivateMarkerInvokeMemberIsRisky `
                            -Invocation $invocation `
                            -RiskyTypeNames $riskyTypeNames)) {
                        # protected PSVariable accessと既知のdynamic/risky memberだけを
                        # wrapperへ伝播し、無関係なinstance methodは誤検知しない。
                        $functionIsRisky = $true
                        break
                    }
                }
            }
            if (-not $functionIsRisky) {
                $ownedFunctionReferences = @(
                    $functionDefinition.FindAll(
                        {
                            param($node)
                            return $node -is
                                    [System.Management.Automation.Language.VariableExpressionAst] -and
                                (Test-PrivateMarkerAstOwnedByFunction `
                                    -Node $node `
                                    -Function $functionDefinition) -and
                                $node.VariablePath.UserPath -match
                                    '^(?i:function:)'
                        },
                        $true
                    )
                )
                foreach ($reference in $ownedFunctionReferences) {
                    if (Test-PrivateMarkerNameMatchesRiskyCallable `
                        -Name $reference.VariablePath.UserPath `
                        -RiskyCallableNames $riskyCallableNames) {
                        $functionIsRisky = $true
                        break
                    }
                }
            }
            if (-not $functionIsRisky -and
                (Test-PrivateMarkerAstReferencesRiskyType `
                    -Ast $functionDefinition `
                    -RiskyTypeNames $riskyTypeNames `
                    -FunctionOwner $functionDefinition)) {
                $functionIsRisky = $true
            }
            if ($functionIsRisky -and
                $riskyCallableNames.Add($functionName)) {
                $riskySetChanged = $true
            }
        }

        foreach ($typeDefinition in $typeDefinitions) {
            $typeName = ConvertTo-PrivateMarkerTypeName `
                -Name $typeDefinition.Name
            if ($riskyTypeNames.Contains($typeName)) {
                continue
            }

            $typeIsRisky = $false
            $typeBootstrapMutations = @(
                $typeDefinition.FindAll(
                    {
                        param($node)
                        if ($node -is
                                [System.Management.Automation.Language.ConvertExpressionAst] -and
                            $node.Type.TypeName.FullName -ieq 'ref') {
                            foreach ($bootstrapVariableName in
                                $bootstrapVariableNames) {
                                $escapedVariables = @(
                                    $node.FindAll(
                                        {
                                            param($child)
                                            return $child -is
                                                    [System.Management.Automation.Language.VariableExpressionAst] -and
                                                (Test-PrivateMarkerVariableEscapesDefinitionScope `
                                                    -Name $child.VariablePath.UserPath) -and
                                                (ConvertTo-PrivateMarkerVariableName `
                                                    -Name $child.VariablePath.UserPath) -ieq
                                                        $bootstrapVariableName
                                        },
                                        $true
                                    )
                                )
                                if ($escapedVariables.Count -gt 0) {
                                    return $true
                                }
                            }
                            return $false
                        }
                        if ($node -isnot
                            [System.Management.Automation.Language.AssignmentStatementAst]) {
                            return $false
                        }
                        if (Test-PrivateMarkerAstIsSessionStatePsVariable `
                            -Ast $node.Right) {
                            return $true
                        }
                        foreach ($bootstrapVariableName in
                            $bootstrapVariableNames) {
                            $externalTargets = @(
                                $node.Left.FindAll(
                                    {
                                        param($target)
                                        return $target -is
                                                [System.Management.Automation.Language.VariableExpressionAst] -and
                                            (Test-PrivateMarkerVariableEscapesDefinitionScope `
                                                -Name $target.VariablePath.UserPath) -and
                                            (ConvertTo-PrivateMarkerVariableName `
                                                -Name $target.VariablePath.UserPath) -ieq
                                                    $bootstrapVariableName
                                    },
                                    $true
                                )
                            )
                            if ($externalTargets.Count -gt 0) {
                                return $true
                            }
                        }
                        return $false
                    },
                    $true
                )
            )
            if ($typeBootstrapMutations.Count -gt 0) {
                # class本体は定義時には実行しない。constructor/static member経由で
                # 先行実行された場合だけ、risky type伝播でbootstrap破壊を拒否する。
                $typeIsRisky = $true
            }
            if (-not $typeIsRisky) {
                $typeExecutionContextReferences = @(
                    $typeDefinition.FindAll(
                        {
                            param($node)
                            return $node -is
                                    [System.Management.Automation.Language.VariableExpressionAst] -and
                                (ConvertTo-PrivateMarkerVariableName `
                                    -Name $node.VariablePath.UserPath) -ieq
                                    'ExecutionContext' -and
                                -not (
                                    Test-PrivateMarkerExecutionContextReferenceIsDirectPsVariableReceiver `
                                        -Variable $node
                                )
                        },
                        $true
                    )
                )
                if ($typeExecutionContextReferences.Count -gt 0) {
                    $typeIsRisky = $true
                }
            }
            $typeCommands = @(
                $typeDefinition.FindAll(
                    {
                        param($node)
                        return $node -is
                            [System.Management.Automation.Language.CommandAst]
                    },
                    $true
                )
            )
            foreach ($typeCommand in $typeCommands) {
                if ($typeIsRisky) {
                    break
                }
                $typeCommandName = ConvertTo-PrivateMarkerCallableName `
                    -Name $typeCommand.GetCommandName()
                $unresolvedOperator =
                    [string]::IsNullOrWhiteSpace($typeCommandName)
                $scriptInvocationOperator =
                    Test-PrivateMarkerCommandUsesScriptInvocationOperator `
                        -Command $typeCommand
                $scriptPathCommand = Test-PrivateMarkerNameIsScriptPath `
                    -Name $typeCommand.GetCommandName()
                $alias = Get-PrivateMarkerAliasDefinition -Command $typeCommand
                $referenceRisk = Get-PrivateMarkerFunctionReferenceRisk `
                    -Command $typeCommand `
                    -RiskyCallableNames $riskyCallableNames
                $commandReadsBootstrapVariable = $false
                foreach ($bootstrapVariableName in
                    $bootstrapVariableNames) {
                    if (Test-PrivateMarkerCommandReadsVariable `
                        -Command $typeCommand `
                        -VariableName $bootstrapVariableName) {
                        $commandReadsBootstrapVariable = $true
                        break
                    }
                }
                $commandReadsExecutionContext =
                    Test-PrivateMarkerCommandReadsVariable `
                        -Command $typeCommand `
                        -VariableName 'ExecutionContext'
                if ($riskyCallableNames.Contains($typeCommandName) -or
                    $unresolvedOperator -or
                    $scriptInvocationOperator -or
                    $scriptPathCommand -or
                    $commandReadsBootstrapVariable -or
                    $commandReadsExecutionContext -or
                    ($alias.IsAliasCommand -and
                        $alias.Resolved -and
                        $alias.Name -ieq 'Invoke-PrivateMarkerProcess' -and
                        (Test-PrivateMarkerAliasMutationEscapesDefinitionScope `
                            -Command $typeCommand)) -or
                    ($alias.IsAliasCommand -and -not $alias.Resolved) -or
                    @('Risky', 'Unresolved') -contains $referenceRisk -or
                    (Test-PrivateMarkerCommandConstructsRiskyType `
                        -Command $typeCommand `
                        -ConstructorCallableNames $constructorCallableNames `
                        -RiskyTypeNames $riskyTypeNames)) {
                    $typeIsRisky = $true
                    break
                }
            }
            if (-not $typeIsRisky) {
                $typeInvocations = @(
                    $typeDefinition.FindAll(
                        {
                            param($node)
                            return $node -is
                                [System.Management.Automation.Language.InvokeMemberExpressionAst]
                        },
                        $true
                    )
                )
                foreach ($invocation in $typeInvocations) {
                    $memberAccessesBootstrapVariable = $false
                    foreach ($bootstrapVariableName in
                        $bootstrapVariableNames) {
                        if ((Test-PrivateMarkerMemberReadsVariable `
                                -Invocation $invocation `
                                -VariableName $bootstrapVariableName) -or
                            (Test-PrivateMarkerMemberWritesVariable `
                                -Invocation $invocation `
                                -VariableName $bootstrapVariableName)) {
                            $memberAccessesBootstrapVariable = $true
                            break
                        }
                    }
                    $memberReadsScriptVariable = (
                        (Test-PrivateMarkerAstIsSessionStatePsVariable `
                            -Ast $invocation.Expression) -and
                        $invocation.Member -is
                            [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $invocation.Member.Value -imatch '^(?:Get|GetValue)$'
                    )
                    if ($memberAccessesBootstrapVariable -or
                        $memberReadsScriptVariable -or
                        (Test-PrivateMarkerInvokeMemberIsRisky `
                            -Invocation $invocation `
                            -RiskyTypeNames $riskyTypeNames)) {
                        $typeIsRisky = $true
                        break
                    }
                }
            }
            if (-not $typeIsRisky) {
                $typeFunctionReferences = @(
                    $typeDefinition.FindAll(
                        {
                            param($node)
                            return $node -is
                                    [System.Management.Automation.Language.VariableExpressionAst] -and
                                $node.VariablePath.UserPath -match
                                    '^(?i:function:)'
                        },
                        $true
                    )
                )
                foreach ($reference in $typeFunctionReferences) {
                    if (Test-PrivateMarkerNameMatchesRiskyCallable `
                        -Name $reference.VariablePath.UserPath `
                        -RiskyCallableNames $riskyCallableNames) {
                        $typeIsRisky = $true
                        break
                    }
                }
            }
            if (-not $typeIsRisky -and
                (Test-PrivateMarkerAstReferencesRiskyType `
                    -Ast $typeDefinition `
                    -RiskyTypeNames $riskyTypeNames)) {
                $typeIsRisky = $true
            }
            if ($typeIsRisky -and $riskyTypeNames.Add($typeName)) {
                $riskySetChanged = $true
            }
        }
    } while ($riskySetChanged)

    $earlyRiskyMembers = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.EndOffset
            },
            $true
        ) |
            Where-Object {
                -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                    -Command $_) -and
                (Test-PrivateMarkerInvokeMemberIsRisky `
                    -Invocation $_ `
                    -RiskyTypeNames $riskyTypeNames)
            }
    )
    if ($earlyRiskyMembers.Count -gt 0) {
        return $false
    }

    $earlyRiskyStaticMembers = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.MemberExpressionAst] -and
                    $node -isnot
                        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.EndOffset
            },
            $true
        ) |
            Where-Object {
                -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                    -Command $_) -and
                (Test-PrivateMarkerAstReferencesRiskyType `
                    -Ast $_ `
                    -RiskyTypeNames $riskyTypeNames)
            }
    )
    if ($earlyRiskyStaticMembers.Count -gt 0) {
        # risky classのstatic member参照はtype initializer/getterを実行し得る。
        # 後段で変数やwrapperへ渡されても、provenanceを失う前に拒否する。
        return $false
    }

    $earlyRiskyConversions = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.ConvertExpressionAst] -or
                    ($node -is
                            [System.Management.Automation.Language.BinaryExpressionAst] -and
                        [string]$node.Operator -eq 'As')
                ) -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.EndOffset
            },
            $true
        ) |
            Where-Object {
                -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                    -Command $_) -and
                (Test-PrivateMarkerAstReferencesRiskyType `
                    -Ast $_ `
                    -RiskyTypeNames $riskyTypeNames)
            }
    )
    if ($earlyRiskyConversions.Count -gt 0) {
        return $false
    }

    $earlyRiskyConstructors = @(
        $allCommands |
            Where-Object {
                $_.Extent.StartOffset -lt
                    $binaryOuterCommand.Extent.EndOffset -and
                -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                    -Command $_) -and
                (Test-PrivateMarkerCommandConstructsRiskyType `
                    -Command $_ `
                    -ConstructorCallableNames $constructorCallableNames `
                    -RiskyTypeNames $riskyTypeNames)
            }
    )
    if ($earlyRiskyConstructors.Count -gt 0) {
        return $false
    }

    $earlyEagerCommands = @(
        $allCommands |
            Where-Object {
                $_.Extent.StartOffset -lt
                    $binaryOuterCommand.Extent.EndOffset -and
                -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                    -Command $_)
            }
    )
    foreach ($earlyCommand in $earlyEagerCommands) {
        if ($earlyCommand.Extent.StartOffset -eq
                $binaryOuterCommand.Extent.StartOffset -and
            $earlyCommand.Extent.EndOffset -eq
                $binaryOuterCommand.Extent.EndOffset) {
            continue
        }

        $earlyName = ConvertTo-PrivateMarkerCallableName `
            -Name $earlyCommand.GetCommandName()
        $scriptInvocationOperator =
            Test-PrivateMarkerCommandUsesScriptInvocationOperator `
                -Command $earlyCommand
        $scriptPathCommand = Test-PrivateMarkerNameIsScriptPath `
            -Name $earlyCommand.GetCommandName()
        $allowedBootstrapDotSource = (
            [string]$earlyCommand.InvocationOperator -eq 'Dot' -and
            (Test-PrivateMarkerAllowedBootstrapDotSource `
                -Command $earlyCommand `
                -SourceAst $sourceAst)
        )
        $unresolvedOperator = (
            [string]::IsNullOrWhiteSpace($earlyName) -and
            -not $allowedBootstrapDotSource
        )
        $dynamicExpression = @(
            'Invoke-Expression',
            'iex',
            'Invoke-Command',
            'icm'
        ) -contains $earlyName
        $alias = Get-PrivateMarkerAliasDefinition -Command $earlyCommand
        $referenceRisk = Get-PrivateMarkerFunctionReferenceRisk `
            -Command $earlyCommand `
            -RiskyCallableNames $riskyCallableNames
        $commandExecutionContextReferences = @(
            $earlyCommand.FindAll(
                {
                    param($node)
                    return $node -is
                            [System.Management.Automation.Language.VariableExpressionAst] -and
                        (ConvertTo-PrivateMarkerVariableName `
                            -Name $node.VariablePath.UserPath) -ieq
                            'ExecutionContext' -and
                        -not (
                            Test-PrivateMarkerExecutionContextReferenceIsDirectPsVariableReceiver `
                                -Variable $node
                        )
                },
                $true
            )
        )
        $commandReadsExecutionContext = (
            $commandExecutionContextReferences.Count -gt 0 -or
            (Test-PrivateMarkerCommandReadsVariable `
                -Command $earlyCommand `
                -VariableName 'ExecutionContext')
        )
        if ($riskyCallableNames.Contains($earlyName) -or
            $unresolvedOperator -or
            ($scriptInvocationOperator -and
                -not $allowedBootstrapDotSource) -or
            $scriptPathCommand -or
            $dynamicExpression -or
            $commandReadsExecutionContext -or
            ($alias.IsAliasCommand -and
                $alias.Resolved -and
                $alias.Name -ieq 'Invoke-PrivateMarkerProcess') -or
            ($alias.IsAliasCommand -and -not $alias.Resolved) -or
            @('Risky', 'Unresolved') -contains $referenceRisk) {
            return $false
        }
    }

    # function providerのscriptblock参照は、Invoke*()やcall operatorへ渡せる。
    # raw fixtureより前のrisky function参照を実行形に限定せず保守的に拒否する。
    $earlyFunctionReferences = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.EndOffset -and
                    $node.VariablePath.UserPath -match '^(?i:function:)'
            },
            $true
        ) |
            Where-Object {
                -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                    -Command $_)
            }
    )
    foreach ($reference in $earlyFunctionReferences) {
        if (Test-PrivateMarkerNameMatchesRiskyCallable `
            -Name $reference.VariablePath.UserPath `
            -RiskyCallableNames $riskyCallableNames) {
            return $false
        }
    }

    # top-level変数へ保存したrisky scriptblockは、assignment後に同じ変数が
    # binary fixtureより前で再参照された時点で保守的にrejectする。helper名
    # だけでなく、literal/dynamic operatorやfixed-pointでriskyになったcallも追う。
    $deferredRiskyCommandsBeforeBinary = @(
        $allCommands |
            Where-Object {
                if ($_.Extent.StartOffset -ge
                        $binaryOuterCommand.Extent.StartOffset -or
                    -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                        -Command $_)) {
                    return $false
                }
                $deferredName = ConvertTo-PrivateMarkerCallableName `
                    -Name $_.GetCommandName()
                $deferredAlias = Get-PrivateMarkerAliasDefinition -Command $_
                $deferredReferenceRisk =
                    Get-PrivateMarkerFunctionReferenceRisk `
                        -Command $_ `
                        -RiskyCallableNames $riskyCallableNames
                return [string]::IsNullOrWhiteSpace($deferredName) -or
                    $riskyCallableNames.Contains($deferredName) -or
                    (Test-PrivateMarkerNameIsScriptPath `
                        -Name $_.GetCommandName()) -or
                    (Test-PrivateMarkerCommandUsesScriptInvocationOperator `
                        -Command $_) -or
                    ($deferredAlias.IsAliasCommand -and
                        -not $deferredAlias.Resolved) -or
                    @('Risky', 'Unresolved') -contains
                        $deferredReferenceRisk -or
                    (Test-PrivateMarkerCommandConstructsRiskyType `
                        -Command $_ `
                        -ConstructorCallableNames $constructorCallableNames `
                        -RiskyTypeNames $riskyTypeNames)
            }
    )
    foreach ($deferredRiskyCommand in $deferredRiskyCommandsBeforeBinary) {
        $ancestor = $deferredRiskyCommand.Parent
        $functionOwner = $null
        $typeOwner = $null
        $scriptBlockOwner = $null
        while ($null -ne $ancestor) {
            if ($null -eq $functionOwner -and
                $ancestor -is
                    [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $functionOwner = $ancestor
            }
            if ($null -eq $typeOwner -and
                ($ancestor -is
                        [System.Management.Automation.Language.FunctionMemberAst] -or
                    $ancestor -is
                        [System.Management.Automation.Language.TypeDefinitionAst])) {
                $typeOwner = $ancestor
            }
            if ($null -eq $scriptBlockOwner -and
                $ancestor -is
                    [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                $scriptBlockOwner = $ancestor
            }
            $ancestor = $ancestor.Parent
        }
        if ($null -ne $functionOwner) {
            continue
        }
        if ($null -ne $typeOwner -or $null -eq $scriptBlockOwner) {
            return $false
        }

        $assignmentOwner = $scriptBlockOwner.Parent
        while ($null -ne $assignmentOwner -and
            $assignmentOwner -isnot
                [System.Management.Automation.Language.AssignmentStatementAst]) {
            $assignmentOwner = $assignmentOwner.Parent
        }
        if ($null -eq $assignmentOwner -or
            $assignmentOwner.Left -isnot
                [System.Management.Automation.Language.VariableExpressionAst]) {
            return $false
        }
        $storedVariableName = ConvertTo-PrivateMarkerVariableName `
            -Name $assignmentOwner.Left.VariablePath.UserPath
        $laterReferences = @(
            $sourceAst.FindAll(
                {
                    param($node)
                    if ($node.Extent.StartOffset -lt
                            $assignmentOwner.Extent.EndOffset -or
                        $node.Extent.StartOffset -ge
                            $binaryOuterCommand.Extent.EndOffset) {
                        return $false
                    }
                    if ($node -is
                        [System.Management.Automation.Language.VariableExpressionAst]) {
                        return (ConvertTo-PrivateMarkerVariableName `
                            -Name $node.VariablePath.UserPath) -ieq
                                $storedVariableName
                    }
                    if ($node -is
                        [System.Management.Automation.Language.CommandAst]) {
                        return Test-PrivateMarkerCommandReadsVariable `
                            -Command $node `
                            -VariableName $storedVariableName
                    }
                    if ($node -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                        return Test-PrivateMarkerMemberReadsVariable `
                            -Invocation $node `
                            -VariableName $storedVariableName
                    }
                    return $false
                },
                $true
            )
        )
        if ($laterReferences.Count -gt 0) {
            return $false
        }
    }

    $eagerHelperCalls = @(
        $allHelperCalls |
            Where-Object {
                -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                    -Command $_)
            } |
            Sort-Object { $_.Extent.StartOffset }
    )
    return $eagerHelperCalls.Count -gt 0 -and
        $eagerHelperCalls[0].Extent.StartOffset -eq
            $binaryOuterCommand.Extent.StartOffset -and
        $eagerHelperCalls[0].Extent.EndOffset -eq
            $binaryOuterCommand.Extent.EndOffset
}
