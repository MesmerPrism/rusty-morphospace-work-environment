Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkCompatibility.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')

function Copy-PreparationRecoveryValue([object]$Value) { $Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String }
function Get-PreparationRecoveryHash([object]$Value) { Get-MorphospaceCanonicalJsonSha256 $Value }
function Get-PreparationRecoveryPath([string]$Root,[string]$Path) { Resolve-MorphospaceWorkspacePath $Root $Path }
function Get-PreparationRecoveryBinding([string]$Root,[string]$Path,[switch]$Snapshot) {
    $full=Get-PreparationRecoveryPath $Root $Path
    $value=Read-MorphospaceProtocolJson $full
    $binding=[ordered]@{path=$Path;raw_sha256=(Get-MorphospaceFileSha256 $full);canonical_sha256=(Get-PreparationRecoveryHash $value)}
    if($Snapshot){$binding.document=$value}
    [pscustomobject]$binding
}
function Read-PreparationRecoveryLedger([string]$Root,[long]$Length=-1) {
    $bytes=[IO.File]::ReadAllBytes((Get-PreparationRecoveryPath $Root 'iteration-events.jsonl'))
    if($bytes.Length-gt67108864-or($Length-ge0-and$Length-gt$bytes.Length)){throw 'Preparation recovery ledger is outside its bounded byte prefix.'}
    if($Length-ge0){$prefix=[byte[]]::new([int]$Length);[Array]::Copy($bytes,$prefix,[int]$Length);$bytes=$prefix}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    if(-not$text.EndsWith("`n")-or$text.Contains([char]0)-or$text.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)){throw 'Preparation recovery ledger must be complete strict UTF-8 records.'}
    $events=@();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$previous=$null
    foreach($line in $text.TrimEnd("`n").Split("`n")){
        if(-not$line.Trim()){throw 'Preparation recovery ledger has a blank record.'}
        $event=ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes($line)) 'preparation recovery ledger'
        # Retained preaccepted events use the event schema's date-time form;
        # exact current intent/completion timestamps are checked by their owners.
        $at=ConvertFrom-MorphospaceInvariantTimestamp ([string]$event.timestamp)
        if(-not$seen.Add([string]$event.event_id)-or[int]$event.sequence-ne$events.Count+1-or($null-ne$previous-and$at-lt$previous)){throw 'Preparation recovery ledger identity, sequence, or chronology is ambiguous.'}
        $events+=,$event;$previous=$at
    }
    [pscustomobject]@{bytes=$bytes;events=$events;raw_sha256=(Get-MorphospaceSha256Bytes $bytes);length=$bytes.Length;tail_event_id=[string]$events[-1].event_id}
}
function Get-PreparationRecoveryContext([string]$Workspace,[string]$PreparationId,[object]$Ledger,[switch]$PendingCorrection) {
    if($PreparationId-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){throw 'Preparation recovery identity is not canonical.'}
    $prepared=@($Ledger.events|Where-Object{[string]$_.event_id-ceq"$PreparationId-prepared"})
    if($prepared.Count-ne1-or$Ledger.events.Count-ne[int]$prepared[0].sequence+3){throw 'Preparation recovery requires exactly Admission, Ready, Claim after the preparation.'}
    $event=$prepared[0];$sequence=[int]$event.sequence;$suffix=@($Ledger.events|Where-Object{[int]$_.sequence-gt$sequence})
    $unitId=[string]$suffix[0].unit_id;$unitPath="iteration-units/$unitId.json"
    $intentPath="receipts/transactions/$PreparationId-prepared-transition.intent.json";$completionPath="receipts/transactions/$PreparationId-prepared-transition.completion.json"
    $intent=Read-MorphospaceProtocolJson (Get-PreparationRecoveryPath $Workspace $intentPath)
    if($null-eq(Get-Command Get-MorphospacePreparationStepEvidence -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkHistory.psm1')}
    $proof=Get-MorphospacePreparationStepEvidence -Workspace $Workspace -IntentPath (Get-PreparationRecoveryPath $Workspace $intentPath) -Intent $intent -Events $Ledger.events -ExpectedEvent $event
    if([string]$proof.chronology_fault-cne'preparation-completion-precedes-intent'){throw 'Preparation recovery requires exactly the evidenced completion chronology defect.'}
    $receiptPath="receipts/$PreparationId.json";$receipt=Read-MorphospaceProtocolJson (Get-PreparationRecoveryPath $Workspace $receiptPath)
    $paths=@($intentPath,$completionPath,$receiptPath,[string]$receipt.source_composition.path,[string]$intent.pre.repository_map.path,[string]$intent.pre.predecessor_unit.path)
    $accepted=@($Ledger.events|Where-Object{[string]$_.unit_id-ceq[string]$event.unit_id-and[int]$_.sequence-lt$sequence-and@($_.receipts)-ccontains[string]$intent.pre.state.document.last_accepted_receipt-and[string]$_.event_id-cmatch'-accepted-[0-9]{4,}$'})
    if($accepted.Count-ne1){throw 'Preparation recovery lacks one exact accepted predecessor.'}
    $acceptedProof=Test-MorphospaceAcceptedCheckpointProof -WorkspaceRoot $Workspace -ExpectedEvent $accepted[0] -AllowFiniteHistoricalV1
    if([string]$acceptedProof.intent.target.unit.sha256-cne[string]$intent.pre.predecessor_unit.sha256){throw 'Preparation recovery predecessor differs from its accepted checkpoint.'}
    $priorStateHash=[string]$acceptedProof.intent.target.state.sha256;$projectionHashes=@{}
    foreach($prefixEvent in @($Ledger.events|Where-Object{[int]$_.sequence-gt[int]$accepted[0].sequence-and[int]$_.sequence-lt$sequence})){
        $prefixId="$($prefixEvent.event_id)-transition";$prefixIntentPath="receipts/transactions/$prefixId.intent.json";$prefixCompletionPath="receipts/transactions/$prefixId.completion.json"
        $prefixIntent=Read-MorphospaceProtocolJson (Get-PreparationRecoveryPath $Workspace $prefixIntentPath)
        $paths+=@($prefixIntentPath,$prefixCompletionPath)
        if([string]$prefixIntent.schema-ceq'rusty.morphospace.workflow.development_envelope_preparation_intent.v1'){
            $prefixProof=Get-MorphospacePreparationStepEvidence -Workspace $Workspace -IntentPath (Get-PreparationRecoveryPath $Workspace $prefixIntentPath) -Intent $prefixIntent -Events $Ledger.events -ExpectedEvent $prefixEvent
            if($null-ne$prefixProof.chronology_fault){throw 'Preparation recovery accepted prefix contains another malformed preparation.'}
            foreach($name in @('project','feature_lock')){
                $path=[string]$prefixIntent.target.$name.path
                if($projectionHashes.ContainsKey($path)-and[string]$prefixIntent.pre.$name.sha256-cne$projectionHashes[$path]){throw 'Preparation recovery prefix authority projection is detached.'}
                $projectionHashes[$path]=[string]$prefixIntent.target.$name.sha256
            }
        }else{
            $prefixProof=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $prefixId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$($prefixEvent.unit_id).json" -ExpectedEventsPath 'iteration-events.jsonl'
            $prefixIntent=$prefixProof.intent
            if([string]$prefixEvent.event_id-cmatch('-proposal-retired-[0-9]{4}$')){[void](Test-MorphospaceHistoricalProposedRetirement -WorkspaceRoot $Workspace -ExpectedEvent $prefixEvent -CommittedStep $prefixProof)}
            if([string]$prefixEvent.event_id-cmatch'-active-retired$'){Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1');[void](Test-MorphospaceHistoricalActiveUnitRetirement -WorkspaceRoot $Workspace -ExpectedEvent $prefixEvent)}
            if($prefixIntent.PSObject.Properties.Name-contains'additional_projections'){
                foreach($projection in $prefixIntent.additional_projections){
                    $path=[string]$projection.path
                    if($projectionHashes.ContainsKey($path)-and[string]$projection.pre_sha256-cne$projectionHashes[$path]){throw 'Preparation recovery prefix additional projection is detached.'}
                    $projectionHashes[$path]=[string]$projection.target_sha256
                }
            }
        }
        if((Get-PreparationRecoveryHash $prefixIntent.event)-cne(Get-PreparationRecoveryHash $prefixEvent)-or[string]$prefixIntent.pre.state.sha256-cne$priorStateHash){throw 'Preparation recovery accepted-to-preparation state chain is detached.'}
        $priorStateHash=[string]$prefixIntent.target.state.sha256
        $paths+=@($prefixIntent.artifacts|ForEach-Object{[string]$_.path})
    }
    if([string]$intent.pre.state.sha256-cne$priorStateHash){throw 'Preparation recovery accepted-to-preparation state chain is detached.'}
    foreach($name in @('project','feature_lock')){$path=[string]$intent.pre.$name.path;if($projectionHashes.ContainsKey($path)-and[string]$intent.pre.$name.sha256-cne$projectionHashes[$path]){throw 'Preparation recovery original authority preimage is detached.'}}
    $previousState=$intent.target.state.document;$previousUnit=$null;$steps=@()
    for($index=0;$index-lt3;$index++){
        $row=$suffix[$index];$slug=@('admitted','ready','claimed')[$index]
        $pattern=if($index-eq0){'^.+-admitted$'}else{'^'+[regex]::Escape($unitId)+'-'+$slug+'-[0-9]{4,}$'}
        if([string]$row.event_id-cnotmatch$pattern-or[string]$row.unit_id-cne$unitId-or[string]$row.project_id-cne[string]$event.project_id-or[string]$row.event_type-cne'state-transition'){throw 'Preparation recovery successor event is not the exact ordinary lifecycle.'}
        $expectedSummary=@('Admitted a bounded proposed development unit; normal Ready, Inspect, and Claim remain required.','Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites.','Claimed one ready iteration unit without expanding repository or path scope.')[$index]
        if([string]$row.summary-cne$expectedSummary){throw 'Preparation recovery requires the exact ordinary successor semantics.'}
        $transactionId="$([string]$row.event_id)-transition"
        # An interrupted correction can already own the state projection while
        # Claim remains the ledger tail. Its exact persisted request and intent
        # bind these previously authenticated bytes before repair can resume;
        # fresh and completed proofs always use the full committed reader.
        if($PendingCorrection-and$index-eq2){
            $step=[pscustomobject]@{intent=(Read-MorphospaceProtocolJson (Get-PreparationRecoveryPath $Workspace "receipts/transactions/$transactionId.intent.json"));completion=(Read-MorphospaceProtocolJson (Get-PreparationRecoveryPath $Workspace "receipts/transactions/$transactionId.completion.json"))}
        }else{
            $step=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $transactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $unitPath -ExpectedEventsPath 'iteration-events.jsonl'
        }
        $i=$step.intent;$steps+=,$step;$paths+="receipts/transactions/$transactionId.intent.json";$paths+="receipts/transactions/$transactionId.completion.json"
        if((Get-PreparationRecoveryHash $i.event)-cne(Get-PreparationRecoveryHash $row)-or[string]$i.pre.state.sha256-cne(Get-PreparationRecoveryHash $previousState)){throw 'Preparation recovery successor state chain is detached.'}
        $target=Copy-PreparationRecoveryValue $previousState;$target.last_event_id=[string]$row.event_id
        if($index-eq0){
            if(@($row.receipts).Count-ne1-or[string]$i.pre.unit.sha256-cne('0'*64)-or[string]$i.target.unit.document.status-cne'proposed'-or@($i.artifacts).Count-ne1){throw 'Preparation recovery admission is not a fresh ordinary proposed-unit admission.'}
            $admissionPath=[string]$row.receipts[0];$paths+=$admissionPath;$admission=Read-MorphospaceProtocolJson (Get-PreparationRecoveryPath $Workspace $admissionPath)
            $admissionSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas/development-unit-admission-v1.schema.json'
            if(-not(Test-Json -Json ($admission|ConvertTo-Json -Depth 100) -SchemaFile $admissionSchema)-or[string]$admission.preparation.preparation_id-cne$PreparationId-or[string]$admission.preparation.receipt_path-cne$receiptPath-or[string]$admission.preparation.receipt_sha256-cne(Get-MorphospaceFileSha256 (Get-PreparationRecoveryPath $Workspace $receiptPath))-or(Get-PreparationRecoveryHash $admission.unit)-cne(Get-PreparationRecoveryHash $i.target.unit.document)-or[string]$admission.expected.state_sha256-cne[string]$i.pre.state.sha256-or[string]$admission.expected.event_tail_id-cne[string]$event.event_id){throw 'Preparation recovery admission does not bind its original preparation and unit.'}
            if(($admission.PSObject.Properties.Name-contains'admission_kind'-and[string]$admission.admission_kind-cne'ordinary')-or($admission.preparation.PSObject.Properties.Name-contains'preparation_kind'-and[string]$admission.preparation.preparation_kind-cne'ordinary')){throw 'Preparation recovery supports only ordinary preparation and admission.'}
            $sourcePath=[string]$receipt.source_composition.path;$sourceHash=Get-MorphospaceFileSha256 (Get-PreparationRecoveryPath $Workspace $sourcePath)
            if([string]$admission.preparation.source_composition_path-cne$sourcePath-or[string]$admission.preparation.source_composition_sha256-cne$sourceHash-or[string]$admission.expected.source_composition_path-cne$sourcePath-or[string]$admission.expected.source_composition_sha256-cne$sourceHash-or[string]$admission.expected.project_sha256-cne[string]$intent.target.project.sha256-or[string]$admission.expected.feature_lock_sha256-cne[string]$intent.target.feature_lock.sha256-or[string]$admission.expected.repository_map_path-cne[string]$intent.target.repository_map.path-or[string]$admission.expected.repository_map_sha256-cne[string]$intent.target.repository_map.sha256-or[string]$admission.expected.events_sha256-cne[string]$i.expected.events_sha256-or[long]$admission.expected.events_length-ne[long]$i.expected.events_length-or[string]$row.event_id-cne"$($admission.admission_id)-admitted"){throw 'Preparation recovery admission source, project, map, or ledger bindings are detached.'}
            if([string]$i.artifacts[0].path-cne$admissionPath-or[string]$i.artifacts[0].sha256-cne(Get-MorphospaceFileSha256 (Get-PreparationRecoveryPath $Workspace $admissionPath))){throw 'Preparation recovery admission artifact is detached.'}
        }else{
            if(@($row.receipts).Count-ne0-or@($i.artifacts).Count-ne0-or[string]$i.pre.unit.sha256-cne(Get-PreparationRecoveryHash $previousUnit)){throw 'Preparation recovery Ready/Claim must have no adoption or other artifacts.'}
            $derivedUnit=Copy-PreparationRecoveryValue $previousUnit;$derivedUnit.status=if($index-eq1){'ready'}else{'active'}
            if((Get-PreparationRecoveryHash $derivedUnit)-cne(Get-PreparationRecoveryHash $i.target.unit.document)){throw 'Preparation recovery Ready/Claim changed the unit beyond status.'}
            $target.next_ready_unit=if($index-eq1){$unitId}else{$null};if($index-eq2){$target.current_unit=$unitId}
            # Ordinary Ready/Claim may update observed repository heads/dirt.
            # Keep their committed observations; never query current Git HEADs.
            foreach($field in @('repository_heads','dirty_repositories')){if($target.PSObject.Properties.Name-contains$field){$target.$field=$i.target.state.document.$field}}
        }
        if((Get-PreparationRecoveryHash $target)-cne(Get-PreparationRecoveryHash $i.target.state.document)){throw 'Preparation recovery successor changes an unsupported state field.'}
        $previousState=$i.target.state.document;$previousUnit=$i.target.unit.document
    }
    if([string]$previousState.current_unit-cne$unitId-or$null-ne$previousState.next_ready_unit-or$null-ne$previousState.pending_push_bundle-or@($previousState.blockers).Count-ne0){throw 'Preparation recovery requires unblocked active ownership without pending publication.'}
    $orderedPaths=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal);foreach($path in $paths){[void]$orderedPaths.Add([string]$path)}
    [pscustomobject]@{original_intent=$intent;malformed_completion=$proof.completion;original_intent_raw_sha256=$proof.intent_raw_sha256;original_completion_raw_sha256=$proof.completion_raw_sha256;preparation_event=$event;unit_id=$unitId;state=$previousState;unit=$previousUnit;paths=@($orderedPaths);steps=$steps}
}
function New-MorphospacePreparationCompletionTimestampRecovery {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$PreparationId)
    $ledger=Read-PreparationRecoveryLedger $WorkspaceRoot;$context=Get-PreparationRecoveryContext $WorkspaceRoot $PreparationId $ledger
    $snapshots=[ordered]@{};foreach($pair in @(@('state','workspace.state.json'),@('unit',"iteration-units/$($context.unit_id).json"),@('project','project.spec.json'),@('feature_lock','feature.lock.json'))){$snapshots[$pair[0]]=Get-PreparationRecoveryBinding $WorkspaceRoot $pair[1] -Snapshot}
    $now=[DateTimeOffset]::UtcNow;$intentAt=Test-MorphospaceStrictUtcTimestamp ([string]$context.original_intent.created_at);$tailAt=Test-MorphospaceStrictUtcTimestamp ([string]$ledger.events[-1].timestamp)
    if($now-lt$intentAt-or$now-lt$tailAt){throw 'Preparation recovery must be observed at or after its immutable event chronology.'}
    $receipt=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.preparation_completion_timestamp_recovery.v1';recovery_id=('preparation-completion-timestamp-recovered-{0:d4}'-f($ledger.events.Count+1));project_id=[string]$context.state.project_id;unit_id=$context.unit_id;preparation_id=$PreparationId;prepared_sequence=[int]$context.preparation_event.sequence;fault_kind='preparation-completion-precedes-intent';chronology=[pscustomobject]@{intent_created_at=[string]$context.original_intent.created_at;malformed_completed_at=[string]$context.malformed_completion.completed_at;recovery_timestamp=$now.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};evidence=@($context.paths|ForEach-Object{Get-PreparationRecoveryBinding $WorkspaceRoot $_});snapshots=[pscustomobject]$snapshots;ledger=[pscustomobject]@{raw_sha256=$ledger.raw_sha256;length=$ledger.length;tail_event_id=$ledger.tail_event_id}}
    [void](Assert-PreparationRecoveryReceipt $WorkspaceRoot $receipt -Mode PreApply)
    $receipt
}
function Assert-PreparationRecoveryReceipt {
    param([string]$Workspace,[object]$Receipt,[ValidateSet('PreApply','Pending','Historical')][string]$Mode)
    $schema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas/preparation-completion-timestamp-recovery-v1.schema.json'
    if(-not(Test-Json -Json ($Receipt|ConvertTo-Json -Depth 100) -SchemaFile $schema)){throw 'Preparation completion recovery does not satisfy its closed schema.'}
    $ledger=Read-PreparationRecoveryLedger $Workspace ([long]$Receipt.ledger.length)
    if([string]$Receipt.ledger.raw_sha256-cne$ledger.raw_sha256-or[string]$Receipt.ledger.tail_event_id-cne$ledger.tail_event_id){throw 'Preparation recovery ledger preimage changed.'}
    $context=Get-PreparationRecoveryContext $Workspace ([string]$Receipt.preparation_id) $ledger -PendingCorrection:($Mode-eq'Pending')
    if([string]$Receipt.unit_id-cne$context.unit_id-or[string]$Receipt.project_id-cne[string]$context.state.project_id-or[int]$Receipt.prepared_sequence-ne[int]$context.preparation_event.sequence-or[string]$Receipt.recovery_id-cne('preparation-completion-timestamp-recovered-{0:d4}'-f($ledger.events.Count+1))){throw 'Preparation recovery identity or placement is detached.'}
    $evidence=@($context.paths|ForEach-Object{Get-PreparationRecoveryBinding $Workspace $_})
    if((Get-PreparationRecoveryHash $evidence)-cne(Get-PreparationRecoveryHash @($Receipt.evidence))){throw 'Preparation recovery immutable evidence bytes or paths changed.'}
    $at=Test-MorphospaceStrictUtcTimestamp ([string]$Receipt.chronology.recovery_timestamp)
    if([string]$Receipt.chronology.intent_created_at-cne[string]$context.original_intent.created_at-or[string]$Receipt.chronology.malformed_completed_at-cne[string]$context.malformed_completion.completed_at-or$at-lt(Test-MorphospaceStrictUtcTimestamp ([string]$ledger.events[-1].timestamp))-or$at-gt[DateTimeOffset]::UtcNow){throw 'Preparation recovery chronology is not an exact observed correction.'}
    $expectedDocuments=@{state=$context.state;unit=$context.unit;project=$context.original_intent.target.project.document;feature_lock=$context.original_intent.target.feature_lock.document}
    foreach($name in @('state','unit','project','feature_lock')){
        $binding=$Receipt.snapshots.$name;$expectedPath=switch($name){state{'workspace.state.json'}unit{"iteration-units/$($context.unit_id).json"}project{'project.spec.json'}feature_lock{'feature.lock.json'}}
        if([string]$binding.path-cne$expectedPath-or[string]$binding.canonical_sha256-cne(Get-PreparationRecoveryHash $binding.document)-or[string]$binding.canonical_sha256-cne(Get-PreparationRecoveryHash $expectedDocuments[$name])){throw "Preparation recovery $name snapshot is not the exact historical projection."}
        if($Mode-eq'PreApply'-or($Mode-eq'Pending'-and$name-ne'state')){if((Get-PreparationRecoveryHash (Get-PreparationRecoveryBinding $Workspace $expectedPath -Snapshot))-cne(Get-PreparationRecoveryHash $binding)){throw "Preparation recovery live $name preimage changed."}}
    }
    $target=Copy-PreparationRecoveryValue $context.state;$target.last_event_id=[string]$Receipt.recovery_id
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=[string]$Receipt.recovery_id;sequence=$ledger.events.Count+1;timestamp=[string]$Receipt.chronology.recovery_timestamp;project_id=[string]$Receipt.project_id;unit_id=[string]$Receipt.unit_id;event_type='state-transition';summary='Recorded exact preparation completion chronology recovery; retained original evidence and active ownership.';receipts=@("receipts/$($Receipt.recovery_id).json")}
    $all=Read-PreparationRecoveryLedger $Workspace;$hasCorrection=$all.events.Count-gt$ledger.events.Count
    if($Mode-eq'PreApply'-and$hasCorrection){throw 'Preparation recovery requires its exact current tail.'}
    if($Mode-eq'Pending'){
        $live=Get-PreparationRecoveryBinding $Workspace 'workspace.state.json' -Snapshot
        if(@((Get-PreparationRecoveryHash $context.state),(Get-PreparationRecoveryHash $target))-cnotcontains$live.canonical_sha256-or($live.canonical_sha256-ceq(Get-PreparationRecoveryHash $context.state)-and$live.raw_sha256-cne[string]$Receipt.snapshots.state.raw_sha256)){throw 'Preparation recovery pending state preimage changed.'}
        if($all.events.Count-gt$ledger.events.Count+1){throw 'Preparation recovery pending ledger has a foreign suffix.'}
    }
    if($hasCorrection-and(Get-PreparationRecoveryHash $all.events[$ledger.events.Count])-cne(Get-PreparationRecoveryHash $event)){throw 'Preparation recovery correction event differs from the derived exact append.'}
    if($Mode-eq'Historical'-and-not$hasCorrection){throw 'Preparation recovery correction event is missing.'}
    $context|Add-Member target_state $target;$context|Add-Member correction_event $event;$context|Add-Member receipt $Receipt
    $context
}
function Test-MorphospacePreparationCompletionTimestampRecovery {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RecoveryPath,[ValidateSet('PreApply','Pending','Historical')][string]$Mode='Historical',[object]$ExpectedEvent)
    $receiptBytes=[IO.File]::ReadAllBytes($RecoveryPath);$receipt=ConvertFrom-MorphospaceProtocolJsonBytes $receiptBytes $RecoveryPath;$context=Assert-PreparationRecoveryReceipt $WorkspaceRoot $receipt -Mode $Mode;$context|Add-Member receipt_raw_sha256 (Get-MorphospaceSha256Bytes $receiptBytes)
    if($null-ne$ExpectedEvent-and(Get-PreparationRecoveryHash $ExpectedEvent)-cne(Get-PreparationRecoveryHash $context.correction_event)){throw 'Preparation recovery event lookup is detached.'}
    if($Mode-eq'Historical'){
        $canonical=Get-PreparationRecoveryPath $WorkspaceRoot "receipts/$($receipt.recovery_id).json"
        if([IO.Path]::GetFullPath($RecoveryPath)-cne$canonical){throw 'Preparation recovery receipt is not at its canonical installed path.'}
        $step=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId "$($receipt.recovery_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$receipt.snapshots.unit.path) -ExpectedEventsPath 'iteration-events.jsonl'
        Assert-PreparationRecoveryIntent $step.intent $context ([string]$context.receipt_raw_sha256)
        $context|Add-Member intent $step.intent;$context|Add-Member completion $step.completion
    }
    $context
}
function Assert-PreparationRecoveryIntent([object]$Intent,[object]$Context,[string]$ReceiptHash) {
    $receipt=$Context.receipt
    if([string]$Context.receipt_raw_sha256-cne$ReceiptHash){throw 'Preparation recovery reloaded input differs from its inspected raw hash.'}
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v6'-or(Get-PreparationRecoveryHash $Intent.event)-cne(Get-PreparationRecoveryHash $Context.correction_event)-or[string]$Intent.pre.state.sha256-cne[string]$receipt.snapshots.state.canonical_sha256-or[string]$Intent.pre_state_raw.sha256-cne[string]$receipt.snapshots.state.raw_sha256-or[string]$Intent.pre.unit.sha256-cne[string]$receipt.snapshots.unit.canonical_sha256-or[string]$Intent.pre_unit_raw.sha256-cne[string]$receipt.snapshots.unit.raw_sha256-or(Get-PreparationRecoveryHash $Intent.target.state.document)-cne(Get-PreparationRecoveryHash $Context.target_state)-or(Get-PreparationRecoveryHash $Intent.target.unit.document)-cne(Get-PreparationRecoveryHash $Context.unit)-or[string]$Intent.expected.events_sha256-cne[string]$receipt.ledger.raw_sha256-or[long]$Intent.expected.events_length-ne[long]$receipt.ledger.length-or[string]$Intent.expected.event_tail_id-cne[string]$receipt.ledger.tail_event_id){throw 'Preparation recovery transaction does not bind exact raw/canonical preimages and derived targets.'}
    if(@($Intent.artifacts).Count-ne1-or[string]$Intent.artifacts[0].path-cne"receipts/$($receipt.recovery_id).json"-or[string]$Intent.artifacts[0].sha256-cne$ReceiptHash){throw 'Preparation recovery transaction receipt artifact is detached.'}
    $projections=@($Intent.additional_projections)
    if($projections.Count-ne2){throw 'Preparation recovery must preserve its two exact project/lock projections.'}
    for($index=0;$index-lt2;$index++){$name=@('feature_lock','project')[$index];$binding=$receipt.snapshots.$name;$p=$projections[$index];if([string]$p.path-cne[string]$binding.path-or[string]$p.pre_raw_sha256-cne[string]$binding.raw_sha256-or[string]$p.pre_sha256-cne[string]$binding.canonical_sha256-or[string]$p.target_sha256-cne[string]$binding.canonical_sha256-or(Get-PreparationRecoveryHash $p.document)-cne[string]$binding.canonical_sha256){throw 'Preparation recovery project/lock preservation is detached.'}}
}
function Get-MorphospacePreparationCompletionTimestampRecoveryIndex {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object[]]$ExpectedEvents)
    $ledger=Read-PreparationRecoveryLedger $WorkspaceRoot
    if((Get-PreparationRecoveryHash @($ExpectedEvents))-cne(Get-PreparationRecoveryHash @($ledger.events))){throw 'Preparation recovery index event snapshot changed.'}
    $byPreparation=@{};$byCorrection=@{}
    foreach($event in @($ExpectedEvents|Where-Object{[string]$_.event_id-cmatch'^preparation-completion-timestamp-recovered-[0-9]{4,}$'})){
        $proof=Test-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $WorkspaceRoot -RecoveryPath (Get-PreparationRecoveryPath $WorkspaceRoot "receipts/$($event.event_id).json") -ExpectedEvent $event
        $id=[string]$proof.preparation_event.event_id
        if($byPreparation.ContainsKey($id)){throw 'Preparation recovery index contains duplicate corrections.'}
        $byPreparation[$id]=$proof;$byCorrection[[string]$event.event_id]=$proof
    }
    [pscustomobject]@{by_preparation_event=$byPreparation;by_correction_event=$byCorrection}
}
function Invoke-MorphospacePreparationCompletionTimestampRecovery {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RecoveryPath,[string]$ExpectedRecoverySha256='',[string]$OutPath='',[switch]$Execute,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none')
    $input=[IO.Path]::GetFullPath($RecoveryPath);$inputBytes=[IO.File]::ReadAllBytes($input);$hash=Get-MorphospaceSha256Bytes $inputBytes;$receipt=ConvertFrom-MorphospaceProtocolJsonBytes $inputBytes $input
    if(($ExpectedRecoverySha256-and$ExpectedRecoverySha256-cne$hash)-or($Execute-and-not$ExpectedRecoverySha256)){throw 'Preparation recovery requires its exact inspected input hash.'}
    $relative="receipts/$($receipt.recovery_id).json";$out=Get-PreparationRecoveryPath $WorkspaceRoot $relative
    if(($OutPath-and[IO.Path]::GetFullPath($OutPath)-cne$out)-or$input-ceq$out){throw 'Preparation recovery needs a distinct input and exact canonical output.'}
    $id="$($receipt.recovery_id)-transition";$intentPath=Get-PreparationRecoveryPath $WorkspaceRoot "receipts/transactions/$id.intent.json";$completionPath=Get-PreparationRecoveryPath $WorkspaceRoot "receipts/transactions/$id.completion.json"
    if([IO.File]::Exists($completionPath)){throw 'Preparation completion timestamp recovery was already consumed.'}
    $pending=[IO.File]::Exists($intentPath);$context=Test-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $WorkspaceRoot -RecoveryPath $input -Mode $(if($pending){'Pending'}else{'PreApply'})
    if([string]$context.receipt_raw_sha256-cne$hash){throw 'Preparation recovery reloaded input differs from its inspected raw hash.'}
    if($pending){Assert-PreparationRecoveryIntent (Read-MorphospaceProtocolJson $intentPath) $context $hash}elseif([IO.File]::Exists($out)){throw 'Preparation recovery receipt exists without its owning intent.'}
    if($Execute){
        if(-not$OutPath){throw 'Executed preparation recovery requires canonical OutPath.'}
        $mutex=Enter-MorphospaceWorkspaceMutex $WorkspaceRoot
        try{
            $context=Test-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $WorkspaceRoot -RecoveryPath $input -Mode $(if($pending){'Pending'}else{'PreApply'})
            if([string]$context.receipt_raw_sha256-cne$hash){throw 'Preparation recovery reloaded input differs from its inspected raw hash.'}
            if($pending){Assert-PreparationRecoveryIntent (Read-MorphospaceProtocolJson $intentPath) $context $hash;[void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId $id -Repair -FaultAfter $FaultAfter)}else{
                $projections=@(foreach($name in @('feature_lock','project')){$b=$receipt.snapshots.$name;[pscustomobject]@{path=$b.path;expected_sha256=$b.canonical_sha256;expected_raw_sha256=$b.raw_sha256;document=$b.document}})
                [void](Start-MorphospaceTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId $id -StatePath 'workspace.state.json' -UnitPath ([string]$receipt.snapshots.unit.path) -EventsPath 'iteration-events.jsonl' -TargetState $context.target_state -TargetUnit $context.unit -Event $context.correction_event -ExpectedPreStateSha256 ([string]$receipt.snapshots.state.canonical_sha256) -ExpectedPreStateRawSha256 ([string]$receipt.snapshots.state.raw_sha256) -ExpectedPreUnitSha256 ([string]$receipt.snapshots.unit.canonical_sha256) -ExpectedPreUnitRawSha256 ([string]$receipt.snapshots.unit.raw_sha256) -ExpectedEventTailId ([string]$receipt.ledger.tail_event_id) -ExpectedEventsSha256 ([string]$receipt.ledger.raw_sha256) -ExpectedEventsLength ([long]$receipt.ledger.length) -AdditionalProjections $projections -Artifacts @([pscustomobject]@{source_path=$input;path=$relative;sha256=$hash}) -FaultAfter $FaultAfter)
            }
        }finally{Exit-MorphospaceWorkspaceMutex $mutex}
        [void](Test-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $WorkspaceRoot -RecoveryPath $out)
    }
    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$receipt.project_id;unit_id=[string]$receipt.unit_id;action='RecoverPreparationCompletionTimestamp';timestamp=[string]$receipt.chronology.recovery_timestamp;executed=$Execute.IsPresent;transition='preparation-completion-timestamp-recovered';status_before='active';status_after='active';current_unit_before=[string]$receipt.unit_id;current_unit_after=[string]$receipt.unit_id;preservation=[pscustomobject]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject]@{path=$relative;sha256=$hash};event_id=$(if($Execute){[string]$receipt.recovery_id}else{$null})}
}
Export-ModuleMember -Function New-MorphospacePreparationCompletionTimestampRecovery,Invoke-MorphospacePreparationCompletionTimestampRecovery,Test-MorphospacePreparationCompletionTimestampRecovery,Get-MorphospacePreparationCompletionTimestampRecoveryIndex
