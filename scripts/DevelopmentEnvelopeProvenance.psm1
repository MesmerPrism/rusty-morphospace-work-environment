Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
function Assert-PreparationProvenanceJson { param([string]$Path,[string]$Schema,[string]$Message) if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $Path) -SchemaFile $Schema)){throw $Message} }
function Get-PreparationProvenanceCanonicalHash { param([object]$Value,[string]$Context) try{return Get-MorphospaceCanonicalJsonSha256 $Value}catch{throw "$Context canonical identity is invalid. $($_.Exception.Message)"} }
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
 if(@([string]$AdmissionIntent.pre.state.sha256,[string]$AdmissionIntent.target.state.sha256)-cnotcontains$stateHash){throw 'Prepared-envelope replacement recovery state is outside its admission intent.'}
 $ledgerPath=Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1';$ledger=@(Get-Module -All|Where-Object{$_.Path-eq$ledgerPath}|Select-Object -Last 1)[0]
 if($null-eq$ledger){throw 'Prepared-envelope transition-ledger validator is unavailable.'}
 $lock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $Workspace
 try{
  return &$ledger {
   param($root,$intent)
   $workspace=[IO.Path]::GetFullPath($root);$eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
   Assert-MorphospaceLedgerIntent $intent ([string]$intent.transaction_id);Assert-MorphospaceLedgerArtifactNamespace $workspace ([string]$intent.transaction_id) $intent
   $present=Assert-MorphospaceLedgerEventPlacement $eventsPath $intent;$snapshot=Get-MorphospaceLedgerSnapshot $eventsPath;$events=@($snapshot.events)
   $prefix=if($present-and$events.Count-gt1){@($events[0..($events.Count-2)])}elseif($present){@()}else{@($events)}
   [pscustomobject]@{events=$prefix;event_present=[bool]$present}
  } $Workspace $AdmissionIntent
 }finally{Exit-MorphospaceWorkspaceMutex $lock}
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
 if($null-ne$State.current_unit-or$null-ne$State.next_ready_unit){throw 'Prepared-envelope replacement admission requires an idle project.'}
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
 $tx="$([string]$p.preparation_id)-prepared-transition";$intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$tx.intent.json" -RequireLeaf;$completionPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$tx.completion.json" -RequireLeaf
 Assert-PreparationProvenanceJson $intentPath (Join-Path $repoRoot 'schemas\development-envelope-preparation-intent-v1.schema.json') 'Prepared-envelope intent schema is invalid.';Assert-PreparationProvenanceJson $completionPath (Join-Path $repoRoot 'schemas\development-envelope-preparation-completion-v1.schema.json') 'Prepared-envelope completion schema is invalid.'
 $intent=Read-MorphospaceProtocolJson $intentPath;$completion=Read-MorphospaceProtocolJson $completionPath;$sourcePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$p.source_composition_path) -RequireLeaf
 Assert-PreparationProvenanceJson $sourcePath (Join-Path $repoRoot 'schemas\development-envelope-source-composition-v1.schema.json') 'Prepared-envelope source lock schema is invalid.'
 $source=Read-MorphospaceProtocolJson $sourcePath;$project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$lock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
 $scope=$Admission.agent_scope_assessment;$envelope=$receipt.envelope;foreach($name in @('allowed_change_categories','allowed_effect_categories','allowed_permission_categories')){if($null-eq$envelope.$name){throw "Prepared-envelope omits $name."};foreach($value in @($scope.$name)){if(@($envelope.$name)-cnotcontains$value){throw "Admission scope exceeds prepared $name."}}};if([string]$scope.public_private_boundary-cne[string]$envelope.public_private_boundary-or[string]$scope.build_envelope.class-cne[string]$envelope.build_envelope.class-or[string]$scope.device_envelope.requirement-cne[string]$envelope.device_envelope.requirement){throw 'Admission public/private, build, or device ceiling exceeds the prepared envelope.'}
 foreach($profile in @($scope.build_envelope.allowed_profiles)){if(@($envelope.build_envelope.allowed_profiles)-cnotcontains[string]$profile){throw 'Admission build profile exceeds the prepared envelope.'}}
 foreach($kind in @($scope.device_envelope.allowed_kinds)){if(@($envelope.device_envelope.allowed_kinds)-cnotcontains[string]$kind){throw 'Admission device kind exceeds the prepared envelope.'}}
 foreach($owner in @($scope.owner_repositories)){$prepared=@($envelope.owner_repositories|Where-Object{[string]$_.repo_id-ceq[string]$owner.repo_id});if($prepared.Count-ne1){throw 'Admission repository identity exceeds the prepared envelope.'};foreach($root in @($owner.source_roots)){if(@($prepared[0].source_roots)-cnotcontains[string]$root){throw 'Admission source root exceeds the prepared envelope.'}}}
 if([string]$Admission.unit.source_composition.lock_path-cne[string]$p.source_composition_path){throw 'Admission unit does not bind the canonical prepared source lock.'}
 $artifacts=@($intent.artifacts);$receiptArtifact=@($artifacts|Where-Object{[string]$_.path-ceq[string]$p.receipt_path});$sourceArtifact=@($artifacts|Where-Object{[string]$_.path-ceq[string]$p.source_composition_path})
 $sourceRawFileSha256=Get-MorphospaceFileSha256 $sourcePath;$sourceCanonicalJsonSha256=Get-MorphospaceCanonicalJsonSha256 $source;$receiptCanonicalJsonSha256=Get-MorphospaceCanonicalJsonSha256 $receipt
 $receiptBytesBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($admissionPath));$sourceBytesBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sourcePath))
 if([string]$receipt.preparation_id-cne[string]$p.preparation_id-or[string]$source.preparation_id-cne[string]$p.preparation_id-or[string]$receipt.source_composition.path-cne[string]$p.source_composition_path-or[string]$receipt.source_composition.sha256-cne$sourceCanonicalJsonSha256-or[string]$p.source_composition_sha256-cne$sourceRawFileSha256-or[string]$intent.transaction_id-cne$tx-or[string]$completion.transaction_id-cne$tx-or[string]$completion.intent_sha256-cne(Get-MorphospaceFileSha256 $intentPath)-or$receiptArtifact.Count-ne1-or$sourceArtifact.Count-ne1-or[string]$receiptArtifact[0].sha256-cne$receiptCanonicalJsonSha256-or[string]$sourceArtifact[0].sha256-cne$sourceCanonicalJsonSha256-or[string]$receiptArtifact[0].bytes_base64-cne$receiptBytesBase64-or[string]$sourceArtifact[0].bytes_base64-cne$sourceBytesBase64){throw 'Prepared-envelope artifact provenance is not exact.'}
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
Export-ModuleMember -Function Test-MorphospacePreparedDevelopmentEnvelope
