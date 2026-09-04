Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalSupersessionCompatibility.psm1') -Force

$script:HscSummary = 'Recorded exact compatibility evidence for one transactionless historical supersession without creating or rewriting historical artifacts.'

function Copy-HscActionDocument {
    param([Parameter(Mandatory)][object]$Value)
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String
}

function Invoke-MorphospaceHistoricalSupersessionCompatibility {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$CompatibilityReceipt,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedCompatibilityReceiptSha256 = '',
        [scriptblock]$BeforeTransitionHook,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter = 'none',
        [switch]$Execute
    )
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $inputPath = (Resolve-Path -LiteralPath $CompatibilityReceipt).Path
    $inputHash = Get-MorphospaceFileSha256 $inputPath
    if ($ExpectedCompatibilityReceiptSha256 -and $ExpectedCompatibilityReceiptSha256 -cne $inputHash) {
        throw 'ExpectedCompatibilityReceiptSha256 does not match the compatibility input.'
    }
    if ($Execute -and -not $ExpectedCompatibilityReceiptSha256) {
        throw 'Executed RecordHistoricalSupersessionCompatibility requires the reviewed compatibility SHA-256.'
    }
    $snapshot = Read-MorphospaceHistoricalSupersessionCompatibility -Path $inputPath
    $receipt = $snapshot.document
    $canonicalRelative = [string]$receipt.compatibility_event.receipt_path
    $canonicalTarget = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $canonicalRelative
    if ([IO.Path]::GetFullPath($OutPath) -cne $canonicalTarget) {
        throw 'Historical supersession compatibility OutPath differs from its canonical receipt path.'
    }
    if ($inputPath -ceq $canonicalTarget) {
        throw 'Historical supersession compatibility input must be distinct from its transaction-owned output.'
    }

    $eventId = [string]$receipt.compatibility_event.event_id
    $transactionId = "$eventId-transition"
    $intentPath = Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.intent.json"
    $completionPath = Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.completion.json"
    $pending = [IO.File]::Exists($intentPath) -and -not [IO.File]::Exists($completionPath)
    $committed = [IO.File]::Exists($completionPath)

    if ($committed) {
        if (-not [IO.File]::Exists($canonicalTarget) -or (Get-MorphospaceFileSha256 $canonicalTarget) -cne $inputHash) {
            throw 'Committed historical supersession compatibility output differs from the reviewed input.'
        }
        $context = Test-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $workspace -ReceiptPath $canonicalTarget -Mode PostApply
    } elseif ($pending) {
        $context = Test-MorphospaceHistoricalSupersessionCompatibilityPending -WorkspaceRoot $workspace -ReceiptPath $inputPath
    } else {
        if ([IO.File]::Exists($canonicalTarget)) { throw 'Historical supersession compatibility output exists without its transaction completion.' }
        $context = Test-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $workspace -ReceiptPath $inputPath -Mode PreApply
    }

    if ($Execute -and -not $committed) {
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        if ($pending) {
            [void](Test-MorphospaceHistoricalSupersessionCompatibilityPending -WorkspaceRoot $workspace -ReceiptPath $inputPath)
            [void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -Repair -FaultAfter $FaultAfter)
        } else {
            $context = Test-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $workspace -ReceiptPath $inputPath -Mode PreApply
            $state = $context.live_state
            $oldUnit = $context.old_unit
            $targetState = Copy-HscActionDocument $state
            $targetState.last_event_id = $eventId
            $targetUnit = Copy-HscActionDocument $oldUnit
            $transitionEvent = [pscustomobject][ordered]@{
                schema = 'rusty.morphospace.workflow.iteration_event.v1'
                event_id = $eventId
                sequence = [int]$receipt.compatibility_event.sequence
                timestamp = [string]$receipt.compatibility_event.timestamp
                project_id = [string]$receipt.project_id
                unit_id = [string]$receipt.old_unit.unit_id
                event_type = 'state-transition'
                summary = $script:HscSummary
                receipts = @($canonicalRelative)
            }
            Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId `
                -StatePath 'workspace.state.json' -UnitPath ([string]$receipt.old_unit.path) -EventsPath 'iteration-events.jsonl' `
                -TargetState $targetState -TargetUnit $targetUnit -Event $transitionEvent `
                -ExpectedPreStateSha256 ([string]$receipt.expected.state_sha256) `
                -ExpectedPreUnitSha256 ([string]$receipt.expected.old_unit_sha256) `
                -ExpectedPreUnitRawSha256 ([string]$receipt.expected.old_unit_raw_sha256) `
                -ExpectedEventTailId ([string]$receipt.expected.event_tail_id) `
                -ExpectedEventsSha256 ([string]$receipt.expected.events_sha256) `
                -ExpectedEventsLength ([int64]$receipt.expected.events_length) `
                -Artifacts @([pscustomobject][ordered]@{source_path=$inputPath;path=$canonicalRelative;sha256=$inputHash}) `
                -FaultAfter $FaultAfter | Out-Null
        }
        $context = Test-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $workspace -ReceiptPath $canonicalTarget -Mode PostApply
    }

    $result = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id = [string]$receipt.project_id
        unit_id = [string]$receipt.old_unit.unit_id
        action = 'RecordHistoricalSupersessionCompatibility'
        timestamp = [string]$receipt.compatibility_event.timestamp
        executed = $Execute.IsPresent
        transition = 'historical-supersession-compatibility-recorded'
        status_before = [string]$receipt.old_unit.status
        status_after = [string]$receipt.old_unit.status
        current_unit_before = $null
        current_unit_after = $null
        preservation = [pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt = [pscustomobject][ordered]@{path=$canonicalRelative;sha256=$inputHash}
        event_id = if ($Execute) { $eventId } else { $null }
    }
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'))) {
        throw 'Historical supersession compatibility action emitted an invalid automation receipt.'
    }
    $result
}

Export-ModuleMember -Function Invoke-MorphospaceHistoricalSupersessionCompatibility
