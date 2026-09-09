Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'AdmissionCompletionTimestampRecovery.psm1')

function Test-MorphospaceProposedRetirementJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Schemas,
        [Parameter(Mandatory)][string]$Context
    )
    if (-not [IO.File]::Exists($Path)) { throw "$Context is missing: $Path" }
    $raw = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
    $document = Read-MorphospaceProtocolJson -Path $Path
    $schemaName = switch -CaseSensitive ([string]$document.schema) {
        'rusty.morphospace.workflow.project_spec.v1' { 'project-spec.schema.json' }
        'rusty.morphospace.workflow.project_spec.v2' { 'project-spec-v2.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v1' { 'workspace-state.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v2' { 'workspace-state-v2.schema.json' }
        'rusty.morphospace.workflow.iteration_unit.v1' { 'iteration-unit.schema.json' }
        default { '' }
    }
    if (-not $schemaName -or $Schemas -cnotcontains $schemaName) {
        throw "$Context has unsupported schema '$([string]$document.schema)'."
    }
    $schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) "schemas/$schemaName"
    if (-not (Test-Json -Json $raw -SchemaFile $schemaPath)) { throw "$Context does not satisfy '$schemaName'." }
    return $document
}

function Read-MorphospaceProposedRetirementEvents {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { throw "Iteration event ledger is missing: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.LongLength -gt 67108864) { throw 'Iteration event ledger exceeds the 64 MiB protocol bound.' }
    if ($bytes.LongLength -gt 0 -and $bytes[$bytes.LongLength - 1] -ne 0x0a) { throw 'Iteration event ledger must end with LF.' }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) } catch { throw 'Iteration event ledger is not strict UTF-8.' }
    $events = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previousSequence = 0
    $schemaRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas'
    foreach ($line in @($text -split "`n", 0)) {
        if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
        if (-not $line) { continue }
        try { $event = $line | ConvertFrom-Json -DateKind String } catch { throw "Iteration event ledger contains malformed JSON: $($_.Exception.Message)" }
        $schemaName = switch -CaseSensitive ([string]$event.schema) {
            'rusty.morphospace.workflow.iteration_event.v1' { 'iteration-event.schema.json' }
            'rusty.morphospace.workflow.iteration_event.v2' { 'iteration-event-v2.schema.json' }
            default { throw "Iteration event ledger contains unsupported schema '$([string]$event.schema)'." }
        }
        if (-not (Test-Json -Json $line -SchemaFile (Join-Path $schemaRoot $schemaName))) { throw "Iteration event ledger contains an invalid '$schemaName' record." }
        if (-not $seen.Add([string]$event.event_id) -or [int]$event.sequence -ne ($previousSequence + 1)) { throw 'Iteration event ledger identity or sequence is invalid.' }
        $previousSequence = [int]$event.sequence
        $events.Add($event)
    }
    return [pscustomobject][ordered]@{
        events = @($events.ToArray())
        bytes = $bytes
        sha256 = Get-MorphospaceSha256Bytes -Bytes $bytes
        length = [int64]$bytes.LongLength
        tail_id = if ($events.Count) { [string]$events[$events.Count - 1].event_id } else { $null }
    }
}

function Get-MorphospaceProposedRetirementUnits {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)
    $unitRoot = Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'iteration-units'
    if (-not [IO.Directory]::Exists($unitRoot)) { throw 'Iteration-unit directory is missing.' }
    $map = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $unitRoot -Filter '*.json' -File | Sort-Object Name)) {
        $unit = Test-MorphospaceProposedRetirementJson -Path $file.FullName -Schemas @('iteration-unit.schema.json') -Context 'Iteration unit'
        $unitId = [string]$unit.unit_id
        if ($map.ContainsKey($unitId)) { throw "Duplicate iteration unit '$unitId'." }
        $map[$unitId] = [pscustomobject]@{ document = $unit; path = $file.FullName }
    }
    return $map
}

function Get-MorphospaceProposedRetirementBinding {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitRelativePath,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$ReplacementUnitId,
        [Parameter(Mandatory)][ValidateSet('contract-invalid')][string]$Reason,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][object]$LiveState,
        [Parameter(Mandatory)][object]$LiveUnit,
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][hashtable]$UnitMap,
        [Parameter(Mandatory)][string]$ExpectedStateSha256,
        [Parameter(Mandatory)][string]$ExpectedUnitSha256,
        [Parameter(Mandatory)][string]$ExpectedUnitRawSha256
    )
    $events = @($Ledger.events)
    if ([string]$LiveUnit.status -cne 'proposed') { throw "RetireProposed requires proposed status; '$UnitId' is '$([string]$LiveUnit.status)'." }
    if ($null -ne $LiveState.current_unit -or $null -ne $LiveState.next_ready_unit) { throw 'RetireProposed requires an idle project with no current or next-ready unit.' }
    foreach ($identity in @($UnitId, $ReplacementUnitId)) {
        if ($identity -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$' -or $identity.Contains('-superseded-by-', [StringComparison]::Ordinal)) { throw "RetireProposed received a non-portable or reserved unit identity '$identity'." }
    }
    if ($UnitId -ceq $ReplacementUnitId) { throw 'RetireProposed requires a distinct replacement unit identity.' }
    if ($UnitMap.ContainsKey($ReplacementUnitId)) { throw "RetireProposed replacement identity '$ReplacementUnitId' already exists." }
    if ($events.Count -lt 1) { throw 'RetireProposed requires the exact owner-generated admission event.' }

    $admissionEvent = $events[-1]
    $recoveredAdmission = $null
    $admissionStateSha256 = $ExpectedStateSha256
    if ([string]$admissionEvent.event_id -cmatch '^admission-completion-timestamp-recovered-[0-9]{4,}$') {
        if ($events.Count -lt 2 -or @($admissionEvent.receipts).Count -ne 1) { throw 'RetireProposed requires exactly one authenticated recovery after admission.' }
        $recoveryPath = Resolve-MorphospaceWorkspacePath $WorkspaceRoot ([string]$admissionEvent.receipts[0]) -RequireLeaf
        $recoveredAdmission = Test-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $WorkspaceRoot -RecoveryPath $recoveryPath -Mode Projection -CorrectionEvent $admissionEvent
        if ((Get-MorphospaceCanonicalJsonSha256 $recoveredAdmission.target_state) -cne $ExpectedStateSha256 -or
            (Get-MorphospaceCanonicalJsonSha256 $recoveredAdmission.target_unit) -cne $ExpectedUnitSha256 -or
            [string]$recoveredAdmission.receipt.unit_id -cne $UnitId -or
            [int]$recoveredAdmission.receipt.evidence.admission_event.sequence -ne [int]$events[-2].sequence -or
            [string]$recoveredAdmission.receipt.evidence.admission_event.event_id -cne [string]$events[-2].event_id) {
            throw 'RetireProposed recovered admission does not bind the exact proposed unit and tail.'
        }
        $admissionEvent = $events[-2]
        $admissionStateSha256 = [string]$recoveredAdmission.original_intent.document.target.state.sha256
    }
    $admissionMatch = [regex]::Match([string]$admissionEvent.event_id, '^(?<admission>[a-z0-9][a-z0-9-]{1,127})-admitted$')
    if ([string]$LiveState.last_event_id -cne [string]$events[-1].event_id -or [string]$admissionEvent.project_id -cne $ProjectId -or
        [string]$admissionEvent.unit_id -cne $UnitId -or [string]$admissionEvent.event_type -cne 'state-transition' -or
        [string]$admissionEvent.summary -cne 'Admitted a bounded proposed development unit; normal Ready, Inspect, and Claim remain required.' -or
        -not $admissionMatch.Success -or @($admissionEvent.receipts).Count -ne 1) {
        throw 'RetireProposed requires admission at the current ledger tail or immediately before its authenticated timestamp recovery.'
    }
    $admissionId = [string]$admissionMatch.Groups['admission'].Value
    $receiptRelative = "receipts/$admissionId.json"
    if ([string]@($admissionEvent.receipts)[0] -cne $receiptRelative) { throw 'RetireProposed admission event does not reference its exact admission receipt.' }
    $receiptPath = Resolve-MorphospaceWorkspacePath $WorkspaceRoot $receiptRelative -RequireLeaf
    $receiptRaw = [IO.File]::ReadAllText($receiptPath, [Text.UTF8Encoding]::new($false, $true))
    $receiptSchema = Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas/development-unit-admission-v1.schema.json'
    if (-not (Test-Json -Json $receiptRaw -SchemaFile $receiptSchema)) { throw 'RetireProposed admission receipt is absent or invalid.' }
    $admission = Read-MorphospaceProtocolJson -Path $receiptPath
    if ([string]$admission.admission_id -cne $admissionId -or [string]$admission.project_id -cne $ProjectId -or [string]$admission.unit_id -cne $UnitId -or
        [string]$admission.unit.project_id -cne $ProjectId -or [string]$admission.unit.unit_id -cne $UnitId -or [string]$admission.unit.status -cne 'proposed' -or
        (Get-MorphospaceCanonicalJsonSha256 $admission.unit) -cne $ExpectedUnitSha256) { throw 'RetireProposed admission receipt does not bind the exact live proposed unit.' }

    $admissionTransactionId = "$admissionId-admitted-transition"
    if ($admissionTransactionId -cnotmatch '^[a-z0-9][a-z0-9-]{1,191}$') {
        throw 'RetireProposed admission transaction identity exceeds the 192-character ledger bound.'
    }
    $intentRelative = "receipts/transactions/$admissionTransactionId.intent.json"
    $completionRelative = "receipts/transactions/$admissionTransactionId.completion.json"
    $intentPath = Resolve-MorphospaceWorkspacePath $WorkspaceRoot $intentRelative -RequireLeaf
    $completionPath = Resolve-MorphospaceWorkspacePath $WorkspaceRoot $completionRelative -RequireLeaf
    if ($null -eq $recoveredAdmission) {
        $authentication = Complete-MorphospaceTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId $admissionTransactionId
        if ([string]$authentication.status -cne 'already-committed') { throw 'RetireProposed requires an already committed admission transaction.' }
    }
    $intent = Read-MorphospaceProtocolJson -Path $intentPath
    $completion = Read-MorphospaceProtocolJson -Path $completionPath
    $receiptHash = Get-MorphospaceFileSha256 $receiptPath
    $receiptBytesBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($receiptPath))
    if ([string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or [string]$intent.transaction_id -cne $admissionTransactionId -or
        [string]$intent.state.path -cne 'workspace.state.json' -or [string]$intent.unit.path -cne $UnitRelativePath -or [string]$intent.events.path -cne 'iteration-events.jsonl' -or
        [string]$intent.event.event_id -cne [string]$admissionEvent.event_id -or [int]$intent.event.sequence -ne [int]$admissionEvent.sequence -or
        [string]$intent.target.state.sha256 -cne $admissionStateSha256 -or [string]$intent.target.unit.sha256 -cne $ExpectedUnitSha256 -or @($intent.artifacts).Count -ne 1 -or
        [string]$intent.artifacts[0].path -cne $receiptRelative -or [string]$intent.artifacts[0].sha256 -cne $receiptHash -or [string]$intent.artifacts[0].bytes_base64 -cne $receiptBytesBase64 -or
        [string]$completion.transaction_id -cne $admissionTransactionId -or [string]$completion.event_id -cne [string]$admissionEvent.event_id -or
        [string]$completion.state_sha256 -cne $admissionStateSha256 -or [string]$completion.unit_sha256 -cne $ExpectedUnitSha256) {
        throw 'RetireProposed admission transaction does not bind the exact live state, unit, event, and receipt bytes.'
    }
    $base = [pscustomobject][ordered]@{
        replacement_unit_id = $ReplacementUnitId
        reason = $Reason
        authenticated_admission = [pscustomobject][ordered]@{
            admission_id = $admissionId
            event = [pscustomobject][ordered]@{ event_id = [string]$admissionEvent.event_id; sequence = [int]$admissionEvent.sequence; sha256 = Get-MorphospaceCanonicalJsonSha256 $intent.event }
            receipt = [pscustomobject][ordered]@{ path = $receiptRelative; sha256 = $receiptHash }
            transaction = [pscustomobject][ordered]@{
                transaction_id = $admissionTransactionId
                intent = [pscustomobject][ordered]@{ path = $intentRelative; sha256 = Get-MorphospaceFileSha256 $intentPath }
                completion = [pscustomobject][ordered]@{ path = $completionRelative; sha256 = Get-MorphospaceFileSha256 $completionPath }
                target_state_sha256 = [string]$intent.target.state.sha256
                target_unit_sha256 = [string]$intent.target.unit.sha256
            }
        }
        authenticated_preimage = [pscustomobject][ordered]@{
            state_sha256 = $ExpectedStateSha256; unit_sha256 = $ExpectedUnitSha256; unit_raw_sha256 = $ExpectedUnitRawSha256
            events_sha256 = [string]$Ledger.sha256; events_length = [int64]$Ledger.length; event_tail_id = [string]$Ledger.tail_id
        }
        replacement_identity_absent = $true; current_unit_absent = $true; next_ready_unit_absent = $true; original_admission_preserved = $true
    }
    return [pscustomobject][ordered]@{
        replacement_unit_id = $base.replacement_unit_id; reason = $base.reason; authenticated_admission = $base.authenticated_admission; authenticated_preimage = $base.authenticated_preimage
        replacement_identity_absent = $true; current_unit_absent = $true; next_ready_unit_absent = $true; original_admission_preserved = $true
        binding_sha256 = Get-MorphospaceCanonicalJsonSha256 $base
    }
}

function Assert-MorphospaceLegacyRetirementEnvelope {
    param([object]$Receipt, [object]$Context, [byte[]]$Bytes)
    $schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas/work-unit-automation-receipt.schema.json'
    $raw = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    if (-not (Test-Json -Json $raw -SchemaFile $schemaPath)) { throw 'Legacy RetireProposed adapter returned an invalid complete v1 receipt.' }
    $parsed = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $Bytes -Context 'legacy RetireProposed receipt'
    if ((Get-MorphospaceCanonicalJsonSha256 $Receipt) -cne (Get-MorphospaceCanonicalJsonSha256 $parsed)) { throw 'Legacy RetireProposed adapter returned a non-lossless receipt object.' }
    foreach ($field in @('schema','project_id','unit_id','action','timestamp','transition','status_before','status_after')) {
        if ([string]$parsed.$field -cne [string]$Context.$field) { throw "Legacy RetireProposed adapter changed authoritative field '$field'." }
    }
    if ([bool]$parsed.executed -ne [bool]$Context.executed -or $null -ne $parsed.current_unit_before -or $null -ne $parsed.current_unit_after -or
        [string]$parsed.event_id -cne [string]$Context.event_id -or (Get-MorphospaceCanonicalJsonSha256 $parsed.proposed_retirement) -cne (Get-MorphospaceCanonicalJsonSha256 $Context.proposed_retirement) -or
        [bool]$parsed.preservation.git_mutation_performed -or [bool]$parsed.preservation.device_mutation_performed -or [bool]$parsed.preservation.force_push_allowed) {
        throw 'Legacy RetireProposed adapter changed authoritative retirement identity, binding, target, or preservation semantics.'
    }
    return $parsed
}

function Invoke-MorphospaceProposedUnitRetirementCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('NarrowV1','LegacyAutomationV1')][string]$ReceiptFormat,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$ReplacementUnitId,
        [ValidateSet('contract-invalid')][string]$RetirementReason = 'contract-invalid',
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedStateSha256 = '', [string]$ExpectedUnitSha256 = '', [string]$ExpectedUnitRawSha256 = '',
        [string]$ExpectedEventsSha256 = '', [long]$ExpectedEventsLength = -1, [string]$ExpectedEventTailId = '',
        [string]$ExpectedProposedRetirementBindingSha256 = '',
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$TransitionFaultAfter = 'none',
        [scriptblock]$LegacyEnvelopeFactory,
        [switch]$Execute
    )
    if ($ReceiptFormat -ceq 'NarrowV1' -and $null -ne $LegacyEnvelopeFactory) { throw 'Narrow retirement does not accept a legacy envelope factory.' }
    if ($ReceiptFormat -ceq 'LegacyAutomationV1' -and $null -eq $LegacyEnvelopeFactory) { throw 'Legacy retirement requires its private envelope factory.' }
    if ($TransitionFaultAfter -cne 'none' -and -not $Execute) { throw 'Transition fault injection requires execution.' }
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $workspacePrefix = $workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $outAbsolute = [IO.Path]::GetFullPath($OutPath)
    if (-not $outAbsolute.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'RetireProposed OutPath must stay inside the workspace.' }
    $outRelative = $outAbsolute.Substring($workspacePrefix.Length).Replace('\','/')
    if ($outRelative -cnotmatch '^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$') { throw 'RetireProposed OutPath must be one canonical receipt path.' }
    if ($ReceiptFormat -ceq 'NarrowV1') {
        $Timestamp = ConvertTo-MorphospaceUtcTimestamp $Timestamp
    }
    $projectPath = Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf
    $statePath = Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $project = Test-MorphospaceProposedRetirementJson -Path $projectPath -Schemas @('project-spec.schema.json','project-spec-v2.schema.json') -Context 'Project specification'
    $state = Test-MorphospaceProposedRetirementJson -Path $statePath -Schemas @('workspace-state.schema.json','workspace-state-v2.schema.json') -Context 'Workspace state'
    $unitMap = Get-MorphospaceProposedRetirementUnits $workspace
    if (-not $unitMap.ContainsKey($UnitId)) { throw "Iteration unit '$UnitId' does not exist." }
    $unitEntry = $unitMap[$UnitId]
    $unit = $unitEntry.document
    if ([string]$project.project_id -cne [string]$state.project_id -or [string]$project.project_id -cne [string]$unit.project_id) { throw 'Project identifiers do not agree.' }
    $unitRelative = $unitEntry.path.Substring($workspacePrefix.Length).Replace('\','/')
    if ($unitRelative -cne "iteration-units/$UnitId.json") { throw 'RetireProposed unit path is not canonical for its identity.' }
    $ledger = Read-MorphospaceProposedRetirementEvents $eventsPath
    $preStateHash = Get-MorphospaceCanonicalJsonSha256 $state
    $preUnitHash = Get-MorphospaceCanonicalJsonSha256 $unit
    $preUnitRawHash = Get-MorphospaceFileSha256 $unitEntry.path
    $binding = Get-MorphospaceProposedRetirementBinding -WorkspaceRoot $workspace -UnitRelativePath $unitRelative -UnitId $UnitId -ReplacementUnitId $ReplacementUnitId -Reason $RetirementReason -ProjectId ([string]$project.project_id) -LiveState $state -LiveUnit $unit -Ledger $ledger -UnitMap $unitMap -ExpectedStateSha256 $preStateHash -ExpectedUnitSha256 $preUnitHash -ExpectedUnitRawSha256 $preUnitRawHash
    foreach ($expectation in @(
        @{ name='state'; supplied=$ExpectedStateSha256; actual=$preStateHash }, @{ name='unit'; supplied=$ExpectedUnitSha256; actual=$preUnitHash },
        @{ name='unit raw'; supplied=$ExpectedUnitRawSha256; actual=$preUnitRawHash }, @{ name='events'; supplied=$ExpectedEventsSha256; actual=[string]$ledger.sha256 },
        @{ name='event tail'; supplied=$ExpectedEventTailId; actual=[string]$ledger.tail_id }, @{ name='retirement binding'; supplied=$ExpectedProposedRetirementBindingSha256; actual=[string]$binding.binding_sha256 }
    )) { if ([string]$expectation.supplied -and [string]$expectation.supplied -cne [string]$expectation.actual) { throw "RetireProposed expected $([string]$expectation.name) identity does not match the live authenticated boundary." } }
    if ($ExpectedEventsLength -ge 0 -and $ExpectedEventsLength -ne [int64]$ledger.length) { throw 'RetireProposed expected event-ledger length does not match the live authenticated boundary.' }
    if ($Execute) {
        foreach ($required in @(@{name='ExpectedStateSha256';value=$ExpectedStateSha256},@{name='ExpectedUnitSha256';value=$ExpectedUnitSha256},@{name='ExpectedUnitRawSha256';value=$ExpectedUnitRawSha256},@{name='ExpectedEventsSha256';value=$ExpectedEventsSha256},@{name='ExpectedEventTailId';value=$ExpectedEventTailId},@{name='ExpectedProposedRetirementBindingSha256';value=$ExpectedProposedRetirementBindingSha256})) {
            if (-not [string]$required.value) { throw "Executed RetireProposed requires $([string]$required.name) from its dry run." }
        }
        if ($ExpectedEventsLength -lt 0) { throw 'Executed RetireProposed requires ExpectedEventsLength from its dry run.' }
    }
    $sequence = @($ledger.events).Count + 1
    $eventId = "$UnitId-proposal-retired-$('{0:d4}' -f $sequence)"
    $retirementTransactionId = "$eventId-transition"
    if ($retirementTransactionId -cnotmatch '^[a-z0-9][a-z0-9-]{1,191}$') {
        throw 'RetireProposed transaction identity exceeds the 192-character ledger bound.'
    }
    $event = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1'; event_id=$eventId; sequence=$sequence; timestamp=$Timestamp
        project_id=[string]$state.project_id; unit_id=$UnitId; event_type='state-transition'
        summary="Retired the exact admitted proposed unit because its contract is invalid; preserved its admission chain and recorded intended replacement identity '$ReplacementUnitId' for separate admission."
        receipts=@($outRelative)
    }
    $targetState = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes (ConvertTo-MorphospaceProtocolJsonBytes $state) -Context 'retirement target state'
    $targetUnit = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes (ConvertTo-MorphospaceProtocolJsonBytes $unit) -Context 'retirement target unit'
    $targetState.last_event_id = $eventId
    $targetUnit.status = 'superseded'
    $transaction = [pscustomobject][ordered]@{
        transaction_id=$retirementTransactionId; state_path='workspace.state.json'; unit_path=$unitRelative; events_path='iteration-events.jsonl'; receipt_path=$outRelative; event_id=$eventId
        expected_pre_state_sha256=$preStateHash; expected_pre_unit_sha256=$preUnitHash; expected_pre_unit_raw_sha256=$preUnitRawHash
        expected_events_sha256=[string]$ledger.sha256; expected_events_length=[int64]$ledger.length; expected_event_tail_id=[string]$ledger.tail_id
    }
    $authority = [pscustomobject][ordered]@{
        schema=if($ReceiptFormat-ceq'LegacyAutomationV1'){'rusty.morphospace.workflow.work_unit_automation_receipt.v1'}else{'rusty.morphospace.workflow.proposed_unit_retirement_receipt.v1'}
        project_id=[string]$state.project_id; unit_id=$UnitId; action='RetireProposed'; timestamp=$Timestamp; executed=[bool]$Execute
        transition='proposed-to-superseded-retired'; status_before='proposed'; status_after=if($Execute){'superseded'}else{'proposed'}
        current_unit_before=$null; current_unit_after=$null; proposed_retirement=$binding; event_id=if($Execute){$eventId}else{$null}
        state=if($Execute){$targetState}else{$state}; unit=if($Execute){$targetUnit}else{$unit}; event=if($Execute){$event}else{$null}; transaction=$transaction
    }
    if ($ReceiptFormat -ceq 'LegacyAutomationV1') {
        $before = @($preStateHash,$preUnitHash,$preUnitRawHash,[string]$ledger.sha256,[string]$ledger.length,[string]$ledger.tail_id,[bool][IO.File]::Exists($outAbsolute),[bool][IO.File]::Exists((Join-Path $workspace "receipts/transactions/$eventId-transition.intent.json"))) -join '|'
        $callbackContext = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes (ConvertTo-MorphospaceProtocolJsonBytes $authority) -Context 'legacy RetireProposed callback context'
        $callbackContextSha256 = Get-MorphospaceCanonicalJsonSha256 $callbackContext
        $receipt = & $LegacyEnvelopeFactory $callbackContext
        $afterLedger = Read-MorphospaceProposedRetirementEvents $eventsPath
        $after = @((Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $statePath)),(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $unitEntry.path)),(Get-MorphospaceFileSha256 $unitEntry.path),[string]$afterLedger.sha256,[string]$afterLedger.length,[string]$afterLedger.tail_id,[bool][IO.File]::Exists($outAbsolute),[bool][IO.File]::Exists((Join-Path $workspace "receipts/transactions/$eventId-transition.intent.json"))) -join '|'
        if ((Get-MorphospaceCanonicalJsonSha256 $callbackContext) -cne $callbackContextSha256) { throw 'Legacy RetireProposed adapter mutated its immutable authoritative context.' }
        if ($after -cne $before) { throw 'Legacy RetireProposed adapter mutated or published the authenticated transition boundary.' }
    } else {
        $receipt = [pscustomobject][ordered]@{
            schema=$authority.schema; project_id=$authority.project_id; unit_id=$UnitId; action='RetireProposed'; timestamp=$Timestamp; executed=[bool]$Execute
            transition=$authority.transition; status_before='proposed'; status_after=$authority.status_after; current_unit_before=$null; current_unit_after=$null
            preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;force_push_allowed=$false}
            proposed_retirement=$binding; transaction=$transaction; event_id=$authority.event_id
        }
    }
    $receiptBytes = [Text.UTF8Encoding]::new($false).GetBytes((($receipt | ConvertTo-Json -Depth 32) + [Environment]::NewLine))
    if ($ReceiptFormat -ceq 'LegacyAutomationV1') { $receipt = Assert-MorphospaceLegacyRetirementEnvelope -Receipt $receipt -Context $authority -Bytes $receiptBytes }
    else {
        $raw = [Text.UTF8Encoding]::new($false,$true).GetString($receiptBytes)
        if (-not (Test-Json -Json $raw -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas/proposed-unit-retirement-receipt-v1.schema.json'))) { throw 'Proposed-unit retirement owner produced an invalid narrow receipt.' }
    }
    if ($Execute) {
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId ([string]$transaction.transaction_id) -StatePath 'workspace.state.json' -UnitPath $unitRelative -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event -ExpectedPreStateSha256 $preStateHash -ExpectedPreUnitSha256 $preUnitHash -ExpectedPreUnitRawSha256 $preUnitRawHash -ExpectedEventTailId ([string]$ledger.tail_id) -ExpectedEventsSha256 ([string]$ledger.sha256) -ExpectedEventsLength ([int64]$ledger.length) -Artifacts @([pscustomobject][ordered]@{bytes_base64=[Convert]::ToBase64String($receiptBytes);path=$outRelative;sha256=Get-MorphospaceSha256Bytes $receiptBytes}) -FaultAfter $TransitionFaultAfter | Out-Null
    }
    return $receipt
}

function Invoke-MorphospaceProposedUnitRetirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot, [Parameter(Mandatory)][string]$UnitId, [Parameter(Mandatory)][string]$ReplacementUnitId,
        [ValidateSet('contract-invalid')][string]$RetirementReason='contract-invalid', [Parameter(Mandatory)][string]$Timestamp, [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedStateSha256='', [string]$ExpectedUnitSha256='', [string]$ExpectedUnitRawSha256='', [string]$ExpectedEventsSha256='', [long]$ExpectedEventsLength=-1,
        [string]$ExpectedEventTailId='', [string]$ExpectedProposedRetirementBindingSha256='',
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$TransitionFaultAfter='none', [switch]$Execute
    )
    Invoke-MorphospaceProposedUnitRetirementCore -ReceiptFormat NarrowV1 @PSBoundParameters
}

Export-ModuleMember -Function Invoke-MorphospaceProposedUnitRetirement
