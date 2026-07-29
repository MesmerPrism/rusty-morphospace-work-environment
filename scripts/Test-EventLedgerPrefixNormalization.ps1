$ErrorActionPreference='Stop'

$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'EventLedgerPrefixNormalization.psm1') -Force
$normalizationModule=Get-Module EventLedgerPrefixNormalization
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Assert-NormalizationTest {
    param([bool]$Value,[string]$Message)
    if(-not$Value){throw "Event-ledger prefix normalization self-test failed: $Message"}
}

function Write-NormalizationTestJson {
    param([string]$Path,[object]$Document)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null
    [IO.File]::WriteAllText($Path,(ConvertTo-MorphospaceCanonicalJson $Document)+"`n",[Text.UTF8Encoding]::new($false))
}

function Invoke-NormalizationTestGit {
    param([string]$Repository,[string[]]$Arguments)
    $output=@(& git -C $Repository @Arguments 2>&1)
    if($LASTEXITCODE-ne0){throw "Fixture Git command failed: git $($Arguments-join' ')`n$($output-join"`n")"}
    return @($output)
}

function New-NormalizationFixture {
    param(
        [string]$Base,
        [string]$Name,
        [ValidateSet('crlf','lf','double-crlf','interior-blank','none')][string]$PrefixCase='crlf',
        [string]$EventProject='normalization-test',
        [string]$StateTail='prior-event-0001'
    )
    $repo=Join-Path $Base $Name
    $workspace=Join-Path $repo 'morphospace'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units'))|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts\transactions'))|Out-Null
    $project=Read-MorphospaceProtocolJson (Join-Path $root 'templates\project.spec.v2.example.json')
    $project.project_id='normalization-test'
    $state=Read-MorphospaceProtocolJson (Join-Path $root 'templates\workspace.state.v2.example.json')
    $state.project_id='normalization-test'
    $state.current_unit='current-unit-001'
    $state.next_ready_unit=$null
    $state.last_event_id=$StateTail
    $unit=Read-MorphospaceProtocolJson (Join-Path $root 'templates\iteration-unit.example.json')
    $unit.unit_id='current-unit-001'
    $unit.project_id='normalization-test'
    $unit.status='active'
    $event=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1'
        event_id='prior-event-0001'
        sequence=1
        timestamp='2026-01-01T00:00:00.0000000Z'
        project_id=$EventProject
        unit_id='current-unit-001'
        event_type='state-transition'
        summary='Fixture prior event.'
        receipts=@()
    }
    Write-NormalizationTestJson (Join-Path $workspace 'project.spec.json') $project
    Write-NormalizationTestJson (Join-Path $workspace 'workspace.state.json') $state
    Write-NormalizationTestJson (Join-Path $workspace 'iteration-units\current-unit-001.json') $unit
    $eventText=$event|ConvertTo-Json -Depth 16 -Compress
    $ledgerText=switch($PrefixCase){
        'crlf'{"`r`n$eventText`r`n"}
        'lf'{"`n$eventText`r`n"}
        'double-crlf'{"`r`n`r`n$eventText`r`n"}
        'interior-blank'{"`r`n$eventText`r`n`r`n"}
        'none'{"$eventText`r`n"}
    }
    [IO.File]::WriteAllBytes((Join-Path $workspace 'iteration-events.jsonl'),[Text.UTF8Encoding]::new($false).GetBytes($ledgerText))
    [void](Invoke-NormalizationTestGit $repo @('init','-b','codex/normalization-test'))
    [void](Invoke-NormalizationTestGit $repo @('config','user.email','normalization@example.invalid'))
    [void](Invoke-NormalizationTestGit $repo @('config','user.name','Normalization Test'))
    [void](Invoke-NormalizationTestGit $repo @('add','--all'))
    [void](Invoke-NormalizationTestGit $repo @('commit','-m','fixture'))
    $eventsPath=Join-Path $workspace 'iteration-events.jsonl'
    [pscustomobject]@{
        repo=$repo
        workspace=$workspace
        project=$project
        state=$state
        unit=$unit
        head=((Invoke-NormalizationTestGit $repo @('rev-parse','HEAD'))-join'').Trim()
        project_sha=Get-MorphospaceFileSha256 (Join-Path $workspace 'project.spec.json')
        state_sha=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json')
        unit_sha=Get-MorphospaceFileSha256 (Join-Path $workspace 'iteration-units\current-unit-001.json')
        events_sha=Get-MorphospaceFileSha256 $eventsPath
        events_length=[IO.File]::ReadAllBytes($eventsPath).LongLength
        tail='prior-event-0001'
    }
}

function Invoke-NormalizationFixture {
    param(
        [object]$Fixture,
        [string]$NormalizationId='event-ledger-prefix-normalized-0002',
        [switch]$Execute,
        [string]$ExpectedRepositoryHead='',
        [string]$ExpectedProjectSha256='',
        [string]$ExpectedStateSha256='',
        [string]$ExpectedUnitSha256='',
        [string]$ExpectedEventsSha256='',
        [long]$ExpectedEventsLength=-1,
        [string]$ExpectedEventTailId='',
        [ValidateSet('none','after-intent','after-receipt','after-state','after-events')][string]$FaultAfter='none'
    )
    if(-not$ExpectedRepositoryHead){$ExpectedRepositoryHead=$Fixture.head}
    if(-not$ExpectedProjectSha256){$ExpectedProjectSha256=$Fixture.project_sha}
    if(-not$ExpectedStateSha256){$ExpectedStateSha256=$Fixture.state_sha}
    if(-not$ExpectedUnitSha256){$ExpectedUnitSha256=$Fixture.unit_sha}
    if(-not$ExpectedEventsSha256){$ExpectedEventsSha256=$Fixture.events_sha}
    if($ExpectedEventsLength-lt0){$ExpectedEventsLength=$Fixture.events_length}
    if(-not$ExpectedEventTailId){$ExpectedEventTailId=$Fixture.tail}
    Invoke-MorphospaceEventLedgerPrefixNormalization -WorkspaceRoot $Fixture.workspace `
        -NormalizationId $NormalizationId -UnitId 'current-unit-001' `
        -ExpectedRepositoryHead $ExpectedRepositoryHead -ExpectedProjectSha256 $ExpectedProjectSha256 `
        -ExpectedStateSha256 $ExpectedStateSha256 -ExpectedUnitSha256 $ExpectedUnitSha256 `
        -ExpectedEventsSha256 $ExpectedEventsSha256 -ExpectedEventsLength $ExpectedEventsLength `
        -ExpectedEventTailId $ExpectedEventTailId -Timestamp '2026-01-02T00:00:00.0000000Z' `
        -Execute:$Execute -FaultAfter $FaultAfter
}

function Assert-NormalizationRejected {
    param([scriptblock]$Action,[string]$Message,[string]$Pattern='')
    $rejected=$false;$observed=''
    try{&$Action|Out-Null}catch{$rejected=$true;$observed=$_.Exception.Message}
    Assert-NormalizationTest $rejected "$Message was accepted"
    if($Pattern){Assert-NormalizationTest ($observed-like$Pattern) "$Message rejection was not specific: $observed"}
}

$base=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-normalization-'+[guid]::NewGuid().ToString('N'))
try{
    $strict=New-NormalizationFixture $base 'ordinary-strict'
    $transition=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force -PassThru
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
    $strictState=Read-MorphospaceProtocolJson (Join-Path $strict.workspace 'workspace.state.json')
    $strictTarget=Read-MorphospaceProtocolJson (Join-Path $strict.workspace 'workspace.state.json')
    $strictTarget.last_event_id='ordinary-event-0002'
    $strictUnit=Read-MorphospaceProtocolJson (Join-Path $strict.workspace 'iteration-units\current-unit-001.json')
    $strictEvent=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1';event_id='ordinary-event-0002';sequence=2
        timestamp='2026-01-02T00:00:00.0000000Z';project_id='normalization-test';unit_id='current-unit-001'
        event_type='state-transition';summary='Ordinary strict parser fixture.';receipts=@()
    }
    Assert-NormalizationRejected {
        Start-MorphospaceTransitionLedger -WorkspaceRoot $strict.workspace -TransactionId 'ordinary-event-0002-transition' `
            -StatePath 'workspace.state.json' -UnitPath 'iteration-units/current-unit-001.json' -EventsPath 'iteration-events.jsonl' `
            -TargetState $strictTarget -TargetUnit $strictUnit -Event $strictEvent
    } 'ordinary transition with leading CRLF' '*blank record at line 1*'
    Assert-NormalizationTest (-not(Test-Path (Join-Path $strict.workspace 'receipts\transactions\ordinary-event-0002-transition.intent.json'))) 'ordinary strict rejection wrote an intent'

    $success=New-NormalizationFixture $base 'success'
    $successLedgerBefore=[IO.File]::ReadAllBytes((Join-Path $success.workspace 'iteration-events.jsonl'))
    $successUnitBefore=[IO.File]::ReadAllBytes((Join-Path $success.workspace 'iteration-units\current-unit-001.json'))
    $successStateBefore=Read-MorphospaceProtocolJson (Join-Path $success.workspace 'workspace.state.json')
    $plan=Invoke-NormalizationFixture $success
    Assert-NormalizationTest ($plan.status-ceq'planned'-and$plan.execution-ceq'not-performed') 'plan result is not non-executing'
    Assert-NormalizationTest ((Get-MorphospaceFileSha256 (Join-Path $success.workspace 'iteration-events.jsonl'))-ceq$success.events_sha) 'plan changed ledger bytes'
    Assert-NormalizationTest (@(Invoke-NormalizationTestGit $success.repo @('status','--porcelain=v1','--untracked-files=all')).Count-eq0) 'plan dirtied Git'

    $result=Invoke-NormalizationFixture $success -Execute
    Assert-NormalizationTest ($result.status-ceq'committed') 'successful normalization did not commit'
    $afterBytes=[IO.File]::ReadAllBytes((Join-Path $success.workspace 'iteration-events.jsonl'))
    Assert-NormalizationTest ($afterBytes[0]-eq[byte][char]'{'-and$afterBytes[1]-ne0x0a) 'normalized ledger retained a leading blank record'
    $preserved=[byte[]]::new($successLedgerBefore.Length-2)
    [Array]::Copy($successLedgerBefore,2,$preserved,0,$preserved.Length)
    for($i=0;$i-lt$preserved.Length;$i++){if($afterBytes[$i]-ne$preserved[$i]){throw 'Event-ledger prefix normalization self-test failed: prior event bytes changed'}}
    $afterEvents=@(& $transition {param($bytes) Read-MorphospaceLedgerEvents -EventsPath 'test' -ProvidedBytes $bytes} $afterBytes)
    Assert-NormalizationTest ($afterEvents.Count-eq2-and$afterEvents[-1].sequence-eq2-and$afterEvents[-1].event_id-ceq'event-ledger-prefix-normalized-0002') 'normalized ledger event append is not canonical/contiguous'
    $targetState=Read-MorphospaceProtocolJson (Join-Path $success.workspace 'workspace.state.json')
    $expectedState=ConvertFrom-MorphospaceProtocolJsonBytes `
        -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $successStateBefore))) `
        -Context 'test state comparison'
    $expectedState.last_event_id='event-ledger-prefix-normalized-0002'
    Assert-NormalizationTest ((Get-MorphospaceCanonicalJsonSha256 $targetState)-ceq(Get-MorphospaceCanonicalJsonSha256 $expectedState)) 'normalization changed state beyond last_event_id'
    Assert-NormalizationTest ([Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $success.workspace 'iteration-units\current-unit-001.json')))-ceq[Convert]::ToHexString($successUnitBefore)) 'normalization changed current-unit bytes'
    foreach($artifact in @(
        [pscustomobject]@{path='receipts/event-ledger-prefix-normalized-0002.json';schema='rusty.morphospace.workflow.event_ledger_prefix_normalization.v1'},
        [pscustomobject]@{path='receipts/transactions/event-ledger-prefix-normalized-0002-normalization.intent.json';schema='rusty.morphospace.workflow.event_ledger_prefix_normalization_intent.v1'},
        [pscustomobject]@{path='receipts/transactions/event-ledger-prefix-normalized-0002-normalization.completion.json';schema='rusty.morphospace.workflow.event_ledger_prefix_normalization_completion.v1'}
    )){
        $document=Read-MorphospaceProtocolJson (Join-Path $success.workspace $artifact.path)
        Assert-NormalizationTest ([string]$document.schema-ceq[string]$artifact.schema) "wrong schema at $($artifact.path)"
    }
    Assert-NormalizationRejected {Invoke-NormalizationFixture $success -Execute} 'completed normalization replay' '*rejects replay*'

    foreach($case in @('lf','double-crlf','interior-blank','none')){
        $invalid=New-NormalizationFixture $base "invalid-$case" -PrefixCase $case
        Assert-NormalizationRejected {Invoke-NormalizationFixture $invalid} "$case framing" '*'
        Assert-NormalizationTest (@(Invoke-NormalizationTestGit $invalid.repo @('status','--porcelain=v1','--untracked-files=all')).Count-eq0) "$case rejection dirtied Git"
    }
    $wrongProject=New-NormalizationFixture $base 'wrong-project' -EventProject 'other-project'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $wrongProject} 'wrong-project preserved event' '*wrong project identity*'
    $wrongTail=New-NormalizationFixture $base 'wrong-tail' -StateTail 'different-tail-0001'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $wrongTail} 'state/event tail mismatch' '*event-tail CAS*'

    $wrongHash=New-NormalizationFixture $base 'wrong-hash'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $wrongHash -ExpectedEventsSha256 ('0'*64)} 'wrong event-ledger hash' '*event-ledger SHA-256 CAS*'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $wrongHash -ExpectedEventsLength ($wrongHash.events_length+1)} 'wrong event-ledger length' '*length CAS*'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $wrongHash -ExpectedRepositoryHead ('0'*40)} 'wrong repository head' '*repository-HEAD CAS*'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $wrongHash -ExpectedProjectSha256 ('0'*64)} 'wrong project hash' '*project file SHA-256 CAS*'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $wrongHash -ExpectedStateSha256 ('0'*64)} 'wrong state hash' '*state file SHA-256 CAS*'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $wrongHash -ExpectedUnitSha256 ('0'*64)} 'wrong current-unit hash' '*unit file SHA-256 CAS*'

    $occupied=New-NormalizationFixture $base 'occupied'
    Write-NormalizationTestJson (Join-Path $occupied.workspace 'receipts\event-ledger-prefix-normalized-0002.json') ([pscustomobject]@{occupied=$true})
    [void](Invoke-NormalizationTestGit $occupied.repo @('add','--all'))
    [void](Invoke-NormalizationTestGit $occupied.repo @('commit','-m','occupy normalization output'))
    $occupied.head=((Invoke-NormalizationTestGit $occupied.repo @('rev-parse','HEAD'))-join'').Trim()
    Assert-NormalizationRejected {Invoke-NormalizationFixture $occupied} 'occupied receipt target' '*target path is occupied*'

    $dirty=New-NormalizationFixture $base 'dirty'
    [IO.File]::WriteAllText((Join-Path $dirty.repo 'unrelated.txt'),'unrelated',[Text.UTF8Encoding]::new($false))
    Assert-NormalizationRejected {Invoke-NormalizationFixture $dirty} 'initial unrelated dirt' '*initially clean*'

    foreach($fault in @('after-intent','after-receipt','after-state','after-events')){
        $recovery=New-NormalizationFixture $base "recovery-$fault"
        Assert-NormalizationRejected {Invoke-NormalizationFixture $recovery -Execute -FaultAfter $fault} "$fault injection" '*Injected interruption*'
        $recovered=Invoke-NormalizationFixture $recovery -Execute
        Assert-NormalizationTest ($recovered.status-ceq'committed') "$fault did not recover to committed"
        Assert-NormalizationTest ((Get-MorphospaceFileSha256 (Join-Path $recovery.workspace 'iteration-units\current-unit-001.json'))-ceq$recovery.unit_sha) "$fault recovery changed current-unit bytes"
    }

    $drift=New-NormalizationFixture $base 'drift'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $drift -Execute -FaultAfter 'after-intent'} 'drift setup interruption' '*Injected interruption*'
    [IO.File]::AppendAllText((Join-Path $drift.repo 'unrelated.txt'),'drift',[Text.UTF8Encoding]::new($false))
    Assert-NormalizationRejected {Invoke-NormalizationFixture $drift -Execute} 'post-intent unrelated drift' '*unrelated Git dirt*'

    $ambiguous=New-NormalizationFixture $base 'ambiguous'
    Assert-NormalizationRejected {Invoke-NormalizationFixture $ambiguous -Execute -FaultAfter 'after-intent'} 'ambiguous setup interruption' '*Injected interruption*'
    [IO.File]::WriteAllText((Join-Path $ambiguous.workspace 'iteration-events.jsonl'),'ambiguous',[Text.UTF8Encoding]::new($false))
    Assert-NormalizationRejected {Invoke-NormalizationFixture $ambiguous -Execute} 'ambiguous event-ledger interruption' '*neither the exact before nor exact after*'

    $cli=New-NormalizationFixture $base 'cli'
    $cliJson=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action NormalizeEventLedgerPrefix `
        -WorkspaceRoot $cli.workspace -UnitId 'current-unit-001' -LedgerPrefixNormalizationId 'cli-ledger-prefix-normalized-0002' `
        -ExpectedRepositoryHead $cli.head -ExpectedProjectSha256 $cli.project_sha -ExpectedStateSha256 $cli.state_sha `
        -ExpectedUnitSha256 $cli.unit_sha -ExpectedEventsSha256 $cli.events_sha -ExpectedEventsLength $cli.events_length `
        -ExpectedEventTailId $cli.tail -Timestamp '2026-01-02T00:00:00.0000000Z'
    $cliPlan=$cliJson|ConvertFrom-Json
    Assert-NormalizationTest ($cliPlan.status-ceq'planned'-and$cliPlan.execution-ceq'not-performed') 'CLI action did not route to a non-executing plan'

    Write-Host 'Event-ledger prefix normalization self-test passed.'
}finally{
    if([IO.Directory]::Exists($base)){
        Get-ChildItem -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue|ForEach-Object{$_.Attributes=[IO.FileAttributes]::Normal}
        try{[IO.Directory]::Delete($base,$true)}catch{Write-Warning "Normalization test cleanup retained its exact temporary root: $base"}
    }
}
