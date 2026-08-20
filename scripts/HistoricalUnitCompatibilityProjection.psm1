Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalUnitCompatibilityProjection.psm1') -Force

$script:HucActionSummary = 'Recorded one authenticated historical work-unit compatibility projection without rewriting history or inferring completion, validation, acceptance, or publication authority.'

function Copy-HucActionDocument {
    param([Parameter(Mandatory)][object]$Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 100 -Compress))
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'historical compatibility action document copy'
}

function Invoke-MorphospaceHistoricalUnitCompatibilityProjection {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$CompatibilityProjection,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedCompatibilityProjectionSha256 = '',
        [scriptblock]$BeforeTransitionHook,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none',
        [switch]$Execute
    )
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workspace = (Resolve-Path $WorkspaceRoot).Path
    $input = (Resolve-Path $CompatibilityProjection).Path
    $validated = Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $workspace -ReceiptPath $input -Mode PreApply
    $receipt = $validated.receipt
    if ([string]$receipt.authority_unit_id -cne $UnitId) { throw 'Historical compatibility action UnitId is not the exact receipt authority unit.' }
    $inputHash = Get-MorphospaceFileSha256 $input
    if ($ExpectedCompatibilityProjectionSha256 -and $ExpectedCompatibilityProjectionSha256 -cne $inputHash) { throw 'ExpectedCompatibilityProjectionSha256 does not match the projection input.' }
    if ($Execute -and -not $ExpectedCompatibilityProjectionSha256) { throw 'Executed RecordHistoricalUnitCompatibilityProjection requires the reviewed projection SHA-256.' }

    $outAbsolute = [IO.Path]::GetFullPath($OutPath)
    $workspacePrefix = $workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $outAbsolute.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Historical compatibility output must stay inside the workspace.' }
    Assert-MorphospaceNoReparseAncestor -Root $workspace -Candidate $outAbsolute
    $outRelative = $outAbsolute.Substring($workspacePrefix.Length).Replace('\','/')
    if ($outRelative -cne [string]$receipt.projection_event.receipt_path) { throw 'Historical compatibility output path differs from its receipt contract.' }
    if ([IO.File]::Exists($outAbsolute) -or [IO.Directory]::Exists($outAbsolute)) { throw 'Historical compatibility output already exists.' }
    if ($outAbsolute -ceq [IO.Path]::GetFullPath($input)) { throw 'Historical compatibility input and transaction-owned output must be distinct.' }

    $stateRelative = 'workspace.state.json'
    $unitRelative = "iteration-units/$UnitId.json"
    $eventsRelative = 'iteration-events.jsonl'
    $state = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $stateRelative -RequireLeaf)
    $unit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf)
    $stateHash = Get-MorphospaceCanonicalJsonSha256 $state
    $unitHash = Get-MorphospaceCanonicalJsonSha256 $unit
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace $eventsRelative -RequireLeaf
    $eventsHash = Get-MorphospaceFileSha256 $eventsPath
    $eventsLength = [IO.FileInfo]::new($eventsPath).Length
    foreach ($binding in @(
        [pscustomobject]@{label='state';expected=[string]$receipt.expected.state_sha256;actual=$stateHash},
        [pscustomobject]@{label='authority unit';expected=[string]$receipt.expected.authority_unit_sha256;actual=$unitHash},
        [pscustomobject]@{label='event ledger';expected=[string]$receipt.expected.events_sha256;actual=$eventsHash}
    )) { if ([string]$binding.expected -cne [string]$binding.actual) { throw "Historical compatibility $([string]$binding.label) CAS drifted." } }
    if ([int64]$receipt.expected.events_length -ne $eventsLength -or [string]$state.last_event_id -cne [string]$receipt.expected.event_tail_id -or
        [string]$state.current_unit -cne $UnitId -or $null -ne $state.next_ready_unit) { throw 'Historical compatibility state/event projection drifted before execution.' }

    $eventId = [string]$receipt.projection_event.event_id
    $targetState = Copy-HucActionDocument $state
    $targetState.last_event_id = $eventId
    $targetUnit = Copy-HucActionDocument $unit
    $event = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$receipt.projection_event.sequence
        timestamp=[string]$receipt.projection_event.timestamp;project_id=[string]$receipt.project_id;unit_id=$UnitId
        event_type='state-transition';summary=$script:HucActionSummary;receipts=@($outRelative)
    }
    if ([int]$event.sequence -le 0 -or [string]$event.timestamp -cne [string]$receipt.created_at) { throw 'Historical compatibility event sequence/timestamp is inconsistent.' }
    if (-not (Test-Json -Json ($targetState | ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repoRoot 'schemas\workspace-state-v2.schema.json')) -or
        -not (Test-Json -Json ($targetUnit | ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repoRoot 'schemas\iteration-unit.schema.json')) -or
        -not (Test-Json -Json ($event | ConvertTo-Json -Depth 16) -SchemaFile (Join-Path $repoRoot 'schemas\iteration-event.schema.json'))) {
        throw 'Historical compatibility action target documents do not satisfy owner schemas.'
    }
    if ($Execute) {
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" `
            -StatePath $stateRelative -UnitPath $unitRelative -EventsPath $eventsRelative `
            -TargetState $targetState -TargetUnit $targetUnit -Event $event `
            -ExpectedStateSha256 $stateHash -ExpectedUnitSha256 $unitHash -ExpectedEventTailId ([string]$state.last_event_id) `
            -ExpectedEventsSha256 $eventsHash -ExpectedEventsLength $eventsLength `
            -Artifacts @([pscustomobject]@{source_path=$input;path=$outRelative;sha256=$inputHash}) -FaultAfter $FaultAfter | Out-Null
        [void](Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $workspace -ReceiptPath $outAbsolute -Mode PostApply)
    }
    $result = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$receipt.project_id;unit_id=$UnitId
        action='RecordHistoricalUnitCompatibilityProjection';timestamp=[string]$receipt.created_at;executed=$Execute.IsPresent
        transition='historical-unit-compatibility-projected';status_before=[string]$unit.status;status_after=[string]$targetUnit.status
        current_unit_before=[string]$state.current_unit;current_unit_after=[string]$targetState.current_unit
        preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt=[pscustomobject][ordered]@{path=$outRelative;sha256=$inputHash};event_id=$(if($Execute){$eventId}else{$null})
    }
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'))) {
        throw 'Historical compatibility action emitted an invalid automation receipt.'
    }
    $result
}

Export-ModuleMember -Function Invoke-MorphospaceHistoricalUnitCompatibilityProjection
