param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$inspector = Join-Path $PSScriptRoot "Inspect-LocalWorktreeIndex.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("local-worktree-index-" + [guid]::NewGuid().ToString("N"))
$repo = Join-Path $temp "source"
$worktree = Join-Path $temp "registered-worktree"
$missing = Join-Path $temp "missing-repository"

function Invoke-TestGit {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git -C $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return @($output)
}

function Write-Utf8 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Label)
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "$Label was accepted unexpectedly." }
}

New-Item -ItemType Directory -Path $temp | Out-Null
try {
    & git init -b main $repo | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to initialize fixture repository." }
    Invoke-TestGit -Path $repo -Arguments @("config", "user.email", "fixture@example.invalid") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("config", "user.name", "Worktree Index Fixture") | Out-Null
    Write-Utf8 -Path (Join-Path $repo "tracked.txt") -Text "base`n"
    Invoke-TestGit -Path $repo -Arguments @("add", "tracked.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "base") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("worktree", "add", "--detach", $worktree, "HEAD") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("worktree", "lock", "--reason", "fixture lock", $worktree) | Out-Null
    Write-Utf8 -Path (Join-Path $repo "untracked.txt") -Text "preserve me`n"

    $registryPath = Join-Path $temp "registry.json"
    $registry = [ordered]@{
        repositories = @(
            [ordered]@{ repo_id = "fixture-repository"; repository_root = $repo },
            [ordered]@{ repo_id = "missing-repository"; repository_root = $missing }
        )
    }
    Write-Utf8 -Path $registryPath -Text ($registry | ConvertTo-Json -Depth 10)

    $beforeRefs = @(Invoke-TestGit -Path $repo -Arguments @("show-ref")) -join "`n"
    $beforeWorktrees = @(Invoke-TestGit -Path $repo -Arguments @("worktree", "list", "--porcelain")) -join "`n"
    $beforeStatus = @(Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n"

    $json = @(& $inspector -RegistryPath $registryPath) -join "`n"
    $result = $json | ConvertFrom-Json -Depth 30
    Assert-True ($result.schema -ceq "rusty.morphospace.workflow.fast_local_worktree_index.v1") "Wrong index schema."
    Assert-True ($result.execution -ceq "not-performed" -and $result.tier -ceq "registration-index") "Index overstated execution or tier."
    Assert-True (-not $result.git_mutation_performed -and -not $result.source_or_worktree_mutation_performed -and -not $result.remote_mutation_performed) "Index claimed mutation."
    Assert-True ($result.network_calls -eq 0 -and $result.source_status_reads -eq 0 -and $result.ignored_path_reads -eq 0) "Index performed or claimed a deep check."
    Assert-True ($result.summary.repository_count -eq 2 -and $result.summary.accessible_repository_count -eq 1 -and $result.summary.errored_repository_count -eq 1) "Repository summary is incorrect: $($result.summary | ConvertTo-Json -Compress); repositories=$($result.repositories | ConvertTo-Json -Depth 5 -Compress)."
    Assert-True ($result.summary.worktree_count -eq 2 -and $result.summary.accessible_worktree_count -eq 2 -and $result.summary.detached_worktree_count -eq 1 -and $result.summary.locked_worktree_count -eq 1) "Worktree summary is incorrect."
    $canonical = @($result.worktrees | Where-Object canonical_checkout)
    $detached = @($result.worktrees | Where-Object detached)
    Assert-True ($canonical.Count -eq 1 -and $detached.Count -eq 1 -and $detached[0].locked -and $detached[0].locked_reason -ceq "fixture lock") "Worktree fields are incorrect."
    Assert-True (@(Invoke-TestGit -Path $repo -Arguments @("show-ref")) -join "`n" -ceq $beforeRefs) "Index mutated refs."
    Assert-True (@(Invoke-TestGit -Path $repo -Arguments @("worktree", "list", "--porcelain")) -join "`n" -ceq $beforeWorktrees) "Index mutated worktree registrations."
    Assert-True (@(Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n" -ceq $beforeStatus) "Index mutated source bytes."

    $outPath = Join-Path $temp "index.json"
    & $inspector -RegistryPath $registryPath -OutPath $outPath | Out-Null
    Assert-True (Test-Path -LiteralPath $outPath -PathType Leaf) "Optional output was not written."
    $written = Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json -Depth 30
    Assert-True ($written.summary.worktree_count -eq 2) "Written output is invalid."
    Assert-Rejected { & $inspector -RegistryPath $registryPath -OutPath $outPath } "Output overwrite"

    $customPath = Join-Path $temp "custom-registry.json"
    $custom = @([ordered]@{ repository = "fixture-custom"; local_repository = $repo })
    Write-Utf8 -Path $customPath -Text ($custom | ConvertTo-Json -Depth 10 -AsArray)
    $customResult = (@(& $inspector -RegistryPath $customPath -RepositoryIdProperty repository -RepositoryPathProperty local_repository) -join "`n") | ConvertFrom-Json -Depth 30
    Assert-True ($customResult.summary.repository_count -eq 1 -and $customResult.repositories[0].repo_id -ceq "fixture-custom") "Top-level registry array or custom registry properties failed."

    $duplicatePath = Join-Path $temp "duplicate-registry.json"
    $duplicate = [ordered]@{ repositories = @([ordered]@{ repo_id = "duplicate"; repository_root = $repo }, [ordered]@{ repo_id = "duplicate"; repository_root = $repo }) }
    Write-Utf8 -Path $duplicatePath -Text ($duplicate | ConvertTo-Json -Depth 10)
    Assert-Rejected { & $inspector -RegistryPath $duplicatePath } "Duplicate repository ID"

    Write-Output "Fast local worktree index self-test passed (registration identity, detached/locked state, inaccessible root, top-level/custom registry, overwrite rejection, zero deep checks, and no Git/source mutation)."
} finally {
    if (Test-Path -LiteralPath $repo -PathType Container) {
        & git -C $repo worktree unlock $worktree 2>$null | Out-Null
        & git -C $repo worktree remove $worktree --force 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
