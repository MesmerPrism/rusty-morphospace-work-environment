[CmdletBinding()]
param([string]$ActualInputPath='', [string]$RetainedSelectionPath='', [string]$ConsumerPath='', [switch]$ModeledNamespaceFixture)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceQuestBuildExecutorSelection.psm1') -Force -PassThru
function Assert-SelectionTest([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
function Assert-SelectionRefused([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Assert-SelectionTest $failed $Message}
$endpoint='repos/example/workflows/actions/runs/123'
foreach($suffix in @(@($endpoint),@('--method','GET',$endpoint),@($endpoint,'--method','GET'),@('--hostname','github.com',$endpoint),@('--method','GET',$endpoint,'--hostname','github.com'))){Test-MorphospaceQuestBuildExecutorApiGet -Arguments (@('gh','api')+$suffix) -Endpoint $endpoint}
foreach($suffix in @(@('--hostname','elsewhere.invalid',$endpoint),@('--hostname','github.com','--hostname','github.com',$endpoint),@('--method','POST',$endpoint),@('--method','GET','--method','GET',$endpoint),@($endpoint,$endpoint),@('https://api.github.com/'+$endpoint),@('-H','Accept: application/json',$endpoint),@('-f','x=y',$endpoint),@('--paginate',$endpoint))){Assert-SelectionRefused {Test-MorphospaceQuestBuildExecutorApiGet -Arguments (@('gh','api')+$suffix) -Endpoint $endpoint} 'Expanded GET grammar was accepted.'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('quest-executor-selection-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try{
    $schemaPath=Join-Path $PSScriptRoot '../schemas/quest-build-executor-selection-v1.schema.json'
    $schema=Get-Content -LiteralPath $schemaPath -Raw|ConvertFrom-Json -Depth 30
    $wire=[pscustomobject]@{schema='task.actual_legacy_executor_selection.v1';selected_utc='2026-01-01T00:00:00Z';executor_root=$fixture;executor_commit=('a'*40);executor_tree=('b'*40);executor_pins_sha256=('c'*64);acceptance_observation_sha256=('d'*64);qualification_observation_sha256=('e'*64);actual_acceptance_event='example-unit-accepted-0001';remote_ref='refs/heads/main';fresh_remote_observation=(('a'*40)+"`trefs/heads/main");current039_tooling_context_created=$false;owner_state_mutated=$false;installed_skills_changed=$false;publication_or_device_authority=$false}
    Assert-SelectionTest (Test-Json -Json ($wire|ConvertTo-Json) -SchemaFile $schemaPath) 'Exact fifteen-field compatibility wire was rejected.'
    $wire.owner_state_mutated=$true
    Assert-SelectionTest (-not(Test-Json -Json ($wire|ConvertTo-Json) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) 'Selection wire grants owner mutation.'
    $wire.owner_state_mutated=$false;$wire|Add-Member -NotePropertyName trusted -NotePropertyValue $true
    Assert-SelectionTest (-not(Test-Json -Json ($wire|ConvertTo-Json) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) 'Extra selection trust flag was admitted.'
    if($ConsumerPath){
        $tokens=$null;$errors=$null;$consumer=[Management.Automation.Language.Parser]::ParseFile($ConsumerPath,[ref]$tokens,[ref]$errors)
        Assert-SelectionTest ($errors.Count-eq0) 'Consumer source failed to parse.'
        $readers=@($consumer.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Read-RetainedBuildExecutorSelection'},$false));Assert-SelectionTest ($readers.Count-eq1) 'Consumer reader is not unique.'
        $names=@($readers[0].FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq'$names'},$true));Assert-SelectionTest ($names.Count-eq1) 'Consumer wire property declaration changed.'
        $values=@($names[0].Right.FindAll({param($n)$n-is[Management.Automation.Language.StringConstantExpressionAst]},$true)|ForEach-Object Value)
        $set=[Collections.Generic.HashSet[string]]::new([string[]]$values,[StringComparer]::Ordinal)
        Assert-SelectionTest ($set.Count-eq15-and$set.SetEquals([string[]]$schema.'$defs'.selection.required)) 'Public output no longer matches the actual fifteen-field consumer.'
    }
    $path=Join-Path $fixture 'raw.json';[IO.File]::WriteAllText($path,'{"value":1}',[Text.UTF8Encoding]::new($false))
    & $module {param($p) $bag=New-QuestSelectionObservation; $r=Get-QuestSelectionReference $p;[void](Read-QuestSelectionReference $r $bag);[IO.File]::AppendAllText($p,' ');$failed=$false;try{Assert-QuestSelectionObservation $bag}catch{$failed=$true};if(-not$failed){throw 'Observed proof drift was accepted.'}} $path
    & $module {param($root)
        $bag=New-QuestSelectionObservation;$snapshots=@()
        foreach($name in @('workspace.state.json','iteration-events.jsonl','unit.json')){
            $source=Join-Path $root $name;$target=Join-Path $root ('snapshot-'+$name)
            [IO.File]::WriteAllText($source,'{"retained":"accepted"}',[Text.UTF8Encoding]::new($false));[IO.File]::Copy($source,$target)
            $ref=Get-QuestSelectionReference $source;[void](Read-QuestSelectionReference $ref $bag);$snapshots+=,[pscustomobject]@{source_path=$source;snapshot=Get-QuestSelectionReference $target}
        }
        $proofs=@(Get-QuestSelectionRetainedProofs $bag $snapshots)
        foreach($snapshot in $snapshots){[IO.File]::WriteAllText($snapshot.source_path,'{"current":"successor"}',[Text.UTF8Encoding]::new($false))}
        $retained=New-QuestSelectionObservation;foreach($ref in $proofs){[void](Read-QuestSelectionReference $ref $retained)};Assert-QuestSelectionObservation $retained
        $refused=$false;try{Assert-QuestSelectionObservation $bag}catch{$refused=$true};Assert-QuestSelection $refused 'Snapshot substitution removed fresh original drift refusal.'
        [IO.File]::AppendAllText($snapshots[0].snapshot.path,' ')
        # Dictionary order is unspecified: explicitly check the damaged snapshot.
        $refused=$false;try{Read-QuestSelectionReference $snapshots[0].snapshot (New-QuestSelectionObservation)|Out-Null}catch{$refused=$true};Assert-QuestSelection $refused 'Retained snapshot drift was accepted.'
    } $fixture
    $git=@(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source;$gitRoot=Join-Path $fixture 'source';[void][IO.Directory]::CreateDirectory($gitRoot)
    function Invoke-SelectionFixtureGit([string[]]$Arguments){$value=&$git -C $gitRoot @Arguments 2>&1;if($LASTEXITCODE-ne0){throw "Selection Git fixture failed: $value"};($value-join"`n").Trim()}
    [void](Invoke-SelectionFixtureGit @('init','--initial-branch=main'));[IO.File]::WriteAllText((Join-Path $gitRoot 'source.txt'),'fixture',[Text.UTF8Encoding]::new($false));[void](Invoke-SelectionFixtureGit @('add','source.txt'));[void](Invoke-SelectionFixtureGit @('-c','user.name=Selection Test','-c','user.email=selection@example.invalid','commit','-m','fixture'))
    $head=Invoke-SelectionFixtureGit @('rev-parse','HEAD');$tree=Invoke-SelectionFixtureGit @('rev-parse','HEAD^{tree}')
    & $module {param($g,$r,$h,$t) Assert-QuestSelectionSourceIdentity $g $r $h $t} $git $gitRoot $head $tree
    [IO.File]::WriteAllText((Join-Path $gitRoot 'untracked.txt'),'new input',[Text.UTF8Encoding]::new($false))
    Assert-SelectionRefused {&$module {param($g,$r,$h,$t) Assert-QuestSelectionSourceIdentity $g $r $h $t} $git $gitRoot $head $tree} 'Late untracked source escaped final Git guard.'
    Remove-Item -LiteralPath (Join-Path $gitRoot 'untracked.txt')
    [void](Invoke-SelectionFixtureGit @('-c','user.name=Selection Test','-c','user.email=selection@example.invalid','commit','--allow-empty','-m','same-tree move'))
    Assert-SelectionRefused {&$module {param($g,$r,$h,$t) Assert-QuestSelectionSourceIdentity $g $r $h $t} $git $gitRoot $head $tree} 'Same-tree HEAD movement escaped final Git guard.'
    & $module {
        $source=[pscustomobject]@{base=[pscustomobject]@{commit=('a'*40);tree=('b'*40)};head=[pscustomobject]@{commit=('c'*40);tree=('d'*40)}}
        $receipt=[pscustomobject]@{schema='rusty.morphospace.workflow.affected_validation_check_evidence.v1';result='pass';mode='reused';source=$source;binding=[pscustomobject]@{check_id='example';platform='windows'};reused_from=[pscustomobject]@{receipt_sha256=('1'*64);source_head=$source.head};child=[pscustomobject]@{started=$false;exit_code=0;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;failure_kind=$null}}
        $row=[pscustomobject]@{check_id='example';platform='windows';result='pass';mode='reused';evidence_source=$source;immediate_reused_from=$receipt.reused_from}
        Test-QuestSelectionLeafJoin $row $receipt
        $row.evidence_source=[pscustomobject]@{base=$source.base;head=[pscustomobject]@{commit=('e'*40);tree=('d'*40)}}
        $failed=$false;try{Test-QuestSelectionLeafJoin $row $receipt}catch{$failed=$true};if(-not$failed){throw 'Reused origin was relabelled as the current head.'}
        $row.evidence_source=$source;$receipt.child.started=$true
        $failed=$false;try{Test-QuestSelectionLeafJoin $row $receipt}catch{$failed=$true};if(-not$failed){throw 'Reused receipt claimed actual execution.'}
    }
    if($ModeledNamespaceFixture){
        Assert-SelectionTest ($ActualInputPath-and$RetainedSelectionPath) 'Modeled namespace fixture needs explicit retained input and selection paths.'
        & $module {param($inputPath,$retainedPath,$testRoot)
            # This is a MODELED transport/namespace fixture, never an actual
            # owner execution, current acceptance, fresh selection or adoption.
            $originals=New-QuestSelectionObservation
            $v=Read-QuestSelectionJson (Get-QuestSelectionReference $inputPath) $originals
            $retained=Read-QuestSelectionJson (Get-QuestSelectionReference $retainedPath) $originals
            $retainedDirectory=Split-Path -Parent $retainedPath
            $acceptProofRef=Get-QuestSelectionReference (Join-Path $retainedDirectory 'ACCEPTANCE_OBSERVATION.json')
            $remoteProofRef=Get-QuestSelectionReference (Join-Path $retainedDirectory 'QUALIFICATION_OBSERVATION.json')
            Assert-QuestSelection ($acceptProofRef.sha256-ceq$retained.acceptance_observation_sha256-and$remoteProofRef.sha256-ceq$retained.qualification_observation_sha256) 'Retained fixture basis sibling hashes differ.'
            $basis=Read-QuestSelectionJson $acceptProofRef $originals;$remoteBasis=Read-QuestSelectionJson $remoteProofRef $originals
            Assert-QuestSelection ($retained.executor_commit-ceq$v.executor_commit-and$retained.executor_tree-ceq$v.candidate_tree-and$remoteBasis.fresh_remote_observation-ceq($v.executor_commit+"`t"+$remoteBasis.remote_ref)) 'Retained remote fixture basis differs from selected supplier.'
            $originalWorkspace=[IO.Path]::GetFullPath($v.subject.workspace)
            $owner=Join-Path $testRoot 'MODELED-owner';$capture=Join-Path $testRoot 'MODELED-accept-capture';$local=Join-Path $testRoot 'local'
            foreach($path in @($owner,$capture,$local)){[void][IO.Directory]::CreateDirectory($path)}
            $copied=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            function Copy-ModeledOwnerFile([string]$Relative){
                $source=Resolve-QuestSelectionRelative $originalWorkspace $Relative
                $ref=Get-QuestSelectionReference $source;$bytes=Read-QuestSelectionReference $ref $originals
                $destination=Join-Path $owner $Relative
                if($copied.Add($Relative)){[void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination));[IO.File]::WriteAllBytes($destination,$bytes)}
                return $destination
            }
            Assert-QuestSelection (@($basis.snapshot_sources).Count-eq3) 'Finite accepted checkpoint snapshots are absent.'
            foreach($row in $basis.snapshot_sources){
                $relative=[IO.Path]::GetRelativePath($originalWorkspace,[IO.Path]::GetFullPath($row.source_path)).Replace('\','/')
                [void](ConvertTo-MorphospaceProtocolRelativePath $relative)
                $bytes=Read-QuestSelectionReference $row.snapshot $originals;$target=Join-Path $owner $relative
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));[IO.File]::WriteAllBytes($target,$bytes);[void]$copied.Add($relative)
            }
            $state=Read-QuestSelectionJson (Get-QuestSelectionReference (Join-Path $owner 'workspace.state.json')) (New-QuestSelectionObservation)
            $unit=Read-QuestSelectionJson (Get-QuestSelectionReference (Join-Path $owner "iteration-units/$($v.subject.unit_id).json")) (New-QuestSelectionObservation)
            $events=@([IO.File]::ReadAllLines((Join-Path $owner 'iteration-events.jsonl'))|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String})
            Assert-QuestSelection ($state.last_event_id-ceq$basis.accepted_event-and$unit.status-ceq'accepted'-and$events[-1].event_id-ceq$basis.accepted_event) 'Retained fixture accepted checkpoint differs.'
            # Finite typed edges only: accepted unit receipts, its Accept
            # transaction, ordinary preparation/source lock and original capture.
            foreach($event in $events|Where-Object unit_id -ceq $v.subject.unit_id){foreach($relative in $event.receipts){[void](Copy-ModeledOwnerFile $relative)}}
            foreach($suffix in @('intent','completion')){[void](Copy-ModeledOwnerFile "receipts/transactions/$($basis.accepted_event)-transition.$suffix.json")}
            [void](Copy-ModeledOwnerFile $state.last_accepted_receipt)
            [void](Copy-ModeledOwnerFile $unit.source_composition.lock_path)
            $admissions=@();foreach($event in $events|Where-Object unit_id -ceq $v.subject.unit_id){foreach($relative in $event.receipts){$body=Read-QuestSelectionJson (Get-QuestSelectionReference (Join-Path $owner $relative)) (New-QuestSelectionObservation);if($body.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'){$admissions+=,$body}}}
            Assert-QuestSelection ($admissions.Count-eq1) 'Modeled fixture requires exactly one retained ordinary admission.'
            [void](Copy-ModeledOwnerFile $admissions[0].preparation.receipt_path)
            $oldCapture=Read-QuestSelectionOriginal $v.accept_original $originals
            $intent=$oldCapture.intent|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
            for($i=0;$i-lt$intent.argv.Count;$i++){
                $value=[string]$intent.argv[$i]
                if([IO.Path]::IsPathFullyQualified($value)){
                    $absolute=[IO.Path]::GetFullPath($value);$prefix=$originalWorkspace.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
                    if($absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$relative=[IO.Path]::GetRelativePath($originalWorkspace,$absolute).Replace('\','/');$intent.argv[$i]=Join-Path $owner $relative;if([IO.File]::Exists($absolute)){[void](Copy-ModeledOwnerFile $relative)}}
                    elseif($absolute-ceq$originalWorkspace){$intent.argv[$i]=$owner}
                }
            }
            $intent|Add-Member -NotePropertyName modeled_fixture -NotePropertyValue 'MODELED namespace only; no process or owner execution'
            $modeledIntent=Write-QuestSelectionNewJson (Join-Path $capture 'MODELED-INTENT.json') $intent
            $completion=$oldCapture.completion|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
            $completion.intent=$modeledIntent
            foreach($name in @('stdout','stderr')){
                $bytes=Read-QuestSelectionReference $oldCapture.completion.$name $originals;$target=Join-Path $capture ("MODELED-$name.bin");[IO.File]::WriteAllBytes($target,$bytes)
                $completion.$name=Get-QuestSelectionReference $target;$completion.streams.$name.raw=$completion.$name
            }
            $completion|Add-Member -NotePropertyName modeled_fixture -NotePropertyValue 'MODELED namespace/capture metadata; no process or owner execution'
            $modeledCompletion=Write-QuestSelectionNewJson (Join-Path $capture 'MODELED-COMPLETION.json') $completion
            $receiptRelative=[IO.Path]::GetRelativePath($originalWorkspace,[IO.Path]::GetFullPath($v.accept_receipt.path)).Replace('\','/')
            [void](Copy-ModeledOwnerFile $receiptRelative);$v.accept_receipt=Get-QuestSelectionReference (Join-Path $owner $receiptRelative);$v.accept_original=$modeledCompletion;$v.subject.workspace=$owner
            $report=Read-QuestSelectionJson $v.qualification.dynamic_raw $originals
            foreach($pair in @(@('repository',$report.repository),@('repository_id','work-environment'),@('origin',"https://github.com/$($report.repository).git"),@('remote_ref',$remoteBasis.remote_ref),@('schema','rusty.morphospace.quest_build_executor_selection_request.v1'))){$v|Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1]}
            $requestRef=Write-QuestSelectionNewJson (Join-Path $local 'MODELED-request.json') $v
            $output=Join-Path $local 'MODELED-selection'
            $script:selectionFixtureOriginalGit=(Get-Item Function:Invoke-QuestSelectionGit).ScriptBlock
            $script:selectionFixtureRemote=$remoteBasis.fresh_remote_observation+"`n";$script:selectionFixtureRemoteCalls=0
            $script:selectionFixtureExpectedRemote=@('ls-remote','--heads','origin',$v.remote_ref);$script:selectionFixtureRoot=[IO.Path]::GetFullPath($v.executor_root);$script:selectionFixtureGit=[IO.Path]::GetFullPath($v.git.path)
            try{
                function script:Invoke-QuestSelectionGit([string]$Git,[string]$Root,[string[]]$Arguments){
                    if(Test-QuestSelectionEqual $Arguments $script:selectionFixtureExpectedRemote){
                        Assert-QuestSelection ([IO.Path]::GetFullPath($Root)-ceq$script:selectionFixtureRoot-and[IO.Path]::GetFullPath($Git)-ceq$script:selectionFixtureGit-and$script:selectionFixtureRemoteCalls-eq0) 'Modeled remote seam scope/call differs.'
                        $script:selectionFixtureRemoteCalls++;return ,[Text.Encoding]::UTF8.GetBytes($script:selectionFixtureRemote)
                    }
                    return ,(& $script:selectionFixtureOriginalGit -Git $Git -Root $Root -Arguments $Arguments)
                }
                $created=New-MorphospaceQuestBuildExecutorSelection -InputPath $requestRef.path -ExpectedInputSha256 $requestRef.sha256 -OutputDirectory $output
                $fresh=Read-MorphospaceQuestBuildExecutorSelection -Path $created.path -ExpectedSha256 $created.sha256
                Assert-QuestSelection (@($fresh.selection.PSObject.Properties).Count-eq15-and@($fresh.source.files).Count-gt0) 'NEW modeled producer/reader output differs.'
                $modeledState=Get-Content -LiteralPath (Join-Path $owner 'workspace.state.json') -Raw|ConvertFrom-Json -Depth 100 -DateKind String
                $modeledState.current_unit='modeled-successor';$modeledState.last_event_id='modeled-successor-started'
                [IO.File]::WriteAllText((Join-Path $owner 'workspace.state.json'),($modeledState|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
                [IO.File]::AppendAllText((Join-Path $owner 'iteration-events.jsonl'),"{`"modeled_fixture`":true,`"event_id`":`"modeled-successor-started`"}`n",[Text.UTF8Encoding]::new($false))
                [void](Read-MorphospaceQuestBuildExecutorSelection -Path $created.path -ExpectedSha256 $created.sha256)
                $refused=$false;try{New-MorphospaceQuestBuildExecutorSelection -InputPath $requestRef.path -ExpectedInputSha256 $requestRef.sha256 -OutputDirectory (Join-Path $local 'MODELED-refused-current')|Out-Null}catch{if($_.Exception.Message-ceq'Current idle accepted owner boundary is required.'){$refused=$true}else{throw}}
                Assert-QuestSelection ($refused-and-not(Test-Path -LiteralPath (Join-Path $local 'MODELED-refused-current'))) 'Modeled successor was promoted to current acceptance.'
                $snapshot=@($fresh.acceptance.snapshot_sources|Where-Object{[IO.Path]::GetFileName($_.source_path)-ceq'workspace.state.json'})
                Assert-QuestSelection ($snapshot.Count-eq1) 'NEW modeled producer state snapshot is absent.'
                [IO.File]::AppendAllText($snapshot[0].snapshot.path,' ',[Text.UTF8Encoding]::new($false))
                $refused=$false;try{Read-MorphospaceQuestBuildExecutorSelection -Path $created.path -ExpectedSha256 $created.sha256|Out-Null}catch{$refused=$true}
                Assert-QuestSelection $refused 'NEW retained consumer accepted damaged modeled snapshot.'
                Assert-QuestSelection ($script:selectionFixtureRemoteCalls-eq1) 'Expected exactly one modeled remote response.'
                [pscustomobject]@{schema='rusty.morphospace.test.modeled_executor_selection_assembly.v1';result='pass';namespace_and_remote_modeled=$true;capture_is_modeled_no_process_execution=$true;producer_function_called=$true;new_retained_reader_called=$true;owner_advance_retained_read_passed=$true;damaged_snapshot_refused=$true;current_owner_promotion_refused=$true;retained_qualification_source_unchanged=$true;regular_source_files=@($fresh.source.files).Count;finite_owner_files=$copied.Count;modeled_remote_calls=$script:selectionFixtureRemoteCalls;actual_acceptance_or_adoption=$false;network_used=$false}|ConvertTo-Json -Compress
            }finally{
                Set-Item Function:script:Invoke-QuestSelectionGit -Value $script:selectionFixtureOriginalGit
                Remove-Variable selectionFixtureOriginalGit,selectionFixtureRemote,selectionFixtureRemoteCalls,selectionFixtureExpectedRemote,selectionFixtureRoot,selectionFixtureGit -Scope Script -ErrorAction SilentlyContinue
                Assert-QuestSelectionObservation $originals
            }
        } $ActualInputPath $RetainedSelectionPath $fixture
    }
    if($ActualInputPath-and-not$ModeledNamespaceFixture){
        & $module {param($path)
            $v=Read-MorphospaceProtocolJson $path;$bag=New-QuestSelectionObservation
            $report=Read-QuestSelectionJson $v.qualification.dynamic_raw $bag
            $v|Add-Member -NotePropertyName repository -NotePropertyValue $report.repository
            $v|Add-Member -NotePropertyName repository_id -NotePropertyValue 'work-environment'
            $v|Add-Member -NotePropertyName origin -NotePropertyValue ("https://github.com/$($report.repository).git")
            $v|Add-Member -NotePropertyName remote_ref -NotePropertyValue 'refs/heads/main'
            $v|Add-Member -NotePropertyName schema -NotePropertyValue 'rusty.morphospace.quest_build_executor_selection_request.v1'
            Assert-QuestSelection (Test-Json -Json ($v|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $PSScriptRoot '../schemas/quest-build-executor-selection-v1.schema.json')) 'Actual generic request fails public schema.'
            $artifacts=@();$accept=Read-MorphospaceProtocolJson $v.accept_receipt.path
            $transition=Read-MorphospaceProtocolJson (Join-Path $v.subject.workspace "receipts/transactions/$($accept.event_id)-transition.intent.json")
            $validation=Read-MorphospaceProtocolJson (Join-Path $v.subject.workspace $transition.target.state.document.last_accepted_receipt)
            foreach($a in $validation.artifacts){$artifacts+=Get-QuestSelectionReference $a.path}
            $result=Get-QuestSelectionQualification $v $artifacts $bag
            $accepted=[pscustomobject]@{original=Read-QuestSelectionOriginal $v.accept_original $bag}
            [void](Get-QuestSelectionPublication $v $accepted $result $bag)
            $source=Get-QuestSelectionSource $v $result $bag
            # Authenticate the actual immutable accepted transaction as evidence,
            # without claiming it is the currently active owner's acceptance tail.
            $checkpoint=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $v.subject.workspace -TransactionId "$($accept.event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$($v.subject.unit_id).json" -ExpectedEventsPath 'iteration-events.jsonl'
            Assert-QuestSelection ($checkpoint.intent.target.unit.document.status-ceq'accepted'-and$checkpoint.intent.event.event_id-ceq$accept.event_id) 'Actual retained public acceptance checkpoint differs.'
            Assert-QuestSelectionObservation $bag
            $busyRefused=$false;try{Get-QuestSelectionAcceptedBoundary $v (New-QuestSelectionObservation)|Out-Null}catch{if($_.Exception.Message-ceq'Current idle accepted owner boundary is required.'){$busyRefused=$true}else{throw}}
            Assert-QuestSelection $busyRefused 'Earlier actual Accept was promoted over the active owner tail.'
            [pscustomobject]@{actual_qualification_rows=$result.counts.selected_rows;executed=$result.counts.executed;reused=$result.counts.reused;source_files=@($source.files).Count;current_tail_promoted=$false}
        } $ActualInputPath
    }
    if($RetainedSelectionPath-and-not$ModeledNamespaceFixture){[void](Read-MorphospaceQuestBuildExecutorSelection -Path $RetainedSelectionPath -ExpectedSha256 ((Get-FileHash -LiteralPath $RetainedSelectionPath -Algorithm SHA256).Hash.ToLowerInvariant()))}
    [pscustomobject]@{schema='rusty.morphospace.test.quest_build_executor_selection.v1';result='pass';network_used=$false;owner_mutated=$false;device_used=$false}|ConvertTo-Json -Compress
}finally{
    $full=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Selection test fixture escaped temp.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
