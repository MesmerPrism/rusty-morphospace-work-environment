Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force

$script:ValidatingCandidateCleanDirtyFingerprint = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

function Copy-ValidatingCandidateDocument {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 96 | ConvertFrom-Json -Depth 96 -DateKind String)
}

function Assert-ValidatingCandidateSchema {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Schema,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $Path) -SchemaFile (Join-Path $RepositoryRoot "schemas\$Schema"))) {
        throw $Message
    }
}

function Assert-ValidatingCandidateProtocolDocument {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$Label
    )
    $schema = switch ([string]$Document.schema) {
        'rusty.morphospace.workflow.project_spec.v1' { 'project-spec.schema.json' }
        'rusty.morphospace.workflow.project_spec.v2' { 'project-spec-v2.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v1' { 'workspace-state.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v2' { 'workspace-state-v2.schema.json' }
        'rusty.morphospace.workflow.iteration_unit.v1' { 'iteration-unit.schema.json' }
        'rusty.morphospace.workflow.feature_lock.v1' { 'feature-lock.schema.json' }
        'rusty.morphospace.workflow.feature_lock.v2' { 'feature-lock-v2.schema.json' }
        'rusty.morphospace.workflow.iteration_event.v1' { 'iteration-event.schema.json' }
        default { throw "Unsupported $Label schema '$([string]$Document.schema)'." }
    }
    Assert-ValidatingCandidateSchema $RepositoryRoot $Path $schema "$Label does not satisfy its repository-owned schema."
}

function Invoke-ValidatingCandidateGit {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Context,
        [switch]$AllowFailure
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git --no-optional-locks --no-pager --no-replace-objects -c core.pager=cat -C $Repository @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Validating-candidate rematerialization $Context failed: git $($Arguments -join ' ')"
    }
    return [pscustomobject]@{ code = [int]$code; lines = @($output | ForEach-Object { [string]$_ }) }
}

function Get-ValidatingCandidateGitScalar {
    param([string]$Repository,[string[]]$Arguments,[string]$Context)
    $observation = Invoke-ValidatingCandidateGit $Repository $Arguments $Context
    $value = (($observation.lines -join "`n").Trim()).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Validating-candidate rematerialization $Context returned no identity." }
    return $value
}

function Get-ValidatingCandidateMap {
    param([object[]]$Rows,[string]$Label)
    $result = @{}
    foreach ($row in @($Rows)) {
        $id = [string]$row.repo_id
        if ([string]::IsNullOrWhiteSpace($id) -or $result.ContainsKey($id)) { throw "$Label repeats or omits repository identity '$id'." }
        $result[$id] = $row
    }
    return $result
}

function Get-ValidatingCandidateRepositoryMap {
    param([string]$RepositoryRoot,[string]$Workspace,[string]$RelativePath)
    $path = Resolve-MorphospaceWorkspacePath $Workspace $RelativePath -RequireLeaf
    Assert-ValidatingCandidateSchema $RepositoryRoot $path 'repository-map.schema.json' 'Validating-candidate repository map is malformed.'
    $document = Read-MorphospaceProtocolJson $path
    $result = @{}
    foreach ($entry in @($document.repositories)) {
        $id = [string]$entry.repo_id
        if ([string]::IsNullOrWhiteSpace($id) -or $result.ContainsKey($id)) { throw "Validating-candidate repository map repeats or omits '$id'." }
        $root = [IO.Path]::GetFullPath([string]$entry.path)
        if (-not [IO.Directory]::Exists($root)) { throw "Validating-candidate mapped repository '$id' is absent." }
        $result[$id] = [pscustomobject]@{ repo_id=$id; path=$root; role=[string]$entry.role }
    }
    return [pscustomobject]@{ path=$path; document=$document; entries=$result }
}

function Get-ValidatingCandidateSourceComposition {
    param([string]$RepositoryRoot,[string]$Path,[string]$ProjectId,[string]$UnitId,[switch]$Target)
    $document = Read-MorphospaceProtocolJson $Path
    switch ([string]$document.schema) {
        'rusty.morphospace.workflow.source_composition_lock.v1' {
            Assert-ValidatingCandidateSchema $RepositoryRoot $Path 'source-composition-lock.schema.json' 'Source-composition lock is malformed.'
            if ([string]$document.project_id -cne $ProjectId -or [string]$document.unit_id -cne $UnitId) { throw 'Source-composition lock project or unit identity differs.' }
        }
        'rusty.morphospace.workflow.development_envelope_source_composition.v1' {
            if ($Target) { throw 'Rematerialization target must use source_composition_lock.v1.' }
            Assert-ValidatingCandidateSchema $RepositoryRoot $Path 'development-envelope-source-composition-v1.schema.json' 'Predecessor source composition is malformed.'
            if ([string]$document.project_id -cne $ProjectId) { throw 'Predecessor source-composition project identity differs.' }
        }
        default { throw "Unsupported source-composition schema '$([string]$document.schema)'." }
    }
    if ($Target) {
        $fingerprintDocument = [pscustomobject][ordered]@{ project_id=$ProjectId; unit_id=$UnitId; repositories=@($document.repositories) }
        if ([string]$document.fingerprint -cne (Get-MorphospaceCanonicalJsonSha256 $fingerprintDocument)) {
            throw 'Target source-composition fingerprint does not bind its exact project, unit, and repositories.'
        }
    }
    return $document
}

function Get-ValidatingCandidateEvents {
    param([string]$Path)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { throw 'Validating-candidate event ledger contains a blank record.' }
        try { $result.Add(($line | ConvertFrom-Json -Depth 96 -DateKind String)) | Out-Null }
        catch { throw 'Validating-candidate event ledger contains malformed JSON.' }
    }
    if ($result.Count -eq 0) { throw 'Validating-candidate rematerialization requires a non-empty event ledger.' }
    return @($result.ToArray())
}

function Assert-ValidatingCandidateEquivalent {
    param([object]$Expected,[object]$Actual,[string]$Message)
    if ((Get-MorphospaceCanonicalJsonSha256 $Expected) -cne (Get-MorphospaceCanonicalJsonSha256 $Actual)) { throw $Message }
}

function Assert-ValidatingCandidateRepositoryClosure {
    param(
        [object]$Candidate,
        [object]$PredecessorFreeze,
        [object]$PredecessorComposition,
        [object]$TargetComposition,
        [hashtable]$RepositoryMap
    )
    foreach ($id in @($TargetComposition.repositories | ForEach-Object { [string]$_.repo_id })) {
        if ($id -cmatch '(^|[-_.])qfm($|[-_.])|file-manager') { throw "QFM repository '$id' may not enter product source composition." }
    }

    $oldComposition = Get-ValidatingCandidateMap @($PredecessorComposition.repositories) 'Predecessor source composition'
    $newComposition = Get-ValidatingCandidateMap @($TargetComposition.repositories) 'Target source composition'
    $lineage = Get-ValidatingCandidateMap @($Candidate.lineage.repositories) 'Candidate lineage'
    $oldFinal = Get-ValidatingCandidateMap @($PredecessorFreeze.final_repositories) 'Predecessor freeze final repositories'
    $declaredOldFinal = Get-ValidatingCandidateMap @($Candidate.lineage.predecessor_final_repositories) 'Candidate predecessor final repositories'
    $newFinal = Get-ValidatingCandidateMap @($Candidate.final_repositories) 'Candidate final repositories'
    $oldChanged = Get-ValidatingCandidateMap @($PredecessorFreeze.changed_paths) 'Predecessor changed paths'
    $newChanged = Get-ValidatingCandidateMap @($Candidate.changed_paths) 'Candidate changed paths'
    $headProjections = Get-ValidatingCandidateMap @($Candidate.lineage.repository_head_projections) 'Candidate repository-head projections'

    $oldIds = @($oldComposition.Keys); [Array]::Sort($oldIds,[StringComparer]::Ordinal)
    $newIds = @($newComposition.Keys); [Array]::Sort($newIds,[StringComparer]::Ordinal)
    $lineageIds = @($lineage.Keys); [Array]::Sort($lineageIds,[StringComparer]::Ordinal)
    if (($oldIds -join '|') -cne ($newIds -join '|') -or ($oldIds -join '|') -cne ($lineageIds -join '|')) {
        throw 'Rematerialization may not add, remove, or substitute a product source-composition repository.'
    }
    Assert-ValidatingCandidateEquivalent @($PredecessorFreeze.final_repositories) @($Candidate.lineage.predecessor_final_repositories) 'Candidate predecessor-final-repository lineage differs from the immutable predecessor freeze.'
    Assert-ValidatingCandidateEquivalent @($PredecessorFreeze.changed_paths) @($Candidate.changed_paths) 'Rematerialization must retain the predecessor changed-path closure exactly.'
    if (($oldFinal.Count -ne $declaredOldFinal.Count) -or ($oldFinal.Count -ne $newFinal.Count) -or ($oldChanged.Count -ne $newChanged.Count) -or ($oldFinal.Count -ne $headProjections.Count)) {
        throw 'Rematerialization final-repository or changed-path repository sets differ from the predecessor freeze.'
    }

    foreach ($id in $oldIds) {
        if (-not $RepositoryMap.ContainsKey($id)) { throw "Rematerialization source repository '$id' is absent from the repository map." }
        $old = $oldComposition[$id]; $new = $newComposition[$id]; $route = $lineage[$id]; $mapped = $RepositoryMap[$id]
        $frozenCommit=if($oldFinal.ContainsKey($id)){[string]$oldFinal[$id].commit}else{[string]$old.commit}
        $frozenTree=if($oldFinal.ContainsKey($id)){[string]$oldFinal[$id].tree}else{[string]$old.tree}
        if ([string]$old.role -cne [string]$new.role -or [string]$new.role -cne [string]$route.role -or [string]$new.role -cne [string]$mapped.role) {
            throw "Rematerialization role differs for '$id'."
        }
        foreach ($binding in @(
            @{n='source-baseline commit';e=[string]$old.commit;a=[string]$route.source_baseline_commit},
            @{n='source-baseline tree';e=[string]$old.tree;a=[string]$route.source_baseline_tree},
            @{n='predecessor commit';e=$frozenCommit;a=[string]$route.predecessor_commit},
            @{n='predecessor tree';e=$frozenTree;a=[string]$route.predecessor_tree},
            @{n='target commit';e=[string]$new.commit;a=[string]$route.target_commit},
            @{n='target tree';e=[string]$new.tree;a=[string]$route.target_tree}
        )) { if ($binding.e -cne $binding.a) { throw "Rematerialization $($binding.n) lineage differs for '$id'." } }

        $head = Get-ValidatingCandidateGitScalar $mapped.path @('rev-parse','HEAD') "HEAD observation for '$id'"
        $tree = Get-ValidatingCandidateGitScalar $mapped.path @('rev-parse','HEAD^{tree}') "tree observation for '$id'"
        if ($head -cne [string]$new.commit -or $tree -cne [string]$new.tree) { throw "Rematerialization target repository '$id' is not at the exact staged commit/tree." }
        $status = Invoke-ValidatingCandidateGit $mapped.path @('status','--porcelain=v1','--untracked-files=all') "cleanliness observation for '$id'"
        if (@($status.lines).Count -ne 0) { throw "Rematerialization target repository '$id' is dirty." }
        $branchObservation=Invoke-ValidatingCandidateGit $mapped.path @('symbolic-ref','--quiet','--short','HEAD') "branch observation for '$id'" -AllowFailure
        $branch=if($branchObservation.code-eq0){($branchObservation.lines-join"`n").Trim()}else{$null}
        $remoteObservation=Invoke-ValidatingCandidateGit $mapped.path @('remote','get-url','origin') "remote observation for '$id'" -AllowFailure
        $remote=if($remoteObservation.code-eq0){($remoteObservation.lines-join"`n").Trim()}else{$null}
        if ([string]$new.branch -cne [string]$branch -or [string]$new.remote_url -cne [string]$remote -or [string]$new.materialization_path -cne (Split-Path -Leaf $mapped.path)) {
            throw "Rematerialization target repository '$id' branch, remote, or materialization identity differs."
        }
        $observedBaselineTree = Get-ValidatingCandidateGitScalar $mapped.path @('rev-parse',"$([string]$old.commit)^{tree}") "source-baseline tree-object observation for '$id'"
        $observedPredecessorTree = Get-ValidatingCandidateGitScalar $mapped.path @('rev-parse',"$frozenCommit^{tree}") "predecessor tree-object observation for '$id'"
        $observedNewTree = Get-ValidatingCandidateGitScalar $mapped.path @('rev-parse',"$([string]$new.commit)^{tree}") "target tree-object observation for '$id'"
        if ($observedBaselineTree -cne [string]$old.tree -or $observedPredecessorTree -cne $frozenTree -or $observedNewTree -cne [string]$new.tree) { throw "Rematerialization Git tree identity differs for '$id'." }
        $baselineAncestor = Invoke-ValidatingCandidateGit $mapped.path @('merge-base','--is-ancestor',[string]$old.commit,$frozenCommit) "source-baseline ancestry observation for '$id'" -AllowFailure
        if ($baselineAncestor.code -ne 0) { throw "Rematerialization frozen predecessor is not descended from its source baseline for '$id'." }
        $targetAncestor = Invoke-ValidatingCandidateGit $mapped.path @('merge-base','--is-ancestor',$frozenCommit,[string]$new.commit) "target ancestry observation for '$id'" -AllowFailure
        if ($targetAncestor.code -ne 0) { throw "Rematerialization target is not descended from its frozen predecessor for '$id'." }

        $expectedPaths = @()
        if ($oldChanged.ContainsKey($id)) { $expectedPaths = @($oldChanged[$id].paths | ForEach-Object { ConvertTo-MorphospaceProtocolRelativePath ([string]$_).TrimEnd('/') }) }
        [Array]::Sort($expectedPaths,[StringComparer]::Ordinal)
        $carried = @($route.carried_paths)
        $actualPaths = @($carried | ForEach-Object { ConvertTo-MorphospaceProtocolRelativePath ([string]$_.path).TrimEnd('/') })
        [Array]::Sort($actualPaths,[StringComparer]::Ordinal)
        if (($expectedPaths -join '|') -cne ($actualPaths -join '|')) { throw "Rematerialization carried-path closure differs for '$id'." }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($carry in $carried) {
            $path = ConvertTo-MorphospaceProtocolRelativePath ([string]$carry.path)
            if (-not $seen.Add($path)) { throw "Rematerialization repeats carried path '$id/$path'." }
            $oldObject = Get-ValidatingCandidateGitScalar $mapped.path @('rev-parse',"$frozenCommit`:$path") "predecessor carried-path observation for '$id/$path'"
            $newObject = Get-ValidatingCandidateGitScalar $mapped.path @('rev-parse',"$([string]$new.commit):$path") "target carried-path observation for '$id/$path'"
            $oldType = Get-ValidatingCandidateGitScalar $mapped.path @('cat-file','-t',$oldObject) "predecessor carried-path type observation for '$id/$path'"
            $newType = Get-ValidatingCandidateGitScalar $mapped.path @('cat-file','-t',$newObject) "target carried-path type observation for '$id/$path'"
            if ($oldType -cne 'blob' -or $newType -cne 'blob' -or $oldObject -cne [string]$carry.predecessor_blob -or $newObject -cne [string]$carry.target_blob -or $oldObject -cne $newObject) {
                throw "Rematerialization did not preserve the exact predecessor blob at '$id/$path'."
            }
        }
    }

    foreach ($id in @($oldFinal.Keys)) {
        if (-not $newFinal.ContainsKey($id) -or -not $oldChanged.ContainsKey($id) -or -not $newChanged.ContainsKey($id) -or -not $lineage.ContainsKey($id)) {
            throw "Rematerialization writable closure is incomplete for '$id'."
        }
        if ([string]$oldFinal[$id].commit -cne [string]$lineage[$id].predecessor_commit -or [string]$oldFinal[$id].tree -cne [string]$lineage[$id].predecessor_tree -or
            [string]$newFinal[$id].commit -cne [string]$lineage[$id].target_commit -or [string]$newFinal[$id].tree -cne [string]$lineage[$id].target_tree) {
            throw "Rematerialization final-repository lineage differs for '$id'."
        }
        if (-not $headProjections.ContainsKey($id)) { throw "Rematerialization repository-head projection is absent for '$id'." }
        $projection=$headProjections[$id];$targetCompositionRow=$newComposition[$id]
        if ([string]$projection.predecessor.head-cne[string]$oldFinal[$id].commit-or
            [string]$projection.predecessor.dirty_fingerprint-cne$script:ValidatingCandidateCleanDirtyFingerprint-or
            [string]$projection.target.head-cne[string]$newFinal[$id].commit-or
            [string]$projection.target.branch-cne[string]$targetCompositionRow.branch-or
            [string]$projection.target.dirty_fingerprint-cne$script:ValidatingCandidateCleanDirtyFingerprint) {
            throw "Rematerialization repository-head predecessor or clean target identity differs for '$id'."
        }
    }
}

function Get-ValidatingCandidateTargetDocuments {
    param([object]$Candidate,[object]$State,[object]$Unit,[string]$CandidateHash,[string]$CandidateOut,[string]$SourceOut,[string]$EventId)
    $targetUnit = Copy-ValidatingCandidateDocument $Unit
    $targetUnit.source_composition = [pscustomobject][ordered]@{ mode='exact-lock'; lock_path=$SourceOut; materialization_receipt=$null }
    $targetUnit.candidate_freeze = [pscustomobject][ordered]@{ freeze_id=[string]$Candidate.freeze_id; receipt_path=$CandidateOut; receipt_sha256=$CandidateHash }
    $targetState = Copy-ValidatingCandidateDocument $State
    $targetState.last_event_id = $EventId
    $targetState.normal_validation_selection = $null

    if (-not($targetState.PSObject.Properties.Name -contains 'repository_heads')) { throw 'Rematerialization requires workspace-state v2 repository-head projections.' }
    $headProjections=Get-ValidatingCandidateMap @($Candidate.lineage.repository_head_projections) 'Candidate repository-head projections'
    foreach($id in @($headProjections.Keys)){
        $matches=@($targetState.repository_heads|Where-Object{[string]$_.repo_id-ceq$id})
        if($matches.Count-ne1){throw "Workspace must contain exactly one predecessor repository-head row for '$id'."}
        $expectedPre=[pscustomobject][ordered]@{repo_id=$id;head=[string]$headProjections[$id].predecessor.head;branch=$headProjections[$id].predecessor.branch;dirty_fingerprint=$headProjections[$id].predecessor.dirty_fingerprint}
        Assert-ValidatingCandidateEquivalent $expectedPre $matches[0] "Workspace repository-head predecessor row differs for '$id'."
    }
    $targetHeads=[Collections.Generic.List[object]]::new()
    foreach($head in @($targetState.repository_heads)){
        $id=[string]$head.repo_id
        if($headProjections.ContainsKey($id)){$targetHeads.Add([pscustomobject][ordered]@{repo_id=$id;head=[string]$headProjections[$id].target.head;branch=$headProjections[$id].target.branch;dirty_fingerprint=$headProjections[$id].target.dirty_fingerprint})|Out-Null}
        else{$targetHeads.Add((Copy-ValidatingCandidateDocument $head))|Out-Null}
    }
    $targetState.repository_heads=@($targetHeads.ToArray())
    return [pscustomobject]@{ state=$targetState; unit=$targetUnit }
}

function Assert-ValidatingCandidatePreservation {
    param([object]$Candidate,[object]$OriginalState,[object]$OriginalUnit,[object]$TargetState,[object]$TargetUnit)
    if ([string]$OriginalUnit.status -cne 'validating' -or [string]$TargetUnit.status -cne 'validating') { throw 'Rematerialization must preserve validating status.' }
    $restoredUnit = Copy-ValidatingCandidateDocument $TargetUnit
    $restoredUnit.source_composition = Copy-ValidatingCandidateDocument $OriginalUnit.source_composition
    $restoredUnit.candidate_freeze = Copy-ValidatingCandidateDocument $OriginalUnit.candidate_freeze
    Assert-ValidatingCandidateEquivalent $OriginalUnit $restoredUnit 'Rematerialization would change a unit field outside source_composition and candidate_freeze.'

    $restoredState = Copy-ValidatingCandidateDocument $TargetState
    $restoredState.last_event_id = $OriginalState.last_event_id
    $restoredState.normal_validation_selection = Copy-ValidatingCandidateDocument $Candidate.lineage.invalidated_normal_validation_selection
    $headProjections=Get-ValidatingCandidateMap @($Candidate.lineage.repository_head_projections) 'Candidate repository-head projections'
    foreach($head in @($restoredState.repository_heads)){if($headProjections.ContainsKey([string]$head.repo_id)){$projection=$headProjections[[string]$head.repo_id].predecessor;$head.head=[string]$projection.head;$head.branch=$projection.branch;$head.dirty_fingerprint=$projection.dirty_fingerprint}}
    Assert-ValidatingCandidateEquivalent $OriginalState $restoredState 'Rematerialization would change workspace state outside last_event_id, stale selector removal, and exact predecessor repository-head projection.'
}

function Assert-ValidatingCandidateReplayIntent {
    param(
        [object]$Candidate,[object]$Intent,[string]$TransactionId,[string]$EventId,[string]$CandidateHash,[string]$CandidateOut,
        [string]$SourceHash,[string]$SourceOut,[string]$UnitRelative,[string]$ProjectHash,[string]$FeatureHash
    )
    if ([string]$Intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v6' -or [string]$Intent.transaction_id -cne $TransactionId -or
        [string]$Intent.event.event_id -cne $EventId -or [string]$Intent.event.project_id -cne [string]$Candidate.project_id -or [string]$Intent.event.unit_id -cne [string]$Candidate.unit_id) {
        throw 'Rematerialization replay intent identity is conflicting.'
    }
    if([string]$Intent.event.schema-cne'rusty.morphospace.workflow.iteration_event.v1'-or[string]$Intent.event.event_type-cne'state-transition'-or
       [string]$Intent.event.summary-cne'Rematerialized only the exact source and candidate-freeze bindings of the current validating unit while invalidating its stale selector.'){
        throw 'Rematerialization replay event contract is conflicting.'
    }
    foreach ($binding in @(
        @{e=[string]$Candidate.expected.state_sha256;a=[string]$Intent.pre.state.sha256;n='state preimage'},
        @{e=[string]$Candidate.expected.state_raw_sha256;a=[string]$Intent.pre_state_raw.sha256;n='raw state preimage'},
        @{e='workspace.state.json';a=[string]$Intent.pre_state_raw.path;n='raw state path'},
        @{e=[string]$Candidate.expected.unit_sha256;a=[string]$Intent.pre.unit.sha256;n='unit preimage'},
        @{e=[string]$Candidate.expected.unit_raw_sha256;a=[string]$Intent.pre_unit_raw.sha256;n='raw unit preimage'},
        @{e=$UnitRelative;a=[string]$Intent.pre_unit_raw.path;n='raw unit path'},
        @{e=[string]$Candidate.expected.events_sha256;a=[string]$Intent.expected.events_sha256;n='event bytes'},
        @{e=[string]$Candidate.expected.event_tail_id;a=[string]$Intent.expected.event_tail_id;n='event tail'}
    )) { if ($binding.e -cne $binding.a) { throw "Rematerialization replay $($binding.n) is conflicting." } }
    if ([int64]$Candidate.expected.events_length -ne [int64]$Intent.expected.events_length) { throw 'Rematerialization replay event length is conflicting.' }
    $artifacts = @($Intent.artifacts)
    $receipts = @($Intent.event.receipts)
    if ($artifacts.Count -ne 2 -or $receipts.Count -ne 2) { throw 'Rematerialization replay must own exactly two artifacts and receipts.' }
    $expectedArtifacts = @([pscustomobject]@{path=$CandidateOut;sha256=$CandidateHash},[pscustomobject]@{path=$SourceOut;sha256=$SourceHash})
    [Array]::Sort($expectedArtifacts,[Collections.Generic.Comparer[object]]::Create({param($a,$b)[StringComparer]::Ordinal.Compare([string]$a.path,[string]$b.path)}))
    for ($index=0; $index -lt 2; $index++) {
        if ([string]$artifacts[$index].path -cne [string]$expectedArtifacts[$index].path -or [string]$artifacts[$index].sha256 -cne [string]$expectedArtifacts[$index].sha256 -or [string]$receipts[$index] -cne [string]$expectedArtifacts[$index].path) {
            throw 'Rematerialization replay artifact/receipt binding is conflicting.'
        }
    }
    $projections = @($Intent.additional_projections)
    if ($projections.Count -ne 2 -or [string]$projections[0].path -cne 'feature.lock.json' -or [string]$projections[0].pre_sha256 -cne $FeatureHash -or [string]$projections[0].pre_raw_sha256 -cne [string]$Candidate.expected.feature_lock_raw_sha256 -or [string]$projections[0].target_sha256 -cne $FeatureHash -or
        [string]$projections[1].path -cne 'project.spec.json' -or [string]$projections[1].pre_sha256 -cne $ProjectHash -or [string]$projections[1].pre_raw_sha256 -cne [string]$Candidate.expected.project_raw_sha256 -or [string]$projections[1].target_sha256 -cne $ProjectHash) {
        throw 'Rematerialization replay additional-projection binding is conflicting.'
    }
    $targetUnit = $Intent.target.unit.document; $targetState = $Intent.target.state.document
    if ([string]$targetUnit.status -cne 'validating' -or [string]$targetUnit.candidate_freeze.freeze_id -cne [string]$Candidate.freeze_id -or
        [string]$targetUnit.candidate_freeze.receipt_path -cne $CandidateOut -or [string]$targetUnit.candidate_freeze.receipt_sha256 -cne $CandidateHash -or
        [string]$targetUnit.source_composition.mode -cne 'exact-lock' -or [string]$targetUnit.source_composition.lock_path -cne $SourceOut -or $null -ne $targetUnit.source_composition.materialization_receipt -or
        [string]$targetState.last_event_id -cne $EventId -or $null -ne $targetState.normal_validation_selection) {
        throw 'Rematerialization replay target projection is conflicting.'
    }
    $restoredUnit = Copy-ValidatingCandidateDocument $targetUnit
    $restoredUnit.candidate_freeze = Copy-ValidatingCandidateDocument $Candidate.lineage.predecessor_freeze
    $restoredUnit.source_composition = [pscustomobject][ordered]@{mode='exact-lock';lock_path=[string]$Candidate.lineage.predecessor_source_composition.path;materialization_receipt=$null}
    if ((Get-MorphospaceCanonicalJsonSha256 $restoredUnit) -cne [string]$Candidate.expected.unit_sha256) { throw 'Rematerialization replay target unit does not preserve its exact preimage.' }
    $restoredState = Copy-ValidatingCandidateDocument $targetState
    $restoredState.last_event_id = [string]$Candidate.expected.event_tail_id
    $restoredState.normal_validation_selection = Copy-ValidatingCandidateDocument $Candidate.lineage.invalidated_normal_validation_selection
    $headProjections=Get-ValidatingCandidateMap @($Candidate.lineage.repository_head_projections) 'Candidate repository-head projections'
    foreach($head in @($restoredState.repository_heads)){if($headProjections.ContainsKey([string]$head.repo_id)){$projection=$headProjections[[string]$head.repo_id].predecessor;$head.head=[string]$projection.head;$head.branch=$projection.branch;$head.dirty_fingerprint=$projection.dirty_fingerprint}}
    if ((Get-MorphospaceCanonicalJsonSha256 $restoredState) -cne [string]$Candidate.expected.state_sha256) { throw 'Rematerialization replay target state does not preserve its exact preimage.' }
}

function New-ValidatingCandidateAutomationReceipt {
    param([object]$Candidate,[string]$Timestamp,[bool]$Executed,[string]$Transition,[string]$CandidateOut,[string]$CandidateHash,[AllowNull()][string]$EventId)
    return [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2'; project_id=[string]$Candidate.project_id; unit_id=[string]$Candidate.unit_id
        action='RematerializeValidatingCandidate'; timestamp=$Timestamp; executed=$Executed; transition=$Transition
        status_before='validating'; status_after='validating'; current_unit_before=[string]$Candidate.unit_id; current_unit_after=[string]$Candidate.unit_id
        preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt=[pscustomobject][ordered]@{path=$CandidateOut;sha256=$CandidateHash}; event_id=$EventId
    }
}

function Invoke-MorphospaceRematerializeValidatingCandidate {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$CandidateFreeze,
        [Parameter(Mandatory)][string]$SourceCompositionLock,
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedCandidateFreezeSha256='',
        [string]$Timestamp='',
        [scriptblock]$BeforeTransitionHook,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none',
        [switch]$Execute
    )
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    $workspace = (Resolve-Path $WorkspaceRoot).Path
    $candidateInput = (Resolve-Path $CandidateFreeze).Path
    $sourceInput = (Resolve-Path $SourceCompositionLock).Path
    Assert-ValidatingCandidateSchema $repositoryRoot $candidateInput 'candidate-freeze-v2.schema.json' 'Candidate-freeze v2 input does not satisfy its closed schema.'
    Assert-ValidatingCandidateSchema $repositoryRoot $sourceInput 'source-composition-lock.schema.json' 'Target source-composition input does not satisfy its closed schema.'
    $candidate = Read-MorphospaceProtocolJson $candidateInput
    $candidateHash = Get-MorphospaceFileSha256 $candidateInput
    $sourceHash = Get-MorphospaceFileSha256 $sourceInput
    if ([string]$candidate.unit_id -cne $UnitId) { throw 'Candidate-freeze v2 unit identity differs from UnitId.' }
    if ($ExpectedCandidateFreezeSha256 -and $ExpectedCandidateFreezeSha256 -cne $candidateHash) { throw 'Expected candidate-freeze v2 hash does not match its exact input.' }
    if ($Execute -and -not $ExpectedCandidateFreezeSha256) { throw 'Executed rematerialization requires ExpectedCandidateFreezeSha256 from its dry run.' }
    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    if (-not (Test-MorphospaceStrictUtcTimestamp $Timestamp)) { throw 'Rematerialization timestamp must be strict UTC.' }

    $candidateOut = "receipts/$([string]$candidate.freeze_id).json"
    $sourceOut = [string]$candidate.source_composition.path
    $expectedSourceOut = "source-compositions/$([string](Read-MorphospaceProtocolJson $sourceInput).lock_id).lock.json"
    if ($sourceOut -cne $expectedSourceOut -or [string]$candidate.lineage.target_source_composition.path -cne $sourceOut -or
        [string]$candidate.source_composition.sha256 -cne $sourceHash -or [string]$candidate.lineage.target_source_composition.sha256 -cne $sourceHash) {
        throw 'Candidate-freeze v2 target source-composition path/hash is not exact.'
    }
    if ([IO.Path]::GetFullPath($OutPath) -cne (Resolve-MorphospaceWorkspacePath $workspace $candidateOut)) { throw "Rematerialization output must be '$candidateOut'." }
    if ([IO.Path]::GetFullPath($candidateInput) -ceq [IO.Path]::GetFullPath($OutPath) -or [IO.Path]::GetFullPath($sourceInput) -ceq (Resolve-MorphospaceWorkspacePath $workspace $sourceOut)) {
        throw 'Rematerialization inputs and transaction-owned outputs must be distinct.'
    }
    Assert-MorphospaceNoReparseAncestor $workspace (Resolve-MorphospaceWorkspacePath $workspace $candidateOut)
    Assert-MorphospaceNoReparseAncestor $workspace (Resolve-MorphospaceWorkspacePath $workspace $sourceOut)

    $eventId = "$([string]$candidate.lineage.rematerialization_id)-recorded"
    if($eventId.Length-gt128-or$eventId-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){throw 'Rematerialization derived event identity is invalid.'}
    $transactionId = "$eventId-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $intentPath = Resolve-MorphospaceWorkspacePath $workspace $intentRelative
    $projectRelative='project.spec.json'; $featureRelative='feature.lock.json'; $stateRelative='workspace.state.json'; $unitRelative="iteration-units/$UnitId.json"; $eventsRelative='iteration-events.jsonl'
    $projectPath=Resolve-MorphospaceWorkspacePath $workspace $projectRelative -RequireLeaf; $featurePath=Resolve-MorphospaceWorkspacePath $workspace $featureRelative -RequireLeaf
    $statePath=Resolve-MorphospaceWorkspacePath $workspace $stateRelative -RequireLeaf; $unitPath=Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf; $eventsPath=Resolve-MorphospaceWorkspacePath $workspace $eventsRelative -RequireLeaf
    $project=Read-MorphospaceProtocolJson $projectPath; $feature=Read-MorphospaceProtocolJson $featurePath
    $projectHash=Get-MorphospaceCanonicalJsonSha256 $project; $featureHash=Get-MorphospaceCanonicalJsonSha256 $feature
    foreach ($check in @(
        @{n='project canonical';e=[string]$candidate.expected.project_sha256;a=$projectHash}, @{n='project raw';e=[string]$candidate.expected.project_raw_sha256;a=(Get-MorphospaceFileSha256 $projectPath)},
        @{n='feature-lock canonical';e=[string]$candidate.expected.feature_lock_sha256;a=$featureHash}, @{n='feature-lock raw';e=[string]$candidate.expected.feature_lock_raw_sha256;a=(Get-MorphospaceFileSha256 $featurePath)}
    )) { if ($check.e -cne $check.a) { throw "Rematerialization stale $($check.n) CAS." } }
    if ([int]$candidate.feature_lock.revision -ne [int]$feature.revision -or [string]$candidate.feature_lock.sha256 -cne $featureHash) { throw 'Candidate-freeze v2 feature-lock closure differs from the live lock.' }

    $repoMap = Get-ValidatingCandidateRepositoryMap $repositoryRoot $workspace ([string]$candidate.expected.repository_map_path)
    if ([IO.Path]::GetFullPath($RepoMapPath) -cne $repoMap.path) { throw 'RepoMapPath differs from the candidate-bound repository map.' }
    if ((Get-MorphospaceFileSha256 $repoMap.path) -cne [string]$candidate.expected.repository_map_sha256 -or (Get-MorphospaceCanonicalJsonSha256 $repoMap.document) -cne [string]$candidate.expected.repository_map_canonical_sha256) {
        throw 'Rematerialization stale repository-map raw or canonical CAS.'
    }
    $targetComposition = Get-ValidatingCandidateSourceComposition $repositoryRoot $sourceInput ([string]$candidate.project_id) $UnitId -Target

    $predecessorFreezePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.lineage.predecessor_freeze.receipt_path) -RequireLeaf
    if ((Get-MorphospaceFileSha256 $predecessorFreezePath) -cne [string]$candidate.lineage.predecessor_freeze.receipt_sha256) { throw 'Predecessor candidate-freeze bytes drifted.' }
    Assert-ValidatingCandidateSchema $repositoryRoot $predecessorFreezePath 'candidate-freeze-v1.schema.json' 'Predecessor candidate freeze is malformed.'
    $predecessorFreeze=Read-MorphospaceProtocolJson $predecessorFreezePath
    if ([string]$predecessorFreeze.freeze_id -cne [string]$candidate.lineage.predecessor_freeze.freeze_id -or [string]$predecessorFreeze.project_id -cne [string]$candidate.project_id -or [string]$predecessorFreeze.unit_id -cne $UnitId) { throw 'Predecessor candidate-freeze identity differs.' }
    $predecessorSourcePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.lineage.predecessor_source_composition.path) -RequireLeaf
    if ((Get-MorphospaceFileSha256 $predecessorSourcePath) -cne [string]$candidate.lineage.predecessor_source_composition.sha256) { throw 'Predecessor source-composition bytes drifted.' }
    $predecessorComposition=Get-ValidatingCandidateSourceComposition $repositoryRoot $predecessorSourcePath ([string]$candidate.project_id) $UnitId
    Assert-ValidatingCandidateRepositoryClosure $candidate $predecessorFreeze $predecessorComposition $targetComposition $repoMap.entries

    if ([IO.File]::Exists($intentPath)) {
        $intent = Read-MorphospaceProtocolJson $intentPath
        Assert-ValidatingCandidateReplayIntent $candidate $intent $transactionId $eventId $candidateHash $candidateOut $sourceHash $sourceOut $unitRelative $projectHash $featureHash
        if ($Execute) {
            [void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -Repair -FaultAfter $FaultAfter)
            [void](Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -ExpectedStatePath $stateRelative -ExpectedUnitPath $unitRelative -ExpectedEventsPath $eventsRelative -RequireTail)
            if (-not (Test-MorphospaceRematerializedCandidate -WorkspaceRoot $workspace -Unit (Read-MorphospaceProtocolJson $unitPath))) { throw 'Rematerialization replay verifier did not accept the exact committed candidate.' }
        }
        return New-ValidatingCandidateAutomationReceipt $candidate $Timestamp $Execute.IsPresent 'validating-candidate-already-rematerialized' $candidateOut $candidateHash $(if($Execute){$eventId}else{$null})
    }

    $state=Read-MorphospaceProtocolJson $statePath; $unit=Read-MorphospaceProtocolJson $unitPath; $events=@(Get-ValidatingCandidateEvents $eventsPath); $tail=$events[-1]
    Assert-ValidatingCandidateProtocolDocument $repositoryRoot $projectPath $project 'project'
    Assert-ValidatingCandidateProtocolDocument $repositoryRoot $featurePath $feature 'feature lock'
    Assert-ValidatingCandidateProtocolDocument $repositoryRoot $statePath $state 'workspace state'
    Assert-ValidatingCandidateProtocolDocument $repositoryRoot $unitPath $unit 'iteration unit'
    if ([string]$candidate.project_id -cne [string]$project.project_id -or [string]$state.project_id -cne [string]$project.project_id -or [string]$unit.project_id -cne [string]$project.project_id -or
        [string]$unit.unit_id -cne $UnitId -or [string]$state.current_unit -cne $UnitId -or [string]$unit.status -cne 'validating') {
        throw 'Rematerialization requires the exact current validating unit.'
    }
    if ($null -eq $state.normal_validation_selection) { throw 'Rematerialization requires the complete stale normal-validation selector binding.' }
    if ($null -ne $state.pending_push_bundle) { throw 'Rematerialization rejects a current pending-publication bundle.' }
    if ($null -ne $state.validation_checkpoint -and [string]$state.validation_checkpoint.result -ceq 'pass') { throw 'Rematerialization rejects an extant passing validation checkpoint.' }
    Assert-ValidatingCandidateEquivalent $candidate.lineage.invalidated_normal_validation_selection $state.normal_validation_selection 'Candidate invalidated selector differs from the complete live selector binding.'
    if (-not ($unit.PSObject.Properties.Name -contains 'candidate_freeze') -or -not ($unit.PSObject.Properties.Name -contains 'source_composition') -or [string]$unit.source_composition.mode -cne 'exact-lock' -or $null -ne $unit.source_composition.materialization_receipt) {
        throw 'Rematerialization requires an exact-lock validating candidate with a candidate-freeze marker.'
    }
    Assert-ValidatingCandidateEquivalent $candidate.lineage.predecessor_freeze $unit.candidate_freeze 'Candidate predecessor-freeze lineage differs from the live unit marker.'
    if ([string]$unit.source_composition.lock_path -cne [string]$candidate.lineage.predecessor_source_composition.path) { throw 'Candidate predecessor source-composition path differs from the live unit.' }

    foreach ($property in @('changed_paths','instruction_surfaces','feature_lock','effects','permissions','device_use','test_matrix','cleanup_evidence')) {
        Assert-ValidatingCandidateEquivalent $predecessorFreeze.$property $candidate.$property "Candidate-freeze v2 changed predecessor semantic field '$property'."
    }
    if ([string]$predecessorFreeze.cleanliness_policy -cne [string]$candidate.cleanliness_policy) { throw 'Candidate-freeze v2 cleanliness policy differs from its predecessor.' }

    if ((Get-MorphospaceFileSha256 $predecessorSourcePath) -cne [string]$candidate.lineage.predecessor_source_composition.sha256 -or
        [string]$candidate.lineage.predecessor_source_composition.path -cne [string]$candidate.expected.source_composition_path -or
        [string]$candidate.lineage.predecessor_source_composition.sha256 -cne [string]$candidate.expected.source_composition_sha256 -or
        [string]$predecessorFreeze.expected.source_composition_path -cne [string]$candidate.expected.source_composition_path -or
        [string]$predecessorFreeze.expected.source_composition_sha256 -cne [string]$candidate.expected.source_composition_sha256) { throw 'Predecessor source-composition bytes or freeze binding drifted.' }

    foreach ($check in @(
        @{n='state canonical';e=[string]$candidate.expected.state_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $state)}, @{n='state raw';e=[string]$candidate.expected.state_raw_sha256;a=(Get-MorphospaceFileSha256 $statePath)},
        @{n='unit canonical';e=[string]$candidate.expected.unit_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $unit)}, @{n='unit raw';e=[string]$candidate.expected.unit_raw_sha256;a=(Get-MorphospaceFileSha256 $unitPath)},
        @{n='events';e=[string]$candidate.expected.events_sha256;a=(Get-MorphospaceFileSha256 $eventsPath)}, @{n='event tail';e=[string]$candidate.expected.event_tail_id;a=[string]$tail.event_id}
    )) { if ($check.e -cne $check.a) { throw "Rematerialization stale $($check.n) CAS." } }
    if ([int64]$candidate.expected.events_length -ne [IO.FileInfo]::new($eventsPath).Length -or [string]$state.last_event_id -cne [string]$tail.event_id) { throw 'Rematerialization stale event length or state-tail binding.' }

    foreach ($target in @($candidateOut,$sourceOut,"receipts/transactions/$transactionId.intent.json","receipts/transactions/$transactionId.completion.json")) {
        $absolute=Resolve-MorphospaceWorkspacePath $workspace $target
        if ([IO.File]::Exists($absolute) -or [IO.Directory]::Exists($absolute)) { throw "Rematerialization output is already occupied: $target" }
    }
    $targets=Get-ValidatingCandidateTargetDocuments $candidate $state $unit $candidateHash $candidateOut $sourceOut $eventId
    Assert-ValidatingCandidatePreservation $candidate $state $unit $targets.state $targets.unit
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$tail.sequence+1;timestamp=$Timestamp;project_id=[string]$candidate.project_id;unit_id=$UnitId;event_type='state-transition';summary='Rematerialized only the exact source and candidate-freeze bindings of the current validating unit while invalidating its stale selector.';receipts=@()}
    $artifactRows=@([pscustomobject]@{source_path=$candidateInput;path=$candidateOut;sha256=$candidateHash},[pscustomobject]@{source_path=$sourceInput;path=$sourceOut;sha256=$sourceHash})
    [Array]::Sort($artifactRows,[Collections.Generic.Comparer[object]]::Create({param($a,$b)[StringComparer]::Ordinal.Compare([string]$a.path,[string]$b.path)}))
    $event.receipts=@($artifactRows|ForEach-Object{[string]$_.path})

    if ($Execute) {
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -StatePath $stateRelative -UnitPath $unitRelative -EventsPath $eventsRelative `
            -TargetState $targets.state -TargetUnit $targets.unit -Event $event -ExpectedStateSha256 ([string]$candidate.expected.state_sha256) -ExpectedUnitSha256 ([string]$candidate.expected.unit_sha256) `
            -ExpectedPreStateRawSha256 ([string]$candidate.expected.state_raw_sha256) -ExpectedPreUnitRawSha256 ([string]$candidate.expected.unit_raw_sha256) -ExpectedEventTailId ([string]$candidate.expected.event_tail_id) -ExpectedEventsSha256 ([string]$candidate.expected.events_sha256) -ExpectedEventsLength ([int64]$candidate.expected.events_length) `
            -AdditionalProjections @([pscustomobject]@{path=$featureRelative;expected_sha256=$featureHash;expected_raw_sha256=[string]$candidate.expected.feature_lock_raw_sha256;document=$feature},[pscustomobject]@{path=$projectRelative;expected_sha256=$projectHash;expected_raw_sha256=[string]$candidate.expected.project_raw_sha256;document=$project}) -Artifacts $artifactRows -FaultAfter $FaultAfter | Out-Null
    }
    return New-ValidatingCandidateAutomationReceipt $candidate $Timestamp $Execute.IsPresent 'validating-candidate-rematerialized' $candidateOut $candidateHash $(if($Execute){$eventId}else{$null})
}

function Test-MorphospaceRematerializedCandidate {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$Unit
    )
    $repositoryRoot=Split-Path $PSScriptRoot -Parent; $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    if (-not ($Unit.PSObject.Properties.Name -contains 'candidate_freeze')) { throw 'Rematerialized candidate lacks its candidate-freeze marker.' }
    $marker=$Unit.candidate_freeze; $candidatePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$marker.receipt_path) -RequireLeaf
    if ((Get-MorphospaceFileSha256 $candidatePath) -cne [string]$marker.receipt_sha256) { throw 'Rematerialized candidate-freeze receipt hash drifted.' }
    Assert-ValidatingCandidateSchema $repositoryRoot $candidatePath 'candidate-freeze-v2.schema.json' 'Rematerialized candidate-freeze receipt is malformed.'
    $candidate=Read-MorphospaceProtocolJson $candidatePath; $candidateHash=Get-MorphospaceFileSha256 $candidatePath
    if ([string]$candidate.freeze_id -cne [string]$marker.freeze_id -or [string]$candidate.unit_id -cne [string]$Unit.unit_id) { throw 'Rematerialized candidate-freeze identity differs from its unit marker.' }
    $candidateOut="receipts/$([string]$candidate.freeze_id).json"; if ([string]$marker.receipt_path -cne $candidateOut) { throw 'Rematerialized candidate-freeze receipt path is noncanonical.' }
    $sourceOut=[string]$candidate.source_composition.path; $sourcePath=Resolve-MorphospaceWorkspacePath $workspace $sourceOut -RequireLeaf
    $sourceHash=Get-MorphospaceFileSha256 $sourcePath
    if ($sourceHash -cne [string]$candidate.source_composition.sha256 -or $sourceHash -cne [string]$candidate.lineage.target_source_composition.sha256 -or [string]$candidate.lineage.target_source_composition.path -cne $sourceOut) { throw 'Rematerialized target source-composition binding drifted.' }
    $targetComposition=Get-ValidatingCandidateSourceComposition $repositoryRoot $sourcePath ([string]$candidate.project_id) ([string]$candidate.unit_id) -Target
    $expectedSourceOut="source-compositions/$([string]$targetComposition.lock_id).lock.json"; if ($sourceOut -cne $expectedSourceOut) { throw 'Rematerialized target source-composition path is noncanonical.' }

    $projectPath=Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf; $featurePath=Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf
    $statePath=Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf; $unitRelative="iteration-units/$([string]$candidate.unit_id).json"; $unitPath=Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf
    $eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $project=Read-MorphospaceProtocolJson $projectPath; $feature=Read-MorphospaceProtocolJson $featurePath; $state=Read-MorphospaceProtocolJson $statePath; $liveUnit=Read-MorphospaceProtocolJson $unitPath
    Assert-ValidatingCandidateProtocolDocument $repositoryRoot $projectPath $project 'project'; Assert-ValidatingCandidateProtocolDocument $repositoryRoot $featurePath $feature 'feature lock'
    Assert-ValidatingCandidateProtocolDocument $repositoryRoot $statePath $state 'workspace state'; Assert-ValidatingCandidateProtocolDocument $repositoryRoot $unitPath $liveUnit 'iteration unit'
    if ([string]$project.project_id -cne [string]$candidate.project_id -or [string]$state.project_id -cne [string]$candidate.project_id -or [string]$liveUnit.project_id -cne [string]$candidate.project_id -or
        [string]$state.current_unit -cne [string]$candidate.unit_id -or [string]$liveUnit.unit_id -cne [string]$candidate.unit_id -or [string]$liveUnit.status -cne 'validating') { throw 'Rematerialized candidate no longer projects the exact current validating unit.' }
    Assert-ValidatingCandidateEquivalent $liveUnit $Unit 'Rematerialized candidate verifier input differs from the live unit bytes.'
    if ($null -ne $state.normal_validation_selection) { throw 'Rematerialized candidate retains a stale normal-validation selector.' }
    if ([string]$liveUnit.source_composition.mode -cne 'exact-lock' -or [string]$liveUnit.source_composition.lock_path -cne $sourceOut -or $null -ne $liveUnit.source_composition.materialization_receipt) { throw 'Rematerialized candidate unit source-composition marker drifted.' }
    Assert-ValidatingCandidateEquivalent $liveUnit.candidate_freeze ([pscustomobject][ordered]@{freeze_id=[string]$candidate.freeze_id;receipt_path=$candidateOut;receipt_sha256=$candidateHash}) 'Rematerialized candidate unit marker drifted.'
    foreach($check in @(
        @{n='project canonical';e=[string]$candidate.expected.project_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $project)}, @{n='project raw';e=[string]$candidate.expected.project_raw_sha256;a=(Get-MorphospaceFileSha256 $projectPath)},
        @{n='feature canonical';e=[string]$candidate.expected.feature_lock_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $feature)}, @{n='feature raw';e=[string]$candidate.expected.feature_lock_raw_sha256;a=(Get-MorphospaceFileSha256 $featurePath)}
    )) { if ($check.e -cne $check.a) { throw "Rematerialized candidate $($check.n) binding drifted." } }
    $repoMap=Get-ValidatingCandidateRepositoryMap $repositoryRoot $workspace ([string]$candidate.expected.repository_map_path)
    if ((Get-MorphospaceFileSha256 $repoMap.path) -cne [string]$candidate.expected.repository_map_sha256 -or (Get-MorphospaceCanonicalJsonSha256 $repoMap.document) -cne [string]$candidate.expected.repository_map_canonical_sha256) { throw 'Rematerialized candidate repository-map binding drifted.' }
    $oldFreezePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.lineage.predecessor_freeze.receipt_path) -RequireLeaf
    if ((Get-MorphospaceFileSha256 $oldFreezePath) -cne [string]$candidate.lineage.predecessor_freeze.receipt_sha256) { throw 'Rematerialized predecessor candidate-freeze bytes drifted.' }
    Assert-ValidatingCandidateSchema $repositoryRoot $oldFreezePath 'candidate-freeze-v1.schema.json' 'Rematerialized predecessor candidate freeze is malformed.'
    $oldFreeze=Read-MorphospaceProtocolJson $oldFreezePath
    $oldSourcePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.lineage.predecessor_source_composition.path) -RequireLeaf
    if ((Get-MorphospaceFileSha256 $oldSourcePath) -cne [string]$candidate.lineage.predecessor_source_composition.sha256) { throw 'Rematerialized predecessor source-composition bytes drifted.' }
    $oldComposition=Get-ValidatingCandidateSourceComposition $repositoryRoot $oldSourcePath ([string]$candidate.project_id) ([string]$candidate.unit_id)
    Assert-ValidatingCandidateRepositoryClosure $candidate $oldFreeze $oldComposition $targetComposition $repoMap.entries

    $eventId="$([string]$candidate.lineage.rematerialization_id)-recorded"; $transactionId="$eventId-transition"
    $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.intent.json" -RequireLeaf
    $intent=Read-MorphospaceProtocolJson $intentPath; $projectHash=Get-MorphospaceCanonicalJsonSha256 $project; $featureHash=Get-MorphospaceCanonicalJsonSha256 $feature
    Assert-ValidatingCandidateReplayIntent $candidate $intent $transactionId $eventId $candidateHash $candidateOut $sourceHash $sourceOut $unitRelative $projectHash $featureHash
    [void](Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $unitRelative -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail)
    if ((Get-MorphospaceCanonicalJsonSha256 $state) -cne [string]$intent.target.state.sha256 -or (Get-MorphospaceCanonicalJsonSha256 $liveUnit) -cne [string]$intent.target.unit.sha256) { throw 'Rematerialized candidate live state/unit differ from their committed targets.' }
    $events=@(Get-ValidatingCandidateEvents $eventsPath); $tail=$events[-1]
    if ([string]$tail.event_id -cne $eventId -or [string]$state.last_event_id -cne $eventId -or @($tail.receipts).Count -ne 2 -or
        [string]$tail.receipts[0] -cne [string]@($intent.artifacts)[0].path -or [string]$tail.receipts[1] -cne [string]@($intent.artifacts)[1].path) { throw 'Rematerialized candidate event tail or receipt binding drifted.' }
    return $true
}

Export-ModuleMember -Function Invoke-MorphospaceRematerializeValidatingCandidate,Test-MorphospaceRematerializedCandidate
