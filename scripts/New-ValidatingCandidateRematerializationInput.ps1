[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$UnitId,
    [Parameter(Mandatory)][string]$RepositoryMapPath,
    [Parameter(Mandatory)][string]$TargetSourceCompositionLock,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,127}$')][string]$FreezeId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,118}$')][string]$RematerializationId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$RepoId,
    [string]$OutPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceSourceCompositionIdentity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function ConvertTo-MorphospaceProtocolRelativePath { param([string]$Path) MorphospaceProtocolCommon\ConvertTo-MorphospaceProtocolRelativePath -Path $Path }
function Resolve-MorphospaceWorkspacePath { param([string]$WorkspaceRoot,[string]$RelativePath,[switch]$RequireLeaf) MorphospaceProtocolCommon\Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -RequireLeaf:$RequireLeaf }
function Get-MorphospaceFileSha256 { param([string]$Path) MorphospaceProtocolCommon\Get-MorphospaceFileSha256 -Path $Path }
function Read-MorphospaceProtocolJson { param([string]$Path) MorphospaceProtocolCommon\Read-MorphospaceProtocolJson -Path $Path }
function Get-MorphospaceCanonicalJsonSha256 { param([object]$Value) MorphospaceProtocolCommon\Get-MorphospaceCanonicalJsonSha256 -Value $Value }
function ConvertTo-MorphospaceCanonicalJson { param([object]$Value) MorphospaceProtocolCommon\ConvertTo-MorphospaceCanonicalJson -Value $Value }
function Get-MorphospaceSourceCompositionFingerprint { param([string]$ProjectId,[string]$UnitId,[object[]]$Repositories) MorphospaceSourceCompositionIdentity\Get-MorphospaceSourceCompositionFingerprint -ProjectId $ProjectId -UnitId $UnitId -Repositories @($Repositories) }

$cleanDirtyFingerprint = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

function Copy-RematerializationInputValue {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 96 | ConvertFrom-Json -Depth 96 -DateKind String)
}

function Assert-RematerializationInputSchema {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Schema,[Parameter(Mandatory)][string]$Message)
    if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $Path) -SchemaFile (Join-Path $repositoryRoot "schemas\$Schema"))) { throw $Message }
}

function Invoke-RematerializationInputGit {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$Context,[switch]$AllowFailure)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git --no-optional-locks --no-pager --no-replace-objects -c core.pager=cat -C $Root @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($code -ne 0 -and -not $AllowFailure) { throw "Rematerialization input $Context failed: git $($Arguments -join ' ')" }
    return [pscustomobject]@{ code=[int]$code; lines=@($output | ForEach-Object { [string]$_ }) }
}

function Get-RematerializationInputGitScalar {
    param([string]$Root,[string[]]$Arguments,[string]$Context)
    $observation = Invoke-RematerializationInputGit -Root $Root -Arguments $Arguments -Context $Context
    $value = (($observation.lines -join "`n").Trim()).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Rematerialization input $Context returned no identity." }
    return $value
}

function Get-RematerializationInputMap {
    param([Parameter(Mandatory)][object[]]$Rows,[Parameter(Mandatory)][string]$Label)
    $result = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($row in @($Rows)) {
        $id = [string]$row.repo_id
        if ([string]::IsNullOrWhiteSpace($id) -or $result.ContainsKey($id)) { throw "$Label repeats or omits repository identity '$id'." }
        $result[$id] = $row
    }
    return $result
}

function Get-RematerializationInputIds {
    param([Parameter(Mandatory)][object[]]$Rows,[Parameter(Mandatory)][string]$Label)
    $map = Get-RematerializationInputMap -Rows @($Rows) -Label $Label
    [string[]]$ids = @($map.Keys)
    [Array]::Sort($ids,[StringComparer]::Ordinal)
    return @($ids)
}

function Assert-RematerializationInputIdSet {
    param([Parameter(Mandatory)][string[]]$Expected,[Parameter(Mandatory)][object[]]$Rows,[Parameter(Mandatory)][string]$Label)
    $actual = @(Get-RematerializationInputIds -Rows @($Rows) -Label $Label)
    if (($Expected -join '|') -cne ($actual -join '|')) { throw "$Label does not equal the explicit rematerialization repository set." }
}

function Get-RematerializationInputRelativePath {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $full = [IO.Path]::GetFullPath($Path)
    $relative = [IO.Path]::GetRelativePath($Workspace,$full).Replace('\','/')
    if ($relative -eq '..' -or $relative.StartsWith('../',[StringComparison]::Ordinal)) { throw "$Label must be inside the planning workspace." }
    return ConvertTo-MorphospaceProtocolRelativePath $relative
}

function Get-RematerializationInputEvents {
    param([Parameter(Mandatory)][string]$Path)
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { throw 'Rematerialization input event ledger contains a blank record.' }
        try { [void]$events.Add(($line | ConvertFrom-Json -Depth 96 -DateKind String)) }
        catch { throw 'Rematerialization input event ledger contains malformed JSON.' }
    }
    if ($events.Count -eq 0) { throw 'Rematerialization input requires a non-empty event ledger.' }
    return @($events.ToArray())
}

$workspace = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path)
$projectPath = Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf
$featurePath = Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf
$statePath = Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
$unitRelative = "iteration-units/$UnitId.json"
$unitPath = Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf
$eventsPath = Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
$mapPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryMapPath).Path)
$mapRelative = Get-RematerializationInputRelativePath -Workspace $workspace -Path $mapPath -Label 'Repository map'
$targetSourcePath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TargetSourceCompositionLock).Path)

$projectRaw = Get-MorphospaceFileSha256 $projectPath
$featureRaw = Get-MorphospaceFileSha256 $featurePath
$stateRaw = Get-MorphospaceFileSha256 $statePath
$unitRaw = Get-MorphospaceFileSha256 $unitPath
$eventsRaw = Get-MorphospaceFileSha256 $eventsPath
$mapRaw = Get-MorphospaceFileSha256 $mapPath
$targetSourceRaw = Get-MorphospaceFileSha256 $targetSourcePath

$project = Read-MorphospaceProtocolJson $projectPath
$feature = Read-MorphospaceProtocolJson $featurePath
$state = Read-MorphospaceProtocolJson $statePath
$unit = Read-MorphospaceProtocolJson $unitPath
$repositoryMap = Read-MorphospaceProtocolJson $mapPath
$targetSource = Read-MorphospaceProtocolJson $targetSourcePath

$projectSchema = if ([string]$project.schema -ceq 'rusty.morphospace.workflow.project_spec.v2') { 'project-spec-v2.schema.json' } else { 'project-spec.schema.json' }
$stateSchema = if ([string]$state.schema -ceq 'rusty.morphospace.workflow.workspace_state.v2') { 'workspace-state-v2.schema.json' } else { 'workspace-state.schema.json' }
$featureSchema = if ([string]$feature.schema -ceq 'rusty.morphospace.workflow.feature_lock.v2') { 'feature-lock-v2.schema.json' } else { 'feature-lock.schema.json' }
Assert-RematerializationInputSchema $projectPath $projectSchema 'Rematerialization input project is malformed.'
Assert-RematerializationInputSchema $featurePath $featureSchema 'Rematerialization input feature lock is malformed.'
Assert-RematerializationInputSchema $statePath $stateSchema 'Rematerialization input workspace state is malformed.'
Assert-RematerializationInputSchema $unitPath 'iteration-unit.schema.json' 'Rematerialization input iteration unit is malformed.'
Assert-RematerializationInputSchema $mapPath 'repository-map.schema.json' 'Rematerialization input repository map is malformed.'
Assert-RematerializationInputSchema $targetSourcePath 'source-composition-lock.schema.json' 'Rematerialization target source lock is malformed.'

if ([string]$project.project_id -cne [string]$state.project_id -or [string]$project.project_id -cne [string]$unit.project_id -or
    [string]$unit.unit_id -cne $UnitId -or [string]$state.current_unit -cne $UnitId -or [string]$unit.status -cne 'validating') {
    throw 'Rematerialization input requires the exact current validating unit.'
}
if ($null -eq $state.normal_validation_selection) { throw 'Rematerialization input requires the complete stale normal-validation selector.' }
if ($null -ne $state.pending_push_bundle) { throw 'Rematerialization input rejects a pending publication bundle.' }
if ($null -ne $state.validation_checkpoint -and [string]$state.validation_checkpoint.result -ceq 'pass') { throw 'Rematerialization input rejects an extant passing validation checkpoint.' }
if (-not ($unit.PSObject.Properties.Name -contains 'candidate_freeze') -or -not ($unit.PSObject.Properties.Name -contains 'source_composition') -or
    [string]$unit.source_composition.mode -cne 'exact-lock' -or $null -ne $unit.source_composition.materialization_receipt) {
    throw 'Rematerialization input requires a frozen exact-lock validating candidate.'
}

$requested = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($id in @($RepoId)) {
    if ([string]::IsNullOrWhiteSpace($id) -or $id -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$' -or -not $requested.Add($id)) { throw "Rematerialization input has an invalid or duplicate explicit RepoId '$id'." }
}
[string[]]$requestedIds = @($requested); [Array]::Sort($requestedIds,[StringComparer]::Ordinal)
if ($requestedIds.Count -eq 0) { throw 'Rematerialization input requires at least one explicit RepoId.' }

$predecessorFreezeRelative = ConvertTo-MorphospaceProtocolRelativePath ([string]$unit.candidate_freeze.receipt_path)
$predecessorFreezePath = Resolve-MorphospaceWorkspacePath $workspace $predecessorFreezeRelative -RequireLeaf
$predecessorFreezeRaw = Get-MorphospaceFileSha256 $predecessorFreezePath
if ($predecessorFreezeRaw -cne [string]$unit.candidate_freeze.receipt_sha256) { throw 'Rematerialization predecessor freeze bytes differ from the live unit marker.' }
Assert-RematerializationInputSchema $predecessorFreezePath 'candidate-freeze-v1.schema.json' 'Rematerialization predecessor freeze is malformed.'
$predecessorFreeze = Read-MorphospaceProtocolJson $predecessorFreezePath
if ([string]$predecessorFreeze.freeze_id -cne [string]$unit.candidate_freeze.freeze_id -or [string]$predecessorFreeze.project_id -cne [string]$project.project_id -or [string]$predecessorFreeze.unit_id -cne $UnitId) {
    throw 'Rematerialization predecessor freeze identity differs from the live unit marker.'
}

$predecessorSourceRelative = ConvertTo-MorphospaceProtocolRelativePath ([string]$unit.source_composition.lock_path)
$predecessorSourcePath = Resolve-MorphospaceWorkspacePath $workspace $predecessorSourceRelative -RequireLeaf
$predecessorSourceRaw = Get-MorphospaceFileSha256 $predecessorSourcePath
if ([string]$predecessorFreeze.expected.source_composition_path -cne $predecessorSourceRelative -or [string]$predecessorFreeze.expected.source_composition_sha256 -cne $predecessorSourceRaw -or
    [string]$predecessorFreeze.source_composition.path -cne $predecessorSourceRelative -or [string]$predecessorFreeze.source_composition.sha256 -cne $predecessorSourceRaw) {
    throw 'Rematerialization predecessor source-composition binding differs from its freeze.'
}
$predecessorSource = Read-MorphospaceProtocolJson $predecessorSourcePath
switch ([string]$predecessorSource.schema) {
    'rusty.morphospace.workflow.source_composition_lock.v1' {
        Assert-RematerializationInputSchema $predecessorSourcePath 'source-composition-lock.schema.json' 'Rematerialization predecessor source lock is malformed.'
        if ([string]$predecessorSource.project_id -cne [string]$project.project_id -or [string]$predecessorSource.unit_id -cne $UnitId) { throw 'Rematerialization predecessor source-lock identity differs.' }
    }
    'rusty.morphospace.workflow.development_envelope_source_composition.v1' {
        Assert-RematerializationInputSchema $predecessorSourcePath 'development-envelope-source-composition-v1.schema.json' 'Rematerialization predecessor development-envelope composition is malformed.'
        if ([string]$predecessorSource.project_id -cne [string]$project.project_id) { throw 'Rematerialization predecessor source-composition project differs.' }
    }
    default { throw "Unsupported rematerialization predecessor source-composition schema '$([string]$predecessorSource.schema)'." }
}

if ([string]$targetSource.project_id -cne [string]$project.project_id -or [string]$targetSource.unit_id -cne $UnitId) { throw 'Rematerialization target source-lock identity differs.' }
$targetFingerprint = Get-MorphospaceSourceCompositionFingerprint -ProjectId ([string]$project.project_id) -UnitId $UnitId -Repositories @($targetSource.repositories)
if ([string]$targetSource.fingerprint -cne $targetFingerprint) { throw 'Rematerialization target source-lock fingerprint is not canonical.' }
Assert-RematerializationInputIdSet $requestedIds @($predecessorSource.repositories) 'Predecessor source composition'
Assert-RematerializationInputIdSet $requestedIds @($targetSource.repositories) 'Target source composition'
Assert-RematerializationInputIdSet $requestedIds @($predecessorFreeze.final_repositories) 'Predecessor final repositories'
Assert-RematerializationInputIdSet $requestedIds @($predecessorFreeze.changed_paths) 'Predecessor changed paths'

$oldComposition = Get-RematerializationInputMap @($predecessorSource.repositories) 'Predecessor source composition'
$targetComposition = Get-RematerializationInputMap @($targetSource.repositories) 'Target source composition'
$oldFinal = Get-RematerializationInputMap @($predecessorFreeze.final_repositories) 'Predecessor final repositories'
$oldChanged = Get-RematerializationInputMap @($predecessorFreeze.changed_paths) 'Predecessor changed paths'
$heads = Get-RematerializationInputMap @($state.repository_heads) 'Workspace repository heads'
$mapped = Get-RematerializationInputMap @($repositoryMap.repositories) 'Repository map'
$lineageRows = [Collections.Generic.List[object]]::new()
$finalRows = [Collections.Generic.List[object]]::new()
$headRows = [Collections.Generic.List[object]]::new()
foreach ($id in $requestedIds) {
    if (-not $mapped.ContainsKey($id) -or -not $heads.ContainsKey($id)) { throw "Rematerialization repository '$id' is absent from the map or live state." }
    $old = $oldComposition[$id]; $target = $targetComposition[$id]; $frozen = $oldFinal[$id]; $changed = $oldChanged[$id]; $head = $heads[$id]; $mapEntry = $mapped[$id]
    if ([string]$old.role -cne [string]$target.role -or [string]$target.role -cne [string]$mapEntry.role) { throw "Rematerialization repository role differs for '$id'." }
    if ([string]$head.head -cne [string]$frozen.commit -or [string]$head.dirty_fingerprint -cne $cleanDirtyFingerprint) { throw "Rematerialization live predecessor head is not exact and clean for '$id'." }
    $root = [IO.Path]::GetFullPath([string]$mapEntry.path)
    if (-not [IO.Directory]::Exists($root)) { throw "Rematerialization mapped repository '$id' is absent." }
    $observedHead = Get-RematerializationInputGitScalar $root @('rev-parse','HEAD') "HEAD observation for '$id'"
    $observedTree = Get-RematerializationInputGitScalar $root @('rev-parse','HEAD^{tree}') "tree observation for '$id'"
    if ($observedHead -cne [string]$target.commit -or $observedTree -cne [string]$target.tree) { throw "Rematerialization mapped repository '$id' is not at the target commit/tree." }
    $status = Invoke-RematerializationInputGit $root @('status','--porcelain=v1','--untracked-files=all') "cleanliness observation for '$id'"
    if (@($status.lines).Count -ne 0) { throw "Rematerialization mapped repository '$id' is not completely clean." }
    $branchObservation = Invoke-RematerializationInputGit $root @('symbolic-ref','--quiet','--short','HEAD') "branch observation for '$id'" -AllowFailure
    $branch = if ($branchObservation.code -eq 0) { ($branchObservation.lines -join "`n").Trim() } else { $null }
    $remoteObservation = Invoke-RematerializationInputGit $root @('remote','get-url','origin') "remote observation for '$id'" -AllowFailure
    $remote = if ($remoteObservation.code -eq 0) { ($remoteObservation.lines -join "`n").Trim() } else { $null }
    if ([string]$target.branch -cne [string]$branch -or [string]$target.remote_url -cne [string]$remote -or [string]$target.materialization_path -cne (Split-Path -Leaf $root)) {
        throw "Rematerialization target branch, remote, or materialization identity differs for '$id'."
    }
    $baselineTree = Get-RematerializationInputGitScalar $root @('rev-parse',"$([string]$old.commit)^{tree}") "baseline tree observation for '$id'"
    $predecessorTree = Get-RematerializationInputGitScalar $root @('rev-parse',"$([string]$frozen.commit)^{tree}") "predecessor tree observation for '$id'"
    if ($baselineTree -cne [string]$old.tree -or $predecessorTree -cne [string]$frozen.tree) { throw "Rematerialization predecessor Git identity differs for '$id'." }
    if ((Invoke-RematerializationInputGit $root @('merge-base','--is-ancestor',[string]$old.commit,[string]$frozen.commit) "baseline ancestry for '$id'" -AllowFailure).code -ne 0 -or
        (Invoke-RematerializationInputGit $root @('merge-base','--is-ancestor',[string]$frozen.commit,[string]$target.commit) "target ancestry for '$id'" -AllowFailure).code -ne 0) {
        throw "Rematerialization ancestry differs for '$id'."
    }
    [string[]]$paths = @($changed.paths | ForEach-Object { ConvertTo-MorphospaceProtocolRelativePath ([string]$_) })
    [Array]::Sort($paths,[StringComparer]::Ordinal)
    $carried = [Collections.Generic.List[object]]::new()
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $paths) {
        if (-not $seenPaths.Add($path)) { throw "Rematerialization changed path repeats for '$id/$path'." }
        $oldBlob = Get-RematerializationInputGitScalar $root @('rev-parse',"$([string]$frozen.commit):$path") "predecessor blob for '$id/$path'"
        $newBlob = Get-RematerializationInputGitScalar $root @('rev-parse',"$([string]$target.commit):$path") "target blob for '$id/$path'"
        if ((Get-RematerializationInputGitScalar $root @('cat-file','-t',$oldBlob) "predecessor blob type for '$id/$path'") -cne 'blob' -or
            (Get-RematerializationInputGitScalar $root @('cat-file','-t',$newBlob) "target blob type for '$id/$path'") -cne 'blob' -or $oldBlob -cne $newBlob) {
            throw "Rematerialization target did not preserve predecessor blob '$id/$path'."
        }
        [void]$carried.Add([pscustomobject][ordered]@{path=$path;predecessor_blob=$oldBlob;target_blob=$newBlob})
    }
    [void]$lineageRows.Add([pscustomobject][ordered]@{
        repo_id=$id; role=[string]$target.role; source_baseline_commit=[string]$old.commit; source_baseline_tree=[string]$old.tree
        predecessor_commit=[string]$frozen.commit; predecessor_tree=[string]$frozen.tree; target_commit=[string]$target.commit; target_tree=[string]$target.tree
        carried_paths=@($carried.ToArray())
    })
    [void]$finalRows.Add([pscustomobject][ordered]@{repo_id=$id;commit=[string]$target.commit;tree=[string]$target.tree})
    [void]$headRows.Add([pscustomobject][ordered]@{
        repo_id=$id
        predecessor=[pscustomobject][ordered]@{head=[string]$frozen.commit;branch=$head.branch;dirty_fingerprint=$cleanDirtyFingerprint}
        target=[pscustomobject][ordered]@{head=[string]$target.commit;branch=$target.branch;dirty_fingerprint=$cleanDirtyFingerprint}
    })
}

$events = @(Get-RematerializationInputEvents $eventsPath)
$tail = $events[-1]
if ([string]$tail.event_id -cne [string]$state.last_event_id) { throw 'Rematerialization state and event tail differ.' }
$targetSourceRelative = "source-compositions/$([string]$targetSource.lock_id).lock.json"
$candidate = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.candidate_freeze.v2'; freeze_id=$FreezeId; project_id=[string]$project.project_id; unit_id=$UnitId
    expected=[pscustomobject][ordered]@{
        project_sha256=(Get-MorphospaceCanonicalJsonSha256 $project); project_raw_sha256=$projectRaw
        state_sha256=(Get-MorphospaceCanonicalJsonSha256 $state); state_raw_sha256=$stateRaw
        unit_sha256=(Get-MorphospaceCanonicalJsonSha256 $unit); unit_raw_sha256=$unitRaw
        feature_lock_sha256=(Get-MorphospaceCanonicalJsonSha256 $feature); feature_lock_raw_sha256=$featureRaw
        source_composition_path=$predecessorSourceRelative; source_composition_sha256=$predecessorSourceRaw
        repository_map_path=$mapRelative; repository_map_sha256=$mapRaw; repository_map_canonical_sha256=(Get-MorphospaceCanonicalJsonSha256 $repositoryMap)
        events_sha256=$eventsRaw; events_length=[IO.FileInfo]::new($eventsPath).Length; event_tail_id=[string]$tail.event_id
    }
    final_repositories=@($finalRows.ToArray()); changed_paths=@(Copy-RematerializationInputValue $predecessorFreeze.changed_paths)
    cleanliness_policy=[string]$predecessorFreeze.cleanliness_policy; instruction_surfaces=@(Copy-RematerializationInputValue $predecessorFreeze.instruction_surfaces)
    feature_lock=(Copy-RematerializationInputValue $predecessorFreeze.feature_lock); effects=@($predecessorFreeze.effects); permissions=@($predecessorFreeze.permissions)
    device_use=@($predecessorFreeze.device_use); test_matrix=@(Copy-RematerializationInputValue $predecessorFreeze.test_matrix); cleanup_evidence=@($predecessorFreeze.cleanup_evidence)
    source_composition=[pscustomobject][ordered]@{path=$targetSourceRelative;sha256=$targetSourceRaw}
    lineage=[pscustomobject][ordered]@{
        rematerialization_id=$RematerializationId
        predecessor_freeze=[pscustomobject][ordered]@{freeze_id=[string]$predecessorFreeze.freeze_id;receipt_path=$predecessorFreezeRelative;receipt_sha256=$predecessorFreezeRaw}
        predecessor_source_composition=[pscustomobject][ordered]@{path=$predecessorSourceRelative;sha256=$predecessorSourceRaw}
        predecessor_final_repositories=@(Copy-RematerializationInputValue $predecessorFreeze.final_repositories)
        invalidated_normal_validation_selection=(Copy-RematerializationInputValue $state.normal_validation_selection)
        repositories=@($lineageRows.ToArray()); repository_head_projections=@($headRows.ToArray())
        target_source_composition=[pscustomobject][ordered]@{path=$targetSourceRelative;sha256=$targetSourceRaw}
    }
    does_not_prove=@('Does not prove source mutation, validation, build, device behavior, acceptance, or publication.')
}

$candidateJson = ConvertTo-MorphospaceCanonicalJson $candidate
if (-not (Test-Json -Json $candidateJson -SchemaFile (Join-Path $repositoryRoot 'schemas\candidate-freeze-v2.schema.json'))) { throw 'Produced rematerialization input does not satisfy candidate-freeze-v2.schema.json.' }
foreach ($binding in @(
    @{path=$projectPath;hash=$projectRaw},@{path=$featurePath;hash=$featureRaw},@{path=$statePath;hash=$stateRaw},@{path=$unitPath;hash=$unitRaw},
    @{path=$eventsPath;hash=$eventsRaw},@{path=$mapPath;hash=$mapRaw},@{path=$targetSourcePath;hash=$targetSourceRaw},
    @{path=$predecessorFreezePath;hash=$predecessorFreezeRaw},@{path=$predecessorSourcePath;hash=$predecessorSourceRaw}
)) {
    if ((Get-MorphospaceFileSha256 ([string]$binding.path)) -cne [string]$binding.hash) { throw "Rematerialization input source bytes changed during production: $([string]$binding.path)" }
}

if (-not [string]::IsNullOrWhiteSpace($OutPath)) {
    $output = [IO.Path]::GetFullPath($OutPath)
    $workspacePrefix = $workspace.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($output.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Rematerialization input output must remain outside the planning workspace transaction targets.' }
    $parent = [IO.Path]::GetDirectoryName($output)
    if (-not [IO.Directory]::Exists($parent)) { throw 'Rematerialization input output parent must already exist.' }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($candidateJson + "`n")
    $stream = [IO.FileStream]::new($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

$candidate
