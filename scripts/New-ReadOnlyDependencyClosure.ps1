param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$RepositoryMapPath,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Read-ClosureJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { throw "Required JSON file is missing: $Path" }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { throw "Invalid JSON in '$Path': $($_.Exception.Message)" }
}

function Resolve-ClosurePath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Relative)
    $normalized = ConvertTo-MorphospaceProtocolRelativePath -Path $Relative
    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $normalized))
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Dependency path escapes its repository: $Relative" }
    return $candidate
}

function Get-ClosureGit {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $lines = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Git query failed in '$Root': git $($Arguments -join ' ')" }
    return @($lines | ForEach-Object { [string]$_ })
}

function Get-ClosureBlob {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Specifier)
    $lines = @(& git -C $Root rev-parse --verify --quiet $Specifier 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace($lines[0])) { return $null }
    $value = $lines[0].Trim().ToLowerInvariant()
    if ($value -notmatch '^[0-9a-f]{40}$') { throw "Git returned an invalid blob identifier for '$Specifier'." }
    return $value
}

function Get-ClosureFiles {
    param([Parameter(Mandatory = $true)][string]$RepoRoot, [Parameter(Mandatory = $true)][string]$DeclaredPath)
    $directoryScope = $DeclaredPath.EndsWith('/') -or $DeclaredPath.EndsWith('\\')
    $relative = ConvertTo-MorphospaceProtocolRelativePath -Path $DeclaredPath.TrimEnd('\', '/')
    $absolute = Resolve-ClosurePath -Root $RepoRoot -Relative $relative
    $rows = [Collections.Generic.List[string]]::new()
    if ($directoryScope) {
        if (-not [IO.Directory]::Exists($absolute)) { throw "Declared dependency directory is missing: $relative" }
        foreach ($entry in [IO.Directory]::EnumerateFiles($absolute, '*', [IO.SearchOption]::AllDirectories)) {
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Declared dependency contains a reparse-point file: $entry" }
            $rows.Add(([IO.Path]::GetRelativePath($RepoRoot, $entry)).Replace('\', '/')) | Out-Null
        }
    } else {
        if (-not [IO.File]::Exists($absolute)) { throw "Declared dependency file is missing: $relative" }
        $attributes = [IO.File]::GetAttributes($absolute)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Declared dependency is a reparse point: $relative" }
        $rows.Add($relative) | Out-Null
    }
    return @($rows.ToArray() | Sort-Object -Unique)
}

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$outAbsolute = [IO.Path]::GetFullPath($OutPath)
$workspacePrefix = $workspace.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $outAbsolute.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Closure output must stay inside the project workspace.' }
$outRelative = $outAbsolute.Substring($workspacePrefix.Length).Replace('\', '/')
if (-not $outRelative.StartsWith('dependency-closures/', [StringComparison]::OrdinalIgnoreCase)) { throw 'Closure output must use dependency-closures/.' }
if (-not $Execute) { throw 'Use -Execute to create the immutable closure artifact.' }

$spec = Read-ClosureJson -Path (Join-Path $workspace 'project.spec.json')
$unit = Read-ClosureJson -Path (Join-Path $workspace (Join-Path 'iteration-units' "$UnitId.json"))
$map = Read-ClosureJson -Path $RepositoryMapPath
if ([string]$unit.project_id -ne [string]$spec.project_id -or [string]$unit.unit_id -ne $UnitId) { throw 'Project and unit identity do not agree.' }
if (-not ($unit.PSObject.Properties.Name -contains 'read_only_dependencies') -or @($unit.read_only_dependencies).Count -eq 0) { throw 'Unit has no declared read-only dependencies.' }
$mapById = @{}
foreach ($repo in @($map.repositories)) { $mapById[[string]$repo.repo_id] = $repo }

$dependencies = [Collections.Generic.List[object]]::new()
foreach ($dependency in @($unit.read_only_dependencies | Sort-Object repo_id)) {
    $repoId = [string]$dependency.repo_id
    if (-not $mapById.ContainsKey($repoId)) { throw "Read-only dependency '$repoId' is not mapped." }
    $repoRoot = [IO.Path]::GetFullPath([string]$mapById[$repoId].path)
    if (-not [IO.Directory]::Exists($repoRoot)) { throw "Read-only dependency repository is missing: $repoId" }
    $head = ([string](@(Get-ClosureGit -Root $repoRoot -Arguments @('rev-parse', 'HEAD'))[0])).Trim().ToLowerInvariant()
    $branch = ([string](@(Get-ClosureGit -Root $repoRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD'))[0])).Trim()
    if ($head -notmatch '^[0-9a-f]{40}$' -or [string]::IsNullOrWhiteSpace($branch)) { throw "Read-only dependency repository has no exact Git identity: $repoId" }
    $files = [Collections.Generic.List[object]]::new()
    foreach ($declaredPath in @($dependency.paths | Sort-Object)) {
        foreach ($relative in @(Get-ClosureFiles -RepoRoot $repoRoot -DeclaredPath ([string]$declaredPath))) {
            $absolute = Resolve-ClosurePath -Root $repoRoot -Relative $relative
            $index = @(Get-ClosureGit -Root $repoRoot -Arguments @('ls-files', '--stage', '--', $relative))
            $indexBlob = if ($index.Count -eq 0) { $null } elseif ($index[0] -match '^[0-7]+\s+([0-9a-f]{40})\s+[0-3]\t') { $Matches[1].ToLowerInvariant() } else { throw "Could not parse Git index row for '$relative'." }
            $headBlob = Get-ClosureBlob -Root $repoRoot -Specifier ("HEAD:" + $relative)
            $status = @(Get-ClosureGit -Root $repoRoot -Arguments @('status', '--porcelain=v1', '--untracked-files=all', '--', $relative))
            $info = [IO.FileInfo]::new($absolute)
            $files.Add([pscustomobject][ordered]@{
                path = $relative; length = [long]$info.Length; worktree_sha256 = Get-MorphospaceFileSha256 -Path $absolute
                index_blob_sha256 = $indexBlob; head_blob_sha256 = $headBlob; status_porcelain = @($status | Sort-Object)
            }) | Out-Null
        }
    }
    $orderedFiles = @($files.ToArray() | Sort-Object path)
    if ($orderedFiles.Count -eq 0) { throw "Read-only dependency '$repoId' resolved to no files." }
    $dependencies.Add([pscustomobject][ordered]@{
        repo_id = $repoId; purpose = [string]$dependency.purpose; verification = [string]$dependency.verification
        head = $head; branch = $branch; files = $orderedFiles
    }) | Out-Null
}

$closure = [pscustomobject][ordered]@{
    schema = 'rusty.morphospace.workflow.read_only_dependency_closure.v1'
    closure_id = "$UnitId-read-only-dependencies"
    captured_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    project_id = [string]$spec.project_id
    unit_id = $UnitId
    dependencies = @($dependencies.ToArray())
    status = 'captured'
    does_not_prove = @('Does not claim, adopt, modify, validate changed paths for, or authorize a release from any dependency repository.', 'Does not accept central WF-005 or any downstream unit.')
}
Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath $outRelative -Value $closure -NoOverwrite
$closure | ConvertTo-Json -Depth 32
