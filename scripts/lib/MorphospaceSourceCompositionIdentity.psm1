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
    # Callers can load this small identity module beside larger workflow
    # modules that refresh ProtocolCommon in their own scopes. Re-import the
    # exact static dependency into this module scope before resolving the
    # canonical serializer so the fingerprint never depends on ambient module
    # load order.
    Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
    return Get-MorphospaceCanonicalJsonSha256 -Value (New-MorphospaceSourceCompositionIdentity -ProjectId $ProjectId -UnitId $UnitId -Repositories @($Repositories))
}

Export-ModuleMember -Function New-MorphospaceSourceCompositionIdentity,Get-MorphospaceSourceCompositionFingerprint
