Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force

function Invoke-ReconstructionGit {
    param([string]$Path,[string[]]$Arguments,[switch]$AllowFailure)
    $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$output=@(& git -C $Path @Arguments 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    if($code-ne0-and-not$AllowFailure){throw "Prepared-publication reconstruction Git observation failed: git $($Arguments-join' ')"}
    [pscustomobject]@{code=$code;text=(($output|ForEach-Object{[string]$_})-join"`n").Trim()}
}
function Resolve-ReconstructionBinding {
    param([string]$Workspace,[object]$Binding)
    $path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Binding.path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $path)-cne[string]$Binding.sha256){throw "Prepared-publication reconstruction evidence hash mismatch for '$($Binding.path)'."}
    $path
}
function Assert-ReconstructionCanonicalBinding {
    param([object]$Actual,[object]$Binding,[string]$Name)
    $expected=[string]$Binding.sha256
    if((Get-MorphospaceCanonicalJsonSha256 $Actual)-cne$expected-or(Get-MorphospaceCanonicalJsonSha256 $Binding.value)-cne$expected){throw "Prepared-publication reconstruction $Name canonical hash mismatch."}
}
function Get-ReconstructionTransitionBinding {
    param([string]$Workspace,[object]$Binding,[string]$Name)
    $intentPath=Resolve-ReconstructionBinding $Workspace $Binding.intent
    $completionPath=Resolve-ReconstructionBinding $Workspace $Binding.completion
    $intent=Read-MorphospaceProtocolJson $intentPath;$completion=Read-MorphospaceProtocolJson $completionPath
    if([string]$intent.event.event_id-cne[string]$Binding.event_id-or[string]$completion.event_id-cne[string]$Binding.event_id-or[string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $intentPath)-or[string]$completion.status-cne'committed'){throw "Prepared-publication reconstruction $Name transition binding mismatch."}
    [pscustomobject]@{intent=$intent;completion=$completion;intent_path=$intentPath;completion_path=$completionPath}
}
function Get-ReconstructionPlanAuthority {
    param([object]$Plan,[object]$MapDocument)
    $aliases=@{};$entries=@{}
    foreach($entry in @($MapDocument.repositories)){
        $physicalId=[string]$entry.repo_id
        if($entries.ContainsKey($physicalId)){throw 'Prepared-publication reconstruction repository map contains duplicate IDs.'}
        $entries[$physicalId]=$entry
        foreach($logicalId in @($physicalId)+@($entry.aliases)){
            $logical=[string]$logicalId
            if($aliases.ContainsKey($logical)){throw "Prepared-publication reconstruction repository map alias '$logical' is ambiguous."}
            $aliases[$logical]=$entry
        }
    }
    $logicalSeen=@{};$groups=@{}
    foreach($leg in @($Plan.repositories)){
        $logical=[string]$leg.repo_id
        if($logicalSeen.ContainsKey($logical)){throw "Prepared-publication reconstruction prepared plan duplicates logical repository '$logical'."}
        $logicalSeen[$logical]=$true
        if(-not$aliases.ContainsKey($logical)){throw "Prepared-publication reconstruction prepared plan repository '$logical' is not mapped."}
        $upstream=[string]$leg.upstream
        if($upstream-notmatch'^([^/]+)/(.+)$'){throw "Prepared-publication reconstruction plan upstream for '$logical' is not canonical."}
        $remote=$Matches[1];$mergeBranch=$Matches[2];$mergeRef="refs/heads/$mergeBranch"
        $entry=$aliases[$logical];$repo=[IO.Path]::GetFullPath([string]$entry.path)
        $key="$($repo.ToLowerInvariant())|$remote|$mergeRef"
        if(-not$groups.ContainsKey($key)){$groups[$key]=[pscustomobject][ordered]@{key=$key;observation_repo_id=[string]$entry.repo_id;repo=$repo;remote=$remote;ref=$mergeRef;branch=[string]$leg.branch;upstream=$upstream;prepared_revision=[string]$leg.commit;logical_repo_ids=[Collections.Generic.List[string]]::new()}}
        $group=$groups[$key]
        if([string]$group.prepared_revision-cne[string]$leg.commit-or[string]$group.branch-cne[string]$leg.branch-or[string]$group.upstream-cne$upstream){throw "Prepared-publication reconstruction logical aliases do not share one physical branch/upstream/prepared revision for '$logical'."}
        $group.logical_repo_ids.Add($logical)
    }
    [pscustomobject]@{logical_ids=@($logicalSeen.Keys);groups=@($groups.Values);entries=$entries}
}
function Get-ReconstructionHistory {
    param([string]$Repo,[string]$Prepared,[string]$Tip)
    $ids=@((Invoke-ReconstructionGit $Repo @('rev-list','--reverse',"$Prepared..$Tip")).text-split"`n"|Where-Object{$_})
    @($ids|ForEach-Object{
        $id=$_;$parents=@((Invoke-ReconstructionGit $Repo @('show','-s','--format=%P',$id)).text-split' '|Where-Object{$_})
        $tree=(Invoke-ReconstructionGit $Repo @('show','-s','--format=%T',$id)).text
        $paths=@((Invoke-ReconstructionGit $Repo @('diff-tree','--no-commit-id','--name-only','-r','--root',$id)).text-split"`n"|Where-Object{$_}|Sort-Object -Unique)
        [pscustomobject][ordered]@{revision=$id;parents=$parents;tree=$tree;changed_paths=$paths}
    })
}
function Assert-ReconstructionHistory {
    param([object[]]$Declared,[object[]]$Actual,[string]$Id)
    if($Declared.Count-ne$Actual.Count){throw "Prepared-publication reconstruction incomplete intervening history for '$Id'."}
    for($i=0;$i-lt$Actual.Count;$i++){
        foreach($field in @('revision','tree')){if([string]$Declared[$i].$field-cne[string]$Actual[$i].$field){throw "Prepared-publication reconstruction reordered or abbreviated intervening history for '$Id'."}}
        if((@($Declared[$i].parents)-join'|')-cne(@($Actual[$i].parents)-join'|')-or(@($Declared[$i].changed_paths)-join'|')-cne(@($Actual[$i].changed_paths)-join'|')){throw "Prepared-publication reconstruction incomplete commit detail for '$Id'."}
    }
}
function Get-ReconstructionBundleBindings {
    param([AllowNull()][object]$Node)
    if($null-eq$Node){return}
    if($Node-is[pscustomobject]){foreach($p in $Node.PSObject.Properties){if($p.Name-ceq'bundle_id'){[string]$p.Value};Get-ReconstructionBundleBindings $p.Value}}
    elseif($Node-is[System.Collections.IEnumerable]-and$Node-isnot[string]){foreach($item in $Node){Get-ReconstructionBundleBindings $item}}
}
function Assert-NoReconstructionConflict {
    param([string]$Workspace,[string]$BundleId,[string[]]$Excluded)
    $recognized=@('rusty.morphospace.workflow.executed_push_receipt.v1','rusty.morphospace.workflow.planned_publication_accounting.v1','rusty.morphospace.workflow.unplanned_publication_closure.v1','rusty.morphospace.workflow.unplanned_publication_closure.v2','rusty.morphospace.workflow.published_prerequisite_suffix_reconciliation.v1','rusty.morphospace.workflow.published_prerequisite_suffix_reconciliation.v2','rusty.morphospace.workflow.planning_suffix_rewrite_recovery.v1')
    foreach($file in @(Get-ChildItem (Join-Path $Workspace 'receipts') -File -Recurse -Filter *.json)){
        $relative=[IO.Path]::GetRelativePath($Workspace,$file.FullName).Replace('\','/');if($Excluded-contains$relative){continue}
        try{$candidate=Read-MorphospaceProtocolJson $file.FullName}catch{throw "Prepared-publication reconstruction encountered malformed evidence '$relative'."}
        if($recognized-contains[string]$candidate.schema-and@(Get-ReconstructionBundleBindings $candidate)-contains$BundleId){throw "Prepared-publication reconstruction found mutually exclusive execution/accounting/reconciliation evidence at '$relative'."}
    }
}
function Invoke-MorphospacePreparedPublicationReconstruction {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$UnitId,[Parameter(Mandatory)][string]$RepoMapPath,[Parameter(Mandatory)][string]$ReconstructionReceipt,[string]$Timestamp='',[string]$OutPath='',[switch]$Execute,[ValidateSet('none','after-intent','after-projection','after-event')][string]$FaultAfter='none')
    $workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $ReconstructionReceipt).Path
    $schema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\prepared-publication-reconstruction-v1.schema.json'
    if(-not(Test-Json -Json (Get-Content -Raw $input) -SchemaFile $schema)){throw 'Prepared-publication reconstruction receipt does not satisfy its schema.'}
    $doc=Read-MorphospaceProtocolJson $input;$statePath=Join-Path $workspace 'workspace.state.json';$state=Read-MorphospaceProtocolJson $statePath
    $unitRelative="iteration-units/$UnitId.json";$unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf)
    if([string]$unit.status-cne'accepted'-or[string]$doc.project_id-cne[string]$state.project_id-or[string]$doc.bundle_id-cne[string]$state.pending_push_bundle.bundle_id){throw 'Prepared-publication reconstruction project, accepted unit, or pending bundle mismatch.'}
    Assert-ReconstructionCanonicalBinding $state.pending_push_bundle $doc.pending_bundle 'pending bundle'
    $blockers=@($state.blockers|Where-Object{[string]$_.blocker_id-ceq[string]$doc.stale_blocker.value.blocker_id})
    if($blockers.Count-ne1){throw 'Prepared-publication reconstruction exact stale blocker is absent.'};Assert-ReconstructionCanonicalBinding $blockers[0] $doc.stale_blocker 'stale blocker'
    $planPath=Resolve-ReconstructionBinding $workspace $doc.prepared_plan.container;$owner=Read-MorphospaceProtocolJson $planPath;$plan=$owner.push_plan
    if([string]$owner.schema-cne'rusty.morphospace.workflow.work_unit_automation_receipt.v1'-or[string]$owner.action-cne'PreparePush'-or[string]$plan.execution-cne'not-performed'-or[string]$plan.bundle_id-cne[string]$doc.bundle_id){throw 'Prepared-publication reconstruction does not bind the original not-performed PreparePush owner/member.'}
    $intentPath=Resolve-ReconstructionBinding $workspace $doc.prepared_event.intent;$completionPath=Resolve-ReconstructionBinding $workspace $doc.prepared_event.completion
    $intent=Read-MorphospaceProtocolJson $intentPath;$completion=Read-MorphospaceProtocolJson $completionPath
    if([string]$intent.event.event_id-cne[string]$doc.prepared_event.event_id-or[string]$completion.event_id-cne[string]$doc.prepared_event.event_id-or[string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $intentPath)-or@($intent.event.receipts)-notcontains[string]$doc.prepared_plan.container.path){throw 'Prepared-publication reconstruction prepared event containers are not linked.'}
    $acceptedPath=Resolve-ReconstructionBinding $workspace $doc.accepted_unit;$accepted=Read-MorphospaceProtocolJson $acceptedPath
    if([IO.Path]::GetFullPath($acceptedPath)-cne[IO.Path]::GetFullPath((Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf))-or[string]$accepted.unit_id-cne$UnitId-or[string]$accepted.status-cne'accepted'-or(Get-MorphospaceCanonicalJsonSha256 $accepted)-cne(Get-MorphospaceCanonicalJsonSha256 $unit)){throw 'Prepared-publication reconstruction accepted-unit binding mismatch.'}
    $validationPath=Resolve-ReconstructionBinding $workspace $doc.validation_receipt
    $validationSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\validation-receipt.schema.json'
    if(-not(Test-Json -Json (Get-Content -Raw $validationPath) -SchemaFile $validationSchema)){throw 'Prepared-publication reconstruction validation receipt does not satisfy the full validation schema.'}
    $validation=Read-MorphospaceProtocolJson $validationPath
    if([string]$validation.schema-cne'rusty.morphospace.workflow.validation_receipt.v1'-or[string]$validation.result-cne'pass'-or[string]$validation.unit_id-cne$UnitId){throw 'Prepared-publication reconstruction validation receipt is not the accepted passing evidence.'}
    $validationTransition=Get-ReconstructionTransitionBinding $workspace $doc.validation_event 'validation-pass'
    $acceptanceTransition=Get-ReconstructionTransitionBinding $workspace $doc.acceptance_event 'acceptance'
    if([string]$validationTransition.intent.event.event_type-cne'validation'-or@($validationTransition.intent.event.receipts)-notcontains[string]$doc.validation_receipt.path-or[string]$validationTransition.intent.target.unit.document.unit_id-cne$UnitId){throw 'Prepared-publication reconstruction validation-pass event is not bound to the passing receipt and unit.'}
    if([string]$acceptanceTransition.intent.event.event_type-cne'state-transition'-or@($acceptanceTransition.intent.event.receipts)-notcontains[string]$doc.validation_receipt.path-or[string]$acceptanceTransition.intent.target.unit.document.status-cne'accepted'-or(Get-MorphospaceCanonicalJsonSha256 $acceptanceTransition.intent.target.unit.document)-cne(Get-MorphospaceCanonicalJsonSha256 $accepted)-or[string]$acceptanceTransition.completion.unit_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $accepted)){throw 'Prepared-publication reconstruction acceptance event is not bound to the passing receipt and accepted unit bytes.'}
    if($doc.conflicting_evidence.executed_push_receipt_present-ne$false-or$doc.conflicting_evidence.planned_accounting_present-ne$false-or$doc.conflicting_evidence.unplanned_closure_present-ne$false){throw 'Prepared-publication reconstruction is mutually exclusive with execution/accounting/unplanned closure.'}
    Assert-NoReconstructionConflict $workspace ([string]$doc.bundle_id) @([string]$doc.prepared_plan.container.path,[string]$doc.prepared_event.intent.path,[string]$doc.prepared_event.completion.path,[string]$doc.accepted_unit.path,[string]$doc.validation_receipt.path,[string]$doc.validation_event.intent.path,[string]$doc.validation_event.completion.path,[string]$doc.acceptance_event.intent.path,[string]$doc.acceptance_event.completion.path)
    $mapDoc=Read-MorphospaceProtocolJson (Resolve-Path $RepoMapPath)
    $authority=Get-ReconstructionPlanAuthority $plan $mapDoc
    $legIds=@($doc.logical_legs|ForEach-Object{[string]$_.repo_id});$planIds=@($authority.logical_ids)
    $sortedLegIds=@($legIds|Sort-Object);$sortedPlanIds=@($planIds|Sort-Object)
    if(@($legIds|Sort-Object -Unique).Count-ne$legIds.Count-or($sortedLegIds-join'|')-cne($sortedPlanIds-join'|')){throw 'Prepared-publication reconstruction logical plan-leg coverage mismatch.'}
    $physicalIds=@($doc.physical_refs|ForEach-Object{[string]$_.physical_ref_id})
    if(@($physicalIds|Sort-Object -Unique).Count-ne$physicalIds.Count-or$doc.physical_refs.Count-ne$authority.groups.Count){throw 'Prepared-publication reconstruction physical refs are duplicated, split, merged, or unused.'}
    foreach($leg in @($doc.logical_legs)){
        $planned=@($plan.repositories|Where-Object{[string]$_.repo_id-ceq[string]$leg.repo_id})
        if($planned.Count-ne1-or[string]$planned[0].role-cne[string]$leg.role-or[string]$planned[0].commit-cne[string]$leg.prepared_revision){throw "Prepared-publication reconstruction logical leg mismatch for '$($leg.repo_id)'."}
        $physical=@($doc.physical_refs|Where-Object{@($_.logical_repo_ids)-contains[string]$leg.repo_id})
        if($physical.Count-ne1-or[string]$physical[0].physical_ref_id-cne[string]$leg.physical_ref_id-or[string]$physical[0].prepared_revision-cne[string]$leg.prepared_revision){throw "Prepared-publication reconstruction physical alias binding mismatch for '$($leg.repo_id)'."}
    }
    foreach($group in @($authority.groups)){
        $physical=@($doc.physical_refs|Where-Object{[string]$_.observation_repo_id-ceq[string]$group.observation_repo_id-and[string]$_.remote-ceq[string]$group.remote-and[string]$_.ref-ceq[string]$group.ref})
        if($physical.Count-ne1){throw 'Prepared-publication reconstruction physical refs do not canonically collapse by resolved repository, intended remote, and intended merge ref.'}
        $declaredIds=@($physical[0].logical_repo_ids|ForEach-Object{[string]$_}|Sort-Object)
        $expectedIds=@($group.logical_repo_ids|Sort-Object)
        if(($declaredIds-join'|')-cne($expectedIds-join'|')-or[string]$physical[0].prepared_revision-cne[string]$group.prepared_revision-or[string]$physical[0].branch-cne[string]$group.branch-or[string]$physical[0].upstream-cne[string]$group.upstream){throw 'Prepared-publication reconstruction physical ref authority differs from the immutable plan and repository map.'}
    }
    foreach($physical in @($doc.physical_refs)){
        if(-not$authority.entries.ContainsKey([string]$physical.observation_repo_id)){throw "Prepared-publication reconstruction physical observation repository is not mapped."}
        $repo=[IO.Path]::GetFullPath([string]$authority.entries[[string]$physical.observation_repo_id].path)
        if((Invoke-ReconstructionGit $repo @('branch','--show-current')).text-cne[string]$physical.branch-or(Invoke-ReconstructionGit $repo @('rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}')).text-cne[string]$physical.upstream){throw 'Prepared-publication reconstruction live branch/upstream differs from plan authority.'}
        [void](Invoke-ReconstructionGit $repo @('remote','get-url',[string]$physical.remote))
        $first=(Invoke-ReconstructionGit $repo @('ls-remote','--exit-code',[string]$physical.remote,[string]$physical.ref)).text-split'\s+'
        if($first[0]-cne[string]$physical.remote_tip_revision){throw "Prepared-publication reconstruction remote tip changed before history validation."}
        $prepared=(Invoke-ReconstructionGit $repo @('rev-parse',"$([string]$physical.prepared_revision)^{commit}")).text
        $tip=(Invoke-ReconstructionGit $repo @('rev-parse',"$([string]$physical.remote_tip_revision)^{commit}")).text
        if((Invoke-ReconstructionGit $repo @('merge-base','--is-ancestor',$prepared,$tip) -AllowFailure).code-ne0){throw 'Prepared-publication reconstruction requires every distinct prepared revision to be reachable.'}
        if((Invoke-ReconstructionGit $repo @('show','-s','--format=%T',$prepared)).text-cne[string]$physical.prepared_tree-or(Invoke-ReconstructionGit $repo @('show','-s','--format=%T',$tip)).text-cne[string]$physical.remote_tip_tree){throw 'Prepared-publication reconstruction tree binding mismatch.'}
        Assert-ReconstructionHistory @($physical.history) @(Get-ReconstructionHistory $repo $prepared $tip) ([string]$physical.physical_ref_id)
        $second=(Invoke-ReconstructionGit $repo @('ls-remote','--exit-code',[string]$physical.remote,[string]$physical.ref)).text-split'\s+'
        if($second[0]-cne$first[0]){throw 'Prepared-publication reconstruction remote tip changed between observations.'}
    }
    $events=@(Get-Content (Join-Path $workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json});$sequence=if($events.Count){[int]$events[-1].sequence+1}else{1}
    $eventId="$UnitId-prepared-publication-reconstructed-$('{0:d4}'-f$sequence)";if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('o')}
    $relative=if($OutPath){[IO.Path]::GetRelativePath($workspace,[IO.Path]::GetFullPath($OutPath)).Replace('\','/')}else{"receipts/$([string]$doc.reconstruction_id).json"}
    if($relative-notmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'){throw 'Prepared-publication reconstruction output must be a portable top-level receipt path.'}
    $artifactTarget=Resolve-MorphospaceWorkspacePath $workspace $relative
    if($Execute-and([IO.Path]::GetFullPath($input)-ceq[IO.Path]::GetFullPath($artifactTarget)-or[IO.File]::Exists($artifactTarget))){throw 'Prepared-publication reconstruction requires a new transaction-owned output artifact distinct from its input.'}
    $hash=Get-MorphospaceFileSha256 $input;$event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=$sequence;timestamp=$Timestamp;project_id=[string]$doc.project_id;unit_id=$UnitId;event_type='push';summary='Reconstructed current prepared-revision reachability and closed only stale bookkeeping without making execution, chronology, force-history, actor, timestamp, or historical-nonpublication claims.';receipts=@($relative)}
    $beforeCurrent=$state.current_unit
    if($Execute){
        if(-not$OutPath){throw 'Executed prepared-publication reconstruction requires OutPath.'}
        $preHash=Get-MorphospaceCanonicalJsonSha256 $state;$preTail=if($events.Count){[string]$events[-1].event_id}else{$null}
        $state.pending_push_bundle=$null;$state.blockers=@($state.blockers|Where-Object{[string]$_.blocker_id-cne[string]$doc.stale_blocker.value.blocker_id});$state.last_event_id=$eventId
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $unitRelative -EventsPath 'iteration-events.jsonl' -TargetState $state -TargetUnit $unit -Event $event -ExpectedStateSha256 $preHash -ExpectedUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $unit) -ExpectedEventTailId $preTail -Artifacts @([pscustomobject]@{source_path=$input;path=$relative;sha256=$hash}) -FaultAfter $FaultAfter|Out-Null
    }
    $result=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$doc.project_id;unit_id=$UnitId;action='ReconcilePreparedPublication';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='prepared-publication-reconstructed';status_before=[string]$unit.status;status_after=[string]$unit.status;current_unit_before=$beforeCurrent;current_unit_after=$state.current_unit;preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject][ordered]@{path=$relative;sha256=$hash};event_id=$(if($Execute){$eventId}else{$null})}
    $outSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\work-unit-automation-receipt-v2.schema.json'
    if(-not(Test-Json -Json ($result|ConvertTo-Json -Depth 32) -SchemaFile $outSchema)){throw 'Prepared-publication reconstruction emitted an invalid automation receipt.'}
    $result
}
Export-ModuleMember -Function Invoke-MorphospacePreparedPublicationReconstruction
