param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$QuestRoot,
    [Parameter(Mandatory = $true)][string]$RoadmapPath,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [switch]$ProbeOnly
)

$ErrorActionPreference = 'Stop'

function Read-ValidatorJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required validator input is missing: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Assert-Validator {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-ValidatorHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-TextHash {
    param([AllowNull()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
    return ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
}

function Invoke-ValidatorCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CommandId,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )
    Assert-Validator (Test-Path -LiteralPath $ScriptPath -PathType Leaf) "Validator command is missing: $ScriptPath"
    $output = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    return [pscustomobject][ordered]@{
        command_id = $CommandId
        command_path = $ScriptPath
        command_sha256 = Get-ValidatorHash $ScriptPath
        exit_code = [int]$exitCode
        status = if ($exitCode -eq 0) { 'pass' } else { 'fail' }
        output_sha256 = Get-TextHash $text
    }
}

function Write-ValidatorOutput {
    param([Parameter(Mandatory = $true)][object]$Value)
    $target = [IO.Path]::GetFullPath($OutPath)
    $directory = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Validator output directory does not exist: $directory" }
    $json = $Value | ConvertTo-Json -Depth 20
    $stream = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    $json
}

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$quest = [IO.Path]::GetFullPath($QuestRoot)
$roadmap = [IO.Path]::GetFullPath($RoadmapPath)
$unit = Read-ValidatorJson (Join-Path $workspace "iteration-units\$UnitId.json")
Assert-Validator ([string]$unit.unit_id -eq $UnitId) 'Owner validator unit identity mismatch.'
Assert-Validator ([string]$unit.risk_tier -eq 'deep') 'WF-005 must remain a deep validator profile.'
Assert-Validator ([string]$unit.device_requirement -eq 'none') 'WF-005 must remain a no-device corrective unit.'
$expected = @($unit.acceptance | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
$gate = Join-Path $quest 'tools\checks\Test-SpatialCameraPanelWorkflowStatic.ps1'
$ownership = Join-Path $PSScriptRoot 'Test-OwnershipAuthority.ps1'
$contracts = Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1'
$executionAuthority = Join-Path $PSScriptRoot 'Test-ValidationExecutionAuthority.ps1'
$transitionLedger = Join-Path $PSScriptRoot 'Test-TransitionLedger.ps1'
$authorityHandoff = Join-Path $PSScriptRoot 'Test-AuthorityRunnerHandoff.ps1'
$commandDefinitions = @(
    [pscustomobject]@{ command_id = 'quest-workspace-static-gate'; path = $gate },
    [pscustomobject]@{ command_id = 'portable-ownership-authority-self-test'; path = $ownership },
    [pscustomobject]@{ command_id = 'portable-workflow-contract-self-test'; path = $contracts },
    [pscustomobject]@{ command_id = 'validation-execution-authority-self-test'; path = $executionAuthority },
    [pscustomobject]@{ command_id = 'transition-ledger-recovery-self-test'; path = $transitionLedger },
    [pscustomobject]@{ command_id = 'authority-runner-handoff-self-test'; path = $authorityHandoff }
)
$criterionCommandIds = @{
    'spatial-history' = 'quest-workspace-static-gate'
    'candidate-maturity' = 'quest-workspace-static-gate'
    'native-workspace' = 'quest-workspace-static-gate'
    'inert-defaults' = 'quest-workspace-static-gate'
    'derived-state' = 'quest-workspace-static-gate'
    'inflight-adoption' = 'portable-workflow-contract-self-test'
    'validator-derived-evidence' = 'portable-ownership-authority-self-test'
    'overlay-content-integrity' = 'portable-ownership-authority-self-test'
    'unit-attribution' = 'portable-ownership-authority-self-test'
    'device-derivation' = 'portable-workflow-contract-self-test'
}
if ($ProbeOnly) {
    $commands = @($commandDefinitions | Sort-Object command_id | ForEach-Object {
        Assert-Validator (Test-Path -LiteralPath $_.path -PathType Leaf) "Validator command is missing: $($_.path)"
        [pscustomobject][ordered]@{command_id=[string]$_.command_id;command_name=[IO.Path]::GetFileName([string]$_.path);command_sha256=Get-ValidatorHash ([string]$_.path)}
    })
    $bindings = @($expected | ForEach-Object {
        $acceptanceId = [string]$_
        Assert-Validator ($criterionCommandIds.ContainsKey($acceptanceId)) "Validator admission mapping is missing: $acceptanceId"
        [pscustomobject][ordered]@{acceptance_id=$acceptanceId;command_id=[string]$criterionCommandIds[$acceptanceId]}
    })
    $unitContractText = "$([string]$unit.risk_tier)`n$([string]$unit.device_requirement)`n$($expected -join "`n")"
    $probe = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.owner_validator_admission_probe.v1'
        validator_id = 'wf005-workspace-owner'
        created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        project_id = [string]$unit.project_id
        unit_id = $UnitId
        unit_contract_sha256 = Get-TextHash (($([pscustomobject]@{value=$unitContractText})) | ConvertTo-Json -Compress)
        commands = $commands
        acceptance_bindings = $bindings
        status = 'pass'
        does_not_prove = @('Admission only: does not execute acceptance commands or constitute owner validation evidence, validation, or acceptance.')
    }
    Write-ValidatorOutput $probe
    exit 0
}
$staticResult = Invoke-ValidatorCommand -CommandId 'quest-workspace-static-gate' -ScriptPath $gate -Arguments @('-RepoRoot', $quest, '-RoadmapPath', $roadmap)
$ownershipResult = Invoke-ValidatorCommand -CommandId 'portable-ownership-authority-self-test' -ScriptPath $ownership -Arguments @()
$contractResult = Invoke-ValidatorCommand -CommandId 'portable-workflow-contract-self-test' -ScriptPath $contracts -Arguments @('-RepoRoot', (Split-Path -Parent $PSScriptRoot), '-WorkspaceRoot', $workspace)
$executionResult = Invoke-ValidatorCommand -CommandId 'validation-execution-authority-self-test' -ScriptPath $executionAuthority -Arguments @()
$transitionResult = Invoke-ValidatorCommand -CommandId 'transition-ledger-recovery-self-test' -ScriptPath $transitionLedger -Arguments @()
$handoffResult = Invoke-ValidatorCommand -CommandId 'authority-runner-handoff-self-test' -ScriptPath $authorityHandoff -Arguments @()
if ($executionResult.exit_code -ne 0 -or $transitionResult.exit_code -ne 0 -or $handoffResult.exit_code -ne 0) { throw 'Authority execution, runner handoff, or transition-ledger self-test failed.' }
$criterionCommands = @{
    'spatial-history' = $staticResult
    'candidate-maturity' = $staticResult
    'native-workspace' = $staticResult
    'inert-defaults' = $staticResult
    'derived-state' = $staticResult
    'inflight-adoption' = $contractResult
    'validator-derived-evidence' = $ownershipResult
    'overlay-content-integrity' = $ownershipResult
    'unit-attribution' = $ownershipResult
    'device-derivation' = $contractResult
}
$criteria = [Collections.Generic.List[object]]::new()
foreach ($acceptanceId in $expected) {
    $result = $criterionCommands[$acceptanceId]
    $criteria.Add([pscustomobject][ordered]@{
        acceptance_id = $acceptanceId
        status = [string]$result.status
        command_id = [string]$result.command_id
        command_path = [IO.Path]::GetFileName([string]$result.command_path)
        command_sha256 = [string]$result.command_sha256
        output_sha256 = [string]$result.output_sha256
        exit_code = [int]$result.exit_code
    }) | Out-Null
}
$status = if (@($criteria | Where-Object { [string]$_.status -ne 'pass' }).Count -eq 0) { 'pass' } else { 'fail' }
$output = [pscustomobject][ordered]@{
    schema = 'rusty.morphospace.workflow.owner_validation.v1'
    validator_id = 'wf005-workspace-owner'
    created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    project_id = [string]$unit.project_id
    unit_id = $UnitId
    acceptance_ids = $expected
    status = $status
    criteria = @($criteria.ToArray())
    does_not_prove = @('Does not prove device validation, stable promotion, external Git push, or any downstream NET-013/MOD-006 acceptance.')
}
Write-ValidatorOutput $output
