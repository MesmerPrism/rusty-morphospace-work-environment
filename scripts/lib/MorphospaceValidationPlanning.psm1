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

function Assert-MorphospaceValidationMatrixProducerParity {
    param([Parameter(Mandatory)][string]$ExecutorRoot,[Parameter(Mandatory)][string]$AuthoritativeModulePath,[string]$ExpectedExtractedMatrixSha256='',[bool]$OriginalContextBound=$false)
    $tokens=$null;$errors=$null
    $producerAst=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($ExecutorRoot,'scripts/WorkUnitAutomation.psm1'),[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw 'Frozen continuation validation matrix producer is not parseable.'}
    $matrixFunctions=@($producerAst.FindAll({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'New-MorphospaceValidationMatrix'},$true))
    if($matrixFunctions.Count-eq0){
        $imports=@($producerAst.FindAll({param($node) $node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Import-Module'-and$node.Extent.Text.Replace("`r`n","`n")-ceq'Import-Module (Join-Path $PSScriptRoot ''lib/MorphospaceValidationPlanning.psm1'')'},$true))
        if($imports.Count-ne1){throw 'Frozen continuation extracted validation matrix import is detached.'}
        $matrixPath=[IO.Path]::Combine($ExecutorRoot,'scripts/lib/MorphospaceValidationPlanning.psm1')
        if($OriginalContextBound-and[string]::IsNullOrEmpty($ExpectedExtractedMatrixSha256)){throw 'Frozen continuation extracted validation matrix bytes are outside the original closure.'}
        if($ExpectedExtractedMatrixSha256-and-not[string]::Equals([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($matrixPath))).ToLowerInvariant(),$ExpectedExtractedMatrixSha256,[StringComparison]::Ordinal)){throw 'Frozen continuation extracted validation matrix bytes are outside the original closure.'}
        $producerAst=[Management.Automation.Language.Parser]::ParseFile($matrixPath,[ref]$tokens,[ref]$errors)
        if(@($errors).Count){throw 'Frozen continuation extracted validation matrix is not parseable.'}
        $matrixFunctions=@($producerAst.FindAll({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'New-MorphospaceValidationMatrix'},$true))
    }
    $authoritativeAst=[Management.Automation.Language.Parser]::ParseFile($AuthoritativeModulePath,[ref]$tokens,[ref]$errors)
    $authoritativeFunctions=@($authoritativeAst.FindAll({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'New-MorphospaceValidationMatrix'},$true))
    if(@($errors).Count-or$matrixFunctions.Count-ne1-or$authoritativeFunctions.Count-ne1-or-not[string]::Equals($matrixFunctions[0].Extent.Text.Replace("`r`n","`n"),$authoritativeFunctions[0].Extent.Text.Replace("`r`n","`n"),[StringComparison]::Ordinal)){throw 'Frozen continuation original validation matrix semantics differ from the shared producer.'}
}

Export-ModuleMember -Function New-MorphospaceValidationMatrix,Assert-MorphospaceValidationMatrixProducerParity
