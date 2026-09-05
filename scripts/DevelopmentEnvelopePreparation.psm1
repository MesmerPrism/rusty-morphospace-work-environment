Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalSupersessionCompatibility.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceCurrentWorkHistory.psm1')

function Get-PreparationHash { param([object]$Value) Get-MorphospaceCanonicalJsonSha256 $Value }
function Get-PreparationFileHash { param([string]$Path) Get-MorphospaceFileSha256 $Path }
function Copy-PreparationValue { param([object]$Value) $Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -DateKind String }
function Get-PreparationPath { param([string]$Root,[string]$Relative) Resolve-MorphospaceWorkspacePath $Root $Relative }
function Get-PreparationTransactionId { param([string]$Id) "$Id-prepared-transition" }
function Get-PreparationEventId { param([string]$Id) "$Id-prepared" }
function Assert-PreparationHistoricalSupersessionAudit {
    param([string]$Workspace)
    $state=Read-MorphospaceProtocolJson (Get-PreparationPath $Workspace 'workspace.state.json')
    $unitDirectory=Get-PreparationPath $Workspace 'iteration-units'
    $units=@{};$paths=@{}
    foreach($unitFile in @(Get-ChildItem -LiteralPath $unitDirectory -Filter '*.json' -File)){
        $unit=Read-MorphospaceProtocolJson $unitFile.FullName;$unitId=[string]$unit.unit_id
        if($unitId-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'-or$units.ContainsKey($unitId)){throw 'Preparation unit history contains a missing, nonportable, or repeated unit identity.'}
        $relative="iteration-units/$unitId.json"
        if([IO.Path]::GetFullPath($unitFile.FullName)-cne(Get-PreparationPath $Workspace $relative)){throw "Preparation unit '$unitId' is not stored at its canonical path."}
        $units[$unitId]=$unit;$paths[$unitId]=$relative
    }
    $historical=@($units.Keys|Where-Object{[string]$units[$_].status-cne'accepted'})
    if($historical.Count-eq0){return}
    if($null-ne$state.current_unit-or$null-ne$state.next_ready_unit){throw 'Preparation rejects current or next-ready unit authority.'}
    foreach($unitId in $historical){if(@('active','validating')-cnotcontains[string]$units[$unitId].status){throw 'Preparation rejects future, terminal, or otherwise nonaccepted unit documents outside authenticated historical supersession.'}}
    $events=@(Get-Content -LiteralPath (Get-PreparationPath $Workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    $compatibility=Get-MorphospaceHistoricalSupersessionCompatibilityMap -WorkspaceRoot $Workspace -ProjectId ([string]$state.project_id)
    foreach($historicalId in $historical){
        $cursor=[string]$historicalId;$visited=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$event=$null
        while([string]$units[$cursor].status-cne'accepted'){
            if(-not$visited.Add($cursor)){throw "Preparation historical supersession chain for '$historicalId' is cyclic."}
            if(@('active','validating')-cnotcontains[string]$units[$cursor].status){throw "Preparation historical supersession chain for '$historicalId' does not terminate in accepted history."}
            $prefix="$cursor-superseded-by-"
            $matches=@($events|Where-Object{[string]$_.unit_id-ceq$cursor-and([string]$_.event_id).StartsWith($prefix,[StringComparison]::Ordinal)})
            if($matches.Count-ne1){throw "Preparation historical unit '$cursor' lacks exactly one canonical supersession event."}
            $event=$matches[0];$replacementId=([string]$event.event_id).Substring($prefix.Length)
            $expectedEventId=Get-MorphospaceSupersessionEventId -OldUnitId $cursor -ReplacementUnitId $replacementId
            if([string]$event.event_id-cne$expectedEventId-or[string]$event.event_type-cne'state-transition'-or-not$units.ContainsKey($replacementId)){throw "Preparation historical unit '$cursor' has a damaged or orphaned supersession replacement."}
            $transactionId="$expectedEventId-transition"
            $intentPath=Get-PreparationPath $Workspace "receipts/transactions/$transactionId.intent.json"
            $completionPath=Get-PreparationPath $Workspace "receipts/transactions/$transactionId.completion.json"
            $hasIntent=[IO.File]::Exists($intentPath);$hasCompletion=[IO.File]::Exists($completionPath)
            $compatibilityEdge=$(if($compatibility.ContainsKey($cursor)){$compatibility[$cursor]}else{$null})
            if($hasIntent-or$hasCompletion){
                if(-not$hasIntent-or-not$hasCompletion){throw "Preparation historical unit '$cursor' has an incomplete supersession transaction."}
                $intentDocument=Read-MorphospaceProtocolJson $intentPath
                if([string]$intentDocument.schema-ceq'rusty.morphospace.workflow.transition_ledger_intent.v2'){
                    $committed=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $transactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$paths[$replacementId]) -ExpectedEventsPath 'iteration-events.jsonl'
                    $binding=$committed.intent.supersession
                    if([string]$binding.old_unit_id-cne$cursor-or[string]$binding.new_unit_id-cne$replacementId-or
                       [string]$binding.old_unit.path-cne[string]$paths[$cursor]-or
                       [string]$binding.old_unit.sha256-cne(Get-PreparationHash $units[$cursor])-or
                       (Get-PreparationHash $binding.old_unit.document)-cne(Get-PreparationHash $units[$cursor])){
                        throw "Preparation historical unit '$cursor' differs from its authenticated supersession binding."
                    }
                }elseif($null-eq$compatibilityEdge-or[string]$compatibilityEdge.transaction_kind-cne'legacy-v1'){
                    throw "Preparation historical unit '$cursor' has an unsupported supersession transaction schema."
                }
            }else{
                if($null-eq$compatibilityEdge-or[string]$compatibilityEdge.transaction_kind-cne'absent'){throw "Preparation historical unit '$cursor' lacks its supersession transaction and exact compatibility proof."}
            }
            if($null-ne$compatibilityEdge-and([string]$compatibilityEdge.transaction_kind-ceq$(if($hasIntent){'legacy-v1'}else{'absent'}))){
                if([string]$compatibilityEdge.old_unit_id-cne$cursor-or[string]$compatibilityEdge.replacement_unit_id-cne$replacementId-or
                   [string]$compatibilityEdge.event_id-cne$expectedEventId-or[int]$compatibilityEdge.sequence-ne[int]$event.sequence-or
                   [string]$compatibilityEdge.old_document_sha256-cne(Get-PreparationHash $units[$cursor])-or
                   [string]$compatibilityEdge.replacement_document_sha256-cne(Get-PreparationHash $units[$replacementId])){
                    throw "Preparation historical unit '$cursor' differs from its exact compatibility proof."
                }
            }
            $cursor=$replacementId
        }
        $acceptPattern='^'+[regex]::Escape($cursor)+'-accepted-[0-9]{4,}$'
        $acceptEvents=@($events|Where-Object{[string]$_.unit_id-ceq$cursor-and[string]$_.event_type-ceq'state-transition'-and[string]$_.event_id-cmatch$acceptPattern})
        if($acceptEvents.Count-ne1){throw "Preparation historical supersession chain for '$historicalId' lacks exactly one accepted-history transition."}
        $acceptEvent=$acceptEvents[0]
        if([int]$acceptEvent.sequence-le[int]$event.sequence){throw "Preparation historical supersession chain for '$historicalId' does not precede its accepted-history transition."}
        $accepted=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId "$([string]$acceptEvent.event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$paths[$cursor]) -ExpectedEventsPath 'iteration-events.jsonl'
        if([string]$accepted.intent.target.unit.document.status-cne'accepted'-or
           (Get-PreparationHash $accepted.intent.target.unit.document)-cne(Get-PreparationHash $units[$cursor])-or
           $null-ne$accepted.intent.target.state.document.current_unit){throw "Preparation historical supersession chain for '$historicalId' has an unauthenticated accepted endpoint."}
    }
}
function Assert-PreparationHistoricalSupersessionClosure {
    param([string]$Workspace)
    $history = Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $Workspace -RequireIdle
    if (-not $history.authenticated) {
        # Existing bootstrap workspaces have no exemption from ordinary rules.
        Assert-PreparationHistoricalSupersessionAudit $Workspace
        return
    }
    foreach ($id in $history.units.Keys) {
        if ([string]$history.units[$id].status -cne 'accepted' -and -not $history.retired_ids.Contains($id)) {
            throw "Preparation rejects nonhistorical unit '$id' outside idle accepted authority."
        }
    }
}
function Get-PreparationSchemaPin {
    param([string]$Revision,[string]$SchemaFile)
    "https://raw.githubusercontent.com/MesmerPrism/rusty-morphospace-work-environment/$Revision/schemas/$SchemaFile"
}
function Get-PreparationPinnedRevision {
    param([string]$Uri,[string]$SchemaFile,[string]$Context)
    $pattern='^https://raw\.githubusercontent\.com/MesmerPrism/rusty-morphospace-work-environment/([0-9a-f]{40})/schemas/'+[regex]::Escape($SchemaFile)+'$'
    if($Uri-cnotmatch$pattern){throw "Preparation $Context schema pin is not an exact Work Environment revision."}
    $Matches[1]
}
function Get-PreparationLockFingerprint {
    param([object]$Lock)
    Get-MorphospaceFeatureLockFingerprint $Lock
}
function Get-PreparationModuleRegistry {
    param([object]$Project,[object]$FeatureLock)
    [pscustomobject][ordered]@{
        lock_revision=[int]$FeatureLock.revision
        lock_fingerprint=[string]$FeatureLock.lock_fingerprint
        modules=@($Project.modules|Where-Object{$_.selected-eq$true}|Sort-Object module_id|ForEach-Object{
            [pscustomobject][ordered]@{
                module_id=[string]$_.module_id
                owner_repo=[string]$_.source_repo
                maturity=[string]$_.maturity
                contract=[string]$_.contract
                contract_revision=[string]$_.contract_revision
            }
        })
    }
}
function Assert-PreparationLockAndRegistry {
    param([object]$Project,[object]$FeatureLock,[object]$State,[string]$Context)
    if(-not(Test-MorphospaceFeatureLockFingerprint $FeatureLock)){throw "Preparation $Context feature-lock fingerprint is stale or damaged."}
    $expectedRegistry=Get-PreparationModuleRegistry $Project $FeatureLock
    if((Get-PreparationHash $State.module_registry)-cne(Get-PreparationHash $expectedRegistry)){throw "Preparation $Context workspace module registry does not match the feature lock and selected modules."}
}
function New-PreparationAutomationReceipt {
    param([object]$Preparation,[string]$Timestamp,[bool]$Executed,[string]$Transition,[string]$ReceiptPath,[string]$InputHash,[object]$State,[string]$EventId)
    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$Preparation.project_id;unit_id=[string]$Preparation.predecessor_unit_id;action='PrepareDevelopmentEnvelope';timestamp=$Timestamp;executed=$Executed;transition=$Transition;status_before='accepted';status_after='accepted';current_unit_before=$State.current_unit;current_unit_after=$State.current_unit;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$ReceiptPath;sha256=$InputHash};event_id=$(if([string]::IsNullOrWhiteSpace($EventId)){$null}else{$EventId})}
}

function Assert-PreparationSchema {
    param([string]$RepoRoot,[string]$Path,[string]$Schema,[string]$Message)
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $Path) -SchemaFile (Join-Path $RepoRoot "schemas\\$Schema"))){throw $Message}
}
function Assert-PreparationRoots {
    param([object[]]$Rows,[object]$Project,[hashtable]$Map)
    $projectById=@{};foreach($repo in @($Project.repositories)){$projectById[[string]$repo.repo_id]=$repo}
    $seen=@{};foreach($row in @($Rows)){
        $id=[string]$row.repo_id;if(-not$projectById.ContainsKey($id)-or-not$Map.ContainsKey($id)){throw "Preparation repository '$id' is absent from project or repository map."}
        $roots=@($row.source_roots|ForEach-Object{([string]$_).Replace('\\','/')});if($roots.Count-ne@($roots|Sort-Object -Unique -CaseSensitive).Count){throw "Preparation repeats a source root for '$id'."}
        foreach($sourceRoot in $roots){$canonical=ConvertTo-MorphospaceProtocolRelativePath $sourceRoot.TrimEnd('/');$canonical=if($sourceRoot.EndsWith('/')){"$canonical/"}else{$canonical};if($canonical-cne$sourceRoot){throw "Preparation source root '$id/$sourceRoot' is not canonical."};foreach($other in @($seen[$id]|Where-Object{$null-ne$_})){if($canonical-eq$other-or$canonical.StartsWith($other.TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)-or$other.StartsWith($canonical.TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)){throw "Preparation source roots overlap for '$id'."}};$seen[$id]=@($seen[$id]|Where-Object{$null-ne$_})+$canonical
            $allowed=@($projectById[$id].allowed_paths|Where-Object{$canonical-eq$_-or$canonical.StartsWith(([string]$_).TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)});if($allowed.Count-eq0){throw "Preparation root '$id/$canonical' exceeds project authority."}
        }
    }
}
function Assert-PreparationAdditiveProject {
    param([object]$Current,[object]$Target,[bool]$AllowSchemaPinAdvance)
    if([string]$Current.project_id-cne[string]$Target.project_id-or[int]$Target.revision-ne([int]$Current.revision+1)){throw 'Preparation project identity or single revision advance is invalid.'}
    foreach($property in @('selected_features','denied_features','selected_modules','denied_modules','allowed_permissions','denied_permissions','data_classes')){
        foreach($value in @($Current.composition.$property)){if(@($Target.composition.$property)-cnotcontains$value){throw "Preparation removes current composition value '$property/$value'."}}
    }
    $currentRepos=@{};foreach($repo in @($Current.repositories)){$currentRepos[[string]$repo.repo_id]=$repo};$targetRepos=@{};foreach($repo in @($Target.repositories)){$targetRepos[[string]$repo.repo_id]=$repo}
    foreach($id in $currentRepos.Keys){if(-not$targetRepos.ContainsKey($id)-or(Get-PreparationHash $currentRepos[$id])-cne(Get-PreparationHash $targetRepos[$id])){throw "Preparation removes or rewrites repository '$id'."}}
    $currentProfiles=@{};foreach($profile in @($Current.validation_profiles)){$id=[string]$profile.profile_id;if($currentProfiles.ContainsKey($id)){throw "Preparation current project repeats validation profile '$id'."};$currentProfiles[$id]=$profile}
    $targetProfiles=@{};foreach($profile in @($Target.validation_profiles)){$id=[string]$profile.profile_id;if($targetProfiles.ContainsKey($id)){throw "Preparation target project repeats validation profile '$id'."};$targetProfiles[$id]=$profile}
    foreach($id in $currentProfiles.Keys){if(-not$targetProfiles.ContainsKey($id)-or(Get-PreparationHash $currentProfiles[$id])-cne(Get-PreparationHash $targetProfiles[$id])){throw "Preparation removes or rewrites validation profile '$id'."}}
    $mutable=@('revision','composition','repositories','validation_profiles');if($AllowSchemaPinAdvance){$mutable+=,'$schema'}
    foreach($property in @($Current.psobject.Properties.Name)){if($property -notin $mutable -and (Get-PreparationHash $Current.$property)-cne(Get-PreparationHash $Target.$property)){throw "Preparation rewrites non-envelope project property '$property'."}}
}
function Get-PreparationTargetState {
    param([object]$Preparation,[object]$Project,[object]$FeatureLock,[object]$State)
    $targetState=Copy-PreparationValue $State
    $pinProperty=$Preparation.envelope.psobject.Properties['schema_pin_revision']
    if($null-eq$pinProperty){
        if((Get-PreparationHash $Project.'$schema')-cne(Get-PreparationHash $Preparation.envelope.project.'$schema')-or(Get-PreparationHash $FeatureLock.'$schema')-cne(Get-PreparationHash $Preparation.envelope.feature_lock.'$schema')){throw 'Preparation schema pins may change only through schema_pin_revision.'}
    }else{
        $targetRevision=[string]$pinProperty.Value
        $projectRevision=Get-PreparationPinnedRevision ([string]$Project.'$schema') 'project-spec-v2.schema.json' 'current project'
        $lockRevision=Get-PreparationPinnedRevision ([string]$FeatureLock.'$schema') 'feature-lock-v2.schema.json' 'current feature-lock'
        $stateRevision=Get-PreparationPinnedRevision ([string]$State.'$schema') 'workspace-state-v2.schema.json' 'current workspace-state'
        if($projectRevision-cne$lockRevision-or$projectRevision-cne$stateRevision){throw 'Preparation current schema pins do not share one exact Work Environment revision.'}
        if($targetRevision-ceq$projectRevision){throw 'Preparation schema pin target must differ from the current Work Environment revision.'}
        if([string]$Preparation.envelope.project.'$schema'-cne(Get-PreparationSchemaPin $targetRevision 'project-spec-v2.schema.json')-or[string]$Preparation.envelope.feature_lock.'$schema'-cne(Get-PreparationSchemaPin $targetRevision 'feature-lock-v2.schema.json')){throw 'Preparation target project and feature-lock schema pins do not match schema_pin_revision.'}
        $targetState.'$schema'=Get-PreparationSchemaPin $targetRevision 'workspace-state-v2.schema.json'
    }
    if((Get-PreparationHash $FeatureLock)-cne(Get-PreparationHash $Preparation.envelope.feature_lock)){
        $targetState.module_registry=Get-PreparationModuleRegistry $Preparation.envelope.project $Preparation.envelope.feature_lock
    }
    $targetState
}
function Assert-PreparationEnvelope {
    param([object]$Preparation,[object]$Project,[object]$FeatureLock)
    $targetProject=$Preparation.envelope.project;$targetLock=$Preparation.envelope.feature_lock
    if([string]$targetProject.project_id-cne[string]$Preparation.project_id-or[string]$targetLock.project_id-cne[string]$Preparation.project_id){throw 'Preparation envelope project identities are not exact.'}
    if([int]$targetLock.project_revision-ne[int]$targetProject.revision){throw 'Preparation feature-lock project revision differs from the target project revision.'}
    if([int]$targetLock.revision-ne([int]$FeatureLock.revision+1)){throw 'Preparation feature lock must advance exactly one revision.'}
    $old=@{};foreach($f in @($FeatureLock.features)){$id=[string]$f.feature_id;if($old.ContainsKey($id)){throw "Preparation current feature lock repeats '$id'."};$old[$id]=$f};$new=@{};foreach($f in @($targetLock.features)){$id=[string]$f.feature_id;if($new.ContainsKey($id)){throw "Preparation target feature lock repeats '$id'."};$new[$id]=$f}
    foreach($id in $old.Keys){if(-not$new.ContainsKey($id)){throw "Preparation removes existing feature '$id'."};if((Get-PreparationHash $old[$id])-cne(Get-PreparationHash $new[$id])){throw "Preparation rewrites existing feature '$id'."}}
    $added=@($new.Keys|Where-Object{-not$old.ContainsKey($_)}|Sort-Object);foreach($id in $added){$feature=$new[$id];if([string]$feature.run_activation_default-cne'disabled'-or$feature.selected-ne$true){throw "Preparation feature '$id' must be selected and default disabled."};if([string]$feature.activation.rule-cne'selected-lock-and-runtime-input'-or@($feature.activation.runtime_inputs).Count-eq0){throw "Preparation feature '$id' requires selected lock and runtime input."}}
    $oldLockSelected=@($FeatureLock.selected_features|Sort-Object -Unique);$newLockSelected=@($targetLock.selected_features|Sort-Object -Unique);foreach($id in $oldLockSelected){if($newLockSelected-cnotcontains$id){throw "Preparation removes selected feature '$id'."}}
    $oldProjectSelected=@($Project.composition.selected_features|Sort-Object -Unique);$newProjectSelected=@($targetProject.composition.selected_features|Sort-Object -Unique);$addedLockSelected=@($newLockSelected|Where-Object{$oldLockSelected-cnotcontains$_}|Sort-Object);$addedProjectSelected=@($newProjectSelected|Where-Object{$oldProjectSelected-cnotcontains$_}|Sort-Object)
    if((Get-PreparationHash $added)-cne(Get-PreparationHash $addedLockSelected)-or(Get-PreparationHash $added)-cne(Get-PreparationHash $addedProjectSelected)){throw 'Preparation added feature bindings differ between project composition and feature lock.'}
    foreach($id in @($FeatureLock.denied_features)){if(@($targetLock.denied_features)-cnotcontains$id){throw "Preparation removes denied feature '$id'."}}
    $declaredPermissions=@($Preparation.envelope.allowed_permission_categories|Sort-Object -Unique);if($declaredPermissions-ccontains'none'){if($declaredPermissions.Count-ne1){throw "Preparation permission ceiling 'none' must be the only declared value."};$declaredPermissions=@()}
    $permissionUnion=@($targetLock.effect_union.permissions|Sort-Object -Unique);$projectPermissions=@($targetProject.composition.allowed_permissions|Sort-Object -Unique);if((Get-PreparationHash $permissionUnion)-cne(Get-PreparationHash $declaredPermissions)-or(Get-PreparationHash $projectPermissions)-cne(Get-PreparationHash $declaredPermissions)){throw 'Preparation project, feature-lock, and declared permission ceilings differ.'}
    foreach($permission in @($targetProject.composition.denied_permissions)){if($permissionUnion-ccontains$permission){throw "Preparation permits denied permission '$permission'."}}
    if(@($Preparation.envelope.allowed_change_categories).Count-eq0-or@($Preparation.envelope.allowed_effect_categories).Count-eq0){throw 'Preparation requires closed change and effect ceilings.'}
    if([string]$targetLock.lock_fingerprint-cne(Get-PreparationLockFingerprint $targetLock)){throw 'Preparation target feature-lock fingerprint is stale or damaged.'}
    $registeredProfiles=@($targetProject.validation_profiles|ForEach-Object{[string]$_.profile_id})
    $declaredProfiles=@($Preparation.envelope.build_envelope.allowed_profiles|ForEach-Object{[string]$_}|Sort-Object -Unique)
    foreach($profile in $declaredProfiles){
        if($registeredProfiles-cnotcontains[string]$profile){throw "Preparation build profile '$profile' is not registered in the target project validation profiles."}
    }
    $currentProfiles=@($Project.validation_profiles|ForEach-Object{[string]$_.profile_id});foreach($profile in @($registeredProfiles|Where-Object{$currentProfiles-cnotcontains$_})){if($declaredProfiles-cnotcontains$profile){throw "Preparation adds validation profile '$profile' outside the declared build profile ceiling."}}
}
function Complete-MorphospaceDevelopmentEnvelopePreparation {
    param([string]$Workspace,[string]$RepoRoot,[string]$IntentRelative,[string]$CompletionRelative,[switch]$CheckOnly,[ValidateSet('none','after-artifacts','after-project','after-lock','after-state','after-event')][string]$FaultAfter='none')
    $intentPath=Get-PreparationPath $Workspace $IntentRelative;Assert-PreparationSchema $RepoRoot $intentPath 'development-envelope-preparation-intent-v1.schema.json' 'Preparation intent is invalid.';$intent=Read-MorphospaceProtocolJson $intentPath
    $completionPath=Get-PreparationPath $Workspace $CompletionRelative;$completion=$null;if([IO.File]::Exists($completionPath)){Assert-PreparationSchema $RepoRoot $completionPath 'development-envelope-preparation-completion-v1.schema.json' 'Preparation completion is invalid.';$completion=Read-MorphospaceProtocolJson $completionPath}
    foreach($name in @('project','state','feature_lock','predecessor_unit')){$binding=$intent.pre.$name;$target=$intent.target.$name;$current=Read-MorphospaceProtocolJson (Get-PreparationPath $Workspace ([string]$binding.path));$hash=Get-PreparationHash $current;if(@([string]$binding.sha256,[string]$target.sha256)-cnotcontains$hash){throw "Preparation recovery $name CAS is stale or conflicting."}}
    if((Get-PreparationFileHash (Get-PreparationPath $Workspace ([string]$intent.pre.repository_map.path)))-cne[string]$intent.pre.repository_map.sha256){throw 'Preparation recovery repository map preimage is stale.'}
    foreach($artifact in @($intent.artifacts)){$path=Get-PreparationPath $Workspace ([string]$artifact.path);if([IO.File]::Exists($path)){if((Get-PreparationHash (Read-MorphospaceProtocolJson $path))-cne[string]$artifact.sha256){throw "Preparation artifact '$($artifact.path)' conflicts with intent."}}elseif(-not$CheckOnly){$bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null;[IO.File]::WriteAllBytes($path,$bytes)}}
    if($FaultAfter-eq'after-artifacts'){throw 'Injected preparation interruption after artifacts.'}
    foreach($name in @('project','feature_lock','state')){$binding=$intent.pre.$name;$target=$intent.target.$name;$current=Read-MorphospaceProtocolJson (Get-PreparationPath $Workspace ([string]$binding.path));if(-not$CheckOnly-and(Get-PreparationHash $current)-cne[string]$target.sha256){Write-MorphospaceManagedProtocolJsonAtomic $Workspace ([string]$target.path) $target.document};if($FaultAfter-eq("after-"+$name.Replace('feature_lock','lock'))){throw "Injected preparation interruption after $name."}}
    $eventsPath=Get-PreparationPath $Workspace ([string]$intent.pre.events.path);$events=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json});$same=@($events|Where-Object{[string]$_.event_id-ceq[string]$intent.event.event_id});if($same.Count-gt1-or($same.Count-eq1-and(([int]$same[0].sequence-ne[int]$intent.event.sequence-or[string]$same[0].project_id-cne[string]$intent.event.project_id-or[string]$same[0].unit_id-cne[string]$intent.event.unit_id-or[string]$same[0].event_type-cne[string]$intent.event.event_type-or[string]$same[0].summary-cne[string]$intent.event.summary-or@($same[0].receipts).Count-ne1-or[string]@($same[0].receipts)[0]-cne[string]@($intent.event.receipts)[0])-or[string]$events[-1].event_id-cne[string]$intent.event.event_id))){throw 'Preparation event placement conflicts with intent.'};if($same.Count-eq0){if((Get-PreparationFileHash $eventsPath)-cne[string]$intent.pre.events.sha256-or[int]$events[-1].sequence+1-ne[int]$intent.event.sequence){throw 'Preparation event predecessor is stale.'};if(-not$CheckOnly){[IO.File]::AppendAllText($eventsPath,(($intent.event|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))}}
    if($FaultAfter-eq'after-event'){throw 'Injected preparation interruption after event.'}
    if($null-ne$completion){if([string]$completion.transaction_id-cne[string]$intent.transaction_id-or[string]$completion.intent_sha256-cne(Get-PreparationFileHash $intentPath)-or[string]$completion.target_project_sha256-cne[string]$intent.target.project.sha256-or[string]$completion.target_state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.target_feature_lock_sha256-cne[string]$intent.target.feature_lock.sha256-or[string]$completion.event_id-cne[string]$intent.event.event_id){throw 'Preparation completion no longer authenticates its exact transaction.'};return 'already-committed'}
    if($CheckOnly){return 'recoverable'}
    $completion=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.development_envelope_preparation_completion.v1';transaction_id=$intent.transaction_id;completed_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');intent_sha256=(Get-PreparationFileHash $intentPath);target_project_sha256=$intent.target.project.sha256;target_state_sha256=$intent.target.state.sha256;target_feature_lock_sha256=$intent.target.feature_lock.sha256;event_id=$intent.event.event_id;status='committed'};Write-MorphospaceManagedProtocolJsonAtomic $Workspace $CompletionRelative $completion -NoOverwrite;return 'committed'
}
function Get-PreparationSourceComposition {
    param([object]$Preparation,[hashtable]$Map)
    $records=[Collections.Generic.List[object]]::new();$leaves=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($id in @($Preparation.envelope.source_composition.repository_ids|Sort-Object -Unique)){
        if(-not$Map.ContainsKey([string]$id)){throw "Preparation source-composition repository '$id' is unmapped."};$entry=$Map[[string]$id];$root=[IO.Path]::GetFullPath([string]$entry.path)
        if(-not[IO.Directory]::Exists($root)){throw "Preparation mapped repository '$id' is unavailable."};$dirty=@(& git -C $root status --porcelain=v1 --untracked-files=no);if($LASTEXITCODE-ne0-or$dirty.Count-ne0){throw "Preparation source-composition repository '$id' is not tracked-clean."}
        $commit=([string](& git -C $root rev-parse HEAD)).Trim().ToLowerInvariant();$tree=([string](& git -C $root rev-parse 'HEAD^{tree}')).Trim().ToLowerInvariant();if($commit-cnotmatch'^[0-9a-f]{40}$'-or$tree-cnotmatch'^[0-9a-f]{40}$'){throw "Preparation repository '$id' lacks exact commit/tree identities."}
        $branch=([string](& git -C $root rev-parse --abbrev-ref HEAD)).Trim();if($branch-eq'HEAD'){$branch=$null};$leaf=Split-Path -Leaf $root;if(-not$leaves.Add($leaf)){throw 'Preparation source-composition has duplicate materialization paths.'}
        $records.Add([pscustomobject][ordered]@{repo_id=[string]$id;role=[string]$entry.role;commit=$commit;tree=$tree;branch=$branch;materialization_path=$leaf;tracked_worktree_clean=$true})|Out-Null
    }
    $fingerprint=Get-PreparationHash ([pscustomobject][ordered]@{project_id=$Preparation.project_id;preparation_id=$Preparation.preparation_id;repositories=@($records.ToArray())})
    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.development_envelope_source_composition.v1';lock_id="$($Preparation.preparation_id)-source-$($fingerprint.Substring(0,12))";preparation_id=$Preparation.preparation_id;project_id=$Preparation.project_id;fingerprint=$fingerprint;repositories=@($records.ToArray());status='locked';does_not_prove=@('Does not admit a future unit, claim a device, enable a feature, execute a build, or authorize publication.')}
}
function Invoke-MorphospacePrepareDevelopmentEnvelope {
 [CmdletBinding()]param([string]$WorkspaceRoot,[string]$DevelopmentEnvelopePreparation,[string]$OutPath,[string]$ExpectedDevelopmentEnvelopePreparationSha256='',[string]$Timestamp='',[switch]$Execute,[ValidateSet('none','after-intent','after-artifacts','after-project','after-lock','after-state','after-event')][string]$FaultAfter='none')
 $repoRoot=Split-Path $PSScriptRoot -Parent;$workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $DevelopmentEnvelopePreparation).Path
 Assert-PreparationSchema $repoRoot $input 'development-envelope-preparation-v1.schema.json' 'Development envelope preparation does not satisfy its schema.';$p=Read-MorphospaceProtocolJson $input;$inputHash=Get-PreparationFileHash $input
 if($Execute-and-not$ExpectedDevelopmentEnvelopePreparationSha256){throw 'Executed preparation requires the dry-run preparation SHA-256.'};if($ExpectedDevelopmentEnvelopePreparationSha256-and$ExpectedDevelopmentEnvelopePreparationSha256-cne$inputHash){throw 'Expected preparation hash does not match input.'};if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};if(-not(Test-MorphospaceStrictUtcTimestamp $Timestamp)){throw 'Preparation timestamp must be strict UTC.'}
 $receiptRelative="receipts/$($p.preparation_id).json";$sourceRelative=[string]$p.envelope.source_composition.path;$eventId=Get-PreparationEventId $p.preparation_id;$transactionId=Get-PreparationTransactionId $p.preparation_id;$intentRelative="receipts/transactions/$transactionId.intent.json";$completionRelative="receipts/transactions/$transactionId.completion.json"
 if([IO.Path]::GetFullPath($OutPath)-cne(Get-PreparationPath $workspace $receiptRelative)){throw "Preparation output must be '$receiptRelative'."}
 $earlyIntent=Get-PreparationPath $workspace $intentRelative
 if([IO.File]::Exists($earlyIntent)){$intent=Read-MorphospaceProtocolJson $earlyIntent;$receiptArtifact=@($intent.artifacts|Where-Object{[string]$_.path-ceq$receiptRelative});if($receiptArtifact.Count-ne1){throw 'Preparation replay intent lacks its exact receipt artifact.'};$intentReceipt=([Text.UTF8Encoding]::new($false).GetString([Convert]::FromBase64String([string]$receiptArtifact[0].bytes_base64))|ConvertFrom-Json);if([string]$intent.transaction_id-cne$transactionId-or[string]$intentReceipt.input_sha256-cne$inputHash-or(Get-PreparationHash $intent.target.project.document)-cne(Get-PreparationHash $p.envelope.project)-or(Get-PreparationHash $intent.target.feature_lock.document)-cne(Get-PreparationHash $p.envelope.feature_lock)){throw 'Preparation replay conflicts with its published intent.'};[void](Complete-MorphospaceDevelopmentEnvelopePreparation $workspace $repoRoot $intentRelative $completionRelative -CheckOnly);if([IO.File]::Exists((Get-PreparationPath $workspace $completionRelative))){Assert-PreparationHistoricalSupersessionClosure $workspace};$liveState=Read-MorphospaceProtocolJson (Get-PreparationPath $workspace 'workspace.state.json');if($Execute){$mutex=Enter-MorphospaceWorkspaceMutex $workspace;try{[void](Complete-MorphospaceDevelopmentEnvelopePreparation $workspace $repoRoot $intentRelative $completionRelative -FaultAfter $FaultAfter)}finally{Exit-MorphospaceWorkspaceMutex $mutex}};return (New-PreparationAutomationReceipt $p $Timestamp $Execute.IsPresent 'idle-project-envelope-prepared' $receiptRelative $inputHash $liveState $(if($Execute){$eventId}else{$null}))}
 $projectPath=Get-PreparationPath $workspace 'project.spec.json';$statePath=Get-PreparationPath $workspace 'workspace.state.json';$lockPath=Get-PreparationPath $workspace 'feature.lock.json';$eventsPath=Get-PreparationPath $workspace 'iteration-events.jsonl';$mapPath=Get-PreparationPath $workspace ([string]$p.expected.repository_map_path);$prePath=Get-PreparationPath $workspace ([string]$p.expected.predecessor_unit_path)
 $project=Read-MorphospaceProtocolJson $projectPath;$state=Read-MorphospaceProtocolJson $statePath;$lock=Read-MorphospaceProtocolJson $lockPath;$mapDoc=Read-MorphospaceProtocolJson $mapPath;$pre=Read-MorphospaceProtocolJson $prePath;$eventBytes=[IO.File]::ReadAllBytes($eventsPath);$events=@(Get-Content $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json});if($events.Count-eq0){throw 'Preparation requires a predecessor event.'};$tail=$events[-1]
 Assert-PreparationSchema $repoRoot $projectPath 'project-spec-v2.schema.json' 'Preparation current project does not satisfy the owner schema.';Assert-PreparationSchema $repoRoot $lockPath 'feature-lock-v2.schema.json' 'Preparation current feature lock does not satisfy the owner schema.'
 Assert-PreparationSchema $repoRoot $mapPath 'repository-map.schema.json' 'Preparation repository map does not satisfy the closed owner schema.'
 if([string]$project.project_id-cne[string]$p.project_id-or[string]$state.project_id-cne[string]$p.project_id-or[string]$pre.project_id-cne[string]$p.project_id-or[string]$pre.unit_id-cne[string]$p.predecessor_unit_id-or[string]$pre.status-cne'accepted'){throw 'Preparation project/predecessor identity or acceptance is invalid.'};if($null-ne$state.current_unit-or$null-ne$state.next_ready_unit){throw 'Preparation requires an idle project with null current and ready units.'};Assert-PreparationLockAndRegistry $project $lock $state 'current'
  Assert-PreparationHistoricalSupersessionClosure $workspace
 foreach($check in @(@{e=$p.expected.project_sha256;a=(Get-PreparationHash $project);n='project'},@{e=$p.expected.state_sha256;a=(Get-PreparationHash $state);n='state'},@{e=$p.expected.feature_lock_sha256;a=(Get-PreparationHash $lock);n='feature lock'},@{e=$p.expected.repository_map_sha256;a=(Get-PreparationFileHash $mapPath);n='repository map'},@{e=$p.expected.predecessor_unit_sha256;a=(Get-PreparationHash $pre);n='predecessor unit'},@{e=$p.expected.events_sha256;a=(Get-PreparationFileHash $eventsPath);n='ledger'})){if([string]$check.e-cne[string]$check.a){throw "Preparation stale $($check.n) preimage."}}
 if([int64]$p.expected.events_length-ne$eventBytes.LongLength-or[string]$p.expected.event_tail_id-cne[string]$tail.event_id){throw 'Preparation ledger predecessor is stale.'};$map=@{};foreach($entry in @($mapDoc.repositories)){$id=[string]$entry.repo_id;if($map.ContainsKey($id)){throw "Preparation repository map repeats '$id' case-insensitively."};$map[$id]=$entry}
 if(-not(Test-Json -Json ($p.envelope.project|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repoRoot 'schemas\project-spec-v2.schema.json'))){throw 'Preparation target project does not satisfy the owner schema.'};if(-not(Test-Json -Json ($p.envelope.feature_lock|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repoRoot 'schemas\feature-lock-v2.schema.json'))){throw 'Preparation target feature lock does not satisfy the owner schema.'}
 $targetState=Get-PreparationTargetState $p $project $lock $state
 if(-not(Test-Json -Json ($targetState|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repoRoot 'schemas\workspace-state-v2.schema.json'))){throw 'Preparation target workspace state does not satisfy the owner schema.'}
 Assert-PreparationAdditiveProject $project $p.envelope.project ($null-ne$p.envelope.psobject.Properties['schema_pin_revision']);Assert-PreparationRoots @($p.envelope.owner_repositories) $p.envelope.project $map;Assert-PreparationEnvelope $p $project $lock;Assert-PreparationLockAndRegistry $p.envelope.project $p.envelope.feature_lock $targetState 'target'
 $ownerIds=@($p.envelope.owner_repositories|ForEach-Object{[string]$_.repo_id}|Sort-Object -Unique);$sourceIds=@($p.envelope.source_composition.repository_ids|Sort-Object -Unique);$mapIds=@($map.Keys|Sort-Object -Unique);if($ownerIds.Count-ne$sourceIds.Count-or$ownerIds.Count-ne$mapIds.Count-or(@($ownerIds|Where-Object{$sourceIds-cnotcontains$_-or$mapIds-cnotcontains$_}).Count-ne0)){throw 'Preparation owner repositories, repository map, and source-lock repository sets must agree exactly.'}
 $targetProjectIds=@($p.envelope.project.repositories|ForEach-Object{[string]$_.repo_id}|Sort-Object -Unique);if($targetProjectIds.Count-ne$mapIds.Count-or@($targetProjectIds|Where-Object{$mapIds-cnotcontains$_}).Count-ne0){throw 'Preparation target project repositories must exactly match the validated repository map.'}
 $source=Get-PreparationSourceComposition $p $map;if(-not(Test-Json -Json ($source|ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\development-envelope-source-composition-v1.schema.json'))){throw 'Preparation generated source lock does not satisfy its closed schema.'};Assert-PreparationSchema $repoRoot ([string]$input) 'development-envelope-preparation-v1.schema.json' 'Preparation input changed during observation.'
 $targetState.last_event_id=$eventId;$receipt=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.development_envelope_preparation_receipt.v1';preparation_id=$p.preparation_id;project_id=$p.project_id;predecessor_unit_id=$p.predecessor_unit_id;input_sha256=$inputHash;envelope=$p.envelope;project_sha256=(Get-PreparationHash $p.envelope.project);feature_lock_sha256=(Get-PreparationHash $p.envelope.feature_lock);source_composition=[pscustomobject]@{path=$sourceRelative;sha256=(Get-PreparationHash $source)};does_not_prove=@('Does not admit, Ready, Inspect, Claim, amend, freeze, validate, accept, approve a schema revision, build, deploy, launch, mutate a device, mutate a Git remote, or publish a future unit.')}
 $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$tail.sequence+1;timestamp=$Timestamp;project_id=$p.project_id;unit_id=$p.predecessor_unit_id;event_type='decision';summary='Prepared one bounded idle-project development envelope; future admission remains bind-only.';receipts=@($receiptRelative)}
 $intentPath=Get-PreparationPath $workspace $intentRelative
 $intent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.development_envelope_preparation_intent.v1';transaction_id=$transactionId;created_at=$Timestamp;pre=[pscustomobject]@{project=[pscustomobject]@{path='project.spec.json';sha256=(Get-PreparationHash $project);document=$project};state=[pscustomobject]@{path='workspace.state.json';sha256=(Get-PreparationHash $state);document=$state};feature_lock=[pscustomobject]@{path='feature.lock.json';sha256=(Get-PreparationHash $lock);document=$lock};predecessor_unit=[pscustomobject]@{path=$p.expected.predecessor_unit_path;sha256=(Get-PreparationHash $pre);document=$pre};events=[pscustomobject]@{path='iteration-events.jsonl';sha256=(Get-PreparationFileHash $eventsPath)};repository_map=[pscustomobject]@{path=$p.expected.repository_map_path;sha256=(Get-PreparationFileHash $mapPath)}};target=[pscustomobject]@{project=[pscustomobject]@{path='project.spec.json';sha256=(Get-PreparationHash $p.envelope.project);document=$p.envelope.project};state=[pscustomobject]@{path='workspace.state.json';sha256=(Get-PreparationHash $targetState);document=$targetState};feature_lock=[pscustomobject]@{path='feature.lock.json';sha256=(Get-PreparationHash $p.envelope.feature_lock);document=$p.envelope.feature_lock};predecessor_unit=[pscustomobject]@{path=$p.expected.predecessor_unit_path;sha256=(Get-PreparationHash $pre);document=$pre};events=[pscustomobject]@{path='iteration-events.jsonl';sha256=(Get-PreparationFileHash $eventsPath)};repository_map=[pscustomobject]@{path=$p.expected.repository_map_path;sha256=(Get-PreparationFileHash $mapPath)}};artifacts=@([pscustomobject]@{path=$receiptRelative;sha256=(Get-PreparationHash $receipt);bytes_base64=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($receipt|ConvertTo-Json -Depth 64)))},[pscustomobject]@{path=$sourceRelative;sha256=(Get-PreparationHash $source);bytes_base64=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($source|ConvertTo-Json -Depth 64))) });event=$event;status='prepared'}
 if(-not$Execute){return (New-PreparationAutomationReceipt $p $Timestamp $false 'idle-project-envelope-prepared' $receiptRelative $inputHash $state $null)}
 $mutex=Enter-MorphospaceWorkspaceMutex $workspace;try{if([IO.File]::Exists($intentPath)){throw 'Preparation intent appeared during observation; retry against the exact owner intent.'};Write-MorphospaceManagedProtocolJsonAtomic $workspace $intentRelative $intent -NoOverwrite;if($FaultAfter-eq'after-intent'){throw 'Injected preparation interruption after intent.'};[void](Complete-MorphospaceDevelopmentEnvelopePreparation $workspace $repoRoot $intentRelative $completionRelative -FaultAfter $FaultAfter)}finally{Exit-MorphospaceWorkspaceMutex $mutex}
 New-PreparationAutomationReceipt $p $Timestamp $true 'idle-project-envelope-prepared' $receiptRelative $inputHash $state $eventId
}
Export-ModuleMember -Function Invoke-MorphospacePrepareDevelopmentEnvelope
