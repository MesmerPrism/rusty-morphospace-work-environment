Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceActiveUnitContractReviewCompatibility.psm1') -Force

function Copy-ActiveUnitContractDocument {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Read-ActiveUnitContractEvents {
    param([Parameter(Mandatory)][string]$Path)
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { throw 'Active-unit contract correction requires a ledger without blank records.' }
        try { $events.Add(($line | ConvertFrom-Json)) | Out-Null } catch { throw 'Active-unit contract correction requires a valid iteration event ledger.' }
    }
    if ($events.Count -eq 0) { throw 'CorrectActiveUnitContract requires a non-empty iteration event ledger.' }
    return @($events.ToArray())
}

function Assert-ActiveUnitContractProtocolDocument {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    $schemaName = switch ([string]$Document.schema) {
        'rusty.morphospace.workflow.project_spec.v2' { 'project-spec-v2.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v2' { 'workspace-state-v2.schema.json' }
        'rusty.morphospace.workflow.iteration_unit.v1' { 'iteration-unit.schema.json' }
        'rusty.morphospace.workflow.iteration_event.v1' { 'iteration-event.schema.json' }
        default { throw "Unsupported workflow document schema for ${Label}: $([string]$Document.schema)" }
    }
    if (-not (Test-Json -Json ($Document | ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $RepositoryRoot "schemas\$schemaName"))) {
        throw "Workflow document '$Label' does not satisfy '$schemaName'."
    }
}

function Get-ActiveUnitContractFixedSkillSurface {
    param([Parameter(Mandatory)][string]$SkillId)
    $common = [ordered]@{
        surface_kind = 'skill'
        owner = 'workflow-maintainer'
        change_reason = 'Correct the current active-unit contract without claiming an instruction update.'
        action = 'review-no-change'
        status = 'planned'
        validation = 'CompleteInstructionSurfaces must observe and complete this declared surface separately.'
    }
    switch ($SkillId) {
        'rusty-morphospace' {
            return [pscustomobject][ordered]@{ surface_kind=$common.surface_kind; path='<skills-root>/rusty-morphospace/SKILL.md'; owner=$common.owner; change_reason=$common.change_reason; action=$common.action; status=$common.status; validation=$common.validation; skill_id='rusty-morphospace' }
        }
        'system-engineering' {
            return [pscustomobject][ordered]@{ surface_kind=$common.surface_kind; path='<skills-root>/system-engineering/SKILL.md'; owner=$common.owner; change_reason=$common.change_reason; action=$common.action; status=$common.status; validation=$common.validation; skill_id='system-engineering' }
        }
        default { throw "CorrectActiveUnitContract does not admit skill '$SkillId'." }
    }
}

function Assert-ActiveUnitContractExactSkillSurfaces {
    param([Parameter(Mandatory)][object[]]$Surfaces)
    $expectedIds = @('rusty-morphospace', 'system-engineering')
    $ids = @($Surfaces | ForEach-Object { [string]$_.skill_id })
    if (($ids -join '|') -cne ($expectedIds -join '|')) { throw 'Correction skill surfaces must be exactly ordered rusty-morphospace and system-engineering.' }
    for ($index = 0; $index -lt $expectedIds.Count; $index++) {
        $expected = Get-ActiveUnitContractFixedSkillSurface -SkillId $expectedIds[$index]
        if ((Get-MorphospaceCanonicalJsonSha256 $Surfaces[$index]) -cne (Get-MorphospaceCanonicalJsonSha256 $expected)) {
            throw "Correction skill surface '$($expectedIds[$index])' does not use the fixed current vocabulary."
        }
    }
}

function Assert-ActiveUnitContractCurrentSkillRules {
    param(
        [Parameter(Mandatory)][object]$Unit,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    Assert-ActiveUnitContractProtocolDocument -Label 'corrected active unit' -Document $Unit -RepositoryRoot $RepositoryRoot
    $lifecyclePath = Join-Path $RepositoryRoot 'manifests\workflow-lifecycle.portable.json'
    $lifecycle = Get-Content -LiteralPath $lifecyclePath -Raw | ConvertFrom-Json
    if ([string]$Unit.work_mode -cne 'feature' -or [string]$Unit.status -cne 'active' -or [string]$State.current_unit -cne [string]$Unit.unit_id) {
        throw 'CorrectActiveUnitContract requires the exact current active feature unit.'
    }
    if ([string]$Unit.instruction_impact -cne 'update') { throw 'Corrected active feature unit must retain update instruction impact.' }

    $surfaces = @($Unit.instruction_surfaces)
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($surface in $surfaces) {
        if (-not $paths.Add([string]$surface.path)) { throw "Corrected active unit repeats instruction surface path '$([string]$surface.path)'." }
    }
    $agents = @($surfaces | Where-Object { [string]$_.surface_kind -ceq 'agents' })
    $routers = @($surfaces | Where-Object { [string]$_.surface_kind -cin @('readme','router-doc') })
    if ($agents.Count -eq 0 -or $routers.Count -eq 0) { throw 'Corrected active unit must retain required AGENTS and README-or-router surfaces.' }
    foreach ($surface in @($agents + $routers)) {
        if ([string]$surface.action -cne 'update') { throw "Corrected active unit required instruction surface '$([string]$surface.path)' must retain update action." }
    }
    if (-not (Test-MorphospaceActiveUnitContractReviewCompatibility -Unit $Unit -State $State -Lifecycle $lifecycle)) {
        throw 'CorrectActiveUnitContract requires exact lifecycle-routed, canonical, non-writable review-no-change skill surfaces.'
    }
}

function Assert-ActiveUnitContractPreservation {
    param(
        [Parameter(Mandatory)][object]$OriginalUnit,
        [Parameter(Mandatory)][object]$TargetUnit,
        [Parameter(Mandatory)][object]$OriginalState,
        [Parameter(Mandatory)][object]$TargetState,
        [Parameter(Mandatory)][object]$OriginalArchitecture
    )
    $unitRestored = Copy-ActiveUnitContractDocument $TargetUnit
    if ($null -eq $OriginalArchitecture) {
        $unitRestored.PSObject.Properties.Remove('architecture_decision')
    } else {
        $unitRestored.architecture_decision = Copy-ActiveUnitContractDocument $OriginalArchitecture
    }
    $unitRestored.instruction_surfaces = @(Copy-ActiveUnitContractDocument @($OriginalUnit.instruction_surfaces))
    if ((Get-MorphospaceCanonicalJsonSha256 $unitRestored) -cne (Get-MorphospaceCanonicalJsonSha256 $OriginalUnit)) {
        throw 'Active-unit contract correction would change a unit field outside architecture_decision and added skill surfaces.'
    }
    $stateRestored = Copy-ActiveUnitContractDocument $TargetState
    $stateRestored.last_event_id = $OriginalState.last_event_id
    if ((Get-MorphospaceCanonicalJsonSha256 $stateRestored) -cne (Get-MorphospaceCanonicalJsonSha256 $OriginalState)) {
        throw 'Active-unit contract correction would change workspace state outside last_event_id.'
    }
}

function Invoke-MorphospaceCorrectActiveUnitContract {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$ActiveUnitContractCorrection,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedActiveUnitContractCorrectionSha256 = '',
        [string]$Timestamp = '',
        [scriptblock]$BeforeTransitionHook,
        [switch]$Execute
    )

    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workspace = (Resolve-Path $WorkspaceRoot).Path
    $correctionPath = (Resolve-Path $ActiveUnitContractCorrection).Path
    $correctionSchema = Join-Path $repoRoot 'schemas\active-unit-contract-correction-v1.schema.json'
    $correctionRaw = Get-Content -Raw -LiteralPath $correctionPath
    if (-not (Test-Json -Json $correctionRaw -SchemaFile $correctionSchema)) { throw 'Active-unit contract correction does not satisfy its schema.' }
    $correction = Read-MorphospaceProtocolJson $correctionPath
    if ([string]$correction.unit_id -cne $UnitId -or [string]$correction.expected.current_unit -cne $UnitId) {
        throw 'Correction identity and expected current unit must exactly match UnitId.'
    }
    Assert-ActiveUnitContractExactSkillSurfaces -Surfaces @($correction.required_skill_surfaces)

    $projectRelative = 'project.spec.json'
    $stateRelative = 'workspace.state.json'
    $unitRelative = "iteration-units/$UnitId.json"
    $eventsRelative = 'iteration-events.jsonl'
    $projectPath = Resolve-MorphospaceWorkspacePath $workspace $projectRelative -RequireLeaf
    $statePath = Resolve-MorphospaceWorkspacePath $workspace $stateRelative -RequireLeaf
    $unitPath = Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace $eventsRelative -RequireLeaf
    $project = Read-MorphospaceProtocolJson $projectPath
    $state = Read-MorphospaceProtocolJson $statePath
    $unit = Read-MorphospaceProtocolJson $unitPath
    $events = @(Read-ActiveUnitContractEvents $eventsPath)
    Assert-ActiveUnitContractProtocolDocument -Label 'project specification' -Document $project -RepositoryRoot $repoRoot
    Assert-ActiveUnitContractProtocolDocument -Label 'workspace state' -Document $state -RepositoryRoot $repoRoot
    foreach ($eventRow in $events) { Assert-ActiveUnitContractProtocolDocument -Label 'iteration event' -Document $eventRow -RepositoryRoot $repoRoot }

    if ([string]$project.project_id -cne [string]$correction.project_id -or [string]$state.project_id -cne [string]$project.project_id -or
        [string]$unit.project_id -cne [string]$project.project_id -or [string]$unit.unit_id -cne $UnitId -or
        [string]$state.current_unit -cne $UnitId -or [string]$unit.status -cne 'active' -or
        -not ($unit.PSObject.Properties.Name -contains 'work_mode') -or [string]$unit.work_mode -cne 'feature') {
        throw 'CorrectActiveUnitContract requires the exact current active feature unit.'
    }

    $projectHash = Get-MorphospaceCanonicalJsonSha256 $project
    $stateHash = Get-MorphospaceCanonicalJsonSha256 $state
    $unitRawHash = Get-MorphospaceFileSha256 $unitPath
    $unitHash = Get-MorphospaceCanonicalJsonSha256 $unit
    $eventsHash = Get-MorphospaceFileSha256 $eventsPath
    $eventsLength = [IO.FileInfo]::new($eventsPath).Length
    $tailId = [string]$events[-1].event_id
    if ([string]$state.last_event_id -cne $tailId) { throw 'Workspace last_event_id does not match the iteration event tail.' }
    foreach ($binding in @(
        [pscustomobject]@{name='project revision';expected=[string]$correction.expected.project_revision;actual=[string]$project.revision},
        [pscustomobject]@{name='project SHA-256';expected=[string]$correction.expected.project_sha256;actual=$projectHash},
        [pscustomobject]@{name='state SHA-256';expected=[string]$correction.expected.state_sha256;actual=$stateHash},
        [pscustomobject]@{name='unit raw SHA-256';expected=[string]$correction.expected.unit_raw_sha256;actual=$unitRawHash},
        [pscustomobject]@{name='unit SHA-256';expected=[string]$correction.expected.unit_sha256;actual=$unitHash},
        [pscustomobject]@{name='event-ledger SHA-256';expected=[string]$correction.expected.events_sha256;actual=$eventsHash},
        [pscustomobject]@{name='event tail';expected=[string]$correction.expected.event_tail_id;actual=$tailId},
        [pscustomobject]@{name='unit status';expected=[string]$correction.expected.status;actual=[string]$unit.status},
        [pscustomobject]@{name='current unit';expected=[string]$correction.expected.current_unit;actual=[string]$state.current_unit}
    )) {
        if ([string]$binding.expected -cne [string]$binding.actual) { throw "Correction expected $([string]$binding.name) does not match the current workspace." }
    }
    if ([int64]$correction.expected.events_length -ne $eventsLength) { throw 'Correction expected event-ledger byte length does not match the current workspace.' }

    $architecturePresent = $unit.PSObject.Properties.Name -contains 'architecture_decision'
    $originalArchitecture = if ($architecturePresent) { $unit.architecture_decision } else { $null }
    if ($architecturePresent -and -not ($originalArchitecture -is [string])) {
        throw 'CorrectActiveUnitContract admits only a missing or legacy string architecture_decision.'
    }
    if ($architecturePresent -and [string]::IsNullOrWhiteSpace([string]$originalArchitecture)) {
        throw 'Legacy architecture_decision must be a non-empty string.'
    }
    if ($architecturePresent -and [string]$correction.architecture_decision.selected -cne [string]$originalArchitecture) {
        throw 'Corrected architecture_decision.selected must retain the legacy string verbatim.'
    }

    $existingSurfaces = @($unit.instruction_surfaces)
    foreach ($skillId in @('rusty-morphospace', 'system-engineering')) {
        $fixed = Get-ActiveUnitContractFixedSkillSurface -SkillId $skillId
        if (@($existingSurfaces | Where-Object { ([string]$_.surface_kind -ceq 'skill' -and [string]$_.skill_id -ceq $skillId) -or [string]$_.path -ceq [string]$fixed.path }).Count -ne 0) {
            throw "CorrectActiveUnitContract may add only a wholly absent '$skillId' skill surface."
        }
    }

    $targetUnit = Copy-ActiveUnitContractDocument $unit
    if ($architecturePresent) { $targetUnit.architecture_decision = Copy-ActiveUnitContractDocument $correction.architecture_decision }
    else { $targetUnit | Add-Member -NotePropertyName architecture_decision -NotePropertyValue (Copy-ActiveUnitContractDocument $correction.architecture_decision) }
    $targetUnit.instruction_surfaces = @(@(Copy-ActiveUnitContractDocument $existingSurfaces) + @(Copy-ActiveUnitContractDocument @($correction.required_skill_surfaces)))

    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    if (-not (Test-MorphospaceStrictUtcTimestamp $Timestamp)) { throw 'Timestamp must be a strict UTC timestamp.' }
    $eventId = "$([string]$correction.correction_id)-recorded"
    if (@($events | Where-Object { [string]$_.event_id -ceq $eventId }).Count -ne 0) { throw 'Correction event identity has already been recorded.' }
    $targetState = Copy-ActiveUnitContractDocument $state
    $targetState.last_event_id = $eventId
    $event = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = $eventId
        sequence = [int]$events[-1].sequence + 1
        timestamp = $Timestamp
        project_id = [string]$project.project_id
        unit_id = $UnitId
        event_type = 'state-transition'
        summary = 'Corrected only the current active feature-unit architecture decision and wholly absent required skill surfaces with exact compare-and-swap bindings.'
        receipts = @()
    }

    $outAbsolute = [IO.Path]::GetFullPath($OutPath)
    $workspacePrefix = $workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $outAbsolute.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Correction output must stay inside the project workspace.' }
    Assert-MorphospaceNoReparseAncestor -Root $workspace -Candidate $outAbsolute
    $outRelative = $outAbsolute.Substring($workspacePrefix.Length).Replace('\','/')
    $expectedOutRelative = "receipts/$([string]$correction.correction_id).json"
    if ($outRelative -cne $expectedOutRelative) { throw "Correction output must be '$expectedOutRelative'." }
    if ([IO.File]::Exists($outAbsolute) -or [IO.Directory]::Exists($outAbsolute)) { throw 'Correction output already exists.' }
    if ([IO.Path]::GetFullPath($correctionPath) -ceq $outAbsolute) { throw 'Correction input and transaction-owned output must be distinct.' }
    foreach ($transactionArtifact in @("receipts/transactions/$eventId-transition.intent.json", "receipts/transactions/$eventId-transition.completion.json")) {
        if ([IO.File]::Exists((Resolve-MorphospaceWorkspacePath $workspace $transactionArtifact)) -or [IO.Directory]::Exists((Resolve-MorphospaceWorkspacePath $workspace $transactionArtifact))) {
            throw "Correction transaction output is already occupied: $transactionArtifact"
        }
    }
    $event.receipts = @($outRelative)

    Assert-ActiveUnitContractCurrentSkillRules -Unit $targetUnit -State $targetState -RepositoryRoot $repoRoot
    Assert-ActiveUnitContractProtocolDocument -Label 'target state' -Document $targetState -RepositoryRoot $repoRoot
    Assert-ActiveUnitContractProtocolDocument -Label 'target event' -Document $event -RepositoryRoot $repoRoot
    Assert-ActiveUnitContractPreservation -OriginalUnit $unit -TargetUnit $targetUnit -OriginalState $state -TargetState $targetState -OriginalArchitecture $originalArchitecture

    $correctionHash = Get-MorphospaceFileSha256 $correctionPath
    if ($ExpectedActiveUnitContractCorrectionSha256 -and $ExpectedActiveUnitContractCorrectionSha256 -cne $correctionHash) {
        throw 'ExpectedActiveUnitContractCorrectionSha256 does not match the correction input.'
    }
    if ($Execute -and -not $ExpectedActiveUnitContractCorrectionSha256) {
        throw 'Executed CorrectActiveUnitContract requires ExpectedActiveUnitContractCorrectionSha256 from the dry run.'
    }

    if ($Execute) {
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" `
            -StatePath $stateRelative -UnitPath $unitRelative -EventsPath $eventsRelative `
            -TargetState $targetState -TargetUnit $targetUnit -Event $event `
            -ExpectedStateSha256 $stateHash -ExpectedUnitSha256 $unitHash -ExpectedPreUnitRawSha256 $unitRawHash `
            -ExpectedEventTailId $tailId -ExpectedEventsSha256 $eventsHash -ExpectedEventsLength $eventsLength `
            -AdditionalProjections @([pscustomobject]@{path=$projectRelative;expected_sha256=$projectHash;document=$project}) `
            -Artifacts @([pscustomobject]@{source_path=$correctionPath;path=$outRelative;sha256=$correctionHash}) | Out-Null
    }

    $result = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id = [string]$project.project_id
        unit_id = $UnitId
        action = 'CorrectActiveUnitContract'
        timestamp = $Timestamp
        executed = $Execute.IsPresent
        transition = 'active-unit-contract-corrected'
        status_before = [string]$unit.status
        status_after = [string]$targetUnit.status
        current_unit_before = $state.current_unit
        current_unit_after = $targetState.current_unit
        preservation = [pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt = [pscustomobject][ordered]@{path=$outRelative;sha256=$correctionHash}
        event_id = $(if ($Execute) { $eventId } else { $null })
    }
    $resultSchema = Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile $resultSchema)) { throw 'CorrectActiveUnitContract emitted an invalid automation receipt.' }
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceCorrectActiveUnitContract
