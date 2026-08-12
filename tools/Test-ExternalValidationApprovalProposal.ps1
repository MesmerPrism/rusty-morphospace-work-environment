param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$generator = Join-Path $PSScriptRoot "New-ExternalValidationApprovalProposal.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("external-validation-approval-proposal-" + [guid]::NewGuid().ToString("N"))
$repo = Join-Path $temp "trusted-base"
$candidateWorktree = Join-Path $temp "candidate-worktree"

function Invoke-TestGit {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed ($exitCode): $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ exit_code = $exitCode; output = $output }
}

function Write-Utf8 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-Sha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
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
    Invoke-TestGit $repo @("config", "user.email", "fixture@example.invalid") | Out-Null
    Invoke-TestGit $repo @("config", "user.name", "Approval Proposal Fixture") | Out-Null
    Invoke-TestGit $repo @("config", "core.autocrlf", "false") | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo "docs"), (Join-Path $repo "tools") | Out-Null
    Write-Utf8 (Join-Path $repo "docs/a.txt") "base`n"
    Write-Utf8 (Join-Path $repo "old.txt") "delete me`n"
    Write-Utf8 (Join-Path $repo "tools/run.sh") "#!/bin/sh`nexit 1`n"
    Invoke-TestGit $repo @("add", "--", "docs/a.txt", "old.txt", "tools/run.sh") | Out-Null
    Invoke-TestGit $repo @("commit", "-m", "base") | Out-Null
    $base = (Invoke-TestGit $repo @("rev-parse", "HEAD")).output[0]

    Invoke-TestGit $repo @("switch", "-c", "candidate") | Out-Null
    $sharedText = "candidate bytes`n"
    $scriptText = "#!/bin/sh`nexit 0`n"
    Write-Utf8 (Join-Path $repo "docs/a.txt") $sharedText
    Write-Utf8 (Join-Path $repo "docs/z.txt") $sharedText
    Write-Utf8 (Join-Path $repo "tools/run.sh") $scriptText
    Remove-Item -LiteralPath (Join-Path $repo "old.txt")
    Invoke-TestGit $repo @("add", "--", "docs/a.txt", "docs/z.txt", "old.txt", "tools/run.sh") | Out-Null
    Invoke-TestGit $repo @("update-index", "--chmod=+x", "tools/run.sh") | Out-Null
    Invoke-TestGit $repo @("commit", "-m", "candidate") | Out-Null
    $candidate = (Invoke-TestGit $repo @("rev-parse", "HEAD")).output[0]
    Invoke-TestGit $repo @("switch", "main") | Out-Null

    Invoke-TestGit $repo @("worktree", "add", "--detach", $candidateWorktree, $candidate) | Out-Null
    [IO.File]::WriteAllBytes(
        (Join-Path $candidateWorktree "docs/a.txt"),
        [Text.Encoding]::UTF8.GetBytes("poisoned candidate checkout`r`n")
    )

    $beforeRefs = (Invoke-TestGit $repo @("show-ref")).output -join "`n"
    $beforeStatus = (Invoke-TestGit $repo @("status", "--porcelain=v1", "--untracked-files=all")).output -join "`n"
    $beforeWorktrees = (Invoke-TestGit $repo @("worktree", "list", "--porcelain")).output -join "`n"
    $outPath = Join-Path $temp "proposal.json"
    $json = @(
        & $generator `
            -RepositoryRoot $repo `
            -Repository "Example/project" `
            -ApprovalId "fixture-approval-001" `
            -BaseCommit $base `
            -CandidateCommit $candidate `
            -OutPath $outPath
    ) -join "`n"
    $proposal = $json | ConvertFrom-Json -Depth 30

    Assert-True ($proposal.schema -ceq "rusty.morphospace.workflow.external_validation_approval_proposal.v1") "Wrong proposal schema."
    Assert-True ($proposal.proposal_status -ceq "review-required") "Proposal did not require review."
    Assert-True ($proposal.repository -ceq "Example/project") "Repository identity drifted."
    Assert-True ($proposal.base.commit -ceq $base -and $proposal.candidate.commit -ceq $candidate) "Base or candidate identity drifted."
    Assert-True ($proposal.required_ancestor.commit -ceq $candidate -and $proposal.approval_candidate.required_ancestor -ceq $candidate) "Safe default required ancestor was not the exact candidate."
    Assert-True ($proposal.evidence_source -ceq "canonical-git-objects") "Evidence source is not canonical Git objects."
    Assert-True (
        -not $proposal.candidate_checkout_performed -and
        -not $proposal.candidate_code_executed -and
        -not $proposal.working_tree_file_content_read -and
        -not $proposal.git_mutation_performed -and
        -not $proposal.remote_mutation_performed -and
        -not $proposal.approval_authority -and
        -not $proposal.execution_attested -and
        -not $proposal.publication_authority
    ) "Proposal overstated execution or authority."
    $expectedPaths = @("docs/a.txt", "docs/z.txt", "old.txt", "tools/run.sh")
    Assert-True ((@($proposal.approval_candidate.changed_paths) -join "|") -ceq ($expectedPaths -join "|")) "Changed paths are incomplete or unsorted."
    Assert-True ((@($proposal.approval_candidate.artifacts.path) -join "|") -ceq ($expectedPaths -join "|")) "Artifact paths do not equal changed paths."

    $artifactByPath = @{}
    foreach ($artifact in @($proposal.approval_candidate.artifacts)) { $artifactByPath[[string]$artifact.path] = $artifact }
    $sharedBytes = [Text.Encoding]::UTF8.GetBytes($sharedText)
    $scriptBytes = [Text.Encoding]::UTF8.GetBytes($scriptText)
    Assert-True (
        $artifactByPath["docs/a.txt"].state -ceq "present" -and
        $artifactByPath["docs/a.txt"].mode -ceq "100644" -and
        [int64]$artifactByPath["docs/a.txt"].size_bytes -eq $sharedBytes.Length -and
        $artifactByPath["docs/a.txt"].sha256 -ceq (Get-Sha256 $sharedBytes)
    ) "Canonical docs/a.txt evidence is wrong."
    Assert-True ($artifactByPath["docs/z.txt"].sha256 -ceq $artifactByPath["docs/a.txt"].sha256) "Shared blob evidence was inconsistent."
    Assert-True (
        $artifactByPath["tools/run.sh"].mode -ceq "100755" -and
        [int64]$artifactByPath["tools/run.sh"].size_bytes -eq $scriptBytes.Length -and
        $artifactByPath["tools/run.sh"].sha256 -ceq (Get-Sha256 $scriptBytes)
    ) "Executable blob evidence is wrong."
    Assert-True ($artifactByPath["old.txt"].state -ceq "absent") "Deletion did not become an absent artifact."
    Assert-True ($artifactByPath["docs/a.txt"].sha256 -cne (Get-Sha256 ([IO.File]::ReadAllBytes((Join-Path $candidateWorktree "docs/a.txt")))) ) "Generator appears to have trusted poisoned checkout bytes."
    Assert-True (Test-Path -LiteralPath $outPath -PathType Leaf) "Proposal output was not written."
    Assert-True ((Get-Content -Raw -LiteralPath $outPath) -ceq $json) "Written and stdout proposal JSON differ."
    Assert-True (((Invoke-TestGit $repo @("show-ref")).output -join "`n") -ceq $beforeRefs) "Generator mutated refs."
    Assert-True (((Invoke-TestGit $repo @("status", "--porcelain=v1", "--untracked-files=all")).output -join "`n") -ceq $beforeStatus) "Generator mutated source status."
    Assert-True (((Invoke-TestGit $repo @("worktree", "list", "--porcelain")).output -join "`n") -ceq $beforeWorktrees) "Generator mutated worktree registrations."

    $secondJson = @(
        & $generator `
            -RepositoryRoot $repo `
            -Repository "Example/project" `
            -ApprovalId "fixture-approval-001" `
            -BaseCommit $base `
            -CandidateCommit $candidate
    ) -join "`n"
    Assert-True ($secondJson -ceq $json) "Proposal generation is not deterministic."
    Assert-Rejected {
        & $generator -RepositoryRoot $repo -Repository "Example/project" -ApprovalId "fixture-approval-001" -BaseCommit $base -CandidateCommit $candidate -OutPath $outPath
    } "Output overwrite"
    Assert-Rejected {
        & $generator -RepositoryRoot $repo -Repository "Example/project" -ApprovalId "fixture-approval-001" -BaseCommit $base -CandidateCommit $candidate -OutPath (Join-Path $repo "proposal.json")
    } "Output inside trusted checkout"
    Assert-Rejected {
        & $generator -RepositoryRoot $repo -Repository "Example/project" -ApprovalId "BAD" -BaseCommit $base -CandidateCommit $candidate
    } "Malformed approval ID"
    Assert-Rejected {
        & $generator -RepositoryRoot $repo -Repository "Example/project" -ApprovalId "fixture-approval-001" -BaseCommit $base -CandidateCommit $candidate -RequiredAncestor $base
    } "Already consumed required ancestor"

    Write-Utf8 (Join-Path $repo "untracked.txt") "dirty`n"
    Assert-Rejected {
        & $generator -RepositoryRoot $repo -Repository "Example/project" -ApprovalId "fixture-approval-001" -BaseCommit $base -CandidateCommit $candidate
    } "Dirty trusted base"
    Remove-Item -LiteralPath (Join-Path $repo "untracked.txt")

    Invoke-TestGit $repo @("switch", "candidate") | Out-Null
    Assert-Rejected {
        & $generator -RepositoryRoot $repo -Repository "Example/project" -ApprovalId "fixture-approval-001" -BaseCommit $base -CandidateCommit $candidate
    } "Trusted-base HEAD mismatch"
    Invoke-TestGit $repo @("switch", "main") | Out-Null

    Invoke-TestGit $repo @("switch", "-c", "unsupported-mode") | Out-Null
    Write-Utf8 (Join-Path $repo "link-target.txt") "target`n"
    $linkBlob = (Invoke-TestGit $repo @("hash-object", "-w", "link-target.txt")).output[0]
    Remove-Item -LiteralPath (Join-Path $repo "link-target.txt")
    Invoke-TestGit $repo @("update-index", "--add", "--cacheinfo", "120000,$linkBlob,link.txt") | Out-Null
    Invoke-TestGit $repo @("commit", "-m", "unsupported symlink mode") | Out-Null
    $unsupported = (Invoke-TestGit $repo @("rev-parse", "HEAD")).output[0]
    Invoke-TestGit $repo @("switch", "main") | Out-Null
    Assert-Rejected {
        & $generator -RepositoryRoot $repo -Repository "Example/project" -ApprovalId "fixture-approval-002" -BaseCommit $base -CandidateCommit $unsupported
    } "Unsupported candidate file mode"

    Invoke-TestGit $repo @("switch", "main") | Out-Null
    Invoke-TestGit $repo @("switch", "-c", "deletion-only") | Out-Null
    Remove-Item -LiteralPath (Join-Path $repo "old.txt")
    Invoke-TestGit $repo @("add", "--", "old.txt") | Out-Null
    Invoke-TestGit $repo @("commit", "-m", "deletion only") | Out-Null
    $deletionOnly = (Invoke-TestGit $repo @("rev-parse", "HEAD")).output[0]
    Invoke-TestGit $repo @("switch", "main") | Out-Null
    $deletionProposal = @(
        & $generator -RepositoryRoot $repo -Repository "Example/project" -ApprovalId "fixture-approval-003" -BaseCommit $base -CandidateCommit $deletionOnly
    ) -join "`n" | ConvertFrom-Json -Depth 30
    Assert-True (
        @($deletionProposal.approval_candidate.artifacts).Count -eq 1 -and
        $deletionProposal.approval_candidate.artifacts[0].path -ceq "old.txt" -and
        $deletionProposal.approval_candidate.artifacts[0].state -ceq "absent"
    ) "Deletion-only proposal was not exact."

    Write-Output "External validation approval proposal self-test passed (canonical Git blobs, duplicate blobs, executable mode, mixed/deletion-only candidates, sorted paths, poisoned checkout independence, deterministic durable no-overwrite/outside-checkout output, clean exact base, unconsumed ancestor, unsupported-mode rejection, and zero Git/source/remote authority)."
} finally {
    if (Test-Path -LiteralPath $repo -PathType Container) {
        if (Test-Path -LiteralPath $candidateWorktree -PathType Container) {
            & git -C $repo worktree remove $candidateWorktree --force 2>$null | Out-Null
        }
    }
    if (Test-Path -LiteralPath $temp) {
        $resolvedTemp = [IO.Path]::GetFullPath($temp)
        $resolvedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemp.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean fixture outside the system temporary directory: $resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
