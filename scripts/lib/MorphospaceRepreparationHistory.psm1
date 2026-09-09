Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
$script:RepreparationTransitionLedgerModule = Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1') -PassThru

# Shared read-only historical predicate used by repreparation and continuation.
# It authenticates retained owner evidence without importing mutation owners.


function Get-RepreparationHash { param([object]$Value) Get-MorphospaceCanonicalJsonSha256 $Value }

function Get-RepreparationBytesHash { param([byte[]]$Bytes) Get-MorphospaceSha256Bytes $Bytes }

function Get-RepreparationPath { param([string]$Root,[string]$Relative) Resolve-MorphospaceWorkspacePath $Root $Relative }

function Get-RepreparationLocalSchema {
    param([string]$Root,[string]$Name)
    $path=[IO.Path]::GetFullPath((Join-Path $Root "schemas\$Name"));$schema=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json -Depth 100
    if($schema.PSObject.Properties.Name-contains'$id'){$schema.'$id'=([Uri]$path).AbsoluteUri}
    $schema|ConvertTo-Json -Depth 100
}

function Assert-RepreparationObjectSchema { param([string]$Root,[object]$Value,[string]$Name,[string]$Message) if(-not(Test-Json -Json ($Value|ConvertTo-Json -Depth 64) -Schema (Get-RepreparationLocalSchema $Root $Name))){throw $Message} }

function Read-RepreparationJsonSnapshot {
    param([string]$Path,[string]$Context,[string]$RepoRoot='',[string]$SchemaName='',[string]$SchemaMessage='',[string]$ExpectedSha256='')
    $fullPath=[IO.Path]::GetFullPath($Path)
    try{$stream=[IO.FileStream]::new($fullPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}catch{throw "Unable to read $Context as one stable byte snapshot."}
    try{
        [int64]$length=$stream.Length
        if($length-lt1-or$length-gt16777216){throw "$Context byte length is outside the bounded JSON surface."}
        [byte[]]$bytes=[byte[]]::new([int]$length);$offset=0
        while($offset-lt$bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read-le0){throw "$Context was truncated during its byte snapshot."};$offset+=$read}
        if($stream.Length-ne$length-or$stream.Position-ne$length){throw "$Context changed during its byte snapshot."}
    } finally {$stream.Dispose()}
    $sha256=Get-RepreparationBytesHash $bytes
    if($ExpectedSha256-and$sha256-cne$ExpectedSha256){throw "$Context bytes do not match the supplied evidence."}
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)}catch{throw "$Context is not strict UTF-8."}
    if($SchemaName-and-not(Test-Json -Json $text -Schema (Get-RepreparationLocalSchema $RepoRoot $SchemaName))){throw $SchemaMessage}
    $document=ConvertFrom-MorphospaceProtocolJsonBytes $bytes $Context
    [pscustomobject]@{path=$fullPath;bytes=$bytes;sha256=$sha256;document=$document}
}

function Read-RepreparationBoundSnapshot {
    param([string]$Workspace,[object]$Binding,[string]$Name,[string]$RepoRoot='',[string]$SchemaName='',[string]$SchemaMessage='')
    $path=Get-RepreparationPath $Workspace ([string]$Binding.path)
    Read-RepreparationJsonSnapshot $path "Repreparation $Name" $RepoRoot $SchemaName $SchemaMessage ([string]$Binding.sha256)
}

function Assert-RepreparationTransitionLedgerEvidence {
    param([string]$Workspace,[string]$IntentRelative,[object]$IntentSnapshot,[string]$CompletionRelative,[object]$CompletionSnapshot)
    $intent=$IntentSnapshot.document;$transactionId=[string]$intent.transaction_id
    &$script:RepreparationTransitionLedgerModule {
        param($workspaceValue,$transactionValue,$intentRelativeValue,$intentShaValue,$intentValue,$completionRelativeValue,$completionValue)
        Assert-MorphospaceLedgerIntent $intentValue $transactionValue
        $completion=$completionValue
        Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Historical transition ledger completion'
        Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Historical transition ledger completion intent reference'
        if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or
           [string]$completion.transaction_id-cne$transactionValue-or[string]$completion.status-cne'committed'-or
           [string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$intentRelativeValue-or
           [string]$completion.intent.schema-cne[string]$intentValue.schema-or
           [string]$completion.intent.sha256-cne$intentShaValue-or
           [string]$completion.state_sha256-cne[string]$intentValue.target.state.sha256-or
           [string]$completion.unit_sha256-cne[string]$intentValue.target.unit.sha256-or
           [string]$completion.event_id-cne[string]$intentValue.event.event_id-or
           (Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))-lt(Test-MorphospaceStrictUtcTimestamp ([string]$intentValue.created_at))){throw 'Historical transition completion is not canonically bound to its exact intent.'}
        $eventsAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspaceValue -RelativePath ([string]$intentValue.events.path) -RequireLeaf
        [void](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intentValue -AllowHistorical -RequirePresent)
        foreach($artifact in @($intentValue.artifacts)){$target=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspaceValue -RelativePath ([string]$artifact.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $target)-cne[string]$artifact.sha256){throw "Historical transition committed artifact differs from its intent: $($artifact.path)"}}
    } $Workspace $transactionId $IntentRelative ([string]$IntentSnapshot.sha256) $intent $CompletionRelative $CompletionSnapshot.document
}

function Get-RepreparationEventProjection {
    param([object]$Event)
    [pscustomobject][ordered]@{schema=[string]$Event.schema;event_id=[string]$Event.event_id;sequence=[int]$Event.sequence;timestamp=[string]$Event.timestamp;project_id=[string]$Event.project_id;unit_id=$(if($null-eq$Event.unit_id){$null}else{[string]$Event.unit_id});event_type=[string]$Event.event_type;summary=[string]$Event.summary;receipts=@($Event.receipts|ForEach-Object{[string]$_})}
}

function Assert-RepreparationHistoricalSuffix {
    param([string]$Workspace,[string]$RepoRoot,[object]$Recovery,[object[]]$Events,[object]$RetiredUnit)
    if($Events.Count-lt3-or[string]$Events[-1].event_id-cne[string]$Recovery.retirement.event_id){throw 'Repreparation requires the exact completed retirement at the ledger tail.'}
    $retirementTransaction="$([string]$Recovery.retirement.event_id)-transition";$originalTransaction="$([string]$Recovery.original_preparation.preparation_id)-prepared-transition"
    if([string]$Recovery.retirement.receipt.path-cne"receipts/$([string]$Recovery.retired_unit_id)-contract-retirement.json"-or[string]$Recovery.retirement.intent.path-cne"receipts/transactions/$retirementTransaction.intent.json"-or[string]$Recovery.retirement.completion.path-cne"receipts/transactions/$retirementTransaction.completion.json"-or[string]$Recovery.original_preparation.receipt.path-cne"receipts/$([string]$Recovery.original_preparation.preparation_id).json"-or[string]$Recovery.original_preparation.intent.path-cne"receipts/transactions/$originalTransaction.intent.json"-or[string]$Recovery.original_preparation.completion.path-cne"receipts/transactions/$originalTransaction.completion.json"){throw 'Repreparation historical evidence paths are not the exact protocol-derived constants.'}
    foreach($event in @($Events[-3],$Events[-2],$Events[-1])){Assert-RepreparationObjectSchema $RepoRoot $event 'iteration-event.schema.json' 'Repreparation historical ledger suffix contains an invalid event.'}
    $retirementReceiptSnapshot=Read-RepreparationBoundSnapshot $Workspace $Recovery.retirement.receipt 'retirement receipt' $RepoRoot 'work-unit-automation-receipt.schema.json' 'Repreparation retirement receipt is invalid.'
    $retirementIntentSnapshot=Read-RepreparationBoundSnapshot $Workspace $Recovery.retirement.intent 'retirement intent'
    $retirementCompletionSnapshot=Read-RepreparationBoundSnapshot $Workspace $Recovery.retirement.completion 'retirement completion'
    Assert-RepreparationTransitionLedgerEvidence $Workspace ([string]$Recovery.retirement.intent.path) $retirementIntentSnapshot ([string]$Recovery.retirement.completion.path) $retirementCompletionSnapshot
    $retirementReceipt=$retirementReceiptSnapshot.document;$retirementIntent=$retirementIntentSnapshot.document;$retirementCompletion=$retirementCompletionSnapshot.document;$retirementEvent=$Events[-1]
    if([string]$retirementReceipt.action-cne'RetireProposed'-or$retirementReceipt.executed-ne$true-or[string]$retirementReceipt.project_id-cne[string]$Recovery.project_id-or[string]$retirementReceipt.event_id-cne[string]$retirementEvent.event_id-or[string]$retirementReceipt.unit_id-cne[string]$Recovery.retired_unit_id-or[string]$retirementReceipt.proposed_retirement.replacement_unit_id-cne[string]$Recovery.replacement_unit_id-or[string]$retirementReceipt.proposed_retirement.reason-cne'contract-invalid'-or[string]$retirementEvent.project_id-cne[string]$Recovery.project_id-or[string]$retirementEvent.unit_id-cne[string]$Recovery.retired_unit_id-or@($retirementEvent.receipts).Count-ne1-or[string]$retirementEvent.receipts[0]-cne[string]$Recovery.retirement.receipt.path){throw 'Repreparation retirement receipt does not name the exact retired/replacement pair.'}
    $retirementCompletionIntentHash=if($retirementCompletion.PSObject.Properties.Name-contains'intent_sha256'){[string]$retirementCompletion.intent_sha256}else{[string]$retirementCompletion.intent.sha256}
    $retirementArtifact=@($retirementIntent.artifacts|Where-Object{[string]$_.path-ceq[string]$Recovery.retirement.receipt.path})
    $retirementEventHash=Get-RepreparationHash (Get-RepreparationEventProjection $retirementEvent)
    if([string]$retirementIntent.event.event_id-cne[string]$retirementEvent.event_id-or(Get-RepreparationHash (Get-RepreparationEventProjection $retirementIntent.event))-cne$retirementEventHash){throw 'Repreparation retirement event differs between its intent and ledger.'}
    if([string]$retirementCompletion.event_id-cne[string]$retirementEvent.event_id-or[string]$retirementCompletion.status-cne'committed'-or$retirementCompletionIntentHash-cne[string]$retirementIntentSnapshot.sha256){throw 'Repreparation retirement completion does not bind its committed intent and event.'}
    if($retirementArtifact.Count-ne1-or[string]$retirementArtifact[0].sha256-cne[string]$retirementReceiptSnapshot.sha256-or[string]$retirementArtifact[0].bytes_base64-cne[Convert]::ToBase64String($retirementReceiptSnapshot.bytes)){throw 'Repreparation retirement intent does not preserve the exact receipt bytes.'}
    $admission=$retirementReceipt.proposed_retirement.authenticated_admission
    $admissionReceiptSnapshot=Read-RepreparationBoundSnapshot $Workspace $admission.receipt 'admission receipt' $RepoRoot 'development-unit-admission-v1.schema.json' 'Repreparation admission receipt is invalid.'
    $admissionIntentSnapshot=Read-RepreparationBoundSnapshot $Workspace $admission.transaction.intent 'admission intent'
    $admissionCompletionSnapshot=Read-RepreparationBoundSnapshot $Workspace $admission.transaction.completion 'admission completion'
    $admissionReceipt=$admissionReceiptSnapshot.document;$admissionIntent=$admissionIntentSnapshot.document;$admissionCompletion=$admissionCompletionSnapshot.document;$admissionEvent=$Events[-2]
    $admissionTransaction="$([string]$admission.admission_id)-admitted-transition";if([string]$admission.receipt.path-cne"receipts/$([string]$admission.admission_id).json"-or[string]$admission.transaction.intent.path-cne"receipts/transactions/$admissionTransaction.intent.json"-or[string]$admission.transaction.completion.path-cne"receipts/transactions/$admissionTransaction.completion.json"){throw 'Repreparation predecessor-admission evidence paths are not protocol-derived.'}
    Assert-RepreparationTransitionLedgerEvidence $Workspace ([string]$admission.transaction.intent.path) $admissionIntentSnapshot ([string]$admission.transaction.completion.path) $admissionCompletionSnapshot
    $admittedUnitHash=Get-RepreparationHash $admissionReceipt.unit
    $admissionArtifact=@($admissionIntent.artifacts|Where-Object{[string]$_.path-ceq[string]$admission.receipt.path});$admissionCompletionIntentHash=if($admissionCompletion.PSObject.Properties.Name-contains'intent_sha256'){[string]$admissionCompletion.intent_sha256}else{[string]$admissionCompletion.intent.sha256}
    $admissionEventHash=Get-RepreparationHash (Get-RepreparationEventProjection $admissionEvent)
    if([string]$admission.event.event_id-cne[string]$admissionEvent.event_id-or[int]$admission.event.sequence-ne[int]$admissionEvent.sequence-or[string]$admission.event.sha256-cne$admissionEventHash-or[string]$admissionIntent.event.event_id-cne[string]$admissionEvent.event_id-or(Get-RepreparationHash (Get-RepreparationEventProjection $admissionIntent.event))-cne$admissionEventHash-or[string]$admissionCompletion.event_id-cne[string]$admissionEvent.event_id-or$admissionCompletionIntentHash-cne[string]$admissionIntentSnapshot.sha256-or$admissionArtifact.Count-ne1-or[string]$admissionArtifact[0].sha256-cne[string]$admissionReceiptSnapshot.sha256-or[string]$admissionArtifact[0].bytes_base64-cne[Convert]::ToBase64String($admissionReceiptSnapshot.bytes)-or[string]$admissionReceipt.project_id-cne[string]$Recovery.project_id-or[string]$admissionReceipt.unit_id-cne[string]$Recovery.retired_unit_id-or[string]$admissionEvent.project_id-cne[string]$Recovery.project_id-or[string]$admissionEvent.unit_id-cne[string]$Recovery.retired_unit_id-or@($admissionEvent.receipts).Count-ne1-or[string]$admissionEvent.receipts[0]-cne[string]$admission.receipt.path-or[int]$admissionEvent.sequence+1-ne[int]$retirementEvent.sequence-or$admittedUnitHash-cne[string]$admission.transaction.target_unit_sha256-or$admittedUnitHash-cne[string]$retirementIntent.pre.unit.sha256-or(Get-RepreparationHash $RetiredUnit)-cne[string]$retirementIntent.target.unit.sha256){throw 'Repreparation admission is not the exact contiguous predecessor of retirement.'}
    $original=$Recovery.original_preparation;if([string]$admissionReceipt.preparation.preparation_id-cne[string]$original.preparation_id-or[string]$admissionReceipt.preparation.receipt_path-cne[string]$original.receipt.path-or[string]$admissionReceipt.preparation.receipt_sha256-cne[string]$original.receipt.sha256-or[string]$admissionReceipt.preparation.source_composition_path-cne[string]$original.source_composition.path-or[string]$admissionReceipt.preparation.source_composition_sha256-cne[string]$original.source_composition.sha256){throw 'Repreparation admission does not bind the exact supplied original preparation and source bytes.'}
    $prepReceiptSnapshot=Read-RepreparationBoundSnapshot $Workspace $original.receipt 'original preparation receipt' $RepoRoot 'development-envelope-preparation-receipt-v1.schema.json' 'Repreparation original preparation receipt is invalid.'
    $sourceSnapshot=Read-RepreparationBoundSnapshot $Workspace $original.source_composition 'original source lock' $RepoRoot 'development-envelope-source-composition-v1.schema.json' 'Repreparation original source lock is invalid.'
    $prepIntentSnapshot=Read-RepreparationBoundSnapshot $Workspace $original.intent 'original preparation intent' $RepoRoot 'development-envelope-preparation-intent-v1.schema.json' 'Repreparation original preparation intent is invalid.'
    $prepCompletionSnapshot=Read-RepreparationBoundSnapshot $Workspace $original.completion 'original preparation completion' $RepoRoot 'development-envelope-preparation-completion-v1.schema.json' 'Repreparation original preparation completion is invalid.'
    $prepReceipt=$prepReceiptSnapshot.document;$source=$sourceSnapshot.document;$prepIntent=$prepIntentSnapshot.document;$prepCompletion=$prepCompletionSnapshot.document;$prepEvent=$Events[-3]
    $prepReceiptArtifact=@($prepIntent.artifacts|Where-Object{[string]$_.path-ceq[string]$original.receipt.path});$prepSourceArtifact=@($prepIntent.artifacts|Where-Object{[string]$_.path-ceq[string]$original.source_composition.path});$prepArtifactPaths=@($prepIntent.artifacts|ForEach-Object{[string]$_.path}|Sort-Object)
    $prepReceiptBytes=$prepReceiptSnapshot.bytes;$prepSourceBytes=$sourceSnapshot.bytes;$prepReceiptCanonical=Get-RepreparationHash $prepReceipt;$sourceCanonical=Get-RepreparationHash $source
    if($prepReceiptArtifact.Count-ne1-or$prepSourceArtifact.Count-ne1-or$prepArtifactPaths.Count-ne2-or$prepArtifactPaths[0]-cne(@([string]$original.receipt.path,[string]$original.source_composition.path)|Sort-Object)[0]-or$prepArtifactPaths[1]-cne(@([string]$original.receipt.path,[string]$original.source_composition.path)|Sort-Object)[1]-or[string]$prepReceiptArtifact[0].bytes_base64-cne[Convert]::ToBase64String($prepReceiptBytes)-or[string]$prepSourceArtifact[0].bytes_base64-cne[Convert]::ToBase64String($prepSourceBytes)-or[string]$prepReceiptArtifact[0].sha256-cne$prepReceiptCanonical-or[string]$prepSourceArtifact[0].sha256-cne$sourceCanonical){throw 'Repreparation original preparation artifacts do not bind exactly two live canonical documents.'}
    $historicalRepositoryMapPath=[string]$prepIntent.pre.repository_map.path;$historicalRepositoryMapSha256=[string]$prepIntent.pre.repository_map.sha256
    if([string]$prepIntent.transaction_id-cne$originalTransaction-or[string]$prepCompletion.transaction_id-cne$originalTransaction-or[string]$original.source_composition.path-cne[string]$prepReceipt.source_composition.path-or$sourceCanonical-cne[string]$original.source_composition.canonical_sha256-or[string]$source.project_id-cne[string]$Recovery.project_id-or[string]$source.preparation_id-cne[string]$original.preparation_id-or[string]$prepEvent.event_id-cne[string]$original.event_id-or[string]$prepEvent.project_id-cne[string]$Recovery.project_id-or[int]$prepEvent.sequence+1-ne[int]$admissionEvent.sequence-or@($prepEvent.receipts).Count-ne1-or[string]$prepEvent.receipts[0]-cne[string]$original.receipt.path-or[string]$prepIntent.event.event_id-cne[string]$prepEvent.event_id-or(Get-RepreparationHash (Get-RepreparationEventProjection $prepIntent.event))-cne(Get-RepreparationHash (Get-RepreparationEventProjection $prepEvent))-or[string]$prepCompletion.event_id-cne[string]$prepEvent.event_id-or[string]$prepCompletion.status-cne'committed'-or[string]$prepCompletion.intent_sha256-cne[string]$prepIntentSnapshot.sha256-or[string]$prepReceipt.preparation_id-cne[string]$original.preparation_id-or[string]$prepReceipt.project_id-cne[string]$Recovery.project_id-or[string]$prepReceipt.predecessor_unit_id-cne[string]$prepEvent.unit_id-or@($admissionReceipt.unit.prerequisites)-cnotcontains[string]$prepReceipt.predecessor_unit_id-or[string]$prepReceipt.project_sha256-cne[string]$prepIntent.target.project.sha256-or[string]$prepReceipt.feature_lock_sha256-cne[string]$prepIntent.target.feature_lock.sha256-or[string]$prepReceipt.source_composition.sha256-cne$sourceCanonical-or[string]$prepIntent.target.project.path-cne'project.spec.json'-or[string]$prepIntent.target.feature_lock.path-cne'feature.lock.json'-or[string]$prepIntent.target.repository_map.path-cne$historicalRepositoryMapPath-or[string]$prepIntent.target.repository_map.sha256-cne$historicalRepositoryMapSha256-or[string]$admissionReceipt.expected.repository_map_path-cne$historicalRepositoryMapPath-or[string]$admissionReceipt.expected.repository_map_sha256-cne$historicalRepositoryMapSha256){throw 'Repreparation original preparation/source chain is not exact and contiguous.'}
    $snapshotByPath=@{};foreach($snapshot in @($retirementReceiptSnapshot,$retirementIntentSnapshot,$retirementCompletionSnapshot,$admissionReceiptSnapshot,$admissionIntentSnapshot,$admissionCompletionSnapshot,$prepReceiptSnapshot,$sourceSnapshot,$prepIntentSnapshot,$prepCompletionSnapshot)){$snapshotByPath[[string]$snapshot.path]=$snapshot}
    $preserved=@($Recovery.retirement.receipt,$Recovery.retirement.intent,$Recovery.retirement.completion,$admission.receipt,$admission.transaction.intent,$admission.transaction.completion,$original.receipt,$original.source_composition,$original.intent,$original.completion)|ForEach-Object{$absolute=Get-RepreparationPath $Workspace ([string]$_.path);[pscustomobject][ordered]@{path=[string]$_.path;sha256=[string]$snapshotByPath[$absolute].sha256}}
    [pscustomobject]@{preserved=@($preserved);source=$source;live=[pscustomobject]@{project_sha256=[string]$prepIntent.target.project.sha256;feature_lock_sha256=[string]$prepIntent.target.feature_lock.sha256;repository_map_path=$historicalRepositoryMapPath;repository_map_sha256=[string]$prepIntent.target.repository_map.sha256;state_sha256=[string]$retirementIntent.target.state.sha256}}
}

Export-ModuleMember -Function Get-RepreparationHash,Get-RepreparationBytesHash,Get-RepreparationPath,Get-RepreparationLocalSchema,Assert-RepreparationObjectSchema,Read-RepreparationJsonSnapshot,Read-RepreparationBoundSnapshot,Assert-RepreparationTransitionLedgerEvidence,Get-RepreparationEventProjection,Assert-RepreparationHistoricalSuffix
