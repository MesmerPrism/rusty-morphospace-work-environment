param(
    [Parameter(Mandatory = $true)][ValidateSet('Inspect', 'Validate')][string]$Action,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$RegistryPath,
    [Parameter(Mandatory = $true)][string]$RepositoryMapPath,
    [Parameter(Mandatory = $true)][string]$CurrentProtocolPath,
    [Parameter(Mandatory = $true)][string]$TrustMigrationPath,
    [Parameter(Mandatory = $true)][string]$ClaimBaselinePath,
    [Parameter(Mandatory = $true)][string]$OwnershipPath,
    [Parameter(Mandatory = $true)][string]$ValidationActionPath,
    [string]$EvidencePath,
    [string]$OutPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceOwnership.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force

function Invoke-MorphospacePinnedValidator {
    param(
        [Parameter(Mandatory = $true)][string]$ValidatorPath,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Quest,
        [Parameter(Mandatory = $true)][string]$Roadmap,
        [Parameter(Mandatory = $true)][string]$Unit,
        [Parameter(Mandatory = $true)][string]$OwnerOut,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    if (Test-Path -LiteralPath $OwnerOut -or Test-Path -LiteralPath $StdoutPath -or Test-Path -LiteralPath $StderrPath) { throw 'Pinned validator output paths must be absent before launch.' }
    $host = (Get-Command powershell.exe -ErrorAction Stop).Source
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ValidatorPath, '-WorkspaceRoot', $Workspace, '-QuestRoot', $Quest, '-RoadmapPath', $Roadmap, '-UnitId', $Unit, '-OutPath', $OwnerOut)
    $process = Start-Process -FilePath $host -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "Pinned validator exceeded its registry timeout of $TimeoutSeconds seconds."
        }
        $stdout = if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) { [IO.File]::ReadAllText($StdoutPath, [Text.UTF8Encoding]::new($false)) } else { '' }
        $stderr = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) { [IO.File]::ReadAllText($StderrPath, [Text.UTF8Encoding]::new($false)) } else { '' }
        return [pscustomobject][ordered]@{ exit_code = [int]$process.ExitCode; stdout = $stdout; stderr = $stderr }
    } finally {
        $process.Dispose()
    }
}

function Assert-MorphospaceAuthorizedAction {
    param([Parameter(Mandatory = $true)][object]$ActionDocument, [Parameter(Mandatory = $true)][object]$Selection, [Parameter(Mandatory = $true)][object]$Unit)
    if ([string]$ActionDocument.schema -ne 'rusty.morphospace.workflow.validation_action.v2' -or [string]$ActionDocument.project_id -ne [string]$Unit.project_id -or [string]$ActionDocument.unit_id -ne [string]$Unit.unit_id -or [string]$ActionDocument.status -ne 'authorized' -or [string]$ActionDocument.profile_id -ne [string]$Selection.profile_id) { throw 'Validation action is not bound to the active unit and selected profile.' }
    if ([string]$Unit.device_requirement -eq 'none' -and $null -ne $ActionDocument.device_validation) { throw 'No-device unit validation action must not carry a device payload.' }
    $selected = @($Selection.validators | ForEach-Object { [pscustomobject]@{ validator_id = [string]$_.validator_id; registry_entry_sha256 = (Get-MorphospaceCanonicalJsonSha256 $_) } } | Sort-Object validator_id)
    $asserted = @($ActionDocument.selected_validators | Sort-Object validator_id)
    if ((Get-MorphospaceCanonicalJsonSha256 $asserted) -ne (Get-MorphospaceCanonicalJsonSha256 $selected)) { throw 'Validation action selected validators are not the exact registry selection.' }
}

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$spec = Read-MorphospaceAuthorityJson (Join-Path $workspace 'project.spec.json')
$unitPath = Join-Path $workspace (Join-Path 'iteration-units' "$UnitId.json")
$unit = Read-MorphospaceAuthorityJson $unitPath
if ([string]$unit.unit_id -ne $UnitId -or [string]$unit.project_id -ne [string]$spec.project_id) { throw 'Unit identity does not match the workspace.' }
$map = Get-MorphospaceFixedRepositoryMap -WorkspaceRoot $workspace -RequiredRepositoryIds @($unit.allowed_repositories | ForEach-Object { [string]$_.repo_id })
$registryAbsolute = Resolve-MorphospaceAuthorityPath $workspace $RegistryPath
$registry = Read-MorphospaceAuthorityJson $registryAbsolute; $registry | Add-Member -NotePropertyName __path -NotePropertyValue $registryAbsolute -Force
Test-MorphospaceOwnerValidatorRegistry -Registry $registry -RepositoryMap $map.map | Out-Null
$protocolAbsolute = Resolve-MorphospaceAuthorityPath $workspace $CurrentProtocolPath
$protocol = Read-MorphospaceAuthorityJson $protocolAbsolute; $protocol | Add-Member -NotePropertyName __path -NotePropertyValue $protocolAbsolute -Force
if ([string]$protocol.project_id -ne [string]$unit.project_id -or [string]$protocol.unit_id -ne $UnitId -or [string]$protocol.status -ne 'active') { throw 'Current protocol does not bind the active unit.' }
$migration = Test-MorphospaceValidatorTrustAnchorMigration -WorkspaceRoot $workspace -MigrationPath $TrustMigrationPath -RegistryReference $protocol.registry -ExpectedProjectId ([string]$unit.project_id) -ExpectedUnitId $UnitId
$baseline = Read-MorphospaceAuthorityJson (Resolve-MorphospaceAuthorityPath $workspace $ClaimBaselinePath)
$ownershipAbsolute = Resolve-MorphospaceAuthorityPath $workspace $OwnershipPath
$ownership = Read-MorphospaceAuthorityJson $ownershipAbsolute; $ownership | Add-Member -NotePropertyName __path -NotePropertyValue $ownershipAbsolute -Force
Test-MorphospaceClaimBaseline -Baseline $baseline -Unit $unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $map.map | Out-Null
$observation = Test-MorphospaceUnitOwnership -Ownership $ownership -ClaimBaseline $baseline -ClaimBaselineReference $protocol.claim_baseline -Unit $unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $map.map
$actionAbsolute = Resolve-MorphospaceAuthorityPath $workspace $ValidationActionPath
$actionDocument = Read-MorphospaceAuthorityJson $actionAbsolute; $actionDocument | Add-Member -NotePropertyName __path -NotePropertyValue $actionAbsolute -Force
if ([string]$actionDocument.pre_observation_sha256 -ne [string]$observation.observation.sha256) { throw 'Validation action is not bound to the current ownership observation.' }
$selection = Get-MorphospaceRegistrySelection -Registry $registry -Unit $unit -RepositoryMap $map.map -AssertedProfileId ([string]$actionDocument.profile_id)
Assert-MorphospaceAuthorizedAction -ActionDocument $actionDocument -Selection $selection -Unit $unit
if ($Action -eq 'Inspect') { [pscustomobject][ordered]@{ action = 'Inspect'; project_id = $unit.project_id; unit_id = $UnitId; validators = @($selection.validators | ForEach-Object { $_.validator_id }); observation_sha256 = $observation.observation.sha256; trust_migration = $migration.migration_id } | ConvertTo-Json -Depth 20; exit 0 }
if (-not $EvidencePath -or -not $OutPath) { throw 'Validate requires EvidencePath and OutPath.' }
$evidenceAbsolute = Resolve-MorphospaceAuthorityPath $workspace $EvidencePath
$receiptAbsolute = Resolve-MorphospaceAuthorityPath $workspace $OutPath
if (Test-Path -LiteralPath $evidenceAbsolute -or Test-Path -LiteralPath $receiptAbsolute) { throw 'Validation authority refuses to overwrite an existing evidence or receipt artifact.' }
$evidenceDirectory = Split-Path -Parent $evidenceAbsolute
if (-not (Test-Path -LiteralPath $evidenceDirectory -PathType Container)) { throw 'Validation evidence directory does not exist.' }
$evidenceStem = [IO.Path]::GetFileNameWithoutExtension($evidenceAbsolute)
$validatorResults = [Collections.Generic.List[object]]::new()
foreach ($validator in @($selection.validators)) {
    if ([string]$UnitId -ne 'wf-005') { throw 'The current authority runner supports only the WF-005 owner-validator contract.' }
    $cleanRoom = $null
    try {
        $cleanRoom = New-MorphospaceCleanRoom -Ownership $ownership -ClaimBaseline $baseline -RepositoryMap $map.map -InputClosure @($validator.input_closure) -AttemptId "$UnitId-$($actionDocument.attempt_id)-$([string]$validator.validator_id)"
        $cleanBefore = Get-MorphospaceCleanRoomFingerprint $cleanRoom
        if ($cleanBefore -ne [string]$cleanRoom.fingerprint_sha256) { throw 'New clean room does not match its reported fingerprint.' }
        $validatorPath = [IO.Path]::GetFullPath((Join-Path ([string]$cleanRoom.repositories[[string]$validator.owner_repo_id]) ([string]$validator.path)))
        if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf) -or (Get-MorphospaceAuthoritySha256 $validatorPath) -ne [string]$validator.sha256) { throw "Clean-room validator bytes do not match the registry: $($validator.validator_id)" }
        $ownerOut = Join-Path $evidenceDirectory "$evidenceStem.$([string]$validator.validator_id).owner.json"
        $stdoutPath = Join-Path $evidenceDirectory "$evidenceStem.$([string]$validator.validator_id).stdout.txt"
        $stderrPath = Join-Path $evidenceDirectory "$evidenceStem.$([string]$validator.validator_id).stderr.txt"
        $planningRoot = [string]$cleanRoom.repositories['planning']
        $questRoot = [string]$cleanRoom.repositories['quest']
        $cleanWorkspace = Join-Path $planningRoot 'workspaces\morphospace-platform-iteration\morphospace'
        $cleanRoadmap = Join-Path $planningRoot 'agent-state\morphospace-autonomous-iteration-roadmap-2026-07-10.json'
        $run = Invoke-MorphospacePinnedValidator -ValidatorPath $validatorPath -Workspace $cleanWorkspace -Quest $questRoot -Roadmap $cleanRoadmap -Unit $UnitId -OwnerOut $ownerOut -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds ([int]$validator.timeout_seconds)
        if (([Text.Encoding]::UTF8.GetByteCount([string]$run.stdout) + [Text.Encoding]::UTF8.GetByteCount([string]$run.stderr)) -gt [int]$validator.max_output_bytes) { throw "Validator output exceeded its registered limit: $($validator.validator_id)" }
        $cleanAfter = Get-MorphospaceCleanRoomFingerprint $cleanRoom
        if ($cleanAfter -ne $cleanBefore) { throw "Validator modified its clean-room input closure: $($validator.validator_id)" }
        if ((Get-MorphospaceAuthoritySha256 $validatorPath) -ne [string]$validator.sha256) { throw "Validator bytes changed during execution: $($validator.validator_id)" }
        if (-not (Test-Path -LiteralPath $ownerOut -PathType Leaf)) { throw "Selected validator did not emit its owner evidence: $($validator.validator_id)" }
        $owner = Read-MorphospaceAuthorityJson $ownerOut
        $ownerStatus = if ($run.exit_code -eq 0 -and [string]$owner.status -eq 'pass') { 'pass' } elseif ($run.exit_code -eq 0) { 'fail' } else { 'fail' }
        $validatorResults.Add([pscustomobject][ordered]@{
            validator_id = [string]$validator.validator_id; owner_repo_id = [string]$validator.owner_repo_id; acceptance_ids = @($validator.acceptance_ids | Sort-Object); status = $ownerStatus; command_identity_sha256 = (Get-MorphospaceAuthoritySha256 $validatorPath); exit_code = [int]$run.exit_code; stdout_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ value = [string]$run.stdout })); stderr_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ value = [string]$run.stderr })); owner_evidence = Get-MorphospaceAuthorityReference $workspace $ownerOut 'owner-validation' ([string]$validator.evidence_schema); cleanroom_fingerprint_sha256 = $cleanBefore; input_closure_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ closure = @($validator.input_closure) }))
        }) | Out-Null
    } finally { if ($null -ne $cleanRoom) { Remove-MorphospaceCleanRoom $cleanRoom } }
}
$evidenceResult = if (@($validatorResults | Where-Object { [string]$_.status -ne 'pass' }).Count -eq 0) { 'pass' } else { 'fail' }
$evidenceDocument = [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.validation_evidence.v2'; evidence_id = "$UnitId-$($actionDocument.attempt_id)-evidence"; created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); project_id = [string]$unit.project_id; unit_id = $UnitId; attempt_id = [string]$actionDocument.attempt_id; action = Get-MorphospaceAuthorityReference $workspace ([string]$actionDocument.__path) 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'; profile_id = [string]$actionDocument.profile_id; result = $evidenceResult; validator_results = @($validatorResults.ToArray()); device_validation = $null; does_not_prove = @('Does not prove device validation, stable promotion, external Git push, or any downstream NET-013/MOD-006 acceptance.') }
[IO.File]::WriteAllText($evidenceAbsolute, ($evidenceDocument | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
$evidence = Test-MorphospaceValidationEvidenceV2 -WorkspaceRoot $workspace -EvidencePath $EvidencePath -Unit $unit -SelectedValidators @($selection.validators) -Action $actionDocument; $evidence | Add-Member -NotePropertyName __path -NotePropertyValue $evidenceAbsolute -Force
$receipt = New-MorphospaceValidationReceiptV2 -WorkspaceRoot $workspace -Unit $unit -Action $actionDocument -Evidence $evidence -Protocol $protocol -Ownership $ownership -Registry $registry -Observation $observation.observation
[IO.File]::WriteAllText($receiptAbsolute, ($receipt | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 30
