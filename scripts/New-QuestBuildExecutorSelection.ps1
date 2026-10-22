[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedInputSha256,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceQuestBuildExecutorSelection.psm1') -Force
$PSBoundParameters['InputPath']=[IO.Path]::GetFullPath($InputPath)
$PSBoundParameters['OutputDirectory']=[IO.Path]::GetFullPath($OutputDirectory)
New-MorphospaceQuestBuildExecutorSelection @PSBoundParameters | ConvertTo-Json -Depth 10 -Compress
