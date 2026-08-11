[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RegistryPath,
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')][string]$RepositoryIdProperty = "repo_id",
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')][string]$RepositoryPathProperty = "repository_root",
    [string]$OutPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

function Invoke-IndexGit {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $priorOptionalLocks = [Environment]::GetEnvironmentVariable("GIT_OPTIONAL_LOCKS")
    $priorExternalDiff = [Environment]::GetEnvironmentVariable("GIT_EXTERNAL_DIFF")
    try {
        $env:GIT_OPTIONAL_LOCKS = "0"
        Remove-Item Env:GIT_EXTERNAL_DIFF -ErrorAction SilentlyContinue
        $output = @(& git -C $Repository @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $priorOptionalLocks) {
            Remove-Item Env:GIT_OPTIONAL_LOCKS -ErrorAction SilentlyContinue
        } else {
            $env:GIT_OPTIONAL_LOCKS = $priorOptionalLocks
        }
        if ($null -eq $priorExternalDiff) {
            Remove-Item Env:GIT_EXTERNAL_DIFF -ErrorAction SilentlyContinue
        } else {
            $env:GIT_EXTERNAL_DIFF = $priorExternalDiff
        }
    }
    if ($exitCode -ne 0) {
        throw "Read-only Git command failed ($exitCode): git -C '<repository>' $($Arguments -join ' '): $($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Convert-ToPortablePath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path).Replace('\', '/').TrimEnd('/')
}

function Test-SameLocalPath {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals((Convert-ToPortablePath $Left), (Convert-ToPortablePath $Right), $comparison)
}

function Convert-WorktreePorcelain {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    $records = [Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in @($Lines) + "") {
        if ([string]::IsNullOrEmpty($line)) {
            if ($null -ne $current) {
                $records.Add([pscustomobject]$current) | Out-Null
                $current = $null
            }
            continue
        }
        if ($line.StartsWith("worktree ", [StringComparison]::Ordinal)) {
            if ($null -ne $current) { throw "Malformed Git worktree record: missing separator." }
            $current = [ordered]@{
                path = $line.Substring(9).Replace('\', '/')
                head = $null
                branch_ref = $null
                detached = $false
                bare = $false
                prunable = $false
                prunable_reason = $null
                locked = $false
                locked_reason = $null
            }
        } elseif ($null -eq $current) {
            throw "Malformed Git worktree record: field before worktree path."
        } elseif ($line.StartsWith("HEAD ", [StringComparison]::Ordinal)) {
            $current.head = $line.Substring(5)
        } elseif ($line.StartsWith("branch ", [StringComparison]::Ordinal)) {
            $current.branch_ref = $line.Substring(7)
        } elseif ($line -ceq "detached") {
            $current.detached = $true
        } elseif ($line -ceq "bare") {
            $current.bare = $true
        } elseif ($line.StartsWith("prunable", [StringComparison]::Ordinal)) {
            $current.prunable = $true
            $current.prunable_reason = $line.Substring(8).Trim()
        } elseif ($line.StartsWith("locked", [StringComparison]::Ordinal)) {
            $current.locked = $true
            $current.locked_reason = $line.Substring(6).Trim()
        }
    }
    return $records.ToArray()
}

$resolvedRegistryPath = (Resolve-Path -LiteralPath $RegistryPath).Path
$registryText = Get-Content -LiteralPath $resolvedRegistryPath -Raw
$registry = $registryText | ConvertFrom-Json -Depth 100
$repositoryEntries = if ($registry -is [Array]) {
    @($registry)
} elseif ($null -ne $registry.PSObject.Properties["repositories"] -and $null -ne $registry.repositories) {
    @($registry.repositories)
} elseif ($null -ne $registry.PSObject.Properties[$RepositoryIdProperty] -and $null -ne $registry.PSObject.Properties[$RepositoryPathProperty]) {
    @($registry)
} else {
    throw "Registry must be a repository row, an array, or contain a repositories array."
}

$registryDirectory = Split-Path -Parent $resolvedRegistryPath
$seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$repositoryRows = [Collections.Generic.List[object]]::new()
$worktreeRows = [Collections.Generic.List[object]]::new()

foreach ($repository in $repositoryEntries) {
    $idProperty = $repository.PSObject.Properties[$RepositoryIdProperty]
    $pathProperty = $repository.PSObject.Properties[$RepositoryPathProperty]
    if ($null -eq $idProperty -or [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
        throw "Every repository must define non-empty '$RepositoryIdProperty'."
    }
    if ($null -eq $pathProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
        throw "Repository '$($idProperty.Value)' must define non-empty '$RepositoryPathProperty'."
    }
    $repoId = [string]$idProperty.Value
    if (-not $seenIds.Add($repoId)) { throw "Duplicate repository ID '$repoId'." }
    $configuredRoot = [string]$pathProperty.Value
    $absoluteRoot = if ([IO.Path]::IsPathFullyQualified($configuredRoot)) {
        [IO.Path]::GetFullPath($configuredRoot)
    } else {
        [IO.Path]::GetFullPath((Join-Path $registryDirectory $configuredRoot))
    }
    $row = [ordered]@{
        repo_id = $repoId
        configured_root = $absoluteRoot.Replace('\', '/')
        accessible = $false
        common_dir = $null
        worktree_count = 0
        worktree_list_sha256 = $null
        local_branch_count = $null
        error = $null
    }
    if (-not (Test-Path -LiteralPath $absoluteRoot -PathType Container)) {
        $row.error = "repository_root_missing"
        $repositoryRows.Add([pscustomobject]$row) | Out-Null
        continue
    }
    try {
        $inside = @(Invoke-IndexGit -Repository $absoluteRoot -Arguments @("rev-parse", "--is-inside-work-tree"))
        if ($inside.Count -ne 1 -or $inside[0] -cne "true") { throw "Configured root is not a Git worktree." }
        $commonLines = @(Invoke-IndexGit -Repository $absoluteRoot -Arguments @("rev-parse", "--path-format=absolute", "--git-common-dir"))
        if ($commonLines.Count -ne 1) { throw "Git returned an invalid common-dir record." }
        $commonDir = $commonLines[0].Replace('\', '/')
        $worktreeLines = @(Invoke-IndexGit -Repository $absoluteRoot -Arguments @("worktree", "list", "--porcelain"))
        $worktreeText = ($worktreeLines -join "`n") + "`n"
        $worktrees = @(Convert-WorktreePorcelain -Lines $worktreeLines)
        $branchLines = @(Invoke-IndexGit -Repository $absoluteRoot -Arguments @("for-each-ref", "--format=%(refname)", "refs/heads"))

        $row.accessible = $true
        $row.common_dir = $commonDir
        $row.worktree_count = $worktrees.Count
        $row.worktree_list_sha256 = Get-Sha256Text -Text $worktreeText
        $row.local_branch_count = @($branchLines | Where-Object { $_ }).Count

        foreach ($worktree in $worktrees) {
            $worktreeRows.Add([pscustomobject][ordered]@{
                repo_id = $repoId
                canonical_checkout = Test-SameLocalPath -Left $worktree.path -Right $absoluteRoot
                common_dir = $commonDir
                path = $worktree.path
                accessible = Test-Path -LiteralPath $worktree.path -PathType Container
                head = $worktree.head
                branch_ref = $worktree.branch_ref
                detached = $worktree.detached
                bare = $worktree.bare
                prunable = $worktree.prunable
                prunable_reason = $worktree.prunable_reason
                locked = $worktree.locked
                locked_reason = $worktree.locked_reason
            }) | Out-Null
        }
    } catch {
        $row.error = $_.Exception.Message
    }
    $repositoryRows.Add([pscustomobject]$row) | Out-Null
}

$stopwatch.Stop()
$result = [ordered]@{
    schema = "rusty.morphospace.workflow.fast_local_worktree_index.v1"
    observed_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    execution = "not-performed"
    tier = "registration-index"
    git_mutation_performed = $false
    source_or_worktree_mutation_performed = $false
    remote_mutation_performed = $false
    network_calls = 0
    source_status_reads = 0
    ignored_path_reads = 0
    elapsed_milliseconds = $stopwatch.ElapsedMilliseconds
    registry = [ordered]@{
        path = $resolvedRegistryPath.Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $resolvedRegistryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        repository_id_property = $RepositoryIdProperty
        repository_path_property = $RepositoryPathProperty
    }
    repositories = $repositoryRows.ToArray()
    worktrees = $worktreeRows.ToArray()
    summary = [ordered]@{
        repository_count = $repositoryRows.Count
        accessible_repository_count = @($repositoryRows | Where-Object accessible).Count
        errored_repository_count = @($repositoryRows | Where-Object { $null -ne $_.error }).Count
        worktree_count = $worktreeRows.Count
        accessible_worktree_count = @($worktreeRows | Where-Object accessible).Count
        inaccessible_worktree_count = @($worktreeRows | Where-Object { -not $_.accessible }).Count
        detached_worktree_count = @($worktreeRows | Where-Object detached).Count
        prunable_worktree_count = @($worktreeRows | Where-Object prunable).Count
        locked_worktree_count = @($worktreeRows | Where-Object locked).Count
    }
}
$json = ($result | ConvertTo-Json -Depth 20).Replace("`r`n", "`n") + "`n"

if ($OutPath) {
    $fullOutPath = [IO.Path]::GetFullPath($OutPath)
    $parent = Split-Path -Parent $fullOutPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output parent does not exist: $parent" }
    if (Test-Path -LiteralPath $fullOutPath) { throw "Refusing to overwrite local worktree index: $fullOutPath" }
    [IO.File]::WriteAllText($fullOutPath, $json, [Text.UTF8Encoding]::new($false))
}

Write-Output $json
