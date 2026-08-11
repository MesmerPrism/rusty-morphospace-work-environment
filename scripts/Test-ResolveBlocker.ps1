$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ResolveBlocker.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
function Assert-Resolve([bool]$Value,[string]$Message){if(-not$Value){throw "ResolveBlocker self-test failed: $Message"}}
function Write-ResolveJson([string]$Path,[object]$Value){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 30 -Compress)+"`n"),[Text.UTF8Encoding]::new($false))}
function Invoke-ResolveGit([string]$Path,[string[]]$Arguments){$output=@(& git -C $Path @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "git failed: $output"};(($output|ForEach-Object{[string]$_})-join"`n").Trim()}
$root=Join-Path ([IO.Path]::GetTempPath()) ("morphospace-resolve-"+[guid]::NewGuid().ToString('N'))
try{
    $repo=Join-Path $root 'repo';& git init --quiet -b main $repo
    Invoke-ResolveGit $repo @('config','user.name','Synthetic Test')|Out-Null;Invoke-ResolveGit $repo @('config','user.email','synthetic@example.invalid')|Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'),'exact',[Text.UTF8Encoding]::new($false));Invoke-ResolveGit $repo @('add','tracked.txt')|Out-Null;Invoke-ResolveGit $repo @('commit','-m','exact head')|Out-Null
    $head=Invoke-ResolveGit $repo @('rev-parse','HEAD')
    $workspace=Join-Path $repo 'morphospace';[IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $workspace 'local'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts'))|Out-Null
    $unit=[ordered]@{schema='synthetic-unit';unit_id='active-unit';status='active'};Write-ResolveJson (Join-Path $workspace 'iteration-units\active-unit.json') $unit
    $target=[ordered]@{blocker_id='target-blocker';condition='Exact generic condition.';resume_when='Exact generic evidence passes.'}
    $preserved=[ordered]@{blocker_id='preserved-blocker';condition='Unrelated condition.';resume_when='Separate evidence passes.'}
    $pending=[ordered]@{bundle_id='unchanged-bundle'};$checkpoint=[ordered]@{receipt='receipts/unchanged-validation.json';result='pass'}
    $state=[ordered]@{schema='synthetic-state';project_id='resolve-project';current_unit='active-unit';pending_push_bundle=$pending;validation_checkpoint=$checkpoint;blockers=@($target,$preserved);last_event_id='active-unit-started'}
    Write-ResolveJson (Join-Path $workspace 'workspace.state.json') $state
    $initialEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='active-unit-started';sequence=1;timestamp='2025-12-31T23:59:59Z';project_id='resolve-project';unit_id='active-unit';event_type='state-transition';summary='Started the synthetic active unit.';receipts=@()}
    Write-ResolveJson (Join-Path $workspace 'iteration-events.jsonl') $initialEvent
    $evidenceRelative='local/resolution-evidence.txt';[IO.File]::WriteAllText((Join-Path $workspace ($evidenceRelative-replace'/','\')),'pass',[Text.UTF8Encoding]::new($false))
    $map=Join-Path $root 'map.json';Write-ResolveJson $map ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='synthetic-repo';path=$repo;role='source'})})
    $receipt=[ordered]@{schema='rusty.morphospace.workflow.blocker_resolution_receipt.v1';receipt_id='target-blocker-resolution';project_id='resolve-project';unit_id='active-unit';blocker=$target;result='pass';evidence=@([ordered]@{path=$evidenceRelative;sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ($evidenceRelative-replace'/','\'))});repository_heads=@([ordered]@{repo_id='synthetic-repo';branch='main';revision=$head});repository_sources=@([ordered]@{repo_id='synthetic-repo';sources=@([ordered]@{path='tracked.txt';sha256=Get-MorphospaceFileSha256 (Join-Path $repo 'tracked.txt')})});preserve_blocker_ids=@('preserved-blocker')}
    $input=Join-Path $workspace 'local\target-blocker-resolution.json';$script:ResolveInputPath=$input;Write-ResolveJson $input $receipt
    Write-ResolveJson (Join-Path $workspace 'receipts\unrelated-dollar-schema-evidence.json') ([ordered]@{'$schema'='synthetic.unrelated_evidence.v1';result='pass'})
    function Assert-RejectedWithoutMutation([object]$Candidate,[string]$Name,[scriptblock]$BeforeInvoke=$null,[scriptblock]$AfterInvoke=$null){
        Write-ResolveJson $script:ResolveInputPath $Candidate
        $beforeState=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json')
        $beforeUnit=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json')
        $beforeEvents=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl')
        $negativeOutput=Join-Path $workspace "receipts\negative-$Name.json"
        if($BeforeInvoke){&$BeforeInvoke}
        $rejected=$false
        try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $script:ResolveInputPath -OutPath $negativeOutput -Execute|Out-Null}catch{$rejected=$true}
        finally{if($AfterInvoke){&$AfterInvoke}}
        Assert-Resolve $rejected "$Name was accepted"
        Assert-Resolve ((Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json'))-eq$beforeState-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json'))-eq$beforeUnit-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl'))-eq$beforeEvents-and-not(Test-Path $negativeOutput)) "$Name rejection changed a projection or wrote its output"
    }
    $dry=Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input -Timestamp '2026-01-01T00:00:00Z'
    Assert-Resolve (-not$dry.executed-and@(Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')).blockers.Count-eq2) 'dry run mutated blockers'
    Invoke-ResolveGit $repo @('checkout','--detach',$head)|Out-Null
    try{
        $detached=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$detached.repository_heads[0].branch='';Write-ResolveJson $input $detached
        $detachedDry=Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input -Timestamp '2026-01-01T00:00:00Z'
        Assert-Resolve (-not$detachedDry.executed) 'detached repository head was rejected'
    }finally{Invoke-ResolveGit $repo @('checkout','main')|Out-Null}
    Write-ResolveJson $input $receipt
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.evidence[0].sha256='0'*64;Write-ResolveJson $input $damaged
    $tamperRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input|Out-Null}catch{$tamperRejected=$true};Assert-Resolve $tamperRejected 'tampered evidence was accepted'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.preserve_blocker_ids=@();Write-ResolveJson $input $damaged
    $preservationRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input|Out-Null}catch{$preservationRejected=$true};Assert-Resolve $preservationRejected 'incomplete blocker preservation was accepted'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_heads[0].revision='0'*40;Write-ResolveJson $input $damaged
    $casRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input|Out-Null}catch{$casRejected=$true};Assert-Resolve $casRejected 'stale repository-head binding was accepted'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_heads=@();Write-ResolveJson $input $damaged
    $omittedRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input|Out-Null}catch{$omittedRejected=$true};Assert-Resolve $omittedRejected 'omitted authoritative repository head was accepted'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_heads+=,[pscustomobject][ordered]@{repo_id='extra-repo';branch='main';revision=$head};Write-ResolveJson $input $damaged
    $extraRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input|Out-Null}catch{$extraRejected=$true};Assert-Resolve $extraRejected 'extra repository head was accepted'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_heads=@([pscustomobject][ordered]@{repo_id='unrelated-repo';branch='main';revision=$head});Write-ResolveJson $input $damaged
    $unrelatedRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input|Out-Null}catch{$unrelatedRejected=$true};Assert-Resolve $unrelatedRejected 'unrelated-only repository head set was accepted'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources=@();Assert-RejectedWithoutMutation $damaged 'empty-repository-sources'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources=@();Assert-RejectedWithoutMutation $damaged 'omitted-repository-source'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources+=,[pscustomobject][ordered]@{repo_id='extra-repo';sources=@([pscustomobject][ordered]@{path='tracked.txt';sha256='0'*64})};Assert-RejectedWithoutMutation $damaged 'extra-repository-source'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources=@([pscustomobject][ordered]@{repo_id='unknown-repo';sources=@([pscustomobject][ordered]@{path='tracked.txt';sha256='0'*64})});Assert-RejectedWithoutMutation $damaged 'unknown-repository-source'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources+=,$damaged.repository_sources[0];Assert-RejectedWithoutMutation $damaged 'duplicate-repository-source-id'
    $caseMap=Join-Path $root 'case-map.json';Write-ResolveJson $caseMap ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='synthetic-repo';path=$repo;role='source'},[ordered]@{repo_id='Synthetic-Repo';path=$repo;role='source'})})
    $beforeCaseState=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json');$caseRejected=$false;Write-ResolveJson $input $receipt
    try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $caseMap -BlockerResolutionReceipt $input|Out-Null}catch{$caseRejected=$true}
    Assert-Resolve ($caseRejected-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json'))-eq$beforeCaseState) 'case-fold duplicate repository-map IDs were accepted or mutated state'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources[0].sources+=,[pscustomobject][ordered]@{path='tracked.txt';sha256=$damaged.repository_sources[0].sources[0].sha256};Assert-RejectedWithoutMutation $damaged 'duplicate-source-path'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources[0].sources+=,[pscustomobject][ordered]@{path='TRACKED.TXT';sha256=$damaged.repository_sources[0].sources[0].sha256};Assert-RejectedWithoutMutation $damaged 'case-fold-duplicate-source-path'
    $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources[0].sources[0].path='missing.txt';Assert-RejectedWithoutMutation $damaged 'missing-source-file'
    $originalTracked=[IO.File]::ReadAllBytes((Join-Path $repo 'tracked.txt'))
    Assert-RejectedWithoutMutation $receipt 'tampered-source-file' {[IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'),'tampered',[Text.UTF8Encoding]::new($false))} {[IO.File]::WriteAllBytes((Join-Path $repo 'tracked.txt'),$originalTracked)}
    $driveQualifiedPath=([string][char]67)+':/tracked.txt'
    foreach($invalidPath in @('','/tracked.txt',$driveQualifiedPath,'//server/share/file.txt','../tracked.txt','dir/../tracked.txt','./tracked.txt','dir/','dir//file.txt','dir/./file.txt')){
        $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources[0].sources[0].path=$invalidPath
        Assert-RejectedWithoutMutation $damaged ("invalid-source-path-"+[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($invalidPath)).ToLowerInvariant())
    }
    $linkTarget=Join-Path $repo 'linked-source.txt'
    $targetLinkCreated=$false
    try{New-Item -ItemType SymbolicLink -Path $linkTarget -Target (Join-Path $repo 'tracked.txt') -ErrorAction Stop|Out-Null;$targetLinkCreated=$true}catch{Write-Host "ResolveBlocker reparse-target test skipped: $($_.Exception.Message)"}
    if($targetLinkCreated){
        $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources[0].sources[0].path='linked-source.txt';Assert-RejectedWithoutMutation $damaged 'reparse-source-target'
        Remove-Item -LiteralPath $linkTarget -Force
    }
    $realDirectory=Join-Path $repo 'real-source-dir';[IO.Directory]::CreateDirectory($realDirectory)|Out-Null;[IO.File]::WriteAllText((Join-Path $realDirectory 'source.txt'),'source',[Text.UTF8Encoding]::new($false))
    $linkDirectory=Join-Path $repo 'linked-source-dir'
    $ancestorLinkCreated=$false
    try{New-Item -ItemType SymbolicLink -Path $linkDirectory -Target $realDirectory -ErrorAction Stop|Out-Null;$ancestorLinkCreated=$true}catch{Write-Host "ResolveBlocker reparse-ancestor test skipped: $($_.Exception.Message)"}
    if($ancestorLinkCreated){
        $damaged=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$damaged.repository_sources[0].sources[0].path='linked-source-dir/source.txt';Assert-RejectedWithoutMutation $damaged 'reparse-source-ancestor'
        Remove-Item -LiteralPath $linkDirectory -Force
    }
    Remove-Item -LiteralPath $realDirectory -Recurse -Force
    Write-ResolveJson $input $receipt
    $sourceRaceOutput=Join-Path $workspace 'receipts\source-race-resolution.json'
    $beforeRaceState=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json');$beforeRaceUnit=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json');$beforeRaceEvents=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl')
    $raceRejected=$false
    $raceHook={[IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'),'changed between checks',[Text.UTF8Encoding]::new($false))}.GetNewClosure()
    try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input -OutPath $sourceRaceOutput -Execute -BeforeTransitionHook $raceHook|Out-Null}catch{$raceRejected=$true}finally{[IO.File]::WriteAllBytes((Join-Path $repo 'tracked.txt'),$originalTracked)}
    Assert-Resolve ($raceRejected-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json'))-eq$beforeRaceState-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json'))-eq$beforeRaceUnit-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl'))-eq$beforeRaceEvents-and-not(Test-Path $sourceRaceOutput)) 'source change between initial validation and transition was consumed or mutated projections'
    foreach($invalidStatus in @('validating','accepted','blocked')){
        $invalidUnit=$unit|ConvertTo-Json -Depth 10|ConvertFrom-Json;$invalidUnit.status=$invalidStatus;Write-ResolveJson (Join-Path $workspace 'iteration-units\active-unit.json') $invalidUnit
        Write-ResolveJson $input $receipt
        $statusRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input|Out-Null}catch{$statusRejected=$true}
        Assert-Resolve $statusRejected "unit status '$invalidStatus' was accepted"
    }
    Write-ResolveJson (Join-Path $workspace 'iteration-units\active-unit.json') $unit
    Write-ResolveJson $input $receipt
    $stateHash=Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json'));$unitHash=Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Join-Path $workspace 'iteration-units\active-unit.json'))
    $output=Join-Path $workspace 'receipts\target-blocker-resolution.json'
    $executed=Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $input -Timestamp '2026-01-01T00:00:00Z' -OutPath $output -Execute
    $after=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
    Assert-Resolve ($executed.executed-and@($after.blockers).Count-eq1-and[string]$after.blockers[0].blocker_id-eq'preserved-blocker') 'execute did not remove only the named blocker'
    Assert-Resolve ((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$after.pending_push_bundle}))-eq(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$pending}))-and(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$after.validation_checkpoint}))-eq(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$checkpoint}))-and[string]$after.current_unit-eq'active-unit'-and(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Join-Path $workspace 'iteration-units\active-unit.json')))-eq$unitHash) 'execute changed a preserved workflow projection'
    Assert-Resolve ((Get-MorphospaceFileSha256 $output)-eq(Get-MorphospaceFileSha256 $input)-and(Get-MorphospaceCanonicalJsonSha256 $after)-ne$stateHash) 'transaction did not own exact receipt artifact or state did not advance'
    $reintroduced=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json');$reintroduced.blockers=@($reintroduced.blockers)+[pscustomobject]$target
    $reintroduced.last_event_id='active-unit-blocker-reintroduced'
    Write-ResolveJson (Join-Path $workspace 'workspace.state.json') $reintroduced
    Add-Content -LiteralPath (Join-Path $workspace 'iteration-events.jsonl') -Value '{"schema":"rusty.morphospace.workflow.iteration_event.v1","event_id":"active-unit-blocker-reintroduced","sequence":3,"timestamp":"2026-01-01T00:00:01Z","project_id":"resolve-project","unit_id":"active-unit","event_type":"state-transition","summary":"Reintroduced the exact blocker as a valid later projection fixture.","receipts":[]}' -Encoding utf8
    $differentInput=Join-Path $workspace 'local\same-receipt-different-path.json';Write-ResolveJson $differentInput $receipt
    $differentOutput=Join-Path $workspace 'receipts\same-receipt-different-output.json'
    $consumedBytes=[IO.File]::ReadAllBytes($output)
    foreach($damage in @(
        @{name='missing';apply={Remove-Item -LiteralPath $output -Force}},
        @{name='malformed';apply={[IO.File]::WriteAllText($output,'{malformed',[Text.UTF8Encoding]::new($false))}},
        @{name='schema-invalid';apply={Write-ResolveJson $output ([ordered]@{schema='wrong.schema';receipt_id='target-blocker-resolution'})}},
        @{name='hash-mismatched';apply={$changed=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$changed.receipt_id='changed-resolution-identity';Write-ResolveJson $output $changed}}
    )){
        & $damage.apply
        $damageOutput=Join-Path $workspace "receipts\damage-$($damage.name)-retry.json"
        $beforeDamageState=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json')
        $beforeDamageUnit=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json')
        $beforeDamageEvents=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl')
        $damageRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $differentInput -OutPath $damageOutput -Execute|Out-Null}catch{$damageRejected=$true}
        Assert-Resolve $damageRejected "$($damage.name) consumed artifact was accepted"
        Assert-Resolve ((Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json'))-eq$beforeDamageState-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json'))-eq$beforeDamageUnit-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl'))-eq$beforeDamageEvents-and-not(Test-Path $damageOutput)) "$($damage.name) consumed-artifact rejection changed a projection or wrote an artifact"
        [IO.File]::WriteAllBytes($output,$consumedBytes)
    }
    $consumedEventId='active-unit-blocker-resolved-0002'
    $consumedIntent=Join-Path $workspace "receipts\transactions\$consumedEventId-transition.intent.json"
    $consumedCompletion=Join-Path $workspace "receipts\transactions\$consumedEventId-transition.completion.json"
    $intentBytes=[IO.File]::ReadAllBytes($consumedIntent);$completionBytes=[IO.File]::ReadAllBytes($consumedCompletion)
    foreach($completionDamage in @(
        @{name='missing-completion';apply={Remove-Item -LiteralPath $consumedCompletion -Force}},
        @{name='malformed-completion';apply={[IO.File]::WriteAllText($consumedCompletion,'{malformed',[Text.UTF8Encoding]::new($false))}}
    )){
        & $completionDamage.apply
        $damageOutput=Join-Path $workspace "receipts\$($completionDamage.name)-retry.json"
        $beforeDamageState=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json')
        $beforeDamageUnit=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json')
        $beforeDamageEvents=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl')
        $damageRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $differentInput -OutPath $damageOutput -Execute|Out-Null}catch{$damageRejected=$true}
        Assert-Resolve $damageRejected "$($completionDamage.name) historical evidence was accepted"
        Assert-Resolve ((Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json'))-eq$beforeDamageState-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json'))-eq$beforeDamageUnit-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl'))-eq$beforeDamageEvents-and-not(Test-Path $damageOutput)) "$($completionDamage.name) rejection changed a projection or wrote an artifact"
        [IO.File]::WriteAllBytes($consumedCompletion,$completionBytes)
    }
    $pairedReceipt=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$pairedReceipt.receipt_id='paired-tamper-resolution';Write-ResolveJson $output $pairedReceipt
    $pairedIntent=Read-MorphospaceProtocolJson $consumedIntent
    $pairedArtifact=@($pairedIntent.artifacts|Where-Object{[string]$_.path-ceq'receipts/target-blocker-resolution.json'})[0]
    $pairedArtifact.sha256=Get-MorphospaceFileSha256 $output
    $pairedArtifact.bytes_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($output))
    Write-ResolveJson $consumedIntent $pairedIntent
    $pairedOutput=Join-Path $workspace 'receipts\paired-tamper-retry.json'
    $beforePairedState=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json')
    $beforePairedUnit=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json')
    $beforePairedEvents=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl')
    $pairedRejected=$false;try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $differentInput -OutPath $pairedOutput -Execute|Out-Null}catch{$pairedRejected=$true}
    Assert-Resolve $pairedRejected 'paired receipt plus intent-owned hash tamper was accepted without the original completion binding'
    Assert-Resolve ((Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json'))-eq$beforePairedState-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json'))-eq$beforePairedUnit-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl'))-eq$beforePairedEvents-and-not(Test-Path $pairedOutput)) 'paired receipt/intent tamper rejection changed a projection or wrote an artifact'
    [IO.File]::WriteAllBytes($output,$consumedBytes);[IO.File]::WriteAllBytes($consumedIntent,$intentBytes)
    $beforeReplayState=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json')
    $beforeReplayUnit=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json')
    $beforeReplayEvents=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl')
    $consumedRejected=$false;$consumedMessage='';try{Invoke-MorphospaceResolveBlocker -WorkspaceRoot $workspace -UnitId 'active-unit' -RepoMapPath $map -BlockerResolutionReceipt $differentInput -OutPath $differentOutput -Execute|Out-Null}catch{$consumedRejected=$true;$consumedMessage=$_.Exception.Message}
    Assert-Resolve ($consumedRejected-and$consumedMessage-like'*already consumed*') "same receipt identity/hash replay did not reject by stable consumption identity: $consumedMessage"
    Assert-Resolve ((Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json'))-eq$beforeReplayState-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\active-unit.json'))-eq$beforeReplayUnit-and(Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-events.jsonl'))-eq$beforeReplayEvents-and-not(Test-Path $differentOutput)) 'replay rejection changed a projection or wrote an artifact'
    Write-Host 'ResolveBlocker self-test passed.'
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}}
