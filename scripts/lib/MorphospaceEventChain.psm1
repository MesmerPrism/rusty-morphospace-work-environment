Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Microsoft.PowerShell.Core\Import-Module ([IO.Path]::Combine($PSScriptRoot,'MorphospaceProtocolCommon.psm1'))

function Split-MorphospaceLfRecords {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    $records=[Collections.Generic.List[byte[]]]::new()
    $start=0
    for($i=0;$i -lt $Bytes.Length;$i++){
        if($Bytes[$i] -ne 10){continue}
        $length=$i-$start
        $record=[byte[]]::new($length)
        if($length -gt 0){[Array]::Copy($Bytes,$start,$record,0,$length)}
        [void]$records.Add($record);$start=$i+1
    }
    if($start -ne $Bytes.Length){throw 'Iteration event log must end with LF; partial records are not accepted.'}
    return @($records.ToArray())
}

function Get-MorphospaceLegacyEventPrefixObservation {
    param(
        [Parameter(Mandatory=$true)][string]$EventsPath,
        [string]$ExpectedProjectId='',
        [AllowEmptyCollection()][byte[]]$EventBytes=$null
    )
    $path=[IO.Path]::GetFullPath($EventsPath)
    if(-not[IO.File]::Exists($path)){throw "Iteration event log is missing: $path"}
    if($null -eq $EventBytes){
        $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{if($stream.Length-gt67108864){throw 'Legacy event prefix exceeds the 64 MiB protocol bound.'};$bytes=[byte[]]::new([int]$stream.Length);$read=0;while($read-lt$bytes.Length){$n=$stream.Read($bytes,$read,$bytes.Length-$read);if($n-le0){throw 'Short legacy event-prefix read.'};$read+=$n}}finally{$stream.Dispose()}
    }else{$bytes=$EventBytes}
    if($bytes.Length-gt67108864){throw 'Legacy event prefix exceeds the 64 MiB protocol bound.'}
    $records=@(Split-MorphospaceLfRecords $bytes)
    $events=[Collections.Generic.List[object]]::new()
    $previousSequence=0;$maxTime=$null;$maxEvent=$null;$anomalies=[Collections.Generic.List[object]]::new()
    $eventIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($record in $records){
        if($record.Length -eq 0){throw 'Blank event records are not accepted in an anchored prefix.'}
        $event=ConvertFrom-MorphospaceProtocolJsonBytes $record 'legacy event record'
        if([string]$event.schema -cne 'rusty.morphospace.workflow.iteration_event.v1'){throw 'Legacy prefix may contain only iteration_event.v1 records.'}
        if([int]$event.sequence -ne $previousSequence+1){throw 'Legacy event sequence must be exactly contiguous from 1..N.'}
        if(-not $eventIds.Add([string]$event.event_id)){throw "Legacy event ID is duplicated: $([string]$event.event_id)"}
        if($ExpectedProjectId -and [string]$event.project_id -cne $ExpectedProjectId){throw "Legacy event '$([string]$event.event_id)' has the wrong project identity."}
        $parsed=ConvertFrom-MorphospaceInvariantTimestamp ([string]$event.timestamp)
        if($null -ne $maxTime -and $parsed -lt $maxTime){
            $anomalies.Add([pscustomobject][ordered]@{
                high_water_event_id=[string]$maxEvent.event_id;high_water_timestamp=[string]$maxEvent.timestamp
                below_high_water_event_id=[string]$event.event_id;below_high_water_timestamp=[string]$event.timestamp
            })
        }
        if($null -eq $maxTime -or $parsed -gt $maxTime){$maxTime=$parsed;$maxEvent=$event}
        $previousSequence=[int]$event.sequence;[void]$events.Add($event)
    }
    return [pscustomobject][ordered]@{
        byte_length=[long]$bytes.Length;line_count=$records.Count;prefix_sha256=(Get-MorphospaceSha256Bytes $bytes)
        last_event_id=if($events.Count){[string]$events[$events.Count-1].event_id}else{$null}
        last_sequence=$previousSequence
        max_timestamp_utc=if($null -eq $maxTime){$null}else{ConvertTo-MorphospaceUtcTimestamp $maxTime}
        anomalies=@($anomalies.ToArray())
    }
}

function Test-MorphospaceTypedReference {
    param([string]$WorkspaceRoot,[object]$Reference,[string]$Context)
    return Read-MorphospaceTypedFileSnapshot -WorkspaceRoot $WorkspaceRoot -Reference $Reference -Context $Context
}

function Test-MorphospaceTimestampAnomalyProjection {
    param([string]$WorkspaceRoot,[object]$Reference,[object]$Observation,[string]$ProjectId,[string]$UnitId)
    if([string]$Reference.role-cne'timestamp-anomaly-projection' -or [string]$Reference.schema-cne'rusty.morphospace.workflow.timestamp_anomaly_projection.v1'){throw 'Timestamp anomaly projection reference role/schema is wrong.'}
    $snapshot=Test-MorphospaceTypedReference $WorkspaceRoot $Reference 'timestamp anomaly projection';$projection=$snapshot.document
    Assert-MorphospaceExactPropertySet $projection @('schema','projection_id','project_id','unit_id','created_at','legacy_prefix_sha256','anomalies','safe_to_anchor') @() 'timestamp anomaly projection'
    if([string]$projection.schema-cne'rusty.morphospace.workflow.timestamp_anomaly_projection.v1' -or [string]$projection.project_id-cne$ProjectId -or [string]$projection.unit_id-cne$UnitId -or $projection.safe_to_anchor-ne$true -or [string]$projection.legacy_prefix_sha256-cne[string]$Observation.prefix_sha256){throw 'Timestamp anomaly projection identity, status, or prefix binding is wrong.'}
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$projection.created_at))
    foreach($anomaly in @($projection.anomalies)){Assert-MorphospaceExactPropertySet $anomaly @('high_water_event_id','high_water_timestamp','below_high_water_event_id','below_high_water_timestamp') @() 'timestamp anomaly item';[void](ConvertFrom-MorphospaceInvariantTimestamp ([string]$anomaly.high_water_timestamp));[void](ConvertFrom-MorphospaceInvariantTimestamp ([string]$anomaly.below_high_water_timestamp))}
    $expected=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{items=@($Observation.anomalies)});$actual=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{items=@($projection.anomalies)})
    if($expected-cne$actual){throw 'Timestamp anomaly projection does not cover the exact detected anomaly set.'}
    return $snapshot
}

function New-MorphospaceLegacyPrefixAnchor {
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][string]$RunId,
        [Parameter(Mandatory=$true)][string]$Timestamp,
        [object]$TimestampAnomalyProjection=$null,
        [object]$SubstitutionEnvelope=$null,
        [string]$ExpectedSubstitutionEnvelopeId='',
        [string]$ExpectedSubstitutionTriggerEventId='',
        [switch]$Execute
    )
    [void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    $eventsPath=Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'iteration-events.jsonl' -RequireLeaf
    $anchorLock=$null;$eventStream=$null;$eventBytes=$null
    try{
    if($Execute){$anchorLock=Enter-MorphospaceWorkspaceMutex $WorkspaceRoot;$eventStream=[IO.FileStream]::new($eventsPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);if($eventStream.Length-gt67108864){throw 'Anchored prefix exceeds the 64 MiB protocol bound.'};$eventBytes=[byte[]]::new([int]$eventStream.Length);$read=0;while($read-lt$eventBytes.Length){$n=$eventStream.Read($eventBytes,$read,$eventBytes.Length-$read);if($n-le0){throw 'Short anchored prefix read.'};$read+=$n}}
    $observation=Get-MorphospaceLegacyEventPrefixObservation -EventsPath $eventsPath -ExpectedProjectId $ProjectId -EventBytes $eventBytes
    if([int]$observation.line_count-lt1){throw 'A legacy prefix anchor requires at least one immutable event.'}
    if($observation.anomalies.Count -gt 0 -and $null -eq $TimestampAnomalyProjection){throw 'Non-monotonic legacy timestamps require a typed anomaly projection.'}
    if($observation.anomalies.Count -eq 0 -and $null -ne $TimestampAnomalyProjection){throw 'A monotonic legacy prefix must not carry an anomaly projection.'}
    if($null -ne $TimestampAnomalyProjection){
        [void](Test-MorphospaceTimestampAnomalyProjection $WorkspaceRoot $TimestampAnomalyProjection $observation $ProjectId $UnitId)
    }
    if($null -ne $SubstitutionEnvelope){
        if(-not $ExpectedSubstitutionEnvelopeId -or -not $ExpectedSubstitutionTriggerEventId){throw 'Substitution anchoring requires exact expected envelope and trigger-event identities.'}
        $envelopeSnapshot=Test-MorphospaceTypedReference $WorkspaceRoot $SubstitutionEnvelope 'substitution envelope'
        $envelope=$envelopeSnapshot.document
        if([string]$envelope.schema -cne 'rusty.morphospace.workflow.claim_substitution_receipt.v1' -or
           [string]$envelope.receipt_id -cne $ExpectedSubstitutionEnvelopeId -or
           [string]$envelope.trigger_event_id -cne $ExpectedSubstitutionTriggerEventId -or
           [string]$envelope.project_id -cne $ProjectId -or [string]$envelope.unit_id -cne $UnitId -or
           [string]$envelope.status -cne 'provisional-non-promotional' -or
           $envelope.external_mutation_performed -ne $false -or $envelope.device_work -ne $false){throw 'Claim substitution envelope identity/status/boundary fields are damaged.'}
        if([string]$envelope.canonical_original.sha256 -notmatch '^[0-9a-f]{64}$' -or
           [string]$envelope.substitution.restored_result_sha256 -cne [string]$envelope.canonical_original.sha256 -or
           $envelope.substitution.event_73_restored -ne $true -or $envelope.substitution.event_75_records_mutation -ne $true){throw 'Claim substitution envelope does not preserve the canonical restoration chain.'}
        foreach($raw in @($envelope.raw_recovery_copies)){
            $rawPath=Resolve-MorphospaceWorkspacePath $WorkspaceRoot ([string]$raw.path) -RequireLeaf
            if([string]$raw.sha256 -notmatch '^[0-9a-f]{64}$' -or (Get-MorphospaceFileSha256 $rawPath)-cne[string]$raw.sha256){throw 'Raw-only substitution preservation artifact changed.'}
        }
        $canonicalPath=Resolve-MorphospaceWorkspacePath $WorkspaceRoot ([string]$envelope.canonical_original.path) -RequireLeaf
        if((Get-MorphospaceFileSha256 $canonicalPath)-cne[string]$envelope.canonical_original.sha256){throw 'Canonical claim correction changed after substitution recovery.'}
    }
    $anchor=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.legacy_event_prefix_anchor.v1';anchor_id="$UnitId-legacy-prefix";created_at=$Timestamp
        project_id=$ProjectId;unit_id=$UnitId;run_id=$RunId;event_log_path='iteration-events.jsonl'
        byte_length=[long]$observation.byte_length;line_count=[int]$observation.line_count;prefix_sha256=[string]$observation.prefix_sha256
        last_event_id=$observation.last_event_id;last_sequence=[int]$observation.last_sequence;max_timestamp_utc=$observation.max_timestamp_utc
        timestamp_order=if($observation.anomalies.Count){'projected-legacy-anomalies'}else{'monotonic'}
        timestamp_anomaly_projection=$TimestampAnomalyProjection;substitution_envelope=$SubstitutionEnvelope
    }
    $managed=Get-MorphospaceManagedControlPath $WorkspaceRoot $UnitId 'legacy-prefix-anchor'
    if($Execute){Write-MorphospaceManagedProtocolJsonAtomic $WorkspaceRoot $managed.relative_path $anchor -NoOverwrite}
    $hash=if($Execute){Get-MorphospaceFileSha256 $managed.absolute_path}else{$null}
    return [pscustomobject][ordered]@{document=$anchor;reference=[pscustomobject][ordered]@{role='legacy-prefix-anchor';path=$managed.relative_path;schema='rusty.morphospace.workflow.legacy_event_prefix_anchor.v1';sha256=$hash}}
    }finally{if($null-ne$eventStream){$eventStream.Dispose()};if($null-ne$anchorLock){Exit-MorphospaceWorkspaceMutex $anchorLock}}
}

function Get-MorphospaceEventLineSha256 {
    param([Parameter(Mandatory=$true)][byte[]]$LineBytes)
    return Get-MorphospaceSha256Bytes $LineBytes
}

function Test-MorphospaceEventV2Document {
    param([object]$Event)
    Assert-MorphospaceExactPropertySet $Event @('schema','event_id','sequence','timestamp','run_id','session_id','project_id','unit_id','event_type','summary','previous_event_sha256','receipts') @() 'iteration_event.v2'
    if([string]$Event.schema -cne 'rusty.morphospace.workflow.iteration_event.v2'){throw 'Wrong v2 event schema.'}
    foreach($identity in @([string]$Event.event_id,[string]$Event.project_id,[string]$Event.unit_id,[string]$Event.run_id)){if($identity -notmatch '^[a-z0-9][a-z0-9-]{1,95}$'){throw "V2 event identity is invalid: $identity"}}
    if($null-ne$Event.session_id -and [string]$Event.session_id -notmatch '^[a-z0-9][a-z0-9-]{7,95}$'){throw 'V2 event session ID is invalid.'}
    if(([string]$Event.summary).Length -gt 4096 -or @($Event.receipts).Count -gt 64){throw 'V2 event exceeds summary/receipt bounds.'}
    if([string]::IsNullOrWhiteSpace([string]$Event.summary)){throw 'V2 event summary must be non-empty.'}
    if(@('state-transition','decision','extraction','validation','commit','push','promotion','blocker') -cnotcontains [string]$Event.event_type){throw 'V2 event type is not in the portable schema vocabulary.'}
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$Event.timestamp))
    if([string]$Event.previous_event_sha256 -notmatch '^[0-9a-f]{64}$'){throw 'V2 event has invalid previous hash.'}
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($reference in @($Event.receipts)){
        Assert-MorphospaceExactPropertySet $reference @('role','path','schema','sha256') @() 'v2 event receipt reference'
        if([string]$reference.role-notmatch'^[a-z0-9][a-z0-9-]{1,95}$' -or [string]$reference.schema-notmatch'^[a-z0-9][a-z0-9_.-]{2,191}$' -or [string]$reference.sha256-notmatch'^[0-9a-f]{64}$'){throw 'V2 event receipt role/schema/hash is invalid.'}
        $canonical=ConvertTo-MorphospaceProtocolRelativePath ([string]$reference.path)
        if(-not $paths.Add($canonical)){throw 'V2 event repeats a canonical receipt path.'}
    }
}

function Test-MorphospaceEventChainBytes {
    param([string]$WorkspaceRoot,[object]$AnchorReference,[byte[]]$Bytes,[object]$ExpectedTail=$null)
    if($Bytes.Length-gt67108864){throw 'Event log exceeds the 64 MiB protocol bound.'}
    if([string]$AnchorReference.role-cne'legacy-prefix-anchor' -or [string]$AnchorReference.schema-cne'rusty.morphospace.workflow.legacy_event_prefix_anchor.v1'){throw 'Legacy prefix anchor reference role/schema is wrong.'}
    $anchorSnapshot=Test-MorphospaceTypedReference -WorkspaceRoot $WorkspaceRoot -Reference $AnchorReference -Context 'legacy prefix anchor'
    $anchor=$anchorSnapshot.document
    Assert-MorphospaceExactPropertySet $anchor @('schema','anchor_id','created_at','project_id','unit_id','run_id','event_log_path','byte_length','line_count','prefix_sha256','last_event_id','last_sequence','max_timestamp_utc','timestamp_order','timestamp_anomaly_projection','substitution_envelope') @() 'legacy prefix anchor'
    if([string]$anchor.schema-cne'rusty.morphospace.workflow.legacy_event_prefix_anchor.v1' -or [string]$anchor.anchor_id-cne"$([string]$anchor.unit_id)-legacy-prefix" -or [string]$anchor.event_log_path-cne'iteration-events.jsonl'){throw 'Wrong legacy prefix anchor identity/schema/path.'}
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$anchor.created_at))
    if($null-ne$anchor.substitution_envelope){[void](Test-MorphospaceTypedReference $WorkspaceRoot $anchor.substitution_envelope 'anchored substitution envelope')}
    if($bytes.Length -lt [long]$anchor.byte_length){throw 'Event log is shorter than its anchored legacy prefix.'}
    $prefix=[byte[]]::new([int]$anchor.byte_length);if($prefix.Length){[Array]::Copy($bytes,0,$prefix,0,$prefix.Length)}
    if((Get-MorphospaceSha256Bytes $prefix) -cne [string]$anchor.prefix_sha256){throw 'Anchored legacy event prefix changed.'}
    $legacyObservation=Get-MorphospaceLegacyEventPrefixObservation -EventsPath (Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'iteration-events.jsonl' -RequireLeaf) -ExpectedProjectId ([string]$anchor.project_id) -EventBytes $prefix
    if([long]$anchor.byte_length-ne[long]$legacyObservation.byte_length -or [int]$anchor.line_count-ne[int]$legacyObservation.line_count -or [string]$anchor.prefix_sha256-cne[string]$legacyObservation.prefix_sha256 -or [string]$anchor.last_event_id-cne[string]$legacyObservation.last_event_id -or [int]$anchor.last_sequence-ne[int]$legacyObservation.last_sequence -or [string]$anchor.max_timestamp_utc-cne[string]$legacyObservation.max_timestamp_utc){throw 'Legacy anchor metadata does not derive from the exact frozen prefix.'}
    if($legacyObservation.anomalies.Count-gt0){if([string]$anchor.timestamp_order-cne'projected-legacy-anomalies' -or $null-eq$anchor.timestamp_anomaly_projection){throw 'Legacy anchor is missing its required anomaly projection.'};[void](Test-MorphospaceTimestampAnomalyProjection $WorkspaceRoot $anchor.timestamp_anomaly_projection $legacyObservation ([string]$anchor.project_id) ([string]$anchor.unit_id))}elseif([string]$anchor.timestamp_order-cne'monotonic' -or $null-ne$anchor.timestamp_anomaly_projection){throw 'Monotonic legacy anchor has an unexpected anomaly projection.'}
    $legacyRecords=@(Split-MorphospaceLfRecords $prefix)
    $eventIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$v2Events=[Collections.Generic.List[object]]::new()
    foreach($legacyRecord in $legacyRecords){$legacyEvent=ConvertFrom-MorphospaceProtocolJsonBytes $legacyRecord 'anchored legacy event';if([string]$legacyEvent.project_id-cne[string]$anchor.project_id -or -not$eventIds.Add([string]$legacyEvent.event_id)){throw 'Anchored legacy project/event identity is damaged.'}}
    $suffixLength=$bytes.Length-$prefix.Length;$suffix=[byte[]]::new($suffixLength);if($suffixLength){[Array]::Copy($bytes,$prefix.Length,$suffix,0,$suffixLength)}
    $records=@(Split-MorphospaceLfRecords $suffix);$previous=[string]$anchor.prefix_sha256;$sequence=[int]$anchor.last_sequence;$lastTime=if($anchor.max_timestamp_utc){Test-MorphospaceStrictUtcTimestamp ([string]$anchor.max_timestamp_utc)}else{$null};$tail=$null
    foreach($record in $records){
        $event=ConvertFrom-MorphospaceProtocolJsonBytes $record 'v2 event record';Test-MorphospaceEventV2Document $event
        if([string]$event.project_id-cne[string]$anchor.project_id -or -not$eventIds.Add([string]$event.event_id)){throw 'V2 event project identity is wrong or event ID is reused.'}
        if([int]$event.sequence -ne $sequence+1){throw 'V2 event sequence is not exact/contiguous.'}
        if([string]$event.previous_event_sha256 -cne $previous){throw 'V2 previous-event hash chain is broken.'}
        $time=Test-MorphospaceStrictUtcTimestamp ([string]$event.timestamp);if($null-ne$lastTime -and $time -le $lastTime){throw 'V2 event time is not strictly monotonic UTC.'}
        foreach($reference in @($event.receipts)){[void](Test-MorphospaceTypedReference $WorkspaceRoot $reference "event '$([string]$event.event_id)' receipt")}
        [void]$v2Events.Add($event);$previous=Get-MorphospaceEventLineSha256 $record;$sequence=[int]$event.sequence;$lastTime=$time;$tail=[pscustomobject][ordered]@{event_id=[string]$event.event_id;sequence=$sequence;sha256=$previous;timestamp=[string]$event.timestamp}
    }
    if($null-ne$ExpectedTail){if($null-eq$tail -or [string]$ExpectedTail.event_id-cne$tail.event_id -or [string]$ExpectedTail.sha256-cne$tail.sha256 -or [int]$ExpectedTail.sequence-ne$tail.sequence){throw 'Protocol state tail does not match the validated event chain.'}}
    return [pscustomobject][ordered]@{anchor=$anchor;tail=$tail;event_count=$records.Count;event_log_sha256=(Get-MorphospaceSha256Bytes $bytes);event_ids=@($eventIds);events=@($v2Events.ToArray())}
}

function Test-MorphospaceCandidateEvent {
    param([string]$WorkspaceRoot,[object]$Event,[object]$Chain)
    Test-MorphospaceEventV2Document $Event
    if([string]$Event.project_id-cne[string]$Chain.anchor.project_id){throw 'Candidate event project does not match the anchored project authority.'}
    if(@($Chain.event_ids)-ccontains[string]$Event.event_id){throw 'Candidate event reuses an existing event ID.'}
    $expectedSequence=if($null-ne$Chain.tail){[int]$Chain.tail.sequence+1}else{[int]$Chain.anchor.last_sequence+1};$expectedPrevious=if($null-ne$Chain.tail){[string]$Chain.tail.sha256}else{[string]$Chain.anchor.prefix_sha256}
    if([int]$Event.sequence-ne$expectedSequence-or[string]$Event.previous_event_sha256-cne$expectedPrevious){throw 'Candidate event does not extend the exact anchored tail.'}
    $priorTime=if($null-ne$Chain.tail){Test-MorphospaceStrictUtcTimestamp ([string]$Chain.tail.timestamp)}else{Test-MorphospaceStrictUtcTimestamp ([string]$Chain.anchor.max_timestamp_utc)};$candidateTime=Test-MorphospaceStrictUtcTimestamp ([string]$Event.timestamp)
    if($candidateTime-le$priorTime){throw 'Candidate event timestamp is not strictly above the anchored high-water time.'}
    foreach($reference in @($Event.receipts)){[void](Test-MorphospaceTypedReference $WorkspaceRoot $reference 'candidate v2 event receipt')}
}

function Test-MorphospaceEventChain {
    param([string]$WorkspaceRoot,[object]$AnchorReference,[object]$ExpectedTail=$null)
    $lock=Enter-MorphospaceWorkspaceMutex $WorkspaceRoot;$stream=$null
    try{$path=Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'iteration-events.jsonl' -RequireLeaf;$stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);if($stream.Length-gt67108864){throw 'Event log exceeds the 64 MiB protocol bound.'};$bytes=[byte[]]::new([int]$stream.Length);$read=0;while($read-lt$bytes.Length){$n=$stream.Read($bytes,$read,$bytes.Length-$read);if($n-le0){throw 'Short public event-chain read.'};$read+=$n};$chain=Test-MorphospaceEventChainBytes -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -Bytes $bytes -ExpectedTail $ExpectedTail;Test-MorphospaceEventTransactionLedger -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -EventBytes $bytes;return $chain}
    finally{if($null-ne$stream){$stream.Dispose()};Exit-MorphospaceWorkspaceMutex $lock}
}

function Get-MorphospaceEventTransactionPaths {
    param([string]$WorkspaceRoot,[string]$UnitId,[string]$RunId,[int]$Sequence)
    if($RunId -notmatch "^$([regex]::Escape($UnitId))-[a-f0-9]{32}$"){throw 'Event run ID is not an automation-derived unit UUID.'}
    $base="receipts/event-transactions/$UnitId-$('{0:d6}'-f$Sequence)-$RunId"
    return [pscustomobject]@{intent="$base.intent.json";completion="$base.completion.json";intent_absolute=(Resolve-MorphospaceWorkspacePath $WorkspaceRoot "$base.intent.json");completion_absolute=(Resolve-MorphospaceWorkspacePath $WorkspaceRoot "$base.completion.json")}
}

function New-MorphospaceEventCompletion {
    param([string]$WorkspaceRoot,[object]$Intent,[object]$IntentReference,[string]$CompletionPath,[byte[]]$AfterBytes)
    $tail=[pscustomobject][ordered]@{event_id=[string]$Intent.event.event_id;sequence=[int]$Intent.event.sequence;sha256=[string]$Intent.event_line_sha256}
    $completion=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.event_transaction_completion.v1';transaction_id=[string]$Intent.transaction_id;completed_at=[string]$Intent.timestamp;project_id=[string]$Intent.project_id;unit_id=[string]$Intent.unit_id;run_id=[string]$Intent.run_id;intent=$IntentReference;tail=$tail;event_log_sha256=(Get-MorphospaceSha256Bytes $AfterBytes);event_log_length=[long]$AfterBytes.Length;status='committed'}
    Write-MorphospaceManagedProtocolJsonAtomic $WorkspaceRoot $CompletionPath $completion -NoOverwrite
    return $completion
}

function Test-MorphospaceEventIntentDocument {
    param([string]$WorkspaceRoot,[object]$Intent,[object]$IntentReference,[object]$ExpectedAnchorReference)
    Assert-MorphospaceExactPropertySet $Intent @('schema','transaction_id','created_at','timestamp','project_id','unit_id','run_id','session_id','anchor','pre_event_log_sha256','pre_event_log_length','event_line_sha256','event','status') @() 'event transaction intent'
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.event_transaction_intent.v1' -or [string]$Intent.status-cne'prepared'){throw 'Wrong event transaction intent schema/status.'}
    if([string]$IntentReference.role-cne'event-transaction-intent' -or [string]$IntentReference.schema-cne'rusty.morphospace.workflow.event_transaction_intent.v1'){throw 'Event transaction intent reference has the wrong role/schema.'}
    Assert-MorphospaceExactPropertySet $Intent.anchor @('role','path','schema','sha256') @() 'event transaction anchor reference'
    if([string]$Intent.anchor.role-cne'legacy-prefix-anchor' -or [string]$Intent.anchor.schema-cne'rusty.morphospace.workflow.legacy_event_prefix_anchor.v1' -or (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$Intent.anchor}))-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$ExpectedAnchorReference}))){throw 'Event transaction intent does not bind the exact authorized anchor.'}
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$Intent.created_at))
    if([string]$Intent.created_at-cne[string]$Intent.timestamp){throw 'Event intent timestamps disagree.'}
    Test-MorphospaceEventV2Document $Intent.event
    foreach($field in @('project_id','unit_id','run_id')){if([string]$Intent.$field-cne[string]$Intent.event.$field){throw "Event intent '$field' does not bind its event."}}
    if([string]$Intent.session_id-cne[string]$Intent.event.session_id){throw 'Event intent session does not bind its event.'}
    $paths=Get-MorphospaceEventTransactionPaths $WorkspaceRoot ([string]$Intent.unit_id) ([string]$Intent.run_id) ([int]$Intent.event.sequence)
    if([string]$paths.intent-cne(ConvertTo-MorphospaceProtocolRelativePath ([string]$IntentReference.path))){throw 'Event transaction intent is not at its canonical path.'}
    $expectedTransactionId="$([string]$Intent.run_id)-$('{0:d6}'-f[int]$Intent.event.sequence)"
    if([string]$Intent.transaction_id-cne$expectedTransactionId -or [string]$Intent.pre_event_log_sha256-notmatch'^[0-9a-f]{64}$' -or [string]$Intent.event_line_sha256-notmatch'^[0-9a-f]{64}$' -or [long]$Intent.pre_event_log_length-lt1){throw 'Event intent identity, pre-state, or hash is damaged.'}
    $line=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Intent.event))
    if((Get-MorphospaceSha256Bytes $line)-cne[string]$Intent.event_line_sha256){throw 'Event transaction intent line hash is damaged.'}
    return [pscustomobject]@{paths=$paths;line=$line}
}

function Read-MorphospaceEventCompletionSnapshot {
    param([string]$Path,[string]$Context)
    $stream=[IO.FileStream]::new([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($stream.Length-gt16777216){throw "$Context exceeds 16 MiB."}
        $bytes=[byte[]]::new([int]$stream.Length);$read=0
        while($read-lt$bytes.Length){$n=$stream.Read($bytes,$read,$bytes.Length-$read);if($n-le0){throw "$Context short read."};$read+=$n}
        $document=ConvertFrom-MorphospaceProtocolJsonBytes $bytes $Context
        $result=[pscustomobject]@{document=$document;bytes=$bytes;stream=$stream};$stream=$null;return $result
    }finally{if($null-ne$stream){$stream.Dispose()}}
}

function Test-MorphospaceEventCompletion {
    param([string]$WorkspaceRoot,[object]$Completion,[object]$Intent,[object]$IntentReference,[object]$AnchorReference,[byte[]]$EventBytes)
    $intentValidation=Test-MorphospaceEventIntentDocument $WorkspaceRoot $Intent $IntentReference $AnchorReference
    Assert-MorphospaceExactPropertySet $Completion @('schema','transaction_id','completed_at','project_id','unit_id','run_id','intent','tail','event_log_sha256','event_log_length','status') @() 'event transaction completion'
    Assert-MorphospaceExactPropertySet $Completion.tail @('event_id','sequence','sha256') @() 'event transaction completion tail'
    if([string]$Completion.schema-cne'rusty.morphospace.workflow.event_transaction_completion.v1' -or [string]$Completion.status-cne'committed' -or [string]$Completion.transaction_id-cne[string]$Intent.transaction_id -or [string]$Completion.project_id-cne[string]$Intent.project_id -or [string]$Completion.unit_id-cne[string]$Intent.unit_id -or [string]$Completion.run_id-cne[string]$Intent.run_id){throw 'Event completion identity/status is damaged.'}
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$Completion.completed_at))
    if([string]$Completion.completed_at-cne[string]$Intent.timestamp){throw 'Event completion time does not bind the intent time.'}
    if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$Completion.intent}))-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$IntentReference}))){throw 'Event completion intent binding is damaged.'}
    [void](Test-MorphospaceTypedReference $WorkspaceRoot $Completion.intent 'completed event intent')
    $length=[long]$Completion.event_log_length;if($length-lt1-or$EventBytes.Length-lt$length){throw 'Event completion prefix length is invalid.'};$prefix=[byte[]]::new([int]$length);[Array]::Copy($EventBytes,0,$prefix,0,$prefix.Length)
    if([string]$Completion.event_log_sha256-cne(Get-MorphospaceSha256Bytes $prefix)){throw 'Event completion does not bind its exact committed log prefix.'}
    $preLength=[long]$Intent.pre_event_log_length
    if($preLength-gt$prefix.Length){throw 'Event completion is shorter than the intended exact pre-state.'}
    $pre=[byte[]]::new([int]$preLength);if($pre.Length){[Array]::Copy($prefix,0,$pre,0,$pre.Length)}
    if((Get-MorphospaceSha256Bytes $pre)-cne[string]$Intent.pre_event_log_sha256){throw 'Event completion does not preserve the intended exact pre-state.'}
    $preChain=Test-MorphospaceEventChainBytes -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -Bytes $pre
    Test-MorphospaceCandidateEvent $WorkspaceRoot $Intent.event $preChain
    $line=[byte[]]$intentValidation.line;$expectedLength=$pre.Length+$line.Length+1
    if($prefix.Length-ne$expectedLength){throw 'Event completion length is not the exact intended append length.'}
    for($i=0;$i-lt$line.Length;$i++){if($prefix[$pre.Length+$i]-ne$line[$i]){throw 'Event completion bytes differ from the intended event.'}}
    if($prefix[-1]-ne10){throw 'Event completion is missing its canonical LF terminator.'}
    if([string]$Completion.tail.event_id-cne[string]$Intent.event.event_id -or [int]$Completion.tail.sequence-ne[int]$Intent.event.sequence -or [string]$Completion.tail.sha256-cne[string]$Intent.event_line_sha256){throw 'Event completion tail does not bind the intended event.'}
    [void](Test-MorphospaceEventChainBytes -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -Bytes $prefix -ExpectedTail $Completion.tail)
    return $true
}

function Test-MorphospaceEventTransactionLedger {
    param([string]$WorkspaceRoot,[object]$AnchorReference,[byte[]]$EventBytes,[string]$AllowedUnresolvedIntentPath='')
    $ledgerLeases=[Collections.Generic.List[object]]::new()
    try{
    $chain=Test-MorphospaceEventChainBytes -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -Bytes $EventBytes
    $directory=Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'receipts/event-transactions';$expectedIntents=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$expectedCompletions=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$orderedPairs=[Collections.Generic.List[object]]::new()
    foreach($event in @($chain.events)){$paths=Get-MorphospaceEventTransactionPaths $WorkspaceRoot ([string]$event.unit_id) ([string]$event.run_id) ([int]$event.sequence);if(-not$expectedIntents.Add([IO.Path]::GetFullPath($paths.intent_absolute))-or-not$expectedCompletions.Add([IO.Path]::GetFullPath($paths.completion_absolute))){throw 'Two v2 events derive the same canonical event transaction path.'};$orderedPairs.Add($paths)}
    $allowed=$null;if($AllowedUnresolvedIntentPath){$allowed=[IO.Path]::GetFullPath($AllowedUnresolvedIntentPath);$directoryPrefix=[IO.Path]::GetFullPath($directory).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;if(-not$allowed.StartsWith($directoryPrefix,[StringComparison]::OrdinalIgnoreCase)-or-not$allowed.EndsWith('.intent.json',[StringComparison]::Ordinal)){throw 'Allowed unresolved event intent path is non-canonical.'};[void]$expectedIntents.Add($allowed)}
    if(-not[IO.Directory]::Exists($directory)){if($expectedIntents.Count-or$expectedCompletions.Count){throw 'V2 event transaction ledger directory is missing.'};return}
    $actualIntents=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$actualCompletions=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$initialNames=[Collections.Generic.List[string]]::new()
    foreach($path in @([IO.Directory]::GetFileSystemEntries($directory))){$attributes=[IO.File]::GetAttributes($path);if(($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or($attributes-band[IO.FileAttributes]::Directory)-ne0){throw "Unexpected/reparse event transaction ledger entry: $path"};$full=[IO.Path]::GetFullPath($path);$initialNames.Add($full);if($full.EndsWith('.intent.json',[StringComparison]::Ordinal)){if(-not$actualIntents.Add($full)){throw 'Duplicate event intent path.'}}elseif($full.EndsWith('.completion.json',[StringComparison]::Ordinal)){if(-not$actualCompletions.Add($full)){throw 'Duplicate event completion path.'}}else{throw "Unknown event transaction ledger artifact: $full"}}
    foreach($pair in $orderedPairs){
        $intentPath=[IO.Path]::GetFullPath($pair.intent_absolute);$completionPath=[IO.Path]::GetFullPath($pair.completion_absolute)
        if(-not$actualIntents.Contains($intentPath)){throw "V2 event is missing its exact intent: $intentPath"}
        if(-not$actualCompletions.Contains($completionPath)){if($null-ne$allowed-and$intentPath.Equals($allowed,[StringComparison]::OrdinalIgnoreCase)){continue};throw "V2 event is missing its exact completion: $completionPath"}
        $completionSnapshot=Read-MorphospaceEventCompletionSnapshot $completionPath 'event transaction ledger completion';$intentSnapshot=$null
        try{$completion=$completionSnapshot.document;Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','project_id','unit_id','run_id','intent','tail','event_log_sha256','event_log_length','status') @() 'event transaction ledger completion';$intentReference=$completion.intent;$intentSnapshot=Read-MorphospaceTypedFileSnapshot $WorkspaceRoot $intentReference 'event transaction ledger intent' -KeepLease;$intent=$intentSnapshot.document;$validated=(Test-MorphospaceEventIntentDocument $WorkspaceRoot $intent $intentReference $AnchorReference).paths;if([IO.Path]::GetFullPath($validated.intent_absolute)-cne$intentPath-or[IO.Path]::GetFullPath($validated.completion_absolute)-cne$completionPath){throw 'Event transaction ledger path is non-canonical.'};[void](Test-MorphospaceEventCompletion $WorkspaceRoot $completion $intent $intentReference $AnchorReference $EventBytes);$ledgerLeases.Add([pscustomobject]@{stream=$completionSnapshot.stream;bytes=$completionSnapshot.bytes;context=$completionPath});$completionSnapshot=$null;$ledgerLeases.Add([pscustomobject]@{stream=$intentSnapshot.stream;bytes=$intentSnapshot.bytes;context=$intentPath});$intentSnapshot=$null}finally{if($null-ne$intentSnapshot-and$null-ne$intentSnapshot.stream){$intentSnapshot.stream.Dispose()};if($null-ne$completionSnapshot){$completionSnapshot.stream.Dispose()}}
    }
    foreach($path in $actualIntents){if(-not$expectedIntents.Contains($path)){throw "Orphan event intent blocks the ledger: $path"}}
    foreach($path in $actualCompletions){if(-not$expectedCompletions.Contains($path)){throw "Orphan event completion blocks the ledger: $path"}}
    if($null-ne$allowed-and-not$actualIntents.Contains($allowed)){throw 'Authorized unresolved event intent is missing from the ledger.'}
    $finalNames=@([IO.Directory]::GetFileSystemEntries($directory));if($finalNames.Count-ne$initialNames.Count){throw 'Event transaction ledger changed during validation.'};$finalSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($path in $finalNames){[void]$finalSet.Add([IO.Path]::GetFullPath($path))};foreach($path in $initialNames){if(-not$finalSet.Contains($path)){throw 'Event transaction ledger changed during validation.'}}
    foreach($lease in $ledgerLeases){if([long]$lease.stream.Length-ne[long]$lease.bytes.Length-or(Get-MorphospaceStreamSha256 $lease.stream)-cne(Get-MorphospaceSha256Bytes $lease.bytes)){throw "Event transaction artifact changed under lease: $([string]$lease.context)"}}
    }finally{foreach($lease in $ledgerLeases){$lease.stream.Dispose()}}
}

function Add-MorphospaceEventV2 {
    param(
        [string]$WorkspaceRoot,[object]$AnchorReference,[string]$ProjectId,[string]$UnitId,[string]$ActionSlug,[string]$EventType,[string]$Summary,[string]$RunId,[string]$SessionId,[string]$Timestamp,[object[]]$ReceiptReferences=@(),[object]$ExpectedTail=$null,[switch]$Execute
    )
    [void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    if(-not$Execute){
        $chain=Test-MorphospaceEventChain -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -ExpectedTail $ExpectedTail
        if($null-ne$chain.tail -and $null-eq$ExpectedTail){throw 'Planning a later v2 event requires the caller-bound exact tail.'}
        $previous=if($null-ne$chain.tail){[string]$chain.tail.sha256}else{[string]$chain.anchor.prefix_sha256};$sequence=if($null-ne$chain.tail){[int]$chain.tail.sequence+1}else{[int]$chain.anchor.last_sequence+1}
        $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v2';event_id="$UnitId-$ActionSlug-$('{0:d4}'-f$sequence)";sequence=$sequence;timestamp=$Timestamp;run_id=$RunId;session_id=if($SessionId){$SessionId}else{$null};project_id=$ProjectId;unit_id=$UnitId;event_type=$EventType;summary=$Summary;previous_event_sha256=$previous;receipts=@($ReceiptReferences)}
        Test-MorphospaceCandidateEvent $WorkspaceRoot $event $chain
        return [pscustomobject][ordered]@{document=$event;tail=$null;transaction=$null}
    }
    $lock=Enter-MorphospaceWorkspaceMutex $WorkspaceRoot;$leases=[Collections.Generic.List[object]]::new()
    try{
        [void]$leases.Add((Read-MorphospaceTypedFileSnapshot $WorkspaceRoot $AnchorReference 'leased legacy prefix anchor' -KeepLease))
        foreach($reference in @($ReceiptReferences)){[void]$leases.Add((Read-MorphospaceTypedFileSnapshot $WorkspaceRoot $reference 'leased event receipt' -KeepLease))}
        $eventsPath=Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'iteration-events.jsonl' -RequireLeaf;$stream=[IO.FileStream]::new($eventsPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
        try{
            if($stream.Length -gt 67108864){throw 'Event log exceeds the 64 MiB transaction bound.'}
            $before=[byte[]]::new([int]$stream.Length);$stream.Position=0;$read=0;while($read-lt$before.Length){$n=$stream.Read($before,$read,$before.Length-$read);if($n-le0){throw 'Short read under event lock.'};$read+=$n}
            $chain=Test-MorphospaceEventChainBytes -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -Bytes $before -ExpectedTail $ExpectedTail
            if($null-ne$chain.tail -and $null-eq$ExpectedTail){throw 'Appending after the first v2 event requires the caller-bound exact tail.'}
            $previous=if($null-ne$chain.tail){[string]$chain.tail.sha256}else{[string]$chain.anchor.prefix_sha256};$sequence=if($null-ne$chain.tail){[int]$chain.tail.sequence+1}else{[int]$chain.anchor.last_sequence+1}
            $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v2';event_id="$UnitId-$ActionSlug-$('{0:d4}'-f$sequence)";sequence=$sequence;timestamp=$Timestamp;run_id=$RunId;session_id=if($SessionId){$SessionId}else{$null};project_id=$ProjectId;unit_id=$UnitId;event_type=$EventType;summary=$Summary;previous_event_sha256=$previous;receipts=@($ReceiptReferences)}
            Test-MorphospaceCandidateEvent $WorkspaceRoot $event $chain
            $utf8=[Text.UTF8Encoding]::new($false);$line=$utf8.GetBytes((ConvertTo-MorphospaceCanonicalJson $event));$lineHash=Get-MorphospaceEventLineSha256 $line
            $paths=Get-MorphospaceEventTransactionPaths $WorkspaceRoot $UnitId $RunId $sequence
            Test-MorphospaceEventTransactionLedger $WorkspaceRoot $AnchorReference $before
            if([IO.File]::Exists($paths.intent_absolute)-or[IO.File]::Exists($paths.completion_absolute)){throw 'Canonical event transaction paths must be absent before append.'}
            $intent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.event_transaction_intent.v1';transaction_id="$RunId-$('{0:d6}'-f$sequence)";created_at=$Timestamp;timestamp=$Timestamp;project_id=$ProjectId;unit_id=$UnitId;run_id=$RunId;session_id=if($SessionId){$SessionId}else{$null};anchor=$AnchorReference;pre_event_log_sha256=(Get-MorphospaceSha256Bytes $before);pre_event_log_length=[long]$before.Length;event_line_sha256=$lineHash;event=$event;status='prepared'}
            Write-MorphospaceManagedProtocolJsonAtomic $WorkspaceRoot $paths.intent $intent -NoOverwrite
            $intentReference=[pscustomobject][ordered]@{role='event-transaction-intent';path=$paths.intent;schema='rusty.morphospace.workflow.event_transaction_intent.v1';sha256=(Get-MorphospaceFileSha256 $paths.intent_absolute)}
            [void]$leases.Add((Read-MorphospaceTypedFileSnapshot $WorkspaceRoot $intentReference 'leased newly written event intent' -KeepLease))
            if($stream.Length-ne$before.Length){throw 'Event log length changed while its exclusive transaction handle was held.'}
            $stream.Position=$stream.Length;$stream.Write($line,0,$line.Length);$stream.WriteByte(10);$stream.Flush($true)
            $stream.Position=0;$after=[byte[]]::new([int]$stream.Length);$read=0;while($read-lt$after.Length){$n=$stream.Read($after,$read,$after.Length-$read);if($n-le0){throw 'Short event readback under lock.'};$read+=$n}
            if($after.Length-ne$before.Length+$line.Length+1){throw 'Event transaction readback length mismatch.'}
            for($i=0;$i-lt$before.Length;$i++){if($after[$i]-ne$before[$i]){throw 'Event transaction changed the prior prefix.'}}
            $tail=[pscustomobject][ordered]@{event_id=[string]$event.event_id;sequence=$sequence;sha256=$lineHash;timestamp=$Timestamp}
            [void](Test-MorphospaceEventChainBytes -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -Bytes $after -ExpectedTail $tail)
            $completion=New-MorphospaceEventCompletion $WorkspaceRoot $intent $intentReference $paths.completion $after
            Test-MorphospaceEventTransactionLedger -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -EventBytes $after
        }finally{$stream.Dispose()}
    }finally{foreach($lease in $leases){if($null-ne$lease.stream){$lease.stream.Dispose()}};Exit-MorphospaceWorkspaceMutex $lock}
    return [pscustomobject][ordered]@{document=$event;tail=$tail;transaction=[pscustomobject][ordered]@{intent=$paths.intent;completion=$paths.completion;completion_sha256=(Get-MorphospaceFileSha256 $paths.completion_absolute)}}
}

function Repair-MorphospaceEventTransaction {
    param([string]$WorkspaceRoot,[object]$IntentReference,[object]$AnchorReference)
    $lock=Enter-MorphospaceWorkspaceMutex $WorkspaceRoot
    $leases=[Collections.Generic.List[object]]::new();$completionSnapshot=$null
    try{
        $intentSnapshot=Read-MorphospaceTypedFileSnapshot $WorkspaceRoot $IntentReference 'event transaction recovery intent' -KeepLease;[void]$leases.Add($intentSnapshot)
        $intentPath=$intentSnapshot.path;$intent=$intentSnapshot.document;$intentValidation=Test-MorphospaceEventIntentDocument $WorkspaceRoot $intent $IntentReference $AnchorReference;$paths=$intentValidation.paths
        $anchorLease=Read-MorphospaceTypedFileSnapshot $WorkspaceRoot $AnchorReference 'leased recovery anchor' -KeepLease;[void]$leases.Add($anchorLease)
        foreach($reference in @($intent.event.receipts)){[void]$leases.Add((Read-MorphospaceTypedFileSnapshot $WorkspaceRoot $reference 'leased recovered event receipt' -KeepLease))}
        $eventsPath=Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'iteration-events.jsonl' -RequireLeaf;$stream=[IO.FileStream]::new($eventsPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
        try{
            if($stream.Length-gt67108864){throw 'Event log exceeds the 64 MiB recovery bound.'}
            $current=[byte[]]::new([int]$stream.Length);$stream.Position=0;$read=0;while($read-lt$current.Length){$n=$stream.Read($current,$read,$current.Length-$read);if($n-le0){throw 'Short recovery read.'};$read+=$n}
            $completionExists=[IO.File]::Exists($paths.completion_absolute)
            $line=[byte[]]$intentValidation.line
            $preLength=[long]$intent.pre_event_log_length;if($preLength-lt1-or$preLength-gt$current.Length){throw 'Event transaction recovery log is shorter than its exact pre-state.'}
            $prefix=[byte[]]::new([int]$preLength);if($prefix.Length){[Array]::Copy($current,0,$prefix,0,$prefix.Length)}
            if((Get-MorphospaceSha256Bytes $prefix)-cne[string]$intent.pre_event_log_sha256){throw 'Event transaction recovery prefix changed; no truncation is permitted.'}
            if($completionExists){Test-MorphospaceEventTransactionLedger -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -EventBytes $current}else{Test-MorphospaceEventTransactionLedger -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -EventBytes $prefix -AllowedUnresolvedIntentPath $paths.intent_absolute}
            $preChain=Test-MorphospaceEventChainBytes -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -Bytes $prefix
            Test-MorphospaceCandidateEvent $WorkspaceRoot $intent.event $preChain
            $intended=[byte[]]::new($line.Length+1);[Array]::Copy($line,0,$intended,0,$line.Length);$intended[-1]=10
            $tailLength=$current.Length-$preLength;if($tailLength-gt$intended.Length){throw 'Unknown bytes follow the intended event; recovery refuses to append or truncate.'}
            for($i=0;$i-lt$tailLength;$i++){if($current[$preLength+$i]-ne$intended[$i]){throw 'Partial event bytes do not match the exact intended append.'}}
            if($completionExists){
                if($tailLength-ne$intended.Length){throw 'A completion artifact exists before the intended append is complete.'}
                $completionSnapshot=Read-MorphospaceEventCompletionSnapshot $paths.completion_absolute 'event transaction recovery completion';$completion=$completionSnapshot.document
                [void](Test-MorphospaceEventCompletion $WorkspaceRoot $completion $intent $IntentReference $AnchorReference $current)
                return $completion
            }
            if($tailLength-lt$intended.Length){$remaining=$intended.Length-$tailLength;$stream.Position=$stream.Length;$stream.Write($intended,$tailLength,$remaining);$stream.Flush($true);$stream.Position=0;$current=[byte[]]::new([int]$stream.Length);$read=0;while($read-lt$current.Length){$n=$stream.Read($current,$read,$current.Length-$read);if($n-le0){throw 'Short recovery readback.'};$read+=$n}}
            $tail=[pscustomobject]@{event_id=[string]$intent.event.event_id;sequence=[int]$intent.event.sequence;sha256=[string]$intent.event_line_sha256}
            [void](Test-MorphospaceEventChainBytes -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -Bytes $current -ExpectedTail $tail)
            $completion=New-MorphospaceEventCompletion $WorkspaceRoot $intent $IntentReference $paths.completion $current;Test-MorphospaceEventTransactionLedger -WorkspaceRoot $WorkspaceRoot -AnchorReference $AnchorReference -EventBytes $current;return $completion
        }finally{$stream.Dispose()}
    }finally{if($null-ne$completionSnapshot){$completionSnapshot.stream.Dispose()};foreach($lease in $leases){if($null-ne$lease.stream){$lease.stream.Dispose()}};Exit-MorphospaceWorkspaceMutex $lock}
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Get-MorphospaceLegacyEventPrefixObservation,New-MorphospaceLegacyPrefixAnchor,Test-MorphospaceEventChain,Test-MorphospaceTypedReference
