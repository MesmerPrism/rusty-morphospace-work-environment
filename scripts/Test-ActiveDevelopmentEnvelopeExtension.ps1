param([switch]$SelfTest,[switch]$RetainedAuthorityOnly,[switch]$CheckpointProofOnly,[switch]$PreparationConsumerOnly,[switch]$ExtendedSourceConsumerOnly)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
& (Join-Path $PSScriptRoot 'Test-PlanningAuthorityRelocation.ps1') -SelfTest

$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopePreparation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force
$automationModule=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force -PassThru
$extensionModule=Import-Module (Join-Path $PSScriptRoot 'ActiveDevelopmentEnvelopeExtension.psm1') -Force -PassThru
$freezeModule=Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -PassThru
$retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
$scopeAmendmentModule=Import-Module (Join-Path $PSScriptRoot 'ActiveWriteScopeAmendment.psm1') -PassThru
$scopeProvenanceModule=Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1') -PassThru
$transitionPath=Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1'
$transitionModule=@(Get-Module -All|Where-Object{$_.Path-eq$transitionPath}|Select-Object -Last 1)[0]
if($null-eq$transitionModule){throw 'Active-envelope test cannot retain the transition-ledger module.'}
$continuationModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceDevelopmentContinuation.psm1') -PassThru
. (Join-Path $PSScriptRoot 'test-support\DevelopmentAdmissionFixture.ps1')
. (Join-Path $PSScriptRoot 'test-support\ActiveUnitRetirementFixture.ps1')

function Assert-ActiveEnvelopeTest([bool]$Condition,[string]$Message){if(-not$Condition){throw "Active development-envelope extension self-test failed: $Message"}}
function Assert-ActiveEnvelopeRejected([scriptblock]$Action,[string]$Message){$rejected=$false;try{&$Action|Out-Null}catch{$rejected=$true};Assert-ActiveEnvelopeTest $rejected $Message}

function Test-ActiveEnvelopeBuildPreflightConsumer([string]$Workspace,[string]$UnitId,[string]$Root,[string]$RepositoryMapPath=''){
    # Consume persisted owner artifacts. Materialize their exact tiny fixture
    # commits rather than replacing a locked source with its later planning HEAD.
    $unit=Read-EnvelopeProtocolJson (Join-Path $Workspace "iteration-units/$UnitId.json")
    $source=Read-EnvelopeProtocolJson (Join-Path $Workspace ([string]$unit.source_composition.lock_path))
    if(-not$RepositoryMapPath){$RepositoryMapPath=Join-Path $Workspace 'repository-map.json'}
    $map=Read-EnvelopeProtocolJson $RepositoryMapPath
    [void][IO.Directory]::CreateDirectory($Root)
    $rows=@($source.repositories|Sort-Object repo_id|ForEach-Object{
        $derivative=$_.PSObject.Properties.Name-contains'effective_commit'
        [pscustomobject]@{repo_id=[string]$_.repo_id;commit=$(if($derivative){[string]$_.effective_commit}else{[string]$_.commit});tree=$(if($derivative){[string]$_.effective_tree}else{[string]$_.tree})}
    });$materialized=@()
    foreach($row in $rows){
        $mapping=@($map.repositories|Where-Object repo_id -CEQ $row.repo_id)
        Assert-ActiveEnvelopeTest ($mapping.Count-eq1) 'preflight fixture lacks an exact owner mapping'
        $path=Join-Path $Root ([string]$row.repo_id)
        Invoke-EnvelopeGit $Root @('clone','--quiet','--no-hardlinks','--no-checkout',[string]$mapping[0].path,$path)|Out-Null
        Invoke-EnvelopeGit $path @('checkout','--quiet','--detach',[string]$row.commit)|Out-Null
        $materialized+=,[pscustomobject]@{row=$row;path=$path}
    }
    $tool=Join-Path $Root 'gradle.bat';$marker=Join-Path $Root 'compiler-started.txt'
    [IO.File]::WriteAllText($tool,"@echo compiler-started> `"$marker`"`r`n",[Text.UTF8Encoding]::new($false))
    for($count=0;$count-le[math]::Min(2,$materialized.Count-1);$count++){
        $bindings=@();$external=@();$environment=[ordered]@{}
        for($i=0;$i-lt$count;$i++){
            $entry=$materialized[$i+1];$id="source-$i";$environment["SOURCE_$i"]=$id
            $bindings+=,[pscustomobject][ordered]@{id=$id;path=$entry.path;kind='directory';git_revision=[string]$entry.row.commit;git_tree=[string]$entry.row.tree}
            $external+=,[pscustomobject][ordered]@{source_id=[string]$entry.row.repo_id;binding_id=$id;git_revision=[string]$entry.row.commit;git_tree=[string]$entry.row.tree}
        }
        $profile=[pscustomobject][ordered]@{schema='rusty.morphospace.quest_build_profile.v1';profile_id='prepared-source-consumer';working_directory='.';executable='gradle';arguments=@();environment=[pscustomobject]$environment;artifact=[pscustomobject]@{relative_path='fixture.apk';kind='single-base-apk'};preflight=[pscustomobject]@{source_composition=[pscustomobject]@{source=[pscustomobject]@{git_revision=[string]$materialized[0].row.commit;git_tree=[string]$materialized[0].row.tree;require_clean=$true};external_sources=@($external)};output=[pscustomobject]@{lane='warm';collision_policy='new-only';allow_source_root=$true}}}
        $profilePath=Join-Path $Root "profile-$count.json";Write-EnvelopeJson $profilePath $profile
        $bindingsPath=Join-Path $Root "bindings-$count.json";Write-EnvelopeJson $bindingsPath ([pscustomobject]@{schema='rusty.morphospace.local_quest_build_environment.v1';bindings=@($bindings)})
        $persisted=Read-EnvelopeProtocolJson $profilePath
        Assert-ActiveEnvelopeTest ($persisted.arguments-is[Array]-and$persisted.preflight.source_composition.external_sources-is[Array]-and@($persisted.preflight.source_composition.external_sources).Count-eq$count) 'persisted profile lost zero/one/two array cardinality'
        $args=@('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Invoke-QuestBuildProfile.ps1'),'-Mode','Preflight','-ProfilePath',$profilePath,'-ProfileSha256',(Get-EnvelopeFileSha256 $profilePath),'-SourceRoot',$materialized[0].path,'-ToolPath',$tool,'-ToolSha256',(Get-EnvelopeFileSha256 $tool))
        if($count-gt0){$args+=@('-EnvironmentBindingsPath',$bindingsPath,'-EnvironmentBindingsSha256',(Get-EnvelopeFileSha256 $bindingsPath))}
        $output=@(& pwsh @args);$exit=$LASTEXITCODE;$terminal=($output-join"`n")|ConvertFrom-Json -Depth 64 -DateKind String
        $resultPath=Join-Path $Root "terminal-$count.json";Write-EnvelopeJson $resultPath $terminal;$persistedTerminal=Read-EnvelopeProtocolJson $resultPath
        Assert-ActiveEnvelopeTest ($exit-eq0-and$persistedTerminal.operation-ceq'preflight'-and$persistedTerminal.terminal_status-ceq'passed'-and-not$persistedTerminal.child_process.started-and$persistedTerminal.owner_payload.source_composition.external_sources-is[Array]-and@($persistedTerminal.owner_payload.source_composition.external_sources).Count-eq$count-and-not(Test-Path -LiteralPath $marker)) "writer source lock did not reach real build preflight or preflight spawned the compiler: exit=$exit count=$count terminal=$($terminal|ConvertTo-Json -Depth 16 -Compress)"
        # Change one persisted source identity, retaining a valid profile hash.
        $profile.preflight.source_composition.source.git_tree='0'*40;Write-EnvelopeJson $profilePath $profile
        $badArgs=@($args);$hashIndex=[Array]::IndexOf($badArgs,'-ProfileSha256')+1;$badArgs[$hashIndex]=Get-EnvelopeFileSha256 $profilePath
        $badOutput=@(& pwsh @badArgs);$badExit=$LASTEXITCODE;$bad=($badOutput-join"`n")|ConvertFrom-Json -Depth 64
        Assert-ActiveEnvelopeTest ($badExit-eq2-and$bad.terminal_status-ceq'contradiction'-and@($bad.reason_codes)-contains'source-composition-source-mismatch'-and-not$bad.child_process.started-and-not(Test-Path -LiteralPath $marker)) 'mismatched persisted source reached compilation or passed preflight'
    }
}

# Adapt fixture inputs before acceptance. Durable acceptance records come from
# the owner writer; the ordinary case retains an externally supplied receipt.
function New-ActiveEnvelopeCheckpointWriter([switch]$SeparateReceiptProducer,[switch]$ExternalReceipt){
New-Module -ArgumentList $transitionModule,$SeparateReceiptProducer.IsPresent,$ExternalReceipt.IsPresent -ScriptBlock {
    param($ProductionWriter,$SeparateProducer,$External)
    $script:writer=$ProductionWriter
    $script:separateProducer=$SeparateProducer
    $script:externalReceipt=$External
    function Start-MorphospaceTransitionLedger {
        param($WorkspaceRoot,$TransactionId,$StatePath,$UnitPath,$EventsPath,$TargetState,$TargetUnit,$Event)
        if([string]$TargetUnit.status-cne'accepted'){
            &$script:writer {param($a)Start-MorphospaceTransitionLedger @a} $PSBoundParameters
            return
        }
        $TargetState.validation_checkpoint=[pscustomobject][ordered]@{tier='quick';receipt=[string]$TargetState.last_accepted_receipt;result='pass'}
        $receiptPath=Join-Path $WorkspaceRoot ([string]$TargetState.last_accepted_receipt)
        &$script:writer {param($w,$t,$s,$u,$e,$ts,$tu,$ev,$receipt,$separate,$external)
            $validation=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id='u001-accepted';project_id=$ts.project_id;unit_id='u001';created_at='2026-08-24T23:58:00.0000000Z';tier='quick';result='pass';repository_revisions=@();changed_paths=@();artifacts=@([pscustomobject]@{artifact_id='fixture-project';kind='fixture';path='project.spec.json';sha256=Get-MorphospaceFileSha256 (Join-Path $w 'project.spec.json')});criteria=@([pscustomobject]@{acceptance_id='fixture-accepted';status='pass';command='Fixture predecessor validation.';evidence_refs=@('fixture-project')});gates=@([pscustomobject]@{gate_id='fixture-gate';status='pass';command='Fixture predecessor validation.';evidence_refs=@('fixture-project')});device_validation=$null}
            $bytes=ConvertTo-MorphospaceProtocolJsonBytes $validation
            # Prepare the unaccepted draft before the production writer seals its target.
            # Receipts may be supplied externally or retained as owner artifacts.
            if($external){[IO.File]::WriteAllBytes($receipt,$bytes)}else{Remove-Item -LiteralPath $receipt}
            $preStatePath=Join-Path $w $s;$preUnitPath=Join-Path $w $u;$eventsPath=Join-Path $w $e
            $preState=Read-MorphospaceProtocolJson $preStatePath;$preUnit=Read-MorphospaceProtocolJson $preUnitPath
            $artifacts=@([pscustomobject]@{path=[string]$ts.last_accepted_receipt;sha256=Get-MorphospaceSha256Bytes $bytes;bytes_base64=[Convert]::ToBase64String($bytes)})
            if($external){$artifacts=@()}
            if($separate){
                $producerState=$preState|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
                $producerUnit=$preUnit|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
                $producerUnit.status='validating';$producerState.current_unit='u001';$producerState.validation_checkpoint=$ts.validation_checkpoint;$producerState.last_event_id='u001-validation-pass-0001'
                $producerEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='u001-validation-pass-0001';sequence=1;timestamp='2026-08-24T23:59:00.0000000Z';project_id=$ts.project_id;unit_id='u001';event_type='state-transition';summary='Recorded the fixture predecessor validation artifact.';receipts=@([string]$ts.last_accepted_receipt)}
                Start-MorphospaceTransitionLedger -WorkspaceRoot $w -TransactionId 'u001-validation-pass-0001-transition' -StatePath $s -UnitPath $u -EventsPath $e -TargetState $producerState -TargetUnit $producerUnit -Event $producerEvent -ExpectedPreStateSha256 (Get-MorphospaceCanonicalJsonSha256 $preState) -ExpectedPreUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $preUnit) -ExpectedEventsSha256 (Get-MorphospaceFileSha256 $eventsPath) -ExpectedEventsLength ([IO.FileInfo]$eventsPath).Length -Artifacts $artifacts|Out-Null
                $preState=Read-MorphospaceProtocolJson $preStatePath;$preUnit=Read-MorphospaceProtocolJson $preUnitPath;$artifacts=@()
                $ev.sequence=2
            }
            Start-MorphospaceTransitionLedger -WorkspaceRoot $w -TransactionId $t -StatePath $s -UnitPath $u -EventsPath $e -TargetState $ts -TargetUnit $tu -Event $ev -ExpectedPreStateSha256 (Get-MorphospaceCanonicalJsonSha256 $preState) -ExpectedPreUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $preUnit) -ExpectedEventTailId ([string]$preState.last_event_id) -ExpectedEventsSha256 (Get-MorphospaceFileSha256 $eventsPath) -ExpectedEventsLength ([IO.FileInfo]$eventsPath).Length -Artifacts $artifacts
        } $WorkspaceRoot $TransactionId $StatePath $UnitPath $EventsPath $TargetState $TargetUnit $Event $receiptPath $script:separateProducer $script:externalReceipt
    }
}
}
$checkpointWriter=New-ActiveEnvelopeCheckpointWriter -ExternalReceipt

function Invoke-RetainedAuthorityFocusedTests {
    $surface=[pscustomobject][ordered]@{surface_kind='readme';path='README.md';owner='workflow-owner';change_reason='Keep the declared instruction current.';action='update';status='planned';validation='Observe the exact managed file.'}
    $before=[pscustomobject][ordered]@{schema='test.unit';project_id='test-project';unit_id='test-unit';status='active';objective='Preserve the admitted objective.';prerequisites=@('prior-unit');acceptance=@('The admitted acceptance remains exact.');instruction_none_justification=$null;instruction_surfaces=@($surface)}
    $statusAfter=Copy-Envelope $before;$statusAfter.status='validating'
    [void](&$continuationModule {param($b,$a)Assert-DevelopmentContinuationRetainedAuthority $b $a ([pscustomobject]@{artifacts=@()}) ([pscustomobject]@{})} $before $statusAfter)
    $nonNull=Copy-Envelope $before;$nonNull.instruction_none_justification='Changed optional authority.'
    foreach($pair in @(@($before,$nonNull),@($nonNull,$before))){
        $rejected=$false
        try{&$continuationModule {param($b,$a)Assert-DevelopmentContinuationRetainedAuthority $b $a ([pscustomobject]@{artifacts=@()}) ([pscustomobject]@{})} $pair[0] $pair[1]|Out-Null}
        catch{if($_.Exception.Message-cne'Development continuation retained authority/instruction_none_justification is detached.'){throw};$rejected=$true}
        Assert-ActiveEnvelopeTest $rejected 'retained continuation accepted a null/non-null authority change'
    }
    foreach($mutation in @('objective','acceptance','prerequisites')){
        $forged=Copy-Envelope $before
        switch($mutation){'objective'{$forged.objective='Forged objective.'};'acceptance'{$forged.acceptance=@('Forged acceptance.')};'prerequisites'{$forged.prerequisites=@('forged-prerequisite')}}
        Assert-ActiveEnvelopeRejected {&$continuationModule {param($b,$a)Assert-DevelopmentContinuationRetainedAuthority $b $a ([pscustomobject]@{artifacts=@()}) ([pscustomobject]@{})} $before $forged} "retained continuation accepted forged $mutation"
    }
    $instructionAfter=Copy-Envelope $before;$instructionAfter.instruction_surfaces[0].status='complete'
    $preHash=&$protocolModule {param($v)Get-MorphospaceCanonicalJsonSha256 $v} $before
    $targetHash=&$protocolModule {param($v)Get-MorphospaceCanonicalJsonSha256 $v} $instructionAfter
    $event=[pscustomobject][ordered]@{project_id='test-project';unit_id='test-unit';event_id='test-instructions-recorded';event_type='state-transition';summary='Completed the exact declared instruction-surface set after stable content observation without executing validation commands.';receipts=@('receipts/test-instructions.json')}
    $completion=[pscustomobject][ordered]@{completion_id='test-instructions';expected_unit_sha256=$preHash;resulting_unit_sha256=$targetHash;observation_sha256=('b'*64);all_planned_surfaces_completed=$true;surface_files_observed_stable=$true;validation_commands_executed=$false;surfaces=@([pscustomobject][ordered]@{surface_id=('c'*64);surface_kind='readme';declared_path='README.md';repo_id='test-repo';relative_path='README.md';owner='workflow-owner';action='update';validation='Observe the exact managed file.';skill_id=$null;previous_status='planned';resulting_status='complete';sha256=('d'*64)})}
    $claimPreflight=[pscustomobject][ordered]@{version='v1';ready_to_claim=$false;validation_tier='quick';requirements_declared=$false;disk=@();tools=@();product_inputs=@();writable_repositories=@();read_only_dependencies=@();instruction_surfaces=@();resources=@();validation_matrix=@();issues=@()}
    $receipt=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v1';project_id='test-project';unit_id='test-unit';action='CompleteInstructionSurfaces';timestamp='2026-09-15T02:00:00.0000000Z';executed=$true;transition='planned-instruction-surfaces-to-complete';status_before='active';status_after='active';current_unit_before='test-unit';current_unit_after='test-unit';preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;force_push_allowed=$false;repository_states=@()};validation_matrix=@();graph_scope=[pscustomobject]@{repositories=@()};claim_preflight=$claimPreflight;adoption_receipt=$null;publication_closure=$null;published_planning_authority_adoption=$null;planned_publication=$null;planning_suffix_rewrite_recovery=$null;published_prerequisite_suffix_reconciliation=$null;executed_prepared_publication_reconciliation=$null;instruction_surface_completion=$completion;ready_withdrawal=$null;proposed_retirement=$null;terminal_validation_selection_release=$null;push_plan=$null;event_id='test-instructions-recorded'}
    $receiptBytes=&$protocolModule {param($v)ConvertTo-MorphospaceProtocolJsonBytes $v} $receipt
    $intent=[pscustomobject]@{pre=[pscustomobject]@{unit=[pscustomobject]@{sha256=$preHash}};target=[pscustomobject]@{unit=[pscustomobject]@{sha256=$targetHash}};artifacts=@([pscustomobject]@{path='receipts/test-instructions.json';sha256=(&$protocolModule {param($b)Get-MorphospaceSha256Bytes $b} $receiptBytes);bytes_base64=[Convert]::ToBase64String($receiptBytes)})}
    [void](&$continuationModule {param($b,$a,$i,$e)Assert-DevelopmentContinuationRetainedAuthority $b $a $i $e} $before $instructionAfter $intent $event)
    $rowRewrite=Copy-Envelope $instructionAfter;$rowRewrite.instruction_surfaces[0].owner='forged-owner'
    Assert-ActiveEnvelopeRejected {&$continuationModule {param($b,$a,$i,$e)Assert-DevelopmentContinuationRetainedAuthority $b $a $i $e} $before $rowRewrite $intent $event} 'retained continuation accepted an instruction row rewrite'
    [pscustomobject]@{result='pass';retained_status=$true;retained_null_authority=$true;changed_null_authority_rejected=$true;retained_instruction_completion=$true;forged_objective=$true;forged_acceptance=$true;forged_prerequisites=$true;forged_instruction_row=$true}
}

function New-ActiveEnvelopeExtensionRequest {
    param([string]$Workspace,[string]$AddedRepository,[string]$RequestPath,[string]$AddedOwnerRoot='')
    $project=Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json')
    $lock=Read-EnvelopeProtocolJson (Join-Path $Workspace 'feature.lock.json')
    $state=Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json')
    $unit=Read-EnvelopeProtocolJson (Join-Path $Workspace 'iteration-units\u002.json')
    $source=Read-EnvelopeProtocolJson (Join-Path $Workspace ([string]$unit.source_composition.lock_path))
    $map=Read-EnvelopeProtocolJson (Join-Path $Workspace 'repository-map.json')
    $targetMap=Copy-Envelope $map
    $targetMap.repositories+=,[pscustomobject][ordered]@{repo_id='added-dependency';path=$AddedRepository;role='source'}
    $targetMapPath=Join-Path $Workspace 'repository-map-extension.json';Write-EnvelopeJson $targetMapPath $targetMap
    $targetProject=Copy-Envelope $project;$targetProject.revision=[int]$project.revision+1
    $targetProject.repositories+=,[pscustomobject][ordered]@{repo_id='added-dependency';role='core';path='../added-repository';allowed_paths=@('dep/')}
    $targetLock=Copy-Envelope $lock;$targetLock.project_revision=[int]$targetProject.revision;$targetLock.revision=[int]$lock.revision+1;$targetLock.generated_at='2026-09-15T01:00:00.0000000Z';$targetLock.lock_fingerprint='0'*64;$targetLock.lock_fingerprint=Get-EnvelopeCanonicalJsonSha256 $targetLock
    $targetState=Copy-Envelope $state;$targetState.plan_revision=[int]$state.plan_revision+1;$targetState.last_event_id='u002-add-dependency-recorded';$targetState.module_registry.lock_revision=[int]$targetLock.revision;$targetState.module_registry.lock_fingerprint=[string]$targetLock.lock_fingerprint
    $assessment=Copy-Envelope $unit.agent_scope_assessment
    $assessment.owner_repositories+=,[pscustomobject][ordered]@{repo_id='added-dependency';source_roots=@('dep/')}
    $allowed=@(Copy-Envelope @($unit.allowed_repositories))
    $readOnly=@(Copy-Envelope @($(if($unit.PSObject.Properties.Name-contains'read_only_dependencies'){$unit.read_only_dependencies}else{@()})))
    $readOnly+=,[pscustomobject][ordered]@{repo_id='added-dependency';paths=@('dep/');purpose='Compile against the newly discovered code dependency.';verification='Keep the dependency at the exact derivative source identity.'}
    $emptyEffects=[ordered]@{};foreach($axis in @('permissions','services','activities','queries','tools','assets','shaders','native_libraries','commands','routes','streams','inputs','scenes','markers')){$emptyEffects[$axis]=@()}
    $eventsPath=Join-Path $Workspace 'iteration-events.jsonl';$events=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String})
    $sourcePath=Join-Path $Workspace ([string]$unit.source_composition.lock_path)
    $mapPath=Join-Path $Workspace 'repository-map.json'
    $request=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.active_development_envelope_extension.v1'
        extension_id='u002-add-dependency';project_id='envelope-test';unit_id='u002'
        rationale='The unchanged objective requires one newly discovered compile-time dependency owned by the declared repository.'
        ownership_proof=@([pscustomobject][ordered]@{repo_id='added-dependency';source_roots=@('dep/');owner='dependency-owner';evidence='The committed dependency root and its read-only role were reviewed against the unchanged objective.'})
        additions=[pscustomobject][ordered]@{repository_ids=@('added-dependency');owner_roots=@([pscustomobject][ordered]@{repo_id='added-dependency';source_roots=@('dep/')});feature_ids=@();module_ids=@();authority_parameters=@();effects=[pscustomobject]$emptyEffects;permissions=@();validation_profile_ids=@();acceptance_profile_ids=@();build_profile_ids=@();device_kinds=@()}
        before=[pscustomobject][ordered]@{project=$project;feature_lock=$lock;state=$state;agent_scope_assessment=$unit.agent_scope_assessment;allowed_repositories=@($unit.allowed_repositories);read_only_dependencies=@($(if($unit.PSObject.Properties.Name-contains'read_only_dependencies'){$unit.read_only_dependencies}else{@()}))}
        target=[pscustomobject][ordered]@{project=$targetProject;feature_lock=$targetLock;state=$targetState;agent_scope_assessment=$assessment;allowed_repositories=@($allowed);read_only_dependencies=@($readOnly)}
        source_composition=[pscustomobject][ordered]@{path='source-composition-locks/u002-add-dependency.json';repository_ids=@(@($source.repositories.repo_id)+@('added-dependency')|Sort-Object -Unique)}
        effective_repository_map=[pscustomobject][ordered]@{path='repository-map-extension.json';raw_sha256=Get-EnvelopeFileSha256 $targetMapPath}
        expected=[pscustomobject][ordered]@{
            status='active';current_unit='u002';project_revision=[int]$project.revision;feature_lock_revision=[int]$lock.revision;plan_revision=[int]$state.plan_revision
            project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;project_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'project.spec.json')
            feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $lock;feature_lock_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'feature.lock.json')
            state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;state_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'workspace.state.json')
            unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;unit_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'iteration-units\u002.json')
            events_sha256=Get-EnvelopeFileSha256 $eventsPath;events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$events[-1].event_id
            source_composition_path=[string]$unit.source_composition.lock_path;source_composition_raw_sha256=Get-EnvelopeFileSha256 $sourcePath;source_composition_canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $source
            repository_map_path='repository-map.json';repository_map_raw_sha256=Get-EnvelopeFileSha256 $mapPath
            original_source_composition_path=[string]$unit.source_composition.lock_path;original_source_composition_raw_sha256=Get-EnvelopeFileSha256 $sourcePath
            original_repository_map_path='repository-map.json';original_repository_map_raw_sha256=Get-EnvelopeFileSha256 $mapPath
        }
        does_not_prove=@('Does not change the objective, validate, accept, publish, mutate Git, or operate a device.')
    }
    if($AddedOwnerRoot){
        # A roots-only extension retains the actual admitted map and every
        # existing source row; it grants no new feature or repository identity.
        Remove-Item -LiteralPath $targetMapPath
        $targetMapPath=$mapPath
        $request.extension_id='u002-add-root'
        $request.rationale='The unchanged documentation objective requires one additional exact root in the existing writable repository.'
        $request.ownership_proof=@([pscustomobject][ordered]@{repo_id='project-shell';source_roots=@($AddedOwnerRoot);owner='project-shell';evidence='The existing repository owner reviewed the additional documentation root against the unchanged objective.'})
        $request.additions.repository_ids=@()
        $request.additions.owner_roots=@([pscustomobject][ordered]@{repo_id='project-shell';source_roots=@($AddedOwnerRoot)})
        $request.target.project.repositories=@(Copy-Envelope @($project.repositories))
        @($request.target.project.repositories|Where-Object{$_.repo_id-ceq'project-shell'})[0].allowed_paths+=,$AddedOwnerRoot
        $request.target.agent_scope_assessment=Copy-Envelope $unit.agent_scope_assessment
        @($request.target.agent_scope_assessment.owner_repositories|Where-Object{$_.repo_id-ceq'project-shell'})[0].source_roots+=,$AddedOwnerRoot
        $request.target.allowed_repositories=@(Copy-Envelope @($unit.allowed_repositories))
        @($request.target.allowed_repositories|Where-Object{$_.repo_id-ceq'project-shell'})[0].allowed_paths+=,$AddedOwnerRoot
        $request.target.read_only_dependencies=@(Copy-Envelope @($unit.read_only_dependencies))
        $request.target.state.last_event_id='u002-add-root-recorded'
        $request.source_composition.path='source-composition-locks/u002-add-root.json'
        $request.source_composition.repository_ids=@($source.repositories|ForEach-Object{[string]$_.repo_id})
        $request.effective_repository_map.path='repository-map.json'
        $request.effective_repository_map.raw_sha256=Get-EnvelopeFileSha256 $mapPath
    }
    Write-EnvelopeJson $RequestPath $request
    return [pscustomobject]@{request=$request;request_path=$RequestPath;map_path=$targetMapPath;receipt_path=(Join-Path $Workspace ('receipts/'+$request.extension_id+'.json'));source_path=(Join-Path $Workspace ([string]$request.source_composition.path))}
}

function New-ActiveEnvelopeFreezeRequest {
    param([string]$Workspace,[string]$RepositoryMapPath,[string]$RequestPath,[string]$UnitId='u002')
    $project=Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json');$lock=Read-EnvelopeProtocolJson (Join-Path $Workspace 'feature.lock.json');$state=Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json');$unit=Read-EnvelopeProtocolJson (Join-Path $Workspace "iteration-units/$UnitId.json")
    $eventsPath=Join-Path $Workspace 'iteration-events.jsonl';$events=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String});$map=Read-EnvelopeProtocolJson $RepositoryMapPath;$mapRows=@{};foreach($row in @($map.repositories)){$mapRows[[string]$row.repo_id]=$row}
    $final=[Collections.Generic.List[object]]::new();$changed=[Collections.Generic.List[object]]::new()
    foreach($scope in @($unit.allowed_repositories)){
        $id=[string]$scope.repo_id;if(-not$mapRows.ContainsKey($id)){throw "Freeze fixture writable repository '$id' is absent from the effective map."};$root=[string]$mapRows[$id].path
        $head=(@(Invoke-EnvelopeGit $root @('rev-parse','HEAD'))[0]).Trim().ToLowerInvariant();$tree=(@(Invoke-EnvelopeGit $root @('rev-parse','HEAD^{tree}'))[0]).Trim().ToLowerInvariant()
        $final.Add([pscustomobject][ordered]@{repo_id=$id;commit=$head;tree=$tree})|Out-Null;$changed.Add([pscustomobject][ordered]@{repo_id=$id;paths=@($scope.allowed_paths)})|Out-Null
    }
    $sourceRelative=[string]$unit.source_composition.lock_path;$sourcePath=Join-Path $Workspace $sourceRelative;$mapRelative=[IO.Path]::GetRelativePath($Workspace,$RepositoryMapPath).Replace('\','/');$deviceUse=@(if(@($unit.agent_scope_assessment.device_envelope.allowed_kinds).Count){@($unit.agent_scope_assessment.device_envelope.allowed_kinds)}else{@('none')})
    $freeze=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id="$UnitId-extension-freeze";project_id=[string]$project.project_id;unit_id=$UnitId
        expected=[pscustomobject][ordered]@{project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $lock;source_composition_path=$sourceRelative;source_composition_sha256=Get-EnvelopeFileSha256 $sourcePath;repository_map_path=$mapRelative;repository_map_sha256=Get-EnvelopeFileSha256 $RepositoryMapPath;events_sha256=Get-EnvelopeFileSha256 $eventsPath;events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$events[-1].event_id}
        final_repositories=@($final.ToArray());changed_paths=@($changed.ToArray());cleanliness_policy='clean-only';instruction_surfaces=@([pscustomobject][ordered]@{path='README.md';disposition='reviewed-no-change'});feature_lock=[pscustomobject][ordered]@{revision=[int]$lock.revision;sha256=Get-EnvelopeCanonicalJsonSha256 $lock};effects=@($unit.agent_scope_assessment.allowed_effect_categories);permissions=@($unit.agent_scope_assessment.allowed_permission_categories);device_use=@($deviceUse);test_matrix=@([pscustomobject][ordered]@{test_id='extension';command='pwsh -NoProfile -File scripts/Test-ActiveDevelopmentEnvelopeExtension.ps1'});cleanup_evidence=@('All source repositories are clean at their exact candidate identities.');source_composition=[pscustomobject][ordered]@{path=$sourceRelative;sha256=Get-EnvelopeFileSha256 $sourcePath};does_not_prove=@('Does not validate, accept, publish, mutate Git, or operate a device.')
    }
    Write-EnvelopeJson $RequestPath $freeze
    return $freeze
}

function Set-ActiveEnvelopeEvidenceDamage([string]$Path){
    $value=Read-EnvelopeProtocolJson $Path
    if($Path.EndsWith('.completion.json')){$value.event_id='forged-event'}
    elseif($Path.EndsWith('.intent.json')){$value.event.summary='Detached accepted intent.'}
    elseif($Path.Replace('\','/').Contains('/iteration-units/')){$value.status='active'}
    else{$value.result='fail'}
    Write-EnvelopeJson $Path $value
}

function Test-ActiveEnvelopeScopeOnlyAmendmentContinuation {
    param([string]$Root)
    $seed=New-EnvelopeAdmissionPreparedFixture -Root $Root -RepositoryRoot $repoRoot -TransitionLedgerModule $checkpointWriter -OwnerProducedPreparation
    $workspace=$seed.workspace;$firstPath=Join-Path $Root 'first-admission.json';Write-EnvelopeJson $firstPath $seed.admission_template
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $firstPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $firstPath) -OutPath (Join-Path $workspace 'receipts/u002-admission.json') -Timestamp '2026-09-16T00:00:00.0000000Z' -Execute|Out-Null
    # Retain the actual proposed unit and admit its named replacement using the
    # same immutable preparation. This is the production replacement-prefix seam.
    $retire=@{Action='RetireProposed';WorkspaceRoot=$workspace;UnitId='u002';ReplacementUnitId='u003';RetirementReason='contract-invalid';OutPath=(Join-Path $workspace 'receipts/u002-scope-fixture-retirement.json');Timestamp='2026-09-16T00:01:00.0000000Z'}
    $retireDry=&$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a} $retire
    $pre=$retireDry.proposed_retirement.authenticated_preimage
    $retire.ExpectedStateSha256=[string]$pre.state_sha256;$retire.ExpectedUnitSha256=[string]$pre.unit_sha256;$retire.ExpectedUnitRawSha256=[string]$pre.unit_raw_sha256
    $retire.ExpectedEventsSha256=[string]$pre.events_sha256;$retire.ExpectedEventsLength=[long]$pre.events_length;$retire.ExpectedEventTailId=[string]$pre.event_tail_id
    $retire.ExpectedProposedRetirementBindingSha256=[string]$retireDry.proposed_retirement.binding_sha256;$retire.Execute=$true
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a} $retire|Out-Null
    $admission=New-EnvelopeReplacementAdmission -Template $seed.admission_template -Workspace $workspace -AdmissionId 'u003-admission' -UnitId u003
    # Narrow the new draft before admission. Every later added path remains
    # inside the unchanged prepared project/assessment root morphospace/.
    $admission.unit.allowed_repositories[0].allowed_paths=@('morphospace/README.md')
    $admission.unit|Add-Member -Force architecture_decision ([pscustomobject][ordered]@{selected='Retain this bounded documentation unit with additive owner-approved paths.';material_advance='The newly reviewed paths let the same objective continue.';deferred='Any larger project or source identity change.';deferred_reason='The original project and source lock already cover these paths.'})
    $admissionPath=Join-Path $Root 'replacement-admission.json';Write-EnvelopeJson $admissionPath $admission
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts/u003-admission.json') -Timestamp '2026-09-16T00:02:00.0000000Z' -Execute|Out-Null
    $map=Join-Path $workspace 'repository-map.json';$lifecycle=@{WorkspaceRoot=$workspace;UnitId='u003';RepoMapPath=$map;ValidationTier='quick'}
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Ready -Timestamp '2026-09-16T00:03:00.0000000Z' -Execute} $lifecycle|Out-Null
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Claim -Timestamp '2026-09-16T00:04:00.0000000Z' -Execute} $lifecycle|Out-Null
    $unitPath=Join-Path $workspace 'iteration-units/u003.json';$initial=Read-EnvelopeProtocolJson $unitPath
    $sourcePath=Join-Path $workspace ([string]$initial.source_composition.lock_path);$sourceHash=Get-EnvelopeFileSha256 $sourcePath
    $projectHash=Get-EnvelopeFileSha256 (Join-Path $workspace 'project.spec.json');$featureHash=Get-EnvelopeFileSha256 (Join-Path $workspace 'feature.lock.json')
    $toolingBefore=$initial.PSObject.Properties['tooling_context']
    $amendmentIds=@()
    for($i=1;$i-le4;$i++){
        $unit=Read-EnvelopeProtocolJson $unitPath;$state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$project=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json')
        $eventsPath=Join-Path $workspace 'iteration-events.jsonl';$before=@($unit.allowed_repositories[0].allowed_paths);$after=@($before)+@("morphospace/scope-$i/")
        $id="u003-scope-only-$i";$amendmentIds+=,$id
        $request=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.active_write_scope_amendment.v1';amendment_id=$id;project_id='envelope-test';unit_id='u003';repository_id='project-shell';reason='Continue the same bounded documentation objective within its already prepared owner root.';semantic_rationale='The owner reviewed this exact additional nested documentation path without changing project or source selection.';ownership_proof=[pscustomobject][ordered]@{repo_id='project-shell';source_roots=@('morphospace/');tracked_paths=@($after)};source_composition=[pscustomobject][ordered]@{mode=[string]$unit.source_composition.mode;lock_path=[string]$unit.source_composition.lock_path;lock_sha256=$sourceHash};expected=[pscustomobject][ordered]@{status='active';current_unit='u003';project_revision=[int]$project.revision;project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;events_sha256=Get-EnvelopeFileSha256 $eventsPath;events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$state.last_event_id};before_allowed_paths=$before;after_allowed_paths=$after;does_not_prove=@('No source identity, build, media, device, acceptance or publication authority.')}
        $path=Join-Path $Root "$id.json";Write-EnvelopeJson $path $request
        $arguments=@{WorkspaceRoot=$workspace;UnitId='u003';ActiveWriteScopeAmendment=$path;ExpectedActiveWriteScopeAmendmentSha256=(Get-EnvelopeFileSha256 $path);OutPath=(Join-Path $workspace "receipts/$id.json");Timestamp=('2026-09-16T00:{0:D2}:00.0000000Z' -f (4+$i));Execute=$true}
        &$scopeAmendmentModule {param($a)Invoke-MorphospaceAmendActiveWriteScope @a} $arguments|Out-Null
    }
    $current=Read-EnvelopeProtocolJson $unitPath;$toolingAfter=$current.PSObject.Properties['tooling_context']
    Assert-ActiveEnvelopeTest ([string]$current.source_composition.lock_path-ceq[string]$initial.source_composition.lock_path-and(Get-EnvelopeFileSha256 $sourcePath)-ceq$sourceHash-and(Get-EnvelopeFileSha256 (Join-Path $workspace 'project.spec.json'))-ceq$projectHash-and(Get-EnvelopeFileSha256 (Join-Path $workspace 'feature.lock.json'))-ceq$featureHash) 'scope-only fixture changed preparation/project/feature/source identity'
    Assert-ActiveEnvelopeTest (($null-eq$toolingBefore)-eq($null-eq$toolingAfter)) 'scope-only fixture changed tooling-context presence'
    if($null-ne$toolingBefore){Assert-ActiveEnvelopeTest ((Get-EnvelopeCanonicalJsonSha256 $toolingBefore.Value)-ceq(Get-EnvelopeCanonicalJsonSha256 $toolingAfter.Value)) 'scope-only fixture changed tooling context'}
    # The old discriminator returned false here and its narrow suffix reader
    # refused Ready+Claim+four genuine amendments. Authenticate the full chain.
    $admissionIntent=Read-EnvelopeProtocolJson (Join-Path $workspace 'receipts/transactions/u003-admission-admitted-transition.intent.json')
    $prefix=&$scopeProvenanceModule {param($w,$a,$s)Get-PreparationProvenanceAdmissionPrefix -Workspace $w -AdmissionIntent $a -State $s} $workspace $admissionIntent (Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json'))
    Assert-ActiveEnvelopeTest (@($prefix.events)[-1].event_id-ceq$admissionIntent.expected.event_tail_id) 'scope-only continuation did not preserve the exact retained replacement admission prefix'
    $effective=Invoke-ScopeOnlyEffectiveEnvelope $workspace $map
    Assert-ActiveEnvelopeTest ((Get-EnvelopeCanonicalJsonSha256 $effective.effective.unit.allowed_repositories)-ceq(Get-EnvelopeCanonicalJsonSha256 $current.allowed_repositories)-and@($effective.extensions).Count-eq0-and@($effective.tooling_upgrades).Count-eq0) 'effective consumer lost scope-only amendments or invented an extension/tooling action'
    foreach($damage in @('detached-live-scope','foreign-unit-receipt','missing-completion','tampered-intent')){
        $damagedWorkspace=Join-Path $Root $damage;Copy-Item -LiteralPath $workspace -Destination $damagedWorkspace -Recurse
        # Prove that relocation itself is a valid, read-only observation before
        # applying the target damage; a broken copy must not satisfy refusal.
        $undamagedInventory=Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace
        [void](Invoke-ScopeOnlyEffectiveEnvelope $damagedWorkspace (Join-Path $damagedWorkspace 'repository-map.json'))
        Assert-ActiveEnvelopeTest ((Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace)-ceq$undamagedInventory) "undamaged copied fixture changed during $damage observation"
        switch($damage){
            'detached-live-scope'{$p=Join-Path $damagedWorkspace 'iteration-units/u003.json';$v=Read-EnvelopeProtocolJson $p;$v.allowed_repositories[0].allowed_paths+=,'morphospace/unowned/';Write-EnvelopeJson $p $v}
            'foreign-unit-receipt'{$p=Join-Path $damagedWorkspace 'receipts/u003-scope-only-2.json';$v=Read-EnvelopeProtocolJson $p;$v.unit_id='u999';Write-EnvelopeJson $p $v}
            'missing-completion'{Remove-Item -LiteralPath (Join-Path $damagedWorkspace 'receipts/transactions/u003-scope-only-2-recorded-transition.completion.json')}
            'tampered-intent'{$p=Join-Path $damagedWorkspace 'receipts/transactions/u003-scope-only-2-recorded-transition.intent.json';$v=Read-EnvelopeProtocolJson $p;$v.event.summary='Detached amendment intent.';Write-EnvelopeJson $p $v}
        }
        $inventory=Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace
        Assert-ActiveEnvelopeRejected {Invoke-ScopeOnlyEffectiveEnvelope $damagedWorkspace (Join-Path $damagedWorkspace 'repository-map.json')} "scope-only continuation accepted $damage"
        Assert-ActiveEnvelopeTest ((Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace)-ceq$inventory) "scope-only rejection mutated $damage"
    }
    $freezePath=Join-Path $Root 'scope-only-freeze.json';$null=New-ActiveEnvelopeFreezeRequest -Workspace $workspace -RepositoryMapPath $map -RequestPath $freezePath -UnitId u003
    $freezeArguments=@{WorkspaceRoot=$workspace;UnitId='u003';CandidateFreeze=$freezePath;OutPath=(Join-Path $workspace 'receipts/u003-extension-freeze.json');Timestamp='2026-09-16T00:09:00.0000000Z'}
    $dry=&$freezeModule {param($a)Invoke-MorphospaceFreezeCandidate @a} $freezeArguments
    $freezeArguments.ExpectedCandidateFreezeSha256=[string]$dry.audit_receipt.sha256;$freezeArguments.Execute=$true
    $run=&$freezeModule {param($a)Invoke-MorphospaceFreezeCandidate @a} $freezeArguments
    Assert-ActiveEnvelopeTest ($run.transition-ceq'candidate-frozen') 'scope-only replacement chain did not reach real candidate Freeze'
    [void](Invoke-ScopeOnlyEffectiveEnvelope $workspace $map)
    Test-ActiveEnvelopeBuildPreflightConsumer $workspace 'u003' (Join-Path $Root 'build-preflight')
    Write-Output 'PASS genuine retained proposal/replacement/Ready/Claim/four scope-only amendments/full effective envelope/Freeze and detached evidence refusals'
}
function Invoke-ScopeOnlyEffectiveEnvelope([string]$Workspace,[string]$Map){
    &$scopeProvenanceModule {param($w,$m)Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $w -UnitId u003 -RepositoryMapPath $m} $Workspace $Map
}

function Test-ActiveEnvelopeFeaturelessRootsOnly {
    param([string]$Root)
    # Do not populate the feature/module arrays to make the owner API usable.
    # This is the same valid featureless input shape as a roots-only repair.
    $fixture=New-EnvelopeAdmissionPreparedFixture -Root $Root -RepositoryRoot $repoRoot -TransitionLedgerModule $checkpointWriter -OwnerProducedPreparation
    $workspace=$fixture.workspace;$admission=Join-Path $Root 'admission.json';Write-EnvelopeJson $admission $fixture.admission_template
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admission -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admission) -OutPath (Join-Path $workspace 'receipts/u002-admission.json') -Timestamp '2026-09-15T00:00:00.0000000Z' -Execute|Out-Null
    $lifecycle=@{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=(Join-Path $workspace 'repository-map.json');ValidationTier='quick'}
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Ready -Timestamp '2026-09-15T00:01:00.0000000Z' -Execute} $lifecycle|Out-Null
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Claim -Timestamp '2026-09-15T00:02:00.0000000Z' -Execute} $lifecycle|Out-Null
    $request=New-ActiveEnvelopeExtensionRequest -Workspace $workspace -RequestPath (Join-Path $Root 'roots-only.json') -AddedOwnerRoot 'additional-docs/'
    Assert-ActiveEnvelopeTest (@($request.request.before.feature_lock.features).Count-eq0-and@($request.request.before.project.modules).Count-eq0) 'roots-only fixture silently selected a feature/module'
    $mapHash=Get-EnvelopeFileSha256 $request.map_path

    # All five identifier projections may be empty. Exercise the actual helper
    # with valid empty arrays, rather than substituting dummy authority rows.
    $emptyRequest=Copy-Envelope $request.request;$emptyProject=Copy-Envelope $emptyRequest.before.project
    foreach($name in @('modules','authority_map','validation_profiles','acceptance_profiles')){$emptyProject.$name=@();$emptyRequest.target.project.$name=@()}
    [void](&$extensionModule {param($q,$p)Assert-ActiveEnvelopeExplicitAdditions $q $p $q.before.feature_lock $q.before.agent_scope_assessment} $emptyRequest $emptyProject)

    $forged=Copy-Envelope $request.request
    $forged.target.project.authority_map+=,[pscustomobject][ordered]@{parameter='unadmitted.authority';owner='project-shell';adapters=@()}
    $forged.additions.authority_parameters=@('unadmitted.authority')
    $forgedPath=Join-Path $Root 'added-authority.json';Write-EnvelopeJson $forgedPath $forged
    $inventory=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$authorityRejected=$false
    try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $forgedPath -RepositoryMapPath $request.map_path -OutPath $request.receipt_path -SourceCompositionOutPath $request.source_path|Out-Null}
    catch{if($_.Exception.Message-cne"Preparation added authority 'unadmitted.authority' is unused or has the wrong owner."){throw};$authorityRejected=$true}
    Assert-ActiveEnvelopeTest ($authorityRejected-and(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)-ceq$inventory) 'featureless roots-only route added authority or changed workspace on refusal'

    $arguments=@{WorkspaceRoot=$workspace;UnitId='u002';ActiveDevelopmentEnvelopeExtension=$request.request_path;RepositoryMapPath=$request.map_path;OutPath=$request.receipt_path;SourceCompositionOutPath=$request.source_path;Timestamp='2026-09-15T01:00:00.0000000Z'}
    $dry=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @arguments
    Assert-ActiveEnvelopeTest (-not$dry.executed-and-not(Test-Path -LiteralPath $request.receipt_path)-and-not(Test-Path -LiteralPath $request.source_path)) 'featureless roots-only dry run wrote output'
    $arguments.ExpectedActiveDevelopmentEnvelopeExtensionSha256=Get-EnvelopeFileSha256 $request.request_path;$arguments.Execute=$true
    $run=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @arguments
    $unit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json');$lock=Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json')
    Assert-ActiveEnvelopeTest ($run.executed-and@($lock.features).Count-eq0-and@($unit.allowed_repositories|Where-Object{$_.repo_id-ceq'project-shell'-and$_.allowed_paths-ccontains'additional-docs/'}).Count-eq1-and(Get-EnvelopeFileSha256 $request.map_path)-ceq$mapHash) 'featureless roots-only execute changed map/features or omitted the root'
    $events=@(Get-Content -LiteralPath (Join-Path $workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String})
    [void](Test-MorphospaceHistoricalActiveDevelopmentEnvelopeExtension -WorkspaceRoot $workspace -ExpectedEvent $events[-1])

    # A subsequent ordinary write must derive from the authenticated extension,
    # not the original admission endpoint or a fabricated current projection.
    $next=New-ActiveEnvelopeExtensionRequest -Workspace $workspace -RequestPath (Join-Path $Root 'next-root.json') -AddedOwnerRoot 'additional-docs-two/'
    $next.request.extension_id='u002-add-second-root';$next.request.target.state.last_event_id='u002-add-second-root-recorded';$next.request.source_composition.path='source-composition-locks/u002-add-second-root.json'
    $next.request.expected.original_source_composition_path=$request.request.expected.original_source_composition_path
    $next.request.expected.original_source_composition_raw_sha256=$request.request.expected.original_source_composition_raw_sha256
    Write-EnvelopeJson $next.request_path $next.request
    $nextArguments=@{WorkspaceRoot=$workspace;UnitId='u002';ActiveDevelopmentEnvelopeExtension=$next.request_path;RepositoryMapPath=$next.map_path;OutPath=(Join-Path $workspace 'receipts/u002-add-second-root.json');SourceCompositionOutPath=(Join-Path $workspace $next.request.source_composition.path);Timestamp='2026-09-15T01:01:00.0000000Z'}
    $nextDry=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @nextArguments
    Assert-ActiveEnvelopeTest (-not$nextDry.executed-and(Get-EnvelopeFileSha256 $next.map_path)-ceq$mapHash) 'next featureless roots-only writer lost effective provenance or changed the map'
    $nextArguments.ExpectedActiveDevelopmentEnvelopeExtensionSha256=Get-EnvelopeFileSha256 $next.request_path;$nextArguments.Execute=$true
    $nextRun=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @nextArguments
    Assert-ActiveEnvelopeTest $nextRun.executed 'next featureless roots-only writer did not execute'
    Test-ActiveEnvelopeBuildPreflightConsumer $workspace 'u002' (Join-Path $Root 'build-preflight')
    [void](Test-MorphospaceHistoricalActiveDevelopmentEnvelopeExtension -WorkspaceRoot $workspace -ExpectedEvent $events[-1])
    Write-Output 'PASS genuine featureless Prepare/Admit/Ready/Claim roots-only extension, historical replay, next writer, and authority refusal'
}

$retainedAuthorityResult=Invoke-RetainedAuthorityFocusedTests
if($RetainedAuthorityOnly){$retainedAuthorityResult|ConvertTo-Json -Compress;return}

$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$temp=Join-Path $tempParent ('active-envelope-extension-'+[guid]::NewGuid().ToString('N'))
try{
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    if(-not$PreparationConsumerOnly-and-not$ExtendedSourceConsumerOnly){foreach($mode in @('external','separate-artifact')){
        $writer=if($mode-ceq'external'){New-ActiveEnvelopeCheckpointWriter -ExternalReceipt}else{New-ActiveEnvelopeCheckpointWriter -SeparateReceiptProducer}
        $proofSeed=New-EnvelopeAdmissionPreparedFixture -Root (Join-Path $temp "proof-$mode") -RepositoryRoot $repoRoot -TransitionLedgerModule $writer -OwnerProducedPreparation -AdditiveFeature
        $proofArguments=@{WorkspaceRoot=$proofSeed.workspace;State=$proofSeed.state;CurrentUnitId='u002';Expected=$proofSeed.admission_template.expected}
        [void](&$extensionModule {param($a)Assert-ActiveEnvelopeValidationCheckpoint @a} $proofArguments)
        $prefixDrift=$proofArguments.Clone();$prefixDrift.Expected=Copy-Envelope $proofArguments.Expected;$prefixDrift.Expected.events_sha256='0'*64
        Assert-ActiveEnvelopeRejected {&$extensionModule {param($a)Assert-ActiveEnvelopeValidationCheckpoint @a} $prefixDrift} "prefix drift accepted for $mode"
        $ledgerPath=Join-Path $proofSeed.workspace 'iteration-events.jsonl';$ledgerBytes=[IO.File]::ReadAllBytes($ledgerPath)
        $firstLine=([Text.UTF8Encoding]::new($false,$true).GetString($ledgerBytes)-split "`n")[0]+"`n";$firstBytes=[Text.UTF8Encoding]::new($false).GetBytes($firstLine)
        $beforeAcceptance=$proofArguments.Clone();$beforeAcceptance.Expected=Copy-Envelope $proofArguments.Expected;$beforeAcceptance.Expected.events_length=$firstBytes.Length;$beforeAcceptance.Expected.events_sha256=(&$protocolModule {param($b)Get-MorphospaceSha256Bytes $b} $firstBytes);$beforeAcceptance.Expected.event_tail_id=($firstLine|ConvertFrom-Json -Depth 100).event_id
        if($mode-ceq'separate-artifact'){Assert-ActiveEnvelopeRejected {&$extensionModule {param($a)Assert-ActiveEnvelopeValidationCheckpoint @a} $beforeAcceptance} 'acceptance outside captured prefix was accepted'}
        $events=@([Text.UTF8Encoding]::new($false,$true).GetString($ledgerBytes)-split "`n"|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String})
        $duplicate=Copy-Envelope $events[0];if($mode-ceq'separate-artifact'){$duplicate=Copy-Envelope $events[1]};$duplicate.event_id='u001-accepted-9999';$duplicate.sequence=$events.Count+1
        [IO.File]::AppendAllText($ledgerPath,(($duplicate|ConvertTo-Json -Depth 100 -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $ambiguous=$proofArguments.Clone();$ambiguous.Expected=Copy-Envelope $proofArguments.Expected;$ambiguous.Expected.events_length=([IO.FileInfo]$ledgerPath).Length;$ambiguous.Expected.events_sha256=Get-EnvelopeFileSha256 $ledgerPath;$ambiguous.Expected.event_tail_id=$duplicate.event_id
        Assert-ActiveEnvelopeRejected {&$extensionModule {param($a)Assert-ActiveEnvelopeValidationCheckpoint @a} $ambiguous} "ambiguous acceptance accepted for $mode"
        [IO.File]::WriteAllBytes($ledgerPath,$ledgerBytes)
        $receiptPath=Join-Path $proofSeed.workspace 'receipts/u001-accepted.json';$receiptBytes=[IO.File]::ReadAllBytes($receiptPath);Remove-Item -LiteralPath $receiptPath
        Assert-ActiveEnvelopeRejected {&$extensionModule {param($a)Assert-ActiveEnvelopeValidationCheckpoint @a} $proofArguments} "missing accepted receipt accepted for $mode"
        [IO.File]::WriteAllBytes($receiptPath,$receiptBytes)
    }
    if($CheckpointProofOnly){[pscustomobject]@{result='pass';external_receipt=$true;separate_receipt_producer=$true;prefix_drift_rejected=$true;acceptance_outside_prefix_rejected=$true;ambiguous_acceptance_rejected=$true;missing_receipt_rejected=$true}|ConvertTo-Json -Compress;return}}
    if(-not$ExtendedSourceConsumerOnly){
    Test-ActiveEnvelopeScopeOnlyAmendmentContinuation -Root (Join-Path $temp 'scope-only-amendment-continuation')
    Test-ActiveEnvelopeFeaturelessRootsOnly -Root (Join-Path $temp 'featureless-roots-only')
    # Genuine recovered-origin positive. Both fixture factories already belong
    # to the dot-sourced DevelopmentAdmissionFixture.ps1. The current public
    # Reprepare and Admit writers earn every recovered receipt used below.
    $recoveredOriginSeed = New-RecoveredProposalContinuationSeed -Root (Join-Path $temp 'recovered-origin-seed') -RepositoryRoot $repoRoot -TransitionLedgerModule $transitionModule
    $recoveredOriginRoot = Join-Path $temp 'recovered-origin-positive'
    $recoveredOriginFixture = New-EnvelopeRepreparationFixture -BaseRepository $recoveredOriginSeed.base_repository -FixtureRoot $recoveredOriginRoot -Template $recoveredOriginSeed.repreparation_template
    $recoveredOriginWorkspace = $recoveredOriginFixture.workspace
    $recoveredOriginPreserved = @()
    foreach ($binding in @(
        $recoveredOriginFixture.input.original_preparation.receipt,
        $recoveredOriginFixture.input.original_preparation.source_composition,
        $recoveredOriginFixture.input.original_preparation.intent,
        $recoveredOriginFixture.input.original_preparation.completion,
        $recoveredOriginFixture.input.retirement.receipt,
        $recoveredOriginFixture.input.retirement.intent,
        $recoveredOriginFixture.input.retirement.completion
    )) {
        $recoveredOriginPreserved += [pscustomobject]@{ path=[string]$binding.path; sha256=(Get-EnvelopeFileSha256 (Join-Path $recoveredOriginWorkspace ([string]$binding.path))) }
    }
    $recoveredOriginOut = Join-Path $recoveredOriginWorkspace 'receipts/u003-envelope-recovery-repreparation.json'
    $recoveredOriginArguments = @{
        Action='ReprepareRetiredDevelopmentEnvelope'; WorkspaceRoot=$recoveredOriginWorkspace
        DevelopmentEnvelopeRepreparation=$recoveredOriginFixture.input_path
        ExpectedDevelopmentEnvelopeRepreparationSha256=(Get-EnvelopeFileSha256 $recoveredOriginFixture.input_path)
        OutPath=$recoveredOriginOut; Timestamp='2026-08-25T00:01:40.0000000Z'; Execute=$true
    }
    $recoveredOriginRun = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') @recoveredOriginArguments | ConvertFrom-Json -DateKind String
    Assert-ActiveEnvelopeTest ($recoveredOriginRun.executed -and $recoveredOriginRun.transition -ceq 'retired-envelope-reprepared') 'actual current Reprepare writer did not produce the recovered-origin boundary'
    $recoveredOriginAdmissionRequest = New-EnvelopeReplacementAdmission -Template $recoveredOriginSeed.admission_template -Workspace $recoveredOriginWorkspace -AdmissionId 'u003-admission' -UnitId 'u003'
    $recoveredOriginAdmissionRequest.preparation = [ordered]@{
        preparation_kind='recovered'; preparation_id='u003-envelope'
        receipt_path='receipts/u003-envelope.json'
        receipt_sha256=(Get-EnvelopeFileSha256 (Join-Path $recoveredOriginWorkspace 'receipts/u003-envelope.json'))
        source_composition_path='source-composition-locks/u003-envelope.json'
        source_composition_sha256=(Get-EnvelopeFileSha256 (Join-Path $recoveredOriginWorkspace 'source-composition-locks/u003-envelope.json'))
        recovery_receipt_path='receipts/u003-envelope-recovery-repreparation.json'
        recovery_receipt_sha256=(Get-EnvelopeFileSha256 $recoveredOriginOut)
    }
    $recoveredOriginAdmissionRequest.unit.source_composition.lock_path = 'source-composition-locks/u003-envelope.json'
    $recoveredOriginAdmissionRequest.expected.project_sha256 = Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $recoveredOriginWorkspace 'project.spec.json'))
    $recoveredOriginAdmissionRequest.expected.feature_lock_sha256 = Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $recoveredOriginWorkspace 'feature.lock.json'))
    $recoveredOriginAdmissionRequest.expected.source_composition_path = $recoveredOriginAdmissionRequest.preparation.source_composition_path
    $recoveredOriginAdmissionRequest.expected.source_composition_sha256 = $recoveredOriginAdmissionRequest.preparation.source_composition_sha256
    $recoveredOriginAdmissionRequest.expected.repository_map_sha256 = Get-EnvelopeFileSha256 (Join-Path $recoveredOriginWorkspace 'repository-map.json')
    $recoveredOriginAdmissionPath = Join-Path $recoveredOriginRoot 'admission.json'
    Write-EnvelopeJson $recoveredOriginAdmissionPath $recoveredOriginAdmissionRequest
    $recoveredOriginAdmissionOut = Join-Path $recoveredOriginWorkspace 'receipts/u003-admission.json'
    $recoveredOriginAdmitted = Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $recoveredOriginWorkspace -DevelopmentUnitAdmission $recoveredOriginAdmissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $recoveredOriginAdmissionPath) -OutPath $recoveredOriginAdmissionOut -Timestamp '2026-08-25T00:01:50.0000000Z' -Execute
    Assert-ActiveEnvelopeTest ($recoveredOriginAdmitted.transition -ceq 'development-unit-admitted') 'actual recovered admission writer did not earn the origin binding'
    # Use the persisted writer-owned admission, not an unaccepted request DTO.
    $recoveredOriginAdmission = Read-EnvelopeProtocolJson $recoveredOriginAdmissionOut
    $recoveredOriginLifecycle = @{ WorkspaceRoot=$recoveredOriginWorkspace; UnitId='u003'; RepoMapPath=(Join-Path $recoveredOriginWorkspace 'repository-map.json'); ValidationTier='quick' }
    $recoveredOriginReady = & $automationModule { param($a) Invoke-MorphospaceWorkUnitAutomation @a -Action Ready -Timestamp '2026-08-25T00:01:51.0000000Z' -Execute } $recoveredOriginLifecycle
    # This is an isolated fixture checkpoint, as in the existing recovered-
    # continuation owner test; actual Claim observes its real repository state.
    [void](Invoke-EnvelopeGit $recoveredOriginFixture.repository @('add','--','morphospace'))
    [void](Invoke-EnvelopeGit $recoveredOriginFixture.repository @('commit','-m','checkpoint writer-produced recovered preparation and Ready'))
    $recoveredOriginClaimed = & $automationModule { param($a) Invoke-MorphospaceWorkUnitAutomation @a -Action Claim -Timestamp '2026-08-25T00:01:52.0000000Z' -Execute } $recoveredOriginLifecycle
    Assert-ActiveEnvelopeTest ($recoveredOriginReady.transition -ceq 'proposed-to-ready' -and $recoveredOriginClaimed.transition -ceq 'ready-to-active') 'actual recovered owner did not complete Ready and Claim'
    $recoveredOriginIntent = Read-EnvelopeProtocolJson (Join-Path $recoveredOriginWorkspace 'receipts/transactions/u003-envelope-recovery-transition.intent.json')
    $recoveredOriginCompletion = Read-EnvelopeProtocolJson (Join-Path $recoveredOriginWorkspace 'receipts/transactions/u003-envelope-recovery-transition.completion.json')
    $recoveredOriginReceipt = Read-EnvelopeProtocolJson (Join-Path $recoveredOriginWorkspace 'receipts/u003-envelope.json')
    Assert-ActiveEnvelopeTest ($recoveredOriginAdmission.preparation.preparation_kind -ceq 'recovered' -and [string]$recoveredOriginCompletion.intent_sha256 -ceq (Get-EnvelopeFileSha256 (Join-Path $recoveredOriginWorkspace 'receipts/transactions/u003-envelope-recovery-transition.intent.json'))) 'recovered positive is detached from its real typed Reprepare completion'
    foreach ($binding in @($recoveredOriginPreserved)) {
        Assert-ActiveEnvelopeTest ((Get-EnvelopeFileSha256 (Join-Path $recoveredOriginWorkspace $binding.path)) -ceq $binding.sha256) 'recovered origin journey rewrote retained preparation or retirement evidence'
    }
    $recoveredOriginBeforeReads = Get-EnvelopeWorkspaceByteInventorySha256 $recoveredOriginWorkspace
    $recoveredOriginTargets = & $continuationModule { param($w,$a) Read-DevelopmentContinuationPreparationTargets $w $a } $recoveredOriginWorkspace $recoveredOriginAdmission
    $recoveredOriginFull = & $continuationModule { param($w,$a) Get-MorphospaceDevelopmentEnvelopeContinuation -WorkspaceRoot $w -Admission $a } $recoveredOriginWorkspace $recoveredOriginAdmission
    Assert-ActiveEnvelopeTest ((Get-EnvelopeCanonicalJsonSha256 $recoveredOriginTargets.project) -ceq [string]$recoveredOriginIntent.target.project.sha256 -and (Get-EnvelopeCanonicalJsonSha256 $recoveredOriginTargets.feature_lock) -ceq [string]$recoveredOriginIntent.target.feature_lock.sha256 -and (Get-EnvelopeCanonicalJsonSha256 $recoveredOriginFull.project) -ceq [string]$recoveredOriginIntent.target.project.sha256 -and (Get-EnvelopeCanonicalJsonSha256 $recoveredOriginFull.feature_lock) -ceq [string]$recoveredOriginIntent.target.feature_lock.sha256) 'actual recovered helper or full reader lost the typed writer-owned targets'
    Assert-ActiveEnvelopeTest ([string]$recoveredOriginFull.unit.unit_id -ceq 'u003' -and [string]$recoveredOriginFull.unit.status -ceq 'active' -and @($recoveredOriginFull.records | Where-Object kind -CEQ 'ready').Count -eq 1 -and @($recoveredOriginFull.records | Where-Object kind -CEQ 'claimed').Count -eq 1 -and @($recoveredOriginFull.extensions).Count -eq 0 -and @($recoveredOriginFull.tooling_upgrades).Count -eq 0) 'recovered positive bypassed the genuine ordinary owner continuation'
    Assert-ActiveEnvelopeTest ((Get-EnvelopeCanonicalJsonSha256 $recoveredOriginReceipt.envelope.project) -ceq (Get-EnvelopeCanonicalJsonSha256 $recoveredOriginTargets.project) -and (Get-EnvelopeCanonicalJsonSha256 $recoveredOriginReceipt.envelope.feature_lock) -ceq (Get-EnvelopeCanonicalJsonSha256 $recoveredOriginTargets.feature_lock) -and (Get-EnvelopeWorkspaceByteInventorySha256 $recoveredOriginWorkspace) -ceq $recoveredOriginBeforeReads) 'actual rich recovered receipt disagreed or read-only observations changed fixture bytes'
    Test-ActiveEnvelopeBuildPreflightConsumer $recoveredOriginWorkspace 'u003' (Join-Path $recoveredOriginRoot 'build-preflight')
    Write-Output 'PASS genuine current Reprepare/Admit/Ready/Claim origin helper and full continuation; retained historical evidence and read-only bytes unchanged'
    if($PreparationConsumerOnly){[pscustomobject]@{result='pass';ordinary_v1_without_snapshots=$true;recovered_v1_with_snapshots=$true;scope_only_amendment=$true;roots_only_extensions=$true;real_build_preflight=$true;persisted_zero_one_array_cardinality=$true;source_mismatch_refused=$true;compiler_started=$false;device_used=$false}|ConvertTo-Json -Compress;return}
    }
    $seed=New-EnvelopeAdmissionPreparedFixture -Root (Join-Path $temp 'seed') -RepositoryRoot $repoRoot -TransitionLedgerModule $checkpointWriter -OwnerProducedPreparation -AdditiveFeature
    $workspace=$seed.workspace;$admissionPath=Join-Path $temp 'admission.json';Write-EnvelopeJson $admissionPath $seed.admission_template
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts\u002-admission.json') -Timestamp '2026-09-15T00:00:00.0000000Z' -Execute|Out-Null
    $lifecycle=@{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=(Join-Path $workspace 'repository-map.json');ValidationTier='quick'}
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Ready -Timestamp '2026-09-15T00:01:00.0000000Z' -Execute} $lifecycle|Out-Null
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Claim -Timestamp '2026-09-15T00:02:00.0000000Z' -Execute} $lifecycle|Out-Null

    $added=Join-Path $temp 'added-repository';[IO.Directory]::CreateDirectory((Join-Path $added 'dep'))|Out-Null
    Invoke-EnvelopeGit $temp @('init',$added)|Out-Null;Invoke-EnvelopeGit $added @('config','user.name','Active Envelope Test')|Out-Null;Invoke-EnvelopeGit $added @('config','user.email','active-envelope@example.invalid')|Out-Null;Invoke-EnvelopeGit $added @('config','commit.gpgsign','false')|Out-Null
    [IO.File]::WriteAllText((Join-Path $added 'dep\README.md'),'dependency'+[Environment]::NewLine,[Text.UTF8Encoding]::new($false));Invoke-EnvelopeGit $added @('add','dep/README.md')|Out-Null;Invoke-EnvelopeGit $added @('commit','-m','dependency baseline')|Out-Null
    $preExtensionWorkspace=Join-Path $temp 'pre-extension-workspace';Copy-Item -LiteralPath $workspace -Destination $preExtensionWorkspace -Recurse
    $requestInfo=New-ActiveEnvelopeExtensionRequest -Workspace $workspace -AddedRepository $added -RequestPath (Join-Path $temp 'extension.json')
    $beforeProject=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json');$beforeLock=Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json');$beforeState=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$beforeUnit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units\u002.json')
    $acceptedEvidence=@('iteration-units/u001.json','receipts/u001-accepted.json','receipts/transactions/u001-accepted-0001-transition.intent.json','receipts/transactions/u001-accepted-0001-transition.completion.json')
    $acceptedHashes=@{};foreach($path in $acceptedEvidence){$acceptedHashes[$path]=Get-EnvelopeFileSha256 (Join-Path $workspace $path)}
    $checkpointArguments=@{WorkspaceRoot=$workspace;State=$beforeState;CurrentUnitId='u002';Expected=$requestInfo.request.expected}
    foreach($case in @('current','unaccepted','mismatch','tier','result','malformed')){
        $damaged=Copy-Envelope $beforeState;$args= $checkpointArguments.Clone();$args.State=$damaged
        switch($case){
            'current'{$args.CurrentUnitId='u001'}
            'unaccepted'{$damaged.last_accepted_receipt='receipts/orphan.json';$damaged.validation_checkpoint.receipt='receipts/orphan.json'}
            'mismatch'{$damaged.validation_checkpoint.receipt='receipts/other.json'}
            'tier'{$damaged.validation_checkpoint.tier='deep'}
            'result'{$damaged.validation_checkpoint.result='blocked'}
            'malformed'{$damaged.validation_checkpoint|Add-Member extra 'forged'}
        }
        $inventory=Get-EnvelopeWorkspaceByteInventorySha256 $workspace
        Assert-ActiveEnvelopeRejected {&$extensionModule {param($a)Assert-ActiveEnvelopeValidationCheckpoint @a} $args} "checkpoint $case was accepted"
        Assert-ActiveEnvelopeTest ((Get-EnvelopeWorkspaceByteInventorySha256 $workspace)-ceq$inventory) "checkpoint $case rejection mutated workspace"
    }
    foreach($path in $acceptedEvidence){
        $absolute=Join-Path $workspace $path;$bytes=[IO.File]::ReadAllBytes($absolute)
        Set-ActiveEnvelopeEvidenceDamage $absolute
        Assert-ActiveEnvelopeRejected {&$extensionModule {param($a)Assert-ActiveEnvelopeValidationCheckpoint @a} $checkpointArguments} "damaged accepted evidence $path was accepted"
        [IO.File]::WriteAllBytes($absolute,$bytes)
    }
    $nullState=Copy-Envelope $beforeState;$nullState.validation_checkpoint=$null;$nullArgs=$checkpointArguments.Clone();$nullArgs.State=$nullState
    [void](&$extensionModule {param($a)Assert-ActiveEnvelopeValidationCheckpoint @a} $nullArgs)
    $dry=Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $requestInfo.request_path -RepositoryMapPath $requestInfo.map_path -OutPath $requestInfo.receipt_path -SourceCompositionOutPath $requestInfo.source_path -Timestamp '2026-09-15T01:00:00.0000000Z'
    Assert-ActiveEnvelopeTest (-not$dry.executed-and-not(Test-Path $requestInfo.receipt_path)-and-not(Test-Path $requestInfo.source_path)) 'dry run wrote an artifact'
    $stale=Copy-Envelope $requestInfo.request;$stale.expected.project_sha256='0'*64;$stalePath=Join-Path $temp 'stale.json';Write-EnvelopeJson $stalePath $stale
    Assert-ActiveEnvelopeRejected {Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $stalePath -RepositoryMapPath $requestInfo.map_path -OutPath $requestInfo.receipt_path -SourceCompositionOutPath $requestInfo.source_path} 'stale project CAS was accepted'
    $changedObjective=Copy-Envelope $requestInfo.request;$changedObjective.target.agent_scope_assessment.objective='A different objective that the original admission never authorized.';$changedObjectivePath=Join-Path $temp 'changed-objective.json';Write-EnvelopeJson $changedObjectivePath $changedObjective
    Assert-ActiveEnvelopeRejected {Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $changedObjectivePath -RepositoryMapPath $requestInfo.map_path -OutPath $requestInfo.receipt_path -SourceCompositionOutPath $requestInfo.source_path} 'changed objective was accepted'
    $forgedMap=Copy-Envelope (Read-EnvelopeProtocolJson $requestInfo.map_path);$forgedMap.repositories[0].role=$(if([string]$forgedMap.repositories[0].role-ceq'source'){'planning'}else{'source'});$forgedMapPath=Join-Path $workspace 'repository-map-forged.json';Write-EnvelopeJson $forgedMapPath $forgedMap
    $forgedRequest=Copy-Envelope $requestInfo.request;$forgedRequest.effective_repository_map.path='repository-map-forged.json';$forgedRequest.effective_repository_map.raw_sha256=Get-EnvelopeFileSha256 $forgedMapPath;$forgedRequestPath=Join-Path $temp 'forged-map.json';Write-EnvelopeJson $forgedRequestPath $forgedRequest
    Assert-ActiveEnvelopeRejected {Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $forgedRequestPath -RepositoryMapPath $forgedMapPath -OutPath $requestInfo.receipt_path -SourceCompositionOutPath $requestInfo.source_path} 'forged existing repository-map row was accepted'
    $unreviewedRoot=Copy-Envelope $requestInfo.request;$unreviewedRoot.target.agent_scope_assessment.owner_repositories[0].source_roots+=,'unreviewed-root/';$unreviewedRootPath=Join-Path $temp 'unreviewed-root.json';Write-EnvelopeJson $unreviewedRootPath $unreviewedRoot
    Assert-ActiveEnvelopeRejected {Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $unreviewedRootPath -RepositoryMapPath $requestInfo.map_path -OutPath $requestInfo.receipt_path -SourceCompositionOutPath $requestInfo.source_path} 'unreviewed owner root was accepted'
    $dirtyDependencyPath=Join-Path $added 'dep\unreviewed-dirt.txt';[IO.File]::WriteAllText($dirtyDependencyPath,'dirty',[Text.UTF8Encoding]::new($false))
    Assert-ActiveEnvelopeRejected {Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $requestInfo.request_path -RepositoryMapPath $requestInfo.map_path -OutPath $requestInfo.receipt_path -SourceCompositionOutPath $requestInfo.source_path} 'dirty new dependency source was accepted'
    Remove-Item -LiteralPath $dirtyDependencyPath
    $run=Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $requestInfo.request_path -RepositoryMapPath $requestInfo.map_path -OutPath $requestInfo.receipt_path -SourceCompositionOutPath $requestInfo.source_path -ExpectedActiveDevelopmentEnvelopeExtensionSha256 (Get-EnvelopeFileSha256 $requestInfo.request_path) -Timestamp '2026-09-15T01:00:00.0000000Z' -Execute
    $afterProject=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json');$afterLock=Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json');$afterState=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$afterUnit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units\u002.json');$afterSource=Read-EnvelopeProtocolJson $requestInfo.source_path
    Assert-ActiveEnvelopeTest ($run.executed-and$run.event_id-ceq'u002-add-dependency-recorded'-and[int]$afterProject.revision-eq([int]$beforeProject.revision+1)-and[int]$afterLock.revision-eq([int]$beforeLock.revision+1)-and[int]$afterState.plan_revision-eq([int]$beforeState.plan_revision+1)) 'execute did not advance the exact project, lock, and plan revisions'
    Assert-ActiveEnvelopeTest ([string]$afterUnit.objective-ceq[string]$beforeUnit.objective-and(Get-EnvelopeCanonicalJsonSha256 $afterUnit.acceptance)-ceq(Get-EnvelopeCanonicalJsonSha256 $beforeUnit.acceptance)-and[string]$afterUnit.source_composition.lock_path-ceq'source-composition-locks/u002-add-dependency.json') 'execute changed objective/acceptance or failed to install the derivative source binding'
    Assert-ActiveEnvelopeTest ([string]$afterSource.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'-and@($afterSource.repositories|Where-Object{$_.repo_id-ceq'added-dependency'-and$_.worktree_state-ceq'clean'}).Count-eq1) 'derivative source artifact lacks the clean added dependency'
    Assert-ActiveEnvelopeTest ((Get-EnvelopeCanonicalJsonSha256 $afterState.validation_checkpoint)-ceq(Get-EnvelopeCanonicalJsonSha256 $beforeState.validation_checkpoint)) 'extension changed retained accepted checkpoint'
    foreach($path in $acceptedEvidence){Assert-ActiveEnvelopeTest ((Get-EnvelopeFileSha256 (Join-Path $workspace $path))-ceq$acceptedHashes[$path]) "extension changed accepted evidence $path"}
    $events=@(Get-Content -LiteralPath (Join-Path $workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String})
    [void](Test-MorphospaceHistoricalActiveDevelopmentEnvelopeExtension -WorkspaceRoot $workspace -ExpectedEvent ($events[-1]))
    $replay=Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $requestInfo.request_path -RepositoryMapPath $requestInfo.map_path -OutPath $requestInfo.receipt_path -SourceCompositionOutPath $requestInfo.source_path -ExpectedActiveDevelopmentEnvelopeExtensionSha256 (Get-EnvelopeFileSha256 $requestInfo.request_path) -Execute
    Assert-ActiveEnvelopeTest ($replay.executed-and$replay.transition-ceq'active-development-envelope-extended') 'exact replay was not idempotent'

    $freezePath=Join-Path $temp 'extension-freeze.json';$null=New-ActiveEnvelopeFreezeRequest -Workspace $workspace -RepositoryMapPath $requestInfo.map_path -RequestPath $freezePath;$freezeOut=Join-Path $workspace 'receipts\u002-extension-freeze.json'
    $freezeArguments=@{WorkspaceRoot=$workspace;UnitId='u002';CandidateFreeze=$freezePath;OutPath=$freezeOut;Timestamp='2026-09-15T01:05:00.0000000Z'}
    $freezeDry=&$freezeModule {param($arguments)Invoke-MorphospaceFreezeCandidate @arguments} $freezeArguments
    $freezeArguments.ExpectedCandidateFreezeSha256=[string]$freezeDry.audit_receipt.sha256;$freezeArguments.Execute=$true;$freezeRun=&$freezeModule {param($arguments)Invoke-MorphospaceFreezeCandidate @arguments} $freezeArguments
    $frozenUnit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units\u002.json');$frozenProjectHash=Get-EnvelopeFileSha256 (Join-Path $workspace 'project.spec.json');$frozenLockHash=Get-EnvelopeFileSha256 (Join-Path $workspace 'feature.lock.json');$frozenSourceHash=Get-EnvelopeFileSha256 $requestInfo.source_path
    Assert-ActiveEnvelopeTest ($freezeRun.transition-ceq'candidate-frozen'-and[bool](&$freezeModule {param($root,$unit)Test-MorphospaceFrozenCandidate -WorkspaceRoot $root -Unit $unit} $workspace $frozenUnit)) 'derived source composition did not pass the real candidate Freeze consumer'
    Test-ActiveEnvelopeBuildPreflightConsumer $workspace 'u002' (Join-Path $temp 'extension-build-preflight') $requestInfo.map_path
    if($ExtendedSourceConsumerOnly){[pscustomobject]@{result='pass';writer_produced_source_extension=$true;real_freeze_consumer=$true;real_build_preflight=$true;persisted_zero_one_two_array_cardinality=$true;source_mismatch_refused=$true;compiler_started=$false;device_used=$false}|ConvertTo-Json -Compress;return}
    $retirementRequest=New-ActiveUnitRetirementRequest -WorkspaceRoot $workspace -RepoMapPath $requestInfo.map_path -RetirementId 'retire-u002-extension' -ReplacementUnitId 'u003';$retirementRequestPath=Join-Path $temp 'retire-u002-extension.json';Write-EnvelopeJson $retirementRequestPath $retirementRequest;$retirementOut=Join-Path $workspace 'receipts\retire-u002-extension.json'
    $retirementArguments=@{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=$requestInfo.map_path;ActiveUnitRetirement=$retirementRequestPath;OutPath=$retirementOut;Timestamp='2026-09-15T01:06:00.0000000Z'}
    $retirementDry=&$retirementModule {param($arguments)Invoke-MorphospaceRetireActive @arguments} $retirementArguments
    Assert-ActiveEnvelopeTest (-not$retirementDry.executed) 'post-extension active retirement dry run failed'
    $retirementArguments.ExpectedActiveUnitRetirementSha256=Get-EnvelopeFileSha256 $retirementRequestPath;$retirementArguments.Execute=$true;$retirementArguments.FaultAfter='after-intent';$retirementInterrupted=$false
    try{&$retirementModule {param($arguments)Invoke-MorphospaceRetireActive @arguments} $retirementArguments|Out-Null}catch{$retirementInterrupted=$_.Exception.Message-like'*Injected interruption*'}
    Assert-ActiveEnvelopeTest ($retirementInterrupted-and(Test-Path (Join-Path $workspace 'receipts\transactions\retire-u002-extension-active-retired-transition.intent.json'))) 'post-extension active retirement did not retain its interrupted v6 intent'
    $retirementArguments.FaultAfter='none';$retirementRun=&$retirementModule {param($arguments)Invoke-MorphospaceRetireActive @arguments} $retirementArguments
    $retiredState=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$retiredUnit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units\u002.json')
    Assert-ActiveEnvelopeTest ($retirementRun.executed-and$null-eq$retiredState.current_unit-and[string]$retiredUnit.candidate_freeze.freeze_id-ceq'u002-extension-freeze'-and(Get-EnvelopeFileSha256 (Join-Path $workspace 'project.spec.json'))-ceq$frozenProjectHash-and(Get-EnvelopeFileSha256 (Join-Path $workspace 'feature.lock.json'))-ceq$frozenLockHash-and(Get-EnvelopeFileSha256 $requestInfo.source_path)-ceq$frozenSourceHash) 'post-extension active retirement recovery changed preserved authority or failed to become idle'
    $historyModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkHistory.psm1') -PassThru
    $history=&$historyModule {param($w)Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $w -RequireIdle} $workspace
    Assert-ActiveEnvelopeTest ($history.authenticated) 'current-work replay failed after ordinary Freeze and retirement'
    $nextPreparation=Read-EnvelopeProtocolJson (Join-Path $temp 'seed/u002-envelope-preparation.json')
    $nextPreparation.preparation_id='u003-envelope';$nextPreparation.envelope.project=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json');$nextPreparation.envelope.project.revision++
    $nextPreparation.envelope.feature_lock=Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json');$nextPreparation.envelope.feature_lock.project_revision=$nextPreparation.envelope.project.revision;$nextPreparation.envelope.feature_lock.revision++;$nextPreparation.envelope.feature_lock.generated_at='2026-09-15T01:07:00.0000000Z';$nextPreparation.envelope.feature_lock.lock_fingerprint=Get-EnvelopeLockFingerprint $nextPreparation.envelope.feature_lock
    $nextPreparation.envelope.owner_repositories=$retiredUnit.agent_scope_assessment.owner_repositories;$nextPreparation.envelope.source_composition.path='source-composition-u003.json';$nextPreparation.envelope.source_composition.repository_ids=@($afterSource.repositories.repo_id)
    $nextPreparation.expected.project_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json'));$nextPreparation.expected.feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json'));$nextPreparation.expected.state_sha256=Get-EnvelopeCanonicalJsonSha256 $retiredState
    $nextPreparation.expected.repository_map_path='repository-map-extension.json';$nextPreparation.expected.repository_map_sha256=Get-EnvelopeFileSha256 $requestInfo.map_path;$nextPreparation.expected.events_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'iteration-events.jsonl');$nextPreparation.expected.events_length=([IO.FileInfo](Join-Path $workspace 'iteration-events.jsonl')).Length;$nextPreparation.expected.event_tail_id=$retiredState.last_event_id
    $nextPreparationPath=Join-Path $temp 'next-preparation.json';Write-EnvelopeJson $nextPreparationPath $nextPreparation
    Invoke-MorphospacePrepareDevelopmentEnvelope -WorkspaceRoot $workspace -DevelopmentEnvelopePreparation $nextPreparationPath -ExpectedDevelopmentEnvelopePreparationSha256 (Get-EnvelopeFileSha256 $nextPreparationPath) -OutPath (Join-Path $workspace 'receipts/u003-envelope.json') -Timestamp '2026-09-15T01:07:00.0000000Z' -Execute|Out-Null
    $nextAdmission=Copy-Envelope $seed.admission_template;$nextAdmission.admission_id='u003-admission';$nextAdmission.unit_id='u003';$nextAdmission.unit.unit_id='u003';$nextAdmission.unit.agent_scope_assessment=$retiredUnit.agent_scope_assessment;$nextAdmission.agent_scope_assessment=$retiredUnit.agent_scope_assessment;$nextAdmission.unit.read_only_dependencies=$retiredUnit.read_only_dependencies;$nextAdmission.unit.source_composition.lock_path='source-composition-u003.json'
    $nextAdmission.preparation.preparation_id='u003-envelope';$nextAdmission.preparation.receipt_path='receipts/u003-envelope.json';$nextAdmission.preparation.receipt_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'receipts/u003-envelope.json');$nextAdmission.preparation.source_composition_path='source-composition-u003.json';$nextAdmission.preparation.source_composition_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'source-composition-u003.json')
    $nextAdmission.expected.project_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json'));$nextAdmission.expected.feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json'));$nextAdmission.expected.state_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json'));$nextAdmission.expected.source_composition_path='source-composition-u003.json';$nextAdmission.expected.source_composition_sha256=$nextAdmission.preparation.source_composition_sha256;$nextAdmission.expected.repository_map_path='repository-map-extension.json';$nextAdmission.expected.repository_map_sha256=$nextPreparation.expected.repository_map_sha256;$nextAdmission.expected.events_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'iteration-events.jsonl');$nextAdmission.expected.events_length=([IO.FileInfo](Join-Path $workspace 'iteration-events.jsonl')).Length;$nextAdmission.expected.event_tail_id='u003-envelope-prepared'
    $nextAdmissionPath=Join-Path $temp 'next-admission.json';Write-EnvelopeJson $nextAdmissionPath $nextAdmission
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $nextAdmissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $nextAdmissionPath) -OutPath (Join-Path $workspace 'receipts/u003-admission.json') -Timestamp '2026-09-15T01:08:00.0000000Z' -Execute|Out-Null
    $nextHistory=&$historyModule {param($w)Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $w -RequireIdle} $workspace
    Assert-ActiveEnvelopeTest ($nextHistory.authenticated) 'current-work continuation failed after successor preparation and admission'

    foreach($fault in @('after-artifact','after-projection','after-event')){
        $faultWorkspace=Join-Path $temp $fault;Copy-Item -LiteralPath $preExtensionWorkspace -Destination $faultWorkspace -Recurse
        $faultInfo=New-ActiveEnvelopeExtensionRequest -Workspace $faultWorkspace -AddedRepository $added -RequestPath (Join-Path $temp "$fault-extension.json")
        $faulted=$false
        try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $faultWorkspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $faultInfo.request_path -RepositoryMapPath $faultInfo.map_path -OutPath $faultInfo.receipt_path -SourceCompositionOutPath $faultInfo.source_path -ExpectedActiveDevelopmentEnvelopeExtensionSha256 (Get-EnvelopeFileSha256 $faultInfo.request_path) -Timestamp '2026-09-15T01:10:00.0000000Z' -Execute -FaultAfter $fault|Out-Null}catch{$faulted=$_.Exception.Message-like'*Injected interruption*'}
        Assert-ActiveEnvelopeTest $faulted "extension did not interrupt at $fault"
        $ownedIntent=Read-EnvelopeProtocolJson (Join-Path $faultWorkspace 'receipts/transactions/u002-add-dependency-recorded-transition.intent.json')
        $ownedPaths=@('workspace.state.json','iteration-units/u002.json','project.spec.json','feature.lock.json','iteration-events.jsonl','receipts/transactions/u002-add-dependency-recorded-transition.intent.json')+@($ownedIntent.artifacts|ForEach-Object{[string]$_.path})+@(Get-ChildItem (Join-Path $faultWorkspace 'receipts/transactions') -Filter 'u002-add-dependency-recorded-transition.artifact-*.pending'|ForEach-Object{'receipts/transactions/'+$_.Name})
        $ownedDirt=@($ownedPaths|Sort-Object -Unique|Where-Object{Test-Path -LiteralPath (Join-Path $faultWorkspace $_)}|ForEach-Object{[pscustomobject]@{path="$fault/$_";status=' M';sha256=Get-EnvelopeFileSha256 (Join-Path $faultWorkspace $_)}})
        &$extensionModule {param($w,$r,$i,$d)Assert-ActiveEnvelopePlanningRecoveryDirt -WorkspaceRoot $w -Repository $r -Intent $i -Dirt $d} $faultWorkspace $temp $ownedIntent $ownedDirt
        $wrongDirt=Copy-Envelope $ownedDirt;$wrongDirt[0].sha256='0'*64
        Assert-ActiveEnvelopeRejected {&$extensionModule {param($w,$r,$i,$d)Assert-ActiveEnvelopePlanningRecoveryDirt -WorkspaceRoot $w -Repository $r -Intent $i -Dirt $d} $faultWorkspace $temp $ownedIntent $wrongDirt} "planning recovery admitted wrong projection bytes at $fault"
        $extraDirt=@($ownedDirt)+@([pscustomobject]@{path="$fault/unowned.json";status='??';sha256='0'*64})
        Assert-ActiveEnvelopeRejected {&$extensionModule {param($w,$r,$i,$d)Assert-ActiveEnvelopePlanningRecoveryDirt -WorkspaceRoot $w -Repository $r -Intent $i -Dirt $d} $faultWorkspace $temp $ownedIntent $extraDirt} "planning recovery admitted an unrelated path at $fault"
        Write-Output "PASS genuine $fault planning recovery bytes and drift/unrelated-path denials"
        &$transitionModule {param($w)Complete-MorphospaceTransitionLedger -WorkspaceRoot $w -TransactionId 'u002-add-dependency-recorded-transition' -Repair} $faultWorkspace|Out-Null
        $faultState=Read-EnvelopeProtocolJson (Join-Path $faultWorkspace 'workspace.state.json')
        Assert-ActiveEnvelopeTest ((Get-EnvelopeCanonicalJsonSha256 $faultState.validation_checkpoint)-ceq(Get-EnvelopeCanonicalJsonSha256 $beforeState.validation_checkpoint)) "generic recovery changed retained checkpoint at $fault"
        foreach($path in $acceptedEvidence){Assert-ActiveEnvelopeTest ((Get-EnvelopeFileSha256 (Join-Path $faultWorkspace $path))-ceq$acceptedHashes[$path]) "generic recovery changed accepted evidence at $fault/$path"}
    }
    $recoveryWorkspace=$preExtensionWorkspace;$recoveryRequestInfo=New-ActiveEnvelopeExtensionRequest -Workspace $recoveryWorkspace -AddedRepository $added -RequestPath (Join-Path $temp 'recovery-extension.json')
    $interrupted=$false;try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $recoveryWorkspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $recoveryRequestInfo.request_path -RepositoryMapPath $recoveryRequestInfo.map_path -OutPath $recoveryRequestInfo.receipt_path -SourceCompositionOutPath $recoveryRequestInfo.source_path -ExpectedActiveDevelopmentEnvelopeExtensionSha256 (Get-EnvelopeFileSha256 $recoveryRequestInfo.request_path) -Timestamp '2026-09-15T01:10:00.0000000Z' -Execute -FaultAfter after-intent|Out-Null}catch{$interrupted=$true}
    Assert-ActiveEnvelopeTest ($interrupted-and(Test-Path (Join-Path $recoveryWorkspace 'receipts\transactions\u002-add-dependency-recorded-transition.intent.json'))) 'recovery fixture did not retain the v6 intent'
    foreach($path in $acceptedEvidence){
        $absolute=Join-Path $recoveryWorkspace $path;$bytes=[IO.File]::ReadAllBytes($absolute)
        Set-ActiveEnvelopeEvidenceDamage $absolute;$inventory=Get-EnvelopeWorkspaceByteInventorySha256 $recoveryWorkspace
        Assert-ActiveEnvelopeRejected {&$transitionModule {param($w)Complete-MorphospaceTransitionLedger -WorkspaceRoot $w -TransactionId 'u002-add-dependency-recorded-transition' -Repair} $recoveryWorkspace} "generic Recover accepted damaged predecessor $path"
        Assert-ActiveEnvelopeTest ((Get-EnvelopeWorkspaceByteInventorySha256 $recoveryWorkspace)-ceq$inventory) "recovery rejection mutated workspace for $path"
        [IO.File]::WriteAllBytes($absolute,$bytes)
    }
    [IO.File]::WriteAllText($dirtyDependencyPath,'recovery drift',[Text.UTF8Encoding]::new($false))
    Assert-ActiveEnvelopeRejected {&$transitionModule {param($w)Complete-MorphospaceTransitionLedger -WorkspaceRoot $w -TransactionId 'u002-add-dependency-recorded-transition' -Repair} $recoveryWorkspace} 'generic Recover accepted captured dependency-source drift'
    Remove-Item -LiteralPath $dirtyDependencyPath
    $parentSourcePath=Join-Path $recoveryWorkspace ([string]$recoveryRequestInfo.request.expected.source_composition_path);$parentSourceBytes=[IO.File]::ReadAllBytes($parentSourcePath);[IO.File]::AppendAllText($parentSourcePath,' ',[Text.UTF8Encoding]::new($false))
    Assert-ActiveEnvelopeRejected {&$transitionModule {param($w)Complete-MorphospaceTransitionLedger -WorkspaceRoot $w -TransactionId 'u002-add-dependency-recorded-transition' -Repair} $recoveryWorkspace} 'generic Recover accepted parent source-composition drift'
    [IO.File]::WriteAllBytes($parentSourcePath,$parentSourceBytes)
    $mapBytes=[IO.File]::ReadAllBytes($recoveryRequestInfo.map_path);[IO.File]::AppendAllText($recoveryRequestInfo.map_path,' ',[Text.UTF8Encoding]::new($false))
    Assert-ActiveEnvelopeRejected {&$transitionModule {param($w)Complete-MorphospaceTransitionLedger -WorkspaceRoot $w -TransactionId 'u002-add-dependency-recorded-transition' -Repair} $recoveryWorkspace} 'generic Recover accepted effective repository-map drift'
    [IO.File]::WriteAllBytes($recoveryRequestInfo.map_path,$mapBytes)
    $recovered=Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $recoveryWorkspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $recoveryRequestInfo.request_path -RepositoryMapPath $recoveryRequestInfo.map_path -OutPath $recoveryRequestInfo.receipt_path -SourceCompositionOutPath $recoveryRequestInfo.source_path -ExpectedActiveDevelopmentEnvelopeExtensionSha256 (Get-EnvelopeFileSha256 $recoveryRequestInfo.request_path) -Execute
    Assert-ActiveEnvelopeTest ($recovered.executed-and(Test-Path (Join-Path $recoveryWorkspace 'receipts\transactions\u002-add-dependency-recorded-transition.completion.json'))) 'exact interrupted extension did not recover'

    [pscustomobject]@{result='pass';action='ExtendActiveDevelopmentEnvelope';prepare_admit_ready_claim_extend=$true;retained_accepted_checkpoint=$true;checkpoint_damage_rejected=$true;accepted_evidence_preserved=$true;current_work_after_retirement=$true;null_checkpoint=$true;additive=$true;unreviewed_root_rejected=$true;dirty_source_rejected=$true;freeze_consumer=$true;retire_active_recovery=$true;v6_recovery=$true;planning_owned_recovery_bytes=$true;generic_recover_source_drift_rejected=$true;generic_recover_map_drift_rejected=$true;git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}|ConvertTo-Json -Compress
}finally{
    $cleanupTarget=[IO.Path]::GetFullPath($temp);$cleanupName=[IO.Path]::GetFileName($cleanupTarget);$cleanupParent=[IO.Path]::GetFullPath((Split-Path $cleanupTarget -Parent)).TrimEnd('\','/')
    if($cleanupParent-cne$tempParent-or$cleanupName-cnotmatch'^active-envelope-extension-[0-9a-f]{32}$'){throw "Active-envelope test cleanup target escaped its unique temp prefix: '$cleanupTarget'."}
    if(Test-Path -LiteralPath $cleanupTarget){Remove-Item -LiteralPath $cleanupTarget -Recurse -Force}
}
