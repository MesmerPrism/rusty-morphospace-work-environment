Set-StrictMode -Version Latest

function Get-QfmProperty {
    param([object]$Value, [string]$Name)

    if ($null -eq $Value) { return $null }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-QfmPropertyPresent {
    param([object]$Value, [string[]]$Names)

    if ($null -eq $Value) { return $false }
    foreach ($name in $Names) {
        $property = $Value.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $true }
    }
    return $false
}

function Get-QfmObservationContract {
    param([object]$Observation)

    if ($null -eq $Observation) { return '' }
    foreach ($name in @('ObservationContract', 'observationContract', 'schema')) {
        $property = $Observation.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) { continue }
        # Inspect before pipeline enumeration: a one-element JSON array is
        # malformed, not a supported scalar contract identifier.
        if ($property.Value -isnot [string]) { return '' }
        return $property.Value
    }
    return ''
}

function Convert-QfmRuntimeObservation {
    [OutputType([pscustomobject])]
    param([object]$Observation)

    $contract = Get-QfmObservationContract -Observation $Observation
    $adapter = switch ($contract) {
        'questionable.file_manager.app_runtime_observation.v3' { 'legacy-v3'; break }
        'questionable.file_manager.app_runtime_observation.v4' { 'legacy-v4'; break }
        'questionable.file_manager.app_runtime_observation.v5' { 'current-v5'; break }
        'questionable.file_manager.app_runtime_observation.v6' { 'current-v6'; break }
        default { 'unknown'; break }
    }
    $isSupported = $adapter -ne 'unknown'
    $processIds = @(Get-QfmProperty -Value $Observation -Name 'ProcessIds')
    if ($processIds.Count -eq 0) { $processIds = @(Get-QfmProperty -Value $Observation -Name 'processIds') }
    $topResumedComponents = @(Get-QfmProperty -Value $Observation -Name 'TopResumedComponents')
    if ($topResumedComponents.Count -eq 0) { $topResumedComponents = @(Get-QfmProperty -Value $Observation -Name 'topResumedComponents') }
    $foregroundComponents = @(Get-QfmProperty -Value $Observation -Name 'ForegroundComponents')
    if ($foregroundComponents.Count -eq 0) { $foregroundComponents = @(Get-QfmProperty -Value $Observation -Name 'foregroundComponents') }
    $currentFocus = Get-QfmProperty -Value $Observation -Name 'CurrentFocus'
    if ($null -eq $currentFocus) { $currentFocus = Get-QfmProperty -Value $Observation -Name 'currentFocus' }
    $focusedApp = Get-QfmProperty -Value $Observation -Name 'FocusedApp'
    if ($null -eq $focusedApp) { $focusedApp = Get-QfmProperty -Value $Observation -Name 'focusedApp' }
    $globalFocus = Get-QfmProperty -Value $Observation -Name 'GlobalFocus'
    if ($null -eq $globalFocus) { $globalFocus = Get-QfmProperty -Value $Observation -Name 'globalFocus' }
    $processReported = Test-QfmPropertyPresent -Value $Observation -Names @('ProcessIds', 'processIds', 'ProcessObservationQuality', 'processObservationQuality', 'ProcessObservationSource', 'processObservationSource', 'ProcessObservationExitCode', 'ProcessCorroboration', 'ProcessAlive')
    $taskReported = Test-QfmPropertyPresent -Value $Observation -Names @('IsForeground', 'isForeground', 'IsTopResumed', 'isTopResumed', 'ForegroundComponents', 'foregroundComponents', 'TopResumedComponents', 'topResumedComponents')
    $installed = Get-QfmProperty -Value $Observation -Name 'Installed'
    if ($null -eq $installed) { $installed = Get-QfmProperty -Value $Observation -Name 'installed' }

    [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.qfm_runtime_observation_adapter.v1'
        input_contract = if ($contract) { $contract } else { 'unavailable' }
        adapter = $adapter
        status = if ($isSupported) { 'supported' } else { 'unknown' }
        fact_families = [pscustomobject][ordered]@{
            installed_identity = [pscustomobject]@{
                status = if ($null -ne $installed) { 'reported' } else { 'unavailable' }
                value = $installed
            }
            process = [pscustomobject]@{
                status = if ($processReported) { 'reported' } else { 'unavailable' }
                process_ids = @($processIds)
                quality = (Get-QfmProperty -Value $Observation -Name 'ProcessObservationQuality')
                source = (Get-QfmProperty -Value $Observation -Name 'ProcessObservationSource')
                observation_exit_code = Get-QfmProperty -Value $Observation -Name 'ProcessObservationExitCode'
                # Preserve the native presence-only corroboration and nullable
                # liveness separately from pidof; never compute absence/readiness.
                corroboration = Get-QfmProperty -Value $Observation -Name 'ProcessCorroboration'
                alive = Get-QfmProperty -Value $Observation -Name 'ProcessAlive'
            }
            task_top_resumed = [pscustomobject]@{
                status = if ($taskReported) { 'reported' } else { 'unavailable' }
                is_foreground = Get-QfmProperty -Value $Observation -Name 'IsForeground'
                is_top_resumed = Get-QfmProperty -Value $Observation -Name 'IsTopResumed'
                foreground_components = @($foregroundComponents)
                top_resumed_components = @($topResumedComponents)
            }
            global_android_focus = [pscustomobject]@{
                status = if ($adapter -eq 'legacy-v3') { 'unavailable' } elseif ($null -eq $globalFocus -and $null -eq $currentFocus -and $null -eq $focusedApp) { 'unavailable' } else { 'reported' }
                contract = if ($adapter -in @('current-v5', 'current-v6')) { 'questionable.file_manager.android_global_focus_observation.v1' } elseif ($adapter -eq 'legacy-v4') { 'legacy-v4-projection' } else { 'unavailable' }
                current_focus = $currentFocus
                focused_app = $focusedApp
                global_focus = $globalFocus
            }
            application_evidence = [pscustomobject]@{
                status = 'unknown'
                application_readiness = 'unknown'
                application_readiness_authority = $false
                openxr_readiness = 'unknown'
                openxr_readiness_authority = $false
                app_receipts = @()
            }
        }
    }
}

Export-ModuleMember -Function Convert-QfmRuntimeObservation
