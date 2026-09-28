param(
    [switch]$SelfTest,
    [switch]$InertProposalsOnly,
    [ValidateSet('All', 'Core', 'NestedPositive', 'NestedCommitted', 'NestedMapGuards', 'AmendmentRecovery', 'NestedRecovery', 'NestedDamage', 'PlanningProjection')]
    [string]$Scenario = 'All'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if(-not$SelfTest){throw 'Test-ActiveUnitRetirement requires -SelfTest.'}

$repository=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementContinuation.ps1')
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementFixture.ps1')
$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force -PassThru
$retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -Force -PassThru
if($null-eq(Get-Command Read-MorphospaceProtocolJson -ErrorAction SilentlyContinue)){throw 'Active retirement test: importing the retirement owner removed the caller protocol commands.'}
function Assert-RetirementTest([bool]$Value,[string]$Message){if(-not$Value){throw "Active retirement test: $Message"}}
function Assert-RetirementNoReparse([string]$Root,[string]$Candidate){&$protocolModule {param($root,$candidate)Assert-MorphospaceNoReparseAncestor -Root $root -Candidate $candidate} $Root $Candidate}
function Get-RetirementInventory([string]$Workspace){
    $rows=@(Get-ChildItem -LiteralPath $Workspace -Recurse -File -Force|Sort-Object FullName|ForEach-Object{[pscustomobject]@{path=[IO.Path]::GetRelativePath($Workspace,$_.FullName).Replace('\','/');sha256=Get-EnvelopeFileSha256 $_.FullName}})
    Get-EnvelopeCanonicalJsonSha256 $rows
}
function Get-RetirementBytesSha256([byte[]]$Bytes){&$protocolModule {param($value)Get-MorphospaceSha256Bytes $value} $Bytes}
function Write-RetirementRequest([string]$Workspace,[object]$Request){Write-EnvelopeJson ($Workspace+'.request.json') $Request}
function Invoke-RetirementTest([string]$Workspace,[bool]$Execute=$true,[string]$FaultAfter='none',[string]$RepoMapPath=''){
    $requestPath=$Workspace+'.request.json'
    if(-not$RepoMapPath){$RepoMapPath=Join-Path $Workspace 'repository-map.json'}
    Invoke-MorphospaceRetireActive -WorkspaceRoot $Workspace -UnitId u002 -RepoMapPath $RepoMapPath -ActiveUnitRetirement $requestPath -ExpectedActiveUnitRetirementSha256 (Get-EnvelopeFileSha256 $requestPath) -OutPath (Join-Path $Workspace 'receipts/retire-u002.json') -Timestamp '2026-08-25T00:00:43.0000000Z' -Execute:$Execute -FaultAfter $FaultAfter
}
function Assert-RetirementRejects([string]$Workspace,[string]$Label,[string]$Pattern='*'){
    $before=Get-RetirementInventory $Workspace;$message='';$rejected=$false
    try{Invoke-RetirementTest $Workspace|Out-Null}catch{$rejected=$true;$message=$_.Exception.Message}
    Assert-RetirementTest ($rejected-and$message-like$Pattern) "$Label was not rejected: $message"
    Assert-RetirementTest ((Get-RetirementInventory $Workspace)-ceq$before) "$Label mutated workspace bytes"
}
function New-RetirementNestedPlanningProjection([object]$Seed,[string]$Root,[string]$Name){
    $fixtureRoot=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$fixturePrefix=$fixtureRoot+[IO.Path]::DirectorySeparatorChar;$planning=[IO.Path]::GetFullPath([string]$Seed.source_repository);$snapshot=[IO.Path]::GetFullPath([string]$Seed.retirement_snapshot_path)
    foreach($path in @($planning,$snapshot)){if(-not$path.StartsWith($fixturePrefix,[StringComparison]::OrdinalIgnoreCase)){throw "Retirement fixture restore path escapes its unique root: $path"};Assert-RetirementNoReparse -Root $fixtureRoot -Candidate $path;$item=Get-Item -LiteralPath $path -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Retirement fixture restore rejects a reparse point: $path"}}
    if((Get-RetirementInventory $snapshot)-cne[string]$Seed.retirement_snapshot_inventory){throw 'Retirement fixture immutable producer snapshot is damaged.'}
    Remove-Item -LiteralPath $planning -Recurse -Force;Copy-Item -LiteralPath $snapshot -Destination $planning -Recurse -Force
    Assert-RetirementNoReparse -Root $fixtureRoot -Candidate $planning;if((Get-RetirementInventory $planning)-cne[string]$Seed.retirement_snapshot_inventory){throw 'Retirement fixture restore differs from its immutable producer snapshot.'}
    $workspace=Join-Path $planning 'morphospace';$requestPath=Join-Path (Split-Path $planning -Parent) "$([IO.Path]::GetFileName($planning))-request.json";$requestFull=[IO.Path]::GetFullPath($requestPath)
    if(-not$requestFull.StartsWith($fixturePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Retirement fixture request cleanup path escapes its unique root.'};if([IO.File]::Exists($requestFull)){Remove-Item -LiteralPath $requestFull -Force}
    $mapPath=Join-Path $workspace 'repository-map.json';$map=Read-EnvelopeProtocolJson $mapPath
    [pscustomobject]@{repository=$planning;workspace=$workspace;map=$map;map_path=$mapPath}
}
function New-ReadonlyPlanningRetirementSeed([string]$Root,[switch]$Replacement,[switch]$NestedReadOnlySource,[switch]$ImmutableReadOnlyPaths){
    $protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
    $ledger=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
    $seed=@(New-EnvelopeAdmissionPreparedFixture -Root $Root -RepositoryRoot $repository -TransitionLedgerModule $ledger -OwnerProducedPreparation -AdditiveFeature)[-1]
    $planning=[string]$seed.source_repository;$workspace=Join-Path $planning 'morphospace'
    if($ImmutableReadOnlyPaths){Invoke-EnvelopeGit $planning @('config','core.autocrlf','false')|Out-Null}
    foreach($entry in @(Get-ChildItem -LiteralPath $seed.workspace -Force)){Copy-Item -LiteralPath $entry.FullName -Destination $workspace -Recurse -Force}
    if($ImmutableReadOnlyPaths){foreach($name in @('readonly-extra.txt','readonly-later.txt')){[IO.File]::WriteAllText((Join-Path $workspace $name),'immutable planning dependency existing at original pin',[Text.UTF8Encoding]::new($false))}}
    $preparationIntent=$seed.preparation_intent
    Write-EnvelopeJson (Join-Path $workspace 'project.spec.json') $preparationIntent.pre.project.document;Write-EnvelopeJson (Join-Path $workspace 'workspace.state.json') $preparationIntent.pre.state.document;Write-EnvelopeJson (Join-Path $workspace 'feature.lock.json') $preparationIntent.pre.feature_lock.document;Write-EnvelopeJson (Join-Path $workspace 'iteration-units/u001.json') $preparationIntent.pre.predecessor_unit.document
    $ledgerLines=@(Get-Content -LiteralPath (Join-Path $workspace 'iteration-events.jsonl')|Where-Object{$_});[IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'),(($ledgerLines[0..($ledgerLines.Count-2)]-join"`n")+"`n"),[Text.UTF8Encoding]::new($false))
    foreach($relative in @('source-composition.json','receipts/u002-envelope.json','receipts/transactions/u002-envelope-prepared-transition.intent.json','receipts/transactions/u002-envelope-prepared-transition.completion.json')){Remove-Item -LiteralPath (Join-Path $workspace $relative) -Force}
    $map=Read-EnvelopeProtocolJson (Join-Path $workspace 'repository-map.json');@($map.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0].path=$planning
    $nestedSource=$null
    if($NestedReadOnlySource){
        $nestedSourceRoot=Join-Path $Root 'nested-read-only-backing';$nestedSource=Join-Path $nestedSourceRoot 'skills';[IO.Directory]::CreateDirectory($nestedSource)|Out-Null
        Invoke-EnvelopeGit $Root @('init',$nestedSourceRoot)|Out-Null;Invoke-EnvelopeGit $nestedSourceRoot @('config','user.name','Retirement Fixture')|Out-Null;Invoke-EnvelopeGit $nestedSourceRoot @('config','user.email','fixture@example.invalid')|Out-Null
        [IO.File]::WriteAllText((Join-Path $nestedSource 'SKILL.md'),'nested read-only source'+[Environment]::NewLine,[Text.UTF8Encoding]::new($false));Invoke-EnvelopeGit $nestedSourceRoot @('add','skills/SKILL.md')|Out-Null;Invoke-EnvelopeGit $nestedSourceRoot @('commit','-m','nested read-only source')|Out-Null
        $map.repositories+=,[pscustomobject][ordered]@{repo_id='nested-read-only-source';path=$nestedSource;role='source'}
    }
    Write-EnvelopeJson (Join-Path $workspace 'repository-map.json') $map
    Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;if($ImmutableReadOnlyPaths){Invoke-EnvelopeGit $planning @('add','--renormalize','morphospace')|Out-Null};Invoke-EnvelopeGit $planning @('commit','-m','accepted planning baseline')|Out-Null
    $baselineStatus=@(Invoke-EnvelopeGit $planning @('status','--porcelain=v1','--untracked-files=all'));if($baselineStatus.Count-ne0){throw "Nested accepted baseline commit is dirty: $($baselineStatus-join', ')"}
    $lockedHead=(@(Invoke-EnvelopeGit $planning @('rev-parse','HEAD'))[0]).Trim().ToLowerInvariant()
    $preparationDocument=Read-EnvelopeProtocolJson (Join-Path $Root 'u002-envelope-preparation.json');$preState=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$preProject=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json');$preFeature=Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json');$eventsPath=Join-Path $workspace 'iteration-events.jsonl'
    if($NestedReadOnlySource){
        $preparationDocument.envelope.project.repositories+=,[pscustomobject][ordered]@{repo_id='nested-read-only-source';role='core';path='../nested-read-only-source';allowed_paths=@('SKILL.md')}
        $preparationDocument.envelope.owner_repositories+=,[pscustomobject][ordered]@{repo_id='nested-read-only-source';source_roots=@('SKILL.md')}
        $preparationDocument.envelope.source_composition.repository_ids+=,'nested-read-only-source'
    }
    @($preparationDocument.envelope.feature_lock.features)[0].descriptor.source_revision=$lockedHead;$preparationDocument.envelope.feature_lock.lock_fingerprint=Get-EnvelopeLockFingerprint $preparationDocument.envelope.feature_lock
    $preparationDocument.expected.project_sha256=Get-EnvelopeCanonicalJsonSha256 $preProject;$preparationDocument.expected.state_sha256=Get-EnvelopeCanonicalJsonSha256 $preState;$preparationDocument.expected.feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $preFeature;$preparationDocument.expected.repository_map_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'repository-map.json');$preparationDocument.expected.predecessor_unit_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u001.json'));$preparationDocument.expected.events_sha256=Get-EnvelopeFileSha256 $eventsPath;$preparationDocument.expected.events_length=([IO.FileInfo]$eventsPath).Length;$preparationDocument.expected.event_tail_id=[string]$preState.last_event_id
    $preparationPath=Join-Path $Root 'nested-preparation.json';Write-EnvelopeJson $preparationPath $preparationDocument
    $null=Invoke-MorphospacePrepareDevelopmentEnvelope -WorkspaceRoot $workspace -DevelopmentEnvelopePreparation $preparationPath -ExpectedDevelopmentEnvelopePreparationSha256 (Get-EnvelopeFileSha256 $preparationPath) -OutPath (Join-Path $workspace 'receipts/u002-envelope.json') -Timestamp '2026-08-25T00:00:30.0000000Z' -Execute
    $admission=Copy-Envelope $seed.admission_template;$state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$project=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json');$feature=Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json');$sourcePath=Join-Path $workspace 'source-composition.json'
    $admission.preparation.receipt_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'receipts/u002-envelope.json');$admission.preparation.source_composition_sha256=Get-EnvelopeFileSha256 $sourcePath
    $admission.expected.project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;$admission.expected.state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;$admission.expected.feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $feature;$admission.expected.source_composition_sha256=Get-EnvelopeFileSha256 $sourcePath;$admission.expected.repository_map_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'repository-map.json');$admission.expected.events_sha256=Get-EnvelopeFileSha256 $eventsPath;$admission.expected.events_length=([IO.FileInfo]$eventsPath).Length;$admission.expected.event_tail_id=[string]$state.last_event_id
    $admission.unit.allowed_repositories=@([pscustomobject]@{repo_id='read-only-dependency';allowed_paths=@('dependency/')})
    $admission.unit.read_only_dependencies=@([pscustomobject][ordered]@{repo_id='project-shell';paths=@($(if($ImmutableReadOnlyPaths){'morphospace/README.md'}else{'morphospace/'}));purpose='Nested planning authority.';verification='Exact preparation lock and authenticated lifecycle projection.'})
    if($NestedReadOnlySource){
        $ownerRow=[pscustomobject][ordered]@{repo_id='nested-read-only-source';source_roots=@('SKILL.md')}
        $admission.agent_scope_assessment.owner_repositories+=,$ownerRow;$admission.unit.agent_scope_assessment.owner_repositories+=,(Copy-Envelope $ownerRow)
        $admission.unit.read_only_dependencies+=,[pscustomobject][ordered]@{repo_id='nested-read-only-source';paths=@('SKILL.md');purpose='Producer-authenticated nested source materialization.';verification='Exact preparation commit, tree, role, map, and clean backing repository.'}
    }
    $admission.unit.agent_scope_assessment=$admission.agent_scope_assessment
    if($ImmutableReadOnlyPaths){$admission.unit.instruction_impact='review';$admission.unit.instruction_none_justification=$null;$admission.unit.instruction_surfaces=@([pscustomobject][ordered]@{surface_kind='validation-doc';path='<project-shell>/morphospace/README.md';owner='project-shell';change_reason='Review the immutable planning instructions used by this lifecycle fixture.';action='review-no-change';status='planned';validation='Stable source content observation.';skill_id=$null})}
    $admissionPath=Join-Path $Root 'u002-readonly-planning-admission.json';Write-EnvelopeJson $admissionPath $admission
    $automation=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'
    $null=&$automation -Action AdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts/u002-admission.json') -Timestamp '2026-08-25T00:00:40.0000000Z' -Execute
    if($Replacement){
        $retireDry=&$automation -Action RetireProposed -WorkspaceRoot $workspace -UnitId u002 -ReplacementUnitId u003 -RetirementReason contract-invalid -OutPath (Join-Path $workspace 'receipts/u002-contract-retirement.json') -Timestamp '2026-08-25T00:00:41.0000000Z'|ConvertFrom-Json;$pre=$retireDry.proposed_retirement.authenticated_preimage
        $null=&$automation -Action RetireProposed -WorkspaceRoot $workspace -UnitId u002 -ReplacementUnitId u003 -RetirementReason contract-invalid -OutPath (Join-Path $workspace 'receipts/u002-contract-retirement.json') -ExpectedStateSha256 $pre.state_sha256 -ExpectedUnitSha256 $pre.unit_sha256 -ExpectedUnitRawSha256 $pre.unit_raw_sha256 -ExpectedEventsSha256 $pre.events_sha256 -ExpectedEventsLength ([long]$pre.events_length) -ExpectedEventTailId $pre.event_tail_id -ExpectedProposedRetirementBindingSha256 $retireDry.proposed_retirement.binding_sha256 -Timestamp '2026-08-25T00:00:41.0000000Z' -Execute
        $admission=New-EnvelopeReplacementAdmission $admission $workspace u003-admission u003;$admissionPath=Join-Path $Root 'u003-readonly-planning-admission.json';Write-EnvelopeJson $admissionPath $admission
        $null=&$automation -Action AdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts/u003-admission.json') -Timestamp '2026-08-25T00:00:42.0000000Z' -Execute;$unitId='u003';$ready='2026-08-25T00:00:43.0000000Z';$claim='2026-08-25T00:00:44.0000000Z'
    }else{$unitId='u002';$ready='2026-08-25T00:00:41.0000000Z';$claim='2026-08-25T00:00:42.0000000Z'}
    $lifecycle=@{WorkspaceRoot=$workspace;UnitId=$unitId;RepoMapPath=(Join-Path $workspace 'repository-map.json');ValidationTier='quick'}
    $readyOutput=if($ImmutableReadOnlyPaths){@{OutPath=(Join-Path $workspace 'receipts/ordinary-reviewed-ready.json')}}else{@{}};$claimOutput=if($ImmutableReadOnlyPaths){@{OutPath=(Join-Path $workspace 'receipts/ordinary-claimed-owner.json')}}else{@{}}
    $null=&$automation @lifecycle @readyOutput -Action Ready -Timestamp $ready -Execute;$null=&$automation @lifecycle @claimOutput -Action Claim -Timestamp $claim -Execute
    $baselineLeak=@(Invoke-EnvelopeGit $planning @('status','--porcelain=v1','--untracked-files=all')|Where-Object{[string]$_-match'u001|repository-map'});if($baselineLeak.Count-ne0){throw "Nested lifecycle dirt leaked baseline paths: $($baselineLeak-join', ')"}
    $seed.workspace=$workspace
    $snapshot=Join-Path $Root 'retirement-planning-snapshot';if([IO.Directory]::Exists($snapshot)){throw 'Retirement fixture immutable planning snapshot already exists.'};Copy-Item -LiteralPath $planning -Destination $snapshot -Recurse -Force
    $seed|Add-Member -NotePropertyName retirement_snapshot_path -NotePropertyValue $snapshot -Force
    $seed|Add-Member -NotePropertyName retirement_snapshot_inventory -NotePropertyValue (Get-RetirementInventory $snapshot) -Force
    return $seed
}
function New-PlanningProjectionExtensionRequest {
    param([string]$Workspace,[string]$AddedRepository,[string]$RequestPath,[string]$ExtensionId='u002-add-dependency',[string]$DependencyId='added-dependency',[string]$AddPlanningReadOnlyPath)
    $project=Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json')
    $lock=Read-EnvelopeProtocolJson (Join-Path $Workspace 'feature.lock.json')
    $state=Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json')
    $unit=Read-EnvelopeProtocolJson (Join-Path $Workspace 'iteration-units\u002.json')
    $source=Read-EnvelopeProtocolJson (Join-Path $Workspace ([string]$unit.source_composition.lock_path))
    $parentMapRelative=if([string]$source.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){[string]$source.repository_map.path}else{'repository-map.json'}
    $map=Read-EnvelopeProtocolJson (Join-Path $Workspace $parentMapRelative)
    $targetMap=Copy-Envelope $map
    $targetMap.repositories+=,[pscustomobject][ordered]@{repo_id=$DependencyId;path=$AddedRepository;role='source'}
    $targetMapPath=Join-Path $Workspace ("local/$ExtensionId-map.json");Write-EnvelopeJson $targetMapPath $targetMap
    $targetProject=Copy-Envelope $project;$targetProject.revision=[int]$project.revision+1
    $targetProject.repositories+=,[pscustomobject][ordered]@{repo_id=$DependencyId;role='core';path=("../$DependencyId");allowed_paths=@('dep/')}
    $targetLock=Copy-Envelope $lock;$targetLock.project_revision=[int]$targetProject.revision;$targetLock.revision=[int]$lock.revision+1;$targetLock.generated_at='2026-09-15T01:00:00.0000000Z';$targetLock.lock_fingerprint='0'*64;$targetLock.lock_fingerprint=Get-EnvelopeCanonicalJsonSha256 $targetLock
    $targetState=Copy-Envelope $state;$targetState.plan_revision=[int]$state.plan_revision+1;$targetState.last_event_id=("$ExtensionId-recorded");$targetState.module_registry.lock_revision=[int]$targetLock.revision;$targetState.module_registry.lock_fingerprint=[string]$targetLock.lock_fingerprint
    $assessment=Copy-Envelope $unit.agent_scope_assessment
    $assessment.owner_repositories+=,[pscustomobject][ordered]@{repo_id=$DependencyId;source_roots=@('dep/')}
    $allowed=@(Copy-Envelope @($unit.allowed_repositories))
    $readOnly=@(Copy-Envelope @($(if($unit.PSObject.Properties.Name-contains'read_only_dependencies'){$unit.read_only_dependencies}else{@()})))
    if($AddPlanningReadOnlyPath){@($readOnly|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0].paths+=,$AddPlanningReadOnlyPath}
    $readOnly+=,[pscustomobject][ordered]@{repo_id=$DependencyId;paths=@('dep/');purpose='Compile against the newly discovered code dependency.';verification='Keep the dependency at the exact derivative source identity.'}
    $emptyEffects=[ordered]@{};foreach($axis in @('permissions','services','activities','queries','tools','assets','shaders','native_libraries','commands','routes','streams','inputs','scenes','markers')){$emptyEffects[$axis]=@()}
    $eventsPath=Join-Path $Workspace 'iteration-events.jsonl';$events=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String})
    $sourcePath=Join-Path $Workspace ([string]$unit.source_composition.lock_path)
    $mapPath=Join-Path $Workspace $parentMapRelative
    $request=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.active_development_envelope_extension.v1'
        extension_id=$ExtensionId;project_id='envelope-test';unit_id='u002'
        rationale='The unchanged objective requires one newly discovered compile-time dependency owned by the declared repository.'
        ownership_proof=@([pscustomobject][ordered]@{repo_id=$DependencyId;source_roots=@('dep/');owner='dependency-owner';evidence='The committed dependency root and its read-only role were reviewed against the unchanged objective.'})
        additions=[pscustomobject][ordered]@{repository_ids=@($DependencyId);owner_roots=@([pscustomobject][ordered]@{repo_id=$DependencyId;source_roots=@('dep/')});feature_ids=@();module_ids=@();authority_parameters=@();effects=[pscustomobject]$emptyEffects;permissions=@();validation_profile_ids=@();acceptance_profile_ids=@();build_profile_ids=@();device_kinds=@()}
        before=[pscustomobject][ordered]@{project=$project;feature_lock=$lock;state=$state;agent_scope_assessment=$unit.agent_scope_assessment;allowed_repositories=@($unit.allowed_repositories);read_only_dependencies=@($(if($unit.PSObject.Properties.Name-contains'read_only_dependencies'){$unit.read_only_dependencies}else{@()}))}
        target=[pscustomobject][ordered]@{project=$targetProject;feature_lock=$targetLock;state=$targetState;agent_scope_assessment=$assessment;allowed_repositories=@($allowed);read_only_dependencies=@($readOnly)}
        source_composition=[pscustomobject][ordered]@{path=("source-composition-locks/$ExtensionId.json");repository_ids=@(@($source.repositories.repo_id)+@($DependencyId)|Sort-Object -Unique)}
        effective_repository_map=[pscustomobject][ordered]@{path=("local/$ExtensionId-map.json");raw_sha256=Get-EnvelopeFileSha256 $targetMapPath}
        expected=[pscustomobject][ordered]@{
            status='active';current_unit='u002';project_revision=[int]$project.revision;feature_lock_revision=[int]$lock.revision;plan_revision=[int]$state.plan_revision
            project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;project_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'project.spec.json')
            feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $lock;feature_lock_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'feature.lock.json')
            state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;state_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'workspace.state.json')
            unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;unit_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'iteration-units\u002.json')
            events_sha256=Get-EnvelopeFileSha256 $eventsPath;events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$events[-1].event_id
            source_composition_path=[string]$unit.source_composition.lock_path;source_composition_raw_sha256=Get-EnvelopeFileSha256 $sourcePath;source_composition_canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $source
            repository_map_path=$parentMapRelative;repository_map_raw_sha256=Get-EnvelopeFileSha256 $mapPath
            original_source_composition_path=$(if([string]$source.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){$source.original_preparation.path}else{[string]$unit.source_composition.lock_path});original_source_composition_raw_sha256=$(if([string]$source.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){$source.original_preparation.raw_sha256}else{Get-EnvelopeFileSha256 $sourcePath})
            original_repository_map_path='repository-map.json';original_repository_map_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'repository-map.json')
        }
        does_not_prove=@('Does not change the objective, validate, accept, publish, mutate Git, or operate a device.')
    }
    Write-EnvelopeJson $RequestPath $request
    return [pscustomobject]@{request=$request;request_path=$RequestPath;map_path=$targetMapPath;receipt_path=(Join-Path $Workspace ("receipts/$ExtensionId.json"));source_path=(Join-Path $Workspace ("source-composition-locks/$ExtensionId.json"))}
}

function New-PlanningProjectionFreezeRequest {
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

function Add-ReadonlyPlanningWriteScopeAmendment([object]$Projection,[string]$AmendmentId='u002-add-nested-file'){
    $workspace=[string]$Projection.workspace;$unitId=[string](Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')).current_unit
    $unit=Read-EnvelopeProtocolJson (Join-Path $workspace "iteration-units/$unitId.json");$project=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json');$state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$eventsPath=Join-Path $workspace 'iteration-events.jsonl'
    $repository=[string]$unit.allowed_repositories[0].repo_id;$unitRow=@($unit.allowed_repositories|Where-Object{[string]$_.repo_id-ceq$repository})[0];$projectRow=@($project.repositories|Where-Object{[string]$_.repo_id-ceq$repository})[0];$assessmentRow=@($unit.agent_scope_assessment.owner_repositories|Where-Object{[string]$_.repo_id-ceq$repository})[0]
    $newPath=([string]$projectRow.allowed_paths[0]).TrimEnd('/')+'/retirement-continuation.txt';$after=@($unitRow.allowed_paths)+$newPath
    $amendment=[pscustomobject][ordered]@{'$schema'='https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/active-write-scope-amendment-v1.schema.json';schema='rusty.morphospace.workflow.active_write_scope_amendment.v1';amendment_id=$AmendmentId;project_id=[string]$project.project_id;unit_id=$unitId;repository_id=$repository;reason='Exercise authenticated planning continuation before active retirement.';semantic_rationale='The added exact file remains within the existing admitted owner root and objective.';ownership_proof=[pscustomobject][ordered]@{repo_id=$repository;source_roots=@($assessmentRow.source_roots);tracked_paths=@($after)};source_composition=[pscustomobject][ordered]@{mode=[string]$unit.source_composition.mode;lock_path=[string]$unit.source_composition.lock_path;lock_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace ([string]$unit.source_composition.lock_path))};expected=[pscustomobject][ordered]@{status='active';current_unit=$unitId;project_revision=[int]$project.revision;project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;events_sha256=Get-EnvelopeFileSha256 $eventsPath;events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$state.last_event_id};before_allowed_paths=@($unitRow.allowed_paths);after_allowed_paths=$after;does_not_prove=@('This fixture does not grant source, validation, acceptance, publication, or device authority.')}
    $inputPath=Join-Path (Split-Path $Projection.repository -Parent) "$([IO.Path]::GetFileName($Projection.repository))-$AmendmentId.json";Write-EnvelopeJson $inputPath $amendment
    $automation=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1';$out=Join-Path $workspace "receipts/$AmendmentId.json"
    $null=&$automation -Action AmendActiveWriteScope -WorkspaceRoot $workspace -UnitId $unitId -ActiveWriteScopeAmendment $inputPath -ExpectedActiveWriteScopeAmendmentSha256 (Get-EnvelopeFileSha256 $inputPath) -OutPath $out -Timestamp '2026-08-25T00:00:42.5000000Z' -Execute
    return $Projection
}
function Invoke-NestedRetirement([object]$Projection,[string]$UnitId,[string]$ReplacementId,[string]$Timestamp,[switch]$Execute,[string]$FaultAfter='none'){
    if(-not[IO.Directory]::Exists([string]$Projection.workspace)-or-not[IO.File]::Exists([string]$Projection.map_path)){throw 'Nested retirement projection paths are absent.'}
    foreach($row in @((Read-EnvelopeProtocolJson $Projection.map_path).repositories)){if([string]::IsNullOrWhiteSpace([string]$row.path)){throw "Nested retirement repository '$([string]$row.repo_id)' has an empty path."}}
    $requestPath=Join-Path (Split-Path $Projection.repository -Parent) "$([IO.Path]::GetFileName($Projection.repository))-request.json"
    $retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
    if([IO.File]::Exists($requestPath)){$request=Read-EnvelopeProtocolJson $requestPath}else{$request=&$retirementModule {param($workspace,$mapPath,$retirementId,$replacement)
        $state=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json');$id=[string]$state.current_unit;$unitPath="iteration-units/$id.json";$unit=Read-MorphospaceProtocolJson (Join-Path $workspace $unitPath);$unitBinding=Get-ActiveRetirementFileBinding $workspace $unitPath;$events=Get-ActiveRetirementEvents $workspace;$expected=[ordered]@{}
        foreach($pair in @(@('project','project.spec.json'),@('feature_lock','feature.lock.json'),@('state','workspace.state.json'))){$binding=Get-ActiveRetirementFileBinding $workspace $pair[1];$expected["$($pair[0])_raw_sha256"]=$binding.raw_sha256;$expected["$($pair[0])_canonical_sha256"]=$binding.canonical_sha256}
        $expected.events_sha256=$events.sha256;$expected.events_length=$events.length;$expected.event_tail_id=$events.tail_id;$expected.repository_map_sha256=Get-MorphospaceFileSha256 $mapPath
        $value=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.active_unit_retirement.v1';retirement_id=$retirementId;project_id=[string]$state.project_id;unit_id=$id;replacement_unit_id=$replacement;reason='scope-replanned';old_unit=[pscustomobject]@{unit_id=$id;path=$unitPath;raw_sha256=$unitBinding.raw_sha256;canonical_sha256=$unitBinding.canonical_sha256;status='active'};expected=[pscustomobject]$expected;source_composition=Get-ActiveRetirementFileBinding $workspace ([string]$unit.source_composition.lock_path);claim=$null;repositories=@();accepted_receipt=[pscustomobject]@{path=[string]$state.last_accepted_receipt;sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ([string]$state.last_accepted_receipt))}}
        $value.claim=Get-ActiveRetirementClaim $workspace $value $events.events;$source=Read-MorphospaceProtocolJson (Join-Path $workspace ([string]$value.source_composition.path));$value.repositories=@(Get-ActiveRetirementRepositories $unit $source $mapPath $workspace);$value
    } $Projection.workspace $Projection.map_path "retire-$UnitId" $ReplacementId;Write-EnvelopeJson $requestPath $request}
    $arguments=@{WorkspaceRoot=$Projection.workspace;UnitId=$UnitId;RepoMapPath=$Projection.map_path;ActiveUnitRetirement=$requestPath;ExpectedActiveUnitRetirementSha256=Get-EnvelopeFileSha256 $requestPath;OutPath=(Join-Path $Projection.workspace "receipts/retire-$UnitId.json");Timestamp=$Timestamp;FaultAfter=$FaultAfter}
    Invoke-MorphospaceRetireActive @arguments -Execute:$Execute
}
function Assert-RetirementCallerProtocol([string]$Workspace,[string]$Context){
    Assert-RetirementTest ($null-ne(Get-Command Read-MorphospaceProtocolJson -ErrorAction SilentlyContinue)) "$Context removed the caller protocol command"
    $document=Read-MorphospaceProtocolJson (Join-Path $Workspace 'project.spec.json')
    Assert-RetirementTest (-not[string]::IsNullOrWhiteSpace([string]$document.project_id)) "$Context left the caller protocol reader unusable"
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-active-retirement-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
try{
    $runCore = $Scenario -cin @('All', 'Core') -or $InertProposalsOnly
    $runNestedPositive = $Scenario -cin @('All', 'NestedPositive')
    $runNestedCommitted = $Scenario -cin @('All', 'NestedCommitted')
    $runNestedMapGuards = $Scenario -cin @('All', 'NestedMapGuards')
    $runAmendmentRecovery = $Scenario -cin @('All', 'AmendmentRecovery')
    $runNestedRecovery = $Scenario -cin @('All', 'NestedRecovery')
    $runNestedDamage = $Scenario -cin @('All', 'NestedDamage')

    if($runCore){
        $seed=New-ActiveRetirementContinuationSeed -Root (Join-Path $temp 'seed') -RepositoryRoot $repository
        $template=$seed.workspace
        $request=New-ActiveUnitRetirementRequest -WorkspaceRoot $template
        Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
        Write-RetirementRequest $template $request
        $requestSchema=Join-Path $repository 'schemas/active-unit-retirement-v1.schema.json'
        Assert-RetirementTest (Test-Json -Json ($request|ConvertTo-Json -Depth 100) -SchemaFile $requestSchema) 'exact request schema'
        function Copy-RetirementWorkspace([string]$Name){$path=Join-Path $temp $Name;Copy-Item -LiteralPath $template -Destination $path -Recurse;Write-RetirementRequest $path $request;return $path}
    # Authentic Prepare/Admit/Ready/Claim authority may coexist with an unrelated
    # never-admitted draft. It grants no ownership and must survive retirement.
    $draft=$seed.u002|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $draft.unit_id='u015';$draft.status='proposed'
    foreach($name in @($draft.PSObject.Properties.Name|Where-Object{$_-match'admission|preparation|^candidate_freeze$|^inherited_candidate'})){$draft.PSObject.Properties.Remove($name)}
    $inert=Copy-RetirementWorkspace 'inert-draft'
    $draftPath=Join-Path $inert 'iteration-units/u015.json';Write-EnvelopeJson $draftPath $draft
    $draftHash=Get-EnvelopeFileSha256 $draftPath;$before=Get-RetirementInventory $inert
    $null=Invoke-RetirementTest $inert $false
    Assert-RetirementTest ((Get-RetirementInventory $inert)-ceq$before) 'inert-draft dry run wrote bytes'
    $done=Invoke-RetirementTest $inert
    Assert-RetirementTest ($done.executed-and$null-eq$done.current_unit_after-and(Get-EnvelopeFileSha256 $draftPath)-ceq$draftHash) 'inert draft was rejected or rewritten'
    foreach($kind in @('admitted','ready','active','validating','prerequisite','queued','receipt-reference','named-replacement')){
        $workspace=Copy-RetirementWorkspace "draft-$kind"
        $proposal=$draft|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
        if($kind-ceq'admitted'){$proposal|Add-Member -NotePropertyName admission -NotePropertyValue ([pscustomobject]@{admission_id='u015-admission'})}
        if(@('ready','active','validating')-ccontains$kind){$proposal.status=$kind}
        Write-EnvelopeJson (Join-Path $workspace 'iteration-units/u015.json') $proposal
        if($kind-ceq'prerequisite'){
            $dependent=$draft|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$dependent.unit_id='u016';$dependent.prerequisites=@('u015')
            Write-EnvelopeJson (Join-Path $workspace 'iteration-units/u016.json') $dependent
        }
        if($kind-ceq'queued'){
            $state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$state.next_ready_unit='u015';Write-EnvelopeJson (Join-Path $workspace 'workspace.state.json') $state
            $bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.expected.state_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'workspace.state.json');$bad.expected.state_canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $state;Write-RetirementRequest $workspace $bad
        }
        if($kind-ceq'receipt-reference'){Write-EnvelopeJson (Join-Path $workspace 'receipts/u015-observation.json') ([ordered]@{unit_id='u015'})}
        if($kind-ceq'named-replacement'){$bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.replacement_unit_id='u015';Write-RetirementRequest $workspace $bad}
        Assert-RetirementRejects $workspace "non-inert $kind proposal"
    }
        if($InertProposalsOnly){[pscustomobject]@{status='pass';check='active-unit-retirement-inert-proposals';negative_cases=8;inert_draft_bytes_preserved=$true}|ConvertTo-Json -Compress;return}
    }

    $readonlySeed = $null
    if($runNestedPositive -or $runNestedCommitted -or $runAmendmentRecovery -or $runNestedRecovery -or $runNestedDamage){
        $readonlySeed=@(New-ReadonlyPlanningRetirementSeed (Join-Path $temp 'readonly-seed'))[-1]
    }
    if($runNestedCommitted){
        $continuation=@([pscustomobject]@{sequence=5;unit_id='u002';event_id='u002-envelope-recorded'},[pscustomobject]@{sequence=6;unit_id='u002';event_id='u002-tooling-01-tooling-context-upgraded'})
        &$retirementModule {param($events)Assert-ActiveRetirementPlanningContinuationEvents -Events $events -AfterSequence 4 -UnitId u002} $continuation
        foreach($bad in @([pscustomobject]@{sequence=7;unit_id='u002';event_id='u002-tooling-01-tooling-context-upgraded'},[pscustomobject]@{sequence=6;unit_id='other';event_id='u002-tooling-01-tooling-context-upgraded'},[pscustomobject]@{sequence=6;unit_id='u002';event_id='u002-unowned-transition'})){
            $message='';try{&$retirementModule {param($event)Assert-ActiveRetirementPlanningContinuationEvents -Events @($event) -AfterSequence 5 -UnitId u002} $bad}catch{$message=$_.Exception.Message}
            Assert-RetirementTest ($message-like'*same-unit authenticated transition suffix*') "unowned planning continuation shape was accepted: $message"
        }
        $committed=@(New-RetirementNestedPlanningProjection $readonlySeed $temp 'nested-committed')[-1]
        Invoke-EnvelopeGit $committed.repository @('add','-f','morphospace')|Out-Null
        Invoke-EnvelopeGit $committed.repository @('commit','-m','authenticated prepare admit ready claim')|Out-Null
        Assert-RetirementTest (@(Invoke-EnvelopeGit $committed.repository @('status','--porcelain=v1','--untracked-files=all')).Count-eq0) 'committed lifecycle fixture is dirty'
        $checkpoint=(@(Invoke-EnvelopeGit $committed.repository @('rev-parse','HEAD'))[0]).Trim()
        $unrelated=Join-Path $committed.repository 'unrelated.txt';[IO.File]::WriteAllText($unrelated,'unrelated')
        $message='';try{Invoke-NestedRetirement $committed u002 u003 '2026-08-25T00:00:43.0000000Z'|Out-Null}catch{$message=$_.Exception.Message}
        Assert-RetirementTest ($message-like'*clean available source*') "dirty committed descendant was accepted: $message"
        Remove-Item -LiteralPath $unrelated -Force
        [IO.File]::WriteAllText($unrelated,'staged');Invoke-EnvelopeGit $committed.repository @('add','unrelated.txt')|Out-Null
        $message='';try{Invoke-NestedRetirement $committed u002 u003 '2026-08-25T00:00:43.0000000Z'|Out-Null}catch{$message=$_.Exception.Message}
        Assert-RetirementTest ($message-like'*clean available source*') "staged committed descendant was accepted: $message"
        Invoke-EnvelopeGit $committed.repository @('reset','--','unrelated.txt')|Out-Null;Remove-Item -LiteralPath $unrelated -Force
        $dry=Invoke-NestedRetirement $committed u002 u003 '2026-08-25T00:00:43.0000000Z'
        Assert-RetirementTest (-not$dry.executed) 'clean authenticated committed planning descendant dry run failed'
        $done=Invoke-NestedRetirement $committed u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute
        Assert-RetirementTest ($done.executed-and(@(Invoke-EnvelopeGit $committed.repository @('rev-parse','HEAD'))[0]).Trim()-ceq$checkpoint) 'committed planning descendant retirement did not preserve HEAD'
        $arbitrary=@(New-RetirementNestedPlanningProjection $readonlySeed $temp 'nested-arbitrary')[-1]
        Invoke-EnvelopeGit $arbitrary.repository @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $arbitrary.repository @('commit','-m','authenticated prepare admit ready claim')|Out-Null
        $unrelated=Join-Path $arbitrary.repository 'unrelated.txt';[IO.File]::WriteAllText($unrelated,'unrelated');Invoke-EnvelopeGit $arbitrary.repository @('add','unrelated.txt')|Out-Null;Invoke-EnvelopeGit $arbitrary.repository @('commit','-m','unrelated descendant')|Out-Null
        $message='';try{Invoke-NestedRetirement $arbitrary u002 u003 '2026-08-25T00:00:43.0000000Z'|Out-Null}catch{$message=$_.Exception.Message}
        Assert-RetirementTest ($message-like'*unauthenticated path*') "arbitrary committed descendant was accepted: $message"
        Remove-Item -LiteralPath $unrelated -Force;Invoke-EnvelopeGit $arbitrary.repository @('add','-u','unrelated.txt')|Out-Null;Invoke-EnvelopeGit $arbitrary.repository @('commit','-m','revert unrelated descendant')|Out-Null
        $message='';try{Invoke-NestedRetirement $arbitrary u002 u003 '2026-08-25T00:00:43.0000000Z'|Out-Null}catch{$message=$_.Exception.Message}
        Assert-RetirementTest ($message-like'*unauthenticated path*') "reverted arbitrary committed descendant was accepted: $message"
    }
    if($runNestedPositive){
    # Direct and amended nested planning positives, exact replay, caller-module
    # retention, and the independent post-retirement continuation consumer.
    # The planning checkout remains at its preparation lock while the real owner
    # writers create the admitted lifecycle projection inside the nested workspace.
    $nested=@(New-RetirementNestedPlanningProjection $readonlySeed $temp 'nested-direct')[-1]
    $nestedHead=(@(Invoke-EnvelopeGit $nested.repository @('rev-parse','HEAD'))[0]).Trim()
    $nestedDry=Invoke-NestedRetirement $nested u002 u003 '2026-08-25T00:00:43.0000000Z'
    Assert-RetirementTest (-not$nestedDry.executed-and(@(Invoke-EnvelopeGit $nested.repository @('status','--porcelain=v1','--untracked-files=all')).Count-gt0)) 'nested read-only planning dry run did not preserve owner lifecycle dirt'
    Assert-RetirementCallerProtocol $nested.workspace 'nested read-only planning dry run'
    $nestedRun=Invoke-NestedRetirement $nested u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute
    Assert-RetirementTest ($nestedRun.executed-and(@(Invoke-EnvelopeGit $nested.repository @('rev-parse','HEAD'))[0]).Trim()-ceq$nestedHead) 'nested read-only planning retirement moved its locked HEAD'
    $nestedExternalRequest=Join-Path (Split-Path $nested.repository -Parent) "$([IO.Path]::GetFileName($nested.repository))-request.json"
    Assert-RetirementTest ((Get-EnvelopeFileSha256 (Join-Path $nested.workspace 'receipts/retire-u002-request.json'))-ceq(Get-EnvelopeFileSha256 $nestedExternalRequest)) 'retained external request bytes differ'
    Assert-RetirementCallerProtocol $nested.workspace 'nested read-only planning execute'
    $nestedReplay=Invoke-NestedRetirement $nested u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute
    Assert-RetirementTest ($nestedReplay.executed-and$null-eq$nestedReplay.current_unit_after) 'nested read-only planning replay did not return the committed retirement'
    Assert-RetirementCallerProtocol $nested.workspace 'nested read-only planning replay'
    $continuationSeed=@(New-ReadonlyPlanningRetirementSeed (Join-Path $temp 'amended-continuation-seed') -NestedReadOnlySource)[-1]
    $amended=@(Add-ReadonlyPlanningWriteScopeAmendment ([pscustomobject]@{repository=[string]$continuationSeed.source_repository;workspace=[string]$continuationSeed.workspace;map=Read-EnvelopeProtocolJson (Join-Path $continuationSeed.workspace 'repository-map.json');map_path=Join-Path $continuationSeed.workspace 'repository-map.json'}))[-1]
    $amendedHead=(@(Invoke-EnvelopeGit $amended.repository @('rev-parse','HEAD'))[0]).Trim();$amendedDry=Invoke-NestedRetirement $amended u002 u003 '2026-08-25T00:00:43.0000000Z'
    Assert-RetirementTest (-not$amendedDry.executed) 'amended nested planning dry run failed'
    $amendedRun=Invoke-NestedRetirement $amended u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute
    Assert-RetirementTest ($amendedRun.executed-and(@(Invoke-EnvelopeGit $amended.repository @('rev-parse','HEAD'))[0]).Trim()-ceq$amendedHead) 'amended nested planning retirement moved its locked HEAD'
    $amendedReplay=Invoke-NestedRetirement $amended u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute
    Assert-RetirementTest ($amendedReplay.executed-and$null-eq$amendedReplay.current_unit_after) 'amended nested planning exact retry did not return the committed retirement'
    Invoke-EnvelopeGit $amended.repository @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $amended.repository @('commit','-m','checkpoint amended active retirement')|Out-Null
    $transitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
    Test-ActiveRetirementContinuation -Workspace $amended.workspace -TestRoot (Join-Path $temp 'amended-continuation') -RepositoryRoot $repository -RetirementReceiptPath 'receipts/retire-u002.json'
    }

    if($runNestedMapGuards){
    # Nested materialization shape, duplicate backing root, traversal, reparse,
    # drive-relative path, request-CAS, and admission-map binding negatives.
    $nestedSourceSeed=@(New-ReadonlyPlanningRetirementSeed (Join-Path $temp 'nested-source-negative-seed') -NestedReadOnlySource)[-1]
    $nestedSourceProjection=[pscustomobject]@{repository=[string]$nestedSourceSeed.source_repository;workspace=[string]$nestedSourceSeed.workspace;map=Read-EnvelopeProtocolJson (Join-Path $nestedSourceSeed.workspace 'repository-map.json');map_path=Join-Path $nestedSourceSeed.workspace 'repository-map.json'}
    $retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -Force -PassThru;Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
    function Assert-NestedSourceMaterializationRejects([object]$Entry,[object]$Locked,[bool]$Writable,[Collections.Generic.HashSet[string]]$Roots,[string]$Label,[string]$Pattern){
        $rejected=$false;$message=''
        try{&$retirementModule {param($id,$entry,$locked,$writable,$roots)Get-ActiveRetirementRepositoryMaterialization -Id $id -Entry $entry -Locked $locked -Writable $writable -BackingRoots $roots} ([string]$Locked.repo_id) $Entry $Locked $Writable $Roots|Out-Null}catch{$rejected=$true;$message=$_.Exception.Message}
        Assert-RetirementTest ($rejected-and$message-like$Pattern) "$Label was accepted: $message"
    }
    $nestedMap=Read-EnvelopeProtocolJson $nestedSourceProjection.map_path;$nestedLock=Read-EnvelopeProtocolJson (Join-Path $nestedSourceProjection.workspace 'source-composition.json');$nestedEntry=@($nestedMap.repositories|Where-Object{[string]$_.repo_id-ceq'nested-read-only-source'})[0];$nestedLocked=@($nestedLock.repositories|Where-Object{[string]$_.repo_id-ceq'nested-read-only-source'})[0]
    Assert-NestedSourceMaterializationRejects $nestedEntry $nestedLocked $true ([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)) 'writable-nested-source' '*must map to its exact Git root*'
    $duplicateRoots=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$null=&$retirementModule {param($id,$entry,$locked,$roots)Get-ActiveRetirementRepositoryMaterialization -Id $id -Entry $entry -Locked $locked -Writable $false -BackingRoots $roots} 'nested-read-only-source' $nestedEntry $nestedLocked $duplicateRoots
    $duplicateEntry=Copy-Envelope $nestedEntry;$duplicateEntry.repo_id='duplicate-source';$duplicateLocked=Copy-Envelope $nestedLocked;$duplicateLocked.repo_id='duplicate-source'
    Assert-NestedSourceMaterializationRejects $duplicateEntry $duplicateLocked $false $duplicateRoots 'duplicate-backing-root' '*distinct authenticated backing Git repositories*'
    $traversalEntry=Copy-Envelope $nestedEntry;$traversalEntry.path=Join-Path (Split-Path ([string]$traversalEntry.path) -Parent) 'skills/../skills'
    Assert-NestedSourceMaterializationRejects $traversalEntry $nestedLocked $false ([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)) 'nested-source-traversal' '*not an exact absolute materialization*'
    if([OperatingSystem]::IsWindows()){$driveRelativeEntry=Copy-Envelope $nestedEntry;$driveRelativeEntry.path='S:skills';Assert-NestedSourceMaterializationRejects $driveRelativeEntry $nestedLocked $false ([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)) 'nested-source-drive-relative' '*not an exact absolute materialization*'}
    $alias=Join-Path $temp 'nested-source-junction';$aliasCreated=$false
    try{
        New-Item -ItemType Junction -Path $alias -Target ([string]@($nestedMap.repositories|Where-Object{[string]$_.repo_id-ceq'nested-read-only-source'})[0].path) -ErrorAction Stop|Out-Null;$aliasCreated=$true
        $aliasEntry=Copy-Envelope $nestedEntry;$aliasEntry.path=$alias
        Assert-NestedSourceMaterializationRejects $aliasEntry $nestedLocked $false ([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)) 'nested-source-reparse' '*Reparse-point ancestors are not accepted*'
    }catch{if(-not$aliasCreated){Write-Warning "Active retirement nested reparse negative skipped: $($_.Exception.Message)"}else{throw}}finally{if($aliasCreated){Remove-Item -LiteralPath $alias -Force}}
    $mapDriftSeed=@(New-ReadonlyPlanningRetirementSeed (Join-Path $temp 'nested-source-map-drift-seed') -NestedReadOnlySource)[-1];$mapDrift=[pscustomobject]@{repository=[string]$mapDriftSeed.source_repository;workspace=[string]$mapDriftSeed.workspace;map_path=Join-Path $mapDriftSeed.workspace 'repository-map.json'};$mapDriftRequest=New-ActiveUnitRetirementRequest -WorkspaceRoot $mapDrift.workspace -RepoMapPath $mapDrift.map_path;$mapDriftInput=Join-Path $temp 'nested-source-map-drift-request.json';Write-EnvelopeJson $mapDriftInput $mapDriftRequest
    $driftedMap=Read-EnvelopeProtocolJson $mapDrift.map_path;@($driftedMap.repositories|Where-Object{[string]$_.repo_id-ceq'nested-read-only-source'})[0].path=Split-Path ([string]@($driftedMap.repositories|Where-Object{[string]$_.repo_id-ceq'nested-read-only-source'})[0].path) -Parent;Write-EnvelopeJson $mapDrift.map_path $driftedMap
    $mapDriftBefore=Get-RetirementInventory $mapDrift.workspace
    $mapDriftRejected=$false;$mapDriftMessage=''
    try{Invoke-MorphospaceRetireActive -WorkspaceRoot $mapDrift.workspace -UnitId u002 -RepoMapPath $mapDrift.map_path -ActiveUnitRetirement $mapDriftInput -ExpectedActiveUnitRetirementSha256 (Get-EnvelopeFileSha256 $mapDriftInput) -OutPath (Join-Path $mapDrift.workspace 'receipts/retire-u002.json') -Timestamp '2026-08-25T00:00:43.0000000Z' -Execute|Out-Null}catch{$mapDriftMessage=$_.Exception.Message;$mapDriftRejected=$mapDriftMessage-like'*repository map bytes drifted*'-or$mapDriftMessage-like'*repository map is detached from its admission*'}
    Assert-RetirementTest $mapDriftRejected "nested source repository-map drift was not rejected at its authenticated binding: $mapDriftMessage"
    Assert-RetirementTest ((Get-RetirementInventory $mapDrift.workspace)-ceq$mapDriftBefore) 'nested source repository-map drift changed workspace bytes'
    $preRequestSwapRejected=$false;$preRequestSwapMessage=''
    try{New-ActiveUnitRetirementRequest -WorkspaceRoot $mapDrift.workspace -RepoMapPath $mapDrift.map_path|Out-Null}catch{$preRequestSwapMessage=$_.Exception.Message;$preRequestSwapRejected=$preRequestSwapMessage-like'*repository map is detached from its admission*'}
    Assert-RetirementTest $preRequestSwapRejected "fresh retirement request rebound a producer-detached repository map: $preRequestSwapMessage"
    Assert-RetirementTest ((Get-RetirementInventory $mapDrift.workspace)-ceq$mapDriftBefore) 'fresh retirement request changed workspace bytes after producer-detached map rejection'
    }

    if($runAmendmentRecovery){
    # Every amendment interruption boundary and every authenticated amendment
    # artifact, proof, unit, ownership, staging, and dirt negative.
    foreach($phase in @('after-intent','after-artifact','after-projection','after-event')){
        $case=@(Add-ReadonlyPlanningWriteScopeAmendment (New-RetirementNestedPlanningProjection $readonlySeed $temp "nested-amended-recovery-$phase") "amended-recovery-$phase")[-1];$interrupted=$false
        try{Invoke-NestedRetirement $case u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute -FaultAfter $phase|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption*'}
        Assert-RetirementTest $interrupted "amended nested planning recovery $phase did not interrupt"
        $recovered=Invoke-NestedRetirement $case u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute
        Assert-RetirementTest ($recovered.executed-and$null-eq(Read-EnvelopeProtocolJson (Join-Path $case.workspace 'workspace.state.json')).current_unit) "amended nested planning recovery $phase did not complete"
    }
    foreach($damage in @('amended-unit','amendment-artifact-missing','amendment-artifact-damaged','amendment-proof','amendment-wrong-unit','amendment-incomplete','amendment-outside','amendment-staged')){
        $amendmentId="${damage}-scope";$case=@(Add-ReadonlyPlanningWriteScopeAmendment (New-RetirementNestedPlanningProjection $readonlySeed $temp "nested-$damage") $amendmentId)[-1];$eventPath=Join-Path $case.workspace 'iteration-events.jsonl';$receiptPath=Join-Path $case.workspace "receipts/$amendmentId.json";$completionPath=Join-Path $case.workspace "receipts/transactions/$amendmentId-recorded-transition.completion.json"
        switch($damage){
            'amended-unit' {$unitPath=Join-Path $case.workspace 'iteration-units/u002.json';[IO.File]::AppendAllText($unitPath,' ')}
            'amendment-artifact-missing' {Remove-Item -LiteralPath $receiptPath -Force}
            'amendment-artifact-damaged' {[IO.File]::AppendAllText($receiptPath,' ')}
            'amendment-proof' {$receipt=Read-EnvelopeProtocolJson $receiptPath;$receipt.ownership_proof.tracked_paths=@($receipt.before_allowed_paths);Write-EnvelopeJson $receiptPath $receipt;$intentPath=Join-Path $case.workspace "receipts/transactions/$amendmentId-recorded-transition.intent.json";$intent=Read-EnvelopeProtocolJson $intentPath;$artifactBytes=[IO.File]::ReadAllBytes($receiptPath);$intent.artifacts[0].bytes_base64=[Convert]::ToBase64String($artifactBytes);$intent.artifacts[0].sha256=Get-EnvelopeFileSha256 $receiptPath;Write-EnvelopeJson $intentPath $intent;$completion=Read-EnvelopeProtocolJson $completionPath;$completion.intent.sha256=Get-EnvelopeFileSha256 $intentPath;Write-EnvelopeJson $completionPath $completion}
            'amendment-wrong-unit' {$lines=[Collections.Generic.List[string]]@(Get-Content $eventPath);$event=$lines[-1]|ConvertFrom-Json -DateKind String;$event.unit_id='u009';$lines[-1]=$event|ConvertTo-Json -Compress -Depth 32;[IO.File]::WriteAllText($eventPath,($lines-join"`n")+"`n",[Text.UTF8Encoding]::new($false))}
            'amendment-incomplete' {Remove-Item -LiteralPath $completionPath -Force}
            'amendment-outside' {[IO.File]::WriteAllText((Join-Path $case.repository 'outside-amendment.txt'),'outside')}
            'amendment-staged' {Invoke-EnvelopeGit $case.repository @('add',([IO.Path]::GetRelativePath($case.repository,$receiptPath)))|Out-Null}
        }
        $rejected=$false;try{Invoke-NestedRetirement $case u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute|Out-Null}catch{$rejected=$true};Assert-RetirementTest $rejected "$damage was accepted"
    }
    }

    if($runNestedRecovery){
    # Every ordinary nested retirement interruption boundary, in-place unowned
    # dirt rejection, and the authenticated RetireProposed replacement suffix.
    foreach($phase in @('after-intent','after-artifact','after-projection','after-event')){
        $recoveryCase=@(New-RetirementNestedPlanningProjection $readonlySeed $temp "nested-recovery-$phase")[-1];$interrupted=$false
        try{Invoke-NestedRetirement $recoveryCase u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute -FaultAfter $phase|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption*'}
        Assert-RetirementTest $interrupted "nested planning recovery $phase did not interrupt"
        if($phase-ceq'after-projection'){
            $unowned=Join-Path $recoveryCase.repository 'unowned-recovery.txt';[IO.File]::WriteAllText($unowned,'unowned')
            try{
                $before=Get-RetirementInventory $recoveryCase.workspace;$rejected=$false;$message=''
                try{Invoke-NestedRetirement $recoveryCase u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute|Out-Null}catch{$message=$_.Exception.Message;$rejected=$message-like'*clean available source*'-or$message-like'*planning repository dirt differs from the authenticated lifecycle projection*'}
                Assert-RetirementTest $rejected "in-place recovery accepted unrelated planning dirt: $message"
                Assert-RetirementTest ((Get-RetirementInventory $recoveryCase.workspace)-ceq$before) 'in-place recovery rejection changed workspace bytes'
            }finally{[IO.File]::Delete($unowned)}
        }
        $recovered=Invoke-NestedRetirement $recoveryCase u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute
        Assert-RetirementTest ($recovered.executed-and$null-eq(Read-EnvelopeProtocolJson (Join-Path $recoveryCase.workspace 'workspace.state.json')).current_unit) "nested planning recovery $phase did not complete"
    }
    $replacementSeed=@(New-ReadonlyPlanningRetirementSeed (Join-Path $temp 'replacement-seed') -Replacement)[-1]
    $replacementProjection=@(New-RetirementNestedPlanningProjection $replacementSeed $temp 'nested-replacement')[-1];$replacementInterrupted=$false;try{Invoke-NestedRetirement $replacementProjection u003 u004 '2026-08-25T00:00:45.0000000Z' -Execute -FaultAfter after-projection|Out-Null}catch{$replacementInterrupted=$_.Exception.Message-like'*Injected interruption*'};Assert-RetirementTest $replacementInterrupted 'replacement nested planning recovery did not interrupt';$replacementRun=Invoke-NestedRetirement $replacementProjection u003 u004 '2026-08-25T00:00:45.0000000Z' -Execute
    Assert-RetirementTest ($replacementRun.executed-and$null-eq(Read-EnvelopeProtocolJson (Join-Path $replacementProjection.workspace 'workspace.state.json')).current_unit) 'authenticated RetireProposed replacement suffix did not retire'
    }

    if($runNestedDamage){
    # Nested planning source, lifecycle artifact, role, writable-scope, pending
    # artifact, backing-HEAD, staging, and outside-workspace damage negatives.
    foreach($damage in @('extra','staged','artifact','preparation-receipt','intent','completion','outside','head','role','writable','pending')){
        $case=@(New-RetirementNestedPlanningProjection $readonlySeed $temp "nested-$damage")[-1]
        switch($damage){
            'extra' {[IO.File]::WriteAllText((Join-Path $case.workspace 'extra.txt'),'extra')}
            'staged' {Invoke-EnvelopeGit $case.repository @('add','morphospace/workspace.state.json')|Out-Null}
            'artifact' {[IO.File]::AppendAllText((Join-Path $case.workspace 'receipts/u002-admission.json'),' ')}
            'preparation-receipt' {[IO.File]::AppendAllText((Join-Path $case.workspace 'receipts/u002-envelope.json'),' ')}
            'intent' {[IO.File]::AppendAllText((Join-Path $case.workspace 'receipts/transactions/u002-claimed-0005-transition.intent.json'),' ')}
            'completion' {[IO.File]::AppendAllText((Join-Path $case.workspace 'receipts/transactions/u002-claimed-0005-transition.completion.json'),' ')}
            'outside' {[IO.File]::WriteAllText((Join-Path $case.repository 'outside.txt'),'outside')}
            'head' {[IO.File]::WriteAllText((Join-Path $case.repository 'head.txt'),'head');Invoke-EnvelopeGit $case.repository @('add','head.txt')|Out-Null;Invoke-EnvelopeGit $case.repository @('config','user.name','Retirement Fixture')|Out-Null;Invoke-EnvelopeGit $case.repository @('config','user.email','fixture@example.invalid')|Out-Null;Invoke-EnvelopeGit $case.repository @('commit','-m','move-head')|Out-Null}
            'role' {@($case.map.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0].role='source';Write-EnvelopeJson $case.map_path $case.map}
            'writable' {$unitPath=Join-Path $case.workspace 'iteration-units/u002.json';$unit=Read-EnvelopeProtocolJson $unitPath;$unit.allowed_repositories+=,[pscustomobject]@{repo_id='project-shell';allowed_paths=@('morphospace/')};Write-EnvelopeJson $unitPath $unit}
            'pending' {[IO.File]::WriteAllText((Join-Path $case.workspace 'receipts/transactions/u002-admission-admitted-transition.artifact-0.pending'),'orphan')}
        }
        $rejected=$false;try{Invoke-NestedRetirement $case u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute|Out-Null}catch{$rejected=$true}
        Assert-RetirementTest $rejected "nested planning $damage damage was accepted"
    }
    }

    if($runCore){
    # Ordinary dry run, execute, replay, fault recovery, CAS, queue/publication
    # conflicts, historical proof, preservation, and source-dirt rejection.
    $protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
    $success=Copy-RetirementWorkspace 'success';$before=Get-RetirementInventory $success
    $dry=Invoke-RetirementTest $success $false
    Assert-RetirementTest (-not$dry.executed-and$dry.current_unit_after-ceq'u002') 'dry observation grants no idle ownership'
    Assert-RetirementTest ((Get-RetirementInventory $success)-ceq$before) 'dry observation wrote files'
    $preserved=@{};foreach($file in @(Get-ChildItem -LiteralPath $success -Recurse -File)){$relative=[IO.Path]::GetRelativePath($success,$file.FullName).Replace('\','/');$preserved[$relative]=[IO.File]::ReadAllBytes($file.FullName)}
    $done=Invoke-RetirementTest $success
    Assert-RetirementTest ($done.executed-and$null-eq$done.current_unit_after-and$done.status_after-ceq'active') 'nonaccepting active-to-idle result'
    $state=Read-EnvelopeProtocolJson (Join-Path $success 'workspace.state.json')
    Assert-RetirementTest ($null-eq$state.current_unit-and$state.last_event_id-ceq'retire-u002-active-retired') 'idle target'
    foreach($relative in $preserved.Keys){
        $bytes=[IO.File]::ReadAllBytes((Join-Path $success $relative))
        if($relative-ceq'workspace.state.json'){continue}
        if($relative-ceq'iteration-events.jsonl'){$prefix=[byte[]]::new($preserved[$relative].Length);[Array]::Copy($bytes,$prefix,$prefix.Length);$bytes=$prefix}
        Assert-RetirementTest ((Get-RetirementBytesSha256 $bytes)-ceq(Get-RetirementBytesSha256 $preserved[$relative])) "preserved $relative"
    }
    $event=Get-Content -LiteralPath (Join-Path $success 'iteration-events.jsonl')|Select-Object -Last 1|ConvertFrom-Json -DateKind String
    $proof=&$retirementModule {param($workspace,$expected)Test-MorphospaceHistoricalActiveUnitRetirement -WorkspaceRoot $workspace -ExpectedEvent $expected} $success $event
    Assert-RetirementTest ($proof.receipt.replacement_unit_id-ceq'u003'-and-not$proof.receipt.accepted) 'authenticated named replacement lineage'
    $post=Get-RetirementInventory $success;Invoke-RetirementTest $success|Out-Null
    Assert-RetirementTest ((Get-RetirementInventory $success)-ceq$post) 'completed replay changed bytes'
    foreach($phase in @('after-intent','after-artifact','after-projection','after-event')){
        $workspace=Copy-RetirementWorkspace "fault-$phase";$interrupted=$false
        try{Invoke-RetirementTest $workspace $true $phase|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption*'}
        Assert-RetirementTest $interrupted "fault $phase not reached"
        Invoke-RetirementTest $workspace|Out-Null
        Assert-RetirementTest ($null-eq(Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')).current_unit) "fault $phase did not resume"
    }
    foreach($field in @('project_raw_sha256','feature_lock_raw_sha256','state_raw_sha256','events_sha256','repository_map_sha256')){
        $workspace=Copy-RetirementWorkspace "bad-$field";$bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.expected.$field='0'*64;Write-RetirementRequest $workspace $bad
        Assert-RetirementRejects $workspace $field
    }
    $workspace=Copy-RetirementWorkspace 'same-replacement';$bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.replacement_unit_id='u002';Write-RetirementRequest $workspace $bad;Assert-RetirementRejects $workspace 'same replacement'
    $workspace=Copy-RetirementWorkspace 'occupied-replacement';Copy-Item -LiteralPath (Join-Path $workspace 'iteration-units/u002.json') -Destination (Join-Path $workspace 'iteration-units/u003.json');Assert-RetirementRejects $workspace 'occupied replacement'
    foreach($field in @('next_ready_unit','pending_push_bundle','normal_validation_selection')){
        $workspace=Copy-RetirementWorkspace "conflict-$field";$state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')
        $value=if($field-ceq'next_ready_unit'){'u099'}elseif($field-ceq'pending_push_bundle'){[pscustomobject]@{bundle_id='pending';unit_ids=@('u002');repo_ids=@('fixture-source');ready=$true}}else{[pscustomobject]@{selector_id='pending'}}
        $state|Add-Member -NotePropertyName $field -NotePropertyValue $value -Force;Write-EnvelopeJson (Join-Path $workspace 'workspace.state.json') $state
        $bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.expected.state_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'workspace.state.json');$bad.expected.state_canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $state;Write-RetirementRequest $workspace $bad
        Assert-RetirementRejects $workspace $field
    }
    $workspace=Copy-RetirementWorkspace 'claim-damage';$path=Join-Path $workspace "receipts/transactions/$($request.claim.transaction_id).completion.json";[IO.File]::AppendAllText($path,' ');Assert-RetirementRejects $workspace 'Claim completion raw drift'
    $workspace=Copy-RetirementWorkspace 'intent-damage';try{Invoke-RetirementTest $workspace $true 'after-intent'|Out-Null}catch{}
    $intentPath=Join-Path $workspace 'receipts/transactions/retire-u002-active-retired-transition.intent.json';$intent=Read-EnvelopeProtocolJson $intentPath;$intent.target.state.document.plan_revision++;Write-EnvelopeJson $intentPath $intent
    Assert-RetirementRejects $workspace 'interrupted target damage'
    $workspace=Copy-RetirementWorkspace 'raw-unit-damage';[IO.File]::AppendAllText((Join-Path $workspace 'iteration-units/u002.json'),' ');Assert-RetirementRejects $workspace 'active raw unit drift'
    $sourceMap=Read-EnvelopeProtocolJson (Join-Path $template 'repository-map.json');$sourcePath=[string]@($sourceMap.repositories|Where-Object{[string]$_.repo_id-ceq[string]$request.repositories[0].repo_id})[0].path
    $dirtyPath=Join-Path $sourcePath 'unowned-retirement-test.txt';[IO.File]::WriteAllText($dirtyPath,'unowned')
    try{$workspace=Copy-RetirementWorkspace 'dirty-source';Assert-RetirementRejects $workspace 'untracked source dirt' '*clean available source*'}finally{[IO.File]::Delete($dirtyPath)}
    }
    if($Scenario-cin@('All','PlanningProjection')){
        $shadowScript=Join-Path $temp 'planning-caller-shadow.ps1'
        [IO.File]::WriteAllText($shadowScript,@'
param([string]$ModulePath)
$ErrorActionPreference='Stop'
function global:Read-MorphospaceProtocolJson {'unrelated-protocol-shadow'}
function global:Test-MorphospaceCommittedTransitionLedger {'unrelated-ledger-shadow'}
Import-Module $ModulePath
$rejected=$false
try{Assert-MorphospaceReadOnlyPlanningLifecycleProjection -Workspace $PSScriptRoot -Unit ([pscustomobject]@{unit_id='u002'}) -RepositoryEntry ([pscustomobject]@{role='source';path=$PSScriptRoot}) -Dependency ([pscustomobject]@{paths=@('README.md')}) -LockedCommit ('0'*40) -LockedTree ('0'*40)}catch{$rejected=$true}
if(-not$rejected-or(Read-MorphospaceProtocolJson)-cne'unrelated-protocol-shadow'-or(Test-MorphospaceCommittedTransitionLedger)-cne'unrelated-ledger-shadow'){throw 'Planning projection replaced unrelated caller command authority.'}
'planning caller shadows preserved'
'@,[Text.UTF8Encoding]::new($false))
        $shadowResult=&pwsh -NoProfile -File $shadowScript -ModulePath (Join-Path $PSScriptRoot 'lib/MorphospacePlanningLifecycleProjection.psm1')
        Assert-RetirementTest ($LASTEXITCODE-eq0-and$shadowResult-ccontains'planning caller shadows preserved') 'planning projection overwrote unrelated caller commands'
        Import-Module (Join-Path $PSScriptRoot 'lib/MorphospacePlanningLifecycleProjection.psm1')
        $projectionExtensionModule=Import-Module (Join-Path $PSScriptRoot 'ActiveDevelopmentEnvelopeExtension.psm1') -PassThru
        $projectionFreezeModule=Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -PassThru
        $projectionSeed=@(New-ReadonlyPlanningRetirementSeed (Join-Path $temp 'immutable-planning-seed') -ImmutableReadOnlyPaths)[-1]
        $projection=@(New-RetirementNestedPlanningProjection $projectionSeed $temp 'immutable-planning')[-1]
        $planning=$projection.repository;$workspace=$projection.workspace
        [IO.File]::AppendAllText((Join-Path $planning '.git/info/exclude'),"`nmorphospace/local/`n",[Text.UTF8Encoding]::new($false))
        $namedOutputs=@{};foreach($name in @('ordinary-reviewed-ready.json','ordinary-claimed-owner.json')){$path=Join-Path $workspace "receipts/$name";$namedOutputs[$path]=[IO.File]::ReadAllBytes($path);[IO.File]::Delete($path)}
        Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','authenticated owner Prepare Admit Ready Claim')|Out-Null
        foreach($path in $namedOutputs.Keys){[IO.File]::WriteAllBytes($path,$namedOutputs[$path])};Invoke-EnvelopeGit $planning @('add','morphospace/receipts')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','ordinary post-action owner byproducts')|Out-Null
        $unit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json');$source=Read-EnvelopeProtocolJson (Join-Path $workspace 'source-composition.json')
        $entry=@($projection.map.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0];$pin=@($source.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0]
        $arguments=@{Workspace=$workspace;Unit=$unit;RepositoryEntry=$entry;Dependency=$unit.read_only_dependencies[0];LockedCommit=[string]$pin.commit;LockedTree=[string]$pin.tree}
        Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments
        $checkpoint=(@(Invoke-EnvelopeGit $planning @('rev-parse','HEAD'))[0]).Trim()
        function Assert-PlanningProjectionRejects([scriptblock]$Action,[string]$Label){$before=Get-RetirementInventory $workspace;$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Assert-RetirementTest $failed "planning projection accepted $Label";Assert-RetirementTest ((Get-RetirementInventory $workspace)-ceq$before) "planning projection mutated bytes for $Label"}
        $ordinaryClaimPath=Join-Path $workspace 'receipts/ordinary-claimed-owner.json';$ordinaryClaimBytes=[IO.File]::ReadAllBytes($ordinaryClaimPath)
        foreach($damage in @('action','event','timestamp','status','selector','executed','adoption-binding','duplicate','outside-namespace','reserved-namespace')){
            $extraPath=$null
            if($damage-in@('duplicate','outside-namespace','reserved-namespace')){$extraPath=Join-Path $workspace $(if($damage-ceq'duplicate'){'receipts/copied-claim.json'}elseif($damage-ceq'reserved-namespace'){'receipts/transactions/unbound-owner-output.json'}else{'unbound-claim-output.json'});[IO.File]::WriteAllBytes($extraPath,$ordinaryClaimBytes)}else{
                $damaged=Read-EnvelopeProtocolJson $ordinaryClaimPath
                switch($damage){'action'{$damaged.action='Ready'}'event'{$damaged.event_id='u002-ready-0004'}'timestamp'{$damaged.timestamp='2026-08-25T00:00:41.0000000Z'}'status'{$damaged.status_before='proposed'}'selector'{$damaged.current_unit_after=$null}'executed'{$damaged.executed=$false}'adoption-binding'{$damaged.adoption_receipt='receipts/unbound-adoption.json'}}
                Write-EnvelopeJson $ordinaryClaimPath $damaged
            }
            try{
                Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m',"damaged derived output $damage")|Out-Null
                Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments} "ordinary output $damage"
            }finally{Invoke-EnvelopeGit $planning @('reset','--hard',$checkpoint)|Out-Null}
        }
        $changedOutput=Read-EnvelopeProtocolJson $ordinaryClaimPath;$changedOutput.preservation.repository_states[0] | Add-Member -NotePropertyName branch -NotePropertyValue 'changed informational observation' -Force;Write-EnvelopeJson $ordinaryClaimPath $changedOutput
        Invoke-EnvelopeGit $planning @('add','morphospace/receipts/ordinary-claimed-owner.json')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','changed derived output observation')|Out-Null
        Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments} 'changed committed derived output bytes'
        [IO.File]::WriteAllBytes($ordinaryClaimPath,$ordinaryClaimBytes);Invoke-EnvelopeGit $planning @('add','morphospace/receipts/ordinary-claimed-owner.json')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','reverted derived output observation')|Out-Null
        Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments} 'changed and reverted committed derived output bytes'
        Invoke-EnvelopeGit $planning @('reset','--hard',$checkpoint)|Out-Null
        [IO.File]::Delete($ordinaryClaimPath);Invoke-EnvelopeGit $planning @('add','-u','morphospace/receipts/ordinary-claimed-owner.json')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','deleted derived output')|Out-Null
        [IO.File]::WriteAllBytes($ordinaryClaimPath,$ordinaryClaimBytes);Invoke-EnvelopeGit $planning @('add','morphospace/receipts/ordinary-claimed-owner.json')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','restored derived output')|Out-Null
        Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments} 'deleted and restored committed derived output'
        Invoke-EnvelopeGit $planning @('reset','--hard',$checkpoint)|Out-Null
        $claimIntentPath=@(Get-ChildItem (Join-Path $workspace 'receipts/transactions') -Filter 'u002-claimed-*.intent.json' -File)[0].FullName;$claimCompletionPath=$claimIntentPath.Replace('.intent.json','.completion.json')
        $claimIntentBytes=[IO.File]::ReadAllBytes($claimIntentPath);$claimCompletionBytes=[IO.File]::ReadAllBytes($claimCompletionPath)
        $changedProof=Read-EnvelopeProtocolJson $claimIntentPath;$changedProof.created_at='2026-08-25T00:00:00.0000000Z';Write-EnvelopeJson $claimIntentPath $changedProof;$changedCompletion=Read-EnvelopeProtocolJson $claimCompletionPath;$changedCompletion.intent.sha256=Get-EnvelopeFileSha256 $claimIntentPath;Write-EnvelopeJson $claimCompletionPath $changedCompletion
        Invoke-EnvelopeGit $planning @('add','morphospace/receipts/transactions')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','changed linked byproduct transaction')|Out-Null
        Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments} 'changed linked transaction while ordinary output is unchanged'
        [IO.File]::WriteAllBytes($claimIntentPath,$claimIntentBytes);[IO.File]::WriteAllBytes($claimCompletionPath,$claimCompletionBytes);Invoke-EnvelopeGit $planning @('add','morphospace/receipts/transactions')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','reverted linked byproduct transaction')|Out-Null
        Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments} 'changed and reverted linked transaction while ordinary output is unchanged'
        Invoke-EnvelopeGit $planning @('reset','--hard',$checkpoint)|Out-Null
        $projectionProofModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospacePlanningLifecycleProjection.psm1') -PassThru
        $projectionAdmission=@(Get-ChildItem (Join-Path $workspace 'receipts') -File -Filter '*.json'|ForEach-Object{Read-EnvelopeProtocolJson $_.FullName}|Where-Object{[string]$_.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$_.unit_id-ceq'u002'})[0]
        foreach($slug in @('ready','claimed')){
            $transitionFile=@(Get-ChildItem (Join-Path $workspace 'receipts/transactions') -File -Filter "u002-$slug-*.intent.json")[0]
            $completionFile=$transitionFile.FullName.Replace('.intent.json','.completion.json');$originalIntent=[IO.File]::ReadAllBytes($transitionFile.FullName);$originalCompletion=[IO.File]::ReadAllBytes($completionFile)
            foreach($damage in @('pre-unit','pre-state','target-authority')){
                $detached=Read-EnvelopeProtocolJson $transitionFile.FullName;$completion=Read-EnvelopeProtocolJson $completionFile
                if($damage-ceq'pre-unit'){$detached.pre.unit.sha256='0'*64;$detached.expected.unit_sha256=$detached.pre.unit.sha256}elseif($damage-ceq'pre-state'){$detached.pre.state.sha256='0'*64;$detached.expected.state_sha256=$detached.pre.state.sha256}else{$detached.target.unit.document.objective+=' unreviewed expansion';$detached.target.unit.sha256=Get-EnvelopeCanonicalJsonSha256 $detached.target.unit.document;$completion.unit_sha256=$detached.target.unit.sha256}
                Write-EnvelopeJson $transitionFile.FullName $detached;$completion.intent.sha256=Get-EnvelopeFileSha256 $transitionFile.FullName;Write-EnvelopeJson $completionFile $completion
                try{
                    $before=Get-RetirementInventory $workspace
                    $rejected=&$projectionProofModule {param($root,$unit,$entry,$admission,$transaction)
                        # Prove this is a self-consistent generic transaction, then
                        # require the independent owner projection to reject it.
                        $null=Get-MorphospacePlanningLifecycleTransition $root $transaction -HistoricalProjection
                        try{$null=Test-MorphospacePlanningLifecycleProjectionFromAuthenticatedAdmission -Workspace $root -Unit $unit -RepositoryEntry $entry -StatusPorcelain @() -Admission $admission -HistoricalOnly;return $false}catch{return $true}
                    } $workspace $unit $entry $projectionAdmission $detached.transaction_id
                    Assert-RetirementTest $rejected "planning projection accepted detached $slug $damage"
                    Assert-RetirementTest ((Get-RetirementInventory $workspace)-ceq$before) "planning projection wrote during detached $slug $damage rejection"
                }finally{[IO.File]::WriteAllBytes($transitionFile.FullName,$originalIntent);[IO.File]::WriteAllBytes($completionFile,$originalCompletion)}
            }
        }
        $additionalPaths=Copy-Envelope $arguments.Dependency;$additionalPaths.paths=@($additionalPaths.paths)+@('morphospace/local/new-readonly.json')
        $additionalArguments=@{};foreach($key in $arguments.Keys){$additionalArguments[$key]=$arguments[$key]};$additionalArguments.Dependency=$additionalPaths
        Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @additionalArguments} 'unauthenticated dependency path addition beyond terminal owner prefix'
        $externalPlanning=Join-Path $temp 'external-exact-planning';Invoke-EnvelopeGit $temp @('clone','--no-hardlinks',$planning,$externalPlanning)|Out-Null;Invoke-EnvelopeGit $externalPlanning @('reset','--hard',[string]$pin.commit)|Out-Null
        $externalEntry=Copy-Envelope $entry;$externalEntry.path=$externalPlanning
        $externalSource=[pscustomobject]@{unit_id='u002';repositories=@([pscustomobject]@{repo_id='project-shell';role='planning';effective_commit=[string]$pin.commit;effective_tree=[string]$pin.tree})}
        $externalMap=[pscustomobject]@{repositories=@($externalEntry)};$externalEndpoint=[pscustomobject]@{allowed_repositories=@();read_only_dependencies=@($arguments.Dependency)}
        $externalChecks=&$projectionExtensionModule {
            param($source,$map,$endpoint,$workspace,$external)
            Assert-ActiveEnvelopeCapturedSourceObservation $source $map $endpoint -WorkspaceRoot $workspace
            [IO.File]::WriteAllText((Join-Path $external 'unrelated-external.txt'),'unrelated external history');&git -C $external add unrelated-external.txt|Out-Null;&git -C $external -c user.name=Fixture -c user.email=fixture@example.invalid commit -m 'unrelated external drift'|Out-Null
            $rejected=$false;try{Assert-ActiveEnvelopeCapturedSourceObservation $source $map $endpoint -WorkspaceRoot $workspace}catch{$rejected=$true};return $rejected
        } $externalSource $externalMap $externalEndpoint $workspace $externalPlanning
        Assert-RetirementTest $externalChecks 'external unchanged planning fast path accepted nonnested drift'
        foreach($path in @('unrelated.txt','morphospace/README.md')){
            $absolute=Join-Path $planning $path;$existed=[IO.File]::Exists($absolute);$old=if($existed){[IO.File]::ReadAllBytes($absolute)}else{$null}
            [IO.File]::WriteAllText($absolute,'foreign committed bytes',[Text.UTF8Encoding]::new($false));Invoke-EnvelopeGit $planning @('add','-f','--',$path)|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','foreign intermediate path')|Out-Null
            if($existed){[IO.File]::WriteAllBytes($absolute,$old)}else{[IO.File]::Delete($absolute)}
            Invoke-EnvelopeGit $planning @('add','-u','--',$path)|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','revert foreign intermediate path')|Out-Null
            Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments} "reverted $path"
            Invoke-EnvelopeGit $planning @('reset','--hard',$checkpoint)|Out-Null
        }
        foreach($damage in @('role','nonnested','pin','map','readonly','preparation-semantic')){
            $caseArguments=$arguments.Clone();$restorePath=$null;$restoreBytes=$null
            switch($damage){
                'role' {$caseArguments.RepositoryEntry=Copy-Envelope $entry;$caseArguments.RepositoryEntry.role='source'}
                'nonnested' {$caseArguments.Workspace=Split-Path $planning -Parent}
                'pin' {$caseArguments.LockedCommit=$checkpoint;$caseArguments.LockedTree=(@(Invoke-EnvelopeGit $planning @('rev-parse',"$checkpoint^{tree}"))[0]).Trim()}
                'map' {$caseArguments.RepositoryEntry=Copy-Envelope $entry;$caseArguments.RepositoryEntry.repo_id='foreign-owner'}
                'readonly' {$restorePath=Join-Path $planning 'morphospace/README.md';$restoreBytes=[IO.File]::ReadAllBytes($restorePath);[IO.File]::WriteAllText($restorePath,'damaged readonly')}
                'preparation-semantic' {
                    $restorePath=Join-Path $workspace 'receipts/transactions/u002-envelope-prepared-transition.intent.json';$restoreBytes=[IO.File]::ReadAllBytes($restorePath)
                    $completionPath=Join-Path $workspace 'receipts/transactions/u002-envelope-prepared-transition.completion.json';$completionBytes=[IO.File]::ReadAllBytes($completionPath)
                    $intent=Read-EnvelopeProtocolJson $restorePath;$intent.target.project.path='unrelated-owner.json';Write-EnvelopeJson $restorePath $intent
                    $completion=Read-EnvelopeProtocolJson $completionPath;$completion.intent_sha256=Get-EnvelopeFileSha256 $restorePath;Write-EnvelopeJson $completionPath $completion
                }
            }
            try{Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @caseArguments} $damage}finally{if($restorePath){[IO.File]::WriteAllBytes($restorePath,$restoreBytes)};if($damage-ceq'preparation-semantic'){[IO.File]::WriteAllBytes($completionPath,$completionBytes)}}
        }
        $dependency=Join-Path $temp 'projection-dependency';[IO.Directory]::CreateDirectory((Join-Path $dependency 'dep'))|Out-Null
        Invoke-EnvelopeGit $temp @('init',$dependency)|Out-Null;Invoke-EnvelopeGit $dependency @('config','user.name','Projection Fixture')|Out-Null;Invoke-EnvelopeGit $dependency @('config','user.email','fixture@example.invalid')|Out-Null
        [IO.File]::WriteAllText((Join-Path $dependency 'dep/api.txt'),'independent dependency');Invoke-EnvelopeGit $dependency @('add','dep')|Out-Null;Invoke-EnvelopeGit $dependency @('commit','-m','dependency baseline')|Out-Null
        $requestInfo=New-PlanningProjectionExtensionRequest $workspace $dependency (Join-Path $temp 'projection-extension.json') -AddPlanningReadOnlyPath 'morphospace/readonly-extra.txt'
        foreach($field in @('source_composition_path','source_composition_raw_sha256','source_composition_canonical_sha256','original_source_composition_path','original_source_composition_raw_sha256')){
            $detachedRequest=Copy-Envelope $requestInfo.request;$detachedRequest.expected.$field=if($field.EndsWith('_path')){'source-composition-locks/unbound.json'}else{'0'*64}
            $detachedPath=Join-Path $temp "pending-source-$field.json";Write-EnvelopeJson $detachedPath $detachedRequest
            Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments -CapturedExpected $detachedRequest.expected -PendingExtensionPath $detachedPath -ExpectedPendingExtensionSha256 (Get-EnvelopeFileSha256 $detachedPath)} "pending request $field"
        }
        $extensionArguments=@{WorkspaceRoot=$workspace;UnitId='u002';RepositoryMapPath=$requestInfo.map_path;SourceCompositionOutPath=$requestInfo.source_path;ActiveDevelopmentEnvelopeExtension=$requestInfo.request_path;ExpectedActiveDevelopmentEnvelopeExtensionSha256=(Get-EnvelopeFileSha256 $requestInfo.request_path);OutPath=$requestInfo.receipt_path;Timestamp='2026-09-15T01:00:00.0000000Z'}
        $missingPathRequest=Copy-Envelope $requestInfo.request;@($missingPathRequest.target.read_only_dependencies|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0].paths+=,'morphospace/absent-at-original-pin.txt'
        $missingRequestPath=Join-Path $temp 'projection-missing-readonly-path.json';Write-EnvelopeJson $missingRequestPath $missingPathRequest
        $missingArguments=$extensionArguments.Clone();$missingArguments.ActiveDevelopmentEnvelopeExtension=$missingRequestPath;$missingArguments.ExpectedActiveDevelopmentEnvelopeExtensionSha256=Get-EnvelopeFileSha256 $missingRequestPath
        Assert-PlanningProjectionRejects {Invoke-MorphospaceExtendActiveDevelopmentEnvelope @missingArguments} 'new readonly path absent from original source pin'
        $before=Get-RetirementInventory $workspace;$dry=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @extensionArguments
        Assert-RetirementTest (-not$dry.executed-and(Get-RetirementInventory $workspace)-ceq$before) 'planning extension dryrun changed bytes'
        $interrupted=$false;try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope @extensionArguments -Execute -FaultAfter after-intent|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption*'}
        Assert-RetirementTest $interrupted 'planning extension did not reach its recovery boundary'
        $pendingIntentPath=Join-Path $workspace 'receipts/transactions/u002-add-dependency-recorded-transition.intent.json'
        $pendingIntentBytes=[IO.File]::ReadAllBytes($pendingIntentPath)
        foreach($damage in @('target-unit','predecessor-unit','predecessor-state')){
            $damaged=Read-EnvelopeProtocolJson $pendingIntentPath
            if($damage-ceq'target-unit'){$damaged.target.unit.document.unit_id='u099';$damaged.target.unit.sha256=Get-EnvelopeCanonicalJsonSha256 $damaged.target.unit.document}elseif($damage-ceq'predecessor-unit'){$damaged.pre.unit.sha256='0'*64}else{$damaged.pre.state.sha256='0'*64}
            $damageBytes=&$protocolModule {param($value)ConvertTo-MorphospaceProtocolJsonBytes $value} $damaged
            [IO.File]::WriteAllBytes($pendingIntentPath,$damageBytes)
            try{Assert-PlanningProjectionRejects {Invoke-MorphospaceExtendActiveDevelopmentEnvelope @extensionArguments -Execute} "damaged planning extension $damage"}finally{[IO.File]::WriteAllBytes($pendingIntentPath,$pendingIntentBytes)}
        }
        $redirected=Read-EnvelopeProtocolJson $pendingIntentPath
        $redirected.unit.path='iteration-units/shadow.json';$redirected.pre_unit_raw.path='iteration-units/shadow.json'
        $shadowPath=Join-Path $workspace 'iteration-units/shadow.json'
        $redirectedBytes=&$protocolModule {param($intent) [pscustomobject]@{unit=ConvertTo-MorphospaceProtocolJsonBytes $intent.target.unit.document;intent=ConvertTo-MorphospaceProtocolJsonBytes $intent}} $redirected
        [IO.File]::WriteAllBytes($shadowPath,$redirectedBytes.unit)
        [IO.File]::WriteAllBytes($pendingIntentPath,$redirectedBytes.intent)
        try{Assert-PlanningProjectionRejects {Invoke-MorphospaceExtendActiveDevelopmentEnvelope @extensionArguments -Execute} 'redirected canonical unit and pre-unit references'}finally{[IO.File]::WriteAllBytes($pendingIntentPath,$pendingIntentBytes);Remove-Item -LiteralPath $shadowPath}
        $interrupted=$false;try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope @extensionArguments -Execute -FaultAfter after-projection|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption*'}
        Assert-RetirementTest $interrupted 'planning extension did not reach its projected recovery boundary'
        $projectedIntentBytes=[IO.File]::ReadAllBytes($pendingIntentPath);$detachedIntent=Read-EnvelopeProtocolJson $pendingIntentPath
        $requestArtifactIndex=@(for($index=0;$index-lt$detachedIntent.artifacts.Count;$index++){if(([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($detachedIntent.artifacts[$index].bytes_base64))|ConvertFrom-Json -DateKind String).schema-ceq'rusty.morphospace.workflow.active_development_envelope_extension.v1'){$index}})[0]
        $requestArtifact=$detachedIntent.artifacts[$requestArtifactIndex];$detachedRequest=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($requestArtifact.bytes_base64))|ConvertFrom-Json -DateKind String
        # last_event_id is overwritten by the extension's exact target transform.
        # This forged predecessor leaves the genuine live target unchanged.
        $detachedRequest.before.state.last_event_id='u002-envelope-prepared';$detachedRequest.expected.state_sha256=Get-EnvelopeCanonicalJsonSha256 $detachedRequest.before.state
        $detachedStateBytes=&$protocolModule {param($value)ConvertTo-MorphospaceProtocolJsonBytes $value} $detachedRequest.before.state
        $detachedRequest.expected.state_raw_sha256=Get-RetirementBytesSha256 $detachedStateBytes;$detachedIntent.pre.state.sha256=$detachedRequest.expected.state_sha256;$detachedIntent.pre_state_raw.sha256=$detachedRequest.expected.state_raw_sha256
        foreach($name in @('state_sha256','state_raw_sha256')){if($detachedIntent.expected.PSObject.Properties.Name-contains$name){$detachedIntent.expected.$name=$detachedRequest.expected.$name}}
        $artifactBytes=&$protocolModule {param($value)ConvertTo-MorphospaceProtocolJsonBytes $value} $detachedRequest;$requestArtifact.bytes_base64=[Convert]::ToBase64String($artifactBytes);$requestArtifact.sha256=Get-RetirementBytesSha256 $artifactBytes
        $artifactRestore=@{}
        foreach($relative in @($requestArtifact.path,"receipts/transactions/$($detachedIntent.transaction_id).artifact-$requestArtifactIndex.pending")){$artifactPath=Join-Path $workspace $relative;if([IO.File]::Exists($artifactPath)){$artifactRestore[$artifactPath]=[IO.File]::ReadAllBytes($artifactPath);[IO.File]::WriteAllBytes($artifactPath,$artifactBytes)}}
        $detachedIntentBytes=&$protocolModule {param($value)ConvertTo-MorphospaceProtocolJsonBytes $value} $detachedIntent;[IO.File]::WriteAllBytes($pendingIntentPath,$detachedIntentBytes)
        try{
            $before=Get-RetirementInventory $workspace;$message=''
            try{Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments -RecoveryIntent $detachedIntent}catch{$message=$_.Exception.Message}
            Assert-RetirementTest ($message-ceq'Pending or recorded planning extension predecessor differs from authenticated terminal unit or state.') "self-consistent own predecessor state missed the prefix guard: $message"
            Assert-RetirementTest ((Get-RetirementInventory $workspace)-ceq$before) 'own predecessor state rejection wrote workspace bytes'
        }finally{[IO.File]::WriteAllBytes($pendingIntentPath,$projectedIntentBytes);foreach($path in $artifactRestore.Keys){[IO.File]::WriteAllBytes($path,$artifactRestore[$path])}}
        $null=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @extensionArguments -Execute
        $derivative=Read-EnvelopeProtocolJson $requestInfo.source_path;$planningRow=@($derivative.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0]
        Assert-RetirementTest ([string]$planningRow.baseline_commit-ceq[string]$pin.commit-and[string]$planningRow.parent_commit-ceq[string]$pin.commit-and[string]$planningRow.effective_commit-ceq[string]$pin.commit-and[string]$planningRow.effective_tree-ceq[string]$pin.tree) 'planning extension replaced immutable source pins'
        $event=@(Get-Content (Join-Path $workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})[-1]
        [void](Test-MorphospaceHistoricalActiveDevelopmentEnvelopeExtension -WorkspaceRoot $workspace -ExpectedEvent $event)
        $badExpected=Copy-Envelope $requestInfo.request.expected;$badExpected.events_length=([IO.FileInfo](Join-Path $workspace 'iteration-events.jsonl')).Length;$badExpected.events_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'iteration-events.jsonl');$badExpected.event_tail_id=[string]$event.event_id
        Assert-PlanningProjectionRejects {Assert-MorphospaceReadOnlyPlanningLifecycleProjection @arguments -CapturedExpected $badExpected -HistoricalOnly -BeforeSequence ([int]$event.sequence)} 'consumer-containing prefix'
        Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','authenticated owner extension')|Out-Null
        $addedCheckpoint=(@(Invoke-EnvelopeGit $planning @('rev-parse','HEAD'))[0]).Trim()
        $addedPath=Join-Path $workspace 'readonly-extra.txt';$addedBytes=[IO.File]::ReadAllBytes($addedPath)
        [IO.File]::AppendAllText($addedPath,'changed');Invoke-EnvelopeGit $planning @('add','-f','morphospace/readonly-extra.txt')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','changed added readonly dependency')|Out-Null
        [IO.File]::WriteAllBytes($addedPath,$addedBytes);Invoke-EnvelopeGit $planning @('add','-f','morphospace/readonly-extra.txt')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','reverted added readonly dependency')|Out-Null
        Assert-PlanningProjectionRejects {Invoke-MorphospaceExtendActiveDevelopmentEnvelope @extensionArguments -Execute} 'changed and reverted newly added readonly path'
        Invoke-EnvelopeGit $planning @('reset','--hard',$addedCheckpoint)|Out-Null
        $null=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @extensionArguments -Execute
        $laterDependency=Join-Path $temp 'projection-later-dependency';Invoke-EnvelopeGit $temp @('clone','--no-hardlinks',$dependency,$laterDependency)|Out-Null
        $laterInfo=New-PlanningProjectionExtensionRequest $workspace $laterDependency (Join-Path $temp 'projection-later-extension.json') -ExtensionId 'u002-add-later-dependency' -DependencyId 'later-dependency' -AddPlanningReadOnlyPath 'morphospace/readonly-later.txt'
        $laterArguments=@{WorkspaceRoot=$workspace;UnitId='u002';RepositoryMapPath=$laterInfo.map_path;SourceCompositionOutPath=$laterInfo.source_path;ActiveDevelopmentEnvelopeExtension=$laterInfo.request_path;ExpectedActiveDevelopmentEnvelopeExtensionSha256=(Get-EnvelopeFileSha256 $laterInfo.request_path);OutPath=$laterInfo.receipt_path;Timestamp='2026-09-15T01:00:00.2500000Z'}
        $null=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @laterArguments -Execute
        [void](Test-MorphospaceHistoricalActiveDevelopmentEnvelopeExtension -WorkspaceRoot $workspace -ExpectedEvent $event)
        Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','authenticated second extension')|Out-Null
        $null=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @extensionArguments -Execute
        $requestInfo=$laterInfo
        $completionArguments=@{Action='CompleteInstructionSurfaces';WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=$requestInfo.map_path;InstructionCompletionId='u002-planning-instructions';OutPath=(Join-Path $workspace 'receipts/u002-planning-instructions.json');Timestamp='2026-09-15T01:00:00.5000000Z'}
        $completionDry=&(Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') @completionArguments|ConvertFrom-Json
        $null=&(Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') @completionArguments -ExpectedInstructionObservationSha256 $completionDry.instruction_surface_completion.observation_sha256 -ExpectedUnitSha256 $completionDry.instruction_surface_completion.expected_unit_sha256 -InstructionSurfaceIds @($completionDry.instruction_surface_completion.surfaces.surface_id) -Execute
        Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','authenticated instruction completion')|Out-Null
        $freezePath=Join-Path $temp 'projection-freeze.json';$freeze=New-PlanningProjectionFreezeRequest $workspace $requestInfo.map_path $freezePath
        $freezeArguments=@{WorkspaceRoot=$workspace;UnitId='u002';CandidateFreeze=$freezePath;ExpectedCandidateFreezeSha256=(Get-EnvelopeFileSha256 $freezePath);OutPath=(Join-Path $workspace 'receipts/u002-extension-freeze.json');Timestamp='2026-09-15T01:00:01.0000000Z';Execute=$true}
        $null=&$projectionFreezeModule {param($a) Invoke-MorphospaceFreezeCandidate @a} $freezeArguments
        $frozen=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json')
        [void](&$projectionFreezeModule {param($root,$unit) Test-MorphospaceFrozenCandidate -WorkspaceRoot $root -Unit $unit} $workspace $frozen)
        Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','authenticated committed Freeze')|Out-Null
        [void](&$projectionFreezeModule {param($root,$unit) Test-MorphospaceFrozenCandidate -WorkspaceRoot $root -Unit $unit} $workspace $frozen)
        $freezeCheckpoint=(@(Invoke-EnvelopeGit $planning @('rev-parse','HEAD'))[0]).Trim()
        $freezeProofPath=Join-Path $workspace 'receipts/u002-extension-freeze.json';$freezeProofBytes=[IO.File]::ReadAllBytes($freezeProofPath)
        [IO.File]::AppendAllText($freezeProofPath,' ',[Text.UTF8Encoding]::new($false));Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','damaged committed Freeze proof')|Out-Null
        [IO.File]::WriteAllBytes($freezeProofPath,$freezeProofBytes);Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','reverted committed Freeze proof')|Out-Null
        Assert-PlanningProjectionRejects {&$projectionFreezeModule {param($root,$unit) Test-MorphospaceFrozenCandidate -WorkspaceRoot $root -Unit $unit} $workspace $frozen} 'changed and reverted committed own Freeze proof'
        Invoke-EnvelopeGit $planning @('reset','--hard',$freezeCheckpoint)|Out-Null
        $null=&(Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action BeginValidation -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath $requestInfo.map_path -ValidationTier quick -Timestamp '2026-09-15T01:00:02.0000000Z' -Execute
        Assert-RetirementTest ([string](Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json')).status-ceq'validating') 'frozen planning candidate failed ordinary BeginValidation'
        Assert-RetirementTest ($null-ne(Get-Command Read-MorphospaceProtocolJson -ErrorAction SilentlyContinue)) 'planning projection removed caller protocol commands'

    }
    $checkName=switch($Scenario){
        'NestedPositive' {'active-unit-retirement-nested-positive'}
        'NestedCommitted' {'active-unit-retirement-nested-committed'}
        'NestedMapGuards' {'active-unit-retirement-nested-map-guards'}
        'AmendmentRecovery' {'active-unit-retirement-amendment-recovery'}
        'NestedRecovery' {'active-unit-retirement-nested-recovery'}
        'NestedDamage' {'active-unit-retirement-nested-damage'}
        'PlanningProjection' {'active-unit-retirement-planning-projection'}
        default {'active-unit-retirement'}
    }
    [pscustomobject]@{status='pass';check=$checkName;scenario=$Scenario;old_unit_and_prior_evidence_bytes_preserved=$true;source_mutation_performed=$false}|ConvertTo-Json -Compress
}finally{
    # The entire target is a unique fixture directory generated above.
    $resolved=[IO.Path]::GetFullPath($temp);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)-or-not[IO.Path]::GetFileName($resolved).StartsWith('morphospace-active-retirement-')){throw 'Unsafe fixture cleanup target.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
