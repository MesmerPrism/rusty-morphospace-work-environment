[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Readiness', 'Plan', 'StartOperation', 'ObserveOperation', 'Execution', 'Disposition', 'ObserveLanding', 'VerifyLanding', 'ComputeReviewedIntegration')][string]$Action,
    [string]$WorkspaceRoot = '', [string]$UnitId = '', [string]$RepoMapPath = '', [string]$PublicationId = '',
    [ValidateSet('fast-forward', 'provider-merge')][string]$PublicationMode = 'provider-merge',
    [string]$Remote = 'origin', [string]$TargetBranch = 'main', [string]$PlanPath = '', [string]$RepoId = '',
    [string]$OperationStartPath = '', [string]$OperationEvidencePath = '', [string]$ExpectedOperationEvidenceSha256 = '',
    [string[]]$OperationObservationPaths = @(), [string]$Timestamp = '',
    [string]$RequestPath = '', [string]$ExpectedRequestSha256 = '',
    [string]$HumanDecisionPath = '', [string]$ExpectedHumanDecisionSha256 = '',
    [string]$LandingPath = '', [string]$ExpectedLandingSha256 = '',
    [string]$OutPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if($Action -ceq 'ComputeReviewedIntegration'){$WarningPreference='SilentlyContinue'}
Import-Module (Join-Path $PSScriptRoot 'SourceOnlyPublicationInputs.psm1') -Force

switch ($Action) {
    'ComputeReviewedIntegration' {
        New-MorphospaceSourceDeliveryIntegrationComputation -RequestPath $RequestPath -ExpectedRequestSha256 $ExpectedRequestSha256 -WorkspaceRoot $WorkspaceRoot -RepoMapPath $RepoMapPath -OutPath $OutPath | ConvertTo-Json -Depth 8 -Compress
    }
    'Disposition' {
        New-MorphospaceSourceDeliveryDisposition -RequestPath $RequestPath -ExpectedRequestSha256 $ExpectedRequestSha256 -WorkspaceRoot $WorkspaceRoot -RepoMapPath $RepoMapPath -HumanDecisionPath $HumanDecisionPath -ExpectedHumanDecisionSha256 $ExpectedHumanDecisionSha256 -OutPath $OutPath
    }
    'ObserveLanding' {
        New-MorphospaceSourceDeliveryLanding -RequestPath $RequestPath -ExpectedRequestSha256 $ExpectedRequestSha256 -RepoMapPath $RepoMapPath -OutPath $OutPath
    }
    'VerifyLanding' {
        Test-MorphospaceSourceDeliveryLanding -LandingPath $LandingPath -ExpectedLandingSha256 $ExpectedLandingSha256 -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -RepositoryMap $RepoMapPath
    }
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
