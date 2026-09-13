param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
$transitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
. (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')
function Assert-TimeRecovery([bool]$Condition,[string]$Message){if(-not$Condition){throw "Preparation timestamp recovery self-test: $Message"}}
function Assert-TimeRecoveryRejected([string]$Workspace,[string]$InputPath,[string]$Context){
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace;$message=''
    try{Invoke-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $Workspace -RecoveryPath $InputPath|Out-Null}catch{$message=$_.Exception.Message}
    Assert-TimeRecovery ([bool]$message) "accepted $Context"
    Assert-TimeRecovery ((Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)-ceq$before) "mutated workspace while rejecting $Context"
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('workenv-preparation-time-'+[guid]::NewGuid().ToString('N'))
try{
    Write-Host 'Testing preparation writer timestamp floor.'
    $futureTimestamp=[DateTimeOffset]::UtcNow.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    $future=New-EnvelopeAdmissionPreparedFixture -Root (Join-Path $temp 'future-floor') -RepositoryRoot $repoRoot -TransitionLedgerModule $transitionLedgerModule -OwnerProducedPreparation -PreparationTimestamp $futureTimestamp
    Assert-TimeRecovery (([DateTimeOffset]::Parse($future.preparation_completion.completed_at))-ge([DateTimeOffset]::Parse($futureTimestamp))) 'future supplied Timestamp produced an earlier completion'
    $seed=New-EnvelopeAdmissionPreparedFixture -Root (Join-Path $temp 'seed') -RepositoryRoot $repoRoot -TransitionLedgerModule $transitionLedgerModule -OwnerProducedPreparation
    $seed.admission_template.unit.instruction_impact='none';$seed.admission_template.unit.instruction_surfaces=@();$seed.admission_template.unit.instruction_none_justification='The fixture changes no portable instruction contract.'
    $workspace=$seed.workspace;$admissionPath=Join-Path $temp 'admission.json';Write-EnvelopeJson $admissionPath $seed.admission_template
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts/u002-admission.json') -Timestamp '2026-08-25T00:01:00.0000000Z' -Execute|Out-Null
    $lifecycle=@{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=(Join-Path $workspace 'repository-map.json');ValidationTier='quick';Execute=$true}
    Invoke-MorphospaceWorkUnitAutomation @lifecycle -Action Ready -Timestamp '2026-08-25T00:02:00.0000000Z'|Out-Null
    Invoke-MorphospaceWorkUnitAutomation @lifecycle -Action Claim -Timestamp '2026-08-25T00:03:00.0000000Z'|Out-Null
    $completionPath=Join-Path $workspace 'receipts/transactions/u002-envelope-prepared-transition.completion.json'
    # Reproduce only the legacy writer's wall-clock-before-supplied-intent
    # output. All owner-produced intents, artifacts, events and suffixes stay.
    $completion=Read-EnvelopeProtocolJson $completionPath;$completion.completed_at='2026-08-25T00:00:29.0000000Z';Write-EnvelopeJson $completionPath $completion
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkHistory.psm1')
    $recoveryModule=Import-Module (Join-Path $PSScriptRoot 'PreparationCompletionTimestampRecovery.psm1') -Force -PassThru
    # A reread receipt must be rejected by its raw pin before any persisted
    # transition payload is consumed, even if the remaining context is absent.
    $rereadRejected=& $recoveryModule {
        try{Assert-PreparationRecoveryIntent ([pscustomobject]@{}) ([pscustomobject]@{receipt=[pscustomobject]@{};receipt_raw_sha256=('1'*64)}) ('0'*64)}catch{return $_.Exception.Message-ceq'Preparation recovery reloaded input differs from its inspected raw hash.'}
        return $false
    }
    Assert-TimeRecovery $rereadRejected 'changed receipt observation reached transition payload access'
    Write-Host 'Testing active suffix recovery and raw preservation.'
    $missingRejected=$false;$historyFailure='';try{Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $workspace|Out-Null}catch{$historyFailure=$_.Exception.Message;$missingRejected=$historyFailure-like'*preparation completion predates its intent*'};Assert-TimeRecovery $missingRejected ("current reader did not identify missing correction: $historyFailure")
    $receipt=New-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $workspace -PreparationId 'u002-envelope'
    $inputPath=Join-Path $temp 'recovery.json';Write-EnvelopeJson $inputPath $receipt;$inputHash=Get-EnvelopeFileSha256 $inputPath
    $base=Join-Path $temp 'base';Copy-Item $workspace $base -Recurse
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    $dry=Invoke-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $workspace -RecoveryPath $inputPath
    Assert-TimeRecovery (-not$dry.executed-and$null-eq$dry.event_id-and(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)-ceq$before) 'dry run changed authority or bytes'
    $preserved=@($receipt.evidence)+@($receipt.snapshots.unit,$receipt.snapshots.project,$receipt.snapshots.feature_lock)
    $out=Join-Path $workspace "receipts/$($receipt.recovery_id).json"
    $run=Invoke-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $workspace -RecoveryPath $inputPath -ExpectedRecoverySha256 $inputHash -OutPath $out -Execute
    Assert-TimeRecovery ($run.executed-and$run.current_unit_after-ceq'u002'-and$run.status_after-ceq'active') 'recovery changed active ownership'
    foreach($binding in $preserved){Assert-TimeRecovery ((Get-EnvelopeFileSha256 (Join-Path $workspace $binding.path))-ceq$binding.raw_sha256) "rewrote $($binding.path)"}
    Assert-TimeRecoveryRejected $workspace $inputPath 'replay'
    $events=@(Get-Content (Join-Path $workspace 'iteration-events.jsonl')|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    $index=Get-MorphospacePreparationCompletionTimestampRecoveryIndex -WorkspaceRoot $workspace -ExpectedEvents $events
    Assert-TimeRecovery ($index.by_preparation_event.ContainsKey('u002-envelope-prepared')) 'index did not authenticate the retained defect'
    Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $workspace|Out-Null
    Write-Host 'Testing interrupted correction resume.'
    foreach($cut in @('after-intent','after-artifact','after-projection','after-event')){
        Write-Host ("Recovery cut: $cut")
        $root=Join-Path $temp $cut;Copy-Item $base $root -Recurse;$cutOut=Join-Path $root "receipts/$($receipt.recovery_id).json";$injected=$false
        try{Invoke-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $root -RecoveryPath $inputPath -ExpectedRecoverySha256 $inputHash -OutPath $cutOut -Execute -FaultAfter $cut|Out-Null}catch{$injected=$_.Exception.Message-like'Injected interruption*'}
        Assert-TimeRecovery $injected "did not reach $cut"
        if($cut-ceq'after-projection'){
            $claimCompletion=Join-Path $root "receipts/transactions/$($receipt.ledger.tail_event_id)-transition.completion.json"
            $originalBytes=[IO.File]::ReadAllBytes($claimCompletion)
            [IO.File]::AppendAllText($claimCompletion,' ')
            Assert-TimeRecoveryRejected $root $inputPath 'damaged Claim bytes during interrupted recovery'
            [IO.File]::WriteAllBytes($claimCompletion,$originalBytes)
        }
        $resumed=Invoke-MorphospacePreparationCompletionTimestampRecovery -WorkspaceRoot $root -RecoveryPath $inputPath -ExpectedRecoverySha256 $inputHash -OutPath $cutOut -Execute
        Assert-TimeRecovery $resumed.executed "failed to resume $cut"
        foreach($binding in $preserved){Assert-TimeRecovery ((Get-EnvelopeFileSha256 (Join-Path $root $binding.path))-ceq$binding.raw_sha256) "$cut rewrote $($binding.path)"}
    }
    Write-Host 'Testing read-only rejection of damaged inputs.'
    foreach($damage in @('wrong-shape','completion-other-defect','raw-evidence','stale-state','stale-unit','missing-suffix','wrong-chronology','duplicate-evidence','detached-accepted-state')){
        $root=Join-Path $temp $damage;Copy-Item $base $root -Recurse;$candidate=Copy-Envelope $receipt
        switch($damage){
            'wrong-shape'{$candidate.fault_kind='other-fault'}
            'completion-other-defect'{$p=Join-Path $root 'receipts/transactions/u002-envelope-prepared-transition.completion.json';$c=Read-EnvelopeProtocolJson $p;$c.target_state_sha256='0'*64;Write-EnvelopeJson $p $c}
            'raw-evidence'{[IO.File]::AppendAllText((Join-Path $root 'source-composition.json')," ")}
            'stale-state'{$p=Join-Path $root 'workspace.state.json';$d=Read-EnvelopeProtocolJson $p;$d.current_unit=$null;Write-EnvelopeJson $p $d}
            'stale-unit'{$p=Join-Path $root 'iteration-units/u002.json';$d=Read-EnvelopeProtocolJson $p;$d.objective='changed';Write-EnvelopeJson $p $d}
            'missing-suffix'{$p=Join-Path $root "receipts/transactions/$($receipt.ledger.tail_event_id)-transition.completion.json";Remove-Item -LiteralPath $p}
            'wrong-chronology'{$candidate.chronology.malformed_completed_at=$candidate.chronology.intent_created_at}
            'duplicate-evidence'{$candidate.evidence[0]=$candidate.evidence[1]}
            'detached-accepted-state'{
                $ip=Join-Path $root 'receipts/transactions/u001-accepted-0001-transition.intent.json';$cp=Join-Path $root 'receipts/transactions/u001-accepted-0001-transition.completion.json'
                $i=Read-EnvelopeProtocolJson $ip;$i.target.state.document.repository_heads=@();$i.target.state.document | Add-Member -NotePropertyName detached_recovery_fixture -NotePropertyValue $true
                $i.target.state.sha256=Get-EnvelopeCanonicalJsonSha256 $i.target.state.document;Write-EnvelopeJson $ip $i
                $c=Read-EnvelopeProtocolJson $cp;$c.state_sha256=$i.target.state.sha256;$c.intent.sha256=Get-EnvelopeFileSha256 $ip;Write-EnvelopeJson $cp $c
            }
        }
        $damagedInput=Join-Path $temp "$damage.json";Write-EnvelopeJson $damagedInput $candidate
        Assert-TimeRecoveryRejected $root $damagedInput $damage
    }
    Write-Host 'Preparation completion timestamp recovery self-test passed.'
}finally{
    $resolved=[IO.Path]::GetFullPath($temp)
    if(-not$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-notlike'workenv-preparation-time-*'){throw 'Unsafe recovery test cleanup.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
