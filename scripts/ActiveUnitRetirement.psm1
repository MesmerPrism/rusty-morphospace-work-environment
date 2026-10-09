Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:ActiveRetirementHistoricalEventsScope=$null
$script:ActiveRetirementHadCallerProtocolCommon=$null-ne(Get-Command Read-MorphospaceProtocolJson -ErrorAction SilentlyContinue)
$script:ActiveRetirementHadCallerTransitionLedger=$null-ne(Get-Command Test-MorphospaceCommittedTransitionLedger -ErrorAction SilentlyContinue)
$script:ActiveRetirementProtocolCommonPath=Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1'
$script:ActiveRetirementTransitionLedgerPath=Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1'
Import-Module $script:ActiveRetirementProtocolCommonPath
Import-Module $script:ActiveRetirementTransitionLedgerPath
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceSourceCompositionIdentity.psm1')
if($script:ActiveRetirementHadCallerProtocolCommon){Microsoft.PowerShell.Core\Import-Module $script:ActiveRetirementProtocolCommonPath -Global}
if($script:ActiveRetirementHadCallerTransitionLedger){Microsoft.PowerShell.Core\Import-Module $script:ActiveRetirementTransitionLedgerPath -Global}

function Restore-ActiveRetirementCallerModules {
    if($script:ActiveRetirementHadCallerProtocolCommon){Microsoft.PowerShell.Core\Import-Module $script:ActiveRetirementProtocolCommonPath -Global}
    if($script:ActiveRetirementHadCallerTransitionLedger){Microsoft.PowerShell.Core\Import-Module $script:ActiveRetirementTransitionLedgerPath -Global}
}
function Assert-ActiveRetirementSchema([object]$Document,[string]$Name) {
    if(-not(Test-Json -Json ($Document|ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) "schemas/$Name"))){throw "Active retirement $Name contract is invalid."}
}
function Copy-ActiveRetirementValue([object]$Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String}
function Assert-ActiveRetirementEqual([object]$Expected,[object]$Actual,[string]$Label){
    if((Get-MorphospaceCanonicalJsonSha256 $Expected)-cne(Get-MorphospaceCanonicalJsonSha256 $Actual)){throw "Active retirement $Label binding drifted."}
}
function Get-ActiveRetirementReference([string]$Workspace,[string]$Path){
    $relative=if([IO.Path]::IsPathRooted($Path)){[IO.Path]::GetRelativePath($Workspace,$Path).Replace('\','/')}else{$Path}
    $relative=ConvertTo-MorphospaceProtocolRelativePath $relative
    if($relative-cnotmatch '^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'){throw 'Active retirement references must use the workspace receipts namespace.'}
    [pscustomobject]@{path=$relative;absolute=Resolve-MorphospaceWorkspacePath $Workspace $relative}
}
function Get-ActiveRetirementFileBinding([string]$Workspace,[string]$Path){
    $absolute=Resolve-MorphospaceWorkspacePath $Workspace $Path -RequireLeaf
    $document=Read-MorphospaceProtocolJson $absolute
    [pscustomobject][ordered]@{path=$Path;raw_sha256=Get-MorphospaceFileSha256 $absolute;canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $document}
}
function Get-ActiveRetirementEvents([string]$Workspace){
    $path=Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf
    $bytes=[IO.File]::ReadAllBytes($path)
    if($bytes.Length-eq0-or$bytes.Length-gt67108864-or$bytes[-1]-ne10){throw 'Active retirement requires a bounded LF-terminated event ledger.'}
    $sha=Get-MorphospaceSha256Bytes $bytes
    $scope=$script:ActiveRetirementHistoricalEventsScope
    if($null-ne$scope){
        $workspaceKey=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
        $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
        if(-not$scope.workspace.Equals($workspaceKey,$comparison)){throw 'Historical retirement event observation escaped its workspace.'}
        $schemaHashes=@('iteration-event.schema.json','iteration-event-v2.schema.json'|ForEach-Object{Get-MorphospaceFileSha256 (Join-Path (Split-Path $PSScriptRoot -Parent) "schemas/$_")})-join':'
        if($null-ne$scope.observation){
            if($scope.observation.length-ne[long]$bytes.Length-or$scope.observation.sha256-cne$sha){throw 'Historical retirement event ledger changed during authentication.'}
            if($scope.schema_hashes-cne$schemaHashes){throw 'Historical retirement event schemas changed during authentication.'}
            return $scope.observation
        }
    }
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    $events=@();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($line in @($text.Split([char]10))){
        if(-not$line){continue};$event=$line|ConvertFrom-Json -DateKind String
        $schema=switch -CaseSensitive ([string]$event.schema){
            'rusty.morphospace.workflow.iteration_event.v1' {'iteration-event.schema.json'}
            'rusty.morphospace.workflow.iteration_event.v2' {'iteration-event-v2.schema.json'}
            default {throw 'Active retirement event schema is unsupported.'}
        }
        Assert-ActiveRetirementSchema $event $schema
        if(-not$seen.Add([string]$event.event_id)-or[int]$event.sequence-ne($events.Count+1)){throw 'Active retirement event sequence or identity is invalid.'}
        $events+=,$event
    }
    $observation=[pscustomobject]@{events=$events;sha256=$sha;length=[long]$bytes.Length;tail_id=[string]$events[-1].event_id}
    if($null-ne$scope){
        $validatedSchemaHashes=@('iteration-event.schema.json','iteration-event-v2.schema.json'|ForEach-Object{Get-MorphospaceFileSha256 (Join-Path (Split-Path $PSScriptRoot -Parent) "schemas/$_")})-join':'
        if($schemaHashes-cne$validatedSchemaHashes){throw 'Historical retirement event schemas changed during authentication.'}
        $scope.observation=$observation;$scope.schema_hashes=$schemaHashes
    }
    $observation
}
function Get-ActiveRetirementCanonicalRawSha256([object]$Document){Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $Document)}
function Import-ActiveRetirementDevelopmentEnvelopeProvenance {
    $path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1'))
    $module=Get-Module DevelopmentEnvelopeProvenance -All|Where-Object{[IO.Path]::GetFullPath([string]$_.Path)-ceq$path}|Select-Object -First 1
    if($null-ne$module){return $module}
    $module=Import-Module $path -PassThru
    Import-Module $script:ActiveRetirementProtocolCommonPath
    Import-Module $script:ActiveRetirementTransitionLedgerPath
    Restore-ActiveRetirementCallerModules
    $module
}
function Get-ActiveRetirementPlanningTransition([string]$Workspace,[string]$TransactionId,[switch]$HistoricalProjection){
    if(-not$HistoricalProjection){return Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $TransactionId -ExpectedEventsPath 'iteration-events.jsonl'}
    $ledger=Get-Module MorphospaceTransitionLedger -All|Select-Object -First 1
    if($null-eq$ledger){throw 'Active retirement planning transition-ledger verifier is unavailable.'}
    &$ledger {param($root,$id)
        $intentRelative=Get-MorphospaceLedgerPath $root $id intent;$completionRelative=Get-MorphospaceLedgerPath $root $id completion;$intentAbsolute=Resolve-MorphospaceWorkspacePath $root $intentRelative -RequireLeaf;$completionAbsolute=Resolve-MorphospaceWorkspacePath $root $completionRelative -RequireLeaf
        $intent=Read-MorphospaceLedgerJson $intentAbsolute;Assert-MorphospaceLedgerIntent $intent $id;Assert-MorphospaceLedgerArtifactNamespace $root $id $intent;$completion=Read-MorphospaceLedgerJson $completionAbsolute
        Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Active retirement historical planning completion';Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Active retirement historical planning completion intent'
        if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or[string]$completion.transaction_id-cne$id-or[string]$completion.status-cne'committed'-or[string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$intentRelative-or[string]$completion.intent.schema-cne[string]$intent.schema-or[string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $intentAbsolute)-or[string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256-or[string]$completion.event_id-cne[string]$intent.event.event_id){throw 'Active retirement historical planning completion is detached.'}
        if((Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))-lt(Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))){throw 'Active retirement historical planning completion timestamp is invalid.'}
        [void](Assert-MorphospaceLedgerEventPlacement (Resolve-MorphospaceWorkspacePath $root ([string]$intent.events.path) -RequireLeaf) $intent -AllowHistorical -RequirePresent)
        foreach($artifact in @($intent.artifacts)){$target=Resolve-MorphospaceWorkspacePath $root ([string]$artifact.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $target)-cne[string]$artifact.sha256){throw 'Active retirement historical planning artifact differs from its intent.'}}
        [pscustomobject]@{intent=$intent;completion=$completion}
    } $Workspace $TransactionId
}
function Test-ActiveRetirementRecoveryPreparationProvenance([string]$Workspace,[object]$Admission,[object]$RecoveryIntent,[Management.Automation.PSModuleInfo]$ProvenanceModule){
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-retirement-provenance-'+[guid]::NewGuid().ToString('N'))
    try{
        Copy-Item -LiteralPath $Workspace -Destination $temporary -Recurse -Force
        $preState=Copy-ActiveRetirementValue $RecoveryIntent.target.state.document;$preState.current_unit=[string]$RecoveryIntent.target.unit.document.unit_id;$preState.last_event_id=[string]$RecoveryIntent.expected.event_tail_id
        if((Get-MorphospaceCanonicalJsonSha256 $preState)-cne[string]$RecoveryIntent.pre.state.sha256){throw 'Active retirement recovery state preimage is detached.'}
        [IO.File]::WriteAllBytes((Join-Path $temporary ([string]$RecoveryIntent.state.path)),(ConvertTo-MorphospaceProtocolJsonBytes $preState))
        $liveEvents=[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath $Workspace ([string]$RecoveryIntent.events.path) -RequireLeaf));$length=[long]$RecoveryIntent.expected.events_length
        if($length-lt0-or$length-gt$liveEvents.Length){throw 'Active retirement recovery event prefix length is invalid.'};$prefix=[byte[]]::new($length);[Array]::Copy($liveEvents,$prefix,$length)
        if((Get-MorphospaceSha256Bytes $prefix)-cne[string]$RecoveryIntent.expected.events_sha256){throw 'Active retirement recovery event prefix differs from its authenticated preimage.'};[IO.File]::WriteAllBytes((Join-Path $temporary ([string]$RecoveryIntent.events.path)),$prefix)
        foreach($relative in @("receipts/transactions/$($RecoveryIntent.transaction_id).intent.json","receipts/transactions/$($RecoveryIntent.transaction_id).completion.json")+@($RecoveryIntent.artifacts|ForEach-Object{[string]$_.path})){$path=Resolve-MorphospaceWorkspacePath $temporary $relative;if([IO.File]::Exists($path)){Remove-Item -LiteralPath $path -Force}}
        $transactionRoot=Resolve-MorphospaceWorkspacePath $temporary 'receipts/transactions';foreach($pending in @(Get-ChildItem -LiteralPath $transactionRoot -File -Filter "$($RecoveryIntent.transaction_id).artifact-*.pending")){Remove-Item -LiteralPath $pending.FullName -Force}
        return &$ProvenanceModule {param($root,$admission) Test-MorphospaceDevelopmentUnitPreparation -WorkspaceRoot $root -Admission $admission -Phase Freeze} $temporary $Admission
    }finally{
        $resolved=[IO.Path]::GetFullPath($temporary);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if($resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($resolved).StartsWith('morphospace-retirement-provenance-')){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
    }
}
function Assert-ActiveRetirementPlanningContinuationEvents {
    param([object[]]$Events,[int]$AfterSequence,[string]$UnitId)
    for($index=0;$index-lt$Events.Count;$index++){
        $event=$Events[$index]
        if([int]$event.sequence-ne($AfterSequence+$index+1)-or[string]$event.unit_id-cne$UnitId-or[string]$event.event_id-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}-(?:recorded|tooling-context-upgraded|validating-[0-9]{4,}|validation-fail-[0-9]{4,}|resumed-[0-9]{4,}|blocker-resolved-[0-9]{4,})$'){throw 'Active retirement planning continuation is not a contiguous same-unit authenticated transition suffix.'}
    }
}
function Assert-ActiveRetirementImmutableNonpassReceipt {
    param([string]$Workspace,[string]$Relative)
    $repository=(@(&git -C $Workspace rev-parse --show-toplevel 2>&1)-join'').Trim();if($LASTEXITCODE-ne0){throw 'Active retirement nonpass receipt requires committed planning history.'}
    $prefix=[IO.Path]::GetRelativePath($repository,$Workspace).Replace('\','/').TrimEnd('/');if($prefix-ceq'.'){$prefix=''}else{$prefix+='/' };$gitPath=$prefix+$Relative
    $additions=@(&git -C $repository log --format=%H --diff-filter=A -- $gitPath 2>&1);if($LASTEXITCODE-ne0-or$additions.Count-ne1){throw 'Active retirement nonpass receipt requires one original committed addition.'}
    $blob=(@(&git -C $repository rev-parse "$($additions[0]):$gitPath" 2>&1)-join'').Trim();if($LASTEXITCODE-ne0){throw 'Active retirement nonpass original blob is unavailable.'}
    $changes=@(&git -C $repository log --format=%H -- $gitPath 2>&1);if($LASTEXITCODE-ne0){throw 'Active retirement nonpass receipt history is unavailable.'}
    foreach($revision in @($changes)+@('HEAD')){$observed=(@(&git -C $repository rev-parse "$($revision):$gitPath" 2>&1)-join'').Trim();if($LASTEXITCODE-ne0-or$observed-cne$blob){throw 'Active retirement nonpass original receipt was rewritten in planning history.'}}
    $live=(@(&git -C $repository hash-object --path=$gitPath -- (Resolve-MorphospaceWorkspacePath $Workspace $Relative -RequireLeaf) 2>&1)-join'').Trim();if($LASTEXITCODE-ne0-or$live-cne$blob){throw 'Active retirement nonpass original receipt live bytes drifted.'}
}

function Assert-ActiveRetirementRetainedLifecycle {
    param([string]$Workspace,[object]$Event,[object]$Transition)
    $intent=$Transition.intent;$unitId=[string]$Event.unit_id
    $prior=Get-ActiveRetirementPlanningTransition $Workspace "$([string]$intent.expected.event_tail_id)-transition"
    if([string]$prior.intent.event.unit_id-cne$unitId-or[int]$prior.intent.event.sequence-ne([int]$Event.sequence-1)-or[string]$intent.pre.state.sha256-cne[string]$prior.intent.target.state.sha256-or[string]$intent.pre.unit.sha256-cne[string]$prior.intent.target.unit.sha256){throw 'Active retirement retained lifecycle predecessor is detached.'}
    $state=Copy-ActiveRetirementValue $prior.intent.target.state.document;$unit=Copy-ActiveRetirementValue $prior.intent.target.unit.document
    $targetUnit=$intent.target.unit.document;$targetState=$intent.target.state.document
    $development=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceDevelopmentContinuation.psm1') -PassThru
    $instruction=@($intent.artifacts|Where-Object{[string](ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))).schema-ceq'rusty.morphospace.workflow.work_unit_automation_receipt.v1'})
    $freeze=@($intent.artifacts|Where-Object{[string](ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))).schema-cin@('rusty.morphospace.workflow.candidate_freeze.v1','rusty.morphospace.workflow.candidate_freeze.v2')})
    if($instruction.Count-eq1){
        if([string]$unit.status-cne'active'-or[string]$state.current_unit-cne$unitId){throw 'Active retirement instruction completion requires active ownership.'}
        $null=&$development {param($before,$after,$intent,$event)Assert-DevelopmentContinuationRetainedAuthority $before $after $intent $event} $unit $targetUnit $intent $Event
        $unit=Copy-ActiveRetirementValue $targetUnit
    }elseif($freeze.Count-eq1){
        if(@($intent.artifacts).Count-ne1-or[string]$unit.status-cne'active'-or[string]$state.current_unit-cne$unitId-or$unit.PSObject.Properties.Name-ccontains'candidate_freeze'){throw 'Active retirement Freeze requires an unfrozen active owner.'}
        $binding=$freeze[0];$receipt=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$binding.bytes_base64))
        $schema=if([string]$receipt.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v1'){'candidate-freeze-v1.schema.json'}else{'candidate-freeze-v2.schema.json'};Assert-ActiveRetirementSchema $receipt $schema
        if([string]$receipt.unit_id-cne$unitId-or[string]$receipt.project_id-cne[string]$Event.project_id-or[string]$Event.event_id-cne"$([string]$receipt.freeze_id)-recorded"-or[string]$receipt.expected.unit_sha256-cne[string]$intent.pre.unit.sha256-or[string]$receipt.expected.state_sha256-cne[string]$intent.pre.state.sha256-or[string]$Event.summary-cne'Froze the exact candidate closure before validation.'){throw 'Active retirement Freeze receipt is detached.'}
        Assert-ActiveRetirementEqual @($binding.path) @($Event.receipts) 'Freeze event receipt'
        $pointer=[pscustomobject]@{freeze_id=[string]$receipt.freeze_id;receipt_path=[string]$binding.path;receipt_sha256=[string]$binding.sha256}
        $unit|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue $pointer
    }elseif([string]$Event.event_id-cmatch('^'+[regex]::Escape($unitId)+'-validating-[0-9]{4,}$')){
        if([string]$unit.status-cne'active'-or[string]$state.current_unit-cne$unitId-or$unit.PSObject.Properties.Name-cnotcontains'candidate_freeze'-or@($intent.artifacts).Count-ne0-or@($Event.receipts).Count-ne0-or[string]$Event.summary-cne'Entered validation with a deterministic command, instruction, graph, and device-impact plan.'){throw 'Active retirement BeginValidation is not the exact frozen active transition.'};$unit.status='validating'
    }elseif([string]$Event.event_id-cmatch('^'+[regex]::Escape($unitId)+'-validation-fail-[0-9]{4,}$')){
        if([string]$unit.status-cne'validating'-or[string]$state.current_unit-cne$unitId-or@($intent.artifacts).Count-ne0-or@($Event.receipts).Count-ne1-or[string]$Event.event_type-cne'blocker'-or[string]$Event.summary-cne'Recorded non-passing validation and blocked further acceptance.'){throw 'Active retirement nonpass is not the exact validating-to-blocked transition.'}
        $relative=[string]$Event.receipts[0];Assert-ActiveRetirementImmutableNonpassReceipt $Workspace $relative;$receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf);Assert-ActiveRetirementSchema $receipt 'validation-receipt.schema.json'
        if([string]$receipt.schema-cne'rusty.morphospace.workflow.validation_receipt.v1'-or[string]$receipt.unit_id-cne$unitId-or[string]$receipt.project_id-cne[string]$Event.project_id-or[string]$receipt.result-cne'fail'){throw 'Active retirement nonpass receipt identity/result is detached.'}
        foreach($artifact in @($receipt.artifacts)){$artifactPath=if([IO.Path]::IsPathRooted([string]$artifact.path)){[IO.Path]::GetFullPath([string]$artifact.path)}else{[IO.Path]::GetFullPath((Join-Path (Split-Path (Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf) -Parent) ([string]$artifact.path)))};if((Get-MorphospaceFileSha256 $artifactPath)-cne[string]$artifact.sha256){throw 'Active retirement nonpass artifact bytes drifted.'}}
        $state.validation_checkpoint=[pscustomobject]@{receipt=$relative;result='fail';tier=[string]$receipt.tier};$unit.status='blocked';$state.current_unit=$null
        if($state.PSObject.Properties.Name-ccontains'normal_validation_selection'){$state.normal_validation_selection=$null}
        $blockerId="$unitId-validation-fail";if(@($state.blockers|Where-Object blocker_id -CEQ $blockerId).Count-ne0){throw 'Active retirement nonpass repeats a failure blocker.'}
        $state.blockers=@($state.blockers)+@([pscustomobject]@{blocker_id=$blockerId;condition="Validation result is fail in $relative.";resume_when='Correct the failure and explicitly resume the unit.'})
    }elseif([string]$Event.event_id-cmatch('^'+[regex]::Escape($unitId)+'-resumed-[0-9]{4,}$')){
        if([string]$unit.status-cne'blocked'-or$null-ne$state.current_unit-or[string]$state.validation_checkpoint.result-cne'fail'-or@($intent.artifacts).Count-ne0-or@($Event.receipts).Count-ne0-or[string]$Event.summary-cne'Resumed a blocked unit while preserving blocker and validation history.'){throw 'Active retirement Resume is not the exact failed blocked owner transition.'};$unit.status='active';$state.current_unit=$unitId
    }elseif([string]$Event.event_id-cmatch('^'+[regex]::Escape($unitId)+'-blocker-resolved-[0-9]{4,}$')){
        if([string]$unit.status-cne'active'-or[string]$state.current_unit-cne$unitId-or[string]$state.validation_checkpoint.result-cne'fail'-or@($intent.artifacts).Count-ne1-or@($Event.receipts).Count-ne1){throw 'Active retirement resolution requires the planning-resumed failed owner.'}
        $binding=$intent.artifacts[0];$receipt=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$binding.bytes_base64));Assert-ActiveRetirementSchema $receipt 'blocker-resolution-receipt-v1.schema.json'
        if([string]$receipt.result-cne'pass'-or[string]$receipt.unit_id-cne$unitId-or[string]$receipt.project_id-cne[string]$Event.project_id-or[string]$receipt.blocker.blocker_id-cne"$unitId-validation-fail"-or[string]$Event.receipts[0]-cne[string]$binding.path-or[string]$Event.summary-cne"Resolved blocker '$([string]$receipt.blocker.blocker_id)' from hash-bound passing evidence while preserving all other workflow projections."){throw 'Active retirement scope resolution receipt is detached.'}
        $matches=@($state.blockers|Where-Object blocker_id -CEQ $receipt.blocker.blocker_id);if($matches.Count-ne1){throw 'Active retirement scope resolution blocker is absent or duplicated.'};Assert-ActiveRetirementEqual $matches[0] $receipt.blocker 'resolution exact blocker'
        $state.blockers=@($state.blockers|Where-Object blocker_id -CNE $receipt.blocker.blocker_id);Assert-ActiveRetirementEqual @($state.blockers|ForEach-Object blocker_id|Sort-Object) @($receipt.preserve_blocker_ids|Sort-Object) 'resolution preserved blockers'
        foreach($evidence in @($receipt.evidence)){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace ([string]$evidence.path) -RequireLeaf))-cne[string]$evidence.sha256){throw 'Active retirement scope resolution evidence drifted.'}}
    }else{throw 'Active retirement retained lifecycle action is unsupported.'}
    if([string]$Event.event_id-cnotmatch'-validation-fail-'-and[string]$Event.event_type-cne'state-transition'){throw 'Active retirement retained lifecycle event type is invalid.'}
    $state.last_event_id=[string]$Event.event_id
    Assert-ActiveRetirementEqual $unit $targetUnit 'retained lifecycle exact target unit';Assert-ActiveRetirementEqual $state $targetState 'retained lifecycle exact target state'
    foreach($projection in @(if($intent.PSObject.Properties.Name-ccontains'additional_projections'){$intent.additional_projections})){
        if([string]$projection.path-cnotin@('project.spec.json','feature.lock.json')-or[string]$projection.pre_sha256-cne[string]$projection.target_sha256-or(Get-MorphospaceCanonicalJsonSha256 $projection.document)-cne[string]$projection.pre_sha256){throw 'Active retirement retained lifecycle changed product authority.'}
    }
}

function Assert-ActiveRetirementPostNonpassUpgradeSlot {
    param([string]$Workspace,[object]$Unit,[object]$State,[string]$UnitId)
    if([string]$Unit.unit_id-cne$UnitId-or[string]$Unit.status-cne'active'-or[string]$State.current_unit-cne$UnitId-or@($State.blockers).Count-ne0-or$null-ne$State.next_ready_unit-or[string]$State.validation_checkpoint.result-cne'fail'-or$Unit.PSObject.Properties.Name-cnotcontains'candidate_freeze'){throw 'Frozen tooling upgrade requires the exact failed, resumed, blocker-free active owner.'}
    $events=@(Get-Content -LiteralPath (Join-Path $Workspace 'iteration-events.jsonl')|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes($_))})
    $freeze=$Unit.candidate_freeze;$starts=@($events|Where-Object event_id -CEQ "$([string]$freeze.freeze_id)-recorded");$ends=@($events|Where-Object event_id -CEQ ([string]$State.last_event_id))
    if($starts.Count-ne1-or$ends.Count-ne1-or[string]$ends[0].event_id-cnotmatch('^'+[regex]::Escape($UnitId)+'-blocker-resolved-[0-9]{4,}$')){throw 'Frozen tooling upgrade lacks its original freeze and final scope-resolution events.'}
    $suffix=@($events|Where-Object{[int]$_.sequence-ge[int]$starts[0].sequence-and[int]$_.sequence-le[int]$ends[0].sequence})
    Assert-ActiveRetirementPlanningContinuationEvents $suffix ([int]$starts[0].sequence-1) $UnitId
    if($suffix.Count-ne5-or[string]$suffix[1].event_id-cnotmatch'-validating-[0-9]{4,}$'-or[string]$suffix[2].event_id-cnotmatch'-validation-fail-[0-9]{4,}$'-or[string]$suffix[3].event_id-cnotmatch'-resumed-[0-9]{4,}$'){throw 'Frozen tooling upgrade requires exactly Freeze, BeginValidation, fail, Resume and ResolveBlocker.'}
    foreach($event in $suffix){$proof=Get-ActiveRetirementPlanningTransition $Workspace "$([string]$event.event_id)-transition";Assert-ActiveRetirementRetainedLifecycle $Workspace $event $proof}
    Assert-ActiveRetirementEqual $Unit $proof.intent.target.unit.document 'post-nonpass upgrade original unit';Assert-ActiveRetirementEqual $State $proof.intent.target.state.document 'post-nonpass upgrade original state'
}
function Get-ActiveRetirementLifecycleDiagnostics {
    param([string]$Workspace,[string]$Repository,[string]$ObservedHead,[object]$Request,[object[]]$Events)
    if($null-eq$Request-or$Request.PSObject.Properties.Name-cnotcontains'retained_lifecycle_diagnostics'){return @()}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$seenEvents=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($binding in @($Request.retained_lifecycle_diagnostics)){
        if(-not$seen.Add([string]$binding.path)-or-not$seenEvents.Add([string]$binding.event_id)){throw 'Retained lifecycle diagnostic repeats a path or event.'}
        $reference=Get-ActiveRetirementReference $Workspace ([string]$binding.path);$receipt=Read-MorphospaceProtocolJson $reference.absolute;Assert-ActiveRetirementSchema $receipt 'work-unit-automation-receipt.schema.json'
        if((Get-MorphospaceFileSha256 $reference.absolute)-cne[string]$binding.raw_sha256-or(Get-MorphospaceCanonicalJsonSha256 $receipt)-cne[string]$binding.canonical_sha256){throw 'Retained lifecycle diagnostic raw/canonical bytes drifted.'}
        $matches=@($Events|Where-Object event_id -CEQ $binding.event_id);if($matches.Count-ne1-or[string]$matches[0].unit_id-cne[string]$Request.unit_id){throw 'Retained lifecycle diagnostic event is detached.'}
        $event=$matches[0];$proof=Get-ActiveRetirementPlanningTransition $Workspace "$([string]$event.event_id)-transition";Assert-ActiveRetirementRetainedLifecycle $Workspace $event $proof
        $prior=Get-ActiveRetirementPlanningTransition $Workspace "$([string]$proof.intent.expected.event_tail_id)-transition"
        $action=switch -Regex -CaseSensitive ([string]$event.event_id){'-validating-[0-9]{4,}$'{'BeginValidation'};'-validation-fail-[0-9]{4,}$'{'RecordValidation'};'-resumed-[0-9]{4,}$'{'Resume'};default{throw 'Retained lifecycle diagnostic action is unsupported.'}}
        $transition=switch -CaseSensitive ($action){'BeginValidation'{'active-to-validating'};'RecordValidation'{'validation-fail'};'Resume'{'blocked-to-active'}}
        if($receipt.executed-ne$true-or[string]$receipt.timestamp-cne[string]$event.timestamp-or[string]$receipt.schema-cne'rusty.morphospace.workflow.work_unit_automation_receipt.v1'-or[string]$receipt.action-cne$action-or[string]$receipt.transition-cne$transition-or[string]$receipt.event_id-cne[string]$event.event_id-or[string]$receipt.project_id-cne[string]$event.project_id-or[string]$receipt.unit_id-cne[string]$event.unit_id-or[string]$receipt.status_before-cne[string]$prior.intent.target.unit.document.status-or[string]$receipt.status_after-cne[string]$proof.intent.target.unit.document.status){throw 'Retained lifecycle diagnostic owner action/status is detached.'}
        Assert-ActiveRetirementEqual ([pscustomobject]@{value=$receipt.current_unit_before}) ([pscustomobject]@{value=$prior.intent.target.state.document.current_unit}) 'diagnostic previous owner';Assert-ActiveRetirementEqual ([pscustomobject]@{value=$receipt.current_unit_after}) ([pscustomobject]@{value=$proof.intent.target.state.document.current_unit}) 'diagnostic resulting owner'
        foreach($name in @('adoption_receipt','publication_closure','published_planning_authority_adoption','planned_publication','planning_suffix_rewrite_recovery','published_prerequisite_suffix_reconciliation','executed_prepared_publication_reconciliation','instruction_surface_completion','ready_withdrawal','proposed_retirement','terminal_validation_selection_release','push_plan')){if($receipt.PSObject.Properties.Name-ccontains$name-and$null-ne$receipt.$name){throw 'Retained lifecycle diagnostic contains unrelated authority payload.'}}
        $prefix=[IO.Path]::GetRelativePath($Repository,$Workspace).Replace('\','/').TrimEnd('/')+'/';$gitPath=$prefix+$reference.path
        $null=&git -C $Repository merge-base --is-ancestor ([string]$binding.introduced_commit) $ObservedHead 2>&1;if($LASTEXITCODE-ne0){throw 'Retained lifecycle diagnostic commit is outside observed history.'}
        $addition=@(&git -C $Repository diff-tree --no-commit-id --name-status -r ([string]$binding.introduced_commit) -- $gitPath 2>&1);if($LASTEXITCODE-ne0-or$addition.Count-ne1-or[string]$addition[0]-cne("A`t"+$gitPath)){throw 'Retained lifecycle diagnostic lacks exact original addition.'}
        foreach($revision in @([string]$binding.introduced_commit,$ObservedHead)){$blob=(@(&git -C $Repository rev-parse "$($revision):$gitPath" 2>&1)-join'').Trim();if($LASTEXITCODE-ne0-or$blob-cne[string]$binding.git_blob_sha1){throw 'Retained lifecycle diagnostic committed blob drifted.'}}
        $live=(@(&git -C $Repository hash-object --path=$gitPath -- $reference.absolute 2>&1)-join'').Trim();if($LASTEXITCODE-ne0-or$live-cne[string]$binding.git_blob_sha1){throw 'Retained lifecycle diagnostic live blob drifted.'}
        [pscustomobject]@{path=$reference.path;sha256=[string]$binding.raw_sha256}
    }
}

function Get-ActiveRetirementToolingProofBindings {
    param([string]$WorkspaceRoot,[object]$Request,[object]$Context)
    $bindings=@{};$documents=@{}
    foreach($binding in @($Request.compatibility_receipt,$Context.executor.publication_evidence,$Context.compatibility.receipt)){
        $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$binding.path)
        $hash=[string]$binding.sha256
        if($bindings.ContainsKey($relative)-and[string]$bindings[$relative]-cne$hash){throw "Active retirement tooling proof '$relative' has conflicting bindings."}
        $path=Resolve-MorphospaceWorkspacePath $WorkspaceRoot $relative -RequireLeaf
        if((Get-MorphospaceFileSha256 $path)-cne$hash){throw "Active retirement tooling proof '$relative' differs from its authenticated binding."}
        $bindings[$relative]=$hash;$documents[$relative]=Read-MorphospaceProtocolJson $path
    }
    $compatibility=$documents[[string]$Request.compatibility_receipt.path]
    $publication=$documents[[string]$Context.executor.publication_evidence.path]
    $protocol=$documents[[string]$Context.compatibility.receipt.path]
    foreach($binding in @($compatibility.validation.evidence,$publication.validation,$protocol.validation)){
        $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$binding.path)
        $hash=[string]$binding.sha256
        if($bindings.ContainsKey($relative)-and[string]$bindings[$relative]-cne$hash){throw "Active retirement tooling proof '$relative' has conflicting bindings."}
        $path=Resolve-MorphospaceWorkspacePath $WorkspaceRoot $relative -RequireLeaf
        if((Get-MorphospaceFileSha256 $path)-cne$hash){throw "Active retirement tooling proof '$relative' differs from its authenticated binding."}
        $bindings[$relative]=$hash
    }
    @($bindings.Keys|Sort-Object -CaseSensitive|ForEach-Object{[pscustomobject]@{path=$_;sha256=[string]$bindings[$_]}})
}
function Get-ActiveRetirementClaimDiagnosticProjection {
    param([string]$Workspace,[object]$Request,[string]$Repository,[string]$ObservedHead)
    if($null-eq$Request-or$Request.PSObject.Properties.Name-cnotcontains'retained_claim_diagnostic'){return $null}
    Assert-ActiveRetirementSchema $Request 'active-unit-retirement-v1.schema.json'
    $binding=$Request.retained_claim_diagnostic
    $reference=Get-ActiveRetirementReference $Workspace ([string]$binding.path)
    if($reference.path-cnotmatch '^receipts/[a-z0-9][a-z0-9-]{1,79}-claim(?:-[0-9]{8})?\.json$'){throw 'Retained Claim diagnostic path is outside the closed diagnostic namespace.'}
    if(([IO.FileInfo]$reference.absolute).Length-gt131072){throw 'Retained Claim diagnostic exceeds its byte bound.'}
    $bytes=[IO.File]::ReadAllBytes($reference.absolute)
    if($bytes.Length-gt131072-or(Get-MorphospaceSha256Bytes $bytes)-cne[string]$binding.raw_sha256){throw 'Retained Claim diagnostic raw CAS drifted.'}
    $diagnostic=ConvertFrom-MorphospaceProtocolJsonBytes $bytes
    Assert-ActiveRetirementSchema $diagnostic 'work-unit-automation-receipt.schema.json'
    if((Get-MorphospaceCanonicalJsonSha256 $diagnostic)-cne[string]$binding.canonical_sha256){throw 'Retained Claim diagnostic canonical CAS drifted.'}
    $proof=Get-ActiveRetirementPlanningTransition $Workspace ([string]$Request.claim.transaction_id) -HistoricalProjection
    $intent=$proof.intent;$event=$intent.event;$unit=$intent.target.unit.document
    Assert-ActiveRetirementEqual $Request.claim (Get-ActiveRetirementClaim $Workspace $Request (Get-ActiveRetirementEvents $Workspace).events) 'diagnostic committed Claim'
    if(@($intent.artifacts).Count-ne0-or@($event.receipts).Count-ne0){throw 'Retained Claim diagnostic must not replace an original ledger artifact.'}
    if([string]$diagnostic.schema-cne'rusty.morphospace.workflow.work_unit_automation_receipt.v1'-or[string]$diagnostic.action-cne'Claim'-or$diagnostic.executed-ne$true-or[string]$diagnostic.transition-cne'ready-to-active'-or[string]$diagnostic.status_before-cne'ready'-or[string]$diagnostic.status_after-cne'active'-or$null-ne$diagnostic.current_unit_before-or[string]$diagnostic.current_unit_after-cne[string]$Request.unit_id-or[string]$diagnostic.project_id-cne[string]$Request.project_id-or[string]$diagnostic.unit_id-cne[string]$Request.unit_id-or[string]$diagnostic.event_id-cne[string]$Request.claim.event_id-or[string]$diagnostic.timestamp-cne[string]$event.timestamp-or[string]$unit.status-cne'active'-or[string]$event.event_type-cne'state-transition') {throw 'Retained Claim diagnostic producer semantics are detached.'}
    if([string]$event.project_id-cne[string]$Request.project_id-or[string]$unit.unit_id-cne[string]$Request.unit_id){throw 'Retained Claim diagnostic original owner identity drifted.'}
    $preState=Copy-ActiveRetirementValue $intent.target.state.document;$preState.current_unit=$null;$preState.next_ready_unit=[string]$Request.unit_id;$preState.last_event_id=[string]$intent.expected.event_tail_id
    if((Get-MorphospaceCanonicalJsonSha256 $preState)-cne[string]$intent.pre.state.sha256){throw 'Retained Claim diagnostic original idle-to-owned state is malformed.'}
    $preUnit=Copy-ActiveRetirementValue $unit;$preUnit.status='ready'
    if((Get-MorphospaceCanonicalJsonSha256 $preUnit)-cne[string]$intent.pre.unit.sha256){throw 'Retained Claim diagnostic original transition is malformed.'}
    foreach($name in @('adoption_receipt','publication_closure','published_planning_authority_adoption','planned_publication','planning_suffix_rewrite_recovery','published_prerequisite_suffix_reconciliation','executed_prepared_publication_reconciliation','instruction_surface_completion','ready_withdrawal','proposed_retirement','terminal_validation_selection_release','push_plan')){if($diagnostic.PSObject.Properties.Name-ccontains$name-and$null-ne$diagnostic.$name){throw 'Retained Claim diagnostic contains a non-Claim authority payload.'}}
    $originalContext=if($unit.PSObject.Properties.Name-ccontains'tooling_context'){$unit.tooling_context}else{$null}
    if($null-eq$originalContext){if($null-ne$binding.tooling_context){throw 'Retained Claim diagnostic original context is absent.'}}else{Assert-ActiveRetirementEqual $binding.tooling_context $originalContext 'original Claim diagnostic context'}
    if($null-ne$originalContext){
        $contextPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$originalContext.path) -RequireLeaf
        $context=Read-MorphospaceProtocolJson $contextPath
        if((Get-MorphospaceFileSha256 $contextPath)-cne[string]$originalContext.sha256-or(Get-MorphospaceCanonicalJsonSha256 $context)-cne[string]$originalContext.canonical_sha256){throw 'Retained Claim diagnostic original context bytes drifted.'}
        Assert-ActiveRetirementSchema $context 'tooling-context-v1.schema.json'
    }
    # Derive only declaration-shaped producer fields. Historical disk/tool/lease
    # observations remain unused diagnostic data; they authorize no gate today.
    $matrixModule=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru
    $deviceRows=@($diagnostic.validation_matrix|Where-Object{[string]$_.gate_id-ceq'device-validation'})
    $serials=if($deviceRows.Count-eq1-and$deviceRows[0].PSObject.Properties.Name-ccontains'serials'){@($deviceRows[0].serials)}else{@()}
    $matrix=@(&$matrixModule {param($u,$s)New-MorphospaceValidationMatrix -Unit $u -DeviceSerials $s} $unit $serials)
    Assert-ActiveRetirementEqual $matrix @($diagnostic.validation_matrix) 'diagnostic declared validation matrix'
    Assert-ActiveRetirementEqual $matrix @($diagnostic.claim_preflight.validation_matrix) 'diagnostic preflight matrix'
    $repos=@($unit.allowed_repositories|Sort-Object repo_id|ForEach-Object{[pscustomobject][ordered]@{repo_id=[string]$_.repo_id;allowed_paths=@($_.allowed_paths|ForEach-Object{([string]$_ -replace '\\','/')}|Sort-Object -Unique)}})
    $dependencies=@($unit.read_only_dependencies|ForEach-Object{[pscustomobject][ordered]@{repo_id=[string]$_.repo_id;paths=@($_.paths|ForEach-Object{([string]$_ -replace '\\','/')}|Sort-Object -Unique);purpose=[string]$_.purpose;verification=[string]$_.verification}}|Sort-Object repo_id)
    $scope=[pscustomobject][ordered]@{change_categories=@($unit.change_categories|Sort-Object -Unique);repositories=$repos;read_only_dependencies=$dependencies;exclusion='Do not scan repositories or paths outside this list.'}
    Assert-ActiveRetirementEqual $scope $diagnostic.graph_scope 'diagnostic declared graph scope'
    if($diagnostic.claim_preflight.ready_to_claim-ne$true-or$diagnostic.claim_preflight.requirements_declared-ne($unit.PSObject.Properties.Name-ccontains'claim_requirements')-or@($diagnostic.claim_preflight.issues).Count-ne0){throw 'Retained Claim diagnostic preflight contradicts executed Claim.'}
    $workspaceRelative=[IO.Path]::GetRelativePath($Repository,$Workspace).Replace('\','/').TrimEnd('/')
    $prefix=if($workspaceRelative-ceq'.'){''}else{$workspaceRelative+'/'}
    $gitPath=$prefix+$reference.path
    $introduced=[string]$binding.introduced_commit
    $null=&git -C $Repository merge-base --is-ancestor $introduced $ObservedHead 2>&1
    if($LASTEXITCODE-ne0){throw 'Retained Claim diagnostic commit is outside observed history.'}
    $introduction=@(&git -C $Repository diff-tree --no-commit-id --name-status -r $introduced -- $gitPath 2>&1)
    if($LASTEXITCODE-ne0-or$introduction.Count-ne1-or[string]$introduction[0]-cne("A`t"+$gitPath)){throw 'Retained Claim diagnostic must bind its original committed addition.'}
    foreach($revision in @($introduced,$ObservedHead)){
        $blob=(@(&git -C $Repository rev-parse "$($revision):$gitPath" 2>&1)-join'').Trim()
        if($LASTEXITCODE-ne0-or$blob-cne[string]$binding.git_blob_sha1){throw 'Retained Claim diagnostic committed blob CAS drifted.'}
    }
    $liveBlob=(@(&git -C $Repository hash-object --path=$gitPath -- $reference.absolute 2>&1)-join'').Trim()
    if($LASTEXITCODE-ne0-or$liveBlob-cne[string]$binding.git_blob_sha1){throw 'Retained Claim diagnostic live blob differs from committed bytes.'}
    $blobSize=(@(&git -C $Repository cat-file -s ([string]$binding.git_blob_sha1) 2>&1)-join'').Trim()
    if($LASTEXITCODE-ne0-or$blobSize-cnotmatch'^[0-9]{1,6}$'-or[long]$blobSize-gt131072){throw 'Retained Claim diagnostic committed blob exceeds its byte bound.'}
    $start=[Diagnostics.ProcessStartInfo]::new('git');$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-C',$Repository,'cat-file','blob',[string]$binding.git_blob_sha1)){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start);$errorTask=$process.StandardError.ReadToEndAsync();$stream=[IO.MemoryStream]::new()
    try{$process.StandardOutput.BaseStream.CopyTo($stream);$process.WaitForExit();$errorText=$errorTask.GetAwaiter().GetResult();if($process.ExitCode-ne0){throw 'Retained Claim diagnostic committed blob is unavailable.'};$blobBytes=$stream.ToArray()}finally{$stream.Dispose();$process.Dispose()}
    if($blobBytes.Length-gt131072-or(Get-MorphospaceSha256Bytes $blobBytes)-cne[string]$binding.git_blob_sha256){throw 'Retained Claim diagnostic committed raw blob CAS drifted.'}
    Assert-ActiveRetirementEqual $diagnostic (ConvertFrom-MorphospaceProtocolJsonBytes $blobBytes) 'complete committed Claim diagnostic'
    foreach($relative in @("receipts/transactions/$($Request.claim.transaction_id).intent.json","receipts/transactions/$($Request.claim.transaction_id).completion.json")+@($(if($originalContext){[string]$originalContext.path}else{@()}))){
        $live=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf
        $expectedBlob=(@(&git -C $Repository hash-object --path=$prefix$relative -- $live 2>&1)-join'').Trim()
        $originalBlob=(@(&git -C $Repository rev-parse "$($introduced):$prefix$relative" 2>&1)-join'').Trim()
        if($LASTEXITCODE-ne0-or$originalBlob-cne$expectedBlob){throw 'Retained Claim diagnostic committed original Claim/context join drifted.'}
    }
    # Retention only: never add to the original event/intent, gate selection,
    # validation checkpoint, acceptance, prerequisite or publication evidence.
    [pscustomobject]@{path=$reference.path;sha256=[string]$binding.raw_sha256}
}

function Get-ActiveRetirementReadyDiagnosticProjection {
    param([string]$Workspace,[object]$Request,[string]$Repository,[string]$ObservedHead)
    if($null-eq$Request-or$Request.PSObject.Properties.Name-cnotcontains'retained_ready_diagnostic'){return $null}
    Assert-ActiveRetirementSchema $Request 'active-unit-retirement-v1.schema.json'
    $binding=$Request.retained_ready_diagnostic
    $reference=Get-ActiveRetirementReference $Workspace ([string]$binding.path)
    if($reference.path-cnotmatch '^receipts/[a-z0-9][a-z0-9-]{1,79}-ready(?:-[0-9]{8})?\.json$'){throw 'Retained Ready diagnostic path is outside the closed diagnostic namespace.'}
    if(([IO.FileInfo]$reference.absolute).Length-gt131072){throw 'Retained Ready diagnostic exceeds its byte bound.'}
    $bytes=[IO.File]::ReadAllBytes($reference.absolute)
    if($bytes.Length-gt131072-or(Get-MorphospaceSha256Bytes $bytes)-cne[string]$binding.raw_sha256){throw 'Retained Ready diagnostic raw CAS drifted.'}
    $diagnostic=ConvertFrom-MorphospaceProtocolJsonBytes $bytes
    Assert-ActiveRetirementSchema $diagnostic 'work-unit-automation-receipt.schema.json'
    if((Get-MorphospaceCanonicalJsonSha256 $diagnostic)-cne[string]$binding.canonical_sha256){throw 'Retained Ready diagnostic canonical CAS drifted.'}
    $proof=Get-ActiveRetirementPlanningTransition $Workspace ([string]$binding.transaction_id) -HistoricalProjection
    $intent=$proof.intent;$event=$intent.event;$unit=$intent.target.unit.document
    if([string]$binding.transaction_id-cne"$($binding.event_id)-transition"-or[string]$binding.event_id-cnotmatch('^'+[regex]::Escape([string]$Request.unit_id)+'-ready-[0-9]{4,}$')-or[string]$event.event_id-cne[string]$binding.event_id){throw 'Retained Ready diagnostic transaction identity is detached.'}
    foreach($pair in @(@('intent',$binding.intent_sha256),@('completion',$binding.completion_sha256))){$path=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($binding.transaction_id).$($pair[0]).json" -RequireLeaf;if((Get-MorphospaceFileSha256 $path)-cne[string]$pair[1]){throw 'Retained Ready diagnostic transaction CAS drifted.'}}
    Assert-ActiveRetirementEqual $Request.claim (Get-ActiveRetirementClaim $Workspace $Request (Get-ActiveRetirementEvents $Workspace).events) 'diagnostic subsequent committed Claim'
    $claimProof=Get-ActiveRetirementPlanningTransition $Workspace ([string]$Request.claim.transaction_id) -HistoricalProjection
    if([string]$claimProof.intent.expected.event_tail_id-cne[string]$binding.event_id-or[string]$claimProof.intent.pre.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $unit)-or[string]$claimProof.intent.pre.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document)-or[int]$claimProof.intent.event.sequence-ne([int]$event.sequence+1)){throw 'Retained Ready diagnostic does not join the original immediate Claim preimage.'}
    if(@($intent.artifacts).Count-ne0-or@($event.receipts).Count-ne0){throw 'Retained Ready diagnostic must not replace an original ledger artifact.'}
    if([string]$diagnostic.schema-cne'rusty.morphospace.workflow.work_unit_automation_receipt.v1'-or[string]$diagnostic.action-cne'Ready'-or$diagnostic.executed-ne$true-or[string]$diagnostic.transition-cne'proposed-to-ready'-or[string]$diagnostic.status_before-cne'proposed'-or[string]$diagnostic.status_after-cne'ready'-or$null-ne$diagnostic.current_unit_before-or$null-ne$diagnostic.current_unit_after-or[string]$diagnostic.project_id-cne[string]$Request.project_id-or[string]$diagnostic.unit_id-cne[string]$Request.unit_id-or[string]$diagnostic.event_id-cne[string]$binding.event_id-or[string]$diagnostic.timestamp-cne[string]$event.timestamp-or[string]$unit.status-cne'ready'-or[string]$event.event_type-cne'state-transition') {throw 'Retained Ready diagnostic producer semantics are detached.'}
    if([string]$event.project_id-cne[string]$Request.project_id-or[string]$event.unit_id-cne[string]$Request.unit_id-or[string]$unit.unit_id-cne[string]$Request.unit_id-or[string]$unit.project_id-cne[string]$Request.project_id){throw 'Retained Ready diagnostic original owner identity drifted.'}
    if($null-ne$intent.target.state.document.current_unit-or[string]$intent.target.state.document.next_ready_unit-cne[string]$Request.unit_id){throw 'Retained Ready diagnostic original ready queue is malformed.'}
    $predecessorId=[string]$intent.expected.event_tail_id;$predecessorTransaction="$predecessorId-transition"
    $predecessor=Get-ActiveRetirementPlanningTransition $Workspace $predecessorTransaction -HistoricalProjection
    if([string]$predecessor.intent.event.event_id-cne$predecessorId-or[string]$predecessor.intent.event.project_id-cne[string]$Request.project_id-or[string]$predecessor.intent.event.unit_id-cne[string]$Request.unit_id-or[int]$predecessor.intent.event.sequence-ne([int]$event.sequence-1)-or(Get-MorphospaceCanonicalJsonSha256 $predecessor.intent.target.state.document)-cne[string]$intent.pre.state.sha256){throw 'Retained Ready diagnostic original predecessor is detached.'}
    $preState=Copy-ActiveRetirementValue $intent.target.state.document;$preState.current_unit=$null;$preState.next_ready_unit=$null;$preState.last_event_id=[string]$intent.expected.event_tail_id
    # Ready refreshes recorded repository heads. Preserve its authenticated
    # historical preimage; never replay present observations or grant credit.
    $preState.repository_heads=@($predecessor.intent.target.state.document.repository_heads|ForEach-Object{Copy-ActiveRetirementValue $_})
    if((Get-MorphospaceCanonicalJsonSha256 $preState)-cne[string]$intent.pre.state.sha256){throw 'Retained Ready diagnostic original idle-to-owned state is malformed.'}
    $preUnit=Copy-ActiveRetirementValue $unit;$preUnit.status='proposed'
    if((Get-MorphospaceCanonicalJsonSha256 $preUnit)-cne[string]$intent.pre.unit.sha256){throw 'Retained Ready diagnostic original transition is malformed.'}
    foreach($name in @('adoption_receipt','publication_closure','published_planning_authority_adoption','planned_publication','planning_suffix_rewrite_recovery','published_prerequisite_suffix_reconciliation','executed_prepared_publication_reconciliation','instruction_surface_completion','ready_withdrawal','proposed_retirement','terminal_validation_selection_release','push_plan')){if($diagnostic.PSObject.Properties.Name-ccontains$name-and$null-ne$diagnostic.$name){throw 'Retained Ready diagnostic contains a non-Ready authority payload.'}}
    $originalContext=if($unit.PSObject.Properties.Name-ccontains'tooling_context'){$unit.tooling_context}else{$null}
    if($null-eq$originalContext){if($null-ne$binding.tooling_context){throw 'Retained Ready diagnostic original context is absent.'}}else{Assert-ActiveRetirementEqual $binding.tooling_context $originalContext 'original Ready diagnostic context'}
    if($null-ne$originalContext){
        $contextPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$originalContext.path) -RequireLeaf
        $context=Read-MorphospaceProtocolJson $contextPath
        if((Get-MorphospaceFileSha256 $contextPath)-cne[string]$originalContext.sha256-or(Get-MorphospaceCanonicalJsonSha256 $context)-cne[string]$originalContext.canonical_sha256){throw 'Retained Ready diagnostic original context bytes drifted.'}
        Assert-ActiveRetirementSchema $context 'tooling-context-v1.schema.json'
    }
    # Derive only declaration-shaped producer fields. Historical disk/tool/lease
    # observations remain unused diagnostic data; they authorize no gate today.
    $matrixModule=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru
    $deviceRows=@($diagnostic.validation_matrix|Where-Object{[string]$_.gate_id-ceq'device-validation'})
    $serials=if($deviceRows.Count-eq1-and$deviceRows[0].PSObject.Properties.Name-ccontains'serials'){@($deviceRows[0].serials)}else{@()}
    $matrix=@(&$matrixModule {param($u,$s)New-MorphospaceValidationMatrix -Unit $u -DeviceSerials $s} $unit $serials)
    Assert-ActiveRetirementEqual $matrix @($diagnostic.validation_matrix) 'diagnostic declared validation matrix'
    Assert-ActiveRetirementEqual $matrix @($diagnostic.claim_preflight.validation_matrix) 'diagnostic preflight matrix'
    $repos=@($unit.allowed_repositories|Sort-Object repo_id|ForEach-Object{[pscustomobject][ordered]@{repo_id=[string]$_.repo_id;allowed_paths=@($_.allowed_paths|ForEach-Object{([string]$_ -replace '\\','/')}|Sort-Object -Unique)}})
    $dependencies=@($unit.read_only_dependencies|ForEach-Object{[pscustomobject][ordered]@{repo_id=[string]$_.repo_id;paths=@($_.paths|ForEach-Object{([string]$_ -replace '\\','/')}|Sort-Object -Unique);purpose=[string]$_.purpose;verification=[string]$_.verification}}|Sort-Object repo_id)
    $scope=[pscustomobject][ordered]@{change_categories=@($unit.change_categories|Sort-Object -Unique);repositories=$repos;read_only_dependencies=$dependencies;exclusion='Do not scan repositories or paths outside this list.'}
    Assert-ActiveRetirementEqual $scope $diagnostic.graph_scope 'diagnostic declared graph scope'
    if($diagnostic.claim_preflight.ready_to_claim-ne$true-or$diagnostic.claim_preflight.requirements_declared-ne($unit.PSObject.Properties.Name-ccontains'claim_requirements')-or@($diagnostic.claim_preflight.issues).Count-ne0){throw 'Retained Ready diagnostic preflight contradicts executed Ready.'}
    $workspaceRelative=[IO.Path]::GetRelativePath($Repository,$Workspace).Replace('\','/').TrimEnd('/')
    $prefix=if($workspaceRelative-ceq'.'){''}else{$workspaceRelative+'/'}
    $gitPath=$prefix+$reference.path
    $introduced=[string]$binding.introduced_commit
    $null=&git -C $Repository merge-base --is-ancestor $introduced $ObservedHead 2>&1
    if($LASTEXITCODE-ne0){throw 'Retained Ready diagnostic commit is outside observed history.'}
    $introduction=@(&git -C $Repository diff-tree --no-commit-id --name-status -r $introduced -- $gitPath 2>&1)
    if($LASTEXITCODE-ne0-or$introduction.Count-ne1-or[string]$introduction[0]-cne("A`t"+$gitPath)){throw 'Retained Ready diagnostic must bind its original committed addition.'}
    foreach($revision in @($introduced,$ObservedHead)){
        $blob=(@(&git -C $Repository rev-parse "$($revision):$gitPath" 2>&1)-join'').Trim()
        if($LASTEXITCODE-ne0-or$blob-cne[string]$binding.git_blob_sha1){throw 'Retained Ready diagnostic committed blob CAS drifted.'}
    }
    $liveBlob=(@(&git -C $Repository hash-object --path=$gitPath -- $reference.absolute 2>&1)-join'').Trim()
    if($LASTEXITCODE-ne0-or$liveBlob-cne[string]$binding.git_blob_sha1){throw 'Retained Ready diagnostic live blob differs from committed bytes.'}
    $blobSize=(@(&git -C $Repository cat-file -s ([string]$binding.git_blob_sha1) 2>&1)-join'').Trim()
    if($LASTEXITCODE-ne0-or$blobSize-cnotmatch'^[0-9]{1,6}$'-or[long]$blobSize-gt131072){throw 'Retained Ready diagnostic committed blob exceeds its byte bound.'}
    $start=[Diagnostics.ProcessStartInfo]::new('git');$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-C',$Repository,'cat-file','blob',[string]$binding.git_blob_sha1)){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start);$errorTask=$process.StandardError.ReadToEndAsync();$stream=[IO.MemoryStream]::new()
    try{$process.StandardOutput.BaseStream.CopyTo($stream);$process.WaitForExit();$errorText=$errorTask.GetAwaiter().GetResult();if($process.ExitCode-ne0){throw 'Retained Ready diagnostic committed blob is unavailable.'};$blobBytes=$stream.ToArray()}finally{$stream.Dispose();$process.Dispose()}
    if($blobBytes.Length-gt131072-or(Get-MorphospaceSha256Bytes $blobBytes)-cne[string]$binding.git_blob_sha256){throw 'Retained Ready diagnostic committed raw blob CAS drifted.'}
    Assert-ActiveRetirementEqual $diagnostic (ConvertFrom-MorphospaceProtocolJsonBytes $blobBytes) 'complete committed Ready diagnostic'
    foreach($relative in @("receipts/transactions/$($binding.transaction_id).intent.json","receipts/transactions/$($binding.transaction_id).completion.json","receipts/transactions/$predecessorTransaction.intent.json","receipts/transactions/$predecessorTransaction.completion.json")+@($(if($originalContext){[string]$originalContext.path}else{@()}))){
        $live=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf
        $expectedBlob=(@(&git -C $Repository hash-object --path=$prefix$relative -- $live 2>&1)-join'').Trim()
        $originalBlob=(@(&git -C $Repository rev-parse "$($introduced):$prefix$relative" 2>&1)-join'').Trim()
        if($LASTEXITCODE-ne0-or$originalBlob-cne$expectedBlob){throw 'Retained Ready diagnostic committed original Ready/context join drifted.'}
    }
    # Retention only: never add to the original event/intent, gate selection,
    # validation checkpoint, acceptance, prerequisite or publication evidence.
    [pscustomobject]@{path=$reference.path;sha256=[string]$binding.raw_sha256}
}

function Test-ActiveRetirementPlanningProjectionFromAuthenticatedAdmission {
    param([string]$Workspace,[object]$Unit,[object]$RepositoryEntry,[string[]]$StatusPorcelain,[Parameter(Mandatory)][object]$Admission,[object]$RecoveryIntent=$null,[string]$LockedCommit='',[string]$ObservedHead='',[object]$Request=$null)
    if([string]$RepositoryEntry.role-cne'planning'){return $false}
    $committed=[bool]$LockedCommit
    if($committed-and($RecoveryIntent-or$StatusPorcelain.Count-ne0-or$ObservedHead-cnotmatch'^[0-9a-f]{40}$')){throw 'Active retirement committed planning descendant requires a clean exact HEAD without recovery.'}
    if([string]::IsNullOrWhiteSpace($Workspace)){throw 'Active retirement planning lifecycle workspace path is empty.'};if([string]::IsNullOrWhiteSpace([string]$RepositoryEntry.path)){throw 'Active retirement planning lifecycle repository path is empty.'}
    if($null-eq$RecoveryIntent-and@($StatusPorcelain|Where-Object{[string]$_-cmatch'retire-.*-active-retired-transition'}).Count-ne0){throw 'Active retirement planning lifecycle recovery intent was not forwarded.'}
    $repository=[IO.Path]::GetFullPath([string]$RepositoryEntry.path).TrimEnd('\','/');$workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $repositoryPrefix=$repository+[IO.Path]::DirectorySeparatorChar;$pathComparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$workspaceFull.StartsWith($repositoryPrefix,$pathComparison)){return $false}
    $workspacePrefix=[IO.Path]::GetRelativePath($repository,$workspaceFull).Replace('\','/').TrimEnd('/')+'/'
    $admission=$Admission
    $eventObservation=Get-ActiveRetirementEvents $workspaceFull;$events=$eventObservation.events
    if($RecoveryIntent){
        $tailMatches=@($events|Where-Object{[string]$_.event_id-ceq[string]$RecoveryIntent.expected.event_tail_id})
        if($tailMatches.Count-ne1){throw 'Active retirement recovery planning prefix tail is ambiguous.'}
        $prefixLength=[long]$RecoveryIntent.expected.events_length;$bytes=[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath $workspaceFull 'iteration-events.jsonl' -RequireLeaf))
        if($prefixLength-lt1-or$prefixLength-gt$bytes.LongLength){throw 'Active retirement recovery planning prefix length is invalid.'};$prefix=[byte[]]::new($prefixLength);[Array]::Copy($bytes,$prefix,$prefixLength)
        if((Get-MorphospaceSha256Bytes $prefix)-cne[string]$RecoveryIntent.expected.events_sha256){throw 'Active retirement recovery planning prefix bytes changed.'}
        $events=@($events|Where-Object{[int]$_.sequence-le[int]$tailMatches[0].sequence})
    }
    $preparedId="$([string]$admission.preparation.preparation_id)-prepared";$admittedId="$([string]$admission.admission_id)-admitted"
    $prepared=@($events|Where-Object{[string]$_.event_id-ceq$preparedId});$admitted=@($events|Where-Object{[string]$_.event_id-ceq$admittedId});$claimed=@($events|Where-Object{[string]$_.unit_id-ceq[string]$Unit.unit_id-and[string]$_.event_id-cmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-claimed-[0-9]{4}$')})
    if($prepared.Count-ne1-or$admitted.Count-ne1-or$claimed.Count-ne1){throw 'Active retirement planning lifecycle event identities are ambiguous.'}
    $from=[int]$prepared[0].sequence;$to=[int]$claimed[0].sequence;$suffix=@($events|Where-Object{[int]$_.sequence-ge$from-and[int]$_.sequence-le$to}|Sort-Object sequence)
    $direct=$suffix.Count-eq4-and[string]$suffix[0].event_id-ceq$preparedId-and[string]$suffix[1].event_id-ceq$admittedId-and[string]$suffix[2].event_id-cmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-ready-[0-9]{4}$')-and[string]$suffix[3].event_id-ceq[string]$claimed[0].event_id
    $replacement=$suffix.Count-eq6-and[string]$suffix[0].event_id-ceq$preparedId-and[string]$suffix[1].event_id-cmatch'-admitted$'-and[string]$suffix[2].event_id-cmatch'-proposal-retired-[0-9]{4}$'-and[string]$suffix[3].event_id-ceq$admittedId-and[string]$suffix[4].event_id-cmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-ready-[0-9]{4}$')-and[string]$suffix[5].event_id-ceq[string]$claimed[0].event_id
    if(-not$direct-and-not$replacement){throw 'Active retirement planning lifecycle suffix is unsupported.'}
    for($index=0;$index-lt$suffix.Count;$index++){if([int]$suffix[$index].sequence-ne($from+$index)){throw 'Active retirement planning lifecycle suffix is not contiguous.'}}
    $amendments=@($events|Where-Object{[int]$_.sequence-gt$to}|Sort-Object sequence)
    $amendmentModule=$null
    if($amendments.Count-ne0){
        $amendmentModule=Import-Module (Join-Path $PSScriptRoot 'ActiveWriteScopeAmendment.psm1') -Force -PassThru
        Restore-ActiveRetirementCallerModules
        Assert-ActiveRetirementPlanningContinuationEvents -Events $amendments -AfterSequence $to -UnitId ([string]$Unit.unit_id)
    }
    $projectionSuffix=@($suffix)+@($amendments)
    $expected=@{};$recoveryOwned=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if($RecoveryIntent){foreach($relative in @([string]$RecoveryIntent.state.path,[string]$RecoveryIntent.events.path,"receipts/transactions/$($RecoveryIntent.transaction_id).intent.json","receipts/transactions/$($RecoveryIntent.transaction_id).completion.json")+@($RecoveryIntent.artifacts|ForEach-Object{[string]$_.path})){[void]$recoveryOwned.Add($relative)};for($artifactIndex=0;$artifactIndex-lt@($RecoveryIntent.artifacts).Count;$artifactIndex++){[void]$recoveryOwned.Add("receipts/transactions/$($RecoveryIntent.transaction_id).artifact-$artifactIndex.pending")}}
    function Set-PlanningProjection([string]$Relative,[string]$Sha){$relative=ConvertTo-MorphospaceProtocolRelativePath $Relative;if(-not$recoveryOwned.Contains($relative)){$expected[$workspacePrefix+$relative]=$Sha}}
    $preparationTransactionId="$preparedId-transition";$preparationIntentRelative="receipts/transactions/$preparationTransactionId.intent.json";$preparationCompletionRelative="receipts/transactions/$preparationTransactionId.completion.json"
    $preparationIntentPath=Resolve-MorphospaceWorkspacePath $workspaceFull $preparationIntentRelative -RequireLeaf;$preparationCompletionPath=Resolve-MorphospaceWorkspacePath $workspaceFull $preparationCompletionRelative -RequireLeaf
    $preparationIntent=Read-MorphospaceProtocolJson $preparationIntentPath;$preparationCompletion=Read-MorphospaceProtocolJson $preparationCompletionPath
    if([string]$preparationIntent.transaction_id-cne$preparationTransactionId-or[string]$preparationIntent.event.event_id-cne$preparedId-or[string]$preparationCompletion.transaction_id-cne$preparationTransactionId-or[string]$preparationCompletion.intent_sha256-cne(Get-MorphospaceFileSha256 $preparationIntentPath)-or[string]$preparationCompletion.event_id-cne$preparedId-or[string]$preparationCompletion.status-cne'committed'){throw 'Active retirement planning preparation transaction is detached.'}
    if((Get-MorphospaceFileSha256 $preparationIntentPath)-cne(Get-ActiveRetirementCanonicalRawSha256 $preparationIntent)-or(Get-MorphospaceFileSha256 $preparationCompletionPath)-cne(Get-ActiveRetirementCanonicalRawSha256 $preparationCompletion)){throw 'Active retirement planning preparation transaction bytes are non-canonical.'}
    if(@(Get-ChildItem -LiteralPath (Split-Path $preparationIntentPath -Parent) -File -Filter "$preparationTransactionId.artifact-*.pending").Count-ne0){throw 'Active retirement planning lifecycle contains an orphan preparation pending artifact.'}
    foreach($name in @('project','state','feature_lock')){$projection=$preparationIntent.target.$name;Set-PlanningProjection ([string]$projection.path) (Get-ActiveRetirementCanonicalRawSha256 $projection.document)}
    foreach($artifact in @($preparationIntent.artifacts)){$artifactBytes=[Convert]::FromBase64String([string]$artifact.bytes_base64);Set-PlanningProjection ([string]$artifact.path) (Get-MorphospaceSha256Bytes $artifactBytes)}
    Set-PlanningProjection $preparationIntentRelative (Get-MorphospaceFileSha256 $preparationIntentPath);Set-PlanningProjection $preparationCompletionRelative (Get-MorphospaceFileSha256 $preparationCompletionPath)
    foreach($event in @($projectionSuffix|Select-Object -Skip 1)){
        $transactionId="$([string]$event.event_id)-transition";$proof=Get-ActiveRetirementPlanningTransition -Workspace $workspaceFull -TransactionId $transactionId -HistoricalProjection:($null-ne$RecoveryIntent)
        if((Get-MorphospaceCanonicalJsonSha256 $proof.intent.event)-cne(Get-MorphospaceCanonicalJsonSha256 $event)){throw 'Active retirement planning lifecycle event is detached from its transaction.'}
        if([int]$event.sequence-gt$to){
            $artifactSchemas=@($proof.intent.artifacts|ForEach-Object{[string](ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))).schema})
            if($artifactSchemas-ccontains'rusty.morphospace.workflow.active_development_envelope_extension.v1'){
                $extensionModule=Import-Module (Join-Path $PSScriptRoot 'ActiveDevelopmentEnvelopeExtension.psm1') -PassThru
                $null=&$extensionModule {param($root,$expected,$transition) Assert-ActiveEnvelopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $expected -Transition $transition} $workspaceFull $event $proof
            }elseif($artifactSchemas-ccontains'rusty.morphospace.workflow.tooling_context_upgrade.v1'){
                $toolingModule=Import-Module (Join-Path $PSScriptRoot 'ToolingContextUpgrade.psm1') -PassThru
                $null=&$toolingModule {param($root,$expected,$transition) Assert-ToolingContextHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $expected -Transition $transition} $workspaceFull $event $proof
                $documents=@($proof.intent.artifacts|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))})
                $toolingUpgradeRequests=@($documents|Where-Object{[string]$_.schema-ceq'rusty.morphospace.workflow.tooling_context_upgrade.v1'})
                $toolingUpgradeContexts=@($documents|Where-Object{[string]$_.schema-ceq'rusty.morphospace.workflow.tooling_context.v1'})
                if($toolingUpgradeRequests.Count-ne1-or$toolingUpgradeContexts.Count-ne1){throw 'Active retirement tooling upgrade proof artifacts are ambiguous.'}
                foreach($binding in @(Get-ActiveRetirementToolingProofBindings -WorkspaceRoot $workspaceFull -Request $toolingUpgradeRequests[0] -Context $toolingUpgradeContexts[0])){Set-PlanningProjection ([string]$binding.path) ([string]$binding.sha256)}
            }elseif($artifactSchemas-ccontains'rusty.morphospace.workflow.active_write_scope_amendment.v1'){
                $null=&$amendmentModule {param($root,$expected,$transition) Assert-ActiveWriteScopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $expected -Transition $transition} $workspaceFull $event $proof
            }else{
                Assert-ActiveRetirementRetainedLifecycle $workspaceFull $event $proof
                foreach($relative in @($event.receipts)){Set-PlanningProjection ([string]$relative) (Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspaceFull ([string]$relative) -RequireLeaf))}
            }
        }
        $intentRelative="receipts/transactions/$transactionId.intent.json";$completionRelative="receipts/transactions/$transactionId.completion.json";$intentPath=Resolve-MorphospaceWorkspacePath $workspaceFull $intentRelative -RequireLeaf;$completionPath=Resolve-MorphospaceWorkspacePath $workspaceFull $completionRelative -RequireLeaf
        if((Get-MorphospaceFileSha256 $intentPath)-cne(Get-ActiveRetirementCanonicalRawSha256 $proof.intent)-or(Get-MorphospaceFileSha256 $completionPath)-cne(Get-ActiveRetirementCanonicalRawSha256 $proof.completion)){throw 'Active retirement planning lifecycle transaction bytes are non-canonical.'}
        if(@(Get-ChildItem -LiteralPath (Split-Path $intentPath -Parent) -File -Filter "$transactionId.artifact-*.pending").Count-ne0){throw 'Active retirement planning lifecycle contains an orphan committed pending artifact.'}
        Set-PlanningProjection ([string]$proof.intent.state.path) (Get-ActiveRetirementCanonicalRawSha256 $proof.intent.target.state.document);Set-PlanningProjection ([string]$proof.intent.unit.path) (Get-ActiveRetirementCanonicalRawSha256 $proof.intent.target.unit.document)
        foreach($projection in @($(if($proof.intent.PSObject.Properties.Name-contains'additional_projections'){$proof.intent.additional_projections}else{@()}))){Set-PlanningProjection ([string]$projection.path) (Get-ActiveRetirementCanonicalRawSha256 $projection.document)}
        foreach($artifact in @($proof.intent.artifacts)){$artifactBytes=[Convert]::FromBase64String([string]$artifact.bytes_base64);if((Get-MorphospaceSha256Bytes $artifactBytes)-cne[string]$artifact.sha256){throw 'Active retirement planning lifecycle artifact payload is detached.'};Set-PlanningProjection ([string]$artifact.path) ([string]$artifact.sha256)}
        Set-PlanningProjection $intentRelative (Get-MorphospaceFileSha256 $intentPath);Set-PlanningProjection $completionRelative (Get-MorphospaceFileSha256 $completionPath)
    }
    if($Request-and$Request.PSObject.Properties.Name-ccontains'retained_claim_diagnostic'){
        $diagnosticHead=if($ObservedHead){$ObservedHead}else{(@(&git -C $repository rev-parse HEAD 2>&1)-join'').Trim()}
        $diagnostic=Get-ActiveRetirementClaimDiagnosticProjection -Workspace $workspaceFull -Request $Request -Repository $repository -ObservedHead $diagnosticHead
        Set-PlanningProjection ([string]$diagnostic.path) ([string]$diagnostic.sha256)
    }
    if($Request-and$Request.PSObject.Properties.Name-ccontains'retained_ready_diagnostic'){
        $readyHead=if($ObservedHead){$ObservedHead}else{(@(&git -C $repository rev-parse HEAD 2>&1)-join'').Trim()}
        $readyDiagnostic=Get-ActiveRetirementReadyDiagnosticProjection -Workspace $workspaceFull -Request $Request -Repository $repository -ObservedHead $readyHead
        Set-PlanningProjection ([string]$readyDiagnostic.path) ([string]$readyDiagnostic.sha256)
    }
    Set-PlanningProjection 'iteration-events.jsonl' (Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspaceFull 'iteration-events.jsonl' -RequireLeaf))
    foreach($binding in @(Get-ActiveRetirementLifecycleDiagnostics $workspaceFull $repository $ObservedHead $Request $events)){Set-PlanningProjection ([string]$binding.path) ([string]$binding.sha256)}
    if($committed){
        $staged=@(& git -C $repository diff --cached --name-only --no-renames -- 2>&1);if($LASTEXITCODE-ne0-or$staged.Count-ne0){throw 'Active retirement committed planning descendant must remain clean.'}
        foreach($path in @($expected.Keys)){$live=Join-Path $repository $path;if(-not[IO.File]::Exists($live)-or(Get-MorphospaceFileSha256 $live)-cne[string]$expected[$path]){throw "Active retirement committed planning projection is damaged: $path"}}
        $changed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $cursor=$ObservedHead
        while($cursor-cne$LockedCommit){
            $line=(@(& git -C $repository rev-list --parents -n 1 $cursor 2>&1)-join'').Trim()
            if($LASTEXITCODE-ne0-or$line-cnotmatch'^[0-9a-f]{40} [0-9a-f]{40}$'){throw 'Active retirement committed planning descendant must have linear authenticated history.'}
            $parent=$line.Substring(41)
            $paths=@(& git -C $repository diff --name-only --no-renames $parent $cursor -- 2>&1)
            if($LASTEXITCODE-ne0){throw 'Active retirement committed planning descendant diff failed.'}
            foreach($path in $paths){$relative=([string]$path).Replace('\','/');if(-not$expected.ContainsKey($relative)){throw "Active retirement committed planning descendant changes unauthenticated path: $relative"};[void]$changed.Add($relative)}
            $cursor=$parent
        }
        $final=@(& git -C $repository diff --name-only --no-renames $LockedCommit $ObservedHead -- 2>&1)
        if($LASTEXITCODE-ne0){throw 'Active retirement committed planning descendant final diff failed.'}
        foreach($path in $final){if(-not$expected.ContainsKey(([string]$path).Replace('\','/'))){throw 'Active retirement committed planning descendant final projection is unauthenticated.'}}
        if($changed.Count-eq0){throw 'Active retirement committed planning descendant contains no lifecycle projection.'}
        return $true
    }
    $staged=@(& git -C $repository diff --cached --name-only --no-renames -- 2>&1|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')});if($LASTEXITCODE-ne0-or$staged.Count-ne0){throw 'Active retirement planning lifecycle dirt must not be staged.'}
    $changes=@();foreach($line in @($StatusPorcelain)){$value=[string]$line;if($value.Length-lt4-or$value.Substring(0,2)-cnotin@(' M','??')){throw 'Active retirement planning lifecycle dirt contains a staged, deleted, renamed, conflicted, or unsupported entry.'};$gitPath=$value.Substring(3).Replace('\','/');if($RecoveryIntent-and$gitPath.StartsWith($workspacePrefix,[StringComparison]::Ordinal)-and$recoveryOwned.Contains($gitPath.Substring($workspacePrefix.Length))){continue};$changes+=,$gitPath};$changes=@($changes|Sort-Object -Unique)
    $allowed=@();foreach($path in @($expected.Keys|Sort-Object)){$live=Join-Path $repository $path;if(-not[IO.File]::Exists($live)-or(Get-MorphospaceFileSha256 $live)-cne[string]$expected[$path]){throw "Active retirement planning lifecycle projection is damaged: $path"};$null=& git -C $repository diff --quiet HEAD -- $path 2>&1;if($LASTEXITCODE-ne0){$allowed+=,$path}else{$null=& git -C $repository ls-files --error-unmatch -- $path 2>&1;if($LASTEXITCODE-ne0){$allowed+=,$path}}};$allowed=@($allowed|Sort-Object -Unique)
    if($changes.Count-ne$allowed.Count-or($changes-join'|')-cne($allowed-join'|')){throw "Active retirement planning repository dirt differs from the authenticated lifecycle projection (expected: $($allowed-join', '); observed: $($changes-join', '))."}
    return $true
}
function Get-ActiveRetirementRepositoryMaterialization([string]$Id,[object]$Entry,[object]$Locked,[bool]$Writable,[Collections.Generic.HashSet[string]]$BackingRoots){
    $rootComparer=if([OperatingSystem]::IsWindows()){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    $rootComparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if([string]$Entry.role-cne[string]$Locked.role){throw "Active retirement repository map role differs from the source lock for '$Id'."}
    $mappedText=[string]$Entry.path
    if(-not[IO.Path]::IsPathFullyQualified($mappedText)-or$mappedText-cmatch'(^|[\\/])\.\.?(?:[\\/]|$)'){throw "Active retirement repository map path is not an exact absolute materialization for '$Id'."}
    $mappedPath=[IO.Path]::GetFullPath($mappedText).TrimEnd('\','/')
    if(-not[IO.Directory]::Exists($mappedPath)){throw "Active retirement requires clean available source repository '$Id'."}
    Assert-MorphospaceNoReparseAncestor -Root ([IO.Path]::GetPathRoot($mappedPath)) -Candidate $mappedPath
    $gitRoot=(@(& git -C $mappedPath rev-parse --show-toplevel 2>&1)-join'').Trim()
    if($LASTEXITCODE-ne0){throw "Active retirement requires clean available source repository '$Id'."}
    $gitRoot=[IO.Path]::GetFullPath($gitRoot).TrimEnd('\','/')
    Assert-MorphospaceNoReparseAncestor -Root ([IO.Path]::GetPathRoot($gitRoot)) -Candidate $gitRoot
    $isRoot=$rootComparer.Equals($gitRoot,$mappedPath);$isNested=$mappedPath.StartsWith($gitRoot+[IO.Path]::DirectorySeparatorChar,$rootComparison)
    if(-not$isRoot-and-not$isNested){throw 'Active retirement mapped materialization is outside its backing Git repository.'}
    if(-not$BackingRoots.Add($gitRoot)){throw 'Active retirement requires distinct authenticated backing Git repositories.'}
    if($Writable-and-not$isRoot){throw "Active retirement writable repository '$Id' must map to its exact Git root."}
    if($isNested-and($Writable-or[string]$Entry.role-cne'source')){throw "Active retirement nested repository materialization '$Id' must be a read-only source dependency."}
    [pscustomobject]@{mapped_path=$mappedPath;git_root=$gitRoot;is_nested=$isNested}
}
function Get-ActiveRetirementRepositories([object]$Unit,[object]$Source,[string]$RepoMapPath,[string]$Workspace='',[object]$RecoveryIntent=$null,[object]$Request=$null){
    # Git observation is action-only. The shared reader avoids importing the
    # larger automation orchestrator into the historical dependency closure.
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceRepositoryObservation.psm1')
    $mapDocument=Read-MorphospaceProtocolJson ([IO.Path]::GetFullPath($RepoMapPath))
    Assert-ActiveRetirementSchema $mapDocument 'repository-map.schema.json'
    $retainedDiagnosticValidated=$false
    $map=@{};foreach($row in @($mapDocument.repositories)){
        if($map.ContainsKey([string]$row.repo_id)){throw 'Active retirement repository map contains duplicate identities.'};$map[[string]$row.repo_id]=$row
    }
    $authorized=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($row in @($Unit.allowed_repositories)){if(-not$authorized.Add([string]$row.repo_id)){throw 'Active retirement repeats an authorized source repository.'}}
    $sourceIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($row in @($Source.repositories)){if(-not$sourceIds.Add([string]$row.repo_id)){throw 'Active retirement source composition repeats a repository.'}}
    foreach($id in $authorized){if(-not$sourceIds.Contains($id)){throw 'Active retirement source composition omits an authorized repository.'}}
    if([string]::IsNullOrWhiteSpace($Workspace)){throw 'Active retirement repository observation requires its authenticated admission workspace.'}
    $admissions=@(Get-ChildItem -LiteralPath (Resolve-MorphospaceWorkspacePath $Workspace 'receipts') -File -Filter '*.json'|ForEach-Object{$document=Read-MorphospaceProtocolJson $_.FullName;if([string]$document.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$document.unit_id-ceq[string]$Unit.unit_id){$document}})
    if($admissions.Count-ne1){throw 'Active retirement repository observation requires one exact current admission receipt.'}
    $admission=$admissions[0];$provenanceModule=Import-ActiveRetirementDevelopmentEnvelopeProvenance
    $preparationProof=if($RecoveryIntent){Test-ActiveRetirementRecoveryPreparationProvenance $Workspace $admission $RecoveryIntent $provenanceModule}else{&$provenanceModule {param($root,$document) Test-MorphospaceDevelopmentUnitPreparation -WorkspaceRoot $root -Admission $document -Phase Freeze} $Workspace $admission}
    $mapBinding=if($preparationProof.PSObject.Properties.Name-contains'continuation'-and$null-ne$preparationProof.continuation){$preparationProof.continuation.repository_map}else{[pscustomobject]@{path=[string]$admission.expected.repository_map_path;raw_sha256=[string]$admission.expected.repository_map_sha256}}
    $admittedMap=Resolve-MorphospaceWorkspacePath $Workspace ([string]$mapBinding.path) -RequireLeaf
    $rootComparer=if([OperatingSystem]::IsWindows()){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    if(-not$rootComparer.Equals([IO.Path]::GetFullPath($admittedMap),[IO.Path]::GetFullPath($RepoMapPath))-or(Get-MorphospaceFileSha256 $admittedMap)-cne[string]$mapBinding.raw_sha256){throw 'Active retirement repository map is detached from its admission.'}
    $ids=[string[]]@($sourceIds);[Array]::Sort($ids,[StringComparer]::Ordinal);$observations=@()
    $retainedReadyValidated=$false
    $roots=[Collections.Generic.HashSet[string]]::new($rootComparer)
    foreach($id in $ids){
        if(-not$map.ContainsKey($id)){throw "Active retirement lacks repository map entry '$id'."}
        $entry=$map[$id]
        $locked=@(Get-MorphospaceSourceCompositionRepositoryPins $Source|Where-Object{[string]$_.repo_id-ceq$id})[0]
        $materialization=Get-ActiveRetirementRepositoryMaterialization -Id $id -Entry $entry -Locked $locked -Writable ($authorized.Contains($id)) -BackingRoots $roots
        $mappedPath=[string]$materialization.mapped_path
        $observed=Get-MorphospaceRepositoryState -RepoId $id -Path $mappedPath
        $remaining=@($observed.status_porcelain)
        if($RecoveryIntent-and[string]$entry.role-ceq'planning'){
            $root=[IO.Path]::GetFullPath([string]$entry.path).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if($Workspace.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){
                $prefix=[IO.Path]::GetRelativePath($root,$Workspace).Replace('\','/').TrimEnd('/')+'/'
                $owned=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach($relative in @([string]$RecoveryIntent.state.path,[string]$RecoveryIntent.events.path,"receipts/transactions/$($RecoveryIntent.transaction_id).intent.json","receipts/transactions/$($RecoveryIntent.transaction_id).completion.json")+@($RecoveryIntent.artifacts|ForEach-Object{[string]$_.path})){
                    [void]$owned.Add($prefix+$relative)
                }
                for($index=0;$index-lt@($RecoveryIntent.artifacts).Count;$index++){[void]$owned.Add($prefix+"receipts/transactions/$($RecoveryIntent.transaction_id).artifact-$index.pending")}
                $remaining=@($remaining|Where-Object{
                    $line=[string]$_
                    # Only ledger-owned additions/modifications qualify; renames, deletions and staged changes do not.
                    -not($line.Length-gt3-and@('?? ',' M ')-ccontains$line.Substring(0,3)-and$owned.Contains($line.Substring(3)))
                })
            }
        }
        if($Request-and$Request.PSObject.Properties.Name-ccontains'retained_claim_diagnostic'-and[string]$entry.role-ceq'planning'){
            $null=Get-ActiveRetirementClaimDiagnosticProjection -Workspace $Workspace -Request $Request -Repository $mappedPath -ObservedHead ([string]$observed.head)
            $retainedDiagnosticValidated=$true
        }
        if($Request-and$Request.PSObject.Properties.Name-ccontains'retained_ready_diagnostic'-and[string]$entry.role-ceq'planning'){
            $null=Get-ActiveRetirementReadyDiagnosticProjection -Workspace $Workspace -Request $Request -Repository $mappedPath -ObservedHead ([string]$observed.head)
            $retainedReadyValidated=$true
        }
        $planningDirt=$false
        if($observed.available-and$observed.is_git-and$remaining.Count-ne0-and-not$authorized.Contains($id)-and[string]$observed.head-ceq[string]$locked.commit-and[string]$observed.tree-ceq[string]$locked.tree){$planningDirt=Test-ActiveRetirementPlanningProjectionFromAuthenticatedAdmission -Workspace $Workspace -Unit $Unit -RepositoryEntry $entry -StatusPorcelain $remaining -Admission $admission -RecoveryIntent $RecoveryIntent -Request $Request}
        if($observed.available-and$observed.is_git-and$remaining.Count-eq0-and-not$authorized.Contains($id)-and[string]$entry.role-ceq'planning'-and[string]$observed.head-cne[string]$locked.commit){
            $null=& git -C $mappedPath merge-base --is-ancestor ([string]$locked.commit) ([string]$observed.head) 2>&1
            if($LASTEXITCODE-ne0){throw "Active retirement planning descendant '$id' does not retain its locked baseline."}
            $planningDirt=Test-ActiveRetirementPlanningProjectionFromAuthenticatedAdmission -Workspace $Workspace -Unit $Unit -RepositoryEntry $entry -StatusPorcelain $remaining -Admission $admission -LockedCommit ([string]$locked.commit) -ObservedHead ([string]$observed.head) -Request $Request
        }
        if(-not$observed.available-or-not$observed.is_git-or($remaining.Count-ne0-and-not$planningDirt)-or[string]$observed.head-cnotmatch'^[0-9a-f]{40}$'-or[string]$observed.tree-cnotmatch'^[0-9a-f]{40}$'){throw "Active retirement requires clean available source repository '$id'."}
        # Writable repositories may have newer clean local checkpoints. Read-only dependencies stay pinned.
        if(-not$authorized.Contains($id)-and-not$planningDirt-and([string]$observed.head-cne[string]$locked.commit-or[string]$observed.tree-cne[string]$locked.tree)){throw "Active retirement read-only dependency '$id' differs from the source lock."}
        if($authorized.Contains($id)){
            $null=& git -C $mappedPath merge-base --is-ancestor ([string]$locked.commit) ([string]$observed.head) 2>&1
            if($LASTEXITCODE-ne0){throw "Active retirement writable checkpoint '$id' does not retain its locked baseline."}
        }
        $observations+=,[pscustomobject][ordered]@{repo_id=$id;head=[string]$observed.head;tree=[string]$observed.tree;branch=$observed.branch;clean=$true}
    }
    if($Request-and$Request.PSObject.Properties.Name-ccontains'retained_claim_diagnostic'-and-not$retainedDiagnosticValidated){throw 'Retained Claim diagnostic requires its exact planning repository.'}
    if($Request-and$Request.PSObject.Properties.Name-ccontains'retained_ready_diagnostic'-and-not$retainedReadyValidated){throw 'Retained Ready diagnostic requires its exact planning repository.'}
    return @($observations)
}
function Get-ActiveRetirementClaim([string]$Workspace,[object]$Request,[object[]]$Events){
    $claims=@($Events|Where-Object{[string]$_.unit_id-ceq[string]$Request.unit_id-and[string]$_.event_id-cmatch('^'+[regex]::Escape([string]$Request.unit_id)+'-claimed-[0-9]{4,}$')})
    if($claims.Count-ne1){throw 'Active retirement requires one unambiguous current Claim lineage.'}
    $event=$claims[0];$id="$([string]$event.event_id)-transition"
    $proof=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $id -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$Request.old_unit.path) -ExpectedEventsPath 'iteration-events.jsonl'
    if((Get-MorphospaceCanonicalJsonSha256 $proof.intent.event)-cne(Get-MorphospaceCanonicalJsonSha256 $event)-or[string]$proof.intent.target.unit.document.status-cne'active'-or[string]$proof.intent.target.state.document.current_unit-cne[string]$Request.unit_id){throw 'Active retirement Claim lineage is detached.'}
    $preUnit=Copy-ActiveRetirementValue $proof.intent.target.unit.document;$preUnit.status='ready'
    if((Get-MorphospaceCanonicalJsonSha256 $preUnit)-cne[string]$proof.intent.pre.unit.sha256){throw 'Active retirement Claim is not an exact ready-to-active owner transition.'}
    [pscustomobject][ordered]@{event_id=[string]$event.event_id;transaction_id=$id;intent_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$id.intent.json" -RequireLeaf);completion_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$id.completion.json" -RequireLeaf)}
}
function Assert-ActiveRetirementPreserved([string]$Workspace,[object]$Request,[string]$RepoMapPath,[object]$RecoveryIntent=$null){
    foreach($pair in @(@('project','project.spec.json'),@('feature_lock','feature.lock.json'))){
        $binding=Get-ActiveRetirementFileBinding $Workspace $pair[1]
        if([string]$binding.raw_sha256-cne[string]$Request.expected."$($pair[0])_raw_sha256"-or[string]$binding.canonical_sha256-cne[string]$Request.expected."$($pair[0])_canonical_sha256"){throw "Active retirement preserved $($pair[0]) bytes drifted."}
    }
    $unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$Request.old_unit.path) -RequireLeaf)
    $binding=Get-ActiveRetirementFileBinding $Workspace ([string]$Request.old_unit.path)
    if([string]$unit.status-cne'active'-or[string]$unit.unit_id-cne[string]$Request.unit_id-or[string]$unit.project_id-cne[string]$Request.project_id-or[string]$binding.raw_sha256-cne[string]$Request.old_unit.raw_sha256-or[string]$binding.canonical_sha256-cne[string]$Request.old_unit.canonical_sha256){throw 'Active retirement preserved active unit bytes drifted.'}
    if([string]$unit.source_composition.lock_path-cne[string]$Request.source_composition.path){throw 'Active retirement source composition is detached from its unit.'}
    Assert-ActiveRetirementEqual $Request.source_composition (Get-ActiveRetirementFileBinding $Workspace ([string]$Request.source_composition.path)) 'source composition'
    if((Get-MorphospaceFileSha256 ([IO.Path]::GetFullPath($RepoMapPath)))-cne[string]$Request.expected.repository_map_sha256){throw 'Active retirement repository map bytes drifted.'}
    $source=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$Request.source_composition.path) -RequireLeaf)
    switch -CaseSensitive ([string]$source.schema){
        'rusty.morphospace.workflow.source_composition_lock.v1' {
            Assert-ActiveRetirementSchema $source 'source-composition-lock.schema.json'
            if([string]$source.unit_id-cne[string]$Request.unit_id-or[string]$source.fingerprint-cne(Get-MorphospaceSourceCompositionFingerprint -ProjectId ([string]$source.project_id) -UnitId ([string]$source.unit_id) -Repositories @($source.repositories))){throw 'Active retirement unit source lock fingerprint is detached.'}
        }
        {$_-cin@('rusty.morphospace.workflow.development_envelope_source_composition.v1','rusty.morphospace.workflow.development_envelope_source_composition.v2','rusty.morphospace.workflow.development_envelope_source_composition.v3')} {
            $version=([string]$source.schema).Split('.')[-1]
            Assert-ActiveRetirementSchema $source "development-envelope-source-composition-$version.schema.json"
            if([string]$source.fingerprint-cne(Get-MorphospacePreparationSourceCompositionFingerprint $source)-or[string]$source.lock_id-cne"$($source.preparation_id)-source-$(([string]$source.fingerprint).Substring(0,12))"){throw 'Active retirement preparation source lock fingerprint is detached.'}
            # The current-history admission proof authenticates this preparation-owned artifact and the unit's binding.
        }
        'rusty.morphospace.workflow.active_development_envelope_source_composition.v1' {
            Assert-ActiveRetirementSchema $source 'active-development-envelope-source-composition-v1.schema.json'
            $identity=Copy-ActiveRetirementValue $source;$identity.fingerprint='0'*64
            if([string]$source.unit_id-cne[string]$Request.unit_id-or[string]$source.fingerprint-cne(Get-MorphospaceCanonicalJsonSha256 $identity)){throw 'Active retirement extended source identity is detached.'}
            # Get-ActiveRetirementRepositories authenticates its complete owner lineage.
        }
        default {throw 'Active retirement source composition schema is unsupported.'}
    }
    if([string]$source.project_id-cne[string]$Request.project_id){throw 'Active retirement source lock project identity is detached.'}
    if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace ([string]$Request.accepted_receipt.path) -RequireLeaf))-cne[string]$Request.accepted_receipt.sha256){throw 'Active retirement accepted checkpoint bytes drifted.'}
    Assert-ActiveRetirementEqual @($Request.repositories) @(Get-ActiveRetirementRepositories -Unit $unit -Source $source -RepoMapPath $RepoMapPath -Workspace $Workspace -RecoveryIntent $RecoveryIntent -Request $Request) 'clean repository observation'
    return $unit
}
function New-ActiveRetirementReceipt([object]$Request,[string]$Path,[string]$Sha,[string]$Timestamp){
    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.active_unit_retirement_receipt.v1';retirement_id=[string]$Request.retirement_id;project_id=[string]$Request.project_id;unit_id=[string]$Request.unit_id;replacement_unit_id=[string]$Request.replacement_unit_id;reason=[string]$Request.reason;timestamp=$Timestamp;transaction_id="$($Request.retirement_id)-active-retired-transition";request=[pscustomobject]@{path=$Path;sha256=$Sha};old_unit=$Request.old_unit;source_composition=$Request.source_composition;claim=$Request.claim;repositories=@($Request.repositories);accepted_receipt=$Request.accepted_receipt;accepted=$false;source_mutation_performed=$false}
}
function New-ActiveRetirementResult([object]$Request,[string]$Path,[string]$Sha,[string]$Timestamp,[bool]$Executed){
    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$Request.project_id;unit_id=[string]$Request.unit_id;action='RetireActive';timestamp=$Timestamp;executed=$Executed;transition='active-retired-to-idle';status_before='active';status_after='active';current_unit_before=[string]$Request.unit_id;current_unit_after=$(if($Executed){$null}else{[string]$Request.unit_id});preservation=[pscustomobject]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject]@{path=$Path;sha256=$Sha};event_id=$(if($Executed){"$($Request.retirement_id)-active-retired"}else{$null})}
}
function Assert-ActiveRetirementIntent([string]$Workspace,[object]$Intent,[object]$Request,[string]$RequestPath,[string]$RequestSha,[string]$OutPath){
    if($Request.PSObject.Properties.Name-ccontains'retained_claim_diagnostic'){
        $repository=(@(&git -C $Workspace rev-parse --show-toplevel 2>&1)-join'').Trim()
        if($LASTEXITCODE-ne0){throw 'Retained Claim diagnostic historical Git materialization is unavailable.'}
        $head=(@(&git -C $repository rev-parse HEAD 2>&1)-join'').Trim()
        if($LASTEXITCODE-ne0){throw 'Retained Claim diagnostic historical Git HEAD is unavailable.'}
        $null=Get-ActiveRetirementClaimDiagnosticProjection -Workspace $Workspace -Request $Request -Repository $repository -ObservedHead $head
    }

    if($Request.PSObject.Properties.Name-ccontains'retained_ready_diagnostic'){
        $readyRepository=(@(&git -C $Workspace rev-parse --show-toplevel 2>&1)-join'').Trim()
        if($LASTEXITCODE-ne0){throw 'Retained Ready diagnostic historical Git materialization is unavailable.'}
        $readyHead=(@(&git -C $readyRepository rev-parse HEAD 2>&1)-join'').Trim()
        if($LASTEXITCODE-ne0){throw 'Retained Ready diagnostic historical Git HEAD is unavailable.'}
        $null=Get-ActiveRetirementReadyDiagnosticProjection -Workspace $Workspace -Request $Request -Repository $readyRepository -ObservedHead $readyHead
    }
    if($Request.PSObject.Properties.Name-ccontains'retained_lifecycle_diagnostics'){
        $repository=(@(&git -C $Workspace rev-parse --show-toplevel 2>&1)-join'').Trim();if($LASTEXITCODE-ne0){throw 'Retained lifecycle diagnostic historical repository is unavailable.'}
        $head=(@(&git -C $repository rev-parse HEAD 2>&1)-join'').Trim();if($LASTEXITCODE-ne0){throw 'Retained lifecycle diagnostic historical HEAD is unavailable.'}
        $null=Get-ActiveRetirementLifecycleDiagnostics $Workspace $repository $head $Request (Get-ActiveRetirementEvents $Workspace).events
    }
    $eventId="$($Request.retirement_id)-active-retired"
    if([string]$Request.old_unit.unit_id-cne[string]$Request.unit_id-or[string]$Request.old_unit.path-cne"iteration-units/$($Request.unit_id).json"-or[string]$Request.replacement_unit_id-ceq[string]$Request.unit_id-or[string]$Intent.target.unit.document.unit_id-cne[string]$Request.unit_id-or[string]$Intent.target.unit.document.project_id-cne[string]$Request.project_id-or[string]$Intent.target.unit.document.status-cne'active'-or[string]$Intent.target.unit.document.source_composition.lock_path-cne[string]$Request.source_composition.path){throw 'Active retirement historical endpoint or source-lock identity is detached.'}
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v6'-or[string]$Intent.transaction_id-cne"$eventId-transition"-or[string]$Intent.state.path-cne'workspace.state.json'-or[string]$Intent.unit.path-cne[string]$Request.old_unit.path-or[string]$Intent.events.path-cne'iteration-events.jsonl'){throw 'Active retirement intent identity or paths are detached.'}
    foreach($pair in @(@([string]$Intent.pre.state.sha256,[string]$Request.expected.state_canonical_sha256),@([string]$Intent.pre_state_raw.sha256,[string]$Request.expected.state_raw_sha256),@([string]$Intent.pre.unit.sha256,[string]$Request.old_unit.canonical_sha256),@([string]$Intent.target.unit.sha256,[string]$Request.old_unit.canonical_sha256),@([string]$Intent.pre_unit_raw.sha256,[string]$Request.old_unit.raw_sha256))){if($pair[0]-cne$pair[1]){throw 'Active retirement intent preimage is detached.'}}
    $preState=Copy-ActiveRetirementValue $Intent.target.state.document
    if($null-ne$preState.current_unit-or[string]$preState.last_event_id-cne$eventId){throw 'Active retirement target is not idle.'}
    $preState.current_unit=[string]$Request.unit_id;$preState.last_event_id=[string]$Request.expected.event_tail_id
    if((Get-MorphospaceCanonicalJsonSha256 $preState)-cne[string]$Request.expected.state_canonical_sha256){throw 'Active retirement changes fields beyond the active pointer and event tail.'}
    if($null-ne$preState.next_ready_unit-or$null-ne$preState.pending_push_bundle-or@($preState.blockers).Count-ne0-or($preState.PSObject.Properties.Name-contains'normal_validation_selection'-and$null-ne$preState.normal_validation_selection)){throw 'Active retirement predecessor contains conflicting queue, selector, publication or blockers.'}
    if([string]$preState.last_accepted_receipt-cne[string]$Request.accepted_receipt.path){throw 'Active retirement changes accepted checkpoint identity.'}
    $expected=[pscustomobject]@{state_sha256=[string]$Request.expected.state_canonical_sha256;unit_sha256=[string]$Request.old_unit.canonical_sha256;event_tail_id=[string]$Request.expected.event_tail_id;events_sha256=[string]$Request.expected.events_sha256;events_length=[long]$Request.expected.events_length}
    Assert-ActiveRetirementEqual $expected $Intent.expected 'ledger prefix'
    if(@($Intent.additional_projections).Count-ne2){throw 'Active retirement must bind both unchanged authority projections.'}
    foreach($pair in @(@('feature_lock','feature.lock.json'),@('project','project.spec.json'))){
        $rows=@($Intent.additional_projections|Where-Object{[string]$_.path-ceq$pair[1]})
        if($rows.Count-ne1-or[string]$rows[0].pre_sha256-cne[string]$Request.expected."$($pair[0])_canonical_sha256"-or[string]$rows[0].target_sha256-cne[string]$rows[0].pre_sha256-or[string]$rows[0].pre_raw_sha256-cne[string]$Request.expected."$($pair[0])_raw_sha256"){throw 'Active retirement authority projection is detached.'}
    }
    $event=$Intent.event
    $paths=[string[]]@($RequestPath,$OutPath);[Array]::Sort($paths,[StringComparer]::Ordinal)
    if($RequestPath-cne"receipts/$($Request.retirement_id)-request.json"-or[string]$event.event_id-cne$eventId-or[string]$event.unit_id-cne[string]$Request.unit_id-or[string]$event.project_id-cne[string]$Request.project_id-or[string]$event.event_type-cne'state-transition'-or@($Intent.artifacts).Count-ne2){throw 'Active retirement event or artifact identity is detached.'}
    Assert-ActiveRetirementEqual @($paths) @($event.receipts) 'event artifacts'
    Assert-ActiveRetirementEqual @($paths) @($Intent.artifacts|ForEach-Object{[string]$_.path}) 'owned artifact paths'
    $requestArtifact=@($Intent.artifacts|Where-Object{[string]$_.path-ceq$RequestPath})[0]
    $requestBytes=[Convert]::FromBase64String([string]$requestArtifact.bytes_base64)
    if((Get-MorphospaceSha256Bytes $requestBytes)-cne$RequestSha-or[string]$requestArtifact.sha256-cne$RequestSha){throw 'Active retirement retained request payload is damaged.'}
    Assert-ActiveRetirementEqual $Request (ConvertFrom-MorphospaceProtocolJsonBytes $requestBytes) 'retained request payload'
    $receiptArtifact=@($Intent.artifacts|Where-Object{[string]$_.path-ceq$OutPath})[0]
    $bytes=[Convert]::FromBase64String([string]$receiptArtifact.bytes_base64)
    if((Get-MorphospaceSha256Bytes $bytes)-cne[string]$receiptArtifact.sha256){throw 'Active retirement receipt payload is damaged.'}
    $receipt=ConvertFrom-MorphospaceProtocolJsonBytes $bytes
    Assert-ActiveRetirementSchema $receipt 'active-unit-retirement-receipt-v1.schema.json'
    Assert-ActiveRetirementEqual (New-ActiveRetirementReceipt $Request $RequestPath $RequestSha ([string]$event.timestamp)) $receipt 'owned receipt'
    return $receipt
}
function Test-MorphospaceHistoricalActiveUnitRetirement {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$ExpectedEvent)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    # Parsed events belong only to this read-only verifier. Every use still
    # reads and hashes live raw bytes; all transaction/provenance guards remain live.
    if($null-ne$script:ActiveRetirementHistoricalEventsScope){throw 'Historical retirement event authentication cannot be reentered.'}
    $script:ActiveRetirementHistoricalEventsScope=[pscustomobject]@{workspace=$workspace.TrimEnd('\','/');observation=$null;schema_hashes=$null}
    try {
    if([string]$ExpectedEvent.event_id-cnotmatch'-active-retired$'-or@($ExpectedEvent.receipts).Count-ne2){throw 'Historical active retirement event identity is invalid.'}
    $retirementId=[string]$ExpectedEvent.event_id-creplace'-active-retired$',''
    $requestPath="receipts/$retirementId-request.json"
    $outPaths=@($ExpectedEvent.receipts|Where-Object{[string]$_-cne$requestPath})
    if($outPaths.Count-ne1){throw 'Historical active retirement artifact paths are ambiguous.'}
    $out=Get-ActiveRetirementReference $workspace ([string]$outPaths[0]);$receipt=Read-MorphospaceProtocolJson $out.absolute
    Assert-ActiveRetirementSchema $receipt 'active-unit-retirement-receipt-v1.schema.json'
    $reference=Get-ActiveRetirementReference $workspace ([string]$receipt.request.path);$request=Read-MorphospaceProtocolJson $reference.absolute
    Assert-ActiveRetirementSchema $request 'active-unit-retirement-v1.schema.json'
    $sha=Get-MorphospaceFileSha256 $reference.absolute
    if($sha-cne[string]$receipt.request.sha256){throw 'Historical active retirement request bytes are damaged.'}
    $id="$($ExpectedEvent.event_id)-transition"
    $proof=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $id -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$request.old_unit.path) -ExpectedEventsPath 'iteration-events.jsonl'
    Assert-ActiveRetirementEqual $ExpectedEvent $proof.intent.event 'historical event'
    $owned=Assert-ActiveRetirementIntent $workspace $proof.intent $request $reference.path $sha $out.path
    Assert-ActiveRetirementEqual $owned $receipt 'historical receipt'
    $old=Get-ActiveRetirementFileBinding $workspace ([string]$request.old_unit.path)
    if([string]$old.raw_sha256-cne[string]$request.old_unit.raw_sha256-or[string]$old.canonical_sha256-cne[string]$request.old_unit.canonical_sha256-or[string]$proof.intent.target.unit.document.status-cne'active'){throw 'Historical retired active unit bytes changed.'}
    Assert-ActiveRetirementEqual $request.source_composition (Get-ActiveRetirementFileBinding $workspace ([string]$request.source_composition.path)) 'historical preserved source lock'
    if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace ([string]$request.accepted_receipt.path) -RequireLeaf))-cne[string]$request.accepted_receipt.sha256){throw 'Historical active retirement accepted checkpoint bytes changed.'}
    $events=(Get-ActiveRetirementEvents $workspace).events
    Assert-ActiveRetirementEqual $request.claim (Get-ActiveRetirementClaim $workspace $request @($events|Where-Object{[int]$_.sequence-lt[int]$ExpectedEvent.sequence})) 'historical Claim'
    # Later envelope/source checkpoints may evolve; historical authentication never compares their live preimages.
    $null=Get-ActiveRetirementEvents $workspace
    [pscustomobject]@{intent=$proof.intent;completion=$proof.completion;receipt=$receipt;request=$request;transaction_id=$id}
    }finally{$script:ActiveRetirementHistoricalEventsScope=$null}
}
function Invoke-MorphospaceRetireActive {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$UnitId,[Parameter(Mandatory)][string]$RepoMapPath,[Parameter(Mandatory)][string]$ActiveUnitRetirement,[string]$ExpectedActiveUnitRetirementSha256='',[string]$Timestamp='',[Parameter(Mandatory)][string]$OutPath,[switch]$Execute,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none')
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$inputPath=[IO.Path]::GetFullPath($ActiveUnitRetirement);$out=Get-ActiveRetirementReference $workspace $OutPath
    $inputBytes=[IO.File]::ReadAllBytes($inputPath);$sha=Get-MorphospaceSha256Bytes $inputBytes
    $request=ConvertFrom-MorphospaceProtocolJsonBytes $inputBytes
    Assert-ActiveRetirementSchema $request 'active-unit-retirement-v1.schema.json'
    $requestRef=Get-ActiveRetirementReference $workspace "receipts/$($request.retirement_id)-request.json"
    if($requestRef.path-ceq$out.path){throw 'Active retirement request and receipt paths must differ.'}
    if(($Execute-and-not$ExpectedActiveUnitRetirementSha256)-or($ExpectedActiveUnitRetirementSha256-and$ExpectedActiveUnitRetirementSha256-cne$sha)){throw 'Active retirement requires the exact reviewed request SHA256.'}
    if([string]$request.unit_id-cne$UnitId-or[string]$request.old_unit.unit_id-cne$UnitId-or[string]$request.old_unit.path-cne"iteration-units/$UnitId.json"-or[string]$request.replacement_unit_id-ceq$UnitId){throw 'Active retirement endpoint identities are invalid.'}
    $eventId="$($request.retirement_id)-active-retired";$id="$eventId-transition"
    $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$id.intent.json";$completionPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$id.completion.json"
    $mutex=Enter-MorphospaceWorkspaceMutex $workspace
    try{
        if([IO.File]::Exists($intentPath)){
            $intent=Read-MorphospaceProtocolJson $intentPath;$receipt=Assert-ActiveRetirementIntent $workspace $intent $request $requestRef.path $sha $out.path
            if(-not[IO.File]::Exists($completionPath)){
                [void](Assert-ActiveRetirementPreserved -Workspace $workspace -Request $request -RepoMapPath $RepoMapPath -RecoveryIntent $intent)
                if($intent.target.unit.document.PSObject.Properties.Name-contains'tooling_context'){
                    $module=Import-ActiveRetirementDevelopmentEnvelopeProvenance
                    [void](&$module {param($root,$binding,$owner) Assert-MorphospaceToolingContextExecutor -WorkspaceRoot $root -Binding $binding -Action RetireActive -OwnerModule $owner} $workspace $intent.target.unit.document.tooling_context $MyInvocation.MyCommand.Module)
                }
                if(Test-Path -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace "iteration-units/$($request.replacement_unit_id).json")){throw 'Interrupted active retirement replacement identity is no longer absent.'}
                foreach($kind in @('intent','completion')){
                    if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$($request.claim.transaction_id).$kind.json" -RequireLeaf))-cne[string]$request.claim."${kind}_sha256"){throw 'Active retirement interrupted Claim evidence changed.'}
                }
                if(-not$Execute){throw 'Active retirement has an interrupted transaction; exact Execute is required to resume.'}
                Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $id -Repair -FaultAfter $FaultAfter|Out-Null
            }
            [void](Test-MorphospaceHistoricalActiveUnitRetirement -WorkspaceRoot $workspace -ExpectedEvent $intent.event)
            return New-ActiveRetirementResult $request $out.path (Get-MorphospaceFileSha256 $out.absolute) ([string]$receipt.timestamp) ([bool]$Execute)
        }
        if([IO.File]::Exists($completionPath)-or(Test-Path -LiteralPath $out.absolute)){throw 'Active retirement refuses an orphan completion or occupied receipt.'}
        if(Test-Path -LiteralPath $requestRef.absolute){throw 'Active retirement retained request artifact must be absent before the transaction.'}
        if(Test-Path -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace "iteration-units/$($request.replacement_unit_id).json")){throw 'Active retirement replacement identity must be absent before fresh preparation.'}
        $unit=Assert-ActiveRetirementPreserved $workspace $request $RepoMapPath
        if($unit.PSObject.Properties.Name-contains'tooling_context'){
            $module=Import-ActiveRetirementDevelopmentEnvelopeProvenance
            [void](&$module {param($root,$binding,$owner) Assert-MorphospaceToolingContextExecutor -WorkspaceRoot $root -Binding $binding -Action RetireActive -OwnerModule $owner} $workspace $unit.tooling_context $MyInvocation.MyCommand.Module)
        }
        Assert-ActiveRetirementSchema $unit 'iteration-unit.schema.json'
        $project=Read-MorphospaceProtocolJson (Join-Path $workspace 'project.spec.json');$feature=Read-MorphospaceProtocolJson (Join-Path $workspace 'feature.lock.json');$state=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
        $stateSchema=if([string]$state.schema-ceq'rusty.morphospace.workflow.workspace_state.v2'){'workspace-state-v2.schema.json'}else{'workspace-state.schema.json'};Assert-ActiveRetirementSchema $state $stateSchema
        if([string]$state.current_unit-cne$UnitId-or[string]$state.project_id-cne[string]$request.project_id-or[string]$project.project_id-cne[string]$request.project_id-or$null-ne$state.next_ready_unit-or$null-ne$state.pending_push_bundle-or@($state.blockers).Count-ne0-or($state.PSObject.Properties.Name-contains'normal_validation_selection'-and$null-ne$state.normal_validation_selection)){throw 'Active retirement requires exact active ownership without queue, selector, publication or blockers.'}
        if((Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json'))-cne[string]$request.expected.state_raw_sha256-or(Get-MorphospaceCanonicalJsonSha256 $state)-cne[string]$request.expected.state_canonical_sha256){throw 'Active retirement state CAS drifted.'}
        $events=Get-ActiveRetirementEvents $workspace
        if([string]$events.sha256-cne[string]$request.expected.events_sha256-or[long]$events.length-ne[long]$request.expected.events_length-or[string]$events.tail_id-cne[string]$request.expected.event_tail_id-or[string]$state.last_event_id-cne[string]$events.tail_id){throw 'Active retirement event CAS drifted.'}
        Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkHistory.psm1')
        $history=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $workspace
        if(-not$history.authenticated){throw 'Active retirement requires an authenticated accepted checkpoint and current suffix.'}
        Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopePreparation.psm1')
        $inertDrafts=Get-MorphospaceInertDevelopmentProposalIds -Workspace $workspace -History $history
        foreach($other in $history.units.Values){
            $otherId=[string]$other.unit_id
            if($otherId-cne$UnitId-and@('proposed','ready','active','validating')-ccontains[string]$other.status-and-not$history.retired_active_ids.Contains($otherId)-and-not$history.historical_ids.Contains($otherId)-and-not$inertDrafts.Contains($otherId)){throw 'Active retirement refuses another pending or in-flight unit.'}
        }
        Assert-ActiveRetirementEqual $request.claim (Get-ActiveRetirementClaim $workspace $request $events.events) 'current Claim'
        if([string]$state.last_accepted_receipt-cne[string]$request.accepted_receipt.path-or(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace ([string]$request.accepted_receipt.path) -RequireLeaf))-cne[string]$request.accepted_receipt.sha256){throw 'Active retirement accepted receipt binding drifted.'}
        if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('o')};[void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
        if((Test-MorphospaceStrictUtcTimestamp $Timestamp)-lt(Test-MorphospaceStrictUtcTimestamp ([string]$events.events[-1].timestamp))){throw 'Active retirement timestamp predates the ledger tail.'}
        if(-not$Execute){return New-ActiveRetirementResult $request $requestRef.path $sha $Timestamp $false}
        $target=Copy-ActiveRetirementValue $state;$target.current_unit=$null;$target.last_event_id=$eventId
        $receipt=New-ActiveRetirementReceipt $request $requestRef.path $sha $Timestamp;Assert-ActiveRetirementSchema $receipt 'active-unit-retirement-receipt-v1.schema.json'
        $artifactPaths=[string[]]@($requestRef.path,$out.path);[Array]::Sort($artifactPaths,[StringComparer]::Ordinal)
        $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=$events.events.Count+1;timestamp=$Timestamp;project_id=[string]$request.project_id;unit_id=$UnitId;event_type='state-transition';summary='Retired active ownership without acceptance, preserving the old unit and evidence for a named future replacement.';receipts=@($artifactPaths)}
        $bytes=ConvertTo-MorphospaceProtocolJsonBytes $receipt
        $artifacts=@($artifactPaths|ForEach-Object{if($_-ceq$requestRef.path){[pscustomobject]@{path=$_;sha256=$sha;bytes_base64=[Convert]::ToBase64String($inputBytes)}}else{[pscustomobject]@{path=$_;sha256=Get-MorphospaceSha256Bytes $bytes;bytes_base64=[Convert]::ToBase64String($bytes)}}})
        # Reobserve non-ledger guards while holding the same workspace mutex immediately before publishing intent.
        [void](Assert-ActiveRetirementPreserved $workspace $request $RepoMapPath)
        if((Get-MorphospaceFileSha256 $inputPath)-cne$sha){throw 'Active retirement request bytes drifted before intent.'}
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $id -StatePath 'workspace.state.json' -UnitPath ([string]$request.old_unit.path) -EventsPath 'iteration-events.jsonl' -TargetState $target -TargetUnit $unit -Event $event -ExpectedPreStateSha256 ([string]$request.expected.state_canonical_sha256) -ExpectedPreStateRawSha256 ([string]$request.expected.state_raw_sha256) -ExpectedPreUnitSha256 ([string]$request.old_unit.canonical_sha256) -ExpectedPreUnitRawSha256 ([string]$request.old_unit.raw_sha256) -ExpectedEventTailId ([string]$request.expected.event_tail_id) -ExpectedEventsSha256 ([string]$request.expected.events_sha256) -ExpectedEventsLength ([long]$request.expected.events_length) -AdditionalProjections @([pscustomobject]@{path='feature.lock.json';expected_sha256=[string]$request.expected.feature_lock_canonical_sha256;expected_raw_sha256=[string]$request.expected.feature_lock_raw_sha256;document=$feature},[pscustomobject]@{path='project.spec.json';expected_sha256=[string]$request.expected.project_canonical_sha256;expected_raw_sha256=[string]$request.expected.project_raw_sha256;document=$project}) -Artifacts $artifacts -FaultAfter $FaultAfter|Out-Null
        [void](Test-MorphospaceHistoricalActiveUnitRetirement -WorkspaceRoot $workspace -ExpectedEvent $event)
        return New-ActiveRetirementResult $request $out.path (Get-MorphospaceFileSha256 $out.absolute) $Timestamp $true
    }finally{try{Restore-ActiveRetirementCallerModules}finally{Exit-MorphospaceWorkspaceMutex $mutex}}
}
Export-ModuleMember -Function Invoke-MorphospaceRetireActive,Test-MorphospaceHistoricalActiveUnitRetirement
