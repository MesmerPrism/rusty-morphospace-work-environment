Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force
$script:HscTransitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1') -Force -PassThru

$script:HscSchema = 'rusty.morphospace.workflow.historical_supersession_compatibility.v1'
$script:HscSummary = 'Recorded exact compatibility evidence for one transactionless historical supersession without creating or rewriting historical artifacts.'
$script:HscMaximumLedgerBytes = 67108864

function Get-HscRepoRoot { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
function Get-HscHashBytes { param([byte[]]$Bytes) Get-MorphospaceSha256Bytes $Bytes }
function Get-HscCanonicalFileBytes { param([object]$Document) [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Document) + "`n") }
function Copy-HscDocument { param([object]$Document) $Document | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String }

function Test-HscSchema {
    param([object]$Document,[string]$Schema,[string]$Context)
    $schemaPath = Join-Path (Get-HscRepoRoot) "schemas\$Schema"
    if (-not (Test-Json -Json ($Document | ConvertTo-Json -Depth 100 -Compress) -SchemaFile $schemaPath)) {
        throw "$Context does not satisfy its closed schema."
    }
}

function Read-HscJsonSnapshot {
    param([string]$Path,[string]$Schema = '',[string]$Context = 'historical supersession compatibility artifact')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { throw "$Context is missing: $full" }
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.LongLength -gt 4194304) { throw "$Context exceeds its four-MiB bound." }
    $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context $Context
    if ($Schema) { Test-HscSchema $document $Schema $Context }
    [pscustomobject][ordered]@{path=$full;bytes=$bytes;sha256=Get-HscHashBytes $bytes;document=$document}
}

function Read-HscLedgerRows {
    param([byte[]]$Bytes,[string]$Context)
    if ($Bytes.LongLength -lt 1 -or $Bytes.LongLength -gt $script:HscMaximumLedgerBytes -or $Bytes[-1] -ne 0x0a) {
        throw "$Context is empty, oversized, or lacks a terminal LF."
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) { throw "$Context has a forbidden UTF-8 BOM." }
    $rows = [Collections.Generic.List[object]]::new()
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $start = 0
    $expectedSequence = 1
    for ($index=0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -ne 0x0a) { continue }
        $contentLength = $index - $start
        if ($contentLength -gt 0 -and $Bytes[$index-1] -eq 0x0d) { $contentLength-- }
        if ($contentLength -le 0) { throw "$Context contains a blank record." }
        $content = [byte[]]::new($contentLength)
        [Array]::Copy($Bytes,$start,$content,0,$contentLength)
        $line = [byte[]]::new($index-$start+1)
        [Array]::Copy($Bytes,$start,$line,0,$line.Length)
        $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $content -Context "$Context event $expectedSequence"
        Test-HscSchema $document 'iteration-event.schema.json' "$Context event $expectedSequence"
        if ([int]$document.sequence -ne $expectedSequence -or -not $ids.Add([string]$document.event_id)) {
            throw "$Context has a non-contiguous sequence or repeated event identity."
        }
        $rows.Add([pscustomobject][ordered]@{document=$document;line_bytes=$line;line_sha256=Get-HscHashBytes $line})
        $expectedSequence++
        $start = $index + 1
    }
    if ($start -ne $Bytes.Length) { throw "$Context has trailing bytes after its final record." }
    @($rows.ToArray())
}

function Assert-HscSameDocument {
    param([object]$Expected,[object]$Actual,[string]$Context)
    if ((Get-MorphospaceCanonicalJsonSha256 $Expected) -cne (Get-MorphospaceCanonicalJsonSha256 $Actual)) { throw "$Context drifted." }
}

function Assert-HscStateTailOnly {
    param([object]$Before,[object]$After,[string]$Tail,[string]$Context)
    $expected = Copy-HscDocument $Before
    $expected.last_event_id = $Tail
    Assert-HscSameDocument $expected $After $Context
}

function Get-HscNormalizationEvidence {
    param([string]$Workspace,[string]$NormalizationId)
    if ($NormalizationId -cnotmatch '^[a-z0-9][a-z0-9-]{1,111}$') { throw 'Historical supersession compatibility normalization ID is not canonical.' }
    $transactionId = "$NormalizationId-normalization"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentSnapshot = Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $intentRelative -RequireLeaf) 'event-ledger-prefix-normalization-intent-v1.schema.json' 'Historical compatibility normalization intent'
    $completionSnapshot = Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $completionRelative -RequireLeaf) 'event-ledger-prefix-normalization-completion-v1.schema.json' 'Historical compatibility normalization completion'
    $intent = $intentSnapshot.document
    $completion = $completionSnapshot.document
    if ([string]$intent.normalization_id -cne $NormalizationId -or [string]$intent.transaction_id -cne $transactionId -or
        [string]$intent.paths.completion -cne $completionRelative -or [string]$intent.paths.receipt -cne "receipts/$NormalizationId.json" -or
        [string]$intent.paths.events -cne 'iteration-events.jsonl' -or [string]$intent.paths.state -cne 'workspace.state.json' -or
        [string]$intent.status -cne 'prepared') { throw 'Historical compatibility normalization intent identity or paths drifted.' }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))
    try { $before = [Convert]::FromBase64String([string]$intent.pre_events_base64) } catch { throw 'Historical compatibility normalization ledger preimage is not valid base64.' }
    if ([Convert]::ToBase64String($before) -cne [string]$intent.pre_events_base64 -or $before.Length -lt 3 -or $before[0] -ne 0x0d -or $before[1] -ne 0x0a -or
        $before.LongLength -ne [int64]$intent.pre.events_length -or (Get-HscHashBytes $before) -cne [string]$intent.pre.events_sha256) {
        throw 'Historical compatibility normalization ledger preimage binding is invalid.'
    }
    $normalized = [byte[]]::new($before.Length-2)
    [Array]::Copy($before,2,$normalized,0,$normalized.Length)
    if ($normalized.LongLength -ne [int64]$intent.target.normalized_prefix_length -or (Get-HscHashBytes $normalized) -cne [string]$intent.target.normalized_prefix_sha256) {
        throw 'Historical compatibility normalization preserved-prefix binding is invalid.'
    }
    $priorRows = @(Read-HscLedgerRows $normalized 'Historical compatibility normalized historical prefix')
    $priorTail = $priorRows[-1]
    if ([string]$priorTail.document.event_id -cne [string]$intent.pre.event_tail_id -or [int]$priorTail.document.sequence -ne [int]$intent.pre.event_tail_sequence) {
        throw 'Historical compatibility normalization prior tail binding is invalid.'
    }
    try { $preStateBytes = [Convert]::FromBase64String([string]$intent.pre_state_base64) } catch { throw 'Historical compatibility normalization state preimage is not valid base64.' }
    if ([Convert]::ToBase64String($preStateBytes) -cne [string]$intent.pre_state_base64 -or (Get-HscHashBytes $preStateBytes) -cne [string]$intent.pre.state_file_sha256) {
        throw 'Historical compatibility normalization state byte binding is invalid.'
    }
    $preState = ConvertFrom-MorphospaceProtocolJsonBytes $preStateBytes 'Historical compatibility normalization pre-state'
    Assert-HscSameDocument $preState $intent.pre_state 'Historical compatibility normalization pre-state'
    Assert-HscStateTailOnly $intent.pre_state $intent.target_state $NormalizationId 'Historical compatibility normalization target state'
    if ([string]$intent.pre_state.current_unit -cne [IO.Path]::GetFileNameWithoutExtension([string]$intent.paths.unit) -or
        [string]$intent.pre_state.last_event_id -cne [string]$intent.pre.event_tail_id -or
        [string]$intent.pre_state.project_id -cne [string]$intent.project.project_id) {
        throw 'Historical compatibility normalization state identity is invalid.'
    }
    $eventBytes = Get-HscCanonicalFileBytes $intent.event
    $after = [byte[]]::new($normalized.Length+$eventBytes.Length)
    [Array]::Copy($normalized,0,$after,0,$normalized.Length)
    [Array]::Copy($eventBytes,0,$after,$normalized.Length,$eventBytes.Length)
    $afterRows = @(Read-HscLedgerRows $after 'Historical compatibility normalization target ledger')
    if ($after.LongLength -ne [int64]$intent.target.events_length -or (Get-HscHashBytes $after) -cne [string]$intent.target.events_sha256 -or
        [string]$intent.event.event_id -cne $NormalizationId -or [int]$intent.event.sequence -ne [int]$priorTail.document.sequence+1 -or
        [string]$intent.event.project_id -cne [string]$intent.project.project_id -or [string]$intent.event.unit_id -cne [string]$intent.pre_state.current_unit -or
        [string]$intent.event.event_type -cne 'state-transition' -or @($intent.event.receipts).Count -ne 1 -or [string]$intent.event.receipts[0] -cne [string]$intent.paths.receipt) {
        throw 'Historical compatibility normalization target event or ledger is invalid.'
    }
    $embeddedReceiptBytes = Get-HscCanonicalFileBytes $intent.receipt.document
    if ((Get-HscHashBytes $embeddedReceiptBytes) -cne [string]$intent.receipt.sha256 -or [string]$intent.receipt.path -cne [string]$intent.paths.receipt) {
        throw 'Historical compatibility normalization embedded receipt binding is invalid.'
    }
    Test-HscSchema $intent.pre_state 'workspace-state-v2.schema.json' 'Historical compatibility normalization pre-state'
    Test-HscSchema $intent.target_state 'workspace-state-v2.schema.json' 'Historical compatibility normalization target-state'
    Test-HscSchema $intent.event 'iteration-event.schema.json' 'Historical compatibility normalization event'
    Test-HscSchema $intent.receipt.document 'event-ledger-prefix-normalization-v1.schema.json' 'Historical compatibility normalization embedded receipt'
    $receiptSnapshot = Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace ([string]$intent.paths.receipt) -RequireLeaf) 'event-ledger-prefix-normalization-v1.schema.json' 'Historical compatibility normalization receipt'
    if ($receiptSnapshot.sha256 -cne [string]$intent.receipt.sha256) { throw 'Historical compatibility normalization receipt bytes drifted from its intent.' }
    Assert-HscSameDocument $intent.receipt.document $receiptSnapshot.document 'Historical compatibility normalization receipt document'
    if ([string]$completion.transaction_id -cne $transactionId -or [string]$completion.normalization_id -cne $NormalizationId -or
        [string]$completion.status -cne 'committed' -or [string]$completion.intent.path -cne $intentRelative -or
        [string]$completion.intent.sha256 -cne $intentSnapshot.sha256 -or [string]$completion.receipt.path -cne [string]$intent.paths.receipt -or
        [string]$completion.receipt.sha256 -cne $receiptSnapshot.sha256 -or [string]$completion.event_id -cne $NormalizationId -or
        [string]$completion.repository_head -cne [string]$intent.repository.head -or
        [string]$completion.state_sha256 -cne [string]$intent.target.state_file_sha256 -or
        [string]$completion.unit_sha256 -cne [string]$intent.pre.unit_file_sha256 -or
        [string]$completion.events_sha256 -cne [string]$intent.target.events_sha256) {
        throw 'Historical compatibility normalization completion is detached from its intent or receipt.'
    }
    $created = Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at)
    $completed = Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at)
    if ($completed -lt $created) { throw 'Historical compatibility normalization completion precedes its intent.' }
    $liveBytes = [IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf))
    $liveRows = @(Read-HscLedgerRows $liveBytes 'Historical compatibility live event ledger')
    if ($liveRows.Count -lt $afterRows.Count) { throw 'Historical compatibility live event ledger omits normalized history.' }
    for ($rowIndex=0; $rowIndex -lt $afterRows.Count; $rowIndex++) {
        Assert-HscSameDocument $afterRows[$rowIndex].document $liveRows[$rowIndex].document "Historical compatibility normalized event $($rowIndex+1)"
    }
    $replacementPath = [string]$intent.paths.unit
    $replacementSnapshot = Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $replacementPath -RequireLeaf) '' 'Historical compatibility normalized replacement unit'
    if ((Get-MorphospaceCanonicalJsonSha256 $replacementSnapshot.document) -cne [string]$intent.pre.unit_document_sha256 -or
        [string]$replacementSnapshot.document.unit_id -cne [string]$intent.pre_state.current_unit -or
        [string]$replacementSnapshot.document.project_id -cne [string]$intent.project.project_id) {
        throw 'Historical compatibility normalized replacement unit document drifted.'
    }
    [pscustomobject][ordered]@{
        normalization_id=$NormalizationId;intent_snapshot=$intentSnapshot;completion_snapshot=$completionSnapshot;receipt_snapshot=$receiptSnapshot
        intent=$intent;completion=$completion;receipt=$receiptSnapshot.document;normalized=$normalized;after=$after
        prior_rows=$priorRows;prior_tail=$priorTail;after_rows=$afterRows;live_rows=$liveRows;live_bytes=$liveBytes
        replacement_snapshot=$replacementSnapshot
    }
}

function Get-HscTransitionBinding {
    param([string]$Workspace,[object]$Row,[string]$ExpectedUnitPath,[switch]$AllowPendingTailProjection)
    $eventId = [string]$Row.document.event_id
    $transactionId = "$eventId-transition"
    $intentRelative="receipts/transactions/$transactionId.intent.json"
    $completionRelative="receipts/transactions/$transactionId.completion.json"
    $intentSnapshot=Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $intentRelative -RequireLeaf) '' 'Historical compatibility accepted-endpoint intent'
    $completionSnapshot=Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $completionRelative -RequireLeaf) '' 'Historical compatibility accepted-endpoint completion'
    if($AllowPendingTailProjection){
        $intent=$intentSnapshot.document;$completion=$completionSnapshot.document
        $eventsPath=Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf
        &$script:HscTransitionLedgerModule {
            param($workspace,$id,$candidate,$events)
            Assert-MorphospaceLedgerIntent $candidate $id
            Assert-MorphospaceLedgerArtifactNamespace $workspace $id $candidate
            [void](Assert-MorphospaceLedgerEventPlacement $events $candidate -AllowHistorical -RequirePresent)
        } $Workspace $transactionId $intent $eventsPath
        if([string]$intent.state.path-cne'workspace.state.json'-or[string]$intent.unit.path-cne$ExpectedUnitPath-or[string]$intent.events.path-cne'iteration-events.jsonl'){
            throw 'Historical compatibility accepted-endpoint paths are not exact during pending projection repair.'
        }
        Assert-HscSameDocument $intent.event $Row.document 'Historical compatibility accepted-endpoint event'
        Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Historical compatibility accepted-endpoint completion'
        Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Historical compatibility accepted-endpoint completion intent'
        if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or[string]$completion.transaction_id-cne$transactionId-or
           [string]$completion.status-cne'committed'-or[string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$intentRelative-or
           [string]$completion.intent.schema-cne[string]$intent.schema-or[string]$completion.intent.sha256-cne[string]$intentSnapshot.sha256-or
           [string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256-or
           [string]$completion.event_id-cne$eventId){throw 'Historical compatibility accepted-endpoint completion is detached from its intent.'}
        if((Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))-lt(Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))){
            throw 'Historical compatibility accepted-endpoint completion precedes its intent.'
        }
        foreach($artifact in @($intent.artifacts)){
            $artifactPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$artifact.path) -RequireLeaf
            if((Get-MorphospaceFileSha256 $artifactPath)-cne[string]$artifact.sha256){throw 'Historical compatibility accepted-endpoint artifact drifted.'}
        }
        $transition=[pscustomobject][ordered]@{transaction_id=$transactionId;status='committed';intent=$intent;completion=$completion;event_tail_id=$eventId}
    }else{
        $transition = Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $transactionId `
            -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $ExpectedUnitPath -ExpectedEventsPath 'iteration-events.jsonl'
    }
    [pscustomobject][ordered]@{
        transition=$transition
        event_id=$eventId
        sequence=[int]$Row.document.sequence
        intent_path=$intentRelative
        intent_sha256=$intentSnapshot.sha256
        completion_path=$completionRelative
        completion_sha256=$completionSnapshot.sha256
    }
}

function Get-HscLegacyV1SupersessionBinding {
    param(
        [string]$Workspace,
        [object]$Row,
        [string]$OldUnitPath,
        [string]$ReplacementUnitId,
        [object]$Normalization
    )
    $eventId=[string]$Row.document.event_id
    $transactionId="$eventId-transition"
    $intentRelative="receipts/transactions/$transactionId.intent.json"
    $completionRelative="receipts/transactions/$transactionId.completion.json"
    $intentSnapshot=Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $intentRelative -RequireLeaf) '' 'Historical compatibility legacy-v1 successor intent'
    $completionSnapshot=Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $completionRelative -RequireLeaf) '' 'Historical compatibility legacy-v1 successor completion'
    $intent=$intentSnapshot.document;$completion=$completionSnapshot.document
    Assert-MorphospaceExactPropertySet $intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') @() 'Historical compatibility legacy-v1 successor intent'
    Assert-MorphospaceExactPropertySet $intent.pre @('state','unit') @() 'Historical compatibility legacy-v1 successor preimage'
    Assert-MorphospaceExactPropertySet $intent.target @('state','unit') @() 'Historical compatibility legacy-v1 successor target'
    Assert-MorphospaceExactPropertySet $intent.expected @('state_sha256','unit_sha256','event_tail_id','events_sha256','events_length') @() 'Historical compatibility legacy-v1 successor expected ledger'
    foreach($projection in @('state','unit')){
        Assert-MorphospaceExactPropertySet $intent.$projection @('path') @() "Historical compatibility legacy-v1 successor $projection path"
        Assert-MorphospaceExactPropertySet $intent.pre.$projection @('sha256') @() "Historical compatibility legacy-v1 successor pre-$projection"
        Assert-MorphospaceExactPropertySet $intent.target.$projection @('sha256','document') @() "Historical compatibility legacy-v1 successor target-$projection"
    }
    $oldId=[string]$Row.document.unit_id
    $expectedEventId=Get-MorphospaceSupersessionEventId -OldUnitId $oldId -ReplacementUnitId $ReplacementUnitId
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or[string]$intent.transaction_id-cne$transactionId-or[string]$intent.status-cne'prepared'-or
       [string]$intent.state.path-cne'workspace.state.json'-or[string]$intent.unit.path-cne$OldUnitPath-or[string]$intent.events.path-cne'iteration-events.jsonl'-or
       @($intent.artifacts).Count-ne2-or[string]$eventId-cne$expectedEventId-or[string]$intent.event.event_id-cne$eventId-or
       [string]$intent.event.unit_id-cne$oldId-or[string]$intent.event.project_id-cne[string]$Normalization.intent.project.project_id-or
       [string]$intent.event.event_type-cne'state-transition'-or@($intent.event.receipts).Count-ne0-or[int]$intent.event.sequence-ne[int]$Normalization.intent.event.sequence+1){
        throw 'Historical compatibility legacy-v1 successor identity or shape is invalid.'
    }
    $artifacts=@($intent.artifacts)
    $expectedUnitArtifactPath="iteration-units/$ReplacementUnitId.json"
    foreach($artifact in $artifacts){
        Assert-MorphospaceExactPropertySet $artifact @('path','sha256','bytes_base64') @() 'Historical compatibility legacy-v1 successor artifact'
        try{$artifactBytes=[Convert]::FromBase64String([string]$artifact.bytes_base64)}catch{throw 'Historical compatibility legacy-v1 successor artifact is not valid base64.'}
        if([Convert]::ToBase64String($artifactBytes)-cne[string]$artifact.bytes_base64-or(Get-HscHashBytes $artifactBytes)-cne[string]$artifact.sha256){throw 'Historical compatibility legacy-v1 successor artifact hash is invalid.'}
    }
    if([string]$artifacts[0].path-cne$expectedUnitArtifactPath){throw 'Historical compatibility legacy-v1 successor first artifact is not the replacement unit.'}
    $replacementArtifact=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$artifacts[0].bytes_base64)) 'Historical compatibility legacy-v1 replacement artifact'
    Test-HscSchema $replacementArtifact 'iteration-unit.schema.json' 'Historical compatibility legacy-v1 replacement artifact'
    if([string]$replacementArtifact.unit_id-cne$ReplacementUnitId-or[string]$replacementArtifact.project_id-cne[string]$intent.event.project_id-or
       [string]$replacementArtifact.status-cne'active'-or[string]$artifacts[1].path-cne[string]$replacementArtifact.source_composition.lock_path){
        throw 'Historical compatibility legacy-v1 successor replacement artifact identity is invalid.'
    }
    $sourceArtifact=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$artifacts[1].bytes_base64)) 'Historical compatibility legacy-v1 source-composition artifact'
    Test-HscSchema $sourceArtifact 'source-composition-lock.schema.json' 'Historical compatibility legacy-v1 source-composition artifact'
    if([string]$sourceArtifact.project_id-cne[string]$intent.event.project_id-or[string]$sourceArtifact.unit_id-cne$ReplacementUnitId-or[string]$sourceArtifact.status-cne'locked'){
        throw 'Historical compatibility legacy-v1 successor source-composition artifact identity is invalid.'
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$intent.event.timestamp))
    Test-HscSchema $intent.event 'iteration-event.schema.json' 'Historical compatibility legacy-v1 successor event'
    $oldUnit=$Normalization.replacement_snapshot.document
    if([string]$intent.pre.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $Normalization.intent.target_state)-or
       [string]$intent.expected.state_sha256-cne[string]$intent.pre.state.sha256-or
       [string]$intent.pre.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $oldUnit)-or[string]$intent.expected.unit_sha256-cne[string]$intent.pre.unit.sha256-or
       [string]$intent.expected.event_tail_id-cne[string]$Normalization.intent.event.event_id-or
       [string]$intent.expected.events_sha256-cnotmatch'^[0-9a-f]{64}$'-or[int64]$intent.expected.events_length-lt1){
        throw 'Historical compatibility legacy-v1 successor preimage is detached from the normalization target.'
    }
    $expectedTargetState=Copy-HscDocument $Normalization.intent.target_state
    $expectedTargetState.current_unit=$ReplacementUnitId
    $expectedTargetState.last_event_id=$eventId
    $expectedTargetState.plan_revision=[int]$expectedTargetState.plan_revision+1
    if((Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document)-cne[string]$intent.target.state.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document)-cne(Get-MorphospaceCanonicalJsonSha256 $expectedTargetState)-or
       (Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document)-cne[string]$intent.target.unit.sha256-or
       [string]$intent.target.state.document.current_unit-cne$ReplacementUnitId-or
       [string]$intent.target.state.document.last_event_id-cne$eventId-or
       [string]$intent.target.state.document.project_id-cne[string]$intent.event.project_id-or
       [string]$intent.target.unit.document.unit_id-cne$oldId-or
       (Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document)-cne(Get-MorphospaceCanonicalJsonSha256 $oldUnit)){
        throw 'Historical compatibility legacy-v1 successor target projection is invalid.'
    }
    Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Historical compatibility legacy-v1 successor completion'
    Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Historical compatibility legacy-v1 successor completion intent'
    if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or[string]$completion.transaction_id-cne$transactionId-or
       [string]$completion.status-cne'committed'-or[string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$intentRelative-or
       [string]$completion.intent.schema-cne[string]$intent.schema-or[string]$completion.intent.sha256-cne[string]$intentSnapshot.sha256-or
       [string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256-or
       [string]$completion.event_id-cne$eventId){throw 'Historical compatibility legacy-v1 successor completion is detached from its intent.'}
    if((Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))-lt(Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))){throw 'Historical compatibility legacy-v1 successor completion precedes its intent.'}
    $liveRow=@($Normalization.live_rows|Where-Object{[string]$_.document.event_id-ceq$eventId})
    if($liveRow.Count-ne1){throw 'Historical compatibility legacy-v1 successor event is missing or ambiguous in the live ledger.'}
    Assert-HscSameDocument $intent.event $liveRow[0].document 'Historical compatibility legacy-v1 successor event'
    [pscustomobject][ordered]@{
        transition=[pscustomobject][ordered]@{intent=$intent;completion=$completion};event_id=$eventId;sequence=[int]$Row.document.sequence
        intent_path=$intentRelative;intent_sha256=$intentSnapshot.sha256;completion_path=$completionRelative;completion_sha256=$completionSnapshot.sha256
    }
}

function Get-HscHistoricalEvidence {
    param([string]$Workspace,[string]$OldUnitId,[string]$ReplacementUnitId,[string]$NormalizationId,[switch]$AllowPendingAcceptedTailProjection)
    $normalization = Get-HscNormalizationEvidence $Workspace $NormalizationId
    $project = Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace 'project.spec.json' -RequireLeaf) '' 'Historical compatibility project'
    $state = Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace 'workspace.state.json' -RequireLeaf) '' 'Historical compatibility live state'
    $oldPath = "iteration-units/$OldUnitId.json"
    $replacementPath = "iteration-units/$ReplacementUnitId.json"
    $old = Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $oldPath -RequireLeaf) '' 'Historical compatibility old unit'
    $replacement = Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $replacementPath -RequireLeaf) '' 'Historical compatibility replacement unit'
    foreach ($unit in @($old.document,$replacement.document)) {
        Test-HscSchema $unit 'iteration-unit.schema.json' 'Historical compatibility historical unit'
        if (@('active','validating') -cnotcontains [string]$unit.status) { throw 'Historical compatibility is limited to active or validating historical unit documents.' }
    }
    if ([string]$project.document.project_id -cne [string]$state.document.project_id -or [string]$old.document.project_id -cne [string]$project.document.project_id -or
        [string]$replacement.document.project_id -cne [string]$project.document.project_id -or [string]$old.document.unit_id -cne $OldUnitId -or
        [string]$replacement.document.unit_id -cne $ReplacementUnitId) { throw 'Historical compatibility project or unit identities disagree.' }
    $legacy = $normalization.prior_tail
    $expectedLegacyId = Get-MorphospaceSupersessionEventId -OldUnitId $OldUnitId -ReplacementUnitId $ReplacementUnitId
    if ([string]$legacy.document.event_id -cne $expectedLegacyId -or [string]$legacy.document.unit_id -cne $OldUnitId -or
        [string]$legacy.document.project_id -cne [string]$project.document.project_id -or [string]$legacy.document.event_type -cne 'state-transition' -or
        @($legacy.document.receipts).Count -ne 0 -or [string]$normalization.intent.pre_state.current_unit -cne $ReplacementUnitId -or
        [string]$normalization.intent.pre_state.last_event_id -cne $expectedLegacyId) {
        throw 'Historical compatibility legacy supersession is not the exact normalized predecessor transition.'
    }
    $legacyTransaction = "$expectedLegacyId-transition"
    foreach ($kind in @('intent','completion')) {
        $path = Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$legacyTransaction.$kind.json"
        if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) { throw 'Historical compatibility refuses to replace or coexist with a historical supersession transaction artifact.' }
    }
    if ([int]$normalization.intent.event.sequence -ne [int]$legacy.document.sequence+1) { throw 'Historical compatibility normalization is not immediately after the legacy supersession.' }

    $rows = @($normalization.live_rows)
    $successorRows = @($rows | Where-Object {
        [int]$_.document.sequence -eq [int]$normalization.intent.event.sequence+1 -and
        [string]$_.document.unit_id -ceq $ReplacementUnitId -and
        ([string]$_.document.event_id).StartsWith("$ReplacementUnitId-superseded-by-",[StringComparison]::Ordinal)
    })
    if ($successorRows.Count -ne 1) { throw 'Historical compatibility requires exactly one immediate legacy-v1 successor supersession.' }
    $successorRow = $successorRows[0]
    $acceptedUnitId = ([string]$successorRow.document.event_id).Substring("$ReplacementUnitId-superseded-by-".Length)
    $acceptedPath = "iteration-units/$acceptedUnitId.json"
    $successor = Get-HscLegacyV1SupersessionBinding $Workspace $successorRow $replacementPath $acceptedUnitId $normalization
    $acceptedRows = @($rows | Where-Object {
        [int]$_.document.sequence -gt [int]$successorRow.document.sequence -and [string]$_.document.unit_id -ceq $acceptedUnitId -and
        [string]$_.document.event_type -ceq 'state-transition' -and [string]$_.document.event_id -cmatch ('^'+[regex]::Escape($acceptedUnitId)+'-accepted-[0-9]{4,}$')
    })
    if ($acceptedRows.Count -ne 1) { throw 'Historical compatibility requires exactly one authenticated accepted endpoint.' }
    $acceptedRow = $acceptedRows[0]
    $accepted = Get-HscTransitionBinding $Workspace $acceptedRow $acceptedPath -AllowPendingTailProjection:$AllowPendingAcceptedTailProjection
    if ([string]$accepted.transition.intent.target.unit.document.status -cne 'accepted' -or
        [string]$accepted.transition.intent.target.unit.document.unit_id -cne $acceptedUnitId -or
        $null -ne $accepted.transition.intent.target.state.document.current_unit -or
        [string]$accepted.transition.intent.target.state.document.last_event_id -cne [string]$acceptedRow.document.event_id) {
        throw 'Historical compatibility accepted endpoint projection is invalid.'
    }
    $acceptedSnapshot = Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $Workspace $acceptedPath -RequireLeaf) '' 'Historical compatibility accepted endpoint unit'
    Assert-HscSameDocument $accepted.transition.intent.target.unit.document $acceptedSnapshot.document 'Historical compatibility accepted endpoint unit'
    [pscustomobject][ordered]@{
        project=$project;state=$state;old=$old;replacement=$replacement;normalization=$normalization;legacy=$legacy
        successor=$successor;successor_row=$successorRow;accepted=$accepted;accepted_row=$acceptedRow;accepted_unit_id=$acceptedUnitId;accepted_snapshot=$acceptedSnapshot
    }
}

function New-MorphospaceHistoricalSupersessionCompatibility {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$OldUnitId,
        [Parameter(Mandatory)][string]$ReplacementUnitId,
        [Parameter(Mandatory)][string]$NormalizationId,
        [Parameter(Mandatory)][string]$CompatibilityId,
        [string]$Timestamp = ''
    )
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $evidence = Get-HscHistoricalEvidence $workspace $OldUnitId $ReplacementUnitId $NormalizationId
    if ($null -ne $evidence.state.document.current_unit -or $null -ne $evidence.state.document.next_ready_unit -or
        [string]$evidence.state.document.last_event_id -cne [string]$evidence.accepted_row.document.event_id -or
        [string]$evidence.accepted_row.document.event_id -cne [string]$evidence.normalization.live_rows[-1].document.event_id) {
        throw 'Historical compatibility builder requires the accepted endpoint as the idle live ledger tail.'
    }
    if ($CompatibilityId -cnotmatch '^[a-z0-9][a-z0-9-]{1,111}$' -or $CompatibilityId.Contains('-superseded-by-',[StringComparison]::Ordinal)) {
        throw 'Historical compatibility ID is not canonical or collides with supersession syntax.'
    }
    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    $timestampValue = Test-MorphospaceStrictUtcTimestamp $Timestamp
    $tailTimestamp = ConvertFrom-MorphospaceInvariantTimestamp ([string]$evidence.accepted_row.document.timestamp)
    if ($timestampValue -lt $tailTimestamp) { throw 'Historical compatibility timestamp precedes the accepted ledger tail.' }
    $normalization = $evidence.normalization
    $successor = $evidence.successor
    $accepted = $evidence.accepted
    $document = [pscustomobject][ordered]@{
        schema=$script:HscSchema;compatibility_id=$CompatibilityId;created_at=$Timestamp;project_id=[string]$evidence.project.document.project_id
        old_unit=[pscustomobject][ordered]@{unit_id=$OldUnitId;path="iteration-units/$OldUnitId.json";raw_sha256=$evidence.old.sha256;document_sha256=Get-MorphospaceCanonicalJsonSha256 $evidence.old.document;status=[string]$evidence.old.document.status}
        replacement_unit=[pscustomobject][ordered]@{unit_id=$ReplacementUnitId;path="iteration-units/$ReplacementUnitId.json";raw_sha256=$evidence.replacement.sha256;document_sha256=Get-MorphospaceCanonicalJsonSha256 $evidence.replacement.document;status=[string]$evidence.replacement.document.status}
        accepted_unit=[pscustomobject][ordered]@{unit_id=[string]$evidence.accepted_unit_id;path="iteration-units/$([string]$evidence.accepted_unit_id).json";raw_sha256=$evidence.accepted_snapshot.sha256;document_sha256=Get-MorphospaceCanonicalJsonSha256 $evidence.accepted_snapshot.document;status='accepted'}
        legacy_supersession=[pscustomobject][ordered]@{
            event_id=[string]$evidence.legacy.document.event_id;sequence=[int]$evidence.legacy.document.sequence
            event_document_sha256=Get-MorphospaceCanonicalJsonSha256 $evidence.legacy.document;event_line_sha256=[string]$evidence.legacy.line_sha256
            normalized_prefix_sha256=[string]$normalization.intent.target.normalized_prefix_sha256;normalized_prefix_length=[int64]$normalization.intent.target.normalized_prefix_length
        }
        normalization=[pscustomobject][ordered]@{
            event_id=$NormalizationId;sequence=[int]$normalization.intent.event.sequence
            intent_path="receipts/transactions/$NormalizationId-normalization.intent.json";intent_sha256=[string]$normalization.intent_snapshot.sha256
            completion_path="receipts/transactions/$NormalizationId-normalization.completion.json";completion_sha256=[string]$normalization.completion_snapshot.sha256
            receipt_path=[string]$normalization.intent.paths.receipt;receipt_sha256=[string]$normalization.receipt_snapshot.sha256
        }
        successor_supersession=[pscustomobject][ordered]@{
            event_id=[string]$successor.event_id;sequence=[int]$successor.sequence;accepted_unit_id=[string]$evidence.accepted_unit_id;intent_schema='rusty.morphospace.workflow.transition_ledger_intent.v1'
            intent_path=[string]$successor.intent_path;intent_sha256=[string]$successor.intent_sha256
            completion_path=[string]$successor.completion_path;completion_sha256=[string]$successor.completion_sha256
        }
        accepted_endpoint=[pscustomobject][ordered]@{
            event_id=[string]$accepted.event_id;sequence=[int]$accepted.sequence
            intent_path=[string]$accepted.intent_path;intent_sha256=[string]$accepted.intent_sha256
            completion_path=[string]$accepted.completion_path;completion_sha256=[string]$accepted.completion_sha256
        }
        expected=[pscustomobject][ordered]@{
            project_sha256=Get-MorphospaceCanonicalJsonSha256 $evidence.project.document;state_sha256=Get-MorphospaceCanonicalJsonSha256 $evidence.state.document
            old_unit_sha256=Get-MorphospaceCanonicalJsonSha256 $evidence.old.document;old_unit_raw_sha256=[string]$evidence.old.sha256
            events_sha256=Get-HscHashBytes $normalization.live_bytes;events_length=[int64]$normalization.live_bytes.LongLength;event_tail_id=[string]$evidence.accepted_row.document.event_id
        }
        compatibility_event=[pscustomobject][ordered]@{event_id=$CompatibilityId;sequence=[int]$evidence.accepted_row.document.sequence+1;timestamp=$Timestamp;receipt_path="receipts/$CompatibilityId.json"}
        guarantees=[pscustomobject][ordered]@{
            historical_files_created=$false;historical_files_rewritten=$false;old_unit_bytes_preserved=$true;replacement_unit_bytes_preserved=$true
            state_change_limited_to_last_event_id=$true;git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false
        }
        status='compatible'
    }
    Test-HscSchema $document 'historical-supersession-compatibility-v1.schema.json' 'Historical supersession compatibility receipt'
    $document
}

function Read-MorphospaceHistoricalSupersessionCompatibility {
    param([Parameter(Mandatory)][string]$Path)
    Read-HscJsonSnapshot $Path 'historical-supersession-compatibility-v1.schema.json' 'Historical supersession compatibility receipt'
}

function Assert-HscReceiptEvidence {
    param([object]$Receipt,[object]$Evidence)
    $normalization=$Evidence.normalization;$successor=$Evidence.successor;$accepted=$Evidence.accepted
    $normalizationTransactionId = "$([string]$normalization.normalization_id)-normalization"
    $normalizationIntentPath = "receipts/transactions/$normalizationTransactionId.intent.json"
    $normalizationCompletionPath = "receipts/transactions/$normalizationTransactionId.completion.json"
    $normalizationReceiptPath = "receipts/$([string]$normalization.normalization_id).json"
    if ([string]$Receipt.project_id -cne [string]$Evidence.project.document.project_id -or
        [string]$Receipt.old_unit.unit_id -cne [string]$Evidence.old.document.unit_id -or [string]$Receipt.replacement_unit.unit_id -cne [string]$Evidence.replacement.document.unit_id -or
        [string]$Receipt.accepted_unit.unit_id -cne [string]$Evidence.accepted_unit_id -or
        [string]$Receipt.old_unit.raw_sha256 -cne [string]$Evidence.old.sha256 -or [string]$Receipt.replacement_unit.raw_sha256 -cne [string]$Evidence.replacement.sha256 -or
        [string]$Receipt.accepted_unit.raw_sha256 -cne [string]$Evidence.accepted_snapshot.sha256 -or
        [string]$Receipt.old_unit.document_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $Evidence.old.document) -or
        [string]$Receipt.replacement_unit.document_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $Evidence.replacement.document) -or
        [string]$Receipt.accepted_unit.document_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $Evidence.accepted_snapshot.document) -or
        [string]$Receipt.legacy_supersession.event_id -cne [string]$Evidence.legacy.document.event_id -or [int]$Receipt.legacy_supersession.sequence -ne [int]$Evidence.legacy.document.sequence -or
        [string]$Receipt.legacy_supersession.event_document_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $Evidence.legacy.document) -or
        [string]$Receipt.legacy_supersession.event_line_sha256 -cne [string]$Evidence.legacy.line_sha256 -or
        [string]$Receipt.legacy_supersession.normalized_prefix_sha256 -cne [string]$normalization.intent.target.normalized_prefix_sha256 -or
        [int64]$Receipt.legacy_supersession.normalized_prefix_length -ne [int64]$normalization.intent.target.normalized_prefix_length -or
        [string]$Receipt.normalization.intent_path -cne $normalizationIntentPath -or
        [string]$Receipt.normalization.completion_path -cne $normalizationCompletionPath -or
        [string]$Receipt.normalization.receipt_path -cne $normalizationReceiptPath) {
        throw 'Historical supersession compatibility unit or legacy-event binding drifted.'
    }
    foreach ($pair in @(
        [pscustomobject]@{receipt=$Receipt.normalization;event_id=$normalization.normalization_id;sequence=[int]$normalization.intent.event.sequence;intent=$normalization.intent_snapshot;completion=$normalization.completion_snapshot;receipt_snapshot=$normalization.receipt_snapshot},
        [pscustomobject]@{receipt=$Receipt.successor_supersession;event_id=$successor.event_id;sequence=$successor.sequence;intent_path=$successor.intent_path;intent=[pscustomobject]@{sha256=$successor.intent_sha256};completion_path=$successor.completion_path;completion=[pscustomobject]@{sha256=$successor.completion_sha256};receipt_snapshot=$null},
        [pscustomobject]@{receipt=$Receipt.accepted_endpoint;event_id=$accepted.event_id;sequence=$accepted.sequence;intent_path=$accepted.intent_path;intent=[pscustomobject]@{sha256=$accepted.intent_sha256};completion_path=$accepted.completion_path;completion=[pscustomobject]@{sha256=$accepted.completion_sha256};receipt_snapshot=$null}
    )) {
        if ([string]$pair.receipt.event_id -cne [string]$pair.event_id -or [int]$pair.receipt.sequence -ne [int]$pair.sequence -or
            [string]$pair.receipt.intent_sha256 -cne [string]$pair.intent.sha256 -or [string]$pair.receipt.completion_sha256 -cne [string]$pair.completion.sha256 -or
            ($null-ne$pair.PSObject.Properties['intent_path']-and[string]$pair.receipt.intent_path-cne[string]$pair.intent_path) -or
            ($null-ne$pair.PSObject.Properties['completion_path']-and[string]$pair.receipt.completion_path-cne[string]$pair.completion_path)) {
            throw 'Historical supersession compatibility transaction binding drifted.'
        }
        if ($null -ne $pair.receipt_snapshot -and [string]$pair.receipt.receipt_sha256 -cne [string]$pair.receipt_snapshot.sha256) {
            throw 'Historical supersession compatibility normalization receipt binding drifted.'
        }
    }
    if ([string]$Receipt.successor_supersession.accepted_unit_id -cne [string]$Evidence.accepted_unit_id -or
        [string]$Receipt.successor_supersession.intent_schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1') { throw 'Historical supersession compatibility accepted-unit or legacy schema identity drifted.' }
}

function Test-MorphospaceHistoricalSupersessionCompatibility {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [ValidateSet('PreApply','PostApply')][string]$Mode = 'PreApply'
    )
    $workspace=(Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $snapshot=Read-MorphospaceHistoricalSupersessionCompatibility $ReceiptPath
    $receipt=$snapshot.document
    $evidence=Get-HscHistoricalEvidence $workspace ([string]$receipt.old_unit.unit_id) ([string]$receipt.replacement_unit.unit_id) ([string]$receipt.normalization.event_id)
    Assert-HscReceiptEvidence $receipt $evidence
    if ([string]$receipt.expected.project_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $evidence.project.document) -or
        [string]$receipt.expected.old_unit_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $evidence.old.document) -or
        [string]$receipt.expected.old_unit_raw_sha256 -cne [string]$evidence.old.sha256) { throw 'Historical supersession compatibility expected project or old-unit binding drifted.' }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$receipt.created_at))
    if ([string]$receipt.compatibility_event.event_id -cne [string]$receipt.compatibility_id -or [string]$receipt.compatibility_event.timestamp -cne [string]$receipt.created_at -or
        [string]$receipt.compatibility_event.receipt_path -cne "receipts/$([string]$receipt.compatibility_id).json" -or
        [int]$receipt.compatibility_event.sequence -ne [int]$evidence.accepted_row.document.sequence+1) { throw 'Historical supersession compatibility event contract drifted.' }
    if ((Test-MorphospaceStrictUtcTimestamp ([string]$receipt.created_at)) -lt (ConvertFrom-MorphospaceInvariantTimestamp ([string]$evidence.accepted_row.document.timestamp))) {
        throw 'Historical supersession compatibility event precedes its accepted endpoint.'
    }
    if ($Mode -ceq 'PreApply') {
        if ($null -ne $evidence.state.document.current_unit -or $null -ne $evidence.state.document.next_ready_unit -or
            [string]$evidence.state.document.last_event_id -cne [string]$receipt.expected.event_tail_id -or
            [string]$evidence.state.document.last_event_id -cne [string]$evidence.accepted_row.document.event_id -or
            [string]$receipt.expected.state_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $evidence.state.document) -or
            [string]$receipt.expected.events_sha256 -cne (Get-HscHashBytes $evidence.normalization.live_bytes) -or
            [int64]$receipt.expected.events_length -ne [int64]$evidence.normalization.live_bytes.LongLength -or
            [string]$evidence.normalization.live_rows[-1].document.event_id -cne [string]$receipt.expected.event_tail_id) {
            throw 'Historical supersession compatibility pre-apply state or ledger CAS drifted.'
        }
        $eventCollision=@($evidence.normalization.live_rows|Where-Object{[string]$_.document.event_id-ceq[string]$receipt.compatibility_id})
        if($eventCollision.Count-ne0){throw 'Historical supersession compatibility event already exists before apply.'}
    } else {
        $transition=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId "$([string]$receipt.compatibility_id)-transition" `
            -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$receipt.old_unit.path) -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail
        $intent=$transition.intent
        if ([string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v5' -or
            [string]$intent.pre.state.sha256 -cne [string]$receipt.expected.state_sha256 -or [string]$intent.pre.unit.sha256 -cne [string]$receipt.expected.old_unit_sha256 -or
            [string]$intent.pre_unit_raw.sha256 -cne [string]$receipt.expected.old_unit_raw_sha256 -or
            [string]$intent.expected.events_sha256 -cne [string]$receipt.expected.events_sha256 -or [int64]$intent.expected.events_length -ne [int64]$receipt.expected.events_length -or
            [string]$intent.expected.event_tail_id -cne [string]$receipt.expected.event_tail_id -or @($intent.artifacts).Count -ne 1 -or
            [string]$intent.artifacts[0].path -cne [string]$receipt.compatibility_event.receipt_path -or [string]$intent.artifacts[0].sha256 -cne [string]$snapshot.sha256) {
            throw 'Historical supersession compatibility action transaction detached from its receipt preimages.'
        }
        Assert-HscSameDocument $evidence.old.document $intent.target.unit.document 'Historical supersession compatibility action target unit'
        Assert-HscStateTailOnly $intent.target.state.document $evidence.state.document ([string]$receipt.compatibility_id) 'Historical supersession compatibility live state'
        $preState=Copy-HscDocument $intent.target.state.document;$preState.last_event_id=[string]$receipt.expected.event_tail_id
        if((Get-MorphospaceCanonicalJsonSha256 $preState)-cne[string]$receipt.expected.state_sha256){throw 'Historical supersession compatibility action changed state beyond last_event_id.'}
        $transitionEvent=$intent.event
        if([string]$transitionEvent.event_id-cne[string]$receipt.compatibility_id-or[int]$transitionEvent.sequence-ne[int]$receipt.compatibility_event.sequence-or
           [string]$transitionEvent.timestamp-cne[string]$receipt.created_at-or[string]$transitionEvent.project_id-cne[string]$receipt.project_id-or
           [string]$transitionEvent.unit_id-cne[string]$receipt.old_unit.unit_id-or[string]$transitionEvent.event_type-cne'state-transition'-or
           [string]$transitionEvent.summary-cne$script:HscSummary-or@($transitionEvent.receipts).Count-ne1-or[string]$transitionEvent.receipts[0]-cne[string]$receipt.compatibility_event.receipt_path){
            throw 'Historical supersession compatibility action event drifted.'
        }
    }
    [pscustomobject][ordered]@{receipt=$receipt;sha256=$snapshot.sha256;evidence=$evidence;live_state=$evidence.state.document;old_unit=$evidence.old.document}
}

function Test-MorphospaceHistoricalSupersessionCompatibilityPending {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ReceiptPath)
    $workspace=(Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $snapshot=Read-MorphospaceHistoricalSupersessionCompatibility $ReceiptPath
    $receipt=$snapshot.document
    $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$([string]$receipt.compatibility_id)-transition.intent.json" -RequireLeaf
    $intent=Read-HscJsonSnapshot $intentPath '' 'Pending historical supersession compatibility intent'
    $candidate=$intent.document
    $transactionId="$([string]$receipt.compatibility_id)-transition"
    $completionPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.completion.json"
    if([IO.File]::Exists($completionPath)){throw 'Pending historical supersession compatibility already has a completion.'}
    Assert-MorphospaceExactPropertySet $candidate @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status','pre_unit_raw') @() 'Pending historical supersession compatibility intent'
    Assert-MorphospaceExactPropertySet $candidate.pre @('state','unit') @() 'Pending historical supersession compatibility preimage'
    Assert-MorphospaceExactPropertySet $candidate.target @('state','unit') @() 'Pending historical supersession compatibility target'
    Assert-MorphospaceExactPropertySet $candidate.expected @('state_sha256','unit_sha256','event_tail_id','events_sha256','events_length') @() 'Pending historical supersession compatibility expected boundary'
    foreach($projection in @('state','unit')){
        Assert-MorphospaceExactPropertySet $candidate.$projection @('path') @() "Pending historical supersession compatibility $projection path"
        Assert-MorphospaceExactPropertySet $candidate.pre.$projection @('sha256') @() "Pending historical supersession compatibility pre-$projection"
        Assert-MorphospaceExactPropertySet $candidate.target.$projection @('sha256','document') @() "Pending historical supersession compatibility target-$projection"
    }
    Assert-MorphospaceExactPropertySet $candidate.events @('path') @() 'Pending historical supersession compatibility events path'
    Assert-MorphospaceExactPropertySet $candidate.pre_unit_raw @('path','sha256') @() 'Pending historical supersession compatibility raw unit binding'
    if([string]$candidate.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v5'-or
       [string]$candidate.transaction_id-cne$transactionId-or[string]$candidate.status-cne'prepared'-or
       [string]$candidate.state.path-cne'workspace.state.json'-or[string]$candidate.unit.path-cne[string]$receipt.old_unit.path-or[string]$candidate.events.path-cne'iteration-events.jsonl'-or
       [string]$candidate.pre.state.sha256-cne[string]$receipt.expected.state_sha256-or[string]$candidate.expected.state_sha256-cne[string]$receipt.expected.state_sha256-or
       [string]$candidate.pre.unit.sha256-cne[string]$receipt.expected.old_unit_sha256-or[string]$candidate.expected.unit_sha256-cne[string]$receipt.expected.old_unit_sha256-or
       [string]$candidate.pre_unit_raw.path-cne[string]$receipt.old_unit.path-or[string]$candidate.pre_unit_raw.sha256-cne[string]$receipt.expected.old_unit_raw_sha256-or
       [string]$candidate.expected.events_sha256-cne[string]$receipt.expected.events_sha256-or[int64]$candidate.expected.events_length-ne[int64]$receipt.expected.events_length-or
       [string]$candidate.expected.event_tail_id-cne[string]$receipt.expected.event_tail_id){
        throw 'Pending historical supersession compatibility intent is detached from the reviewed input.'
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$candidate.created_at))
    if((Get-MorphospaceCanonicalJsonSha256 $candidate.target.unit.document)-cne[string]$candidate.target.unit.sha256-or
       [string]$candidate.target.unit.sha256-cne[string]$receipt.expected.old_unit_sha256){
        throw 'Pending historical supersession compatibility target unit is not the preserved old unit.'
    }
    $preState=Copy-HscDocument $candidate.target.state.document
    if([string]$preState.last_event_id-cne[string]$receipt.compatibility_id){throw 'Pending historical supersession compatibility target state does not own its proof event.'}
    $preState.last_event_id=[string]$receipt.expected.event_tail_id
    if((Get-MorphospaceCanonicalJsonSha256 $preState)-cne[string]$receipt.expected.state_sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $candidate.target.state.document)-cne[string]$candidate.target.state.sha256){
        throw 'Pending historical supersession compatibility target state changes more than last_event_id.'
    }
    $expectedEvent=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1';event_id=[string]$receipt.compatibility_id;sequence=[int]$receipt.compatibility_event.sequence
        timestamp=[string]$receipt.compatibility_event.timestamp;project_id=[string]$receipt.project_id;unit_id=[string]$receipt.old_unit.unit_id
        event_type='state-transition';summary=$script:HscSummary;receipts=@([string]$receipt.compatibility_event.receipt_path)
    }
    if((Get-MorphospaceCanonicalJsonSha256 $candidate.event)-cne(Get-MorphospaceCanonicalJsonSha256 $expectedEvent)){
        throw 'Pending historical supersession compatibility event differs from the reviewed proof.'
    }
    $artifacts=@($candidate.artifacts)
    if($artifacts.Count-ne1){throw 'Pending historical supersession compatibility must own exactly one artifact.'}
    $artifact=$artifacts[0]
    Assert-MorphospaceExactPropertySet $artifact @('path','sha256','bytes_base64') @() 'Pending historical supersession compatibility artifact'
    if([string]$artifact.path-cne[string]$receipt.compatibility_event.receipt_path-or[string]$artifact.sha256-cne[string]$snapshot.sha256-or
       [string]$artifact.bytes_base64-cne[Convert]::ToBase64String($snapshot.bytes)){
        throw 'Pending historical supersession compatibility does not byte-own the reviewed receipt.'
    }
    $liveStateSnapshot=Read-HscJsonSnapshot (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf) '' 'Pending historical supersession compatibility live state'
    $liveStateHash=Get-MorphospaceCanonicalJsonSha256 $liveStateSnapshot.document
    if($liveStateHash-cne[string]$receipt.expected.state_sha256-and$liveStateHash-cne[string]$candidate.target.state.sha256){
        throw 'Pending historical supersession compatibility live state is not an allowed preimage or target.'
    }
    $eventBytes=Get-HscCanonicalFileBytes $expectedEvent
    $liveBytes=[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf))
    $ledgerApplied=$false
    if($liveBytes.LongLength-eq[int64]$receipt.expected.events_length){
        if((Get-HscHashBytes $liveBytes)-cne[string]$receipt.expected.events_sha256){throw 'Pending historical supersession compatibility ledger preimage drifted.'}
    }elseif($liveBytes.LongLength-eq[int64]$receipt.expected.events_length+$eventBytes.LongLength){
        $prefix=[byte[]]::new([int]$receipt.expected.events_length);[Array]::Copy($liveBytes,0,$prefix,0,$prefix.Length)
        $suffix=[byte[]]::new($eventBytes.Length);[Array]::Copy($liveBytes,$prefix.Length,$suffix,0,$suffix.Length)
        if((Get-HscHashBytes $prefix)-cne[string]$receipt.expected.events_sha256-or[Convert]::ToHexString($suffix)-cne[Convert]::ToHexString($eventBytes)){
            throw 'Pending historical supersession compatibility ledger suffix differs from its exact proof event.'
        }
        $ledgerApplied=$true
    }else{throw 'Pending historical supersession compatibility ledger is outside its allowed forward-repair boundary.'}
    $artifactPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$receipt.compatibility_event.receipt_path)
    $artifactApplied=[IO.File]::Exists($artifactPath)
    if($artifactApplied-and(Get-MorphospaceFileSha256 $artifactPath)-cne[string]$snapshot.sha256){throw 'Pending historical supersession compatibility installed receipt bytes drifted.'}
    $stateApplied=$liveStateHash-ceq[string]$candidate.target.state.sha256
    if(($stateApplied-or$ledgerApplied)-and-not$artifactApplied){throw 'Pending historical supersession compatibility advanced beyond its missing receipt artifact.'}
    if($ledgerApplied-and-not$stateApplied){throw 'Pending historical supersession compatibility ledger advanced before its target state.'}
    $evidence=Get-HscHistoricalEvidence $workspace ([string]$receipt.old_unit.unit_id) ([string]$receipt.replacement_unit.unit_id) ([string]$receipt.normalization.event_id) -AllowPendingAcceptedTailProjection:($stateApplied-and-not$ledgerApplied)
    Assert-HscReceiptEvidence $receipt $evidence
    if((Get-MorphospaceCanonicalJsonSha256 $candidate.target.unit.document)-cne(Get-MorphospaceCanonicalJsonSha256 $evidence.old.document)-or
       [string]$receipt.expected.state_sha256-cne[string]$evidence.accepted.transition.intent.target.state.sha256){
        throw 'Pending historical supersession compatibility detached the preserved unit or accepted state endpoint.'
    }
    [pscustomobject][ordered]@{receipt=$receipt;sha256=$snapshot.sha256;intent=$candidate}
}

function Get-MorphospaceHistoricalSupersessionCompatibilityMap {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ProjectId)
    $workspace=(Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $ledger=[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf))
    $rows=@(Read-HscLedgerRows $ledger 'Historical supersession compatibility map ledger')
    $map=@{}
    foreach($row in @($rows|Where-Object{[string]$_.document.summary-ceq$script:HscSummary})){
        if([string]$row.document.project_id-cne$ProjectId-or[string]$row.document.event_type-cne'state-transition'-or@($row.document.receipts).Count-ne1){throw 'Historical supersession compatibility map event is malformed.'}
        $relative=[string]$row.document.receipts[0]
        $validated=Test-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $workspace -ReceiptPath (Resolve-MorphospaceWorkspacePath $workspace $relative -RequireLeaf) -Mode PostApply
        $oldId=[string]$validated.receipt.old_unit.unit_id
        if($map.ContainsKey($oldId)){throw "Historical supersession compatibility unit '$oldId' has more than one proof."}
        $map[$oldId]=[pscustomobject][ordered]@{
            receipt=$validated.receipt;old_unit_id=$oldId;replacement_unit_id=[string]$validated.receipt.replacement_unit.unit_id
            event_id=[string]$validated.receipt.legacy_supersession.event_id;sequence=[int]$validated.receipt.legacy_supersession.sequence
            old_document_sha256=[string]$validated.receipt.old_unit.document_sha256;replacement_document_sha256=[string]$validated.receipt.replacement_unit.document_sha256
            transaction_kind='absent'
        }
        $replacementId=[string]$validated.receipt.replacement_unit.unit_id
        if($map.ContainsKey($replacementId)){throw "Historical supersession compatibility unit '$replacementId' has more than one proof."}
        $map[$replacementId]=[pscustomobject][ordered]@{
            receipt=$validated.receipt;old_unit_id=$replacementId;replacement_unit_id=[string]$validated.receipt.accepted_unit.unit_id
            event_id=[string]$validated.receipt.successor_supersession.event_id;sequence=[int]$validated.receipt.successor_supersession.sequence
            old_document_sha256=[string]$validated.receipt.replacement_unit.document_sha256;replacement_document_sha256=[string]$validated.receipt.accepted_unit.document_sha256
            transaction_kind='legacy-v1'
        }
    }
    $map
}

Export-ModuleMember -Function New-MorphospaceHistoricalSupersessionCompatibility,Read-MorphospaceHistoricalSupersessionCompatibility,Test-MorphospaceHistoricalSupersessionCompatibility,Test-MorphospaceHistoricalSupersessionCompatibilityPending,Get-MorphospaceHistoricalSupersessionCompatibilityMap
