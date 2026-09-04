Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BlockedSuccessorPreparation.psm1') -Force
function Assert-PreparationProvenanceJson { param([string]$Path,[string]$Schema,[string]$Message) if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $Path) -SchemaFile $Schema)){throw $Message} }
function Get-PreparationProvenanceCanonicalHash { param([object]$Value,[string]$Context) try{return Get-MorphospaceCanonicalJsonSha256 $Value}catch{throw "$Context canonical identity is invalid. $($_.Exception.Message)"} }
function Test-PreparationProvenancePathWithinRoots {
 param([string]$Path,[object[]]$Roots)
 foreach($rootValue in @($Roots)){$root=[string]$rootValue;if($Path-ceq$root-or$Path.StartsWith($root.TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)){return $true}}
 return $false
}
function Assert-PreparationProvenanceAdmissionClosure {
 param([object]$Admission,[object]$Envelope,[object]$Project,[object]$Source)
 $registeredProfiles=@($Project.validation_profiles|ForEach-Object{[string]$_.profile_id})
 $preparedProfiles=@($Envelope.build_envelope.allowed_profiles|ForEach-Object{[string]$_})
 $assessmentProfiles=@($Admission.agent_scope_assessment.build_envelope.allowed_profiles|ForEach-Object{[string]$_})
 foreach($validation in @($Admission.unit.validation)){$profile=[string]$validation.profile_id;if($registeredProfiles-cnotcontains$profile){throw "Admission unit validation profile '$profile' is not registered in the target project."};if($preparedProfiles-cnotcontains$profile-or$assessmentProfiles-cnotcontains$profile){throw "Admission unit validation profile '$profile' exceeds the prepared or assessed build-profile ceiling."}}
 $projectById=@{};foreach($row in @($Project.repositories)){$id=[string]$row.repo_id;if($projectById.ContainsKey($id)){throw "Admission target project repeats repository '$id'."};$projectById[$id]=$row}
 $assessmentById=@{};foreach($row in @($Admission.agent_scope_assessment.owner_repositories)){$id=[string]$row.repo_id;if($assessmentById.ContainsKey($id)){throw "Admission assessment repeats repository '$id'."};$assessmentById[$id]=$row}
 $preparedById=@{};foreach($row in @($Envelope.owner_repositories)){$id=[string]$row.repo_id;if($preparedById.ContainsKey($id)){throw "Admission prepared envelope repeats repository '$id'."};$preparedById[$id]=$row}
 $sourceIds=@{};foreach($row in @($Source.repositories)){$id=[string]$row.repo_id;if($sourceIds.ContainsKey($id)){throw "Admission source composition repeats repository '$id'."};$sourceIds[$id]=$true}
 foreach($dependency in @($(if($Admission.unit.PSObject.Properties.Name-contains'read_only_dependencies'){@($Admission.unit.read_only_dependencies)}else{@()}))){
  $id=[string]$dependency.repo_id
  if(-not$projectById.ContainsKey($id)-or-not$assessmentById.ContainsKey($id)-or-not$preparedById.ContainsKey($id)-or-not$sourceIds.ContainsKey($id)){throw "Admission read-only dependency repository '$id' is outside the exact project, assessment, preparation, and source-composition intersection."}
  foreach($pathValue in @($dependency.paths)){$path=[string]$pathValue;$directory=$path.EndsWith('/');$body=if($directory){$path.TrimEnd('/')}else{$path};$canonical=ConvertTo-MorphospaceProtocolRelativePath $body;if($directory){$canonical+='/' };if($canonical-cne$path){throw "Admission read-only dependency path '$id/$path' is not canonical."};if(-not(Test-PreparationProvenancePathWithinRoots $canonical @($projectById[$id].allowed_paths))-or-not(Test-PreparationProvenancePathWithinRoots $canonical @($assessmentById[$id].source_roots))-or-not(Test-PreparationProvenancePathWithinRoots $canonical @($preparedById[$id].source_roots))){throw "Admission read-only dependency path '$id/$canonical' exceeds the exact project, assessment, and preparation root intersection."}}
 }
}
function Assert-PreparationProvenanceCommittedTransaction {
 param([string]$Workspace,[string]$TransactionId,[object]$SuccessorIntent=$null,[switch]$AllowHistorical,[switch]$AllowIncomplete)
 $ledgerPath=Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1';$ledger=@(Get-Module -All|Where-Object{$_.Path-eq$ledgerPath}|Select-Object -Last 1)[0]
 if($null-eq$ledger){throw 'Prepared-envelope transition-ledger validator is unavailable.'}
 $lock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $Workspace
 try{
  &$ledger {
   param($root,$id,$successor,$historical,$incomplete)
   $workspace=[IO.Path]::GetFullPath($root);$intentRelative=Get-MorphospaceLedgerPath $workspace $id intent;$completionRelative=Get-MorphospaceLedgerPath $workspace $id completion
   $intentAbsolute=Resolve-MorphospaceWorkspacePath $workspace $intentRelative -RequireLeaf;$completionAbsolute=Resolve-MorphospaceWorkspacePath $workspace $completionRelative
   $intent=Read-MorphospaceLedgerJson $intentAbsolute;Assert-MorphospaceLedgerIntent $intent $id;Assert-MorphospaceLedgerArtifactNamespace $workspace $id $intent
   if(-not[IO.File]::Exists($completionAbsolute)){
    if(-not$incomplete){throw 'Prepared-envelope transition completion is missing.'}
    for($artifactIndex=0;$artifactIndex-lt@($intent.artifacts).Count;$artifactIndex++){$artifact=@($intent.artifacts)[$artifactIndex];$stageRelative=Get-MorphospaceLedgerArtifactStagePath $id $artifactIndex;$stageAbsolute=Resolve-MorphospaceWorkspacePath $workspace $stageRelative;$targetAbsolute=Resolve-MorphospaceWorkspacePath $workspace ([string]$artifact.path);$stagePresent=[IO.File]::Exists($stageAbsolute);$targetPresent=[IO.File]::Exists($targetAbsolute);if($stagePresent-eq$targetPresent){throw 'Prepared-envelope incomplete transition does not own exactly one staged or installed artifact projection.'};$ownedArtifact=if($stagePresent){$stageAbsolute}else{$targetAbsolute};if((Get-MorphospaceFileSha256 $ownedArtifact)-cne[string]$artifact.sha256){throw 'Prepared-envelope incomplete transition artifact differs from its intent.'}}
    return
   }
   if($null-eq$successor-and-not$historical){Assert-MorphospaceLedgerCommittedCompletion $workspace $id $intentRelative $intentAbsolute $intent $completionAbsolute;return}
   $completion=Read-MorphospaceLedgerJson $completionAbsolute;Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Prepared-envelope historical transition completion';Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Prepared-envelope historical transition completion intent reference'
   if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or[string]$completion.transaction_id-cne$id-or[string]$completion.status-cne'committed'-or[string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$intentRelative-or[string]$completion.intent.schema-cne[string]$intent.schema-or[string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $intentAbsolute)-or[string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256-or[string]$completion.event_id-cne[string]$intent.event.event_id){throw 'Prepared-envelope historical transition completion is not bound to its exact intent.'}
   $createdAt=Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at);$completedAt=Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at);if($completedAt-lt$createdAt){throw 'Prepared-envelope historical transition completion precedes its intent.'}
   $eventsAbsolute=Resolve-MorphospaceWorkspacePath $workspace ([string]$intent.events.path) -RequireLeaf;[void](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intent -AllowHistorical -RequirePresent)
   foreach($artifact in @($intent.artifacts)){$target=Resolve-MorphospaceWorkspacePath $workspace ([string]$artifact.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $target)-cne[string]$artifact.sha256){throw "Prepared-envelope historical transition artifact differs from its intent: $([string]$artifact.path)"}}
   if($null-ne$successor-and[string]$successor.pre.state.sha256-cne[string]$intent.target.state.sha256){throw 'Prepared-envelope successor intent does not continue from the historical transition state.'}
  } $Workspace $TransactionId $SuccessorIntent ([bool]$AllowHistorical) ([bool]$AllowIncomplete)
 }finally{Exit-MorphospaceWorkspaceMutex $lock}
}
function Test-PreparationProvenanceHasAdmissionConsumer {
 [CmdletBinding()]param(
  [Parameter(Mandatory)][string]$Workspace,
  [Parameter(Mandatory)][object]$Admission,
  [Parameter(Mandatory)][object]$PreparationIntent
 )
 $transactionRoot=Resolve-MorphospaceWorkspacePath $Workspace 'receipts/transactions'
 if(-not[IO.Directory]::Exists($transactionRoot)){return $false}
 $directConsumers=0
 foreach($intentFile in @(Get-ChildItem -LiteralPath $transactionRoot -File -Filter '*-admitted-transition.intent.json')){
  $transactionId=$intentFile.Name.Substring(0,$intentFile.Name.Length-'.intent.json'.Length)
  Assert-PreparationProvenanceCommittedTransaction -Workspace $Workspace -TransactionId $transactionId -AllowHistorical -AllowIncomplete
  $consumerIntent=Read-MorphospaceProtocolJson $intentFile.FullName
  if([string]$consumerIntent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'){throw 'Prepared-envelope admission-consumer intent has an unexpected schema.'}
  if(@($consumerIntent.artifacts).Count-ne1){throw 'Prepared-envelope admission consumer does not own exactly one admission artifact.'}
  try{$consumer=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Convert]::FromBase64String([string]$consumerIntent.artifacts[0].bytes_base64)) -Context 'prepared-envelope admission consumer'}catch{throw "Prepared-envelope admission consumer artifact is invalid. $($_.Exception.Message)"}
  if([string]$consumer.schema-cne'rusty.morphospace.workflow.development_unit_admission.v1'){throw 'Prepared-envelope admission consumer artifact has an unexpected schema.'}
  $completionPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$transactionId.completion.json";$completed=[IO.File]::Exists($completionPath)
  $preparationMatches=(Get-PreparationProvenanceCanonicalHash $consumer.preparation 'Prepared-envelope admission consumer preparation')-ceq(Get-PreparationProvenanceCanonicalHash $Admission.preparation 'Requested prepared-envelope admission preparation')
  if(-not$completed){if([string]$consumer.admission_id-cne[string]$Admission.admission_id){throw 'A different incomplete development-unit admission already owns workspace transition authority.'};if(-not$preparationMatches){throw 'The current incomplete development-unit admission contradicts its requested preparation identity.'}}
  $directTopology=[string]$consumerIntent.event.project_id-ceq[string]$Admission.project_id-and[string]$consumerIntent.expected.event_tail_id-ceq[string]$PreparationIntent.event.event_id-and[string]$consumerIntent.pre.state.sha256-ceq[string]$PreparationIntent.target.state.sha256-and[int]$consumerIntent.event.sequence-eq([int]$PreparationIntent.event.sequence+1)
  if(-not$preparationMatches){if($directTopology){throw 'Prepared-envelope admission consumer artifact contradicts its direct preparation topology.'};continue}
  if([string]$consumer.project_id-cne[string]$Admission.project_id-or[string]$consumerIntent.event.project_id-cne[string]$Admission.project_id){throw 'Prepared-envelope admission consumer uses the wrong project identity.'}
  if($directTopology){$directConsumers++;continue}
  if([string]$consumer.admission_id-cne[string]$Admission.admission_id){throw 'Prepared-envelope replacement admission is already reserved by a different admission identity.'}
 }
 if($directConsumers-gt1){throw 'Prepared envelope has more than one direct admission consumer.'}
 return $directConsumers-eq1
}
function Get-PreparationProvenanceAdmissionPrefix {
 [CmdletBinding()]param(
  [Parameter(Mandatory)][string]$Workspace,
  [Parameter(Mandatory)][object]$AdmissionIntent,
  [Parameter(Mandatory)][object]$State
 )
 $stateHash=Get-PreparationProvenanceCanonicalHash $State 'Prepared-envelope replacement recovery state'
 $admissionBoundary=@([string]$AdmissionIntent.pre.state.sha256,[string]$AdmissionIntent.target.state.sha256)-ccontains$stateHash
 $ledgerPath=Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1';$ledger=@(Get-Module -All|Where-Object{$_.Path-eq$ledgerPath}|Select-Object -Last 1)[0]
 if($null-eq$ledger){throw 'Prepared-envelope transition-ledger validator is unavailable.'}
 $lock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $Workspace
 try{
  $projection=&$ledger {
   param($root,$intent,$historical)
   $workspace=[IO.Path]::GetFullPath($root);$eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
   Assert-MorphospaceLedgerIntent $intent ([string]$intent.transaction_id);Assert-MorphospaceLedgerArtifactNamespace $workspace ([string]$intent.transaction_id) $intent
   $present=if($historical){Assert-MorphospaceLedgerEventPlacement $eventsPath $intent -AllowHistorical -RequirePresent}else{Assert-MorphospaceLedgerEventPlacement $eventsPath $intent};$snapshot=Get-MorphospaceLedgerSnapshot $eventsPath;$events=@($snapshot.events)
   $prefix=if($present-and$events.Count-gt1){@($events[0..($events.Count-2)])}elseif($present){@()}else{@($events)}
   [pscustomobject]@{events=$events;prefix=$prefix;event_present=[bool]$present}
  } $Workspace $AdmissionIntent (-not$admissionBoundary)
 }finally{Exit-MorphospaceWorkspaceMutex $lock}

 if($admissionBoundary){
  return [pscustomobject]@{events=@($projection.prefix);event_present=[bool]$projection.event_present}
 }

 if(-not[bool]$projection.event_present){throw 'Prepared-envelope replacement recovery state is outside its admission intent.'}
 $events=@($projection.events);$admissionEventId=[string]$AdmissionIntent.event.event_id;$admissionIndexes=@(for($index=0;$index-lt$events.Count;$index++){if([string]$events[$index].event_id-ceq$admissionEventId){$index}})
 if($admissionIndexes.Count-ne1){throw 'Prepared-envelope replacement admission event placement is ambiguous.'}
 $admissionIndex=[int]$admissionIndexes[0]
 $suffixCount=$events.Count-($admissionIndex+1)
 if($suffixCount-notin@(2,3)){throw 'Prepared-envelope replacement Freeze requires exactly the owner-produced Ready and Claim suffix, optionally followed by its own Freeze.'}

 $admissionEvent=$events[$admissionIndex];$readyEvent=$events[$admissionIndex+1];$claimEvent=$events[$admissionIndex+2]
 $unitId=[string]$AdmissionIntent.event.unit_id;$projectId=[string]$AdmissionIntent.event.project_id;$escapedUnitId=[regex]::Escape($unitId)
 if([string]$readyEvent.project_id-cne$projectId-or[string]$readyEvent.unit_id-cne$unitId-or[string]$readyEvent.event_type-cne'state-transition'-or
    [string]$readyEvent.event_id-cnotmatch"^$escapedUnitId-ready-[0-9]{4}$"-or[int]$readyEvent.sequence-ne([int]$admissionEvent.sequence+1)-or
    [string]$readyEvent.summary-cne'Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites.'-or@($readyEvent.receipts).Count-ne0){throw 'Prepared-envelope replacement Ready event is not exact.'}
 if([string]$claimEvent.project_id-cne$projectId-or[string]$claimEvent.unit_id-cne$unitId-or[string]$claimEvent.event_type-cne'state-transition'-or
    [string]$claimEvent.event_id-cnotmatch"^$escapedUnitId-claimed-[0-9]{4}$"-or[int]$claimEvent.sequence-ne([int]$readyEvent.sequence+1)-or
    [string]$claimEvent.summary-cne'Claimed one ready iteration unit without expanding repository or path scope.'-or@($claimEvent.receipts).Count-ne0){throw 'Prepared-envelope replacement Claim event is not exact.'}

 $readyTransactionId="$([string]$readyEvent.event_id)-transition";$claimTransactionId="$([string]$claimEvent.event_id)-transition"
 $readyIntent=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$readyTransactionId.intent.json" -RequireLeaf)
 $claimIntent=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$claimTransactionId.intent.json" -RequireLeaf)
 $unitRelative="iteration-units/$unitId.json";$liveUnit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace $unitRelative -RequireLeaf)
 $freezeEvent=if($suffixCount-eq3){$events[$admissionIndex+3]}else{$null};$freezeIntent=$null
 Assert-PreparationProvenanceCommittedTransaction -Workspace $Workspace -TransactionId ([string]$AdmissionIntent.transaction_id) -SuccessorIntent $readyIntent
 Assert-PreparationProvenanceCommittedTransaction -Workspace $Workspace -TransactionId $readyTransactionId -SuccessorIntent $claimIntent
 if($null-eq$freezeEvent){
  Assert-PreparationProvenanceCommittedTransaction -Workspace $Workspace -TransactionId $claimTransactionId
 }else{
  if(-not($liveUnit.PSObject.Properties.Name-contains'candidate_freeze')){throw 'Prepared-envelope replacement post-Claim event is not an owned candidate Freeze.'}
  $freezeId=[string]$liveUnit.candidate_freeze.freeze_id;$freezeReceipt=[string]$liveUnit.candidate_freeze.receipt_path
  if([string]$freezeEvent.project_id-cne$projectId-or[string]$freezeEvent.unit_id-cne$unitId-or[string]$freezeEvent.event_type-cne'state-transition'-or
     [string]$freezeEvent.event_id-cne"$freezeId-recorded"-or[int]$freezeEvent.sequence-ne([int]$claimEvent.sequence+1)-or
     [string]$freezeEvent.summary-cne'Froze the exact candidate closure before validation.'-or@($freezeEvent.receipts).Count-ne1-or[string]$freezeEvent.receipts[0]-cne$freezeReceipt){throw 'Prepared-envelope replacement candidate Freeze event is not exact.'}
  $freezeTransactionId="$([string]$freezeEvent.event_id)-transition";$freezeIntent=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$freezeTransactionId.intent.json" -RequireLeaf)
  Assert-PreparationProvenanceCommittedTransaction -Workspace $Workspace -TransactionId $claimTransactionId -SuccessorIntent $freezeIntent
  Assert-PreparationProvenanceCommittedTransaction -Workspace $Workspace -TransactionId $freezeTransactionId
 }

 if([string]$readyIntent.unit.path-cne$unitRelative-or[string]$claimIntent.unit.path-cne$unitRelative-or
    (Get-PreparationProvenanceCanonicalHash $readyIntent.event 'Prepared-envelope replacement Ready intent event')-cne(Get-PreparationProvenanceCanonicalHash $readyEvent 'Prepared-envelope replacement live Ready event')-or
    (Get-PreparationProvenanceCanonicalHash $claimIntent.event 'Prepared-envelope replacement Claim intent event')-cne(Get-PreparationProvenanceCanonicalHash $claimEvent 'Prepared-envelope replacement live Claim event')-or
    [string]$readyIntent.target.unit.document.status-cne'ready'-or[string]$readyIntent.target.state.document.next_ready_unit-cne$unitId-or
    [string]$claimIntent.target.unit.document.status-cne'active'-or[string]$claimIntent.target.state.document.current_unit-cne$unitId-or$null-ne$claimIntent.target.state.document.next_ready_unit-or
    [string]$liveUnit.status-cne'active'-or[string]$liveUnit.unit_id-cne$unitId){throw 'Prepared-envelope replacement Ready and Claim transactions do not own the exact live projection.'}
 $terminalEvent=if($null-ne$freezeEvent){$freezeEvent}else{$claimEvent};$terminalIntent=if($null-ne$freezeIntent){$freezeIntent}else{$claimIntent}
 if([string]$State.project_id-cne$projectId-or[string]$State.current_unit-cne$unitId-or$null-ne$State.next_ready_unit-or[string]$State.last_event_id-cne[string]$terminalEvent.event_id-or
    [string]$terminalIntent.target.state.sha256-cne$stateHash-or[string]$terminalIntent.target.unit.sha256-cne(Get-PreparationProvenanceCanonicalHash $liveUnit 'Prepared-envelope replacement live terminal unit')){throw 'Prepared-envelope replacement live ownership does not match its exact owner suffix.'}
 if($null-ne$freezeIntent-and([string]$freezeIntent.unit.path-cne$unitRelative-or
    (Get-PreparationProvenanceCanonicalHash $freezeIntent.event 'Prepared-envelope replacement Freeze intent event')-cne(Get-PreparationProvenanceCanonicalHash $freezeEvent 'Prepared-envelope replacement live Freeze event')-or
    [string]$freezeIntent.target.unit.document.candidate_freeze.freeze_id-cne[string]$liveUnit.candidate_freeze.freeze_id-or
    [string]$freezeIntent.target.unit.document.candidate_freeze.receipt_path-cne[string]$liveUnit.candidate_freeze.receipt_path-or
    [string]$freezeIntent.target.unit.document.candidate_freeze.receipt_sha256-cne[string]$liveUnit.candidate_freeze.receipt_sha256)){throw 'Prepared-envelope replacement Freeze transaction does not own the exact candidate marker.'}

 $prefix=if($admissionIndex-gt0){@($events[0..($admissionIndex-1)])}else{@()}
 return [pscustomobject]@{events=$prefix;event_present=$true}
}
function Test-MorphospacePreparedEnvelopeReplacementSuffix {
 [CmdletBinding()]param(
  [Parameter(Mandatory)][string]$Workspace,
  [Parameter(Mandatory)][string]$RepoRoot,
  [Parameter(Mandatory)][object]$Admission,
  [Parameter(Mandatory)][object]$PreparationIntent,
  [Parameter(Mandatory)][object]$PreparationCompletion,
  [Parameter(Mandatory)][object]$State,
  [Parameter(Mandatory)][object[]]$Events,
  [object]$AdmissionIntent=$null
 )
 $claimedReplacement=$null-ne$AdmissionIntent-and[string]$State.current_unit-ceq[string]$Admission.unit_id-and$null-eq$State.next_ready_unit
 if(-not$claimedReplacement-and($null-ne$State.current_unit-or$null-ne$State.next_ready_unit)){throw 'Prepared-envelope replacement admission requires an idle project.'}
 if($Events.Count-lt3){throw 'Prepared-envelope replacement admission lacks its exact transition suffix.'}

 $preparationEvent=$Events[$Events.Count-3];$admissionEvent=$Events[$Events.Count-2];$retirementEvent=$Events[$Events.Count-1]
 if([string]$preparationEvent.event_id-cne[string]$PreparationCompletion.event_id-or
    [string]$preparationEvent.event_id-cne[string]$PreparationIntent.event.event_id-or
    [string]$admissionEvent.project_id-cne[string]$Admission.project_id-or
    [string]$retirementEvent.project_id-cne[string]$Admission.project_id-or
     ($null-eq$AdmissionIntent-and[string]$State.last_event_id-cne[string]$retirementEvent.event_id)-or
     ($null-ne$AdmissionIntent-and[string]$AdmissionIntent.expected.event_tail_id-cne[string]$retirementEvent.event_id)-or
    [int]$admissionEvent.sequence-ne([int]$preparationEvent.sequence+1)-or
    [int]$retirementEvent.sequence-ne([int]$admissionEvent.sequence+1)-or
    @($retirementEvent.receipts).Count-ne1){throw 'Prepared-envelope replacement admission transition suffix is not exact.'}

 $retirementReceiptRelative=[string]$retirementEvent.receipts[0]
 $retirementReceiptPath=Resolve-MorphospaceWorkspacePath $Workspace $retirementReceiptRelative -RequireLeaf
 Assert-PreparationProvenanceJson $retirementReceiptPath (Join-Path $RepoRoot 'schemas\work-unit-automation-receipt.schema.json') 'Prepared-envelope replacement retirement receipt is invalid.'
 $retirementReceipt=Read-MorphospaceProtocolJson $retirementReceiptPath;$proposedRetirement=$retirementReceipt.proposed_retirement
 if([string]$retirementReceipt.project_id-cne[string]$Admission.project_id-or
    [string]$retirementReceipt.unit_id-cne[string]$retirementEvent.unit_id-or
    [string]$retirementReceipt.action-cne'RetireProposed'-or-not[bool]$retirementReceipt.executed-or
    [string]$retirementReceipt.transition-cne'proposed-to-superseded-retired'-or
    [string]$retirementReceipt.status_before-cne'proposed'-or[string]$retirementReceipt.status_after-cne'superseded'-or
    $null-ne$retirementReceipt.current_unit_before-or$null-ne$retirementReceipt.current_unit_after-or
    [string]$retirementReceipt.event_id-cne[string]$retirementEvent.event_id-or
    [string]$proposedRetirement.replacement_unit_id-cne[string]$Admission.unit_id){throw 'Prepared-envelope replacement retirement semantics are not exact.'}
 $retirementBinding=[pscustomobject][ordered]@{
  replacement_unit_id=$proposedRetirement.replacement_unit_id;reason=$proposedRetirement.reason
  authenticated_admission=$proposedRetirement.authenticated_admission;authenticated_preimage=$proposedRetirement.authenticated_preimage
  replacement_identity_absent=$proposedRetirement.replacement_identity_absent;current_unit_absent=$proposedRetirement.current_unit_absent
  next_ready_unit_absent=$proposedRetirement.next_ready_unit_absent;original_admission_preserved=$proposedRetirement.original_admission_preserved
 }
 if((Get-PreparationProvenanceCanonicalHash $retirementBinding 'Prepared-envelope replacement retirement binding')-cne[string]$proposedRetirement.binding_sha256){throw 'Prepared-envelope replacement retirement binding is invalid.'}

 $retirementTransactionId="$([string]$retirementEvent.event_id)-transition"
 $retirementIntentPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$retirementTransactionId.intent.json" -RequireLeaf
 $retirementCompletionPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$retirementTransactionId.completion.json" -RequireLeaf
  Assert-PreparationProvenanceCommittedTransaction -Workspace $Workspace -TransactionId $retirementTransactionId -SuccessorIntent $AdmissionIntent
 $retirementIntent=Read-MorphospaceProtocolJson $retirementIntentPath;$retirementCompletion=Read-MorphospaceProtocolJson $retirementCompletionPath
 $retiredUnitPath=Resolve-MorphospaceWorkspacePath $Workspace "iteration-units/$([string]$retirementReceipt.unit_id).json" -RequireLeaf
 $retiredUnit=Read-MorphospaceProtocolJson $retiredUnitPath
 if([string]$retirementIntent.unit.path-cne"iteration-units/$([string]$retirementReceipt.unit_id).json"-or
    [string]$retirementIntent.event.event_id-cne[string]$retirementEvent.event_id-or
    (Get-PreparationProvenanceCanonicalHash $retirementIntent.event 'Prepared-envelope replacement retirement intent event')-cne(Get-PreparationProvenanceCanonicalHash $retirementEvent 'Prepared-envelope replacement retirement live event')-or
    @($retirementIntent.artifacts).Count-ne1-or[string]$retirementIntent.artifacts[0].path-cne$retirementReceiptRelative-or
     ($null-eq$AdmissionIntent-and[string]$retirementIntent.target.state.sha256-cne(Get-PreparationProvenanceCanonicalHash $State 'Prepared-envelope replacement live state'))-or
     ($null-ne$AdmissionIntent-and[string]$retirementIntent.target.state.sha256-cne[string]$AdmissionIntent.pre.state.sha256)-or
    [string]$retirementIntent.target.unit.sha256-cne(Get-PreparationProvenanceCanonicalHash $retiredUnit 'Prepared-envelope replacement retired unit')-or
    [string]$retiredUnit.status-cne'superseded'-or[string]$retiredUnit.unit_id-cne[string]$retirementReceipt.unit_id-or
    [string]$retirementCompletion.event_id-cne[string]$retirementEvent.event_id){throw 'Prepared-envelope replacement retirement transaction does not own the live suffix.'}

 $authenticatedAdmission=$proposedRetirement.authenticated_admission
 $oldAdmissionReceiptPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$authenticatedAdmission.receipt.path) -RequireLeaf
 if((Get-MorphospaceFileSha256 $oldAdmissionReceiptPath)-cne[string]$authenticatedAdmission.receipt.sha256){throw 'Prepared-envelope replacement predecessor admission receipt bytes drifted.'}
 Assert-PreparationProvenanceJson $oldAdmissionReceiptPath (Join-Path $RepoRoot 'schemas\development-unit-admission-v1.schema.json') 'Prepared-envelope replacement predecessor admission receipt is invalid.'
 $oldAdmission=Read-MorphospaceProtocolJson $oldAdmissionReceiptPath;$oldAdmissionTransactionId=[string]$authenticatedAdmission.transaction.transaction_id
 $oldAdmissionIntentPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$authenticatedAdmission.transaction.intent.path) -RequireLeaf
 $oldAdmissionCompletionPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$authenticatedAdmission.transaction.completion.path) -RequireLeaf
 if((Get-MorphospaceFileSha256 $oldAdmissionIntentPath)-cne[string]$authenticatedAdmission.transaction.intent.sha256-or
    (Get-MorphospaceFileSha256 $oldAdmissionCompletionPath)-cne[string]$authenticatedAdmission.transaction.completion.sha256){throw 'Prepared-envelope replacement predecessor admission transaction bytes drifted.'}
  Assert-PreparationProvenanceCommittedTransaction -Workspace $Workspace -TransactionId $oldAdmissionTransactionId -SuccessorIntent $(if($null-ne$AdmissionIntent){$retirementIntent}else{$null})
 $oldAdmissionIntent=Read-MorphospaceProtocolJson $oldAdmissionIntentPath;$oldAdmissionCompletion=Read-MorphospaceProtocolJson $oldAdmissionCompletionPath
 if([string]$oldAdmission.admission_id-cne[string]$authenticatedAdmission.admission_id-or
    [string]$oldAdmission.project_id-cne[string]$Admission.project_id-or
    [string]$oldAdmission.unit_id-cne[string]$retirementReceipt.unit_id-or
    [string]$oldAdmission.unit.unit_id-cne[string]$retirementReceipt.unit_id-or
    [string]$oldAdmission.unit.status-cne'proposed'-or
    (Get-PreparationProvenanceCanonicalHash $oldAdmission.preparation 'Prepared-envelope predecessor preparation')-cne(Get-PreparationProvenanceCanonicalHash $Admission.preparation 'Prepared-envelope replacement preparation')-or
    [string]$oldAdmissionTransactionId-cne"$([string]$oldAdmission.admission_id)-admitted-transition"-or
    [string]$oldAdmissionIntent.event.event_id-cne[string]$admissionEvent.event_id-or
    (Get-PreparationProvenanceCanonicalHash $oldAdmissionIntent.event 'Prepared-envelope predecessor admission intent event')-cne(Get-PreparationProvenanceCanonicalHash $admissionEvent 'Prepared-envelope predecessor live admission event')-or
    [string]$authenticatedAdmission.event.event_id-cne[string]$admissionEvent.event_id-or
    [int]$authenticatedAdmission.event.sequence-ne[int]$admissionEvent.sequence-or
    [string]$authenticatedAdmission.event.sha256-cne(Get-PreparationProvenanceCanonicalHash $admissionEvent 'Prepared-envelope authenticated admission event')-or
    [string]$oldAdmissionIntent.pre.state.sha256-cne[string]$PreparationIntent.target.state.sha256-or
    [string]$oldAdmissionIntent.target.state.sha256-cne[string]$retirementIntent.pre.state.sha256-or
    [string]$oldAdmissionIntent.target.unit.sha256-cne[string]$retirementIntent.pre.unit.sha256-or
    [string]$authenticatedAdmission.transaction.target_state_sha256-cne[string]$oldAdmissionIntent.target.state.sha256-or
    [string]$authenticatedAdmission.transaction.target_unit_sha256-cne[string]$oldAdmissionIntent.target.unit.sha256-or
    [string]$oldAdmissionCompletion.event_id-cne[string]$admissionEvent.event_id){throw 'Prepared-envelope replacement predecessor admission is not the direct authenticated preparation consumer.'}
 return $true
}
function Test-MorphospacePreparedDevelopmentEnvelope {
 [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Admission,[ValidateSet('Admission','Freeze')][string]$Phase='Admission')
 $workspace=(Resolve-Path $WorkspaceRoot).Path;$repoRoot=Split-Path $PSScriptRoot -Parent;$p=$Admission.preparation
 $admissionPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$p.receipt_path) -RequireLeaf
 if((Get-MorphospaceFileSha256 $admissionPath)-cne[string]$p.receipt_sha256){throw 'Prepared-envelope admission receipt bytes drifted.'}
 $receipt=Read-MorphospaceProtocolJson $admissionPath;Assert-PreparationProvenanceJson $admissionPath (Join-Path $repoRoot 'schemas\development-envelope-preparation-receipt-v1.schema.json') 'Prepared-envelope receipt schema is invalid.'
 $recovered=$p.PSObject.Properties.Name-contains'preparation_kind'-and[string]$p.preparation_kind-ceq'recovered';$recoveryReceipt=$null
 if($recovered){$recoveryPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$p.recovery_receipt_path) -RequireLeaf;if((Get-MorphospaceFileSha256 $recoveryPath)-cne[string]$p.recovery_receipt_sha256){throw 'Recovered prepared-envelope recovery receipt bytes drifted.'};Assert-PreparationProvenanceJson $recoveryPath (Join-Path $repoRoot 'schemas\development-envelope-repreparation-receipt-v1.schema.json') 'Recovered prepared-envelope recovery receipt is invalid.';$recoveryReceipt=Read-MorphospaceProtocolJson $recoveryPath;if([string]$recoveryReceipt.preparation_id-cne[string]$p.preparation_id){throw 'Recovered prepared-envelope recovery receipt names a different preparation.'};$tx="$([string]$recoveryReceipt.repreparation_id)-transition"}else{$tx="$([string]$p.preparation_id)-prepared-transition"}
 $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$tx.intent.json" -RequireLeaf;$completionPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$tx.completion.json" -RequireLeaf
 $intentSchema=if($recovered){'development-envelope-repreparation-intent-v1.schema.json'}else{'development-envelope-preparation-intent-v1.schema.json'};$completionSchema=if($recovered){'development-envelope-repreparation-completion-v1.schema.json'}else{'development-envelope-preparation-completion-v1.schema.json'}
 Assert-PreparationProvenanceJson $intentPath (Join-Path $repoRoot "schemas\$intentSchema") 'Prepared-envelope intent schema is invalid.';Assert-PreparationProvenanceJson $completionPath (Join-Path $repoRoot "schemas\$completionSchema") 'Prepared-envelope completion schema is invalid.'
 $intent=Read-MorphospaceProtocolJson $intentPath;$completion=Read-MorphospaceProtocolJson $completionPath;$sourcePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$p.source_composition_path) -RequireLeaf
 $sourceSchema=if($recovered){'schemas\development-envelope-source-composition-v2.schema.json'}else{'schemas\development-envelope-source-composition-v1.schema.json'};Assert-PreparationProvenanceJson $sourcePath (Join-Path $repoRoot $sourceSchema) 'Prepared-envelope source lock schema is invalid.'
 $source=Read-MorphospaceProtocolJson $sourcePath;$project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$lock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
 $scope=$Admission.agent_scope_assessment;$envelope=$receipt.envelope;foreach($name in @('allowed_change_categories','allowed_effect_categories','allowed_permission_categories')){if($null-eq$envelope.$name){throw "Prepared-envelope omits $name."};foreach($value in @($scope.$name)){if(@($envelope.$name)-cnotcontains$value){throw "Admission scope exceeds prepared $name."}}};if([string]$scope.public_private_boundary-cne[string]$envelope.public_private_boundary-or[string]$scope.build_envelope.class-cne[string]$envelope.build_envelope.class-or[string]$scope.device_envelope.requirement-cne[string]$envelope.device_envelope.requirement){throw 'Admission public/private, build, or device ceiling exceeds the prepared envelope.'}
 foreach($profile in @($scope.build_envelope.allowed_profiles)){if(@($envelope.build_envelope.allowed_profiles)-cnotcontains[string]$profile){throw 'Admission build profile exceeds the prepared envelope.'}}
 foreach($kind in @($scope.device_envelope.allowed_kinds)){if(@($envelope.device_envelope.allowed_kinds)-cnotcontains[string]$kind){throw 'Admission device kind exceeds the prepared envelope.'}}
  foreach($owner in @($scope.owner_repositories)){$prepared=@($envelope.owner_repositories|Where-Object{[string]$_.repo_id-ceq[string]$owner.repo_id});if($prepared.Count-ne1){throw 'Admission repository identity exceeds the prepared envelope.'};foreach($root in @($owner.source_roots)){if(@($prepared[0].source_roots)-cnotcontains[string]$root){throw 'Admission source root exceeds the prepared envelope.'}}}
  Assert-PreparationProvenanceAdmissionClosure $Admission $envelope $project $source
 if([string]$Admission.unit.source_composition.lock_path-cne[string]$p.source_composition_path){throw 'Admission unit does not bind the canonical prepared source lock.'}
 $artifacts=@($intent.artifacts);$receiptArtifact=@($artifacts|Where-Object{[string]$_.path-ceq[string]$p.receipt_path});$sourceArtifact=@($artifacts|Where-Object{[string]$_.path-ceq[string]$p.source_composition_path})
 $sourceRawFileSha256=Get-MorphospaceFileSha256 $sourcePath;$sourceCanonicalJsonSha256=Get-MorphospaceCanonicalJsonSha256 $source;$receiptCanonicalJsonSha256=Get-MorphospaceCanonicalJsonSha256 $receipt;$receiptRawFileSha256=Get-MorphospaceFileSha256 $admissionPath
 $receiptBytesBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($admissionPath));$sourceBytesBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sourcePath))
 $receiptArtifactHash=if($recovered){$receiptRawFileSha256}else{$receiptCanonicalJsonSha256};$sourceArtifactHash=if($recovered){$sourceRawFileSha256}else{$sourceCanonicalJsonSha256}
  if([string]$receipt.preparation_id-cne[string]$p.preparation_id-or[string]$source.preparation_id-cne[string]$p.preparation_id-or[string]$receipt.source_composition.path-cne[string]$p.source_composition_path-or[string]$receipt.source_composition.sha256-cne$sourceCanonicalJsonSha256-or[string]$p.source_composition_sha256-cne$sourceRawFileSha256-or[string]$Admission.expected.repository_map_path-cne[string]$intent.pre.repository_map.path-or[string]$Admission.expected.repository_map_sha256-cne[string]$intent.pre.repository_map.sha256-or[string]$intent.transaction_id-cne$tx-or[string]$completion.transaction_id-cne$tx-or[string]$completion.intent_sha256-cne(Get-MorphospaceFileSha256 $intentPath)-or$receiptArtifact.Count-ne1-or$sourceArtifact.Count-ne1-or[string]$receiptArtifact[0].sha256-cne$receiptArtifactHash-or[string]$sourceArtifact[0].sha256-cne$sourceArtifactHash-or[string]$receiptArtifact[0].bytes_base64-cne$receiptBytesBase64-or[string]$sourceArtifact[0].bytes_base64-cne$sourceBytesBase64){throw 'Prepared-envelope artifact provenance is not exact.'}
 if($recovered){$recoveryArtifact=@($artifacts|Where-Object{[string]$_.path-ceq[string]$p.recovery_receipt_path});$recoveryRawSha256=Get-MorphospaceFileSha256 $recoveryPath;$recoveryBytesBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($recoveryPath));$historyIdentity=[pscustomobject][ordered]@{retirement=$recoveryReceipt.retirement;original_preparation=$recoveryReceipt.original_preparation;preserved_evidence=@($recoveryReceipt.preserved_evidence)};if([string]$recoveryReceipt.project_id-cne[string]$Admission.project_id-or[string]$recoveryReceipt.replacement_unit_id-cne[string]$Admission.unit_id-or[string]$recoveryReceipt.retired_unit_id-cne[string]$receipt.predecessor_unit_id-or[string]$recoveryReceipt.preparation_id-cne[string]$p.preparation_id-or[string]$recoveryReceipt.input_sha256-cne[string]$receipt.input_sha256-or[string]$recoveryReceipt.input_sha256-cne[string]$intent.input_sha256-or[string]$recoveryReceipt.source_composition.path-cne[string]$p.source_composition_path-or[string]$recoveryReceipt.source_composition.sha256-cne$sourceRawFileSha256-or[string]$recoveryReceipt.history_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $historyIdentity)-or(Get-MorphospaceCanonicalJsonSha256 @($recoveryReceipt.preserved_evidence))-cne(Get-MorphospaceCanonicalJsonSha256 @($intent.preserved_evidence))-or$recoveryArtifact.Count-ne1-or[string]$recoveryArtifact[0].sha256-cne$recoveryRawSha256-or[string]$recoveryArtifact[0].bytes_base64-cne$recoveryBytesBase64-or[string]$completion.repreparation_receipt_sha256-cne$recoveryRawSha256){throw 'Recovered prepared-envelope transaction does not bind its exact project, units, input, source, history, and recovery-receipt bytes.'}}
 if([string]$intent.target.project.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $project)-or[string]$intent.target.feature_lock.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $lock)-or[string]$completion.target_project_sha256-cne[string]$intent.target.project.sha256-or[string]$completion.target_feature_lock_sha256-cne[string]$intent.target.feature_lock.sha256-or[string]$completion.target_state_sha256-cne[string]$intent.target.state.sha256){throw 'Prepared-envelope completion target bytes drifted.'}
 $events=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_}|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$_)) -Context 'prepared-envelope event ledger'});$event=@($events|Where-Object{[string]$_.event_id-ceq[string]$completion.event_id});if($event.Count-ne1-or[string]$event[0].project_id-cne[string]$Admission.project_id-or[string]$event[0].unit_id-cne[string]$receipt.predecessor_unit_id-or[string]$event[0].event_id-cne[string]$intent.event.event_id-or(Get-PreparationProvenanceCanonicalHash $event[0] 'Prepared-envelope live preparation event')-cne(Get-PreparationProvenanceCanonicalHash $intent.event 'Prepared-envelope intent event')){throw 'Prepared-envelope event provenance is invalid.'}
 if($Phase-ceq'Admission'){
  $preparedStateExact=[string]$intent.target.state.sha256-ceq(Get-MorphospaceCanonicalJsonSha256 $state)
  $preparationOwnsTail=$events.Count-gt0-and[string]$events[-1].event_id-ceq[string]$event[0].event_id-and[string]$state.last_event_id-ceq[string]$event[0].event_id
  $preparationAlreadyConsumed=Test-PreparationProvenanceHasAdmissionConsumer -Workspace $workspace -Admission $Admission -PreparationIntent $intent
  if(-not($preparedStateExact-and$preparationOwnsTail-and-not$preparationAlreadyConsumed)){
   try{[void](Test-MorphospacePreparedEnvelopeReplacementSuffix -Workspace $workspace -RepoRoot $repoRoot -Admission $Admission -PreparationIntent $intent -PreparationCompletion $completion -State $state -Events $events)}catch{throw "Prepared-envelope admission state or event tail drifted before unit admission. $($_.Exception.Message)"}
  }
 }elseif($Phase-ceq'Freeze'){
  $admissionTransactionId="$([string]$Admission.admission_id)-admitted-transition";$admissionIntentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$admissionTransactionId.intent.json"
  if([IO.File]::Exists($admissionIntentPath)){
   $admissionIntent=Read-MorphospaceProtocolJson $admissionIntentPath
   if([string]$admissionIntent.expected.event_tail_id-cne[string]$intent.event.event_id){
    try{$projection=Get-PreparationProvenanceAdmissionPrefix -Workspace $workspace -AdmissionIntent $admissionIntent -State $state;[void](Test-MorphospacePreparedEnvelopeReplacementSuffix -Workspace $workspace -RepoRoot $repoRoot -Admission $Admission -PreparationIntent $intent -PreparationCompletion $completion -State $state -Events @($projection.events) -AdmissionIntent $admissionIntent)}catch{throw "Prepared-envelope replacement recovery provenance is invalid. $($_.Exception.Message)"}
   }
  }
 }
 return [pscustomobject]@{receipt=$receipt;intent=$intent;completion=$completion;source_lock=$source;project=$project;feature_lock=$lock;state=$state}
}
function Get-MorphospaceDevelopmentAdmissionKind {
 [CmdletBinding()]param([Parameter(Mandatory)][object]$Admission)
 if($Admission.PSObject.Properties.Name-contains'admission_kind'){return [string]$Admission.admission_kind}
 return 'ordinary'
}
function Test-MorphospaceDevelopmentUnitPreparation {
 [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Admission,[ValidateSet('Admission','Freeze','Release')][string]$Phase='Admission')
 $kind=Get-MorphospaceDevelopmentAdmissionKind $Admission
 if($kind-ceq'ordinary'){
  if($Admission.PSObject.Properties.Name-contains'blocked_successor'){throw 'Ordinary admission may not carry blocked-successor provenance.'}
  return Test-MorphospacePreparedDevelopmentEnvelope -WorkspaceRoot $WorkspaceRoot -Admission $Admission -Phase $(if($Phase-ceq'Release'){'Freeze'}else{$Phase})
 }
 if($kind-cne'blocked-successor'){throw "Unknown development admission kind '$kind'."}
 if(-not($Admission.PSObject.Properties.Name-contains'blocked_successor')){throw 'Blocked-successor admission lacks its closed terminal binding.'}
 return Test-MorphospaceBlockedSuccessorPreparation -WorkspaceRoot $WorkspaceRoot -Admission $Admission -Phase $Phase
}
Export-ModuleMember -Function Test-MorphospacePreparedDevelopmentEnvelope,Get-MorphospaceDevelopmentAdmissionKind,Test-MorphospaceDevelopmentUnitPreparation
