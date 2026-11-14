[CmdletBinding()]
param([switch]$SelfTest,[switch]$PositiveOnly,[switch]$KeepFixture)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Test-SourceOnlyPublication.ps1') -FixtureOnly

function Local-Reference($f,$path){[pscustomobject]@{path=[IO.Path]::GetRelativePath($f.workspace,$path).Replace('\','/');bytes=([IO.FileInfo]$path).Length;sha256=(Hash $path)}}
function New-CheckedResult($f,$directory,$name,$code,$time){
    $stdout=Join-Path $directory "$name.stdout";$stderr=Join-Path $directory "$name.stderr"
    [IO.File]::WriteAllText($stdout,"actual fixture $name outcome $code",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false))
    $path=Join-Path $directory "$name.result.json"
    $stdoutReference=Local-Reference $f $stdout;$stdoutReference.path=$stdout
    $stderrReference=Local-Reference $f $stderr;$stderrReference.path=$stderr
    Write-Json $path @{exit_code=$code;original_wait_returned=$true;stdout_eof=$true;stderr_eof=$true;completed_utc=$time;elapsed_seconds=1.0;stdout=$stdoutReference;stderr=$stderrReference}
    $reference=Local-Reference $f $path;$reference.path=$path
    return $reference
}
function New-FailureFixture($root){
    # An earlier isolated builder may force-import the same ledger in its own
    # module scope. Bind this fixture's original writer explicitly each time.
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -Global -Force
    $f=New-Fixture $root 'fixture-unmerged-failure' -SingleSource
    $planning=Split-Path $f.workspace -Parent
    [IO.File]::AppendAllText((Join-Path $planning '.git/info/exclude'),"morphospace/local/`nlocal/`n",[Text.UTF8Encoding]::new($false))
    $ownedPlan=Join-Path $f.workspace 'receipts/fixture-unmerged-failure-plan.json'
    Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationPlan $f.plan_path -ExpectedSourceOnlyPublicationPlanSha256 $f.plan_hash -OutPath $ownedPlan -Timestamp '2026-01-01T00:01:00.0000000Z' -Execute|Out-Null
    $directory=Join-Path $planning 'local/failure';[IO.Directory]::CreateDirectory($directory)|Out-Null
    $inputsOwner=Import-Module (Join-Path $PSScriptRoot 'SourceOnlyPublicationInputs.psm1') -PassThru
    $start=Join-Path $directory 'start.json'
    & $inputsOwner {param($p,$r,$o) Start-MorphospaceSourceOnlyPublicationOperation -PlanPath $p -RepoId $r -OutPath $o -Timestamp '2026-01-01T00:02:00.0000000Z'} $ownedPlan $f.private.id $start|Out-Null
    Git $f.private.repo @('push','origin','HEAD:refs/heads/codex/candidate')|Out-Null
    $row=$f.plan.source_repositories[0]
    $snapshot=@{head=$row.candidate_revision;tree=$row.candidate_tree;branch=$row.candidate_branch;upstream=$row.upstream;status='';remote=$row.remote_url}
    $push=Join-Path $directory 'push.json'
    Write-Json $push @{before=$snapshot;after=$snapshot;remote_before=@{'refs/heads/main'=$row.old_revision};remote_after=@{'refs/heads/main'=$row.old_revision;'refs/heads/codex/candidate'=$row.candidate_revision};force_used=$false;upstream_changed=$false;completed_utc='2026-01-01T00:02:11.0000000Z';original_checked_result=(New-CheckedResult $f $directory push 0 '2026-01-01T00:02:10.0000000Z')}
    $pr=Join-Path $directory 'pr.json';$prUrl='https://github.com/fixture/source/pull/17'
    Write-Json $pr @{number=17;url=$prUrl;candidate=$row.candidate_revision;created_utc='2026-01-01T00:02:21.0000000Z';original_checked_result=(New-CheckedResult $f $directory pr 0 '2026-01-01T00:02:20.0000000Z')}
    $watch=New-CheckedResult $f $directory watch 1 '2026-01-01T00:02:30.0000000Z'
    $failure=Join-Path $directory 'failure.json'
    Write-Json $failure @{schema='rusty.morphospace.workflow.source_only_publication_failure_evidence.v1';publication_id=$f.plan.publication_id;project_id='fixture-project';trigger_unit_id='fixture-unit';repo_id=$f.private.id;executor_id='fixture-executor';plan_sha256=(Hash $ownedPlan);capsule_root='../local/failure';operation_start=(Local-Reference $f $start);push_verification=(Local-Reference $f $push);pull_request=(Local-Reference $f $pr);required_check_watch=$watch}
    $providerPath=Join-Path $directory 'provider.json'
    Write-Json $providerPath @{number=17;html_url=$prUrl;state='open';merged=$false;merged_at=$null;base=@{sha=$row.old_revision;ref='main';repo=@{full_name='fixture/source';clone_url=$row.remote_url}};head=@{sha=$row.candidate_revision;ref=$row.candidate_branch;repo=@{full_name='fixture/source'}}}
    $provider=[pscustomobject]@{pull_request=[pscustomobject]@{number=17;url=$prUrl;state='OPEN';isCrossRepository=$false;headRefName=$row.candidate_branch;headRefOid=$row.candidate_revision;baseRefName='main';baseRefOid=$row.old_revision;mergedAt=$null;mergeCommit=$null};required_checks=@([pscustomobject]@{name='Required fixture CI';state='FAILURE';bucket='fail';link='https://github.com/fixture/source/actions/runs/1'})}
    & $sourceOnly {param($p) $script:FailureProviderFixture=$p;function script:Get-SourceOnlyFailureProviderReadback {param($Context,$Planned,$PullRequest) return $script:FailureProviderFixture}} $provider
    $inputPath=Join-Path $directory 'retirement-input.json'
    New-MorphospaceSourceOnlyPublicationRetirement -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -PlanPath $ownedPlan -ProviderObservationPaths @($providerPath) -FailureEvidencePath $failure -ExpectedFailureEvidenceSha256 (Hash $failure) -Reason 'Known failed required check requires a distinct reviewed candidate.' -Timestamp '2026-01-01T00:03:00.0000000Z' -OutPath $inputPath|Out-Null
    $canonicalInput=& $sourceOnly {param($p) ConvertTo-MorphospaceProtocolJsonBytes (Read-MorphospaceProtocolJson $p)} $inputPath
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($inputPath))-cne[Convert]::ToBase64String([byte[]]$canonicalInput)){throw 'Retirement constructor output is not owner canonical UTF-8 LF bytes.'}
    $f|Add-Member input_path $inputPath;$f|Add-Member failure_path $failure;$f|Add-Member provider $provider;$f|Add-Member directory $directory
    return $f
}
function Invoke-FixtureRetirement($f,$path,$hash,[bool]$execute=$true,$stage='none'){
    Invoke-MorphospaceRetireSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId fixture-unit -RepoMapPath $f.map -SourceOnlyPublicationRetirement $path -ExpectedSourceOnlyPublicationRetirementSha256 $hash -Timestamp '2026-01-01T00:04:00.0000000Z' -OutPath (Join-Path $f.workspace 'receipts/fixture-unmerged-failure-retirement.json') -Execute:$execute -FaultAfter $stage
}
function Rebind-FixtureFailure($f){
    $failure=Read-Json $f.failure_path
    $failure.push_verification=Local-Reference $f (Join-Path $f.directory 'push.json')
    $failure.required_check_watch=Local-Reference $f (Join-Path $f.directory 'watch.result.json')
    Write-Json $f.failure_path $failure
    $input=Read-Json $f.input_path;$input.failure_evidence=Local-Reference $f $f.failure_path;Write-Json $f.input_path $input
}
function Exercise-FailureRetirement($stage='none'){
    $root=Join-Path ([IO.Path]::GetTempPath())('source-only-retirement-'+[guid]::NewGuid().ToString('N'))
    try{
        $f=New-FailureFixture $root;$inputPath=$f.input_path;$hash=Hash $inputPath
        $unitHash=Hash (Join-Path $f.workspace 'iteration-units/fixture-unit.json');$planHash=Hash (Join-Path $f.workspace 'receipts/fixture-unmerged-failure-plan.json');$prefix=[IO.File]::ReadAllBytes((Join-Path $f.workspace 'iteration-events.jsonl'))
        if($stage-ceq'none'){
            foreach($damage in @('subject','plan','pending','unknown','merge','force','not-closed','unknown-children','stream','ref','feature-ref')){
                $before=[IO.File]::ReadAllBytes($inputPath);$failureBefore=[IO.File]::ReadAllBytes($f.failure_path);$providerBefore=Copy-Document $f.provider
                $expected='*'
                try{
                    switch($damage){
                        subject {$bad=Read-Json $inputPath;$bad.trigger_unit_id='other-unit';Write-Json $inputPath $bad;$expected='*identity drifted*'}
                        plan {$planPath=Join-Path $f.workspace 'receipts/fixture-unmerged-failure-plan.json';$planBefore=[IO.File]::ReadAllBytes($planPath);[IO.File]::AppendAllText($planPath,' ');$expected='*plan binding drifted*'}
                        pending {$statePath=Join-Path $f.workspace 'workspace.state.json';$stateBefore=[IO.File]::ReadAllBytes($statePath);$bad=Read-Json $statePath;$bad.pending_push_bundle.bundle_id='other-bundle';Write-Json $statePath $bad;$expected='*projection*'}
                        unknown {$f.provider.required_checks[0].bucket='pending';$f.provider.required_checks[0].state='IN_PROGRESS';$expected='*outcome is unknown*'}
                        merge {$f.provider.pull_request.mergedAt='2026-01-01T00:03:10.0000000Z';$expected='*PR is merged*'}
                        force {$pushPath=Join-Path $f.directory 'push.json';$pushBefore=[IO.File]::ReadAllBytes($pushPath);$bad=Read-Json $pushPath;$bad.force_used=$true;Write-Json $pushPath $bad;Rebind-FixtureFailure $f;$expected='*push used force*'}
                        not-closed {$watchPath=Join-Path $f.directory 'watch.result.json';$watchBefore=[IO.File]::ReadAllBytes($watchPath);$bad=Read-Json $watchPath;$bad.stdout_eof=$false;Write-Json $watchPath $bad;Rebind-FixtureFailure $f;$expected='*not closed*'}
                        unknown-children {$watchPath=Join-Path $f.directory 'watch.result.json';$watchBefore=[IO.File]::ReadAllBytes($watchPath);$bad=Read-Json $watchPath;$bad|Add-Member children @('unknown');Write-Json $watchPath $bad;Rebind-FixtureFailure $f;$expected='*damaged property set*'}
                        stream {$streamPath=Join-Path $f.directory 'watch.stdout';$streamBefore=[IO.File]::ReadAllBytes($streamPath);[IO.File]::AppendAllText($streamPath,'tampered');$expected='*bytes or hash drifted*'}
                        ref {Git $f.private.remote @('update-ref','refs/heads/main',$f.private.candidate)|Out-Null;$expected='*target or feature readback drifted*'}
                        feature-ref {Git $f.private.remote @('update-ref','refs/heads/codex/candidate',$f.private.old)|Out-Null;$expected='*target or feature readback drifted*'}
                    }
                    & $sourceOnly {param($p)$script:FailureProviderFixture=$p} $f.provider
                    Assert-Rejected {Invoke-FixtureRetirement $f $inputPath (Hash $inputPath)} "failure retirement $damage" $expected $f.workspace
                }finally{
                    [IO.File]::WriteAllBytes($inputPath,$before);[IO.File]::WriteAllBytes($f.failure_path,$failureBefore)
                    if($damage-ceq'plan'){[IO.File]::WriteAllBytes($planPath,$planBefore)}
                    if($damage-ceq'pending'){[IO.File]::WriteAllBytes($statePath,$stateBefore)}
                    if($damage-ceq'force'){[IO.File]::WriteAllBytes($pushPath,$pushBefore)}
                    if($damage-in@('not-closed','unknown-children')){[IO.File]::WriteAllBytes($watchPath,$watchBefore)}
                    if($damage-ceq'stream'){[IO.File]::WriteAllBytes($streamPath,$streamBefore)}
                    if($damage-ceq'ref'){Git $f.private.remote @('update-ref','refs/heads/main',$f.private.old)|Out-Null}
                    if($damage-ceq'feature-ref'){Git $f.private.remote @('update-ref','refs/heads/codex/candidate',$f.private.candidate)|Out-Null}
                    $f.provider=$providerBefore;& $sourceOnly {param($p)$script:FailureProviderFixture=$p} $f.provider
                }
            }
            $dry=Invoke-FixtureRetirement $f $inputPath $hash $false
            if($dry.executed){throw 'Retirement dry run executed.'}
        }else{
            Assert-Fault {Invoke-FixtureRetirement $f $inputPath $hash $true $stage} "retire $stage" $f
            Assert-Rejected {Invoke-FixtureRetirement $f $inputPath $hash $false} 'interrupted dry replay' '*requires -Execute recovery*' $f.workspace
            $changed=Join-Path $f.directory 'changed-input.json';[IO.File]::WriteAllText($changed,(Get-Content -Raw $inputPath)+' ',[Text.UTF8Encoding]::new($false))
            Assert-Rejected {Invoke-FixtureRetirement $f $changed (Hash $changed)} 'interruption changed input' '*caller bytes do not match*' $f.workspace
        }
        Invoke-FixtureRetirement $f $inputPath $hash|Out-Null
        $state=Read-Json (Join-Path $f.workspace 'workspace.state.json')
        if($null-ne$state.pending_push_bundle-or$state.last_event_id-cne'fixture-unmerged-failure-source-publication-retired'-or$state.current_unit-or$state.next_ready_unit){throw 'Retirement state changed outside exact pending bundle.'}
        if($unitHash-cne(Hash (Join-Path $f.workspace 'iteration-units/fixture-unit.json'))-or$planHash-cne(Hash (Join-Path $f.workspace 'receipts/fixture-unmerged-failure-plan.json'))){throw 'Retirement rewrote accepted unit or plan.'}
        $after=[IO.File]::ReadAllBytes((Join-Path $f.workspace 'iteration-events.jsonl'));if([Convert]::ToBase64String($prefix)-cne[Convert]::ToBase64String($after[0..($prefix.Length-1)])){throw 'Retirement rewrote event prefix.'}
        Assert-Rejected {Invoke-FixtureRetirement $f $inputPath $hash} 'terminal duplicate' '*already retired*' $f.workspace
        Assert-CurrentWork $f "Retire/$stage"
        if($stage-ceq'none'){
            $streamPath=Join-Path $f.directory 'watch.stdout';$streamBefore=[IO.File]::ReadAllBytes($streamPath)
            try{[IO.File]::AppendAllText($streamPath,'post-retirement tamper');Assert-Rejected {Assert-CurrentWork $f 'damaged retained stream'} 'current-work retained stream tamper' '*bytes or hash drifted*' $f.workspace}finally{[IO.File]::WriteAllBytes($streamPath,$streamBefore)}
        }
        "Retirement fixture $stage passed."
    }finally{if($KeepFixture){"Retained isolated fixture: $root"}else{Remove-FixtureRoot $root}}
}
Exercise-FailureRetirement
if(-not$PositiveOnly){foreach($stage in @('after-intent','after-artifact','after-projection','after-event')){Exercise-FailureRetirement $stage}}
'Source-only known-partial failure retirement self-test passed.'
