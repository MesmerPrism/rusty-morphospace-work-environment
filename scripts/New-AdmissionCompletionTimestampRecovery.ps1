param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [string]$Timestamp = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdmissionCompletionTimestampRecovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

$document = New-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $WorkspaceRoot -Timestamp $Timestamp
$bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $document) + "`n")
$target = [IO.Path]::GetFullPath($OutPath)
if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) { throw "Admission completion timestamp recovery output already exists: $target" }
$parent = [IO.Path]::GetDirectoryName($target)
if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
$stream = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
} finally {
    $stream.Dispose()
}
[pscustomobject][ordered]@{
    path = $target
    sha256 = Get-MorphospaceSha256Bytes $bytes
    recovery_id = [string]$document.recovery_id
    admission_id = [string]$document.admission_id
    unit_id = [string]$document.unit_id
    correction_event_id = [string]$document.correction_event.event_id
}
