Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceCompletedTransitionSemanticCorrection.psm1') -Force

function Invoke-MorphospaceCompletedTransitionSemanticCorrection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$CorrectionReceipt,
        [string]$OutPath = '',
        [scriptblock]$BeforeTransitionHook,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter = 'none',
        [switch]$Execute
    )

    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $inputPath = (Resolve-Path -LiteralPath $CorrectionReceipt).Path
    $snapshot = Read-MorphospaceCompletedTransitionSemanticCorrection -Path $inputPath
    $receipt = $snapshot.document
    $canonicalRelative = [string]$receipt.correction_event.receipt_path
    $canonicalTarget = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $canonicalRelative
    $requestedTarget = if ($OutPath) { [IO.Path]::GetFullPath($OutPath) } else { $canonicalTarget }
    if (-not $requestedTarget.Equals($canonicalTarget, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Completed-transition correction OutPath must equal the receipt-derived canonical workspace path.'
    }
    if ($inputPath.Equals($canonicalTarget, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Completed-transition correction requires an inspected input distinct from the transaction-owned workspace receipt.'
    }

    $eventId = [string]$receipt.correction_event.event_id
    $transactionId = "$eventId-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $intentRelative
    $completionPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $completionRelative
    if ([IO.File]::Exists($completionPath)) {
        throw "Completed-transition correction '$eventId' was already consumed."
    }

    $pending = [IO.File]::Exists($intentPath)
    if ($pending) {
        $context = Test-MorphospaceCompletedTransitionSemanticCorrectionPending -WorkspaceRoot $workspace -ReceiptPath $inputPath
    } else {
        $context = Test-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $workspace -ReceiptPath $inputPath -Mode PreApply
        if ([IO.File]::Exists($canonicalTarget)) {
            throw 'Completed-transition correction target already exists without its authenticated pending intent.'
        }
    }

    if ($Execute) {
        if (-not $OutPath) { throw 'Executed completed-transition correction requires explicit canonical OutPath.' }
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        if ($pending) {
            [void](Test-MorphospaceCompletedTransitionSemanticCorrectionPending -WorkspaceRoot $workspace -ReceiptPath $inputPath)
            $repairResult = Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -Repair -FaultAfter $FaultAfter
            if ([string]$repairResult.status -ceq 'already-committed') {
                throw "Completed-transition correction '$eventId' was concurrently consumed."
            }
        } else {
            # Recheck all retained bytes after any caller test hook and before
            # the ledger publishes its mutex-protected CAS-bound intent.
            $context = Test-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $workspace -ReceiptPath $inputPath -Mode PreApply
            $ledgerArguments = @{
                WorkspaceRoot = $workspace
                TransactionId = $transactionId
                StatePath = 'workspace.state.json'
                UnitPath = [string]$receipt.original_transition.replacement_unit.path
                EventsPath = 'iteration-events.jsonl'
                TargetState = $context.target_state
                TargetUnit = $context.target_unit
                Event = $context.correction_event
                ExpectedPreStateSha256 = [string]$receipt.original_transition.state.sha256
                ExpectedPreUnitSha256 = [string]$receipt.original_transition.replacement_unit.sha256
                ExpectedEventTailId = [string]$receipt.original_transition.event.event_id
                ExpectedEventsSha256 = [string]$receipt.original_transition.event_ledger.sha256
                ExpectedEventsLength = [int64]$receipt.original_transition.event_ledger.length
                Artifacts = @([pscustomobject][ordered]@{
                    source_path = $inputPath
                    path = $canonicalRelative
                    sha256 = [string]$snapshot.sha256
                })
                FaultAfter = $FaultAfter
            }
            [void](Start-MorphospaceTransitionLedger @ledgerArguments)
        }
        [void](Test-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $workspace -ReceiptPath $canonicalTarget -Mode Projection -CorrectionEvent $context.correction_event)
    }

    $unit = $receipt.original_transition.replacement_unit.document
    $result = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id = [string]$receipt.project_id
        unit_id = [string]$receipt.semantic_correction.replacement_unit_id
        action = 'CorrectCompletedTransitionSemantics'
        timestamp = [string]$receipt.correction_event.timestamp
        executed = $Execute.IsPresent
        transition = 'completed-transition-semantics-corrected'
        status_before = [string]$unit.status
        status_after = [string]$unit.status
        current_unit_before = [string]$receipt.semantic_correction.replacement_unit_id
        current_unit_after = [string]$receipt.semantic_correction.replacement_unit_id
        preservation = [pscustomobject][ordered]@{
            git_mutation_performed = $false
            device_mutation_performed = $false
            remote_mutation_performed = $false
        }
        audit_receipt = [pscustomobject][ordered]@{
            path = $canonicalRelative
            sha256 = [string]$snapshot.sha256
        }
        event_id = if ($Execute) { $eventId } else { $null }
    }
    $schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\work-unit-automation-receipt-v2.schema.json'
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile $schemaPath)) {
        throw 'Completed-transition correction emitted an invalid automation receipt.'
    }
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceCompletedTransitionSemanticCorrection
