param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$inspector = Join-Path $PSScriptRoot "Inspect-RepositoryLifecycle.ps1"
$schema = Join-Path $root "schemas/repository-lifecycle-advisory-v1.schema.json"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("repository-lifecycle-" + [guid]::NewGuid().ToString("N"))
$repo = Join-Path $temp "source"
$remote = Join-Path $temp "remote.git"
$worktree = Join-Path $temp "registered-worktree"

function Invoke-TestGit {
    param([string]$Path, [string[]]$Arguments)
    $output = @(& git -C $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return @($output)
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function New-Check {
    param([string]$Name, [string]$Status = "no", [string[]]$Consumers = @())
    return [ordered]@{
        status = $Status
        evidence_refs = @("fixture:$Name-$Status")
        consumer_ids = @($Consumers)
        reevaluation_gate = "fixture-reevaluate-$Name"
    }
}

function New-Checks {
    param([hashtable]$Overrides = @{})
    $names = @(
        "open_pr_use",
        "protected_ref",
        "pages_use",
        "workflow_use",
        "release_use",
        "deployment_use",
        "active_task_or_writer",
        "registered_worktree_consumer",
        "dirty_unique_local_consumer",
        "evidence_or_hold_consumer"
    )
    $checks = [ordered]@{}
    foreach ($name in $names) {
        if ($Overrides.ContainsKey($name)) {
            $value = $Overrides[$name]
            $checks[$name] = New-Check -Name $name -Status ([string]$value.status) -Consumers @($value.consumers)
        } else {
            $checks[$name] = New-Check -Name $name
        }
    }
    return $checks
}

function Get-RemoteTip {
    param([string]$Ref)
    $line = @(Invoke-TestGit -Path $repo -Arguments @("ls-remote", "--heads", "origin", $Ref))
    if ($line.Count -ne 1 -or $line[0] -notmatch '^([0-9a-f]{40})\s+') { throw "Cannot resolve fixture ref '$Ref'." }
    return [string]$Matches[1]
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Label)
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "$Label was accepted unexpectedly." }
}

New-Item -ItemType Directory -Path $temp | Out-Null
try {
    & git init --bare $remote | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to initialize fixture remote." }
    & git init -b main $repo | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to initialize fixture source." }
    Invoke-TestGit -Path $repo -Arguments @("config", "user.email", "fixture@example.invalid") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("config", "user.name", "Lifecycle Fixture") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("remote", "add", "origin", $remote) | Out-Null

    Write-Utf8 -Path (Join-Path $repo "state.txt") -Text "base`n"
    Invoke-TestGit -Path $repo -Arguments @("add", "state.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "base") | Out-Null
    $base = [string](@(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0])
    foreach ($branch in @("candidate", "worktree-hold", "pr-hold", "unknown-hold")) {
        Invoke-TestGit -Path $repo -Arguments @("branch", $branch, $base) | Out-Null
    }

    Write-Utf8 -Path (Join-Path $repo "state.txt") -Text "base`nmain`n"
    Invoke-TestGit -Path $repo -Arguments @("add", "state.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "main advance") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("switch", "-c", "divergent", $base) | Out-Null
    Write-Utf8 -Path (Join-Path $repo "divergent.txt") -Text "divergent`n"
    Invoke-TestGit -Path $repo -Arguments @("add", "divergent.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "divergent") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("switch", "main") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("push", "origin", "main", "candidate", "worktree-hold", "pr-hold", "unknown-hold", "divergent") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("worktree", "add", $worktree, "worktree-hold") | Out-Null

    $refs = @(
        [ordered]@{ ref = "refs/heads/main"; expected_tip = Get-RemoteTip "refs/heads/main"; checks = New-Checks @{ registered_worktree_consumer = @{ status = "yes"; consumers = @("fixture-main-worktree") } } },
        [ordered]@{ ref = "refs/heads/candidate"; expected_tip = Get-RemoteTip "refs/heads/candidate"; checks = New-Checks },
        [ordered]@{ ref = "refs/heads/worktree-hold"; expected_tip = Get-RemoteTip "refs/heads/worktree-hold"; checks = New-Checks @{ registered_worktree_consumer = @{ status = "yes"; consumers = @("fixture-worktree") } } },
        [ordered]@{ ref = "refs/heads/pr-hold"; expected_tip = Get-RemoteTip "refs/heads/pr-hold"; checks = New-Checks @{ open_pr_use = @{ status = "yes"; consumers = @("fixture-pr-1") } } },
        [ordered]@{ ref = "refs/heads/unknown-hold"; expected_tip = Get-RemoteTip "refs/heads/unknown-hold"; checks = New-Checks @{ release_use = @{ status = "unknown"; consumers = @() } } },
        [ordered]@{ ref = "refs/heads/divergent"; expected_tip = Get-RemoteTip "refs/heads/divergent"; checks = New-Checks }
    )
    $registry = [ordered]@{
        schema = "rusty.morphospace.workflow.repository_lifecycle_registry.v1"
        observed_at_utc = "2026-08-08T00:00:00Z"
        repositories = @([ordered]@{
            repo_id = "fixture-owner"
            repository_root = $repo
            remote = "origin"
            default_branch = "main"
            refs = $refs
        })
    }
    $registryPath = Join-Path $temp "registry.json"
    Write-Utf8 -Path $registryPath -Text ($registry | ConvertTo-Json -Depth 50)

    $beforeRefs = (Invoke-TestGit -Path $repo -Arguments @("show-ref")) -join "`n"
    $beforeWorktrees = (Invoke-TestGit -Path $repo -Arguments @("worktree", "list", "--porcelain")) -join "`n"
    $beforeStatus = (Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1")) -join "`n"
    $json1 = @(& $inspector -RegistryPath $registryPath -SchemaPath $schema) -join "`n"
    $json2 = @(& $inspector -RegistryPath $registryPath -SchemaPath $schema) -join "`n"
    if ($json1 -cne $json2) { throw "Lifecycle advisory output is not deterministic for unchanged evidence." }
    if (-not (Test-Json -Json $json1 -SchemaFile $schema -ErrorAction Stop)) { throw "Lifecycle result failed its public schema." }
    $result = $json1 | ConvertFrom-Json -Depth 50 -DateKind String
    if ([string]$result.execution -cne "not-performed" -or $result.git_mutation_performed -ne $false -or $result.remote_mutation_performed -ne $false) { throw "Lifecycle result claimed mutation or execution." }
    if ($result.summary.repository_count -ne 1 -or $result.summary.ref_count -ne 6 -or $result.summary.candidate_retire_count -ne 1 -or $result.summary.hold_count -ne 4 -or $result.summary.incomplete_count -ne 1) { throw "Lifecycle result summary is incorrect: $($result.summary | ConvertTo-Json -Compress)." }
    $byRef = @{}; foreach ($item in $result.repositories[0].refs) { $byRef[[string]$item.ref] = $item }
    if ([string]$byRef["refs/heads/candidate"].disposition -cne "candidate-retire") { throw "Main-reachable consumer-free ref was not a candidate." }
    if ([string]$byRef["refs/heads/worktree-hold"].disposition -cne "hold" -or @($byRef["refs/heads/worktree-hold"].registered_worktree_paths).Count -ne 1) { throw "Registered worktree consumer was not held." }
    if ([string]$byRef["refs/heads/divergent"].disposition -cne "hold" -or [string]$byRef["refs/heads/divergent"].main_relation -cne "divergent") { throw "Divergent ref was not held." }
    if ([string]$byRef["refs/heads/unknown-hold"].disposition -cne "incomplete") { throw "Unknown operational evidence did not remain incomplete." }
    if ([string]$byRef["refs/heads/main"].disposition -cne "hold" -or @($byRef["refs/heads/main"].reason_codes) -cnotcontains "default-branch") { throw "Default branch was not held." }
    if ([string]$byRef["refs/heads/pr-hold"].disposition -cne "hold" -or @($byRef["refs/heads/pr-hold"].reason_codes) -cnotcontains "open-pr-consumer") { throw "Open PR consumer was not held." }
    if (((Invoke-TestGit -Path $repo -Arguments @("show-ref")) -join "`n") -cne $beforeRefs -or ((Invoke-TestGit -Path $repo -Arguments @("worktree", "list", "--porcelain")) -join "`n") -cne $beforeWorktrees -or ((Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1")) -join "`n") -cne $beforeStatus) { throw "Lifecycle inspection mutated Git state." }

    $outPath = Join-Path $temp "result.json"
    & $inspector -RegistryPath $registryPath -SchemaPath $schema -OutPath $outPath | Out-Null
    if (-not (Test-Path -LiteralPath $outPath -PathType Leaf)) { throw "Lifecycle inspector did not write its optional report." }
    Assert-Rejected { & $inspector -RegistryPath $registryPath -SchemaPath $schema -OutPath $outPath } "Output overwrite"

    $worktreeGitFile = Join-Path $worktree ".git"
    $worktreeGitPointer = [IO.File]::ReadAllText($worktreeGitFile)
    $worktreeGitAttributes = [IO.File]::GetAttributes($worktreeGitFile)
    try {
        [IO.File]::SetAttributes($worktreeGitFile, [IO.FileAttributes]::Normal)
        Write-Utf8 -Path $worktreeGitFile -Text "gitdir: $temp/missing-worktree-registration`n"
        $unreadable = (@(& $inspector -RegistryPath $registryPath -SchemaPath $schema) -join "`n") | ConvertFrom-Json -Depth 50 -DateKind String
        if ([int]$unreadable.repositories[0].unreadable_worktree_count -ne 1) { throw "Unreadable registered worktree was not counted." }
        $unreadableRef = @($unreadable.repositories[0].refs | Where-Object ref -ceq "refs/heads/worktree-hold")[0]
        if ([string]$unreadableRef.disposition -cne "incomplete" -or @($unreadableRef.reason_codes) -cnotcontains "registered-worktree-status-unreadable") { throw "Unreadable registered worktree was not classified as incomplete." }
    } finally {
        [IO.File]::WriteAllText($worktreeGitFile, $worktreeGitPointer, [Text.UTF8Encoding]::new($false))
        [IO.File]::SetAttributes($worktreeGitFile, $worktreeGitAttributes)
    }

    $bad = $registry | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50 -DateKind String
    $bad.repositories[0].refs[1].checks.open_pr_use.status = "yes"
    $bad.repositories[0].refs[1].checks.open_pr_use.consumer_ids = @()
    $badPath = Join-Path $temp "bad-registry.json"
    Write-Utf8 -Path $badPath -Text ($bad | ConvertTo-Json -Depth 50)
    Assert-Rejected { & $inspector -RegistryPath $badPath -SchemaPath $schema } "Yes without consumer identity"

    Invoke-TestGit -Path $repo -Arguments @("switch", "candidate") | Out-Null
    Write-Utf8 -Path (Join-Path $repo "candidate.txt") -Text "changed tip`n"
    Invoke-TestGit -Path $repo -Arguments @("add", "candidate.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "candidate changed") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("push", "origin", "candidate") | Out-Null
    $changed = (@(& $inspector -RegistryPath $registryPath -SchemaPath $schema) -join "`n") | ConvertFrom-Json -Depth 50 -DateKind String
    $changedCandidate = @($changed.repositories[0].refs | Where-Object ref -ceq "refs/heads/candidate")[0]
    if ([string]$changedCandidate.disposition -cne "incomplete" -or @($changedCandidate.reason_codes) -cnotcontains "tip-changed") { throw "Changed exact tip did not invalidate retirement candidacy." }

    Write-Output "Repository lifecycle advisory self-test passed (candidate, holds, incomplete, unreadable worktree, exact-tip drift, determinism, no mutation, and damaged registry)."
} finally {
    if (Test-Path -LiteralPath $repo -PathType Container) {
        & git -C $repo worktree remove $worktree --force 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
