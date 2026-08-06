Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalBlockerResolutionIntentBindingCorrection.psm1') -Force

function Invoke-MorphospaceCorrectHistoricalBlockerResolutionIntentBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$CorrectionReceipt,
        [string]$ExpectedCorrectionSha256 = '',
        [string]$OutPath = '',
        [scriptblock]$BeforeTransitionHook,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter = 'none',
        [switch]$Execute
    )
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $inputPath = (Resolve-Path -LiteralPath $CorrectionReceipt).Path
    $snapshot = Read-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection $inputPath
    $receipt = $snapshot.document
    if ([string]$receipt.current_authority.unit_id -cne $UnitId) { throw 'Historical correction UnitId differs from its exact current-authority binding.' }
    if ($ExpectedCorrectionSha256 -and $ExpectedCorrectionSha256 -cne [string]$snapshot.sha256) { throw 'Historical correction input SHA-256 differs from the expected reviewed bytes.' }
    if ($Execute -and -not $ExpectedCorrectionSha256) { throw 'Executed historical correction requires ExpectedCorrectionSha256 from its dry run.' }

    $canonicalRelative = [string]$receipt.correction_event.receipt_path
    $canonicalTarget = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $canonicalRelative
    $requestedTarget = if ($OutPath) { [IO.Path]::GetFullPath($OutPath) } else { $canonicalTarget }
    if (-not $requestedTarget.Equals($canonicalTarget, [StringComparison]::OrdinalIgnoreCase)) { throw 'Historical correction OutPath must equal the receipt-derived canonical workspace path.' }
    if ($inputPath.Equals($canonicalTarget, [StringComparison]::OrdinalIgnoreCase)) { throw 'Historical correction requires an inspected input distinct from its transaction-owned workspace receipt.' }
    $eventId = [string]$receipt.correction_event.event_id
    $transactionId = "$eventId-transition"
    $completionPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath "receipts/transactions/$transactionId.completion.json"
    if ([IO.File]::Exists($completionPath)) { throw "Historical correction '$eventId' was already consumed." }
    if ([IO.File]::Exists($canonicalTarget)) { throw 'Historical correction target already exists without a completed authenticated transition.' }

    $context = Test-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection -WorkspaceRoot $workspace -ReceiptPath $inputPath -Mode PreApply
    $targetState = $context.current_state | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $targetState.last_event_id = $eventId
    $beforePending = Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$context.current_state.pending_push_bundle})
    $beforeValidation = Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$context.current_state.validation_checkpoint})
    $beforeBlockers = Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=@($context.current_state.blockers)})
    if (
        (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$targetState.pending_push_bundle})) -cne $beforePending -or
        (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$targetState.validation_checkpoint})) -cne $beforeValidation -or
        (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=@($targetState.blockers)})) -cne $beforeBlockers -or
        [string]$targetState.current_unit -cne $UnitId
    ) { throw 'Historical correction changed a preserved workflow projection before transaction.' }

    if ($Execute) {
        if (-not $OutPath) { throw 'Executed historical correction requires explicit canonical OutPath.' }
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        $context = Test-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection -WorkspaceRoot $workspace -ReceiptPath $inputPath -Mode PreApply
        $targetState = $context.current_state | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $targetState.last_event_id = $eventId
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $workspace -TransactionId $transactionId `
            -StatePath 'workspace.state.json' -UnitPath ([string]$receipt.current_authority.unit.path) -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState -TargetUnit $context.current_unit -Event $context.correction_event `
            -ExpectedStateSha256 ([string]$receipt.current_authority.state.canonical_sha256) `
            -ExpectedUnitSha256 ([string]$receipt.current_authority.unit.canonical_sha256) `
            -ExpectedEventTailId ([string]$receipt.current_authority.event_ledger.tail_event_id) `
            -ExpectedEventsSha256 ([string]$receipt.current_authority.event_ledger.sha256) `
            -ExpectedEventsLength ([int64]$receipt.current_authority.event_ledger.length) `
            -Artifacts @([pscustomobject][ordered]@{source_path=$inputPath;path=$canonicalRelative;sha256=[string]$snapshot.sha256}) `
            -FaultAfter $FaultAfter | Out-Null
        [void](Test-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection -WorkspaceRoot $workspace -ReceiptPath $canonicalTarget -Mode Projection)
    }

    $result = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id = [string]$receipt.project_id
        unit_id = $UnitId
        action = 'CorrectHistoricalBlockerResolutionIntentBinding'
        timestamp = [string]$receipt.correction_event.timestamp
        executed = $Execute.IsPresent
        transition = 'historical-blocker-resolution-intent-binding-corrected'
        status_before = [string]$context.current_unit.status
        status_after = [string]$context.current_unit.status
        current_unit_before = $UnitId
        current_unit_after = $UnitId
        preservation = [pscustomobject][ordered]@{
            git_mutation_performed = $false
            device_mutation_performed = $false
            remote_mutation_performed = $false
        }
        audit_receipt = [pscustomobject][ordered]@{path=$canonicalRelative;sha256=[string]$snapshot.sha256}
        event_id = if ($Execute) { $eventId } else { $null }
    }
    $resultSchema = Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\work-unit-automation-receipt-v2.schema.json'
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile $resultSchema)) { throw 'Historical correction emitted an invalid automation receipt.' }
    $result
}

Export-ModuleMember -Function Invoke-MorphospaceCorrectHistoricalBlockerResolutionIntentBinding
