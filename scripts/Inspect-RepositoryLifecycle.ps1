param(
    [Parameter(Mandatory)][string]$RegistryPath,
    [string]$SchemaPath = "",
    [string]$OutPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if (-not $SchemaPath) {
    $SchemaPath = Join-Path $root "schemas/repository-lifecycle-advisory-v1.schema.json"
}
$RegistryPath = (Resolve-Path -LiteralPath $RegistryPath).Path
$SchemaPath = (Resolve-Path -LiteralPath $SchemaPath).Path

$checkOrder = @(
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
$reasonByCheck = [ordered]@{
    open_pr_use = "open-pr-consumer"
    protected_ref = "protected-ref"
    pages_use = "pages-consumer"
    workflow_use = "workflow-consumer"
    release_use = "release-consumer"
    deployment_use = "deployment-consumer"
    active_task_or_writer = "active-task-or-writer-consumer"
    registered_worktree_consumer = "registered-worktree-consumer"
    dirty_unique_local_consumer = "dirty-unique-local-consumer"
    evidence_or_hold_consumer = "evidence-or-hold-consumer"
}

function Invoke-LifecycleGit {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $priorOptionalLocks = $env:GIT_OPTIONAL_LOCKS
    $priorExternalDiff = $env:GIT_EXTERNAL_DIFF
    try {
        $env:GIT_OPTIONAL_LOCKS = "0"
        Remove-Item Env:GIT_EXTERNAL_DIFF -ErrorAction SilentlyContinue
        $output = @(& git -C $Repository -c core.hooksPath=NUL -c diff.external= @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    } finally {
        if ($null -eq $priorOptionalLocks) { Remove-Item Env:GIT_OPTIONAL_LOCKS -ErrorAction SilentlyContinue } else { $env:GIT_OPTIONAL_LOCKS = $priorOptionalLocks }
        if ($null -eq $priorExternalDiff) { Remove-Item Env:GIT_EXTERNAL_DIFF -ErrorAction SilentlyContinue } else { $env:GIT_EXTERNAL_DIFF = $priorExternalDiff }
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Read-only Git command failed ($code): git -C '<repository>' $($Arguments -join ' '): $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ code = $code; output = @($output) }
}

function Get-RemoteBranchTips {
    param([string]$Repository, [string]$Remote)
    $result = Invoke-LifecycleGit -Repository $Repository -Arguments @("ls-remote", "--heads", $Remote)
    $tips = @{}
    foreach ($line in $result.output) {
        if ($line -notmatch '^([0-9a-f]{40})\s+(refs/heads/.+)$') {
            throw "Remote '$Remote' returned an invalid branch-ref record."
        }
        $ref = [string]$Matches[2]
        if ($tips.ContainsKey($ref)) { throw "Remote '$Remote' returned duplicate ref '$ref'." }
        $tips[$ref] = [string]$Matches[1]
    }
    return $tips
}

function Get-WorktreeObservations {
    param([string]$Repository)
    $result = Invoke-LifecycleGit -Repository $Repository -Arguments @("worktree", "list", "--porcelain")
    $records = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in @($result.output) + "") {
        if ([string]::IsNullOrEmpty($line)) {
            if ($null -ne $current) {
                $path = [string]$current.path
                $dirtyResult = Invoke-LifecycleGit -Repository $path -Arguments @("status", "--porcelain=v1", "--untracked-files=normal") -AllowFailure
                $current.status_readable = $dirtyResult.code -eq 0
                $current.dirty = if ($current.status_readable) { @($dirtyResult.output).Count -gt 0 } else { $null }
                $records.Add([pscustomobject]$current) | Out-Null
                $current = $null
            }
            continue
        }
        if ($line.StartsWith("worktree ", [StringComparison]::Ordinal)) {
            if ($null -ne $current) { throw "Malformed Git worktree record: missing separator." }
            $current = [ordered]@{ path = $line.Substring(9); head = $null; branch = $null; status_readable = $false; dirty = $null }
        } elseif ($null -eq $current) {
            throw "Malformed Git worktree record: field before worktree path."
        } elseif ($line.StartsWith("HEAD ", [StringComparison]::Ordinal)) {
            $current.head = $line.Substring(5)
        } elseif ($line.StartsWith("branch ", [StringComparison]::Ordinal)) {
            $current.branch = $line.Substring(7)
        }
    }
    return $records.ToArray()
}

function Get-CommitTree {
    param([string]$Repository, [string]$Revision)
    $result = Invoke-LifecycleGit -Repository $Repository -Arguments @("show", "-s", "--format=%T", $Revision) -AllowFailure
    if ($result.code -ne 0 -or @($result.output).Count -ne 1 -or [string]$result.output[0] -cnotmatch '^[0-9a-f]{40}$') {
        return $null
    }
    return [string]$result.output[0]
}

function Get-MainRelation {
    param([string]$Repository, [string]$Tip, [string]$MainTip)
    if ($Tip -ceq $MainTip) { return "equal" }
    if ($null -eq (Get-CommitTree -Repository $Repository -Revision $Tip)) { return "unknown" }
    $ancestor = Invoke-LifecycleGit -Repository $Repository -Arguments @("merge-base", "--is-ancestor", $Tip, $MainTip) -AllowFailure
    if ($ancestor.code -eq 0) { return "ancestor" }
    if ($ancestor.code -eq 1) { return "divergent" }
    return "unknown"
}

function Copy-ChecksCanonical {
    param([object]$Checks)
    $copy = [ordered]@{}
    foreach ($name in $checkOrder) {
        $source = $Checks.$name
        $consumerIds = @($source.consumer_ids | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
        if ([string]$source.status -ceq "yes" -and $consumerIds.Count -eq 0) {
            throw "Check '$name' says yes but has no consumer_ids."
        }
        if ([string]$source.status -ceq "no" -and $consumerIds.Count -ne 0) {
            throw "Check '$name' says no but still names consumer_ids."
        }
        $copy[$name] = [ordered]@{
            status = [string]$source.status
            evidence_refs = @($source.evidence_refs | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
            consumer_ids = $consumerIds
            reevaluation_gate = [string]$source.reevaluation_gate
        }
    }
    return $copy
}

$registryText = Get-Content -Raw -LiteralPath $RegistryPath
if (-not (Test-Json -Json $registryText -SchemaFile $SchemaPath -ErrorAction Stop)) {
    throw "Repository lifecycle registry failed its schema."
}
$registry = $registryText | ConvertFrom-Json -Depth 50 -DateKind String
if ([string]$registry.schema -cne "rusty.morphospace.workflow.repository_lifecycle_registry.v1") {
    throw "Registry has the wrong schema ID."
}

$seenRepoIds = @{}
$repositories = New-Object System.Collections.Generic.List[object]
$candidateCount = 0
$holdCount = 0
$incompleteCount = 0
$refCount = 0

foreach ($repository in @($registry.repositories | Sort-Object -Property repo_id -CaseSensitive)) {
    $repoId = [string]$repository.repo_id
    if ($seenRepoIds.ContainsKey($repoId)) { throw "Duplicate repo_id '$repoId'." }
    $seenRepoIds[$repoId] = $true
    $repoRoot = (Resolve-Path -LiteralPath ([string]$repository.repository_root)).Path
    $inside = Invoke-LifecycleGit -Repository $repoRoot -Arguments @("rev-parse", "--is-inside-work-tree")
    if (@($inside.output).Count -ne 1 -or [string]$inside.output[0] -cne "true") { throw "Repository '$repoId' is not a Git worktree." }

    $remote = [string]$repository.remote
    $defaultBranch = [string]$repository.default_branch
    $remoteTips = Get-RemoteBranchTips -Repository $repoRoot -Remote $remote
    $mainRef = "refs/heads/$defaultBranch"
    if (-not $remoteTips.ContainsKey($mainRef)) { throw "Repository '$repoId' default ref '$mainRef' is absent from remote '$remote'." }
    $mainTip = [string]$remoteTips[$mainRef]
    $mainTree = Get-CommitTree -Repository $repoRoot -Revision $mainTip
    if ($null -eq $mainTree) { throw "Repository '$repoId' does not contain the current default-branch object '$mainTip'; update it outside this read-only inspector first." }

    $worktrees = @(Get-WorktreeObservations -Repository $repoRoot)
    $repoRefs = New-Object System.Collections.Generic.List[object]
    $seenRefs = @{}
    foreach ($refRecord in @($repository.refs | Sort-Object -Property ref -CaseSensitive)) {
        $refCount++
        $ref = [string]$refRecord.ref
        if ($seenRefs.ContainsKey($ref)) { throw "Repository '$repoId' repeats ref '$ref'." }
        $seenRefs[$ref] = $true
        $expectedTip = [string]$refRecord.expected_tip
        $observedTip = if ($remoteTips.ContainsKey($ref)) { [string]$remoteTips[$ref] } else { $null }
        $tipUnchanged = $null -ne $observedTip -and $observedTip -ceq $expectedTip
        $relation = if ($null -eq $observedTip) { "unknown" } else { Get-MainRelation -Repository $repoRoot -Tip $observedTip -MainTip $mainTip }
        $branchName = $ref.Substring("refs/heads/".Length)
        $localBranchRef = "refs/heads/$branchName"
        $matchingWorktrees = @(
            $worktrees |
                Where-Object { [string]$_.branch -ceq $localBranchRef } |
                ForEach-Object { [string]$_.path } |
                Sort-Object -CaseSensitive -Unique
        )
        $checks = Copy-ChecksCanonical -Checks $refRecord.checks
        $reasons = New-Object System.Collections.Generic.List[string]
        $gates = New-Object System.Collections.Generic.List[string]
        $hasUnknown = $false
        $hasConsumer = $false

        foreach ($checkName in $checkOrder) {
            $check = $checks[$checkName]
            if ([string]$check.status -ceq "yes") {
                $hasConsumer = $true
                $reasons.Add([string]$reasonByCheck[$checkName]) | Out-Null
                $gates.Add([string]$check.reevaluation_gate) | Out-Null
            } elseif ([string]$check.status -ceq "unknown") {
                $hasUnknown = $true
                $reasons.Add(($checkName.Replace('_', '-') + "-unknown")) | Out-Null
                $gates.Add([string]$check.reevaluation_gate) | Out-Null
            }
        }

        $registryWorktreeStatus = [string]$checks.registered_worktree_consumer.status
        if ($matchingWorktrees.Count -gt 0 -and $registryWorktreeStatus -ceq "no") {
            $hasUnknown = $true
            $reasons.Add("registered-worktree-observation-mismatch") | Out-Null
            $gates.Add("refresh-worktree-consumer-evidence") | Out-Null
        }
        $unreadableMatchingWorktrees = @(
            $worktrees |
                Where-Object { [string]$_.branch -ceq $localBranchRef -and -not $_.status_readable } |
                ForEach-Object { [string]$_.path } |
                Sort-Object -CaseSensitive -Unique
        )
        if ($unreadableMatchingWorktrees.Count -gt 0) {
            $hasUnknown = $true
            $reasons.Add("registered-worktree-status-unreadable") | Out-Null
            $gates.Add("repair-or-release-unreadable-worktree-registration") | Out-Null
        }
        if ($ref -ceq $mainRef) {
            $hasConsumer = $true
            $reasons.Add("default-branch") | Out-Null
            $gates.Add("explicit-owner-default-branch-redesign") | Out-Null
        }
        if ($null -eq $observedTip) {
            $hasUnknown = $true
            $reasons.Add("remote-ref-missing") | Out-Null
            $gates.Add("refresh-remote-ref-inventory") | Out-Null
        } elseif (-not $tipUnchanged) {
            $hasUnknown = $true
            $reasons.Add("tip-changed") | Out-Null
            $gates.Add("refresh-exact-tip-registry") | Out-Null
        }
        if ($relation -ceq "divergent") {
            $hasConsumer = $true
            $reasons.Add("divergent-from-main") | Out-Null
            $gates.Add("preserve-commit-and-re-admit-wanted-slice-from-current-main") | Out-Null
        } elseif ($relation -ceq "unknown") {
            $hasUnknown = $true
            $reasons.Add("main-ancestry-unknown") | Out-Null
            $gates.Add("materialize-exact-tip-object-and-refresh-ancestry") | Out-Null
        }

        $disposition = if ($hasUnknown) { "incomplete" } elseif ($hasConsumer) { "hold" } else { "candidate-retire" }
        if ($disposition -ceq "candidate-retire") {
            $candidateCount++
            $reasons.Add("main-reachable-no-consumer") | Out-Null
            $gates.Add("repository-owner-release-and-exact-tip-recovery-manifest") | Out-Null
        } elseif ($disposition -ceq "hold") {
            $holdCount++
        } else {
            $incompleteCount++
        }

        $repoRefs.Add([ordered]@{
            ref = $ref
            expected_tip = $expectedTip
            observed_tip = $observedTip
            tip_unchanged = [bool]$tipUnchanged
            main_relation = $relation
            registered_worktree_paths = $matchingWorktrees
            checks = $checks
            disposition = $disposition
            reason_codes = @($reasons | Sort-Object -CaseSensitive -Unique)
            confidence = if ($hasUnknown) { "low" } else { "high" }
            reevaluation_gates = @($gates | Sort-Object -CaseSensitive -Unique)
        }) | Out-Null
    }

    $repositories.Add([ordered]@{
        repo_id = $repoId
        repository_root = $repoRoot
        remote = $remote
        default_branch = $defaultBranch
        main_tip = $mainTip
        main_tree = $mainTree
        worktree_count = $worktrees.Count
        dirty_worktree_count = @($worktrees | Where-Object { $_.status_readable -and $_.dirty }).Count
        unreadable_worktree_count = @($worktrees | Where-Object { -not $_.status_readable }).Count
        refs = $repoRefs.ToArray()
    }) | Out-Null
}

$result = [ordered]@{
    schema = "rusty.morphospace.workflow.repository_lifecycle_advisory.v1"
    observed_at_utc = [string]$registry.observed_at_utc
    execution = "not-performed"
    git_mutation_performed = $false
    remote_mutation_performed = $false
    deletion_authority = "repository-owner-only"
    repositories = $repositories.ToArray()
    summary = [ordered]@{
        repository_count = $repositories.Count
        ref_count = $refCount
        candidate_retire_count = $candidateCount
        hold_count = $holdCount
        incomplete_count = $incompleteCount
    }
}
$json = ($result | ConvertTo-Json -Depth 50).Replace("`r`n", "`n") + "`n"
if (-not (Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop)) {
    throw "Repository lifecycle advisory result failed its schema."
}

if ($OutPath) {
    $fullOutPath = [IO.Path]::GetFullPath($OutPath)
    $parent = Split-Path -Parent $fullOutPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output parent does not exist: $parent" }
    if (Test-Path -LiteralPath $fullOutPath) { throw "Refusing to overwrite lifecycle output: $fullOutPath" }
    [IO.File]::WriteAllText($fullOutPath, $json, [Text.UTF8Encoding]::new($false))
}
Write-Output $json
