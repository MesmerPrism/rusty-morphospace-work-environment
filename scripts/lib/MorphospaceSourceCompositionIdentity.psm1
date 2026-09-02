Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')

function New-MorphospaceSourceCompositionIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Repositories
    )
    return [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.source_composition_identity.v1'
        project_id = $ProjectId
        unit_id = $UnitId
        repositories = @($Repositories)
    }
}

function Get-MorphospaceSourceCompositionFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Repositories
    )
    return Get-MorphospaceCanonicalJsonSha256 -Value (New-MorphospaceSourceCompositionIdentity -ProjectId $ProjectId -UnitId $UnitId -Repositories @($Repositories))
}

Export-ModuleMember -Function New-MorphospaceSourceCompositionIdentity,Get-MorphospaceSourceCompositionFingerprint
