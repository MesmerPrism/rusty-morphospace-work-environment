Set-StrictMode -Version Latest

function Get-QfmPermissionProperty {
    param([object]$Value, [string[]]$Names)

    if ($null -eq $Value) { return $null }
    foreach ($name in $Names) {
        $property = $Value.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Get-QfmPermissionFact {
    param(
        [object]$Result,
        [string[]]$StateNames,
        [string[]]$ValueNames
    )

    $state = Get-QfmPermissionProperty -Value $Result -Names $StateNames
    $rawValues = Get-QfmPermissionProperty -Value $Result -Names $ValueNames
    $values = if ($null -eq $rawValues) { @() } else { @($rawValues) }
    [pscustomobject][ordered]@{
        status = if ($null -eq $state) { 'unavailable' } else { 'reported' }
        source_state = if ($null -eq $state) { 'unavailable' } else { [string]$state }
        values = $values
    }
}

function Convert-QfmPermissionObservation {
    [OutputType([pscustomobject])]
    param([object]$Envelope)

    $contract = [string](Get-QfmPermissionProperty -Value $Envelope -Names @('schema', 'Schema'))
    $isSupported = $contract -ceq 'questionable.file_manager.apk_permission_observation.v1'
    $succeeded = Get-QfmPermissionProperty -Value $Envelope -Names @('succeeded', 'Succeeded')
    $candidateResult = Get-QfmPermissionProperty -Value $Envelope -Names @('result', 'Result')
    $hasReportedResult = $isSupported -and $succeeded -eq $true -and $null -ne $candidateResult
    $result = if ($hasReportedResult) { $candidateResult } else { $null }
    $provider = Get-QfmPermissionProperty -Value $result -Names @('Provider', 'provider')
    $packageName = Get-QfmPermissionProperty -Value $result -Names @('PackageName', 'packageName')

    [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.qfm_permission_observation_adapter.v1'
        input_contract = if ($contract) { $contract } else { 'unavailable' }
        adapter = if ($isSupported) { 'current-v1' } else { 'unknown' }
        status = if ($isSupported) { 'supported' } else { 'unknown' }
        envelope_status = if (-not $isSupported) { 'unavailable' } elseif ($hasReportedResult) { 'reported' } elseif ($succeeded -eq $false) { 'failed' } else { 'unavailable' }
        fact_families = [pscustomobject][ordered]@{
            package_identity = [pscustomobject][ordered]@{
                status = if ($null -eq $result) { 'unavailable' } else { 'reported' }
                package_name = $packageName
                source_state = Get-QfmPermissionProperty -Value $result -Names @('PackageState', 'packageState')
            }
            manifest_declarations = Get-QfmPermissionFact -Result $result -StateNames @('ManifestDeclaredPermissionsState', 'manifestDeclaredPermissionsState') -ValueNames @('ManifestDeclaredPermissions', 'manifestDeclaredPermissions')
            effective_grants = Get-QfmPermissionFact -Result $result -StateNames @('EffectiveGrantState', 'effectiveGrantState') -ValueNames @('EffectiveGrants', 'effectiveGrants')
            app_ops = Get-QfmPermissionFact -Result $result -StateNames @('AppOpState', 'appOpState') -ValueNames @('AppOps', 'appOps')
            provider_identity = [pscustomobject][ordered]@{
                status = if ($null -eq $provider) { 'unavailable' } else { 'reported' }
                id = Get-QfmPermissionProperty -Value $provider -Names @('Id', 'id')
                version = Get-QfmPermissionProperty -Value $provider -Names @('Version', 'version')
                source_repository = Get-QfmPermissionProperty -Value $provider -Names @('SourceRepository', 'sourceRepository')
                distribution = Get-QfmPermissionProperty -Value $provider -Names @('Distribution', 'distribution')
            }
            application_evidence = [pscustomobject][ordered]@{
                status = 'unknown'
                permission_policy = 'unknown'
                permission_policy_authority = $false
                feature_use = 'unknown'
                application_readiness = 'unknown'
                application_readiness_authority = $false
                openxr_readiness = 'unknown'
                openxr_readiness_authority = $false
            }
        }
    }
}

Export-ModuleMember -Function Convert-QfmPermissionObservation
