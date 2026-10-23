Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1')
Import-Module (Join-Path $PSScriptRoot 'InheritedCandidateMaterialization.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceSourceCompositionIdentity.psm1')

function Invoke-MorphospaceCandidateGit {
    param([string]$Repository,[string[]]$Arguments,[string]$Context)
    $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$output=@(& git -C $Repository @Arguments 2>&1);$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
    if($exit-ne0){throw "Frozen candidate $Context failed for '$Repository': git $($Arguments -join ' ')"}
    return @($output|ForEach-Object{[string]$_})
}
function Test-MorphospaceCandidatePathAllowed {
    param([string]$Path,[string[]]$Allowed)
    $canonical=ConvertTo-MorphospaceProtocolRelativePath $Path
    foreach($entry in @($Allowed)){
        $raw=[string]$entry;$directory=$raw.EndsWith('/');$base=ConvertTo-MorphospaceProtocolRelativePath ($raw.TrimEnd('/'))
        if($canonical-ceq$base-or($directory-and$canonical.StartsWith("$base/",[StringComparison]::Ordinal))){return $true}
    }
    return $false
}
function Get-MorphospaceCandidateRepositoryMap {
    param([string]$Workspace,[string]$RelativePath)
    $path=Resolve-MorphospaceWorkspacePath $Workspace $RelativePath -RequireLeaf
    $repoRoot=Split-Path $PSScriptRoot -Parent
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile (Join-Path $repoRoot 'schemas\repository-map.schema.json'))){throw 'Frozen candidate repository map is malformed.'}
    $document=Read-MorphospaceProtocolJson $path;$map=@{}
    foreach($entry in @($document.repositories)){
        $id=[string]$entry.repo_id
        if(-not$id-or$map.ContainsKey($id)){throw "Frozen candidate repository map repeats or omits repository identity '$id'."}
        $root=[IO.Path]::GetFullPath([string]$entry.path)
        if(-not[IO.Directory]::Exists($root)){throw "Frozen candidate mapped repository '$id' is absent."}
        $map[$id]=[pscustomobject]@{repo_id=$id;path=$root;role=[string]$entry.role}
    }
    return $map
}
function Get-MorphospaceCandidatePreparationProvenance {
    param([string]$Workspace,[string]$UnitId)
    $repoRoot=Split-Path $PSScriptRoot -Parent;$matches=@();foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $Workspace 'receipts') -Filter '*.json' -File)){$doc=Read-MorphospaceProtocolJson $file.FullName;if([string]$doc.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$doc.unit_id-ceq$UnitId){if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $file.FullName) -SchemaFile (Join-Path $repoRoot 'schemas\development-unit-admission-v1.schema.json'))){throw 'Preparation-owned source composition admission receipt is malformed.'};$matches+=,[pscustomobject]@{path=('receipts/'+$file.Name);document=$doc;sha256=(Get-MorphospaceFileSha256 $file.FullName)}}}
    if($matches.Count-ne1){throw 'Preparation-owned source composition requires exactly one authenticated admission receipt.'};return $matches[0]
}
function Get-MorphospaceCandidateSourceComposition {
    param([string]$Workspace,[string]$RelativePath,[string]$ProjectId,[string]$UnitId,[ref]$OwnerContinuation=$null)
    if($null-ne$OwnerContinuation){$OwnerContinuation.Value=$null}
    $path=Resolve-MorphospaceWorkspacePath $Workspace $RelativePath -RequireLeaf
    $repoRoot=Split-Path $PSScriptRoot -Parent
    $composition=Read-MorphospaceProtocolJson $path
    if([string]$composition.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){
        if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile (Join-Path $repoRoot 'schemas/active-development-envelope-source-composition-v1.schema.json'))){throw 'Frozen candidate active envelope source composition is malformed.'}
        if([string]$composition.project_id-cne$ProjectId-or[string]$composition.unit_id-cne$UnitId){throw 'Frozen candidate active envelope identity is detached.'}
        $mapPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$composition.repository_map.path) -RequireLeaf
        $proof=Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $Workspace -UnitId $UnitId -RepositoryMapPath $mapPath
        if([string]$proof.effective.source_composition_binding.path-cne$RelativePath-or[string]$proof.effective.source_composition_binding.raw_sha256-cne(Get-MorphospaceFileSha256 $path)){throw 'Frozen candidate active envelope source lock is detached from its owner lineage.'}
        if($null-ne$OwnerContinuation){$OwnerContinuation.Value=$proof.continuation}
        return $composition
    }
    if([string]$composition.schema-cin@('rusty.morphospace.workflow.development_envelope_source_composition.v1','rusty.morphospace.workflow.development_envelope_source_composition.v2','rusty.morphospace.workflow.development_envelope_source_composition.v3')){
        $schemaFile="development-envelope-source-composition-$(([string]$composition.schema).Split('.')[-1]).schema.json"
        if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile (Join-Path $repoRoot "schemas\$schemaFile"))){throw 'Frozen candidate preparation-owned source composition is malformed.'}
        $admission=Get-MorphospaceCandidatePreparationProvenance $Workspace $UnitId;$preparation=$admission.document.preparation;$preparationProof=Test-MorphospaceDevelopmentUnitPreparation -WorkspaceRoot $Workspace -Admission $admission.document -Phase Freeze
        if($null-ne$OwnerContinuation){$OwnerContinuation.Value=$preparationProof.continuation}
        if([string]$preparation.source_composition_path-cne$RelativePath-or[string]$preparation.source_composition_sha256-cne(Get-MorphospaceFileSha256 $path)){throw 'Frozen candidate preparation source lock is not the exact admitted lock.'}
        $receiptPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$preparation.receipt_path) -RequireLeaf
        $admissionKind=Get-MorphospaceDevelopmentAdmissionKind $admission.document
        $receiptSchema=if($admissionKind-ceq'blocked-successor'){'blocked-successor-preparation-receipt-v1.schema.json'}else{'development-envelope-preparation-receipt-v1.schema.json'}
        if((Get-MorphospaceFileSha256 $receiptPath)-cne[string]$preparation.receipt_sha256-or-not(Test-Json -Json (Get-Content -Raw -LiteralPath $receiptPath) -SchemaFile (Join-Path $repoRoot "schemas\$receiptSchema"))){throw 'Frozen candidate preparation receipt provenance is invalid.'}
        $receipt=Read-MorphospaceProtocolJson $receiptPath
        $expectedSourceHash=if($admissionKind-ceq'blocked-successor'){Get-MorphospaceFileSha256 $path}else{Get-MorphospaceCanonicalJsonSha256 $composition}
        if([string]$receipt.project_id-cne$ProjectId-or[string]$receipt.preparation_id-cne[string]$composition.preparation_id-or[string]$receipt.source_composition.path-cne$RelativePath-or[string]$receipt.source_composition.sha256-cne$expectedSourceHash){throw 'Frozen candidate preparation receipt does not authenticate this source lock.'}
        return $composition
    }
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile (Join-Path $repoRoot 'schemas\source-composition-lock.schema.json'))){throw 'Frozen candidate source composition is not an exact source-composition lock.'}
    if([string]$composition.project_id-cne$ProjectId-or[string]$composition.unit_id-cne$UnitId){throw 'Frozen candidate source composition project or unit identity differs from the candidate.'}
    return $composition
}
function Assert-MorphospaceFrozenCandidateScope {
    param([object]$Candidate,[object]$Unit)
    $scope=$Unit.agent_scope_assessment
    $unitRepos=@($Unit.allowed_repositories.repo_id)
    foreach($r in @($Candidate.final_repositories)){if($unitRepos -cnotcontains [string]$r.repo_id){throw "Frozen source closure includes undeclared repository '$($r.repo_id)'."}}
    foreach($r in @($Candidate.changed_paths)){
        if($unitRepos -cnotcontains [string]$r.repo_id){throw "Frozen changed path set includes undeclared repository '$($r.repo_id)'."}
        $allowed=@($Unit.allowed_repositories|Where-Object{[string]$_.repo_id -ceq [string]$r.repo_id})[0]
        if(@($r.paths).Count-eq0){
            $validationOnly=$Unit.PSObject.Properties.Name-contains'work_mode'-and[string]$Unit.work_mode-ceq'validation-only'
            if(-not$validationOnly-or@($allowed.allowed_paths).Count-ne0-or[string]$Candidate.cleanliness_policy-cne'clean-only'){throw 'Empty frozen path rows require an explicit validation-only unit, empty admitted write scope and clean-only observation.'}
        }
        foreach($path in @($r.paths)){if(-not(Test-MorphospaceCandidatePathAllowed -Path ([string]$path).TrimEnd('/') -Allowed @($allowed.allowed_paths))){throw "Frozen path '$($r.repo_id)/$path' exceeds the active write scope."}}
    }
    foreach($effect in @($Candidate.effects)){if(@($scope.allowed_effect_categories) -cnotcontains [string]$effect){throw "Frozen effect '$effect' exceeds the admitted envelope."}}
    foreach($permission in @($Candidate.permissions)){if(@($scope.allowed_permission_categories) -cnotcontains [string]$permission){throw "Frozen permission '$permission' exceeds the admitted envelope."}}
    foreach($device in @($Candidate.device_use)){if([string]$device -cne 'none' -and @($scope.device_envelope.allowed_kinds) -cnotcontains [string]$device){throw "Frozen device '$device' exceeds the admitted envelope."}}
    if(@($Candidate.cleanup_evidence).Count -lt 1 -or @($Candidate.instruction_surfaces).Count -lt 1){throw 'FreezeCandidate requires cleanup/evidence and instruction-surface declarations.'}
}
function Get-MorphospaceCandidateTransitionPaths {
    param([string]$Workspace,[string]$TransactionId)
    $ledgerOwner=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
    &$ledgerOwner {param($w,$id)
        [pscustomobject]@{intent=Get-MorphospaceLedgerPath $w $id intent;completion=Get-MorphospaceLedgerPath $w $id completion}
    } $Workspace $TransactionId
}
function New-MorphospaceSelfHostedPlanningControlClosure {
    # Continuation comes only from this invocation's source-composition owner
    # read. Inputs name exact files; they do not grant validation or acceptance.
    param([string]$Workspace,[object]$Unit,[object]$FrozenTransition,[object]$Continuation,[object]$Inputs,[hashtable]$Observation)
    $workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $liveUnit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace "iteration-units/$($Unit.unit_id).json" -RequireLeaf)
    $liveState=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'workspace.state.json' -RequireLeaf)
    if($null-eq$Continuation-or[string]$Continuation.unit.unit_id-cne[string]$Unit.unit_id-or
        (Get-MorphospaceCanonicalJsonSha256 $Continuation.unit)-cne(Get-MorphospaceCanonicalJsonSha256 $liveUnit)-or
        (Get-MorphospaceCanonicalJsonSha256 $Continuation.state)-cne(Get-MorphospaceCanonicalJsonSha256 $liveState)){
        throw 'Self-hosted planning closure is detached from the current authenticated owner.'
    }
    $inputNames=@('selector_path','selector_sha256','consumed_receipt_path','consumed_receipt_sha256')
    if((@($Inputs.PSObject.Properties.Name|Sort-Object)-join'|')-cne(@($inputNames|Sort-Object)-join'|')){throw 'Self-hosted planning inputs must be the exact selector and consumed-receipt bindings.'}
    $entries=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $add={param([string]$relative,[string]$expected)
        $canonical=ConvertTo-MorphospaceProtocolRelativePath $relative
        if($canonical-cne$relative-or$expected-cnotmatch'^[0-9a-f]{64}$'){throw 'Self-hosted planning control binding is malformed.'}
        $absolute=Resolve-MorphospaceWorkspacePath $Workspace $canonical -RequireLeaf
        if((Get-MorphospaceFileSha256 $absolute)-cne$expected){throw "Self-hosted planning authenticated control bytes drifted: $canonical"}
        if($entries.ContainsKey($canonical)-and$entries[$canonical]-cne$expected){throw 'Self-hosted planning control paths have conflicting byte bindings.'}
        $entries[$canonical]=$expected
    }
    foreach($relative in $Observation.Keys){&$add $relative ([string]$Observation[$relative])}
    $records=@($Continuation.records)
    $freezes=@($records|Where-Object{[string]$_.event.event_id-ceq[string]$FrozenTransition.intent.event.event_id})
    if($freezes.Count-ne1-or(Get-MorphospaceCanonicalJsonSha256 $freezes[0].transition.intent)-cne(Get-MorphospaceCanonicalJsonSha256 $FrozenTransition.intent)){
        throw 'Self-hosted planning closure lacks its exact authenticated Freeze transition.'
    }
    foreach($record in $records){
        $proof=$record.transition;$intent=$proof.intent
        $paths=Get-MorphospaceCandidateTransitionPaths $Workspace ([string]$intent.transaction_id)
        if([string]$proof.completion.intent.path-cne[string]$paths.intent){throw 'Self-hosted planning transition paths are detached from their ledger owner.'}
        &$add ([string]$paths.intent) ([string]$proof.completion.intent.sha256)
        &$add ([string]$paths.completion) (Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $proof.completion))
        foreach($artifact in @($intent.artifacts)){&$add ([string]$artifact.path) ([string]$artifact.sha256)}
        if([string]$record.event.event_id-cmatch'-validation-(fail|blocked|partial)-return-[0-9]{4,}$'){
            if(@($record.event.receipts).Count-ne2-or@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].path-cne[string]$record.event.receipts[1]){throw 'Self-hosted planning retained Return receipt binding is detached.'}
            &$add ([string]$record.event.receipts[0]) ([string]$intent.artifacts[0].sha256)
        }
        if([string]$record.kind-ceq'tooling-upgrade'){
            $requests=@($intent.artifacts|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))}|Where-Object schema -CEQ 'rusty.morphospace.workflow.tooling_context_upgrade.v1')
            if($requests.Count-ne1){throw 'Self-hosted planning upgrade must have one authenticated request.'}
            &$add ([string]$requests[0].compatibility_receipt.path) ([string]$requests[0].compatibility_receipt.sha256)
        }
    }
    foreach($pair in @(@('selector_path','selector_sha256'),@('consumed_receipt_path','consumed_receipt_sha256'))){
        $relative=[string]$Inputs.($pair[0]);$hash=[string]$Inputs.($pair[1])
        if([bool]$relative-ne[bool]$hash){throw 'Self-hosted planning input requires its exact path and raw hash together.'}
        if($relative){&$add $relative $hash}
    }
    # The physical receipt is admitted only after its consuming owner has run
    # the complete native receipt predicate. Still repeat its closed structure
    # and identity here; a path or caller-supplied success flag is never proof.
    if($Inputs.consumed_receipt_path){
        $receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$Inputs.consumed_receipt_path) -RequireLeaf)
        $owner=Split-Path $PSScriptRoot -Parent
        if([string]$receipt.schema-cne'rusty.morphospace.workflow.validation_receipt.v1'-or
            -not(Test-Json -Json ($receipt|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $owner 'schemas/validation-receipt.schema.json'))-or
            [string]$receipt.project_id-cne[string]$liveUnit.project_id-or[string]$receipt.unit_id-cne[string]$liveUnit.unit_id){throw 'Self-hosted planning consumed receipt identity is detached.'}
    }
    [pscustomobject]@{workspace=$workspaceFull;unit_id=[string]$Unit.unit_id;entries=$entries;observation=$Observation}
}
function Test-MorphospaceSelfHostedPlanningFreezeDirt {
    param(
        [string]$Workspace,
        [object]$Unit,
        [object]$RepositoryEntry,
        [object]$FrozenTransition,
        [object]$PlanningClosure=$null
    )
    if($null-eq$FrozenTransition-or[string]$RepositoryEntry.role-cne'planning'){return $false}
    $repository=[IO.Path]::GetFullPath([string]$RepositoryEntry.path).TrimEnd('\','/')
    $workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $repositoryPrefix=$repository+[IO.Path]::DirectorySeparatorChar
    $workspaceRelative=if($workspaceFull.Equals($repository,[StringComparison]::OrdinalIgnoreCase)){''}elseif($workspaceFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)){$workspaceFull.Substring($repositoryPrefix.Length).Replace('\','/').TrimEnd('/')+'/' }else{return $false}
    if($null-ne$PlanningClosure){
        if([string]$PlanningClosure.workspace-cne$workspaceFull-or[string]$PlanningClosure.unit_id-cne[string]$Unit.unit_id){throw 'Self-hosted planning closure escaped its authenticated owner.'}
        foreach($relative in $PlanningClosure.entries.Keys){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf))-cne[string]$PlanningClosure.entries[$relative]){throw "Self-hosted planning authenticated control bytes drifted: $relative"}}
        $staged=@(Invoke-MorphospaceCandidateGit $repository @('-c','core.safecrlf=false','diff','--cached','--name-only','--no-renames','--') 'self-hosted planning staged-dirt observation'|Where-Object{$_})
        $unstaged=@(Invoke-MorphospaceCandidateGit $repository @('-c','core.safecrlf=false','diff','--name-only','--no-renames','--') 'self-hosted planning unstaged-dirt observation'|Where-Object{$_})
        $untracked=@(Invoke-MorphospaceCandidateGit $repository @('ls-files','--others','--exclude-standard') 'self-hosted planning untracked-dirt observation'|Where-Object{$_})
        foreach($path in @($staged+$unstaged+$untracked|Sort-Object -Unique)){
            $canonical=([string]$path).Replace('\','/')
            if(-not$canonical.StartsWith($workspaceRelative,[StringComparison]::Ordinal)-or-not$PlanningClosure.entries.ContainsKey($canonical.Substring($workspaceRelative.Length))){throw "Self-hosted planning repository dirt is outside the exact authenticated control closure: $canonical"}
        }
        foreach($path in $staged){
            $index=@(Invoke-MorphospaceCandidateGit $repository @('ls-files','--stage','--',([string]$path)) 'self-hosted planning index observation')
            if($index.Count-ne1-or[string]$index[0]-cnotmatch'^(100644|100755) ([0-9a-f]{40}) 0\t'){throw 'Self-hosted planning staged control entry is not one regular stage-zero blob.'}
            $indexOid=$Matches[2];$workingOid=@(Invoke-MorphospaceCandidateGit $repository @('hash-object','--no-filters','--',([string]$path)) 'self-hosted planning index-byte comparison')[0]
            if($indexOid-cne$workingOid){throw 'Self-hosted planning staged control bytes differ from the authenticated physical file.'}
        }
        return $true
    }
    $receiptRelative=([string]$Unit.candidate_freeze.receipt_path).Replace('\','/')
    $ownedWorkspacePaths=@(
        'workspace.state.json',
        'iteration-events.jsonl',
        "iteration-units/$([string]$Unit.unit_id).json",
        $receiptRelative,
        ([string]$FrozenTransition.intent_path).Replace('\','/'),
        ([string]$FrozenTransition.completion_path).Replace('\','/')
    )|Sort-Object -Unique
    if($ownedWorkspacePaths.Count-ne6-or@($ownedWorkspacePaths|Where-Object{[string]::IsNullOrWhiteSpace([string]$_)}).Count-ne0){return $false}
    $expected=@($ownedWorkspacePaths|ForEach-Object{$workspaceRelative+$_}|Sort-Object -Unique)
    $staged=@(Invoke-MorphospaceCandidateGit $repository @('-c','core.safecrlf=false','diff','--cached','--name-only','--no-renames','--') 'self-hosted planning lifecycle staged-dirt observation'|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')}|Sort-Object -Unique)
    $unstaged=@(Invoke-MorphospaceCandidateGit $repository @('-c','core.safecrlf=false','diff','--name-only','--no-renames','--') 'self-hosted planning lifecycle unstaged-dirt observation'|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')}|Sort-Object -Unique)
    $untracked=@(Invoke-MorphospaceCandidateGit $repository @('ls-files','--others','--exclude-standard') 'self-hosted planning lifecycle untracked-dirt observation'|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')}|Sort-Object -Unique)
    $observed=@($staged+$unstaged+$untracked|Sort-Object -Unique)
    if($observed.Count-ne$expected.Count-or($observed-join'|')-cne($expected-join'|')){
        throw "Self-hosted planning repository dirt differs from the exact authenticated freeze transition (expected: $($expected-join', '); observed: $($observed-join', '))."
    }
    return $true
}
function Test-MorphospaceOwnPlanningCandidateHistory {
    param([string]$Workspace,[object]$RepositoryEntry,[object]$Bound,[object]$Composition,[object]$Unit,[object]$FrozenTransition,[object]$PlanningClosure=$null)
    # Get-MorphospaceCandidateSourceComposition has already authenticated the
    # exact preparation/effective continuation. A generic lock is insufficient.
    if([string]$RepositoryEntry.role-cne'planning'-or[string]$Composition.schema-cnotin@(
        'rusty.morphospace.workflow.development_envelope_source_composition.v1',
        'rusty.morphospace.workflow.development_envelope_source_composition.v2',
        'rusty.morphospace.workflow.development_envelope_source_composition.v3',
        'rusty.morphospace.workflow.active_development_envelope_source_composition.v1')){return $false}
    $pathComparison=if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $repository=[IO.Path]::GetFullPath([string]$RepositoryEntry.path).TrimEnd('\','/')
    $workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $gitRoot=(@(Invoke-MorphospaceCandidateGit $repository @('rev-parse','--show-toplevel') 'own-planning Git-root observation')[0]).Trim()
    if(-not([IO.Path]::GetFullPath($gitRoot).TrimEnd('\','/').Equals($repository,$pathComparison))){return $false}
    $prefix=$repository+[IO.Path]::DirectorySeparatorChar
    # This bounded route is for a nested control workspace, never a blanket
    # role=planning exemption for an entire repository or a sibling workspace.
    if(-not$workspaceFull.StartsWith($prefix,$pathComparison)){return $false}
    $workspaceGitRoot=(@(Invoke-MorphospaceCandidateGit $workspaceFull @('rev-parse','--show-toplevel') 'own-planning workspace Git-root observation')[0]).Trim()
    if(-not([IO.Path]::GetFullPath($workspaceGitRoot).TrimEnd('\','/').Equals($repository,$pathComparison))){return $false}
    $controlPrefix=$workspaceFull.Substring($prefix.Length).Replace('\','/').TrimEnd('/')+'/'
    $head=(@(Invoke-MorphospaceCandidateGit $repository @('rev-parse','HEAD') 'own-planning live commit observation')[0]).Trim().ToLowerInvariant()
    [void](Invoke-MorphospaceCandidateGit $repository @('merge-base','--is-ancestor',[string]$Bound.commit,$head) 'own-planning historical ancestry observation')
    # Inspect each intervening commit, not merely the endpoint diff: a source
    # or docs change followed by a revert must not gain this control-only route.
    $changed=@(Invoke-MorphospaceCandidateGit $repository @('-c','core.quotepath=false','log','--format=','--name-only','--no-renames','--full-history','-m',"$([string]$Bound.commit)..$head",'--') 'own-planning lifecycle history observation')
    foreach($path in @($changed|Where-Object{$_}|Sort-Object -Unique)){
        if(-not([string]$path).StartsWith($controlPrefix,[StringComparison]::Ordinal)){throw "Frozen candidate own-planning history changed '$path' outside its exact control workspace."}
    }
    $dirty=@(Invoke-MorphospaceCandidateGit $repository @('status','--porcelain=v1','--untracked-files=all') 'own-planning cleanliness observation')
    if($dirty.Count-ne0-and-not(Test-MorphospaceSelfHostedPlanningFreezeDirt -Workspace $Workspace -Unit $Unit -RepositoryEntry $RepositoryEntry -FrozenTransition $FrozenTransition -PlanningClosure $PlanningClosure)){throw 'Frozen candidate own-planning repository is dirty outside its authenticated freeze transition.'}
    return $true
}
function Assert-MorphospaceCandidateRepositoryClosure {
    param([string]$Workspace,[object]$Candidate,[object]$Unit,[object]$FrozenTransition=$null,[object]$AuthenticatedComposition=$null,[object]$PlanningInputs=$null,[object]$PendingRevisionIntent=$null)
    $planningObservation=@{}
    if($null-ne$PlanningInputs){foreach($relative in @('workspace.state.json','iteration-events.jsonl',"iteration-units/$($Unit.unit_id).json")){$planningObservation[$relative]=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf)}}
    $map=Get-MorphospaceCandidateRepositoryMap $Workspace ([string]$Candidate.expected.repository_map_path)
    $ownerContinuation=$null
    $composition=if($null-ne$AuthenticatedComposition){$AuthenticatedComposition}else{Get-MorphospaceCandidateSourceComposition $Workspace ([string]$Candidate.expected.source_composition_path) ([string]$Candidate.project_id) ([string]$Candidate.unit_id) -OwnerContinuation ([ref]$ownerContinuation)}
    $planningClosure=$null
    if($null-ne$PlanningInputs){
        if($null-eq$FrozenTransition-or$Unit.PSObject.Properties.Name-cnotcontains'tooling_context'){throw 'Current planning closure requires an actual frozen tooling-aware owner.'}
        if($null-eq$ownerContinuation){$effective=Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $Workspace -UnitId ([string]$Unit.unit_id) -RepositoryMapPath (Resolve-MorphospaceWorkspacePath $Workspace ([string]$Candidate.expected.repository_map_path) -RequireLeaf);$ownerContinuation=$effective.continuation}
        $planningClosure=New-MorphospaceSelfHostedPlanningControlClosure $Workspace $Unit $FrozenTransition $ownerContinuation $PlanningInputs $planningObservation
    }
    if($null-ne$PendingRevisionIntent){
        if($null-ne$PlanningInputs){throw 'Pending candidate revision cannot mix live selector inputs.'}
        $planningClosure=New-MorphospaceCandidateRevisionPendingPlanningClosure $Workspace $Candidate $Unit $PendingRevisionIntent
    }
    if([string]$composition.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){
        $boundMapPath=[string]$composition.repository_map.path;$boundMapSha=[string]$composition.repository_map.raw_sha256
    }elseif([string]$composition.schema-cin@('rusty.morphospace.workflow.development_envelope_source_composition.v1','rusty.morphospace.workflow.development_envelope_source_composition.v2','rusty.morphospace.workflow.development_envelope_source_composition.v3')){
        $admission=Get-MorphospaceCandidatePreparationProvenance $Workspace ([string]$Candidate.unit_id)
        $boundMapPath=[string]$admission.document.expected.repository_map_path;$boundMapSha=[string]$admission.document.expected.repository_map_sha256
    }else{$boundMapPath='';$boundMapSha=''}
    if($boundMapPath-and([string]$Candidate.expected.repository_map_path-cne$boundMapPath-or[string]$Candidate.expected.repository_map_sha256-cne$boundMapSha-or(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $boundMapPath -RequireLeaf))-cne$boundMapSha)){throw 'Frozen candidate repository map is detached from its prepared or extended owner binding.'}
    $finalById=@{};foreach($final in @($Candidate.final_repositories)){
        $id=[string]$final.repo_id
        if(-not$id-or$finalById.ContainsKey($id)){throw "Frozen candidate final repositories repeat or omit '$id'."}
        $finalById[$id]=$final
    }
    $changedById=@{};foreach($changed in @($Candidate.changed_paths)){
        $id=[string]$changed.repo_id
        if(-not$id-or$changedById.ContainsKey($id)){throw "Frozen candidate changed-path records repeat or omit '$id'."}
        $changedById[$id]=$changed
    }
    $scopeById=@{};foreach($scope in @($Unit.allowed_repositories)){if($scopeById.ContainsKey([string]$scope.repo_id)){throw 'Active unit repeats a repository scope.'};$scopeById[[string]$scope.repo_id]=$scope}
    $compositionById=@{};foreach($row in @(Get-MorphospaceSourceCompositionRepositoryPins $composition)){
        $id=[string]$row.repo_id
        if(-not$id-or$compositionById.ContainsKey($id)){throw "Frozen candidate source composition repeats or omits '$id'."}
        $compositionById[$id]=$row
    }
    if($finalById.Count-ne$scopeById.Count-or$changedById.Count-ne$scopeById.Count){throw 'Frozen candidate repository and changed-path sets must exactly equal the active writable scope.'}
    foreach($id in @($compositionById.Keys|Sort-Object)){
        if(-not$map.ContainsKey($id)){throw "Frozen candidate source-composition repository '$id' is absent from the repository map."}
        $bound=$compositionById[$id];$entry=$map[$id]
        if([string]$bound.role-cne[string]$entry.role){throw "Frozen candidate source-composition role differs from the repository map for '$id'."}
        $lockedCommit=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse',"$([string]$bound.commit)^{commit}") 'source-composition commit-object observation')[0]).Trim().ToLowerInvariant()
        $lockedTree=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse',"$([string]$bound.commit)^{tree}") 'source-composition tree-object observation')[0]).Trim().ToLowerInvariant()
        if($lockedCommit-cne[string]$bound.commit-or$lockedTree-cne[string]$bound.tree){throw "Frozen candidate source-composition object identity differs for '$id'."}
        if(-not$scopeById.ContainsKey($id)){
            if(Test-MorphospaceOwnPlanningCandidateHistory -Workspace $workspace -RepositoryEntry $entry -Bound $bound -Composition $composition -Unit $Unit -FrozenTransition $FrozenTransition -PlanningClosure $planningClosure){continue}
            $head=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse','HEAD') 'read-only dependency commit observation')[0]).Trim().ToLowerInvariant()
            $tree=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse','HEAD^{tree}') 'read-only dependency tree observation')[0]).Trim().ToLowerInvariant()
            if($head-cne[string]$bound.commit-or$tree-cne[string]$bound.tree){throw "Frozen candidate live read-only dependency identity drifted for '$id'."}
            if([string]$entry.role-ceq'source'){
                $tracked=@(Invoke-MorphospaceCandidateGit $entry.path @('status','--porcelain=v1','--untracked-files=no') 'read-only dependency tracked-cleanliness observation')
                if($tracked.Count-ne0){throw "Frozen candidate read-only source dependency '$id' is not tracked-clean."}
            }
        }
    }
    foreach($id in @($scopeById.Keys|Sort-Object)){
        if(-not$finalById.ContainsKey($id)-or-not$changedById.ContainsKey($id)-or-not$compositionById.ContainsKey($id)-or-not$map.ContainsKey($id)){throw "Frozen candidate closure is incomplete for '$id'."}
        $final=$finalById[$id];$bound=$compositionById[$id];$entry=$map[$id]
        if(@($changedById[$id].paths).Count-eq0-and([string]$final.commit-cne[string]$bound.commit-or[string]$final.tree-cne[string]$bound.tree)){throw "Frozen read-only observation '$id' must retain its exact locked commit and tree."}
        $head=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse','HEAD') 'writable candidate commit observation')[0]).Trim().ToLowerInvariant()
        $tree=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse','HEAD^{tree}') 'writable candidate tree observation')[0]).Trim().ToLowerInvariant()
        if($head-cne[string]$final.commit-or$tree-cne[string]$final.tree){throw "Frozen candidate live writable repository identity drifted for '$id'."}
        [void](Invoke-MorphospaceCandidateGit $entry.path @('merge-base','--is-ancestor',[string]$bound.commit,[string]$final.commit) 'baseline-to-candidate ancestry observation')
        $committed=@(Invoke-MorphospaceCandidateGit $entry.path @('diff','--name-only','--no-renames',"$([string]$bound.commit)..$([string]$final.commit)",'--') 'baseline-to-candidate changed-path observation'|Where-Object{$_}|Sort-Object -Unique)
        foreach($path in $committed){
            if(-not(Test-MorphospaceCandidatePathAllowed $path @($changedById[$id].paths))){throw "Frozen candidate committed path '$id/$path' is outside its declared changed-path closure."}
            if(-not(Test-MorphospaceCandidatePathAllowed $path @($scopeById[$id].allowed_paths))){throw "Frozen candidate committed path '$id/$path' exceeds the active scope."}
        }
        if([string]$Candidate.cleanliness_policy-ceq'clean-only'){
            $observed=@(Invoke-MorphospaceCandidateGit $entry.path @('status','--porcelain=v1','--untracked-files=all') 'cleanliness observation')
            if($observed.Count-ne0-and-not(Test-MorphospaceSelfHostedPlanningFreezeDirt -Workspace $workspace -Unit $Unit -RepositoryEntry $entry -FrozenTransition $FrozenTransition -PlanningClosure $planningClosure)){throw "Frozen candidate clean-only repository '$id' is dirty outside the exact authenticated self-hosted planning freeze transition."}
        }else{
            $tracked=@(Invoke-MorphospaceCandidateGit $entry.path @('diff','--name-only','HEAD','--') 'changed-path observation')
            $untracked=@(Invoke-MorphospaceCandidateGit $entry.path @('ls-files','--others','--exclude-standard') 'untracked-path observation')
            $observed=@($tracked+$untracked|Where-Object{$_}|Sort-Object -Unique)
            if($observed.Count-eq0){throw "Frozen candidate declared-dirty repository '$id' has no observed changes."}
            foreach($path in $observed){if(-not(Test-MorphospaceCandidatePathAllowed $path @($changedById[$id].paths))){throw "Frozen candidate observed dirty path '$id/$path' is outside its declared changed-path closure."}}
        }
        foreach($declared in @($changedById[$id].paths)){if(-not(Test-MorphospaceCandidatePathAllowed ([string]$declared).TrimEnd('/') @($scopeById[$id].allowed_paths))){throw "Frozen candidate changed path '$id/$declared' exceeds the active scope."}}
    }
}
function Get-MorphospaceFrozenCandidateTransition {
    param([string]$Workspace,[object]$Candidate,[object]$LiveState,[object]$LiveUnit,[string]$ReceiptRelative)
    $transactionId="$([string]$Candidate.freeze_id)-recorded-transition";$ledger=Get-Module MorphospaceTransitionLedger -All | Select-Object -First 1
    if($null-eq$ledger){throw 'Frozen candidate transition-ledger validator is unavailable.'}
    $binding=& $ledger {
        param($Root,$Id)
        $intentRelative=Get-MorphospaceLedgerPath $Root $Id intent;$completionRelative=Get-MorphospaceLedgerPath $Root $Id completion
        $intentAbsolute=Resolve-MorphospaceWorkspacePath $Root $intentRelative -RequireLeaf;$completionAbsolute=Resolve-MorphospaceWorkspacePath $Root $completionRelative -RequireLeaf
        $intent=Read-MorphospaceLedgerJson $intentAbsolute;Assert-MorphospaceLedgerIntent $intent $Id
        Assert-MorphospaceLedgerCommittedCompletion $Root $Id $intentRelative $intentAbsolute $intent $completionAbsolute
        [pscustomobject]@{intent=$intent;completion=(Read-MorphospaceLedgerJson $completionAbsolute);intent_path=$intentRelative;completion_path=$completionRelative}
    } $Workspace $transactionId
    $intent=$binding.intent;$completion=$binding.completion;$eventId="$([string]$Candidate.freeze_id)-recorded"
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v3'-or[string]$intent.transaction_id-cne$transactionId-or[string]$intent.event.event_id-cne$eventId-or[string]$intent.event.project_id-cne[string]$Candidate.project_id-or[string]$intent.event.unit_id-cne[string]$Candidate.unit_id-or@($intent.event.receipts).Count-ne1-or[string]@($intent.event.receipts)[0]-cne$ReceiptRelative){throw 'Frozen candidate transition identity or receipt binding is not exact.'}
    if([string]$intent.pre.state.sha256-cne[string]$Candidate.expected.state_sha256-or[string]$intent.pre.unit.sha256-cne[string]$Candidate.expected.unit_sha256-or[string]$intent.expected.events_sha256-cne[string]$Candidate.expected.events_sha256-or[int64]$intent.expected.events_length-ne[int64]$Candidate.expected.events_length-or[string]$intent.expected.event_tail_id-cne[string]$Candidate.expected.event_tail_id){throw 'Frozen candidate transition pre-state or ledger binding differs from the receipt.'}
    if([string]$intent.target.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $LiveState)-or[string]$intent.target.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $LiveUnit)){throw 'Frozen candidate transition target state or unit differs from live bytes.'}
    if(@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].path-cne$ReceiptRelative-or[string]$intent.artifacts[0].sha256-cne(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $ReceiptRelative -RequireLeaf))){throw 'Frozen candidate transition artifact binding differs from the receipt.'}
    if([string]$completion.transaction_id-cne$transactionId-or[string]$completion.event_id-cne$eventId-or[string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256){throw 'Frozen candidate transition completion differs from its exact intent.'}
    return $binding
}
function Assert-CandidateRevisionEqual {
    param([object]$Expected,[object]$Actual,[string]$Context)
    if((Get-MorphospaceCanonicalJsonSha256 $Expected)-cne(Get-MorphospaceCanonicalJsonSha256 $Actual)){throw "Candidate revision $Context is detached."}
}
function Get-CandidateRevisionTransition {
    param([string]$Workspace,[string]$EventId,[string]$UnitId)
    # Recovery may already have installed B's projections while Return remains
    # the physical event tail. Authenticate historical evidence independently;
    # the revision transform and ledger CAS authenticate the live endpoint.
    $retirementOwner=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
    $proof=&$retirementOwner {param($root,$id) Get-ActiveRetirementPlanningTransition $root $id -HistoricalProjection} $Workspace "$EventId-transition"
    if([string]$proof.intent.state.path-cne'workspace.state.json'-or[string]$proof.intent.unit.path-cne"iteration-units/$UnitId.json"-or[string]$proof.intent.events.path-cne'iteration-events.jsonl'){throw 'Candidate revision predecessor projection paths are detached.'}
    $paths=Get-MorphospaceCandidateTransitionPaths $Workspace "$EventId-transition"
    if([string]$proof.completion.intent.path-cne[string]$paths.intent){throw 'Candidate revision predecessor transition paths are detached.'}
    return [pscustomobject]@{intent=$proof.intent;completion=$proof.completion;intent_path=$paths.intent;completion_path=$paths.completion}
}
function New-MorphospaceCandidateRevisionPendingPlanningClosure {
    param([string]$Workspace,[object]$Candidate,[object]$Unit,[object]$Intent)
    # This is recovery's exact pending intent, not a proof supplied by a caller.
    # Every committed input remains authenticated through the ledger owner. The
    # pending artifact is optional only until its native installation boundary.
    $paths=Get-MorphospaceCandidateTransitionPaths $Workspace ([string]$Intent.transaction_id)
    $intentPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$paths.intent) -RequireLeaf
    Assert-CandidateRevisionEqual $Intent (Read-MorphospaceProtocolJson $intentPath) 'pending physical intent'
    $endpoint=Get-CandidateRevisionTransition $Workspace ([string]$Candidate.expected.event_tail_id) ([string]$Unit.unit_id)
    foreach($pair in @(@('workspace.state.json','state'),@("iteration-units/$($Unit.unit_id).json",'unit'))){
        $hash=Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace $pair[0] -RequireLeaf))
        if(@([string]$endpoint.intent.target.($pair[1]).sha256,[string]$Intent.target.($pair[1]).sha256)-cnotcontains$hash){throw 'Candidate revision recovery live projection is outside its exact endpoint and target.'}
    }
    $entries=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $add={param([string]$relative,[string]$hash)
        $canonical=ConvertTo-MorphospaceProtocolRelativePath $relative
        if($canonical-cne$relative-or$hash-cnotmatch'^[0-9a-f]{64}$'-or(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $canonical -RequireLeaf))-cne$hash){throw 'Candidate revision recovery control binding is detached.'}
        if($entries.ContainsKey($canonical)-and$entries[$canonical]-cne$hash){throw 'Candidate revision recovery has conflicting control bytes.'}
        $entries[$canonical]=$hash
    }
    # The authenticated current-unit prefix also owns Ready/Claim and original
    # admission artifacts. No other unit or neighboring file enters this set.
    $events=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_}|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$_))})
    foreach($event in @($events|Where-Object{[string]$_.unit_id-ceq[string]$Unit.unit_id-and[int]$_.sequence-le[int]$endpoint.intent.event.sequence})){
        $proof=Get-CandidateRevisionTransition $Workspace ([string]$event.event_id) ([string]$Unit.unit_id)
        Assert-CandidateRevisionEqual $event $proof.intent.event 'recovery control event'
        &$add ([string]$proof.intent_path) ([string]$proof.completion.intent.sha256)
        &$add ([string]$proof.completion_path) (Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $proof.completion))
        foreach($artifact in @($proof.intent.artifacts)){&$add ([string]$artifact.path) ([string]$artifact.sha256)}
        $requests=@($proof.intent.artifacts|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))}|Where-Object schema -CEQ 'rusty.morphospace.workflow.tooling_context_upgrade.v1')
        foreach($request in $requests){&$add ([string]$request.compatibility_receipt.path) ([string]$request.compatibility_receipt.sha256)}
        if([string]$event.event_id-cmatch'-validation-(fail|blocked|partial)-return-[0-9]{4,}$'){
            if(@($event.receipts).Count-ne2-or@($proof.intent.artifacts).Count-ne1-or[string]$proof.intent.artifacts[0].path-cne[string]$event.receipts[1]){throw 'Candidate revision recovery Return binding is detached.'}
            &$add ([string]$event.receipts[0]) ([string]$proof.intent.artifacts[0].sha256)
        }
    }
    &$add ([string]$paths.intent) (Get-MorphospaceFileSha256 $intentPath)
    foreach($artifact in @($Intent.artifacts)){
        if([IO.File]::Exists((Resolve-MorphospaceWorkspacePath $Workspace ([string]$artifact.path)))){&$add ([string]$artifact.path) ([string]$artifact.sha256)}
    }
    $completion=Resolve-MorphospaceWorkspacePath $Workspace ([string]$paths.completion)
    if([IO.File]::Exists($completion)){
        $proof=Get-CandidateRevisionTransition $Workspace ([string]$Intent.event.event_id) ([string]$Unit.unit_id)
        &$add ([string]$paths.completion) (Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $proof.completion))
    }
    foreach($relative in @('workspace.state.json','iteration-events.jsonl',"iteration-units/$($Unit.unit_id).json")){
        &$add $relative (Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf))
    }
    [pscustomobject]@{workspace=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/');unit_id=[string]$Unit.unit_id;entries=$entries}
}
function Get-MorphospaceCandidateCompletedReplayInputs {
    param([string]$Workspace,[object]$Candidate,[object]$Continuation)
    $unit=$Continuation.unit;$state=$Continuation.state
    $inputs=[pscustomobject]@{selector_path='';selector_sha256='';consumed_receipt_path='';consumed_receipt_sha256=''}
    $automation=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru
    $selectorOwner=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceNormalValidationSelector.psm1') -PassThru
    $spec=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'project.spec.json' -RequireLeaf)
    $matrix=@(&$automation {param($u)New-MorphospaceValidationMatrix -Unit $u -DeviceSerials @()} $unit)
    $selections=@($Continuation.records|Where-Object{
        $_.transition.intent.target.unit.document.PSObject.Properties.Name-ccontains'candidate_freeze'-and
        [string]$_.transition.intent.target.unit.document.candidate_freeze.freeze_id-ceq[string]$Candidate.freeze_id-and
        $_.transition.intent.target.state.document.PSObject.Properties.Name-ccontains'normal_validation_selection'-and
        $null-ne$_.transition.intent.target.state.document.normal_validation_selection
    }|ForEach-Object{$_.transition.intent.target.state.document.normal_validation_selection}|Group-Object -Property {Get-MorphospaceCanonicalJsonSha256 $_}|ForEach-Object{$_.Group[0]})
    if($selections.Count-gt1){throw 'Completed candidate replay has ambiguous retained selector bindings.'}
    $selection=if($selections.Count-eq1){$selections[0]}else{$null}
    if($null-ne$selection){
        $inputs.selector_path=[string]$selection.selector_path;$inputs.selector_sha256=[string]$selection.selector_sha256
        if($inputs.selector_path-cnotmatch'^validation-authority/selectors/[a-z0-9][a-z0-9-]{1,127}\.json$'){throw 'Completed candidate replay selector path is detached.'}
        $selectorPath=Resolve-MorphospaceWorkspacePath $Workspace $inputs.selector_path -RequireLeaf
        if((Get-MorphospaceFileSha256 $selectorPath)-cne$inputs.selector_sha256){throw 'Completed candidate replay selector bytes drifted.'}
        $selector=Read-MorphospaceProtocolJson $selectorPath;$declared=[string]$selector.schema-ceq'rusty.morphospace.workflow.normal_validation_selector.v2'
        $schema=if($declared){'normal-validation-selector-v2.schema.json'}else{'normal-validation-selector-v1.schema.json'}
        if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $selectorPath) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) "schemas/$schema"))){throw 'Completed candidate replay selector schema is invalid.'}
        $contract=&$selectorOwner {param($u)Get-MorphospaceSelectorUnitContractSha256 $u} $unit
        if([string]$selector.unit.unit_id-cne[string]$unit.unit_id-or[string]$selector.unit.path-cne"iteration-units/$($unit.unit_id).json"-or[string]$selector.unit.contract_sha256-cne$contract-or
            [string]$selector.project.project_id-cne[string]$unit.project_id-or[string]$selector.project.spec_raw_sha256-cne(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace 'project.spec.json' -RequireLeaf))-or
            [string]$selector.candidate_freeze.freeze_id-cne[string]$Candidate.freeze_id-or[string]$selector.candidate_freeze.receipt_path-cne"receipts/$($Candidate.freeze_id).json"-or
            [string]$selector.selector_id-cne[IO.Path]::GetFileNameWithoutExtension($inputs.selector_path)-or
            [string]$selector.candidate_freeze.receipt_sha256-cne(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace ([string]$selector.candidate_freeze.receipt_path) -RequireLeaf))){throw 'Completed candidate replay selector authority is detached.'}
        Assert-CandidateRevisionEqual @($Candidate.final_repositories) @($selector.candidate_freeze.final_repositories) 'completed selector source vector'
        $declaredRows=@($matrix|Where-Object profile_id -CEQ ([string]$selector.declared_gate.profile_id))
        if($declaredRows.Count-ne1-or[string]$selector.declared_gate.command_sha256-cne(Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$declaredRows[0].command)))){throw 'Completed candidate replay declared validation gate is detached.'}
        $expected=[pscustomobject]@{unit_id=[string]$unit.unit_id;unit_raw_sha256=[string]$selector.unit.raw_sha256;unit_contract_sha256=[string]$selector.unit.contract_sha256;tier=[string]$selector.selection.tier;selector_id=[string]$selector.selector_id;selector_path=$inputs.selector_path;selector_sha256=$inputs.selector_sha256;evidence_path_sha256=[string]$selector.selection.output_evidence.canonical_path_sha256}
        Assert-CandidateRevisionEqual $expected $selection 'completed selector tuple'
        if($declared){&$selectorOwner {param($w,$u,$s)Get-MorphospaceDeclaredTierProducer $w $u $s} $Workspace $unit $selector|Out-Null}
    }
    # A prospective receipt never enters this path. Only the current committed
    # checkpoint is consumed, using the original native receipt predicate and
    # selector-derived matrix before its exact raw binding enters the closure.
    if($null-ne$state.validation_checkpoint){
        $inputs.consumed_receipt_path=[string]$state.validation_checkpoint.receipt
        $receiptPath=Resolve-MorphospaceWorkspacePath $Workspace $inputs.consumed_receipt_path -RequireLeaf
        $inputs.consumed_receipt_sha256=Get-MorphospaceFileSha256 $receiptPath
        $receipt=Read-MorphospaceProtocolJson $receiptPath
        if($null-ne$selection){
            $rows=@($matrix|Where-Object profile_id -CEQ ([string]$selector.declared_gate.profile_id))
            if($rows.Count-ne1){throw 'Completed candidate replay lacks the exact selected gate.'}
            $gates=@($receipt.gates|Where-Object gate_id -CEQ ([string]$rows[0].gate_id))
            if($gates.Count-ne1-or@($gates[0].evidence_refs).Count-ne1){throw 'Completed candidate replay lacks the exact selected evidence reference.'}
            $artifacts=@($receipt.artifacts|Where-Object artifact_id -CEQ ([string]$gates[0].evidence_refs[0]))
            if($artifacts.Count-ne1){throw 'Completed candidate replay selected evidence is ambiguous.'}
            $evidence=if([IO.Path]::IsPathFullyQualified([string]$artifacts[0].path)){[string]$artifacts[0].path}else{Join-Path (Split-Path $receiptPath -Parent) ([string]$artifacts[0].path)}
            $resolved=&$selectorOwner {param($w,$u,$s,$m,$spec,$path)
                Resolve-MorphospaceNormalValidationSelector -WorkspaceRoot $w -SelectorReference ([string]$s.selector_path) -ExpectedSelectorSha256 ([string]$s.selector_sha256) -EvidencePath $path -Spec $spec -Unit $u -DeclaredValidationMatrix $m -Action Accept -ValidationTier ([string]$s.tier) -BoundSelection $s
            } $Workspace $unit $selection $matrix $spec $evidence
            $matrix=@($resolved.validation_matrix)
        }
        $map=Get-MorphospaceCandidateRepositoryMap $Workspace ([string]$Candidate.expected.repository_map_path)
        $observed=@(foreach($scope in @($unit.allowed_repositories)){
            if(-not$map.ContainsKey([string]$scope.repo_id)){throw 'Completed candidate replay source repository is absent.'}
            Get-MorphospaceRepositoryState -RepoId ([string]$scope.repo_id) -Path ([string]$map[[string]$scope.repo_id].path)
        })
        &$automation {param($w,$r,$spec,$u,$map,$observed,$m,$checkpoint)
            Test-MorphospaceValidationReceipt -WorkspaceRoot $w -ReceiptReference $r -Spec $spec -Unit $u -RepositoryMap $map -RepositoryStates $observed -ValidationMatrix $m -ExpectedResult ([string]$checkpoint.result) -ExpectedTier ([string]$checkpoint.tier)
        } $Workspace $inputs.consumed_receipt_path $spec $unit $map $observed $matrix $state.validation_checkpoint|Out-Null
        if((Get-MorphospaceFileSha256 $receiptPath)-cne$inputs.consumed_receipt_sha256){throw 'Completed candidate replay receipt changed during its native predicate.'}
    }
    return $inputs
}
function Get-MorphospaceCandidateNonpassContinuation {
    # Read only the closed owner journey between this exact Freeze and endpoint.
    # Historical and recovery callers supply projections already bound by their
    # intent; no caller can supply a successful proof or an alternate verifier.
    param([string]$Workspace,[object]$Unit,[object]$State,[string]$ReturnEventId='')
    $id=[string]$Unit.unit_id
    if([string]$Unit.status-cne'active'-or[string]$State.current_unit-cne$id-or$null-ne$State.next_ready_unit-or@($State.blockers).Count-ne0-or$null-ne$State.pending_push_bundle-or$Unit.PSObject.Properties.Name-cnotcontains'candidate_freeze'){
        throw 'Candidate nonpass continuation requires the exact blocker-free frozen active owner.'
    }
    $events=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_}|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$_))})
    $freezeEvent="$([string]$Unit.candidate_freeze.freeze_id)-recorded"
    $starts=@($events|Where-Object event_id -CEQ $freezeEvent);$ends=@($events|Where-Object event_id -CEQ ([string]$State.last_event_id))
    if($starts.Count-ne1-or$ends.Count-ne1-or[int]$ends[0].sequence-lt[int]$starts[0].sequence){throw 'Candidate nonpass continuation lacks its unique Freeze and endpoint.'}
    $slice=@($events|Where-Object{[int]$_.sequence-ge[int]$starts[0].sequence-and[int]$_.sequence-le[int]$ends[0].sequence})
    $retirement=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
    $development=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceDevelopmentContinuation.psm1') -PassThru
    $frozen=Get-CandidateRevisionTransition $Workspace $freezeEvent $id
    $freezePath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Unit.candidate_freeze.receipt_path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $freezePath)-cne[string]$Unit.candidate_freeze.receipt_sha256){throw 'Candidate nonpass continuation original freeze bytes drifted.'}
    $candidate=Read-MorphospaceProtocolJson $freezePath
    [void](Get-MorphospaceFrozenCandidateTransition $Workspace $candidate $frozen.intent.target.state.document $frozen.intent.target.unit.document ([string]$Unit.candidate_freeze.receipt_path))
    Assert-CandidateRevisionEqual $Unit.candidate_freeze $frozen.intent.target.unit.document.candidate_freeze 'nonpass original marker'
    $previous=$frozen;$records=@([pscustomobject]@{event=$starts[0];transition=$frozen;kind='freeze'});$returned=$null;$phase='begin'
    for($index=1;$index-lt$slice.Count;$index++){
        $event=$slice[$index];$proof=Get-CandidateRevisionTransition $Workspace ([string]$event.event_id) $id;$intent=$proof.intent
        if([int]$event.sequence-ne([int]$starts[0].sequence+$index)-or[string]$event.unit_id-cne$id-or[string]$event.project_id-cne[string]$Unit.project_id-or
            [string]$intent.expected.event_tail_id-cne[string]$previous.intent.event.event_id-or[string]$intent.pre.state.sha256-cne[string]$previous.intent.target.state.sha256-or[string]$intent.pre.unit.sha256-cne[string]$previous.intent.target.unit.sha256){throw 'Candidate nonpass continuation sequence or state/unit join is detached.'}
        Assert-CandidateRevisionEqual $event $intent.event 'nonpass physical event'
        $documents=@($intent.artifacts|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))})
        $upgrades=@($documents|Where-Object schema -CEQ 'rusty.morphospace.workflow.tooling_context_upgrade.v1')
        $kind=''
        if($phase-ceq'begin'){
            if([string]$event.event_id-cnotmatch('^'+[regex]::Escape($id)+'-validating-[0-9]{4,}$')){throw 'Candidate nonpass continuation requires immediate ordinary BeginValidation.'}
            if($slice.Count-eq3){
                # Preserve the original direct revision route, including its
                # initial Quick selector. Its original contract binds the full
                # committed Begin state and exact status-only unit transform.
                if([string]$event.summary-cne'Entered validation with a deterministic command, instruction, graph, and device-impact plan.'-or@($event.receipts).Count-ne0-or@($intent.artifacts).Count-ne0){throw 'Candidate revision requires its exact ordinary BeginValidation.'}
                $beginUnit=$frozen.intent.target.unit.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String;$beginUnit.status='validating'
                Assert-CandidateRevisionEqual $beginUnit $intent.target.unit.document 'direct BeginValidation unit'
            }else{
                &$retirement {param($w,$e,$p)Assert-ActiveRetirementRetainedLifecycle $w $e $p} $Workspace $event $proof
            }
            $phase='validating';$kind='begin'
        }elseif($upgrades.Count-eq1){
            $upgradeOwner=Import-Module (Join-Path $PSScriptRoot 'ToolingContextUpgrade.psm1') -PassThru
            $projection=$upgrades[0].product_projection
            if([string]$projection.source_composition.path-cne[string]$candidate.expected.source_composition_path-or[string]$projection.source_composition.sha256-cne[string]$candidate.expected.source_composition_sha256-or
                [string]$projection.repository_map.path-cne[string]$candidate.expected.repository_map_path-or[string]$projection.repository_map.sha256-cne[string]$candidate.expected.repository_map_sha256){throw 'Candidate nonpass tooling upgrade changes its frozen source or map.'}
            &$upgradeOwner {param($w,$e,$p,$projection)Assert-ToolingContextHistoricalTransition -WorkspaceRoot $w -ExpectedEvent $e -Transition $p -ExpectedProductProjection $projection} $Workspace $event $proof $projection|Out-Null
            $kind='tooling-upgrade'
        }elseif($phase-ceq'validating'-and[string]$event.summary-ceq'Completed the exact declared instruction-surface set after stable content observation without executing validation commands.'){
            $beforeUnit=$previous.intent.target.unit.document;$beforeState=$previous.intent.target.state.document
            &$development {param($before,$after,$i,$e)Assert-DevelopmentContinuationRetainedAuthority $before $after $i $e} $beforeUnit $intent.target.unit.document $intent $event
            $instruction=@($documents|Where-Object schema -CEQ 'rusty.morphospace.workflow.work_unit_automation_receipt.v1')
            if($instruction.Count-ne1-or@($intent.artifacts).Count-ne1){throw 'Candidate nonpass instruction completion lacks its exact owner receipt.'}
            # Reconstruct the producer's clean writable observations from its
            # exact retained receipt. Dirty summaries omit porcelain, so retain
            # the existing owner's refusal instead of copying a fingerprint.
            $expectedState=$beforeState|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
            &$retirement {param($s,$u,$r)Set-ActiveRetirementInstructionRepositoryProjection $s $u $r} $expectedState $beforeUnit $instruction[0]
            $expectedState.last_event_id=[string]$event.event_id
            Assert-CandidateRevisionEqual $expectedState $intent.target.state.document 'instruction target state'
            $kind='instruction-completion'
        }elseif($phase-ceq'validating'-and[string]$event.event_id-cmatch('^'+[regex]::Escape($id)+'-validation-(fail|partial|blocked)-return-[0-9]{4,}$')){
            &$retirement {param($w,$e,$p)Assert-ActiveRetirementRetainedLifecycle $w $e $p} $Workspace $event $proof
            $returned=$proof;$phase='returned';$kind='return'
        }else{throw 'Candidate nonpass continuation contains an unsupported or interleaved owner action.'}
        $fences=@(if($intent.PSObject.Properties.Name-ccontains'additional_projections'){$intent.additional_projections})
        foreach($fence in $fences){
            $name=switch -CaseSensitive ([string]$fence.path){'project.spec.json'{'project_sha256'};'feature.lock.json'{'feature_lock_sha256'};default{throw 'Candidate nonpass continuation has an unknown authority fence.'}}
            if([string]$fence.pre_sha256-cne[string]$candidate.expected.$name-or[string]$fence.target_sha256-cne[string]$candidate.expected.$name-or(Get-MorphospaceCanonicalJsonSha256 $fence.document)-cne[string]$candidate.expected.$name){throw 'Candidate nonpass continuation changes frozen product authority.'}
        }
        $records+=,[pscustomobject]@{event=$event;transition=$proof;kind=$kind};$previous=$proof
    }
    if($null-eq$returned-or($ReturnEventId-and[string]$returned.intent.event.event_id-cne$ReturnEventId)){throw 'Candidate nonpass continuation lacks its exact retained ReturnToActive.'}
    Assert-CandidateRevisionEqual $Unit $previous.intent.target.unit.document 'nonpass endpoint unit'
    Assert-CandidateRevisionEqual $State $previous.intent.target.state.document 'nonpass endpoint state'
    [pscustomobject]@{frozen=$frozen;returned=$returned;endpoint=$previous;records=$records}
}
function Assert-MorphospaceCandidateRevisionPredecessor {
    param([string]$Workspace,[object]$Candidate,[object]$BeforeUnit,[object]$BeforeState,[int]$Depth=0)
    if($Depth-ge32){throw 'Candidate revision predecessor chain exceeds the supported depth.'}
    $owner=Split-Path $PSScriptRoot -Parent
    if(-not(Test-Json -Json ($Candidate|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $owner 'schemas/candidate-freeze-v3.schema.json'))){throw 'Candidate revision schema is invalid.'}
    $id=[string]$Candidate.unit_id;$predecessor=$Candidate.predecessor
    if([string]$BeforeUnit.unit_id-cne$id-or[string]$BeforeUnit.project_id-cne[string]$Candidate.project_id-or[string]$BeforeUnit.status-cne'active'-or[string]$BeforeState.current_unit-cne$id-or$null-ne$BeforeState.next_ready_unit-or@($BeforeState.blockers).Count-ne0-or($BeforeUnit.PSObject.Properties.Name-contains'work_mode'-and[string]$BeforeUnit.work_mode-cne'feature')){throw 'Candidate revision requires the same blocker-free active feature owner.'}
    Assert-CandidateRevisionEqual $BeforeUnit.candidate_freeze $predecessor.freeze 'predecessor marker'
    if([string]$Candidate.freeze_id-ceq[string]$predecessor.freeze.freeze_id){throw 'Candidate revision requires a fresh identity after ReturnToActive.'}
    $oldPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$predecessor.freeze.receipt_path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $oldPath)-cne[string]$predecessor.freeze.receipt_sha256){throw 'Candidate revision predecessor freeze bytes drifted.'}
    $old=Read-MorphospaceProtocolJson $oldPath
    if([string]$old.schema-cnotin@('rusty.morphospace.workflow.candidate_freeze.v1','rusty.morphospace.workflow.candidate_freeze.v3')-or[string]$old.freeze_id-cne[string]$predecessor.freeze.freeze_id-or[string]$old.unit_id-cne$id-or[string]$old.project_id-cne[string]$Candidate.project_id){throw 'Candidate revision predecessor identity is detached.'}
    $oldSchema=if([string]$old.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v1'){'candidate-freeze-v1.schema.json'}else{'candidate-freeze-v3.schema.json'}
    if(-not(Test-Json -Json ($old|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $owner "schemas/$oldSchema"))){throw 'Candidate revision predecessor schema is invalid.'}
    $frozen=Get-CandidateRevisionTransition $Workspace "$([string]$old.freeze_id)-recorded" $id
    [void](Get-MorphospaceFrozenCandidateTransition $Workspace $old $frozen.intent.target.state.document $frozen.intent.target.unit.document ([string]$predecessor.freeze.receipt_path))
    $originalUnit=$frozen.intent.target.unit.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
    if([string]$old.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v1'){$originalUnit.PSObject.Properties.Remove('candidate_freeze')}else{$originalUnit.candidate_freeze=$old.predecessor.freeze}
    if((Get-MorphospaceCanonicalJsonSha256 $originalUnit)-cne[string]$old.expected.unit_sha256){throw 'Candidate revision original freeze changed its admitted unit authority.'}
    if([string]$old.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3'){
        $oldEndpoint=Get-CandidateRevisionTransition $Workspace ([string]$old.expected.event_tail_id) $id
        Assert-MorphospaceCandidateRevisionPredecessor $Workspace $old $oldEndpoint.intent.target.unit.document $oldEndpoint.intent.target.state.document ($Depth+1)
        $oldState=$oldEndpoint.intent.target.state.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
        $oldState.last_event_id="$($old.freeze_id)-recorded";$oldState.validation_checkpoint=$null
        if($oldState.PSObject.Properties.Name-contains'normal_validation_selection'){$oldState.normal_validation_selection=$null}
        Assert-CandidateRevisionEqual $oldState $frozen.intent.target.state.document 'predecessor revision target state'
    }
    $journey=Get-MorphospaceCandidateNonpassContinuation $Workspace $BeforeUnit $BeforeState ([string]$predecessor.return_event_id)
    $returned=$journey.returned;$returnEvent=$returned.intent.event
    $checkpoint=$returned.intent.target.state.document.validation_checkpoint;$result=[string]$checkpoint.result
    if($result-cnotin@('fail','blocked','partial')-or[string]$returnEvent.event_id-cnotmatch('^'+[regex]::Escape($id)+'-validation-'+[regex]::Escape($result)+'-return-[0-9]{4,}$')-or[string]$returnEvent.event_type-cne'validation'-or[string]$returnEvent.summary-cne'Retained a non-passing validation attempt and returned the same feature unit to active for an in-scope correction.'-or@($returnEvent.receipts).Count-ne2-or[string]$returnEvent.receipts[0]-cne[string]$checkpoint.receipt-or[string]$returnEvent.receipts[1]-cne[string]$predecessor.validation_receipt.path){throw 'Candidate revision lacks the exact retained non-passing ReturnToActive attempt.'}
    $artifacts=@($returned.intent.artifacts)
    if($artifacts.Count-ne1-or[string]$artifacts[0].path-cne[string]$predecessor.validation_receipt.path-or[string]$artifacts[0].sha256-cne[string]$predecessor.validation_receipt.sha256){throw 'Candidate revision failed receipt is not owned by ReturnToActive.'}
    foreach($relative in @([string]$checkpoint.receipt,[string]$predecessor.validation_receipt.path)){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf))-cne[string]$predecessor.validation_receipt.sha256){throw 'Candidate revision failed receipt bytes drifted.'}}
    $receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$predecessor.validation_receipt.path) -RequireLeaf)
    if([string]$receipt.schema-cne'rusty.morphospace.workflow.validation_receipt.v1'-or[string]$receipt.unit_id-cne$id-or[string]$receipt.project_id-cne[string]$Candidate.project_id-or[string]$receipt.result-cne$result-or[string]$receipt.tier-cne[string]$checkpoint.tier){throw 'Candidate revision failed receipt identity is detached.'}
    if(-not(Test-Json -Json ($receipt|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $owner 'schemas/validation-receipt.schema.json'))){throw 'Candidate revision failed receipt schema is invalid.'}
    $artifactIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $receiptDirectory=Split-Path (Resolve-MorphospaceWorkspacePath $Workspace ([string]$checkpoint.receipt) -RequireLeaf) -Parent
    foreach($artifact in @($receipt.artifacts)){
        $artifactPath=if([IO.Path]::IsPathFullyQualified([string]$artifact.path)){[string]$artifact.path}else{Join-Path $receiptDirectory ([string]$artifact.path)}
        if(-not$artifactIds.Add([string]$artifact.artifact_id)-or(Get-MorphospaceFileSha256 $artifactPath)-cne([string]$artifact.sha256).ToLowerInvariant()){throw 'Candidate revision failed validation evidence bytes drifted.'}
    }
    foreach($evidence in @($receipt.criteria)+@($receipt.gates)+@(if($null-ne$receipt.device_validation){$receipt.device_validation})){foreach($reference in @($evidence.evidence_refs)){if(-not$artifactIds.Contains([string]$reference)){throw 'Candidate revision failed receipt references unknown evidence.'}}}
    foreach($repository in @($old.final_repositories)){
        $revisions=@($receipt.repository_revisions|Where-Object{[string]$_.repo_id-ceq[string]$repository.repo_id})
        if($revisions.Count-ne1-or[string]$revisions[0].head_revision-cne[string]$repository.commit){throw 'Candidate revision failed attempt source differs from its predecessor freeze.'}
    }
    foreach($name in @('project_sha256','feature_lock_sha256','source_composition_path','source_composition_sha256','repository_map_path','repository_map_sha256')){if([string]$Candidate.expected.$name-cne[string]$old.expected.$name){throw "Candidate revision changes frozen authority input '$name'."}}
    if([string]$Candidate.expected.state_sha256-cne[string]$journey.endpoint.intent.target.state.sha256-or[string]$Candidate.expected.unit_sha256-cne[string]$journey.endpoint.intent.target.unit.sha256-or[string]$Candidate.expected.event_tail_id-cne[string]$journey.endpoint.intent.event.event_id){throw 'Candidate revision CAS is detached from its authenticated correction endpoint.'}
    # Approval and validation identities are not carried to the changed source.
    return $journey.endpoint
}
function Assert-MorphospaceCandidateRevisionRecoveryBindings {
    param([string]$WorkspaceRoot,[object]$Intent,[switch]$Historical)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    if(@($Intent.artifacts).Count-ne1){throw 'Candidate revision requires one transaction-owned freeze artifact.'}
    $artifact=$Intent.artifacts[0];$bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64)
    if((Get-MorphospaceSha256Bytes $bytes)-cne[string]$artifact.sha256){throw 'Candidate revision artifact bytes drifted.'}
    $candidate=ConvertFrom-MorphospaceProtocolJsonBytes $bytes
    if([string]$candidate.source_composition.path-cne[string]$candidate.expected.source_composition_path-or[string]$candidate.source_composition.sha256-cne[string]$candidate.expected.source_composition_sha256-or[string]$candidate.feature_lock.sha256-cne[string]$candidate.expected.feature_lock_sha256){throw 'Candidate revision source or feature closure detaches from its CAS.'}
    $endpoint=Get-CandidateRevisionTransition $workspace ([string]$candidate.expected.event_tail_id) ([string]$candidate.unit_id)
    [void](Assert-MorphospaceCandidateRevisionPredecessor $workspace $candidate $endpoint.intent.target.unit.document $endpoint.intent.target.state.document)
    $targetUnit=$endpoint.intent.target.unit.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
    $targetUnit.candidate_freeze=[pscustomobject]@{freeze_id=$candidate.freeze_id;receipt_path="receipts/$($candidate.freeze_id).json";receipt_sha256=$artifact.sha256}
    $targetState=$endpoint.intent.target.state.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
    $eventId="$($candidate.freeze_id)-recorded";$targetState.last_event_id=$eventId
    $targetState.validation_checkpoint=$null
    if($targetState.PSObject.Properties.Name-contains'normal_validation_selection'){$targetState.normal_validation_selection=$null}
    Assert-CandidateRevisionEqual $targetUnit $Intent.target.unit.document 'revision target unit'
    Assert-CandidateRevisionEqual $targetState $Intent.target.state.document 'revision target state'
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v3'-or[string]$Intent.transaction_id-cne"$eventId-transition"-or[string]$Intent.event.event_id-cne$eventId-or[string]$Intent.event.summary-cne'Froze a linked in-scope candidate correction after retaining the non-passing validation attempt.'-or[string]$Intent.event.unit_id-cne[string]$candidate.unit_id-or[string]$Intent.event.project_id-cne[string]$candidate.project_id-or[string]$Intent.event.event_type-cne'state-transition'-or[int]$Intent.event.sequence-ne([int]$endpoint.intent.event.sequence+1)-or@($Intent.event.receipts).Count-ne1-or[string]$Intent.event.receipts[0]-cne[string]$artifact.path-or[string]$artifact.path-cne"receipts/$($candidate.freeze_id).json"-or[string]$Intent.pre.state.sha256-cne[string]$candidate.expected.state_sha256-or[string]$Intent.pre.unit.sha256-cne[string]$candidate.expected.unit_sha256-or[string]$Intent.expected.event_tail_id-cne[string]$candidate.expected.event_tail_id-or[string]$Intent.expected.events_sha256-cne[string]$candidate.expected.events_sha256-or[int64]$Intent.expected.events_length-ne[int64]$candidate.expected.events_length){throw 'Candidate revision transition is detached.'}
    if(@($Intent.additional_projections).Count-ne2){throw 'Candidate revision authority fences are incomplete.'}
    $fences=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($projection in @($Intent.additional_projections)){$name=switch -CaseSensitive ([string]$projection.path){'project.spec.json'{'project_sha256'};'feature.lock.json'{'feature_lock_sha256'};default{throw 'Candidate revision contains an unknown authority fence.'}};if(-not$fences.Add([string]$projection.path)-or[string]$projection.pre_sha256-cne[string]$candidate.expected.$name-or[string]$projection.target_sha256-cne[string]$candidate.expected.$name-or(Get-MorphospaceCanonicalJsonSha256 $projection.document)-cne[string]$candidate.expected.$name){throw 'Candidate revision authority fence changes its projection.'}}
    Assert-MorphospaceFrozenCandidateScope $candidate $targetUnit
    if($Historical){return}
    foreach($pair in @(@('project.spec.json','project_sha256'),@('feature.lock.json','feature_lock_sha256'))){if((Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $pair[0] -RequireLeaf)))-cne[string]$candidate.expected.($pair[1])){throw 'Candidate revision live authority fence drifted.'}}
    $featureLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf)
    if([int]$candidate.feature_lock.revision-ne[int]$featureLock.revision){throw 'Candidate revision feature-lock revision drifted.'}
    foreach($pair in @(@('source_composition_path','source_composition_sha256'),@('repository_map_path','repository_map_sha256'))){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.expected.($pair[0])) -RequireLeaf))-cne[string]$candidate.expected.($pair[1])){throw 'Candidate revision live source binding drifted.'}}
    # The original freeze and contiguous owner transactions authenticate this
    # unchanged lock. Recovery may have installed the new projection already.
    $composition=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.source_composition.path) -RequireLeaf)
    $frozenTransition=[pscustomobject]@{intent=$Intent;intent_path="receipts/transactions/$($Intent.transaction_id).intent.json";completion_path="receipts/transactions/$($Intent.transaction_id).completion.json"}
    if($targetUnit.PSObject.Properties.Name-ccontains'tooling_context'){
        $paths=Get-MorphospaceCandidateTransitionPaths $workspace ([string]$Intent.transaction_id)
        if([IO.File]::Exists((Resolve-MorphospaceWorkspacePath $workspace ([string]$paths.completion)))){
            $completed=Get-CandidateRevisionTransition $workspace ([string]$Intent.event.event_id) ([string]$candidate.unit_id)
            Assert-CandidateRevisionEqual $Intent $completed.intent 'completed physical intent'
            $effective=Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId ([string]$candidate.unit_id) -RepositoryMapPath (Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.expected.repository_map_path) -RequireLeaf)
            $inputs=Get-MorphospaceCandidateCompletedReplayInputs $workspace $candidate $effective.continuation
            Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $effective.effective.unit $completed $composition -PlanningInputs $inputs
        }elseif([IO.File]::Exists((Resolve-MorphospaceWorkspacePath $workspace ([string]$paths.intent)))){
            Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $targetUnit $frozenTransition $composition -PendingRevisionIntent $Intent
        }else{
            # Start invokes this owner before publishing its durable intent.
            # There is no pending projection allowance at this boundary: the
            # complete live unit/state must still be the authenticated endpoint.
            $liveUnit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace "iteration-units/$($candidate.unit_id).json" -RequireLeaf)
            $liveState=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
            Assert-CandidateRevisionEqual $endpoint.intent.target.unit.document $liveUnit 'before-intent live unit'
            Assert-CandidateRevisionEqual $endpoint.intent.target.state.document $liveState 'before-intent live state'
            $predecessorTransition=Get-CandidateRevisionTransition $workspace "$([string]$candidate.predecessor.freeze.freeze_id)-recorded" ([string]$candidate.unit_id)
            $inputs=[pscustomobject]@{selector_path='';selector_sha256='';consumed_receipt_path='';consumed_receipt_sha256=''}
            Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $liveUnit $predecessorTransition $composition -PlanningInputs $inputs
        }
    }else{
        Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $targetUnit $frozenTransition $composition
    }
}
function Get-MorphospaceFrozenCandidateToolingProjection {
    param([string]$Workspace,[object]$Candidate,[object]$LiveState,[object]$LiveUnit,[string]$ReceiptRelative)
    # A typed compatible upgrade changes the live pointer, never the original
    # frozen unit/hash. Reconstruct that original view only through the complete
    # committed continuation and its authenticated immediate Freeze/Begin slot.
    $frozen=Get-CandidateRevisionTransition $Workspace "$([string]$Candidate.freeze_id)-recorded" ([string]$Candidate.unit_id)
    $originalUnit=$frozen.intent.target.unit.document;$originalState=$frozen.intent.target.state.document
    [void](Get-MorphospaceFrozenCandidateTransition $Workspace $Candidate $originalState $originalUnit $ReceiptRelative)
    if($LiveUnit.PSObject.Properties.Name-cnotcontains'tooling_context'-or$originalUnit.PSObject.Properties.Name-cnotcontains'tooling_context'-or[string]$LiveUnit.status-cne'validating'-or[string]$LiveState.current_unit-cne[string]$Candidate.unit_id){throw 'Frozen tooling projection requires the same current validating owner.'}
    Assert-CandidateRevisionEqual $LiveUnit.candidate_freeze $originalUnit.candidate_freeze 'tooling upgrade frozen marker'
    $map=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Candidate.expected.repository_map_path) -RequireLeaf
    $effective=Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $Workspace -UnitId ([string]$Candidate.unit_id) -RepositoryMapPath $map
    Assert-CandidateRevisionEqual $LiveUnit $effective.effective.unit 'tooling upgrade live unit'
    Assert-CandidateRevisionEqual $LiveState $effective.effective.state 'tooling upgrade live state'
    $upgrades=@($effective.tooling_upgrades|Where-Object{
        [int]$_.intent.event.sequence-gt[int]$frozen.intent.event.sequence-and
        (Get-MorphospaceCanonicalJsonSha256 $_.intent.target.unit.document.tooling_context)-ceq(Get-MorphospaceCanonicalJsonSha256 $LiveUnit.tooling_context)
    })
    if($upgrades.Count-ne1){throw 'Frozen tooling projection requires one authenticated upgrade to the selected live pointer.'}
    $before=$originalUnit|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String;$before.status='validating'
    if((Get-MorphospaceCanonicalJsonSha256 $before)-cne[string]$upgrades[0].intent.pre.unit.sha256){throw 'Frozen tooling upgrade preimage differs from the original frozen unit.'}
    $after=$before|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String;$after.tooling_context=$LiveUnit.tooling_context
    Assert-CandidateRevisionEqual $after $upgrades[0].intent.target.unit.document 'tooling upgrade pointer-only target'
    [pscustomobject]@{unit=$originalUnit;state=$originalState;event_tail=$effective.effective.event_tail}
}
function Test-MorphospaceFrozenCandidate {
    param([string]$WorkspaceRoot,[object]$Unit,[object]$PlanningInputs=$null)
    # This applies to all units.  It is deliberately before the W-016
    # admission branch so a historical evidence declaration cannot bypass the
    # post-Claim, task-local materialization gate on a legacy-shaped unit.
    [void](Test-MorphospaceInheritedCandidateMaterializationGate -WorkspaceRoot $WorkspaceRoot -Unit $Unit)
    if(-not($Unit.PSObject.Properties.Name -contains 'agent_scope_assessment')){return $true}
    if(-not($Unit.PSObject.Properties.Name -contains 'candidate_freeze')){throw 'This admitted development unit must be frozen before validation.'}
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$freeze=$Unit.candidate_freeze;$path=Resolve-MorphospaceWorkspacePath $workspace ([string]$freeze.receipt_path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $path) -cne [string]$freeze.receipt_sha256){throw 'Frozen candidate receipt hash drifted.'}
    $repoRoot=Split-Path $PSScriptRoot -Parent
    $candidate=Read-MorphospaceProtocolJson $path
    if([string]$candidate.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v2'){
        if(-not(Test-Json -Json (Get-Content -Raw $path) -SchemaFile (Join-Path $repoRoot 'schemas\candidate-freeze-v2.schema.json'))){throw 'Rematerialized frozen candidate receipt is malformed.'}
        Import-Module (Join-Path $PSScriptRoot 'ValidatingCandidateRematerialization.psm1') -Force
        return [bool](Test-MorphospaceRematerializedCandidate -WorkspaceRoot $workspace -Unit $Unit)
    }
    $schema=if([string]$candidate.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3'){'candidate-freeze-v3.schema.json'}else{'candidate-freeze-v1.schema.json'}
    if([string]$candidate.schema-cnotin@('rusty.morphospace.workflow.candidate_freeze.v1','rusty.morphospace.workflow.candidate_freeze.v3')-or-not(Test-Json -Json (Get-Content -Raw $path) -SchemaFile (Join-Path $repoRoot "schemas/$schema"))){throw 'Frozen candidate receipt is malformed.'}
    if([string]$candidate.freeze_id -cne [string]$freeze.freeze_id -or [string]$candidate.unit_id -cne [string]$Unit.unit_id){throw 'Frozen candidate receipt identity does not match its unit marker.'}
    $unitPath="iteration-units/$([string]$Unit.unit_id).json";$liveUnit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    $project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf);$featureLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf)
    $toolingProjection=$null
    if($liveUnit.PSObject.Properties.Name-ccontains'tooling_context'){
        $original=Get-CandidateRevisionTransition $workspace "$([string]$candidate.freeze_id)-recorded" ([string]$candidate.unit_id)
        if((Get-MorphospaceCanonicalJsonSha256 $liveUnit.tooling_context)-cne(Get-MorphospaceCanonicalJsonSha256 $original.intent.target.unit.document.tooling_context)){
            $toolingProjection=Get-MorphospaceFrozenCandidateToolingProjection $workspace $candidate $state $liveUnit ([string]$freeze.receipt_path)
            $liveUnit=$toolingProjection.unit|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
            $state=$toolingProjection.state|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
        }
    }
    if([string]$candidate.project_id -cne [string]$project.project_id -or [string]$candidate.unit_id -cne [string]$liveUnit.unit_id -or [string]$state.current_unit -cne [string]$liveUnit.unit_id -or [string]$state.last_event_id -cne "$([string]$candidate.freeze_id)-recorded"){throw 'Frozen candidate identity no longer matches the live active authority.'}
    $marker=$liveUnit.candidate_freeze;if([string]$candidate.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3'){$liveUnit.candidate_freeze=$candidate.predecessor.freeze}else{$liveUnit.PSObject.Properties.Remove('candidate_freeze')}
    foreach($check in @(@{e=$candidate.expected.project_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $project);n='project'},@{e=$candidate.expected.unit_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $liveUnit);n='unit'},@{e=$candidate.expected.feature_lock_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $featureLock);n='feature lock'},@{e=$candidate.expected.source_composition_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $candidate.expected.source_composition_path -RequireLeaf));n='source composition'},@{e=$candidate.expected.repository_map_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $candidate.expected.repository_map_path -RequireLeaf));n='repository map'})){if([string]$check.e -cne [string]$check.a){throw "Frozen candidate $($check.n) drifted after freeze."}}
    if([string]$candidate.source_composition.path -cne [string]$candidate.expected.source_composition_path -or [string]$candidate.source_composition.sha256 -cne [string]$candidate.expected.source_composition_sha256){throw 'Frozen source-composition closure no longer matches its receipt CAS binding.'}
    if([int]$candidate.feature_lock.revision -ne [int]$featureLock.revision -or [string]$candidate.feature_lock.sha256 -cne [string]$candidate.expected.feature_lock_sha256){throw 'Frozen feature-lock closure no longer matches its receipt CAS binding.'}
    Assert-MorphospaceFrozenCandidateScope $candidate $liveUnit
    $liveUnit|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue $marker -Force
    $frozenTransition=Get-MorphospaceFrozenCandidateTransition $workspace $candidate $state $liveUnit ([string]$freeze.receipt_path)
    if([string]$candidate.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3'){Assert-MorphospaceCandidateRevisionRecoveryBindings $workspace $frozenTransition.intent}
    if($null-eq$PlanningInputs-and$null-ne$toolingProjection){$PlanningInputs=[pscustomobject]@{selector_path='';selector_sha256='';consumed_receipt_path='';consumed_receipt_sha256=''}}
    Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $liveUnit $frozenTransition -PlanningInputs $PlanningInputs
    $eventLines=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_})
    $tail=$eventLines[-1]|ConvertFrom-Json
    $expectedTail=if($null-ne$toolingProjection){[string]$toolingProjection.event_tail.event_id}else{"$([string]$candidate.freeze_id)-recorded"}
    if([string]$tail.event_id-cne$expectedTail){throw 'Frozen candidate transition is no longer the exact ledger tail.'}
    return $true
}
function Invoke-MorphospaceFreezeCandidate {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$UnitId,[string]$CandidateFreeze,[string]$ExpectedCandidateFreezeSha256='',[string]$Timestamp='',[string]$OutPath,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none',[switch]$Execute)
    $repoRoot=Split-Path $PSScriptRoot -Parent;$workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $CandidateFreeze).Path
    $inputDocument=Read-MorphospaceProtocolJson $input;$isRevision=[string]$inputDocument.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3';$schema=if($isRevision){'candidate-freeze-v3.schema.json'}else{'candidate-freeze-v1.schema.json'}
    if(-not(Test-Json -Json (Get-Content -Raw $input) -SchemaFile (Join-Path $repoRoot "schemas/$schema"))){throw 'Candidate freeze does not satisfy its schema.'}
    $candidate=Read-MorphospaceProtocolJson $input;$project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf);$unitPath="iteration-units/$UnitId.json";$unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf);$featureLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf);$eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf;$events=@(Get-Content $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json});$tail=$events[-1]
    if($isRevision){
        $revisionHash=Get-MorphospaceFileSha256 $input
        $revisionRelative="receipts/$($candidate.freeze_id).json";$revisionEvent="$($candidate.freeze_id)-recorded";$revisionTransaction="$revisionEvent-transition"
        $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$revisionTransaction.intent.json"
        if([IO.File]::Exists($intentPath)){
            if($ExpectedCandidateFreezeSha256-cne$revisionHash-or[IO.Path]::GetFullPath($OutPath)-cne(Resolve-MorphospaceWorkspacePath $workspace $revisionRelative)){throw 'Candidate revision replay requires its exact request hash and output path.'}
            $intent=Read-MorphospaceProtocolJson $intentPath
            if(@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].sha256-cne$revisionHash){throw 'Candidate revision replay input differs from the durable intent.'}
            Assert-MorphospaceCandidateRevisionRecoveryBindings $workspace $intent
            $completion=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$revisionTransaction.completion.json"
            if(-not[IO.File]::Exists($completion)){
                if(-not$Execute){throw 'Interrupted candidate revision requires executed recovery.'}
                Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $revisionTransaction -Repair -FaultAfter $FaultAfter|Out-Null
            }
            [void](Get-CandidateRevisionTransition $workspace $revisionEvent $UnitId)
            return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$project.project_id;unit_id=$UnitId;action='FreezeCandidate';timestamp=[string]$intent.event.timestamp;executed=$Execute.IsPresent;transition='candidate-already-frozen';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$revisionRelative;sha256=$revisionHash};event_id=$null}
        }
    }
    if([string]$candidate.project_id -cne [string]$project.project_id -or [string]$candidate.unit_id -cne $UnitId -or [string]$unit.status -cne 'active' -or [string]$state.current_unit -cne $UnitId){throw 'FreezeCandidate requires the matching active current unit.'}
    if($unit.PSObject.Properties.Name-contains'tooling_context'){
        [void](Get-MorphospaceUnitToolingContextObservation -WorkspaceRoot $workspace -UnitId $UnitId -Action FreezeCandidate -OwnerModule $MyInvocation.MyCommand.Module)
    }
    [void](Test-MorphospaceInheritedCandidateMaterializationGate -WorkspaceRoot $workspace -Unit $unit)
    if(-not($unit.PSObject.Properties.Name -contains 'agent_scope_assessment')){throw 'FreezeCandidate is reserved for development-envelope admitted units.'}
    $inputHash=Get-MorphospaceFileSha256 $input;$outRelative="receipts/$([string]$candidate.freeze_id).json"
    if($unit.PSObject.Properties.Name -contains 'candidate_freeze'){if([string]$unit.candidate_freeze.receipt_sha256 -ceq $inputHash -and [string]$unit.candidate_freeze.freeze_id -ceq [string]$candidate.freeze_id){return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$project.project_id;unit_id=$UnitId;action='FreezeCandidate';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='candidate-already-frozen';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$outRelative;sha256=$inputHash};event_id=$null}};if(-not$isRevision){throw 'Conflicting candidate freeze is rejected.'}}
    if($isRevision){[void](Assert-MorphospaceCandidateRevisionPredecessor $workspace $candidate $unit $state)}
    $e=$candidate.expected;foreach($check in @(@{e=$e.project_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $project);n='project'},@{e=$e.state_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $state);n='state'},@{e=$e.unit_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $unit);n='unit'},@{e=$e.feature_lock_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $featureLock);n='feature lock'},@{e=$e.source_composition_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $e.source_composition_path -RequireLeaf));n='source composition'},@{e=$e.repository_map_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $e.repository_map_path -RequireLeaf));n='repository map'},@{e=$e.events_sha256;a=(Get-MorphospaceFileSha256 $eventsPath);n='ledger'})){if([string]$check.e -cne [string]$check.a){throw "FreezeCandidate stale $($check.n) preimage (expected $($check.e), actual $($check.a), state-tail $($state.last_event_id))."}}
    if([int64]$e.events_length -ne ([IO.FileInfo]$eventsPath).Length -or [string]$e.event_tail_id -cne [string]$tail.event_id){throw 'FreezeCandidate stale ledger length or tail.'}
    if([string]$candidate.source_composition.path -cne [string]$e.source_composition_path -or [string]$candidate.source_composition.sha256 -cne [string]$e.source_composition_sha256){throw 'Frozen source-composition closure must exactly restate its CAS-bound source composition.'}
    if([int]$candidate.feature_lock.revision -ne [int]$featureLock.revision -or [string]$candidate.feature_lock.sha256 -cne [string]$e.feature_lock_sha256){throw 'Frozen feature-lock identity must exactly restate its CAS-bound feature lock.'}
    Assert-MorphospaceFrozenCandidateScope $candidate $unit
    if($isRevision-and$unit.PSObject.Properties.Name-ccontains'tooling_context'){
        $predecessorTransition=Get-CandidateRevisionTransition $workspace "$([string]$candidate.predecessor.freeze.freeze_id)-recorded" $UnitId
        $revisionPlanningInputs=[pscustomobject]@{selector_path='';selector_sha256='';consumed_receipt_path='';consumed_receipt_sha256=''}
        Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $unit $predecessorTransition -PlanningInputs $revisionPlanningInputs
    }else{
        Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $unit
    }
    if($ExpectedCandidateFreezeSha256 -and $ExpectedCandidateFreezeSha256 -cne $inputHash){throw 'Expected candidate-freeze hash does not match input.'};if($Execute -and -not $ExpectedCandidateFreezeSha256){throw 'Executed FreezeCandidate requires its dry-run SHA-256.'}
    $outFull=Resolve-MorphospaceWorkspacePath $workspace $outRelative;if([IO.Path]::GetFullPath($OutPath) -cne $outFull){throw "Candidate freeze output must be '$outRelative'."}
    if(-not $Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};$eventId="$([string]$candidate.freeze_id)-recorded";$targetUnit=($unit|ConvertTo-Json -Depth 64|ConvertFrom-Json);$targetUnit|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue ([ordered]@{freeze_id=$candidate.freeze_id;receipt_path=$outRelative;receipt_sha256=$inputHash}) -Force;$targetState=($state|ConvertTo-Json -Depth 64|ConvertFrom-Json);$targetState.last_event_id=$eventId;$event=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$tail.sequence+1;timestamp=$Timestamp;project_id=$project.project_id;unit_id=$UnitId;event_type='state-transition';summary='Froze the exact candidate closure before validation.';receipts=@($outRelative)}
    if($isRevision){$targetState.validation_checkpoint=$null;if($targetState.PSObject.Properties.Name-contains'normal_validation_selection'){$targetState.normal_validation_selection=$null};$event.summary='Froze a linked in-scope candidate correction after retaining the non-passing validation attempt.'}
    if($Execute){Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $unitPath -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event ([pscustomobject]$event) -ExpectedStateSha256 $e.state_sha256 -ExpectedUnitSha256 $e.unit_sha256 -ExpectedEventTailId $e.event_tail_id -ExpectedEventsSha256 $e.events_sha256 -ExpectedEventsLength $e.events_length -AdditionalProjections @([pscustomobject]@{path='feature.lock.json';expected_sha256=$e.feature_lock_sha256;document=$featureLock},[pscustomobject]@{path='project.spec.json';expected_sha256=$e.project_sha256;document=$project}) -Artifacts @([pscustomobject]@{source_path=$input;path=$outRelative;sha256=$inputHash}) -FaultAfter $FaultAfter|Out-Null}
    return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$project.project_id;unit_id=$UnitId;action='FreezeCandidate';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='candidate-frozen';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$outRelative;sha256=$inputHash};event_id=$(if($Execute){$eventId}else{$null})}
}
Export-ModuleMember -Function Invoke-MorphospaceFreezeCandidate,Test-MorphospaceFrozenCandidate,Assert-MorphospaceCandidateRevisionRecoveryBindings
