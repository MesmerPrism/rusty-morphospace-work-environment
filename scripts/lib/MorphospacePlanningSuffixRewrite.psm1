Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-PlanningSuffixGit([string]$Repo,[string[]]$Arguments,[string]$Context) {
    $output=@(& git -C $Repo @Arguments 2>&1); if($LASTEXITCODE-ne0){throw "$Context failed: $($output-join' ')"}; @($output)
}

function Test-MorphospacePlanningSuffixRewriteDocument {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot)
    try{$d=Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json -DateKind String}catch{throw "Invalid planning-suffix rewrite recovery JSON: $($_.Exception.Message)"}
    if([string]$d.schema-cne'rusty.morphospace.workflow.planning_suffix_rewrite_recovery.v1'){throw 'Planning-suffix rewrite recovery has the wrong schema ID.'}
    foreach($v in @($d.recovery_id,$d.project_id,$d.bundle_id,$d.trigger_unit_id)){if([string]$v-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){throw 'Planning-suffix rewrite recovery contains an invalid portable ID.'}}
    $accountingReference=[string]$d.planned_publication_accounting.path
    if([IO.Path]::IsPathRooted($accountingReference)-or$accountingReference.Replace('\','/')-match'(^|/)\.\.(/|$)'){throw 'Bound planned-publication accounting path must be workspace-relative and non-traversing.'}
    $root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');$candidate=[IO.Path]::GetFullPath((Join-Path $root $accountingReference));if(-not$candidate.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Bound planned-publication accounting path is outside the workspace.'};$accountingPath=Resolve-Path -LiteralPath $candidate -ErrorAction Stop
    if((Get-PlannedPublicationHash $accountingPath.Path)-cne[string]$d.planned_publication_accounting.sha256){throw 'Bound planned-publication accounting hash mismatch.'}
    $accounting=Test-MorphospacePlannedPublicationDocument -Path $accountingPath.Path -WorkspaceRoot $WorkspaceRoot
    if([string]$accounting.document.project_id-cne[string]$d.project_id-or[string]$accounting.document.bundle_id-cne[string]$d.bundle_id-or[string]$accounting.document.trigger_unit_id-cne[string]$d.trigger_unit_id){throw 'Recovery identity does not match bound planned-publication accounting.'}
    if($accounting.document.force_push_used-ne$false-or$d.rewrite.prepared_execution_force_push_used-ne$false-or$d.rewrite.force_with_lease_used-ne$true-or[string]$d.rewrite.mechanism-cne'force-with-lease'-or[string]$d.rewrite.scope-cne'planning-only-finalization-suffix'-or$d.rewrite.source_rewrite_used-ne$false-or$null-ne$d.failure){throw 'Recovery does not distinguish the no-force execution from the later planning-only force-with-lease rewrite.'}
    if([string]$d.workspace_transition.pending_push_bundle_before-cne[string]$d.bundle_id-or$null-ne$d.workspace_transition.pending_push_bundle_after){throw 'Recovery workspace transition is not exact.'}
    $planning=@($accounting.document.repositories|Where-Object{$_.role-eq'planning-transport'});if($planning.Count-ne1){throw 'Bound accounting does not contain exactly one planning repository.'};$p=$planning[0];$rp=$d.planning_repository
    if([string]$rp.repo_id-cne[string]$p.repo_id-or[string]$rp.branch-cne[string]$p.branch-or[string]$rp.upstream-cne[string]$p.upstream-or[string]$rp.prepared_revision-cne[string]$p.prepared_revision-or[string]$rp.first_suffix_revision-cne[string]$p.final_revision){throw 'Planning rewrite identity/revision does not match the executed accounting.'}
    if([string]$rp.first_suffix_revision-ceq[string]$rp.replacement_suffix_revision-or[string]$rp.first_suffix_tree-ceq[string]$rp.replacement_suffix_tree-or[string]$rp.current_remote_readback_revision-cne[string]$rp.replacement_suffix_revision-or$rp.worktree_clean-ne$true){throw 'Planning replacement/readback proof is invalid.'}
    $source=@($accounting.document.repositories|Where-Object{$_.role-eq'source'});if(@($d.source_repositories).Count-ne$source.Count){throw 'Recovery source repository coverage mismatch.'};$seen=@{}
    foreach($s in @($d.source_repositories)){if($seen.ContainsKey([string]$s.repo_id)){throw 'Recovery repeats a source repository.'};$seen[[string]$s.repo_id]=$true;$a=@($source|Where-Object{$_.repo_id-ceq$s.repo_id});if($a.Count-ne1-or[string]$s.executed_revision-cne[string]$a[0].final_revision-or[string]$s.current_remote_readback_revision-cne[string]$s.executed_revision-or$s.history_unchanged-ne$true-or$s.worktree_clean-ne$true-or[string]$s.branch-cne[string]$a[0].branch-or[string]$s.upstream-cne[string]$a[0].upstream){throw "Source repository '$($s.repo_id)' does not prove unchanged executed history."}}
    [pscustomobject]@{document=$d;accounting=$accounting;recovery_sha256=Get-PlannedPublicationHash $Path}
}

function Test-MorphospacePlanningSuffixRewriteLive {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$State,[Parameter(Mandatory)][hashtable]$RepositoryMap,[Parameter(Mandatory)][object[]]$RepositoryStates)
    $v=Test-MorphospacePlanningSuffixRewriteDocument $Path $WorkspaceRoot;$d=$v.document
    if([string]$Spec.project_id-cne[string]$d.project_id-or$null-ne$State.current_unit-or$null-eq$State.pending_push_bundle-or[string]$State.pending_push_bundle.bundle_id-cne[string]$d.bundle_id-or(@($State.pending_push_bundle.unit_ids)-join'|')-cne(@($v.accounting.plan.unit_ids)-join'|')-or(@($State.pending_push_bundle.repo_ids)-join'|')-cne(@($v.accounting.plan.repositories.repo_id)-join'|')){throw 'Recovery does not match the exact pending bundle/project state.'}
    foreach($r in @($d.source_repositories)+@($d.planning_repository)){
        $id=[string]$r.repo_id;if(-not$RepositoryMap.ContainsKey($id)){throw "Repository '$id' is not mapped."};$s=@($RepositoryStates|Where-Object{$_.repo_id-ceq$id});if($s.Count-ne1-or$s[0].dirty-ne$false-or$s[0].diverged-eq$true-or[int]$s[0].ahead-ne0-or[int]$s[0].behind-ne0-or[string]$s[0].branch-cne[string]$r.branch-or[string]$s[0].upstream-cne[string]$r.upstream){throw "Repository '$id' is dirty, divergent, or not synchronized."};$repo=[string]$RepositoryMap[$id].path;$remote=@(Invoke-PlanningSuffixGit $repo @('rev-parse',[string]$r.upstream) "Repository '$id' remote readback")[0];if([string]$remote-cne[string]$r.current_remote_readback_revision-or[string]$s[0].head-cne[string]$remote){throw "Repository '$id' current readback mismatch."}
        [void](Invoke-PlanningSuffixGit $repo @('cat-file','-e',"$($r.current_remote_readback_revision)^{commit}") "Repository '$id' current object")
    }
    $rp=$d.planning_repository;$repo=[string]$RepositoryMap[[string]$rp.repo_id].path
    foreach($pair in @(@($rp.prepared_revision,$rp.prepared_tree),@($rp.first_suffix_revision,$rp.first_suffix_tree),@($rp.replacement_suffix_revision,$rp.replacement_suffix_tree))){[void](Invoke-PlanningSuffixGit $repo @('cat-file','-e',"$($pair[0])^{commit}") 'Planning incident object');$tree=@(Invoke-PlanningSuffixGit $repo @('rev-parse',"$($pair[0])^{tree}") 'Planning incident tree')[0];if([string]$tree-cne[string]$pair[1]){throw 'Planning incident tree binding mismatch.'}}
    $firstParent=@(Invoke-PlanningSuffixGit $repo @('rev-parse',"$($rp.first_suffix_revision)^1") 'First suffix parent')[0];$replacementParent=@(Invoke-PlanningSuffixGit $repo @('rev-parse',"$($rp.replacement_suffix_revision)^1") 'Replacement suffix parent')[0];if([string]$firstParent-cne[string]$rp.prepared_revision-or[string]$replacementParent-cne[string]$rp.prepared_revision){throw 'Planning incident is not two alternative one-commit suffixes from the prepared revision.'}
    foreach($revision in @($rp.first_suffix_revision,$rp.replacement_suffix_revision)){$paths=@(Invoke-PlanningSuffixGit $repo @('diff-tree','--no-commit-id','--name-only','-r',[string]$revision) 'Planning suffix changed path');if($paths.Count-ne1-or[string]$paths[0]-cne[string]$rp.changed_path){throw 'Planning suffix does not change the one exact bound path.'}}
    $v
}

Export-ModuleMember -Function Test-MorphospacePlanningSuffixRewriteDocument,Test-MorphospacePlanningSuffixRewriteLive
