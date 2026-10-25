param([switch]$SelfTest,[string]$ScratchRoot='',[ValidateSet('All','EligibilityRace','RollbackRace','Races','DefaultFeature','FrozenValidationOnly')][string]$Case='All')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if(-not $SelfTest){throw 'Test-NonpassReceiptEvidence requires -SelfTest.'}
$repository=Split-Path $PSScriptRoot -Parent
$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$transitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementContinuation.ps1')
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementFixture.ps1')
if(-not $ScratchRoot){$ScratchRoot=Join-Path ([IO.Path]::GetTempPath()) ('nonpass-custody-'+[guid]::NewGuid().ToString('N'))}
$null=[IO.Directory]::CreateDirectory($ScratchRoot)
if($Case-cin@('All','DefaultFeature')){
    # The shared public owner constructor deliberately omits work_mode here;
    # no admitted unit/native history is edited to manufacture this boundary.
    $seed=New-ActiveRetirementContinuationSeed -Root (Join-Path $ScratchRoot 'genuine-default') -RepositoryRoot $repository -SelfHostedReadOnlyPlanning
    $workspace=$seed.workspace;$planning=$seed.source_repository;$map=Join-Path $workspace 'repository-map.json';$unitPath=Join-Path $workspace 'iteration-units/u002.json'
    Assert-Envelope ((Read-EnvelopeProtocolJson $unitPath).PSObject.Properties.Name-cnotcontains'work_mode') 'default-feature fixture unexpectedly declared work_mode'
    [IO.File]::AppendAllText((Join-Path $planning '.git/info/exclude'),"`n/morphospace/receipts/*-evidence/`n",[Text.UTF8Encoding]::new($false))
    Invoke-EnvelopeGit $planning @('add','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','--allow-empty','-qm','Retain genuine default-feature Claim')|Out-Null
    $automation=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1';$common=@{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=$map;ValidationTier='quick'}
    $freezePath=Join-Path $ScratchRoot 'default-initial-freeze.json';$null=New-RetirementNonpassFreezeRequest $workspace $map $freezePath
    $null=&$automation @common -Action FreezeCandidate -CandidateFreeze $freezePath -ExpectedCandidateFreezeSha256 (Get-EnvelopeFileSha256 $freezePath) -OutPath (Join-Path $workspace 'receipts/u002-extension-freeze.json') -Timestamp '2026-08-25T00:00:44.0000000Z' -Execute
    $null=&$automation @common -Action BeginValidation -Timestamp '2026-08-25T00:00:45.0000000Z' -Execute
    $unit=Read-EnvelopeProtocolJson $unitPath;$owner=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru
    $matrix=@(&$owner {param($u)New-MorphospaceValidationMatrix -Unit $u -DeviceSerials @()} $unit)
    $source=Join-Path $seed.dependency_repository 'dependency/README.md';$index=(@(Invoke-EnvelopeGit $seed.dependency_repository @('rev-parse','--path-format=absolute','--git-path','index'))[0]).Trim()
    $evidence=[pscustomobject]@{receipt_id='u002-default-feature-failure';tier='quick';result='fail';artifacts=@([pscustomobject]@{artifact_id='source';kind='opaque-source';path=$source},[pscustomobject]@{artifact_id='index';kind='opaque-index';path=$index});criteria=@($unit.acceptance|ForEach-Object{[pscustomobject]@{acceptance_id=$_.acceptance_id;status='fail';command=$_.command;evidence_refs=@('source')}});gates=@($matrix|Where-Object disposition -CNE 'forbidden'|ForEach-Object{[pscustomobject]@{gate_id=$_.gate_id;status='fail';command=$_.command;evidence_refs=@('source')}});device_validation=$null}
    $productPath=Join-Path $ScratchRoot 'default-product-evidence.json';Write-EnvelopeJson $productPath $evidence
    $receiptPath=Join-Path $workspace 'receipts/default-feature-failure.json'
    $null=& (Join-Path $PSScriptRoot 'New-ValidationReceipt.ps1') -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath $map -EvidencePath $productPath -OutPath $receiptPath -CreatedAt '2026-08-25T00:00:46.0000000Z'
    $originalReceipt=[IO.File]::ReadAllBytes($receiptPath)
    $null=&$automation @common -Action ReturnToActive -ValidationReceipt 'receipts/default-feature-failure.json' -ValidationResult fail -Timestamp '2026-08-25T00:00:47.0000000Z' -Execute
    $state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$returnId=[string]$state.last_event_id;$retainedRelative="receipts/$returnId-retained-validation.json"
    $prefix=[IO.File]::ReadAllBytes((Join-Path $workspace 'iteration-events.jsonl'))
    Save-ActiveRetirementFixtureCheckpoint -Seed $seed -Message 'Retain genuine default-feature failure and Return'
    $sourceHash=Get-EnvelopeFileSha256 $source;$indexHash=Get-EnvelopeFileSha256 $index
    [IO.File]::AppendAllText($source,"`nReal default-feature in-scope correction.",[Text.UTF8Encoding]::new($false))
    Invoke-EnvelopeGit $seed.dependency_repository @('add','dependency/README.md')|Out-Null;Invoke-EnvelopeGit $seed.dependency_repository @('commit','-qm','Correct allowed source after genuine failure')|Out-Null
    Assert-Envelope ((Get-EnvelopeFileSha256 $source)-cne$sourceHash-and(Get-EnvelopeFileSha256 $index)-cne$indexHash) 'default-feature source/index bytes did not actually change'
    Write-Host 'Default-mode public producer/Return and actual allowed source/index change completed; exercising ordinary v3.'
    $retryPath=Join-Path $ScratchRoot 'default-ordinary-v3.json';$retry=New-RetirementNonpassFreezeRequest $workspace $map $retryPath
    $retry.schema='rusty.morphospace.workflow.candidate_freeze.v3';$retry.freeze_id='u002-default-feature-retry';$before=Read-EnvelopeProtocolJson $unitPath
    $retry|Add-Member -NotePropertyName predecessor -NotePropertyValue ([pscustomobject]@{freeze=Copy-Envelope $before.candidate_freeze;return_event_id=$returnId;validation_receipt=[pscustomobject]@{path=$retainedRelative;sha256=Get-EnvelopeFileSha256 (Join-Path $workspace $retainedRelative)}})
    Write-EnvelopeJson $retryPath $retry
    $null=&$automation @common -Action FreezeCandidate -CandidateFreeze $retryPath -ExpectedCandidateFreezeSha256 (Get-EnvelopeFileSha256 $retryPath) -OutPath (Join-Path $workspace 'receipts/u002-default-feature-retry.json') -Timestamp '2026-08-25T00:00:48.0000000Z' -Execute
    $after=Read-EnvelopeProtocolJson $unitPath
    Assert-Envelope ($after.candidate_freeze.freeze_id-ceq'u002-default-feature-retry'-and$after.PSObject.Properties.Name-cnotcontains'work_mode') 'ordinary v3 did not preserve default-feature ownership'
    Assert-Envelope ([Convert]::ToBase64String([IO.File]::ReadAllBytes($receiptPath))-ceq[Convert]::ToBase64String($originalReceipt)-and[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $workspace $retainedRelative)))-ceq[Convert]::ToBase64String($originalReceipt)) 'default-feature retry rewrote original or retained failure'
    $events=[IO.File]::ReadAllBytes((Join-Path $workspace 'iteration-events.jsonl'));Assert-Envelope ($events.Length-gt$prefix.Length-and[Convert]::ToBase64String([byte[]]$events[0..($prefix.Length-1)])-ceq[Convert]::ToBase64String($prefix)) 'ordinary v3 changed the actual event prefix'
    $receipt=Read-EnvelopeProtocolJson $receiptPath;$artifact=@($receipt.artifacts|Where-Object artifact_id -CEQ 'source')[0]
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1') -DisableNameChecking
    Assert-Envelope (Assert-MorphospaceNonpassEvidenceSnapshotBinding -WorkspaceRoot $workspace -ReceiptPath $receiptPath -Receipt $receipt -Artifact $artifact -ExpectedOriginPath $source -ExpectedOriginSha256 $sourceHash) 'default-feature retry lacks exact immutable source custody'
    Write-Host 'Default-feature genuine public writer/Return/change/ordinary v3 passed with immutable failure, retained receipt and event prefix.'
    if($Case-ceq'DefaultFeature'){return}
}
if($Case-cin@('All','FrozenValidationOnly')){
    # Use the existing genuine validation-only constructor and public admission;
    # empty write scope never becomes permission to change an observed source.
    $caseRoot=Join-Path $ScratchRoot 'genuine-validation-only'
    $seed=New-EnvelopeAdmissionPreparedFixture -Root $caseRoot -RepositoryRoot $repository -TransitionLedgerModule $transitionLedgerModule -OwnerProducedPreparation -NearestAgentInstructions -ValidationOnly
    $workspace=$seed.workspace;$planning=$caseRoot;$map=Join-Path $workspace 'repository-map.json';$automation=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'
    # The constructor keeps observed sources outside its control workspace.
    # Give that workspace its own private Git owner; observed source repos and
    # their empty admitted write scope remain byte-exact and unchanged.
    Invoke-EnvelopeGit $planning @('init','--quiet')|Out-Null;Invoke-EnvelopeGit $planning @('config','user.name','Custody fixture')|Out-Null;Invoke-EnvelopeGit $planning @('config','user.email','custody@example.invalid')|Out-Null;Invoke-EnvelopeGit $planning @('config','commit.gpgsign','false')|Out-Null;Invoke-EnvelopeGit $planning @('config','core.autocrlf','false')|Out-Null;Invoke-EnvelopeGit $planning @('config','core.longpaths','true')|Out-Null
    [IO.File]::WriteAllText((Join-Path $planning '.gitignore'),"/source-repo/`n/dependency-repo/`n/morphospace/receipts/*-evidence/`n",[Text.UTF8Encoding]::new($false));Invoke-EnvelopeGit $planning @('add','.gitignore')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-qm','Own private validation control storage')|Out-Null
    $admissionPath=Join-Path $caseRoot 'admission.json';Write-EnvelopeJson $admissionPath $seed.admission_template
    $null=&$automation -Action AdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts/u002-admission.json') -Timestamp '2026-08-25T00:00:40.0000000Z' -Execute
    $common=@{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=$map;ValidationTier='quick'}
    $null=&$automation @common -Action Ready -Timestamp '2026-08-25T00:00:41.0000000Z' -Execute
    $null=&$automation @common -Action Claim -Timestamp '2026-08-25T00:00:42.0000000Z' -Execute
    $unitPath=Join-Path $workspace 'iteration-units/u002.json';$unit=Read-EnvelopeProtocolJson $unitPath
    Assert-Envelope ($unit.work_mode-ceq'validation-only'-and@($unit.allowed_repositories[0].allowed_paths).Count-eq0) 'genuine validation-only admission lost its empty write scope'
    $freezePath=Join-Path $ScratchRoot 'validation-only-freeze.json';$null=New-RetirementNonpassFreezeRequest $workspace $map $freezePath
    $null=&$automation @common -Action FreezeCandidate -CandidateFreeze $freezePath -ExpectedCandidateFreezeSha256 (Get-EnvelopeFileSha256 $freezePath) -OutPath (Join-Path $workspace 'receipts/u002-extension-freeze.json') -Timestamp '2026-08-25T00:00:44.0000000Z' -Execute
    $null=&$automation @common -Action BeginValidation -Timestamp '2026-08-25T00:00:45.0000000Z' -Execute
    $unit=Read-EnvelopeProtocolJson $unitPath;$owner=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru
    $matrix=@(&$owner {param($u)New-MorphospaceValidationMatrix -Unit $u -DeviceSerials @()} $unit)
    $opaqueInput=Join-Path $ScratchRoot 'validation-only-opaque.bin';[IO.File]::WriteAllBytes($opaqueInput,[Text.Encoding]::UTF8.GetBytes('Separate mutable opaque failure input; no source-write authority.'))
    $evidence=[pscustomobject]@{receipt_id='u002-validation-only-failure';tier='quick';result='fail';artifacts=@([pscustomobject]@{artifact_id='failure-input';kind='opaque-input';path=$opaqueInput});criteria=@($unit.acceptance|ForEach-Object{[pscustomobject]@{acceptance_id=$_.acceptance_id;status='fail';command=$_.command;evidence_refs=@('failure-input')}});gates=@($matrix|Where-Object disposition -CNE 'forbidden'|ForEach-Object{[pscustomobject]@{gate_id=$_.gate_id;status='fail';command=$_.command;evidence_refs=@('failure-input')}});device_validation=$null}
    $productPath=Join-Path $ScratchRoot 'validation-only-product.json';Write-EnvelopeJson $productPath $evidence
    $receiptPath=Join-Path $workspace 'receipts/validation-only-failure.json'
    $null=& (Join-Path $PSScriptRoot 'New-ValidationReceipt.ps1') -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath $map -EvidencePath $productPath -OutPath $receiptPath -CreatedAt '2026-08-25T00:00:46.0000000Z'
    $receiptBytes=[IO.File]::ReadAllBytes($receiptPath);$accepted=(Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')).last_accepted_receipt
    $inventory=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$message=''
    try{$null=&$automation @common -Action ReturnToActive -ValidationReceipt 'receipts/validation-only-failure.json' -ValidationResult fail -Timestamp '2026-08-25T00:00:46.5000000Z' -Execute}catch{$message=$_.Exception.Message}
    Assert-Envelope ($message-like'*ReturnToActive is available only to feature units*'-and$inventory-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) 'validation-only Return exclusion changed or wrote owner bytes'
    $null=&$automation @common -Action RecordValidation -ValidationReceipt 'receipts/validation-only-failure.json' -ValidationResult fail -Timestamp '2026-08-25T00:00:47.0000000Z' -Execute
    $null=&$automation @common -Action Resume -Timestamp '2026-08-25T00:00:48.0000000Z' -Execute
    $state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$heads=@();$sources=@()
    foreach($entry in @((Read-EnvelopeProtocolJson $map).repositories)){
        $heads+=,[pscustomobject]@{repo_id=$entry.repo_id;revision=(@(Invoke-EnvelopeGit $entry.path @('rev-parse','HEAD'))[0]).Trim();branch=(@(Invoke-EnvelopeGit $entry.path @('branch','--show-current'))-join'').Trim()}
        $relative=if($entry.repo_id-ceq'project-shell'){'morphospace/README.md'}else{'dependency/README.md'}
        $sources+=,[pscustomobject]@{repo_id=$entry.repo_id;sources=@([pscustomobject]@{path=$relative;sha256=Get-EnvelopeFileSha256 (Join-Path $entry.path $relative)})}
    }
    $resolution=[pscustomobject]@{schema='rusty.morphospace.workflow.blocker_resolution_receipt.v1';receipt_id='u002-validation-only-disposition';project_id=$state.project_id;unit_id='u002';blocker=$state.blockers[0];result='pass';evidence=@([pscustomobject]@{path='receipts/validation-only-failure.json';sha256=Get-EnvelopeFileSha256 $receiptPath});repository_heads=$heads;repository_sources=$sources;preserve_blocker_ids=@()}
    $resolutionPath=Join-Path $ScratchRoot 'validation-only-resolution-input.json';Write-EnvelopeJson $resolutionPath $resolution
    $null=&$automation @common -Action ResolveBlocker -BlockerResolutionReceipt $resolutionPath -OutPath (Join-Path $workspace 'receipts/validation-only-resolution.json') -Timestamp '2026-08-25T00:00:49.0000000Z' -Execute
    Invoke-EnvelopeGit $planning @('add','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-qm','Retain genuine validation-only failure scope disposition')|Out-Null
    $request=New-ActiveUnitRetirementRequest -WorkspaceRoot $workspace -RepoMapPath $map -RetirementId 'retire-validation-only' -ReplacementUnitId u003
    $requestPath=Join-Path $ScratchRoot 'validation-only-retirement-input.json';Write-EnvelopeJson $requestPath $request
    $null=&$automation -Action RetireActive -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath $map -ActiveUnitRetirement $requestPath -ExpectedActiveUnitRetirementSha256 (Get-EnvelopeFileSha256 $requestPath) -OutPath (Join-Path $workspace 'receipts/retire-validation-only.json') -Timestamp '2026-08-25T00:00:50.0000000Z' -Execute
    $historyOwner=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkHistory.psm1') -PassThru
    $null=&$historyOwner {param($w)Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $w -RequireIdle} $workspace
    $retirementOwner=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
    $recordReplay={param($w,$owner)&$owner {
        param($root)
        $record=@((Get-ActiveRetirementEvents $root).events|Where-Object{[string]$_.event_id-cmatch'^u002-validation-fail-[0-9]{4,}$'})
        if($record.Count-ne1){throw 'Validation-only fixture lacks its unique real RecordFAIL event.'}
        $proof=Get-ActiveRetirementPlanningTransition $root "$($record[0].event_id)-transition"
        Assert-ActiveRetirementRetainedLifecycle $root $record[0] $proof
    } $w}
    $null=&$recordReplay $workspace $retirementOwner
    $inventory=Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    [IO.File]::AppendAllText($opaqueInput,' A separate actor reused its mutable input.',[Text.UTF8Encoding]::new($false))
    Write-Host 'Genuine frozen validation-only producer/RecordFAIL/Resume/Resolve/Retire completed; opaque input changed without source mutation.'
    $null=&$recordReplay $workspace $retirementOwner
    $history=&$historyOwner {param($w)Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $w -RequireIdle} $workspace
    Assert-Envelope ($history.authenticated-and$history.retired_active_ids.Contains('u002')-and$inventory-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) 'validation-only historical custody failed or wrote owner bytes'
    $produced=Read-EnvelopeProtocolJson $receiptPath
    Assert-Envelope ($produced.artifacts[0].path-ceq'u002-validation-only-failure-evidence/0000-failure-input.bin') 'frozen validation-only public producer retained a mutable opaque reference'
    $state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')
    Assert-Envelope ($state.last_accepted_receipt-ceq$accepted-and[Convert]::ToBase64String([IO.File]::ReadAllBytes($receiptPath))-ceq[Convert]::ToBase64String($receiptBytes)-and(Read-EnvelopeProtocolJson $unitPath).work_mode-ceq'validation-only') 'validation-only retirement changed acceptance, receipt bytes or mode'
    Write-Host 'Frozen validation-only immutable NONPASS custody survived actual historical retirement replay; Return exclusion preserved.'
    if($Case-ceq'FrozenValidationOnly'){return}
}
$seed=New-ActiveRetirementContinuationSeed -Root (Join-Path $ScratchRoot 'genuine') -RepositoryRoot $repository -SelfHostedReadOnlyPlanning -FeatureWorkMode
$workspace=$seed.workspace;$planning=$seed.source_repository;$map=Join-Path $workspace 'repository-map.json'
# The fixture owner establishes private storage policy before the writer runs.
[IO.File]::AppendAllText((Join-Path $planning '.git/info/exclude'),"`n/morphospace/receipts/*-evidence/`n/morphospace/local/`n",[Text.UTF8Encoding]::new($false))
$defaultMap=$map
$unfrozenUnitBytes=[IO.File]::ReadAllBytes((Join-Path $workspace 'iteration-units/u002.json'))
Invoke-EnvelopeGit $planning @('add','morphospace')|Out-Null
Invoke-EnvelopeGit $planning @('commit','--allow-empty','-qm','Modeled custody Claim checkpoint')|Out-Null
$freeze=Join-Path $ScratchRoot 'freeze.json';$null=New-RetirementNonpassFreezeRequest $workspace $map $freeze
$automation=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'
$common=@{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=$map;ValidationTier='quick'}
$null=&$automation @common -Action FreezeCandidate -CandidateFreeze $freeze -ExpectedCandidateFreezeSha256 (Get-EnvelopeFileSha256 $freeze) -OutPath (Join-Path $workspace 'receipts/u002-extension-freeze.json') -Timestamp '2026-08-25T00:00:44.0000000Z' -Execute
$null=&$automation @common -Action BeginValidation -Timestamp '2026-08-25T00:00:45.0000000Z' -Execute
$unit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json')
$owner=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru
$matrix=@(&$owner {param($u)New-MorphospaceValidationMatrix -Unit $u -DeviceSerials @()} $unit)
$source=Join-Path $seed.dependency_repository 'dependency/README.md'
$index=(@(Invoke-EnvelopeGit $planning @('rev-parse','--path-format=absolute','--git-path','index'))[0]).Trim()
# Capture an actual failing child through the existing raw-stream owner.
$captureOwner=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceRetainedBuildProcess.psm1') -PassThru
$childBase=Join-Path $ScratchRoot 'actual-failure'
$childEnvironment=@{};foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()){$childEnvironment[[string]$entry.Key]=[string]$entry.Value}
$execution=[pscustomobject]@{FileName=(Get-Process -Id $PID).Path;WorkingDirectory=$ScratchRoot;Arguments=@('-NoProfile','-NonInteractive','-Command','[Console]::Out.Write("modeled stdout");[Console]::Error.Write("modeled stderr");exit 9')}
$capture=&$captureOwner {param($e,$envs,$p)Invoke-MorphospaceRetainedBuildProcess -Execution $e -EnvironmentValues $envs -BaseReceiptPath $p -EstimatedWarningSeconds 60} $execution $childEnvironment $childBase
Assert-Envelope ($capture.ExitCode-eq9-and$capture.ChildProcess.process_reaped-and$capture.ChildProcess.raw_capture_complete-and$capture.ChildProcess.stdout_eof-and$capture.ChildProcess.stderr_eof) 'actual failed child was not reaped with both raw EOFs'
Write-EnvelopeJson ($childBase+'.terminal.json') $capture
$evidence=[pscustomobject]@{receipt_id='u002-custody-fail';tier='quick';result='fail';artifacts=@([pscustomobject]@{artifact_id='source';kind='opaque-source';path=$source},[pscustomobject]@{artifact_id='index';kind='opaque-index';path=$index});criteria=@($unit.acceptance|ForEach-Object{[pscustomobject]@{acceptance_id=$_.acceptance_id;status='fail';command=$_.command;evidence_refs=@('source')}});gates=@($matrix|Where-Object disposition -CNE 'forbidden'|ForEach-Object{[pscustomobject]@{gate_id=$_.gate_id;status='fail';command=$_.command;evidence_refs=@('source')}});device_validation=$null}
$rawInputs=[ordered]@{bom=[byte[]]@(239,187,191,97);binary=[byte[]]@(0,1,0,255,128);crlf=[byte[]]@(97,13,10,98,13,10);empty=[byte[]]@();opaque=[Text.UTF8Encoding]::new($false).GetBytes('{"path":"never-read-missing-nested-file"}')}
foreach($name in $rawInputs.Keys){$path=Join-Path $ScratchRoot ($name+'.raw');[IO.File]::WriteAllBytes($path,$rawInputs[$name]);$evidence.artifacts+=,[pscustomobject]@{artifact_id=$name;kind='opaque-raw';path=$path}}
$largePath=Join-Path $ScratchRoot 'large.raw';$largeBytes=[byte[]]::new(16777217);$largeBytes[0]=255;$largeBytes[-1]=128;[IO.File]::WriteAllBytes($largePath,$largeBytes)
$evidence.artifacts+=,[pscustomobject]@{artifact_id='large';kind='opaque-raw';path=$largePath}
foreach($name in @('stdout','stderr','terminal')){$suffix=if($name-eq'terminal'){'.terminal.json'}else{".$name.bin"};$evidence.artifacts+=,[pscustomobject]@{artifact_id=$name;kind='opaque-child';path=$childBase+$suffix}}
$evidence.gates[0].evidence_refs=@('source','index')
$evidencePath=Join-Path $ScratchRoot 'evidence.json';Write-EnvelopeJson $evidencePath $evidence
$output=Join-Path $workspace 'receipts/custody-fail.json'
$null=& (Join-Path $PSScriptRoot 'New-ValidationReceipt.ps1') -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath $map -EvidencePath $evidencePath -OutPath $output -CreatedAt '2026-08-25T00:00:46.0000000Z'
$receipt=Read-EnvelopeProtocolJson $output
$artifact=@($receipt.artifacts|Where-Object artifact_id -CEQ 'source')[0]
Assert-Envelope ($artifact.path -ceq 'u002-custody-fail-evidence/0000-source.bin') 'NONPASS writer must replace mutable source reference with its owned raw snapshot'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1') -DisableNameChecking
$manifestPath=Join-Path $workspace 'receipts/u002-custody-fail-evidence/custody.json'
$manifest=Read-EnvelopeProtocolJson $manifestPath
Assert-Envelope (@($receipt.artifacts).Count-eq@($evidence.artifacts).Count+1) 'custody changed caller artifact count beyond its reserved manifest'
for($i=0;$i-lt$evidence.artifacts.Count;$i++){
    $before=$evidence.artifacts[$i];$after=$receipt.artifacts[$i];$row=$manifest.artifacts[$i]
    $snapshot=Join-Path $workspace $row.snapshot_path
    Assert-Envelope ($after.artifact_id-ceq$before.artifact_id-and$after.kind-ceq$before.kind-and$row.original_path-ceq$before.path) 'artifact identity/kind/origin was rewritten'
    Assert-Envelope ([Convert]::ToBase64String([IO.File]::ReadAllBytes($before.path))-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes($snapshot))-and(Get-Item -LiteralPath $snapshot).Length-eq$row.byte_length) 'snapshot changed raw bytes or length'
}
Assert-Envelope (($receipt.criteria|ConvertTo-Json -Depth 100)-ceq($evidence.criteria|ConvertTo-Json -Depth 100)-and($receipt.gates|ConvertTo-Json -Depth 100)-ceq($evidence.gates|ConvertTo-Json -Depth 100)-and$receipt.result-ceq'fail') 'NONPASS statuses, commands or evidence references changed'
Assert-Envelope (Assert-MorphospaceNonpassEvidenceSnapshotBinding -WorkspaceRoot $workspace -ReceiptPath $output -Receipt $receipt -Artifact $artifact -ExpectedOriginPath $source -ExpectedOriginSha256 $artifact.sha256) 'exact actual origin binding was not recognized'
Assert-Envelope (-not(Assert-MorphospaceNonpassEvidenceSnapshotBinding -WorkspaceRoot $workspace -ReceiptPath $output -Receipt $receipt -Artifact $receipt.artifacts[1] -ExpectedOriginPath $source -ExpectedOriginSha256 $artifact.sha256)) 'unrelated valid evidence matched selector origin'
Assert-Envelope (-not(Assert-MorphospaceNonpassEvidenceSnapshotBinding -WorkspaceRoot $workspace -ReceiptPath $output -Receipt $receipt -Artifact $artifact -ExpectedOriginPath $source -ExpectedOriginSha256 ('0'*64))) 'wrong origin hash matched'
$heldDefaultMap=Join-Path $ScratchRoot 'held-default-map.json';[IO.File]::Move($defaultMap,$heldDefaultMap)
try{Assert-Envelope (Assert-MorphospaceNonpassEvidenceSnapshotBinding -WorkspaceRoot $workspace -ReceiptPath $output -Receipt $receipt -Artifact $artifact -ExpectedOriginPath $source -ExpectedOriginSha256 $artifact.sha256) 'custody reader depended on a default or planning-role map'}finally{[IO.File]::Move($heldDefaultMap,$defaultMap)}

function Assert-CustodyRefusal([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Assert-Envelope $failed $Message}
function Invoke-CustodyWriter([object]$Product,[string]$Path){New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath $map -Evidence $Product -OutPath $Path -CreatedAt '2026-08-25T00:00:46.0000000Z'}
function Assert-CustodyWriterRefusal([object]$Product,[string]$Name,[string]$Path=''){
    if(-not$Path){$Path=Join-Path $workspace "receipts/$Name.json"}
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    Assert-CustodyRefusal {Invoke-CustodyWriter $Product $Path} "writer accepted $Name"
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) "refusal $Name changed owner bytes"
}
if($Case -cin @('All','EligibilityRace','Races')){
    # A real pre-Freeze unit read completes across the writer boundary while
    # the actual workspace already has its genuine Freeze/Begin bytes. No unit,
    # receipt or ledger is fabricated or edited to manufacture a positive.
    $racing=Copy-Envelope $evidence;$racing.receipt_id='u002-eligibility-race';$racing.artifacts=@($racing.artifacts[0],$racing.artifacts[1])
    $raceOutput=Join-Path $workspace 'receipts/eligibility-race.json'
    $guard=&$protocolModule {param($w)Enter-MorphospaceWorkspaceMutex $w} $workspace
    $cloneDone=[Threading.ManualResetEventSlim]::new($false);$unitRead=[Threading.ManualResetEventSlim]::new($false);$unitResume=[Threading.ManualResetEventSlim]::new($false);$lockReleased=[Threading.ManualResetEventSlim]::new($false)
    $worker=[powershell]::Create()
    $null=$worker.AddScript({param($scriptRoot,$w,$map,$product,$output,$oldUnit,$cloneDone,$unitRead,$unitResume,$released)
        $receiptOwner=Import-Module (Join-Path $scriptRoot 'lib/MorphospaceValidationReceipt.psm1') -PassThru -DisableNameChecking
        &$receiptOwner {
            param($unitPath,$oldUnit,$cloneDone,$unitRead,$unitResume,$released)
            $script:RaceOriginalCopy=(Get-Command Copy-MorphospaceValidationReceiptValue).ScriptBlock
            $script:RaceUnitPath=$unitPath;$script:RaceOldUnit=[Text.Encoding]::UTF8.GetString($oldUnit);$script:RaceCloneDone=$cloneDone;$script:RaceUnitRead=$unitRead;$script:RaceUnitResume=$unitResume;$script:RaceReleased=$released;$script:RaceFirstCopy=$true;$script:RaceFirstUnit=$true
            function script:Copy-MorphospaceValidationReceiptValue {
                param([AllowNull()][object]$Value)
                $copy=&$script:RaceOriginalCopy $Value
                if($script:RaceFirstCopy){$script:RaceFirstCopy=$false;$script:RaceCloneDone.Set()}
                return $copy
            }
            function script:Get-Content {
                param([string]$LiteralPath,[switch]$Raw)
                if($script:RaceFirstUnit-and$LiteralPath-eq$script:RaceUnitPath){
                    $script:RaceFirstUnit=$false;$script:RaceUnitRead.Set()
                    if(-not$script:RaceReleased.IsSet){$script:RaceUnitResume.Wait();return $script:RaceOldUnit}
                }
                Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
            }
        } (Join-Path $w 'iteration-units/u002.json') $oldUnit $cloneDone $unitRead $unitResume $released
        try{New-MorphospaceValidationReceiptV1 -WorkspaceRoot $w -UnitId u002 -RepoMapPath $map -Evidence $product -OutPath $output -CreatedAt '2026-08-25T00:00:46.0000000Z'}
        finally{&$receiptOwner {Set-Item Function:script:Copy-MorphospaceValidationReceiptValue -Value $script:RaceOriginalCopy;Remove-Item Function:script:Get-Content}}
    }).AddArgument($PSScriptRoot).AddArgument($workspace).AddArgument($map).AddArgument($racing).AddArgument($raceOutput).AddArgument($unfrozenUnitBytes).AddArgument($cloneDone).AddArgument($unitRead).AddArgument($unitResume).AddArgument($lockReleased)
    $handle=$worker.BeginInvoke()
    try{
        Assert-Envelope ($cloneDone.Wait(30000)) 'interleaved producer did not clone caller evidence'
        # The caller remains mutable while the writer waits; its private clone
        # must preserve the originally selected evidence and receipt identity.
        $racing.receipt_id='u002-mutated-after-clone'
        $readBeforeRelease=$unitRead.Wait(10000)
        $unitResume.Set()
        $completedBeforeRelease=if($readBeforeRelease){$handle.AsyncWaitHandle.WaitOne(15000)}else{$false}
        $publishedBeforeRelease=[IO.File]::Exists($raceOutput)
    }finally{
        $lockReleased.Set();$unitResume.Set();&$protocolModule {param($g)Exit-MorphospaceWorkspaceMutex $g} $guard
        try{$null=$worker.EndInvoke($handle);if($worker.HadErrors){throw ($worker.Streams.Error|Out-String)}}finally{$worker.Dispose();$cloneDone.Dispose();$unitRead.Dispose();$unitResume.Dispose();$lockReleased.Dispose()}
    }
    Assert-Envelope (-not$readBeforeRelease-and-not$completedBeforeRelease-and-not$publishedBeforeRelease) 'NONPASS eligibility read escaped the owner mutex across a genuine unfrozen-to-frozen boundary'
    $raceReceipt=Read-EnvelopeProtocolJson $raceOutput
    Assert-Envelope ($raceReceipt.receipt_id-ceq'u002-eligibility-race'-and$raceReceipt.artifacts[0].path-ceq'u002-eligibility-race-evidence/0000-source.bin') 'caller mutation replaced the private evidence clone'
    Write-Host 'Interleaved genuine unit reads and mutable caller evidence stayed behind the NONPASS owner mutex.'
}
if($Case -cin @('All','RollbackRace','Races')){
    if(-not('NonpassTestReplacementOnDispose'-as[type])){
        Add-Type -TypeDefinition @'
using System.IO;
public sealed class NonpassTestReplacementOnDispose : MemoryStream {
  public string TargetPath, RetainedPath;
  public byte[] Replacement;
  public bool Replaced;
  protected override void Dispose(bool disposing) {
    base.Dispose(disposing);
    if(disposing && !Replaced) {
      File.Move(TargetPath, RetainedPath);
      File.WriteAllBytes(TargetPath, Replacement);
      Replaced=true;
    }
  }
}
'@
    }
    $lateFailure=Copy-Envelope $evidence;$lateFailure.receipt_id='u002-late-failure';$lateFailure.artifacts=@($lateFailure.artifacts[0],$lateFailure.artifacts[1])
    $replacement=[NonpassTestReplacementOnDispose]::new();$replacement.TargetPath=Join-Path $workspace 'receipts/u002-late-failure-evidence/0000-source.bin';$replacement.RetainedPath=Join-Path $ScratchRoot 'actor-retained-original-snapshot.bin';$replacement.Replacement=[Text.Encoding]::UTF8.GetBytes('Another actor owns these replacement bytes.')
    $receiptOwner=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1') -PassThru -DisableNameChecking
    &$receiptOwner {
        param($boundary)
        $script:RaceOriginalCustody=(Get-Command New-MorphospaceNonpassEvidenceCustody).ScriptBlock;$script:RaceCleanupBoundary=$boundary
        function script:New-MorphospaceNonpassEvidenceCustody {
            param([string]$Workspace,[string]$Output,[object]$Receipt,[object]$Owned)
            &$script:RaceOriginalCustody @PSBoundParameters
            # The callback is last: it replaces the path only after all actual
            # source/copy ownership handles have closed in the real rollback.
            $Owned.handles.Add($script:RaceCleanupBoundary)
            throw [IO.IOException]::new('Modeled late I/O failure after genuine custody capture.')
        }
    } $replacement
    try{Assert-CustodyRefusal {Invoke-CustodyWriter $lateFailure (Join-Path $workspace 'receipts/late-failure.json')} 'late I/O boundary did not refuse publication'}
    finally{&$receiptOwner {Set-Item Function:script:New-MorphospaceNonpassEvidenceCustody -Value $script:RaceOriginalCustody}}
    Assert-Envelope ($replacement.Replaced) 'controlled replacement boundary did not execute after handle release'
    Assert-Envelope ([IO.File]::Exists($replacement.TargetPath)-and[Convert]::ToBase64String([IO.File]::ReadAllBytes($replacement.TargetPath))-ceq[Convert]::ToBase64String($replacement.Replacement)) 'rollback deleted another actor replacement after releasing ownership handles'
    Assert-CustodyWriterRefusal $lateFailure 'preserved-late-failure' (Join-Path $workspace 'receipts/late-failure.json')
    Write-Host 'Late I/O rollback preserved the actual replacement and refused conflicting reuse.'
}
if($Case-cne'All'){Write-Host "NONPASS focused $Case passed.";return}
# Exercise actual existing owner lock contention, with a second runspace calling
# the public writer. Always release and join that original worker before checks.
$serialized=Copy-Envelope $evidence;$serialized.receipt_id='u002-serialized';$serialized.artifacts=@($serialized.artifacts[0],$serialized.artifacts[1])
$serializedOutput=Join-Path $workspace 'receipts/serialized.json'
$guard=&$protocolModule {param($w)Enter-MorphospaceWorkspaceMutex $w} $workspace
$worker=[powershell]::Create();$started=[Threading.ManualResetEventSlim]::new($false)
$null=$worker.AddScript({param($scriptRoot,$w,$map,$product,$output,$started)
    Import-Module (Join-Path $scriptRoot 'lib/MorphospaceValidationReceipt.psm1') -DisableNameChecking
    $started.Set()
    New-MorphospaceValidationReceiptV1 -WorkspaceRoot $w -UnitId u002 -RepoMapPath $map -Evidence $product -OutPath $output -CreatedAt '2026-08-25T00:00:46.0000000Z'
}).AddArgument($PSScriptRoot).AddArgument($workspace).AddArgument($map).AddArgument($serialized).AddArgument($serializedOutput).AddArgument($started)
$handle=$worker.BeginInvoke()
try{
    Assert-Envelope ($started.Wait(30000)) 'contending producer did not enter its public writer'
    $premature=$handle.AsyncWaitHandle.WaitOne(15000)
    $prematureOutput=[IO.File]::Exists($serializedOutput)
}finally{
    &$protocolModule {param($g)Exit-MorphospaceWorkspaceMutex $g} $guard
    try{$null=$worker.EndInvoke($handle);if($worker.HadErrors){throw ($worker.Streams.Error|Out-String)}}finally{$worker.Dispose();$started.Dispose()}
}
Assert-Envelope (-not$premature-and-not$prematureOutput-and[IO.File]::Exists($serializedOutput)) 'NONPASS producer bypassed existing owner lock or failed after release'
foreach($damage in @('missing-second','duplicate-id','reserved-id','typed-closure','invalid-status','source-alias','output-alias','nested-output')){
    $bad=Copy-Envelope $evidence;$bad.receipt_id='u002-'+$damage;$path=''
    switch($damage){
        'missing-second'{$bad.artifacts[1].path=Join-Path $ScratchRoot 'missing.raw'}
        'duplicate-id'{$bad.artifacts[1].artifact_id='source'}
        'reserved-id'{$bad.artifacts[1].artifact_id='nonpass-evidence-custody'}
        'typed-closure'{$bad.artifacts[-1].kind='source-delivery-landing'}
        'invalid-status'{$bad.criteria[0].status='invalid'}
        'source-alias'{$bad.artifacts[0].path=$source+':alternate'}
        'output-alias'{$path=Join-Path $workspace 'receipts/alias.json.'}
        'nested-output'{$path=Join-Path $workspace 'receipts/nested/failure.json'}
    }
    Assert-CustodyWriterRefusal $bad $damage $path
}
$bad=Copy-Envelope $evidence;$bad.receipt_id='u002-locked-source'
$locked=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{Assert-CustodyWriterRefusal $bad 'locked-source'}finally{$locked.Dispose()}
if($IsWindows){
    $target=Join-Path $ScratchRoot 'junction-target';$null=[IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'source.raw'),'Fixture target must remain untouched.')
    $junction=Join-Path $ScratchRoot 'source-junction';$null=New-Item -ItemType Junction -Path $junction -Target $target
    try{$bad=Copy-Envelope $evidence;$bad.receipt_id='u002-source-reparse';$bad.artifacts[0].path=Join-Path $junction 'source.raw';Assert-CustodyWriterRefusal $bad 'source-reparse'}finally{[IO.Directory]::Delete($junction,$false)}
    $junction=Join-Path $workspace 'receipts/u002-destination-reparse-evidence';$null=New-Item -ItemType Junction -Path $junction -Target $target
    try{$bad=Copy-Envelope $evidence;$bad.receipt_id='u002-destination-reparse';Assert-CustodyWriterRefusal $bad 'destination-reparse'}finally{[IO.Directory]::Delete($junction,$false)}
    Assert-Envelope ([IO.File]::ReadAllText((Join-Path $target 'source.raw'))-ceq'Fixture target must remain untouched.') 'reparse refusal altered external target'
}
$exclude=Join-Path $planning '.git/info/exclude';$excludeBytes=[IO.File]::ReadAllBytes($exclude)
try{
    [IO.File]::WriteAllText($exclude,'',[Text.UTF8Encoding]::new($false))
    $bad=Copy-Envelope $evidence;$bad.receipt_id='u002-no-ignore';Assert-CustodyWriterRefusal $bad 'no-ignore'
}finally{[IO.File]::WriteAllBytes($exclude,$excludeBytes)}
foreach($damage in @('conflict','tracked','unrelated','manifest-conflict','hardlink')){
    $bad=Copy-Envelope $evidence;$bad.receipt_id='u002-'+$damage
    $directory=Join-Path $workspace "receipts/$($bad.receipt_id)-evidence";$null=[IO.Directory]::CreateDirectory($directory)
    $preexisting=Join-Path $directory $(if($damage-eq'unrelated'){'unrelated.bin'}elseif($damage-eq'manifest-conflict'){'custody.json'}else{'0000-source.bin'})
    if($damage-eq'hardlink'){$null=New-Item -ItemType HardLink -Path $preexisting -Target $source}else{[IO.File]::WriteAllBytes($preexisting,[byte[]]@(9,8,7))}
    $savedIndex=[IO.File]::ReadAllBytes($index)
    if($damage-eq'tracked'){Invoke-EnvelopeGit $planning @('add','-f','--',([IO.Path]::GetRelativePath($planning,$preexisting)))|Out-Null}
    try{Assert-CustodyWriterRefusal $bad $damage}finally{[IO.File]::WriteAllBytes($index,$savedIndex);[IO.File]::Delete($preexisting);[IO.Directory]::Delete($directory,$false)}
}
# A failed mid-copy must retain an exact preexisting first leaf and remove only
# new files from this invocation. The second leaf intentionally conflicts.
$bad=Copy-Envelope $evidence;$bad.receipt_id='u002-partial-conflict';$directory=Join-Path $workspace 'receipts/u002-partial-conflict-evidence';$null=[IO.Directory]::CreateDirectory($directory)
$first=Join-Path $directory '0000-source.bin';$second=Join-Path $directory '0001-index.bin'
[IO.File]::WriteAllBytes($first,[IO.File]::ReadAllBytes($source));[IO.File]::WriteAllBytes($second,[byte[]]@(1))
Assert-CustodyWriterRefusal $bad 'partial-conflict'
[IO.File]::Delete($first);[IO.File]::Delete($second);[IO.Directory]::Delete($directory,$false)
Assert-CustodyWriterRefusal $evidence 'existing-output' $output
# Exact interrupted snapshots/manifests may be reused; the public output itself
# keeps its create-new contract. Deletion here is fixture-owned interruption.
$receiptBytes=[IO.File]::ReadAllBytes($output);$snapshotTime=(Get-Item -LiteralPath (Join-Path $workspace $manifest.artifacts[0].snapshot_path)).LastWriteTimeUtc
[IO.File]::Delete($output);$null=Invoke-CustodyWriter $evidence $output
Assert-Envelope ([Convert]::ToBase64String([IO.File]::ReadAllBytes($output))-ceq[Convert]::ToBase64String($receiptBytes)) 'exact interrupted retry changed receipt bytes'
Assert-Envelope ((Get-Item -LiteralPath (Join-Path $workspace $manifest.artifacts[0].snapshot_path)).LastWriteTimeUtc-eq$snapshotTime) 'exact interrupted retry overwrote existing snapshot'
foreach($damage in @('pass','namespace','manifest-hash','snapshot-hash','missing-snapshot','byte-length','extra-row','duplicate-origin','wrong-output','wrong-unit','wrong-kind','duplicate-key')){
    $badReceipt=Copy-Envelope $receipt;$savedManifest=[IO.File]::ReadAllBytes($manifestPath);$leafPath=Join-Path $workspace $manifest.artifacts[0].snapshot_path;$savedLeaf=[IO.File]::ReadAllBytes($leafPath)
    try{
        switch($damage){
            'pass'{$badReceipt.result='pass'}
            'namespace'{$badReceipt.artifacts[0].path='../unsafe.bin'}
            'manifest-hash'{[IO.File]::AppendAllText($manifestPath,' ')}
            'snapshot-hash'{[IO.File]::WriteAllBytes($leafPath,[byte[]]@(99))}
            'missing-snapshot'{[IO.File]::Delete($leafPath)}
            'duplicate-key'{[IO.File]::WriteAllText($manifestPath,[Text.Encoding]::UTF8.GetString($savedManifest).Replace('"receipt_id":','"receipt_id": "other-id", "receipt_id":'),[Text.UTF8Encoding]::new($false));$badReceipt.artifacts[-1].sha256=Get-EnvelopeFileSha256 $manifestPath}
            default{
                $badManifest=Copy-Envelope $manifest
                switch($damage){
                    'byte-length'{$badManifest.artifacts[0].byte_length++}
                    'extra-row'{$badManifest.artifacts+=,$badManifest.artifacts[0]}
                    'duplicate-origin'{$badManifest.artifacts[1].original_path=$source}
                    'wrong-output'{$badManifest.receipt_path='receipts/missing-original.json'}
                    'wrong-unit'{$badManifest.unit_id='u999'}
                    'wrong-kind'{$badManifest.artifacts[0].kind='other-kind'}
                }
                Write-EnvelopeJson $manifestPath $badManifest;$badReceipt.artifacts[-1].sha256=Get-EnvelopeFileSha256 $manifestPath
            }
        }
        # Damage is applied only after genuine production, including a matching
        # raw receipt for controls that must reach past output-byte checks.
        Write-EnvelopeJson $output $badReceipt
        Assert-CustodyRefusal {Assert-MorphospaceNonpassEvidenceSnapshotBinding -WorkspaceRoot $workspace -ReceiptPath $output -Receipt $badReceipt -Artifact $badReceipt.artifacts[0] -ExpectedOriginPath $source -ExpectedOriginSha256 $artifact.sha256} "reader accepted $damage"
    }finally{[IO.File]::WriteAllBytes($manifestPath,$savedManifest);[IO.File]::WriteAllBytes($leafPath,$savedLeaf);[IO.File]::WriteAllBytes($output,$receiptBytes)}
}
# An ordinary PASS keeps the old explicit references and has no custody artifact.
$pass=Copy-Envelope $evidence;$pass.receipt_id='u002-control-pass';$pass.result='pass';foreach($row in @($pass.criteria)+@($pass.gates)){$row.status='pass'}
$passReceipt=Invoke-CustodyWriter $pass (Join-Path $workspace 'receipts/control-pass.json')
Assert-Envelope ($passReceipt.artifacts[0].path-ceq$source-and@($passReceipt.artifacts).Count-eq@($evidence.artifacts).Count) 'PASS producer changed its existing evidence semantics'
# Genuine Return authenticates the failure before mutable source and Git index
# change; custody and receipt bytes retain the exact failed attempt afterward.
# Isolate the changed exact-selector reader seam with a copied actual declared
# matrix. This does not claim selector document production/dispatch occurred.
$readerOwner=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru -DisableNameChecking
$readerMatrix=@(foreach($row in $matrix){Copy-Envelope $row})
$selectedDefinition=@($readerMatrix|Where-Object disposition -CNE 'forbidden')[0]
$selectedDefinition|Add-Member -NotePropertyName selection_kind -NotePropertyValue 'exact-external-evidence' -Force
$selectedDefinition|Add-Member -NotePropertyName selector -NotePropertyValue ([pscustomobject]@{evidence=[pscustomobject]@{path=$source;sha256=$artifact.sha256;producer_result='fail'}}) -Force
$readerSpec=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json')
$readerMap=&$readerOwner {param($p)Get-MorphospaceRepositoryMap -RepoMapPath $p} $map
$readerStates=@(foreach($scope in $unit.allowed_repositories){&$readerOwner {param($id,$p)Get-MorphospaceRepositoryState -RepoId $id -Path $p} ([string]$scope.repo_id) ([string]$readerMap[[string]$scope.repo_id].path)})
$readerArgs=@{WorkspaceRoot=$workspace;ReceiptReference=$output;Spec=$readerSpec;Unit=$unit;RepositoryMap=$readerMap;RepositoryStates=$readerStates;ValidationMatrix=$readerMatrix;ExpectedResult='fail';ExpectedTier='quick';RepoMapPath=$map}
$null=&$readerOwner {param($a)Test-MorphospaceValidationReceipt @a} $readerArgs
foreach($damage in @('wrong-origin','wrong-hash')){
    $savedPath=$selectedDefinition.selector.evidence.path;$savedHash=$selectedDefinition.selector.evidence.sha256
    try{
        if($damage-eq'wrong-origin'){$selectedDefinition.selector.evidence.path=$source+'.wrong'}else{$selectedDefinition.selector.evidence.sha256='0'*64}
        Assert-CustodyRefusal {&$readerOwner {param($a)Test-MorphospaceValidationReceipt @a} $readerArgs} "actual selector reader seam accepted $damage"
    }finally{$selectedDefinition.selector.evidence.path=$savedPath;$selectedDefinition.selector.evidence.sha256=$savedHash}
}
$null=&$automation @common -Action ReturnToActive -ValidationReceipt 'receipts/custody-fail.json' -ValidationResult fail -Timestamp '2026-08-25T00:00:47.0000000Z' -Execute
$originalSource=[IO.File]::ReadAllBytes($source);$sourceHash=Get-EnvelopeFileSha256 $source;$indexHash=Get-EnvelopeFileSha256 $index
[IO.File]::AppendAllText($source,"`nModeled allowed source correction.",[Text.UTF8Encoding]::new($false))
Invoke-EnvelopeGit $seed.dependency_repository @('add','dependency/README.md')|Out-Null
[IO.File]::AppendAllText((Join-Path $workspace 'README.md'),"`nModeled planning index correction.",[Text.UTF8Encoding]::new($false))
Invoke-EnvelopeGit $planning @('add','morphospace/README.md')|Out-Null
Assert-Envelope ((Get-EnvelopeFileSha256 $source)-cne$sourceHash-and(Get-EnvelopeFileSha256 $index)-cne$indexHash) 'actual source/index mutation did not occur'
Assert-Envelope ([Convert]::ToBase64String([IO.File]::ReadAllBytes($output))-ceq[Convert]::ToBase64String($receiptBytes)) 'Return or source correction changed original receipt bytes'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1') -DisableNameChecking
Assert-Envelope (Assert-MorphospaceNonpassEvidenceSnapshotBinding -WorkspaceRoot $workspace -ReceiptPath $output -Receipt $receipt -Artifact $artifact -ExpectedOriginPath $source -ExpectedOriginSha256 $artifact.sha256) 'source/index correction damaged immutable failure custody'
# Every read/source/copy handle must have been released on successful and failed
# paths; exclusive reopen provides an actual resource-lifetime observation.
foreach($path in @($source,$index,$output,$manifestPath)+@($manifest.artifacts|ForEach-Object{Join-Path $workspace $_.snapshot_path})){$probe=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$probe.Dispose()}
Write-Host 'NONPASS custody: genuine public Freeze/Begin/failed-child/producer/Return, raw identity, reuse, no-write refusals, mapping and source/index mutation controls passed.'
