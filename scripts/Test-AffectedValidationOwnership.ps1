[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$SelfTest
)

Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$modulePath = Join-Path $root 'scripts/lib/MorphospaceAffectedValidation.psm1'
$registryPath = Join-Path $root 'manifests/affected-validation-registry.json'
$schemaPath = Join-Path $root 'schemas/affected-validation-registry-v1.schema.json'

Import-Module $modulePath -Force
$registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json -Depth 100
$compiled = Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $root -SchemaPath $schemaPath
$head = (& git -C $root rev-parse 'HEAD^{commit}').Trim()
if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[0-9a-f]{40}$') { throw 'Affected-validation ownership audit could not resolve exact HEAD.' }
$inventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $root -Commit $head
$audit = Get-MorphospaceAffectedValidationOwnershipAudit -Registry $registry -CompiledRegistry $compiled -Inventory $inventory
Assert-MorphospaceAffectedValidationOwnershipComplete -Audit $audit
$aggregateAudit = Assert-MorphospaceAffectedWorkEnvironmentLeafRegistration -Root $root -Registry $registry -Inventory $inventory

if ($SelfTest) {
    function Copy-OwnershipValue([object]$Value) {
        return (($Value | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -Depth 100)
    }
    function Assert-OwnershipFailure([scriptblock]$Action,[string]$Pattern,[string]$Context) {
        $failed = $false
        try { & $Action } catch { $failed = [string]$_.Exception.Message -like $Pattern }
        if (-not $failed) { throw $Context }
    }

    $missingRegistry = Copy-OwnershipValue $registry
    $ownerSet = @($missingRegistry.path_sets | Where-Object { @($_.patterns) -ccontains 'scripts/Test-AffectedValidationOwnership.ps1' })
    if ($ownerSet.Count -ne 1) { throw 'Ownership self-test command does not have one exact path-set fixture.' }
    $ownerSet[0].patterns = @($ownerSet[0].patterns | Where-Object { [string]$_ -cne 'scripts/Test-AffectedValidationOwnership.ps1' })
    $missingCompiled = Test-MorphospaceAffectedValidationRegistry -Registry $missingRegistry -RepositoryRoot $root -SchemaPath $schemaPath
    $missingAudit = Get-MorphospaceAffectedValidationOwnershipAudit -Registry $missingRegistry -CompiledRegistry $missingCompiled -Inventory $inventory
    Assert-OwnershipFailure { Assert-MorphospaceAffectedValidationOwnershipComplete -Audit $missingAudit } '*unmapped=1*registered_commands_without_one_owner=1*' 'Ownership audit accepted a removed command owner.'

    $overlapRegistry = Copy-OwnershipValue $registry
    $overlapRegistry.path_sets = @($overlapRegistry.path_sets) + @([pscustomobject][ordered]@{
        path_set_id = 'ownership-damage-overlap'
        patterns = @('scripts/Test-AffectedValidationOwnership.ps1')
    })
    foreach ($check in @($overlapRegistry.checks | Where-Object { [string]$_.check_id -in @('affected-validation-ownership','public-boundary') })) {
        $check.trigger_path_sets = @($check.trigger_path_sets) + @('ownership-damage-overlap')
        $check.consume_path_sets = @($check.consume_path_sets) + @('ownership-damage-overlap')
    }
    $overlapCompiled = Test-MorphospaceAffectedValidationRegistry -Registry $overlapRegistry -RepositoryRoot $root -SchemaPath $schemaPath
    $overlapAudit = Get-MorphospaceAffectedValidationOwnershipAudit -Registry $overlapRegistry -CompiledRegistry $overlapCompiled -Inventory $inventory
    Assert-OwnershipFailure { Assert-MorphospaceAffectedValidationOwnershipComplete -Audit $overlapAudit } '*ambiguous=1*registered_commands_without_one_owner=1*' 'Ownership audit accepted an overlapping command owner.'

    $missingAggregateRegistry = Copy-OwnershipValue $registry
    $missingAggregateRegistry.checks = @($missingAggregateRegistry.checks | Where-Object { [string]$_.check_id -cne 'external-owner-authorization' })
    Assert-OwnershipFailure {
        Assert-MorphospaceAffectedWorkEnvironmentLeafRegistration -Root $root -Registry $missingAggregateRegistry -Inventory $inventory
    } '*aggregate owner-entrypoint registration debt changed*' 'Ownership audit accepted a missing aggregate owner registration.'

    $argumentDriftRegistry = Copy-OwnershipValue $registry
    $powerShellHost = @($argumentDriftRegistry.checks | Where-Object { [string]$_.check_id -ceq 'powershell-host' })
    if ($powerShellHost.Count -ne 1) { throw 'Ownership self-test could not resolve the PowerShell host leaf.' }
    $powerShellHost[0].arguments = @('-Quiet')
    Assert-OwnershipFailure {
        Assert-MorphospaceAffectedWorkEnvironmentLeafRegistration -Root $root -Registry $argumentDriftRegistry -Inventory $inventory
    } '*aggregate invocation differs from its focused registration*' 'Ownership audit accepted the ambient PowerShell preflight as the gating self-test.'
}

Write-Host "Affected-validation ownership is complete: tracked=$($audit.tracked_path_count) aggregate_owners=$($aggregateAudit.owner_entrypoint_count) digest=$($audit.ownership_sha256)."
