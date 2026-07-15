param(
    [string]$Path = "",
    [string]$RepoMapPath = "",
    [ValidateSet("CandidateCut", "HistoricalClosure")]
    [string]$Mode = "HistoricalClosure",
    [string]$OutPath = "",
    [string]$ReceiptPath = "",
    [string]$ClosureReceiptPath = "",
    [switch]$SchemaOnly,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$IdPattern = "^[a-z0-9][a-z0-9-]{1,127}$"
$RevisionPattern = "^[0-9a-f]{40}$"
$ShaPattern = "^[0-9a-f]{64}$"

function Invoke-CapsuleGit {
    param([string]$Repository, [string[]]$Arguments, [switch]$AllowFailure)
    $output = @(& git -C $Repository @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "git -C '$Repository' $($Arguments -join ' ') failed ($code): $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ Code = $code; Output = $output }
}

function Add-CapsuleFailure {
    param([System.Collections.Generic.List[string]]$Failures, [string]$Message)
    $Failures.Add($Message) | Out-Null
}

function Test-CapsuleShape {
    param([object]$Capsule)
    $failures = New-Object System.Collections.Generic.List[string]
    if ([string]$Capsule.schema -cne "rusty.morphospace.workflow.release_capsule.v1") { Add-CapsuleFailure $failures "Wrong release capsule schema ID." }
    foreach ($property in @("capsule_id", "project_id", "release_id")) {
        if ([string]$Capsule.$property -cnotmatch $IdPattern) { Add-CapsuleFailure $failures "Invalid or missing '$property'." }
    }
    if ([string]$Capsule.release_version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') { Add-CapsuleFailure $failures "Invalid release_version." }
    if ([string]$Capsule.status -cne "sealed") { Add-CapsuleFailure $failures "Release capsule must be sealed." }
    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Capsule.created_at, [ref]$timestamp)) { Add-CapsuleFailure $failures "Invalid created_at timestamp." }

    $policy = $Capsule.closure_policy
    $expectedPolicy = [ordered]@{
        candidate_cut_remote_relation = "exact"
        historical_closure_remote_relation = "ancestor-or-equal"
        active_worktrees = "observed-not-materialized"
        materialization = "isolated-clean-tree"
        branch_convergence = "candidate-cut-only"
        receipt_history = "append-only"
    }
    foreach ($key in $expectedPolicy.Keys) {
        if ([string]$policy.$key -cne [string]$expectedPolicy[$key]) { Add-CapsuleFailure $failures "closure_policy.$key must be '$($expectedPolicy[$key])'." }
    }

    $repositories = @($Capsule.repositories)
    if ($repositories.Count -eq 0) { Add-CapsuleFailure $failures "repositories must not be empty." }
    $seen = @{}
    foreach ($repository in $repositories) {
        $repoId = [string]$repository.repo_id
        if ($repoId -cnotmatch $IdPattern) { Add-CapsuleFailure $failures "Repository has invalid repo_id '$repoId'." }
        if ($seen.ContainsKey($repoId)) { Add-CapsuleFailure $failures "Repository '$repoId' is repeated." } else { $seen[$repoId] = $true }
        if (@("release-source", "workflow-tool", "planning-authority", "evidence-producer") -cnotcontains [string]$repository.role) { Add-CapsuleFailure $failures "Repository '$repoId' has invalid role." }
        if ([string]::IsNullOrWhiteSpace([string]$repository.remote_url)) { Add-CapsuleFailure $failures "Repository '$repoId' needs remote_url." }
        foreach ($property in @("revision", "tree")) {
            if ([string]$repository.$property -cnotmatch $RevisionPattern) { Add-CapsuleFailure $failures "Repository '$repoId' has invalid $property." }
        }
        if ([string]$repository.overlay_disposition -cne "excluded") { Add-CapsuleFailure $failures "Repository '$repoId' must exclude worktree overlays." }
        if ([string]$repository.materialization -cne "isolated-clean-tree") { Add-CapsuleFailure $failures "Repository '$repoId' must use isolated-clean-tree materialization." }
        if (@($repository.remote_refs).Count -eq 0) { Add-CapsuleFailure $failures "Repository '$repoId' needs at least one remote ref." }
        $refIds = @{}
        foreach ($remoteRef in @($repository.remote_refs)) {
            if ([string]$remoteRef.ref_id -cnotmatch $IdPattern) { Add-CapsuleFailure $failures "Repository '$repoId' has invalid ref_id." }
            if ($refIds.ContainsKey([string]$remoteRef.ref_id)) { Add-CapsuleFailure $failures "Repository '$repoId' repeats ref_id '$($remoteRef.ref_id)'." } else { $refIds[[string]$remoteRef.ref_id] = $true }
            if ([string]$remoteRef.ref -cnotmatch '^refs/(heads|tags)/') { Add-CapsuleFailure $failures "Repository '$repoId' has invalid full Git ref '$($remoteRef.ref)'." }
        }
        if (@($repository.validation_refs).Count -eq 0) { Add-CapsuleFailure $failures "Repository '$repoId' needs validation_refs." }
    }
    if (@($Capsule.validations).Count -eq 0) { Add-CapsuleFailure $failures "validations must not be empty." }
    foreach ($binding in @($Capsule.validations)) {
        if ([string]$binding.artifact_id -cnotmatch $IdPattern -or [string]$binding.path -eq "" -or [string]$binding.sha256 -cnotmatch $ShaPattern) { Add-CapsuleFailure $failures "Invalid validation binding." }
    }
    foreach ($binding in @($Capsule.external_receipts)) {
        if (@("hash-bound", "damaged-original-unavailable", "independent-reconstruction") -cnotcontains [string]$binding.integrity) { Add-CapsuleFailure $failures "External receipt '$($binding.artifact_id)' has invalid integrity." }
        if ([string]$binding.integrity -ceq "hash-bound" -and [string]$binding.sha256 -cnotmatch $ShaPattern) { Add-CapsuleFailure $failures "Hash-bound external receipt '$($binding.artifact_id)' needs sha256." }
        if ([string]$binding.integrity -ceq "damaged-original-unavailable" -and ([string]$binding.expected_sha256 -cnotmatch $ShaPattern -or [string]$binding.observed_sha256 -cnotmatch $ShaPattern)) { Add-CapsuleFailure $failures "Damaged external receipt '$($binding.artifact_id)' needs expected and observed hashes." }
    }
    if (@($Capsule.does_not_prove).Count -eq 0) { Add-CapsuleFailure $failures "does_not_prove must not be empty." }
    return $failures
}

function Test-ReceiptBinding {
    param([string]$ValidationReceiptPath)
    $receipt = Get-Content -Raw -LiteralPath $ValidationReceiptPath | ConvertFrom-Json
    if ([string]$receipt.schema -cne "rusty.morphospace.workflow.release_capsule_validation_receipt.v1" -or [string]$receipt.status -cne "pass") { throw "Validation receipt schema or status is invalid." }
    $capsulePath = [string]$receipt.capsule.path
    if (-not (Test-Path -LiteralPath $capsulePath -PathType Leaf)) { throw "Validation receipt capsule path does not exist." }
    $actual = (Get-FileHash -LiteralPath $capsulePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne ([string]$receipt.capsule.sha256).ToLowerInvariant()) { throw "Validation receipt capsule SHA-256 does not match." }
    return $receipt
}

function Test-HistoricalClosureReceipt {
    param([string]$ClosurePath)
    $receipt = Get-Content -Raw -LiteralPath $ClosurePath | ConvertFrom-Json
    if ([string]$receipt.schema -cne "rusty.morphospace.workflow.historical_release_closure_receipt.v1" -or [string]$receipt.status -cne "closed") { throw "Historical closure receipt schema or status is invalid." }
    foreach ($property in @("capsule", "historical_validation", "exact_tree_graph")) {
        $binding = $receipt.$property
        if (-not (Test-Path -LiteralPath ([string]$binding.path) -PathType Leaf)) { throw "Historical closure binding '$property' does not exist." }
        $actual = (Get-FileHash -LiteralPath ([string]$binding.path) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne ([string]$binding.sha256).ToLowerInvariant()) { throw "Historical closure binding '$property' has a SHA-256 mismatch." }
    }
    $reconstruction = $receipt.publication_evidence.reconstruction
    if (-not (Test-Path -LiteralPath ([string]$reconstruction.path) -PathType Leaf)) { throw "Historical closure reconstruction does not exist." }
    if ((Get-FileHash -LiteralPath ([string]$reconstruction.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne ([string]$reconstruction.sha256).ToLowerInvariant()) { throw "Historical closure reconstruction has a SHA-256 mismatch." }
    if ([string]$receipt.publication_evidence.original_binding_status -cne "damaged-original-unavailable" -or [string]$receipt.publication_evidence.claim -cne "independent-reconstruction-not-original-bytes") { throw "Historical closure must keep damaged original evidence distinct from its reconstruction." }
    if ($receipt.active_work_preservation.mutated -ne $false -or [string]$receipt.active_work_preservation.disposition -cne "observed-not-materialized") { throw "Historical closure must preserve active work as observed-not-materialized." }
    if ([string]$receipt.device_validation -cne "historical-evidence-reused-no-device-rerun") { throw "Historical closure has an invalid device-validation disposition." }
    if (@($receipt.does_not_prove).Count -eq 0) { throw "Historical closure needs does_not_prove limitations." }
    $capsule = Get-Content -Raw -LiteralPath ([string]$receipt.capsule.path) | ConvertFrom-Json
    $historical = Get-Content -Raw -LiteralPath ([string]$receipt.historical_validation.path) | ConvertFrom-Json
    if ([string]$capsule.release_id -cne [string]$receipt.release_id -or [string]$historical.mode -cne "historical-closure" -or [string]$historical.status -cne "pass") { throw "Historical closure subjects do not agree." }
    return $receipt
}

function Invoke-ReleaseCapsuleValidation {
    param([string]$CapsulePath, [string]$MapPath, [string]$ValidationMode, [string]$OutputPath, [switch]$OnlyShape)
    if (-not (Test-Path -LiteralPath $CapsulePath -PathType Leaf)) { throw "Release capsule not found: $CapsulePath" }
    $resolvedCapsulePath = (Resolve-Path -LiteralPath $CapsulePath).Path
    $capsule = Get-Content -Raw -LiteralPath $resolvedCapsulePath | ConvertFrom-Json
    $shapeFailures = Test-CapsuleShape -Capsule $capsule
    if ($shapeFailures.Count -gt 0) { throw ($shapeFailures -join [Environment]::NewLine) }
    if ($OnlyShape) { return $null }

    if (-not (Test-Path -LiteralPath $MapPath -PathType Leaf)) { throw "Repository map not found: $MapPath" }
    $repoMap = Get-Content -Raw -LiteralPath $MapPath | ConvertFrom-Json
    $paths = @{}
    foreach ($row in @($repoMap.repositories)) { $paths[[string]$row.repo_id] = [string]$row.path }
    $failures = New-Object System.Collections.Generic.List[string]
    $results = New-Object System.Collections.Generic.List[object]
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("mrc-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        foreach ($repository in @($capsule.repositories)) {
            $repoId = [string]$repository.repo_id
            if (-not $paths.ContainsKey($repoId)) { Add-CapsuleFailure $failures "Repository map omits '$repoId'."; continue }
            $activePath = $paths[$repoId]
            if (-not (Test-Path -LiteralPath (Join-Path $activePath ".git"))) { Add-CapsuleFailure $failures "Mapped path for '$repoId' is not a Git worktree."; continue }
            $dirtyEntries = @(Invoke-CapsuleGit -Repository $activePath -Arguments @("status", "--porcelain=v1") | Select-Object -ExpandProperty Output).Count
            $isolatedPath = Join-Path $tempRoot $repoId
            $cloneOutput = @(& git clone --quiet --no-hardlinks --no-checkout $activePath $isolatedPath 2>&1 | ForEach-Object { [string]$_ })
            if ($LASTEXITCODE -ne 0) { Add-CapsuleFailure $failures "Could not isolate '$repoId': $($cloneOutput -join ' ')"; continue }
            try {
                Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("config", "core.longpaths", "true") | Out-Null
                Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("remote", "set-url", "origin", [string]$repository.remote_url) | Out-Null
                $actualTree = (Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("rev-parse", "$($repository.revision)^{tree}")).Output[-1].Trim()
                if ($actualTree -cne [string]$repository.tree) { Add-CapsuleFailure $failures "Repository '$repoId' pinned tree does not match the pinned commit." }
                $observations = New-Object System.Collections.Generic.List[object]
                foreach ($remoteRef in @($repository.remote_refs)) {
                    $destination = "refs/remotes/capsule/$($remoteRef.ref_id)"
                    $fetch = Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("fetch", "--quiet", "--no-tags", "origin", "+$($remoteRef.ref):$destination") -AllowFailure
                    if ($fetch.Code -ne 0) { Add-CapsuleFailure $failures "Repository '$repoId' remote ref '$($remoteRef.ref)' is missing or unavailable."; continue }
                    $observed = (Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("rev-parse", $destination)).Output[-1].Trim()
                    $relation = ""
                    if ($observed -ceq [string]$repository.revision) {
                        $relation = "exact"
                    } else {
                        $ancestry = Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("merge-base", "--is-ancestor", [string]$repository.revision, $observed) -AllowFailure
                        if ($ancestry.Code -eq 0) { $relation = "descendant" } else { Add-CapsuleFailure $failures "Repository '$repoId' remote ref '$($remoteRef.ref)' no longer descends from the capsule revision."; $relation = "rewrite" }
                    }
                    if ($ValidationMode -ceq "CandidateCut" -and $relation -cne "exact") { Add-CapsuleFailure $failures "Candidate-cut requires '$repoId' ref '$($remoteRef.ref)' to equal the capsule revision." }
                    if ($relation -ne "rewrite") { $observations.Add([ordered]@{ ref_id = [string]$remoteRef.ref_id; ref = [string]$remoteRef.ref; observed_revision = $observed; relation = $relation }) | Out-Null }
                }
                Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("checkout", "--quiet", "--detach", [string]$repository.revision) | Out-Null
                $isolatedDirty = @(Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("status", "--porcelain=v1") | Select-Object -ExpandProperty Output).Count
                $isolatedRevision = (Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("rev-parse", "HEAD")).Output[-1].Trim()
                $isolatedTree = (Invoke-CapsuleGit -Repository $isolatedPath -Arguments @("rev-parse", "HEAD^{tree}")).Output[-1].Trim()
                if ($isolatedDirty -ne 0 -or $isolatedRevision -cne [string]$repository.revision -or $isolatedTree -cne [string]$repository.tree) { Add-CapsuleFailure $failures "Repository '$repoId' isolated materialization is not the exact clean capsule tree." }
                $results.Add([ordered]@{
                    repo_id = $repoId; pinned_revision = [string]$repository.revision; pinned_tree = [string]$repository.tree
                    commit_present = $true; tree_match = ($actualTree -ceq [string]$repository.tree); remote_observations = @($observations | ForEach-Object { $_ })
                    active_worktree = [ordered]@{ disposition = "observed-not-materialized"; dirty_entries = $dirtyEntries }
                    isolated_materialization = [ordered]@{ status = $(if ($isolatedDirty -eq 0) { "clean" } else { "dirty" }); revision = $isolatedRevision; tree = $isolatedTree; dirty_entries = $isolatedDirty }
                }) | Out-Null
            } catch { Add-CapsuleFailure $failures "Repository '$repoId' validation failed: $($_.Exception.Message)" }
        }
    } finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
    if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
    $modeId = if ($ValidationMode -ceq "CandidateCut") { "candidate-cut" } else { "historical-closure" }
    $receipt = [ordered]@{
        schema = "rusty.morphospace.workflow.release_capsule_validation_receipt.v1"
        receipt_id = "$($capsule.release_id)-$modeId-validation"
        created_at = [DateTimeOffset]::UtcNow.ToString("o")
        mode = $modeId; status = "pass"
        capsule = [ordered]@{ path = $resolvedCapsulePath; sha256 = (Get-FileHash -LiteralPath $resolvedCapsulePath -Algorithm SHA256).Hash.ToLowerInvariant() }
        repositories = @($results | ForEach-Object { $_ }); remote_rewrite_detected = $false; active_worktrees_mutated = $false
        does_not_prove = @("Active worktree overlays were observed only and are not release payload.", "Historical closure does not validate commits made after the sealed candidate cut.")
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $parent = Split-Path -Parent $OutputPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    }
    return [pscustomobject]$receipt
}

function Invoke-ReleaseCapsuleSelfTest {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("morphospace-release-capsule-selftest-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $remote = Join-Path $root "remote.git"; $seed = Join-Path $root "seed"; $active = Join-Path $root "active"
        & git init --bare --quiet $remote; if ($LASTEXITCODE -ne 0) { throw "Self-test bare init failed." }
        & git init --quiet -b main $seed; if ($LASTEXITCODE -ne 0) { throw "Self-test seed init failed." }
        Invoke-CapsuleGit $seed @("config", "user.email", "capsule@example.invalid") | Out-Null; Invoke-CapsuleGit $seed @("config", "user.name", "Capsule Test") | Out-Null
        Set-Content -LiteralPath (Join-Path $seed "payload.txt") -Value "release"
        Invoke-CapsuleGit $seed @("add", "payload.txt") | Out-Null; Invoke-CapsuleGit $seed @("commit", "--quiet", "-m", "release") | Out-Null
        Invoke-CapsuleGit $seed @("remote", "add", "origin", $remote) | Out-Null; Invoke-CapsuleGit $seed @("push", "--quiet", "-u", "origin", "main") | Out-Null
        & git --git-dir=$remote symbolic-ref HEAD refs/heads/main
        if ($LASTEXITCODE -ne 0) { throw "Self-test remote HEAD setup failed." }
        $revision = (Invoke-CapsuleGit $seed @("rev-parse", "HEAD")).Output[-1].Trim(); $tree = (Invoke-CapsuleGit $seed @("rev-parse", "HEAD^{tree}")).Output[-1].Trim()
        & git clone --quiet $remote $active; if ($LASTEXITCODE -ne 0) { throw "Self-test active clone failed." }
        $capsulePath = Join-Path $root "capsule.json"; $mapPath = Join-Path $root "map.json"; $receiptPath = Join-Path $root "receipt.json"
        $capsule = [ordered]@{
            '$schema' = "release-capsule.schema.json"; schema = "rusty.morphospace.workflow.release_capsule.v1"; capsule_id = "selftest-capsule"; project_id = "selftest-project"; release_id = "rel-001"; release_version = "1.0.0"; status = "sealed"; created_at = "2026-01-01T00:00:00Z"
            closure_policy = [ordered]@{ candidate_cut_remote_relation = "exact"; historical_closure_remote_relation = "ancestor-or-equal"; active_worktrees = "observed-not-materialized"; materialization = "isolated-clean-tree"; branch_convergence = "candidate-cut-only"; receipt_history = "append-only" }
            repositories = @([ordered]@{ repo_id = "selftest-source"; role = "release-source"; remote_url = $remote; revision = $revision; tree = $tree; remote_refs = @([ordered]@{ ref_id = "selftest-main"; ref = "refs/heads/main" }); payload = $true; overlay_disposition = "excluded"; materialization = "isolated-clean-tree"; validation_refs = @("source-validation") })
            validations = @([ordered]@{ artifact_id = "source-validation"; path = "fixture"; sha256 = ("3" * 64) }); external_receipts = @(); does_not_prove = @("Self-test only.")
        }
        $capsule | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $capsulePath -Encoding utf8
        [ordered]@{ schema = "rusty.morphospace.workflow.repository_map.v1"; repositories = @([ordered]@{ repo_id = "selftest-source"; path = $active; role = "source"; aliases = @() }) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mapPath -Encoding utf8
        Invoke-ReleaseCapsuleValidation $capsulePath $mapPath "CandidateCut" $receiptPath | Out-Null
        Add-Content -LiteralPath (Join-Path $active "payload.txt") -Value "local overlay"
        Set-Content -LiteralPath (Join-Path $seed "later.txt") -Value "later"
        Invoke-CapsuleGit $seed @("add", "later.txt") | Out-Null; Invoke-CapsuleGit $seed @("commit", "--quiet", "-m", "later") | Out-Null; Invoke-CapsuleGit $seed @("push", "--quiet", "origin", "main") | Out-Null
        $historical = Invoke-ReleaseCapsuleValidation $capsulePath $mapPath "HistoricalClosure" $receiptPath
        if ($historical.repositories[0].active_worktree.dirty_entries -lt 1) { throw "Historical closure did not preserve/observe the dirty active tree." }
        $failed = $false; try { Invoke-ReleaseCapsuleValidation $capsulePath $mapPath "CandidateCut" "" | Out-Null } catch { $failed = $true }; if (-not $failed) { throw "Candidate-cut accepted an advanced remote." }
        $capsule.repositories[0].tree = ("f" * 40); $capsule | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $capsulePath -Encoding utf8
        $failed = $false; try { Invoke-ReleaseCapsuleValidation $capsulePath $mapPath "HistoricalClosure" "" | Out-Null } catch { $failed = $true }; if (-not $failed) { throw "Historical closure accepted the wrong tree." }
        $capsule.repositories[0].tree = $tree; $capsule | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $capsulePath -Encoding utf8
        Invoke-ReleaseCapsuleValidation $capsulePath $mapPath "HistoricalClosure" $receiptPath | Out-Null
        Add-Content -LiteralPath $capsulePath -Value " "
        $failed = $false; try { Test-ReceiptBinding $receiptPath | Out-Null } catch { $failed = $true }; if (-not $failed) { throw "Receipt binding accepted a modified capsule." }
        $capsule.repositories[0].remote_refs[0].ref = "refs/heads/missing"
        $capsule | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $capsulePath -Encoding utf8
        $failed = $false; try { Invoke-ReleaseCapsuleValidation $capsulePath $mapPath "HistoricalClosure" "" | Out-Null } catch { $failed = $true }; if (-not $failed) { throw "Historical closure accepted a missing remote ref." }
        $capsule.repositories[0].remote_refs[0].ref = "refs/heads/main"
        $capsule.closure_policy.active_worktrees = "must-be-clean"
        $capsule | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $capsulePath -Encoding utf8
        $failed = $false; try { Invoke-ReleaseCapsuleValidation $capsulePath $mapPath "HistoricalClosure" "" | Out-Null } catch { $failed = $true }; if (-not $failed) { throw "Historical closure accepted a mutated closure policy." }
        $capsule.closure_policy.active_worktrees = "observed-not-materialized"
        $capsule | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $capsulePath -Encoding utf8
        Invoke-CapsuleGit $seed @("checkout", "--quiet", "--force", "--orphan", "rewritten") | Out-Null
        Invoke-CapsuleGit $seed @("rm", "--quiet", "--force", "-r", ".") | Out-Null
        Set-Content -LiteralPath (Join-Path $seed "replacement.txt") -Value "unrelated history"
        Invoke-CapsuleGit $seed @("add", "replacement.txt") | Out-Null; Invoke-CapsuleGit $seed @("commit", "--quiet", "-m", "rewrite") | Out-Null
        Invoke-CapsuleGit $seed @("push", "--quiet", "--force", "origin", "HEAD:main") | Out-Null
        $failed = $false; try { Invoke-ReleaseCapsuleValidation $capsulePath $mapPath "HistoricalClosure" "" | Out-Null } catch { $failed = $true }; if (-not $failed) { throw "Historical closure accepted a rewritten remote history." }
        Write-Output "Release capsule self-test passed: exact cut, later descendant, dirty-overlay preservation, wrong-tree, missing-ref, policy-mutation, hash-tamper, and history-rewrite rejection."
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

if ($SelfTest) { Invoke-ReleaseCapsuleSelfTest; exit 0 }
if (-not [string]::IsNullOrWhiteSpace($ClosureReceiptPath)) { Test-HistoricalClosureReceipt $ClosureReceiptPath | Out-Null; Write-Output "Historical release closure receipt is hash-bound and valid."; exit 0 }
if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) { Test-ReceiptBinding $ReceiptPath | Out-Null; Write-Output "Release capsule validation receipt is hash-bound and valid."; exit 0 }
if ([string]::IsNullOrWhiteSpace($Path)) { throw "Provide -Path, -ReceiptPath, -ClosureReceiptPath, or -SelfTest." }
$result = Invoke-ReleaseCapsuleValidation -CapsulePath $Path -MapPath $RepoMapPath -ValidationMode $Mode -OutputPath $OutPath -OnlyShape:$SchemaOnly
if ($SchemaOnly) { Write-Output "Release capsule contract is semantically valid." } else { $result }
