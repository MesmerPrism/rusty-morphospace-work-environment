param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-GitTest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & git -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Test Git command failed ($($Arguments -join ' ')): $($output -join "`n")"
    }
    return (@($output) -join "`n").Trim()
}

function Write-Utf8 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent)
    }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Get-GitBlobBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ObjectId
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = @(
        Get-Command git -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    )[0].Source
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @("cat-file", "blob", $ObjectId)) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $memory = [IO.MemoryStream]::new()
    try {
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Test Git blob read failed: $stderr"
        }
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        & $Operation | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Label rejected for the wrong reason: $($_.Exception.Message)"
        }
        return
    }
    throw "$Label unexpectedly passed."
}

$temp = Join-Path (
    [IO.Path]::GetTempPath()
) ("external-authority-github-adapter-" + [guid]::NewGuid().ToString("N"))
$remoteRoot = Join-Path $temp "remote.git"
$seedRoot = Join-Path $temp "seed"
$trustedRoot = Join-Path $temp "trusted"
$markerPath = Join-Path $temp "candidate-executed.txt"
$adapter = Join-Path $PSScriptRoot "Invoke-ExternalValidationAuthorityForGitHub.ps1"
$repository = "example/static-admission-fixture"
$pullRequestNumber = "7"

try {
    [void](New-Item -ItemType Directory -Path $temp)
    [void](New-Item -ItemType Directory -Path $remoteRoot)
    [void](New-Item -ItemType Directory -Path $seedRoot)
    [void](Invoke-GitTest $remoteRoot @("init", "--bare"))
    [void](Invoke-GitTest $seedRoot @("init", "--initial-branch=main"))
    [void](Invoke-GitTest $seedRoot @("config", "user.name", "Static Admission Test"))
    [void](Invoke-GitTest $seedRoot @("config", "user.email", "static-admission@example.invalid"))
    [void](Invoke-GitTest $seedRoot @("config", "core.autocrlf", "false"))

    foreach ($directory in @("config", "schemas", "scripts")) {
        [void](New-Item -ItemType Directory -Path (Join-Path $seedRoot $directory))
    }
    Copy-Item -LiteralPath (
        Join-Path $PSScriptRoot "Test-ExternalValidationAuthority.ps1"
    ) -Destination (
        Join-Path $seedRoot "scripts/Test-ExternalValidationAuthority.ps1"
    )
    foreach ($schemaName in @(
        "external-validation-authority-assessment-v1.schema.json",
        "external-validation-authority-policy-v1.schema.json"
    )) {
        Copy-Item -LiteralPath (
            Join-Path (Split-Path -Parent $PSScriptRoot) "schemas/$schemaName"
        ) -Destination (Join-Path $seedRoot "schemas/$schemaName")
    }
    Write-Utf8 (Join-Path $seedRoot "config/external-validation-authority.json") @"
{
  "schema": "rusty.morphospace.workflow.external_validation_authority_policy.v1",
  "policy_id": "static-admission-fixture-v1",
  "repository": "$repository",
  "mandatory_protected_paths": [
    "config/external-validation-authority.json"
  ],
  "protected_rules": [
    {
      "rule_id": "protected-fixture",
      "match": "prefix",
      "path": "protected/"
    }
  ],
  "approved_change_sets": [],
  "status": "active"
}
"@
    [void](Invoke-GitTest $seedRoot @("add", "."))
    [void](Invoke-GitTest $seedRoot @("commit", "-m", "trusted base"))
    $baseCommit = Invoke-GitTest $seedRoot @("rev-parse", "HEAD")
    $baseTree = Invoke-GitTest $seedRoot @("rev-parse", "HEAD^{tree}")
    $verifierEntry = Invoke-GitTest $seedRoot @(
        "ls-tree", "HEAD", "--", "scripts/Test-ExternalValidationAuthority.ps1"
    )
    if ($verifierEntry -cnotmatch "^100644 blob ([0-9a-f]{40})`t") {
        throw "Fixture verifier blob entry is malformed."
    }
    $verifierSha256 = Get-Sha256 (Get-GitBlobBytes $seedRoot $Matches[1])
    [void](Invoke-GitTest $seedRoot @("remote", "add", "origin", $remoteRoot))
    [void](Invoke-GitTest $seedRoot @("push", "origin", "main"))

    [void](Invoke-GitTest $seedRoot @("checkout", "-b", "candidate"))
    $escapedMarker = $markerPath.Replace("'", "''")
    Write-Utf8 (Join-Path $seedRoot "candidate/never-run.ps1") (
        "[IO.File]::WriteAllText('$escapedMarker', 'executed')`n" +
        "throw 'Candidate code executed.'`n"
    )
    Write-Utf8 (Join-Path $seedRoot "docs/note.md") "ordinary unprotected change`n"
    [void](Invoke-GitTest $seedRoot @("add", "."))
    [void](Invoke-GitTest $seedRoot @("commit", "-m", "candidate"))
    $headCommit = Invoke-GitTest $seedRoot @("rev-parse", "HEAD")
    $headTree = Invoke-GitTest $seedRoot @("rev-parse", "HEAD^{tree}")
    $mergeCommit = Invoke-GitTest $seedRoot @(
        "commit-tree", $headTree, "-p", $baseCommit, "-p", $headCommit,
        "-m", "synthetic pull request merge"
    )
    [void](Invoke-GitTest $seedRoot @(
        "push", "origin",
        "${headCommit}:refs/pull/$pullRequestNumber/head",
        "${mergeCommit}:refs/pull/$pullRequestNumber/merge"
    ))

    [void](Invoke-GitTest $temp @("clone", "--no-local", $remoteRoot, $trustedRoot))
    [void](Invoke-GitTest $trustedRoot @("checkout", "--detach", $baseCommit))
    $commonArguments = @{
        RepositoryRoot = $trustedRoot
        Repository = $repository
        PullRequestNumber = $pullRequestNumber
        BaseCommit = $baseCommit
        HeadCommit = $headCommit
        MergeCommit = $mergeCommit
        PinnedVerifierCommit = $baseCommit
        PinnedVerifierTree = $baseTree
        PinnedVerifierPath = "scripts/Test-ExternalValidationAuthority.ps1"
        PinnedVerifierSha256 = $verifierSha256
        RemoteUrl = $remoteRoot
        AllowLocalTestRemote = $true
    }
    $assessmentText = & $adapter @commonArguments
    $assessment = (@($assessmentText) -join "`n") | ConvertFrom-Json -Depth 30
    if (
        [string]$assessment.decision -cne "unprotected" -or
        [bool]$assessment.candidate_code_executed -ne $false -or
        [bool]$assessment.execution_attested -ne $false -or
        [bool]$assessment.publication_authority -ne $false
    ) {
        throw "Static adapter did not return the exact unprotected static assessment."
    }
    if (
        (Test-Path -LiteralPath $markerPath) -or
        (Test-Path -LiteralPath (Join-Path $trustedRoot "candidate")) -or
        (Test-Path -LiteralPath (Join-Path $trustedRoot "docs/note.md"))
    ) {
        throw "Candidate content was executed or checked out into the trusted base."
    }

    $staleHead = @{} + $commonArguments
    $staleHead.HeadCommit = $baseCommit
    Assert-Rejected {
        & $adapter @staleHead
    } "Fetched pull request head does not equal" "stale event head"

    $staleBase = @{} + $commonArguments
    $staleBase.BaseCommit = $headCommit
    Assert-Rejected {
        & $adapter @staleBase
    } "Trusted checkout HEAD does not equal" "stale event base"

    $oneParentMerge = Invoke-GitTest $seedRoot @(
        "commit-tree", $headTree, "-p", $baseCommit,
        "-m", "malformed one-parent merge"
    )
    [void](Invoke-GitTest $seedRoot @(
        "push", "--force", "origin",
        "${oneParentMerge}:refs/pull/$pullRequestNumber/merge"
    ))
    $oneParent = @{} + $commonArguments
    $oneParent.MergeCommit = $oneParentMerge
    Assert-Rejected {
        & $adapter @oneParent
    } "exact ordered event base and head parents" "one-parent merge"

    $reversedMerge = Invoke-GitTest $seedRoot @(
        "commit-tree", $headTree, "-p", $headCommit, "-p", $baseCommit,
        "-m", "reversed pull request merge"
    )
    [void](Invoke-GitTest $seedRoot @(
        "push", "--force", "origin",
        "${reversedMerge}:refs/pull/$pullRequestNumber/merge"
    ))
    $reversed = @{} + $commonArguments
    $reversed.MergeCommit = $reversedMerge
    Assert-Rejected {
        & $adapter @reversed
    } "exact ordered event base and head parents" "reversed merge parents"

    Assert-Rejected {
        & $adapter @commonArguments
    } "Fetched pull request merge does not equal" "stale merge identity"

    [void](Invoke-GitTest $seedRoot @(
        "push", "--force", "origin",
        "${mergeCommit}:refs/pull/$pullRequestNumber/merge"
    ))

    $malformedNumber = @{} + $commonArguments
    $malformedNumber.PullRequestNumber = "07"
    Assert-Rejected {
        & $adapter @malformedNumber
    } "Pull request number is malformed" "malformed pull request number"

    $malformedCommit = @{} + $commonArguments
    $malformedCommit.HeadCommit = $headCommit.ToUpperInvariant()
    Assert-Rejected {
        & $adapter @malformedCommit
    } "Head commit is not a lowercase full commit identity" "malformed head identity"

    $badVerifierPin = @{} + $commonArguments
    $badVerifierPin.PinnedVerifierSha256 = "0" * 64
    Assert-Rejected {
        & $adapter @badVerifierPin
    } "Pinned verifier bytes do not equal" "substituted verifier pin"

    Write-Output "External validation authority GitHub adapter self-tests passed."
} finally {
    if (Test-Path -LiteralPath $temp) {
        Get-ChildItem -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    $_.Attributes = [IO.FileAttributes]::Normal
                } catch {}
            }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
