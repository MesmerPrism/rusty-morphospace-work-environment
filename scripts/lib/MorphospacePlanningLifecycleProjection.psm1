Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:PlanningScriptsRoot=Split-Path $PSScriptRoot -Parent
$protocolCaller=Get-Command Read-MorphospaceProtocolJson -ErrorAction SilentlyContinue
$ledgerCaller=Get-Command Test-MorphospaceCommittedTransitionLedger -ErrorAction SilentlyContinue
$callerPathComparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
$script:PlanningHadCallerProtocolCommon=$null-ne$protocolCaller-and$null-ne$protocolCaller.Module-and-not[string]::IsNullOrWhiteSpace([string]$protocolCaller.Module.Path)-and[IO.Path]::GetFullPath($protocolCaller.Module.Path).Equals([IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')),$callerPathComparison)
$script:PlanningHadCallerTransitionLedger=$null-ne$ledgerCaller-and$null-ne$ledgerCaller.Module-and-not[string]::IsNullOrWhiteSpace([string]$ledgerCaller.Module.Path)-and[IO.Path]::GetFullPath($ledgerCaller.Module.Path).Equals([IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')),$callerPathComparison)
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')
function Restore-MorphospacePlanningLifecycleModules {
    Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
    Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')
    if($script:PlanningHadCallerProtocolCommon){Microsoft.PowerShell.Core\Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Global}
    if($script:PlanningHadCallerTransitionLedger){Microsoft.PowerShell.Core\Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1') -Global}
}
function Assert-MorphospacePlanningLifecycleSchema([object]$Document,[string]$Name) {
    if(-not(Test-Json -Json ($Document|ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Join-Path (Split-Path $script:PlanningScriptsRoot -Parent) "schemas/$Name"))){throw "Planning lifecycle $Name contract is invalid."}
}

function Get-MorphospacePlanningLifecycleEvents([string]$Workspace,[object]$CapturedExpected=$null){
    $path=Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf
    $bytes=[IO.File]::ReadAllBytes($path)
    if($CapturedExpected){
        $length=[long]$CapturedExpected.events_length
        if($length-lt1-or$length-gt$bytes.LongLength){throw 'Planning lifecycle captured prefix length is invalid.'}
        $prefix=[byte[]]::new($length);[Array]::Copy($bytes,$prefix,$length)
        if((Get-MorphospaceSha256Bytes $prefix)-cne[string]$CapturedExpected.events_sha256){throw 'Planning lifecycle captured prefix bytes changed.'}
        $bytes=$prefix
    }
    if($bytes.Length-eq0-or$bytes.Length-gt67108864-or$bytes[-1]-ne10){throw 'Planning lifecycle requires a bounded LF-terminated event ledger.'}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    $events=@();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($line in @($text.Split([char]10))){
        if(-not$line){continue};$event=$line|ConvertFrom-Json -DateKind String
        $schema=switch -CaseSensitive ([string]$event.schema){
            'rusty.morphospace.workflow.iteration_event.v1' {'iteration-event.schema.json'}
            'rusty.morphospace.workflow.iteration_event.v2' {'iteration-event-v2.schema.json'}
            default {throw 'Planning lifecycle event schema is unsupported.'}
        }
        Assert-MorphospacePlanningLifecycleSchema $event $schema
        if(-not$seen.Add([string]$event.event_id)-or[int]$event.sequence-ne($events.Count+1)){throw 'Planning lifecycle event sequence or identity is invalid.'}
        $events+=,$event
    }
    if($CapturedExpected-and[string]$events[-1].event_id-cne[string]$CapturedExpected.event_tail_id){throw 'Planning lifecycle captured prefix tail differs from its bytes.'}
    [pscustomobject]@{events=$events;sha256=Get-MorphospaceSha256Bytes $bytes;length=[long]$bytes.Length;tail_id=[string]$events[-1].event_id}
}
function Get-MorphospacePlanningLifecycleCanonicalRawSha256([object]$Document){Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $Document)}

function Get-MorphospacePlanningLifecycleTransition([string]$Workspace,[string]$TransactionId,[switch]$HistoricalProjection){
    if(-not$HistoricalProjection){return Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $TransactionId -ExpectedEventsPath 'iteration-events.jsonl'}
    $ledger=Get-Module MorphospaceTransitionLedger -All|Where-Object{[IO.Path]::GetFullPath($_.Path)-ceq[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1'))}|Select-Object -First 1
    if($null-eq$ledger){throw 'Planning lifecycle planning transition-ledger verifier is unavailable.'}
    &$ledger {param($root,$id)
        $intentRelative=Get-MorphospaceLedgerPath $root $id intent;$completionRelative=Get-MorphospaceLedgerPath $root $id completion;$intentAbsolute=Resolve-MorphospaceWorkspacePath $root $intentRelative -RequireLeaf;$completionAbsolute=Resolve-MorphospaceWorkspacePath $root $completionRelative -RequireLeaf
        $intent=Read-MorphospaceLedgerJson $intentAbsolute;Assert-MorphospaceLedgerIntent $intent $id;Assert-MorphospaceLedgerArtifactNamespace $root $id $intent;$completion=Read-MorphospaceLedgerJson $completionAbsolute
        Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Planning lifecycle historical planning completion';Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Planning lifecycle historical planning completion intent'
        if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or[string]$completion.transaction_id-cne$id-or[string]$completion.status-cne'committed'-or[string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$intentRelative-or[string]$completion.intent.schema-cne[string]$intent.schema-or[string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $intentAbsolute)-or[string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256-or[string]$completion.event_id-cne[string]$intent.event.event_id){throw 'Planning lifecycle historical planning completion is detached.'}
        if((Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))-lt(Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))){throw 'Planning lifecycle historical planning completion timestamp is invalid.'}
        [void](Assert-MorphospaceLedgerEventPlacement (Resolve-MorphospaceWorkspacePath $root ([string]$intent.events.path) -RequireLeaf) $intent -AllowHistorical -RequirePresent)
        foreach($artifact in @($intent.artifacts)){$target=Resolve-MorphospaceWorkspacePath $root ([string]$artifact.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $target)-cne[string]$artifact.sha256){throw 'Planning lifecycle historical planning artifact differs from its intent.'}}
        [pscustomobject]@{intent=$intent;completion=$completion}
    } $Workspace $TransactionId
}

function Assert-MorphospacePlanningLifecycleContinuationEvents {
    param([object[]]$Events,[int]$AfterSequence,[string]$UnitId)
    for($index=0;$index-lt$Events.Count;$index++){
        $event=$Events[$index]
        if([int]$event.sequence-ne($AfterSequence+$index+1)-or[string]$event.unit_id-cne$UnitId-or[string]$event.event_id-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}-(?:recorded|tooling-context-upgraded)$'){throw 'Planning lifecycle planning continuation is not a contiguous same-unit authenticated transition suffix.'}
    }
}
function Get-MorphospacePlanningLifecycleToolingProofBindings {
    param([string]$WorkspaceRoot,[object]$Request,[object]$Context)
    $bindings=@{};$documents=@{}
    foreach($binding in @($Request.compatibility_receipt,$Context.executor.publication_evidence,$Context.compatibility.receipt)){
        $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$binding.path)
        $hash=[string]$binding.sha256
        if($bindings.ContainsKey($relative)-and[string]$bindings[$relative]-cne$hash){throw "Planning lifecycle tooling proof '$relative' has conflicting bindings."}
        $path=Resolve-MorphospaceWorkspacePath $WorkspaceRoot $relative -RequireLeaf
        if((Get-MorphospaceFileSha256 $path)-cne$hash){throw "Planning lifecycle tooling proof '$relative' differs from its authenticated binding."}
        $bindings[$relative]=$hash;$documents[$relative]=Read-MorphospaceProtocolJson $path
    }
    $compatibility=$documents[[string]$Request.compatibility_receipt.path]
    $publication=$documents[[string]$Context.executor.publication_evidence.path]
    $protocol=$documents[[string]$Context.compatibility.receipt.path]
    foreach($binding in @($compatibility.validation.evidence,$publication.validation,$protocol.validation)){
        $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$binding.path)
        $hash=[string]$binding.sha256
        if($bindings.ContainsKey($relative)-and[string]$bindings[$relative]-cne$hash){throw "Planning lifecycle tooling proof '$relative' has conflicting bindings."}
        $path=Resolve-MorphospaceWorkspacePath $WorkspaceRoot $relative -RequireLeaf
        if((Get-MorphospaceFileSha256 $path)-cne$hash){throw "Planning lifecycle tooling proof '$relative' differs from its authenticated binding."}
        $bindings[$relative]=$hash
    }
    @($bindings.Keys|Sort-Object -CaseSensitive|ForEach-Object{[pscustomobject]@{path=$_;sha256=[string]$bindings[$_]}})
}
function Get-MorphospacePlanningLifecycleProjectionEvidenceFromAuthenticatedAdmission {
    param([string]$Workspace,[object]$Unit,[object]$RepositoryEntry,[string[]]$StatusPorcelain,[Parameter(Mandatory)][object]$Admission,[object]$RecoveryIntent=$null,[string]$LockedCommit='',[string]$ObservedHead='',[object]$CapturedExpected=$null,[switch]$HistoricalOnly)
    if([string]$RepositoryEntry.role-cne'planning'){return $null}
    $committed=[bool]$LockedCommit
    if($committed-and(($StatusPorcelain.Count-ne0-and-not$RecoveryIntent)-or$ObservedHead-cnotmatch'^[0-9a-f]{40}$')){throw 'Planning lifecycle committed planning descendant requires a clean exact HEAD without recovery.'}
    if([string]::IsNullOrWhiteSpace($Workspace)){throw 'Planning lifecycle planning lifecycle workspace path is empty.'};if([string]::IsNullOrWhiteSpace([string]$RepositoryEntry.path)){throw 'Planning lifecycle planning lifecycle repository path is empty.'}
    if($null-eq$RecoveryIntent-and@($StatusPorcelain|Where-Object{[string]$_-cmatch'retire-.*-active-retired-transition'}).Count-ne0){throw 'Planning lifecycle planning lifecycle recovery intent was not forwarded.'}
    $repository=[IO.Path]::GetFullPath([string]$RepositoryEntry.path).TrimEnd('\','/');$workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $repositoryPrefix=$repository+[IO.Path]::DirectorySeparatorChar;$pathComparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$workspaceFull.StartsWith($repositoryPrefix,$pathComparison)){return $null}
    $workspacePrefix=[IO.Path]::GetRelativePath($repository,$workspaceFull).Replace('\','/').TrimEnd('/')+'/'
    $admission=$Admission
    $prefixExpected=if($RecoveryIntent){$RecoveryIntent.expected}else{$CapturedExpected}
    $eventObservation=Get-MorphospacePlanningLifecycleEvents $workspaceFull $prefixExpected;$events=$eventObservation.events
    $preparedId="$([string]$admission.preparation.preparation_id)-prepared";$admittedId="$([string]$admission.admission_id)-admitted"
    $prepared=@($events|Where-Object{[string]$_.event_id-ceq$preparedId});$admitted=@($events|Where-Object{[string]$_.event_id-ceq$admittedId});$claimed=@($events|Where-Object{[string]$_.unit_id-ceq[string]$Unit.unit_id-and[string]$_.event_id-cmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-claimed-[0-9]{4}$')})
    if($prepared.Count-ne1-or$admitted.Count-ne1-or$claimed.Count-ne1){throw 'Planning lifecycle planning lifecycle event identities are ambiguous.'}
    $from=[int]$prepared[0].sequence;$to=[int]$claimed[0].sequence;$suffix=@($events|Where-Object{[int]$_.sequence-ge$from-and[int]$_.sequence-le$to}|Sort-Object sequence)
    $direct=$suffix.Count-eq4-and[string]$suffix[0].event_id-ceq$preparedId-and[string]$suffix[1].event_id-ceq$admittedId-and[string]$suffix[2].event_id-cmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-ready-[0-9]{4}$')-and[string]$suffix[3].event_id-ceq[string]$claimed[0].event_id
    $replacement=$suffix.Count-eq6-and[string]$suffix[0].event_id-ceq$preparedId-and[string]$suffix[1].event_id-cmatch'-admitted$'-and[string]$suffix[2].event_id-cmatch'-proposal-retired-[0-9]{4}$'-and[string]$suffix[3].event_id-ceq$admittedId-and[string]$suffix[4].event_id-cmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-ready-[0-9]{4}$')-and[string]$suffix[5].event_id-ceq[string]$claimed[0].event_id
    if(-not$direct-and-not$replacement){throw 'Planning lifecycle planning lifecycle suffix is unsupported.'}
    for($index=0;$index-lt$suffix.Count;$index++){if([int]$suffix[$index].sequence-ne($from+$index)){throw 'Planning lifecycle planning lifecycle suffix is not contiguous.'}}
    $amendments=@($events|Where-Object{[int]$_.sequence-gt$to}|Sort-Object sequence)
    $amendmentModule=$null
    if($amendments.Count-ne0){
        $amendmentModule=Import-Module (Join-Path $PSScriptRoot '../ActiveWriteScopeAmendment.psm1') -Force -PassThru
        Restore-MorphospacePlanningLifecycleModules
        Assert-MorphospacePlanningLifecycleContinuationEvents -Events $amendments -AfterSequence $to -UnitId ([string]$Unit.unit_id)
    }
    $projectionSuffix=@($suffix)+@($amendments)
    $expected=@{};$recoveryOwned=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if($RecoveryIntent){foreach($relative in @([string]$RecoveryIntent.state.path,[string]$RecoveryIntent.unit.path,[string]$RecoveryIntent.events.path,"receipts/transactions/$($RecoveryIntent.transaction_id).intent.json","receipts/transactions/$($RecoveryIntent.transaction_id).completion.json")+@($RecoveryIntent.artifacts|ForEach-Object{[string]$_.path})+@($(if($RecoveryIntent.PSObject.Properties.Name-contains'additional_projections'){$RecoveryIntent.additional_projections|ForEach-Object{[string]$_.path}}else{@()}))){[void]$recoveryOwned.Add($relative)};for($artifactIndex=0;$artifactIndex-lt@($RecoveryIntent.artifacts).Count;$artifactIndex++){[void]$recoveryOwned.Add("receipts/transactions/$($RecoveryIntent.transaction_id).artifact-$artifactIndex.pending")}}
    function Set-PlanningProjection([string]$Relative,[string]$Sha){$relative=ConvertTo-MorphospaceProtocolRelativePath $Relative;$expected[$workspacePrefix+$relative]=$Sha}
    $preparationTransactionId="$preparedId-transition";$preparationIntentRelative="receipts/transactions/$preparationTransactionId.intent.json";$preparationCompletionRelative="receipts/transactions/$preparationTransactionId.completion.json"
    $preparationIntentPath=Resolve-MorphospaceWorkspacePath $workspaceFull $preparationIntentRelative -RequireLeaf;$preparationCompletionPath=Resolve-MorphospaceWorkspacePath $workspaceFull $preparationCompletionRelative -RequireLeaf
    $preparationIntent=Read-MorphospaceProtocolJson $preparationIntentPath;$preparationCompletion=Read-MorphospaceProtocolJson $preparationCompletionPath
    if([string]$preparationIntent.transaction_id-cne$preparationTransactionId-or[string]$preparationIntent.event.event_id-cne$preparedId-or[string]$preparationCompletion.transaction_id-cne$preparationTransactionId-or[string]$preparationCompletion.intent_sha256-cne(Get-MorphospaceFileSha256 $preparationIntentPath)-or[string]$preparationCompletion.event_id-cne$preparedId-or[string]$preparationCompletion.status-cne'committed'){throw 'Planning lifecycle planning preparation transaction is detached.'}
    if((Get-MorphospaceFileSha256 $preparationIntentPath)-cne(Get-MorphospacePlanningLifecycleCanonicalRawSha256 $preparationIntent)-or(Get-MorphospaceFileSha256 $preparationCompletionPath)-cne(Get-MorphospacePlanningLifecycleCanonicalRawSha256 $preparationCompletion)){throw 'Planning lifecycle planning preparation transaction bytes are non-canonical.'}
    if(@(Get-ChildItem -LiteralPath (Split-Path $preparationIntentPath -Parent) -File -Filter "$preparationTransactionId.artifact-*.pending").Count-ne0){throw 'Planning lifecycle planning lifecycle contains an orphan preparation pending artifact.'}
    foreach($name in @('project','state','feature_lock')){$projection=$preparationIntent.target.$name;Set-PlanningProjection ([string]$projection.path) (Get-MorphospacePlanningLifecycleCanonicalRawSha256 $projection.document)}
    foreach($artifact in @($preparationIntent.artifacts)){$artifactBytes=[Convert]::FromBase64String([string]$artifact.bytes_base64);Set-PlanningProjection ([string]$artifact.path) (Get-MorphospaceSha256Bytes $artifactBytes)}
    Set-PlanningProjection $preparationIntentRelative (Get-MorphospaceFileSha256 $preparationIntentPath);Set-PlanningProjection $preparationCompletionRelative (Get-MorphospaceFileSha256 $preparationCompletionPath)
    $lastUnit=$Admission.unit;$lastState=$preparationIntent.target.state.document;$lastProject=$preparationIntent.target.project.document;$lastFeatureLock=$preparationIntent.target.feature_lock.document
    foreach($event in @($projectionSuffix|Select-Object -Skip 1)){
        $transactionId="$([string]$event.event_id)-transition";$proof=Get-MorphospacePlanningLifecycleTransition -Workspace $workspaceFull -TransactionId $transactionId -HistoricalProjection
        if((Get-MorphospaceCanonicalJsonSha256 $proof.intent.event)-cne(Get-MorphospaceCanonicalJsonSha256 $event)){throw 'Planning lifecycle planning lifecycle event is detached from its transaction.'}
        if([int]$event.sequence-gt[int]$admitted[0].sequence-and[int]$event.sequence-le$to){
            if([string]$proof.intent.pre.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $lastUnit)-or[string]$proof.intent.pre.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $lastState)){throw 'Planning Ready or Claim predecessor differs from authenticated prior unit or state.'}
            $ready=[int]$event.sequence-eq([int]$admitted[0].sequence+1);$slug=if($ready){'ready'}else{'claimed'};$status=if($ready){'ready'}else{'active'}
            $summary=if($ready){'Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites.'}else{'Claimed one ready iteration unit without expanding repository or path scope.'}
            $targetUnit=$proof.intent.target.unit.document;$targetState=$proof.intent.target.state.document
            if([string]$event.event_type-cne'state-transition'-or[string]$event.event_id-cnotmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-'+$slug+'-[0-9]{4}$')-or[string]$event.summary-cne$summary-or@($event.receipts).Count-ne0-or[string]$targetUnit.status-cne$status){throw 'Planning Ready or Claim is not the ordinary owner transition.'}
            $baseContinuationModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceDevelopmentContinuation.psm1') -PassThru
            &$baseContinuationModule {param($before,$after,$slug)Assert-DevelopmentContinuationStableAuthority $before $after @('status') $slug} $lastUnit $targetUnit $slug
            if(($ready-and($null-ne$targetState.current_unit-or[string]$targetState.next_ready_unit-cne[string]$Unit.unit_id))-or(-not$ready-and([string]$targetState.current_unit-cne[string]$Unit.unit_id-or$null-ne$targetState.next_ready_unit))){throw 'Planning Ready or Claim selector differs from ordinary owner authority.'}
        }
        if([int]$event.sequence-gt$to){
            if([string]$proof.intent.pre.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $lastUnit)-or[string]$proof.intent.pre.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $lastState)){throw 'Planning continuation predecessor differs from authenticated terminal unit or state.'}
            $artifactSchemas=@($proof.intent.artifacts|ForEach-Object{[string](ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))).schema})
            if($artifactSchemas-ccontains'rusty.morphospace.workflow.active_development_envelope_extension.v1'){
                $extensionModule=Import-Module (Join-Path $PSScriptRoot '../ActiveDevelopmentEnvelopeExtension.psm1') -PassThru
                $null=&$extensionModule {param($root,$expected,$transition) Assert-ActiveEnvelopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $expected -Transition $transition} $workspaceFull $event $proof
                $extensionRequest=@($proof.intent.artifacts|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))}|Where-Object{[string]$_.schema-ceq'rusty.morphospace.workflow.active_development_envelope_extension.v1'})[0]
                Set-PlanningProjection ([string]$extensionRequest.effective_repository_map.path) ([string]$extensionRequest.effective_repository_map.raw_sha256)
            }elseif($artifactSchemas-ccontains'rusty.morphospace.workflow.tooling_context_upgrade.v1'){
                $toolingModule=Import-Module (Join-Path $PSScriptRoot '../ToolingContextUpgrade.psm1') -PassThru
                $null=&$toolingModule {param($root,$expected,$transition) Assert-ToolingContextHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $expected -Transition $transition} $workspaceFull $event $proof
                $documents=@($proof.intent.artifacts|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))})
                $request=@($documents|Where-Object{[string]$_.schema-ceq'rusty.morphospace.workflow.tooling_context_upgrade.v1'})
                $context=@($documents|Where-Object{[string]$_.schema-ceq'rusty.morphospace.workflow.tooling_context.v1'})
                if($request.Count-ne1-or$context.Count-ne1){throw 'Planning lifecycle tooling upgrade proof artifacts are ambiguous.'}
                foreach($binding in @(Get-MorphospacePlanningLifecycleToolingProofBindings -WorkspaceRoot $workspaceFull -Request $request[0] -Context $context[0])){Set-PlanningProjection ([string]$binding.path) ([string]$binding.sha256)}
            }elseif($artifactSchemas-ccontains'rusty.morphospace.workflow.work_unit_automation_receipt.v1'){
                if((Get-MorphospaceCanonicalJsonSha256 $lastUnit)-cne[string]$proof.intent.pre.unit.sha256-or$null-eq$lastState){throw 'Planning instruction completion has no exact predecessor projection.'}
                $continuationModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceDevelopmentContinuation.psm1') -PassThru
                &$continuationModule {param($before,$after,$intent,$event) Assert-DevelopmentContinuationRetainedAuthority $before $after $intent $event} $lastUnit $proof.intent.target.unit.document $proof.intent $event
                $beforeSurfaces=Get-MorphospaceCanonicalJsonSha256 $lastUnit.instruction_surfaces
                if($beforeSurfaces-ceq(Get-MorphospaceCanonicalJsonSha256 $proof.intent.target.unit.document.instruction_surfaces)){throw 'Planning instruction completion must complete declared planned surfaces.'}
                $stateProjection=ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $lastState);$stateProjection.last_event_id=[string]$event.event_id
                if((Get-MorphospaceCanonicalJsonSha256 $lastState)-cne[string]$proof.intent.pre.state.sha256-or(Get-MorphospaceCanonicalJsonSha256 $stateProjection)-cne[string]$proof.intent.target.state.sha256){throw 'Planning instruction completion changes state outside its exact event readback.'}
            }else{
                $null=&$amendmentModule {param($root,$expected,$transition) Assert-ActiveWriteScopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $expected -Transition $transition} $workspaceFull $event $proof
            }
        }
        $lastUnit=$proof.intent.target.unit.document;$lastState=$proof.intent.target.state.document
        $intentRelative="receipts/transactions/$transactionId.intent.json";$completionRelative="receipts/transactions/$transactionId.completion.json";$intentPath=Resolve-MorphospaceWorkspacePath $workspaceFull $intentRelative -RequireLeaf;$completionPath=Resolve-MorphospaceWorkspacePath $workspaceFull $completionRelative -RequireLeaf
        if((Get-MorphospaceFileSha256 $intentPath)-cne(Get-MorphospacePlanningLifecycleCanonicalRawSha256 $proof.intent)-or(Get-MorphospaceFileSha256 $completionPath)-cne(Get-MorphospacePlanningLifecycleCanonicalRawSha256 $proof.completion)){throw 'Planning lifecycle planning lifecycle transaction bytes are non-canonical.'}
        if(@(Get-ChildItem -LiteralPath (Split-Path $intentPath -Parent) -File -Filter "$transactionId.artifact-*.pending").Count-ne0){throw 'Planning lifecycle planning lifecycle contains an orphan committed pending artifact.'}
        Set-PlanningProjection ([string]$proof.intent.state.path) (Get-MorphospacePlanningLifecycleCanonicalRawSha256 $proof.intent.target.state.document);Set-PlanningProjection ([string]$proof.intent.unit.path) (Get-MorphospacePlanningLifecycleCanonicalRawSha256 $proof.intent.target.unit.document)
        foreach($projection in @($(if($proof.intent.PSObject.Properties.Name-contains'additional_projections'){$proof.intent.additional_projections}else{@()}))){Set-PlanningProjection ([string]$projection.path) (Get-MorphospacePlanningLifecycleCanonicalRawSha256 $projection.document);if([string]$projection.path-ceq'project.spec.json'){$lastProject=$projection.document};if([string]$projection.path-ceq'feature.lock.json'){$lastFeatureLock=$projection.document}}
        foreach($artifact in @($proof.intent.artifacts)){$artifactBytes=[Convert]::FromBase64String([string]$artifact.bytes_base64);if((Get-MorphospaceSha256Bytes $artifactBytes)-cne[string]$artifact.sha256){throw 'Planning lifecycle planning lifecycle artifact payload is detached.'};Set-PlanningProjection ([string]$artifact.path) ([string]$artifact.sha256)}
        Set-PlanningProjection $intentRelative (Get-MorphospaceFileSha256 $intentPath);Set-PlanningProjection $completionRelative (Get-MorphospaceFileSha256 $completionPath)
    }
    $committedOwn=@{}
    if($committed-and$RecoveryIntent){
        $own=Get-MorphospaceCommittedPlanningFreezeProjection -Workspace $workspaceFull -Repository $repository -WorkspacePrefix $workspacePrefix -Intent $RecoveryIntent -Head $ObservedHead -BeforeState $lastState -BeforeUnit $lastUnit
        if($null-ne$own){foreach($binding in @($own.bindings)){$committedOwn[[string]$binding.path]=$binding}}
    }
    $authority=[pscustomobject]@{unit=$lastUnit;state=$lastState;project=$lastProject;feature_lock=$lastFeatureLock;assessment=$lastUnit.agent_scope_assessment}
    if($HistoricalOnly){return $authority}
    Set-PlanningProjection 'iteration-events.jsonl' (Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspaceFull 'iteration-events.jsonl' -RequireLeaf))
    if($committed){
        $staged=@(& git -C $repository diff --cached --name-only --no-renames -- 2>&1);if($LASTEXITCODE-ne0-or$staged.Count-ne0){throw 'Planning lifecycle committed planning descendant must remain clean.'}
        foreach($path in @($expected.Keys)){if($recoveryOwned.Contains($path.Substring($workspacePrefix.Length))){continue};$live=Join-Path $repository $path;if(-not[IO.File]::Exists($live)-or(Get-MorphospaceFileSha256 $live)-cne[string]$expected[$path]){throw "Planning lifecycle committed planning projection is damaged: $path"}}
        $changed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $cursor=$ObservedHead
        while($cursor-cne$LockedCommit){
            $line=(@(& git -C $repository rev-list --parents -n 1 $cursor 2>&1)-join'').Trim()
            if($LASTEXITCODE-ne0-or$line-cnotmatch'^[0-9a-f]{40} [0-9a-f]{40}$'){throw 'Planning lifecycle committed planning descendant must have linear authenticated history.'}
            $parent=$line.Substring(41)
            $paths=@(& git -C $repository diff --name-only --no-renames $parent $cursor -- 2>&1)
            if($LASTEXITCODE-ne0){throw 'Planning lifecycle committed planning descendant diff failed.'}
            foreach($path in $paths){
                $relative=([string]$path).Replace('\','/')
                if($committedOwn.ContainsKey($relative)){
                    $ownedAtCommit=@(&git -C $repository rev-parse --verify ($cursor+':'+[string]$own.receipt_path) 2>$null)
                    if($LASTEXITCODE-eq0-or-not$expected.ContainsKey($relative)){Assert-MorphospaceCommittedPlanningFreezeProjectionAtCommit -Repository $repository -Commit $cursor -Bindings @($own.bindings)}
                }elseif(-not$expected.ContainsKey($relative)){throw "Planning lifecycle committed planning descendant changes unauthenticated path: $relative"}
                [void]$changed.Add($relative)
            }
            $cursor=$parent
        }
        $final=@(& git -C $repository diff --name-only --no-renames $LockedCommit $ObservedHead -- 2>&1)
        if($LASTEXITCODE-ne0){throw 'Planning lifecycle committed planning descendant final diff failed.'}
        foreach($path in $final){if(-not$expected.ContainsKey(([string]$path).Replace('\','/'))-and-not$committedOwn.ContainsKey(([string]$path).Replace('\','/'))){throw 'Planning lifecycle committed planning descendant final projection is unauthenticated.'}}
        if($changed.Count-eq0){throw 'Planning lifecycle committed planning descendant contains no lifecycle projection.'}
        if(-not$RecoveryIntent){return $authority}
    }
    $staged=@(& git -C $repository diff --cached --name-only --no-renames -- 2>&1|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')});if($LASTEXITCODE-ne0-or$staged.Count-ne0){throw 'Planning lifecycle planning lifecycle dirt must not be staged.'}
    $changes=@();foreach($line in @($StatusPorcelain)){$value=[string]$line;if($value.Length-lt4-or$value.Substring(0,2)-cnotin@(' M','??')){throw 'Planning lifecycle planning lifecycle dirt contains a staged, deleted, renamed, conflicted, or unsupported entry.'};$gitPath=$value.Substring(3).Replace('\','/');if($RecoveryIntent-and$gitPath.StartsWith($workspacePrefix,[StringComparison]::Ordinal)-and$recoveryOwned.Contains($gitPath.Substring($workspacePrefix.Length))){continue};$changes+=,$gitPath};$changes=@($changes|Sort-Object -Unique)
    $allowed=@();foreach($path in @($expected.Keys|Sort-Object)){if($recoveryOwned.Contains($path.Substring($workspacePrefix.Length))){continue};$live=Join-Path $repository $path;if(-not[IO.File]::Exists($live)-or(Get-MorphospaceFileSha256 $live)-cne[string]$expected[$path]){throw "Planning lifecycle planning lifecycle projection is damaged: $path"};$null=& git -C $repository diff --quiet HEAD -- $path 2>&1;if($LASTEXITCODE-ne0){$allowed+=,$path}else{$null=& git -C $repository ls-files --error-unmatch -- $path 2>&1;if($LASTEXITCODE-ne0){$allowed+=,$path}}};$allowed=@($allowed|Sort-Object -Unique)
    if($changes.Count-ne$allowed.Count-or($changes-join'|')-cne($allowed-join'|')){throw "Planning lifecycle planning repository dirt differs from the authenticated lifecycle projection (expected: $($allowed-join', '); observed: $($changes-join', '))."}
    return $authority
}
function Test-MorphospacePlanningLifecycleProjectionFromAuthenticatedAdmission {
    param([string]$Workspace,[object]$Unit,[object]$RepositoryEntry,[string[]]$StatusPorcelain,[Parameter(Mandatory)][object]$Admission,[object]$RecoveryIntent=$null,[string]$LockedCommit='',[string]$ObservedHead='',[object]$CapturedExpected=$null,[switch]$HistoricalOnly)
    return $null-ne(Get-MorphospacePlanningLifecycleProjectionEvidenceFromAuthenticatedAdmission @PSBoundParameters)
}

# Observed HEAD is a local lifecycle readback. It never replaces a source pin.
function Test-MorphospacePlanningLifecycleReadOnlyPath {
    param([string]$Path,[string[]]$Declared)
    foreach($entry in $Declared){$base=ConvertTo-MorphospaceProtocolRelativePath ([string]$entry).TrimEnd('/');if($Path-ceq$base-or$Path.StartsWith($base+'/',[StringComparison]::Ordinal)){return $true}}
    return $false
}
function Assert-MorphospaceCommittedPlanningFreezeProjectionAtCommit {
    param([string]$Repository,[string]$Commit,[object[]]$Bindings)
    foreach($binding in $Bindings){
        $blob=@(&git -C $Repository rev-parse --verify ($Commit+':'+[string]$binding.path) 2>$null)
        if($LASTEXITCODE-ne0-or$blob.Count-ne1-or[string]$blob[0]-cne[string]$binding.blob_sha1){throw 'Committed own Freeze path is not part of the exact authenticated complete projection.'}
    }
}
function Get-MorphospaceCommittedPlanningFreezeProjection {
    param([string]$Workspace,[string]$Repository,[string]$WorkspacePrefix,[object]$Intent,[string]$Head,[object]$BeforeState,[object]$BeforeUnit)
    $documents=@($Intent.artifacts|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))})
    if($documents.Count-ne1-or[string]$documents[0].schema-cne'rusty.morphospace.workflow.candidate_freeze.v1'){return $null}
    $completionRelative="receipts/transactions/$($Intent.transaction_id).completion.json"
    $headCompletion=@(&git -C $Repository rev-parse --verify ($Head+':'+$WorkspacePrefix+$completionRelative) 2>$null)
    if($LASTEXITCODE-ne0){return $null}
    $candidate=$documents[0];$receiptRelative=[string]$Intent.artifacts[0].path
    $targetUnit=ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $BeforeUnit)
    if($targetUnit.PSObject.Properties.Name-contains'candidate_freeze'){throw 'Committed own Freeze predecessor already contains a frozen marker.'}
    $targetUnit|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue ([ordered]@{freeze_id=$candidate.freeze_id;receipt_path=$receiptRelative;receipt_sha256=[string]$Intent.artifacts[0].sha256})
    $targetState=ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $BeforeState);$targetState.last_event_id=[string]$Intent.event.event_id
    if((Get-MorphospaceCanonicalJsonSha256 $BeforeUnit)-cne[string]$Intent.pre.unit.sha256-or(Get-MorphospaceCanonicalJsonSha256 $BeforeState)-cne[string]$Intent.pre.state.sha256-or(Get-MorphospaceCanonicalJsonSha256 $targetUnit)-cne[string]$Intent.target.unit.sha256-or(Get-MorphospaceCanonicalJsonSha256 $targetState)-cne[string]$Intent.target.state.sha256){throw 'Committed own Freeze changes authority outside its exact derived marker and event.'}
    $freezeModule=Import-Module (Join-Path $PSScriptRoot '../CandidateFreeze.psm1') -PassThru
    $proof=&$freezeModule {param($root,$candidate,$state,$unit,$receipt) Assert-MorphospaceFrozenCandidateScope $candidate $unit;Get-MorphospaceFrozenCandidateTransition $root $candidate $state $unit $receipt} $Workspace $candidate $Intent.target.state.document $Intent.target.unit.document $receiptRelative
    Restore-MorphospacePlanningLifecycleModules
    if((Get-MorphospaceCanonicalJsonSha256 $proof.intent)-cne(Get-MorphospaceCanonicalJsonSha256 $Intent)){throw 'Committed own Freeze is detached from its authenticated transition.'}
    $events=Get-MorphospacePlanningLifecycleEvents $Workspace
    if([string]$events.tail_id-cne[string]$Intent.event.event_id){throw 'Committed own Freeze must remain the exact current event tail.'}
    $relativePaths=@([string]$Intent.state.path,[string]$Intent.unit.path,[string]$Intent.events.path,[string]$Intent.artifacts[0].path,"receipts/transactions/$($Intent.transaction_id).intent.json",$completionRelative)+@($Intent.additional_projections|ForEach-Object{[string]$_.path})
    $bindings=@()
    foreach($relative in @($relativePaths|Sort-Object -Unique)){
        $absolute=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf
        $blob=@(&git -C $Repository hash-object --no-filters -- $absolute 2>$null)
        if($LASTEXITCODE-ne0-or$blob.Count-ne1){throw 'Committed own Freeze blob observation failed.'}
        $bindings+=,[pscustomobject]@{path=$WorkspacePrefix+$relative;blob_sha1=[string]$blob[0]}
    }
    Assert-MorphospaceCommittedPlanningFreezeProjectionAtCommit -Repository $Repository -Commit $Head -Bindings $bindings
    [pscustomobject]@{bindings=$bindings;receipt_path=$WorkspacePrefix+$receiptRelative}
}
function Assert-MorphospacePlanningLifecycleOwnedIntent {
    param([string]$Workspace,[object]$Intent)
    $ledger=Get-Module MorphospaceTransitionLedger -All|Where-Object{[IO.Path]::GetFullPath($_.Path)-ceq[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1'))}|Select-Object -First 1
    &$ledger {param($root,$intent)
        Assert-MorphospaceLedgerIntent $intent ([string]$intent.transaction_id)
        Assert-MorphospaceLedgerArtifactNamespace $root ([string]$intent.transaction_id) $intent
        [void](Assert-MorphospaceLedgerEventPlacement (Resolve-MorphospaceWorkspacePath $root ([string]$intent.events.path) -RequireLeaf) $intent -AllowHistorical)
    } $Workspace $Intent
    foreach($binding in @(@{path=$Intent.state.path;pre=$Intent.pre.state.sha256;target=$Intent.target.state.sha256},@{path=$Intent.unit.path;pre=$Intent.pre.unit.sha256;target=$Intent.target.unit.sha256})+@($(if($Intent.PSObject.Properties.Name-contains'additional_projections'){@($Intent.additional_projections|ForEach-Object{@{path=$_.path;pre=$_.pre_sha256;target=$_.target_sha256}})}else{@()}))){
        $value=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$binding.path) -RequireLeaf)
        $hash=Get-MorphospaceCanonicalJsonSha256 $value
        if($hash-cne[string]$binding.pre-and$hash-cne[string]$binding.target){throw 'Planning lifecycle own intent projection is neither its authenticated preimage nor target.'}
    }
    $intentPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($Intent.transaction_id).intent.json" -RequireLeaf
    if((Get-MorphospaceFileSha256 $intentPath)-cne(Get-MorphospacePlanningLifecycleCanonicalRawSha256 $Intent)){throw 'Planning lifecycle own intent bytes are detached.'}
    $index=0
    foreach($artifact in @($Intent.artifacts)){
        foreach($relative in @([string]$artifact.path,"receipts/transactions/$($Intent.transaction_id).artifact-$index.pending")){
            $path=Resolve-MorphospaceWorkspacePath $Workspace $relative
            if([IO.File]::Exists($path)-and(Get-MorphospaceFileSha256 $path)-cne[string]$artifact.sha256){throw 'Planning lifecycle own artifact bytes are detached.'}
        };$index++
    }
    $completionPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($Intent.transaction_id).completion.json"
    if([IO.File]::Exists($completionPath)){[void](Get-MorphospacePlanningLifecycleTransition $Workspace ([string]$Intent.transaction_id) -HistoricalProjection)}
}
function Assert-MorphospaceReadOnlyPlanningLifecycleProjection {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][object]$Unit,[Parameter(Mandatory)][object]$RepositoryEntry,[Parameter(Mandatory)][object]$Dependency,[Parameter(Mandatory)][string]$LockedCommit,[Parameter(Mandatory)][string]$LockedTree,[object]$CapturedExpected=$null,[object]$RecoveryIntent=$null,[switch]$HistoricalOnly,[int]$BeforeSequence=0,[string]$PendingExtensionPath,[string]$ExpectedPendingExtensionSha256)
    try{
    Restore-MorphospacePlanningLifecycleModules
    $recordedExtensionIntent=$null
    if($RecoveryIntent){
        $repositoryRoot=[IO.Path]::GetFullPath([string]$RepositoryEntry.path)
        $workspaceRelative=[IO.Path]::GetRelativePath($repositoryRoot,[IO.Path]::GetFullPath($Workspace)).Replace('\','/').TrimEnd('/')+'/'
        $committedOwn=$true
        foreach($relative in @("receipts/transactions/$($RecoveryIntent.transaction_id).intent.json","receipts/transactions/$($RecoveryIntent.transaction_id).completion.json")){
            $live=Resolve-MorphospaceWorkspacePath $Workspace $relative
            if(-not[IO.File]::Exists($live)){$committedOwn=$false;break}
            $pinBlob=@(&git -C $repositoryRoot rev-parse --verify ('HEAD:'+$workspaceRelative+$relative) 2>$null)
            if($LASTEXITCODE-ne0-or$pinBlob.Count-ne1){$committedOwn=$false;break}
            $liveBlob=@(&git -C $repositoryRoot hash-object --no-filters -- $live 2>$null)
            if($LASTEXITCODE-ne0-or$liveBlob.Count-ne1-or[string]$pinBlob[0]-cne[string]$liveBlob[0]){$committedOwn=$false;break}
        }
        # A committed continuation is verified as part of the complete owner
        # suffix. Only an uncommitted intent receives current-dirt exclusions.
        $ownSchemas=@($RecoveryIntent.artifacts|ForEach-Object{[string](ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))).schema})
        if($committedOwn-and$ownSchemas-ccontains'rusty.morphospace.workflow.active_development_envelope_extension.v1'){$recordedExtensionIntent=$RecoveryIntent;$RecoveryIntent=$null}
    }
    if([string]$RepositoryEntry.role-cne'planning'){throw 'Read-only planning projection requires the planning owner role.'}
    $repository=[IO.Path]::GetFullPath([string]$RepositoryEntry.path).TrimEnd('\','/');$root=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$root.StartsWith($repository+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'Read-only planning projection requires a strictly nested owner workspace.'}
    $tree=(@(&git -C $repository rev-parse "$LockedCommit^{tree}" 2>&1)-join'').Trim()
    if($LASTEXITCODE-ne0-or$tree-cne$LockedTree){throw 'Read-only planning source pin has no exact commit/tree object.'}
    $observationExpected=if($RecoveryIntent){$RecoveryIntent.expected}else{$CapturedExpected}
    $prefixEvents=Get-MorphospacePlanningLifecycleEvents $Workspace $observationExpected
    if($HistoricalOnly-and($null-eq$CapturedExpected-or$BeforeSequence-le0-or[int]$prefixEvents.events[-1].sequence-ge$BeforeSequence)){throw 'Historical planning projection requires an owner-captured strictly earlier prefix.'}
    $admissions=@(Get-ChildItem -LiteralPath (Join-Path $Workspace 'receipts') -Filter '*.json' -File|ForEach-Object{Read-MorphospaceProtocolJson $_.FullName}|Where-Object{[string]$_.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$_.unit_id-ceq[string]$Unit.unit_id})
    if($admissions.Count-ne1){throw 'Read-only planning projection requires exactly one owner admission.'}
    $admission=$admissions[0];Assert-MorphospacePlanningLifecycleSchema $admission 'development-unit-admission-v1.schema.json'
    $admitProof=Get-MorphospacePlanningLifecycleTransition $Workspace "$($admission.admission_id)-admitted-transition" -HistoricalProjection
    $admitArtifacts=@($admitProof.intent.artifacts|Where-Object{(Get-MorphospaceCanonicalJsonSha256 (ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))))-ceq(Get-MorphospaceCanonicalJsonSha256 $admission)})
    if($admitArtifacts.Count-ne1){throw 'Read-only planning admission is detached from its committed transaction.'}
    if((Get-MorphospaceCanonicalJsonSha256 $admission.unit)-cne(Get-MorphospaceCanonicalJsonSha256 $admitProof.intent.target.unit.document)-or[string]$admitProof.intent.event.unit_id-cne[string]$admission.unit_id-or(Get-MorphospaceCanonicalJsonSha256 $admission.unit.agent_scope_assessment)-cne(Get-MorphospaceCanonicalJsonSha256 $admission.agent_scope_assessment)){throw 'Read-only planning admitted unit or assessed scope differs from its exact transaction.'}
    Assert-MorphospacePlanningLifecycleSchema $admission.unit 'iteration-unit.schema.json'
    Assert-MorphospacePlanningLifecycleSchema $admission.agent_scope_assessment 'agent-scope-assessment-v1.schema.json'

    foreach($binding in @(@{path=$admission.preparation.receipt_path;sha=$admission.preparation.receipt_sha256},@{path=$admission.preparation.source_composition_path;sha=$admission.preparation.source_composition_sha256})){
        if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace ([string]$binding.path) -RequireLeaf))-cne[string]$binding.sha){throw 'Read-only planning preparation provenance bytes changed.'}
    }
    $preparationId=[string]$admission.preparation.preparation_id
    if(($admission.PSObject.Properties.Name-contains'admission_kind'-and[string]$admission.admission_kind-cne'ordinary')-or($admission.preparation.PSObject.Properties.Name-contains'preparation_kind'-and[string]$admission.preparation.preparation_kind-cne'ordinary')){throw 'Read-only planning projection requires ordinary owner preparation without historical reclassification.'}
    $preparationIntentPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$preparationId-prepared-transition.intent.json" -RequireLeaf
    $preparationIntent=Read-MorphospaceProtocolJson $preparationIntentPath
    if(($admission.PSObject.Properties.Name-contains'admission_kind'-and[string]$admission.admission_kind-cne'ordinary')-or($admission.preparation.PSObject.Properties.Name-contains'preparation_kind'-and[string]$admission.preparation.preparation_kind-cne'ordinary')-or($preparationIntent.PSObject.Properties.Name-contains'legacy_tooling_reclassification')){throw 'Read-only planning projection requires ordinary owner preparation without historical reclassification.'}
    $preparationEvent=@($prefixEvents.events|Where-Object{[string]$_.event_id-ceq"$preparationId-prepared"})
    if($preparationEvent.Count-ne1){throw 'Read-only planning preparation event is absent or ambiguous in its captured prefix.'}
    $historyModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceCurrentWorkHistory.psm1') -PassThru
    $preparationProof=&$historyModule {param($root,$path,$intent,$events,$event) Get-MorphospacePreparationStepEvidence -Workspace $root -IntentPath $path -Intent $intent -Events $events -ExpectedEvent $event} $Workspace $preparationIntentPath $preparationIntent $prefixEvents.events $preparationEvent[0]
    Restore-MorphospacePlanningLifecycleModules
    if($null-ne$preparationProof.chronology_fault){throw 'Read-only planning preparation completion predates its intent.'}
    $source=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$admission.preparation.source_composition_path) -RequireLeaf)
    $map=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$admission.expected.repository_map_path) -RequireLeaf)
    if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace ([string]$admission.expected.repository_map_path) -RequireLeaf))-cne[string]$admission.expected.repository_map_sha256){throw 'Read-only planning admitted repository map bytes changed.'}
    $receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$admission.preparation.receipt_path) -RequireLeaf)
    $scope=$admission.agent_scope_assessment;$envelope=$receipt.envelope
    foreach($axis in @('allowed_change_categories','allowed_effect_categories','allowed_permission_categories')){foreach($value in @($scope.$axis)){if(@($envelope.$axis)-cnotcontains$value){throw 'Read-only planning admission exceeds its prepared authority ceiling.'}}}
    if([string]$scope.public_private_boundary-cne[string]$envelope.public_private_boundary-or[string]$scope.build_envelope.class-cne[string]$envelope.build_envelope.class-or[string]$scope.device_envelope.requirement-cne[string]$envelope.device_envelope.requirement){throw 'Read-only planning admission changes its prepared boundary or build/device ceiling.'}
    foreach($profile in @($scope.build_envelope.allowed_profiles)){if(@($envelope.build_envelope.allowed_profiles)-cnotcontains[string]$profile){throw 'Read-only planning admission exceeds prepared build profiles.'}}
    foreach($kind in @($scope.device_envelope.allowed_kinds)){if(@($envelope.device_envelope.allowed_kinds)-cnotcontains[string]$kind){throw 'Read-only planning admission exceeds prepared device kinds.'}}
    foreach($owner in @($scope.owner_repositories)){$prepared=@($envelope.owner_repositories|Where-Object{[string]$_.repo_id-ceq[string]$owner.repo_id});if($prepared.Count-ne1){throw 'Read-only planning admission names an unprepared owner.'};foreach($path in @($owner.source_roots)){if(@($prepared[0].source_roots)-cnotcontains[string]$path){throw 'Read-only planning admission exceeds prepared owner roots.'}}}
    $provenanceModule=Import-Module (Join-Path $PSScriptRoot '../DevelopmentEnvelopeProvenance.psm1') -PassThru
    &$provenanceModule {param($admission,$envelope,$project,$source) Assert-PreparationProvenanceAdmissionClosure $admission $envelope $project $source} $admission $envelope $preparationIntent.target.project.document $source
    $admissionModule=Import-Module (Join-Path $PSScriptRoot '../DevelopmentUnitAdmission.psm1') -PassThru
    &$admissionModule {param($unit,$scope,$project) Assert-AdmissionPaths $unit $scope $project} $admission.unit $scope $preparationIntent.target.project.document
    Restore-MorphospacePlanningLifecycleModules
    $sourceRow=@($source.repositories|Where-Object{[string]$_.repo_id-ceq[string]$RepositoryEntry.repo_id})
    $mapRow=@($map.repositories|Where-Object{[string]$_.repo_id-ceq[string]$RepositoryEntry.repo_id})
    $dependencyRow=@($admission.unit.read_only_dependencies|Where-Object{[string]$_.repo_id-ceq[string]$RepositoryEntry.repo_id})
    if($sourceRow.Count-ne1-or$mapRow.Count-ne1-or$dependencyRow.Count-ne1-or[string]$sourceRow[0].role-cne'planning'-or[string]$sourceRow[0].commit-cne$LockedCommit-or[string]$sourceRow[0].tree-cne$LockedTree-or(Get-MorphospaceCanonicalJsonSha256 $mapRow[0])-cne(Get-MorphospaceCanonicalJsonSha256 $RepositoryEntry)){throw 'Read-only planning source pins or mapped owner are detached from authenticated admission.'}
    if($RecoveryIntent){Assert-MorphospacePlanningLifecycleOwnedIntent $Workspace $RecoveryIntent}
    $head='';$status=@()
    if(-not$HistoricalOnly){
        $head=(@(&git -C $repository rev-parse HEAD 2>&1)-join'').Trim()
        if($LASTEXITCODE-ne0){throw 'Read-only planning HEAD observation failed.'}
        $status=@(&git -C $repository -c core.quotepath=false status --porcelain=v1 --untracked-files=all 2>&1)
        if($LASTEXITCODE-ne0){throw 'Read-only planning dirt observation failed.'}
    }
    $arguments=@{Workspace=$Workspace;Unit=$Unit;RepositoryEntry=$RepositoryEntry;StatusPorcelain=@($status);Admission=$admission;RecoveryIntent=$RecoveryIntent;CapturedExpected=$CapturedExpected;HistoricalOnly=$HistoricalOnly}
    if(-not$HistoricalOnly-and$head-cne$LockedCommit){$arguments.LockedCommit=$LockedCommit;$arguments.ObservedHead=$head}
    $authority=Get-MorphospacePlanningLifecycleProjectionEvidenceFromAuthenticatedAdmission @arguments
    if($null-eq$authority){throw 'Read-only planning lifecycle projection is not authenticated.'}
    $effectiveDependency=@($authority.unit.read_only_dependencies|Where-Object{[string]$_.repo_id-ceq[string]$RepositoryEntry.repo_id})
    if($effectiveDependency.Count-ne1){throw 'Authenticated planning prefix has no exact read-only dependency row.'}
    $targetDependency=@();$pendingExtensionModule=$null
    if($PendingExtensionPath){
        if($HistoricalOnly-or$RecoveryIntent-or[string]::IsNullOrWhiteSpace($ExpectedPendingExtensionSha256)){throw 'Pending planning capture requires exact request identity before any owner intent.'}
        if((Get-MorphospaceFileSha256 $PendingExtensionPath)-cne$ExpectedPendingExtensionSha256){throw 'Pending planning extension request bytes changed.'}
        $pending=Read-MorphospaceProtocolJson $PendingExtensionPath;Assert-MorphospacePlanningLifecycleSchema $pending 'active-development-envelope-extension-v1.schema.json'
        if([string]$pending.unit_id-cne[string]$authority.unit.unit_id-or[string]$pending.expected.unit_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $authority.unit)-or[string]$pending.expected.state_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $authority.state)-or[string]$pending.expected.project_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $authority.project)-or[string]$pending.expected.feature_lock_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $authority.feature_lock)-or[string]$pending.expected.events_sha256-cne[string]$observationExpected.events_sha256-or[long]$pending.expected.events_length-ne[long]$observationExpected.events_length-or[string]$pending.expected.event_tail_id-cne[string]$observationExpected.event_tail_id){throw 'Pending planning extension is detached from terminal owner authority or prefix.'}
        foreach($binding in @(@{path='workspace.state.json';sha=$pending.expected.state_raw_sha256},@{path="iteration-units/$($authority.unit.unit_id).json";sha=$pending.expected.unit_raw_sha256},@{path='project.spec.json';sha=$pending.expected.project_raw_sha256},@{path='feature.lock.json';sha=$pending.expected.feature_lock_raw_sha256})){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $binding.path -RequireLeaf))-cne[string]$binding.sha){throw 'Pending planning extension raw owner preimage changed.'}}
        $terminalSourcePath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$authority.unit.source_composition.lock_path) -RequireLeaf
        $terminalSource=Read-MorphospaceProtocolJson $terminalSourcePath
        if([string]$pending.expected.source_composition_path-cne[string]$authority.unit.source_composition.lock_path-or[string]$pending.expected.source_composition_raw_sha256-cne(Get-MorphospaceFileSha256 $terminalSourcePath)-or[string]$pending.expected.source_composition_canonical_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $terminalSource)-or[string]$pending.expected.original_source_composition_path-cne[string]$admission.preparation.source_composition_path-or[string]$pending.expected.original_source_composition_raw_sha256-cne[string]$admission.preparation.source_composition_sha256){throw 'Pending planning extension source lineage differs from authenticated terminal and original provenance.'}
        $previousMapPath=if([string]$terminalSource.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){[string]$terminalSource.repository_map.path}else{[string]$admission.expected.repository_map_path}
        $previousMapHash=if([string]$terminalSource.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){[string]$terminalSource.repository_map.raw_sha256}else{[string]$admission.expected.repository_map_sha256}
        if([string]$pending.expected.repository_map_path-cne$previousMapPath-or[string]$pending.expected.repository_map_raw_sha256-cne$previousMapHash-or[string]$pending.expected.original_repository_map_path-cne[string]$admission.expected.repository_map_path-or[string]$pending.expected.original_repository_map_raw_sha256-cne[string]$admission.expected.repository_map_sha256){throw 'Pending planning extension map lineage differs from owner-derived terminal provenance.'}
        $previousMapFile=Resolve-MorphospaceWorkspacePath $Workspace $previousMapPath -RequireLeaf;$effectiveMapFile=Resolve-MorphospaceWorkspacePath $Workspace ([string]$pending.effective_repository_map.path) -RequireLeaf
        if((Get-MorphospaceFileSha256 $previousMapFile)-cne$previousMapHash-or(Get-MorphospaceFileSha256 $effectiveMapFile)-cne[string]$pending.effective_repository_map.raw_sha256){throw 'Pending planning extension map bytes changed.'}
        $pendingExtensionModule=Import-Module (Join-Path $PSScriptRoot '../ActiveDevelopmentEnvelopeExtension.psm1') -PassThru
        $targetUnit=&$pendingExtensionModule {param($root,$request,$authority,$originalMap,$previousMap,$effectiveMap) Assert-ActiveEnvelopeValidationCheckpoint -WorkspaceRoot $root -State $authority.state -CurrentUnitId $authority.unit.unit_id -Expected $request.expected;Assert-ActiveEnvelopeMapExtension $request $originalMap $previousMap $effectiveMap ([string]$request.expected.repository_map_path);Assert-ActiveEnvelopeTargetSemantics $request ([pscustomobject]@{effective=$authority}) $effectiveMap} $Workspace $pending $authority $map (Read-MorphospaceProtocolJson $previousMapFile) (Read-MorphospaceProtocolJson $effectiveMapFile)
        $targetDependency=@($targetUnit.read_only_dependencies|Where-Object{[string]$_.repo_id-ceq[string]$RepositoryEntry.repo_id})
    }elseif(($RecoveryIntent-or$recordedExtensionIntent)-and@($(if($RecoveryIntent){$RecoveryIntent.artifacts}else{$recordedExtensionIntent.artifacts})|Where-Object{[string](ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$_.bytes_base64))).schema-ceq'rusty.morphospace.workflow.active_development_envelope_extension.v1'}).Count-ne0){
        $extensionIntent=if($RecoveryIntent){$RecoveryIntent}else{$recordedExtensionIntent}
        $pendingExtensionModule=Import-Module (Join-Path $PSScriptRoot '../ActiveDevelopmentEnvelopeExtension.psm1') -PassThru
        $null=&$pendingExtensionModule {param($root,$intent)Assert-ActiveEnvelopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $intent.event -Transition ([pscustomobject]@{intent=$intent})} $Workspace $extensionIntent
        $predecessorAuthority=if($recordedExtensionIntent){Get-MorphospacePlanningLifecycleProjectionEvidenceFromAuthenticatedAdmission -Workspace $Workspace -Unit $Unit -RepositoryEntry $RepositoryEntry -StatusPorcelain @() -Admission $admission -CapturedExpected $extensionIntent.expected -HistoricalOnly}else{$authority}
        if([string]$extensionIntent.pre.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $predecessorAuthority.unit)-or[string]$extensionIntent.pre.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $predecessorAuthority.state)){throw 'Pending or recorded planning extension predecessor differs from authenticated terminal unit or state.'}
        $targetDependency=@($extensionIntent.target.unit.document.read_only_dependencies|Where-Object{[string]$_.repo_id-ceq[string]$RepositoryEntry.repo_id})
    }
    Restore-MorphospacePlanningLifecycleModules
    $dependencyHash=Get-MorphospaceCanonicalJsonSha256 $Dependency
    if($dependencyHash-cne(Get-MorphospaceCanonicalJsonSha256 $effectiveDependency[0])-and($targetDependency.Count-ne1-or$dependencyHash-cne(Get-MorphospaceCanonicalJsonSha256 $targetDependency[0]))){throw 'Planning dependency differs from exact owner-derived prefix or pending target scope.'}
    $paths=@(@($dependencyRow[0].paths)+@($effectiveDependency[0].paths)+@($targetDependency|ForEach-Object{$_.paths})|ForEach-Object{ConvertTo-MorphospaceProtocolRelativePath ([string]$_).TrimEnd('/')}|Sort-Object -Unique)
    if($paths.Count-eq0){throw 'Read-only planning projection requires declared content paths.'}
    if($HistoricalOnly){
        foreach($declared in $paths){$files=@(&git -C $repository ls-tree -r --name-only $LockedCommit -- $declared 2>&1);if($LASTEXITCODE-ne0-or$files.Count-eq0){throw 'Historical planning dependency path is absent from its immutable source pin.'}}
        return
    }
    foreach($declared in $paths){
        $files=@(&git -C $repository ls-tree -r --name-only $LockedCommit -- $declared 2>&1)
        if($LASTEXITCODE-ne0-or$files.Count-eq0){throw 'Read-only planning declared source content is absent at its pin.'}
        foreach($file in $files){
            $pin=(@(&git -C $repository rev-parse ($LockedCommit+':'+[string]$file) 2>&1)-join'').Trim()
            $live=Join-Path $repository ([string]$file)
            if(-not[IO.File]::Exists($live)){throw 'Read-only planning declared source content is missing.'}
            $blob=(@(&git -C $repository hash-object --no-filters -- $live 2>&1)-join'').Trim()
            if($LASTEXITCODE-ne0-or$pin-cne$blob){throw 'Read-only planning declared source bytes changed.'}
        }
        $contentDelta=@(&git -C $repository diff --name-only $LockedCommit HEAD -- $declared 2>&1)
        if($LASTEXITCODE-ne0-or$contentDelta.Count-ne0){throw 'Read-only planning declared source tree changed.'}
    }
    if(-not$HistoricalOnly){
        $cursor=$head
        while($cursor-cne$LockedCommit){
            $line=(@(&git -C $repository rev-list --parents -n 1 $cursor 2>&1)-join'').Trim()
            if($LASTEXITCODE-ne0-or$line-cnotmatch'^[0-9a-f]{40} [0-9a-f]{40}$'){throw 'Read-only planning history is not a linear descendant of its pin.'}
            $parent=$line.Substring(41);$changed=@(&git -C $repository diff --name-only --no-renames $parent $cursor -- 2>&1)
            if($LASTEXITCODE-ne0){throw 'Read-only planning intermediate commit diff failed.'}
            foreach($file in $changed){if(Test-MorphospacePlanningLifecycleReadOnlyPath ([string]$file) $paths){throw 'Read-only planning source changed in an intermediate commit.'}}
            $cursor=$parent
        }
    }
    }finally{Restore-MorphospacePlanningLifecycleModules}
}
Export-ModuleMember -Function Test-MorphospacePlanningLifecycleProjectionFromAuthenticatedAdmission,Assert-MorphospaceReadOnlyPlanningLifecycleProjection
