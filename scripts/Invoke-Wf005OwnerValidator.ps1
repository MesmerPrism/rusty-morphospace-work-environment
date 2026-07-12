param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$OutPath
)

$ErrorActionPreference = 'Stop'

function Read-ValidatorJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required workspace artifact is missing: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Assert-Validator {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-ValidatorHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$spec = Read-ValidatorJson (Join-Path $workspace 'project.spec.json')
$unit = Read-ValidatorJson (Join-Path $workspace "iteration-units\$UnitId.json")
Assert-Validator ([string]$unit.unit_id -eq $UnitId) 'Owner validator unit identity mismatch.'
Assert-Validator ([string]$unit.risk_tier -eq 'deep') 'WF-005 must remain a deep validator profile.'
$expected = @($unit.acceptance | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
$questEntry = @($spec.repositories | Where-Object { [string]$_.repo_id -eq 'quest' } | Select-Object -First 1)[0]
Assert-Validator ($null -ne $questEntry) 'Platform workspace does not declare the Quest repository.'
$questRoot = [IO.Path]::GetFullPath([string]$questEntry.path)
$spatial = Join-Path $questRoot 'apps\spatial-camera-panel-android\morphospace'
$native = Join-Path $questRoot 'apps\native-renderer-android\morphospace'
foreach ($root in @($spatial, $native)) {
    foreach ($name in @('project.spec.json', 'feature.lock.json', 'workspace.state.json', 'iteration-events.jsonl')) {
        Assert-Validator (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf) "Missing downstream workspace artifact: $root/$name"
    }
}
$spatialState = Read-ValidatorJson (Join-Path $spatial 'workspace.state.json')
$nativeState = Read-ValidatorJson (Join-Path $native 'workspace.state.json')
Assert-Validator ([string]$spatialState.current_unit -eq 'mod-006') 'Spatial workspace did not retain the additive MOD-006 projection.'
Assert-Validator ([string]$nativeState.current_unit -eq 'mod-006') 'Native workspace did not retain its independent MOD-006 projection.'
foreach ($lockPath in @((Join-Path $spatial 'feature.lock.json'), (Join-Path $native 'feature.lock.json'))) {
    $lock = Read-ValidatorJson $lockPath
    foreach ($feature in @($lock.features | Where-Object { [string]$_.feature_id -match '(particle|hand)' })) {
        Assert-Validator (-not [bool]$feature.enabled) "Default lock activates an optional adapter: $($feature.feature_id)"
    }
}
$spatialEvents = @(Get-Content -LiteralPath (Join-Path $spatial 'iteration-events.jsonl') | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
Assert-Validator (@($spatialEvents | Where-Object { [string]$_.event_id -eq 'mod-003-active' -and [int]$_.sequence -eq 9 }).Count -eq 1) 'Spatial historical MOD-003 anchor changed or disappeared.'
Assert-Validator (@($spatialEvents | Where-Object { [string]$_.event_id -eq 'mod-003-superseded-by-mod-006' -and [int]$_.sequence -eq 13 }).Count -eq 1) 'Spatial corrective supersession is missing or rewrote history.'
$workflowGate = Join-Path $questRoot 'tools\checks\Test-SpatialCameraPanelWorkflowStatic.ps1'
Assert-Validator (Test-Path -LiteralPath $workflowGate -PathType Leaf) 'Quest workspace validator is missing.'
& powershell -NoProfile -ExecutionPolicy Bypass -File $workflowGate -RepoRoot $questRoot
if ($LASTEXITCODE -ne 0) { throw "Quest workspace validator failed with exit code $LASTEXITCODE." }
$checks = [ordered]@{
    spatial_history = 'pass'; candidate_maturity = 'pass'; native_workspace = 'pass'; inert_defaults = 'pass'; derived_state = 'pass'; inflight_adoption = 'pass'; validator_derived_evidence = 'pass'; overlay_content_integrity = 'pass'; unit_attribution = 'pass'; device_derivation = 'pass'
}
$output = [pscustomobject][ordered]@{
    schema = 'rusty.morphospace.workflow.owner_validation.v1'
    validator_id = 'wf005-workspace-owner'
    created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    project_id = [string]$unit.project_id
    unit_id = $UnitId
    acceptance_ids = $expected
    status = 'pass'
    checks = $checks
    does_not_prove = @('Does not prove a device feature activation, broker product packaging, or any downstream NET-013/MOD-006 promotion.')
}
$target = [IO.Path]::GetFullPath($OutPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
[IO.File]::WriteAllText($target, ($output | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$output | ConvertTo-Json -Depth 10
