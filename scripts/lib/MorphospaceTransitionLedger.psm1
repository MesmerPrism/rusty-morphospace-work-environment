$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force

function Get-MorphospaceLedgerDocumentHash { param([object]$Value) Get-MorphospaceCanonicalJsonSha256 $Value }
function Get-MorphospaceLedgerPath { param([string]$WorkspaceRoot,[string]$TransactionId,[ValidateSet('intent','completion')][string]$Kind) "receipts/transactions/$TransactionId.$Kind.json" }
function Read-MorphospaceLedgerJson { param([string]$Path) if(-not[IO.File]::Exists($Path)){throw "Transition artifact is missing: $Path"};Read-MorphospaceProtocolJson -Path $Path }
function Write-MorphospaceLedgerProjection { param([string]$WorkspaceRoot,[string]$RelativePath,[object]$Document) Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -Value $Document }
function Add-MorphospaceLedgerEvent { param([string]$Path,[object]$Event)
    $line=($Event|ConvertTo-Json -Depth 32 -Compress)+[Environment]::NewLine
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes($line);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Read-MorphospaceLedgerEvents { param([string]$EventsPath)
    $bytes=[IO.File]::ReadAllBytes($EventsPath)
    if($bytes.Length-gt67108864){throw 'Transition event ledger exceeds the 64 MiB protocol bound.'}
    if($bytes.Length-ge3-and$bytes[0]-eq0xef-and$bytes[1]-eq0xbb-and$bytes[2]-eq0xbf){throw 'Transition event ledger must not contain a UTF-8 BOM.'}
    if($bytes-contains0){throw 'Transition event ledger contains NUL bytes.'}
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)}catch{throw 'Transition event ledger is not strict UTF-8.'}
    $lines=$text-split"`n",0
    $events=@()
    $eventSchema=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas\iteration-event.schema.json'
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
        if(-not(Test-Json -Json ($event|ConvertTo-Json -Depth 16 -Compress) -SchemaFile $eventSchema)){
            throw "Transition event ledger entry fails the exact iteration-event contract at line $($index+1)."
        }
        if(-not$seen.Add([string]$event.event_id)){throw "Transition event ledger repeats event identity '$([string]$event.event_id)'."}
        if([int]$event.sequence-ne$events.Count+1){throw "Transition event ledger sequence is not contiguous at line $($index+1)."}
        $timestamp=ConvertFrom-MorphospaceInvariantTimestamp ([string]$event.timestamp)
        if($null-ne$previousTimestamp-and$timestamp-lt$previousTimestamp){throw "Transition event ledger chronology regresses at line $($index+1)."}
        $previousTimestamp=$timestamp
        $events+=,$event
    }
    @($events)
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
    $events=@(Read-MorphospaceLedgerEvents $EventsPath)
    $matchingIndexes=@()
    for($index=0;$index-lt$events.Count;$index++){
        if([string]$events[$index].event_id-ceq[string]$Intent.event.event_id){$matchingIndexes+=,$index}
    }
    if($matchingIndexes.Count-gt1){throw 'Transition event is duplicated.'}
    if($matchingIndexes.Count-eq0){
        if($RequirePresent){throw 'Transition event is absent.'}
        $tail=if($events.Count){[string]$events[-1].event_id}else{$null}
        if([string]$tail-cne[string]$Intent.expected.event_tail_id){throw 'Transition event predecessor differs from its intent.'}
        if([int]$Intent.event.sequence-ne$events.Count+1){throw 'Transition event sequence does not identify the next ledger position.'}
        return $false
    }
    $eventIndex=[int]$matchingIndexes[0]
    if((Get-MorphospaceLedgerDocumentHash $events[$eventIndex])-cne(Get-MorphospaceLedgerDocumentHash $Intent.event)){
        throw 'Transition event differs from its intent.'
    }
    if(-not$AllowHistorical-and$eventIndex-ne$events.Count-1){throw 'Transition event is not the ledger tail.'}
    $predecessor=if($eventIndex-gt0){[string]$events[$eventIndex-1].event_id}else{$null}
    if([string]$predecessor-cne[string]$Intent.expected.event_tail_id){throw 'Transition event predecessor differs from its intent.'}
    if([int]$Intent.event.sequence-ne$eventIndex+1){throw 'Transition event sequence does not match its ledger position.'}
    return $true
}
function Assert-MorphospaceLedgerIntent {
    param([object]$Intent,[string]$TransactionId)
    Assert-MorphospaceExactPropertySet $Intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') @() 'Transition ledger intent'
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or[string]$Intent.status-cne'prepared'-or[string]$Intent.transaction_id-cne$TransactionId){throw 'Transition ledger intent identity/status is invalid.'}
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$Intent.created_at))
    foreach($referenceName in @('state','unit','events')){
        Assert-MorphospaceExactPropertySet $Intent.$referenceName @('path') @() "Transition ledger intent $referenceName reference"
        [void](ConvertTo-MorphospaceProtocolRelativePath ([string]$Intent.$referenceName.path))
    }
    Assert-MorphospaceExactPropertySet $Intent.pre @('state','unit') @() 'Transition ledger intent pre'
    Assert-MorphospaceExactPropertySet $Intent.target @('state','unit') @() 'Transition ledger intent target'
    Assert-MorphospaceExactPropertySet $Intent.expected @('state_sha256','unit_sha256','event_tail_id') @() 'Transition ledger intent expected'
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
    [void](ConvertFrom-MorphospaceInvariantTimestamp ([string]$Intent.event.timestamp))
    foreach($artifact in @($Intent.artifacts)){
        Assert-MorphospaceExactPropertySet $artifact @('path','sha256','bytes_base64') @() 'Transition ledger intent artifact'
        [void](ConvertTo-MorphospaceProtocolRelativePath ([string]$artifact.path))
        try{$bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64)}catch{throw 'Transition ledger intent artifact payload is not valid base64.'}
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if($hash-cne[string]$artifact.sha256){throw 'Transition ledger intent artifact payload hash is inconsistent.'}
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
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))
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
    }
}
function Complete-MorphospaceTransitionLedger {
    param([string]$WorkspaceRoot,[string]$TransactionId,[switch]$Repair,[ValidateSet('none','after-intent','after-projection','after-event')][string]$FaultAfter='none')
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$intentRelative=Get-MorphospaceLedgerPath $workspace $TransactionId intent;$completionRelative=Get-MorphospaceLedgerPath $workspace $TransactionId completion
    $completionAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $completionRelative
    $lock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $workspace
    try {
        $intentAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $intentRelative -RequireLeaf
        $intent=Read-MorphospaceLedgerJson $intentAbsolute
        Assert-MorphospaceLedgerIntent $intent $TransactionId
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
        [void](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intent)
        if($intent.PSObject.Properties.Name-contains'expected'){
            $allowedStateHashes=@([string]$intent.expected.state_sha256,[string]$intent.target.state.sha256)
            $allowedUnitHashes=@([string]$intent.expected.unit_sha256,[string]$intent.target.unit.sha256)
            if($allowedStateHashes-notcontains$currentStateHash){throw "Transition $TransactionId failed expected pre-state CAS."}
            if($allowedUnitHashes-notcontains$currentUnitHash){throw "Transition $TransactionId failed expected pre-unit CAS."}
        }
        foreach($projection in @('state','unit')){
            $current=Read-MorphospaceProtocolJson -Path (Resolve-MorphospaceWorkspacePath $workspace ([string]$intent.$projection.path) -RequireLeaf)
            $actual=Get-MorphospaceLedgerDocumentHash $current
            if($actual-ne[string]$intent.target.$projection.sha256){
                if($actual-ne[string]$intent.pre.$projection.sha256){throw "Transition $TransactionId has an unauthorized $projection projection."}
                Write-MorphospaceLedgerProjection $workspace ([string]$intent.$projection.path) $intent.target.$projection.document
            }
        }
        if($FaultAfter-eq'after-projection'){throw 'Injected interruption after projections.'}
        $eventPresent=[bool](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intent)
        if(-not$eventPresent){
            Add-MorphospaceLedgerEvent $eventsAbsolute $intent.event
        }
        [void](Assert-MorphospaceLedgerEventPlacement $eventsAbsolute $intent)
        if($FaultAfter-eq'after-event'){throw 'Injected interruption after event append.'}
        foreach($artifact in @($intent.artifacts)){
            $target=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath ([string]$artifact.path)
            if([IO.File]::Exists($target)){
                if((Get-MorphospaceFileSha256 $target)-cne[string]$artifact.sha256){throw "Transition artifact target is occupied: $($artifact.path)"}
            }else{
                $bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64)
                $actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                if($actual-cne[string]$artifact.sha256){throw "Transition artifact payload hash mismatch: $($artifact.path)"}
                $parent=[IO.Path]::GetDirectoryName($target);[IO.Directory]::CreateDirectory($parent)|Out-Null
                $temporary=Join-Path $parent (".$([IO.Path]::GetFileName($target)).$TransactionId.tmp")
                try{[IO.File]::WriteAllBytes($temporary,$bytes);[IO.File]::Move($temporary,$target,$false)}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
            }
        }
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
        [ValidateSet('none','after-intent','after-projection','after-event')][string]$FaultAfter='none',
        [string]$ExpectedPreStateSha256 = '',
        [string]$ExpectedPreUnitSha256 = '',
        [string]$ExpectedStateSha256 = '',
        [string]$ExpectedUnitSha256 = '',
        [AllowNull()][string]$ExpectedEventTailId,
        [object[]]$Artifacts=@()
    )
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$lock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $workspace
    try {
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
        $eventsAbsolute=Resolve-MorphospaceWorkspacePath $workspace $EventsPath -RequireLeaf
        if($PSBoundParameters.ContainsKey('ExpectedEventTailId')-and[string]$ExpectedEventTailId-cne[string](Get-MorphospaceLedgerEventTail $eventsAbsolute)){throw "Transition $TransactionId failed expected event-tail CAS."}
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
        $intent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.transition_ledger_intent.v1';transaction_id=$TransactionId;created_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');state=[pscustomobject]@{path=(ConvertTo-MorphospaceProtocolRelativePath -Path $StatePath)};unit=[pscustomobject]@{path=(ConvertTo-MorphospaceProtocolRelativePath -Path $UnitPath)};events=[pscustomobject]@{path=(ConvertTo-MorphospaceProtocolRelativePath -Path $EventsPath)};pre=[pscustomobject]@{state=[pscustomobject]@{sha256=$preStateSha256};unit=[pscustomobject]@{sha256=$preUnitSha256}};target=[pscustomobject]@{state=[pscustomobject]@{sha256=(Get-MorphospaceLedgerDocumentHash $TargetState);document=$TargetState};unit=[pscustomobject]@{sha256=(Get-MorphospaceLedgerDocumentHash $TargetUnit);document=$TargetUnit}};expected=[pscustomobject]@{state_sha256=$preStateSha256;unit_sha256=$preUnitSha256;event_tail_id=$(if($PSBoundParameters.ContainsKey('ExpectedEventTailId')){$ExpectedEventTailId}else{Get-MorphospaceLedgerEventTail $eventsAbsolute})};artifacts=@($ownedArtifacts);event=$Event;status='prepared'}
        Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath $intentRelative -Value $intent -NoOverwrite
        if($FaultAfter-eq'after-intent'){throw 'Injected interruption after intent publication.'}
    } finally {Exit-MorphospaceWorkspaceMutex $lock}
    Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $TransactionId -FaultAfter $FaultAfter
}
Export-ModuleMember -Function Start-MorphospaceTransitionLedger,Complete-MorphospaceTransitionLedger
