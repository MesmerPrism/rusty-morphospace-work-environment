param([switch]$SelfTest,[switch]$RetainedAuthorityOnly)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent

$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopePreparation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force
$automationModule=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force -PassThru
$extensionModule=Import-Module (Join-Path $PSScriptRoot 'ActiveDevelopmentEnvelopeExtension.psm1') -Force -PassThru
$freezeModule=Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -PassThru
$retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
$transitionPath=Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1'
$transitionModule=@(Get-Module -All|Where-Object{$_.Path-eq$transitionPath}|Select-Object -Last 1)[0]
if($null-eq$transitionModule){throw 'Active-envelope test cannot retain the transition-ledger module.'}
$continuationModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceDevelopmentContinuation.psm1') -PassThru
. (Join-Path $PSScriptRoot 'test-support\DevelopmentAdmissionFixture.ps1')
. (Join-Path $PSScriptRoot 'test-support\ActiveUnitRetirementFixture.ps1')

function Assert-ActiveEnvelopeTest([bool]$Condition,[string]$Message){if(-not$Condition){throw "Active development-envelope extension self-test failed: $Message"}}
function Assert-ActiveEnvelopeRejected([scriptblock]$Action,[string]$Message){$rejected=$false;try{&$Action|Out-Null}catch{$rejected=$true};Assert-ActiveEnvelopeTest $rejected $Message}

function Invoke-RetainedAuthorityFocusedTests {
    $surface=[pscustomobject][ordered]@{surface_kind='readme';path='README.md';owner='workflow-owner';change_reason='Keep the declared instruction current.';action='update';status='planned';validation='Observe the exact managed file.'}
    $before=[pscustomobject][ordered]@{schema='test.unit';project_id='test-project';unit_id='test-unit';status='active';objective='Preserve the admitted objective.';prerequisites=@('prior-unit');acceptance=@('The admitted acceptance remains exact.');instruction_surfaces=@($surface)}
    $statusAfter=Copy-Envelope $before;$statusAfter.status='validating'
    [void](&$continuationModule {param($b,$a)Assert-DevelopmentContinuationRetainedAuthority $b $a ([pscustomobject]@{artifacts=@()}) ([pscustomobject]@{})} $before $statusAfter)
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
    [pscustomobject]@{result='pass';retained_status=$true;retained_instruction_completion=$true;forged_objective=$true;forged_acceptance=$true;forged_prerequisites=$true;forged_instruction_row=$true}
}

function New-ActiveEnvelopeExtensionRequest {
    param([string]$Workspace,[string]$AddedRepository,[string]$RequestPath)
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
    Write-EnvelopeJson $RequestPath $request
    return [pscustomobject]@{request=$request;request_path=$RequestPath;map_path=$targetMapPath;receipt_path=(Join-Path $Workspace 'receipts\u002-add-dependency.json');source_path=(Join-Path $Workspace 'source-composition-locks\u002-add-dependency.json')}
}

function New-ActiveEnvelopeFreezeRequest {
    param([string]$Workspace,[string]$RepositoryMapPath,[string]$RequestPath)
    $project=Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json');$lock=Read-EnvelopeProtocolJson (Join-Path $Workspace 'feature.lock.json');$state=Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json');$unit=Read-EnvelopeProtocolJson (Join-Path $Workspace 'iteration-units\u002.json')
    $eventsPath=Join-Path $Workspace 'iteration-events.jsonl';$events=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String});$map=Read-EnvelopeProtocolJson $RepositoryMapPath;$mapRows=@{};foreach($row in @($map.repositories)){$mapRows[[string]$row.repo_id]=$row}
    $final=[Collections.Generic.List[object]]::new();$changed=[Collections.Generic.List[object]]::new()
    foreach($scope in @($unit.allowed_repositories)){
        $id=[string]$scope.repo_id;if(-not$mapRows.ContainsKey($id)){throw "Freeze fixture writable repository '$id' is absent from the effective map."};$root=[string]$mapRows[$id].path
        $head=(@(Invoke-EnvelopeGit $root @('rev-parse','HEAD'))[0]).Trim().ToLowerInvariant();$tree=(@(Invoke-EnvelopeGit $root @('rev-parse','HEAD^{tree}'))[0]).Trim().ToLowerInvariant()
        $final.Add([pscustomobject][ordered]@{repo_id=$id;commit=$head;tree=$tree})|Out-Null;$changed.Add([pscustomobject][ordered]@{repo_id=$id;paths=@($scope.allowed_paths)})|Out-Null
    }
    $sourceRelative=[string]$unit.source_composition.lock_path;$sourcePath=Join-Path $Workspace $sourceRelative;$mapRelative=[IO.Path]::GetRelativePath($Workspace,$RepositoryMapPath).Replace('\','/');$deviceUse=@(if(@($unit.agent_scope_assessment.device_envelope.allowed_kinds).Count){@($unit.agent_scope_assessment.device_envelope.allowed_kinds)}else{@('none')})
    $freeze=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id='u002-extension-freeze';project_id=[string]$project.project_id;unit_id='u002'
        expected=[pscustomobject][ordered]@{project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $lock;source_composition_path=$sourceRelative;source_composition_sha256=Get-EnvelopeFileSha256 $sourcePath;repository_map_path=$mapRelative;repository_map_sha256=Get-EnvelopeFileSha256 $RepositoryMapPath;events_sha256=Get-EnvelopeFileSha256 $eventsPath;events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$events[-1].event_id}
        final_repositories=@($final.ToArray());changed_paths=@($changed.ToArray());cleanliness_policy='clean-only';instruction_surfaces=@([pscustomobject][ordered]@{path='README.md';disposition='reviewed-no-change'});feature_lock=[pscustomobject][ordered]@{revision=[int]$lock.revision;sha256=Get-EnvelopeCanonicalJsonSha256 $lock};effects=@($unit.agent_scope_assessment.allowed_effect_categories);permissions=@($unit.agent_scope_assessment.allowed_permission_categories);device_use=@($deviceUse);test_matrix=@([pscustomobject][ordered]@{test_id='extension';command='pwsh -NoProfile -File scripts/Test-ActiveDevelopmentEnvelopeExtension.ps1'});cleanup_evidence=@('All source repositories are clean at their exact candidate identities.');source_composition=[pscustomobject][ordered]@{path=$sourceRelative;sha256=Get-EnvelopeFileSha256 $sourcePath};does_not_prove=@('Does not validate, accept, publish, mutate Git, or operate a device.')
    }
    Write-EnvelopeJson $RequestPath $freeze
    return $freeze
}

$retainedAuthorityResult=Invoke-RetainedAuthorityFocusedTests
if($RetainedAuthorityOnly){$retainedAuthorityResult|ConvertTo-Json -Compress;return}

$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$temp=Join-Path $tempParent ('active-envelope-extension-'+[guid]::NewGuid().ToString('N'))
try{
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    $seed=New-EnvelopeAdmissionPreparedFixture -Root (Join-Path $temp 'seed') -RepositoryRoot $repoRoot -TransitionLedgerModule $transitionModule -OwnerProducedPreparation -AdditiveFeature
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

    $recoveryWorkspace=$preExtensionWorkspace;$recoveryRequestInfo=New-ActiveEnvelopeExtensionRequest -Workspace $recoveryWorkspace -AddedRepository $added -RequestPath (Join-Path $temp 'recovery-extension.json')
    $interrupted=$false;try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $recoveryWorkspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $recoveryRequestInfo.request_path -RepositoryMapPath $recoveryRequestInfo.map_path -OutPath $recoveryRequestInfo.receipt_path -SourceCompositionOutPath $recoveryRequestInfo.source_path -ExpectedActiveDevelopmentEnvelopeExtensionSha256 (Get-EnvelopeFileSha256 $recoveryRequestInfo.request_path) -Timestamp '2026-09-15T01:10:00.0000000Z' -Execute -FaultAfter after-intent|Out-Null}catch{$interrupted=$true}
    Assert-ActiveEnvelopeTest ($interrupted-and(Test-Path (Join-Path $recoveryWorkspace 'receipts\transactions\u002-add-dependency-recorded-transition.intent.json'))) 'recovery fixture did not retain the v6 intent'
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

    [pscustomobject]@{result='pass';action='ExtendActiveDevelopmentEnvelope';prepare_admit_ready_claim_extend=$true;additive=$true;unreviewed_root_rejected=$true;dirty_source_rejected=$true;freeze_consumer=$true;retire_active_recovery=$true;v6_recovery=$true;generic_recover_source_drift_rejected=$true;generic_recover_map_drift_rejected=$true;git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}|ConvertTo-Json -Compress
}finally{
    $cleanupTarget=[IO.Path]::GetFullPath($temp);$cleanupName=[IO.Path]::GetFileName($cleanupTarget);$cleanupParent=[IO.Path]::GetFullPath((Split-Path $cleanupTarget -Parent)).TrimEnd('\','/')
    if($cleanupParent-cne$tempParent-or$cleanupName-cnotmatch'^active-envelope-extension-[0-9a-f]{32}$'){throw "Active-envelope test cleanup target escaped its unique temp prefix: '$cleanupTarget'."}
    if(Test-Path -LiteralPath $cleanupTarget){Remove-Item -LiteralPath $cleanupTarget -Recurse -Force}
}
