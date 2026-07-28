$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PreparedPublicationReconstruction.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
function Assert-Reconstruction([bool]$Value,[string]$Message){if(-not$Value){throw "Prepared-publication reconstruction self-test failed: $Message"}}
function Write-ReconstructionJson([string]$Path,[object]$Value){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 40 -Compress)+"`n"),[Text.UTF8Encoding]::new($false))}
function Invoke-ReconstructionTestGit([string]$Path,[string[]]$Arguments){$output=@(& git -C $Path @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "git $($Arguments-join' ') failed: $output"};(($output|ForEach-Object{[string]$_})-join"`n").Trim()}
function New-ReconstructionRepo([string]$Root,[string]$Name){
    $remote=Join-Path $Root "$Name.git";$repo=Join-Path $Root $Name
    & git init --bare --quiet $remote; & git init --quiet -b main $repo
    Invoke-ReconstructionTestGit $repo @('config','user.name','Synthetic Test')|Out-Null
    Invoke-ReconstructionTestGit $repo @('config','user.email','synthetic@example.invalid')|Out-Null
    Invoke-ReconstructionTestGit $repo @('remote','add','origin',$remote)|Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'payload.txt'),'prepared',[Text.UTF8Encoding]::new($false))
    Invoke-ReconstructionTestGit $repo @('add','payload.txt')|Out-Null;Invoke-ReconstructionTestGit $repo @('commit','-m','prepared')|Out-Null
    $prepared=Invoke-ReconstructionTestGit $repo @('rev-parse','HEAD');Invoke-ReconstructionTestGit $repo @('push','-u','origin','main')|Out-Null
    [IO.File]::AppendAllText((Join-Path $repo 'payload.txt'),"`naccepted",[Text.UTF8Encoding]::new($false))
    Invoke-ReconstructionTestGit $repo @('commit','-am','accepted publication')|Out-Null;Invoke-ReconstructionTestGit $repo @('push','origin','main')|Out-Null
    [IO.File]::AppendAllText((Join-Path $repo 'payload.txt'),"`nfinal",[Text.UTF8Encoding]::new($false))
    Invoke-ReconstructionTestGit $repo @('commit','-am','final publication')|Out-Null;Invoke-ReconstructionTestGit $repo @('push','origin','main')|Out-Null
    [pscustomobject]@{repo=$repo;remote=$remote;prepared=$prepared;tip=(Invoke-ReconstructionTestGit $repo @('rev-parse','HEAD'))}
}
function New-FileBinding([string]$Workspace,[string]$Relative){$path=Join-Path $Workspace ($Relative-replace'/','\');[ordered]@{path=$Relative;sha256=Get-MorphospaceFileSha256 $path}}
function New-TransitionFixture([string]$Workspace,[string]$Name,[object]$Event,[object]$State,[object]$Unit,[AllowNull()][string]$PreviousEventId){
    $intentRelative="receipts/transactions/$Name.intent.json";$completionRelative="receipts/transactions/$Name.completion.json"
    $preState='1'*64;$preUnit='2'*64
    $intent=[ordered]@{
        schema='rusty.morphospace.workflow.transition_ledger_intent.v1';transaction_id=$Name;created_at='2026-01-01T00:00:00Z'
        state=[ordered]@{path='workspace.state.json'};unit=[ordered]@{path="iteration-units/$([string]$Unit.unit_id).json"};events=[ordered]@{path='iteration-events.jsonl'}
        pre=[ordered]@{state=[ordered]@{sha256=$preState};unit=[ordered]@{sha256=$preUnit}}
        target=[ordered]@{
            state=[ordered]@{sha256=Get-MorphospaceCanonicalJsonSha256 $State;document=$State}
            unit=[ordered]@{sha256=Get-MorphospaceCanonicalJsonSha256 $Unit;document=$Unit}
        }
        expected=[ordered]@{state_sha256=$preState;unit_sha256=$preUnit;event_tail_id=$PreviousEventId}
        artifacts=@();event=$Event;status='prepared'
    }
    Write-ReconstructionJson (Join-Path $Workspace ($intentRelative-replace'/','\')) $intent
    $completion=[ordered]@{
        schema='rusty.morphospace.workflow.transition_ledger_completion.v1';transaction_id=$Name;completed_at='2026-01-01T00:00:01Z'
        intent=[ordered]@{role='transition-ledger-intent';path=$intentRelative;schema='rusty.morphospace.workflow.transition_ledger_intent.v1';sha256=Get-MorphospaceFileSha256 (Join-Path $Workspace ($intentRelative-replace'/','\'))}
        state_sha256=Get-MorphospaceCanonicalJsonSha256 $State;unit_sha256=Get-MorphospaceCanonicalJsonSha256 $Unit
        event_id=[string]$Event.event_id;status='committed'
    }
    Write-ReconstructionJson (Join-Path $Workspace ($completionRelative-replace'/','\')) $completion
    [ordered]@{event_id=[string]$Event.event_id;intent=New-FileBinding $Workspace $intentRelative;completion=New-FileBinding $Workspace $completionRelative}
}
function Get-PhysicalFixture([object]$Repo,[string]$PhysicalId,[string[]]$LogicalIds,[string]$ObservationId){
    $revision=Invoke-ReconstructionTestGit $Repo.repo @('rev-list','--reverse',"$($Repo.prepared)..$($Repo.tip)")
    $history=@($revision-split"`n"|Where-Object{$_}|ForEach-Object{
        [ordered]@{revision=$_;parents=@((Invoke-ReconstructionTestGit $Repo.repo @('show','-s','--format=%P',$_))-split' '|Where-Object{$_});tree=Invoke-ReconstructionTestGit $Repo.repo @('show','-s','--format=%T',$_);changed_paths=@((Invoke-ReconstructionTestGit $Repo.repo @('diff-tree','--no-commit-id','--name-only','-r','--root',$_))-split"`n"|Where-Object{$_}|Sort-Object -Unique)}
    })
    [ordered]@{physical_ref_id=$PhysicalId;observation_repo_id=$ObservationId;logical_repo_ids=$LogicalIds;remote='origin';ref='refs/heads/main';branch='main';upstream='origin/main';prepared_revision=$Repo.prepared;prepared_tree=Invoke-ReconstructionTestGit $Repo.repo @('show','-s','--format=%T',$Repo.prepared);remote_tip_revision=$Repo.tip;remote_tip_tree=Invoke-ReconstructionTestGit $Repo.repo @('show','-s','--format=%T',$Repo.tip);ancestor_or_equal=$true;history=$history}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ("morphospace-reconstruction-"+[guid]::NewGuid().ToString('N'))
try{
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $application=New-ReconstructionRepo $root 'application-physical'
    $adapter=New-ReconstructionRepo $root 'adapter-physical'
    $workspace=Join-Path $root 'workflow-workspace'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units'))|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts\transactions'))|Out-Null
    $unit=[ordered]@{schema='synthetic-unit';unit_id='unit-reconstruction';status='accepted'}
    $validationUnit=[ordered]@{schema='synthetic-unit';unit_id='unit-reconstruction';status='validating'}
    Write-ReconstructionJson (Join-Path $workspace 'iteration-units\unit-reconstruction.json') $unit
    $validationRelative='receipts/unit-reconstruction-validation.json'
    $evidenceRelative='receipts/unit-reconstruction-evidence.txt'
    [IO.File]::WriteAllText((Join-Path $workspace $evidenceRelative),'pass',[Text.UTF8Encoding]::new($false))
    $validation=[ordered]@{schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id='validation-reconstruction';project_id='synthetic-project';unit_id='unit-reconstruction';created_at='2026-01-01T00:00:00Z';tier='standard';result='pass';repository_revisions=@([ordered]@{repo_id='application';base_revision=$application.prepared;head_revision=$application.tip;branch='main'});changed_paths=@();artifacts=@([ordered]@{artifact_id='synthetic-evidence';kind='test-report';path=$evidenceRelative;sha256=Get-MorphospaceFileSha256 (Join-Path $workspace $evidenceRelative)});criteria=@([ordered]@{acceptance_id='synthetic-criterion';status='pass';command='synthetic';evidence_refs=@('synthetic-evidence')});gates=@([ordered]@{gate_id='synthetic-gate';status='pass';command='synthetic';evidence_refs=@('synthetic-evidence')});device_validation=$null}
    Write-ReconstructionJson (Join-Path $workspace ($validationRelative-replace'/','\')) $validation
    $validationEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-reconstruction-validation-pass';sequence=1;timestamp='2026-01-01T00:00:00Z';project_id='synthetic-project';unit_id='unit-reconstruction';event_type='validation';summary='Synthetic validation passed.';receipts=@($validationRelative)}
    $acceptanceEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-reconstruction-accepted';sequence=2;timestamp='2026-01-01T00:00:01Z';project_id='synthetic-project';unit_id='unit-reconstruction';event_type='state-transition';summary='Synthetic unit accepted.';receipts=@($validationRelative)}
    $pending=[ordered]@{bundle_id='synthetic-bundle';unit_ids=@('unit-reconstruction')}
    $blocker=[ordered]@{blocker_id='stale-prepared-publication';condition='Published revisions remain projected as pending.';resume_when='Canonical reconstruction passes.'}
    $validationState=[ordered]@{schema='synthetic-state';project_id='synthetic-project';current_unit='unit-reconstruction';pending_push_bundle=$null;validation_checkpoint=[ordered]@{receipt=$validationRelative;result='pass'};blockers=@();last_event_id=$validationEvent.event_id}
    $acceptanceState=[ordered]@{schema='synthetic-state';project_id='synthetic-project';current_unit=$null;pending_push_bundle=$null;validation_checkpoint=[ordered]@{receipt=$validationRelative;result='pass'};blockers=@();last_event_id=$acceptanceEvent.event_id}
    $preparedState=[ordered]@{schema='synthetic-state';project_id='synthetic-project';current_unit=$null;pending_push_bundle=$pending;validation_checkpoint=[ordered]@{receipt=$validationRelative;result='pass'};blockers=@();last_event_id=$null}
    $validationTransition=New-TransitionFixture -Workspace $workspace -Name "$($validationEvent.event_id)-transition" -Event $validationEvent -State $validationState -Unit $validationUnit -PreviousEventId $null
    $acceptanceTransition=New-TransitionFixture -Workspace $workspace -Name "$($acceptanceEvent.event_id)-transition" -Event $acceptanceEvent -State $acceptanceState -Unit $unit -PreviousEventId $validationEvent.event_id
    $plan=[ordered]@{schema='rusty.morphospace.workflow.push_bundle_plan.v1';bundle_id='synthetic-bundle';project_id='synthetic-project';unit_ids=@('unit-reconstruction');prepared_at='2026-01-01T00:00:02Z';dependency_order=@('application','adapter','planning');repositories=@([ordered]@{repo_id='application';role='application';branch='main';commit=$application.prepared;upstream='origin/main';ahead=0;behind=0},[ordered]@{repo_id='adapter';role='adapter';branch='main';commit=$adapter.prepared;upstream='origin/main';ahead=0;behind=0},[ordered]@{repo_id='planning';role='planning';branch='main';commit=$application.prepared;upstream='origin/main';ahead=0;behind=0});source_first=$true;planning_last=$true;execution='not-performed';force_push_allowed=$false}
    $planRelative='receipts/prepared-plan-owner.json'
    Write-ReconstructionJson (Join-Path $workspace ($planRelative-replace'/','\')) ([ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v1';project_id='synthetic-project';unit_id='unit-reconstruction';action='PreparePush';executed=$true;transition='push-bundle-prepared';event_id='unit-reconstruction-push-prepared';push_plan=$plan})
    $prepareEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-reconstruction-push-prepared';sequence=3;timestamp='2026-01-01T00:00:02Z';project_id='synthetic-project';unit_id='unit-reconstruction';event_type='commit';summary='Synthetic plan prepared.';receipts=@($planRelative)}
    $preparedState.last_event_id=$prepareEvent.event_id
    $prepareTransition=New-TransitionFixture -Workspace $workspace -Name "$($prepareEvent.event_id)-transition" -Event $prepareEvent -State $preparedState -Unit $unit -PreviousEventId $acceptanceEvent.event_id
    $canonicalEventLines=@($validationEvent,$acceptanceEvent,$prepareEvent|ForEach-Object{$_|ConvertTo-Json -Depth 20 -Compress})
    [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),$canonicalEventLines,[Text.UTF8Encoding]::new($false))
    $state=[ordered]@{schema='synthetic-state';project_id='synthetic-project';current_unit=$null;pending_push_bundle=$pending;validation_checkpoint=$null;blockers=@($blocker);last_event_id=$prepareEvent.event_id}
    Write-ReconstructionJson (Join-Path $workspace 'workspace.state.json') $state
    $mapPath=Join-Path $root 'repository-map.json'
    Write-ReconstructionJson $mapPath ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='application-physical';path=$application.repo;role='source';aliases=@('application','planning')},[ordered]@{repo_id='adapter-physical';path=$adapter.repo;role='source';aliases=@('adapter')})})
    $document=[ordered]@{schema='rusty.morphospace.workflow.prepared_publication_reconstruction.v1';reconstruction_id='synthetic-reconstruction';project_id='synthetic-project';bundle_id='synthetic-bundle';unit_ids=@('unit-reconstruction');prepared_plan=[ordered]@{container=New-FileBinding $workspace $planRelative;member='push_plan'};prepared_event=[ordered]@{event_id=$prepareEvent.event_id;intent=$prepareTransition.intent;completion=$prepareTransition.completion;member='event'};accepted_unit=New-FileBinding $workspace 'iteration-units/unit-reconstruction.json';validation_receipt=New-FileBinding $workspace $validationRelative;validation_event=$validationTransition;acceptance_event=$acceptanceTransition;pending_bundle=[ordered]@{value=$pending;sha256=Get-MorphospaceCanonicalJsonSha256 $pending};stale_blocker=[ordered]@{value=$blocker;sha256=Get-MorphospaceCanonicalJsonSha256 $blocker};active_workspace_observation=[ordered]@{evidentiary=$false;repositories=@()};logical_legs=@([ordered]@{repo_id='application';role='application';physical_ref_id='application-main';prepared_revision=$application.prepared},[ordered]@{repo_id='adapter';role='adapter';physical_ref_id='adapter-main';prepared_revision=$adapter.prepared},[ordered]@{repo_id='planning';role='planning';physical_ref_id='application-main';prepared_revision=$application.prepared});physical_refs=@((Get-PhysicalFixture $application 'application-main' @('application','planning') 'application-physical'),(Get-PhysicalFixture $adapter 'adapter-main' @('adapter') 'adapter-physical'));conflicting_evidence=[ordered]@{executed_push_receipt_present=$false;planned_accounting_present=$false;unplanned_closure_present=$false};claims=[ordered]@{original_plan_execution=$false;cross_repository_execution_or_publication_order=$false;source_first_planning_last_execution=$false;force_or_no_force_history=$false;publication_actor_or_timestamp=$false;historical_nonpublication_or_impossibility=$false;original_not_performed_preserved=$true};mutation=[ordered]@{pending_bundle_consumed=$true;blocker_consumed=$true}}
    $input=Join-Path $root 'reconstruction-input.json';Write-ReconstructionJson $input $document
    $dry=Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input -Timestamp '2026-01-01T00:00:03Z'
    Assert-Reconstruction (-not$dry.executed-and$dry.transition-eq'prepared-publication-reconstructed') 'exact three-logical/two-physical shape did not dry-run'
    foreach($case in @(
        @{name='unrelated ref';mutate={param($d)$d.physical_refs[0].ref='refs/heads/unrelated'}},
        @{name='split alias';mutate={param($d)$d.physical_refs[0].logical_repo_ids=@('application')}},
        @{name='incomplete history';mutate={param($d)$d.physical_refs[0].history=@($d.physical_refs[0].history|Select-Object -First 1)}},
        @{name='reordered history';mutate={param($d)$rows=@($d.physical_refs[0].history);[array]::Reverse($rows);$d.physical_refs[0].history=$rows}},
        @{name='duplicate physical id';mutate={param($d)$d.physical_refs[1].physical_ref_id=$d.physical_refs[0].physical_ref_id}},
        @{name='unreachable revision';mutate={param($d)$d.physical_refs[0].prepared_revision='0000000000000000000000000000000000000000'}},
        @{name='stale remote';mutate={param($d)$d.physical_refs[0].remote_tip_revision=$d.physical_refs[0].prepared_revision}},
        @{name='blocker mismatch';mutate={param($d)$d.stale_blocker.value.condition='wrong'}},
        @{name='pending mismatch';mutate={param($d)$d.pending_bundle.value.bundle_id='wrong-bundle'}}
    )){
        $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;& $case.mutate $damaged;Write-ReconstructionJson $input $damaged
        $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
        Assert-Reconstruction $rejected "$($case.name) was accepted"
    }
    foreach($case in @(
        @{name='omitted document unit_ids';mutate={param($d)$d.unit_ids=@()}},
        @{name='document unit_ids mismatch';mutate={param($d)$d.unit_ids=@('different-unit')}},
        @{name='case-changed document unit_ids';mutate={param($d)$d.unit_ids=@('Unit-reconstruction')}},
        @{name='injected accepted-unit request';mutate={param($d)$d.unit_ids=@('unit-reconstruction','different-unit')}},
        @{name='duplicate accepted-unit request';mutate={param($d)$d.unit_ids=@('unit-reconstruction','unit-reconstruction')}}
    )){
        $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;& $case.mutate $damaged;Write-ReconstructionJson $input $damaged
        $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
        Assert-Reconstruction $rejected "$($case.name) was accepted"
    }
    $planOwnerPath=Join-Path $workspace ($document.prepared_plan.container.path-replace'/','\')
    $planOwner=Read-MorphospaceProtocolJson $planOwnerPath
    $damagedOwner=$planOwner|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damagedOwner.push_plan.unit_ids=@('different-unit');Write-ReconstructionJson $planOwnerPath $damagedOwner
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.prepared_plan.container.sha256=Get-MorphospaceFileSha256 $planOwnerPath;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'prepared plan unit_ids mismatch was accepted'
    Write-ReconstructionJson $planOwnerPath $planOwner

    $preparedIntentPath=Join-Path $workspace ($document.prepared_event.intent.path-replace'/','\')
    $preparedIntent=Read-MorphospaceProtocolJson $preparedIntentPath
    $damagedIntent=$preparedIntent|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damagedIntent.schema='rusty.morphospace.workflow.iteration_event.v1';Write-ReconstructionJson $preparedIntentPath $damagedIntent
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.prepared_event.intent.sha256=Get-MorphospaceFileSha256 $preparedIntentPath;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'prepared-event intent schema mismatch was accepted'
    $prepareTransition=New-TransitionFixture -Workspace $workspace -Name "$($prepareEvent.event_id)-transition" -Event $prepareEvent -State $preparedState -Unit $unit -PreviousEventId $acceptanceEvent.event_id

    $preparedCompletionPath=Join-Path $workspace ($document.prepared_event.completion.path-replace'/','\')
    $preparedCompletion=Read-MorphospaceProtocolJson $preparedCompletionPath
    $damagedCompletion=$preparedCompletion|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damagedCompletion.intent.role='untrusted-reference';Write-ReconstructionJson $preparedCompletionPath $damagedCompletion
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.prepared_event.completion.sha256=Get-MorphospaceFileSha256 $preparedCompletionPath;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'prepared-event completion intent role mismatch was accepted'
    $prepareTransition=New-TransitionFixture -Workspace $workspace -Name "$($prepareEvent.event_id)-transition" -Event $prepareEvent -State $preparedState -Unit $unit -PreviousEventId $acceptanceEvent.event_id

    $validationIntentPath=Join-Path $workspace ($document.validation_event.intent.path-replace'/','\')
    $validationCompletionPath=Join-Path $workspace ($document.validation_event.completion.path-replace'/','\')
    $validationIntent=Read-MorphospaceProtocolJson $validationIntentPath
    $validationCompletion=Read-MorphospaceProtocolJson $validationCompletionPath
    $damagedIntent=$validationIntent|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damagedIntent.transaction_id='different-transition';Write-ReconstructionJson $validationIntentPath $damagedIntent
    $damagedCompletion=$validationCompletion|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damagedCompletion.intent.sha256=Get-MorphospaceFileSha256 $validationIntentPath;Write-ReconstructionJson $validationCompletionPath $damagedCompletion
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.validation_event.intent.sha256=Get-MorphospaceFileSha256 $validationIntentPath;$damaged.validation_event.completion.sha256=Get-MorphospaceFileSha256 $validationCompletionPath;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'validation transition transaction/path mismatch was accepted'
    $validationTransition=New-TransitionFixture -Workspace $workspace -Name "$($validationEvent.event_id)-transition" -Event $validationEvent -State $validationState -Unit $validationUnit -PreviousEventId $null

    $alternateIntentRelative='receipts/transactions/alternate-validation.intent.json'
    $alternateIntentPath=Join-Path $workspace ($alternateIntentRelative-replace'/','\')
    Copy-Item -LiteralPath $validationIntentPath -Destination $alternateIntentPath
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.validation_event.intent.path=$alternateIntentRelative;$damaged.validation_event.intent.sha256=Get-MorphospaceFileSha256 $alternateIntentPath;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'non-canonical validation intent path was accepted'
    Remove-Item -LiteralPath $alternateIntentPath

    $validationIntent=Read-MorphospaceProtocolJson $validationIntentPath;$validationCompletion=Read-MorphospaceProtocolJson $validationCompletionPath
    $damagedIntent=$validationIntent|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damagedIntent.target.state.sha256='0'*64;Write-ReconstructionJson $validationIntentPath $damagedIntent
    $damagedCompletion=$validationCompletion|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damagedCompletion.intent.sha256=Get-MorphospaceFileSha256 $validationIntentPath;Write-ReconstructionJson $validationCompletionPath $damagedCompletion
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.validation_event.intent.sha256=Get-MorphospaceFileSha256 $validationIntentPath;$damaged.validation_event.completion.sha256=Get-MorphospaceFileSha256 $validationCompletionPath;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'validation target state hash mismatch was accepted'
    $validationTransition=New-TransitionFixture -Workspace $workspace -Name "$($validationEvent.event_id)-transition" -Event $validationEvent -State $validationState -Unit $validationUnit -PreviousEventId $null

    $acceptanceCompletionPath=Join-Path $workspace ($document.acceptance_event.completion.path-replace'/','\')
    $acceptanceCompletion=Read-MorphospaceProtocolJson $acceptanceCompletionPath;$acceptanceCompletion.state_sha256='0'*64;Write-ReconstructionJson $acceptanceCompletionPath $acceptanceCompletion
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.acceptance_event.completion.sha256=Get-MorphospaceFileSha256 $acceptanceCompletionPath;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'acceptance completion target-state hash mismatch was accepted'
    $acceptanceTransition=New-TransitionFixture -Workspace $workspace -Name "$($acceptanceEvent.event_id)-transition" -Event $acceptanceEvent -State $acceptanceState -Unit $unit -PreviousEventId $validationEvent.event_id

    [IO.File]::WriteAllText((Join-Path $application.repo 'untracked-readback.txt'),'dirty',[Text.UTF8Encoding]::new($false))
    Write-ReconstructionJson $input $document
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'dirty/untracked readback repository was accepted'
    Remove-Item -LiteralPath (Join-Path $application.repo 'untracked-readback.txt')

    $fabricatedEvent=$validationEvent|ConvertTo-Json -Depth 20|ConvertFrom-Json
    $fabricatedEvent.event_id='unit-reconstruction-fabricated-validation';$fabricatedEvent.sequence=1
    $fabricatedTransition=New-TransitionFixture -Workspace $workspace -Name "$($fabricatedEvent.event_id)-transition" -Event $fabricatedEvent -State $validationState -Unit $validationUnit -PreviousEventId $null
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.validation_event=$fabricatedTransition;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'fabricated self-consistent transition absent from the event ledger was accepted'

    [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),@($canonicalEventLines[1],$canonicalEventLines[0],$canonicalEventLines[2]),[Text.UTF8Encoding]::new($false))
    Write-ReconstructionJson $input $document
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'reordered event ledger was accepted'
    [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),@($canonicalEventLines+$canonicalEventLines[2]),[Text.UTF8Encoding]::new($false))
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'duplicate event ledger identity was accepted'
    [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),@($canonicalEventLines[1..2]),[Text.UTF8Encoding]::new($false))
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'event ledger with an absent validation event was accepted'
    [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),$canonicalEventLines,[Text.UTF8Encoding]::new($false))

    $validationIntent=Read-MorphospaceProtocolJson $validationIntentPath;$validationCompletion=Read-MorphospaceProtocolJson $validationCompletionPath
    $validationIntent.expected.event_tail_id=$acceptanceEvent.event_id;Write-ReconstructionJson $validationIntentPath $validationIntent
    $validationCompletion.intent.sha256=Get-MorphospaceFileSha256 $validationIntentPath;Write-ReconstructionJson $validationCompletionPath $validationCompletion
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.validation_event.intent.sha256=Get-MorphospaceFileSha256 $validationIntentPath;$damaged.validation_event.completion.sha256=Get-MorphospaceFileSha256 $validationCompletionPath;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'transition with the wrong preceding event tail was accepted'
    $validationTransition=New-TransitionFixture -Workspace $workspace -Name "$($validationEvent.event_id)-transition" -Event $validationEvent -State $validationState -Unit $validationUnit -PreviousEventId $null

    $conflictingRelative='receipts/event-bound-conflict.json'
    Write-ReconstructionJson (Join-Path $workspace ($conflictingRelative-replace'/','\')) ([ordered]@{schema='rusty.morphospace.workflow.executed_push_receipt.v1';bundle_id='synthetic-bundle'})
    $conflictEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-reconstruction-conflicting-publication';sequence=4;timestamp='2026-01-01T00:00:04Z';project_id='synthetic-project';unit_id='unit-reconstruction';event_type='push';summary='Conflicting publication evidence.';receipts=@($conflictingRelative)}
    $conflictLines=@($canonicalEventLines+($conflictEvent|ConvertTo-Json -Depth 20 -Compress))
    [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),$conflictLines,[Text.UTF8Encoding]::new($false))
    $preConflictState=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
    $conflictState=$preConflictState|ConvertTo-Json -Depth 40|ConvertFrom-Json;$conflictState.last_event_id=$conflictEvent.event_id
    Write-ReconstructionJson (Join-Path $workspace 'workspace.state.json') $conflictState
    Write-ReconstructionJson $input $document
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'event-bound conflicting publication evidence was accepted'
    Remove-Item -LiteralPath (Join-Path $workspace ($conflictingRelative-replace'/','\'))
    [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),$canonicalEventLines,[Text.UTF8Encoding]::new($false))
    Write-ReconstructionJson (Join-Path $workspace 'workspace.state.json') $preConflictState

    foreach($action in @('RecordPublication','ReconcilePublication','ReconcilePlanningSuffixRewrite','ReconcilePublishedPrerequisiteSuffix')){
        $slug=($action-replace'([a-z])([A-Z])','$1-$2').ToLowerInvariant()
        $standaloneRelative="receipts/standalone-$slug.json"
        Write-ReconstructionJson (Join-Path $workspace ($standaloneRelative-replace'/','\')) ([ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';action=$action;audit_receipt=[ordered]@{bundle_id='synthetic-bundle'}})
        Write-ReconstructionJson $input $document
        $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
        Assert-Reconstruction $rejected "standalone bundle-bound $action automation receipt was accepted"
        Remove-Item -LiteralPath (Join-Path $workspace ($standaloneRelative-replace'/','\'))

        $eventRelative="event-evidence/$slug.json"
        Write-ReconstructionJson (Join-Path $workspace ($eventRelative-replace'/','\')) ([ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';action=$action;audit_receipt=[ordered]@{bundle_id='synthetic-bundle'}})
        $automationEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id="unit-reconstruction-$slug";sequence=4;timestamp='2026-01-01T00:00:04Z';project_id='synthetic-project';unit_id='unit-reconstruction';event_type='push';summary='Conflicting consuming automation evidence.';receipts=@($eventRelative)}
        [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),@($canonicalEventLines+($automationEvent|ConvertTo-Json -Depth 20 -Compress)),[Text.UTF8Encoding]::new($false))
        $eventBoundState=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
        $eventBoundState.last_event_id=$automationEvent.event_id
        Write-ReconstructionJson (Join-Path $workspace 'workspace.state.json') $eventBoundState
        $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
        Assert-Reconstruction $rejected "event-bound bundle-bound $action automation receipt was accepted"
        Remove-Item -LiteralPath (Join-Path $workspace ($eventRelative-replace'/','\'))
        [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),$canonicalEventLines,[Text.UTF8Encoding]::new($false))
        $eventBoundState.last_event_id=$prepareEvent.event_id
        Write-ReconstructionJson (Join-Path $workspace 'workspace.state.json') $eventBoundState
    }

    $canonicalState=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
    foreach($tailCase in @($null,'Unit-Reconstruction-Push-Prepared','unit-reconstruction-nonexistent-event','unit-reconstruction-accepted')){
        $damagedState=$canonicalState|ConvertTo-Json -Depth 40|ConvertFrom-Json
        $damagedState.last_event_id=$tailCase
        Write-ReconstructionJson (Join-Path $workspace 'workspace.state.json') $damagedState
        Write-ReconstructionJson $input $document
        $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
        Assert-Reconstruction $rejected "workspace state tail '$tailCase' was accepted despite differing from the authenticated event ledger"
    }
    Write-ReconstructionJson (Join-Path $workspace 'workspace.state.json') $canonicalState

    $preparedCompletion=Read-MorphospaceProtocolJson $preparedCompletionPath
    $preparedCompletion|Add-Member -NotePropertyName untrusted_extra -NotePropertyValue 'not-canonical'
    Write-ReconstructionJson $preparedCompletionPath $preparedCompletion
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$damaged.prepared_event.completion.sha256=Get-MorphospaceFileSha256 $preparedCompletionPath;Write-ReconstructionJson $input $damaged
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'transition completion with an unrecognized field was accepted'
    $prepareTransition=New-TransitionFixture -Workspace $workspace -Name "$($prepareEvent.event_id)-transition" -Event $prepareEvent -State $preparedState -Unit $unit -PreviousEventId $acceptanceEvent.event_id

    $linkedReadback=Join-Path $root 'application-linked-readback'
    Invoke-ReconstructionTestGit $application.repo @('worktree','add','--detach',$linkedReadback,$application.tip)|Out-Null
    $linkedMap=Read-MorphospaceProtocolJson $mapPath
    (@($linkedMap.repositories|Where-Object{[string]$_.repo_id-ceq'application-physical'}))[0].path=$linkedReadback
    $linkedMapPath=Join-Path $root 'repository-map-linked.json';Write-ReconstructionJson $linkedMapPath $linkedMap
    Write-ReconstructionJson $input $document
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $linkedMapPath -ReconstructionReceipt $input|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'linked/shared-Git readback worktree was accepted'

    [IO.File]::AppendAllText((Join-Path $application.repo '.git\info\exclude'),"`nnested-workspace/`n",[Text.UTF8Encoding]::new($false))
    $nestedWorkspace=Join-Path $application.repo 'nested-workspace'
    Copy-Item -LiteralPath $workspace -Destination $nestedWorkspace -Recurse
    $nestedInput=Join-Path $root 'nested-reconstruction-input.json';Write-ReconstructionJson $nestedInput $document
    $rejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $nestedWorkspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $nestedInput|Out-Null}catch{$rejected=$true}
    Assert-Reconstruction $rejected 'readback repository containing the active workflow workspace was accepted'

    $observationModule=Get-Module PreparedPublicationReconstruction
    $stableObservation=[pscustomobject][ordered]@{root='r';git_dir='g';common_dir='g';branch='main';upstream='origin/main';head=('a'*40);upstream_tip=('a'*40);ahead=0;behind=0;clean=$true;remote_tip=('a'*40)}
    foreach($field in @('head','branch','upstream')){
        $changed=$stableObservation|ConvertTo-Json|ConvertFrom-Json
        $changed.$field=if($field-eq'head'){'b'*40}else{"changed-$field"}
        $rejected=$false;try{& $observationModule {param($first,$second) Assert-ReconstructionObservationEqual $first $second 'synthetic'} $stableObservation $changed}catch{$rejected=$true}
        Assert-Reconstruction $rejected "second readback observation accepted changed $field"
    }
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $validationIntent=Read-MorphospaceProtocolJson (Join-Path $workspace ($damaged.validation_event.intent.path-replace'/','\'));$validationIntent.event.receipts=@('receipts/different-validation.json')
    Write-ReconstructionJson (Join-Path $workspace ($damaged.validation_event.intent.path-replace'/','\')) $validationIntent;$damaged.validation_event.intent.sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($damaged.validation_event.intent.path-replace'/','\'));Write-ReconstructionJson $input $damaged
    $differentValidationRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$differentValidationRejected=$true};Assert-Reconstruction $differentValidationRejected 'validation event pointing to a different receipt was accepted'
    $validationTransition=New-TransitionFixture -Workspace $workspace -Name "$($validationEvent.event_id)-transition" -Event $validationEvent -State $validationState -Unit $validationUnit -PreviousEventId $null

    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $acceptanceIntent=Read-MorphospaceProtocolJson (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\'));$acceptanceIntent.event.receipts=@('receipts/different-validation.json')
    Write-ReconstructionJson (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\')) $acceptanceIntent;$damaged.acceptance_event.intent.sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\'));Write-ReconstructionJson $input $damaged
    $differentAcceptanceRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$differentAcceptanceRejected=$true};Assert-Reconstruction $differentAcceptanceRejected 'acceptance event pointing to different validation provenance was accepted'
    $acceptanceTransition=New-TransitionFixture -Workspace $workspace -Name "$($acceptanceEvent.event_id)-transition" -Event $acceptanceEvent -State $acceptanceState -Unit $unit -PreviousEventId $validationEvent.event_id

    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $acceptanceIntent=Read-MorphospaceProtocolJson (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\'));$acceptanceIntent.target.unit.document.status='validating';$acceptanceIntent.target.unit.sha256=Get-MorphospaceCanonicalJsonSha256 $acceptanceIntent.target.unit.document
    Write-ReconstructionJson (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\')) $acceptanceIntent;$damaged.acceptance_event.intent.sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\'));Write-ReconstructionJson $input $damaged
    $targetMismatchRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$targetMismatchRejected=$true};Assert-Reconstruction $targetMismatchRejected 'accepted transition target-unit byte mismatch was accepted'
    $acceptanceTransition=New-TransitionFixture -Workspace $workspace -Name "$($acceptanceEvent.event_id)-transition" -Event $acceptanceEvent -State $acceptanceState -Unit $unit -PreviousEventId $validationEvent.event_id

    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $acceptanceCompletion=Read-MorphospaceProtocolJson (Join-Path $workspace ($damaged.acceptance_event.completion.path-replace'/','\'));$acceptanceCompletion.unit_sha256='0'*64
    Write-ReconstructionJson (Join-Path $workspace ($damaged.acceptance_event.completion.path-replace'/','\')) $acceptanceCompletion;$damaged.acceptance_event.completion.sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($damaged.acceptance_event.completion.path-replace'/','\'));Write-ReconstructionJson $input $damaged
    $completionMismatchRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$completionMismatchRejected=$true};Assert-Reconstruction $completionMismatchRejected 'acceptance completion unit_sha256 mismatch was accepted'
    $acceptanceTransition=New-TransitionFixture -Workspace $workspace -Name "$($acceptanceEvent.event_id)-transition" -Event $acceptanceEvent -State $acceptanceState -Unit $unit -PreviousEventId $validationEvent.event_id

    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$unused=$damaged.physical_refs[1]|ConvertTo-Json -Depth 20|ConvertFrom-Json;$unused.physical_ref_id='unused-physical-ref';$damaged.physical_refs+=,$unused;Write-ReconstructionJson $input $damaged
    $unusedPhysicalRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$unusedPhysicalRejected=$true};Assert-Reconstruction $unusedPhysicalRejected 'extra unused physical ref was accepted'
    foreach($remoteCase in @(
        @{name='wrong intended remote name';mutate={param($d)$d.physical_refs[0].remote='upstream'}},
        @{name='wrong intended upstream';mutate={param($d)$d.physical_refs[0].upstream='origin/other'}}
    )){
        $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;& $remoteCase.mutate $damaged;Write-ReconstructionJson $input $damaged
        $remoteRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$remoteRejected=$true};Assert-Reconstruction $remoteRejected "$($remoteCase.name) was accepted"
    }
    $fabricated=$validation|ConvertTo-Json -Depth 20|ConvertFrom-Json;$fabricated.PSObject.Properties.Remove('criteria');Write-ReconstructionJson (Join-Path $workspace ($validationRelative-replace'/','\')) $fabricated
    $fabricatedDocument=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json;$fabricatedDocument.validation_receipt.sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($validationRelative-replace'/','\'));Write-ReconstructionJson $input $fabricatedDocument
    $fabricatedRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$fabricatedRejected=$true}
    Assert-Reconstruction $fabricatedRejected 'fabricated minimal validation was accepted'
    Write-ReconstructionJson (Join-Path $workspace ($validationRelative-replace'/','\')) $validation;Write-ReconstructionJson $input $document
    $conflict=Join-Path $workspace 'receipts\conflicting.json';Write-ReconstructionJson $conflict ([ordered]@{schema='rusty.morphospace.workflow.executed_push_receipt.v1';bundle_id='synthetic-bundle'})
    $conflictRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$conflictRejected=$true};Assert-Reconstruction $conflictRejected 'conflicting evidence was accepted';Remove-Item $conflict
    $output=Join-Path $workspace 'receipts\synthetic-reconstruction.json'
    $interrupted=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input -Timestamp '2026-01-01T00:00:03Z' -OutPath $output -Execute -FaultAfter after-event|Out-Null}catch{$interrupted=$true}
    Assert-Reconstruction ($interrupted-and-not(Test-Path $output)) 'reconstruction transaction interruption did not stop before audit-artifact installation'
    Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId 'unit-reconstruction-prepared-publication-reconstructed-0004-transition' -Repair|Out-Null
    $finalState=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
    Assert-Reconstruction ($null-eq$finalState.pending_push_bundle-and@($finalState.blockers).Count-eq0-and(Get-MorphospaceFileSha256 $output)-eq(Get-MorphospaceFileSha256 $input)-and(Test-Path (Join-Path $workspace 'receipts\transactions\unit-reconstruction-prepared-publication-reconstructed-0004-transition.completion.json'))) 'interruption repair did not atomically own the audit artifact and close exact projections'
    Write-Host 'Prepared-publication reconstruction self-test passed.'
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}}
