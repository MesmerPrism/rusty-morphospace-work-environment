param(
    [string]$Path = '',
    [string]$WorkspaceRoot = '',
    [string]$SourceRepository = '',
    [string]$PlanningRepository = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePublishedPlanningAuthorityAdoption.psm1') -Force

function Write-AdoptionTestJson {
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][object]$Value)
    $parent = Split-Path -Parent $Target
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Target, (($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine), $encoding)
}

function Write-AdoptionTestText {
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$Value)
    $parent = Split-Path -Parent $Target
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Target, $Value, [Text.UTF8Encoding]::new($false))
}

function Get-AdoptionTestHash {
    param([Parameter(Mandatory)][string]$Target)
    return (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Copy-AdoptionTestObject {
    param([Parameter(Mandatory)][object]$Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
}

function Invoke-AdoptionTestGit {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Git self-test command failed in '$Repository': git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Assert-AdoptionTestRejected {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Case)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Published planning authority adoption damage case was accepted: $Case" }
}

function Invoke-PublishedPlanningAuthorityAdoptionSelfTest {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-authority-adoption-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
        $sourceRemote = Join-Path $tempRoot 'source-remote.git'
        $sourceRoot = Join-Path $tempRoot 'source'
        $planningRoot = Join-Path $tempRoot 'planning'
        & git init --bare $sourceRemote 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize source remote for adoption self-test.' }
        & git init -b main $sourceRoot 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize source repository for adoption self-test.' }
        Invoke-AdoptionTestGit $sourceRoot @('config', 'user.email', 'fixture@example.invalid') | Out-Null
        Invoke-AdoptionTestGit $sourceRoot @('config', 'user.name', 'Fixture') | Out-Null
        Invoke-AdoptionTestGit $sourceRoot @('config', 'core.autocrlf', 'false') | Out-Null

        Write-AdoptionTestText (Join-Path $sourceRoot 'README.md') "stale source checkpoint`n"
        Invoke-AdoptionTestGit $sourceRoot @('add', 'README.md') | Out-Null
        Invoke-AdoptionTestGit $sourceRoot @('commit', '-m', 'stale source checkpoint') | Out-Null
        $staleRevision = [string](@(Invoke-AdoptionTestGit $sourceRoot @('rev-parse', 'HEAD'))[0])

        Write-AdoptionTestText (Join-Path $sourceRoot 'README.md') "pre-merge source checkpoint`n"
        Invoke-AdoptionTestGit $sourceRoot @('add', 'README.md') | Out-Null
        Invoke-AdoptionTestGit $sourceRoot @('commit', '-m', 'pre-merge source checkpoint') | Out-Null
        $preMergeRevision = [string](@(Invoke-AdoptionTestGit $sourceRoot @('rev-parse', 'HEAD'))[0])

        $workspaceSource = Join-Path $sourceRoot 'morphospace'
        $dirtyFingerprint = 'c' * 64
        $lockFingerprint = 'd' * 64
        $beforeState = [ordered]@{
            schema = 'rusty.morphospace.workflow.workspace_state.v2'
            project_id = 'test-project'
            plan_revision = 7
            current_unit = $null
            next_ready_unit = $null
            last_event_id = 'test-previous-event'
            last_accepted_receipt = 'receipts/test-last-accepted.json'
            repository_heads = @(
                [ordered]@{ repo_id = 'other-repo'; head = ('9' * 40); branch = 'main'; dirty_fingerprint = ('8' * 64) },
                [ordered]@{ repo_id = 'source-repo'; head = $staleRevision; branch = 'codex/stale-work'; dirty_fingerprint = $dirtyFingerprint }
            )
            repository_checkpoints = @(
                [ordered]@{
                    repo_id = 'source-repo'; observed_head = $staleRevision; claimed_head = $null
                    validated_head = $null; accepted_head = $null; composition_fingerprint = $lockFingerprint
                }
            )
            module_registry = [ordered]@{ lock_revision = 3; lock_fingerprint = $lockFingerprint; modules = @() }
            capability_registry = @([ordered]@{ capability_id = 'test.capability'; owner = 'source-repo'; state = 'candidate'; revision = 'v1' })
            dirty_repositories = @('other-repo', 'source-repo')
            blockers = @([ordered]@{ blocker_id = 'historical-evidence'; condition = 'Preserve exact evidence.'; resume_when = 'A separate correction is accepted.' })
            validation_checkpoint = [ordered]@{ tier = 'standard'; receipt = 'receipts/test-validation.json'; result = 'pass' }
            pending_push_bundle = $null
        }
        Write-AdoptionTestJson (Join-Path $workspaceSource 'workspace.state.json') $beforeState
        Write-AdoptionTestJson (Join-Path $workspaceSource 'project.spec.json') ([ordered]@{
            schema = 'rusty.morphospace.workflow.project_spec.v2'; project_id = 'test-project'
        })
        Write-AdoptionTestJson (Join-Path $workspaceSource 'feature.lock.json') ([ordered]@{
            schema = 'rusty.morphospace.workflow.feature_lock.v2'; project_id = 'test-project'
            revision = 3; lock_fingerprint = $lockFingerprint; features = @()
        })
        Write-AdoptionTestText (Join-Path $workspaceSource 'iteration-events.jsonl') (
            '{"schema":"rusty.morphospace.workflow.iteration_event.v1","event_id":"test-previous-event","sequence":1}' + [Environment]::NewLine
        )
        Invoke-AdoptionTestGit $sourceRoot @('add', 'morphospace') | Out-Null
        Invoke-AdoptionTestGit $sourceRoot @('commit', '-m', 'publish embedded planning workspace') | Out-Null
        $publishedRevision = [string](@(Invoke-AdoptionTestGit $sourceRoot @('rev-parse', 'HEAD'))[0])
        $publishedTree = [string](@(Invoke-AdoptionTestGit $sourceRoot @('rev-parse', 'HEAD^{tree}'))[0])
        $embeddedTree = [string](@(Invoke-AdoptionTestGit $sourceRoot @('rev-parse', "$publishedRevision`:morphospace"))[0])
        Invoke-AdoptionTestGit $sourceRoot @('remote', 'add', 'origin', $sourceRemote) | Out-Null
        Invoke-AdoptionTestGit $sourceRoot @('push', '-u', 'origin', 'main') | Out-Null

        & git init -b main $planningRoot 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize local planning repository for adoption self-test.' }
        Invoke-AdoptionTestGit $planningRoot @('config', 'user.email', 'fixture@example.invalid') | Out-Null
        Invoke-AdoptionTestGit $planningRoot @('config', 'user.name', 'Fixture') | Out-Null
        Invoke-AdoptionTestGit $planningRoot @('config', 'core.autocrlf', 'false') | Out-Null
        Write-AdoptionTestText (Join-Path $planningRoot 'README.md') "local-only planning authority`n"
        Invoke-AdoptionTestGit $planningRoot @('add', 'README.md') | Out-Null
        Invoke-AdoptionTestGit $planningRoot @('commit', '-m', 'initialize local planning authority') | Out-Null
        $planningRevision = [string](@(Invoke-AdoptionTestGit $planningRoot @('rev-parse', 'HEAD'))[0])
        $planningTree = [string](@(Invoke-AdoptionTestGit $planningRoot @('rev-parse', 'HEAD^{tree}'))[0])

        $workspace = Join-Path $planningRoot 'projects\test-project\morphospace'
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $workspaceSource -File -Recurse)) {
            $relative = $sourceFile.FullName.Substring($workspaceSource.Length + 1)
            $destination = Join-Path $workspace $relative
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            [IO.File]::Copy($sourceFile.FullName, $destination, $true)
        }
        $receiptRoot = Join-Path $workspace 'receipts'
        [IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
        Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlanningProjection.psm1') -Force
        $inventory = @(Get-GitWorkspaceInventory $sourceRoot $publishedRevision 'morphospace' | ForEach-Object {
            [ordered]@{ path = [string]$_.path; git_mode = [string]$_.git_mode; size = [int64]$_.size; sha256 = [string]$_.sha256 }
        })
        $projectionPath = Join-Path $receiptRoot 'test-projection-v2.json'
        $projection = [ordered]@{
            schema = 'rusty.morphospace.workflow.planning_workspace_projection.v2'
            projection_id = 'test-projection-v2'
            project_id = 'test-project'
            unit_id = 'test-accepted-unit'
            recorded_at = '2026-07-25T00:00:00Z'
            status = 'exact-projection-verified'
            chronology = [ordered]@{
                classification = 'published-embedded-workspace-authority-adoption'
                source_publication_preceded_projection = $true
                prepared_plan_present = $false
                executed_push_receipt_present = $false
                does_not_claim = @('prospective preparation', 'planning-last publication', 'source acceptance', 'Git execution')
            }
            source = [ordered]@{
                repo_id = 'source-repo'; branch = 'main'; remote = 'origin'; remote_ref = 'refs/heads/main'; upstream = 'origin/main'
                old_revision = $preMergeRevision; published_revision = $publishedRevision; observed_remote_revision = $publishedRevision
                embedded_workspace_path = 'morphospace'; embedded_workspace_tree = $embeddedTree
                fast_forward_verified = $true; remote_match = $true; force_push_used = $false
            }
            planning = [ordered]@{
                repo_id = 'planning-repo'; workspace_path = 'projects/test-project/morphospace'
                projection_record_path = 'receipts/test-projection-v2.json'; distinct_from_source = $true
                base_revision = $planningRevision
            }
            inventory = $inventory
            projected_state = [ordered]@{
                current_unit = $null; next_ready_unit = $null; pending_push_bundle = $null
                dirty_repository_ids = @('other-repo', 'source-repo')
                source_repository = [ordered]@{
                    repo_id = 'source-repo'; head = $staleRevision; branch = 'codex/stale-work'; dirty_fingerprint = $dirtyFingerprint
                }
            }
            authority = [ordered]@{
                source_workspace = 'immutable-historical-snapshot'; external_workspace = 'sole-mutable-workflow-authority'
                source_workflow_mutation_performed = $false; git_mutation_performed = $false
                next_transition = 'AdoptPublishedPlanningAuthority'
            }
            failure = $null
        }
        Write-AdoptionTestJson $projectionPath $projection

        $beforePath = Join-Path $receiptRoot 'test-state-before.json'
        [IO.File]::Copy((Join-Path $workspace 'workspace.state.json'), $beforePath, $true)
        $afterState = Copy-AdoptionTestObject $beforeState
        $afterState.dirty_repositories = @('other-repo')
        $afterState.last_event_id = 'test-accepted-unit-planning-authority-adopted-0002'
        $afterSource = @($afterState.repository_heads | Where-Object { [string]$_.repo_id -ceq 'source-repo' })[0]
        $afterSource.head = $publishedRevision
        $afterSource.branch = 'main'
        $afterSource.dirty_fingerprint = $null
        $afterPath = Join-Path $receiptRoot 'test-state-after.json'
        Write-AdoptionTestJson $afterPath $afterState
        $validationPath = Join-Path $receiptRoot 'test-validation.json'
        $observerPath = Join-Path $receiptRoot 'test-observer.json'
        Write-AdoptionTestJson $validationPath ([ordered]@{ schema = 'test.validation.v1'; status = 'pass'; revision = $publishedRevision })
        Write-AdoptionTestJson $observerPath ([ordered]@{ schema = 'test.observer.v1'; observed_revision = $publishedRevision })

        $beforeBinding = [ordered]@{
            path = 'receipts/test-state-before.json'; sha256 = Get-AdoptionTestHash $beforePath
            current_unit = $null; next_ready_unit = $null; pending_push_bundle = $null
            dirty_repository_ids = @('other-repo', 'source-repo')
            source_repository = [ordered]@{
                repo_id = 'source-repo'; head = $staleRevision; branch = 'codex/stale-work'; dirty_fingerprint = $dirtyFingerprint
            }
        }
        $afterBinding = [ordered]@{
            path = 'receipts/test-state-after.json'; sha256 = Get-AdoptionTestHash $afterPath
            current_unit = $null; next_ready_unit = $null; pending_push_bundle = $null
            dirty_repository_ids = @('other-repo')
            source_repository = [ordered]@{
                repo_id = 'source-repo'; head = $publishedRevision; branch = 'main'; dirty_fingerprint = $null
            }
        }
        $adoption = [ordered]@{
            schema = 'rusty.morphospace.workflow.published_planning_authority_adoption.v1'
            adoption_id = 'test-published-planning-authority-adoption'
            project_id = 'test-project'
            recorded_at = '2026-07-25T00:01:00Z'
            status = 'published-planning-authority-adopted'
            planning_workspace_projection = [ordered]@{
                path = 'receipts/test-projection-v2.json'; projection_id = 'test-projection-v2'
                sha256 = Get-AdoptionTestHash $projectionPath
            }
            workspace_state_before = $beforeBinding
            workspace_state_after = $afterBinding
            source_publication = [ordered]@{
                repo_id = 'source-repo'; branch = 'main'; remote = 'origin'; remote_ref = 'refs/heads/main'; upstream = 'origin/main'
                pre_merge_revision = $preMergeRevision; published_revision = $publishedRevision; readback_revision = $publishedRevision
                published_tree = $publishedTree; worktree_clean = $true; synchronized = $true
                fast_forward_verified = $true; remote_match = $true; force_push_used = $false; history_rewrite_used = $false
            }
            planning_repository = [ordered]@{
                repo_id = 'planning-repo'; branch = 'main'; head_revision = $planningRevision; head_tree = $planningTree
                workspace_path = 'projects/test-project/morphospace'; distinct_from_source = $true
                remote_configured = $false; unrelated_worktree_clean = $true
            }
            validation = @([ordered]@{
                gate_id = 'published-source-readback'; status = 'pass'
                evidence = [ordered]@{ path = 'receipts/test-validation.json'; sha256 = Get-AdoptionTestHash $validationPath }
            })
            observers = @([ordered]@{
                observer_id = 'external-coordinator'; recorded_at = '2026-07-25T00:01:00Z'
                evidence = [ordered]@{ path = 'receipts/test-observer.json'; sha256 = Get-AdoptionTestHash $observerPath }
            })
            state_delta = [ordered]@{
                cleared_dirty_repository_id = 'source-repo'
                dirty_repository_ids_before = @('other-repo', 'source-repo')
                dirty_repository_ids_after = @('other-repo')
                repository_before = $beforeBinding.source_repository
                repository_after = $afterBinding.source_repository
                last_event_id_before = 'test-previous-event'
                last_event_id_after = 'test-accepted-unit-planning-authority-adopted-0002'
                preserved_fields = @(
                    'blockers', 'capability_registry', 'current_unit', 'last_accepted_receipt',
                    'module_registry', 'next_ready_unit', 'pending_push_bundle', 'plan_revision',
                    'project_id', 'repository_checkpoints', 'unrelated_repository_heads',
                    'validation_checkpoint'
                )
            }
            nonclaims = [ordered]@{
                external_planning_authority_existed_at_publication = $false
                prepared_plan_or_executed_push_reconstructed = $false
                source_acceptance_created = $false
                git_or_remote_mutation_performed = $false
                force_push_or_history_rewrite_used = $false
                unrelated_dirty_repositories_cleared = $false
            }
            failure = $null
        }
        $adoptionPath = Join-Path $receiptRoot 'test-adoption.json'
        Write-AdoptionTestJson $adoptionPath $adoption
        $live = Test-MorphospacePublishedPlanningAuthorityAdoptionLive `
            -Path $adoptionPath -WorkspaceRoot $workspace -SourceRepository $sourceRoot -PlanningRepository $planningRoot
        if ([string]$live.source_revision -cne $publishedRevision -or
            [string]$live.planning_revision -cne $planningRevision -or
            [string]$live.cleared_dirty_repository_id -cne 'source-repo' -or
            $live.planning_remote_configured -ne $false) {
            throw 'Published planning authority adoption live result omitted an exact authority binding.'
        }

        $outsideBadPath = Join-Path $tempRoot 'bad-adoption.json'
        $bad = Copy-AdoptionTestObject $adoption
        $bad.workspace_state_before.current_unit = 'unexpected-unit'
        Write-AdoptionTestJson $outsideBadPath $bad
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionDocument $outsideBadPath $workspace
        } 'non-null projected current unit'

        [IO.File]::WriteAllBytes($outsideBadPath, [byte[]]@(0x7b, 0x22, 0xff, 0x22, 0x3a, 0x31, 0x7d))
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionDocument $outsideBadPath $workspace
        } 'malformed UTF-8 adoption document'

        $bad = Copy-AdoptionTestObject $adoption
        $bad.recorded_at = '2026-02-30T00:01:00Z'
        Write-AdoptionTestJson $outsideBadPath $bad
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionDocument $outsideBadPath $workspace
        } 'semantically invalid adoption timestamp'

        $bad = Copy-AdoptionTestObject $adoption
        $bad.observers[0].recorded_at = '2026-07-25 00:01:00Z'
        Write-AdoptionTestJson $outsideBadPath $bad
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionDocument $outsideBadPath $workspace
        } 'noncanonical observer timestamp'

        $badAfterPath = Join-Path $receiptRoot 'bad-state-after.json'
        $badAfter = Copy-AdoptionTestObject $afterState
        $badAfter.blockers[0].condition = 'Illegally changed blocker.'
        Write-AdoptionTestJson $badAfterPath $badAfter
        $bad = Copy-AdoptionTestObject $adoption
        $bad.workspace_state_after.path = 'receipts/bad-state-after.json'
        $bad.workspace_state_after.sha256 = Get-AdoptionTestHash $badAfterPath
        Write-AdoptionTestJson $outsideBadPath $bad
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionDocument $outsideBadPath $workspace
        } 'unrelated blocker mutation'
        Remove-Item -LiteralPath $badAfterPath -Force

        $bad = Copy-AdoptionTestObject $adoption
        $bad.observers = @()
        Write-AdoptionTestJson $outsideBadPath $bad
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionDocument $outsideBadPath $workspace
        } 'missing observer'

        $bad = Copy-AdoptionTestObject $adoption
        $bad.nonclaims.git_or_remote_mutation_performed = $true
        Write-AdoptionTestJson $outsideBadPath $bad
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionDocument $outsideBadPath $workspace
        } 'Git mutation claim'

        Write-AdoptionTestText (Join-Path $sourceRoot 'unrelated.txt') "dirty`n"
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionLive $adoptionPath $workspace $sourceRoot $planningRoot
        } 'dirty source worktree'
        Remove-Item -LiteralPath (Join-Path $sourceRoot 'unrelated.txt') -Force

        Write-AdoptionTestText (Join-Path $planningRoot 'unrelated.txt') "dirty`n"
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionLive $adoptionPath $workspace $sourceRoot $planningRoot
        } 'unrelated local planning dirt'
        Remove-Item -LiteralPath (Join-Path $planningRoot 'unrelated.txt') -Force

        $featureLockPath = Join-Path $workspace 'feature.lock.json'
        $featureLockBytes = [IO.File]::ReadAllBytes($featureLockPath)
        [IO.File]::AppendAllText($featureLockPath, "tampered`n", [Text.UTF8Encoding]::new($false))
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionLive $adoptionPath $workspace $sourceRoot $planningRoot
        } 'tampered projected non-state byte'
        [IO.File]::WriteAllBytes($featureLockPath, $featureLockBytes)

        $liveStatePath = Join-Path $workspace 'workspace.state.json'
        $liveStateBytes = [IO.File]::ReadAllBytes($liveStatePath)
        [IO.File]::Copy($afterPath, $liveStatePath, $true)
        Assert-AdoptionTestRejected {
            Test-MorphospacePublishedPlanningAuthorityAdoptionLive $adoptionPath $workspace $sourceRoot $planningRoot
        } 'replayed adoption after state already applied'
        [IO.File]::WriteAllBytes($liveStatePath, $liveStateBytes)

        Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\schemas\published-planning-authority-adoption.schema.json') -Raw | ConvertFrom-Json | Out-Null
        Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\templates\published-planning-authority-adoption.example.json') -Raw | ConvertFrom-Json | Out-Null
        Write-Host 'Published planning authority adoption self-test passed.'
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $tempRoot).Path)
            $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Refusing to remove an adoption self-test directory outside the system temporary directory.'
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

if ($SelfTest) {
    Invoke-PublishedPlanningAuthorityAdoptionSelfTest
    return
}
if (-not $Path -or -not $WorkspaceRoot -or -not $SourceRepository -or -not $PlanningRepository) {
    throw 'Path, WorkspaceRoot, SourceRepository, and PlanningRepository are required unless -SelfTest is used.'
}
Test-MorphospacePublishedPlanningAuthorityAdoptionLive `
    -Path $Path -WorkspaceRoot $WorkspaceRoot -SourceRepository $SourceRepository -PlanningRepository $PlanningRepository |
    ConvertTo-Json -Depth 100
