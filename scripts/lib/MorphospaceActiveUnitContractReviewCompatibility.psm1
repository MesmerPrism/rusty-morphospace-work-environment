Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

function Test-MorphospaceActiveUnitContractReviewCompatibility {
    param(
        [Parameter(Mandatory)][object]$Unit,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Lifecycle
    )

    $requiredUnitProperties = @('unit_id', 'status', 'work_mode', 'instruction_impact', 'change_categories', 'instruction_surfaces', 'allowed_repositories')
    if (@($requiredUnitProperties | Where-Object { $Unit.PSObject.Properties.Name -cnotcontains $_ }).Count -ne 0 -or
        $State.PSObject.Properties.Name -cnotcontains 'current_unit') {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$Unit.unit_id) -or
        [string]::IsNullOrWhiteSpace([string]$State.current_unit) -or
        [string]$Unit.work_mode -cne 'feature' -or
        @('active', 'validating') -cnotcontains [string]$Unit.status -or
        [string]$State.current_unit -cne [string]$Unit.unit_id -or
        [string]$Unit.instruction_impact -cne 'update') {
        return $false
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
    return $true
}

Export-ModuleMember -Function Test-MorphospaceActiveUnitContractReviewCompatibility
