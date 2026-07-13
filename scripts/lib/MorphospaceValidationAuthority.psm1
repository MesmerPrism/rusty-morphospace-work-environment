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
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [switch]$ProbeOnly
    )
    if ((Test-Path -LiteralPath $OwnerOut) -or (Test-Path -LiteralPath $StdoutPath) -or (Test-Path -LiteralPath $StderrPath)) { throw 'Pinned validator output paths must be absent before launch.' }
    $host = (Get-Command powershell.exe -ErrorAction Stop).Source
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ValidatorPath, '-WorkspaceRoot', $Workspace, '-QuestRoot', $Quest, '-RoadmapPath', $Roadmap, '-UnitId', $Unit, '-OutPath', $OwnerOut)
    if ($ProbeOnly) { $arguments += '-ProbeOnly' }
    $process = Start-Process -FilePath $host -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "Pinned validator exceeded its registry timeout of $TimeoutSeconds seconds."
        }
        $stdout = if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) { [IO.File]::ReadAllText($StdoutPath, [Text.UTF8Encoding]::new($false)) } else { '' }
        $stderr = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) { [IO.File]::ReadAllText($StderrPath, [Text.UTF8Encoding]::new($false)) } else { '' }
        return [pscustomobject][ordered]@{ exit_code = [int]$process.ExitCode; stdout = $stdout; stderr = $stderr }
    } finally { $process.Dispose() }
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

function Get-MorphospaceBoundAuthorityReference {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Schema
    )
    if ($Document.PSObject.Properties.Name -contains '__path') { throw "Authority document '$Role' contains internal path metadata." }
    if ([string]$Document.schema -cne $Schema) { throw "Authority document '$Role' has the wrong schema." }
    $absolute = Resolve-MorphospaceAuthorityPath $WorkspaceRoot $Path
    $stored = Read-MorphospaceAuthorityJson $absolute
    if ([string]$stored.schema -cne $Schema -or (Get-MorphospaceCanonicalJsonSha256 $stored) -cne (Get-MorphospaceCanonicalJsonSha256 $Document)) {
        throw "Authority document '$Role' does not match its bound path."
    }
    return Get-MorphospaceAuthorityReference -WorkspaceRoot $WorkspaceRoot -Path $absolute -Role $Role -Schema $Schema
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
        [Parameter(Mandatory = $true)][string]$ExpectedUnitId,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap
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
    $artifacts = @($migration.authority_artifacts)
    if ($artifacts.Count -eq 0) { throw 'Trust migration does not bind authority artifacts.' }
    $seenArtifacts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($artifact in $artifacts) {
        Assert-MorphospaceExactPropertySet $artifact @('repo_id','path','sha256','git_blob_oid') @() 'trust migration authority artifact'
        $repoId = [string]$artifact.repo_id
        $relative = ConvertTo-MorphospaceProtocolRelativePath ([string]$artifact.path)
        $key = "$repoId/$relative"
        if (-not $RepositoryMap.ContainsKey($repoId) -or -not $seenArtifacts.Add($key) -or [string]$artifact.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "Trust migration authority artifact is malformed: $key"
        }
        if ([string]$artifact.git_blob_oid -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw "Trust migration authority artifact '$key' blob is invalid." }
        $absolute = [IO.Path]::GetFullPath((Join-Path ([string]$RepositoryMap[$repoId].path) $relative))
        Assert-MorphospaceNoReparseAncestor ([string]$RepositoryMap[$repoId].path) $absolute
        if (-not [IO.File]::Exists($absolute) -or (Get-MorphospaceAuthoritySha256 $absolute) -cne [string]$artifact.sha256) {
            throw "Trust migration authority artifact drifted: $key"
        }
        $blob = @(& git -C ([string]$RepositoryMap[$repoId].path) rev-parse "HEAD:$relative" 2>&1)
        if ($LASTEXITCODE -ne 0 -or ([string]($blob -join '').Trim().ToLowerInvariant()) -cne [string]$artifact.git_blob_oid) {
            throw "Trust migration authority artifact is not the current tracked blob: $key"
        }
    }
    foreach ($required in @(
        'scripts/Invoke-MorphospaceValidationAuthority.ps1',
        'scripts/Invoke-WorkUnitAutomation.ps1',
        'scripts/Invoke-Wf005OwnerValidator.ps1',
        'scripts/Test-ValidationAuthorityLauncher.ps1',
        'scripts/Test-AuthorityRunnerHandoff.ps1',
        'scripts/Test-AuthorityRecordReadiness.ps1',
        'scripts/Test-TrustMigrationAuthority.ps1',
        'scripts/Test-ValidationExecutionAuthority.ps1',
        'scripts/Test-TransitionLedger.ps1',
        'scripts/WorkUnitAutomation.psm1',
        'scripts/lib/MorphospaceAuthorityReadiness.psm1',
        'scripts/lib/MorphospaceContentObservation.psm1',
        'scripts/lib/MorphospaceOwnership.psm1',
        'scripts/lib/MorphospaceProtocolCommon.psm1',
        'scripts/lib/MorphospaceTransitionLedger.psm1',
        'scripts/lib/MorphospaceValidationAuthority.psm1'
    )) {
        if (-not $seenArtifacts.Contains("work-environment/$required")) { throw "Trust migration omits required authority artifact: $required" }
    }
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
    if (((@($covered) | Sort-Object) -join '|') -ne ($expected -join '|')) { throw 'Validation evidence does not cover the exact acceptance set.' }
    if ([string]$evidence.result -eq 'pass' -and (@($evidence.validator_results | Where-Object { [string]$_.status -ne 'pass' }).Count -ne 0)) { throw 'Passing evidence has a non-passing validator.' }
    return $evidence
}

function New-MorphospaceValidationExecutionV1 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object]$Action,
        [Parameter(Mandatory = $true)][string]$ActionPath,
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$EvidencePath,
        [Parameter(Mandatory = $true)][object]$Observation,
        [Parameter(Mandatory = $true)][string]$ExpectedReceiptPath,
        [Parameter(Mandatory = $true)][string]$ExecutorPath,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExecutionNonce
    )
    $receiptOutputs = @($Action.expected_outputs | Where-Object { [string]$_.role -eq 'validation-receipt' })
    if ($receiptOutputs.Count -ne 1 -or [string]$receiptOutputs[0].path -ne $ExpectedReceiptPath) { throw 'Validation execution receipt target is not the exact authorized output.' }
    return [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.validation_execution.v1'
        execution_id = "$($Unit.unit_id)-$($Action.attempt_id)-execution"
        completed_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        execution_nonce = $ExecutionNonce
        project_id = [string]$Unit.project_id
        unit_id = [string]$Unit.unit_id
        attempt_id = [string]$Action.attempt_id
        action = Get-MorphospaceBoundAuthorityReference $WorkspaceRoot $Action $ActionPath 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'
        evidence = Get-MorphospaceBoundAuthorityReference $WorkspaceRoot $Evidence $EvidencePath 'validation-evidence' 'rusty.morphospace.workflow.validation_evidence.v2'
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
        [Parameter(Mandatory = $true)][string]$ActionPath,
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$EvidencePath,
        [Parameter(Mandatory = $true)][object[]]$AutomationOutputs,
        [Parameter(Mandatory = $true)][string]$ReceiptReference,
        [Parameter(Mandatory = $true)][object]$Receipt,
        [string]$ExpectedExecutionNonce = ''
    )
    $executionPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $ExecutionReference 'validation-execution' 'rusty.morphospace.workflow.validation_execution.v1'
    $execution = Read-MorphospaceAuthorityJson $executionPath
    Assert-MorphospaceExactPropertySet $execution @('schema','execution_id','completed_at','execution_nonce','project_id','unit_id','attempt_id','action','evidence','expected_receipt','output_contract_sha256','observations','executor','status') @() 'validation execution'
    if ([string]$execution.schema -ne 'rusty.morphospace.workflow.validation_execution.v1' -or [string]$execution.project_id -ne [string]$Unit.project_id -or [string]$execution.unit_id -ne [string]$Unit.unit_id -or [string]$execution.attempt_id -ne [string]$Action.attempt_id -or [string]$execution.execution_id -ne "$($Unit.unit_id)-$($Action.attempt_id)-execution" -or [string]$execution.status -ne 'completed') { throw 'Validation execution identity/status is invalid.' }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$execution.completed_at))
    if ([string]$execution.execution_nonce -notmatch '^[0-9a-f]{64}$' -or ($ExpectedExecutionNonce -and [string]$execution.execution_nonce -cne $ExpectedExecutionNonce)) { throw 'Validation execution nonce is invalid or does not belong to this authority invocation.' }
    $executionActionPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $execution.action 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'
    $executionEvidencePath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $execution.evidence 'validation-evidence' 'rusty.morphospace.workflow.validation_evidence.v2'
    $expectedActionPath = Resolve-MorphospaceAuthorityPath $WorkspaceRoot $ActionPath
    $expectedEvidencePath = Resolve-MorphospaceAuthorityPath $WorkspaceRoot $EvidencePath
    if (-not $executionActionPath.Equals($expectedActionPath, [StringComparison]::OrdinalIgnoreCase) -or -not $executionEvidencePath.Equals($expectedEvidencePath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Validation execution is not bound to the receipt action/evidence.' }
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
    $covered = @($seen | Sort-Object)
    if (($covered -join '|') -ne ($expected -join '|')) { throw 'Owner validation does not provide one typed criterion per selected acceptance.' }
    if (@($OwnerEvidence.does_not_prove | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -ne 0 -or @($OwnerEvidence.does_not_prove).Count -eq 0) { throw 'Owner validation limits are missing.' }
    return $OwnerEvidence
}

function Test-MorphospaceOwnerValidatorAdmissionProbeV1 {
    param(
        [Parameter(Mandatory = $true)][object]$Probe,
        [Parameter(Mandatory = $true)][object]$Validator,
        [Parameter(Mandatory = $true)][object]$Unit
    )
    Assert-MorphospaceExactPropertySet $Probe @('schema','validator_id','created_at','project_id','unit_id','unit_contract_sha256','commands','acceptance_bindings','status','does_not_prove') @() 'owner-validator admission probe'
    if ([string]$Probe.schema -cne 'rusty.morphospace.workflow.owner_validator_admission_probe.v1' -or [string]$Probe.validator_id -cne [string]$Validator.validator_id -or [string]$Probe.project_id -cne [string]$Unit.project_id -or [string]$Probe.unit_id -cne [string]$Unit.unit_id -or [string]$Probe.status -cne 'pass') { throw 'Owner-validator admission probe identity/status is invalid.' }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$Probe.created_at))
    $acceptanceIds = @($Unit.acceptance | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
    $unitContractText = "$([string]$Unit.risk_tier)`n$([string]$Unit.device_requirement)`n$($acceptanceIds -join "`n")"
    $expectedContractSha = Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ value = $unitContractText })
    if ([string]$Probe.unit_contract_sha256 -cne $expectedContractSha) { throw 'Owner-validator admission probe unit contract drifted.' }
    $commandIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $priorCommand = ''
    foreach ($command in @($Probe.commands)) {
        Assert-MorphospaceExactPropertySet $command @('command_id','command_name','command_sha256') @() 'owner-validator admission command'
        $commandId = [string]$command.command_id
        if ($commandId -notmatch '^[a-z0-9][a-z0-9-]{1,191}$' -or -not $commandIds.Add($commandId) -or ($priorCommand -and [StringComparer]::Ordinal.Compare($priorCommand,$commandId) -ge 0) -or [string]$command.command_name -match '[\\/]' -or -not [string]$command.command_name -or [string]$command.command_sha256 -notmatch '^[0-9a-f]{64}$') { throw "Owner-validator admission command is malformed or unsorted: $commandId" }
        $priorCommand = $commandId
    }
    if ($commandIds.Count -eq 0) { throw 'Owner-validator admission probe has no command identities.' }
    $bindingIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $priorBinding = ''
    foreach ($binding in @($Probe.acceptance_bindings)) {
        Assert-MorphospaceExactPropertySet $binding @('acceptance_id','command_id') @() 'owner-validator admission binding'
        $acceptanceId = [string]$binding.acceptance_id
        if (-not $bindingIds.Add($acceptanceId) -or ($priorBinding -and [StringComparer]::Ordinal.Compare($priorBinding,$acceptanceId) -ge 0) -or -not $commandIds.Contains([string]$binding.command_id)) { throw "Owner-validator admission binding is malformed or unsorted: $acceptanceId" }
        $priorBinding = $acceptanceId
    }
    if ((@($bindingIds | Sort-Object) -join '|') -cne ($acceptanceIds -join '|')) { throw 'Owner-validator admission probe does not bind the exact acceptance set.' }
    if (@($Probe.does_not_prove).Count -eq 0 -or @($Probe.does_not_prove | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -ne 0) { throw 'Owner-validator admission probe lacks explicit limits.' }
    return $Probe
}

function Get-MorphospaceCommittedTransitionPaths {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot,[Parameter(Mandatory = $true)][object[]]$AutomationOutputs,[Parameter(Mandatory = $true)][hashtable]$RepositoryMap)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');$planningRoot=[IO.Path]::GetFullPath([string]$RepositoryMap['planning'].path).TrimEnd('\','/');if(-not$workspace.StartsWith($planningRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Authority workspace is not contained by the planning repository.'};$prefix=$workspace.Substring($planningRoot.Length).TrimStart('\','/').Replace('\','/')
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($completionOutput in @($AutomationOutputs|Where-Object{[string]$_.phase-ceq'transition'-and[string]$_.role-ceq'transition-ledger-completion'})){
        $completionAbsolute=[IO.Path]::GetFullPath((Join-Path $planningRoot ([string]$completionOutput.path)));if(-not[IO.File]::Exists($completionAbsolute)){continue};$completion=Read-MorphospaceAuthorityJson $completionAbsolute;if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or[string]$completion.status-cne'committed'){throw 'Committed transition completion is malformed.'};$intentRelative=([string]$completion.intent.path);$intentAbsolute=Resolve-MorphospaceAuthorityPath $workspace $intentRelative;$intent=Read-MorphospaceAuthorityJson $intentAbsolute;if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or[string]$intent.status-cne'prepared'-or[string]$intent.transaction_id-cne[string]$completion.transaction_id-or(Get-MorphospaceAuthoritySha256 $intentAbsolute)-cne[string]$completion.intent.sha256){throw 'Committed transition intent is malformed or substituted.'}
        foreach($projection in @('state','unit')){$relative=[string]$intent.$projection.path;$absolute=Resolve-MorphospaceAuthorityPath $workspace $relative;$live=Read-MorphospaceAuthorityJson $absolute;if((Get-MorphospaceCanonicalJsonSha256 $live)-cne[string]$intent.target.$projection.sha256-or[string]$completion."$($projection)_sha256"-cne[string]$intent.target.$projection.sha256){throw "Committed transition $projection projection drifted."};[void]$paths.Add("planning/$prefix/$relative")}
        $eventsAbsolute=Resolve-MorphospaceAuthorityPath $workspace ([string]$intent.events.path);$eventId=[regex]::Escape([string]$intent.event.event_id);$matches=@(Get-Content -LiteralPath $eventsAbsolute|Where-Object{$_ -match ('"event_id"\s*:\s*"'+$eventId+'"')});$expectedEvent=($intent.event|ConvertTo-Json -Depth 32 -Compress);if($matches.Count-ne1-or$matches[0].Trim()-cne$expectedEvent-or[string]$completion.event_id-cne[string]$intent.event.event_id){throw 'Committed transition event is missing, duplicated, or substituted.'};[void]$paths.Add("planning/$prefix/$([string]$intent.events.path)")
    }
    return @($paths|Sort-Object)
}

function New-MorphospaceValidationReceiptV2 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object]$Action,
        [Parameter(Mandatory = $true)][string]$ActionPath,
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$EvidencePath,
        [Parameter(Mandatory = $true)][object]$Execution,
        [Parameter(Mandatory = $true)][string]$ExecutionPath,
        [Parameter(Mandatory = $true)][object]$Protocol,
        [Parameter(Mandatory = $true)][string]$ProtocolPath,
        [Parameter(Mandatory = $true)][object]$Ownership,
        [Parameter(Mandatory = $true)][string]$OwnershipPath,
        [Parameter(Mandatory = $true)][object]$Registry,
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][object]$Observation
    )
    $criteria = [Collections.Generic.List[object]]::new()
    foreach ($result in @($Evidence.validator_results)) {
        foreach ($acceptance in @($result.acceptance_ids)) { $criteria.Add([pscustomobject][ordered]@{ acceptance_id = [string]$acceptance; status = [string]$result.status; validator_id = [string]$result.validator_id; evidence_ref = $result.owner_evidence }) }
    }
    return [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.validation_receipt.v2'; receipt_id = "$($Unit.unit_id)-$($Action.attempt_id)-receipt"; created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); project_id = [string]$Unit.project_id; unit_id = [string]$Unit.unit_id; attempt_id = [string]$Action.attempt_id
        action = Get-MorphospaceBoundAuthorityReference $WorkspaceRoot $Action $ActionPath 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'; evidence = Get-MorphospaceBoundAuthorityReference $WorkspaceRoot $Evidence $EvidencePath 'validation-evidence' 'rusty.morphospace.workflow.validation_evidence.v2'; execution = Get-MorphospaceBoundAuthorityReference $WorkspaceRoot $Execution $ExecutionPath 'validation-execution' 'rusty.morphospace.workflow.validation_execution.v1'
        current_protocol = Get-MorphospaceBoundAuthorityReference $WorkspaceRoot $Protocol $ProtocolPath 'current-unit-protocol' 'rusty.morphospace.workflow.current_unit_protocol.v1'; ownership = Get-MorphospaceBoundAuthorityReference $WorkspaceRoot $Ownership $OwnershipPath 'unit-ownership' 'rusty.morphospace.workflow.unit_ownership.v1'; registry = Get-MorphospaceBoundAuthorityReference $WorkspaceRoot $Registry $RegistryPath 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'
        profile_id = [string]$Action.profile_id; result = [string]$Evidence.result; criteria = @($criteria.ToArray()); validators = @($Evidence.validator_results | ForEach-Object { [string]$_.validator_id } | Sort-Object -Unique); observations = [pscustomobject][ordered]@{ before_sha256 = [string]$Action.pre_observation_sha256; after_sha256 = [string]$Observation.sha256; allowed_delta_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ outputs = @($Action.expected_outputs | Sort-Object repo_id,path) })) }; device_validation = $Evidence.device_validation; status = 'accepted-evidence'
    }
}

function Test-MorphospaceValidationReceiptV2 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptReference,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap,
        [Parameter(Mandatory = $true)][string]$ExpectedResult,
        [string]$ExpectedExecutionNonce = ''
    )
    $receiptPath = Resolve-MorphospaceAuthorityPath $WorkspaceRoot $ReceiptReference
    $receipt = Read-MorphospaceAuthorityJson $receiptPath
    if ([string]$receipt.schema -ne 'rusty.morphospace.workflow.validation_receipt.v2' -or [string]$receipt.project_id -ne [string]$Unit.project_id -or [string]$receipt.unit_id -ne [string]$Unit.unit_id -or [string]$receipt.status -ne 'accepted-evidence') { throw 'Validation receipt v2 identity/status is invalid.' }
    if ([string]$receipt.result -ne $ExpectedResult) { throw 'Validation receipt v2 result does not match the requested transition.' }
    $protocolPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $receipt.current_protocol 'current-unit-protocol' 'rusty.morphospace.workflow.current_unit_protocol.v1'
    $protocol = Read-MorphospaceAuthorityJson $protocolPath
    if ([string]$protocol.project_id -ne [string]$Unit.project_id -or [string]$protocol.unit_id -ne [string]$Unit.unit_id -or [string]$protocol.status -ne 'active') { throw 'Current protocol does not bind this active unit.' }
    $registryPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $receipt.registry 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'
    $registry = Read-MorphospaceAuthorityJson $registryPath
    Test-MorphospaceOwnerValidatorRegistry -Registry $registry -RepositoryMap $RepositoryMap | Out-Null
    $migration = Test-MorphospaceValidatorTrustAnchorMigration -WorkspaceRoot $WorkspaceRoot -MigrationPath ([string]$protocol.trust_anchor_migration.path) -RegistryReference $protocol.registry -ExpectedProjectId ([string]$Unit.project_id) -ExpectedUnitId ([string]$Unit.unit_id) -RepositoryMap $RepositoryMap
    $ownershipPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $receipt.ownership 'unit-ownership' 'rusty.morphospace.workflow.unit_ownership.v1'
    $ownership = Read-MorphospaceAuthorityJson $ownershipPath
    $baselinePath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $ownership.claim_baseline 'claim-baseline' 'rusty.morphospace.workflow.claim_baseline.v1'
    $baseline = Read-MorphospaceAuthorityJson $baselinePath
    Test-MorphospaceClaimBaseline -Baseline $baseline -Unit $Unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $RepositoryMap | Out-Null
    $automationOutputs = @($ownership.automation_outputs)
    $transitionPaths=@(Get-MorphospaceCommittedTransitionPaths -WorkspaceRoot $WorkspaceRoot -AutomationOutputs $automationOutputs -RepositoryMap $RepositoryMap)
    if($transitionPaths.Count-gt0){$current=Test-MorphospaceUnitOwnership -Ownership $ownership -ClaimBaseline $baseline -ClaimBaselineReference $protocol.claim_baseline -Unit $Unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $RepositoryMap -CommittedTransitionPaths $transitionPaths}
    else{$current=Test-MorphospaceUnitOwnership -Ownership $ownership -ClaimBaseline $baseline -ClaimBaselineReference $protocol.claim_baseline -Unit $Unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $RepositoryMap}
    $automationOutputs = @($current.automation_outputs)
    if ($automationOutputs.Count -eq 0) { throw 'Validation receipt v2 lacks an ownership-bound automation output contract.' }
    Test-MorphospaceAutomationOutputSet -AutomationOutputs @($automationOutputs|Where-Object{[string]$_.phase-cne'transition'}) -RepositoryMap $RepositoryMap -Expected present
    $actionPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $receipt.action 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'
    $action = Read-MorphospaceAuthorityJson $actionPath
    if ([string]$action.pre_observation_sha256 -ne [string]$receipt.observations.before_sha256 -or($transitionPaths.Count-eq0-and[string]$current.observation.sha256 -ne [string]$receipt.observations.after_sha256)) { throw 'Validation receipt v2 observation boundary drifted.' }
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
    $execution = Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $WorkspaceRoot -ExecutionReference $receipt.execution -Unit $Unit -Action $action -ActionPath $actionPath -Evidence $evidence -EvidencePath $evidencePath -AutomationOutputs $automationOutputs -ReceiptReference ([string]$receiptOutput[0].path) -Receipt $receipt -ExpectedExecutionNonce $ExpectedExecutionNonce
    $runnerArtifacts = @($migration.authority_artifacts | Where-Object { [string]$_.repo_id -ceq 'work-environment' -and [string]$_.path -ceq 'scripts/Invoke-MorphospaceValidationAuthority.ps1' })
    if ($runnerArtifacts.Count -ne 1 -or [string]$execution.executor.command_sha256 -cne [string]$runnerArtifacts[0].sha256) { throw 'Validation execution is not bound to the migrated authority runner.' }
    $expectedCriteria = @($Unit.acceptance | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
    $actualCriteria = @($receipt.criteria | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
    if (($expectedCriteria -join '|') -ne ($actualCriteria -join '|')) { throw 'Validation receipt v2 does not cover the exact acceptance set.' }
    if ($ExpectedResult -eq 'pass' -and @($receipt.criteria | Where-Object { [string]$_.status -ne 'pass' }).Count -ne 0) { throw 'Passing validation receipt v2 has a non-passing criterion.' }
    return $receipt
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Read-MorphospaceAuthorityJson, Get-MorphospaceAuthoritySha256, Invoke-MorphospacePinnedValidator, Resolve-MorphospaceAuthorityPath, Get-MorphospaceAuthorityReference, Assert-MorphospaceAuthorityReference, Test-MorphospaceValidatorTrustAnchorMigration, Test-MorphospaceOwnerValidation, Test-MorphospaceOwnerValidatorAdmissionProbeV1, Test-MorphospaceValidationEvidenceV2, New-MorphospaceValidationExecutionV1, Test-MorphospaceValidationExecutionV1, New-MorphospaceValidationReceiptV2, Test-MorphospaceValidationReceiptV2
