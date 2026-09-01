Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-MorphospaceAffectedDependencyBytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function ConvertTo-MorphospaceAffectedDependencyPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $normalized = $Path.Replace('\','/')
    if ($normalized -notmatch '^[^/:][^:]*$' -or $normalized -match '(?:^|/)\.\.?/') { throw "Affected dependency path is not canonical: $Path" }
    return $normalized
}

function Get-MorphospaceAffectedDependencyDeclarationKey {
    param(
        [Parameter(Mandatory = $true)][string]$Importer,
        [Parameter(Mandatory = $true)][string]$Variable
    )
    # Repository paths remain ordinal. PowerShell variable identity is
    # case-insensitive, so only the variable component is canonicalized.
    return "$Importer|$($Variable.ToLowerInvariant())"
}

function Get-MorphospaceAffectedDependencyDeclarations {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Declarations)
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($declaration in @($Declarations)) {
        $properties = @($declaration.PSObject.Properties.Name)
        [Array]::Sort($properties,[StringComparer]::Ordinal)
        $targetShape = ($properties -join ',') -ceq 'count,importer,target_paths,variable'
        $classificationShape = ($properties -join ',') -ceq 'classification,count,importer,variable'
        if (-not $targetShape -and -not $classificationShape) { throw 'Affected dependency declaration does not use one closed importer/variable/count/target_paths-or-classification shape.' }
        $importer = ConvertTo-MorphospaceAffectedDependencyPath -Path ([string]$declaration.importer)
        $variable = [string]$declaration.variable
        $identity = "$importer|$variable"
        $key = Get-MorphospaceAffectedDependencyDeclarationKey -Importer $importer -Variable $variable
        if ($importer -cnotmatch '^scripts/.+\.ps(?:m)?1$' -or $variable -cnotmatch '^[A-Za-z_][A-Za-z0-9_:.-]*$' -or [int]$declaration.count -lt 1 -or $map.ContainsKey($key)) { throw "Affected dependency declaration has an invalid or duplicate identity: $identity" }
        if ($targetShape) {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $targets = [Collections.Generic.List[string]]::new()
            foreach ($target in @($declaration.target_paths)) {
                $path = ConvertTo-MorphospaceAffectedDependencyPath -Path ([string]$target)
                if ($path -cnotmatch '^scripts/.+\.ps(?:m)?1$' -or -not $seen.Add($path)) { throw "Affected dependency declaration has an invalid or duplicate target: $key" }
            [void]$targets.Add($path)
            }
            if ($targets.Count -eq 0) { throw "Affected dependency declaration has no target: $key" }
            [string[]]$ordered = @($targets.ToArray()); [Array]::Sort($ordered,[StringComparer]::Ordinal)
            $map[$key] = [pscustomobject][ordered]@{importer=$importer;variable=$variable;count=[int]$declaration.count;target_paths=@($ordered)}
        } else {
            if ([string]$declaration.classification -cne 'authenticated-external-command') { throw "Affected dependency declaration has an unsupported classification: $key" }
            $map[$key] = [pscustomobject][ordered]@{importer=$importer;variable=$variable;count=[int]$declaration.count;classification='authenticated-external-command'}
        }
    }
    return $map
}

function Get-MorphospaceAffectedDependencyLexicalScope {
    param([Parameter(Mandatory = $true)][Management.Automation.Language.Ast]$Node)
    $current = $Node.Parent
    if ($Node -is [Management.Automation.Language.ScriptBlockAst] -and $current -is [Management.Automation.Language.ScriptBlockExpressionAst]) { $current = $current.Parent }
    while ($null -ne $current) {
        if ($current -is [Management.Automation.Language.FunctionDefinitionAst]) { return $current }
        if ($current -is [Management.Automation.Language.ScriptBlockExpressionAst]) { return $current.ScriptBlock }
        $current = $current.Parent
    }
    $current = $Node
    while ($null -ne $current.Parent) { $current = $current.Parent }
    return $current
}

function Get-MorphospaceAffectedDependencyScopeChain {
    param([Parameter(Mandatory = $true)][object]$Scope)
    $result = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $current = $Scope
    while ($null -ne $current -and $seen.Add($current)) {
        [void]$result.Add($current)
        $next = Get-MorphospaceAffectedDependencyLexicalScope -Node $current
        if ($next -eq $current) { break }
        $current = $next
    }
    return $result.ToArray()
}

function Test-MorphospaceAffectedDependencyAssignmentDefinite {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.Language.AssignmentStatementAst]$Assignment,
        [Parameter(Mandatory = $true)][object]$AssignmentScope,
        [Parameter(Mandatory = $true)][Management.Automation.Language.CommandAst]$Invocation,
        [Parameter(Mandatory = $true)][object]$InvocationScope
    )
    $sameLexicalScope = [object]::ReferenceEquals($AssignmentScope,$InvocationScope)
    $explicitRootScriptScope =
        [string]$Assignment.Left.VariablePath.UserPath -imatch '^script:' -and
        $AssignmentScope -is [Management.Automation.Language.ScriptBlockAst]
    if ((-not $sameLexicalScope -and -not $explicitRootScriptScope) -or [int]$Assignment.Extent.EndOffset -gt [int]$Invocation.Extent.StartOffset) { return $false }

    # PowerShell executes statements in one StatementBlock/NamedBlock in source
    # order. The assignment is therefore definite for a later invocation in
    # that block or any of its nested blocks. An assignment made in a sibling
    # or nested conditional block is not definite for an invocation outside
    # that block and must use a declaration or the conservative fallback.
    $assignmentContainer = $Assignment.Parent
    while ($null -ne $assignmentContainer -and
        $assignmentContainer -isnot [Management.Automation.Language.StatementBlockAst] -and
        $assignmentContainer -isnot [Management.Automation.Language.NamedBlockAst]) {
        $assignmentContainer = $assignmentContainer.Parent
    }
    if ($null -eq $assignmentContainer) { return $false }
    $current = $Invocation
    while ($null -ne $current -and -not [object]::ReferenceEquals($current,$assignmentContainer)) { $current = $current.Parent }
    return $null -ne $current
}

function Resolve-MorphospaceAffectedCheckDependencyClosure {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Entrypoint,
        [Parameter(Mandatory = $true)][object]$Inventory,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$DynamicDeclarations
    )
    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    $trackedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $trackedScripts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Inventory.records)) {
        if ([string]$entry.type -cne 'blob' -or @('100644','100755') -cnotcontains [string]$entry.mode) { continue }
        [void]$trackedFiles.Add([string]$entry.path)
        if ([string]$entry.path -match '^scripts/.+\.ps(?:m)?1$') { [void]$trackedScripts.Add([string]$entry.path) }
    }
    $declarations = Get-MorphospaceAffectedDependencyDeclarations -Declarations @($DynamicDeclarations)
    $observedDeclarations = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $usedDeclarations = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $fallbackReasons = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $nodes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Queue[string]]::new()
    $parsedSha = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)

    function Add-MorphospaceTrackedDependencyPath([string]$Importer,[string]$Value) {
        $normalized = $Value.Replace('\','/')
        $importerDirectory = [IO.Path]::GetDirectoryName((Join-Path $root $Importer))
        $candidates = [Collections.Generic.List[string]]::new()
        if ($normalized -match '^(?:scripts|schemas|manifests|docs|templates|config|skills)/') { [void]$candidates.Add([IO.Path]::GetFullPath((Join-Path $root $normalized))) }
        [void]$candidates.Add([IO.Path]::GetFullPath((Join-Path $importerDirectory $normalized)))
        [void]$candidates.Add([IO.Path]::GetFullPath((Join-Path $root $normalized)))
        if ($normalized -notmatch '/') { foreach ($directory in @('schemas','manifests','config','templates')) { [void]$candidates.Add([IO.Path]::GetFullPath((Join-Path $root (Join-Path $directory $normalized)))) } }
        foreach ($absolute in @($candidates)) {
            if (-not $absolute.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = [IO.Path]::GetRelativePath($root,$absolute).Replace('\','/')
            if (-not $trackedFiles.Contains($relative)) { continue }
            if ($nodes.Add($relative) -and $trackedScripts.Contains($relative)) { $pending.Enqueue($relative) }
            return $relative
        }
        return $null
    }
    function Add-MorphospaceFallback([string]$Importer,[string]$Variable,[string]$Kind) {
        $key = "$Importer|$Variable|$Kind"
        if (-not $fallbackReasons.ContainsKey($key)) { $fallbackReasons[$key] = [pscustomobject][ordered]@{importer=$Importer;variable=$Variable;kind=$Kind} }
    }
    function Use-MorphospaceDeclaration(
        [string]$Importer,
        [string]$Variable,
        [AllowEmptyCollection()][string[]]$ObservedBoundPaths = @()
    ) {
        $key = Get-MorphospaceAffectedDependencyDeclarationKey -Importer $Importer -Variable $Variable
        if (-not $declarations.ContainsKey($key)) { return $false }
        $declaration = $declarations[$key]
        if (@($ObservedBoundPaths).Count -ne 0) {
            if ($declaration.PSObject.Properties.Name -cnotcontains 'target_paths') { throw "Affected dependency declaration does not bind observed static targets: $Importer|$Variable" }
            $declaredTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($target in @($declaration.target_paths)) { [void]$declaredTargets.Add([string]$target) }
            foreach ($observed in @($ObservedBoundPaths)) {
                $observedPath = Add-MorphospaceTrackedDependencyPath -Importer $Importer -Value ([string]$observed)
                if ($null -eq $observedPath -or -not $declaredTargets.Contains([string]$observedPath)) { throw "Affected dependency declaration omits observed static target: $Importer|$Variable -> $observed" }
            }
        }
        $observedDeclarations[$key] = 1 + $(if ($observedDeclarations.ContainsKey($key)) { [int]$observedDeclarations[$key] } else { 0 })
        $usedDeclarations[$key] = $declaration
        if ($declaration.PSObject.Properties.Name -ccontains 'target_paths') {
            foreach ($target in @($declaration.target_paths)) {
                if ($null -eq (Add-MorphospaceTrackedDependencyPath -Importer $Importer -Value ([string]$target))) { throw "Affected dependency declaration target is absent from the exact head: $key -> $target" }
            }
        }
        return $true
    }

    $entrypointPath = ConvertTo-MorphospaceAffectedDependencyPath -Path $Entrypoint
    if ($null -eq (Add-MorphospaceTrackedDependencyPath -Importer $entrypointPath -Value $entrypointPath) -or -not $trackedScripts.Contains($entrypointPath)) { throw "Affected check entrypoint is not a tracked PowerShell file: $Entrypoint" }
    $fallbackExpanded = $false
    while ($true) {
        while ($pending.Count -gt 0) {
            $importer = $pending.Dequeue()
            $absolute = Join-Path $root $importer
            [byte[]]$beforeBytes = [IO.File]::ReadAllBytes($absolute)
            $beforeSha = Get-MorphospaceAffectedDependencyBytesSha256 -Bytes $beforeBytes
            $parsedSha[$importer] = $beforeSha
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput(([Text.UTF8Encoding]::new($false,$true).GetString($beforeBytes)),[ref]$tokens,[ref]$errors)
            if (@($errors).Count -ne 0) { throw "Affected check dependency closure could not parse tracked source: $importer" }
            $literalOffsets = [Collections.Generic.HashSet[int]]::new()
            foreach ($literal in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Value -match '(?i)\.(?:ps1|psm1|json|jsonl|ya?ml|toml|md)$' },$true))) {
                if ($null -ne (Add-MorphospaceTrackedDependencyPath -Importer $importer -Value ([string]$literal.Value)) -and [string]$literal.Value -match '(?i)\.ps(?:m)?1$') { [void]$literalOffsets.Add([int]$literal.Extent.StartOffset) }
            }
            $assignmentsByScope = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
            foreach ($assignment in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] },$true))) {
                $variable = [string]$assignment.Left.VariablePath.UserPath
                $scope = Get-MorphospaceAffectedDependencyLexicalScope -Node $assignment
                if (-not $assignmentsByScope.ContainsKey($scope)) { $assignmentsByScope[$scope] = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase) }
                $assignments = $assignmentsByScope[$scope]
                if (-not $assignments.ContainsKey($variable)) { $assignments[$variable] = [Collections.Generic.List[object]]::new() }
                $pathValues = @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Value -match '(?i)\.ps(?:m)?1$' },$true) | ForEach-Object { [string]$_.Value })
                $rightText = [string]$assignment.Right.Extent.Text
                $nonPath = $rightText -match '(?i)\b(?:Get-Module|Import-Module|Get-Process)\b'
                if (-not $nonPath -and $rightText.Contains('{')) { $nonPath = @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] },$true)).Count -ne 0 }
                $unknownVariables = @($assignment.Right.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.VariableExpressionAst] -and
                    @('PSScriptRoot','true','false','null') -inotcontains [string]$node.VariablePath.UserPath
                },$true)).Count -ne 0
                $unknownCommands = $false
                foreach ($rightCommand in @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] },$true))) {
                    $name = [string]$rightCommand.GetCommandName()
                    if ($name -imatch '(?:^|\\)Join-Path$') { continue }
                    if ($name -imatch '(?:^|\\)Get-Command$' -and @($pathValues).Count -ne 0 -and -not $unknownVariables) { continue }
                    $unknownCommands = $true
                }
                $unclassifiedBinding = -not $nonPath -and (@($pathValues).Count -eq 0 -or $unknownVariables -or $unknownCommands)
                $scriptBlockMembers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($hashtable in @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] },$true))) {
                    foreach ($pair in @($hashtable.KeyValuePairs)) {
                        $memberName = ([string]$pair.Item1.Extent.Text).Trim("'",'"')
                        $valueText = [string]$pair.Item2.Extent.Text
                        if ($valueText.Contains('{') -and @($pair.Item2.FindAll({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] },$true)).Count -eq 1 -and $valueText -notmatch '(?i)\.ps(?:m)?1') { [void]$scriptBlockMembers.Add($memberName) }
                    }
                }
                [void]([Collections.Generic.List[object]]$assignments[$variable]).Add([pscustomobject][ordered]@{ast=$assignment;scope=$scope;paths=$pathValues;non_path=$nonPath;unclassified_binding=$unclassifiedBinding;scriptblock_members=$scriptBlockMembers})
            }
            $typedScriptBlocksByScope = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
            $untypedParametersByScope = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
            foreach ($parameter in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.ParameterAst] -and $node.StaticType -eq [scriptblock] },$true))) {
                $scope = Get-MorphospaceAffectedDependencyLexicalScope -Node $parameter
                if (-not $typedScriptBlocksByScope.ContainsKey($scope)) { $typedScriptBlocksByScope[$scope] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
                [void]$typedScriptBlocksByScope[$scope].Add([string]$parameter.Name.VariablePath.UserPath)
            }
            foreach ($parameter in @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ParameterAst] -and
                @($node.Attributes | Where-Object { $_ -is [Management.Automation.Language.TypeConstraintAst] }).Count -eq 0
            },$true))) {
                $scope = Get-MorphospaceAffectedDependencyLexicalScope -Node $parameter
                if (-not $untypedParametersByScope.ContainsKey($scope)) { $untypedParametersByScope[$scope] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
                [void]$untypedParametersByScope[$scope].Add([string]$parameter.Name.VariablePath.UserPath)
            }
            foreach ($command in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] },$true))) {
                $isImport = [string]$command.GetCommandName() -match '(?i)(?:^|\\)Import-Module$'
                $isInvocation = $command.InvocationOperator -in @([Management.Automation.Language.TokenKind]::Ampersand,[Management.Automation.Language.TokenKind]::Dot)
                if (-not $isImport -and -not $isInvocation) { continue }
                $trackedLiteral = @($command.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $literalOffsets.Contains([int]$node.Extent.StartOffset) },$true)).Count -ne 0
                if ($trackedLiteral) { continue }
                $elements = @($command.CommandElements); $first = $elements[0]
                if ($isImport -and @($elements | Select-Object -Skip 1).Count -eq 1 -and $elements[1] -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$elements[1].Value -notmatch '[\\/]|(?i)\.psm1$') { continue }
                if ($isInvocation -and ($first -is [Management.Automation.Language.StringConstantExpressionAst] -or $first -is [Management.Automation.Language.ScriptBlockExpressionAst])) { continue }
                $variable = $null
                $memberInvocationUnclassified = $false
                if ($isInvocation -and $first -is [Management.Automation.Language.MemberExpressionAst] -and [string]$first.Extent.Text -match '(?i)\.Source$') {
                    $getCommandNodes = @($first.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -imatch '(?:^|\\)Get-Command$' },$true))
                    if ($getCommandNodes.Count -eq 1) {
                        $variableNodes = @($getCommandNodes[0].FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and [string]$node.VariablePath.UserPath -ine 'PSScriptRoot' },$true))
                        if ($variableNodes.Count -eq 1) { $variable = [string]$variableNodes[0].VariablePath.UserPath; $memberInvocationUnclassified = $true }
                        elseif ($variableNodes.Count -eq 0 -and @($getCommandNodes[0].FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Value -match '(?i)\.ps(?:m)?1$' },$true)).Count -eq 0) { continue }
                    }
                }
                if ($null -eq $variable -and $isInvocation -and $first -is [Management.Automation.Language.MemberExpressionAst] -and $first.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $first.Member -is [Management.Automation.Language.StringConstantExpressionAst]) {
                    $receiverVariable = [string]$first.Expression.VariablePath.UserPath
                    $memberName = [string]$first.Member.Value
                    $memberProven = $false
                    $memberAmbiguous = $false
                    $invocationScope = Get-MorphospaceAffectedDependencyLexicalScope -Node $command
                    foreach ($scope in @(Get-MorphospaceAffectedDependencyScopeChain -Scope $invocationScope)) {
                        if (-not $assignmentsByScope.ContainsKey($scope) -or -not $assignmentsByScope[$scope].ContainsKey($receiverVariable)) { continue }
                        foreach ($record in @($assignmentsByScope[$scope][$receiverVariable])) {
                            if (-not (Test-MorphospaceAffectedDependencyAssignmentDefinite -Assignment $record.ast -AssignmentScope $record.scope -Invocation $command -InvocationScope $invocationScope) -or -not $record.scriptblock_members.Contains($memberName)) { $memberAmbiguous = $true }
                            else { $memberProven = $true }
                        }
                    }
                    if ($memberProven -and -not $memberAmbiguous) { continue }
                    $variable = $receiverVariable
                    $memberInvocationUnclassified = $true
                }
                if ($null -eq $variable -and $first -is [Management.Automation.Language.VariableExpressionAst]) { $variable = [string]$first.VariablePath.UserPath }
                elseif ($isImport) {
                    $variableNodes = @($command.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and [string]$node.VariablePath.UserPath -cne 'PSScriptRoot' },$true))
                    if ($variableNodes.Count -eq 1) { $variable = [string]$variableNodes[0].VariablePath.UserPath }
                }
                if (-not [string]::IsNullOrWhiteSpace($variable)) {
                    $boundPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    $nonPath = $false
                    $unclassifiedBinding = $memberInvocationUnclassified
                    $typedScriptBlock = $false
                    $invocationScope = Get-MorphospaceAffectedDependencyLexicalScope -Node $command
                    foreach ($scope in @(Get-MorphospaceAffectedDependencyScopeChain -Scope $invocationScope)) {
                        if ($assignmentsByScope.ContainsKey($scope)) {
                            $scopeAssignments = $assignmentsByScope[$scope]
                            if ($scopeAssignments.ContainsKey($variable)) {
                                foreach ($record in @($scopeAssignments[$variable])) {
                                    foreach ($value in @($record.paths)) { [void]$boundPaths.Add([string]$value) }
                                    if ([bool]$record.non_path) { $nonPath=$true }
                                    if ([bool]$record.unclassified_binding) { $unclassifiedBinding=$true }
                                    if (-not (Test-MorphospaceAffectedDependencyAssignmentDefinite -Assignment $record.ast -AssignmentScope $record.scope -Invocation $command -InvocationScope $invocationScope)) { $unclassifiedBinding=$true }
                                }
                            }
                        }
                        if ($typedScriptBlocksByScope.ContainsKey($scope) -and $typedScriptBlocksByScope[$scope].Contains($variable)) { $typedScriptBlock=$true }
                        if ($untypedParametersByScope.ContainsKey($scope) -and $untypedParametersByScope[$scope].Contains($variable)) { $unclassifiedBinding=$true }
                    }
                    # A literal assignment cannot make a variable invocation exact when
                    # another applicable assignment has no classified path or callable
                    # shape. A closed declaration may bind that whole dispatch; absent
                    # one, bind every tracked script so reuse cannot omit the unknown
                    # target's imported bytes.
                    if ($unclassifiedBinding) {
                        [string[]]$observedBoundPaths = @($boundPaths | ForEach-Object { [string]$_ })
                        if (Use-MorphospaceDeclaration -Importer $importer -Variable $variable -ObservedBoundPaths $observedBoundPaths) { continue }
                        Add-MorphospaceFallback -Importer $importer -Variable $variable -Kind $(if($boundPaths.Count -eq 0){$(if($isImport){'unresolved-import'}else{'unresolved-invocation'})}else{'ambiguous-static-binding'})
                        continue
                    }
                    if ($boundPaths.Count -eq 1) { [void](Add-MorphospaceTrackedDependencyPath -Importer $importer -Value ([string]@($boundPaths)[0])); continue }
                    if ($boundPaths.Count -gt 1) { Add-MorphospaceFallback -Importer $importer -Variable $variable -Kind 'ambiguous-static-binding'; continue }
                    if ($nonPath -or $typedScriptBlock) { continue }
                    if (Use-MorphospaceDeclaration -Importer $importer -Variable $variable) { continue }
                    Add-MorphospaceFallback -Importer $importer -Variable $variable -Kind $(if($isImport){'unresolved-import'}else{'unresolved-invocation'})
                    continue
                }
                Add-MorphospaceFallback -Importer $importer -Variable ([string]$first.Extent.Text) -Kind $(if($isImport){'unresolved-import'}else{'unresolved-invocation'})
            }
            [byte[]]$afterBytes = [IO.File]::ReadAllBytes($absolute)
            if ((Get-MorphospaceAffectedDependencyBytesSha256 -Bytes $afterBytes) -cne $beforeSha) { throw "Affected dependency source bytes changed during analysis: $importer" }
        }
        if ($fallbackReasons.Count -eq 0 -or $fallbackExpanded) { break }
        $fallbackExpanded = $true
        # Unknown dispatch remains fail-closed by binding and inspecting every
        # tracked script. This also retains non-script inputs named by any
        # possible target; declared consume path sets remain an independent
        # exact input boundary rather than a substitute for dynamic closure.
        foreach ($path in @($trackedScripts)) { if ($nodes.Add([string]$path)) { $pending.Enqueue([string]$path) } }
    }
    foreach ($key in @($declarations.Keys)) {
        $declaration = $declarations[$key]
        if (-not $nodes.Contains([string]$declaration.importer)) { continue }
        $expected = [int]$declaration.count
        $observed = if ($observedDeclarations.ContainsKey($key)) { [int]$observedDeclarations[$key] } else { 0 }
        if ($observed -ne $expected) { throw "Affected dependency declaration count changed: $key expected=$expected observed=$observed" }
        $usedDeclarations[$key] = $declaration
    }
    foreach ($path in @($parsedSha.Keys)) {
        $current = Get-MorphospaceAffectedDependencyBytesSha256 -Bytes ([IO.File]::ReadAllBytes((Join-Path $root $path)) )
        if ($current -cne [string]$parsedSha[$path]) { throw "Affected dependency source bytes changed after analysis: $path" }
    }
    [string[]]$orderedPaths = @($nodes); [Array]::Sort($orderedPaths,[StringComparer]::Ordinal)
    [object[]]$orderedDeclarations = @($usedDeclarations.Values)
    if ($orderedDeclarations.Count -gt 1) { [Array]::Sort($orderedDeclarations,[Collections.Generic.Comparer[object]]::Create({param($l,$r)[StringComparer]::Ordinal.Compare("$($l.importer)|$($l.variable)","$($r.importer)|$($r.variable)" )})) }
    [object[]]$orderedReasons = @($fallbackReasons.Values)
    if ($orderedReasons.Count -gt 1) { [Array]::Sort($orderedReasons,[Collections.Generic.Comparer[object]]::Create({param($l,$r)[StringComparer]::Ordinal.Compare("$($l.importer)|$($l.variable)|$($l.kind)","$($r.importer)|$($r.variable)|$($r.kind)")})) }
    return [pscustomobject][ordered]@{
        paths=@($orderedPaths)
        resolution=[pscustomobject][ordered]@{
            schema='rusty.morphospace.workflow.affected_validation_dependency_resolution.v1'
            algorithm='indexed-static-closure-v1'
            mode=$(if($fallbackReasons.Count -eq 0){'exact'}else{'all-tracked-scripts-fallback'})
            entrypoint=$entrypointPath
            used_declarations=@($orderedDeclarations)
            fallback_reasons=@($orderedReasons)
        }
    }
}

Export-ModuleMember -Function Resolve-MorphospaceAffectedCheckDependencyClosure
