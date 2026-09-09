Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalSupersessionCompatibility.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceDevelopmentEnvelopeSemantics.psm1')

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
    if($null-eq(Get-Command Get-MorphospaceCurrentWorkHistory -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceCurrentWorkHistory.psm1')}
    $history = Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $Workspace -RequireIdle
    if (-not $history.authenticated) {
        # Existing bootstrap workspaces have no exemption from ordinary rules.
        Assert-PreparationHistoricalSupersessionAudit $Workspace
        return
    }
    foreach ($id in $history.units.Keys) {
        if ([string]$history.units[$id].status -cne 'accepted' -and
            -not $history.retired_ids.Contains($id) -and
            -not $history.historically_retired_proposed_ids.Contains($id)) {
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
    Get-MorphospaceDevelopmentEnvelopeModuleRegistry $Project $FeatureLock
}
function Assert-PreparationLockAndRegistry {
    param([object]$Project,[object]$FeatureLock,[object]$State,[string]$Context)
    Assert-MorphospaceDevelopmentEnvelopeLockAndRegistry $Project $FeatureLock $State $Context
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
    Assert-MorphospaceDevelopmentEnvelopeOwnerRoots $Rows $Project $Map
}
function Assert-PreparationAdditiveProject {
    param([object]$Current,[object]$Target,[bool]$AllowSchemaPinAdvance,[AllowNull()][object[]]$OwnerRepositories=$null)
    Assert-MorphospaceDevelopmentEnvelopeAdditiveProject $Current $Target $AllowSchemaPinAdvance $OwnerRepositories
}
function Get-PreparationTargetState {
    param([object]$Preparation,[object]$Project,[object]$FeatureLock,[object]$State)
    Get-MorphospaceDevelopmentEnvelopeTargetState $Preparation $Project $FeatureLock $State
}
function Assert-PreparationEnvelope {
    param([object]$Preparation,[object]$Project,[object]$FeatureLock)
    Assert-MorphospaceDevelopmentEnvelope $Preparation $Project $FeatureLock
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
 Assert-PreparationAdditiveProject $project $p.envelope.project ($null-ne$p.envelope.psobject.Properties['schema_pin_revision']) @($p.envelope.owner_repositories);Assert-PreparationRoots @($p.envelope.owner_repositories) $p.envelope.project $map;Assert-PreparationEnvelope $p $project $lock;Assert-PreparationLockAndRegistry $p.envelope.project $p.envelope.feature_lock $targetState 'target'
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
