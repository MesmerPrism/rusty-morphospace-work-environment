[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$RepoMapPath,
    [Parameter(Mandatory = $true)][string]$EvidencePath,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [string]$CreatedAt = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationReceipt.psm1') -Force

$evidence = Get-Content -LiteralPath (Resolve-Path -LiteralPath $EvidencePath).Path -Raw | ConvertFrom-Json -Depth 100 -DateKind String
New-MorphospaceValidationReceiptV1 -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -RepoMapPath $RepoMapPath -Evidence $evidence -OutPath $OutPath -CreatedAt $CreatedAt
