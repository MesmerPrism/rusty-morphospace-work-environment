[CmdletBinding()]
param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$sourceOnly=Import-Module (Join-Path $PSScriptRoot 'SourceOnlyPublication.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
$gitExecutable=(@(Get-Command git -CommandType Application -ErrorAction Stop)[0]).Source

function Write-Json($Path,$Value){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 64)+"`n"),[Text.UTF8Encoding]::new($false))}
function Read-Json($Path){Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json -DateKind String}
function Hash($Path){& $sourceOnly {param($p)Get-MorphospaceFileSha256 $p} $Path}
function Canonical($Value){& $sourceOnly {param($v)Get-MorphospaceCanonicalJsonSha256 $v} $Value}
function Assert-CurrentWork($Fixture,$Phase){try{$validatorExecutable=(@(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0]).Source;$output=@(& $validatorExecutable -NoProfile -File (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -RepoRoot (Split-Path $PSScriptRoot -Parent) -WorkspaceRoot $Fixture.workspace -RepositoryMapPath $Fixture.map -CurrentWorkOnly -SkipOwnerSelfTests 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE -ne 0){throw "Current-work validator returned exit code ${LASTEXITCODE}: $($output -join ' ')"}}catch{throw "Current-work validation failed after source-only ${Phase}: $($_.Exception.Message)`n$($_.ScriptStackTrace)"}}
function Git{
    param([string]$Path)
    $GitArguments=@($args)
    $out=@(& $gitExecutable -C $Path @GitArguments 2>&1|%{[string]$_})
    if($LASTEXITCODE -ne 0){throw "git $($GitArguments-join' ') failed: $($out-join' ')"}
    $out
}
function GitValue{param([string]$Path);$out=@(Git $Path @args);if($out.Count-ne1){throw 'Expected one Git value.'};$out[0].Trim()}
function Copy-Document($Value){$Value|ConvertTo-Json -Depth 64|ConvertFrom-Json -DateKind String}
function Workspace-Fingerprint($Workspace){@(Get-ChildItem -LiteralPath $Workspace -Recurse -File|Sort-Object FullName|%{"$([IO.Path]::GetRelativePath($Workspace,$_.FullName).Replace('\','/'))|$(Hash $_.FullName)"})-join"`n"}
function Assert-Rejected([scriptblock]$Action,$Name,$Expected,$Workspace,$Fixture=$null){$fixtureRoot=if($null -ne $Fixture){$Fixture.root}else{$Workspace};$before=Workspace-Fingerprint $fixtureRoot;try{&$Action;throw "Expected rejection: $Name"}catch{if($_.Exception.Message -like 'Expected rejection:*'){throw};if($_.Exception.Message -notlike $Expected){throw "Unexpected rejection for ${Name}: $($_.Exception.Message)"}};if((Workspace-Fingerprint $fixtureRoot) -cne $before){throw "Rejected $Name mutated the fixture root, including source repositories, planning state, events, or owned artifacts."}}
function Assert-Fault([scriptblock]$Action,$Name,$Fixture){
    if($Name -cnotmatch '^(prepare|record) (after-intent|after-artifact|after-projection|after-event)$'){throw "Fault assertion name is not a supported publication transition: $Name"}
    $phase=$Matches[1];$Stage=$Matches[2];$Workspace=$Fixture.workspace
    if($phase -ceq 'prepare'){$EventId="$($Fixture.plan.publication_id)-source-publication-prepared";$ArtifactPath="receipts/$($Fixture.plan.publication_id)-plan.json"}else{$EventId="$($Fixture.plan.publication_id)-source-publication-recorded";$ArtifactPath="receipts/$($Fixture.plan.publication_id)-execution.json"}
    $TransactionId="$EventId-transition"
    $expected=@{'after-intent'='Injected interruption after intent publication.';'after-artifact'='Injected interruption after artifact installation.';'after-projection'='Injected interruption after projections.';'after-event'='Injected interruption after event append.'}[$Stage]
    $faulted=$false
    try{&$Action}catch{if($_.Exception.Message -cne $expected){throw "Unexpected transition fault for ${Name}: $($_.Exception.Message)"};$faulted=$true}
    if(-not $faulted){throw "Expected transition fault: $Name"}
    $intent=Join-Path $Workspace "receipts/transactions/$TransactionId.intent.json"
    if(-not (Test-Path -LiteralPath $intent -PathType Leaf)){throw "Fault $Name did not publish its transition intent."}
    if($Stage -ne 'after-intent' -and -not (Test-Path -LiteralPath (Join-Path $Workspace $ArtifactPath) -PathType Leaf)){throw "Fault $Name did not install its owned artifact."}
    if($Stage -in @('after-projection','after-event')){$state=Read-Json (Join-Path $Workspace 'workspace.state.json');if([string]$state.last_event_id -cne $EventId){throw "Fault $Name did not install its state projection."}}
    if($Stage -eq 'after-event'){$events=@(Get-Content -LiteralPath (Join-Path $Workspace 'iteration-events.jsonl')|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}|ForEach-Object{$_|ConvertFrom-Json -DateKind String});if([string]$events[-1].event_id -cne $EventId){throw "Fault $Name did not append its event."}}
}
function Remove-FixtureRoot($Root){$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');$candidate=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$parent=[IO.Path]::GetDirectoryName($candidate).TrimEnd('\','/');if(-not $parent.Equals($temp,[StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFileName($candidate).StartsWith('source-only-',[StringComparison]::Ordinal))){throw "Refusing to remove fixture root outside the direct temporary source-only namespace: $candidate"};if(Test-Path -LiteralPath $candidate){Remove-Item -LiteralPath $candidate -Recurse -Force}}

function New-Source($Root,$Id,[string[]]$Paths){
    $remote=Join-Path $Root "$Id.git";$repo=Join-Path $Root $Id
    [IO.Directory]::CreateDirectory($repo)|Out-Null;Git $Root @('init','--bare',$remote)|Out-Null;Git $repo @('init')|Out-Null;Git $repo @('config','core.autocrlf','false')|Out-Null;Git $repo @('config','user.email','fixture@example.invalid')|Out-Null;Git $repo @('config','user.name','Fixture')|Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'baseline.txt'),'base',[Text.UTF8Encoding]::new($false));Git $repo @('add','baseline.txt')|Out-Null;Git $repo @('commit','-m','base')|Out-Null;Git $repo @('branch','-M','main')|Out-Null;Git $repo @('remote','add','origin',$remote)|Out-Null;Git $repo @('push','-u','origin','main')|Out-Null
    $old=GitValue $repo @('rev-parse','HEAD');$oldTree=GitValue $repo @('rev-parse','HEAD^{tree}');Git $repo @('checkout','-b','codex/candidate')|Out-Null;Git $repo @('branch','--set-upstream-to','origin/main')|Out-Null
    foreach($path in $Paths){[IO.File]::WriteAllText((Join-Path $repo $path),"$Id $path",[Text.UTF8Encoding]::new($false))};Git $repo @('add','.')|Out-Null;Git $repo @('commit','-m','reviewed candidate')|Out-Null
    [pscustomobject]@{id=$Id;repo=$repo;remote=$remote;old=$old;old_tree=$oldTree;candidate=(GitValue $repo @('rev-parse','HEAD'));candidate_tree=(GitValue $repo @('rev-parse','HEAD^{tree}'));paths=$Paths}
}
function Publish-Merge($Source,$Root){$merger=Join-Path $Root "merge-$($Source.id)";Git $Source.repo @('push','origin',($Source.candidate+':refs/heads/candidate'))|Out-Null;Git $Root @('clone',$Source.remote,$merger)|Out-Null;Git $merger @('config','user.email','fixture@example.invalid')|Out-Null;Git $merger @('config','user.name','Fixture')|Out-Null;Git $merger @('checkout','main')|Out-Null;Git $merger @('merge','--no-ff','--no-edit','origin/candidate')|Out-Null;Git $merger @('push','origin','main')|Out-Null;Git $Source.repo @('fetch','origin','main')|Out-Null;GitValue $merger @('rev-parse','HEAD')}

function New-Fixture($Root,$PublicationId){
    [IO.Directory]::CreateDirectory($Root)|Out-Null
    $public=New-Source $Root 'public-provider' @('public-carried.txt');$private=New-Source $Root 'private-consumer' @('private-carried.txt','private-agents.md');$readonly=New-Source $Root 'readonly-dependency' @('readonly-input.txt')
    $planning=Join-Path $Root 'planning';$workspace=Join-Path $planning 'morphospace';$inputs=Join-Path $Root 'inputs';[IO.Directory]::CreateDirectory($planning)|Out-Null;[IO.Directory]::CreateDirectory($inputs)|Out-Null;Git $planning @('init')|Out-Null;Git $planning @('config','core.autocrlf','false')|Out-Null;Git $planning @('config','user.email','fixture@example.invalid')|Out-Null;Git $planning @('config','user.name','Fixture')|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts'))|Out-Null
    $unit=[ordered]@{schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id='fixture-unit';project_id='fixture-project';status='active';objective='Publish reviewed source snapshots.';change_categories=@('documentation-only');instruction_impact='none';instruction_surfaces=@();instruction_none_justification='Fixture.';prerequisites=@();allowed_repositories=@([ordered]@{repo_id=$public.id;allowed_paths=@('public-carried.txt')},[ordered]@{repo_id=$private.id;allowed_paths=@('private-carried.txt','private-agents.md')});read_only_dependencies=@([ordered]@{repo_id=$readonly.id;paths=@('readonly-input.txt');purpose='Pinned dependency.';verification='Fixture.'});non_scope=@('Planning publication.');acceptance=@([ordered]@{acceptance_id='host';proof='pass';command='fixture'});risk_tier='standard';device_requirement='none';validation=@([ordered]@{profile_id='host';command='fixture'});outputs=@('source');commit_policy='fixture';push_checkpoint='integration-batch'}
    $event=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='fixture-start';sequence=1;timestamp='2026-01-01T00:00:00Z';project_id='fixture-project';unit_id='fixture-unit';event_type='state-transition';summary='fixture';receipts=@()}
    $exampleRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'examples/hello-morphospace-v2/morphospace'
    $project=Read-Json (Join-Path $exampleRoot 'project.spec.json')
    $project.project_id='fixture-project'
    $project.authority_map[0].owner=$public.id
    $project.validation_profiles=@([ordered]@{profile_id='host';commands=@('fixture')})
    $project.repositories=@(
        [ordered]@{repo_id=$public.id;role='adapter';path='<public-provider>';allowed_paths=@('public-carried.txt')},
        [ordered]@{repo_id=$private.id;role='application';path='<private-consumer>';allowed_paths=@('private-carried.txt','private-agents.md')},
        [ordered]@{repo_id=$readonly.id;role='core';path='<readonly-dependency>';allowed_paths=@('readonly-input.txt')}
    )
    $lock=Read-Json (Join-Path $exampleRoot 'feature.lock.json')
    $lock.project_id='fixture-project'
    $lock.lock_fingerprint=& $sourceOnly {param($value)Get-MorphospaceFeatureLockFingerprint -Lock $value} $lock
    $state=Read-Json (Join-Path $exampleRoot 'workspace.state.json')
    $state.project_id='fixture-project';$state.current_unit='fixture-unit';$state.last_event_id='fixture-start';$state.last_accepted_receipt=$null
    $state.module_registry.lock_fingerprint=$lock.lock_fingerprint
    Write-Json (Join-Path $workspace 'project.spec.json') $project;Write-Json (Join-Path $workspace 'feature.lock.json') $lock;Write-Json (Join-Path $workspace 'workspace.state.json') $state;Write-Json (Join-Path $workspace 'iteration-units/fixture-unit.json') $unit;[IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'),(($event|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $workspace 'receipts/host.txt'),'pass',[Text.UTF8Encoding]::new($false));$hostArtifact=Hash (Join-Path $workspace 'receipts/host.txt')
    $validation=[ordered]@{schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id='fixture-host-pass';project_id='fixture-project';unit_id='fixture-unit';created_at='2026-01-01T00:00:20Z';tier='standard';result='pass';repository_revisions=@([ordered]@{repo_id=$public.id;base_revision=$public.old;head_revision=$public.candidate;branch='codex/candidate'},[ordered]@{repo_id=$private.id;base_revision=$private.old;head_revision=$private.candidate;branch='codex/candidate'},[ordered]@{repo_id=$readonly.id;base_revision=$readonly.old;head_revision=$readonly.candidate;branch='codex/candidate'});changed_paths=@([ordered]@{repo_id=$private.id;path='private-agents.md'});artifacts=@([ordered]@{artifact_id='host';kind='fixture';path='receipts/host.txt';sha256=$hostArtifact});criteria=@([ordered]@{acceptance_id='host';status='pass';command='fixture';evidence_refs=@('host')});gates=@([ordered]@{gate_id='host';status='pass';command='fixture';evidence_refs=@('host')});device_validation=$null};Write-Json (Join-Path $workspace 'receipts/host-pass.json') $validation
    Git $planning @('add','morphospace')|Out-Null;Git $planning @('commit','-m','baseline')|Out-Null;$acceptedState=Read-Json (Join-Path $workspace 'workspace.state.json');$acceptedState.current_unit=$null;$acceptedState.last_event_id='fixture-unit-accepted-0001';$acceptedState.last_accepted_receipt='receipts/host-pass.json';$acceptedState.validation_checkpoint=[ordered]@{tier='standard';receipt='receipts/host-pass.json';result='pass'};$acceptedUnit=Read-Json (Join-Path $workspace 'iteration-units/fixture-unit.json');$acceptedUnit.status='accepted';$acceptedEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='fixture-unit-accepted-0001';sequence=2;timestamp='2026-01-01T00:00:30Z';project_id='fixture-project';unit_id='fixture-unit';event_type='state-transition';summary='accepted';receipts=@('receipts/host-pass.json')};Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId 'fixture-unit-accepted-0001-transition' -StatePath 'workspace.state.json' -UnitPath 'iteration-units/fixture-unit.json' -EventsPath 'iteration-events.jsonl' -TargetState $acceptedState -TargetUnit $acceptedUnit -Event $acceptedEvent|Out-Null;Git $planning @('add','morphospace')|Out-Null;Git $planning @('commit','-m','accepted')|Out-Null
    $map=[ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id=$public.id;path=$public.repo;role='source'},[ordered]@{repo_id=$private.id;path=$private.repo;role='source'},[ordered]@{repo_id=$readonly.id;path=$readonly.repo;role='source'},[ordered]@{repo_id='planning-repo';path=$planning;role='planning'})};$mapPath=Join-Path $inputs 'map.json';Write-Json $mapPath $map;$hostHash=Hash (Join-Path $workspace 'receipts/host-pass.json');$state=Read-Json (Join-Path $workspace 'workspace.state.json');$unit=Read-Json (Join-Path $workspace 'iteration-units/fixture-unit.json')
    function Row($s,$ordinal,$trigger,$carried){[ordered]@{dependency_ordinal=$ordinal;repo_id=$s.id;publication_mode='provider-merge';candidate_branch='codex/candidate';target_branch='main';upstream='origin/main';remote='origin';remote_url=$s.remote;old_revision=$s.old;old_tree=$s.old_tree;candidate_revision=$s.candidate;candidate_tree=$s.candidate_tree;final_revision=$null;final_tree=$s.candidate_tree;changed_paths=$s.paths;trigger_unit_paths=$trigger;carried_paths=$carried;validation_refs=@('host-pass');rollback_revision=$s.old}}
    $plan=[ordered]@{schema='rusty.morphospace.workflow.source_only_publication_plan.v1';publication_id=$PublicationId;project_id='fixture-project';trigger_unit_id='fixture-unit';trigger=[ordered]@{kind='accepted-development-snapshot';accepted_status='accepted';push_checkpoint='integration-batch'};acceptance_transition=[ordered]@{event_id='fixture-unit-accepted-0001';transaction_id='fixture-unit-accepted-0001-transition';validation_receipt=[ordered]@{path='receipts/host-pass.json';sha256=$hostHash}};planning_owner=[ordered]@{repo_id='planning-repo';branch=(GitValue $planning @('branch','--show-current'));head=(GitValue $planning @('rev-parse','HEAD'));tree=(GitValue $planning @('rev-parse','HEAD^{tree}'));remote_policy='no-configured-remotes'};expected=[ordered]@{project_sha256=(Canonical (Read-Json (Join-Path $workspace 'project.spec.json')));state_sha256=(Canonical $state);unit_sha256=(Canonical $unit);events_sha256=(Hash (Join-Path $workspace 'iteration-events.jsonl'));events_length=([IO.FileInfo](Join-Path $workspace 'iteration-events.jsonl')).Length;event_tail_id='fixture-unit-accepted-0001'};source_repositories=@((Row $public 1 @() @('public-carried.txt')),(Row $private 2 @('private-agents.md') @('private-carried.txt')));validation_evidence=@([ordered]@{evidence_id='host-pass';path='receipts/host-pass.json';sha256=$hostHash});preservation=[ordered]@{source_only=$true;planning_remote_required=$false;planning_remote_mutation_claimed=$false;planning_publication_performed=$false;unit_statuses_preserved=$true;acceptance_inferred=$false;validation_inferred=$false;wearer_acceptance_inferred=$false;force_push_allowed=$false}}
    $planPath=Join-Path $inputs 'plan.json';Write-Json $planPath $plan;[pscustomobject]@{root=$Root;workspace=$workspace;inputs=$inputs;map=$mapPath;public=$public;private=$private;readonly=$readonly;plan=$plan;plan_path=$planPath;plan_hash=(Hash $planPath)}
}
function New-Execution($f,$publicFinal,$privateFinal){[ordered]@{schema='rusty.morphospace.workflow.source_only_publication_execution.v1';publication_id=$f.plan.publication_id;project_id='fixture-project';trigger_unit_id='fixture-unit';plan=[ordered]@{path="receipts/$($f.plan.publication_id)-plan.json";sha256=$f.plan_hash};started_at='2026-01-01T00:02:00Z';finished_at='2026-01-01T00:03:00Z';source_repositories=@([ordered]@{dependency_ordinal=1;repo_id=$f.public.id;publication_mode='provider-merge';old_revision=$f.public.old;candidate_revision=$f.public.candidate;final_revision=$publicFinal;remote_readback_revision=$publicFinal;operation_started_at='2026-01-01T00:02:05Z';remote_readback_at='2026-01-01T00:02:20Z';push_mode='fast-forward';force_used=$false;result='pass'},[ordered]@{dependency_ordinal=2;repo_id=$f.private.id;publication_mode='provider-merge';old_revision=$f.private.old;candidate_revision=$f.private.candidate;final_revision=$privateFinal;remote_readback_revision=$privateFinal;operation_started_at='2026-01-01T00:02:25Z';remote_readback_at='2026-01-01T00:02:40Z';push_mode='fast-forward';force_used=$false;result='pass'});rollback=[ordered]@{reverse_dependency_order=@($f.private.id,$f.public.id);required=$false};preservation=[ordered]@{planning_remote_mutation_performed=$false;planning_feature_ref_created=$false;planning_publication_claimed=$false;unit_statuses_changed=$false;acceptance_changed=$false;validation_changed=$false;wearer_acceptance_changed=$false;device_mutation_performed=$false;release_claimed=$false}}}


function Exercise-Recovery($Phase,$Stage){
    $root=Join-Path ([IO.Path]::GetTempPath())("source-only-$Phase-$Stage-"+[guid]::NewGuid().ToString('N'))
    $f=$null
    try{
        $f=New-Fixture $root "fixture-$Phase-$Stage"
        $prepare={param($fixture,$fault,$execute,$hash,$path)Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $fixture.workspace -UnitId fixture-unit -RepoMapPath $fixture.map -SourceOnlyPublicationPlan $path -ExpectedSourceOnlyPublicationPlanSha256 $hash -OutPath (Join-Path $fixture.workspace "receipts/$($fixture.plan.publication_id)-plan.json") -Timestamp '2026-01-01T00:01:00Z' -Execute:$execute -FaultAfter $fault}
        if($Phase -ceq 'prepare'){
            Assert-Fault {&$prepare $f $Stage $true $f.plan_hash $f.plan_path} "prepare $Stage" $f
            Assert-Rejected {&$prepare $f none $false $f.plan_hash $f.plan_path} 'partial prepare dry replay' '*requires -Execute recovery*' $f.workspace $f
            $same=Join-Path $f.inputs 'same-id-plan.json';[IO.File]::WriteAllText($same,(Get-Content -Raw $f.plan_path)+' ',[Text.UTF8Encoding]::new($false))
            Assert-Rejected {&$prepare $f none $true (Hash $same) $same} 'partial prepare changed input' '*caller bytes do not match*' $f.workspace $f
            &$prepare $f none $true $f.plan_hash $f.plan_path|Out-Null
            return
        }
        &$prepare $f none $true $f.plan_hash $f.plan_path|Out-Null
        $pub=Publish-Merge $f.public $root;$priv=Publish-Merge $f.private $root
        $executionPath=Join-Path $f.inputs 'execution.json';Write-Json $executionPath (New-Execution $f $pub $priv);$executionHash=Hash $executionPath
        $record={param($fixture,$fault,$execute,$hash,$path)Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $fixture.workspace -UnitId fixture-unit -RepoMapPath $fixture.map -SourceOnlyPublicationExecution $path -ExpectedSourceOnlyPublicationExecutionSha256 $hash -OutPath (Join-Path $fixture.workspace "receipts/$($fixture.plan.publication_id)-execution.json") -Timestamp '2026-01-01T00:04:00Z' -Execute:$execute -FaultAfter $fault}
        Assert-Fault {&$record $f $Stage $true $executionHash $executionPath} "record $Stage" $f
        Assert-Rejected {&$record $f none $false $executionHash $executionPath} 'partial record dry replay' '*requires -Execute recovery*' $f.workspace $f
        $same=Join-Path $f.inputs 'same-id-execution.json';[IO.File]::WriteAllText($same,(Get-Content -Raw $executionPath)+' ',[Text.UTF8Encoding]::new($false))
        Assert-Rejected {&$record $f none $true (Hash $same) $same} 'partial record changed input' '*caller bytes do not match*' $f.workspace $f
        &$record $f none $true $executionHash $executionPath|Out-Null
    }catch{
        $failureMessage=$_.Exception.Message
        $planningDiagnostic='fixture creation did not return'
        if($null -ne $f){
            try{
                $planningRoot=Split-Path $f.workspace -Parent
                $dirtyPaths=@(Git $planningRoot @('status','--porcelain=v1','--untracked-files=all'))
                $planningDiagnostic="planning=$planningRoot; status=$($dirtyPaths -join ' | ')"
                if($planningDiagnostic.Length -gt 2048){$planningDiagnostic=$planningDiagnostic.Substring(0,2048)}
            }catch{$planningDiagnostic='planning status diagnostic unavailable'}
        }
        throw "Recovery fixture [$Phase/$Stage] failed: $failureMessage; $planningDiagnostic"
    }finally{Remove-FixtureRoot $root}
}

$root=Join-Path ([IO.Path]::GetTempPath())('source-only-publication-'+[guid]::NewGuid().ToString('N'))
try{
    $f=New-Fixture $root 'fixture-source-publication';Assert-Rejected {Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationPlan $f.plan_path -OutPath (Join-Path $f.workspace 'receipts/fixture-source-publication-plan.json') -Execute} 'prepare missing reviewed hash' '*dry-run plan SHA-256*' $f.workspace
    $bad=Copy-Document $f.plan;$bad.expected.project_sha256='0'*64;$badPath=Join-Path $f.inputs 'project-drift.json';Write-Json $badPath $bad;Assert-Rejected {Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationPlan $badPath -OutPath (Join-Path $f.workspace 'receipts/fixture-source-publication-plan.json')} 'project drift' '*expected project drifted*' $f.workspace
    $aliasMap=Copy-Document (Read-Json $f.map);$aliasMap.repositories[1].path=$f.public.repo;$aliasMapPath=Join-Path $f.inputs 'physical-source-alias-map.json';Write-Json $aliasMapPath $aliasMap;Assert-Rejected {Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $aliasMapPath -SourceOnlyPublicationPlan $f.plan_path -OutPath (Join-Path $f.workspace 'receipts/fixture-source-publication-plan.json')} 'physical source alias' '*share physical repository or Git authority*' $f.workspace
    Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationPlan $f.plan_path -ExpectedSourceOnlyPublicationPlanSha256 $f.plan_hash -OutPath (Join-Path $f.workspace 'receipts/fixture-source-publication-plan.json') -Timestamp '2026-01-01T00:01:00Z' -Execute|Out-Null
    Assert-CurrentWork $f 'Prepare'
    $publicFinal=Publish-Merge $f.public $root;$privateFinal=Publish-Merge $f.private $root;$execution=New-Execution $f $publicFinal $privateFinal;$executionPath=Join-Path $f.inputs 'execution.json';Write-Json $executionPath $execution;$executionHash=Hash $executionPath
    $badExecution=Copy-Document $execution;$badExecution.source_repositories[1].operation_started_at='2026-01-01T00:02:10Z';$badExecutionPath=Join-Path $f.inputs 'out-of-order.json';Write-Json $badExecutionPath $badExecution;Assert-Rejected {Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationExecution $badExecutionPath -OutPath (Join-Path $f.workspace 'receipts/fixture-source-publication-execution.json')} 'provider before consumer chronology' '*not ordered by dependency ordinal*' $f.workspace
    Assert-Rejected {Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationExecution $executionPath -OutPath (Join-Path $f.workspace 'receipts/fixture-source-publication-execution.json') -Execute} 'record missing reviewed hash' '*dry-run execution SHA-256*' $f.workspace
    Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationExecution $executionPath -ExpectedSourceOnlyPublicationExecutionSha256 $executionHash -OutPath (Join-Path $f.workspace 'receipts/fixture-source-publication-execution.json') -Timestamp '2026-01-01T00:04:00Z' -Execute|Out-Null
    Assert-CurrentWork $f 'Record'
    Assert-Rejected {Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationExecution $executionPath -OutPath (Join-Path $f.workspace 'receipts/fixture-source-publication-execution.json')} 'completed replay missing hash' '*requires its reviewed SHA-256*' $f.workspace
    Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationExecution $executionPath -ExpectedSourceOnlyPublicationExecutionSha256 $executionHash -OutPath (Join-Path $f.workspace 'receipts/fixture-source-publication-execution.json') -Execute|Out-Null
    foreach($stage in @('after-intent','after-artifact','after-projection','after-event')){Exercise-Recovery prepare $stage;Exercise-Recovery record $stage}
    'Source-only publication self-test passed.'
}finally{Remove-FixtureRoot $root}
