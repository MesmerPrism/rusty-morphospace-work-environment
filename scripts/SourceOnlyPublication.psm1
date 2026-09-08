Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceContentObservation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationReceipt.psm1') -Force

if($IsWindows-and-not('MorphospaceSourceOnlyFileIdentity'-as[type])){Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class MorphospaceSourceOnlyFileIdentity {
 [StructLayout(LayoutKind.Sequential)] struct ID128 {[MarshalAs(UnmanagedType.ByValArray,SizeConst=16)] public byte[] v;}
 [StructLayout(LayoutKind.Sequential)] struct INFO {public UInt64 volume; public ID128 id;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr q,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h,int c,out INFO i,uint z);
 public static string Directory(string p){using(var h=CreateFileW(p,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)){if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error()); INFO i;if(!GetFileInformationByHandleEx(h,18,out i,(uint)Marshal.SizeOf<INFO>()))throw new Win32Exception(Marshal.GetLastWin32Error());return i.volume.ToString("x16")+":"+BitConverter.ToString(i.id.v).Replace("-","").ToLowerInvariant();}}
}
'@}

function Copy-SourceOnlyDocument { param([object]$Value) return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json) }

function Invoke-SourceOnlyGit {
    param([string]$Repository,[string[]]$Arguments,[string]$Context,[switch]$AllowFailure)
    if($null-eq(Get-Variable -Name SourceOnlyGitExecutable -Scope Script -ValueOnly -ErrorAction SilentlyContinue)){$script:SourceOnlyGitExecutable=Get-MorphospaceBoundExecutable -Name 'git'}
    $safeArguments=@('--no-optional-locks','--no-replace-objects','--literal-pathspecs','-c','core.quotepath=false','-c','color.ui=false','-c','core.fsmonitor=false','-c','diff.external=','-c','core.hooksPath=NUL','-C',$Repository)+$Arguments
    $result=Invoke-MorphospaceBoundProcessBytes -Executable $script:SourceOnlyGitExecutable.path -Arguments $safeArguments -WorkingDirectory $Repository -ExpectedExecutableSha256 $script:SourceOnlyGitExecutable.sha256 -TimeoutSeconds 30 -MaxOutputBytes 1048576 -AllowFailure:$AllowFailure
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($result.stdout)
    $lines=if($text.Length-eq0){@()}else{@($text.TrimEnd("`r","`n").Split("`n")|ForEach-Object{$_.TrimEnd("`r")})}
    return [pscustomobject]@{ code=$result.exit_code; lines=$lines }
}

function Get-SourceOnlyGitValue { param([string]$Repository,[string[]]$Arguments,[string]$Context)
    $result=Invoke-SourceOnlyGit $Repository $Arguments $Context
    $lines=@($result.lines);if($lines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($lines[0])){throw "$Context did not return exactly one value."}
    return $lines[0].Trim()
}

function Get-SourceOnlyGitCommonDirectory {
    param([string]$Repository,[string]$Context)
    return (Get-SourceOnlyGitValue $Repository @('rev-parse','--path-format=absolute','--git-common-dir') $Context).TrimEnd('\','/')
}

function Get-SourceOnlyPhysicalDirectoryIdentity {
    param([string]$Path,[string]$Context)
    if(-not$IsWindows){throw "$Context requires Windows FileIdInfo physical identity support."}
    try{return [MorphospaceSourceOnlyFileIdentity]::Directory([IO.Path]::GetFullPath($Path))}catch{throw "$Context physical identity observation failed: $($_.Exception.Message)"}
}

function Assert-SourceOnlyCleanGitRepository {
    param([string]$Repository,[string]$Context)
    $status=Invoke-SourceOnlyGit $Repository @('status','--porcelain=v1','--untracked-files=all') $Context
    if(@($status.lines).Count-ne0){throw "$Context is dirty."}
}

function Assert-SourceOnlyPreparedPlanningWorktree {
    param([string]$PlanningRoot,[string]$Workspace,[string]$PublicationId,[ValidateSet('preparation','recording')][string]$Phase='preparation')
    $workspaceRelative=[IO.Path]::GetRelativePath($PlanningRoot,$Workspace).Replace('\','/').TrimEnd('/')
    if($workspaceRelative-cmatch'(^|/)\.\.(/|$)'){throw 'Source-only workspace is not contained by the planning worktree.'}
    $eventId="$PublicationId-source-publication-prepared";$transactionId="$eventId-transition"
    $allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($path in @('workspace.state.json','iteration-events.jsonl',"receipts/$PublicationId-plan.json","receipts/transactions/$transactionId.intent.json","receipts/transactions/$transactionId.completion.json","receipts/transactions/$transactionId.artifact-0.pending")){[void]$allowed.Add("$workspaceRelative/$path")}
    if($Phase-ceq'recording'){
        $recordEventId="$PublicationId-source-publication-recorded";$recordTransactionId="$recordEventId-transition"
        foreach($path in @("receipts/$PublicationId-execution.json","receipts/transactions/$recordTransactionId.intent.json","receipts/transactions/$recordTransactionId.completion.json","receipts/transactions/$recordTransactionId.artifact-0.pending")){[void]$allowed.Add("$workspaceRelative/$path")}
    }
    $status=Invoke-SourceOnlyGit $PlanningRoot @('status','--porcelain=v1','--untracked-files=all') 'prepared local-only planning owner status'
    foreach($line in @($status.lines)){if($line.Length-lt4){throw 'Prepared local-only planning owner returned malformed status.'};$path=$line.Substring(3).Replace('\','/');if($path.StartsWith('"')){throw 'Prepared local-only planning owner returned quoted status evidence.'};if(-not$allowed.Contains($path)){throw "Prepared local-only planning owner has unrelated dirty path '$path'."}}
}

function Get-SourceOnlyRemoteReadback {
    param([string]$Repository,[string]$RemoteUrl,[string]$Branch)
    $lines=@((Invoke-SourceOnlyGit $Repository @('ls-remote','--refs',$RemoteUrl,"refs/heads/$Branch") "source remote '$RemoteUrl/$Branch' direct readback").lines|Where-Object{$_})
    if($lines.Count-ne1){throw "Source remote '$RemoteUrl/$Branch' did not return exactly one branch ref."}
    $fields=@($lines[0].Split("`t",[StringSplitOptions]::None))
    if($fields.Count-ne2-or$fields[0]-cnotmatch'^[0-9a-f]{40}$'-or$fields[1]-cne"refs/heads/$Branch"){throw "Source remote '$RemoteUrl/$Branch' returned an invalid branch readback."}
    return $fields[0]
}

function Test-SourceOnlyPathAllowed { param([string]$Path,[object[]]$Allowed)
    if($Path -cmatch '\\' -or $Path.StartsWith('/') -or $Path -match '(^|/)\.\.(/|$)'){return $false}
    foreach($raw in @($Allowed)){
        $a=([string]$raw).Replace('\','/').TrimEnd('/')
        if($Path.Equals($a,[StringComparison]::Ordinal)-or $Path.StartsWith($a+'/',[StringComparison]::Ordinal)){return $true}
    }
    return $false
}

function Assert-SourceOnlySetEqual { param([object[]]$Expected,[object[]]$Actual,[string]$Label)
    $expectedSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$actualSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($value in @($Expected)){if(-not$expectedSet.Add([string]$value)){throw "$Label repeats an expected identity."}}
    foreach($value in @($Actual)){if(-not$actualSet.Add([string]$value)){throw "$Label repeats an actual identity."}}
    if($expectedSet.Count-ne$actualSet.Count){throw "$Label does not exactly match the declared set."};foreach($value in $expectedSet){if(-not$actualSet.Contains($value)){throw "$Label does not exactly match the declared set."}}
}

function Get-SourceOnlyContext {
    param([string]$WorkspaceRoot,[string]$UnitId,[string]$RepoMapPath,[switch]$AllowPartialLedger)
    $repoRoot=Split-Path $PSScriptRoot -Parent;$workspace=(Resolve-Path $WorkspaceRoot).Path;$mapPath=(Resolve-Path $RepoMapPath).Path
    $mapRaw=Get-Content -Raw -LiteralPath $mapPath
    if(-not(Test-Json -Json $mapRaw -SchemaFile (Join-Path $repoRoot 'schemas\repository-map.schema.json'))){throw 'Repository map does not satisfy its schema.'}
    $map=Read-MorphospaceProtocolJson $mapPath
    $projectPath=Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf
    $statePath=Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
    $unitRelative="iteration-units/$UnitId.json";$unitPath=Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf
    $eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $project=Read-MorphospaceProtocolJson $projectPath;$state=Read-MorphospaceProtocolJson $statePath;$unit=Read-MorphospaceProtocolJson $unitPath
    $eventLines=@(Get-Content -LiteralPath $eventsPath|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
    if($eventLines.Count-eq0){throw 'Iteration event ledger must be non-empty.'};$tail=$eventLines[-1]|ConvertFrom-Json
    if(-not$AllowPartialLedger-and[string]$state.last_event_id-cne[string]$tail.event_id){throw 'Workspace state does not match the event-ledger tail.'}
    if([string]$project.project_id-cne[string]$state.project_id-or[string]$project.project_id-cne[string]$unit.project_id-or[string]$unit.unit_id-cne$UnitId){throw 'Project, state, and trigger-unit identity do not match.'}
    return [pscustomobject]@{repo_root=$repoRoot;workspace=$workspace;map=$map;map_path=$mapPath;project=$project;project_path=$projectPath;state=$state;state_path=$statePath;unit=$unit;unit_path=$unitPath;unit_relative=$unitRelative;events_path=$eventsPath;tail=$tail}
}

function Resolve-SourceOnlyValidationArtifactPath {
    param([string]$ReceiptPath,[string]$ArtifactPath,[string]$ArtifactId)
    $resolved=if([IO.Path]::IsPathRooted($ArtifactPath)){[IO.Path]::GetFullPath($ArtifactPath)}else{[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ReceiptPath) $ArtifactPath))}
    if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "Accepted trigger validation artifact '$ArtifactId' does not exist: $ArtifactPath"}
    return $resolved
}

function Test-SourceOnlyCommittedPredecessorTransition {
    param([object]$Context,[string]$TransactionId,[object]$PendingSuccessorIntent)
    try{
        return Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Context.workspace -TransactionId $TransactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $Context.unit_relative -ExpectedEventsPath 'iteration-events.jsonl'
    }catch{
        if($null-eq$PendingSuccessorIntent-or$_.Exception.Message-cne'Transition ledger tail completion does not own its target state projection.'){throw}
        $intentPath=Resolve-MorphospaceWorkspacePath $Context.workspace "receipts/transactions/$TransactionId.intent.json" -RequireLeaf
        $completionPath=Resolve-MorphospaceWorkspacePath $Context.workspace "receipts/transactions/$TransactionId.completion.json" -RequireLeaf
        $predecessorIntent=Read-MorphospaceProtocolJson $intentPath;$completion=Read-MorphospaceProtocolJson $completionPath
        $currentStateHash=Get-MorphospaceCanonicalJsonSha256 $Context.state;$currentUnitHash=Get-MorphospaceCanonicalJsonSha256 $Context.unit
        $eventsHash=Get-MorphospaceFileSha256 $Context.events_path;$eventsLength=([IO.FileInfo]$Context.events_path).Length
        if([string]$Context.tail.event_id-cne[string]$predecessorIntent.event.event_id-or
           [string]$PendingSuccessorIntent.expected.event_tail_id-cne[string]$predecessorIntent.event.event_id-or
           [int]$PendingSuccessorIntent.event.sequence-ne([int]$predecessorIntent.event.sequence+1)-or
           [string]$PendingSuccessorIntent.pre.state.sha256-cne[string]$predecessorIntent.target.state.sha256-or
           [string]$PendingSuccessorIntent.pre.unit.sha256-cne[string]$predecessorIntent.target.unit.sha256-or
           [string]$PendingSuccessorIntent.expected.events_sha256-cne$eventsHash-or
           [int64]$PendingSuccessorIntent.expected.events_length-ne$eventsLength-or
           [string]$PendingSuccessorIntent.target.state.sha256-cne$currentStateHash-or
           [string]$PendingSuccessorIntent.target.unit.sha256-cne$currentUnitHash){
            throw 'Source-only pending successor does not authenticate the temporarily projected predecessor tail.'
        }
        return [pscustomobject][ordered]@{transaction_id=$TransactionId;status='committed';intent=$predecessorIntent;completion=$completion;event_tail_id=[string]$Context.tail.event_id}
    }
}

function Assert-SourceOnlyPlan {
    param([object]$Context,[object]$Plan,[string]$PlanPath,[switch]$AfterPrepare,[switch]$Recovery,[object]$PendingSuccessorIntent)
    $c=$Context;$repoRoot=$c.repo_root
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $PlanPath) -SchemaFile (Join-Path $repoRoot 'schemas\source-only-publication-plan-v1.schema.json'))){throw 'Source-only publication plan does not satisfy its schema.'}
    if([string]$Plan.project_id-cne[string]$c.project.project_id-or[string]$Plan.trigger_unit_id-cne[string]$c.unit.unit_id){throw 'Source-only publication plan identity does not match the owner workspace.'}
    if([string]$Plan.trigger.accepted_status-cne'accepted'-or[string]$Plan.trigger.push_checkpoint-cne'integration-batch'-or[string]$Plan.trigger.kind-notin@('accepted-development-integration','accepted-development-snapshot')){throw 'Source-only publication trigger is not an accepted development integration or snapshot.'}
    if([string]$c.unit.status-cne'accepted'){throw 'Source-only publication requires an accepted trigger unit.'}
    if([string]$c.unit.push_checkpoint-cne'integration-batch'){throw 'Source-only publication requires the accepted integration-batch checkpoint.'}
    $acceptance=$Plan.acceptance_transition;$acceptancePath=Resolve-MorphospaceWorkspacePath $c.workspace ([string]$acceptance.validation_receipt.path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $acceptancePath)-cne[string]$acceptance.validation_receipt.sha256){throw 'Accepted trigger validation receipt drifted.'}
    $acceptanceEvents=@(Get-Content -LiteralPath $c.events_path|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|ForEach-Object{$_|ConvertFrom-Json -DateKind String}|Where-Object{[string]$_.event_id-ceq[string]$acceptance.event_id})
    if($acceptanceEvents.Count-ne1-or[string]$acceptance.event_id-cnotmatch('^'+[regex]::Escape($c.unit.unit_id)+'-accepted-[0-9]{4,}$')-or[string]$acceptanceEvents[0].unit_id-cne$c.unit.unit_id-or@($acceptanceEvents[0].receipts)-cnotcontains[string]$acceptance.validation_receipt.path){throw 'Accepted trigger event does not bind the declared validation receipt.'}
    if([string]$acceptance.transaction_id-cne"$([string]$acceptance.event_id)-transition"){throw 'Accepted trigger transaction identity is noncanonical.'}
    $acceptedTransition=Test-SourceOnlyCommittedPredecessorTransition -Context $c -TransactionId ([string]$acceptance.transaction_id) -PendingSuccessorIntent $PendingSuccessorIntent
    if((Get-MorphospaceCanonicalJsonSha256 $acceptedTransition.intent.event)-cne(Get-MorphospaceCanonicalJsonSha256 $acceptanceEvents[0])-or[string]$acceptedTransition.intent.target.unit.document.status-cne'accepted'-or[string]$acceptedTransition.intent.target.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $c.unit)-or$null-ne$acceptedTransition.intent.target.state.document.current_unit){throw 'Accepted trigger owner transition does not authenticate the retained accepted unit.'}
    $acceptedValidation=Assert-MorphospaceValidationReceiptStructure -ReceiptPath $acceptancePath -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1'
    if([string]$acceptedValidation.unit_id-cne$c.unit.unit_id-or[string]$acceptedValidation.result-cne'pass'){throw 'Accepted trigger validation receipt is not a passing receipt for the trigger unit.'}
    $checkpoint=$acceptedTransition.intent.target.state.document.validation_checkpoint
    if($null-eq$checkpoint-or[string]$checkpoint.receipt-cne[string]$acceptance.validation_receipt.path-or[string]$checkpoint.result-cne'pass'-or[string]$checkpoint.tier-cne[string]$acceptedValidation.tier){throw 'Accepted trigger transition does not bind its exact passing validation checkpoint.'}
    if(@($acceptedValidation.criteria|Where-Object{[string]$_.status-cne'pass'}).Count-ne0-or@($acceptedValidation.gates|Where-Object{[string]$_.status-cne'pass'}).Count-ne0){throw 'Accepted trigger validation receipt contains a failed criterion or gate.'}
    foreach($artifact in @($acceptedValidation.artifacts)){$artifactPath=Resolve-SourceOnlyValidationArtifactPath $acceptancePath ([string]$artifact.path) ([string]$artifact.artifact_id);if((Get-MorphospaceFileSha256 $artifactPath)-cne([string]$artifact.sha256).ToLowerInvariant()){throw "Accepted trigger validation artifact '$($artifact.artifact_id)' drifted."}}
    $planning=@($c.map.repositories|Where-Object{[string]$_.role-ceq'planning'});if($planning.Count-ne1-or[string]$planning[0].repo_id-cne[string]$Plan.planning_owner.repo_id){throw 'Repository map must identify exactly the bound planning owner.'}
    $planningRoot=(Resolve-Path ([string]$planning[0].path)).Path
    $top=[IO.Path]::GetFullPath((Get-SourceOnlyGitValue $planningRoot @('rev-parse','--show-toplevel') 'planning owner root observation')).TrimEnd('\','/')
    $workspaceFull=[IO.Path]::GetFullPath($c.workspace).TrimEnd('\','/')
    if(-not($workspaceFull.Equals($top,[StringComparison]::OrdinalIgnoreCase)-or$workspaceFull.StartsWith($top+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){throw 'Workspace is not contained by the bound planning owner.'}
    $remotes=Invoke-SourceOnlyGit $planningRoot @('remote') 'planning remote observation'
    if(@($remotes.lines).Count-ne0){throw 'Source-only publication requires the bound planning owner to have no configured remotes.'}
    if(-not$AfterPrepare){Assert-SourceOnlyCleanGitRepository $planningRoot 'local-only planning owner'}
    foreach($check in @(
      @{n='planning branch';e=$Plan.planning_owner.branch;a=(Get-SourceOnlyGitValue $planningRoot @('branch','--show-current') 'planning branch observation')},
      @{n='planning head';e=$Plan.planning_owner.head;a=(Get-SourceOnlyGitValue $planningRoot @('rev-parse','HEAD') 'planning head observation')},
      @{n='planning tree';e=$Plan.planning_owner.tree;a=(Get-SourceOnlyGitValue $planningRoot @('rev-parse','HEAD^{tree}') 'planning tree observation')}
    )){if([string]$check.e-cne[string]$check.a){throw "Bound $($check.n) drifted."}}
    if(-not$AfterPrepare){
      foreach($check in @(
        @{n='project';e=$Plan.expected.project_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $c.project)},
        @{n='state';e=$Plan.expected.state_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $c.state)},
        @{n='unit';e=$Plan.expected.unit_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $c.unit)},
        @{n='events';e=$Plan.expected.events_sha256;a=(Get-MorphospaceFileSha256 $c.events_path)},
        @{n='event tail';e=$Plan.expected.event_tail_id;a=$c.tail.event_id}
      )){if([string]$check.e-cne[string]$check.a){throw "Source-only plan expected $($check.n) drifted."}}
      if([int64]$Plan.expected.events_length-ne([IO.FileInfo]$c.events_path).Length){throw 'Source-only plan expected event-ledger length drifted.'}
      if($null-ne$c.state.pending_push_bundle){throw 'Another publication bundle is already pending.'}
    }elseif(-not$Recovery){
      $preparedId="$([string]$Plan.publication_id)-source-publication-prepared";$preparedTransaction=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $c.workspace -TransactionId "$preparedId-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $c.unit_relative -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail
      if([string]$preparedTransaction.intent.event.event_id-cne[string]$c.tail.event_id-or[int]$preparedTransaction.intent.event.sequence-ne[int]$c.tail.sequence-or[string]$preparedTransaction.intent.pre.state.sha256-cne[string]$Plan.expected.state_sha256-or[string]$preparedTransaction.intent.pre.unit.sha256-cne[string]$Plan.expected.unit_sha256-or[string]$preparedTransaction.intent.expected.events_sha256-cne[string]$Plan.expected.events_sha256-or[int64]$preparedTransaction.intent.expected.events_length-ne[int64]$Plan.expected.events_length-or[string]$preparedTransaction.intent.expected.event_tail_id-cne[string]$Plan.expected.event_tail_id){throw 'Prepared source-only publication transaction does not authenticate the exact original preimage.'}
      $preparedArtifacts=@($preparedTransaction.intent.artifacts);if($preparedArtifacts.Count-ne1-or[string]$preparedArtifacts[0].path-cne"receipts/$([string]$Plan.publication_id)-plan.json"-or[string]$preparedArtifacts[0].sha256-cne(Get-MorphospaceFileSha256 $PlanPath)){throw 'Prepared source-only publication transaction does not own the immutable plan exactly.'}
       if((Get-MorphospaceCanonicalJsonSha256 $preparedTransaction.intent.target.state.document)-cne(Get-MorphospaceCanonicalJsonSha256 $c.state)-or[string]$preparedTransaction.intent.target.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $c.unit)-or(Get-MorphospaceCanonicalJsonSha256 $c.project)-cne[string]$Plan.expected.project_sha256-or[string]$c.state.pending_push_bundle.bundle_id-cne[string]$Plan.publication_id){throw 'Live planning state, unit, or project differs from the prepared source-only publication target.'}
       Assert-SourceOnlyPreparedPlanningWorktree $planningRoot $c.workspace ([string]$Plan.publication_id)
    }elseif((Get-MorphospaceCanonicalJsonSha256 $c.project)-cne[string]$Plan.expected.project_sha256){throw 'Source-only recovery project projection drifted.'}
    # A resolver map may also name external instruction/tool support. Project
    # membership owns source publication; extra map rows gain no authority.
    $projectSourceIds=@($c.project.repositories.repo_id)
    $sources=@($c.map.repositories|Where-Object{[string]$_.role-ceq'source'-and[string]$_.repo_id-cin$projectSourceIds});$planRows=@($Plan.source_repositories);$scopeRows=@($c.unit.allowed_repositories)
    $mapIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($repo in @($c.map.repositories)){if(-not$mapIds.Add([string]$repo.repo_id)){throw 'Repository map repeats a repository identity.'}}
    $planIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($row in $planRows){if(-not$planIds.Add([string]$row.repo_id)){throw 'Source-only publication plan repeats a source repository.'}}
    Assert-SourceOnlySetEqual @($scopeRows.repo_id) @($planRows.repo_id) 'Publication-plan writable source coverage'
    $published=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($row in $planRows){[void]$published.Add([string]$row.repo_id)}
    $readOnlyIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$readOnlyDependencies=if($c.unit.PSObject.Properties.Name-contains'read_only_dependencies'){@($c.unit.read_only_dependencies)}else{@()};foreach($dependency in $readOnlyDependencies){[void]$readOnlyIds.Add([string]$dependency.repo_id)}
    foreach($source in $sources){$id=[string]$source.repo_id;if(-not$published.Contains($id)-and-not$readOnlyIds.Contains($id)){throw "Mapped source repository '$id' is neither an exact publication owner nor an explicitly declared read-only dependency."}}
    $evidenceIds=@($Plan.validation_evidence.evidence_id);$evidenceSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($id in $evidenceIds){if(-not$evidenceSet.Add([string]$id)){throw 'Validation evidence identifiers must be unique.'}}
    foreach($ev in @($Plan.validation_evidence)){$ep=Resolve-MorphospaceWorkspacePath $c.workspace ([string]$ev.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $ep)-cne[string]$ev.sha256){throw "Validation evidence '$($ev.evidence_id)' drifted."}}
    $planningIdentity=@((Get-SourceOnlyPhysicalDirectoryIdentity $planningRoot 'Local-only planning owner'),(Get-SourceOnlyPhysicalDirectoryIdentity (Get-SourceOnlyGitCommonDirectory $planningRoot 'planning Git common-directory observation') 'Local-only planning Git authority'))
    $sourceAuthorities=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $sourceRemoteTargets=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    for($i=0;$i-lt$planRows.Count;$i++){
      $row=$planRows[$i];if([int]$row.dependency_ordinal-ne($i+1)){throw 'Source dependency ordinals must be contiguous and match array order.'}
      $matches=@($sources|Where-Object{[string]$_.repo_id-ceq[string]$row.repo_id});$scopes=@($scopeRows|Where-Object{[string]$_.repo_id-ceq[string]$row.repo_id});if($matches.Count-ne1-or$scopes.Count-ne1){throw "Source repository '$($row.repo_id)' is not uniquely declared."}
      foreach($ref in @($row.validation_refs)){if($ref-notin$evidenceIds){throw "Source repository '$($row.repo_id)' names undeclared validation evidence '$ref'."}}
      $path=(Resolve-Path ([string]$matches[0].path)).Path
      $sourceIdentity=@((Get-SourceOnlyPhysicalDirectoryIdentity $path "Source repository '$($row.repo_id)'"),(Get-SourceOnlyPhysicalDirectoryIdentity (Get-SourceOnlyGitCommonDirectory $path 'source Git common-directory observation') "Source repository '$($row.repo_id)' Git authority"))
      $rowIdentities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      foreach($identity in $sourceIdentity){
        if($planningIdentity-contains$identity){throw "Source repository '$($row.repo_id)' shares physical repository or Git authority with the local-only planning owner."}
        if($rowIdentities.Add($identity)){
          if($sourceAuthorities.ContainsKey($identity)){throw "Source repositories '$($sourceAuthorities[$identity])' and '$($row.repo_id)' share physical repository or Git authority."}
          $sourceAuthorities.Add($identity,[string]$row.repo_id)
        }
      }
      Assert-SourceOnlyCleanGitRepository $path "Source repository '$($row.repo_id)'"
       $branch=Get-SourceOnlyGitValue $path @('branch','--show-current') 'source branch observation';$upstream=Get-SourceOnlyGitValue $path @('rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}') 'source upstream observation';$remoteUrl=Get-SourceOnlyGitValue $path @('remote','get-url',[string]$row.remote) 'source remote URL observation'
      $targetBranch=[string]$row.target_branch;$remoteTargetKey="$($remoteUrl.Length):$remoteUrl|$($targetBranch.Length):$targetBranch"
      if($sourceRemoteTargets.ContainsKey($remoteTargetKey)){throw "Source repositories '$($sourceRemoteTargets[$remoteTargetKey])' and '$($row.repo_id)' share the same remote URL and target ref."}
      $sourceRemoteTargets.Add($remoteTargetKey,[string]$row.repo_id)
      $head=(Get-SourceOnlyGitValue $path @('rev-parse','HEAD') 'source head observation').ToLowerInvariant();$tree=(Get-SourceOnlyGitValue $path @('rev-parse','HEAD^{tree}') 'source tree observation').ToLowerInvariant()
       if($branch-cne[string]$row.candidate_branch-or$upstream-cne[string]$row.upstream-or$remoteUrl-cne[string]$row.remote_url-or$head-cne[string]$row.candidate_revision-or$tree-cne[string]$row.candidate_tree){throw "Source repository '$($row.repo_id)' candidate identity or remote target drifted."}
      if([string]$row.upstream-cne("$([string]$row.remote)/$([string]$row.target_branch)")){throw "Source repository '$($row.repo_id)' upstream does not bind its declared target branch."}
       foreach($rev in @('old_revision','candidate_revision')){[void](Invoke-SourceOnlyGit $path @('cat-file','-e',"$([string]$row.$rev)^{commit}") "source $rev observation")}
       $validated=@($acceptedValidation.repository_revisions|Where-Object{[string]$_.repo_id-ceq[string]$row.repo_id});if($validated.Count-ne1-or[string]$validated[0].head_revision-cne[string]$row.candidate_revision-or[string]$validated[0].branch-cne[string]$row.candidate_branch){throw "Source repository '$($row.repo_id)' candidate does not match the accepted validation snapshot."}
      [void](Invoke-SourceOnlyGit $path @('merge-base','--is-ancestor',[string]$row.old_revision,[string]$row.candidate_revision) 'source candidate ancestry observation')
      if([string]$row.old_revision-ceq[string]$row.candidate_revision-or[string]$row.rollback_revision-cne[string]$row.old_revision){throw "Source repository '$($row.repo_id)' has no publication delta or wrong rollback target."}
      if([string]$row.publication_mode-ceq'fast-forward'-and([string]$row.final_revision-cne[string]$row.candidate_revision-or[string]$row.final_tree-cne[string]$row.candidate_tree)){throw "Fast-forward source repository '$($row.repo_id)' must bind its candidate as final."}
      if([string]$row.publication_mode-ceq'provider-merge'-and($null-ne$row.final_revision-or[string]$row.final_tree-cne[string]$row.candidate_tree)){throw "Provider-merge source repository '$($row.repo_id)' must leave the future merge revision unset and bind its candidate tree."}
      $oldTree=(Get-SourceOnlyGitValue $path @('rev-parse',"$([string]$row.old_revision)^{tree}") 'old source tree observation').ToLowerInvariant();if($oldTree-cne[string]$row.old_tree){throw "Source repository '$($row.repo_id)' old tree drifted."}
      $changed=@((Invoke-SourceOnlyGit $path @('diff','--name-only','--no-renames',"$([string]$row.old_revision)..$([string]$row.candidate_revision)",'--') 'source path closure observation').lines|Where-Object{$_})
      Assert-SourceOnlySetEqual @($row.changed_paths) $changed "Source repository '$($row.repo_id)' changed paths"
      $declaredSnapshot=@($row.trigger_unit_paths)+@($row.carried_paths);Assert-SourceOnlySetEqual @($row.changed_paths) $declaredSnapshot "Source repository '$($row.repo_id)' reviewed snapshot coverage"
       $projectScope=@($c.project.repositories|Where-Object{[string]$_.repo_id-ceq[string]$row.repo_id});if($projectScope.Count-ne1){throw "Source repository '$($row.repo_id)' is not uniquely owned by the project."}
       foreach($changedPath in @($row.trigger_unit_paths)){if(-not(Test-SourceOnlyPathAllowed $changedPath @($scopes[0].allowed_paths))){throw "Trigger-unit source path '$($row.repo_id)/$changedPath' exceeds the trigger unit scope."}}
       $validatedPaths=@($acceptedValidation.changed_paths|Where-Object{[string]$_.repo_id-ceq[string]$row.repo_id}|ForEach-Object{[string]$_.path})
        Assert-SourceOnlySetEqual @($row.trigger_unit_paths) $validatedPaths "Source repository '$($row.repo_id)' accepted trigger-path coverage"
       foreach($carriedPath in @($row.carried_paths)){if(-not(Test-SourceOnlyPathAllowed $carriedPath @($projectScope[0].allowed_paths))){throw "Carried source path '$($row.repo_id)/$carriedPath' exceeds the exact project owner scope."}}
       if(-not$AfterPrepare){$upstreamOid=(Get-SourceOnlyGitValue $path @('rev-parse',[string]$row.upstream) 'pre-publication upstream observation').ToLowerInvariant();$remoteOld=Get-SourceOnlyRemoteReadback $path ([string]$row.remote_url) ([string]$row.target_branch);if($upstreamOid-cne[string]$row.old_revision-or$remoteOld-cne[string]$row.old_revision){throw "Source repository '$($row.repo_id)' target branch is not the declared old revision."}}
    }
}

function Get-SourceOnlyRecoveryIntent {
    param([object]$Context,[string]$TransactionId,[string]$ArtifactPath,[string]$CallerPath,[string]$ExpectedSha256,[string]$Action)
    if(-not$ExpectedSha256){throw "Source-only $Action recovery requires its reviewed SHA-256."}
    $callerHash=Get-MorphospaceFileSha256 $CallerPath
    if($callerHash-cne$ExpectedSha256){throw "Expected source-only $Action hash does not match input."}
    $intentPath=Resolve-MorphospaceWorkspacePath $Context.workspace "receipts/transactions/$TransactionId.intent.json" -RequireLeaf
    try{$intent=Read-MorphospaceProtocolJson $intentPath}catch{throw "Source-only $Action recovery intent is malformed."}
    if([string]$intent.transaction_id-cne$TransactionId-or[string]$intent.state.path-cne'workspace.state.json'-or[string]$intent.unit.path-cne$Context.unit_relative-or[string]$intent.events.path-cne'iteration-events.jsonl'){throw "Source-only $Action recovery intent endpoints differ from the live authority."}
    $artifacts=@($intent.artifacts);if($artifacts.Count-ne1-or[string]$artifacts[0].path-cne$ArtifactPath){throw "Source-only $Action recovery intent does not own the exact requested artifact."}
    try{$bytes=[Convert]::FromBase64String([string]$artifacts[0].bytes_base64)}catch{throw "Source-only $Action recovery artifact payload is malformed."}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if($hash-cne[string]$artifacts[0].sha256-or$hash-cne$callerHash-or([Convert]::ToBase64String([IO.File]::ReadAllBytes($CallerPath))-cne[Convert]::ToBase64String($bytes))){throw "Source-only $Action recovery caller bytes do not match the immutable transaction artifact."}
    return [pscustomobject]@{intent=$intent;artifact_sha256=$hash}
}

function Assert-SourceOnlyRecoveryCallerControls {
    param([object]$Context,[object]$Intent,[string]$ArtifactPath,[string]$OutPath,[string]$Timestamp,[string]$FaultAfter,[string]$Action)
    $ownedPath=Resolve-MorphospaceWorkspacePath $Context.workspace $ArtifactPath
    if($OutPath-and[IO.Path]::GetFullPath($OutPath)-cne$ownedPath){throw "Source-only $Action recovery output differs from the intent-owned artifact path."}
    if($Timestamp-and$Timestamp-cne[string]$Intent.event.timestamp){throw "Source-only $Action recovery timestamp differs from the durable intent."}
    if($FaultAfter-cne'none'){throw "Source-only $Action recovery does not accept a new fault-injection point."}
}

function Assert-SourceOnlyPreparationIntentSemantics {
    param([object]$Context,[object]$Plan,[object]$Intent)
    $publicationId=[string]$Plan.publication_id;$eventId="$publicationId-source-publication-prepared"
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v3'-or
       [string]$Intent.transaction_id-cne"$eventId-transition"-or
       [string]$Intent.pre.state.sha256-cne[string]$Plan.expected.state_sha256-or
       [string]$Intent.pre.unit.sha256-cne[string]$Plan.expected.unit_sha256-or
       [string]$Intent.expected.state_sha256-cne[string]$Plan.expected.state_sha256-or
       [string]$Intent.expected.unit_sha256-cne[string]$Plan.expected.unit_sha256-or
       [string]$Intent.expected.events_sha256-cne[string]$Plan.expected.events_sha256-or
       [int64]$Intent.expected.events_length-ne[int64]$Plan.expected.events_length-or
       [string]$Intent.expected.event_tail_id-cne[string]$Plan.expected.event_tail_id-or
       [string]$Intent.target.unit.sha256-cne[string]$Plan.expected.unit_sha256){
        throw 'Source-only preparation recovery intent does not bind the exact plan preimage and unchanged unit.'
    }
    $artifactPath="receipts/$publicationId-plan.json";$event=$Intent.event
    if([string]$event.event_id-cne$eventId-or[string]$event.project_id-cne[string]$Plan.project_id-or
       [string]$event.unit_id-cne[string]$Plan.trigger_unit_id-or[string]$event.event_type-cne'state-transition'-or
       [string]$event.summary-cne'Prepared exact source-only publication from an accepted trigger; planning remains local-only.'-or
       @($event.receipts).Count-ne1-or[string]$event.receipts[0]-cne$artifactPath){
        throw 'Source-only preparation recovery event differs from the exact source-only transition.'
    }
    $projections=@($Intent.additional_projections)
    if($projections.Count-ne1-or[string]$projections[0].path-cne'project.spec.json'-or
       [string]$projections[0].pre_sha256-cne[string]$Plan.expected.project_sha256-or
       [string]$projections[0].target_sha256-cne[string]$Plan.expected.project_sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $projections[0].document)-cne[string]$Plan.expected.project_sha256){
        throw 'Source-only preparation recovery intent changes or misbinds the project projection.'
    }
    $target=$Intent.target.state.document
    if([string]$Intent.target.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $target)-or
       [string]$target.last_event_id-cne$eventId-or$null-eq$target.pending_push_bundle-or
       [string]$target.pending_push_bundle.bundle_id-cne$publicationId-or-not[bool]$target.pending_push_bundle.ready){
        throw 'Source-only preparation recovery target pending bundle differs from the exact prepared projection.'
    }
    Assert-SourceOnlySetEqual @([string]$Plan.trigger_unit_id) @($target.pending_push_bundle.unit_ids) 'Source-only preparation recovery target unit coverage'
    if((@($target.pending_push_bundle.repo_ids)-join"`n")-cne(@($Plan.source_repositories.repo_id)-join"`n")){throw 'Source-only preparation recovery target repository order differs from the plan.'}
    $reconstructedPre=Copy-SourceOnlyDocument $target;$reconstructedPre.pending_push_bundle=$null;$reconstructedPre.last_event_id=[string]$Plan.expected.event_tail_id
    if((Get-MorphospaceCanonicalJsonSha256 $reconstructedPre)-cne[string]$Plan.expected.state_sha256){throw 'Source-only preparation recovery target state contains an unauthorized change.'}
}

function Assert-SourceOnlyRecordingIntentSemantics {
    param([object]$Context,[object]$Plan,[object]$Execution,[object]$Intent)
    $publicationId=[string]$Execution.publication_id;$preparedEventId="$publicationId-source-publication-prepared";$eventId="$publicationId-source-publication-recorded"
    $preparedTransaction=Test-SourceOnlyCommittedPredecessorTransition -Context $Context -TransactionId "$preparedEventId-transition" -PendingSuccessorIntent $Intent
    Assert-SourceOnlyPreparationIntentSemantics $Context $Plan $preparedTransaction.intent
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or
       [string]$Intent.transaction_id-cne"$eventId-transition"-or
       [string]$Intent.pre.state.sha256-cne[string]$preparedTransaction.intent.target.state.sha256-or
       [string]$Intent.pre.unit.sha256-cne[string]$preparedTransaction.intent.target.unit.sha256-or
       [string]$Intent.expected.state_sha256-cne[string]$preparedTransaction.intent.target.state.sha256-or
       [string]$Intent.expected.unit_sha256-cne[string]$preparedTransaction.intent.target.unit.sha256-or
       [string]$Intent.expected.event_tail_id-cne$preparedEventId-or
       [string]$Intent.target.unit.sha256-cne[string]$preparedTransaction.intent.target.unit.sha256){
        throw 'Source-only recording recovery intent does not bind the exact prepared transition and unchanged unit.'
    }
    $artifactPath="receipts/$publicationId-execution.json";$event=$Intent.event
    if([string]$event.event_id-cne$eventId-or[string]$event.project_id-cne[string]$Execution.project_id-or
       [string]$event.unit_id-cne[string]$Execution.trigger_unit_id-or[string]$event.event_type-cne'state-transition'-or
       [string]$event.summary-cne'Recorded ordered source publication and remote readback; planning remains local-only.'-or
       @($event.receipts).Count-ne1-or[string]$event.receipts[0]-cne$artifactPath){
        throw 'Source-only recording recovery event differs from the exact source-only transition.'
    }
    $target=$Intent.target.state.document
    if([string]$Intent.target.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $target)-or
       [string]$target.last_event_id-cne$eventId-or$null-ne$target.pending_push_bundle){
        throw 'Source-only recording recovery target pending bundle differs from the exact recorded projection.'
    }
    $reconstructedPre=Copy-SourceOnlyDocument $target
    $reconstructedPre.pending_push_bundle=Copy-SourceOnlyDocument $preparedTransaction.intent.target.state.document.pending_push_bundle
    $reconstructedPre.last_event_id=$preparedEventId
    if((Get-MorphospaceCanonicalJsonSha256 $reconstructedPre)-cne[string]$Intent.pre.state.sha256){throw 'Source-only recording recovery target state contains an unauthorized change.'}
    $preparedAt=[DateTimeOffset]::Parse([string]$preparedTransaction.intent.event.timestamp)
    $startedAt=[DateTimeOffset]::Parse([string]$Execution.started_at);$finishedAt=[DateTimeOffset]::Parse([string]$Execution.finished_at);$recordedAt=[DateTimeOffset]::Parse([string]$event.timestamp)
    if($preparedAt-gt$startedAt-or$finishedAt-gt$recordedAt){throw 'Source-only recording recovery chronology does not follow preparation and execution.'}
}

function Assert-SourceOnlyPreparationRemotePreimage {
    param([object]$Context,[object]$Plan)
    foreach($row in @($Plan.source_repositories)){
        $mapped=@($Context.map.repositories|Where-Object{[string]$_.repo_id-ceq[string]$row.repo_id})
        if($mapped.Count-ne1){throw "Source-only preparation recovery source '$($row.repo_id)' map binding drifted."}
        $sourcePath=(Resolve-Path ([string]$mapped[0].path)).Path
        $remote=Get-SourceOnlyRemoteReadback $sourcePath ([string]$row.remote_url) ([string]$row.target_branch)
        if($remote-cne[string]$row.old_revision){throw "Source-only preparation recovery remote preimage differs for '$($row.repo_id)'."}
    }
}

function Assert-SourceOnlyRecoveryPlanningWorktree {
    param([object]$Context,[object]$Plan,[ValidateSet('preparation','recording')][string]$Phase)
    $planning=@($Context.map.repositories|Where-Object{[string]$_.role-ceq'planning'-and[string]$_.repo_id-ceq[string]$Plan.planning_owner.repo_id})
    if($planning.Count-ne1){throw 'Source-only recovery planning-owner map binding drifted.'}
    $planningRoot=(Resolve-Path ([string]$planning[0].path)).Path
    Assert-SourceOnlyPreparedPlanningWorktree $planningRoot $Context.workspace ([string]$Plan.publication_id) -Phase $Phase
}

function Assert-SourceOnlyRecoveryResult {
    param([object]$Context,[string]$TransactionId,[string]$ArtifactPath,[string]$Action)
    [void](Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Context.workspace -TransactionId $TransactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $Context.unit_relative -ExpectedEventsPath 'iteration-events.jsonl')
    $path=Resolve-MorphospaceWorkspacePath $Context.workspace $ArtifactPath -RequireLeaf
    return Get-MorphospaceFileSha256 $path
}

function Assert-SourceOnlyRecoveryExecution {
    param([object]$Context,[object]$Plan,[object]$Execution)
    $rows=@($Execution.source_repositories);$planned=@($Plan.source_repositories)
    if($rows.Count-ne$planned.Count){throw 'Source-only recording recovery execution source coverage differs from its plan.'}
    $priorReadback=$null
    for($i=0;$i-lt$rows.Count;$i++){
        $row=$rows[$i];$bound=$planned[$i]
        foreach($name in @('dependency_ordinal','repo_id','publication_mode','old_revision','candidate_revision')){if([string]$row.$name-cne[string]$bound.$name){throw "Source-only recording recovery execution differs at ordinal $($i+1)."}}
        $mapped=@($Context.map.repositories|Where-Object{[string]$_.repo_id-ceq[string]$bound.repo_id});if($mapped.Count-ne1){throw "Source-only recording recovery source '$($bound.repo_id)' map binding drifted."}
        $sourcePath=(Resolve-Path ([string]$mapped[0].path)).Path;$remote=Get-SourceOnlyRemoteReadback $sourcePath ([string]$bound.remote_url) ([string]$bound.target_branch)
        if([string]$row.remote_readback_revision-cne[string]$row.final_revision-or$remote-cne[string]$row.final_revision){throw "Source-only recording recovery remote readback differs for '$($bound.repo_id)'."}
        $started=[DateTimeOffset]::Parse([string]$row.operation_started_at);$readback=[DateTimeOffset]::Parse([string]$row.remote_readback_at)
        if($started-lt[DateTimeOffset]::Parse([string]$Execution.started_at)-or$readback-lt$started-or$readback-gt[DateTimeOffset]::Parse([string]$Execution.finished_at)-or($null-ne$priorReadback-and$started-lt$priorReadback)){throw "Source-only recording recovery operation chronology is invalid for '$($bound.repo_id)'."};$priorReadback=$readback
        if([string]$bound.publication_mode-ceq'fast-forward'){if([string]$row.final_revision-cne[string]$bound.candidate_revision){throw "Source-only recording recovery fast-forward final revision differs for '$($bound.repo_id)'."}}
        else{$parentResult=Invoke-SourceOnlyGit $sourcePath @('rev-list','--parents','-n','1',[string]$row.final_revision) 'provider merge recovery parent readback';$parents=@((@($parentResult.lines)[0].Split(' ',[StringSplitOptions]::RemoveEmptyEntries)));if($parents.Count-ne3-or$parents[1]-cne[string]$bound.old_revision-or$parents[2]-cne[string]$bound.candidate_revision){throw "Source-only recording recovery provider merge parents differ for '$($bound.repo_id)'."};$tree=(Get-SourceOnlyGitValue $sourcePath @('rev-parse',"$([string]$row.final_revision)^{tree}") 'provider merge recovery tree readback').ToLowerInvariant();if($tree-cne[string]$bound.candidate_tree){throw "Source-only recording recovery provider merge tree differs for '$($bound.repo_id)'."}}
    }
    $reverse=@([string[]]@($planned|ForEach-Object{[string]$_.repo_id}));[array]::Reverse($reverse)
    if((@([string[]]$Execution.rollback.reverse_dependency_order)-join"`n")-cne($reverse-join"`n")){throw 'Source-only recording recovery rollback order is not the reverse dependency order.'}
    if([DateTimeOffset]::Parse([string]$Execution.finished_at)-lt[DateTimeOffset]::Parse([string]$Execution.started_at)){throw 'Source-only recording recovery finish precedes its start.'}
}

function Invoke-MorphospacePrepareSourceOnlyPublication {
 [CmdletBinding()]param([string]$WorkspaceRoot,[string]$UnitId,[string]$RepoMapPath,[string]$SourceOnlyPublicationPlan,[string]$ExpectedSourceOnlyPublicationPlanSha256='',[string]$Timestamp='',[string]$OutPath,[switch]$Execute,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none')
 $c=Get-SourceOnlyContext $WorkspaceRoot $UnitId $RepoMapPath -AllowPartialLedger;$input=(Resolve-Path $SourceOnlyPublicationPlan).Path;$plan=Read-MorphospaceProtocolJson $input;$eventId="$([string]$plan.publication_id)-source-publication-prepared";$transactionId="$eventId-transition";$intentPath=Resolve-MorphospaceWorkspacePath $c.workspace "receipts/transactions/$transactionId.intent.json";$completionPath=Resolve-MorphospaceWorkspacePath $c.workspace "receipts/transactions/$transactionId.completion.json"
 if([IO.File]::Exists($intentPath)){
   $artifactPath="receipts/$([string]$plan.publication_id)-plan.json";$recovery=Get-SourceOnlyRecoveryIntent $c $transactionId $artifactPath $input $ExpectedSourceOnlyPublicationPlanSha256 'preparation';Assert-SourceOnlyRecoveryCallerControls $c $recovery.intent $artifactPath $OutPath $Timestamp $FaultAfter 'preparation'
   if(-not$Execute-and-not[IO.File]::Exists($completionPath)){throw 'Source-only preparation is interrupted and requires -Execute recovery.'}
   Assert-SourceOnlyPreparationIntentSemantics $c $plan $recovery.intent;Assert-SourceOnlyPlan $c $plan $input -AfterPrepare -Recovery -PendingSuccessorIntent $recovery.intent
   if(-not[IO.File]::Exists($completionPath)){Assert-SourceOnlyPreparationRemotePreimage $c $plan;Assert-SourceOnlyRecoveryPlanningWorktree $c $plan 'preparation'}
   if($Execute-and-not[IO.File]::Exists($completionPath)){[void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $c.workspace -TransactionId $transactionId -Repair)}
   $c=Get-SourceOnlyContext $WorkspaceRoot $UnitId $RepoMapPath;$ownedHash=Assert-SourceOnlyRecoveryResult $c $transactionId "receipts/$([string]$plan.publication_id)-plan.json" 'preparation';Assert-SourceOnlyPlan $c $plan (Resolve-MorphospaceWorkspacePath $c.workspace "receipts/$([string]$plan.publication_id)-plan.json") -AfterPrepare
   return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.source_only_publication_automation_receipt.v1';action='PrepareSourceOnlyPublication';publication_id=$plan.publication_id;project_id=$plan.project_id;trigger_unit_id=$UnitId;executed=$Execute.IsPresent;plan=[ordered]@{path="receipts/$([string]$plan.publication_id)-plan.json";sha256=$ownedHash};event_id=$eventId;preservation=$plan.preservation}
  }
  if([string]$c.state.last_event_id-cne[string]$c.tail.event_id){throw 'Workspace state does not match the event-ledger tail.'}
  Assert-SourceOnlyPlan $c $plan $input
 $hash=Get-MorphospaceFileSha256 $input;if($ExpectedSourceOnlyPublicationPlanSha256-and$hash-cne$ExpectedSourceOnlyPublicationPlanSha256){throw 'Expected source-only publication plan hash does not match input.'};if($Execute-and-not$ExpectedSourceOnlyPublicationPlanSha256){throw 'Executed preparation requires its dry-run plan SHA-256.'}
 if(-not$OutPath){throw 'Source-only preparation requires an output path.'};$relative="receipts/$([string]$plan.publication_id)-plan.json";$full=Resolve-MorphospaceWorkspacePath $c.workspace $relative;if([IO.Path]::GetFullPath($OutPath)-cne$full){throw "Preparation output must be '$relative'."};if(Test-Path -LiteralPath $full){throw 'Source-only publication plan has already been prepared.'}
 if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};if($Timestamp-cnotmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$'){throw 'Timestamp is invalid.'};try{[void][DateTimeOffset]::Parse($Timestamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)}catch{throw 'Timestamp is invalid.'}
 $targetState=Copy-SourceOnlyDocument $c.state;$targetState.pending_push_bundle=[pscustomobject][ordered]@{bundle_id=[string]$plan.publication_id;unit_ids=@($UnitId);repo_ids=@($plan.source_repositories.repo_id);ready=$true};$targetState.last_event_id=$eventId
 $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$c.tail.sequence+1;timestamp=$Timestamp;project_id=$plan.project_id;unit_id=$UnitId;event_type='state-transition';summary='Prepared exact source-only publication from an accepted trigger; planning remains local-only.';receipts=@($relative)}
  if($Execute){Start-MorphospaceTransitionLedger -WorkspaceRoot $c.workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $c.unit_relative -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $c.unit -Event $event -ExpectedStateSha256 $plan.expected.state_sha256 -ExpectedUnitSha256 $plan.expected.unit_sha256 -ExpectedEventTailId $plan.expected.event_tail_id -ExpectedEventsSha256 $plan.expected.events_sha256 -ExpectedEventsLength $plan.expected.events_length -AdditionalProjections @([pscustomobject]@{path='project.spec.json';expected_sha256=$plan.expected.project_sha256;document=$c.project}) -Artifacts @([pscustomobject]@{source_path=$input;path=$relative;sha256=$hash}) -FaultAfter $FaultAfter|Out-Null}
 return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.source_only_publication_automation_receipt.v1';action='PrepareSourceOnlyPublication';publication_id=$plan.publication_id;project_id=$plan.project_id;trigger_unit_id=$UnitId;executed=$Execute.IsPresent;plan=[ordered]@{path=$relative;sha256=$hash};event_id=$(if($Execute){$eventId}else{$null});preservation=$plan.preservation}
}

function Invoke-MorphospaceRecordSourceOnlyPublication {
 [CmdletBinding()]param([string]$WorkspaceRoot,[string]$UnitId,[string]$RepoMapPath,[string]$SourceOnlyPublicationExecution,[string]$ExpectedSourceOnlyPublicationExecutionSha256='',[string]$Timestamp='',[string]$OutPath,[switch]$Execute,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none')
   $c=Get-SourceOnlyContext $WorkspaceRoot $UnitId $RepoMapPath -AllowPartialLedger;$input=(Resolve-Path $SourceOnlyPublicationExecution).Path;$repoRoot=$c.repo_root;$raw=Get-Content -Raw $input;if(-not(Test-Json -Json $raw -SchemaFile (Join-Path $repoRoot 'schemas\source-only-publication-execution-v1.schema.json'))){throw 'Source-only publication execution does not satisfy its schema.'};$execution=Read-MorphospaceProtocolJson $input;$eventId="$([string]$execution.publication_id)-source-publication-recorded";$transactionId="$eventId-transition";$intentPath=Resolve-MorphospaceWorkspacePath $c.workspace "receipts/transactions/$transactionId.intent.json";$completionPath=Resolve-MorphospaceWorkspacePath $c.workspace "receipts/transactions/$transactionId.completion.json"
   if([IO.File]::Exists($intentPath)){
      $artifactPath="receipts/$([string]$execution.publication_id)-execution.json";$recovery=Get-SourceOnlyRecoveryIntent $c $transactionId $artifactPath $input $ExpectedSourceOnlyPublicationExecutionSha256 'recording';Assert-SourceOnlyRecoveryCallerControls $c $recovery.intent $artifactPath $OutPath $Timestamp $FaultAfter 'recording'
     if(-not$Execute-and-not[IO.File]::Exists($completionPath)){throw 'Source-only recording is interrupted and requires -Execute recovery.'}
     $recoveryPlanPath=Resolve-MorphospaceWorkspacePath $c.workspace ([string]$execution.plan.path) -RequireLeaf
     if([string]$execution.plan.path-cne"receipts/$([string]$execution.publication_id)-plan.json"-or(Get-MorphospaceFileSha256 $recoveryPlanPath)-cne[string]$execution.plan.sha256){throw 'Source-only recording recovery prepared-plan binding drifted.'}
     $recoveryPlan=Read-MorphospaceProtocolJson $recoveryPlanPath
     if([string]$recoveryPlan.publication_id-cne[string]$execution.publication_id-or[string]$recoveryPlan.project_id-cne[string]$execution.project_id-or[string]$execution.trigger_unit_id-cne$UnitId){throw 'Source-only recording recovery plan identity drifted.'}
      Assert-SourceOnlyPlan $c $recoveryPlan $recoveryPlanPath -AfterPrepare -Recovery
      Assert-SourceOnlyRecoveryExecution $c $recoveryPlan $execution
      Assert-SourceOnlyRecordingIntentSemantics $c $recoveryPlan $execution $recovery.intent
     if(-not[IO.File]::Exists($completionPath)){Assert-SourceOnlyRecoveryPlanningWorktree $c $recoveryPlan 'recording'}
     if($Execute-and-not[IO.File]::Exists($completionPath)){[void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $c.workspace -TransactionId $transactionId -Repair)}
     $c=Get-SourceOnlyContext $WorkspaceRoot $UnitId $RepoMapPath;$ownedHash=Assert-SourceOnlyRecoveryResult $c $transactionId "receipts/$([string]$execution.publication_id)-execution.json" 'recording'
     return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.source_only_publication_automation_receipt.v1';action='RecordSourceOnlyPublication';publication_id=$execution.publication_id;project_id=$execution.project_id;trigger_unit_id=$UnitId;executed=$Execute.IsPresent;plan=$execution.plan;execution=[ordered]@{path="receipts/$([string]$execution.publication_id)-execution.json";sha256=$ownedHash};event_id=$eventId;preservation=$execution.preservation}
   }
  if([string]$c.state.last_event_id-cne[string]$c.tail.event_id){throw 'Workspace state does not match the event-ledger tail.'}
  $planPath=Resolve-MorphospaceWorkspacePath $c.workspace ([string]$execution.plan.path) -RequireLeaf;if([string]$execution.plan.path-cne"receipts/$([string]$execution.publication_id)-plan.json"){throw 'Execution does not name the canonical prepared source-only plan path.'};if((Get-MorphospaceFileSha256 $planPath)-cne[string]$execution.plan.sha256){throw 'Prepared source-only publication plan binding drifted.'};$plan=Read-MorphospaceProtocolJson $planPath
 if([string]$execution.publication_id-cne[string]$plan.publication_id-or[string]$execution.project_id-cne[string]$plan.project_id-or[string]$execution.trigger_unit_id-cne$UnitId){throw 'Execution identity does not match its prepared plan.'}
 Assert-SourceOnlyPlan $c $plan $planPath -AfterPrepare
 if($null-eq$c.state.pending_push_bundle-or[string]$c.state.pending_push_bundle.bundle_id-cne[string]$plan.publication_id-or-not[bool]$c.state.pending_push_bundle.ready){throw 'Exact prepared source-only publication bundle is not pending.'}
 Assert-SourceOnlySetEqual @($plan.source_repositories.repo_id) @($c.state.pending_push_bundle.repo_ids) 'Pending source repository coverage';Assert-SourceOnlySetEqual @($UnitId) @($c.state.pending_push_bundle.unit_ids) 'Pending trigger-unit coverage'
  if([string]$c.state.last_event_id-cne"$([string]$plan.publication_id)-source-publication-prepared"){throw 'Prepared source-only publication is not the current planning transition.'}
  $preparedTransition=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $c.workspace -TransactionId "$([string]$plan.publication_id)-source-publication-prepared-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $c.unit_relative -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail
 $rows=@($execution.source_repositories);if($rows.Count-ne@($plan.source_repositories).Count){throw 'Execution source repository count differs from its plan.'}
 for($i=0;$i-lt$rows.Count;$i++){
   $x=$rows[$i];$p=@($plan.source_repositories)[$i]
   foreach($name in @('dependency_ordinal','repo_id','publication_mode','old_revision','candidate_revision')){if([string]$x.$name-cne[string]$p.$name){throw "Execution source order or revision differs at ordinal $($i+1)."}}
    if([string]$x.remote_readback_revision-cne[string]$x.final_revision){throw "Execution readback differs for '$($p.repo_id)'."}
   $mapped=@($c.map.repositories|Where-Object{[string]$_.repo_id-ceq[string]$p.repo_id});$sourcePath=(Resolve-Path ([string]$mapped[0].path)).Path
    $remoteActual=Get-SourceOnlyRemoteReadback $sourcePath ([string]$p.remote_url) ([string]$p.target_branch);if($remoteActual-cne[string]$x.final_revision){throw "Live remote readback differs for '$($p.repo_id)'."}
    $operationStarted=[DateTimeOffset]::Parse([string]$x.operation_started_at);$readbackAt=[DateTimeOffset]::Parse([string]$x.remote_readback_at);if($operationStarted-lt[DateTimeOffset]::Parse([string]$execution.started_at)-or$readbackAt-lt$operationStarted-or$readbackAt-gt[DateTimeOffset]::Parse([string]$execution.finished_at)){throw "Execution operation chronology is invalid for '$($p.repo_id)'."}
    if($i-gt0-and$operationStarted-lt[DateTimeOffset]::Parse([string]$rows[$i-1].remote_readback_at)){throw "Execution source operations are not ordered by dependency ordinal."}
   if([string]$p.publication_mode-ceq'fast-forward'){
      if([string]$x.final_revision-cne[string]$p.candidate_revision){throw "Fast-forward execution final revision differs for '$($p.repo_id)'."}
   }else{
       $parentResult=Invoke-SourceOnlyGit $sourcePath @('rev-list','--parents','-n','1',[string]$x.final_revision) 'provider merge parent readback';$parents=@((@($parentResult.lines)[0].Split(' ',[StringSplitOptions]::RemoveEmptyEntries)))
      if($parents.Count-ne3-or$parents[0]-cne[string]$x.final_revision-or$parents[1]-cne[string]$p.old_revision-or$parents[2]-cne[string]$p.candidate_revision){throw "Provider merge '$($p.repo_id)' does not have the exact ordered base and candidate parents."}
      $mergeTree=(Get-SourceOnlyGitValue $sourcePath @('rev-parse',"$([string]$x.final_revision)^{tree}") 'provider merge tree readback').ToLowerInvariant();if($mergeTree-cne[string]$p.candidate_tree){throw "Provider merge '$($p.repo_id)' tree differs from its bound candidate tree."}
   }
 }
 $reverse=@([string[]]@($plan.source_repositories|ForEach-Object{[string]$_.repo_id}));[array]::Reverse($reverse);if((@([string[]]$execution.rollback.reverse_dependency_order)-join"`n")-cne($reverse-join"`n")){throw 'Execution rollback order is not the reverse dependency order.'}
 if([DateTimeOffset]::Parse([string]$execution.finished_at)-lt[DateTimeOffset]::Parse([string]$execution.started_at)){throw 'Execution finish precedes its start.'}
 $hash=Get-MorphospaceFileSha256 $input;if($ExpectedSourceOnlyPublicationExecutionSha256-and$hash-cne$ExpectedSourceOnlyPublicationExecutionSha256){throw 'Expected source-only execution hash does not match input.'};if($Execute-and-not$ExpectedSourceOnlyPublicationExecutionSha256){throw 'Executed recording requires its dry-run execution SHA-256.'}
 if(-not$OutPath){throw 'Source-only recording requires an output path.'};$relative="receipts/$([string]$plan.publication_id)-execution.json";$full=Resolve-MorphospaceWorkspacePath $c.workspace $relative;if([IO.Path]::GetFullPath($OutPath)-cne$full){throw "Record output must be '$relative'."};if(Test-Path -LiteralPath $full){throw 'Source-only publication execution has already been recorded.'}
  if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};if($Timestamp-cnotmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$'){throw 'Timestamp is invalid.'};try{$recordedAt=[DateTimeOffset]::Parse($Timestamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)}catch{throw 'Timestamp is invalid.'};if([DateTimeOffset]::Parse([string]$preparedTransition.intent.event.timestamp)-gt[DateTimeOffset]::Parse([string]$execution.started_at)-or[DateTimeOffset]::Parse([string]$execution.finished_at)-gt$recordedAt){throw 'Source-only recording chronology does not follow preparation and execution.'};$targetState=Copy-SourceOnlyDocument $c.state;$targetState.pending_push_bundle=$null;$targetState.last_event_id=$eventId
 $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$c.tail.sequence+1;timestamp=$Timestamp;project_id=$plan.project_id;unit_id=$UnitId;event_type='state-transition';summary='Recorded ordered source publication and remote readback; planning remains local-only.';receipts=@($relative)}
 $stateHash=Get-MorphospaceCanonicalJsonSha256 $c.state;$unitHash=Get-MorphospaceCanonicalJsonSha256 $c.unit;$eventsHash=Get-MorphospaceFileSha256 $c.events_path;$eventsLength=([IO.FileInfo]$c.events_path).Length
  if($Execute){Start-MorphospaceTransitionLedger -WorkspaceRoot $c.workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $c.unit_relative -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $c.unit -Event $event -ExpectedStateSha256 $stateHash -ExpectedUnitSha256 $unitHash -ExpectedEventTailId $c.tail.event_id -ExpectedEventsSha256 $eventsHash -ExpectedEventsLength $eventsLength -Artifacts @([pscustomobject]@{source_path=$input;path=$relative;sha256=$hash}) -FaultAfter $FaultAfter|Out-Null}
 return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.source_only_publication_automation_receipt.v1';action='RecordSourceOnlyPublication';publication_id=$plan.publication_id;project_id=$plan.project_id;trigger_unit_id=$UnitId;executed=$Execute.IsPresent;plan=$execution.plan;execution=[ordered]@{path=$relative;sha256=$hash};event_id=$(if($Execute){$eventId}else{$null});preservation=$execution.preservation}
}

Export-ModuleMember -Function Invoke-MorphospacePrepareSourceOnlyPublication,Invoke-MorphospaceRecordSourceOnlyPublication
