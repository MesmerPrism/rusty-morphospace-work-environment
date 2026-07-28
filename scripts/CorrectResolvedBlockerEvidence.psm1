Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force

function Invoke-CorrectionGit {
    param([string]$Path,[string[]]$Arguments)
    $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$output=@(& git -C $Path @Arguments 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    if($code-ne0){throw "CorrectResolvedBlockerEvidence Git observation failed: git $($Arguments-join' ')"}
    (($output|ForEach-Object{[string]$_})-join"`n").Trim()
}
function Resolve-CorrectionSourcePath {
    param([string]$Repository,[string]$RelativePath)
    if($RelativePath-cmatch'\\'){throw "Correction repository source path must use forward slashes: '$RelativePath'."}
    $normalized=ConvertTo-MorphospaceProtocolRelativePath $RelativePath
    if($normalized-cne$RelativePath){throw "Correction repository source path is not normalized: '$RelativePath'."}
    $root=[IO.Path]::GetFullPath($Repository).TrimEnd('\','/')
    $candidate=[IO.Path]::GetFullPath([IO.Path]::Combine($root,$normalized))
    if(-not$candidate.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "Correction repository source path escapes its repository: '$RelativePath'."}
    Assert-MorphospaceNoReparseAncestor -Root $root -Candidate $candidate
    if(-not[IO.File]::Exists($candidate)){throw "Correction repository source file is missing: '$RelativePath'."}
    $attributes=[IO.File]::GetAttributes($candidate)
    if(($attributes-band[IO.FileAttributes]::Directory)-ne0-or($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Correction repository source is not a regular non-reparse file: '$RelativePath'."}
    $candidate
}
function Get-CorrectionRepositoryMap {
    param([string]$Path,[object]$Receipt)
    $mapDoc=Read-MorphospaceProtocolJson (Resolve-Path $Path);$map=@{}
    foreach($entry in @($mapDoc.repositories)){
        $key=([string]$entry.repo_id).ToLowerInvariant()
        if($map.ContainsKey($key)){throw 'Correction repository map contains duplicate or case-fold duplicate IDs.'}
        $map[$key]=$entry
    }
    $mapIds=@($map.Keys|Sort-Object)
    foreach($property in @('repository_heads','repository_sources')){
        $keys=@($Receipt.$property|ForEach-Object{([string]$_.repo_id).ToLowerInvariant()})
        if(@($keys|Sort-Object -Unique).Count-ne$keys.Count){throw "Correction $property contains duplicate or case-fold duplicate IDs."}
        if(($mapIds-join'|')-cne(@($keys|Sort-Object)-join'|')){throw "Correction $property must exactly cover every authoritative repository-map entry."}
    }
    foreach($sourceSet in @($Receipt.repository_sources)){
        $paths=@($sourceSet.sources|ForEach-Object{[string]$_.path});$folded=@($paths|ForEach-Object{$_.ToLowerInvariant()})
        if(@($folded|Sort-Object -Unique).Count-ne$folded.Count){throw "Correction repository_sources contains duplicate or case-fold duplicate paths for '$($sourceSet.repo_id)'."}
    }
    $map
}
function Assert-CorrectionRepositories {
    param([object]$Receipt,[hashtable]$Map)
    foreach($head in @($Receipt.repository_heads)){
        $repo=[IO.Path]::GetFullPath([string]$Map[([string]$head.repo_id).ToLowerInvariant()].path)
        if((Invoke-CorrectionGit $repo @('rev-parse','HEAD'))-cne[string]$head.revision-or(Invoke-CorrectionGit $repo @('branch','--show-current'))-cne[string]$head.branch){throw "Correction repository head changed for '$($head.repo_id)'."}
    }
    foreach($set in @($Receipt.repository_sources)){
        $repo=[IO.Path]::GetFullPath([string]$Map[([string]$set.repo_id).ToLowerInvariant()].path)
        foreach($source in @($set.sources)){
            $path=Resolve-CorrectionSourcePath $repo ([string]$source.path)
            if((Get-MorphospaceFileSha256 $path)-cne[string]$source.sha256){throw "Correction repository source hash mismatch for '$($set.repo_id):$($source.path)'."}
        }
    }
}
function Get-CorrectionBoundJson {
    param([string]$Workspace,[object]$Binding,[string]$Label)
    try{$path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Binding.path) -RequireLeaf}catch{throw "$Label is missing."}
    if((Get-MorphospaceFileSha256 $path)-cne[string]$Binding.sha256){throw "$Label hash mismatch."}
    try{$raw=Get-Content -Raw -LiteralPath $path;$document=$raw|ConvertFrom-Json}catch{throw "$Label is malformed or unreadable."}
    [pscustomobject]@{path=$path;raw=$raw;document=$document}
}
function Assert-CorrectionTransactionChain {
    param([string]$Workspace,[object]$Event,[object]$ReceiptBinding,[object]$IntentBinding,[object]$CompletionBinding,[string]$ExpectedReceiptSchema,[string]$ExpectedReceiptId,[string]$ExpectedBlockerId)
    $receiptResult=Get-CorrectionBoundJson $Workspace $ReceiptBinding 'Historical receipt'
    $intentResult=Get-CorrectionBoundJson $Workspace $IntentBinding 'Historical transition intent'
    $completionResult=Get-CorrectionBoundJson $Workspace $CompletionBinding 'Historical transition completion'
    $receipt=$receiptResult.document;$intent=$intentResult.document;$completion=$completionResult.document
    $transactionId="$([string]$Event.event_id)-transition"
    $expectedIntent="receipts/transactions/$transactionId.intent.json";$expectedCompletion="receipts/transactions/$transactionId.completion.json"
    if([string]$ReceiptBinding.path-notmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'-or[string]$IntentBinding.path-cne$expectedIntent-or[string]$CompletionBinding.path-cne$expectedCompletion){throw 'Historical receipt or transaction paths are not canonical for the event.'}
    $receiptSchemaPath=if($ExpectedReceiptSchema-ceq'rusty.morphospace.workflow.blocker_resolution_receipt.v1'){Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\blocker-resolution-receipt-v1.schema.json'}else{Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\blocker-resolution-correction-receipt-v1.schema.json'}
    if(-not(Test-Json -Json $receiptResult.raw -SchemaFile $receiptSchemaPath)){throw 'Historical receipt is schema-invalid.'}
    if([string]$receipt.schema-cne$ExpectedReceiptSchema-or[string]$receipt.receipt_id-cne$ExpectedReceiptId-or[string]$receipt.project_id-cne[string]$Event.project_id-or[string]$receipt.unit_id-cne[string]$Event.unit_id){throw 'Historical receipt schema or identity is inconsistent.'}
    $receiptBlocker=if($ExpectedReceiptSchema-ceq'rusty.morphospace.workflow.blocker_resolution_receipt.v1'){[string]$receipt.blocker.blocker_id}else{[string]$receipt.blocker_id}
    if($receiptBlocker-cne$ExpectedBlockerId){throw 'Historical receipt blocker identity is inconsistent.'}
    $intentEventJson=$intent.event|ConvertTo-Json -Depth 16 -Compress
    $eventJson=$Event|ConvertTo-Json -Depth 16 -Compress
    $targetStateHash=Get-MorphospaceCanonicalJsonSha256 -Value $intent.target.state.document
    $targetUnitHash=Get-MorphospaceCanonicalJsonSha256 -Value $intent.target.unit.document
    if(
        [string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or
        [string]$intent.transaction_id-cne$transactionId-or[string]$intent.status-cne'prepared'-or
        $intentEventJson-cne$eventJson-or
        [string]$intent.target.state.sha256-cne$targetStateHash-or
        [string]$intent.target.unit.sha256-cne$targetUnitHash-or
        [string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or
        [string]$completion.transaction_id-cne$transactionId-or[string]$completion.event_id-cne[string]$Event.event_id-or
        [string]$completion.status-cne'committed'-or[string]$completion.intent.role-cne'transition-ledger-intent'-or
        [string]$completion.intent.path-cne$expectedIntent-or[string]$completion.intent.schema-cne[string]$intent.schema-or
        [string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $intentResult.path)-or
        [string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or
        [string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256
    ){throw 'Historical completion-to-intent chain is inconsistent.'}
    $owned=@($intent.artifacts|Where-Object{[string]$_.path-ceq[string]$ReceiptBinding.path})
    if($owned.Count-ne1-or[string]$owned[0].sha256-cne(Get-MorphospaceFileSha256 $receiptResult.path)-or[Convert]::ToBase64String([IO.File]::ReadAllBytes($receiptResult.path))-cne[string]$owned[0].bytes_base64){throw 'Historical receipt is not uniquely hash-owned by its transition intent.'}
}
function Assert-CorrectionNotConsumed {
    param([string]$Workspace,[object]$Receipt,[string]$CanonicalHash,[object[]]$Events,[string]$SchemaPath)
    foreach($event in @($Events|Where-Object{[string]$_.event_id-match'-blocker-resolution-corrected-[0-9]{4}$'})){
        if([string]$event.event_type-cne'state-transition'-or@($event.receipts).Count-ne1){throw "Historical correction event '$($event.event_id)' is malformed."}
        $relative=[string]$event.receipts[0]
        try{$path=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf;$raw=Get-Content -Raw $path;$candidate=$raw|ConvertFrom-Json}catch{throw "Historical correction event '$($event.event_id)' has missing or malformed retained evidence."}
        if(-not(Test-Json -Json $raw -SchemaFile $SchemaPath)){throw "Historical correction event '$($event.event_id)' has schema-invalid retained evidence."}
        $transactionId="$([string]$event.event_id)-transition"
        $intentRelative="receipts/transactions/$transactionId.intent.json";$completionRelative="receipts/transactions/$transactionId.completion.json"
        $intentPath=Resolve-MorphospaceWorkspacePath $Workspace $intentRelative -RequireLeaf;$completionPath=Resolve-MorphospaceWorkspacePath $Workspace $completionRelative -RequireLeaf
        $binding=[pscustomobject]@{path=$relative;sha256=Get-MorphospaceFileSha256 $path}
        Assert-CorrectionTransactionChain $Workspace $event $binding ([pscustomobject]@{path=$intentRelative;sha256=Get-MorphospaceFileSha256 $intentPath}) ([pscustomobject]@{path=$completionRelative;sha256=Get-MorphospaceFileSha256 $completionPath}) 'rusty.morphospace.workflow.blocker_resolution_correction_receipt.v1' ([string]$candidate.receipt_id) ([string]$candidate.blocker_id)
        if(([string]$candidate.receipt_id-ceq[string]$Receipt.receipt_id-and[string]$candidate.unit_id-ceq[string]$Receipt.unit_id-and[string]$candidate.blocker_id-ceq[string]$Receipt.blocker_id)-or(Get-MorphospaceCanonicalJsonSha256 $candidate)-ceq$CanonicalHash){throw 'Correction receipt identity or canonical hash was already consumed.'}
    }
}
function Resolve-CorrectionJsonPointer {
    param([object]$Document,[string]$Pointer)
    $current=$Document
    foreach($rawToken in @($Pointer.Substring(1)-split'/')){
        $token=$rawToken.Replace('~1','/').Replace('~0','~')
        if($current-is [Array]){
            $index=0
            if(-not[int]::TryParse($token,[ref]$index)-or$index-lt0-or$index-ge$current.Count){throw 'Authority clarification JSON pointer does not resolve in the immutable unit.'}
            $current=$current[$index]
        }else{
            $property=@($current.PSObject.Properties|Where-Object{$_.Name-ceq$token})
            if($property.Count-ne1){throw 'Authority clarification JSON pointer does not resolve in the immutable unit.'}
            $current=$property[0].Value
        }
    }
    $current
}
function Invoke-MorphospaceCorrectResolvedBlockerEvidence {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$CorrectionReceipt,
        [string]$Timestamp='',
        [string]$OutPath='',
        [scriptblock]$BeforeTransitionHook,
        [ValidateSet('','after-intent','after-state','after-unit','after-event','after-projection','after-artifact')][string]$FaultAfter='',
        [switch]$Execute
    )
    $workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $CorrectionReceipt).Path
    $schema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\blocker-resolution-correction-receipt-v1.schema.json'
    $raw=Get-Content -Raw $input
    if(-not(Test-Json -Json $raw -SchemaFile $schema)){throw 'Blocker resolution correction receipt does not satisfy its schema.'}
    $doc=$raw|ConvertFrom-Json;$statePath=Join-Path $workspace 'workspace.state.json';$state=Read-MorphospaceProtocolJson $statePath
    $unitRelative="iteration-units/$UnitId.json";$unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf)
    if([string]$doc.project_id-cne[string]$state.project_id-or[string]$doc.unit_id-cne$UnitId-or[string]$state.current_unit-cne$UnitId-or[string]$unit.status-cne'active'){throw 'Correction requires the exact project and current active unit.'}
    $clarification=$doc.authority_clarification
    if([string]$clarification.unit.path-cne$unitRelative-or[string]$clarification.unit.sha256-cne(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf))){throw 'Authority clarification does not bind the exact immutable current unit bytes.'}
    $statement=Resolve-CorrectionJsonPointer $unit ([string]$clarification.statement.json_pointer)
    $statementHash=Get-MorphospaceSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false)).GetBytes([string]$clarification.statement.exact_text)
    if($statement-isnot[string]-or[string]$statement-cne[string]$clarification.statement.exact_text-or$statementHash-cne[string]$clarification.statement.exact_text_sha256){throw 'Authority clarification does not bind the exact retained unit statement.'}
    if(@($state.blockers|Where-Object{[string]$_.blocker_id-ceq[string]$doc.blocker_id}).Count-ne0){throw 'Correction requires the target blocker to remain absent.'}
    $liveIds=@($state.blockers|ForEach-Object{[string]$_.blocker_id}|Sort-Object);$preserved=@($doc.preserve_blocker_ids|ForEach-Object{[string]$_}|Sort-Object)
    if(($liveIds-join'|')-cne($preserved-join'|')){throw 'Correction preserve_blocker_ids must exactly enumerate all live blockers.'}
    foreach($binding in @($doc.evidence)){$path=Resolve-MorphospaceWorkspacePath $workspace ([string]$binding.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $path)-cne[string]$binding.sha256){throw "Correction evidence hash mismatch for '$($binding.path)'."}}
    $map=Get-CorrectionRepositoryMap $RepoMapPath $doc;Assert-CorrectionRepositories $doc $map
    $eventsPath=Join-Path $workspace 'iteration-events.jsonl';$events=@(Get-Content $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
    $originals=@($events|Where-Object{[string]$_.event_id-ceq[string]$doc.supersedes.event_id})
    if($originals.Count-ne1){throw 'Correction requires exactly one superseded historical event.'}
    $original=$originals[0]
    if([string]$original.event_id-notmatch'-blocker-resolved-[0-9]{4}$'-or[string]$original.event_type-cne'state-transition'-or[string]$original.project_id-cne[string]$doc.project_id-or[string]$original.unit_id-cne$UnitId-or@($original.receipts).Count-ne1-or[string]$original.receipts[0]-cne[string]$doc.supersedes.receipt.path){throw 'Superseded historical blocker-resolved event is inconsistent.'}
    Assert-CorrectionTransactionChain $workspace $original $doc.supersedes.receipt $doc.supersedes.intent $doc.supersedes.completion 'rusty.morphospace.workflow.blocker_resolution_receipt.v1' ([string]$doc.supersedes.original_receipt_id) ([string]$doc.blocker_id)
    $canonical=Get-MorphospaceCanonicalJsonSha256 $doc;Assert-CorrectionNotConsumed $workspace $doc $canonical $events $schema
    if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('o')};$sequence=[int]$events[-1].sequence+1;$eventId="$UnitId-blocker-resolution-corrected-$('{0:d4}'-f$sequence)"
    $relative=if($OutPath){[IO.Path]::GetRelativePath($workspace,[IO.Path]::GetFullPath($OutPath)).Replace('\','/')}else{"receipts/$([string]$doc.receipt_id).json"}
    if($relative-notmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'){throw 'Correction output must be a portable top-level receipt path.'}
    $target=Resolve-MorphospaceWorkspacePath $workspace $relative
    if($Execute-and([IO.Path]::GetFullPath($input)-ceq[IO.Path]::GetFullPath($target)-or[IO.File]::Exists($target))){throw 'Correction requires a new transaction-owned output artifact distinct from its input.'}
    $beforeState=Get-MorphospaceCanonicalJsonSha256 $state;$beforeUnit=Get-MorphospaceCanonicalJsonSha256 $unit;$preTail=[string]$events[-1].event_id
    $targetState=$state|ConvertTo-Json -Depth 100|ConvertFrom-Json;$targetState.last_event_id=$eventId
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=$sequence;timestamp=$Timestamp;project_id=[string]$doc.project_id;unit_id=$UnitId;event_type='state-transition';summary="Corrected retained evidence for resolved blocker '$([string]$doc.blocker_id)' without changing workflow projections.";receipts=@($relative)}
    if($Execute){
        if(-not$OutPath){throw 'Executed correction requires OutPath.'}
        if($BeforeTransitionHook){&$BeforeTransitionHook}
        Assert-CorrectionRepositories $doc $map
        $ledgerArgs=@{WorkspaceRoot=$workspace;TransactionId="$eventId-transition";StatePath='workspace.state.json';UnitPath=$unitRelative;EventsPath='iteration-events.jsonl';TargetState=$targetState;TargetUnit=$unit;Event=$event;ExpectedStateSha256=$beforeState;ExpectedUnitSha256=$beforeUnit;ExpectedEventTailId=$preTail;Artifacts=@([pscustomobject]@{source_path=$input;path=$relative;sha256=Get-MorphospaceFileSha256 $input})}
        if($FaultAfter){$ledgerArgs.FaultAfter=$FaultAfter}
        Start-MorphospaceTransitionLedger @ledgerArgs|Out-Null
    }
    $result=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$doc.project_id;unit_id=$UnitId;action='CorrectResolvedBlockerEvidence';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='blocker-resolution-corrected';status_before=[string]$unit.status;status_after=[string]$unit.status;current_unit_before=[string]$state.current_unit;current_unit_after=[string]$targetState.current_unit;preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject][ordered]@{path=$relative;sha256=Get-MorphospaceFileSha256 $input};event_id=$(if($Execute){$eventId}else{$null})}
    $outSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\work-unit-automation-receipt-v2.schema.json'
    if(-not(Test-Json -Json ($result|ConvertTo-Json -Depth 32) -SchemaFile $outSchema)){throw 'Correction emitted an invalid automation receipt.'}
    $result
}
Export-ModuleMember -Function Invoke-MorphospaceCorrectResolvedBlockerEvidence
