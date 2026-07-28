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
function New-TransitionFixture([string]$Workspace,[string]$Name,[object]$Event,[object]$Unit){
    $intentRelative="receipts/transactions/$Name.intent.json";$completionRelative="receipts/transactions/$Name.completion.json"
    $intent=[ordered]@{schema='rusty.morphospace.workflow.transition_ledger_intent.v1';transaction_id=$Name;event=$Event;target=[ordered]@{unit=[ordered]@{sha256=Get-MorphospaceCanonicalJsonSha256 $Unit;document=$Unit}};status='prepared'}
    Write-ReconstructionJson (Join-Path $Workspace ($intentRelative-replace'/','\')) $intent
    $completion=[ordered]@{schema='rusty.morphospace.workflow.transition_ledger_completion.v1';transaction_id=$Name;intent=[ordered]@{sha256=Get-MorphospaceFileSha256 (Join-Path $Workspace ($intentRelative-replace'/','\'))};unit_sha256=Get-MorphospaceCanonicalJsonSha256 $Unit;event_id=[string]$Event.event_id;status='committed'}
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
    $workspace=Join-Path $application.repo 'morphospace'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units'))|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts\transactions'))|Out-Null
    $unit=[ordered]@{schema='synthetic-unit';unit_id='unit-reconstruction';status='accepted'}
    Write-ReconstructionJson (Join-Path $workspace 'iteration-units\unit-reconstruction.json') $unit
    $validationRelative='receipts/unit-reconstruction-validation.json'
    $evidenceRelative='receipts/unit-reconstruction-evidence.txt'
    [IO.File]::WriteAllText((Join-Path $workspace $evidenceRelative),'pass',[Text.UTF8Encoding]::new($false))
    $validation=[ordered]@{schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id='validation-reconstruction';project_id='synthetic-project';unit_id='unit-reconstruction';created_at='2026-01-01T00:00:00Z';tier='standard';result='pass';repository_revisions=@([ordered]@{repo_id='application';base_revision=$application.prepared;head_revision=$application.tip;branch='main'});changed_paths=@();artifacts=@([ordered]@{artifact_id='synthetic-evidence';kind='test-report';path=$evidenceRelative;sha256=Get-MorphospaceFileSha256 (Join-Path $workspace $evidenceRelative)});criteria=@([ordered]@{acceptance_id='synthetic-criterion';status='pass';command='synthetic';evidence_refs=@('synthetic-evidence')});gates=@([ordered]@{gate_id='synthetic-gate';status='pass';command='synthetic';evidence_refs=@('synthetic-evidence')});device_validation=$null}
    Write-ReconstructionJson (Join-Path $workspace ($validationRelative-replace'/','\')) $validation
    $validationEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-reconstruction-validation-pass';sequence=1;timestamp='2026-01-01T00:00:00Z';project_id='synthetic-project';unit_id='unit-reconstruction';event_type='validation';summary='Synthetic validation passed.';receipts=@($validationRelative)}
    $acceptanceEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-reconstruction-accepted';sequence=2;timestamp='2026-01-01T00:00:01Z';project_id='synthetic-project';unit_id='unit-reconstruction';event_type='state-transition';summary='Synthetic unit accepted.';receipts=@($validationRelative)}
    $validationTransition=New-TransitionFixture $workspace 'validation-transition' $validationEvent $unit
    $acceptanceTransition=New-TransitionFixture $workspace 'acceptance-transition' $acceptanceEvent $unit
    $plan=[ordered]@{schema='rusty.morphospace.workflow.push_bundle_plan.v1';bundle_id='synthetic-bundle';project_id='synthetic-project';unit_ids=@('unit-reconstruction');prepared_at='2026-01-01T00:00:02Z';dependency_order=@('application','adapter','planning');repositories=@([ordered]@{repo_id='application';role='application';branch='main';commit=$application.prepared;upstream='origin/main';ahead=0;behind=0},[ordered]@{repo_id='adapter';role='adapter';branch='main';commit=$adapter.prepared;upstream='origin/main';ahead=0;behind=0},[ordered]@{repo_id='planning';role='planning';branch='main';commit=$application.prepared;upstream='origin/main';ahead=0;behind=0});source_first=$true;planning_last=$true;execution='not-performed';force_push_allowed=$false}
    $planRelative='receipts/prepared-plan-owner.json'
    Write-ReconstructionJson (Join-Path $workspace ($planRelative-replace'/','\')) ([ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v1';action='PreparePush';push_plan=$plan})
    $prepareEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-reconstruction-push-prepared';sequence=3;timestamp='2026-01-01T00:00:02Z';project_id='synthetic-project';unit_id='unit-reconstruction';event_type='push';summary='Synthetic plan prepared.';receipts=@($planRelative)}
    $prepareTransition=New-TransitionFixture $workspace 'prepare-transition' $prepareEvent $unit
    [IO.File]::WriteAllLines((Join-Path $workspace 'iteration-events.jsonl'),@($validationEvent,$acceptanceEvent,$prepareEvent|ForEach-Object{$_|ConvertTo-Json -Depth 20 -Compress}),[Text.UTF8Encoding]::new($false))
    $blocker=[ordered]@{blocker_id='stale-prepared-publication';condition='Published revisions remain projected as pending.';resume_when='Canonical reconstruction passes.'}
    $pending=[ordered]@{bundle_id='synthetic-bundle';unit_ids=@('unit-reconstruction')}
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
    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $validationIntent=Read-MorphospaceProtocolJson (Join-Path $workspace ($damaged.validation_event.intent.path-replace'/','\'));$validationIntent.event.receipts=@('receipts/different-validation.json')
    Write-ReconstructionJson (Join-Path $workspace ($damaged.validation_event.intent.path-replace'/','\')) $validationIntent;$damaged.validation_event.intent.sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($damaged.validation_event.intent.path-replace'/','\'));Write-ReconstructionJson $input $damaged
    $differentValidationRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$differentValidationRejected=$true};Assert-Reconstruction $differentValidationRejected 'validation event pointing to a different receipt was accepted'
    $validationTransition=New-TransitionFixture $workspace 'validation-transition' $validationEvent $unit

    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $acceptanceIntent=Read-MorphospaceProtocolJson (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\'));$acceptanceIntent.event.receipts=@('receipts/different-validation.json')
    Write-ReconstructionJson (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\')) $acceptanceIntent;$damaged.acceptance_event.intent.sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\'));Write-ReconstructionJson $input $damaged
    $differentAcceptanceRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$differentAcceptanceRejected=$true};Assert-Reconstruction $differentAcceptanceRejected 'acceptance event pointing to different validation provenance was accepted'
    $acceptanceTransition=New-TransitionFixture $workspace 'acceptance-transition' $acceptanceEvent $unit

    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $acceptanceIntent=Read-MorphospaceProtocolJson (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\'));$acceptanceIntent.target.unit.document.status='validating';$acceptanceIntent.target.unit.sha256=Get-MorphospaceCanonicalJsonSha256 $acceptanceIntent.target.unit.document
    Write-ReconstructionJson (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\')) $acceptanceIntent;$damaged.acceptance_event.intent.sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($damaged.acceptance_event.intent.path-replace'/','\'));Write-ReconstructionJson $input $damaged
    $targetMismatchRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$targetMismatchRejected=$true};Assert-Reconstruction $targetMismatchRejected 'accepted transition target-unit byte mismatch was accepted'
    $acceptanceTransition=New-TransitionFixture $workspace 'acceptance-transition' $acceptanceEvent $unit

    $damaged=$document|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $acceptanceCompletion=Read-MorphospaceProtocolJson (Join-Path $workspace ($damaged.acceptance_event.completion.path-replace'/','\'));$acceptanceCompletion.unit_sha256='0'*64
    Write-ReconstructionJson (Join-Path $workspace ($damaged.acceptance_event.completion.path-replace'/','\')) $acceptanceCompletion;$damaged.acceptance_event.completion.sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($damaged.acceptance_event.completion.path-replace'/','\'));Write-ReconstructionJson $input $damaged
    $completionMismatchRejected=$false;try{Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $workspace -UnitId 'unit-reconstruction' -RepoMapPath $mapPath -ReconstructionReceipt $input|Out-Null}catch{$completionMismatchRejected=$true};Assert-Reconstruction $completionMismatchRejected 'acceptance completion unit_sha256 mismatch was accepted'
    $acceptanceTransition=New-TransitionFixture $workspace 'acceptance-transition' $acceptanceEvent $unit

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
