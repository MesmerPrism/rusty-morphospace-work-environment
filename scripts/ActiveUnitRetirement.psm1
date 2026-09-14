Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceSourceCompositionIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1')

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
    [pscustomobject]@{events=$events;sha256=Get-MorphospaceSha256Bytes $bytes;length=[long]$bytes.Length;tail_id=[string]$events[-1].event_id}
}
function Get-ActiveRetirementCanonicalRawSha256([object]$Document){Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $Document)}
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
function Test-ActiveRetirementRecoveryPreparationProvenance([string]$Workspace,[object]$Admission,[object]$RecoveryIntent){
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
        $null=Test-MorphospaceDevelopmentUnitPreparation -WorkspaceRoot $temporary -Admission $Admission -Phase Freeze
    }finally{
        $resolved=[IO.Path]::GetFullPath($temporary);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if($resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($resolved).StartsWith('morphospace-retirement-provenance-')){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
    }
}
function Test-ActiveRetirementAuthenticatedPlanningDirt {
    param([string]$Workspace,[object]$Unit,[object]$RepositoryEntry,[string[]]$StatusPorcelain,[object]$RecoveryIntent=$null)
    if([string]$RepositoryEntry.role-cne'planning'){return $false}
    if([string]::IsNullOrWhiteSpace($Workspace)){throw 'Active retirement planning lifecycle workspace path is empty.'};if([string]::IsNullOrWhiteSpace([string]$RepositoryEntry.path)){throw 'Active retirement planning lifecycle repository path is empty.'}
    if($null-eq$RecoveryIntent-and@($StatusPorcelain|Where-Object{[string]$_-cmatch'retire-.*-active-retired-transition'}).Count-ne0){throw 'Active retirement planning lifecycle recovery intent was not forwarded.'}
    $repository=[IO.Path]::GetFullPath([string]$RepositoryEntry.path).TrimEnd('\','/');$workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $repositoryPrefix=$repository+[IO.Path]::DirectorySeparatorChar;$pathComparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$workspaceFull.StartsWith($repositoryPrefix,$pathComparison)){return $false}
    $workspacePrefix=[IO.Path]::GetRelativePath($repository,$workspaceFull).Replace('\','/').TrimEnd('/')+'/'
    $admissions=@(Get-ChildItem -LiteralPath (Resolve-MorphospaceWorkspacePath $workspaceFull 'receipts') -File -Filter '*.json'|ForEach-Object{$document=Read-MorphospaceProtocolJson $_.FullName;if([string]$document.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$document.unit_id-ceq[string]$Unit.unit_id){$document}})
    if($admissions.Count-ne1){throw 'Active retirement planning lifecycle requires one exact current admission receipt.'}
    $admission=$admissions[0]
    if($RecoveryIntent){Test-ActiveRetirementRecoveryPreparationProvenance $workspaceFull $admission $RecoveryIntent}else{$null=Test-MorphospaceDevelopmentUnitPreparation -WorkspaceRoot $workspaceFull -Admission $admission -Phase Freeze}
    $events=(Get-ActiveRetirementEvents $workspaceFull).events;$preparedId="$([string]$admission.preparation.preparation_id)-prepared";$admittedId="$([string]$admission.admission_id)-admitted"
    $prepared=@($events|Where-Object{[string]$_.event_id-ceq$preparedId});$admitted=@($events|Where-Object{[string]$_.event_id-ceq$admittedId});$claimed=@($events|Where-Object{[string]$_.unit_id-ceq[string]$Unit.unit_id-and[string]$_.event_id-cmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-claimed-[0-9]{4}$')})
    if($prepared.Count-ne1-or$admitted.Count-ne1-or$claimed.Count-ne1){throw 'Active retirement planning lifecycle event identities are ambiguous.'}
    $from=[int]$prepared[0].sequence;$to=[int]$claimed[0].sequence;$suffix=@($events|Where-Object{[int]$_.sequence-ge$from-and[int]$_.sequence-le$to}|Sort-Object sequence)
    $direct=$suffix.Count-eq4-and[string]$suffix[0].event_id-ceq$preparedId-and[string]$suffix[1].event_id-ceq$admittedId-and[string]$suffix[2].event_id-cmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-ready-[0-9]{4}$')-and[string]$suffix[3].event_id-ceq[string]$claimed[0].event_id
    $replacement=$suffix.Count-eq6-and[string]$suffix[0].event_id-ceq$preparedId-and[string]$suffix[1].event_id-cmatch'-admitted$'-and[string]$suffix[2].event_id-cmatch'-proposal-retired-[0-9]{4}$'-and[string]$suffix[3].event_id-ceq$admittedId-and[string]$suffix[4].event_id-cmatch('^'+[regex]::Escape([string]$Unit.unit_id)+'-ready-[0-9]{4}$')-and[string]$suffix[5].event_id-ceq[string]$claimed[0].event_id
    if(-not$direct-and-not$replacement){throw 'Active retirement planning lifecycle suffix is unsupported.'}
    for($index=0;$index-lt$suffix.Count;$index++){if([int]$suffix[$index].sequence-ne($from+$index)){throw 'Active retirement planning lifecycle suffix is not contiguous.'}}
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
    foreach($event in @($suffix|Select-Object -Skip 1)){
        $transactionId="$([string]$event.event_id)-transition";$proof=Get-ActiveRetirementPlanningTransition -Workspace $workspaceFull -TransactionId $transactionId -HistoricalProjection:($null-ne$RecoveryIntent)
        if((Get-MorphospaceCanonicalJsonSha256 $proof.intent.event)-cne(Get-MorphospaceCanonicalJsonSha256 $event)){throw 'Active retirement planning lifecycle event is detached from its transaction.'}
        $intentRelative="receipts/transactions/$transactionId.intent.json";$completionRelative="receipts/transactions/$transactionId.completion.json";$intentPath=Resolve-MorphospaceWorkspacePath $workspaceFull $intentRelative -RequireLeaf;$completionPath=Resolve-MorphospaceWorkspacePath $workspaceFull $completionRelative -RequireLeaf
        if((Get-MorphospaceFileSha256 $intentPath)-cne(Get-ActiveRetirementCanonicalRawSha256 $proof.intent)-or(Get-MorphospaceFileSha256 $completionPath)-cne(Get-ActiveRetirementCanonicalRawSha256 $proof.completion)){throw 'Active retirement planning lifecycle transaction bytes are non-canonical.'}
        if(@(Get-ChildItem -LiteralPath (Split-Path $intentPath -Parent) -File -Filter "$transactionId.artifact-*.pending").Count-ne0){throw 'Active retirement planning lifecycle contains an orphan committed pending artifact.'}
        Set-PlanningProjection ([string]$proof.intent.state.path) (Get-ActiveRetirementCanonicalRawSha256 $proof.intent.target.state.document);Set-PlanningProjection ([string]$proof.intent.unit.path) (Get-ActiveRetirementCanonicalRawSha256 $proof.intent.target.unit.document)
        foreach($projection in @($(if($proof.intent.PSObject.Properties.Name-contains'additional_projections'){$proof.intent.additional_projections}else{@()}))){Set-PlanningProjection ([string]$projection.path) (Get-ActiveRetirementCanonicalRawSha256 $projection.document)}
        foreach($artifact in @($proof.intent.artifacts)){$artifactBytes=[Convert]::FromBase64String([string]$artifact.bytes_base64);if((Get-MorphospaceSha256Bytes $artifactBytes)-cne[string]$artifact.sha256){throw 'Active retirement planning lifecycle artifact payload is detached.'};Set-PlanningProjection ([string]$artifact.path) ([string]$artifact.sha256)}
        Set-PlanningProjection $intentRelative (Get-MorphospaceFileSha256 $intentPath);Set-PlanningProjection $completionRelative (Get-MorphospaceFileSha256 $completionPath)
    }
    Set-PlanningProjection 'iteration-events.jsonl' (Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspaceFull 'iteration-events.jsonl' -RequireLeaf))
    $staged=@(& git -C $repository diff --cached --name-only --no-renames -- 2>&1|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')});if($LASTEXITCODE-ne0-or$staged.Count-ne0){throw 'Active retirement planning lifecycle dirt must not be staged.'}
    $changes=@();foreach($line in @($StatusPorcelain)){$value=[string]$line;if($value.Length-lt4-or$value.Substring(0,2)-cnotin@(' M','??')){throw 'Active retirement planning lifecycle dirt contains a staged, deleted, renamed, conflicted, or unsupported entry.'};$gitPath=$value.Substring(3).Replace('\','/');if($RecoveryIntent-and$gitPath.StartsWith($workspacePrefix,[StringComparison]::Ordinal)-and$recoveryOwned.Contains($gitPath.Substring($workspacePrefix.Length))){continue};$changes+=,$gitPath};$changes=@($changes|Sort-Object -Unique)
    $allowed=@();foreach($path in @($expected.Keys|Sort-Object)){$live=Join-Path $repository $path;if(-not[IO.File]::Exists($live)-or(Get-MorphospaceFileSha256 $live)-cne[string]$expected[$path]){throw "Active retirement planning lifecycle projection is damaged: $path"};$null=& git -C $repository diff --quiet HEAD -- $path 2>&1;if($LASTEXITCODE-ne0){$allowed+=,$path}else{$null=& git -C $repository ls-files --error-unmatch -- $path 2>&1;if($LASTEXITCODE-ne0){$allowed+=,$path}}};$allowed=@($allowed|Sort-Object -Unique)
    if($changes.Count-ne$allowed.Count-or($changes-join'|')-cne($allowed-join'|')){throw "Active retirement planning repository dirt differs from the authenticated lifecycle projection (expected: $($allowed-join', '); observed: $($changes-join', '))."}
    return $true
}
function Get-ActiveRetirementRepositories([object]$Unit,[object]$Source,[string]$RepoMapPath,[string]$Workspace='',[object]$RecoveryIntent=$null){
    # Git observation is action-only. The shared reader avoids importing the
    # larger automation orchestrator into the historical dependency closure.
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceRepositoryObservation.psm1')
    $mapDocument=Read-MorphospaceProtocolJson ([IO.Path]::GetFullPath($RepoMapPath))
    Assert-ActiveRetirementSchema $mapDocument 'repository-map.schema.json'
    $map=@{};foreach($row in @($mapDocument.repositories)){
        if($map.ContainsKey([string]$row.repo_id)){throw 'Active retirement repository map contains duplicate identities.'};$map[[string]$row.repo_id]=$row
    }
    $authorized=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($row in @($Unit.allowed_repositories)){if(-not$authorized.Add([string]$row.repo_id)){throw 'Active retirement repeats an authorized source repository.'}}
    $sourceIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($row in @($Source.repositories)){if(-not$sourceIds.Add([string]$row.repo_id)){throw 'Active retirement source composition repeats a repository.'}}
    foreach($id in $authorized){if(-not$sourceIds.Contains($id)){throw 'Active retirement source composition omits an authorized repository.'}}
    $ids=[string[]]@($sourceIds);[Array]::Sort($ids,[StringComparer]::Ordinal);$observations=@()
    $rootComparer=if([OperatingSystem]::IsWindows()){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    $roots=[Collections.Generic.HashSet[string]]::new($rootComparer)
    foreach($id in $ids){
        if(-not$map.ContainsKey($id)){throw "Active retirement lacks repository map entry '$id'."}
        $entry=$map[$id]
        $observed=Get-MorphospaceRepositoryState -RepoId $id -Path ([string]$entry.path)
        if($observed.available-and$observed.is_git){
            $gitRoot=(@(& git -C ([string]$entry.path) rev-parse --show-toplevel 2>&1)-join'').Trim()
            if($LASTEXITCODE-ne0-or-not$rootComparer.Equals([IO.Path]::GetFullPath($gitRoot),[IO.Path]::GetFullPath([string]$entry.path))-or-not$roots.Add([IO.Path]::GetFullPath($gitRoot))){throw 'Active retirement requires distinct exact repository roots.'}
        }
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
        $locked=@($Source.repositories|Where-Object{[string]$_.repo_id-ceq$id})[0]
        $planningDirt=$false
        if($observed.available-and$observed.is_git-and$remaining.Count-ne0-and-not$authorized.Contains($id)-and[string]$observed.head-ceq[string]$locked.commit-and[string]$observed.tree-ceq[string]$locked.tree){$planningDirt=Test-ActiveRetirementAuthenticatedPlanningDirt $Workspace $Unit $entry $remaining $RecoveryIntent}
        if(-not$observed.available-or-not$observed.is_git-or($remaining.Count-ne0-and-not$planningDirt)-or[string]$observed.head-cnotmatch'^[0-9a-f]{40}$'-or[string]$observed.tree-cnotmatch'^[0-9a-f]{40}$'){throw "Active retirement requires clean available source repository '$id'."}
        # Writable repositories may have newer clean local checkpoints. Read-only dependencies stay pinned.
        if(-not$authorized.Contains($id)-and([string]$observed.head-cne[string]$locked.commit-or[string]$observed.tree-cne[string]$locked.tree)){throw "Active retirement read-only dependency '$id' differs from the source lock."}
        if($authorized.Contains($id)){
            $null=& git -C ([string]$map[$id].path) merge-base --is-ancestor ([string]$locked.commit) ([string]$observed.head) 2>&1
            if($LASTEXITCODE-ne0){throw "Active retirement writable checkpoint '$id' does not retain its locked baseline."}
        }
        $observations+=,[pscustomobject][ordered]@{repo_id=$id;head=[string]$observed.head;tree=[string]$observed.tree;branch=$observed.branch;clean=$true}
    }
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
        {$_-cin@('rusty.morphospace.workflow.development_envelope_source_composition.v1','rusty.morphospace.workflow.development_envelope_source_composition.v2')} {
            $version=([string]$source.schema).Split('.')[-1]
            Assert-ActiveRetirementSchema $source "development-envelope-source-composition-$version.schema.json"
            $identity=[pscustomobject][ordered]@{project_id=[string]$source.project_id;preparation_id=[string]$source.preparation_id;repositories=@($source.repositories)}
            if([string]$source.fingerprint-cne(Get-MorphospaceCanonicalJsonSha256 $identity)-or[string]$source.lock_id-cne"$($source.preparation_id)-source-$(([string]$source.fingerprint).Substring(0,12))"){throw 'Active retirement preparation source lock fingerprint is detached.'}
            # The current-history admission proof authenticates this preparation-owned artifact and the unit's binding.
        }
        default {throw 'Active retirement source composition schema is unsupported.'}
    }
    if([string]$source.project_id-cne[string]$Request.project_id){throw 'Active retirement source lock project identity is detached.'}
    if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace ([string]$Request.accepted_receipt.path) -RequireLeaf))-cne[string]$Request.accepted_receipt.sha256){throw 'Active retirement accepted checkpoint bytes drifted.'}
    Assert-ActiveRetirementEqual @($Request.repositories) @(Get-ActiveRetirementRepositories -Unit $unit -Source $source -RepoMapPath $RepoMapPath -Workspace $Workspace -RecoveryIntent $RecoveryIntent) 'clean repository observation'
    return $unit
}
function New-ActiveRetirementReceipt([object]$Request,[string]$Path,[string]$Sha,[string]$Timestamp){
    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.active_unit_retirement_receipt.v1';retirement_id=[string]$Request.retirement_id;project_id=[string]$Request.project_id;unit_id=[string]$Request.unit_id;replacement_unit_id=[string]$Request.replacement_unit_id;reason=[string]$Request.reason;timestamp=$Timestamp;transaction_id="$($Request.retirement_id)-active-retired-transition";request=[pscustomobject]@{path=$Path;sha256=$Sha};old_unit=$Request.old_unit;source_composition=$Request.source_composition;claim=$Request.claim;repositories=@($Request.repositories);accepted_receipt=$Request.accepted_receipt;accepted=$false;source_mutation_performed=$false}
}
function New-ActiveRetirementResult([object]$Request,[string]$Path,[string]$Sha,[string]$Timestamp,[bool]$Executed){
    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$Request.project_id;unit_id=[string]$Request.unit_id;action='RetireActive';timestamp=$Timestamp;executed=$Executed;transition='active-retired-to-idle';status_before='active';status_after='active';current_unit_before=[string]$Request.unit_id;current_unit_after=$(if($Executed){$null}else{[string]$Request.unit_id});preservation=[pscustomobject]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject]@{path=$Path;sha256=$Sha};event_id=$(if($Executed){"$($Request.retirement_id)-active-retired"}else{$null})}
}
function Assert-ActiveRetirementIntent([string]$Workspace,[object]$Intent,[object]$Request,[string]$RequestPath,[string]$RequestSha,[string]$OutPath){
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
    [pscustomobject]@{intent=$proof.intent;completion=$proof.completion;receipt=$receipt;request=$request;transaction_id=$id}
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
    }finally{Exit-MorphospaceWorkspaceMutex $mutex}
}
Export-ModuleMember -Function Invoke-MorphospaceRetireActive,Test-MorphospaceHistoricalActiveUnitRetirement
