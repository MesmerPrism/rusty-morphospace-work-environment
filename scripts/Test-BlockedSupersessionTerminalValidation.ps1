param([switch]$KeepFixture)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceBlockedSupersessionTerminalValidation.psm1') -Force

$encoding = [Text.UTF8Encoding]::new($false)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-blocked-supersession-' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $testRoot 'source'
$planningRoot = Join-Path $testRoot 'planning'
$workspace = Join-Path $planningRoot 'morphospace'
$repoMapPath = Join-Path $testRoot 'repository-map.json'
$projectId = 'terminal-history-fixture'
$oldUnitId = 'predecessor-owner'
$replacementUnitId = 'replacement-owner'
$supersessionEventId = "$oldUnitId-superseded-by-$replacementUnitId"
$assertions = [Collections.Generic.List[string]]::new()

function Write-FixtureJson {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 64 -Compress) + [Environment]::NewLine), $encoding)
}

function Read-FixtureJson { param([string]$Path) return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }

function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $output = @(& git -C $sourceRoot @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)" }
    return @($output)
}

function New-FixtureUnit {
    param([string]$UnitId, [string]$Status)
    return [pscustomobject][ordered]@{
        '$schema' = '../schemas/iteration-unit.schema.json'
        schema = 'rusty.morphospace.workflow.iteration_unit.v1'
        unit_id = $UnitId
        project_id = $projectId
        status = $Status
        objective = "Exercise owner-authenticated terminal history for $UnitId."
        change_categories = @('validation')
        instruction_impact = 'update'
        instruction_surfaces = @(
            [pscustomobject][ordered]@{ surface_kind = 'agents'; path = '<repo-root>/AGENTS.md'; owner = 'fixture-owner'; change_reason = 'Exercise the instruction projection required by a feature-mode fixture.'; action = 'update'; status = 'complete'; validation = 'Synthetic fixture review.'; skill_id = $null },
            [pscustomobject][ordered]@{ surface_kind = 'readme'; path = '<repo-root>/README.md'; owner = 'fixture-owner'; change_reason = 'Exercise the public router projection required by a feature-mode fixture.'; action = 'update'; status = 'complete'; validation = 'Synthetic fixture review.'; skill_id = $null },
            [pscustomobject][ordered]@{ surface_kind = 'skill'; path = '<skills-root>/rusty-morphospace/SKILL.md'; owner = 'workflow-maintainer'; change_reason = 'Exercise the Morphospace skill projection required by a feature-mode fixture.'; action = 'update'; status = 'complete'; validation = 'Synthetic fixture review.'; skill_id = 'rusty-morphospace' },
            [pscustomobject][ordered]@{ surface_kind = 'skill'; path = '<skills-root>/system-engineering/SKILL.md'; owner = 'workflow-maintainer'; change_reason = 'Exercise the system-authority skill projection required by a feature-mode fixture.'; action = 'update'; status = 'complete'; validation = 'Synthetic fixture review.'; skill_id = 'system-engineering' }
        )
        prerequisites = @()
        allowed_repositories = @([pscustomobject][ordered]@{ repo_id = 'fixture-source'; allowed_paths = @('src/', 'AGENTS.md', 'README.md', 'rusty-morphospace/SKILL.md', 'system-engineering/SKILL.md') })
        non_scope = @('Real projects, remotes, devices, and publication.')
        acceptance = @([pscustomobject][ordered]@{ acceptance_id = 'fixture-proof'; proof = 'The neutral workflow fixture passes.'; command = 'Test-BlockedSupersessionTerminalValidation.ps1' })
        risk_tier = 'standard'
        device_requirement = 'none'
        validation = @([pscustomobject][ordered]@{ profile_id = 'workflow'; command = 'Run the neutral workflow fixture.' })
        outputs = @('Synthetic owner transition evidence.')
        commit_policy = 'Temporary local fixture only.'
        push_checkpoint = 'local-only'
    }
}

function New-FixtureValidationReceipt {
    param([string]$Workspace, [string]$UnitId, [ValidateSet('pass','fail')][string]$Result, [string]$Suffix)
    $head = ([string]@(Invoke-FixtureGit @('rev-parse','HEAD'))[0]).Trim()
    $receiptRoot = Join-Path $Workspace 'receipts'
    [IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
    $evidenceName = "$UnitId-$Suffix-evidence.txt"
    $evidencePath = Join-Path $receiptRoot $evidenceName
    [IO.File]::WriteAllText($evidencePath, "neutral $Result validation evidence`n", $encoding)
    $evidenceHash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $status = if ($Result -eq 'pass') { 'pass' } else { 'fail' }
    $receiptName = "$UnitId-$Suffix-validation.json"
    $receipt = [pscustomobject][ordered]@{
        '$schema' = '../schemas/validation-receipt.schema.json'
        schema = 'rusty.morphospace.workflow.validation_receipt.v1'
        receipt_id = "$UnitId-$Suffix-validation"
        project_id = $projectId
        unit_id = $UnitId
        created_at = '2026-01-02T03:05:00.0000000Z'
        tier = 'standard'
        result = $Result
        repository_revisions = @([pscustomobject][ordered]@{ repo_id = 'fixture-source'; base_revision = $head; head_revision = $head; branch = 'main' })
        changed_paths = @()
        artifacts = @([pscustomobject][ordered]@{ artifact_id = 'fixture-evidence'; kind = 'test-log'; path = $evidenceName; sha256 = $evidenceHash })
        criteria = @([pscustomobject][ordered]@{ acceptance_id = 'fixture-proof'; status = $status; command = 'Test-BlockedSupersessionTerminalValidation.ps1'; evidence_refs = @('fixture-evidence') })
        gates = @(
            [pscustomobject][ordered]@{ gate_id = 'validation-workflow'; status = $status; command = 'Run the neutral workflow fixture.'; evidence_refs = @('fixture-evidence') },
            [pscustomobject][ordered]@{ gate_id = 'instruction-synchronization'; status = $status; command = 'Verify every declared instruction surface is complete and validated.'; evidence_refs = @('fixture-evidence') }
        )
        device_validation = $null
    }
    Write-FixtureJson -Path (Join-Path $receiptRoot $receiptName) -Value $receipt
    return "receipts/$receiptName"
}

function Copy-FixtureWorkspace {
    param([string]$Source, [string]$Name)
    $destination = Join-Path $testRoot $Name
    if (Test-Path -LiteralPath $destination) { throw "Fixture destination already exists: $destination" }
    Copy-Item -LiteralPath $Source -Destination $destination -Recurse
    return $destination
}

function Invoke-OwnerAction {
    param(
        [string]$Workspace,
        [string]$Action,
        [string]$UnitId,
        [string]$Timestamp,
        [string]$ValidationReceipt = '',
        [string]$ValidationResult = 'pass'
    )
    $arguments = @{
        Action = $Action
        WorkspaceRoot = $Workspace
        UnitId = $UnitId
        RepoMapPath = $repoMapPath
        ValidationTier = 'standard'
        Timestamp = $Timestamp
        Execute = $true
    }
    if ($ValidationReceipt) { $arguments.ValidationReceipt = $ValidationReceipt; $arguments.ValidationResult = $ValidationResult }
    Invoke-MorphospaceWorkUnitAutomation @arguments | Out-Null
}

function Invoke-WorkflowContract {
    param([string]$Workspace)
    & (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -RepoRoot $RepoRoot -WorkspaceRoot $Workspace -RepositoryMapPath $repoMapPath -SkipOwnerSelfTests
}

function Assert-Passed {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "Assertion failed: $Name" }
    $assertions.Add($Name) | Out-Null
}

function Assert-HelperPasses {
    param([string]$Workspace, [string]$Name, [int]$ContinuationCount)
    $result = Test-MorphospaceBlockedSupersessionTerminalValidation -WorkspaceRoot $Workspace -ProjectId $projectId -SupersessionEventId $supersessionEventId -ReplacementUnitId $replacementUnitId
    Assert-Passed ($result.history_present -and $result.authenticated -and [int]$result.continuation_event_count -eq $ContinuationCount -and -not $result.acceptance_inferred) $Name
}

function Assert-HelperRejects {
    param([string]$Template, [string]$Name, [scriptblock]$Mutation)
    $caseRoot = Copy-FixtureWorkspace -Source $Template -Name ('damage-' + $Name)
    & $Mutation $caseRoot
    $rejected = $false
    try {
        Test-MorphospaceBlockedSupersessionTerminalValidation -WorkspaceRoot $caseRoot -ProjectId $projectId -SupersessionEventId $supersessionEventId -ReplacementUnitId $replacementUnitId | Out-Null
    } catch { $rejected = $true }
    Assert-Passed $rejected $Name
}

function Assert-WorkflowRejects {
    param([string]$Template, [string]$Name, [scriptblock]$Mutation)
    $caseRoot = Copy-FixtureWorkspace -Source $Template -Name ('workflow-damage-' + $Name)
    & $Mutation $caseRoot
    $rejected = $false
    try { Invoke-WorkflowContract -Workspace $caseRoot *> $null } catch { $rejected = $true }
    Assert-Passed $rejected $Name
}

function Update-FixtureJson {
    param([string]$Path, [scriptblock]$Mutation)
    $document = Read-FixtureJson -Path $Path
    & $Mutation $document
    Write-FixtureJson -Path $Path -Value $document
}

function Rebind-FixtureTransaction {
    param([string]$Workspace, [string]$EventId)
    $transactionId = "$EventId-transition"
    $intentPath = Join-Path $Workspace "receipts\transactions\$transactionId.intent.json"
    $completionPath = Join-Path $Workspace "receipts\transactions\$transactionId.completion.json"
    $intent = Read-FixtureJson -Path $intentPath
    $intent.target.state.sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $intent.target.state.document
    $intent.target.unit.sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $intent.target.unit.document
    Write-FixtureJson -Path $intentPath -Value $intent
    $completion = Read-FixtureJson -Path $completionPath
    $completion.intent.sha256 = (Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $completion.state_sha256 = [string]$intent.target.state.sha256
    $completion.unit_sha256 = [string]$intent.target.unit.sha256
    Write-FixtureJson -Path $completionPath -Value $completion
}

function Update-FixtureLedgerEvent {
    param([string]$Workspace, [string]$EventId, [scriptblock]$Mutation)
    $path = Join-Path $Workspace 'iteration-events.jsonl'
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json
        if ([string]$event.event_id -ceq $EventId) { & $Mutation $event }
        $lines.Add(($event | ConvertTo-Json -Depth 32 -Compress)) | Out-Null
    }
    [IO.File]::WriteAllText($path, (($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine), $encoding)
}

function Add-LaterUnit {
    param([string]$Workspace, [switch]$Accept)
    $laterUnitId = if ($Accept) { 'later-accepted-owner' } else { 'later-current-owner' }
    Write-FixtureJson -Path (Join-Path $Workspace "iteration-units\$laterUnitId.json") -Value (New-FixtureUnit -UnitId $laterUnitId -Status 'proposed')
    Invoke-OwnerAction -Workspace $Workspace -Action Ready -UnitId $laterUnitId -Timestamp '2026-01-02T03:06:00.0000000Z'
    Invoke-OwnerAction -Workspace $Workspace -Action Claim -UnitId $laterUnitId -Timestamp '2026-01-02T03:07:00.0000000Z'
    if ($Accept) {
        Invoke-OwnerAction -Workspace $Workspace -Action BeginValidation -UnitId $laterUnitId -Timestamp '2026-01-02T03:08:00.0000000Z'
        $receipt = New-FixtureValidationReceipt -Workspace $Workspace -UnitId $laterUnitId -Result pass -Suffix pass
        Invoke-OwnerAction -Workspace $Workspace -Action RecordValidation -UnitId $laterUnitId -Timestamp '2026-01-02T03:09:00.0000000Z' -ValidationReceipt $receipt -ValidationResult pass
        Invoke-OwnerAction -Workspace $Workspace -Action Accept -UnitId $laterUnitId -Timestamp '2026-01-02T03:10:00.0000000Z'
    }
}

try {
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'src')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'rusty-morphospace')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'system-engineering')) | Out-Null
    & git -C $sourceRoot init -b main | Out-Null
    & git -C $sourceRoot config user.name 'Neutral Fixture'
    & git -C $sourceRoot config user.email 'fixture@example.invalid'
    & git -C $sourceRoot config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'src\seed.txt'), "seed`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'AGENTS.md'), "# Neutral fixture instructions`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'README.md'), "# Neutral fixture router`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'rusty-morphospace\SKILL.md'), "# Neutral Morphospace fixture skill`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'system-engineering\SKILL.md'), "# Neutral system fixture skill`n", $encoding)
    Invoke-FixtureGit @('add','src/seed.txt','AGENTS.md','README.md','rusty-morphospace/SKILL.md','system-engineering/SKILL.md') | Out-Null
    Invoke-FixtureGit @('commit','-m','fixture seed') | Out-Null

    [IO.Directory]::CreateDirectory($planningRoot) | Out-Null
    & (Join-Path $PSScriptRoot 'New-ProjectWorkspace.ps1') -ProjectRoot $planningRoot -ProjectId $projectId -Purpose 'Neutral blocked-supersession terminal history fixture.' -SchemaRevision ((git -C $RepoRoot rev-parse HEAD).Trim()) -Execute | Out-Null
    $specPath = Join-Path $workspace 'project.spec.json'
    $spec = Read-FixtureJson -Path $specPath
    $spec.owner = 'fixture-owner'
    $spec.repositories = @([pscustomobject][ordered]@{ repo_id = 'fixture-source'; role = 'tool'; path = '<repository-map:fixture-source>'; allowed_paths = @('src/', 'AGENTS.md', 'README.md', 'rusty-morphospace/SKILL.md', 'system-engineering/SKILL.md') })
    $spec.validation_profiles = @([pscustomobject][ordered]@{ profile_id = 'workflow'; commands = @('Run the neutral workflow fixture.') })
    $spec.acceptance_profiles = @([pscustomobject][ordered]@{ profile_id = 'rollback'; commands = @('Discard the temporary fixture.') })
    $spec.release_policy.push_checkpoint = 'local-only'
    Write-FixtureJson -Path $specPath -Value $spec

    Write-FixtureJson -Path (Join-Path $workspace "iteration-units\$oldUnitId.json") -Value (New-FixtureUnit -UnitId $oldUnitId -Status 'active')
    $readyReplacement = New-FixtureUnit -UnitId $replacementUnitId -Status 'ready'
    Write-FixtureJson -Path (Join-Path $workspace "iteration-units\$replacementUnitId.json") -Value $readyReplacement
    $statePath = Join-Path $workspace 'workspace.state.json'
    $state = Read-FixtureJson -Path $statePath
    $state.current_unit = $oldUnitId
    $state.next_ready_unit = $replacementUnitId
    $state.last_event_id = $null
    Write-FixtureJson -Path $statePath -Value $state
    $supersessionEvent = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = $supersessionEventId
        sequence = 1
        timestamp = '2026-01-02T03:03:00.0000000Z'
        project_id = $projectId
        unit_id = $oldUnitId
        event_type = 'state-transition'
        summary = 'The replacement additively supersedes immutable in-flight predecessor state.'
        receipts = @()
    }
    $activeReplacement = $readyReplacement | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $activeReplacement.status = 'active'
    $supersessionTargetState = $state | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $supersessionTargetState.current_unit = $replacementUnitId
    $supersessionTargetState.next_ready_unit = $null
    $supersessionTargetState.last_event_id = $supersessionEventId
    Start-MorphospaceTransitionLedger `
        -WorkspaceRoot $workspace `
        -TransactionId "$supersessionEventId-transition" `
        -StatePath 'workspace.state.json' `
        -UnitPath "iteration-units/$replacementUnitId.json" `
        -EventsPath 'iteration-events.jsonl' `
        -TargetState $supersessionTargetState `
        -TargetUnit $activeReplacement `
        -Event $supersessionEvent | Out-Null
    Write-FixtureJson -Path $repoMapPath -Value ([pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.repository_map.v1'
        repositories = @([pscustomobject][ordered]@{ repo_id = 'fixture-source'; path = $sourceRoot; role = 'source'; aliases = @('repo-root', 'skills-root') })
    })

    $activeWorkspace = Copy-FixtureWorkspace -Source $workspace -Name 'positive-existing-active'
    Invoke-WorkflowContract -Workspace $activeWorkspace | Out-Null
    Assert-Passed $true 'existing-active-replacement'

    Invoke-OwnerAction -Workspace $workspace -Action BeginValidation -UnitId $replacementUnitId -Timestamp '2026-01-02T03:04:00.0000000Z'
    $validatingWorkspace = Copy-FixtureWorkspace -Source $workspace -Name 'positive-existing-validating'
    Invoke-WorkflowContract -Workspace $validatingWorkspace | Out-Null
    Assert-Passed $true 'existing-validating-replacement'

    $acceptedWorkspace = Copy-FixtureWorkspace -Source $workspace -Name 'positive-existing-accepted'
    $acceptedReceipt = New-FixtureValidationReceipt -Workspace $acceptedWorkspace -UnitId $replacementUnitId -Result pass -Suffix pass
    Invoke-OwnerAction -Workspace $acceptedWorkspace -Action RecordValidation -UnitId $replacementUnitId -Timestamp '2026-01-02T03:05:00.0000000Z' -ValidationReceipt $acceptedReceipt -ValidationResult pass
    Invoke-OwnerAction -Workspace $acceptedWorkspace -Action Accept -UnitId $replacementUnitId -Timestamp '2026-01-02T03:06:00.0000000Z'
    Invoke-WorkflowContract -Workspace $acceptedWorkspace | Out-Null
    Assert-Passed $true 'existing-accepted-replacement'

    $failReceipt = New-FixtureValidationReceipt -Workspace $workspace -UnitId $replacementUnitId -Result fail -Suffix fail
    Invoke-OwnerAction -Workspace $workspace -Action RecordValidation -UnitId $replacementUnitId -Timestamp '2026-01-02T03:05:00.0000000Z' -ValidationReceipt $failReceipt -ValidationResult fail
    $baselineWorkspace = Copy-FixtureWorkspace -Source $workspace -Name 'positive-terminal-blocked'
    $events = @(Get-Content -LiteralPath (Join-Path $baselineWorkspace 'iteration-events.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $beginEventId = [string]$events[-2].event_id
    $failEventId = [string]$events[-1].event_id
    Assert-HelperPasses -Workspace $baselineWorkspace -Name 'exact-terminal-lifecycle-positive' -ContinuationCount 0
    Invoke-WorkflowContract -Workspace $baselineWorkspace | Out-Null
    Assert-Passed $true 'terminal-lifecycle-aggregate-integration'

    $laterActiveWorkspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-later-current'
    Add-LaterUnit -Workspace $laterActiveWorkspace
    Assert-HelperPasses -Workspace $laterActiveWorkspace -Name 'historical-later-current-positive' -ContinuationCount 2
    Invoke-WorkflowContract -Workspace $laterActiveWorkspace | Out-Null
    Assert-Passed $true 'historical-later-current-aggregate'

    $laterAcceptedWorkspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-later-accepted'
    Add-LaterUnit -Workspace $laterAcceptedWorkspace -Accept
    Assert-HelperPasses -Workspace $laterAcceptedWorkspace -Name 'historical-later-accepted-positive' -ContinuationCount 5
    Invoke-WorkflowContract -Workspace $laterAcceptedWorkspace | Out-Null
    Assert-Passed $true 'historical-later-accepted-aggregate'

    Assert-WorkflowRejects -Template $activeWorkspace -Name 'arbitrary-blocked-without-chain' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "iteration-units\$replacementUnitId.json") { param($u) $u.status = 'blocked' }
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.current_unit = $null }
    }
    Assert-WorkflowRejects -Template $activeWorkspace -Name 'legacy-or-unrelated-blocked-replacement' -Mutation {
        param($case)
        $unrelatedId = 'legacy-unrelated-owner'
        Write-FixtureJson -Path (Join-Path $case "iteration-units\$unrelatedId.json") -Value (New-FixtureUnit -UnitId $unrelatedId -Status 'blocked')
        Update-FixtureLedgerEvent -Workspace $case -EventId $supersessionEventId -Mutation { param($e) $e.event_id = "$oldUnitId-superseded-by-$unrelatedId" }
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.current_unit = $null; $s.last_event_id = "$oldUnitId-superseded-by-$unrelatedId" }
    }
    Assert-WorkflowRejects -Template $baselineWorkspace -Name 'manual-supersession-event-without-owner-transaction' -Mutation {
        param($case)
        Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json")
        Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$supersessionEventId-transition.completion.json")
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-supersession-intent' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-supersession-completion' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$supersessionEventId-transition.completion.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-intent-link-mismatch' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.completion.json") { param($c) $c.intent.sha256 = ('3' * 64) }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-completion-target-mismatch' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.completion.json") { param($c) $c.state_sha256 = ('4' * 64) }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-old-unit-binding-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") {
            param($i)
            $i.supersession.old_unit.document.objective = 'Drifted old-unit binding.'
            $i.supersession.old_unit.sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $i.supersession.old_unit.document
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $supersessionEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-pre-state-identity-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") {
            param($i)
            $i.supersession.pre_state.document.current_unit = 'unrelated-owner'
            $newHash = Get-MorphospaceCanonicalJsonSha256 -Value $i.supersession.pre_state.document
            $i.supersession.pre_state.sha256 = $newHash
            $i.pre.state.sha256 = $newHash
            $i.expected.state_sha256 = $newHash
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $supersessionEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-target-identity-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") { param($i) $i.target.state.document.current_unit = $oldUnitId }
        Rebind-FixtureTransaction -Workspace $case -EventId $supersessionEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-ledger-prefix-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") { param($i) $i.expected.events_sha256 = ('5' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $supersessionEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-target-to-begin-state-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$beginEventId-transition.intent.json") { param($i) $i.pre.state.sha256 = ('6' * 64); $i.expected.state_sha256 = ('6' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $beginEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-target-to-begin-unit-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$beginEventId-transition.intent.json") { param($i) $i.pre.unit.sha256 = ('7' * 64); $i.expected.unit_sha256 = ('7' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $beginEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-begin-intent' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$beginEventId-transition.intent.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-begin-completion' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$beginEventId-transition.completion.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'damaged-begin-intent-link' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$beginEventId-transition.completion.json") { param($c) $c.intent.path = 'receipts/transactions/wrong.intent.json' }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-fail-intent' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-fail-completion' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$failEventId-transition.completion.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'mismatched-fail-event-unit' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.event.unit_id = $oldUnitId }
        $ip = Join-Path $case "receipts\transactions\$failEventId-transition.intent.json"
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.completion.json") { param($c) $c.intent.sha256 = (Get-FileHash $ip -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'completion-target-mismatch' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.completion.json") { param($c) $c.state_sha256 = ('0' * 64) }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'fail-preimage-detached' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.pre.state.sha256 = ('1' * 64); $i.expected.state_sha256 = ('1' * 64) }
        $ip = Join-Path $case "receipts\transactions\$failEventId-transition.intent.json"
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.completion.json") { param($c) $c.intent.sha256 = (Get-FileHash $ip -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    foreach ($substitution in @('pass','blocked')) {
        Assert-HelperRejects -Template $baselineWorkspace -Name "validation-receipt-$substitution-substitution" -Mutation {
            param($case)
            Update-FixtureJson (Join-Path $case "receipts\$replacementUnitId-fail-validation.json") { param($r) $r.result = $substitution }
        }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'validation-receipt-missing' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\$replacementUnitId-fail-validation.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'validation-receipt-wrong-unit' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\$replacementUnitId-fail-validation.json") { param($r) $r.unit_id = $oldUnitId }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-blocker-projection-tamper' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.blockers[0].condition = 'Fabricated condition.' }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-state-tail-tamper' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.last_event_id = $beginEventId }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-current-contradiction' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.current_unit = $replacementUnitId }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-next-ready-contradiction' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.next_ready_unit = $replacementUnitId }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-acceptance-inference' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.last_accepted_receipt = "receipts/$replacementUnitId-fail-validation.json" }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'status-only-reactivation' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "iteration-units\$replacementUnitId.json") { param($u) $u.status = 'active' }
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.current_unit = $replacementUnitId }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'live-state-not-derived' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.next_ready_unit = $oldUnitId }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'damaged-supersession-binding' -Mutation {
        param($case)
        Update-FixtureLedgerEvent -Workspace $case -EventId $supersessionEventId -Mutation { param($e) $e.event_id = "$oldUnitId-superseded-by-unrelated-owner" }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'begin-ledger-prefix-tamper' -Mutation {
        param($case)
        Update-FixtureLedgerEvent -Workspace $case -EventId $supersessionEventId -Mutation { param($e) $e.summary = 'Tampered prefix.' }
    }
    Assert-HelperRejects -Template $laterActiveWorkspace -Name 'later-event-chain-tamper' -Mutation {
        param($case)
        $last = (Get-Content (Join-Path $case 'iteration-events.jsonl') | Where-Object { $_ } | Select-Object -Last 1 | ConvertFrom-Json).event_id
        Update-FixtureLedgerEvent -Workspace $case -EventId $last -Mutation { param($e) $e.summary = 'Tampered later event.' }
    }
    Assert-HelperRejects -Template $laterActiveWorkspace -Name 'later-completion-link-tamper' -Mutation {
        param($case)
        $last = (Get-Content (Join-Path $case 'iteration-events.jsonl') | Where-Object { $_ } | Select-Object -Last 1 | ConvertFrom-Json).event_id
        Update-FixtureJson (Join-Path $case "receipts\transactions\$last-transition.completion.json") { param($c) $c.intent.sha256 = ('2' * 64) }
    }
    Assert-HelperRejects -Template $laterActiveWorkspace -Name 'later-live-projection-tamper' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.current_unit = $null }
    }

    Write-Host "Blocked-supersession terminal validation passed $($assertions.Count) focused assertions."
} finally {
    if ($KeepFixture) {
        Write-Host "Retained fixture: $testRoot"
    } elseif (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove a fixture outside the system temporary directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
