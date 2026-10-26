param([switch]$SelfTest,[string]$LegacyProducerRoot,[string]$FixtureRoot,[string]$AuthoritySourceRoot,[switch]$SourceScopeOnly,[switch]$ContinuationOnly)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force
$automationModule=Import-Module (Join-Path $repoRoot 'scripts/WorkUnitAutomation.psm1') -Force -PassThru
$freezeModule=Import-Module (Join-Path $repoRoot 'scripts/CandidateFreeze.psm1') -PassThru
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
    $evidence=Join-Path $ws "receipts/$Id.txt";[IO.Directory]::CreateDirectory((Split-Path $evidence -Parent))|Out-Null;[IO.File]::WriteAllText($evidence,"source predicate result: $result`n")
    $unit=Read-EnvelopeProtocolJson (Join-Path $ws 'iteration-units/u002.json')
    $matrix=@($script:revisionMatrix|Where-Object disposition -CNE 'forbidden')
    $receipt=[ordered]@{schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id=$Id;project_id='envelope-test';unit_id='u002';created_at='2026-10-20T10:00:00Z';tier='quick';result=$result;repository_revisions=@([ordered]@{repo_id='project-shell';base_revision=$seed.source_commit;head_revision=(@(Invoke-EnvelopeGit $source @('rev-parse','HEAD'))[0]).Trim();branch=(@(Invoke-EnvelopeGit $source @('rev-parse','--abbrev-ref','HEAD'))[0]).Trim()});changed_paths=@();artifacts=@([ordered]@{artifact_id='source-evidence';kind='test-log';path="$Id.txt";sha256=Get-EnvelopeFileSha256 $evidence});criteria=@($unit.acceptance|ForEach-Object{[ordered]@{acceptance_id=$_.acceptance_id;status=$result;command=$_.command;evidence_refs=@('source-evidence')}});gates=@($matrix|ForEach-Object{
        $references=if($_.PSObject.Properties.Name-ccontains'selection_kind'-and[string]$_.selection_kind-ceq'exact-external-evidence'){@('selector-evidence')}else{@('source-evidence')}
        [ordered]@{gate_id=$_.gate_id;status=$result;command=$_.command;evidence_refs=@($references)}
    });device_validation=$null}
    if($result-cne'pass'){$receipt.artifacts+=@([ordered]@{artifact_id='mutable-source';kind='source';path=(Join-Path $source 'morphospace/README.md');sha256=Get-EnvelopeFileSha256 (Join-Path $source 'morphospace/README.md')},[ordered]@{artifact_id='mutable-index';kind='source';path=(@(Invoke-EnvelopeGit $source @('rev-parse','--path-format=absolute','--git-path','index'))[0]).Trim();sha256=Get-EnvelopeFileSha256 ((@(Invoke-EnvelopeGit $source @('rev-parse','--path-format=absolute','--git-path','index'))[0]).Trim())})}
    $receipt.changed_paths=@(Invoke-EnvelopeGit $source @('diff','--name-only',"$($seed.source_commit)..HEAD",'--')|Where-Object{$_}|ForEach-Object{[ordered]@{repo_id='project-shell';path=[string]$_}})
    if($null-ne$script:revisionSelector){
        $evidencePath=$script:revisionSelector.ValidationEvidencePath
        Write-EnvelopeJson $evidencePath ([ordered]@{schema='rusty.morphospace.test.revision.v1';result=$result})
        $receipt.artifacts+=,[ordered]@{artifact_id='selector-evidence';kind='test-log';path=$evidencePath;sha256=Get-EnvelopeFileSha256 $evidencePath}
    }
    $relative="receipts/$Id.json"
    $productEvidence=[ordered]@{};foreach($key in @('receipt_id','tier','result','criteria','gates','device_validation')){$productEvidence[$key]=$receipt[$key]}
    $productEvidence.artifacts=@($receipt.artifacts|ForEach-Object{[ordered]@{artifact_id=$_.artifact_id;kind=$_.kind;path=$_.path}})
    $productEvidencePath=Join-Path $root "$Id-product-evidence.json";Write-EnvelopeJson $productEvidencePath $productEvidence
    $producerRoot=if($script:currentReceiptProducerRoot){$script:currentReceiptProducerRoot}else{$LegacyProducerRoot}
    & (Join-Path $producerRoot 'scripts/New-ValidationReceipt.ps1') -WorkspaceRoot $ws -UnitId u002 -RepoMapPath (Join-Path $ws 'repository-map.json') -EvidencePath $productEvidencePath -OutPath (Join-Path $ws $relative) -CreatedAt '2026-10-20T10:00:00Z'|Out-Null
    if($script:currentReceiptProducerRoot-and$result-cne'pass'){
        $produced=Read-EnvelopeProtocolJson (Join-Path $ws $relative)
        Assert-Envelope (@($produced.artifacts|Where-Object artifact_id -CEQ 'nonpass-evidence-custody').Count-eq1) 'eligible current producer did not publish immutable NONPASS custody'
    }
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
$script:currentReceiptProducerRoot=''
function Expand-RecoveryFixtureSource([string]$Commit,[string]$Archive,[string]$Destination){
    if([IO.File]::Exists($Archive)-or[IO.Directory]::Exists($Destination)){throw 'Historical source fixture output is occupied.'}
    $process=[Diagnostics.Process]::new();$process.StartInfo=[Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName=(Get-Command git -CommandType Application|Select-Object -First 1).Source;$process.StartInfo.WorkingDirectory=$repoRoot
    $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
    foreach($name in @($process.StartInfo.Environment.Keys)){if($name-match'^GIT_'){$process.StartInfo.Environment.Remove($name)|Out-Null}}
    $process.StartInfo.Environment['GIT_CONFIG_NOSYSTEM']='1';$process.StartInfo.Environment['GIT_CONFIG_GLOBAL']=if($IsWindows){'NUL'}else{'/dev/null'}
    foreach($arg in @('--no-optional-locks','--no-replace-objects','-c','core.hooksPath=','archive','--format=zip','--output',$Archive,$Commit)){$process.StartInfo.ArgumentList.Add($arg)}
    try{$null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit();$null=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult();if($process.ExitCode-ne0){throw "Published fixture Git object $Commit is required: $errorText"}}finally{$process.Dispose()}
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$Destination)
}
function Invoke-RecoveryAuthoritySourceGit([string]$At,[string[]]$Arguments){
    # Same isolated Git process policy as the owning authority source reader.
    $process=[Diagnostics.Process]::new();$process.StartInfo=[Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName=(Get-Command git -CommandType Application|Select-Object -First 1).Source
    $process.StartInfo.WorkingDirectory=$At;$process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
    foreach($name in @($process.StartInfo.Environment.Keys)){if($name-match'^GIT_'){$process.StartInfo.Environment.Remove($name)|Out-Null}}
    $process.StartInfo.Environment['GIT_CONFIG_NOSYSTEM']='1';$process.StartInfo.Environment['GIT_CONFIG_GLOBAL']=if($IsWindows){'NUL'}else{'/dev/null'}
    foreach($argument in @('--no-optional-locks','--no-pager','--no-replace-objects','-c','core.fsmonitor=false','-c','core.hooksPath=','-c','core.autocrlf=false','-c','core.longpaths=true','-c','protocol.allow=never','-c','protocol.file.allow=always')+$Arguments){$process.StartInfo.ArgumentList.Add($argument)}
    try{
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
        $result=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode-ne0){throw "Adopted authority fixture Git failed: $errorText"}
        $result.Trim()
    }finally{$process.Dispose()}
}
function Initialize-RecoveryAuthoritySource([object]$Authority,[string]$Destination){
    if([IO.Directory]::Exists($Destination)-or[IO.File]::Exists($Destination)){throw 'Adopted authority source fixture output is occupied.'}
    if([string]$Authority.commit-cnotmatch'^(?:[0-9a-f]{40}|[0-9a-f]{64})$'-or
       [string]$Authority.tree-cnotmatch'^(?:[0-9a-f]{40}|[0-9a-f]{64})$'-or
       [string]$Authority.repository-cnotmatch'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){throw 'Adopted authority fixture requires exact binding identity.'}
    $commit=[string]$Authority.commit;$tree=[string]$Authority.tree
    if((Invoke-RecoveryAuthoritySourceGit $repoRoot @('rev-parse','--verify',"$commit^{commit}"))-cne$commit-or
       (Invoke-RecoveryAuthoritySourceGit $repoRoot @('rev-parse','--verify',"$commit^{tree}"))-cne$tree){throw 'Adopted authority fixture local object identity differs from its binding.'}
    # Reuse the exact-source consumer's local no-hardlink/no-checkout pattern.
    # Dissociate any borrowed source objects; no network protocol is permitted.
    Invoke-RecoveryAuthoritySourceGit $repoRoot @('clone','--quiet','--no-hardlinks','--no-checkout','--dissociate',$repoRoot,$Destination)|Out-Null
    Invoke-RecoveryAuthoritySourceGit $Destination @('config','core.autocrlf','false')|Out-Null
    Invoke-RecoveryAuthoritySourceGit $Destination @('remote','set-url','origin',('https://github.com/'+[string]$Authority.repository+'.git'))|Out-Null
    Invoke-RecoveryAuthoritySourceGit $Destination @('checkout','--quiet','--detach',$commit)|Out-Null
    if((Invoke-RecoveryAuthoritySourceGit $Destination @('rev-parse','HEAD'))-cne$commit-or
       (Invoke-RecoveryAuthoritySourceGit $Destination @('rev-parse','HEAD^{tree}'))-cne$tree-or
       (Invoke-RecoveryAuthoritySourceGit $Destination @('status','--porcelain=v2','--untracked-files=all'))){throw 'Adopted authority source fixture is not its exact clean pinned checkout.'}
    foreach($relative in @('objects/info/alternates','objects/info/http-alternates','info/grafts','shallow')){
        if(Test-Path -LiteralPath (Join-Path $Destination ('.git/'+$relative))){throw 'Adopted authority fixture must own complete unmodified Git objects.'}
    }
    if(Invoke-RecoveryAuthoritySourceGit $Destination @('for-each-ref','--format=%(refname)','refs/replace')){throw 'Adopted authority fixture replacement refs are forbidden.'}
    [IO.Path]::GetFullPath($Destination)
}
function Assert-RevisionRefuses([scriptblock]$Action,[string]$Name,[string]$ExpectedMessage=''){
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $ws;$caught=$null
    try{&$Action|Out-Null}catch{$caught=$_}
    if($caught-and$caught.Exception-is[Management.Automation.CommandNotFoundException]){throw $caught}
    Assert-Envelope ($null-ne$caught) "candidate revision accepted $Name"
    if($ExpectedMessage){Assert-Envelope ($caught.Exception.Message.Contains($ExpectedMessage,[StringComparison]::Ordinal)) "candidate revision refused $Name for an unrelated reason: $($caught.Exception.Message)"}
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) "candidate revision wrote while refusing $Name"
}
function Assert-RevisionSelectedEvidenceControls([string]$Relative,[string]$TransitionAction,[string]$Result){
    $path=Join-Path $ws $Relative;$original=[IO.File]::ReadAllBytes($path);$receipt=Read-EnvelopeProtocolJson $path
    # This fixture selects its declared workflow gate; ordinary proof stays on the source predicate.
    $selected=@($receipt.gates|Where-Object gate_id -CEQ 'validation-workflow')
    Assert-Envelope ($selected.Count-eq1-and@($selected[0].evidence_refs).Count-eq1-and$selected[0].evidence_refs[0]-ceq'selector-evidence') 'selected workflow gate lost its independent evidence'
    $ordinary=@($receipt.gates|Where-Object gate_id -CNE 'validation-workflow')
    Assert-Envelope ($ordinary.Count-gt0) 'candidate revision lacks an ordinary instruction gate'
    foreach($row in @($ordinary)+@($receipt.criteria)){
        Assert-Envelope (@($row.evidence_refs).Count-eq1-and$row.evidence_refs[0]-ceq'source-evidence') 'ordinary proof was replaced by selected evidence'
    }
    foreach($damage in @('wrong','omitted','duplicate')){
        $changed=Copy-Envelope $receipt;$gate=@($changed.gates|Where-Object gate_id -CEQ 'validation-workflow')[0]
        switch($damage){
            'wrong'{$gate.evidence_refs=@('source-evidence')}
            'omitted'{$gate.evidence_refs=@()}
            'duplicate'{$gate.evidence_refs=@('selector-evidence','selector-evidence')}
        }
        Write-EnvelopeJson $path $changed
        try{
            $expected=if($damage-ceq'wrong'){"Selected validation gate 'validation-workflow' must reference exactly its bound external evidence artifact."}else{'Validation receipt does not satisfy structural schema'}
            Assert-RevisionRefuses {Invoke-RevisionAutomation $TransitionAction @{ValidationResult=$Result;ValidationReceipt=$Relative;Execute=$true}} "$TransitionAction $damage selected evidence" $expected
        }finally{[IO.File]::WriteAllBytes($path,$original)}
    }
    Write-Host "PASS $TransitionAction selected versus ordinary evidence and wrong/omitted/duplicate reference no-write controls."
}
function Assert-RevisionRetirementConsumer([string]$EventId){
    $retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
    &$retirementModule {param($w,$id)
        $proof=Get-ActiveRetirementPlanningTransition $w "$id-transition" -HistoricalProjection
        Assert-ActiveRetirementRetainedLifecycle $w $proof.intent.event $proof
    } $ws $EventId
}
$root=if($FixtureRoot){[IO.Path]::GetFullPath($FixtureRoot)}else{Join-Path ([IO.Path]::GetTempPath()) ('wef-nonpass-recovery-'+[guid]::NewGuid().ToString('N'))}
[IO.Directory]::CreateDirectory($root)|Out-Null
# Fail source setup before starting the expensive recovery journey.
if(-not$AuthoritySourceRoot){
    $binding=Read-EnvelopeProtocolJson (Join-Path $repoRoot 'config/native-nonpass-recovery-authority-binding.json')
    if(@($binding.authorities).Count-ne1){throw 'The full positive native recovery fixture requires one independently adopted authority Git source; no denial-only pass is issued.'}
    $AuthoritySourceRoot=Initialize-RecoveryAuthoritySource $binding.authorities[0] (Join-Path $root 'adopted-authority-source')
}
if(-not$LegacyProducerRoot){
    $archive=Join-Path $root 'published-old-producer.zip'
    $LegacyProducerRoot=Join-Path $root 'published-old-producer'
    Expand-RecoveryFixtureSource '05006fc68268b2d72da855ed3195b0afcfd90785' $archive $LegacyProducerRoot
    Assert-Envelope ((Get-EnvelopeFileSha256 (Join-Path $LegacyProducerRoot 'scripts/lib/MorphospaceValidationReceipt.psm1'))-ceq'46f96102712ae41dbf07c86ce8c25ea8a7742acfd07b1251bab7e29213eb42d0') 'published historical producer raw bytes differ from the pinned writer'
}
$preparedArguments=@{Root=$root;RepositoryRoot=$repoRoot;TransitionLedgerModule=$transitionLedgerModule;OwnerProducedPreparation=$true}
$seed=New-EnvelopeAdmissionPreparedFixture @preparedArguments
$ws=$seed.workspace;$source=$seed.source_repository
$ignorePath=Join-Path $ws '.gitignore';$ignore=if([IO.File]::Exists($ignorePath)){[IO.File]::ReadAllText($ignorePath)}else{''}
if($ignore-and-not$ignore.EndsWith("`n")){$ignore+="`n"}
[IO.File]::WriteAllText($ignorePath,($ignore+"receipts/*-evidence/`n"),[Text.UTF8Encoding]::new($false))
Invoke-EnvelopeGit $ws @('init','-b','main')|Out-Null
Invoke-EnvelopeGit $ws @('config','user.name','Nonpass recovery fixture')|Out-Null
Invoke-EnvelopeGit $ws @('config','user.email','fixture@example.invalid')|Out-Null
Invoke-EnvelopeGit $ws @('config','core.autocrlf','false')|Out-Null
Invoke-EnvelopeGit $ws @('add','--all')|Out-Null
Invoke-EnvelopeGit $ws @('commit','-m','declare fixture custody storage before native admission and validation')|Out-Null
$seed.admission_template.unit|Add-Member -NotePropertyName work_mode -NotePropertyValue 'feature'
$seed.admission_template.unit|Add-Member -NotePropertyName claim_requirements -NotePropertyValue ([pscustomobject][ordered]@{minimum_free_disk_mib=1;required_tools=@();product_inputs=@()})
$admission=Join-Path $root 'admission.json';Write-EnvelopeJson $admission $seed.admission_template
Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $ws -DevelopmentUnitAdmission $admission -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admission) -OutPath (Join-Path $ws 'receipts/u002-admission.json') -Timestamp '2026-08-25T00:01:00.0000000Z' -Execute|Out-Null
foreach($action in @('Ready','Claim')){Invoke-RevisionAutomation $action @{Execute=$true}|Out-Null}
$freezeA=Join-Path $root 'freeze-a.json';Write-EnvelopeJson $freezeA (New-RevisionFreeze 'candidate-a')
Invoke-RevisionFreeze $freezeA -Execute|Out-Null
$script:revisionSelector=New-RevisionSelector 'candidate-a-selector'
$script:revisionMatrix=(Invoke-RevisionAutomation BeginValidation @{Execute=$true}).validation_matrix
$script:currentReceiptProducerRoot=$repoRoot
try{
    $preflight=New-RevisionValidation 'eligible-writer-preflight'
    $preflightReceipt=Read-EnvelopeProtocolJson (Join-Path $ws $preflight)
    $custody=@($preflightReceipt.artifacts|Where-Object artifact_id -CEQ 'nonpass-evidence-custody')[0]
    Assert-Envelope ([IO.File]::Exists((Join-Path $ws ('receipts/'+[string]$custody.path)))) 'eligible writer preflight lacks its actual immutable custody manifest'
    Invoke-EnvelopeGit $ws @('check-ignore','--quiet','--',('receipts/'+[string]$custody.path))|Out-Null
    Write-Host 'PASS actual eligible public writer and declared ignored immutable custody before old-writer defect and independent C.'
}finally{$script:currentReceiptProducerRoot=''}
$failed=New-RevisionValidation 'candidate-a-failure'
Invoke-RevisionAutomation ReturnToActive @{ValidationResult='fail';ValidationReceipt=$failed;Execute=$true}|Out-Null
$script:revisionSelector=$null
$beforeState=Read-EnvelopeProtocolJson (Join-Path $ws 'workspace.state.json')
$originalReceipt=[IO.File]::ReadAllBytes((Join-Path $ws $failed))
$fixtureOriginalPayloads=@(foreach($artifact in @((Read-EnvelopeProtocolJson (Join-Path $ws $failed)).artifacts|Where-Object{[string]$_.artifact_id-cin@('mutable-source','mutable-index')})){[pscustomobject]@{path=[string]$artifact.path;bytes=[IO.File]::ReadAllBytes([string]$artifact.path)}})
[IO.File]::WriteAllText((Join-Path $source 'morphospace/README.md'),"in-scope source correction; remains failing`n")
Invoke-EnvelopeGit $source @('add','morphospace/README.md')|Out-Null
Invoke-EnvelopeGit $source @('commit','-m','in-scope correction')|Out-Null
$freezeB=Join-Path $root 'freeze-b.json';Write-EnvelopeJson $freezeB (New-RevisionFreeze 'candidate-b' -Revision)
Assert-RevisionRefuses {Invoke-RevisionFreeze $freezeB -Execute} 'ordinary v3 after actual mutable source/index drift' 'evidence bytes drifted'
Assert-Envelope ([Convert]::ToBase64String($originalReceipt)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $ws $failed)))) 'fixture rewrote original failed receipt'
Write-Host 'PASS genuine old-writer Freeze/Begin/nonpass Return, actual source/index mutation, ordinary v3 strict no-write refusal.'
$recoveryModule=Join-Path $PSScriptRoot 'lib/MorphospaceNonpassCustodyCorrection.psm1'
Assert-Envelope ([IO.File]::Exists($recoveryModule)) 'closed native nonpass custody recovery consumer is absent'
Import-Module $recoveryModule -Force
function New-CustodyAnchor([string]$EventId){
    $intent="receipts/transactions/$EventId-transition.intent.json";$completion="receipts/transactions/$EventId-transition.completion.json"
    [ordered]@{event_id=$EventId;intent=[ordered]@{path=$intent;sha256=Get-EnvelopeFileSha256 (Join-Path $ws $intent)};completion=[ordered]@{path=$completion;sha256=Get-EnvelopeFileSha256 (Join-Path $ws $completion)}}
}
function New-RepeatedCustodyRequest([string]$Id,[object]$Template){
    $candidate=New-RevisionFreeze $Id -Revision;$candidate.schema='rusty.morphospace.workflow.candidate_freeze.v4'
    foreach($pair in @(@('project.spec.json','project_raw_sha256'),@('workspace.state.json','state_raw_sha256'),@('iteration-units/u002.json','unit_raw_sha256'),@('feature.lock.json','feature_lock_raw_sha256'))){$candidate.expected[$pair[1]]=Get-EnvelopeFileSha256 (Join-Path $ws $pair[0])}
    $state=Read-EnvelopeProtocolJson (Join-Path $ws 'workspace.state.json');$receiptPath=[string]$state.validation_checkpoint.receipt;$receipt=Read-EnvelopeProtocolJson (Join-Path $ws $receiptPath)
    $previous=Read-EnvelopeProtocolJson (Join-Path $ws ([string]$candidate.predecessor.freeze.receipt_path))
    $events=@(Get-Content (Join-Path $ws 'iteration-events.jsonl')|Where-Object{$_}|ConvertFrom-Json -DateKind String)
    $start=@($events|Where-Object event_id -CEQ "$($previous.freeze_id)-recorded")[0]
    $begins=@($events|Where-Object{[int]$_.sequence-gt[int]$start.sequence-and[string]$_.event_id-cmatch'^u002-validating-'})
    Assert-Envelope ($begins.Count-eq1) 'repeated v4 fixture does not have its one genuine Begin'
    $d=Copy-Envelope $Template.nonpass_custody_defect;$d.defect_id="$Id-custody-defect";$d.freeze=New-CustodyAnchor "$($previous.freeze_id)-recorded";$d.begin=New-CustodyAnchor ([string]$begins[0].event_id);$d.return=New-CustodyAnchor ([string]$state.last_event_id)
    $d.original_receipt=[pscustomobject]@{path=$receiptPath;sha256=Get-EnvelopeFileSha256 (Join-Path $ws $receiptPath);canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $receipt}
    $retained=[string]$candidate.predecessor.validation_receipt.path;$d.retained_receipt=[pscustomobject]@{path=$retained;sha256=Get-EnvelopeFileSha256 (Join-Path $ws $retained);canonical_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $ws $retained))}
    $d.result=[string]$receipt.result;$d.tier=[string]$receipt.tier;$d.frozen_repositories=@($previous.final_repositories)
    $d.artifacts=@(foreach($pair in @(@('mutable-source','mutable-source'),@('mutable-index','git-index'))){$artifacts=@($receipt.artifacts|Where-Object artifact_id -CEQ $pair[0]);Assert-Envelope ($artifacts.Count-eq1) 'repeated v4 fixture lacks a genuine legacy mutable artifact';$artifact=$artifacts[0];[pscustomobject]@{artifact_id=[string]$artifact.artifact_id;path=[string]$artifact.path;expected_sha256=[string]$artifact.sha256;artifact_class=$pair[1];repo_id='project-shell';observation=[pscustomobject]@{state='different';sha256=Get-EnvelopeFileSha256 ([string]$artifact.path)};observed_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');reason='An unmodified retained producer emitted literal mutable refs after an ordinary v3 candidate; the next actual in-scope source commit changed them.'}})
    $candidate['nonpass_custody_defect']=$d;$candidate['recovery_authorization']=Copy-Envelope $Template.recovery_authorization
    $candidate
}
$v4=Read-EnvelopeProtocolJson $freezeB;$v4.schema='rusty.morphospace.workflow.candidate_freeze.v4'
foreach($pair in @(@('project.spec.json','project_raw_sha256'),@('workspace.state.json','state_raw_sha256'),@('iteration-units/u002.json','unit_raw_sha256'),@('feature.lock.json','feature_lock_raw_sha256'))){$v4.expected|Add-Member $pair[1] (Get-EnvelopeFileSha256 (Join-Path $ws $pair[0]))}
$old=Read-EnvelopeProtocolJson (Join-Path $ws $failed)
$events=@(Get-Content (Join-Path $ws 'iteration-events.jsonl')|Where-Object{$_}|ConvertFrom-Json -DateKind String)
$begin=@($events|Where-Object event_id -Match '^u002-validating-')[0]
$retained=[string]$v4.predecessor.validation_receipt.path
$rows=@(foreach($pair in @(@('mutable-source','mutable-source'),@('mutable-index','git-index'))){
    $artifact=@($old.artifacts|Where-Object artifact_id -CEQ $pair[0])[0]
    [ordered]@{artifact_id=[string]$artifact.artifact_id;path=[string]$artifact.path;expected_sha256=[string]$artifact.sha256;artifact_class=$pair[1];repo_id='project-shell';observation=[ordered]@{state='different';sha256=Get-EnvelopeFileSha256 ([string]$artifact.path)};observed_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');reason='The old producer retained a mutable source/index reference; the actual in-scope source commit changed it.'}
})
$v4|Add-Member nonpass_custody_defect ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.nonpass_custody_defect.v1';defect_id='candidate-a-custody-defect';project_id='envelope-test';unit_id='u002';freeze=New-CustodyAnchor 'candidate-a-recorded';begin=New-CustodyAnchor ([string]$begin.event_id);return=New-CustodyAnchor ([string]$beforeState.last_event_id);original_receipt=[ordered]@{path=$failed;sha256=Get-EnvelopeFileSha256 (Join-Path $ws $failed);canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $old};retained_receipt=[ordered]@{path=$retained;sha256=Get-EnvelopeFileSha256 (Join-Path $ws $retained);canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $old};result='fail';tier='quick';receipt_schema='rusty.morphospace.workflow.validation_receipt.v1';frozen_repositories=@((Read-EnvelopeProtocolJson $freezeA).final_repositories);artifacts=$rows;audit_inert=$true;accepted=$false;historical_payload_preserved=$false;validation_credit=$false;acceptance_credit=$false;proof_reuse=$false;disposition='audit-inert-unavailable'})
$v4|Add-Member recovery_authorization ([pscustomobject]@{trusted_authority_root=(Join-Path $root 'unadopted-authority');authorization_path=(Join-Path $root 'unsigned-authorization.json');source_qualification_path=(Join-Path $root 'unqualified-source.json')})
$v4Path=Join-Path $root 'freeze-b-v4.json';Write-EnvelopeJson $v4Path $v4
$before=Get-EnvelopeWorkspaceByteInventorySha256 $ws
Assert-MorphospaceNonpassCustodyRequest -WorkspaceRoot $ws -RequestPath $v4Path
& (Join-Path $PSScriptRoot 'test-support/Test-NonpassWritablePathClass.ps1') -WorkspaceRoot $ws -RequestPath $v4Path
& (Join-Path $PSScriptRoot 'test-support/Test-NonpassReturnTuple.ps1') -WorkspaceRoot $ws -RequestPath $v4Path
Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) 'structural custody verification wrote workspace'
Write-Host 'PASS exact source/index defect structural verification grants no write or validation credit.'
foreach($damage in @('wrong-tuple','extra-defect','false-observation','wrong-class','unsafe-path','wrong-old-raw','PASS-target')){
    $changed=Copy-Envelope $v4
    switch($damage){
        'wrong-tuple'{$changed.nonpass_custody_defect.artifacts[0].expected_sha256='0'*64}
        'extra-defect'{$changed.nonpass_custody_defect.artifacts+=,$changed.nonpass_custody_defect.artifacts[0]}
        'false-observation'{$changed.nonpass_custody_defect.artifacts[0].observation.sha256='0'*64}
        'wrong-class'{$changed.nonpass_custody_defect.artifacts[0].artifact_class='git-index'}
        'unsafe-path'{$changed.nonpass_custody_defect.artifacts[0].path='../outside-source'}
        'wrong-old-raw'{$changed.nonpass_custody_defect.return.intent.sha256='0'*64}
        'PASS-target'{$changed.nonpass_custody_defect.result='pass'}
    }
    Write-EnvelopeJson $v4Path $changed
    Assert-RevisionRefuses {Assert-MorphospaceNonpassCustodyRequest -WorkspaceRoot $ws -RequestPath $v4Path} $damage
}
Write-EnvelopeJson $v4Path $v4
    $unitPath=Join-Path $ws 'iteration-units/u002.json';$saved=[IO.File]::ReadAllBytes($unitPath)
    try{$contexted=Read-EnvelopeProtocolJson $unitPath;$contexted|Add-Member tooling_context ([pscustomobject]@{path='unsupported-sealed-context.json'});Write-EnvelopeJson $unitPath $contexted;Assert-RevisionRefuses {Invoke-RevisionFreeze $v4Path -Execute} 'unsupported contexted v4 owner' 'supports only units without a sealed tooling context'}finally{[IO.File]::WriteAllBytes($unitPath,$saved)}
Assert-RevisionRefuses {Assert-MorphospaceHistoricalNonpassArtifacts -WorkspaceRoot $ws -ReceiptPath $failed -ReturnEventId ([string]$beforeState.last_event_id)} 'uncommitted request supplied no historical disposition'
Assert-RevisionRefuses {Assert-MorphospaceHistoricalNonpassArtifacts -WorkspaceRoot $ws -ReceiptPath $failed -ReturnEventId ([string]$beforeState.last_event_id) -RecoveryRequestPath $v4Path} 'public prospective waiver parameter'
Assert-RevisionRefuses {Invoke-RevisionFreeze $v4Path -Execute} 'unqualified independent native recovery authority'
Write-Host 'PASS exact tuple/class/raw-anchor/observation/PASS and unadopted-authority no-write refusals.'
. (Join-Path $repoRoot 'scripts/test-support/NativeNonpassRecoveryAuthorityFixture.ps1')
Invoke-EnvelopeGit $source @('remote','add','origin','https://github.com/example/nonpass-source-fixture.git')|Out-Null
Invoke-EnvelopeGit $ws @('add','--all')|Out-Null
Invoke-EnvelopeGit $ws @('commit','-m','retain genuine pre-correction owner bytes')|Out-Null
$executor=Join-Path $root 'authorized-executor'
[IO.Directory]::CreateDirectory($executor)|Out-Null
$files=@(Invoke-EnvelopeGit $repoRoot @('ls-files','--cached','--others','--exclude-standard'))
foreach($relative in $files){$from=Join-Path $repoRoot ([string]$relative);$to=Join-Path $executor ([string]$relative);if([IO.File]::Exists($from)){[IO.Directory]::CreateDirectory((Split-Path $to -Parent))|Out-Null;[IO.File]::Copy($from,$to,$false)}}
$authorityFixture=New-NativeNonpassRecoveryAuthorityFixture -AuthoritySourceRoot $AuthoritySourceRoot -ExecutorRoot $executor -FixtureRoot $root -RecoveryAdapterPath (Join-Path $repoRoot 'scripts/lib/MorphospaceNativeNonpassRecoveryAuthorization.psm1')
try{
    Set-NativeNonpassRecoveryFixtureAuthorization -Fixture $authorityFixture -WorkspaceRoot $ws -RequestPath $v4Path|Out-Null
    $freezeModule=Import-Module (Join-Path $executor 'scripts/CandidateFreeze.psm1') -Force -PassThru
    $automationModule=Import-Module (Join-Path $executor 'scripts/WorkUnitAutomation.psm1') -Force -PassThru
    $script:currentReceiptProducerRoot=$executor
    $originalWorkspace=$ws
    if($SourceScopeOnly){
        $scopePath=Join-Path $authorityFixture.authority_root 'scripts/lib/NativeNonpassRecoveryAuthority.psm1'
        $scopeLines=@(Get-Content -LiteralPath $scopePath)
        $scopeLine=1+[array]::FindIndex($scopeLines,[Predicate[string]]{param($line)$line.Contains('$rows=[Collections.Generic.List[object]]::new();$total=0L')})
        Assert-Envelope ($scopeLine-gt0) 'actual A source observation boundary is unavailable'
        $global:NonpassFixturePhysicalSourceObservations=0
        $scopeBreakpoint=Set-PSBreakpoint -Script $scopePath -Line $scopeLine -Action {$global:NonpassFixturePhysicalSourceObservations++}
        try{
            $snapshot=Get-EnvelopeWorkspaceByteInventorySha256 $ws
            Invoke-RevisionFreeze $v4Path|Out-Null
            Assert-Envelope ($snapshot-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) 'scoped dry run wrote native workspace'
            Assert-Envelope ($global:NonpassFixturePhysicalSourceObservations-eq2) 'scoped dry run repeated complete physical A/B source observations'
            Invoke-RevisionFreeze $v4Path -Execute|Out-Null
            Assert-Envelope ($global:NonpassFixturePhysicalSourceObservations-eq4) 'scoped executed v4 repeated complete physical A/B source observations'
            $snapshot=Get-EnvelopeWorkspaceByteInventorySha256 $ws
            Invoke-RevisionFreeze $v4Path -Execute|Out-Null
            Assert-Envelope ($snapshot-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) 'scoped completed replay wrote native workspace'
            Assert-Envelope ($global:NonpassFixturePhysicalSourceObservations-eq6) 'scoped completed replay repeated complete physical A/B source observations'
            foreach($leaf in @($scopePath,(Join-Path $executor 'scripts/CandidateFreeze.psm1'),$v4Path)){$released=[IO.File]::Open($leaf,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$released.Dispose()}
            Write-Host 'PASS genuine A/C and native v4 wrapper dry run, execution, exact completed replay and released source lifetime; six complete physical observations across three API calls.'
        }finally{Remove-PSBreakpoint -Breakpoint $scopeBreakpoint}
        return
    }
    $faults=if($ContinuationOnly){@()}else{@('after-intent','after-artifact','after-projection','after-event')}
    foreach($fault in $faults){
        $faultWorkspace=Join-Path $root "signed-recovery-$fault";Copy-Item -LiteralPath $originalWorkspace -Destination $faultWorkspace -Recurse
        $faultRequest=Join-Path $root "signed-recovery-$fault.json";[IO.File]::Copy($v4Path,$faultRequest,$false)
        try{
            $ws=$faultWorkspace
            Set-NativeNonpassRecoveryFixtureAuthorization -Fixture $authorityFixture -WorkspaceRoot $ws -RequestPath $faultRequest|Out-Null
            $caught=$null;try{Invoke-RevisionFreeze $faultRequest -Execute -Fault $fault|Out-Null}catch{$caught=$_}
            Assert-Envelope ($null-ne$caught-and$caught.Exception.Message-like'*Injected interruption*') "signed v4 did not reach $fault; actual failure: $caught"
            Invoke-RevisionFreeze $faultRequest -Execute|Out-Null
            $snapshot=Get-EnvelopeWorkspaceByteInventorySha256 $ws;Invoke-RevisionFreeze $faultRequest -Execute|Out-Null
            Assert-Envelope ($snapshot-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) "signed v4 $fault replay wrote another transaction"
        }finally{$ws=$originalWorkspace}
        Write-Host "PASS genuine signed v4 $fault recovery and completed exact replay."
        if($fault-ceq'after-intent'){
            & (Join-Path $PSScriptRoot 'test-support/Invoke-NonpassRetirementContinuation.ps1') -WorkspaceRoot $faultWorkspace -ExecutorRoot $executor -PreparationTemplatePath (Join-Path $root 'u002-envelope-preparation.json') -AdmissionTemplatePath (Join-Path $root 'admission.json') -FixtureRoot $root
        }
    }
    $oldPrefix=[IO.File]::ReadAllBytes((Join-Path $ws 'iteration-events.jsonl'))
    Invoke-RevisionFreeze $v4Path -Execute|Out-Null
    Assert-Envelope ([Convert]::ToBase64String($originalReceipt)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $ws $failed)))) 'authorized v4 changed original nonpass receipt'
    $newLedger=[IO.File]::ReadAllBytes((Join-Path $ws 'iteration-events.jsonl'));$prefix=[byte[]]::new($oldPrefix.Length);[Array]::Copy($newLedger,$prefix,$prefix.Length)
    Assert-Envelope ([Convert]::ToBase64String($oldPrefix)-ceq[Convert]::ToBase64String($prefix)) 'authorized v4 rewrote its prior ledger prefix'
    $after=Read-EnvelopeProtocolJson (Join-Path $ws 'workspace.state.json')
    Assert-Envelope ([string]$after.last_accepted_receipt-ceq[string]$beforeState.last_accepted_receipt) 'authorized v4 changed inherited accepted checkpoint'
    $authorizedRequest=Read-EnvelopeProtocolJson $v4Path;$authorizationPath=[string]$authorizedRequest.recovery_authorization.authorization_path;$authorizationBytes=[IO.File]::ReadAllBytes($authorizationPath)
    $latestPayloads=@(foreach($entry in $fixtureOriginalPayloads){[pscustomobject]@{path=$entry.path;bytes=[IO.File]::ReadAllBytes($entry.path)}})
    try{
        # A negative fixture only: temporarily restore genuinely saved input
        # bytes so strict payload equality cannot conceal a damaged C. This is
        # never recovery evidence, an invented index, or a production repair.
        foreach($entry in $fixtureOriginalPayloads){[IO.File]::WriteAllBytes($entry.path,$entry.bytes)}
        $damaged=Read-EnvelopeProtocolJson $authorizationPath;$damaged.payload.authorization_id='invalid-signature-fixture';Write-EnvelopeJson $authorizationPath $damaged
        $intent=Read-EnvelopeProtocolJson (Join-Path $ws 'receipts/transactions/candidate-b-recorded-transition.intent.json')
        Assert-RevisionRefuses {&$freezeModule {param($w,$i)Assert-MorphospaceCandidateRevisionRecoveryBindings $w $i -Historical} $ws $intent} 'damaged C with every old payload byte matching' 'signature verification failed'
    }finally{foreach($entry in $latestPayloads){[IO.File]::WriteAllBytes($entry.path,$entry.bytes)};[IO.File]::WriteAllBytes($authorizationPath,$authorizationBytes)}
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $ws;Invoke-RevisionFreeze $v4Path -Execute|Out-Null
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $ws)) 'completed authorized v4 replay wrote workspace'
    Write-Host 'PASS genuine signed independent A/source qualification and actual native v4; immutable receipt/prefix/accepted checkpoint and idempotent replay.'
    $script:revisionSelector=New-RevisionSelector 'candidate-b-selector'
    $script:revisionMatrix=(Invoke-RevisionAutomation BeginValidation @{Execute=$true}).validation_matrix
    $nextFailed=New-RevisionValidation 'candidate-b-real-failure'
    Invoke-RevisionAutomation ReturnToActive @{ValidationResult='fail';ValidationReceipt=$nextFailed;Execute=$true}|Out-Null
    $script:revisionSelector=$null
    [IO.File]::WriteAllText((Join-Path $source 'morphospace/README.md'),"second in-scope correction; remains failing`n")
    Invoke-EnvelopeGit $source @('add','morphospace/README.md')|Out-Null
    Invoke-EnvelopeGit $source @('commit','-m','real ordinary correction after v4')|Out-Null
    $freezeC=Join-Path $root 'freeze-c-v3.json';Write-EnvelopeJson $freezeC (New-RevisionFreeze 'candidate-c' -Revision)
    Invoke-RevisionFreeze $freezeC -Execute|Out-Null
    $script:revisionSelector=New-RevisionSelector 'candidate-c-selector'
    $script:revisionMatrix=(Invoke-RevisionAutomation BeginValidation @{Execute=$true}).validation_matrix
    # The unmodified published old writer recognizes this real v3 candidate.
    # It creates the second defect without a schema fork or hand-built receipt.
    $script:currentReceiptProducerRoot=''
    $legacyFailed=New-RevisionValidation 'candidate-c-legacy-failure'
    Invoke-RevisionAutomation ReturnToActive @{ValidationResult='fail';ValidationReceipt=$legacyFailed;Execute=$true}|Out-Null
    $script:revisionSelector=$null
    [IO.File]::WriteAllText((Join-Path $source 'morphospace/README.md'),"third in-scope correction; remains failing`n")
    Invoke-EnvelopeGit $source @('add','morphospace/README.md')|Out-Null;Invoke-EnvelopeGit $source @('commit','-m','demonstrate a second genuine mutable custody defect')|Out-Null
    $repeatPath=Join-Path $root 'freeze-d-v4.json';Write-EnvelopeJson $repeatPath (New-RepeatedCustodyRequest 'candidate-d' $v4)
    Set-NativeNonpassRecoveryFixtureAuthorization -Fixture $authorityFixture -WorkspaceRoot $ws -RequestPath $repeatPath|Out-Null
    $script:currentReceiptProducerRoot=$executor
    Invoke-RevisionFreeze $repeatPath -Execute|Out-Null
    Write-Host 'PASS repeated real v4 correction through ordinary v3 and an unmodified retained receipt producer; both exact inventories remain cumulative.'
    $script:revisionSelector=New-RevisionSelector 'candidate-d-selector';$script:revisionMatrix=(Invoke-RevisionAutomation BeginValidation @{Execute=$true}).validation_matrix
    $lastFailure=New-RevisionValidation 'candidate-d-immutable-failure';Invoke-RevisionAutomation ReturnToActive @{ValidationResult='fail';ValidationReceipt=$lastFailure;Execute=$true}|Out-Null
    $script:revisionSelector=$null
    [IO.File]::WriteAllText((Join-Path $source 'morphospace/README.md'),"corrected`n")
    Invoke-EnvelopeGit $source @('add','morphospace/README.md')|Out-Null;Invoke-EnvelopeGit $source @('commit','-m','final real source predicate correction')|Out-Null
    $freezeE=Join-Path $root 'freeze-e-v3.json';Write-EnvelopeJson $freezeE (New-RevisionFreeze 'candidate-e' -Revision);Invoke-RevisionFreeze $freezeE -Execute|Out-Null
    $script:revisionSelector=New-RevisionSelector 'candidate-e-selector';$script:revisionMatrix=(Invoke-RevisionAutomation BeginValidation @{Execute=$true}).validation_matrix
    $passed=New-RevisionValidation 'candidate-e-real-pass'
    Invoke-RevisionAutomation RecordValidation @{ValidationResult='pass';ValidationReceipt=$passed;Execute=$true}|Out-Null
    Invoke-RevisionAutomation Accept @{Execute=$true}|Out-Null
    Assert-Envelope ([string](Read-EnvelopeProtocolJson (Join-Path $ws 'iteration-units/u002.json')).status-ceq'accepted') 'ordinary post-v4 correction did not reach acceptance'
    $historyOwner=Import-Module (Join-Path $executor 'scripts/lib/MorphospaceCurrentWorkHistory.psm1') -PassThru;$history=&$historyOwner {param($w)Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $w} $ws
    Assert-Envelope (@($history.audit_only|Where-Object classification -CEQ 'nonpass-audit-inert-unavailable').Count-eq4) 'accepted-boundary current-work reader did not preserve both exact audit-only corrections'
    & (Join-Path $executor 'scripts/test-support/Test-NonpassHistoricalPayloadShape.ps1') -WorkspaceRoot $ws -ExecutorRoot $executor -RequestPath $v4Path -FixtureRoot $root -AllShapes -PassReceiptPath $passed
    Write-Host 'PASS actual v4 -> fresh Begin/real FAIL/Return -> ordinary v3 correction -> fresh real PASS/Record/Accept; historical mutable source/index changed again.'
}finally{$authorityFixture.rsa.Dispose()}
