Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force

$script:RecoverySchema = 'rusty.morphospace.workflow.admission_completion_timestamp_recovery.v1'
$script:RecoveryFault = 'admission-completion-precedes-future-intent'
$script:RecoveryEventPrefix = 'admission-completion-timestamp-recovered-'

function Get-AdmissionRecoverySchemaPath {
    Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\admission-completion-timestamp-recovery-v1.schema.json'
}

function Get-AdmissionRecoveryResultSchemaPath {
    Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\admission-completion-timestamp-recovery-result-v1.schema.json'
}

function Get-AdmissionRecoverySha256Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Copy-AdmissionRecoveryDocument {
    param([Parameter(Mandatory = $true)][object]$Document)
    $Document | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String
}

function Test-AdmissionRecoveryBytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.LongLength -ne $Right.LongLength) { return $false }
    for ($index = 0L; $index -lt $Left.LongLength; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Get-AdmissionRecoveryEventLineBytes {
    param([Parameter(Mandatory = $true)][object]$Event)
    [Text.UTF8Encoding]::new($false).GetBytes(($Event | ConvertTo-Json -Depth 32 -Compress) + "`n")
}

function Test-AdmissionRecoveryByteRange {
    param([byte[]]$Value, [int64]$Offset, [byte[]]$Expected)
    if ($Offset -lt 0 -or $Expected.LongLength -gt ($Value.LongLength - $Offset)) { return $false }
    for ($index = 0L; $index -lt $Expected.LongLength; $index++) {
        if ($Value[$Offset + $index] -ne $Expected[$index]) { return $false }
    }
    return $true
}

function Read-AdmissionRecoveryLedgerBytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes, [string]$Context = 'iteration event ledger')
    if ($Bytes.LongLength -gt 67108864) { throw "$Context exceeds 64 MiB." }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) { throw "$Context contains a UTF-8 BOM." }
    if ($Bytes -contains 0) { throw "$Context contains NUL bytes." }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { throw "$Context is not strict UTF-8." }
    $events = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previous = $null
    $lines = $text -split "`n", 0
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
        if (-not $line) {
            if ($lineIndex -eq $lines.Count - 1 -and $text.EndsWith("`n")) { continue }
            if ($Bytes.Length -eq 0 -and $lineIndex -eq 0) { continue }
            throw "$Context contains a blank record at line $($lineIndex + 1)."
        }
        $event = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line)) -Context "$Context line $($lineIndex + 1)"
        if (-not $seen.Add([string]$event.event_id)) { throw "$Context repeats event '$([string]$event.event_id)'." }
        if ([int]$event.sequence -ne $events.Count + 1) { throw "$Context sequence is not contiguous at line $($lineIndex + 1)." }
        $at = Test-MorphospaceStrictUtcTimestamp ([string]$event.timestamp)
        if ($null -ne $previous -and $at -lt $previous) { throw "$Context timestamp regresses at line $($lineIndex + 1)." }
        $previous = $at
        $events.Add($event)
    }
    [pscustomobject]@{
        bytes = $Bytes
        raw_sha256 = Get-AdmissionRecoverySha256Bytes $Bytes
        length = [int64]$Bytes.LongLength
        events = @($events.ToArray())
        tail_id = if ($events.Count) { [string]$events[$events.Count - 1].event_id } else { $null }
    }
}

function Get-AdmissionRecoveryJsonSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Binding,
        [Parameter(Mandatory = $true)][string]$Context,
        [string]$ExpectedPath = '',
        [switch]$PermitLiveMismatch
    )
    if ($ExpectedPath -and [string]$Binding.path -cne $ExpectedPath) { throw "$Context path is not canonically derived." }
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$Binding.path) -RequireLeaf
    $bytes = [IO.File]::ReadAllBytes($path)
    $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context $Context
    $raw = Get-AdmissionRecoverySha256Bytes $bytes
    $canonical = Get-MorphospaceCanonicalJsonSha256 $document
    if (-not $PermitLiveMismatch -and ($raw -cne [string]$Binding.raw_sha256 -or $canonical -cne [string]$Binding.canonical_sha256)) {
        throw "$Context raw or canonical SHA-256 differs from its exact binding."
    }
    [pscustomobject]@{ path=$path; bytes=$bytes; raw_sha256=$raw; canonical_sha256=$canonical; document=$document }
}

function New-AdmissionRecoveryJsonBinding {
    param([string]$WorkspaceRoot, [string]$RelativePath)
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -RequireLeaf
    $bytes = [IO.File]::ReadAllBytes($path)
    $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context "recovery evidence '$RelativePath'"
    [pscustomobject][ordered]@{
        path = $RelativePath
        raw_sha256 = Get-AdmissionRecoverySha256Bytes $bytes
        canonical_sha256 = Get-MorphospaceCanonicalJsonSha256 $document
    }
}

function New-AdmissionRecoveryEvent {
    param([object]$Receipt)
    $event = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = [string]$Receipt.correction_event.event_id
        sequence = [int]$Receipt.correction_event.sequence
        timestamp = [string]$Receipt.correction_event.timestamp
        project_id = [string]$Receipt.project_id
        unit_id = [string]$Receipt.unit_id
        event_type = 'state-transition'
        summary = "Authenticated the exact admission completion timestamp defect for '$([string]$Receipt.admission_id)' while preserving the malformed completion bytes."
        receipts = @([string]$Receipt.correction_event.receipt_path)
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $event))
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'derived admission timestamp recovery event'
}

function New-AdmissionRecoveryTargetState {
    param([object]$State, [string]$EventId)
    $target = Copy-AdmissionRecoveryDocument $State
    $target.last_event_id = $EventId
    $target
}

function Assert-AdmissionRecoveryCore {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][byte[]]$ReceiptBytes,
        [ValidateSet('PreApply','Pending','Projection')][string]$Mode,
        [AllowNull()][object]$CorrectionEvent
    )
    $schemaText = [Text.UTF8Encoding]::new($false, $true).GetString($ReceiptBytes)
    if (-not (Test-Json -Json $schemaText -SchemaFile (Get-AdmissionRecoverySchemaPath))) { throw 'Admission completion timestamp recovery does not satisfy its strict schema.' }
    if ([string]$Receipt.schema -cne $script:RecoverySchema -or [string]$Receipt.fault_kind -cne $script:RecoveryFault) { throw 'Admission recovery schema or fault kind differs.' }

    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $admissionId = [string]$Receipt.admission_id
    $unitId = [string]$Receipt.unit_id
    $originalEventId = "$admissionId-admitted"
    $originalTransactionId = "$originalEventId-transition"
    $sequence = [int]$Receipt.evidence.admission_event.sequence + 1
    $recoveryId = "$script:RecoveryEventPrefix$('{0:d4}' -f $sequence)"
    $recoveryReceiptPath = "receipts/$recoveryId.json"
    if ([string]$Receipt.recovery_id -cne $recoveryId -or
        [string]$Receipt.correction_event.event_id -cne $recoveryId -or
        [int]$Receipt.correction_event.sequence -ne $sequence -or
        [string]$Receipt.correction_event.unit_id -cne $unitId -or
        [string]$Receipt.correction_event.receipt_path -cne $recoveryReceiptPath) {
        throw 'Admission recovery identity, sequence, unit, or receipt path is not fully derived.'
    }

    $requestPath = "local/$admissionId.json"
    $receiptPath = "receipts/$admissionId.json"
    $intentPath = "receipts/transactions/$originalTransactionId.intent.json"
    $completionPath = "receipts/transactions/$originalTransactionId.completion.json"
    $unitPath = "iteration-units/$unitId.json"
    $request = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.admission_request 'Admission request' $requestPath
    $admissionReceipt = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.admission_receipt 'Admission receipt' $receiptPath
    $intent = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.admission_intent 'Admission intent' $intentPath
    $completion = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.malformed_completion 'Malformed admission completion' $completionPath
    $project = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.project 'Project specification' 'project.spec.json'
    $lock = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.feature_lock 'Feature lock' 'feature.lock.json'
    $unit = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.unit 'Admitted unit' $unitPath
    $state = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.state 'Workspace state' 'workspace.state.json' -PermitLiveMismatch:($Mode -ne 'PreApply')

    $requestDocument = $request.document
    $intentDocument = $intent.document
    $completionDocument = $completion.document
    $unitDocument = $unit.document
    $stateDocument = $state.document
    if ([string]$requestDocument.schema -cne 'rusty.morphospace.workflow.development_unit_admission.v1' -or
        [string]$requestDocument.admission_kind -cne 'ordinary' -or
        [string]$requestDocument.admission_id -cne $admissionId -or
        [string]$requestDocument.project_id -cne [string]$Receipt.project_id -or
        [string]$requestDocument.unit_id -cne $unitId) {
        throw 'Recovery evidence is not one exact ordinary development-unit admission.'
    }
    if (-not (Test-AdmissionRecoveryBytesEqual $request.bytes $admissionReceipt.bytes)) { throw 'Installed admission receipt is not byte-identical to the inspected admission request.' }
    if ((Get-MorphospaceCanonicalJsonSha256 $requestDocument.unit) -cne $unit.canonical_sha256 -or
        [string]$unitDocument.schema -cne 'rusty.morphospace.workflow.iteration_unit.v1' -or
        [string]$unitDocument.project_id -cne [string]$Receipt.project_id -or
        [string]$unitDocument.unit_id -cne $unitId -or [string]$unitDocument.status -cne 'proposed') {
        throw 'Admitted unit differs from the exact ordinary admission target.'
    }

    $repreparationPath = [string]$requestDocument.preparation.recovery_receipt_path
    $preparationPath = [string]$requestDocument.preparation.receipt_path
    $sourcePath = [string]$requestDocument.expected.source_composition_path
    $mapPath = [string]$requestDocument.expected.repository_map_path
    $repreparation = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.repreparation_receipt 'Repreparation receipt' $repreparationPath
    $preparation = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.preparation_receipt 'Preparation receipt' $preparationPath
    $source = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.source_composition 'Source composition' $sourcePath
    $map = Get-AdmissionRecoveryJsonSnapshot $workspace $Receipt.evidence.repository_map 'Repository map' $mapPath
    if ([string]$repreparation.document.schema -cne 'rusty.morphospace.workflow.development_envelope_repreparation_receipt.v1' -or
        [string]$repreparation.document.project_id -cne [string]$Receipt.project_id -or
        [string]$repreparation.document.replacement_unit_id -cne $unitId -or
        [string]$repreparation.document.preparation_id -cne [string]$requestDocument.preparation.preparation_id -or
        [string]$repreparation.document.source_composition.path -cne $sourcePath -or
        [string]$repreparation.document.source_composition.sha256 -cne $source.raw_sha256) {
        throw 'Repreparation receipt does not derive the admitted replacement/source envelope.'
    }
    if ([string]$preparation.document.schema -cne 'rusty.morphospace.workflow.development_envelope_preparation_receipt.v1' -or
        [string]$preparation.document.project_id -cne [string]$Receipt.project_id -or
        [string]$preparation.document.preparation_id -cne [string]$requestDocument.preparation.preparation_id -or
        [string]$preparation.document.source_composition.path -cne $sourcePath -or
        [string]$preparation.document.source_composition.sha256 -cne $source.canonical_sha256) {
        throw 'Preparation receipt does not derive the admitted project/source envelope.'
    }
    if ([string]$requestDocument.preparation.receipt_sha256 -cne $preparation.raw_sha256 -or
        [string]$requestDocument.preparation.recovery_receipt_sha256 -cne $repreparation.raw_sha256 -or
        [string]$requestDocument.preparation.source_composition_sha256 -cne $source.raw_sha256 -or
        [string]$requestDocument.expected.source_composition_sha256 -cne $source.raw_sha256 -or
        [string]$requestDocument.expected.repository_map_sha256 -cne $map.raw_sha256 -or
        [string]$requestDocument.expected.project_sha256 -cne $project.canonical_sha256 -or
        [string]$requestDocument.expected.feature_lock_sha256 -cne $lock.canonical_sha256) {
        throw 'Admission request no longer binds its exact preparation, source, map, project, or lock evidence.'
    }

    Assert-MorphospaceExactPropertySet $intentDocument @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') @() 'Malformed admission intent'
    if ([string]$intentDocument.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
        [string]$intentDocument.transaction_id -cne $originalTransactionId -or [string]$intentDocument.status -cne 'prepared' -or
        [string]$intentDocument.state.path -cne 'workspace.state.json' -or [string]$intentDocument.unit.path -cne $unitPath -or
        [string]$intentDocument.events.path -cne 'iteration-events.jsonl' -or @($intentDocument.artifacts).Count -ne 1) {
        throw 'Malformed admission intent is not the exact supported admission transaction shape.'
    }
    $artifact = $intentDocument.artifacts[0]
    Assert-MorphospaceExactPropertySet $artifact @('path','sha256','bytes_base64') @() 'Admission receipt artifact'
    if ([string]$artifact.path -cne $receiptPath -or [string]$artifact.sha256 -cne $admissionReceipt.raw_sha256 -or
        [string]$artifact.bytes_base64 -cne [Convert]::ToBase64String($admissionReceipt.bytes)) {
        throw 'Admission intent does not byte-own the exact admission receipt.'
    }
    if ((Get-MorphospaceCanonicalJsonSha256 $intentDocument.target.unit.document) -cne $unit.canonical_sha256 -or
        [string]$intentDocument.target.unit.sha256 -cne $unit.canonical_sha256 -or
        [string]$intentDocument.pre.unit.sha256 -cne ('0' * 64) -or
        (Get-MorphospaceCanonicalJsonSha256 $intentDocument.target.state.document) -cne [string]$intentDocument.target.state.sha256) {
        throw 'Admission target state or unit is not fully derivable from the retained transaction.'
    }

    $ledgerPath = Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $currentLedgerBytes = [IO.File]::ReadAllBytes($ledgerPath)
    $boundLength = [int64]$Receipt.evidence.event_ledger.length
    if ($currentLedgerBytes.LongLength -lt $boundLength) { throw 'Current event ledger is shorter than the recovery binding.' }
    $boundLedgerBytes = [byte[]]::new([int]$boundLength)
    [Array]::Copy($currentLedgerBytes, 0, $boundLedgerBytes, 0, $boundLength)
    if ((Get-AdmissionRecoverySha256Bytes $boundLedgerBytes) -cne [string]$Receipt.evidence.event_ledger.raw_sha256) { throw 'Current event-ledger prefix differs from the recovery binding.' }
    if ($Mode -eq 'PreApply' -and $currentLedgerBytes.LongLength -ne $boundLength) { throw 'Pre-application admission recovery requires the malformed admission event to remain the ledger tail.' }
    $boundLedger = Read-AdmissionRecoveryLedgerBytes $boundLedgerBytes 'Recovery-bound event ledger'
    if ([string]$boundLedger.tail_id -cne $originalEventId -or [string]$Receipt.evidence.event_ledger.tail_event_id -cne $originalEventId -or
        $boundLedger.events.Count -ne [int]$Receipt.evidence.admission_event.sequence) {
        throw 'Recovery-bound admission event is not the exact ledger tail.'
    }
    $originalEvent = $boundLedger.events[-1]
    if ([string]$originalEvent.event_id -cne $originalEventId -or [string]$originalEvent.project_id -cne [string]$Receipt.project_id -or
        [string]$originalEvent.unit_id -cne $unitId -or [string]$originalEvent.event_type -cne 'state-transition' -or
        @($originalEvent.receipts).Count -ne 1 -or [string]$originalEvent.receipts[0] -cne $receiptPath -or
        (Get-MorphospaceCanonicalJsonSha256 $originalEvent) -cne [string]$Receipt.evidence.admission_event.canonical_sha256 -or
        [string]$Receipt.evidence.event_ledger.tail_event_sha256 -cne [string]$Receipt.evidence.admission_event.canonical_sha256) {
        throw 'Admission event differs from the one exact supported admission transaction.'
    }
    if ((Get-MorphospaceCanonicalJsonSha256 $intentDocument.event) -cne (Get-MorphospaceCanonicalJsonSha256 $originalEvent)) { throw 'Admission intent event differs from the retained ledger event.' }
    $prefixLength = [int64]$intentDocument.expected.events_length
    if ($prefixLength -lt 0 -or $prefixLength -ge $boundLength) { throw 'Admission intent predecessor ledger length is invalid.' }
    $preBytes = [byte[]]::new([int]$prefixLength)
    if ($preBytes.Length) { [Array]::Copy($boundLedgerBytes, 0, $preBytes, 0, $preBytes.Length) }
    $preLedger = Read-AdmissionRecoveryLedgerBytes $preBytes 'Admission predecessor event ledger'
    $eventLine = Get-AdmissionRecoveryEventLineBytes $originalEvent
    if ((Get-AdmissionRecoverySha256Bytes $preBytes) -cne [string]$intentDocument.expected.events_sha256 -or
        [string]$preLedger.tail_id -cne [string]$intentDocument.expected.event_tail_id -or
        $boundLength -ne $prefixLength + $eventLine.LongLength -or
        -not (Test-AdmissionRecoveryByteRange $boundLedgerBytes $prefixLength $eventLine)) {
        throw 'Admission event is not the exact sole append to its authenticated predecessor ledger.'
    }

    $targetState = $intentDocument.target.state.document
    $preState = Copy-AdmissionRecoveryDocument $targetState
    $preState.last_event_id = [string]$intentDocument.expected.event_tail_id
    if ((Get-MorphospaceCanonicalJsonSha256 $preState) -cne [string]$intentDocument.pre.state.sha256 -or
        [string]$intentDocument.expected.state_sha256 -cne [string]$intentDocument.pre.state.sha256 -or
        [string]$targetState.last_event_id -cne $originalEventId -or $null -ne $targetState.current_unit -or
        $null -ne $targetState.next_ready_unit) {
        throw 'Admission state transition is not the exact last-event-only proposed-unit admission projection.'
    }
    if ([string]$requestDocument.expected.state_sha256 -cne [string]$intentDocument.pre.state.sha256 -or
        [string]$intentDocument.target.state.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $targetState)) {
        throw 'Admission request, intent preimage, and target-state chain differs.'
    }
    $expectedLiveStateHash = if ($Mode -eq 'Projection') { Get-MorphospaceCanonicalJsonSha256 (New-AdmissionRecoveryTargetState $targetState $recoveryId) } else { [string]$intentDocument.target.state.sha256 }
    if ($Mode -eq 'Pending') {
        $allowed = @([string]$intentDocument.target.state.sha256, (Get-MorphospaceCanonicalJsonSha256 (New-AdmissionRecoveryTargetState $targetState $recoveryId)))
        if ($allowed -cnotcontains $state.canonical_sha256) { throw 'Pending recovery state projection is unauthorized.' }
        if ($state.canonical_sha256 -ceq [string]$intentDocument.target.state.sha256 -and $state.raw_sha256 -cne [string]$Receipt.evidence.state.raw_sha256) { throw 'Pending recovery pre-state raw bytes changed.' }
    } elseif ($state.canonical_sha256 -cne $expectedLiveStateHash) {
        throw 'Current workspace state differs from the exact recovery projection.'
    }
    if ($Mode -eq 'PreApply' -and ($state.raw_sha256 -cne [string]$Receipt.evidence.state.raw_sha256 -or $state.canonical_sha256 -cne [string]$Receipt.evidence.state.canonical_sha256)) { throw 'Current workspace state bytes differ from the exact recovery preimage.' }
    if ([string]$stateDocument.project_id -cne [string]$Receipt.project_id) { throw 'Workspace state project differs from the admission recovery.' }

    Assert-MorphospaceExactPropertySet $completionDocument @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Malformed admission completion'
    Assert-MorphospaceExactPropertySet $completionDocument.intent @('role','path','schema','sha256') @() 'Malformed completion intent binding'
    if ([string]$completionDocument.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or
        [string]$completionDocument.transaction_id -cne $originalTransactionId -or [string]$completionDocument.status -cne 'committed' -or
        [string]$completionDocument.event_id -cne $originalEventId -or [string]$completionDocument.intent.role -cne 'transition-ledger-intent' -or
        [string]$completionDocument.intent.path -cne $intentPath -or [string]$completionDocument.intent.schema -cne [string]$intentDocument.schema -or
        [string]$completionDocument.intent.sha256 -cne $intent.raw_sha256 -or
        [string]$completionDocument.state_sha256 -cne [string]$intentDocument.target.state.sha256 -or
        [string]$completionDocument.unit_sha256 -cne [string]$intentDocument.target.unit.sha256) {
        throw 'Malformed completion has another defect besides its timestamp chronology.'
    }
    $intentAt = Test-MorphospaceStrictUtcTimestamp ([string]$intentDocument.created_at)
    $completedAt = Test-MorphospaceStrictUtcTimestamp ([string]$completionDocument.completed_at)
    $eventAt = Test-MorphospaceStrictUtcTimestamp ([string]$originalEvent.timestamp)
    $recoveryAt = Test-MorphospaceStrictUtcTimestamp ([string]$Receipt.chronology.recovery_timestamp)
    if ([string]$Receipt.chronology.intent_created_at -cne [string]$intentDocument.created_at -or
        [string]$Receipt.chronology.malformed_completed_at -cne [string]$completionDocument.completed_at -or
        [string]$Receipt.correction_event.timestamp -cne [string]$Receipt.chronology.recovery_timestamp -or
        $eventAt -ne $intentAt -or $completedAt -ge $intentAt -or $recoveryAt -lt $intentAt) {
        throw 'Recovery chronology is not exactly one completion timestamp preceding its immutable future intent.'
    }
    $now = [DateTimeOffset]::UtcNow
    if ($recoveryAt -gt $now -and $recoveryAt -ne $intentAt) {
        throw 'A future recovery timestamp must equal the immutable future admission intent timestamp.'
    }

    $derivedCorrectionEvent = New-AdmissionRecoveryEvent $Receipt
    $derivedTargetState = New-AdmissionRecoveryTargetState $targetState $recoveryId
    if ($Mode -eq 'Projection') {
        if ($null -eq $CorrectionEvent -or (Get-MorphospaceCanonicalJsonSha256 $CorrectionEvent) -cne (Get-MorphospaceCanonicalJsonSha256 $derivedCorrectionEvent)) { throw 'Admission recovery projection event differs from its receipt.' }
        $suffix = Get-AdmissionRecoveryEventLineBytes $derivedCorrectionEvent
        if ($currentLedgerBytes.LongLength -ne $boundLength + $suffix.LongLength -or -not (Test-AdmissionRecoveryByteRange $currentLedgerBytes $boundLength $suffix)) { throw 'Admission recovery event is not the exact sole append to the malformed admission ledger.' }
    }
    [pscustomobject]@{
        receipt = $Receipt
        receipt_bytes = $ReceiptBytes
        receipt_sha256 = Get-AdmissionRecoverySha256Bytes $ReceiptBytes
        project = $project
        feature_lock = $lock
        state = $state
        unit = $unit
        original_intent = $intent
        malformed_completion = $completion
        ledger_bytes = $currentLedgerBytes
        correction_event = $derivedCorrectionEvent
        target_state = $derivedTargetState
        target_unit = $unitDocument
    }
}

function Read-MorphospaceAdmissionCompletionTimestampRecovery {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { throw "Admission completion timestamp recovery is missing: $full" }
    if (([IO.FileInfo]$full).Length -gt 16777216) { throw 'Admission completion timestamp recovery exceeds 16 MiB.' }
    $bytes = [IO.File]::ReadAllBytes($full)
    $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context "admission completion timestamp recovery '$full'"
    if (-not (Test-Json -Json ([Text.UTF8Encoding]::new($false, $true).GetString($bytes)) -SchemaFile (Get-AdmissionRecoverySchemaPath))) { throw 'Admission completion timestamp recovery does not satisfy its strict schema.' }
    [pscustomobject]@{ path=$full; bytes=$bytes; sha256=(Get-AdmissionRecoverySha256Bytes $bytes); document=$document }
}

function Test-MorphospaceAdmissionCompletionTimestampRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RecoveryPath,
        [ValidateSet('PreApply','Pending','Projection')][string]$Mode = 'PreApply',
        [AllowNull()][object]$CorrectionEvent
    )
    $snapshot = Read-MorphospaceAdmissionCompletionTimestampRecovery $RecoveryPath
    $context = Assert-AdmissionRecoveryCore -WorkspaceRoot $WorkspaceRoot -Receipt $snapshot.document -ReceiptBytes $snapshot.bytes -Mode $Mode -CorrectionEvent $CorrectionEvent
    if ($Mode -eq 'Projection') {
        $canonical = Resolve-MorphospaceWorkspacePath $WorkspaceRoot ([string]$snapshot.document.correction_event.receipt_path) -RequireLeaf
        if (-not $canonical.Equals($snapshot.path, [StringComparison]::OrdinalIgnoreCase)) { throw 'Installed recovery receipt is not at its canonical workspace path.' }
        $transactionId = "$([string]$snapshot.document.correction_event.event_id)-transition"
        $committed = Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$snapshot.document.evidence.unit.path) -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail
        if ((Get-MorphospaceCanonicalJsonSha256 $committed.intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $context.correction_event) -or
            @($committed.intent.artifacts).Count -ne 1 -or [string]$committed.intent.artifacts[0].path -cne [string]$snapshot.document.correction_event.receipt_path -or
            [string]$committed.intent.artifacts[0].sha256 -cne $snapshot.sha256 -or
            [string]$committed.intent.pre_state_raw.sha256 -cne [string]$snapshot.document.evidence.state.raw_sha256 -or
            [string]$committed.intent.pre_unit_raw.sha256 -cne [string]$snapshot.document.evidence.unit.raw_sha256) {
            throw 'Recovery transition does not bind its exact receipt and raw live preimages.'
        }
        $projections = @($committed.intent.additional_projections)
        if ($projections.Count -ne 2 -or [string]$projections[0].path -cne 'feature.lock.json' -or [string]$projections[1].path -cne 'project.spec.json' -or
            [string]$projections[0].pre_raw_sha256 -cne [string]$snapshot.document.evidence.feature_lock.raw_sha256 -or
            [string]$projections[1].pre_raw_sha256 -cne [string]$snapshot.document.evidence.project.raw_sha256 -or
            [string]$projections[0].pre_sha256 -cne [string]$projections[0].target_sha256 -or
            [string]$projections[1].pre_sha256 -cne [string]$projections[1].target_sha256) {
            throw 'Recovery transition does not preserve and raw-bind the exact feature-lock/project projections.'
        }
    }
    $context
}

function New-MorphospaceAdmissionCompletionTimestampRecovery {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [string]$Timestamp = '')
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $statePath = Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
    $state = Read-MorphospaceProtocolJson $statePath
    $ledgerPath = Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $ledgerBytes = [IO.File]::ReadAllBytes($ledgerPath)
    $ledger = Read-AdmissionRecoveryLedgerBytes $ledgerBytes
    $eventId = [string]$state.last_event_id
    if ([string]$ledger.tail_id -cne $eventId -or -not $eventId.EndsWith('-admitted', [StringComparison]::Ordinal)) { throw 'Recovery builder requires the malformed admission event to remain both state and ledger tail.' }
    $admissionId = $eventId.Substring(0, $eventId.Length - '-admitted'.Length)
    $event = $ledger.events[-1]
    $unitId = [string]$event.unit_id
    if ([string]$event.event_type -cne 'state-transition' -or @($event.receipts).Count -ne 1 -or [string]$event.receipts[0] -cne "receipts/$admissionId.json") { throw 'Recovery builder found no exact ordinary admission event at the live tail.' }
    $requestRelative = "local/$admissionId.json"
    $request = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $requestRelative -RequireLeaf)
    $repreparationRelative = [string]$request.preparation.recovery_receipt_path
    $preparationRelative = [string]$request.preparation.receipt_path
    $sourceRelative = [string]$request.expected.source_composition_path
    $mapRelative = [string]$request.expected.repository_map_path
    $intentRelative = "receipts/transactions/$eventId-transition.intent.json"
    $completionRelative = "receipts/transactions/$eventId-transition.completion.json"
    $intent = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $intentRelative -RequireLeaf)
    $completion = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $completionRelative -RequireLeaf)
    if (-not $Timestamp) {
        $now = [DateTimeOffset]::UtcNow
        $intentAt = Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at)
        $Timestamp = ConvertTo-MorphospaceUtcTimestamp $(if ($now -lt $intentAt) { $intentAt } else { $now })
    }
    [void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    $sequence = [int]$event.sequence + 1
    $recoveryId = "$script:RecoveryEventPrefix$('{0:d4}' -f $sequence)"
    $receipt = [pscustomobject][ordered]@{
        schema = $script:RecoverySchema
        recovery_id = $recoveryId
        project_id = [string]$state.project_id
        unit_id = $unitId
        admission_id = $admissionId
        fault_kind = $script:RecoveryFault
        evidence = [pscustomobject][ordered]@{
            admission_request = New-AdmissionRecoveryJsonBinding $workspace $requestRelative
            repreparation_receipt = New-AdmissionRecoveryJsonBinding $workspace $repreparationRelative
            preparation_receipt = New-AdmissionRecoveryJsonBinding $workspace $preparationRelative
            source_composition = New-AdmissionRecoveryJsonBinding $workspace $sourceRelative
            repository_map = New-AdmissionRecoveryJsonBinding $workspace $mapRelative
            admission_receipt = New-AdmissionRecoveryJsonBinding $workspace "receipts/$admissionId.json"
            admission_intent = New-AdmissionRecoveryJsonBinding $workspace $intentRelative
            malformed_completion = New-AdmissionRecoveryJsonBinding $workspace $completionRelative
            project = New-AdmissionRecoveryJsonBinding $workspace 'project.spec.json'
            feature_lock = New-AdmissionRecoveryJsonBinding $workspace 'feature.lock.json'
            state = New-AdmissionRecoveryJsonBinding $workspace 'workspace.state.json'
            unit = New-AdmissionRecoveryJsonBinding $workspace "iteration-units/$unitId.json"
            event_ledger = [pscustomobject][ordered]@{
                path = 'iteration-events.jsonl'
                raw_sha256 = [string]$ledger.raw_sha256
                length = [int64]$ledger.length
                tail_event_id = $eventId
                tail_event_sha256 = Get-MorphospaceCanonicalJsonSha256 $event
            }
            admission_event = [pscustomobject][ordered]@{ event_id=$eventId; sequence=[int]$event.sequence; canonical_sha256=(Get-MorphospaceCanonicalJsonSha256 $event) }
        }
        chronology = [pscustomobject][ordered]@{
            intent_created_at = [string]$intent.created_at
            malformed_completed_at = [string]$completion.completed_at
            recovery_timestamp = $Timestamp
            disposition = 'preserve-original-and-append-owner-correction'
        }
        correction_event = [pscustomobject][ordered]@{
            event_id = $recoveryId
            sequence = $sequence
            timestamp = $Timestamp
            unit_id = $unitId
            receipt_path = "receipts/$recoveryId.json"
        }
        preservation = [pscustomobject][ordered]@{
            malformed_completion_bytes_retained = $true
            admission_transaction_bytes_retained = $true
            admission_receipt_bytes_retained = $true
            unit_bytes_retained = $true
            project_and_lock_bytes_retained = $true
            state_change = 'last_event_id-only'
            authority_granted = 'none'
        }
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $receipt) + "`n")
    [void](Assert-AdmissionRecoveryCore $workspace $receipt $bytes PreApply $null)
    $receipt
}

function Invoke-MorphospaceAdmissionCompletionTimestampRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$Recovery,
        [string]$ExpectedRecoverySha256 = '',
        [string]$OutPath = '',
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter = 'none',
        [scriptblock]$BeforeTransitionHook,
        [switch]$Execute
    )
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $input = Read-MorphospaceAdmissionCompletionTimestampRecovery $Recovery
    if ($ExpectedRecoverySha256 -and [string]$ExpectedRecoverySha256 -cne [string]$input.sha256) { throw 'Admission completion timestamp recovery input SHA-256 differs from the expected dry-run pin.' }
    if ($Execute -and -not $ExpectedRecoverySha256) { throw 'Executed admission completion timestamp recovery requires ExpectedRecoverySha256 from its dry run.' }
    $receipt = $input.document
    $canonicalRelative = [string]$receipt.correction_event.receipt_path
    $canonicalTarget = Resolve-MorphospaceWorkspacePath $workspace $canonicalRelative
    $requestedTarget = if ($OutPath) { [IO.Path]::GetFullPath($OutPath) } else { $canonicalTarget }
    if (-not $requestedTarget.Equals($canonicalTarget, [StringComparison]::OrdinalIgnoreCase)) { throw 'Admission completion timestamp recovery OutPath must equal its derived canonical workspace path.' }
    if ($input.path.Equals($canonicalTarget, [StringComparison]::OrdinalIgnoreCase)) { throw 'Inspected recovery input must be distinct from the transaction-owned workspace receipt.' }
    $transactionId = "$([string]$receipt.correction_event.event_id)-transition"
    $intentPath = Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.intent.json"
    $completionPath = Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.completion.json"
    if ([IO.File]::Exists($completionPath)) { throw "Admission completion timestamp recovery '$([string]$receipt.recovery_id)' was already consumed." }
    $pending = [IO.File]::Exists($intentPath)
    $context = Test-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $workspace -RecoveryPath $input.path -Mode $(if ($pending) { 'Pending' } else { 'PreApply' })
    if (-not $pending -and [IO.File]::Exists($canonicalTarget)) { throw 'Recovery receipt target already exists without its authenticated pending intent.' }
    if ($Execute) {
        if (-not $OutPath) { throw 'Executed admission completion timestamp recovery requires explicit canonical OutPath.' }
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        if ($pending) {
            [void](Test-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $workspace -RecoveryPath $input.path -Mode Pending)
            $repair = Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -Repair -FaultAfter $FaultAfter
            if ([string]$repair.status -ceq 'already-committed') { throw "Admission completion timestamp recovery '$([string]$receipt.recovery_id)' was concurrently consumed." }
        } else {
            $context = Test-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $workspace -RecoveryPath $input.path -Mode PreApply
            $arguments = @{
                WorkspaceRoot = $workspace
                TransactionId = $transactionId
                StatePath = 'workspace.state.json'
                UnitPath = [string]$receipt.evidence.unit.path
                EventsPath = 'iteration-events.jsonl'
                TargetState = $context.target_state
                TargetUnit = $context.target_unit
                Event = $context.correction_event
                ExpectedPreStateSha256 = [string]$receipt.evidence.state.canonical_sha256
                ExpectedPreStateRawSha256 = [string]$receipt.evidence.state.raw_sha256
                ExpectedPreUnitSha256 = [string]$receipt.evidence.unit.canonical_sha256
                ExpectedPreUnitRawSha256 = [string]$receipt.evidence.unit.raw_sha256
                ExpectedEventTailId = [string]$receipt.evidence.event_ledger.tail_event_id
                ExpectedEventsSha256 = [string]$receipt.evidence.event_ledger.raw_sha256
                ExpectedEventsLength = [int64]$receipt.evidence.event_ledger.length
                AdditionalProjections = @(
                    [pscustomobject][ordered]@{ path='feature.lock.json'; expected_sha256=[string]$receipt.evidence.feature_lock.canonical_sha256; expected_raw_sha256=[string]$receipt.evidence.feature_lock.raw_sha256; document=$context.feature_lock.document },
                    [pscustomobject][ordered]@{ path='project.spec.json'; expected_sha256=[string]$receipt.evidence.project.canonical_sha256; expected_raw_sha256=[string]$receipt.evidence.project.raw_sha256; document=$context.project.document }
                )
                Artifacts = @([pscustomobject][ordered]@{ source_path=$input.path; path=$canonicalRelative; sha256=[string]$input.sha256 })
                FaultAfter = $FaultAfter
            }
            [void](Start-MorphospaceTransitionLedger @arguments)
        }
        [void](Test-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $workspace -RecoveryPath $canonicalTarget -Mode Projection -CorrectionEvent $context.correction_event)
    }
    $result = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id = [string]$receipt.project_id
        unit_id = [string]$receipt.unit_id
        action = 'RecoverAdmissionCompletionTimestamp'
        timestamp = [string]$receipt.chronology.recovery_timestamp
        executed = $Execute.IsPresent
        transition = 'admission-completion-timestamp-recovered'
        status_before = 'proposed'
        status_after = 'proposed'
        current_unit_before = $null
        current_unit_after = $null
        preservation = [pscustomobject][ordered]@{ git_mutation_performed=$false; device_mutation_performed=$false; remote_mutation_performed=$false }
        audit_receipt = [pscustomobject][ordered]@{ path=$canonicalRelative; sha256=[string]$input.sha256 }
        event_id = if ($Execute) { [string]$receipt.correction_event.event_id } else { $null }
    }
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile (Get-AdmissionRecoveryResultSchemaPath))) { throw 'Admission completion timestamp recovery emitted an invalid automation result.' }
    $result
}

Export-ModuleMember -Function `
    New-MorphospaceAdmissionCompletionTimestampRecovery, `
    Read-MorphospaceAdmissionCompletionTimestampRecovery, `
    Test-MorphospaceAdmissionCompletionTimestampRecovery, `
    Invoke-MorphospaceAdmissionCompletionTimestampRecovery
