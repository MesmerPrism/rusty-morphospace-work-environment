[CmdletBinding()]
param([switch]$SelfTest,[ValidateSet('all','future','correction','accepted-prefix','fingerprint')][string]$Scenario='all',[string]$HarnessRoot='',[string]$HistoricalFixtureRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
trap { Write-Host $_.Exception.Message; Write-Host $_.ScriptStackTrace; throw $_ }
$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
$pwsh=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
function Assert-ProfileTest([bool]$Condition,[string]$Message){if(-not$Condition){throw "Initial profile closure test: $Message"}}
function Write-ProfileJson([string]$Path,[object]$Value){[void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent));[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 64)+"`n",[Text.UTF8Encoding]::new($false))}
function Read-ProfileJson([string]$Path){Read-MorphospaceProtocolJson $Path}
function Clone-ProfileValue([object]$Value){$Value|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String}
function Invoke-ProfileNative([string]$Script,[string[]]$Arguments){$output=@(&$pwsh -NoProfile -NonInteractive -File $Script @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "Native fixture action failed ($Script): $($output-join"`n")"};$output}
function ConvertTo-ProfileNativePresentationText([object[]]$Output){
    # Remove SGR presentation only; preserve all semantic characters and tokens.
    $plain=[regex]::Replace(($Output-join"`n"),'\x1b\[[0-9;]*m','')
    [regex]::Replace($plain,'\s+',' ').Trim()
}
function Snapshot-Profile([string]$Root){@((Get-ChildItem -LiteralPath $Root -Recurse -File|Sort-Object FullName|ForEach-Object{"$($_.FullName.Substring($Root.Length)) $(Get-MorphospaceFileSha256 $_.FullName)"}))-join"`n"}
function Assert-ProfileRefusal([scriptblock]$Action,[string]$Reason,[string]$Workspace){$before=Snapshot-Profile $Workspace;$refused=$false;try{&$Action|Out-Null}catch{$refused=$_.Exception.Message.Contains($Reason,[StringComparison]::Ordinal)};Assert-ProfileTest $refused "Expected refusal containing '$Reason'";Assert-ProfileTest ((Snapshot-Profile $Workspace)-ceq$before) 'Refusal wrote owner files'}
function Invoke-ProfileAcceptedPrefixProbe([string]$CorrectedRoot,[string]$MapPath,[string]$Destination){
    # Product PASS rows remain explicitly modeled and do not execute the
    # historical command strings. The real public producer owns the receipt,
    # exact bootstrap source/correction witness and native artifact bindings.
    if(Test-Path -LiteralPath $Destination){throw 'Accepted-prefix probe destination must be new.'}
    $originalBefore=Snapshot-Profile $CorrectedRoot
    [void][IO.Directory]::CreateDirectory($Destination)
    $accepted=Join-Path $Destination 'accepted';Copy-Item -LiteralPath $CorrectedRoot -Destination $accepted -Recurse
    Assert-ProfileTest ((Snapshot-Profile $accepted)-ceq$originalBefore) 'Accepted-prefix copy differs from earned original'
    $unit=Read-ProfileJson (Join-Path $accepted 'iteration-units/initial-profile-001.json')
    Assert-ProfileTest ([string]$unit.status-ceq'validating'-and[string]$unit.risk_tier-ceq'quick'-and[string]$unit.device_requirement-ceq'forbidden'-and@($unit.instruction_surfaces).Count-eq0) 'Accepted-prefix fixture has unexpected owning contract'
    $sourceLock=Read-ProfileJson (Join-Path $accepted ([string]$unit.source_composition.lock_path))
    $map=Read-ProfileJson $MapPath;$revisions=@()
    foreach($binding in @($sourceLock.repositories)){
        $mapped=@($map.repositories|Where-Object{[string]$_.repo_id-ceq[string]$binding.repo_id})
        Assert-ProfileTest ($mapped.Count-eq1) 'Accepted-prefix fixture lacks exact source mapping'
        $head=(&git -C ([string]$mapped[0].path) rev-parse HEAD|Out-String).Trim();Assert-ProfileTest ($LASTEXITCODE-eq0-and$head-ceq[string]$binding.commit) 'Accepted-prefix fixture source changed from immutable baseline'
        $branch=(&git -C ([string]$mapped[0].path) branch --show-current|Out-String).Trim();Assert-ProfileTest ($LASTEXITCODE-eq0) 'Accepted-prefix fixture source branch observation failed'
        $revisions+=,[pscustomobject]@{repo_id=[string]$binding.repo_id;base_revision=[string]$binding.commit;head_revision=$head;branch=$branch}
    }
    $modeledPath=Join-Path $accepted 'receipts/modeled-acceptance-input.txt'
    [IO.File]::WriteAllText($modeledPath,"Synthetic standard-v1 receipt input for a host-only transition/reader test. Profile command strings were NOT executed; this grants no product/source qualification or real-owner acceptance.`n",[Text.UTF8Encoding]::new($false))
    $evidence=[pscustomobject]@{receipt_id='initial-profile-modeled-pass';tier='quick';result='pass';artifacts=@([pscustomobject]@{artifact_id='modeled-fixture-input';kind='host-control';path=$modeledPath});criteria=@($unit.acceptance|ForEach-Object{[pscustomobject]@{acceptance_id=[string]$_.acceptance_id;status='pass';command=[string]$_.command;evidence_refs=@('modeled-fixture-input')}});gates=@($unit.validation|ForEach-Object{[pscustomobject]@{gate_id="validation-$([string]$_.profile_id)";status='pass';command=[string]$_.command;evidence_refs=@('modeled-fixture-input')}});device_validation=$null}
    $evidencePath=Join-Path $Destination 'modeled-product-evidence.json';Write-ProfileJson $evidencePath $evidence
    $receiptPath=Join-Path $accepted 'receipts/modeled-pass-validation.json'
    Assert-ProfileTest (-not(Test-Path -LiteralPath $receiptPath)) 'Public producer output must be fresh'
    $producer=Join-Path $PSScriptRoot 'New-ValidationReceipt.ps1'
    $producerArgs=@('-WorkspaceRoot',$accepted,'-UnitId','initial-profile-001','-RepoMapPath',$MapPath,'-EvidencePath',$evidencePath,'-OutPath',$receiptPath)
    $producerOutput=@(Invoke-ProfileNative $producer $producerArgs)
    Write-ProfileJson (Join-Path $Destination 'public-producer-observation.json') ([pscustomobject]@{argv=@($pwsh,'-NoProfile','-NonInteractive','-File',$producer)+$producerArgs;stdout_and_stderr=@($producerOutput|ForEach-Object{[string]$_});native_public_receipt=$true;profile_commands_executed=$false;product_or_source_qualification=$false})
    $receipt=Read-ProfileJson $receiptPath
    Assert-ProfileTest ([string]$receipt.schema-ceq'rusty.morphospace.workflow.validation_receipt.v1'-and[string]$receipt.receipt_id-ceq'initial-profile-modeled-pass'-and[string]$receipt.unit_id-ceq[string]$unit.unit_id-and[string]$receipt.result-ceq'pass') 'Public producer receipt identity differs'
    foreach($revision in $revisions){
        $actual=@($receipt.repository_revisions|Where-Object{[string]$_.repo_id-ceq[string]$revision.repo_id})
        Assert-ProfileTest ($actual.Count-eq1-and[string]$actual[0].base_revision-ceq[string]$revision.base_revision-and[string]$actual[0].head_revision-ceq[string]$revision.head_revision-and[string]$actual[0].branch-ceq[string]$revision.branch) 'Public producer did not retain the exact initial locked source baseline'
    }
    Assert-ProfileTest (@($receipt.changed_paths).Count-eq0-and@($receipt.repository_revisions).Count-eq$revisions.Count) 'Public producer changed the unchanged-source fixture closure'
    foreach($reserved in @('bootstrap-source-lock','bootstrap-repository-map','bootstrap-begin-intent')){Assert-ProfileTest (@($receipt.artifacts|Where-Object{[string]$_.artifact_id-ceq$reserved}).Count-eq1) "Public bootstrap producer omitted or repeated $reserved"}
    $lockedArtifact=@($receipt.artifacts|Where-Object{[string]$_.artifact_id-ceq'bootstrap-source-lock'})[0]
    Assert-ProfileTest ([string]$lockedArtifact.sha256-ceq(Get-MorphospaceFileSha256 (Join-Path $accepted ([string]$unit.source_composition.lock_path)))) 'Public producer failed to bind the exact native correction source-lock bytes'
    $entry=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'
    $producerReceiptRaw=Get-MorphospaceFileSha256 $receiptPath
    Invoke-ProfileNative $entry @('-Action','RecordValidation','-WorkspaceRoot',$accepted,'-UnitId','initial-profile-001','-RepoMapPath',$MapPath,'-ValidationTier','quick','-ValidationResult','pass','-ValidationReceipt','receipts/modeled-pass-validation.json','-Execute')|Out-Null
    $recordedState=Read-ProfileJson (Join-Path $accepted 'workspace.state.json')
    $recordedReceiptRelative=[string]$recordedState.validation_checkpoint.receipt
    Assert-ProfileTest (-not[string]::IsNullOrWhiteSpace($recordedReceiptRelative)-and$recordedReceiptRelative-cne'receipts/modeled-pass-validation.json'-and[string]$recordedState.validation_checkpoint.result-ceq'pass') 'Record must select its new native-owned retained receipt copy'
    $recordedReceiptPath=Join-Path $accepted $recordedReceiptRelative
    Assert-ProfileTest ((Split-Path ([IO.Path]::GetFullPath($recordedReceiptPath)) -Parent)-ceq(Split-Path ([IO.Path]::GetFullPath($receiptPath)) -Parent)-and(Test-Path -LiteralPath $recordedReceiptPath -PathType Leaf)) 'Native retained receipt must exist in the producer receipt directory'
    Assert-ProfileTest ((Get-MorphospaceFileSha256 $recordedReceiptPath)-ceq$producerReceiptRaw-and(Get-MorphospaceFileSha256 $receiptPath)-ceq$producerReceiptRaw) 'Record changed producer bytes or retained a different receipt'
    Invoke-ProfileNative $entry @('-Action','Accept','-WorkspaceRoot',$accepted,'-UnitId','initial-profile-001','-RepoMapPath',$MapPath,'-Execute')|Out-Null
    $state=Read-ProfileJson (Join-Path $accepted 'workspace.state.json')
    $acceptedReceiptRelative=[string]$state.last_accepted_receipt
    $acceptedReceiptPath=Join-Path $accepted $acceptedReceiptRelative
    $acceptedEventId=[string]$state.last_event_id
    $expectedAcceptedReceiptRelative=((Split-Path $recordedReceiptRelative -Parent).Replace('\','/')+'/'+$acceptedEventId+'-retained-validation.json')
    Assert-ProfileTest ($null-eq$state.current_unit-and$acceptedReceiptRelative-ceq$expectedAcceptedReceiptRelative-and$acceptedReceiptRelative-cne$recordedReceiptRelative-and[string]$state.validation_checkpoint.receipt-ceq$acceptedReceiptRelative-and[string](Read-ProfileJson (Join-Path $accepted 'iteration-units/initial-profile-001.json')).status-ceq'accepted') 'Public modeled-input acceptance did not select its new event-derived final receipt copy'
    Assert-ProfileTest ((Split-Path ([IO.Path]::GetFullPath($acceptedReceiptPath)) -Parent)-ceq(Split-Path ([IO.Path]::GetFullPath($receiptPath)) -Parent)-and(Test-Path -LiteralPath $acceptedReceiptPath -PathType Leaf)) 'Accept final receipt must exist in the producer and Record receipt directory'
    Assert-ProfileTest ((Get-MorphospaceFileSha256 $acceptedReceiptPath)-ceq$producerReceiptRaw-and(Get-MorphospaceFileSha256 $recordedReceiptPath)-ceq$producerReceiptRaw-and(Get-MorphospaceFileSha256 $receiptPath)-ceq$producerReceiptRaw) 'Accept changed producer or Record input bytes or retained a different final receipt'
    $acceptTransactionId=$acceptedEventId+'-transition'
    $acceptIntentRelative="receipts/transactions/$acceptTransactionId.intent.json"
    $acceptIntent=Read-ProfileJson (Join-Path $accepted $acceptIntentRelative)
    $acceptCompletion=Read-ProfileJson (Join-Path $accepted "receipts/transactions/$acceptTransactionId.completion.json")
    $acceptEvent=Get-Content -LiteralPath (Join-Path $accepted 'iteration-events.jsonl')|Select-Object -Last 1|ConvertFrom-Json -DateKind String
    Assert-ProfileTest ([string]$acceptEvent.event_id-ceq$acceptedEventId-and@($acceptEvent.receipts).Count-eq2-and[string]$acceptEvent.receipts[0]-ceq$recordedReceiptRelative-and[string]$acceptEvent.receipts[1]-ceq$acceptedReceiptRelative) 'Accept event must retain the Record input and its new authoritative final receipt'
    Assert-ProfileTest ([string]$acceptIntent.transaction_id-ceq$acceptTransactionId-and[string]$acceptIntent.event.event_id-ceq$acceptedEventId-and@($acceptIntent.artifacts).Count-eq1-and[string]$acceptIntent.artifacts[0].path-ceq$acceptedReceiptRelative-and[string]$acceptIntent.artifacts[0].sha256-ceq$producerReceiptRaw-and(Get-MorphospaceSha256Bytes ([Convert]::FromBase64String([string]$acceptIntent.artifacts[0].bytes_base64)))-ceq$producerReceiptRaw) 'Accept must own exactly one final receipt artifact with the original producer bytes'
    Assert-ProfileTest ([string]$acceptCompletion.transaction_id-ceq$acceptTransactionId-and[string]$acceptCompletion.event_id-ceq$acceptedEventId-and[string]$acceptCompletion.status-ceq'committed'-and[string]$acceptCompletion.intent.path-ceq$acceptIntentRelative-and[string]$acceptCompletion.intent.sha256-ceq(Get-MorphospaceFileSha256 (Join-Path $accepted $acceptIntentRelative))) 'Accept completion must bind its actual final-copy intent'
    $consumer=Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1'
    Invoke-ProfileNative $consumer @('-WorkspaceRoot',$accepted,'-RepositoryMapPath',$MapPath,'-CurrentWorkOnly','-SkipOwnerSelfTests','-CurrentWorkspaceOnly')|Out-Null
    $damaged=Join-Path $Destination 'damaged';Copy-Item -LiteralPath $accepted -Destination $damaged -Recurse
    [IO.File]::AppendAllText((Join-Path $damaged 'receipts/active-correction.json')," ")
    $damageBefore=Snapshot-Profile $damaged
    $damageOutput=@(&$pwsh -NoProfile -NonInteractive -File $consumer -WorkspaceRoot $damaged -RepositoryMapPath $MapPath -CurrentWorkOnly -SkipOwnerSelfTests -CurrentWorkspaceOnly 2>&1)
    $refused=$LASTEXITCODE-ne0
    Assert-ProfileTest ($refused-and(ConvertTo-ProfileNativePresentationText $damageOutput)-match'(artifact|correction|profile closure)') 'Accepted-prefix reader accepted or misclassified damaged correction artifact'
    Assert-ProfileTest ((Snapshot-Profile $damaged)-ceq$damageBefore) 'Accepted-prefix damage refusal wrote owner files'
    $damagedReceipt=Join-Path $Destination 'damaged-receipt';Copy-Item -LiteralPath $accepted -Destination $damagedReceipt -Recurse
    [IO.File]::AppendAllText((Join-Path $damagedReceipt $acceptedReceiptRelative)," ")
    $receiptDamageBefore=Snapshot-Profile $damagedReceipt
    $receiptDamageOutput=@(&$pwsh -NoProfile -NonInteractive -File $consumer -WorkspaceRoot $damagedReceipt -RepositoryMapPath $MapPath -CurrentWorkOnly -SkipOwnerSelfTests -CurrentWorkspaceOnly 2>&1)
    $receiptDamageExitCode=$LASTEXITCODE
    $receiptDamageAfter=Snapshot-Profile $damagedReceipt
    $receiptDamageRawText=$receiptDamageOutput-join"`n"
    $receiptDamageExpected="Transition ledger committed artifact differs from its intent: $acceptedReceiptRelative"
    # Native stderr may place SGR close/open codes around its line wrapping.
    # Retain raw text; compare the exact owning error/path after presentation only.
    $receiptDamageNormalized=ConvertTo-ProfileNativePresentationText @($receiptDamageRawText)
    $receiptDamageExpectedNormalized=ConvertTo-ProfileNativePresentationText @($receiptDamageExpected)
    $receiptDamageMatched=$receiptDamageNormalized.Contains($receiptDamageExpectedNormalized,[StringComparison]::Ordinal)
    Write-ProfileJson (Join-Path $Destination 'accepted-receipt-drift-observation.json') ([pscustomobject]@{argv=@($pwsh,'-NoProfile','-NonInteractive','-File',$consumer,'-WorkspaceRoot',$damagedReceipt,'-RepositoryMapPath',$MapPath,'-CurrentWorkOnly','-SkipOwnerSelfTests','-CurrentWorkspaceOnly');exit_code=$receiptDamageExitCode;output=@($receiptDamageOutput|ForEach-Object{[string]$_});raw_text=$receiptDamageRawText;expected_exact_error=$receiptDamageExpected;whitespace_normalized_output=$receiptDamageNormalized;whitespace_normalized_error=$receiptDamageExpectedNormalized;exact_error_matched=$receiptDamageMatched;owner_before=$receiptDamageBefore;owner_after=$receiptDamageAfter;owner_unchanged=($receiptDamageAfter-ceq$receiptDamageBefore)})
    if($receiptDamageExitCode-eq0-or-not$receiptDamageMatched-or$receiptDamageAfter-cne$receiptDamageBefore){
        Write-Host ('Initial profile raw-drift diagnostic: '+([pscustomobject]@{exit_code=$receiptDamageExitCode;raw_text=$receiptDamageRawText;expected_exact_error=$receiptDamageExpected;presentation_normalized_output=$receiptDamageNormalized;exact_error_matched=$receiptDamageMatched;owner_unchanged=($receiptDamageAfter-ceq$receiptDamageBefore)}|ConvertTo-Json -Depth 8 -Compress))
    }
    Assert-ProfileTest ($receiptDamageExitCode-ne0) 'Accepted-prefix reader accepted final Accept-owned receipt raw drift; see accepted-receipt-drift-observation.json'
    Assert-ProfileTest $receiptDamageMatched 'Accepted-prefix reader misclassified final Accept-owned receipt raw drift; see accepted-receipt-drift-observation.json'
    Assert-ProfileTest ($receiptDamageAfter-ceq$receiptDamageBefore) 'Accepted consumed-receipt refusal wrote owner files'
    Assert-ProfileTest ((Snapshot-Profile $CorrectedRoot)-ceq$originalBefore) 'Accepted-prefix probe changed earned original'
    Write-ProfileJson (Join-Path $Destination 'OUTCOME.json') ([pscustomobject]@{result='pass';accepted_workspace=$accepted;damaged_workspace=$damaged;model='Modeled host-only product evidence input; genuine public receipt production and Record/Accept/current-work transitions only.';native_public_receipt=$true;producer_receipt_unchanged=$true;recorded_receipt_unchanged=$true;recorded_receipt=$recordedReceiptRelative;accepted_receipt=$acceptedReceiptRelative;accept_artifact_count=1;profile_commands_executed=$false;product_or_source_qualification=$false;real_owner_acceptance=$false;original_unchanged=$true;damaged_correction_refused_without_write=$true;consumed_receipt_drift_refused_without_write=$true;damage_output=@($damageOutput|ForEach-Object{[string]$_});receipt_damage_output=@($receiptDamageOutput|ForEach-Object{[string]$_});accepted_tail=[string]$state.last_event_id})
    Write-Host 'accepted-prefix public receipt/current-work and correction/receipt drift refusals passed using explicitly modeled product evidence'
}

if($HistoricalFixtureRoot-and$Scenario-cnotin@('correction','accepted-prefix','fingerprint')){throw 'Retained historical fixture reuse requires correction, accepted-prefix or fingerprint.'}
if(-not$HarnessRoot){$HarnessRoot=Join-Path ([IO.Path]::GetTempPath()) ('initial-profile-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($HarnessRoot)
$clock=[Diagnostics.Stopwatch]::StartNew()
if($Scenario-ceq'accepted-prefix'){if(-not$HistoricalFixtureRoot){throw 'Accepted-prefix-only requires an earned retained harness.'};Invoke-ProfileAcceptedPrefixProbe (Join-Path $HistoricalFixtureRoot 'active-correction') (Join-Path $HistoricalFixtureRoot 'repository-map.json') (Join-Path $HarnessRoot 'accepted-prefix');return}
# These historical-origin fixtures deliberately use the immutable public owner
# that admitted unknown IDs. No claimed project or ledger is edited to synthesize
# the defect. The current owner independently authenticates those real receipts.
$oldCommit='34feb99391101e2a36f4ada51b73add973d38a4f'
if($HistoricalFixtureRoot){Copy-Item -LiteralPath (Join-Path $HistoricalFixtureRoot 'seed') -Destination (Join-Path $HarnessRoot 'seed') -Recurse;Copy-Item -LiteralPath (Join-Path $HistoricalFixtureRoot 'repository-map.json') -Destination (Join-Path $HarnessRoot 'repository-map.json')}
if(-not$HistoricalFixtureRoot){
$old=Join-Path $HarnessRoot 'pre-fix-owner'
$archive=Join-Path $HarnessRoot 'pre-fix-owner.zip'
& git -C $repo archive --format=zip --output=$archive $oldCommit
if($LASTEXITCODE-ne0){throw 'Historical fixture owner Git object is unavailable.'}
Expand-Archive -LiteralPath $archive -DestinationPath $old
& git -C $old init -q
& git -C $old -c core.autocrlf=false add .
& git -C $old -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'immutable historical owner fixture'
if($LASTEXITCODE-ne0){throw 'Historical fixture owner checkout creation failed.'}
$source=Join-Path $HarnessRoot 'source'
[void][IO.Directory]::CreateDirectory($source)
[IO.File]::WriteAllText((Join-Path $source 'source.txt'),"fixture source`n")
& git -C $source init -q; & git -C $source -c user.name=Fixture -c user.email=fixture@example.invalid add source.txt
& git -C $source -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'fixture source'
if($LASTEXITCODE-ne0){throw 'Fixture Git source creation failed.'}
$seed=Join-Path $HarnessRoot 'seed'
Invoke-ProfileNative (Join-Path $old 'scripts/New-ProjectWorkspace.ps1') @('-ProjectRoot',$seed,'-ProjectId','initial-profile-test','-Purpose','Exercise historical initial profile closure.','-Execute')|Out-Null
$workspace=Join-Path $seed 'morphospace'
$spec=Read-ProfileJson (Join-Path $workspace 'project.spec.json')
$spec.repositories=@([pscustomobject]@{repo_id='source';role='application';path=$source;allowed_paths=@('source.txt')})
$spec.validation_profiles=@([pscustomobject]@{profile_id='focused';commands=@('literal focused evidence description')})
Write-ProfileJson (Join-Path $workspace 'project.spec.json') $spec
$unit=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_unit.v1';project_id='initial-profile-test';unit_id='initial-profile-001';status='proposed';objective='Exercise an authentic initial profile omission.';change_categories=@('implementation');instruction_impact='none';instruction_surfaces=@();instruction_none_justification='Disposable fixture has no instruction changes.';prerequisites=@();allowed_repositories=@([pscustomobject]@{repo_id='source';allowed_paths=@('source.txt')});read_only_dependencies=@();non_scope=@('No product effects.');acceptance=@([pscustomobject]@{acceptance_id='closure';proof='Exact additive declaration';command='literal workflow evidence description'});risk_tier='quick';device_requirement='forbidden';validation=@([pscustomobject]@{profile_id='workflow';command='literal workflow evidence description'},[pscustomobject]@{profile_id='workflow';command='literal workflow evidence description'},[pscustomobject]@{profile_id='workflow';command='pwsh -NoProfile -File scripts/Test-ToolingContext.ps1 -SelfTest -Scenario validating-upgrade'});outputs=@('Fixture evidence');commit_policy='Fixture only';push_checkpoint='local-only';source_composition=[pscustomobject]@{mode='exact-lock';lock_path='source-compositions/initial-profile-001.lock.json';materialization_receipt=$null}}
$unitPath=Join-Path $workspace 'iteration-units/initial-profile-001.json'
Write-ProfileJson $unitPath $unit
$map=Join-Path $HarnessRoot 'repository-map.json'
Write-ProfileJson $map ([pscustomobject]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([pscustomobject]@{repo_id='source';role='source';path=$source;aliases=@()})})
Invoke-ProfileNative (Join-Path $old 'scripts/New-SourceCompositionLock.ps1') @('-WorkspaceRoot',$workspace,'-UnitId','initial-profile-001','-RepositoryMapPath',$map,'-RepoId','source','-OutRelativePath','source-compositions/initial-profile-001.lock.json','-Execute')|Out-Null
$common=@('-WorkspaceRoot',$workspace,'-UnitId','initial-profile-001','-RepoMapPath',$map)
if($Scenario-cne'correction'){
    $entry=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'
    $before=Snapshot-Profile $workspace
    $readyOutput=@(&$pwsh -NoProfile -NonInteractive -File $entry -Action Ready @common -Execute 2>&1)
    Write-ProfileJson (Join-Path $HarnessRoot 'ready-observation.json') ([pscustomobject]@{exit_code=$LASTEXITCODE;output=@($readyOutput|ForEach-Object{[string]$_})});Assert-ProfileTest ($LASTEXITCODE-ne0-and(ConvertTo-ProfileNativePresentationText $readyOutput).Contains('validation-profile-unknown')) 'Unknown profile Ready must refuse before any transition'
    Assert-ProfileTest ((Snapshot-Profile $workspace)-ceq$before) 'Unknown Ready wrote owner files'
    Write-Host 'future unknown-ID Ready refusal passed'
    $known=Join-Path $HarnessRoot 'known-profiles'
    Copy-Item -LiteralPath $workspace -Destination $known -Recurse
    $knownProject=Read-ProfileJson (Join-Path $known 'project.spec.json')
    $knownProject.validation_profiles+=,[pscustomobject]@{profile_id='workflow';commands=@('Different declared project command; Ready checks IDs only.')}
    Write-ProfileJson (Join-Path $known 'project.spec.json') $knownProject
    Invoke-ProfileNative $entry @('-Action','Ready','-WorkspaceRoot',$known,'-UnitId','initial-profile-001','-RepoMapPath',$map,'-Execute')|Out-Null
    Invoke-ProfileNative $entry @('-Action','Claim','-WorkspaceRoot',$known,'-UnitId','initial-profile-001','-RepoMapPath',$map,'-Execute')|Out-Null
    Write-Host 'future known-ID Ready/Claim passed without imposing command equality'
    if($Scenario-ceq'future'){return}
}
Invoke-ProfileNative (Join-Path $old 'scripts/Invoke-WorkUnitAutomation.ps1') (@('-Action','Ready')+$common+'-Execute')|Out-Null
if($Scenario-cne'correction'){
    $before=Snapshot-Profile $workspace
    $claimOutput=@(&$pwsh -NoProfile -NonInteractive -File $entry -Action Claim @common -Execute 2>&1)
    Assert-ProfileTest ($LASTEXITCODE-ne0-and(ConvertTo-ProfileNativePresentationText $claimOutput).Contains('validation-profile-unknown')) 'Fresh Claim must refuse the historical ready unknown profile'
    Assert-ProfileTest ((Snapshot-Profile $workspace)-ceq$before) 'Unknown Claim wrote owner files'
}
Invoke-ProfileNative (Join-Path $old 'scripts/Invoke-WorkUnitAutomation.ps1') (@('-Action','Claim')+$common+'-Execute')|Out-Null
}
$workspace=Join-Path $HarnessRoot 'seed/morphospace';$map=Join-Path $HarnessRoot 'repository-map.json'
# Validate that the real old project is refused by the current public consumer
# for the exact omission, before attempting the new correction.
$consumer=@(&$pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -WorkspaceRoot $workspace -RepositoryMapPath $map -CurrentWorkOnly -SkipOwnerSelfTests -CurrentWorkspaceOnly 2>&1)
Assert-ProfileTest ($LASTEXITCODE-ne0-and(ConvertTo-ProfileNativePresentationText $consumer).Contains('unknown validation profile')) 'Historical missing-profile fixture must reproduce the current-work failure'
Import-Module (Join-Path $PSScriptRoot 'InitialValidationProfileClosureCorrection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
function New-ProfileRequest([string]$Root,[string]$Id){
    $s=Read-ProfileJson (Join-Path $Root 'workspace.state.json');$p=Read-ProfileJson (Join-Path $Root 'project.spec.json');$l=Read-ProfileJson (Join-Path $Root 'feature.lock.json');$u=Read-ProfileJson (Join-Path $Root 'iteration-units/initial-profile-001.json');$e=[ordered]@{status=[string]$u.status;current_unit=[string]$s.current_unit;project_revision=[int]$p.revision;feature_lock_revision=[int]$l.revision;plan_revision=[int]$s.plan_revision;feature_lock_generated_at=[string]$l.generated_at}
    foreach($row in @(@('project','project.spec.json'),@('feature_lock','feature.lock.json'),@('state','workspace.state.json'),@('unit','iteration-units/initial-profile-001.json'))){$path=Join-Path $Root $row[1];$e[($row[0]+'_sha256')]=Get-MorphospaceCanonicalJsonSha256 (Read-ProfileJson $path);$e[($row[0]+'_raw_sha256')]=Get-MorphospaceFileSha256 $path}
    $e.events_sha256=Get-MorphospaceFileSha256 (Join-Path $Root 'iteration-events.jsonl');$e.events_length=[IO.FileInfo]::new((Join-Path $Root 'iteration-events.jsonl')).Length;$e.event_tail_id=[string]$s.last_event_id;$e.source_composition=[pscustomobject]@{path=[string]$u.source_composition.lock_path;sha256=Get-MorphospaceFileSha256 (Join-Path $Root $u.source_composition.lock_path)}
    [pscustomobject]@{schema='rusty.morphospace.workflow.initial_validation_profile_closure_correction.v1';correction_id=$Id;project_id='initial-profile-test';unit_id='initial-profile-001';reason='Restore only missing initial validation profile declarations.';expected=[pscustomobject]$e;additions=@([pscustomobject]@{profile_id='workflow';commands=@('literal workflow evidence description','pwsh -NoProfile -File scripts/Test-ToolingContext.ps1 -SelfTest -Scenario validating-upgrade')});does_not_prove=@('No command execution, validation pass, acceptance, source or publication authority.')}
}
function New-ProfileCase([string]$Name){
    $root=Join-Path $HarnessRoot $Name
    Copy-Item -LiteralPath $workspace -Destination $root -Recurse
    $request=New-ProfileRequest $root $Name
    $inputPath=Join-Path $HarnessRoot "$Name.request.json";Write-ProfileJson $inputPath $request
    [pscustomobject]@{root=$root;request=$request;input=$inputPath;out=(Join-Path $root "receipts/$Name.json")}
}
function Invoke-ProfileCase([object]$Case,[switch]$Execute,[string]$FaultAfter='none'){
    Invoke-MorphospaceCorrectInitialValidationProfileClosure -WorkspaceRoot $Case.root -UnitId initial-profile-001 -InitialValidationProfileCorrectionPath $Case.input -ExpectedInitialValidationProfileCorrectionSha256 (Get-MorphospaceFileSha256 $Case.input) -OutPath $Case.out -FaultAfter $FaultAfter -Execute:$Execute
}
function Invoke-ProfileFingerprintControl {
    $case=New-ProfileCase 'stale-lock-fingerprint'
    $path=Join-Path $case.root 'feature.lock.json';$lock=Read-ProfileJson $path
    # Both authentic producer formats remain valid inputs to the shared guard.
    # These are predicate controls only and create no synthetic owner history.
    $canonical=Clone-ProfileValue $lock;$canonical.lock_fingerprint=Get-MorphospaceFeatureLockFingerprint $canonical
    Assert-ProfileTest (Test-MorphospaceFeatureLockFingerprint $canonical) 'Canonical feature-lock producer format was rejected'
    $compressed=Clone-ProfileValue $lock;$compressed.lock_fingerprint='0'*64
    $compressed.lock_fingerprint=Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($compressed|ConvertTo-Json -Depth 48 -Compress)))
    Assert-ProfileTest (Test-MorphospaceFeatureLockFingerprint $compressed) 'Original compressed feature-lock producer format was rejected'
    Assert-ProfileTest (Test-MorphospaceFeatureLockFingerprint $lock) 'Authentic initial feature-lock fingerprint is invalid'
    $lock.generated_at='2026-09-01T00:00:00Z';Write-ProfileJson $path $lock
    Assert-ProfileTest (-not(Test-MorphospaceFeatureLockFingerprint (Read-ProfileJson $path))) 'Semantic lock damage did not retain a stale fingerprint'
    # Fresh raw/canonical CAS must not launder a semantic lock fingerprint.
    $case.request=New-ProfileRequest $case.root 'stale-lock-fingerprint';Write-ProfileJson $case.input $case.request
    Assert-ProfileRefusal {Invoke-ProfileCase $case -Execute} 'feature-lock fingerprint' $case.root
    Write-Host 'fresh-CAS stale feature-lock fingerprint refused without writes; canonical/compressed predicate compatibility passed'
}

if($Scenario-ceq'fingerprint'){
    Invoke-ProfileFingerprintControl
    $valid=New-ProfileCase 'fingerprint-valid-original'
    Invoke-ProfileCase $valid -Execute|Out-Null
    $event=Get-Content -LiteralPath (Join-Path $valid.root 'iteration-events.jsonl')|Select-Object -Last 1|ConvertFrom-Json -DateKind String
    [void](Test-MorphospaceHistoricalInitialValidationProfileClosure -WorkspaceRoot $valid.root -ExpectedEvent $event)
    Write-Host 'authentic original-lock correction and historical read passed with shared fingerprint guard'
    return
}
$negativeCount=0
Invoke-ProfileFingerprintControl;$negativeCount++
foreach($field in @('project_sha256','project_raw_sha256','feature_lock_sha256','feature_lock_raw_sha256','state_sha256','state_raw_sha256','unit_sha256','unit_raw_sha256','events_sha256','event_tail_id','events_length','project_revision','feature_lock_revision','plan_revision')){
    $case=New-ProfileCase ("stale-"+$field.Replace('_','-'))
    if($field-ceq'event_tail_id'){$case.request.expected.$field='detached-tail'}elseif($field-cmatch'(length|revision)$'){$case.request.expected.$field=[int64]$case.request.expected.$field+1}else{$case.request.expected.$field='0'*64}
    Write-ProfileJson $case.input $case.request
    Assert-ProfileRefusal {Invoke-ProfileCase $case -Execute} 'Initial profile closure' $case.root;$negativeCount++
}
foreach($damage in @('extra-profile','existing-profile','extra-command','duplicate-profile','duplicate-command','source-hash','source-path')){
    $case=New-ProfileCase $damage
    switch($damage){
        'extra-profile' {$case.request.additions+=,[pscustomobject]@{profile_id='unrelated';commands=@('unearned')}}
        'existing-profile' {$case.request.additions[0].profile_id='focused'}
        'extra-command' {$case.request.additions[0].commands+=,'unearned command'}
        'duplicate-profile' {$case.request.additions+=,$case.request.additions[0]}
        'duplicate-command' {$case.request.additions[0].commands+=,$case.request.additions[0].commands[0]}
        'source-hash' {$case.request.expected.source_composition.sha256='0'*64}
        'source-path' {$case.request.expected.source_composition.path='source-compositions/absent.json'}
    }
    Write-ProfileJson $case.input $case.request
    Assert-ProfileRefusal {Invoke-ProfileCase $case -Execute} '' $case.root;$negativeCount++
}
foreach($damage in @('material-unit','frozen','accepted','admitted','checkpoint','blocker','queued','pending-publication','detached-origin','raw-project','raw-lock','raw-state','raw-unit','raw-source')){
    $case=New-ProfileCase $damage
    switch($damage){
        'material-unit' {$u=Read-ProfileJson (Join-Path $case.root 'iteration-units/initial-profile-001.json');$u.objective='Changed contract';Write-ProfileJson (Join-Path $case.root 'iteration-units/initial-profile-001.json') $u}
        'frozen' {$u=Read-ProfileJson (Join-Path $case.root 'iteration-units/initial-profile-001.json');$u|Add-Member candidate_freeze ([pscustomobject]@{freeze_id='frozen-unit';receipt_path='receipts/absent.json';receipt_sha256=('0'*64)});Write-ProfileJson (Join-Path $case.root 'iteration-units/initial-profile-001.json') $u}
        'accepted' {$u=Read-ProfileJson (Join-Path $case.root 'iteration-units/initial-profile-001.json');$u.status='accepted';Write-ProfileJson (Join-Path $case.root 'iteration-units/initial-profile-001.json') $u}
        'admitted' {$u=Read-ProfileJson (Join-Path $case.root 'iteration-units/initial-profile-001.json');$u|Add-Member agent_scope_assessment ([pscustomobject]@{schema='rusty.morphospace.workflow.agent_scope_assessment.v1'});Write-ProfileJson (Join-Path $case.root 'iteration-units/initial-profile-001.json') $u}
        'checkpoint' {$s=Read-ProfileJson (Join-Path $case.root 'workspace.state.json');$s.validation_checkpoint=[pscustomobject]@{tier='standard';receipt='receipts/previous-fail.json';result='fail'};Write-ProfileJson (Join-Path $case.root 'workspace.state.json') $s}
        'blocker' {$s=Read-ProfileJson (Join-Path $case.root 'workspace.state.json');$s.blockers=@([pscustomobject]@{blocker_id='blocked';condition='Unresolved fixture blocker';resume_when='A separate owner resolves the blocker.'});Write-ProfileJson (Join-Path $case.root 'workspace.state.json') $s}
        'queued' {$s=Read-ProfileJson (Join-Path $case.root 'workspace.state.json');$s.next_ready_unit='queued-unit';Write-ProfileJson (Join-Path $case.root 'workspace.state.json') $s}
        'pending-publication' {$s=Read-ProfileJson (Join-Path $case.root 'workspace.state.json');$s.pending_push_bundle=[pscustomobject]@{bundle_id='pending';unit_ids=@('initial-profile-001');repo_ids=@('source');ready=$false};Write-ProfileJson (Join-Path $case.root 'workspace.state.json') $s}
        'detached-origin' {[IO.File]::AppendAllText((Join-Path $case.root 'receipts/transactions/initial-profile-001-ready-0001-transition.intent.json')," ")}
        {$_-like'raw-*'} {$relative=switch($damage){'raw-project'{'project.spec.json'} 'raw-lock'{'feature.lock.json'} 'raw-state'{'workspace.state.json'} 'raw-unit'{'iteration-units/initial-profile-001.json'} 'raw-source'{'source-compositions/initial-profile-001.lock.json'}};[IO.File]::AppendAllText((Join-Path $case.root $relative)," ")}
    }
    # Semantic eligibility cases carry fresh CAS; raw-only drift deliberately
    # retains the old raw expectation. Neither is allowed to write an intent.
    if($damage-cnotlike'raw-*'-and$damage-cne'detached-origin'){$case.request=New-ProfileRequest $case.root $damage;Write-ProfileJson $case.input $case.request}
    Assert-ProfileRefusal {Invoke-ProfileCase $case -Execute} '' $case.root;$negativeCount++
}
$active=New-ProfileCase 'active-correction'
$before=Snapshot-Profile $active.root
$unitRaw=Get-MorphospaceFileSha256 (Join-Path $active.root 'iteration-units/initial-profile-001.json');$sourceRaw=Get-MorphospaceFileSha256 (Join-Path $active.root 'source-compositions/initial-profile-001.lock.json');$ledgerBytes=[IO.File]::ReadAllBytes((Join-Path $active.root 'iteration-events.jsonl'))
$dry=Invoke-ProfileCase $active
Assert-ProfileTest (-not$dry.executed-and(Snapshot-Profile $active.root)-ceq$before) 'Correction dry run changed owner files'
# The exact public router must use the same module and request pins.
$wrapperRaw=@(Invoke-ProfileNative (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') @('-Action','CorrectInitialValidationProfileClosure','-WorkspaceRoot',$active.root,'-UnitId','initial-profile-001','-InitialValidationProfileCorrectionPath',$active.input,'-ExpectedInitialValidationProfileCorrectionSha256',(Get-MorphospaceFileSha256 $active.input),'-OutPath',$active.out))
$jsonStart=[Array]::IndexOf($wrapperRaw,'{');Assert-ProfileTest ($jsonStart-ge0) 'Public router emitted no JSON';$wrapper=($wrapperRaw[$jsonStart..($wrapperRaw.Count-1)]-join"`n")|ConvertFrom-Json
Assert-ProfileTest ([string]$wrapper.action-ceq'CorrectInitialValidationProfileClosure'-and-not$wrapper.executed) 'Public correction router differs'
Invoke-ProfileCase $active -Execute|Out-Null
Assert-ProfileTest ((Get-MorphospaceFileSha256 (Join-Path $active.root 'iteration-units/initial-profile-001.json'))-ceq$unitRaw-and(Get-MorphospaceFileSha256 (Join-Path $active.root 'source-compositions/initial-profile-001.lock.json'))-ceq$sourceRaw) 'Correction changed raw unit/source'
$afterBytes=[IO.File]::ReadAllBytes((Join-Path $active.root 'iteration-events.jsonl'));Assert-ProfileTest ((Get-MorphospaceSha256Bytes ([byte[]]$afterBytes[0..($ledgerBytes.Length-1)]))-ceq(Get-MorphospaceSha256Bytes $ledgerBytes)) 'Correction rewrote original committed ledger prefix'
$afterProject=Read-ProfileJson (Join-Path $active.root 'project.spec.json');Assert-ProfileTest (@($afterProject.validation_profiles).Count-eq2-and[object]::Equals($afterProject.validation_profiles[0].commands[0],'literal focused evidence description')-and(@($afterProject.validation_profiles[1].commands)-join'|')-ceq'literal workflow evidence description|pwsh -NoProfile -File scripts/Test-ToolingContext.ps1 -SelfTest -Scenario validating-upgrade') 'Correction changed existing profile or literal command set'
$activeEvent=(Get-Content -LiteralPath (Join-Path $active.root 'iteration-events.jsonl')|Select-Object -Last 1)|ConvertFrom-Json -DateKind String
[void](Test-MorphospaceHistoricalInitialValidationProfileClosure -WorkspaceRoot $active.root -ExpectedEvent $activeEvent)
Invoke-ProfileNative (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') @('-WorkspaceRoot',$active.root,'-RepositoryMapPath',$map,'-CurrentWorkOnly','-SkipOwnerSelfTests','-CurrentWorkspaceOnly')|Out-Null
Invoke-ProfileNative (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') @('-Action','BeginValidation','-WorkspaceRoot',$active.root,'-UnitId','initial-profile-001','-RepoMapPath',$map,'-Execute')|Out-Null
[void](Test-MorphospaceHistoricalInitialValidationProfileClosure -WorkspaceRoot $active.root -ExpectedEvent $activeEvent)
Invoke-ProfileNative (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') @('-WorkspaceRoot',$active.root,'-RepositoryMapPath',$map,'-CurrentWorkOnly','-SkipOwnerSelfTests','-CurrentWorkspaceOnly')|Out-Null
Write-Host "active correction and genuine Begin/current-work continuation passed"
$validating=New-ProfileCase 'validating-correction'
Invoke-ProfileNative (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') @('-Action','BeginValidation','-WorkspaceRoot',$validating.root,'-UnitId','initial-profile-001','-RepoMapPath',$map,'-Execute')|Out-Null
$validating.request=New-ProfileRequest $validating.root 'validating-correction';Write-ProfileJson $validating.input $validating.request
$validationUnitRaw=Get-MorphospaceFileSha256 (Join-Path $validating.root 'iteration-units/initial-profile-001.json')
Invoke-ProfileCase $validating -Execute|Out-Null
Assert-ProfileTest ((Get-MorphospaceFileSha256 (Join-Path $validating.root 'iteration-units/initial-profile-001.json'))-ceq$validationUnitRaw) 'Validating correction rewrote unit bytes'
Invoke-ProfileNative (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') @('-WorkspaceRoot',$validating.root,'-RepositoryMapPath',$map,'-CurrentWorkOnly','-SkipOwnerSelfTests','-CurrentWorkspaceOnly')|Out-Null
foreach($damage in @('late-source','late-request')){
    $case=New-ProfileCase $damage;$ledgerBefore=Get-MorphospaceFileSha256 (Join-Path $case.root 'iteration-events.jsonl')
    $hook={if($damage-ceq'late-source'){[IO.File]::AppendAllText((Join-Path $case.root 'source-compositions/initial-profile-001.lock.json')," ")}else{[IO.File]::AppendAllText($case.input," ")}}
    $refused=$false;try{Invoke-MorphospaceCorrectInitialValidationProfileClosure -WorkspaceRoot $case.root -UnitId initial-profile-001 -InitialValidationProfileCorrectionPath $case.input -ExpectedInitialValidationProfileCorrectionSha256 (Get-MorphospaceFileSha256 $case.input) -OutPath $case.out -BeforeTransitionHook $hook -Execute|Out-Null}catch{$refused=$_.Exception.Message.Contains('raw bytes')}
    Assert-ProfileTest ($refused-and(Get-MorphospaceFileSha256 (Join-Path $case.root 'iteration-events.jsonl'))-ceq$ledgerBefore-and-not(Test-Path -LiteralPath $case.out)-and-not(Test-Path -LiteralPath (Join-Path $case.root "receipts/transactions/$damage-recorded-transition.intent.json"))) 'Late controlled drift wrote a transition';$negativeCount++
}
foreach($fault in @('after-intent','after-artifact','after-projection','after-event')){
    $case=New-ProfileCase ("recovery-$fault")
    $faulted=$false;try{Invoke-ProfileCase $case -Execute -FaultAfter $fault|Out-Null}catch{$faulted=$_.Exception.Message.Contains('Injected interruption')}
    Assert-ProfileTest $faulted "Fault seam $fault not reached"
    Invoke-ProfileCase $case -Execute|Out-Null
    $committed=Snapshot-Profile $case.root;Invoke-ProfileCase $case -Execute|Out-Null;Assert-ProfileTest ((Snapshot-Profile $case.root)-ceq$committed) 'Authenticated recovery appended or rewrote twice'
    Assert-ProfileTest ((Get-MorphospaceFileSha256 (Join-Path $case.root 'iteration-units/initial-profile-001.json'))-ceq$unitRaw) 'Recovery changed unit raw bytes'
}
foreach($damage in @('recovery-source-drift','recovery-state-drift','recovery-target-drift','recovery-origin-completion-drift','recovery-unrelated-intent')){
    $case=New-ProfileCase $damage
    $faulted=$false;try{Invoke-ProfileCase $case -Execute -FaultAfter after-intent|Out-Null}catch{$faulted=$_.Exception.Message.Contains('Injected interruption')};Assert-ProfileTest $faulted 'Recovery refusal fixture did not earn an actual intent'
    switch($damage){
        'recovery-source-drift' {[IO.File]::AppendAllText((Join-Path $case.root 'source-compositions/initial-profile-001.lock.json')," ")}
        'recovery-state-drift' {[IO.File]::AppendAllText((Join-Path $case.root 'workspace.state.json')," ")}
        'recovery-target-drift' {$path=Join-Path $case.root "receipts/transactions/$damage-recorded-transition.intent.json";$intent=Read-ProfileJson $path;$intent.additional_projections[1].document.purpose='Unrelated projection';$intent.additional_projections[1].target_sha256=Get-MorphospaceCanonicalJsonSha256 $intent.additional_projections[1].document;Write-ProfileJson $path $intent}
        'recovery-origin-completion-drift' {$path=Join-Path $case.root 'receipts/transactions/initial-profile-001-claimed-0002-transition.completion.json';$completion=Read-ProfileJson $path;$completion.intent.sha256='0'*64;Write-ProfileJson $path $completion}
        'recovery-unrelated-intent' {[IO.File]::WriteAllText((Join-Path $case.root 'receipts/transactions/unrelated-transition.intent.json'),"{}`n")}
    }
    Assert-ProfileRefusal {Invoke-ProfileCase $case -Execute} '' $case.root;$negativeCount++
}
$historicalDamage=Join-Path $HarnessRoot 'historical-artifact-damage';Copy-Item -LiteralPath $active.root -Destination $historicalDamage -Recurse
[IO.File]::AppendAllText((Join-Path $historicalDamage 'receipts/active-correction.json')," ")
Assert-ProfileRefusal {Test-MorphospaceHistoricalInitialValidationProfileClosure -WorkspaceRoot $historicalDamage -ExpectedEvent $activeEvent} '' $historicalDamage;$negativeCount++
Invoke-ProfileAcceptedPrefixProbe $active.root $map (Join-Path $HarnessRoot 'accepted-prefix')
Write-Host "validating correction, four fault recoveries and $negativeCount strict no-write refusals passed"
[pscustomobject]@{result='pass';historical_owner=$oldCommit;harness_root=$HarnessRoot;negative_controls=$negativeCount;elapsed_seconds=$clock.Elapsed.TotalSeconds;commands_executed_for_profile_evidence=$false}|ConvertTo-Json -Compress
