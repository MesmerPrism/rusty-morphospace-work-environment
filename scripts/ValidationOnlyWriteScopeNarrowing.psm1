Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceSourceCompositionIdentity.psm1') -Force

function Copy-ValidationOnlyScopeValue {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String)
}

function Get-ValidationOnlyScopeEvents {
    param([Parameter(Mandatory)][string]$Path)
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $events.Add((ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line)) -Context 'iteration event ledger entry')) | Out-Null
        } catch { throw 'Validation-only scope narrowing found malformed event-ledger JSON.' }
    }
    if ($events.Count -eq 0) { throw 'Validation-only scope narrowing requires a non-empty event ledger.' }
    return @($events.ToArray())
}

function Assert-ValidationOnlyScopeDocument {
    param([Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][object]$Document,[Parameter(Mandatory)][string]$RepositoryRoot)
    $schemaName = switch ([string]$Document.schema) {
        'rusty.morphospace.workflow.project_spec.v2' { 'project-spec-v2.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v2' { 'workspace-state-v2.schema.json' }
        'rusty.morphospace.workflow.iteration_unit.v1' { 'iteration-unit.schema.json' }
        'rusty.morphospace.workflow.iteration_event.v1' { 'iteration-event.schema.json' }
        'rusty.morphospace.workflow.iteration_event.v2' { 'iteration-event-v2.schema.json' }
        default { throw "Unsupported $Label schema '$([string]$Document.schema)'." }
    }
    if (-not (Test-Json -Json ($Document | ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $RepositoryRoot "schemas\$schemaName"))) {
        throw "$Label does not satisfy $schemaName."
    }
}

function Get-ValidationOnlyCanonicalPaths {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Paths,[Parameter(Mandatory)][string]$Context)
    $result = [Collections.Generic.List[string]]::new()
    $folded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in @($Paths)) {
        $path = [string]$raw
        if ($path -cmatch '\\' -or $path.EndsWith('/')) { throw "$Context contains a noncanonical path '$path'." }
        $canonical = ConvertTo-MorphospaceProtocolRelativePath $path
        if ($canonical -cne $path -or -not $folded.Add($path)) { throw "$Context contains a noncanonical or duplicate path '$path'." }
        $result.Add($path) | Out-Null
    }
    return @($result.ToArray())
}

function Test-ValidationOnlyPathAllowed {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object[]]$AllowedPaths)
    foreach ($raw in @($AllowedPaths)) {
        $allowed = ([string]$raw).Replace('\','/').TrimEnd('/')
        if ($Path.Equals($allowed,[StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($allowed + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Assert-ValidationOnlyScopeTransition {
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][object]$SourceLock,
        [AllowNull()][object]$LiveUnit,
        [switch]$RequireLiveBefore
    )
    $beforeRows = @($Request.before_allowed_repositories)
    $afterRows = @($Request.after_allowed_repositories)
    if ($beforeRows.Count -eq 0 -or $beforeRows.Count -ne $afterRows.Count) {
        throw 'Validation-only narrowing must preserve a non-empty complete allowed-repository row set.'
    }
    $projectRows = @($Project.repositories)
    $projectIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $projectRows) { if (-not $projectIds.Add([string]$row.repo_id)) { throw 'Project repository scope contains duplicate identities.' } }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $liveRows = if ($null -ne $LiveUnit) { @($LiveUnit.allowed_repositories) } else { @() }
    if ($RequireLiveBefore -and $liveRows.Count -ne $beforeRows.Count) { throw 'Before scope row count differs from the live unit.' }
    $removed = 0
    for ($i = 0; $i -lt $beforeRows.Count; $i++) {
        $repoId = [string]$beforeRows[$i].repo_id
        if (-not $seen.Add($repoId) -or [string]$afterRows[$i].repo_id -cne $repoId -or -not $projectIds.Contains($repoId) -or @($SourceLock.repositories | Where-Object { [string]$_.repo_id -ceq $repoId }).Count -ne 1) {
            throw 'Validation-only narrowing may not add, remove, reorder, or retarget repository identities.'
        }
        $beforePaths = @(Get-ValidationOnlyCanonicalPaths @($beforeRows[$i].allowed_paths) "Before scope '$repoId'")
        $afterPaths = @(Get-ValidationOnlyCanonicalPaths @($afterRows[$i].allowed_paths) "After scope '$repoId'")
        if ($RequireLiveBefore) {
            if ([string]$liveRows[$i].repo_id -cne $repoId) { throw 'Before scope repository identities differ from the live unit.' }
            $livePaths = @(Get-ValidationOnlyCanonicalPaths @($liveRows[$i].allowed_paths) "Live scope '$repoId'")
            if ((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{p=$livePaths})) -cne (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{p=$beforePaths}))) { throw "Before scope '$repoId' differs from the live unit." }
        }
        $beforeSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($path in $beforePaths) { [void]$beforeSet.Add($path) }
        foreach ($path in $afterPaths) { if (-not $beforeSet.Contains($path)) { throw "After scope '$repoId' introduces path '$path'." } }
        $removed += $beforePaths.Count - $afterPaths.Count
        $projectMatches = @($projectRows | Where-Object { [string]$_.repo_id -ceq $repoId })
        if ($projectMatches.Count -ne 1) { throw "Project repository scope does not contain exact row '$repoId'." }
        foreach ($path in $afterPaths) { if (-not (Test-ValidationOnlyPathAllowed $path @($projectMatches[0].allowed_paths))) { throw "Retained path '$repoId/$path' is outside project scope." } }
    }
    if ($removed -le 0) { throw 'Validation-only narrowing must remove at least one allowed path.' }
}

$script:ValidationOnlyGit = (@(Get-Command git -CommandType Application -ErrorAction Stop)[0]).Source
function Invoke-ValidationOnlyGit {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string[]]$Arguments)
    $safe = @('--no-optional-locks','--no-replace-objects','--literal-pathspecs','-c','core.quotepath=false','-c','color.ui=false','-c','core.fsmonitor=false','-c','diff.external=','-c','core.hooksPath=NUL','-C',$Repository) + $Arguments
    $output = @(& $script:ValidationOnlyGit @safe 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "Validation-only source observation failed: git $($Arguments -join ' ')`n$($output -join "`n")" }
    return @($output)
}

function Get-ValidationOnlySourceObservations {
    param([Parameter(Mandatory)][object]$Map,[Parameter(Mandatory)][object]$SourceLock)
    $mapRows = @($Map.repositories | Where-Object { [string]$_.role -ceq 'source' })
    if ($mapRows.Count -eq 0 -or @($SourceLock.repositories).Count -ne $mapRows.Count) { throw 'Validation-only scope narrowing requires one non-empty exact mapped and locked source set.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($locked in @($SourceLock.repositories)) {
        $repoId = [string]$locked.repo_id
        $matches = @($mapRows | Where-Object { [string]$_.repo_id -ceq $repoId })
        if (-not $seen.Add($repoId) -or $matches.Count -ne 1) { throw "Source lock/map identity '$repoId' is missing or duplicated." }
        $repo = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath ([string]$matches[0].path) -ErrorAction Stop).Path)
        $status = @(Invoke-ValidationOnlyGit -Repository $repo -Arguments @('status','--porcelain=v1','--untracked-files=all'))
        $head = @((Invoke-ValidationOnlyGit -Repository $repo -Arguments @('rev-parse','HEAD')))[0].Trim().ToLowerInvariant()
        $tree = @((Invoke-ValidationOnlyGit -Repository $repo -Arguments @('rev-parse','HEAD^{tree}')))[0].Trim().ToLowerInvariant()
        if ($status.Count -ne 0 -or $head -cne [string]$locked.commit -or $tree -cne [string]$locked.tree -or -not [bool]$locked.tracked_worktree_clean) {
            throw "Source repository '$repoId' is not the exact clean locked commit and tree."
        }
        $observations.Add([pscustomobject][ordered]@{repo_id=$repoId;path=$repo;head=$head;tree=$tree}) | Out-Null
    }
    if ($seen.Count -ne $mapRows.Count) { throw 'Source lock does not cover the complete mapped source set.' }
    return @($observations.ToArray())
}

function Assert-ValidationOnlyPreimageBytes {
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$UnitPath,
        [Parameter(Mandatory)][string]$EventsPath,
        [Parameter(Mandatory)][string]$MapPath,
        [Parameter(Mandatory)][string]$SourceLockPath,
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$RequestSha256
    )
    foreach ($binding in @(
        @('project raw hash',[string]$Expected.project_raw_sha256,(Get-MorphospaceFileSha256 $ProjectPath)),
        @('state raw hash',[string]$Expected.state_raw_sha256,(Get-MorphospaceFileSha256 $StatePath)),
        @('unit raw hash',[string]$Expected.unit_raw_sha256,(Get-MorphospaceFileSha256 $UnitPath)),
        @('event-ledger hash',[string]$Expected.events_sha256,(Get-MorphospaceFileSha256 $EventsPath)),
        @('repository-map raw hash',[string]$Expected.repository_map_sha256,(Get-MorphospaceFileSha256 $MapPath)),
        @('source-composition raw hash',[string]$Expected.source_composition_sha256,(Get-MorphospaceFileSha256 $SourceLockPath)),
        @('request raw hash',$RequestSha256,(Get-MorphospaceFileSha256 $RequestPath))
    )) { if ([string]$binding[1] -cne [string]$binding[2]) { throw "Validation-only narrowing $($binding[0]) changed before transition." } }
    if ([int64]$Expected.events_length -ne [IO.FileInfo]::new($EventsPath).Length) { throw 'Validation-only narrowing event-ledger length changed before transition.' }
}

function Assert-ValidationOnlySourceObservationsStable {
    param([Parameter(Mandatory)][object[]]$Observations)
    foreach ($row in @($Observations)) {
        $status = @(Invoke-ValidationOnlyGit -Repository ([string]$row.path) -Arguments @('status','--porcelain=v1','--untracked-files=all'))
        $head = @((Invoke-ValidationOnlyGit -Repository ([string]$row.path) -Arguments @('rev-parse','HEAD')))[0].Trim().ToLowerInvariant()
        $tree = @((Invoke-ValidationOnlyGit -Repository ([string]$row.path) -Arguments @('rev-parse','HEAD^{tree}')))[0].Trim().ToLowerInvariant()
        if ($status.Count -ne 0 -or $head -cne [string]$row.head -or $tree -cne [string]$row.tree) { throw "Source repository '$([string]$row.repo_id)' changed during validation-only scope narrowing." }
    }
}

function New-ValidationOnlyScopeResult {
    param([object]$Request,[object]$Unit,[object]$State,[string]$Timestamp,[string]$OutRelative,[string]$RequestHash,[bool]$Executed,[string]$EventId)
    $result = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$Request.project_id;unit_id=[string]$Request.unit_id;action='NarrowValidationOnlyWriteScope';timestamp=$Timestamp;executed=$Executed;transition='validation-only-write-scope-narrowed';status_before=[string]$Unit.status;status_after=[string]$Unit.status;current_unit_before=$State.current_unit;current_unit_after=$State.current_unit;preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject][ordered]@{path=$OutRelative;sha256=$RequestHash};event_id=$(if($Executed){$EventId}else{$null})}
    $repoRoot = Split-Path $PSScriptRoot -Parent
    if (-not (Test-Json -Json ($result|ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'))) { throw 'NarrowValidationOnlyWriteScope emitted an invalid automation receipt.' }
    return $result
}

function Assert-ValidationOnlyRecoveryIntent {
    param([object]$Intent,[object]$Request,[object]$Project,[object]$State,[object]$Unit,[object[]]$Events,[string]$RequestHash,[string]$RequestPath,[string]$StatePath,[string]$UnitPath,[string]$OutRelative,[string]$EventId,[string]$TransactionId,[string]$Timestamp,[object]$SourceLock)
    $expected = $Request.expected
    if ([string]$Intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v6' -or [string]$Intent.transaction_id -cne $TransactionId -or [string]$Intent.status -cne 'prepared' -or [string]$Intent.state.path -cne 'workspace.state.json' -or [string]$Intent.unit.path -cne "iteration-units/$([string]$Request.unit_id).json" -or [string]$Intent.events.path -cne 'iteration-events.jsonl') { throw 'Validation-only recovery intent identity or projection paths differ.' }
    if ([string]$Intent.pre.state.sha256 -cne [string]$expected.state_sha256 -or [string]$Intent.pre.unit.sha256 -cne [string]$expected.unit_sha256 -or [string]$Intent.pre_state_raw.path -cne 'workspace.state.json' -or [string]$Intent.pre_state_raw.sha256 -cne [string]$expected.state_raw_sha256 -or [string]$Intent.pre_unit_raw.path -cne "iteration-units/$([string]$Request.unit_id).json" -or [string]$Intent.pre_unit_raw.sha256 -cne [string]$expected.unit_raw_sha256) { throw 'Validation-only recovery intent preimage bindings differ.' }
    if ([string]$Intent.expected.state_sha256 -cne [string]$expected.state_sha256 -or [string]$Intent.expected.unit_sha256 -cne [string]$expected.unit_sha256 -or [string]$Intent.expected.event_tail_id -cne [string]$expected.event_tail_id -or [string]$Intent.expected.events_sha256 -cne [string]$expected.events_sha256 -or [int64]$Intent.expected.events_length -ne [int64]$expected.events_length) { throw 'Validation-only recovery intent event-ledger bindings differ.' }
    $requestBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($RequestPath))
    if (@($Intent.artifacts).Count -ne 1 -or [string]$Intent.artifacts[0].path -cne $OutRelative -or [string]$Intent.artifacts[0].sha256 -cne $RequestHash -or [string]$Intent.artifacts[0].bytes_base64 -cne $requestBase64) { throw 'Validation-only recovery intent artifact differs.' }
    if (@($Intent.additional_projections).Count -ne 1 -or [string]$Intent.additional_projections[0].path -cne 'project.spec.json' -or [string]$Intent.additional_projections[0].pre_sha256 -cne [string]$expected.project_sha256 -or [string]$Intent.additional_projections[0].target_sha256 -cne [string]$expected.project_sha256 -or [string]$Intent.additional_projections[0].pre_raw_sha256 -cne [string]$expected.project_raw_sha256 -or (Get-MorphospaceCanonicalJsonSha256 $Intent.additional_projections[0].document) -cne [string]$expected.project_sha256 -or (Get-MorphospaceCanonicalJsonSha256 $Project) -cne [string]$expected.project_sha256) { throw 'Validation-only recovery intent unchanged project binding differs.' }
    $event = $Intent.event
    if ([string]$event.schema -cne 'rusty.morphospace.workflow.iteration_event.v1' -or [string]$event.event_id -cne $EventId -or [string]$event.project_id -cne [string]$Request.project_id -or [string]$event.unit_id -cne [string]$Request.unit_id -or [string]$event.event_type -cne 'state-transition' -or [string]$event.summary -cne "Narrowed only the current validation-only unit's declared write paths while preserving repository identities and source bytes." -or @($event.receipts).Count -ne 1 -or [string]$event.receipts[0] -cne $OutRelative -or ($Timestamp -and [string]$event.timestamp -cne $Timestamp) -or -not (Test-MorphospaceStrictUtcTimestamp ([string]$event.timestamp))) { throw 'Validation-only recovery intent event differs.' }
    $preEvents = @($Events | Where-Object { [string]$_.event_id -ceq [string]$expected.event_tail_id })
    $ownedEvents = @($Events | Where-Object { [string]$_.event_id -ceq $EventId })
    if ($preEvents.Count -ne 1 -or [int]$event.sequence -ne ([int]$preEvents[0].sequence + 1) -or $ownedEvents.Count -gt 1) { throw 'Validation-only recovery intent event sequence or identity differs.' }
    if ($ownedEvents.Count -eq 0) {
        if ([string]$Events[-1].event_id -cne [string]$expected.event_tail_id) { throw 'Validation-only recovery event ledger has an unauthorized suffix.' }
    } elseif ($Events.Count -lt 2 -or [string]$Events[-2].event_id -cne [string]$expected.event_tail_id -or [string]$Events[-1].event_id -cne $EventId -or (Get-MorphospaceCanonicalJsonSha256 $Events[-1]) -cne (Get-MorphospaceCanonicalJsonSha256 $event)) {
        throw 'Validation-only recovery event ledger has an unauthorized suffix.'
    }

    $preState = Copy-ValidationOnlyScopeValue $Intent.target.state.document; $preState.last_event_id = [string]$expected.event_tail_id
    $expectedTargetState = Copy-ValidationOnlyScopeValue $preState; $expectedTargetState.last_event_id = $EventId
    if ((Get-MorphospaceCanonicalJsonSha256 $preState) -cne [string]$expected.state_sha256 -or (Get-MorphospaceCanonicalJsonSha256 $expectedTargetState) -cne [string]$Intent.target.state.sha256 -or (Get-MorphospaceCanonicalJsonSha256 $Intent.target.state.document) -cne [string]$Intent.target.state.sha256) { throw 'Validation-only recovery target state changes more than last_event_id.' }
    $preUnit = Copy-ValidationOnlyScopeValue $Intent.target.unit.document
    $targetUnit = Copy-ValidationOnlyScopeValue $Intent.target.unit.document
    if (@($preUnit.allowed_repositories).Count -ne @($Request.before_allowed_repositories).Count -or @($targetUnit.allowed_repositories).Count -ne @($Request.after_allowed_repositories).Count) { throw 'Validation-only recovery target scope row count differs.' }
    for($i=0;$i-lt@($preUnit.allowed_repositories).Count;$i++){
        if([string]$preUnit.allowed_repositories[$i].repo_id-cne[string]$Request.before_allowed_repositories[$i].repo_id-or[string]$targetUnit.allowed_repositories[$i].repo_id-cne[string]$Request.after_allowed_repositories[$i].repo_id){throw 'Validation-only recovery target repository identities differ.'}
        $preUnit.allowed_repositories[$i].allowed_paths=@($Request.before_allowed_repositories[$i].allowed_paths|ForEach-Object{[string]$_})
        $targetUnit.allowed_repositories[$i].allowed_paths=@($Request.after_allowed_repositories[$i].allowed_paths|ForEach-Object{[string]$_})
    }
    if((Get-MorphospaceCanonicalJsonSha256 $preUnit)-cne[string]$expected.unit_sha256-or(Get-MorphospaceCanonicalJsonSha256 $targetUnit)-cne[string]$Intent.target.unit.sha256-or(Get-MorphospaceCanonicalJsonSha256 $Intent.target.unit.document)-cne[string]$Intent.target.unit.sha256){throw 'Validation-only recovery target unit changes more than allowed_repositories.'}
    Assert-ValidationOnlyScopeTransition -Request $Request -Project $Project -SourceLock $SourceLock
    $liveStateHash=Get-MorphospaceCanonicalJsonSha256 $State;$liveUnitHash=Get-MorphospaceCanonicalJsonSha256 $Unit
    if(@([string]$expected.state_sha256,[string]$Intent.target.state.sha256)-cnotcontains$liveStateHash-or@([string]$expected.unit_sha256,[string]$Intent.target.unit.sha256)-cnotcontains$liveUnitHash){throw 'Validation-only recovery live projections are outside the exact preimage and target.'}
    $expectedLiveStateRaw = if($liveStateHash -ceq [string]$expected.state_sha256){[string]$expected.state_raw_sha256}else{Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $Intent.target.state.document)}
    $expectedLiveUnitRaw = if($liveUnitHash -ceq [string]$expected.unit_sha256){[string]$expected.unit_raw_sha256}else{Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $Intent.target.unit.document)}
    if((Get-MorphospaceFileSha256 $StatePath)-cne$expectedLiveStateRaw-or(Get-MorphospaceFileSha256 $UnitPath)-cne$expectedLiveUnitRaw){throw 'Validation-only recovery live projection bytes differ from the exact preimage or owned target.'}
}

function Invoke-MorphospaceNarrowValidationOnlyWriteScope {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$ValidationOnlyWriteScopeNarrowing,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedValidationOnlyWriteScopeNarrowingSha256 = '',
        [string]$Timestamp = '',
        [scriptblock]$BeforeTransitionHook,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter = 'none',
        [switch]$Execute
    )
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workspace = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).Path).TrimEnd('\','/')
    $requestPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ValidationOnlyWriteScopeNarrowing -ErrorAction Stop).Path)
    $mapPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoMapPath -ErrorAction Stop).Path)
    $requestRaw = Get-Content -Raw -LiteralPath $requestPath
    if (-not (Test-Json -Json $requestRaw -SchemaFile (Join-Path $repoRoot 'schemas\validation-only-write-scope-narrowing-v1.schema.json'))) { throw 'Validation-only write-scope narrowing request does not satisfy its schema.' }
    $request = Read-MorphospaceProtocolJson $requestPath
    if ([string]$request.unit_id -cne $UnitId -or [string]$request.expected.current_unit -cne $UnitId) { throw 'Validation-only narrowing identity and expected current unit must match UnitId.' }
    $requestHash = Get-MorphospaceFileSha256 $requestPath
    if ($ExpectedValidationOnlyWriteScopeNarrowingSha256 -and $ExpectedValidationOnlyWriteScopeNarrowingSha256 -cne $requestHash) { throw 'ExpectedValidationOnlyWriteScopeNarrowingSha256 does not match the request.' }
    if ($Execute -and -not $ExpectedValidationOnlyWriteScopeNarrowingSha256) { throw 'Executed NarrowValidationOnlyWriteScope requires ExpectedValidationOnlyWriteScopeNarrowingSha256 from its dry run.' }

    $projectRelative = 'project.spec.json'; $stateRelative = 'workspace.state.json'; $unitRelative = "iteration-units/$UnitId.json"; $eventsRelative = 'iteration-events.jsonl'
    $projectPath = Resolve-MorphospaceWorkspacePath $workspace $projectRelative -RequireLeaf
    $statePath = Resolve-MorphospaceWorkspacePath $workspace $stateRelative -RequireLeaf
    $unitPath = Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace $eventsRelative -RequireLeaf
    $outAbsolute = [IO.Path]::GetFullPath($OutPath); $workspacePrefix = $workspace + [IO.Path]::DirectorySeparatorChar
    if (-not $outAbsolute.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Validation-only narrowing output must stay inside the workspace.' }
    Assert-MorphospaceNoReparseAncestor -Root $workspace -Candidate $outAbsolute
    $outRelative = $outAbsolute.Substring($workspacePrefix.Length).Replace('\','/'); $expectedOut = "receipts/$([string]$request.narrowing_id).json"
    if ($outRelative -cne $expectedOut -or $requestPath -ceq $outAbsolute) { throw "Validation-only narrowing output must be the transaction-owned path '$expectedOut'." }
    $eventId = "$([string]$request.narrowing_id)-recorded"; $transactionId = "$eventId-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"; $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentPath = Resolve-MorphospaceWorkspacePath $workspace $intentRelative; $completionPath = Resolve-MorphospaceWorkspacePath $workspace $completionRelative
    $hasIntent = [IO.File]::Exists($intentPath); $hasCompletion = [IO.File]::Exists($completionPath)
    if ($hasCompletion -and -not $hasIntent) { throw 'Validation-only narrowing completion exists without its owned intent.' }

    $project = Read-MorphospaceProtocolJson $projectPath; $state = Read-MorphospaceProtocolJson $statePath; $unit = Read-MorphospaceProtocolJson $unitPath
    $events = @(Get-ValidationOnlyScopeEvents $eventsPath)
    foreach ($entry in @([pscustomobject]@{l='project';d=$project},[pscustomobject]@{l='state';d=$state},[pscustomobject]@{l='unit';d=$unit})) { Assert-ValidationOnlyScopeDocument $entry.l $entry.d $repoRoot }
    for ($eventIndex=0; $eventIndex -lt $events.Count; $eventIndex++) {
        if ([string]$events[$eventIndex].schema -ceq 'rusty.morphospace.workflow.iteration_event.v2' -and ($eventIndex -ne 0 -or [string]$events[$eventIndex].previous_event_sha256 -cne ('0'*64))) { throw 'Validation-only narrowing found an invalid historical v2 event position.' }
        Assert-ValidationOnlyScopeDocument 'event' $events[$eventIndex] $repoRoot
    }
    if ([string]$project.project_id -cne [string]$request.project_id -or [string]$state.project_id -cne [string]$request.project_id -or [string]$unit.project_id -cne [string]$request.project_id -or [string]$unit.unit_id -cne $UnitId -or [string]$state.current_unit -cne $UnitId -or [string]$unit.work_mode -cne 'validation-only' -or [string]$unit.status -notin @('active','validating') -or [string]$request.expected.status -cne [string]$unit.status) { throw 'NarrowValidationOnlyWriteScope requires the exact current active or validating validation-only unit.' }
    if ($state.PSObject.Properties.Name -contains 'normal_validation_selection' -and $null -ne $state.normal_validation_selection) { throw 'Validation-only scope narrowing requires no normal validation selection.' }
    if ($null -ne $state.validation_checkpoint) {
        $checkpointPath = Resolve-MorphospaceWorkspacePath $workspace ([string]$state.validation_checkpoint.receipt) -RequireLeaf
        $checkpoint = Read-MorphospaceProtocolJson $checkpointPath
        if ([string]$checkpoint.unit_id -ceq $UnitId) { throw 'Validation-only scope narrowing rejects a same-unit recorded validation checkpoint.' }
    }

    $expected = $request.expected
    foreach ($binding in @(
        @('project canonical hash',[string]$expected.project_sha256,(Get-MorphospaceCanonicalJsonSha256 $project)),
        @('project raw hash',[string]$expected.project_raw_sha256,(Get-MorphospaceFileSha256 $projectPath)),
        @('repository-map raw hash',[string]$expected.repository_map_sha256,(Get-MorphospaceFileSha256 $mapPath))
    )) { if ([string]$binding[1] -cne [string]$binding[2]) { throw "Validation-only narrowing expected $($binding[0]) differs from live bytes." } }
    if ((Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $project)) -cne [string]$expected.project_raw_sha256) { throw 'Validation-only narrowing requires byte-canonical project.spec.json preservation.' }
    if ([string]$unit.source_composition.mode -cne 'exact-lock' -or [string]$unit.source_composition.lock_path -cne [string]$expected.source_composition_path) { throw 'Validation-only narrowing source-composition reference differs from the unit.' }
    $sourceLockPath = Resolve-MorphospaceWorkspacePath $workspace ([string]$expected.source_composition_path) -RequireLeaf
    if ((Get-MorphospaceFileSha256 $sourceLockPath) -cne [string]$expected.source_composition_sha256) { throw 'Validation-only narrowing source-composition raw hash differs.' }
    $sourceLockRaw = Get-Content -Raw -LiteralPath $sourceLockPath; $repoMapRaw = Get-Content -Raw -LiteralPath $mapPath
    if (-not (Test-Json -Json $sourceLockRaw -SchemaFile (Join-Path $repoRoot 'schemas\source-composition-lock.schema.json')) -or -not (Test-Json -Json $repoMapRaw -SchemaFile (Join-Path $repoRoot 'schemas\repository-map.schema.json'))) { throw 'Validation-only narrowing source lock or repository map violates its schema.' }
    $sourceLock = Read-MorphospaceProtocolJson $sourceLockPath; $repoMap = Read-MorphospaceProtocolJson $mapPath
    if ([string]$sourceLock.schema -cne 'rusty.morphospace.workflow.source_composition_lock.v1' -or [string]$sourceLock.project_id -cne [string]$request.project_id -or [string]$sourceLock.unit_id -cne $UnitId -or [string]$sourceLock.status -cne 'locked' -or [string]$sourceLock.fingerprint -cne (Get-MorphospaceSourceCompositionFingerprint -ProjectId ([string]$request.project_id) -UnitId $UnitId -Repositories @($sourceLock.repositories)) -or [string]$repoMap.schema -cne 'rusty.morphospace.workflow.repository_map.v1') { throw 'Validation-only narrowing source lock or repository map is not exact.' }
    $sourceObservations = @(Get-ValidationOnlySourceObservations -Map $repoMap -SourceLock $sourceLock)
    Assert-ValidationOnlyScopeTransition -Request $request -Project $project -SourceLock $sourceLock

    if ($hasIntent) {
        $intent = Read-MorphospaceProtocolJson $intentPath
        Assert-ValidationOnlyRecoveryIntent -Intent $intent -Request $request -Project $project -State $state -Unit $unit -Events $events -RequestHash $requestHash -RequestPath $requestPath -StatePath $statePath -UnitPath $unitPath -OutRelative $outRelative -EventId $eventId -TransactionId $transactionId -Timestamp $Timestamp -SourceLock $sourceLock
        if ([IO.File]::Exists($outAbsolute) -and (Get-MorphospaceFileSha256 $outAbsolute) -cne $requestHash) { throw 'Validation-only recovery artifact bytes differ from the authenticated request.' }
        $replayTimestamp = [string]$intent.event.timestamp
        if ($hasCompletion) {
            Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -ExpectedStatePath $stateRelative -ExpectedUnitPath $unitRelative -ExpectedEventsPath $eventsRelative -RequireTail | Out-Null
            return New-ValidationOnlyScopeResult -Request $request -Unit $unit -State $state -Timestamp $replayTimestamp -OutRelative $outRelative -RequestHash $requestHash -Executed $true -EventId $eventId
        }
        if (-not $Execute) { throw 'Interrupted NarrowValidationOnlyWriteScope requires -Execute recovery.' }
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        Assert-ValidationOnlySourceObservationsStable $sourceObservations
        foreach ($binding in @(
            @('project raw hash',[string]$expected.project_raw_sha256,(Get-MorphospaceFileSha256 $projectPath)),
            @('repository-map raw hash',[string]$expected.repository_map_sha256,(Get-MorphospaceFileSha256 $mapPath)),
            @('source-composition raw hash',[string]$expected.source_composition_sha256,(Get-MorphospaceFileSha256 $sourceLockPath)),
            @('request raw hash',$requestHash,(Get-MorphospaceFileSha256 $requestPath))
        )) { if ([string]$binding[1] -cne [string]$binding[2]) { throw "Validation-only recovery $($binding[0]) changed before repair." } }
        Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -Repair -FaultAfter $FaultAfter | Out-Null
        Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -ExpectedStatePath $stateRelative -ExpectedUnitPath $unitRelative -ExpectedEventsPath $eventsRelative -RequireTail | Out-Null
        return New-ValidationOnlyScopeResult -Request $request -Unit $unit -State $state -Timestamp $replayTimestamp -OutRelative $outRelative -RequestHash $requestHash -Executed $true -EventId $eventId
    }

    $ledgerModule = Get-Module MorphospaceTransitionLedger
    & $ledgerModule { param($candidateWorkspace,$candidateTransaction) Assert-MorphospaceNoOutstandingTransitionIntent $candidateWorkspace $candidateTransaction } $workspace $transactionId

    if ([IO.File]::Exists($outAbsolute)) { throw "Validation-only narrowing output must be the new transaction-owned path '$expectedOut'." }
    $tail = $events[-1]
    if ([string]$state.last_event_id -cne [string]$tail.event_id) { throw 'Workspace last_event_id does not match the physical event tail.' }
    foreach ($binding in @(
        @('state canonical hash',[string]$expected.state_sha256,(Get-MorphospaceCanonicalJsonSha256 $state)),
        @('state raw hash',[string]$expected.state_raw_sha256,(Get-MorphospaceFileSha256 $statePath)),
        @('unit canonical hash',[string]$expected.unit_sha256,(Get-MorphospaceCanonicalJsonSha256 $unit)),
        @('unit raw hash',[string]$expected.unit_raw_sha256,(Get-MorphospaceFileSha256 $unitPath)),
        @('event-ledger hash',[string]$expected.events_sha256,(Get-MorphospaceFileSha256 $eventsPath)),
        @('event tail',[string]$expected.event_tail_id,[string]$tail.event_id)
    )) { if ([string]$binding[1] -cne [string]$binding[2]) { throw "Validation-only narrowing expected $($binding[0]) differs from live bytes." } }
    if ([int64]$expected.events_length -ne [IO.FileInfo]::new($eventsPath).Length) { throw 'Validation-only narrowing expected event-ledger length differs from live bytes.' }
    $liveRows = @($unit.allowed_repositories); $beforeRows = @($request.before_allowed_repositories); $afterRows = @($request.after_allowed_repositories)
    if ((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{rows=$liveRows})) -cne (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{rows=$beforeRows}))) { throw 'Validation-only narrowing before scope differs from the live unit.' }
    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    if (-not (Test-MorphospaceStrictUtcTimestamp $Timestamp)) { throw 'Timestamp must be a strict UTC timestamp.' }
    $targetUnit = Copy-ValidationOnlyScopeValue $unit
    for ($i=0; $i -lt $targetUnit.allowed_repositories.Count; $i++) { $targetUnit.allowed_repositories[$i].allowed_paths = @($afterRows[$i].allowed_paths | ForEach-Object { [string]$_ }) }
    $targetState = Copy-ValidationOnlyScopeValue $state; $targetState.last_event_id = $eventId
    $event = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$tail.sequence+1;timestamp=$Timestamp;project_id=[string]$request.project_id;unit_id=$UnitId;event_type='state-transition';summary="Narrowed only the current validation-only unit's declared write paths while preserving repository identities and source bytes.";receipts=@($outRelative)}
    foreach ($entry in @([pscustomobject]@{l='target state';d=$targetState},[pscustomobject]@{l='target unit';d=$targetUnit},[pscustomobject]@{l='event';d=$event})) { Assert-ValidationOnlyScopeDocument $entry.l $entry.d $repoRoot }
    if ($Execute) {
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        Assert-ValidationOnlySourceObservationsStable $sourceObservations
        Assert-ValidationOnlyPreimageBytes -Expected $expected -ProjectPath $projectPath -StatePath $statePath -UnitPath $unitPath -EventsPath $eventsPath -MapPath $mapPath -SourceLockPath $sourceLockPath -RequestPath $requestPath -RequestSha256 $requestHash
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -StatePath $stateRelative -UnitPath $unitRelative -EventsPath $eventsRelative -TargetState $targetState -TargetUnit $targetUnit -Event $event -ExpectedPreStateSha256 ([string]$expected.state_sha256) -ExpectedPreStateRawSha256 ([string]$expected.state_raw_sha256) -ExpectedPreUnitSha256 ([string]$expected.unit_sha256) -ExpectedPreUnitRawSha256 ([string]$expected.unit_raw_sha256) -ExpectedEventTailId ([string]$expected.event_tail_id) -ExpectedEventsSha256 ([string]$expected.events_sha256) -ExpectedEventsLength ([int64]$expected.events_length) -AdditionalProjections @([pscustomobject]@{path=$projectRelative;expected_sha256=[string]$expected.project_sha256;expected_raw_sha256=[string]$expected.project_raw_sha256;document=$project}) -Artifacts @([pscustomobject]@{source_path=$requestPath;path=$outRelative;sha256=$requestHash}) -FaultAfter $FaultAfter | Out-Null
    }
    return New-ValidationOnlyScopeResult -Request $request -Unit $unit -State $state -Timestamp $Timestamp -OutRelative $outRelative -RequestHash $requestHash -Executed $Execute.IsPresent -EventId $eventId
}


Export-ModuleMember -Function Invoke-MorphospaceNarrowValidationOnlyWriteScope
