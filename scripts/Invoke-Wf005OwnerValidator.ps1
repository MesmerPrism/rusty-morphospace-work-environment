param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$QuestRoot,
    [Parameter(Mandatory = $true)][string]$RoadmapPath,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$OutPath
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
$target = [IO.Path]::GetFullPath($OutPath)
$directory = Split-Path -Parent $target
if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Validator output directory does not exist: $directory" }
$json = $output | ConvertTo-Json -Depth 20
$stream = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
} finally {
    $stream.Dispose()
}
$output | ConvertTo-Json -Depth 20
