[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$BaseCommit,
    [Parameter(Mandatory = $true)][string]$HeadCommit,
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [Parameter(Mandatory = $true)][ValidateSet('windows','linux')][string]$Platform,
    [Parameter(Mandatory = $true)][string]$DownloadedArtifactRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][int]$CurrentAttempt,
    [Parameter(Mandatory = $true)][string]$StagingDirectory,
    [Parameter(Mandatory = $true)][string]$SelectionReceiptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationArtifactTransport.psm1') -Force

function Assert-TransportNoReparseAncestor {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $volume = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($volume)) { throw "Affected segment transport path has no filesystem root: $Path" }
    if (([IO.Directory]::Exists($volume) -or [IO.File]::Exists($volume)) -and
        (([IO.File]::GetAttributes($volume) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Affected segment transport rejects reparse-point filesystem root: $volume"
    }
    $current = $volume
    foreach ($part in $full.Substring($volume.Length).Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        if (-not ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current))) { break }
        if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Affected segment transport rejects reparse-point ancestor: $current"
        }
    }
}

function Test-TransportPathOverlap {
    param([Parameter(Mandatory = $true)][string]$Left, [Parameter(Mandatory = $true)][string]$Right)

    $leftFull = [IO.Path]::GetFullPath($Left)
    $rightFull = [IO.Path]::GetFullPath($Right)
    if ($leftFull.Length -gt [IO.Path]::GetPathRoot($leftFull).Length) { $leftFull = $leftFull.TrimEnd('\','/') }
    if ($rightFull.Length -gt [IO.Path]::GetPathRoot($rightFull).Length) { $rightFull = $rightFull.TrimEnd('\','/') }
    if ($leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $leftPrefix = $leftFull + [IO.Path]::DirectorySeparatorChar
    $rightPrefix = $rightFull + [IO.Path]::DirectorySeparatorChar
    return $leftFull.StartsWith($rightPrefix, [StringComparison]::OrdinalIgnoreCase) -or $rightFull.StartsWith($leftPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-TransportGitMetadataPath {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot, [Parameter(Mandatory = $true)][string]$Argument)

    $result = @(& git -C $RepositoryRoot rev-parse --path-format=absolute $Argument 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $detail = (@($result | ForEach-Object { [string]$_ }) -join "`n").Trim()
        throw "Affected segment transport cannot resolve Git metadata '$Argument': $detail"
    }
    if ($result.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$result[0])) {
        throw "Affected segment transport Git metadata '$Argument' is ambiguous."
    }
    return [IO.Path]::GetFullPath(([string]$result[0]).Trim())
}

function Get-TransportBoundedBytes {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Context)

    Assert-TransportNoReparseAncestor -Path $Path
    if (-not [IO.File]::Exists($Path)) { throw "Affected segment transport $Context is absent: $Path" }
    $length = [long]([IO.FileInfo]$Path).Length
    if ($length -gt 16777216) { throw "Affected segment transport $Context exceeds the 16 MiB bound: $Path" }
    return [IO.File]::ReadAllBytes($Path)
}

function Write-TransportCreateNew {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][byte[]]$Bytes)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

if ($CurrentAttempt -lt 1) { throw 'Affected segment transport requires a positive current attempt.' }
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$planFull = [IO.Path]::GetFullPath($PlanPath)
$downloadRoot = [IO.Path]::GetFullPath($DownloadedArtifactRoot)
$stage = [IO.Path]::GetFullPath($StagingDirectory)
$receiptFull = [IO.Path]::GetFullPath($SelectionReceiptPath)

# Refuse output state and input/output aliasing before source recomputation or
# payload processing. An existing path is evidence from another operation.
foreach ($path in @($root, $planFull, $downloadRoot, $stage, $receiptFull)) { Assert-TransportNoReparseAncestor -Path $path }
if ([IO.Directory]::Exists($stage) -or [IO.File]::Exists($stage)) { throw 'Affected segment transport staging directory already exists.' }
if ([IO.Directory]::Exists($receiptFull) -or [IO.File]::Exists($receiptFull)) { throw 'Affected segment transport selection receipt already exists.' }
$gitMetadataPaths = @(
    Get-TransportGitMetadataPath -RepositoryRoot $root -Argument '--git-dir'
    Get-TransportGitMetadataPath -RepositoryRoot $root -Argument '--git-common-dir'
    [IO.Path]::GetFullPath((Join-Path $root '.git'))
)
foreach ($metadataPath in $gitMetadataPaths) { Assert-TransportNoReparseAncestor -Path $metadataPath }
foreach ($output in @($stage, $receiptFull)) {
    foreach ($metadataPath in $gitMetadataPaths) {
        if (Test-TransportPathOverlap -Left $output -Right $metadataPath) {
            throw "Affected segment transport output overlaps Git metadata: $output"
        }
    }
    foreach ($input in @($planFull, $downloadRoot)) {
        if (Test-TransportPathOverlap -Left $output -Right $input) { throw "Affected segment transport output overlaps an input: $output" }
    }
}
if (Test-TransportPathOverlap -Left $stage -Right $receiptFull) { throw 'Affected segment transport outputs overlap.' }

if (-not [IO.Directory]::Exists($root)) { throw 'Affected segment transport repository root is absent.' }
$planBytes = Get-TransportBoundedBytes -Path $planFull -Context 'plan'
$planRaw = [Text.UTF8Encoding]::new($false, $true).GetString($planBytes)
$planSchema = Join-Path $repoRoot 'schemas/affected-validation-plan-v2.schema.json'
if (-not (Test-Json -Json $planRaw -SchemaFile $planSchema -ErrorAction Stop)) { throw 'Affected segment transport plan fails its closed schema.' }
$plan = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $planBytes -Context 'affected segment transport plan'
if (-not [bool]$plan.execution_permitted -or [string]$plan.selection_mode -ceq 'mapping-incomplete') { throw 'Affected segment transport rejects a non-executable plan.' }
$registryPath = Join-Path $root 'manifests/affected-validation-registry.json'
$recomputed = Resolve-MorphospaceAffectedValidation -RepositoryRoot $root -BaseRevision $BaseCommit -HeadRevision $HeadCommit -RegistryPath $registryPath -RequestedTier ([string]$plan.requested_tier)
if ((Get-MorphospaceCanonicalJsonSha256 -Value $recomputed) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $plan) -or [string]$recomputed.plan_sha256 -cne [string]$plan.plan_sha256) { throw 'Affected segment transport plan differs from exact base/head selection.' }
$registry = Read-MorphospaceProtocolJson -Path $registryPath
[void](Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $root -SchemaPath (Join-Path $root 'schemas/affected-validation-registry-v1.schema.json'))
$segments = @(Get-MorphospaceAffectedValidationSegments -Plan $plan -Registry $registry -Platform $Platform)
if ($segments.Count -eq 0) { throw "Affected segment transport rejects empty '$Platform' selection." }
$expectedIds = @($segments | ForEach-Object { [string]$_.segment_id })

if (-not [IO.Directory]::Exists($downloadRoot)) { throw 'Affected segment transport download root is absent.' }
$entries = @([IO.Directory]::EnumerateFileSystemEntries($downloadRoot) | ForEach-Object { Get-Item -LiteralPath $_ -Force })
if ($entries.Count -eq 0) { throw 'Affected segment transport download root is empty.' }
foreach ($entry in $entries) {
    Assert-TransportNoReparseAncestor -Path $entry.FullName
    if (-not $entry.PSIsContainer) { throw "Affected segment transport download layout contains a file: $($entry.Name)" }
}
$selection = @(Select-MorphospaceAffectedArtifactAttempts -Artifacts $entries -ExpectedIds $expectedIds -RunId $RunId -CurrentAttempt $CurrentAttempt)

$evidenceSchema = Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json'
$validated = [Collections.Generic.List[object]]::new()
foreach ($selected in $selection) {
    $identity = $selected.identity
    $artifactDirectory = [string]$selected.artifact.FullName
    Assert-TransportNoReparseAncestor -Path $artifactDirectory
    $payloadEntries = @([IO.Directory]::EnumerateFileSystemEntries($artifactDirectory) | ForEach-Object { Get-Item -LiteralPath $_ -Force })
    $expectedFileName = [string]$identity.file_name
    if ($payloadEntries.Count -ne 1 -or $payloadEntries[0].PSIsContainer -or [string]$payloadEntries[0].Name -cne $expectedFileName) {
        throw "Affected segment transport payload layout is not exact: $($selected.artifact.Name)"
    }
    $payloadPath = [string]$payloadEntries[0].FullName
    $bytes = Get-TransportBoundedBytes -Path $payloadPath -Context "payload '$($selected.artifact.Name)'"
    $actualHash = Get-MorphospaceSha256Bytes -Bytes $bytes
    if ($actualHash -cne [string]$identity.digest) { throw "Affected segment transport payload SHA-256 differs from artifact name: $($selected.artifact.Name)" }
    $raw = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if (-not (Test-Json -Json $raw -SchemaFile $evidenceSchema -ErrorAction Stop)) { throw "Affected segment transport payload fails its closed schema: $($selected.artifact.Name)" }
    $evidence = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context "affected segment transport payload '$($selected.artifact.Name)'"
    if ([string]$evidence.repository -cne [string]$plan.repository -or [string]$evidence.plan_sha256 -cne [string]$plan.plan_sha256 -or [string]$evidence.platform -cne $Platform -or [string]$evidence.result -cne 'pass') {
        throw "Affected segment transport payload identity or result differs from plan: $($selected.artifact.Name)"
    }
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $evidence.base) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $plan.base) -or
        (Get-MorphospaceCanonicalJsonSha256 -Value $evidence.head) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $plan.head)) {
        throw "Affected segment transport payload source differs from plan: $($selected.artifact.Name)"
    }
    $validated.Add([pscustomobject][ordered]@{ identity=$identity; artifact_name=[string]$selected.artifact.Name; bytes=$bytes })
}

$receiptSelected = @($validated.ToArray() | ForEach-Object {
    [pscustomobject][ordered]@{
        segment_id = [string]$_.identity.logical_id
        artifact_name = [string]$_.artifact_name
        attempt = [long]$_.identity.attempt
        payload_sha256 = [string]$_.identity.digest
    }
})
$receipt = [pscustomobject][ordered]@{
    schema = 'rusty.morphospace.workflow.affected_validation_segment_selection.v1'
    repository = [string]$plan.repository
    run = [pscustomobject][ordered]@{ id=$RunId; current_attempt=$CurrentAttempt }
    source = [pscustomobject][ordered]@{ base=$plan.base; head=$plan.head; plan_sha256=[string]$plan.plan_sha256; platform=$Platform }
    selected = $receiptSelected
    claims = [pscustomobject][ordered]@{ segment_evidence_staged=$true; aggregate_authority=$false; acceptance_authority=$false; publication_authority=$false }
}
$receiptJson = ConvertTo-MorphospaceCanonicalJson -Value $receipt
$receiptSchema = Join-Path $repoRoot 'schemas/affected-validation-segment-selection-v1.schema.json'
if (-not (Test-Json -Json $receiptJson -SchemaFile $receiptSchema -ErrorAction Stop)) { throw 'Affected segment transport selection receipt fails its closed schema.' }

[void][IO.Directory]::CreateDirectory($stage)
Assert-TransportNoReparseAncestor -Path $stage
foreach ($item in $validated) { Write-TransportCreateNew -Path (Join-Path $stage "$([string]$item.identity.logical_id).json") -Bytes ([byte[]]$item.bytes) }
$receiptParent = [IO.Path]::GetDirectoryName($receiptFull)
if (-not [IO.Directory]::Exists($receiptParent)) { [void][IO.Directory]::CreateDirectory($receiptParent) }
Assert-TransportNoReparseAncestor -Path $receiptFull
Write-TransportCreateNew -Path $receiptFull -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($receiptJson + "`n"))
$receipt
