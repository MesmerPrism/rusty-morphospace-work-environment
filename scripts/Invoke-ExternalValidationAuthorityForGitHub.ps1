param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$PullRequestNumber,
    [Parameter(Mandatory = $true)][string]$BaseCommit,
    [Parameter(Mandatory = $true)][string]$HeadCommit,
    [string]$MergeCommit = "",
    [Parameter(Mandatory = $true)][string]$PinnedVerifierCommit,
    [Parameter(Mandatory = $true)][string]$PinnedVerifierTree,
    [Parameter(Mandatory = $true)][string]$PinnedVerifierPath,
    [Parameter(Mandatory = $true)][string]$PinnedVerifierSha256,
    [string]$PolicyPath = "config/external-validation-authority.json",
    [string]$RemoteUrl = "",
    [switch]$AllowLocalTestRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$GitCommandTimeoutSeconds = 60
$MaximumVerifierBytes = 1048576
$ForbiddenGitEnvironmentVariables = @(
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CEILING_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_SYSTEM",
    "GIT_DIFF_OPTS",
    "GIT_DIR",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    "GIT_GLOB_PATHSPECS",
    "GIT_ICASE_PATHSPECS",
    "GIT_INDEX_FILE",
    "GIT_LITERAL_PATHSPECS",
    "GIT_NAMESPACE",
    "GIT_NOGLOB_PATHSPECS",
    "GIT_OBJECT_DIRECTORY",
    "GIT_QUARANTINE_PATH",
    "GIT_REPLACE_REF_BASE",
    "GIT_SHALLOW_FILE",
    "GIT_WORK_TREE"
)

function Test-ForbiddenGitEnvironmentName {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($ForbiddenGitEnvironmentVariables -icontains $Name) {
        return $true
    }
    return (
        $Name.StartsWith("GIT_CONFIG_KEY_", [StringComparison]::OrdinalIgnoreCase) -or
        $Name.StartsWith("GIT_CONFIG_VALUE_", [StringComparison]::OrdinalIgnoreCase)
    )
}

function Assert-CleanGitProcessEnvironment {
    $present = @(
        Get-ChildItem Env: |
            Where-Object { Test-ForbiddenGitEnvironmentName ([string]$_.Name) } |
            ForEach-Object { [string]$_.Name } |
            Sort-Object -CaseSensitive
    )
    if ($present.Count -ne 0) {
        throw (
            "Ambient Git repository/object-store environment is forbidden: " +
            ($present -join ", ")
        )
    }
}

function Assert-FullCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Value -cnotmatch "^(?:[0-9a-f]{40}|[0-9a-f]{64})$") {
        throw "$Label is not a lowercase full commit identity."
    }
}

function Assert-PortableRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (
        [string]::IsNullOrWhiteSpace($Path) -or
        $Path.Length -gt 512 -or
        [IO.Path]::IsPathRooted($Path) -or
        $Path.Contains("\") -or
        $Path.Contains(":") -or
        $Path -match "[\x00-\x1f\x7f]"
    ) {
        throw "$Label is not a portable relative path: $Path"
    }
    $segments = @($Path.Split("/"))
    if (
        $segments.Count -eq 0 -or
        @($segments | Where-Object {
            [string]::IsNullOrEmpty($_) -or $_ -in @(".", "..")
        }).Count -ne 0
    ) {
        throw "$Label contains an empty or traversal segment: $Path"
    }
}

function New-GitStartInfo {
    param([Parameter(Mandatory = $true)][string]$Root)

    $git = @(
        Get-Command git -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    )[0].Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $git
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    $start.Environment["GIT_OPTIONAL_LOCKS"] = "0"
    $start.Environment["GIT_LFS_SKIP_SMUDGE"] = "1"
    $start.Environment["GIT_TERMINAL_PROMPT"] = "0"
    $start.Environment["LC_ALL"] = "C"
    $start.Environment["LANG"] = "C"
    foreach ($name in @($start.Environment.Keys)) {
        if (Test-ForbiddenGitEnvironmentName ([string]$name)) {
            [void]$start.Environment.Remove([string]$name)
        }
    }
    $disabledHooks = Join-Path $Root ".git/codex-static-admission-disabled-hooks"
    foreach ($argument in @(
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=$disabledHooks",
        "-c",
        "credential.helper=",
        "-C",
        $Root
    )) {
        [void]$start.ArgumentList.Add($argument)
    }
    return $start
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = $GitCommandTimeoutSeconds
    )

    $start = New-GitStartInfo $Root
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                }
                [void]$process.WaitForExit(5000)
            } catch {}
            throw "Git command timed out after $TimeoutSeconds seconds."
        }
        $result = [pscustomobject]@{
            exit_code = [int]$process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
    if (-not $AllowFailure -and $result.exit_code -ne 0) {
        $detail = ($result.stderr + "`n" + $result.stdout).Trim()
        if ($detail.Length -gt 2048) {
            $detail = $detail.Substring($detail.Length - 2048)
        }
        throw "Git command failed ($($Arguments -join ' ')): $detail"
    }
    return $result
}

function Invoke-GitBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(1, 1048576)][int]$MaximumBytes = $MaximumVerifierBytes
    )

    $start = New-GitStartInfo $Root
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $memory = [IO.MemoryStream]::new()
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        [byte[]]$buffer = [byte[]]::new(8192)
        while ($true) {
            $count = $process.StandardOutput.BaseStream.Read(
                $buffer,
                0,
                $buffer.Length
            )
            if ($count -eq 0) {
                break
            }
            if ($memory.Length + $count -gt $MaximumBytes) {
                try {
                    if (-not $process.HasExited) {
                        $process.Kill($true)
                    }
                    [void]$process.WaitForExit(5000)
                } catch {}
                throw "Git byte command exceeded the $MaximumBytes-byte bound."
            }
            $memory.Write($buffer, 0, $count)
        }
        if (-not $process.WaitForExit($GitCommandTimeoutSeconds * 1000)) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                }
                [void]$process.WaitForExit(5000)
            } catch {}
            throw "Git byte command timed out."
        }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Git byte command failed: $($stderr.Trim())"
        }
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Get-GitCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $resolved = (
        Invoke-Git $Root @("rev-parse", "--verify", "${Revision}^{commit}")
    ).stdout.Trim()
    if ($resolved -cne $Revision) {
        throw "$Label does not equal its declared commit identity."
    }
    return $resolved
}

function Get-GitTreeEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $line = (Invoke-Git $Root @("ls-tree", $Commit, "--", $Path)).stdout.TrimEnd()
    if ([string]::IsNullOrEmpty($line) -or $line.Contains("`n")) {
        throw "Pinned verifier tree entry is absent or ambiguous."
    }
    if ($line -cnotmatch "^(100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64})`t(.+)$") {
        throw "Pinned verifier tree entry is not a regular file."
    }
    if ($Matches[3] -cne $Path) {
        throw "Pinned verifier tree entry path does not match its declaration."
    }
    return [pscustomobject]@{
        mode = [string]$Matches[1]
        object_id = [string]$Matches[2]
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

Assert-CleanGitProcessEnvironment
if ($Repository -cnotmatch "^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$") {
    throw "Repository identity is malformed."
}
if (
    $PullRequestNumber -cnotmatch "^[1-9][0-9]{0,9}$" -or
    [uint64]$PullRequestNumber -gt [uint64][int]::MaxValue
) {
    throw "Pull request number is malformed or outside its bound."
}
Assert-FullCommit $BaseCommit "Base commit"
Assert-FullCommit $HeadCommit "Head commit"
if (-not [string]::IsNullOrEmpty($MergeCommit)) {
    Assert-FullCommit $MergeCommit "Merge commit"
}
Assert-FullCommit $PinnedVerifierCommit "Pinned verifier commit"
Assert-FullCommit $PinnedVerifierTree "Pinned verifier tree"
if ($PinnedVerifierSha256 -cnotmatch "^[0-9a-f]{64}$") {
    throw "Pinned verifier SHA-256 is malformed."
}
Assert-PortableRelativePath $PinnedVerifierPath "pinned verifier path"
Assert-PortableRelativePath $PolicyPath "policy path"

$trusted = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).Path)
$headRef = "refs/codex/static-admission/pr-$PullRequestNumber/head"
$mergeRef = "refs/codex/static-admission/pr-$PullRequestNumber/merge"
$expectedRemote = "https://github.com/$Repository.git"
if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    $RemoteUrl = $expectedRemote
}
if (-not $AllowLocalTestRemote -and $RemoteUrl -cne $expectedRemote) {
    throw "Production static admission requires the exact public HTTPS repository URL."
}
if ($AllowLocalTestRemote -and [string]::IsNullOrWhiteSpace($RemoteUrl)) {
    throw "A local self-test remote must be explicit."
}

$headBeforeFetch = (Invoke-Git $trusted @("rev-parse", "HEAD")).stdout.Trim()
if ($headBeforeFetch -cne $BaseCommit) {
    throw "Trusted checkout HEAD does not equal the event base commit."
}
$dirtyBeforeFetch = (Invoke-Git $trusted @(
    "status", "--porcelain=v1", "-z", "--untracked-files=all"
)).stdout
if ($dirtyBeforeFetch.Length -ne 0) {
    throw "Trusted checkout is dirty before candidate object fetch."
}
$shallow = (Invoke-Git $trusted @("rev-parse", "--is-shallow-repository")).stdout.Trim()
if ($shallow -cne "false") {
    throw "Trusted checkout must be a complete non-shallow repository."
}

[void](Invoke-Git $trusted @(
    "fetch",
    "--force",
    "--no-tags",
    "--no-recurse-submodules",
    "--no-write-fetch-head",
    "--upload-pack=git-upload-pack",
    $RemoteUrl,
    "+refs/pull/$PullRequestNumber/head:$headRef",
    "+refs/pull/$PullRequestNumber/merge:$mergeRef"
))
$fetchedHead = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${headRef}^{commit}")
).stdout.Trim()
$fetchedMerge = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${mergeRef}^{commit}")
).stdout.Trim()
if ($fetchedHead -cne $HeadCommit) {
    throw "Fetched pull request head does not equal the event head commit."
}
if (
    -not [string]::IsNullOrEmpty($MergeCommit) -and
    $fetchedMerge -cne $MergeCommit
) {
    throw "Fetched pull request merge does not equal the event merge commit."
}
$mergeIdentity = (
    Invoke-Git $trusted @("rev-list", "--parents", "-n", "1", $fetchedMerge)
).stdout.Trim().Split(" ", [StringSplitOptions]::RemoveEmptyEntries)
if (
    $mergeIdentity.Count -ne 3 -or
    $mergeIdentity[0] -cne $fetchedMerge -or
    $mergeIdentity[1] -cne $BaseCommit -or
    $mergeIdentity[2] -cne $HeadCommit
) {
    throw "Pull request merge must have the exact ordered event base and head parents."
}
$headTree = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${HeadCommit}^{tree}")
).stdout.Trim()
$mergeTree = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${fetchedMerge}^{tree}")
).stdout.Trim()
if ($mergeTree -cne $headTree) {
    throw "Pull request merge tree does not equal the exact event head tree."
}

$headAfterFetch = (Invoke-Git $trusted @("rev-parse", "HEAD")).stdout.Trim()
$dirtyAfterFetch = (Invoke-Git $trusted @(
    "status", "--porcelain=v1", "-z", "--untracked-files=all"
)).stdout
if ($headAfterFetch -cne $BaseCommit -or $dirtyAfterFetch.Length -ne 0) {
    throw "Candidate object fetch changed the trusted base checkout."
}

[void](Get-GitCommit $trusted $PinnedVerifierCommit "Pinned verifier commit")
$actualPinnedTree = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${PinnedVerifierCommit}^{tree}")
).stdout.Trim()
if ($actualPinnedTree -cne $PinnedVerifierTree) {
    throw "Pinned verifier tree does not equal its declared tree identity."
}
$pinIsBaseOwned = Invoke-Git $trusted @(
    "merge-base", "--is-ancestor", $PinnedVerifierCommit, $BaseCommit
) -AllowFailure
if ($pinIsBaseOwned.exit_code -ne 0) {
    throw "Pinned verifier commit is not an ancestor of the trusted base."
}
$pinnedEntry = Get-GitTreeEntry $trusted $PinnedVerifierCommit $PinnedVerifierPath
$baseEntry = Get-GitTreeEntry $trusted $BaseCommit $PinnedVerifierPath
if (
    $pinnedEntry.mode -cne $baseEntry.mode -or
    $pinnedEntry.object_id -cne $baseEntry.object_id
) {
    throw "Trusted base verifier entry does not equal the pinned verifier entry."
}
$verifierBytes = Invoke-GitBytes $trusted @(
    "cat-file", "blob", [string]$pinnedEntry.object_id
)
if ((Get-Sha256 $verifierBytes) -cne $PinnedVerifierSha256) {
    throw "Pinned verifier bytes do not equal the declared SHA-256."
}

$verifierFullPath = [IO.Path]::GetFullPath((Join-Path $trusted $PinnedVerifierPath))
$trustedPrefix = $trusted.TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
if (-not $verifierFullPath.StartsWith($trustedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Pinned verifier entrypoint escapes the trusted checkout."
}
$verifierItem = Get-Item -LiteralPath $verifierFullPath -Force
if (
    $verifierItem.PSIsContainer -or
    ($verifierItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
) {
    throw "Pinned verifier entrypoint is not a regular checked-out file."
}

$assessmentJson = & $verifierFullPath `
    -RepositoryRoot $trusted `
    -PolicyPath $PolicyPath `
    -Repository $Repository `
    -BaseCommit $BaseCommit `
    -CandidateCommit $HeadCommit `
    -Json
$assessmentText = @($assessmentJson) -join "`n"
$assessment = $assessmentText | ConvertFrom-Json -Depth 30
if (
    [string]$assessment.repository -cne $Repository -or
    [string]$assessment.base.commit -cne $BaseCommit -or
    [string]$assessment.candidate.commit -cne $HeadCommit -or
    [bool]$assessment.candidate_code_executed -ne $false -or
    [bool]$assessment.execution_attested -ne $false -or
    [bool]$assessment.publication_authority -ne $false
) {
    throw "Base-owned verifier returned an inconsistent static assessment."
}

Write-Output $assessmentText
