param([switch]$SelfTest)

$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'EventLedgerPrefixNormalization.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HistoricalSupersessionCompatibility.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalSupersessionCompatibility.psm1') -Force
$script:HscTransitionModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force -PassThru
$script:HscProtocolModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force -PassThru

function Read-MorphospaceProtocolJson([string]$Path){&$script:HscProtocolModule {param($p)Read-MorphospaceProtocolJson $p} $Path}
function ConvertTo-MorphospaceCanonicalJson([object]$Value){&$script:HscProtocolModule {param($v)ConvertTo-MorphospaceCanonicalJson $v} $Value}
function Get-MorphospaceCanonicalJsonSha256([object]$Value){&$script:HscProtocolModule {param($v)Get-MorphospaceCanonicalJsonSha256 $v} $Value}
function Get-MorphospaceFileSha256([string]$Path){&$script:HscProtocolModule {param($p)Get-MorphospaceFileSha256 $p} $Path}
function Get-MorphospaceSha256Bytes([byte[]]$Bytes){&$script:HscProtocolModule {param($b)Get-MorphospaceSha256Bytes $b} $Bytes}
function Invoke-HscOwnerTransition([hashtable]$Arguments){&$script:HscTransitionModule {param($a)Start-MorphospaceTransitionLedger @a} $Arguments}

function Assert-HscTest([bool]$Value,[string]$Message){if(-not$Value){throw "Historical supersession compatibility self-test failed: $Message"}}
function Copy-HscTest([object]$Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String}
function Write-HscTestJson([string]$Path,[object]$Value){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText($Path,(ConvertTo-MorphospaceCanonicalJson $Value)+"`n",[Text.UTF8Encoding]::new($false))}
function Get-HscTestBytes([object]$Value){[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Value)+"`n")}
function Invoke-HscTestGit([string]$Root,[string[]]$Arguments){$output=@(& git -C $Root @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "Fixture Git failed: git $($Arguments-join' ')`n$($output-join"`n")"};@($output)}
function Assert-HscRejected([scriptblock]$Action,[string]$Label){$rejected=$false;try{&$Action|Out-Null}catch{$rejected=$true};Assert-HscTest $rejected "accepted $Label damage"}
function Update-HscLegacyIntentCompletion([string]$Workspace,[scriptblock]$Mutation){
    $intentPath=Join-Path $Workspace 'receipts\transactions\unit011-superseded-by-unit013-transition.intent.json'
    $completionPath=Join-Path $Workspace 'receipts\transactions\unit011-superseded-by-unit013-transition.completion.json'
    $intent=Read-MorphospaceProtocolJson $intentPath;&$Mutation $intent;Write-HscTestJson $intentPath $intent
    $completion=Read-MorphospaceProtocolJson $completionPath;$completion.intent.sha256=Get-MorphospaceFileSha256 $intentPath;Write-HscTestJson $completionPath $completion
}

function New-HscUnit([string]$Id,[string]$Status,[string]$LockPath){
    $unit=Read-MorphospaceProtocolJson (Join-Path $repoRoot 'templates\iteration-unit.example.json')
    $unit.unit_id=$Id;$unit.project_id='hsc-project';$unit.status=$Status
    $unit.source_composition.mode='exact-lock';$unit.source_composition.lock_path=$LockPath;$unit.source_composition.materialization_receipt=$null
    $unit
}

function New-HscSourceLock([string]$UnitId,[string]$LockId){
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.source_composition_lock.v1';lock_id=$LockId;created_at='2026-01-03T00:00:00.0000000Z'
        project_id='hsc-project';unit_id=$UnitId;fingerprint='a'*64
        repositories=@([pscustomobject][ordered]@{repo_id='fixture-repo';role='source';commit='1'*40;tree='2'*40;branch='main';remote_url=$null;materialization_path='fixture-repo';tracked_worktree_clean=$true})
        status='locked';does_not_prove=@('Fixture source lock does not prove validation or publication.')
    }
}

function Install-HscLegacySuccessor {
    param([string]$Workspace)
    $oldId='unit011';$newId='unit013';$eventId="$oldId-superseded-by-$newId";$transactionId="$eventId-transition"
    $state=Read-MorphospaceProtocolJson (Join-Path $Workspace 'workspace.state.json')
    $old=Read-MorphospaceProtocolJson (Join-Path $Workspace 'iteration-units\unit011.json')
    $lockPath='source-compositions/unit013-source.lock.json'
    $new=New-HscUnit $newId 'active' $lockPath
    $lock=New-HscSourceLock $newId 'unit013-source-lock'
    $targetState=Copy-HscTest $state;$targetState.current_unit=$newId;$targetState.next_ready_unit=$null;$targetState.last_event_id=$eventId;$targetState.plan_revision=[int]$targetState.plan_revision+1
    $targetOld=Copy-HscTest $old
    $transitionEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=4;timestamp='2026-01-04T00:00:00.0000000Z';project_id='hsc-project';unit_id=$oldId;event_type='state-transition';summary='Legacy owner moved authority to the exact successor artifacts.';receipts=@()}
    $eventsPath=Join-Path $Workspace 'iteration-events.jsonl';$eventsBytes=[IO.File]::ReadAllBytes($eventsPath)
    $unitBytes=Get-HscTestBytes $new;$lockBytes=Get-HscTestBytes $lock
    $intent=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.transition_ledger_intent.v1';transaction_id=$transactionId;created_at='2026-01-04T00:00:00.0000000Z'
        state=[pscustomobject]@{path='workspace.state.json'};unit=[pscustomobject]@{path='iteration-units/unit011.json'};events=[pscustomobject]@{path='iteration-events.jsonl'}
        pre=[pscustomobject]@{state=[pscustomobject]@{sha256=Get-MorphospaceCanonicalJsonSha256 $state};unit=[pscustomobject]@{sha256=Get-MorphospaceCanonicalJsonSha256 $old}}
        target=[pscustomobject]@{state=[pscustomobject]@{sha256=Get-MorphospaceCanonicalJsonSha256 $targetState;document=$targetState};unit=[pscustomobject]@{sha256=Get-MorphospaceCanonicalJsonSha256 $targetOld;document=$targetOld}}
        expected=[pscustomobject]@{state_sha256=Get-MorphospaceCanonicalJsonSha256 $state;unit_sha256=Get-MorphospaceCanonicalJsonSha256 $old;event_tail_id='ledger-normalized-0003';events_sha256=Get-MorphospaceSha256Bytes $eventsBytes;events_length=[int64]$eventsBytes.LongLength}
        artifacts=@(
            [pscustomobject]@{path='iteration-units/unit013.json';sha256=Get-MorphospaceSha256Bytes $unitBytes;bytes_base64=[Convert]::ToBase64String($unitBytes)},
            [pscustomobject]@{path=$lockPath;sha256=Get-MorphospaceSha256Bytes $lockBytes;bytes_base64=[Convert]::ToBase64String($lockBytes)}
        )
        event=$transitionEvent;status='prepared'
    }
    $intentRelative="receipts/transactions/$transactionId.intent.json";$completionRelative="receipts/transactions/$transactionId.completion.json"
    Write-HscTestJson (Join-Path $Workspace $intentRelative) $intent
    [IO.Directory]::CreateDirectory((Join-Path $Workspace 'source-compositions'))|Out-Null
    [IO.File]::WriteAllBytes((Join-Path $Workspace 'iteration-units\unit013.json'),$unitBytes)
    [IO.File]::WriteAllBytes((Join-Path $Workspace $lockPath),$lockBytes)
    Write-HscTestJson (Join-Path $Workspace 'workspace.state.json') $targetState
    [IO.File]::AppendAllText($eventsPath,(ConvertTo-MorphospaceCanonicalJson $transitionEvent)+"`n",[Text.UTF8Encoding]::new($false))
    $completion=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.transition_ledger_completion.v1';transaction_id=$transactionId;completed_at='2026-01-04T00:00:01.0000000Z'
        intent=[pscustomobject]@{role='transition-ledger-intent';path=$intentRelative;schema=[string]$intent.schema;sha256=Get-MorphospaceFileSha256 (Join-Path $Workspace $intentRelative)}
        state_sha256=[string]$intent.target.state.sha256;unit_sha256=[string]$intent.target.unit.sha256;event_id=$eventId;status='committed'
    }
    Write-HscTestJson (Join-Path $Workspace $completionRelative) $completion
}

function Add-HscAcceptance([string]$Workspace){
    $state=Read-MorphospaceProtocolJson (Join-Path $Workspace 'workspace.state.json');$unit=Read-MorphospaceProtocolJson (Join-Path $Workspace 'iteration-units\unit013.json')
    $targetState=Copy-HscTest $state;$targetState.current_unit=$null;$targetState.next_ready_unit=$null;$targetState.last_event_id='unit013-accepted-0005'
    $targetUnit=Copy-HscTest $unit;$targetUnit.status='accepted'
    $transitionEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit013-accepted-0005';sequence=5;timestamp='2026-01-05T00:00:00.0000000Z';project_id='hsc-project';unit_id='unit013';event_type='state-transition';summary='Accepted the legacy successor after its owner validation.';receipts=@()}
    Invoke-HscOwnerTransition @{WorkspaceRoot=$Workspace;TransactionId='unit013-accepted-0005-transition';StatePath='workspace.state.json';UnitPath='iteration-units/unit013.json';EventsPath='iteration-events.jsonl';TargetState=$targetState;TargetUnit=$targetUnit;Event=$transitionEvent;ExpectedPreStateSha256=Get-MorphospaceCanonicalJsonSha256 $state;ExpectedPreUnitSha256=Get-MorphospaceCanonicalJsonSha256 $unit}|Out-Null
}

function New-HscFixture([string]$Base,[string]$Name){
    $repository=Join-Path $Base $Name;$workspace=Join-Path $repository 'morphospace'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts\transactions'))|Out-Null
    $project=Read-MorphospaceProtocolJson (Join-Path $repoRoot 'templates\project.spec.v2.example.json');$project.project_id='hsc-project'
    $state=Read-MorphospaceProtocolJson (Join-Path $repoRoot 'templates\workspace.state.v2.example.json');$state.project_id='hsc-project';$state.current_unit='unit011';$state.next_ready_unit=$null;$state.last_event_id='unit010-superseded-by-unit011'
    $old=New-HscUnit 'unit010' 'active' 'source-compositions/unit010.lock.json';$replacement=New-HscUnit 'unit011' 'active' 'source-compositions/unit011.lock.json'
    Write-HscTestJson (Join-Path $workspace 'project.spec.json') $project;Write-HscTestJson (Join-Path $workspace 'workspace.state.json') $state
    Write-HscTestJson (Join-Path $workspace 'iteration-units\unit010.json') $old;Write-HscTestJson (Join-Path $workspace 'iteration-units\unit011.json') $replacement
    $first=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit009-accepted-0001';sequence=1;timestamp='2026-01-01T00:00:00.0000000Z';project_id='hsc-project';unit_id='unit009';event_type='state-transition';summary='Accepted prior fixture authority.';receipts=@()}
    $legacy=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit010-superseded-by-unit011';sequence=2;timestamp='2026-01-02T00:00:00.0000000Z';project_id='hsc-project';unit_id='unit010';event_type='state-transition';summary='Legacy transactionless supersession fixture.';receipts=@()}
    $ledger="`r`n$(ConvertTo-MorphospaceCanonicalJson $first)`r`n$(ConvertTo-MorphospaceCanonicalJson $legacy)`r`n"
    [IO.File]::WriteAllBytes((Join-Path $workspace 'iteration-events.jsonl'),[Text.UTF8Encoding]::new($false).GetBytes($ledger))
    [void](Invoke-HscTestGit $repository @('init','-b','codex/hsc-test'));[void](Invoke-HscTestGit $repository @('config','user.email','hsc@example.invalid'));[void](Invoke-HscTestGit $repository @('config','user.name','HSC Test'));[void](Invoke-HscTestGit $repository @('add','--all'));[void](Invoke-HscTestGit $repository @('commit','-m','fixture'))
    $head=((Invoke-HscTestGit $repository @('rev-parse','HEAD'))-join'').Trim()
    $projectHash=Get-MorphospaceFileSha256 (Join-Path $workspace 'project.spec.json');$stateHash=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json');$unitHash=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\unit011.json');$eventsPath=Join-Path $workspace 'iteration-events.jsonl';$eventsHash=Get-MorphospaceFileSha256 $eventsPath;$eventsLength=[IO.FileInfo]::new($eventsPath).Length
    $plan=Invoke-MorphospaceEventLedgerPrefixNormalization -WorkspaceRoot $workspace -NormalizationId 'ledger-normalized-0003' -UnitId 'unit011' -ExpectedRepositoryHead $head -ExpectedProjectSha256 $projectHash -ExpectedStateSha256 $stateHash -ExpectedUnitSha256 $unitHash -ExpectedEventsSha256 $eventsHash -ExpectedEventsLength $eventsLength -ExpectedEventTailId 'unit010-superseded-by-unit011' -Timestamp '2026-01-03T00:00:00.0000000Z'
    [void](Invoke-MorphospaceEventLedgerPrefixNormalization -WorkspaceRoot $workspace -NormalizationId 'ledger-normalized-0003' -UnitId 'unit011' -ExpectedRepositoryHead $head -ExpectedProjectSha256 $projectHash -ExpectedStateSha256 $stateHash -ExpectedUnitSha256 $unitHash -ExpectedEventsSha256 $eventsHash -ExpectedEventsLength $eventsLength -ExpectedEventTailId 'unit010-superseded-by-unit011' -Timestamp '2026-01-03T00:00:00.0000000Z' -ExpectedIntentSha256 ([string]$plan.intent_sha256) -Execute)
    Install-HscLegacySuccessor $workspace;Add-HscAcceptance $workspace
    [pscustomobject]@{repository=$repository;workspace=$workspace}
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('hsc-owner-'+[guid]::NewGuid().ToString('N'))
try{
    $fixture=New-HscFixture $temp 'positive';$reviewedInput=Join-Path $temp 'reviewed-hsc.json'
    $receipt=New-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $fixture.workspace -OldUnitId unit010 -ReplacementUnitId unit011 -NormalizationId ledger-normalized-0003 -CompatibilityId historical-supersession-compatible-0006 -Timestamp '2026-01-06T00:00:00.0000000Z'
    Write-HscTestJson $reviewedInput $receipt;$inputHash=Get-MorphospaceFileSha256 $reviewedInput;$out=Join-Path $fixture.workspace 'receipts\historical-supersession-compatible-0006.json'
    $before=@(Get-ChildItem $fixture.workspace -Recurse -File|Sort-Object FullName|ForEach-Object{"$($_.FullName.Substring($fixture.workspace.Length))=$(Get-MorphospaceFileSha256 $_.FullName)"})
    $dry=Invoke-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $fixture.workspace -CompatibilityReceipt $reviewedInput -OutPath $out
    $afterDry=@(Get-ChildItem $fixture.workspace -Recurse -File|Sort-Object FullName|ForEach-Object{"$($_.FullName.Substring($fixture.workspace.Length))=$(Get-MorphospaceFileSha256 $_.FullName)"})
    Assert-HscTest (-not$dry.executed-and$null-eq$dry.event_id-and($before-join"`n")-ceq($afterDry-join"`n")) 'dry run mutated workspace or claimed execution'
    $preapplyTemplate=Join-Path $temp 'preapply-template';Copy-Item $fixture.repository $preapplyTemplate -Recurse
    $oldBefore=[IO.File]::ReadAllBytes((Join-Path $fixture.workspace 'iteration-units\unit010.json'));$replacementBefore=[IO.File]::ReadAllBytes((Join-Path $fixture.workspace 'iteration-units\unit011.json'))
    $run=Invoke-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $fixture.workspace -CompatibilityReceipt $reviewedInput -ExpectedCompatibilityReceiptSha256 $inputHash -OutPath $out -Execute
    Assert-HscTest ($run.executed-and[string]$run.event_id-ceq'historical-supersession-compatible-0006') 'owner execution did not emit its exact event'
    Assert-HscTest ([Convert]::ToHexString($oldBefore)-ceq[Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $fixture.workspace 'iteration-units\unit010.json')))) 'owner execution rewrote the old unit'
    Assert-HscTest ([Convert]::ToHexString($replacementBefore)-ceq[Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $fixture.workspace 'iteration-units\unit011.json')))) 'owner execution rewrote the replacement unit'
    Assert-HscTest (-not(Test-Path (Join-Path $fixture.workspace 'receipts\transactions\unit010-superseded-by-unit011-transition.intent.json'))) 'owner execution synthesized the missing historical intent'
    [void](Test-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $fixture.workspace -ReceiptPath $out -Mode PostApply)
    $replay=Invoke-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $fixture.workspace -CompatibilityReceipt $reviewedInput -ExpectedCompatibilityReceiptSha256 $inputHash -OutPath $out -Execute
    Assert-HscTest ($replay.executed-and[string]$replay.event_id-ceq'historical-supersession-compatible-0006') 'exact committed replay was not idempotent'

    $cliOut=@(& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action RecordHistoricalSupersessionCompatibility -WorkspaceRoot $fixture.workspace -HistoricalSupersessionCompatibility $reviewedInput -ExpectedHistoricalSupersessionCompatibilitySha256 $inputHash -OutPath $out -Execute)
    if($LASTEXITCODE-ne0){throw "public action replay failed: $($cliOut-join"`n")"};$cliText=$cliOut-join"`n";$cli=$cliText.Substring($cliText.IndexOf('{'))|ConvertFrom-Json -DateKind String
    Assert-HscTest ($cli.executed-and[string]$cli.action-ceq'RecordHistoricalSupersessionCompatibility') 'public router did not preserve exact action replay'

    foreach($cut in @('after-intent','after-artifact','after-projection','after-event')){
        $copy=Join-Path $temp "interrupt-$cut";Copy-Item $preapplyTemplate $copy -Recurse
        $copyWorkspace=Join-Path $copy 'morphospace'
        $copyInput=Join-Path $temp "input-$cut.json";Copy-Item $reviewedInput $copyInput
        $interrupted=$false;try{Invoke-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $copyWorkspace -CompatibilityReceipt $copyInput -ExpectedCompatibilityReceiptSha256 $inputHash -OutPath (Join-Path $copyWorkspace 'receipts\historical-supersession-compatible-0006.json') -Execute -FaultAfter $cut|Out-Null}catch{$interrupted=$true}
        $resumed=Invoke-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $copyWorkspace -CompatibilityReceipt $copyInput -ExpectedCompatibilityReceiptSha256 $inputHash -OutPath (Join-Path $copyWorkspace 'receipts\historical-supersession-compatible-0006.json') -Execute
        Assert-HscTest ($interrupted-and$resumed.executed) "interruption $cut did not repair forward"
    }

    $pendingDamage=Join-Path $temp 'pending-target-damage';Copy-Item $preapplyTemplate $pendingDamage -Recurse
    $pendingWorkspace=Join-Path $pendingDamage 'morphospace';$pendingInput=Join-Path $temp 'pending-target-damage.json';Copy-Item $reviewedInput $pendingInput
    $pendingInterrupted=$false;try{Invoke-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $pendingWorkspace -CompatibilityReceipt $pendingInput -ExpectedCompatibilityReceiptSha256 $inputHash -OutPath (Join-Path $pendingWorkspace 'receipts\historical-supersession-compatible-0006.json') -Execute -FaultAfter after-intent|Out-Null}catch{$pendingInterrupted=$true}
    Assert-HscTest $pendingInterrupted 'pending target-damage fixture did not stop after intent'
    $pendingIntentPath=Join-Path $pendingWorkspace 'receipts\transactions\historical-supersession-compatible-0006-transition.intent.json'
    $pendingIntent=Read-MorphospaceProtocolJson $pendingIntentPath;$pendingIntent.target.state.document.plan_revision=[int]$pendingIntent.target.state.document.plan_revision+1;$pendingIntent.target.state.sha256=Get-MorphospaceCanonicalJsonSha256 $pendingIntent.target.state.document;Write-HscTestJson $pendingIntentPath $pendingIntent
    Assert-HscRejected {Invoke-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $pendingWorkspace -CompatibilityReceipt $pendingInput -ExpectedCompatibilityReceiptSha256 $inputHash -OutPath (Join-Path $pendingWorkspace 'receipts\historical-supersession-compatible-0006.json') -Execute} 'self-consistent pending target-state'

    $damageCases=@(
        [pscustomobject]@{name='old-unit';action={param($w)$p=Join-Path $w 'iteration-units\unit010.json';$d=Read-MorphospaceProtocolJson $p;$d.objective='damaged';Write-HscTestJson $p $d}},
        [pscustomobject]@{name='replacement-unit';action={param($w)$p=Join-Path $w 'iteration-units\unit011.json';$d=Read-MorphospaceProtocolJson $p;$d.objective='damaged';Write-HscTestJson $p $d}},
        [pscustomobject]@{name='normalization-intent';action={param($w)$p=Join-Path $w 'receipts\transactions\ledger-normalized-0003-normalization.intent.json';$d=Read-MorphospaceProtocolJson $p;$d.project.document_sha256='0'*64;Write-HscTestJson $p $d}},
        [pscustomobject]@{name='missing-normalization-completion';action={param($w)Remove-Item (Join-Path $w 'receipts\transactions\ledger-normalized-0003-normalization.completion.json')}},
        [pscustomobject]@{name='legacy-successor-intent';action={param($w)$p=Join-Path $w 'receipts\transactions\unit011-superseded-by-unit013-transition.intent.json';$d=Read-MorphospaceProtocolJson $p;$d.pre.state.sha256='0'*64;Write-HscTestJson $p $d}},
        [pscustomobject]@{name='legacy-events-sha';action={param($w)Update-HscLegacyIntentCompletion $w {param($d)$d.expected.events_sha256='0'*64}}},
        [pscustomobject]@{name='legacy-events-length';action={param($w)Update-HscLegacyIntentCompletion $w {param($d)$d.expected.events_length=[int64]$d.expected.events_length+1}}},
        [pscustomobject]@{name='missing-source-composition';action={param($w)Remove-Item (Join-Path $w 'source-compositions\unit013-source.lock.json')}},
        [pscustomobject]@{name='tampered-source-composition';action={param($w)$p=Join-Path $w 'source-compositions\unit013-source.lock.json';$d=Read-MorphospaceProtocolJson $p;$d.fingerprint='0'*64;Write-HscTestJson $p $d}},
        [pscustomobject]@{name='legacy-artifact-order';action={param($w)Update-HscLegacyIntentCompletion $w {param($d)$first=$d.artifacts[0];$d.artifacts[0]=$d.artifacts[1];$d.artifacts[1]=$first}}},
        [pscustomobject]@{name='missing-compatibility-completion';action={param($w)Remove-Item (Join-Path $w 'receipts\transactions\historical-supersession-compatible-0006-transition.completion.json')}},
        [pscustomobject]@{name='fabricated-missing-intent';action={param($w)Write-HscTestJson (Join-Path $w 'receipts\transactions\unit010-superseded-by-unit011-transition.intent.json') ([pscustomobject]@{fabricated=$true})}}
    )
    foreach($case in $damageCases){$copy=Join-Path $temp "damage-$($case.name)";Copy-Item $fixture.repository $copy -Recurse;$workspace=Join-Path $copy 'morphospace';&$case.action $workspace;Assert-HscRejected {Test-MorphospaceHistoricalSupersessionCompatibility -WorkspaceRoot $workspace -ReceiptPath (Join-Path $workspace 'receipts\historical-supersession-compatible-0006.json') -Mode PostApply} $case.name}

    $laterState=Read-MorphospaceProtocolJson (Join-Path $fixture.workspace 'workspace.state.json');$laterUnit=Read-MorphospaceProtocolJson (Join-Path $fixture.workspace 'iteration-units\unit010.json')
    $laterTargetState=Copy-HscTest $laterState;$laterTargetState.last_event_id='later-owner-transition-0007'
    $laterEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='later-owner-transition-0007';sequence=7;timestamp='2026-01-07T00:00:00.0000000Z';project_id='hsc-project';unit_id='unit010';event_type='state-transition';summary='Appended a later valid owner transition after the compatibility proof.';receipts=@()}
    Invoke-HscOwnerTransition @{WorkspaceRoot=$fixture.workspace;TransactionId='later-owner-transition-0007-transition';StatePath='workspace.state.json';UnitPath='iteration-units/unit010.json';EventsPath='iteration-events.jsonl';TargetState=$laterTargetState;TargetUnit=$laterUnit;Event=$laterEvent;ExpectedPreStateSha256=Get-MorphospaceCanonicalJsonSha256 $laterState;ExpectedPreUnitSha256=Get-MorphospaceCanonicalJsonSha256 $laterUnit}|Out-Null
    $historicalMap=Get-MorphospaceHistoricalSupersessionCompatibilityMap -WorkspaceRoot $fixture.workspace -ProjectId 'hsc-project'
    Assert-HscTest ($historicalMap.Count-eq2-and$historicalMap.ContainsKey('unit010')-and$historicalMap.ContainsKey('unit011')) 'later valid transition made the historical compatibility map unusable'
    Write-Host 'Historical supersession compatibility self-test passed.'
}finally{if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
