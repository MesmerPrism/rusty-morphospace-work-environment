Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-PlannedPublicationHash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Publication evidence does not exist: $Path" }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-PlannedPublicationFile([string]$WorkspaceRoot,[string]$Reference,[string]$Context) {
    if ([IO.Path]::IsPathRooted($Reference) -or $Reference.Replace('\','/') -match '(^|/)\.\.(/|$)') { throw "$Context must be a workspace-relative non-traversing path." }
    $root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/'); $path=[IO.Path]::GetFullPath((Join-Path $root $Reference)); $prefix=$root+[IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Context is outside or missing from the workspace." }
    $path
}

function Test-PlannedPublicationBinding($Binding,[string]$WorkspaceRoot,[string]$Context) {
    $path=Resolve-PlannedPublicationFile $WorkspaceRoot ([string]$Binding.path) $Context
    if ((Get-PlannedPublicationHash $path) -cne ([string]$Binding.sha256).ToLowerInvariant()) { throw "$Context hash mismatch." }
    $path
}

function Invoke-PlannedPublicationGit([string]$RepoPath,[string[]]$Arguments,[string]$Context) {
    $output=@(& git -C $RepoPath @Arguments 2>&1); if($LASTEXITCODE-ne 0){throw "$Context failed: $($output -join ' ')"}; @($output)
}

function ConvertTo-PlannedPublicationTime($Value) {
    if ($Value -is [datetime]) { return [DateTimeOffset]::new([datetime]$Value) }
    if ($Value -is [DateTimeOffset]) { return $Value }
    return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)
}

function Test-PlannedPublicationTimeNotAfter($EarlierValue,$LaterValue) {
    $earlier=ConvertTo-PlannedPublicationTime $EarlierValue;$later=ConvertTo-PlannedPublicationTime $LaterValue
    if($earlier-le$later){return $true}
    # A bound RFC 3339 value without a fractional component carries only
    # whole-second precision. Accept an earlier high-precision observation
    # inside that same represented second, but never across its boundary.
    $laterText=[string]$LaterValue
    if($laterText-cmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.0+)?(?:Z|[+-]\d{2}:\d{2})$'){
        return $earlier-lt$later.AddSeconds(1)
    }
    return $false
}

function Resolve-PlannedPublicationPlan($Document,[string]$WorkspaceRoot) {
    if ($Document.prepared_plan.PSObject.Properties.Name -contains 'container') {
        if ([string]$Document.prepared_plan.member -cne 'push_plan') { throw 'Prepared-plan container member must be push_plan.' }
        $containerPath=Test-PlannedPublicationBinding $Document.prepared_plan.container $WorkspaceRoot 'prepared-plan container'
        try{$container=Get-Content -Raw $containerPath|ConvertFrom-Json -DateKind String}catch{throw 'Prepared-plan container is not valid JSON.'}
        if([string]$container.schema-cne'rusty.morphospace.workflow.work_unit_automation_receipt.v1' -or [string]$container.action-cne'PreparePush' -or [string]$container.transition-cne'push-bundle-prepared' -or $container.executed-ne$true){throw 'Prepared-plan container schema/action/transition/executed state is invalid.'}
        if([string]$container.project_id-cne[string]$Document.project_id -or [string]$container.unit_id-cne[string]$Document.trigger_unit_id){throw 'Prepared-plan container project/unit identity mismatch.'}
        if($null-eq$container.push_plan){throw 'Prepared-plan container is missing push_plan.'}
        return [pscustomobject]@{plan=$container.push_plan;evidence_path=$containerPath;receipt_reference=[string]$Document.prepared_plan.container.path;container=$container}
    }
    $planPath=Test-PlannedPublicationBinding $Document.prepared_plan $WorkspaceRoot 'prepared plan'
    return [pscustomobject]@{plan=(Get-Content -Raw $planPath|ConvertFrom-Json -DateKind String);evidence_path=$planPath;receipt_reference=[string]$Document.prepared_plan.path;container=$null}
}

function Resolve-PlannedPublicationEvent($Document,[string]$WorkspaceRoot,[string]$PlanReceiptReference) {
    if ($Document.prepared_event.PSObject.Properties.Name -contains 'intent') {
        $intentPath=Test-PlannedPublicationBinding $Document.prepared_event.intent $WorkspaceRoot 'prepared-event transition intent'
        $completionPath=Test-PlannedPublicationBinding $Document.prepared_event.completion $WorkspaceRoot 'prepared-event transition completion'
        try{$intent=Get-Content -Raw $intentPath|ConvertFrom-Json -DateKind String;$completion=Get-Content -Raw $completionPath|ConvertFrom-Json -DateKind String}catch{throw 'Prepared-event transition evidence is not valid JSON.'}
        if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1' -or [string]$intent.status-cne'prepared'){throw 'Prepared-event transition intent schema/status is invalid.'}
        if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1' -or [string]$completion.status-cne'committed'){throw 'Prepared-event transition completion schema/status is invalid.'}
        $transaction=[string]$Document.prepared_event.transaction_id;$eventId=[string]$Document.prepared_event.event_id
        if([string]$intent.transaction_id-cne$transaction-or[string]$completion.transaction_id-cne$transaction){throw 'Prepared-event transaction identity mismatch.'}
        if([string]$completion.event_id-cne$eventId-or[string]$intent.event.event_id-cne$eventId){throw 'Prepared-event event identity mismatch.'}
        if([string]$completion.intent.role-cne'transition-ledger-intent' -or [string]$completion.intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1' -or [string]$completion.intent.path-cne[string]$Document.prepared_event.intent.path -or [string]$completion.intent.sha256-cne[string]$Document.prepared_event.intent.sha256){throw 'Prepared-event completion-to-intent reference mismatch.'}
        $event=$intent.event
        if([string]$event.schema-cne'rusty.morphospace.workflow.iteration_event.v1' -or [string]$event.project_id-cne[string]$Document.project_id -or [string]$event.unit_id-cne[string]$Document.trigger_unit_id -or [string]$event.event_type-cne'commit'){throw 'Embedded prepared event schema/project/unit/type is invalid.'}
        if(@($event.receipts|Where-Object{[string]$_-ceq$PlanReceiptReference}).Count-ne1){throw 'Embedded prepared event does not link the exact prepared-plan receipt.'}
        return [pscustomobject]@{event=$event;evidence_path=$completionPath;intent=$intent;completion=$completion}
    }
    $eventPath=Test-PlannedPublicationBinding $Document.prepared_event $WorkspaceRoot 'prepared event'
    try{$event=Get-Content -Raw $eventPath|ConvertFrom-Json -DateKind String}catch{throw 'Prepared event evidence is not a JSON event document.'}
    if([string]$event.event_id-cne[string]$Document.prepared_event.event_id){throw 'Prepared event ID does not match its bound evidence.'}
    return [pscustomobject]@{event=$event;evidence_path=$eventPath;intent=$null;completion=$null}
}

function Test-MorphospacePlannedPublicationDocument {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot)
    try{$d=Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json -DateKind String}catch{throw "Invalid planned-publication accounting JSON: $($_.Exception.Message)"}
    if([string]$d.schema-cne'rusty.morphospace.workflow.planned_publication_accounting.v1'){throw 'Planned-publication accounting has the wrong schema ID.'}
    foreach($v in @($d.accounting_id,$d.project_id,$d.bundle_id,$d.trigger_unit_id)){if([string]$v-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){throw 'Planned-publication accounting contains an invalid portable ID.'}}
    $resolvedPlan=Resolve-PlannedPublicationPlan $d $WorkspaceRoot;$plan=$resolvedPlan.plan
    $resolvedEvent=Resolve-PlannedPublicationEvent $d $WorkspaceRoot $resolvedPlan.receipt_reference;$preparedEvent=$resolvedEvent.event
    $executedPath=Test-PlannedPublicationBinding $d.executed_push_receipt $WorkspaceRoot 'executed push receipt';$executed=Get-Content -Raw $executedPath|ConvertFrom-Json -DateKind String
    if([string]$plan.schema-cne'rusty.morphospace.workflow.push_bundle_plan.v1' -or [string]$executed.schema-cne'rusty.morphospace.workflow.executed_push_receipt.v1'){throw 'Accounting evidence has an unexpected schema.'}
    if([string]$plan.bundle_id-cne[string]$d.bundle_id -or [string]$executed.bundle_id-cne[string]$d.bundle_id -or [string]$executed.prepared_plan_id-cne[string]$plan.bundle_id){throw 'Bundle or prepared-plan identity mismatch.'}
    if([string]$plan.project_id-cne[string]$d.project_id -or [string]$executed.project_id-cne[string]$d.project_id){throw 'Project identity mismatch.'}
    if(@($plan.unit_ids|Where-Object{[string]$_-ceq[string]$d.trigger_unit_id}).Count-ne1){throw 'Prepared plan does not contain the triggering unit identity.'}
    $times=@($d.chronology.prepared_at,$d.chronology.push_started_at,$d.chronology.push_finished_at,$d.chronology.accounted_at)|ForEach-Object{ConvertTo-PlannedPublicationTime $_}
    if(-not((Test-PlannedPublicationTimeNotAfter $d.chronology.prepared_at $d.chronology.push_started_at)-and(Test-PlannedPublicationTimeNotAfter $d.chronology.push_started_at $d.chronology.push_finished_at)-and(Test-PlannedPublicationTimeNotAfter $d.chronology.push_finished_at $d.chronology.accounted_at))){throw 'Publication chronology is not monotonic at the precision carried by its bound evidence.'}
    if((ConvertTo-PlannedPublicationTime $plan.prepared_at)-ne$times[0] -or (ConvertTo-PlannedPublicationTime $executed.started_at)-ne$times[1] -or (ConvertTo-PlannedPublicationTime $executed.finished_at)-ne$times[2]){throw 'Publication chronology does not match bound evidence.'}
    foreach($name in @('dependency_order','execution_order')){if((@($d.$name)-join'|')-cne(@($executed.$name)-join'|')){throw "$name does not match executed receipt."}}
    if($d.force_push_used-ne$false-or$d.remote_readback_complete-ne$true-or$null-ne$d.failure-or$d.workspace_transition.pending_push_bundle_after-ne$null){throw 'Publication accounting lacks no-force/readback/null-after proof.'}
    $planRepos=@{};foreach($r in @($plan.repositories)){$planRepos[[string]$r.repo_id]=$r};$execRepos=@{};foreach($r in @($executed.repositories)){$execRepos[[string]$r.repo_id]=$r}
    if(@($d.repositories).Count-ne$planRepos.Count-or$planRepos.Count-ne$execRepos.Count){throw 'Repository coverage mismatch.'}
    $planning=@($d.repositories|Where-Object{$_.role-eq'planning-transport'});if($planning.Count-ne1){throw 'Exactly one planning transport repository is required.'}
    foreach($r in @($d.repositories)){
      $id=[string]$r.repo_id;if(-not$planRepos.ContainsKey($id)-or-not$execRepos.ContainsKey($id)){throw "Repository '$id' is missing from plan or execution evidence."};$p=$planRepos[$id];$e=$execRepos[$id]
      $recovery=$null-ne$r.PSObject.Properties['intervening_accepted_publication']
      $executedFinal=if($recovery){[string]$r.intervening_accepted_publication.executed_final_revision}else{[string]$r.final_revision}
      $executedReadback=if($recovery){[string]$r.intervening_accepted_publication.executed_remote_readback_revision}else{[string]$r.remote_readback_revision}
      if([string]$r.old_revision-cne[string]$e.old_revision-or$executedFinal-cne[string]$e.new_revision-or$executedReadback-cne[string]$e.observed_remote_revision){throw "Repository '$id' execution-time revision mismatch."}
      if([string]$p.commit-cne[string]$r.prepared_revision){throw "Repository '$id' prepared-plan revision mismatch."}
      if([string]$r.final_revision-cne[string]$r.remote_readback_revision-or$r.force_push_used-ne$false-or$r.fast_forward_verified-ne$true-or$r.worktree_clean-ne$true){throw "Repository '$id' lacks clean no-force readback proof."}
      if($r.role-eq'source'-and[string]$r.prepared_revision-cne$executedFinal){throw "Source repository '$id' prepared revision must equal its execution-time final revision."}
      if($r.role-eq'planning-transport'-and(-not$r.planning_last-or$r.source_first)){throw 'Planning transport ordering flags are invalid.'}
      if($r.role-eq'source'-and(-not$r.source_first-or$r.planning_last)){throw "Source repository '$id' ordering flags are invalid."}
      $synchronized=$null-ne$r.PSObject.Properties['synchronized_carried_acceptance'];$readback=$null-ne$r.PSObject.Properties['synchronized_readback']
      $seen=@{};foreach($u in @($r.units)){if($seen.ContainsKey([string]$u.unit_id)){throw "Repository '$id' repeats a unit."};$seen[[string]$u.unit_id]=$true;$statusPath=Test-PlannedPublicationBinding $u.status_evidence $WorkspaceRoot "unit '$($u.unit_id)' status evidence";try{$statusDocument=Get-Content -Raw $statusPath|ConvertFrom-Json -DateKind String}catch{throw "Unit '$($u.unit_id)' status evidence is not JSON."};if([string]$statusDocument.unit_id-cne[string]$u.unit_id-or[string]$statusDocument.status-cne[string]$u.status_at_publication){throw "Unit '$($u.unit_id)' status evidence payload mismatch."};if($u.role-eq'carried-unit'-and($u.status_at_publication-ne'blocked'-or$u.no_acceptance_claim-ne$true)){throw "Carried unit '$($u.unit_id)' must be blocked with an explicit no-acceptance claim."};if($u.role-eq'intervening-unit'){$validationPath=Test-PlannedPublicationBinding $u.validation_evidence $WorkspaceRoot "unit '$($u.unit_id)' validation evidence";try{$validationDocument=Get-Content -Raw $validationPath|ConvertFrom-Json -DateKind String}catch{throw "Unit '$($u.unit_id)' validation evidence is not JSON."};if([string]$validationDocument.schema-cne'rusty.morphospace.workflow.validation_receipt.v1'-or[string]$validationDocument.unit_id-cne[string]$u.unit_id-or[string]$validationDocument.result-cne'pass'-or$u.status_at_publication-ne'accepted'-or$u.no_acceptance_claim-ne$false){throw "Intervening unit '$($u.unit_id)' lacks exact accepted/pass evidence."}};if($u.role-eq'triggering-unit'-and([string]$u.unit_id-cne[string]$d.trigger_unit_id-or$u.status_at_publication-ne'accepted'-or($readback-and$u.no_acceptance_claim-ne$true)-or(-not$readback-and$u.no_acceptance_claim-ne$false))){throw 'Triggering-unit status claim is invalid.'}}
      $commitIds=@($r.commits|Where-Object{$null-ne$_.unit_id}|ForEach-Object{[string]$_.unit_id})
      $commitRevisions=@($r.commits|ForEach-Object{[string]$_.revision});if(@($commitRevisions|Sort-Object -Unique).Count-ne@($r.commits).Count){throw "Repository '$id' repeats a commit revision."}
      foreach($u in @($r.units)){if($u.role-eq'intervening-unit'-and@($commitIds|Where-Object{$_-ceq[string]$u.unit_id}).Count-lt1){throw "Repository '$id' intervening unit '$($u.unit_id)' has no attributed commit."};if(-not$synchronized-and-not$readback-and$u.role-ne'intervening-unit'-and@($commitIds|Where-Object{$_-ceq[string]$u.unit_id}).Count-lt1){throw "Repository '$id' unit '$($u.unit_id)' has no attributed commit."}}
      foreach($c in @($r.commits)){if($c.role-eq'workflow-publication-finalization'){if($r.role-ne'planning-transport'-or$null-ne$c.unit_id){throw 'Workflow/publication-finalization commits belong only to planning transport and cannot claim a unit.'};foreach($changedPath in @($c.changed_paths)){if(@($r.allowed_finalization_paths|Where-Object{[string]$changedPath-like(([string]$_).TrimEnd('/')+'*')}).Count-eq0){throw "Planning suffix path '$changedPath' is outside explicit transport scope."}}}elseif($c.role-eq'intervening-planning-evidence'){if(-not$recovery-or$r.role-ne'planning-transport'-or$null-ne$c.unit_id-or$c.evidence_kind-notin@('blocker','publication-finalization')){throw 'Intervening planning evidence has invalid recovery scope or identity.'};foreach($changedPath in @($c.changed_paths)){if(@($r.intervening_accepted_publication.allowed_planning_evidence_paths|Where-Object{[string]$changedPath-ceq[string]$_}).Count-eq0){throw "Intervening planning evidence path '$changedPath' is outside the exact recovery allowlist."}}}elseif(-not$seen.ContainsKey([string]$c.unit_id)-or[string]$c.role-cne[string](@($r.units|Where-Object{$_.unit_id-ceq$c.unit_id})[0].role)){throw "Repository '$id' commit attribution mismatch."}}
      if($r.role-eq'planning-transport'){if(@($r.commits.revision)-notcontains[string]$r.prepared_revision-or[string]$r.commits[-1].revision-cne[string]$r.final_revision){throw 'Planning prepared/final revisions are not represented by the ordered commit list.'}}
      elseif($synchronized){
        if(@($r.commits).Count-ne0-or[string]$r.old_revision-cne[string]$r.final_revision-or[string]$r.prepared_revision-cne[string]$r.final_revision){throw "Synchronized source '$id' must be an exact zero-commit prepared/final/readback leg."}
        if(@($r.units).Count-ne1-or[string]$r.units[0].unit_id-cne[string]$d.trigger_unit_id-or$r.units[0].status_at_publication-ne'accepted'-or$r.units[0].no_acceptance_claim-ne$false){throw "Synchronized source '$id' must bind only the currently accepted triggering unit."}
        $currentPath=Test-PlannedPublicationBinding $r.synchronized_carried_acceptance.current_acceptance_evidence $WorkspaceRoot 'current acceptance evidence';$current=Get-Content -Raw $currentPath|ConvertFrom-Json -DateKind String
        if([string]$current.unit_id-cne[string]$d.trigger_unit_id-or[string]$current.status-cne'accepted'-or[string]$r.units[0].status_evidence.sha256-cne[string]$r.synchronized_carried_acceptance.current_acceptance_evidence.sha256-or[string]$r.units[0].status_evidence.path-cne[string]$r.synchronized_carried_acceptance.current_acceptance_evidence.path){throw 'Current synchronized-source acceptance evidence mismatch.'}
        $priorPath=Test-PlannedPublicationBinding $r.synchronized_carried_acceptance.prior_accounting $WorkspaceRoot 'prior publication accounting';if((Resolve-Path -LiteralPath $priorPath).Path-ceq(Resolve-Path -LiteralPath $Path).Path){throw 'Prior publication accounting cannot reference itself.'};try{$prior=Get-Content -Raw $priorPath|ConvertFrom-Json -DateKind String}catch{throw 'Prior publication accounting is not JSON.'}
        if([string]$prior.schema-cne'rusty.morphospace.workflow.planned_publication_accounting.v1'-or[string]$prior.project_id-cne[string]$d.project_id-or$prior.force_push_used-ne$false-or$prior.remote_readback_complete-ne$true-or$null-ne$prior.failure){throw 'Prior publication accounting identity or terminal proof mismatch.'};$priorRepo=@($prior.repositories|Where-Object{$_.repo_id-ceq$id});if($priorRepo.Count-ne1-or$null-ne$priorRepo[0].PSObject.Properties['synchronized_carried_acceptance']-or@($priorRepo[0].commits).Count-lt1){throw 'Prior accounting must contain one normal nonempty source range.'}
        $priorCommit=@($priorRepo[0].commits|Where-Object{$_.revision-ceq$r.synchronized_carried_acceptance.carried_revision-and$_.unit_id-ceq$d.trigger_unit_id-and$_.role-eq'carried-unit'});$priorUnit=@($priorRepo[0].units|Where-Object{$_.unit_id-ceq$d.trigger_unit_id-and$_.role-eq'carried-unit'});if($priorCommit.Count-ne1-or$priorUnit.Count-ne1-or$priorUnit[0].status_at_publication-ne'blocked'-or$priorUnit[0].no_acceptance_claim-ne$true){throw 'Prior accounting lacks the exact carried commit and no-acceptance claim.'}
        $priorStatusPath=Test-PlannedPublicationBinding $r.synchronized_carried_acceptance.prior_status_evidence $WorkspaceRoot 'prior status evidence';$priorStatus=Get-Content -Raw $priorStatusPath|ConvertFrom-Json -DateKind String;if([string]$priorUnit[0].status_evidence.sha256-cne[string]$r.synchronized_carried_acceptance.prior_status_evidence.sha256-or[string]$priorStatus.unit_id-cne[string]$d.trigger_unit_id-or[string]$priorStatus.status-cne'blocked'){throw 'Prior blocked status evidence mismatch.'}
      }
      elseif($readback){
        $triggerUnits=@($r.units|Where-Object{$_.role-eq'triggering-unit'});if($triggerUnits.Count-ne1-or[string]$triggerUnits[0].unit_id-cne[string]$d.trigger_unit_id-or$triggerUnits[0].status_at_publication-ne'accepted'-or$triggerUnits[0].no_acceptance_claim-ne$true){throw "Synchronized readback '$id' must bind one execution-time triggering status without inferring acceptance."}
        if(-not$recovery-and(@($r.commits).Count-ne0-or@($r.units).Count-ne1)){throw "Synchronized readback '$id' without recovery must remain a zero-commit single-unit leg."}
        if([string]$r.old_revision-cne[string]$r.prepared_revision-or[string]$r.old_revision-cne$executedFinal-or[string]$r.old_revision-cne$executedReadback-or[string]$r.old_revision-cne[string]$r.synchronized_readback.unchanged_revision){throw "Synchronized readback '$id' must bind four equal execution-time revisions."}
        if([string]$e.action-cne'readback-only'-or[string]$r.synchronized_readback.executed_action-cne'readback-only'-or$r.synchronized_readback.no_mutation_inferred-ne$true-or[string]$e.branch-cne[string]$r.branch-or[string]$e.upstream-cne[string]$r.upstream){throw "Synchronized readback '$id' execution identity or non-mutation proof mismatch."}
        $orderIndex=[array]::IndexOf(@($d.dependency_order),$id);$executionIndex=[array]::IndexOf(@($d.execution_order),$id);if($orderIndex-lt0-or$executionIndex-ne$orderIndex-or[array]::IndexOf(@($plan.dependency_order),$id)-ne$orderIndex){throw "Synchronized readback '$id' order position mismatch."}
      }
      elseif([string]$r.commits[-1].role-cne'triggering-unit'){throw "Source repository '$id' must end its accounted range with the triggering unit."}
      if($recovery){$re=$r.intervening_accepted_publication;if([string]$re.current_final_revision-cne[string]$r.final_revision-or[string]$re.current_remote_readback_revision-cne[string]$r.remote_readback_revision-or$re.original_to_current_fast_forward-ne$true){throw "Repository '$id' recovered-final binding mismatch."};if(-not(Test-PlannedPublicationTimeNotAfter $d.chronology.push_finished_at $re.recovered_at)-or-not(Test-PlannedPublicationTimeNotAfter $re.recovered_at $d.chronology.accounted_at)){throw "Repository '$id' recovery chronology is invalid."};if(@($r.units|Where-Object{$_.role-eq'intervening-unit'}).Count-lt1){throw "Repository '$id' recovery has no accepted intervening unit."}}
    }
    [pscustomobject]@{document=$d;plan=$plan;executed=$executed;prepared_event=$preparedEvent;accounting_sha256=Get-PlannedPublicationHash $Path;event_path=$resolvedEvent.evidence_path}
}

function Test-MorphospacePlannedPublicationLive {
 param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$State,[Parameter(Mandatory)][hashtable]$RepositoryMap,[Parameter(Mandatory)][object[]]$RepositoryStates)
 $v=Test-MorphospacePlannedPublicationDocument $Path $WorkspaceRoot;$d=$v.document
 if([string]$d.project_id-cne[string]$Spec.project_id-or$null-ne$State.current_unit){throw 'Publication accounting project/current-unit state mismatch.'}
 if($null-eq$State.pending_push_bundle-or[string]$State.pending_push_bundle.bundle_id-cne[string]$d.bundle_id-or[string]$d.workspace_transition.pending_push_bundle_before-cne[string]$d.bundle_id){throw 'Publication accounting does not match the pending bundle.'}
 if((@($State.pending_push_bundle.unit_ids)-join'|')-cne(@($v.plan.unit_ids)-join'|')-or(@($State.pending_push_bundle.repo_ids)-join'|')-cne(@($v.plan.repositories.repo_id)-join'|')){throw 'Pending bundle unit/repository coverage mismatch.'}
 foreach($r in @($d.repositories)){
  $id=[string]$r.repo_id;if(-not$RepositoryMap.ContainsKey($id)){throw "Repository '$id' is not mapped."};$s=@($RepositoryStates|Where-Object{$_.repo_id-ceq$id})
  if($s.Count-ne1-or$s[0].dirty-ne$false-or$s[0].diverged-eq$true-or[int]$s[0].behind-ne0-or[string]$s[0].branch-cne[string]$r.branch-or[string]$s[0].upstream-cne[string]$r.upstream){throw "Repository '$id' live state mismatch or dirty."};$repo=[string]$RepositoryMap[$id].path
  $published=([int]$s[0].ahead-eq0-and[string]$s[0].head-ceq[string]$r.final_revision)
  if(-not$published){
   if($r.role-ne'planning-transport'-or[int]$s[0].ahead-lt1){throw "Repository '$id' live state mismatch or dirty."}
   $remote=Invoke-PlannedPublicationGit $repo @('rev-parse',[string]$r.upstream) "Repository '$id' remote readback";if([string]$remote-cne[string]$r.final_revision){throw "Planning repository '$id' remote drifted from the executed final revision."}
   [void](Invoke-PlannedPublicationGit $repo @('merge-base','--is-ancestor',[string]$r.final_revision,[string]$s[0].head) "Planning repository '$id' prerequisite-suffix ancestry")
   $localSuffix=@(Invoke-PlannedPublicationGit $repo @('rev-list','--reverse',"$($r.final_revision)..$($s[0].head)") 'Planning prerequisite-suffix enumeration');if($localSuffix.Count-ne[int]$s[0].ahead){throw "Planning repository '$id' ahead count does not match its prerequisite suffix."}
   $accountingRelative=[IO.Path]::GetRelativePath($repo,(Resolve-Path -LiteralPath $Path).Path).Replace('\','/');$executedPath=Test-PlannedPublicationBinding $d.executed_push_receipt $WorkspaceRoot 'executed push receipt';$executedRelative=[IO.Path]::GetRelativePath($repo,$executedPath).Replace('\','/');$required=@($executedRelative,$accountingRelative|Sort-Object -Unique);$observed=@()
   foreach($localCommit in $localSuffix){$localPaths=@(Invoke-PlannedPublicationGit $repo @('diff-tree','--no-commit-id','--name-only','-r',[string]$localCommit) 'Planning prerequisite-suffix paths');if($localPaths.Count-eq0){throw 'Planning prerequisite suffix contains an empty commit.'};foreach($localPath in $localPaths){if($required-notcontains[string]$localPath){throw "Planning prerequisite suffix path '$localPath' is not exact accounting/executed evidence."};$observed+=[string]$localPath}}
   if((@($observed|Sort-Object -Unique)-join'|')-cne(@($required|Sort-Object -Unique)-join'|')){throw 'Planning prerequisite suffix does not contain the exact accounting and executed evidence paths.'}
  }
   [void](Invoke-PlannedPublicationGit $repo @('merge-base','--is-ancestor',[string]$r.old_revision,[string]$r.final_revision) "Repository '$id' fast-forward check");if($null-ne$r.PSObject.Properties['synchronized_carried_acceptance']){[void](Invoke-PlannedPublicationGit $repo @('merge-base','--is-ancestor',[string]$r.synchronized_carried_acceptance.carried_revision,[string]$r.final_revision) 'Synchronized carried revision ancestry')};if($null-ne$r.PSObject.Properties['intervening_accepted_publication']){[void](Invoke-PlannedPublicationGit $repo @('merge-base','--is-ancestor',[string]$r.intervening_accepted_publication.executed_final_revision,[string]$r.final_revision) "Repository '$id' intervening-publication ancestry")};if($r.role-eq'planning-transport'){[void](Invoke-PlannedPublicationGit $repo @('merge-base','--is-ancestor',[string]$r.prepared_revision,[string]$r.final_revision) 'Planning suffix ancestry');$allowed=@($r.allowed_finalization_paths);$suffix=@(Invoke-PlannedPublicationGit $repo @('rev-list','--reverse',"$($r.prepared_revision)..$($r.final_revision)") 'Planning suffix enumeration')}else{$suffix=@()};$commits=@(Invoke-PlannedPublicationGit $repo @('rev-list','--reverse',"$($r.old_revision)..$($r.final_revision)") 'Commit enumeration');if(($commits-join'|')-cne(@($r.commits|ForEach-Object{$_.revision})-join'|')){throw "Repository '$id' commit enumeration mismatch."};foreach($c in @($r.commits)){if($c.role-eq'workflow-publication-finalization'){if($r.role-ne'planning-transport'-or$suffix-notcontains[string]$c.revision-or$null-ne$c.unit_id){throw 'Invalid workflow/publication-finalization commit.'};foreach($p in @($c.changed_paths)){if(@($allowed|Where-Object{[string]$p-like(([string]$_).TrimEnd('/')+'*')}).Count-eq0){throw "Planning suffix path '$p' is outside explicit transport scope."}}}elseif($c.role-eq'intervening-planning-evidence'){if($r.role-ne'planning-transport'-or$null-ne$c.unit_id){throw 'Invalid intervening planning evidence commit.'}}elseif(-not$c.unit_id-or@($r.units.unit_id)-notcontains[string]$c.unit_id){throw "Commit '$($c.revision)' lacks matching unit attribution."};$actual=@(Invoke-PlannedPublicationGit $repo @('diff-tree','--no-commit-id','--name-only','-r',[string]$c.revision) 'Changed-path enumeration');if(($actual-join'|')-cne(@($c.changed_paths)-join'|')){throw "Commit '$($c.revision)' changed-path mismatch."}}
 }
  $recoveredSources=@($d.repositories|Where-Object{$_.role-eq'source'-and$null-ne$_.PSObject.Properties['intervening_accepted_publication']});$recoveredPlanning=@($d.repositories|Where-Object{$_.role-eq'planning-transport'-and$null-ne$_.PSObject.Properties['intervening_accepted_publication']});if($recoveredSources.Count-gt0-and$recoveredPlanning.Count-ne1){throw 'Recovered source publication requires exactly one recovered planning-last leg.'};foreach($source in $recoveredSources){if(-not(Test-PlannedPublicationTimeNotAfter $source.intervening_accepted_publication.recovered_at $recoveredPlanning[0].intervening_accepted_publication.recovered_at)){throw 'Intervening accepted publication is not source-first and planning-last.'}}
  $v
}

Export-ModuleMember -Function Test-MorphospacePlannedPublicationDocument,Test-MorphospacePlannedPublicationLive,Get-PlannedPublicationHash
