$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$transitionModulePath = Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1'
Import-Module $transitionModulePath -Force
$transitionModule = Get-Module MorphospaceTransitionLedger
$validationAuthorityModulePath = Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1'
Import-Module $validationAuthorityModulePath -Force
$validationAuthorityModule = Get-Module MorphospaceValidationAuthority

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

function Get-LedgerFileHash {
    param([string]$Path)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

function Get-LedgerCommittedTransitionPaths {
    param([string]$WorkspaceRoot,[object[]]$AutomationOutputs,[hashtable]$RepositoryMap)
    & $script:validationAuthorityModule {
        param($Workspace,$Outputs,$Map)
        Get-MorphospaceCommittedTransitionPaths -WorkspaceRoot $Workspace -AutomationOutputs $Outputs -RepositoryMap $Map
    } $WorkspaceRoot $AutomationOutputs $RepositoryMap
}

function Assert-LedgerCommittedV4DamageRejected {
    param(
        [string]$TemplateWorkspace,
        [string]$PlanningRoot,
        [string]$Name,
        [scriptblock]$Mutation
    )
    $caseWorkspace = Join-Path $PlanningRoot "validation-authority-v4-$Name"
    Copy-Item -LiteralPath $TemplateWorkspace -Destination $caseWorkspace -Recurse
    $transactionId = 'projected-raw-recovery-transition'
    $intentPath = Join-Path $caseWorkspace "receipts\transactions\$transactionId.intent.json"
    $completionPath = Join-Path $caseWorkspace "receipts\transactions\$transactionId.completion.json"
    $intent = Get-Content -Raw -LiteralPath $intentPath | ConvertFrom-Json
    & $Mutation $caseWorkspace $intent
    Write-Json -Path $intentPath -Value $intent
    $completion = Get-Content -Raw -LiteralPath $completionPath | ConvertFrom-Json
    $completion.intent.sha256 = Get-LedgerFileHash $intentPath
    Write-Json -Path $completionPath -Value $completion
    $completionRelative = [IO.Path]::GetRelativePath($PlanningRoot, $completionPath).Replace('\','/')
    $rejected = $false
    try {
        Get-LedgerCommittedTransitionPaths `
            -WorkspaceRoot $caseWorkspace `
            -AutomationOutputs @([pscustomobject]@{ phase='transition'; role='transition-ledger-completion'; path=$completionRelative }) `
            -RepositoryMap @{ planning=[pscustomobject]@{ path=$PlanningRoot } } | Out-Null
    } catch { $rejected = $true }
    Assert-Ledger $rejected "validation authority accepted self-hashed malformed v4 intent: $Name"
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

function New-LedgerBootstrapEvent {
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v2'
        event_id='mixed-prefix-bootstrap-001'
        sequence=1
        timestamp='2026-01-02T03:04:05.0000000Z'
        run_id='mixed-prefix-bootstrap-run'
        session_id=$null
        project_id='ledger-test'
        unit_id='unit-test'
        event_type='decision'
        summary='Bootstrap the historical event ledger before v1 transition ownership.'
        previous_event_sha256='0' * 64
        receipts=@()
    }
}

function Read-LedgerEventsForTest {
    param([string]$Path)
    @(& $script:transitionModule {
        param($EventsPath)
        Read-MorphospaceLedgerEvents -EventsPath $EventsPath
    } $Path)
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

function Initialize-SupersessionLedgerFixture {
    param(
        [string]$WorkspaceRoot,
        [string]$OldUnitId,
        [string]$NewUnitId,
        [string]$OldStatus = 'active',
        [string]$CurrentUnitId = $OldUnitId
    )
    $eventId = "$OldUnitId-superseded-by-$NewUnitId"
    $state = [pscustomobject][ordered]@{
        schema = 'test'
        project_id = 'ledger-test'
        current_unit = $CurrentUnitId
        last_event_id = $null
    }
    $oldUnit = [pscustomobject][ordered]@{
        schema = 'test'
        project_id = 'ledger-test'
        unit_id = $OldUnitId
        status = $OldStatus
    }
    $newUnit = [pscustomobject][ordered]@{
        schema = 'test'
        project_id = 'ledger-test'
        unit_id = $NewUnitId
        status = 'ready'
    }
    $targetState = [pscustomobject][ordered]@{
        schema = 'test'
        project_id = 'ledger-test'
        current_unit = $NewUnitId
        last_event_id = $eventId
    }
    $targetUnit = [pscustomobject][ordered]@{
        schema = 'test'
        project_id = 'ledger-test'
        unit_id = $NewUnitId
        status = 'active'
    }
    $event = New-LedgerEvent $eventId 1 'Superseded one immutable in-flight unit with the sole current replacement.'
    $event.unit_id = $OldUnitId
    [IO.Directory]::CreateDirectory((Join-Path $WorkspaceRoot 'receipts')) | Out-Null
    Write-Json (Join-Path $WorkspaceRoot 'workspace.state.json') $state
    $oldPath = "iteration-units/$OldUnitId.json"
    $newPath = "iteration-units/$NewUnitId.json"
    Write-Json (Join-Path $WorkspaceRoot $oldPath) $oldUnit
    Write-Json (Join-Path $WorkspaceRoot $newPath) $newUnit
    [IO.File]::WriteAllText(
        (Join-Path $WorkspaceRoot 'iteration-events.jsonl'),
        '',
        [Text.UTF8Encoding]::new($false)
    )
    [pscustomobject]@{
        workspace = $WorkspaceRoot
        event_id = $eventId
        transaction_id = "$eventId-transition"
        state = $state
        old_unit = $oldUnit
        new_unit = $newUnit
        target_state = $targetState
        target_unit = $targetUnit
        event = $event
        old_unit_path = $oldPath
        new_unit_path = $newPath
    }
}

function Assert-SupersessionRejectedAtomically {
    param(
        [object]$Fixture,
        [object]$TargetState = $Fixture.target_state,
        [object]$TargetUnit = $Fixture.target_unit,
        [object]$Event = $Fixture.event,
        [string]$ExpectedMessage = '*supersession*'
    )
    $paths = @(
        'workspace.state.json',
        $Fixture.old_unit_path,
        $Fixture.new_unit_path,
        'iteration-events.jsonl'
    )
    $before = @{}
    foreach ($path in $paths) {
        $before[$path] = [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $Fixture.workspace $path)))
    }
    $rejected = $false
    $message = ''
    try {
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $Fixture.workspace `
            -TransactionId "$([string]$Event.event_id)-transition" `
            -StatePath 'workspace.state.json' `
            -UnitPath $Fixture.new_unit_path `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $TargetState `
            -TargetUnit $TargetUnit `
            -Event $Event `
            -ExpectedPreStateSha256 (Get-LedgerDocumentHash $Fixture.state) `
            -ExpectedPreUnitSha256 (Get-LedgerDocumentHash $Fixture.new_unit) | Out-Null
    } catch {
        $rejected = $true
        $message = $_.Exception.Message
    }
    Assert-Ledger ($rejected -and $message -like $ExpectedMessage) "supersession damage was not rejected with '$ExpectedMessage': $message"
    foreach ($path in $paths) {
        $after = [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $Fixture.workspace $path)))
        Assert-Ledger ($after -ceq $before[$path]) "supersession rejection changed '$path'"
    }
    $transactions = Join-Path $Fixture.workspace 'receipts\transactions'
    Assert-Ledger (
        -not [IO.Directory]::Exists($transactions) -or
        @([IO.Directory]::EnumerateFileSystemEntries($transactions)).Count -eq 0
    ) 'supersession rejection published a transaction artifact'
}

function Publish-SupersessionIntent {
    param([object]$Fixture)
    $interrupted = $false
    try {
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $Fixture.workspace `
            -TransactionId $Fixture.transaction_id `
            -StatePath 'workspace.state.json' `
            -UnitPath $Fixture.new_unit_path `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $Fixture.target_state `
            -TargetUnit $Fixture.target_unit `
            -Event $Fixture.event `
            -ExpectedPreStateSha256 (Get-LedgerDocumentHash $Fixture.state) `
            -ExpectedPreUnitSha256 (Get-LedgerDocumentHash $Fixture.new_unit) `
            -ExpectedSupersededUnitSha256 (Get-LedgerDocumentHash $Fixture.old_unit) `
            -FaultAfter after-intent | Out-Null
    } catch {
        $interrupted = $_.Exception.Message -like '*Injected interruption after intent publication*'
    }
    Assert-Ledger $interrupted 'supersession fixture did not publish exactly one interrupted intent'
    Join-Path $Fixture.workspace "receipts\transactions\$($Fixture.transaction_id).intent.json"
}

function Invoke-ConcurrentSupersessionDriftTest {
    param([string]$WorkspaceRoot,[string]$TransitionModulePath,[string]$OldUnitId,[string]$NewUnitId)
    $fixture = Initialize-SupersessionLedgerFixture $WorkspaceRoot $OldUnitId $NewUnitId
    $expectedState = Get-LedgerDocumentHash $fixture.state
    $expectedUnit = Get-LedgerDocumentHash $fixture.new_unit
    $expectedOldUnit = Get-LedgerDocumentHash $fixture.old_unit
    $lock = Enter-LedgerTestMutex -WorkspaceRoot $WorkspaceRoot
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($ModulePath,$Fixture,$ExpectedState,$ExpectedUnit,$ExpectedOldUnit)
            $ErrorActionPreference = 'Stop'
            Import-Module $ModulePath -Force
            try {
                Start-MorphospaceTransitionLedger `
                    -WorkspaceRoot $Fixture.workspace `
                    -TransactionId $Fixture.transaction_id `
                    -StatePath 'workspace.state.json' `
                    -UnitPath $Fixture.new_unit_path `
                    -EventsPath 'iteration-events.jsonl' `
                    -TargetState $Fixture.target_state `
                    -TargetUnit $Fixture.target_unit `
                    -Event $Fixture.event `
                    -ExpectedPreStateSha256 $ExpectedState `
                    -ExpectedPreUnitSha256 $ExpectedUnit `
                    -ExpectedSupersededUnitSha256 $ExpectedOldUnit | Out-Null
                [pscustomobject]@{rejected=$false;message='supersession unexpectedly committed'}
            } catch {
                [pscustomobject]@{rejected=$true;message=$_.Exception.Message}
            }
        } -ArgumentList @($TransitionModulePath,$fixture,$expectedState,$expectedUnit,$expectedOldUnit)
        Start-Sleep -Milliseconds 500
        Assert-Ledger ($job.State -in @('NotStarted','Running')) 'supersession contender did not wait for the transition mutex'
        $mutatedOld = [pscustomobject][ordered]@{
            schema='test';project_id='ledger-test';unit_id=$OldUnitId;status='validating'
        }
        Write-Json (Join-Path $WorkspaceRoot $fixture.old_unit_path) $mutatedOld
    } finally {
        Exit-LedgerTestMutex $lock
    }
    try {
        $output = @(Receive-Job -Job $job -Wait)
        $outcome = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'rejected' } | Select-Object -Last 1)
        Assert-Ledger ($outcome.Count -eq 1 -and $outcome[0].rejected) 'superseded-unit concurrency drift was not rejected'
        Assert-Ledger ([string]$outcome[0].message -like '*expected superseded-unit SHA-256*') 'superseded-unit concurrency rejection did not identify the stale old-unit expectation'
    } finally {
        if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
    Assert-Ledger (-not [IO.File]::Exists((Join-Path $WorkspaceRoot "receipts\transactions\$($fixture.transaction_id).intent.json"))) 'superseded-unit concurrency drift wrote an intent'
    Assert-Ledger ([IO.File]::ReadAllBytes((Join-Path $WorkspaceRoot 'iteration-events.jsonl')).Length -eq 0) 'superseded-unit concurrency drift appended an event'
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
    $exactBoundarySupersessionId = Get-MorphospaceSupersessionEventId -OldUnitId 'aa' -ReplacementUnitId ('b' * 111)
    Assert-Ledger ($exactBoundarySupersessionId.Length -eq 128 -and $exactBoundarySupersessionId -ceq (('aa-superseded-by-') + ('b' * 111))) 'canonical supersession constructor rejected the exact 128-character boundary'
    $overlongSupersessionRejected = $false
    try {
        Get-MorphospaceSupersessionEventId -OldUnitId 'aa' -ReplacementUnitId ('b' * 112) | Out-Null
    } catch {
        $overlongSupersessionRejected = $_.Exception.Message -like '*exceeds the portable 128-character event-ID contract*'
    }
    Assert-Ledger $overlongSupersessionRejected 'canonical supersession constructor accepted a 129-character event identity'

    $mixedLedgerPath = Join-Path $workspace 'mixed-event-prefix.jsonl'
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    $bootstrapEvent = New-LedgerBootstrapEvent
    $legacyEvent = New-LedgerEvent 'mixed-prefix-ready-002' 2
    $legacyEvent.timestamp = '2026-01-02T03:04:06.0000000Z'
    $mixedLedgerText = (@(
        $bootstrapEvent | ConvertTo-Json -Depth 16 -Compress
        $legacyEvent | ConvertTo-Json -Depth 16 -Compress
    ) -join "`n") + "`n"
    [IO.File]::WriteAllText($mixedLedgerPath, $mixedLedgerText, [Text.UTF8Encoding]::new($false))
    $mixedEvents = @(Read-LedgerEventsForTest $mixedLedgerPath)
    Assert-Ledger ($mixedEvents.Count -eq 2 -and [string]$mixedEvents[0].schema -eq 'rusty.morphospace.workflow.iteration_event.v2' -and [string]$mixedEvents[1].schema -eq 'rusty.morphospace.workflow.iteration_event.v1') 'historical v2 bootstrap followed by v1 events was not admitted'

    $firstLegacyEvent = New-LedgerEvent 'mixed-prefix-legacy-001' 1
    [IO.File]::WriteAllText($mixedLedgerPath, (($firstLegacyEvent | ConvertTo-Json -Depth 16 -Compress) + "`n" + ($bootstrapEvent | ConvertTo-Json -Depth 16 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $lateV2Rejected = $false
    try { Read-LedgerEventsForTest $mixedLedgerPath | Out-Null } catch { $lateV2Rejected = $_.Exception.Message -like '*v2 event outside the historical bootstrap position*' }
    Assert-Ledger $lateV2Rejected 'v2 event outside the historical bootstrap position was accepted'

    $nonzeroBootstrap = New-LedgerBootstrapEvent
    $nonzeroBootstrap.previous_event_sha256 = '1' * 64
    [IO.File]::WriteAllText($mixedLedgerPath, (($nonzeroBootstrap | ConvertTo-Json -Depth 16 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $nonzeroBootstrapRejected = $false
    try { Read-LedgerEventsForTest $mixedLedgerPath | Out-Null } catch { $nonzeroBootstrapRejected = $_.Exception.Message -like '*does not use the zero predecessor*' }
    Assert-Ledger $nonzeroBootstrapRejected 'historical v2 bootstrap with a nonzero predecessor was accepted'

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

    $unit036 = 'historical-active-unit-036'
    $unit037 = 'corrective-current-unit-037'

    $targetIdentityWorkspace = Join-Path $workspace 'supersession-target-as-event-identity'
    $targetIdentityFixture = Initialize-SupersessionLedgerFixture $targetIdentityWorkspace $unit036 $unit037
    $targetIdentityFixture.event.unit_id = $unit037
    Assert-SupersessionRejectedAtomically `
        -Fixture $targetIdentityFixture `
        -ExpectedMessage '*old and replacement unit identities must differ*'

    $wrongOldWorkspace = Join-Path $workspace 'supersession-wrong-old'
    $wrongOldFixture = Initialize-SupersessionLedgerFixture $wrongOldWorkspace $unit036 $unit037
    $wrongOldId = 'wrong-historical-unit-036'
    $wrongOldEvent = New-LedgerEvent "$wrongOldId-superseded-by-$unit037" 1
    $wrongOldEvent.unit_id = $wrongOldId
    $wrongOldTargetState = [pscustomobject][ordered]@{
        schema = 'test'; project_id = 'ledger-test'; current_unit = $unit037
        last_event_id = [string]$wrongOldEvent.event_id
    }
    Assert-SupersessionRejectedAtomically `
        -Fixture $wrongOldFixture `
        -TargetState $wrongOldTargetState `
        -Event $wrongOldEvent `
        -ExpectedMessage "*current unit must be old unit '$wrongOldId'*"

    $wrongNewWorkspace = Join-Path $workspace 'supersession-wrong-new'
    $wrongNewFixture = Initialize-SupersessionLedgerFixture $wrongNewWorkspace $unit036 $unit037
    $wrongNewId = 'wrong-corrective-unit-037'
    $wrongNewEvent = New-LedgerEvent "$unit036-superseded-by-$wrongNewId" 1
    $wrongNewEvent.unit_id = $unit036
    Assert-SupersessionRejectedAtomically `
        -Fixture $wrongNewFixture `
        -Event $wrongNewEvent `
        -ExpectedMessage "*event identity must exactly equal '$unit036-superseded-by-$unit037'*"

    $inactiveOldWorkspace = Join-Path $workspace 'supersession-inactive-old'
    $inactiveOldFixture = Initialize-SupersessionLedgerFixture $inactiveOldWorkspace $unit036 $unit037 -OldStatus accepted
    Assert-SupersessionRejectedAtomically `
        -Fixture $inactiveOldFixture `
        -ExpectedMessage "*old unit '$unit036' must be active or validating*"

    $wrongTargetWorkspace = Join-Path $workspace 'supersession-wrong-target'
    $wrongTargetFixture = Initialize-SupersessionLedgerFixture $wrongTargetWorkspace $unit036 $unit037
    $wrongTargetState = [pscustomobject][ordered]@{
        schema = 'test'; project_id = 'ledger-test'; current_unit = $unit036
        last_event_id = [string]$wrongTargetFixture.event_id
    }
    Assert-SupersessionRejectedAtomically `
        -Fixture $wrongTargetFixture `
        -TargetState $wrongTargetState `
        -ExpectedMessage '*old and replacement unit identities must differ*'

    $ambiguousDelimiterWorkspace = Join-Path $workspace 'supersession-ambiguous-delimiter'
    $ambiguousDelimiterFixture = Initialize-SupersessionLedgerFixture $ambiguousDelimiterWorkspace $unit036 $unit037
    $ambiguousDelimiterFixture.event.event_id = "$unit036-superseded-by-injected-superseded-by-$unit037"
    $ambiguousDelimiterFixture.target_state.last_event_id = [string]$ambiguousDelimiterFixture.event.event_id
    Assert-SupersessionRejectedAtomically `
        -Fixture $ambiguousDelimiterFixture `
        -ExpectedMessage '*ambiguous repeated delimiter*'

    $wrongCurrentWorkspace = Join-Path $workspace 'supersession-wrong-current'
    $wrongCurrentFixture = Initialize-SupersessionLedgerFixture `
        $wrongCurrentWorkspace $unit036 $unit037 `
        -CurrentUnitId 'unrelated-current-unit'
    Assert-SupersessionRejectedAtomically `
        -Fixture $wrongCurrentFixture `
        -ExpectedMessage "*current unit must be old unit '$unit036'*"

    $validSupersessionWorkspace = Join-Path $workspace 'supersession-valid-start-complete'
    $validSupersession = Initialize-SupersessionLedgerFixture $validSupersessionWorkspace $unit036 $unit037 -OldStatus validating
    $validOldBytes = [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $validSupersessionWorkspace $validSupersession.old_unit_path)))
    $validIntentPath = Publish-SupersessionIntent $validSupersession
    $validIntent = Get-Content -LiteralPath $validIntentPath -Raw | ConvertFrom-Json
    Assert-Ledger (
        [string]$validIntent.schema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2' -and
        [string]$validIntent.supersession.old_unit_id -ceq $unit036 -and
        [string]$validIntent.supersession.new_unit_id -ceq $unit037 -and
        [string]$validIntent.supersession.pre_state.document.current_unit -ceq $unit036 -and
        [string]$validIntent.supersession.old_unit.document.unit_id -ceq $unit036 -and
        @(Get-Content (Join-Path $validSupersessionWorkspace 'iteration-events.jsonl') | Where-Object { $_ }).Count -eq 0
    ) 'valid supersession intent lacks its exact authenticated old-to-replacement pre-state binding'
    $validResult = Complete-MorphospaceTransitionLedger `
        -WorkspaceRoot $validSupersessionWorkspace `
        -TransactionId $validSupersession.transaction_id `
        -Repair
    $validEvent = Get-Content (Join-Path $validSupersessionWorkspace 'iteration-events.jsonl') | ConvertFrom-Json
    $validState = Get-Content -Raw (Join-Path $validSupersessionWorkspace 'workspace.state.json') | ConvertFrom-Json
    $validNewUnit = Get-Content -Raw (Join-Path $validSupersessionWorkspace $validSupersession.new_unit_path) | ConvertFrom-Json
    Assert-Ledger (
        $validResult.status -eq 'committed' -and
        [string]$validState.current_unit -ceq $unit037 -and
        [string]$validNewUnit.unit_id -ceq $unit037 -and
        [string]$validNewUnit.status -ceq 'active' -and
        [string]$validEvent.unit_id -ceq $unit036 -and
        [string]$validEvent.event_id -ceq "$unit036-superseded-by-$unit037" -and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $validSupersessionWorkspace $validSupersession.old_unit_path))) -ceq $validOldBytes
    ) 'valid supersession did not commit one exact old-to-replacement edge while preserving the old unit'

    $legacyProjectedWorkspace = Join-Path $workspace 'supersession-legacy-projected-target'
    $legacyProjected = Initialize-SupersessionLedgerFixture $legacyProjectedWorkspace $unit036 $unit037
    $legacyIntentPath = Publish-SupersessionIntent $legacyProjected
    $legacyIntent = Get-Content -LiteralPath $legacyIntentPath -Raw | ConvertFrom-Json -DateKind String
    $legacyIntent.schema = 'rusty.morphospace.workflow.transition_ledger_intent.v1'
    $legacyIntent.PSObject.Properties.Remove('supersession')
    Write-Json $legacyIntentPath $legacyIntent
    Write-Json (Join-Path $legacyProjectedWorkspace 'workspace.state.json') $legacyProjected.target_state
    Write-Json (Join-Path $legacyProjectedWorkspace $legacyProjected.new_unit_path) $legacyProjected.target_unit
    $legacyLedgerBefore = [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $legacyProjectedWorkspace 'iteration-events.jsonl')))
    $legacyRejected = $false
    $legacyMessage = ''
    try { Complete-MorphospaceTransitionLedger -WorkspaceRoot $legacyProjectedWorkspace -TransactionId $legacyProjected.transaction_id -Repair | Out-Null }
    catch {
        $legacyMessage = $_.Exception.Message
        $legacyRejected = $legacyMessage -like '*Legacy supersession intent lacks an authenticated semantic binding*'
    }
    Assert-Ledger ($legacyRejected -and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $legacyProjectedWorkspace 'iteration-events.jsonl'))) -ceq $legacyLedgerBefore -and
        -not [IO.File]::Exists((Join-Path $legacyProjectedWorkspace "receipts\transactions\$($legacyProjected.transaction_id).completion.json"))
    ) "unbound legacy supersession completed from an unrelated already-projected state: $legacyMessage"

    $oldMutationWorkspace = Join-Path $workspace 'supersession-old-unit-mutated'
    $oldMutation = Initialize-SupersessionLedgerFixture $oldMutationWorkspace $unit036 $unit037
    [void](Publish-SupersessionIntent $oldMutation)
    $mutatedOldUnit = $oldMutation.old_unit.PSObject.Copy()
    $mutatedOldUnit.status = 'validating'
    Write-Json (Join-Path $oldMutationWorkspace $oldMutation.old_unit_path) $mutatedOldUnit
    $oldMutationRejected = $false
    $oldMutationMessage = ''
    try { Complete-MorphospaceTransitionLedger -WorkspaceRoot $oldMutationWorkspace -TransactionId $oldMutation.transaction_id -Repair | Out-Null }
    catch {$oldMutationMessage=$_.Exception.Message;$oldMutationRejected=$oldMutationMessage-like'*workspace endpoints differ from the authenticated intent binding*'}
    Assert-Ledger ($oldMutationRejected -and [IO.File]::ReadAllBytes((Join-Path $oldMutationWorkspace 'iteration-events.jsonl')).Length -eq 0) "old-unit status mutation escaped the authenticated supersession binding: $oldMutationMessage"

    $targetMutationWorkspace = Join-Path $workspace 'supersession-target-unit-mutated'
    $targetMutation = Initialize-SupersessionLedgerFixture $targetMutationWorkspace $unit036 $unit037
    [void](Publish-SupersessionIntent $targetMutation)
    $mutatedTargetUnit = $targetMutation.new_unit.PSObject.Copy()
    $mutatedTargetUnit.status = 'validating'
    Write-Json (Join-Path $targetMutationWorkspace $targetMutation.new_unit_path) $mutatedTargetUnit
    $targetMutationRejected = $false
    $targetMutationMessage = ''
    try { Complete-MorphospaceTransitionLedger -WorkspaceRoot $targetMutationWorkspace -TransactionId $targetMutation.transaction_id -Repair | Out-Null }
    catch {$targetMutationMessage=$_.Exception.Message;$targetMutationRejected=$targetMutationMessage-like'*failed expected pre-unit CAS*'}
    Assert-Ledger ($targetMutationRejected -and [IO.File]::ReadAllBytes((Join-Path $targetMutationWorkspace 'iteration-events.jsonl')).Length -eq 0) "replacement-unit mutation escaped supersession completion CAS: $targetMutationMessage"

    $pathMutationWorkspace = Join-Path $workspace 'supersession-intent-path-mutated'
    $pathMutation = Initialize-SupersessionLedgerFixture $pathMutationWorkspace $unit036 $unit037
    $pathMutationIntentPath = Publish-SupersessionIntent $pathMutation
    $pathMutationIntent = Get-Content -LiteralPath $pathMutationIntentPath -Raw | ConvertFrom-Json -DateKind String
    $pathMutationIntent.unit.path = [string]$pathMutationIntent.supersession.old_unit.path
    Write-Json $pathMutationIntentPath $pathMutationIntent
    $pathMutationRejected = $false
    $pathMutationMessage = ''
    try { Complete-MorphospaceTransitionLedger -WorkspaceRoot $pathMutationWorkspace -TransactionId $pathMutation.transaction_id -Repair | Out-Null }
    catch {$pathMutationMessage=$_.Exception.Message;$pathMutationRejected=$pathMutationMessage-like'*replacement path differs from its authenticated binding*'}
    Assert-Ledger ($pathMutationRejected -and [IO.File]::ReadAllBytes((Join-Path $pathMutationWorkspace 'iteration-events.jsonl')).Length -eq 0) "mutated supersession target path escaped intent validation: $pathMutationMessage"

    $tornBindingWorkspace = Join-Path $workspace 'supersession-torn-tail-invalid-binding'
    $tornBinding = Initialize-SupersessionLedgerFixture $tornBindingWorkspace $unit036 $unit037
    $tornBindingIntentPath = Publish-SupersessionIntent $tornBinding
    $tornBindingIntent = Get-Content -LiteralPath $tornBindingIntentPath -Raw | ConvertFrom-Json -DateKind String
    $tornBindingIntent.supersession.pre_state.document.current_unit = $unit037
    Write-Json $tornBindingIntentPath $tornBindingIntent
    $tornLedgerPath = Join-Path $tornBindingWorkspace 'iteration-events.jsonl'
    $canonicalLine = [Text.UTF8Encoding]::new($false).GetBytes(($tornBinding.event | ConvertTo-Json -Depth 32 -Compress) + "`n")
    $tornStream = [IO.FileStream]::new($tornLedgerPath,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $tornStream.Write($canonicalLine,0,17);$tornStream.Flush($true) } finally { $tornStream.Dispose() }
    $tornBytesBefore = [Convert]::ToHexString([IO.File]::ReadAllBytes($tornLedgerPath))
    $tornBindingRejected = $false
    $tornBindingMessage = ''
    try { Complete-MorphospaceTransitionLedger -WorkspaceRoot $tornBindingWorkspace -TransactionId $tornBinding.transaction_id -Repair | Out-Null }
    catch {$tornBindingMessage=$_.Exception.Message;$tornBindingRejected=$tornBindingMessage-like'*pre-state binding is invalid*'}
    Assert-Ledger ($tornBindingRejected -and
        [Convert]::ToHexString([IO.File]::ReadAllBytes($tornLedgerPath)) -ceq $tornBytesBefore
    ) "repair truncated a torn tail before rejecting an invalid supersession binding: $tornBindingMessage"

    Invoke-ConcurrentSupersessionDriftTest `
        -WorkspaceRoot (Join-Path $workspace 'supersession-concurrent-old-unit-drift') `
        -TransitionModulePath $transitionModulePath `
        -OldUnitId $unit036 `
        -NewUnitId $unit037

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

    $projectionWorkspace=Join-Path $workspace 'additional-projection-repair'
    Initialize-LedgerFixture $projectionWorkspace $state $unit
    $projectBefore=[pscustomobject][ordered]@{schema='test';project_id='ledger-test';revision=1}
    $projectAfter=[pscustomobject][ordered]@{schema='test';project_id='ledger-test';revision=2}
    $lockBefore=[pscustomobject][ordered]@{schema='test';project_id='ledger-test';revision=4}
    $lockAfter=[pscustomobject][ordered]@{schema='test';project_id='ledger-test';revision=5}
    Write-Json (Join-Path $projectionWorkspace 'project.spec.json') $projectBefore
    Write-Json (Join-Path $projectionWorkspace 'feature.lock.json') $lockBefore
    $projectionInterrupted=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $projectionWorkspace `
            -TransactionId 'additional-projection-repair-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'additional-projection-repair' 1) `
            -AdditionalProjections @(
                [pscustomobject]@{path='feature.lock.json';expected_sha256=(Get-LedgerDocumentHash $lockBefore);document=$lockAfter},
                [pscustomobject]@{path='project.spec.json';expected_sha256=(Get-LedgerDocumentHash $projectBefore);document=$projectAfter}
            ) `
            -FaultAfter after-projection | Out-Null
    }catch{$projectionInterrupted=$true}
    $projectionIntent=Get-Content -Raw (Join-Path $projectionWorkspace 'receipts\transactions\additional-projection-repair-transition.intent.json')|ConvertFrom-Json
    Assert-Ledger ($projectionInterrupted-and[string]$projectionIntent.schema-ceq'rusty.morphospace.workflow.transition_ledger_intent.v3'-and@($projectionIntent.additional_projections).Count-eq2) 'additional projections did not publish one authenticated v3 intent'
    $projectionResult=Complete-MorphospaceTransitionLedger -WorkspaceRoot $projectionWorkspace -TransactionId 'additional-projection-repair-transition' -Repair
    Assert-Ledger ($projectionResult.status-eq'committed'-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $projectionWorkspace 'project.spec.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $projectAfter)-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $projectionWorkspace 'feature.lock.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $lockAfter)-and
        @(Get-Content (Join-Path $projectionWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq1
    ) 'additional projection interruption did not repair to one committed target'
    $projectionCompletionRelative=[IO.Path]::GetRelativePath($workspace,(Join-Path $projectionWorkspace 'receipts\transactions\additional-projection-repair-transition.completion.json')).Replace('\','/')
    $projectionPaths=@(Get-LedgerCommittedTransitionPaths -WorkspaceRoot $projectionWorkspace -AutomationOutputs @([pscustomobject]@{phase='transition';role='transition-ledger-completion';path=$projectionCompletionRelative}) -RepositoryMap @{planning=[pscustomobject]@{path=$workspace}})
    Assert-Ledger ($projectionPaths.Count-eq5-and@($projectionPaths|Where-Object{$_-like'*/feature.lock.json'}).Count-eq1-and@($projectionPaths|Where-Object{$_-like'*/project.spec.json'}).Count-eq1) 'validation authority did not bind both committed v3 additional projections'

    $wrongRawWorkspace=Join-Path $workspace 'projected-raw-wrong-preflight'
    Initialize-LedgerFixture $wrongRawWorkspace $state $unit
    Write-Json (Join-Path $wrongRawWorkspace 'project.spec.json') $projectBefore
    $wrongRawUnitPath=Join-Path $wrongRawWorkspace 'iteration-units\unit.json'
    $wrongRawUnitBefore=[IO.File]::ReadAllBytes($wrongRawUnitPath)
    $wrongRawRejected=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $wrongRawWorkspace `
            -TransactionId 'projected-raw-wrong-preflight-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'projected-raw-wrong-preflight' 1) `
            -ExpectedPreUnitRawSha256 ('0'*64) `
            -AdditionalProjections @([pscustomobject]@{path='project.spec.json';expected_sha256=(Get-LedgerDocumentHash $projectBefore);document=$projectAfter}) | Out-Null
    }catch{$wrongRawRejected=$_.Exception.Message-like'*expected pre-unit raw SHA-256*'}
    Assert-Ledger ($wrongRawRejected-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes($wrongRawUnitPath))-ceq[Convert]::ToHexString($wrongRawUnitBefore)-and
        -not[IO.File]::Exists((Join-Path $wrongRawWorkspace 'receipts\transactions\projected-raw-wrong-preflight-transition.intent.json'))
    ) 'wrong projected raw pre-unit SHA reached intent publication or mutated the unit'

    $retirementProjectionWorkspace=Join-Path $workspace 'retirement-v1-projection-rejection'
    Initialize-LedgerFixture $retirementProjectionWorkspace $state $unit
    Write-Json (Join-Path $retirementProjectionWorkspace 'project.spec.json') $projectBefore
    $retirementProjectionEvent=New-LedgerEvent 'unit-test-proposal-retired-0001' 1
    $retirementProjectionRejected=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $retirementProjectionWorkspace `
            -TransactionId 'unit-test-proposal-retired-0001-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event $retirementProjectionEvent `
            -ExpectedPreUnitRawSha256 (Get-LedgerFileHash (Join-Path $retirementProjectionWorkspace 'iteration-units\unit.json')) `
            -AdditionalProjections @([pscustomobject]@{path='project.spec.json';expected_sha256=(Get-LedgerDocumentHash $projectBefore);document=$projectAfter}) | Out-Null
    }catch{$retirementProjectionRejected=$_.Exception.Message-like'*may not replace proposed-unit retirement v1 receipt binding*'}
    Assert-Ledger ($retirementProjectionRejected-and
        -not[IO.File]::Exists((Join-Path $retirementProjectionWorkspace 'receipts\transactions\unit-test-proposal-retired-0001-transition.intent.json'))-and
        [IO.File]::ReadAllBytes((Join-Path $retirementProjectionWorkspace 'iteration-events.jsonl')).Length-eq0
    ) 'projected raw v4 path changed proposed-unit retirement v1 semantics'

    $rawDriftWorkspace=Join-Path $workspace 'projected-raw-normalization-drift'
    Initialize-LedgerFixture $rawDriftWorkspace $state $unit
    Write-Json (Join-Path $rawDriftWorkspace 'project.spec.json') $projectBefore
    $rawDriftUnitPath=Join-Path $rawDriftWorkspace 'iteration-units\unit.json'
    $rawDriftHash=Get-LedgerFileHash $rawDriftUnitPath
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $rawDriftWorkspace `
            -TransactionId 'projected-raw-normalization-drift-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'projected-raw-normalization-drift' 1) `
            -ExpectedPreUnitRawSha256 $rawDriftHash `
            -AdditionalProjections @([pscustomobject]@{path='project.spec.json';expected_sha256=(Get-LedgerDocumentHash $projectBefore);document=$projectAfter}) `
            -FaultAfter after-intent | Out-Null
    }catch{}
    $rawDriftProjectBefore=[IO.File]::ReadAllBytes((Join-Path $rawDriftWorkspace 'project.spec.json'))
    $rawDriftStateBefore=[IO.File]::ReadAllBytes((Join-Path $rawDriftWorkspace 'workspace.state.json'))
    $rawDriftSameUnit=Get-Content -Raw $rawDriftUnitPath|ConvertFrom-Json
    [IO.File]::WriteAllText($rawDriftUnitPath,($rawDriftSameUnit|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    Assert-Ledger ((Get-LedgerDocumentHash (Get-Content -Raw $rawDriftUnitPath|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)-and(Get-LedgerFileHash $rawDriftUnitPath)-cne$rawDriftHash) 'normalization-drift fixture did not retain canonical identity while changing raw bytes'
    $rawDriftRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $rawDriftWorkspace -TransactionId 'projected-raw-normalization-drift-transition' -Repair|Out-Null}catch{$rawDriftRejected=$_.Exception.Message-like'*durable raw pre-unit byte-hash CAS*'}
    Assert-Ledger ($rawDriftRejected-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $rawDriftWorkspace 'project.spec.json')))-ceq[Convert]::ToHexString($rawDriftProjectBefore)-and
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $rawDriftWorkspace 'workspace.state.json')))-ceq[Convert]::ToHexString($rawDriftStateBefore)-and
        [IO.File]::ReadAllBytes((Join-Path $rawDriftWorkspace 'iteration-events.jsonl')).Length-eq0-and
        -not[IO.File]::Exists((Join-Path $rawDriftWorkspace 'receipts\transactions\projected-raw-normalization-drift-transition.completion.json'))
    ) 'normalization-equivalent raw-unit drift reached a projection, event, or completion'

    $projectedRawWorkspace=Join-Path $workspace 'projected-raw-recovery'
    Initialize-LedgerFixture $projectedRawWorkspace $state $unit
    Write-Json (Join-Path $projectedRawWorkspace 'project.spec.json') $projectBefore
    Write-Json (Join-Path $projectedRawWorkspace 'feature.lock.json') $lockBefore
    $projectedRawUnitPath=Join-Path $projectedRawWorkspace 'iteration-units\unit.json'
    $projectedRawHash=Get-LedgerFileHash $projectedRawUnitPath
    $projectedRawInterrupted=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $projectedRawWorkspace `
            -TransactionId 'projected-raw-recovery-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'projected-raw-recovery' 1) `
            -ExpectedPreUnitRawSha256 $projectedRawHash `
            -AdditionalProjections @(
                [pscustomobject]@{path='feature.lock.json';expected_sha256=(Get-LedgerDocumentHash $lockBefore);document=$lockAfter},
                [pscustomobject]@{path='project.spec.json';expected_sha256=(Get-LedgerDocumentHash $projectBefore);document=$projectAfter}
            ) `
            -FaultAfter after-projection | Out-Null
    }catch{$projectedRawInterrupted=$_.Exception.Message-like'*Injected interruption after projections*'}
    $projectedRawIntent=Get-Content -Raw (Join-Path $projectedRawWorkspace 'receipts\transactions\projected-raw-recovery-transition.intent.json')|ConvertFrom-Json
    Assert-Ledger ($projectedRawInterrupted-and
        [string]$projectedRawIntent.schema-ceq'rusty.morphospace.workflow.transition_ledger_intent.v4'-and
        [string]$projectedRawIntent.pre_unit_raw.path-ceq'iteration-units/unit.json'-and
        [string]$projectedRawIntent.pre_unit_raw.sha256-ceq$projectedRawHash-and
        @($projectedRawIntent.additional_projections).Count-eq2
    ) 'projected raw transition did not publish the closed v4 raw/projection binding'
    $projectedRawResult=Complete-MorphospaceTransitionLedger -WorkspaceRoot $projectedRawWorkspace -TransactionId 'projected-raw-recovery-transition' -Repair
    $projectedRawReplay=Complete-MorphospaceTransitionLedger -WorkspaceRoot $projectedRawWorkspace -TransactionId 'projected-raw-recovery-transition'
    Assert-Ledger ($projectedRawResult.status-eq'committed'-and$projectedRawReplay.status-eq'already-committed'-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $projectedRawWorkspace 'project.spec.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $projectAfter)-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $projectedRawWorkspace 'feature.lock.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $lockAfter)-and
        @(Get-Content (Join-Path $projectedRawWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq1
    ) 'projected raw interruption did not recover and replay idempotently'
    $projectedRawCompletionRelative=[IO.Path]::GetRelativePath($workspace,(Join-Path $projectedRawWorkspace 'receipts\transactions\projected-raw-recovery-transition.completion.json')).Replace('\','/')
    $projectedRawPaths=@(Get-LedgerCommittedTransitionPaths -WorkspaceRoot $projectedRawWorkspace -AutomationOutputs @([pscustomobject]@{phase='transition';role='transition-ledger-completion';path=$projectedRawCompletionRelative}) -RepositoryMap @{planning=[pscustomobject]@{path=$workspace}})
    Assert-Ledger ($projectedRawPaths.Count-eq5-and@($projectedRawPaths|Where-Object{$_-like'*/feature.lock.json'}).Count-eq1-and@($projectedRawPaths|Where-Object{$_-like'*/project.spec.json'}).Count-eq1) 'validation authority did not bind the committed v4 projection set'

    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'unknown-root' -Mutation {
        param($caseWorkspace,$intent)
        $intent | Add-Member -NotePropertyName unknown_policy -NotePropertyValue 'forbidden'
    }
    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'stray-supersession' -Mutation {
        param($caseWorkspace,$intent)
        $intent | Add-Member -NotePropertyName supersession -NotePropertyValue ([pscustomobject]@{ old_unit_id='forbidden' })
    }
    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'zero-projections' -Mutation {
        param($caseWorkspace,$intent)
        $intent.additional_projections = @()
    }
    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'extra-projection' -Mutation {
        param($caseWorkspace,$intent)
        $intent.additional_projections = @($intent.additional_projections[0],$intent.additional_projections[1],$intent.additional_projections[1])
    }
    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'duplicate-projection' -Mutation {
        param($caseWorkspace,$intent)
        $intent.additional_projections[1].path = [string]$intent.additional_projections[0].path
    }
    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'misordered-projections' -Mutation {
        param($caseWorkspace,$intent)
        $intent.additional_projections = @($intent.additional_projections[1],$intent.additional_projections[0])
    }
    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'unauthorized-projection' -Mutation {
        param($caseWorkspace,$intent)
        $intent.additional_projections[0].path = 'unowned.json'
    }
    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'projection-document-hash' -Mutation {
        param($caseWorkspace,$intent)
        $intent.additional_projections[1].document.revision = 99
    }
    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'projection-project-identity' -Mutation {
        param($caseWorkspace,$intent)
        $projection = @($intent.additional_projections | Where-Object { [string]$_.path -ceq 'project.spec.json' })[0]
        $projection.document.project_id = 'substituted-project'
        $projection.target_sha256 = Get-LedgerDocumentHash $projection.document
        Write-Json -Path (Join-Path $caseWorkspace 'project.spec.json') -Value $projection.document
    }
    Assert-LedgerCommittedV4DamageRejected -TemplateWorkspace $projectedRawWorkspace -PlanningRoot $workspace -Name 'projection-unknown-field' -Mutation {
        param($caseWorkspace,$intent)
        $intent.additional_projections[0] | Add-Member -NotePropertyName policy -NotePropertyValue 'forbidden'
    }

    $rawBindingTamperWorkspace=Join-Path $workspace 'projected-raw-binding-tamper'
    Initialize-LedgerFixture $rawBindingTamperWorkspace $state $unit
    Write-Json (Join-Path $rawBindingTamperWorkspace 'project.spec.json') $projectBefore
    $rawBindingTamperHash=Get-LedgerFileHash (Join-Path $rawBindingTamperWorkspace 'iteration-units\unit.json')
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $rawBindingTamperWorkspace `
            -TransactionId 'projected-raw-binding-tamper-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'projected-raw-binding-tamper' 1) `
            -ExpectedPreUnitRawSha256 $rawBindingTamperHash `
            -AdditionalProjections @([pscustomobject]@{path='project.spec.json';expected_sha256=(Get-LedgerDocumentHash $projectBefore);document=$projectAfter}) `
            -FaultAfter after-intent | Out-Null
    }catch{}
    $rawBindingTamperIntentPath=Join-Path $rawBindingTamperWorkspace 'receipts\transactions\projected-raw-binding-tamper-transition.intent.json'
    $rawBindingTamperIntent=Get-Content -Raw $rawBindingTamperIntentPath|ConvertFrom-Json
    $rawBindingTamperIntent.pre_unit_raw.sha256='0'*64
    Write-Json $rawBindingTamperIntentPath $rawBindingTamperIntent
    $rawBindingTamperRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $rawBindingTamperWorkspace -TransactionId 'projected-raw-binding-tamper-transition' -Repair|Out-Null}catch{$rawBindingTamperRejected=$_.Exception.Message-like'*durable raw pre-unit byte-hash CAS*'}
    Assert-Ledger ($rawBindingTamperRejected-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $rawBindingTamperWorkspace 'project.spec.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $projectBefore)-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $rawBindingTamperWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
        [IO.File]::ReadAllBytes((Join-Path $rawBindingTamperWorkspace 'iteration-events.jsonl')).Length-eq0
    ) 'tampered durable v4 raw SHA reached a projection or event mutation'

    $projectedRawTamperWorkspace=Join-Path $workspace 'projected-raw-projection-tamper'
    Initialize-LedgerFixture $projectedRawTamperWorkspace $state $unit
    Write-Json (Join-Path $projectedRawTamperWorkspace 'project.spec.json') $projectBefore
    $projectedRawTamperHash=Get-LedgerFileHash (Join-Path $projectedRawTamperWorkspace 'iteration-units\unit.json')
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $projectedRawTamperWorkspace `
            -TransactionId 'projected-raw-projection-tamper-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'projected-raw-projection-tamper' 1) `
            -ExpectedPreUnitRawSha256 $projectedRawTamperHash `
            -AdditionalProjections @([pscustomobject]@{path='project.spec.json';expected_sha256=(Get-LedgerDocumentHash $projectBefore);document=$projectAfter}) `
            -FaultAfter after-intent | Out-Null
    }catch{}
    Write-Json (Join-Path $projectedRawTamperWorkspace 'project.spec.json') ([pscustomobject][ordered]@{schema='test';project_id='ledger-test';revision=99})
    $projectedRawTamperRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $projectedRawTamperWorkspace -TransactionId 'projected-raw-projection-tamper-transition' -Repair|Out-Null}catch{$projectedRawTamperRejected=$_.Exception.Message-like'*additional-projection CAS*'}
    Assert-Ledger ($projectedRawTamperRejected-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $projectedRawTamperWorkspace 'workspace.state.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $state)-and
        (Get-LedgerDocumentHash (Get-Content -Raw (Join-Path $projectedRawTamperWorkspace 'iteration-units\unit.json')|ConvertFrom-Json))-ceq(Get-LedgerDocumentHash $unit)-and
        [IO.File]::ReadAllBytes((Join-Path $projectedRawTamperWorkspace 'iteration-events.jsonl')).Length-eq0
    ) 'tampered v4 additional projection reached state, unit, or event mutation'

    $projectionTamperWorkspace=Join-Path $workspace 'additional-projection-tamper'
    Initialize-LedgerFixture $projectionTamperWorkspace $state $unit
    Write-Json (Join-Path $projectionTamperWorkspace 'project.spec.json') $projectBefore
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $projectionTamperWorkspace `
            -TransactionId 'additional-projection-tamper-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'additional-projection-tamper' 1) `
            -AdditionalProjections @([pscustomobject]@{path='project.spec.json';expected_sha256=(Get-LedgerDocumentHash $projectBefore);document=$projectAfter}) `
            -FaultAfter after-intent | Out-Null
    }catch{}
    Write-Json (Join-Path $projectionTamperWorkspace 'project.spec.json') ([pscustomobject]@{schema='test';project_id='ledger-test';revision=99})
    $projectionTamperRejected=$false
    try{Complete-MorphospaceTransitionLedger -WorkspaceRoot $projectionTamperWorkspace -TransactionId 'additional-projection-tamper-transition' -Repair|Out-Null}catch{$projectionTamperRejected=$_.Exception.Message-like'*additional-projection CAS*'}
    Assert-Ledger ($projectionTamperRejected-and@(Get-Content (Join-Path $projectionTamperWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count-eq0) 'unauthorized additional projection drift reached event mutation'

    $projectionCollisionWorkspace=Join-Path $workspace 'additional-projection-collision'
    Initialize-LedgerFixture $projectionCollisionWorkspace $state $unit
    Write-Json (Join-Path $projectionCollisionWorkspace 'feature.lock.json') $lockBefore
    $projectionCollisionRejected=$false
    try{
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $projectionCollisionWorkspace `
            -TransactionId 'additional-projection-collision-transition' `
            -StatePath 'workspace.state.json' `
            -UnitPath 'iteration-units/unit.json' `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState `
            -TargetUnit $targetUnit `
            -Event (New-LedgerEvent 'additional-projection-collision' 1) `
            -AdditionalProjections @([pscustomobject]@{path='feature.lock.json';expected_sha256=(Get-LedgerDocumentHash $lockBefore);document=$lockAfter}) `
            -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($memoryPayload);path='feature.lock.json';sha256=$memoryHash}) | Out-Null
    }catch{$projectionCollisionRejected=$_.Exception.Message-like'*collides with the transaction control namespace*'}
    Assert-Ledger ($projectionCollisionRejected-and-not[IO.File]::Exists((Join-Path $projectionCollisionWorkspace 'receipts\transactions\additional-projection-collision-transition.intent.json'))) 'additional projection collision reached intent publication'

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
