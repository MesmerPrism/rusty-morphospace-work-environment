param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$ValidationUnitId,
    [Parameter(Mandatory = $true)][string]$WithdrawnUnitId,
    [Parameter(Mandatory = $true)][string]$ReceiptId,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [string]$Timestamp = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalUnitCompatibilityProjection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

$target = [IO.Path]::GetFullPath($OutPath)
if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) { throw 'Historical compatibility builder requires a new output path.' }
$document = New-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $WorkspaceRoot `
    -ValidationUnitId $ValidationUnitId -WithdrawnUnitId $WithdrawnUnitId -ReceiptId $ReceiptId -Timestamp $Timestamp
$parent = [IO.Path]::GetDirectoryName($target)
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($target,(ConvertTo-MorphospaceCanonicalJson $document) + "`n",[Text.UTF8Encoding]::new($false))
[void](Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $WorkspaceRoot -ReceiptPath $target -Mode PreApply)
[pscustomobject][ordered]@{
    schema=[string]$document.schema;receipt_id=[string]$document.receipt_id;path=$target
    sha256=Get-MorphospaceFileSha256 $target;event_id=[string]$document.projection_event.event_id
    authority_unit_id=[string]$document.authority_unit_id;target_unit_ids=@($document.targets | ForEach-Object { [string]$_.unit_id })
} | ConvertTo-Json -Depth 8
