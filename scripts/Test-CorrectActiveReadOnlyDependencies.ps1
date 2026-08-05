param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'CorrectActiveReadOnlyDependencies.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Assert-CorrectionTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "CorrectActiveReadOnlyDependencies self-test failed: $Message" }
}

function Assert-CorrectionRejected {
    param([scriptblock]$Action,[string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-CorrectionTest $rejected $Message
}

function Write-CorrectionTestJson {
    param([string]$Path,[object]$Value)
    $parent = Split-Path $Path -Parent
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 64) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Copy-CorrectionTestDocument {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Get-CorrectionTestDependencyHash {
    param([AllowEmptyCollection()][object[]]$Dependencies)
    return Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{read_only_dependencies=@($Dependencies)})
}

function Invoke-CorrectionTestGit {
    param([string]$Path,[string[]]$Arguments)
    $output = @(& git -C $Path @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Test Git command failed: git $($Arguments -join ' ')`n$($output -join "`n")" }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function New-CorrectionTestRepository {
    param([string]$Path,[string]$Name)
    [IO.Directory]::CreateDirectory((Join-Path $Path 'crates')) | Out-Null
    Invoke-CorrectionTestGit $Path @('init','--initial-branch=main') | Out-Null
    Invoke-CorrectionTestGit $Path @('config','user.name','Workflow Test') | Out-Null
    Invoke-CorrectionTestGit $Path @('config','user.email','workflow@example.invalid') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Path 'Cargo.toml'), "[workspace]`nmembers = []`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path "crates\$Name.txt"), "first`n", [Text.UTF8Encoding]::new($false))
    Invoke-CorrectionTestGit $Path @('add','.') | Out-Null
    Invoke-CorrectionTestGit $Path @('commit','-m','first') | Out-Null
    $first = Invoke-CorrectionTestGit $Path @('rev-parse','HEAD')
    [IO.File]::WriteAllText((Join-Path $Path "crates\$Name.txt"), "second`n", [Text.UTF8Encoding]::new($false))
    Invoke-CorrectionTestGit $Path @('add','.') | Out-Null
    Invoke-CorrectionTestGit $Path @('commit','-m','second') | Out-Null
    return [pscustomobject]@{
        first = $first
        first_tree = Invoke-CorrectionTestGit $Path @('rev-parse',"$first^{tree}")
        head = Invoke-CorrectionTestGit $Path @('rev-parse','HEAD')
        tree = Invoke-CorrectionTestGit $Path @('rev-parse','HEAD^{tree}')
    }
}

function Get-CorrectionVerification {
    param([string]$Revision,[string]$Tree,[string]$Role)
    return "Exact Git revision $Revision with tree $Tree; role $Role."
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("workenv-readonly-correction-" + [guid]::NewGuid().ToString('N'))
try {
    $workspace = Join-Path $temp 'morphospace'
    $repoA = Join-Path $temp 'dep-a'
    $repoB = Join-Path $temp 'dep-b'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null
    [IO.Directory]::CreateDirectory($repoA) | Out-Null
    [IO.Directory]::CreateDirectory($repoB) | Out-Null
    $identityA = New-CorrectionTestRepository $repoA 'a'
    $identityB = New-CorrectionTestRepository $repoB 'b'

    $project = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.project_spec.v1';project_id='correction-project';revision=1
        purpose='Exercise bounded read-only dependency correction.'
        activation_model=[pscustomobject]@{default='disabled';unlisted_modules='inert'}
        authority_map=@([pscustomobject]@{parameter='project.composition';owner='owner-repo';adapters=@()})
        repositories=@(
            [pscustomobject]@{repo_id='dep-a';role='core';path='<dep-a>';allowed_paths=@('Cargo.toml','crates/')},
            [pscustomobject]@{repo_id='dep-b';role='core';path='<dep-b>';allowed_paths=@('Cargo.toml','crates/')},
            [pscustomobject]@{repo_id='owner-repo';role='application';path='<owner>';allowed_paths=@('src/')}
        )
        modules=@();non_scope=@('No source or device mutation.')
        validation_profiles=@([pscustomobject]@{profile_id='quick';commands=@('test-command')})
        public_boundary=[pscustomobject]@{mode='public';private_overlay='local';prohibited_evidence=@('private evidence')}
    }
    $beforeDependency = [pscustomobject][ordered]@{
        repo_id='dep-a';paths=@('Cargo.toml','crates/');purpose='Provide an exact build dependency.'
        verification=(Get-CorrectionVerification $identityA.first $identityA.first_tree 'exact-build-pin')
    }
    $unit = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id='unit-correction-001';project_id='correction-project';status='active'
        objective='Correct only the declared read-only dependency closure.';change_categories=@('workflow-automation')
        instruction_impact='none';instruction_surfaces=@();instruction_none_justification='No instruction surface changes in the fixture.'
        prerequisites=@();allowed_repositories=@([pscustomobject]@{repo_id='owner-repo';allowed_paths=@('src/')})
        read_only_dependencies=@($beforeDependency);non_scope=@('Source mutation.');acceptance=@([pscustomobject]@{acceptance_id='bounded-correction';proof='Only the dependency declaration changes.';command='test-command'})
        risk_tier='quick';device_requirement='forbidden';validation=@([pscustomobject]@{profile_id='quick';command='test-command'})
        outputs=@('Transactional correction receipt.');commit_policy='Commit after validation.';push_checkpoint='local-only'
    }
    $eventId = 'unit-correction-001-claimed-0001'
    $state = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.workspace_state.v1';project_id='correction-project';plan_revision=1
        current_unit='unit-correction-001';next_ready_unit=$null;last_event_id=$eventId;dirty_repositories=@('owner-repo')
        blockers=@();validation_checkpoint=$null;pending_push_bundle=$null
    }
    $event = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=1;timestamp='2026-08-05T00:00:00Z'
        project_id='correction-project';unit_id='unit-correction-001';event_type='state-transition';summary='Claimed the bounded test unit.';receipts=@()
    }
    Write-CorrectionTestJson (Join-Path $workspace 'project.spec.json') $project
    Write-CorrectionTestJson (Join-Path $workspace 'workspace.state.json') $state
    Write-CorrectionTestJson (Join-Path $workspace 'iteration-units\unit-correction-001.json') $unit
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'), (($event | ConvertTo-Json -Depth 32 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $repoMap = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.repository_map.v1'
        repositories=@(
            [pscustomobject]@{repo_id='dep-a';path=$repoA;role='source'},
            [pscustomobject]@{repo_id='dep-b';path=$repoB;role='source'}
        )
    }
    $repoMapPath = Join-Path $temp 'repository-map.json'
    Write-CorrectionTestJson $repoMapPath $repoMap

    $afterA = Copy-CorrectionTestDocument $beforeDependency
    $afterA.verification = Get-CorrectionVerification $identityA.head $identityA.tree 'exact-build-pin'
    $afterB = [pscustomobject][ordered]@{
        repo_id='dep-b';paths=@('Cargo.toml','crates/');purpose='Provide parse-only workspace metadata.'
        verification=(Get-CorrectionVerification $identityB.head $identityB.tree 'workspace-parse-only')
    }
    $statePath = Join-Path $workspace 'workspace.state.json'
    $unitPath = Join-Path $workspace 'iteration-units\unit-correction-001.json'
    $eventsPath = Join-Path $workspace 'iteration-events.jsonl'
    $correction = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.active_read_only_dependency_correction.v1'
        correction_id='unit-correction-001-dependencies';project_id='correction-project';unit_id='unit-correction-001'
        reason='Replace one exact build identity and add one parse-only repository without widening write scope.'
        expected=[pscustomobject][ordered]@{
            status='active';current_unit='unit-correction-001'
            state_sha256=(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $statePath))
            unit_sha256=(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $unitPath))
            events_sha256=(Get-MorphospaceFileSha256 $eventsPath);events_length=[IO.FileInfo]::new($eventsPath).Length;event_tail_id=$eventId
        }
        before=@($beforeDependency);after=@($afterA,$afterB)
        repository_identities=@(
            [pscustomobject]@{repo_id='dep-a';revision=$identityA.head;tree=$identityA.tree;role='exact-build-pin'},
            [pscustomobject]@{repo_id='dep-b';revision=$identityB.head;tree=$identityB.tree;role='workspace-parse-only'}
        )
        does_not_prove=@('Does not materialize dependencies, execute validation, or authorize publication.')
    }
    $correctionPath = Join-Path $temp 'correction.json'
    $outPath = Join-Path $workspace 'receipts\unit-correction-001-dependencies.json'
    Write-CorrectionTestJson $correctionPath $correction
    $beforeStateBytes = [IO.File]::ReadAllBytes($statePath)
    $beforeUnitBytes = [IO.File]::ReadAllBytes($unitPath)
    $beforeEventsBytes = [IO.File]::ReadAllBytes($eventsPath)

    $dry = Invoke-MorphospaceCorrectActiveReadOnlyDependencies -WorkspaceRoot $workspace -UnitId 'unit-correction-001' `
        -RepoMapPath $repoMapPath -ReadOnlyDependencyCorrection $correctionPath -OutPath $outPath -Timestamp '2026-08-05T01:00:00.0000000Z'
    Assert-CorrectionTest (-not $dry.executed -and $null -eq $dry.event_id) 'dry run did not report a non-executed plan'
    Assert-CorrectionTest ((Get-MorphospaceSha256Bytes $beforeStateBytes) -eq (Get-MorphospaceFileSha256 $statePath)) 'dry run changed state bytes'
    Assert-CorrectionTest ((Get-MorphospaceSha256Bytes $beforeUnitBytes) -eq (Get-MorphospaceFileSha256 $unitPath)) 'dry run changed unit bytes'
    Assert-CorrectionTest ((Get-MorphospaceSha256Bytes $beforeEventsBytes) -eq (Get-MorphospaceFileSha256 $eventsPath)) 'dry run changed event bytes'
    Assert-CorrectionTest (-not [IO.File]::Exists($outPath)) 'dry run created the receipt'
    Assert-CorrectionTest ((Invoke-CorrectionTestGit $repoA @('rev-parse','HEAD')) -ceq $identityA.head) 'dry run changed dependency A HEAD'

    $wrapperDry = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action CorrectActiveReadOnlyDependencies `
        -WorkspaceRoot $workspace -UnitId 'unit-correction-001' -RepoMapPath $repoMapPath `
        -ReadOnlyDependencyCorrection $correctionPath -OutPath $outPath -Timestamp '2026-08-05T01:00:00.0000000Z' | ConvertFrom-Json
    Assert-CorrectionTest ([string]$wrapperDry.action -ceq 'CorrectActiveReadOnlyDependencies') 'public action router did not dispatch the correction'
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

    $badState = Copy-CorrectionTestDocument $correction
    $badState.expected.state_sha256 = '0' * 64
    $badStatePath = Join-Path $temp 'bad-state.json'; Write-CorrectionTestJson $badStatePath $badState
    Assert-CorrectionRejected {
        Invoke-MorphospaceCorrectActiveReadOnlyDependencies -WorkspaceRoot $workspace -UnitId 'unit-correction-001' -RepoMapPath $repoMapPath -ReadOnlyDependencyCorrection $badStatePath -OutPath $outPath
    } 'stale state CAS was accepted'

    $changedScope = Copy-CorrectionTestDocument $correction
    $changedScope.after[0].paths = @('crates/')
    $changedScopePath = Join-Path $temp 'changed-scope.json'; Write-CorrectionTestJson $changedScopePath $changedScope
    Assert-CorrectionRejected {
        Invoke-MorphospaceCorrectActiveReadOnlyDependencies -WorkspaceRoot $workspace -UnitId 'unit-correction-001' -RepoMapPath $repoMapPath -ReadOnlyDependencyCorrection $changedScopePath -OutPath $outPath
    } 'existing dependency path mutation was accepted'

    $wrongTree = Copy-CorrectionTestDocument $correction
    $wrongTree.repository_identities[1].tree = '0' * 40
    $wrongTree.after[1].verification = Get-CorrectionVerification $identityB.head ('0' * 40) 'workspace-parse-only'
    $wrongTreePath = Join-Path $temp 'wrong-tree.json'; Write-CorrectionTestJson $wrongTreePath $wrongTree
    Assert-CorrectionRejected {
        Invoke-MorphospaceCorrectActiveReadOnlyDependencies -WorkspaceRoot $workspace -UnitId 'unit-correction-001' -RepoMapPath $repoMapPath -ReadOnlyDependencyCorrection $wrongTreePath -OutPath $outPath
    } 'wrong Git tree identity was accepted'

    $validatingUnit = Copy-CorrectionTestDocument (Read-MorphospaceProtocolJson $unitPath)
    $validatingUnit.status = 'validating'; Write-CorrectionTestJson $unitPath $validatingUnit
    $validatingCorrection = Copy-CorrectionTestDocument $correction
    $validatingCorrection.expected.unit_sha256 = Get-MorphospaceCanonicalJsonSha256 $validatingUnit
    $validatingPath = Join-Path $temp 'validating.json'; Write-CorrectionTestJson $validatingPath $validatingCorrection
    Assert-CorrectionRejected {
        Invoke-MorphospaceCorrectActiveReadOnlyDependencies -WorkspaceRoot $workspace -UnitId 'unit-correction-001' -RepoMapPath $repoMapPath -ReadOnlyDependencyCorrection $validatingPath -OutPath $outPath
    } 'validating unit was accepted as active'
    [IO.File]::WriteAllBytes($unitPath,$beforeUnitBytes)

    $correctionHash = Get-MorphospaceFileSha256 $correctionPath
    Assert-CorrectionRejected {
        Invoke-MorphospaceCorrectActiveReadOnlyDependencies -WorkspaceRoot $workspace -UnitId 'unit-correction-001' -RepoMapPath $repoMapPath `
            -ReadOnlyDependencyCorrection $correctionPath -OutPath $outPath -Execute
    } 'execute without the dry-run correction hash was accepted'

    $executed = Invoke-MorphospaceCorrectActiveReadOnlyDependencies -WorkspaceRoot $workspace -UnitId 'unit-correction-001' `
        -RepoMapPath $repoMapPath -ReadOnlyDependencyCorrection $correctionPath -OutPath $outPath `
        -ExpectedReadOnlyDependencyCorrectionSha256 $correctionHash -Timestamp '2026-08-05T01:00:00.0000000Z' -Execute
    Assert-CorrectionTest ($executed.executed -and [string]$executed.event_id -ceq 'unit-correction-001-dependencies-recorded') 'execute receipt is incomplete'
    $afterUnit = Read-MorphospaceProtocolJson $unitPath
    $afterState = Read-MorphospaceProtocolJson $statePath
    Assert-CorrectionTest ((Get-CorrectionTestDependencyHash -Dependencies @($afterUnit.read_only_dependencies)) -eq (Get-CorrectionTestDependencyHash -Dependencies @($correction.after))) 'resulting dependency set differs from the correction'
    $expectedState = Copy-CorrectionTestDocument $state; $expectedState.last_event_id = 'unit-correction-001-dependencies-recorded'
    Assert-CorrectionTest ((Get-MorphospaceCanonicalJsonSha256 $afterState) -eq (Get-MorphospaceCanonicalJsonSha256 $expectedState)) 'execute changed state beyond last_event_id'
    Assert-CorrectionTest ([string]$afterUnit.status -ceq 'active' -and [string]$afterState.current_unit -ceq 'unit-correction-001') 'execute changed active/current-unit status'
    Assert-CorrectionTest ((Get-MorphospaceFileSha256 $outPath) -eq $correctionHash) 'transaction did not install the exact correction input'
    Assert-CorrectionTest ([IO.File]::Exists((Join-Path $workspace 'receipts\transactions\unit-correction-001-dependencies-recorded-transition.intent.json'))) 'transaction intent is missing'
    Assert-CorrectionTest ([IO.File]::Exists((Join-Path $workspace 'receipts\transactions\unit-correction-001-dependencies-recorded-transition.completion.json'))) 'transaction completion is missing'
    Assert-CorrectionTest ((Invoke-CorrectionTestGit $repoA @('rev-parse','HEAD')) -ceq $identityA.head -and (Invoke-CorrectionTestGit $repoB @('rev-parse','HEAD')) -ceq $identityB.head) 'execute changed a dependency repository HEAD'

    $staleAfter = Copy-CorrectionTestDocument $correction
    $staleAfter.correction_id = 'unit-correction-001-stale'
    $staleAfterPath = Join-Path $temp 'stale-after.json'; Write-CorrectionTestJson $staleAfterPath $staleAfter
    Assert-CorrectionRejected {
        Invoke-MorphospaceCorrectActiveReadOnlyDependencies -WorkspaceRoot $workspace -UnitId 'unit-correction-001' -RepoMapPath $repoMapPath `
            -ReadOnlyDependencyCorrection $staleAfterPath -OutPath (Join-Path $workspace 'receipts\unit-correction-001-stale.json')
    } 'stale pre-transition CAS was accepted after correction'

    [pscustomobject]@{result='pass';action='CorrectActiveReadOnlyDependencies';transactional=$true;git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false} | ConvertTo-Json -Compress
} finally {
    if ([IO.Directory]::Exists($temp)) {
        foreach ($file in [IO.Directory]::EnumerateFiles($temp,'*',[IO.SearchOption]::AllDirectories)) {
            try { [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal) } catch {}
        }
        [IO.Directory]::Delete($temp,$true)
    }
}
