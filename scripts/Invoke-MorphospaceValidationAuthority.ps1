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

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$spec = Read-MorphospaceJson -Path (Join-Path $workspace 'project.spec.json')
$unitPath = Join-Path $workspace (Join-Path 'iteration-units' "$UnitId.json")
$unit = Read-MorphospaceJson -Path $unitPath
if ([string]$unit.unit_id -ne $UnitId -or [string]$unit.project_id -ne [string]$spec.project_id) { throw 'Unit identity does not match the workspace.' }
$map = Get-MorphospaceFixedRepositoryMap -WorkspaceRoot $workspace -RequiredRepositoryIds @($unit.allowed_repositories | ForEach-Object { [string]$_.repo_id })
$registry = Read-MorphospaceAuthorityJson $RegistryPath; $registry | Add-Member -NotePropertyName __path -NotePropertyValue $RegistryPath -Force
Test-MorphospaceOwnerValidatorRegistry -Registry $registry -RepositoryMap $map | Out-Null
$protocol = Read-MorphospaceAuthorityJson (Resolve-MorphospaceAuthorityPath $workspace $CurrentProtocolPath); $protocol | Add-Member -NotePropertyName __path -NotePropertyValue (Resolve-MorphospaceAuthorityPath $workspace $CurrentProtocolPath) -Force
if ([string]$protocol.project_id -ne [string]$unit.project_id -or [string]$protocol.unit_id -ne $UnitId -or [string]$protocol.status -ne 'active') { throw 'Current protocol does not bind the active unit.' }
$migration = Test-MorphospaceValidatorTrustAnchorMigration -WorkspaceRoot $workspace -MigrationPath $TrustMigrationPath -RegistryReference $protocol.registry -ExpectedProjectId ([string]$unit.project_id) -ExpectedUnitId $UnitId
$baseline = Read-MorphospaceAuthorityJson (Resolve-MorphospaceAuthorityPath $workspace $ClaimBaselinePath)
$ownership = Read-MorphospaceAuthorityJson (Resolve-MorphospaceAuthorityPath $workspace $OwnershipPath); $ownership | Add-Member -NotePropertyName __path -NotePropertyValue (Resolve-MorphospaceAuthorityPath $workspace $OwnershipPath) -Force
Test-MorphospaceClaimBaseline -Baseline $baseline -Unit $unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $map | Out-Null
$observation = Test-MorphospaceUnitOwnership -Ownership $ownership -ClaimBaseline $baseline -ClaimBaselineReference $protocol.claim_baseline -Unit $unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $map
$action = Read-MorphospaceAuthorityJson (Resolve-MorphospaceAuthorityPath $workspace $ValidationActionPath); $action | Add-Member -NotePropertyName __path -NotePropertyValue (Resolve-MorphospaceAuthorityPath $workspace $ValidationActionPath) -Force
if ([string]$action.project_id -ne [string]$unit.project_id -or [string]$action.unit_id -ne $UnitId -or [string]$action.status -ne 'authorized' -or [string]$action.pre_observation_sha256 -ne [string]$observation.observation.sha256) { throw 'Validation action is not bound to the current protocol/observation.' }
$selection = Get-MorphospaceRegistrySelection -Registry $registry -Unit $unit -RepositoryMap $map -AssertedProfileId ([string]$action.profile_id)
if ($Action -eq 'Inspect') { [pscustomobject][ordered]@{ action = 'Inspect'; project_id = $unit.project_id; unit_id = $UnitId; validators = @($selection.validators | ForEach-Object { $_.validator_id }); observation_sha256 = $observation.observation.sha256; trust_migration = $migration.migration_id } | ConvertTo-Json -Depth 20; exit 0 }
if (-not $EvidencePath -or -not $OutPath) { throw 'Validate requires EvidencePath and OutPath.' }
$evidenceAbsolute = Resolve-MorphospaceAuthorityPath $workspace $EvidencePath
$receiptAbsolute = Resolve-MorphospaceAuthorityPath $workspace $OutPath
if (Test-Path -LiteralPath $evidenceAbsolute -or Test-Path -LiteralPath $receiptAbsolute) { throw 'Validation authority refuses to overwrite an existing evidence or receipt artifact.' }
$evidenceDirectory = Split-Path -Parent $evidenceAbsolute
$evidenceStem = [IO.Path]::GetFileNameWithoutExtension($evidenceAbsolute)
$validatorResults = [Collections.Generic.List[object]]::new()
foreach ($validator in @($selection.validators)) {
    $ownerRoot = [IO.Path]::GetFullPath([string]$map[[string]$validator.owner_repo_id].path)
    $validatorPath = [IO.Path]::GetFullPath((Join-Path $ownerRoot ([string]$validator.path)))
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) { throw "Selected validator is missing: $($validator.validator_id)" }
    $ownerOut = Join-Path $evidenceDirectory "$evidenceStem.$([string]$validator.validator_id).owner.json"
    $stderrPath = Join-Path $evidenceDirectory "$evidenceStem.$([string]$validator.validator_id).stderr.txt"
    if (Test-Path -LiteralPath $ownerOut -or Test-Path -LiteralPath $stderrPath) { throw "Validation authority refuses to overwrite validator output: $($validator.validator_id)" }
    $stdout = & powershell -NoProfile -ExecutionPolicy Bypass -File $validatorPath -WorkspaceRoot $workspace -UnitId $UnitId -OutPath $ownerOut 2> $stderrPath
    $exitCode = $LASTEXITCODE
    $stdoutText = (@($stdout) -join [Environment]::NewLine)
    $stderrText = if (Test-Path -LiteralPath $stderrPath) { [IO.File]::ReadAllText($stderrPath, [Text.UTF8Encoding]::new($false)) } else { '' }
    if (([Text.Encoding]::UTF8.GetByteCount($stdoutText) + [Text.Encoding]::UTF8.GetByteCount($stderrText)) -gt [int]$validator.max_output_bytes) { throw "Validator output exceeded its registered limit: $($validator.validator_id)" }
    if (-not (Test-Path -LiteralPath $ownerOut -PathType Leaf)) { throw "Selected validator did not emit its owner evidence: $($validator.validator_id)" }
    $owner = Read-MorphospaceAuthorityJson $ownerOut
    $ownerStatus = if ($exitCode -eq 0 -and [string]$owner.status -eq 'pass') { 'pass' } elseif ($exitCode -eq 0) { 'fail' } else { 'fail' }
    $cleanRoom = $null
    try {
        $cleanRoom = New-MorphospaceCleanRoom -Ownership $ownership -ClaimBaseline $baseline -RepositoryMap $map -InputClosure @($validator.input_closure) -AttemptId "$UnitId-$($action.attempt_id)-$([string]$validator.validator_id)"
        $cleanFingerprint = [string]$cleanRoom.fingerprint_sha256
    } finally { if ($null -ne $cleanRoom) { Remove-MorphospaceCleanRoom $cleanRoom } }
    $validatorResults.Add([pscustomobject][ordered]@{
        validator_id = [string]$validator.validator_id; owner_repo_id = [string]$validator.owner_repo_id; acceptance_ids = @($validator.acceptance_ids | Sort-Object); status = $ownerStatus; command_identity_sha256 = (Get-MorphospaceAuthoritySha256 $validatorPath); exit_code = [int]$exitCode; stdout_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ value = $stdoutText })); stderr_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ value = $stderrText })); owner_evidence = Get-MorphospaceAuthorityReference $workspace $ownerOut 'owner-validation' 'rusty.morphospace.workflow.owner_validation.v1'; cleanroom_fingerprint_sha256 = $cleanFingerprint; input_closure_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ closure = @($validator.input_closure) }))
    }) | Out-Null
}
$evidenceResult = if (@($validatorResults | Where-Object { [string]$_.status -ne 'pass' }).Count -eq 0) { 'pass' } else { 'fail' }
$evidenceDocument = [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.validation_evidence.v2'; evidence_id = "$UnitId-$($action.attempt_id)-evidence"; created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); project_id = [string]$unit.project_id; unit_id = $UnitId; attempt_id = [string]$action.attempt_id; action = Get-MorphospaceAuthorityReference $workspace ([string]$action.__path) 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'; profile_id = [string]$action.profile_id; result = $evidenceResult; validator_results = @($validatorResults.ToArray()); device_validation = $null; does_not_prove = @('Does not prove device validation, stable promotion, external Git push, or any downstream NET-013/MOD-006 acceptance.') }
[IO.File]::WriteAllText($evidenceAbsolute, ($evidenceDocument | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
$evidence = Test-MorphospaceValidationEvidenceV2 -WorkspaceRoot $workspace -EvidencePath $EvidencePath -Unit $unit -SelectedValidators @($selection.validators) -Action $action; $evidence | Add-Member -NotePropertyName __path -NotePropertyValue $evidenceAbsolute -Force
$registry | Add-Member -NotePropertyName __path -NotePropertyValue $RegistryPath -Force
$receipt = New-MorphospaceValidationReceiptV2 -WorkspaceRoot $workspace -Unit $unit -Action $action -Evidence $evidence -Protocol $protocol -Ownership $ownership -Registry $registry -Observation $observation.observation
[IO.File]::WriteAllText($receiptAbsolute, ($receipt | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 30
