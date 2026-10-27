Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceSourceCompositionIdentity.psm1')
$script:initialProfileLedger=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
$script:initialProfileSchema='rusty.morphospace.workflow.initial_validation_profile_closure_correction.v1'
function Copy-InitialProfileValue([object]$Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String}
function Assert-InitialProfileSchema([object]$Value,[string]$Name){
    if(-not(Test-Json -Json ($Value|ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) "schemas/$Name") -ErrorAction Stop)){throw "Initial profile closure document violates $Name."}
}
function Get-InitialProfileLockFingerprint([object]$Lock){$copy=Copy-InitialProfileValue $Lock;$copy.lock_fingerprint='0'*64;Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($copy|ConvertTo-Json -Depth 64 -Compress)))}
function Get-InitialProfileAdditions([object]$Project,[object]$Unit){
    $known=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($row in @($Project.validation_profiles)){if(-not$known.Add([string]$row.profile_id)){throw 'Initial profile closure project repeats a profile ID.'}}
    $ids=[Collections.Generic.List[string]]::new();$commands=@{}
    foreach($row in @($Unit.validation)){
        $id=[string]$row.profile_id;$command=[string]$row.command
        if([string]::IsNullOrWhiteSpace($id)-or[string]::IsNullOrWhiteSpace($command)){throw 'Initial profile closure unit has an empty profile or command.'}
        if($known.Contains($id)){continue}
        if(-not$commands.ContainsKey($id)){$ids.Add($id);$commands[$id]=[Collections.Generic.List[string]]::new()}
        if(-not$commands[$id].Contains($command)){$commands[$id].Add($command)}
    }
    foreach($id in $ids){[pscustomobject][ordered]@{profile_id=$id;commands=@($commands[$id].ToArray())}}
}
function Assert-InitialProfileEligible([object]$Project,[object]$Lock,[object]$State,[object]$Unit){
    Assert-InitialProfileSchema $Project 'project-spec-v2.schema.json';Assert-InitialProfileSchema $Lock 'feature-lock-v2.schema.json';Assert-InitialProfileSchema $State 'workspace-state-v2.schema.json';Assert-InitialProfileSchema $Unit 'iteration-unit.schema.json'
    if(@('active','validating')-cnotcontains[string]$Unit.status-or[string]$State.current_unit-cne[string]$Unit.unit_id-or
       [string]$Project.project_id-cne[string]$Unit.project_id-or[string]$Lock.project_id-cne[string]$Project.project_id-or[string]$State.project_id-cne[string]$Project.project_id){throw 'Initial profile closure requires the exact active or validating current initial owner.'}
    foreach($name in @('agent_scope_assessment','candidate_freeze','tooling_context')){if($Unit.PSObject.Properties.Name-ccontains$name-and$null-ne$Unit.$name){throw 'Initial profile closure excludes admitted, frozen or tooling-context units.'}}
    if(@($Unit.prerequisites).Count-ne0-or$null-ne$State.next_ready_unit-or$null-ne$State.last_accepted_receipt-or$null-ne$State.validation_checkpoint-or$null-ne$State.pending_push_bundle-or@($State.blockers).Count-ne0){throw 'Initial profile closure excludes checkpoints, successors, blockers or pending publication.'}
    if($State.PSObject.Properties.Name-ccontains'normal_validation_selection'-and$null-ne$State.normal_validation_selection){throw 'Initial profile closure excludes selected validation.'}
    if([int]$Lock.project_revision-ne[int]$Project.revision-or[int]$State.module_registry.lock_revision-ne[int]$Lock.revision-or[string]$State.module_registry.lock_fingerprint-cne[string]$Lock.lock_fingerprint){throw 'Initial profile closure project, feature lock and state revisions are detached.'}
}
function Assert-InitialProfileSource([string]$Workspace,[object]$Unit,[object]$Reference){
    if($Unit.PSObject.Properties.Name-cnotcontains'source_composition'-or[string]$Unit.source_composition.mode-cne'exact-lock'-or$null-ne$Unit.source_composition.materialization_receipt-or[string]$Unit.source_composition.lock_path-cne[string]$Reference.path){throw 'Initial profile closure requires the unchanged exact initial source lock.'}
    $path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Reference.path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $path)-cne[string]$Reference.sha256){throw 'Initial profile closure source-lock raw bytes differ.'}
    $source=Read-MorphospaceProtocolJson $path;Assert-InitialProfileSchema $source 'source-composition-lock.schema.json'
    if([string]$source.schema-cne'rusty.morphospace.workflow.source_composition_lock.v1'-or[string]$source.project_id-cne[string]$Unit.project_id-or[string]$source.unit_id-cne[string]$Unit.unit_id-or[string]$source.fingerprint-cne(Get-MorphospaceSourceCompositionFingerprint -ProjectId ([string]$Unit.project_id) -UnitId ([string]$Unit.unit_id) -Repositories @($source.repositories))){throw 'Initial profile closure source identity is detached.'}
}
function Get-InitialProfileEvents([string]$Workspace){@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_}|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes($_))})}
function Assert-InitialProfileRecoveryProjections([string]$Workspace,[object]$Intent){
    foreach($row in @(@('workspace.state.json',$Intent.pre.state.sha256,$Intent.pre_state_raw.sha256,$Intent.target.state.document),@($Intent.unit.path,$Intent.pre.unit.sha256,$Intent.pre_unit_raw.sha256,$Intent.target.unit.document)) + @($Intent.additional_projections|ForEach-Object{,@($_.path,$_.pre_sha256,$_.pre_raw_sha256,$_.document)})){
        $path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$row[0]) -RequireLeaf;$actual=Read-MorphospaceProtocolJson $path;$canonical=Get-MorphospaceCanonicalJsonSha256 $actual
        if([string]$row[0]-ceq'feature.lock.json'-and-not(Test-MorphospaceFeatureLockFingerprint $actual)){throw 'Initial profile closure recovery feature-lock fingerprint does not authenticate its live preimage or target.'}
        $expectedRaw=if($canonical-ceq[string]$row[1]){[string]$row[2]}elseif($canonical-ceq(Get-MorphospaceCanonicalJsonSha256 $row[3])){Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $row[3])}else{throw 'Initial profile closure recovery projection is outside its exact preimage or target.'}
        if((Get-MorphospaceFileSha256 $path)-cne$expectedRaw){throw 'Initial profile closure recovery projection raw bytes differ.'}
    }
}
function Get-InitialProfileOriginStep([string]$Workspace,[object]$Event,[object]$RecoveryIntent=$null){
    $transaction="$([string]$Event.event_id)-transition"
    if($null-eq$RecoveryIntent){return Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $transaction -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$([string]$Event.unit_id).json" -ExpectedEventsPath 'iteration-events.jsonl'}
    # During v6 repair the physical predecessor can still be the ledger tail
    # while a projection is already the exact owned repair target. Authenticate
    # its retained committed proof without claiming it owns that live target.
    # The private caller fences every live pre/target raw byte above; normal
    # historical reads always retain the public ledger's live-tail check.
    & $script:initialProfileLedger {
        param($root,$id,$event)
        $relative="receipts/transactions/$id.intent.json";$path=Resolve-MorphospaceWorkspacePath $root $relative -RequireLeaf
        $intent=Read-MorphospaceCheckedLedgerIntent $root $id $path ''
        if([string]$intent.state.path-cne'workspace.state.json'-or[string]$intent.unit.path-cne"iteration-units/$([string]$event.unit_id).json"-or[string]$intent.events.path-cne'iteration-events.jsonl'-or(Get-MorphospaceCanonicalJsonSha256 $event)-cne(Get-MorphospaceCanonicalJsonSha256 $intent.event)){throw 'Initial profile closure recovery origin paths or event differ.'}
        Assert-MorphospaceLedgerArtifactNamespace $root $id $intent
        $completion=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $root "receipts/transactions/$id.completion.json" -RequireLeaf)
        Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Initial profile closure recovery origin completion'
        Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Initial profile closure recovery origin intent reference'
        if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or[string]$completion.transaction_id-cne$id-or[string]$completion.status-cne'committed'-or[string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$relative-or[string]$completion.intent.schema-cne[string]$intent.schema-or[string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $path)-or[string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256-or[string]$completion.event_id-cne[string]$intent.event.event_id-or(Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))-lt(Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))){throw 'Initial profile closure recovery origin completion is detached.'}
        [void](Assert-MorphospaceLedgerEventPlacement (Resolve-MorphospaceWorkspacePath $root 'iteration-events.jsonl' -RequireLeaf) $intent -AllowHistorical -RequirePresent)
        foreach($artifact in @($intent.artifacts)){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $root ([string]$artifact.path) -RequireLeaf))-cne[string]$artifact.sha256){throw 'Initial profile closure recovery origin artifact differs.'}}
        [pscustomobject]@{intent=$intent;completion=$completion}
    } $Workspace $transaction $Event
}
function Assert-InitialProfileOrigin {
    param([string]$Workspace,[object]$Unit,[object]$State,[object]$Lock,[object[]]$Events,[object]$RecoveryIntent=$null)
    if($Events.Count-lt2){throw 'Initial profile closure lacks authenticated initial Ready/Claim origin.'}
    $previous=$null;$previousUnit=$null;$claimed=$false;$ready=$false
    foreach($event in $Events){
        if([string]$event.unit_id-cne[string]$Unit.unit_id-or[string]$event.event_type-cne'state-transition'){throw 'Initial profile closure origin contains an unrelated or recorded event.'}
        $step=Get-InitialProfileOriginStep $Workspace $event $RecoveryIntent
        $intent=$step.intent;$target=$intent.target.state.document;$targetUnit=$intent.target.unit.document
        if((Get-MorphospaceCanonicalJsonSha256 $event)-cne(Get-MorphospaceCanonicalJsonSha256 $intent.event)){throw 'Initial profile closure origin event is detached.'}
        if($intent.PSObject.Properties.Name-ccontains'additional_projections'-or$intent.PSObject.Properties.Name-ccontains'supersession'){throw 'Initial profile closure origin is not an unchanged initial contract.'}
        if($null-eq$previous){
            $proposed=Copy-InitialProfileValue $targetUnit;$proposed.status='proposed'
            if([string]$targetUnit.status-cne'ready'-or$null-ne$target.current_unit-or[string]$target.next_ready_unit-cne[string]$Unit.unit_id-or$null-ne$intent.expected.event_tail_id-or[int64]$intent.expected.events_length-ne0-or[string]$intent.expected.events_sha256-cne(Get-MorphospaceSha256Bytes ([byte[]]@()))-or(Get-MorphospaceCanonicalJsonSha256 $proposed)-cne[string]$intent.pre.unit.sha256-or@($intent.artifacts).Count-ne0){throw 'Initial profile closure lacks an authentic initial proposed-to-ready origin.'}
            $ready=$true
        }else{
            if([string]$intent.pre.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $previous)-or[string]$intent.pre.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $previousUnit)){throw 'Initial profile closure origin has a detached committed preimage.'}
            $expectedUnit=Copy-InitialProfileValue $previousUnit
            if(-not$claimed){
                $expectedUnit.status='active'
                if(-not$ready-or[string]$targetUnit.status-cne'active'-or[string]$target.current_unit-cne[string]$Unit.unit_id-or$null-ne$target.next_ready_unit-or@($intent.artifacts).Count-ne0){throw 'Initial profile closure requires the genuine initial Claim.'}
                $claimed=$true
            }elseif([string]$targetUnit.status-ceq'validating'-and[string]$previousUnit.status-ceq'active'){
                $expectedUnit.status='validating'
                if(@($intent.artifacts).Count-ne0){throw 'Initial profile closure excludes a selected or augmented Begin.'}
            }else{
                # Genuine instruction completion can change only planned surface
                # statuses. Its committed typed receipt binds both unit hashes.
                if(@($intent.artifacts).Count-ne1){throw 'Initial profile closure origin has an unsupported transition.'}
                $receipt=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$intent.artifacts[0].bytes_base64))
                Assert-InitialProfileSchema $receipt 'work-unit-automation-receipt.schema.json'
                if([string]$receipt.action-cne'CompleteInstructionSurfaces'-or-not[bool]$receipt.executed-or[string]$receipt.instruction_surface_completion.expected_unit_sha256-cne[string]$intent.pre.unit.sha256-or[string]$receipt.instruction_surface_completion.resulting_unit_sha256-cne[string]$intent.target.unit.sha256-or[string]$receipt.event_id-cne[string]$event.event_id){throw 'Initial profile closure instruction completion is detached.'}
                foreach($surface in @($expectedUnit.instruction_surfaces)){if([string]$surface.status-ceq'planned'){$surface.status='complete'}}
            }
            if((Get-MorphospaceCanonicalJsonSha256 $expectedUnit)-cne[string]$intent.target.unit.sha256){throw 'Initial profile closure immutable unit contract drifted after Ready.'}
        }
        if($null-ne$target.last_accepted_receipt-or$null-ne$target.validation_checkpoint-or$null-ne$target.pending_push_bundle-or@($target.blockers).Count-ne0-or[string]$target.module_registry.lock_fingerprint-cne[string]$Lock.lock_fingerprint-or[int]$target.module_registry.lock_revision-ne[int]$Lock.revision){throw 'Initial profile closure origin contains non-initial authority.'}
        $previous=$target;$previousUnit=$targetUnit
    }
    if(-not$claimed-or(Get-MorphospaceCanonicalJsonSha256 $previous)-cne(Get-MorphospaceCanonicalJsonSha256 $State)-or(Get-MorphospaceCanonicalJsonSha256 $previousUnit)-cne(Get-MorphospaceCanonicalJsonSha256 $Unit)){throw 'Initial profile closure current owner differs from its authenticated initial suffix.'}
}
function Get-InitialProfileTargets([object]$Project,[object]$Lock,[object]$State,[object]$Unit,[object]$Request,[string]$Timestamp){
    Assert-InitialProfileEligible $Project $Lock $State $Unit
    $additions=@(Get-InitialProfileAdditions $Project $Unit)
    if($additions.Count-eq0-or(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{rows=$additions}))-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{rows=@($Request.additions)}))){throw 'Initial profile closure additions must exactly equal the immutable unit missing profiles and ordinal-deduplicated commands.'}
    $projectTarget=Copy-InitialProfileValue $Project;$projectTarget.revision=[int]$Project.revision+1;$projectTarget.validation_profiles=@($projectTarget.validation_profiles)+$additions
    $lockTarget=Copy-InitialProfileValue $Lock;$lockTarget.revision=[int]$Lock.revision+1;$lockTarget.project_revision=[int]$projectTarget.revision;$lockTarget.generated_at=$Timestamp;$lockTarget.lock_fingerprint='0'*64
    $lockTarget=ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $lockTarget)
    $lockTarget.lock_fingerprint=Get-InitialProfileLockFingerprint $lockTarget
    $stateTarget=Copy-InitialProfileValue $State;$stateTarget.plan_revision=[int]$State.plan_revision+1;$stateTarget.last_event_id="$([string]$Request.correction_id)-recorded";$stateTarget.module_registry.lock_revision=[int]$lockTarget.revision;$stateTarget.module_registry.lock_fingerprint=[string]$lockTarget.lock_fingerprint
    Assert-InitialProfileSchema $projectTarget 'project-spec-v2.schema.json';Assert-InitialProfileSchema $lockTarget 'feature-lock-v2.schema.json';Assert-InitialProfileSchema $stateTarget 'workspace-state-v2.schema.json'
    [pscustomobject]@{project=$projectTarget;feature_lock=$lockTarget;state=$stateTarget;unit=$Unit}
}
function Assert-InitialProfileHistoricalTransition {
    param([string]$WorkspaceRoot,[object]$ExpectedEvent,[object]$Transition,[switch]$Recovery)
    $intent=$Transition.intent
    & $script:initialProfileLedger {param($value,$id) Assert-MorphospaceLedgerIntent $value $id} $intent "$([string]$ExpectedEvent.event_id)-transition"
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v6'-or(Get-MorphospaceCanonicalJsonSha256 $ExpectedEvent)-cne(Get-MorphospaceCanonicalJsonSha256 $intent.event)-or@($intent.artifacts).Count-ne1-or@($intent.additional_projections).Count-ne2-or[string]$intent.additional_projections[0].path-cne'feature.lock.json'-or[string]$intent.additional_projections[1].path-cne'project.spec.json'){throw 'Initial profile closure historical transaction shape differs.'}
    if($Recovery){Assert-InitialProfileRecoveryProjections $WorkspaceRoot $intent}
    $artifact=$intent.artifacts[0];$request=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$artifact.bytes_base64));Assert-InitialProfileSchema $request 'initial-validation-profile-closure-correction-v1.schema.json'
    if([string]$ExpectedEvent.summary-cne'Added only exact missing immutable initial-unit validation profile declarations without executing commands or changing unit, source, status or acceptance authority.'-or[string]$artifact.path-cne"receipts/$([string]$request.correction_id).json"-or[string]$ExpectedEvent.event_id-cne"$([string]$request.correction_id)-recorded"-or[string]$ExpectedEvent.unit_id-cne[string]$request.unit_id-or@($ExpectedEvent.receipts).Count-ne1-or[string]$ExpectedEvent.receipts[0]-cne[string]$artifact.path){throw 'Initial profile closure historical request identity differs.'}
    $unit=$intent.target.unit.document;$state=Copy-InitialProfileValue $intent.target.state.document;$lock=Copy-InitialProfileValue $intent.additional_projections[0].document;$project=Copy-InitialProfileValue $intent.additional_projections[1].document
    $project.revision=[int]$project.revision-1
    if(@($project.validation_profiles).Count-lt@($request.additions).Count){throw 'Initial profile closure historical additions are detached.'}
    $project.validation_profiles=@($project.validation_profiles|Select-Object -First (@($project.validation_profiles).Count-@($request.additions).Count))
    $lock.revision=[int]$request.expected.feature_lock_revision;$lock.project_revision=[int]$request.expected.project_revision;$lock.generated_at=[string]$request.expected.feature_lock_generated_at
    $events=@(Get-InitialProfileEvents $WorkspaceRoot|Where-Object{[int]$_.sequence-lt[int]$ExpectedEvent.sequence})
    if($events.Count-eq0-or[string]$events[-1].event_id-cne[string]$request.expected.event_tail_id){throw 'Initial profile closure historical prefix is detached.'}
    $recoveryIntent=if($Recovery){$intent}else{$null}
    $predecessor=Get-InitialProfileOriginStep $WorkspaceRoot $events[-1] $recoveryIntent
    $state=Copy-InitialProfileValue $predecessor.intent.target.state.document;$lock.lock_fingerprint=[string]$state.module_registry.lock_fingerprint
    if([string]$request.project_id-cne[string]$unit.project_id-or[string]$ExpectedEvent.project_id-cne[string]$request.project_id-or[string]$request.unit_id-cne[string]$unit.unit_id-or[string]$request.expected.current_unit-cne[string]$state.current_unit-or[string]$request.expected.status-cne[string]$unit.status-or[int]$request.expected.project_revision-ne[int]$project.revision-or[int]$request.expected.plan_revision-ne[int]$state.plan_revision){throw 'Initial profile closure historical identity, status or revision metadata differs.'}
    foreach($row in @(@('project',$project,$intent.additional_projections[1]),@('feature_lock',$lock,$intent.additional_projections[0]),@('state',$state,$null),@('unit',$unit,$null))){$name=$row[0];$hash=Get-MorphospaceCanonicalJsonSha256 $row[1];if($hash-cne[string]$request.expected.($name+'_sha256')){throw "Initial profile closure historical $name preimage differs."};if($null-ne$row[2]-and([string]$row[2].pre_sha256-cne$hash-or[string]$row[2].pre_raw_sha256-cne[string]$request.expected.($name+'_raw_sha256'))){throw 'Initial profile closure historical raw projection binding differs.'}}
    if([string]$intent.pre.state.sha256-cne[string]$request.expected.state_sha256-or[string]$intent.pre.unit.sha256-cne[string]$request.expected.unit_sha256-or[string]$intent.pre_state_raw.sha256-cne[string]$request.expected.state_raw_sha256-or[string]$intent.pre_unit_raw.sha256-cne[string]$request.expected.unit_raw_sha256-or[string]$intent.expected.events_sha256-cne[string]$request.expected.events_sha256-or[int64]$intent.expected.events_length-ne[int64]$request.expected.events_length){throw 'Initial profile closure historical raw preimages or ledger binding differ.'}
    Assert-InitialProfileSource $WorkspaceRoot $unit $request.expected.source_composition
    Assert-InitialProfileOrigin $WorkspaceRoot $unit $state $lock $events $recoveryIntent
    $targets=Get-InitialProfileTargets $project $lock $state $unit $request ([string]$ExpectedEvent.timestamp)
    foreach($row in @(@($targets.project,$intent.additional_projections[1].document),@($targets.feature_lock,$intent.additional_projections[0].document),@($targets.state,$intent.target.state.document),@($targets.unit,$intent.target.unit.document))){if((Get-MorphospaceCanonicalJsonSha256 $row[0])-cne(Get-MorphospaceCanonicalJsonSha256 $row[1])){throw 'Initial profile closure historical target changes unrelated authority.'}}
    # Canonical historical reconstruction loses the old compressed producer's
    # property order. Its exact raw/canonical preimage bindings remain above;
    # validate a target fingerprint against real live bytes when still current.
    $liveLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'feature.lock.json' -RequireLeaf)
    if((Get-MorphospaceCanonicalJsonSha256 $liveLock)-ceq[string]$intent.additional_projections[0].target_sha256-and-not(Test-MorphospaceFeatureLockFingerprint $liveLock)){throw 'Initial profile closure historical live target feature-lock fingerprint is invalid.'}
    $Transition
}
function Test-MorphospaceHistoricalInitialValidationProfileClosure {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$ExpectedEvent)
    $step=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId "$([string]$ExpectedEvent.event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$([string]$ExpectedEvent.unit_id).json" -ExpectedEventsPath 'iteration-events.jsonl'
    Assert-InitialProfileHistoricalTransition $WorkspaceRoot $ExpectedEvent $step
}
function Assert-InitialProfileRecoveryIsolation([string]$Workspace,[string]$Transaction){
    # The generic pre-start guard deliberately refuses every pending intent,
    # including this one. Recovery authenticates this exact intent first and
    # uses the existing ledger repair, while refusing any other pending owner.
    $directory=Resolve-MorphospaceWorkspacePath $Workspace 'receipts/transactions'
    foreach($path in [IO.Directory]::EnumerateFiles($directory,'*.intent.json')){
        $name=[IO.Path]::GetFileName($path)
        if($name-cnotmatch'^(?<id>[a-z0-9][a-z0-9-]{1,191})\.intent\.json$'){throw 'Initial profile closure recovery has a malformed transaction namespace.'}
        $id=[string]$Matches.id
        if($id-cne$Transaction-and-not[IO.File]::Exists((Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$id.completion.json"))){throw 'Initial profile closure recovery refuses an unrelated incomplete transaction.'}
    }
}
function Invoke-MorphospaceCorrectInitialValidationProfileClosure {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$UnitId,[Parameter(Mandatory)][string]$InitialValidationProfileCorrectionPath,[Parameter(Mandatory)][string]$OutPath,[string]$ExpectedInitialValidationProfileCorrectionSha256='',[string]$Timestamp='',[scriptblock]$BeforeTransitionHook,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none',[switch]$Execute)
    $workspace=(Resolve-Path -LiteralPath $WorkspaceRoot).Path;$requestPath=(Resolve-Path -LiteralPath $InitialValidationProfileCorrectionPath).Path
    $requestBytes=[IO.File]::ReadAllBytes($requestPath);$hash=Get-MorphospaceSha256Bytes $requestBytes;$request=ConvertFrom-MorphospaceProtocolJsonBytes $requestBytes;Assert-InitialProfileSchema $request 'initial-validation-profile-closure-correction-v1.schema.json'
    if($ExpectedInitialValidationProfileCorrectionSha256-and$hash-cne$ExpectedInitialValidationProfileCorrectionSha256){throw 'Initial profile closure request raw bytes differ.'}
    if($Execute-and-not$ExpectedInitialValidationProfileCorrectionSha256){throw 'Initial profile closure execute requires the exact dry-run request hash.'}
    if([string]$request.unit_id-cne$UnitId-or[string]$request.expected.current_unit-cne$UnitId){throw 'Initial profile closure UnitId differs.'}
    $outRelative="receipts/$([string]$request.correction_id).json";$out=Resolve-MorphospaceWorkspacePath $workspace $outRelative
    if([IO.Path]::GetFullPath($OutPath)-cne[IO.Path]::GetFullPath($out)-or[IO.Path]::GetFullPath($requestPath)-ceq[IO.Path]::GetFullPath($out)){throw 'Initial profile closure output must be the distinct exact owner receipt path.'}
    if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};[void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    $eventId="$([string]$request.correction_id)-recorded";$transaction="$eventId-transition"
    if($BeforeTransitionHook){&$BeforeTransitionHook}
    $mutex=Enter-MorphospaceWorkspaceMutex $workspace
    try{
        if((Get-MorphospaceFileSha256 $requestPath)-cne$hash){throw 'Initial profile closure request raw bytes changed before intent.'}
        $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transaction.intent.json"
        if([IO.File]::Exists($intentPath)){
            if(-not$Execute){throw 'Initial profile closure transaction already exists; use exact authenticated execute recovery.'}
            $intent=Read-MorphospaceProtocolJson $intentPath
            if(@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].sha256-cne$hash-or[string]$intent.artifacts[0].bytes_base64-cne[Convert]::ToBase64String([IO.File]::ReadAllBytes($requestPath))){throw 'Initial profile closure recovery request differs from its intent.'}
            [void](Assert-InitialProfileHistoricalTransition $workspace $intent.event ([pscustomobject]@{intent=$intent}) -Recovery)
            Assert-InitialProfileRecoveryIsolation $workspace $transaction
            [void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transaction -Repair)
            $unit=$intent.target.unit.document;$state=$intent.target.state.document;$Timestamp=[string]$intent.event.timestamp
        }else{
            & $script:initialProfileLedger {param($root,$id) Assert-MorphospaceNoOutstandingTransitionIntent $root $id} $workspace $transaction
            if([IO.File]::Exists($out)){throw 'Initial profile closure output already exists without its transaction.'}
            $project=Read-MorphospaceProtocolJson (Join-Path $workspace 'project.spec.json');$lock=Read-MorphospaceProtocolJson (Join-Path $workspace 'feature.lock.json');$state=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json');$unit=Read-MorphospaceProtocolJson (Join-Path $workspace "iteration-units/$UnitId.json")
            if([string]$request.project_id-cne[string]$project.project_id-or[string]$request.expected.status-cne[string]$unit.status){throw 'Initial profile closure request identity or status differs.'}
            foreach($row in @(@('project','project.spec.json',$project),@('feature_lock','feature.lock.json',$lock),@('state','workspace.state.json',$state),@('unit',"iteration-units/$UnitId.json",$unit))){$name=$row[0];if((Get-MorphospaceCanonicalJsonSha256 $row[2])-cne[string]$request.expected.($name+'_sha256')-or(Get-MorphospaceFileSha256 (Join-Path $workspace $row[1]))-cne[string]$request.expected.($name+'_raw_sha256')){throw "Initial profile closure expected $name canonical or raw bytes differ."}}
            if([int]$project.revision-ne[int]$request.expected.project_revision-or[int]$lock.revision-ne[int]$request.expected.feature_lock_revision-or[int]$state.plan_revision-ne[int]$request.expected.plan_revision-or[string]$lock.generated_at-cne[string]$request.expected.feature_lock_generated_at){throw 'Initial profile closure expected revisions differ.'}
            $eventsPath=Join-Path $workspace 'iteration-events.jsonl';$events=@(Get-InitialProfileEvents $workspace)
            if((Get-MorphospaceFileSha256 $eventsPath)-cne[string]$request.expected.events_sha256-or[IO.FileInfo]::new($eventsPath).Length-ne[int64]$request.expected.events_length-or[string]$state.last_event_id-cne[string]$request.expected.event_tail_id-or$events.Count-eq0-or[string]$events[-1].event_id-cne[string]$state.last_event_id){throw 'Initial profile closure expected ledger bytes, length or tail differ.'}
            Assert-InitialProfileSource $workspace $unit $request.expected.source_composition
            if(-not(Test-MorphospaceFeatureLockFingerprint $lock)){throw 'Initial profile closure feature-lock fingerprint does not authenticate its semantic preimage.'}
            Assert-InitialProfileEligible $project $lock $state $unit
            Assert-InitialProfileOrigin $workspace $unit $state $lock $events
            $target=Get-InitialProfileTargets $project $lock $state $unit $request $Timestamp
            $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$events[-1].sequence+1;timestamp=$Timestamp;project_id=[string]$request.project_id;unit_id=$UnitId;event_type='state-transition';summary='Added only exact missing immutable initial-unit validation profile declarations without executing commands or changing unit, source, status or acceptance authority.';receipts=@($outRelative)}
            Assert-InitialProfileSchema $event 'iteration-event.schema.json'
            if($Execute){
                # Held through the existing ledger's reentrant mutex and v6 CAS.
                Assert-InitialProfileSource $workspace $unit $request.expected.source_composition
                if((Get-MorphospaceFileSha256 $requestPath)-cne$hash){throw 'Initial profile closure request raw bytes changed before intent.'}
                Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transaction -StatePath 'workspace.state.json' -UnitPath "iteration-units/$UnitId.json" -EventsPath 'iteration-events.jsonl' -TargetState $target.state -TargetUnit $unit -Event $event -ExpectedPreStateSha256 ([string]$request.expected.state_sha256) -ExpectedPreStateRawSha256 ([string]$request.expected.state_raw_sha256) -ExpectedPreUnitSha256 ([string]$request.expected.unit_sha256) -ExpectedPreUnitRawSha256 ([string]$request.expected.unit_raw_sha256) -ExpectedEventTailId ([string]$request.expected.event_tail_id) -ExpectedEventsSha256 ([string]$request.expected.events_sha256) -ExpectedEventsLength ([int64]$request.expected.events_length) -AdditionalProjections @([pscustomobject]@{path='feature.lock.json';expected_sha256=[string]$request.expected.feature_lock_sha256;expected_raw_sha256=[string]$request.expected.feature_lock_raw_sha256;document=$target.feature_lock},[pscustomobject]@{path='project.spec.json';expected_sha256=[string]$request.expected.project_sha256;expected_raw_sha256=[string]$request.expected.project_raw_sha256;document=$target.project}) -Artifacts @([pscustomobject]@{source_path=$requestPath;path=$outRelative;sha256=$hash}) -FaultAfter $FaultAfter|Out-Null
            }
        }
        $result=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$request.project_id;unit_id=$UnitId;action='CorrectInitialValidationProfileClosure';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='initial-validation-profile-closure-corrected';status_before=[string]$unit.status;status_after=[string]$unit.status;current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[pscustomobject]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject]@{path=$outRelative;sha256=$hash};event_id=$(if($Execute){$eventId}else{$null})}
        Assert-InitialProfileSchema $result 'work-unit-automation-receipt-v2.schema.json';$result
    }finally{Exit-MorphospaceWorkspaceMutex $mutex}
}
Export-ModuleMember -Function Invoke-MorphospaceCorrectInitialValidationProfileClosure,Test-MorphospaceHistoricalInitialValidationProfileClosure
