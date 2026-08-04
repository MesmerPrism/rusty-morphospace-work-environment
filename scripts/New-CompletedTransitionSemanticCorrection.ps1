param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [string]$Timestamp = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceCompletedTransitionSemanticCorrection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

$document = New-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $WorkspaceRoot -Timestamp $Timestamp
$bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $document) + "`n")
$target = [IO.Path]::GetFullPath($OutPath)
if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) {
    throw "Completed-transition correction output already exists: $target"
}
$parent = [IO.Path]::GetDirectoryName($target)
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
$stream = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
} finally {
    $stream.Dispose()
}
[pscustomobject][ordered]@{
    path = $target
    sha256 = Get-MorphospaceSha256Bytes -Bytes $bytes
    receipt_id = [string]$document.receipt_id
    original_event_id = [string]$document.original_transition.event.event_id
    effective_old_unit_id = [string]$document.semantic_correction.effective_old_unit_id
    replacement_unit_id = [string]$document.semantic_correction.replacement_unit_id
    correction_event_id = [string]$document.correction_event.event_id
}
