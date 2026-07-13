param()

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot "WorkUnitAutomation.psm1") -Force

function Assert-Automation {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Automation self-test failed: $Message" }
}

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

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("rusty-morphospace-automation-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $remote = Join-Path $testRoot "remote.git"
    $repo = Join-Path $testRoot "project-repo"
    $peer = Join-Path $testRoot "peer-repo"
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

    $workspace = New-TestWorkspace -Root (Join-Path $testRoot "project") -ProjectId "automation-test" -UnitId "unit-auto-001"
    $nextUnit = New-TestUnit -ProjectId "automation-test" -UnitId "unit-auto-002"
    $nextUnit.prerequisites = @("unit-auto-001")
    Write-TestJson -Path (Join-Path $workspace "iteration-units\unit-auto-002.json") -Value $nextUnit
    $repoMapPath = Join-Path $testRoot "repo-map.json"
    Write-TestJson -Path $repoMapPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.repository_map.v1"; repositories = @([ordered]@{ repo_id = "project-shell"; path = $repo; role = "source" }) })
    $receiptRoot = Join-Path $workspace "receipts"
    $fixed = "2026-01-02T03:04:05Z"

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

    $scopeWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "scope-project") -ProjectId "scope-test" -UnitId "unit-scope-001"
    [System.IO.File]::WriteAllText((Join-Path $repo "outside.txt"), "outside unit scope`n", $encoding)
    Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    $scopeHead = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $scopeBranch = @(Invoke-TestGit -Path $repo -Arguments @("branch", "--show-current"))[0]
    New-TestValidationReceipt -Workspace $scopeWorkspace -ProjectId "scope-test" -UnitId "unit-scope-001" -Tier standard -Result pass -RepositoryRevisions @([ordered]@{
        repo_id = "project-shell"; base_revision = $scopeHead; head_revision = $scopeHead; branch = $scopeBranch
    }) | Out-Null
    $scopeRecord = Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -ValidationTier standard -ValidationResult pass -ValidationReceipt "receipts/unit-scope-001-pass-validation.json" -Timestamp $fixed
    Assert-Automation ($scopeRecord.transition -eq "validation-pass" -and (Test-Path -LiteralPath (Join-Path $repo "outside.txt"))) "out-of-scope user work blocked validation or was modified"
    New-TestValidationReceipt -Workspace $scopeWorkspace -ProjectId "scope-test" -UnitId "unit-scope-001" -Tier standard -Result pass -RepositoryRevisions @([ordered]@{
        repo_id = "project-shell"; base_revision = $scopeHead; head_revision = $scopeHead; branch = $scopeBranch
    }) -ChangedPaths @([ordered]@{ repo_id = "project-shell"; path = "outside.txt" }) | Out-Null
    $outsideScopeRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -ValidationTier standard -ValidationResult pass -ValidationReceipt "receipts/unit-scope-001-pass-validation.json" -Timestamp $fixed | Out-Null
    } catch {
        $outsideScopeRejected = $_.Exception.Message -like "Validation changed path is outside unit scope*"
    }
    Assert-Automation $outsideScopeRejected "validation did not reject an out-of-scope changed path"
    Remove-Item -LiteralPath (Join-Path $repo "outside.txt")

    [System.IO.File]::WriteAllText((Join-Path $repo "src\ahead.txt"), "ahead`n", $encoding)
    Invoke-TestGit -Path $repo -Arguments @("add", "src/ahead.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "ahead") | Out-Null
    $localHead = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $remoteBefore = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "origin/main"))[0]
    $revisionsPath = Join-Path $testRoot "revisions.json"
    Write-TestJson -Path $revisionsPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.revision_set.v1"; repositories = @([ordered]@{ repo_id = "project-shell"; commit = $localHead }) })
    $pushPlanPath = Join-Path $receiptRoot "push-plan.json"
    $prepared = Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -RevisionsPath $revisionsPath -Timestamp $fixed -OutPath $pushPlanPath -Execute
    Assert-Automation ($prepared.push_plan.schema -eq "rusty.morphospace.workflow.push_bundle_plan.v1" -and $prepared.push_plan.execution -eq "not-performed" -and -not $prepared.push_plan.force_push_allowed) "push plan execution boundary"
    Assert-Automation (-not ($prepared.push_plan.PSObject.Properties.Name -contains "remote_readback_complete")) "automation fabricated executed-push evidence"
    Assert-Automation ((@(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "origin/main"))[0]) -eq $remoteBefore) "push preparation changed the remote"

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
        & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $caseWorkspace
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
    & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $supersessionWorkspace

    $supersessionEvent.event_type = "validation"
    [System.IO.File]::WriteAllText(
        (Join-Path $supersessionWorkspace "iteration-events.jsonl"),
        (($supersessionEvent | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $encoding
    )
    $damagedSupersessionRejected = $false
    try {
        & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $supersessionWorkspace
    } catch {
        $damagedSupersessionRejected = $_.Exception.Message -like "Workflow contract validation failed*"
    }
    Assert-Automation $damagedSupersessionRejected "supersession accepted a non-state-transition event"

    & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $recoveryWorkspace
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
