param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$RepoMapPath,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [string]$Timestamp = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "WorkUnitAutomation.psm1") -Force

$arguments = @{
    WorkspaceRoot = $WorkspaceRoot
    UnitId = $UnitId
    RepoMapPath = $RepoMapPath
    OutPath = $OutPath
    Timestamp = $Timestamp
    Execute = $Execute
}

New-MorphospaceInflightAdoptionReceipt @arguments | ConvertTo-Json -Depth 32
