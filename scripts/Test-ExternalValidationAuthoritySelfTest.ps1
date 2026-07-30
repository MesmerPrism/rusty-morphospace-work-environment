param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Invoke-GitTest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Git test command failed: git $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

function Invoke-AuthorityTest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Candidate,
        [string]$OutputPath = ""
    )

    $arguments = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $authorityScript,
        "-RepositoryRoot",
        $Root,
        "-PolicyPath",
        "config/external-validation-authority.json",
        "-Repository",
        "example/example",
        "-BaseCommit",
        $Base,
        "-CandidateCommit",
        $Candidate,
        "-Json"
    )
    if ($OutputPath) {
        $arguments += @("-OutPath", $OutputPath)
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            exit_code = [int]$process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Assert-Passed {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Result.exit_code -ne 0) {
        throw "$Label failed unexpectedly:`n$($Result.stderr)`n$($Result.stdout)"
    }
    return $Result.stdout | ConvertFrom-Json -Depth 30
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Result.exit_code -eq 0) {
        throw "$Label was accepted unexpectedly."
    }
    $detail = $Result.stderr + "`n" + $Result.stdout
    if ($detail -notmatch $Pattern) {
        throw "$Label failed for the wrong reason:`n$detail"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$authorityScript = Join-Path $PSScriptRoot "Test-ExternalValidationAuthority.ps1"
$temp = Join-Path (
    [IO.Path]::GetTempPath()
) ("morphospace-external-authority-" + [guid]::NewGuid().ToString("N"))
$baseRoot = Join-Path $temp "base"
$candidateRoot = Join-Path $temp "candidate"
$docsRoot = Join-Path $temp "docs-only"
$impostorRoot = Join-Path $temp "impostor"

try {
    [IO.Directory]::CreateDirectory($baseRoot) | Out-Null
    Invoke-GitTest $baseRoot @("init", "--initial-branch=main") | Out-Null
    Invoke-GitTest $baseRoot @("config", "user.name", "External Authority Test") | Out-Null
    Invoke-GitTest $baseRoot @("config", "user.email", "authority@example.invalid") | Out-Null
    Write-Utf8 (Join-Path $baseRoot "README.md") "baseline`n"
    Write-Utf8 (Join-Path $baseRoot "tools/authority.ps1") "exit 0`n"
    Write-Utf8 (
        Join-Path $baseRoot "config/external-validation-authority.json"
    ) @'
{
  "schema": "rusty.morphospace.workflow.external_validation_authority_policy.v1",
  "policy_id": "external-authority-test-v1",
  "repository": "example/example",
  "mandatory_protected_paths": [
    "config/external-validation-authority.json"
  ],
  "protected_rules": [
    {
      "rule_id": "authority-tools",
      "match": "exact",
      "path": "tools/authority.ps1"
    }
  ],
  "approved_change_sets": [],
  "status": "active"
}
'@
    Invoke-GitTest $baseRoot @("add", ".") | Out-Null
    Invoke-GitTest $baseRoot @("commit", "-m", "baseline") | Out-Null

    Invoke-GitTest $baseRoot @(
        "worktree",
        "add",
        "-b",
        "feature",
        $candidateRoot,
        "main"
    ) | Out-Null
    Write-Utf8 (
        Join-Path $candidateRoot "tools/authority.ps1"
    ) "throw 'candidate code must not execute during admission'`n"
    Write-Utf8 (Join-Path $candidateRoot "docs/note.md") "reviewed change`n"
    Invoke-GitTest $candidateRoot @("add", ".") | Out-Null
    Invoke-GitTest $candidateRoot @(
        "update-index",
        "--chmod=+x",
        "tools/authority.ps1"
    ) | Out-Null
    Invoke-GitTest $candidateRoot @("commit", "-m", "reviewed authority change") |
        Out-Null
    $featureAnchor = Invoke-GitTest $candidateRoot @("rev-parse", "HEAD")

    $changedPaths = @("docs/note.md", "tools/authority.ps1")
    $artifacts = @($changedPaths | ForEach-Object {
        $file = Get-Item -LiteralPath (Join-Path $candidateRoot $_)
        [ordered]@{
            path = $_
            state = "present"
            mode = if ($_ -ceq "tools/authority.ps1") { "100755" } else { "100644" }
            size_bytes = [int64]$file.Length
            sha256 = (
                Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName
            ).Hash.ToLowerInvariant()
        }
    })
    $policy = [ordered]@{
        schema = "rusty.morphospace.workflow.external_validation_authority_policy.v1"
        policy_id = "external-authority-test-v1"
        repository = "example/example"
        mandatory_protected_paths = @(
            "config/external-validation-authority.json"
        )
        protected_rules = @(
            [ordered]@{
                rule_id = "authority-tools"
                match = "exact"
                path = "tools/authority.ps1"
            }
        )
        approved_change_sets = @(
            [ordered]@{
                approval_id = "reviewed-authority-change"
                required_ancestor = $featureAnchor
                changed_paths = $changedPaths
                artifacts = $artifacts
                status = "approved"
            }
        )
        status = "active"
    }
    Write-Utf8 (
        Join-Path $baseRoot "config/external-validation-authority.json"
    ) (($policy | ConvertTo-Json -Depth 20) + "`n")
    Invoke-GitTest $baseRoot @("add", "config/external-validation-authority.json") |
        Out-Null
    Invoke-GitTest $baseRoot @("commit", "-m", "approve exact authority change") |
        Out-Null
    $baseCommit = Invoke-GitTest $baseRoot @("rev-parse", "HEAD")

    Invoke-GitTest $candidateRoot @("merge", "--no-edit", "main") | Out-Null
    $candidateCommit = Invoke-GitTest $candidateRoot @("rev-parse", "HEAD")

    $outputPath = Join-Path $temp "assessment.json"
    $positive = Assert-Passed (
        Invoke-AuthorityTest $baseRoot $baseCommit $candidateCommit $outputPath
    ) "exact approved change"
    if (
        $positive.decision -cne "approved-change-set" -or
        $positive.approval_id -cne "reviewed-authority-change" -or
        $positive.candidate_code_executed -ne $false -or
        $positive.execution_attested -ne $false -or
        $positive.publication_authority -ne $false -or
        -not (Test-Path -LiteralPath $outputPath -PathType Leaf)
    ) {
        throw "Exact approved assessment is incomplete."
    }
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $candidateCommit $outputPath
    ) "already exists|CreateNew" "assessment overwrite"

    Invoke-GitTest $baseRoot @(
        "worktree",
        "add",
        "-b",
        "docs-only",
        $docsRoot,
        "main"
    ) | Out-Null
    Write-Utf8 (Join-Path $docsRoot "docs/other.md") "unprotected`n"
    Invoke-GitTest $docsRoot @("add", ".") | Out-Null
    Invoke-GitTest $docsRoot @("commit", "-m", "unprotected docs") | Out-Null
    $docsCommit = Invoke-GitTest $docsRoot @("rev-parse", "HEAD")
    $unprotected = Assert-Passed (
        Invoke-AuthorityTest $baseRoot $baseCommit $docsCommit
    ) "unprotected change"
    if (
        $unprotected.decision -cne "unprotected" -or
        $null -ne $unprotected.approval_id
    ) {
        throw "Unprotected change did not remain outside authority admission."
    }

    Write-Utf8 (
        Join-Path $candidateRoot "tools/authority.ps1"
    ) "throw 'different candidate bytes'`n"
    Invoke-GitTest $candidateRoot @("add", "tools/authority.ps1") | Out-Null
    Invoke-GitTest $candidateRoot @("commit", "-m", "damage approved bytes") |
        Out-Null
    $damagedCommit = Invoke-GitTest $candidateRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $damagedCommit
    ) "do not match an exact base-approved change set" "damaged artifact"
    Invoke-GitTest $candidateRoot @("reset", "--hard", $candidateCommit) | Out-Null

    Invoke-GitTest $candidateRoot @(
        "update-index",
        "--chmod=-x",
        "tools/authority.ps1"
    ) | Out-Null
    Invoke-GitTest $candidateRoot @("commit", "-m", "substitute non-executable mode") |
        Out-Null
    $modeCommit = Invoke-GitTest $candidateRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $modeCommit
    ) "do not match an exact base-approved change set" "Git mode substitution"
    Invoke-GitTest $candidateRoot @("reset", "--hard", $candidateCommit) | Out-Null

    Write-Utf8 (Join-Path $candidateRoot "extra.txt") "extra`n"
    Invoke-GitTest $candidateRoot @("add", "extra.txt") | Out-Null
    Invoke-GitTest $candidateRoot @("commit", "-m", "expand exact scope") | Out-Null
    $expandedCommit = Invoke-GitTest $candidateRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $expandedCommit
    ) "do not match an exact base-approved change set" "expanded path scope"
    Invoke-GitTest $candidateRoot @("reset", "--hard", $candidateCommit) | Out-Null

    for ($index = 0; $index -lt 513; $index++) {
        Write-Utf8 (
            Join-Path $candidateRoot ("bulk/path-{0:D3}.txt" -f $index)
        ) "bounded`n"
    }
    Invoke-GitTest $candidateRoot @("add", "bulk") | Out-Null
    Invoke-GitTest $candidateRoot @("commit", "-m", "exceed path bound") | Out-Null
    $largeCommit = Invoke-GitTest $candidateRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $largeCommit
    ) "512-path admission bound" "oversized path inventory"
    Invoke-GitTest $candidateRoot @("reset", "--hard", $candidateCommit) | Out-Null

    $candidatePolicy = (
        Get-Content -LiteralPath (
            Join-Path $candidateRoot "config/external-validation-authority.json"
        ) -Raw
    ).Replace(
        '"policy_id": "external-authority-test-v1"',
        '"policy_id": "candidate-replaced-policy"'
    )
    Write-Utf8 (
        Join-Path $candidateRoot "config/external-validation-authority.json"
    ) $candidatePolicy
    Invoke-GitTest $candidateRoot @(
        "add",
        "config/external-validation-authority.json"
    ) | Out-Null
    Invoke-GitTest $candidateRoot @("commit", "-m", "replace future policy") |
        Out-Null
    $policyChangeCommit = Invoke-GitTest $candidateRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $policyChangeCommit
    ) "do not match an exact base-approved change set" "self-policy change"
    Invoke-GitTest $candidateRoot @("reset", "--hard", $candidateCommit) | Out-Null

    Invoke-GitTest $baseRoot @(
        "worktree",
        "add",
        "-b",
        "impostor",
        $impostorRoot,
        "main"
    ) | Out-Null
    Copy-Item -LiteralPath (Join-Path $candidateRoot "tools/authority.ps1") `
        -Destination (Join-Path $impostorRoot "tools/authority.ps1")
    Write-Utf8 (Join-Path $impostorRoot "docs/note.md") "reviewed change`n"
    Invoke-GitTest $impostorRoot @("add", ".") | Out-Null
    Invoke-GitTest $impostorRoot @("commit", "-m", "copy without reviewed ancestry") |
        Out-Null
    $impostorCommit = Invoke-GitTest $impostorRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $impostorCommit
    ) "do not match an exact base-approved change set" "missing reviewed ancestor"

    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $featureAnchor
    ) "not an ancestor" "candidate behind trusted base"

    Write-Utf8 (Join-Path $baseRoot "untracked.txt") "dirty`n"
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $candidateCommit
    ) "checkout is dirty" "dirty trusted base"
    Remove-Item -LiteralPath (Join-Path $baseRoot "untracked.txt") -Force

    Invoke-GitTest $baseRoot @(
        "update-ref",
        "refs/replace/$baseCommit",
        $candidateCommit
    ) | Out-Null
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $candidateCommit
    ) "replacement refs" "replacement-ref inspection environment"
    Invoke-GitTest $baseRoot @("update-ref", "-d", "refs/replace/$baseCommit") |
        Out-Null

    $commonDir = Invoke-GitTest $baseRoot @(
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir"
    )
    $alternatesPath = Join-Path $commonDir "objects/info/alternates"
    Write-Utf8 $alternatesPath ""
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $baseCommit $candidateCommit
    ) "external object metadata" "alternate-object inspection environment"
    Remove-Item -LiteralPath $alternatesPath -Force

    foreach ($ambientGitVariable in @(
        [pscustomobject]@{
            name = "GIT_ALTERNATE_OBJECT_DIRECTORIES"
            value = (Join-Path $commonDir "objects")
        },
        [pscustomobject]@{
            name = "GIT_OBJECT_DIRECTORY"
            value = (Join-Path $commonDir "objects")
        },
        [pscustomobject]@{
            name = "Git_Dir"
            value = $commonDir
        }
    )) {
        try {
            [Environment]::SetEnvironmentVariable(
                [string]$ambientGitVariable.name,
                [string]$ambientGitVariable.value,
                [EnvironmentVariableTarget]::Process
            )
            Assert-Rejected (
                Invoke-AuthorityTest $baseRoot $baseCommit $candidateCommit
            ) "Ambient Git repository/object-store environment is forbidden" (
                "ambient " + [string]$ambientGitVariable.name
            )
        } finally {
            Remove-Item -LiteralPath (
                "Env:" + [string]$ambientGitVariable.name
            ) -ErrorAction SilentlyContinue
        }
    }

    $ambiguous = $policy | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $secondApproval = $ambiguous.approved_change_sets[0] |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
    $secondApproval.approval_id = "second-reviewed-authority-change"
    $ambiguous.approved_change_sets = @(
        $ambiguous.approved_change_sets[0],
        $secondApproval
    )
    Write-Utf8 (
        Join-Path $baseRoot "config/external-validation-authority.json"
    ) (($ambiguous | ConvertTo-Json -Depth 20) + "`n")
    Invoke-GitTest $baseRoot @("add", "config/external-validation-authority.json") |
        Out-Null
    Invoke-GitTest $baseRoot @("commit", "-m", "ambiguous authority fixture") |
        Out-Null
    $ambiguousBase = Invoke-GitTest $baseRoot @("rev-parse", "HEAD")
    Invoke-GitTest $candidateRoot @("merge", "--no-edit", "main") | Out-Null
    $ambiguousCandidate = Invoke-GitTest $candidateRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $ambiguousBase $ambiguousCandidate
    ) "ambiguously match" "ambiguous approvals"
    Invoke-GitTest $candidateRoot @("reset", "--hard", $candidateCommit) | Out-Null
    Invoke-GitTest $baseRoot @("reset", "--hard", $baseCommit) | Out-Null

    $missingSelf = $policy | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $missingSelf.mandatory_protected_paths = @("tools/authority.ps1")
    Write-Utf8 (
        Join-Path $baseRoot "config/external-validation-authority.json"
    ) (($missingSelf | ConvertTo-Json -Depth 20) + "`n")
    Invoke-GitTest $baseRoot @("add", "config/external-validation-authority.json") |
        Out-Null
    Invoke-GitTest $baseRoot @("commit", "-m", "omit self protection fixture") |
        Out-Null
    $missingSelfBase = Invoke-GitTest $baseRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $missingSelfBase $missingSelfBase
    ) "list its own path" "policy without self protection"
    Invoke-GitTest $baseRoot @("reset", "--hard", $baseCommit) | Out-Null

    $duplicateJson = ($policy | ConvertTo-Json -Depth 20).TrimEnd()
    $duplicateJson = $duplicateJson.Substring(0, $duplicateJson.Length - 1) +
        ",`n  `"Repository`": `"example/example`"`n}`n"
    Write-Utf8 (
        Join-Path $baseRoot "config/external-validation-authority.json"
    ) $duplicateJson
    Invoke-GitTest $baseRoot @("add", "config/external-validation-authority.json") |
        Out-Null
    Invoke-GitTest $baseRoot @("commit", "-m", "duplicate json fixture") | Out-Null
    $duplicateBase = Invoke-GitTest $baseRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $duplicateBase $duplicateBase
    ) "Duplicate or case-colliding JSON|AssertNoDuplicateProperties" `
        "duplicate policy property"
    Invoke-GitTest $baseRoot @("reset", "--hard", $baseCommit) | Out-Null

    $nonPortable = $policy | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $nonPortable.mandatory_protected_paths = @(
        ("C" + [char]58 + "/escape"),
        "config/external-validation-authority.json"
    )
    Write-Utf8 (
        Join-Path $baseRoot "config/external-validation-authority.json"
    ) (($nonPortable | ConvertTo-Json -Depth 20) + "`n")
    Invoke-GitTest $baseRoot @("add", "config/external-validation-authority.json") |
        Out-Null
    Invoke-GitTest $baseRoot @("commit", "-m", "non-portable path fixture") |
        Out-Null
    $nonPortableBase = Invoke-GitTest $baseRoot @("rev-parse", "HEAD")
    Assert-Rejected (
        Invoke-AuthorityTest $baseRoot $nonPortableBase $nonPortableBase
    ) "not a portable relative path" "non-portable policy path"
    Invoke-GitTest $baseRoot @("reset", "--hard", $baseCommit) | Out-Null

    Write-Output "External validation authority self-tests passed."
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
