$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$transitionModulePath = Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1'
Import-Module $transitionModulePath -Force
$transitionModule = Get-Module MorphospaceTransitionLedger

function Assert-Ledger {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw "Transition-ledger self-test failed: $Message" }
}

function Write-Json {
    param([string]$Path, [object]$Value)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 20 -Compress) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-LedgerDocumentHash {
    param([object]$Value)
    & $script:transitionModule {
        param($Document)
        Get-MorphospaceLedgerDocumentHash $Document
    } $Value
}

function New-LedgerEvent {
    param([string]$EventId,[int]$Sequence,[string]$Summary='Transition-ledger test event.')
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1'
        event_id=$EventId
        sequence=$Sequence
        timestamp='2026-01-01T00:00:00.0000000Z'
        project_id='ledger-test'
        unit_id='unit-test'
        event_type='state-transition'
        summary=$Summary
        receipts=@()
    }
}

function Enter-LedgerTestMutex {
    param([string]$WorkspaceRoot)
    & $script:transitionModule {
        param($Workspace)
        Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $Workspace
    } $WorkspaceRoot
}

function Exit-LedgerTestMutex {
    param([object]$Lock)
    & $script:transitionModule {
        param($WorkspaceLock)
        Exit-MorphospaceWorkspaceMutex $WorkspaceLock
    } $Lock
}

function Initialize-LedgerFixture {
    param([string]$WorkspaceRoot, [object]$State, [object]$Unit)
    [IO.Directory]::CreateDirectory((Join-Path $WorkspaceRoot 'receipts')) | Out-Null
    Write-Json (Join-Path $WorkspaceRoot 'workspace.state.json') $State
    Write-Json (Join-Path $WorkspaceRoot 'iteration-units\unit.json') $Unit
    [IO.File]::WriteAllText(
        (Join-Path $WorkspaceRoot 'iteration-events.jsonl'),
        '',
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-ConcurrentLedgerDriftTest {
    param(
        [string]$WorkspaceRoot,
        [ValidateSet('state', 'unit')][string]$DriftTarget,
        [string]$TransitionModulePath
    )
    $beforeState = [pscustomobject]@{schema='test';stage='before'}
    $beforeUnit = [pscustomobject]@{schema='test';status='validating'}
    $targetState = [pscustomobject]@{schema='test';stage='after'}
    $targetUnit = [pscustomobject]@{schema='test';status='accepted'}
    Initialize-LedgerFixture $WorkspaceRoot $beforeState $beforeUnit
    $expectedState = Get-LedgerDocumentHash $beforeState
    $expectedUnit = Get-LedgerDocumentHash $beforeUnit
    $eventId = "concurrent-$DriftTarget-drift"
    $transactionId = "$eventId-transition"
    $event = New-LedgerEvent $eventId 1
    $lock = Enter-LedgerTestMutex -WorkspaceRoot $WorkspaceRoot
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param(
                $ModulePath,
                $Workspace,
                $Transaction,
                $TargetState,
                $TargetUnit,
                $Event,
                $ExpectedState,
                $ExpectedUnit
            )
            $ErrorActionPreference = 'Stop'
            Import-Module $ModulePath -Force
            try {
                Start-MorphospaceTransitionLedger `
                    -WorkspaceRoot $Workspace `
                    -TransactionId $Transaction `
                    -StatePath 'workspace.state.json' `
                    -UnitPath 'iteration-units/unit.json' `
                    -EventsPath 'iteration-events.jsonl' `
                    -TargetState $TargetState `
                    -TargetUnit $TargetUnit `
                    -Event $Event `
                    -ExpectedPreStateSha256 $ExpectedState `
                    -ExpectedPreUnitSha256 $ExpectedUnit | Out-Null
                [pscustomobject]@{rejected=$false;message='transition unexpectedly committed'}
            } catch {
                [pscustomobject]@{rejected=$true;message=$_.Exception.Message}
            }
        } -ArgumentList @(
            $TransitionModulePath,
            $WorkspaceRoot,
            $transactionId,
            $targetState,
            $targetUnit,
            $event,
            $expectedState,
            $expectedUnit
        )
        Start-Sleep -Milliseconds 500
        Assert-Ledger ($job.State -in @('NotStarted', 'Running')) "$DriftTarget contender did not wait for the transition mutex"
        if ($DriftTarget -eq 'state') {
            Write-Json (Join-Path $WorkspaceRoot 'workspace.state.json') ([pscustomobject]@{schema='test';stage='concurrent-drift'})
        } else {
            Write-Json (Join-Path $WorkspaceRoot 'iteration-units\unit.json') ([pscustomobject]@{schema='test';status='concurrent-drift'})
        }
    } finally {
        Exit-LedgerTestMutex $lock
    }
    try {
        $output = @(Receive-Job -Job $job -Wait)
        $outcome = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'rejected' } | Select-Object -Last 1)
        Assert-Ledger ($outcome.Count -eq 1 -and $outcome[0].rejected) "$DriftTarget drift was not rejected"
        Assert-Ledger ([string]$outcome[0].message -match "expected pre-$DriftTarget SHA-256") "$DriftTarget drift rejection did not identify the stale expectation"
    } finally {
        if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
    $intentPath = Join-Path $WorkspaceRoot "receipts\transactions\$transactionId.intent.json"
    Assert-Ledger (-not [IO.File]::Exists($intentPath)) "$DriftTarget drift wrote a transition intent"
    Assert-Ledger (@(Get-Content (Join-Path $WorkspaceRoot 'iteration-events.jsonl') | Where-Object { $_ }).Count -eq 0) "$DriftTarget drift appended an event"
}

$workspace = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-ledger-' + [guid]::NewGuid().ToString('N'))
try {
    $state = [pscustomobject]@{schema='test';stage='before'}
    $unit = [pscustomobject]@{schema='test';status='validating'}
    $event = New-LedgerEvent 'unit-accept-0001' 1
    Initialize-LedgerFixture $workspace $state $unit
    $targetState = [pscustomobject]@{schema='test';stage='after'}
    $targetUnit = [pscustomobject]@{schema='test';status='accepted'}
    $expectedState = Get-LedgerDocumentHash $state
    $expectedUnit = Get-LedgerDocumentHash $unit
    $interrupted = $false
    try {
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $workspace `
            -TransactionId 'unit-accept-0001-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event $event `
            -ExpectedPreStateSha256 $expectedState `
            -ExpectedPreUnitSha256 $expectedUnit `
            -FaultAfter after-projection | Out-Null
    } catch {
        $interrupted = $true
    }
    Assert-Ledger $interrupted 'fault injection did not interrupt'
    $result = Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId 'unit-accept-0001-transition' -Repair
    Assert-Ledger ($result.status -eq 'committed') 'repair did not commit'
    Assert-Ledger ((Get-Content (Join-Path $workspace 'workspace.state.json') -Raw | ConvertFrom-Json).stage -eq 'after') 'repair did not preserve target state'
    Assert-Ledger (@(Get-Content (Join-Path $workspace 'iteration-events.jsonl') | Where-Object { $_ }).Count -eq 1) 'repair event count is not one'
    Assert-Ledger ((Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId 'unit-accept-0001-transition').status -eq 'already-committed') 'completion was not idempotent'

    $counterfeitWorkspace=Join-Path $workspace 'counterfeit-event'
    Initialize-LedgerFixture $counterfeitWorkspace $state $unit
    $counterfeitArtifactBytes=[Text.UTF8Encoding]::new($false).GetBytes('must remain uninstalled')
    $counterfeitArtifactHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($counterfeitArtifactBytes)).ToLowerInvariant()
    $counterfeitInterrupted=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $counterfeitWorkspace `
            -TransactionId 'counterfeit-event-0001-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'counterfeit-event-0001' 1) `
            -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($counterfeitArtifactBytes);path='receipts/counterfeit-artifact.json';sha256=$counterfeitArtifactHash}) `
            -FaultAfter after-intent | Out-Null
    }catch{$counterfeitInterrupted=$true}
    Assert-Ledger $counterfeitInterrupted 'counterfeit event fixture did not stop after intent'
    Write-Json (Join-Path $counterfeitWorkspace 'iteration-events.jsonl') (New-LedgerEvent 'counterfeit-event-0001' 1 'Counterfeit event body.')
    $counterfeitStateBefore=[IO.File]::ReadAllBytes((Join-Path $counterfeitWorkspace 'workspace.state.json'))
    $counterfeitUnitBefore=[IO.File]::ReadAllBytes((Join-Path $counterfeitWorkspace 'iteration-units\unit.json'))
    $counterfeitLedgerBefore=[IO.File]::ReadAllBytes((Join-Path $counterfeitWorkspace 'iteration-events.jsonl'))
    $counterfeitRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $counterfeitWorkspace -TransactionId 'counterfeit-event-0001-transition' -Repair|Out-Null}catch{$counterfeitRejected=$_.Exception.Message-like'*authenticated pre-append snapshot*'-or$_.Exception.Message-like'*exact canonical event append*'-or$_.Exception.Message-like'*differs from its intent*'}
    Assert-Ledger ($counterfeitRejected-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $counterfeitWorkspace 'workspace.state.json')))-ceq[Convert]::ToHexString($counterfeitStateBefore)-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $counterfeitWorkspace 'iteration-units\unit.json')))-ceq[Convert]::ToHexString($counterfeitUnitBefore)-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $counterfeitWorkspace 'iteration-events.jsonl')))-ceq[Convert]::ToHexString($counterfeitLedgerBefore)-and
        -not[IO.File]::Exists((Join-Path $counterfeitWorkspace 'receipts\counterfeit-artifact.json'))-and
        -not[IO.File]::Exists((Join-Path $counterfeitWorkspace 'receipts\transactions\counterfeit-event-0001-transition.completion.json'))
    ) 'counterfeit same-ID event reached repair mutation'

    $wrongPositionWorkspace=Join-Path $workspace 'wrong-event-position'
    Initialize-LedgerFixture $wrongPositionWorkspace $state $unit
    $wrongPositionPrior=New-LedgerEvent 'wrong-position-prior' 1
    Write-Json (Join-Path $wrongPositionWorkspace 'iteration-events.jsonl') $wrongPositionPrior
    $wrongPositionEvent=New-LedgerEvent 'wrong-position-target' 2
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $wrongPositionWorkspace `
            -TransactionId 'wrong-position-target-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event $wrongPositionEvent `
            -FaultAfter after-intent | Out-Null
    }catch{}
    $wrongPositionLater=New-LedgerEvent 'wrong-position-later' 3
    $wrongPositionText=(@($wrongPositionPrior,$wrongPositionEvent,$wrongPositionLater)|ForEach-Object{$_|ConvertTo-Json -Depth 20 -Compress})-join"`n"
    [IO.File]::WriteAllText((Join-Path $wrongPositionWorkspace 'iteration-events.jsonl'),$wrongPositionText+"`n",[Text.UTF8Encoding]::new($false))
    $wrongPositionRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $wrongPositionWorkspace -TransactionId 'wrong-position-target-transition' -Repair|Out-Null}catch{$wrongPositionRejected=$true}
    Assert-Ledger ($wrongPositionRejected-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $wrongPositionWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $wrongPositionWorkspace 'iteration-units\unit.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)-and
        -not[IO.File]::Exists((Join-Path $wrongPositionWorkspace 'receipts\transactions\wrong-position-target-transition.completion.json'))
    ) 'same-ID event at the wrong ledger position reached repair mutation'

    $preplantedSourceWorkspace=Join-Path $workspace 'preplanted-intent-source'
    Initialize-LedgerFixture $preplantedSourceWorkspace $state $unit
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $preplantedSourceWorkspace `
            -TransactionId 'preplanted-source-event-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'preplanted-source-event' 1) `
            -FaultAfter after-intent | Out-Null
    }catch{}
    $preplantedWorkspace=Join-Path $workspace 'preplanted-intent'
    Initialize-LedgerFixture $preplantedWorkspace $state $unit
    $preplantedIntent=Get-Content -Raw (Join-Path $preplantedSourceWorkspace 'receipts\transactions\preplanted-source-event-transition.intent.json')|ConvertFrom-Json
    $preplantedIntent.transaction_id='preplanted-intent-0001-transition'
    $preplantedIntentPath=Join-Path $preplantedWorkspace 'receipts\transactions\preplanted-intent-0001-transition.intent.json'
    Write-Json $preplantedIntentPath $preplantedIntent
    $preplantedRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $preplantedWorkspace -TransactionId 'preplanted-intent-0001-transition' -Repair|Out-Null}catch{$preplantedRejected=$true}
    Assert-Ledger ($preplantedRejected-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $preplantedWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $preplantedWorkspace 'iteration-units\unit.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)-and
        @(Get-Content (Join-Path $preplantedWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0-and
        -not[IO.File]::Exists((Join-Path $preplantedWorkspace 'receipts\transactions\preplanted-intent-0001-transition.completion.json'))
    ) 'preplanted mismatched transaction/event intent reached repair mutation'

    $duplicateRepairWorkspace=Join-Path $workspace 'duplicate-key-repair'
    Initialize-LedgerFixture $duplicateRepairWorkspace $state $unit
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $duplicateRepairWorkspace `
            -TransactionId 'duplicate-key-repair-0001-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'duplicate-key-repair-0001' 1) `
            -FaultAfter after-intent | Out-Null
    }catch{}
    [IO.File]::WriteAllText(
        (Join-Path $duplicateRepairWorkspace 'iteration-events.jsonl'),
        "{`"event_id`":`"evil`",`"event_id`":`"duplicate-key-repair-0001`",`"sequence`":1}`n",
        [Text.UTF8Encoding]::new($false)
    )
    $duplicateRepairRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $duplicateRepairWorkspace -TransactionId 'duplicate-key-repair-0001-transition' -Repair|Out-Null}catch{$duplicateRepairRejected=$_.Exception.Message-like'*malformed JSON*'}
    Assert-Ledger ($duplicateRepairRejected-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $duplicateRepairWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $duplicateRepairWorkspace 'iteration-units\unit.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)-and
        -not[IO.File]::Exists((Join-Path $duplicateRepairWorkspace 'receipts\transactions\duplicate-key-repair-0001-transition.completion.json'))
    ) 'duplicate-key event ledger reached repair mutation'

    $duplicateStartWorkspace=Join-Path $workspace 'duplicate-key-start'
    Initialize-LedgerFixture $duplicateStartWorkspace $state $unit
    [IO.File]::WriteAllText(
        (Join-Path $duplicateStartWorkspace 'iteration-events.jsonl'),
        "{`"event_id`":`"evil`",`"event_id`":`"duplicate-key-start-tail`",`"sequence`":1}`n",
        [Text.UTF8Encoding]::new($false)
    )
    $duplicateStartRejected=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $duplicateStartWorkspace `
            -TransactionId 'duplicate-key-start-0001-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'duplicate-key-start-0001' 2) | Out-Null
    }catch{$duplicateStartRejected=$_.Exception.Message-like'*malformed JSON*'}
    Assert-Ledger ($duplicateStartRejected-and
        -not[IO.File]::Exists((Join-Path $duplicateStartWorkspace 'receipts\transactions\duplicate-key-start-0001-transition.intent.json'))-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $duplicateStartWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $duplicateStartWorkspace 'iteration-units\unit.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)
    ) 'duplicate-key event ledger reached transition start mutation'

    foreach($invalidPrefixCase in @(
        [pscustomobject]@{name='schema-invalid';line="{`"event_id`":`"invalid-prefix-tail`"}`n"},
        [pscustomobject]@{name='noncontiguous-sequence';line=((New-LedgerEvent 'invalid-prefix-tail' 99)|ConvertTo-Json -Depth 20 -Compress)+"`n"}
    )){
        $invalidPrefixWorkspace=Join-Path $workspace "invalid-prefix-$($invalidPrefixCase.name)"
        Initialize-LedgerFixture $invalidPrefixWorkspace $state $unit
        [IO.File]::WriteAllText((Join-Path $invalidPrefixWorkspace 'iteration-events.jsonl'),[string]$invalidPrefixCase.line,[Text.UTF8Encoding]::new($false))
        $invalidPrefixRejected=$false
        try{
            Start-MorphospaceTransitionLedger `
                -WorkspaceRoot $invalidPrefixWorkspace `
                -TransactionId "invalid-prefix-$($invalidPrefixCase.name)-target-transition" `
                -StatePath 'workspace.state.json' `
                -UnitPath 'iteration-units/unit.json' `
                -EventsPath 'iteration-events.jsonl' `
                -TargetState $targetState `
                -TargetUnit $targetUnit `
                -Event (New-LedgerEvent "invalid-prefix-$($invalidPrefixCase.name)-target" 2) | Out-Null
        }catch{$invalidPrefixRejected=$true}
        Assert-Ledger ($invalidPrefixRejected-and
            -not[IO.File]::Exists((Join-Path $invalidPrefixWorkspace "receipts\transactions\invalid-prefix-$($invalidPrefixCase.name)-target-transition.intent.json"))-and
            (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $invalidPrefixWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
            (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $invalidPrefixWorkspace 'iteration-units\unit.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)-and
            -not[IO.File]::Exists((Join-Path $invalidPrefixWorkspace "receipts\transactions\invalid-prefix-$($invalidPrefixCase.name)-target-transition.completion.json"))
        ) "$($invalidPrefixCase.name) event-ledger prefix reached transition start mutation"
    }

    $backdatedStartWorkspace=Join-Path $workspace 'backdated-start'
    Initialize-LedgerFixture $backdatedStartWorkspace $state $unit
    $backdatedStartPrior=New-LedgerEvent 'backdated-start-prior' 1
    $backdatedStartPrior.timestamp='2026-01-02T00:00:00.0000000Z'
    Write-Json (Join-Path $backdatedStartWorkspace 'iteration-events.jsonl') $backdatedStartPrior
    $backdatedStartEvent=New-LedgerEvent 'backdated-start-target' 2
    $backdatedStartEvent.timestamp='2026-01-01T00:00:00.0000000Z'
    $backdatedStartArtifact=[Text.UTF8Encoding]::new($false).GetBytes('backdated start artifact must remain absent')
    $backdatedStartHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($backdatedStartArtifact)).ToLowerInvariant()
    $backdatedStartStateBefore=[IO.File]::ReadAllBytes((Join-Path $backdatedStartWorkspace 'workspace.state.json'))
    $backdatedStartUnitBefore=[IO.File]::ReadAllBytes((Join-Path $backdatedStartWorkspace 'iteration-units\unit.json'))
    $backdatedStartLedgerBefore=[IO.File]::ReadAllBytes((Join-Path $backdatedStartWorkspace 'iteration-events.jsonl'))
    $backdatedStartRejected=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $backdatedStartWorkspace `
            -TransactionId 'backdated-start-target-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event $backdatedStartEvent `
            -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($backdatedStartArtifact);path='receipts/backdated-start-artifact.json';sha256=$backdatedStartHash}) | Out-Null
    }catch{$backdatedStartRejected=$_.Exception.Message-like'*precedes the current ledger tail*'}
    Assert-Ledger ($backdatedStartRejected-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $backdatedStartWorkspace 'workspace.state.json')))-ceq[Convert]::ToHexString($backdatedStartStateBefore)-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $backdatedStartWorkspace 'iteration-units\unit.json')))-ceq[Convert]::ToHexString($backdatedStartUnitBefore)-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $backdatedStartWorkspace 'iteration-events.jsonl')))-ceq[Convert]::ToHexString($backdatedStartLedgerBefore)-and
        -not[IO.File]::Exists((Join-Path $backdatedStartWorkspace 'receipts\transactions\backdated-start-target-transition.intent.json'))-and
        -not[IO.File]::Exists((Join-Path $backdatedStartWorkspace 'receipts\backdated-start-artifact.json'))-and
        -not[IO.File]::Exists((Join-Path $backdatedStartWorkspace 'receipts\transactions\backdated-start-target-transition.completion.json'))
    ) 'backdated proposed event reached start mutation'

    $invalidTimestampWorkspace=Join-Path $workspace 'invalid-proposed-timestamp'
    Initialize-LedgerFixture $invalidTimestampWorkspace $state $unit
    $invalidTimestampEvent=New-LedgerEvent 'invalid-proposed-timestamp' 1
    $invalidTimestampEvent.timestamp=' 2026-01-01T00:00:00.0000000Z'
    $invalidTimestampRejected=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $invalidTimestampWorkspace `
            -TransactionId 'invalid-proposed-timestamp-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event $invalidTimestampEvent | Out-Null
    }catch{$invalidTimestampRejected=$_.Exception.Message-like'*strict invariant ISO-8601*'}
    Assert-Ledger ($invalidTimestampRejected-and
        -not[IO.File]::Exists((Join-Path $invalidTimestampWorkspace 'receipts\transactions\invalid-proposed-timestamp-transition.intent.json'))-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $invalidTimestampWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $invalidTimestampWorkspace 'iteration-units\unit.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)-and
        @(Get-Content (Join-Path $invalidTimestampWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0
    ) 'noncanonical proposed timestamp reached start mutation'

    $backdatedRepairWorkspace=Join-Path $workspace 'backdated-repair'
    Initialize-LedgerFixture $backdatedRepairWorkspace $state $unit
    $backdatedRepairPrior=New-LedgerEvent 'backdated-repair-prior' 1
    $backdatedRepairPrior.timestamp='2026-01-01T00:00:00.0000000Z'
    Write-Json (Join-Path $backdatedRepairWorkspace 'iteration-events.jsonl') $backdatedRepairPrior
    $backdatedRepairEvent=New-LedgerEvent 'backdated-repair-target' 2
    $backdatedRepairEvent.timestamp='2026-01-02T00:00:00.0000000Z'
    $backdatedRepairArtifact=[Text.UTF8Encoding]::new($false).GetBytes('backdated repair artifact must remain absent')
    $backdatedRepairHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($backdatedRepairArtifact)).ToLowerInvariant()
    $backdatedRepairInterrupted=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $backdatedRepairWorkspace `
            -TransactionId 'backdated-repair-target-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event $backdatedRepairEvent `
            -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($backdatedRepairArtifact);path='receipts/backdated-repair-artifact.json';sha256=$backdatedRepairHash}) `
            -FaultAfter after-intent | Out-Null
    }catch{$backdatedRepairInterrupted=$true}
    Assert-Ledger $backdatedRepairInterrupted 'backdated repair fixture did not retain its pending intent'
    $backdatedRepairPrior.timestamp='2026-01-03T00:00:00.0000000Z'
    Write-Json (Join-Path $backdatedRepairWorkspace 'iteration-events.jsonl') $backdatedRepairPrior
    $backdatedRepairIntent=Join-Path $backdatedRepairWorkspace 'receipts\transactions\backdated-repair-target-transition.intent.json'
    $backdatedRepairStateBefore=[IO.File]::ReadAllBytes((Join-Path $backdatedRepairWorkspace 'workspace.state.json'))
    $backdatedRepairUnitBefore=[IO.File]::ReadAllBytes((Join-Path $backdatedRepairWorkspace 'iteration-units\unit.json'))
    $backdatedRepairLedgerBefore=[IO.File]::ReadAllBytes((Join-Path $backdatedRepairWorkspace 'iteration-events.jsonl'))
    $backdatedRepairIntentBefore=[IO.File]::ReadAllBytes($backdatedRepairIntent)
    $backdatedRepairRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $backdatedRepairWorkspace -TransactionId 'backdated-repair-target-transition' -Repair|Out-Null}catch{$backdatedRepairRejected=$true}
    Assert-Ledger ($backdatedRepairRejected-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $backdatedRepairWorkspace 'workspace.state.json')))-ceq[Convert]::ToHexString($backdatedRepairStateBefore)-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $backdatedRepairWorkspace 'iteration-units\unit.json')))-ceq[Convert]::ToHexString($backdatedRepairUnitBefore)-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $backdatedRepairWorkspace 'iteration-events.jsonl')))-ceq[Convert]::ToHexString($backdatedRepairLedgerBefore)-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes($backdatedRepairIntent))-ceq[Convert]::ToHexString($backdatedRepairIntentBefore)-and
        -not[IO.File]::Exists((Join-Path $backdatedRepairWorkspace 'receipts\backdated-repair-artifact.json'))-and
        -not[IO.File]::Exists((Join-Path $backdatedRepairWorkspace 'receipts\transactions\backdated-repair-target-transition.completion.json'))
    ) 'backdated proposed event reached repair mutation'

    $duplicateCommittedWorkspace=Join-Path $workspace 'duplicate-key-committed'
    Initialize-LedgerFixture $duplicateCommittedWorkspace $state $unit
    Start-MorphospaceTransitionLedger `
        -WorkspaceRoot $duplicateCommittedWorkspace `
        -TransactionId 'duplicate-key-committed-0001-transition' `
        -StatePath 'workspace.state.json' `
        -UnitPath 'iteration-units/unit.json' `
        -EventsPath 'iteration-events.jsonl' `
        -TargetState $targetState `
        -TargetUnit $targetUnit `
        -Event (New-LedgerEvent 'duplicate-key-committed-0001' 1) | Out-Null
    $duplicateCommittedCompletion=Join-Path $duplicateCommittedWorkspace 'receipts\transactions\duplicate-key-committed-0001-transition.completion.json'
    $duplicateCommittedCompletionBefore=[IO.File]::ReadAllBytes($duplicateCommittedCompletion)
    [IO.File]::WriteAllText(
        (Join-Path $duplicateCommittedWorkspace 'iteration-events.jsonl'),
        "{`"event_id`":`"evil`",`"event_id`":`"duplicate-key-committed-0001`",`"sequence`":1}`n",
        [Text.UTF8Encoding]::new($false)
    )
    $duplicateCommittedRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $duplicateCommittedWorkspace -TransactionId 'duplicate-key-committed-0001-transition'|Out-Null}catch{$duplicateCommittedRejected=$_.Exception.Message-like'*malformed JSON*'}
    Assert-Ledger ($duplicateCommittedRejected-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes($duplicateCommittedCompletion))-ceq[Convert]::ToHexString($duplicateCommittedCompletionBefore)
    ) 'duplicate-key committed event was accepted as idempotent'

    $historicalPlacementWorkspace=Join-Path $workspace 'historical-placement'
    Initialize-LedgerFixture $historicalPlacementWorkspace $state $unit
    $historicalPlacementEvent=New-LedgerEvent 'historical-placement-target' 1
    Start-MorphospaceTransitionLedger `
        -WorkspaceRoot $historicalPlacementWorkspace `
        -TransactionId 'historical-placement-target-transition' `
        -StatePath 'workspace.state.json' `
        -UnitPath 'iteration-units/unit.json' `
        -EventsPath 'iteration-events.jsonl' `
        -TargetState $targetState `
        -TargetUnit $targetUnit `
        -Event $historicalPlacementEvent | Out-Null
    $historicalPlacementCompletion=Join-Path $historicalPlacementWorkspace 'receipts\transactions\historical-placement-target-transition.completion.json'
    $historicalPlacementCompletionBefore=[IO.File]::ReadAllBytes($historicalPlacementCompletion)
    $historicalPlacementSuffix=New-LedgerEvent 'historical-placement-suffix' 2 'Valid later suffix event.'
    [IO.File]::AppendAllText(
        (Join-Path $historicalPlacementWorkspace 'iteration-events.jsonl'),
        (($historicalPlacementSuffix|ConvertTo-Json -Depth 20 -Compress)+"`n"),
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Ledger (
        (Complete-MorphospaceTransitionLedger -WorkspaceRoot $historicalPlacementWorkspace -TransactionId 'historical-placement-target-transition').status-eq'already-committed'
    ) 'valid later event suffix invalidated an unchanged committed transition'
    $historicalPlacementUnrelated=New-LedgerEvent 'historical-placement-unrelated' 1
    $historicalPlacementText=(@($historicalPlacementUnrelated,$historicalPlacementEvent)|ForEach-Object{$_|ConvertTo-Json -Depth 20 -Compress})-join"`n"
    [IO.File]::WriteAllText((Join-Path $historicalPlacementWorkspace 'iteration-events.jsonl'),$historicalPlacementText+"`n",[Text.UTF8Encoding]::new($false))
    $historicalPlacementRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $historicalPlacementWorkspace -TransactionId 'historical-placement-target-transition'|Out-Null}catch{$historicalPlacementRejected=$_.Exception.Message-like'*predecessor differs*'-or$_.Exception.Message-like'*sequence does not match*'-or$_.Exception.Message-like'*sequence is not contiguous*'}
    Assert-Ledger ($historicalPlacementRejected-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes($historicalPlacementCompletion))-ceq[Convert]::ToHexString($historicalPlacementCompletionBefore)
    ) 'rewritten historical event position was accepted as already committed'

    foreach($orphanCase in @(
        [pscustomobject]@{name='malformed';completion=[pscustomobject]@{schema='damaged'}},
        [pscustomobject]@{name='forged';completion=[pscustomobject][ordered]@{
            schema='rusty.morphospace.workflow.transition_ledger_completion.v1'
            transaction_id='orphan-completion-0001-transition'
            completed_at='2026-01-01T00:00:00.0000000Z'
            intent=[pscustomobject]@{role='transition-ledger-intent';path='receipts/transactions/orphan-completion-0001-transition.intent.json';schema='rusty.morphospace.workflow.transition_ledger_intent.v1';sha256=('0'*64)}
            state_sha256=Get-LedgerDocumentHash $targetState
            unit_sha256=Get-LedgerDocumentHash $targetUnit
            event_id='orphan-completion-0001'
            status='committed'
        }}
    )){
        $orphanWorkspace=Join-Path $workspace "orphan-$($orphanCase.name)"
        Initialize-LedgerFixture $orphanWorkspace $state $unit
        $orphanCompletion=Join-Path $orphanWorkspace 'receipts\transactions\orphan-completion-0001-transition.completion.json'
        Write-Json $orphanCompletion $orphanCase.completion
        $orphanRejected=$false
        try{
            Start-MorphospaceTransitionLedger `
                -WorkspaceRoot $orphanWorkspace `
                -TransactionId 'orphan-completion-0001-transition' `
                -StatePath 'workspace.state.json' `
                -UnitPath 'iteration-units/unit.json' `
                -EventsPath 'iteration-events.jsonl' `
                -TargetState $targetState `
                -TargetUnit $targetUnit `
                -Event (New-LedgerEvent 'orphan-completion-0001' 1) | Out-Null
        }catch{$orphanRejected=$true}
        Assert-Ledger ($orphanRejected-and
            (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $orphanWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
            (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $orphanWorkspace 'iteration-units\unit.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)-and
            @(Get-Content (Join-Path $orphanWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0) "$($orphanCase.name) orphan completion failed open"
    }

    $authorityWorkspace = Join-Path $workspace 'authority'
    Initialize-LedgerFixture $authorityWorkspace $state $unit
    Start-MorphospaceTransitionLedger `
        -WorkspaceRoot $authorityWorkspace `
        -TransactionId 'unit-record-0002-transition' `
        -StatePath 'workspace.state.json' `
        -UnitPath 'iteration-units/unit.json' `
        -EventsPath 'iteration-events.jsonl' `
        -TargetState $targetState `
        -TargetUnit $targetUnit `
        -Event (New-LedgerEvent 'unit-record-0002' 1) | Out-Null
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force
    $validationModule = Get-Module MorphospaceValidationAuthority
    $outputs = @([pscustomobject]@{
        repo_id='planning'
        path='authority/receipts/transactions/unit-record-0002-transition.completion.json'
        phase='transition'
        role='transition-ledger-completion'
        schema='rusty.morphospace.workflow.transition_ledger_completion.v1'
        validator_id=$null
    })
    $map = @{planning=[pscustomobject]@{path=$workspace}}
    $projectionPaths = @(& $validationModule {
        param($WorkspaceRoot, $Contract, $RepositoryMap)
        Get-MorphospaceCommittedTransitionPaths -WorkspaceRoot $WorkspaceRoot -AutomationOutputs $Contract -RepositoryMap $RepositoryMap
    } $authorityWorkspace $outputs $map)
    $expectedPaths = @(
        'planning/authority/iteration-events.jsonl',
        'planning/authority/iteration-units/unit.json',
        'planning/authority/workspace.state.json'
    )
    Assert-Ledger (($projectionPaths -join '|') -ceq ($expectedPaths -join '|')) 'committed transition projections are not repo-qualified'

    $memoryWorkspace = Join-Path $workspace 'memory-artifact'
    Initialize-LedgerFixture $memoryWorkspace $state $unit
    $memoryPayload = [Text.UTF8Encoding]::new($false).GetBytes('retained exact artifact bytes')
    $memoryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($memoryPayload)).ToLowerInvariant()
    Start-MorphospaceTransitionLedger `
        -WorkspaceRoot $memoryWorkspace `
        -TransactionId 'memory-artifact-0001-transition' `
        -StatePath 'workspace.state.json' `
        -UnitPath 'iteration-units/unit.json' `
        -EventsPath 'iteration-events.jsonl' `
        -TargetState $targetState `
        -TargetUnit $targetUnit `
        -Event (New-LedgerEvent 'memory-artifact-0001' 1) `
        -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path='receipts/memory-artifact.json';sha256=$memoryHash}) | Out-Null
    $installedMemoryBytes = [IO.File]::ReadAllBytes((Join-Path $memoryWorkspace 'receipts\memory-artifact.json'))
    Assert-Ledger ([Convert]::ToHexString($installedMemoryBytes)-ceq[Convert]::ToHexString($memoryPayload)) 'in-memory artifact bytes changed during transaction ownership'

    foreach($invalidArtifactCase in @(
        [pscustomobject]@{name='both sources';artifact=[pscustomobject]@{source_path=(Join-Path $memoryWorkspace 'workspace.state.json');bytes_base64=[Convert]::ToBase64String($memoryPayload);path='receipts/invalid-both.json';sha256=$memoryHash}},
        [pscustomobject]@{name='no source';artifact=[pscustomobject]@{path='receipts/invalid-neither.json';sha256=$memoryHash}},
        [pscustomobject]@{name='invalid base64';artifact=[pscustomobject]@{bytes_base64='%%%';path='receipts/invalid-base64.json';sha256=$memoryHash}},
        [pscustomobject]@{name='wrong retained hash';artifact=[pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path='receipts/invalid-hash.json';sha256=('0'*64)}}
    )){
        $invalidWorkspace=Join-Path $workspace ("invalid-"+($invalidArtifactCase.name-replace' ','-'))
        Initialize-LedgerFixture $invalidWorkspace $state $unit
        $invalidRejected=$false
        try{
            Start-MorphospaceTransitionLedger `
                -WorkspaceRoot $invalidWorkspace `
                -TransactionId 'invalid-artifact-0001-transition' `
                -StatePath 'workspace.state.json' `
                -UnitPath 'iteration-units/unit.json' `
                -EventsPath 'iteration-events.jsonl' `
                -TargetState $targetState `
                -TargetUnit $targetUnit `
                -Event (New-LedgerEvent 'invalid-artifact-0001' 1) `
                -Artifacts @($invalidArtifactCase.artifact) | Out-Null
        }catch{$invalidRejected=$true}
        Assert-Ledger ($invalidRejected-and
            -not[IO.File]::Exists((Join-Path $invalidWorkspace 'receipts\transactions\invalid-artifact-0001-transition.intent.json'))-and
            @(Get-Content (Join-Path $invalidWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0) "invalid $($invalidArtifactCase.name) artifact reached transaction intent or event mutation"
    }

    foreach($occupiedCase in @(
        [pscustomobject]@{name='identical';bytes=$memoryPayload},
        [pscustomobject]@{name='different';bytes=[Text.UTF8Encoding]::new($false).GetBytes('preoccupied different bytes')}
    )){
        $occupiedWorkspace=Join-Path $workspace "occupied-$($occupiedCase.name)"
        Initialize-LedgerFixture $occupiedWorkspace $state $unit
        $occupiedTarget=Join-Path $occupiedWorkspace 'receipts\occupied-artifact.json'
        [IO.File]::WriteAllBytes($occupiedTarget,[byte[]]$occupiedCase.bytes)
        $occupiedBefore=[IO.File]::ReadAllBytes($occupiedTarget)
        $occupiedRejected=$false
        try{
            Start-MorphospaceTransitionLedger `
                -WorkspaceRoot $occupiedWorkspace `
                -TransactionId "occupied-$($occupiedCase.name)-transition" `
                -StatePath 'workspace.state.json' `
                -UnitPath 'iteration-units/unit.json' `
                -EventsPath 'iteration-events.jsonl' `
                -TargetState $targetState `
                -TargetUnit $targetUnit `
                -Event (New-LedgerEvent "occupied-$($occupiedCase.name)" 1) `
                -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path='receipts/occupied-artifact.json';sha256=$memoryHash}) | Out-Null
        }catch{$occupiedRejected=$_.Exception.Message-like'*must be absent before intent publication*'}
        Assert-Ledger ($occupiedRejected-and
            -not[IO.File]::Exists((Join-Path $occupiedWorkspace "receipts\transactions\occupied-$($occupiedCase.name)-transition.intent.json"))-and
            -not[IO.File]::Exists((Join-Path $occupiedWorkspace "receipts\transactions\occupied-$($occupiedCase.name)-transition.artifact-0.pending"))-and
            [Convert]::ToHexString([IO.File]::ReadAllBytes($occupiedTarget))-ceq[Convert]::ToHexString($occupiedBefore)-and
            @(Get-Content (Join-Path $occupiedWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0-and
            (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $occupiedWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
            (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $occupiedWorkspace 'iteration-units\unit.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)
        ) "preoccupied $($occupiedCase.name) artifact target reached transition mutation"
    }

    $reservedCases=@(
        [pscustomobject]@{name='state';path='workspace.state.json'},
        [pscustomobject]@{name='unit';path='iteration-units/unit.json'},
        [pscustomobject]@{name='events';path='iteration-events.jsonl'},
        [pscustomobject]@{name='intent';path='receipts/transactions/reserved-intent-transition.intent.json'},
        [pscustomobject]@{name='completion';path='receipts/transactions/reserved-completion-transition.completion.json'}
    )
    foreach($reservedCase in $reservedCases){
        $reservedWorkspace=Join-Path $workspace "reserved-$($reservedCase.name)"
        Initialize-LedgerFixture $reservedWorkspace $state $unit
        $transactionId="reserved-$($reservedCase.name)-transition"
        if($reservedCase.name-eq'intent'){$transactionId='reserved-intent-transition'}
        if($reservedCase.name-eq'completion'){$transactionId='reserved-completion-transition'}
        $reservedRejected=$false
        try{
            Start-MorphospaceTransitionLedger `
                -WorkspaceRoot $reservedWorkspace `
                -TransactionId $transactionId `
                -StatePath 'workspace.state.json' `
                -UnitPath 'iteration-units/unit.json' `
                -EventsPath 'iteration-events.jsonl' `
                -TargetState $targetState `
                -TargetUnit $targetUnit `
                -Event (New-LedgerEvent "reserved-$($reservedCase.name)" 1) `
                -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path=([string]$reservedCase.path);sha256=$memoryHash}) | Out-Null
        }catch{$reservedRejected=$_.Exception.Message-like'*transaction control namespace*'}
        Assert-Ledger ($reservedRejected-and
            -not[IO.File]::Exists((Join-Path $reservedWorkspace "receipts\transactions\$transactionId.intent.json"))-and
            @(Get-Content (Join-Path $reservedWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0
        ) "reserved $($reservedCase.name) path was accepted as an artifact target"
    }

    $aliasWorkspace=Join-Path $workspace 'case-alias-artifacts'
    Initialize-LedgerFixture $aliasWorkspace $state $unit
    $aliasRejected=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $aliasWorkspace `
            -TransactionId 'case-alias-artifacts-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'case-alias-artifacts' 1) `
            -Artifacts @(
                [pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path='receipts/Alias.json';sha256=$memoryHash},
                [pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path='receipts/alias.json';sha256=$memoryHash}
            ) | Out-Null
    }catch{$aliasRejected=$_.Exception.Message-like'*repeats an artifact target path*'}
    Assert-Ledger ($aliasRejected-and
        -not[IO.File]::Exists((Join-Path $aliasWorkspace 'receipts\transactions\case-alias-artifacts-transition.intent.json'))-and
        @(Get-Content (Join-Path $aliasWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0
    ) 'case-alias artifact targets reached transition mutation'

    $multiArtifactWorkspace=Join-Path $workspace 'multi-artifact-preflight'
    Initialize-LedgerFixture $multiArtifactWorkspace $state $unit
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $multiArtifactWorkspace `
            -TransactionId 'multi-artifact-preflight-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'multi-artifact-preflight' 1) `
            -Artifacts @(
                [pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path='receipts/multi-first.json';sha256=$memoryHash},
                [pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path='receipts/multi-second.json';sha256=$memoryHash}
            ) -FaultAfter after-intent | Out-Null
    }catch{}
    $multiOccupiedBytes=[Text.UTF8Encoding]::new($false).GetBytes('occupied after intent')
    [IO.File]::WriteAllBytes((Join-Path $multiArtifactWorkspace 'receipts\multi-second.json'),$multiOccupiedBytes)
    $multiRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $multiArtifactWorkspace -TransactionId 'multi-artifact-preflight-transition' -Repair|Out-Null}catch{$multiRejected=$_.Exception.Message-like'*occupied after intent publication*'}
    Assert-Ledger ($multiRejected-and
        -not[IO.File]::Exists((Join-Path $multiArtifactWorkspace 'receipts\multi-first.json'))-and
        [IO.File]::Exists((Join-Path $multiArtifactWorkspace 'receipts\transactions\multi-artifact-preflight-transition.artifact-0.pending'))-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $multiArtifactWorkspace 'receipts\multi-second.json')))-ceq[Convert]::ToHexString($multiOccupiedBytes)-and
        @(Get-Content (Join-Path $multiArtifactWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $multiArtifactWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
        -not[IO.File]::Exists((Join-Path $multiArtifactWorkspace 'receipts\transactions\multi-artifact-preflight-transition.completion.json'))
    ) 'multi-artifact completion mutated an earlier target before rejecting a later occupied target'

    foreach($artifactFault in @('after-artifact','after-event')){
        $artifactRepairWorkspace=Join-Path $workspace "artifact-repair-$artifactFault"
        Initialize-LedgerFixture $artifactRepairWorkspace $state $unit
        $artifactRepairInterrupted=$false
        try{
            Start-MorphospaceTransitionLedger `
                -WorkspaceRoot $artifactRepairWorkspace `
                -TransactionId "artifact-repair-$artifactFault-transition" `
                -StatePath 'workspace.state.json' `
                -UnitPath 'iteration-units/unit.json' `
                -EventsPath 'iteration-events.jsonl' `
                -TargetState $targetState `
                -TargetUnit $targetUnit `
                -Event (New-LedgerEvent "artifact-repair-$artifactFault" 1) `
                -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path='receipts/repaired-artifact.json';sha256=$memoryHash}) `
                -FaultAfter $artifactFault | Out-Null
        }catch{$artifactRepairInterrupted=$true}
        Assert-Ledger ($artifactRepairInterrupted-and[IO.File]::Exists((Join-Path $artifactRepairWorkspace 'receipts\repaired-artifact.json'))) "$artifactFault did not retain its transaction-owned artifact"
        $artifactRepairResult=Complete-MorphospaceTransitionLedger -WorkspaceRoot $artifactRepairWorkspace -TransactionId "artifact-repair-$artifactFault-transition" -Repair
        Assert-Ledger ($artifactRepairResult.status-eq'committed'-and
            @(Get-Content (Join-Path $artifactRepairWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq1-and
            (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $artifactRepairWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $targetState)-and
            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $artifactRepairWorkspace 'receipts\repaired-artifact.json')))-ceq[Convert]::ToHexString($memoryPayload)
        ) "$artifactFault repair did not converge exactly once"
    }

    $overtakeWorkspace=Join-Path $workspace 'outstanding-intent-gate'
    Initialize-LedgerFixture $overtakeWorkspace $state $unit
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $overtakeWorkspace `
            -TransactionId 'outstanding-first-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'outstanding-first' 1) `
            -FaultAfter after-intent | Out-Null
    }catch{}
    $overtakeRejected=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $overtakeWorkspace `
            -TransactionId 'outstanding-second-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'outstanding-second' 1) | Out-Null
    }catch{$overtakeRejected=$_.Exception.Message-like'*outstanding transition intent requiring repair*'}
    Assert-Ledger ($overtakeRejected-and
        -not[IO.File]::Exists((Join-Path $overtakeWorkspace 'receipts\transactions\outstanding-second-transition.intent.json'))-and
        @(Get-Content (Join-Path $overtakeWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0
    ) 'a second transition overtook an outstanding intent'
    Assert-Ledger ((Complete-MorphospaceTransitionLedger -WorkspaceRoot $overtakeWorkspace -TransactionId 'outstanding-first-transition' -Repair).status-eq'committed') 'outstanding intent did not remain repairable'

    $tornWorkspace=Join-Path $workspace 'torn-event-append'
    Initialize-LedgerFixture $tornWorkspace $state $unit
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $tornWorkspace `
            -TransactionId 'torn-event-append-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'torn-event-append' 1) `
            -FaultAfter after-intent | Out-Null
    }catch{}
    $tornIntent=Get-Content -Raw (Join-Path $tornWorkspace 'receipts\transactions\torn-event-append-transition.intent.json')|ConvertFrom-Json
    $tornLine=[Text.UTF8Encoding]::new($false).GetBytes(($tornIntent.event|ConvertTo-Json -Depth 32 -Compress)+"`n")
    $tornLength=[int][Math]::Floor($tornLine.Length/2)
    $tornStream=[IO.FileStream]::new((Join-Path $tornWorkspace 'iteration-events.jsonl'),[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$tornStream.Write($tornLine,0,$tornLength);$tornStream.Flush($true)}finally{$tornStream.Dispose()}
    $tornResult=Complete-MorphospaceTransitionLedger -WorkspaceRoot $tornWorkspace -TransactionId 'torn-event-append-transition' -Repair
    Assert-Ledger ($tornResult.status-eq'committed'-and
        @(Get-Content (Join-Path $tornWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq1
    ) 'authenticated torn event append did not repair to one canonical event'

    Invoke-ConcurrentLedgerDriftTest `
        -WorkspaceRoot (Join-Path $workspace 'concurrent-state') `
        -DriftTarget state `
        -TransitionModulePath $transitionModulePath
    Invoke-ConcurrentLedgerDriftTest `
        -WorkspaceRoot (Join-Path $workspace 'concurrent-unit') `
        -DriftTarget unit `
        -TransitionModulePath $transitionModulePath

    Write-Host 'Transition-ledger self-test passed.'
} finally {
    if ([IO.Directory]::Exists($workspace)) { [IO.Directory]::Delete($workspace, $true) }
}
