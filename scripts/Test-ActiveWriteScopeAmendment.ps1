param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'ActiveWriteScopeAmendment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
$iterationUnitSchema = Join-Path $repoRoot 'schemas\iteration-unit.schema.json'
$projectSpecSchema = Join-Path $repoRoot 'schemas\project-spec-v2.schema.json'

function Assert-WriteScopeTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "AmendActiveWriteScope self-test failed: $Message" }
}

function Assert-WriteScopeRejected {
    param([scriptblock]$Action,[string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-WriteScopeTest $rejected $Message
}

function Assert-IterationUnitSchema {
    param([object]$Unit,[bool]$Expected,[string]$Message)
    $valid = Test-Json -Json ($Unit | ConvertTo-Json -Depth 64) -SchemaFile $iterationUnitSchema -ErrorAction SilentlyContinue
    Assert-WriteScopeTest ($valid -eq $Expected) $Message
}

function Assert-ProjectSpecSchema {
    param([object]$Project,[bool]$Expected,[string]$Message)
    $valid = Test-Json -Json ($Project | ConvertTo-Json -Depth 64) -SchemaFile $projectSpecSchema -ErrorAction SilentlyContinue
    Assert-WriteScopeTest ($valid -eq $Expected) $Message
}

function Write-WriteScopeJson {
    param([string]$Path,[object]$Value)
    $parent = Split-Path $Path -Parent
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 64) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Copy-WriteScopeValue {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function New-WriteScopeFixture {
    param(
        [string]$Root,
        [string]$Suffix='main',
        [switch]$AddRepository,
        [switch]$WithoutArchitectureDecision,
        [switch]$UpdateInstructionImpact
    )
    $workspace = Join-Path $Root "morphospace-$Suffix"
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null
    $project = [pscustomobject][ordered]@{
        '$schema'='https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/project-spec-v2.schema.json'
        schema='rusty.morphospace.workflow.project_spec.v2';project_id='write-scope-test';revision=1
        owner='workflow-self-test';purpose='Exercise additive active feature-unit write-scope amendments.'
        activation_model=[pscustomobject][ordered]@{default='disabled';unlisted_modules='inert';runtime_rule='selected-lock-and-runtime-input'}
        composition=[pscustomobject][ordered]@{selected_features=@();denied_features=@();selected_modules=@();denied_modules=@();allowed_permissions=@();denied_permissions=@();data_classes=@('test-data')}
        authority_map=@([pscustomobject][ordered]@{parameter='project.composition';owner='owner-repo';adapters=@()})
        repositories=@(
            [pscustomobject][ordered]@{repo_id='owner-repo';role='application';path='<owner>';allowed_paths=@('docs/','src/')},
            [pscustomobject][ordered]@{repo_id='aux-repo';role='platform-test-harness';path='<aux>';allowed_paths=@('crates/')}
        )
        modules=@();non_scope=@('No source, Git, device, build, validation, or remote mutation.')
        validation_profiles=@([pscustomobject][ordered]@{profile_id='quick';commands=@('test-command')})
        acceptance_profiles=@([pscustomobject][ordered]@{profile_id='rollback';commands=@('test-command')})
        release_policy=[pscustomobject][ordered]@{versioning='semver';commit_policy='validated slices';push_checkpoint='manual-owner-review';source_first=$true;planning_last=$true;force_push_allowed=$false}
        public_boundary=[pscustomobject][ordered]@{mode='public';private_overlay='local/';prohibited_evidence=@('private evidence')}
    }
    $unit = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id='unit-write-scope-001';project_id='write-scope-test';status='active'
        objective='Continue one bounded implementation after discovering another project-approved path.';guard_profile='fast';change_categories=@('implementation')
        instruction_impact='none';instruction_surfaces=@();instruction_none_justification='The fixture does not change instruction surfaces.'
        prerequisites=@();allowed_repositories=@([pscustomobject][ordered]@{repo_id='owner-repo';allowed_paths=@('src/')})
        read_only_dependencies=@();non_scope=@('Any work outside declared project repositories.');acceptance=@([pscustomobject][ordered]@{acceptance_id='bounded-amendment';proof='Only project-approved paths are added.';command='test-command'})
        risk_tier='quick';device_requirement='forbidden';validation=@([pscustomobject][ordered]@{profile_id='quick';command='test-command'})
        outputs=@('Transactional amendment receipt.');commit_policy='Commit after validation.';push_checkpoint='manual-owner-review'
    }
    if (-not $WithoutArchitectureDecision) {
        $unit | Add-Member -NotePropertyName architecture_decision -NotePropertyValue ([pscustomobject][ordered]@{
            selected='Keep the existing feature unit and add only a project-approved path.'
            material_advance='The amendment unlocks the next bounded implementation slice.'
            deferred='Any broader project-authority or product change remains deferred.'
            deferred_reason='Those changes are outside this amendment contract.'
        })
    }
    if ($UpdateInstructionImpact) {
        $surfacePaths = [ordered]@{
            'agents'='<repo-root>/AGENTS.md'
            'readme'='<repo-root>/README.md'
            'router-doc'='<repo-root>/docs/ROUTER.md'
            'validation-doc'='<repo-root>/docs/VALIDATION.md'
            'compatibility-doc'='<repo-root>/docs/COMPATIBILITY.md'
            'roadmap-doc'='<repo-root>/docs/ROADMAP.md'
        }
        $unit.instruction_impact = 'update'
        $unit.instruction_surfaces = @(
            @($surfacePaths.Keys) | ForEach-Object {
                [pscustomobject][ordered]@{
                    surface_kind=$_
                    path=$surfacePaths[$_]
                    owner='workflow-self-test'
                    change_reason='Keep the synthetic amendment contract current.'
                    action='update'
                    status='planned'
                    validation='Test-ActiveWriteScopeAmendment.ps1 -SelfTest'
                    skill_id=$null
                }
            }
        )
        $unit.instruction_none_justification = $null
        $unit | Add-Member -NotePropertyName source_composition -NotePropertyValue ([pscustomobject][ordered]@{
            mode='observed-working-copies'
            lock_path=$null
            materialization_receipt=$null
        })
    }
    $eventId = 'unit-write-scope-001-claimed-0001'
    $state = [pscustomobject][ordered]@{
        '$schema'='https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/workspace-state-v2.schema.json'
        schema='rusty.morphospace.workflow.workspace_state.v2';project_id='write-scope-test';plan_revision=1
        current_unit='unit-write-scope-001';next_ready_unit=$null;last_event_id=$eventId;last_accepted_receipt=$null
        repository_heads=@();module_registry=[pscustomobject][ordered]@{lock_revision=1;lock_fingerprint=('0'*64);modules=@()}
        capability_registry=@();dirty_repositories=@('owner-repo');blockers=@();validation_checkpoint=$null;pending_push_bundle=$null
    }
    $event = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v2';event_id=$eventId;sequence=1;timestamp='2026-08-10T00:00:00.0000000Z'
        run_id='write-scope-bootstrap-20260810';session_id=$null;project_id='write-scope-test';unit_id='unit-write-scope-001'
        event_type='state-transition';summary='Claimed the bounded write-scope test unit.';previous_event_sha256=('0'*64);receipts=@()
    }
    $amendmentId = if ($AddRepository) { 'unit-write-scope-001-add-aux' } else { 'unit-write-scope-001-add-docs' }
    $repositoryId = if ($AddRepository) { 'aux-repo' } else { 'owner-repo' }
    $beforePaths = [Collections.Generic.List[string]]::new()
    $afterPaths = [Collections.Generic.List[string]]::new()
    if ($AddRepository) {
        $afterPaths.Add('crates/') | Out-Null
    } else {
        $beforePaths.Add('src/') | Out-Null
        $afterPaths.Add('docs/') | Out-Null
        $afterPaths.Add('src/') | Out-Null
    }
    $paths = [pscustomobject]@{
        workspace=$workspace
        project=(Join-Path $workspace 'project.spec.json')
        state=(Join-Path $workspace 'workspace.state.json')
        unit=(Join-Path $workspace 'iteration-units\unit-write-scope-001.json')
        events=(Join-Path $workspace 'iteration-events.jsonl')
        out=(Join-Path $workspace "receipts\$amendmentId.json")
    }
    Write-WriteScopeJson $paths.project $project
    Write-WriteScopeJson $paths.state $state
    Write-WriteScopeJson $paths.unit $unit
    [IO.File]::WriteAllText($paths.events, (($event | ConvertTo-Json -Depth 32 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $amendment = [pscustomobject][ordered]@{
        '$schema'='https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/active-write-scope-amendment-v1.schema.json'
        schema='rusty.morphospace.workflow.active_write_scope_amendment.v1'
        amendment_id=$amendmentId;project_id='write-scope-test';unit_id='unit-write-scope-001';repository_id=$repositoryId
        reason='Continue the same bounded feature unit with an additional project-approved write path.'
        expected=[pscustomobject][ordered]@{
            status='active';current_unit='unit-write-scope-001';project_revision=1
            project_sha256=(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $paths.project))
            state_sha256=(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $paths.state))
            unit_sha256=(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $paths.unit))
            events_sha256=(Get-MorphospaceFileSha256 $paths.events);events_length=[IO.FileInfo]::new($paths.events).Length;event_tail_id=$eventId
        }
        before_allowed_paths=$beforePaths;after_allowed_paths=$afterPaths
        does_not_prove=@('Does not change source, run a build, validate a product, mutate a device, or authorize publication.')
    }
    $amendmentPath = Join-Path $Root "amendment-$Suffix.json"
    Write-WriteScopeJson $amendmentPath $amendment
    return [pscustomobject]@{paths=$paths;amendment=$amendment;amendment_path=$amendmentPath;amendment_id=$amendmentId}
}

function Test-ReachableLargeWriteScope {
    param([string]$Root)
    # Reach the active state through the real initial Ready and Claim writers;
    # a hand-authored active unit would not prove transition closure.
    foreach ($name in @('GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES','GIT_CONFIG')) {
        if ([Environment]::GetEnvironmentVariable($name)) { throw "Write-scope fixture refuses ambient Git redirection: $name" }
    }
    $root = Join-Path $Root 'reachable-large'
    $source = Join-Path $root 'source'
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'src'))
    $allPaths = @(1..142 | ForEach-Object { 'src/file-{0:d3}.txt' -f $_ })
    foreach ($path in $allPaths) { [IO.File]::WriteAllText((Join-Path $source $path), "Fixture source.`n") }
    foreach ($arguments in @(
        @('init','-b','main'), @('add','src/'),
        @('-c','core.hooksPath=','-c','user.name=Workflow Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture source')
    )) {
        $gitOutput = @(& git -C $source @arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Fixture-local Git failed: $($gitOutput -join ' ')" }
        if ($arguments[0] -ceq 'init') {
            $metadata = Join-Path $source '.git'
            Assert-WriteScopeTest ([IO.Directory]::Exists($metadata) -and -not ([IO.File]::GetAttributes($metadata) -band [IO.FileAttributes]::ReparsePoint)) 'fixture Git metadata is not an ordinary local directory'
            $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            foreach ($probe in @(
                @{arguments=@('rev-parse','--show-toplevel');expected=$source},
                @{arguments=@('rev-parse','--absolute-git-dir');expected=$metadata},
                @{arguments=@('rev-parse','--path-format=absolute','--git-common-dir');expected=$metadata}
            )) {
                $actual = @(& git -C $source @($probe.arguments) 2>&1)
                Assert-WriteScopeTest ($LASTEXITCODE -eq 0 -and $actual.Count -eq 1 -and [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$actual[0])).Equals($probe.expected,$comparison)) 'fixture Git worktree or metadata was redirected'
            }
        }
    }
    $projectRoot = Join-Path $root 'project'
    [void][IO.Directory]::CreateDirectory($projectRoot)
    & (Join-Path $PSScriptRoot 'New-ProjectWorkspace.ps1') -ProjectRoot $projectRoot -ProjectId 'write-scope-reachable' -Purpose 'Reach a large active scope through initial owner admission.' -Execute | Out-Null
    $workspace = Join-Path $projectRoot 'morphospace'
    $seed = New-WriteScopeFixture $root 'seed'
    $unit = Read-MorphospaceProtocolJson $seed.paths.unit
    $unit.project_id = 'write-scope-reachable'
    $unit.status = 'proposed'
    $unit.allowed_repositories = @([pscustomobject]@{repo_id='project-shell';allowed_paths=@($allPaths[0..133])})
    $unit.validation = @([pscustomobject]@{profile_id='workflow';command='Fixture validation only.'})
    $unit | Add-Member -NotePropertyName claim_requirements -NotePropertyValue ([pscustomobject]@{minimum_free_disk_mib=0;required_tools=@();product_inputs=@()})
    $unitPath = Join-Path $workspace 'iteration-units/unit-write-scope-001.json'
    Write-WriteScopeJson $unitPath $unit
    $mapPath = Join-Path $root 'repository-map.json'
    Write-WriteScopeJson $mapPath ([pscustomobject]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([pscustomobject]@{repo_id='project-shell';path=$source;role='source'})})
    foreach ($action in @('Ready','Claim')) {
        $receipt = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action $action -WorkspaceRoot $workspace -UnitId $unit.unit_id -RepoMapPath $mapPath -Timestamp '2026-08-10T02:00:00.0000000Z' -Execute | ConvertFrom-Json
        Assert-WriteScopeTest ($receipt.executed) "large initial $action did not execute"
    }
    Import-Module (Join-Path $PSScriptRoot 'ActiveWriteScopeAmendment.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
    $projectPath = Join-Path $workspace 'project.spec.json'
    $statePath = Join-Path $workspace 'workspace.state.json'
    $eventsPath = Join-Path $workspace 'iteration-events.jsonl'
    $project = Read-MorphospaceProtocolJson $projectPath
    $state = Read-MorphospaceProtocolJson $statePath
    $active = Read-MorphospaceProtocolJson $unitPath
    Assert-WriteScopeTest ($active.status -ceq 'active' -and $state.current_unit -ceq $unit.unit_id -and @($active.allowed_repositories[0].allowed_paths).Count -eq 134 -and $null -eq $state.last_accepted_receipt) 'initial Ready/Claim did not admit 134 exact paths without an accepted predecessor'
    Assert-IterationUnitSchema $active $true 'the reachable 134-path active unit does not satisfy the unit schema'
    $amendment = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.active_write_scope_amendment.v1'
        amendment_id='reachable-large-add-eight';project_id=$project.project_id;unit_id=$unit.unit_id;repository_id='project-shell'
        reason='Add eight exact tracked paths within the unchanged project source ceiling.'
        expected=[pscustomobject]@{
            status='active';current_unit=$state.current_unit;project_revision=$project.revision
            project_sha256=(Get-MorphospaceCanonicalJsonSha256 $project);state_sha256=(Get-MorphospaceCanonicalJsonSha256 $state)
            unit_sha256=(Get-MorphospaceCanonicalJsonSha256 $active);events_sha256=(Get-MorphospaceFileSha256 $eventsPath)
            events_length=[IO.FileInfo]::new($eventsPath).Length;event_tail_id=$state.last_event_id
        }
        before_allowed_paths=@($active.allowed_repositories[0].allowed_paths);after_allowed_paths=$allPaths
        does_not_prove=@('Fixture-only source-scope continuity; no product, device, build, acceptance or publication authority.')
    }
    $amendmentPath = Join-Path $root 'large-amendment.json'
    $outPath = Join-Path $workspace 'receipts/reachable-large-add-eight.json'
    Write-WriteScopeJson $amendmentPath $amendment
    $before = @{}
    foreach ($path in @($projectPath,$statePath,$unitPath,$eventsPath)) { $before[$path] = Get-MorphospaceFileSha256 $path }
    $dry = Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $workspace -UnitId $unit.unit_id -ActiveWriteScopeAmendment $amendmentPath -OutPath $outPath
    Assert-WriteScopeTest (-not $dry.executed -and -not [IO.File]::Exists($outPath)) 'large-scope dry run performed a transition'
    foreach ($path in $before.Keys) { Assert-WriteScopeTest ($before[$path] -ceq (Get-MorphospaceFileSha256 $path)) 'large-scope dry run changed owner bytes' }
    foreach ($case in @('stale-cas','wrong-before','removal','outside-project','unsafe-path','case-duplicate')) {
        $bad = Copy-WriteScopeValue $amendment
        switch ($case) {
            'stale-cas' { $bad.expected.unit_sha256 = '0'*64 }
            'wrong-before' { $bad.before_allowed_paths[133] = 'src/not-declared.txt' }
            'removal' { $bad.after_allowed_paths = @($allPaths[1..141]) }
            'outside-project' { $bad.after_allowed_paths += 'private/extra.txt' }
            'unsafe-path' { $bad.after_allowed_paths += '../escape.txt' }
            'case-duplicate' { $bad.after_allowed_paths += 'src/FILE-001.txt' }
        }
        $badPath = Join-Path $root "large-$case.json"
        Write-WriteScopeJson $badPath $bad
        Assert-WriteScopeRejected { Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $workspace -UnitId $unit.unit_id -ActiveWriteScopeAmendment $badPath -OutPath $outPath } "large-scope $case was accepted"
    }
    $hash = Get-MorphospaceFileSha256 $amendmentPath
    Assert-WriteScopeRejected { Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $workspace -UnitId $unit.unit_id -ActiveWriteScopeAmendment $amendmentPath -OutPath $outPath -Execute } 'large-scope execute without dry-run input hash was accepted'
    $executed = Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $workspace -UnitId $unit.unit_id -ActiveWriteScopeAmendment $amendmentPath -ExpectedActiveWriteScopeAmendmentSha256 $hash -OutPath $outPath -Timestamp '2026-08-10T02:01:00.0000000Z' -Execute
    $after = Read-MorphospaceProtocolJson $unitPath
    $afterState = Read-MorphospaceProtocolJson $statePath
    $expectedUnit = Copy-WriteScopeValue $active
    $expectedUnit.allowed_repositories[0].allowed_paths = $allPaths
    $expectedState = Copy-WriteScopeValue $state
    $expectedState.last_event_id = 'reachable-large-add-eight-recorded'
    Assert-WriteScopeTest ($executed.executed -and @($after.allowed_repositories[0].allowed_paths).Count -eq 142 -and (Get-MorphospaceCanonicalJsonSha256 $after) -ceq (Get-MorphospaceCanonicalJsonSha256 $expectedUnit)) 'large amendment changed more than the exact additive path set'
    Assert-WriteScopeTest ((Get-MorphospaceCanonicalJsonSha256 $afterState) -ceq (Get-MorphospaceCanonicalJsonSha256 $expectedState) -and $before[$projectPath] -ceq (Get-MorphospaceFileSha256 $projectPath) -and (Get-MorphospaceFileSha256 $outPath) -ceq $hash) 'large amendment detached project/state/input-hash continuity'
    Write-Output 'Reachable large-scope control passed: actual Ready/Claim 134 paths, dry-run/execute 142 paths, seven refusal guards.'
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("workenv-active-write-scope-" + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    Test-ReachableLargeWriteScope $temp
    $fixture = New-WriteScopeFixture $temp
    $paths = $fixture.paths
    $before = @{}
    foreach ($name in @('project','state','unit','events')) { $before[$name] = [IO.File]::ReadAllBytes([string]$paths.$name) }
    $beforeStateDocument = Read-MorphospaceProtocolJson $paths.state
    $beforeUnitDocument = Read-MorphospaceProtocolJson $paths.unit
    $beforeProjectDocument = Read-MorphospaceProtocolJson $paths.project
    Assert-IterationUnitSchema $beforeUnitDocument $true 'the exact four-field architecture decision was rejected'
    Assert-ProjectSpecSchema $beforeProjectDocument $true 'the manual-owner-review project checkpoint was rejected'
    Assert-WriteScopeTest ([string]$beforeUnitDocument.push_checkpoint -ceq 'manual-owner-review') 'the active fixture does not exercise manual-owner-review'

    $unknownPushCheckpoint = Copy-WriteScopeValue $beforeUnitDocument
    $unknownPushCheckpoint.push_checkpoint = 'unknown-checkpoint'
    Assert-IterationUnitSchema $unknownPushCheckpoint $false 'an unknown unit push checkpoint was accepted'

    $unknownProjectPushCheckpoint = Copy-WriteScopeValue $beforeProjectDocument
    $unknownProjectPushCheckpoint.release_policy.push_checkpoint = 'unknown-checkpoint'
    Assert-ProjectSpecSchema $unknownProjectPushCheckpoint $false 'an unknown project push checkpoint was accepted'

    $missingArchitectureField = Copy-WriteScopeValue $beforeUnitDocument
    $missingArchitectureField.architecture_decision.PSObject.Properties.Remove('deferred_reason')
    Assert-IterationUnitSchema $missingArchitectureField $false 'an architecture decision with a missing field was accepted'

    $emptyArchitectureField = Copy-WriteScopeValue $beforeUnitDocument
    $emptyArchitectureField.architecture_decision.material_advance = ''
    Assert-IterationUnitSchema $emptyArchitectureField $false 'an architecture decision with an empty field was accepted'

    $wrongTypeArchitectureField = Copy-WriteScopeValue $beforeUnitDocument
    $wrongTypeArchitectureField.architecture_decision.deferred = 1
    Assert-IterationUnitSchema $wrongTypeArchitectureField $false 'an architecture decision with a wrong-type field was accepted'

    $unknownArchitectureField = Copy-WriteScopeValue $beforeUnitDocument
    $unknownArchitectureField.architecture_decision | Add-Member -NotePropertyName unexpected -NotePropertyValue 'not admitted'
    Assert-IterationUnitSchema $unknownArchitectureField $false 'an architecture decision with an unknown field was accepted'

    $dry = Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $paths.workspace -UnitId 'unit-write-scope-001' `
        -ActiveWriteScopeAmendment $fixture.amendment_path -OutPath $paths.out -Timestamp '2026-08-10T01:00:00.0000000Z'
    Assert-WriteScopeTest (-not $dry.executed -and $null -eq $dry.event_id) 'dry run did not report a non-executed plan'
    foreach ($name in @('project','state','unit','events')) {
        Assert-WriteScopeTest ((Get-MorphospaceSha256Bytes $before[$name]) -ceq (Get-MorphospaceFileSha256 ([string]$paths.$name))) "dry run changed $name bytes"
    }
    Assert-WriteScopeTest (-not [IO.File]::Exists($paths.out)) 'dry run created the amendment receipt'

    $wrapperDry = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action AmendActiveWriteScope `
        -WorkspaceRoot $paths.workspace -UnitId 'unit-write-scope-001' -ActiveWriteScopeAmendment $fixture.amendment_path `
        -OutPath $paths.out -Timestamp '2026-08-10T01:00:00.0000000Z' | ConvertFrom-Json
    Assert-WriteScopeTest ([string]$wrapperDry.action -ceq 'AmendActiveWriteScope') 'public action router did not dispatch the amendment'
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

    $badCas = Copy-WriteScopeValue $fixture.amendment
    $badCas.expected.project_sha256 = '0' * 64
    $badCasPath = Join-Path $temp 'bad-cas.json'; Write-WriteScopeJson $badCasPath $badCas
    Assert-WriteScopeRejected {
        Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $paths.workspace -UnitId 'unit-write-scope-001' -ActiveWriteScopeAmendment $badCasPath -OutPath $paths.out
    } 'stale project CAS was accepted'

    $outsideProject = Copy-WriteScopeValue $fixture.amendment
    $outsideProject.after_allowed_paths = @('docs/','private/','src/')
    $outsidePath = Join-Path $temp 'outside-project.json'; Write-WriteScopeJson $outsidePath $outsideProject
    Assert-WriteScopeRejected {
        Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $paths.workspace -UnitId 'unit-write-scope-001' -ActiveWriteScopeAmendment $outsidePath -OutPath $paths.out
    } 'path outside project repository scope was accepted'

    $removal = Copy-WriteScopeValue $fixture.amendment
    $removal.after_allowed_paths = @('docs/')
    $removalPath = Join-Path $temp 'removal.json'; Write-WriteScopeJson $removalPath $removal
    Assert-WriteScopeRejected {
        Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $paths.workspace -UnitId 'unit-write-scope-001' -ActiveWriteScopeAmendment $removalPath -OutPath $paths.out
    } 'write-path removal was accepted'

    $amendmentHash = Get-MorphospaceFileSha256 $fixture.amendment_path
    Assert-WriteScopeRejected {
        Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $paths.workspace -UnitId 'unit-write-scope-001' `
            -ActiveWriteScopeAmendment $fixture.amendment_path -OutPath $paths.out -Execute
    } 'execute without dry-run input hash was accepted'

    $executed = Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $paths.workspace -UnitId 'unit-write-scope-001' `
        -ActiveWriteScopeAmendment $fixture.amendment_path -ExpectedActiveWriteScopeAmendmentSha256 $amendmentHash `
        -OutPath $paths.out -Timestamp '2026-08-10T01:00:00.0000000Z' -Execute
    Assert-WriteScopeTest ($executed.executed -and [string]$executed.event_id -ceq 'unit-write-scope-001-add-docs-recorded') 'execute receipt is incomplete'
    $afterState = Read-MorphospaceProtocolJson $paths.state
    $afterUnit = Read-MorphospaceProtocolJson $paths.unit
    Assert-WriteScopeTest ((Get-MorphospaceSha256Bytes $before.project) -ceq (Get-MorphospaceFileSha256 $paths.project)) 'execute changed project bytes'
    Assert-WriteScopeTest ([string]$afterState.current_unit -ceq 'unit-write-scope-001' -and [int]$afterState.plan_revision -eq 1 -and [string]$afterState.last_event_id -ceq 'unit-write-scope-001-add-docs-recorded') 'state continuity is wrong'
    Assert-WriteScopeTest ([string]$afterUnit.status -ceq 'active' -and (@($afterUnit.allowed_repositories[0].allowed_paths) -join '|') -ceq 'docs/|src/') 'active unit did not receive the exact additive paths'
    Assert-WriteScopeTest ([string]$afterUnit.push_checkpoint -ceq 'manual-owner-review') 'execute changed the manual owner-review checkpoint'
    Assert-WriteScopeTest (
        (Get-MorphospaceCanonicalJsonSha256 $afterUnit.architecture_decision) -ceq
        (Get-MorphospaceCanonicalJsonSha256 $beforeUnitDocument.architecture_decision)
    ) 'execute changed the architecture decision'
    $expectedState = Copy-WriteScopeValue $beforeStateDocument
    $expectedState.last_event_id = 'unit-write-scope-001-add-docs-recorded'
    Assert-WriteScopeTest ((Get-MorphospaceCanonicalJsonSha256 $afterState) -ceq (Get-MorphospaceCanonicalJsonSha256 $expectedState)) 'execute changed another state field'
    $expectedUnit = Copy-WriteScopeValue $beforeUnitDocument
    $expectedUnit.allowed_repositories[0].allowed_paths = @('docs/','src/')
    Assert-WriteScopeTest ((Get-MorphospaceCanonicalJsonSha256 $afterUnit) -ceq (Get-MorphospaceCanonicalJsonSha256 $expectedUnit)) 'execute changed another unit field'
    Assert-WriteScopeTest ((Get-MorphospaceFileSha256 $paths.out) -ceq $amendmentHash) 'transaction did not install the exact amendment input'
    $intentPath = Join-Path $paths.workspace 'receipts\transactions\unit-write-scope-001-add-docs-recorded-transition.intent.json'
    $completionPath = Join-Path $paths.workspace 'receipts\transactions\unit-write-scope-001-add-docs-recorded-transition.completion.json'
    $intent = Read-MorphospaceProtocolJson $intentPath
    Assert-WriteScopeTest ([string]$intent.schema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v3' -and @($intent.additional_projections).Count -eq 1 -and [string]$intent.additional_projections[0].path -ceq 'project.spec.json') 'transaction did not mutex-bind the unchanged project authority'
    Assert-WriteScopeTest ([IO.File]::Exists($completionPath)) 'transaction completion is missing'

    $withoutArchitecture = New-WriteScopeFixture $temp 'without-architecture' -WithoutArchitectureDecision
    $withoutArchitectureUnit = Read-MorphospaceProtocolJson $withoutArchitecture.paths.unit
    Assert-IterationUnitSchema $withoutArchitectureUnit $true 'a unit without the optional architecture decision was rejected'
    $withoutArchitectureDry = Invoke-MorphospaceAmendActiveWriteScope `
        -WorkspaceRoot $withoutArchitecture.paths.workspace `
        -UnitId 'unit-write-scope-001' `
        -ActiveWriteScopeAmendment $withoutArchitecture.amendment_path `
        -OutPath $withoutArchitecture.paths.out `
        -Timestamp '2026-08-10T01:05:00.0000000Z'
    Assert-WriteScopeTest (-not $withoutArchitectureDry.executed) 'dry run rejected a unit without the optional architecture decision'

    $updateImpact = New-WriteScopeFixture $temp 'update-impact' -UpdateInstructionImpact
    $updateImpactUnit = Read-MorphospaceProtocolJson $updateImpact.paths.unit
    Assert-IterationUnitSchema $updateImpactUnit $true 'an update-impact unit with planned surfaces and null justification was rejected'
    Assert-WriteScopeTest (
        [string]$updateImpactUnit.instruction_impact -ceq 'update' -and
        (@($updateImpactUnit.instruction_surfaces | ForEach-Object { [string]$_.surface_kind }) -join '|') -ceq
            'agents|readme|router-doc|validation-doc|compatibility-doc|roadmap-doc' -and
        @($updateImpactUnit.instruction_surfaces | Where-Object { $_.status -cne 'planned' -or $null -ne $_.skill_id }).Count -eq 0 -and
        $null -eq $updateImpactUnit.instruction_none_justification -and
        [string]$updateImpactUnit.source_composition.mode -ceq 'observed-working-copies' -and
        $null -eq $updateImpactUnit.source_composition.lock_path -and
        $null -eq $updateImpactUnit.source_composition.materialization_receipt
    ) 'the update-impact fixture does not exercise the intended exact nullable shape'
    $unknownSurfaceKind = Copy-WriteScopeValue $updateImpactUnit
    $unknownSurfaceKind.instruction_surfaces[4].surface_kind = 'unknown-doc'
    Assert-IterationUnitSchema $unknownSurfaceKind $false 'an unknown instruction surface kind was accepted'
    $updateImpactUnitHash = Get-MorphospaceFileSha256 $updateImpact.paths.unit
    $updateImpactDry = Invoke-MorphospaceAmendActiveWriteScope `
        -WorkspaceRoot $updateImpact.paths.workspace `
        -UnitId 'unit-write-scope-001' `
        -ActiveWriteScopeAmendment $updateImpact.amendment_path `
        -OutPath $updateImpact.paths.out `
        -Timestamp '2026-08-10T01:07:00.0000000Z'
    Assert-WriteScopeTest (-not $updateImpactDry.executed) 'dry run rejected an update-impact unit with null justification'
    Assert-WriteScopeTest (
        $updateImpactUnitHash -ceq (Get-MorphospaceFileSha256 $updateImpact.paths.unit)
    ) 'update-impact dry run changed active-unit bytes'

    $addRepo = New-WriteScopeFixture $temp 'add-repo' -AddRepository
    $addRepoHash = Get-MorphospaceFileSha256 $addRepo.amendment_path
    Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $addRepo.paths.workspace -UnitId 'unit-write-scope-001' `
        -ActiveWriteScopeAmendment $addRepo.amendment_path -ExpectedActiveWriteScopeAmendmentSha256 $addRepoHash `
        -OutPath $addRepo.paths.out -Timestamp '2026-08-10T01:10:00.0000000Z' -Execute | Out-Null
    $addRepoUnit = Read-MorphospaceProtocolJson $addRepo.paths.unit
    Assert-WriteScopeTest ((@($addRepoUnit.allowed_repositories | ForEach-Object { [string]$_.repo_id }) -join '|') -ceq 'aux-repo|owner-repo') 'project-declared repository was not added canonically'
    Assert-WriteScopeTest ((@($addRepoUnit.allowed_repositories | Where-Object { [string]$_.repo_id -ceq 'aux-repo' })[0].allowed_paths -join '|') -ceq 'crates/') 'new repository received the wrong path set'

    $race = New-WriteScopeFixture $temp 'race'
    $raceHook = {
        $mutated = Read-MorphospaceProtocolJson $race.paths.project
        $mutated.purpose = 'Concurrent project mutation.'
        Write-WriteScopeJson $race.paths.project $mutated
    }.GetNewClosure()
    Assert-WriteScopeRejected {
        Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $race.paths.workspace -UnitId 'unit-write-scope-001' `
            -ActiveWriteScopeAmendment $race.amendment_path -ExpectedActiveWriteScopeAmendmentSha256 (Get-MorphospaceFileSha256 $race.amendment_path) `
            -OutPath $race.paths.out -Timestamp '2026-08-10T01:20:00.0000000Z' -BeforeTransitionHook $raceHook -Execute
    } 'mutex-protected project CAS race was accepted'

    # Mutation flags describe the amendment action, not the isolated fixture's
    # initial Git setup or its real Ready/Claim transitions.
    [pscustomobject]@{result='pass';action='AmendActiveWriteScope';additive=$true;project_bounded=$true;transactional=$true;reachable_initial_paths=134;amended_paths=142;isolated_fixture_git_setup=$true;architecture_decision_optional_and_strict=$true;manual_owner_review_preserved=$true;unknown_push_checkpoint_rejected=$true;update_instruction_null_compatible=$true;compatibility_and_roadmap_surfaces_strict=$true;git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false} | ConvertTo-Json -Compress
} finally {
    if ([IO.Directory]::Exists($temp)) {
        $resolvedTemp = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $temp).Path)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedTemp.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTemp) -notlike 'workenv-active-write-scope-*' -or ([IO.File]::GetAttributes($resolvedTemp) -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe write-scope fixture cleanup path.' }
        foreach ($file in [IO.Directory]::EnumerateFiles($temp,'*',[IO.SearchOption]::AllDirectories)) {
            try { [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal) } catch {}
        }
        [IO.Directory]::Delete($temp,$true)
    }
}
