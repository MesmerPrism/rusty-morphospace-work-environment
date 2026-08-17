Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force

function Get-MorphospaceBlockedSupersessionSha256Slice {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Count
    )
    if ($Offset -lt 0 -or $Count -lt 0 -or ($Offset + $Count) -gt $Bytes.Length) {
        throw 'Byte-slice bounds are invalid.'
    }
    $slice = [byte[]]::new($Count)
    if ($Count -gt 0) { [Array]::Copy($Bytes, $Offset, $slice, 0, $Count) }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($slice)).ToLowerInvariant()
}

function Get-MorphospaceBlockedSupersessionLedger {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot)

    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath 'iteration-events.jsonl' -RequireLeaf
    $bytes = [IO.File]::ReadAllBytes($path)
    $rows = [Collections.Generic.List[object]]::new()
    $start = 0
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -ne 10) { continue }
        $contentEnd = $index
        if ($contentEnd -gt $start -and $bytes[$contentEnd - 1] -eq 13) { $contentEnd-- }
        if ($contentEnd -eq $start) { throw "Event ledger contains a blank record at byte offset $start." }
        $lineBytes = [byte[]]::new($contentEnd - $start)
        [Array]::Copy($bytes, $start, $lineBytes, 0, $lineBytes.Length)
        $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $lineBytes -Context "event ledger byte offset $start"
        $rows.Add([pscustomobject][ordered]@{
            ordinal = $rows.Count
            start_offset = $start
            end_offset = $index + 1
            prefix_sha256 = Get-MorphospaceBlockedSupersessionSha256Slice -Bytes $bytes -Offset 0 -Count $start
            line_sha256 = Get-MorphospaceSha256Bytes -Bytes $lineBytes
            document = $document
        }) | Out-Null
        $start = $index + 1
    }
    if ($start -lt $bytes.Length) {
        $lineBytes = [byte[]]::new($bytes.Length - $start)
        [Array]::Copy($bytes, $start, $lineBytes, 0, $lineBytes.Length)
        $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $lineBytes -Context "event ledger byte offset $start"
        $rows.Add([pscustomobject][ordered]@{
            ordinal = $rows.Count
            start_offset = $start
            end_offset = $bytes.Length
            prefix_sha256 = Get-MorphospaceBlockedSupersessionSha256Slice -Bytes $bytes -Offset 0 -Count $start
            line_sha256 = Get-MorphospaceSha256Bytes -Bytes $lineBytes
            document = $document
        }) | Out-Null
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previousSequence = 0
    foreach ($row in $rows) {
        $event = $row.document
        if ([string]$event.schema -cnotin @('rusty.morphospace.workflow.iteration_event.v1', 'rusty.morphospace.workflow.iteration_event.v2')) {
            throw "Event '$([string]$event.event_id)' has an unsupported schema."
        }
        if (-not $ids.Add([string]$event.event_id)) { throw "Event '$([string]$event.event_id)' is duplicated." }
        if ([int]$event.sequence -le $previousSequence) { throw "Event '$([string]$event.event_id)' does not advance sequence." }
        $previousSequence = [int]$event.sequence
    }
    return [pscustomobject][ordered]@{ path = $path; bytes = $bytes; rows = @($rows.ToArray()) }
}

function Read-MorphospaceBlockedSupersessionJson {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -RequireLeaf
    $bytes = [IO.File]::ReadAllBytes($path)
    return [pscustomobject][ordered]@{
        path = $path
        relative_path = (ConvertTo-MorphospaceProtocolRelativePath -Path $RelativePath)
        bytes = $bytes
        sha256 = Get-MorphospaceSha256Bytes -Bytes $bytes
        document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context $Context
    }
}

function Assert-MorphospaceBlockedSupersessionHash {
    param([object]$Value, [string]$Context)
    if ([string]$Value -cnotmatch '^[0-9a-f]{64}$') { throw "$Context is not a lowercase SHA-256." }
}

function Assert-MorphospaceBlockedSupersessionEventEqual {
    param([object]$Expected, [object]$Actual, [string]$Context)
    $expectedHash = Get-MorphospaceCanonicalJsonSha256 -Value $Expected
    $actualHash = Get-MorphospaceCanonicalJsonSha256 -Value $Actual
    if ($expectedHash -cne $actualHash) { throw "$Context does not match the immutable event-ledger record." }
}

function Test-MorphospaceBlockedSupersessionArtifact {
    param(
        [string]$WorkspaceRoot,
        [object]$Artifact,
        [string]$Context
    )
    Assert-MorphospaceExactPropertySet $Artifact @('bytes_base64', 'path', 'sha256') @() $Context
    Assert-MorphospaceBlockedSupersessionHash $Artifact.sha256 "$Context hash"
    $relative = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$Artifact.path)
    $embedded = try { [Convert]::FromBase64String([string]$Artifact.bytes_base64) } catch { throw "$Context has invalid base64 bytes." }
    $embeddedHash = Get-MorphospaceSha256Bytes -Bytes $embedded
    if ($embeddedHash -cne [string]$Artifact.sha256) { throw "$Context embedded-byte hash drifted." }
    $livePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $relative -RequireLeaf
    $liveBytes = [IO.File]::ReadAllBytes($livePath)
    if ((Get-MorphospaceSha256Bytes -Bytes $liveBytes) -cne $embeddedHash -or $liveBytes.Length -ne $embedded.Length) {
        throw "$Context live artifact bytes drifted."
    }
}

function Test-MorphospaceBlockedSupersessionTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][object]$Row,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [string]$ExpectedPreStateSha256 = '',
        [string]$ExpectedPreUnitSha256 = '',
        [string]$ExpectedTargetUnitId = '',
        [ValidateSet(
            'rusty.morphospace.workflow.transition_ledger_intent.v1',
            'rusty.morphospace.workflow.transition_ledger_intent.v2'
        )][string]$ExpectedIntentSchema = 'rusty.morphospace.workflow.transition_ledger_intent.v1'
    )

    $event = $Row.document
    $eventId = [string]$event.event_id
    $transactionId = "$eventId-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentFile = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath $intentRelative -Context "transition intent '$eventId'"
    $completionFile = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath $completionRelative -Context "transition completion '$eventId'"
    $intent = $intentFile.document
    $completion = $completionFile.document

    $intentProperties = @('artifacts','created_at','event','events','expected','pre','schema','state','status','target','transaction_id','unit')
    if ($ExpectedIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2') {
        $intentProperties += 'supersession'
    }
    Assert-MorphospaceExactPropertySet $intent $intentProperties @() "transition intent '$eventId'"
    if ([string]$intent.schema -cne $ExpectedIntentSchema -or [string]$intent.status -cne 'prepared') {
        throw "Transition intent '$eventId' is not the expected prepared owner transaction."
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))
    if ([string]$intent.transaction_id -cne $transactionId) { throw "Transition intent '$eventId' has a mismatched transaction ID." }
    Assert-MorphospaceExactPropertySet $intent.events @('path') @() "transition intent '$eventId' events reference"
    Assert-MorphospaceExactPropertySet $intent.state @('path') @() "transition intent '$eventId' state reference"
    Assert-MorphospaceExactPropertySet $intent.unit @('path') @() "transition intent '$eventId' unit reference"
    if ([string]$intent.events.path -cne 'iteration-events.jsonl' -or [string]$intent.state.path -cne 'workspace.state.json') {
        throw "Transition intent '$eventId' does not target the canonical state and ledger paths."
    }
    $eventUnitId = [string]$event.unit_id
    $targetUnitId = if ($ExpectedTargetUnitId) { $ExpectedTargetUnitId } else { $eventUnitId }
    if (-not $eventUnitId -or -not $targetUnitId -or [string]$intent.unit.path -cne "iteration-units/$targetUnitId.json") {
        throw "Transition intent '$eventId' does not target its exact unit path."
    }

    Assert-MorphospaceExactPropertySet $intent.expected @('event_tail_id','events_length','events_sha256','state_sha256','unit_sha256') @() "transition intent '$eventId' expected preimage"
    Assert-MorphospaceExactPropertySet $intent.pre @('state','unit') @() "transition intent '$eventId' preimage"
    Assert-MorphospaceExactPropertySet $intent.pre.state @('sha256') @() "transition intent '$eventId' pre-state"
    Assert-MorphospaceExactPropertySet $intent.pre.unit @('sha256') @() "transition intent '$eventId' pre-unit"
    foreach ($hash in @($intent.expected.events_sha256, $intent.expected.state_sha256, $intent.expected.unit_sha256, $intent.pre.state.sha256, $intent.pre.unit.sha256)) {
        Assert-MorphospaceBlockedSupersessionHash $hash "Transition intent '$eventId' preimage hash"
    }
    if ([int64]$intent.expected.events_length -ne [int64]$Row.start_offset -or [string]$intent.expected.events_sha256 -cne [string]$Row.prefix_sha256) {
        throw "Transition intent '$eventId' does not bind the exact ledger prefix before its event."
    }
    $previousEventId = if ([int]$Row.ordinal -eq 0) { $null } else { [string]$Ledger.rows[[int]$Row.ordinal - 1].document.event_id }
    if ([string]$intent.expected.event_tail_id -cne [string]$previousEventId) { throw "Transition intent '$eventId' has a mismatched predecessor event." }
    if ([string]$intent.expected.state_sha256 -cne [string]$intent.pre.state.sha256 -or [string]$intent.expected.unit_sha256 -cne [string]$intent.pre.unit.sha256) {
        throw "Transition intent '$eventId' expected and preimage hashes disagree."
    }
    if ($ExpectedPreStateSha256 -and [string]$intent.pre.state.sha256 -cne $ExpectedPreStateSha256) {
        throw "Transition intent '$eventId' is detached from the preceding state target."
    }
    if ($ExpectedPreUnitSha256 -and [string]$intent.pre.unit.sha256 -cne $ExpectedPreUnitSha256) {
        throw "Transition intent '$eventId' is detached from the preceding unit target."
    }
    Assert-MorphospaceBlockedSupersessionEventEqual -Expected $intent.event -Actual $event -Context "Transition intent '$eventId' event"
    if ([string]$intent.event.project_id -cne $ProjectId -or [string]$intent.event.unit_id -cne $eventUnitId) {
        throw "Transition intent '$eventId' project or unit identity drifted."
    }

    Assert-MorphospaceExactPropertySet $intent.target @('state','unit') @() "transition intent '$eventId' target"
    foreach ($targetName in @('state','unit')) {
        $target = $intent.target.$targetName
        Assert-MorphospaceExactPropertySet $target @('document','sha256') @() "transition intent '$eventId' target $targetName"
        Assert-MorphospaceBlockedSupersessionHash $target.sha256 "Transition intent '$eventId' target $targetName hash"
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $target.document) -cne [string]$target.sha256) {
            throw "Transition intent '$eventId' target $targetName document hash drifted."
        }
    }
    if ([string]$intent.target.state.document.project_id -cne $ProjectId -or
        [string]$intent.target.unit.document.project_id -cne $ProjectId -or
        [string]$intent.target.unit.document.unit_id -cne $targetUnitId -or
        [string]$intent.target.state.document.last_event_id -cne $eventId) {
        throw "Transition intent '$eventId' target identity or event projection drifted."
    }
    if ($ExpectedIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2') {
        $delimiter = '-superseded-by-'
        $oldUnitId = $eventUnitId
        if ($eventId -cne "$oldUnitId$delimiter$targetUnitId" -or
            [string]$event.event_type -cne 'state-transition' -or
            @($event.receipts).Count -ne 0) {
            throw "Supersession transaction '$eventId' does not carry the exact old-to-replacement event."
        }
        $binding = $intent.supersession
        Assert-MorphospaceExactPropertySet $binding @('new_unit_id','old_unit','old_unit_id','pre_state','target_unit_path') @() "supersession binding '$eventId'"
        Assert-MorphospaceExactPropertySet $binding.pre_state @('document','path','sha256') @() "supersession pre-state binding '$eventId'"
        Assert-MorphospaceExactPropertySet $binding.old_unit @('document','path','sha256') @() "supersession old-unit binding '$eventId'"
        $oldUnitPath = "iteration-units/$oldUnitId.json"
        $targetUnitPath = "iteration-units/$targetUnitId.json"
        if ([string]$binding.old_unit_id -cne $oldUnitId -or
            [string]$binding.new_unit_id -cne $targetUnitId -or
            [string]$binding.pre_state.path -cne 'workspace.state.json' -or
            [string]$binding.old_unit.path -cne $oldUnitPath -or
            [string]$binding.target_unit_path -cne $targetUnitPath) {
            throw "Supersession transaction '$eventId' has detached paths or endpoint identities."
        }
        foreach ($hash in @($binding.pre_state.sha256, $binding.old_unit.sha256)) {
            Assert-MorphospaceBlockedSupersessionHash $hash "Supersession transaction '$eventId' binding hash"
        }
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $binding.pre_state.document) -cne [string]$binding.pre_state.sha256 -or
            [string]$binding.pre_state.sha256 -cne [string]$intent.pre.state.sha256 -or
            [string]$binding.pre_state.document.project_id -cne $ProjectId -or
            [string]$binding.pre_state.document.current_unit -cne $oldUnitId -or
            [string]$binding.pre_state.document.next_ready_unit -cne $targetUnitId -or
            [string]$binding.pre_state.document.last_event_id -cne [string]$intent.expected.event_tail_id) {
            throw "Supersession transaction '$eventId' has an invalid authenticated pre-state."
        }
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $binding.old_unit.document) -cne [string]$binding.old_unit.sha256 -or
            [string]$binding.old_unit.document.project_id -cne $ProjectId -or
            [string]$binding.old_unit.document.unit_id -cne $oldUnitId -or
            [string]$binding.old_unit.document.status -cnotin @('active','validating')) {
            throw "Supersession transaction '$eventId' has an invalid authenticated old unit."
        }
        $liveOldUnit = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath $oldUnitPath -Context "superseded unit '$oldUnitId'"
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $liveOldUnit.document) -cne [string]$binding.old_unit.sha256) {
            throw "Supersession transaction '$eventId' old-unit bytes no longer match the immutable binding."
        }
        if ([string]$intent.target.state.document.current_unit -cne $targetUnitId -or
            $null -ne $intent.target.state.document.next_ready_unit -or
            [string]$intent.target.unit.document.status -cne 'active' -or
            [string]$intent.target.state.document.last_accepted_receipt -cne [string]$binding.pre_state.document.last_accepted_receipt) {
            throw "Supersession transaction '$eventId' target is not the exact non-accepting current replacement projection."
        }
        $readyReplacement = $intent.target.unit.document | ConvertTo-Json -Depth 64 | ConvertFrom-Json
        $readyReplacement.status = 'ready'
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $readyReplacement) -cne [string]$intent.pre.unit.sha256) {
            throw "Supersession transaction '$eventId' pre-unit hash is not the exact ready form of its active replacement target."
        }
    }
    foreach ($artifact in @($intent.artifacts)) {
        Test-MorphospaceBlockedSupersessionArtifact -WorkspaceRoot $WorkspaceRoot -Artifact $artifact -Context "transition intent '$eventId' artifact"
    }

    Assert-MorphospaceExactPropertySet $completion @('completed_at','event_id','intent','schema','state_sha256','status','transaction_id','unit_sha256') @() "transition completion '$eventId'"
    if ([string]$completion.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or [string]$completion.status -cne 'committed') {
        throw "Transition completion '$eventId' is not committed v1 evidence."
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))
    if ([string]$completion.event_id -cne $eventId -or [string]$completion.transaction_id -cne $transactionId) {
        throw "Transition completion '$eventId' identity drifted."
    }
    Assert-MorphospaceExactPropertySet $completion.intent @('path','role','schema','sha256') @() "transition completion '$eventId' intent reference"
    if ([string]$completion.intent.path -cne $intentRelative -or
        [string]$completion.intent.role -cne 'transition-ledger-intent' -or
        [string]$completion.intent.schema -cne [string]$intent.schema -or
        [string]$completion.intent.sha256 -cne [string]$intentFile.sha256) {
        throw "Transition completion '$eventId' does not bind its exact intent bytes."
    }
    if ([string]$completion.state_sha256 -cne [string]$intent.target.state.sha256 -or
        [string]$completion.unit_sha256 -cne [string]$intent.target.unit.sha256) {
        throw "Transition completion '$eventId' does not bind its target state and unit."
    }
    return [pscustomobject][ordered]@{
        event = $event
        intent = $intent
        intent_sha256 = $intentFile.sha256
        completion = $completion
        state_document = $intent.target.state.document
        state_sha256 = [string]$intent.target.state.sha256
        unit_document = $intent.target.unit.document
        unit_sha256 = [string]$intent.target.unit.sha256
    }
}

function Test-MorphospaceBlockedSupersessionValidationReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$UnitId
    )
    $file = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -Context "blocked supersession validation receipt '$UnitId'"
    $schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) '..\schemas\validation-receipt.schema.json'
    $json = [Text.UTF8Encoding]::new($false, $true).GetString($file.bytes)
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath)) { throw "Validation receipt '$RelativePath' fails its owner schema." }
    $receipt = $file.document
    if ([string]$receipt.schema -cne 'rusty.morphospace.workflow.validation_receipt.v1' -or
        [string]$receipt.project_id -cne $ProjectId -or
        [string]$receipt.unit_id -cne $UnitId -or
        [string]$receipt.result -cne 'fail') {
        throw "Validation receipt '$RelativePath' is not an exact same-unit fail result."
    }
    return $receipt
}

function Test-MorphospaceBlockedSupersessionTerminalValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$SupersessionEventId,
        [Parameter(Mandatory = $true)][string]$ReplacementUnitId
    )

    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $ledger = Get-MorphospaceBlockedSupersessionLedger -WorkspaceRoot $workspace
    $supersessionRows = @($ledger.rows | Where-Object { [string]$_.document.event_id -ceq $SupersessionEventId })
    if ($supersessionRows.Count -ne 1) { throw "Supersession event '$SupersessionEventId' is not one exact ledger record." }
    $supersessionRow = $supersessionRows[0]

    $escapedUnit = [Regex]::Escape($ReplacementUnitId)
    $failRows = @($ledger.rows | Where-Object { [string]$_.document.event_id -cmatch "^$escapedUnit-validation-fail-[0-9]{4,}$" })
    if ($failRows.Count -eq 0) {
        return [pscustomobject][ordered]@{
            history_present = $false
            authenticated = $false
            replacement_unit_id = $ReplacementUnitId
            fail_event_id = $null
            continuation_event_count = 0
        }
    }
    if ($failRows.Count -ne 1) { throw "Replacement '$ReplacementUnitId' has more than one candidate validation-fail terminal chain." }
    $supersessionEvent = $supersessionRow.document
    $oldUnitId = [string]$supersessionEvent.unit_id
    if (-not $oldUnitId -or
        [string]$supersessionEvent.project_id -cne $ProjectId -or
        [string]$supersessionEvent.event_type -cne 'state-transition' -or
        [string]$supersessionEvent.event_id -cne "$oldUnitId-superseded-by-$ReplacementUnitId") {
        throw "Supersession event '$SupersessionEventId' does not exactly bind its old and replacement identities."
    }
    $supersession = Test-MorphospaceBlockedSupersessionTransaction `
        -WorkspaceRoot $workspace `
        -Ledger $ledger `
        -Row $supersessionRow `
        -ProjectId $ProjectId `
        -ExpectedTargetUnitId $ReplacementUnitId `
        -ExpectedIntentSchema 'rusty.morphospace.workflow.transition_ledger_intent.v2'
    $failRow = $failRows[0]
    if ([int]$supersessionRow.ordinal -ge [int]$failRow.ordinal) { throw "Replacement '$ReplacementUnitId' failed before its supersession edge." }
    $failEvent = $failRow.document
    $expectedFailId = '{0}-validation-fail-{1:D4}' -f $ReplacementUnitId, [int]$failEvent.sequence
    if ([string]$failEvent.event_id -cne $expectedFailId -or
        [string]$failEvent.project_id -cne $ProjectId -or
        [string]$failEvent.unit_id -cne $ReplacementUnitId -or
        [string]$failEvent.event_type -cne 'blocker' -or
        [string]$failEvent.summary -cne 'Recorded non-passing validation and blocked further acceptance.') {
        throw "Replacement '$ReplacementUnitId' has a malformed validation-fail event."
    }
    if ([int]$failRow.ordinal -eq 0) { throw "Replacement '$ReplacementUnitId' has no BeginValidation predecessor." }
    $beginRow = $ledger.rows[[int]$failRow.ordinal - 1]
    $beginEvent = $beginRow.document
    $expectedBeginId = '{0}-validating-{1:D4}' -f $ReplacementUnitId, [int]$beginEvent.sequence
    if ([string]$beginEvent.event_id -cne $expectedBeginId -or
        [string]$beginEvent.project_id -cne $ProjectId -or
        [string]$beginEvent.unit_id -cne $ReplacementUnitId -or
        [string]$beginEvent.event_type -cne 'state-transition' -or
        [string]$beginEvent.summary -cne 'Entered validation with a deterministic command, instruction, graph, and device-impact plan.' -or
        @($beginEvent.receipts).Count -ne 0 -or
        [int]$failEvent.sequence -ne ([int]$beginEvent.sequence + 1)) {
        throw "Replacement '$ReplacementUnitId' does not have the exact BeginValidation-to-fail event pair."
    }
    if ([int]$beginRow.ordinal -ne ([int]$supersessionRow.ordinal + 1)) {
        throw "BeginValidation is not the immediate owner transition after the authenticated supersession edge."
    }

    $begin = Test-MorphospaceBlockedSupersessionTransaction `
        -WorkspaceRoot $workspace `
        -Ledger $ledger `
        -Row $beginRow `
        -ProjectId $ProjectId `
        -ExpectedPreStateSha256 $supersession.state_sha256 `
        -ExpectedPreUnitSha256 $supersession.unit_sha256
    if ([string]$begin.unit_document.status -cne 'validating' -or
        [string]$begin.state_document.current_unit -cne $ReplacementUnitId -or
        [string]$begin.state_document.last_event_id -cne [string]$beginEvent.event_id) {
        throw "BeginValidation target does not project the replacement as the current validating unit."
    }
    $beginPreUnit = $begin.unit_document | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $beginPreUnit.status = 'active'
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $beginPreUnit) -cne [string]$begin.intent.pre.unit.sha256) {
        throw "BeginValidation pre-unit hash is not the exact active form of its validating target."
    }

    $fail = Test-MorphospaceBlockedSupersessionTransaction -WorkspaceRoot $workspace -Ledger $ledger -Row $failRow -ProjectId $ProjectId -ExpectedPreStateSha256 $begin.state_sha256 -ExpectedPreUnitSha256 $begin.unit_sha256
    if ([string]$fail.intent.expected.event_tail_id -cne [string]$beginEvent.event_id) {
        throw "Validation-fail intent is not attached directly to BeginValidation."
    }
    if ([string]$fail.unit_document.status -cne 'blocked' -or
        $null -ne $fail.state_document.current_unit -or
        $null -ne $fail.state_document.next_ready_unit -or
        [string]$fail.state_document.last_event_id -cne [string]$failEvent.event_id) {
        throw "Validation-fail target is not the exact terminal blocked projection."
    }
    if (@($failEvent.receipts).Count -ne 1 -or @($failEvent.receipts)[0] -isnot [string]) {
        throw "Validation-fail event must reference exactly one v1 validation receipt path."
    }
    $receiptPath = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]@($failEvent.receipts)[0])
    $receipt = Test-MorphospaceBlockedSupersessionValidationReceipt -WorkspaceRoot $workspace -RelativePath $receiptPath -ProjectId $ProjectId -UnitId $ReplacementUnitId
    $checkpoint = $fail.state_document.validation_checkpoint
    if ($null -eq $checkpoint -or
        [string]$checkpoint.receipt -cne $receiptPath -or
        [string]$checkpoint.result -cne 'fail' -or
        [string]$checkpoint.tier -cne [string]$receipt.tier) {
        throw "Validation-fail target checkpoint does not bind its same-unit fail receipt."
    }
    $blockerId = "$ReplacementUnitId-validation-fail"
    $blockers = @($fail.state_document.blockers | Where-Object { [string]$_.blocker_id -ceq $blockerId })
    if ($blockers.Count -ne 1 -or
        [string]$blockers[0].condition -cne "Validation result is fail in $receiptPath." -or
        [string]$blockers[0].resume_when -cne 'Correct the failure and explicitly resume the unit.') {
        throw "Validation-fail target lacks its exact owner-defined blocker projection."
    }
    if ([string]$fail.state_document.last_accepted_receipt -cne [string]$begin.state_document.last_accepted_receipt) {
        throw "Validation-fail target inferred or changed acceptance state."
    }

    $stateProjection = $fail.state_document
    $stateProjectionSha256 = $fail.state_sha256
    $unitProjection = @{}
    $unitProjection[$ReplacementUnitId] = [pscustomobject][ordered]@{ document = $fail.unit_document; sha256 = $fail.unit_sha256 }
    $continuationCount = 0
    for ($ordinal = [int]$failRow.ordinal + 1; $ordinal -lt $ledger.rows.Count; $ordinal++) {
        $row = $ledger.rows[$ordinal]
        $eventUnitId = [string]$row.document.unit_id
        if (-not $eventUnitId) { throw "Later event '$([string]$row.document.event_id)' lacks a unit identity required for historical derivation." }
        $knownUnitSha = if ($unitProjection.ContainsKey($eventUnitId)) { [string]$unitProjection[$eventUnitId].sha256 } else { '' }
        $transition = Test-MorphospaceBlockedSupersessionTransaction -WorkspaceRoot $workspace -Ledger $ledger -Row $row -ProjectId $ProjectId -ExpectedPreStateSha256 $stateProjectionSha256 -ExpectedPreUnitSha256 $knownUnitSha
        $stateProjection = $transition.state_document
        $stateProjectionSha256 = $transition.state_sha256
        $unitProjection[$eventUnitId] = [pscustomobject][ordered]@{ document = $transition.unit_document; sha256 = $transition.unit_sha256 }
        $continuationCount++
    }

    $liveStateFile = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $workspace -RelativePath 'workspace.state.json' -Context 'live workspace state'
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $liveStateFile.document) -cne $stateProjectionSha256) {
        throw "Live workspace state is not derivable from the authenticated fail transition and later event chain."
    }
    foreach ($unitId in @($unitProjection.Keys)) {
        $liveUnit = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $workspace -RelativePath "iteration-units/$unitId.json" -Context "live iteration unit '$unitId'"
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $liveUnit.document) -cne [string]$unitProjection[$unitId].sha256) {
            throw "Live unit '$unitId' is not derivable from the authenticated fail transition and later event chain."
        }
    }
    $liveReplacement = $unitProjection[$ReplacementUnitId].document
    if ([string]$liveReplacement.status -cnotin @('blocked','active','validating','accepted')) {
        throw "Replacement '$ReplacementUnitId' has an illegal live status after its authenticated fail history."
    }
    return [pscustomobject][ordered]@{
        history_present = $true
        authenticated = $true
        replacement_unit_id = $ReplacementUnitId
        fail_event_id = [string]$failEvent.event_id
        begin_event_id = [string]$beginEvent.event_id
        supersession_event_id = [string]$supersessionEvent.event_id
        validation_receipt = $receiptPath
        continuation_event_count = $continuationCount
        final_state_sha256 = $stateProjectionSha256
        live_replacement_status = [string]$liveReplacement.status
        acceptance_inferred = $false
    }
}

Export-ModuleMember -Function Test-MorphospaceBlockedSupersessionTerminalValidation
