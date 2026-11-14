# Private implementation included by SourceOnlyPublication.psm1. The original
# source-only owner supplies the authenticated plan, Git and ledger primitives.

function Assert-SourceOnlyFailureJsonUniqueKeys {
    param([System.Text.Json.JsonElement]$Element)
    if($Element.ValueKind-eq[System.Text.Json.JsonValueKind]::Object){
        $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Element.EnumerateObject()){if(-not$keys.Add($property.Name)){throw 'Source-only failure JSON repeats a property.'};Assert-SourceOnlyFailureJsonUniqueKeys $property.Value}
    }elseif($Element.ValueKind-eq[System.Text.Json.JsonValueKind]::Array){foreach($item in $Element.EnumerateArray()){Assert-SourceOnlyFailureJsonUniqueKeys $item}}
}

function Read-SourceOnlyFailureJson {
    param([string]$Path)
    $raw=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    $options=[System.Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=64
    $json=[System.Text.Json.JsonDocument]::Parse($raw,$options)
    try{Assert-SourceOnlyFailureJsonUniqueKeys $json.RootElement}finally{$json.Dispose()}
    return $raw|ConvertFrom-Json -Depth 64 -DateKind String
}

function Resolve-SourceOnlyFailureReference {
    param([object]$Context,[object]$Reference,[switch]$Json)
    Assert-MorphospaceExactPropertySet $Reference @('path','bytes','sha256') -Context 'Source-only failure reference'
    $path=[IO.Path]::GetFullPath($(if([IO.Path]::IsPathRooted([string]$Reference.path)){[string]$Reference.path}else{Join-Path $Context.workspace ([string]$Reference.path)}))
    $roots=if($Context.PSObject.Properties.Name-contains'capsule_root'){@([string]$Context.capsule_root)}else{@((Join-Path $Context.workspace 'local'),(Join-Path (Split-Path -Parent $Context.workspace) 'local'))}
    $contained=$false
    foreach($root in $roots){$prefix=[IO.Path]::GetFullPath($root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;if($path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$contained=$true}}
    if(-not$contained){throw 'Source-only failure evidence is outside its retained local capsule.'}
    Assert-MorphospaceNoReparseAncestor (Split-Path -Parent $Context.workspace) $path
    if(-not[IO.File]::Exists($path)-or[long]$Reference.bytes-ne([IO.FileInfo]$path).Length-or
       [string]$Reference.sha256-cnotmatch'^[0-9a-f]{64}$'-or(Get-MorphospaceFileSha256 $path)-cne[string]$Reference.sha256){throw 'Source-only failure evidence bytes or hash drifted.'}
    if($Json){return Read-SourceOnlyFailureJson $path};return $path
}

function Test-SourceOnlyFailureCheckedResult {
    param([object]$Context,[object]$Reference,[int]$ExitCode)
    $result=Resolve-SourceOnlyFailureReference $Context $Reference -Json
    Assert-MorphospaceExactPropertySet $result @('exit_code','original_wait_returned','stdout_eof','stderr_eof','completed_utc','elapsed_seconds','stdout','stderr') -Context 'Source-only checked result'
    if(($result.exit_code-isnot[int]-and$result.exit_code-isnot[long])-or[long]$result.exit_code-ne$ExitCode){throw 'Source-only checked result has an unknown or unexpected exit code.'}
    foreach($claim in @('original_wait_returned','stdout_eof','stderr_eof')){if($result.$claim-isnot[bool]-or-not$result.$claim){throw 'Source-only checked result is not closed with original wait and stream EOF.'}}
    if($result.elapsed_seconds-isnot[ValueType]-or[double]$result.elapsed_seconds-lt0){throw 'Source-only checked result duration is invalid.'}
    foreach($stream in @('stdout','stderr')){[void](Resolve-SourceOnlyFailureReference $Context $result.$stream)}
    try{$completed=[DateTimeOffset]::Parse([string]$result.completed_utc,[Globalization.CultureInfo]::InvariantCulture)}catch{throw 'Source-only checked result completion is invalid.'}
    return $completed
}

function Get-SourceOnlyFailureProviderReadback {
    param([object]$Context,[object]$Planned,[object]$PullRequest)
    # Fixed read-only commands. No caller commands, endpoint, executable or
    # provider callback can cross the public owner interface.
    $url=[string]$Planned.remote_url
    if($url-cnotmatch'^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git$'){throw 'Source-only failure retirement supports only the declared GitHub HTTPS provider.'}
    $repository=$Matches[1];$number=[int]$PullRequest.number
    if($number-lt1-or[string]$PullRequest.url-cne"https://github.com/$repository/pull/$number"){throw 'Source-only failure PR subject differs from the declared provider.'}
    $gh=Get-MorphospaceBoundExecutable -Name 'gh'
    $prResult=Invoke-MorphospaceBoundProcessBytes -Executable $gh.path -ExpectedExecutableSha256 $gh.sha256 -WorkingDirectory $Context.workspace -Arguments @('pr','view',[string]$number,'--repo',$repository,'--json','number,url,state,isCrossRepository,headRefName,headRefOid,baseRefName,baseRefOid,mergedAt,mergeCommit') -TimeoutSeconds 30 -MaxOutputBytes 1048576
    $pr=([Text.UTF8Encoding]::new($false,$true).GetString($prResult.stdout))|ConvertFrom-Json -DateKind String
    $checksResult=Invoke-MorphospaceBoundProcessBytes -Executable $gh.path -ExpectedExecutableSha256 $gh.sha256 -WorkingDirectory $Context.workspace -Arguments @('pr','checks',[string]$number,'--repo',$repository,'--required','--json','name,state,bucket,link') -TimeoutSeconds 30 -MaxOutputBytes 1048576 -AllowFailure
    if($checksResult.exit_code-ne1){throw 'Source-only failure provider required checks are not a known failed terminal result.'}
    $checks=([Text.UTF8Encoding]::new($false,$true).GetString($checksResult.stdout))|ConvertFrom-Json -DateKind String
    return [pscustomobject]@{pull_request=$pr;required_checks=@($checks)}
}

function Assert-SourceOnlyFailureProviderReadback {
    param([object]$Readback,[object]$Planned,[object]$PullRequest)
    Assert-MorphospaceExactPropertySet $Readback @('pull_request','required_checks') -Context 'Source-only failure provider readback'
    $pr=$Readback.pull_request
    Assert-MorphospaceExactPropertySet $pr @('number','url','state','isCrossRepository','headRefName','headRefOid','baseRefName','baseRefOid','mergedAt','mergeCommit') -Context 'Source-only failure provider PR'
    if([int]$pr.number-ne[int]$PullRequest.number-or[string]$pr.url-cne[string]$PullRequest.url-or[string]$pr.state-cne'OPEN'-or
       $pr.isCrossRepository-isnot[bool]-or$pr.isCrossRepository-or$null-ne$pr.mergedAt-or$null-ne$pr.mergeCommit-or
       [string]$pr.headRefName-cne[string]$Planned.candidate_branch-or[string]$pr.headRefOid-cne[string]$Planned.candidate_revision-or
       [string]$pr.baseRefName-cne[string]$Planned.target_branch-or[string]$pr.baseRefOid-cne[string]$Planned.old_revision){throw 'Source-only failure provider PR is merged, unknown, or detached from the exact plan.'}
    Assert-SourceOnlyFailureRequiredChecks @($Readback.required_checks)
}

function Assert-SourceOnlyFailureRequiredChecks {
    param([object[]]$Checks)
    $checks=@($Checks);$names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$failed=$false
    if($checks.Count-eq0){throw 'Source-only failure provider has no known required checks.'}
    foreach($check in $checks){
        Assert-MorphospaceExactPropertySet $check @('name','state','bucket','link') -Context 'Source-only failure required check'
        if([string]::IsNullOrWhiteSpace([string]$check.name)-or-not$names.Add([string]$check.name)-or[string]$check.link-cnotmatch'^https://github\.com/'-or
           [string]$check.bucket-notin@('pass','fail','skipping')-or[string]$check.state-notin@('SUCCESS','FAILURE','SKIPPED','NEUTRAL')){throw 'Source-only failure provider required-check outcome is unknown or repeated.'}
        if(([string]$check.bucket-ceq'fail')-ne([string]$check.state-ceq'FAILURE')){throw 'Source-only failure required-check state and bucket disagree.'}
        if([string]$check.bucket-ceq'fail'){$failed=$true}
    }
    if(-not$failed){throw 'Source-only failure provider has no failed required check.'}
}

function Test-SourceOnlyFailureEvidence {
    param([object]$Context,[object]$Plan,[object]$Reference)
    $evidence=Resolve-SourceOnlyFailureReference $Context $Reference -Json
    Assert-MorphospaceExactPropertySet $evidence @('schema','publication_id','project_id','trigger_unit_id','repo_id','executor_id','plan_sha256','capsule_root','operation_start','push_verification','pull_request','required_check_watch') -Context 'Source-only failure evidence'
    if([string]$evidence.capsule_root-cnotmatch'^(?:\.\./)?local/[A-Za-z0-9_-][A-Za-z0-9._/-]*$'){throw 'Source-only failure capsule root is not a retained local path.'}
    $capsule=[IO.Path]::GetFullPath((Join-Path $Context.workspace ([string]$evidence.capsule_root)))
    # Validate the declaration before narrowing every nested original reference
    # to it. Absolute paths inside the immutable original JSON remain intact.
    $localRoots=@((Join-Path $Context.workspace 'local'),(Join-Path (Split-Path -Parent $Context.workspace) 'local'))
    $validRoot=$false
    foreach($root in $localRoots){$prefix=[IO.Path]::GetFullPath($root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;if($capsule.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$validRoot=$true}}
    if(-not$validRoot-or-not[IO.Directory]::Exists($capsule)){throw 'Source-only failure capsule root is missing or outside retained local storage.'}
    Assert-MorphospaceNoReparseAncestor (Split-Path -Parent $Context.workspace) $capsule
    $planningRoot=Get-SourceOnlyGitValue $Context.workspace @('rev-parse','--show-toplevel') 'Failure capsule planning owner'
    $capsuleRelative=[IO.Path]::GetRelativePath($planningRoot,$capsule).Replace('\','/')
    if($capsuleRelative.StartsWith('../',[StringComparison]::Ordinal)-or[IO.Path]::IsPathRooted($capsuleRelative)){throw 'Source-only failure capsule is outside its planning repository.'}
    # check-ignore takes literal pathnames and rejects Git's global literal
    # pathspec magic. Keep this fixed read-only command separately bound.
    $git=Get-MorphospaceBoundExecutable -Name 'git'
    $ignored=Invoke-MorphospaceBoundProcessBytes -Executable $git.path -ExpectedExecutableSha256 $git.sha256 -WorkingDirectory $planningRoot -Arguments @('--no-optional-locks','--no-replace-objects','-c','core.hooksPath=NUL','-C',$planningRoot,'check-ignore','--quiet','--',($capsuleRelative+'/')) -TimeoutSeconds 30 -MaxOutputBytes 1048576 -AllowFailure
    if($ignored.exit_code-ne0){throw "Source-only failure capsule root must be ignored by its planning owner (Git exit $($ignored.exit_code))."}
    $Context=[pscustomobject]@{workspace=$Context.workspace;capsule_root=$capsule}
    [void](Resolve-SourceOnlyFailureReference $Context $Reference)
    $rows=@($Plan.source_repositories)
    if($rows.Count-ne1-or[string]$rows[0].publication_mode-cne'provider-merge'){throw 'Source-only failure retirement requires exactly one provider-merge source.'}
    $row=$rows[0]
    if([string]$evidence.schema-cne'rusty.morphospace.workflow.source_only_publication_failure_evidence.v1'-or
       [string]$evidence.publication_id-cne[string]$Plan.publication_id-or[string]$evidence.project_id-cne[string]$Plan.project_id-or
       [string]$evidence.trigger_unit_id-cne[string]$Plan.trigger_unit_id-or[string]$evidence.repo_id-cne[string]$row.repo_id-or
       [string]$evidence.executor_id-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$'){throw 'Source-only failure evidence subject differs from the exact plan.'}
    $planPath=Resolve-MorphospaceWorkspacePath $Context.workspace "receipts/$($Plan.publication_id)-plan.json" -RequireLeaf
    if([string]$evidence.plan_sha256-cne(Get-MorphospaceFileSha256 $planPath)){throw 'Source-only failure evidence plan hash drifted.'}
    $start=Resolve-SourceOnlyFailureReference $Context $evidence.operation_start -Json
    Assert-MorphospaceExactPropertySet $start @('schema','publication_id','plan_sha256','dependency_ordinal','repo_id','operation_started_at','preservation') -Context 'Source-only failure operation start'
    Assert-MorphospaceExactPropertySet $start.preservation @('external_operation_performed','git_mutation_performed','execution_success_inferred') -Context 'Source-only failure operation start preservation'
    foreach($claim in @('external_operation_performed','git_mutation_performed','execution_success_inferred')){if($start.preservation.$claim-isnot[bool]-or$start.preservation.$claim){throw 'Source-only failure start infers an external effect.'}}
    if([string]$start.schema-cne'rusty.morphospace.workflow.source_only_publication_operation_start.v1'-or[string]$start.publication_id-cne[string]$Plan.publication_id-or
       [string]$start.plan_sha256-cne[string]$evidence.plan_sha256-or[string]$start.repo_id-cne[string]$row.repo_id-or[int]$start.dependency_ordinal-ne1){throw 'Source-only failure start is detached from the exact plan.'}
    $started=Test-MorphospaceStrictUtcTimestamp ([string]$start.operation_started_at)
    $push=Resolve-SourceOnlyFailureReference $Context $evidence.push_verification -Json
    Assert-MorphospaceExactPropertySet $push @('before','after','remote_before','remote_after','original_checked_result','force_used','upstream_changed','completed_utc') -Context 'Source-only failure push verification'
    if($push.force_used-isnot[bool]-or$push.force_used-or$push.upstream_changed-isnot[bool]-or$push.upstream_changed){throw 'Source-only failure push used force or changed upstream.'}
    foreach($when in @('before','after')){
        $snapshot=$push.$when;Assert-MorphospaceExactPropertySet $snapshot @('head','tree','branch','upstream','status','remote') -Context 'Source-only failure pushed source snapshot'
        if([string]$snapshot.head-cne[string]$row.candidate_revision-or[string]$snapshot.tree-cne[string]$row.candidate_tree-or[string]$snapshot.branch-cne[string]$row.candidate_branch-or[string]$snapshot.upstream-cne[string]$row.upstream-or[string]$snapshot.status-cne''-or[string]$snapshot.remote-cne[string]$row.remote_url){throw 'Source-only failure pushed source identity differs from its plan.'}
    }
    $targetRef="refs/heads/$($row.target_branch)";$featureRef="refs/heads/$($row.candidate_branch)"
    Assert-MorphospaceExactPropertySet $push.remote_before @($targetRef) -Context 'Source-only failure pre-push refs'
    Assert-MorphospaceExactPropertySet $push.remote_after @($targetRef,$featureRef) -Context 'Source-only failure post-push refs'
    if([string]$push.remote_before.$targetRef-cne[string]$row.old_revision-or[string]$push.remote_after.$targetRef-cne[string]$row.old_revision-or[string]$push.remote_after.$featureRef-cne[string]$row.candidate_revision){throw 'Source-only failure push target or feature ref differs from the plan.'}
    $pushAt=Test-SourceOnlyFailureCheckedResult $Context $push.original_checked_result 0
    $pr=Resolve-SourceOnlyFailureReference $Context $evidence.pull_request -Json
    Assert-MorphospaceExactPropertySet $pr @('url','number','created_utc','candidate','original_checked_result') -Context 'Source-only failure PR creation'
    if([string]$pr.candidate-cne[string]$row.candidate_revision-or[int]$pr.number-lt1){throw 'Source-only failure PR creation subject differs.'}
    $prAt=Test-SourceOnlyFailureCheckedResult $Context $pr.original_checked_result 0
    $failedAt=Test-SourceOnlyFailureCheckedResult $Context $evidence.required_check_watch 1
    if($started-gt$pushAt-or$pushAt-gt$prAt-or$prAt-gt$failedAt){throw 'Source-only failure actual operation chronology is invalid.'}
    return [pscustomobject]@{evidence=$evidence;start=$start;pull_request=$pr;failed_at=$failedAt}
}

function Get-SourceOnlyFailureReadback {
    param([object]$Context,[object]$Plan,[object]$Evidence)
    $row=@($Plan.source_repositories)[0];$source=@($Context.map.repositories|Where-Object{[string]$_.repo_id-ceq[string]$row.repo_id})
    if($source.Count-ne1){throw 'Source-only failure source map is ambiguous.'}
    $target=Get-SourceOnlyRemoteReadback ([string]$source[0].path) ([string]$row.remote_url) ([string]$row.target_branch)
    $feature=Get-SourceOnlyRemoteReadback ([string]$source[0].path) ([string]$row.remote_url) ([string]$row.candidate_branch)
    if($target-cne[string]$row.old_revision-or$feature-cne[string]$row.candidate_revision){throw 'Source-only failure target or feature readback drifted; retain the pending bundle.'}
    $provider=Get-SourceOnlyFailureProviderReadback $Context $row $Evidence.pull_request
    Assert-SourceOnlyFailureProviderReadback $provider $row $Evidence.pull_request
    return $provider
}
