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

function Get-MorphospacePreparationSourceCompositionFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Composition)
    Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
    if ([string]$Composition.schema -cnotin @(
        'rusty.morphospace.workflow.development_envelope_source_composition.v1',
        'rusty.morphospace.workflow.development_envelope_source_composition.v2',
        'rusty.morphospace.workflow.development_envelope_source_composition.v3'
    )) { throw 'Preparation source identity uses an unsupported schema.' }
    $identity=[ordered]@{project_id=[string]$Composition.project_id;preparation_id=[string]$Composition.preparation_id;repositories=@($Composition.repositories)}
    if ([string]$Composition.schema -ceq 'rusty.morphospace.workflow.development_envelope_source_composition.v3') {
        $identity.tooling_protocol=$Composition.tooling_protocol
    }
    Get-MorphospaceCanonicalJsonSha256 $identity
}

function Get-MorphospaceSourceCompositionRepositoryPins {
    <# Return the immutable product baselines used by Freeze and retirement.
       An active extension's observed effective HEAD is not a new baseline and
       cannot erase changes made earlier in the same active unit. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Composition)
    if ([string]$Composition.schema -ceq 'rusty.morphospace.workflow.active_development_envelope_source_composition.v1') {
        foreach ($row in @($Composition.repositories)) {
            if ([string]$row.baseline_commit -cnotmatch '^[0-9a-f]{40}$' -or [string]$row.baseline_tree -cnotmatch '^[0-9a-f]{40}$') { throw 'Active envelope source baseline is malformed.' }
            [pscustomobject]@{repo_id=[string]$row.repo_id;role=[string]$row.role;commit=[string]$row.baseline_commit;tree=[string]$row.baseline_tree;branch=$row.branch;materialization_path=[string]$row.materialization_path}
        }
    } elseif ([string]$Composition.schema -cin @(
        'rusty.morphospace.workflow.source_composition_lock.v1',
        'rusty.morphospace.workflow.development_envelope_source_composition.v1',
        'rusty.morphospace.workflow.development_envelope_source_composition.v2',
        'rusty.morphospace.workflow.development_envelope_source_composition.v3'
    )) { @($Composition.repositories) }
    else { throw 'Source baseline projection uses an unsupported schema.' }
}

Export-ModuleMember -Function New-MorphospaceSourceCompositionIdentity,Get-MorphospaceSourceCompositionFingerprint,Get-MorphospacePreparationSourceCompositionFingerprint,Get-MorphospaceSourceCompositionRepositoryPins
