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
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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
        foreach ($acceptance in @($result.acceptance_ids)) { if (-not $covered.Add([string]$acceptance)) { throw "Acceptance is claimed twice: $acceptance" } }
        $ownerPath = Assert-MorphospaceAuthorityReference $WorkspaceRoot $result.owner_evidence 'owner-validation' 'rusty.morphospace.workflow.owner_validation.v1'
        $owner = Read-MorphospaceAuthorityJson $ownerPath
        if ([string]$owner.validator_id -ne $id -or [string]$owner.status -ne [string]$result.status -or ((@($owner.acceptance_ids) | Sort-Object) -join '|') -ne ((@($result.acceptance_ids) | Sort-Object) -join '|')) { throw "Owner validation does not match the evidence projection: $id" }
    }
    $expected = @($Unit.acceptance | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
    if (($covered.ToArray() | Sort-Object) -join '|' -ne $expected -join '|') { throw 'Validation evidence does not cover the exact acceptance set.' }
    if ([string]$evidence.result -eq 'pass' -and (@($evidence.validator_results | Where-Object { [string]$_.status -ne 'pass' }).Count -ne 0)) { throw 'Passing evidence has a non-passing validator.' }
    return $evidence
}

function New-MorphospaceValidationReceiptV2 {
    param([string]$WorkspaceRoot, [object]$Unit, [object]$Action, [object]$Evidence, [object]$Protocol, [object]$Ownership, [object]$Registry, [object]$Observation)
    $criteria = [Collections.Generic.List[object]]::new()
    foreach ($result in @($Evidence.validator_results)) {
        foreach ($acceptance in @($result.acceptance_ids)) { $criteria.Add([pscustomobject][ordered]@{ acceptance_id = [string]$acceptance; status = [string]$result.status; validator_id = [string]$result.validator_id; evidence_ref = $result.owner_evidence }) }
    }
    return [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.validation_receipt.v2'; receipt_id = "$($Unit.unit_id)-$($Action.attempt_id)-receipt"; created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); project_id = [string]$Unit.project_id; unit_id = [string]$Unit.unit_id; attempt_id = [string]$Action.attempt_id
        action = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Action.__path) 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'; evidence = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Evidence.__path) 'validation-evidence' 'rusty.morphospace.workflow.validation_evidence.v2'
        current_protocol = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Protocol.__path) 'current-unit-protocol' 'rusty.morphospace.workflow.current_unit_protocol.v1'; ownership = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Ownership.__path) 'unit-ownership' 'rusty.morphospace.workflow.unit_ownership.v1'; registry = Get-MorphospaceAuthorityReference $WorkspaceRoot ([string]$Registry.__path) 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'
        profile_id = [string]$Action.profile_id; result = [string]$Evidence.result; criteria = @($criteria.ToArray()); validators = @($Evidence.validator_results | ForEach-Object { [string]$_.validator_id } | Sort-Object -Unique); observations = [pscustomobject][ordered]@{ before_sha256 = [string]$Action.pre_observation_sha256; after_sha256 = [string]$Observation.sha256; allowed_delta_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ outputs = @($Action.expected_outputs | Sort-Object) })) }; device_validation = $Evidence.device_validation; status = 'accepted-evidence'
    }
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Read-MorphospaceAuthorityJson, Get-MorphospaceAuthoritySha256, Resolve-MorphospaceAuthorityPath, Get-MorphospaceAuthorityReference, Assert-MorphospaceAuthorityReference, Test-MorphospaceValidatorTrustAnchorMigration, Test-MorphospaceValidationEvidenceV2, New-MorphospaceValidationReceiptV2
