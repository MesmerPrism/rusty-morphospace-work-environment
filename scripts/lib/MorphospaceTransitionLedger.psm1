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
function Test-MorphospaceLedgerEventPresent { param([string]$EventsPath,[string]$EventId)
    @((Get-Content -LiteralPath $EventsPath | Where-Object { $_.Length -gt 0 } | ForEach-Object { $_|ConvertFrom-Json }) | Where-Object { [string]$_.event_id -eq $EventId })
}
function Get-MorphospaceLedgerEventTail { param([string]$EventsPath)
    $events=@(Get-Content -LiteralPath $EventsPath | Where-Object {$_.Length-gt 0} | ForEach-Object {$_|ConvertFrom-Json})
    if($events.Count-eq0){return $null}
    return [string]$events[-1].event_id
}
function Complete-MorphospaceTransitionLedger {
    param([string]$WorkspaceRoot,[string]$TransactionId,[switch]$Repair,[ValidateSet('none','after-intent','after-projection','after-event')][string]$FaultAfter='none')
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$intentRelative=Get-MorphospaceLedgerPath $workspace $TransactionId intent;$completionRelative=Get-MorphospaceLedgerPath $workspace $TransactionId completion
    $completionAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $completionRelative
    if([IO.File]::Exists($completionAbsolute)){return [pscustomobject]@{transaction_id=$TransactionId;status='already-committed'}}
    $intentAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $intentRelative -RequireLeaf;$intent=Read-MorphospaceLedgerJson $intentAbsolute
    if([string]$intent.schema-ne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or[string]$intent.status-ne'prepared'-or[string]$intent.transaction_id-ne$TransactionId){throw 'Transition ledger intent identity/status is invalid.'}
    $lock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $workspace
    try {
        $stateAbsolute=Resolve-MorphospaceWorkspacePath $workspace ([string]$intent.state.path) -RequireLeaf
        $unitAbsolute=Resolve-MorphospaceWorkspacePath $workspace ([string]$intent.unit.path) -RequireLeaf
        $eventsAbsolute=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath ([string]$intent.events.path) -RequireLeaf
        $currentState=Read-MorphospaceProtocolJson -Path $stateAbsolute
        $currentUnit=Read-MorphospaceProtocolJson -Path $unitAbsolute
        $currentStateHash=Get-MorphospaceLedgerDocumentHash $currentState
        $currentUnitHash=Get-MorphospaceLedgerDocumentHash $currentUnit
        $eventAlready=@(Test-MorphospaceLedgerEventPresent $eventsAbsolute $intent.event.event_id)
        if($eventAlready.Count-gt1){throw 'Transition event is duplicated.'}
        if($intent.PSObject.Properties.Name-contains'expected'){
            $allowedStateHashes=@([string]$intent.expected.state_sha256,[string]$intent.target.state.sha256)
            $allowedUnitHashes=@([string]$intent.expected.unit_sha256,[string]$intent.target.unit.sha256)
            if($allowedStateHashes-notcontains$currentStateHash){throw "Transition $TransactionId failed expected pre-state CAS."}
            if($allowedUnitHashes-notcontains$currentUnitHash){throw "Transition $TransactionId failed expected pre-unit CAS."}
            if($eventAlready.Count-eq0-and[string]$intent.expected.event_tail_id-cne[string](Get-MorphospaceLedgerEventTail $eventsAbsolute)){throw "Transition $TransactionId failed expected event-tail CAS."}
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
        $existing=@(Test-MorphospaceLedgerEventPresent $eventsAbsolute $intent.event.event_id)
        if($existing.Count-eq0){Add-MorphospaceLedgerEvent $eventsAbsolute $intent.event}elseif($existing.Count-ne1){throw 'Transition event is duplicated.'}
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
            $source=[IO.Path]::GetFullPath([string]$artifact.source_path)
            if(-not[IO.File]::Exists($source)){throw "Transition artifact input is missing: $source"}
            $bytes=[IO.File]::ReadAllBytes($source);$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
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
