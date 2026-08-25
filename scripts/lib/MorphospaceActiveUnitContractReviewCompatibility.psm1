Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:MorphospaceActiveUnitContractReviewSourceRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
$script:MorphospaceActiveUnitContractReviewContentObservationModule = Import-Module (Join-Path $PSScriptRoot 'MorphospaceContentObservation.psm1') -PassThru

function Test-MorphospaceActiveUnitContractReviewPathInScope {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][object[]]$AllowedPaths
    )

    $candidatePath = $Candidate.Replace('\', '/').TrimEnd('/')
    foreach ($allowedRaw in @($AllowedPaths)) {
        $allowed = ([string]$allowedRaw).Replace('\', '/').TrimEnd('/')
        if (-not $allowed) { return $true }
        if ($candidatePath.Equals($allowed, [StringComparison]::OrdinalIgnoreCase) -or
            $candidatePath.StartsWith($allowed + '/', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Resolve-MorphospaceActiveUnitContractReviewDirectory {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not [IO.Directory]::Exists($Path)) { return $null }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $null }
        $resolved = (Resolve-Path -LiteralPath $item.FullName -ErrorAction Stop).ProviderPath
        if (-not $resolved) { return $null }
        $full = [IO.Path]::GetFullPath($resolved).TrimEnd('\', '/')
        Assert-MorphospaceNoReparseAncestor -Root $full -Candidate $full
        return $full
    } catch {
        return $null
    }
}

function Test-MorphospaceActiveUnitContractReviewRootOverlap {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $comparison = if ($env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($Left.Equals($Right, $comparison)) { return $true }
    $leftPrefix = $Left.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $rightPrefix = $Right.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $Left.StartsWith($rightPrefix, $comparison) -or $Right.StartsWith($leftPrefix, $comparison)
}

function Test-MorphospaceActiveUnitContractReviewTrackedSkillBinding {
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][string]$SkillId
    )

    # The compatibility exception is tied to this checked-out Work Environment
    # router, not to caller-provided bytes at a similarly named external path.
    $sourceRepositoryRoot = Resolve-MorphospaceActiveUnitContractReviewDirectory $script:MorphospaceActiveUnitContractReviewSourceRepositoryRoot
    if (-not $sourceRepositoryRoot) { return $false }
    $relative = "skills/$SkillId/SKILL.md"
    $sourcePath = Join-Path $sourceRepositoryRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $mappedPath = Join-Path $SkillRoot "$SkillId\SKILL.md"
    try {
        Assert-MorphospaceNoReparseAncestor -Root $sourceRepositoryRoot -Candidate $sourcePath
        Assert-MorphospaceNoReparseAncestor -Root $SkillRoot -Candidate $mappedPath
        foreach ($path in @($sourcePath, $mappedPath)) {
            if (-not [IO.File]::Exists($path)) { return $false }
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        }
        $git = Get-MorphospaceBoundExecutable -Name 'git'
        $headBlob = & $script:MorphospaceActiveUnitContractReviewContentObservationModule {
            param($GitExecutable, $RepositoryPath, $ExpectedExecutableSha256, $RevisionPath)
            Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('show', $RevisionPath) -ExpectedExecutableSha256 $ExpectedExecutableSha256 -TimeoutSeconds 30 -MaxOutputBytes 10485760
        } $git.path $sourceRepositoryRoot $git.sha256 "HEAD:$relative"
        if ($headBlob.exit_code -ne 0) { return $false }
        $headHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$headBlob.stdout))
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        $mappedHash = (Get-FileHash -LiteralPath $mappedPath -Algorithm SHA256).Hash
        return $headHash -ceq $sourceHash -and $sourceHash -ceq $mappedHash
    } catch {
        return $false
    }
}

function Test-MorphospaceActiveUnitContractReviewCompatibility {
    param(
        [Parameter(Mandatory)][object]$Unit,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Lifecycle,
        [ValidateSet('Aggregate', 'Inspect', 'Ready', 'Claim')][string]$Phase = 'Aggregate',
        [hashtable]$RepositoryMap = @{}
    )

    $requiredUnitProperties = @('unit_id', 'status', 'work_mode', 'instruction_impact', 'change_categories', 'instruction_surfaces', 'allowed_repositories')
    if (@($requiredUnitProperties | Where-Object { $Unit.PSObject.Properties.Name -cnotcontains $_ }).Count -ne 0 -or
        $State.PSObject.Properties.Name -cnotcontains 'current_unit') {
        return $false
    }
    if ($Phase -in @('Ready', 'Inspect', 'Claim') -and $RepositoryMap.Count -eq 0) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Unit.unit_id) -or
        [string]$Unit.work_mode -cne 'feature' -or
        [string]$Unit.instruction_impact -cne 'update') {
        return $false
    }
    $status = [string]$Unit.status
    switch ($Phase) {
        'Ready' {
            if ($status -cne 'proposed') { return $false }
        }
        'Claim' {
            if ($status -cne 'ready' -or $State.current_unit -or
                $State.PSObject.Properties.Name -cnotcontains 'next_ready_unit' -or
                [string]$State.next_ready_unit -cne [string]$Unit.unit_id) { return $false }
        }
        default {
            if (@('proposed', 'ready', 'active', 'validating') -cnotcontains $status) { return $false }
            if (@('active', 'validating') -ccontains $status -and [string]$State.current_unit -cne [string]$Unit.unit_id) { return $false }
            if ($status -ceq 'ready' -and $State.PSObject.Properties.Name -contains 'next_ready_unit' -and
                [string]$State.next_ready_unit -cne [string]$Unit.unit_id) { return $false }
        }
    }

    $aliases = @{}
    foreach ($alias in @($Lifecycle.change_category_aliases)) {
        $aliasId = [string]$alias.alias
        $canonicalId = [string]$alias.canonical
        if (-not $aliasId -or -not $canonicalId -or $aliases.ContainsKey($aliasId)) { return $false }
        $aliases[$aliasId] = $canonicalId
    }
    $effectiveCategories = @($Unit.change_categories | ForEach-Object {
        $category = [string]$_
        if ($aliases.ContainsKey($category)) { $aliases[$category] } else { $category }
    })
    $triggerCategories = @($Lifecycle.instruction_sync.trigger_categories | ForEach-Object { [string]$_ })
    $routing = @{}
    foreach ($entry in @($Lifecycle.instruction_sync.skill_routing)) {
        $category = [string]$entry.change_category
        if (-not $category -or $routing.ContainsKey($category)) { return $false }
        $routeSkillIds = @($entry.skill_ids | ForEach-Object { [string]$_ })
        if ($routeSkillIds.Count -ne @($routeSkillIds | Sort-Object -Unique -CaseSensitive).Count) { return $false }
        $routing[$category] = $routeSkillIds
    }
    $requiredSkillIds = [Collections.Generic.List[string]]::new()
    foreach ($category in @($effectiveCategories | Where-Object { $triggerCategories -ccontains [string]$_ } | Sort-Object -Unique -CaseSensitive)) {
        if (-not $routing.ContainsKey([string]$category)) { return $false }
        foreach ($skillId in @($routing[[string]$category])) {
            if (-not $skillId) { return $false }
            if (-not $requiredSkillIds.Contains($skillId)) { $requiredSkillIds.Add($skillId) | Out-Null }
        }
    }
    $expectedSkillIds = @('rusty-morphospace', 'system-engineering')
    if ((@($requiredSkillIds.ToArray() | Sort-Object -Unique -CaseSensitive) -join '|') -cne ($expectedSkillIds -join '|')) {
        return $false
    }

    $surfaces = @($Unit.instruction_surfaces)
    $reviewSurfaces = @($surfaces | Where-Object { [string]$_.action -ceq 'review-no-change' })
    if ($reviewSurfaces.Count -ne $expectedSkillIds.Count -or
        @($reviewSurfaces | Where-Object { [string]$_.surface_kind -cne 'skill' }).Count -ne 0 -or
        @($surfaces | Where-Object { [string]$_.action -cne 'review-no-change' -and [string]$_.action -cne 'update' }).Count -ne 0) {
        return $false
    }
    foreach ($surface in @($surfaces | Where-Object { [string]$_.action -cne 'review-no-change' })) {
        if ([string]$surface.action -cne 'update') { return $false }
    }

    # The two review-only skill surfaces are a closed external registration,
    # never a second writable repository authority.
    if (@($Unit.allowed_repositories | Where-Object { [string]$_.repo_id -ceq 'skill-surfaces' }).Count -ne 0) {
        return $false
    }
    $writablePaths = @($Unit.allowed_repositories | ForEach-Object { @($_.allowed_paths | ForEach-Object { [string]$_ }) })
    foreach ($skillId in $expectedSkillIds) {
        $matches = @($reviewSurfaces | Where-Object { [string]$_.skill_id -ceq $skillId })
        if ($matches.Count -ne 1 -or
            [string]$matches[0].path -cne "<skills-root>/$skillId/SKILL.md" -or
            [string]$matches[0].owner -cne 'workflow-maintainer' -or
            @('planned', 'complete') -cnotcontains [string]$matches[0].status -or
            (Test-MorphospaceActiveUnitContractReviewPathInScope -Candidate ([string]$matches[0].path) -AllowedPaths $writablePaths)) {
            return $false
        }
    }

    # Aggregate validation without a repository map is diagnostic only. Ready,
    # Inspect, and Claim supply this binding and must not trust a path-shaped
    # external surface as admission authority.
    if ($RepositoryMap.Count -gt 0) {
        $registeredRoots = @($RepositoryMap.Values | Where-Object {
            [string]$_.repo_id -ceq 'skill-surfaces' -and
            [string]$_.role -ceq 'source' -and
            @($_.aliases).Count -eq 1 -and [string](@($_.aliases)[0]) -ceq 'skills-root'
        })
        if ($registeredRoots.Count -ne 1) { return $false }
        # A surface is outside the unit's sole repository write authority by
        # repository identity, not merely because its placeholder path happens
        # to differ from a declared relative write path.
        if (@($Unit.allowed_repositories | Where-Object {
            [string]$_.repo_id -ceq [string]$registeredRoots[0].repo_id
        }).Count -ne 0) { return $false }
        $skillRoot = Resolve-MorphospaceActiveUnitContractReviewDirectory ([string]$registeredRoots[0].path)
        if (-not $skillRoot) { return $false }
        foreach ($allowedRepository in @($Unit.allowed_repositories)) {
            $allowedRepoId = [string]$allowedRepository.repo_id
            if (-not $RepositoryMap.ContainsKey($allowedRepoId)) { return $false }
            $allowedRoot = Resolve-MorphospaceActiveUnitContractReviewDirectory ([string]$RepositoryMap[$allowedRepoId].path)
            if (-not $allowedRoot -or (Test-MorphospaceActiveUnitContractReviewRootOverlap -Left $skillRoot -Right $allowedRoot)) { return $false }
        }
        foreach ($skillId in $expectedSkillIds) {
            if (-not (Test-MorphospaceActiveUnitContractReviewTrackedSkillBinding -SkillRoot $skillRoot -SkillId $skillId)) { return $false }
        }
    }
    return $true
}

Export-ModuleMember -Function Test-MorphospaceActiveUnitContractReviewCompatibility
