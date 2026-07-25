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
    $transactionId = "concurrent-$DriftTarget-drift"
    $event = [pscustomobject]@{event_id=$transactionId;sequence=1}
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
    $event = [pscustomobject]@{event_id='unit-accept-0001';sequence=1}
    Initialize-LedgerFixture $workspace $state $unit
    $targetState = [pscustomobject]@{schema='test';stage='after'}
    $targetUnit = [pscustomobject]@{schema='test';status='accepted'}
    $expectedState = Get-LedgerDocumentHash $state
    $expectedUnit = Get-LedgerDocumentHash $unit
    $interrupted = $false
    try {
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $workspace `
            -TransactionId 'unit-accept-0001' `
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
    $result = Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId 'unit-accept-0001' -Repair
    Assert-Ledger ($result.status -eq 'committed') 'repair did not commit'
    Assert-Ledger ((Get-Content (Join-Path $workspace 'workspace.state.json') -Raw | ConvertFrom-Json).stage -eq 'after') 'repair did not preserve target state'
    Assert-Ledger (@(Get-Content (Join-Path $workspace 'iteration-events.jsonl') | Where-Object { $_ }).Count -eq 1) 'repair event count is not one'
    Assert-Ledger ((Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId 'unit-accept-0001').status -eq 'already-committed') 'completion was not idempotent'

    $authorityWorkspace = Join-Path $workspace 'authority'
    Initialize-LedgerFixture $authorityWorkspace $state $unit
    Start-MorphospaceTransitionLedger `
        -WorkspaceRoot $authorityWorkspace `
        -TransactionId 'unit-record-0002' `
        -StatePath 'workspace.state.json' `
        -UnitPath 'iteration-units/unit.json' `
        -EventsPath 'iteration-events.jsonl' `
        -TargetState $targetState `
        -TargetUnit $targetUnit `
        -Event ([pscustomobject]@{event_id='unit-record-0002';sequence=2}) | Out-Null
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force
    $validationModule = Get-Module MorphospaceValidationAuthority
    $outputs = @([pscustomobject]@{
        repo_id='planning'
        path='authority/receipts/transactions/unit-record-0002.completion.json'
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
