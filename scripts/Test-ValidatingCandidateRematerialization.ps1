[CmdletBinding()]param([switch]$SelfTest)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$repoRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidatingCandidateRematerialization.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
$expectedRematerializationModulePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'ValidatingCandidateRematerialization.psm1'))
$rematerializationModules=@(Get-Module ValidatingCandidateRematerialization|Where-Object{[IO.Path]::GetFullPath([string]$_.Path)-ceq$expectedRematerializationModulePath})
if($rematerializationModules.Count-ne1){throw"Expected exactly one public ValidatingCandidateRematerialization module at '$expectedRematerializationModulePath', observed $($rematerializationModules.Count)."}
$script:RematerializationOwnerModule=$rematerializationModules[0]
$script:RematerializationSourceLockProducerPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'New-SourceCompositionLock.ps1'))
$script:RematerializationInputProducerPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'New-ValidatingCandidateRematerializationInput.ps1'))
function Import-RematerializationProtocolCommon {Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Global}
function Read-RematerializationTestProtocolJson {param([Parameter(Mandatory,Position=0)][string]$Path)Import-RematerializationProtocolCommon;MorphospaceProtocolCommon\Read-MorphospaceProtocolJson -Path $Path}
function Get-RematerializationTestFileSha256 {param([Parameter(Mandatory,Position=0)][string]$Path)Import-RematerializationProtocolCommon;MorphospaceProtocolCommon\Get-MorphospaceFileSha256 -Path $Path}
function Get-RematerializationTestCanonicalJsonSha256 {param([Parameter(Mandatory,Position=0)][object]$Value)Import-RematerializationProtocolCommon;MorphospaceProtocolCommon\Get-MorphospaceCanonicalJsonSha256 -Value $Value}
function Invoke-MorphospaceRematerializeValidatingCandidate {
    [CmdletBinding()]param(
        [Parameter(Mandatory,Position=0)][string]$WorkspaceRoot,[Parameter(Mandatory,Position=1)][string]$UnitId,[Parameter(Mandatory,Position=2)][string]$CandidateFreeze,
        [Parameter(Mandatory,Position=3)][string]$SourceCompositionLock,[Parameter(Mandatory,Position=4)][string]$RepoMapPath,[Parameter(Mandatory,Position=5)][string]$OutPath,
        [string]$ExpectedCandidateFreezeSha256='',[string]$Timestamp='',[scriptblock]$BeforeTransitionHook,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none',[switch]$Execute
    )
    $arguments=@{};foreach($key in $PSBoundParameters.Keys){$arguments[$key]=$PSBoundParameters[$key]}
    & $script:RematerializationOwnerModule {param($BoundArguments) Invoke-MorphospaceRematerializeValidatingCandidate @BoundArguments} $arguments
}
function Test-MorphospaceRematerializedCandidate {
    [CmdletBinding()]param([Parameter(Mandatory,Position=0)][string]$WorkspaceRoot,[Parameter(Mandatory,Position=1)][object]$Unit)
    & $script:RematerializationOwnerModule {param($Root,$CandidateUnit) Test-MorphospaceRematerializedCandidate -WorkspaceRoot $Root -Unit $CandidateUnit} $WorkspaceRoot $Unit
}
function Invoke-RematerializationSourceLockProducer {
    param([hashtable]$Arguments)
    & $script:RematerializationSourceLockProducerPath @Arguments
}
function Invoke-RematerializationInputProducer {
    param([hashtable]$Arguments)
    & $script:RematerializationInputProducerPath @Arguments
}

function Write-RematerializationTestJson {
    param([string]$Path,[object]$Value)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)))|Out-Null
    [IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 96)+"`n"),[Text.UTF8Encoding]::new($false))
}
function Copy-RematerializationTestValue { param([object]$Value) $Value|ConvertTo-Json -Depth 96|ConvertFrom-Json -Depth 96 -DateKind String }
function Invoke-RematerializationTestGit {
    param([string]$Root,[string[]]$Arguments)
    $output=@(& git --no-pager --no-replace-objects -c core.pager=cat -C $Root @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "Test Git command failed: git $($Arguments-join' ') :: $($output-join' ')"};return (($output|ForEach-Object{[string]$_})-join"`n").Trim()
}
function Assert-RematerializationThrows {
    param([scriptblock]$Action,[string]$Like)
    $thrown=$false;try{&$Action}catch{$thrown=$true;if($_.Exception.Message-cnotlike$Like){throw "Expected '$Like', got '$($_.Exception.Message)'."}}
    if(-not$thrown){throw "Expected rejection '$Like'."}
}
function Assert-RematerializationEquivalent {
    param([object]$Expected,[object]$Actual,[string]$Message)
    if((Get-RematerializationTestCanonicalJsonSha256 $Expected)-cne(Get-RematerializationTestCanonicalJsonSha256 $Actual)){throw $Message}
}
function Test-RematerializationCandidateFreezeDispatch {
    param([string]$WorkspaceRoot,[object]$Unit)
    $expected=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'CandidateFreeze.psm1'))
    $modules=@(Get-Module CandidateFreeze -All|Where-Object{[IO.Path]::GetFullPath([string]$_.Path)-ceq$expected})
    if($modules.Count-ne1){throw"Expected exactly one loaded CandidateFreeze owner module at '$expected', observed $($modules.Count)."}
    [bool](CandidateFreeze\Test-MorphospaceFrozenCandidate -WorkspaceRoot $WorkspaceRoot -Unit $Unit)
}
function Get-RematerializationSourceFingerprint {
    param([string]$ProjectId,[string]$UnitId,[object[]]$Repositories)
    Get-RematerializationTestCanonicalJsonSha256 ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.source_composition_identity.v1';project_id=$ProjectId;unit_id=$UnitId;repositories=@($Repositories)})
}
function Get-RematerializationGitMetadataSnapshot {
    param([string]$Root)
    $gitRoot=Join-Path $Root '.git';$index=Join-Path $gitRoot 'index'
    $paths=[Collections.Generic.List[string]]::new()
    $refs=Join-Path $gitRoot 'refs'
    if([IO.Directory]::Exists($refs)){foreach($file in @(Get-ChildItem -LiteralPath $refs -File -Recurse -Force)){$paths.Add(([IO.Path]::GetRelativePath($gitRoot,$file.FullName)).Replace('\','/'))|Out-Null}}
    if([IO.File]::Exists((Join-Path $gitRoot 'packed-refs'))){$paths.Add('packed-refs')|Out-Null}
    $ordered=[string[]]$paths.ToArray();[Array]::Sort($ordered,[StringComparer]::Ordinal)
    [pscustomobject][ordered]@{
        index_length=[IO.FileInfo]::new($index).Length
        index_sha256=(Get-RematerializationTestFileSha256 $index)
        refs=@($ordered|ForEach-Object{$path=$_;$absolute=Join-Path $gitRoot $path.Replace('/','\');[pscustomobject][ordered]@{path=$path;length=[IO.FileInfo]::new($absolute).Length;sha256=(Get-RematerializationTestFileSha256 $absolute)}})
    }
}
function Get-RematerializationFileTreeSnapshot {
    param([string]$Root)
    $rows=[Collections.Generic.List[object]]::new()
    foreach($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)){
        $relative=[IO.Path]::GetRelativePath($Root,$file.FullName).Replace('\','/')
        [void]$rows.Add([pscustomobject][ordered]@{path=$relative;length=[long]$file.Length;sha256=(Get-RematerializationTestFileSha256 $file.FullName)})
    }
    $ordered=@($rows.ToArray()|Sort-Object path -CaseSensitive)
    return $ordered
}
function Get-RematerializationTextSha256 {
    param([string]$Value)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($Value))).ToLowerInvariant()
}
$script:RematerializationCleanDirtyFingerprint=Get-RematerializationTextSha256 ''
function New-RematerializationFixture {
    param([string]$Name,[switch]$BlobDrift,[switch]$NonAncestor,[switch]$BaselineNonAncestor,[string]$RepoId='source-repo')
    $root=Join-Path ([IO.Path]::GetTempPath()) "validating-candidate-rematerialization-$Name-$([guid]::NewGuid().ToString('N'))"
    $source=Join-Path $root 'source';$workspace=Join-Path $root 'workspace';$inputs=Join-Path $root 'inputs'
    [IO.Directory]::CreateDirectory($source)|Out-Null;[IO.Directory]::CreateDirectory($workspace)|Out-Null;[IO.Directory]::CreateDirectory($inputs)|Out-Null
    [void](Invoke-RematerializationTestGit $source @('init','-b','main'));[void](Invoke-RematerializationTestGit $source @('config','user.name','Rematerialization Test'));[void](Invoke-RematerializationTestGit $source @('config','user.email','test@example.invalid'))
    [IO.File]::WriteAllText((Join-Path $source 'app.txt'),"baseline`n",[Text.UTF8Encoding]::new($false));[void](Invoke-RematerializationTestGit $source @('add','app.txt'));[void](Invoke-RematerializationTestGit $source @('commit','-m','source baseline'))
    $baselineCommit=Invoke-RematerializationTestGit $source @('rev-parse','HEAD');$baselineTree=Invoke-RematerializationTestGit $source @('rev-parse','HEAD^{tree}')
    if($BaselineNonAncestor){[void](Invoke-RematerializationTestGit $source @('checkout','--orphan','frozen'));[void](Invoke-RematerializationTestGit $source @('rm','-rf','.'))}
    [IO.File]::WriteAllText((Join-Path $source 'app.txt'),"carried`n",[Text.UTF8Encoding]::new($false));[void](Invoke-RematerializationTestGit $source @('add','-A'));[void](Invoke-RematerializationTestGit $source @('commit','-m','frozen candidate'))
    $predecessorCommit=Invoke-RematerializationTestGit $source @('rev-parse','HEAD');$predecessorTree=Invoke-RematerializationTestGit $source @('rev-parse','HEAD^{tree}');$predecessorBlob=Invoke-RematerializationTestGit $source @('rev-parse',"$predecessorCommit`:app.txt");$predecessorBranch=$(if($BaselineNonAncestor){'frozen'}else{'main'})
    if($NonAncestor){
        [void](Invoke-RematerializationTestGit $source @('checkout','--orphan','unrelated'));[void](Invoke-RematerializationTestGit $source @('rm','-rf','.'))
        [IO.File]::WriteAllText((Join-Path $source 'app.txt'),"carried`n",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $source 'prerequisite.txt'),"adopted`n",[Text.UTF8Encoding]::new($false))
    }else{
        if($BlobDrift){[IO.File]::WriteAllText((Join-Path $source 'app.txt'),"drifted`n",[Text.UTF8Encoding]::new($false))}
        [IO.File]::WriteAllText((Join-Path $source 'prerequisite.txt'),"adopted`n",[Text.UTF8Encoding]::new($false))
    }
    [void](Invoke-RematerializationTestGit $source @('add','-A'));[void](Invoke-RematerializationTestGit $source @('commit','-m','adopt prerequisite'))
    $newCommit=Invoke-RematerializationTestGit $source @('rev-parse','HEAD');$newTree=Invoke-RematerializationTestGit $source @('rev-parse','HEAD^{tree}');$newBlob=Invoke-RematerializationTestGit $source @('rev-parse',"$newCommit`:app.txt");$targetBranch=$(if($NonAncestor){'unrelated'}else{$predecessorBranch})
    [void](Invoke-RematerializationTestGit $source @('remote','add','origin','https://example.invalid/source.git'))

    foreach($relative in @('iteration-units','receipts','receipts/transactions','source-compositions','manifests')){[IO.Directory]::CreateDirectory((Join-Path $workspace $relative))|Out-Null}
    $project=Get-Content -Raw (Join-Path $repoRoot 'templates\project.spec.v2.example.json')|ConvertFrom-Json -Depth 96 -DateKind String
    $project.project_id='test-project';$project.owner='test-owner';$project.repositories=@([pscustomobject][ordered]@{repo_id=$RepoId;role='application';path='..';allowed_paths=@('app.txt')})
    $projectPath=Join-Path $workspace 'project.spec.json';Write-RematerializationTestJson $projectPath $project
    $feature=Get-Content -Raw (Join-Path $repoRoot 'templates\feature.lock.v2.example.json')|ConvertFrom-Json -Depth 96 -DateKind String
    $feature.project_id='test-project';$featurePath=Join-Path $workspace 'feature.lock.json';Write-RematerializationTestJson $featurePath $feature
    $map=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([pscustomobject][ordered]@{repo_id=$RepoId;path=$source;role='source';aliases=@()})}
    $mapPath=Join-Path $workspace 'repository-map.json';Write-RematerializationTestJson $mapPath $map

    $oldRepository=[pscustomobject][ordered]@{repo_id=$RepoId;role='source';commit=$baselineCommit;tree=$baselineTree;branch='main';remote_url='https://example.invalid/source.git';materialization_path='source';tracked_worktree_clean=$true}
    $oldLock=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.source_composition_lock.v1';lock_id='old-source-lock';created_at='2026-09-02T00:00:00.0000000Z';project_id='test-project';unit_id='unit-remat-001';fingerprint=('0'*64);repositories=@($oldRepository);status='locked';does_not_prove=@('Does not prove validation.')}
    $oldLock.fingerprint=Get-RematerializationSourceFingerprint 'test-project' 'unit-remat-001' @($oldLock.repositories)
    $oldLockRelative='source-compositions/old-source-lock.lock.json';$oldLockPath=Join-Path $workspace $oldLockRelative;Write-RematerializationTestJson $oldLockPath $oldLock

    $unit=Get-Content -Raw (Join-Path $repoRoot 'templates\iteration-unit.example.json')|ConvertFrom-Json -Depth 96 -DateKind String
    $unit.unit_id='unit-remat-001';$unit.project_id='test-project';$unit.status='validating';$unit.allowed_repositories=@([pscustomobject][ordered]@{repo_id=$RepoId;allowed_paths=@('app.txt')})
    $unit.source_composition=[pscustomobject][ordered]@{mode='exact-lock';lock_path=$oldLockRelative;materialization_receipt=$null}
    if(-not($unit.PSObject.Properties.Name-contains'agent_scope_assessment')){$unit|Add-Member -NotePropertyName agent_scope_assessment -NotePropertyValue ([pscustomobject]@{assessment='test-only development-envelope admission'})}
    $unitWithoutFreezeHash=Get-RematerializationTestCanonicalJsonSha256 $unit
    $state=Get-Content -Raw (Join-Path $repoRoot 'templates\workspace.state.v2.example.json')|ConvertFrom-Json -Depth 96 -DateKind String
    $state.project_id='test-project';$state.current_unit='unit-remat-001';$state.last_event_id='remat-seed-0001';$state.repository_heads=@([pscustomobject][ordered]@{repo_id=$RepoId;head=$predecessorCommit;branch=$predecessorBranch;dirty_fingerprint=$script:RematerializationCleanDirtyFingerprint})
    $selector=[pscustomobject][ordered]@{unit_id='unit-remat-001';unit_raw_sha256=('1'*64);unit_contract_sha256=('2'*64);tier='quick';selector_id='unit-remat-selector';selector_path='validation-authority/selectors/unit-remat-selector.json';selector_sha256=('3'*64);evidence_path_sha256=('4'*64)}
    $state|Add-Member -NotePropertyName normal_validation_selection -NotePropertyValue $selector
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='remat-seed-0001';sequence=1;timestamp='2026-09-02T00:00:00.0000000Z';project_id='test-project';unit_id='unit-remat-001';event_type='state-transition';summary='Seeded validating candidate.';receipts=@()}
    $eventsPath=Join-Path $workspace 'iteration-events.jsonl';[IO.File]::WriteAllText($eventsPath,(($event|ConvertTo-Json -Compress -Depth 96)+"`n"),[Text.UTF8Encoding]::new($false))

    $oldFreeze=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id='old-candidate-freeze';project_id='test-project';unit_id='unit-remat-001';expected=[pscustomobject][ordered]@{project_sha256=(Get-RematerializationTestCanonicalJsonSha256 $project);state_sha256=('5'*64);unit_sha256=$unitWithoutFreezeHash;feature_lock_sha256=(Get-RematerializationTestCanonicalJsonSha256 $feature);source_composition_path=$oldLockRelative;source_composition_sha256=(Get-RematerializationTestFileSha256 $oldLockPath);repository_map_path='repository-map.json';repository_map_sha256=(Get-RematerializationTestFileSha256 $mapPath);events_sha256=(Get-RematerializationTestFileSha256 $eventsPath);events_length=[IO.FileInfo]::new($eventsPath).Length;event_tail_id='remat-seed-0001'};final_repositories=@([pscustomobject][ordered]@{repo_id=$RepoId;commit=$predecessorCommit;tree=$predecessorTree});changed_paths=@([pscustomobject][ordered]@{repo_id=$RepoId;paths=@('app.txt')});cleanliness_policy='clean-only';instruction_surfaces=@([pscustomobject][ordered]@{path='<repo-root>/AGENTS.md';disposition='reviewed-no-change'});feature_lock=[pscustomobject][ordered]@{revision=[int]$feature.revision;sha256=(Get-RematerializationTestCanonicalJsonSha256 $feature)};effects=@('source-rebind-only');permissions=@('none');device_use=@('none');test_matrix=@([pscustomobject][ordered]@{test_id='host-only';command='pwsh -File Test.ps1'});cleanup_evidence=@('No process or lease is acquired.');source_composition=[pscustomobject][ordered]@{path=$oldLockRelative;sha256=(Get-RematerializationTestFileSha256 $oldLockPath)};does_not_prove=@('Does not prove validation.')}
    $oldFreezeRelative='receipts/old-candidate-freeze.json';$oldFreezePath=Join-Path $workspace $oldFreezeRelative;Write-RematerializationTestJson $oldFreezePath $oldFreeze;$oldFreezeHash=Get-RematerializationTestFileSha256 $oldFreezePath
    $unit|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue ([pscustomobject][ordered]@{freeze_id='old-candidate-freeze';receipt_path=$oldFreezeRelative;receipt_sha256=$oldFreezeHash})
    $unitPath=Join-Path $workspace 'iteration-units\unit-remat-001.json';Write-RematerializationTestJson $unitPath $unit
    $selector.unit_raw_sha256=Get-RematerializationTestFileSha256 $unitPath;$selector.unit_contract_sha256=Get-RematerializationTestCanonicalJsonSha256 $unit
    $state.normal_validation_selection=$selector;$statePath=Join-Path $workspace 'workspace.state.json';Write-RematerializationTestJson $statePath $state

    $newRepository=[pscustomobject][ordered]@{repo_id=$RepoId;role='source';commit=$newCommit;tree=$newTree;branch=$targetBranch;remote_url='https://example.invalid/source.git';materialization_path='source';tracked_worktree_clean=$true}
    $newLock=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.source_composition_lock.v1';lock_id="new-source-$Name";created_at='2026-09-02T00:01:00.0000000Z';project_id='test-project';unit_id='unit-remat-001';fingerprint=('0'*64);repositories=@($newRepository);status='locked';does_not_prove=@('Does not prove validation, build, device behavior, acceptance, or publication.')}
    $newLock.fingerprint=Get-RematerializationSourceFingerprint 'test-project' 'unit-remat-001' @($newLock.repositories)
    $newLockPath=Join-Path $inputs 'new-source-lock.json';Write-RematerializationTestJson $newLockPath $newLock;$newLockHash=Get-RematerializationTestFileSha256 $newLockPath
    $newLockRelative="source-compositions/$($newLock.lock_id).lock.json"
    $candidate=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.candidate_freeze.v2';freeze_id="new-candidate-$Name";project_id='test-project';unit_id='unit-remat-001';expected=[pscustomobject][ordered]@{project_sha256=(Get-RematerializationTestCanonicalJsonSha256 $project);project_raw_sha256=(Get-RematerializationTestFileSha256 $projectPath);state_sha256=(Get-RematerializationTestCanonicalJsonSha256 $state);state_raw_sha256=(Get-RematerializationTestFileSha256 $statePath);unit_sha256=(Get-RematerializationTestCanonicalJsonSha256 $unit);unit_raw_sha256=(Get-RematerializationTestFileSha256 $unitPath);feature_lock_sha256=(Get-RematerializationTestCanonicalJsonSha256 $feature);feature_lock_raw_sha256=(Get-RematerializationTestFileSha256 $featurePath);source_composition_path=$oldLockRelative;source_composition_sha256=(Get-RematerializationTestFileSha256 $oldLockPath);repository_map_path='repository-map.json';repository_map_sha256=(Get-RematerializationTestFileSha256 $mapPath);repository_map_canonical_sha256=(Get-RematerializationTestCanonicalJsonSha256 $map);events_sha256=(Get-RematerializationTestFileSha256 $eventsPath);events_length=[IO.FileInfo]::new($eventsPath).Length;event_tail_id='remat-seed-0001'};final_repositories=@([pscustomobject][ordered]@{repo_id=$RepoId;commit=$newCommit;tree=$newTree});changed_paths=@(Copy-RematerializationTestValue $oldFreeze.changed_paths);cleanliness_policy='clean-only';instruction_surfaces=@(Copy-RematerializationTestValue $oldFreeze.instruction_surfaces);feature_lock=(Copy-RematerializationTestValue $oldFreeze.feature_lock);effects=@($oldFreeze.effects);permissions=@($oldFreeze.permissions);device_use=@($oldFreeze.device_use);test_matrix=@(Copy-RematerializationTestValue $oldFreeze.test_matrix);cleanup_evidence=@($oldFreeze.cleanup_evidence);source_composition=[pscustomobject][ordered]@{path=$newLockRelative;sha256=$newLockHash};lineage=[pscustomobject][ordered]@{rematerialization_id="rematerialize-$Name";predecessor_freeze=[pscustomobject][ordered]@{freeze_id='old-candidate-freeze';receipt_path=$oldFreezeRelative;receipt_sha256=$oldFreezeHash};predecessor_source_composition=[pscustomobject][ordered]@{path=$oldLockRelative;sha256=(Get-RematerializationTestFileSha256 $oldLockPath)};predecessor_final_repositories=@(Copy-RematerializationTestValue $oldFreeze.final_repositories);invalidated_normal_validation_selection=(Copy-RematerializationTestValue $selector);repositories=@([pscustomobject][ordered]@{repo_id=$RepoId;role='source';source_baseline_commit=$baselineCommit;source_baseline_tree=$baselineTree;predecessor_commit=$predecessorCommit;predecessor_tree=$predecessorTree;target_commit=$newCommit;target_tree=$newTree;carried_paths=@([pscustomobject][ordered]@{path='app.txt';predecessor_blob=$predecessorBlob;target_blob=$newBlob})});repository_head_projections=@([pscustomobject][ordered]@{repo_id=$RepoId;predecessor=[pscustomobject][ordered]@{head=$predecessorCommit;branch=$predecessorBranch;dirty_fingerprint=$script:RematerializationCleanDirtyFingerprint};target=[pscustomobject][ordered]@{head=$newCommit;branch=$targetBranch;dirty_fingerprint=$script:RematerializationCleanDirtyFingerprint}});target_source_composition=[pscustomobject][ordered]@{path=$newLockRelative;sha256=$newLockHash}};does_not_prove=@('Does not prove source mutation, validation, build, device behavior, acceptance, or publication.')}
    $candidatePath=Join-Path $inputs 'candidate-freeze-v2.json';Write-RematerializationTestJson $candidatePath $candidate
    if($Name-ceq'positive'){
        Remove-Item -LiteralPath $newLockPath,$candidatePath -Force
        $producedLockJson=(@(Invoke-RematerializationSourceLockProducer @{WorkspaceRoot=$workspace;UnitId='unit-remat-001';RepositoryMapPath=$mapPath;RepoId=@($RepoId)}) -join "`n")
        $producedLock=$producedLockJson|ConvertFrom-Json -Depth 96 -DateKind String
        Write-RematerializationTestJson $newLockPath $producedLock
        $newLock=Read-RematerializationTestProtocolJson $newLockPath;$newLockRelative="source-compositions/$($newLock.lock_id).lock.json"
        [void](Invoke-RematerializationInputProducer @{WorkspaceRoot=$workspace;UnitId='unit-remat-001';RepositoryMapPath=$mapPath;TargetSourceCompositionLock=$newLockPath;FreezeId="new-candidate-$Name";RematerializationId="rematerialize-$Name";RepoId=@($RepoId);OutPath=$candidatePath})
        $candidate=Read-RematerializationTestProtocolJson $candidatePath
    }
    [pscustomobject]@{root=$root;source=$source;workspace=$workspace;candidate_path=$candidatePath;source_lock_path=$newLockPath;map_path=$mapPath;out_path=(Join-Path $workspace "receipts\$($candidate.freeze_id).json");candidate=$candidate;state_path=$statePath;unit_path=$unitPath;new_lock_relative=$newLockRelative}
}

if(-not$SelfTest){throw 'Test-ValidatingCandidateRematerialization.ps1 requires -SelfTest.'}
$fixtures=[Collections.Generic.List[string]]::new();$assertions=0
try{
    $positive=New-RematerializationFixture 'positive';$fixtures.Add($positive.root)|Out-Null
    $workspaceBefore=Get-RematerializationFileTreeSnapshot $positive.workspace
    $reproduced=@(Invoke-RematerializationInputProducer @{WorkspaceRoot=$positive.workspace;UnitId='unit-remat-001';RepositoryMapPath=$positive.map_path;TargetSourceCompositionLock=$positive.source_lock_path;FreezeId='new-candidate-positive';RematerializationId='rematerialize-positive';RepoId=@('source-repo')})[-1]
    Assert-RematerializationEquivalent $positive.candidate $reproduced 'Stdout-only production did not reproduce the exact candidate-freeze v2 document.'
    Assert-RematerializationEquivalent $workspaceBefore (Get-RematerializationFileTreeSnapshot $positive.workspace) 'Stdout-only rematerialization input production changed planning workspace bytes.';$assertions++
    $candidateBytesBefore=Get-RematerializationTestFileSha256 $positive.candidate_path
    Assert-RematerializationThrows {Invoke-RematerializationInputProducer @{WorkspaceRoot=$positive.workspace;UnitId='unit-remat-001';RepositoryMapPath=$positive.map_path;TargetSourceCompositionLock=$positive.source_lock_path;FreezeId='new-candidate-positive';RematerializationId='rematerialize-positive';RepoId=@('source-repo');OutPath=$positive.candidate_path}} '*exists*'
    if((Get-RematerializationTestFileSha256 $positive.candidate_path)-cne$candidateBytesBefore){throw'Rematerialization input collision changed existing bytes.'};$assertions++
    $workspaceAlias=Join-Path (Split-Path -Parent $positive.workspace) 'workspace-output-alias'
    $aliasedTarget=Join-Path $positive.workspace 'receipts\aliased-candidate-freeze-v2.json'
    try{
        $aliasItemType=if($IsWindows){'Junction'}else{'SymbolicLink'}
        [void](New-Item -ItemType $aliasItemType -Path $workspaceAlias -Target (Join-Path $positive.workspace 'receipts') -ErrorAction Stop)
        Assert-RematerializationThrows {Invoke-RematerializationInputProducer @{WorkspaceRoot=$positive.workspace;UnitId='unit-remat-001';RepositoryMapPath=$positive.map_path;TargetSourceCompositionLock=$positive.source_lock_path;FreezeId='new-candidate-positive';RematerializationId='rematerialize-positive';RepoId=@('source-repo');OutPath=(Join-Path $workspaceAlias 'aliased-candidate-freeze-v2.json')}} '*contains a reparse point*'
        if([IO.File]::Exists($aliasedTarget)){throw'Rematerialization input reparse-alias rejection created planning workspace bytes.'};$assertions++
    }finally{
        if([IO.Directory]::Exists($workspaceAlias)){Remove-Item -LiteralPath $workspaceAlias -Force}
    }
    Assert-RematerializationThrows {Invoke-RematerializationInputProducer @{WorkspaceRoot=$positive.workspace;UnitId='unit-remat-001';RepositoryMapPath=$positive.map_path;TargetSourceCompositionLock=$positive.source_lock_path;FreezeId='new-candidate-positive';RematerializationId='rematerialize-positive';RepoId=@('other-repo')}} '*explicit rematerialization repository set*';$assertions++
    $untracked=Join-Path $positive.source 'untracked.tmp';[IO.File]::WriteAllText($untracked,'untracked',[Text.UTF8Encoding]::new($false))
    Assert-RematerializationThrows {Invoke-RematerializationSourceLockProducer @{WorkspaceRoot=$positive.workspace;UnitId='unit-remat-001';RepositoryMapPath=$positive.map_path;RepoId=@('source-repo')}} '*not completely clean*'
    Remove-Item -LiteralPath $untracked -Force;$assertions++
    $gitMetadataBefore=Get-RematerializationGitMetadataSnapshot $positive.source
    $dry=Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $positive.workspace -UnitId 'unit-remat-001' -CandidateFreeze $positive.candidate_path -SourceCompositionLock $positive.source_lock_path -RepoMapPath $positive.map_path -OutPath $positive.out_path -Timestamp '2026-09-02T00:02:00.0000000Z'
    if($dry.executed-or$dry.transition-cne'validating-candidate-rematerialized'-or[IO.File]::Exists($positive.out_path)){throw'Dry run mutated or returned the wrong transition.'};$assertions++
    Assert-RematerializationEquivalent $gitMetadataBefore (Get-RematerializationGitMetadataSnapshot $positive.source) 'Dry-run Git observation changed refs or index bytes.'
    $candidateHash=Get-RematerializationTestFileSha256 $positive.candidate_path
    $executed=Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $positive.workspace -UnitId 'unit-remat-001' -CandidateFreeze $positive.candidate_path -SourceCompositionLock $positive.source_lock_path -RepoMapPath $positive.map_path -OutPath $positive.out_path -ExpectedCandidateFreezeSha256 $candidateHash -Timestamp '2026-09-02T00:02:00.0000000Z' -Execute
    if(-not$executed.executed-or$executed.transition-cne'validating-candidate-rematerialized'){throw'Execute returned the wrong transition.'};$assertions++
    Assert-RematerializationEquivalent $gitMetadataBefore (Get-RematerializationGitMetadataSnapshot $positive.source) 'Executed Git observation changed refs or index bytes.';$assertions++
    $liveUnit=Read-RematerializationTestProtocolJson $positive.unit_path;if(-not(Test-MorphospaceRematerializedCandidate -WorkspaceRoot $positive.workspace -Unit $liveUnit)){throw'Verifier did not accept exact rematerialization.'};$assertions++
    $replay=Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $positive.workspace -UnitId 'unit-remat-001' -CandidateFreeze $positive.candidate_path -SourceCompositionLock $positive.source_lock_path -RepoMapPath $positive.map_path -OutPath $positive.out_path -ExpectedCandidateFreezeSha256 $candidateHash -Timestamp '2026-09-02T00:02:00.0000000Z' -Execute
    if($replay.transition-cne'validating-candidate-already-rematerialized'){throw'Exact replay was not idempotent.'};$assertions++
    $bridgeUnit=Read-RematerializationTestProtocolJson $positive.unit_path
    if(-not(Test-RematerializationCandidateFreezeDispatch -WorkspaceRoot $positive.workspace -Unit $bridgeUnit)){throw'CandidateFreeze v2 dispatch did not verify the rematerialized candidate.'};$assertions++
    $oldReceipt=Join-Path $positive.workspace ([string]$positive.candidate.lineage.predecessor_freeze.receipt_path).Replace('/','\');[IO.File]::AppendAllText($oldReceipt,' ',[Text.UTF8Encoding]::new($false))
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $positive.workspace -UnitId 'unit-remat-001' -CandidateFreeze $positive.candidate_path -SourceCompositionLock $positive.source_lock_path -RepoMapPath $positive.map_path -OutPath $positive.out_path -ExpectedCandidateFreezeSha256 $candidateHash -Timestamp '2026-09-02T00:02:00.0000000Z' -Execute} '*Predecessor candidate-freeze bytes drifted*';$assertions++

    $torn=New-RematerializationFixture 'torn';$fixtures.Add($torn.root)|Out-Null;$tornHash=Get-RematerializationTestFileSha256 $torn.candidate_path
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $torn.workspace -UnitId 'unit-remat-001' -CandidateFreeze $torn.candidate_path -SourceCompositionLock $torn.source_lock_path -RepoMapPath $torn.map_path -OutPath $torn.out_path -ExpectedCandidateFreezeSha256 $tornHash -Timestamp '2026-09-02T00:02:00.0000000Z' -FaultAfter after-intent -Execute} '*Injected interruption after intent publication*';$assertions++
    $repair=Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $torn.workspace -UnitId 'unit-remat-001' -CandidateFreeze $torn.candidate_path -SourceCompositionLock $torn.source_lock_path -RepoMapPath $torn.map_path -OutPath $torn.out_path -ExpectedCandidateFreezeSha256 $tornHash -Timestamp '2026-09-02T00:02:00.0000000Z' -Execute
    if($repair.transition-cne'validating-candidate-already-rematerialized'-or-not(Test-MorphospaceRematerializedCandidate $torn.workspace (Read-RematerializationTestProtocolJson $torn.unit_path))){throw'Torn transition did not repair exactly.'};$assertions++
    foreach($eventDamage in @(
        [pscustomobject]@{name='event-schema';property='schema';value='rusty.morphospace.workflow.iteration_event.v2'},
        [pscustomobject]@{name='event-type';property='event_type';value='validation'},
        [pscustomobject]@{name='event-summary';property='summary';value='Rematerialized a near-miss candidate.'}
    )){
        $damagedIntent=New-RematerializationFixture ([string]$eventDamage.name);$fixtures.Add($damagedIntent.root)|Out-Null;$damagedIntentHash=Get-RematerializationTestFileSha256 $damagedIntent.candidate_path
        Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $damagedIntent.workspace -UnitId 'unit-remat-001' -CandidateFreeze $damagedIntent.candidate_path -SourceCompositionLock $damagedIntent.source_lock_path -RepoMapPath $damagedIntent.map_path -OutPath $damagedIntent.out_path -ExpectedCandidateFreezeSha256 $damagedIntentHash -Timestamp '2026-09-02T00:02:00.0000000Z' -FaultAfter after-intent -Execute} '*Injected interruption after intent publication*'
        $intentPath=Join-Path $damagedIntent.workspace "receipts\transactions\rematerialize-$([string]$eventDamage.name)-recorded-transition.intent.json";$intent=Read-RematerializationTestProtocolJson $intentPath;$intent.event.([string]$eventDamage.property)=[string]$eventDamage.value;Write-RematerializationTestJson $intentPath $intent
        Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $damagedIntent.workspace -UnitId 'unit-remat-001' -CandidateFreeze $damagedIntent.candidate_path -SourceCompositionLock $damagedIntent.source_lock_path -RepoMapPath $damagedIntent.map_path -OutPath $damagedIntent.out_path -ExpectedCandidateFreezeSha256 $damagedIntentHash -Timestamp '2026-09-02T00:02:00.0000000Z' -Execute} '*replay event contract is conflicting*';$assertions++
    }

    $stale=New-RematerializationFixture 'stale';$fixtures.Add($stale.root)|Out-Null;$damaged=Read-RematerializationTestProtocolJson $stale.candidate_path;$damaged.expected.state_sha256='f'*64;Write-RematerializationTestJson $stale.candidate_path $damaged
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $stale.workspace 'unit-remat-001' $stale.candidate_path $stale.source_lock_path $stale.map_path $stale.out_path} '*stale state canonical CAS*';$assertions++

    $dirty=New-RematerializationFixture 'dirty';$fixtures.Add($dirty.root)|Out-Null;[IO.File]::WriteAllText((Join-Path $dirty.source 'dirty.tmp'),'dirty',[Text.UTF8Encoding]::new($false))
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $dirty.workspace 'unit-remat-001' $dirty.candidate_path $dirty.source_lock_path $dirty.map_path $dirty.out_path} '*is dirty*';$assertions++
    $missing=New-RematerializationFixture 'missing';$fixtures.Add($missing.root)|Out-Null;$map=Read-RematerializationTestProtocolJson $missing.map_path;$map.repositories[0].path=Join-Path $missing.root 'absent';Write-RematerializationTestJson $missing.map_path $map;$candidate=Read-RematerializationTestProtocolJson $missing.candidate_path;$candidate.expected.repository_map_sha256=Get-RematerializationTestFileSha256 $missing.map_path;$candidate.expected.repository_map_canonical_sha256=Get-RematerializationTestCanonicalJsonSha256 $map;Write-RematerializationTestJson $missing.candidate_path $candidate
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $missing.workspace 'unit-remat-001' $missing.candidate_path $missing.source_lock_path $missing.map_path $missing.out_path} '*is absent*';$assertions++
    $wrong=New-RematerializationFixture 'wrong';$fixtures.Add($wrong.root)|Out-Null;[void](Invoke-RematerializationTestGit $wrong.source @('checkout','HEAD^'))
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $wrong.workspace 'unit-remat-001' $wrong.candidate_path $wrong.source_lock_path $wrong.map_path $wrong.out_path} '*not at the exact staged commit/tree*';$assertions++

    foreach($fingerprintDamage in @(
        [pscustomobject]@{name='predecessor-fingerprint-null';side='predecessor';value=$null;error='*JSON is not valid with the schema*'},
        [pscustomobject]@{name='target-fingerprint-null';side='target';value=$null;error='*JSON is not valid with the schema*'},
        [pscustomobject]@{name='predecessor-fingerprint-nonempty';side='predecessor';value=('a'*64);error='*repository-head predecessor or clean target identity differs*'},
        [pscustomobject]@{name='target-fingerprint-nonempty';side='target';value=('a'*64);error='*repository-head predecessor or clean target identity differs*'}
    )){
        $fingerprint=New-RematerializationFixture ([string]$fingerprintDamage.name);$fixtures.Add($fingerprint.root)|Out-Null
        $candidate=Read-RematerializationTestProtocolJson $fingerprint.candidate_path
        $candidate.lineage.repository_head_projections[0].([string]$fingerprintDamage.side).dirty_fingerprint=$fingerprintDamage.value
        Write-RematerializationTestJson $fingerprint.candidate_path $candidate
        Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $fingerprint.workspace 'unit-remat-001' $fingerprint.candidate_path $fingerprint.source_lock_path $fingerprint.map_path $fingerprint.out_path} ([string]$fingerprintDamage.error);$assertions++
    }

    $nonAncestor=New-RematerializationFixture 'nonancestor' -NonAncestor;$fixtures.Add($nonAncestor.root)|Out-Null
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $nonAncestor.workspace 'unit-remat-001' $nonAncestor.candidate_path $nonAncestor.source_lock_path $nonAncestor.map_path $nonAncestor.out_path} '*target is not descended from its frozen predecessor*';$assertions++
    $baselineNonAncestor=New-RematerializationFixture 'baseline-nonancestor' -BaselineNonAncestor;$fixtures.Add($baselineNonAncestor.root)|Out-Null
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $baselineNonAncestor.workspace 'unit-remat-001' $baselineNonAncestor.candidate_path $baselineNonAncestor.source_lock_path $baselineNonAncestor.map_path $baselineNonAncestor.out_path} '*frozen predecessor is not descended from its source baseline*';$assertions++
    $baselineIdentity=New-RematerializationFixture 'baseline-identity';$fixtures.Add($baselineIdentity.root)|Out-Null;$candidate=Read-RematerializationTestProtocolJson $baselineIdentity.candidate_path;$candidate.lineage.repositories[0].source_baseline_tree=$candidate.lineage.repositories[0].target_tree;Write-RematerializationTestJson $baselineIdentity.candidate_path $candidate
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $baselineIdentity.workspace 'unit-remat-001' $baselineIdentity.candidate_path $baselineIdentity.source_lock_path $baselineIdentity.map_path $baselineIdentity.out_path} '*source-baseline tree lineage differs*';$assertions++
    $blob=New-RematerializationFixture 'blob' -BlobDrift;$fixtures.Add($blob.root)|Out-Null
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $blob.workspace 'unit-remat-001' $blob.candidate_path $blob.source_lock_path $blob.map_path $blob.out_path} '*did not preserve the exact predecessor blob*';$assertions++
    $headBranch=New-RematerializationFixture 'head-branch';$fixtures.Add($headBranch.root)|Out-Null;$state=Read-RematerializationTestProtocolJson $headBranch.state_path;$state.repository_heads[0].branch='wrong-predecessor-branch';Write-RematerializationTestJson $headBranch.state_path $state;$candidate=Read-RematerializationTestProtocolJson $headBranch.candidate_path;$candidate.expected.state_sha256=Get-RematerializationTestCanonicalJsonSha256 $state;$candidate.expected.state_raw_sha256=Get-RematerializationTestFileSha256 $headBranch.state_path;Write-RematerializationTestJson $headBranch.candidate_path $candidate
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $headBranch.workspace 'unit-remat-001' $headBranch.candidate_path $headBranch.source_lock_path $headBranch.map_path $headBranch.out_path} '*repository-head predecessor row differs*';$assertions++
    $headDuplicate=New-RematerializationFixture 'head-duplicate';$fixtures.Add($headDuplicate.root)|Out-Null;$state=Read-RematerializationTestProtocolJson $headDuplicate.state_path;$duplicateHead=Copy-RematerializationTestValue $state.repository_heads[0];$duplicateHead.branch='duplicate-predecessor-branch';$state.repository_heads=@($state.repository_heads)+@($duplicateHead);Write-RematerializationTestJson $headDuplicate.state_path $state;$candidate=Read-RematerializationTestProtocolJson $headDuplicate.candidate_path;$candidate.expected.state_sha256=Get-RematerializationTestCanonicalJsonSha256 $state;$candidate.expected.state_raw_sha256=Get-RematerializationTestFileSha256 $headDuplicate.state_path;Write-RematerializationTestJson $headDuplicate.candidate_path $candidate
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $headDuplicate.workspace 'unit-remat-001' $headDuplicate.candidate_path $headDuplicate.source_lock_path $headDuplicate.map_path $headDuplicate.out_path} '*exactly one predecessor repository-head row*';$assertions++
    $selector=New-RematerializationFixture 'selector';$fixtures.Add($selector.root)|Out-Null;$state=Read-RematerializationTestProtocolJson $selector.state_path;$state.normal_validation_selection.selector_sha256='a'*64;Write-RematerializationTestJson $selector.state_path $state;$candidate=Read-RematerializationTestProtocolJson $selector.candidate_path;$candidate.expected.state_sha256=Get-RematerializationTestCanonicalJsonSha256 $state;$candidate.expected.state_raw_sha256=Get-RematerializationTestFileSha256 $selector.state_path;Write-RematerializationTestJson $selector.candidate_path $candidate
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $selector.workspace 'unit-remat-001' $selector.candidate_path $selector.source_lock_path $selector.map_path $selector.out_path} '*invalidated selector differs*';$assertions++
    $qfm=New-RematerializationFixture 'qfm' -RepoId 'rusty-qfm';$fixtures.Add($qfm.root)|Out-Null
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $qfm.workspace 'unit-remat-001' $qfm.candidate_path $qfm.source_lock_path $qfm.map_path $qfm.out_path} '*may not enter product source composition*';$assertions++
    $collision=New-RematerializationFixture 'collision';$fixtures.Add($collision.root)|Out-Null;[IO.File]::WriteAllText($collision.out_path,'preserve',[Text.UTF8Encoding]::new($false))
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $collision.workspace 'unit-remat-001' $collision.candidate_path $collision.source_lock_path $collision.map_path $collision.out_path} '*already occupied*';if([IO.File]::ReadAllText($collision.out_path)-cne'preserve'){throw'Collision changed existing bytes.'};$assertions++
    $id119=New-RematerializationFixture 'id-119';$fixtures.Add($id119.root)|Out-Null;$candidate=Read-RematerializationTestProtocolJson $id119.candidate_path;$candidate.lineage.rematerialization_id='r'*119;Write-RematerializationTestJson $id119.candidate_path $candidate;$id119Dry=Invoke-MorphospaceRematerializeValidatingCandidate $id119.workspace 'unit-remat-001' $id119.candidate_path $id119.source_lock_path $id119.map_path $id119.out_path
    if($id119Dry.transition-cne'validating-candidate-rematerialized'-or$id119Dry.executed){throw'119-character rematerialization identity did not pass dry-run boundary validation.'};$assertions++
    $id120=New-RematerializationFixture 'id-120';$fixtures.Add($id120.root)|Out-Null;$candidate=Read-RematerializationTestProtocolJson $id120.candidate_path;$candidate.lineage.rematerialization_id='r'*120;Write-RematerializationTestJson $id120.candidate_path $candidate
    Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate $id120.workspace 'unit-remat-001' $id120.candidate_path $id120.source_lock_path $id120.map_path $id120.out_path} '*at most 119 characters*';$assertions++
    foreach($rawDrift in @(
        [pscustomobject]@{name='state-raw';path='workspace.state.json';error='*expected pre-state raw SHA-256 does not match*'},
        [pscustomobject]@{name='project-raw';path='project.spec.json';error="*expected additional-projection raw SHA-256 does not match 'project.spec.json'*"},
        [pscustomobject]@{name='feature-raw';path='feature.lock.json';error="*expected additional-projection raw SHA-256 does not match 'feature.lock.json'*"}
    )){
        $raw=New-RematerializationFixture ([string]$rawDrift.name);$fixtures.Add($raw.root)|Out-Null;$rawHash=Get-RematerializationTestFileSha256 $raw.candidate_path;$eventsBefore=Get-RematerializationTestFileSha256 (Join-Path $raw.workspace 'iteration-events.jsonl');$driftPath=Join-Path $raw.workspace ([string]$rawDrift.path)
        Assert-RematerializationThrows {Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $raw.workspace -UnitId 'unit-remat-001' -CandidateFreeze $raw.candidate_path -SourceCompositionLock $raw.source_lock_path -RepoMapPath $raw.map_path -OutPath $raw.out_path -ExpectedCandidateFreezeSha256 $rawHash -Timestamp '2026-09-02T00:02:00.0000000Z' -BeforeTransitionHook {[IO.File]::AppendAllText($driftPath,' ',[Text.UTF8Encoding]::new($false))} -Execute} ([string]$rawDrift.error)
        $intentPath=Join-Path $raw.workspace "receipts\transactions\rematerialize-$([string]$rawDrift.name)-recorded-transition.intent.json"
        $sourceOut=Join-Path $raw.workspace ([string]$raw.new_lock_relative).Replace('/','\')
        if([IO.File]::Exists($raw.out_path)-or[IO.File]::Exists($sourceOut)-or[IO.File]::Exists($intentPath)-or(Get-RematerializationTestFileSha256 (Join-Path $raw.workspace 'iteration-events.jsonl'))-cne$eventsBefore){throw"Raw-only $([string]$rawDrift.name) drift crossed the failure-before-mutation boundary."};$assertions++
    }
    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.validating_candidate_rematerialization_test.v1';result='pass';assertion_count=$assertions;producer_executed=$false;git_mutation_performed_by_action=$false;source_mutated_by_action=$false;build_or_device_used=$false}|ConvertTo-Json -Compress
}finally{
    foreach($root in @($fixtures)){if([IO.Directory]::Exists($root)){Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction SilentlyContinue|ForEach-Object{try{$_.Attributes=$_.Attributes-band(-bnot[IO.FileAttributes]::ReadOnly)}catch{}};Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}}
}
