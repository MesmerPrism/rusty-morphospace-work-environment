Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Microsoft.PowerShell.Core\Import-Module ([IO.Path]::Combine($PSScriptRoot, 'MorphospaceProtocolCommon.psm1')) -Force
Microsoft.PowerShell.Core\Import-Module ([IO.Path]::Combine($PSScriptRoot, 'MorphospaceOwnership.psm1')) -Force

function Read-MorphospaceAuthorityJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { throw "Authority artifact does not exist: $Path" }
    return Read-MorphospaceProtocolJson -Path $Path
}

function Get-MorphospaceAuthoritySha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { throw "Authority artifact does not exist: $Path" }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { return ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream))).Replace('-', '').ToLowerInvariant() } finally { $stream.Dispose() }
}

function Resolve-MorphospaceAuthorityPath {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][string]$Reference)
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $candidate = if ([IO.Path]::IsPathRooted($Reference)) { [IO.Path]::GetFullPath($Reference) } else { [IO.Path]::GetFullPath((Join-Path $workspace $Reference)) }
    if (-not ($candidate -eq $workspace -or $candidate.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Authority artifact escapes workspace: $Reference"
    }
    return $candidate
}

function Get-MorphospaceAuthorityReference {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Role, [Parameter(Mandatory = $true)][string]$Schema)
    $absolute = Resolve-MorphospaceAuthorityPath $WorkspaceRoot $Path
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return [pscustomobject][ordered]@{ role = $Role; path = $absolute.Substring($workspace.Length).Replace('\', '/'); schema = $Schema; sha256 = Get-MorphospaceAuthoritySha256 $absolute }
}

function Assert-MorphospaceAuthorityReference {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][object]$Reference, [Parameter(Mandatory = $true)][string]$Role, [Parameter(Mandatory = $true)][string]$Schema)
    if ([string]$Reference.role -ne $Role -or [string]$Reference.schema -ne $Schema) { throw "Authority reference has the wrong role/schema for $Role." }
    $path = Resolve-MorphospaceAuthorityPath $WorkspaceRoot ([string]$Reference.path)
    if ((Get-MorphospaceAuthoritySha256 $path) -ne [string]$Reference.sha256) { throw "Authority reference hash drifted: $($Reference.path)" }
    return $path
}

function Test-MorphospaceValidatorTrustAnchorMigration {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$MigrationPath,
        [Parameter(Mandatory = $true)][object]$RegistryReference,
        [Parameter(Mandatory = $true)][string]$ExpectedProjectId,
        [Parameter(Mandatory = $true)][string]$ExpectedUnitId
    )
    $migration = Read-MorphospaceAuthorityJson (Resolve-MorphospaceAuthorityPath $WorkspaceRoot $MigrationPath)
    if ([string]$migration.schema -ne 'rusty.morphospace.workflow.validator_trust_anchor_migration.v1' -or [string]$migration.project_id -ne $ExpectedProjectId -or [string]$migration.unit_id -ne $ExpectedUnitId -or [string]$migration.status -ne 'accepted') { throw 'Trust migration identity/status is invalid.' }
    if (-not [bool]$migration.bootstrap_exception.one_time -or -not [bool]$migration.bootstrap_exception.non_promotional -or [string]$migration.bootstrap_exception.self_authorization_scope -ne 'authority-adoption-only' -or -not [bool]$migration.bootstrap_exception.normal_ownership_after_commit) { throw 'Trust migration bootstrap exception is broadened.' }
    $roles = @($migration.lineage | ForEach-Object { [string]$_.role })
    if (($roles -join '|') -ne 'legacy-bootstrap|protocol-v2|foundation|authority') { throw 'Trust migration lineage is incomplete or reordered.' }
    $registryPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $migration.registry 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'
    $expectedRegistryPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $RegistryReference 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'
    if (-not $registryPath.Equals($expectedRegistryPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Trust migration uses a different registry than the current protocol.' }
    [void](Assert-MorphospaceAuthorityReference $WorkspaceRoot $migration.prior_event_anchor 'legacy-prefix-anchor' 'rusty.morphospace.workflow.legacy_event_prefix_anchor.v1')
    if (@($migration.authority_artifacts).Count -eq 0) { throw 'Trust migration does not bind authority artifacts.' }
    return $migration
}

function Test-MorphospaceValidationEvidenceV2 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$EvidencePath,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object[]]$SelectedValidators,
        [Parameter(Mandatory = $true)][object]$Action
    )
    $evidence = Read-MorphospaceAuthorityJson (Resolve-MorphospaceAuthorityPath $WorkspaceRoot $EvidencePath)
    if ([string]$evidence.schema -ne 'rusty.morphospace.workflow.validation_evidence.v2' -or [string]$evidence.project_id -ne [string]$Unit.project_id -or [string]$evidence.unit_id -ne [string]$Unit.unit_id -or [string]$evidence.result -notin @('pass', 'fail', 'blocked')) { throw 'Validation evidence identity/result is invalid.' }
    [void](Assert-MorphospaceAuthorityReference $WorkspaceRoot $evidence.action 'validation-action' 'rusty.morphospace.workflow.validation_action.v2')
    if ([string]$evidence.attempt_id -ne [string]$Action.attempt_id -or [string]$evidence.profile_id -ne [string]$Action.profile_id) { throw 'Validation evidence is not bound to the authorized action.' }
    if ([string]$Unit.device_requirement -eq 'none' -and $null -ne $evidence.device_validation) { throw 'A no-device unit cannot manufacture device validation.' }
    $selected = @{}; foreach ($item in $SelectedValidators) { $selected[[string]$item.validator_id] = $item }
    $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($result in @($evidence.validator_results)) {
        $id = [string]$result.validator_id
        if (-not $selected.ContainsKey($id)) { throw "Validation evidence names an unselected validator: $id" }
        if ([string]$result.status -notin @('pass', 'fail', 'blocked') -or [int]$result.exit_code -lt 0) { throw "Validator result is malformed: $id" }
        $validator = $selected[$id]
        if ([string]$result.owner_repo_id -ne [string]$validator.owner_repo_id -or [string]$result.command_identity_sha256 -ne [string]$validator.sha256) { throw "Validator identity is not bound to the selected registry entry: $id" }
        if ([string]$result.cleanroom_fingerprint_sha256 -notmatch '^[0-9a-f]{64}$' -or [string]$result.input_closure_sha256 -ne (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ closure = @($validator.input_closure) }))) { throw "Validator clean-room closure is not bound to the selected registry entry: $id" }
        foreach ($acceptance in @($result.acceptance_ids)) { if (-not $covered.Add([string]$acceptance)) { throw "Acceptance is claimed twice: $acceptance" } }
        $ownerPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $result.owner_evidence 'owner-validation' 'rusty.morphospace.workflow.owner_validation.v1'
        $owner = Read-MorphospaceAuthorityJson $ownerPath
        Test-MorphospaceOwnerValidation -OwnerEvidence $owner -Validator $validator -Unit $Unit -ExpectedStatus ([string]$result.status) | Out-Null
    }
    $expected = @($Unit.acceptance | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
    if (($covered.ToArray() | Sort-Object) -join '|' -ne $expected -join '|') { throw 'Validation evidence does not cover the exact acceptance set.' }
    if ([string]$evidence.result -eq 'pass' -and (@($evidence.validator_results | Where-Object { [string]$_.status -ne 'pass' }).Count -ne 0)) { throw 'Passing evidence has a non-passing validator.' }
    return $evidence
}

function New-MorphospaceValidationExecutionV1 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object]$Action,
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][object]$Observation,
        [Parameter(Mandatory = $true)][string]$ExpectedReceiptPath,
        [Parameter(Mandatory = $true)][string]$ExecutorPath
    )
    $receiptOutputs = @($Action.expected_outputs | Where-Object { [string]$_.role -eq 'validation-receipt' })
    if ($receiptOutputs.Count -ne 1 -or [string]$receiptOutputs[0].path -ne $ExpectedReceiptPath) { throw 'Validation execution receipt target is not the exact authorized output.' }
    return [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.validation_execution.v1'
        execution_id = "$($Unit.unit_id)-$($Action.attempt_id)-execution"
        completed_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        project_id = [string]$Unit.project_id
        unit_id = [string]$Unit.unit_id
        attempt_id = [string]$Action.attempt_id
        action = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Action.__path) 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'
        evidence = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Evidence.__path) 'validation-evidence' 'rusty.morphospace.workflow.validation_evidence.v2'
        expected_receipt = [pscustomobject][ordered]@{ role = 'validation-receipt'; path = $ExpectedReceiptPath; schema = 'rusty.morphospace.workflow.validation_receipt.v2' }
        output_contract_sha256 = Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ outputs = @($Action.expected_outputs | Sort-Object repo_id,path) })
        observations = [pscustomobject][ordered]@{ before_sha256 = [string]$Action.pre_observation_sha256; after_sha256 = [string]$Observation.sha256 }
        executor = [pscustomobject][ordered]@{ command = 'Invoke-MorphospaceValidationAuthority.ps1'; command_sha256 = Get-MorphospaceAuthoritySha256 $ExecutorPath }
        status = 'completed'
    }
}

function Test-MorphospaceValidationExecutionV1 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$ExecutionReference,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object]$Action,
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][object[]]$AutomationOutputs,
        [Parameter(Mandatory = $true)][string]$ReceiptReference,
        [Parameter(Mandatory = $true)][object]$Receipt
    )
    $executionPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $ExecutionReference 'validation-execution' 'rusty.morphospace.workflow.validation_execution.v1'
    $execution = Read-MorphospaceAuthorityJson $executionPath
    Assert-MorphospaceExactPropertySet $execution @('schema','execution_id','completed_at','project_id','unit_id','attempt_id','action','evidence','expected_receipt','output_contract_sha256','observations','executor','status') @() 'validation execution'
    if ([string]$execution.schema -ne 'rusty.morphospace.workflow.validation_execution.v1' -or [string]$execution.project_id -ne [string]$Unit.project_id -or [string]$execution.unit_id -ne [string]$Unit.unit_id -or [string]$execution.attempt_id -ne [string]$Action.attempt_id -or [string]$execution.execution_id -ne "$($Unit.unit_id)-$($Action.attempt_id)-execution" -or [string]$execution.status -ne 'completed') { throw 'Validation execution identity/status is invalid.' }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$execution.completed_at))
    $actionPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $execution.action 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'
    $evidencePath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $execution.evidence 'validation-evidence' 'rusty.morphospace.workflow.validation_evidence.v2'
    if (-not $actionPath.Equals([string]$Action.__path, [StringComparison]::OrdinalIgnoreCase) -or -not $evidencePath.Equals([string]$Evidence.__path, [StringComparison]::OrdinalIgnoreCase)) { throw 'Validation execution is not bound to the receipt action/evidence.' }
    $receiptOutputs = @($AutomationOutputs | Where-Object { [string]$_.role -eq 'validation-receipt' })
    $executionOutputs = @($AutomationOutputs | Where-Object { [string]$_.role -eq 'validation-execution' })
    if ($receiptOutputs.Count -ne 1 -or $executionOutputs.Count -ne 1) { throw 'Validation execution requires one exact receipt and execution output.' }
    if ([string]$execution.expected_receipt.role -ne 'validation-receipt' -or [string]$execution.expected_receipt.schema -ne 'rusty.morphospace.workflow.validation_receipt.v2' -or [string]$execution.expected_receipt.path -ne [string]$receiptOutputs[0].path -or [string]$ReceiptReference -ne [string]$receiptOutputs[0].path) { throw 'Validation execution receipt target drifted from the ownership contract.' }
    if ([string]$execution.output_contract_sha256 -ne (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ outputs = @($Action.expected_outputs | Sort-Object repo_id,path) }))) { throw 'Validation execution output contract drifted from the authorized action.' }
    if ([string]$execution.observations.before_sha256 -ne [string]$Action.pre_observation_sha256 -or [string]$execution.observations.after_sha256 -ne [string]$Receipt.observations.after_sha256) { throw 'Validation execution observation boundary drifted.' }
    if ([string]$execution.executor.command -ne 'Invoke-MorphospaceValidationAuthority.ps1' -or [string]$execution.executor.command_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Validation execution lacks an exact authority-runner identity.' }
    return $execution
}

function Test-MorphospaceOwnerValidation {
    param(
        [Parameter(Mandatory = $true)][object]$OwnerEvidence,
        [Parameter(Mandatory = $true)][object]$Validator,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][string]$ExpectedStatus
    )
    Assert-MorphospaceExactPropertySet $OwnerEvidence @('schema','validator_id','created_at','project_id','unit_id','acceptance_ids','status','criteria','does_not_prove') @() 'owner validation evidence'
    if ([string]$OwnerEvidence.schema -ne [string]$Validator.evidence_schema -or [string]$OwnerEvidence.validator_id -ne [string]$Validator.validator_id -or [string]$OwnerEvidence.project_id -ne [string]$Unit.project_id -or [string]$OwnerEvidence.unit_id -ne [string]$Unit.unit_id -or [string]$OwnerEvidence.status -ne $ExpectedStatus) { throw 'Owner validation identity/status is not bound to the selected validator.' }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$OwnerEvidence.created_at))
    $expected = @($Validator.acceptance_ids | ForEach-Object { [string]$_ } | Sort-Object)
    $actual = @($OwnerEvidence.acceptance_ids | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actual -join '|') -ne ($expected -join '|')) { throw 'Owner validation acceptance set is not bound to the registry.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($criterion in @($OwnerEvidence.criteria)) {
        Assert-MorphospaceExactPropertySet $criterion @('acceptance_id','status','command_id','command_path','command_sha256','output_sha256','exit_code') @() 'owner validation criterion'
        $criterionId = [string]$criterion.acceptance_id
        if (-not $seen.Add($criterionId) -or $criterionId -notin $expected -or [string]$criterion.status -notin @('pass','fail','blocked') -or [string]$criterion.command_id -notmatch '^[a-z0-9][a-z0-9-]{1,191}$' -or [string]$criterion.command_path -match '[\\/]' -or [string]$criterion.command_sha256 -notmatch '^[0-9a-f]{64}$' -or [string]$criterion.output_sha256 -notmatch '^[0-9a-f]{64}$' -or [int]$criterion.exit_code -lt 0) { throw "Owner validation criterion is malformed: $criterionId" }
        if ($ExpectedStatus -eq 'pass' -and ([string]$criterion.status -ne 'pass' -or [int]$criterion.exit_code -ne 0)) { throw "Passing owner validation has a non-passing criterion: $criterionId" }
    }
    $covered = @($seen.ToArray() | Sort-Object)
    if (($covered -join '|') -ne ($expected -join '|')) { throw 'Owner validation does not provide one typed criterion per selected acceptance.' }
    if (@($OwnerEvidence.does_not_prove | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -ne 0 -or @($OwnerEvidence.does_not_prove).Count -eq 0) { throw 'Owner validation limits are missing.' }
    return $OwnerEvidence
}

function New-MorphospaceValidationReceiptV2 {
    param([string]$WorkspaceRoot, [object]$Unit, [object]$Action, [object]$Evidence, [object]$Execution, [object]$Protocol, [object]$Ownership, [object]$Registry, [object]$Observation)
    $criteria = [Collections.Generic.List[object]]::new()
    foreach ($result in @($Evidence.validator_results)) {
        foreach ($acceptance in @($result.acceptance_ids)) { $criteria.Add([pscustomobject][ordered]@{ acceptance_id = [string]$acceptance; status = [string]$result.status; validator_id = [string]$result.validator_id; evidence_ref = $result.owner_evidence }) }
    }
    return [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.validation_receipt.v2'; receipt_id = "$($Unit.unit_id)-$($Action.attempt_id)-receipt"; created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); project_id = [string]$Unit.project_id; unit_id = [string]$Unit.unit_id; attempt_id = [string]$Action.attempt_id
        action = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Action.__path) 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'; evidence = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Evidence.__path) 'validation-evidence' 'rusty.morphospace.workflow.validation_evidence.v2'; execution = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Execution.__path) 'validation-execution' 'rusty.morphospace.workflow.validation_execution.v1'
        current_protocol = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Protocol.__path) 'current-unit-protocol' 'rusty.morphospace.workflow.current_unit_protocol.v1'; ownership = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Ownership.__path) 'unit-ownership' 'rusty.morphospace.workflow.unit_ownership.v1'; registry = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Registry.__path) 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'
        profile_id = [string]$Action.profile_id; result = [string]$Evidence.result; criteria = @($criteria.ToArray()); validators = @($Evidence.validator_results | ForEach-Object { [string]$_.validator_id } | Sort-Object -Unique); observations = [pscustomobject][ordered]@{ before_sha256 = [string]$Action.pre_observation_sha256; after_sha256 = [string]$Observation.sha256; allowed_delta_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ outputs = @($Action.expected_outputs | Sort-Object repo_id,path) })) }; device_validation = $Evidence.device_validation; status = 'accepted-evidence'
    }
}

function Test-MorphospaceValidationReceiptV2 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptReference,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap,
        [Parameter(Mandatory = $true)][string]$ExpectedResult
    )
    $receiptPath = Resolve-MorphospaceAuthorityPath $WorkspaceRoot $ReceiptReference
    $receipt = Read-MorphospaceAuthorityJson $receiptPath
    if ([string]$receipt.schema -ne 'rusty.morphospace.workflow.validation_receipt.v2' -or [string]$receipt.project_id -ne [string]$Unit.project_id -or [string]$receipt.unit_id -ne [string]$Unit.unit_id -or [string]$receipt.status -ne 'accepted-evidence') { throw 'Validation receipt v2 identity/status is invalid.' }
    if ([string]$receipt.result -ne $ExpectedResult) { throw 'Validation receipt v2 result does not match the requested transition.' }
    $protocolPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $receipt.current_protocol 'current-unit-protocol' 'rusty.morphospace.workflow.current_unit_protocol.v1'
    $protocol = Read-MorphospaceAuthorityJson $protocolPath; $protocol | Add-Member -NotePropertyName __path -NotePropertyValue $protocolPath -Force
    if ([string]$protocol.project_id -ne [string]$Unit.project_id -or [string]$protocol.unit_id -ne [string]$Unit.unit_id -or [string]$protocol.status -ne 'active') { throw 'Current protocol does not bind this active unit.' }
    $registryPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $receipt.registry 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'
    $registry = Read-MorphospaceAuthorityJson $registryPath
    Test-MorphospaceOwnerValidatorRegistry -Registry $registry -RepositoryMap $RepositoryMap | Out-Null
    Test-MorphospaceValidatorTrustAnchorMigration -WorkspaceRoot $WorkspaceRoot -MigrationPath ([string]$protocol.trust_anchor_migration.path) -RegistryReference $protocol.registry -ExpectedProjectId ([string]$Unit.project_id) -ExpectedUnitId ([string]$Unit.unit_id) | Out-Null
    $ownershipPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $receipt.ownership 'unit-ownership' 'rusty.morphospace.workflow.unit_ownership.v1'
    $ownership = Read-MorphospaceAuthorityJson $ownershipPath
    $baselinePath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $ownership.claim_baseline 'claim-baseline' 'rusty.morphospace.workflow.claim_baseline.v1'
    $baseline = Read-MorphospaceAuthorityJson $baselinePath
    Test-MorphospaceClaimBaseline -Baseline $baseline -Unit $Unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $RepositoryMap | Out-Null
    $current = Test-MorphospaceUnitOwnership -Ownership $ownership -ClaimBaseline $baseline -ClaimBaselineReference $protocol.claim_baseline -Unit $Unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $RepositoryMap
    $automationOutputs = @($current.automation_outputs)
    if ($automationOutputs.Count -eq 0) { throw 'Validation receipt v2 lacks an ownership-bound automation output contract.' }
    Test-MorphospaceAutomationOutputSet -AutomationOutputs $automationOutputs -RepositoryMap $RepositoryMap -Expected present
    $actionPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $receipt.action 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'
    $action = Read-MorphospaceAuthorityJson $actionPath; $action | Add-Member -NotePropertyName __path -NotePropertyValue $actionPath -Force
    if ([string]$action.pre_observation_sha256 -ne [string]$receipt.observations.before_sha256 -or [string]$current.observation.sha256 -ne [string]$receipt.observations.after_sha256) { throw 'Validation receipt v2 observation boundary drifted.' }
    $selection = Get-MorphospaceRegistrySelection -Registry $registry -Unit $Unit -RepositoryMap $RepositoryMap -AssertedProfileId ([string]$action.profile_id)
    $expectedOutputs = @($automationOutputs | Where-Object { [string]$_.phase -eq 'validation' } | Sort-Object repo_id,path)
    $actionOutputs = @($action.expected_outputs | Sort-Object repo_id,path)
    if ((Get-MorphospaceCanonicalJsonSha256 $actionOutputs) -ne (Get-MorphospaceCanonicalJsonSha256 $expectedOutputs) -or [string]$receipt.observations.allowed_delta_sha256 -ne (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ outputs = $expectedOutputs }))) { throw 'Validation receipt v2 automation output delta is not bound to the ownership contract.' }
    $receiptOutput = @($expectedOutputs | Where-Object { [string]$_.role -eq 'validation-receipt' })
    if ($receiptOutput.Count -ne 1) { throw 'Validation receipt v2 has no exact receipt output contract.' }
    $expectedReceiptPath = [IO.Path]::GetFullPath((Join-Path ([string]$RepositoryMap[[string]$receiptOutput[0].repo_id].path) ([string]$receiptOutput[0].path)))
    if (-not $receiptPath.Equals($expectedReceiptPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Validation receipt v2 was not written to its exact ownership-bound automation path.' }
    $evidencePath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $receipt.evidence 'validation-evidence' 'rusty.morphospace.workflow.validation_evidence.v2'
    $evidence = Test-MorphospaceValidationEvidenceV2 -WorkspaceRoot $WorkspaceRoot -EvidencePath $evidencePath -Unit $Unit -SelectedValidators @($selection.validators) -Action $action
    $evidence | Add-Member -NotePropertyName __path -NotePropertyValue $evidencePath -Force
    [void](Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $WorkspaceRoot -ExecutionReference $receipt.execution -Unit $Unit -Action $action -Evidence $evidence -AutomationOutputs $automationOutputs -ReceiptReference $ReceiptReference -Receipt $receipt)
    $expectedCriteria = @($Unit.acceptance | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
    $actualCriteria = @($receipt.criteria | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
    if (($expectedCriteria -join '|') -ne ($actualCriteria -join '|')) { throw 'Validation receipt v2 does not cover the exact acceptance set.' }
    if ($ExpectedResult -eq 'pass' -and @($receipt.criteria | Where-Object { [string]$_.status -ne 'pass' }).Count -ne 0) { throw 'Passing validation receipt v2 has a non-passing criterion.' }
    return $receipt
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Read-MorphospaceAuthorityJson, Get-MorphospaceAuthoritySha256, Resolve-MorphospaceAuthorityPath, Get-MorphospaceAuthorityReference, Assert-MorphospaceAuthorityReference, Test-MorphospaceValidatorTrustAnchorMigration, Test-MorphospaceOwnerValidation, Test-MorphospaceValidationEvidenceV2, New-MorphospaceValidationExecutionV1, Test-MorphospaceValidationExecutionV1, New-MorphospaceValidationReceiptV2, Test-MorphospaceValidationReceiptV2
