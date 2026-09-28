Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:ReentryProtocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$script:ReentryCandidateModule=Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -PassThru
$script:ReentryToolingModule=Import-Module (Join-Path $PSScriptRoot 'ToolingContextProvenance.psm1') -PassThru
$script:ReentryProofModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceFrozenValidationReentryProof.psm1') -PassThru

function Assert-ReentrySchema {
    param([object]$Document,[string]$Name,[string]$SchemaId)
    & $script:ReentryProofModule { param($parameters) Assert-ReentrySchema @parameters } @{Document=$Document;Name=$Name;SchemaId=$SchemaId}
}

function Assert-ReentryEqual {
    param([object]$Expected,[object]$Actual,[string]$Name)
    & $script:ReentryProofModule { param($parameters) Assert-ReentryEqual @parameters } @{Expected=$Expected;Actual=$Actual;Name=$Name}
}

function Copy-ReentryValue {
    param([object]$Value)
    & $script:ReentryProofModule { param($parameters) Copy-ReentryValue @parameters } @{Value=$Value}
}

function Assert-ReentryExecutorClosure {
    param([string]$Root,[object]$Executor,[switch]$Executing)
    & $script:ReentryProofModule { param($parameters) Assert-ReentryExecutorClosure @parameters } @{Root=$Root;Executor=$Executor;Executing=$Executing;AdditionalOwnerModules=@($MyInvocation.MyCommand.Module,$script:ReentryCandidateModule)}
}

function Assert-ReentryPublication {
    param([string]$ConsumerWorkspace,[object]$Request,[object]$OldContext,[switch]$Executing)
    & $script:ReentryProofModule { param($parameters) Assert-ReentryPublication @parameters } @{ConsumerWorkspace=$ConsumerWorkspace;Request=$Request;OldContext=$OldContext;Executing=$Executing;AdditionalOwnerModules=@($MyInvocation.MyCommand.Module,$script:ReentryCandidateModule)}
}

function Get-ReentryOriginalContext {
    param([string]$Workspace,[object]$Request,[object]$Unit)
    & $script:ReentryProofModule { param($parameters) Get-ReentryOriginalContext @parameters } @{Workspace=$Workspace;Request=$Request;Unit=$Unit}
}

function Assert-ReentryImmutableBindings {
    param([string]$Workspace,[object]$Request,[object]$Unit)
    & $script:ReentryProofModule { param($parameters) Assert-ReentryImmutableBindings @parameters } @{Workspace=$Workspace;Request=$Request;Unit=$Unit}
}

function Assert-ReentryIntentSemantics {
    param([string]$Workspace,[object]$Request,[string]$RequestHash,[object]$Intent,[Parameter(Mandatory)][object]$Publication)
    & $script:ReentryProofModule { param($parameters) Assert-ReentryIntentSemantics @parameters } @{Workspace=$Workspace;Request=$Request;RequestHash=$RequestHash;Intent=$Intent;Publication=$Publication}
}

function Assert-MorphospaceFrozenValidationReentryHistoricalTransition {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Transition)
    & $script:ReentryProofModule { param($parameters) Assert-MorphospaceFrozenValidationReentryHistoricalTransition @parameters } @{WorkspaceRoot=$WorkspaceRoot;Transition=$Transition}
}

function Get-MorphospaceFrozenValidationReentryPendingObservation {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath)
    & $script:ReentryProofModule { param($parameters) Get-MorphospaceFrozenValidationReentryPendingObservation @parameters } @{WorkspaceRoot=$WorkspaceRoot;RequestPath=$RequestPath}
}

function Remove-ReentryDerivedObservation {
    param([string]$Path)
    & $script:ReentryProofModule { param($parameters) Remove-ReentryDerivedObservation @parameters } @{Path=$Path}
}

function Invoke-ReentryOriginalInspect {
    param([string]$Workspace,[object]$Unit,[object]$Request,[object]$Context,[object]$Resolver)
    # Preserve the original public producer's entire Inspect prelude in an
    # isolated host, without importing its broad graph into this finite reader.
    $wrapper=Join-Path ([string]$Resolver.executor_root) 'scripts/Invoke-WorkUnitAutomation.ps1'
    $schema=Join-Path ([string]$Resolver.executor_root) 'schemas/work-unit-automation-receipt.schema.json'
    $hostPath=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if([IO.Path]::GetFileNameWithoutExtension($hostPath)-cne'pwsh'){throw 'Frozen re-entry original Inspect requires the current native pwsh host.'}
    $hostHash=Get-MorphospaceFileSha256 $hostPath
    & $script:ReentryToolingModule { param($parameters) Assert-MorphospaceToolingContextLocalObservation @parameters } @{WorkspaceRoot=$Workspace;Context=$Context}|Out-Null
    $mapPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Request.repository_map.path) -RequireLeaf
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$hostPath;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    # Only advisory warning formatting is suppressed. Data is carried through
    # ArgumentList; the command and the original producer path are fixed.
    foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-CommandWithArgs','$WarningPreference="SilentlyContinue"; & $args[0] -Action Inspect -WorkspaceRoot $args[1] -UnitId $args[2] -RepoMapPath $args[3]',$wrapper,$Workspace,[string]$Unit.unit_id,$mapPath)){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $started=$false
    try{
        if(-not$process.Start()){throw 'Frozen re-entry original Inspect failed to start.'}
        $started=$true
        $streams=@(@{reader=$process.StandardOutput;buffer=[char[]]::new(4096);text=[Text.StringBuilder]::new();bytes=0;limit=262144;done=$false},@{reader=$process.StandardError;buffer=[char[]]::new(4096);text=[Text.StringBuilder]::new();bytes=0;limit=65536;done=$false})
        foreach($stream in $streams){$stream.task=$stream.reader.ReadAsync($stream.buffer,0,$stream.buffer.Length)}
        $timer=[Diagnostics.Stopwatch]::StartNew()
        while(-not$process.HasExited-or@($streams|Where-Object{-not$_.done}).Count){
            if($timer.ElapsedMilliseconds-ge120000){throw 'Frozen re-entry original Inspect exceeded its finite 120-second bound.'}
            foreach($stream in $streams){if(-not$stream.done-and$stream.task.IsCompleted){
                $count=$stream.task.GetAwaiter().GetResult()
                if($count-eq0){$stream.done=$true;continue}
                $chunk=[string]::new($stream.buffer,0,$count);$stream.bytes+=[Text.Encoding]::UTF8.GetByteCount($chunk)
                if($stream.bytes-gt$stream.limit){throw 'Frozen re-entry original Inspect stream exceeded its bounded size.'}
                [void]$stream.text.Append($chunk);$stream.task=$stream.reader.ReadAsync($stream.buffer,0,$stream.buffer.Length)
            }}
            if(-not$process.HasExited){[void]$process.WaitForExit(10)}else{[Threading.Thread]::Sleep(10)}
        }
        $output=$streams[0].text.ToString();$errorOutput=$streams[1].text.ToString()
        if($process.ExitCode-ne0-or-not[string]::IsNullOrWhiteSpace($errorOutput)){throw "Frozen re-entry original Inspect failed: $($errorOutput.Substring(0,[Math]::Min(2048,$errorOutput.Length)))"}
        if(-not(Test-Json -Json $output -SchemaFile $schema -ErrorAction SilentlyContinue)){throw 'Frozen re-entry original Inspect output does not satisfy its authenticated schema.'}
        $receipt=ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes($output))
        if([string]$receipt.schema-cne'rusty.morphospace.workflow.work_unit_automation_receipt.v1'-or[string]$receipt.action-cne'Inspect'-or$receipt.executed-ne$false-or[string]$receipt.transition-cne'inspect-only'-or[string]$receipt.project_id-cne[string]$Unit.project_id-or[string]$receipt.unit_id-cne[string]$Unit.unit_id-or[string]$receipt.status_before-cne[string]$Unit.status-or[string]$receipt.status_after-cne[string]$Unit.status-or[string]$receipt.current_unit_before-cne[string]$Unit.unit_id-or[string]$receipt.current_unit_after-cne[string]$Unit.unit_id-or$null-ne$receipt.event_id){throw 'Frozen re-entry original Inspect returned a detached producer identity.'}
        foreach($flag in @('git_mutation_performed','device_mutation_performed','force_push_allowed')){if($receipt.preservation.$flag-ne$false){throw 'Frozen re-entry original Inspect returned mutation authority.'}}
    }finally{if($started-and-not$process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
    if((Get-MorphospaceFileSha256 $hostPath)-cne$hostHash){throw 'Frozen re-entry original Inspect host changed during observation.'}
    & $script:ReentryToolingModule { param($parameters) Assert-MorphospaceToolingContextLocalObservation @parameters } @{WorkspaceRoot=$Workspace;Context=$Context}|Out-Null
}

function New-ReentryResult {
    param([object]$Request,[string]$Hash,[bool]$Executed,[string]$Timestamp)
    $result=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.frozen_validation_reentry_result.v1';project_id=[string]$Request.project_id;unit_id=[string]$Request.unit_id;action='FrozenValidationReentry';timestamp=$Timestamp;executed=$Executed;transition='active-to-validating';status_before='active';status_after='validating';current_unit_before=[string]$Request.unit_id;current_unit_after=[string]$Request.unit_id;audit_receipt=[pscustomobject]@{path="receipts/$([string]$Request.reentry_id)-frozen-validation-reentry.json";sha256=$Hash};event_id=$(if($Executed){"$([string]$Request.reentry_id)-frozen-validation-reentered"}else{$null});preservation=[pscustomobject]@{tooling_context_unchanged=$true;candidate_freeze_unchanged=$true;git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}}
    Assert-ReentrySchema $result 'frozen-validation-reentry-v1.schema.json' 'rusty.morphospace.workflow.frozen_validation_reentry_result.v1'
    $result
}

function Invoke-MorphospaceFrozenValidationReentry {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$UnitId,[Parameter(Mandatory)][string]$FrozenValidationReentry,[string]$ExpectedFrozenValidationReentrySha256='',[Parameter(Mandatory)][string]$OutPath,[string]$Timestamp='',[switch]$Execute,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none')
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$inputFile=(Resolve-Path -LiteralPath $FrozenValidationReentry).Path;$hash=Get-MorphospaceFileSha256 $inputFile;$request=Read-MorphospaceProtocolJson $inputFile
    Assert-ReentrySchema $request 'frozen-validation-reentry-v1.schema.json' 'rusty.morphospace.workflow.frozen_validation_reentry.v1'
    if([string]$request.unit_id-cne$UnitId-or($ExpectedFrozenValidationReentrySha256-and$ExpectedFrozenValidationReentrySha256-cne$hash)-or($Execute-and-not$ExpectedFrozenValidationReentrySha256)){throw 'Frozen re-entry identity or required dry-run request hash is detached.'}
    $relative="receipts/$([string]$request.reentry_id)-frozen-validation-reentry.json";$out=Resolve-MorphospaceWorkspacePath $workspace $relative
    if([IO.Path]::GetFullPath($OutPath)-cne$out){throw 'Frozen re-entry output path must be its canonical audit receipt.'}
    $unitPath="iteration-units/$UnitId.json";$unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    $state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
    $eventId="$([string]$request.reentry_id)-frozen-validation-reentered";$transactionId="$eventId-transition"
    $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.intent.json"
    if(Test-Path -LiteralPath $intentPath){
        $intent=Read-MorphospaceProtocolJson $intentPath
        $context=Get-ReentryOriginalContext $workspace $request $intent.target.unit.document
        $publication=Assert-ReentryPublication $workspace $request $context -Executing
        $before=Assert-ReentryIntentSemantics $workspace $request $hash $intent $publication
        $oldResolver=& $script:ReentryToolingModule { param($parameters) Read-MorphospaceToolingContextResolver @parameters } @{WorkspaceRoot=$workspace;Context=$context}
        $oldLedgerModule=Import-Module (Join-Path ([string]$oldResolver.executor_root) 'scripts/lib/MorphospaceTransitionLedger.psm1') -PassThru
        & $script:ReentryToolingModule { param($parameters) Assert-MorphospaceToolingContextLoadedOwnerModule @parameters } @{Context=$context;ExecutorRoot=([string]$oldResolver.executor_root);OwnerModule=$oldLedgerModule}|Out-Null
        $completionPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.completion.json"
        if([IO.File]::Exists($completionPath)){
            $proof=& $oldLedgerModule { param($parameters) Test-MorphospaceCommittedTransitionLedger @parameters } @{WorkspaceRoot=$workspace;TransactionId=$transactionId;ExpectedStatePath='workspace.state.json';ExpectedUnitPath=$unitPath;ExpectedEventsPath='iteration-events.jsonl';RequireTail=$true}
            Assert-ReentryEqual $intent $proof.intent 'idempotent re-entry intent'
            [void](& $script:ReentryCandidateModule { param($parameters) Get-MorphospaceFrozenValidationContinuation @parameters } @{WorkspaceRoot=$workspace;Unit=$unit})
        }else{
            $flow=& $script:ReentryCandidateModule { param($parameters) Get-MorphospaceFrozenValidationContinuation @parameters } @{WorkspaceRoot=$workspace;Unit=$unit;PendingReentry=$inputFile}
            if(@($flow.transitions).Count-lt2-or[string]$flow.unit.status-cne'active'-or[string]$flow.state.validation_checkpoint.result-cnotin@('fail','partial','blocked')){throw 'Frozen re-entry recovery lacks a genuine non-passing predecessor.'}
            if($Execute){& $oldLedgerModule { param($parameters) Complete-MorphospaceTransitionLedger @parameters } @{WorkspaceRoot=$workspace;TransactionId=$transactionId;Repair=$true;FaultAfter=$FaultAfter}|Out-Null}
        }
        if($Execute){
            $proof=& $oldLedgerModule { param($parameters) Test-MorphospaceCommittedTransitionLedger @parameters } @{WorkspaceRoot=$workspace;TransactionId=$transactionId;ExpectedStatePath='workspace.state.json';ExpectedUnitPath=$unitPath;ExpectedEventsPath='iteration-events.jsonl';RequireTail=$true}
            [void](Assert-ReentryIntentSemantics $workspace $request $hash $proof.intent $publication)
            Assert-ReentryExecutorClosure ([string]$publication.executor_root) $request.executor -Executing
        }
        if((Get-MorphospaceFileSha256 $inputFile)-cne$hash){throw 'Frozen re-entry input drifted during recovery.'}
        return New-ReentryResult $request $hash $Execute.IsPresent ([string]$intent.event.timestamp)
    }
    if([string]$unit.status-cne'active'-or[string]$state.current_unit-cne$UnitId-or(($state.PSObject.Properties.Name-ccontains'normal_validation_selection')-and$null-ne$state.normal_validation_selection)){throw 'Frozen re-entry requires the exact active frozen unit without a selector.'}
    Assert-ReentryImmutableBindings $workspace $request $unit
    $context=Get-ReentryOriginalContext $workspace $request $unit
    $publication=Assert-ReentryPublication $workspace $request $context -Executing
    $oldResolver=& $script:ReentryToolingModule { param($parameters) Read-MorphospaceToolingContextResolver @parameters } @{WorkspaceRoot=$workspace;Context=$context}
    Invoke-ReentryOriginalInspect $workspace $unit $request $context $oldResolver
    $flow=& $script:ReentryCandidateModule { param($parameters) Get-MorphospaceFrozenValidationContinuation @parameters } @{WorkspaceRoot=$workspace;Unit=$unit}
    if(@($flow.transitions).Count-lt2-or[string]$state.validation_checkpoint.result-cnotin@('fail','partial','blocked')){throw 'Frozen re-entry requires a genuine retained non-passing validation return.'}
    $eventsFile=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf;$e=$request.expected
    $casPairs=@(@($e.state_sha256,(Get-MorphospaceCanonicalJsonSha256 $state)),@($e.unit_sha256,(Get-MorphospaceCanonicalJsonSha256 $unit)),@($e.state_raw_sha256,(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf))),@($e.unit_raw_sha256,(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf))),@($e.events_sha256,(Get-MorphospaceFileSha256 $eventsFile)))
    foreach($check in $casPairs){if([string]$check[0]-cne[string]$check[1]){throw 'Frozen re-entry stale canonical or raw predecessor CAS.'}}
    $events=@(Get-Content -LiteralPath $eventsFile|Where-Object{$_}|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$_))});$tail=$events[-1]
    if([int64]$e.events_length-ne([IO.FileInfo]$eventsFile).Length-or[string]$e.event_tail_id-cne[string]$tail.event_id-or[string]$state.last_event_id-cne[string]$tail.event_id){throw 'Frozen re-entry ledger CAS is detached.'}
    if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};[void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    if((Test-MorphospaceStrictUtcTimestamp $Timestamp)-lt(Test-MorphospaceStrictUtcTimestamp ([string]$publication.publication_record_timestamp))){throw 'Frozen re-entry event predates its authenticated SourceOnly publication record.'}
    $targetUnit=Copy-ReentryValue $unit;$targetUnit.status='validating';$targetState=Copy-ReentryValue $state;$targetState.last_event_id=$eventId
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int64]$tail.sequence+1;timestamp=$Timestamp;project_id=[string]$request.project_id;unit_id=$UnitId;event_type='state-transition';summary='Re-entered validation for the unchanged frozen candidate after an authenticated non-passing return.';receipts=@($relative)}
    if($Execute){
        $oldLedgerModule=Import-Module (Join-Path ([string]$oldResolver.executor_root) 'scripts/lib/MorphospaceTransitionLedger.psm1') -PassThru
        & $script:ReentryToolingModule { param($parameters) Assert-MorphospaceToolingContextLoadedOwnerModule @parameters } @{Context=$context;ExecutorRoot=([string]$oldResolver.executor_root);OwnerModule=$oldLedgerModule}|Out-Null
        $fences=@();foreach($path in @('feature.lock.json','project.spec.json')){$file=Resolve-MorphospaceWorkspacePath $workspace $path -RequireLeaf;$doc=Read-MorphospaceProtocolJson $file;$fences+=,[pscustomobject]@{path=$path;expected_sha256=(Get-MorphospaceCanonicalJsonSha256 $doc);expected_raw_sha256=(Get-MorphospaceFileSha256 $file);document=$doc}}
        & $oldLedgerModule { param($parameters) Start-MorphospaceTransitionLedger @parameters } @{WorkspaceRoot=$workspace;TransactionId=$transactionId;StatePath='workspace.state.json';UnitPath=$unitPath;EventsPath='iteration-events.jsonl';TargetState=$targetState;TargetUnit=$targetUnit;Event=$event;ExpectedPreStateSha256=$e.state_sha256;ExpectedPreStateRawSha256=$e.state_raw_sha256;ExpectedPreUnitSha256=$e.unit_sha256;ExpectedPreUnitRawSha256=$e.unit_raw_sha256;ExpectedEventTailId=$e.event_tail_id;ExpectedEventsSha256=$e.events_sha256;ExpectedEventsLength=$e.events_length;AdditionalProjections=$fences;Artifacts=@([pscustomobject]@{source_path=$inputFile;path=$relative;sha256=$hash});FaultAfter=$FaultAfter}|Out-Null
        $proof=& $oldLedgerModule { param($parameters) Test-MorphospaceCommittedTransitionLedger @parameters } @{WorkspaceRoot=$workspace;TransactionId=$transactionId;ExpectedStatePath='workspace.state.json';ExpectedUnitPath=$unitPath;ExpectedEventsPath='iteration-events.jsonl';RequireTail=$true}
        [void](Assert-ReentryIntentSemantics $workspace $request $hash $proof.intent $publication)
        if((Get-MorphospaceFileSha256 $inputFile)-cne$hash){throw 'Frozen re-entry input drifted during execution.'}
        Assert-ReentryExecutorClosure ([string]$publication.executor_root) $request.executor -Executing
    }
    New-ReentryResult $request $hash $Execute.IsPresent $Timestamp
}
Export-ModuleMember -Function Invoke-MorphospaceFrozenValidationReentry,Assert-MorphospaceFrozenValidationReentryHistoricalTransition,Get-MorphospaceFrozenValidationReentryPendingObservation,Remove-ReentryDerivedObservation
