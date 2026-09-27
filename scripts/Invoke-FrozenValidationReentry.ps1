[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$UnitId,
    [Parameter(Mandatory)][string]$FrozenValidationReentry,
    [string]$ExpectedFrozenValidationReentrySha256='',
    [Parameter(Mandatory)][string]$OutPath,
    [string]$Timestamp='',
    [switch]$Execute,
    [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$reentryModule=Import-Module (Join-Path $PSScriptRoot 'FrozenValidationReentry.psm1') -PassThru
& $reentryModule { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $PSBoundParameters | ConvertTo-Json -Depth 100
