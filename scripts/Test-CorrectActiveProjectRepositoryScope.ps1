param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'CorrectActiveProjectRepositoryScope.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Assert-ProjectScopeTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "CorrectActiveProjectRepositoryScope self-test failed: $Message" }
}

function Assert-ProjectScopeRejected {
    param([scriptblock]$Action,[string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-ProjectScopeTest $rejected $Message
}

function Write-ProjectScopeJson {
    param([string]$Path,[object]$Value)
    $parent = Split-Path $Path -Parent
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 64) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Copy-ProjectScopeValue {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Get-ProjectScopeLockFingerprint {
    param([object]$Lock)
    $copy = Copy-ProjectScopeValue $Lock
    $copy.lock_fingerprint = '0' * 64
    return Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($copy | ConvertTo-Json -Depth 48 -Compress)))
}

function Get-EmptyProjectScopeEffects {
    return [pscustomobject][ordered]@{
        permissions=@();services=@();activities=@();queries=@();tools=@();assets=@();shaders=@()
        native_libraries=@();commands=@();routes=@();streams=@();inputs=@();scenes=@();markers=@()
    }
}

function New-ProjectScopeFixture {
    param([string]$Root,[string]$Suffix='main')
    $workspace = Join-Path $Root "morphospace-$Suffix"
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null
    $project = [pscustomobject][ordered]@{
        '$schema'='https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/project-spec-v2.schema.json'
        schema='rusty.morphospace.workflow.project_spec.v2';project_id='project-scope-test';revision=1
        owner='workflow-self-test';purpose='Exercise bounded active project repository scope correction.'
        activation_model=[pscustomobject][ordered]@{default='disabled';unlisted_modules='inert';runtime_rule='selected-lock-and-runtime-input'}
        composition=[pscustomobject][ordered]@{selected_features=@();denied_features=@();selected_modules=@();denied_modules=@();allowed_permissions=@();denied_permissions=@();data_classes=@('test-data')}
        authority_map=@([pscustomobject][ordered]@{parameter='project.composition';owner='owner-repo';adapters=@()})
        repositories=@([pscustomobject][ordered]@{repo_id='owner-repo';role='application';path='<owner>';allowed_paths=@('src/')})
        modules=@();non_scope=@('No source or device mutation.')
        validation_profiles=@([pscustomobject][ordered]@{profile_id='quick';commands=@('test-command')})
        acceptance_profiles=@([pscustomobject][ordered]@{profile_id='rollback';commands=@('test-command')})
        release_policy=[pscustomobject][ordered]@{versioning='semver';commit_policy='validated slices';push_checkpoint='local-only';source_first=$true;planning_last=$true;force_push_allowed=$false}
        public_boundary=[pscustomobject][ordered]@{mode='public';private_overlay='local/';prohibited_evidence=@('private evidence')}
    }
    $lock = [pscustomobject][ordered]@{
        '$schema'='https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/feature-lock-v2.schema.json'
        schema='rusty.morphospace.workflow.feature_lock.v2';project_id='project-scope-test';project_revision=1;revision=1
        generated_at='2026-08-05T00:00:00Z';resolver_version='rusty-morphospace-feature-resolver/2';lock_fingerprint=('0'*64)
        default_activation='disabled';activation_rule='selected-lock-and-runtime-input';selected_features=@();denied_features=@();features=@();effect_union=(Get-EmptyProjectScopeEffects)
    }
    $lock.lock_fingerprint = Get-ProjectScopeLockFingerprint $lock
    $unit = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id='unit-project-scope-001';project_id='project-scope-test';status='active'
        objective='Add one already-declared unit path to project scope.';change_categories=@('workflow-automation')
        instruction_impact='none';instruction_surfaces=@();instruction_none_justification='No instruction surface changes in the fixture.'
        prerequisites=@();allowed_repositories=@([pscustomobject][ordered]@{repo_id='owner-repo';allowed_paths=@('AGENTS.md','src/')})
        read_only_dependencies=@();non_scope=@('Source mutation.');acceptance=@([pscustomobject][ordered]@{acceptance_id='bounded-scope';proof='Only exact unit-declared scope is added.';command='test-command'})
        risk_tier='quick';device_requirement='forbidden';validation=@([pscustomobject][ordered]@{profile_id='quick';command='test-command'})
        outputs=@('Transactional correction receipt.');commit_policy='Commit after validation.';push_checkpoint='local-only'
    }
    $eventId = 'unit-project-scope-001-claimed-0001'
    $state = [pscustomobject][ordered]@{
        '$schema'='https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/workspace-state-v2.schema.json'
        schema='rusty.morphospace.workflow.workspace_state.v2';project_id='project-scope-test';plan_revision=1
        current_unit='unit-project-scope-001';next_ready_unit=$null;last_event_id=$eventId;last_accepted_receipt=$null
        repository_heads=@();module_registry=[pscustomobject][ordered]@{lock_revision=1;lock_fingerprint=[string]$lock.lock_fingerprint;modules=@()}
        capability_registry=@();dirty_repositories=@('owner-repo');blockers=@();validation_checkpoint=$null;pending_push_bundle=$null
    }
    $event = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=1;timestamp='2026-08-05T00:00:00Z'
        project_id='project-scope-test';unit_id='unit-project-scope-001';event_type='state-transition';summary='Claimed the bounded project-scope test unit.';receipts=@()
    }
    $paths = [pscustomobject]@{
        workspace=$workspace
        project=(Join-Path $workspace 'project.spec.json')
        lock=(Join-Path $workspace 'feature.lock.json')
        state=(Join-Path $workspace 'workspace.state.json')
        unit=(Join-Path $workspace 'iteration-units\unit-project-scope-001.json')
        events=(Join-Path $workspace 'iteration-events.jsonl')
        out=(Join-Path $workspace 'receipts\unit-project-scope-001-project-scope.json')
    }
    Write-ProjectScopeJson $paths.project $project
    Write-ProjectScopeJson $paths.lock $lock
    Write-ProjectScopeJson $paths.state $state
    Write-ProjectScopeJson $paths.unit $unit
    [IO.File]::WriteAllText($paths.events, (($event | ConvertTo-Json -Depth 32 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $correction = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.active_project_repository_scope_correction.v1'
        correction_id='unit-project-scope-001-project-scope';project_id='project-scope-test';unit_id='unit-project-scope-001';repository_id='owner-repo'
        reason='Admit exactly the root instruction file already declared by the active unit.'
        expected=[pscustomobject][ordered]@{
            status='active';current_unit='unit-project-scope-001';project_revision=1;feature_lock_revision=1;plan_revision=1
            project_sha256=(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $paths.project))
            feature_lock_sha256=(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $paths.lock))
            state_sha256=(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $paths.state))
            unit_sha256=(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $paths.unit))
            events_sha256=(Get-MorphospaceFileSha256 $paths.events);events_length=[IO.FileInfo]::new($paths.events).Length;event_tail_id=$eventId
        }
        before_allowed_paths=@('src/');after_allowed_paths=@('AGENTS.md','src/')
        does_not_prove=@('Does not change source, execute validation, or authorize publication.')
    }
    $correctionPath = Join-Path $Root "correction-$Suffix.json"
    Write-ProjectScopeJson $correctionPath $correction
    return [pscustomobject]@{paths=$paths;correction=$correction;correction_path=$correctionPath}
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("workenv-project-scope-correction-" + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $fixture = New-ProjectScopeFixture $temp
    $paths = $fixture.paths
    $before = @{}
    foreach ($name in @('project','lock','state','unit','events')) { $before[$name] = [IO.File]::ReadAllBytes([string]$paths.$name) }

    $dry = Invoke-MorphospaceCorrectActiveProjectRepositoryScope -WorkspaceRoot $paths.workspace -UnitId 'unit-project-scope-001' `
        -ProjectRepositoryScopeCorrection $fixture.correction_path -OutPath $paths.out -Timestamp '2026-08-05T01:00:00.0000000Z'
    Assert-ProjectScopeTest (-not $dry.executed -and $null -eq $dry.event_id) 'dry run did not report a non-executed plan'
    foreach ($name in @('project','lock','state','unit','events')) {
        Assert-ProjectScopeTest ((Get-MorphospaceSha256Bytes $before[$name]) -ceq (Get-MorphospaceFileSha256 ([string]$paths.$name))) "dry run changed $name bytes"
    }
    Assert-ProjectScopeTest (-not [IO.File]::Exists($paths.out)) 'dry run created the correction receipt'

    $wrapperDry = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action CorrectActiveProjectRepositoryScope `
        -WorkspaceRoot $paths.workspace -UnitId 'unit-project-scope-001' -ProjectRepositoryScopeCorrection $fixture.correction_path `
        -OutPath $paths.out -Timestamp '2026-08-05T01:00:00.0000000Z' | ConvertFrom-Json
    Assert-ProjectScopeTest ([string]$wrapperDry.action -ceq 'CorrectActiveProjectRepositoryScope') 'public action router did not dispatch the correction'
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

    $badCas = Copy-ProjectScopeValue $fixture.correction
    $badCas.expected.project_sha256 = '0' * 64
    $badCasPath = Join-Path $temp 'bad-cas.json'; Write-ProjectScopeJson $badCasPath $badCas
    Assert-ProjectScopeRejected {
        Invoke-MorphospaceCorrectActiveProjectRepositoryScope -WorkspaceRoot $paths.workspace -UnitId 'unit-project-scope-001' -ProjectRepositoryScopeCorrection $badCasPath -OutPath $paths.out
    } 'stale project CAS was accepted'

    $outsideUnit = Copy-ProjectScopeValue $fixture.correction
    $outsideUnit.after_allowed_paths = @('AGENTS.md','docs/','src/')
    $outsideUnitPath = Join-Path $temp 'outside-unit.json'; Write-ProjectScopeJson $outsideUnitPath $outsideUnit
    Assert-ProjectScopeRejected {
        Invoke-MorphospaceCorrectActiveProjectRepositoryScope -WorkspaceRoot $paths.workspace -UnitId 'unit-project-scope-001' -ProjectRepositoryScopeCorrection $outsideUnitPath -OutPath $paths.out
    } 'path outside exact active-unit declarations was accepted'

    $removal = Copy-ProjectScopeValue $fixture.correction
    $removal.before_allowed_paths = @('AGENTS.md','src/')
    $removal.after_allowed_paths = @('AGENTS.md','other/')
    $removalPath = Join-Path $temp 'removal.json'; Write-ProjectScopeJson $removalPath $removal
    Assert-ProjectScopeRejected {
        Invoke-MorphospaceCorrectActiveProjectRepositoryScope -WorkspaceRoot $paths.workspace -UnitId 'unit-project-scope-001' -ProjectRepositoryScopeCorrection $removalPath -OutPath $paths.out
    } 'nonmatching/removing before scope was accepted'

    $correctionHash = Get-MorphospaceFileSha256 $fixture.correction_path
    Assert-ProjectScopeRejected {
        Invoke-MorphospaceCorrectActiveProjectRepositoryScope -WorkspaceRoot $paths.workspace -UnitId 'unit-project-scope-001' `
            -ProjectRepositoryScopeCorrection $fixture.correction_path -OutPath $paths.out -Execute
    } 'execute without dry-run input hash was accepted'

    $executed = Invoke-MorphospaceCorrectActiveProjectRepositoryScope -WorkspaceRoot $paths.workspace -UnitId 'unit-project-scope-001' `
        -ProjectRepositoryScopeCorrection $fixture.correction_path -ExpectedProjectRepositoryScopeCorrectionSha256 $correctionHash `
        -OutPath $paths.out -Timestamp '2026-08-05T01:00:00.0000000Z' -Execute
    Assert-ProjectScopeTest ($executed.executed -and [string]$executed.event_id -ceq 'unit-project-scope-001-project-scope-recorded') 'execute receipt is incomplete'
    $afterProject = Read-MorphospaceProtocolJson $paths.project
    $afterLock = Read-MorphospaceProtocolJson $paths.lock
    $afterState = Read-MorphospaceProtocolJson $paths.state
    Assert-ProjectScopeTest ([int]$afterProject.revision -eq 2 -and (@($afterProject.repositories[0].allowed_paths) -join '|') -ceq 'AGENTS.md|src/') 'project scope/revision target is wrong'
    $recomputedLockFingerprint = Get-ProjectScopeLockFingerprint $afterLock
    Assert-ProjectScopeTest ([int]$afterLock.project_revision -eq 2 -and [int]$afterLock.revision -eq 2 -and [string]$afterLock.lock_fingerprint -ceq $recomputedLockFingerprint) "feature lock target is wrong (project_revision=$([int]$afterLock.project_revision), revision=$([int]$afterLock.revision), actual=$([string]$afterLock.lock_fingerprint), recomputed=$recomputedLockFingerprint)"
    Assert-ProjectScopeTest ([int]$afterState.plan_revision -eq 2 -and [int]$afterState.module_registry.lock_revision -eq 2 -and [string]$afterState.module_registry.lock_fingerprint -ceq [string]$afterLock.lock_fingerprint) 'state/lock synchronization is wrong'
    Assert-ProjectScopeTest ((Get-MorphospaceSha256Bytes $before.unit) -ceq (Get-MorphospaceFileSha256 $paths.unit)) 'execute changed unit bytes'
    Assert-ProjectScopeTest ((Get-MorphospaceFileSha256 $paths.out) -ceq $correctionHash) 'transaction did not install the exact correction input'
    $intentPath = Join-Path $paths.workspace 'receipts\transactions\unit-project-scope-001-project-scope-recorded-transition.intent.json'
    $completionPath = Join-Path $paths.workspace 'receipts\transactions\unit-project-scope-001-project-scope-recorded-transition.completion.json'
    $intent = Read-MorphospaceProtocolJson $intentPath
    Assert-ProjectScopeTest ([string]$intent.schema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v3' -and @($intent.additional_projections).Count -eq 2) 'transaction did not bind both additional projections in v3'
    Assert-ProjectScopeTest ([IO.File]::Exists($completionPath)) 'transaction completion is missing'

    $race = New-ProjectScopeFixture $temp 'race'
    $raceHook = {
        $mutated = Read-MorphospaceProtocolJson $race.paths.project
        $mutated.purpose = 'Concurrent mutation.'
        Write-ProjectScopeJson $race.paths.project $mutated
    }.GetNewClosure()
    Assert-ProjectScopeRejected {
        Invoke-MorphospaceCorrectActiveProjectRepositoryScope -WorkspaceRoot $race.paths.workspace -UnitId 'unit-project-scope-001' `
            -ProjectRepositoryScopeCorrection $race.correction_path -ExpectedProjectRepositoryScopeCorrectionSha256 (Get-MorphospaceFileSha256 $race.correction_path) `
            -OutPath $race.paths.out -Timestamp '2026-08-05T01:00:00.0000000Z' -BeforeTransitionHook $raceHook -Execute
    } 'mutex-protected project CAS race was accepted'

    [pscustomobject]@{result='pass';action='CorrectActiveProjectRepositoryScope';transactional=$true;git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false} | ConvertTo-Json -Compress
} finally {
    if ([IO.Directory]::Exists($temp)) {
        foreach ($file in [IO.Directory]::EnumerateFiles($temp,'*',[IO.SearchOption]::AllDirectories)) {
            try { [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal) } catch {}
        }
        [IO.Directory]::Delete($temp,$true)
    }
}
