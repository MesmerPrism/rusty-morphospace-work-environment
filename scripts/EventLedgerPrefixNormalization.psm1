$ErrorActionPreference = 'Stop'

$script:TransitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

$script:NormalizationMaximumLedgerBytes = 1048576
$script:NormalizationPrefix = [byte[]]@(0x0d,0x0a)

function Test-MorphospaceTransitionLedgerBytes {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    & $script:TransitionLedgerModule {
        param([byte[]]$ProvidedBytes)
        $events=@(Read-MorphospaceLedgerEvents -EventsPath 'provided transition event ledger bytes' -ProvidedBytes $ProvidedBytes)
        [pscustomobject]@{
            length=[int64]$ProvidedBytes.LongLength
            sha256=Get-MorphospaceLedgerByteHash $ProvidedBytes
            events=$events
            tail_id=$(if($events.Count){[string]$events[-1].event_id}else{$null})
        }
    } $Bytes
}

function Get-MorphospaceTransitionLedgerEventLineBytes {
    param([Parameter(Mandatory=$true)][object]$Event)
    & $script:TransitionLedgerModule {param($Value) Get-MorphospaceLedgerEventLineBytes $Value} $Event
}

function Get-MorphospaceNormalizationSchemaPath {
    param([Parameter(Mandatory=$true)][string]$Name)
    Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\$Name"
}

function Get-MorphospaceNormalizationSha256 {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-MorphospaceNormalizationJsonBytes {
    param([Parameter(Mandatory=$true)][object]$Document)
    [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Document)+"`n")
}

function Copy-MorphospaceNormalizationDocument {
    param([Parameter(Mandatory=$true)][object]$Document,[string]$Context='normalization document')
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Document))) -Context $Context
}

function Test-MorphospaceNormalizationSchema {
    param([Parameter(Mandatory=$true)][object]$Document,[Parameter(Mandatory=$true)][string]$Schema,[Parameter(Mandatory=$true)][string]$Context)
    if(-not(Test-Json -Json ($Document|ConvertTo-Json -Depth 64 -Compress) -SchemaFile (Get-MorphospaceNormalizationSchemaPath $Schema))){
        throw "$Context fails its exact schema."
    }
}

function Invoke-MorphospaceNormalizationGit {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string[]]$Arguments)
    $prior=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try{$output=@(& git -C $Path @Arguments 2>&1);$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$prior}
    if($exit-ne0){throw "Event-ledger normalization Git observation failed: git $($Arguments -join ' ')"}
    return @($output|ForEach-Object{[string]$_})
}

function Get-MorphospaceNormalizationGitObservation {
    param([Parameter(Mandatory=$true)][string]$Workspace)
    $rootText=((Invoke-MorphospaceNormalizationGit $Workspace @('rev-parse','--show-toplevel'))-join"`n").Trim()
    $head=((Invoke-MorphospaceNormalizationGit $Workspace @('rev-parse','HEAD'))-join"`n").Trim()
    $branchLines=Invoke-MorphospaceNormalizationGit $Workspace @('symbolic-ref','--quiet','--short','HEAD')
    $branch=if($branchLines.Count){($branchLines-join"`n").Trim()}else{$null}
    $root=[IO.Path]::GetFullPath($rootText)
    $workspacePath=[IO.Path]::GetFullPath($Workspace)
    $prefix=$root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not$workspacePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Morphospace workspace is not below its observed Git root.'}
    $workspaceRelative=$workspacePath.Substring($prefix.Length).Replace('\','/').TrimEnd('/')
    $status=@(Invoke-MorphospaceNormalizationGit $root @('status','--porcelain=v1','--untracked-files=all'))
    [pscustomobject]@{root=$root;head=$head;branch=$branch;workspace_relative=$workspaceRelative;status=@($status)}
}

function Get-MorphospaceNormalizationDirtyPath {
    param([Parameter(Mandatory=$true)][string]$Line)
    if($Line.Length-lt4){throw "Malformed Git status entry during event-ledger normalization: $Line"}
    $path=$Line.Substring(3)
    if($path.Contains(' -> ')){$path=($path-split' -> ',2)[1]}
    $path.Trim('"').Replace('\','/')
}

function Assert-MorphospaceNormalizationGitClean {
    param([Parameter(Mandatory=$true)][object]$Observation)
    if(@($Observation.status).Count){throw 'Event-ledger prefix normalization requires an initially clean Git worktree.'}
}

function Assert-MorphospaceNormalizationOwnedDirt {
    param([Parameter(Mandatory=$true)][object]$Observation,[Parameter(Mandatory=$true)][object]$Paths)
    $allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($relative in @($Paths.state,$Paths.events,$Paths.receipt,$Paths.intent,$Paths.completion,$Paths.stage,$Paths.backup)){
        $joined=if($Observation.workspace_relative){"$($Observation.workspace_relative)/$relative"}else{$relative}
        [void]$allowed.Add($joined.Replace('\','/'))
    }
    foreach($line in @($Observation.status)){
        $dirty=Get-MorphospaceNormalizationDirtyPath ([string]$line)
        if(-not$allowed.Contains($dirty)){throw "Event-ledger normalization observed unrelated Git dirt: $dirty"}
    }
}

function Get-MorphospaceNormalizationPaths {
    param([Parameter(Mandatory=$true)][string]$NormalizationId)
    if($NormalizationId-cnotmatch'^[a-z0-9][a-z0-9-]{1,111}$'){throw 'NormalizationId must be a canonical 2-through-112-character workflow ID.'}
    $transactionId="$NormalizationId-normalization"
    [pscustomobject][ordered]@{
        project='project.spec.json'
        state='workspace.state.json'
        unit=$null
        events='iteration-events.jsonl'
        receipt="receipts/$NormalizationId.json"
        intent="receipts/transactions/$transactionId.intent.json"
        completion="receipts/transactions/$transactionId.completion.json"
        stage="iteration-events.jsonl.$transactionId.pending"
        backup="iteration-events.jsonl.$transactionId.before"
        transaction_id=$transactionId
    }
}

function Get-MorphospaceNormalizationAbsolute {
    param([string]$Workspace,[string]$Relative,[switch]$RequireLeaf)
    Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath $Relative -RequireLeaf:$RequireLeaf
}

function Assert-MorphospaceNormalizationExpectedHash {
    param([string]$Name,[string]$Expected,[string]$Actual)
    if($Expected-cnotmatch'^[0-9a-f]{64}$'){throw "Expected $Name SHA-256 is not canonical lowercase hex."}
    if($Expected-cne$Actual){throw "Event-ledger prefix normalization failed expected $Name SHA-256 CAS."}
}

function Get-MorphospaceNormalizationCandidate {
    param(
        [Parameter(Mandatory=$true)][string]$Workspace,
        [Parameter(Mandatory=$true)][string]$NormalizationId,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][string]$ExpectedRepositoryHead,
        [Parameter(Mandatory=$true)][string]$ExpectedProjectSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedStateSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedUnitSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedEventsSha256,
        [Parameter(Mandatory=$true)][int64]$ExpectedEventsLength,
        [Parameter(Mandatory=$true)][string]$ExpectedEventTailId,
        [Parameter(Mandatory=$true)][string]$Timestamp
    )
    $paths=Get-MorphospaceNormalizationPaths $NormalizationId
    $paths.unit="iteration-units/$UnitId.json"
    $git=Get-MorphospaceNormalizationGitObservation $Workspace
    if($ExpectedRepositoryHead-cnotmatch'^[0-9a-f]{40}$'-or$git.head-cne$ExpectedRepositoryHead){throw 'Event-ledger prefix normalization failed expected repository-HEAD CAS.'}

    $projectPath=Get-MorphospaceNormalizationAbsolute $Workspace $paths.project -RequireLeaf
    $statePath=Get-MorphospaceNormalizationAbsolute $Workspace $paths.state -RequireLeaf
    $unitPath=Get-MorphospaceNormalizationAbsolute $Workspace $paths.unit -RequireLeaf
    $eventsPath=Get-MorphospaceNormalizationAbsolute $Workspace $paths.events -RequireLeaf
    $project=Read-MorphospaceProtocolJson $projectPath
    $state=Read-MorphospaceProtocolJson $statePath
    $unit=Read-MorphospaceProtocolJson $unitPath
    Test-MorphospaceNormalizationSchema $project 'project-spec-v2.schema.json' 'Event-ledger normalization project specification'
    Test-MorphospaceNormalizationSchema $state 'workspace-state-v2.schema.json' 'Event-ledger normalization workspace state'
    Test-MorphospaceNormalizationSchema $unit 'iteration-unit.schema.json' 'Event-ledger normalization current unit'
    if([string]$project.schema-cne'rusty.morphospace.workflow.project_spec.v2'-or[string]$state.schema-cne'rusty.morphospace.workflow.workspace_state.v2'){
        throw 'Event-ledger prefix normalization is available only to protocol-v2 project workspaces.'
    }
    if([string]$project.project_id-cne[string]$state.project_id-or[string]$project.project_id-cne[string]$unit.project_id){throw 'Event-ledger normalization project identities disagree.'}
    if([string]$state.current_unit-cne$UnitId-or[string]$unit.unit_id-cne$UnitId){throw 'Event-ledger normalization does not bind the exact current unit.'}

    $projectFileHash=Get-MorphospaceFileSha256 $projectPath
    $stateFileHash=Get-MorphospaceFileSha256 $statePath
    $unitFileHash=Get-MorphospaceFileSha256 $unitPath
    Assert-MorphospaceNormalizationExpectedHash 'project file' $ExpectedProjectSha256 $projectFileHash
    Assert-MorphospaceNormalizationExpectedHash 'state file' $ExpectedStateSha256 $stateFileHash
    Assert-MorphospaceNormalizationExpectedHash 'unit file' $ExpectedUnitSha256 $unitFileHash

    $before=[IO.File]::ReadAllBytes($eventsPath)
    if($before.LongLength-gt$script:NormalizationMaximumLedgerBytes){throw 'Event-ledger prefix normalization exceeds its one-MiB incident bound.'}
    if($ExpectedEventsLength-lt0-or$before.LongLength-ne$ExpectedEventsLength){throw 'Event-ledger prefix normalization failed expected event-ledger length CAS.'}
    Assert-MorphospaceNormalizationExpectedHash 'event-ledger' $ExpectedEventsSha256 (Get-MorphospaceNormalizationSha256 $before)
    if($before.Length-lt3-or$before[0]-ne0x0d-or$before[1]-ne0x0a){throw 'Event-ledger prefix normalization accepts only one exact leading CRLF record.'}
    $normalized=[byte[]]::new($before.Length-2)
    [Array]::Copy($before,2,$normalized,0,$normalized.Length)
    $snapshot=Test-MorphospaceTransitionLedgerBytes -Bytes $normalized
    if($snapshot.events.Count-lt1){throw 'Event-ledger prefix normalization requires at least one preserved event.'}
    if([string]$snapshot.tail_id-cne$ExpectedEventTailId-or[string]$state.last_event_id-cne$ExpectedEventTailId){throw 'Event-ledger prefix normalization failed expected event-tail CAS.'}
    foreach($priorEvent in @($snapshot.events)){
        if([string]$priorEvent.project_id-cne[string]$project.project_id){throw 'Event-ledger normalization found an event with the wrong project identity.'}
    }

    $timestampValue=Test-MorphospaceStrictUtcTimestamp $Timestamp
    $tailTimestamp=ConvertFrom-MorphospaceInvariantTimestamp ([string]$snapshot.events[-1].timestamp)
    if($timestampValue-lt$tailTimestamp){throw 'Event-ledger normalization timestamp precedes the preserved event tail.'}
    $event=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1'
        event_id=$NormalizationId
        sequence=[int]$snapshot.events[-1].sequence+1
        timestamp=$Timestamp
        project_id=[string]$project.project_id
        unit_id=$UnitId
        event_type='state-transition'
        summary='Removed one unauthorized leading CRLF record through the workflow-owned normalization transaction; prior event records and current-unit bytes remained unchanged.'
        receipts=@($paths.receipt)
    }
    $event=Copy-MorphospaceNormalizationDocument $event 'event-ledger normalization canonical event copy'
    Test-MorphospaceNormalizationSchema $event 'iteration-event.schema.json' 'Event-ledger normalization event'
    $eventLine=Get-MorphospaceTransitionLedgerEventLineBytes $event
    $after=[byte[]]::new($normalized.Length+$eventLine.Length)
    [Array]::Copy($normalized,0,$after,0,$normalized.Length)
    [Array]::Copy($eventLine,0,$after,$normalized.Length,$eventLine.Length)
    [void](Test-MorphospaceTransitionLedgerBytes -Bytes $after)

    $preState=Copy-MorphospaceNormalizationDocument $state 'event-ledger normalization pre-state copy'
    $targetState=Copy-MorphospaceNormalizationDocument $state 'event-ledger normalization target-state copy'
    $targetState.last_event_id=$NormalizationId
    $targetStateBytes=Get-MorphospaceNormalizationJsonBytes $targetState
    $receipt=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.event_ledger_prefix_normalization.v1'
        normalization_id=$NormalizationId
        created_at=$Timestamp
        project_id=[string]$project.project_id
        unit_id=$UnitId
        repository=[pscustomobject][ordered]@{head=$git.head;branch=$git.branch}
        ledger=[pscustomobject][ordered]@{
            path=$paths.events
            before_sha256=Get-MorphospaceNormalizationSha256 $before
            before_length=[int64]$before.LongLength
            removed_prefix_base64='DQo='
            normalized_prefix_sha256=Get-MorphospaceNormalizationSha256 $normalized
            normalized_prefix_length=[int64]$normalized.LongLength
            after_sha256=Get-MorphospaceNormalizationSha256 $after
            after_length=[int64]$after.LongLength
            preserved_event_count=[int]$snapshot.events.Count
            prior_tail_event_id=[string]$snapshot.tail_id
            prior_tail_sequence=[int]$snapshot.events[-1].sequence
        }
        state=[pscustomobject][ordered]@{
            path=$paths.state
            before_file_sha256=$stateFileHash
            before_document_sha256=Get-MorphospaceCanonicalJsonSha256 $state
            after_file_sha256=Get-MorphospaceNormalizationSha256 $targetStateBytes
            after_document_sha256=Get-MorphospaceCanonicalJsonSha256 $targetState
            changed_fields=@('last_event_id')
        }
        unit=[pscustomobject][ordered]@{
            path=$paths.unit
            file_sha256=$unitFileHash
            document_sha256=Get-MorphospaceCanonicalJsonSha256 $unit
            status=[string]$unit.status
        }
        event=[pscustomobject][ordered]@{event_id=$NormalizationId;sequence=[int]$event.sequence;receipt_path=$paths.receipt}
        guarantees=[pscustomobject][ordered]@{
            removed_exactly_one_leading_crlf_record=$true
            prior_event_bytes_unchanged=$true
            current_unit_bytes_unchanged=$true
            state_change_limited_to_last_event_id=$true
            git_mutation_performed=$false
            device_work=$false
        }
        status='normalized'
    }
    Test-MorphospaceNormalizationSchema $receipt 'event-ledger-prefix-normalization-v1.schema.json' 'Event-ledger normalization receipt'
    $receiptBytes=Get-MorphospaceNormalizationJsonBytes $receipt
    [pscustomobject]@{
        paths=$paths;git=$git;project=$project;state=$state;unit=$unit
        before=$before;normalized=$normalized;after=$after;event=$event
        pre_state=$preState;target_state=$targetState;target_state_bytes=$targetStateBytes
        receipt=$receipt;receipt_bytes=$receiptBytes
        project_file_sha256=$projectFileHash;state_file_sha256=$stateFileHash;unit_file_sha256=$unitFileHash
    }
}

function New-MorphospaceNormalizationIntent {
    param([Parameter(Mandatory=$true)][object]$Candidate)
    $c=$Candidate
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.event_ledger_prefix_normalization_intent.v1'
        transaction_id=$c.paths.transaction_id
        normalization_id=[string]$c.event.event_id
        created_at=[string]$c.event.timestamp
        paths=[pscustomobject][ordered]@{
            project=$c.paths.project;state=$c.paths.state;unit=$c.paths.unit;events=$c.paths.events
            receipt=$c.paths.receipt;completion=$c.paths.completion
        }
        repository=[pscustomobject][ordered]@{head=$c.git.head;branch=$c.git.branch}
        project=[pscustomobject][ordered]@{
            project_id=[string]$c.project.project_id
            file_sha256=$c.project_file_sha256
            document_sha256=Get-MorphospaceCanonicalJsonSha256 $c.project
        }
        pre=[pscustomobject][ordered]@{
            state_file_sha256=$c.state_file_sha256
            state_document_sha256=Get-MorphospaceCanonicalJsonSha256 $c.state
            unit_file_sha256=$c.unit_file_sha256
            unit_document_sha256=Get-MorphospaceCanonicalJsonSha256 $c.unit
            events_sha256=Get-MorphospaceNormalizationSha256 $c.before
            events_length=[int64]$c.before.LongLength
            event_tail_id=[string]$c.receipt.ledger.prior_tail_event_id
            event_tail_sequence=[int]$c.receipt.ledger.prior_tail_sequence
        }
        target=[pscustomobject][ordered]@{
            state_file_sha256=[string]$c.receipt.state.after_file_sha256
            state_document_sha256=[string]$c.receipt.state.after_document_sha256
            unit_file_sha256=$c.unit_file_sha256
            unit_document_sha256=Get-MorphospaceCanonicalJsonSha256 $c.unit
            normalized_prefix_sha256=[string]$c.receipt.ledger.normalized_prefix_sha256
            normalized_prefix_length=[int64]$c.receipt.ledger.normalized_prefix_length
            events_sha256=[string]$c.receipt.ledger.after_sha256
            events_length=[int64]$c.receipt.ledger.after_length
        }
        pre_events_base64=[Convert]::ToBase64String($c.before)
        pre_state=$c.pre_state
        target_state=$c.target_state
        event=$c.event
        receipt=[pscustomobject][ordered]@{
            path=$c.paths.receipt
            sha256=Get-MorphospaceNormalizationSha256 $c.receipt_bytes
            document=$c.receipt
        }
        status='prepared'
    }
}

function Assert-MorphospaceNormalizationIntent {
    param([Parameter(Mandatory=$true)][object]$Intent,[Parameter(Mandatory=$true)][string]$NormalizationId)
    Test-MorphospaceNormalizationSchema $Intent 'event-ledger-prefix-normalization-intent-v1.schema.json' 'Event-ledger normalization intent'
    Test-MorphospaceNormalizationSchema $Intent.pre_state 'workspace-state-v2.schema.json' 'Event-ledger normalization intent pre-state'
    Test-MorphospaceNormalizationSchema $Intent.target_state 'workspace-state-v2.schema.json' 'Event-ledger normalization intent target-state'
    Test-MorphospaceNormalizationSchema $Intent.event 'iteration-event.schema.json' 'Event-ledger normalization intent event'
    Test-MorphospaceNormalizationSchema $Intent.receipt.document 'event-ledger-prefix-normalization-v1.schema.json' 'Event-ledger normalization intent receipt'
    $paths=Get-MorphospaceNormalizationPaths $NormalizationId
    $paths.unit=[string]$Intent.paths.unit
    if([string]$Intent.normalization_id-cne$NormalizationId-or[string]$Intent.transaction_id-cne$paths.transaction_id-or
       [string]$Intent.paths.project-cne$paths.project-or[string]$Intent.paths.state-cne$paths.state-or
       [string]$Intent.paths.events-cne$paths.events-or[string]$Intent.paths.receipt-cne$paths.receipt-or
       [string]$Intent.paths.completion-cne$paths.completion-or[string]$Intent.event.event_id-cne$NormalizationId){
        throw 'Event-ledger normalization intent identity or path binding is invalid.'
    }
    try{$before=[Convert]::FromBase64String([string]$Intent.pre_events_base64)}catch{throw 'Event-ledger normalization intent preimage is not valid base64.'}
    if([Convert]::ToBase64String($before)-cne[string]$Intent.pre_events_base64){throw 'Event-ledger normalization intent preimage is not canonical base64.'}
    if($before.Length-ne[int64]$Intent.pre.events_length-or(Get-MorphospaceNormalizationSha256 $before)-cne[string]$Intent.pre.events_sha256-or
       $before.Length-lt3-or$before[0]-ne0x0d-or$before[1]-ne0x0a){throw 'Event-ledger normalization intent preimage binding is invalid.'}
    $normalized=[byte[]]::new($before.Length-2);[Array]::Copy($before,2,$normalized,0,$normalized.Length)
    $prior=Test-MorphospaceTransitionLedgerBytes $normalized
    if($prior.events.Count-lt1-or[string]$prior.tail_id-cne[string]$Intent.pre.event_tail_id-or
       [int]$prior.events[-1].sequence-ne[int]$Intent.pre.event_tail_sequence-or
       (Get-MorphospaceNormalizationSha256 $normalized)-cne[string]$Intent.target.normalized_prefix_sha256-or
       $normalized.Length-ne[int64]$Intent.target.normalized_prefix_length){throw 'Event-ledger normalization intent preserved-prefix binding is invalid.'}
    foreach($priorEvent in @($prior.events)){if([string]$priorEvent.project_id-cne[string]$Intent.project.project_id){throw 'Event-ledger normalization intent contains a wrong-project preserved event.'}}
    if([int]$Intent.event.sequence-ne[int]$Intent.pre.event_tail_sequence+1-or[string]$Intent.event.project_id-cne[string]$Intent.project.project_id-or
       [string]$Intent.event.unit_id-cne([IO.Path]::GetFileNameWithoutExtension([string]$Intent.paths.unit))-or
       [string]$Intent.event.event_type-cne'state-transition'-or@($Intent.event.receipts).Count-ne1-or[string]$Intent.event.receipts[0]-cne[string]$Intent.paths.receipt){
        throw 'Event-ledger normalization intent event binding is invalid.'
    }
    $line=Get-MorphospaceTransitionLedgerEventLineBytes $Intent.event
    $after=[byte[]]::new($normalized.Length+$line.Length);[Array]::Copy($normalized,0,$after,0,$normalized.Length);[Array]::Copy($line,0,$after,$normalized.Length,$line.Length)
    [void](Test-MorphospaceTransitionLedgerBytes $after)
    if($after.Length-ne[int64]$Intent.target.events_length-or(Get-MorphospaceNormalizationSha256 $after)-cne[string]$Intent.target.events_sha256){throw 'Event-ledger normalization intent target ledger binding is invalid.'}
    if((Get-MorphospaceCanonicalJsonSha256 $Intent.pre_state)-cne[string]$Intent.pre.state_document_sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $Intent.target_state)-cne[string]$Intent.target.state_document_sha256){throw 'Event-ledger normalization intent state hash binding is invalid.'}
    $expectedTarget=Copy-MorphospaceNormalizationDocument $Intent.pre_state 'event-ledger normalization intent state comparison'
    $expectedTarget.last_event_id=$NormalizationId
    if((Get-MorphospaceCanonicalJsonSha256 $expectedTarget)-cne(Get-MorphospaceCanonicalJsonSha256 $Intent.target_state)){throw 'Event-ledger normalization intent changes state beyond last_event_id.'}
    if([string]$Intent.pre_state.current_unit-cne([IO.Path]::GetFileNameWithoutExtension([string]$Intent.paths.unit))-or
       [string]$Intent.pre_state.project_id-cne[string]$Intent.project.project_id-or[string]$Intent.pre_state.last_event_id-cne[string]$Intent.pre.event_tail_id){
        throw 'Event-ledger normalization intent pre-state identity or tail binding is invalid.'
    }
    $targetStateBytes=Get-MorphospaceNormalizationJsonBytes $Intent.target_state
    if((Get-MorphospaceNormalizationSha256 $targetStateBytes)-cne[string]$Intent.target.state_file_sha256){throw 'Event-ledger normalization intent target state file hash is invalid.'}
    $receiptBytes=Get-MorphospaceNormalizationJsonBytes $Intent.receipt.document
    if((Get-MorphospaceNormalizationSha256 $receiptBytes)-cne[string]$Intent.receipt.sha256){throw 'Event-ledger normalization intent receipt hash is invalid.'}
    $r=$Intent.receipt.document
    if([string]$r.normalization_id-cne$NormalizationId-or[string]$r.project_id-cne[string]$Intent.project.project_id-or
       [string]$r.unit_id-cne([IO.Path]::GetFileNameWithoutExtension([string]$Intent.paths.unit))-or
       [string]$r.ledger.before_sha256-cne[string]$Intent.pre.events_sha256-or[int64]$r.ledger.before_length-ne[int64]$Intent.pre.events_length-or
       [string]$r.ledger.normalized_prefix_sha256-cne[string]$Intent.target.normalized_prefix_sha256-or
       [string]$r.ledger.after_sha256-cne[string]$Intent.target.events_sha256-or
       [string]$r.state.before_file_sha256-cne[string]$Intent.pre.state_file_sha256-or
       [string]$r.state.after_file_sha256-cne[string]$Intent.target.state_file_sha256-or
       [string]$r.unit.file_sha256-cne[string]$Intent.pre.unit_file_sha256-or
       [string]$r.event.event_id-cne$NormalizationId){
        throw 'Event-ledger normalization receipt does not derive from its intent.'
    }
    [pscustomobject]@{paths=$paths;before=$before;normalized=$normalized;after=$after;target_state_bytes=$targetStateBytes;receipt_bytes=$receiptBytes}
}

function Write-MorphospaceNormalizationLedgerTarget {
    param([Parameter(Mandatory=$true)][string]$Workspace,[Parameter(Mandatory=$true)][object]$Intent,[Parameter(Mandatory=$true)][object]$Derived)
    $events=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Intent.paths.events) -RequireLeaf
    $stage=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Derived.paths.stage)
    $backup=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Derived.paths.backup)
    $current=[IO.File]::ReadAllBytes($events);$currentHash=Get-MorphospaceNormalizationSha256 $current
    if($currentHash-cne[string]$Intent.pre.events_sha256-and$currentHash-cne[string]$Intent.target.events_sha256){throw 'Event-ledger normalization found neither the exact before nor exact after ledger state.'}
    foreach($owned in @([pscustomobject]@{path=$stage;hash=[string]$Intent.target.events_sha256},[pscustomobject]@{path=$backup;hash=[string]$Intent.pre.events_sha256})){
        if([IO.Directory]::Exists($owned.path)){throw 'Event-ledger normalization transaction path is occupied by a directory.'}
        if([IO.File]::Exists($owned.path)-and(Get-MorphospaceFileSha256 $owned.path)-cne$owned.hash){throw 'Event-ledger normalization transaction file differs from its exact intended bytes.'}
    }
    if($currentHash-ceq[string]$Intent.pre.events_sha256){
        if([IO.File]::Exists($backup)){throw 'Event-ledger normalization has an ambiguous before-state plus backup.'}
        if(-not[IO.File]::Exists($stage)){
            $stream=[IO.FileStream]::new($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
            try{$stream.Write($Derived.after,0,$Derived.after.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        }
        [IO.File]::Replace($stage,$events,$backup)
        if((Get-MorphospaceFileSha256 $events)-cne[string]$Intent.target.events_sha256-or
           (Get-MorphospaceFileSha256 $backup)-cne[string]$Intent.pre.events_sha256){throw 'Event-ledger normalization atomic replacement readback failed.'}
    }
    if([IO.File]::Exists($stage)){
        if((Get-MorphospaceFileSha256 $stage)-cne[string]$Intent.target.events_sha256){throw 'Event-ledger normalization retained a damaged stage.'}
        [IO.File]::Delete($stage)
    }
    if([IO.File]::Exists($backup)){
        if((Get-MorphospaceFileSha256 $backup)-cne[string]$Intent.pre.events_sha256){throw 'Event-ledger normalization retained a damaged backup.'}
        [IO.File]::Delete($backup)
    }
    $afterBytes=[IO.File]::ReadAllBytes($events)
    if((Get-MorphospaceNormalizationSha256 $afterBytes)-cne[string]$Intent.target.events_sha256){throw 'Event-ledger normalization target ledger changed after replacement.'}
    [void](Test-MorphospaceTransitionLedgerBytes $afterBytes)
}

function Complete-MorphospaceEventLedgerPrefixNormalization {
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [Parameter(Mandatory=$true)][string]$NormalizationId,
        [ValidateSet('none','after-receipt','after-state','after-events')][string]$FaultAfter='none'
    )
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$paths=Get-MorphospaceNormalizationPaths $NormalizationId
    $lock=Enter-MorphospaceWorkspaceMutex $workspace
    try{
        $intentPath=Get-MorphospaceNormalizationAbsolute $workspace $paths.intent -RequireLeaf
        $completionPath=Get-MorphospaceNormalizationAbsolute $workspace $paths.completion
        if([IO.File]::Exists($completionPath)){throw 'Event-ledger prefix normalization rejects replay after committed completion.'}
        $intent=Read-MorphospaceProtocolJson $intentPath
        $derived=Assert-MorphospaceNormalizationIntent $intent $NormalizationId
        $paths=$derived.paths
        $git=Get-MorphospaceNormalizationGitObservation $workspace
        if($git.head-cne[string]$intent.repository.head-or[string]$git.branch-cne[string]$intent.repository.branch){throw 'Event-ledger normalization repository identity drifted after intent publication.'}
        Assert-MorphospaceNormalizationOwnedDirt $git $paths

        $projectPath=Get-MorphospaceNormalizationAbsolute $workspace ([string]$intent.paths.project) -RequireLeaf
        $statePath=Get-MorphospaceNormalizationAbsolute $workspace ([string]$intent.paths.state) -RequireLeaf
        $unitPath=Get-MorphospaceNormalizationAbsolute $workspace ([string]$intent.paths.unit) -RequireLeaf
        if((Get-MorphospaceFileSha256 $projectPath)-cne[string]$intent.project.file_sha256){throw 'Event-ledger normalization project bytes drifted after intent publication.'}
        if((Get-MorphospaceFileSha256 $unitPath)-cne[string]$intent.pre.unit_file_sha256){throw 'Event-ledger normalization current-unit bytes drifted after intent publication.'}
        $unit=Read-MorphospaceProtocolJson $unitPath
        if((Get-MorphospaceCanonicalJsonSha256 $unit)-cne[string]$intent.pre.unit_document_sha256){throw 'Event-ledger normalization current-unit document drifted after intent publication.'}
        $stateFileHash=Get-MorphospaceFileSha256 $statePath
        if($stateFileHash-cne[string]$intent.pre.state_file_sha256-and$stateFileHash-cne[string]$intent.target.state_file_sha256){throw 'Event-ledger normalization found neither the exact before nor exact after state.'}

        $receiptPath=Get-MorphospaceNormalizationAbsolute $workspace ([string]$intent.paths.receipt)
        if([IO.Directory]::Exists($receiptPath)){throw 'Event-ledger normalization receipt path is occupied by a directory.'}
        if([IO.File]::Exists($receiptPath)){
            if((Get-MorphospaceFileSha256 $receiptPath)-cne[string]$intent.receipt.sha256){throw 'Event-ledger normalization receipt differs from its intent.'}
        }else{
            Write-MorphospaceManagedProtocolJsonAtomic $workspace ([string]$intent.paths.receipt) $intent.receipt.document -NoOverwrite
        }
        if($FaultAfter-eq'after-receipt'){throw 'Injected interruption after normalization receipt installation.'}

        if($stateFileHash-ceq[string]$intent.pre.state_file_sha256){
            $currentState=Read-MorphospaceProtocolJson $statePath
            if((Get-MorphospaceCanonicalJsonSha256 $currentState)-cne[string]$intent.pre.state_document_sha256){throw 'Event-ledger normalization pre-state document differs from its intent.'}
            Write-MorphospaceManagedProtocolJsonAtomic $workspace ([string]$intent.paths.state) $intent.target_state
        }
        if((Get-MorphospaceFileSha256 $statePath)-cne[string]$intent.target.state_file_sha256-or
           (Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $statePath))-cne[string]$intent.target.state_document_sha256){
            throw 'Event-ledger normalization target state readback differs from its intent.'
        }
        if($FaultAfter-eq'after-state'){throw 'Injected interruption after normalization state projection.'}

        Write-MorphospaceNormalizationLedgerTarget $workspace $intent $derived
        if($FaultAfter-eq'after-events'){throw 'Injected interruption after normalized event-ledger publication.'}

        $finalGit=Get-MorphospaceNormalizationGitObservation $workspace
        if($finalGit.head-cne[string]$intent.repository.head){throw 'Event-ledger normalization repository HEAD drifted before completion.'}
        Assert-MorphospaceNormalizationOwnedDirt $finalGit $paths
        if((Get-MorphospaceFileSha256 $unitPath)-cne[string]$intent.pre.unit_file_sha256){throw 'Event-ledger normalization current-unit bytes changed before completion.'}
        $completion=[pscustomobject][ordered]@{
            schema='rusty.morphospace.workflow.event_ledger_prefix_normalization_completion.v1'
            transaction_id=[string]$intent.transaction_id
            normalization_id=$NormalizationId
            completed_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            intent=[pscustomobject][ordered]@{
                role='event-ledger-prefix-normalization-intent';path=$paths.intent
                schema=[string]$intent.schema;sha256=Get-MorphospaceFileSha256 $intentPath
            }
            receipt=[pscustomobject][ordered]@{
                role='event-ledger-prefix-normalization';path=[string]$intent.paths.receipt
                schema=[string]$intent.receipt.document.schema;sha256=[string]$intent.receipt.sha256
            }
            repository_head=[string]$intent.repository.head
            state_sha256=[string]$intent.target.state_file_sha256
            unit_sha256=[string]$intent.pre.unit_file_sha256
            events_sha256=[string]$intent.target.events_sha256
            event_id=$NormalizationId
            status='committed'
        }
        Test-MorphospaceNormalizationSchema $completion 'event-ledger-prefix-normalization-completion-v1.schema.json' 'Event-ledger normalization completion'
        Write-MorphospaceManagedProtocolJsonAtomic $workspace $paths.completion $completion -NoOverwrite
        return [pscustomobject][ordered]@{
            normalization_id=$NormalizationId;transaction_id=[string]$intent.transaction_id
            status='committed';receipt=[string]$intent.paths.receipt;completion=$paths.completion
            repository_head=[string]$intent.repository.head;events_sha256=[string]$intent.target.events_sha256
            state_sha256=[string]$intent.target.state_file_sha256;unit_sha256=[string]$intent.pre.unit_file_sha256
        }
    }finally{Exit-MorphospaceWorkspaceMutex $lock}
}

function Invoke-MorphospaceEventLedgerPrefixNormalization {
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [Parameter(Mandatory=$true)][string]$NormalizationId,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][string]$ExpectedRepositoryHead,
        [Parameter(Mandatory=$true)][string]$ExpectedProjectSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedStateSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedUnitSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedEventsSha256,
        [Parameter(Mandatory=$true)][int64]$ExpectedEventsLength,
        [Parameter(Mandatory=$true)][string]$ExpectedEventTailId,
        [string]$Timestamp='',
        [switch]$Execute,
        [ValidateSet('none','after-intent','after-receipt','after-state','after-events')][string]$FaultAfter='none'
    )
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')}
    [void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    $paths=Get-MorphospaceNormalizationPaths $NormalizationId
    $intentPath=Get-MorphospaceNormalizationAbsolute $workspace $paths.intent
    $completionPath=Get-MorphospaceNormalizationAbsolute $workspace $paths.completion
    if([IO.File]::Exists($completionPath)){throw 'Event-ledger prefix normalization rejects replay after committed completion.'}
    if([IO.File]::Exists($intentPath)){
        if(-not$Execute){throw 'Event-ledger prefix normalization has an outstanding intent requiring executed recovery.'}
        return Complete-MorphospaceEventLedgerPrefixNormalization $workspace $NormalizationId -FaultAfter $(if($FaultAfter-eq'after-intent'){'none'}else{$FaultAfter})
    }

    $lock=Enter-MorphospaceWorkspaceMutex $workspace
    try{
        if([IO.File]::Exists($intentPath)-or[IO.File]::Exists($completionPath)){throw 'Event-ledger normalization transaction identity is already occupied.'}
        $transactions=Get-MorphospaceNormalizationAbsolute $workspace 'receipts/transactions'
        if([IO.Directory]::Exists($transactions)){
            foreach($priorIntent in @([IO.Directory]::EnumerateFiles($transactions,'*.intent.json',[IO.SearchOption]::TopDirectoryOnly))){
                $priorCompletion=$priorIntent.Substring(0,$priorIntent.Length-'.intent.json'.Length)+'.completion.json'
                if(-not[IO.File]::Exists($priorCompletion)){throw "Workspace has another outstanding transition intent requiring repair: $([IO.Path]::GetFileName($priorIntent))"}
            }
        }
        $candidate=Get-MorphospaceNormalizationCandidate -Workspace $workspace -NormalizationId $NormalizationId -UnitId $UnitId `
            -ExpectedRepositoryHead $ExpectedRepositoryHead -ExpectedProjectSha256 $ExpectedProjectSha256 `
            -ExpectedStateSha256 $ExpectedStateSha256 -ExpectedUnitSha256 $ExpectedUnitSha256 `
            -ExpectedEventsSha256 $ExpectedEventsSha256 -ExpectedEventsLength $ExpectedEventsLength `
            -ExpectedEventTailId $ExpectedEventTailId -Timestamp $Timestamp
        Assert-MorphospaceNormalizationGitClean $candidate.git
        $intent=New-MorphospaceNormalizationIntent $candidate
        Test-MorphospaceNormalizationSchema $intent 'event-ledger-prefix-normalization-intent-v1.schema.json' 'Event-ledger normalization intent'
        foreach($relative in @($paths.receipt,$paths.completion,$paths.stage,$paths.backup)){
            $target=Get-MorphospaceNormalizationAbsolute $workspace $relative
            if([IO.File]::Exists($target)-or[IO.Directory]::Exists($target)){throw "Event-ledger normalization target path is occupied: $relative"}
        }
        if(-not$Execute){
            return [pscustomobject][ordered]@{
                normalization_id=$NormalizationId;transaction_id=$paths.transaction_id;status='planned'
                repository_head=$candidate.git.head;project_id=[string]$candidate.project.project_id;unit_id=$UnitId
                before_events_sha256=[string]$intent.pre.events_sha256;after_events_sha256=[string]$intent.target.events_sha256
                before_state_sha256=[string]$intent.pre.state_file_sha256;after_state_sha256=[string]$intent.target.state_file_sha256
                receipt=$paths.receipt;completion=$paths.completion;execution='not-performed'
            }
        }
        Write-MorphospaceManagedProtocolJsonAtomic $workspace $paths.intent $intent -NoOverwrite
        if($FaultAfter-eq'after-intent'){throw 'Injected interruption after normalization intent publication.'}
    }finally{Exit-MorphospaceWorkspaceMutex $lock}
    Complete-MorphospaceEventLedgerPrefixNormalization $workspace $NormalizationId -FaultAfter $FaultAfter
}

Export-ModuleMember -Function Invoke-MorphospaceEventLedgerPrefixNormalization,Complete-MorphospaceEventLedgerPrefixNormalization
