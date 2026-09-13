# Shared owner-produced seed for active retirement and continuation checks.
. (Join-Path $PSScriptRoot 'DevelopmentAdmissionFixture.ps1')

function New-ActiveRetirementContinuationSeed {
    param([string]$Root,[string]$RepositoryRoot)
    $scriptsRoot = Join-Path $RepositoryRoot 'scripts'
    $protocolModule = Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceProtocolCommon.psm1') -PassThru
    $transitionLedgerModule = Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceTransitionLedger.psm1') -PassThru
    Import-Module (Join-Path $PSScriptRoot '../DevelopmentEnvelopePreparation.psm1')
    $seed = New-EnvelopeAdmissionPreparedFixture -Root $Root -RepositoryRoot $RepositoryRoot -TransitionLedgerModule $transitionLedgerModule -OwnerProducedPreparation -AdditiveFeature
    $admissionPath = Join-Path $Root 'u002-admission-input.json'
    Write-EnvelopeJson $admissionPath $seed.admission_template
    $automation = Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1'
    $null = & $automation -Action AdmitDevelopmentUnit -WorkspaceRoot $seed.workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $seed.workspace 'receipts/u002-admission.json') -Timestamp '2026-08-25T00:00:40.0000000Z' -Execute
    $lifecycle = @{WorkspaceRoot=$seed.workspace; UnitId='u002'; RepoMapPath=(Join-Path $seed.workspace 'repository-map.json'); ValidationTier='quick'}
    $null = & $automation @lifecycle -Action Ready -Timestamp '2026-08-25T00:00:41.0000000Z' -Execute
    $null = & $automation @lifecycle -Action Claim -Timestamp '2026-08-25T00:00:42.0000000Z' -Execute
    return $seed
}

function Assert-ActiveRetirementPublicHistory {
    param([string]$WorkspaceRoot,[string]$RepositoryRoot)
    $hostPath = (Get-Process -Id $PID).Path
    $validator = Join-Path $PSScriptRoot '../Test-WorkflowContracts.ps1'
    $before = Get-EnvelopeWorkspaceByteInventorySha256 $WorkspaceRoot
    $output = & $hostPath -NoProfile -File $validator -RepoRoot $RepositoryRoot -WorkspaceRoot $WorkspaceRoot -RepositoryMapPath (Join-Path $WorkspaceRoot 'repository-map.json') -CurrentWorkOnly -SkipOwnerSelfTests 2>&1 | Out-String
    Assert-Envelope ($LASTEXITCODE -eq 0) "active retirement public current-work validation failed: $output"
    Assert-Envelope ($before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $WorkspaceRoot)) 'public current-work validation changed retired workspace bytes'
}

function New-ActiveRetirementReplacementPreparation {
    param([string]$Workspace)
    $project = Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json')
    $state = Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json')
    $lock = Read-EnvelopeProtocolJson (Join-Path $Workspace 'feature.lock.json')
    $envelope = Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $Workspace 'receipts/u002-envelope.json')).envelope
    $envelope.project = Copy-Envelope $project; $envelope.project.revision = [int]$project.revision + 1
    $envelope.feature_lock = Copy-Envelope $lock; $envelope.feature_lock.revision = [int]$lock.revision + 1
    $envelope.feature_lock.project_revision = [int]$envelope.project.revision
    $envelope.feature_lock.generated_at = '2026-08-25T00:01:01.0000000Z'
    $envelope.feature_lock.lock_fingerprint = Get-EnvelopeLockFingerprint $envelope.feature_lock
    $envelope.source_composition.path = 'source-compositions/u003-envelope.json'
    $eventsPath = Join-Path $Workspace 'iteration-events.jsonl'
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.development_envelope_preparation.v1'; preparation_id='u003-envelope'
        project_id=[string]$project.project_id; predecessor_unit_id='u001'; envelope=$envelope
        expected=[ordered]@{
            project_sha256=(Get-EnvelopeCanonicalJsonSha256 $project); state_sha256=(Get-EnvelopeCanonicalJsonSha256 $state)
            feature_lock_sha256=(Get-EnvelopeCanonicalJsonSha256 $lock); repository_map_path='repository-map.json'
            repository_map_sha256=(Get-EnvelopeFileSha256 (Join-Path $Workspace 'repository-map.json'))
            predecessor_unit_path='iteration-units/u001.json'; predecessor_unit_sha256=(Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $Workspace 'iteration-units/u001.json')))
            events_sha256=(Get-EnvelopeFileSha256 $eventsPath); events_length=([IO.FileInfo]$eventsPath).Length; event_tail_id=[string]$state.last_event_id
        }
        does_not_prove=@('Does not accept the retired unit or admit its separately authored replacement.')
    }
}

function Add-ActiveRetirementContinuationEvent {
    param([string]$Workspace,[switch]$Accepted)
    $state = Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json'))
    $unit = Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $Workspace 'iteration-units/u003.json'))
    $sequence = @(Get-Content -LiteralPath (Join-Path $Workspace 'iteration-events.jsonl') | Where-Object { $_ }).Count + 1
    $eventId = if ($Accepted) { 'u003-accepted-{0:d4}' -f $sequence } else { 'u003-observed-{0:d4}' -f $sequence }
    $state.last_event_id=$eventId; $receipts=@()
    if ($Accepted) {
        $unit.status='accepted'; $state.current_unit=$null; $state.last_accepted_receipt='receipts/u003-fixture-accepted.json'
        Write-EnvelopeJson (Join-Path $Workspace $state.last_accepted_receipt) ([ordered]@{schema='fixture.owner.validation.v1';result='pass'})
        $receipts=@($state.last_accepted_receipt)
    }
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=$sequence;timestamp='2026-08-25T00:02:00.0000000Z';project_id=[string]$state.project_id;unit_id='u003';event_type=$(if($Accepted){'state-transition'}else{'decision'});summary='Owner ledger fixture for later continuation history.';receipts=$receipts}
    & $transitionLedgerModule { param($root,$targetState,$targetUnit,$event)
        Start-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId "$($event.event_id)-transition" -StatePath 'workspace.state.json' -UnitPath 'iteration-units/u003.json' -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event
    } $Workspace $state $unit $event | Out-Null
}

function Test-ActiveRetirementFulfilledAdmissionProof {
    param([string]$Workspace,[string]$TestRoot=(Split-Path $Workspace -Parent))
    $admissionModule=Import-Module (Join-Path $PSScriptRoot '../DevelopmentUnitAdmission.psm1') -PassThru
    $guard={param($root)
        $mutex=Enter-MorphospaceWorkspaceMutex $root
        try {
            $events=@(Get-Content -LiteralPath (Join-Path $root 'iteration-events.jsonl')|Where-Object{$_})
            Assert-AdmissionActiveRetirementBinding -Workspace $root -Admission ([pscustomobject]@{unit_id='u004'}) -AdmissionSequence ($events.Count+1)
        } finally {Exit-MorphospaceWorkspaceMutex $mutex}
    }
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace
    & $admissionModule $guard $Workspace
    Assert-Envelope ($before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)) 'authenticated prior replacement fulfillment changed bytes'
    foreach($damage in @('missing-completion','altered-intent','altered-receipt','detached-event')) {
        $damaged=Join-Path $TestRoot ('fulfilled-admission-'+$damage+'-'+[guid]::NewGuid().ToString('N'));Copy-Item -LiteralPath $Workspace -Destination $damaged -Recurse
        switch($damage) {
            'missing-completion' {Remove-Item -LiteralPath (Join-Path $damaged 'receipts/transactions/u003-admission-admitted-transition.completion.json')}
            'altered-intent' {[IO.File]::AppendAllText((Join-Path $damaged 'receipts/transactions/u003-admission-admitted-transition.intent.json'),"`n",[Text.UTF8Encoding]::new($false))}
            'altered-receipt' {[IO.File]::AppendAllText((Join-Path $damaged 'receipts/u003-admission.json'),"`n",[Text.UTF8Encoding]::new($false))}
            'detached-event' {$path=Join-Path $damaged 'iteration-events.jsonl';$bytes=[IO.File]::ReadAllText($path).Replace('u003-admission-admitted','u003-detached-admitted');[IO.File]::WriteAllText($path,$bytes,[Text.UTF8Encoding]::new($false))}
        }
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $damaged;$rejected=$false
        try{& $admissionModule $guard $damaged}catch{$rejected=$true}
        Assert-Envelope ($rejected -and $before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $damaged)) "prior replacement fulfillment accepted or wrote $damage"
    }
}

function Test-ActiveRetirementArchive {
    param([string]$Workspace,[string]$TestRoot=(Split-Path $Workspace -Parent))
    $archiveModule=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceHistoryArchive.psm1') -PassThru
    $state=Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json');$project=Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json')
    $eventsPath=Join-Path $Workspace 'iteration-events.jsonl';$oldPath=Join-Path $Workspace 'iteration-units/u002.json';$oldHash=Get-EnvelopeFileSha256 $oldPath
    $inventoryHash=& $archiveModule {param($root,$state) $inventory=Get-HistoryArchiveSourceInventory -Workspace $root -State $state;Get-HistoryArchiveHash (Get-HistoryArchiveInventoryCommitment -Records @($inventory.records) -Context 'retired-active fixture inventory')} $Workspace $state
    $request=[ordered]@{schema='rusty.morphospace.workflow.history_archive_checkpoint.v1';record_kind='request';checkpoint_id='retired-active-archive';project_id=[string]$state.project_id;expected=[ordered]@{project_sha256=(Get-EnvelopeCanonicalJsonSha256 $project);state_sha256=(Get-EnvelopeCanonicalJsonSha256 $state);events_sha256=(Get-EnvelopeFileSha256 $eventsPath);events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$state.last_event_id;source_inventory_sha256=$inventoryHash};does_not_prove=@('Does not accept or rewrite retired active history.')}
    $requestPath=Join-Path $Workspace 'history-archive/requests/retired-active-archive.json';Write-EnvelopeJson $requestPath $request
    $arguments=@{WorkspaceRoot=$Workspace;HistoryArchiveCheckpoint=$requestPath;OutPath=(Join-Path $Workspace 'history-archive/checkpoints/retired-active-archive.json');Timestamp='2026-08-25T00:03:00.0000000Z'}
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace
    $dry=& $archiveModule {param($arguments) Invoke-MorphospaceArchiveHistoryCheckpoint @arguments} $arguments
    Assert-Envelope (-not $dry.executed -and $before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)) 'retired-active archive dry run changed bytes'
    $null=& $archiveModule {param($arguments,$hash) Invoke-MorphospaceArchiveHistoryCheckpoint @arguments -ExpectedHistoryArchiveCheckpointSha256 $hash -Execute} $arguments (Get-EnvelopeFileSha256 $requestPath)
    foreach($tier in @('quick','deep')){
        $result=& $archiveModule {param($root,$tier) Test-MorphospaceHistoryArchive -WorkspaceRoot $root -Tier $tier} $Workspace $tier
        Assert-Envelope ($result.status -ceq 'pass') "retired-active archive $tier validation failed"
    }
    $archivedState=Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json')
    $archiveRoot=Read-EnvelopeProtocolJson (Join-Path $Workspace $archivedState.history_archive.root_path)
    $oldObject=@($archiveRoot.objects|Where-Object{[string]$_.source_path -ceq 'iteration-units/u002.json'})
    Assert-Envelope ($oldObject.Count -eq 1 -and [string]$oldObject[0].sha256 -ceq $oldHash -and $oldHash -ceq (Get-EnvelopeFileSha256 $oldPath)) 'archive changed or lost retired active raw bytes'
    $history=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $Workspace -RequireIdle
    Assert-Envelope ($history.retired_active_ids.Contains('u002') -and -not $history.historical_ids.Contains('u002')) 'archive reclassified retired active work as accepted'
    # A legitimate archive decision may contain a lifecycle word in its ID;
    # a later typed lifecycle event for accepted history must still reject.
    $resurrected=Join-Path $TestRoot ('archive-resurrection-'+[guid]::NewGuid().ToString('N'));Copy-Item -LiteralPath $Workspace -Destination $resurrected -Recurse
    $targetState=Copy-Envelope $archivedState;$acceptedUnit=Read-EnvelopeProtocolJson (Join-Path $resurrected 'iteration-units/u003.json')
    $sequence=@(Get-Content -LiteralPath (Join-Path $resurrected 'iteration-events.jsonl')|Where-Object{$_}).Count+1
    $eventId='u003-claimed-{0:d4}' -f $sequence;$targetState.last_event_id=$eventId
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=$sequence;timestamp='2026-08-25T00:04:00.0000000Z';project_id=[string]$targetState.project_id;unit_id='u003';event_type='state-transition';summary='Negative fixture for a typed lifecycle resurrection after acceptance.';receipts=@()}
    $ledger=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceTransitionLedger.psm1') -PassThru
    & $ledger {param($root,$state,$unit,$event) Start-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId "$($event.event_id)-transition" -StatePath 'workspace.state.json' -UnitPath 'iteration-units/u003.json' -EventsPath 'iteration-events.jsonl' -TargetState $state -TargetUnit $unit -Event $event} $resurrected $targetState $acceptedUnit $event | Out-Null
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $resurrected;$rejected=$false
    try{Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $resurrected | Out-Null}catch{$rejected=$_.Exception.Message -ceq 'Current-work history cannot hide a resurrected historical owner.'}
    Assert-Envelope ($rejected -and $before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $resurrected)) 'typed lifecycle resurrection passed or current history wrote bytes'
}

function Test-ActiveRetirementContinuation {
    param([string]$Workspace,[string]$TestRoot,[string]$RepositoryRoot,[string]$RetirementReceiptPath)
    Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceCurrentWorkHistory.psm1')
    $originalAccepted = [string](Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json')).last_accepted_receipt
    $oldPath = Join-Path $Workspace 'iteration-units/u002.json'
    $oldRawHash = Get-EnvelopeFileSha256 $oldPath
    $history = Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $Workspace -RequireIdle
    Assert-Envelope ($history.retired_active_ids.Contains('u002') -and -not $history.historical_ids.Contains('u002') -and -not $history.retired_ids.Contains('u002')) 'active retirement was not classified separately from accepted history'
    Assert-ActiveRetirementPublicHistory $Workspace $RepositoryRoot
    $proof = $history.active_retirements['u002']
    $retirementEventId = [string]$proof.intent.event.event_id
    foreach ($damage in @('missing-completion','altered-receipt','old-raw-drift','resurrected-pointer')) {
        $damaged = Join-Path $TestRoot $damage; Copy-Item -LiteralPath $Workspace -Destination $damaged -Recurse
        switch ($damage) {
            'missing-completion' { Remove-Item -LiteralPath (Join-Path $damaged "receipts/transactions/$retirementEventId-transition.completion.json") }
            'altered-receipt' { $path=Join-Path $damaged $RetirementReceiptPath; $receipt=Read-EnvelopeProtocolJson $path; $receipt.replacement_unit_id='wrong-replacement'; Write-EnvelopeJson $path $receipt }
            'old-raw-drift' { [IO.File]::AppendAllText((Join-Path $damaged 'iteration-units/u002.json'),"`n",[Text.UTF8Encoding]::new($false)) }
            'resurrected-pointer' { $path=Join-Path $damaged 'workspace.state.json'; $state=Read-EnvelopeProtocolJson $path; $state.current_unit='u002'; Write-EnvelopeJson $path $state }
        }
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $damaged; $rejected=$false
        try { Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $damaged | Out-Null } catch { $rejected=$true }
        Assert-Envelope ($rejected -and $before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $damaged)) "history accepted or wrote $damage"
    }
    $automation=Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1'
    foreach ($action in @('Recover','Resume','Ready','Claim','Accept')) {
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace; $rejected=$false
        try { & $automation -Action $action -WorkspaceRoot $Workspace -UnitId u002 -RepoMapPath (Join-Path $Workspace 'repository-map.json') -Execute | Out-Null } catch { $rejected=$true }
        Assert-Envelope ($rejected -and $before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)) "retired unit regained authority through $action"
    }
    $preparation=New-ActiveRetirementReplacementPreparation $Workspace
    $preparationPath=Join-Path $TestRoot 'replacement-preparation.json'; Write-EnvelopeJson $preparationPath $preparation
    $null=& $automation -Action PrepareDevelopmentEnvelope -WorkspaceRoot $Workspace -DevelopmentEnvelopePreparation $preparationPath -ExpectedDevelopmentEnvelopePreparationSha256 (Get-EnvelopeFileSha256 $preparationPath) -OutPath (Join-Path $Workspace 'receipts/u003-envelope.json') -Timestamp '2026-08-25T00:01:01.0000000Z' -Execute
    Assert-Envelope ([string](Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json')).last_accepted_receipt -ceq $originalAccepted) 'preparation replaced the original accepted checkpoint'
    $admission=New-EnvelopeReplacementAdmission -Template (Read-EnvelopeProtocolJson (Join-Path $Workspace 'receipts/u002-admission.json')) -Workspace $Workspace -AdmissionId u003-admission -UnitId u003
    $admission.preparation=[ordered]@{preparation_id='u003-envelope';receipt_path='receipts/u003-envelope.json';receipt_sha256=(Get-EnvelopeFileSha256 (Join-Path $Workspace 'receipts/u003-envelope.json'));source_composition_path='source-compositions/u003-envelope.json';source_composition_sha256=(Get-EnvelopeFileSha256 (Join-Path $Workspace 'source-compositions/u003-envelope.json'))}
    $admission.unit.source_composition.lock_path=$admission.preparation.source_composition_path
    $admission.expected.project_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json'))
    $admission.expected.feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $Workspace 'feature.lock.json'))
    $admission.expected.source_composition_path=$admission.preparation.source_composition_path
    $admission.expected.source_composition_sha256=$admission.preparation.source_composition_sha256
    foreach ($damage in @('wrong-replacement','retired-prerequisite')) {
        $candidate=Copy-Envelope $admission
        if($damage -ceq 'wrong-replacement'){$candidate.admission_id='u004-admission';$candidate.unit_id='u004';$candidate.unit.unit_id='u004'}else{$candidate.unit.prerequisites=@('u002')}
        $inputPath=Join-Path $TestRoot "$damage.json";Write-EnvelopeJson $inputPath $candidate
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace;$rejected=$false
        try{& $automation -Action AdmitDevelopmentUnit -WorkspaceRoot $Workspace -DevelopmentUnitAdmission $inputPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $inputPath) -OutPath (Join-Path $Workspace "receipts/$($candidate.admission_id).json") -Execute|Out-Null}catch{$rejected=$true}
        Assert-Envelope ($rejected -and $before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)) "admission accepted or wrote $damage"
    }
    $admissionPath=Join-Path $TestRoot 'replacement-admission.json';Write-EnvelopeJson $admissionPath $admission
    $arguments=@{Action='AdmitDevelopmentUnit';WorkspaceRoot=$Workspace;DevelopmentUnitAdmission=$admissionPath;OutPath=(Join-Path $Workspace 'receipts/u003-admission.json');Timestamp='2026-08-25T00:01:02.0000000Z'}
    # Derive the negative from an owner-written interrupted replacement admission.
    # Only this damage branch rewrites the pending intent to an unnamed identity.
    $pendingWorkspace=Join-Path $TestRoot 'pending-wrong-replacement';Copy-Item -LiteralPath $Workspace -Destination $pendingWorkspace -Recurse
    $pendingArguments=@{};foreach($key in $arguments.Keys){$pendingArguments[$key]=$arguments[$key]}
    $pendingArguments.Remove('Action')
    $pendingArguments.WorkspaceRoot=$pendingWorkspace;$pendingArguments.OutPath=Join-Path $pendingWorkspace 'receipts/u003-admission.json'
    $admissionModule=Import-Module (Join-Path $PSScriptRoot '../DevelopmentUnitAdmission.psm1') -PassThru
    $interrupted=$false
    try{$null=& $admissionModule {param($arguments,$hash) Invoke-MorphospaceAdmitDevelopmentUnit @arguments -ExpectedDevelopmentUnitAdmissionSha256 $hash -Execute -FaultAfter after-intent} $pendingArguments (Get-EnvelopeFileSha256 $admissionPath)}catch{$interrupted=$_.Exception.Message -like '*Injected admission interruption after intent*'}
    Assert-Envelope $interrupted 'replacement admission did not produce its expected interrupted owner intent'
    $wrong=Copy-Envelope $admission;$wrong.admission_id='u004-admission';$wrong.unit_id='u004';$wrong.unit.unit_id='u004'
    $wrongPath=Join-Path $TestRoot 'pending-wrong-input.json';Write-EnvelopeJson $wrongPath $wrong;$wrongHash=Get-EnvelopeFileSha256 $wrongPath
    $originalIntentPath=Join-Path $pendingWorkspace 'receipts/transactions/u003-admission-admitted-transition.intent.json'
    $pending=Read-EnvelopeProtocolJson $originalIntentPath;$pending.transaction_id='u004-admission-admitted-transition';$pending.unit.path='iteration-units/u004.json'
    $pending.event.event_id='u004-admission-admitted';$pending.event.unit_id='u004';$pending.event.receipts=@('receipts/u004-admission.json')
    $pending.target.state.document.last_event_id=$pending.event.event_id;$pending.target.state.sha256=Get-EnvelopeCanonicalJsonSha256 $pending.target.state.document
    $pending.target.unit.document=$wrong.unit;$pending.target.unit.sha256=Get-EnvelopeCanonicalJsonSha256 $wrong.unit
    $pending.artifacts[0].path='receipts/u004-admission.json';$pending.artifacts[0].sha256=$wrongHash;$pending.artifacts[0].bytes_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($wrongPath))
    Write-EnvelopeJson (Join-Path $pendingWorkspace 'receipts/transactions/u004-admission-admitted-transition.intent.json') $pending;Remove-Item -LiteralPath $originalIntentPath
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $pendingWorkspace;$rejected=$false
    try{
        & $admissionModule {param($workspace,$admission,$hash,$target,$project,$lock) Complete-MorphospaceDevelopmentUnitAdmission -WorkspaceRoot $workspace -Admission $admission -InputHash $hash -TargetState $target -Project $project -FeatureLock $lock} $pendingWorkspace $wrong $wrongHash $pending.target.state.document (Read-EnvelopeProtocolJson (Join-Path $pendingWorkspace 'project.spec.json')) (Read-EnvelopeProtocolJson (Join-Path $pendingWorkspace 'feature.lock.json')) | Out-Null
    }catch{$rejected=$_.Exception.Message -ceq 'Active retirement permits only its explicitly named replacement admission.'}
    Assert-Envelope ($rejected -and $before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $pendingWorkspace)) 'interrupted admission bypassed named replacement binding or wrote bytes'
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace
    $dry=& $automation @arguments | ConvertFrom-Json
    Assert-Envelope ($before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)) 'replacement admission dry-run changed bytes'
    $null=& $automation @arguments -ExpectedDevelopmentUnitAdmissionSha256 $dry.audit_receipt.sha256 -Execute
    $lifecycle=@{WorkspaceRoot=$Workspace;UnitId='u003';RepoMapPath=(Join-Path $Workspace 'repository-map.json');ValidationTier='quick'}
    $null=& $automation @lifecycle -Action Ready -Timestamp '2026-08-25T00:01:03.0000000Z' -Execute
    $inspect=& $automation @lifecycle -Action Inspect | ConvertFrom-Json
    Assert-Envelope $inspect.claim_preflight.ready_to_claim 'named replacement Inspect did not pass claim preflight'
    $null=& $automation @lifecycle -Action Claim -Timestamp '2026-08-25T00:01:04.0000000Z' -Execute
    $recoverWorkspace=Join-Path $TestRoot 'replacement-pointer-recovery';Copy-Item -LiteralPath $Workspace -Destination $recoverWorkspace -Recurse
    $recoverStatePath=Join-Path $recoverWorkspace 'workspace.state.json';$recoverState=Read-EnvelopeProtocolJson $recoverStatePath;$recoverState.current_unit=$null;Write-EnvelopeJson $recoverStatePath $recoverState
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $recoverWorkspace
    $recover=& $automation -Action Recover -WorkspaceRoot $recoverWorkspace -UnitId u003 -RepoMapPath (Join-Path $recoverWorkspace 'repository-map.json') | ConvertFrom-Json
    Assert-Envelope ($recover.transition -ceq 'restore-current-unit' -and $before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $recoverWorkspace)) 'retired active inventory blocked ordinary replacement pointer recovery or dry run wrote bytes'
    Add-ActiveRetirementContinuationEvent $Workspace
    $history=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $Workspace
    Assert-Envelope ($history.retired_active_ids.Contains('u002') -and $history.accepted_unit_id -ceq 'u001') 'unrelated later event lost retirement or changed checkpoint'
    Assert-ActiveRetirementPublicHistory $Workspace $RepositoryRoot
    Add-ActiveRetirementContinuationEvent $Workspace -Accepted
    $history=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $Workspace -RequireIdle
    Assert-Envelope ($history.retired_active_ids.Contains('u002') -and -not $history.historical_ids.Contains('u002') -and $history.accepted_unit_id -ceq 'u003') 'later accepted prefix reclassified retired active unit as accepted'
    Assert-ActiveRetirementPublicHistory $Workspace $RepositoryRoot
    Assert-Envelope ((Get-EnvelopeFileSha256 $oldPath) -ceq $oldRawHash) 'continuation changed original retired active bytes'
    Test-ActiveRetirementFulfilledAdmissionProof $Workspace $TestRoot
    Test-ActiveRetirementArchive $Workspace $TestRoot
}
