[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][int]$CurrentAttempt,
    [Parameter(Mandatory = $true)][ValidateSet('linux','windows')][string]$Platform,
    [Parameter(Mandatory = $true)][string]$DestinationRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationArtifactTransport.psm1') -Force

if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw 'Segment download requires an owner/repository identity.' }
[UInt64]$parsedRunId = 0
if ($RunId -cnotmatch '\A[1-9][0-9]*\z' -or -not [UInt64]::TryParse($RunId, [ref]$parsedRunId) -or $CurrentAttempt -lt 1) { throw 'Segment download requires a canonical positive run ID and attempt.' }
$destination = [IO.Path]::GetFullPath($DestinationRoot)
$ancestor = $destination
while (-not [string]::IsNullOrEmpty($ancestor)) {
    if (Test-Path -LiteralPath $ancestor) {
        if (([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Segment download rejects a reparse-point ancestor.' }
    }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
if (Test-Path -LiteralPath $destination) { throw 'Segment download destination already exists.' }

$remoteArtifacts = [Collections.Generic.List[object]]::new()
$complete = $false
for ($page = 1; $page -le 100; $page++) {
    $raw = & gh api "/repos/$Repository/actions/runs/$RunId/artifacts?per_page=100&page=$page"
    if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate segment artifacts.' }
    $response = ($raw -join "`n") | ConvertFrom-Json -Depth 32
    $rows = @($response.artifacts)
    if ($rows.Count -gt 100) { throw 'Segment artifact page exceeds its bound.' }
    foreach ($row in $rows) { $remoteArtifacts.Add($row) }
    # Other platform jobs may upload while this reducer lists its completed
    # producers. Global total_count is not a stable target-platform identity.
    if ($rows.Count -lt 100) { $complete = $true; break }
}
if (-not $complete) { throw 'Segment artifact inventory exceeds its 100-page bound.' }

$candidates = [Collections.Generic.List[object]]::new()
$logicalIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($artifact in $remoteArtifacts) {
    if (-not ([string]$artifact.name).StartsWith("affected-segment-$Platform-", [StringComparison]::Ordinal)) { continue }
    $identity = ConvertFrom-MorphospaceAffectedArtifactName -Name ([string]$artifact.name) -RunId $RunId -CurrentAttempt $CurrentAttempt
    [UInt64]$artifactId = 0
    if ([string]$artifact.id -cnotmatch '\A[1-9][0-9]*\z' -or -not [UInt64]::TryParse([string]$artifact.id, [ref]$artifactId)) { throw 'Segment artifact ID is invalid.' }
    if (-not $names.Add([string]$artifact.name) -or -not $ids.Add([string]$artifact.id)) { throw 'Segment artifact inventory has duplicate names or IDs.' }
    [void]$logicalIds.Add([string]$identity.logical_id)
    $candidates.Add($artifact)
}
if ($candidates.Count -eq 0) { throw "No $Platform segment artifacts were found." }
$selected = @(Select-MorphospaceAffectedArtifactAttempts -Artifacts $candidates.ToArray() -ExpectedIds @($logicalIds | Sort-Object) -RunId $RunId -CurrentAttempt $CurrentAttempt)
foreach ($item in $selected) {
    if ($item.artifact.expired -isnot [bool] -or [bool]$item.artifact.expired) { throw "Selected segment artifact '$($item.artifact.name)' is expired or has invalid expiry metadata." }
}

# The CLI, like download-artifact, flattens a single named download into --dir.
# Bind that explicit directory to the API artifact name for every cardinality.
# Staging independently authenticates expected segment IDs and all payload bytes.
[void][IO.Directory]::CreateDirectory($destination)
foreach ($item in $selected) {
    $name = [string]$item.artifact.name
    & gh run download $RunId --repo $Repository --name $name --dir (Join-Path $destination $name)
    if ($LASTEXITCODE -ne 0) { throw "Could not download selected segment artifact '$name'." }
}
