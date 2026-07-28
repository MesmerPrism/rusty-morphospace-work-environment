$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ResolveBlocker.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CorrectResolvedBlockerEvidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
function Assert-Correction([bool]$Value,[string]$Message){if(-not$Value){throw "CorrectResolvedBlockerEvidence self-test failed: $Message"}}
function Write-CorrectionJson([string]$Path,[object]$Value){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 40 -Compress)+"`n"),[Text.UTF8Encoding]::new($false))}
function Invoke-CorrectionTestGit([string]$Path,[string[]]$Arguments){$o=@(& git -C $Path @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "git failed: $o"};(($o|ForEach-Object{[string]$_})-join"`n").Trim()}
function Copy-Correction([object]$Value){$Value|ConvertTo-Json -Depth 40|ConvertFrom-Json}
function New-CorrectionFixture([string]$Name){
    $root=Join-Path $script:Root $Name;$repo=Join-Path $root 'repo';&git init --quiet -b main $repo
    Invoke-CorrectionTestGit $repo @('config','user.name','Synthetic Test')|Out-Null;Invoke-CorrectionTestGit $repo @('config','user.email','synthetic@example.invalid')|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $repo 'src'))|Out-Null;[IO.File]::WriteAllText((Join-Path $repo 'src\current.txt'),'corrected',[Text.UTF8Encoding]::new($false))
    Invoke-CorrectionTestGit $repo @('add','src/current.txt')|Out-Null;Invoke-CorrectionTestGit $repo @('commit','-m','current')|Out-Null;$head=Invoke-CorrectionTestGit $repo @('rev-parse','HEAD')
    $ws=Join-Path $root 'morphospace';[IO.Directory]::CreateDirectory((Join-Path $ws 'iteration-units'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $ws 'local'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $ws 'receipts\evidence'))|Out-Null
    $retainedStatement='Retained historical authority wording.'
    $unit=[ordered]@{schema='synthetic-unit';unit_id='active-unit';status='active';immutable='unit-bytes';non_scope=@($retainedStatement)};Write-CorrectionJson (Join-Path $ws 'iteration-units\active-unit.json') $unit
    $target=[ordered]@{blocker_id='resolved-blocker';condition='Original bounded condition.';resume_when='Original bounded resume condition.'}
    $preserved=[ordered]@{blocker_id='preserved-blocker';condition='Preserved condition.';resume_when='Preserved resume.'}
    $state=[ordered]@{schema='synthetic-state';project_id='correction-project';current_unit='active-unit';pending_push_bundle=[ordered]@{bundle_id='unchanged'};validation_checkpoint=[ordered]@{receipt='receipts/validation.json';result='pass'};last_accepted_receipt='receipts/accepted.json';plan_revision=9;blockers=@($target,$preserved);last_event_id='active-unit-started'}
    Write-CorrectionJson (Join-Path $ws 'workspace.state.json') $state
    $initialEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='active-unit-started';sequence=1;timestamp='2025-12-31T23:59:59Z';project_id='correction-project';unit_id='active-unit';event_type='state-transition';summary='Started the synthetic active unit.';receipts=@()}
    Write-CorrectionJson (Join-Path $ws 'iteration-events.jsonl') $initialEvent
    [IO.File]::WriteAllText((Join-Path $ws 'receipts\evidence\original.txt'),'original',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $ws 'receipts\evidence\corrected.txt'),'corrected',[Text.UTF8Encoding]::new($false))
    $map=Join-Path $root 'map.json';Write-CorrectionJson $map ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='synthetic-repo';path=$repo;role='source'})})
    $original=[ordered]@{schema='rusty.morphospace.workflow.blocker_resolution_receipt.v1';receipt_id='original-resolution';project_id='correction-project';unit_id='active-unit';blocker=$target;result='pass';evidence=@([ordered]@{path='receipts/evidence/original.txt';sha256=Get-MorphospaceFileSha256 (Join-Path $ws 'receipts\evidence\original.txt')});repository_heads=@([ordered]@{repo_id='synthetic-repo';branch='main';revision=$head});repository_sources=@([ordered]@{repo_id='synthetic-repo';sources=@([ordered]@{path='src/current.txt';sha256=Get-MorphospaceFileSha256 (Join-Path $repo 'src\current.txt')})});preserve_blocker_ids=@('preserved-blocker')}
    $originalInput=Join-Path $ws 'local\original.json';$originalOutput=Join-Path $ws 'receipts\original-resolution.json';Write-CorrectionJson $originalInput $original
    Invoke-MorphospaceResolveBlocker -WorkspaceRoot $ws -UnitId active-unit -RepoMapPath $map -BlockerResolutionReceipt $originalInput -Timestamp '2026-01-01T00:00:00Z' -OutPath $originalOutput -Execute|Out-Null
    $eventId='active-unit-blocker-resolved-0002';$intentRelative="receipts/transactions/$eventId-transition.intent.json";$completionRelative="receipts/transactions/$eventId-transition.completion.json"
    $statementHash=Get-MorphospaceSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false)).GetBytes($retainedStatement)
    $correction=[ordered]@{schema='rusty.morphospace.workflow.blocker_resolution_correction_receipt.v1';receipt_id='corrected-resolution';project_id='correction-project';unit_id='active-unit';blocker_id='resolved-blocker';result='pass';supersedes=[ordered]@{event_id=$eventId;original_receipt_id='original-resolution';receipt=[ordered]@{path='receipts/original-resolution.json';sha256=Get-MorphospaceFileSha256 $originalOutput};intent=[ordered]@{path=$intentRelative;sha256=Get-MorphospaceFileSha256 (Join-Path $ws ($intentRelative-replace'/','\'))};completion=[ordered]@{path=$completionRelative;sha256=Get-MorphospaceFileSha256 (Join-Path $ws ($completionRelative-replace'/','\'))}};correction=[ordered]@{historical_receipt_retained=$true;prior_complete_resolution_claim='superseded';corrected_resolution_established=$true};authority_clarification=[ordered]@{unit=[ordered]@{path='iteration-units/active-unit.json';sha256=Get-MorphospaceFileSha256 (Join-Path $ws 'iteration-units\active-unit.json')};statement=[ordered]@{json_pointer='/non_scope/0';exact_text=$retainedStatement;exact_text_sha256=$statementHash;disposition='superseded-for-current-interpretation'};historical_unit_retained=$true;bindings=@([ordered]@{contract_id='example.generic.contract.v1';authority_id='generic-owner';relation='owns-schema'})};evidence=@([ordered]@{path='receipts/evidence/corrected.txt';sha256=Get-MorphospaceFileSha256 (Join-Path $ws 'receipts\evidence\corrected.txt')});repository_heads=@([ordered]@{repo_id='synthetic-repo';branch='main';revision=$head});repository_sources=@([ordered]@{repo_id='synthetic-repo';sources=@([ordered]@{path='src/current.txt';sha256=Get-MorphospaceFileSha256 (Join-Path $repo 'src\current.txt')})});preserve_blocker_ids=@('preserved-blocker')}
    $input=Join-Path $ws 'local\correction.json';Write-CorrectionJson $input $correction
    [pscustomobject]@{root=$root;repo=$repo;workspace=$ws;map=$map;unit=$unit;state=$state;target=$target;receipt=$correction;input=$input;head=$head}
}
function Assert-CorrectionRejected([object]$Fixture,[object]$Receipt,[string]$Name,[scriptblock]$Before=$null,[scriptblock]$After=$null){
    Write-CorrectionJson $Fixture.input $Receipt;$state=Get-MorphospaceFileSha256 (Join-Path $Fixture.workspace 'workspace.state.json');$unit=Get-MorphospaceFileSha256 (Join-Path $Fixture.workspace 'iteration-units\active-unit.json');$events=Get-MorphospaceFileSha256 (Join-Path $Fixture.workspace 'iteration-events.jsonl');$out=Join-Path $Fixture.workspace "receipts\$Name.json"
    if($Before){&$Before};$rejected=$false
    try{Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $Fixture.workspace -UnitId active-unit -RepoMapPath $Fixture.map -CorrectionReceipt $Fixture.input -OutPath $out -Execute|Out-Null}catch{$rejected=$true}finally{if($After){&$After}}
    Assert-Correction $rejected "$Name was accepted";Assert-Correction ((Get-MorphospaceFileSha256 (Join-Path $Fixture.workspace 'workspace.state.json'))-eq$state-and(Get-MorphospaceFileSha256 (Join-Path $Fixture.workspace 'iteration-units\active-unit.json'))-eq$unit-and(Get-MorphospaceFileSha256 (Join-Path $Fixture.workspace 'iteration-events.jsonl'))-eq$events-and-not(Test-Path $out)) "$Name mutated a projection"
}
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ("morphospace-correction-"+[guid]::NewGuid().ToString('N'))
try{
    $f=New-CorrectionFixture 'positive';$dry=Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $f.workspace -UnitId active-unit -RepoMapPath $f.map -CorrectionReceipt $f.input
    Assert-Correction (-not$dry.executed) 'dry run executed'
    $before=Read-MorphospaceProtocolJson (Join-Path $f.workspace 'workspace.state.json');$beforeUnit=Get-MorphospaceFileSha256 (Join-Path $f.workspace 'iteration-units\active-unit.json')
    $out=Join-Path $f.workspace 'receipts\corrected-resolution.json';$result=Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $f.workspace -UnitId active-unit -RepoMapPath $f.map -CorrectionReceipt $f.input -Timestamp '2026-01-01T00:00:01Z' -OutPath $out -Execute
    $after=Read-MorphospaceProtocolJson (Join-Path $f.workspace 'workspace.state.json');$before.last_event_id=$after.last_event_id
    Assert-Correction ($result.executed-and(Get-MorphospaceCanonicalJsonSha256 $before)-eq(Get-MorphospaceCanonicalJsonSha256 $after)) 'state semantic diff was not exactly last_event_id'
    Assert-Correction ((Get-MorphospaceFileSha256 (Join-Path $f.workspace 'iteration-units\active-unit.json'))-eq$beforeUnit-and(Get-MorphospaceFileSha256 $out)-eq(Get-MorphospaceFileSha256 $f.input)) 'unit or installed artifact changed'

    foreach($case in @(
        @{name='preserve-mismatch';edit={$args[0].preserve_blocker_ids=@()}},
        @{name='unknown-field';edit={$args[0]|Add-Member -NotePropertyName unknown -NotePropertyValue $true}},
        @{name='clarification-unit-hash';edit={$args[0].authority_clarification.unit.sha256='0'*64}},
        @{name='clarification-pointer';edit={$args[0].authority_clarification.statement.json_pointer='/non_scope/1'}},
        @{name='clarification-text';edit={$args[0].authority_clarification.statement.exact_text='substituted'}},
        @{name='clarification-text-hash';edit={$args[0].authority_clarification.statement.exact_text_sha256='0'*64}},
        @{name='original-event';edit={$args[0].supersedes.event_id='wrong-event'}},
        @{name='original-receipt-path';edit={$args[0].supersedes.receipt.path='receipts/wrong.json'}},
        @{name='original-receipt-hash';edit={$args[0].supersedes.receipt.sha256='0'*64}},
        @{name='original-receipt-id';edit={$args[0].supersedes.original_receipt_id='wrong-original'}},
        @{name='intent-path';edit={$args[0].supersedes.intent.path='receipts/transactions/wrong.intent.json'}},
        @{name='intent-hash';edit={$args[0].supersedes.intent.sha256='0'*64}},
        @{name='completion-path';edit={$args[0].supersedes.completion.path='receipts/transactions/wrong.completion.json'}},
        @{name='completion-hash';edit={$args[0].supersedes.completion.sha256='0'*64}},
        @{name='source-omitted';edit={$args[0].repository_sources=@()}},
        @{name='source-extra';edit={$args[0].repository_sources+=,[pscustomobject]@{repo_id='extra-repo';sources=@([pscustomobject]@{path='src/current.txt';sha256='0'*64})}}},
        @{name='head-extra';edit={$args[0].repository_heads+=,[pscustomobject]@{repo_id='extra-repo';branch='main';revision='0'*40}}},
        @{name='source-escape';edit={$args[0].repository_sources[0].sources[0].path='../escape.txt'}},
        @{name='source-hash';edit={$args[0].repository_sources[0].sources[0].sha256='0'*64}}
    )){
        $x=New-CorrectionFixture $case.name;$r=Copy-Correction $x.receipt;&$case.edit $r;Assert-CorrectionRejected $x $r $case.name
    }
    $invalidIndex=0;$driveQualifiedPath=([string][char]67)+':/drive.txt'
    foreach($invalidPath in @('','/absolute.txt',$driveQualifiedPath,'//server/share.txt','../escape.txt','src/../escape.txt','./src.txt','src/','src//current.txt','src/./current.txt')){
        $invalidIndex++;$x=New-CorrectionFixture "invalid-path-$invalidIndex";$r=Copy-Correction $x.receipt;$r.repository_sources[0].sources[0].path=$invalidPath;Assert-CorrectionRejected $x $r "invalid-path-$invalidIndex"
    }
    $link=New-CorrectionFixture 'reparse-target';$linkPath=Join-Path $link.repo 'src\linked.txt';$linkMade=$false
    try{New-Item -ItemType SymbolicLink -Path $linkPath -Target (Join-Path $link.repo 'src\current.txt') -ErrorAction Stop|Out-Null;$linkMade=$true}catch{Write-Host "Correction reparse-target test skipped: $($_.Exception.Message)"}
    if($linkMade){$r=Copy-Correction $link.receipt;$r.repository_sources[0].sources[0].path='src/linked.txt';Assert-CorrectionRejected $link $r 'reparse-target'}
    $ancestor=New-CorrectionFixture 'reparse-ancestor';$real=Join-Path $ancestor.repo 'real';[IO.Directory]::CreateDirectory($real)|Out-Null;[IO.File]::WriteAllText((Join-Path $real 'current.txt'),'corrected',[Text.UTF8Encoding]::new($false));$ancestorLink=Join-Path $ancestor.repo 'linked';$ancestorMade=$false
    try{New-Item -ItemType SymbolicLink -Path $ancestorLink -Target $real -ErrorAction Stop|Out-Null;$ancestorMade=$true}catch{Write-Host "Correction reparse-ancestor test skipped: $($_.Exception.Message)"}
    if($ancestorMade){$r=Copy-Correction $ancestor.receipt;$r.repository_sources[0].sources[0].path='linked/current.txt';Assert-CorrectionRejected $ancestor $r 'reparse-ancestor'}
    $present=New-CorrectionFixture 'target-present';$s=Read-MorphospaceProtocolJson (Join-Path $present.workspace 'workspace.state.json');$s.blockers=@($s.blockers)+[pscustomobject]$present.target;Write-CorrectionJson (Join-Path $present.workspace 'workspace.state.json') $s;Assert-CorrectionRejected $present $present.receipt 'target-present'
    foreach($damage in @('receipt','intent','completion')){
        $x=New-CorrectionFixture "missing-$damage";$binding=$x.receipt.supersedes.$damage;$path=Join-Path $x.workspace ($binding.path-replace'/','\');Remove-Item -LiteralPath $path -Force;Assert-CorrectionRejected $x $x.receipt "missing-$damage"
    }
    $identity=New-CorrectionFixture 'original-identity';$p=Join-Path $identity.workspace ($identity.receipt.supersedes.receipt.path-replace'/','\');$old=[IO.File]::ReadAllBytes($p);$doc=Read-MorphospaceProtocolJson $p;$doc.receipt_id='wrong-original';Write-CorrectionJson $p $doc;$identity.receipt.supersedes.receipt.sha256=Get-MorphospaceFileSha256 $p;Assert-CorrectionRejected $identity $identity.receipt 'original-identity'
    $chain=New-CorrectionFixture 'completion-chain';$cp=Join-Path $chain.workspace ($chain.receipt.supersedes.completion.path-replace'/','\');$c=Read-MorphospaceProtocolJson $cp;$c.intent.sha256='0'*64;Write-CorrectionJson $cp $c;$chain.receipt.supersedes.completion.sha256=Get-MorphospaceFileSha256 $cp;Assert-CorrectionRejected $chain $chain.receipt 'completion-chain'
    $race=New-CorrectionFixture 'source-race';$bytes=[IO.File]::ReadAllBytes((Join-Path $race.repo 'src\current.txt'));$hook={[IO.File]::WriteAllText((Join-Path $race.repo 'src\current.txt'),'race',[Text.UTF8Encoding]::new($false))}.GetNewClosure();Assert-CorrectionRejected $race $race.receipt 'source-race' $hook {[IO.File]::WriteAllBytes((Join-Path $race.repo 'src\current.txt'),$bytes)}
    foreach($kind in @('state','unit','tail')){
        $x=New-CorrectionFixture "stale-$kind";$hook={
            if($kind-eq'state'){$s=Read-MorphospaceProtocolJson (Join-Path $x.workspace 'workspace.state.json');$s.concurrent='change';Write-CorrectionJson (Join-Path $x.workspace 'workspace.state.json') $s}
            elseif($kind-eq'unit'){$u=Read-MorphospaceProtocolJson (Join-Path $x.workspace 'iteration-units\active-unit.json');$u.concurrent='change';Write-CorrectionJson (Join-Path $x.workspace 'iteration-units\active-unit.json') $u}
            else{Add-Content -LiteralPath (Join-Path $x.workspace 'iteration-events.jsonl') -Value '{\"event_id\":\"concurrent-tail\",\"sequence\":3}' -Encoding utf8}
        }.GetNewClosure()
        $out=Join-Path $x.workspace "receipts\stale-$kind.json";$rejected=$false;try{Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $x.workspace -UnitId active-unit -RepoMapPath $x.map -CorrectionReceipt $x.input -OutPath $out -Execute -BeforeTransitionHook $hook|Out-Null}catch{$rejected=$true};Assert-Correction ($rejected-and-not(Test-Path $out)) "stale $kind CAS was accepted"
    }
    $replay=New-CorrectionFixture 'replay';$first=Join-Path $replay.workspace 'receipts\first-correction.json';Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $replay.workspace -UnitId active-unit -RepoMapPath $replay.map -CorrectionReceipt $replay.input -OutPath $first -Execute|Out-Null
    $alternate=Join-Path $replay.workspace 'local\alternate.json';Write-CorrectionJson $alternate $replay.receipt;$rejected=$false;try{Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $replay.workspace -UnitId active-unit -RepoMapPath $replay.map -CorrectionReceipt $alternate -OutPath (Join-Path $replay.workspace 'receipts\alternate-output.json') -Execute|Out-Null}catch{$rejected=$true};Assert-Correction $rejected 'alternate-path replay was accepted'
    foreach($historicalDamage in @('missing-receipt','malformed-receipt','missing-intent','malformed-intent','missing-completion','malformed-completion','artifact-hash')){
        $damaged=New-CorrectionFixture "historical-$historicalDamage";$first=Join-Path $damaged.workspace 'receipts\first-correction.json';$done=Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $damaged.workspace -UnitId active-unit -RepoMapPath $damaged.map -CorrectionReceipt $damaged.input -OutPath $first -Execute
        $intent=Join-Path $damaged.workspace "receipts\transactions\$($done.event_id)-transition.intent.json";$completion=Join-Path $damaged.workspace "receipts\transactions\$($done.event_id)-transition.completion.json"
        if($historicalDamage-eq'missing-receipt'){Remove-Item $first -Force}
        elseif($historicalDamage-eq'malformed-receipt'){[IO.File]::WriteAllText($first,'{malformed',[Text.UTF8Encoding]::new($false))}
        elseif($historicalDamage-eq'missing-intent'){Remove-Item $intent -Force}
        elseif($historicalDamage-eq'malformed-intent'){[IO.File]::WriteAllText($intent,'{malformed',[Text.UTF8Encoding]::new($false))}
        elseif($historicalDamage-eq'missing-completion'){Remove-Item $completion -Force}
        elseif($historicalDamage-eq'malformed-completion'){[IO.File]::WriteAllText($completion,'{malformed',[Text.UTF8Encoding]::new($false))}
        else{$i=Read-MorphospaceProtocolJson $intent;$i.artifacts[0].sha256='0'*64;Write-CorrectionJson $intent $i}
        $next=Copy-Correction $damaged.receipt;$next.receipt_id="second-$historicalDamage";Write-CorrectionJson $damaged.input $next;$rejected=$false;try{Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $damaged.workspace -UnitId active-unit -RepoMapPath $damaged.map -CorrectionReceipt $damaged.input|Out-Null}catch{$rejected=$true};Assert-Correction $rejected "$historicalDamage historical correction damage was ignored"
    }
    $fault=New-CorrectionFixture 'artifact-repair';$faultOut=Join-Path $fault.workspace 'receipts\fault-correction.json';$interrupted=$false;try{Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $fault.workspace -UnitId active-unit -RepoMapPath $fault.map -CorrectionReceipt $fault.input -OutPath $faultOut -Execute -FaultAfter after-intent|Out-Null}catch{$interrupted=$true}
    Assert-Correction ($interrupted-and-not(Test-Path $faultOut)) 'intent interruption did not stop before artifact'
    Complete-MorphospaceTransitionLedger -WorkspaceRoot $fault.workspace -TransactionId 'active-unit-blocker-resolution-corrected-0003-transition' -Repair|Out-Null
    Assert-Correction ((Get-MorphospaceFileSha256 $faultOut)-eq(Get-MorphospaceFileSha256 $fault.input)) 'repair did not install exact correction artifact'
    Write-Host 'CorrectResolvedBlockerEvidence self-test passed.'
}finally{if([IO.Directory]::Exists($script:Root)){Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue}}
