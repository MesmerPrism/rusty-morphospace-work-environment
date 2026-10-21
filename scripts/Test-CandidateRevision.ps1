param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force
$automationModule=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force -PassThru
$freezeModule=Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -PassThru
$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$transitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
. (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')

function Invoke-RevisionAutomation([string]$Action,[hashtable]$Extra=@{}){
    $arguments=@{Action=$Action;WorkspaceRoot=$ws;UnitId='u002';RepoMapPath=(Join-Path $ws 'repository-map.json');ValidationTier='quick';Timestamp='2026-10-20T10:00:00.0000000Z'}
    foreach($key in $Extra.Keys){$arguments[$key]=$Extra[$key]}
    if($Action-cin@('BeginValidation','ReturnToActive','RecordValidation','Accept')-and$null-ne$script:revisionSelector){foreach($key in $script:revisionSelector.Keys){$arguments[$key]=$script:revisionSelector[$key]}}
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a} $arguments
}
function New-RevisionFreeze([string]$Id,[switch]$Revision){
    $state=Read-EnvelopeProtocolJson (Join-Path $ws 'workspace.state.json');$unit=Read-EnvelopeProtocolJson (Join-Path $ws 'iteration-units/u002.json');$lock=Read-EnvelopeProtocolJson (Join-Path $ws 'feature.lock.json');$events=Join-Path $ws 'iteration-events.jsonl'
    $freeze=[ordered]@{schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id=$Id;project_id='envelope-test';unit_id='u002';expected=[ordered]@{project_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $ws 'project.spec.json'));state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $lock;source_composition_path='source-composition.json';source_composition_sha256=Get-EnvelopeFileSha256 (Join-Path $ws 'source-composition.json');repository_map_path='repository-map.json';repository_map_sha256=Get-EnvelopeFileSha256 (Join-Path $ws 'repository-map.json');events_sha256=Get-EnvelopeFileSha256 $events;events_length=([IO.FileInfo]$events).Length;event_tail_id=[string]$state.last_event_id};final_repositories=@([ordered]@{repo_id='project-shell';commit=(@(Invoke-EnvelopeGit $source @('rev-parse','HEAD'))[0]).Trim();tree=(@(Invoke-EnvelopeGit $source @('rev-parse','HEAD^{tree}'))[0]).Trim()});changed_paths=@([ordered]@{repo_id='project-shell';paths=@('morphospace/')});cleanliness_policy='clean-only';instruction_surfaces=@([ordered]@{path='morphospace/README.md';disposition='reviewed-no-change'});feature_lock=[ordered]@{revision=[int]$lock.revision;sha256=Get-EnvelopeCanonicalJsonSha256 $lock};effects=@('none');permissions=@();device_use=@('none');test_matrix=@([ordered]@{test_id='revision-source';command='Check the fixture source content.'});cleanup_evidence=@('Disposable host fixture; no external effects.');source_composition=[ordered]@{path='source-composition.json';sha256=Get-EnvelopeFileSha256 (Join-Path $ws 'source-composition.json')};does_not_prove=@('No protected approval, publication, build or device authority.')}
    if($Revision){$freeze.schema='rusty.morphospace.workflow.candidate_freeze.v3';$retained="receipts/$($state.last_event_id)-retained-validation.json";$freeze.predecessor=[ordered]@{freeze=Copy-Envelope $unit.candidate_freeze;return_event_id=[string]$state.last_event_id;validation_receipt=[ordered]@{path=$retained;sha256=Get-EnvelopeFileSha256 (Join-Path $ws $retained)}}}
    $freeze
}
function Invoke-RevisionFreeze([string]$Path,[switch]$Execute,[string]$Fault='none'){
    $document=Read-EnvelopeProtocolJson $Path;$out=Join-Path $ws "receipts/$($document.freeze_id).json"
    &$freezeModule {param($a)Invoke-MorphospaceFreezeCandidate @a} @{WorkspaceRoot=$ws;UnitId='u002';CandidateFreeze=$Path;ExpectedCandidateFreezeSha256=(Get-EnvelopeFileSha256 $Path);OutPath=$out;Timestamp='2026-10-20T10:00:00.0000000Z';Execute=$Execute.IsPresent;FaultAfter=$Fault}
}
function New-RevisionValidation([string]$Id){
    # Execute the fixture's source predicate and then describe its observed result.
    $passed=[IO.File]::ReadAllText((Join-Path $source 'morphospace/README.md')).Contains('corrected')
    $result=if($passed){'pass'}else{'fail'}
    $evidence=Join-Path $ws "receipts/attempts/$Id.txt";[IO.Directory]::CreateDirectory((Split-Path $evidence -Parent))|Out-Null;[IO.File]::WriteAllText($evidence,"source predicate result: $result`n")
    $unit=Read-EnvelopeProtocolJson (Join-Path $ws 'iteration-units/u002.json')
    $matrix=@($script:revisionMatrix|Where-Object disposition -CNE 'forbidden')
    $receipt=[ordered]@{schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id=$Id;project_id='envelope-test';unit_id='u002';created_at='2026-10-20T10:00:00Z';tier='quick';result=$result;repository_revisions=@([ordered]@{repo_id='project-shell';base_revision=$seed.source_commit;head_revision=(@(Invoke-EnvelopeGit $source @('rev-parse','HEAD'))[0]).Trim();branch=(@(Invoke-EnvelopeGit $source @('rev-parse','--abbrev-ref','HEAD'))[0]).Trim()});changed_paths=@();artifacts=@([ordered]@{artifact_id='source-evidence';kind='test-log';path="$Id.txt";sha256=Get-EnvelopeFileSha256 $evidence});criteria=@($unit.acceptance|ForEach-Object{[ordered]@{acceptance_id=$_.acceptance_id;status=$result;command=$_.command;evidence_refs=@('source-evidence')}});gates=@($matrix|ForEach-Object{[ordered]@{gate_id=$_.gate_id;status=$result;command=$_.command;evidence_refs=@('source-evidence')}});device_validation=$null}
    $receipt.changed_paths=@(Invoke-EnvelopeGit $source @('diff','--name-only',"$($seed.source_commit)..HEAD",'--')|Where-Object{$_}|ForEach-Object{[ordered]@{repo_id='project-shell';path=[string]$_}})
    if($null-ne$script:revisionSelector){
        $evidencePath=$script:revisionSelector.ValidationEvidencePath
        Write-EnvelopeJson $evidencePath ([ordered]@{schema='rusty.morphospace.test.revision.v1';result=$result})
        $receipt.artifacts+=,[ordered]@{artifact_id='selector-evidence';kind='test-log';path=$evidencePath;sha256=Get-EnvelopeFileSha256 $evidencePath}
    }
    $relative="receipts/attempts/$Id.json"
    $productEvidence=[ordered]@{};foreach($key in @('receipt_id','tier','result','criteria','gates','device_validation')){$productEvidence[$key]=$receipt[$key]}
    $productEvidence.artifacts=@($receipt.artifacts|ForEach-Object{[ordered]@{artifact_id=$_.artifact_id;kind=$_.kind;path=$_.path}})
    $productEvidencePath=Join-Path $root "$Id-product-evidence.json";Write-EnvelopeJson $productEvidencePath $productEvidence
    & (Join-Path $PSScriptRoot 'New-ValidationReceipt.ps1') -WorkspaceRoot $ws -UnitId u002 -RepoMapPath (Join-Path $ws 'repository-map.json') -EvidencePath $productEvidencePath -OutPath (Join-Path $ws $relative) -CreatedAt '2026-10-20T10:00:00Z'|Out-Null
    $relative
}
function New-RevisionSelector([string]$Id){
    $unitPath=Join-Path $ws 'iteration-units/u002.json';$unit=Read-EnvelopeProtocolJson $unitPath;$freeze=Read-EnvelopeProtocolJson (Join-Path $ws $unit.candidate_freeze.receipt_path)
    $contract=Copy-Envelope $unit;$contract.PSObject.Properties.Remove('status')
    $producer=Join-Path $ws 'tools/revision-evidence.ps1';[IO.Directory]::CreateDirectory((Split-Path $producer -Parent))|Out-Null
    [IO.File]::WriteAllText($producer,'param([string]$OutPath) # Test-owned exact evidence producer.')
    $evidence=Join-Path $root "$Id-evidence.json";$canonical=[IO.Path]::GetFullPath($evidence);if($IsWindows){$canonical=$canonical.Replace('/','\').ToUpperInvariant()}
    $pathHash=&$protocolModule {param($t)Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes($t))} $canonical
    $gate=$unit.validation[0];$commandHash=&$protocolModule {param($t)Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes($t))} ([string]$gate.command)
    $relative="validation-authority/selectors/$Id.json"
    Write-EnvelopeJson (Join-Path $ws $relative) ([ordered]@{schema='rusty.morphospace.workflow.normal_validation_selector.v1';selector_id=$Id;project=[ordered]@{project_id='envelope-test';spec_path='project.spec.json';spec_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $ws 'project.spec.json')};unit=[ordered]@{unit_id='u002';path='iteration-units/u002.json';raw_sha256=Get-EnvelopeFileSha256 $unitPath;contract_sha256=Get-EnvelopeCanonicalJsonSha256 $contract};declared_gate=[ordered]@{profile_id=$gate.profile_id;command_sha256=$commandHash};candidate_freeze=[ordered]@{freeze_id=$freeze.freeze_id;receipt_path=$unit.candidate_freeze.receipt_path;receipt_sha256=$unit.candidate_freeze.receipt_sha256;final_repositories=@($freeze.final_repositories)};selection=[ordered]@{tier='quick';producer=[ordered]@{kind='workspace-powershell-evidence-v1';path='tools/revision-evidence.ps1';sha256=Get-EnvelopeFileSha256 $producer};output_evidence=[ordered]@{file_name=[IO.Path]::GetFileName($evidence);schema='rusty.morphospace.test.revision.v1';canonical_path_sha256=$pathHash;requires_create_new=$true}};does_not_authorize=@('No protected approval or other candidate acceptance.')})
    @{ValidationSelector=$relative;ExpectedValidationSelectorSha256=Get-EnvelopeFileSha256 (Join-Path $ws $relative);ValidationEvidencePath=$evidence}
}
$script:revisionSelector=$null;$script:revisionMatrix=@()
function Assert-RevisionRefuses([scriptblock]$Action,[string]$Name){
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $ws;$caught=$null
    try{&$Action|Out-Null}catch{$caught=$_}
    if($caught-and$caught.Exception-is[Management.Automation.CommandNotFoundException]){throw $caught}
    Assert-Envelope ($null-ne$caught) "candidate revision accepted $Name"
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) "candidate revision wrote while refusing $Name"
}
function Assert-RevisionRetirementConsumer([string]$EventId){
    $retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
    &$retirementModule {param($w,$id)
        $proof=Get-ActiveRetirementPlanningTransition $w "$id-transition" -HistoricalProjection
        Assert-ActiveRetirementRetainedLifecycle $w $proof.intent.event $proof
    } $ws $EventId
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wef-candidate-revision-'+[guid]::NewGuid().ToString('N'))
try{
    $seed=New-EnvelopeAdmissionPreparedFixture -Root $root -RepositoryRoot $repoRoot -TransitionLedgerModule $transitionLedgerModule -OwnerProducedPreparation
    $ws=$seed.workspace;$source=$seed.source_repository;$admission=Join-Path $root 'admission.json';Write-EnvelopeJson $admission $seed.admission_template
    $admissionOut=Join-Path $ws 'receipts/u002-admission.json'
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $ws -DevelopmentUnitAdmission $admission -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admission) -OutPath $admissionOut -Timestamp '2026-08-25T00:01:00.0000000Z' -Execute|Out-Null
    foreach($action in @('Ready','Claim')){Invoke-RevisionAutomation $action @{Execute=$true}|Out-Null}
    $freezeA=Join-Path $root 'freeze-a.json';Write-EnvelopeJson $freezeA (New-RevisionFreeze 'candidate-a')
    Invoke-RevisionFreeze $freezeA -Execute|Out-Null
    $oldHash=Get-EnvelopeFileSha256 (Join-Path $ws 'receipts/candidate-a.json')
    $script:revisionSelector=New-RevisionSelector 'candidate-a-selector'
    $script:revisionMatrix=(Invoke-RevisionAutomation BeginValidation @{Execute=$true}).validation_matrix
    $failed=New-RevisionValidation 'candidate-a-failure'
    Assert-RevisionRefuses {Invoke-RevisionAutomation ReturnToActive @{ValidationResult='pass';ValidationReceipt=$failed;Execute=$true}} 'passing ReturnToActive'
    Invoke-RevisionAutomation ReturnToActive @{ValidationResult='fail';ValidationReceipt=$failed;Execute=$true}|Out-Null
    Assert-RevisionRetirementConsumer ([string](Read-EnvelopeProtocolJson (Join-Path $ws 'workspace.state.json')).last_event_id)
    $oldSelector=$script:revisionSelector;$script:revisionSelector=$null
    $failedHash=Get-EnvelopeFileSha256 (Join-Path $ws $failed)
    [IO.File]::WriteAllText((Join-Path $source 'morphospace/README.md'),"corrected`n")
    Invoke-EnvelopeGit $source @('add','morphospace/README.md')|Out-Null;Invoke-EnvelopeGit $source @('commit','-m','in-scope correction')|Out-Null
    $freezeB=Join-Path $root 'freeze-b.json';Write-EnvelopeJson $freezeB (New-RevisionFreeze 'candidate-b' -Revision)
    Assert-RevisionRefuses {Invoke-RevisionAutomation BeginValidation @{Execute=$true}} 'old freeze validation after correction'
    $originalB=[IO.File]::ReadAllBytes($freezeB)
    foreach($damage in @('predecessor','stale-CAS','scope','feature-lock','tooling','failed-receipt','failed-artifact','accepted')){
        $unitPath=Join-Path $ws 'iteration-units/u002.json';$lockPath=Join-Path $ws 'feature.lock.json';$savedUnit=[IO.File]::ReadAllBytes($unitPath);$savedLock=[IO.File]::ReadAllBytes($lockPath);$savedFailed=[IO.File]::ReadAllBytes((Join-Path $ws $failed))
        $failedEvidence=Join-Path $ws 'receipts/attempts/candidate-a-failure.txt';$savedEvidence=[IO.File]::ReadAllBytes($failedEvidence)
        try{
            $candidate=Read-EnvelopeProtocolJson $freezeB
            switch($damage){
                'predecessor'{$candidate.predecessor.freeze.freeze_id='detached-freeze'}
                'stale-CAS'{$candidate.expected.state_sha256='0'*64}
                'scope'{$candidate.changed_paths[0].paths=@('outside/')}
                'feature-lock'{$lock=Read-EnvelopeProtocolJson $lockPath;$lock.revision++;Write-EnvelopeJson $lockPath $lock}
                'tooling'{$unit=Read-EnvelopeProtocolJson $unitPath;$unit|Add-Member tooling_context ([pscustomobject]@{path='receipts/missing.json';sha256='0'*64;canonical_sha256='0'*64;protocol_id='missing-context'});Write-EnvelopeJson $unitPath $unit}
                'failed-receipt'{[IO.File]::AppendAllText((Join-Path $ws $failed),' ')}
                'failed-artifact'{[IO.File]::AppendAllText($failedEvidence,'changed retained failure evidence')}
                'accepted'{$unit=Read-EnvelopeProtocolJson $unitPath;$unit.status='accepted';Write-EnvelopeJson $unitPath $unit}
            }
            Write-EnvelopeJson $freezeB $candidate;Assert-RevisionRefuses {Invoke-RevisionFreeze $freezeB -Execute} $damage
        }finally{[IO.File]::WriteAllBytes($freezeB,$originalB);[IO.File]::WriteAllBytes($unitPath,$savedUnit);[IO.File]::WriteAllBytes($lockPath,$savedLock);[IO.File]::WriteAllBytes((Join-Path $ws $failed),$savedFailed);[IO.File]::WriteAllBytes($failedEvidence,$savedEvidence)}
    }
    $beforeDry=Get-EnvelopeWorkspaceByteInventorySha256 $ws;Invoke-RevisionFreeze $freezeB|Out-Null
    Assert-Envelope ($beforeDry-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) 'revision dry run wrote workspace'
    Write-Host 'PASS admitted frozen failure and eight revision damage controls; checking each durable recovery boundary.'
    $originalWorkspace=$ws
    foreach($fault in @('after-artifact','after-projection','after-event')){
        $copy=Join-Path $root "recovery-$fault";Copy-Item -LiteralPath $originalWorkspace -Destination $copy -Recurse
        try{
            $ws=$copy;$interrupted=$false
            try{Invoke-RevisionFreeze $freezeB -Execute -Fault $fault|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption*'}
            Assert-Envelope $interrupted "candidate revision did not reach $fault"
            Invoke-RevisionFreeze $freezeB -Execute|Out-Null
            $snapshot=Get-EnvelopeWorkspaceByteInventorySha256 $ws;Invoke-RevisionFreeze $freezeB -Execute|Out-Null
            Assert-Envelope ($snapshot-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) "candidate revision $fault recovery duplicated effects"
        }finally{$ws=$originalWorkspace}
    }
    $failedWrite=$false;try{Invoke-RevisionFreeze $freezeB -Execute -Fault after-intent|Out-Null}catch{$failedWrite=$_.Exception.Message-like'*Injected interruption*'}
    Assert-Envelope $failedWrite 'revision interruption did not reach durable intent'
    # Recovery must revalidate old proof and current sources before effects.
    [IO.File]::AppendAllText((Join-Path $ws $failed),' ')
    Assert-RevisionRefuses {Invoke-RevisionFreeze $freezeB -Execute} 'damaged failed proof during recovery'
    [IO.File]::WriteAllBytes((Join-Path $ws $failed),$savedFailed)
    $dirt=Join-Path $source 'morphospace/recovery-drift.txt';[IO.File]::WriteAllText($dirt,'unvalidated source drift')
    Assert-RevisionRefuses {Invoke-RevisionFreeze $freezeB -Execute} 'changed live source during recovery'
    Remove-Item -LiteralPath $dirt
    Invoke-RevisionFreeze $freezeB -Execute|Out-Null
    Assert-RevisionRetirementConsumer 'candidate-b-recorded'
    $afterRevision=Get-EnvelopeWorkspaceByteInventorySha256 $ws
    Invoke-RevisionFreeze $freezeB -Execute|Out-Null
    Assert-Envelope ($afterRevision-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) 'completed revision replay wrote another event'
    $state=Read-EnvelopeProtocolJson (Join-Path $ws 'workspace.state.json')
    Assert-Envelope ($null-eq$state.validation_checkpoint-and$null-eq$state.normal_validation_selection) 'revision retained old acceptance or selector authority'
    $script:revisionSelector=$oldSelector
    Assert-RevisionRefuses {Invoke-RevisionAutomation BeginValidation @{Execute=$true}} 'old selector reused on corrected source'
    $script:revisionSelector=New-RevisionSelector 'candidate-b-selector'
    $script:revisionMatrix=(Invoke-RevisionAutomation BeginValidation @{Execute=$true}).validation_matrix
    Assert-RevisionRefuses {Invoke-RevisionAutomation RecordValidation @{ValidationResult='pass';ValidationReceipt=$failed;Execute=$true}} 'old failed validation reused on corrected source'
    $passed=New-RevisionValidation 'candidate-b-passing'
    Invoke-RevisionAutomation RecordValidation @{ValidationResult='pass';ValidationReceipt=$passed;Execute=$true}|Out-Null
    Invoke-RevisionAutomation Accept @{Execute=$true}|Out-Null
    $unit=Read-EnvelopeProtocolJson (Join-Path $ws 'iteration-units/u002.json')
    Assert-Envelope ([string]$unit.status-ceq'accepted'-and[string]$unit.candidate_freeze.freeze_id-ceq'candidate-b') 'linked revision did not earn fresh acceptance'
    Assert-Envelope ($oldHash-ceq(Get-EnvelopeFileSha256 (Join-Path $ws 'receipts/candidate-a.json'))-and$failedHash-ceq(Get-EnvelopeFileSha256 (Join-Path $ws $failed))) 'linked revision changed old freeze or failed evidence'
    $events=@(Get-Content (Join-Path $ws 'iteration-events.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
    Assert-Envelope (@($events|Where-Object event_id -CEQ 'candidate-b-recorded').Count-eq1) 'revision replay duplicated its event'
    Write-Output 'PASS owner preparation/admission/Ready/Claim/Freeze A/failure/Return/edit/linked B/fresh validation/acceptance; immutable history, no-write damage controls, interruption/recovery and idempotent replay.'
}finally{
    $full=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($full).TrimEnd('\','/')-ne$parent-or[IO.Path]::GetFileName($full)-cnotmatch'^wef-candidate-revision-[0-9a-f]{32}$'){throw 'Refusing candidate revision fixture cleanup outside its exact task-owned root.'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
