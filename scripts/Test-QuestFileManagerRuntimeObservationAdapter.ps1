param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Import-Module (Join-Path $RepoRoot 'scripts\lib\QuestFileManagerRuntimeObservationAdapter.psm1') -Force
$fixture = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'fixtures\quest-file-manager\runtime-observation-adapter.v1.json') | ConvertFrom-Json -Depth 32

$v6ProcessExpectations = @{
    'minimal-v6-unavailable-families' = @('unavailable', $null, $null, $null, $null)
    'v6-verified-presence-with-empty-pidof' = @('reported', 'pidofReportedNoProcesses', 1, $true, 'verifiedPresent')
    'v6-inconclusive-is-not-absence' = @('reported', 'pidofReportedNoProcesses', 1, $null, 'inconclusive')
    'v6-pidof-presence' = @('reported', 'pidofReportedProcesses', 0, $true, 'notCollected')
    'v6-conflicting-corroboration' = @('reported', 'pidofReportedNoProcesses', 1, $null, 'conflicting')
    'v6-unavailable-sources' = @('reported', 'pidofUnavailable', 1, $null, 'unavailable')
    'v6-multiple-malformed-focus' = @('unavailable', $null, $null, $null, $null)
    'v6-unknown-truncated-focus' = @('unavailable', $null, $null, $null, $null)
}

function Assert-UnknownReadiness {
    param([object]$Adapted, [string]$CaseId)
    $evidence = $Adapted.fact_families.application_evidence
    if ($evidence.status -cne 'unknown' -or $evidence.application_readiness -cne 'unknown' -or
        $evidence.openxr_readiness -cne 'unknown' -or $evidence.application_readiness_authority -ne $false -or
        $evidence.openxr_readiness_authority -ne $false -or @($evidence.app_receipts).Count -ne 0) {
        throw "Runtime adapter invented application evidence for $CaseId."
    }
}

foreach ($case in @($fixture.cases)) {
    $observation = if ($null -ne $case.PSObject.Properties['observation']) { $case.observation } else { @($case.frames)[-1] }
    $adapted = Convert-QfmRuntimeObservation -Observation $observation
    if ($adapted.status -ne 'supported' -or $adapted.fact_families.application_evidence.application_readiness -ne 'unknown' -or $adapted.fact_families.application_evidence.openxr_readiness -ne 'unknown') {
        throw "Runtime adapter failed the fact-only boundary for $($case.id)."
    }
    Assert-UnknownReadiness $adapted $case.id
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
    if ($v6ProcessExpectations.ContainsKey($case.id)) {
        $want = $v6ProcessExpectations[$case.id]
        $process = $adapted.fact_families.process
        if ($adapted.adapter -cne 'current-v6' -or $process.status -cne $want[0] -or
            $process.quality -cne $want[1] -or $process.observation_exit_code -cne $want[2] -or
            $process.alive -cne $want[3]) {
            throw "Runtime v6 process projection lost native facts for $($case.id)."
        }
        if ($null -eq $want[4]) {
            if ($null -ne $process.corroboration) { throw "Runtime v6 fabricated corroboration for $($case.id)." }
        } elseif ($process.corroboration.State -cne $want[4] -or $process.corroboration.AbsenceAuthority -ne $false) {
            throw "Runtime v6 changed corroboration or its absence boundary for $($case.id)."
        }
        # Compare the independently declared native objects to the projection:
        # source counts, ordering, ambiguity, truncation and exit codes must survive.
        foreach ($pair in @(@('ProcessCorroboration', 'corroboration'), @('GlobalFocus', 'global_focus'), @('CurrentFocus', 'current_focus'), @('FocusedApp', 'focused_app'))) {
            $property = $observation.PSObject.Properties[$pair[0]]
            if ($null -eq $property) { continue }
            $actual = if ($pair[1] -eq 'corroboration') { $process.corroboration } else { $adapted.fact_families.global_android_focus.($pair[1]) }
            if (($actual | ConvertTo-Json -Depth 16 -Compress) -cne ($property.Value | ConvertTo-Json -Depth 16 -Compress)) {
                throw "Runtime v6 changed the native $($pair[0]) observation for $($case.id)."
            }
        }
        if ($null -ne $observation.PSObject.Properties['GlobalFocus'] -and
            $adapted.fact_families.global_android_focus.contract -cne 'questionable.file_manager.android_global_focus_observation.v1') {
            throw "Runtime v6 did not identify the global-focus v1 fact family for $($case.id)."
        }
    }
    if ($case.id -eq 'v6-verified-presence-with-empty-pidof' -and
        (@($adapted.fact_families.process.process_ids).Count -ne 0 -or
        $adapted.fact_families.process.corroboration.ProcessId -ne 17527 -or
        $adapted.fact_families.process.corroboration.StartTicks -ne 123 -or
        $adapted.fact_families.process.corroboration.CurrentUserUid -ne 10177 -or
        $adapted.fact_families.task_top_resumed.is_foreground -ne $false)) {
        throw 'Runtime v6 merged independent pidof, corroboration or foreground facts.'
    }
    if ($case.id -eq 'minimal-v6-unavailable-families' -and
        ($adapted.fact_families.task_top_resumed.status -cne 'unavailable' -or
        $adapted.fact_families.global_android_focus.status -cne 'unavailable')) {
        throw 'Incomplete v6 observations fabricated task or focus facts.'
    }
}

foreach ($observation in @(
    [pscustomobject]@{ ObservationContract = 'questionable.file_manager.app_runtime_observation.v99'; ProcessAlive = $true },
    [pscustomobject]@{},
    [pscustomobject]@{ ObservationContract = @('questionable.file_manager.app_runtime_observation.v6', 'unexpected') },
    [pscustomobject]@{ ObservationContract = @('questionable.file_manager.app_runtime_observation.v6') }
)) {
    $unknown = Convert-QfmRuntimeObservation -Observation $observation
    if ($unknown.status -cne 'unknown' -or $unknown.adapter -cne 'unknown') { throw 'Unknown or malformed runtime contract was not explicit.' }
    Assert-UnknownReadiness $unknown 'unknown-contract'
}

# A partial v6 payload may contain corroboration or an exit code without pidof
# fields. Report it without deriving presence, absence or readiness.
foreach ($partial in @(
    [pscustomobject]@{ ProcessObservationExitCode = 1 },
    [pscustomobject]@{ ProcessAlive = $true },
    [pscustomobject]@{ ProcessCorroboration = [pscustomobject]@{ State = 'futureState'; AbsenceAuthority = $false } },
    [pscustomobject]@{ ProcessCorroboration = [pscustomobject]@{ State = 'verifiedPresent'; ProcessId = 17527; StartTicks = 123; CurrentUserUid = 10177; AbsenceAuthority = $false } }
)) {
    $partial | Add-Member -NotePropertyName ObservationContract -NotePropertyValue 'questionable.file_manager.app_runtime_observation.v6'
    $adapted = Convert-QfmRuntimeObservation -Observation $partial
    if ($adapted.fact_families.process.status -cne 'reported') { throw 'Partial v6 process facts were lost.' }
    if ($null -eq $partial.PSObject.Properties['ProcessAlive'] -and $null -ne $adapted.fact_families.process.alive) { throw 'Partial v6 facts were used to recompute native liveness.' }
    if ($null -ne $partial.PSObject.Properties['ProcessCorroboration'] -and
        $adapted.fact_families.process.corroboration.State -cne $partial.ProcessCorroboration.State) { throw 'Partial v6 corroboration states were reinterpreted.' }
    Assert-UnknownReadiness $adapted 'partial-v6'
}
Write-Host 'Quest File Manager runtime observation adapters passed.'
