param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repoRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitSupersession.psm1') -Force -PassThru
$protocol=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force -PassThru
$transition=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force -PassThru

function Assert-ActiveTest([bool]$Condition,[string]$Message){if(-not$Condition){throw "Active-unit supersession self-test failed: $Message"}}
function Write-ActiveJson([string]$Path,[object]$Value){[IO.Directory]::CreateDirectory((Split-Path $Path -Parent))|Out-Null;[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 100)+[char]10),[Text.UTF8Encoding]::new($false))}
function Copy-ActiveTest([object]$Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String}
function Get-ActiveFileHash([string]$Path){&$protocol {param($p)Get-MorphospaceFileSha256 $p} $Path}
function Get-ActiveCanonicalHash([object]$Value){&$protocol {param($v)Get-MorphospaceCanonicalJsonSha256 $v} $Value}
function Read-ActiveJson([string]$Path){&$protocol {param($p)Read-MorphospaceProtocolJson $p} $Path}
function Get-ActiveWorkspaceInventoryHash([string]$Workspace){$root=[IO.Path]::GetFullPath($Workspace);$rows=@(Get-ChildItem -LiteralPath $root -Recurse -File|Sort-Object FullName|ForEach-Object{[pscustomobject][ordered]@{path=[IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/');sha256=Get-ActiveFileHash $_.FullName;length=$_.Length}});Get-ActiveCanonicalHash $rows}
function Invoke-ActivePrivate([scriptblock]$Script,[object[]]$Arguments){&$module $Script $Arguments}
function Invoke-ActiveGit([string]$Path,[string[]]$Arguments){$result=@(& git -C $Path @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "Git fixture command failed: git -C $Path $($Arguments-join' ') $($result-join' ')"};@($result)}

function New-ActiveRequest {
    param([string]$Workspace,[string]$RepoMapPath,[string[]]$CompanionUnitIds=@())
    $project=Read-ActiveJson (Join-Path $Workspace 'project.spec.json')
    $state=Read-ActiveJson (Join-Path $Workspace 'workspace.state.json')
    $old=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionUnitBinding @a} @($Workspace,'unit-old')
    $replacement=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionUnitBinding @a} @($Workspace,'unit-new')
    $events=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionEventsSnapshot @a} @((Join-Path $Workspace 'iteration-events.jsonl'))
    $repoMap=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionRepositoryMap @a} @($RepoMapPath)
    $companionRequests=@();$ownershipUnits=@([pscustomobject]@{unit_id='unit-new';role='replacement';document=$replacement.document;binding=$replacement})
    foreach($id in @($CompanionUnitIds|Sort-Object -CaseSensitive)){
        $binding=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionUnitBinding @a} @($Workspace,$id)
        $companionRequests+=,[ordered]@{unit_id=$id;path=[string]$binding.path;raw_sha256=[string]$binding.raw_sha256;canonical_sha256=[string]$binding.canonical_sha256;status='proposed';lifecycle_effect='preserve-proposed'}
        $ownershipUnits+=,[pscustomobject]@{unit_id=$id;role='companion-overlay-only';document=$binding.document;binding=$binding}
    }
    $repositories=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionRepositoryObservation @a} @($old.document,$ownershipUnits,$repoMap.map)
    [ordered]@{
        schema='rusty.morphospace.workflow.active_unit_supersession.v1'
        supersession_id='unit-old-superseded-by-unit-new'
        project_id='active-supersession-test'
        old_unit=[ordered]@{unit_id='unit-old';path=[string]$old.path;raw_sha256=[string]$old.raw_sha256;canonical_sha256=[string]$old.canonical_sha256;status='active'}
        replacement_unit=[ordered]@{unit_id='unit-new';path=[string]$replacement.path;raw_sha256=[string]$replacement.raw_sha256;canonical_sha256=[string]$replacement.canonical_sha256;status='proposed'}
        companion_units=@($companionRequests)
        expected=[ordered]@{
            project_raw_sha256=Get-ActiveFileHash (Join-Path $Workspace 'project.spec.json')
            project_canonical_sha256=Get-ActiveCanonicalHash $project
            state_raw_sha256=Get-ActiveFileHash (Join-Path $Workspace 'workspace.state.json')
            state_canonical_sha256=Get-ActiveCanonicalHash $state
            events_sha256=[string]$events.sha256
            events_length=[int64]$events.length
            event_tail_id=[string]$events.tail_id
            repository_map_sha256=Get-ActiveFileHash $RepoMapPath
        }
        repositories=@($repositories)
        does_not_authorize=@('This request changes only workflow lifecycle ownership; it authorizes no acceptance, source edit, build, device, Git, remote, or publication action.')
    }
}

function Copy-ActiveWorkspace([string]$Template,[string]$Root,[string]$Name){$target=Join-Path $Root $Name;Copy-Item -LiteralPath $Template -Destination $target -Recurse;return $target}

function New-ActiveUnit([string]$UnitId,[string]$Status,[object[]]$AllowedRepositories){
    [ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id=$UnitId;project_id='active-supersession-test';status=$Status
        objective="Exercise exact active-unit supersession for $UnitId.";change_categories=@('implementation')
        instruction_impact='none';instruction_surfaces=@();instruction_none_justification='The synthetic fixture changes no instruction surface.'
        prerequisites=@();allowed_repositories=@($AllowedRepositories);non_scope=@('Real product, publication, build, or device work.')
        acceptance=@([ordered]@{acceptance_id='self-test';proof='The focused synthetic contract passes.';command='Test-ActiveUnitSupersession.ps1 -SelfTest'})
        risk_tier='quick';device_requirement='none';validation=@([ordered]@{profile_id='quick';command='Test-ActiveUnitSupersession.ps1 -SelfTest'})
        outputs=@('One exact transaction receipt.');commit_policy='Synthetic fixture only.';push_checkpoint='none'
    }
}

function Assert-ActiveRejects {
    param([string]$Workspace,[string]$Message,[string]$Expected='*')
    $requestPath=Join-Path $Workspace 'receipts\unit-old-superseded-by-unit-new-request.json'
    $repoMapPath=Join-Path $Workspace 'repository-map.json'
    $outPath=Join-Path $Workspace 'receipts\unit-old-superseded-by-unit-new-automation.json'
    $before=@{}
    $preserved=@('project.spec.json','workspace.state.json','iteration-events.jsonl')+@([IO.Directory]::EnumerateFiles((Join-Path $Workspace 'iteration-units'),'*.json',[IO.SearchOption]::TopDirectoryOnly)|ForEach-Object{[IO.Path]::GetRelativePath($Workspace,$_).Replace('\','/')})
    foreach($path in $preserved){$before[$path]=Get-ActiveFileHash (Join-Path $Workspace $path)}
    $rejected=$false;$text=''
    try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $Workspace -UnitId unit-new -RepoMapPath $repoMapPath -ActiveUnitSupersession $requestPath -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $requestPath) -OutPath $outPath -Timestamp '2026-09-01T00:02:00.0000000Z' -Execute|Out-Null}catch{$rejected=$true;$text=$_.Exception.Message}
    Assert-ActiveTest ($rejected-and$text-like$Expected) "$Message was not rejected: $text"
    foreach($path in $before.Keys){Assert-ActiveTest ((Get-ActiveFileHash (Join-Path $Workspace $path))-ceq$before[$path]) "$Message changed $path"}
}

if(-not$SelfTest){throw 'Test-ActiveUnitSupersession requires -SelfTest.'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-active-supersession-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
try{
    $source=Join-Path $temp 'source'
    [IO.Directory]::CreateDirectory((Join-Path $source 'src'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'src\feature.rs'),("baseline"+[char]10),[Text.UTF8Encoding]::new($false))
    Invoke-ActiveGit $source @('init')|Out-Null
    Invoke-ActiveGit $source @('config','user.email','fixture@example.invalid')|Out-Null
    Invoke-ActiveGit $source @('config','user.name','Fixture')|Out-Null
    Invoke-ActiveGit $source @('add','src/feature.rs')|Out-Null
    Invoke-ActiveGit $source @('commit','-m','fixture')|Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'src\feature.rs'),("candidate overlay"+[char]10),[Text.UTF8Encoding]::new($false))

    $template=Join-Path $temp 'workspace-template'
    [IO.Directory]::CreateDirectory((Join-Path $template 'iteration-units'))|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $template 'receipts'))|Out-Null
    $project=[ordered]@{schema='test';project_id='active-supersession-test'}
    $state=[ordered]@{schema='test';project_id='active-supersession-test';current_unit='unit-old';next_ready_unit='unit-new';normal_validation_selection=$null;last_event_id='unit-old-claimed-0001'}
    $scope=@([ordered]@{repo_id='source-repo';allowed_paths=@('src/feature.rs')})
    $old=New-ActiveUnit 'unit-old' 'active' $scope
    $replacement=New-ActiveUnit 'unit-new' 'proposed' $scope
    $seed=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-old-claimed-0001';sequence=1;timestamp='2026-09-01T00:01:00.0000000Z';project_id='active-supersession-test';unit_id='unit-old';event_type='state-transition';summary='Established the exact active predecessor fixture.';receipts=@()}
    Write-ActiveJson (Join-Path $template 'project.spec.json') $project
    Write-ActiveJson (Join-Path $template 'workspace.state.json') $state
    Write-ActiveJson (Join-Path $template 'iteration-units\unit-old.json') $old
    Write-ActiveJson (Join-Path $template 'iteration-units\unit-new.json') $replacement
    [IO.File]::WriteAllText((Join-Path $template 'iteration-events.jsonl'),(($seed|ConvertTo-Json -Compress)+[char]10),[Text.UTF8Encoding]::new($false))
    $templateRepoMap=Join-Path $template 'repository-map.json'
    Write-ActiveJson $templateRepoMap ([ordered]@{'$schema'='fixture';schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='source-repo';path=$source;role='source'})})
    $request=New-ActiveRequest $template $templateRepoMap
    $templateRequest=Join-Path $template 'receipts\unit-old-superseded-by-unit-new-request.json'
    Write-ActiveJson $templateRequest $request
    Assert-ActiveTest (Test-Json -Json (Get-Content -Raw $templateRequest) -SchemaFile (Join-Path $repoRoot 'schemas\active-unit-supersession-v1.schema.json')) 'request schema rejected the exact fixture'

    $legacyWorkspace=Copy-ActiveWorkspace $template $temp 'v1-v2-state-without-selector-property';$legacyStatePath=Join-Path $legacyWorkspace 'workspace.state.json';$legacyState=Read-ActiveJson $legacyStatePath;$legacyState.PSObject.Properties.Remove('normal_validation_selection');Write-ActiveJson $legacyStatePath $legacyState;$legacyRepoMapPath=Join-Path $legacyWorkspace 'repository-map.json';$legacyRequestPath=Join-Path $legacyWorkspace 'receipts\unit-old-superseded-by-unit-new-request.json';Write-ActiveJson $legacyRequestPath (New-ActiveRequest $legacyWorkspace $legacyRepoMapPath);$legacyOutPath=Join-Path $legacyWorkspace 'receipts\unit-old-superseded-by-unit-new-automation.json';$legacyBefore=Get-ActiveWorkspaceInventoryHash $legacyWorkspace;$legacyDry=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $legacyWorkspace -UnitId unit-new -RepoMapPath $legacyRepoMapPath -ActiveUnitSupersession $legacyRequestPath -OutPath $legacyOutPath -Timestamp '2026-09-01T00:02:00.0000000Z';$legacyAfterState=Read-ActiveJson $legacyStatePath;Assert-ActiveTest (-not$legacyDry.executed-and-not(Test-Path $legacyOutPath)-and$null-eq$legacyAfterState.PSObject.Properties['normal_validation_selection']-and(Get-ActiveWorkspaceInventoryHash $legacyWorkspace)-ceq$legacyBefore) 'v1/v2 state without the optional normal-validation selector did not dry-run compatibly without writes';$legacyOldPath=Join-Path $legacyWorkspace 'iteration-units\unit-old.json';$legacyOldBefore=Get-ActiveFileHash $legacyOldPath;$legacyProjectBefore=Get-ActiveFileHash (Join-Path $legacyWorkspace 'project.spec.json');$legacySourceBefore=Get-ActiveFileHash (Join-Path $source 'src\feature.rs');$legacyRun=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $legacyWorkspace -UnitId unit-new -RepoMapPath $legacyRepoMapPath -ActiveUnitSupersession $legacyRequestPath -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $legacyRequestPath) -OutPath $legacyOutPath -Timestamp '2026-09-01T00:02:00.0000000Z' -Execute;$legacyCommittedState=Read-ActiveJson $legacyStatePath;$legacyCommittedReplacement=Read-ActiveJson (Join-Path $legacyWorkspace 'iteration-units\unit-new.json');Assert-ActiveTest ($legacyRun.executed-and[string]$legacyCommittedState.current_unit-ceq'unit-new'-and$null-eq$legacyCommittedState.PSObject.Properties['normal_validation_selection']-and[string]$legacyCommittedReplacement.status-ceq'active'-and(Get-ActiveFileHash $legacyOldPath)-ceq$legacyOldBefore-and(Get-ActiveFileHash (Join-Path $legacyWorkspace 'project.spec.json'))-ceq$legacyProjectBefore-and(Get-ActiveFileHash (Join-Path $source 'src\feature.rs'))-ceq$legacySourceBefore) 'v1/v2 state without the optional normal-validation selector did not execute while preserving old-unit, project, source, and omitted-property state'
    foreach($selectorCase in @([pscustomobject]@{name='malformed-string';value='malformed-selector'},[pscustomobject]@{name='empty-object';value=[pscustomobject]@{}},[pscustomobject]@{name='empty-array';value=[object[]]@()},[pscustomobject]@{name='conflicting-object';value=[pscustomobject][ordered]@{unit_id='unit-other';unit_raw_sha256='a'*64;unit_contract_sha256='b'*64;tier='quick';selector_id='selector-other';selector_path='validation-authority/selectors/selector-other.json';selector_sha256='c'*64;evidence_path_sha256='d'*64}})){$selectorRoot=Copy-ActiveWorkspace $template $temp "selector-$([string]$selectorCase.name)";$selectorStatePath=Join-Path $selectorRoot 'workspace.state.json';$selectorState=Read-ActiveJson $selectorStatePath;$selectorState.normal_validation_selection=$selectorCase.value;Write-ActiveJson $selectorStatePath $selectorState;$selectorBefore=Get-ActiveWorkspaceInventoryHash $selectorRoot;$selectorSourceBefore=Get-ActiveFileHash (Join-Path $source 'src\feature.rs');$selectorRejected=$false;$selectorReason='';try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $selectorRoot -UnitId unit-new -RepoMapPath (Join-Path $selectorRoot 'repository-map.json') -ActiveUnitSupersession (Join-Path $selectorRoot 'receipts\unit-old-superseded-by-unit-new-request.json') -OutPath (Join-Path $selectorRoot 'receipts\unit-old-superseded-by-unit-new-automation.json') -Timestamp '2026-09-01T00:02:00.0000000Z'|Out-Null}catch{$selectorRejected=$true;$selectorReason=$_.Exception.Message};Assert-ActiveTest ($selectorRejected-and$selectorReason-like'*refuses to orphan a normal-validation selector binding*'-and(Get-ActiveWorkspaceInventoryHash $selectorRoot)-ceq$selectorBefore-and(Get-ActiveFileHash (Join-Path $source 'src\feature.rs'))-ceq$selectorSourceBefore) "supersession accepted or wrote during $([string]$selectorCase.name) normal-validation selection damage: $selectorReason"}

    $workspace=Copy-ActiveWorkspace $template $temp 'positive'
    $repoMapPath=Join-Path $workspace 'repository-map.json'
    $requestPath=Join-Path $workspace 'receipts\unit-old-superseded-by-unit-new-request.json'
    $requestHash=Get-ActiveFileHash $requestPath
    $outPath=Join-Path $workspace 'receipts\unit-old-superseded-by-unit-new-automation.json'
    $beforeState=Get-ActiveFileHash (Join-Path $workspace 'workspace.state.json')
    $beforeOld=Get-ActiveFileHash (Join-Path $workspace 'iteration-units\unit-old.json')
    $dry=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $workspace -UnitId unit-new -RepoMapPath $repoMapPath -ActiveUnitSupersession $requestPath -OutPath $outPath -Timestamp '2026-09-01T00:02:00.0000000Z'
    Assert-ActiveTest (-not$dry.executed-and-not(Test-Path $outPath)-and(Get-ActiveFileHash (Join-Path $workspace 'workspace.state.json'))-ceq$beforeState) 'dry-run mutated the workspace'
    $wrapperJson=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action SupersedeActive -WorkspaceRoot $workspace -UnitId unit-new -RepoMapPath $repoMapPath -ActiveUnitSupersession $requestPath -OutPath $outPath -Timestamp '2026-09-01T00:02:00.0000000Z'
    $wrapper=$wrapperJson|ConvertFrom-Json -DateKind String
    Assert-ActiveTest ([string]$wrapper.action-ceq'SupersedeActive'-and-not$wrapper.executed) 'normal consumer wrapper did not route a non-mutating SupersedeActive dry-run'

    $run=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $workspace -UnitId unit-new -RepoMapPath $repoMapPath -ActiveUnitSupersession $requestPath -ExpectedActiveUnitSupersessionSha256 $requestHash -OutPath $outPath -Timestamp '2026-09-01T00:02:00.0000000Z' -Execute
    $liveState=Read-ActiveJson (Join-Path $workspace 'workspace.state.json')
    $liveOld=Read-ActiveJson (Join-Path $workspace 'iteration-units\unit-old.json')
    $liveNew=Read-ActiveJson (Join-Path $workspace 'iteration-units\unit-new.json')
    $events=@(Get-Content (Join-Path $workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    $committed=&$transition {param($w)Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $w -TransactionId 'unit-old-superseded-by-unit-new-transition' -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath 'iteration-units/unit-new.json' -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail} $workspace
    Assert-ActiveTest ($run.executed-and[string]$liveState.current_unit-ceq'unit-new'-and$null-eq$liveState.next_ready_unit-and[string]$liveNew.status-ceq'active') 'execute did not atomically activate the proposed replacement'
    Assert-ActiveTest ((Get-ActiveFileHash (Join-Path $workspace 'iteration-units\unit-old.json'))-ceq$beforeOld-and[string]$liveOld.status-ceq'active') 'execute did not preserve immutable old-unit evidence'
    Assert-ActiveTest ([string]$events[-1].unit_id-ceq'unit-old'-and[string]$events[-1].event_id-ceq'unit-old-superseded-by-unit-new'-and[string]$committed.intent.schema-ceq'rusty.morphospace.workflow.transition_ledger_intent.v2') 'execute lacks the authenticated v2 supersession edge'
    Assert-ActiveTest ([string](Read-ActiveJson $outPath).audit_receipt.sha256-ceq$requestHash) 'transaction-owned receipt does not bind the reviewed request'
    $completedReplayPreimage=[pscustomobject][ordered]@{state=Get-ActiveFileHash (Join-Path $workspace 'workspace.state.json');old=Get-ActiveFileHash (Join-Path $workspace 'iteration-units\unit-old.json');replacement=Get-ActiveFileHash (Join-Path $workspace 'iteration-units\unit-new.json');events=Get-ActiveFileHash (Join-Path $workspace 'iteration-events.jsonl');receipt=Get-ActiveFileHash $outPath}
    $dryReplay=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $workspace -UnitId unit-new -RepoMapPath $repoMapPath -ActiveUnitSupersession $requestPath -ExpectedActiveUnitSupersessionSha256 $requestHash -OutPath $outPath -Timestamp '2026-09-01T00:08:00.0000000Z'
    Assert-ActiveTest (-not$dryReplay.executed-and$null-eq$dryReplay.event_id-and[string]$dryReplay.timestamp-ceq[string]$run.timestamp-and[string]$dryReplay.transition-ceq'active-superseded-by-proposed-to-active') 'completed no-Execute replay falsely claimed execution or lost the original transaction identity'
    Assert-ActiveTest ((Get-ActiveFileHash (Join-Path $workspace 'workspace.state.json'))-ceq[string]$completedReplayPreimage.state-and(Get-ActiveFileHash (Join-Path $workspace 'iteration-units\unit-old.json'))-ceq[string]$completedReplayPreimage.old-and(Get-ActiveFileHash (Join-Path $workspace 'iteration-units\unit-new.json'))-ceq[string]$completedReplayPreimage.replacement-and(Get-ActiveFileHash (Join-Path $workspace 'iteration-events.jsonl'))-ceq[string]$completedReplayPreimage.events-and(Get-ActiveFileHash $outPath)-ceq[string]$completedReplayPreimage.receipt) 'completed no-Execute replay changed committed workspace or receipt bytes'
    $replay=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $workspace -UnitId unit-new -RepoMapPath $repoMapPath -ActiveUnitSupersession $requestPath -ExpectedActiveUnitSupersessionSha256 $requestHash -OutPath $outPath -Timestamp '2026-09-01T00:09:00.0000000Z' -Execute
    Assert-ActiveTest ($replay.executed-and[string]$replay.timestamp-ceq[string]$run.timestamp-and[string]$replay.event_id-ceq[string]$run.event_id) 'committed replay did not return the exact original transaction receipt'
    $historicalReplayEvents=Get-ActiveFileHash (Join-Path $workspace 'iteration-events.jsonl');$historicalReplaySource=Join-Path $source 'src\feature.rs';$historicalReplaySourceBytes=[IO.File]::ReadAllBytes($historicalReplaySource)
    try{
        [IO.File]::AppendAllText($historicalReplaySource,"post-commit dirt`n",[Text.UTF8Encoding]::new($false))
        $historicalReplay=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $workspace -UnitId unit-new -RepoMapPath $repoMapPath -ActiveUnitSupersession $requestPath -ExpectedActiveUnitSupersessionSha256 $requestHash -OutPath $outPath -Timestamp '2026-09-01T00:10:00.0000000Z' -Execute
        Assert-ActiveTest ($historicalReplay.executed-and[string]$historicalReplay.timestamp-ceq[string]$run.timestamp-and(Get-ActiveFileHash (Join-Path $workspace 'iteration-events.jsonl'))-ceq$historicalReplayEvents) 'committed replay depended on current repository dirt or appended another event'
    }finally{[IO.File]::WriteAllBytes($historicalReplaySource,$historicalReplaySourceBytes)}

    # Study 6-shaped positive: one repository has 73 replacement-owned paths
    # and nine companion-owned paths; a second old-scope repository is omitted
    # by both successors and must be observed clean.
    $partitionSource=Join-Path $temp 'partition-source';$cleanSource=Join-Path $temp 'omitted-clean-source'
    [IO.Directory]::CreateDirectory($partitionSource)|Out-Null;[IO.Directory]::CreateDirectory($cleanSource)|Out-Null
    $replacementPaths=@(1..73|ForEach-Object{"replacement/path-$('{0:d3}'-f$_).txt"});$companionPaths=@(1..9|ForEach-Object{"companion/path-$('{0:d3}'-f$_).txt"})
    foreach($path in @($replacementPaths)+@($companionPaths)){ $absolute=Join-Path $partitionSource $path;[IO.Directory]::CreateDirectory((Split-Path $absolute -Parent))|Out-Null;[IO.File]::WriteAllText($absolute,"base`n",[Text.UTF8Encoding]::new($false)) }
    Invoke-ActiveGit $partitionSource @('init')|Out-Null;Invoke-ActiveGit $partitionSource @('config','user.email','fixture@example.invalid')|Out-Null;Invoke-ActiveGit $partitionSource @('config','user.name','Fixture')|Out-Null;Invoke-ActiveGit $partitionSource @('add','.')|Out-Null;Invoke-ActiveGit $partitionSource @('commit','-m','partition-base')|Out-Null
    foreach($path in @($replacementPaths)+@($companionPaths)){[IO.File]::AppendAllText((Join-Path $partitionSource $path),"candidate`n",[Text.UTF8Encoding]::new($false))}
    [IO.File]::WriteAllText((Join-Path $cleanSource 'clean.txt'),"clean`n",[Text.UTF8Encoding]::new($false));Invoke-ActiveGit $cleanSource @('init')|Out-Null;Invoke-ActiveGit $cleanSource @('config','user.email','fixture@example.invalid')|Out-Null;Invoke-ActiveGit $cleanSource @('config','user.name','Fixture')|Out-Null;Invoke-ActiveGit $cleanSource @('add','.')|Out-Null;Invoke-ActiveGit $cleanSource @('commit','-m','clean-base')|Out-Null
    $partition=Join-Path $temp 'partition-workspace';[IO.Directory]::CreateDirectory((Join-Path $partition 'iteration-units'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $partition 'receipts'))|Out-Null
    Write-ActiveJson (Join-Path $partition 'project.spec.json') $project;Write-ActiveJson (Join-Path $partition 'workspace.state.json') $state
    $partitionOld=Copy-ActiveTest $old;$partitionOld.allowed_repositories=@([ordered]@{repo_id='source-repo';allowed_paths=@('replacement/','companion/')},[ordered]@{repo_id='omitted-repo';allowed_paths=@('clean.txt')})
    $partitionReplacement=Copy-ActiveTest $replacement;$partitionReplacement.allowed_repositories=@([ordered]@{repo_id='source-repo';allowed_paths=$replacementPaths})
    $partitionCompanion=Copy-ActiveTest $replacement;$partitionCompanion.unit_id='unit-companion';$partitionCompanion.allowed_repositories=@([ordered]@{repo_id='source-repo';allowed_paths=$companionPaths})
    Write-ActiveJson (Join-Path $partition 'iteration-units\unit-old.json') $partitionOld;Write-ActiveJson (Join-Path $partition 'iteration-units\unit-new.json') $partitionReplacement;Write-ActiveJson (Join-Path $partition 'iteration-units\unit-companion.json') $partitionCompanion
    [IO.File]::WriteAllText((Join-Path $partition 'iteration-events.jsonl'),(($seed|ConvertTo-Json -Compress)+[char]10),[Text.UTF8Encoding]::new($false))
    $partitionMap=Join-Path $partition 'repository-map.json';Write-ActiveJson $partitionMap ([ordered]@{'$schema'='fixture';schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='source-repo';path=$partitionSource;role='source'},[ordered]@{repo_id='omitted-repo';path=$cleanSource;role='source'})})
    $partitionRequest=New-ActiveRequest $partition $partitionMap @('unit-companion');$partitionRequestPath=Join-Path $partition 'receipts\unit-old-superseded-by-unit-new-request.json';Write-ActiveJson $partitionRequestPath $partitionRequest
    Assert-ActiveTest (Test-Json -Json (Get-Content -Raw $partitionRequestPath) -SchemaFile (Join-Path $repoRoot 'schemas\active-unit-supersession-v1.schema.json')) 'companion partition request schema failed'
    $ownedRow=@($partitionRequest.repositories|Where-Object{[string]$_.repo_id-ceq'source-repo'})[0];$omittedRow=@($partitionRequest.repositories|Where-Object{[string]$_.repo_id-ceq'omitted-repo'})[0]
    Assert-ActiveTest (@($ownedRow.overlay|Where-Object{[string]$_.owner_unit_id-ceq'unit-new'}).Count-eq73-and@($ownedRow.overlay|Where-Object{[string]$_.owner_unit_id-ceq'unit-companion'}).Count-eq9-and[string]$omittedRow.scope_disposition-ceq'omitted-clean'-and@($omittedRow.overlay).Count-eq0) '73+9 overlay partition or omitted-clean observation is not exact'
    $partitionTemplate=Join-Path $temp 'partition-template';Copy-Item -LiteralPath $partition -Destination $partitionTemplate -Recurse
    function New-PartitionRecoveryCase([string]$Name){
        $root=Copy-ActiveWorkspace $partitionTemplate $temp $Name;$sourceCopy=Join-Path $temp "$Name-source";$cleanCopy=Join-Path $temp "$Name-clean"
        Copy-Item -LiteralPath $partitionSource -Destination $sourceCopy -Recurse;Copy-Item -LiteralPath $cleanSource -Destination $cleanCopy -Recurse
        $mapPath=Join-Path $root 'repository-map.json';Write-ActiveJson $mapPath ([ordered]@{'$schema'='fixture';schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='source-repo';path=$sourceCopy;role='source'},[ordered]@{repo_id='omitted-repo';path=$cleanCopy;role='source'})})
        $request=New-ActiveRequest $root $mapPath @('unit-companion');$requestPath=Join-Path $root 'receipts\unit-old-superseded-by-unit-new-request.json';Write-ActiveJson $requestPath $request
        [pscustomobject]@{root=$root;source=$sourceCopy;clean=$cleanCopy;map=$mapPath;request=$requestPath;out=(Join-Path $root 'receipts\unit-old-superseded-by-unit-new-automation.json')}
    }
    $companionBefore=Get-ActiveFileHash (Join-Path $partition 'iteration-units\unit-companion.json');$partitionOut=Join-Path $partition 'receipts\unit-old-superseded-by-unit-new-automation.json'
    $partitionRun=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $partition -UnitId unit-new -RepoMapPath $partitionMap -ActiveUnitSupersession $partitionRequestPath -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $partitionRequestPath) -OutPath $partitionOut -Timestamp '2026-09-01T00:02:00.0000000Z' -Execute
    $partitionCompanionAfter=Read-ActiveJson (Join-Path $partition 'iteration-units\unit-companion.json');$partitionIntent=Read-ActiveJson (Join-Path $partition 'receipts\transactions\unit-old-superseded-by-unit-new-transition.intent.json')
    Assert-ActiveTest ($partitionRun.executed-and(Get-ActiveFileHash (Join-Path $partition 'iteration-units\unit-companion.json'))-ceq$companionBefore-and[string]$partitionCompanionAfter.status-ceq'proposed'-and[string]$partitionIntent.unit.path-ceq'iteration-units/unit-new.json'-and[string]$partitionIntent.target.unit.document.unit_id-ceq'unit-new') 'companion gained lifecycle authority or changed during supersession'

    foreach($case in @('missing-current','old-status','replacement-status','replacement-schema','source-widening','state-drift','ledger-drift','collision')){
        $root=Copy-ActiveWorkspace $template $temp "case-$case"
        if($case-ceq'missing-current'){$doc=Read-ActiveJson (Join-Path $root 'workspace.state.json');$doc.current_unit=$null;Write-ActiveJson (Join-Path $root 'workspace.state.json') $doc}
        elseif($case-ceq'old-status'){$doc=Read-ActiveJson (Join-Path $root 'iteration-units\unit-old.json');$doc.status='blocked';Write-ActiveJson (Join-Path $root 'iteration-units\unit-old.json') $doc}
        elseif($case-ceq'replacement-status'){$doc=Read-ActiveJson (Join-Path $root 'iteration-units\unit-new.json');$doc.status='ready';Write-ActiveJson (Join-Path $root 'iteration-units\unit-new.json') $doc}
        elseif($case-ceq'replacement-schema'){$doc=Read-ActiveJson (Join-Path $root 'iteration-units\unit-new.json');$doc.objective='';Write-ActiveJson (Join-Path $root 'iteration-units\unit-new.json') $doc}
        elseif($case-ceq'source-widening'){$doc=Read-ActiveJson (Join-Path $root 'iteration-units\unit-new.json');$doc.allowed_repositories[0].allowed_paths=@('src/other.rs');Write-ActiveJson (Join-Path $root 'iteration-units\unit-new.json') $doc}
        elseif($case-ceq'state-drift'){$doc=Read-ActiveJson (Join-Path $root 'workspace.state.json');$doc.last_event_id='drifted-event';Write-ActiveJson (Join-Path $root 'workspace.state.json') $doc}
        elseif($case-ceq'ledger-drift'){[IO.File]::AppendAllText((Join-Path $root 'iteration-events.jsonl'),[string][char]10,[Text.UTF8Encoding]::new($false))}
        else{[IO.File]::WriteAllText((Join-Path $root 'receipts\unit-old-superseded-by-unit-new-automation.json'),'occupied',[Text.UTF8Encoding]::new($false))}
        Assert-ActiveRejects $root $case $(if($case-ceq'replacement-schema'){'*iteration-unit schema*'}else{'*'})
    }

    foreach($case in @('companion-omitted','companion-owner-tamper','companion-raw-drift','companion-status','companion-schema','companion-project','companion-duplicate','omitted-row-missing')){
        $root=Copy-ActiveWorkspace $partitionTemplate $temp "case-$case";$requestFile=Join-Path $root 'receipts\unit-old-superseded-by-unit-new-request.json'
        if($case-ceq'companion-raw-drift'){[IO.File]::AppendAllText((Join-Path $root 'iteration-units\unit-companion.json')," `n",[Text.UTF8Encoding]::new($false))}
        elseif($case-ceq'companion-status'){$doc=Read-ActiveJson (Join-Path $root 'iteration-units\unit-companion.json');$doc.status='ready';Write-ActiveJson (Join-Path $root 'iteration-units\unit-companion.json') $doc}
        elseif($case-ceq'companion-schema'){$doc=Read-ActiveJson (Join-Path $root 'iteration-units\unit-companion.json');$doc.objective='';Write-ActiveJson (Join-Path $root 'iteration-units\unit-companion.json') $doc}
        elseif($case-ceq'companion-project'){$doc=Read-ActiveJson (Join-Path $root 'iteration-units\unit-companion.json');$doc.project_id='other-project';Write-ActiveJson (Join-Path $root 'iteration-units\unit-companion.json') $doc}
        else{
            $doc=Read-ActiveJson $requestFile
            if($case-ceq'companion-omitted'){$doc.companion_units=@()}
            elseif($case-ceq'companion-owner-tamper'){$sourceRow=@($doc.repositories|Where-Object{[string]$_.repo_id-ceq'source-repo'})[0];$ownerTargets=@($sourceRow.overlay|Where-Object{[string]$_.path-ceq[string]$replacementPaths[0]-and[string]$_.owner_unit_id-ceq'unit-new'});Assert-ActiveTest ($ownerTargets.Count-eq1) 'owner-tamper fixture did not resolve exactly one replacement-owned overlay row';$ownerTargets[0].owner_unit_id='unit-companion'}
            elseif($case-ceq'companion-duplicate'){$doc.companion_units=@($doc.companion_units)+@($doc.companion_units)}
            else{$doc.repositories=@($doc.repositories|Where-Object{[string]$_.repo_id-cne'omitted-repo'})}
            Write-ActiveJson $requestFile $doc
        }
        Assert-ActiveRejects $root $case $(if($case-ceq'companion-schema'){'*iteration-unit schema*'}else{'*'})
    }

    $partitionOldBinding=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionUnitBinding @a} @($partitionTemplate,'unit-old');$partitionNewBinding=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionUnitBinding @a} @($partitionTemplate,'unit-new');$partitionCompanionBinding=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionUnitBinding @a} @($partitionTemplate,'unit-companion');$partitionRepoMap=Invoke-ActivePrivate {param($a)Get-ActiveSupersessionRepositoryMap @a} @((Join-Path $partitionTemplate 'repository-map.json'))
    $partitionOwners=@([pscustomobject]@{unit_id='unit-new';role='replacement';document=$partitionNewBinding.document;binding=$partitionNewBinding},[pscustomobject]@{unit_id='unit-companion';role='companion-overlay-only';document=$partitionCompanionBinding.document;binding=$partitionCompanionBinding})
    [IO.File]::AppendAllText((Join-Path $cleanSource 'clean.txt'),"dirty`n",[Text.UTF8Encoding]::new($false));$omittedDirtyRejected=$false;try{Invoke-ActivePrivate {param($a)Get-ActiveSupersessionRepositoryObservation @a} @($partitionOldBinding.document,$partitionOwners,$partitionRepoMap.map)|Out-Null}catch{$omittedDirtyRejected=$_.Exception.Message-like'*omitted repository*not clean*'}finally{[IO.File]::WriteAllText((Join-Path $cleanSource 'clean.txt'),"clean`n",[Text.UTF8Encoding]::new($false))}
    Assert-ActiveTest $omittedDirtyRejected 'dirty omitted old-scope repository was accepted'
    $overlapCompanion=Copy-ActiveTest $partitionCompanionBinding.document;$overlapCompanion.allowed_repositories[0].allowed_paths=@($overlapCompanion.allowed_repositories[0].allowed_paths)+$replacementPaths[0]
    $overlapRejected=$false;try{Invoke-ActivePrivate {param($a)Get-ActiveSupersessionRepositoryObservation @a} @($partitionOldBinding.document,@([pscustomobject]@{unit_id='unit-new';role='replacement';document=$partitionNewBinding.document},[pscustomobject]@{unit_id='unit-companion';role='companion-overlay-only';document=$overlapCompanion}),$partitionRepoMap.map)|Out-Null}catch{$overlapRejected=$_.Exception.Message-like'*ownership scopes overlap*'}
    Assert-ActiveTest $overlapRejected 'cross-unit overlapping scope was accepted'
    $emptyCompanion=Copy-ActiveTest $partitionCompanionBinding.document;$emptyCompanion.unit_id='unit-empty-companion';$emptyCompanion.allowed_repositories=@([ordered]@{repo_id='omitted-repo';allowed_paths=@('clean.txt')})
    $emptyOwners=[object[]](@($partitionOwners)+@([pscustomobject]@{unit_id='unit-empty-companion';role='companion-overlay-only';document=$emptyCompanion}));$emptyArguments=[object[]]@($partitionOldBinding.document,[pscustomobject]@{units=$emptyOwners},$partitionRepoMap.map)
    $emptyRejected=$false;$emptyReason='';try{Invoke-ActivePrivate {param($a);if(@($a).Count-ne3){throw "empty-companion fixture call shape has $(@($a).Count) arguments"};$units=[object[]]@($a[1].units);if($units.Count-ne3-or@($units|Where-Object{[string]$_.unit_id-ceq'unit-empty-companion'-and[string]$_.role-ceq'companion-overlay-only'}).Count-ne1){throw 'empty-companion fixture ownership-unit shape is invalid'};$omittedState=Get-MorphospaceRepositoryState -RepoId 'omitted-repo' -Path ([string]$a[2]['omitted-repo'].path);if(@($omittedState.status_porcelain).Count-ne0){throw 'empty-companion fixture unexpectedly has omitted-repository overlay rows'};Get-ActiveSupersessionRepositoryObservation -OldUnit $a[0] -OwnershipUnits $units -RepositoryMap $a[2]} $emptyArguments|Out-Null}catch{$emptyReason=$_.Exception.Message;$emptyRejected=$emptyReason-like'*owns no dirty overlay path*'}
    Assert-ActiveTest $emptyRejected "companion with no dirty overlay ownership was accepted or the fixture shape was invalid: $emptyReason"

    $renameSource=Join-Path $temp 'rename-source';[IO.Directory]::CreateDirectory((Join-Path $renameSource 'replacement'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $renameSource 'companion'))|Out-Null;[IO.File]::WriteAllText((Join-Path $renameSource 'replacement\old.txt'),"old`n",[Text.UTF8Encoding]::new($false));Invoke-ActiveGit $renameSource @('init')|Out-Null;Invoke-ActiveGit $renameSource @('config','user.email','fixture@example.invalid')|Out-Null;Invoke-ActiveGit $renameSource @('config','user.name','Fixture')|Out-Null;Invoke-ActiveGit $renameSource @('add','.')|Out-Null;Invoke-ActiveGit $renameSource @('commit','-m','rename-base')|Out-Null;Invoke-ActiveGit $renameSource @('mv','replacement/old.txt','companion/new.txt')|Out-Null
    $renameMap=@{'source-repo'=[pscustomobject]@{repo_id='source-repo';path=$renameSource;role='source'}};$renameOld=[pscustomobject]@{allowed_repositories=@([pscustomobject]@{repo_id='source-repo';allowed_paths=@('replacement/','companion/')})};$renameReplacement=[pscustomobject]@{allowed_repositories=@([pscustomobject]@{repo_id='source-repo';allowed_paths=@('replacement/old.txt')})};$renameCompanion=[pscustomobject]@{allowed_repositories=@([pscustomobject]@{repo_id='source-repo';allowed_paths=@('companion/new.txt')})}
    $crossRenameRejected=$false;try{Invoke-ActivePrivate {param($a)Get-ActiveSupersessionRepositoryObservation @a} @($renameOld,@([pscustomobject]@{unit_id='unit-new';role='replacement';document=$renameReplacement},[pscustomobject]@{unit_id='unit-companion';role='companion-overlay-only';document=$renameCompanion}),$renameMap)|Out-Null}catch{$crossRenameRejected=$_.Exception.Message-like'*rename whose endpoints have different owners*'}
    Assert-ActiveTest $crossRenameRejected 'rename crossing replacement and companion ownership was accepted'

    $rawDrift=Copy-ActiveWorkspace $template $temp 'case-raw-drift'
    $rawRequestPath=Join-Path $rawDrift 'receipts\unit-old-superseded-by-unit-new-request.json'
    $rawRequest=Read-ActiveJson $rawRequestPath;$rawRequest.old_unit.raw_sha256='0'*64;Write-ActiveJson $rawRequestPath $rawRequest
    Assert-ActiveRejects $rawDrift 'old raw-byte drift' '*old unit binding drifted*'

    [IO.File]::WriteAllText((Join-Path $source 'outside.txt'),'outside',[Text.UTF8Encoding]::new($false))
    try{$outside=Copy-ActiveWorkspace $template $temp 'case-outside-overlay';Assert-ActiveRejects $outside 'unowned overlay' '*unowned overlay*'}finally{Remove-Item -LiteralPath (Join-Path $source 'outside.txt') -Force}

    $partial=Copy-ActiveWorkspace $template $temp 'case-partial'
    $partialRequest=Join-Path $partial 'receipts\unit-old-superseded-by-unit-new-request.json'
    $partialRepoMap=Join-Path $partial 'repository-map.json'
    $partialOut=Join-Path $partial 'receipts\unit-old-superseded-by-unit-new-automation.json'
    $interrupted=$false;try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $partial -UnitId unit-new -RepoMapPath $partialRepoMap -ActiveUnitSupersession $partialRequest -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $partialRequest) -OutPath $partialOut -Timestamp '2026-09-01T00:02:00.0000000Z' -Execute -FaultAfter after-intent|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption after intent*'}
    Assert-ActiveTest $interrupted 'fault injection did not preserve one partial authenticated intent'
    $partialRecovered=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $partial -UnitId unit-new -RepoMapPath $partialRepoMap -ActiveUnitSupersession $partialRequest -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $partialRequest) -OutPath $partialOut -Timestamp '2026-09-01T00:08:00.0000000Z' -Execute
    $partialCommitted=&$transition {param($w)Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $w -TransactionId 'unit-old-superseded-by-unit-new-transition' -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath 'iteration-units/unit-new.json' -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail} $partial
    Assert-ActiveTest ($partialRecovered.executed-and[string]$partialCommitted.status-ceq'committed') 'partial exact intent was not repaired and committed'

    foreach($case in @('replacement-dirt-drift','companion-dirt-drift','omitted-clean-dirt','repository-map-byte-drift','repository-map-path-drift')){
        $recoveryCase=New-PartitionRecoveryCase "case-after-intent-$case";$interrupted=$false
        try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $recoveryCase.root -UnitId unit-new -RepoMapPath $recoveryCase.map -ActiveUnitSupersession $recoveryCase.request -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $recoveryCase.request) -OutPath $recoveryCase.out -Timestamp '2026-09-01T00:02:00.0000000Z' -Execute -FaultAfter after-intent|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption after intent*'}
        Assert-ActiveTest $interrupted "$case fixture did not stop after its exact intent"
        $eventsPath=Join-Path $recoveryCase.root 'iteration-events.jsonl';$eventsHash=Get-ActiveFileHash $eventsPath;$eventsLength=[IO.FileInfo]::new($eventsPath).Length
        if($case-ceq'replacement-dirt-drift'){[IO.File]::AppendAllText((Join-Path $recoveryCase.source $replacementPaths[0]),"replacement drift`n",[Text.UTF8Encoding]::new($false))}
        elseif($case-ceq'companion-dirt-drift'){[IO.File]::AppendAllText((Join-Path $recoveryCase.source $companionPaths[0]),"companion drift`n",[Text.UTF8Encoding]::new($false))}
        elseif($case-ceq'omitted-clean-dirt'){[IO.File]::AppendAllText((Join-Path $recoveryCase.clean 'clean.txt'),"omitted drift`n",[Text.UTF8Encoding]::new($false))}
        elseif($case-ceq'repository-map-byte-drift'){[IO.File]::AppendAllText($recoveryCase.map," `n",[Text.UTF8Encoding]::new($false))}
        else{
            $alternateSource=Join-Path $temp "case-after-intent-$case-alternate-source";Copy-Item -LiteralPath $recoveryCase.source -Destination $alternateSource -Recurse
            $mapDocument=Read-ActiveJson $recoveryCase.map;@($mapDocument.repositories|Where-Object{[string]$_.repo_id-ceq'source-repo'})[0].path=$alternateSource;Write-ActiveJson $recoveryCase.map $mapDocument
        }
        $rejected=$false;$reason='';try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $recoveryCase.root -UnitId unit-new -RepoMapPath $recoveryCase.map -ActiveUnitSupersession $recoveryCase.request -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $recoveryCase.request) -OutPath $recoveryCase.out -Timestamp '2026-09-01T00:08:00.0000000Z' -Execute|Out-Null}catch{$rejected=$true;$reason=$_.Exception.Message}
        $expected=if($case-like'repository-map-*'){'*recovery repository-map bytes drifted*'}elseif($case-ceq'omitted-clean-dirt'){'*omitted repository*not clean*'}else{'*recovery repository and overlay binding drifted*'}
        Assert-ActiveTest ($rejected-and$reason-like$expected) "$case after-intent recovery was not rejected by its bound observation: $reason"
        $completionPath=Join-Path $recoveryCase.root 'receipts\transactions\unit-old-superseded-by-unit-new-transition.completion.json'
        Assert-ActiveTest (-not(Test-Path -LiteralPath $completionPath)-and(Get-ActiveFileHash $eventsPath)-ceq$eventsHash-and[IO.FileInfo]::new($eventsPath).Length-eq$eventsLength) "$case rejection emitted a completion or appended an event"
    }

    foreach($fault in @('after-artifact','after-projection','after-event')){
        $faultRoot=Copy-ActiveWorkspace $template $temp "case-fault-$fault";$faultRequest=Join-Path $faultRoot 'receipts\unit-old-superseded-by-unit-new-request.json';$faultMap=Join-Path $faultRoot 'repository-map.json';$faultOut=Join-Path $faultRoot 'receipts\unit-old-superseded-by-unit-new-automation.json';$faulted=$false
        try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $faultRoot -UnitId unit-new -RepoMapPath $faultMap -ActiveUnitSupersession $faultRequest -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $faultRequest) -OutPath $faultOut -Timestamp '2026-09-01T00:02:00.0000000Z' -Execute -FaultAfter $fault|Out-Null}catch{$faulted=$_.Exception.Message-like'*Injected interruption*'}
        Assert-ActiveTest $faulted "fault point $fault did not interrupt"
        $recovered=Invoke-MorphospaceSupersedeActive -WorkspaceRoot $faultRoot -UnitId unit-new -RepoMapPath $faultMap -ActiveUnitSupersession $faultRequest -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $faultRequest) -OutPath $faultOut -Timestamp '2026-09-01T00:08:00.0000000Z' -Execute
        $verified=&$transition {param($w)Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $w -TransactionId 'unit-old-superseded-by-unit-new-transition' -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath 'iteration-units/unit-new.json' -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail} $faultRoot
        Assert-ActiveTest ($recovered.executed-and[string]$verified.status-ceq'committed') "fault point $fault was not exactly recovered"
    }

    $damagedIntent=Copy-ActiveWorkspace $template $temp 'case-damaged-intent';$damagedRequest=Join-Path $damagedIntent 'receipts\unit-old-superseded-by-unit-new-request.json';$damagedMap=Join-Path $damagedIntent 'repository-map.json';$damagedOut=Join-Path $damagedIntent 'receipts\unit-old-superseded-by-unit-new-automation.json'
    try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $damagedIntent -UnitId unit-new -RepoMapPath $damagedMap -ActiveUnitSupersession $damagedRequest -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $damagedRequest) -OutPath $damagedOut -Timestamp '2026-09-01T00:02:00.0000000Z' -Execute -FaultAfter after-intent|Out-Null}catch{}
    $intentFile=Join-Path $damagedIntent 'receipts\transactions\unit-old-superseded-by-unit-new-transition.intent.json';$intentDamage=Read-ActiveJson $intentFile;$intentDamage.target.unit.document.status='blocked';Write-ActiveJson $intentFile $intentDamage
    $intentDamageRejected=$false;try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $damagedIntent -UnitId unit-new -RepoMapPath $damagedMap -ActiveUnitSupersession $damagedRequest -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $damagedRequest) -OutPath $damagedOut -Timestamp '2026-09-01T00:08:00.0000000Z' -Execute|Out-Null}catch{$intentDamageRejected=$_.Exception.Message-like'*target unit is not the exact*'}
    Assert-ActiveTest $intentDamageRejected 'damaged existing intent was repaired or committed'

    $companionIntent=Copy-ActiveWorkspace $partitionTemplate $temp 'case-companion-intent-drift';$companionRequest=Join-Path $companionIntent 'receipts\unit-old-superseded-by-unit-new-request.json';$companionMap=Join-Path $companionIntent 'repository-map.json';$companionOut=Join-Path $companionIntent 'receipts\unit-old-superseded-by-unit-new-automation.json'
    try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $companionIntent -UnitId unit-new -RepoMapPath $companionMap -ActiveUnitSupersession $companionRequest -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $companionRequest) -OutPath $companionOut -Timestamp '2026-09-01T00:02:00.0000000Z' -Execute -FaultAfter after-intent|Out-Null}catch{}
    [IO.File]::AppendAllText((Join-Path $companionIntent 'iteration-units\unit-companion.json')," `n",[Text.UTF8Encoding]::new($false));$companionIntentRejected=$false
    try{Invoke-MorphospaceSupersedeActive -WorkspaceRoot $companionIntent -UnitId unit-new -RepoMapPath $companionMap -ActiveUnitSupersession $companionRequest -ExpectedActiveUnitSupersessionSha256 (Get-ActiveFileHash $companionRequest) -OutPath $companionOut -Timestamp '2026-09-01T00:08:00.0000000Z' -Execute|Out-Null}catch{$companionIntentRejected=$_.Exception.Message-like'*companion*binding drifted*'}
    Assert-ActiveTest $companionIntentRejected 'companion byte drift after intent was accepted during recovery'

    $orphan=Copy-ActiveWorkspace $template $temp 'case-orphan-completion';[IO.Directory]::CreateDirectory((Join-Path $orphan 'receipts\transactions'))|Out-Null;Write-ActiveJson (Join-Path $orphan 'receipts\transactions\unit-old-superseded-by-unit-new-transition.completion.json') ([ordered]@{orphan=$true});Assert-ActiveRejects $orphan 'orphan completion' '*orphan completion*'
    [pscustomobject][ordered]@{result='pass';supersession_atomic=$true;old_unit_bytes_preserved=$true;replacement_unaccepted=$true;companion_units_preserved=$true;source_widening_rejected=$true;exact_intent_recovery_and_replay=$true;product_or_device_used=$false}|ConvertTo-Json -Compress
}finally{
    if([IO.Directory]::Exists($temp)){Remove-Item -LiteralPath $temp -Recurse -Force}
}
