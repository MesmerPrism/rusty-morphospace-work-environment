Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$protocolModule = Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1'
Microsoft.PowerShell.Core\Import-Module -Name $protocolModule

function Invoke-MorphospaceAffectedGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.WorkingDirectory = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $start.StandardOutputEncoding = $strictUtf8
    $start.StandardErrorEncoding = $strictUtf8
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'git did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
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
    $checkMap = @{}
    foreach ($check in @($Registry.checks)) {
        $checkId = [string]$check.check_id
        if (@('quick', 'standard', 'deep') -cnotcontains [string]$check.minimum_tier) { throw "Check '$checkId' has invalid tier." }
        if (@('disabled', 'exact-host', 'portable') -cnotcontains [string]$check.cache_policy) { throw "Check '$checkId' has invalid cache policy." }
        if ([long]$check.budget_seconds -lt 1 -or [long]$check.budget_seconds -gt 86400) { throw "Check '$checkId' has invalid budget." }
        [void](ConvertTo-MorphospaceAffectedPath -Path ([string]$check.command_path))
        foreach ($field in @('trigger_path_sets', 'consume_path_sets')) {
            foreach ($pathSetId in @($check.$field)) { if (-not $pathSetMap.ContainsKey([string]$pathSetId)) { throw "Check '$checkId' references unknown path set '$pathSetId'." } }
        }
        $checkMap[$checkId] = $check
    }
    foreach ($id in @($Registry.always_run_check_ids)) { if (-not $checkMap.ContainsKey([string]$id)) { throw "Unknown always-run check '$id'." } }
    foreach ($id in @($Registry.deep_escalation_path_sets)) { if (-not $pathSetMap.ContainsKey([string]$id)) { throw "Unknown deep-escalation path set '$id'." } }
    foreach ($check in @($Registry.checks)) {
        foreach ($id in @($check.prerequisite_checks)) {
            if (-not $checkMap.ContainsKey([string]$id)) { throw "Check '$($check.check_id)' references unknown prerequisite '$id'." }
            foreach ($platform in @($check.platforms)) {
                if (@($checkMap[[string]$id].platforms) -cnotcontains [string]$platform) { throw "Check '$($check.check_id)' has an unsatisfied cross-platform prerequisite '$id'." }
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
        foreach ($dependency in @($checkMap[$Id].prerequisite_checks)) { Visit-AffectedCheck ([string]$dependency) }
        [void]$visiting.Remove($Id)
        [void]$visited.Add($Id)
    }
    foreach ($id in @($checkMap.Keys)) { Visit-AffectedCheck ([string]$id) }
    return [pscustomobject]@{ path_sets = $pathSetMap; checks = $checkMap }
}

function Get-MorphospaceAffectedTopologicalOrder {
    param([Parameter(Mandatory = $true)][hashtable]$Checks, [Parameter(Mandatory = $true)][hashtable]$SelectedReasons)
    $pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($id in @($SelectedReasons.Keys)) { [void]$pending.Add([string]$id) }
    $ordered = [System.Collections.Generic.List[string]]::new()
    while ($pending.Count -gt 0) {
        $ready = [System.Collections.Generic.List[string]]::new()
        foreach ($id in @($pending)) {
            $dependencies = @($Checks[$id].prerequisite_checks | ForEach-Object { [string]$_ })
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

    $result = Invoke-MorphospaceAffectedGit -RepositoryRoot $RepositoryRoot -Arguments @('ls-tree', '-r', '-z', '--name-only', $Commit)
    $paths = @($result.stdout.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))
    return Test-MorphospaceAffectedPathCaseCollision -Paths $paths
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
    if (-not [System.IO.Directory]::Exists((Join-Path $root '.git')) -and
        (Invoke-MorphospaceAffectedGit -RepositoryRoot $root -Arguments @('rev-parse', '--is-inside-work-tree') -AllowFailure).exit_code -ne 0) { throw 'RepositoryRoot is not a Git worktree.' }
    $dirty = (Invoke-MorphospaceAffectedGit -RepositoryRoot $root -Arguments @('status', '--porcelain=v1', '--untracked-files=no')).stdout
    if ($dirty.Length -ne 0) { throw 'Affected validation requires a clean tracked source worktree.' }
    $base = Get-MorphospaceAffectedGitIdentity -RepositoryRoot $root -Revision $BaseRevision
    $head = Get-MorphospaceAffectedGitIdentity -RepositoryRoot $root -Revision $HeadRevision
    $current = Get-MorphospaceAffectedGitIdentity -RepositoryRoot $root -Revision 'HEAD'
    if ($current.commit -cne $head.commit -or $current.tree -cne $head.tree) { throw 'Affected validation requires the clean worktree HEAD to equal the observed head identity.' }
    $ancestry = Invoke-MorphospaceAffectedGit -RepositoryRoot $root -Arguments @('merge-base', '--is-ancestor', $base.commit, $head.commit) -AllowFailure
    if ($ancestry.exit_code -ne 0) { throw 'Affected validation requires base to be an ancestor of head.' }

    $registryFullPath = [System.IO.Path]::GetFullPath($RegistryPath)
    $rootPrefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $registryFullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Affected-validation registry must be inside RepositoryRoot.' }
    $registryRelativePath = ConvertTo-MorphospaceAffectedPath -Path ([System.IO.Path]::GetRelativePath($root, $registryFullPath).Replace('\', '/'))
    $registryTreeEntry = Get-MorphospaceAffectedTreeEntry -RepositoryRoot $root -Commit $head.commit -Path $registryRelativePath
    if ($null -eq $registryTreeEntry -or [string]$registryTreeEntry.mode -cne '100644') { throw 'Affected-validation registry must be a tracked regular file in the exact head.' }
    $registryWorktreeBlob = (Invoke-MorphospaceAffectedGit -RepositoryRoot $root -Arguments @('hash-object', "--path=$registryRelativePath", $registryFullPath)).stdout.Trim()
    if ($registryWorktreeBlob -cne [string]$registryTreeEntry.blob) { throw 'Affected-validation registry working bytes do not match the exact head blob after Git filters.' }
    $registry = Read-MorphospaceProtocolJson -Path $registryFullPath
    $registrySchemaPath = Join-Path $root 'schemas/affected-validation-registry-v1.schema.json'
    $registrySchemaEntry = Get-MorphospaceAffectedTreeEntry -RepositoryRoot $root -Commit $head.commit -Path 'schemas/affected-validation-registry-v1.schema.json'
    if ($null -eq $registrySchemaEntry -or [string]$registrySchemaEntry.mode -cne '100644' -or -not [System.IO.File]::Exists($registrySchemaPath)) { throw 'Affected-validation registry schema must be a tracked regular file in the exact head.' }
    $compiled = Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $root -SchemaPath $registrySchemaPath
    foreach ($check in @($registry.checks)) {
        $commandRelative = ConvertTo-MorphospaceAffectedPath -Path ([string]$check.command_path)
        $commandEntry = Get-MorphospaceAffectedTreeEntry -RepositoryRoot $root -Commit $head.commit -Path $commandRelative
        if ($null -eq $commandEntry -or [string]$commandEntry.mode -cnotmatch '^100(?:644|755)$') { throw "Check '$($check.check_id)' command must be a tracked regular file in the exact head: $commandRelative" }
        $commandFull = Join-Path $root $commandRelative
        if (-not [System.IO.File]::Exists($commandFull)) { throw "Check '$($check.check_id)' command is absent from the exact checkout: $commandRelative" }
        $commandWorktreeBlob = (Invoke-MorphospaceAffectedGit -RepositoryRoot $root -Arguments @('hash-object', "--path=$commandRelative", $commandFull)).stdout.Trim()
        if ($commandWorktreeBlob -cne [string]$commandEntry.blob) { throw "Check '$($check.check_id)' command working bytes do not match the exact head blob: $commandRelative" }
    }
    $changes = @(Get-MorphospaceAffectedChanges -RepositoryRoot $root -BaseCommit $base.commit -HeadCommit $head.commit)
    $changedPathValues = [System.Collections.Generic.List[object]]::new()
    foreach ($change in $changes) {
        if ($null -ne $change.old_path) { [void]$changedPathValues.Add($change.old_path) }
        if ($null -ne $change.new_path) { [void]$changedPathValues.Add($change.new_path) }
    }
    $caseCollision = (Test-MorphospaceAffectedTreeCaseCollision -RepositoryRoot $root -Commit $head.commit) -or
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
        foreach ($check in @($registry.checks)) { Add-AffectedSelection ([string]$check.check_id) 'full-deep' }
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

Microsoft.PowerShell.Core\Export-ModuleMember -Function Test-MorphospaceAffectedValidationRegistry, Resolve-MorphospaceAffectedValidation
