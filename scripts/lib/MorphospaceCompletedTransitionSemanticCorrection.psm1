Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force

$script:CorrectionSchema = 'rusty.morphospace.workflow.completed_transition_semantic_correction.v1'
$script:CorrectionFault = 'legacy-v1-supersession-event-unit-id-targeted-replacement'
$script:CorrectionEventPrefix = 'completed-transition-semantics-corrected-'
$script:SupersessionDelimiter = '-superseded-by-'

function Get-CorrectionSchemaPath {
    Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas\completed-transition-semantic-correction-v1.schema.json'
}

function Get-CorrectionEventSchemaPath {
    Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas\iteration-event.schema.json'
}

function Get-CorrectionStateSchemaPath {
    param([object]$Document)
    $name = if ([string]$Document.schema -ceq 'rusty.morphospace.workflow.workspace_state.v2') {
        'workspace-state-v2.schema.json'
    } else {
        'workspace-state.schema.json'
    }
    Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "schemas\$name"
}

function Get-CorrectionEventLineBytes {
    param([Parameter(Mandatory = $true)][object]$Event)
    [Text.UTF8Encoding]::new($false).GetBytes(($Event | ConvertTo-Json -Depth 32 -Compress) + "`n")
}

function Get-CorrectionSha256Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Test-CorrectionByteRange {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Value,
        [Parameter(Mandatory = $true)][int64]$Offset,
        [Parameter(Mandatory = $true)][byte[]]$Expected
    )
    if ($Offset -lt 0 -or $Expected.LongLength -gt ($Value.LongLength - $Offset)) { return $false }
    for ($index = 0L; $index -lt $Expected.LongLength; $index++) {
        if ($Value[$Offset + $index] -ne $Expected[$index]) { return $false }
    }
    return $true
}

function Read-CorrectionEventLedgerBytes {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
        [string]$Context = 'iteration event ledger'
    )
    if ($Bytes.LongLength -gt 67108864) { throw "$Context exceeds 64 MiB." }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) {
        throw "$Context contains a UTF-8 BOM."
    }
    if ($Bytes -contains 0) { throw "$Context contains NUL bytes." }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { throw "$Context is not strict UTF-8." }
    $events = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previousTimestamp = $null
    $lines = $text -split "`n", 0
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
        if (-not $line) {
            if ($lineIndex -eq $lines.Count - 1 -and $text.EndsWith("`n")) { continue }
            if ($Bytes.Length -eq 0 -and $lineIndex -eq 0) { continue }
            throw "$Context contains a blank record at line $($lineIndex + 1)."
        }
        $eventBytes = [Text.UTF8Encoding]::new($false).GetBytes($line)
        $event = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $eventBytes -Context "$Context line $($lineIndex + 1)"
        if (-not (Test-Json -Json ($event | ConvertTo-Json -Depth 32 -Compress) -SchemaFile (Get-CorrectionEventSchemaPath))) {
            throw "$Context line $($lineIndex + 1) is not an exact v1 iteration event."
        }
        if (-not $seen.Add([string]$event.event_id)) { throw "$Context repeats event '$([string]$event.event_id)'." }
        if ([int]$event.sequence -ne $events.Count + 1) { throw "$Context sequence is not contiguous at line $($lineIndex + 1)." }
        try { $timestamp = ConvertFrom-MorphospaceInvariantTimestamp ([string]$event.timestamp) }
        catch { throw "$Context timestamp is invalid at line $($lineIndex + 1)." }
        if ($null -ne $previousTimestamp -and $timestamp -lt $previousTimestamp) {
            throw "$Context timestamp regresses at line $($lineIndex + 1)."
        }
        $previousTimestamp = $timestamp
        $events.Add($event)
    }
    [pscustomobject]@{
        bytes = $Bytes
        length = [int64]$Bytes.LongLength
        sha256 = Get-CorrectionSha256Bytes -Bytes $Bytes
        events = @($events.ToArray())
        tail_id = if ($events.Count) { [string]$events[$events.Count - 1].event_id } else { $null }
    }
}

function Read-CorrectionEventLedger {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { throw "Iteration event ledger is missing: $Path" }
    Read-CorrectionEventLedgerBytes -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Get-CorrectionBoundJson {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Binding,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$Binding.path) -RequireLeaf
    if ((Get-MorphospaceFileSha256 $path) -cne [string]$Binding.sha256) { throw "$Context hash mismatch." }
    [pscustomobject]@{ path=$path; document=(Read-MorphospaceProtocolJson $path); raw_bytes=[IO.File]::ReadAllBytes($path) }
}

function Assert-CorrectionDocumentBinding {
    param(
        [Parameter(Mandatory = $true)][object]$Binding,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][string]$ExpectedId,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ([string]$Binding.path -cne $ExpectedPath -or
        [string]$Binding.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $Binding.document) -or
        [string]$Binding.document.unit_id -cne $ExpectedId) {
        throw "$Context binding is inconsistent."
    }
    # These units are immutable historical evidence. Their nested instruction
    # surfaces may require a project-owned historical adoption under today's
    # WorkflowContracts, so do not reinterpret their exact bytes through the
    # latest full iteration-unit schema here. Bind the stable unit envelope;
    # WorkflowContracts validates/adopts the complete document independently
    # before it considers this correction projection.
    if ([string]$Binding.document.schema -cne 'rusty.morphospace.workflow.iteration_unit.v1' -or
        [string]$Binding.document.project_id -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$' -or
        [string]$Binding.document.status -notin @('active','validating')) {
        throw "$Context document lacks the strict historical unit identity/status envelope."
    }
}

function Assert-CorrectionOriginalIntent {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][object]$OriginalEvent,
        [Parameter(Mandatory = $true)][byte[]]$OriginalLedgerBytes
    )
    $eventId = [string]$OriginalEvent.event_id
    $transactionId = "$eventId-transition"
    $expectedIntentPath = "receipts/transactions/$transactionId.intent.json"
    $expectedCompletionPath = "receipts/transactions/$transactionId.completion.json"
    if ([string]$Receipt.original_transition.intent.path -cne $expectedIntentPath -or
        [string]$Receipt.original_transition.completion.path -cne $expectedCompletionPath) {
        throw 'Original transition artifact paths are not canonically derived from its event.'
    }
    $intentResult = Get-CorrectionBoundJson $WorkspaceRoot $Receipt.original_transition.intent 'Original transition intent'
    $completionResult = Get-CorrectionBoundJson $WorkspaceRoot $Receipt.original_transition.completion 'Original transition completion'
    $intent = $intentResult.document
    $completion = $completionResult.document
    Assert-MorphospaceExactPropertySet $intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') @() 'Original transition intent'
    if ([string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
        [string]$intent.transaction_id -cne $transactionId -or [string]$intent.status -cne 'prepared') {
        throw 'Original transition must be one exact completed legacy-v1 intent.'
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))
    if (@($intent.artifacts).Count -ne 0 -or @($Receipt.semantic_correction.original_intent_artifacts).Count -ne 0) {
        throw 'Correction v1 requires the original transition intent artifacts to be empty.'
    }
    foreach ($reference in @(
        [pscustomobject]@{ value=$intent.state; path='workspace.state.json'; label='state' },
        [pscustomobject]@{ value=$intent.unit; path=[string]$Receipt.original_transition.replacement_unit.path; label='unit' },
        [pscustomobject]@{ value=$intent.events; path='iteration-events.jsonl'; label='events' }
    )) {
        Assert-MorphospaceExactPropertySet $reference.value @('path') @() "Original transition $([string]$reference.label) reference"
        if ([string]$reference.value.path -cne [string]$reference.path) { throw "Original transition $([string]$reference.label) path differs." }
    }
    foreach ($projection in @('state','unit')) {
        Assert-MorphospaceExactPropertySet $intent.pre.$projection @('sha256') @() "Original transition pre-$projection"
        Assert-MorphospaceExactPropertySet $intent.target.$projection @('sha256','document') @() "Original transition target-$projection"
        if ([string]$intent.pre.$projection.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$intent.target.$projection.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $intent.target.$projection.document)) {
            throw "Original transition $projection hashes are inconsistent."
        }
    }
    if ((Get-MorphospaceCanonicalJsonSha256 $intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $OriginalEvent) -or
        (Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document) -cne [string]$Receipt.original_transition.state.sha256) {
        throw 'Original intent event or target state differs from retained correction evidence.'
    }
    # The current active replacement unit may have accumulated reviewed unit
    # planning detail after the malformed transition completed. Preserve and
    # CAS-bind its current exact bytes separately; the immutable original
    # intent/completion continue to authenticate their own target-unit bytes.
    if ([string]$intent.target.unit.document.schema -cne 'rusty.morphospace.workflow.iteration_unit.v1' -or
        [string]$intent.target.unit.document.unit_id -cne [string]$Receipt.semantic_correction.replacement_unit_id -or
        [string]$intent.target.unit.document.project_id -cne [string]$Receipt.project_id -or
        [string]$intent.target.unit.document.status -notin @('active','validating')) {
        throw 'Original intent target unit lacks the derived replacement identity/status envelope.'
    }
    Assert-MorphospaceExactPropertySet $intent.expected @('state_sha256','unit_sha256','event_tail_id','events_sha256','events_length') @() 'Original transition expected boundary'
    if ([string]$intent.expected.state_sha256 -cne [string]$intent.pre.state.sha256 -or
        [string]$intent.expected.unit_sha256 -cne [string]$intent.pre.unit.sha256 -or
        [int64]$intent.expected.events_length -lt 0 -or [int64]$intent.expected.events_length -ge $OriginalLedgerBytes.LongLength) {
        throw 'Original transition pre-append length is invalid.'
    }
    $preBytes = [byte[]]::new([int]$intent.expected.events_length)
    if ($preBytes.Length) { [Array]::Copy($OriginalLedgerBytes, 0, $preBytes, 0, $preBytes.Length) }
    if ((Get-CorrectionSha256Bytes $preBytes) -cne [string]$intent.expected.events_sha256) {
        throw 'Original transition pre-append ledger hash is inconsistent.'
    }
    $preSnapshot = Read-CorrectionEventLedgerBytes -Bytes $preBytes -Context 'Original transition pre-append ledger'
    if ([string]$preSnapshot.tail_id -cne [string]$intent.expected.event_tail_id -or
        [int]$OriginalEvent.sequence -ne $preSnapshot.events.Count + 1) {
        throw 'Original transition predecessor or sequence is inconsistent.'
    }
    $eventLine = Get-CorrectionEventLineBytes $OriginalEvent
    if ($OriginalLedgerBytes.LongLength -ne $preBytes.LongLength + $eventLine.LongLength -or
        -not (Test-CorrectionByteRange -Value $OriginalLedgerBytes -Offset $preBytes.LongLength -Expected $eventLine)) {
        throw 'Original transition event is not the exact sole append to its authenticated prefix.'
    }
    Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Original transition completion'
    Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Original completion intent binding'
    if ([string]$completion.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or
        [string]$completion.transaction_id -cne $transactionId -or [string]$completion.status -cne 'committed' -or
        [string]$completion.event_id -cne $eventId -or [string]$completion.intent.role -cne 'transition-ledger-intent' -or
        [string]$completion.intent.path -cne $expectedIntentPath -or [string]$completion.intent.schema -cne [string]$intent.schema -or
        [string]$completion.intent.sha256 -cne (Get-MorphospaceFileSha256 $intentResult.path) -or
        [string]$completion.state_sha256 -cne [string]$intent.target.state.sha256 -or
        [string]$completion.unit_sha256 -cne [string]$intent.target.unit.sha256) {
        throw 'Original completion-to-intent chain is inconsistent.'
    }
    $created = Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at)
    $completed = Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at)
    if ($completed -lt $created) { throw 'Original completion predates its intent.' }
    [pscustomobject]@{ intent=$intent; completion=$completion }
}

function New-CorrectionEventFromReceipt {
    param([Parameter(Mandatory = $true)][object]$Receipt)
    $event = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = [string]$Receipt.correction_event.event_id
        sequence = [int]$Receipt.correction_event.sequence
        timestamp = [string]$Receipt.correction_event.timestamp
        project_id = [string]$Receipt.project_id
        unit_id = [string]$Receipt.correction_event.unit_id
        event_type = 'state-transition'
        summary = "Authenticated the old-unit semantics of completed legacy supersession '$([string]$Receipt.original_transition.event.event_id)' without rewriting history."
        receipts = @([string]$Receipt.correction_event.receipt_path)
    }
    # The transition intent is written in canonical key order and Complete
    # rereads that intent before appending the event. Return that same ordered
    # projection so torn-suffix authentication is byte-exact.
    $canonicalBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $event))
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $canonicalBytes -Context 'derived correction event'
}

function New-CorrectionTargetStateFromReceipt {
    param([Parameter(Mandatory = $true)][object]$Receipt)
    $target = $Receipt.original_transition.state.document | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $target.last_event_id = [string]$Receipt.correction_event.event_id
    $target
}

function Assert-CorrectionReceiptCore {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][byte[]]$ReceiptBytes,
        [ValidateSet('PreApply','Projection','Pending')][string]$Mode,
        [AllowNull()][object]$CorrectionEvent
    )
    if (-not (Test-Json -Json ([Text.UTF8Encoding]::new($false, $true).GetString($ReceiptBytes)) -SchemaFile (Get-CorrectionSchemaPath))) {
        throw 'Completed-transition semantic correction does not satisfy its strict schema.'
    }
    if ([string]$Receipt.schema -cne $script:CorrectionSchema -or [string]$Receipt.fault_kind -cne $script:CorrectionFault) {
        throw 'Completed-transition semantic correction schema or fault kind differs.'
    }
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $original = $Receipt.original_transition
    $semantic = $Receipt.semantic_correction
    $correction = $Receipt.correction_event
    $eventId = [string]$original.event.event_id
    $replacementId = [string]$semantic.replacement_unit_id
    $oldId = [string]$semantic.effective_old_unit_id
    if ([string]$semantic.recorded_unit_id -cne $replacementId -or $oldId -ceq $replacementId -or
        $oldId.Contains($script:SupersessionDelimiter, [StringComparison]::Ordinal) -or
        $replacementId.Contains($script:SupersessionDelimiter, [StringComparison]::Ordinal) -or
        $eventId -cne "$oldId$script:SupersessionDelimiter$replacementId") {
        throw 'Correction semantic endpoints are not the exact derived old-to-replacement rendering.'
    }
    if ($eventId.IndexOf($script:SupersessionDelimiter, [StringComparison]::Ordinal) -ne
        $eventId.LastIndexOf($script:SupersessionDelimiter, [StringComparison]::Ordinal)) {
        throw 'Correction original event identity contains an ambiguous repeated delimiter.'
    }
    $expectedSequence = [int]$original.event.sequence + 1
    $expectedCorrectionId = "$script:CorrectionEventPrefix$('{0:d4}' -f $expectedSequence)"
    $expectedReceiptPath = "receipts/$expectedCorrectionId.json"
    if ([string]$Receipt.receipt_id -cne $expectedCorrectionId -or
        [string]$correction.event_id -cne $expectedCorrectionId -or [int]$correction.sequence -ne $expectedSequence -or
        [string]$correction.receipt_path -cne $expectedReceiptPath -or [string]$correction.unit_id -cne $replacementId) {
        throw 'Correction event identity, sequence, receipt path, or unit is not fully derived.'
    }
    $correctionTimestamp = Test-MorphospaceStrictUtcTimestamp ([string]$correction.timestamp)
    if (@($semantic.original_receipts).Count -ne 0 -or @($semantic.original_intent_artifacts).Count -ne 0) {
        throw 'Correction v1 permits no original receipts or intent artifacts.'
    }
    if ([string]$original.event_ledger.path -cne 'iteration-events.jsonl' -or
        [string]$original.event_ledger.tail_event_id -cne $eventId) {
        throw 'Correction original event-ledger binding is inconsistent.'
    }
    if ([string]$original.state.path -cne 'workspace.state.json' -or
        [string]$original.state.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $original.state.document) -or
        [string]$original.state.document.project_id -cne [string]$Receipt.project_id -or
        [string]$original.state.document.current_unit -cne $replacementId -or
        [string]$original.state.document.last_event_id -cne $eventId) {
        throw 'Correction retained target-state binding is inconsistent.'
    }
    if (-not (Test-Json -Json ($original.state.document | ConvertTo-Json -Depth 100) -SchemaFile (Get-CorrectionStateSchemaPath $original.state.document))) {
        throw 'Correction retained target state is schema-invalid.'
    }
    Assert-CorrectionDocumentBinding $original.old_unit "iteration-units/$oldId.json" $oldId 'Correction old unit'
    Assert-CorrectionDocumentBinding $original.replacement_unit "iteration-units/$replacementId.json" $replacementId 'Correction replacement unit'
    if ([string]$original.old_unit.document.project_id -cne [string]$Receipt.project_id -or
        [string]$original.replacement_unit.document.project_id -cne [string]$Receipt.project_id -or
        @('active','validating') -cnotcontains [string]$original.old_unit.document.status -or
        @('active','validating') -cnotcontains [string]$original.replacement_unit.document.status) {
        throw 'Correction requires project-matched active/validating old and replacement units.'
    }
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $currentBytes = [IO.File]::ReadAllBytes($eventsPath)
    $prefixLength = [int64]$original.event_ledger.length
    if ($prefixLength -gt $currentBytes.LongLength) { throw 'Current event ledger is shorter than the correction binding.' }
    $prefixBytes = [byte[]]::new([int]$prefixLength)
    [Array]::Copy($currentBytes, 0, $prefixBytes, 0, $prefixLength)
    if ((Get-CorrectionSha256Bytes $prefixBytes) -cne [string]$original.event_ledger.sha256) {
        throw 'Current event-ledger prefix differs from the correction binding.'
    }
    if ($Mode -eq 'PreApply' -and $currentBytes.LongLength -ne $prefixLength) {
        throw 'Pre-application correction requires the original event to remain the ledger tail.'
    }
    $prefixSnapshot = Read-CorrectionEventLedgerBytes -Bytes $prefixBytes -Context 'Correction-bound original event ledger'
    if ([string]$prefixSnapshot.tail_id -cne $eventId -or $prefixSnapshot.events.Count -ne [int]$original.event.sequence) {
        throw 'Correction-bound original event is not the exact prefix tail.'
    }
    $originalEvent = $prefixSnapshot.events[-1]
    if ((Get-MorphospaceCanonicalJsonSha256 $originalEvent) -cne [string]$original.event.sha256 -or
        [string]$originalEvent.schema -cne 'rusty.morphospace.workflow.iteration_event.v1' -or
        [string]$originalEvent.project_id -cne [string]$Receipt.project_id -or
        [string]$originalEvent.event_type -cne 'state-transition' -or [string]$originalEvent.unit_id -cne $replacementId -or
        @($originalEvent.receipts).Count -ne 0) {
        throw 'Correction original event does not have the exact supported legacy fault shape.'
    }
    if (@($semantic.original_receipts).Count -ne @($originalEvent.receipts).Count) {
        throw 'Correction original receipt projection differs from the retained event.'
    }
    $originalTimestamp = ConvertFrom-MorphospaceInvariantTimestamp ([string]$originalEvent.timestamp)
    if ($correctionTimestamp -lt $originalTimestamp) { throw 'Correction event timestamp precedes the original transition.' }
    $chain = Assert-CorrectionOriginalIntent $workspace $Receipt $originalEvent $prefixBytes

    $oldPath = Resolve-MorphospaceWorkspacePath $workspace ([string]$original.old_unit.path) -RequireLeaf
    $replacementPath = Resolve-MorphospaceWorkspacePath $workspace ([string]$original.replacement_unit.path) -RequireLeaf
    if ((Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $oldPath)) -cne [string]$original.old_unit.sha256) {
        throw 'Current immutable old-unit bytes differ from the correction binding.'
    }
    if ($Mode -eq 'PreApply') {
        $statePath = Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
        if ((Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $statePath)) -cne [string]$original.state.sha256 -or
            (Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $replacementPath)) -cne [string]$original.replacement_unit.sha256) {
            throw 'Current state or replacement unit differs from the correction pre-application binding.'
        }
    }
    $context = [pscustomobject]@{
        receipt = $Receipt
        receipt_bytes = $ReceiptBytes
        receipt_sha256 = Get-CorrectionSha256Bytes $ReceiptBytes
        original_event = $originalEvent
        original_intent = $chain.intent
        original_completion = $chain.completion
        correction_event = New-CorrectionEventFromReceipt $Receipt
        target_state = New-CorrectionTargetStateFromReceipt $Receipt
        target_unit = $original.replacement_unit.document
        old_unit_path = $oldPath
        replacement_unit_path = $replacementPath
    }
    if ($Mode -eq 'Projection') {
        if ($null -eq $CorrectionEvent -or
            (Get-MorphospaceCanonicalJsonSha256 $CorrectionEvent) -cne (Get-MorphospaceCanonicalJsonSha256 $context.correction_event)) {
            throw 'Correction projection event differs from its derived receipt event.'
        }
        $fullSnapshot = Read-CorrectionEventLedgerBytes -Bytes $currentBytes
        if ($fullSnapshot.events.Count -lt [int]$correction.sequence -or
            (Get-MorphospaceCanonicalJsonSha256 $fullSnapshot.events[[int]$correction.sequence - 1]) -cne (Get-MorphospaceCanonicalJsonSha256 $context.correction_event)) {
            throw 'Correction event is absent from its exact ledger position.'
        }
        $correctionLine = Get-CorrectionEventLineBytes $context.correction_event
        if (-not (Test-CorrectionByteRange -Value $currentBytes -Offset $prefixLength -Expected $correctionLine)) {
            throw 'Correction event is not the exact append to the bound original ledger.'
        }
        $statePath = Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
        $currentState = Read-MorphospaceProtocolJson $statePath
        if ([string]$currentState.last_event_id -ceq [string]$context.correction_event.event_id -and
            (Get-MorphospaceCanonicalJsonSha256 $currentState) -cne (Get-MorphospaceCanonicalJsonSha256 $context.target_state)) {
            throw 'Tail correction does not own the exact last_event_id-only state projection.'
        }
    }
    return $context
}

function Read-MorphospaceCompletedTransitionSemanticCorrection {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($fullPath)) { throw "Completed-transition semantic correction is missing: $fullPath" }
    if (([IO.FileInfo]$fullPath).Length -gt 16777216) { throw 'Completed-transition semantic correction exceeds 16 MiB.' }
    $bytes = [IO.File]::ReadAllBytes($fullPath)
    $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context "completed-transition semantic correction '$fullPath'"
    if (-not (Test-Json -Json ([Text.UTF8Encoding]::new($false, $true).GetString($bytes)) -SchemaFile (Get-CorrectionSchemaPath))) {
        throw 'Completed-transition semantic correction does not satisfy its strict schema.'
    }
    [pscustomobject]@{ path=$fullPath; bytes=$bytes; sha256=(Get-CorrectionSha256Bytes $bytes); document=$document }
}

function Test-MorphospaceCompletedTransitionSemanticCorrection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [ValidateSet('PreApply','Projection')][string]$Mode = 'PreApply',
        [AllowNull()][object]$CorrectionEvent
    )
    $snapshot = Read-MorphospaceCompletedTransitionSemanticCorrection $ReceiptPath
    $context = Assert-CorrectionReceiptCore -WorkspaceRoot $WorkspaceRoot -Receipt $snapshot.document -ReceiptBytes $snapshot.bytes -Mode $Mode -CorrectionEvent $CorrectionEvent
    if ($Mode -eq 'Projection') {
        $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
        $expectedReceiptPath = Resolve-MorphospaceWorkspacePath $workspace ([string]$snapshot.document.correction_event.receipt_path) -RequireLeaf
        if (-not $expectedReceiptPath.Equals($snapshot.path, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Installed correction receipt path differs from its canonical projection path.'
        }
        $transactionId = "$([string]$snapshot.document.correction_event.event_id)-transition"
        $intentRelative = "receipts/transactions/$transactionId.intent.json"
        $completionRelative = "receipts/transactions/$transactionId.completion.json"
        $intentPath = Resolve-MorphospaceWorkspacePath $workspace $intentRelative -RequireLeaf
        $completionPath = Resolve-MorphospaceWorkspacePath $workspace $completionRelative -RequireLeaf
        $intent = Read-MorphospaceProtocolJson $intentPath
        $completion = Read-MorphospaceProtocolJson $completionPath
        Assert-MorphospaceExactPropertySet $intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') @() 'Correction transition intent'
        foreach ($reference in @($intent.state,$intent.unit,$intent.events)) {
            Assert-MorphospaceExactPropertySet $reference @('path') @() 'Correction transition path reference'
        }
        foreach ($projection in @('state','unit')) {
            Assert-MorphospaceExactPropertySet $intent.pre.$projection @('sha256') @() "Correction transition pre-$projection"
            Assert-MorphospaceExactPropertySet $intent.target.$projection @('sha256','document') @() "Correction transition target-$projection"
        }
        Assert-MorphospaceExactPropertySet $intent.expected @('state_sha256','unit_sha256','event_tail_id','events_sha256','events_length') @() 'Correction transition expected boundary'
        if ([string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
            [string]$intent.transaction_id -cne $transactionId -or [string]$intent.status -cne 'prepared' -or
            (Get-MorphospaceCanonicalJsonSha256 $intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $context.correction_event) -or
            [string]$intent.state.path -cne 'workspace.state.json' -or
            [string]$intent.unit.path -cne [string]$snapshot.document.original_transition.replacement_unit.path -or
            [string]$intent.events.path -cne 'iteration-events.jsonl' -or
            [string]$intent.pre.state.sha256 -cne [string]$snapshot.document.original_transition.state.sha256 -or
            [string]$intent.pre.unit.sha256 -cne [string]$snapshot.document.original_transition.replacement_unit.sha256 -or
            [string]$intent.expected.state_sha256 -cne [string]$intent.pre.state.sha256 -or
            [string]$intent.expected.unit_sha256 -cne [string]$intent.pre.unit.sha256 -or
            (Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document) -cne (Get-MorphospaceCanonicalJsonSha256 $context.target_state) -or
            (Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document) -cne [string]$snapshot.document.original_transition.replacement_unit.sha256 -or
            [string]$intent.target.state.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document) -or
            [string]$intent.target.unit.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document) -or
            [string]$intent.expected.event_tail_id -cne [string]$snapshot.document.original_transition.event.event_id -or
            [string]$intent.expected.events_sha256 -cne [string]$snapshot.document.original_transition.event_ledger.sha256 -or
            [int64]$intent.expected.events_length -ne [int64]$snapshot.document.original_transition.event_ledger.length) {
            throw 'Correction transition intent differs from the authenticated correction plan.'
        }
        if (@($intent.artifacts).Count -ne 1) { throw 'Correction transition must own exactly one receipt artifact.' }
        $artifact = $intent.artifacts[0]
        Assert-MorphospaceExactPropertySet $artifact @('path','sha256','bytes_base64') @() 'Correction transition receipt artifact'
        if ([string]$artifact.path -cne [string]$snapshot.document.correction_event.receipt_path -or
            [string]$artifact.sha256 -cne $snapshot.sha256 -or
            [string]$artifact.bytes_base64 -cne [Convert]::ToBase64String($snapshot.bytes)) {
            throw 'Correction transition does not byte-own its sole receipt.'
        }
        Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Correction transition completion'
        Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Correction completion intent binding'
        if ([string]$completion.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or
            [string]$completion.transaction_id -cne $transactionId -or [string]$completion.status -cne 'committed' -or
            [string]$completion.event_id -cne [string]$context.correction_event.event_id -or
            [string]$completion.intent.role -cne 'transition-ledger-intent' -or [string]$completion.intent.path -cne $intentRelative -or
            [string]$completion.intent.schema -cne [string]$intent.schema -or [string]$completion.intent.sha256 -cne (Get-MorphospaceFileSha256 $intentPath) -or
            [string]$completion.state_sha256 -cne [string]$intent.target.state.sha256 -or
            [string]$completion.unit_sha256 -cne [string]$intent.target.unit.sha256) {
            throw 'Correction completion-to-intent chain is inconsistent.'
        }
        $intentCreated = Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at)
        $completionCreated = Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at)
        if ($completionCreated -lt $intentCreated) { throw 'Correction completion predates its intent.' }
    }
    return $context
}

function Test-MorphospaceCompletedTransitionSemanticCorrectionPending {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )
    $snapshot = Read-MorphospaceCompletedTransitionSemanticCorrection $ReceiptPath
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $core = Assert-CorrectionReceiptCore -WorkspaceRoot $workspace -Receipt $snapshot.document -ReceiptBytes $snapshot.bytes -Mode Pending -CorrectionEvent $null
    # Validate all immutable original evidence while allowing the correction
    # ledger append/projections to be partially installed.
    $originalLedger = $snapshot.document.original_transition.event_ledger
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace ([string]$originalLedger.path) -RequireLeaf
    $currentBytes = [IO.File]::ReadAllBytes($eventsPath)
    $prefixLength = [int64]$originalLedger.length
    if ($currentBytes.LongLength -lt $prefixLength) { throw 'Pending correction ledger lost its authenticated prefix.' }
    $prefixBytes = [byte[]]::new([int]$prefixLength)
    [Array]::Copy($currentBytes, 0, $prefixBytes, 0, $prefixLength)
    if ((Get-CorrectionSha256Bytes $prefixBytes) -cne [string]$originalLedger.sha256) { throw 'Pending correction ledger prefix changed.' }
    $receipt = $snapshot.document
    $expectedEvent = $core.correction_event
    $eventLine = Get-CorrectionEventLineBytes $expectedEvent
    $suffixLength = [int64]($currentBytes.LongLength - $prefixLength)
    if ($suffixLength -gt $eventLine.LongLength) { throw 'Pending correction ledger has extra bytes beyond its exact event.' }
    if ($suffixLength -gt 0) {
        $expectedSuffix = [byte[]]::new([int]$suffixLength)
        [Array]::Copy($eventLine, 0, $expectedSuffix, 0, $suffixLength)
        if (-not (Test-CorrectionByteRange -Value $currentBytes -Offset $prefixLength -Expected $expectedSuffix)) {
            throw 'Pending correction ledger suffix is not a prefix of its exact event.'
        }
    }
    # Validate the immutable original chain against the authenticated prefix,
    # while permitting a partially appended correction event after that prefix.
    $prefixSnapshot = Read-CorrectionEventLedgerBytes $prefixBytes
    $originalEvent = $prefixSnapshot.events[-1]
    if ((Get-MorphospaceCanonicalJsonSha256 $originalEvent) -cne [string]$receipt.original_transition.event.sha256) { throw 'Pending correction original event changed.' }
    [void](Assert-CorrectionOriginalIntent $workspace $receipt $originalEvent $prefixBytes)
    $transactionId = "$([string]$receipt.correction_event.event_id)-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentPath = Resolve-MorphospaceWorkspacePath $workspace $intentRelative -RequireLeaf
    if ([IO.File]::Exists((Resolve-MorphospaceWorkspacePath $workspace $completionRelative))) {
        throw 'Pending correction already has a completion and is a replay.'
    }
    $intent = Read-MorphospaceProtocolJson $intentPath
    Assert-MorphospaceExactPropertySet $intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') @() 'Pending correction transition intent'
    foreach ($reference in @($intent.state,$intent.unit,$intent.events)) {
        Assert-MorphospaceExactPropertySet $reference @('path') @() 'Pending correction transition path reference'
    }
    foreach ($projection in @('state','unit')) {
        Assert-MorphospaceExactPropertySet $intent.pre.$projection @('sha256') @() "Pending correction transition pre-$projection"
        Assert-MorphospaceExactPropertySet $intent.target.$projection @('sha256','document') @() "Pending correction transition target-$projection"
    }
    Assert-MorphospaceExactPropertySet $intent.expected @('state_sha256','unit_sha256','event_tail_id','events_sha256','events_length') @() 'Pending correction transition expected boundary'
    $targetState = $core.target_state
    if ([string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
        [string]$intent.transaction_id -cne $transactionId -or [string]$intent.status -cne 'prepared' -or
        (Get-MorphospaceCanonicalJsonSha256 $intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $expectedEvent) -or
        [string]$intent.pre.state.sha256 -cne [string]$receipt.original_transition.state.sha256 -or
        [string]$intent.pre.unit.sha256 -cne [string]$receipt.original_transition.replacement_unit.sha256 -or
        [string]$intent.expected.state_sha256 -cne [string]$intent.pre.state.sha256 -or
        [string]$intent.expected.unit_sha256 -cne [string]$intent.pre.unit.sha256 -or
        (Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document) -cne (Get-MorphospaceCanonicalJsonSha256 $targetState) -or
        (Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document) -cne [string]$receipt.original_transition.replacement_unit.sha256 -or
        [string]$intent.target.state.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document) -or
        [string]$intent.target.unit.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document) -or
        [string]$intent.expected.event_tail_id -cne [string]$receipt.original_transition.event.event_id -or
        [string]$intent.expected.events_sha256 -cne [string]$originalLedger.sha256 -or
        [int64]$intent.expected.events_length -ne [int64]$originalLedger.length -or @($intent.artifacts).Count -ne 1) {
        throw 'Pending correction intent differs from the exact receipt plan.'
    }
    $artifact = $intent.artifacts[0]
    Assert-MorphospaceExactPropertySet $artifact @('path','sha256','bytes_base64') @() 'Pending correction receipt artifact'
    if ([string]$artifact.path -cne [string]$receipt.correction_event.receipt_path -or
        [string]$artifact.sha256 -cne $snapshot.sha256 -or
        [string]$artifact.bytes_base64 -cne [Convert]::ToBase64String($snapshot.bytes)) {
        throw 'Pending correction intent does not own the exact sole receipt bytes.'
    }
    $state = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
    $unit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$receipt.original_transition.replacement_unit.path) -RequireLeaf)
    $allowedState = @([string]$receipt.original_transition.state.sha256, (Get-MorphospaceCanonicalJsonSha256 $targetState))
    if ($allowedState -cnotcontains (Get-MorphospaceCanonicalJsonSha256 $state) -or
        (Get-MorphospaceCanonicalJsonSha256 $unit) -cne [string]$receipt.original_transition.replacement_unit.sha256) {
        throw 'Pending correction state or replacement-unit projection is unauthorized.'
    }
    return [pscustomobject]@{ receipt=$receipt; receipt_sha256=$snapshot.sha256; correction_event=$expectedEvent; target_state=$targetState; target_unit=$receipt.original_transition.replacement_unit.document }
}

function New-MorphospaceCompletedTransitionSemanticCorrection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [string]$Timestamp = ''
    )
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $statePath = Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
    $state = Read-MorphospaceProtocolJson $statePath
    $ledgerPath = Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $ledger = Read-CorrectionEventLedger $ledgerPath
    $OriginalEventId = [string]$state.last_event_id
    if ([string]$ledger.tail_id -cne $OriginalEventId -or [string]$state.last_event_id -cne $OriginalEventId) {
        throw 'Correction builder requires the named completed transition to remain both state and ledger tail.'
    }
    $event = $ledger.events[-1]
    if ([string]$event.event_id -cne $OriginalEventId -or [string]$event.schema -cne 'rusty.morphospace.workflow.iteration_event.v1' -or
        [string]$event.event_type -cne 'state-transition' -or @($event.receipts).Count -ne 0) {
        throw 'Correction builder found no supported receipt-free completed legacy-v1 state transition.'
    }
    $replacementId = [string]$state.current_unit
    if ([string]$event.unit_id -cne $replacementId -or $replacementId -notmatch '^[a-z0-9][a-z0-9-]{1,127}$') {
        throw 'Correction builder requires the original event unit_id to target the current replacement.'
    }
    $unitRoot = Resolve-MorphospaceWorkspacePath $workspace 'iteration-units'
    if (-not [IO.Directory]::Exists($unitRoot)) { throw 'Correction builder requires the iteration-units directory.' }
    $oldCandidates = @()
    $replacementCandidates = @()
    foreach ($path in [IO.Directory]::EnumerateFiles($unitRoot, '*.json', [IO.SearchOption]::TopDirectoryOnly)) {
        $candidate = Read-MorphospaceProtocolJson $path
        $candidateId = [string]$candidate.unit_id
        if ($candidateId -ceq $replacementId) { $replacementCandidates += ,([pscustomobject]@{path=$path;document=$candidate}) }
        if ($candidateId -cne $replacementId -and
            -not $candidateId.Contains($script:SupersessionDelimiter, [StringComparison]::Ordinal) -and
            $OriginalEventId -ceq "$candidateId$script:SupersessionDelimiter$replacementId") {
            $oldCandidates += ,([pscustomobject]@{path=$path;document=$candidate})
        }
    }
    if ($oldCandidates.Count -ne 1 -or $replacementCandidates.Count -ne 1) {
        throw 'Correction builder could not derive exactly one old and replacement unit document.'
    }
    $old = $oldCandidates[0]
    $replacement = $replacementCandidates[0]
    if (@('active','validating') -cnotcontains [string]$old.document.status -or
        @('active','validating') -cnotcontains [string]$replacement.document.status) {
        throw 'Correction builder requires active/validating retained old and replacement units.'
    }
    $sequence = [int]$event.sequence + 1
    $correctionId = "$script:CorrectionEventPrefix$('{0:d4}' -f $sequence)"
    if (-not $Timestamp) { $Timestamp = ConvertTo-MorphospaceUtcTimestamp ([DateTimeOffset]::UtcNow) }
    [void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    $transactionId = "$OriginalEventId-transition"
    $oldRelative = [IO.Path]::GetRelativePath($workspace, $old.path).Replace('\','/')
    $replacementRelative = [IO.Path]::GetRelativePath($workspace, $replacement.path).Replace('\','/')
    $receipt = [pscustomobject][ordered]@{
        schema = $script:CorrectionSchema
        receipt_id = $correctionId
        project_id = [string]$state.project_id
        fault_kind = $script:CorrectionFault
        original_transition = [pscustomobject][ordered]@{
            event = [pscustomobject][ordered]@{ event_id=$OriginalEventId; sequence=[int]$event.sequence; sha256=(Get-MorphospaceCanonicalJsonSha256 $event) }
            event_ledger = [pscustomobject][ordered]@{ path='iteration-events.jsonl'; sha256=[string]$ledger.sha256; length=[int64]$ledger.length; tail_event_id=$OriginalEventId }
            state = [pscustomobject][ordered]@{ path='workspace.state.json'; sha256=(Get-MorphospaceCanonicalJsonSha256 $state); document=$state }
            old_unit = [pscustomobject][ordered]@{ path=$oldRelative; sha256=(Get-MorphospaceCanonicalJsonSha256 $old.document); document=$old.document }
            replacement_unit = [pscustomobject][ordered]@{ path=$replacementRelative; sha256=(Get-MorphospaceCanonicalJsonSha256 $replacement.document); document=$replacement.document }
            intent = [pscustomobject][ordered]@{ path="receipts/transactions/$transactionId.intent.json"; sha256=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.intent.json" -RequireLeaf)) }
            completion = [pscustomobject][ordered]@{ path="receipts/transactions/$transactionId.completion.json"; sha256=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.completion.json" -RequireLeaf)) }
        }
        semantic_correction = [pscustomobject][ordered]@{
            recorded_unit_id = $replacementId
            effective_old_unit_id = [string]$old.document.unit_id
            replacement_unit_id = $replacementId
            original_receipts = @()
            original_intent_artifacts = @()
            disposition = 'project-original-event-with-authenticated-old-unit'
        }
        correction_event = [pscustomobject][ordered]@{
            event_id = $correctionId
            sequence = $sequence
            timestamp = $Timestamp
            unit_id = $replacementId
            receipt_path = "receipts/$correctionId.json"
        }
        preservation = [pscustomobject][ordered]@{
            historical_event_bytes_retained = $true
            historical_transaction_bytes_retained = $true
            unit_bytes_retained = $true
            state_change = 'last_event_id-only'
        }
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $receipt) + "`n")
    [void](Assert-CorrectionReceiptCore -WorkspaceRoot $workspace -Receipt $receipt -ReceiptBytes $bytes -Mode PreApply -CorrectionEvent $null)
    return $receipt
}

Export-ModuleMember -Function `
    New-MorphospaceCompletedTransitionSemanticCorrection, `
    Read-MorphospaceCompletedTransitionSemanticCorrection, `
    Test-MorphospaceCompletedTransitionSemanticCorrection, `
    Test-MorphospaceCompletedTransitionSemanticCorrectionPending
