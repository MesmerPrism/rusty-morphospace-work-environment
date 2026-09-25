param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$UnitId,
    [Parameter(Mandatory)][string]$LocalDirectory,
    [Parameter(Mandatory)][string]$CreatedAt,
    [Parameter(Mandatory)][string]$OutPath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AcceptedValidationEvidenceRelocation.psm1') -Force
New-MorphospaceAcceptedEvidenceRelocationInput -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -LocalDirectory $LocalDirectory -CreatedAt $CreatedAt -OutPath $OutPath | ConvertTo-Json -Depth 20
