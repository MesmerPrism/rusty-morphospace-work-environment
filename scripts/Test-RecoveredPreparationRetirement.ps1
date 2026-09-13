param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Test-RecoveredProposalContinuation.ps1') -SelfTest -Scenario RepreparationRetirement
