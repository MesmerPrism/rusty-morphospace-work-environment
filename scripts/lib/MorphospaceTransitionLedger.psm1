$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force
$script:MorphospaceSupersessionDelimiter = '-superseded-by-'
$script:MorphospaceTransitionIntentV1 = 'rusty.morphospace.workflow.transition_ledger_intent.v1'
$script:MorphospaceTransitionIntentV2 = 'rusty.morphospace.workflow.transition_ledger_intent.v2'
$script:MorphospaceTransitionIntentV3 = 'rusty.morphospace.workflow.transition_ledger_intent.v3'

function Get-MorphospaceLedgerDocumentHash { param([object]$Value) Get-MorphospaceCanonicalJsonSha256 $Value }
function Get-MorphospaceLedgerPath { param([string]$WorkspaceRoot,[string]$TransactionId,[ValidateSet('intent','completion')][string]$Kind) "receipts/transactions/$TransactionId.$Kind.json" }
function Read-MorphospaceLedgerJson { param([string]$Path) if(-not[IO.File]::Exists($Path)){throw "Transition artifact is missing: $Path"};Read-MorphospaceProtocolJson -Path $Path }
function Write-MorphospaceLedgerProjection { param([string]$WorkspaceRoot,[string]$RelativePath,[object]$Document) Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -Value $Document }
function Get-MorphospaceLedgerEventLineBytes { param([object]$Event)
    [Text.UTF8Encoding]::new($false).GetBytes(($Event|ConvertTo-Json -Depth 32 -Compress)+"`n")
}
function Add-MorphospaceLedgerEvent { param([string]$Path,[object]$Event)
    $bytes=Get-MorphospaceLedgerEventLineBytes $Event
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Get-MorphospaceLedgerByteHash { param([byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Get-MorphospaceLedgerArtifactStagePath {
    param([string]$TransactionId,[int]$Index)
    "receipts/transactions/$TransactionId.artifact-$Index.pending"
}
function Test-MorphospaceLedgerBytePrefix {
    param([byte[]]$Value,[int64]$PrefixLength,[byte[]]$ExpectedPrefix)
    if($PrefixLength-lt0-or$PrefixLength-gt$Value.LongLength-or$PrefixLength-ne$ExpectedPrefix.LongLength){return $false}
    for($index=0L;$index-lt$PrefixLength;$index++){if($Value[$index]-ne$ExpectedPrefix[$index]){return $false}}
    return $true
}
function Test-MorphospaceLedgerRangeEquals {
    param([byte[]]$Value,[int64]$Offset,[byte[]]$Expected)
    if($Offset-lt0-or$Expected.LongLength-gt($Value.LongLength-$Offset)){return $false}
    for($index=0L;$index-lt$Expected.LongLength;$index++){if($Value[$Offset+$index]-ne$Expected[$index]){return $false}}
    return $true
}
function ConvertFrom-MorphospaceLedgerEventTimestamp {
    param([Parameter(Mandatory=$true)][string]$Value,[string]$Context='transition event timestamp')
    if($Value-cnotmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$'){
        throw "$Context is not a strict invariant ISO-8601 date-time."
    }
    try{return ConvertFrom-MorphospaceInvariantTimestamp $Value}catch{throw "$Context is not a valid invariant ISO-8601 date-time."}
}
function Read-MorphospaceLedgerEvents { param([string]$EventsPath,[AllowEmptyCollection()][byte[]]$ProvidedBytes)
    if($PSBoundParameters.ContainsKey('ProvidedBytes')){$bytes=$ProvidedBytes}else{$bytes=[IO.File]::ReadAllBytes($EventsPath)}
    if($bytes.Length-gt67108864){throw 'Transition event ledger exceeds the 64 MiB protocol bound.'}
    if($bytes.Length-ge3-and$bytes[0]-eq0xef-and$bytes[1]-eq0xbb-and$bytes[2]-eq0xbf){throw 'Transition event ledger must not contain a UTF-8 BOM.'}
    if($bytes-contains0){throw 'Transition event ledger contains NUL bytes.'}
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)}catch{throw 'Transition event ledger is not strict UTF-8.'}
    $lines=$text-split"`n",0
    $events=@()
    $schemaRoot=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas'
    $eventV1Schema=Join-Path $schemaRoot 'iteration-event.schema.json'
    $eventV2Schema=Join-Path $schemaRoot 'iteration-event-v2.schema.json'
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previousTimestamp=$null
    for($index=0;$index-lt$lines.Count;$index++){
        $line=$lines[$index]
        if($line.EndsWith("`r")){$line=$line.Substring(0,$line.Length-1)}
        if(-not$line){
            if($index-eq$lines.Count-1-and$text.EndsWith("`n")){continue}
            if($bytes.Length-eq0-and$index-eq0){continue}
            throw "Transition event ledger contains a blank record at line $($index+1)."
        }
        try{
            $event=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line)) -Context "transition event ledger line $($index+1)"
        }catch{throw "Transition event ledger contains malformed JSON at line $($index+1): $($_.Exception.Message)"}
        $eventSchemaId=[string]$event.schema
        if($eventSchemaId-ceq'rusty.morphospace.workflow.iteration_event.v1'){
            $eventSchema=$eventV1Schema
        }elseif($eventSchemaId-ceq'rusty.morphospace.workflow.iteration_event.v2'){
            if($index-ne0){
                throw "Transition event ledger contains a v2 event outside the historical bootstrap position at line $($index+1)."
            }
            if([string]$event.previous_event_sha256-cne('0'*64)){
                throw 'Transition event ledger historical v2 bootstrap does not use the zero predecessor.'
            }
            $eventSchema=$eventV2Schema
        }else{
            throw "Transition event ledger entry has an unsupported schema at line $($index+1)."
        }
        if(-not(Test-Json -Json ($event|ConvertTo-Json -Depth 16 -Compress) -SchemaFile $eventSchema)){
            throw "Transition event ledger entry fails the exact iteration-event contract at line $($index+1)."
        }
        if(-not$seen.Add([string]$event.event_id)){throw "Transition event ledger repeats event identity '$([string]$event.event_id)'."}
        if([int]$event.sequence-ne$events.Count+1){throw "Transition event ledger sequence is not contiguous at line $($index+1)."}
        $timestamp=ConvertFrom-MorphospaceLedgerEventTimestamp ([string]$event.timestamp) "Transition event ledger timestamp at line $($index+1)"
        if($null-ne$previousTimestamp-and$timestamp-lt$previousTimestamp){throw "Transition event ledger chronology regresses at line $($index+1)."}
        $previousTimestamp=$timestamp
        $events+=,$event
    }
    @($events)
}
function Get-MorphospaceLedgerSnapshot { param([string]$EventsPath)
    $bytes=[IO.File]::ReadAllBytes($EventsPath)
    $events=@(Read-MorphospaceLedgerEvents -EventsPath $EventsPath -ProvidedBytes $bytes)
    [pscustomobject]@{
        bytes=$bytes
        length=[int64]$bytes.LongLength
        sha256=Get-MorphospaceLedgerByteHash $bytes
        events=$events
        tail_id=$(if($events.Count){[string]$events[-1].event_id}else{$null})
    }
}
function Test-MorphospaceLedgerEventPresent { param([string]$EventsPath,[string]$EventId)
    @((Read-MorphospaceLedgerEvents $EventsPath) | Where-Object { [string]$_.event_id -ceq $EventId })
}
function Get-MorphospaceLedgerEventTail { param([string]$EventsPath)
    $events=@(Read-MorphospaceLedgerEvents $EventsPath)
    if($events.Count-eq0){return $null}
    return [string]$events[-1].event_id
}
function Assert-MorphospaceLedgerEventPlacement {
    param([string]$EventsPath,[object]$Intent,[switch]$AllowHistorical,[switch]$RequirePresent)
    $snapshot=Get-MorphospaceLedgerSnapshot $EventsPath
    $events=@($snapshot.events)
    $matchingIndexes=@()
    for($index=0;$index-lt$events.Count;$index++){
        if([string]$events[$index].event_id-ceq[string]$Intent.event.event_id){$matchingIndexes+=,$index}
    }
    if($matchingIndexes.Count-gt1){throw 'Transition event is duplicated.'}
    if($matchingIndexes.Count-eq0){
        if($RequirePresent){throw 'Transition event is absent.'}
        if($snapshot.length-ne[int64]$Intent.expected.events_length-or
           [string]$snapshot.sha256-cne[string]$Intent.expected.events_sha256){
            throw 'Transition event ledger differs from the authenticated pre-append snapshot.'
        }
        $tail=if($events.Count){[string]$events[-1].event_id}else{$null}
        if([string]$tail-cne[string]$Intent.expected.event_tail_id){throw 'Transition event predecessor differs from its intent.'}
        if([int]$Intent.event.sequence-ne$events.Count+1){throw 'Transition event sequence does not identify the next ledger position.'}
        $eventTimestamp=ConvertFrom-MorphospaceLedgerEventTimestamp ([string]$Intent.event.timestamp) 'Proposed transition event timestamp'
        if($events.Count){
            $tailTimestamp=ConvertFrom-MorphospaceLedgerEventTimestamp ([string]$events[-1].timestamp) 'Transition event ledger tail timestamp'
            if($eventTimestamp-lt$tailTimestamp){throw 'Proposed transition event timestamp precedes the current ledger tail.'}
        }
        return $false
    }
    $eventIndex=[int]$matchingIndexes[0]
    $preLength=[int64]$Intent.expected.events_length
    if($preLength-gt$snapshot.length){throw 'Transition event ledger is shorter than its authenticated pre-append snapshot.'}
    $preBytes=[byte[]]::new($preLength)
    if($preLength){[Array]::Copy($snapshot.bytes,0,$preBytes,0,$preLength)}
    if((Get-MorphospaceLedgerByteHash $preBytes)-cne[string]$Intent.expected.events_sha256){
        throw 'Transition event ledger prefix differs from the authenticated pre-append snapshot.'
    }
    $eventLine=Get-MorphospaceLedgerEventLineBytes $Intent.event
    if(-not(Test-MorphospaceLedgerRangeEquals -Value $snapshot.bytes -Offset $preLength -Expected $eventLine)){
        throw 'Transition event ledger does not contain the exact canonical event append.'
    }
    if((Get-MorphospaceLedgerDocumentHash $events[$eventIndex])-cne(Get-MorphospaceLedgerDocumentHash $Intent.event)){
        throw 'Transition event differs from its intent.'
    }
    if(-not$AllowHistorical-and$eventIndex-ne$events.Count-1){throw 'Transition event is not the ledger tail.'}
    $predecessor=if($eventIndex-gt0){[string]$events[$eventIndex-1].event_id}else{$null}
    if([string]$predecessor-cne[string]$Intent.expected.event_tail_id){throw 'Transition event predecessor differs from its intent.'}
    if([int]$Intent.event.sequence-ne$eventIndex+1){throw 'Transition event sequence does not match its ledger position.'}
    return $true
}
function Repair-MorphospaceLedgerTornAppend {
    param([string]$EventsPath,[object]$Intent)
    $bytes=[IO.File]::ReadAllBytes($EventsPath)
    $preLength=[int64]$Intent.expected.events_length
    $eventLine=Get-MorphospaceLedgerEventLineBytes $Intent.event
    if($bytes.LongLength-le$preLength-or$bytes.LongLength-ge($preLength+$eventLine.LongLength)){return $false}
    $preBytes=[byte[]]::new($preLength)
    if($preLength){[Array]::Copy($bytes,0,$preBytes,0,$preLength)}
    if((Get-MorphospaceLedgerByteHash $preBytes)-cne[string]$Intent.expected.events_sha256){return $false}
    $suffixLength=[int64]($bytes.LongLength-$preLength)
    $expectedSuffix=[byte[]]::new($suffixLength)
    [Array]::Copy($eventLine,0,$expectedSuffix,0,$suffixLength)
    if(-not(Test-MorphospaceLedgerRangeEquals -Value $bytes -Offset $preLength -Expected $expectedSuffix)){return $false}
    $stream=[IO.FileStream]::new($EventsPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.SetLength($preLength);$stream.Flush($true)}finally{$stream.Dispose()}
    return $true
}
function Assert-MorphospaceSupersessionTarget {
    param([object]$Event,[object]$TargetState,[object]$TargetUnit)
    if($null-eq$Event-or$null-eq$Event.PSObject.Properties['event_id']){return $null}
    $eventId=[string]$Event.event_id
    $delimiter=$script:MorphospaceSupersessionDelimiter
    $firstDelimiter=$eventId.IndexOf($delimiter,[StringComparison]::Ordinal)
    if($firstDelimiter-lt0){return $null}
    if($firstDelimiter-ne$eventId.LastIndexOf($delimiter,[StringComparison]::Ordinal)){
        throw 'Transition ledger supersession event identity contains an ambiguous repeated delimiter.'
    }
    if($null-eq$Event.PSObject.Properties['unit_id']-or$null-eq$TargetState.PSObject.Properties['current_unit']){
        throw 'Transition ledger supersession requires independently bound old and replacement unit identities.'
    }
    $oldId=[string]$Event.unit_id
    $currentId=[string]$TargetState.current_unit
    foreach($endpoint in @(
        [pscustomobject]@{role='old';value=$oldId},
        [pscustomobject]@{role='replacement';value=$currentId}
    )){
        if(([string]$endpoint.value).Contains($delimiter,[StringComparison]::Ordinal)){
            throw "Transition ledger supersession $([string]$endpoint.role) endpoint contains the reserved delimiter."
        }
        if([string]$endpoint.value-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){
            throw "Transition ledger supersession $([string]$endpoint.role) endpoint is not a portable unit identity."
        }
    }
    if($oldId-ceq$currentId){throw 'Transition ledger supersession old and replacement unit identities must differ.'}
    $expectedEventId="$oldId$delimiter$currentId"
    if($eventId-cne$expectedEventId){
        throw "Transition ledger supersession event identity must exactly equal '$expectedEventId'."
    }
    if([string]$Event.event_type-cne'state-transition'){
        throw 'Transition ledger supersession event must be a state transition.'
    }
    if($null-eq$TargetUnit.PSObject.Properties['unit_id']-or
       [string]$TargetUnit.unit_id-cne$currentId){
        throw "Transition ledger supersession target unit must be replacement '$currentId'."
    }
    return [pscustomobject]@{old_unit_id=$oldId;current_unit_id=$currentId;event_id=$expectedEventId}
}
function Get-MorphospaceSupersededUnitBinding {
    param([string]$Workspace,[string]$UnitPath,[string]$OldUnitId)
    $unitAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath $UnitPath -RequireLeaf
    $unitDirectory=[IO.Path]::GetDirectoryName($unitAbsolute)
    $matches=@()
    foreach($candidatePath in @([IO.Directory]::EnumerateFiles($unitDirectory,'*.json',[IO.SearchOption]::TopDirectoryOnly))){
        $candidate=Read-MorphospaceProtocolJson -Path $candidatePath
        if($null-ne$candidate.PSObject.Properties['unit_id']-and[string]$candidate.unit_id-ceq$OldUnitId){
            $relativePath=ConvertTo-MorphospaceProtocolRelativePath ([IO.Path]::GetRelativePath($Workspace,$candidatePath).Replace('\','/'))
            $matches+=,[pscustomobject]@{
                path=$relativePath
                sha256=Get-MorphospaceLedgerDocumentHash $candidate
                document=$candidate
            }
        }
    }
    if($matches.Count-ne1){
        throw "Transition ledger supersession requires exactly one old unit document for '$OldUnitId'."
    }
    return $matches[0]
}
function Assert-MorphospaceSupersessionWorkspacePreflight {
    param(
        [string]$Workspace,
        [string]$UnitPath,
        [object]$CurrentState,
        [object]$CurrentTargetUnit,
        [object]$TargetState,
        [object]$TargetUnit,
        [object]$Event,
        [AllowNull()][object]$AuthenticatedBinding,
        [switch]$AllowAppliedTarget
    )
    $identity=Assert-MorphospaceSupersessionTarget -Event $Event -TargetState $TargetState -TargetUnit $TargetUnit
    if($null-eq$identity){return}
    if($null-eq$CurrentState.PSObject.Properties['current_unit']){
        throw 'Transition ledger supersession requires a current old unit in workspace state.'
    }
    $observedCurrent=[string]$CurrentState.current_unit
    if($observedCurrent-cne[string]$identity.old_unit_id-and
       (-not$AllowAppliedTarget-or$observedCurrent-cne[string]$identity.current_unit_id)){
        throw "Transition ledger supersession current unit must be old unit '$([string]$identity.old_unit_id)'."
    }
    if($null-eq$CurrentTargetUnit.PSObject.Properties['unit_id']-or
       [string]$CurrentTargetUnit.unit_id-cne[string]$identity.current_unit_id){
        throw "Transition ledger supersession unit path must identify replacement '$([string]$identity.current_unit_id)'."
    }
    $oldUnitBinding=Get-MorphospaceSupersededUnitBinding -Workspace $Workspace -UnitPath $UnitPath -OldUnitId ([string]$identity.old_unit_id)
    if($null-ne$AuthenticatedBinding){
        if([string]$AuthenticatedBinding.old_unit_id-cne[string]$identity.old_unit_id-or
           [string]$AuthenticatedBinding.new_unit_id-cne[string]$identity.current_unit_id-or
           [string]$AuthenticatedBinding.old_unit.path-cne[string]$oldUnitBinding.path-or
           [string]$AuthenticatedBinding.old_unit.sha256-cne[string]$oldUnitBinding.sha256){
            throw 'Transition ledger supersession workspace endpoints differ from the authenticated intent binding.'
        }
    }
    if(@('active','validating')-cnotcontains[string]$oldUnitBinding.document.status){
        throw "Transition ledger supersession old unit '$([string]$identity.old_unit_id)' must be active or validating."
    }
    return $oldUnitBinding
}
function Assert-MorphospaceLedgerIntent {
    param([object]$Intent,[string]$TransactionId)
    $schema=[string]$Intent.schema
    if($schema-ceq$script:MorphospaceTransitionIntentV1){
        Assert-MorphospaceExactPropertySet $Intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') @() 'Transition ledger intent'
    }elseif($schema-ceq$script:MorphospaceTransitionIntentV2){
        Assert-MorphospaceExactPropertySet $Intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','supersession','status') @() 'Transition ledger intent'
    }elseif($schema-ceq$script:MorphospaceTransitionIntentV3){
        Assert-MorphospaceExactPropertySet $Intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','additional_projections','artifacts','event','status') @() 'Transition ledger intent'
    }else{throw 'Transition ledger intent schema is unsupported.'}
    if([string]$Intent.status-cne'prepared'-or[string]$Intent.transaction_id-cne$TransactionId){throw 'Transition ledger intent identity/status is invalid.'}
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$Intent.created_at))
    foreach($referenceName in @('state','unit','events')){
        Assert-MorphospaceExactPropertySet $Intent.$referenceName @('path') @() "Transition ledger intent $referenceName reference"
        [void](ConvertTo-MorphospaceProtocolRelativePath ([string]$Intent.$referenceName.path))
    }
    Assert-MorphospaceExactPropertySet $Intent.pre @('state','unit') @() 'Transition ledger intent pre'
    Assert-MorphospaceExactPropertySet $Intent.target @('state','unit') @() 'Transition ledger intent target'
    Assert-MorphospaceExactPropertySet $Intent.expected @('state_sha256','unit_sha256','event_tail_id','events_sha256','events_length') @() 'Transition ledger intent expected'
    if($Intent.expected.events_length-isnot[int]-and$Intent.expected.events_length-isnot[long]){
        throw 'Transition ledger intent pre-append event-ledger length is not an integer.'
    }
    if([string]$Intent.expected.events_sha256-cnotmatch'^[0-9a-f]{64}$'-or
       [int64]$Intent.expected.events_length-lt0-or[int64]$Intent.expected.events_length-gt67108864){
        throw 'Transition ledger intent pre-append event-ledger binding is invalid.'
    }
    foreach($projection in @('state','unit')){
        Assert-MorphospaceExactPropertySet $Intent.pre.$projection @('sha256') @() "Transition ledger intent pre-$projection"
        Assert-MorphospaceExactPropertySet $Intent.target.$projection @('sha256','document') @() "Transition ledger intent target-$projection"
        $preHash=[string]$Intent.pre.$projection.sha256
        $targetHash=[string]$Intent.target.$projection.sha256
        $expectedHash=[string]$Intent.expected."${projection}_sha256"
        if($preHash-cnotmatch'^[0-9a-f]{64}$'-or$targetHash-cnotmatch'^[0-9a-f]{64}$'-or$expectedHash-cne$preHash-or
           (Get-MorphospaceLedgerDocumentHash $Intent.target.$projection.document)-cne$targetHash){
            throw "Transition ledger intent $projection hashes are invalid or inconsistent."
        }
    }
    if(-not$Intent.event-or-not[string]$Intent.event.event_id){throw 'Transition ledger intent event identity is absent.'}
    if([string]$Intent.transaction_id-cne"$([string]$Intent.event.event_id)-transition"){throw 'Transition ledger transaction identity is not derived from its event.'}
    $eventSchema=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas\iteration-event.schema.json'
    if(-not(Test-Json -Json ($Intent.event|ConvertTo-Json -Depth 16 -Compress) -SchemaFile $eventSchema)){
        throw 'Transition ledger intent event does not satisfy the exact iteration-event contract.'
    }
    [void](ConvertFrom-MorphospaceLedgerEventTimestamp ([string]$Intent.event.timestamp) 'Transition ledger intent event timestamp')
    foreach($targetName in @('state','unit')){
        $document=$Intent.target.$targetName.document
        if($document.PSObject.Properties.Name-contains'project_id'){
            if([string]$document.project_id-cne[string]$Intent.event.project_id){throw "Transition ledger target $targetName project identity differs from its event."}
        }
        if($document.PSObject.Properties.Name-contains'last_event_id'){
            if([string]$document.last_event_id-cne[string]$Intent.event.event_id){throw "Transition ledger target $targetName last-event identity differs from its event."}
        }
    }
    $isSupersessionCandidate=([string]$Intent.event.event_id).Contains($script:MorphospaceSupersessionDelimiter,[StringComparison]::Ordinal)
    if($isSupersessionCandidate-and$schema-cne$script:MorphospaceTransitionIntentV2){
        throw 'Legacy supersession intent lacks an authenticated semantic binding.'
    }
    if(-not$isSupersessionCandidate-and$schema-ceq$script:MorphospaceTransitionIntentV2){
        throw 'Transition ledger intent v2 is reserved for an authenticated supersession.'
    }
    if($isSupersessionCandidate-and$schema-ceq$script:MorphospaceTransitionIntentV3){
        throw 'Transition ledger intent v3 may not be combined with supersession.'
    }
    $supersession=Assert-MorphospaceSupersessionTarget -Event $Intent.event -TargetState $Intent.target.state.document -TargetUnit $Intent.target.unit.document
    if($null-ne$supersession){
        $binding=$Intent.supersession
        Assert-MorphospaceExactPropertySet $binding @('old_unit_id','new_unit_id','pre_state','old_unit','target_unit_path') @() 'Transition ledger supersession binding'
        Assert-MorphospaceExactPropertySet $binding.pre_state @('path','sha256','document') @() 'Transition ledger supersession pre-state binding'
        Assert-MorphospaceExactPropertySet $binding.old_unit @('path','sha256','document') @() 'Transition ledger supersession old-unit binding'
        $preStatePath=ConvertTo-MorphospaceProtocolRelativePath ([string]$binding.pre_state.path)
        $oldPath=ConvertTo-MorphospaceProtocolRelativePath ([string]$binding.old_unit.path)
        $targetUnitPath=ConvertTo-MorphospaceProtocolRelativePath ([string]$binding.target_unit_path)
        if($preStatePath-cne[string]$Intent.state.path-or$targetUnitPath-cne[string]$Intent.unit.path){
            throw 'Transition ledger supersession state or replacement path differs from its authenticated binding.'
        }
        if($oldPath-ceq[string]$Intent.unit.path){throw 'Transition ledger supersession old and replacement unit paths must differ.'}
        if([string]$binding.old_unit_id-cne[string]$supersession.old_unit_id-or
           [string]$binding.new_unit_id-cne[string]$supersession.current_unit_id){
            throw 'Transition ledger supersession binding endpoints differ from the event and target state.'
        }
        if([string]$binding.pre_state.sha256-cne[string]$Intent.pre.state.sha256-or
           (Get-MorphospaceLedgerDocumentHash $binding.pre_state.document)-cne[string]$binding.pre_state.sha256-or
           [string]$binding.pre_state.document.current_unit-cne[string]$supersession.old_unit_id){
            throw 'Transition ledger supersession pre-state binding is invalid.'
        }
        if([string]$binding.old_unit.sha256-cnotmatch'^[0-9a-f]{64}$'-or
           (Get-MorphospaceLedgerDocumentHash $binding.old_unit.document)-cne[string]$binding.old_unit.sha256-or
           [string]$binding.old_unit.document.unit_id-cne[string]$supersession.old_unit_id-or
           @('active','validating')-cnotcontains[string]$binding.old_unit.document.status){
            throw 'Transition ledger supersession old-unit binding is invalid.'
        }
        if($binding.old_unit.document.PSObject.Properties.Name-contains'project_id'-and
           [string]$binding.old_unit.document.project_id-cne[string]$Intent.event.project_id){
            throw 'Transition ledger supersession old-unit project identity differs from its event.'
        }
    }
    if($null-eq$supersession-and$Intent.target.unit.document.PSObject.Properties.Name-contains'unit_id'){
        if([string]$Intent.target.unit.document.unit_id-cne[string]$Intent.event.unit_id){throw 'Transition ledger target unit identity differs from its event.'}
    }
    if($schema-ceq$script:MorphospaceTransitionIntentV3){
        if(@($Intent.additional_projections).Count-lt1-or@($Intent.additional_projections).Count-gt2){
            throw 'Transition ledger intent v3 requires one or two additional projections.'
        }
        $projectionPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $previousProjectionPath=$null
        foreach($projection in @($Intent.additional_projections)){
            Assert-MorphospaceExactPropertySet $projection @('path','pre_sha256','target_sha256','document') @() 'Transition ledger additional projection'
            $projectionPath=ConvertTo-MorphospaceProtocolRelativePath ([string]$projection.path)
            if([string]$projection.path-cne$projectionPath-or-not$projectionPaths.Add($projectionPath)){
                throw 'Transition ledger intent v3 repeats or mis-canonicalizes an additional projection path.'
            }
            if(@('feature.lock.json','project.spec.json')-cnotcontains$projectionPath){
                throw "Transition ledger intent v3 does not authorize additional projection '$projectionPath'."
            }
            if($null-ne$previousProjectionPath-and[StringComparer]::Ordinal.Compare([string]$previousProjectionPath,$projectionPath)-ge0){
                throw 'Transition ledger intent v3 additional projections are not in canonical path order.'
            }
            $previousProjectionPath=$projectionPath
            if([string]$projection.pre_sha256-cnotmatch'^[0-9a-f]{64}$'-or
               [string]$projection.target_sha256-cnotmatch'^[0-9a-f]{64}$'-or
               (Get-MorphospaceLedgerDocumentHash $projection.document)-cne[string]$projection.target_sha256){
                throw "Transition ledger additional projection '$projectionPath' has invalid or inconsistent hashes."
            }
            if($projection.document.PSObject.Properties.Name-contains'project_id'-and
               [string]$projection.document.project_id-cne[string]$Intent.event.project_id){
                throw "Transition ledger additional projection '$projectionPath' project identity differs from its event."
            }
        }
    }
    $artifactTargets=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($artifact in @($Intent.artifacts)){
        Assert-MorphospaceExactPropertySet $artifact @('path','sha256','bytes_base64') @() 'Transition ledger intent artifact'
        $artifactPath=ConvertTo-MorphospaceProtocolRelativePath ([string]$artifact.path)
        if(-not$artifactTargets.Add($artifactPath)){throw 'Transition ledger intent repeats an artifact target path.'}
        try{$bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64)}catch{throw 'Transition ledger intent artifact payload is not valid base64.'}
        if([Convert]::ToBase64String($bytes)-cne[string]$artifact.bytes_base64){throw 'Transition ledger intent artifact payload is not canonical base64.'}
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if($hash-cne[string]$artifact.sha256){throw 'Transition ledger intent artifact payload hash is inconsistent.'}
    }
}
function Assert-MorphospaceNoOutstandingTransitionIntent {
    param([string]$Workspace,[string]$TransactionId)
    $transactions=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath 'receipts/transactions'
    if(-not[IO.Directory]::Exists($transactions)){return}
    foreach($intentFile in @([IO.Directory]::EnumerateFiles($transactions,'*.intent.json',[IO.SearchOption]::TopDirectoryOnly))){
        $name=[IO.Path]::GetFileName($intentFile)
        if($name-cnotmatch'^(?<transaction>[a-z0-9][a-z0-9-]{1,191})\.intent\.json$'){
            throw "Transition receipt namespace contains a noncanonical intent filename: $name"
        }
        $pendingTransaction=[string]$Matches.transaction
        $completion=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath (Get-MorphospaceLedgerPath $Workspace $pendingTransaction completion)
        if(-not[IO.File]::Exists($completion)){
            throw "Workspace has an outstanding transition intent requiring repair: $pendingTransaction"
        }
    }
}
function Get-MorphospaceLedgerReservedPathSet {
    param([string]$Workspace,[string]$TransactionId,[object]$Intent)
    $reserved=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($relative in @(
        [string]$Intent.state.path,
        [string]$Intent.unit.path,
        [string]$Intent.events.path,
        (Get-MorphospaceLedgerPath $Workspace $TransactionId intent),
        (Get-MorphospaceLedgerPath $Workspace $TransactionId completion)
    )){
        [void]$reserved.Add([IO.Path]::GetFullPath((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath $relative)))
    }
    foreach($projection in @($(if($Intent.PSObject.Properties.Name-contains'additional_projections'){$Intent.additional_projections}else{@()}))){
        $projectionPath=[IO.Path]::GetFullPath((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath ([string]$projection.path)))
        if(-not$reserved.Add($projectionPath)){throw "Transition additional projection collides with a reserved path: $($projection.path)"}
    }
    for($index=0;$index-lt@($Intent.artifacts).Count;$index++){
        [void]$reserved.Add([IO.Path]::GetFullPath((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath (Get-MorphospaceLedgerArtifactStagePath $TransactionId $index))))
    }
    return $reserved
}
function Assert-MorphospaceLedgerArtifactNamespace {
    param([string]$Workspace,[string]$TransactionId,[object]$Intent)
    $reserved=Get-MorphospaceLedgerReservedPathSet $Workspace $TransactionId $Intent
    $targets=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($artifact in @($Intent.artifacts)){
        if([string]$artifact.path-like'receipts/transactions/*'){
            throw "Transition artifact target may not occupy the transaction control namespace: $($artifact.path)"
        }
        $target=[IO.Path]::GetFullPath((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath ([string]$artifact.path)))
        if(-not$targets.Add($target)){throw 'Transition artifacts repeat a target path.'}
        if($reserved.Contains($target)){throw "Transition artifact target collides with the transaction control namespace: $($artifact.path)"}
    }
}
function Install-MorphospaceLedgerArtifacts {
    param([string]$Workspace,[string]$TransactionId,[object]$Intent)
    Assert-MorphospaceLedgerArtifactNamespace $Workspace $TransactionId $Intent
    $installations=@()
    for($index=0;$index-lt@($Intent.artifacts).Count;$index++){
        $artifact=@($Intent.artifacts)[$index]
        $target=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath ([string]$artifact.path)
        $stage=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath (Get-MorphospaceLedgerArtifactStagePath $TransactionId $index)
        $targetExists=[IO.File]::Exists($target)
        $stageExists=[IO.File]::Exists($stage)
        if([IO.Directory]::Exists($target)-or[IO.Directory]::Exists($stage)){
            throw "Transition artifact target or transaction stage is occupied: $($artifact.path)"
        }
        if($stageExists){
            if((Get-MorphospaceFileSha256 $stage)-cne[string]$artifact.sha256){throw "Transition artifact stage differs from its intent: $($artifact.path)"}
            if($targetExists){throw "Transition artifact target was occupied after intent publication: $($artifact.path)"}
        }elseif(-not$targetExists){
            throw "Transition artifact lost both its transaction stage and target: $($artifact.path)"
        }
        if($targetExists-and(Get-MorphospaceFileSha256 $target)-cne[string]$artifact.sha256){throw "Transition artifact target differs from its intent: $($artifact.path)"}
        $installations+=,[pscustomobject]@{artifact=$artifact;target=$target;stage=$stage;move=$stageExists}
    }
    foreach($installation in $installations){
        if($installation.move){
            $parent=[IO.Path]::GetDirectoryName([string]$installation.target)
            [IO.Directory]::CreateDirectory($parent)|Out-Null
            [IO.File]::Move([string]$installation.stage,[string]$installation.target,$false)
        }
        if((Get-MorphospaceFileSha256 ([string]$installation.target))-cne[string]$installation.artifact.sha256){
            throw "Transition artifact target differs from its intent: $([string]$installation.artifact.path)"
        }
    }
}
function Assert-MorphospaceLedgerCommittedCompletion {
    param([string]$Workspace,[string]$TransactionId,[string]$IntentRelative,[string]$IntentAbsolute,[object]$Intent,[string]$CompletionAbsolute)
    $completion=Read-MorphospaceLedgerJson $CompletionAbsolute
    Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Transition ledger completion'
    Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Transition ledger completion intent reference'
    if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or
       [string]$completion.transaction_id-cne$TransactionId-or[string]$completion.status-cne'committed'-or
       [string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$IntentRelative-or
       [string]$completion.intent.schema-cne[string]$Intent.schema-or
       [string]$completion.intent.sha256-cne(Get-MorphospaceFileSha256 $IntentAbsolute)-or
       [string]$completion.state_sha256-cne[string]$Intent.target.state.sha256-or
       [string]$completion.unit_sha256-cne[string]$Intent.target.unit.sha256-or
       [string]$completion.event_id-cne[string]$Intent.event.event_id){
        throw 'Transition ledger completion is not canonically bound to its exact intent.'
    }
    $createdAt=Test-MorphospaceStrictUtcTimestamp ([string]$Intent.created_at)
    $completedAt=Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at)
    if($completedAt-lt$createdAt){throw 'Transition ledger completion timestamp precedes its intent creation.'}
    $eventsAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath ([string]$Intent.events.path) -RequireLeaf
    [void](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $Intent -AllowHistorical -RequirePresent)
    foreach($artifact in @($Intent.artifacts)){
        $target=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath ([string]$artifact.path) -RequireLeaf
        if((Get-MorphospaceFileSha256 $target)-cne[string]$artifact.sha256){throw "Transition ledger committed artifact differs from its intent: $($artifact.path)"}
    }
    if([string](Get-MorphospaceLedgerEventTail $eventsAbsolute)-ceq[string]$Intent.event.event_id){
        foreach($projection in @('state','unit')){
            $current=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$Intent.$projection.path) -RequireLeaf)
            if((Get-MorphospaceLedgerDocumentHash $current)-cne[string]$Intent.target.$projection.sha256){throw "Transition ledger tail completion does not own its target $projection projection."}
        }
        foreach($projection in @($(if($Intent.PSObject.Properties.Name-contains'additional_projections'){$Intent.additional_projections}else{@()}))){
            $current=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$projection.path) -RequireLeaf)
            if((Get-MorphospaceLedgerDocumentHash $current)-cne[string]$projection.target_sha256){throw "Transition ledger tail completion does not own additional projection '$($projection.path)'."}
        }
    }
}
function Complete-MorphospaceTransitionLedger {
    param([string]$WorkspaceRoot,[string]$TransactionId,[switch]$Repair,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none')
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$intentRelative=Get-MorphospaceLedgerPath $workspace $TransactionId intent;$completionRelative=Get-MorphospaceLedgerPath $workspace $TransactionId completion
    $completionAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $completionRelative
    $lock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $workspace
    try {
        $intentAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $intentRelative -RequireLeaf
        $intent=Read-MorphospaceLedgerJson $intentAbsolute
        Assert-MorphospaceLedgerIntent $intent $TransactionId
        Assert-MorphospaceLedgerArtifactNamespace $workspace $TransactionId $intent
        if([IO.File]::Exists($completionAbsolute)){
            Assert-MorphospaceLedgerCommittedCompletion $workspace $TransactionId $intentRelative $intentAbsolute $intent $completionAbsolute
            return [pscustomobject]@{transaction_id=$TransactionId;status='already-committed'}
        }
        $stateAbsolute=Resolve-MorphospaceWorkspacePath $workspace ([string]$intent.state.path) -RequireLeaf
        $unitAbsolute=Resolve-MorphospaceWorkspacePath $workspace ([string]$intent.unit.path) -RequireLeaf
        $eventsAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath ([string]$intent.events.path) -RequireLeaf
        $currentState=Read-MorphospaceProtocolJson -Path $stateAbsolute
        $currentUnit=Read-MorphospaceProtocolJson -Path $unitAbsolute
        $currentStateHash=Get-MorphospaceLedgerDocumentHash $currentState
        $currentUnitHash=Get-MorphospaceLedgerDocumentHash $currentUnit
        if($intent.PSObject.Properties.Name-contains'expected'){
            $allowedStateHashes=@([string]$intent.expected.state_sha256,[string]$intent.target.state.sha256)
            $allowedUnitHashes=@([string]$intent.expected.unit_sha256,[string]$intent.target.unit.sha256)
            if($allowedStateHashes-notcontains$currentStateHash){throw "Transition $TransactionId failed expected pre-state CAS."}
            if($allowedUnitHashes-notcontains$currentUnitHash){throw "Transition $TransactionId failed expected pre-unit CAS."}
        }
        foreach($projection in @($(if($intent.PSObject.Properties.Name-contains'additional_projections'){$intent.additional_projections}else{@()}))){
            $current=Read-MorphospaceProtocolJson -Path (Resolve-MorphospaceWorkspacePath $workspace ([string]$projection.path) -RequireLeaf)
            $actual=Get-MorphospaceLedgerDocumentHash $current
            if(@([string]$projection.pre_sha256,[string]$projection.target_sha256)-notcontains$actual){
                throw "Transition $TransactionId failed additional-projection CAS for '$($projection.path)'."
            }
        }
        [void](Assert-MorphospaceSupersessionWorkspacePreflight `
            -Workspace $workspace `
            -UnitPath ([string]$intent.unit.path) `
            -CurrentState $currentState `
            -CurrentTargetUnit $currentUnit `
            -TargetState $intent.target.state.document `
            -TargetUnit $intent.target.unit.document `
            -Event $intent.event `
            -AuthenticatedBinding $intent.supersession `
            -AllowAppliedTarget)
        if($Repair){[void](Repair-MorphospaceLedgerTornAppend $eventsAbsolute $intent)}
        [void](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intent)
        Install-MorphospaceLedgerArtifacts $workspace $TransactionId $intent
        if($FaultAfter-eq'after-artifact'){throw 'Injected interruption after artifact installation.'}
        foreach($projection in @('state','unit')){
            $current=Read-MorphospaceProtocolJson -Path (Resolve-MorphospaceWorkspacePath $workspace ([string]$intent.$projection.path) -RequireLeaf)
            $actual=Get-MorphospaceLedgerDocumentHash $current
            if($actual-ne[string]$intent.target.$projection.sha256){
                if($actual-ne[string]$intent.pre.$projection.sha256){throw "Transition $TransactionId has an unauthorized $projection projection."}
                Write-MorphospaceLedgerProjection $workspace ([string]$intent.$projection.path) $intent.target.$projection.document
            }
        }
        foreach($projection in @($(if($intent.PSObject.Properties.Name-contains'additional_projections'){$intent.additional_projections}else{@()}))){
            $current=Read-MorphospaceProtocolJson -Path (Resolve-MorphospaceWorkspacePath $workspace ([string]$projection.path) -RequireLeaf)
            $actual=Get-MorphospaceLedgerDocumentHash $current
            if($actual-cne[string]$projection.target_sha256){
                if($actual-cne[string]$projection.pre_sha256){throw "Transition $TransactionId has an unauthorized additional projection '$($projection.path)'."}
                Write-MorphospaceLedgerProjection $workspace ([string]$projection.path) $projection.document
            }
        }
        if($FaultAfter-eq'after-projection'){throw 'Injected interruption after projections.'}
        $eventPresent=[bool](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intent)
        if(-not$eventPresent){
            Add-MorphospaceLedgerEvent $eventsAbsolute $intent.event
        }
        [void](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intent)
        if($FaultAfter-eq'after-event'){throw 'Injected interruption after event append.'}
        [void](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intent)
        $completion=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.transition_ledger_completion.v1';transaction_id=$TransactionId;completed_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');intent=[pscustomobject]@{role='transition-ledger-intent';path=$intentRelative;schema=$intent.schema;sha256=(Get-MorphospaceFileSha256 $intentAbsolute)};state_sha256=[string]$intent.target.state.sha256;unit_sha256=[string]$intent.target.unit.sha256;event_id=[string]$intent.event.event_id;status='committed'}
        Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath $completionRelative -Value $completion -NoOverwrite
        return [pscustomobject]@{transaction_id=$TransactionId;status='committed';repaired=[bool]$Repair}
    } finally {Exit-MorphospaceWorkspaceMutex $lock}
}
function Start-MorphospaceTransitionLedger {
    param(
        [string]$WorkspaceRoot,
        [string]$TransactionId,
        [string]$StatePath,
        [string]$UnitPath,
        [string]$EventsPath,
        [object]$TargetState,
        [object]$TargetUnit,
        [object]$Event,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none',
        [string]$ExpectedPreStateSha256 = '',
        [string]$ExpectedPreUnitSha256 = '',
        [string]$ExpectedStateSha256 = '',
        [string]$ExpectedUnitSha256 = '',
        [AllowNull()][string]$ExpectedEventTailId,
        [string]$ExpectedEventsSha256 = '',
        [int64]$ExpectedEventsLength = -1,
        [string]$ExpectedSupersededUnitSha256 = '',
        [object[]]$AdditionalProjections=@(),
        [object[]]$Artifacts=@()
    )
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$lock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $workspace
    try {
        Assert-MorphospaceNoOutstandingTransitionIntent $workspace $TransactionId
        $state=Read-MorphospaceProtocolJson -Path (Resolve-MorphospaceWorkspacePath $workspace $StatePath -RequireLeaf);$unit=Read-MorphospaceProtocolJson -Path (Resolve-MorphospaceWorkspacePath $workspace $UnitPath -RequireLeaf)
        $preStateSha256=Get-MorphospaceLedgerDocumentHash $state;$preUnitSha256=Get-MorphospaceLedgerDocumentHash $unit
        if($ExpectedStateSha256-and$ExpectedPreStateSha256-and$ExpectedStateSha256-cne$ExpectedPreStateSha256){throw 'Conflicting expected pre-state SHA-256 values.'}
        if($ExpectedUnitSha256-and$ExpectedPreUnitSha256-and$ExpectedUnitSha256-cne$ExpectedPreUnitSha256){throw 'Conflicting expected pre-unit SHA-256 values.'}
        if($ExpectedStateSha256){$ExpectedPreStateSha256=$ExpectedStateSha256}
        if($ExpectedUnitSha256){$ExpectedPreUnitSha256=$ExpectedUnitSha256}
        foreach($expectation in @(
            [pscustomobject]@{name='pre-state';expected=$ExpectedPreStateSha256;actual=$preStateSha256},
            [pscustomobject]@{name='pre-unit';expected=$ExpectedPreUnitSha256;actual=$preUnitSha256}
        )){
            if([string]::IsNullOrEmpty([string]$expectation.expected)){continue}
            if([string]$expectation.expected-cnotmatch'^[0-9a-f]{64}$'){throw "Expected $([string]$expectation.name) SHA-256 is not canonical lowercase hex."}
            if([string]$expectation.expected-cne[string]$expectation.actual){throw "Transition $TransactionId expected $([string]$expectation.name) SHA-256 does not match the mutex-protected current document."}
        }
        $supersessionOldUnitBinding=Assert-MorphospaceSupersessionWorkspacePreflight `
            -Workspace $workspace `
            -UnitPath $UnitPath `
            -CurrentState $state `
            -CurrentTargetUnit $unit `
            -TargetState $TargetState `
            -TargetUnit $TargetUnit `
            -Event $Event
        if($ExpectedSupersededUnitSha256){
            if($ExpectedSupersededUnitSha256-cnotmatch'^[0-9a-f]{64}$'){
                throw 'Expected superseded-unit SHA-256 is not canonical lowercase hex.'
            }
            if($null-eq$supersessionOldUnitBinding-or
               [string]$supersessionOldUnitBinding.sha256-cne$ExpectedSupersededUnitSha256){
                throw "Transition $TransactionId expected superseded-unit SHA-256 does not match the mutex-protected old unit."
            }
        }
        $eventsAbsolute=Resolve-MorphospaceWorkspacePath $workspace $EventsPath -RequireLeaf
        $eventSnapshot=Get-MorphospaceLedgerSnapshot $eventsAbsolute
        if($eventSnapshot.length-gt0-and$eventSnapshot.bytes[$eventSnapshot.length-1]-ne0x0a){
            throw 'Transition event ledger must end with LF before a canonical append.'
        }
        if($PSBoundParameters.ContainsKey('ExpectedEventTailId')-and[string]$ExpectedEventTailId-cne[string]$eventSnapshot.tail_id){throw "Transition $TransactionId failed expected event-tail CAS."}
        if($ExpectedEventsSha256){
            if($ExpectedEventsSha256-cnotmatch'^[0-9a-f]{64}$'){throw 'Expected event-ledger SHA-256 is not canonical lowercase hex.'}
            if([string]$eventSnapshot.sha256-cne$ExpectedEventsSha256){throw "Transition $TransactionId failed expected event-ledger byte-hash CAS."}
        }
        if($ExpectedEventsLength-ge0-and$eventSnapshot.length-ne$ExpectedEventsLength){throw "Transition $TransactionId failed expected event-ledger byte-length CAS."}
        if($null-ne$supersessionOldUnitBinding-and@($AdditionalProjections).Count){throw 'Transition supersession may not carry additional projections.'}
        $ownedProjections=@()
        $projectionPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $previousProjectionPath=$null
        foreach($projection in @($AdditionalProjections)){
            Assert-MorphospaceExactPropertySet $projection @('path','expected_sha256','document') @() 'Transition additional projection request'
            $projectionPath=ConvertTo-MorphospaceProtocolRelativePath ([string]$projection.path)
            if([string]$projection.path-cne$projectionPath-or-not$projectionPaths.Add($projectionPath)){
                throw 'Transition additional projection request repeats or mis-canonicalizes a path.'
            }
            if(@('feature.lock.json','project.spec.json')-cnotcontains$projectionPath){
                throw "Transition additional projection request does not authorize '$projectionPath'."
            }
            if($null-ne$previousProjectionPath-and[StringComparer]::Ordinal.Compare([string]$previousProjectionPath,$projectionPath)-ge0){
                throw 'Transition additional projection requests are not in canonical path order.'
            }
            $previousProjectionPath=$projectionPath
            $current=Read-MorphospaceProtocolJson -Path (Resolve-MorphospaceWorkspacePath $workspace $projectionPath -RequireLeaf)
            $currentHash=Get-MorphospaceLedgerDocumentHash $current
            if([string]$projection.expected_sha256-cnotmatch'^[0-9a-f]{64}$'-or[string]$projection.expected_sha256-cne$currentHash){
                throw "Transition $TransactionId expected additional-projection SHA-256 does not match '$projectionPath'."
            }
            try{$targetProjectionHash=Get-MorphospaceLedgerDocumentHash $projection.document}
            catch{throw "Transition $TransactionId additional-projection target '$projectionPath' is not a bounded protocol document: $($_.Exception.Message)"}
            $ownedProjections+=,[pscustomobject][ordered]@{
                path=$projectionPath
                pre_sha256=$currentHash
                target_sha256=$targetProjectionHash
                document=$projection.document
            }
        }
        $ownedArtifacts=@()
        foreach($artifact in @($Artifacts)){
            $hasSource=$null-ne$artifact.PSObject.Properties['source_path']
            $hasBytes=$null-ne$artifact.PSObject.Properties['bytes_base64']
            if($hasSource-eq$hasBytes){throw 'Transition artifact must provide exactly one of source_path or bytes_base64.'}
            if($hasBytes){
                try{$bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64)}catch{throw 'Transition artifact in-memory payload is not valid base64.'}
                $source='in-memory payload'
            }else{
                $source=[IO.Path]::GetFullPath([string]$artifact.source_path)
                if(-not[IO.File]::Exists($source)){throw "Transition artifact input is missing: $source"}
                $bytes=[IO.File]::ReadAllBytes($source)
            }
            $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            if($artifact.sha256-and$hash-cne[string]$artifact.sha256){throw "Transition artifact input hash mismatch: $source"}
            $ownedArtifacts+=,[pscustomobject][ordered]@{path=(ConvertTo-MorphospaceProtocolRelativePath ([string]$artifact.path));sha256=$hash;bytes_base64=[Convert]::ToBase64String($bytes)}
        }
        $intentRelative=Get-MorphospaceLedgerPath $workspace $TransactionId intent
        $intentFields=[ordered]@{
            schema=$(if($null-ne$supersessionOldUnitBinding){$script:MorphospaceTransitionIntentV2}elseif(@($ownedProjections).Count){$script:MorphospaceTransitionIntentV3}else{$script:MorphospaceTransitionIntentV1})
            transaction_id=$TransactionId
            created_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            state=[pscustomobject]@{path=(ConvertTo-MorphospaceProtocolRelativePath -Path $StatePath)}
            unit=[pscustomobject]@{path=(ConvertTo-MorphospaceProtocolRelativePath -Path $UnitPath)}
            events=[pscustomobject]@{path=(ConvertTo-MorphospaceProtocolRelativePath -Path $EventsPath)}
            pre=[pscustomobject]@{state=[pscustomobject]@{sha256=$preStateSha256};unit=[pscustomobject]@{sha256=$preUnitSha256}}
            target=[pscustomobject]@{state=[pscustomobject]@{sha256=(Get-MorphospaceLedgerDocumentHash $TargetState);document=$TargetState};unit=[pscustomobject]@{sha256=(Get-MorphospaceLedgerDocumentHash $TargetUnit);document=$TargetUnit}}
            expected=[pscustomobject]@{state_sha256=$preStateSha256;unit_sha256=$preUnitSha256;event_tail_id=$(if($PSBoundParameters.ContainsKey('ExpectedEventTailId')){$ExpectedEventTailId}else{$eventSnapshot.tail_id});events_sha256=[string]$eventSnapshot.sha256;events_length=[int64]$eventSnapshot.length}
            artifacts=@($ownedArtifacts)
            event=$Event
        }
        if(@($ownedProjections).Count){$intentFields.additional_projections=@($ownedProjections)}
        if($null-ne$supersessionOldUnitBinding){
            $intentFields.supersession=[pscustomobject][ordered]@{
                old_unit_id=[string]$Event.unit_id
                new_unit_id=[string]$TargetState.current_unit
                pre_state=[pscustomobject][ordered]@{
                    path=(ConvertTo-MorphospaceProtocolRelativePath -Path $StatePath)
                    sha256=$preStateSha256
                    document=$state
                }
                old_unit=[pscustomobject][ordered]@{
                    path=[string]$supersessionOldUnitBinding.path
                    sha256=[string]$supersessionOldUnitBinding.sha256
                    document=$supersessionOldUnitBinding.document
                }
                target_unit_path=(ConvertTo-MorphospaceProtocolRelativePath -Path $UnitPath)
            }
        }
        $intentFields.status='prepared'
        $intent=[pscustomobject]$intentFields
        Assert-MorphospaceLedgerIntent $intent $TransactionId
        Assert-MorphospaceLedgerArtifactNamespace $workspace $TransactionId $intent
        [void](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intent)
        $stagePaths=@()
        for($index=0;$index-lt@($ownedArtifacts).Count;$index++){
            $artifact=@($ownedArtifacts)[$index]
            $target=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath ([string]$artifact.path)
            $stage=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath (Get-MorphospaceLedgerArtifactStagePath $TransactionId $index)
            if([IO.File]::Exists($target)-or[IO.Directory]::Exists($target)){throw "Transition artifact target must be absent before intent publication: $($artifact.path)"}
            if([IO.File]::Exists($stage)-or[IO.Directory]::Exists($stage)){throw "Transition artifact stage must be absent before intent publication: $($artifact.path)"}
            $stagePaths+=,$stage
        }
        $intentPublished=$false
        try{
            for($index=0;$index-lt@($ownedArtifacts).Count;$index++){
                $stage=$stagePaths[$index]
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stage))|Out-Null
                $bytes=[Convert]::FromBase64String([string]@($ownedArtifacts)[$index].bytes_base64)
                $stream=[IO.FileStream]::new($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
                try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            }
            Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath $intentRelative -Value $intent -NoOverwrite
            $intentPublished=$true
        }finally{
            if(-not$intentPublished){foreach($stage in $stagePaths){if([IO.File]::Exists($stage)){[IO.File]::Delete($stage)}}}
        }
        if($FaultAfter-eq'after-intent'){throw 'Injected interruption after intent publication.'}
    } finally {Exit-MorphospaceWorkspaceMutex $lock}
    Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $TransactionId -FaultAfter $FaultAfter
}
Export-ModuleMember -Function Start-MorphospaceTransitionLedger,Complete-MorphospaceTransitionLedger
