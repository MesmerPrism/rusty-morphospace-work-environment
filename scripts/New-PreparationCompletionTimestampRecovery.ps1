[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$PreparationId,[Parameter(Mandatory)][string]$OutPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PreparationCompletionTimestampRecovery.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
$receipt=New-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $WorkspaceRoot -PreparationId $PreparationId
$bytes=ConvertTo-MorphospaceProtocolJsonBytes $receipt
$path=[IO.Path]::GetFullPath($OutPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null
$stream=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
[pscustomobject]@{path=$path;sha256=(Get-MorphospaceSha256Bytes $bytes);recovery_id=$receipt.recovery_id;preparation_id=$receipt.preparation_id}
