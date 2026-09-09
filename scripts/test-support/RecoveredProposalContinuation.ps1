# Called with an admission produced by the ordinary preparation, retirement,
# repreparation and admission writers in Test-DevelopmentUnitAdmission.ps1.
function Test-RecoveredProposalRetirement {
    param([string]$AdmittedWorkspace, [string]$TestRoot, [string]$ScriptsRoot)
    Import-Module (Join-Path $PSScriptRoot '../AdmissionCompletionTimestampRecovery.psm1')
    $workspace = Join-Path $TestRoot 'recovered-proposal-retirement'
    Copy-Item -LiteralPath $AdmittedWorkspace -Destination $workspace -Recurse
    $requestPath = Join-Path $workspace 'local/u003-admission.json'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($requestPath))
    Copy-Item -LiteralPath (Join-Path $workspace 'receipts/u003-admission.json') -Destination $requestPath
    $intentPath = Join-Path $workspace 'receipts/transactions/u003-admission-admitted-transition.intent.json'
    $completionPath = Join-Path $workspace 'receipts/transactions/u003-admission-admitted-transition.completion.json'
    $intent = Read-EnvelopeProtocolJson $intentPath
    $completion = Read-EnvelopeProtocolJson $completionPath
    # Reproduce the historical writer's single known chronology fault. All
    # other bytes below come from the existing real owner writers.
    $completion.completed_at = ([DateTimeOffset]::Parse([string]$intent.created_at)).AddSeconds(-1).UtcDateTime.ToString('o')
    Write-EnvelopeJson $completionPath $completion
    $recovery = New-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $workspace -Timestamp '2026-08-25T00:02:01.0000000Z'
    $recoveryInput = Join-Path $workspace 'local/recovery-input.json'
    Write-EnvelopeJson $recoveryInput $recovery
    $recoveryOut = Join-Path $workspace ([string]$recovery.correction_event.receipt_path)
    $null = Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $workspace -Recovery $recoveryInput -ExpectedRecoverySha256 (Get-EnvelopeFileSha256 $recoveryInput) -OutPath $recoveryOut -Execute
    $preserved = @($intentPath,$completionPath,$requestPath,$recoveryOut | ForEach-Object { [pscustomobject]@{path=$_;sha256=(Get-EnvelopeFileSha256 $_)} })
    $automation = Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1'
    $arguments = @{
        Action='RetireProposed'; WorkspaceRoot=$workspace; UnitId='u003'; ReplacementUnitId='u004'
        RetirementReason='contract-invalid'; OutPath=(Join-Path $workspace 'receipts/u003-recovered-retirement.json')
        Timestamp='2026-08-25T00:02:02.0000000Z'
    }
    $before = Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    $dry = & $automation @arguments | ConvertFrom-Json
    Assert-Envelope ($before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) 'recovered proposal retirement dry run mutated bytes'
    Assert-Envelope ([string]$dry.proposed_retirement.authenticated_admission.transaction.target_state_sha256 -cne [string]$dry.proposed_retirement.authenticated_preimage.state_sha256) 'recovered retirement lost the distinct original and recovered state bindings'
    foreach ($damage in @('recovery-receipt','original-completion','intervening-event')) {
        $damagedWorkspace = Join-Path $TestRoot "recovered-retirement-$damage"
        Copy-Item -LiteralPath $workspace -Destination $damagedWorkspace -Recurse
        switch ($damage) {
            'recovery-receipt' { [IO.File]::AppendAllText((Join-Path $damagedWorkspace ([string]$recovery.correction_event.receipt_path)), ' ') }
            'original-completion' { [IO.File]::AppendAllText((Join-Path $damagedWorkspace 'receipts/transactions/u003-admission-admitted-transition.completion.json'), ' ') }
            'intervening-event' {
                $statePath = Join-Path $damagedWorkspace 'workspace.state.json'
                $state = Read-EnvelopeProtocolJson $statePath
                $event = Read-EnvelopeProtocolJson $recoveryInput
                $row = [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unrelated-event';sequence=([int]$event.correction_event.sequence+1);timestamp='2026-08-25T00:02:01.5000000Z';project_id=$state.project_id;unit_id='u003';event_type='state-transition';summary='Unrelated event.';receipts=@()}
                [IO.File]::AppendAllText((Join-Path $damagedWorkspace 'iteration-events.jsonl'), (($row | ConvertTo-Json -Compress)+"`n"))
                $state.last_event_id = 'unrelated-event'; Write-EnvelopeJson $statePath $state
            }
        }
        $damagedArguments = $arguments.Clone(); $damagedArguments.WorkspaceRoot = $damagedWorkspace
        $damagedArguments.OutPath = Join-Path $damagedWorkspace 'receipts/u003-recovered-retirement.json'
        $damageBefore = Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace
        $rejected = $false
        try { & $automation @damagedArguments | Out-Null } catch { $rejected = $true }
        Assert-Envelope ($rejected -and $damageBefore -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace)) "recovered retirement accepted or mutated $damage"
    }
    $pre = $dry.proposed_retirement.authenticated_preimage
    $arguments.ExpectedStateSha256=$pre.state_sha256; $arguments.ExpectedUnitSha256=$pre.unit_sha256
    $arguments.ExpectedUnitRawSha256=$pre.unit_raw_sha256; $arguments.ExpectedEventsSha256=$pre.events_sha256
    $arguments.ExpectedEventsLength=[long]$pre.events_length; $arguments.ExpectedEventTailId=$pre.event_tail_id
    $arguments.ExpectedProposedRetirementBindingSha256=$dry.proposed_retirement.binding_sha256; $arguments.Execute=$true
    $run = & $automation @arguments | ConvertFrom-Json
    Assert-Envelope ($run.transition -ceq 'proposed-to-superseded-retired' -and [string](Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u003.json')).status -ceq 'superseded') 'recovered proposal did not retire through the ordinary owner writer'
    foreach ($file in $preserved) { Assert-Envelope ((Get-EnvelopeFileSha256 $file.path) -ceq $file.sha256) 'retirement rewrote preserved admission or recovery evidence' }
    $transitionModule=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceTransitionLedger.psm1') -PassThru
    function Add-ContinuationAcceptedBoundary([string]$Root){$acceptedUnit=Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $Root 'iteration-units/u001.json'));$acceptedUnit.unit_id='u004';$acceptedUnit.status='proposed';$acceptedUnit.prerequisites=@('u001');$acceptedUnit.objective='Establish a later owner-written accepted boundary for continuation testing.';Write-EnvelopeCanonicalJson (Join-Path $Root 'iteration-units/u004.json') $acceptedUnit;$acceptedSequence=@(Get-Content -LiteralPath (Join-Path $Root 'iteration-events.jsonl')|Where-Object{$_}).Count+1;$acceptedEventId=('u004-accepted-{0:d4}'-f$acceptedSequence);$acceptedReceiptRelative='receipts/u004-accepted.json';Write-EnvelopeJson (Join-Path $Root $acceptedReceiptRelative) ([ordered]@{schema='fixture.owner.validation.v1';result='pass'});$acceptedState=Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $Root 'workspace.state.json'));$acceptedState.last_accepted_receipt=$acceptedReceiptRelative;$acceptedState.last_event_id=$acceptedEventId;$acceptedUnit.status='accepted';$acceptedEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$acceptedEventId;sequence=$acceptedSequence;timestamp='2026-08-25T00:02:02.5000000Z';project_id=[string]$acceptedState.project_id;unit_id='u004';event_type='state-transition';summary='Accepted later continuation checkpoint.';receipts=@($acceptedReceiptRelative)};&$transitionModule {param($root,$targetState,$targetUnit,$event,$transaction)Start-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId $transaction -StatePath 'workspace.state.json' -UnitPath 'iteration-units/u004.json' -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event} $Root $acceptedState $acceptedUnit $acceptedEvent "$acceptedEventId-transition"|Out-Null}
    $resurrectionWorkspace=Join-Path $TestRoot 'retired-proposal-resurrection-before-boundary';Copy-Item -LiteralPath $workspace -Destination $resurrectionWorkspace -Recurse;$resurrectionUnit=Read-EnvelopeProtocolJson (Join-Path $resurrectionWorkspace 'iteration-units/u003.json');$resurrectionState=Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $resurrectionWorkspace 'workspace.state.json'));$resurrectionSequence=@(Get-Content -LiteralPath (Join-Path $resurrectionWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count+1;$resurrectionEventId=('u003-ready-{0:d4}'-f$resurrectionSequence);$resurrectionState.last_event_id=$resurrectionEventId;$resurrectionEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$resurrectionEventId;sequence=$resurrectionSequence;timestamp='2026-08-25T00:02:02.2500000Z';project_id=[string]$resurrectionState.project_id;unit_id='u003';event_type='state-transition';summary='Damaged resurrection row retained before a later accepted boundary.';receipts=@()};&$transitionModule {param($root,$targetState,$targetUnit,$event,$transaction)Start-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId $transaction -StatePath 'workspace.state.json' -UnitPath 'iteration-units/u003.json' -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event} $resurrectionWorkspace $resurrectionState $resurrectionUnit $resurrectionEvent "$resurrectionEventId-transition"|Out-Null;Add-ContinuationAcceptedBoundary $resurrectionWorkspace
    Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceCurrentWorkHistory.psm1') -Force;$resurrectionMessage='';try{Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $resurrectionWorkspace|Out-Null}catch{$resurrectionMessage=$_.Exception.Message};Assert-Envelope ($resurrectionMessage-ceq'Current-work proposed retirement cannot hide a resurrected owner.') "current-work reader did not reject a retired proposal resurrected inside a later accepted prefix at the intended predicate (observed: '$resurrectionMessage')"
    Add-ContinuationAcceptedBoundary $workspace
    $repositoryMap=Read-EnvelopeProtocolJson (Join-Path $workspace 'repository-map.json');$planningRows=@($repositoryMap.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'});Assert-Envelope ($planningRows.Count-eq1) 'continuation fixture lacks one mapped planning repository';$repositoryRoot=(Resolve-Path -LiteralPath ([string]$planningRows[0].path)).Path;$repositoryWorkspace=Join-Path $repositoryRoot 'morphospace';$testRootFull=[IO.Path]::GetFullPath($TestRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;Assert-Envelope (([IO.Path]::GetFullPath($repositoryRoot)+[IO.Path]::DirectorySeparatorChar).StartsWith($testRootFull,[StringComparison]::OrdinalIgnoreCase)) 'continuation fixture mapped a planning repository outside its exact test root';Assert-Envelope ((Test-Path -LiteralPath (Join-Path $repositoryRoot '.git'))-and(Test-Path -LiteralPath $repositoryWorkspace)) 'continuation fixture planning repository is not a Git worktree containing morphospace'
    Invoke-EnvelopeGit $repositoryRoot @('config','core.longpaths','true')|Out-Null;Get-ChildItem -LiteralPath $workspace -Force|Copy-Item -Destination $repositoryWorkspace -Recurse -Force;Invoke-EnvelopeGit $repositoryRoot @('add','morphospace')|Out-Null;Invoke-EnvelopeGit $repositoryRoot @('commit','-m','fixture recovered retirement checkpoint')|Out-Null
    Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceCurrentWorkHistory.psm1') -Force
    $retiredHistory=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $workspace
    Assert-Envelope ($retiredHistory.historically_retired_proposed_ids.Contains('u003')) 'current-work reader did not authenticate the recovered proposed retirement as audit-only history'

    # Continue through the ordinary owner preparation writer. The new envelope
    # expands one existing repository only by roots explicitly named by its
    # owner row, while the retired proposal remains audit-only history.
    Import-Module (Join-Path $PSScriptRoot '../DevelopmentEnvelopePreparation.psm1') -Force
    $project=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json');$state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$lock=Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json');$map=Read-EnvelopeProtocolJson (Join-Path $workspace 'repository-map.json');$predecessor=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u004.json')
    $targetProject=Copy-Envelope $project;$targetProject.revision=[int]$project.revision+1;$projectShell=@($targetProject.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0];$projectShell.allowed_paths=@($projectShell.allowed_paths)+@('model/','peer/','runtime-host/')
    $targetLock=Copy-Envelope $lock;$targetLock.revision=[int]$lock.revision+1;$targetLock.project_revision=[int]$targetProject.revision;$targetLock.generated_at='2026-08-25T00:02:03.0000000Z';$targetLock.lock_fingerprint=Get-EnvelopeLockFingerprint $targetLock
    $latestPreparation=Read-EnvelopeProtocolJson (Join-Path $workspace 'receipts/u003-envelope.json');$envelope=Copy-Envelope $latestPreparation.envelope;$envelope.project=$targetProject;$envelope.feature_lock=$targetLock;$envelope.PSObject.Properties.Remove('schema_pin_revision');$envelope.source_composition.path='source-composition-locks/u005-envelope.json';$envelope.owner_repositories=@($targetProject.repositories|ForEach-Object{[pscustomobject][ordered]@{repo_id=[string]$_.repo_id;source_roots=@($_.allowed_paths)}})
    $eventsPath=Join-Path $workspace 'iteration-events.jsonl';$tail=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})[-1]
    $preparation=[ordered]@{schema='rusty.morphospace.workflow.development_envelope_preparation.v1';preparation_id='u005-envelope';project_id=[string]$project.project_id;predecessor_unit_id='u004';envelope=$envelope;expected=[ordered]@{project_sha256=(Get-EnvelopeCanonicalJsonSha256 $project);state_sha256=(Get-EnvelopeCanonicalJsonSha256 $state);feature_lock_sha256=(Get-EnvelopeCanonicalJsonSha256 $lock);repository_map_path='repository-map.json';repository_map_sha256=(Get-EnvelopeFileSha256 (Join-Path $workspace 'repository-map.json'));predecessor_unit_path='iteration-units/u004.json';predecessor_unit_sha256=(Get-EnvelopeCanonicalJsonSha256 $predecessor);events_sha256=(Get-EnvelopeFileSha256 $eventsPath);events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$tail.event_id};does_not_prove=@('Does not admit a future unit or execute a device action.')}
    $preparationPath=Join-Path $TestRoot 'u005-envelope.json';Write-EnvelopeJson $preparationPath $preparation;$preparationOut=Join-Path $workspace 'receipts/u005-envelope.json';$preparationHash=Get-EnvelopeFileSha256 $preparationPath
    $prepared=Invoke-MorphospacePrepareDevelopmentEnvelope -WorkspaceRoot $workspace -DevelopmentEnvelopePreparation $preparationPath -ExpectedDevelopmentEnvelopePreparationSha256 $preparationHash -OutPath $preparationOut -Timestamp '2026-08-25T00:02:03.0000000Z' -Execute
    Assert-Envelope ($prepared.executed-and@((Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json')).repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'}|ForEach-Object{$_.allowed_paths}|Where-Object{$_-in@('model/','peer/','runtime-host/')}).Count-eq3) 'ordinary preparation did not add the exact owner-declared repository roots'
    $continuedHistory=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $workspace
    Assert-Envelope ($continuedHistory.historically_retired_proposed_ids.Contains('u003')-and[string](Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')).last_event_id-ceq'u005-envelope-prepared') 'current-work reader did not authenticate ordinary preparation after recovered retirement'

    $damageWorkspace=Join-Path $TestRoot 'prepared-root-rewrite-damage';Copy-Item -LiteralPath $workspace -Destination $damageWorkspace -Recurse
    $damageReceiptPath=Join-Path $damageWorkspace 'receipts/u005-envelope.json';$damageReceipt=Read-EnvelopeProtocolJson $damageReceiptPath;$damageRepo=@($damageReceipt.envelope.project.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0];$damageRepo.allowed_paths=@($damageRepo.allowed_paths|Where-Object{$_-cne'morphospace/'})+@('rewritten/');$damageOwner=@($damageReceipt.envelope.owner_repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0];$damageOwner.source_roots=@($damageRepo.allowed_paths);$damageReceipt.project_sha256=Get-EnvelopeCanonicalJsonSha256 $damageReceipt.envelope.project
    $damageReceiptBytes=[Text.UTF8Encoding]::new($false).GetBytes(($damageReceipt|ConvertTo-Json -Depth 64));[IO.File]::WriteAllBytes($damageReceiptPath,$damageReceiptBytes)
    $damageIntentPath=Join-Path $damageWorkspace 'receipts/transactions/u005-envelope-prepared-transition.intent.json';$damageIntent=Read-EnvelopeProtocolJson $damageIntentPath;$damageIntent.target.project.document=$damageReceipt.envelope.project;$damageIntent.target.project.sha256=$damageReceipt.project_sha256;$damageIntent.artifacts[0].sha256=Get-EnvelopeCanonicalJsonSha256 $damageReceipt;$damageIntent.artifacts[0].bytes_base64=[Convert]::ToBase64String($damageReceiptBytes);Write-EnvelopeCanonicalJson $damageIntentPath $damageIntent
    Write-EnvelopeCanonicalJson (Join-Path $damageWorkspace 'project.spec.json') $damageReceipt.envelope.project;$damageCompletionPath=Join-Path $damageWorkspace 'receipts/transactions/u005-envelope-prepared-transition.completion.json';$damageCompletion=Read-EnvelopeProtocolJson $damageCompletionPath;$damageCompletion.intent_sha256=Get-EnvelopeFileSha256 $damageIntentPath;$damageCompletion.target_project_sha256=$damageReceipt.project_sha256;Write-EnvelopeCanonicalJson $damageCompletionPath $damageCompletion
    $damageRejected=$false;$damageMessage='';try{Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $damageWorkspace|Out-Null}catch{$damageRejected=$true;$damageMessage=$_.Exception.Message};Assert-Envelope ($damageRejected-and$damageMessage-ceq"Preparation removes an existing allowed path from repository 'project-shell'.") 'current-work reader did not reject the otherwise coherent preparation at the existing-root rewrite predicate'

    $ownerDamageWorkspace=Join-Path $TestRoot 'prepared-owner-root-authority-damage';Copy-Item -LiteralPath $workspace -Destination $ownerDamageWorkspace -Recurse
    $ownerDamageReceiptPath=Join-Path $ownerDamageWorkspace 'receipts/u005-envelope.json';$ownerDamageReceipt=Read-EnvelopeProtocolJson $ownerDamageReceiptPath;$ownerDamageRow=@($ownerDamageReceipt.envelope.owner_repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0];$ownerDamageRow.source_roots=@($ownerDamageRow.source_roots)+@('outside/');$ownerDamageReceiptBytes=[Text.UTF8Encoding]::new($false).GetBytes(($ownerDamageReceipt|ConvertTo-Json -Depth 64));[IO.File]::WriteAllBytes($ownerDamageReceiptPath,$ownerDamageReceiptBytes)
    $ownerDamageIntentPath=Join-Path $ownerDamageWorkspace 'receipts/transactions/u005-envelope-prepared-transition.intent.json';$ownerDamageIntent=Read-EnvelopeProtocolJson $ownerDamageIntentPath;$ownerDamageIntent.artifacts[0].sha256=Get-EnvelopeCanonicalJsonSha256 $ownerDamageReceipt;$ownerDamageIntent.artifacts[0].bytes_base64=[Convert]::ToBase64String($ownerDamageReceiptBytes);Write-EnvelopeCanonicalJson $ownerDamageIntentPath $ownerDamageIntent;$ownerDamageCompletionPath=Join-Path $ownerDamageWorkspace 'receipts/transactions/u005-envelope-prepared-transition.completion.json';$ownerDamageCompletion=Read-EnvelopeProtocolJson $ownerDamageCompletionPath;$ownerDamageCompletion.intent_sha256=Get-EnvelopeFileSha256 $ownerDamageIntentPath;Write-EnvelopeCanonicalJson $ownerDamageCompletionPath $ownerDamageCompletion
    $ownerDamageMessage='';try{Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $ownerDamageWorkspace|Out-Null}catch{$ownerDamageMessage=$_.Exception.Message};Assert-Envelope ($ownerDamageMessage-ceq"Preparation root 'project-shell/outside/' exceeds project authority.") 'current-work reader did not reject the otherwise coherent preparation at the owner-root authority predicate'
    $replayed = $false
    try { & $automation @arguments | Out-Null } catch { $replayed = $true }
    Assert-Envelope $replayed 'recovered proposal retirement replay was accepted'
}
