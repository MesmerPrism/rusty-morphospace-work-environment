# Complete focused contract. No product/device operations are performed by this
# fixture. The baseline u001 is the established MODELED accepted prerequisite;
# every ownership, nonpass, retirement and replacement transition below uses
# the actual public owner writer and its retained intent/completion.
param([switch]$SelfTest,[ValidateSet('All','OriginContinuation','RetainedSource','Recovery',IgnoreCase=$false)][string]$Case='All',[ValidateSet('All','RootDiagnostics','SuccessorLifecycle','Untracked','Ignored',IgnoreCase=$false)][string]$RetainedCase='All')
$selectedCase=$Case
$selectedRetainedCase=$RetainedCase
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if(-not$SelfTest){throw 'Test-SupersessionActiveRetirement requires -SelfTest.'}
if($selectedRetainedCase-cne'All'-and$selectedCase-cne'RetainedSource'){throw 'A specific RetainedCase requires -Case RetainedSource.'}
$repoRoot=Split-Path $PSScriptRoot -Parent
$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$transitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
$retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkHistory.psm1')
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementContinuation.ps1')
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementFixture.ps1')
$automation=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'
$checks=[Collections.Generic.List[string]]::new()

function New-SupersessionRetirementCase {
    param([string]$Root,[switch]$Nonpass,[switch]$RootDiagnostics,[switch]$SuccessorLifecycle,[ValidateSet('Committed','Untracked','Ignored')][string]$AttemptDisposition='Committed')
    $seed=New-ActiveRetirementContinuationSeed -Root $Root -RepositoryRoot $repoRoot -SelfHostedReadOnlyPlanning -RetainRootDiagnostics:$RootDiagnostics -FeatureWorkMode:($SuccessorLifecycle-or$AttemptDisposition-cne'Committed')
    if($Nonpass-or$SuccessorLifecycle-or$AttemptDisposition-cne'Committed'){Add-ActiveRetirementRootNonpass -Seed $seed -TestRoot $Root -ReturnToActive:($SuccessorLifecycle-or$AttemptDisposition-cne'Committed') -AttemptDisposition $AttemptDisposition}
    Add-ActiveRetirementSupersession $seed 'u003' '2026-08-25T00:00:51.0000000Z' -OwnSourceLock:$SuccessorLifecycle -InstructionReview:$SuccessorLifecycle
    $mapPath=Join-Path $seed.workspace 'repository-map.json'
    if($SuccessorLifecycle){
        Add-ActiveRetirementSupersededLifecycle $seed
        # A second actual attempt needs the new owner's genuine Freeze tail;
        # ReturnToActive does not authorize replaying the root's old Freeze.
        Add-ActiveRetirementSecondReturn -Seed $seed -TestRoot $Root -UnitId u003
        # A real alternate Git materialization changes the effective map SHA
        # without rewriting the immutable ordinary-admission/root map.
        $map=Copy-Envelope (Read-EnvelopeProtocolJson $mapPath);$row=@($map.repositories|Where-Object repo_id -CEQ 'read-only-dependency')[0]
        $relocated=Join-Path $Root 'relocated-dependency';Invoke-EnvelopeGit $Root @('clone','--no-hardlinks',[string]$row.path,$relocated)|Out-Null;$row.path=$relocated
        $mapPath=Join-Path $seed.workspace 'repository-map-successor.json';Write-EnvelopeJson $mapPath $map
    }
    Add-ActiveRetirementSupersession $seed 'u004' '2026-08-25T00:00:52.0000000Z' -OwnSourceLock:$SuccessorLifecycle -RepoMapPath $mapPath
    Save-ActiveRetirementFixtureCheckpoint -Seed $seed -Message 'Retain actual two-edge supersession ownership'
    $diagnostics=$null;if($RootDiagnostics){$diagnostics=[pscustomobject]@{};Add-ActiveRetirementRootDiagnostics $diagnostics $seed}
    $request=New-ActiveUnitRetirementRequest -WorkspaceRoot $seed.workspace -RepoMapPath $mapPath -RetirementId retire-u004 -ReplacementUnitId u005 -Supersession -RetainedRootDiagnostics $diagnostics
    $requestPath=Join-Path $Root 'retirement-request.json';Write-EnvelopeJson $requestPath $request
    [pscustomobject]@{seed=$seed;workspace=$seed.workspace;request=$request;request_path=$requestPath;arguments=@{WorkspaceRoot=$seed.workspace;UnitId='u004';RepoMapPath=$mapPath;ActiveUnitRetirement=$requestPath;ExpectedActiveUnitRetirementSha256=(Get-EnvelopeFileSha256 $requestPath);OutPath=(Join-Path $seed.workspace 'receipts/retire-u004.json');Timestamp='2026-08-25T00:01:00.0000000Z'}}
}
function Invoke-SupersessionRetirement {
    param([object]$Case,[switch]$Execute,[string]$FaultAfter='none')
    $retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
    &$retirementModule {param($arguments,$execute,$fault)Invoke-MorphospaceRetireActive @arguments -Execute:$execute -FaultAfter $fault} $Case.arguments $Execute.IsPresent $FaultAfter
}
function Assert-SupersessionRequestRejected {
    param([object]$Case,[object]$Request,[string]$Label)
    $retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
    $path=Join-Path (Split-Path $Case.request_path -Parent) 'negative-request.json';Write-EnvelopeJson $path $Request
    $arguments=@{};foreach($key in $Case.arguments.Keys){$arguments[$key]=$Case.arguments[$key]};$arguments.ActiveUnitRetirement=$path;$arguments.ExpectedActiveUnitRetirementSha256=Get-EnvelopeFileSha256 $path
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace;$rejected=$false
    try{$null=&$retirementModule {param($a)Invoke-MorphospaceRetireActive @a -Execute} $arguments}catch{$rejected=$true}
    Assert-Envelope ($rejected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace)) "supersession retirement accepted or wrote negative $Label"
    $checks.Add("reject:$Label")
}
function Assert-SupersessionHistory {
    param([object]$Case,[switch]$Idle)
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace
    $history=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $Case.workspace -RequireIdle:$Idle
    Assert-Envelope ($history.authenticated-and$history.retired_active_ids.Contains('u004')-and-not$history.historical_ids.Contains('u004')) 'retired supersession endpoint became accepted or unauthenticated'
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace)) 'historical supersession retirement validation wrote bytes'
    $history
}

$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
if((Get-Item -LiteralPath $tempParent -Force).Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Refusing reparse-point fixture temp parent.'}
$tempName='wef-supersession-retirement-'+[guid]::NewGuid().ToString('N');$temp=[IO.Path]::GetFullPath((Join-Path $tempParent $tempName));$settled=$false
try{
    [void][IO.Directory]::CreateDirectory($temp)
    if($selectedCase-cin@('All','OriginContinuation')){
    $originCase=New-SupersessionRetirementCase -Root (Join-Path $temp 'nonpass') -Nonpass
    $request=$originCase.request
    Assert-Envelope ($request.schema-ceq'rusty.morphospace.workflow.active_unit_retirement.v2'-and$request.PSObject.Properties.Name-cnotcontains'claim'-and$request.ownership.root_unit_id-ceq'u002'-and@($request.ownership.supersessions).Count-eq2) 'v2 did not bind root and ordered two-edge chain'
    $events=@(Get-Content -LiteralPath (Join-Path $originCase.workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    foreach($id in @('u003','u004')){
        Assert-Envelope (@($events|Where-Object{[string]$_.unit_id-ceq$id-and[string]$_.event_id-cmatch'-(?:claimed|admitted)-'}).Count-eq0) 'fixture manufactured successor Claim or admission'
        Assert-Envelope (-not(Test-Path -LiteralPath (Join-Path $originCase.workspace "receipts/$id-admission.json"))) 'fixture wrote successor admission receipt'
    }
    $preserved=@{};foreach($relative in @('iteration-units/u002.json','iteration-units/u003.json','iteration-units/u004.json','receipts/root-nonpass.json')){$preserved[$relative]=Get-EnvelopeFileSha256 (Join-Path $originCase.workspace $relative)}
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $originCase.workspace;$dry=Invoke-SupersessionRetirement $originCase
    Assert-Envelope (-not$dry.executed-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $originCase.workspace)) 'v2 retirement dry run mutated bytes'
    foreach($damage in @('root','root-admission','root-claim','assessment','map','missing-edge','edge-order','edge-endpoint','edge-intent','edge-completion','edge-request','edge-receipt','source')){
        $bad=Copy-Envelope $request
        switch($damage){
            'root'{$bad.ownership.root_unit_id='u003'}
            'root-admission'{$bad.ownership.root_admission.raw_sha256='0'*64}
            'root-claim'{$bad.ownership.root_claim.event_id='u004-claimed-9999'}
            'assessment'{$bad.ownership.agent_scope_assessment_sha256='0'*64}
            'map'{$bad.ownership.repository_map.raw_sha256='0'*64}
            'missing-edge'{$bad.ownership.supersessions=@($bad.ownership.supersessions[1])}
            'edge-order'{$bad.ownership.supersessions=@($bad.ownership.supersessions[1],$bad.ownership.supersessions[0])}
            'edge-endpoint'{$bad.ownership.supersessions[0].replacement_unit_id='u004'}
            'edge-intent'{$bad.ownership.supersessions[0].intent_sha256='0'*64}
            'edge-completion'{$bad.ownership.supersessions[1].completion_sha256='0'*64}
            'edge-request'{$bad.ownership.supersessions[0].request.sha256='0'*64}
            'edge-receipt'{$bad.ownership.supersessions[1].receipt.sha256='0'*64}
            'source'{$bad.source_composition.raw_sha256='0'*64}
        }
        Assert-SupersessionRequestRejected $originCase $bad $damage
    }
    # Damage actual producer artifacts independently of reviewed request fields.
    foreach($relative in @($request.ownership.root_admission.path,"receipts/transactions/$($request.ownership.root_claim.transaction_id).completion.json",$request.ownership.supersessions[0].request.path,$request.ownership.supersessions[1].receipt.path,$request.ownership.repository_map.path,$request.source_composition.path)){
        $path=Join-Path $originCase.workspace $relative;$saved=[IO.File]::ReadAllBytes($path)
        try{[IO.File]::AppendAllText($path,"`n");Assert-SupersessionRequestRejected $originCase $request "producer-raw:$relative"}finally{[IO.File]::WriteAllBytes($path,$saved)}
    }
    $null=Invoke-SupersessionRetirement $originCase -Execute
    $receipt=Read-EnvelopeProtocolJson (Join-Path $originCase.workspace 'receipts/retire-u004.json')
    Assert-Envelope ($receipt.schema-ceq'rusty.morphospace.workflow.active_unit_retirement_receipt.v2'-and$receipt.accepted-eq$false-and$receipt.source_mutation_performed-eq$false) 'v2 receipt granted acceptance or source mutation'
    Assert-Envelope ((Get-EnvelopeCanonicalJsonSha256 $receipt.ownership)-ceq(Get-EnvelopeCanonicalJsonSha256 $request.ownership)) 'receipt lost exact reviewed ownership'
    $null=Assert-SupersessionHistory $originCase -Idle
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $originCase.workspace;$null=Invoke-SupersessionRetirement $originCase -Execute
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $originCase.workspace)) 'exact completed retirement retry wrote or emitted second event'
    foreach($relative in $preserved.Keys){Assert-Envelope ($preserved[$relative]-ceq(Get-EnvelopeFileSha256 (Join-Path $originCase.workspace $relative))) "retirement rewrote $relative"}
    foreach($relative in @("receipts/transactions/$($request.ownership.root_claim.transaction_id).completion.json",$request.ownership.supersessions[0].receipt.path,'receipts/retire-u004-request.json','receipts/transactions/retire-u004-active-retired-transition.completion.json')){
        $path=Join-Path $originCase.workspace $relative;$saved=[IO.File]::ReadAllBytes($path)
        try{
            [IO.File]::AppendAllText($path,"`n");$before=Get-EnvelopeWorkspaceByteInventorySha256 $originCase.workspace;$rejected=$false
            try{$null=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $originCase.workspace -RequireIdle}catch{$rejected=$true}
            Assert-Envelope ($rejected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $originCase.workspace)) "historical reader accepted or wrote producer damage $relative"
        }finally{[IO.File]::WriteAllBytes($path,$saved)}
    }
    $checks.Add('actual-two-edge-post-nonpass-retirement-dry-retry')
    Test-SupersessionRetirementContinuation -Case $originCase -TestRoot (Join-Path $temp 'continuation') -RepositoryRoot $repoRoot
    foreach($relative in $preserved.Keys){Assert-Envelope ($preserved[$relative]-ceq(Get-EnvelopeFileSha256 (Join-Path $originCase.workspace $relative))) "replacement continuation rewrote $relative"}
    $checks.Add('actual-idle-prepare-admit-ready-claim-and-later-accept-continuation')
    }
    if($selectedCase-cin@('All','RetainedSource')){
    # Diagnostic retention and frozen nonpass are independent positive cases:
    # Freeze's established preparation closure does not acquire a new optional
    # retirement-diagnostic allowance merely to combine fixture histories.
    if($selectedRetainedCase-cin@('All','RootDiagnostics')){
    $diagnosticCase=New-SupersessionRetirementCase -Root (Join-Path $temp 'root-diagnostics') -RootDiagnostics
    $diagnosticPins=@{};foreach($relative in @('receipts/u002-claim.json','receipts/u002-ready.json')){$diagnosticPins[$relative]=Get-EnvelopeFileSha256 (Join-Path $diagnosticCase.workspace $relative)}
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $diagnosticCase.workspace;$null=Invoke-SupersessionRetirement $diagnosticCase
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $diagnosticCase.workspace)) 'root diagnostic dry run mutated bytes'
    foreach($damage in @('claim-commit','claim-context','claim-path','ready-event','ready-transaction','ready-blob','missing-claim','missing-ready')){
        $bad=Copy-Envelope $diagnosticCase.request
        switch($damage){
            'claim-commit'{$bad.retained_claim_diagnostic.introduced_commit='0'*40}
            'claim-context'{$bad.retained_claim_diagnostic.tooling_context=[pscustomobject]@{protocol_id='tooling-context-v1';path='tooling-contexts/forged.json';sha256=('0'*64);canonical_sha256=('0'*64)}}
            'claim-path'{$bad.retained_claim_diagnostic.path='receipts/u004-claim.json'}
            'ready-event'{$bad.retained_ready_diagnostic.event_id='u004-ready-9999'}
            'ready-transaction'{$bad.retained_ready_diagnostic.transaction_id=$bad.ownership.root_claim.transaction_id}
            'ready-blob'{$bad.retained_ready_diagnostic.git_blob_sha256='0'*64}
            'missing-claim'{$bad.PSObject.Properties.Remove('retained_claim_diagnostic')}
            'missing-ready'{$bad.PSObject.Properties.Remove('retained_ready_diagnostic')}
        }
        Assert-SupersessionRequestRejected $diagnosticCase $bad "root-diagnostic:$damage"
    }
    $null=Invoke-SupersessionRetirement $diagnosticCase -Execute;$null=Assert-SupersessionHistory $diagnosticCase -Idle
    foreach($relative in $diagnosticPins.Keys){Assert-Envelope ($diagnosticPins[$relative]-ceq(Get-EnvelopeFileSha256 (Join-Path $diagnosticCase.workspace $relative))) "retirement changed exact root diagnostic $relative"}
    $checks.Add('actual-root-diagnostics-inherited-across-two-edges')
    }
    if($selectedRetainedCase-cin@('All','SuccessorLifecycle')){
    $lifecycleCase=New-SupersessionRetirementCase -Root (Join-Path $temp 'successor-lifecycle') -SuccessorLifecycle
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $lifecycleCase.workspace;$null=Invoke-SupersessionRetirement $lifecycleCase
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $lifecycleCase.workspace)) 'successor lifecycle retirement dry run wrote bytes'
    Assert-Envelope (@($lifecycleCase.request.ownership.repository_maps).Count-eq2) 'actual alternate materialization map was not joined with original root map'
    foreach($damage in @('missing-map','extra-map','wrong-map-raw','wrong-map-path','noncanonical-map-path','duplicate-map','map-order')){
        $bad=Copy-Envelope $lifecycleCase.request
        switch($damage){
            'missing-map'{$bad.ownership.repository_maps=@($bad.ownership.repository_maps[0])}
            'extra-map'{$bad.ownership.repository_maps=@($bad.ownership.repository_maps)+@([pscustomobject]@{path='repository-map-extra.json';raw_sha256=('0'*64)})}
            'wrong-map-raw'{$bad.ownership.repository_maps[0].raw_sha256='0'*64}
            'wrong-map-path'{$bad.ownership.repository_maps[0].path=$bad.ownership.repository_maps[1].path}
            'noncanonical-map-path'{$bad.ownership.repository_maps[0].path='./'+$bad.ownership.repository_maps[0].path}
            'duplicate-map'{$bad.ownership.repository_maps=@($bad.ownership.repository_maps)+@((Copy-Envelope $bad.ownership.repository_maps[0]))}
            'map-order'{$bad.ownership.repository_maps=@($bad.ownership.repository_maps[1],$bad.ownership.repository_maps[0])}
        }
        Assert-SupersessionRequestRejected $lifecycleCase $bad "repository-maps:$damage"
    }
    Assert-Envelope (@($lifecycleCase.request.ownership.validation_attempts).Count-eq2) 'two real ReturnToActive attempts lost their finite producer order'
    $reordered=Copy-Envelope $lifecycleCase.request;$reordered.ownership.validation_attempts=@($reordered.ownership.validation_attempts[1],$reordered.ownership.validation_attempts[0])
    Assert-SupersessionRequestRejected $lifecycleCase $reordered 'validation-attempt-order'
    $lifecycleLineage=Test-ActiveRetirementSupersessionSemantics $lifecycleCase
    $null=Invoke-SupersessionRetirement $lifecycleCase -Execute;$null=Assert-SupersessionHistory $lifecycleCase -Idle
    Test-ActiveRetirementEndpointAuthoritySemantics $lifecycleCase $lifecycleLineage
    $checks.Add('actual-return-to-active-supersede-instruction-freeze-fresh-source-and-map-change')
    }
    foreach($disposition in @('Untracked','Ignored')){
        if($selectedRetainedCase-cne'All'-and$selectedRetainedCase-cne$disposition){continue}
        $attemptCase=New-SupersessionRetirementCase -Root (Join-Path $temp ("attempt-"+$disposition.ToLowerInvariant())) -AttemptDisposition $disposition
        Assert-ActiveRetirementAttemptDisposition $attemptCase $disposition
        $attemptPath=Join-Path $attemptCase.workspace 'receipts/root-nonpass.json';$attemptBytes=[IO.File]::ReadAllBytes($attemptPath)
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $attemptCase.workspace;$null=Invoke-SupersessionRetirement $attemptCase
        Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $attemptCase.workspace)) "$disposition retained attempt dry run wrote bytes"
        foreach($damage in @('missing','extra','foreign-event','foreign-path','wrong-raw','wrong-canonical')){
            $bad=Copy-Envelope $attemptCase.request
            switch($damage){
                'missing'{$bad.ownership.validation_attempts=@()}
                'extra'{$extra=Copy-Envelope $bad.ownership.validation_attempts[0];$extra.event_id='u099-validation-fail-return-9999';$bad.ownership.validation_attempts=@($bad.ownership.validation_attempts)+@($extra)}
                'foreign-event'{$bad.ownership.validation_attempts[0].event_id='u003-superseded-by-u004'}
                'foreign-path'{$bad.ownership.validation_attempts[0].path='receipts/foreign-attempt.json'}
                'wrong-raw'{$bad.ownership.validation_attempts[0].raw_sha256='0'*64}
                'wrong-canonical'{$bad.ownership.validation_attempts[0].canonical_sha256='0'*64}
            }
            Assert-SupersessionRequestRejected $attemptCase $bad ("retained-attempt-$disposition-"+$damage)
        }
        foreach($damage in @('raw-only','semantic')){
            try{
                if($damage-ceq'raw-only'){[IO.File]::AppendAllText($attemptPath,"`n")}else{$changed=Read-EnvelopeProtocolJson $attemptPath;$changed.created_at='2026-08-25T00:00:46.1000000Z';Write-EnvelopeJson $attemptPath $changed}
                Assert-SupersessionRequestRejected $attemptCase $attemptCase.request ("postreview-$disposition-"+$damage)
            }finally{[IO.File]::WriteAllBytes($attemptPath,$attemptBytes)}
        }
        $null=Invoke-SupersessionRetirement $attemptCase -Execute;$null=Assert-SupersessionHistory $attemptCase -Idle
        Assert-ActiveRetirementAttemptDisposition $attemptCase $disposition
        try{
            [IO.File]::AppendAllText($attemptPath,"`n");$before=Get-EnvelopeWorkspaceByteInventorySha256 $attemptCase.workspace;$rejected=$false
            try{$null=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $attemptCase.workspace -RequireIdle}catch{$rejected=$true}
            Assert-Envelope ($rejected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $attemptCase.workspace)) "$disposition historical review accepted retained attempt byte drift or wrote bytes"
        }finally{[IO.File]::WriteAllBytes($attemptPath,$attemptBytes)}
        $checks.Add("actual-$disposition-retained-return-input-review-and-drift")
    }

    }
    if($selectedCase-cin@('All','Recovery')){
    foreach($fault in @('after-intent','after-artifact','after-projection','after-event')){
        # A fresh fixture retains exact local Git/map provenance; positives never
        # transplant a workspace whose effective repository map points elsewhere.
        $recovery=New-SupersessionRetirementCase -Root (Join-Path $temp "recovery-$fault")
        $interrupted=$false;try{$null=Invoke-SupersessionRetirement $recovery -Execute -FaultAfter $fault}catch{$interrupted=$_.Exception.Message-like'*Injected*interruption*'}
        Assert-Envelope $interrupted "retirement did not reach actual owner fault $fault"
        if($fault-ceq'after-intent'){
            $intentPath=Join-Path $recovery.workspace 'receipts/transactions/retire-u004-active-retired-transition.intent.json';$saved=[IO.File]::ReadAllBytes($intentPath)
            try{
                $badIntent=Read-EnvelopeProtocolJson $intentPath;$badIntent.target.state.document.current_unit='u005';Write-EnvelopeJson $intentPath $badIntent
                Assert-SupersessionRequestRejected $recovery $recovery.request 'interrupted-retirement-target'
            }finally{[IO.File]::WriteAllBytes($intentPath,$saved)}
        }
        $null=Invoke-SupersessionRetirement $recovery -Execute;$null=Assert-SupersessionHistory $recovery -Idle
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $recovery.workspace;$null=Invoke-SupersessionRetirement $recovery -Execute
        Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $recovery.workspace)) "recovered exact retry mutated $fault"
        $checks.Add("actual-recovery:$fault")
    }
    }
    $settled=$true
    [pscustomobject]@{status='pass';check='supersession-active-retirement';case=$selectedCase;retained_case=$selectedRetainedCase;checks=@($checks.ToArray());modeled_accepted_prerequisite='u001';new_ownership_transitions='actual-public-writers';product_acceptance_proven=$false}|ConvertTo-Json -Compress -Depth 10
}finally{
    if(Test-Path -LiteralPath $temp){
        if(-not$settled){Write-Warning "Preserved unsettled supersession retirement fixture: $temp"}
        else{
            $resolved=[IO.Path]::GetFullPath((Get-Item -LiteralPath $temp -Force).FullName);$prefix=$tempParent+[IO.Path]::DirectorySeparatorChar
            if(-not$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-cne$tempName-or((Get-Item -LiteralPath $resolved -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'Unsafe supersession fixture cleanup; evidence preserved.'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
