[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$BaseCommit,
    [Parameter(Mandatory = $true)][string]$HeadCommit,
    [string]$RegistryPath,
    [ValidateSet('Quick', 'Standard', 'Deep')][string]$Tier = 'Quick',
    [Parameter(Mandatory = $true)][string]$OutPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($RegistryPath)) { $RegistryPath = Join-Path $root 'manifests/affected-validation-registry.json' }
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
$plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $root -BaseRevision $BaseCommit -HeadRevision $HeadCommit -RegistryPath $RegistryPath -RequestedTier $Tier.ToLowerInvariant()
$planSchema = Join-Path $root 'schemas/affected-validation-plan-v1.schema.json'
if (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $plan) -SchemaFile $planSchema -ErrorAction Stop)) { throw 'Affected-validation plan fails its closed schema.' }
$output = [System.IO.Path]::GetFullPath($OutPath)
$parent = [System.IO.Path]::GetDirectoryName($output)
if (-not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
if ([System.IO.File]::Exists($output)) { throw "Affected-validation output already exists: $output" }
$bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $plan) + "`n")
$pending = "$output.pending-$([guid]::NewGuid().ToString('N'))"
$stream = [System.IO.FileStream]::new($pending, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
try { [System.IO.File]::Move($pending, $output) } catch { throw "Affected-validation atomic publication failed; pending bytes are preserved at '$pending': $($_.Exception.Message)" }
$plan
