Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoryArchive.psm1') -Force

function Invoke-MorphospaceHistoryArchiveCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [Parameter(Mandatory=$true)][string]$HistoryArchiveCheckpoint,
        [Parameter(Mandatory=$true)][string]$OutPath,
        [string]$ExpectedHistoryArchiveCheckpointSha256='',
        [string]$Timestamp='',
        [switch]$Execute,
        [ValidateSet('none','after-intent','after-objects','after-root','after-receipt','after-state','after-event')][string]$FaultAfter='none'
    )
    Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $WorkspaceRoot -HistoryArchiveCheckpoint $HistoryArchiveCheckpoint -OutPath $OutPath -ExpectedHistoryArchiveCheckpointSha256 $ExpectedHistoryArchiveCheckpointSha256 -Timestamp $Timestamp -Execute:$Execute -FaultAfter $FaultAfter
}

function Test-MorphospaceHistoryArchiveCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [ValidateSet('quick','deep','audit','migration')][string]$Tier='quick',
        [string]$ValidationId='history-archive-validation'
    )
    Test-MorphospaceHistoryArchive -WorkspaceRoot $WorkspaceRoot -Tier $Tier -ValidationId $ValidationId
}

Export-ModuleMember -Function Invoke-MorphospaceHistoryArchiveCheckpoint, Test-MorphospaceHistoryArchiveCheckpoint
