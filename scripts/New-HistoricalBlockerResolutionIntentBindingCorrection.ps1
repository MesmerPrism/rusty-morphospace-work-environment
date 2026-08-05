param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$HistoricalEventId,
    [Parameter(Mandatory = $true)][string]$ReceiptId,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [string]$Timestamp = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalBlockerResolutionIntentBindingCorrection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

$target = [IO.Path]::GetFullPath($OutPath)
if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) { throw 'Historical correction builder requires a new output path.' }
$document = New-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection `
    -WorkspaceRoot $WorkspaceRoot -HistoricalEventId $HistoricalEventId -ReceiptId $ReceiptId -Timestamp $Timestamp
$parent = [IO.Path]::GetDirectoryName($target)
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($target, (ConvertTo-MorphospaceCanonicalJson $document) + "`n", [Text.UTF8Encoding]::new($false))
[void](Test-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection -WorkspaceRoot $WorkspaceRoot -ReceiptPath $target -Mode PreApply)
[pscustomobject][ordered]@{
    schema = [string]$document.schema
    receipt_id = [string]$document.receipt_id
    path = $target
    sha256 = Get-MorphospaceFileSha256 $target
    event_id = [string]$document.correction_event.event_id
    historical_event_id = [string]$document.historical_resolution.event.event_id
} | ConvertTo-Json -Depth 8
