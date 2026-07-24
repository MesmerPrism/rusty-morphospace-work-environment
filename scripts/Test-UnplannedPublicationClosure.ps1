param(
    [string]$Path = "",
    [string]$WorkspaceRoot = "",
    [string]$RepoMapPath = "",
    [string]$UnitId = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePublicationRecovery.psm1') -Force

function Write-PublicationRecoveryTestJson {
    param([string]$Target, [object]$Value)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Target, (($Value | ConvertTo-Json -Depth 32) + [Environment]::NewLine), $encoding)
}

function Invoke-PublicationRecoverySelfTest {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("morphospace-publication-recovery-" + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.Directory]::CreateDirectory((Join-Path $tempRoot 'receipts')) | Out-Null
        $statePath = Join-Path $tempRoot 'workspace.state.json'
        $validationPath = Join-Path $tempRoot 'receipts\validation.json'
        Write-PublicationRecoveryTestJson -Target $statePath -Value ([ordered]@{ schema = 'test-state'; current_unit = $null })
        Write-PublicationRecoveryTestJson -Target $validationPath -Value ([ordered]@{ schema = 'test-validation'; result = 'pass' })
        $stateHash = Get-MorphospacePublicationRecoverySha256 -Path $statePath
        $validationHash = Get-MorphospacePublicationRecoverySha256 -Path $validationPath
        $closurePath = Join-Path $tempRoot 'receipts\closure.json'
        $closure = [ordered]@{
            schema = 'rusty.morphospace.workflow.unplanned_publication_closure.v1'
            closure_id = 'unit-test-unplanned-publication-closure'
            project_id = 'test-project'
            unit_id = 'unit-test'
            recorded_at = '2026-01-02T03:04:05Z'
            status = 'independent-reconstruction-verified'
            chronology = [ordered]@{
                classification = 'unplanned-push-before-prepare'
                prepared_plan_present = $false
                executed_push_receipt_present = $false
                does_not_claim = @('No pre-push plan is claimed.')
            }
            workspace_state_before = [ordered]@{ path = 'workspace.state.json'; sha256 = $stateHash }
            repository = [ordered]@{
                repo_id = 'source-owner'; role = 'source-owner'; branch = 'codex/test'; remote = 'origin'; upstream = 'origin/codex/test'; action = 'pushed'
                old_revision = ('1' * 40); new_revision = ('2' * 40); observed_remote_revision = ('2' * 40); rollback_revision = ('1' * 40)
                fast_forward_verified = $true; remote_match = $true; force_push_used = $false; worktree_clean = $true
                validation_refs = @('standard-validation')
            }
            validation = @([ordered]@{
                gate_id = 'standard-validation'; status = 'pass'
                evidence = [ordered]@{ path = 'receipts/validation.json'; sha256 = $validationHash }
            })
            observers = @([ordered]@{ observer_id = 'external-coordinator'; recorded_at = '2026-01-02T03:04:05Z'; evidence_sha256 = ('3' * 64) })
            workspace_transition = [ordered]@{
                pending_push_bundle_before = 'older-unit-push-bundle'; pending_push_bundle_after = $null
                dirty_repository_ids_to_clear = @('source-owner'); repository_head_after = ('2' * 40)
            }
            remote_readback_complete = $true; recovery_scope = 'workflow-state-only'; failure = $null
        }
        Write-PublicationRecoveryTestJson -Target $closurePath -Value $closure
        $valid = Test-MorphospaceUnplannedPublicationClosureDocument -Path $closurePath -WorkspaceRoot $tempRoot
        if ([string]$valid.document.closure_id -cne 'unit-test-unplanned-publication-closure') { throw 'Valid closure was not accepted.' }
        $projectionPath = Join-Path $tempRoot 'receipts/projection.json'
        $projection = [ordered]@{
            schema='rusty.morphospace.workflow.planning_workspace_projection.v1';projection_id='unit-test-planning-projection';project_id='test-project';unit_id='unit-test';recorded_at='2026-01-02T03:04:05Z';status='exact-projection-verified'
            chronology=[ordered]@{classification='embedded-workspace-projected-after-source-publication';source_publication_preceded_projection=$true;prepared_plan_present=$false;executed_push_receipt_present=$false;does_not_claim=@('prospective preparation','planning-last publication','source acceptance','Git execution')}
            source=[ordered]@{repo_id='source-owner';branch='codex/test';remote='origin';remote_ref='refs/heads/codex/test';upstream='origin/codex/test';old_revision=('1'*40);published_revision=('2'*40);observed_remote_revision=('2'*40);embedded_workspace_path='morphospace';embedded_workspace_tree=('4'*40);fast_forward_verified=$true;remote_match=$true;force_push_used=$false}
            planning=[ordered]@{repo_id='external-planning';workspace_path='projects/test-project/morphospace';projection_record_path='receipts/projection.json';distinct_from_source=$true;base_revision=$null}
            inventory=@(
                [ordered]@{path='feature.lock.json';git_mode='100644';size=1;sha256=('4'*64)},
                [ordered]@{path='iteration-events.jsonl';git_mode='100644';size=1;sha256=('5'*64)},
                [ordered]@{path='project.spec.json';git_mode='100644';size=1;sha256=('6'*64)},
                [ordered]@{path='workspace.state.json';git_mode='100644';size=1;sha256=('7'*64)}
            )
            authority=[ordered]@{source_workspace='immutable-historical-snapshot';external_workspace='sole-mutable-workflow-authority';source_workflow_mutation_performed=$false;git_mutation_performed=$false;next_transition='ReconcilePublication'};failure=$null
        }
        Write-PublicationRecoveryTestJson -Target $projectionPath -Value $projection
        $closure.schema='rusty.morphospace.workflow.unplanned_publication_closure.v2'
        $closure|Add-Member -NotePropertyName planning_workspace_projection -NotePropertyValue ([pscustomobject]@{path='receipts/projection.json';sha256=(Get-FileHash $projectionPath -Algorithm SHA256).Hash.ToLowerInvariant()})
        Write-PublicationRecoveryTestJson -Target $closurePath -Value $closure
        Test-MorphospaceUnplannedPublicationClosureDocument -Path $closurePath -WorkspaceRoot $tempRoot | Out-Null
        $closure.schema='rusty.morphospace.workflow.unplanned_publication_closure.v1';$closure.Remove('planning_workspace_projection')
        Write-PublicationRecoveryTestJson -Target $closurePath -Value $closure
        Write-PublicationRecoveryTestJson -Target $validationPath -Value ([ordered]@{ schema = 'test-validation'; result = 'tampered' })
        $tamperRejected = $false
        try { Test-MorphospaceUnplannedPublicationClosureDocument -Path $closurePath -WorkspaceRoot $tempRoot | Out-Null }
        catch { $tamperRejected = $true }
        if (-not $tamperRejected) { throw 'Tampered validation evidence was accepted.' }
        Write-Host 'Unplanned-publication closure self-test passed.'
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            $resolved = (Resolve-Path -LiteralPath $tempRoot).Path
            $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
            if (-not $resolved.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Refusing to remove a self-test directory outside the system temporary directory.'
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

if ($SelfTest) {
    Invoke-PublicationRecoverySelfTest
    return
}
if (-not $Path -or -not $WorkspaceRoot) {
    throw 'Path and WorkspaceRoot are required unless -SelfTest is used.'
}

$validated = Test-MorphospaceUnplannedPublicationClosureDocument -Path $Path -WorkspaceRoot $WorkspaceRoot
if ($RepoMapPath) {
    if (-not $UnitId) { $UnitId = [string]$validated.document.unit_id }
    Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePublicationRecovery.psm1') -Force
    $spec = Get-Content -LiteralPath (Join-Path $WorkspaceRoot 'project.spec.json') -Raw | ConvertFrom-Json
    $state = Get-Content -LiteralPath (Join-Path $WorkspaceRoot 'workspace.state.json') -Raw | ConvertFrom-Json
    $unit = Get-Content -LiteralPath (Join-Path $WorkspaceRoot "iteration-units\$UnitId.json") -Raw | ConvertFrom-Json
    $mapDocument = Get-Content -LiteralPath $RepoMapPath -Raw | ConvertFrom-Json
    $map = @{}
    $states = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($mapDocument.repositories)) { $map[[string]$entry.repo_id] = $entry }
    foreach ($repo in @($unit.allowed_repositories)) {
        $repoId = [string]$repo.repo_id
        if ($map.ContainsKey($repoId)) { $states.Add((Get-MorphospaceRepositoryState -RepoId $repoId -Path ([string]$map[$repoId].path))) | Out-Null }
    }
    $validated = Test-MorphospaceUnplannedPublicationClosureLive -Path $Path -WorkspaceRoot $WorkspaceRoot -Spec $spec -Unit $unit -State $state -RepositoryMap $map -RepositoryStates @($states.ToArray())
}
$validated | ConvertTo-Json -Depth 32
