param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'ActiveWriteScopeAmendment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

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
    param([string]$Root,[string]$Suffix='main',[switch]$AddRepository)
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
        release_policy=[pscustomobject][ordered]@{versioning='semver';commit_policy='validated slices';push_checkpoint='local-only';source_first=$true;planning_last=$true;force_push_allowed=$false}
        public_boundary=[pscustomobject][ordered]@{mode='public';private_overlay='local/';prohibited_evidence=@('private evidence')}
    }
    $unit = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id='unit-write-scope-001';project_id='write-scope-test';status='active'
        objective='Continue one bounded implementation after discovering another project-approved path.';guard_profile='fast';change_categories=@('implementation')
        instruction_impact='none';instruction_surfaces=@();instruction_none_justification='The fixture does not change instruction surfaces.'
        prerequisites=@();allowed_repositories=@([pscustomobject][ordered]@{repo_id='owner-repo';allowed_paths=@('src/')})
        read_only_dependencies=@();non_scope=@('Any work outside declared project repositories.');acceptance=@([pscustomobject][ordered]@{acceptance_id='bounded-amendment';proof='Only project-approved paths are added.';command='test-command'})
        risk_tier='quick';device_requirement='forbidden';validation=@([pscustomobject][ordered]@{profile_id='quick';command='test-command'})
        outputs=@('Transactional amendment receipt.');commit_policy='Commit after validation.';push_checkpoint='local-only'
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

$temp = Join-Path ([IO.Path]::GetTempPath()) ("workenv-active-write-scope-" + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $fixture = New-WriteScopeFixture $temp
    $paths = $fixture.paths
    $before = @{}
    foreach ($name in @('project','state','unit','events')) { $before[$name] = [IO.File]::ReadAllBytes([string]$paths.$name) }
    $beforeStateDocument = Read-MorphospaceProtocolJson $paths.state
    $beforeUnitDocument = Read-MorphospaceProtocolJson $paths.unit

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

    [pscustomobject]@{result='pass';action='AmendActiveWriteScope';additive=$true;project_bounded=$true;transactional=$true;git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false} | ConvertTo-Json -Compress
} finally {
    if ([IO.Directory]::Exists($temp)) {
        foreach ($file in [IO.Directory]::EnumerateFiles($temp,'*',[IO.SearchOption]::AllDirectories)) {
            try { [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal) } catch {}
        }
        [IO.Directory]::Delete($temp,$true)
    }
}
