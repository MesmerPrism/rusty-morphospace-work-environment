param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force
$protocolModule = Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force -PassThru
$repreparationModule = Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeRepreparation.psm1') -Force -PassThru
$transitionLedgerPath = Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1'
$transitionLedgerModule = @(Get-Module -All | Where-Object { $_.Path -eq $transitionLedgerPath } | Select-Object -Last 1)[0]
if ($null -eq $transitionLedgerModule) { throw 'MorphospaceTransitionLedger module is unavailable.' }

. (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')
. (Join-Path $PSScriptRoot 'test-support/RecoveredProposalContinuation.ps1')

$tempParent = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
$tempParentItem = Get-Item -LiteralPath $tempParent -Force
if (($tempParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Recovered proposal continuation refused reparse-point temp parent '$tempParent'." }
$tempName = 'wef-rpc-' + [guid]::NewGuid().ToString('N')
$temp = [IO.Path]::GetFullPath((Join-Path $tempParent $tempName))
$tempPrefix = $tempParent + [IO.Path]::DirectorySeparatorChar
if (-not $temp.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($temp) -cne $tempName) { throw "Recovered proposal continuation derived unsafe temp root '$temp'." }
$settled = $false
try {
    [void][IO.Directory]::CreateDirectory($temp)
    $createdTemp = Get-Item -LiteralPath $temp -Force
    if (($createdTemp.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Recovered proposal continuation refused reparse-point temp root '$temp'." }
    $seed = New-RecoveredProposalContinuationSeed -Root (Join-Path $temp 'seed') -RepositoryRoot $repoRoot -TransitionLedgerModule $transitionLedgerModule
    $callerRoot = Join-Path $temp 'caller'
    $caller = New-RecoveredProposalContinuationFixture -BaseRepository $seed.base_repository -FixtureRoot $callerRoot -RepreparationTemplate $seed.repreparation_template -AdmissionTemplate $seed.admission_template -RepreparationModule $repreparationModule
    $callerHeadBefore = (@(Invoke-EnvelopeGit $caller.repository @('rev-parse','HEAD'))[0]).Trim()
    $callerWorkspaceBefore = Get-EnvelopeWorkspaceByteInventorySha256 $caller.workspace
    $callerRepositoryBefore = Get-EnvelopeWorkspaceByteInventorySha256 $caller.repository

    $continuationRoot = Join-Path $temp 'continuation'
    $continuation = New-RecoveredProposalContinuationFixture -BaseRepository $seed.base_repository -FixtureRoot $continuationRoot -RepreparationTemplate $seed.repreparation_template -AdmissionTemplate $seed.admission_template -RepreparationModule $repreparationModule
    Test-RecoveredProposalRetirement -AdmittedWorkspace $continuation.workspace -TestRoot $continuationRoot -ScriptsRoot $PSScriptRoot

    $callerHeadAfter = (@(Invoke-EnvelopeGit $caller.repository @('rev-parse','HEAD'))[0]).Trim()
    Assert-Envelope ($callerHeadAfter -ceq $callerHeadBefore -and (Get-EnvelopeWorkspaceByteInventorySha256 $caller.workspace) -ceq $callerWorkspaceBefore -and (Get-EnvelopeWorkspaceByteInventorySha256 $caller.repository) -ceq $callerRepositoryBefore) 'isolated continuation regression changed its caller workspace or mapped Git repository'

    $alternateMapPath = Join-Path $caller.workspace 'local/repository-map.json'
    [void][IO.Directory]::CreateDirectory((Split-Path $alternateMapPath -Parent))
    Copy-Item -LiteralPath (Join-Path $caller.workspace 'repository-map.json') -Destination $alternateMapPath
    $substitutedAdmission = Copy-Envelope $caller.admission
    $substitutedAdmission.expected.repository_map_path = 'local/repository-map.json'
    $substitutedAdmission.expected.repository_map_sha256 = Get-EnvelopeFileSha256 $alternateMapPath
    $substitutionRejected = $false
    try { Test-MorphospacePreparedDevelopmentEnvelope -WorkspaceRoot $caller.workspace -Admission $substitutedAdmission -Phase Freeze | Out-Null }
    catch { $substitutionRejected = $true }
    Remove-Item -LiteralPath $alternateMapPath
    Remove-Item -LiteralPath (Split-Path $alternateMapPath -Parent)
    Assert-Envelope ($substitutionRejected -and -not (Test-Path -LiteralPath (Split-Path $alternateMapPath -Parent))) 'recovered admission map substitution or nonrecursive cleanup did not preserve the caller boundary'

    Write-Host 'Recovered proposal continuation self-test passed.'
    $settled = $true
} finally {
    if (Test-Path -LiteralPath $temp) {
        if (-not $settled) {
            Write-Warning "Preserved unsettled recovered proposal continuation evidence at '$temp'."
        } else {
            $cleanupItem = Get-Item -LiteralPath $temp -Force
            $cleanupPath = [IO.Path]::GetFullPath($cleanupItem.FullName)
            $cleanupSafe = $cleanupPath.Equals($temp,[StringComparison]::OrdinalIgnoreCase) -and
                $cleanupPath.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($cleanupPath) -ceq $tempName -and
                ($cleanupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
            if (-not $cleanupSafe) { throw "Recovered proposal continuation refused unsafe cleanup of '$cleanupPath'; evidence was preserved." }
            Remove-Item -LiteralPath $cleanupPath -Recurse -Force
        }
    }
}
