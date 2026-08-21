param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'CorrectActiveUnitContract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Assert-ActiveUnitContractTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "CorrectActiveUnitContract self-test failed: $Message" }
}

function Assert-ActiveUnitContractRejected {
    param([scriptblock]$Action,[string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-ActiveUnitContractTest $rejected $Message
}

function Copy-ActiveUnitContractTestDocument {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Get-ActiveUnitContractTestBytesSha256 {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-ActiveUnitContractTestFileSha256 {
    param([string]$Path)
    return Get-ActiveUnitContractTestBytesSha256 ([IO.File]::ReadAllBytes($Path))
}

function Read-ActiveUnitContractTestJson {
    param([string]$Path)
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Write-ActiveUnitContractTestJson {
    param([string]$Path,[object]$Value)
    $parent = Split-Path $Path -Parent
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 64) + "`n"), [Text.UTF8Encoding]::new($false))
}

function New-ActiveUnitContractTestSurface {
    param([string]$SkillId)
    $path = "<skills-root>/$SkillId/SKILL.md"
    [pscustomobject][ordered]@{
        surface_kind = 'skill'; path = $path; owner = 'workflow-maintainer'
        change_reason = 'Correct the current active-unit contract without claiming an instruction update.'
        action = 'review-no-change'; status = 'planned'
        validation = 'CompleteInstructionSurfaces must observe and complete this declared surface separately.'
        skill_id = $SkillId
    }
}

function Update-ActiveUnitContractTestExpected {
    param([object]$Correction,[string]$ProjectPath,[string]$StatePath,[string]$UnitPath,[string]$EventsPath)
    $project = Read-ActiveUnitContractTestJson $ProjectPath
    $state = Read-ActiveUnitContractTestJson $StatePath
    $unit = Read-ActiveUnitContractTestJson $UnitPath
    $events = @(Get-Content -LiteralPath $EventsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    $Correction.expected.project_revision = [int]$project.revision
    $Correction.expected.project_sha256 = Get-MorphospaceCanonicalJsonSha256 $project
    $Correction.expected.status = [string]$unit.status
    $Correction.expected.current_unit = [string]$state.current_unit
    $Correction.expected.state_sha256 = Get-MorphospaceCanonicalJsonSha256 $state
    $Correction.expected.unit_raw_sha256 = Get-ActiveUnitContractTestFileSha256 $UnitPath
    $Correction.expected.unit_sha256 = Get-MorphospaceCanonicalJsonSha256 $unit
    $Correction.expected.events_sha256 = Get-ActiveUnitContractTestFileSha256 $EventsPath
    $Correction.expected.events_length = [IO.FileInfo]::new($EventsPath).Length
    $Correction.expected.event_tail_id = [string]$events[-1].event_id
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("workenv-active-unit-contract-" + [guid]::NewGuid().ToString('N'))
try {
    $workspace = Join-Path $temp 'morphospace'
    $ownerRoot = Join-Path $temp 'owner'
    $skillsRoot = Join-Path $temp 'skills'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null
    [IO.Directory]::CreateDirectory($ownerRoot) | Out-Null
    foreach ($skillId in @('rusty-morphospace','system-engineering')) {
        $skillDirectory = Join-Path $skillsRoot $skillId
        [IO.Directory]::CreateDirectory($skillDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $skillDirectory 'SKILL.md'), "# $skillId`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $ownerRoot 'AGENTS.md'), "# Fixture Agent Notes`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $ownerRoot 'README.md'), "# Fixture Router`n", [Text.UTF8Encoding]::new($false))

    $project = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.project_spec.v2';project_id='morphovision-unit058';revision=58;owner='fixture-owner'
        purpose='Exercise exact active-unit contract correction without product mutation.'
        activation_model=[pscustomobject]@{default='disabled';unlisted_modules='inert';runtime_rule='selected-lock-and-runtime-input'}
        composition=[pscustomobject]@{selected_features=@();denied_features=@();selected_modules=@();denied_modules=@();allowed_permissions=@();denied_permissions=@();data_classes=@()}
        authority_map=@([pscustomobject]@{parameter='project.composition';owner='fixture-owner';adapters=@()})
        repositories=@([pscustomobject]@{repo_id='project-shell';role='application';path='<repo-root>';allowed_paths=@('src/','morphospace/')})
        modules=@();non_scope=@('No product, device, or remote mutation.')
        validation_profiles=@([pscustomobject]@{profile_id='quick';commands=@('fixture-validation')})
        acceptance_profiles=@([pscustomobject]@{profile_id='fixture-acceptance';commands=@('fixture-acceptance')})
        release_policy=[pscustomobject]@{versioning='private-revision';commit_policy='Fixture only.';push_checkpoint='none';source_first=$true;planning_last=$true;force_push_allowed=$false}
        public_boundary=[pscustomobject]@{mode='public';private_overlay='local/';prohibited_evidence=@('private evidence')}
    }
    $legacyDecision = 'Keep Morphovision Unit058 in its existing host-only validation lane.'
    $unit = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id='unit058';project_id='morphovision-unit058';status='active'
        objective='Resume the frozen current feature unit only after its legacy contract shape is corrected.'
        architecture_decision=$legacyDecision;work_mode='feature';guard_profile='locked';change_categories=@('implementation','authority','validation','public-private-boundary')
        instruction_impact='update'
        instruction_surfaces=@(
            [pscustomobject][ordered]@{surface_kind='agents';path='<repo-root>/AGENTS.md';owner='fixture-owner';change_reason='Retain the required active-unit instruction entrypoint.';action='update';status='complete';validation='Fixture content observation.';skill_id=$null},
            [pscustomobject][ordered]@{surface_kind='readme';path='<repo-root>/README.md';owner='fixture-owner';change_reason='Retain the required active-unit router.';action='update';status='complete';validation='Fixture content observation.';skill_id=$null}
        )
        instruction_none_justification=$null;prerequisites=@();allowed_repositories=@([pscustomobject]@{repo_id='project-shell';allowed_paths=@('src/','morphospace/')})
        non_scope=@('Product source changes.','Device operations.','Remote operations.')
        acceptance=@([pscustomobject]@{acceptance_id='fixture-contract';proof='The active-unit contract is corrected without scope expansion.';command='fixture-acceptance'})
        risk_tier='quick';device_requirement='forbidden';validation=@([pscustomobject]@{profile_id='quick';command='fixture-validation'})
        outputs=@('One transaction-owned correction receipt.');commit_policy='No source commit is made by this correction.';push_checkpoint='none'
        claim_requirements=[pscustomobject]@{minimum_free_disk_mib=0;required_tools=@();product_inputs=@()}
    }
    $eventId = 'unit058-claimed-0001'
    $state = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.workspace_state.v2';project_id='morphovision-unit058';plan_revision=58
        current_unit='unit058';next_ready_unit=$null;last_event_id=$eventId;last_accepted_receipt=$null
        repository_heads=@();repository_checkpoints=@();module_registry=[pscustomobject]@{lock_revision=$null;lock_fingerprint=$null;modules=@()}
        capability_registry=@();dirty_repositories=@();blockers=@();validation_checkpoint=$null;pending_push_bundle=$null
    }
    $event = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=1;timestamp='2026-08-21T00:00:00Z';project_id='morphovision-unit058';unit_id='unit058';event_type='state-transition';summary='Claimed the exact fixture feature unit.';receipts=@()}
    $projectPath = Join-Path $workspace 'project.spec.json'
    $featureLockPath = Join-Path $workspace 'feature.lock.json'
    $statePath = Join-Path $workspace 'workspace.state.json'
    $unitPath = Join-Path $workspace 'iteration-units\unit058.json'
    $eventsPath = Join-Path $workspace 'iteration-events.jsonl'
    Write-ActiveUnitContractTestJson $projectPath $project
    $featureLock = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.feature_lock.v1';project_id='morphovision-unit058';revision=58
        default_activation='disabled';features=@()
    }
    Write-ActiveUnitContractTestJson $featureLockPath $featureLock
    Write-ActiveUnitContractTestJson $statePath $state
    Write-ActiveUnitContractTestJson $unitPath $unit
    [IO.File]::WriteAllText($eventsPath, (($event | ConvertTo-Json -Depth 32 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))

    $correction = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.active_unit_contract_correction.v1';correction_id='unit058-contract';project_id='morphovision-unit058';unit_id='unit058'
        reason='Correct the exact legacy active-unit shape without changing product scope or instruction completion.'
        expected=[pscustomobject][ordered]@{project_revision=1;project_sha256='0'*64;status='active';current_unit='unit058';state_sha256='0'*64;unit_raw_sha256='0'*64;unit_sha256='0'*64;events_sha256='0'*64;events_length=1;event_tail_id=$eventId}
        architecture_decision=[pscustomobject][ordered]@{
            selected=$legacyDecision
            material_advance='Correct only the active workflow contract so its ordinary validation can resume.'
            deferred='Source, build, device, validation, and publication execution remain separate owner actions.'
            deferred_reason='This transaction records no execution or completion claim.'
        }
        required_skill_surfaces=@((New-ActiveUnitContractTestSurface 'rusty-morphospace'),(New-ActiveUnitContractTestSurface 'system-engineering'))
        does_not_prove=@('Does not mutate source or Git state, execute validation, touch a device, contact a remote, or authorize acceptance or publication.')
    }
    Update-ActiveUnitContractTestExpected $correction $projectPath $statePath $unitPath $eventsPath
    $correctionPath = Join-Path $temp 'unit058-contract.json'
    $outPath = Join-Path $workspace 'receipts\unit058-contract.json'
    Write-ActiveUnitContractTestJson $correctionPath $correction
    Assert-ActiveUnitContractTest (Get-Content -Raw -LiteralPath $correctionPath | Test-Json -SchemaFile (Join-Path $repoRoot 'schemas\active-unit-contract-correction-v1.schema.json')) 'correction fixture does not satisfy its schema'
    foreach ($requiredPath in @(
        'docs\ACTIVE_UNIT_CONTRACT_CORRECTION.md',
        'docs\AUTONOMOUS_ITERATION.md',
        'templates\active-unit-contract-correction.example.json',
        'schemas\active-unit-contract-correction-v1.schema.json',
        'scripts\CorrectActiveUnitContract.psm1',
        'skills\rusty-morphospace\references\project-workflow.md',
        'skills\system-engineering\SKILL.md',
        'skills\rust-work-graph\SKILL.md'
    )) { Assert-ActiveUnitContractTest ([IO.File]::Exists((Join-Path $repoRoot $requiredPath))) "required correction surface is absent: $requiredPath" }
    Assert-ActiveUnitContractTest ((Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts\Invoke-WorkUnitAutomation.ps1')) -match 'CorrectActiveUnitContract') 'public action router does not declare the correction'
    Assert-ActiveUnitContractTest ((Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts\Test-WorkEnvironment.ps1')) -match 'Test-CorrectActiveUnitContract\.ps1') 'Quick aggregate does not include the correction self-test'
    $resultSchema = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json') | ConvertFrom-Json
    Assert-ActiveUnitContractTest (@($resultSchema.properties.action.enum) -contains 'CorrectActiveUnitContract' -and @($resultSchema.properties.transition.enum) -contains 'active-unit-contract-corrected') 'automation result enum does not cover the correction'

    Assert-ActiveUnitContractRejected {
        & (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -RepoRoot $repoRoot -WorkspaceRoot $workspace -CurrentUnitInstructionOnly
    } 'the exact Unit058 legacy string plus absent required-skill shape unexpectedly passed current-unit validation'

    $stateBytes = [IO.File]::ReadAllBytes($statePath)
    $unitBytes = [IO.File]::ReadAllBytes($unitPath)
    $eventsBytes = [IO.File]::ReadAllBytes($eventsPath)
    $dry = Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $correctionPath -OutPath $outPath -Timestamp '2026-08-21T01:00:00.0000000Z'
    Assert-ActiveUnitContractTest (-not $dry.executed -and $null -eq $dry.event_id -and [string]$dry.action -ceq 'CorrectActiveUnitContract') 'dry run did not return the bounded non-executed result'
    Assert-ActiveUnitContractTest ((Get-ActiveUnitContractTestBytesSha256 $stateBytes) -ceq (Get-ActiveUnitContractTestFileSha256 $statePath) -and (Get-ActiveUnitContractTestBytesSha256 $unitBytes) -ceq (Get-ActiveUnitContractTestFileSha256 $unitPath) -and (Get-ActiveUnitContractTestBytesSha256 $eventsBytes) -ceq (Get-ActiveUnitContractTestFileSha256 $eventsPath)) 'dry run mutated a workspace input'
    Assert-ActiveUnitContractTest (-not [IO.File]::Exists($outPath)) 'dry run created a correction receipt'
    $routerDry = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action CorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $correctionPath -OutPath $outPath -Timestamp '2026-08-21T01:00:00.0000000Z' | ConvertFrom-Json
    Assert-ActiveUnitContractTest ([string]$routerDry.action -ceq 'CorrectActiveUnitContract') 'public action router did not dispatch the correction'

    $wrongSelected = Copy-ActiveUnitContractTestDocument $correction; $wrongSelected.architecture_decision.selected = 'rewritten legacy decision'
    $wrongSelectedPath = Join-Path $temp 'wrong-selected.json'; Write-ActiveUnitContractTestJson $wrongSelectedPath $wrongSelected
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $wrongSelectedPath -OutPath $outPath } 'legacy selected architecture text was rewritten'
    $missingArchitectureField = Copy-ActiveUnitContractTestDocument $correction; $missingArchitectureField.architecture_decision.PSObject.Properties.Remove('deferred_reason')
    $missingArchitecturePath = Join-Path $temp 'missing-architecture.json'; Write-ActiveUnitContractTestJson $missingArchitecturePath $missingArchitectureField
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $missingArchitecturePath -OutPath $outPath } 'missing architecture field was accepted'
    $extraSkill = Copy-ActiveUnitContractTestDocument $correction; $extraSkill.required_skill_surfaces += (New-ActiveUnitContractTestSurface 'rusty-morphospace')
    $extraSkillPath = Join-Path $temp 'extra-skill.json'; Write-ActiveUnitContractTestJson $extraSkillPath $extraSkill
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $extraSkillPath -OutPath $outPath } 'extra or duplicate correction skill surface was accepted'
    $nonRequiredSkill = Copy-ActiveUnitContractTestDocument $correction
    $nonRequiredSurface = New-ActiveUnitContractTestSurface 'rusty-morphospace'
    $nonRequiredSurface.skill_id = 'rust-work-graph'; $nonRequiredSurface.path = '<skills-root>/rust-work-graph/SKILL.md'
    $nonRequiredSkill.required_skill_surfaces += $nonRequiredSurface
    $nonRequiredSkillPath = Join-Path $temp 'non-required-skill.json'; Write-ActiveUnitContractTestJson $nonRequiredSkillPath $nonRequiredSkill
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $nonRequiredSkillPath -OutPath $outPath } 'non-required correction skill surface was accepted'
    $completedSkill = Copy-ActiveUnitContractTestDocument $correction; $completedSkill.required_skill_surfaces[0].status = 'complete'
    $completedSkillPath = Join-Path $temp 'completed-skill.json'; Write-ActiveUnitContractTestJson $completedSkillPath $completedSkill
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $completedSkillPath -OutPath $outPath } 'falsely completed skill surface was accepted'
    $wrongUnit = Copy-ActiveUnitContractTestDocument $correction; $wrongUnit.unit_id = 'other-unit'
    $wrongUnitPath = Join-Path $temp 'wrong-unit.json'; Write-ActiveUnitContractTestJson $wrongUnitPath $wrongUnit
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $wrongUnitPath -OutPath $outPath } 'wrong correction unit identity was accepted'
    $staleState = Copy-ActiveUnitContractTestDocument $correction; $staleState.expected.state_sha256 = '0' * 64
    $staleStatePath = Join-Path $temp 'stale-state.json'; Write-ActiveUnitContractTestJson $staleStatePath $staleState
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $staleStatePath -OutPath $outPath } 'stale state CAS was accepted'
    $writableSkillUnit = Copy-ActiveUnitContractTestDocument $unit
    $writableSkillUnit.allowed_repositories[0].allowed_paths += '<skills-root>/rusty-morphospace/'
    Write-ActiveUnitContractTestJson $unitPath $writableSkillUnit
    $writableSkillCorrection = Copy-ActiveUnitContractTestDocument $correction
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
    Update-ActiveUnitContractTestExpected $writableSkillCorrection $projectPath $statePath $unitPath $eventsPath
    $writableSkillPath = Join-Path $temp 'writable-skill.json'; Write-ActiveUnitContractTestJson $writableSkillPath $writableSkillCorrection
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $writableSkillPath -OutPath $outPath } 'writable correction skill path was accepted'
    Write-ActiveUnitContractTestJson $unitPath $unit
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $correctionPath -OutPath $outPath -Execute } 'execute without a caller-pinned dry-run hash was accepted'

    $correctionHash = Get-ActiveUnitContractTestFileSha256 $correctionPath
    $rawCasRejected = $false
    try {
        Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $correctionPath -OutPath $outPath -ExpectedActiveUnitContractCorrectionSha256 $correctionHash -Execute -BeforeTransitionHook {
            $sameDocument = Get-Content -Raw -LiteralPath $unitPath | ConvertFrom-Json
            [IO.File]::WriteAllText($unitPath, ($sameDocument | ConvertTo-Json -Depth 64 -Compress), [Text.UTF8Encoding]::new($false))
        } | Out-Null
    } catch { $rawCasRejected = $_.Exception.Message -like '*raw SHA-256*' }
    Assert-ActiveUnitContractTest $rawCasRejected 'mutex-protected raw-unit CAS did not reject canonical-equivalent byte drift'
    [IO.File]::WriteAllBytes($unitPath, $unitBytes)

    $executed = Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $correctionPath -OutPath $outPath -ExpectedActiveUnitContractCorrectionSha256 $correctionHash -Timestamp '2026-08-21T01:00:00.0000000Z' -Execute
    Assert-ActiveUnitContractTest ($executed.executed -and [string]$executed.event_id -ceq 'unit058-contract-recorded') 'execute did not return the bounded correction receipt'
    Assert-ActiveUnitContractTest (($executed | ConvertTo-Json -Depth 64 | Test-Json -SchemaFile (Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'))) 'result enum does not admit the correction action'
    $afterUnit = Read-ActiveUnitContractTestJson $unitPath
    $afterState = Read-ActiveUnitContractTestJson $statePath
    Assert-ActiveUnitContractTest ([string]$afterUnit.architecture_decision.selected -ceq $legacyDecision -and [string]$afterUnit.architecture_decision.material_advance -eq [string]$correction.architecture_decision.material_advance) 'architecture decision was not corrected exactly'
    $afterSkills = @($afterUnit.instruction_surfaces | Where-Object { [string]$_.surface_kind -ceq 'skill' })
    Assert-ActiveUnitContractTest (($afterSkills.skill_id -join '|') -ceq 'rusty-morphospace|system-engineering' -and @($afterSkills | Where-Object { [string]$_.action -cne 'review-no-change' -or [string]$_.status -cne 'planned' }).Count -eq 0) 'fixed planned skill surfaces were not added exactly'
    # The action imports this dependency into its private module scope. Restore
    # the test's public helper before canonical post-transaction comparisons.
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
    $restoredUnit = Copy-ActiveUnitContractTestDocument $afterUnit; $restoredUnit.architecture_decision = $legacyDecision; $restoredUnit.instruction_surfaces = @($unit.instruction_surfaces)
    Assert-ActiveUnitContractTest ((Get-MorphospaceCanonicalJsonSha256 $restoredUnit) -ceq (Get-MorphospaceCanonicalJsonSha256 $unit)) 'execute changed a unit field outside the admitted correction'
    $restoredState = Copy-ActiveUnitContractTestDocument $afterState; $restoredState.last_event_id = $state.last_event_id
    Assert-ActiveUnitContractTest ((Get-MorphospaceCanonicalJsonSha256 $restoredState) -ceq (Get-MorphospaceCanonicalJsonSha256 $state)) 'execute changed workspace state beyond last_event_id'
    Assert-ActiveUnitContractTest ((Get-ActiveUnitContractTestFileSha256 $outPath) -ceq $correctionHash) 'transaction did not install the exact correction input as receipt'
    Assert-ActiveUnitContractTest ([IO.File]::Exists((Join-Path $workspace 'receipts\transactions\unit058-contract-recorded-transition.intent.json')) -and [IO.File]::Exists((Join-Path $workspace 'receipts\transactions\unit058-contract-recorded-transition.completion.json'))) 'atomic intent or completion projection is missing'
    Assert-ActiveUnitContractTest (([IO.File]::ReadAllBytes($eventsPath)[0..($eventsBytes.Length - 1)] -join ',') -ceq ($eventsBytes -join ',')) 'existing ledger prefix was rewritten'

    & (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -RepoRoot $repoRoot -WorkspaceRoot $workspace -CurrentUnitInstructionOnly
    $repoMap = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@(
        [pscustomobject]@{repo_id='project-shell';path=$ownerRoot;role='planning';aliases=@('repo-root')},
        [pscustomobject]@{repo_id='skill-surfaces';path=$skillsRoot;role='source';aliases=@('skills-root')}
    )}
    $repoMapPath = Join-Path $temp 'repository-map.json'; Write-ActiveUnitContractTestJson $repoMapPath $repoMap
    $completionPlan = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action CompleteInstructionSurfaces -WorkspaceRoot $workspace -UnitId 'unit058' -RepoMapPath $repoMapPath -InstructionCompletionId 'unit058-instruction-completion' | ConvertFrom-Json
    Assert-ActiveUnitContractTest (@($completionPlan.instruction_surface_completion.surfaces).Count -eq 2 -and @($completionPlan.instruction_surface_completion.surfaces | Where-Object { [string]$_.skill_id -in @('rusty-morphospace','system-engineering') }).Count -eq 2) 'existing CompleteInstructionSurfaces cannot observe the corrected planned skill records'
    Assert-ActiveUnitContractRejected { Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $workspace -UnitId 'unit058' -ActiveUnitContractCorrection $correctionPath -OutPath $outPath } 'replay or occupied correction output was accepted'

    [pscustomobject]@{result='pass';action='CorrectActiveUnitContract';transactional=$true;git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false} | ConvertTo-Json -Compress
} finally {
    if ([IO.Directory]::Exists($temp)) {
        foreach ($file in [IO.Directory]::EnumerateFiles($temp,'*',[IO.SearchOption]::AllDirectories)) { try { [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal) } catch {} }
        [IO.Directory]::Delete($temp,$true)
    }
}
