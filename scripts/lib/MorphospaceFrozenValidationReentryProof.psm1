Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:ReentryProtocolModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -PassThru
$script:ReentryLedgerModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1') -PassThru
$script:ReentryToolingModule=Import-Module (Join-Path $PSScriptRoot '../ToolingContextProvenance.psm1') -PassThru
$script:ReentryValidationModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceValidationReceipt.psm1') -PassThru
$script:ReentryGit=(@(Get-Command git -CommandType Application -ErrorAction Stop)[0]).Source
$script:ReentryClosureCache=@{}
$script:ReentryDerivedViews=[Collections.Generic.HashSet[string]]::new($(if([OperatingSystem]::IsWindows()){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}))

function Get-ReentrySchema { param([string]$Name) Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "schemas/$Name" }

function Assert-ReentrySchema {
    param([object]$Document,[string]$Name,[string]$SchemaId)
    if([string]$Document.schema-cne$SchemaId-or-not(Test-Json -Json ($Document|ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Get-ReentrySchema $Name) -ErrorAction SilentlyContinue)){throw "Frozen re-entry $SchemaId schema is invalid."}
}

function Assert-ReentryEqual {
    param([object]$Expected,[object]$Actual,[string]$Name)
    if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$Expected}))-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$Actual}))){throw "Frozen re-entry $Name is detached."}
}

function Copy-ReentryValue { param([object]$Value) ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $Value) }

function Read-ReentryBinding {
    param([string]$Root,[object]$Binding)
    $path=Resolve-MorphospaceWorkspacePath $Root ([string]$Binding.path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $path)-cne[string]$Binding.sha256){throw "Frozen re-entry bound bytes drifted: $($Binding.path)"}
    Read-MorphospaceProtocolJson $path
}

function Invoke-ReentryGit {
    param([string]$Root,[string[]]$Arguments)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$script:ReentryGit;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @('-C',$Root)+$Arguments){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        if(-not$process.Start()){throw 'Frozen re-entry Git observation failed to start.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not$process.WaitForExit(60000)){$process.Kill($true);$process.WaitForExit();throw 'Frozen re-entry owned Git observation exceeded its finite 60-second bound.'}
        $result=$stdout.GetAwaiter().GetResult();[void]$stderr.GetAwaiter().GetResult()
        if($process.ExitCode-ne0){throw 'Frozen re-entry Git observation failed.'}
        @($result.Split("`n")|ForEach-Object{$_.TrimEnd("`r")}|Where-Object{$_-cne''})
    }finally{$process.Dispose()}
}

function Get-ReentryGitScalar {
    param([string]$Root,[string[]]$Arguments)
    $lines=@(Invoke-ReentryGit $Root $Arguments);if($lines.Count-ne1-or[string]::IsNullOrWhiteSpace($lines[0])){throw 'Frozen re-entry Git scalar observation is ambiguous.'};[string]$lines[0]
}

function Get-ReentryBlobMap {
    param([string]$Root,[string[]]$Oids)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$script:ReentryGit;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
    foreach($argument in @('-C',$Root,'cat-file','--batch')){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$buffer=[IO.MemoryStream]::new()
    try{
        if(-not$process.Start()){throw 'Frozen re-entry blob reader failed to start.'}
        $stderr=$process.StandardError.ReadToEndAsync();$copy=$process.StandardOutput.BaseStream.CopyToAsync($buffer)
        $write=$process.StandardInput.WriteAsync(($Oids-join"`n")+"`n");[void]$write.GetAwaiter().GetResult();$process.StandardInput.Close()
        if(-not$process.WaitForExit(60000)){$process.Kill($true);$process.WaitForExit();throw 'Frozen re-entry owned blob reader exceeded its finite bound.'}
        [void]$copy.GetAwaiter().GetResult();[void]$stderr.GetAwaiter().GetResult();if($process.ExitCode-ne0){throw 'Frozen re-entry pinned Git blobs are unavailable.'}
        $bytes=$buffer.ToArray();$position=0;$result=@{}
        foreach($oid in $Oids){
            $startAt=$position;while($position-lt$bytes.Length-and$bytes[$position]-ne10){$position++}
            if($position-eq$bytes.Length){throw 'Frozen re-entry batch blob header is truncated.'}
            $header=[Text.Encoding]::ASCII.GetString($bytes,$startAt,$position-$startAt);$position++
            if($header-cnotmatch'^(?<oid>[0-9a-f]{40}) blob (?<length>[0-9]+)$'-or[string]$Matches.oid-cne$oid){throw 'Frozen re-entry batch blob identity is detached.'}
            $length=[int64]$Matches.length;if($length-gt[int]::MaxValue-or$length-gt($bytes.LongLength-$position-1)){throw 'Frozen re-entry batch blob payload is truncated.'}
            $blob=[byte[]]::new([int]$length);[Array]::Copy($bytes,$position,$blob,0,$length);$position+=[int]$length
            if($bytes[$position++]-ne10){throw 'Frozen re-entry batch blob separator is invalid.'};$result[$oid]=$blob
        }
        if($position-ne$bytes.Length){throw 'Frozen re-entry batch blob reader returned an undeclared suffix.'};return $result
    }finally{$buffer.Dispose();$process.Dispose()}
}

function Get-ReentryRequiredExecutorPaths {
    param([object]$SchemaDocument)
    $clauses=@($SchemaDocument.'$defs'.request.properties.executor.properties.closure.allOf)
    if($clauses.Count-ne2){throw 'Frozen re-entry required executor path contract is invalid.'}
    $required=[Collections.Generic.List[string]]::new();$unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($clause in $clauses){
        if((@($clause.PSObject.Properties.Name)-join',')-cne'contains'-or(@($clause.contains.PSObject.Properties.Name|Sort-Object)-join',')-cne'properties,required'-or(@($clause.contains.properties.PSObject.Properties.Name)-join',')-cne'path'-or(@($clause.contains.properties.path.PSObject.Properties.Name)-join',')-cne'const'-or@($clause.contains.required).Count-ne1-or[string]$clause.contains.required[0]-cne'path'-or$clause.contains.properties.path.const-isnot[string]){throw 'Frozen re-entry required executor path contract is invalid.'}
        $raw=[string]$clause.contains.properties.path.const;$path=ConvertTo-MorphospaceProtocolRelativePath $raw
        if($path-cne$raw-or-not$unique.Add($path)){throw 'Frozen re-entry required executor path contract is invalid.'}
        $required.Add($path)
    }
    return $required.ToArray()
}
function Assert-ReentryExecutorClosure {
    param([string]$Root,[object]$Executor,[switch]$Executing,[Management.Automation.PSModuleInfo[]]$AdditionalOwnerModules=@())
    if((Get-ReentryGitScalar $Root @('rev-parse',"$([string]$Executor.commit)^{tree}"))-cne[string]$Executor.tree){throw 'Frozen re-entry executor tree is detached.'}
    $declared=@{};foreach($row in @($Executor.closure)){$path=ConvertTo-MorphospaceProtocolRelativePath ([string]$row.path);if($declared.ContainsKey($path)){throw 'Frozen re-entry executor closure repeats a path.'};$declared[$path]=[string]$row.sha256}
    $cacheKey="$Root|$([string]$Executor.commit)|$([string]$Executor.tree)|$(Get-MorphospaceCanonicalJsonSha256 @($Executor.closure))"
    $cached=$script:ReentryClosureCache.ContainsKey($cacheKey)
    $rows=@(Invoke-ReentryGit $Root @('ls-tree','-r','--full-tree',[string]$Executor.commit));$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $oids=@($rows|ForEach-Object{if($_-cnotmatch'^(100644|100755) blob (?<oid>[0-9a-f]{40})\t.+$'){throw 'Frozen re-entry executor tree contains an unsupported entry.'};[string]$Matches.oid})
    $blobs=if(-not$cached){Get-ReentryBlobMap $Root $oids}else{@{}}
    foreach($line in $rows){
        if($line-cnotmatch'^(?<mode>100644|100755) blob (?<oid>[0-9a-f]{40})\t(?<path>.+)$'){throw 'Frozen re-entry executor tree contains an unsupported entry.'}
        $oid=[string]$Matches.oid;$path=[string]$Matches.path
        if(-not$seen.Add($path)-or-not$declared.ContainsKey($path)){throw 'Frozen re-entry executor closure is not the complete exact Git tree.'}
        if(-not$cached){if((Get-MorphospaceSha256Bytes ([byte[]]$blobs[$oid]))-cne$declared[$path]){throw "Frozen re-entry executor Git blob drifted: $path"}}
        if($Executing){$disk=Resolve-MorphospaceWorkspacePath $Root $path -RequireLeaf;if((Get-MorphospaceFileSha256 $disk)-cne$declared[$path]){throw "Frozen re-entry executing bytes differ from the pinned blob: $path"}}
    }
    if($seen.Count-ne$declared.Count){throw 'Frozen re-entry executor inventory or entrypoint is incomplete.'}
    $requiredPaths=@(Get-ReentryRequiredExecutorPaths (Read-MorphospaceProtocolJson (Get-ReentrySchema 'frozen-validation-reentry-v1.schema.json')))
    foreach($requiredPath in $requiredPaths){if(-not$seen.Contains($requiredPath)){throw 'Frozen re-entry executor inventory or entrypoint is incomplete.'}}
    $script:ReentryClosureCache[$cacheKey]=$true
    if($Executing){
        if((Get-ReentryGitScalar $Root @('rev-parse','HEAD'))-cne[string]$Executor.commit-or@(Invoke-ReentryGit $Root @('status','--porcelain=v1','--untracked-files=all')).Count-ne0){throw 'Frozen re-entry executor must be the exact clean published candidate.'}
        $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal};$prefix=$Root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        $pending=[Collections.Generic.Queue[Management.Automation.PSModuleInfo]]::new();foreach($module in @($script:ReentryProtocolModule,$script:ReentryLedgerModule,$script:ReentryToolingModule,$script:ReentryValidationModule,$MyInvocation.MyCommand.Module)+@($AdditionalOwnerModules)){$pending.Enqueue($module)}
        foreach($frame in @(Get-PSCallStack)){if($null-ne$frame.InvocationInfo-and$null-ne$frame.InvocationInfo.MyCommand-and$null-ne$frame.InvocationInfo.MyCommand.Module){$callerModule=$frame.InvocationInfo.MyCommand.Module;if(-not[string]::IsNullOrEmpty([string]$callerModule.Path)-and[IO.Path]::GetFullPath([string]$callerModule.Path).StartsWith($prefix,$comparison)){$pending.Enqueue($callerModule)}}}
        $modulesSeen=[Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
        while($pending.Count){$module=$pending.Dequeue();if(-not$modulesSeen.Add($module)){continue}
            if(-not[IO.Path]::GetFullPath([string]$module.Path).StartsWith($prefix,$comparison)){throw 'Frozen re-entry loaded owner module is outside the exact executor.'}
            $relative=[IO.Path]::GetRelativePath($Root,[string]$module.Path).Replace('\','/')
            if(-not$declared.ContainsKey($relative)-or-not[string]::Equals([string]$module.Definition,[IO.File]::ReadAllText([string]$module.Path),[StringComparison]::Ordinal)){throw 'Frozen re-entry loaded module does not match the exact closure.'}
            foreach($nested in @($module.NestedModules)){if(-not[string]::IsNullOrEmpty([string]$nested.Path)-and[IO.Path]::GetFullPath([string]$nested.Path).StartsWith($prefix,$comparison)){$pending.Enqueue($nested)}}
        }
    }
}

function Get-ReentryHistoricalTransition {
    param([string]$Workspace,[string]$Id,[string]$UnitId)
    & $script:ReentryLedgerModule { param($parameters) Test-MorphospaceCommittedTransitionLedger @parameters } @{WorkspaceRoot=$Workspace;TransactionId="$Id-transition";ExpectedStatePath='workspace.state.json';ExpectedUnitPath="iteration-units/$UnitId.json";ExpectedEventsPath='iteration-events.jsonl'}
}

function Assert-ReentryPublication {
    param([string]$ConsumerWorkspace,[object]$Request,[object]$OldContext,[switch]$Executing,[Management.Automation.PSModuleInfo[]]$AdditionalOwnerModules=@())
    if(([string]$Request.publication.resolver.path)-cnotmatch'^local/'){throw 'Frozen re-entry owner resolver must remain ignored local configuration.'}
    $resolver=Read-ReentryBinding $ConsumerWorkspace $Request.publication.resolver
    Assert-ReentrySchema $resolver 'frozen-validation-reentry-v1.schema.json' 'rusty.morphospace.workflow.frozen_validation_reentry_resolver.v1'
    if(-not[IO.Path]::IsPathFullyQualified([string]$resolver.owner_workspace)-or-not[IO.Path]::IsPathFullyQualified([string]$resolver.executor_root)){throw 'Frozen re-entry owner resolver roots must be absolute.'}
    $owner=[IO.Path]::GetFullPath([string]$resolver.owner_workspace);$root=[IO.Path]::GetFullPath([string]$resolver.executor_root)
    if([string]$Request.executor.repo_id-cne[string]$OldContext.executor.repo_id-or[string]$Request.executor.remote_url-cne[string]$OldContext.executor.remote_url){throw 'Frozen re-entry publisher is outside the original owner repository identity.'}
    if($Executing){$comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal};if(-not$root.TrimEnd('\','/').Equals((Split-Path (Split-Path $PSScriptRoot -Parent) -Parent).TrimEnd('\','/'),$comparison)){throw 'Frozen re-entry is executing outside its declared published owner root.'}}
    Assert-ReentryExecutorClosure $root $Request.executor -Executing:$Executing -AdditionalOwnerModules $AdditionalOwnerModules
    [void](Invoke-ReentryGit $root @('merge-base','--is-ancestor',[string]$OldContext.executor.commit,[string]$Request.executor.commit))
    & $script:ReentryToolingModule { param($parameters) Assert-MorphospaceToolingContextOwnerValidationEvidence @parameters } @{WorkspaceRoot=$owner;Binding=$Request.validation;Executor=$Request.executor;Name='frozen re-entry owner'}|Out-Null
    $plan=Read-ReentryBinding $owner $Request.publication.plan;$execution=Read-ReentryBinding $owner $Request.publication.execution
    Assert-ReentrySchema $plan 'source-only-publication-plan-v1.schema.json' 'rusty.morphospace.workflow.source_only_publication_plan.v1'
    Assert-ReentrySchema $execution 'source-only-publication-execution-v1.schema.json' 'rusty.morphospace.workflow.source_only_publication_execution.v1'
    if([string]$execution.publication_id-cne[string]$plan.publication_id-or[string]$execution.project_id-cne[string]$plan.project_id-or[string]$execution.trigger_unit_id-cne[string]$plan.trigger_unit_id-or[string]$Request.publication.record_event_id-cne"$([string]$plan.publication_id)-source-publication-recorded"){throw 'Frozen re-entry publication identity is detached.'}
    Assert-ReentryEqual $Request.publication.plan $execution.plan 'recorded publication plan binding'
    if([string]$Request.publication.plan.path-cne"receipts/$([string]$plan.publication_id)-plan.json"-or[string]$Request.publication.execution.path-cne"receipts/$([string]$plan.publication_id)-execution.json"){throw 'Frozen re-entry publication artifact paths are not canonical.'}
    $unitId=[string]$plan.trigger_unit_id
    $accept=Get-ReentryHistoricalTransition $owner ([string]$plan.acceptance_transition.event_id) $unitId
    if([string]$accept.transaction_id-cne[string]$plan.acceptance_transition.transaction_id-or[string]$accept.intent.target.unit.document.status-cne'accepted'-or$null-ne$accept.intent.target.state.document.current_unit-or[string]$accept.intent.target.state.document.validation_checkpoint.result-cne'pass'-or[string]$accept.intent.target.state.document.validation_checkpoint.receipt-cne[string]$plan.acceptance_transition.validation_receipt.path-or[string]$accept.intent.event.event_type-cne'state-transition'-or[string]$accept.intent.event.summary-cne'Accepted the unit after passing validation and instruction synchronization.'){throw 'Frozen re-entry publisher acceptance is detached.'}
    $acceptedUnit=$accept.intent.target.unit.document
    if([string]$acceptedUnit.push_checkpoint-cne'integration-batch'-or[string]$plan.trigger.accepted_status-cne'accepted'-or[string]$plan.trigger.push_checkpoint-cne'integration-batch'-or[string]$plan.trigger.kind-cnotin@('accepted-development-integration','accepted-development-snapshot')){throw 'Frozen re-entry publisher lacks an accepted source-only trigger.'}
    if([string]$acceptedUnit.instruction_impact-cne'none'-and@($acceptedUnit.instruction_surfaces|Where-Object{[string]$_.status-cne'complete'}).Count-ne0){throw 'Frozen re-entry publisher instruction synchronization is incomplete.'}
    if(@($accept.intent.event.receipts).Count-ne1-or[string]$accept.intent.event.receipts[0]-cne[string]$plan.acceptance_transition.validation_receipt.path){throw 'Frozen re-entry acceptance event does not bind its exact receipt.'}
    $acceptedReceipt=Read-ReentryBinding $owner $plan.acceptance_transition.validation_receipt
    [void](Assert-MorphospaceValidationReceiptStructure -Document $acceptedReceipt -AllowedSchemaIds @('rusty.morphospace.workflow.validation_receipt.v1'))
    if([string]$acceptedReceipt.result-cne'pass'-or[string]$acceptedReceipt.unit_id-cne$unitId-or[string]$acceptedReceipt.project_id-cne[string]$plan.project_id){throw 'Frozen re-entry publisher has no matching passing accepted receipt.'}
    if([string]$acceptedReceipt.tier-cne[string]$accept.intent.target.state.document.validation_checkpoint.tier-or@($acceptedReceipt.criteria|Where-Object{[string]$_.status-cne'pass'}).Count-ne0-or@($acceptedReceipt.gates|Where-Object{[string]$_.status-cne'pass'}).Count-ne0){throw 'Frozen re-entry publisher accepted evidence is not wholly passing.'}
    Assert-ReentryEqual @($acceptedUnit.acceptance|ForEach-Object{[string]$_.acceptance_id}|Sort-Object -CaseSensitive) @($acceptedReceipt.criteria|ForEach-Object{[string]$_.acceptance_id}|Sort-Object -CaseSensitive) 'publisher accepted criterion set'
    foreach($criterion in @($acceptedUnit.acceptance)){$matching=@($acceptedReceipt.criteria|Where-Object{[string]$_.acceptance_id-ceq[string]$criterion.acceptance_id});if($matching.Count-ne1-or[string]$matching[0].command-cne[string]$criterion.command){throw 'Frozen re-entry publisher accepted criterion command is detached.'}}
    $acceptedArtifacts=@{};$receiptDirectory=Split-Path (Resolve-MorphospaceWorkspacePath $owner ([string]$plan.acceptance_transition.validation_receipt.path) -RequireLeaf) -Parent
    foreach($artifact in @($acceptedReceipt.artifacts)){
        $id=[string]$artifact.artifact_id;if($acceptedArtifacts.ContainsKey($id)){throw 'Frozen re-entry publisher receipt repeats artifact identity.'};$acceptedArtifacts[$id]=$true
        $path=if([IO.Path]::IsPathRooted([string]$artifact.path)){[IO.Path]::GetFullPath([string]$artifact.path)}else{[IO.Path]::GetFullPath((Join-Path $receiptDirectory ([string]$artifact.path)))}
        if((Get-MorphospaceFileSha256 $path)-cne([string]$artifact.sha256).ToLowerInvariant()){throw 'Frozen re-entry publisher accepted artifact drifted.'}
    }
    foreach($row in @($acceptedReceipt.criteria)+@($acceptedReceipt.gates)){foreach($id in @($row.evidence_refs)){if(-not$acceptedArtifacts.ContainsKey([string]$id)){throw 'Frozen re-entry publisher receipt references an unknown artifact.'}}}
    $prepare=Get-ReentryHistoricalTransition $owner "$([string]$plan.publication_id)-source-publication-prepared" $unitId
    $record=Get-ReentryHistoricalTransition $owner ([string]$Request.publication.record_event_id) $unitId
    foreach($pair in @(@($prepare,$Request.publication.plan,'Prepared exact source-only publication from an accepted trigger; planning remains local-only.'),@($record,$Request.publication.execution,'Recorded ordered source publication and remote readback; planning remains local-only.'))){
        $proof=$pair[0];$binding=$pair[1];if([string]$proof.intent.event.project_id-cne[string]$plan.project_id-or[string]$proof.intent.event.event_type-cne'state-transition'-or[string]$proof.intent.event.summary-cne[string]$pair[2]-or@($proof.intent.event.receipts).Count-ne1-or[string]$proof.intent.event.receipts[0]-cne[string]$binding.path-or@($proof.intent.artifacts).Count-ne1-or[string]$proof.intent.artifacts[0].path-cne[string]$binding.path-or[string]$proof.intent.artifacts[0].sha256-cne[string]$binding.sha256){throw 'Frozen re-entry typed publication transaction is detached.'}
        Assert-ReentryEqual $accept.intent.target.unit.document $proof.intent.target.unit.document 'publication retained accepted unit'
    }
    $projectFences=@($prepare.intent.additional_projections)
    if($projectFences.Count-ne1-or[string]$projectFences[0].path-cne'project.spec.json'-or[string]$projectFences[0].pre_sha256-cne[string]$plan.expected.project_sha256-or[string]$projectFences[0].target_sha256-cne[string]$plan.expected.project_sha256-or(Get-MorphospaceCanonicalJsonSha256 $projectFences[0].document)-cne[string]$plan.expected.project_sha256-or[string]$projectFences[0].document.project_id-cne[string]$plan.project_id){throw 'Frozen re-entry publication project fence is detached.'}
    if(($record.intent.PSObject.Properties.Name-ccontains'additional_projections')-and@($record.intent.additional_projections).Count-ne0){throw 'Frozen re-entry publication recording adds an unexpected projection.'}
    if([string]$prepare.intent.pre.state.sha256-cne[string]$plan.expected.state_sha256-or[string]$prepare.intent.pre.unit.sha256-cne[string]$plan.expected.unit_sha256-or[string]$prepare.intent.pre.state.sha256-cne[string]$accept.intent.target.state.sha256-or[string]$prepare.intent.expected.events_sha256-cne[string]$plan.expected.events_sha256-or[int64]$prepare.intent.expected.events_length-ne[int64]$plan.expected.events_length-or[string]$prepare.intent.expected.event_tail_id-cne[string]$plan.expected.event_tail_id-or[string]$plan.expected.event_tail_id-cne[string]$accept.intent.event.event_id){throw 'Frozen re-entry publication preparation predecessor is detached.'}
    $expectedPrepared=Copy-ReentryValue $accept.intent.target.state.document;$expectedPrepared.pending_push_bundle=[pscustomobject][ordered]@{bundle_id=[string]$plan.publication_id;unit_ids=@($unitId);repo_ids=@($plan.source_repositories.repo_id);ready=$true};$expectedPrepared.last_event_id=[string]$prepare.intent.event.event_id
    Assert-ReentryEqual $expectedPrepared $prepare.intent.target.state.document 'publication prepared state'
    if([string]$record.intent.pre.state.sha256-cne[string]$prepare.intent.target.state.sha256-or[string]$record.intent.pre.unit.sha256-cne[string]$prepare.intent.target.unit.sha256-or[string]$record.intent.expected.event_tail_id-cne[string]$prepare.intent.event.event_id){throw 'Frozen re-entry publication recording predecessor is detached.'}
    $expectedRecorded=Copy-ReentryValue $expectedPrepared;$expectedRecorded.pending_push_bundle=$null;$expectedRecorded.last_event_id=[string]$record.intent.event.event_id
    Assert-ReentryEqual $expectedRecorded $record.intent.target.state.document 'publication recorded state'
    # A tooling descriptor and its publishing product may use different local
    # repository IDs.  The immutable remote/commit/tree selects the owner row;
    # no caller-supplied alias participates in this join.
    $sources=@($plan.source_repositories|Where-Object{[string]$_.remote_url-ceq[string]$OldContext.executor.remote_url-and[string]$_.candidate_revision-ceq[string]$Request.executor.commit-and[string]$_.candidate_tree-ceq[string]$Request.executor.tree})
    if($sources.Count-ne1){throw 'Frozen re-entry publication executor source is not unique.'}
    $source=$sources[0]
    $actual=@($execution.source_repositories|Where-Object{[string]$_.repo_id-ceq[string]$source.repo_id});$validated=@($acceptedReceipt.repository_revisions|Where-Object{[string]$_.repo_id-ceq[string]$source.repo_id});$owned=@($acceptedUnit.allowed_repositories|Where-Object{[string]$_.repo_id-ceq[string]$source.repo_id})
    if($actual.Count-ne1-or$validated.Count-ne1-or$owned.Count-ne1){throw 'Frozen re-entry publisher source is not uniquely owned, accepted and recorded.'}
    $row=$actual[0]
    if(@($plan.source_repositories).Count-ne@($execution.source_repositories).Count){throw 'Frozen re-entry publication source row count is detached.'}
    $started=Test-MorphospaceStrictUtcTimestamp ([string]$execution.started_at);$finished=Test-MorphospaceStrictUtcTimestamp ([string]$execution.finished_at);$previousReadback=$started;$seenSources=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if($started-lt(Test-MorphospaceStrictUtcTimestamp ([string]$prepare.intent.event.timestamp))-or$finished-gt(Test-MorphospaceStrictUtcTimestamp ([string]$record.intent.event.timestamp))){throw 'Frozen re-entry publication execution chronology is detached from its preparation and recording.'}
    for($index=0;$index-lt@($plan.source_repositories).Count;$index++){
        $p=$plan.source_repositories[$index];$x=$execution.source_repositories[$index]
        if(-not$seenSources.Add([string]$p.repo_id)-or[int]$p.dependency_ordinal-ne($index+1)){throw 'Frozen re-entry publication dependency order is not exact.'}
        foreach($field in @('dependency_ordinal','repo_id','publication_mode','old_revision','candidate_revision')){if([string]$x.$field-cne[string]$p.$field){throw 'Frozen re-entry publication source sequence is detached.'}}
        $operation=Test-MorphospaceStrictUtcTimestamp ([string]$x.operation_started_at);$readback=Test-MorphospaceStrictUtcTimestamp ([string]$x.remote_readback_at)
        if($operation-lt$previousReadback-or$readback-lt$operation-or$finished-lt$readback-or[string]$x.result-cne'pass'-or$x.force_used-ne$false-or[string]$x.final_revision-cne[string]$x.remote_readback_revision){throw 'Frozen re-entry publication ordered outcome is detached.'};$previousReadback=$readback
    }
    $reverse=@($plan.source_repositories|ForEach-Object{[string]$_.repo_id});[Array]::Reverse($reverse);Assert-ReentryEqual $reverse @($execution.rollback.reverse_dependency_order) 'publication rollback order'
    if([string]$source.remote_url-cne[string]$Request.executor.remote_url-or[string]$source.candidate_revision-cne[string]$Request.executor.commit-or[string]$source.candidate_tree-cne[string]$Request.executor.tree-or[string]$validated[0].head_revision-cne[string]$Request.executor.commit-or[string]$validated[0].branch-cne[string]$source.candidate_branch-or[string]$source.upstream-cne"$([string]$source.remote)/$([string]$source.target_branch)"){throw 'Frozen re-entry accepted publisher source is detached.'}
    foreach($field in @('dependency_ordinal','repo_id','publication_mode','old_revision','candidate_revision')){if([string]$row.$field-cne[string]$source.$field){throw 'Frozen re-entry recorded source row differs from its prepared row.'}}
    if([string]$row.final_revision-cne[string]$row.remote_readback_revision-or[string]$row.result-cne'pass'-or$row.force_used-ne$false){throw 'Frozen re-entry recorded remote outcome is detached.'}
    if((Get-ReentryGitScalar $root @('rev-parse',"$([string]$row.final_revision)^{tree}"))-cne[string]$Request.executor.tree){throw 'Frozen re-entry published source tree differs from the validated executor.'}
    if([string]$source.publication_mode-ceq'fast-forward'){
        if([string]$row.final_revision-cne[string]$source.candidate_revision-or[string]$source.final_revision-cne[string]$source.candidate_revision-or[string]$source.final_tree-cne[string]$source.candidate_tree){throw 'Frozen re-entry fast-forward publication final differs from its candidate.'}
    }else{
        $parents=(Get-ReentryGitScalar $root @('rev-list','--parents','-n','1',[string]$row.final_revision)).Split(' ',[StringSplitOptions]::RemoveEmptyEntries)
        if($parents.Count-ne3-or$parents[0]-cne[string]$row.final_revision-or$parents[1]-cne[string]$source.old_revision-or$parents[2]-cne[string]$source.candidate_revision-or$null-ne$source.final_revision-or[string]$source.final_tree-cne[string]$source.candidate_tree){throw 'Frozen re-entry provider merge publication has detached ordered parents or tree.'}
    }
    [void](Invoke-ReentryGit $root @('merge-base','--is-ancestor',[string]$Request.executor.commit,[string]$row.final_revision))
    $ref="refs/heads/$([string]$source.target_branch)";$remote=@(Invoke-ReentryGit $root @('ls-remote','--exit-code',[string]$source.remote_url,$ref))
    if($remote.Count-ne1-or$remote[0]-cnotmatch'^(?<oid>[0-9a-f]{40})\s+(?<ref>refs/heads/.+)$'-or[string]$Matches.ref-cne$ref){throw 'Frozen re-entry live publication readback is invalid.'}
    [void](Invoke-ReentryGit $root @('merge-base','--is-ancestor',[string]$row.final_revision,[string]$Matches.oid))
    [pscustomobject]@{owner_workspace=$owner;executor_root=$root;published_revision=[string]$row.final_revision;published_ref=$ref;publication_record_timestamp=[string]$record.intent.event.timestamp}
}

function Get-ReentryOriginalContext {
    param([string]$Workspace,[object]$Request,[object]$Unit)
    if(-not($Unit.PSObject.Properties.Name-ccontains'tooling_context')){throw 'Frozen re-entry requires the original bound tooling context.'}
    Assert-ReentryEqual $Unit.tooling_context $Request.tooling_context 'original context pointer'
    $context=Read-ReentryBinding $Workspace $Request.tooling_context
    if((Get-MorphospaceCanonicalJsonSha256 $context)-cne[string]$Request.tooling_context.canonical_sha256){throw 'Frozen re-entry original context canonical hash drifted.'}
    & $script:ReentryToolingModule { param($parameters) Assert-MorphospaceToolingContext @parameters } @{Context=$context}|Out-Null
    & $script:ReentryToolingModule { param($parameters) Assert-MorphospaceToolingContextLocalObservation @parameters } @{WorkspaceRoot=$Workspace;Context=$context}|Out-Null
    return $context
}

function Assert-ReentryImmutableBindings {
    param([string]$Workspace,[object]$Request,[object]$Unit)
    if([string]$Request.project_id-cne[string]$Unit.project_id-or[string]$Request.unit_id-cne[string]$Unit.unit_id-or-not($Unit.PSObject.Properties.Name-ccontains'candidate_freeze')){throw 'Frozen re-entry project, unit or Freeze is detached.'}
    $freeze=$Unit.candidate_freeze
    if([string]$Request.freeze.freeze_id-cne[string]$freeze.freeze_id-or[string]$Request.freeze.path-cne[string]$freeze.receipt_path-or[string]$Request.freeze.sha256-cne[string]$freeze.receipt_sha256){throw 'Frozen re-entry immutable Freeze pointer is detached.'}
    $candidate=Read-ReentryBinding $Workspace $Request.freeze
    if([string]$Request.repository_map.path-cne[string]$candidate.expected.repository_map_path-or[string]$Request.repository_map.sha256-cne[string]$candidate.expected.repository_map_sha256){throw 'Frozen re-entry repository map differs from the original Freeze.'}
    [void](Read-ReentryBinding $Workspace $Request.repository_map)
    if($Unit.PSObject.Properties.Name-ccontains'work_mode'-and[string]$Unit.work_mode-cne'feature'){throw 'Frozen re-entry supports ordinary feature validation only.'}
    if([string]$Unit.device_requirement-cnotin@('none','forbidden')){throw 'Frozen re-entry does not supply device serial authority.'}
}

function Assert-ReentryIntentSemantics {
    param([string]$Workspace,[object]$Request,[string]$RequestHash,[object]$Intent,[Parameter(Mandatory)][object]$Publication)
    $id="$([string]$Request.reentry_id)-frozen-validation-reentered";$unitPath="iteration-units/$([string]$Request.unit_id).json";$artifactPath="receipts/$([string]$Request.reentry_id)-frozen-validation-reentry.json"
    $ledgerPath=Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1'
    $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $binding=@($Request.executor.closure|Where-Object{[string]$_.path-ceq'scripts/lib/MorphospaceTransitionLedger.psm1'})
    if($binding.Count-ne1-or-not[IO.Path]::GetFullPath([string]$script:ReentryLedgerModule.Path).Equals([IO.Path]::GetFullPath($ledgerPath),$comparison)-or(Get-MorphospaceFileSha256 $ledgerPath)-cne[string]$binding[0].sha256-or-not[string]::Equals([string]$script:ReentryLedgerModule.Definition,[IO.File]::ReadAllText($ledgerPath),[StringComparison]::Ordinal)){throw 'Frozen re-entry structural parser is outside its exact owner closure.'}
    # Fixed owned parsing reuse only.  This does not authorize or complete a
    # transition; the original bound public transport still performs Recover.
    & $script:ReentryLedgerModule {param($Document,$TransactionId) Assert-MorphospaceLedgerIntent $Document $TransactionId} $Intent "$id-transition"
    Assert-MorphospaceExactPropertySet $Intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','pre_state_raw','pre_unit_raw','additional_projections','artifacts','event','status') @() 'Frozen re-entry intent'
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v6'-or[string]$Intent.transaction_id-cne"$id-transition"-or[string]$Intent.status-cne'prepared'-or[string]$Intent.state.path-cne'workspace.state.json'-or[string]$Intent.unit.path-cne$unitPath-or[string]$Intent.events.path-cne'iteration-events.jsonl'){throw 'Frozen re-entry intent paths or identity are detached.'}
    $event=$Intent.event
    if((Test-MorphospaceStrictUtcTimestamp ([string]$event.timestamp))-lt(Test-MorphospaceStrictUtcTimestamp ([string]$Publication.publication_record_timestamp))){throw 'Frozen re-entry event predates its authenticated SourceOnly publication record.'}
    if([string]$event.event_id-cne$id-or[string]$event.project_id-cne[string]$Request.project_id-or[string]$event.unit_id-cne[string]$Request.unit_id-or[string]$event.event_type-cne'state-transition'-or[string]$event.summary-cne'Re-entered validation for the unchanged frozen candidate after an authenticated non-passing return.'-or@($event.receipts).Count-ne1-or[string]$event.receipts[0]-cne$artifactPath){throw 'Frozen re-entry event semantics are detached.'}
    if(@($Intent.artifacts).Count-ne1-or[string]$Intent.artifacts[0].path-cne$artifactPath-or[string]$Intent.artifacts[0].sha256-cne$RequestHash-or(Get-MorphospaceSha256Bytes ([Convert]::FromBase64String([string]$Intent.artifacts[0].bytes_base64)))-cne$RequestHash){throw 'Frozen re-entry intent request bytes are detached.'}
    Assert-ReentryEqual $Request (ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$Intent.artifacts[0].bytes_base64))) 'intent request document'
    $e=$Request.expected
    if([string]$Intent.pre.state.sha256-cne[string]$e.state_sha256-or[string]$Intent.pre.unit.sha256-cne[string]$e.unit_sha256-or[string]$Intent.expected.state_sha256-cne[string]$e.state_sha256-or[string]$Intent.expected.unit_sha256-cne[string]$e.unit_sha256-or[string]$Intent.expected.events_sha256-cne[string]$e.events_sha256-or[int64]$Intent.expected.events_length-ne[int64]$e.events_length-or[string]$Intent.expected.event_tail_id-cne[string]$e.event_tail_id-or[string]$Intent.pre_state_raw.path-cne'workspace.state.json'-or[string]$Intent.pre_state_raw.sha256-cne[string]$e.state_raw_sha256-or[string]$Intent.pre_unit_raw.path-cne$unitPath-or[string]$Intent.pre_unit_raw.sha256-cne[string]$e.unit_raw_sha256){throw 'Frozen re-entry request CAS and intent predecessor are detached.'}
    $beforeUnit=Copy-ReentryValue $Intent.target.unit.document;$beforeState=Copy-ReentryValue $Intent.target.state.document
    if([string]$beforeUnit.status-cne'validating'-or[string]$beforeState.current_unit-cne[string]$Request.unit_id-or[string]$beforeState.last_event_id-cne$id){throw 'Frozen re-entry target is not ordinary validating authority.'}
    $beforeUnit.status='active';$beforeState.last_event_id=[string]$e.event_tail_id
    if((Get-MorphospaceCanonicalJsonSha256 $beforeUnit)-cne[string]$e.unit_sha256-or(Get-MorphospaceCanonicalJsonSha256 $beforeState)-cne[string]$e.state_sha256-or(Get-MorphospaceCanonicalJsonSha256 $Intent.target.unit.document)-cne[string]$Intent.target.unit.sha256-or(Get-MorphospaceCanonicalJsonSha256 $Intent.target.state.document)-cne[string]$Intent.target.state.sha256){throw 'Frozen re-entry changes authority outside its derived status and tail.'}
    if(($beforeState.PSObject.Properties.Name-ccontains'normal_validation_selection')-and$null-ne$beforeState.normal_validation_selection){throw 'Frozen re-entry does not support a retained normal-validation selector.'}
    Assert-ReentryImmutableBindings $Workspace $Request $beforeUnit
    $fences=@($Intent.additional_projections)
    if($fences.Count-ne2){throw 'Frozen re-entry requires its two immutable envelope fences.'}
    foreach($path in @('project.spec.json','feature.lock.json')){
        $file=Resolve-MorphospaceWorkspacePath $Workspace $path -RequireLeaf;$document=Read-MorphospaceProtocolJson $file;$hash=Get-MorphospaceCanonicalJsonSha256 $document;$rawHash=Get-MorphospaceFileSha256 $file
        $match=@($fences|Where-Object{[string]$_.path-ceq$path})
        if($match.Count-ne1-or[string]$match[0].pre_sha256-cne$hash-or[string]$match[0].target_sha256-cne$hash-or[string]$match[0].pre_raw_sha256-cne$rawHash){throw 'Frozen re-entry immutable envelope fence is detached.'}
        Assert-ReentryEqual $document $match[0].document 'retained envelope fence'
    }
    [pscustomobject]@{unit=$beforeUnit;state=$beforeState}
}

function Assert-MorphospaceFrozenValidationReentryHistoricalTransition {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Transition)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$intent=$Transition.intent
    if(@($intent.artifacts).Count-ne1){throw 'Frozen re-entry historical artifact inventory is invalid.'}
    $bytes=[Convert]::FromBase64String([string]$intent.artifacts[0].bytes_base64);$hash=Get-MorphospaceSha256Bytes $bytes
    $request=ConvertFrom-MorphospaceProtocolJsonBytes $bytes
    Assert-ReentrySchema $request 'frozen-validation-reentry-v1.schema.json' 'rusty.morphospace.workflow.frozen_validation_reentry.v1'
    $actual=Get-ReentryHistoricalTransition $workspace "$([string]$request.reentry_id)-frozen-validation-reentered" ([string]$request.unit_id)
    Assert-ReentryEqual $actual.intent $intent 'publicly authenticated historical intent'
    Assert-ReentryEqual $actual.completion $Transition.completion 'publicly authenticated historical completion'
    $context=Get-ReentryOriginalContext $workspace $request $intent.target.unit.document
    $publication=Assert-ReentryPublication $workspace $request $context
    [void](Assert-ReentryIntentSemantics $workspace $request $hash $intent $publication)
}

function Get-MorphospaceFrozenValidationReentryPendingObservation {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$requestFile=(Resolve-Path -LiteralPath $RequestPath).Path
    $hash=Get-MorphospaceFileSha256 $requestFile;$request=Read-MorphospaceProtocolJson $requestFile
    Assert-ReentrySchema $request 'frozen-validation-reentry-v1.schema.json' 'rusty.morphospace.workflow.frozen_validation_reentry.v1'
    $id="$([string]$request.reentry_id)-frozen-validation-reentered";$transactionId="$id-transition"
    $intentRelative="receipts/transactions/$transactionId.intent.json"
    $intentFile=Resolve-MorphospaceWorkspacePath $workspace $intentRelative -RequireLeaf
    $intent=Read-MorphospaceProtocolJson $intentFile;$intentHash=Get-MorphospaceFileSha256 $intentFile
    $context=Get-ReentryOriginalContext $workspace $request $intent.target.unit.document
    $publication=Assert-ReentryPublication $workspace $request $context -Executing
    $before=Assert-ReentryIntentSemantics $workspace $request $hash $intent $publication
    $prefixLength=[int64]$request.expected.events_length;$ledger=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $ledgerBytes=[IO.File]::ReadAllBytes($ledger)
    if($prefixLength-lt1-or$prefixLength-gt$ledgerBytes.LongLength-or$prefixLength-gt[int]::MaxValue){throw 'Frozen re-entry recovery ledger prefix length is invalid.'}
    $prefix=[byte[]]::new([int]$prefixLength);[Array]::Copy($ledgerBytes,$prefix,$prefixLength)
    if($prefix[-1]-ne10-or(Get-MorphospaceSha256Bytes $prefix)-cne[string]$request.expected.events_sha256){throw 'Frozen re-entry recovery prefix bytes are detached.'}
    $suffix=[byte[]]::new($ledgerBytes.Length-$prefix.Length);[Array]::Copy($ledgerBytes,$prefix.Length,$suffix,0,$suffix.Length)
    if($suffix.Length-gt0-and(Get-MorphospaceSha256Bytes $suffix)-cne(Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $intent.event))){throw 'Frozen re-entry recovery contains an unrelated ledger suffix.'}
    $events=@([Text.UTF8Encoding]::new($false,$true).GetString($prefix).Split("`n")|Where-Object{$_}|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes($_))})
    if($events.Count-eq0-or[string]$events[-1].event_id-cne[string]$request.expected.event_tail_id-or[int64]$intent.event.sequence-ne([int64]$events[-1].sequence+1)){throw 'Frozen re-entry recovery predecessor tail is detached.'}
    $unitPath="iteration-units/$([string]$request.unit_id).json"
    foreach($pair in @(@('workspace.state.json',$before.state,$intent.target.state.document,$request.expected.state_raw_sha256),@($unitPath,$before.unit,$intent.target.unit.document,$request.expected.unit_raw_sha256))){
        $liveFile=Resolve-MorphospaceWorkspacePath $workspace ([string]$pair[0]) -RequireLeaf;$live=Read-MorphospaceProtocolJson $liveFile
        $pre=Get-MorphospaceCanonicalJsonSha256 $pair[1];$target=Get-MorphospaceCanonicalJsonSha256 $pair[2];$observed=Get-MorphospaceCanonicalJsonSha256 $live
        if($observed-cne$pre-and$observed-cne$target){throw 'Frozen re-entry recovery has an unowned live projection.'}
        if((Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $pair[1]))-cne[string]$pair[3]){throw 'Frozen re-entry recovery cannot reconstruct the exact ordinary predecessor bytes.'}
        if($observed-ceq$pre-and(Get-MorphospaceFileSha256 $liveFile)-cne[string]$pair[3]){throw 'Frozen re-entry recovery live predecessor raw bytes drifted.'}
    }
    $owned=[Collections.Generic.List[string]]::new();$owned.Add($intentRelative)
    foreach($path in @("receipts/$([string]$request.reentry_id)-frozen-validation-reentry.json","receipts/transactions/$transactionId.artifact-0.pending")){
        $file=Resolve-MorphospaceWorkspacePath $workspace $path
        if([IO.File]::Exists($file)){if((Get-MorphospaceFileSha256 $file)-cne$hash){throw 'Frozen re-entry recovery artifact bytes drifted.'};$owned.Add($path)}
    }
    if($owned.Count-ne2){throw 'Frozen re-entry recovery must retain exactly one request artifact location.'}
    $view=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("rusty-frozen-prefix-"+[Guid]::NewGuid().ToString('N'))))
    if([IO.Directory]::Exists($view)-or[IO.File]::Exists($view)){throw 'Frozen re-entry derived observation root is occupied.'}
    [IO.Directory]::CreateDirectory($view)|Out-Null
    if(-not$script:ReentryDerivedViews.Add($view)){throw 'Frozen re-entry derived observation ownership is ambiguous.'}
    try{
        [IO.File]::WriteAllBytes((Join-Path $view 'iteration-events.jsonl'),$prefix)
        foreach($pair in @(@('workspace.state.json',$before.state),@($unitPath,$before.unit))){$target=Resolve-MorphospaceWorkspacePath $view ([string]$pair[0]);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null;[IO.File]::WriteAllBytes($target,(ConvertTo-MorphospaceProtocolJsonBytes $pair[1]))}
        $copyPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$copyPaths.Add('project.spec.json');[void]$copyPaths.Add('feature.lock.json')
        foreach($event in $events){
            $transaction="$([string]$event.event_id)-transition";$relative="receipts/transactions/$transaction.intent.json";$source=Resolve-MorphospaceWorkspacePath $workspace $relative
            if(-not[IO.File]::Exists($source)){continue}
            [void]$copyPaths.Add($relative);[void]$copyPaths.Add("receipts/transactions/$transaction.completion.json")
            $prior=Read-MorphospaceProtocolJson $source;foreach($artifact in @($prior.artifacts)){[void]$copyPaths.Add([string]$artifact.path)}
        }
        foreach($path in $copyPaths){$source=Resolve-MorphospaceWorkspacePath $workspace $path -RequireLeaf;$target=Resolve-MorphospaceWorkspacePath $view $path;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null;[IO.File]::WriteAllBytes($target,[IO.File]::ReadAllBytes($source))}
        # This view authenticates only the exact historical ledger prefix.  All
        # product, context, source and live-dirt checks retain the original root.
        $proof=& $script:ReentryLedgerModule { param($parameters) Test-MorphospaceCommittedTransitionLedger @parameters } @{WorkspaceRoot=$view;TransactionId="$([string]$request.expected.event_tail_id)-transition";ExpectedStatePath='workspace.state.json';ExpectedUnitPath=$unitPath;ExpectedEventsPath='iteration-events.jsonl';RequireTail=$true}
        Assert-ReentryEqual $proof.intent.target.unit.document $before.unit 'derived predecessor unit'
        Assert-ReentryEqual $proof.intent.target.state.document $before.state 'derived predecessor state'
        if((Get-MorphospaceFileSha256 $intentFile)-cne$intentHash-or(Get-MorphospaceFileSha256 $requestFile)-cne$hash-or(Get-MorphospaceFileSha256 $ledger)-cne(Get-MorphospaceSha256Bytes $ledgerBytes)){throw 'Frozen re-entry recovery inputs drifted during observation.'}
        [pscustomobject]@{ledger_workspace=$view;unit=$before.unit;state=$before.state;owned_paths=@($owned.ToArray());intent=$intent;request=$request;request_sha256=$hash}
    }catch{Remove-ReentryDerivedObservation $view;throw}
}

function Remove-ReentryDerivedObservation {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');$comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$script:ReentryDerivedViews.Contains($full)-or-not([IO.Path]::GetDirectoryName($full)).Equals($parent,$comparison)-or[IO.Path]::GetFileName($full)-cnotmatch'^rusty-frozen-prefix-[0-9a-f]{32}$'){throw 'Frozen re-entry derived observation cleanup target is not an owned exact temporary view.'}
    if([IO.File]::Exists($full)){throw 'Frozen re-entry derived observation cleanup root changed to a file.'}
    if([IO.Directory]::Exists($full)){
        $rootItem=Get-Item -LiteralPath $full -Force
        if(($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Frozen re-entry derived observation cleanup root is a reparse point.'}
        foreach($item in @(Get-ChildItem -LiteralPath $full -Force -Recurse)){if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Frozen re-entry derived observation cleanup found a reparse point.'}}
        Remove-Item -LiteralPath $full -Force -Recurse
    }
    [void]$script:ReentryDerivedViews.Remove($full)
}

Export-ModuleMember -Function Assert-MorphospaceFrozenValidationReentryHistoricalTransition,Get-MorphospaceFrozenValidationReentryPendingObservation,Remove-ReentryDerivedObservation
