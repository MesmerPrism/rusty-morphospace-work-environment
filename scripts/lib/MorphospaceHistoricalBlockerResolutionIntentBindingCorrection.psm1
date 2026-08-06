Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force

$script:CorrectionSchema = 'rusty.morphospace.workflow.historical_blocker_resolution_intent_binding_correction.v1'
$script:CorrectionSuffix = '-historical-blocker-resolution-intent-binding-corrected-'

function Copy-HistoricalCorrectionDocument {
    param([Parameter(Mandatory = $true)][object]$Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 100 -Compress))
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'historical blocker-resolution correction document copy'
}

function Get-HistoricalCorrectionEventLineBytes {
    param([Parameter(Mandatory = $true)][object]$Event)
    [Text.UTF8Encoding]::new($false).GetBytes(($Event | ConvertTo-Json -Depth 32 -Compress) + "`n")
}

function Test-HistoricalCorrectionByteRange {
    param([byte[]]$Value,[int64]$Offset,[byte[]]$Expected)
    if ($Offset -lt 0 -or $Offset + $Expected.LongLength -gt $Value.LongLength) { return $false }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Value[$Offset + $index] -ne $Expected[$index]) { return $false }
    }
    return $true
}

function Get-HistoricalCorrectionTerminalLfNormalizedBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes,[string]$Label)
    if ($Bytes.LongLength -lt 2 -or $Bytes[$Bytes.LongLength - 2] -ne 0x0d -or $Bytes[$Bytes.LongLength - 1] -ne 0x0a) {
        throw "$Label does not have the exact terminal CRLF expansion admitted by this correction."
    }
    $normalized = [byte[]]::new($Bytes.Length - 1)
    if ($Bytes.Length -gt 2) { [Array]::Copy($Bytes, 0, $normalized, 0, $Bytes.Length - 2) }
    $normalized[$normalized.Length - 1] = 0x0a
    $normalized
}

function Test-HistoricalCorrectionBytesEqual {
    param([byte[]]$Left,[byte[]]$Right)
    if ($Left.LongLength -ne $Right.LongLength) { return $false }
    for ($index=0; $index -lt $Left.Length; $index++) { if ($Left[$index] -ne $Right[$index]) { return $false } }
    $true
}

function Get-HistoricalCorrectionManagedJsonFileSha256 {
    param([Parameter(Mandatory = $true)][object]$Document)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Document) + "`n")
    Get-MorphospaceSha256Bytes $bytes
}

function Assert-HistoricalCorrectionIntentShape {
    param(
        [Parameter(Mandatory = $true)][object]$Intent,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [switch]$AllowLegacyExpectedPrefix
    )
    Assert-MorphospaceExactPropertySet $Intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') @() 'Historical correction transition intent'
    if ([string]$Intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
        [string]$Intent.transaction_id -cne $TransactionId -or [string]$Intent.status -cne 'prepared') {
        throw 'Historical correction transition intent identity or status is invalid.'
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$Intent.created_at))
    foreach ($referenceName in @('state','unit','events')) {
        Assert-MorphospaceExactPropertySet $Intent.$referenceName @('path') @() "Historical correction transition intent $referenceName reference"
        [void](ConvertTo-MorphospaceProtocolRelativePath ([string]$Intent.$referenceName.path))
    }
    Assert-MorphospaceExactPropertySet $Intent.pre @('state','unit') @() 'Historical correction transition intent pre'
    Assert-MorphospaceExactPropertySet $Intent.target @('state','unit') @() 'Historical correction transition intent target'
    foreach ($projection in @('state','unit')) {
        Assert-MorphospaceExactPropertySet $Intent.pre.$projection @('sha256') @() "Historical correction transition intent pre-$projection"
        Assert-MorphospaceExactPropertySet $Intent.target.$projection @('sha256','document') @() "Historical correction transition intent target-$projection"
        $preHash = [string]$Intent.pre.$projection.sha256
        $targetHash = [string]$Intent.target.$projection.sha256
        if ($preHash -cnotmatch '^[0-9a-f]{64}$' -or $targetHash -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$Intent.expected."${projection}_sha256" -cne $preHash -or
            (Get-MorphospaceCanonicalJsonSha256 $Intent.target.$projection.document) -cne $targetHash) {
            throw "Historical correction transition intent $projection hashes are invalid or inconsistent."
        }
    }
    $hasEventsSha = $null -ne $Intent.expected.PSObject.Properties['events_sha256']
    $hasEventsLength = $null -ne $Intent.expected.PSObject.Properties['events_length']
    if ($hasEventsSha -ne $hasEventsLength) { throw 'Historical correction transition intent has a partial event-prefix binding.' }
    if ($hasEventsSha) {
        Assert-MorphospaceExactPropertySet $Intent.expected @('state_sha256','unit_sha256','event_tail_id','events_sha256','events_length') @() 'Historical correction transition intent expected'
        if (($Intent.expected.events_length -isnot [int]) -and ($Intent.expected.events_length -isnot [long])) {
            throw 'Historical correction transition intent event-prefix length is not an integer.'
        }
        if ([string]$Intent.expected.events_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [int64]$Intent.expected.events_length -lt 0 -or [int64]$Intent.expected.events_length -gt 67108864) {
            throw 'Historical correction transition intent event-prefix binding is invalid.'
        }
    } elseif ($AllowLegacyExpectedPrefix) {
        Assert-MorphospaceExactPropertySet $Intent.expected @('state_sha256','unit_sha256','event_tail_id') @() 'Historical correction legacy transition intent expected'
    } else {
        throw 'Historical correction transition intent is missing its event-prefix binding.'
    }
    if (@($Intent.artifacts).Count -ne 1) { throw 'Historical correction transition intent must own exactly one artifact.' }
    $artifact = @($Intent.artifacts)[0]
    Assert-MorphospaceExactPropertySet $artifact @('path','sha256','bytes_base64') @() 'Historical correction transition intent artifact'
    [void](ConvertTo-MorphospaceProtocolRelativePath ([string]$artifact.path))
    try { $artifactBytes = [Convert]::FromBase64String([string]$artifact.bytes_base64) }
    catch { throw 'Historical correction transition intent artifact bytes are invalid base64.' }
    if ([string]$artifact.sha256 -cne (Get-MorphospaceSha256Bytes $artifactBytes)) {
        throw 'Historical correction transition intent artifact hash differs from its owned bytes.'
    }
    $eventSchema = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas\iteration-event.schema.json'
    if (-not (Test-Json -Json ($Intent.event | ConvertTo-Json -Depth 16 -Compress) -SchemaFile $eventSchema)) {
        throw 'Historical correction transition intent event does not satisfy the exact iteration-event contract.'
    }
    [void](ConvertFrom-MorphospaceInvariantTimestamp -Value ([string]$Intent.event.timestamp))
}

function Assert-HistoricalCorrectionCompletionShape {
    param(
        [Parameter(Mandatory = $true)][object]$Completion,
        [Parameter(Mandatory = $true)][object]$Intent,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    Assert-MorphospaceExactPropertySet $Completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Historical correction transition completion'
    Assert-MorphospaceExactPropertySet $Completion.intent @('role','path','schema','sha256') @() 'Historical correction transition completion intent reference'
    if ([string]$Completion.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or
        [string]$Completion.transaction_id -cne $TransactionId -or [string]$Completion.status -cne 'committed') {
        throw 'Historical correction transition completion identity or status is invalid.'
    }
    $createdAt = Test-MorphospaceStrictUtcTimestamp ([string]$Intent.created_at)
    $completedAt = Test-MorphospaceStrictUtcTimestamp ([string]$Completion.completed_at)
    if ($completedAt -lt $createdAt) { throw 'Historical correction transition completion timestamp precedes its intent creation.' }
}

function ConvertFrom-HistoricalCorrectionLedgerBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes,[string]$Label = 'Historical correction event ledger')
    if ($Bytes.LongLength -gt 67108864) { throw "$Label exceeds the 64 MiB protocol bound." }
    if ($Bytes.LongLength -eq 0 -or $Bytes[$Bytes.LongLength - 1] -ne 0x0a) { throw "$Label must be non-empty and end with LF." }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { throw "$Label is not strict UTF-8." }
    $lines = @($text.Substring(0, $text.Length - 1) -split "`n")
    $events = @()
    foreach ($line in $lines) {
        if (-not $line) { throw "$Label contains a blank record." }
        $events += ,(ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line)) -Context "$Label entry")
    }
    for ($index = 0; $index -lt $events.Count; $index++) {
        if ([int]$events[$index].sequence -ne $index + 1) { throw "$Label sequence does not match physical record order." }
    }
    [pscustomobject][ordered]@{
        bytes = $Bytes
        sha256 = Get-MorphospaceSha256Bytes $Bytes
        length = [int64]$Bytes.LongLength
        events = @($events)
        tail = $events[-1]
    }
}

function Get-HistoricalCorrectionLedgerEvents {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    ConvertFrom-HistoricalCorrectionLedgerBytes -Bytes $bytes
}

function Get-HistoricalCorrectionBoundLedgerPrefix {
    param([Parameter(Mandatory = $true)][object]$Ledger,[Parameter(Mandatory = $true)][object]$Binding)
    if ([string]$Binding.path -cne 'iteration-events.jsonl' -or
        [int64]$Binding.length -lt 1 -or [int64]$Binding.length -gt [int64]$Ledger.length -or
        [int64]$Binding.length -gt [int]::MaxValue) {
        throw 'Historical correction bound event-ledger prefix is invalid.'
    }
    $prefixBytes = [byte[]]::new([int]$Binding.length)
    [Array]::Copy($Ledger.bytes, 0, $prefixBytes, 0, $prefixBytes.Length)
    if ((Get-MorphospaceSha256Bytes $prefixBytes) -cne [string]$Binding.sha256) {
        throw 'Historical correction bound event-ledger prefix hash is inconsistent.'
    }
    $prefix = ConvertFrom-HistoricalCorrectionLedgerBytes -Bytes $prefixBytes -Label 'Historical correction bound event-ledger prefix'
    if ([string]$prefix.tail.event_id -cne [string]$Binding.tail_event_id -or
        [int]$prefix.tail.sequence -ne [int]$Binding.tail_sequence -or
        @($prefix.events).Count -ne [int]$Binding.tail_sequence) {
        throw 'Historical correction bound event-ledger prefix tail is inconsistent.'
    }
    $prefix
}

function Assert-HistoricalCorrectionEventPlacement {
    param(
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][object]$Event,
        [Parameter(Mandatory = $true)][string]$PrefixSha256,
        [Parameter(Mandatory = $true)][int64]$PrefixLength,
        [AllowNull()][string]$PredecessorId
    )
    if ($PrefixLength -lt 0 -or $PrefixLength -gt $Ledger.length) { throw 'Historical correction event prefix length is outside the ledger.' }
    $prefix = [byte[]]::new([int]$PrefixLength)
    if ($PrefixLength) { [Array]::Copy($Ledger.bytes, 0, $prefix, 0, [int]$PrefixLength) }
    if ((Get-MorphospaceSha256Bytes $prefix) -cne $PrefixSha256) { throw 'Historical correction event predecessor prefix hash is inconsistent.' }
    $line = Get-HistoricalCorrectionEventLineBytes $Event
    if (-not (Test-HistoricalCorrectionByteRange -Value $Ledger.bytes -Offset $PrefixLength -Expected $line)) { throw 'Historical correction event is not the exact canonical append after its bound prefix.' }
    $sequence = [int]$Event.sequence
    if ($sequence -lt 1 -or $sequence -gt @($Ledger.events).Count) { throw 'Historical correction event sequence is outside the ledger.' }
    $observed = @($Ledger.events)[$sequence - 1]
    if ((Get-MorphospaceCanonicalJsonSha256 $observed) -cne (Get-MorphospaceCanonicalJsonSha256 $Event)) { throw 'Historical correction event bytes and sequence do not identify the same event.' }
    $observedPredecessor = if ($sequence -gt 1) { [string]@($Ledger.events)[$sequence - 2].event_id } else { $null }
    if ([string]$observedPredecessor -cne [string]$PredecessorId) { throw 'Historical correction event predecessor identity is inconsistent.' }
}

function Get-HistoricalCorrectionBoundJson {
    param([string]$Workspace,[object]$Binding,[string]$Label)
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath ([string]$Binding.path) -RequireLeaf
    if ((Get-MorphospaceFileSha256 $path) -cne [string]$Binding.sha256) { throw "$Label hash mismatch." }
    $raw = Get-Content -Raw -LiteralPath $path
    try { $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([IO.File]::ReadAllBytes($path)) -Context $Label }
    catch { throw "$Label is malformed or unreadable: $($_.Exception.Message)" }
    [pscustomobject][ordered]@{ path=$path; raw=$raw; document=$document }
}

function Get-HistoricalCorrectionExpectedEvent {
    param([Parameter(Mandatory = $true)][object]$Receipt)
    [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = [string]$Receipt.correction_event.event_id
        sequence = [int]$Receipt.correction_event.sequence
        timestamp = [string]$Receipt.correction_event.timestamp
        project_id = [string]$Receipt.project_id
        unit_id = [string]$Receipt.correction_event.unit_id
        event_type = 'state-transition'
        summary = "Corrected the retained intent-hash binding for historical blocker-resolution event '$([string]$Receipt.historical_resolution.event.event_id)' without rewriting historical records or current work-unit authority."
        receipts = @([string]$Receipt.correction_event.receipt_path)
    }
}

function Assert-HistoricalResolutionIntentBindingFault {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][object]$Ledger
    )
    $binding = $Receipt.historical_resolution
    $matches = @($Ledger.events | Where-Object { [string]$_.event_id -ceq [string]$binding.event.event_id })
    if ($matches.Count -ne 1) { throw 'Historical correction requires exactly one target blocker-resolution event.' }
    $event = $matches[0]
    $eventSequence = [int]$event.sequence
    if (
        [string]$event.schema -cne 'rusty.morphospace.workflow.iteration_event.v1' -or
        [string]$event.event_id -cnotmatch '-blocker-resolved-[0-9]{4}$' -or
        [string]$event.event_type -cne 'state-transition' -or
        [string]$event.project_id -cne [string]$Receipt.project_id -or
        [string]$event.unit_id -cne [string]$binding.unit_id -or
        [int]$event.sequence -ne [int]$binding.event.sequence -or
        (Get-MorphospaceCanonicalJsonSha256 $event) -cne [string]$binding.event.sha256 -or
        @($event.receipts).Count -ne 1 -or
        [string]@($event.receipts)[0] -cne [string]$binding.receipt.path
    ) { throw 'Historical correction target event identity or receipt reference is inconsistent.' }
    if ($eventSequence -lt 1 -or $eventSequence -gt @($Ledger.events).Count -or
        (Get-MorphospaceCanonicalJsonSha256 @($Ledger.events)[$eventSequence - 1]) -cne (Get-MorphospaceCanonicalJsonSha256 $event)) {
        throw 'Historical correction target event is not physically present at its bound sequence in the pre-correction ledger.'
    }

    $receiptResult = Get-HistoricalCorrectionBoundJson $Workspace $binding.receipt 'Historical blocker-resolution receipt'
    $receiptSchema = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas\blocker-resolution-receipt-v1.schema.json'
    if (-not (Test-Json -Json $receiptResult.raw -SchemaFile $receiptSchema)) { throw 'Historical blocker-resolution receipt is schema-invalid.' }
    $originalReceipt = $receiptResult.document
    if (
        [string]$originalReceipt.schema -cne 'rusty.morphospace.workflow.blocker_resolution_receipt.v1' -or
        [string]$originalReceipt.receipt_id -cne [string]$binding.original_receipt_id -or
        [string]$originalReceipt.project_id -cne [string]$Receipt.project_id -or
        [string]$originalReceipt.unit_id -cne [string]$binding.unit_id -or
        [string]$originalReceipt.blocker.blocker_id -cne [string]$binding.blocker_id
    ) { throw 'Historical blocker-resolution receipt identity is inconsistent.' }

    $transactionId = "$([string]$event.event_id)-transition"
    $expectedIntentPath = "receipts/transactions/$transactionId.intent.json"
    $expectedCompletionPath = "receipts/transactions/$transactionId.completion.json"
    if ([string]$binding.intent.path -cne $expectedIntentPath -or [string]$binding.completion.path -cne $expectedCompletionPath) {
        throw 'Historical blocker-resolution transaction paths are not canonical for the target event.'
    }
    $intentResult = Get-HistoricalCorrectionBoundJson $Workspace $binding.intent 'Historical blocker-resolution transition intent'
    $completionResult = Get-HistoricalCorrectionBoundJson $Workspace $binding.completion 'Historical blocker-resolution transition completion'
    $intent = $intentResult.document
    $completion = $completionResult.document
    Assert-HistoricalCorrectionIntentShape -Intent $intent -TransactionId $transactionId -AllowLegacyExpectedPrefix
    Assert-HistoricalCorrectionCompletionShape -Completion $completion -Intent $intent -TransactionId $transactionId
    $intentEventHash = Get-MorphospaceCanonicalJsonSha256 $intent.event
    $eventHash = Get-MorphospaceCanonicalJsonSha256 $event
    $targetStateHash = Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document
    $targetUnitHash = Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document
    if (
        [string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
        [string]$intent.transaction_id -cne $transactionId -or
        [string]$intent.status -cne 'prepared' -or
        [string]$intent.state.path -cne 'workspace.state.json' -or
        [string]$intent.unit.path -cne "iteration-units/$([string]$binding.unit_id).json" -or
        [string]$intent.events.path -cne 'iteration-events.jsonl' -or
        $intentEventHash -cne $eventHash -or
        [string]$intent.target.state.sha256 -cne $targetStateHash -or
        [string]$intent.target.unit.sha256 -cne $targetUnitHash
    ) { throw 'Historical blocker-resolution transition intent is internally inconsistent.' }
    $hasHistoricalEventsSha = $null -ne $intent.expected.PSObject.Properties['events_sha256']
    $hasHistoricalEventsLength = $null -ne $intent.expected.PSObject.Properties['events_length']
    if ($hasHistoricalEventsSha -ne $hasHistoricalEventsLength) { throw 'Historical blocker-resolution intent has a partial event-prefix binding.' }
    if ($hasHistoricalEventsSha) {
        Assert-HistoricalCorrectionEventPlacement -Ledger $Ledger -Event $event `
            -PrefixSha256 ([string]$intent.expected.events_sha256) -PrefixLength ([int64]$intent.expected.events_length) `
            -PredecessorId ([string]$intent.expected.event_tail_id)
    } else {
        # Early v1 transition intents predate byte-length/hash binding for the
        # event prefix. For that exact retained format, bind the whole current
        # ledger through the correction CAS, the exact target event hash and
        # sequence above, and the independently recorded predecessor here.
        $predecessor = if ([int]$event.sequence -gt 1) { [string]@($Ledger.events)[[int]$event.sequence - 2].event_id } else { $null }
        if ([string]$predecessor -cne [string]$intent.expected.event_tail_id) { throw 'Historical blocker-resolution event predecessor differs from its retained v1 intent.' }
    }

    $observedIntentBytes = [IO.File]::ReadAllBytes($intentResult.path)
    $observedIntentHash = Get-MorphospaceSha256Bytes $observedIntentBytes
    $recordedIntentHash = [string]$completion.intent.sha256
    if (
        [string]$completion.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or
        [string]$completion.transaction_id -cne $transactionId -or
        [string]$completion.event_id -cne [string]$event.event_id -or
        [string]$completion.status -cne 'committed' -or
        [string]$completion.intent.role -cne 'transition-ledger-intent' -or
        [string]$completion.intent.path -cne $expectedIntentPath -or
        [string]$completion.intent.schema -cne [string]$intent.schema -or
        [string]$completion.state_sha256 -cne [string]$intent.target.state.sha256 -or
        [string]$completion.unit_sha256 -cne [string]$intent.target.unit.sha256
    ) { throw 'Historical blocker-resolution completion has a fault beyond the admitted intent SHA-256 binding.' }
    if ($recordedIntentHash -ceq $observedIntentHash) { throw 'Historical blocker-resolution completion does not contain the admitted intent SHA-256 mismatch.' }
    $normalizedIntentBytes = Get-HistoricalCorrectionTerminalLfNormalizedBytes -Bytes $observedIntentBytes -Label 'Historical blocker-resolution intent'
    $normalizedIntentHash = Get-MorphospaceSha256Bytes $normalizedIntentBytes
    if (
        $recordedIntentHash -cne [string]$binding.intent_binding.completion_recorded_sha256 -or
        $observedIntentHash -cne [string]$binding.intent_binding.observed_file_sha256 -or
        $normalizedIntentHash -cne [string]$binding.intent_binding.normalized_lf_sha256 -or
        $normalizedIntentHash -cne $recordedIntentHash
    ) { throw 'Historical blocker-resolution intent terminal-newline binding differs from the correction receipt.' }
    $owned = @($intent.artifacts | Where-Object { [string]$_.path -ceq [string]$binding.receipt.path })
    $receiptBytes = [IO.File]::ReadAllBytes($receiptResult.path)
    if ($owned.Count -ne 1 -or @($intent.artifacts).Count -ne 1) { throw 'Historical blocker-resolution receipt is not the sole artifact owned by its intent.' }
    try { $ownedReceiptBytes = [Convert]::FromBase64String([string]$owned[0].bytes_base64) }
    catch { throw 'Historical blocker-resolution intent-owned receipt bytes are invalid base64.' }
    $normalizedReceiptBytes = Get-HistoricalCorrectionTerminalLfNormalizedBytes -Bytes $receiptBytes -Label 'Historical blocker-resolution receipt'
    $normalizedReceiptHash = Get-MorphospaceSha256Bytes $normalizedReceiptBytes
    if (
        [string]$owned[0].sha256 -cne (Get-MorphospaceSha256Bytes $ownedReceiptBytes) -or
        -not (Test-HistoricalCorrectionBytesEqual -Left $normalizedReceiptBytes -Right $ownedReceiptBytes) -or
        [string]$owned[0].sha256 -cne [string]$binding.receipt_binding.intent_recorded_sha256 -or
        (Get-MorphospaceSha256Bytes $receiptBytes) -cne [string]$binding.receipt_binding.observed_file_sha256 -or
        $normalizedReceiptHash -cne [string]$binding.receipt_binding.normalized_lf_sha256 -or
        $normalizedReceiptHash -cne [string]$owned[0].sha256
    ) { throw 'Historical blocker-resolution receipt does not have the exact intent-owned LF to retained CRLF expansion.' }
    [pscustomobject][ordered]@{
        event = $event
        original_receipt = $originalReceipt
        intent = $intent
        completion = $completion
        recorded_intent_sha256 = $recordedIntentHash
        observed_intent_sha256 = $observedIntentHash
        recorded_receipt_sha256 = [string]$owned[0].sha256
        observed_receipt_sha256 = Get-MorphospaceSha256Bytes $receiptBytes
    }
}

function Read-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection {
    param([Parameter(Mandatory = $true)][string]$Path)
    $absolute = (Resolve-Path -LiteralPath $Path).Path
    $raw = Get-Content -Raw -LiteralPath $absolute
    $schemaPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas\historical-blocker-resolution-intent-binding-correction-v1.schema.json'
    if (-not (Test-Json -Json $raw -SchemaFile $schemaPath)) { throw 'Historical blocker-resolution intent-binding correction does not satisfy its schema.' }
    $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([IO.File]::ReadAllBytes($absolute)) -Context 'historical blocker-resolution intent-binding correction'
    [pscustomobject][ordered]@{ path=$absolute; sha256=Get-MorphospaceFileSha256 $absolute; document=$document }
}

function Test-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [ValidateSet('PreApply','Projection')][string]$Mode = 'PreApply',
        [object]$CorrectionEvent
    )
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $snapshot = Read-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection $ReceiptPath
    $receipt = $snapshot.document
    $authority = $receipt.current_authority
    if ([string]$authority.unit.path -cne "iteration-units/$([string]$authority.unit_id).json") { throw 'Historical correction current-unit path is not derived from its current unit identity.' }
    $expectedEventId = "$([string]$authority.unit_id)$script:CorrectionSuffix$('{0:d4}' -f [int]$receipt.correction_event.sequence)"
    if (
        [string]$receipt.correction_event.event_id -cne $expectedEventId -or
        [string]$receipt.correction_event.unit_id -cne [string]$authority.unit_id -or
        [int]$receipt.correction_event.sequence -ne [int]$authority.event_ledger.tail_sequence + 1 -or
        [string]$receipt.correction_event.receipt_path -cne "receipts/$([string]$receipt.receipt_id).json"
    ) { throw 'Historical correction event identity, sequence, unit, or receipt path is not derived from its bound authority.' }
    $expectedEvent = Get-HistoricalCorrectionExpectedEvent $receipt
    $ledgerPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'iteration-events.jsonl' -RequireLeaf
    $ledger = Get-HistoricalCorrectionLedgerEvents $ledgerPath
    $boundLedger = Get-HistoricalCorrectionBoundLedgerPrefix -Ledger $ledger -Binding $authority.event_ledger
    $historical = Assert-HistoricalResolutionIntentBindingFault -Workspace $workspace -Receipt $receipt -Ledger $boundLedger
    $correctionTimestamp = ConvertFrom-MorphospaceInvariantTimestamp -Value ([string]$receipt.correction_event.timestamp)
    $tailTimestamp = ConvertFrom-MorphospaceInvariantTimestamp -Value ([string]$boundLedger.tail.timestamp)
    if ($correctionTimestamp -lt $tailTimestamp) { throw 'Historical correction event timestamp precedes the bound ledger tail.' }

    if ($Mode -ceq 'PreApply') {
        if ($ledger.sha256 -cne [string]$authority.event_ledger.sha256 -or $ledger.length -ne [int64]$authority.event_ledger.length -or
            [string]$ledger.tail.event_id -cne [string]$authority.event_ledger.tail_event_id -or [int]$ledger.tail.sequence -ne [int]$authority.event_ledger.tail_sequence) {
            throw 'Historical correction event-ledger CAS differs from the inspected authority.'
        }
        $statePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath ([string]$authority.state.path) -RequireLeaf
        $unitPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath ([string]$authority.unit.path) -RequireLeaf
        $state = Read-MorphospaceProtocolJson $statePath
        $unit = Read-MorphospaceProtocolJson $unitPath
        if (
            (Get-MorphospaceFileSha256 $statePath) -cne [string]$authority.state.sha256 -or
            (Get-MorphospaceCanonicalJsonSha256 $state) -cne [string]$authority.state.canonical_sha256 -or
            (Get-MorphospaceFileSha256 $unitPath) -cne [string]$authority.unit.sha256 -or
            (Get-MorphospaceCanonicalJsonSha256 $unit) -cne [string]$authority.unit.canonical_sha256
        ) { throw 'Historical correction state or current-unit CAS differs from the inspected authority.' }
        $liveBlockerIds = @($state.blockers | ForEach-Object { [string]$_.blocker_id })
        if (
            [string]$state.project_id -cne [string]$receipt.project_id -or
            [string]$state.current_unit -cne [string]$authority.unit_id -or
            [string]$state.last_event_id -cne [string]$authority.event_ledger.tail_event_id -or
            [string]$unit.project_id -cne [string]$receipt.project_id -or
            [string]$unit.unit_id -cne [string]$authority.unit_id -or
            [string]$unit.status -cne 'active' -or
            ($liveBlockerIds -join '|') -cne (@($authority.blocker_ids) -join '|')
        ) { throw 'Historical correction requires the exact current active unit and ordered blocker projection.' }
        return [pscustomobject][ordered]@{
            receipt=$receipt; receipt_sha256=$snapshot.sha256; current_state=$state; current_unit=$unit
            target_state=$null; correction_event=$expectedEvent; historical=$historical; ledger=$ledger
        }
    }

    if ($null -eq $CorrectionEvent) {
        $events = @($ledger.events | Where-Object { [string]$_.event_id -ceq [string]$receipt.correction_event.event_id })
        if ($events.Count -ne 1) { throw 'Historical correction projection requires exactly one correction event.' }
        $CorrectionEvent = $events[0]
    }
    # Callers such as ResolveBlocker may have parsed the event with the host's
    # default date conversion. Reparse its JSON through the protocol reader so
    # timestamps remain JSON strings before canonical hashing.
    $CorrectionEvent = ConvertFrom-MorphospaceProtocolJsonBytes `
        -Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($CorrectionEvent | ConvertTo-Json -Depth 32 -Compress))) `
        -Context 'historical correction projection event'
    [void]$CorrectionEvent.PSObject.Properties.Remove('__line_sha256')
    if ((Get-MorphospaceCanonicalJsonSha256 $CorrectionEvent) -cne (Get-MorphospaceCanonicalJsonSha256 $expectedEvent)) { throw 'Historical correction projection event differs from the receipt-derived event.' }
    Assert-HistoricalCorrectionEventPlacement -Ledger $ledger -Event $CorrectionEvent `
        -PrefixSha256 ([string]$authority.event_ledger.sha256) -PrefixLength ([int64]$authority.event_ledger.length) `
        -PredecessorId ([string]$authority.event_ledger.tail_event_id)
    $transactionId = "$([string]$receipt.correction_event.event_id)-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentResult = Get-HistoricalCorrectionBoundJson $workspace ([pscustomobject]@{path=$intentRelative;sha256=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $intentRelative -RequireLeaf))}) 'Correction transition intent'
    $completionResult = Get-HistoricalCorrectionBoundJson $workspace ([pscustomobject]@{path=$completionRelative;sha256=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $completionRelative -RequireLeaf))}) 'Correction transition completion'
    $intent = $intentResult.document
    $completion = $completionResult.document
    Assert-HistoricalCorrectionIntentShape -Intent $intent -TransactionId $transactionId
    Assert-HistoricalCorrectionCompletionShape -Completion $completion -Intent $intent -TransactionId $transactionId
    $targetState = $intent.target.state.document
    $targetUnit = $intent.target.unit.document
    $reconstructedPreState = Copy-HistoricalCorrectionDocument $targetState
    $reconstructedPreState.last_event_id = [string]$authority.event_ledger.tail_event_id
    if (
        [string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
        [string]$intent.transaction_id -cne $transactionId -or [string]$intent.status -cne 'prepared' -or
        [string]$intent.state.path -cne [string]$authority.state.path -or
        [string]$intent.unit.path -cne [string]$authority.unit.path -or
        [string]$intent.events.path -cne [string]$authority.event_ledger.path -or
        (Get-MorphospaceCanonicalJsonSha256 $intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $expectedEvent) -or
        [string]$intent.pre.state.sha256 -cne [string]$authority.state.canonical_sha256 -or
        [string]$intent.pre.unit.sha256 -cne [string]$authority.unit.canonical_sha256 -or
        [string]$intent.expected.state_sha256 -cne [string]$authority.state.canonical_sha256 -or
        [string]$intent.expected.unit_sha256 -cne [string]$authority.unit.canonical_sha256 -or
        [string]$intent.expected.events_sha256 -cne [string]$authority.event_ledger.sha256 -or
        [int64]$intent.expected.events_length -ne [int64]$authority.event_ledger.length -or
        [string]$intent.expected.event_tail_id -cne [string]$authority.event_ledger.tail_event_id -or
        [string]$intent.target.state.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $targetState) -or
        [string]$intent.target.unit.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $targetUnit) -or
        (Get-MorphospaceCanonicalJsonSha256 $reconstructedPreState) -cne [string]$authority.state.canonical_sha256 -or
        (Get-MorphospaceCanonicalJsonSha256 $targetUnit) -cne [string]$authority.unit.canonical_sha256 -or
        (Get-HistoricalCorrectionManagedJsonFileSha256 $reconstructedPreState) -cne [string]$authority.state.sha256 -or
        (Get-HistoricalCorrectionManagedJsonFileSha256 $targetUnit) -cne [string]$authority.unit.sha256 -or
        [string]$targetState.last_event_id -cne [string]$receipt.correction_event.event_id -or
        [string]$targetState.current_unit -cne [string]$authority.unit_id -or
        [string]$targetUnit.unit_id -cne [string]$authority.unit_id -or [string]$targetUnit.status -cne 'active' -or
        (@($targetState.blockers | ForEach-Object { [string]$_.blocker_id }) -join '|') -cne (@($authority.blocker_ids) -join '|')
    ) { throw 'Correction transition intent does not preserve the exact bound state/unit/ledger projections.' }
    $receiptOwned = @($intent.artifacts | Where-Object { [string]$_.path -ceq [string]$receipt.correction_event.receipt_path })
    $receiptBytes = [IO.File]::ReadAllBytes($snapshot.path)
    if (@($intent.artifacts).Count -ne 1 -or $receiptOwned.Count -ne 1 -or [string]$receiptOwned[0].sha256 -cne $snapshot.sha256 -or [string]$receiptOwned[0].bytes_base64 -cne [Convert]::ToBase64String($receiptBytes)) {
        throw 'Correction receipt is not uniquely hash-and-byte-owned by its transition intent.'
    }
    if (
        [string]$completion.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or
        [string]$completion.transaction_id -cne $transactionId -or [string]$completion.event_id -cne [string]$expectedEvent.event_id -or
        [string]$completion.status -cne 'committed' -or [string]$completion.intent.role -cne 'transition-ledger-intent' -or
        [string]$completion.intent.path -cne $intentRelative -or [string]$completion.intent.schema -cne [string]$intent.schema -or
        [string]$completion.intent.sha256 -cne (Get-MorphospaceFileSha256 $intentResult.path) -or
        [string]$completion.state_sha256 -cne [string]$intent.target.state.sha256 -or
        [string]$completion.unit_sha256 -cne [string]$intent.target.unit.sha256
    ) { throw 'Correction transition completion is inconsistent with its intent.' }
    [pscustomobject][ordered]@{
        receipt=$receipt; receipt_sha256=$snapshot.sha256; target_state=$targetState; target_unit=$targetUnit
        correction_event=$expectedEvent; historical=$historical; ledger=$ledger
    }
}

function Get-MorphospaceHistoricalBlockerResolutionIntentBindingCorrectionIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot,[object[]]$Events = @())
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $index = @{}
    if (-not $PSBoundParameters.ContainsKey('Events')) {
        $ledgerPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'iteration-events.jsonl' -RequireLeaf
        if ((Get-Item -LiteralPath $ledgerPath).Length -eq 0) { return $index }
        $Events = @((Get-HistoricalCorrectionLedgerEvents $ledgerPath).events)
    }
    if (@($Events).Count -eq 0) { return $index }
    foreach ($event in @($Events | Where-Object { [string]$_.event_id -match [regex]::Escape($script:CorrectionSuffix) + '[0-9]{4}$' })) {
        if ([string]$event.schema -cne 'rusty.morphospace.workflow.iteration_event.v1' -or [string]$event.event_type -cne 'state-transition' -or @($event.receipts).Count -ne 1) {
            throw "Historical intent-binding correction event '$([string]$event.event_id)' is malformed."
        }
        $receiptPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath ([string]@($event.receipts)[0]) -RequireLeaf
        $verified = Test-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection -WorkspaceRoot $workspace -ReceiptPath $receiptPath -Mode Projection -CorrectionEvent $event
        $targetId = [string]$verified.receipt.historical_resolution.event.event_id
        if ($index.ContainsKey($targetId)) { throw "Historical blocker-resolution event '$targetId' has more than one intent-binding correction." }
        $index[$targetId] = [pscustomobject][ordered]@{
            correction_event_id = [string]$event.event_id
            historical_event_id = $targetId
            recorded_intent_sha256 = [string]$verified.historical.recorded_intent_sha256
            observed_intent_sha256 = [string]$verified.historical.observed_intent_sha256
            recorded_receipt_sha256 = [string]$verified.historical.recorded_receipt_sha256
            observed_receipt_sha256 = [string]$verified.historical.observed_receipt_sha256
        }
    }
    $index
}

function New-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$HistoricalEventId,
        [Parameter(Mandatory = $true)][string]$ReceiptId,
        [string]$Timestamp = ''
    )
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $statePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'workspace.state.json' -RequireLeaf
    $eventsPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'iteration-events.jsonl' -RequireLeaf
    $state = Read-MorphospaceProtocolJson $statePath
    $currentUnitId = [string]$state.current_unit
    if (-not $currentUnitId) { throw 'Historical correction builder requires a current unit.' }
    $unitRelative = "iteration-units/$currentUnitId.json"
    $unitPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $unitRelative -RequireLeaf
    $unit = Read-MorphospaceProtocolJson $unitPath
    if ([string]$unit.status -cne 'active' -or [string]$unit.unit_id -cne $currentUnitId -or [string]$unit.project_id -cne [string]$state.project_id) {
        throw 'Historical correction builder requires the exact current active unit.'
    }
    $ledger = Get-HistoricalCorrectionLedgerEvents $eventsPath
    if ([string]$ledger.tail.event_id -cne [string]$state.last_event_id) { throw 'Historical correction builder requires state last_event_id to equal the ledger tail.' }
    $targetEvents = @($ledger.events | Where-Object { [string]$_.event_id -ceq $HistoricalEventId })
    if ($targetEvents.Count -ne 1) { throw 'Historical correction builder requires exactly one target historical event.' }
    $historicalEvent = $targetEvents[0]
    if (@($historicalEvent.receipts).Count -ne 1) { throw 'Historical correction builder target event must retain exactly one receipt.' }
    $receiptRelative = [string]@($historicalEvent.receipts)[0]
    $originalReceiptPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $receiptRelative -RequireLeaf
    $originalReceipt = Read-MorphospaceProtocolJson $originalReceiptPath
    $transactionId = "$HistoricalEventId-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $intentRelative -RequireLeaf
    $completionPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $completionRelative -RequireLeaf
    $intent = Read-MorphospaceProtocolJson $intentPath
    $completion = Read-MorphospaceProtocolJson $completionPath
    $observedIntentHash = Get-MorphospaceFileSha256 $intentPath
    if ([string]$completion.intent.sha256 -ceq $observedIntentHash) { throw 'Historical correction builder found no completion-recorded intent SHA-256 mismatch.' }
    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    $sequence = [int]$ledger.tail.sequence + 1
    $eventId = "$currentUnitId$script:CorrectionSuffix$('{0:d4}' -f $sequence)"
    $document = [pscustomobject][ordered]@{
        schema = $script:CorrectionSchema
        receipt_id = $ReceiptId
        project_id = [string]$state.project_id
        fault_kind = 'legacy-terminal-crlf-expanded-raw-bindings'
        current_authority = [pscustomobject][ordered]@{
            unit_id = $currentUnitId
            status = 'active'
            state = [pscustomobject][ordered]@{
                path = 'workspace.state.json'
                sha256 = Get-MorphospaceFileSha256 $statePath
                canonical_sha256 = Get-MorphospaceCanonicalJsonSha256 $state
            }
            unit = [pscustomobject][ordered]@{
                path = $unitRelative
                sha256 = Get-MorphospaceFileSha256 $unitPath
                canonical_sha256 = Get-MorphospaceCanonicalJsonSha256 $unit
            }
            event_ledger = [pscustomobject][ordered]@{
                path = 'iteration-events.jsonl'
                sha256 = [string]$ledger.sha256
                length = [int64]$ledger.length
                tail_event_id = [string]$ledger.tail.event_id
                tail_sequence = [int]$ledger.tail.sequence
            }
            blocker_ids = @($state.blockers | ForEach-Object { [string]$_.blocker_id })
        }
        historical_resolution = [pscustomobject][ordered]@{
            unit_id = [string]$historicalEvent.unit_id
            blocker_id = [string]$originalReceipt.blocker.blocker_id
            original_receipt_id = [string]$originalReceipt.receipt_id
            event = [pscustomobject][ordered]@{
                event_id = $HistoricalEventId
                sequence = [int]$historicalEvent.sequence
                sha256 = Get-MorphospaceCanonicalJsonSha256 $historicalEvent
            }
            receipt = [pscustomobject][ordered]@{ path=$receiptRelative; sha256=Get-MorphospaceFileSha256 $originalReceiptPath }
            intent = [pscustomobject][ordered]@{ path=$intentRelative; sha256=$observedIntentHash }
            completion = [pscustomobject][ordered]@{ path=$completionRelative; sha256=Get-MorphospaceFileSha256 $completionPath }
            receipt_binding = [pscustomobject][ordered]@{
                intent_recorded_sha256 = [string]@($intent.artifacts | Where-Object { [string]$_.path -ceq $receiptRelative })[0].sha256
                observed_file_sha256 = Get-MorphospaceFileSha256 $originalReceiptPath
                normalized_lf_sha256 = Get-MorphospaceSha256Bytes (Get-HistoricalCorrectionTerminalLfNormalizedBytes -Bytes ([IO.File]::ReadAllBytes($originalReceiptPath)) -Label 'Historical blocker-resolution receipt')
                exact_terminal_lf_to_crlf_expansion = $true
            }
            intent_binding = [pscustomobject][ordered]@{
                completion_recorded_sha256 = [string]$completion.intent.sha256
                observed_file_sha256 = $observedIntentHash
                normalized_lf_sha256 = Get-MorphospaceSha256Bytes (Get-HistoricalCorrectionTerminalLfNormalizedBytes -Bytes ([IO.File]::ReadAllBytes($intentPath)) -Label 'Historical blocker-resolution intent')
                exact_terminal_lf_to_crlf_expansion = $true
                all_other_completion_fields_valid = $true
            }
        }
        correction_event = [pscustomobject][ordered]@{
            event_id = $eventId
            sequence = $sequence
            timestamp = $Timestamp
            unit_id = $currentUnitId
            receipt_path = "receipts/$ReceiptId.json"
        }
        preservation = [pscustomobject][ordered]@{
            historical_event_bytes_retained = $true
            historical_receipt_bytes_retained = $true
            historical_transaction_bytes_retained = $true
            current_unit_bytes_retained = $true
            current_blockers_retained = $true
            state_change = 'last_event_id-only'
        }
    }
    $schemaPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas\historical-blocker-resolution-intent-binding-correction-v1.schema.json'
    if (-not (Test-Json -Json ($document | ConvertTo-Json -Depth 32) -SchemaFile $schemaPath)) { throw 'Historical correction builder emitted a schema-invalid document.' }
    $document
}

Export-ModuleMember -Function `
    New-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection, `
    Read-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection, `
    Test-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection, `
    Get-MorphospaceHistoricalBlockerResolutionIntentBindingCorrectionIndex, `
    Get-HistoricalCorrectionExpectedEvent
