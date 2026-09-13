Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-MorphospaceGitOutput {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git -C $RepositoryPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Git command failed in '$RepositoryPath': git $($Arguments -join ' ')"
    }
    return [pscustomobject]@{ exit_code = $exitCode; lines = @($output); text = ($output -join [Environment]::NewLine).Trim() }
}

function Get-MorphospaceRepositoryState {
    param(
        [Parameter(Mandatory = $true)][string]$RepoId,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject][ordered]@{
            repo_id = $RepoId; path = $Path; available = $false; is_git = $false
            head = $null; tree = $null; branch = $null; upstream = $null; dirty = $null
            tracked_changes = $null; untracked_changes = $null; ahead = $null
            behind = $null; diverged = $null; relation = "missing"; status_porcelain = @()
        }
    }

    $inside = Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "--is-inside-work-tree") -AllowFailure
    if ($inside.exit_code -ne 0 -or $inside.text -ne "true") {
        return [pscustomobject][ordered]@{
            repo_id = $RepoId; path = $Path; available = $true; is_git = $false
            head = $null; tree = $null; branch = $null; upstream = $null; dirty = $null
            tracked_changes = $null; untracked_changes = $null; ahead = $null
            behind = $null; diverged = $null; relation = "not-git"; status_porcelain = @()
        }
    }

    $head = (Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "HEAD")).text
    $tree = (Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "HEAD^{tree}")).text
    $branchResult = Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
    $branch = if ($branchResult.exit_code -eq 0) { $branchResult.text } else { $null }
    $upstreamResult = Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}") -AllowFailure
    $upstream = if ($upstreamResult.exit_code -eq 0) { $upstreamResult.text } else { $null }
    $status = Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    $statusLines = @($status.lines | ForEach-Object { [string]$_ })
    $tracked = @($statusLines | Where-Object { -not $_.StartsWith("??") }).Count
    $untracked = @($statusLines | Where-Object { $_.StartsWith("??") }).Count
    $ahead = $null
    $behind = $null
    $relation = if ($null -eq $branch) { "detached" } elseif ($null -eq $upstream) { "no-upstream" } else { "unknown" }
    if ($upstream) {
        $counts = (Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-list", "--left-right", "--count", "HEAD...@{upstream}")).text -split "\s+"
        if ($counts.Count -ne 2) { throw "Unexpected ahead/behind output for '$RepoId'." }
        $ahead = [int]$counts[0]
        $behind = [int]$counts[1]
        if ($ahead -gt 0 -and $behind -gt 0) { $relation = "diverged" }
        elseif ($ahead -gt 0) { $relation = "ahead" }
        elseif ($behind -gt 0) { $relation = "behind" }
        else { $relation = "synchronized" }
    }

    return [pscustomobject][ordered]@{
        repo_id = $RepoId
        path = (Resolve-Path -LiteralPath $Path).Path
        available = $true
        is_git = $true
        head = $head
        tree = $tree
        branch = $branch
        upstream = $upstream
        dirty = ($statusLines.Count -gt 0)
        tracked_changes = $tracked
        untracked_changes = $untracked
        ahead = $ahead
        behind = $behind
        diverged = ($relation -eq "diverged")
        relation = $relation
        status_porcelain = $statusLines
    }
}

Export-ModuleMember -Function Get-MorphospaceGitOutput,Get-MorphospaceRepositoryState
