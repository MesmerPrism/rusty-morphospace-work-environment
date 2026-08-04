param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'CompletedTransitionSemanticCorrection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceCompletedTransitionSemanticCorrection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Restore-CorrectionTestModules {
    Import-Module (Join-Path $PSScriptRoot 'CompletedTransitionSemanticCorrection.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceCompletedTransitionSemanticCorrection.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
}

function Assert-CorrectionTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Completed-transition correction self-test failed: $Message" }
}

function Assert-CorrectionRejected {
    param([scriptblock]$Action,[string]$Message,[string]$Like = '*')
    $rejected = $false
    $detail = ''
    try { & $Action } catch { $rejected = $true; $detail = $_.Exception.Message }
    Assert-CorrectionTest ($rejected -and ($detail -like $Like)) "$Message (observed: $detail)"
}

function Copy-CorrectionDocument {
    param([object]$Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 100 -Compress))
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'correction test document copy'
}

function Write-CorrectionJson {
    param([string]$Path,[object]$Value)
    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (ConvertTo-MorphospaceCanonicalJson $Value) + "`n", [Text.UTF8Encoding]::new($false))
}

function Write-CorrectionLedger {
    param([string]$Path,[object[]]$Events)
    $text = (@($Events | ForEach-Object { $_ | ConvertTo-Json -Depth 32 -Compress }) -join "`n") + "`n"
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
}

function Get-CorrectionTailEvent {
    param([string]$Path)
    $line = [string](Get-Content -LiteralPath $Path | Select-Object -Last 1)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line)
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'correction test ledger tail'
}

function New-CorrectionFixture {
    param([string]$Root)
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $Root 'iteration-units')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $Root 'receipts\transactions')) | Out-Null

    $project = Read-MorphospaceProtocolJson (Join-Path $repoRoot 'templates\project.spec.example.json')
    $lock = Read-MorphospaceProtocolJson (Join-Path $repoRoot 'templates\feature.lock.example.json')
    $old = Read-MorphospaceProtocolJson (Join-Path $repoRoot 'templates\iteration-unit.example.json')
    $replacement = Copy-CorrectionDocument $old
    $old.unit_id = 'unit-old-001'
    $old.objective = 'Retained active old unit for a legacy supersession semantic-correction fixture.'
    $old.status = 'active'
    $replacement.unit_id = 'unit-new-001'
    $replacement.objective = 'Retained active replacement unit for a legacy supersession semantic-correction fixture.'
    $replacement.status = 'active'
    $eventId = 'unit-old-001-superseded-by-unit-new-001'
    $state = Read-MorphospaceProtocolJson (Join-Path $repoRoot 'templates\workspace.state.example.json')
    $state.current_unit = 'unit-new-001'
    $state.last_event_id = $eventId
    $state.validation_checkpoint = $null
    $state.pending_push_bundle = $null
    $event = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = $eventId
        sequence = 1
        timestamp = '2026-08-04T10:00:00.0000000Z'
        project_id = 'example-project'
        unit_id = 'unit-new-001'
        event_type = 'state-transition'
        summary = 'Legacy completed supersession recorded the replacement in event.unit_id.'
        receipts = @()
    }
    Write-CorrectionJson (Join-Path $Root 'project.spec.json') $project
    Write-CorrectionJson (Join-Path $Root 'feature.lock.json') $lock
    Write-CorrectionJson (Join-Path $Root 'iteration-units\unit-old-001.json') $old
    Write-CorrectionJson (Join-Path $Root 'iteration-units\unit-new-001.json') $replacement
    Write-CorrectionJson (Join-Path $Root 'workspace.state.json') $state
    Write-CorrectionLedger (Join-Path $Root 'iteration-events.jsonl') @($event)

    $preLedger = [byte[]]::new(0)
    $preStateHash = ('a' * 64)
    $preUnitHash = ('b' * 64)
    $transactionId = "$eventId-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intent = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.transition_ledger_intent.v1'
        transaction_id = $transactionId
        created_at = '2026-08-04T09:59:59.0000000Z'
        state = [pscustomobject]@{ path='workspace.state.json' }
        unit = [pscustomobject]@{ path='iteration-units/unit-new-001.json' }
        events = [pscustomobject]@{ path='iteration-events.jsonl' }
        pre = [pscustomobject]@{ state=[pscustomobject]@{sha256=$preStateHash}; unit=[pscustomobject]@{sha256=$preUnitHash} }
        target = [pscustomobject]@{
            state=[pscustomobject]@{sha256=(Get-MorphospaceCanonicalJsonSha256 $state);document=$state}
            unit=[pscustomobject]@{sha256=(Get-MorphospaceCanonicalJsonSha256 $replacement);document=$replacement}
        }
        expected = [pscustomobject]@{
            state_sha256=$preStateHash
            unit_sha256=$preUnitHash
            event_tail_id=$null
            events_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($preLedger)).ToLowerInvariant()
            events_length=0
        }
        artifacts = @()
        event = $event
        status = 'prepared'
    }
    $intentPath = Join-Path $Root ($intentRelative -replace '/', '\')
    Write-CorrectionJson $intentPath $intent
    $completion = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.transition_ledger_completion.v1'
        transaction_id = $transactionId
        completed_at = '2026-08-04T10:00:00.5000000Z'
        intent = [pscustomobject][ordered]@{
            role='transition-ledger-intent'
            path=$intentRelative
            schema=[string]$intent.schema
            sha256=(Get-MorphospaceFileSha256 $intentPath)
        }
        state_sha256 = [string]$intent.target.state.sha256
        unit_sha256 = [string]$intent.target.unit.sha256
        event_id = $eventId
        status = 'committed'
    }
    Write-CorrectionJson (Join-Path $Root ($completionRelative -replace '/', '\')) $completion
    [pscustomobject]@{
        root=$Root
        event_id=$eventId
        old_path=(Join-Path $Root 'iteration-units\unit-old-001.json')
        replacement_path=(Join-Path $Root 'iteration-units\unit-new-001.json')
        state_path=(Join-Path $Root 'workspace.state.json')
        ledger_path=(Join-Path $Root 'iteration-events.jsonl')
        original_intent_path=$intentPath
        original_completion_path=(Join-Path $Root ($completionRelative -replace '/', '\'))
    }
}

function New-CorrectionInput {
    param([object]$Fixture,[string]$Path)
    & (Join-Path $PSScriptRoot 'New-CompletedTransitionSemanticCorrection.ps1') `
        -WorkspaceRoot $Fixture.root -OutPath $Path -Timestamp '2026-08-04T10:00:01.0000000Z' | Out-Null
    $Path
}

function Invoke-WorkflowCorrectionTest {
    param([string]$Workspace,[switch]$ExpectFailure)
    $hostPath = [Environment]::ProcessPath
    if (-not $hostPath -or -not [IO.File]::Exists($hostPath)) { $hostPath = (Get-Command pwsh -ErrorAction Stop).Source }
    $output = @(& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -RepoRoot $repoRoot -WorkspaceRoot $Workspace -SkipOwnerSelfTests 2>&1)
    $code = $LASTEXITCODE
    $detail = (($output | ForEach-Object { [string]$_ }) -join "`n")
    if ($ExpectFailure) {
        Assert-CorrectionTest ($code -ne 0 -and $detail -like '*Workflow contract validation failed*') "WorkflowContracts accepted damaged correction projection (exit $code): $detail"
    } else {
        Assert-CorrectionTest ($code -eq 0) "WorkflowContracts rejected authenticated correction projection (exit $code): $detail"
    }
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("rusty-morphospace-completed-transition-correction-" + [guid]::NewGuid().ToString('N'))
try {
    $positive = New-CorrectionFixture (Join-Path $testRoot 'positive\workspace')
    $positiveInput = New-CorrectionInput $positive (Join-Path $testRoot 'positive\inspected-correction.json')
    $receipt = Read-MorphospaceCompletedTransitionSemanticCorrection $positiveInput
    $canonicalTarget = Join-Path $positive.root ([string]$receipt.document.correction_event.receipt_path -replace '/', '\')
    $before = @{}
    foreach ($path in @($positive.state_path,$positive.ledger_path,$positive.old_path,$positive.replacement_path,$positive.original_intent_path,$positive.original_completion_path)) {
        $before[$path] = [IO.File]::ReadAllBytes($path)
    }

    $builderParameters = (Get-Command New-MorphospaceCompletedTransitionSemanticCorrection).Parameters.Keys
    Assert-CorrectionTest (-not ($builderParameters -contains 'OriginalEventId') -and -not ($builderParameters -contains 'OldUnitId') -and -not ($builderParameters -contains 'ReplacementUnitId')) 'Builder exposes caller-patchable semantic endpoints.'
    $dry = Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $positive.root -CorrectionReceipt $positiveInput -OutPath $canonicalTarget
    Assert-CorrectionTest (-not $dry.executed -and $null -eq $dry.event_id) 'Dry-run did not remain non-mutating.'
    foreach ($path in $before.Keys) {
        Assert-CorrectionTest ((Get-MorphospaceSha256Bytes ([IO.File]::ReadAllBytes($path))) -ceq (Get-MorphospaceSha256Bytes $before[$path])) "Dry-run changed '$path'."
    }

    $routerJson = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') `
        -Action CorrectCompletedTransitionSemantics -WorkspaceRoot $positive.root `
        -CompletedTransitionSemanticCorrection $positiveInput -OutPath $canonicalTarget
    $router = $routerJson | ConvertFrom-Json
    Assert-CorrectionTest ([string]$router.action -ceq 'CorrectCompletedTransitionSemantics' -and -not [bool]$router.executed) 'Invoke-WorkUnitAutomation did not route the typed dry-run action.'
    Restore-CorrectionTestModules

    $executed = Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $positive.root -CorrectionReceipt $positiveInput -OutPath $canonicalTarget -Execute
    Assert-CorrectionTest ($executed.executed -and [string]$executed.event_id -ceq [string]$receipt.document.correction_event.event_id) 'Positive execution did not emit the derived event.'
    Assert-CorrectionTest ((Get-MorphospaceFileSha256 $canonicalTarget) -ceq [string]$receipt.sha256) 'Installed receipt differs from inspected input bytes.'
    foreach ($path in @($positive.old_path,$positive.replacement_path,$positive.original_intent_path,$positive.original_completion_path)) {
        Assert-CorrectionTest ((Get-MorphospaceSha256Bytes ([IO.File]::ReadAllBytes($path))) -ceq (Get-MorphospaceSha256Bytes $before[$path])) "Execution rewrote historical evidence '$path'."
    }
    $afterLedger = [IO.File]::ReadAllBytes($positive.ledger_path)
    Assert-CorrectionTest ($afterLedger.LongLength -gt $before[$positive.ledger_path].LongLength) 'Execution did not append one event.'
    for ($index=0; $index -lt $before[$positive.ledger_path].Length; $index++) {
        Assert-CorrectionTest ($afterLedger[$index] -eq $before[$positive.ledger_path][$index]) 'Execution rewrote the historical ledger prefix.'
    }
    $projectedState = Read-MorphospaceProtocolJson $positive.state_path
    $expectedState = Copy-CorrectionDocument $receipt.document.original_transition.state.document
    $expectedState.last_event_id = [string]$receipt.document.correction_event.event_id
    Assert-CorrectionTest ((Get-MorphospaceCanonicalJsonSha256 $projectedState) -ceq (Get-MorphospaceCanonicalJsonSha256 $expectedState)) 'Execution changed state beyond last_event_id.'
    [void](Test-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $positive.root -ReceiptPath $canonicalTarget -Mode Projection -CorrectionEvent (Get-CorrectionTailEvent $positive.ledger_path))
    Invoke-WorkflowCorrectionTest -Workspace $positive.root
    Restore-CorrectionTestModules

    Assert-CorrectionRejected {
        Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $positive.root -CorrectionReceipt $positiveInput -OutPath $canonicalTarget -Execute | Out-Null
    } 'Replay was accepted.' '*already consumed*'
    Assert-CorrectionRejected {
        Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $positive.root -CorrectionReceipt $canonicalTarget -OutPath $canonicalTarget | Out-Null
    } 'Installed receipt was accepted as its own inspected input.' '*distinct*'

    foreach ($fault in @('after-intent','after-artifact','after-projection','after-event')) {
        $fixture = New-CorrectionFixture (Join-Path $testRoot "$fault\workspace")
        $faultInput = New-CorrectionInput $fixture (Join-Path $testRoot "$fault\inspected.json")
        $faultReceipt = Read-MorphospaceCompletedTransitionSemanticCorrection $faultInput
        $faultTarget = Join-Path $fixture.root ([string]$faultReceipt.document.correction_event.receipt_path -replace '/', '\')
        Assert-CorrectionRejected {
            Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $fixture.root -CorrectionReceipt $faultInput -OutPath $faultTarget -FaultAfter $fault -Execute | Out-Null
        } "Injected $fault interruption did not stop execution." '*Injected interruption*'
        $repaired = Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $fixture.root -CorrectionReceipt $faultInput -OutPath $faultTarget -Execute
        Assert-CorrectionTest ($repaired.executed) "$fault interruption was not repairable."
        [void](Test-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $fixture.root -ReceiptPath $faultTarget -Mode Projection -CorrectionEvent (Get-CorrectionTailEvent $fixture.ledger_path))
    }

    $cas = New-CorrectionFixture (Join-Path $testRoot 'cas\workspace')
    $casInput = New-CorrectionInput $cas (Join-Path $testRoot 'cas\inspected.json')
    $casReceipt = Read-MorphospaceCompletedTransitionSemanticCorrection $casInput
    $casTarget = Join-Path $cas.root ([string]$casReceipt.document.correction_event.receipt_path -replace '/', '\')
    Assert-CorrectionRejected {
        Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $cas.root -CorrectionReceipt $casInput -OutPath $casTarget -BeforeTransitionHook {
            $changed = Read-MorphospaceProtocolJson $cas.state_path
            $changed.plan_revision = [int]$changed.plan_revision + 1
            Write-CorrectionJson $cas.state_path $changed
        } -Execute | Out-Null
    } 'Stale state/CAS mutation was accepted.' '*state*'
    Assert-CorrectionTest (-not [IO.File]::Exists((Join-Path $cas.root "receipts\transactions\$([string]$casReceipt.document.correction_event.event_id)-transition.intent.json"))) 'CAS rejection published an intent.'

    $damaged = New-CorrectionFixture (Join-Path $testRoot 'damaged\workspace')
    $damagedInput = New-CorrectionInput $damaged (Join-Path $testRoot 'damaged\inspected.json')
    $damagedReceipt = Read-MorphospaceCompletedTransitionSemanticCorrection $damagedInput
    $damagedTarget = Join-Path $damaged.root ([string]$damagedReceipt.document.correction_event.receipt_path -replace '/', '\')
    $oldDoc = Read-MorphospaceProtocolJson $damaged.old_path
    $oldDoc.objective = 'Damaged after receipt construction.'
    Write-CorrectionJson $damaged.old_path $oldDoc
    Assert-CorrectionRejected {
        Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $damaged.root -CorrectionReceipt $damagedInput -OutPath $damagedTarget | Out-Null
    } 'Damaged retained old-unit evidence was accepted.' '*old-unit*'

    $patchedReceipt = Copy-CorrectionDocument $receipt.document
    $patchedReceipt.semantic_correction.effective_old_unit_id = 'unit-forged-001'
    $patchedPath = Join-Path $testRoot 'patched-endpoint.json'
    Write-CorrectionJson $patchedPath $patchedReceipt
    Assert-CorrectionRejected {
        Test-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $positive.root -ReceiptPath $patchedPath -Mode PreApply | Out-Null
    } 'Caller-patched semantic endpoint was accepted.' '*semantic endpoints*'

    foreach ($restriction in @(
        [pscustomobject]@{name='original receipts';mutate={param($doc) $doc.semantic_correction.original_receipts=@('receipts/forged.json')}},
        [pscustomobject]@{name='original intent artifacts';mutate={param($doc) $doc.semantic_correction.original_intent_artifacts=@([pscustomobject]@{path='receipts/forged.json'})}},
        [pscustomobject]@{name='fault kind';mutate={param($doc) $doc.fault_kind='some-other-fault'}},
        [pscustomobject]@{name='receipt traversal';mutate={param($doc) $doc.correction_event.receipt_path='../outside.json'}}
    )) {
        $restricted = Copy-CorrectionDocument $receipt.document
        & $restriction.mutate $restricted
        $restrictedName = ([string]$restriction.name).Replace(' ','-')
        $restrictedPath = Join-Path $testRoot "restricted-$restrictedName.json"
        Write-CorrectionJson $restrictedPath $restricted
        Assert-CorrectionRejected {
            Test-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $positive.root -ReceiptPath $restrictedPath -Mode PreApply | Out-Null
        } "Restricted $([string]$restriction.name) shape was accepted." '*schema*'
    }

    $wrongPathFixture = New-CorrectionFixture (Join-Path $testRoot 'wrong-path\workspace')
    $wrongPathInput = New-CorrectionInput $wrongPathFixture (Join-Path $testRoot 'wrong-path\inspected.json')
    Assert-CorrectionRejected {
        Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $wrongPathFixture.root -CorrectionReceipt $wrongPathInput -OutPath (Join-Path $wrongPathFixture.root 'receipts\wrong.json') | Out-Null
    } 'Noncanonical output path was accepted.' '*canonical workspace path*'

    $pendingDamage = New-CorrectionFixture (Join-Path $testRoot 'pending-damage\workspace')
    $pendingInput = New-CorrectionInput $pendingDamage (Join-Path $testRoot 'pending-damage\inspected.json')
    $pendingReceipt = Read-MorphospaceCompletedTransitionSemanticCorrection $pendingInput
    $pendingTarget = Join-Path $pendingDamage.root ([string]$pendingReceipt.document.correction_event.receipt_path -replace '/', '\')
    Assert-CorrectionRejected {
        Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $pendingDamage.root -CorrectionReceipt $pendingInput -OutPath $pendingTarget -FaultAfter after-intent -Execute | Out-Null
    } 'Pending-damage setup did not stop after intent.' '*Injected interruption*'
    $pendingIntent = Join-Path $pendingDamage.root "receipts\transactions\$([string]$pendingReceipt.document.correction_event.event_id)-transition.intent.json"
    $pendingIntentDoc = Read-MorphospaceProtocolJson $pendingIntent
    $pendingIntentDoc.expected.events_length = [int64]$pendingIntentDoc.expected.events_length + 1
    Write-CorrectionJson $pendingIntent $pendingIntentDoc
    Assert-CorrectionRejected {
        Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $pendingDamage.root -CorrectionReceipt $pendingInput -OutPath $pendingTarget -Execute | Out-Null
    } 'Damaged pending intent was repaired.' '*intent differs*'

    $workflowDamageRoot = Join-Path $testRoot 'workflow-damage'
    Copy-Item -LiteralPath $positive.root -Destination $workflowDamageRoot -Recurse
    $workflowReceipt = Join-Path $workflowDamageRoot ([string]$receipt.document.correction_event.receipt_path -replace '/', '\')
    $workflowDoc = Read-MorphospaceProtocolJson $workflowReceipt
    $workflowDoc.semantic_correction.recorded_unit_id = 'unit-old-001'
    Write-CorrectionJson $workflowReceipt $workflowDoc
    Invoke-WorkflowCorrectionTest -Workspace $workflowDamageRoot -ExpectFailure

    Write-Host 'Completed-transition semantic correction self-test passed.'
} finally {
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean completed-transition correction test path outside the system temporary directory.'
        }
        [IO.Directory]::Delete($resolved, $true)
    }
}
