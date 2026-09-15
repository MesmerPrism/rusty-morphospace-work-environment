param(
    [switch]$SelfTest,
    [switch]$InertProposalsOnly,
    [ValidateSet('All', 'Core', 'NestedPositive', 'NestedMapGuards', 'AmendmentRecovery', 'NestedRecovery', 'NestedDamage')]
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
function New-ReadonlyPlanningRetirementSeed([string]$Root,[switch]$Replacement,[switch]$NestedReadOnlySource){
    $protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
    $ledger=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
    $seed=@(New-EnvelopeAdmissionPreparedFixture -Root $Root -RepositoryRoot $repository -TransitionLedgerModule $ledger -OwnerProducedPreparation -AdditiveFeature)[-1]
    $planning=[string]$seed.source_repository;$workspace=Join-Path $planning 'morphospace'
    foreach($entry in @(Get-ChildItem -LiteralPath $seed.workspace -Force)){Copy-Item -LiteralPath $entry.FullName -Destination $workspace -Recurse -Force}
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
    Invoke-EnvelopeGit $planning @('add','-f','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-m','accepted planning baseline')|Out-Null
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
    $admission.unit.read_only_dependencies=@([pscustomobject][ordered]@{repo_id='project-shell';paths=@('morphospace/');purpose='Nested planning authority.';verification='Exact preparation lock and authenticated lifecycle projection.'})
    if($NestedReadOnlySource){
        $ownerRow=[pscustomobject][ordered]@{repo_id='nested-read-only-source';source_roots=@('SKILL.md')}
        $admission.agent_scope_assessment.owner_repositories+=,$ownerRow;$admission.unit.agent_scope_assessment.owner_repositories+=,(Copy-Envelope $ownerRow)
        $admission.unit.read_only_dependencies+=,[pscustomobject][ordered]@{repo_id='nested-read-only-source';paths=@('SKILL.md');purpose='Producer-authenticated nested source materialization.';verification='Exact preparation commit, tree, role, map, and clean backing repository.'}
    }
    $admission.unit.agent_scope_assessment=$admission.agent_scope_assessment
    $admissionPath=Join-Path $Root 'u002-readonly-planning-admission.json';Write-EnvelopeJson $admissionPath $admission
    $automation=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'
    $null=&$automation -Action AdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts/u002-admission.json') -Timestamp '2026-08-25T00:00:40.0000000Z' -Execute
    if($Replacement){
        $retireDry=&$automation -Action RetireProposed -WorkspaceRoot $workspace -UnitId u002 -ReplacementUnitId u003 -RetirementReason contract-invalid -OutPath (Join-Path $workspace 'receipts/u002-contract-retirement.json') -Timestamp '2026-08-25T00:00:41.0000000Z'|ConvertFrom-Json;$pre=$retireDry.proposed_retirement.authenticated_preimage
        $null=&$automation -Action RetireProposed -WorkspaceRoot $workspace -UnitId u002 -ReplacementUnitId u003 -RetirementReason contract-invalid -OutPath (Join-Path $workspace 'receipts/u002-contract-retirement.json') -ExpectedStateSha256 $pre.state_sha256 -ExpectedUnitSha256 $pre.unit_sha256 -ExpectedUnitRawSha256 $pre.unit_raw_sha256 -ExpectedEventsSha256 $pre.events_sha256 -ExpectedEventsLength ([long]$pre.events_length) -ExpectedEventTailId $pre.event_tail_id -ExpectedProposedRetirementBindingSha256 $retireDry.proposed_retirement.binding_sha256 -Timestamp '2026-08-25T00:00:41.0000000Z' -Execute
        $admission=New-EnvelopeReplacementAdmission $admission $workspace u003-admission u003;$admissionPath=Join-Path $Root 'u003-readonly-planning-admission.json';Write-EnvelopeJson $admissionPath $admission
        $null=&$automation -Action AdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts/u003-admission.json') -Timestamp '2026-08-25T00:00:42.0000000Z' -Execute;$unitId='u003';$ready='2026-08-25T00:00:43.0000000Z';$claim='2026-08-25T00:00:44.0000000Z'
    }else{$unitId='u002';$ready='2026-08-25T00:00:41.0000000Z';$claim='2026-08-25T00:00:42.0000000Z'}
    $lifecycle=@{WorkspaceRoot=$workspace;UnitId=$unitId;RepoMapPath=(Join-Path $workspace 'repository-map.json');ValidationTier='quick'};$null=&$automation @lifecycle -Action Ready -Timestamp $ready -Execute;$null=&$automation @lifecycle -Action Claim -Timestamp $claim -Execute
    $baselineLeak=@(Invoke-EnvelopeGit $planning @('status','--porcelain=v1','--untracked-files=all')|Where-Object{[string]$_-match'u001|repository-map'});if($baselineLeak.Count-ne0){throw "Nested lifecycle dirt leaked baseline paths: $($baselineLeak-join', ')"}
    $seed.workspace=$workspace
    $snapshot=Join-Path $Root 'retirement-planning-snapshot';if([IO.Directory]::Exists($snapshot)){throw 'Retirement fixture immutable planning snapshot already exists.'};Copy-Item -LiteralPath $planning -Destination $snapshot -Recurse -Force
    $seed|Add-Member -NotePropertyName retirement_snapshot_path -NotePropertyValue $snapshot -Force
    $seed|Add-Member -NotePropertyName retirement_snapshot_inventory -NotePropertyValue (Get-RetirementInventory $snapshot) -Force
    return $seed
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
    if($runNestedPositive -or $runAmendmentRecovery -or $runNestedRecovery -or $runNestedDamage){
        $readonlySeed=@(New-ReadonlyPlanningRetirementSeed (Join-Path $temp 'readonly-seed'))[-1]
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
        if($phase-ceq'after-projection'){$unowned=Join-Path $recoveryCase.repository 'unowned-recovery.txt';[IO.File]::WriteAllText($unowned,'unowned');try{$rejected=$false;try{Invoke-NestedRetirement $recoveryCase u002 u003 '2026-08-25T00:00:43.0000000Z' -Execute|Out-Null}catch{$rejected=$_.Exception.Message-like'*clean available source*'};Assert-RetirementTest $rejected 'in-place recovery accepted unrelated planning dirt'}finally{[IO.File]::Delete($unowned)}}
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
    $checkName=switch($Scenario){
        'NestedPositive' {'active-unit-retirement-nested-positive'}
        'NestedMapGuards' {'active-unit-retirement-nested-map-guards'}
        'AmendmentRecovery' {'active-unit-retirement-amendment-recovery'}
        'NestedRecovery' {'active-unit-retirement-nested-recovery'}
        'NestedDamage' {'active-unit-retirement-nested-damage'}
        default {'active-unit-retirement'}
    }
    [pscustomobject]@{status='pass';check=$checkName;scenario=$Scenario;old_unit_and_prior_evidence_bytes_preserved=$true;source_mutation_performed=$false}|ConvertTo-Json -Compress
}finally{
    # The entire target is a unique fixture directory generated above.
    $resolved=[IO.Path]::GetFullPath($temp);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)-or-not[IO.Path]::GetFileName($resolved).StartsWith('morphospace-active-retirement-')){throw 'Unsafe fixture cleanup target.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
