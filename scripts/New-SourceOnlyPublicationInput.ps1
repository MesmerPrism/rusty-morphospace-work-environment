[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Readiness', 'Plan', 'StartOperation', 'ObserveOperation', 'Execution')][string]$Action,
    [string]$WorkspaceRoot = '', [string]$UnitId = '', [string]$RepoMapPath = '', [string]$PublicationId = '',
    [ValidateSet('fast-forward', 'provider-merge')][string]$PublicationMode = 'provider-merge',
    [string]$Remote = 'origin', [string]$TargetBranch = 'main', [string]$PlanPath = '', [string]$RepoId = '',
    [string]$OperationStartPath = '', [string]$OperationEvidencePath = '', [string]$ExpectedOperationEvidenceSha256 = '',
    [string[]]$OperationObservationPaths = @(), [string]$Timestamp = '',
    [Parameter(Mandatory = $true)][string]$OutPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SourceOnlyPublicationInputs.psm1') -Force

switch ($Action) {
    'Readiness' {
        Get-MorphospaceSourceOnlyPublicationReadiness -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -RepoMapPath $RepoMapPath -PublicationId $PublicationId -PublicationMode $PublicationMode -Remote $Remote -TargetBranch $TargetBranch -OutPath $OutPath
    }
    'Plan' {
        New-MorphospaceSourceOnlyPublicationPlan -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -RepoMapPath $RepoMapPath -PublicationId $PublicationId -PublicationMode $PublicationMode -Remote $Remote -TargetBranch $TargetBranch -OutPath $OutPath
    }
    'StartOperation' {
        Start-MorphospaceSourceOnlyPublicationOperation -PlanPath $PlanPath -RepoId $RepoId -Timestamp $Timestamp -OutPath $OutPath
    }
    'ObserveOperation' {
        Complete-MorphospaceSourceOnlyPublicationOperationObservation -PlanPath $PlanPath -OperationStartPath $OperationStartPath -OperationEvidencePath $OperationEvidencePath -ExpectedOperationEvidenceSha256 $ExpectedOperationEvidenceSha256 -RepoMapPath $RepoMapPath -Timestamp $Timestamp -OutPath $OutPath
    }
    'Execution' {
        New-MorphospaceSourceOnlyPublicationExecution -PlanPath $PlanPath -OperationObservationPaths $OperationObservationPaths -RepoMapPath $RepoMapPath -OutPath $OutPath
    }
}
