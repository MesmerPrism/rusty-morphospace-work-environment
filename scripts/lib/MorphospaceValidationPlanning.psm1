Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function New-MorphospaceValidationMatrix {
    param(
        [Parameter(Mandatory = $true)][object]$Unit,
        [string[]]$DeviceSerials = @()
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $order = 0
    foreach ($validation in @($Unit.validation)) {
        $order++
        $rows.Add([pscustomobject][ordered]@{
            order = $order; gate_id = "validation-$([string]$validation.profile_id)"
            kind = "command"; profile_id = [string]$validation.profile_id
            command = [string]$validation.command; disposition = "required"
        }) | Out-Null
    }
    if ([string]$Unit.instruction_impact -ne "none") {
        $order++
        $rows.Add([pscustomobject][ordered]@{
            order = $order; gate_id = "instruction-synchronization"; kind = "instruction"
            profile_id = "instruction-sync"; command = "Verify every declared instruction surface is complete and validated."
            disposition = "required"
        }) | Out-Null
    }
    $deviceRequirement = [string]$Unit.device_requirement
    if ($deviceRequirement -eq "forbidden") {
        $order++
        $rows.Add([pscustomobject][ordered]@{
            order = $order; gate_id = "device-validation"; kind = "device"
            profile_id = "device"; command = "Do not run live device operations for this unit."
            disposition = "forbidden"; serials = @()
        }) | Out-Null
    } elseif ($deviceRequirement -ne "none") {
        $order++
        $disposition = if ($DeviceSerials.Count -gt 0) { "serial-scoped-plan-required" } elseif ($deviceRequirement -eq "required") { "blocked-missing-serials" } else { "optional-not-selected" }
        $rows.Add([pscustomobject][ordered]@{
            order = $order; gate_id = "device-validation"; kind = "device"
            profile_id = "device"; command = "Use the device workflow with only the explicitly supplied serials."
            disposition = $disposition; serials = @($DeviceSerials | Sort-Object -Unique)
        }) | Out-Null
    }
    return @($rows.ToArray())
}

Export-ModuleMember -Function New-MorphospaceValidationMatrix
