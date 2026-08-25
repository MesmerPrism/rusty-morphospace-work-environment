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

    $contract = Get-QfmProperty -Value $Observation -Name 'ObservationContract'
    if ($null -eq $contract) { $contract = Get-QfmProperty -Value $Observation -Name 'observationContract' }
    if ($null -eq $contract) { $contract = Get-QfmProperty -Value $Observation -Name 'schema' }
    return [string]$contract
}

function Convert-QfmRuntimeObservation {
    [OutputType([pscustomobject])]
    param([object]$Observation)

    $contract = Get-QfmObservationContract -Observation $Observation
    $adapter = switch ($contract) {
        'questionable.file_manager.app_runtime_observation.v3' { 'legacy-v3'; break }
        'questionable.file_manager.app_runtime_observation.v4' { 'legacy-v4'; break }
        'questionable.file_manager.app_runtime_observation.v5' { 'current-v5'; break }
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
    $processReported = Test-QfmPropertyPresent -Value $Observation -Names @('ProcessIds', 'processIds', 'ProcessObservationQuality', 'processObservationQuality', 'ProcessObservationSource', 'processObservationSource')
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
                contract = if ($adapter -eq 'current-v5') { 'questionable.file_manager.android_global_focus_observation.v1' } elseif ($adapter -eq 'legacy-v4') { 'legacy-v4-projection' } else { 'unavailable' }
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
