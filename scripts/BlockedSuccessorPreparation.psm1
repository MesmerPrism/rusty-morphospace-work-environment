Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
$script:BlockedSuccessorTransitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force -PassThru

function Copy-BlockedSuccessorValue { param([object]$Value) $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -DateKind String }
function Get-BlockedSuccessorHash { param([object]$Value) Get-MorphospaceCanonicalJsonSha256 $Value }
function Get-BlockedSuccessorBytes { param([object]$Value) [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 100)) }
function Get-BlockedSuccessorByteHash { param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Assert-BlockedSuccessorSchema {
    param([string]$Path,[string]$Schema,[string]$Message)
    $schemaPath=Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\$Schema"
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $Path) -SchemaFile $schemaPath)){throw $Message}
}
function Assert-BlockedSuccessorBindingEqual {
    param([object]$Expected,[object]$Actual,[string]$Message)
    if((Get-BlockedSuccessorHash $Expected)-cne(Get-BlockedSuccessorHash $Actual)){throw $Message}
}
function Assert-BlockedSuccessorExactPropertySet {
    param([object]$Value,[string[]]$Required,[string]$Label)
    if($null-eq$Value){throw "$Label is absent."}
    $actual=@($Value.PSObject.Properties.Name);$expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($name in $Required){if(-not$expected.Add($name)){throw "$Label expected-property declaration repeats '$name'."}}
    if($actual.Count-ne$expected.Count){throw "$Label property set is not exact."}
    foreach($name in $actual){if(-not$expected.Contains([string]$name)){throw "$Label property set is not exact."}}
}
function Assert-BlockedSuccessorHistoricalCommittedTransaction {
    param([string]$Workspace,[object]$Request,[object]$HistoricalState,[object[]]$Events)
    if($null-eq$script:BlockedSuccessorTransitionLedgerModule){throw 'Blocked-successor transition-ledger module handle is unavailable.'}
    $tx=Copy-BlockedSuccessorValue $Request.terminal.transaction;$transactionId=[string]$tx.transaction_id
    $intentRelative="receipts/transactions/$transactionId.intent.json";$completionRelative="receipts/transactions/$transactionId.completion.json"
    Assert-BlockedSuccessorExactPropertySet $tx @('transaction_id','intent_path','intent_sha256','completion_path','completion_sha256') 'Blocked-successor historical terminal transaction reference'
    if($transactionId-cne"$([string]$Request.terminal.event_id)-transition"-or[string]$tx.intent_path-cne$intentRelative-or[string]$tx.completion_path-cne$completionRelative-or[string]$tx.intent_sha256-cnotmatch'^[0-9a-f]{64}$'-or[string]$tx.completion_sha256-cnotmatch'^[0-9a-f]{64}$'){throw 'Blocked-successor historical terminal transaction reference is not exact.'}
    if($null-eq$Events){$Events=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})}
    $historicalEvent=$null;$historicalPosition=-1
    for($index=0;$index-lt@($Events).Count;$index++){if([string]$Events[$index].event_id-ceq[string]$Request.terminal.event_id){if($null-ne$historicalEvent){throw 'Blocked-successor historical terminal event is duplicated.'};$historicalEvent=$Events[$index];$historicalPosition=$index}}
    if($null-eq$historicalEvent-or(Get-BlockedSuccessorHash $historicalEvent)-cne[string]$Request.terminal.event_sha256-or[int]$historicalEvent.sequence-ne($historicalPosition+1)-or[string]$HistoricalState.last_event_id-cne[string]$historicalEvent.event_id){throw 'Blocked-successor retained historical terminal state/event authority is not exact.'}
    $intentPath=Resolve-MorphospaceWorkspacePath $Workspace $intentRelative;$completionPath=Resolve-MorphospaceWorkspacePath $Workspace $completionRelative
    $intentExists=[IO.File]::Exists($intentPath);$completionExists=[IO.File]::Exists($completionPath)
    if($intentExists-xor$completionExists){throw 'Blocked-successor archived historical terminal transaction is only partially retained.'}
    if(-not$intentExists){return [pscustomobject]@{intent=[pscustomobject]@{event=$historicalEvent};completion=$null;archived=$true}}
    if((Get-MorphospaceFileSha256 $intentPath)-cne[string]$tx.intent_sha256-or(Get-MorphospaceFileSha256 $completionPath)-cne[string]$tx.completion_sha256){throw 'Blocked-successor historical terminal transaction raw bytes drifted.'}
    $intent=Read-MorphospaceProtocolJson $intentPath
    &$script:BlockedSuccessorTransitionLedgerModule {param($candidate,$id)Assert-MorphospaceLedgerIntent $candidate $id} $intent $transactionId
    if([string]$intent.state.path-cne'workspace.state.json'-or[string]$intent.unit.path-cne[string]$Request.terminal.unit_path-or[string]$intent.events.path-cne'iteration-events.jsonl'){throw 'Blocked-successor historical terminal intent projection paths are not exact.'}
    if([string]$intent.target.state.sha256-cne(Get-BlockedSuccessorHash $HistoricalState)-or(Get-BlockedSuccessorHash $intent.target.state.document)-cne(Get-BlockedSuccessorHash $HistoricalState)){throw 'Blocked-successor historical terminal intent target state differs from the authenticated terminal state.'}
    if([string]$intent.target.unit.sha256-cne[string]$Request.terminal.unit_canonical_sha256-or(Get-BlockedSuccessorHash $intent.target.unit.document)-cne[string]$Request.terminal.unit_canonical_sha256){throw 'Blocked-successor historical terminal intent target unit differs from the authenticated terminal unit.'}
    if((Get-BlockedSuccessorHash $intent.event)-cne[string]$Request.terminal.event_sha256-or[string]$intent.event.event_id-cne[string]$Request.terminal.event_id){throw 'Blocked-successor historical terminal intent event differs from the authenticated terminal event.'}
    $completion=Read-MorphospaceProtocolJson $completionPath
    Assert-BlockedSuccessorExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') 'Blocked-successor historical terminal completion'
    Assert-BlockedSuccessorExactPropertySet $completion.intent @('role','path','schema','sha256') 'Blocked-successor historical terminal completion intent reference'
    if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or[string]$completion.transaction_id-cne$transactionId-or[string]$completion.status-cne'committed'-or[string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$intentRelative-or[string]$completion.intent.schema-cne[string]$intent.schema-or[string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $intentPath)-or[string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256-or[string]$completion.event_id-cne[string]$intent.event.event_id){throw 'Blocked-successor historical terminal completion is not canonically bound to its exact intent.'}
    $created=Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at);$completed=Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at);if($completed-lt$created){throw 'Blocked-successor historical terminal completion precedes its intent.'}
    &$script:BlockedSuccessorTransitionLedgerModule {param($workspaceRoot,$id,$candidate,$eventsPath)
        Assert-MorphospaceLedgerArtifactNamespace $workspaceRoot $id $candidate
        [void](Assert-MorphospaceLedgerEventPlacement $eventsPath $candidate -AllowHistorical -RequirePresent)
    } $Workspace $transactionId $intent (Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf)
    foreach($artifact in @($intent.artifacts)){$target=Resolve-MorphospaceWorkspacePath $Workspace ([string]$artifact.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $target)-cne[string]$artifact.sha256){throw "Blocked-successor historical terminal committed artifact differs from its intent: $($artifact.path)"}}
    [pscustomobject]@{intent=$intent;completion=$completion;archived=$false}
}
function Get-BlockedSuccessorRepositoryMap {
    param([object]$Document)
    $map=@{};foreach($entry in @($Document.repositories)){$id=[string]$entry.repo_id;if($map.ContainsKey($id)){throw "Blocked-successor repository map repeats '$id'."};$map[$id]=$entry};$map
}
function Test-BlockedSuccessorPathWithinRoots {
    param([string]$Path,[object[]]$Roots)
    foreach($root in @($Roots)){$prefix=([string]$root).TrimEnd('/');if($Path-ceq$prefix-or$Path.StartsWith("$prefix/",[StringComparison]::OrdinalIgnoreCase)){return $true}};return $false
}
function Get-BlockedSuccessorTerminalObservation {
    param([string]$Workspace,[object]$Request,[object]$Project,[object]$State,[object[]]$Events,[switch]$AllowHistoricalTerminal)
    $terminal=$Request.terminal
    $unitPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$terminal.unit_path) -RequireLeaf
    $unit=Read-MorphospaceProtocolJson $unitPath
    if([string]$unit.project_id-cne[string]$Request.project_id-or[string]$unit.unit_id-cne[string]$terminal.unit_id-or[string]$unit.status-cne'blocked'){throw 'Blocked-successor preparation requires the exact terminal blocked predecessor.'}
    if((Get-MorphospaceFileSha256 $unitPath)-cne[string]$terminal.unit_raw_sha256-or(Get-BlockedSuccessorHash $unit)-cne[string]$terminal.unit_canonical_sha256){throw 'Blocked-successor terminal unit bytes drifted.'}
    if(-not($unit.PSObject.Properties.Name-contains'candidate_freeze')){throw 'Blocked-successor predecessor is not candidate-frozen.'}
    foreach($name in @('freeze_id','receipt_path','receipt_sha256')){if([string]$unit.candidate_freeze.$name-cne[string]$terminal.candidate_freeze.$name){throw "Blocked-successor candidate-freeze $name drifted."}}
    $freezePath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$terminal.candidate_freeze.receipt_path) -RequireLeaf
    Assert-BlockedSuccessorSchema $freezePath 'candidate-freeze-v1.schema.json' 'Blocked-successor candidate-freeze receipt is invalid.'
    if((Get-MorphospaceFileSha256 $freezePath)-cne[string]$terminal.candidate_freeze.receipt_sha256){throw 'Blocked-successor candidate-freeze receipt bytes drifted.'}
    $freeze=Read-MorphospaceProtocolJson $freezePath
    if([string]$freeze.freeze_id-cne[string]$terminal.candidate_freeze.freeze_id-or[string]$freeze.unit_id-cne[string]$terminal.unit_id-or[string]$freeze.project_id-cne[string]$Request.project_id){throw 'Blocked-successor candidate-freeze identity is not exact.'}

    if($null-eq$State.normal_validation_selection-or(Get-BlockedSuccessorHash $State.normal_validation_selection)-cne[string]$terminal.selector_binding_sha256-or[string]$State.normal_validation_selection.unit_id-cne[string]$terminal.unit_id-or[string]$State.normal_validation_selection.tier-cne'quick'){throw 'Blocked-successor stale Quick selector binding is not exact.'}
    $checkpoint=$State.validation_checkpoint
    if($null-eq$checkpoint-or[string]$checkpoint.tier-cne'standard'-or[string]$checkpoint.result-cne[string]$terminal.checkpoint.result-or[string]$checkpoint.receipt-cne[string]$terminal.checkpoint.receipt_path){throw 'Blocked-successor Standard terminal checkpoint is not exact.'}
    $validationPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$terminal.checkpoint.receipt_path) -RequireLeaf
    Assert-BlockedSuccessorSchema $validationPath 'validation-receipt.schema.json' 'Blocked-successor terminal validation receipt is invalid.'
    if((Get-MorphospaceFileSha256 $validationPath)-cne[string]$terminal.checkpoint.receipt_sha256){throw 'Blocked-successor terminal validation receipt bytes drifted.'}
    $validation=Read-MorphospaceProtocolJson $validationPath
    if([string]$validation.project_id-cne[string]$Request.project_id-or[string]$validation.unit_id-cne[string]$terminal.unit_id-or[string]$validation.tier-cne'standard'-or[string]$validation.result-cne[string]$terminal.checkpoint.result){throw 'Blocked-successor terminal validation receipt semantics drifted.'}

    $blockerId="$([string]$terminal.unit_id)-validation-$([string]$terminal.checkpoint.result)"
    $blockers=@($State.blockers|Where-Object{[string]$_.blocker_id-ceq$blockerId})
    if($blockers.Count-ne1-or(Get-BlockedSuccessorHash $blockers[0])-cne[string]$terminal.blocker_sha256){throw 'Blocked-successor terminal blocker binding is not exact.'}
    $event=@($Events|Where-Object{[string]$_.event_id-ceq[string]$terminal.event_id})
    if($event.Count-ne1-or[string]$event[0].unit_id-cne[string]$terminal.unit_id-or[string]$event[0].event_type-cne'blocker'-or@($event[0].receipts).Count-ne1-or[string]$event[0].receipts[0]-cne[string]$terminal.checkpoint.receipt_path-or(Get-BlockedSuccessorHash $event[0])-cne[string]$terminal.event_sha256){throw 'Blocked-successor terminal event binding is not exact.'}
    if([string]$State.last_event_id-cne[string]$terminal.event_id-or(-not$AllowHistoricalTerminal-and[string]$Events[-1].event_id-cne[string]$terminal.event_id)){throw 'Blocked-successor terminal event is not the required state/physical tail.'}
    $tx=$terminal.transaction
    if($AllowHistoricalTerminal){$committed=Assert-BlockedSuccessorHistoricalCommittedTransaction $Workspace $Request $State $Events}
    else{
        foreach($reference in @(@{p=$tx.intent_path;h=$tx.intent_sha256},@{p=$tx.completion_path;h=$tx.completion_sha256})){$path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$reference.p) -RequireLeaf;if((Get-MorphospaceFileSha256 $path)-cne[string]$reference.h){throw 'Blocked-successor terminal transaction bytes drifted.'}}
        $committed=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId ([string]$tx.transaction_id) -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$terminal.unit_path) -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail
    }
    if([string]$committed.intent.event.event_id-cne[string]$terminal.event_id-or(-not$AllowHistoricalTerminal-and[string]$committed.event_tail_id-cne[string]$terminal.event_id)){throw 'Blocked-successor terminal committed transition does not own the required event.'}

    $repair=$Request.repair
    $oldRepo=@($unit.allowed_repositories|Where-Object{[string]$_.repo_id-ceq[string]$repair.repo_id})
    $projectRepo=@($Project.repositories|Where-Object{[string]$_.repo_id-ceq[string]$repair.repo_id})
    $assessmentRepo=@($unit.agent_scope_assessment.owner_repositories|Where-Object{[string]$_.repo_id-ceq[string]$repair.repo_id})
    if($oldRepo.Count-ne1-or$projectRepo.Count-ne1-or$assessmentRepo.Count-ne1){throw 'Blocked-successor repair repository is absent from the terminal project/agent/unit envelope.'}
    if(Test-BlockedSuccessorPathWithinRoots ([string]$repair.path) @($oldRepo[0].allowed_paths)){throw 'Blocked-successor repair path is already writable by the frozen terminal unit.'}
    if(-not(Test-BlockedSuccessorPathWithinRoots ([string]$repair.path) @($projectRepo[0].allowed_paths))-or-not(Test-BlockedSuccessorPathWithinRoots ([string]$repair.path) @($assessmentRepo[0].source_roots))){throw 'Blocked-successor repair path exceeds the existing project or agent envelope.'}
    $artifact=@($validation.artifacts|Where-Object{[string]$_.artifact_id-ceq[string]$repair.evidence_artifact_id})
    if($artifact.Count-ne1){throw 'Blocked-successor repair lacks exactly one terminal evidence artifact.'}
    $artifactPath=if([IO.Path]::IsPathRooted([string]$artifact[0].path)){[IO.Path]::GetFullPath([string]$artifact[0].path)}else{[IO.Path]::GetFullPath((Join-Path (Split-Path $validationPath -Parent) ([string]$artifact[0].path)))}
    if(-not[IO.File]::Exists($artifactPath)-or(Get-MorphospaceFileSha256 $artifactPath)-cne([string]$artifact[0].sha256).ToLowerInvariant()){throw 'Blocked-successor terminal evidence artifact bytes drifted.'}
    $evidence=Read-MorphospaceProtocolJson $artifactPath
    if(-not($evidence.PSObject.Properties.Name-contains'source_path')-or[string]$evidence.source_path-cne[string]$repair.path){throw 'Blocked-successor evidence does not identify the exact repair path.'}
    [pscustomobject]@{unit=$unit;freeze=$freeze;validation=$validation;blocker=$blockers[0];event=$event[0];repair_artifact=$artifact[0]}
}

function ConvertFrom-BlockedSuccessorIntentArtifact {
    param([object]$Artifact,[string]$Label)
    try{$bytes=[Convert]::FromBase64String([string]$Artifact.bytes_base64)}catch{throw "Blocked-successor $Label artifact payload is not valid base64."}
    if((Get-BlockedSuccessorByteHash $bytes)-cne[string]$Artifact.sha256){throw "Blocked-successor $Label artifact payload hash drifted."}
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);$document=$text|ConvertFrom-Json -DateKind String}catch{throw "Blocked-successor $Label artifact is not strict UTF-8 JSON."}
    [pscustomobject]@{bytes=$bytes;document=$document}
}

function New-BlockedSuccessorAutomationResult {
    param([object]$Request,[string]$Timestamp,[bool]$Executed,[string]$ReceiptRelative,[string]$InputHash)
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$Request.project_id;unit_id=$Request.terminal.unit_id;action='PrepareBlockedSuccessor';timestamp=$Timestamp;executed=$Executed;transition='blocked-successor-prepared';status_before='blocked';status_after='blocked';current_unit_before=$null;current_unit_after=$null
        preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt=[ordered]@{path=$ReceiptRelative;sha256=$InputHash}
        event_id=$(if($Executed){"$([string]$Request.preparation_id)-prepared"}else{$null})
    }
}

function Get-BlockedSuccessorRecoveryBinding {
    param([string]$Workspace,[object]$Request,[string]$InputHash,[string]$ReceiptRelative,[string]$SourceRelative,[string]$TransactionId,[string]$IntentPath,[bool]$CompletionExists)
    $intent=Read-MorphospaceProtocolJson $IntentPath
    $eventId="$([string]$Request.preparation_id)-prepared"
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v5'-or[string]$intent.transaction_id-cne$TransactionId-or[string]$intent.state.path-cne'workspace.state.json'-or[string]$intent.unit.path-cne[string]$Request.terminal.unit_path-or[string]$intent.events.path-cne'iteration-events.jsonl'){
        throw 'Blocked-successor recovery intent identity or live paths conflict with the exact request.'
    }
    if([string]$intent.pre_unit_raw.path-cne[string]$Request.terminal.unit_path-or[string]$intent.pre_unit_raw.sha256-cne[string]$Request.terminal.unit_raw_sha256-or[string]$intent.pre.unit.sha256-cne[string]$Request.terminal.unit_canonical_sha256-or[string]$intent.expected.unit_sha256-cne[string]$Request.terminal.unit_canonical_sha256-or[string]$intent.pre.state.sha256-cne[string]$Request.expected.state_sha256-or[string]$intent.expected.state_sha256-cne[string]$Request.expected.state_sha256-or[string]$intent.expected.events_sha256-cne[string]$Request.expected.events_sha256-or[int64]$intent.expected.events_length-ne[int64]$Request.expected.events_length-or[string]$intent.expected.event_tail_id-cne[string]$Request.expected.event_tail_id){
        throw 'Blocked-successor recovery intent preimage conflicts with the exact request.'
    }
    if((Get-BlockedSuccessorHash $intent.target.unit.document)-cne[string]$Request.terminal.unit_canonical_sha256-or[string]$intent.target.unit.sha256-cne[string]$Request.terminal.unit_canonical_sha256){throw 'Blocked-successor recovery target unit conflicts with the immutable terminal predecessor.'}
    $preState=Copy-BlockedSuccessorValue $intent.target.state.document
    if([string]$preState.last_event_id-cne$eventId){throw 'Blocked-successor recovery target state does not own the exact preparation event.'}
    $preState.last_event_id=[string]$Request.expected.event_tail_id
    if((Get-BlockedSuccessorHash $preState)-cne[string]$Request.expected.state_sha256-or[string]$intent.target.state.sha256-cne(Get-BlockedSuccessorHash $intent.target.state.document)){throw 'Blocked-successor recovery target state changes more than the event tail.'}
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$intent.event.timestamp))
    $expectedEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$intent.event.sequence;timestamp=[string]$intent.event.timestamp;project_id=$Request.project_id;unit_id=$Request.terminal.unit_id;event_type='decision';summary='Prepared one bounded successor to an immutable terminal blocked unit; admission remains separate.';receipts=@($ReceiptRelative,$SourceRelative)}
    if((Get-BlockedSuccessorHash $intent.event)-cne(Get-BlockedSuccessorHash $expectedEvent)){throw 'Blocked-successor recovery event conflicts with the exact request.'}
    $artifacts=@($intent.artifacts)
    if($artifacts.Count-ne2-or[string]$artifacts[0].path-cne$ReceiptRelative-or[string]$artifacts[1].path-cne$SourceRelative){throw 'Blocked-successor recovery requires the exact ordered receipt and source artifacts.'}
    $receiptArtifact=ConvertFrom-BlockedSuccessorIntentArtifact $artifacts[0] 'preparation receipt'
    $sourceArtifact=ConvertFrom-BlockedSuccessorIntentArtifact $artifacts[1] 'source composition'
    $receipt=$receiptArtifact.document;$source=$sourceArtifact.document
    if(-not(Test-Json -Json ($receipt|ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\blocked-successor-preparation-receipt-v1.schema.json'))){throw 'Blocked-successor recovery preparation receipt is invalid.'}
    if(-not(Test-Json -Json ($source|ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\development-envelope-source-composition-v1.schema.json'))){throw 'Blocked-successor recovery source composition is invalid.'}
    $terminalBindingHash=Get-BlockedSuccessorHash ([pscustomobject][ordered]@{terminal=$Request.terminal;repair=$Request.repair})
    $expectedReceipt=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.blocked_successor_preparation_receipt.v1';preparation_id=$Request.preparation_id;project_id=$Request.project_id;successor_unit_id=$Request.successor_unit_id;input_sha256=$InputHash;terminal=$Request.terminal;repair=$Request.repair;source_composition=[pscustomobject][ordered]@{path=$SourceRelative;sha256=[string]$artifacts[1].sha256};terminal_binding_sha256=$terminalBindingHash;does_not_prove=@('Does not admit, Ready, claim, mutate source, build, use a device, accept, or publish the successor.')}
    if((Get-BlockedSuccessorHash $receipt)-cne(Get-BlockedSuccessorHash $expectedReceipt)){throw 'Blocked-successor recovery preparation receipt does not bind the exact request.'}
    $project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'project.spec.json' -RequireLeaf)
    $events=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    $terminal=Get-BlockedSuccessorTerminalObservation $Workspace $Request $project $preState $events -AllowHistoricalTerminal
    if(-not$CompletionExists){
        $lock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'feature.lock.json' -RequireLeaf)
        $mapPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Request.expected.repository_map_path) -RequireLeaf
        if((Get-BlockedSuccessorHash $project)-cne[string]$Request.expected.project_sha256-or(Get-BlockedSuccessorHash $lock)-cne[string]$Request.expected.feature_lock_sha256-or(Get-MorphospaceFileSha256 $mapPath)-cne[string]$Request.expected.repository_map_sha256){throw 'Blocked-successor pending recovery project, feature lock, or repository map drifted.'}
        $map=Get-BlockedSuccessorRepositoryMap (Read-MorphospaceProtocolJson $mapPath)
        $observedSource=Get-BlockedSuccessorSourceComposition $Request $terminal $map
        if((Get-BlockedSuccessorHash $observedSource)-cne(Get-BlockedSuccessorHash $source)){throw 'Blocked-successor pending recovery source composition drifted.'}
    }
    [pscustomobject]@{intent=$intent;terminal=$terminal;receipt=$receipt;source=$source}
}
function Get-BlockedSuccessorSourceComposition {
    param([object]$Request,[object]$Terminal,[hashtable]$RepositoryMap)
    $ids=@($Request.source_repository_ids);$sorted=@($ids|Sort-Object -CaseSensitive -Unique)
    if($ids.Count-ne$sorted.Count-or(Get-BlockedSuccessorHash $ids)-cne(Get-BlockedSuccessorHash $sorted)){throw 'Blocked-successor source repository IDs must be unique and ordinal sorted.'}
    $finalById=@{};foreach($row in @($Terminal.freeze.final_repositories)){$finalById[[string]$row.repo_id]=$row}
    $records=@();$leaves=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($id in $ids){if(-not$RepositoryMap.ContainsKey([string]$id)-or-not$finalById.ContainsKey([string]$id)){throw "Blocked-successor source repository '$id' is not jointly mapped and candidate-frozen."};$entry=$RepositoryMap[[string]$id];$root=[IO.Path]::GetFullPath([string]$entry.path);if(-not[IO.Directory]::Exists($root)){throw "Blocked-successor source repository '$id' is unavailable."};$dirty=@(& git -C $root status --porcelain=v1 --untracked-files=no);if($LASTEXITCODE-ne0-or$dirty.Count-ne0){throw "Blocked-successor source repository '$id' is not tracked-clean."};$commit=([string](& git -C $root rev-parse HEAD)).Trim().ToLowerInvariant();$tree=([string](& git -C $root rev-parse 'HEAD^{tree}')).Trim().ToLowerInvariant();if($commit-cne[string]$finalById[$id].commit-or$tree-cne[string]$finalById[$id].tree){throw "Blocked-successor source repository '$id' drifted from the terminal candidate freeze."};$leaf=Split-Path -Leaf $root;if(-not$leaves.Add($leaf)){throw 'Blocked-successor source composition repeats a materialization leaf.'};$branch=([string](& git -C $root rev-parse --abbrev-ref HEAD)).Trim();if($branch-ceq'HEAD'){$branch=$null};$records+=,[pscustomobject][ordered]@{repo_id=[string]$id;role=[string]$entry.role;commit=$commit;tree=$tree;branch=$branch;materialization_path=$leaf;tracked_worktree_clean=$true}}
    $fingerprint=Get-BlockedSuccessorHash ([pscustomobject][ordered]@{project_id=$Request.project_id;preparation_id=$Request.preparation_id;repositories=$records})
    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.development_envelope_source_composition.v1';lock_id="$($Request.preparation_id)-source-$($fingerprint.Substring(0,12))";preparation_id=$Request.preparation_id;project_id=$Request.project_id;fingerprint=$fingerprint;repositories=$records;status='locked';does_not_prove=@('Does not admit, Ready, claim, mutate source, build, use a device, accept, or publish a successor unit.')}
}
function Test-BlockedSuccessorCompletedPreparation {
    param([string]$Workspace,[object]$Receipt,[string]$ReceiptPath,[object]$Source,[string]$SourcePath)
    $receiptRelative="receipts/$([string]$Receipt.preparation_id).json";$sourceRelative=[string]$Receipt.source_composition.path;$transactionId="$([string]$Receipt.preparation_id)-prepared-transition"
    $intentRelative="receipts/transactions/$transactionId.intent.json";$completionRelative="receipts/transactions/$transactionId.completion.json"
    $intentPath=Resolve-MorphospaceWorkspacePath $Workspace $intentRelative -RequireLeaf;$completionPath=Resolve-MorphospaceWorkspacePath $Workspace $completionRelative -RequireLeaf
    $intent=Read-MorphospaceProtocolJson $intentPath
    &$script:BlockedSuccessorTransitionLedgerModule {param($candidate,$id)Assert-MorphospaceLedgerIntent $candidate $id} $intent $transactionId
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v5'-or[string]$intent.state.path-cne'workspace.state.json'-or[string]$intent.unit.path-cne[string]$Receipt.terminal.unit_path-or[string]$intent.events.path-cne'iteration-events.jsonl'){throw 'Blocked-successor completed preparation intent identity or paths are not exact.'}
    if([string]$intent.pre_unit_raw.path-cne[string]$Receipt.terminal.unit_path-or[string]$intent.pre_unit_raw.sha256-cne[string]$Receipt.terminal.unit_raw_sha256-or[string]$intent.pre.unit.sha256-cne[string]$Receipt.terminal.unit_canonical_sha256-or[string]$intent.target.unit.sha256-cne[string]$Receipt.terminal.unit_canonical_sha256-or(Get-BlockedSuccessorHash $intent.target.unit.document)-cne[string]$Receipt.terminal.unit_canonical_sha256){throw 'Blocked-successor completed preparation unit binding is not the exact immutable terminal.'}
    $eventId="$([string]$Receipt.preparation_id)-prepared";$historicalState=Copy-BlockedSuccessorValue $intent.target.state.document
    if([string]$historicalState.last_event_id-cne$eventId){throw 'Blocked-successor completed preparation target state does not own its event.'};$historicalState.last_event_id=[string]$intent.expected.event_tail_id
    if((Get-BlockedSuccessorHash $historicalState)-cne[string]$intent.pre.state.sha256-or[string]$intent.expected.state_sha256-cne[string]$intent.pre.state.sha256-or[string]$intent.target.state.sha256-cne(Get-BlockedSuccessorHash $intent.target.state.document)){throw 'Blocked-successor completed preparation target state changes more than its event tail.'}
    $expectedEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$intent.event.sequence;timestamp=[string]$intent.event.timestamp;project_id=$Receipt.project_id;unit_id=$Receipt.terminal.unit_id;event_type='decision';summary='Prepared one bounded successor to an immutable terminal blocked unit; admission remains separate.';receipts=@($receiptRelative,$sourceRelative)}
    if((Get-BlockedSuccessorHash $intent.event)-cne(Get-BlockedSuccessorHash $expectedEvent)){throw 'Blocked-successor completed preparation event is not exact.'}
    $artifacts=@($intent.artifacts);if($artifacts.Count-ne2-or[string]$artifacts[0].path-cne$receiptRelative-or[string]$artifacts[1].path-cne$sourceRelative){throw 'Blocked-successor completed preparation artifacts are not the exact ordered receipt and source lock.'}
    $receiptArtifact=ConvertFrom-BlockedSuccessorIntentArtifact $artifacts[0] 'completed preparation receipt';$sourceArtifact=ConvertFrom-BlockedSuccessorIntentArtifact $artifacts[1] 'completed source composition'
    if((Get-BlockedSuccessorHash $receiptArtifact.document)-cne(Get-BlockedSuccessorHash $Receipt)-or(Get-BlockedSuccessorHash $sourceArtifact.document)-cne(Get-BlockedSuccessorHash $Source)-or(Get-MorphospaceFileSha256 $ReceiptPath)-cne[string]$artifacts[0].sha256-or(Get-MorphospaceFileSha256 $SourcePath)-cne[string]$artifacts[1].sha256-or[string]$Receipt.source_composition.sha256-cne[string]$artifacts[1].sha256){throw 'Blocked-successor completed preparation embedded and live artifact bytes are not exact.'}
    $terminalBindingHash=Get-BlockedSuccessorHash ([pscustomobject][ordered]@{terminal=$Receipt.terminal;repair=$Receipt.repair})
    if([string]$Receipt.terminal_binding_sha256-cne$terminalBindingHash-or[string]$Receipt.input_sha256-cnotmatch'^[0-9a-f]{64}$'){throw 'Blocked-successor completed preparation receipt input or terminal binding is invalid.'}
    $completion=Read-MorphospaceProtocolJson $completionPath
    Assert-BlockedSuccessorExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') 'Blocked-successor completed preparation completion'
    Assert-BlockedSuccessorExactPropertySet $completion.intent @('role','path','schema','sha256') 'Blocked-successor completed preparation completion intent reference'
    if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or[string]$completion.transaction_id-cne$transactionId-or[string]$completion.status-cne'committed'-or[string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$intentRelative-or[string]$completion.intent.schema-cne[string]$intent.schema-or[string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $intentPath)-or[string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256-or[string]$completion.event_id-cne$eventId){throw 'Blocked-successor completed preparation completion is not canonically bound to its exact intent.'}
    $created=Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at);$completed=Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at);if($completed-lt$created){throw 'Blocked-successor completed preparation completion precedes its intent.'}
    &$script:BlockedSuccessorTransitionLedgerModule {param($workspaceRoot,$id,$candidate,$eventsPath)
        Assert-MorphospaceLedgerArtifactNamespace $workspaceRoot $id $candidate
        [void](Assert-MorphospaceLedgerEventPlacement $eventsPath $candidate -AllowHistorical -RequirePresent)
    } $Workspace $transactionId $intent (Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf)
    $request=[pscustomobject][ordered]@{project_id=$Receipt.project_id;terminal=$Receipt.terminal;repair=$Receipt.repair}
    $project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'project.spec.json' -RequireLeaf);$events=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    $terminalObservation=Get-BlockedSuccessorTerminalObservation $Workspace $request $project $historicalState $events -AllowHistoricalTerminal
    [pscustomobject]@{intent=$intent;completion=$completion;preparation_event=$intent.event;terminal_observation=$terminalObservation}
}
function Test-MorphospaceBlockedSuccessorPreparation {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Admission,[ValidateSet('Admission','Freeze','Release')][string]$Phase='Admission')
    $workspace=(Resolve-Path $WorkspaceRoot).Path;$p=$Admission.preparation
    $receiptPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$p.receipt_path) -RequireLeaf
    Assert-BlockedSuccessorSchema $receiptPath 'blocked-successor-preparation-receipt-v1.schema.json' 'Blocked-successor preparation receipt is invalid.'
    if((Get-MorphospaceFileSha256 $receiptPath)-cne[string]$p.receipt_sha256){throw 'Blocked-successor preparation receipt bytes drifted.'}
    $receipt=Read-MorphospaceProtocolJson $receiptPath
    $sourcePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$p.source_composition_path) -RequireLeaf
    Assert-BlockedSuccessorSchema $sourcePath 'development-envelope-source-composition-v1.schema.json' 'Blocked-successor source composition is invalid.'
    if((Get-MorphospaceFileSha256 $sourcePath)-cne[string]$p.source_composition_sha256-or[string]$receipt.source_composition.path-cne[string]$p.source_composition_path-or[string]$receipt.source_composition.sha256-cne[string]$p.source_composition_sha256){throw 'Blocked-successor source-composition bytes drifted.'}
    if([string]$receipt.preparation_id-cne[string]$p.preparation_id-or[string]$receipt.successor_unit_id-cne[string]$Admission.unit_id-or[string]$receipt.project_id-cne[string]$Admission.project_id-or[string]$receipt.terminal.unit_id-cne[string]$Admission.blocked_successor.terminal_unit_id-or[string]$receipt.terminal_binding_sha256-cne[string]$Admission.blocked_successor.terminal_binding_sha256-or[string]$receipt.terminal_binding_sha256-cne[string]$p.terminal_binding_sha256){throw 'Blocked-successor admission does not bind the exact preparation.'}
    if(@($Admission.unit.prerequisites)-contains[string]$receipt.terminal.unit_id){throw 'Blocked predecessor may not be smuggled into the ordinary accepted-prerequisite list.'}
    $allowed=@($Admission.unit.allowed_repositories);if($allowed.Count-ne1-or[string]$allowed[0].repo_id-cne[string]$receipt.repair.repo_id-or@($allowed[0].allowed_paths).Count-ne1-or[string]$allowed[0].allowed_paths[0]-cne[string]$receipt.repair.path){throw 'Blocked-successor admission must be the exact one-path repair slice.'}
    $source=Read-MorphospaceProtocolJson $sourcePath;$verified=Test-BlockedSuccessorCompletedPreparation $workspace $receipt $receiptPath $source $sourcePath
    return [pscustomobject]@{kind='blocked-successor';receipt=$receipt;source_lock=$source;preparation_event=$verified.preparation_event;terminal_observation=$verified.terminal_observation;phase=$Phase}
}
function Invoke-MorphospacePrepareBlockedSuccessor {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$BlockedSuccessorPreparation,[string]$OutPath,[string]$ExpectedBlockedSuccessorPreparationSha256='',[string]$Timestamp='',[switch]$Execute,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none')
    $workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $BlockedSuccessorPreparation).Path
    Assert-BlockedSuccessorSchema $input 'blocked-successor-preparation-v1.schema.json' 'Blocked-successor preparation does not satisfy its schema.'
    $request=Read-MorphospaceProtocolJson $input;$inputHash=Get-MorphospaceFileSha256 $input
    if($Execute-and-not$ExpectedBlockedSuccessorPreparationSha256){throw 'Executed blocked-successor preparation requires the dry-run input SHA-256.'};if($ExpectedBlockedSuccessorPreparationSha256-and$ExpectedBlockedSuccessorPreparationSha256-cne$inputHash){throw 'Expected blocked-successor preparation SHA-256 does not match input.'}
    if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};if(-not(Test-MorphospaceStrictUtcTimestamp $Timestamp)){throw 'Blocked-successor preparation timestamp must be strict UTC.'}
    $receiptRelative="receipts/$([string]$request.preparation_id).json";$sourceRelative="source-composition/$([string]$request.preparation_id).json";$expectedOut=Resolve-MorphospaceWorkspacePath $workspace $receiptRelative
    if(-not$OutPath-or[IO.Path]::GetFullPath($OutPath)-cne$expectedOut){throw "Blocked-successor output must be '$receiptRelative'."}
    $eventId="$([string]$request.preparation_id)-prepared";$transactionId="$([string]$request.preparation_id)-prepared-transition"
    $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.intent.json";$completionPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.completion.json"
    $eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf;$events=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String});if($events.Count-eq0){throw 'Blocked-successor preparation requires a terminal event.'}
    $matchingEvents=@($events|Where-Object{[string]$_.event_id-ceq$eventId})
    if([IO.File]::Exists($intentPath)){
        $completed=[IO.File]::Exists($completionPath)
        $recovery=Get-BlockedSuccessorRecoveryBinding $workspace $request $inputHash $receiptRelative $sourceRelative $transactionId $intentPath $completed
        if($completed){[void](Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$request.terminal.unit_path) -ExpectedEventsPath 'iteration-events.jsonl')}
        elseif($Execute){
            [void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -Repair -FaultAfter $FaultAfter)
            [void](Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$request.terminal.unit_path) -ExpectedEventsPath 'iteration-events.jsonl')
        }
        return New-BlockedSuccessorAutomationResult $request ([string]$recovery.intent.event.timestamp) ($completed-or$Execute.IsPresent) $receiptRelative $inputHash
    }
    if([IO.File]::Exists($completionPath)-or$matchingEvents.Count-or[IO.File]::Exists($expectedOut)-or[IO.File]::Exists((Resolve-MorphospaceWorkspacePath $workspace $sourceRelative))){throw 'Blocked-successor preparation found orphaned transaction evidence without its exact intent.'}
    $projectPath=Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf;$statePath=Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf;$lockPath=Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf;$eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf;$mapPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$request.expected.repository_map_path) -RequireLeaf
    $project=Read-MorphospaceProtocolJson $projectPath;$state=Read-MorphospaceProtocolJson $statePath;$featureLock=Read-MorphospaceProtocolJson $lockPath;$mapDoc=Read-MorphospaceProtocolJson $mapPath
    if([string]$project.project_id-cne[string]$request.project_id-or[string]$state.project_id-cne[string]$request.project_id){throw 'Blocked-successor project identity is not exact.'};if($null-ne$state.current_unit-or$null-ne$state.next_ready_unit){throw 'Blocked-successor preparation requires an idle project.'};if([IO.File]::Exists((Resolve-MorphospaceWorkspacePath $workspace "iteration-units/$([string]$request.successor_unit_id).json"))){throw 'Blocked-successor unit identity already exists.'}
    foreach($check in @(@{e=$request.expected.project_sha256;a=Get-BlockedSuccessorHash $project;n='project'},@{e=$request.expected.state_sha256;a=Get-BlockedSuccessorHash $state;n='state'},@{e=$request.expected.feature_lock_sha256;a=Get-BlockedSuccessorHash $featureLock;n='feature lock'},@{e=$request.expected.repository_map_sha256;a=Get-MorphospaceFileSha256 $mapPath;n='repository map'},@{e=$request.expected.events_sha256;a=Get-MorphospaceFileSha256 $eventsPath;n='event ledger'})){if([string]$check.e-cne[string]$check.a){throw "Blocked-successor stale $($check.n) preimage."}}
    if([int64]$request.expected.events_length-ne([IO.FileInfo]$eventsPath).Length-or[string]$request.expected.event_tail_id-cne[string]$events[-1].event_id){throw 'Blocked-successor event ledger length or tail is stale.'}
    $terminal=Get-BlockedSuccessorTerminalObservation $workspace $request $project $state $events
    $map=Get-BlockedSuccessorRepositoryMap $mapDoc;$source=Get-BlockedSuccessorSourceComposition $request $terminal $map
    if(-not(Test-Json -Json ($source|ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\development-envelope-source-composition-v1.schema.json'))){throw 'Blocked-successor generated source composition is invalid.'}
    $terminalBinding=[pscustomobject][ordered]@{terminal=$request.terminal;repair=$request.repair};$terminalBindingHash=Get-BlockedSuccessorHash $terminalBinding
    $receipt=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.blocked_successor_preparation_receipt.v1';preparation_id=$request.preparation_id;project_id=$request.project_id;successor_unit_id=$request.successor_unit_id;input_sha256=$inputHash;terminal=$request.terminal;repair=$request.repair;source_composition=[pscustomobject][ordered]@{path=$sourceRelative;sha256=''};terminal_binding_sha256=$terminalBindingHash;does_not_prove=@('Does not admit, Ready, claim, mutate source, build, use a device, accept, or publish the successor.')}
    $sourceBytes=Get-BlockedSuccessorBytes $source;$sourceRawHash=Get-BlockedSuccessorByteHash $sourceBytes;$receipt.source_composition.sha256=$sourceRawHash;$receiptBytes=Get-BlockedSuccessorBytes $receipt;$receiptRawHash=Get-BlockedSuccessorByteHash $receiptBytes
    $targetState=Copy-BlockedSuccessorValue $state;$targetState.last_event_id=$eventId
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$events[-1].sequence+1;timestamp=$Timestamp;project_id=$request.project_id;unit_id=$request.terminal.unit_id;event_type='decision';summary='Prepared one bounded successor to an immutable terminal blocked unit; admission remains separate.';receipts=@($receiptRelative,$sourceRelative)}
    if($Execute){Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -StatePath 'workspace.state.json' -UnitPath ([string]$request.terminal.unit_path) -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $terminal.unit -Event $event -ExpectedPreStateSha256 ([string]$request.expected.state_sha256) -ExpectedPreUnitSha256 ([string]$request.terminal.unit_canonical_sha256) -ExpectedPreUnitRawSha256 ([string]$request.terminal.unit_raw_sha256) -ExpectedEventTailId ([string]$request.expected.event_tail_id) -ExpectedEventsSha256 ([string]$request.expected.events_sha256) -ExpectedEventsLength ([int64]$request.expected.events_length) -Artifacts @([pscustomobject]@{path=$receiptRelative;sha256=$receiptRawHash;bytes_base64=[Convert]::ToBase64String($receiptBytes)},[pscustomobject]@{path=$sourceRelative;sha256=$sourceRawHash;bytes_base64=[Convert]::ToBase64String($sourceBytes)}) -FaultAfter $FaultAfter|Out-Null}
    New-BlockedSuccessorAutomationResult $request $Timestamp $Execute.IsPresent $receiptRelative $inputHash
}
Export-ModuleMember -Function Invoke-MorphospacePrepareBlockedSuccessor,Test-MorphospaceBlockedSuccessorPreparation
