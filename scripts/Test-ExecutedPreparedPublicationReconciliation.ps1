param([string]$Path = '',[string]$WorkspaceRoot = '',[switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceExecutedPreparedPublication.psm1') -Force

function Write-ReconciliationJson([string]$Target,$Value) {
    $parent = Split-Path -Parent $Target
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Target,(($Value | ConvertTo-Json -Depth 64) + "`n"),[Text.UTF8Encoding]::new($false))
}
function Get-ReconciliationFileHash([string]$Target) { (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant() }
function Invoke-ReconciliationGit([string]$Repository,[string[]]$Arguments) {
    $output = @(& git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
    if ($output.Count) { ([string]($output | Select-Object -Last 1)).Trim() } else { '' }
}
function New-ReconciliationRepository([string]$Root,[string]$Branch) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Invoke-ReconciliationGit $Root @('init','-q') | Out-Null
    Invoke-ReconciliationGit $Root @('config','user.email','fixture@example.invalid') | Out-Null
    Invoke-ReconciliationGit $Root @('config','user.name','Fixture') | Out-Null
    Invoke-ReconciliationGit $Root @('config','core.autocrlf','false') | Out-Null
    Invoke-ReconciliationGit $Root @('checkout','-q','-b',$Branch) | Out-Null
    [IO.File]::WriteAllText((Join-Path $Root 'base.txt'),"base`n",[Text.UTF8Encoding]::new($false))
    Invoke-ReconciliationGit $Root @('add','.') | Out-Null
    Invoke-ReconciliationGit $Root @('commit','-q','-m','base') | Out-Null
    Invoke-ReconciliationGit $Root @('rev-parse','HEAD')
}
function New-FileBinding([string]$Workspace,[string]$Relative) {
    $absolute = Join-Path $Workspace ($Relative -replace '/','\')
    [ordered]@{ path = $Relative; sha256 = Get-ReconciliationFileHash $absolute }
}
function New-PathBinding([string[]]$Paths) {
    $set = Get-ExecutedPreparedPublicationPathSet $Paths
    [ordered]@{ count = $set.count; sha256 = $set.sha256 }
}
function Get-CommitPaths([string]$Repository,[string]$Old,[string]$Final) {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($commit in @(& git -C $Repository rev-list --reverse "$Old..$Final")) {
        foreach ($item in @(& git -C $Repository diff-tree --no-commit-id --name-only -r $commit)) { if ($item) { $paths.Add([string]$item) } }
    }
    @($paths)
}
function Copy-Value($Value) { $Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json }
function Assert-Rejected([scriptblock]$Action,[string]$Name) {
    try { & $Action | Out-Null } catch { return }
    throw "Damaged executed prepared-publication case '$Name' was accepted."
}

if ($SelfTest) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('executed-prepared-publication-' + [guid]::NewGuid().ToString('N'))
    $source = Join-Path $root 'source'
    $merge = Join-Path $root 'merge'
    $planning = Join-Path $root 'planning'
    $workspace = Join-Path $planning 'project\morphospace'
    try {
        $sourceBranch = 'codex/source-fixture'
        $mergeBranch = 'codex/merge-fixture'
        $planningBranch = 'codex/planning-fixture'
        $sourceOld = New-ReconciliationRepository $source $sourceBranch
        [IO.File]::WriteAllText((Join-Path $source 'source.txt'),"source`n",[Text.UTF8Encoding]::new($false))
        Invoke-ReconciliationGit $source @('add','source.txt') | Out-Null
        Invoke-ReconciliationGit $source @('commit','-q','-m','source change') | Out-Null
        $sourceFinal = Invoke-ReconciliationGit $source @('rev-parse','HEAD')

        $mergeBase = New-ReconciliationRepository $merge $mergeBranch
        [IO.File]::WriteAllText((Join-Path $merge 'skill.txt'),"side`n",[Text.UTF8Encoding]::new($false))
        Invoke-ReconciliationGit $merge @('add','skill.txt') | Out-Null
        Invoke-ReconciliationGit $merge @('commit','-q','-m','side change') | Out-Null
        $mergeSide = Invoke-ReconciliationGit $merge @('rev-parse','HEAD')
        Invoke-ReconciliationGit $merge @('checkout','-q','-b','protected-fixture',$mergeBase) | Out-Null
        [IO.File]::WriteAllText((Join-Path $merge 'protected.txt'),"protected`n",[Text.UTF8Encoding]::new($false))
        Invoke-ReconciliationGit $merge @('add','protected.txt') | Out-Null
        Invoke-ReconciliationGit $merge @('commit','-q','-m','protected change') | Out-Null
        $mergeProtected = Invoke-ReconciliationGit $merge @('rev-parse','HEAD')
        Invoke-ReconciliationGit $merge @('checkout','-q',$mergeBranch) | Out-Null
        Invoke-ReconciliationGit $merge @('merge','-q','--no-ff','protected-fixture','-m','merge protected') | Out-Null
        $mergeFinal = Invoke-ReconciliationGit $merge @('rev-parse','HEAD')

        $planningOld = New-ReconciliationRepository $planning $planningBranch
        New-Item -ItemType Directory -Path $workspace -Force | Out-Null
        $spec = [ordered]@{
            '$schema'='../../schemas/project-spec-v2.schema.json'; schema='rusty.morphospace.workflow.project_spec.v2'; project_id='fixture-project'; revision=1; owner='fixture'; purpose='Executed prepared-publication reconciliation fixture.'
            activation_model=[ordered]@{default='disabled';unlisted_modules='inert';runtime_rule='selected-lock-and-runtime-input'}
            composition=[ordered]@{selected_features=@();denied_features=@();selected_modules=@();denied_modules=@();allowed_permissions=@();denied_permissions=@();data_classes=@()}
            authority_map=@(); repositories=@(
                [ordered]@{repo_id='source-repo';role='source';path=$source;allowed_paths=@('source.txt')},
                [ordered]@{repo_id='merge-repo';role='source';path=$merge;allowed_paths=@('skill.txt')}
            ); modules=@(); non_scope=@('Real repositories.'); validation_profiles=@(); acceptance_profiles=@()
            release_policy=[ordered]@{versioning='semver';commit_policy='Fixture only.';push_checkpoint='integration-batch';source_first=$true;planning_last=$true;force_push_allowed=$false}
            public_boundary=[ordered]@{mode='mixed';private_overlay='local/';prohibited_evidence=@()}
        }
        $lock = [ordered]@{'$schema'='../../schemas/feature-lock-v2.schema.json';schema='rusty.morphospace.workflow.feature_lock.v2';project_id='fixture-project';project_revision=1;revision=1;generated_at='1970-01-01T00:00:00Z';resolver_version='fixture';lock_fingerprint=('4'*64);default_activation='disabled';activation_rule='selected-lock-and-runtime-input';selected_features=@();denied_features=@();features=@();effect_union=[ordered]@{permissions=@();services=@();activities=@();queries=@();tools=@();assets=@();shaders=@();native_libraries=@();commands=@();routes=@();streams=@();inputs=@();scenes=@();markers=@()}}
        $unit = [ordered]@{'$schema'='../schemas/iteration-unit.schema.json';schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id='fixture-unit';project_id='fixture-project';status='accepted';objective='Reconcile exact immutable publication evidence.';change_categories=@('workflow');instruction_impact='none';instruction_surfaces=@();instruction_none_justification='Fixture only.';prerequisites=@();allowed_repositories=@([ordered]@{repo_id='source-repo';allowed_paths=@('source.txt')},[ordered]@{repo_id='merge-repo';allowed_paths=@('skill.txt')});non_scope=@('Real publication.');acceptance=@([ordered]@{acceptance_id='fixture';proof='Fixture passes.';command='Test-ExecutedPreparedPublicationReconciliation.ps1 -SelfTest'});risk_tier='standard';device_requirement='none';validation=@([ordered]@{profile_id='workflow';command='fixture'});outputs=@('reconciliation');commit_policy='Fixture only.';push_checkpoint='integration-batch'}
        $state = [ordered]@{'$schema'='../../schemas/workspace-state-v2.schema.json';schema='rusty.morphospace.workflow.workspace_state.v2';project_id='fixture-project';plan_revision=1;current_unit=$null;next_ready_unit=$null;last_event_id='fixture-unit-push-prepared-0001';last_accepted_receipt='receipts/fixture-validation.json';repository_heads=@();repository_checkpoints=@();module_registry=[ordered]@{lock_revision=1;lock_fingerprint=('4'*64);modules=@()};capability_registry=@();dirty_repositories=@();blockers=@();validation_checkpoint=[ordered]@{receipt='receipts/fixture-validation.json';result='pass';tier='standard'};pending_push_bundle=[ordered]@{bundle_id='fixture-unit-push-bundle';planning_transport_repo_id='planning-repo';ready=$true;repo_ids=@('source-repo','merge-repo','planning-repo');unit_ids=@('fixture-unit')}}
        Write-ReconciliationJson (Join-Path $workspace 'project.spec.json') $spec
        Write-ReconciliationJson (Join-Path $workspace 'feature.lock.json') $lock
        Write-ReconciliationJson (Join-Path $workspace 'iteration-units\fixture-unit.json') $unit
        Write-ReconciliationJson (Join-Path $workspace 'workspace.state.json') $state
        Write-ReconciliationJson (Join-Path $workspace 'receipts\fixture-validation.json') ([ordered]@{schema='fixture';result='pass'})
        [IO.File]::WriteAllText((Join-Path $workspace 'seed.txt'),"seed`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'),'',[Text.UTF8Encoding]::new($false))
        Invoke-ReconciliationGit $planning @('add','project') | Out-Null
        Invoke-ReconciliationGit $planning @('commit','-q','-m','prepared planning snapshot') | Out-Null
        $planningPlanned = Invoke-ReconciliationGit $planning @('rev-parse','HEAD')

        $planRelative = 'receipts/fixture-prepare-push.json'
        $intentRelative = 'receipts/transactions/fixture-unit-push-prepared-0001-transition.intent.json'
        $completionRelative = 'receipts/transactions/fixture-unit-push-prepared-0001-transition.completion.json'
        $executedRelative = 'receipts/fixture-executed-push.json'
        $reconciliationRelative = 'receipts/fixture-executed-prepared-reconciliation.json'
        $preparedAt = '2026-01-01T00:02:00Z'
        $plan = [ordered]@{schema='rusty.morphospace.workflow.push_bundle_plan.v1';bundle_id='fixture-unit-push-bundle';project_id='fixture-project';unit_ids=@('fixture-unit');prepared_at=$preparedAt;dependency_order=@('source-repo','merge-repo','planning-repo');repositories=@(
            [ordered]@{repo_id='source-repo';role='source';branch=$sourceBranch;commit=$sourceFinal;upstream=$null;ahead=$null;behind=$null},
            [ordered]@{repo_id='merge-repo';role='source';branch=$mergeBranch;commit=$mergeFinal;upstream=$null;ahead=$null;behind=$null},
            [ordered]@{repo_id='planning-repo';role='planning';branch=$planningBranch;commit=$planningPlanned;upstream=$null;ahead=$null;behind=$null}
        );source_first=$true;planning_last=$true;execution='not-performed';force_push_allowed=$false;publication_ordering_interruption=$null}
        $owner = [ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v1';project_id='fixture-project';unit_id='fixture-unit';action='PreparePush';timestamp=$preparedAt;executed=$true;transition='push-bundle-prepared';event_id='fixture-unit-push-prepared-0001';push_plan=$plan}
        Write-ReconciliationJson (Join-Path $workspace ($planRelative -replace '/','\')) $owner
        $event = [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='fixture-unit-push-prepared-0001';sequence=1;timestamp=$preparedAt;project_id='fixture-project';unit_id='fixture-unit';event_type='commit';summary='Prepared fixture plan.';receipts=@($planRelative)}
        $intent = [ordered]@{schema='rusty.morphospace.workflow.transition_ledger_intent.v1';transaction_id='fixture-unit-push-prepared-0001-transition';event=$event}
        Write-ReconciliationJson (Join-Path $workspace ($intentRelative -replace '/','\')) $intent
        $completion = [ordered]@{schema='rusty.morphospace.workflow.transition_ledger_completion.v1';transaction_id='fixture-unit-push-prepared-0001-transition';status='committed';event_id=$event.event_id;completed_at='2026-01-01T00:02:01Z';state_sha256=('1'*64);unit_sha256=('2'*64);intent=[ordered]@{path=$intentRelative;role='transition-ledger-intent';schema='rusty.morphospace.workflow.transition_ledger_intent.v1';sha256=Get-ReconciliationFileHash (Join-Path $workspace ($intentRelative -replace '/','\'))}}
        Write-ReconciliationJson (Join-Path $workspace ($completionRelative -replace '/','\')) $completion
        [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'),(($event|ConvertTo-Json -Depth 16 -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        Invoke-ReconciliationGit $planning @('add','project') | Out-Null
        Invoke-ReconciliationGit $planning @('commit','-q','-m','record prepared fixture') | Out-Null
        $planningFinal = Invoke-ReconciliationGit $planning @('rev-parse','HEAD')

        $repositories = @(
            [ordered]@{id='source-repo';repo=$source;branch=$sourceBranch;old=$sourceOld;planned=$sourceFinal;final=$sourceFinal;role='source';mode='linear'},
            [ordered]@{id='merge-repo';repo=$merge;branch=$mergeBranch;old=$mergeProtected;planned=$mergeFinal;final=$mergeFinal;role='source';mode='merge-integration'},
            [ordered]@{id='planning-repo';repo=$planning;branch=$planningBranch;old=$planningOld;planned=$planningPlanned;final=$planningFinal;role='planning';mode='linear'}
        )
        foreach ($repository in $repositories) {
            Invoke-ReconciliationGit $repository.repo @('remote','add','origin',$repository.repo) | Out-Null
            Invoke-ReconciliationGit $repository.repo @('update-ref',"refs/remotes/origin/$($repository.branch)",$repository.final) | Out-Null
            Invoke-ReconciliationGit $repository.repo @('branch','--set-upstream-to',"origin/$($repository.branch)",$repository.branch) | Out-Null
        }
        $executed = [ordered]@{'$schema'='../schemas/executed-push-receipt.schema.json';schema='rusty.morphospace.workflow.executed_push_receipt.v1';receipt_id='fixture-executed-push';bundle_id='fixture-unit-push-bundle';project_id='fixture-project';unit_ids=@('fixture-unit');prepared_plan_id='fixture-unit-push-bundle';started_at='2026-01-01T00:01:00Z';finished_at='2026-01-01T00:01:30Z';status='validated-pushed';execution='externally-performed';dependency_order=@('source-repo','merge-repo','planning-repo');execution_order=@('source-repo','merge-repo','planning-repo');repositories=@($repositories|ForEach-Object{[ordered]@{ref_id=$_.id;repo_id=$_.id;role=if($_.role-eq'planning'){'planning'}else{'source-owner'};branch=$_.branch;remote='origin';upstream="origin/$($_.branch)";action='pushed';old_revision=$_.old;new_revision=$_.final;observed_remote_revision=$_.final;push_status='pass';ancestry_verified=$true;remote_match=$true;force_push_used=$false;validation_refs=@('fixture-validation');rollback_revision=$_.old}});validation=@([ordered]@{gate_id='fixture-validation';status='pass';evidence=[ordered]@{path='receipts/fixture-validation.json';sha256=Get-ReconciliationFileHash (Join-Path $workspace 'receipts\fixture-validation.json')}});rollback=[ordered]@{strategy='fixture';reverse_dependency_order=@('planning-repo','merge-repo','source-repo');points=@($repositories|ForEach-Object{[ordered]@{ref_id=$_.id;rollback_revision=$_.old;acceptance='Fixture rollback.'}})};source_first=$true;planning_last=$true;force_push_used=$false;remote_readback_complete=$true;failure=$null}
        Write-ReconciliationJson (Join-Path $workspace ($executedRelative -replace '/','\')) $executed

        $repoEvidence = @()
        foreach ($repository in $repositories) {
            $paths = Get-CommitPaths $repository.repo $repository.old $repository.final
            $history = [ordered]@{mode=$repository.mode;commit_count=@(& git -C $repository.repo rev-list --reverse "$($repository.old)..$($repository.final)").Count;changed_path_count=(Get-ExecutedPreparedPublicationPathSet $paths).count;changed_paths_sha256=(Get-ExecutedPreparedPublicationPathSet $paths).sha256;merge_integration=$null}
            if ($repository.mode -eq 'merge-integration') {
                $history.merge_integration = [ordered]@{
                    base_revision=$mergeBase;base_tree=Invoke-ReconciliationGit $merge @('rev-parse',"$mergeBase^{tree}")
                    side_parent=$mergeSide;side_parent_tree=Invoke-ReconciliationGit $merge @('rev-parse',"$mergeSide^{tree}")
                    protected_parent=$mergeProtected;protected_parent_tree=Invoke-ReconciliationGit $merge @('rev-parse',"$mergeProtected^{tree}")
                    ordered_parents=@($mergeSide,$mergeProtected)
                    side_delta=New-PathBinding @(& git -C $merge diff --name-only $mergeBase $mergeSide)
                    protected_delta=New-PathBinding @(& git -C $merge diff --name-only $mergeBase $mergeProtected)
                    final_delta_against_protected=New-PathBinding @(& git -C $merge diff --name-only $mergeProtected $mergeFinal)
                    final_delta_against_side=New-PathBinding @(& git -C $merge diff --name-only $mergeSide $mergeFinal)
                }
            }
            $repoEvidence += [ordered]@{repo_id=$repository.id;role=$repository.role;branch=$repository.branch;remote='origin';upstream="origin/$($repository.branch)";planned_revision=$repository.planned;old_revision=$repository.old;final_revision=$repository.final;final_tree=Invoke-ReconciliationGit $repository.repo @('rev-parse',"$($repository.final)^{tree}");current_remote_readback_revision=$repository.final;history=$history;force_push_used=$false}
        }
        $reconciliation = [ordered]@{'$schema'='../../../../schemas/executed-prepared-publication-reconciliation.schema.json';schema='rusty.morphospace.workflow.executed_prepared_publication_reconciliation.v1';reconciliation_id='fixture-executed-prepared-reconciliation';project_id='fixture-project';bundle_id='fixture-unit-push-bundle';trigger_unit_id='fixture-unit';prepared_plan=[ordered]@{container=New-FileBinding $workspace $planRelative;member='push_plan'};prepared_event=[ordered]@{event_id=$event.event_id;intent=New-FileBinding $workspace $intentRelative;completion=New-FileBinding $workspace $completionRelative};executed_push_receipt=New-FileBinding $workspace $executedRelative;chronology=[ordered]@{prepared_at=$preparedAt;push_started_at=$executed.started_at;push_finished_at=$executed.finished_at;execution_preceded_recorded_preparation=$true;timestamps_preserved=$true;corrected_chronology_claimed=$false;ordinary_accounting_satisfied=$false};repositories=$repoEvidence;planning_transport=[ordered]@{repo_id='planning-repo';allowed_untracked_paths=@("project/morphospace/$executedRelative","project/morphospace/$reconciliationRelative")};claims=[ordered]@{original_evidence_preserved=$true;ordinary_record_publication_satisfied=$false;retrospective_plan_claimed=$false;merge_history_flattened=$false;source_first_execution_order_observed=$true;planning_last_execution_order_observed=$true};workspace_transition=[ordered]@{pending_push_bundle_before='fixture-unit-push-bundle';pending_push_bundle_after=$null;validation_unchanged=$true;acceptance_unchanged=$true;git_mutation_performed=$false};failure=$null}
        $reconciliationPath = Join-Path $workspace ($reconciliationRelative -replace '/','\')
        Write-ReconciliationJson $reconciliationPath $reconciliation
        $mapPath = Join-Path $root 'repository-map.json'
        Write-ReconciliationJson $mapPath ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='source-repo';role='source';path=$source},[ordered]@{repo_id='merge-repo';role='source';path=$merge},[ordered]@{repo_id='planning-repo';role='planning';path=$planning})})
        $specObject = Get-Content -Raw (Join-Path $workspace 'project.spec.json') | ConvertFrom-Json
        $stateObject = Get-Content -Raw (Join-Path $workspace 'workspace.state.json') | ConvertFrom-Json
        $map = @{'source-repo'=[pscustomobject]@{path=$source};'merge-repo'=[pscustomobject]@{path=$merge};'planning-repo'=[pscustomobject]@{path=$planning}}
        $states = @($repositories | ForEach-Object {[pscustomobject]@{repo_id=$_.id;is_git=$true;dirty=($_.id-eq'planning-repo');diverged=$false;ahead=0;behind=0;head=$_.final;branch=$_.branch;upstream="origin/$($_.branch)"}})
        Test-MorphospaceExecutedPreparedPublicationLive $reconciliationPath $workspace $specObject $stateObject $map $states | Out-Null

        $cases = @('chronology','path-set','merge-parent','missing-merge','ordinary-claim','wrong-bundle')
        foreach ($case in $cases) {
            $bad = Copy-Value $reconciliation
            switch ($case) {
                'chronology' { $bad.chronology.push_started_at = '2026-01-01T00:03:00Z' }
                'path-set' { $bad.repositories[0].history.changed_paths_sha256 = ('0' * 64) }
                'merge-parent' { $bad.repositories[1].history.merge_integration.ordered_parents[0] = $mergeProtected }
                'missing-merge' { $bad.repositories[1].history.mode = 'linear'; $bad.repositories[1].history.merge_integration = $null }
                'ordinary-claim' { $bad.claims.ordinary_record_publication_satisfied = $true }
                'wrong-bundle' { $bad.bundle_id = 'wrong-bundle' }
            }
            $badPath = Join-Path $workspace "receipts\bad-$case.json"
            Write-ReconciliationJson $badPath $bad
            Assert-Rejected { Test-MorphospaceExecutedPreparedPublicationLive $badPath $workspace $specObject $stateObject $map $states } $case
            Remove-Item -LiteralPath $badPath -Force
        }
        [IO.File]::WriteAllText((Join-Path $source 'unexpected.txt'),"dirty`n",[Text.UTF8Encoding]::new($false))
        Assert-Rejected { Test-MorphospaceExecutedPreparedPublicationLive $reconciliationPath $workspace $specObject $stateObject $map $states } 'dirty-source'
        Remove-Item -LiteralPath (Join-Path $source 'unexpected.txt') -Force

        Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
        $result = Invoke-MorphospaceWorkUnitAutomation -Action ReconcileExecutedPreparedPublication -WorkspaceRoot $workspace -UnitId 'fixture-unit' -RepoMapPath $mapPath -ExecutedPreparedPublicationReconciliation $reconciliationRelative -Timestamp '2026-01-01T00:04:00Z' -Execute
        $afterState = Get-Content -Raw (Join-Path $workspace 'workspace.state.json') | ConvertFrom-Json
        $afterUnit = Get-Content -Raw (Join-Path $workspace 'iteration-units\fixture-unit.json') | ConvertFrom-Json
        $tail = Get-Content (Join-Path $workspace 'iteration-events.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
        if ($result.transition -cne 'executed-prepared-publication-reconciled' -or $null -ne $afterState.pending_push_bundle -or [string]$afterUnit.status -cne 'accepted' -or $tail.event_id -notlike '*executed-prepared-publication-reconciled*') { throw 'Automation transition did not clear only the bundle while preserving acceptance.' }
        Assert-Rejected { Invoke-MorphospaceWorkUnitAutomation -Action ReconcileExecutedPreparedPublication -WorkspaceRoot $workspace -UnitId 'fixture-unit' -RepoMapPath $mapPath -ExecutedPreparedPublicationReconciliation $reconciliationRelative -Timestamp '2026-01-01T00:05:00Z' -Execute } 'repeated-consumption'
        "Executed prepared-publication reconciliation self-test passed (1 exact linear+merge positive, $($cases.Count + 2) damaged cases)."
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    exit 0
}

if (-not $Path -or -not $WorkspaceRoot) { throw 'Path and WorkspaceRoot are required unless -SelfTest is used.' }
Test-MorphospaceExecutedPreparedPublicationDocument -Path $Path -WorkspaceRoot $WorkspaceRoot | ConvertTo-Json -Depth 16
