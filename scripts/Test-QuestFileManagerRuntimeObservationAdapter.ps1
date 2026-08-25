param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Import-Module (Join-Path $RepoRoot 'scripts\lib\QuestFileManagerRuntimeObservationAdapter.psm1') -Force
$fixture = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'fixtures\quest-file-manager\runtime-observation-adapter.v1.json') | ConvertFrom-Json -Depth 32

foreach ($case in @($fixture.cases)) {
    $observation = if ($null -ne $case.PSObject.Properties['observation']) { $case.observation } else { @($case.frames)[-1] }
    $adapted = Convert-QfmRuntimeObservation -Observation $observation
    if ($adapted.status -ne 'supported' -or $adapted.fact_families.application_evidence.application_readiness -ne 'unknown' -or $adapted.fact_families.application_evidence.openxr_readiness -ne 'unknown') {
        throw "Runtime adapter failed the fact-only boundary for $($case.id)."
    }
    if ($case.id -eq 'focus-placeholder-after-brief-app-focus') {
        $focus = @($adapted.fact_families.global_android_focus.global_focus.CurrentFocus.Components)
        if ($focus -notcontains 'com.oculus.vrshell/com.oculus.vrshell.FocusPlaceholderActivity' -or $adapted.adapter -ne 'current-v5') {
            throw 'FocusPlaceholder fixture did not preserve the stable global Android foreground fact.'
        }
    }
    if ($case.id -eq 'minimal-v5-unavailable-families' -and
        ($adapted.fact_families.process.status -ne 'unavailable' -or $adapted.fact_families.task_top_resumed.status -ne 'unavailable')) {
        throw 'Incomplete v5 observations fabricated process or task facts.'
    }
}

$unknown = Convert-QfmRuntimeObservation -Observation ([pscustomobject]@{ ObservationContract = 'questionable.file_manager.app_runtime_observation.v99' })
if ($unknown.status -ne 'unknown' -or $unknown.fact_families.application_evidence.application_readiness -ne 'unknown') { throw 'Unknown runtime contract was not explicit.' }
Write-Host 'Quest File Manager runtime observation adapters passed.'
