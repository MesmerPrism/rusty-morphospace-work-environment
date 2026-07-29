Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospacePlanningProjection.psm1') -Force

function Get-MorphospacePublishedPlanningAuthorityAdoptionSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionId {
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Context)
    if ($Value -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') {
        throw "$Context is not a canonical workflow ID."
    }
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionSha {
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Context)
    if ($Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Context is not a full lowercase Git revision."
    }
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionHash {
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Context, [switch]$AllowNull)
    if ($AllowNull -and $null -eq $Value) { return }
    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Context is not a lowercase SHA-256 value."
    }
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionPath {
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Context, [switch]$RequireJson)
    if ([string]::IsNullOrWhiteSpace($Value) -or
        [IO.Path]::IsPathRooted($Value) -or
        $Value -match '\\' -or
        $Value -match '(^|/)\.\.(/|$)' -or
        $Value -cnotmatch '^[a-z0-9][a-z0-9._/-]*$' -or
        ($RequireJson -and $Value -cnotmatch '\.json$')) {
        throw "$Context is not a canonical portable relative path."
    }
}

function Resolve-MorphospacePublishedPlanningAuthorityAdoptionFile {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$Context
    )
    Test-MorphospacePublishedPlanningAuthorityAdoptionPath -Value $Reference -Context $Context -RequireJson
    $root = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $Reference))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context resolves outside the projected workspace."
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "$Context does not exist: $Reference"
    }
    $item = Get-Item -LiteralPath $candidate -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$Context resolves through a reparse-point file."
    }
    return $candidate
}

function Read-MorphospacePublishedPlanningAuthorityAdoptionJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context)
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        return $utf8.GetString($bytes) | ConvertFrom-Json -DateKind String
    } catch {
        throw "$Context is not valid JSON: $($_.Exception.Message)"
    }
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionTimestamp {
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Context)
    if ($Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        throw "$Context is not a canonical invariant ISO-8601 timestamp."
    }
    [string[]]$formats = @(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",
        "yyyy-MM-dd'T'HH:mm:sszzz",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFzzz",
        'o'
    )
    $parsed = [DateTimeOffset]::MinValue
    $parsedOk = [DateTimeOffset]::TryParseExact(
        $Value,
        $formats,
        [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal),
        [ref]$parsed
    )
    if (-not $parsedOk) {
        throw "$Context is not a parseable invariant ISO-8601 timestamp."
    }
}

function Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$Required,
        [string[]]$Optional = @(),
        [Parameter(Mandatory)][string]$Context
    )
    $names = @($Object.PSObject.Properties.Name)
    foreach ($name in $Required) {
        if ($names -cnotcontains $name) { throw "$Context is missing '$name'." }
    }
    $allowed = @($Required + $Optional)
    $unexpected = @($names | Where-Object { $allowed -cnotcontains $_ })
    if ($unexpected.Count -ne 0) {
        throw "$Context contains unexpected field '$($unexpected[0])'."
    }
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionArray {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory)][string]$Context
    )
    if ($Actual.Count -ne $Expected.Count) { throw "$Context does not match exactly." }
    for ($index = 0; $index -lt $Actual.Count; $index++) {
        if ([string]$Actual[$index] -cne [string]$Expected[$index]) {
            throw "$Context does not match exactly."
        }
    }
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionDeepEqual {
    param([AllowNull()][object]$Left, [AllowNull()][object]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    if ($Left -is [pscustomobject] -or $Right -is [pscustomobject]) {
        if ($Left -isnot [pscustomobject] -or $Right -isnot [pscustomobject]) { return $false }
        $leftNames = @($Left.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        $rightNames = @($Right.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        if ($leftNames.Count -ne $rightNames.Count) { return $false }
        for ($index = 0; $index -lt $leftNames.Count; $index++) {
            if ($leftNames[$index] -cne $rightNames[$index]) { return $false }
            $name = $leftNames[$index]
            if (-not (Test-MorphospacePublishedPlanningAuthorityAdoptionDeepEqual -Left $Left.$name -Right $Right.$name)) {
                return $false
            }
        }
        return $true
    }
    $leftArray = $Left -is [System.Collections.IEnumerable] -and $Left -isnot [string]
    $rightArray = $Right -is [System.Collections.IEnumerable] -and $Right -isnot [string]
    if ($leftArray -or $rightArray) {
        if (-not $leftArray -or -not $rightArray) { return $false }
        $leftValues = @($Left)
        $rightValues = @($Right)
        if ($leftValues.Count -ne $rightValues.Count) { return $false }
        for ($index = 0; $index -lt $leftValues.Count; $index++) {
            if (-not (Test-MorphospacePublishedPlanningAuthorityAdoptionDeepEqual -Left $leftValues[$index] -Right $rightValues[$index])) {
                return $false
            }
        }
        return $true
    }
    if ($Left -is [string] -or $Right -is [string]) {
        return ([string]$Left -ceq [string]$Right)
    }
    return ($Left -eq $Right)
}

function Get-MorphospacePublishedPlanningAuthorityAdoptionRepositoryState {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$Context
    )
    $rows = @($State.repository_heads | Where-Object { [string]$_.repo_id -ceq $RepositoryId })
    if ($rows.Count -ne 1) {
        throw "$Context must contain exactly one repository_heads row for '$RepositoryId'."
    }
    return $rows[0]
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionRepositoryBinding {
    param(
        [Parameter(Mandatory)][object]$Binding,
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][string]$Context
    )
    Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $Binding `
        -Required @('repo_id', 'head', 'branch', 'dirty_fingerprint') -Context $Context
    Test-MorphospacePublishedPlanningAuthorityAdoptionId ([string]$Binding.repo_id) "$Context.repo_id"
    Test-MorphospacePublishedPlanningAuthorityAdoptionSha ([string]$Binding.head) "$Context.head"
    if ($null -ne $Binding.dirty_fingerprint) {
        Test-MorphospacePublishedPlanningAuthorityAdoptionHash ([string]$Binding.dirty_fingerprint) "$Context.dirty_fingerprint"
    }
    foreach ($name in @('repo_id', 'head')) {
        if ([string]$Binding.$name -cne [string]$Actual.$name) { throw "$Context.$name does not match workspace state." }
    }
    if (($null -eq $Binding.branch) -ne ($null -eq $Actual.branch) -or
        ($null -ne $Binding.branch -and [string]$Binding.branch -cne [string]$Actual.branch)) {
        throw "$Context.branch does not match workspace state."
    }
    if (($null -eq $Binding.dirty_fingerprint) -ne ($null -eq $Actual.dirty_fingerprint) -or
        ($null -ne $Binding.dirty_fingerprint -and [string]$Binding.dirty_fingerprint -cne [string]$Actual.dirty_fingerprint)) {
        throw "$Context.dirty_fingerprint does not match workspace state."
    }
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionStateBinding {
    param(
        [Parameter(Mandatory)][object]$Binding,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$SourceRepositoryId,
        [AllowNull()][string]$ExpectedCurrentUnit,
        [Parameter(Mandatory)][string]$Context
    )
    Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $Binding `
        -Required @('path', 'sha256', 'current_unit', 'next_ready_unit', 'pending_push_bundle', 'dirty_repository_ids', 'source_repository') `
        -Context $Context
    if ($null -ne $Binding.next_ready_unit -or $null -ne $Binding.pending_push_bundle) {
        throw "$Context must bind null next_ready_unit and pending_push_bundle."
    }
    if (($null -eq $ExpectedCurrentUnit -and $null -ne $Binding.current_unit) -or
        ($null -ne $ExpectedCurrentUnit -and [string]$Binding.current_unit -cne $ExpectedCurrentUnit) -or
        ($null -eq $ExpectedCurrentUnit -and $null -ne $State.current_unit) -or
        ($null -ne $ExpectedCurrentUnit -and [string]$State.current_unit -cne $ExpectedCurrentUnit) -or
        $null -ne $State.next_ready_unit -or $null -ne $State.pending_push_bundle) {
        throw "$Context does not match the required current-unit and queue state."
    }
    $bindingDirty = @($Binding.dirty_repository_ids | ForEach-Object { [string]$_ })
    $stateDirty = @($State.dirty_repositories | ForEach-Object { [string]$_ })
    Test-MorphospacePublishedPlanningAuthorityAdoptionArray $bindingDirty $stateDirty "$Context.dirty_repository_ids"
    $sorted = @($bindingDirty | Sort-Object -CaseSensitive -Unique)
    Test-MorphospacePublishedPlanningAuthorityAdoptionArray $bindingDirty $sorted "$Context.dirty_repository_ids canonical order"
    foreach ($repositoryId in $bindingDirty) {
        Test-MorphospacePublishedPlanningAuthorityAdoptionId $repositoryId "$Context.dirty_repository_ids"
    }
    $stateRepository = Get-MorphospacePublishedPlanningAuthorityAdoptionRepositoryState -State $State -RepositoryId $SourceRepositoryId -Context $Context
    Test-MorphospacePublishedPlanningAuthorityAdoptionRepositoryBinding -Binding $Binding.source_repository -Actual $stateRepository -Context "$Context.source_repository"
}

function Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Context
    )
    $output = @(& git -C $RepositoryPath @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$output[0])) {
        throw "Git observation failed for $Context."
    }
    return ([string]$output[0]).Trim()
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )
    $document = Read-MorphospacePublishedPlanningAuthorityAdoptionJson -Path $Path -Context 'Published planning authority adoption'
    Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $document `
        -Required @(
            'schema', 'adoption_id', 'project_id', 'recorded_at', 'status',
            'planning_workspace_projection', 'workspace_state_before', 'workspace_state_after',
            'source_publication', 'planning_repository', 'validation', 'observers',
            'state_delta', 'nonclaims', 'failure'
        ) -Optional @('$schema') -Context 'Published planning authority adoption'
    $documentSchema = [string]$document.schema
    $isActiveAdoption = $documentSchema -ceq 'rusty.morphospace.workflow.published_planning_authority_adoption.v2'
    $expectedStatus = if ($isActiveAdoption) { 'published-active-planning-authority-adopted' } else { 'published-planning-authority-adopted' }
    if ($documentSchema -cnotin @(
            'rusty.morphospace.workflow.published_planning_authority_adoption.v1',
            'rusty.morphospace.workflow.published_planning_authority_adoption.v2'
        ) -or [string]$document.status -cne $expectedStatus -or
        $null -ne $document.failure) {
        throw 'Published planning authority adoption schema, status, or failure state is invalid.'
    }
    Test-MorphospacePublishedPlanningAuthorityAdoptionId ([string]$document.adoption_id) 'adoption_id'
    Test-MorphospacePublishedPlanningAuthorityAdoptionId ([string]$document.project_id) 'project_id'
    Test-MorphospacePublishedPlanningAuthorityAdoptionTimestamp ([string]$document.recorded_at) 'recorded_at'

    $projectionReference = $document.planning_workspace_projection
    Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $projectionReference `
        -Required @('path', 'projection_id', 'sha256') -Context 'planning_workspace_projection'
    Test-MorphospacePublishedPlanningAuthorityAdoptionId ([string]$projectionReference.projection_id) 'planning_workspace_projection.projection_id'
    Test-MorphospacePublishedPlanningAuthorityAdoptionHash ([string]$projectionReference.sha256) 'planning_workspace_projection.sha256'
    $projectionPath = Resolve-MorphospacePublishedPlanningAuthorityAdoptionFile -WorkspaceRoot $WorkspaceRoot `
        -Reference ([string]$projectionReference.path) -Context 'planning_workspace_projection.path'
    if ((Get-MorphospacePublishedPlanningAuthorityAdoptionSha256 $projectionPath) -cne [string]$projectionReference.sha256) {
        throw 'Published planning authority adoption projection hash mismatch.'
    }
    $projection = (Test-MorphospacePlanningWorkspaceProjectionDocument -Path $projectionPath).document
    $expectedProjectionSchema = if ($isActiveAdoption) {
        'rusty.morphospace.workflow.planning_workspace_projection.v3'
    } else {
        'rusty.morphospace.workflow.planning_workspace_projection.v2'
    }
    if ([string]$projection.schema -cne $expectedProjectionSchema -or
        [string]$projection.projection_id -cne [string]$projectionReference.projection_id -or
        [string]$projection.project_id -cne [string]$document.project_id) {
        throw 'Published planning authority adoption does not bind the exact compatible projection identity.'
    }
    if ([string]$projection.planning.projection_record_path -cne [string]$projectionReference.path) {
        throw 'Published planning authority adoption projection path differs from its self-binding.'
    }

    $source = $document.source_publication
    Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $source `
        -Required @(
            'repo_id', 'branch', 'remote', 'remote_ref', 'upstream', 'pre_merge_revision',
            'published_revision', 'readback_revision', 'published_tree', 'worktree_clean',
            'synchronized', 'fast_forward_verified', 'remote_match', 'force_push_used',
            'history_rewrite_used'
        ) -Context 'source_publication'
    Test-MorphospacePublishedPlanningAuthorityAdoptionId ([string]$source.repo_id) 'source_publication.repo_id'
    foreach ($name in @('pre_merge_revision', 'published_revision', 'readback_revision', 'published_tree')) {
        Test-MorphospacePublishedPlanningAuthorityAdoptionSha ([string]$source.$name) "source_publication.$name"
    }
    if ([string]$source.pre_merge_revision -ceq [string]$source.published_revision -or
        [string]$source.published_revision -cne [string]$source.readback_revision -or
        $source.worktree_clean -ne $true -or $source.synchronized -ne $true -or
        $source.fast_forward_verified -ne $true -or $source.remote_match -ne $true -or
        $source.force_push_used -ne $false -or $source.history_rewrite_used -ne $false) {
        throw 'Published planning authority adoption lacks exact clean no-force source publication proof.'
    }
    if ([string]$source.upstream -cne "$([string]$source.remote)/$([string]$source.branch)" -or
        [string]$source.remote_ref -cne "refs/heads/$([string]$source.branch)") {
        throw 'Published planning authority adoption source branch, remote, upstream, and remote ref are inconsistent.'
    }
    if ([string]$projection.source.repo_id -cne [string]$source.repo_id -or
        [string]$projection.source.branch -cne [string]$source.branch -or
        [string]$projection.source.remote -cne [string]$source.remote -or
        [string]$projection.source.remote_ref -cne [string]$source.remote_ref -or
        [string]$projection.source.upstream -cne [string]$source.upstream -or
        [string]$projection.source.old_revision -cne [string]$source.pre_merge_revision -or
        [string]$projection.source.published_revision -cne [string]$source.published_revision -or
        [string]$projection.source.observed_remote_revision -cne [string]$source.readback_revision) {
        throw 'Published planning authority adoption source proof differs from the bound projection.'
    }
    if ([string]$projection.projected_state.source_repository.repo_id -cne [string]$source.repo_id -or
        [string]$projection.projected_state.source_repository.head -ceq [string]$source.published_revision) {
        throw 'Published planning authority adoption requires the exact stale projected source row, distinct from the publication head.'
    }

    $planning = $document.planning_repository
    Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $planning `
        -Required @(
            'repo_id', 'branch', 'head_revision', 'head_tree', 'workspace_path',
            'distinct_from_source', 'remote_configured', 'unrelated_worktree_clean'
        ) -Context 'planning_repository'
    Test-MorphospacePublishedPlanningAuthorityAdoptionId ([string]$planning.repo_id) 'planning_repository.repo_id'
    foreach ($name in @('head_revision', 'head_tree')) {
        Test-MorphospacePublishedPlanningAuthorityAdoptionSha ([string]$planning.$name) "planning_repository.$name"
    }
    Test-MorphospacePublishedPlanningAuthorityAdoptionPath ([string]$planning.workspace_path) 'planning_repository.workspace_path'
    if ([string]$planning.repo_id -ceq [string]$source.repo_id -or
        [string]$planning.repo_id -cne [string]$projection.planning.repo_id -or
        [string]$planning.workspace_path -cne [string]$projection.planning.workspace_path -or
        $null -eq $projection.planning.base_revision -or
        [string]$planning.head_revision -cne [string]$projection.planning.base_revision -or
        $planning.distinct_from_source -ne $true -or $planning.remote_configured -ne $false -or
        $planning.unrelated_worktree_clean -ne $true) {
        throw 'Published planning authority adoption planning-repository boundary is invalid.'
    }

    $beforeReference = $document.workspace_state_before
    $afterReference = $document.workspace_state_after
    foreach ($pair in @(
        [pscustomobject]@{ binding = $beforeReference; context = 'workspace_state_before' },
        [pscustomobject]@{ binding = $afterReference; context = 'workspace_state_after' }
    )) {
        Test-MorphospacePublishedPlanningAuthorityAdoptionHash ([string]$pair.binding.sha256) "$($pair.context).sha256"
    }
    if ([string]$beforeReference.path -ceq 'workspace.state.json' -or
        [string]$afterReference.path -ceq 'workspace.state.json' -or
        [string]$beforeReference.path -ceq [string]$afterReference.path) {
        throw 'Published planning authority adoption must preserve distinct immutable before-state and expected-after-state files.'
    }
    $beforePath = Resolve-MorphospacePublishedPlanningAuthorityAdoptionFile -WorkspaceRoot $WorkspaceRoot `
        -Reference ([string]$beforeReference.path) -Context 'workspace_state_before.path'
    $afterPath = Resolve-MorphospacePublishedPlanningAuthorityAdoptionFile -WorkspaceRoot $WorkspaceRoot `
        -Reference ([string]$afterReference.path) -Context 'workspace_state_after.path'
    if ((Get-MorphospacePublishedPlanningAuthorityAdoptionSha256 $beforePath) -cne [string]$beforeReference.sha256 -or
        (Get-MorphospacePublishedPlanningAuthorityAdoptionSha256 $afterPath) -cne [string]$afterReference.sha256) {
        throw 'Published planning authority adoption workspace-state hash mismatch.'
    }
    $beforeState = Read-MorphospacePublishedPlanningAuthorityAdoptionJson -Path $beforePath -Context 'Before workspace state'
    $afterState = Read-MorphospacePublishedPlanningAuthorityAdoptionJson -Path $afterPath -Context 'After workspace state'
    if ([string]$beforeState.schema -cne 'rusty.morphospace.workflow.workspace_state.v2' -or
        [string]$afterState.schema -cne 'rusty.morphospace.workflow.workspace_state.v2' -or
        [string]$beforeState.project_id -cne [string]$document.project_id -or
        [string]$afterState.project_id -cne [string]$document.project_id) {
        throw 'Published planning authority adoption requires matching v2 workspace states.'
    }
    $expectedCurrentUnit = if ($isActiveAdoption) { [string]$projection.unit_id } else { $null }
    Test-MorphospacePublishedPlanningAuthorityAdoptionStateBinding -Binding $beforeReference -State $beforeState `
        -SourceRepositoryId ([string]$source.repo_id) -ExpectedCurrentUnit $expectedCurrentUnit -Context 'workspace_state_before'
    Test-MorphospacePublishedPlanningAuthorityAdoptionStateBinding -Binding $afterReference -State $afterState `
        -SourceRepositoryId ([string]$source.repo_id) -ExpectedCurrentUnit $expectedCurrentUnit -Context 'workspace_state_after'
    $projectionDirty = @($projection.projected_state.dirty_repository_ids | ForEach-Object { [string]$_ })
    $beforeDirty = @($beforeReference.dirty_repository_ids | ForEach-Object { [string]$_ })
    Test-MorphospacePublishedPlanningAuthorityAdoptionArray $beforeDirty $projectionDirty 'Projected and before-state dirty repository IDs'
    if ($beforeDirty -cnotcontains [string]$source.repo_id) {
        throw 'Published planning authority adoption source repository is not dirty in the projected before state.'
    }
    if (-not (Test-MorphospacePublishedPlanningAuthorityAdoptionDeepEqual `
        $beforeReference.source_repository $projection.projected_state.source_repository)) {
        throw 'Published planning authority adoption before-state repository binding differs from the projected stale source repository.'
    }
    $projectionStateRow = @($projection.inventory | Where-Object { [string]$_.path -ceq 'workspace.state.json' })
    if ($projectionStateRow.Count -ne 1 -or [string]$projectionStateRow[0].sha256 -cne [string]$beforeReference.sha256) {
        throw 'Published planning authority adoption before-state bytes differ from the projected published workspace state.'
    }
    if ($isActiveAdoption) {
        if (-not (Test-MorphospacePublishedPlanningAuthorityAdoptionDeepEqual `
                $beforeReference.source_repository $afterReference.source_repository)) {
            throw 'Published active planning authority adoption must preserve the projected source repository row.'
        }
    } elseif ([string]$beforeReference.source_repository.head -ceq [string]$source.published_revision -or
        [string]$afterReference.source_repository.head -cne [string]$source.published_revision -or
        [string]$afterReference.source_repository.branch -cne [string]$source.branch -or
        $null -eq $beforeReference.source_repository.dirty_fingerprint -or
        $null -ne $afterReference.source_repository.dirty_fingerprint) {
        throw 'Published inactive planning authority adoption does not update the named source head, branch, and dirty fingerprint exactly.'
    }

    $delta = $document.state_delta
    Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $delta `
        -Required @(
            'cleared_dirty_repository_id', 'dirty_repository_ids_before',
            'dirty_repository_ids_after', 'repository_before', 'repository_after',
            'last_event_id_before', 'last_event_id_after', 'preserved_fields'
        ) -Context 'state_delta'
    $preservedFields = if ($isActiveAdoption) {
        @(
            'blockers', 'capability_registry', 'current_unit', 'dirty_repositories',
            'last_accepted_receipt', 'module_registry', 'next_ready_unit',
            'pending_push_bundle', 'plan_revision', 'project_id',
            'repository_checkpoints', 'repository_heads', 'validation_checkpoint'
        )
    } else {
        @(
            'blockers', 'capability_registry', 'current_unit', 'last_accepted_receipt',
            'module_registry', 'next_ready_unit', 'pending_push_bundle', 'plan_revision',
            'project_id', 'repository_checkpoints',
            'unrelated_repository_heads', 'validation_checkpoint'
        )
    }
    Test-MorphospacePublishedPlanningAuthorityAdoptionArray @($delta.preserved_fields) $preservedFields 'state_delta.preserved_fields'
    Test-MorphospacePublishedPlanningAuthorityAdoptionArray @($delta.dirty_repository_ids_before) $beforeDirty 'state_delta.dirty_repository_ids_before'
    $afterDirty = @($afterReference.dirty_repository_ids | ForEach-Object { [string]$_ })
    Test-MorphospacePublishedPlanningAuthorityAdoptionArray @($delta.dirty_repository_ids_after) $afterDirty 'state_delta.dirty_repository_ids_after'
    if (($isActiveAdoption -and $null -ne $delta.cleared_dirty_repository_id) -or
        (-not $isActiveAdoption -and [string]$delta.cleared_dirty_repository_id -cne [string]$source.repo_id)) {
        throw 'Published planning authority adoption dirty-repository delta is invalid for its schema.'
    }
    if (($null -eq $delta.last_event_id_before) -ne ($null -eq $beforeState.last_event_id) -or
        ($null -ne $delta.last_event_id_before -and [string]$delta.last_event_id_before -cne [string]$beforeState.last_event_id) -or
        [string]$delta.last_event_id_after -cne [string]$afterState.last_event_id -or
        [string]$delta.last_event_id_after -ceq [string]$delta.last_event_id_before) {
        throw 'Published planning authority adoption does not bind one exact new adoption event ID.'
    }
    Test-MorphospacePublishedPlanningAuthorityAdoptionId ([string]$delta.last_event_id_after) 'state_delta.last_event_id_after'
    $expectedAfterDirty = if ($isActiveAdoption) {
        @($beforeDirty)
    } else {
        @($beforeDirty | Where-Object { $_ -cne [string]$source.repo_id })
    }
    Test-MorphospacePublishedPlanningAuthorityAdoptionArray $afterDirty $expectedAfterDirty 'workspace_state_after.dirty_repository_ids'
    $beforeActualRepository = Get-MorphospacePublishedPlanningAuthorityAdoptionRepositoryState $beforeState ([string]$source.repo_id) 'Before workspace state'
    $afterActualRepository = Get-MorphospacePublishedPlanningAuthorityAdoptionRepositoryState $afterState ([string]$source.repo_id) 'After workspace state'
    Test-MorphospacePublishedPlanningAuthorityAdoptionRepositoryBinding $delta.repository_before $beforeActualRepository 'state_delta.repository_before'
    Test-MorphospacePublishedPlanningAuthorityAdoptionRepositoryBinding $delta.repository_after $afterActualRepository 'state_delta.repository_after'
    if (-not (Test-MorphospacePublishedPlanningAuthorityAdoptionDeepEqual $delta.repository_before $beforeReference.source_repository) -or
        -not (Test-MorphospacePublishedPlanningAuthorityAdoptionDeepEqual $delta.repository_after $afterReference.source_repository)) {
        throw 'Published planning authority adoption state-delta repository bindings are inconsistent.'
    }

    $expectedAfterState = $beforeState | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $expectedAfterState.dirty_repositories = @($expectedAfterDirty)
    $expectedRepository = Get-MorphospacePublishedPlanningAuthorityAdoptionRepositoryState $expectedAfterState ([string]$source.repo_id) 'Expected after workspace state'
    if (-not $isActiveAdoption) {
        $expectedRepository.head = [string]$delta.repository_after.head
        $expectedRepository.branch = $delta.repository_after.branch
        $expectedRepository.dirty_fingerprint = $delta.repository_after.dirty_fingerprint
    }
    $expectedAfterState.last_event_id = [string]$delta.last_event_id_after
    $expectedAfterJson = $expectedAfterState | ConvertTo-Json -Depth 100 -Compress
    $actualAfterJson = $afterState | ConvertTo-Json -Depth 100 -Compress
    if ($expectedAfterJson -cne $actualAfterJson) {
        $differentFields = @($expectedAfterState.PSObject.Properties.Name | Where-Object {
            -not (Test-MorphospacePublishedPlanningAuthorityAdoptionDeepEqual $expectedAfterState.$_ $afterState.$_)
        })
        throw "Published planning authority adoption changes workspace state beyond its schema's exact event and repository delta: $($differentFields -join ', ')."
    }

    $evidencePaths = New-Object System.Collections.Generic.List[string]
    $gateIds = @{}
    foreach ($gate in @($document.validation)) {
        Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $gate `
            -Required @('gate_id', 'status', 'evidence') -Context 'validation entry'
        $gateId = [string]$gate.gate_id
        Test-MorphospacePublishedPlanningAuthorityAdoptionId $gateId 'validation.gate_id'
        if ($gateIds.ContainsKey($gateId) -or [string]$gate.status -cne 'pass') {
            throw "Published planning authority adoption validation '$gateId' is duplicate or not passing."
        }
        $gateIds[$gateId] = $true
        Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $gate.evidence `
            -Required @('path', 'sha256') -Context "validation '$gateId' evidence"
        Test-MorphospacePublishedPlanningAuthorityAdoptionHash ([string]$gate.evidence.sha256) "validation '$gateId' evidence.sha256"
        $evidencePath = Resolve-MorphospacePublishedPlanningAuthorityAdoptionFile $WorkspaceRoot ([string]$gate.evidence.path) "validation '$gateId' evidence.path"
        if ((Get-MorphospacePublishedPlanningAuthorityAdoptionSha256 $evidencePath) -cne [string]$gate.evidence.sha256) {
            throw "Published planning authority adoption validation evidence hash mismatch for '$gateId'."
        }
        $evidencePaths.Add([string]$gate.evidence.path) | Out-Null
    }
    if ($gateIds.Count -lt 1) { throw 'Published planning authority adoption requires at least one passing validation.' }

    $observerIds = @{}
    foreach ($observer in @($document.observers)) {
        Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $observer `
            -Required @('observer_id', 'recorded_at', 'evidence') -Context 'observer entry'
        $observerId = [string]$observer.observer_id
        Test-MorphospacePublishedPlanningAuthorityAdoptionId $observerId 'observers.observer_id'
        Test-MorphospacePublishedPlanningAuthorityAdoptionTimestamp ([string]$observer.recorded_at) "observer '$observerId' recorded_at"
        if ($observerIds.ContainsKey($observerId)) {
            throw "Published planning authority adoption repeats observer '$observerId'."
        }
        $observerIds[$observerId] = $true
        Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $observer.evidence `
            -Required @('path', 'sha256') -Context "observer '$observerId' evidence"
        Test-MorphospacePublishedPlanningAuthorityAdoptionHash ([string]$observer.evidence.sha256) "observer '$observerId' evidence.sha256"
        $observerPath = Resolve-MorphospacePublishedPlanningAuthorityAdoptionFile $WorkspaceRoot ([string]$observer.evidence.path) "observer '$observerId' evidence.path"
        if ((Get-MorphospacePublishedPlanningAuthorityAdoptionSha256 $observerPath) -cne [string]$observer.evidence.sha256) {
            throw "Published planning authority adoption observer evidence hash mismatch for '$observerId'."
        }
        $evidencePaths.Add([string]$observer.evidence.path) | Out-Null
    }
    if ($observerIds.Count -lt 1) { throw 'Published planning authority adoption requires at least one external observer.' }

    $uniqueEvidencePaths = @($evidencePaths | Sort-Object -CaseSensitive -Unique)
    if ($uniqueEvidencePaths.Count -ne $evidencePaths.Count) {
        throw 'Published planning authority adoption evidence paths must be distinct.'
    }
    $projectedPaths = @($projection.inventory | ForEach-Object { [string]$_.path })
    foreach ($additivePath in @(
        [string]$beforeReference.path
        [string]$afterReference.path
        [string]$projectionReference.path
        $uniqueEvidencePaths
    )) {
        if ($projectedPaths -ccontains $additivePath -and $additivePath -cne 'workspace.state.json') {
            throw "Published planning authority adoption evidence path collides with published workspace bytes: $additivePath"
        }
    }

    $nonclaims = $document.nonclaims
    Assert-MorphospacePublishedPlanningAuthorityAdoptionProperties -Object $nonclaims `
        -Required @(
            'external_planning_authority_existed_at_publication',
            'prepared_plan_or_executed_push_reconstructed', 'source_acceptance_created',
            'git_or_remote_mutation_performed', 'force_push_or_history_rewrite_used',
            'unrelated_dirty_repositories_cleared'
        ) -Context 'nonclaims'
    foreach ($property in $nonclaims.PSObject.Properties) {
        if ($property.Value -ne $false) {
            throw "Published planning authority adoption nonclaim '$($property.Name)' must be false."
        }
    }

    return [pscustomobject][ordered]@{
        document = $document
        adoption_sha256 = Get-MorphospacePublishedPlanningAuthorityAdoptionSha256 $Path
        projection = $projection
        projection_path = $projectionPath
        workspace_state_before = $beforeState
        workspace_state_after = $afterState
        workspace_state_before_path = $beforePath
        workspace_state_after_path = $afterPath
        additive_evidence_paths = @(
            [string]$beforeReference.path
            [string]$afterReference.path
            $uniqueEvidencePaths
        )
    }
}

function Test-MorphospacePublishedPlanningAuthorityAdoptionLive {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$SourceRepository,
        [Parameter(Mandatory)][string]$PlanningRepository
    )
    $validated = Test-MorphospacePublishedPlanningAuthorityAdoptionDocument -Path $Path -WorkspaceRoot $WorkspaceRoot
    $document = $validated.document
    $projection = $validated.projection
    $source = $document.source_publication
    $planning = $document.planning_repository

    $sourceRoot = [IO.Path]::GetFullPath($SourceRepository).TrimEnd('\', '/')
    $planningRoot = [IO.Path]::GetFullPath($PlanningRepository).TrimEnd('\', '/')
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    if ($sourceRoot -ceq $planningRoot -or
        (Get-GitCommonDirectory $sourceRoot) -ceq (Get-GitCommonDirectory $planningRoot)) {
        throw 'Published planning authority adoption requires distinct source and planning Git authority.'
    }
    $planningPrefix = $planningRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $workspace.StartsWith($planningPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Published planning authority adoption workspace is outside the planning repository.'
    }
    $relativeWorkspace = $workspace.Substring($planningPrefix.Length).Replace('\', '/')
    if ($relativeWorkspace -cne [string]$planning.workspace_path) {
        throw 'Published planning authority adoption workspace differs from the planning-repository binding.'
    }
    $adoptionFull = [IO.Path]::GetFullPath($Path)
    $workspacePrefix = $workspace + [IO.Path]::DirectorySeparatorChar
    if (-not $adoptionFull.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Published planning authority adoption receipt is outside the projected workspace.'
    }
    $adoptionRelative = $adoptionFull.Substring($workspacePrefix.Length).Replace('\', '/')

    $allowedAdditive = @(
        [string]$document.workspace_state_before.path
        [string]$document.workspace_state_after.path
        $adoptionRelative
        @($document.validation | ForEach-Object { [string]$_.evidence.path })
        @($document.observers | ForEach-Object { [string]$_.evidence.path })
    ) | Sort-Object -CaseSensitive -Unique

    $embeddedTree = Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue $sourceRoot `
        @('rev-parse', "$([string]$source.published_revision):$([string]$projection.source.embedded_workspace_path)") `
        'published embedded workspace tree'
    if ($embeddedTree -cne [string]$projection.source.embedded_workspace_tree) {
        throw 'Published planning authority adoption embedded workspace tree differs from the projection.'
    }
    $sourceInventory = @(Get-GitWorkspaceInventory $sourceRoot ([string]$source.published_revision) ([string]$projection.source.embedded_workspace_path))
    if ($sourceInventory.Count -ne @($projection.inventory).Count) {
        throw 'Published planning authority adoption source inventory count differs from the projection.'
    }
    for ($index = 0; $index -lt $sourceInventory.Count; $index++) {
        $actual = $sourceInventory[$index]
        $expected = $projection.inventory[$index]
        if ([string]$actual.path -cne [string]$expected.path -or
            [string]$actual.git_mode -cne [string]$expected.git_mode -or
            [int64]$actual.size -ne [int64]$expected.size -or
            [string]$actual.sha256 -cne [string]$expected.sha256) {
            throw "Published planning authority adoption source inventory differs at '$([string]$actual.path)'."
        }
        if ([string]$actual.path -ceq 'workspace.state.json') {
            if ([string]$actual.sha256 -cne [string]$document.workspace_state_before.sha256) {
                throw 'Published planning authority adoption before-state bytes differ from the published workspace state.'
            }
            $liveStatePath = Join-Path $workspace 'workspace.state.json'
            if (-not (Test-Path -LiteralPath $liveStatePath -PathType Leaf) -or
                (Get-MorphospacePublishedPlanningAuthorityAdoptionSha256 $liveStatePath) -cne [string]$document.workspace_state_before.sha256) {
                throw 'Published planning authority adoption live workspace state is not the bound before state.'
            }
            continue
        }
        $destination = Join-Path $workspace ([string]$actual.path)
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
            (Get-MorphospacePublishedPlanningAuthorityAdoptionSha256 $destination) -cne [string]$actual.sha256) {
            throw "Published planning authority adoption projected byte differs from the published source: $([string]$actual.path)"
        }
    }
    $destinationFiles = @(Get-ChildItem -LiteralPath $workspace -File -Recurse -Force | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Published planning authority adoption workspace contains a reparse-point file: $($_.FullName)"
        }
        $_.FullName.Substring($workspacePrefix.Length).Replace('\', '/')
    } | Sort-Object -CaseSensitive)
    foreach ($directory in @(Get-ChildItem -LiteralPath $workspace -Directory -Recurse -Force)) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Published planning authority adoption workspace contains a reparse-point directory: $($directory.FullName)"
        }
    }
    $expectedDestinationFiles = @(
        @($sourceInventory | ForEach-Object { [string]$_.path })
        [string]$document.planning_workspace_projection.path
        $allowedAdditive
    ) | Sort-Object -CaseSensitive -Unique
    if (($destinationFiles -join '|') -cne ($expectedDestinationFiles -join '|')) {
        throw 'Published planning authority adoption workspace contains missing or additional files outside the exact adoption evidence set.'
    }

    $sourceHead = Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue $sourceRoot @('rev-parse', 'HEAD') 'source HEAD'
    $sourceTree = Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue $sourceRoot @('rev-parse', 'HEAD^{tree}') 'source tree'
    $sourceBranch = Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue $sourceRoot @('branch', '--show-current') 'source branch'
    $sourceUpstream = Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue $sourceRoot @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') 'source upstream'
    $sourceStatus = @(& git -C $sourceRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $sourceStatus.Count -ne 0) {
        throw 'Published planning authority adoption source worktree is not clean.'
    }
    $sourceCounts = (Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue $sourceRoot @('rev-list', '--left-right', '--count', "$sourceUpstream...HEAD") 'source synchronization') -split '\s+'
    if ($sourceCounts.Count -ne 2 -or [int]$sourceCounts[0] -ne 0 -or [int]$sourceCounts[1] -ne 0 -or
        $sourceHead -cne [string]$source.published_revision -or $sourceTree -cne [string]$source.published_tree -or
        $sourceBranch -cne [string]$source.branch -or $sourceUpstream -cne [string]$source.upstream) {
        throw 'Published planning authority adoption source repository is not the exact clean synchronized publication.'
    }
    $freshSource = Get-FreshRemoteRevision $sourceRoot ([string]$source.remote) ([string]$source.remote_ref)
    if ($freshSource -cne [string]$source.readback_revision) {
        throw 'Published planning authority adoption fresh source readback changed.'
    }
    & git -C $sourceRoot merge-base --is-ancestor ([string]$source.pre_merge_revision) ([string]$source.published_revision) 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Published planning authority adoption source publication is not a fast-forward from the bound pre-merge revision.'
    }

    $planningHead = Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue $planningRoot @('rev-parse', 'HEAD') 'planning HEAD'
    $planningTree = Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue $planningRoot @('rev-parse', 'HEAD^{tree}') 'planning tree'
    $planningBranch = Get-MorphospacePublishedPlanningAuthorityAdoptionGitValue $planningRoot @('branch', '--show-current') 'planning branch'
    $planningRemotes = @(& git -C $planningRoot remote)
    if ($LASTEXITCODE -ne 0 -or $planningRemotes.Count -ne 0 -or
        $planningHead -cne [string]$planning.head_revision -or
        $planningTree -cne [string]$planning.head_tree -or
        $planningBranch -cne [string]$planning.branch) {
        throw 'Published planning authority adoption planning repository is not the exact attached local-only authority.'
    }
    $planningStatus = @(& git -C $planningRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw 'Published planning authority adoption local planning worktree observation failed.'
    }
    $allowedPlanningChanges = @{}
    foreach ($relativePath in $destinationFiles) {
        $allowedPlanningChanges["$([string]$planning.workspace_path)/$relativePath"] = $true
    }
    foreach ($line in $planningStatus) {
        if ([string]::IsNullOrWhiteSpace([string]$line) -or ([string]$line).Length -lt 4) {
            throw 'Published planning authority adoption local planning worktree status is malformed.'
        }
        $changedPath = ([string]$line).Substring(3).Trim('"').Replace('\', '/')
        if (-not $allowedPlanningChanges.ContainsKey($changedPath)) {
            throw "Published planning authority adoption planning repository has unrelated worktree change '$changedPath'."
        }
    }

    return [pscustomobject][ordered]@{
        document = $document
        adoption_sha256 = [string]$validated.adoption_sha256
        projection_sha256 = [string]$document.planning_workspace_projection.sha256
        workspace_state_before_sha256 = [string]$document.workspace_state_before.sha256
        workspace_state_after_sha256 = [string]$document.workspace_state_after.sha256
        source_revision = $sourceHead
        source_tree = $sourceTree
        planning_revision = $planningHead
        planning_tree = $planningTree
        source_remote_readback_revision = $freshSource
        planning_remote_configured = $false
        cleared_dirty_repository_id = $document.state_delta.cleared_dirty_repository_id
        dirty_repository_ids_before = @($document.state_delta.dirty_repository_ids_before)
        dirty_repository_ids_after = @($document.state_delta.dirty_repository_ids_after)
    }
}

Export-ModuleMember -Function `
    Test-MorphospacePublishedPlanningAuthorityAdoptionDocument, `
    Test-MorphospacePublishedPlanningAuthorityAdoptionLive
