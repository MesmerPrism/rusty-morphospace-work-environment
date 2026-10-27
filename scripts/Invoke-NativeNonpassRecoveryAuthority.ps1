param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$ExecutorRoot,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/NativeNonpassRecoveryAuthority.psm1') -Force
$result=Invoke-NativeNonpassRecoveryAuthority -WorkspaceRoot $WorkspaceRoot -RequestPath $RequestPath -ExecutorRoot $ExecutorRoot -Execute:$Execute
$result|ConvertTo-Json -Depth 32
if($Execute-and$result.exit_code-ne0){exit $result.exit_code}
