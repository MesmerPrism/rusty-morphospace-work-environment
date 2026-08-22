param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$RepositoryMapPath,
    [Parameter(Mandatory)][string]$BaselineId,
    [string]$RepoRoot = "",
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($BaselineId -cnotmatch '^[a-z0-9][a-z0-9-]{7,127}$') { throw 'Historical-debt baseline ID is invalid.' }
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$RepositoryMapPath = (Resolve-Path -LiteralPath $RepositoryMapPath).Path
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceHistoricalValidationDebtBaseline.psm1') -Force

function Get-BaselineCaptureCas {
    param([string]$Workspace, [string]$RepositoryMap)
    $state = Read-MorphospaceProtocolJson -Path (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath 'workspace.state.json' -RequireLeaf)
    $currentPath = if ($null -eq $state.current_unit) { $null } else { "iteration-units/$([string]$state.current_unit).json" }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($relative in @('project.spec.json','feature.lock.json','workspace.state.json','iteration-events.jsonl') + @($currentPath | Where-Object { $null -ne $_ })) {
        $absolute = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath $relative -RequireLeaf
        $rows.Add([pscustomobject][ordered]@{ path=$relative; sha256=Get-MorphospaceFileSha256 -Path $absolute; length=[long](Get-Item -LiteralPath $absolute).Length }) | Out-Null
    }
    return [pscustomobject][ordered]@{
        workspace = @($rows.ToArray())
        repository_map_sha256 = Get-MorphospaceFileSha256 -Path $RepositoryMap
    }
}

$before = Get-BaselineCaptureCas -Workspace $WorkspaceRoot -RepositoryMap $RepositoryMapPath
$hostPath = [Environment]::ProcessPath
if ([string]::IsNullOrWhiteSpace($hostPath) -or -not [IO.File]::Exists($hostPath)) { $hostPath = (Get-Command pwsh -ErrorAction Stop).Source }
$validator = Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1'
$output = @(& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator `
    -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -RepositoryMapPath $RepositoryMapPath `
    -EmitHistoricalValidationDebtCapture 2>&1)
$exitCode = $LASTEXITCODE
$captureLines = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith('historical_validation_debt_capture_base64=', [StringComparison]::Ordinal) })
if ($captureLines.Count -ne 1) { throw 'Historical-debt baseline capture did not emit exactly one bounded canonical failure-set payload.' }
try {
    $encoded = $captureLines[0].Substring('historical_validation_debt_capture_base64='.Length)
    $capture = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Convert]::FromBase64String($encoded)) -Context 'historical-debt baseline capture'
} catch {
    throw "Historical-debt baseline capture payload is invalid: $($_.Exception.Message)"
}
if ($exitCode -eq 0) { throw 'Historical-debt baseline cannot be generated because the complete validator reported no failures.' }
Assert-MorphospaceExactPropertySet -Value $capture -Required @('schema','failure_records') -Context 'Historical-debt baseline capture'
if ([string]$capture.schema -cne 'rusty.morphospace.workflow.historical_validation_debt_capture.v1' -or @($capture.failure_records).Count -eq 0) {
    throw 'Historical-debt baseline capture did not contain a non-empty failure set.'
}
$after = Get-BaselineCaptureCas -Workspace $WorkspaceRoot -RepositoryMap $RepositoryMapPath
if ((Get-MorphospaceCanonicalJsonSha256 -Value $before) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $after)) {
    throw 'Historical-debt baseline capture CAS drifted; no baseline was generated or written.'
}
$baseline = New-MorphospaceHistoricalValidationDebtBaseline `
    -WorkspaceRoot $WorkspaceRoot -RepoRoot $RepoRoot -RepositoryMapPath $RepositoryMapPath `
    -BaselineId $BaselineId -FailureRecords @($capture.failure_records)
$schemaPath = Join-Path $RepoRoot 'schemas/historical-validation-debt-baseline-v1.schema.json'
if (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $baseline) -SchemaFile $schemaPath -ErrorAction Stop)) {
    throw 'Historical-debt baseline builder produced an invalid closed-schema request.'
}
$relativePath = "receipts/historical-validation-debt/$BaselineId/baseline.json"
$plan = [pscustomobject][ordered]@{
    action = 'generate-historical-validation-debt-baseline-request'
    execute = [bool]$Execute
    baseline_path = $relativePath
    baseline_sha256 = $null
    baseline = $baseline
    does_not_prove = @(
        'An unsigned baseline request does not authorize an exemption, validation, acceptance, source mutation, workspace mutation, or publication.',
        'Only a separately installed external-owner authorization signed by the pinned owner key can admit this exact request.'
    )
}
if ($Execute) {
    Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $WorkspaceRoot -RelativePath $relativePath -Value $baseline -NoOverwrite
    $plan.baseline_sha256 = Get-MorphospaceFileSha256 -Path (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $relativePath -RequireLeaf)
}
$plan | ConvertTo-Json -Depth 32
