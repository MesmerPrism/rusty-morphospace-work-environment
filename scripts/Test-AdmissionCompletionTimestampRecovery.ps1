param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { throw 'Use -SelfTest.' }

Import-Module (Join-Path $PSScriptRoot 'AdmissionCompletionTimestampRecovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Assert-RecoveryTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Admission completion timestamp recovery self-test failed: $Message" }
}

function Assert-RecoveryRejected([scriptblock]$Action, [string]$Message, [string]$Pattern = '*') {
    $rejected = $false
    try { & $Action | Out-Null }
    catch { $rejected = $_.Exception.Message -like $Pattern }
    Assert-RecoveryTest $rejected $Message
}

function Write-RecoveryTestJson([string]$Path, [object]$Value) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Value) + "`n")
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-RecoveryTestHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Copy-RecoveryTestDocument([object]$Value) {
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String
}

function New-RecoveryFixture([string]$Root, [switch]$ChronologyValid) {
    [void][IO.Directory]::CreateDirectory($Root)
    foreach ($directory in @('local','receipts','receipts/transactions','iteration-units','source-composition-locks')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $Root $directory))
    }
    $projectId = 'synthetic-media-routing'
    $unitId = 'route-leg-authority-v2'
    $admissionId = 'route-leg-authority-v2-admission'
    $preparationId = 'route-leg-authority-v2-envelope'
    $repreparationId = 'route-leg-authority-v2-repreparation'
    $preparedEventId = 'route-leg-authority-v2-envelope-prepared'
    $admissionEventId = "$admissionId-admitted"
    $intentAt = '2026-01-02T00:00:00.0000000Z'
    $completedAt = if ($ChronologyValid) { '2026-01-02T00:00:01.0000000Z' } else { '2026-01-01T23:59:59.0000000Z' }

    $project = [pscustomobject][ordered]@{ schema='rusty.morphospace.workflow.project_spec.v2'; project_id=$projectId; revision=3 }
    $featureLock = [pscustomobject][ordered]@{ schema='rusty.morphospace.workflow.feature_lock.v2'; project_id=$projectId; revision=3; project_revision=3 }
    $repositoryMap = [pscustomobject][ordered]@{ schema='rusty.morphospace.workflow.repository_map.v1'; repositories=@([pscustomobject][ordered]@{repo_id='project-shell';path='..';role='planning'}) }
    $source = [pscustomobject][ordered]@{ schema='rusty.morphospace.workflow.development_envelope_source_composition.v2'; project_id=$projectId; repositories=@() }
    $projectPath = Join-Path $Root 'project.spec.json'
    $lockPath = Join-Path $Root 'feature.lock.json'
    $mapRelative = 'local/repository-map.json'
    $mapPath = Join-Path $Root ($mapRelative -replace '/', '\')
    $sourceRelative = "source-composition-locks/$preparationId.json"
    $sourcePath = Join-Path $Root ($sourceRelative -replace '/', '\')
    Write-RecoveryTestJson $projectPath $project
    Write-RecoveryTestJson $lockPath $featureLock
    Write-RecoveryTestJson $mapPath $repositoryMap
    Write-RecoveryTestJson $sourcePath $source

    $preparationRelative = "receipts/$preparationId.json"
    $preparationPath = Join-Path $Root ($preparationRelative -replace '/', '\')
    $preparation = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.development_envelope_preparation_receipt.v1'
        preparation_id=$preparationId
        project_id=$projectId
        source_composition=[pscustomobject][ordered]@{path=$sourceRelative;sha256=(Get-MorphospaceCanonicalJsonSha256 $source)}
    }
    Write-RecoveryTestJson $preparationPath $preparation
    $repreparationRelative = "receipts/$repreparationId-repreparation.json"
    $repreparationPath = Join-Path $Root ($repreparationRelative -replace '/', '\')
    $repreparation = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.development_envelope_repreparation_receipt.v1'
        repreparation_id=$repreparationId
        preparation_id=$preparationId
        project_id=$projectId
        retired_unit_id='route-leg-authority-v1'
        replacement_unit_id=$unitId
        source_composition=[pscustomobject][ordered]@{path=$sourceRelative;sha256=(Get-RecoveryTestHash $sourcePath)}
    }
    Write-RecoveryTestJson $repreparationPath $repreparation

    $unit = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1'
        unit_id=$unitId
        project_id=$projectId
        status='proposed'
        objective='Exercise a sanitized host-only route-leg admission recovery fixture.'
    }
    $unitRelative = "iteration-units/$unitId.json"
    $unitPath = Join-Path $Root ($unitRelative -replace '/', '\')
    Write-RecoveryTestJson $unitPath $unit
    $preState = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.workspace_state.v2'
        project_id=$projectId
        current_unit=$null
        next_ready_unit=$null
        last_event_id=$preparedEventId
        plan_revision=1
    }
    $targetState = Copy-RecoveryTestDocument $preState
    $targetState.last_event_id = $admissionEventId
    $statePath = Join-Path $Root 'workspace.state.json'
    Write-RecoveryTestJson $statePath $targetState

    $preparedEvent = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1'
        event_id=$preparedEventId
        sequence=1
        timestamp='2026-01-01T00:00:00.0000000Z'
        project_id=$projectId
        unit_id='route-leg-authority-v1'
        event_type='decision'
        summary='Prepared a sanitized synthetic envelope.'
        receipts=@($preparationRelative)
    }
    $admissionEvent = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1'
        event_id=$admissionEventId
        sequence=2
        timestamp=$intentAt
        project_id=$projectId
        unit_id=$unitId
        event_type='state-transition'
        summary='Admitted a bounded proposed development unit; normal Ready, Inspect, and Claim remain required.'
        receipts=@("receipts/$admissionId.json")
    }
    $preparedLine = [Text.UTF8Encoding]::new($false).GetBytes(($preparedEvent | ConvertTo-Json -Depth 32 -Compress) + "`n")
    $admissionLine = [Text.UTF8Encoding]::new($false).GetBytes(($admissionEvent | ConvertTo-Json -Depth 32 -Compress) + "`n")
    $ledgerPath = Join-Path $Root 'iteration-events.jsonl'
    $ledgerBytes = [byte[]]::new($preparedLine.Length + $admissionLine.Length)
    [Array]::Copy($preparedLine, 0, $ledgerBytes, 0, $preparedLine.Length)
    [Array]::Copy($admissionLine, 0, $ledgerBytes, $preparedLine.Length, $admissionLine.Length)
    [IO.File]::WriteAllBytes($ledgerPath, $ledgerBytes)

    $request = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.development_unit_admission.v1'
        admission_kind='ordinary'
        admission_id=$admissionId
        project_id=$projectId
        unit_id=$unitId
        preparation=[pscustomobject][ordered]@{
            preparation_kind='recovered'
            preparation_id=$preparationId
            receipt_path=$preparationRelative
            receipt_sha256=(Get-RecoveryTestHash $preparationPath)
            source_composition_path=$sourceRelative
            source_composition_sha256=(Get-RecoveryTestHash $sourcePath)
            recovery_receipt_path=$repreparationRelative
            recovery_receipt_sha256=(Get-RecoveryTestHash $repreparationPath)
        }
        unit=$unit
        expected=[pscustomobject][ordered]@{
            project_sha256=(Get-MorphospaceCanonicalJsonSha256 $project)
            state_sha256=(Get-MorphospaceCanonicalJsonSha256 $preState)
            feature_lock_sha256=(Get-MorphospaceCanonicalJsonSha256 $featureLock)
            source_composition_path=$sourceRelative
            source_composition_sha256=(Get-RecoveryTestHash $sourcePath)
            repository_map_path=$mapRelative
            repository_map_sha256=(Get-RecoveryTestHash $mapPath)
            events_sha256=(Get-AdmissionRecoverySha256BytesForTest $preparedLine)
            events_length=$preparedLine.Length
            event_tail_id=$preparedEventId
        }
    }
    $requestRelative = "local/$admissionId.json"
    $requestPath = Join-Path $Root ($requestRelative -replace '/', '\')
    $receiptRelative = "receipts/$admissionId.json"
    $admissionReceiptPath = Join-Path $Root ($receiptRelative -replace '/', '\')
    Write-RecoveryTestJson $requestPath $request
    [IO.File]::WriteAllBytes($admissionReceiptPath, [IO.File]::ReadAllBytes($requestPath))

    $transactionId = "$admissionEventId-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $intentPath = Join-Path $Root ($intentRelative -replace '/', '\')
    $admissionBytes = [IO.File]::ReadAllBytes($admissionReceiptPath)
    $intent = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.transition_ledger_intent.v1'
        transaction_id=$transactionId
        created_at=$intentAt
        state=[pscustomobject][ordered]@{path='workspace.state.json'}
        unit=[pscustomobject][ordered]@{path=$unitRelative}
        events=[pscustomobject][ordered]@{path='iteration-events.jsonl'}
        pre=[pscustomobject][ordered]@{state=[pscustomobject][ordered]@{sha256=(Get-MorphospaceCanonicalJsonSha256 $preState)};unit=[pscustomobject][ordered]@{sha256=('0'*64)}}
        target=[pscustomobject][ordered]@{
            state=[pscustomobject][ordered]@{sha256=(Get-MorphospaceCanonicalJsonSha256 $targetState);document=$targetState}
            unit=[pscustomobject][ordered]@{sha256=(Get-MorphospaceCanonicalJsonSha256 $unit);document=$unit}
        }
        expected=[pscustomobject][ordered]@{state_sha256=(Get-MorphospaceCanonicalJsonSha256 $preState);unit_sha256=('0'*64);event_tail_id=$preparedEventId;events_sha256=(Get-AdmissionRecoverySha256BytesForTest $preparedLine);events_length=$preparedLine.Length}
        artifacts=@([pscustomobject][ordered]@{path=$receiptRelative;sha256=(Get-RecoveryTestHash $admissionReceiptPath);bytes_base64=[Convert]::ToBase64String($admissionBytes)})
        event=$admissionEvent
        status='prepared'
    }
    Write-RecoveryTestJson $intentPath $intent
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $completionPath = Join-Path $Root ($completionRelative -replace '/', '\')
    $completion = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.transition_ledger_completion.v1'
        transaction_id=$transactionId
        completed_at=$completedAt
        intent=[pscustomobject][ordered]@{role='transition-ledger-intent';path=$intentRelative;schema=[string]$intent.schema;sha256=(Get-RecoveryTestHash $intentPath)}
        state_sha256=[string]$intent.target.state.sha256
        unit_sha256=[string]$intent.target.unit.sha256
        event_id=$admissionEventId
        status='committed'
    }
    Write-RecoveryTestJson $completionPath $completion
    [pscustomobject]@{
        root=$Root
        project_path=$projectPath
        lock_path=$lockPath
        state_path=$statePath
        unit_path=$unitPath
        ledger_path=$ledgerPath
        completion_path=$completionPath
        recovery_out=(Join-Path $Root 'receipts\admission-completion-timestamp-recovered-0003.json')
    }
}

function Get-AdmissionRecoverySha256BytesForTest([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function New-RecoveryInput([object]$Fixture, [string]$Path) {
    $document = New-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $Fixture.root -Timestamp '2026-01-02T00:00:00.0000000Z'
    Write-RecoveryTestJson $Path $document
    $Path
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ('admission-completion-recovery-' + [Guid]::NewGuid().ToString('N'))
try {
    $positive = New-RecoveryFixture (Join-Path $testRoot 'positive\workspace')
    $inputPath = New-RecoveryInput $positive (Join-Path $testRoot 'positive\inspected.json')
    $inputHash = Get-RecoveryTestHash $inputPath
    $before = @($positive.project_path,$positive.lock_path,$positive.unit_path,$positive.completion_path | ForEach-Object { Get-RecoveryTestHash $_ })
    $dry = Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $positive.root -Recovery $inputPath -ExpectedRecoverySha256 $inputHash -OutPath $positive.recovery_out
    Assert-RecoveryTest (-not $dry.executed -and -not [IO.File]::Exists($positive.recovery_out)) 'dry run mutated the workspace'
    $run = Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $positive.root -Recovery $inputPath -ExpectedRecoverySha256 $inputHash -OutPath $positive.recovery_out -Execute
    $after = @($positive.project_path,$positive.lock_path,$positive.unit_path,$positive.completion_path | ForEach-Object { Get-RecoveryTestHash $_ })
    $state = Read-MorphospaceProtocolJson $positive.state_path
    Assert-RecoveryTest ($run.executed -and [string]$run.event_id -ceq 'admission-completion-timestamp-recovered-0003') 'positive recovery did not execute'
    Assert-RecoveryTest (($before -join '|') -ceq ($after -join '|')) 'recovery changed project, lock, unit, or malformed completion bytes'
    Assert-RecoveryTest ([string]$state.last_event_id -ceq 'admission-completion-timestamp-recovered-0003') 'recovery changed the wrong state projection'
    Assert-RecoveryRejected { Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $positive.root -Recovery $inputPath -ExpectedRecoverySha256 $inputHash -OutPath $positive.recovery_out -Execute } 'replay was accepted' '*already consumed*'

    $validChronology = New-RecoveryFixture (Join-Path $testRoot 'valid-chronology\workspace') -ChronologyValid
    Assert-RecoveryRejected { New-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $validChronology.root -Timestamp '2026-01-02T00:00:02.0000000Z' } 'a chronology-valid admission was treated as damaged' '*chronology*'

    foreach ($damage in @('completion','state','unit','ledger')) {
        $fixture = New-RecoveryFixture (Join-Path $testRoot "$damage\workspace")
        $candidate = New-RecoveryInput $fixture (Join-Path $testRoot "$damage\inspected.json")
        if ($damage -eq 'completion') { [IO.File]::AppendAllText($fixture.completion_path, " ", [Text.UTF8Encoding]::new($false)) }
        if ($damage -eq 'state') { $doc=Read-MorphospaceProtocolJson $fixture.state_path;$doc.plan_revision=2;Write-RecoveryTestJson $fixture.state_path $doc }
        if ($damage -eq 'unit') { $doc=Read-MorphospaceProtocolJson $fixture.unit_path;$doc.objective='Drifted.';Write-RecoveryTestJson $fixture.unit_path $doc }
        if ($damage -eq 'ledger') { [IO.File]::AppendAllText($fixture.ledger_path, "`n", [Text.UTF8Encoding]::new($false)) }
        Assert-RecoveryRejected { Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $fixture.root -Recovery $candidate -OutPath $fixture.recovery_out } "$damage drift was accepted"
    }

    $pins = New-RecoveryFixture (Join-Path $testRoot 'pins\workspace')
    $pinsInput = New-RecoveryInput $pins (Join-Path $testRoot 'pins\inspected.json')
    Assert-RecoveryRejected { Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $pins.root -Recovery $pinsInput -ExpectedRecoverySha256 ('0'*64) -OutPath $pins.recovery_out } 'wrong input hash was accepted' '*SHA-256*'
    Assert-RecoveryRejected { Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $pins.root -Recovery $pinsInput -OutPath (Join-Path $pins.root 'receipts\wrong.json') } 'wrong output path was accepted' '*OutPath*'

    $interrupted = New-RecoveryFixture (Join-Path $testRoot 'interrupted\workspace')
    $interruptedInput = New-RecoveryInput $interrupted (Join-Path $testRoot 'interrupted\inspected.json')
    $interruptedHash = Get-RecoveryTestHash $interruptedInput
    Assert-RecoveryRejected { Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $interrupted.root -Recovery $interruptedInput -ExpectedRecoverySha256 $interruptedHash -OutPath $interrupted.recovery_out -FaultAfter after-intent -Execute } 'after-intent interruption did not stop' '*Injected interruption*'
    $resumed = Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $interrupted.root -Recovery $interruptedInput -ExpectedRecoverySha256 $interruptedHash -OutPath $interrupted.recovery_out -Execute
    Assert-RecoveryTest ($resumed.executed -and [IO.File]::Exists($interrupted.recovery_out)) 'interrupted recovery did not resume exactly'

    Write-Host 'Admission completion timestamp recovery self-test passed.'
} finally {
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFileName($resolved)).StartsWith('admission-completion-recovery-', [StringComparison]::Ordinal)) {
            throw 'Refusing to clean an admission recovery test path outside its owned temporary root.'
        }
        [IO.Directory]::Delete($resolved, $true)
    }
}
