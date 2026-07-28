param()

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot "WorkUnitAutomation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\MorphospacePlanningProjection.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceProtocolCommon.psm1") -Force

function Assert-Automation {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Automation self-test failed: $Message" }
}

# Exercise the public script in a fresh pwsh process so action/parameter routing
# cannot pass merely because this test imported the module in-process.
$freshStdout = [IO.Path]::GetTempFileName()
$freshStderr = [IO.Path]::GetTempFileName()
try {
    $freshPwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $fresh = Start-Process -FilePath $freshPwsh -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1"),
        "-Action", "ReconcilePublishedPrerequisiteSuffix", "-WorkspaceRoot", (Join-Path ([IO.Path]::GetTempPath()) "missing-published-prerequisite-workspace"),
        "-UnitId", "test-unit", "-RepoMapPath", "missing-repository-map.json",
        "-PublishedPrerequisiteSuffixReconciliation", "receipts/missing-reconciliation.json"
    ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $freshStdout -RedirectStandardError $freshStderr
    $freshText = ((Get-Content -Raw $freshStdout -ErrorAction SilentlyContinue) + (Get-Content -Raw $freshStderr -ErrorAction SilentlyContinue))
    Assert-Automation ($fresh.ExitCode -ne 0) "fresh-process reconciliation probe unexpectedly succeeded"
    Assert-Automation ($freshText -notmatch "Cannot validate argument on parameter 'Action'|named PublishedPrerequisiteSuffixReconciliation parameter cannot be found") "fresh-process public Invoke entrypoint does not expose published-prerequisite reconciliation"
} finally {
    if ($null -ne $fresh) { $fresh.Dispose() }
    Remove-Item -LiteralPath $freshStdout,$freshStderr -Force -ErrorAction SilentlyContinue
}

$freshStdout = [IO.Path]::GetTempFileName()
$freshStderr = [IO.Path]::GetTempFileName()
$fresh = $null
try {
    $freshPwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $fresh = Start-Process -FilePath $freshPwsh -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1"),
        "-Action", "AdoptPublishedPlanningAuthority", "-WorkspaceRoot", (Join-Path ([IO.Path]::GetTempPath()) "missing-planning-authority-adoption-workspace"),
        "-UnitId", "test-unit", "-RepoMapPath", "missing-repository-map.json",
        "-PublishedPlanningAuthorityAdoption", "receipts/missing-adoption.json"
    ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $freshStdout -RedirectStandardError $freshStderr
    $freshText = ((Get-Content -Raw $freshStdout -ErrorAction SilentlyContinue) + (Get-Content -Raw $freshStderr -ErrorAction SilentlyContinue))
    Assert-Automation ($fresh.ExitCode -ne 0) "fresh-process planning-authority adoption probe unexpectedly succeeded"
    Assert-Automation ($freshText -notmatch "Cannot validate argument on parameter 'Action'|named PublishedPlanningAuthorityAdoption parameter cannot be found") "fresh-process public Invoke entrypoint does not expose planning-authority adoption"
} finally {
    if ($null -ne $fresh) { $fresh.Dispose() }
    Remove-Item -LiteralPath $freshStdout,$freshStderr -Force -ErrorAction SilentlyContinue
}

$workUnitAutomationModule = Get-Module WorkUnitAutomation
$pathNormalizationResults = & $workUnitAutomationModule {
    [pscustomobject]@{
        exact = Test-MorphospacePathAllowed -Path ".github/workflows/ci.yml" -AllowedPaths @(".github/workflows/ci.yml")
        optional_prefix = Test-MorphospacePathAllowed -Path ".github/workflows/ci.yml" -AllowedPaths @("./.github/workflows/ci.yml")
        leading_dot_preserved = -not (Test-MorphospacePathAllowed -Path "github/workflows/ci.yml" -AllowedPaths @(".github/workflows/ci.yml"))
        hidden_directory = Test-MorphospacePathAllowed -Path ".config/tool/settings.json" -AllowedPaths @(".config/")
        explicit_relative = Test-MorphospacePathAllowed -Path "src/lib.rs" -AllowedPaths @("./src/")
    }
}
Assert-Automation ($pathNormalizationResults.exact -and $pathNormalizationResults.optional_prefix -and $pathNormalizationResults.leading_dot_preserved -and $pathNormalizationResults.hidden_directory -and $pathNormalizationResults.explicit_relative) "repository-relative path normalization"

$traversalRejected = $false
try {
    & $workUnitAutomationModule {
        Test-MorphospacePathAllowed -Path "src/lib.rs" -AllowedPaths @("../src/")
    } | Out-Null
} catch {
    $traversalRejected = $_.Exception.Message -like "Repository-relative path may not contain '..'*"
}
Assert-Automation $traversalRejected "traversal in an allowed path did not fail closed"

function Write-TestJson {
    param([string]$Path, [object]$Value)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 32) + [Environment]::NewLine), $encoding)
}

function Invoke-TestGit {
    param([string]$Path, [string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git -C $Path @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { throw "Test Git command failed: git -C $Path $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)" }
    return @($output)
}

function New-TestUnit {
    param([string]$ProjectId, [string]$UnitId)
    return [ordered]@{
        '$schema' = "../schemas/iteration-unit.schema.json"
        schema = "rusty.morphospace.workflow.iteration_unit.v1"
        unit_id = $UnitId; project_id = $ProjectId; status = "ready"
        objective = "Exercise fail-closed work-unit automation without touching real repositories or devices."
        change_categories = @("implementation")
        instruction_impact = "none"; instruction_surfaces = @()
        instruction_none_justification = "The temporary unit only exercises the existing automation contract."
        prerequisites = @()
        allowed_repositories = @([ordered]@{ repo_id = "project-shell"; allowed_paths = @("src/", "docs/", "morphospace/") })
        non_scope = @("Real repositories and live devices.")
        acceptance = @([ordered]@{ acceptance_id = "self-test"; proof = "The simulation passes."; command = "Test-WorkUnitAutomation.ps1" })
        risk_tier = "standard"; device_requirement = "none"
        validation = @([ordered]@{ profile_id = "workflow"; command = "temporary validation command" })
        outputs = @("automation receipt"); commit_policy = "Temporary repository only."
        push_checkpoint = "integration-batch"
    }
}

function New-TestWorkspace {
    param([string]$Root, [string]$ProjectId, [string]$UnitId)
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    & (Join-Path $PSScriptRoot "New-ProjectWorkspace.ps1") -ProjectRoot $Root -ProjectId $ProjectId -Purpose "Automation simulation." -Execute | Out-Null
    $workspace = Join-Path $Root "morphospace"
    Write-TestJson -Path (Join-Path $workspace "iteration-units\$UnitId.json") -Value (New-TestUnit -ProjectId $ProjectId -UnitId $UnitId)
    $statePath = Join-Path $workspace "workspace.state.json"
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.next_ready_unit = $UnitId
    Write-TestJson -Path $statePath -Value $state
    return $workspace
}

function New-TestValidationReceipt {
    param(
        [string]$Workspace,
        [string]$ProjectId,
        [string]$UnitId,
        [string]$Tier,
        [string]$Result,
        [object[]]$RepositoryRevisions = @(),
        [object[]]$ChangedPaths = @(),
        [string]$EvidenceName = "self-test-evidence.txt"
    )

    $receiptRoot = Join-Path $Workspace "receipts"
    [System.IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
    $evidencePath = Join-Path $receiptRoot $EvidenceName
    [System.IO.File]::WriteAllText($evidencePath, "validation evidence for $UnitId $Result`n", (New-Object System.Text.UTF8Encoding($false)))
    $hash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $status = if ($Result -eq "pass") { "pass" } else { "fail" }
    $receipt = [ordered]@{
        '$schema' = "../schemas/validation-receipt.schema.json"
        schema = "rusty.morphospace.workflow.validation_receipt.v1"
        receipt_id = "$UnitId-$Result-validation"
        project_id = $ProjectId
        unit_id = $UnitId
        created_at = "2026-01-02T03:04:05Z"
        tier = $Tier
        result = $Result
        repository_revisions = @($RepositoryRevisions)
        changed_paths = @($ChangedPaths)
        artifacts = @([ordered]@{
            artifact_id = "validation-evidence"
            kind = "test-log"
            path = $EvidenceName
            sha256 = $hash
        })
        criteria = @([ordered]@{
            acceptance_id = "self-test"
            status = $status
            command = "Test-WorkUnitAutomation.ps1"
            evidence_refs = @("validation-evidence")
        })
        gates = @([ordered]@{
            gate_id = "validation-workflow"
            status = $status
            command = "temporary validation command"
            evidence_refs = @("validation-evidence")
        })
        device_validation = $null
    }
    $receiptPath = Join-Path $receiptRoot "$UnitId-$Result-validation.json"
    Write-TestJson -Path $receiptPath -Value $receipt
    return $receiptPath
}

function New-TestInterruptionReceipt {
    param(
        [string]$Workspace,
        [string]$ProjectId,
        [string]$UnitId,
        [string]$Kind,
        [string]$Revision,
        [bool]$Safe = $true,
        [bool]$Cleanup = $true
    )

    $receiptRoot = Join-Path $Workspace "receipts"
    [System.IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
    $evidenceName = "$Kind-evidence.txt"
    $evidencePath = Join-Path $receiptRoot $evidenceName
    [System.IO.File]::WriteAllText($evidencePath, "interruption evidence for $Kind`n", (New-Object System.Text.UTF8Encoding($false)))
    $hash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $repositories = if ($Kind -eq "partial-cross-repo-commit") {
        @(
            [ordered]@{ repo_id = "project-shell"; observed_revision = $Revision; state = "committed" },
            [ordered]@{ repo_id = "planning-surface"; observed_revision = $Revision; state = "pending" }
        )
    } else {
        @([ordered]@{ repo_id = "project-shell"; observed_revision = $Revision; state = "preserved" })
    }
    $buildCleanup = if ($Kind -eq "interrupted-build") {
        [ordered]@{ active_process_count = 0; outputs_quarantined = $Cleanup; cleanup_actions = @("stop bounded build process", "quarantine partial output") }
    } else { $null }
    $deviceCleanup = if ($Kind -eq "interrupted-device") {
        [ordered]@{ serials = @("test-device-a", "test-device-b"); packages_remaining = @(); routes_inactive = $Cleanup; package_fatal_count = 0; system_fatal_count = 0 }
    } else { $null }
    $receipt = [ordered]@{
        '$schema' = "../schemas/interruption-receipt.schema.json"
        schema = "rusty.morphospace.workflow.interruption_receipt.v1"
        receipt_id = "$UnitId-$Kind-recovery"
        project_id = $ProjectId; unit_id = $UnitId; captured_at = "2026-01-02T03:04:05Z"
        interruption_kind = $Kind; safe_to_resume = $Safe; cleanup_complete = $Cleanup
        repositories = $repositories; build_cleanup = $buildCleanup; device_cleanup = $deviceCleanup
        artifacts = @([ordered]@{ artifact_id = "recovery-evidence"; path = $evidenceName; sha256 = $hash })
    }
    $path = Join-Path $receiptRoot "$UnitId-$Kind-recovery.json"
    Write-TestJson -Path $path -Value $receipt
    return $path
}

function New-TestInflightAdoptionReceipt {
    param(
        [string]$Workspace,
        [string]$UnitId,
        [string]$RepoMapPath,
        [string]$Timestamp
    )

    $path = Join-Path $Workspace "receipts\$UnitId-inflight-adoption.json"
    New-MorphospaceInflightAdoptionReceipt -WorkspaceRoot $Workspace -UnitId $UnitId -RepoMapPath $RepoMapPath -Timestamp $Timestamp -OutPath $path -Execute | Out-Null
    return $path
}

function New-TestUnplannedPublicationClosure {
    param(
        [string]$Workspace,
        [string]$ProjectId,
        [string]$UnitId,
        [string]$RepoId,
        [string]$Branch,
        [string]$Upstream,
        [string]$OldRevision,
        [string]$NewRevision,
        [string]$PendingBundle,
        [string]$ValidationReceipt
    )

    $statePath = Join-Path $Workspace 'workspace.state.json'
    $validationPath = Join-Path $Workspace $ValidationReceipt
    $stateHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $validationHash = (Get-FileHash -LiteralPath $validationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $closure = [ordered]@{
        schema = 'rusty.morphospace.workflow.unplanned_publication_closure.v1'
        closure_id = "$UnitId-unplanned-publication-closure"
        project_id = $ProjectId
        unit_id = $UnitId
        recorded_at = '2026-01-02T03:04:05Z'
        status = 'independent-reconstruction-verified'
        chronology = [ordered]@{
            classification = 'unplanned-push-before-prepare'
            prepared_plan_present = $false
            executed_push_receipt_present = $false
            does_not_claim = @('No pre-push PreparePush plan or executed-push receipt is claimed.')
        }
        workspace_state_before = [ordered]@{ path = 'workspace.state.json'; sha256 = $stateHash }
        repository = [ordered]@{
            repo_id = $RepoId; role = 'source-owner'; branch = $Branch; remote = 'origin'; upstream = $Upstream; action = 'pushed'
            old_revision = $OldRevision; new_revision = $NewRevision; observed_remote_revision = $NewRevision; rollback_revision = $OldRevision
            fast_forward_verified = $true; remote_match = $true; force_push_used = $false; worktree_clean = $true
            validation_refs = @('standard-validation')
        }
        validation = @([ordered]@{
            gate_id = 'standard-validation'; status = 'pass'
            evidence = [ordered]@{ path = $ValidationReceipt.Replace('\', '/'); sha256 = $validationHash }
        })
        observers = @([ordered]@{ observer_id = 'external-coordinator'; recorded_at = '2026-01-02T03:04:05Z'; evidence_sha256 = ('4' * 64) })
        workspace_transition = [ordered]@{
            pending_push_bundle_before = $PendingBundle; pending_push_bundle_after = $null
            dirty_repository_ids_to_clear = @($RepoId); repository_head_after = $NewRevision
        }
        remote_readback_complete = $true; recovery_scope = 'workflow-state-only'; failure = $null
    }
    $path = Join-Path $Workspace "receipts\$UnitId-unplanned-publication-closure.json"
    Write-TestJson -Path $path -Value $closure
    return $path
}

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("rusty-morphospace-automation-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $remote = Join-Path $testRoot "remote.git"
    $repo = Join-Path $testRoot "project-repo"
    $peer = Join-Path $testRoot "peer-repo"
    $planningRemote = Join-Path $testRoot "planning-remote.git"
    $planningRepo = Join-Path $testRoot "planning-repo"
    & git init --bare $remote | Out-Null
    & git init $repo | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("config", "user.name", "Automation Test") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("config", "user.email", "automation@example.invalid") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("config", "core.autocrlf", "false") | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.Directory]::CreateDirectory((Join-Path $repo "src")) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repo "src\seed.txt"), "seed`n", $encoding)
    Invoke-TestGit -Path $repo -Arguments @("add", "src/seed.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "seed") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("branch", "-M", "main") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("remote", "add", "origin", $remote) | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("push", "-u", "origin", "main") | Out-Null

    & git init --bare $planningRemote | Out-Null
    & git init $planningRepo | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("config", "user.name", "Automation Planning Test") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("config", "user.email", "planning@example.invalid") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("config", "core.autocrlf", "false") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $planningRepo "planning-seed.txt"), "planning seed`n", $encoding)
    Invoke-TestGit -Path $planningRepo -Arguments @("add", "planning-seed.txt") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "planning seed") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("branch", "-M", "main") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("remote", "add", "origin", $planningRemote) | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("push", "-u", "origin", "main") | Out-Null

    $workspace = New-TestWorkspace -Root (Join-Path $planningRepo "project") -ProjectId "automation-test" -UnitId "unit-auto-001"
    $nextUnit = New-TestUnit -ProjectId "automation-test" -UnitId "unit-auto-002"
    $nextUnit.prerequisites = @("unit-auto-001")
    Write-TestJson -Path (Join-Path $workspace "iteration-units\unit-auto-002.json") -Value $nextUnit
    $repoMapPath = Join-Path $testRoot "repo-map.json"
    Write-TestJson -Path $repoMapPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.repository_map.v1"; repositories = @(
        [ordered]@{ repo_id = "project-shell"; path = $repo; role = "source" },
        [ordered]@{ repo_id = "workflow-planning"; path = $planningRepo; role = "planning" }
    ) })
    $receiptRoot = Join-Path $workspace "receipts"
    $fixed = "2026-01-02T03:04:05Z"

    # Exercise the one behavior-neutral bridge from an already published
    # embedded workspace into a distinct local-only planning authority.
    $adoptionRemote = Join-Path $testRoot "adoption-source-remote.git"
    $adoptionSource = Join-Path $testRoot "adoption-source"
    $adoptionPlanning = Join-Path $testRoot "adoption-planning"
    & git init --bare $adoptionRemote | Out-Null
    & git init $adoptionSource | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("config", "user.name", "Automation Adoption Source") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("config", "user.email", "adoption-source@example.invalid") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("config", "core.autocrlf", "false") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $adoptionSource "README.md"), "stale source checkpoint`n", $encoding)
    Invoke-TestGit -Path $adoptionSource -Arguments @("add", "README.md") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("commit", "-m", "stale source checkpoint") | Out-Null
    $adoptionStaleRevision = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "HEAD"))[0])
    [System.IO.File]::WriteAllText((Join-Path $adoptionSource "README.md"), "pre-merge source checkpoint`n", $encoding)
    Invoke-TestGit -Path $adoptionSource -Arguments @("add", "README.md") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("commit", "-m", "pre-merge source checkpoint") | Out-Null
    $adoptionPreMergeRevision = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "HEAD"))[0])

    $adoptionSourceWorkspace = New-TestWorkspace -Root $adoptionSource -ProjectId "adoption-e2e" -UnitId "unit-adoption-001"
    $adoptionUnitPath = Join-Path $adoptionSourceWorkspace "iteration-units\unit-adoption-001.json"
    $adoptionUnit = Get-Content -LiteralPath $adoptionUnitPath -Raw | ConvertFrom-Json
    $adoptionUnit.status = "accepted"
    Write-TestJson -Path $adoptionUnitPath -Value $adoptionUnit
    $adoptionDirtyFingerprint = "c" * 64
    $adoptionStatePath = Join-Path $adoptionSourceWorkspace "workspace.state.json"
    $adoptionBeforeState = Get-Content -LiteralPath $adoptionStatePath -Raw | ConvertFrom-Json
    $adoptionBeforeState.current_unit = $null
    $adoptionBeforeState.next_ready_unit = $null
    $adoptionBeforeState.last_event_id = $null
    $adoptionBeforeState.pending_push_bundle = $null
    $adoptionBeforeState.dirty_repositories = @("other-repo", "project-shell")
    $adoptionBeforeState.repository_heads = @(
        [pscustomobject][ordered]@{
            repo_id = "other-repo"; head = ("9" * 40); branch = "main"; dirty_fingerprint = ("8" * 64)
        },
        [pscustomobject][ordered]@{
            repo_id = "project-shell"; head = $adoptionStaleRevision
            branch = "codex/stale-work"; dirty_fingerprint = $adoptionDirtyFingerprint
        }
    )
    $adoptionBeforeState.blockers = @([pscustomobject][ordered]@{
        blocker_id = "preserved-unrelated-blocker"
        condition = "Unrelated evidence remains immutable."
        resume_when = "A separate corrective unit is accepted."
    })
    Write-TestJson -Path $adoptionStatePath -Value $adoptionBeforeState
    [System.IO.File]::WriteAllText((Join-Path $adoptionSourceWorkspace "iteration-events.jsonl"), "", $encoding)
    Invoke-TestGit -Path $adoptionSource -Arguments @("add", "morphospace") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("commit", "-m", "publish embedded planning workspace") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("branch", "-M", "main") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("remote", "add", "origin", $adoptionRemote) | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("push", "-u", "origin", "main") | Out-Null
    $adoptionPublishedRevision = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "HEAD"))[0])
    $adoptionPublishedTree = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "HEAD^{tree}"))[0])
    $adoptionEmbeddedTree = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "${adoptionPublishedRevision}:morphospace"))[0])

    & git init $adoptionPlanning | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("config", "user.name", "Automation Adoption Planning") | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("config", "user.email", "adoption-planning@example.invalid") | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("config", "core.autocrlf", "false") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $adoptionPlanning "README.md"), "local-only planning authority`n", $encoding)
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("add", "README.md") | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("commit", "-m", "initialize local planning authority") | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("branch", "-M", "main") | Out-Null
    $adoptionPlanningRevision = [string](@(Invoke-TestGit -Path $adoptionPlanning -Arguments @("rev-parse", "HEAD"))[0])
    $adoptionPlanningTree = [string](@(Invoke-TestGit -Path $adoptionPlanning -Arguments @("rev-parse", "HEAD^{tree}"))[0])
    $adoptionWorkspace = Join-Path $adoptionPlanning "projects\adoption-e2e\morphospace"
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $adoptionSourceWorkspace -File -Recurse)) {
        $relative = $sourceFile.FullName.Substring($adoptionSourceWorkspace.Length + 1)
        $destination = Join-Path $adoptionWorkspace $relative
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [System.IO.File]::Copy($sourceFile.FullName, $destination, $true)
    }
    $adoptionReceiptRoot = Join-Path $adoptionWorkspace "receipts"
    [System.IO.Directory]::CreateDirectory($adoptionReceiptRoot) | Out-Null
    $adoptionInventory = @(Get-GitWorkspaceInventory $adoptionSource $adoptionPublishedRevision "morphospace" | ForEach-Object {
        [ordered]@{
            path = [string]$_.path; git_mode = [string]$_.git_mode
            size = [int64]$_.size; sha256 = [string]$_.sha256
        }
    })
    $adoptionProjectionPath = Join-Path $adoptionReceiptRoot "adoption-projection-v2.json"
    $adoptionProjection = [ordered]@{
        schema = "rusty.morphospace.workflow.planning_workspace_projection.v2"
        projection_id = "adoption-projection-v2"; project_id = "adoption-e2e"; unit_id = "unit-adoption-001"
        recorded_at = $fixed; status = "exact-projection-verified"
        chronology = [ordered]@{
            classification = "published-embedded-workspace-authority-adoption"
            source_publication_preceded_projection = $true; prepared_plan_present = $false
            executed_push_receipt_present = $false
            does_not_claim = @("prospective preparation", "planning-last publication", "source acceptance", "Git execution")
        }
        source = [ordered]@{
            repo_id = "project-shell"; branch = "main"; remote = "origin"
            remote_ref = "refs/heads/main"; upstream = "origin/main"
            old_revision = $adoptionPreMergeRevision; published_revision = $adoptionPublishedRevision
            observed_remote_revision = $adoptionPublishedRevision
            embedded_workspace_path = "morphospace"; embedded_workspace_tree = $adoptionEmbeddedTree
            fast_forward_verified = $true; remote_match = $true; force_push_used = $false
        }
        planning = [ordered]@{
            repo_id = "workflow-planning"; workspace_path = "projects/adoption-e2e/morphospace"
            projection_record_path = "receipts/adoption-projection-v2.json"
            distinct_from_source = $true; base_revision = $adoptionPlanningRevision
        }
        inventory = $adoptionInventory
        projected_state = [ordered]@{
            current_unit = $null; next_ready_unit = $null; pending_push_bundle = $null
            dirty_repository_ids = @("other-repo", "project-shell")
            source_repository = [ordered]@{
                repo_id = "project-shell"; head = $adoptionStaleRevision
                branch = "codex/stale-work"; dirty_fingerprint = $adoptionDirtyFingerprint
            }
        }
        authority = [ordered]@{
            source_workspace = "immutable-historical-snapshot"
            external_workspace = "sole-mutable-workflow-authority"
            source_workflow_mutation_performed = $false; git_mutation_performed = $false
            next_transition = "AdoptPublishedPlanningAuthority"
        }
        failure = $null
    }
    Write-TestJson -Path $adoptionProjectionPath -Value $adoptionProjection
    $adoptionBeforePath = Join-Path $adoptionReceiptRoot "adoption-state-before.json"
    [System.IO.File]::Copy((Join-Path $adoptionWorkspace "workspace.state.json"), $adoptionBeforePath, $true)
    $adoptionExpectedEventId = "unit-adoption-001-planning-authority-adopted-0001"
    $adoptionAfterState = $adoptionBeforeState | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $adoptionAfterState.dirty_repositories = @("other-repo")
    $adoptionAfterState.last_event_id = $adoptionExpectedEventId
    $adoptionAfterSource = @($adoptionAfterState.repository_heads | Where-Object { [string]$_.repo_id -ceq "project-shell" })[0]
    $adoptionAfterSource.head = $adoptionPublishedRevision
    $adoptionAfterSource.branch = "main"
    $adoptionAfterSource.dirty_fingerprint = $null
    $adoptionAfterPath = Join-Path $adoptionReceiptRoot "adoption-state-after.json"
    Write-TestJson -Path $adoptionAfterPath -Value $adoptionAfterState
    $adoptionValidationPath = Join-Path $adoptionReceiptRoot "adoption-validation.json"
    $adoptionObserverPath = Join-Path $adoptionReceiptRoot "adoption-observer.json"
    Write-TestJson -Path $adoptionValidationPath -Value ([ordered]@{
        schema = "test.validation.v1"; status = "pass"; revision = $adoptionPublishedRevision
    })
    Write-TestJson -Path $adoptionObserverPath -Value ([ordered]@{
        schema = "test.observer.v1"; observed_revision = $adoptionPublishedRevision
    })
    $adoptionBeforeBinding = [ordered]@{
        path = "receipts/adoption-state-before.json"
        sha256 = (Get-FileHash -LiteralPath $adoptionBeforePath -Algorithm SHA256).Hash.ToLowerInvariant()
        current_unit = $null; next_ready_unit = $null; pending_push_bundle = $null
        dirty_repository_ids = @("other-repo", "project-shell")
        source_repository = $adoptionProjection.projected_state.source_repository
    }
    $adoptionAfterBinding = [ordered]@{
        path = "receipts/adoption-state-after.json"
        sha256 = (Get-FileHash -LiteralPath $adoptionAfterPath -Algorithm SHA256).Hash.ToLowerInvariant()
        current_unit = $null; next_ready_unit = $null; pending_push_bundle = $null
        dirty_repository_ids = @("other-repo")
        source_repository = [ordered]@{
            repo_id = "project-shell"; head = $adoptionPublishedRevision
            branch = "main"; dirty_fingerprint = $null
        }
    }
    $adoptionDocument = [ordered]@{
        schema = "rusty.morphospace.workflow.published_planning_authority_adoption.v1"
        adoption_id = "adoption-e2e-published-planning-authority"
        project_id = "adoption-e2e"; recorded_at = $fixed
        status = "published-planning-authority-adopted"
        planning_workspace_projection = [ordered]@{
            path = "receipts/adoption-projection-v2.json"; projection_id = "adoption-projection-v2"
            sha256 = (Get-FileHash -LiteralPath $adoptionProjectionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        workspace_state_before = $adoptionBeforeBinding
        workspace_state_after = $adoptionAfterBinding
        source_publication = [ordered]@{
            repo_id = "project-shell"; branch = "main"; remote = "origin"
            remote_ref = "refs/heads/main"; upstream = "origin/main"
            pre_merge_revision = $adoptionPreMergeRevision; published_revision = $adoptionPublishedRevision
            readback_revision = $adoptionPublishedRevision; published_tree = $adoptionPublishedTree
            worktree_clean = $true; synchronized = $true; fast_forward_verified = $true
            remote_match = $true; force_push_used = $false; history_rewrite_used = $false
        }
        planning_repository = [ordered]@{
            repo_id = "workflow-planning"; branch = "main"
            head_revision = $adoptionPlanningRevision; head_tree = $adoptionPlanningTree
            workspace_path = "projects/adoption-e2e/morphospace"; distinct_from_source = $true
            remote_configured = $false; unrelated_worktree_clean = $true
        }
        validation = @([ordered]@{
            gate_id = "published-source-readback"; status = "pass"
            evidence = [ordered]@{
                path = "receipts/adoption-validation.json"
                sha256 = (Get-FileHash -LiteralPath $adoptionValidationPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        observers = @([ordered]@{
            observer_id = "external-coordinator"; recorded_at = $fixed
            evidence = [ordered]@{
                path = "receipts/adoption-observer.json"
                sha256 = (Get-FileHash -LiteralPath $adoptionObserverPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        state_delta = [ordered]@{
            cleared_dirty_repository_id = "project-shell"
            dirty_repository_ids_before = @("other-repo", "project-shell")
            dirty_repository_ids_after = @("other-repo")
            repository_before = $adoptionBeforeBinding.source_repository
            repository_after = $adoptionAfterBinding.source_repository
            last_event_id_before = $null; last_event_id_after = $adoptionExpectedEventId
            preserved_fields = @(
                "blockers", "capability_registry", "current_unit", "last_accepted_receipt",
                "module_registry", "next_ready_unit", "pending_push_bundle", "plan_revision",
                "project_id", "repository_checkpoints", "unrelated_repository_heads",
                "validation_checkpoint"
            )
        }
        nonclaims = [ordered]@{
            external_planning_authority_existed_at_publication = $false
            prepared_plan_or_executed_push_reconstructed = $false
            source_acceptance_created = $false; git_or_remote_mutation_performed = $false
            force_push_or_history_rewrite_used = $false
            unrelated_dirty_repositories_cleared = $false
        }
        failure = $null
    }
    $adoptionDocumentPath = Join-Path $adoptionReceiptRoot "adoption.json"
    Write-TestJson -Path $adoptionDocumentPath -Value $adoptionDocument
    $adoptionRepoMapPath = Join-Path $testRoot "adoption-repo-map.json"
    Write-TestJson -Path $adoptionRepoMapPath -Value ([ordered]@{
        schema = "rusty.morphospace.workflow.repository_map.v1"
        repositories = @(
            [ordered]@{ repo_id = "project-shell"; path = $adoptionSource; role = "source" },
            [ordered]@{ repo_id = "workflow-planning"; path = $adoptionPlanning; role = "planning" }
        )
    })

    $adoptionLiveStatePath = Join-Path $adoptionWorkspace "workspace.state.json"
    $adoptionLiveUnitPath = Join-Path $adoptionWorkspace "iteration-units\unit-adoption-001.json"
    $adoptionEventsPath = Join-Path $adoptionWorkspace "iteration-events.jsonl"
    $adoptionStateBeforeDryRun = Get-Content -LiteralPath $adoptionLiveStatePath -Raw
    $adoptionUnitBeforeDryRun = Get-Content -LiteralPath $adoptionLiveUnitPath -Raw
    $adoptionEventsBeforeDryRun = Get-Content -LiteralPath $adoptionEventsPath -Raw
    $adoptionDryRun = Invoke-MorphospaceWorkUnitAutomation `
        -Action AdoptPublishedPlanningAuthority `
        -WorkspaceRoot $adoptionWorkspace `
        -UnitId "unit-adoption-001" `
        -RepoMapPath $adoptionRepoMapPath `
        -PublishedPlanningAuthorityAdoption "receipts/adoption.json" `
        -Timestamp $fixed
    $adoptionExpectedHash = (Get-FileHash -LiteralPath $adoptionDocumentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Automation (
        $adoptionDryRun.transition -eq "published-planning-authority-adopted" -and
        -not $adoptionDryRun.executed -and $null -eq $adoptionDryRun.event_id -and
        $adoptionDryRun.status_before -eq "accepted" -and $adoptionDryRun.status_after -eq "accepted" -and
        [string]$adoptionDryRun.published_planning_authority_adoption.adoption_id -eq "adoption-e2e-published-planning-authority" -and
        [string]$adoptionDryRun.published_planning_authority_adoption.path -eq "receipts/adoption.json" -and
        [string]$adoptionDryRun.published_planning_authority_adoption.sha256 -eq $adoptionExpectedHash
    ) "planning-authority adoption dry run did not return the exact binding"
    Assert-Automation (
        $adoptionStateBeforeDryRun -ceq (Get-Content -LiteralPath $adoptionLiveStatePath -Raw) -and
        $adoptionUnitBeforeDryRun -ceq (Get-Content -LiteralPath $adoptionLiveUnitPath -Raw) -and
        $adoptionEventsBeforeDryRun -ceq (Get-Content -LiteralPath $adoptionEventsPath -Raw)
    ) "planning-authority adoption dry run mutated workspace projections"

    $adoptionAutomationReceiptPath = Join-Path $adoptionReceiptRoot "adoption-automation-receipt.json"
    $adoptionExecuted = Invoke-MorphospaceWorkUnitAutomation `
        -Action AdoptPublishedPlanningAuthority `
        -WorkspaceRoot $adoptionWorkspace `
        -UnitId "unit-adoption-001" `
        -RepoMapPath $adoptionRepoMapPath `
        -PublishedPlanningAuthorityAdoption "receipts/adoption.json" `
        -Timestamp $fixed `
        -OutPath $adoptionAutomationReceiptPath `
        -Execute
    Assert-Automation (
        $adoptionExecuted.transition -eq "published-planning-authority-adopted" -and
        $adoptionExecuted.executed -and $adoptionExecuted.event_id -eq $adoptionExpectedEventId -and
        $adoptionExecuted.status_before -eq "accepted" -and $adoptionExecuted.status_after -eq "accepted" -and
        [string]$adoptionExecuted.published_planning_authority_adoption.sha256 -eq $adoptionExpectedHash -and
        (Test-Path -LiteralPath $adoptionAutomationReceiptPath -PathType Leaf)
    ) "planning-authority adoption execution did not return the exact transition"
    $adoptionActualState = Get-Content -LiteralPath $adoptionLiveStatePath -Raw | ConvertFrom-Json
    $adoptionExpectedState = Get-Content -LiteralPath $adoptionAfterPath -Raw | ConvertFrom-Json
    Assert-Automation (
        (ConvertTo-MorphospaceCanonicalJson $adoptionActualState) -ceq
            (ConvertTo-MorphospaceCanonicalJson $adoptionExpectedState)
    ) "planning-authority adoption did not write the exact bound after state"
    Assert-Automation (
        $adoptionUnitBeforeDryRun -ceq (Get-Content -LiteralPath $adoptionLiveUnitPath -Raw)
    ) "planning-authority adoption rewrote the accepted unit"
    $adoptionEvents = @(Get-Content -LiteralPath $adoptionEventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Automation (
        $adoptionEvents.Count -eq 1 -and
        [string]$adoptionEvents[0].event_id -eq $adoptionExpectedEventId -and
        [string]$adoptionEvents[0].event_type -eq "state-transition" -and
        @($adoptionEvents[0].receipts).Count -eq 1 -and
        [string]$adoptionEvents[0].receipts[0] -eq "receipts/adoption.json"
    ) "planning-authority adoption did not append exactly one bound receipt event"
    $adoptionTransactionId = "$adoptionExpectedEventId-transition"
    $adoptionTransactionRoot = Join-Path $adoptionReceiptRoot "transactions"
    $adoptionIntentPath = Join-Path $adoptionTransactionRoot "$adoptionTransactionId.intent.json"
    $adoptionCompletionPath = Join-Path $adoptionTransactionRoot "$adoptionTransactionId.completion.json"
    $adoptionIntent = Get-Content -LiteralPath $adoptionIntentPath -Raw | ConvertFrom-Json
    $adoptionCompletion = Get-Content -LiteralPath $adoptionCompletionPath -Raw | ConvertFrom-Json
    Assert-Automation (
        @(Get-ChildItem -LiteralPath $adoptionTransactionRoot -File).Count -eq 2 -and
        [string]$adoptionIntent.schema -eq "rusty.morphospace.workflow.transition_ledger_intent.v1" -and
        [string]$adoptionIntent.transaction_id -eq $adoptionTransactionId -and
        [string]$adoptionIntent.status -eq "prepared" -and
        [string]$adoptionIntent.event.event_id -eq $adoptionExpectedEventId -and
        [string]$adoptionCompletion.schema -eq "rusty.morphospace.workflow.transition_ledger_completion.v1" -and
        [string]$adoptionCompletion.transaction_id -eq $adoptionTransactionId -and
        [string]$adoptionCompletion.status -eq "committed" -and
        [string]$adoptionCompletion.event_id -eq $adoptionExpectedEventId
    ) "planning-authority adoption transaction intent/completion artifacts are incomplete"
    $adoptionReplayRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation `
            -Action AdoptPublishedPlanningAuthority `
            -WorkspaceRoot $adoptionWorkspace `
            -UnitId "unit-adoption-001" `
            -RepoMapPath $adoptionRepoMapPath `
            -PublishedPlanningAuthorityAdoption "receipts/adoption.json" `
            -Timestamp $fixed `
            -Execute | Out-Null
    } catch {
        $adoptionReplayRejected = $true
    }
    Assert-Automation (
        $adoptionReplayRejected -and
        @(Get-Content -LiteralPath $adoptionEventsPath | Where-Object { $_ }).Count -eq 1 -and
        @(Get-ChildItem -LiteralPath $adoptionTransactionRoot -File).Count -eq 2
    ) "planning-authority adoption replay was not rejected without a second event or transaction"

    $readyWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "ready-project") -ProjectId "ready-test" -UnitId "unit-ready-001"
    $readyUnitPath = Join-Path $readyWorkspace "iteration-units\unit-ready-001.json"
    $readyUnit = Get-Content -LiteralPath $readyUnitPath -Raw | ConvertFrom-Json
    $readyUnit.status = "proposed"
    Write-TestJson -Path $readyUnitPath -Value $readyUnit
    $readyStatePath = Join-Path $readyWorkspace "workspace.state.json"
    $readyState = Get-Content -LiteralPath $readyStatePath -Raw | ConvertFrom-Json
    $readyState.next_ready_unit = $null
    Write-TestJson -Path $readyStatePath -Value $readyState
    $readyResult = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $readyWorkspace -UnitId "unit-ready-001" -Timestamp $fixed -Execute
    Assert-Automation ($readyResult.transition -eq "proposed-to-ready" -and $readyResult.status_after -eq "ready") "proposal review transition"
    $readyState = Get-Content -LiteralPath $readyStatePath -Raw | ConvertFrom-Json
    Assert-Automation ([string]$readyState.next_ready_unit -eq "unit-ready-001") "proposal review did not derive next-ready state"
    $readyEventCount = @(Get-Content (Join-Path $readyWorkspace "iteration-events.jsonl")).Count
    $readyAgain = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $readyWorkspace -UnitId "unit-ready-001" -Timestamp $fixed -Execute
    Assert-Automation ($readyAgain.transition -eq "idempotent") "idempotent proposal review"
    Assert-Automation (@(Get-Content (Join-Path $readyWorkspace "iteration-events.jsonl")).Count -eq $readyEventCount) "idempotent proposal review appended an event"

    $blockedReadyWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "blocked-ready-project") -ProjectId "blocked-ready-test" -UnitId "unit-blocked-ready-001"
    $blockedReadyPath = Join-Path $blockedReadyWorkspace "iteration-units\unit-blocked-ready-001.json"
    $blockedReadyUnit = Get-Content -LiteralPath $blockedReadyPath -Raw | ConvertFrom-Json
    $blockedReadyUnit.status = "proposed"
    $blockedReadyUnit.prerequisites = @("missing-prerequisite")
    Write-TestJson -Path $blockedReadyPath -Value $blockedReadyUnit
    $blockedReadyRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $blockedReadyWorkspace -UnitId "unit-blocked-ready-001" -Timestamp $fixed -Execute | Out-Null
    } catch { $blockedReadyRejected = $true }
    Assert-Automation $blockedReadyRejected "proposal review accepted an unmet prerequisite"

    $claim = Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed -OutPath (Join-Path $receiptRoot "claim.json") -Execute
    Assert-Automation ($claim.transition -eq "ready-to-active" -and $claim.status_after -eq "active") "claim transition"
    $eventCount = @(Get-Content (Join-Path $workspace "iteration-events.jsonl")).Count
    $claimAgain = Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute
    Assert-Automation ($claimAgain.transition -eq "idempotent") "idempotent claim"
    Assert-Automation (@(Get-Content (Join-Path $workspace "iteration-events.jsonl")).Count -eq $eventCount) "idempotent claim appended an event"

    $preflightWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "preflight-project") -ProjectId "preflight-test" -UnitId "unit-preflight-001"
    $preflightUnitPath = Join-Path $preflightWorkspace "iteration-units\unit-preflight-001.json"
    $preflightUnit = Get-Content -LiteralPath $preflightUnitPath -Raw | ConvertFrom-Json
    $preflightUnit | Add-Member -NotePropertyName tags -NotePropertyValue @("receipt-security")
    Write-TestJson -Path $preflightUnitPath -Value $preflightUnit
    Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $preflightWorkspace -UnitId "unit-preflight-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $preflightWorkspace -UnitId "unit-preflight-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    $preflightStatePath = Join-Path $preflightWorkspace "workspace.state.json"
    $preflightEventsPath = Join-Path $preflightWorkspace "iteration-events.jsonl"
    $preflightBefore = @(@($preflightUnitPath, $preflightStatePath, $preflightEventsPath) | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    $automationModule = Get-Module WorkUnitAutomation
    $preflightResult = & $automationModule {
        param($Workspace, $UnitId, $MapPath, $Timestamp)
        function Invoke-MorphospaceAuthorityRunnerForRecord {
            param($WorkspaceRoot, $UnitId, $RepositoryMap, $AuthorityRunnerPath, $AuthorityRunnerArguments, $RunnerAction, $ValidationReceipt)
            return "stub-preflight-nonce"
        }
        Invoke-MorphospaceWorkUnitAutomation -Action PreflightValidation -WorkspaceRoot $Workspace -UnitId $UnitId -RepoMapPath $MapPath -AuthorityRunnerPath "stub-authority-runner.ps1" -Timestamp $Timestamp -Execute
    } $preflightWorkspace "unit-preflight-001" $repoMapPath $fixed
    $preflightAfter = @(@($preflightUnitPath, $preflightStatePath, $preflightEventsPath) | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    Assert-Automation ($preflightResult.transition -eq "authority-preflight-ready") "receipt-security preflight did not complete"
    Assert-Automation (($preflightBefore -join "`n") -ceq ($preflightAfter -join "`n")) "preflight rewrote workflow state without an event"

    $statusBefore = (Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $repo "local-only.txt"), "preserve me`n", $encoding)
    $dirtyBefore = (Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n"
    $inspectDirty = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    $dirtyAfter = (Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n"
    Assert-Automation ($inspectDirty.preservation.repository_states[0].dirty -eq $true) "dirty repository was not reported"
    Assert-Automation ($dirtyBefore -eq $dirtyAfter -and (Test-Path (Join-Path $repo "local-only.txt"))) "dirty repository was rewritten"
    Remove-Item -LiteralPath (Join-Path $repo "local-only.txt")
    Assert-Automation ($statusBefore -eq ((Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n")) "test cleanup failed"

    $dirtyClaimWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "dirty-claim-project") -ProjectId "dirty-claim-test" -UnitId "unit-dirty-001"
    [System.IO.File]::WriteAllText((Join-Path $repo "src\preexisting.txt"), "preexisting`n", $encoding)
    $dirtyClaimRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $dirtyClaimWorkspace -UnitId "unit-dirty-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    } catch {
        $dirtyClaimRejected = $_.Exception.Message -like "Claim refused pre-existing dirty-path overlap*"
    }
    Assert-Automation $dirtyClaimRejected "claim did not reject pre-existing dirty overlap inside allowed paths"
    $adoptionPath = New-TestInflightAdoptionReceipt -Workspace $dirtyClaimWorkspace -UnitId "unit-dirty-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    $adoptedClaim = Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $dirtyClaimWorkspace -UnitId "unit-dirty-001" -RepoMapPath $repoMapPath -AdoptionReceipt "receipts/unit-dirty-001-inflight-adoption.json" -Timestamp $fixed -Execute
    Assert-Automation ($adoptedClaim.transition -eq "ready-to-active" -and $adoptedClaim.adoption_receipt -eq "receipts/unit-dirty-001-inflight-adoption.json") "hashed in-flight adoption did not claim bounded pre-protocol work"
    Assert-Automation (Test-Path -LiteralPath $adoptionPath -PathType Leaf) "in-flight adoption receipt was not preserved"
    Remove-Item -LiteralPath (Join-Path $repo "src\preexisting.txt")

    $tamperedAdoptionWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "tampered-adoption-project") -ProjectId "tampered-adoption-test" -UnitId "unit-adopt-001"
    [System.IO.File]::WriteAllText((Join-Path $repo "src\preexisting.txt"), "first version`n", $encoding)
    New-TestInflightAdoptionReceipt -Workspace $tamperedAdoptionWorkspace -UnitId "unit-adopt-001" -RepoMapPath $repoMapPath -Timestamp $fixed | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repo "src\preexisting.txt"), "changed after receipt`n", $encoding)
    $tamperedAdoptionRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $tamperedAdoptionWorkspace -UnitId "unit-adopt-001" -RepoMapPath $repoMapPath -AdoptionReceipt "receipts/unit-adopt-001-inflight-adoption.json" -Timestamp $fixed -Execute | Out-Null
    } catch {
        $tamperedAdoptionRejected = $_.Exception.Message -like "In-flight adoption receipt hash mismatch*"
    }
    Assert-Automation $tamperedAdoptionRejected "claim accepted work that changed after its in-flight adoption receipt"
    Remove-Item -LiteralPath (Join-Path $repo "src\preexisting.txt")

    $headBeforeDetach = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    Invoke-TestGit -Path $repo -Arguments @("checkout", "--detach") | Out-Null
    $inspectDetached = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    Assert-Automation ($inspectDetached.preservation.repository_states[0].relation -eq "detached") "detached HEAD was not reported"
    Assert-Automation ((@(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]) -eq $headBeforeDetach) "detached inspection changed HEAD"
    Invoke-TestGit -Path $repo -Arguments @("switch", "main") | Out-Null

    $begin = Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed -OutPath (Join-Path $receiptRoot "begin-validation.json") -Execute
    Assert-Automation ($begin.status_after -eq "validating" -and $begin.validation_matrix.Count -eq 1) "validation plan"
    $missingReceiptRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -ValidationTier deep -ValidationResult pass -ValidationReceipt "receipts/does-not-exist.json" -Timestamp $fixed | Out-Null
    } catch {
        $missingReceiptRejected = $_.Exception.Message -like "Validation receipt does not exist:*"
    }
    Assert-Automation $missingReceiptRejected "nonexistent validation receipt was accepted"
    $validationHead = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $validationBranch = @(Invoke-TestGit -Path $repo -Arguments @("branch", "--show-current"))[0]
    $validReceiptPath = New-TestValidationReceipt -Workspace $workspace -ProjectId "automation-test" -UnitId "unit-auto-001" -Tier deep -Result pass -RepositoryRevisions @([ordered]@{
        repo_id = "project-shell"; base_revision = $validationHead; head_revision = $validationHead; branch = $validationBranch
    })
    $record = Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -ValidationTier deep -ValidationResult pass -ValidationReceipt "receipts/unit-auto-001-pass-validation.json" -Timestamp $fixed -OutPath (Join-Path $receiptRoot "validation.json") -Execute
    Assert-Automation ($record.transition -eq "validation-pass") "passing validation record"
    $validationEvidencePath = Join-Path $receiptRoot "self-test-evidence.txt"
    [System.IO.File]::WriteAllText($validationEvidencePath, "tampered after validation`n", $encoding)
    $tamperedAcceptanceRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed | Out-Null
    } catch {
        $tamperedAcceptanceRejected = $_.Exception.Message -like "Validation artifact hash mismatch*"
    }
    Assert-Automation $tamperedAcceptanceRejected "acceptance did not revalidate a tampered artifact"
    [System.IO.File]::WriteAllText($validationEvidencePath, "validation evidence for unit-auto-001 pass`n", $encoding)
    $accepted = Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed -OutPath (Join-Path $receiptRoot "accept.json") -Execute
    Assert-Automation ($accepted.status_after -eq "accepted" -and $null -eq $accepted.current_unit_after) "accept transition"
    $acceptedState = Get-Content -LiteralPath (Join-Path $workspace "workspace.state.json") -Raw | ConvertFrom-Json
    Assert-Automation ([string]$acceptedState.next_ready_unit -eq "unit-auto-002") "deterministic next-ready selection"
    Assert-Automation ([string]$acceptedState.last_accepted_receipt -eq "receipts/unit-auto-001-pass-validation.json") "v2 last accepted receipt projection"
    Assert-Automation (@($acceptedState.repository_heads).Count -eq 1) "v2 repository-head projection"

    $unplannedOld = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    [System.IO.File]::WriteAllText((Join-Path $repo "src\unplanned.txt"), "published before PreparePush`n", $encoding)
    Invoke-TestGit -Path $repo -Arguments @("add", "src/unplanned.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "unplanned publication fixture") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("push", "origin", "main") | Out-Null
    $unplannedNew = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $staleStatePath = Join-Path $workspace "workspace.state.json"
    $staleState = Get-Content -LiteralPath $staleStatePath -Raw | ConvertFrom-Json
    $staleState.dirty_repositories = @("project-shell")
    $staleState.pending_push_bundle = [pscustomobject][ordered]@{
        bundle_id = "older-unit-push-bundle"; unit_ids = @("unit-auto-001"); repo_ids = @("project-shell"); ready = $true
    }
    $staleState.repository_heads = @([pscustomobject][ordered]@{
        repo_id = "project-shell"; head = $unplannedOld; branch = "main"; dirty_fingerprint = ('0' * 64)
    })
    Write-TestJson -Path $staleStatePath -Value $staleState
    $closurePath = New-TestUnplannedPublicationClosure `
        -Workspace $workspace `
        -ProjectId "automation-test" `
        -UnitId "unit-auto-001" `
        -RepoId "project-shell" `
        -Branch "main" `
        -Upstream "origin/main" `
        -OldRevision $unplannedOld `
        -NewRevision $unplannedNew `
        -PendingBundle "older-unit-push-bundle" `
        -ValidationReceipt "receipts/unit-auto-001-pass-validation.json"
    $reconciledPublication = Invoke-MorphospaceWorkUnitAutomation `
        -Action ReconcilePublication `
        -WorkspaceRoot $workspace `
        -UnitId "unit-auto-001" `
        -RepoMapPath $repoMapPath `
        -PublicationClosure "receipts/unit-auto-001-unplanned-publication-closure.json" `
        -Timestamp $fixed `
        -Execute
    Assert-Automation ($reconciledPublication.transition -eq "unplanned-publication-reconciled") "unplanned publication recovery transition"
    Assert-Automation ([string]$reconciledPublication.publication_closure.closure_id -eq "unit-auto-001-unplanned-publication-closure") "unplanned publication closure binding"
    $reconciledState = Get-Content -LiteralPath $staleStatePath -Raw | ConvertFrom-Json
    Assert-Automation ($null -eq $reconciledState.pending_push_bundle -and @($reconciledState.dirty_repositories).Count -eq 0) "unplanned publication recovery did not clear stale state"
    Assert-Automation ([string]$reconciledState.repository_heads[0].head -eq $unplannedNew) "unplanned publication recovery did not project the observed head"
    Assert-Automation ((@(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]) -eq $unplannedNew) "unplanned publication recovery mutated Git"
    Assert-Automation (Test-Path -LiteralPath $closurePath -PathType Leaf) "unplanned publication closure was not preserved"

    $scopeWorkspace = New-TestWorkspace -Root (Join-Path $repo "morphospace-scope-test") -ProjectId "scope-test" -UnitId "unit-scope-001"
    $scopeUnitPath = Join-Path $scopeWorkspace "iteration-units\unit-scope-001.json"
    $scopeUnit = Get-Content -LiteralPath $scopeUnitPath -Raw | ConvertFrom-Json
    $scopeUnit.allowed_repositories[0].allowed_paths = @($scopeUnit.allowed_repositories[0].allowed_paths) + ".github/workflows/ci.yml"
    Write-TestJson -Path $scopeUnitPath -Value $scopeUnit
    [System.IO.File]::WriteAllText((Join-Path $repo "outside.txt"), "outside unit scope`n", $encoding)
    Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repo ".github\workflows")) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repo ".github\workflows\ci.yml"), "name: hidden-path-regression`n", $encoding)
    $scopeHead = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $scopeBranch = @(Invoke-TestGit -Path $repo -Arguments @("branch", "--show-current"))[0]
    New-TestValidationReceipt -Workspace $scopeWorkspace -ProjectId "scope-test" -UnitId "unit-scope-001" -Tier standard -Result pass -RepositoryRevisions @([ordered]@{
        repo_id = "project-shell"; base_revision = $scopeHead; head_revision = $scopeHead; branch = $scopeBranch
    }) -ChangedPaths @([ordered]@{ repo_id = "project-shell"; path = ".github/workflows/ci.yml" }) | Out-Null
    $scopeRecord = Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -ValidationTier standard -ValidationResult pass -ValidationReceipt "receipts/unit-scope-001-pass-validation.json" -Timestamp $fixed
    $scopeTransactions = @(Get-ChildItem -LiteralPath (Join-Path $scopeWorkspace "receipts\transactions") -File -ErrorAction SilentlyContinue)
    Assert-Automation ($scopeRecord.transition -eq "validation-pass" -and (Test-Path -LiteralPath (Join-Path $repo "outside.txt")) -and $scopeTransactions.Count -gt 0) "hidden in-scope path, out-of-scope user work, or protocol-owned transaction artifacts blocked validation or were modified"
    New-TestValidationReceipt -Workspace $scopeWorkspace -ProjectId "scope-test" -UnitId "unit-scope-001" -Tier standard -Result pass -RepositoryRevisions @([ordered]@{
        repo_id = "project-shell"; base_revision = $scopeHead; head_revision = $scopeHead; branch = $scopeBranch
    }) -ChangedPaths @(
        [ordered]@{ repo_id = "project-shell"; path = ".github/workflows/ci.yml" },
        [ordered]@{ repo_id = "project-shell"; path = "outside.txt" }
    ) | Out-Null
    $outsideScopeRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -ValidationTier standard -ValidationResult pass -ValidationReceipt "receipts/unit-scope-001-pass-validation.json" -Timestamp $fixed | Out-Null
    } catch {
        $outsideScopeRejected = $_.Exception.Message -like "Validation changed path is outside unit scope*"
    }
    Assert-Automation $outsideScopeRejected "validation did not reject an out-of-scope changed path"
    Remove-Item -LiteralPath (Join-Path $repo "outside.txt")
    Remove-Item -LiteralPath (Join-Path $repo ".github") -Recurse -Force
    Remove-Item -LiteralPath $scopeWorkspace -Recurse -Force

    [System.IO.File]::WriteAllText((Join-Path $repo "src\ahead.txt"), "ahead`n", $encoding)
    Invoke-TestGit -Path $repo -Arguments @("add", "src/ahead.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "ahead") | Out-Null
    $localHead = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $remoteBefore = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "origin/main"))[0]
    $revisionsPath = Join-Path $testRoot "revisions.json"
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "planning state before prepared push") | Out-Null
    $planningHead = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "HEAD"))[0]
    Write-TestJson -Path $revisionsPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.revision_set.v1"; repositories = @(
        [ordered]@{ repo_id = "project-shell"; commit = $localHead },
        [ordered]@{ repo_id = "workflow-planning"; commit = $planningHead }
    ) })
    $pushPlanPath = Join-Path $receiptRoot "push-plan.json"
    $prepared = Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -RevisionsPath $revisionsPath -Timestamp $fixed -OutPath $pushPlanPath -Execute
    Assert-Automation ($prepared.push_plan.schema -eq "rusty.morphospace.workflow.push_bundle_plan.v1" -and $prepared.push_plan.execution -eq "not-performed" -and -not $prepared.push_plan.force_push_allowed) "push plan execution boundary"
    Assert-Automation ($prepared.push_plan.repositories[-1].role -eq "planning" -and $prepared.push_plan.repositories[-1].repo_id -eq "workflow-planning") "push plan did not place the distinct planning repository last"
    Assert-Automation (-not ($prepared.push_plan.PSObject.Properties.Name -contains "remote_readback_complete")) "automation fabricated executed-push evidence"
    Assert-Automation ((@(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "origin/main"))[0]) -eq $remoteBefore) "push preparation changed the remote"

    # A legacy pending bundle stores its plan in the executed PreparePush automation
    # receipt and its event in the immutable transition-ledger pair.
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "retain prepared push evidence") | Out-Null
    $preparedEventId = [string]$prepared.event_id
    $preparedIntentRelative = "receipts/transactions/$preparedEventId-transition.intent.json"
    $preparedCompletionRelative = "receipts/transactions/$preparedEventId-transition.completion.json"
    $preparedIntentPath = Join-Path $workspace ($preparedIntentRelative -replace "/", "\")
    $preparedCompletionPath = Join-Path $workspace ($preparedCompletionRelative -replace "/", "\")
    $realPreparedIntent = Get-Content -Raw $preparedIntentPath | ConvertFrom-Json
    $realPreparedCompletion = Get-Content -Raw $preparedCompletionPath | ConvertFrom-Json
    $realPreparedLedgerEvents = @(Get-Content (Join-Path $workspace "iteration-events.jsonl") | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $realPreparedEvent = @($realPreparedLedgerEvents | Where-Object { [string]$_.event_id -eq $preparedEventId })
    Assert-Automation (
        [string]$realPreparedIntent.schema -eq "rusty.morphospace.workflow.transition_ledger_intent.v1" -and
        [string]$realPreparedIntent.transaction_id -eq "$preparedEventId-transition" -and
        [string]$realPreparedIntent.event.event_type -eq "commit" -and
        [string]$realPreparedCompletion.intent.role -eq "transition-ledger-intent" -and
        [string]$realPreparedCompletion.intent.path -eq $preparedIntentRelative -and
        [string]$realPreparedCompletion.intent.schema -eq [string]$realPreparedIntent.schema -and
        [string]$realPreparedCompletion.intent.sha256 -eq (Get-FileHash $preparedIntentPath).Hash.ToLowerInvariant() -and
        $realPreparedEvent.Count -eq 1
    ) "real PreparePush/transition-ledger provenance is incompatible with prepared-publication reconstruction"
    $retirementInput = Join-Path $testRoot "prepared-push-retirement-input.json"
    $retirementOutput = Join-Path $receiptRoot "prepared-push-retirement.json"
    $retirementStatePath = Join-Path $workspace "workspace.state.json"
    $retirementState = Get-Content -Raw $retirementStatePath | ConvertFrom-Json
    $staleBlocker = [pscustomobject][ordered]@{
        blocker_id = "stale-auto-push-plan"
        condition = "The exact prepared bundle remains pending."
        resume_when = "Typed stale-bookkeeping evidence is accepted."
    }
    $unrelatedBlocker = [pscustomobject][ordered]@{
        blocker_id = "unrelated-auto-blocker"
        condition = "An unrelated condition remains unresolved."
        resume_when = "Separate unrelated evidence passes."
    }
    $retirementState.blockers = @($retirementState.blockers) + $staleBlocker + $unrelatedBlocker
    Write-TestJson -Path $retirementStatePath -Value $retirementState
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "bind exact stale prepared-push blocker") | Out-Null
    $retirementRepositories = @($prepared.push_plan.repositories | ForEach-Object {
        $path = if ([string]$_.repo_id -eq "project-shell") { $repo } else { $planningRepo }
        $head = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "HEAD"))[0]
        $upstream = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"))[0]
        $remoteRevision = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "@{upstream}"))[0]
        $counts = (@(Invoke-TestGit -Path $path -Arguments @("rev-list", "--left-right", "--count", "HEAD...@{upstream}"))[0] -split "\s+")
        [ordered]@{
            repo_id = [string]$_.repo_id; role = [string]$_.role; branch = [string]$_.branch; upstream = $upstream
            prepared_revision = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "$([string]$_.commit)^{commit}"))[0]
            local_head = $head; remote_readback_revision = $remoteRevision; worktree_clean = $true
            detached = $false; ahead = [int]$counts[0]; behind = [int]$counts[1]; diverged = $false
        }
    })
    $retirementDocument = [ordered]@{
        schema = "rusty.morphospace.workflow.prepared_push_retirement.v1"
        retirement_id = "retirement-auto-001"; project_id = "automation-test"
        bundle_id = [string]$prepared.push_plan.bundle_id; unit_ids = @("unit-auto-001"); reason = "reprepared"
        prepared_plan = [ordered]@{
            container = [ordered]@{ path = "receipts/push-plan.json"; sha256 = (Get-FileHash $pushPlanPath).Hash.ToLowerInvariant() }
            member = "push_plan"
        }
        prepared_event = [ordered]@{
            event_id = $preparedEventId
            intent = [ordered]@{ path = $preparedIntentRelative; sha256 = (Get-FileHash $preparedIntentPath).Hash.ToLowerInvariant() }
            completion = [ordered]@{ path = $preparedCompletionRelative; sha256 = (Get-FileHash $preparedCompletionPath).Hash.ToLowerInvariant() }
            member = "event"
        }
        pending_bundle = [ordered]@{
            value = $retirementState.pending_push_bundle
            sha256 = Get-MorphospaceCanonicalJsonSha256 $retirementState.pending_push_bundle
        }
        stale_blocker = [ordered]@{
            value = $staleBlocker
            sha256 = Get-MorphospaceCanonicalJsonSha256 $staleBlocker
        }
        observed_at = $fixed; repositories = $retirementRepositories
        evidence_search = [ordered]@{ workspace_relative_roots = @("receipts","iteration-events.jsonl"); recognized_binding_count = 0; complete = $true }
        claims = [ordered]@{ workflow_recognized_execution_or_publication_asserted = $false; historical_publication_impossible = $false; remote_mutation_performed = $false }
        mutation = [ordered]@{ pending_bundle_consumed = $true; blocker_id = "stale-auto-push-plan" }
    }
    Write-TestJson -Path $retirementInput -Value $retirementDocument

    $retirementDryRun = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace `
        -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | ConvertFrom-Json
    Assert-Automation ($retirementDryRun.transition -eq "prepared-push-retired" -and -not $retirementDryRun.executed) "prepared-push retirement dry run"
    Assert-Automation ($null -ne (Get-Content -Raw (Join-Path $workspace "workspace.state.json") | ConvertFrom-Json).pending_push_bundle) "prepared-push retirement dry run mutated state"

    $damagedRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $damagedRetirement.bundle_id = "wrong-bundle"
    Write-TestJson -Path $retirementInput -Value $damagedRetirement
    $wrongBundleRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $wrongBundleRejected = $_.Exception.Message -like "*bundle identity mismatch*" }
    Assert-Automation $wrongBundleRejected "prepared-push retirement accepted a mismatched bundle"

    $damagedRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $damagedRetirement.repositories = @($damagedRetirement.repositories[0])
    Write-TestJson -Path $retirementInput -Value $damagedRetirement
    $partialCoverageRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $partialCoverageRejected = $_.Exception.Message -like "*coverage is incomplete*" }
    Assert-Automation $partialCoverageRejected "prepared-push retirement accepted partial repository coverage"

    $damagedRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $damagedRetirement.repositories[0].remote_readback_revision = "0000000000000000000000000000000000000000"
    Write-TestJson -Path $retirementInput -Value $damagedRetirement
    $staleObservationRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $staleObservationRejected = $_.Exception.Message -like "*stale or mismatched*" }
    Assert-Automation $staleObservationRejected "prepared-push retirement accepted stale remote observation"

    $conflictingPath = Join-Path $receiptRoot "conflicting-executed-push.json"
    $conflictingRepoRelative = [IO.Path]::GetRelativePath($planningRepo, $conflictingPath).Replace("\","/")
    [IO.File]::AppendAllText((Join-Path $planningRepo ".git\info\exclude"), "$conflictingRepoRelative`n", $encoding)
    Write-TestJson -Path $conflictingPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.executed_push_receipt.v1"; bundle_id = [string]$prepared.push_plan.bundle_id })
    Write-TestJson -Path $retirementInput -Value $retirementDocument
    $executionEvidenceRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $executionEvidenceRejected = $_.Exception.Message -like "*execution/publication evidence*" }
    Assert-Automation $executionEvidenceRejected "prepared-push retirement ignored bound execution evidence"
    Remove-Item -LiteralPath $conflictingPath

    Invoke-TestGit -Path $repo -Arguments @("push", "origin", "main") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("fetch", "origin") | Out-Null
    $planningRemoteBefore = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "origin/main"))[0]
    Invoke-TestGit -Path $planningRepo -Arguments @("push", "origin", "main") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("fetch", "origin") | Out-Null
    $publishedPrepared = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $publishedSourceObservation = @($publishedPrepared.repositories | Where-Object { [string]$_.repo_id -eq "project-shell" })[0]
    $publishedSourceObservation.remote_readback_revision = $localHead
    $publishedSourceObservation.ahead = 0
    $publishedPlanningObservation = @($publishedPrepared.repositories | Where-Object { [string]$_.repo_id -eq "workflow-planning" })[0]
    $publishedPlanningObservation.remote_readback_revision = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "origin/main"))[0]
    $publishedPlanningObservation.ahead = 0
    Write-TestJson -Path $retirementInput -Value $publishedPrepared
    $reachablePreparedRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $reachablePreparedRejected = $_.Exception.Message -like "*requires at least one distinct prepared revision*" }
    Assert-Automation $reachablePreparedRejected "prepared-push retirement became an alternate accounting path for a remotely reachable prepared revision"

    # The real RecordValidation -> Accept -> PreparePush chain must be accepted
    # by reconstruction when observed through independent clean readback clones.
    $sourceReadback = Join-Path $testRoot "source-reconstruction-readback"
    $planningReadback = Join-Path $testRoot "planning-reconstruction-readback"
    Invoke-TestGit -Path $testRoot -Arguments @("-c", "core.autocrlf=false", "clone", "--quiet", "--branch", "main", $remote, $sourceReadback) | Out-Null
    Invoke-TestGit -Path $testRoot -Arguments @("-c", "core.autocrlf=false", "clone", "--quiet", "--branch", "main", $planningRemote, $planningReadback) | Out-Null
    $reconstructionMapPath = Join-Path $testRoot "repository-map-real-reconstruction.json"
    Write-TestJson -Path $reconstructionMapPath -Value ([ordered]@{
        schema = "rusty.morphospace.workflow.repository_map.v1"
        repositories = @(
            [ordered]@{ repo_id = "project-shell"; path = $sourceReadback; role = "source"; aliases = @() },
            [ordered]@{ repo_id = "workflow-planning"; path = $planningReadback; role = "planning"; aliases = @() }
        )
    })
    Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceProtocolCommon.psm1") -Force
    $realReconstructionState = Get-Content -Raw $retirementStatePath | ConvertFrom-Json
    $realUnitRelative = "iteration-units/unit-auto-001.json"
    $realValidationRelative = [IO.Path]::GetRelativePath($workspace, $validReceiptPath).Replace("\","/")
    $realValidationIntentRelative = "receipts/transactions/$([string]$record.event_id)-transition.intent.json"
    $realValidationCompletionRelative = "receipts/transactions/$([string]$record.event_id)-transition.completion.json"
    $realAcceptanceIntentRelative = "receipts/transactions/$([string]$accepted.event_id)-transition.intent.json"
    $realAcceptanceCompletionRelative = "receipts/transactions/$([string]$accepted.event_id)-transition.completion.json"
    $realFileBinding = {
        param([string]$Relative)
        $absolute = Join-Path $workspace ($Relative -replace "/","\")
        [ordered]@{ path = $Relative; sha256 = (Get-FileHash $absolute).Hash.ToLowerInvariant() }
    }
    $realLogicalLegs = @()
    $realPhysicalRefs = @()
    foreach($planRepository in @($prepared.push_plan.repositories)){
        $repoId = [string]$planRepository.repo_id
        $readback = if($repoId -eq "project-shell"){$sourceReadback}else{$planningReadback}
        $physicalId = "$repoId-main-readback"
        $tip = @(Invoke-TestGit -Path $readback -Arguments @("rev-parse","HEAD"))[0]
        $preparedRevision = [string]$planRepository.commit
        $historyIds = @((@(Invoke-TestGit -Path $readback -Arguments @("rev-list","--reverse","$preparedRevision..$tip")) -join "`n") -split "`n" | Where-Object { $_ })
        $history = @($historyIds | ForEach-Object {
            $revision = [string]$_
            [ordered]@{
                revision = $revision
                parents = @(((@(Invoke-TestGit -Path $readback -Arguments @("show","-s","--format=%P",$revision)) -join "") -split " ") | Where-Object { $_ })
                tree = (@(Invoke-TestGit -Path $readback -Arguments @("show","-s","--format=%T",$revision)) -join "")
                changed_paths = @(((@(Invoke-TestGit -Path $readback -Arguments @("diff-tree","--no-commit-id","--name-only","-r","--root",$revision)) -join "`n") -split "`n" | Where-Object { $_ } | Sort-Object -Unique))
            }
        })
        $realLogicalLegs += [ordered]@{ repo_id=$repoId; role=[string]$planRepository.role; physical_ref_id=$physicalId; prepared_revision=$preparedRevision }
        $realPhysicalRefs += [ordered]@{
            physical_ref_id=$physicalId; observation_repo_id=$repoId; logical_repo_ids=@($repoId)
            remote="origin"; ref="refs/heads/main"; branch="main"; upstream="origin/main"
            prepared_revision=$preparedRevision
            prepared_tree=(@(Invoke-TestGit -Path $readback -Arguments @("show","-s","--format=%T",$preparedRevision)) -join "")
            remote_tip_revision=$tip
            remote_tip_tree=(@(Invoke-TestGit -Path $readback -Arguments @("show","-s","--format=%T",$tip)) -join "")
            ancestor_or_equal=$true; history=$history
        }
    }
    $realReconstructionDocument = [ordered]@{
        schema="rusty.morphospace.workflow.prepared_publication_reconstruction.v1"
        reconstruction_id="real-automation-reconstruction";project_id="automation-test"
        bundle_id=[string]$prepared.push_plan.bundle_id;unit_ids=@("unit-auto-001")
        prepared_plan=[ordered]@{container=&$realFileBinding "receipts/push-plan.json";member="push_plan"}
        prepared_event=[ordered]@{event_id=$preparedEventId;intent=&$realFileBinding $preparedIntentRelative;completion=&$realFileBinding $preparedCompletionRelative;member="event"}
        accepted_unit=&$realFileBinding $realUnitRelative
        validation_receipt=&$realFileBinding $realValidationRelative
        validation_event=[ordered]@{event_id=[string]$record.event_id;intent=&$realFileBinding $realValidationIntentRelative;completion=&$realFileBinding $realValidationCompletionRelative}
        acceptance_event=[ordered]@{event_id=[string]$accepted.event_id;intent=&$realFileBinding $realAcceptanceIntentRelative;completion=&$realFileBinding $realAcceptanceCompletionRelative}
        pending_bundle=[ordered]@{value=$realReconstructionState.pending_push_bundle;sha256=Get-MorphospaceCanonicalJsonSha256 $realReconstructionState.pending_push_bundle}
        stale_blocker=[ordered]@{value=$staleBlocker;sha256=Get-MorphospaceCanonicalJsonSha256 $staleBlocker}
        active_workspace_observation=[ordered]@{evidentiary=$false;repositories=@()}
        logical_legs=$realLogicalLegs;physical_refs=$realPhysicalRefs
        conflicting_evidence=[ordered]@{executed_push_receipt_present=$false;planned_accounting_present=$false;unplanned_closure_present=$false}
        claims=[ordered]@{original_plan_execution=$false;cross_repository_execution_or_publication_order=$false;source_first_planning_last_execution=$false;force_or_no_force_history=$false;publication_actor_or_timestamp=$false;historical_nonpublication_or_impossibility=$false;original_not_performed_preserved=$true}
        mutation=[ordered]@{pending_bundle_consumed=$true;blocker_consumed=$true}
    }
    $realReconstructionInput = Join-Path $testRoot "real-prepared-publication-reconstruction.json"
    Write-TestJson -Path $realReconstructionInput -Value $realReconstructionDocument
    $realReconstructionDryRun = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action ReconcilePreparedPublication -WorkspaceRoot $workspace `
        -UnitId "unit-auto-001" -RepoMapPath $reconstructionMapPath -PreparedPublicationReconstruction $realReconstructionInput -Timestamp $fixed | ConvertFrom-Json
    Assert-Automation ($realReconstructionDryRun.transition -eq "prepared-publication-reconstructed" -and -not $realReconstructionDryRun.executed) "real RecordValidation/Accept/PreparePush provenance did not pass prepared-publication reconstruction"

    Invoke-TestGit -Path $remote -Arguments @("update-ref", "refs/heads/main", $remoteBefore) | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("fetch", "origin") | Out-Null
    Invoke-TestGit -Path $planningRemote -Arguments @("update-ref", "refs/heads/main", $planningRemoteBefore) | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("fetch", "origin") | Out-Null
    Write-TestJson -Path $retirementInput -Value $retirementDocument

    $mismatchedBlockerRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $mismatchedBlockerRetirement.mutation.blocker_id = "unrelated-auto-blocker"
    Write-TestJson -Path $retirementInput -Value $mismatchedBlockerRetirement
    $mismatchedBlockerRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $mismatchedBlockerRejected = $_.Exception.Message -like "*blocker identity mismatch*" }
    Assert-Automation $mismatchedBlockerRejected "prepared-push retirement accepted a non-null blocker ID different from the canonical stale blocker"

    $nullPlanningRepo = Join-Path $testRoot "planning-null-retirement"
    Invoke-TestGit -Path $testRoot -Arguments @("-c", "core.autocrlf=false", "clone", "--quiet", "--branch", "main", $planningRepo, $nullPlanningRepo) | Out-Null
    $workspaceRelative = [IO.Path]::GetRelativePath($planningRepo, $workspace)
    $nullWorkspace = Join-Path $nullPlanningRepo $workspaceRelative
    $nullRepoMapPath = Join-Path $testRoot "repository-map-null-retirement.json"
    $nullRepoMap = Get-Content -Raw $repoMapPath | ConvertFrom-Json
    (@($nullRepoMap.repositories | Where-Object { [string]$_.repo_id -eq "workflow-planning" }))[0].path = $nullPlanningRepo
    Write-TestJson -Path $nullRepoMapPath -Value $nullRepoMap
    $nullRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $nullRetirement.mutation.blocker_id = $null
    $nullRetirement.repositories = @($prepared.push_plan.repositories | ForEach-Object {
        $path = if ([string]$_.repo_id -eq "project-shell") { $repo } else { $nullPlanningRepo }
        $head = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "HEAD"))[0]
        $upstream = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"))[0]
        $remoteRevision = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "@{upstream}"))[0]
        $counts = (@(Invoke-TestGit -Path $path -Arguments @("rev-list", "--left-right", "--count", "HEAD...@{upstream}"))[0] -split "\s+")
        [ordered]@{
            repo_id = [string]$_.repo_id; role = [string]$_.role; branch = [string]$_.branch; upstream = $upstream
            prepared_revision = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "$([string]$_.commit)^{commit}"))[0]
            local_head = $head; remote_readback_revision = $remoteRevision; worktree_clean = $true
            detached = $false; ahead = [int]$counts[0]; behind = [int]$counts[1]; diverged = $false
        }
    })
    $nullRetirementInput = Join-Path $testRoot "prepared-push-retirement-null-input.json"
    $nullRetirementOutput = Join-Path $nullWorkspace "receipts\prepared-push-retirement-null.json"
    Write-TestJson -Path $nullRetirementInput -Value $nullRetirement
    $nullRetired = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $nullWorkspace `
        -UnitId "unit-auto-001" -RepoMapPath $nullRepoMapPath -PreparedPushRetirement $nullRetirementInput -Timestamp $fixed `
        -OutPath $nullRetirementOutput -Execute | ConvertFrom-Json
    $nullRetiredState = Get-Content -Raw (Join-Path $nullWorkspace "workspace.state.json") | ConvertFrom-Json
    Assert-Automation ($nullRetired.executed -and $null-eq$nullRetiredState.pending_push_bundle) "null-blocker retirement did not consume the pending bundle"
    Assert-Automation (@($nullRetiredState.blockers | Where-Object blocker_id -eq "stale-auto-push-plan").Count -eq 1) "null-blocker retirement removed the canonically observed stale blocker"
    Assert-Automation (@($nullRetiredState.blockers | Where-Object blocker_id -eq "unrelated-auto-blocker").Count -eq 1) "null-blocker retirement removed an unrelated blocker"
    Write-TestJson -Path $retirementInput -Value $retirementDocument

    $retired = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace `
        -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed `
        -OutPath $retirementOutput -Execute | ConvertFrom-Json
    $retiredState = Get-Content -Raw (Join-Path $workspace "workspace.state.json") | ConvertFrom-Json
    Assert-Automation ($retired.executed -and $retired.event_id -like "*prepared-push-retired*" -and $null -eq $retiredState.pending_push_bundle) "prepared-push retirement did not consume exactly one pending bundle"
    Assert-Automation ((-not ($retiredState.PSObject.Properties.Name -contains "prepared_push_retirements")) -and (Test-Path $retirementOutput) -and @($retiredState.blockers | Where-Object blocker_id -eq "stale-auto-push-plan").Count -eq 0) "prepared-push retirement receipt was not transaction-owned or exact blocker was not removed"
    Assert-Automation (@($retiredState.blockers | Where-Object blocker_id -eq "unrelated-auto-blocker").Count -eq 1) "prepared-push retirement removed an unrelated blocker"
    $repeatRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $repeatRejected = $_.Exception.Message -like "*already consumed*" }
    Assert-Automation $repeatRejected "prepared-push retirement permitted repeated consumption"

    $orderingInterruptionPath = Join-Path $receiptRoot "publication-ordering-interruption.json"
    Write-TestJson -Path $orderingInterruptionPath -Value ([ordered]@{
        schema = "rusty.morphospace.workflow.publication_ordering_interruption.v1"; project_id = "automation-test"; unit_id = "unit-auto-001"
        kind = "planning-published-before-source"; observed_at = $fixed
        planning = [ordered]@{ repo_id = "workflow-planning"; early_remote_revision = (@(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "@{upstream}"))[0]); local_prepared_revision = $planningHead }
        sources = @([ordered]@{ repo_id = "project-shell"; unpublished_remote_revision = $remoteBefore; local_revision = $localHead })
        does_not_claim = @("planning-last chronology", "source publication", "executed push", "publication accounting", "recorded publication")
    })
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "preserve publication ordering interruption") | Out-Null
    $planningRecoveryHead = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "HEAD"))[0]
    Write-TestJson -Path $revisionsPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.revision_set.v1"; repositories = @(
        [ordered]@{ repo_id = "project-shell"; commit = $localHead },
        [ordered]@{ repo_id = "workflow-planning"; commit = $planningRecoveryHead }
    ) })
    $recoveredPlan = Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -RevisionsPath $revisionsPath -PublicationOrderingInterruption "receipts/publication-ordering-interruption.json" -Timestamp $fixed -OutPath (Join-Path $receiptRoot "recovered-push-plan.json")
    Assert-Automation ($recoveredPlan.push_plan.publication_ordering_interruption.early_planning_checkpoint_preserved -and -not $recoveredPlan.push_plan.publication_ordering_interruption.source_publication_claimed) "fresh plan did not preserve the early-planning ordering fault"
    $damagedInterruption = Get-Content -Raw $orderingInterruptionPath | ConvertFrom-Json
    $damagedInterruption.sources[0].unpublished_remote_revision = "0000000000000000000000000000000000000000"
    Write-TestJson -Path $orderingInterruptionPath -Value $damagedInterruption
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "damage publication ordering interruption fixture") | Out-Null
    $planningDamagedHead = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "HEAD"))[0]
    Write-TestJson -Path $revisionsPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.revision_set.v1"; repositories = @(
        [ordered]@{ repo_id = "project-shell"; commit = $localHead },
        [ordered]@{ repo_id = "workflow-planning"; commit = $planningDamagedHead }
    ) })
    $damagedOrderingRejected = $false
    try { Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -RevisionsPath $revisionsPath -PublicationOrderingInterruption "receipts/publication-ordering-interruption.json" -Timestamp $fixed | Out-Null } catch { $damagedOrderingRejected = $_.Exception.Message -like "Publication-ordering interruption source refs do not match*" }
    Assert-Automation $damagedOrderingRejected "damaged unpublished source readback was accepted"

    & git clone --quiet --branch main $remote $peer 2>$null | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("config", "user.name", "Automation Peer") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("config", "user.email", "peer@example.invalid") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("config", "core.autocrlf", "false") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("switch", "main") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $peer "peer.txt"), "peer`n", $encoding)
    Invoke-TestGit -Path $peer -Arguments @("add", "peer.txt") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("commit", "-m", "peer") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("push", "origin", "main") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("fetch", "origin") | Out-Null
    $divergedBefore = (Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--branch")) -join "`n"
    $blockedPush = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -RevisionsPath $revisionsPath -Timestamp $fixed -OutPath (Join-Path $receiptRoot "must-not-exist.json") -Execute | Out-Null
    } catch {
        $blockedPush = $_.Exception.Message -like "Push preparation refused unsafe repo*"
    }
    Assert-Automation $blockedPush "divergent push preparation was not refused"
    Assert-Automation ($divergedBefore -eq ((Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--branch")) -join "`n")) "divergent repo was rewritten"

    $recoveryWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "recovery-project") -ProjectId "recovery-test" -UnitId "unit-recover-001"
    $recoveryStatePath = Join-Path $recoveryWorkspace "workspace.state.json"
    $initialRecoveryState = Get-Content $recoveryStatePath -Raw | ConvertFrom-Json
    $initialRecoveryState.dirty_repositories = @("project-shell")
    Write-TestJson -Path $recoveryStatePath -Value $initialRecoveryState
    Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -Timestamp $fixed -Execute | Out-Null
    Assert-Automation (@((Get-Content $recoveryStatePath -Raw | ConvertFrom-Json).dirty_repositories) -contains "project-shell") "unmapped execution erased prior dirty-repository state"
    Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -Timestamp $fixed -Execute | Out-Null
    $failureReceiptPath = New-TestValidationReceipt -Workspace $recoveryWorkspace -ProjectId "recovery-test" -UnitId "unit-recover-001" -Tier standard -Result fail -EvidenceName "failure-evidence.txt"
    Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -ValidationTier standard -ValidationResult fail -ValidationReceipt "receipts/unit-recover-001-fail-validation.json" -Timestamp $fixed -Execute | Out-Null
    $blockedState = Get-Content (Join-Path $recoveryWorkspace "workspace.state.json") -Raw | ConvertFrom-Json
    Assert-Automation ($blockedState.blockers.Count -eq 1 -and $null -eq $blockedState.current_unit) "failed validation did not persist blocker"
    Invoke-MorphospaceWorkUnitAutomation -Action Resume -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -Timestamp $fixed -Execute | Out-Null
    $resumedState = Get-Content (Join-Path $recoveryWorkspace "workspace.state.json") -Raw | ConvertFrom-Json
    Assert-Automation ($resumedState.blockers.Count -eq 1) "resume discarded blocker history"
    $resumedState.current_unit = $null
    Write-TestJson -Path (Join-Path $recoveryWorkspace "workspace.state.json") -Value $resumedState
    $recovered = Invoke-MorphospaceWorkUnitAutomation -Action Recover -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -Timestamp $fixed -Execute
    Assert-Automation ($recovered.transition -eq "restore-current-unit" -and [string]$recovered.current_unit_after -eq "unit-recover-001") "interrupted recovery"

    $interruptionCases = @(
        [ordered]@{ kind = "partial-cross-repo-commit"; project = "partial-recovery-test"; unit = "unit-partial-001" },
        [ordered]@{ kind = "interrupted-build"; project = "build-recovery-test"; unit = "unit-build-001" },
        [ordered]@{ kind = "interrupted-device"; project = "device-recovery-test"; unit = "unit-device-001" }
    )
    foreach ($case in $interruptionCases) {
        $caseWorkspace = New-TestWorkspace -Root (Join-Path $testRoot $case.project) -ProjectId $case.project -UnitId $case.unit
        $caseUnitPath = Join-Path $caseWorkspace "iteration-units\$($case.unit).json"
        $caseUnit = Get-Content -LiteralPath $caseUnitPath -Raw | ConvertFrom-Json
        $caseUnit.status = "active"
        if ($case.kind -eq "partial-cross-repo-commit") {
            $caseUnit.allowed_repositories = @($caseUnit.allowed_repositories) + [pscustomobject][ordered]@{ repo_id = "planning-surface"; allowed_paths = @("workspaces/") }
            $caseSpecPath = Join-Path $caseWorkspace "project.spec.json"
            $caseSpec = Get-Content -LiteralPath $caseSpecPath -Raw | ConvertFrom-Json
            $caseSpec.repositories = @($caseSpec.repositories) + [pscustomobject][ordered]@{ repo_id = "planning-surface"; role = "planning"; path = "<planning>"; allowed_paths = @("workspaces/") }
            Write-TestJson -Path $caseSpecPath -Value $caseSpec
        }
        Write-TestJson -Path $caseUnitPath -Value $caseUnit
        $caseStatePath = Join-Path $caseWorkspace "workspace.state.json"
        $caseState = Get-Content -LiteralPath $caseStatePath -Raw | ConvertFrom-Json
        $caseState.current_unit = $null; $caseState.next_ready_unit = $null
        $caseState.blockers = @([pscustomobject][ordered]@{
            blocker_id = "$($case.unit)-interrupted"
            condition = "Interrupted $($case.kind) requires structured cleanup evidence."
            resume_when = "A typed recovery receipt proves safe cleanup."
        })
        Write-TestJson -Path $caseStatePath -Value $caseState

        $missingRecoveryRejected = $false
        try { Invoke-MorphospaceWorkUnitAutomation -Action Recover -WorkspaceRoot $caseWorkspace -UnitId $case.unit -RepoMapPath $repoMapPath -Timestamp $fixed | Out-Null }
        catch { $missingRecoveryRejected = $_.Exception.Message -eq "Interrupted work requires a typed recovery receipt before state restoration." }
        Assert-Automation $missingRecoveryRejected "$($case.kind) recovered without a typed receipt"
        $currentRevision = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
        New-TestInterruptionReceipt -Workspace $caseWorkspace -ProjectId $case.project -UnitId $case.unit -Kind $case.kind -Revision $currentRevision -Safe $false -Cleanup $false | Out-Null
        $unsafeRecoveryRejected = $false
        try { Invoke-MorphospaceWorkUnitAutomation -Action Recover -WorkspaceRoot $caseWorkspace -UnitId $case.unit -RepoMapPath $repoMapPath -RecoveryReceipt "receipts/$($case.unit)-$($case.kind)-recovery.json" -Timestamp $fixed | Out-Null }
        catch { $unsafeRecoveryRejected = $_.Exception.Message -eq "Recovery receipt does not prove safe, complete cleanup." }
        Assert-Automation $unsafeRecoveryRejected "$($case.kind) accepted incomplete cleanup"
        New-TestInterruptionReceipt -Workspace $caseWorkspace -ProjectId $case.project -UnitId $case.unit -Kind $case.kind -Revision $currentRevision | Out-Null
        $safeRecovery = Invoke-MorphospaceWorkUnitAutomation -Action Recover -WorkspaceRoot $caseWorkspace -UnitId $case.unit -RepoMapPath $repoMapPath -RecoveryReceipt "receipts/$($case.unit)-$($case.kind)-recovery.json" -Timestamp $fixed -Execute
        Assert-Automation ($safeRecovery.transition -eq "restore-current-unit" -and [string]$safeRecovery.current_unit_after -eq [string]$case.unit) "$($case.kind) safe recovery"
        Assert-Automation ($safeRecovery.preservation.git_mutation_performed -eq $false -and $safeRecovery.preservation.device_mutation_performed -eq $false) "$($case.kind) recovery mutated external state"
        & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $caseWorkspace -SkipOwnerSelfTests
    }

    $supersessionWorkspace = New-TestWorkspace `
        -Root (Join-Path $testRoot "supersession-test") `
        -ProjectId "supersession-test" `
        -UnitId "old-unit"
    $oldUnitPath = Join-Path $supersessionWorkspace "iteration-units\old-unit.json"
    $oldUnit = Get-Content -LiteralPath $oldUnitPath -Raw | ConvertFrom-Json
    $oldUnit.status = "active"
    Write-TestJson -Path $oldUnitPath -Value $oldUnit
    $currentUnit = New-TestUnit -ProjectId "supersession-test" -UnitId "current-unit"
    $currentUnit.status = "validating"
    $currentUnit.prerequisites = @("old-unit")
    Write-TestJson -Path (Join-Path $supersessionWorkspace "iteration-units\current-unit.json") -Value $currentUnit
    $supersessionEvent = [ordered]@{
        schema = "rusty.morphospace.workflow.iteration_event.v1"
        event_id = "old-unit-superseded-by-current-unit"
        sequence = 1
        timestamp = "2026-01-02T03:04:05Z"
        project_id = "supersession-test"
        unit_id = "old-unit"
        event_type = "state-transition"
        summary = "The corrective current unit additively supersedes immutable historical in-flight state."
        receipts = @()
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $supersessionWorkspace "iteration-events.jsonl"),
        (($supersessionEvent | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $encoding
    )
    $supersessionStatePath = Join-Path $supersessionWorkspace "workspace.state.json"
    $supersessionState = Get-Content -LiteralPath $supersessionStatePath -Raw | ConvertFrom-Json
    $supersessionState.current_unit = "current-unit"
    $supersessionState.next_ready_unit = $null
    $supersessionState.last_event_id = "old-unit-superseded-by-current-unit"
    Write-TestJson -Path $supersessionStatePath -Value $supersessionState
    & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $supersessionWorkspace -SkipOwnerSelfTests

    $supersessionEvent.event_type = "validation"
    [System.IO.File]::WriteAllText(
        (Join-Path $supersessionWorkspace "iteration-events.jsonl"),
        (($supersessionEvent | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $encoding
    )
    $damagedSupersessionRejected = $false
    try {
        & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $supersessionWorkspace -SkipOwnerSelfTests
    } catch {
        $damagedSupersessionRejected = $_.Exception.Message -like "Workflow contract validation failed*"
    }
    Assert-Automation $damagedSupersessionRejected "supersession accepted a non-state-transition event"

    & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $recoveryWorkspace -SkipOwnerSelfTests
    Write-Host "Work-unit automation self-test passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        if (-not $resolved.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a test directory outside the system temporary directory."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
