param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$protocolModule = Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$transitionLedgerModule = Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementContinuation.ps1')
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementFixture.ps1')
$tempParent = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
if (((Get-Item -LiteralPath $tempParent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Active retirement continuation refuses a reparse-point temp parent.' }
$tempName = 'wef-active-continuation-' + [guid]::NewGuid().ToString('N')
$temp = [IO.Path]::GetFullPath((Join-Path $tempParent $tempName))
$tempPrefix = $tempParent + [IO.Path]::DirectorySeparatorChar
if (-not $temp.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($temp) -cne $tempName) { throw 'Unsafe active retirement continuation temp root.' }
$settled = $false
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    [void][IO.Directory]::CreateDirectory($temp)
    $seed = New-ActiveRetirementContinuationSeed -Root (Join-Path $temp 'seed') -RepositoryRoot $repoRoot
    $request = New-ActiveUnitRetirementRequest -WorkspaceRoot $seed.workspace
    $requestPath = Join-Path $temp 'active-retirement-request.json'
    Write-EnvelopeJson $requestPath $request
    $receiptRelative = 'receipts/active-retirement.json'
    $arguments = @{Action='RetireActive'; WorkspaceRoot=$seed.workspace; UnitId='u002'; RepoMapPath=(Join-Path $seed.workspace 'repository-map.json'); ActiveUnitRetirement=$requestPath; OutPath=(Join-Path $seed.workspace $receiptRelative); Timestamp='2026-08-25T00:01:00.0000000Z'}
    $before = Get-EnvelopeWorkspaceByteInventorySha256 $seed.workspace
    $dry = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') @arguments | ConvertFrom-Json
    Assert-Envelope ($before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $seed.workspace)) 'active retirement dry run changed workspace bytes'
    $null = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') @arguments -ExpectedActiveUnitRetirementSha256 $dry.audit_receipt.sha256 -Execute
    Test-ActiveRetirementContinuation -Workspace $seed.workspace -TestRoot $temp -RepositoryRoot $repoRoot -RetirementReceiptPath $receiptRelative
    $settled = $true
    Write-Host "Active retirement continuation self-test passed: elapsed_ms=$($clock.ElapsedMilliseconds)."
} finally {
    if (Test-Path -LiteralPath $temp) {
        if (-not $settled) { Write-Warning "Preserved unsettled active retirement continuation evidence at '$temp'." }
        else {
            $item = Get-Item -LiteralPath $temp -Force
            $cleanupPath = [IO.Path]::GetFullPath($item.FullName)
            if (-not $cleanupPath.Equals($temp,[StringComparison]::OrdinalIgnoreCase) -or -not $cleanupPath.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($cleanupPath) -cne $tempName -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe active retirement continuation cleanup; evidence preserved.' }
            Remove-Item -LiteralPath $cleanupPath -Recurse -Force
        }
    }
}
