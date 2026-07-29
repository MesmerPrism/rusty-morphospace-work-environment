param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$ProjectionPath,
    [Parameter(Mandatory)][string]$SourceRepository,
    [Parameter(Mandatory)][string]$PlanningRepository,
    [Parameter(Mandatory)][string]$AdoptionPath,
    [Parameter(Mandatory)][string]$AdoptionId,
    [Parameter(Mandatory)][string]$ValidationGateId,
    [Parameter(Mandatory)][string]$ValidationEvidencePath,
    [Parameter(Mandatory)][string]$ObserverId,
    [Parameter(Mandatory)][string]$ObserverEvidencePath,
    [string]$Timestamp = '',
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePublishedPlanningAuthorityAdoption.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlanningProjection.psm1') -Force

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-GitValue([string]$Repository, [string[]]$Arguments, [string]$Context) {
    $rows = @(& git -C $Repository @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0 -or $rows.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$rows[0])) {
        throw "Git observation failed for $Context."
    }
    return ([string]$rows[0]).Trim()
}
function Get-RelativePath([string]$Root, [string]$Path, [string]$Context) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context is outside the workspace."
    }
    $relative = $fullPath.Substring($prefix.Length).Replace('\', '/')
    Test-PlanningProjectionRelativePath $relative $Context
    return $relative
}

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
$source = [IO.Path]::GetFullPath($SourceRepository).TrimEnd('\', '/')
$planning = [IO.Path]::GetFullPath($PlanningRepository).TrimEnd('\', '/')
$projectionFull = [IO.Path]::GetFullPath($ProjectionPath)
$adoptionFull = [IO.Path]::GetFullPath($AdoptionPath)
$validationFull = [IO.Path]::GetFullPath((Join-Path $workspace $ValidationEvidencePath))
$observerFull = [IO.Path]::GetFullPath((Join-Path $workspace $ObserverEvidencePath))
foreach ($requiredFile in @($projectionFull, $validationFull, $observerFull)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required evidence file is missing: $requiredFile"
    }
}
if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString('o') }

$validatedProjection = Test-MorphospacePlanningWorkspaceProjectionDocument -Path $projectionFull
$projection = $validatedProjection.document
if ([string]$projection.schema -cne 'rusty.morphospace.workflow.planning_workspace_projection.v3') {
    throw 'Published active planning adoption requires a v3 projection.'
}
$projectionRelative = Get-RelativePath $workspace $projectionFull 'Projection path'
$adoptionRelative = Get-RelativePath $workspace $adoptionFull 'Adoption path'
if ($projectionRelative -cne [string]$projection.planning.projection_record_path) {
    throw 'Projection path differs from its self-binding.'
}
foreach ($output in @($adoptionFull)) {
    if (Test-Path -LiteralPath $output) { throw "Output already exists: $output" }
}

$statePath = Join-Path $workspace 'workspace.state.json'
$stateBytes = [IO.File]::ReadAllBytes($statePath)
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$state = $utf8.GetString($stateBytes) | ConvertFrom-Json
if ([string]$state.current_unit -cne [string]$projection.unit_id -or
    $null -ne $state.next_ready_unit -or $null -ne $state.pending_push_bundle) {
    throw 'Live workspace does not retain the projected active-unit state.'
}
$events = @(Get-Content -LiteralPath (Join-Path $workspace 'iteration-events.jsonl') |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_ | ConvertFrom-Json })
$sequence = if ($events.Count -eq 0) { 1 } else { ([int]($events | Sort-Object sequence | Select-Object -Last 1).sequence) + 1 }
$eventId = "$([string]$projection.unit_id)-active-planning-authority-adopted-$('{0:d4}' -f $sequence)"

$receiptRoot = Split-Path -Parent $adoptionFull
$beforeFull = Join-Path $receiptRoot "$AdoptionId-state-before.json"
$afterFull = Join-Path $receiptRoot "$AdoptionId-state-after.json"
foreach ($output in @($beforeFull, $afterFull)) {
    if (Test-Path -LiteralPath $output) { throw "Output already exists: $output" }
}
$beforeRelative = Get-RelativePath $workspace $beforeFull 'Before-state path'
$afterRelative = Get-RelativePath $workspace $afterFull 'After-state path'
$sourceRow = @($state.repository_heads | Where-Object { [string]$_.repo_id -ceq [string]$projection.source.repo_id })
if ($sourceRow.Count -ne 1) { throw 'Projected source repository row is not unique.' }
$sourceBinding = [ordered]@{
    repo_id = [string]$sourceRow[0].repo_id
    head = [string]$sourceRow[0].head
    branch = $sourceRow[0].branch
    dirty_fingerprint = $sourceRow[0].dirty_fingerprint
}
$dirtyIds = @($state.dirty_repositories | ForEach-Object { [string]$_ })
$afterState = $state | ConvertTo-Json -Depth 100 | ConvertFrom-Json
$afterState.last_event_id = $eventId
$afterJson = $afterState | ConvertTo-Json -Depth 100

$sourceHead = Get-GitValue $source @('rev-parse', 'HEAD') 'source HEAD'
$sourceTree = Get-GitValue $source @('rev-parse', 'HEAD^{tree}') 'source tree'
$sourceBranch = Get-GitValue $source @('branch', '--show-current') 'source branch'
$sourceUpstream = Get-GitValue $source @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') 'source upstream'
$planningHead = Get-GitValue $planning @('rev-parse', 'HEAD') 'planning HEAD'
$planningTree = Get-GitValue $planning @('rev-parse', 'HEAD^{tree}') 'planning tree'
$planningBranch = Get-GitValue $planning @('branch', '--show-current') 'planning branch'
if ($sourceHead -cne [string]$projection.source.published_revision -or
    $sourceBranch -cne [string]$projection.source.branch -or
    $sourceUpstream -cne [string]$projection.source.upstream -or
    $planningHead -cne [string]$projection.planning.base_revision) {
    throw 'Source or planning repository no longer matches the projection base.'
}

$beforeBinding = [ordered]@{
    path = $beforeRelative
    sha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stateBytes))).ToLowerInvariant()
    current_unit = [string]$projection.unit_id
    next_ready_unit = $null
    pending_push_bundle = $null
    dirty_repository_ids = $dirtyIds
    source_repository = $sourceBinding
}
$afterBytes = [Text.UTF8Encoding]::new($false).GetBytes($afterJson + [Environment]::NewLine)
$afterBinding = [ordered]@{
    path = $afterRelative
    sha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($afterBytes))).ToLowerInvariant()
    current_unit = [string]$projection.unit_id
    next_ready_unit = $null
    pending_push_bundle = $null
    dirty_repository_ids = $dirtyIds
    source_repository = $sourceBinding
}
$document = [ordered]@{
    '$schema' = '../schemas/published-planning-authority-adoption.schema.json'
    schema = 'rusty.morphospace.workflow.published_planning_authority_adoption.v2'
    adoption_id = $AdoptionId
    project_id = [string]$projection.project_id
    recorded_at = $Timestamp
    status = 'published-active-planning-authority-adopted'
    planning_workspace_projection = [ordered]@{
        path = $projectionRelative
        projection_id = [string]$projection.projection_id
        sha256 = [string]$validatedProjection.sha256
    }
    workspace_state_before = $beforeBinding
    workspace_state_after = $afterBinding
    source_publication = [ordered]@{
        repo_id = [string]$projection.source.repo_id
        branch = [string]$projection.source.branch
        remote = [string]$projection.source.remote
        remote_ref = [string]$projection.source.remote_ref
        upstream = [string]$projection.source.upstream
        pre_merge_revision = [string]$projection.source.old_revision
        published_revision = $sourceHead
        readback_revision = [string]$projection.source.observed_remote_revision
        published_tree = $sourceTree
        worktree_clean = $true
        synchronized = $true
        fast_forward_verified = $true
        remote_match = $true
        force_push_used = $false
        history_rewrite_used = $false
    }
    planning_repository = [ordered]@{
        repo_id = [string]$projection.planning.repo_id
        branch = $planningBranch
        head_revision = $planningHead
        head_tree = $planningTree
        workspace_path = [string]$projection.planning.workspace_path
        distinct_from_source = $true
        remote_configured = $false
        unrelated_worktree_clean = $true
    }
    validation = @([ordered]@{
        gate_id = $ValidationGateId
        status = 'pass'
        evidence = [ordered]@{ path = $ValidationEvidencePath; sha256 = Get-Hash $validationFull }
    })
    observers = @([ordered]@{
        observer_id = $ObserverId
        recorded_at = $Timestamp
        evidence = [ordered]@{ path = $ObserverEvidencePath; sha256 = Get-Hash $observerFull }
    })
    state_delta = [ordered]@{
        cleared_dirty_repository_id = $null
        dirty_repository_ids_before = $dirtyIds
        dirty_repository_ids_after = $dirtyIds
        repository_before = $sourceBinding
        repository_after = $sourceBinding
        last_event_id_before = $state.last_event_id
        last_event_id_after = $eventId
        preserved_fields = @(
            'blockers', 'capability_registry', 'current_unit', 'dirty_repositories',
            'last_accepted_receipt', 'module_registry', 'next_ready_unit',
            'pending_push_bundle', 'plan_revision', 'project_id',
            'repository_checkpoints', 'repository_heads', 'validation_checkpoint'
        )
    }
    nonclaims = [ordered]@{
        external_planning_authority_existed_at_publication = $false
        prepared_plan_or_executed_push_reconstructed = $false
        source_acceptance_created = $false
        git_or_remote_mutation_performed = $false
        force_push_or_history_rewrite_used = $false
        unrelated_dirty_repositories_cleared = $false
    }
    failure = $null
}
if (-not $Execute) { $document | ConvertTo-Json -Depth 100; return }

[IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
[IO.File]::WriteAllBytes($beforeFull, $stateBytes)
[IO.File]::WriteAllBytes($afterFull, $afterBytes)
$documentJson = $document | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText($adoptionFull, $documentJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Test-MorphospacePublishedPlanningAuthorityAdoptionLive -Path $adoptionFull -WorkspaceRoot $workspace `
    -SourceRepository $source -PlanningRepository $planning
