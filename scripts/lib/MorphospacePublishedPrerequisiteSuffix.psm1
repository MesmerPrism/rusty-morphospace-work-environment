Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-PublishedPrerequisiteGit([string]$Repo,[string[]]$Arguments,[string]$Context) {
    $output=@(& git -C $Repo @Arguments 2>&1); if($LASTEXITCODE-ne0){throw "$Context failed: $($output-join' ')"}; @($output)
}

function Get-PublishedPrerequisiteBlobSha256([string]$Repo,[string]$Revision,[string]$Path) {
    $blob=@(Invoke-PublishedPrerequisiteGit $Repo @('rev-parse',"$Revision`:$Path") "Published receipt '$Path'")[0]
    [void](Invoke-PublishedPrerequisiteGit $Repo @('cat-file','-e',"$blob^{blob}") "Published receipt '$Path' blob")
    $temporary=[IO.Path]::GetTempFileName()
    try {
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command git -CommandType Application).Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($argument in @('-C',$Repo,'cat-file','blob',[string]$blob)){[void]$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start
        try { [void]$process.Start();$stream=[IO.File]::Create($temporary);try{$process.StandardOutput.BaseStream.CopyTo($stream)}finally{$stream.Dispose()};$errorText=$process.StandardError.ReadToEnd();$process.WaitForExit();if($process.ExitCode-ne0){throw "Published receipt '$Path' blob read failed: $errorText"} } finally { $process.Dispose() }
        (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Test-MorphospacePublishedPrerequisiteSuffixDocument {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot)
    try{$d=Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json -DateKind String}catch{throw "Invalid published-prerequisite reconciliation JSON: $($_.Exception.Message)"}
    if([string]$d.schema-cne'rusty.morphospace.workflow.published_prerequisite_suffix_reconciliation.v1'){throw 'Published-prerequisite reconciliation has the wrong schema ID.'}
    foreach($v in @($d.reconciliation_id,$d.project_id,$d.bundle_id,$d.trigger_unit_id)){if([string]$v-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){throw 'Published-prerequisite reconciliation contains an invalid portable ID.'}}
    $reference=[string]$d.planned_publication_accounting.path
    if([IO.Path]::IsPathRooted($reference)-or$reference.Replace('\','/')-match'(^|/)\.\.(/|$)'){throw 'Bound planned-publication accounting path must be workspace-relative and non-traversing.'}
    $root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');$accountingPath=[IO.Path]::GetFullPath((Join-Path $root $reference));if(-not$accountingPath.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or-not[IO.File]::Exists($accountingPath)){throw 'Bound planned-publication accounting is outside or missing from the workspace.'}
    if((Get-PlannedPublicationHash $accountingPath)-cne[string]$d.planned_publication_accounting.sha256){throw 'Bound planned-publication accounting hash mismatch.'}
    $accounting=Test-MorphospacePlannedPublicationDocument -Path $accountingPath -WorkspaceRoot $WorkspaceRoot
    if([string]$accounting.document.project_id-cne[string]$d.project_id-or[string]$accounting.document.bundle_id-cne[string]$d.bundle_id-or[string]$accounting.document.trigger_unit_id-cne[string]$d.trigger_unit_id){throw 'Reconciliation identity does not match bound planned-publication accounting.'}
    if($accounting.document.force_push_used-ne$false-or$accounting.document.remote_readback_complete-ne$true-or$null-ne$accounting.document.failure){throw 'Bound ordinary planned accounting is not valid no-force accounting.'}
    if([string]$d.workspace_transition.pending_push_bundle_before-cne[string]$d.bundle_id-or$null-ne$d.workspace_transition.pending_push_bundle_after-or$d.workspace_transition.validation_unchanged-ne$true-or$d.workspace_transition.acceptance_unchanged-ne$true-or$null-ne$d.failure){throw 'Reconciliation workspace transition is not exact.'}
    if([string]$d.publication.scope-cne'planning-published-prerequisite-suffix'-or[int]$d.publication.commit_count-ne1-or$d.publication.fast_forward_verified-ne$true-or$d.publication.force_push_used-ne$false-or$d.publication.force_with_lease_used-ne$false-or$d.publication.rewrite_used-ne$false){throw 'Reconciliation does not prove one no-force, non-rewritten planning publication.'}
    if([DateTimeOffset]::Parse([string]$d.publication.observed_at)-lt[DateTimeOffset]::Parse([string]$accounting.document.chronology.accounted_at)){throw 'Reconciliation observation predates planned accounting.'}
    $planning=@($accounting.document.repositories|Where-Object{$_.role-eq'planning-transport'});if($planning.Count-ne1){throw 'Bound accounting does not contain exactly one planning repository.'};$p=$planning[0];$rp=$d.planning_repository
    $executionFinal=if($null-ne$p.PSObject.Properties['intervening_accepted_publication']){[string]$p.intervening_accepted_publication.executed_final_revision}else{[string]$p.final_revision}
    if([string]$rp.repo_id-cne[string]$p.repo_id-or[string]$rp.branch-cne[string]$p.branch-or[string]$rp.upstream-cne[string]$p.upstream-or[string]$rp.execution_final_revision-cne$executionFinal-or[string]$rp.published_suffix_parent-cne$executionFinal-or[string]$rp.current_remote_readback_revision-cne[string]$rp.published_suffix_revision-or$rp.worktree_clean-ne$true){throw 'Planning execution, parent, identity, or readback binding mismatch.'}
    if([string]$rp.executed_push_receipt.sha256-cne[string]$accounting.document.executed_push_receipt.sha256-or[string]$rp.publication_accounting_receipt.sha256-cne[string]$d.planned_publication_accounting.sha256){throw 'Published receipt hashes do not match ordinary accounting.'}
    $paths=@($d.publication.changed_paths|ForEach-Object{[string]$_});$required=@([string]$rp.executed_push_receipt.path,[string]$rp.publication_accounting_receipt.path|Sort-Object -Unique);if($paths.Count-ne2-or(@($paths|Sort-Object -Unique)-join'|')-cne(@($required|Sort-Object)-join'|')){throw 'Published suffix must name exactly the two bound receipt paths.'}
    $sources=@($accounting.document.repositories|Where-Object{$_.role-eq'source'});if(@($d.source_repositories).Count-ne$sources.Count){throw 'Reconciliation source coverage mismatch.'};$seen=@{}
    foreach($s in @($d.source_repositories)){if($seen.ContainsKey([string]$s.repo_id)){throw 'Reconciliation repeats a source repository.'};$seen[[string]$s.repo_id]=$true;$a=@($sources|Where-Object{$_.repo_id-ceq$s.repo_id});if($a.Count-ne1){throw "Unknown source repository '$($s.repo_id)'."};$expected=if($null-ne$a[0].PSObject.Properties['intervening_accepted_publication']){[string]$a[0].intervening_accepted_publication.executed_final_revision}else{[string]$a[0].final_revision};if([string]$s.execution_final_revision-cne$expected-or[string]$s.current_remote_readback_revision-cne$expected-or[string]$s.branch-cne[string]$a[0].branch-or[string]$s.upstream-cne[string]$a[0].upstream-or$s.history_unchanged-ne$true-or$s.worktree_clean-ne$true){throw "Source repository '$($s.repo_id)' does not bind unchanged execution state."}}
    [pscustomobject]@{document=$d;accounting=$accounting;reconciliation_sha256=Get-PlannedPublicationHash $Path;accounting_path=$accountingPath}
}

function Test-MorphospacePublishedPrerequisiteSuffixLive {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$State,[Parameter(Mandatory)][hashtable]$RepositoryMap,[Parameter(Mandatory)][object[]]$RepositoryStates)
    $v=Test-MorphospacePublishedPrerequisiteSuffixDocument $Path $WorkspaceRoot;$d=$v.document
    if([string]$Spec.project_id-cne[string]$d.project_id-or$null-ne$State.current_unit-or$null-eq$State.pending_push_bundle-or[string]$State.pending_push_bundle.bundle_id-cne[string]$d.bundle_id-or(@($State.pending_push_bundle.unit_ids)-join'|')-cne(@($v.accounting.plan.unit_ids)-join'|')-or(@($State.pending_push_bundle.repo_ids)-join'|')-cne(@($v.accounting.plan.repositories.repo_id)-join'|')){throw 'Reconciliation does not match the exact pending bundle/project state.'}
    foreach($r in @($d.source_repositories)+@($d.planning_repository)){$id=[string]$r.repo_id;if(-not$RepositoryMap.ContainsKey($id)){throw "Repository '$id' is not mapped."};$s=@($RepositoryStates|Where-Object{$_.repo_id-ceq$id});if($s.Count-ne1-or$s[0].dirty-ne$false-or$s[0].diverged-eq$true-or[int]$s[0].ahead-ne0-or[int]$s[0].behind-ne0-or[string]$s[0].branch-cne[string]$r.branch-or[string]$s[0].upstream-cne[string]$r.upstream){throw "Repository '$id' is dirty, ahead, behind, divergent, or identity-mismatched."};$repo=[string]$RepositoryMap[$id].path;$remote=@(Invoke-PublishedPrerequisiteGit $repo @('rev-parse',[string]$r.upstream) "Repository '$id' upstream readback")[0];if([string]$s[0].head-cne[string]$remote-or[string]$remote-cne[string]$r.current_remote_readback_revision){throw "Repository '$id' is not clean upstream-exact at the bound revision."};[void](Invoke-PublishedPrerequisiteGit $repo @('cat-file','-e',"$remote^{commit}") "Repository '$id' bound commit");$tree=@(Invoke-PublishedPrerequisiteGit $repo @('rev-parse',"$remote^{tree}") "Repository '$id' bound tree")[0];if($r.PSObject.Properties.Name-contains'execution_final_tree' -and $r.repo_id-cne$d.planning_repository.repo_id-and[string]$tree-cne[string]$r.execution_final_tree){throw "Source repository '$id' tree mismatch."}}
    $rp=$d.planning_repository;$repo=[string]$RepositoryMap[[string]$rp.repo_id].path
    $executedWorkspacePath=[IO.Path]::GetFullPath((Join-Path $WorkspaceRoot ([string]$v.accounting.document.executed_push_receipt.path)));$expectedExecutedRelative=[IO.Path]::GetRelativePath($repo,$executedWorkspacePath).Replace('\','/');$expectedAccountingRelative=[IO.Path]::GetRelativePath($repo,$v.accounting_path).Replace('\','/')
    if([string]$rp.executed_push_receipt.path-cne$expectedExecutedRelative-or[string]$rp.publication_accounting_receipt.path-cne$expectedAccountingRelative){throw 'Published receipt paths do not resolve to the exact bound workspace evidence.'}
    foreach($pair in @(@($rp.execution_final_revision,$rp.execution_final_tree),@($rp.published_suffix_revision,$rp.published_suffix_tree))){[void](Invoke-PublishedPrerequisiteGit $repo @('cat-file','-e',"$($pair[0])^{commit}") 'Planning bound object');$tree=@(Invoke-PublishedPrerequisiteGit $repo @('rev-parse',"$($pair[0])^{tree}") 'Planning bound tree')[0];if([string]$tree-cne[string]$pair[1]){throw 'Planning commit/tree binding mismatch.'}}
    $commits=@(Invoke-PublishedPrerequisiteGit $repo @('rev-list','--reverse',"$($rp.execution_final_revision)..$($rp.published_suffix_revision)") 'Published suffix enumeration');if($commits.Count-ne1-or[string]$commits[0]-cne[string]$rp.published_suffix_revision){throw 'Planning remote did not advance by exactly one descendant commit.'};$parent=@(Invoke-PublishedPrerequisiteGit $repo @('rev-parse',"$($rp.published_suffix_revision)^1") 'Published suffix parent')[0];if([string]$parent-cne[string]$rp.execution_final_revision-or[string]$parent-cne[string]$rp.published_suffix_parent){throw 'Published suffix has alternate ancestry.'}
    $paths=@(Invoke-PublishedPrerequisiteGit $repo @('diff-tree','--no-commit-id','--name-only','-r',[string]$rp.published_suffix_revision) 'Published suffix paths'|ForEach-Object{[string]$_}|Sort-Object);if(($paths-join'|')-cne(@($d.publication.changed_paths|ForEach-Object{[string]$_}|Sort-Object)-join'|')){throw 'Published suffix contains missing or extra paths.'}
    foreach($binding in @($rp.executed_push_receipt,$rp.publication_accounting_receipt)){if((Get-PublishedPrerequisiteBlobSha256 $repo ([string]$rp.published_suffix_revision) ([string]$binding.path))-cne[string]$binding.sha256){throw "Published receipt hash mismatch for '$($binding.path)'."}}
    $v
}

Export-ModuleMember -Function Test-MorphospacePublishedPrerequisiteSuffixDocument,Test-MorphospacePublishedPrerequisiteSuffixLive
