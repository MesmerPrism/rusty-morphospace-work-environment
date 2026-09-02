Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force

function Get-MorphospaceSelectorTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Get-MorphospaceCanonicalEvidencePathIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'Normal-validation evidence path must be absolute.'
    }
    $canonicalPath = [IO.Path]::GetFullPath($Path)
    $identityText = if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $canonicalPath.Replace('/', '\').ToUpperInvariant()
    } else {
        $canonicalPath
    }
    return [pscustomobject][ordered]@{
        path = $canonicalPath
        sha256 = Get-MorphospaceSelectorTextSha256 $identityText
    }
}

function Get-MorphospaceSelectorUnitContractSha256 {
    param([Parameter(Mandatory = $true)][object]$Unit)

    $copy = (($Unit | ConvertTo-Json -Depth 100) | ConvertFrom-Json)
    if ($copy.PSObject.Properties.Name -contains 'status') {
        $copy.PSObject.Properties.Remove('status')
    }
    return Get-MorphospaceCanonicalJsonSha256 $copy
}

function ConvertTo-MorphospacePowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Resolve-MorphospaceSelectorWorkspacePath {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [switch]$RequireLeaf
    )

    if ([IO.Path]::IsPathFullyQualified($RelativePath) -or $RelativePath.Contains('\') -or $RelativePath -match '(^|/)\.\.(/|$)') {
        throw "Normal-validation selector paths must be forward-slash workspace-relative paths without traversal."
    }
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $absolute = [IO.Path]::GetFullPath((Join-Path $workspace ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)))
    $prefix = $workspace + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Normal-validation selector path escaped the project workspace."
    }
    if ($RequireLeaf -and -not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        throw "Normal-validation selector input is missing: $RelativePath"
    }
    if ($RequireLeaf) {
        $current = $workspace
        foreach ($segment in @($RelativePath -split '/')) {
            $current = Join-Path $current $segment
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Normal-validation selector inputs and their workspace-relative parents may not be reparse points."
            }
        }
    }
    return $absolute
}

function Test-MorphospaceFinalRepositoryBinding {
    param(
        [Parameter(Mandatory = $true)][object[]]$Expected,
        [Parameter(Mandatory = $true)][object[]]$Observed
    )

    if ($Expected.Count -ne $Observed.Count) { return $false }
    $seen = @{}
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        $left = $Expected[$i]
        $right = $Observed[$i]
        $repoId = [string]$left.repo_id
        if (-not $repoId -or $seen.ContainsKey($repoId)) { return $false }
        $seen[$repoId] = $true
        if ($repoId -cne [string]$right.repo_id -or
            [string]$left.commit -cne [string]$right.commit -or
            [string]$left.tree -cne [string]$right.tree) {
            return $false
        }
    }
    return $true
}

function Resolve-MorphospaceNormalValidationSelector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$SelectorReference,
        [Parameter(Mandatory = $true)][string]$ExpectedSelectorSha256,
        [Parameter(Mandatory = $true)][string]$EvidencePath,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object[]]$DeclaredValidationMatrix,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ValidationTier,
        [object]$BoundSelection = $null
    )

    $consumptionActions = @('ReturnToActive', 'RecordValidation', 'Accept')
    $evidencePhase = if ($Action -ceq 'BeginValidation') { 'dispatch' } elseif ($Action -cin $consumptionActions) { 'consumption' } else { '' }
    if (-not $evidencePhase) { throw 'A normal-validation selector is valid only for BeginValidation or a receipt-consuming validation lifecycle action.' }
    if ($ValidationTier -cne 'quick') { throw 'A normal-validation selector is valid only for the Quick tier.' }
    if ($ExpectedSelectorSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Expected normal-validation selector SHA-256 is required in lowercase hexadecimal.' }
    if ($SelectorReference -cnotmatch '^validation-authority/selectors/[a-z0-9][a-z0-9-]{1,127}\.json$') {
        throw 'Normal-validation selectors must be exact files under validation-authority/selectors/.'
    }

    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $selectorPath = Resolve-MorphospaceSelectorWorkspacePath -WorkspaceRoot $workspace -RelativePath $SelectorReference -RequireLeaf
    $selectorSha256 = Get-MorphospaceFileSha256 $selectorPath
    if ($selectorSha256 -cne $ExpectedSelectorSha256) { throw 'Normal-validation selector SHA-256 does not match the expected owner binding.' }
    $schemaPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas\normal-validation-selector-v1.schema.json'
    try {
        $selectorValid = Test-Json -Json (Get-Content -Raw -LiteralPath $selectorPath) -SchemaFile $schemaPath
    } catch {
        throw 'Normal-validation selector does not satisfy normal-validation-selector-v1.schema.json.'
    }
    if (-not $selectorValid) {
        throw 'Normal-validation selector does not satisfy normal-validation-selector-v1.schema.json.'
    }
    $selector = Read-MorphospaceProtocolJson $selectorPath
    $selectorLeafId = [IO.Path]::GetFileNameWithoutExtension($selectorPath)
    if ([string]$selector.selector_id -cne $selectorLeafId) {
        throw 'Normal-validation selector file leaf must exactly equal selector_id.'
    }

    $projectPath = Resolve-MorphospaceSelectorWorkspacePath -WorkspaceRoot $workspace -RelativePath 'project.spec.json' -RequireLeaf
    if ([string]$selector.project.project_id -cne [string]$Spec.project_id -or
        [string]$selector.project.spec_raw_sha256 -cne (Get-MorphospaceFileSha256 $projectPath)) {
        throw 'Normal-validation selector project identity or raw bytes drifted.'
    }

    $expectedUnitPath = "iteration-units/$([string]$Unit.unit_id).json"
    if ([string]$selector.unit.unit_id -cne [string]$Unit.unit_id -or [string]$selector.unit.path -cne $expectedUnitPath) {
        throw 'Normal-validation selector unit identity or path does not match the selected unit.'
    }
    $unitPath = Resolve-MorphospaceSelectorWorkspacePath -WorkspaceRoot $workspace -RelativePath $expectedUnitPath -RequireLeaf
    $liveUnitRawSha256 = Get-MorphospaceFileSha256 $unitPath
    $liveUnitContractSha256 = Get-MorphospaceSelectorUnitContractSha256 $Unit
    if ([string]$selector.unit.contract_sha256 -cne $liveUnitContractSha256) {
        throw 'Normal-validation selector unit contract drifted beyond lifecycle status.'
    }
    if ($null -eq $BoundSelection) {
        if ([string]$selector.unit.raw_sha256 -cne $liveUnitRawSha256) {
            throw 'Normal-validation selector unit raw bytes drifted.'
        }
    } elseif (
        [string]$selector.unit.raw_sha256 -cne [string]$BoundSelection.unit_raw_sha256 -or
        [string]$selector.unit.contract_sha256 -cne [string]$BoundSelection.unit_contract_sha256
    ) {
        throw 'Normal-validation selector unit identity does not match the exact dispatch binding.'
    }

    $profileId = [string]$selector.declared_gate.profile_id
    $matchingRows = @($DeclaredValidationMatrix | Where-Object { $_.kind -ceq 'command' -and [string]$_.profile_id -ceq $profileId })
    if ($matchingRows.Count -ne 1) { throw 'Normal-validation selector must bind exactly one declared unit validation gate.' }
    $declaredRow = $matchingRows[0]
    $declaredCommandSha256 = Get-MorphospaceSelectorTextSha256 ([string]$declaredRow.command)
    if ([string]$selector.declared_gate.command_sha256 -cne $declaredCommandSha256) {
        throw 'Normal-validation selector declared gate command binding drifted.'
    }

    if (-not ($Unit.PSObject.Properties.Name -contains 'candidate_freeze')) {
        throw 'Normal-validation selector requires an already frozen unit.'
    }
    $unitFreeze = $Unit.candidate_freeze
    if ([string]$selector.candidate_freeze.freeze_id -cne [string]$unitFreeze.freeze_id -or
        [string]$selector.candidate_freeze.receipt_path -cne [string]$unitFreeze.receipt_path -or
        [string]$selector.candidate_freeze.receipt_sha256 -cne [string]$unitFreeze.receipt_sha256) {
        throw 'Normal-validation selector candidate-freeze marker binding drifted.'
    }
    $freezePath = Resolve-MorphospaceSelectorWorkspacePath -WorkspaceRoot $workspace -RelativePath ([string]$unitFreeze.receipt_path) -RequireLeaf
    if ((Get-MorphospaceFileSha256 $freezePath) -cne [string]$unitFreeze.receipt_sha256) {
        throw 'Normal-validation selector candidate-freeze receipt bytes drifted.'
    }
    $freezeReceipt = Read-MorphospaceProtocolJson $freezePath
    if (@('rusty.morphospace.workflow.candidate_freeze.v1','rusty.morphospace.workflow.candidate_freeze.v2') -cnotcontains [string]$freezeReceipt.schema -or
        [string]$freezeReceipt.project_id -cne [string]$Spec.project_id -or
        [string]$freezeReceipt.unit_id -cne [string]$Unit.unit_id -or
        [string]$freezeReceipt.freeze_id -cne [string]$unitFreeze.freeze_id) {
        throw 'Normal-validation selector candidate-freeze receipt identity drifted.'
    }
    if (-not (Test-MorphospaceFinalRepositoryBinding -Expected @($selector.candidate_freeze.final_repositories) -Observed @($freezeReceipt.final_repositories))) {
        throw 'Normal-validation selector frozen candidate repository binding drifted.'
    }

    $producerRelative = [string]$selector.selection.producer.path
    $producerPath = Resolve-MorphospaceSelectorWorkspacePath -WorkspaceRoot $workspace -RelativePath $producerRelative -RequireLeaf
    if ((Get-MorphospaceFileSha256 $producerPath) -cne [string]$selector.selection.producer.sha256) {
        throw 'Normal-validation selector evidence producer bytes drifted.'
    }

    $evidenceIdentity = Get-MorphospaceCanonicalEvidencePathIdentity $EvidencePath
    $evidence = [string]$evidenceIdentity.path
    $workspacePrefix = $workspace + [IO.Path]::DirectorySeparatorChar
    if ($evidence.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Normal-validation evidence must be written outside the project workspace.'
    }
    if ([IO.Path]::GetFileName($evidence) -cne [string]$selector.selection.output_evidence.file_name) {
        throw 'Normal-validation evidence file name does not match the exact selector binding.'
    }
    if ([string]$selector.selection.output_evidence.canonical_path_sha256 -cne [string]$evidenceIdentity.sha256) {
        throw 'Normal-validation evidence canonical path does not match the exact selector binding.'
    }
    $evidenceParent = Split-Path -Parent $evidence
    if (-not (Test-Path -LiteralPath $evidenceParent -PathType Container)) {
        throw 'Normal-validation evidence parent directory must already exist.'
    }
    $evidenceAncestor = [IO.Path]::GetFullPath($evidenceParent)
    while ($evidenceAncestor) {
        if ((Get-Item -LiteralPath $evidenceAncestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Normal-validation evidence parent ancestry may not contain a reparse point.'
        }
        $nextAncestor = Split-Path -Parent $evidenceAncestor
        if (-not $nextAncestor -or $nextAncestor -ceq $evidenceAncestor) { break }
        $evidenceAncestor = $nextAncestor
    }
    $evidenceSha256 = $null
    if ($evidencePhase -ceq 'dispatch') {
        if (Test-Path -LiteralPath $evidence) { throw 'Normal-validation evidence collision; refusing to dispatch over an existing path.' }
    } else {
        if (-not (Test-Path -LiteralPath $evidence -PathType Leaf)) {
            throw 'Normal-validation evidence is required for receipt consumption.'
        }
        if ((Get-Item -LiteralPath $evidence -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Normal-validation evidence may not be a reparse point.'
        }
        $evidenceDocument = Read-MorphospaceProtocolJson $evidence
        if ([string]$evidenceDocument.schema -cne [string]$selector.selection.output_evidence.schema) {
            throw 'Normal-validation evidence schema does not match the exact selector binding.'
        }
        $evidenceSha256 = Get-MorphospaceFileSha256 $evidence
    }

    $dispatchCommand = @(
        'pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File',
        (ConvertTo-MorphospacePowerShellLiteral $producerPath),
        '-WorkspaceRoot', (ConvertTo-MorphospacePowerShellLiteral $workspace),
        '-EvidencePath', (ConvertTo-MorphospacePowerShellLiteral $evidence)
    ) -join ' '
    $selectedRows = @($DeclaredValidationMatrix | ForEach-Object {
        if ($_ -ne $declaredRow) { return $_ }
        return [pscustomobject][ordered]@{
            order = [int]$_.order
            gate_id = [string]$_.gate_id
            kind = 'command'
            profile_id = [string]$_.profile_id
            command = $dispatchCommand
            disposition = 'required'
            selection_kind = 'exact-external-evidence'
            selector = [pscustomobject][ordered]@{
                selector_id = [string]$selector.selector_id
                path = $SelectorReference
                sha256 = $selectorSha256
                declared_command_sha256 = $declaredCommandSha256
                producer_path = $producerRelative
                producer_sha256 = [string]$selector.selection.producer.sha256
                evidence = [pscustomobject][ordered]@{
                    path = $evidence
                    canonical_path_sha256 = [string]$evidenceIdentity.sha256
                    file_name = [string]$selector.selection.output_evidence.file_name
                    schema = [string]$selector.selection.output_evidence.schema
                    requires_create_new = $true
                    phase = $evidencePhase
                    sha256 = $evidenceSha256
                }
            }
        }
    })

    return [pscustomobject][ordered]@{
        selector_id = [string]$selector.selector_id
        selector_path = $SelectorReference
        selector_sha256 = $selectorSha256
        evidence_phase = $evidencePhase
        state_binding = [pscustomobject][ordered]@{
            unit_id = [string]$Unit.unit_id
            unit_raw_sha256 = [string]$selector.unit.raw_sha256
            unit_contract_sha256 = [string]$selector.unit.contract_sha256
            tier = 'quick'
            selector_id = [string]$selector.selector_id
            selector_path = $SelectorReference
            selector_sha256 = $selectorSha256
            evidence_path_sha256 = [string]$evidenceIdentity.sha256
        }
        validation_matrix = $selectedRows
    }
}

Export-ModuleMember -Function Resolve-MorphospaceNormalValidationSelector
