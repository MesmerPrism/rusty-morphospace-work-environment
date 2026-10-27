param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$ownerRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceUnitDeclaration.psm1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wef-ready-declarations-' + [guid]::NewGuid().ToString('N'))
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
function Assert-DeclarationCase([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:passed++; Write-Output "PASS $Name" }
    else { $script:failures.Add($Name); Write-Output "FAIL $Name" }
}
function Write-DeclarationJson([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 32), [Text.UTF8Encoding]::new($false))
}
function Get-DeclarationFingerprint([string]$Workspace) {
    @((Get-ChildItem -LiteralPath $Workspace -File -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Workspace.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })) -join "`n"
}
function Invoke-DeclarationGit([string[]]$Arguments) {
    $result = @(& git -C $script:sourceRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($result -join ' ')" }
}
function New-DeclarationFixture([string]$Name, [string]$Category = 'implementation', [switch]$Conflict, [string]$Status = 'proposed') {
    $root = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($root)
    $workspace = Join-Path $root 'morphospace'
    Copy-Item -LiteralPath $script:seedWorkspace -Destination $workspace -Recurse
    $unit = [ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_unit.v1'
        unit_id = 'initial-declaration-001'; project_id = 'declaration-test'; status = $Status
        objective = 'Reject malformed initial declarations before owner effects.'
        work_mode = 'feature'
        claim_requirements = [ordered]@{minimum_free_disk_mib=0;required_tools=@();product_inputs=@()}
        change_categories = @($Category)
        instruction_impact = 'none'; instruction_surfaces = @()
        instruction_none_justification = 'This fixture changes no instruction decisions.'
        prerequisites = @()
        allowed_repositories = @([ordered]@{repo_id='project-shell';allowed_paths=@('src/','docs/','morphospace/')})
        non_scope = @('Real repositories, devices and accepted history.')
        acceptance = @([ordered]@{acceptance_id='fixture';proof='Actual owner refuses invalid declarations.';command='Test-ReadyDeclarationConsistency.ps1'})
        risk_tier = 'standard'; device_requirement = 'none'
        validation = @([ordered]@{profile_id='workflow';command='Fixture validation only.'})
        outputs = @('Fixture evidence'); commit_policy = 'Fixture only.'; push_checkpoint = 'local-only'
    }
    if ($Conflict) {
        $unit.read_only_dependencies = @([ordered]@{repo_id='project-shell';paths=@('docs/reference.md');purpose='Read actual available fixture bytes.';verification='Exact fixture source bytes.'})
    }
    Write-DeclarationJson (Join-Path $workspace 'iteration-units/initial-declaration-001.json') $unit
    $map = Join-Path $root 'repository-map.json'
    Write-DeclarationJson $map ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='project-shell';path=$script:sourceRoot;role='source'})})
    [pscustomobject]@{workspace=$workspace;map=$map}
}
try {
    foreach ($name in @('GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES','GIT_CONFIG')) {
        if ([Environment]::GetEnvironmentVariable($name)) { throw "Declaration fixture refuses ambient Git redirection: $name" }
    }
    [void][IO.Directory]::CreateDirectory($testRoot)
    $script:sourceRoot = Join-Path $testRoot 'source'
    [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'docs'))
    [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'src'))
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'docs/reference.md'), "Fixture reference.`n")
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'src/source.txt'), "Fixture source.`n")
    # Every Git write is local to this newly created repository. No persistent
    # user identity, enclosing-worktree config or shared repository is changed.
    Invoke-DeclarationGit @('init','-b','main')
    Invoke-DeclarationGit @('add','docs/reference.md','src/source.txt')
    Invoke-DeclarationGit @('-c','core.hooksPath=','-c','user.name=Workflow Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture source')
    # Scaffold once through the actual owner, then copy this inert empty
    # workspace for independent controls instead of replaying its validation.
    $seedRoot = Join-Path $testRoot 'seed'
    [void][IO.Directory]::CreateDirectory($seedRoot)
    & (Join-Path $PSScriptRoot 'New-ProjectWorkspace.ps1') -ProjectRoot $seedRoot -ProjectId 'declaration-test' -Purpose 'Isolated initial declaration regression.' -Execute | Out-Null
    $script:seedWorkspace = Join-Path $seedRoot 'morphospace'
    foreach ($case in @(
        @{name='unknown-category';category='documentation';conflict=$false;reason='change-category-unknown'},
        @{name='writable-readonly-overlap';category='implementation';conflict=$true;reason='writable-read-only-dependency-conflict'}
    )) {
        foreach ($action in @('Inspect','Ready','Claim')) {
            foreach ($execute in $(if ($action -eq 'Inspect') { @($false) } else { @($false,$true) })) {
                $label = $case.name + '-' + $action.ToLowerInvariant() + '-' + $execute
                # Hand-authored ready status is a negative fixture only. The
                # positive initial-owner control below uses the actual writer.
                $status = if ($action -eq 'Claim') { 'ready' } else { 'proposed' }
                $fixture = New-DeclarationFixture $label $case.category -Conflict:$case.conflict -Status $status
                $before = Get-DeclarationFingerprint $fixture.workspace
                $message = ''; $result = $null
                try {
                    $result = Invoke-MorphospaceWorkUnitAutomation -Action $action -WorkspaceRoot $fixture.workspace -UnitId 'initial-declaration-001' -RepoMapPath $fixture.map -Timestamp '2026-01-02T03:04:05Z' -Execute:$execute
                } catch { $message = $_.Exception.Message }
                if ($action -eq 'Inspect') {
                    $checks = @($result.claim_preflight.coverage.checks | Where-Object check_id -CEQ 'unit-declaration-consistency')
                    $denied = $message -eq '' -and -not $result.claim_preflight.ready_to_claim -and $checks.Count -eq 1 -and $checks[0].outcome -ceq 'fail' -and @($checks[0].reason_codes) -ccontains $case.reason
                } else {
                    $denied = $message -like "$action preflight blocked:*$($case.reason)*"
                }
                Assert-DeclarationCase ($denied -and $before -ceq (Get-DeclarationFingerprint $fixture.workspace)) "$label refuses before any workspace byte changes"
            }
        }
    }
    foreach ($category in @('documentation-only','production-runtime')) {
        $fixture = New-DeclarationFixture ('valid-' + $category) $category
        $ready = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $fixture.workspace -UnitId 'initial-declaration-001' -RepoMapPath $fixture.map -Timestamp '2026-01-02T03:04:05Z' -Execute
        $inspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $fixture.workspace -UnitId 'initial-declaration-001' -RepoMapPath $fixture.map -Timestamp '2026-01-02T03:04:06Z'
        $claim = Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $fixture.workspace -UnitId 'initial-declaration-001' -RepoMapPath $fixture.map -Timestamp '2026-01-02T03:04:07Z' -Execute
        $state = Get-Content (Join-Path $fixture.workspace 'workspace.state.json') -Raw | ConvertFrom-Json
        Assert-DeclarationCase ($ready.transition -ceq 'proposed-to-ready' -and $inspect.claim_preflight.ready_to_claim -and $claim.transition -ceq 'ready-to-active' -and $state.current_unit -ceq 'initial-declaration-001') "canonical/registered category $category uses actual initial Ready and Claim without accepted predecessor"
    }
    # This same writable-row predicate is consumed by workspace validation.
    # Preserve its narrow empty validation-only membership rule.
    foreach ($case in @(
        @{name='validation-only empty membership';mode='validation-only';paths=@();expected=0},
        @{name='feature empty row remains writable';mode='feature';paths=@();expected=1},
        @{name='validation-only nonempty write scope';mode='validation-only';paths=@('src/');expected=1},
        @{name='validation-only null paths are not empty membership';mode='validation-only';paths=$null;expected=1}
    )) {
        $row = [pscustomobject]@{repo_id='project-shell';allowed_paths=$case.paths}
        $actual = @(Get-MorphospaceWritableRepositoryIds -AllowedRepositories @($row) -WorkMode $case.mode)
        Assert-DeclarationCase ($actual.Count -eq $case.expected) $case.name
    }
    if ($failures.Count) { throw "Ready declaration regression: $($failures.Count) failed controls: $($failures -join '; ')" }
    Write-Output "Ready declaration consistency: $passed controls passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wef-ready-declarations-*') { throw 'Unsafe declaration fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
