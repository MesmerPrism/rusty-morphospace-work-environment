Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceSourceCompositionIdentity.psm1')

function Assert-RetirementLineageEqual([object]$Before,[object]$After,[string]$Context){
 if((Get-MorphospaceCanonicalJsonSha256 $Before)-cne(Get-MorphospaceCanonicalJsonSha256 $After)){throw "Active retirement supersession lineage $Context differs."}
}
function Copy-RetirementLineageValue([object]$Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String}
function ConvertTo-RetirementLineageSourcePath([string]$Path){
 # Match the Supersede producer's normalizer, including its Ordinal containment.
 $value=$Path.Replace('\','/').Trim()
 if(-not$value-or[IO.Path]::IsPathRooted($value)-or$value-cmatch'(^|/)\.\.(/|$)'-or$value-cmatch'(^|/)\.(/|$)'-or$value.Contains('//',[StringComparison]::Ordinal)){throw 'Active retirement lineage source path is not canonical.'}
 $value
}
function Test-RetirementLineageSourcePath([string]$Path,[object[]]$Roots){
 $value=ConvertTo-RetirementLineageSourcePath $Path
 foreach($root in @($Roots)){$allowed=(ConvertTo-RetirementLineageSourcePath ([string]$root)).TrimEnd('/');if($value.Equals($allowed,[StringComparison]::Ordinal)-or$value.StartsWith($allowed+'/',[StringComparison]::Ordinal)){return $true}}
 return $false
}
function Get-RetirementLineageMap([string]$Workspace,[string]$Path){
 $relative=if([IO.Path]::IsPathRooted($Path)){[IO.Path]::GetRelativePath($Workspace,[IO.Path]::GetFullPath($Path)).Replace('\','/')}else{$Path}
 $relative=ConvertTo-MorphospaceProtocolRelativePath $relative;$absolute=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf;$document=Read-MorphospaceProtocolJson $absolute
 $ownerRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 if(-not(Test-Json -Json ($document|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $ownerRoot 'schemas/repository-map.schema.json'))){throw 'Active retirement lineage retained map schema is invalid.'}
 $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($row in @($document.repositories)){if(-not$ids.Add([string]$row.repo_id)){throw 'Active retirement lineage retained map repeats a repository.'}}
 [pscustomobject]@{binding=[pscustomobject]@{path=$relative;raw_sha256=Get-MorphospaceFileSha256 $absolute};document=$document}
}
function Assert-RetirementLineageSource {
 param([string]$Workspace,[object]$Unit,[object]$Project,[object]$Map,[string]$OriginalPreparationId)
 $path=[string]$Unit.source_composition.lock_path;$absolute=Resolve-MorphospaceWorkspacePath $Workspace $path -RequireLeaf;$source=Read-MorphospaceProtocolJson $absolute;$ownerRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 $schema=switch -CaseSensitive ([string]$source.schema){'rusty.morphospace.workflow.source_composition_lock.v1'{'source-composition-lock.schema.json'}'rusty.morphospace.workflow.development_envelope_source_composition.v1'{'development-envelope-source-composition-v1.schema.json'}'rusty.morphospace.workflow.development_envelope_source_composition.v2'{'development-envelope-source-composition-v2.schema.json'}'rusty.morphospace.workflow.development_envelope_source_composition.v3'{'development-envelope-source-composition-v3.schema.json'}'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'{'active-development-envelope-source-composition-v1.schema.json'}default{throw 'Active retirement lineage source schema is unsupported.'}}
 if(-not(Test-Json -Json ($source|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $ownerRoot "schemas/$schema"))-or[string]$source.project_id-cne[string]$Unit.project_id-or[string]$Project.project_id-cne[string]$Unit.project_id){throw 'Active retirement lineage source schema/project identity differs.'}
 if([string]$source.schema-ceq'rusty.morphospace.workflow.source_composition_lock.v1'){if([string]$source.unit_id-cne[string]$Unit.unit_id-or[string]$source.fingerprint-cne(Get-MorphospaceSourceCompositionFingerprint -ProjectId ([string]$source.project_id) -UnitId ([string]$Unit.unit_id) -Repositories @($source.repositories))){throw 'Active retirement lineage source fingerprint/owner differs.'}}
 elseif([string]$source.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){$identity=Copy-RetirementLineageValue $source;$identity.fingerprint='0'*64;if([string]$source.unit_id-cne[string]$Unit.unit_id-or[string]$source.fingerprint-cne(Get-MorphospaceCanonicalJsonSha256 $identity)){throw 'Active retirement lineage extended source fingerprint/owner differs.'}}
 elseif([string]$source.preparation_id-cne$OriginalPreparationId-or[string]$source.fingerprint-cne(Get-MorphospacePreparationSourceCompositionFingerprint $source)-or[string]$source.lock_id-cne"$OriginalPreparationId-source-$(([string]$source.fingerprint).Substring(0,12))"){throw 'Active retirement lineage prepared source fingerprint/origin differs.'}
 $projectRows=@{};foreach($row in @($Project.repositories)){if($projectRows.ContainsKey([string]$row.repo_id)){throw 'Active retirement lineage project repeats a repository.'};$projectRows[[string]$row.repo_id]=$row}
 $mapRows=@{};foreach($row in @($Map.repositories)){if($mapRows.ContainsKey([string]$row.repo_id)){throw 'Active retirement lineage map repeats a repository.'};$mapRows[[string]$row.repo_id]=$row}
 # Project roles describe architecture (application/adapter/etc.); source/map
 # roles describe materialization (source/planning). Only the latter share a
 # vocabulary. Historical project membership and path scopes remain exact.
 $sourceRows=@{};foreach($row in @($source.repositories)){$id=[string]$row.repo_id;if($sourceRows.ContainsKey($id)-or-not$projectRows.ContainsKey($id)-or-not$mapRows.ContainsKey($id)-or[string]$row.role-cne[string]$mapRows[$id].role){throw 'Active retirement lineage source/map/project repository or role intersection differs.'};$sourceRows[$id]=$row}
 $assessmentRows=@{};foreach($row in @($Unit.agent_scope_assessment.owner_repositories)){$id=[string]$row.repo_id;if($assessmentRows.ContainsKey($id)){throw 'Active retirement lineage assessment repeats a repository.'};$assessmentRows[$id]=$row}
 $writable=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($row in @($Unit.allowed_repositories)){$id=[string]$row.repo_id;if(-not$writable.Add($id)-or-not$sourceRows.ContainsKey($id)-or-not$assessmentRows.ContainsKey($id)){throw 'Active retirement lineage source omits or repeats a writable owner.'};foreach($scopePath in @($row.allowed_paths)){if(-not(Test-RetirementLineageSourcePath ([string]$scopePath) @($projectRows[$id].allowed_paths))-or-not(Test-RetirementLineageSourcePath ([string]$scopePath) @($assessmentRows[$id].source_roots))){throw 'Active retirement lineage write scope exceeds its historical project/assessment intersection.'}}}
 $readOnly=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($row in @(if($Unit.PSObject.Properties.Name-ccontains'read_only_dependencies'){$Unit.read_only_dependencies})){$id=[string]$row.repo_id;if(-not$readOnly.Add($id)-or$writable.Contains($id)-or-not$sourceRows.ContainsKey($id)-or-not$assessmentRows.ContainsKey($id)){throw 'Active retirement lineage source omits, repeats, or overlaps a declared read-only dependency.'};foreach($scopePath in @($row.paths)){if(-not(Test-RetirementLineageSourcePath ([string]$scopePath) @($projectRows[$id].allowed_paths))-or-not(Test-RetirementLineageSourcePath ([string]$scopePath) @($assessmentRows[$id].source_roots))){throw 'Active retirement lineage read-only scope exceeds its historical project/assessment intersection.'}}}
 # Fresh Supersede inputs were not transaction-owned source artifacts. Their
 # current schema/fingerprint/closure is checked here; this is not a claim that
 # their original raw bytes were bound by the SHA-only Supersede map contract.
 $source
}
function Assert-RetirementLineageFreezeSource {
 param([string]$Workspace,[object]$Intent,[object]$Unit)
 $freezes=@(foreach($schema in @('rusty.morphospace.workflow.candidate_freeze.v1','rusty.morphospace.workflow.candidate_freeze.v2')){$artifact=Get-RetirementLineageArtifact $Intent $schema;if($null-ne$artifact){$artifact}})
 if($freezes.Count-eq0){return};if($freezes.Count-ne1){throw 'Active retirement lineage Freeze source receipt is ambiguous.'}
 # The source at this historical Freeze can differ from the eventual endpoint.
 # Unlike a fresh Supersede input, Freeze actually captured its raw-file hash.
 $freeze=$freezes[0].document;$sourcePath=[string]$Unit.source_composition.lock_path
 if([string]$freeze.expected.source_composition_path-cne$sourcePath-or[string]$freeze.source_composition.path-cne$sourcePath-or[string]$freeze.source_composition.sha256-cne[string]$freeze.expected.source_composition_sha256){throw 'Active retirement lineage Freeze source path/hash capture is detached.'}
 $actual=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $sourcePath -RequireLeaf)
 if($actual-cne[string]$freeze.expected.source_composition_sha256){throw 'Active retirement lineage Freeze source raw bytes drifted after capture.'}
}
function Assert-RetirementLineageEndpointAuthority {
 param([object]$Endpoint,[object]$Project,[object]$FeatureLock)
 if(@($Endpoint.additional_projections).Count-ne2){throw 'Active retirement lineage retirement must fence exactly project and feature authority.'}
 $request=Get-RetirementLineageArtifact $Endpoint 'rusty.morphospace.workflow.active_unit_retirement.v2'
 if($null-eq$request){throw 'Active retirement lineage retirement lacks its exact v2 request artifact.'}
 foreach($pair in @(@('project','project.spec.json',$Project),@('feature_lock','feature.lock.json',$FeatureLock))){$name=[string]$pair[0];$rows=@($Endpoint.additional_projections|Where-Object{[string]$_.path-ceq[string]$pair[1]});$canonical=Get-MorphospaceCanonicalJsonSha256 $pair[2];$raw=Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $pair[2]);if($rows.Count-ne1-or[string]$rows[0].pre_sha256-cne$canonical-or[string]$rows[0].target_sha256-cne$canonical-or[string]$rows[0].pre_raw_sha256-cne$raw-or[string]$request.document.expected."${name}_canonical_sha256"-cne$canonical-or[string]$request.document.expected."${name}_raw_sha256"-cne$raw){throw 'Active retirement lineage retirement authority pins do not join its historical preimage.'};Assert-RetirementLineageEqual $pair[2] $rows[0].document 'retirement unchanged authority document'}
}
function Get-RetirementLineageBinding([string]$Workspace,[string]$Path){
 $path=ConvertTo-MorphospaceProtocolRelativePath $Path;$absolute=Resolve-MorphospaceWorkspacePath $Workspace $path -RequireLeaf
 [pscustomobject]@{path=$path;raw_sha256=Get-MorphospaceFileSha256 $absolute;canonical_sha256=Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $absolute)}
}
function Get-RetirementLineageArtifact([object]$Intent,[string]$Schema){
 $values=@(foreach($artifact in @($Intent.artifacts)){$bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64);if((Get-MorphospaceSha256Bytes $bytes)-cne[string]$artifact.sha256){throw 'Active retirement lineage artifact payload differs.'};$document=ConvertFrom-MorphospaceProtocolJsonBytes $bytes;if([string]$document.schema-ceq$Schema){[pscustomobject]@{binding=$artifact;document=$document}}})
 if($values.Count-gt1){throw 'Active retirement lineage artifact schema is ambiguous.'};if($values.Count-eq1){return $values[0]};return $null
}
function Set-RetirementLineageAutomaticRepositoryProjection {
 param([object]$Expected,[object]$Target,[object]$Project,[object]$FeatureLock)
 # WorkUnitAutomation refreshes observations after deriving its action. These
 # historical observations can differ after a planning commit; they cannot
 # change selectors, checkpoints, blockers, or product/source authority.
 $ids=@($Project.repositories|ForEach-Object{[string]$_.repo_id});$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($id in @($Target.dirty_repositories)){if($ids-cnotcontains[string]$id){throw 'Active retirement lineage observes an undeclared dirty repository.'}}
 $Expected.dirty_repositories=@($Target.dirty_repositories)
 if([string]$Expected.schema-ceq'rusty.morphospace.workflow.workspace_state.v2'){
  foreach($head in @($Target.repository_heads)){if($ids-cnotcontains[string]$head.repo_id-or-not$seen.Add([string]$head.repo_id)){throw 'Active retirement lineage repository observations repeat or add an owner.'}}
  $Expected.repository_heads=@($Target.repository_heads)
  if([string]$FeatureLock.schema-ceq'rusty.morphospace.workflow.feature_lock.v2'){$registry=[pscustomobject]@{lock_revision=[int]$FeatureLock.revision;lock_fingerprint=[string]$FeatureLock.lock_fingerprint;modules=@($Project.modules|Where-Object{$_.selected-eq$true}|Sort-Object module_id|ForEach-Object{[pscustomobject]@{module_id=[string]$_.module_id;owner_repo=[string]$_.source_repo;maturity=[string]$_.maturity;contract=[string]$_.contract;contract_revision=[string]$_.contract_revision}})};Assert-RetirementLineageEqual $registry $Target.module_registry 'derived module registry';$Expected.module_registry=$registry}
 }
}
function Get-RetirementLineageTransition([string]$Workspace,[object]$Event){
 $owner=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1') -PassThru
 $proof=&$owner {param($root,$id) Get-ActiveRetirementPlanningTransition -Workspace $root -TransactionId $id -HistoricalProjection} $Workspace "$($Event.event_id)-transition"
 Assert-RetirementLineageEqual $Event $proof.intent.event 'event producer'
 if([string]$proof.intent.state.path-cne'workspace.state.json'-or[string]$proof.intent.events.path-cne'iteration-events.jsonl'){throw 'Active retirement lineage uses unexpected projection paths.'}
 $proof
}
function Assert-RetirementLineageSupersession {
 param([string]$Workspace,[object]$Proof,[object]$Before,[object]$Previous,[object]$Map,[object]$Project)
 $intent=$Proof.intent;$event=$intent.event;$old=[string]$Before.unit_id;$replacement=[string]$intent.target.unit.document.unit_id
 if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v2'-or[string]$event.event_id-cne(Get-MorphospaceSupersessionEventId $old $replacement)-or[string]$event.unit_id-cne$old-or[string]$event.event_type-cne'state-transition'-or@($intent.artifacts).Count-ne1-or@($event.receipts).Count-ne1){throw 'Active retirement lineage Supersede producer is not the exact owner transition.'}
 Assert-RetirementLineageEqual $Before $intent.supersession.old_unit.document 'preserved old owner'
 if([string]$intent.supersession.old_unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $Before)-or[string]$intent.supersession.old_unit.path-cne"iteration-units/$old.json"-or[string]$intent.supersession.old_unit_id-cne$old-or[string]$intent.supersession.new_unit_id-cne$replacement-or[string]$intent.supersession.target_unit_path-cne"iteration-units/$replacement.json"-or[string]$intent.unit.path-cne"iteration-units/$replacement.json"-or[string]$intent.supersession.pre_state.path-cne'workspace.state.json'){throw 'Active retirement lineage Supersede endpoint binding differs.'}
 Assert-RetirementLineageEqual $Previous.target.state.document $intent.supersession.pre_state.document 'Supersede prestate'
 $state=Copy-RetirementLineageValue $Previous.target.state.document;$state.current_unit=$replacement;$state.next_ready_unit=$null;$state.last_event_id=[string]$event.event_id
 Assert-RetirementLineageEqual $state $intent.target.state.document 'Supersede state projection'
 $oldBinding=Get-RetirementLineageBinding $Workspace "iteration-units/$old.json"
 if([string]$oldBinding.canonical_sha256-cne[string]$intent.supersession.old_unit.sha256){throw 'Active retirement lineage old owner was rewritten.'}
 $artifact=$intent.artifacts[0];$receiptPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$artifact.path) -RequireLeaf;$receipt=Read-MorphospaceProtocolJson $receiptPath
 $ownerRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 if(-not(Test-Json -Json ($receipt|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $ownerRoot 'schemas/work-unit-automation-receipt-v2.schema.json'))-or[string]$receipt.action-cne'SupersedeActive'-or$receipt.executed-ne$true-or[string]$receipt.transition-cne'active-superseded-by-proposed-to-active'-or[string]$event.receipts[0]-cne[string]$artifact.path-or[string]$receipt.event_id-cne[string]$event.event_id-or[string]$receipt.unit_id-cne$replacement-or[string]$receipt.current_unit_before-cne$old-or[string]$receipt.current_unit_after-cne$replacement-or[string]$receipt.status_before-cne'proposed'-or[string]$receipt.status_after-cne'active'-or[string]$receipt.timestamp-cne[string]$event.timestamp-or[string]$receipt.project_id-cne[string]$event.project_id-or$receipt.preservation.git_mutation_performed-ne$false-or$receipt.preservation.device_mutation_performed-ne$false-or$receipt.preservation.remote_mutation_performed-ne$false){throw 'Active retirement lineage Supersede receipt differs.'}
 $requestPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$receipt.audit_receipt.path) -RequireLeaf;$request=Read-MorphospaceProtocolJson $requestPath;$requestSha=Get-MorphospaceFileSha256 $requestPath
 if($requestSha-cne[string]$receipt.audit_receipt.sha256-or-not(Test-Json -Json ($request|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $ownerRoot 'schemas/active-unit-supersession-v1.schema.json'))){throw 'Active retirement lineage Supersede reviewed request differs.'}
 $target=$intent.target.unit.document;$preimage=Copy-RetirementLineageValue $target;$preimage.status='proposed'
 if(-not(Test-Json -Json ($target|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $ownerRoot 'schemas/iteration-unit.schema.json'))){throw 'Active retirement lineage Supersede replacement unit schema is invalid.'}
 if([string]$Before.status-cne'active'-or[string]$target.status-cne'active'-or[string]$Previous.target.state.document.current_unit-cne$old-or[string]$request.supersession_id-cne[string]$event.event_id-or[string]$request.project_id-cne[string]$event.project_id-or[string]$request.old_unit.unit_id-cne$old-or[string]$request.old_unit.path-cne[string]$oldBinding.path-or[string]$request.old_unit.raw_sha256-cne[string]$oldBinding.raw_sha256-or[string]$request.old_unit.canonical_sha256-cne[string]$oldBinding.canonical_sha256-or[string]$request.old_unit.status-cne'active'-or[string]$request.replacement_unit.unit_id-cne$replacement-or[string]$request.replacement_unit.path-cne[string]$intent.unit.path-or[string]$request.replacement_unit.status-cne'proposed'-or[string]$request.replacement_unit.canonical_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $preimage)-or[string]$intent.pre.unit.sha256-cne[string]$request.replacement_unit.canonical_sha256-or[string]$request.expected.state_canonical_sha256-cne[string]$Previous.target.state.sha256-or[string]$request.expected.state_raw_sha256-cne(Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $Previous.target.state.document))-or[string]$request.expected.events_sha256-cne[string]$intent.expected.events_sha256-or[long]$request.expected.events_length-ne[long]$intent.expected.events_length-or[string]$request.expected.event_tail_id-cne[string]$Previous.event.event_id-or[string]$request.expected.project_canonical_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $Project)){throw 'Active retirement lineage Supersede request does not bind the real predecessor and proposed successor.'}
 # Supersede's own contract permits narrower write paths and a new proposed
 # unit. It does not require an invented admission or Claim for that unit.
 $oldScopes=@{};foreach($row in @($Before.allowed_repositories)){$id=[string]$row.repo_id;if($oldScopes.ContainsKey($id)){throw 'Active retirement lineage Supersede old owner repeats a repository.'};$oldScopes[$id]=@($row.allowed_paths)}
 $newIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($row in @($target.allowed_repositories)){$id=[string]$row.repo_id;if(-not$newIds.Add($id)){throw 'Active retirement lineage Supersede replacement repeats a repository.'};if(-not$oldScopes.ContainsKey($id)){throw 'Active retirement lineage Supersede adds an owner repository.'};foreach($path in @($row.allowed_paths)){if(-not(Test-RetirementLineageSourcePath ([string]$path) @($oldScopes[$id]))){throw 'Active retirement lineage Supersede widens source ownership.'}}}
 [pscustomobject]@{old_unit_id=$old;replacement_unit_id=$replacement;event_id=[string]$event.event_id;transaction_id=[string]$intent.transaction_id;intent_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($intent.transaction_id).intent.json" -RequireLeaf);completion_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($intent.transaction_id).completion.json" -RequireLeaf);request=[pscustomobject]@{path=[string]$receipt.audit_receipt.path;sha256=$requestSha};receipt=[pscustomobject]@{path=[string]$artifact.path;sha256=[string]$artifact.sha256};request_document=$request}
}

function Get-MorphospaceActiveRetirementSupersessionLineage {
 [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$UnitId,[Parameter(Mandatory)][object[]]$Events,[Parameter(Mandatory)][object]$CurrentUnit,[object]$RecoveryIntent=$null,[object]$RetirementIntent=$null,[string]$RepositoryMapPath='',[string[]]$HistoricalRepositoryMapPaths=@())
 $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$endpoint=if($RetirementIntent){$RetirementIntent}elseif($RecoveryIntent){$RecoveryIntent}else{$null}
 $owner=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1') -PassThru
 $observation=&$owner {param($root) Get-ActiveRetirementEvents $root} $workspace
 # The caller's finite prefix is authenticated against the real retained ledger.
 $events=@($Events);if($events.Count-eq0){throw 'Active retirement lineage event prefix is empty.'}
 for($i=0;$i-lt$events.Count;$i++){if($i-ge@($observation.events).Count){throw 'Active retirement lineage prefix exceeds retained history.'};Assert-RetirementLineageEqual $events[$i] $observation.events[$i] 'retained event prefix'}
 if($endpoint){$tail=@($events|Where-Object{[string]$_.event_id-ceq[string]$endpoint.expected.event_tail_id});if($tail.Count-ne1){throw 'Active retirement lineage retirement predecessor is ambiguous.'};$events=@($events|Where-Object{[int]$_.sequence-le[int]$tail[0].sequence});if([long]$endpoint.expected.events_length-gt[long]$observation.length){throw 'Active retirement lineage retirement prefix exceeds retained bytes.'};$bytes=[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf));$prefix=[byte[]]::new([long]$endpoint.expected.events_length);[Array]::Copy($bytes,$prefix,$prefix.Length);if((Get-MorphospaceSha256Bytes $prefix)-cne[string]$endpoint.expected.events_sha256){throw 'Active retirement lineage retirement prefix bytes differ.'}}
 elseif($events.Count-ne@($observation.events).Count){throw 'Active retirement lineage current read requires the actual complete event prefix.'}
 $incoming=@{};$outgoing=@{}
 foreach($event in $events){if(-not([string]$event.event_id).Contains('-superseded-by-',[StringComparison]::Ordinal)){continue};$proof=Get-RetirementLineageTransition $workspace $event;$intent=$proof.intent;if($intent.PSObject.Properties.Name-cnotcontains'supersession'){throw 'Active retirement lineage supersession lacks endpoints.'};$old=[string]$intent.supersession.old_unit_id;$new=[string]$intent.supersession.new_unit_id;if($incoming.ContainsKey($new)-or$outgoing.ContainsKey($old)){throw 'Active retirement lineage supersession branches or repeats an owner.'};$incoming[$new]=$proof;$outgoing[$old]=$proof}
 if(-not$incoming.ContainsKey($UnitId)){throw 'Active retirement lineage endpoint was not admitted by SupersedeActive.'}
 $cursor=$UnitId;$visited=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 while($incoming.ContainsKey($cursor)){if(-not$visited.Add($cursor)){throw 'Active retirement lineage is cyclic.'};$cursor=[string]$incoming[$cursor].intent.supersession.old_unit_id}
 $rootId=$cursor;$admissions=@(Get-ChildItem -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace 'receipts') -File -Filter '*.json'|ForEach-Object{$value=Read-MorphospaceProtocolJson $_.FullName;if($value.PSObject.Properties.Name-ccontains'schema'-and[string]$value.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$value.unit_id-ceq$rootId){[pscustomobject]@{path=[IO.Path]::GetRelativePath($workspace,$_.FullName).Replace('\','/');document=$value}}})
 if($admissions.Count-ne1){throw 'Active retirement lineage ordinary admission root is missing or ambiguous.'}
 $admission=$admissions[0].document;$originModule=Import-Module (Join-Path $PSScriptRoot '../DevelopmentEnvelopeProvenance.psm1') -PassThru
 $origin=&$originModule {param($root,$value,$events) Test-MorphospaceHistoricalDevelopmentAdmissionOrigin -WorkspaceRoot $root -Admission $value -Events $events} $workspace $admission $events
 $previous=$origin.admission_proof.intent;$unit=$previous.target.unit.document;$project=$origin.project;$feature=$origin.feature_lock;$map=$origin.repository_map;$source=$origin.source_lock;$sourcePath=[string]$admission.preparation.source_composition_path
 $maps=@{};$requiredMaps=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$explicitMaps=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 $initialMap=Get-RetirementLineageMap $workspace ([string]$map.path)
 if([string]$initialMap.binding.raw_sha256-cne[string]$map.raw_sha256){throw 'Active retirement lineage root map bytes differ from its admission.'}
 $maps[[string]$map.raw_sha256]=$initialMap;[void]$requiredMaps.Add([string]$map.raw_sha256)
 if($RepositoryMapPath){$currentMap=Get-RetirementLineageMap $workspace $RepositoryMapPath;$maps[[string]$currentMap.binding.raw_sha256]=$currentMap}
 foreach($historicalPath in @($HistoricalRepositoryMapPaths)){$retainedMap=Get-RetirementLineageMap $workspace ([string]$historicalPath);$sha=[string]$retainedMap.binding.raw_sha256;if(-not$explicitMaps.Add($sha)){throw 'Active retirement lineage historical map references repeat a raw identity.'};$maps[$sha]=$retainedMap}
 $source=Assert-RetirementLineageSource $workspace $unit $project $initialMap.document ([string]$admission.preparation.preparation_id)
 $records=@([pscustomobject]@{kind='preparation';intent=$origin.intent;completion=$origin.completion;event=$origin.intent.event},[pscustomobject]@{kind='admission';intent=$previous;completion=$origin.admission_proof.completion;event=$previous.event});$edges=@();$validationAttempts=@();$claim=$null;$ready=$false;$effectiveMapSha=[string]$map.raw_sha256
 foreach($event in @($events|Where-Object{[int]$_.sequence-gt[int]$previous.event.sequence})){
  $proof=Get-RetirementLineageTransition $workspace $event;$intent=$proof.intent
  if([int]$event.sequence-ne([int]$previous.event.sequence+1)-or[string]$intent.pre.state.sha256-cne[string]$previous.target.state.sha256-or[string]$intent.expected.event_tail_id-cne[string]$previous.event.event_id-or[string]$event.project_id-cne[string]$admission.project_id){throw 'Active retirement lineage state/event chain is detached.'}
  $kind='retained'
  if($intent.PSObject.Properties.Name-ccontains'supersession'){
   if($null-eq$claim){throw 'Active retirement lineage Supersede precedes the real root Claim.'}
   $edge=Assert-RetirementLineageSupersession $workspace $proof $unit $previous $map $project
   $request=$edge.request_document;$edge.PSObject.Properties.Remove('request_document');$edges+=,$edge;$kind='supersession'
   # The actual Supersede request authenticates the effective map observed by
   # its producer. Resolve that exact immutable map, never today's root map.
   $effectiveMapSha=[string]$request.expected.repository_map_sha256
  }else{
   if([string]$event.unit_id-cne[string]$unit.unit_id-or[string]$intent.pre.unit.sha256-cne[string]$previous.target.unit.sha256){throw 'Active retirement lineage interleaves another unit.'}
   if($null-eq$claim){
    $slug=if($ready){'claimed'}else{'ready'};$status=if($ready){'active'}else{'ready'};$expected=Copy-RetirementLineageValue $unit;$expected.status=$status;$state=Copy-RetirementLineageValue $previous.target.state.document;$state.last_event_id=[string]$event.event_id
    if($ready){$state.current_unit=$rootId;$state.next_ready_unit=$null}else{$state.next_ready_unit=$rootId}
    if([string]$event.event_id-cnotmatch('^'+[regex]::Escape($rootId)+'-'+$slug+'-[0-9]{4,}$')-or[string]$event.event_type-cne'state-transition'-or@($event.receipts).Count-ne0-or@($intent.artifacts).Count-ne0){throw 'Active retirement lineage ordinary Ready/Claim prefix is invalid.'}
    Set-RetirementLineageAutomaticRepositoryProjection $state $intent.target.state.document $project $feature
    Assert-RetirementLineageEqual $expected $intent.target.unit.document 'ordinary Ready/Claim unit';Assert-RetirementLineageEqual $state $intent.target.state.document 'ordinary Ready/Claim state';$kind=$slug
    if($ready){$claim=[pscustomobject]@{event_id=[string]$event.event_id;transaction_id=[string]$intent.transaction_id;intent_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$($intent.transaction_id).intent.json" -RequireLeaf);completion_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$($intent.transaction_id).completion.json" -RequireLeaf)}}else{$ready=$true}
   }else{
    $extension=Get-RetirementLineageArtifact $intent 'rusty.morphospace.workflow.active_development_envelope_extension.v1';$upgrade=Get-RetirementLineageArtifact $intent 'rusty.morphospace.workflow.tooling_context_upgrade.v1';$amendment=Get-RetirementLineageArtifact $intent 'rusty.morphospace.workflow.active_write_scope_amendment.v1'
    if($extension){$extensionModule=Import-Module (Join-Path $PSScriptRoot '../ActiveDevelopmentEnvelopeExtension.psm1') -PassThru;$null=&$extensionModule {param($root,$event,$proof) Assert-ActiveEnvelopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $event -Transition $proof} $workspace $event $proof;$project=$extension.document.target.project;$feature=$extension.document.target.feature_lock;$kind='extension'}
    elseif($upgrade){$toolingModule=Import-Module (Join-Path $PSScriptRoot '../ToolingContextUpgrade.psm1') -PassThru;$null=&$toolingModule {param($root,$event,$proof) Assert-ToolingContextHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $event -Transition $proof} $workspace $event $proof;$kind='tooling-upgrade'}
    elseif($amendment){$amendmentModule=Import-Module (Join-Path $PSScriptRoot '../ActiveWriteScopeAmendment.psm1') -PassThru;Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1');Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1');$null=&$amendmentModule {param($root,$event,$proof) Assert-ActiveWriteScopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $event -Transition $proof} $workspace $event $proof;$kind='amendment'}
    elseif([string]$event.event_id-cmatch('^'+[regex]::Escape([string]$unit.unit_id)+'-validation-(fail|partial|blocked)-return-[0-9]{4,}$')){
     $result=$Matches[1];$state=Copy-RetirementLineageValue $previous.target.state.document;$expectedUnit=Copy-RetirementLineageValue $unit
     if([string]$unit.status-cne'validating'-or[string]$state.current_unit-cne[string]$unit.unit_id-or[string]$event.event_type-cne'validation'-or@($event.receipts).Count-ne1-or@($intent.artifacts).Count-ne0-or[string]$event.summary-cne'Retained a non-passing validation attempt and returned the same feature unit to active for an in-scope correction.'){throw 'Active retirement lineage ReturnToActive is not the exact owner action.'}
     $workMode=if($unit.PSObject.Properties.Name-ccontains'work_mode'){[string]$unit.work_mode}else{'feature'}
     if($workMode-cne'feature'-or([string]$unit.project_id-ceq'morphospace-platform-iteration'-and[string]$unit.unit_id-ceq'wf-005')-or($unit.PSObject.Properties.Name-ccontains'tags'-and@($unit.tags|Where-Object{[string]$_-eq'receipt-security'}).Count-ne0)){throw 'Active retirement lineage ReturnToActive is not the supported feature/manual-receipt producer.'}
     $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$event.receipts[0]);$receiptPath=Resolve-MorphospaceWorkspacePath $workspace $relative -RequireLeaf
     $receiptBytes=[IO.File]::ReadAllBytes($receiptPath);$receipt=ConvertFrom-MorphospaceProtocolJsonBytes $receiptBytes
     # The original Return producer bound path/result/tier, not Git introduction
     # or raw receipt bytes. V2 explicitly retains the reviewed current bytes.
     $null=&$owner {param($receipt) Assert-ActiveRetirementSchema $receipt 'validation-receipt.schema.json'} $receipt
     if([string]$receipt.result-cne$result-or[string]$receipt.unit_id-cne[string]$unit.unit_id-or[string]$receipt.project_id-cne[string]$event.project_id){throw 'Active retirement lineage ReturnToActive receipt identity differs.'}
     $artifactIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
     foreach($artifact in @($receipt.artifacts)){if(-not$artifactIds.Add([string]$artifact.artifact_id)){throw 'Active retirement lineage nonpassing evidence repeats an artifact ID.'};$path=if([IO.Path]::IsPathRooted([string]$artifact.path)){[string]$artifact.path}else{Join-Path (Split-Path $receiptPath -Parent) ([string]$artifact.path)};if((Get-MorphospaceFileSha256 $path)-cne([string]$artifact.sha256).ToLowerInvariant()){throw 'Active retirement lineage nonpassing evidence drifted.'}}
     $expectedCriteria=@($unit.acceptance|ForEach-Object{[string]$_.acceptance_id}|Sort-Object);$actualCriteria=@($receipt.criteria|ForEach-Object{[string]$_.acceptance_id}|Sort-Object)
     if(($expectedCriteria-join'|')-cne($actualCriteria-join'|')){throw 'Active retirement lineage nonpassing receipt acceptance coverage differs.'}
     foreach($criterion in @($receipt.criteria)){$definition=@($unit.acceptance|Where-Object{[string]$_.acceptance_id-eq[string]$criterion.acceptance_id});if($definition.Count-ne1-or[string]$definition[0].command-ne[string]$criterion.command){throw 'Active retirement lineage nonpassing receipt acceptance command differs.'}}
     foreach($evidence in @($receipt.criteria)+@($receipt.gates)+@(if($null-ne$receipt.device_validation){$receipt.device_validation})){foreach($reference in @($evidence.evidence_refs)){if(-not$artifactIds.Contains([string]$reference)){throw 'Active retirement lineage nonpassing receipt references unknown evidence.'}}}
     $state.validation_checkpoint=[pscustomobject]@{tier=[string]$receipt.tier;receipt=$relative;result=$result};$state.last_event_id=[string]$event.event_id;$expectedUnit.status='active'
     Set-RetirementLineageAutomaticRepositoryProjection $state $intent.target.state.document $project $feature
     Assert-RetirementLineageEqual $state $intent.target.state.document 'ReturnToActive state';Assert-RetirementLineageEqual $expectedUnit $intent.target.unit.document 'ReturnToActive unit';$kind='return-to-active'
     $validationAttempts+=,[pscustomobject]@{event_id=[string]$event.event_id;path=$relative;raw_sha256=Get-MorphospaceSha256Bytes $receiptBytes;canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $receipt}
    }else{$null=&$owner {param($root,$event,$proof,$project,$feature) Assert-ActiveRetirementRetainedLifecycle $root $event $proof -SupersessionLineage -SupersessionProject $project -SupersessionFeatureLock $feature} $workspace $event $proof $project $feature}
   }
  }
  Assert-RetirementLineageFreezeSource $workspace $intent $intent.target.unit.document
  $unit=$intent.target.unit.document;$previous=$intent;$records+=,[pscustomobject]@{kind=$kind;event=$event;intent=$intent;completion=$proof.completion}
  $sourcePath=[string]$unit.source_composition.lock_path;$source=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $sourcePath -RequireLeaf)
  if($kind-ceq'extension'){$effectiveMapSha=[string]$source.repository_map.raw_sha256;$map=[pscustomobject]@{path=[string]$source.repository_map.path;raw_sha256=$effectiveMapSha};$extensionMap=Get-RetirementLineageMap $workspace ([string]$map.path);if([string]$extensionMap.binding.raw_sha256-cne$effectiveMapSha){throw 'Active retirement lineage extension map bytes differ.'};if(-not$explicitMaps.Contains($effectiveMapSha)){$maps[$effectiveMapSha]=$extensionMap}}
  [void]$requiredMaps.Add($effectiveMapSha)
  if(-not$maps.ContainsKey($effectiveMapSha)){throw "Active retirement lineage requires an explicit retained map reference for producer-bound SHA-256 $effectiveMapSha."}
  $source=Assert-RetirementLineageSource $workspace $unit $project $maps[$effectiveMapSha].document ([string]$admission.preparation.preparation_id)
 }
 if($edges.Count-eq0-or$null-eq$claim-or[string]$unit.unit_id-cne$UnitId-or[string]$unit.status-cne'active'-or[string]$previous.target.state.document.current_unit-cne$UnitId){throw 'Active retirement lineage does not end at the exact active Supersede successor.'}
 Assert-RetirementLineageEqual $CurrentUnit $unit 'retained endpoint unit'
 if($endpoint){if([string]$endpoint.pre.state.sha256-cne[string]$previous.target.state.sha256-or[string]$endpoint.pre.unit.sha256-cne[string]$previous.target.unit.sha256){throw 'Active retirement lineage retirement preimage differs.'};Assert-RetirementLineageEndpointAuthority $endpoint $project $feature}else{Assert-RetirementLineageEqual (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)) $previous.target.state.document 'current state';Assert-RetirementLineageEqual (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf)) $project 'current project';Assert-RetirementLineageEqual (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf)) $feature 'current feature lock'}
 if($RepositoryMapPath){$mapRelative=if([IO.Path]::IsPathRooted($RepositoryMapPath)){[IO.Path]::GetRelativePath($workspace,[IO.Path]::GetFullPath($RepositoryMapPath)).Replace('\','/')}else{$RepositoryMapPath};$map=[pscustomobject]@{path=ConvertTo-MorphospaceProtocolRelativePath $mapRelative;raw_sha256=$effectiveMapSha}}
 elseif([string]$map.raw_sha256-cne$effectiveMapSha){throw 'Active retirement lineage requires the exact effective repository-map path; Supersede binds its hash, not a guessed path.'}
 foreach($sha in $explicitMaps){if(-not$requiredMaps.Contains($sha)){throw 'Active retirement lineage historical map reference is not bound by an actual producer.'}}
 $mapBindings=@($requiredMaps|Sort-Object -CaseSensitive|ForEach-Object{$maps[[string]$_].binding})
 $mapPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$map.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $mapPath)-cne[string]$map.raw_sha256){throw 'Active retirement lineage effective map bytes drifted.'}
 $ownerRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $mapPath) -SchemaFile (Join-Path $ownerRoot 'schemas/repository-map.schema.json'))){throw 'Active retirement lineage effective repository map schema is invalid.'}
 $sourceBinding=Get-RetirementLineageBinding $workspace $sourcePath
 foreach($binding in $validationAttempts){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace ([string]$binding.path) -RequireLeaf))-cne[string]$binding.raw_sha256){throw 'Active retirement lineage retained validation attempt changed during authentication.'}}
 [pscustomobject]@{ownership=[pscustomobject]@{kind='supersession';root_unit_id=$rootId;root_admission=(Get-RetirementLineageBinding $workspace ([string]$admissions[0].path));root_claim=$claim;agent_scope_assessment_sha256=Get-MorphospaceCanonicalJsonSha256 $unit.agent_scope_assessment;repository_map=$map;repository_maps=@($mapBindings);validation_attempts=@($validationAttempts);supersessions=@($edges)};repository_map=$map;root_admission=$admission;source_composition=[pscustomobject]@{binding=$sourceBinding;document=$source};planning_projection=@($records);unit=$unit;state=$previous.target.state.document;project=$project;feature_lock=$feature;events=$events}
}

function Test-MorphospaceActiveRetirementSupersessionPlanningProjection {
 [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Lineage,[Parameter(Mandatory)][object]$RepositoryEntry,[string[]]$StatusPorcelain=@(),[object]$RecoveryIntent=$null,[string]$LockedCommit='',[string]$ObservedHead='',[Parameter(Mandatory)][object]$Request)
 if([string]$RepositoryEntry.role-cne'planning'){return $false}
 $workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');$repository=[IO.Path]::GetFullPath([string]$RepositoryEntry.path).TrimEnd('\','/');$comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
 if(-not$workspace.StartsWith($repository+[IO.Path]::DirectorySeparatorChar,$comparison)){return $false}
 $workspacePrefix=[IO.Path]::GetRelativePath($repository,$workspace).Replace('\','/').TrimEnd('/')+'/'
 Assert-RetirementLineageEqual $Request.ownership $Lineage.ownership 'planning ownership';Assert-RetirementLineageEqual $Request.source_composition $Lineage.source_composition.binding 'planning source'
 if($LockedCommit-and$ObservedHead-cnotmatch'^[0-9a-f]{40}$'){throw 'Supersession retirement committed planning projection requires an exact linear descendant.'}
 $expected=@{};$historicalRecovery=@{};$retainedInputs=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$recoveryOwned=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 if($RecoveryIntent){foreach($relative in @([string]$RecoveryIntent.state.path,[string]$RecoveryIntent.events.path,"receipts/transactions/$($RecoveryIntent.transaction_id).intent.json","receipts/transactions/$($RecoveryIntent.transaction_id).completion.json")+@($RecoveryIntent.artifacts|ForEach-Object{[string]$_.path})){[void]$recoveryOwned.Add($relative)};for($i=0;$i-lt@($RecoveryIntent.artifacts).Count;$i++){[void]$recoveryOwned.Add("receipts/transactions/$($RecoveryIntent.transaction_id).artifact-$i.pending")}}
 function Set-LineagePlanningProjection([string]$Relative,[string]$Sha){$relative=ConvertTo-MorphospaceProtocolRelativePath $Relative;if(-not$recoveryOwned.Contains($relative)){$expected[$workspacePrefix+$relative]=$Sha}elseif($relative-ceq[string]$RecoveryIntent.state.path-or$relative-ceq[string]$RecoveryIntent.events.path){$historicalRecovery[$workspacePrefix+$relative]=$Sha}}
 $owner=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1') -PassThru
 foreach($record in @($Lineage.planning_projection)){
  $intent=$record.intent;$id=[string]$intent.transaction_id;$intentRelative="receipts/transactions/$id.intent.json";$completionRelative="receipts/transactions/$id.completion.json"
  foreach($pair in @(@($intentRelative,$intent),@($completionRelative,$record.completion))){$path=Resolve-MorphospaceWorkspacePath $workspace ([string]$pair[0]) -RequireLeaf;$sha=Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $pair[1]);if((Get-MorphospaceFileSha256 $path)-cne$sha){throw 'Supersession retirement planning transaction bytes are noncanonical or changed.'};Set-LineagePlanningProjection ([string]$pair[0]) $sha}
  if(@(Get-ChildItem -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace 'receipts/transactions') -File -Filter "$id.artifact-*.pending").Count-ne0){throw 'Supersession retirement planning contains an orphan committed pending artifact.'}
  if([string]$record.kind-ceq'preparation'){foreach($name in @('project','state','feature_lock')){$projection=$intent.target.$name;Set-LineagePlanningProjection ([string]$projection.path) (Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $projection.document))}}
  else{Set-LineagePlanningProjection ([string]$intent.state.path) (Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $intent.target.state.document));Set-LineagePlanningProjection ([string]$intent.unit.path) (Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $intent.target.unit.document));foreach($projection in @(if($intent.PSObject.Properties.Name-ccontains'additional_projections'){$intent.additional_projections})){Set-LineagePlanningProjection ([string]$projection.path) (Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $projection.document))}}
  foreach($artifact in @($intent.artifacts)){$bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64);$sha=Get-MorphospaceSha256Bytes $bytes;Set-LineagePlanningProjection ([string]$artifact.path) $sha}
  foreach($relative in @($record.event.receipts)){Set-LineagePlanningProjection ([string]$relative) (Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace ([string]$relative) -RequireLeaf))}
  if([string]$record.kind-ceq'supersession'){
   $edge=@($Lineage.ownership.supersessions|Where-Object{[string]$_.event_id-ceq[string]$record.event.event_id});if($edge.Count-ne1){throw 'Supersession retirement planning edge is absent or ambiguous.'};Set-LineagePlanningProjection ([string]$edge[0].request.path) ([string]$edge[0].request.sha256)
   $sourceRelative=[string]$intent.target.unit.document.source_composition.lock_path;$source=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $sourceRelative -RequireLeaf)
   if([string]$source.schema-cne'rusty.morphospace.workflow.source_composition_lock.v1'){if($sourceRelative-cne[string]$Lineage.root_admission.preparation.source_composition_path-and-not$expected.ContainsKey($workspacePrefix+$sourceRelative)){throw 'Supersession retirement planning source is not a preparation/extension-owned artifact.'}}
   elseif([string]$source.unit_id-cne[string]$intent.target.unit.document.unit_id-or[string]$source.project_id-cne[string]$Request.project_id-or[string]$source.fingerprint-cne(Get-MorphospaceSourceCompositionFingerprint -ProjectId ([string]$source.project_id) -UnitId ([string]$source.unit_id) -Repositories @($source.repositories))){throw 'Supersession retirement planning source fingerprint/owner differs.'}
   Set-LineagePlanningProjection $sourceRelative (Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $sourceRelative -RequireLeaf))
  }
  if([string]$record.kind-ceq'tooling-upgrade'){$upgrade=Get-RetirementLineageArtifact $intent 'rusty.morphospace.workflow.tooling_context_upgrade.v1';$context=Get-RetirementLineageArtifact $intent 'rusty.morphospace.workflow.tooling_context.v1';$bindings=&$owner {param($root,$request,$context) Get-ActiveRetirementToolingProofBindings -WorkspaceRoot $root -Request $request -Context $context} $workspace $upgrade.document $context.document;foreach($binding in @($bindings)){Set-LineagePlanningProjection ([string]$binding.path) ([string]$binding.sha256)}}
 }
 Set-LineagePlanningProjection ([string]$Lineage.repository_map.path) ([string]$Lineage.repository_map.raw_sha256)
 foreach($binding in @($Lineage.ownership.repository_maps)){Set-LineagePlanningProjection ([string]$binding.path) ([string]$binding.raw_sha256)}
 # These paths are derived only from authenticated Return events and compared
 # with the whole reviewed ownership above. They may genuinely be untracked or
 # ignored: the original producer required neither a commit nor Git visibility.
 foreach($binding in @($Lineage.ownership.validation_attempts)){Set-LineagePlanningProjection ([string]$binding.path) ([string]$binding.raw_sha256);[void]$retainedInputs.Add($workspacePrefix+[string]$binding.path)}
 Set-LineagePlanningProjection ([string]$Lineage.source_composition.binding.path) ([string]$Lineage.source_composition.binding.raw_sha256)
 $head=if($ObservedHead){$ObservedHead}else{(@(&git -C $repository rev-parse HEAD 2>&1)-join'').Trim()}
 foreach($name in @('retained_claim_diagnostic','retained_ready_diagnostic')){if($Request.PSObject.Properties.Name-ccontains$name){$binding=if($name-ceq'retained_claim_diagnostic'){&$owner {param($root,$request,$repo,$head) Get-ActiveRetirementClaimDiagnosticProjection -Workspace $root -Request $request -Repository $repo -ObservedHead $head} $workspace $Request $repository $head}else{&$owner {param($root,$request,$repo,$head) Get-ActiveRetirementReadyDiagnosticProjection -Workspace $root -Request $request -Repository $repo -ObservedHead $head} $workspace $Request $repository $head};Set-LineagePlanningProjection ([string]$binding.path) ([string]$binding.sha256)}}
 foreach($binding in @(&$owner {param($root,$repo,$head,$request,$events) Get-ActiveRetirementLifecycleDiagnostics $root $repo $head $request $events} $workspace $repository $head $Request $Lineage.events)){Set-LineagePlanningProjection ([string]$binding.path) ([string]$binding.sha256)}
 $eventsSha=if($RecoveryIntent){[string]$RecoveryIntent.expected.events_sha256}else{Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf)}
 Set-LineagePlanningProjection 'iteration-events.jsonl' $eventsSha
 $staged=@(&git -C $repository diff --cached --name-only --no-renames -- 2>&1);if($LASTEXITCODE-ne0-or$staged.Count-ne0){throw 'Supersession retirement planning projection must not be staged.'}
 if($RecoveryIntent){
  # Only the exact pending retirement may overwrite its state/event projections.
  # Keep their historical hashes separately: the committed descendant still
  # needs to prove the real pre-retirement bytes rather than the live target.
  $stateKey=$workspacePrefix+[string]$RecoveryIntent.state.path;$eventsKey=$workspacePrefix+[string]$RecoveryIntent.events.path
  if($historicalRecovery.Count-ne2-or[string]$historicalRecovery[$stateKey]-cne[string]$RecoveryIntent.pre_state_raw.sha256-or[string]$historicalRecovery[$eventsKey]-cne[string]$RecoveryIntent.expected.events_sha256){throw 'Supersession retirement recovery historical projections differ from its authenticated preimage.'}
  $liveState=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace ([string]$RecoveryIntent.state.path) -RequireLeaf);$targetState=Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $RecoveryIntent.target.state.document)
  if($liveState-cne[string]$RecoveryIntent.pre_state_raw.sha256-and$liveState-cne$targetState){throw 'Supersession retirement recovery state is neither its exact preimage nor target.'}
  $liveEvents=[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath $workspace ([string]$RecoveryIntent.events.path) -RequireLeaf));$preLength=[long]$RecoveryIntent.expected.events_length
  $eventLine=[Text.UTF8Encoding]::new($false).GetBytes(($RecoveryIntent.event|ConvertTo-Json -Depth 32 -Compress)+"`n")
  if($liveEvents.LongLength-ne$preLength-and$liveEvents.LongLength-ne($preLength+$eventLine.LongLength)){throw 'Supersession retirement recovery event bytes exceed its exact pending append.'}
  $prefix=[byte[]]::new($preLength);[Array]::Copy($liveEvents,$prefix,$preLength)
  if((Get-MorphospaceSha256Bytes $prefix)-cne[string]$RecoveryIntent.expected.events_sha256){throw 'Supersession retirement recovery event preimage bytes drifted.'}
  if($liveEvents.LongLength-gt$preLength){$appended=[byte[]]::new($preLength+$eventLine.LongLength);[Array]::Copy($prefix,$appended,$preLength);[Array]::Copy($eventLine,0,$appended,$preLength,$eventLine.LongLength);if((Get-MorphospaceSha256Bytes $liveEvents)-cne(Get-MorphospaceSha256Bytes $appended)){throw 'Supersession retirement recovery event append differs from its actual intent.'}}
 }
 foreach($path in @($expected.Keys)){$absolute=Join-Path $repository $path;if(-not[IO.File]::Exists($absolute)-or(Get-MorphospaceFileSha256 $absolute)-cne[string]$expected[$path]){throw "Supersession retirement planning projection bytes changed: $path"}}
 if($LockedCommit){
  foreach($path in @($historicalRecovery.Keys)){$bytes=&$owner {param($repo,$head,$relative) Read-ActiveRetirementCommittedBytes $repo $head $relative} $repository $ObservedHead $path;if((Get-MorphospaceSha256Bytes $bytes)-cne[string]$historicalRecovery[$path]){throw "Supersession retirement recovery committed preimage bytes changed: $path"}}
  # A reviewed Return receipt need not have been committed along with the
  # descendant lifecycle. Permit its literal untracked status only; every live
  # expected byte was checked above, and all other dirt remains unsupported.
  foreach($line in @($StatusPorcelain)){$value=[string]$line;if($value.Length-lt4-or$value.Substring(0,2)-cne'??'-or-not$retainedInputs.Contains($value.Substring(3).Replace('\','/'))){throw 'Supersession retirement planning descendant has dirt outside exact retained validation inputs.'}}
  $cursor=$ObservedHead;$changed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  while($cursor-cne$LockedCommit){$line=(@(&git -C $repository rev-list --parents -n 1 $cursor 2>&1)-join'').Trim();if($LASTEXITCODE-ne0-or$line-cnotmatch'^[0-9a-f]{40} [0-9a-f]{40}$'){throw 'Supersession retirement planning descendant must be linear.'};$parent=$line.Substring(41);$paths=@(&git -C $repository diff --name-status --no-renames $parent $cursor -- 2>&1);if($LASTEXITCODE-ne0){throw 'Supersession retirement planning descendant diff failed.'};foreach($path in $paths){$entry=[string]$path;if($entry-cnotmatch'^[AM]\t(.+)$'){throw 'Supersession retirement planning descendant deletes, renames, or changes an unsupported file kind.'};$relative=([string]$Matches[1]).Replace('\','/');if(-not$expected.ContainsKey($relative)-and-not$historicalRecovery.ContainsKey($relative)){throw "Supersession retirement planning descendant changes unauthenticated path: $relative"};[void]$changed.Add($relative)};$cursor=$parent}
  if($changed.Count-eq0){throw 'Supersession retirement planning descendant contains no lifecycle projection.'};return $true
 }
 $changes=@();foreach($line in @($StatusPorcelain)){$value=[string]$line;if($value.Length-lt4-or$value.Substring(0,2)-cnotin@(' M','??')){throw 'Supersession retirement planning dirt contains a staged, deleted, renamed, conflicted, or unsupported entry.'};$path=$value.Substring(3).Replace('\','/');if($RecoveryIntent-and$path.StartsWith($workspacePrefix,[StringComparison]::Ordinal)-and$recoveryOwned.Contains($path.Substring($workspacePrefix.Length))){continue};$changes+=,$path};$changes=@($changes|Sort-Object -Unique)
 $allowed=@();foreach($path in @($expected.Keys|Sort-Object)){$null=&git -C $repository diff --quiet HEAD -- $path 2>&1;if($LASTEXITCODE-ne0){$allowed+=,$path}else{$null=&git -C $repository ls-files --error-unmatch -- $path 2>&1;if($LASTEXITCODE-ne0){if($retainedInputs.Contains($path)){$null=&git -C $repository check-ignore --quiet -- $path 2>&1;$ignored=$LASTEXITCODE;if($ignored-gt1){throw 'Supersession retirement retained-input Git visibility check failed.'};if($ignored-eq0){continue}};$allowed+=,$path}}};$allowed=@($allowed|Sort-Object -Unique)
 if($changes.Count-ne$allowed.Count-or($changes-join'|')-cne($allowed-join'|')){throw 'Supersession retirement planning dirt differs from the exact authenticated lineage projection.'};return $true
}

Export-ModuleMember -Function Get-MorphospaceActiveRetirementSupersessionLineage,Test-MorphospaceActiveRetirementSupersessionPlanningProjection
