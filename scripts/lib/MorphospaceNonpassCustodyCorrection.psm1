Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')

function Assert-NonpassCustodyEqual([object]$Expected,[object]$Actual,[string]$Name){
    if((Get-MorphospaceCanonicalJsonSha256 $Expected)-cne(Get-MorphospaceCanonicalJsonSha256 $Actual)){throw "Nonpass custody $Name is detached."}
}
function Read-NonpassCustodyBinding([string]$Workspace,[object]$Binding){
    $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$Binding.path)
    if($relative-cne[string]$Binding.path){throw 'Nonpass custody binding path is noncanonical.'}
    $path=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf
    if((Get-MorphospaceFileSha256 $path)-cne[string]$Binding.sha256){throw "Nonpass custody immutable bytes drifted: $relative"}
    Read-MorphospaceProtocolJson $path
}
function Read-NonpassCustodyCommittedTransition([string]$Workspace,[string]$TransactionId){
    # Reuse the native structural historical predicate. It authenticates raw
    # intent/completion/artifacts and physical prefix placement without calling
    # candidate semantics or demanding old projections during an exact repair.
    Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')
    $owner=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1') -PassThru
    $proof=&$owner {param($w,$id)Get-ActiveRetirementPlanningTransition $w $id -HistoricalProjection} $Workspace $TransactionId
    if([string]$proof.intent.state.path-cne'workspace.state.json'-or[string]$proof.intent.events.path-cne'iteration-events.jsonl'-or[string]$proof.intent.unit.path-cne"iteration-units/$($proof.intent.event.unit_id).json"){throw 'Nonpass custody historical projection paths differ from their owner.'}
    $proof
}
function Read-NonpassCustodyTransition([string]$Workspace,[object]$Anchor){
    $id="$($Anchor.event_id)-transition"
    if([string]$Anchor.intent.path-cne"receipts/transactions/$id.intent.json"-or[string]$Anchor.completion.path-cne"receipts/transactions/$id.completion.json"){throw 'Nonpass custody transition anchor namespace is detached.'}
    $intent=Read-NonpassCustodyBinding $Workspace $Anchor.intent
    $completion=Read-NonpassCustodyBinding $Workspace $Anchor.completion
    $proof=Read-NonpassCustodyCommittedTransition $Workspace $id
    Assert-NonpassCustodyEqual $intent $proof.intent 'physical transition'
    Assert-NonpassCustodyEqual $completion $proof.completion 'physical completion'
    if([string]$intent.event.event_id-cne[string]$Anchor.event_id){throw 'Nonpass custody event anchor differs.'}
    $proof
}
function Get-NonpassCustodyEvents([string]$Workspace){
    $path=Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf
    $bytes=[IO.File]::ReadAllBytes($path)
    if($bytes.Length-eq0-or$bytes.Length-gt67108864-or$bytes[-1]-ne10){throw 'Nonpass custody requires a bounded complete LF-terminated physical ledger.'}
    $events=@();$ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($line in ([Text.UTF8Encoding]::new($false,$true).GetString($bytes)).Split([char]10)){
        if(-not$line){continue};$event=ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes($line))
        if([int]$event.sequence-ne($events.Count+1)-or-not$ids.Add([string]$event.event_id)){throw 'Nonpass custody physical ledger sequence or IDs are invalid.'}
        $events+=,$event
    }
    [pscustomobject]@{events=$events;sha256=Get-MorphospaceSha256Bytes $bytes;length=[long]$bytes.LongLength}
}
function Get-NonpassCustodyArtifactLocator([string]$Workspace,[string]$ReceiptPath,[string]$Literal){
    if(-not$Literal-or$Literal-cmatch'[\x00-\x1f\x7f]|(?:^|[\\/])\.\.?([\\/]|$)'){throw 'Nonpass custody evidence path is empty or unsafe.'}
    if([IO.Path]::IsPathFullyQualified($Literal)){return [IO.Path]::GetFullPath($Literal)}
    [IO.Path]::GetFullPath((Join-Path (Split-Path (Resolve-MorphospaceWorkspacePath $Workspace $ReceiptPath -RequireLeaf) -Parent) $Literal))
}
function Get-NonpassCustodyArtifactPath([string]$Workspace,[string]$ReceiptPath,[string]$Literal){
    $path=Get-NonpassCustodyArtifactLocator $Workspace $ReceiptPath $Literal
    $cursor=$path
    while($cursor){
        if([IO.File]::Exists($cursor)-or[IO.Directory]::Exists($cursor)){
            $attributes=[IO.File]::GetAttributes($cursor)
            if(($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw [IO.InvalidDataException]::new('Nonpass custody evidence traverses a reparse point.')}
        }
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent-ceq$cursor){break};$cursor=$parent
    }
    if([IO.Directory]::Exists($path)){throw [IO.InvalidDataException]::new('Nonpass custody evidence is a directory.')}
    $path
}
function Get-NonpassCustodyArtifactObservation([string]$Path){
    # File.Exists deliberately does not classify access denied as missing.
    try{$attributes=[IO.File]::GetAttributes($Path)}catch [IO.FileNotFoundException]{return [pscustomobject]@{state='missing';sha256=$null}}catch [IO.DirectoryNotFoundException]{return [pscustomobject]@{state='missing';sha256=$null}}
    if(($attributes-band([IO.FileAttributes]::Directory-bor[IO.FileAttributes]::ReparsePoint))-ne0){throw [IO.InvalidDataException]::new('Nonpass custody payload is not one ordinary file.')}
    [pscustomobject]@{state='different';sha256=Get-MorphospaceFileSha256 $Path}
}
function Assert-NonpassCustodyReceiptReturn([string]$Workspace,[string]$ReceiptPath,[object]$Receipt,[string]$ReceiptSha256,[string]$ReturnEventId){
    $id=[string]$Receipt.unit_id;$result=[string]$Receipt.result
    if($ReturnEventId-cnotmatch('^'+[regex]::Escape($id)+'-validation-'+[regex]::Escape($result)+'-return-[0-9]{4,}$')){throw 'Nonpass custody disposition requires its exact retained Return event.'}
    $returned=Read-NonpassCustodyCommittedTransition $Workspace "$ReturnEventId-transition"
    $event=$returned.intent.event;$checkpoint=$returned.intent.target.state.document.validation_checkpoint
    if([string]$event.event_id-cne$ReturnEventId-or[string]$event.project_id-cne[string]$Receipt.project_id-or[string]$event.unit_id-cne$id-or[string]$event.event_type-cne'validation'-or@($event.receipts).Count-ne2-or$ReceiptPath-cnotin@([string]$event.receipts[0],[string]$event.receipts[1])-or@($returned.intent.artifacts).Count-ne1-or[string]$returned.intent.artifacts[0].path-cne[string]$event.receipts[1]-or[string]$returned.intent.artifacts[0].sha256-cne$ReceiptSha256-or[string]$checkpoint.receipt-cne[string]$event.receipts[0]-or[string]$checkpoint.result-cne$result-or[string]$checkpoint.tier-cne[string]$Receipt.tier){throw 'Nonpass custody receipt does not belong to its exact retained Return event.'}
    foreach($relative in @($event.receipts)){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace ([string]$relative) -RequireLeaf))-cne$ReceiptSha256){throw 'Nonpass custody exact retained Return receipt bytes drifted.'}}
}
function Assert-NonpassCustodyReceiptPayloads([string]$Workspace,[string]$ReceiptPath,[object[]]$Rows,[string]$ReturnEventId){
    $receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace $ReceiptPath -RequireLeaf)
    if([string]$receipt.result-cnotin@('fail','blocked','partial')){throw 'Nonpass custody predicate cannot consume PASS or accepted evidence.'}
    $sha=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $ReceiptPath -RequireLeaf)
    Assert-NonpassCustodyReceiptReturn $Workspace $ReceiptPath $receipt $sha $ReturnEventId
    foreach($artifact in @($receipt.artifacts)){
        $matches=@($Rows|Where-Object{[string]$_.project_id-ceq[string]$receipt.project_id-and[string]$_.unit_id-ceq[string]$receipt.unit_id-and[string]$_.return_event_id-ceq$ReturnEventId-and([string]$_.receipt_path-ceq$ReceiptPath-or[string]$_.retained_path-ceq$ReceiptPath)-and[string]$_.receipt_sha256-ceq$sha-and[string]$_.artifact_id-ceq[string]$artifact.artifact_id-and[string]$_.path-ceq[string]$artifact.path-and[string]$_.expected_sha256-ceq[string]$artifact.sha256})
        if($matches.Count-gt1){throw 'Nonpass custody artifact has ambiguous historical dispositions.'}
        if($matches.Count-eq1){continue}
        $path=Get-NonpassCustodyArtifactPath $Workspace $ReceiptPath ([string]$artifact.path)
        if((Get-MorphospaceFileSha256 $path)-cne([string]$artifact.sha256).ToLowerInvariant()){throw 'Historical nonpass evidence bytes drifted.'}
    }
}
function Assert-NonpassCustodyPathClass([string]$Workspace,[object]$Candidate,[object]$OldFreeze,[object]$Row,[string]$Resolved,[switch]$Observe){
    $mapPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Candidate.expected.repository_map_path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $mapPath)-cne[string]$Candidate.expected.repository_map_sha256){throw 'Nonpass custody repository map raw binding drifted.'}
    $map=Read-MorphospaceProtocolJson $mapPath
    $entries=@($map.repositories|Where-Object repo_id -CEQ ([string]$Row.repo_id))
    $scopes=@($OldFreeze.intent.target.unit.document.allowed_repositories|Where-Object repo_id -CEQ ([string]$Row.repo_id))
    $final=@($OldFreeze.candidate.final_repositories|Where-Object repo_id -CEQ ([string]$Row.repo_id))
    if($entries.Count-ne1-or$scopes.Count-ne1-or$final.Count-ne1){throw 'Nonpass custody defect does not belong to an actual declared writable frozen Git source.'}
    $repository=[IO.Path]::GetFullPath([string]$entries[0].path).TrimEnd('\','/')
    $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if([string]$Row.artifact_class-ceq'git-index'){
        if($Observe){
            $index=@(&git -C $repository rev-parse --path-format=absolute --git-path index 2>&1)
            if($LASTEXITCODE-ne0-or$index.Count-ne1-or-not$Resolved.Equals([IO.Path]::GetFullPath([string]$index[0]),$comparison)){throw 'Nonpass custody Git index class is not the actual worktree index.'}
        }
    }elseif([string]$Row.artifact_class-ceq'mutable-source'){
        if(-not$Resolved.StartsWith($repository+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'Nonpass custody source path is outside its declared Git worktree.'}
        $relative=[IO.Path]::GetRelativePath($repository,$Resolved).Replace('\','/')
        if($relative.StartsWith('.git/',[StringComparison]::OrdinalIgnoreCase)-or$relative-ceq'.git'){throw 'Nonpass custody source class cannot name Git administration.'}
        $writable=$false
        foreach($allowed in @($scopes[0].allowed_paths)){
            $raw=[string]$allowed;$base=ConvertTo-MorphospaceProtocolRelativePath ($raw.TrimEnd('/'))
            if($relative-ceq$base-or($raw.EndsWith('/')-and$relative.StartsWith($base+'/',[StringComparison]::Ordinal))){$writable=$true;break}
        }
        if(-not$writable){throw 'Nonpass custody source class is outside the actual admitted writable paths.'}
        if($Observe){
            $tree=@(&git --literal-pathspecs -C $repository ls-tree ([string]$final[0].commit) -- $relative 2>&1)
            if($LASTEXITCODE-ne0-or$tree.Count-ne1-or[string]$tree[0]-cnotmatch'^(100644|100755) blob [0-9a-f]{40}\t'){throw 'Nonpass custody source class is not an original frozen regular source blob.'}
        }
    }else{throw 'Nonpass custody path class is unsupported.'}
}
function Read-NonpassCustodyDefect([string]$Workspace,[object]$Candidate,[object[]]$Events,[switch]$Observe){
    $owner=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if(-not(Test-Json -Json ($Candidate|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $owner 'schemas/candidate-freeze-v4.schema.json'))){throw 'Nonpass custody v4 request is malformed.'}
    $d=$Candidate.nonpass_custody_defect;$id=[string]$Candidate.unit_id
    if([string]$d.project_id-cne[string]$Candidate.project_id-or[string]$d.unit_id-cne$id){throw 'Nonpass custody defect project/unit differs.'}
    $freeze=Read-NonpassCustodyTransition $Workspace $d.freeze;$begin=Read-NonpassCustodyTransition $Workspace $d.begin;$returned=Read-NonpassCustodyTransition $Workspace $d.return
    if($freeze.intent.target.unit.document.PSObject.Properties.Name-ccontains'tooling_context'-or$returned.intent.target.unit.document.PSObject.Properties.Name-ccontains'tooling_context'){throw 'Native nonpass custody v4 recovery currently supports only units without a sealed tooling context.'}
    $old=Read-NonpassCustodyBinding $Workspace ([pscustomobject]@{path=[string]$Candidate.predecessor.freeze.receipt_path;sha256=[string]$Candidate.predecessor.freeze.receipt_sha256})
    if([string]$d.freeze.event_id-cne"$($old.freeze_id)-recorded"-or[string]$old.freeze_id-cne[string]$Candidate.predecessor.freeze.freeze_id-or[string]$old.unit_id-cne$id-or[string]$old.project_id-cne[string]$Candidate.project_id-or[string]$d.return.event_id-cne[string]$Candidate.predecessor.return_event_id){throw 'Nonpass custody freeze or Return identity differs from the exact predecessor.'}
    if([string]$old.schema-cnotin@('rusty.morphospace.workflow.candidate_freeze.v1','rusty.morphospace.workflow.candidate_freeze.v3','rusty.morphospace.workflow.candidate_freeze.v4')){throw 'Nonpass custody original freeze producer is unsupported.'}
    if(@($freeze.intent.artifacts).Count-ne1-or[string]$freeze.intent.artifacts[0].path-cne[string]$Candidate.predecessor.freeze.receipt_path-or[string]$freeze.intent.artifacts[0].sha256-cne[string]$Candidate.predecessor.freeze.receipt_sha256){throw 'Nonpass custody original frozen receipt is not its exact ledger artifact.'}
    Assert-NonpassCustodyEqual $Candidate.predecessor.freeze $freeze.intent.target.unit.document.candidate_freeze 'old frozen owner marker'
    $start=[int]$freeze.intent.event.sequence;$end=[int]$returned.intent.event.sequence
    $begins=@($Events|Where-Object{[int]$_.sequence-gt$start-and[int]$_.sequence-le$end-and[string]$_.event_id-cmatch('^'+[regex]::Escape($id)+'-validating-[0-9]{4,}$')})
    if($begins.Count-ne1-or[string]$begins[0].event_id-cne[string]$d.begin.event_id-or[int]$begin.intent.event.sequence-ne($start+1)-or$end-le[int]$begin.intent.event.sequence){throw 'Nonpass custody requires the exact first Begin and later nonpass Return.'}
    $previous=$freeze.intent
    foreach($event in @($Events|Where-Object{[int]$_.sequence-gt$start-and[int]$_.sequence-le$end})){
        if([string]$event.unit_id-cne$id-or[string]$event.project_id-cne[string]$Candidate.project_id){throw 'Nonpass custody prefix interleaves another owner.'}
        $tx="$($event.event_id)-transition"
        $proof=Read-NonpassCustodyCommittedTransition $Workspace $tx
        Assert-NonpassCustodyEqual $event $proof.intent.event 'prefix event'
        if([string]$proof.intent.pre.state.sha256-cne[string]$previous.target.state.sha256-or[string]$proof.intent.pre.unit.sha256-cne[string]$previous.target.unit.sha256-or[string]$proof.intent.expected.event_tail_id-cne[string]$previous.event.event_id){throw 'Nonpass custody prefix state/unit chain is detached.'}
        $previous=$proof.intent
    }
    $receipt=Read-NonpassCustodyBinding $Workspace $d.original_receipt;$retained=Read-NonpassCustodyBinding $Workspace $d.retained_receipt
    Assert-NonpassCustodyEqual $receipt $retained 'retained receipt equality'
    $result=[string]$receipt.result;$checkpoint=$returned.intent.target.state.document.validation_checkpoint
    if($result-cnotin@('fail','blocked','partial')-or[string]$receipt.schema-cne'rusty.morphospace.workflow.validation_receipt.v1'-or[string]$receipt.project_id-cne[string]$Candidate.project_id-or[string]$receipt.unit_id-cne$id-or[string]$d.result-cne$result-or[string]$d.tier-cne[string]$receipt.tier-or[string]$d.receipt_schema-cne[string]$receipt.schema-or[string]$d.original_receipt.canonical_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $receipt)-or[string]$d.retained_receipt.canonical_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $retained)-or[string]$d.original_receipt.sha256-cne[string]$d.retained_receipt.sha256){throw 'Nonpass custody requires immutable exact original/retained NONPASS receipt bytes and identity.'}
    if(-not(Test-Json -Json ($receipt|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $owner 'schemas/validation-receipt.schema.json'))){throw 'Nonpass custody old receipt schema is malformed.'}
    Assert-NonpassCustodyEqual @($old.final_repositories) @($d.frozen_repositories) 'old frozen source vector'
    if([string]$returned.intent.event.event_id-cnotmatch('^'+[regex]::Escape($id)+'-validation-'+$result+'-return-[0-9]{4,}$')-or@($returned.intent.event.receipts).Count-ne2-or[string]$returned.intent.event.receipts[0]-cne[string]$d.original_receipt.path-or[string]$returned.intent.event.receipts[1]-cne[string]$d.retained_receipt.path-or@($returned.intent.artifacts).Count-ne1-or[string]$returned.intent.artifacts[0].path-cne[string]$d.retained_receipt.path-or[string]$returned.intent.artifacts[0].sha256-cne[string]$d.retained_receipt.sha256-or[string]$Candidate.predecessor.validation_receipt.path-cne[string]$d.retained_receipt.path-or[string]$Candidate.predecessor.validation_receipt.sha256-cne[string]$d.retained_receipt.sha256-or[string]$checkpoint.receipt-cne[string]$d.original_receipt.path-or[string]$checkpoint.result-cne$result-or[string]$checkpoint.tier-cne[string]$receipt.tier){throw 'Nonpass custody original/retained receipt does not belong to this exact Return.'}
    foreach($repository in @($old.final_repositories)){$revisions=@($receipt.repository_revisions|Where-Object repo_id -CEQ ([string]$repository.repo_id));if($revisions.Count-ne1-or[string]$revisions[0].head_revision-cne[string]$repository.commit){throw 'Nonpass custody receipt frozen source revision differs.'}}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in @($receipt.artifacts)){if(-not$ids.Add([string]$artifact.artifact_id)){throw 'Nonpass custody receipt repeats artifact IDs.'}}
    foreach($evidence in @($receipt.criteria)+@($receipt.gates)+@(if($null-ne$receipt.device_validation){$receipt.device_validation})){foreach($ref in @($evidence.evidence_refs)){if(-not$ids.Contains([string]$ref)){throw 'Nonpass custody receipt references unknown evidence.'}}}
    $rows=@();$named=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($row in @($d.artifacts)){
        if(-not$named.Add([string]$row.artifact_id)){throw 'Nonpass custody defect repeats an artifact.'}
        $observedAt=Test-MorphospaceStrictUtcTimestamp ([string]$row.observed_at)
        if($observedAt-lt(Test-MorphospaceStrictUtcTimestamp ([string]$returned.intent.created_at))-or-not([string]$row.reason).Trim()){throw 'Nonpass custody observation time or reason is detached from the failed Return.'}
        if($Observe-and$observedAt-gt[DateTime]::UtcNow.AddMinutes(5)){throw 'Nonpass custody observation time is in the future.'}
        $artifacts=@($receipt.artifacts|Where-Object artifact_id -CEQ ([string]$row.artifact_id))
        if($artifacts.Count-ne1-or[string]$artifacts[0].path-cne[string]$row.path-or[string]$artifacts[0].sha256-cne[string]$row.expected_sha256){throw 'Nonpass custody defect tuple is not the literal old receipt artifact.'}
        if([string]$artifacts[0].kind-ceq'source-delivery-landing'){throw 'Nonpass custody correction does not support typed source-delivery-landing evidence.'}
        # A historical class belongs to the exact immutable request, original
        # native execution and independently authenticated C. Its mutable old
        # payload, ancestry and Git administration need not still exist. Only
        # initial issuance observes them; immutable map/scope/vector remain exact.
        $resolved=if($Observe){Get-NonpassCustodyArtifactPath $Workspace ([string]$d.original_receipt.path) ([string]$row.path)}else{Get-NonpassCustodyArtifactLocator $Workspace ([string]$d.original_receipt.path) ([string]$row.path)}
        Assert-NonpassCustodyPathClass $Workspace $Candidate ([pscustomobject]@{intent=$freeze.intent;candidate=$old}) $row $resolved -Observe:$Observe
        if($Observe){$observation=Get-NonpassCustodyArtifactObservation $resolved;if([string]$observation.sha256-ceq[string]$row.expected_sha256){throw 'Nonpass custody defect names unchanged payload.'};Assert-NonpassCustodyEqual $row.observation $observation 'actual missing/different observation'}
        $rows+=,[pscustomobject]@{project_id=[string]$Candidate.project_id;unit_id=$id;return_event_id=[string]$d.return.event_id;receipt_path=[string]$d.original_receipt.path;receipt_sha256=[string]$d.original_receipt.sha256;retained_path=[string]$d.retained_receipt.path;artifact_id=[string]$row.artifact_id;path=[string]$row.path;expected_sha256=[string]$row.expected_sha256}
    }
    [pscustomobject]@{rows=$rows;return_sequence=$end;candidate=$Candidate}
}

function Get-NonpassCustodyCommittedInventory([string]$Workspace){
    $snapshot=Get-NonpassCustodyEvents $Workspace;$rows=@();$keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($event in @($snapshot.events)){
        if(@($event.receipts).Count-ne1-or[string]$event.event_id-cnotmatch'-recorded$'){continue}
        $discoveryPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($event.event_id)-transition.intent.json"
        if(-not[IO.File]::Exists($discoveryPath)){continue}
        $discovery=Read-MorphospaceProtocolJson $discoveryPath
        if($discovery.PSObject.Properties.Name-cnotcontains'artifacts'){continue}
        $candidates=@(foreach($artifact in @($discovery.artifacts)){
            try{$item=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$artifact.bytes_base64))}catch{continue}
            if($null-ne$item-and$item.PSObject.Properties.Name-ccontains'schema'-and[string]$item.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v4'){$item}
        })
        if($candidates.Count-eq0){continue};if($candidates.Count-ne1){throw 'Nonpass custody committed intent repeats a correction.'}
        $relative=[string]$event.receipts[0];$path=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf
        $document=Read-MorphospaceProtocolJson $path
        Assert-NonpassCustodyEqual $candidates[0] $document 'physical committed correction'
        # An exact pending correction is never inventory authority. Its writer
        # may validate its own physical request separately during repair.
        if(-not[IO.File]::Exists((Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($event.event_id)-transition.completion.json"))){continue}
        $proof=Read-NonpassCustodyCommittedTransition $Workspace "$($event.event_id)-transition"
        if(@($proof.intent.artifacts).Count-ne1-or[string]$proof.intent.artifacts[0].path-cne$relative-or[string]$proof.intent.artifacts[0].sha256-cne(Get-MorphospaceFileSha256 $path)-or$relative-cne"receipts/$($document.freeze_id).json"){throw 'Nonpass custody committed v4 artifact is detached.'}
        Assert-NonpassCustodyEqual $event $proof.intent.event 'committed v4 event'
        $defect=Read-NonpassCustodyDefect $Workspace $document @($snapshot.events)
        if([int]$event.sequence-le$defect.return_sequence-or[string]$proof.intent.expected.event_tail_id-cne[string]$document.expected.event_tail_id-or[string]$proof.intent.pre.state.sha256-cne[string]$document.expected.state_sha256-or[string]$proof.intent.pre.unit.sha256-cne[string]$document.expected.unit_sha256){throw 'Nonpass custody committed v4 has future/cyclic/stale anchors.'}
        $endpoint=Read-NonpassCustodyCommittedTransition $Workspace "$($document.expected.event_tail_id)-transition"
        if([int]$endpoint.intent.event.sequence-ne([int]$event.sequence-1)-or[string]$endpoint.intent.target.state.sha256-cne[string]$proof.intent.pre.state.sha256-or[string]$endpoint.intent.target.unit.sha256-cne[string]$proof.intent.pre.unit.sha256){throw 'Nonpass custody committed v4 endpoint is not its actual predecessor.'}
        $before=$endpoint.intent.target.unit.document;$state=$endpoint.intent.target.state.document
        if($before.PSObject.Properties.Name-ccontains'tooling_context'-or$proof.intent.target.unit.document.PSObject.Properties.Name-ccontains'tooling_context'){throw 'Committed native nonpass custody v4 recovery contains an unsupported sealed tooling context.'}
        if([string]$before.status-cne'active'-or[string]$state.current_unit-cne[string]$document.unit_id-or$null-ne$state.next_ready_unit-or@($state.blockers).Count-ne0-or$null-ne$state.pending_push_bundle){throw 'Nonpass custody committed v4 pre-owner is ineligible.'}
        Assert-NonpassCustodyEqual $document.predecessor.freeze $before.candidate_freeze 'committed v4 predecessor marker'
        if(($before.PSObject.Properties.Name-ccontains'work_mode'-and[string]$before.work_mode-cne'feature')-or([string]$before.project_id-ceq'morphospace-platform-iteration'-and[string]$before.unit_id-ceq'wf-005')-or($before.PSObject.Properties.Name-ccontains'tags'-and@($before.tags|Where-Object{[string]$_-eq'receipt-security'}).Count-ne0)){throw 'Nonpass custody committed v4 targets an ineligible producer.'}
        $targetUnit=$before|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
        $targetUnit.candidate_freeze=[pscustomobject]@{freeze_id=[string]$document.freeze_id;receipt_path=$relative;receipt_sha256=Get-MorphospaceFileSha256 $path}
        $targetState=$state|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
        $targetState.last_event_id=[string]$event.event_id;$targetState.validation_checkpoint=$null
        if($targetState.PSObject.Properties.Name-ccontains'normal_validation_selection'){$targetState.normal_validation_selection=$null}
        Assert-NonpassCustodyEqual $targetUnit $proof.intent.target.unit.document 'committed v4 unit projection'
        Assert-NonpassCustodyEqual $targetState $proof.intent.target.state.document 'committed v4 state projection'
        # This assertion is provided by the independently adopted Root adapter.
        # Candidate receipts or a caller-selected authority path never grant trust.
        $adapterPath=Join-Path $PSScriptRoot 'MorphospaceNativeNonpassRecoveryAuthorization.psm1'
        if(-not[IO.File]::Exists($adapterPath)){throw 'Nonpass custody independently trusted recovery authorization is unavailable.'}
        $adapterModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceNativeNonpassRecoveryAuthorization.psm1') -PassThru
        $adapter=$adapterModule.ExportedCommands['Assert-MorphospaceHistoricalNativeNonpassRecoveryAuthorization']
        if($null-eq$adapter){throw 'Nonpass custody independently trusted recovery authorization is unavailable.'}
        $intentRelative="receipts/transactions/$($proof.intent.transaction_id).intent.json";$completionRelative="receipts/transactions/$($proof.intent.transaction_id).completion.json"
        & $adapterModule.ExportedCommands['Assert-MorphospaceHistoricalNativeNonpassRecoveryAuthorization'] -WorkspaceRoot $Workspace -Request $document -Intent $proof.intent -Completion $proof.completion -ExecutorOrigin ([pscustomobject]@{source_qualification_path=[string]$document.recovery_authorization.source_qualification_path;request_path=$path;request_raw_sha256=Get-MorphospaceFileSha256 $path;intent_path=Resolve-MorphospaceWorkspacePath $Workspace $intentRelative -RequireLeaf;intent_raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $intentRelative -RequireLeaf);completion_path=Resolve-MorphospaceWorkspacePath $Workspace $completionRelative -RequireLeaf;completion_raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $completionRelative -RequireLeaf)})|Out-Null
        foreach($row in @($defect.rows)){$key=Get-MorphospaceCanonicalJsonSha256 $row;if(-not$keys.Add($key)){throw 'Nonpass custody cumulative inventory repeats a defect tuple.'};$rows+=,$row}
    }
    foreach($group in @($rows|Group-Object -Property return_event_id,receipt_path -CaseSensitive)){
        $row=$group.Group[0]
        Assert-NonpassCustodyReceiptPayloads $Workspace ([string]$row.receipt_path) @($rows) ([string]$row.return_event_id)
    }
    $after=Get-NonpassCustodyEvents $Workspace
    if($snapshot.sha256-cne$after.sha256-or$snapshot.length-ne$after.length){throw 'Nonpass custody ledger changed during structural authentication.'}
    $rows
}
function Assert-NonpassCustodyCommittedCorrection([string]$Workspace,[string]$TransactionId){
    $proof=Read-NonpassCustodyCommittedTransition $Workspace $TransactionId
    if(@($proof.intent.artifacts).Count-ne1){throw 'Committed nonpass custody correction lacks its sole native artifact.'}
    $artifact=$proof.intent.artifacts[0];$candidate=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$artifact.bytes_base64))
    if([string]$candidate.schema-cne'rusty.morphospace.workflow.candidate_freeze.v4'-or$TransactionId-cne"$($candidate.freeze_id)-recorded-transition"-or[string]$artifact.path-cne"receipts/$($candidate.freeze_id).json"){throw 'Committed nonpass custody correction identity is detached.'}
    # The typed correction always authenticates its original owner signature,
    # even if a caller needs no payload disposition because bytes match again.
    $rows=@(Get-NonpassCustodyCommittedInventory $Workspace)
    foreach($named in @($candidate.nonpass_custody_defect.artifacts)){
        $found=@($rows|Where-Object{[string]$_.project_id-ceq[string]$candidate.project_id-and[string]$_.unit_id-ceq[string]$candidate.unit_id-and[string]$_.return_event_id-ceq[string]$candidate.nonpass_custody_defect.return.event_id-and[string]$_.receipt_sha256-ceq[string]$candidate.nonpass_custody_defect.original_receipt.sha256-and[string]$_.artifact_id-ceq[string]$named.artifact_id-and[string]$_.path-ceq[string]$named.path-and[string]$_.expected_sha256-ceq[string]$named.expected_sha256})
        if($found.Count-ne1){throw 'Committed nonpass custody correction is absent from its authenticated inventory.'}
    }
}
function Assert-NonpassCustodyLiveAuthorization {
    param([string]$Workspace,[string]$RequestPath,[string]$PendingIntentPath='')
    $candidate=Read-MorphospaceProtocolJson $RequestPath
    $state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'workspace.state.json' -RequireLeaf)
    $map=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$candidate.expected.repository_map_path) -RequireLeaf)
    $observed=@(foreach($entry in @($candidate.final_repositories)){
        $mapped=@($map.repositories|Where-Object repo_id -CEQ ([string]$entry.repo_id));if($mapped.Count-ne1){throw 'Nonpass custody authorization source mapping is ambiguous.'}
        $repository=[string]$mapped[0].path
        $commit=(@(&git -C $repository rev-parse HEAD 2>&1)-join'').Trim();if($LASTEXITCODE-ne0){throw 'Nonpass custody actual source commit observation failed.'}
        $tree=(@(&git -C $repository rev-parse 'HEAD^{tree}' 2>&1)-join'').Trim();if($LASTEXITCODE-ne0){throw 'Nonpass custody actual source tree observation failed.'}
        [pscustomobject]@{repo_id=[string]$entry.repo_id;commit=$commit;tree=$tree}
    })
    $bindings=[ordered]@{request_path=[IO.Path]::GetFullPath($RequestPath);request_raw_sha256=Get-MorphospaceFileSha256 $RequestPath;project_raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace 'project.spec.json' -RequireLeaf);state_raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace 'workspace.state.json' -RequireLeaf);unit_raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace "iteration-units/$($candidate.unit_id).json" -RequireLeaf);feature_lock_raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace 'feature.lock.json' -RequireLeaf);events_raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf);events_length=([IO.FileInfo](Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf)).Length;event_tail_id=[string]$state.last_event_id;source_composition_raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace ([string]$candidate.expected.source_composition_path) -RequireLeaf);repository_map_raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace ([string]$candidate.expected.repository_map_path) -RequireLeaf);final_repositories=$observed}
    if(-not$PendingIntentPath){$pending=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($candidate.freeze_id)-recorded-transition.intent.json";if([IO.File]::Exists($pending)){$PendingIntentPath=$pending}}
    if($PendingIntentPath){$bindings.mode='pending';$bindings.execution_intent_path=[IO.Path]::GetFullPath($PendingIntentPath);$bindings.execution_intent_raw_sha256=Get-MorphospaceFileSha256 $PendingIntentPath}
    $adapterPath=Join-Path $PSScriptRoot 'MorphospaceNativeNonpassRecoveryAuthorization.psm1'
    if(-not[IO.File]::Exists($adapterPath)){throw 'Nonpass custody independently trusted recovery authorization is unavailable.'}
    $adapterModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceNativeNonpassRecoveryAuthorization.psm1') -PassThru
    $adapter=$adapterModule.ExportedCommands['Assert-MorphospaceNativeNonpassRecoveryAuthorization']
    if($null-eq$adapter){throw 'Nonpass custody independently trusted recovery authorization is unavailable.'}
    & $adapterModule.ExportedCommands['Assert-MorphospaceNativeNonpassRecoveryAuthorization'] -WorkspaceRoot $Workspace -Request $candidate -CurrentBindings ([pscustomobject]$bindings) -ExecutorRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)|Out-Null
}
function Assert-NonpassCustodyReceiptArtifacts {
    param([string]$WorkspaceRoot,[string]$ReceiptPath,[string]$RecoveryRequestPath='',[string]$ReturnEventId)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    $receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $ReceiptPath -RequireLeaf)
    if([string]$receipt.result-cnotin@('fail','blocked','partial')){throw 'Nonpass custody predicate cannot consume PASS or accepted evidence.'}
    # Matching historical payloads need no disposition. Preserve the ordinary
    # strict path without looking for correction records or performing crypto.
    $strict=$true
    foreach($artifact in @($receipt.artifacts)){
        $null=Get-NonpassCustodyArtifactLocator $workspace $ReceiptPath ([string]$artifact.path)
        try{
            $path=Get-NonpassCustodyArtifactPath $workspace $ReceiptPath ([string]$artifact.path)
            $observed=Get-NonpassCustodyArtifactObservation $path
            if([string]$observed.state-ceq'missing'-or[string]$observed.sha256-cne([string]$artifact.sha256).ToLowerInvariant()){$strict=$false}
        }catch [IO.InvalidDataException]{$strict=$false}catch [IO.IOException]{$strict=$false}catch [UnauthorizedAccessException]{$strict=$false}
    }
    if($strict){return}
    if($RecoveryRequestPath){Assert-NonpassCustodyLiveAuthorization $workspace $RecoveryRequestPath}
    $rows=@(Get-NonpassCustodyCommittedInventory $workspace)
    if($RecoveryRequestPath){$candidate=Read-MorphospaceProtocolJson $RecoveryRequestPath;$events=Get-NonpassCustodyEvents $workspace;$rows+=@(Read-NonpassCustodyDefect $workspace $candidate @($events.events) -Observe).rows}
    Assert-NonpassCustodyReceiptPayloads $workspace $ReceiptPath @($rows) $ReturnEventId
}
function Assert-MorphospaceHistoricalNonpassArtifacts {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ReceiptPath,[Parameter(Mandatory)][string]$ReturnEventId)
    Assert-NonpassCustodyReceiptArtifacts $WorkspaceRoot $ReceiptPath '' $ReturnEventId
}
function Assert-MorphospaceNonpassCustodyRequest {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath)
    $candidate=Read-MorphospaceProtocolJson $RequestPath;$snapshot=Get-NonpassCustodyEvents $WorkspaceRoot
    $defect=Read-NonpassCustodyDefect $WorkspaceRoot $candidate @($snapshot.events) -Observe
    $receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $WorkspaceRoot ([string]$candidate.nonpass_custody_defect.original_receipt.path) -RequireLeaf)
    # A structural request diagnostic never grants a historical disposition.
    # It proves the finite declared tuple set and checks every other payload.
    foreach($artifact in @($receipt.artifacts)){
        $declared=@($defect.rows|Where-Object{[string]$_.artifact_id-ceq[string]$artifact.artifact_id-and[string]$_.path-ceq[string]$artifact.path-and[string]$_.expected_sha256-ceq[string]$artifact.sha256})
        if($declared.Count-eq1){continue}
        $path=Get-NonpassCustodyArtifactPath $WorkspaceRoot ([string]$candidate.nonpass_custody_defect.original_receipt.path) ([string]$artifact.path)
        if((Get-MorphospaceFileSha256 $path)-cne[string]$artifact.sha256){throw 'Nonpass custody request has undeclared unavailable evidence.'}
    }
}
Export-ModuleMember -Function Assert-MorphospaceHistoricalNonpassArtifacts,Assert-MorphospaceNonpassCustodyRequest
