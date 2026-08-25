param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Import-Module (Join-Path $RepoRoot 'scripts\lib\QuestFileManagerPermissionObservationAdapter.psm1') -Force
$fixture = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'fixtures\quest-file-manager\permission-observation-adapter.v1.json') | ConvertFrom-Json -Depth 32

foreach ($case in @($fixture.cases)) {
    $adapted = Convert-QfmPermissionObservation -Envelope $case.envelope
    if ($adapted.status -ne 'supported' -or
        $adapted.fact_families.application_evidence.permission_policy -ne 'unknown' -or
        $adapted.fact_families.application_evidence.feature_use -ne 'unknown' -or
        $adapted.fact_families.application_evidence.application_readiness -ne 'unknown' -or
        $adapted.fact_families.application_evidence.openxr_readiness -ne 'unknown') {
        throw "Permission adapter crossed the fact-only boundary for $($case.id)."
    }
    if ($case.id -eq 'reported-grant-and-denied-app-op' -and
        ($adapted.fact_families.effective_grants.source_state -ne 'reported' -or
            $adapted.fact_families.app_ops.values[0].Mode -ne 'deny')) {
        throw 'Permission adapter did not preserve reported grant and app-op facts.'
    }
    if ($case.id -eq 'failed-envelope-with-result-is-rejected' -and
        ($adapted.envelope_status -ne 'failed' -or
            $adapted.fact_families.package_identity.status -ne 'unavailable' -or
            @($adapted.fact_families.effective_grants.values).Count -ne 0 -or
            $adapted.fact_families.provider_identity.status -ne 'unavailable')) {
        throw 'Permission adapter did not retain the failed observation as non-semantic evidence.'
    }
}

$unknown = Convert-QfmPermissionObservation -Envelope ([pscustomobject]@{ schema = 'questionable.file_manager.apk_permission_observation.v99' })
if ($unknown.status -ne 'unknown' -or $unknown.fact_families.application_evidence.permission_policy -ne 'unknown') {
    throw 'Unknown permission-observation contract was not explicit.'
}
Write-Host 'Quest File Manager permission observation adapters passed.'
