[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$BaseCommit,
    [Parameter(Mandatory = $true)][string]$HeadCommit,
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$Platform,
    [Parameter(Mandatory = $true)][string]$SegmentEvidenceDirectory,
    [Parameter(Mandatory = $true)][string]$OutPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force

$planFull = [IO.Path]::GetFullPath($PlanPath)
if (-not [IO.File]::Exists($planFull)) { throw 'Affected-validation plan is absent.' }
$planRaw = Get-Content -LiteralPath $planFull -Raw
$planSchema = Join-Path $repoRoot 'schemas/affected-validation-plan-v1.schema.json'
if (-not (Test-Json -Json $planRaw -SchemaFile $planSchema -ErrorAction Stop)) { throw 'Affected-validation plan fails its closed schema.' }
$plan = Read-MorphospaceProtocolJson -Path $planFull
$registryPath = Join-Path $root 'manifests/affected-validation-registry.json'
$recomputed = Resolve-MorphospaceAffectedValidation -RepositoryRoot $root -BaseRevision $BaseCommit -HeadRevision $HeadCommit -RegistryPath $registryPath -RequestedTier ([string]$plan.requested_tier)
if ((Get-MorphospaceCanonicalJsonSha256 -Value $recomputed) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $plan) -or [string]$plan.plan_sha256 -cne [string]$recomputed.plan_sha256) { throw 'Affected-validation plan differs from the exact current base/head/registry selection.' }
$registry = Read-MorphospaceProtocolJson -Path $registryPath
[void](Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $root -SchemaPath (Join-Path $root 'schemas/affected-validation-registry-v1.schema.json'))
$segments = @(Get-MorphospaceAffectedValidationSegments -Plan $plan -Registry $registry -Platform $Platform)
if ($segments.Count -eq 0) { throw "Affected-validation segment merge rejects an empty '$Platform' selection." }

$evidenceRoot = [IO.Path]::GetFullPath($SegmentEvidenceDirectory)
if (-not [IO.Directory]::Exists($evidenceRoot)) { throw 'Affected-validation segment evidence directory is absent.' }
if (([IO.File]::GetAttributes($evidenceRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Affected-validation segment evidence directory is a reparse point.' }
$files = @(Get-ChildItem -LiteralPath $evidenceRoot -File -Force)
$directories = @(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force)
if ($directories.Count -ne 0 -or $files.Count -ne $segments.Count) { throw 'Affected-validation segment evidence inventory is not exact.' }

$evidenceSchema = Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json'
$checkMap = @{}; foreach ($check in @($registry.checks)) { $checkMap[[string]$check.check_id] = $check }
$inventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $root -Commit ([string]$plan.head.commit)
$resultMap = @{}
$runner = $null
$runnerSha256 = $null
foreach ($segment in $segments) {
    $fileName = "$([string]$segment.segment_id).json"
    $path = Join-Path $evidenceRoot $fileName
    if (-not [IO.File]::Exists($path) -or ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Affected-validation segment evidence is absent or indirect: $fileName" }
    $raw = Get-Content -LiteralPath $path -Raw
    if (-not (Test-Json -Json $raw -SchemaFile $evidenceSchema -ErrorAction Stop)) { throw "Affected-validation segment evidence fails its closed schema: $fileName" }
    $evidence = $raw | ConvertFrom-Json -Depth 64 -DateKind String
    if ([string]$evidence.repository -cne [string]$plan.repository -or [string]$evidence.plan_sha256 -cne [string]$plan.plan_sha256 -or [string]$evidence.platform -cne $Platform -or [string]$evidence.result -cne 'pass') { throw "Affected-validation segment evidence identity or result is invalid: $fileName" }
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $evidence.base) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $plan.base) -or (Get-MorphospaceCanonicalJsonSha256 -Value $evidence.head) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $plan.head)) { throw "Affected-validation segment evidence source differs from the plan: $fileName" }
    $currentRunnerSha256 = Get-MorphospaceCanonicalJsonSha256 -Value $evidence.runner
    if ($null -eq $runner) { $runner = $evidence.runner; $runnerSha256 = $currentRunnerSha256 }
    elseif ($currentRunnerSha256 -cne $runnerSha256) { throw 'Affected-validation segment runners differ within one platform result.' }
    $expectedIds = @($segment.check_ids)
    $actualIds = @($evidence.check_results | ForEach-Object { [string]$_.check_id })
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $actualIds) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $expectedIds)) { throw "Affected-validation segment check coverage or order is invalid: $fileName" }
    foreach ($result in @($evidence.check_results)) {
        $id = [string]$result.check_id
        if ([long]$result.stdout_bytes + [long]$result.stderr_bytes -gt 10485760) { throw "Affected-validation segment result exceeds the combined stream bound: $id" }
        if ($resultMap.ContainsKey($id) -or -not $checkMap.ContainsKey($id)) { throw "Affected-validation segment repeats or invents check '$id'." }
        $check = $checkMap[$id]
        $entry = $inventory.by_path[[string]$check.command_path]
        if ($null -eq $entry -or [string]$entry.type -cne 'blob' -or [string]$result.command_path -cne [string]$check.command_path -or [string]$result.command_blob_sha1 -cne [string]$entry.blob -or [string]$result.result -cne 'pass') { throw "Affected-validation segment result differs from the exact registered command: $id" }
        $resultMap[$id] = $result
    }
}

$selected = @($plan.selected_checks | Where-Object { @($_.platforms) -ccontains $Platform })
if ($resultMap.Count -ne $selected.Count) { throw 'Affected-validation segment union does not cover the exact platform selection.' }
$orderedResults = [Collections.Generic.List[object]]::new()
foreach ($selection in $selected) {
    $id = [string]$selection.check_id
    if (-not $resultMap.ContainsKey($id)) { throw "Affected-validation segment union omits '$id'." }
    $orderedResults.Add($resultMap[$id])
}
$merged = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.affected_validation_evidence.v1'; repository=[string]$plan.repository; base=$plan.base; head=$plan.head; plan_sha256=[string]$plan.plan_sha256; platform=$Platform
    runner=$runner; check_results=@($orderedResults.ToArray()); result='pass'
    claims=[pscustomobject][ordered]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}
}
$json = ConvertTo-MorphospaceCanonicalJson -Value $merged
if (-not (Test-Json -Json $json -SchemaFile $evidenceSchema -ErrorAction Stop)) { throw 'Merged affected-validation evidence fails its closed schema.' }
$output = [IO.Path]::GetFullPath($OutPath)
$parent = [IO.Path]::GetDirectoryName($output)
if ([IO.File]::Exists($output)) { throw 'Merged affected-validation evidence output already exists.' }
if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
$stream = [IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
$merged
