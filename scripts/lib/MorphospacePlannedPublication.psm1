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

function Test-MorphospacePlannedPublicationDocument {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot)
    try{$d=Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json}catch{throw "Invalid planned-publication accounting JSON: $($_.Exception.Message)"}
    if([string]$d.schema-cne'rusty.morphospace.workflow.planned_publication_accounting.v1'){throw 'Planned-publication accounting has the wrong schema ID.'}
    foreach($v in @($d.accounting_id,$d.project_id,$d.bundle_id,$d.trigger_unit_id)){if([string]$v-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){throw 'Planned-publication accounting contains an invalid portable ID.'}}
    $planPath=Test-PlannedPublicationBinding $d.prepared_plan $WorkspaceRoot 'prepared plan'; $eventPath=Test-PlannedPublicationBinding $d.prepared_event $WorkspaceRoot 'prepared event'; $executedPath=Test-PlannedPublicationBinding $d.executed_push_receipt $WorkspaceRoot 'executed push receipt'
    $plan=Get-Content -Raw $planPath|ConvertFrom-Json; $executed=Get-Content -Raw $executedPath|ConvertFrom-Json
    try{$preparedEvent=Get-Content -Raw $eventPath|ConvertFrom-Json}catch{throw 'Prepared event evidence is not a JSON event document.'}
    if([string]$preparedEvent.event_id-cne[string]$d.prepared_event.event_id){throw 'Prepared event ID does not match its bound evidence.'}
    if([string]$plan.schema-cne'rusty.morphospace.workflow.push_bundle_plan.v1' -or [string]$executed.schema-cne'rusty.morphospace.workflow.executed_push_receipt.v1'){throw 'Accounting evidence has an unexpected schema.'}
    if([string]$plan.bundle_id-cne[string]$d.bundle_id -or [string]$executed.bundle_id-cne[string]$d.bundle_id -or [string]$executed.prepared_plan_id-cne[string]$plan.bundle_id){throw 'Bundle or prepared-plan identity mismatch.'}
    if([string]$plan.project_id-cne[string]$d.project_id -or [string]$executed.project_id-cne[string]$d.project_id){throw 'Project identity mismatch.'}
    $times=@($d.chronology.prepared_at,$d.chronology.push_started_at,$d.chronology.push_finished_at,$d.chronology.accounted_at)|ForEach-Object{ConvertTo-PlannedPublicationTime $_}
    if(-not($times[0]-le$times[1]-and$times[1]-le$times[2]-and$times[2]-le$times[3])){throw 'Publication chronology is not monotonic.'}
    if((ConvertTo-PlannedPublicationTime $plan.prepared_at)-ne$times[0] -or (ConvertTo-PlannedPublicationTime $executed.started_at)-ne$times[1] -or (ConvertTo-PlannedPublicationTime $executed.finished_at)-ne$times[2]){throw 'Publication chronology does not match bound evidence.'}
    foreach($name in @('dependency_order','execution_order')){if((@($d.$name)-join'|')-cne(@($executed.$name)-join'|')){throw "$name does not match executed receipt."}}
    if($d.force_push_used-ne$false-or$d.remote_readback_complete-ne$true-or$null-ne$d.failure-or$d.workspace_transition.pending_push_bundle_after-ne$null){throw 'Publication accounting lacks no-force/readback/null-after proof.'}
    $planRepos=@{};foreach($r in @($plan.repositories)){$planRepos[[string]$r.repo_id]=$r};$execRepos=@{};foreach($r in @($executed.repositories)){$execRepos[[string]$r.repo_id]=$r}
    if(@($d.repositories).Count-ne$planRepos.Count-or$planRepos.Count-ne$execRepos.Count){throw 'Repository coverage mismatch.'}
    $planning=@($d.repositories|Where-Object{$_.role-eq'planning-transport'});if($planning.Count-ne1){throw 'Exactly one planning transport repository is required.'}
    foreach($r in @($d.repositories)){
      $id=[string]$r.repo_id;if(-not$planRepos.ContainsKey($id)-or-not$execRepos.ContainsKey($id)){throw "Repository '$id' is missing from plan or execution evidence."};$p=$planRepos[$id];$e=$execRepos[$id]
      if([string]$r.old_revision-cne[string]$e.old_revision-or[string]$r.final_revision-cne[string]$e.new_revision-or[string]$r.remote_readback_revision-cne[string]$e.observed_remote_revision){throw "Repository '$id' revision mismatch."}
      if([string]$r.final_revision-cne[string]$r.remote_readback_revision-or$r.force_push_used-ne$false-or$r.fast_forward_verified-ne$true-or$r.worktree_clean-ne$true){throw "Repository '$id' lacks clean no-force readback proof."}
      if($r.role-eq'source'-and[string]$r.prepared_revision-cne[string]$r.final_revision){throw "Source repository '$id' prepared revision must equal final revision."}
      if($r.role-eq'planning-transport'-and(-not$r.planning_last-or$r.source_first)){throw 'Planning transport ordering flags are invalid.'}
      if($r.role-eq'source'-and(-not$r.source_first-or$r.planning_last)){throw "Source repository '$id' ordering flags are invalid."}
      $seen=@{};foreach($u in @($r.units)){if($seen.ContainsKey([string]$u.unit_id)){throw "Repository '$id' repeats a unit."};$seen[[string]$u.unit_id]=$true;$statusPath=Test-PlannedPublicationBinding $u.status_evidence $WorkspaceRoot "unit '$($u.unit_id)' status evidence";try{$statusDocument=Get-Content -Raw $statusPath|ConvertFrom-Json}catch{throw "Unit '$($u.unit_id)' status evidence is not JSON."};if([string]$statusDocument.unit_id-cne[string]$u.unit_id-or[string]$statusDocument.status-cne[string]$u.status_at_publication){throw "Unit '$($u.unit_id)' status evidence payload mismatch."};if($u.role-eq'carried-unit'-and($u.status_at_publication-ne'blocked'-or$u.no_acceptance_claim-ne$true)){throw "Carried unit '$($u.unit_id)' must be blocked with an explicit no-acceptance claim."};if($u.role-eq'triggering-unit'-and([string]$u.unit_id-cne[string]$d.trigger_unit_id-or$u.status_at_publication-ne'accepted'-or$u.no_acceptance_claim-ne$false)){throw 'Triggering-unit status claim is invalid.'}}
      $commitIds=@($r.commits|Where-Object{$null-ne$_.unit_id}|ForEach-Object{[string]$_.unit_id})
      if(@($r.commits.revision|Sort-Object -Unique).Count-ne@($r.commits).Count){throw "Repository '$id' repeats a commit revision."}
      foreach($unitId in $seen.Keys){if(@($commitIds|Where-Object{$_-ceq$unitId}).Count-lt1){throw "Repository '$id' unit '$unitId' has no attributed commit."}}
      foreach($c in @($r.commits)){if($c.role-eq'workflow-publication-finalization'){if($r.role-ne'planning-transport'-or$null-ne$c.unit_id){throw 'Workflow/publication-finalization commits belong only to planning transport and cannot claim a unit.'};foreach($changedPath in @($c.changed_paths)){if(@($r.allowed_finalization_paths|Where-Object{[string]$changedPath-like(([string]$_).TrimEnd('/')+'*')}).Count-eq0){throw "Planning suffix path '$changedPath' is outside explicit transport scope."}}}elseif(-not$seen.ContainsKey([string]$c.unit_id)-or[string]$c.role-cne[string](@($r.units|Where-Object{$_.unit_id-ceq$c.unit_id})[0].role)){throw "Repository '$id' commit attribution mismatch."}}
      if($r.role-eq'planning-transport'){if(@($r.commits.revision)-notcontains[string]$r.prepared_revision-or[string]$r.commits[-1].revision-cne[string]$r.final_revision){throw 'Planning prepared/final revisions are not represented by the ordered commit list.'}}
      elseif([string]$r.commits[-1].role-cne'triggering-unit'){throw "Source repository '$id' must end its accounted range with the triggering unit."}
    }
    [pscustomobject]@{document=$d;plan=$plan;executed=$executed;accounting_sha256=Get-PlannedPublicationHash $Path;event_path=$eventPath}
}

function Test-MorphospacePlannedPublicationLive {
 param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$State,[Parameter(Mandatory)][hashtable]$RepositoryMap,[Parameter(Mandatory)][object[]]$RepositoryStates)
 $v=Test-MorphospacePlannedPublicationDocument $Path $WorkspaceRoot;$d=$v.document
 if([string]$d.project_id-cne[string]$Spec.project_id-or$null-ne$State.current_unit){throw 'Publication accounting project/current-unit state mismatch.'}
 if($null-eq$State.pending_push_bundle-or[string]$State.pending_push_bundle.bundle_id-cne[string]$d.bundle_id-or[string]$d.workspace_transition.pending_push_bundle_before-cne[string]$d.bundle_id){throw 'Publication accounting does not match the pending bundle.'}
 if((@($State.pending_push_bundle.unit_ids)-join'|')-cne(@($v.plan.unit_ids)-join'|')-or(@($State.pending_push_bundle.repo_ids)-join'|')-cne(@($v.plan.repositories.repo_id)-join'|')){throw 'Pending bundle unit/repository coverage mismatch.'}
 foreach($r in @($d.repositories)){$id=[string]$r.repo_id;if(-not$RepositoryMap.ContainsKey($id)){throw "Repository '$id' is not mapped."};$s=@($RepositoryStates|Where-Object{$_.repo_id-ceq$id});if($s.Count-ne1-or$s[0].dirty-ne$false-or$s[0].diverged-eq$true-or[int]$s[0].ahead-ne0-or[int]$s[0].behind-ne0-or[string]$s[0].head-cne[string]$r.final_revision-or[string]$s[0].branch-cne[string]$r.branch-or[string]$s[0].upstream-cne[string]$r.upstream){throw "Repository '$id' live state mismatch or dirty."};$repo=[string]$RepositoryMap[$id].path;[void](Invoke-PlannedPublicationGit $repo @('merge-base','--is-ancestor',[string]$r.old_revision,[string]$r.final_revision) "Repository '$id' fast-forward check");if($r.role-eq'planning-transport'){[void](Invoke-PlannedPublicationGit $repo @('merge-base','--is-ancestor',[string]$r.prepared_revision,[string]$r.final_revision) 'Planning suffix ancestry');$allowed=@($r.allowed_finalization_paths);$suffix=@(Invoke-PlannedPublicationGit $repo @('rev-list','--reverse',"$($r.prepared_revision)..$($r.final_revision)") 'Planning suffix enumeration')}else{$suffix=@()};$commits=@(Invoke-PlannedPublicationGit $repo @('rev-list','--reverse',"$($r.old_revision)..$($r.final_revision)") 'Commit enumeration');if(($commits-join'|')-cne(@($r.commits.revision)-join'|')){throw "Repository '$id' commit enumeration mismatch."};foreach($c in @($r.commits)){if($c.role-eq'workflow-publication-finalization'){if($r.role-ne'planning-transport'-or$suffix-notcontains[string]$c.revision-or$null-ne$c.unit_id){throw 'Invalid workflow/publication-finalization commit.'};foreach($p in @($c.changed_paths)){if(@($allowed|Where-Object{[string]$p-like(([string]$_).TrimEnd('/')+'*')}).Count-eq0){throw "Planning suffix path '$p' is outside transport scope."}}}elseif(-not$c.unit_id-or@($r.units.unit_id)-notcontains[string]$c.unit_id){throw "Commit '$($c.revision)' lacks matching unit attribution."};$actual=@(Invoke-PlannedPublicationGit $repo @('diff-tree','--no-commit-id','--name-only','-r',[string]$c.revision) 'Changed-path enumeration');if(($actual-join'|')-cne(@($c.changed_paths)-join'|')){throw "Commit '$($c.revision)' changed-path mismatch."}}}
 $v
}

Export-ModuleMember -Function Test-MorphospacePlannedPublicationDocument,Test-MorphospacePlannedPublicationLive,Get-PlannedPublicationHash
