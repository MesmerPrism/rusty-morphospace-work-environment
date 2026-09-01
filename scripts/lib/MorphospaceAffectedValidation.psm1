Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$protocolModule = Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1'
Microsoft.PowerShell.Core\Import-Module -Name $protocolModule

function Invoke-MorphospaceAffectedGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [AllowNull()][string]$StandardInputText = $null,
        [switch]$AllowFailure
    )

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.WorkingDirectory = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $null -ne $StandardInputText
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    if ($start.RedirectStandardInput) { $start.StandardInputEncoding = $strictUtf8 }
    $start.StandardOutputEncoding = $strictUtf8
    $start.StandardErrorEncoding = $strictUtf8
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'git did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($start.RedirectStandardInput) {
            $process.StandardInput.Write($StandardInputText)
            $process.StandardInput.Close()
        }
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill($true) } catch {}
            throw "git timed out: $($Arguments -join ' ')"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if (-not $AllowFailure -and $process.ExitCode -ne 0) {
            throw "git failed ($($process.ExitCode)): $($Arguments -join ' ')`n$stderr"
        }
        return [pscustomobject]@{ exit_code = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    } finally { $process.Dispose() }
}

function ConvertTo-MorphospaceAffectedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 4096) { throw 'Git path is empty or exceeds 4096 characters.' }
    if ($Path.Contains('\') -or $Path.Contains(':') -or $Path.StartsWith('/') -or $Path.Contains("`0")) {
        throw "Git path is not repository-relative canonical form: $Path"
    }
    foreach ($character in $Path.ToCharArray()) { if ([int]$character -lt 32 -or [int]$character -eq 127) { throw "Git path contains a prohibited control character: $Path" } }
    foreach ($segment in $Path.Split('/')) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') { throw "Git path contains a prohibited segment: $Path" }
    }
    return $Path
}

function ConvertFrom-MorphospaceAffectedTreeInventoryOutput {
    param([Parameter(Mandatory = $true)][string]$Stdout, [Parameter(Mandatory = $true)][string]$Commit)

    if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Affected-validation tree inventory requires a full lowercase commit identity.' }
    $records = [System.Collections.Generic.List[object]]::new()
    $byPath = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    $casePaths = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $caseCollision = $false
    if ($Stdout.Length -ne 0) {
        if ($Stdout[$Stdout.Length - 1] -ne [char]0) { throw 'Affected-validation tree inventory lacks its exact terminal NUL record boundary.' }
        $tokens = @($Stdout.Split([char]0, [System.StringSplitOptions]::None))
        if ($tokens.Count -lt 2 -or $tokens[-1] -cne '') { throw 'Affected-validation tree inventory has an invalid terminal record.' }
        $tokens = @($tokens[0..($tokens.Count - 2)])
        $previousPath = $null
        foreach ($token in $tokens) {
            if ([string]::IsNullOrEmpty([string]$token) -or [string]$token -cnotmatch '^(?<mode>[0-9]{6}) (?<type>blob|commit) (?<blob>[0-9a-f]{40})\t(?<path>.+)$') {
                throw 'Affected-validation tree inventory contains a malformed or empty record.'
            }
            $mode = [string]$Matches.mode
            $type = [string]$Matches.type
            $blob = [string]$Matches.blob
            $path = ConvertTo-MorphospaceAffectedPath -Path ([string]$Matches.path)
            if (($type -ceq 'blob' -and @('100644','100755','120000') -cnotcontains $mode) -or
                ($type -ceq 'commit' -and $mode -cne '160000')) {
                throw "Affected-validation tree inventory contains an unsupported mode/type pair for '$path'."
            }
            if ($null -ne $previousPath -and [System.StringComparer]::Ordinal.Compare([string]$previousPath, $path) -ge 0) {
                throw 'Affected-validation tree inventory is not in strict ordinal path order.'
            }
            if ($byPath.ContainsKey($path)) { throw "Affected-validation tree inventory repeats exact path '$path'." }
            if ($casePaths.ContainsKey($path) -and $casePaths[$path] -cne $path) { $caseCollision = $true }
            else { $casePaths[$path] = $path }
            $record = [pscustomobject][ordered]@{ path=$path; mode=$mode; type=$type; blob=$blob; ordinal=$records.Count }
            $records.Add($record)
            $byPath.Add($path,$record)
            $previousPath = $path
        }
    }
    return [pscustomobject][ordered]@{ commit=$Commit; count=$records.Count; records=@($records.ToArray()); by_path=$byPath; case_collision=$caseCollision }
}

function Get-MorphospaceAffectedTreeInventory {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot, [Parameter(Mandatory = $true)][string]$Commit)

    $result = Invoke-MorphospaceAffectedGit -RepositoryRoot $RepositoryRoot -Arguments @('ls-tree','-r','-z','--full-tree',$Commit)
    if ($result.stderr.Length -ne 0) { throw 'Affected-validation exact-head tree inventory emitted unexpected stderr.' }
    return ConvertFrom-MorphospaceAffectedTreeInventoryOutput -Stdout $result.stdout -Commit $Commit
}

function Get-MorphospaceAffectedInventoryEntry {
    param([Parameter(Mandatory = $true)][object]$Inventory, [AllowNull()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if ($Inventory.by_path.ContainsKey($Path)) { return $Inventory.by_path[$Path] }
    return $null
}

function Get-MorphospaceAffectedWorktreeObservation {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)
    $identity = Invoke-MorphospaceAffectedGit -RepositoryRoot $root -Arguments @('rev-parse','--show-toplevel','HEAD^{commit}','HEAD^{tree}')
    if ($identity.stderr.Length -ne 0) { throw 'Affected-validation worktree identity emitted unexpected stderr.' }
    $lines = @($identity.stdout.Split([char]10,[System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { ([string]$_).TrimEnd([char]13) })
    if ($lines.Count -ne 3 -or [string]$lines[1] -cnotmatch '^[0-9a-f]{40}$' -or [string]$lines[2] -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Affected-validation worktree identity has malformed root/commit/tree output.'
    }
    $observedRoot = [System.IO.Path]::GetFullPath([string]$lines[0]).TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)
    $rootComparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $observedRoot.Equals($root,$rootComparison)) { throw 'Affected-validation repository root changed across its Git observation.' }
    $status = Invoke-MorphospaceAffectedGit -RepositoryRoot $root -Arguments @('status','--porcelain=v1','--untracked-files=no')
    if ($status.stderr.Length -ne 0) { throw 'Affected-validation tracked-dirty observation emitted unexpected stderr.' }
    return [pscustomobject][ordered]@{ repository_root=$observedRoot; head_commit=[string]$lines[1]; head_tree=[string]$lines[2]; tracked_status=[string]$status.stdout; clean=($status.stdout.Length -eq 0) }
}

function Assert-MorphospaceAffectedStableObservation {
    param(
        [Parameter(Mandatory = $true)][object]$Before,
        [Parameter(Mandatory = $true)][object]$After,
        [Parameter(Mandatory = $true)][object]$ExpectedHead
    )

    $rootComparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not [bool]$Before.clean -or -not [bool]$After.clean -or [string]$Before.tracked_status -cne '' -or [string]$After.tracked_status -cne '') {
        throw 'Affected-validation batched observation encountered tracked worktree dirt.'
    }
    if (-not ([string]$Before.repository_root).Equals([string]$After.repository_root,$rootComparison)) { throw 'Affected-validation repository root drifted during batched observation.' }
    if ([string]$Before.head_commit -cne [string]$After.head_commit -or [string]$Before.head_tree -cne [string]$After.head_tree) { throw 'Affected-validation HEAD commit/tree drifted during batched observation.' }
    if ([string]$Before.head_commit -cne [string]$ExpectedHead.commit -or [string]$Before.head_tree -cne [string]$ExpectedHead.tree) { throw 'Affected-validation batched observation is not bound to the exact requested head.' }
}

function ConvertTo-MorphospaceAffectedBatchPathSet {
    param([Parameter(Mandatory = $true)][object[]]$Paths)

    $exact = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $casePaths = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($Paths)) {
        $path = ConvertTo-MorphospaceAffectedPath -Path ([string]$candidate)
        if (-not $exact.Add($path)) { throw "Affected-validation batch path set repeats exact path '$path'." }
        if ($casePaths.ContainsKey($path) -and $casePaths[$path] -cne $path) { throw "Affected-validation batch path set contains case-colliding path '$path'." }
        $casePaths[$path] = $path
    }
    [string[]]$result = @($exact)
    [System.Array]::Sort($result,[System.StringComparer]::Ordinal)
    return $result
}

function ConvertFrom-MorphospaceAffectedBatchHashOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Stdout,
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][object]$Inventory
    )

    if ($Paths.Count -eq 0) { throw 'Affected-validation working-byte hash batch is empty.' }
    if (-not $Stdout.EndsWith("`n",[System.StringComparison]::Ordinal)) { throw 'Affected-validation working-byte hash batch lacks its terminal LF.' }
    $lines = @($Stdout.Split([char]10,[System.StringSplitOptions]::None))
    if ($lines.Count -ne $Paths.Count + 1 -or $lines[-1] -cne '') { throw 'Affected-validation working-byte hash batch returned a missing or extra record.' }
    $records = [System.Collections.Generic.List[object]]::new()
    for ($index=0; $index -lt $Paths.Count; $index++) {
        $hash = ([string]$lines[$index]).TrimEnd([char]13)
        $path = [string]$Paths[$index]
        if ($hash -cnotmatch '^[0-9a-f]{40}$') { throw "Affected-validation working-byte hash batch returned a malformed hash for '$path'." }
        $entry = Get-MorphospaceAffectedInventoryEntry -Inventory $Inventory -Path $path
        if ($null -eq $entry) { throw "Affected-validation batch path is missing from the exact-head tree inventory: $path" }
        if ([string]$entry.type -cne 'blob' -or [string]$entry.blob -cne $hash) { throw "Affected-validation working bytes do not match the exact-head blob for '$path'." }
        $records.Add([pscustomobject][ordered]@{ ordinal=$index; path=$path; mode=[string]$entry.mode; tree_blob=[string]$entry.blob; working_blob=$hash })
    }
    return @($records.ToArray())
}

function Assert-MorphospaceAffectedBatchedWorkingBytes {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$ExpectedHead,
        [Parameter(Mandatory = $true)][object]$Inventory,
        [Parameter(Mandatory = $true)][object[]]$Paths
    )

    if ([string]$Inventory.commit -cne [string]$ExpectedHead.commit) { throw 'Affected-validation tree inventory is not bound to the exact requested head.' }
    [string[]]$orderedPaths = @(ConvertTo-MorphospaceAffectedBatchPathSet -Paths $Paths)
    foreach ($path in $orderedPaths) {
        $entry = Get-MorphospaceAffectedInventoryEntry -Inventory $Inventory -Path $path
        if ($null -eq $entry -or [string]$entry.type -cne 'blob' -or @('100644','100755') -cnotcontains [string]$entry.mode) {
            throw "Affected-validation batch path is not a tracked regular file in the exact head: $path"
        }
        $fullPath = Join-Path ([System.IO.Path]::GetFullPath($RepositoryRoot)) $path
        if (-not [System.IO.File]::Exists($fullPath)) { throw "Affected-validation batch path is absent from the exact checkout: $path" }
    }
    $before = Get-MorphospaceAffectedWorktreeObservation -RepositoryRoot $RepositoryRoot
    $inputText = ($orderedPaths -join "`n") + "`n"
    $hashResult = Invoke-MorphospaceAffectedGit -RepositoryRoot $RepositoryRoot -Arguments @('hash-object','--stdin-paths') -StandardInputText $inputText
    if ($hashResult.stderr.Length -ne 0) { throw 'Affected-validation working-byte hash batch emitted unexpected stderr.' }
    $records = @(ConvertFrom-MorphospaceAffectedBatchHashOutput -Stdout $hashResult.stdout -Paths $orderedPaths -Inventory $Inventory)
    if ($records.Count -ne $orderedPaths.Count) { throw 'Affected-validation working-byte hash batch record count changed after parsing.' }
    for ($index=0; $index -lt $records.Count; $index++) {
        if ([long]$records[$index].ordinal -ne $index -or [string]$records[$index].path -cne [string]$orderedPaths[$index]) { throw 'Affected-validation working-byte hash batch record order/path identity drifted.' }
    }
    $after = Get-MorphospaceAffectedWorktreeObservation -RepositoryRoot $RepositoryRoot
    Assert-MorphospaceAffectedStableObservation -Before $before -After $after -ExpectedHead $ExpectedHead
    return [pscustomobject][ordered]@{ before=$before; after=$after; path_count=$orderedPaths.Count; paths=@($orderedPaths); records=@($records) }
}

function ConvertTo-MorphospaceAffectedGlobRegex {
    param([Parameter(Mandatory = $true)][string]$Pattern)

    [void](ConvertTo-MorphospaceAffectedPath -Path $Pattern.Replace('*', 'x').Replace('?', 'x'))
    $builder = [System.Text.StringBuilder]::new('^')
    for ($index = 0; $index -lt $Pattern.Length; $index++) {
        $character = $Pattern[$index]
        if ($character -eq '*') {
            if ($index + 1 -lt $Pattern.Length -and $Pattern[$index + 1] -eq '*') {
                [void]$builder.Append('.*')
                $index++
            } else { [void]$builder.Append('[^/]*') }
        } elseif ($character -eq '?') { [void]$builder.Append('[^/]') }
        else { [void]$builder.Append([regex]::Escape([string]$character)) }
    }
    [void]$builder.Append('$')
    return [regex]::new($builder.ToString(), [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Assert-MorphospaceAffectedUniqueIds {
    param([object[]]$Values, [string]$Property, [string]$Context)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($value in @($Values)) {
        $id = [string]$value.$Property
        if ($id -cnotmatch '^[a-z0-9][a-z0-9-]{1,95}$') { throw "$Context has invalid identifier '$id'." }
        if (-not $seen.Add($id)) { throw "$Context contains duplicate identifier '$id'." }
    }
}

function Get-MorphospaceAffectedExecutionAfterChecks {
    param([Parameter(Mandatory = $true)][object]$Check)
    if ($null -eq $Check.PSObject.Properties['execution_after_checks']) { return @() }
    return @($Check.execution_after_checks | ForEach-Object { [string]$_ })
}

function Test-MorphospaceAffectedValidationRegistry {
    param(
        [Parameter(Mandatory = $true)][object]$Registry,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$SchemaPath
    )

    if (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $Registry) -SchemaFile ([System.IO.Path]::GetFullPath($SchemaPath)) -ErrorAction Stop)) { throw 'Affected-validation registry fails its closed schema.' }
    if ([string]$Registry.schema -cne 'rusty.morphospace.workflow.affected_validation_registry.v1') { throw 'Affected-validation registry schema is unsupported.' }
    if ([string]$Registry.registry_id -cnotmatch '^[a-z0-9][a-z0-9-]{1,95}$' -or [long]$Registry.revision -lt 1) { throw 'Affected-validation registry identity is invalid.' }
    if ([string]$Registry.repository_id -cnotmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') { throw 'Affected-validation repository identity is invalid.' }
    foreach ($claim in @('selection_only', 'executes_checks', 'acceptance_authority', 'publication_authority')) {
        if ($null -eq $Registry.claims.PSObject.Properties[$claim]) { throw "Affected-validation registry is missing claim '$claim'." }
    }
    if (-not [bool]$Registry.claims.selection_only -or [bool]$Registry.claims.executes_checks -or [bool]$Registry.claims.acceptance_authority -or [bool]$Registry.claims.publication_authority) {
        throw 'Affected-validation registry must remain selection-only and non-authorizing.'
    }

    Assert-MorphospaceAffectedUniqueIds -Values @($Registry.path_sets) -Property path_set_id -Context 'Affected-validation path sets'
    Assert-MorphospaceAffectedUniqueIds -Values @($Registry.checks) -Property check_id -Context 'Affected-validation checks'
    $invocationSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $pathSetMap = @{}
    foreach ($pathSet in @($Registry.path_sets)) {
        if (@($pathSet.patterns).Count -eq 0) { throw "Path set '$($pathSet.path_set_id)' has no patterns." }
        $patternList = [System.Collections.Generic.List[object]]::new()
        foreach ($pattern in @($pathSet.patterns)) {
            $text = [string]$pattern
            [void]$patternList.Add((ConvertTo-MorphospaceAffectedGlobRegex -Pattern $text))
        }
        $pathSetMap[[string]$pathSet.path_set_id] = @($patternList.ToArray())
    }
    $declarationKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $previousDeclarationKey = $null
    foreach ($declaration in @($Registry.dependency_declarations)) {
        $importer = ConvertTo-MorphospaceAffectedPath -Path ([string]$declaration.importer)
        $variable = [string]$declaration.variable
        $key = "$importer|$variable"
        if ($importer -cnotmatch '^scripts/.+\.ps(?:m)?1$' -or $variable -cnotmatch '^[A-Za-z_][A-Za-z0-9_:.-]*$' -or [int]$declaration.count -lt 1 -or -not $declarationKeys.Add($key)) { throw "Affected-validation dependency declaration has an invalid or duplicate identity: $key" }
        if ($null -ne $previousDeclarationKey -and [StringComparer]::Ordinal.Compare($previousDeclarationKey,$key) -ge 0) { throw 'Affected-validation dependency declarations are not in strict ordinal order.' }
        if (-not [IO.File]::Exists((Join-Path $RepositoryRoot $importer))) { throw "Affected-validation dependency declaration importer is absent: $importer" }
        if ($null -ne $declaration.PSObject.Properties['target_paths']) {
            $previousTarget = $null
            foreach ($targetValue in @($declaration.target_paths)) {
                $target = ConvertTo-MorphospaceAffectedPath -Path ([string]$targetValue)
                if ($target -cnotmatch '^scripts/.+\.ps(?:m)?1$' -or ($null -ne $previousTarget -and [StringComparer]::Ordinal.Compare($previousTarget,$target) -ge 0) -or -not [IO.File]::Exists((Join-Path $RepositoryRoot $target))) { throw "Affected-validation dependency declaration target is absent, duplicate, or not ordinal: $key -> $target" }
                $previousTarget = $target
            }
        } elseif ([string]$declaration.classification -cne 'authenticated-external-command') { throw "Affected-validation dependency declaration classification is unsupported: $key" }
        $previousDeclarationKey = $key
    }
    $checkMap = @{}
    foreach ($check in @($Registry.checks)) {
        $checkId = [string]$check.check_id
        if (@('quick', 'standard', 'deep') -cnotcontains [string]$check.minimum_tier) { throw "Check '$checkId' has invalid tier." }
        if (@('disabled', 'exact-host', 'portable') -cnotcontains [string]$check.cache_policy) { throw "Check '$checkId' has invalid cache policy." }
        if ([long]$check.budget_seconds -lt 1 -or [long]$check.budget_seconds -gt 86400) { throw "Check '$checkId' has invalid budget." }
        if ($null -ne $check.PSObject.Properties['aggregate_role']) {
            $exactArguments = @($check.arguments).Count -eq 3 -and [string]$check.arguments[0] -ceq '-SelfTest' -and [string]$check.arguments[1] -ceq '-Tier' -and [string]$check.arguments[2] -ceq 'Deep'
            $exactPlatforms = @($check.platforms).Count -eq 1 -and [string]$check.platforms[0] -ceq 'windows'
            if ([string]$check.aggregate_role -cne 'work-environment-deep-v1' -or $checkId -cne 'work-environment-deep' -or [string]$check.command_path -cne 'scripts/Test-WorkEnvironment.ps1' -or -not $exactArguments -or -not $exactPlatforms -or [string]$check.minimum_tier -cne 'deep' -or [string]$check.cache_policy -cne 'disabled' -or [string]$check.external_state -cne 'none' -or [bool]$check.always_run) {
                throw "Aggregate role '$([string]$check.aggregate_role)' is not the exact closed Work Environment Deep aggregate."
            }
        }
        $commandPath = ConvertTo-MorphospaceAffectedPath -Path ([string]$check.command_path)
        $invocationIdentity = Get-MorphospaceCanonicalJsonSha256 -Value ([pscustomobject][ordered]@{command_path=$commandPath;arguments=@($check.arguments)})
        if (-not $invocationSet.Add($invocationIdentity)) { throw "Affected-validation checks repeat exact command/argument invocation '$commandPath'." }
        foreach ($field in @('trigger_path_sets', 'consume_path_sets')) {
            foreach ($pathSetId in @($check.$field)) { if (-not $pathSetMap.ContainsKey([string]$pathSetId)) { throw "Check '$checkId' references unknown path set '$pathSetId'." } }
        }
        $checkMap[$checkId] = $check
    }
    foreach ($id in @($Registry.always_run_check_ids)) { if (-not $checkMap.ContainsKey([string]$id)) { throw "Unknown always-run check '$id'." } }
    foreach ($id in @($Registry.deep_escalation_path_sets)) { if (-not $pathSetMap.ContainsKey([string]$id)) { throw "Unknown deep-escalation path set '$id'." } }
    foreach ($check in @($Registry.checks)) {
        $checkId = [string]$check.check_id
        $semanticDependencies = @($check.prerequisite_checks | ForEach-Object { [string]$_ })
        $executionDependencies = @(Get-MorphospaceAffectedExecutionAfterChecks -Check $check)
        $semanticSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $executionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($dependencyKind in @(
            [pscustomobject]@{ name='prerequisite'; values=$semanticDependencies; seen=$semanticSet },
            [pscustomobject]@{ name='execution-order dependency'; values=$executionDependencies; seen=$executionSet }
        )) {
            foreach ($id in @($dependencyKind.values)) {
                if ([string]$id -ceq $checkId) { throw "Check '$checkId' cannot depend on itself." }
                if (-not $dependencyKind.seen.Add([string]$id)) { throw "Check '$checkId' repeats $($dependencyKind.name) '$id'." }
                if (-not $checkMap.ContainsKey([string]$id)) { throw "Check '$checkId' references unknown $($dependencyKind.name) '$id'." }
                foreach ($platform in @($check.platforms)) {
                    if (@($checkMap[[string]$id].platforms) -cnotcontains [string]$platform) { throw "Check '$checkId' has an unsatisfied cross-platform $($dependencyKind.name) '$id'." }
                }
            }
        }
        foreach ($id in $executionDependencies) {
            if ($semanticSet.Contains([string]$id)) { throw "Check '$checkId' lists '$id' as both a semantic prerequisite and an execution-order dependency." }
            $providedContracts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($contract in @($checkMap[[string]$id].provides_contracts)) { [void]$providedContracts.Add([string]$contract) }
            foreach ($contract in @($check.consumes_contracts)) {
                if ($providedContracts.Contains([string]$contract)) { throw "Check '$checkId' consumes contract '$contract' from execution-order dependency '$id'; it must be a semantic prerequisite." }
            }
        }
        if ([bool]$check.always_run -and @($Registry.always_run_check_ids) -cnotcontains [string]$check.check_id) { throw "Check '$($check.check_id)' is locally always-run but absent from the registry always-run list." }
    }
    $publicBoundary = $checkMap['public-boundary']
    if ($null -eq $publicBoundary) { throw 'Affected-validation registry requires the public-boundary check.' }
    foreach ($pathSetId in @($pathSetMap.Keys)) {
        if (@($publicBoundary.trigger_path_sets) -cnotcontains [string]$pathSetId) { throw "Public-boundary does not trigger for publishable path set '$pathSetId'." }
        if (@($publicBoundary.consume_path_sets) -cnotcontains [string]$pathSetId) { throw "Public-boundary does not cover publishable path set '$pathSetId'." }
    }

    $visiting = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    function Visit-AffectedCheck([string]$Id) {
        if ($visited.Contains($Id)) { return }
        if (-not $visiting.Add($Id)) { throw "Affected-validation prerequisite cycle contains '$Id'." }
        foreach ($dependency in @(@($checkMap[$Id].prerequisite_checks) + @(Get-MorphospaceAffectedExecutionAfterChecks -Check $checkMap[$Id]))) { Visit-AffectedCheck ([string]$dependency) }
        [void]$visiting.Remove($Id)
        [void]$visited.Add($Id)
    }
    foreach ($id in @($checkMap.Keys)) { Visit-AffectedCheck ([string]$id) }
    return [pscustomobject]@{ path_sets = $pathSetMap; checks = $checkMap; dependency_declarations = @($Registry.dependency_declarations) }
}

function Get-MorphospaceAffectedTopologicalOrder {
    param([Parameter(Mandatory = $true)][hashtable]$Checks, [Parameter(Mandatory = $true)][hashtable]$SelectedReasons)
    $pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($id in @($SelectedReasons.Keys)) { [void]$pending.Add([string]$id) }
    $ordered = [System.Collections.Generic.List[string]]::new()
    while ($pending.Count -gt 0) {
        $ready = [System.Collections.Generic.List[string]]::new()
        foreach ($id in @($pending)) {
            $dependencies = [System.Collections.Generic.List[string]]::new()
            foreach ($dependency in @($Checks[$id].prerequisite_checks)) { [void]$dependencies.Add([string]$dependency) }
            foreach ($dependency in @(Get-MorphospaceAffectedExecutionAfterChecks -Check $Checks[$id])) {
                if ($SelectedReasons.ContainsKey([string]$dependency)) { [void]$dependencies.Add([string]$dependency) }
            }
            if (@($dependencies | Where-Object { -not $ordered.Contains($_) }).Count -eq 0) { [void]$ready.Add($id) }
        }
        if ($ready.Count -eq 0) { throw 'Affected-validation selected closure has no topologically ready check.' }
        $next = @($ready.ToArray()); [Array]::Sort($next, [System.StringComparer]::Ordinal)
        foreach ($id in $next) { [void]$pending.Remove($id); [void]$ordered.Add($id) }
    }
    return @($ordered.ToArray())
}

function Get-MorphospaceAffectedGitIdentity {
    param([string]$RepositoryRoot, [string]$Revision)
    $commit = (Invoke-MorphospaceAffectedGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--verify', "$Revision^{commit}")).stdout.Trim()
    if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw "Revision did not resolve to a full commit: $Revision" }
    $tree = (Invoke-MorphospaceAffectedGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--verify', "$commit^{tree}")).stdout.Trim()
    if ($tree -cnotmatch '^[0-9a-f]{40}$') { throw "Commit did not resolve to a full tree: $commit" }
    return [pscustomobject][ordered]@{ commit = $commit; tree = $tree }
}

function Get-MorphospaceAffectedTreeEntry {
    param([string]$RepositoryRoot, [string]$Commit, [AllowNull()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $result = Invoke-MorphospaceAffectedGit -RepositoryRoot $RepositoryRoot -Arguments @('ls-tree', '-z', $Commit, '--', ":(literal)$Path")
    if ($result.stdout.Length -eq 0) { return $null }
    $entry = $result.stdout.TrimEnd([char]0)
    if ($entry -notmatch '^(?<mode>[0-9]{6}) (?<type>blob|tree|commit) (?<sha>[0-9a-f]{40})\t(?<path>.+)$') { throw "Unexpected git ls-tree result for '$Path'." }
    if ($Matches.path -cne $Path) { throw "git ls-tree returned a different path for '$Path'." }
    return [pscustomobject]@{ mode = $Matches.mode; blob = $Matches.sha }
}

function Get-MorphospaceAffectedChanges {
    param([string]$RepositoryRoot, [string]$BaseCommit, [string]$HeadCommit)
    $result = Invoke-MorphospaceAffectedGit -RepositoryRoot $RepositoryRoot -Arguments @('diff', '--name-status', '-z', '--find-renames', $BaseCommit, $HeadCommit)
    if ($result.stdout.Length -eq 0) { return @() }
    $tokens = @($result.stdout.Split([char]0, [System.StringSplitOptions]::None))
    if ($tokens.Count -gt 0 -and $tokens[-1] -eq '') { $tokens = @($tokens[0..($tokens.Count - 2)]) }
    $changes = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $index = 0
    while ($index -lt $tokens.Count) {
        $status = [string]$tokens[$index]; $index++
        if ($status -cnotmatch '^(?:[ADMT]|[RC](?:[0-9]{1,2}|100))$') { throw "Unexpected or unsupported git diff status '$status'." }
        $kind = $status.Substring(0, 1)
        $oldPath = $null; $newPath = $null
        if ($kind -in @('R', 'C')) {
            if ($index + 1 -ge $tokens.Count) { throw "Truncated git diff record '$status'." }
            $oldPath = ConvertTo-MorphospaceAffectedPath -Path ([string]$tokens[$index]); $index++
            $newPath = ConvertTo-MorphospaceAffectedPath -Path ([string]$tokens[$index]); $index++
        } else {
            if ($index -ge $tokens.Count) { throw "Truncated git diff record '$status'." }
            $path = ConvertTo-MorphospaceAffectedPath -Path ([string]$tokens[$index]); $index++
            if ($kind -ne 'A') { $oldPath = $path }
            if ($kind -ne 'D') { $newPath = $path }
        }
        $recordPaths = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $oldPath) { [void]$recordPaths.Add([string]$oldPath) }
        if ($null -ne $newPath -and ($null -eq $oldPath -or [string]$newPath -cne [string]$oldPath)) { [void]$recordPaths.Add([string]$newPath) }
        foreach ($path in $recordPaths) { if (-not $seen.Add($path)) { throw "Changed paths contain a repeated exact path '$path'." } }
        $oldEntry = Get-MorphospaceAffectedTreeEntry -RepositoryRoot $RepositoryRoot -Commit $BaseCommit -Path $oldPath
        $newEntry = Get-MorphospaceAffectedTreeEntry -RepositoryRoot $RepositoryRoot -Commit $HeadCommit -Path $newPath
        if ($kind -ne 'A' -and $null -eq $oldEntry) { throw "Git diff status '$status' requires an old tree entry for '$oldPath'." }
        if ($kind -ne 'D' -and $null -eq $newEntry) { throw "Git diff status '$status' requires a new tree entry for '$newPath'." }
        $changes.Add([pscustomobject][ordered]@{
            status = $status
            old_path = $oldPath
            new_path = $newPath
            old_mode = $(if ($null -eq $oldEntry) { $null } else { [string]$oldEntry.mode })
            new_mode = $(if ($null -eq $newEntry) { $null } else { [string]$newEntry.mode })
            old_blob = $(if ($null -eq $oldEntry) { $null } else { [string]$oldEntry.blob })
            new_blob = $(if ($null -eq $newEntry) { $null } else { [string]$newEntry.blob })
        })
    }
    $changeArray = @($changes.ToArray())
    $comparison = [System.Comparison[object]]{
        param($left, $right)
        $leftPath = if ($null -ne $left.new_path) { [string]$left.new_path } else { [string]$left.old_path }
        $rightPath = if ($null -ne $right.new_path) { [string]$right.new_path } else { [string]$right.old_path }
        return [System.StringComparer]::Ordinal.Compare($leftPath, $rightPath)
    }
    [Array]::Sort($changeArray, $comparison)
    return @($changeArray)
}

function Test-MorphospaceAffectedPathCaseCollision {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Paths)

    $observed = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($Paths)) {
        if ($null -eq $candidate) { continue }
        $path = ConvertTo-MorphospaceAffectedPath -Path ([string]$candidate)
        if ($observed.ContainsKey($path)) {
            if ($observed[$path] -cne $path) { return $true }
            continue
        }
        $observed[$path] = $path
    }
    return $false
}

function Test-MorphospaceAffectedTreeCaseCollision {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    $inventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $RepositoryRoot -Commit $Commit
    return [bool]$inventory.case_collision
}

function Test-MorphospaceAffectedPathSetMatch {
    param([string]$Path, [object[]]$Patterns)
    foreach ($pattern in @($Patterns)) { if ($pattern.IsMatch($Path)) { return $true } }
    return $false
}

function Resolve-MorphospaceAffectedValidation {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$BaseRevision,
        [Parameter(Mandatory = $true)][string]$HeadRevision,
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [ValidateSet('quick', 'standard', 'deep')][string]$RequestedTier = 'quick'
    )

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $initialObservation = Get-MorphospaceAffectedWorktreeObservation -RepositoryRoot $root
    if (-not [bool]$initialObservation.clean) { throw 'Affected validation requires a clean tracked source worktree.' }
    $base = Get-MorphospaceAffectedGitIdentity -RepositoryRoot $root -Revision $BaseRevision
    $head = Get-MorphospaceAffectedGitIdentity -RepositoryRoot $root -Revision $HeadRevision
    if ([string]$initialObservation.head_commit -cne $head.commit -or [string]$initialObservation.head_tree -cne $head.tree) { throw 'Affected validation requires the clean worktree HEAD to equal the observed head identity.' }
    $ancestry = Invoke-MorphospaceAffectedGit -RepositoryRoot $root -Arguments @('merge-base', '--is-ancestor', $base.commit, $head.commit) -AllowFailure
    if ($ancestry.exit_code -ne 0) { throw 'Affected validation requires base to be an ancestor of head.' }

    $registryFullPath = [System.IO.Path]::GetFullPath($RegistryPath)
    $rootPrefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $registryFullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Affected-validation registry must be inside RepositoryRoot.' }
    $registryRelativePath = ConvertTo-MorphospaceAffectedPath -Path ([System.IO.Path]::GetRelativePath($root, $registryFullPath).Replace('\', '/'))
    $inventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $root -Commit $head.commit
    $registryTreeEntry = Get-MorphospaceAffectedInventoryEntry -Inventory $inventory -Path $registryRelativePath
    if ($null -eq $registryTreeEntry -or [string]$registryTreeEntry.mode -cne '100644') { throw 'Affected-validation registry must be a tracked regular file in the exact head.' }
    $registryBytesBefore = [System.IO.File]::ReadAllBytes($registryFullPath)
    $registry = Read-MorphospaceProtocolJson -Path $registryFullPath
    $registrySchemaPath = Join-Path $root 'schemas/affected-validation-registry-v1.schema.json'
    $registrySchemaRelativePath = 'schemas/affected-validation-registry-v1.schema.json'
    $registrySchemaEntry = Get-MorphospaceAffectedInventoryEntry -Inventory $inventory -Path $registrySchemaRelativePath
    if ($null -eq $registrySchemaEntry -or [string]$registrySchemaEntry.mode -cne '100644' -or -not [System.IO.File]::Exists($registrySchemaPath)) { throw 'Affected-validation registry schema must be a tracked regular file in the exact head.' }
    $commandPaths = [System.Collections.Generic.List[string]]::new()
    $commandPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($check in @($registry.checks)) {
        $commandRelative = ConvertTo-MorphospaceAffectedPath -Path ([string]$check.command_path)
        if ($commandPathSet.Add($commandRelative)) { $commandPaths.Add($commandRelative) }
    }
    $batchPaths = [System.Collections.Generic.List[object]]::new()
    [void]$batchPaths.Add($registryRelativePath)
    [void]$batchPaths.Add($registrySchemaRelativePath)
    foreach ($commandPath in $commandPaths) { [void]$batchPaths.Add($commandPath) }
    $workingBatch = Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $root -ExpectedHead $head -Inventory $inventory -Paths @($batchPaths.ToArray())
    $registryBytesAfter = [System.IO.File]::ReadAllBytes($registryFullPath)
    if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($registryBytesBefore,$registryBytesAfter)) { throw 'Affected-validation registry raw bytes drifted across the exact working-byte batch.' }
    $compiled = Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $root -SchemaPath $registrySchemaPath
    $compiledObservation = Get-MorphospaceAffectedWorktreeObservation -RepositoryRoot $root
    Assert-MorphospaceAffectedStableObservation -Before $workingBatch.after -After $compiledObservation -ExpectedHead $head
    $changes = @(Get-MorphospaceAffectedChanges -RepositoryRoot $root -BaseCommit $base.commit -HeadCommit $head.commit)
    $changedPathValues = [System.Collections.Generic.List[object]]::new()
    foreach ($change in $changes) {
        if ($null -ne $change.old_path) { [void]$changedPathValues.Add($change.old_path) }
        if ($null -ne $change.new_path) { [void]$changedPathValues.Add($change.new_path) }
    }
    $caseCollision = [bool]$inventory.case_collision -or
        (Test-MorphospaceAffectedPathCaseCollision -Paths @($changedPathValues.ToArray()))
    $matchedPathSets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $unmapped = $false
    $ambiguous = $false
    foreach ($change in $changes) {
        foreach ($path in @($change.old_path, $change.new_path)) {
            if ($null -eq $path) { continue }
            $pathMatchCount = 0
            foreach ($pathSetId in @($compiled.path_sets.Keys)) {
                if (Test-MorphospaceAffectedPathSetMatch -Path ([string]$path) -Patterns @($compiled.path_sets[$pathSetId])) {
                    [void]$matchedPathSets.Add([string]$pathSetId)
                    $pathMatchCount++
                }
            }
            if ($pathMatchCount -eq 0) { $unmapped = $true }
            if ($pathMatchCount -gt 1) { $ambiguous = $true }
        }
    }

    $reasonCodes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $fullDeep = $false
    if ($unmapped) { $fullDeep = $true; [void]$reasonCodes.Add('unmapped-path') }
    if ($ambiguous) { $fullDeep = $true; [void]$reasonCodes.Add('ambiguous-path-mapping') }
    if ($caseCollision) { $fullDeep = $true; [void]$reasonCodes.Add('case-colliding-paths') }
    foreach ($id in @($registry.deep_escalation_path_sets)) {
        if ($matchedPathSets.Contains([string]$id)) { $fullDeep = $true; [void]$reasonCodes.Add('trust-root-path-changed') }
    }
    if ($RequestedTier -ceq 'deep') { $fullDeep = $true; [void]$reasonCodes.Add('deep-requested') }
    if ($changes.Count -eq 0) { [void]$reasonCodes.Add('no-changed-paths') }

    $selectedReasons = @{}
    function Add-AffectedSelection([string]$Id, [string]$Reason) {
        if (-not $selectedReasons.ContainsKey($Id)) { $selectedReasons[$Id] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal) }
        [void]$selectedReasons[$Id].Add($Reason)
    }
    foreach ($id in @($registry.always_run_check_ids)) { Add-AffectedSelection ([string]$id) 'always-run' }
    if ($fullDeep) {
        foreach ($check in @($registry.checks)) {
            $isAggregateOnly = $null -ne $check.PSObject.Properties['aggregate_role'] -and [string]$check.aggregate_role -ceq 'work-environment-deep-v1'
            if ($isAggregateOnly -and $RequestedTier -cne 'deep') { continue }
            Add-AffectedSelection ([string]$check.check_id) 'full-deep'
        }
        foreach ($check in @($registry.checks | Where-Object { $null -ne $_.PSObject.Properties['aggregate_role'] -and [string]$_.aggregate_role -ceq 'work-environment-deep-v1' })) {
            foreach ($pathSetId in @($check.trigger_path_sets)) {
                if ($matchedPathSets.Contains([string]$pathSetId)) { Add-AffectedSelection ([string]$check.check_id) "path-set:$pathSetId" }
            }
            $commandPath = [string]$check.command_path
            foreach ($change in $changes) {
                if (($null -ne $change.old_path -and [string]$change.old_path -ceq $commandPath) -or
                    ($null -ne $change.new_path -and [string]$change.new_path -ceq $commandPath)) {
                    Add-AffectedSelection ([string]$check.check_id) 'command-path-changed'
                }
            }
        }
    } else {
        foreach ($check in @($registry.checks)) {
            foreach ($pathSetId in @($check.trigger_path_sets)) {
                if ($matchedPathSets.Contains([string]$pathSetId)) { Add-AffectedSelection ([string]$check.check_id) "path-set:$pathSetId" }
            }
            $commandPath = [string]$check.command_path
            foreach ($change in $changes) {
                if (($null -ne $change.old_path -and [string]$change.old_path -ceq $commandPath) -or
                    ($null -ne $change.new_path -and [string]$change.new_path -ceq $commandPath)) {
                    Add-AffectedSelection ([string]$check.check_id) 'command-path-changed'
                }
            }
        }
    }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($id in @($selectedReasons.Keys)) {
            foreach ($dependency in @($compiled.checks[$id].prerequisite_checks)) {
                $dependencyId = [string]$dependency
                if (-not $selectedReasons.ContainsKey($dependencyId)) { Add-AffectedSelection $dependencyId "prerequisite-of:$id"; $changed = $true }
            }
            foreach ($contract in @($compiled.checks[$id].provides_contracts)) {
                foreach ($consumer in @($registry.checks)) {
                    $consumerId = [string]$consumer.check_id
                    if (@($consumer.consumes_contracts) -ccontains [string]$contract -and -not $selectedReasons.ContainsKey($consumerId)) {
                        Add-AffectedSelection $consumerId "consumer-of:${id}:$contract"
                        $changed = $true
                    }
                }
            }
        }
    }

    $tierRank = @{ quick = 0; standard = 1; deep = 2 }
    $effectiveTier = $RequestedTier
    foreach ($id in @($selectedReasons.Keys)) {
        $tier = [string]$compiled.checks[$id].minimum_tier
        if ($tierRank[$tier] -gt $tierRank[$effectiveTier]) { $effectiveTier = $tier }
    }
    if ($fullDeep) { $effectiveTier = 'deep' }
    $selected = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $budget = [long]0
    foreach ($id in @(Get-MorphospaceAffectedTopologicalOrder -Checks $compiled.checks -SelectedReasons $selectedReasons)) {
        $check = $compiled.checks[$id]
        $reasons = @($selectedReasons[$id]); [Array]::Sort($reasons, [System.StringComparer]::Ordinal)
        $selected.Add([pscustomobject][ordered]@{ check_id=$id; platforms=@($check.platforms); minimum_tier=[string]$check.minimum_tier; reasons=@($reasons); budget_seconds=[long]$check.budget_seconds; cache_policy=[string]$check.cache_policy })
        $budget += [long]$check.budget_seconds
    }
    foreach ($check in @($registry.checks | Sort-Object check_id)) {
        $id = [string]$check.check_id
        if (-not $selectedReasons.ContainsKey($id)) {
            $skipped.Add([pscustomobject][ordered]@{ check_id=$id; platforms=@($check.platforms); minimum_tier=[string]$check.minimum_tier; reasons=@('not-selected'); budget_seconds=[long]$check.budget_seconds; cache_policy=[string]$check.cache_policy })
        }
    }
    if ($reasonCodes.Count -eq 0) { [void]$reasonCodes.Add('affected-path-selection') }
    $reasonArray = @($reasonCodes); [Array]::Sort($reasonArray, [System.StringComparer]::Ordinal)
    $changedPathDigest = Get-MorphospaceCanonicalJsonSha256 -Value @($changes)
    $registryDigest = Get-MorphospaceCanonicalJsonSha256 -Value $registry
    $planWithoutHash = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.affected_validation_plan.v1'
        repository = [string]$registry.repository_id
        base = $base
        head = $head
        registry = [pscustomobject][ordered]@{ schema=[string]$registry.schema; registry_id=[string]$registry.registry_id; revision=[long]$registry.revision; sha256=$registryDigest }
        changed_paths = @($changes)
        changed_paths_sha256 = $changedPathDigest
        requested_tier = $RequestedTier
        effective_tier = $effectiveTier
        selection_mode = $(if ($fullDeep) { 'full-deep' } else { 'affected' })
        reason_codes = @($reasonArray)
        selected_checks = @($selected.ToArray())
        skipped_checks = @($skipped.ToArray())
        estimated_budget_seconds = $budget
        claims = [pscustomobject][ordered]@{ selection_only=$true; checks_executed=$false; acceptance_authority=$false; publication_authority=$false }
    }
    $planHash = Get-MorphospaceCanonicalJsonSha256 -Value $planWithoutHash
    $finalObservation = Get-MorphospaceAffectedWorktreeObservation -RepositoryRoot $root
    Assert-MorphospaceAffectedStableObservation -Before $compiledObservation -After $finalObservation -ExpectedHead $head
    return [pscustomobject][ordered]@{
        schema = $planWithoutHash.schema
        repository = $planWithoutHash.repository
        base = $planWithoutHash.base
        head = $planWithoutHash.head
        registry = $planWithoutHash.registry
        changed_paths = $planWithoutHash.changed_paths
        changed_paths_sha256 = $planWithoutHash.changed_paths_sha256
        requested_tier = $planWithoutHash.requested_tier
        effective_tier = $planWithoutHash.effective_tier
        selection_mode = $planWithoutHash.selection_mode
        reason_codes = $planWithoutHash.reason_codes
        selected_checks = $planWithoutHash.selected_checks
        skipped_checks = $planWithoutHash.skipped_checks
        estimated_budget_seconds = $planWithoutHash.estimated_budget_seconds
        plan_sha256 = $planHash
        claims = $planWithoutHash.claims
    }
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Test-MorphospaceAffectedValidationRegistry, Resolve-MorphospaceAffectedValidation, Get-MorphospaceAffectedTreeInventory, Assert-MorphospaceAffectedBatchedWorkingBytes
