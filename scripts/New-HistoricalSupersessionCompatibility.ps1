param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$OldUnitId,
    [Parameter(Mandatory)][string]$ReplacementUnitId,
    [Parameter(Mandatory)][string]$NormalizationId,
    [Parameter(Mandatory)][string]$CompatibilityId,
    [Parameter(Mandatory)][string]$OutPath,
    [string]$Timestamp = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalSupersessionCompatibility.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

$target = [IO.Path]::GetFullPath($OutPath)
if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) {
    throw 'Historical supersession compatibility builder requires a new output path.'
}
$document = New-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $WorkspaceRoot `
    -OldUnitId $OldUnitId -ReplacementUnitId $ReplacementUnitId `
    -NormalizationId $NormalizationId -CompatibilityId $CompatibilityId -Timestamp $Timestamp
$parent = [IO.Path]::GetDirectoryName($target)
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
$bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $document) + "`n")
$stream=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
[void](Test-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $WorkspaceRoot -ReceiptPath $target -Mode PreApply)
[pscustomobject][ordered]@{
    schema = [string]$document.schema
    compatibility_id = [string]$document.compatibility_id
    path = $target
    sha256 = Get-MorphospaceFileSha256 $target
    event_id = [string]$document.compatibility_event.event_id
    old_unit_id = [string]$document.old_unit.unit_id
    replacement_unit_id = [string]$document.replacement_unit.unit_id
} | ConvertTo-Json -Depth 8
