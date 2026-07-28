Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force

function Invoke-ResolveBlockerGit {
    param([string]$Path,[string[]]$Arguments)
    $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$output=@(& git -C $Path @Arguments 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    if($code-ne0){throw "ResolveBlocker Git observation failed: git $($Arguments-join' ')"}
    (($output|ForEach-Object{[string]$_})-join"`n").Trim()
}
function Resolve-ResolveBlockerRepositorySourcePath {
    param([string]$Repository,[string]$RelativePath)
    if($RelativePath-cmatch'\\'){throw "ResolveBlocker repository source path must use forward slashes: '$RelativePath'."}
    $normalized=ConvertTo-MorphospaceProtocolRelativePath $RelativePath
    if($normalized-cne$RelativePath){throw "ResolveBlocker repository source path is not normalized: '$RelativePath'."}
    $root=[IO.Path]::GetFullPath($Repository).TrimEnd('\','/')
    $candidate=[IO.Path]::GetFullPath([IO.Path]::Combine($root,$normalized))
    $prefix=$root+[IO.Path]::DirectorySeparatorChar
    if(-not$candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "ResolveBlocker repository source path escapes its repository: '$RelativePath'."}
    Assert-MorphospaceNoReparseAncestor -Root $root -Candidate $candidate
    if(-not[IO.File]::Exists($candidate)){throw "ResolveBlocker repository source file is missing: '$RelativePath'."}
    $attributes=[IO.File]::GetAttributes($candidate)
    if(($attributes-band[IO.FileAttributes]::Directory)-ne0-or($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "ResolveBlocker repository source is not a regular non-reparse file: '$RelativePath'."}
    $candidate
}
function Assert-ResolveBlockerRepositories {
    param([object]$Receipt,[hashtable]$Map)
    foreach($head in @($Receipt.repository_heads)){
        $key=([string]$head.repo_id).ToLowerInvariant()
        $repo=[IO.Path]::GetFullPath([string]$Map[$key].path)
        if((Invoke-ResolveBlockerGit $repo @('rev-parse','HEAD'))-cne[string]$head.revision-or(Invoke-ResolveBlockerGit $repo @('branch','--show-current'))-cne[string]$head.branch){throw "ResolveBlocker repository head changed for '$($head.repo_id)'."}
    }
    foreach($sourceSet in @($Receipt.repository_sources)){
        $key=([string]$sourceSet.repo_id).ToLowerInvariant()
        $repo=[IO.Path]::GetFullPath([string]$Map[$key].path)
        foreach($source in @($sourceSet.sources)){
            $sourcePath=Resolve-ResolveBlockerRepositorySourcePath $repo ([string]$source.path)
            if((Get-MorphospaceFileSha256 $sourcePath)-cne[string]$source.sha256){throw "ResolveBlocker repository source hash mismatch for '$($sourceSet.repo_id):$($source.path)'."}
        }
    }
}
function Assert-ResolveBlockerNotConsumed {
    param([string]$Workspace,[object]$Receipt,[string]$CanonicalSha256,[object[]]$Events,[string]$SchemaPath)
    $candidates=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($event in @($Events)){
        if([string]$event.event_id-notmatch'-blocker-resolved-[0-9]{4}$'){continue}
        $references=@($(if($event.PSObject.Properties.Name-contains'receipts'){@($event.receipts)}else{@()}))
        if($references.Count-ne1-or[string]$references[0]-notmatch'^receipts/.+\.json$'){throw "ResolveBlocker historical event '$($event.event_id)' has invalid retained receipt references."}
        $relative=[string]$references[0];[void]$candidates.Add($relative)
        try{$path=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf}catch{throw "ResolveBlocker historical event '$($event.event_id)' references a missing retained blocker-resolution receipt."}
        try{$raw=Get-Content -Raw -LiteralPath $path;$candidate=$raw|ConvertFrom-Json}catch{throw "ResolveBlocker historical event '$($event.event_id)' references an unreadable or malformed retained blocker-resolution receipt."}
        if(-not(Test-Json -Json $raw -SchemaFile $SchemaPath)){throw "ResolveBlocker historical event '$($event.event_id)' references a schema-invalid retained blocker-resolution receipt."}
        if([string]$candidate.project_id-cne[string]$event.project_id-or[string]$candidate.unit_id-cne[string]$event.unit_id){throw "ResolveBlocker historical event '$($event.event_id)' has inconsistent retained blocker-resolution receipt identity."}
        $transactionId="$([string]$event.event_id)-transition"
        $intentRelative="receipts/transactions/$transactionId.intent.json"
        $completionRelative="receipts/transactions/$transactionId.completion.json"
        try{$intentPath=Resolve-MorphospaceWorkspacePath $Workspace $intentRelative -RequireLeaf;$intent=Read-MorphospaceProtocolJson $intentPath}catch{throw "ResolveBlocker historical event '$($event.event_id)' is missing readable immutable transaction evidence."}
        try{$completionPath=Resolve-MorphospaceWorkspacePath $Workspace $completionRelative -RequireLeaf;$completion=Read-MorphospaceProtocolJson $completionPath}catch{throw "ResolveBlocker historical event '$($event.event_id)' is missing readable immutable transition completion evidence."}
        $intentFileHash=Get-MorphospaceFileSha256 $intentPath
        if(
            [string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or
            [string]$completion.transaction_id-cne$transactionId-or
            [string]$completion.event_id-cne[string]$event.event_id-or
            [string]$completion.status-cne'committed'-or
            [string]$completion.intent.role-cne'transition-ledger-intent'-or
            [string]$completion.intent.path-cne$intentRelative-or
            [string]$completion.intent.schema-cne[string]$intent.schema-or
            [string]$completion.intent.sha256-cne$intentFileHash-or
            [string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or
            [string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256
        ){throw "ResolveBlocker historical event '$($event.event_id)' has cryptographically inconsistent transition completion/intent evidence."}
        $owned=@($intent.artifacts|Where-Object{[string]$_.path-ceq$relative})
        if([string]$intent.event.event_id-cne[string]$event.event_id-or$owned.Count-ne1-or[string]$owned[0].sha256-cne(Get-MorphospaceFileSha256 $path)){throw "ResolveBlocker historical event '$($event.event_id)' has hash/identity-inconsistent retained blocker-resolution evidence."}
        if([string]$candidate.receipt_id-ceq[string]$Receipt.receipt_id-and[string]$candidate.unit_id-ceq[string]$Receipt.unit_id-and[string]$candidate.blocker.blocker_id-ceq[string]$Receipt.blocker.blocker_id-or(Get-MorphospaceCanonicalJsonSha256 $candidate)-ceq$CanonicalSha256){
            throw 'ResolveBlocker receipt identity or canonical receipt hash was already consumed.'
        }
    }
    foreach($file in @(Get-ChildItem (Join-Path $Workspace 'receipts') -File -Recurse -Filter *.json)){
        [void]$candidates.Add([IO.Path]::GetRelativePath($Workspace,$file.FullName).Replace('\','/'))
    }
    foreach($relative in $candidates){
        try{
            $path=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf
            $candidate=Read-MorphospaceProtocolJson $path
        }catch{continue}
        if([string]$candidate.schema-cne'rusty.morphospace.workflow.blocker_resolution_receipt.v1'){continue}
        $sameIdentity=([string]$candidate.receipt_id-ceq[string]$Receipt.receipt_id-and[string]$candidate.unit_id-ceq[string]$Receipt.unit_id-and[string]$candidate.blocker.blocker_id-ceq[string]$Receipt.blocker.blocker_id)
        $sameCanonical=(Get-MorphospaceCanonicalJsonSha256 $candidate)-ceq$CanonicalSha256
        if($sameIdentity-or$sameCanonical){throw 'ResolveBlocker receipt identity or canonical receipt hash was already consumed.'}
    }
}
function Invoke-MorphospaceResolveBlocker {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$BlockerResolutionReceipt,
        [string]$Timestamp='',
        [string]$OutPath='',
        [scriptblock]$BeforeTransitionHook,
        [switch]$Execute
    )
    $workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $BlockerResolutionReceipt).Path
    $schema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\blocker-resolution-receipt-v1.schema.json'
    if(-not(Test-Json -Json (Get-Content -Raw $input) -SchemaFile $schema)){throw 'Blocker resolution receipt does not satisfy its schema.'}
    $doc=Read-MorphospaceProtocolJson $input
    $statePath=Join-Path $workspace 'workspace.state.json';$state=Read-MorphospaceProtocolJson $statePath
    $unitRelative="iteration-units/$UnitId.json";$unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf)
    if([string]$doc.project_id-cne[string]$state.project_id-or[string]$doc.unit_id-cne$UnitId-or[string]$state.current_unit-cne$UnitId-or[string]$unit.status-cne'active'){throw 'ResolveBlocker requires the exact project and current unit with status active.'}
    $matches=@($state.blockers|Where-Object{[string]$_.blocker_id-ceq[string]$doc.blocker.blocker_id})
    if($matches.Count-ne1-or[string]$matches[0].condition-cne[string]$doc.blocker.condition-or[string]$matches[0].resume_when-cne[string]$doc.blocker.resume_when){throw 'ResolveBlocker requires one exact blocker condition and resume_when match.'}
    $remaining=@($state.blockers|Where-Object{[string]$_.blocker_id-cne[string]$doc.blocker.blocker_id})
    $remainingIds=@($remaining|ForEach-Object{[string]$_.blocker_id}|Sort-Object)
    $preservedIds=@($doc.preserve_blocker_ids|ForEach-Object{[string]$_}|Sort-Object)
    if(($remainingIds-join'|')-cne($preservedIds-join'|')){throw 'ResolveBlocker preserve_blocker_ids must exactly enumerate every other blocker.'}
    foreach($binding in @($doc.evidence)){
        $evidencePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$binding.path) -RequireLeaf
        if((Get-MorphospaceFileSha256 $evidencePath)-cne[string]$binding.sha256){throw "ResolveBlocker evidence hash mismatch for '$($binding.path)'."}
    }
    $mapDoc=Read-MorphospaceProtocolJson (Resolve-Path $RepoMapPath);$map=@{}
    foreach($entry in @($mapDoc.repositories)){
        $key=([string]$entry.repo_id).ToLowerInvariant()
        if($map.ContainsKey($key)){throw 'ResolveBlocker repository map contains duplicate or case-fold duplicate IDs.'}
        $map[$key]=$entry
    }
    $headIds=@($doc.repository_heads|ForEach-Object{[string]$_.repo_id})
    $headKeys=@($headIds|ForEach-Object{$_.ToLowerInvariant()})
    if(@($headKeys|Sort-Object -Unique).Count-ne$headKeys.Count){throw 'ResolveBlocker repository_heads contains duplicate or case-fold duplicate IDs.'}
    $mapIds=@($map.Keys|Sort-Object);$sortedHeadIds=@($headKeys|Sort-Object)
    if(($mapIds-join'|')-cne($sortedHeadIds-join'|')){throw 'ResolveBlocker repository_heads must exactly cover every authoritative repository-map entry.'}
    $sourceIds=@($doc.repository_sources|ForEach-Object{[string]$_.repo_id})
    $sourceKeys=@($sourceIds|ForEach-Object{$_.ToLowerInvariant()})
    if(@($sourceKeys|Sort-Object -Unique).Count-ne$sourceKeys.Count){throw 'ResolveBlocker repository_sources contains duplicate or case-fold duplicate IDs.'}
    if(($mapIds-join'|')-cne(@($sourceKeys|Sort-Object)-join'|')){throw 'ResolveBlocker repository_sources must exactly cover every authoritative repository-map entry.'}
    foreach($sourceSet in @($doc.repository_sources)){
        $paths=@($sourceSet.sources|ForEach-Object{[string]$_.path})
        $folded=@($paths|ForEach-Object{$_.ToLowerInvariant()})
        if(@($folded|Sort-Object -Unique).Count-ne$folded.Count){throw "ResolveBlocker repository_sources contains duplicate or case-fold duplicate paths for '$($sourceSet.repo_id)'."}
    }
    Assert-ResolveBlockerRepositories $doc $map
    $eventsPath=Join-Path $workspace 'iteration-events.jsonl'
    $events=@(Get-Content $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
    $canonicalReceiptHash=Get-MorphospaceCanonicalJsonSha256 $doc
    Assert-ResolveBlockerNotConsumed $workspace $doc $canonicalReceiptHash $events $schema
    if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('o')}
    $sequence=if($events.Count){[int]$events[-1].sequence+1}else{1}
    $eventId="$UnitId-blocker-resolved-$('{0:d4}'-f$sequence)"
    $relative=if($OutPath){[IO.Path]::GetRelativePath($workspace,[IO.Path]::GetFullPath($OutPath)).Replace('\','/')}else{"receipts/$([string]$doc.receipt_id).json"}
    if($relative-notmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'){throw 'ResolveBlocker output must be a portable top-level receipt path.'}
    $artifactTarget=Resolve-MorphospaceWorkspacePath $workspace $relative
    if($Execute-and([IO.Path]::GetFullPath($input)-ceq[IO.Path]::GetFullPath($artifactTarget)-or[IO.File]::Exists($artifactTarget))){throw 'ResolveBlocker requires a new transaction-owned output artifact distinct from its input.'}
    $hash=Get-MorphospaceFileSha256 $input
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=$sequence;timestamp=$Timestamp;project_id=[string]$doc.project_id;unit_id=$UnitId;event_type='state-transition';summary="Resolved blocker '$([string]$doc.blocker.blocker_id)' from hash-bound passing evidence while preserving all other workflow projections.";receipts=@($relative)}
    $beforeState=Read-MorphospaceProtocolJson $statePath
    $beforeUnitHash=Get-MorphospaceCanonicalJsonSha256 $unit
    $beforePending=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$state.pending_push_bundle})
    $beforeValidation=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$state.validation_checkpoint})
    $beforeCurrent=$state.current_unit
    if($Execute){
        if(-not$OutPath){throw 'Executed ResolveBlocker requires OutPath.'}
        $preHash=Get-MorphospaceCanonicalJsonSha256 $state;$preTail=if($events.Count){[string]$events[-1].event_id}else{$null}
        $state.blockers=$remaining;$state.last_event_id=$eventId
        if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$state.pending_push_bundle}))-cne$beforePending-or(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$state.validation_checkpoint}))-cne$beforeValidation-or[string]$state.current_unit-cne[string]$beforeCurrent-or(Get-MorphospaceCanonicalJsonSha256 $unit)-cne$beforeUnitHash){throw 'ResolveBlocker changed a preserved projection before transaction.'}
        if($BeforeTransitionHook){&$BeforeTransitionHook}
        Assert-ResolveBlockerRepositories $doc $map
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $unitRelative -EventsPath 'iteration-events.jsonl' -TargetState $state -TargetUnit $unit -Event $event -ExpectedStateSha256 $preHash -ExpectedUnitSha256 $beforeUnitHash -ExpectedEventTailId $preTail -Artifacts @([pscustomobject]@{source_path=$input;path=$relative;sha256=$hash})|Out-Null
    }
    $result=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$doc.project_id;unit_id=$UnitId;action='ResolveBlocker';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='blocker-resolved';status_before=[string]$unit.status;status_after=[string]$unit.status;current_unit_before=$beforeCurrent;current_unit_after=$state.current_unit;preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject][ordered]@{path=$relative;sha256=$hash};event_id=$(if($Execute){$eventId}else{$null})}
    $outSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\work-unit-automation-receipt-v2.schema.json'
    if(-not(Test-Json -Json ($result|ConvertTo-Json -Depth 32) -SchemaFile $outSchema)){throw 'ResolveBlocker emitted an invalid automation receipt.'}
    $result
}
Export-ModuleMember -Function Invoke-MorphospaceResolveBlocker
