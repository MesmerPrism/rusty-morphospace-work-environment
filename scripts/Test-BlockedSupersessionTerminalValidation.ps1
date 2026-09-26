param([switch]$KeepFixture, [switch]$RematerializationV6Only)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:fixtureAutomationModule = Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force -PassThru
$script:fixtureAmendmentModule = Import-Module (Join-Path $PSScriptRoot 'ActiveWriteScopeAmendment.psm1') -Force -PassThru
$script:fixtureProtocolModule = Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force -PassThru
$ledgerModule = Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force -PassThru
$script:fixtureTerminalModule = Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceBlockedSupersessionTerminalValidation.psm1') -Force -PassThru
if ($RematerializationV6Only) {
    Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -Force
    $script:fixtureRematerializationModule = Import-Module (Join-Path $PSScriptRoot 'ValidatingCandidateRematerialization.psm1') -Force -PassThru
}

# Keep the real owner implementations bound to this fixture's retained modules.
# Producer Force imports may remove matching export bindings; distinct fixture delegates
# and explicit ModuleObject calls do not rediscover or replace those exports.
function Read-FixtureProtocolJson {
    param([Parameter(Mandatory=$true)][string]$Path)
    & $script:fixtureProtocolModule.ExportedCommands['Read-MorphospaceProtocolJson'] @PSBoundParameters
}

function ConvertFrom-FixtureProtocolJsonBytes {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes,[string]$Context='protocol JSON')
    & $script:fixtureProtocolModule.ExportedCommands['ConvertFrom-MorphospaceProtocolJsonBytes'] @PSBoundParameters
}

function Get-FixtureCanonicalJsonSha256 {
    param([Parameter(Mandatory=$true)][object]$Value)
    & $script:fixtureProtocolModule.ExportedCommands['Get-MorphospaceCanonicalJsonSha256'] @PSBoundParameters
}

function Get-FixtureSha256Bytes {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    & $script:fixtureProtocolModule.ExportedCommands['Get-MorphospaceSha256Bytes'] @PSBoundParameters
}

function Get-FixtureFileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    & $script:fixtureProtocolModule.ExportedCommands['Get-MorphospaceFileSha256'] @PSBoundParameters
}

function Start-FixtureTransitionLedger {
    param(
        [string]$WorkspaceRoot, [string]$TransactionId, [string]$StatePath, [string]$UnitPath, [string]$EventsPath,
        [object]$TargetState, [object]$TargetUnit, [object]$Event,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter = 'none',
        [string]$ExpectedPreStateSha256 = '', [string]$ExpectedPreStateRawSha256 = '',
        [string]$ExpectedPreUnitSha256 = '', [string]$ExpectedPreUnitRawSha256 = '',
        [string]$ExpectedStateSha256 = '', [string]$ExpectedUnitSha256 = '', [AllowNull()][string]$ExpectedEventTailId,
        [string]$ExpectedEventsSha256 = '', [int64]$ExpectedEventsLength = -1, [string]$ExpectedSupersededUnitSha256 = '',
        [object[]]$AdditionalProjections = @(), [object[]]$Artifacts = @()
    )
    & $ledgerModule { param($Arguments) Start-MorphospaceTransitionLedger @Arguments } $PSBoundParameters
}

$encoding = [Text.UTF8Encoding]::new($false)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-blocked-supersession-' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $testRoot 'source'
$planningRoot = Join-Path $testRoot 'planning'
$workspace = Join-Path $planningRoot 'morphospace'
$repoMapPath = Join-Path $testRoot 'repository-map.json'
$projectId = 'terminal-history-fixture'
$oldUnitId = 'predecessor-owner'
$replacementUnitId = 'replacement-owner'
$supersessionEventId = "$oldUnitId-superseded-by-$replacementUnitId"
$assertions = [Collections.Generic.List[string]]::new()

function Write-FixtureJson {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 64 -Compress) + [Environment]::NewLine), $encoding)
}

function ConvertFrom-FixtureJsonText {
    param([string]$Text, [string]$Context = 'fixture JSON')
    return ConvertFrom-FixtureProtocolJsonBytes -Bytes $encoding.GetBytes($Text) -Context $Context
}

function Read-FixtureJson { param([string]$Path) return Read-FixtureProtocolJson -Path $Path }

function Copy-FixtureValue {
    param([object]$Value)
    return ConvertFrom-FixtureJsonText -Text ($Value | ConvertTo-Json -Depth 64 -Compress) -Context 'fixture value clone'
}

function Import-RematerializationV6FixtureDefinitions {
    $fixtureSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-ValidatingCandidateRematerialization.ps1'))
    $definitionStart = $fixtureSource.IndexOf('function Write-RematerializationTestJson', [StringComparison]::Ordinal)
    $definitionEnd = $fixtureSource.IndexOf("if(-not`$SelfTest)", [StringComparison]::Ordinal)
    if ($definitionStart -lt 0 -or $definitionEnd -le $definitionStart) {
        throw 'The validating-candidate rematerialization fixture-definition boundary is unavailable.'
    }
    return $fixtureSource.Substring($definitionStart, $definitionEnd - $definitionStart)
}

function Get-RematerializationV6Transition {
    param([string]$Workspace, [string]$EventId, [string]$PriorStateSha256, [string]$PriorUnitSha256)
    $module = $script:fixtureTerminalModule
    if ($null -eq $module) { throw 'Blocked-supersession terminal validation module is unavailable.' }
    return & $module {
        param($Workspace, $EventId, $PriorStateSha256, $PriorUnitSha256)
        $ledger = Get-MorphospaceBlockedSupersessionLedger -WorkspaceRoot $Workspace
        $row = @($ledger.rows | Where-Object { [string]$_.document.event_id -ceq $EventId })
        if ($row.Count -ne 1) { throw "Targeted rematerialization fixture lacks exactly one '$EventId' event." }
        Test-MorphospaceBlockedSupersessionTransaction -WorkspaceRoot $Workspace -Ledger $ledger -Row $row[0] -ProjectId 'test-project' `
            -ExpectedPreStateSha256 $PriorStateSha256 -ExpectedPreUnitSha256 $PriorUnitSha256 `
            -ExpectedIntentSchema 'rusty.morphospace.workflow.transition_ledger_intent.v6'
    } $Workspace $EventId $PriorStateSha256 $PriorUnitSha256
}

function Test-RematerializationV6TransitionDirect {
    param([string]$Workspace, [object]$Transition, [object]$PriorState, [string]$PriorStateSha256, [object]$PriorUnit, [string]$PriorUnitSha256)
    $module = $script:fixtureTerminalModule
    & $module {
        param($Workspace, $Transition, $PriorState, $PriorStateSha256, $PriorUnit, $PriorUnitSha256)
        Test-MorphospaceBlockedSupersessionRematerializationV6 -WorkspaceRoot $Workspace -ProjectId 'test-project' -UnitId 'unit-remat-001' `
            -Transition $Transition -PriorState $PriorState -PriorStateSha256 $PriorStateSha256 -PriorUnit $PriorUnit -PriorUnitSha256 $PriorUnitSha256
    } $Workspace $Transition $PriorState $PriorStateSha256 $PriorUnit $PriorUnitSha256
}

function Assert-RematerializationV6DirectRejects {
    param([string]$Workspace, [object]$Transition, [object]$PriorState, [string]$PriorStateSha256, [object]$PriorUnit, [string]$PriorUnitSha256, [scriptblock]$Mutation, [string]$ExpectedMessage)
    $damaged = Copy-FixtureValue $Transition
    & $Mutation $damaged
    $message = ''
    try {
        Test-RematerializationV6TransitionDirect -Workspace $Workspace -Transition $damaged -PriorState $PriorState -PriorStateSha256 $PriorStateSha256 -PriorUnit $PriorUnit -PriorUnitSha256 $PriorUnitSha256
    } catch { $message = [string]$_.Exception.Message }
    if (-not $message -or -not $message.Contains($ExpectedMessage, [StringComparison]::Ordinal)) {
        throw "Expected rematerialization v6 rejection containing '$ExpectedMessage', got '$message'."
    }
}

function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $output = @(& git -C $sourceRoot @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)" }
    return @($output)
}

# Producer conformance fixtures use neutral project and unit identities.
function Update-TerminalProducerEvent {
    param([string]$Workspace,[string]$EventId,[scriptblock]$Mutation)
    $path=Join-Path $Workspace 'iteration-events.jsonl'
    $text=[IO.File]::ReadAllText($path,$encoding)
    $parts=[regex]::Split($text,'(?<=\n)')
    $count=0
    for($index=0;$index-lt$parts.Length;$index++){
        if([string]::IsNullOrWhiteSpace($parts[$index])){continue}
        $event=ConvertFrom-FixtureJsonText $parts[$index] 'producer event damage'
        if([string]$event.event_id-cne$EventId){continue}
        &$Mutation $event
        $newline=if($parts[$index].EndsWith("`r`n")){"`r`n"}elseif($parts[$index].EndsWith("`n")){"`n"}else{''}
        $parts[$index]=($event|ConvertTo-Json -Depth 100 -Compress)+$newline
        $count++
    }
    if($count-ne1){throw 'Producer event damage did not select exactly one raw row.'}
    [IO.File]::WriteAllText($path,($parts-join''),$encoding)
}
function New-TerminalProducerSupersessionRequest {
    param([string]$Workspace)
    $project=Read-FixtureJson (Join-Path $Workspace 'project.spec.json')
    $state=Read-FixtureJson (Join-Path $Workspace 'workspace.state.json')
    $oldPath="iteration-units/$oldUnitId.json";$replacementPath="iteration-units/$replacementUnitId.json"
    $old=Read-FixtureJson (Join-Path $Workspace $oldPath)
    $replacement=Read-FixtureJson (Join-Path $Workspace $replacementPath)
    $eventBytes=[IO.File]::ReadAllBytes((Join-Path $Workspace 'iteration-events.jsonl'))
    $events=@(Get-Content -LiteralPath (Join-Path $Workspace 'iteration-events.jsonl')|Where-Object {$_}|ForEach-Object {ConvertFrom-FixtureJsonText $_ 'producer request ledger'})
    $tail=if($events.Count){[string]$events[-1].event_id}else{$null}
    # Only a reviewed request is constructed. Real SupersedeActive validates this
    # actual clean fixture materialization and emits its own receipt/transaction.
    if(@(Invoke-FixtureGit @('status','--porcelain')).Count-ne0){throw 'Producer fixture request requires its actual source to be clean.'}
    $head=([string](@(Invoke-FixtureGit @('rev-parse','HEAD'))[0])).Trim()
    $tree=([string](@(Invoke-FixtureGit @('rev-parse','HEAD^{tree}'))[0])).Trim()
    $branch=([string](@(Invoke-FixtureGit @('symbolic-ref','--short','HEAD'))[0])).Trim()
    [string[]]$allowed=@($replacement.allowed_repositories[0].allowed_paths)
    [Array]::Sort($allowed,[StringComparer]::Ordinal)
    $repositories=@([pscustomobject][ordered]@{
        repo_id='fixture-source';head=$head;tree=$tree;branch=$branch
        dirty_fingerprint=Get-FixtureSha256Bytes ([byte[]]@())
        scope_disposition='owned'
        ownership_scopes=@([pscustomobject][ordered]@{unit_id=$replacementUnitId;role='replacement';allowed_paths=$allowed})
        allowed_paths=$allowed;overlay=@()
    })
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.active_unit_supersession.v1'
        supersession_id=$supersessionEventId
        project_id=$projectId
        old_unit=[ordered]@{unit_id=$oldUnitId;path=$oldPath;raw_sha256=(Get-FileHash (Join-Path $Workspace $oldPath) -Algorithm SHA256).Hash.ToLowerInvariant();canonical_sha256=Get-FixtureCanonicalJsonSha256 $old;status='active'}
        replacement_unit=[ordered]@{unit_id=$replacementUnitId;path=$replacementPath;raw_sha256=(Get-FileHash (Join-Path $Workspace $replacementPath) -Algorithm SHA256).Hash.ToLowerInvariant();canonical_sha256=Get-FixtureCanonicalJsonSha256 $replacement;status='proposed'}
        companion_units=@()
        expected=[ordered]@{
            project_raw_sha256=(Get-FileHash (Join-Path $Workspace 'project.spec.json') -Algorithm SHA256).Hash.ToLowerInvariant()
            project_canonical_sha256=Get-FixtureCanonicalJsonSha256 $project
            state_raw_sha256=(Get-FileHash (Join-Path $Workspace 'workspace.state.json') -Algorithm SHA256).Hash.ToLowerInvariant()
            state_canonical_sha256=Get-FixtureCanonicalJsonSha256 $state
            events_sha256=Get-FixtureSha256Bytes $eventBytes
            events_length=[int64]$eventBytes.Length
            event_tail_id=$tail
            repository_map_sha256=(Get-FileHash $repoMapPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        repositories=@($repositories)
        does_not_authorize=@('This request changes only workflow ownership; it authorizes no acceptance, source edit, build, device, Git, remote, or publication action.')
    }
}

function Update-TerminalInstructionArtifact {
    param([string]$Workspace,[scriptblock]$Mutation,[bool]$RecomputeIds=$true,[bool]$RecomputeObservation=$true)
    $path=Join-Path $Workspace 'receipts/producer-instructions-output.json'
    $receipt=Read-FixtureJson $path
    &$Mutation $receipt
    if($RecomputeIds){
        foreach($row in @($receipt.instruction_surface_completion.surfaces)){
            $identity=[pscustomobject][ordered]@{
                surface_kind=$row.surface_kind;declared_path=$row.declared_path;repo_id=$row.repo_id;relative_path=$row.relative_path
                owner=$row.owner;action=$row.action;validation=$row.validation;skill_id=$row.skill_id
            }
            $row.surface_id=Get-FixtureCanonicalJsonSha256 $identity
        }
        $receipt.instruction_surface_completion.surfaces=@($receipt.instruction_surface_completion.surfaces|Sort-Object surface_id -CaseSensitive)
    }
    if($RecomputeObservation){$receipt.instruction_surface_completion.observation_sha256=Get-FixtureCanonicalJsonSha256 ([pscustomobject][ordered]@{surfaces=@($receipt.instruction_surface_completion.surfaces)})}
    Write-FixtureJson $path $receipt
    $bytes=[IO.File]::ReadAllBytes($path)
    $intentPath=Join-Path $Workspace 'receipts/transactions/producer-instructions-recorded-transition.intent.json'
    $intent=Read-FixtureJson $intentPath
    $intent.artifacts[0].bytes_base64=[Convert]::ToBase64String($bytes);$intent.artifacts[0].sha256=Get-FixtureSha256Bytes $bytes
    Write-FixtureJson $intentPath $intent
    Rebind-FixtureTransaction $Workspace 'producer-instructions-recorded'
}

function Update-TerminalSupersessionScopeArtifact {
    param([string]$Workspace,[ValidateSet('path','repository')][string]$Damage)
    $intentPath=Join-Path $Workspace "receipts/transactions/$supersessionEventId-transition.intent.json"
    $intent=Read-FixtureJson $intentPath
    if($Damage-ceq'path'){$intent.target.unit.document.allowed_repositories[0].allowed_paths+=@('outside-source/')}
    else{$intent.target.unit.document.allowed_repositories+=@([pscustomobject][ordered]@{repo_id='foreign-source';allowed_paths=@('src/')})}
    $pre=Copy-FixtureValue $intent.target.unit.document;$pre.status='proposed'
    $preHash=Get-FixtureCanonicalJsonSha256 $pre
    $intent.pre.unit.sha256=$preHash;$intent.expected.unit_sha256=$preHash
    $requestPath=Join-Path $Workspace 'receipts/producer-supersession-request.json'
    $request=Read-FixtureJson $requestPath
    $request.replacement_unit.canonical_sha256=$preHash
    $request.replacement_unit.raw_sha256=Get-FixtureSha256Bytes ($encoding.GetBytes(($pre|ConvertTo-Json -Depth 100)+[Environment]::NewLine))
    if($Damage-ceq'path'){
        [string[]]$allowed=@($pre.allowed_repositories[0].allowed_paths)
        [Array]::Sort($allowed,[StringComparer]::Ordinal)
        $request.repositories[0].allowed_paths=$allowed;$request.repositories[0].ownership_scopes[0].allowed_paths=$allowed
    }else{
        $extra=Copy-FixtureValue $request.repositories[0];$extra.repo_id='foreign-source';$extra.allowed_paths=@('src/');$extra.ownership_scopes[0].allowed_paths=@('src/')
        $request.repositories=@(@($request.repositories)+$extra|Sort-Object repo_id -CaseSensitive)
    }
    Write-FixtureJson $requestPath $request
    $output=Join-Path $Workspace 'receipts/producer-supersession-output.json'
    $receipt=Read-FixtureJson $output
    $receipt.audit_receipt.sha256=(Get-FileHash $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-FixtureJson $output $receipt
    $bytes=[IO.File]::ReadAllBytes($output)
    $intent.artifacts[0].bytes_base64=[Convert]::ToBase64String($bytes);$intent.artifacts[0].sha256=Get-FixtureSha256Bytes $bytes
    Write-FixtureJson $intentPath $intent
    Rebind-FixtureTransaction $Workspace $supersessionEventId
}

function Invoke-ReceiptBearingProducerTerminalCases {
    param([string]$Template)
    $case=Copy-FixtureWorkspace -Source $Template -Name 'producer-receipt-bearing-cycles'
    $replacement=Read-FixtureJson (Join-Path $case "iteration-units/$replacementUnitId.json")
    $replacement.status='proposed'
    foreach($surface in @($replacement.instruction_surfaces)){$surface.status='planned'}
    Write-FixtureJson (Join-Path $case "iteration-units/$replacementUnitId.json") $replacement
    Update-FixtureJson (Join-Path $case 'workspace.state.json') {param($s)$s.next_ready_unit=$null}
    $request=New-TerminalProducerSupersessionRequest $case
    $requestPath=Join-Path $case 'receipts/producer-supersession-request.json'
    Write-FixtureJson $requestPath $request
    $requestHash=(Get-FileHash $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $null=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action SupersedeActive -WorkspaceRoot $case -UnitId $replacementUnitId -RepoMapPath $repoMapPath -ActiveUnitSupersession $requestPath -ExpectedActiveUnitSupersessionSha256 $requestHash -OutPath (Join-Path $case 'receipts/producer-supersession-output.json') -Timestamp '2026-01-02T03:03:00.0000000Z' -Execute
    # Completion is actual owner producer output, never a hand-authored v1 artifact.
    $completionArguments=@{Action='CompleteInstructionSurfaces';WorkspaceRoot=$case;UnitId=$replacementUnitId;RepoMapPath=$repoMapPath;InstructionCompletionId='producer-instructions';OutPath=(Join-Path $case 'receipts/producer-instructions-output.json');Timestamp='2026-01-02T03:03:30.0000000Z'}
    $dry=& $script:fixtureAutomationModule.ExportedCommands['Invoke-MorphospaceWorkUnitAutomation'] @completionArguments
    $completionArguments.ExpectedInstructionObservationSha256=[string]$dry.instruction_surface_completion.observation_sha256
    $completionArguments.ExpectedUnitSha256=[string]$dry.instruction_surface_completion.expected_unit_sha256
    $completionArguments.InstructionSurfaceIds=@($dry.instruction_surface_completion.surfaces.surface_id)
    $completionArguments.Execute=$true
    $null=& $script:fixtureAutomationModule.ExportedCommands['Invoke-MorphospaceWorkUnitAutomation'] @completionArguments
    $cycleReturnIds=[Collections.Generic.List[string]]::new()
    for($attempt=1;$attempt-le2;$attempt++){
        Invoke-OwnerAction $case BeginValidation $replacementUnitId ('2026-01-02T03:0{0}:00.0000000Z'-f($attempt+3))
        $failed=New-FixtureValidationReceipt $case $replacementUnitId fail "producer-attempt-$attempt"
        Invoke-OwnerAction $case ReturnToActive $replacementUnitId ('2026-01-02T03:0{0}:30.0000000Z'-f($attempt+3)) -ValidationReceipt $failed -ValidationResult fail
        $state=Read-FixtureJson (Join-Path $case 'workspace.state.json')
        $cycleReturnIds.Add([string]$state.last_event_id)
    }
    Invoke-OwnerAction $case BeginValidation $replacementUnitId '2026-01-02T03:06:00.0000000Z'
    $failReceipt=New-FixtureValidationReceipt $case $replacementUnitId fail 'producer-terminal'
    Invoke-OwnerAction $case RecordValidation $replacementUnitId '2026-01-02T03:06:30.0000000Z' -ValidationReceipt $failReceipt -ValidationResult fail
    Assert-HelperPasses $case 'receipt-bearing-proposed-preimage-completion-two-return-cycles' 0
    # Existing blocked instruction compatibility is intentionally unchanged. Aggregate
    # CurrentWork integration is asserted after the real supported Resume action.
    $resumed=Copy-FixtureWorkspace $case 'producer-real-resume'
    Invoke-OwnerAction $resumed Resume $replacementUnitId '2026-01-02T03:07:00.0000000Z'
    Assert-HelperPasses $resumed 'receipt-bearing-terminal-real-resume' 1
    Invoke-WorkflowContract $resumed|Out-Null
    Assert-Passed $true 'receipt-bearing-terminal-resume-aggregate'
    Assert-HelperRejects $case 'producer-request-missing' {param($c)Remove-Item -LiteralPath (Join-Path $c 'receipts/producer-supersession-request.json')} 'Workspace artifact'
    Assert-HelperRejects $case 'producer-bound-output-action-substitution' {
        param($c)$output=Join-Path $c 'receipts/producer-supersession-output.json'
        Update-FixtureJson $output {param($r)$r.action='Inspect'}
        $bytes=[IO.File]::ReadAllBytes($output)
        $intentPath=Join-Path $c "receipts/transactions/$supersessionEventId-transition.intent.json"
        $i=Read-FixtureJson $intentPath
        $i.artifacts[0].bytes_base64=[Convert]::ToBase64String($bytes);$i.artifacts[0].sha256=Get-FixtureSha256Bytes $bytes
        Write-FixtureJson $intentPath $i;Rebind-FixtureTransaction $c $supersessionEventId
    } 'requires exact executed SupersedeActive output'
    Assert-HelperRejects $case 'producer-supersession-ready-substitution' {
        param($c)
        $p=Join-Path $c "receipts/transactions/$supersessionEventId-transition.intent.json"
        Update-FixtureJson $p {param($i)$u=Copy-FixtureValue $i.target.unit.document;$u.status='ready';$i.pre.unit.sha256=Get-FixtureCanonicalJsonSha256 $u;$i.expected.unit_sha256=$i.pre.unit.sha256}
        Rebind-FixtureTransaction $c $supersessionEventId
    } 'preimage differs from the reviewed request'
    $returnId=$cycleReturnIds[0]
    Assert-HelperRejects $case 'producer-return-completion-missing' {param($c)Remove-Item -LiteralPath (Join-Path $c "receipts/transactions/$returnId-transition.completion.json")} 'Workspace artifact'
    Assert-HelperRejects $case 'producer-return-cross-unit' {
        param($c)Update-TerminalProducerEvent $c $returnId {param($e)$e.unit_id='foreign-unit'}
        Update-FixtureJson (Join-Path $c "receipts/transactions/$returnId-transition.intent.json") {param($i)$i.event.unit_id='foreign-unit'};Rebind-FixtureTransaction $c $returnId
    } 'crosses the replacement project/unit'
    Assert-HelperRejects $case 'producer-return-arbitrary-recorded-substitution' {
        param($c)Update-TerminalProducerEvent $c $returnId {param($e)$e.event_type='state-transition'}
        Update-FixtureJson (Join-Path $c "receipts/transactions/$returnId-transition.intent.json") {param($i)$i.event.event_type='state-transition'};Rebind-FixtureTransaction $c $returnId
    } 'requires exact ordinary instruction completion'
    Assert-HelperRejects $case 'producer-return-unit-contract-change' {
        param($c)Update-FixtureJson (Join-Path $c "receipts/transactions/$returnId-transition.intent.json") {param($i)$i.target.unit.document.objective+=' foreign scope'};Rebind-FixtureTransaction $c $returnId
    } 'ReturnToActive changes unit contract beyond status'
    Assert-HelperRejects $case 'producer-return-passing-substitution' {
        param($c)Update-FixtureJson (Join-Path $c "receipts/transactions/$returnId-transition.intent.json") {param($i)$i.target.state.document.validation_checkpoint.result='pass'};Rebind-FixtureTransaction $c $returnId
    } 'ReturnToActive requires a non-passing checkpoint'
    Assert-HelperRejects $case 'producer-return-detached-pre-state' {
        param($c)Update-FixtureJson (Join-Path $c "receipts/transactions/$returnId-transition.intent.json") {param($i)$i.pre.state.sha256=('a'*64);$i.expected.state_sha256=$i.pre.state.sha256};Rebind-FixtureTransaction $c $returnId
    } 'detached from the preceding state target'
    Assert-HelperRejects $case 'producer-return-inferred-acceptance' {
        param($c)Update-FixtureJson (Join-Path $c "receipts/transactions/$returnId-transition.intent.json") {param($i)$i.target.state.document.last_accepted_receipt='receipts/fabricated-pass.json'};Rebind-FixtureTransaction $c $returnId
    } 'authority-bearing state'
    Assert-HelperRejects $case 'producer-return-undeclared-observation' {
        param($c)Update-FixtureJson (Join-Path $c "receipts/transactions/$returnId-transition.intent.json") {param($i)$i.target.state.document.dirty_repositories=@('foreign-repository')};Rebind-FixtureTransaction $c $returnId
    } 'undeclared or repeated repository'
    Assert-HelperRejects $case 'producer-return-receipt-substitution' {
        param($c)$i=Read-FixtureJson (Join-Path $c "receipts/transactions/$returnId-transition.intent.json")
        Update-FixtureJson (Join-Path $c ([string]$i.event.receipts[0])) {param($r)$r.unit_id='foreign-unit'}
    } 'not an exact same-unit fail result'
    Assert-HelperRejects $case 'producer-completion-contract-change' {
        param($c)$id='producer-instructions-recorded'
        Update-FixtureJson (Join-Path $c "receipts/transactions/$id-transition.intent.json") {param($i)$i.target.unit.document.objective+=' foreign scope'};Rebind-FixtureTransaction $c $id
    } 'retained authority/objective'
    Assert-HelperRejects $case 'producer-completion-surface-owner-rehashed' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$r.instruction_surface_completion.surfaces[0].owner='foreign-owner'}
    } 'surface identity differs from the planned declaration'
    Assert-HelperRejects $case 'producer-completion-surface-path-rehashed' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$r.instruction_surface_completion.surfaces[0].declared_path='<repo-root>/foreign.md'}
    } 'surface declaration differs from the planned set'
    Assert-HelperRejects $case 'producer-completion-surface-action-rehashed' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$row=$r.instruction_surface_completion.surfaces[0];$row.action=if($row.action-ceq'update'){'review-no-change'}else{'update'}}
    } 'surface identity differs from the planned declaration'
    Assert-HelperRejects $case 'producer-completion-surface-id-rehashed-observation' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$r.instruction_surface_completion.surfaces[0].surface_id=('a'*64)} -RecomputeIds $false
    } 'surface IDs are not exact, unique and sorted'
    Assert-HelperRejects $case 'producer-completion-observation-hash-substitution' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$r.instruction_surface_completion.observation_sha256=('b'*64)} -RecomputeIds $false -RecomputeObservation $false
    } 'observation hash differs'
    Assert-HelperRejects $case 'producer-completion-relative-observation-substitution' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$r.instruction_surface_completion.surfaces[0].relative_path='foreign.md'}
    } 'retained observation differs'
    Assert-HelperRejects $case 'producer-completion-timestamp-substitution' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$r.timestamp='2026-01-02T03:03:31.0000000Z'}
    } 'receipt transition fields differ'
    Assert-HelperRejects $case 'producer-completion-status-substitution' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$r.status_before='proposed'}
    } 'receipt transition fields differ'
    Assert-HelperRejects $case 'producer-completion-captain-substitution' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$r.current_unit_before='foreign-unit'}
    } 'receipt transition fields differ'
    Assert-HelperRejects $case 'producer-completion-preservation-substitution' {
        param($c)Update-TerminalInstructionArtifact $c {param($r)$r.preservation.git_mutation_performed=$true}
    } 'instruction-completion receipt schema differs'
    Assert-HelperRejects $case 'producer-supersession-path-widening-rebound' {
        param($c)Update-TerminalSupersessionScopeArtifact $c path
    } 'source scope widens path authority'
    Assert-HelperRejects $case 'producer-supersession-repository-widening-rebound' {
        param($c)Update-TerminalSupersessionScopeArtifact $c repository
    } 'source scope widens repository authority'
}

function New-FixtureUnit {
    param([string]$UnitId, [string]$Status)
    return [pscustomobject][ordered]@{
        '$schema' = '../schemas/iteration-unit.schema.json'
        schema = 'rusty.morphospace.workflow.iteration_unit.v1'
        unit_id = $UnitId
        project_id = $projectId
        status = $Status
        objective = "Exercise owner-authenticated terminal history for $UnitId."
        change_categories = @('validation')
        instruction_impact = 'update'
        instruction_none_justification = $null
        instruction_surfaces = @(
            [pscustomobject][ordered]@{ surface_kind = 'agents'; path = '<repo-root>/AGENTS.md'; owner = 'fixture-owner'; change_reason = 'Exercise the instruction projection required by a feature-mode fixture.'; action = 'update'; status = 'complete'; validation = 'Synthetic fixture review.'; skill_id = $null },
            [pscustomobject][ordered]@{ surface_kind = 'readme'; path = '<repo-root>/README.md'; owner = 'fixture-owner'; change_reason = 'Exercise the public router projection required by a feature-mode fixture.'; action = 'update'; status = 'complete'; validation = 'Synthetic fixture review.'; skill_id = $null },
            [pscustomobject][ordered]@{ surface_kind = 'skill'; path = '<skills-root>/rusty-morphospace/SKILL.md'; owner = 'workflow-maintainer'; change_reason = 'Exercise the Morphospace skill projection required by a feature-mode fixture.'; action = 'update'; status = 'complete'; validation = 'Synthetic fixture review.'; skill_id = 'rusty-morphospace' },
            [pscustomobject][ordered]@{ surface_kind = 'skill'; path = '<skills-root>/system-engineering/SKILL.md'; owner = 'workflow-maintainer'; change_reason = 'Exercise the system-authority skill projection required by a feature-mode fixture.'; action = 'update'; status = 'complete'; validation = 'Synthetic fixture review.'; skill_id = 'system-engineering' }
        )
        prerequisites = @()
        allowed_repositories = @([pscustomobject][ordered]@{ repo_id = 'fixture-source'; allowed_paths = @('src/', 'AGENTS.md', 'README.md', 'rusty-morphospace/SKILL.md', 'system-engineering/SKILL.md') })
        non_scope = @('Real projects, remotes, devices, and publication.')
        acceptance = @([pscustomobject][ordered]@{ acceptance_id = 'fixture-proof'; proof = 'The neutral workflow fixture passes.'; command = 'Test-BlockedSupersessionTerminalValidation.ps1' })
        risk_tier = 'standard'
        device_requirement = 'none'
        validation = @([pscustomobject][ordered]@{ profile_id = 'workflow'; command = 'Run the neutral workflow fixture.' })
        outputs = @('Synthetic owner transition evidence.')
        commit_policy = 'Temporary local fixture only.'
        push_checkpoint = 'local-only'
    }
}

function New-FixtureValidationReceipt {
    param([string]$Workspace, [string]$UnitId, [ValidateSet('pass','fail')][string]$Result, [string]$Suffix)
    $head = ([string]@(Invoke-FixtureGit @('rev-parse','HEAD'))[0]).Trim()
    $receiptRoot = Join-Path $Workspace 'receipts'
    [IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
    $evidenceName = "$UnitId-$Suffix-evidence.txt"
    $evidencePath = Join-Path $receiptRoot $evidenceName
    [IO.File]::WriteAllText($evidencePath, "neutral $Result validation evidence`n", $encoding)
    $evidenceHash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $status = if ($Result -eq 'pass') { 'pass' } else { 'fail' }
    $receiptName = "$UnitId-$Suffix-validation.json"
    $receipt = [pscustomobject][ordered]@{
        '$schema' = '../schemas/validation-receipt.schema.json'
        schema = 'rusty.morphospace.workflow.validation_receipt.v1'
        receipt_id = "$UnitId-$Suffix-validation"
        project_id = $projectId
        unit_id = $UnitId
        created_at = '2026-01-02T03:05:00.0000000Z'
        tier = 'standard'
        result = $Result
        repository_revisions = @([pscustomobject][ordered]@{ repo_id = 'fixture-source'; base_revision = $head; head_revision = $head; branch = 'main' })
        changed_paths = @()
        artifacts = @([pscustomobject][ordered]@{ artifact_id = 'fixture-evidence'; kind = 'test-log'; path = $evidenceName; sha256 = $evidenceHash })
        criteria = @([pscustomobject][ordered]@{ acceptance_id = 'fixture-proof'; status = $status; command = 'Test-BlockedSupersessionTerminalValidation.ps1'; evidence_refs = @('fixture-evidence') })
        gates = @(
            [pscustomobject][ordered]@{ gate_id = 'validation-workflow'; status = $status; command = 'Run the neutral workflow fixture.'; evidence_refs = @('fixture-evidence') },
            [pscustomobject][ordered]@{ gate_id = 'instruction-synchronization'; status = $status; command = 'Verify every declared instruction surface is complete and validated.'; evidence_refs = @('fixture-evidence') }
        )
        device_validation = $null
    }
    Write-FixtureJson -Path (Join-Path $receiptRoot $receiptName) -Value $receipt
    return "receipts/$receiptName"
}

function Copy-FixtureWorkspace {
    param([string]$Source, [string]$Name)
    $destination = Join-Path $testRoot $Name
    if (Test-Path -LiteralPath $destination) { throw "Fixture destination already exists: $destination" }
    Copy-Item -LiteralPath $Source -Destination $destination -Recurse
    return $destination
}

function Invoke-OwnerAction {
    param(
        [string]$Workspace,
        [string]$Action,
        [string]$UnitId,
        [string]$Timestamp,
        [string]$ValidationReceipt = '',
        [string]$ValidationResult = 'pass'
    )
    $arguments = @{
        Action = $Action
        WorkspaceRoot = $Workspace
        UnitId = $UnitId
        RepoMapPath = $repoMapPath
        ValidationTier = 'standard'
        Timestamp = $Timestamp
        Execute = $true
    }
    if ($ValidationReceipt) { $arguments.ValidationReceipt = $ValidationReceipt; $arguments.ValidationResult = $ValidationResult }
    & $script:fixtureAutomationModule.ExportedCommands['Invoke-MorphospaceWorkUnitAutomation'] @arguments | Out-Null
}

function Invoke-WorkflowContract {
    param([string]$Workspace)
    & (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -RepoRoot $RepoRoot -WorkspaceRoot $Workspace -RepositoryMapPath $repoMapPath -SkipOwnerSelfTests
}

function Assert-Passed {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "Assertion failed: $Name" }
    $assertions.Add($Name) | Out-Null
}

function Assert-HelperPasses {
    param([string]$Workspace, [string]$Name, [int]$ContinuationCount, [int]$ProjectionCount = -1)
    $result = & $script:fixtureTerminalModule.ExportedCommands['Test-MorphospaceBlockedSupersessionTerminalValidation'] -WorkspaceRoot $Workspace -ProjectId $projectId -SupersessionEventId $supersessionEventId -ReplacementUnitId $replacementUnitId
    $projectionMatches = $ProjectionCount -lt 0 -or [int]$result.continuation_projection_count -eq $ProjectionCount
    Assert-Passed ($result.history_present -and $result.authenticated -and [int]$result.continuation_event_count -eq $ContinuationCount -and $projectionMatches -and -not $result.acceptance_inferred) $Name
}

function Assert-HelperRejects {
    param([string]$Template, [string]$Name, [scriptblock]$Mutation, [string]$ExpectedMessage = '')
    $caseRoot = Copy-FixtureWorkspace -Source $Template -Name ('damage-' + $Name)
    & $Mutation $caseRoot
    $rejected = $false
    $rejectionMessage = ''
    try {
        & $script:fixtureTerminalModule.ExportedCommands['Test-MorphospaceBlockedSupersessionTerminalValidation'] -WorkspaceRoot $caseRoot -ProjectId $projectId -SupersessionEventId $supersessionEventId -ReplacementUnitId $replacementUnitId | Out-Null
    } catch { $rejected = $true; $rejectionMessage = [string]$_.Exception.Message }
    if ($rejected -and $ExpectedMessage -and -not $rejectionMessage.Contains($ExpectedMessage, [StringComparison]::Ordinal)) {
        throw "Assertion failed: $Name rejected with '$rejectionMessage' instead of expected context '$ExpectedMessage'."
    }
    Assert-Passed $rejected $Name
}

function Assert-WorkflowRejects {
    param([string]$Template, [string]$Name, [scriptblock]$Mutation)
    $caseRoot = Copy-FixtureWorkspace -Source $Template -Name ('workflow-damage-' + $Name)
    & $Mutation $caseRoot
    $rejected = $false
    try { Invoke-WorkflowContract -Workspace $caseRoot *> $null } catch { $rejected = $true }
    Assert-Passed $rejected $Name
}

function Update-FixtureJson {
    param([string]$Path, [scriptblock]$Mutation)
    $document = Read-FixtureJson -Path $Path
    & $Mutation $document
    Write-FixtureJson -Path $Path -Value $document
}

function Rebind-FixtureTransaction {
    param([string]$Workspace, [string]$EventId)
    $transactionId = "$EventId-transition"
    $intentPath = Join-Path $Workspace "receipts\transactions\$transactionId.intent.json"
    $completionPath = Join-Path $Workspace "receipts\transactions\$transactionId.completion.json"
    $intent = Read-FixtureJson -Path $intentPath
    $embeddedEventHash = Get-FixtureCanonicalJsonSha256 -Value $intent.event
    $intent.target.state.sha256 = Get-FixtureCanonicalJsonSha256 -Value $intent.target.state.document
    $intent.target.unit.sha256 = Get-FixtureCanonicalJsonSha256 -Value $intent.target.unit.document
    Write-FixtureJson -Path $intentPath -Value $intent
    $reboundIntent = Read-FixtureJson -Path $intentPath
    if ((Get-FixtureCanonicalJsonSha256 -Value $reboundIntent.event) -cne $embeddedEventHash) {
        throw "Fixture transaction '$EventId' rebind changed its embedded immutable event."
    }
    $completion = Read-FixtureJson -Path $completionPath
    $completion.intent.sha256 = (Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $completion.state_sha256 = [string]$intent.target.state.sha256
    $completion.unit_sha256 = [string]$intent.target.unit.sha256
    Write-FixtureJson -Path $completionPath -Value $completion
}

function Rewrite-FixtureTransactionEventIdentity {
    param([string]$Workspace, [string]$OldEventId, [string]$NewEventId)
    $oldTransactionId = "$OldEventId-transition"
    $newTransactionId = "$NewEventId-transition"
    $oldIntentPath = Join-Path $Workspace "receipts\transactions\$oldTransactionId.intent.json"
    $oldCompletionPath = Join-Path $Workspace "receipts\transactions\$oldTransactionId.completion.json"
    $newIntentPath = Join-Path $Workspace "receipts\transactions\$newTransactionId.intent.json"
    $newCompletionPath = Join-Path $Workspace "receipts\transactions\$newTransactionId.completion.json"
    $intent = Read-FixtureJson -Path $oldIntentPath
    $completion = Read-FixtureJson -Path $oldCompletionPath
    $intent.transaction_id = $newTransactionId
    $intent.event.event_id = $NewEventId
    $intent.target.state.document.last_event_id = $NewEventId
    $intent.target.state.sha256 = Get-FixtureCanonicalJsonSha256 -Value $intent.target.state.document
    Write-FixtureJson -Path $newIntentPath -Value $intent
    $completion.transaction_id = $newTransactionId
    $completion.event_id = $NewEventId
    $completion.state_sha256 = [string]$intent.target.state.sha256
    $completion.intent.path = "receipts/transactions/$newTransactionId.intent.json"
    $completion.intent.schema = [string]$intent.schema
    $completion.intent.sha256 = Get-FixtureFileSha256 -Path $newIntentPath
    Write-FixtureJson -Path $newCompletionPath -Value $completion
    Remove-Item -LiteralPath $oldIntentPath,$oldCompletionPath
    Update-FixtureLedgerEvent -Workspace $Workspace -EventId $OldEventId -Mutation { param($event) $event.event_id = $NewEventId }
    Update-FixtureJson (Join-Path $Workspace 'workspace.state.json') { param($state) $state.last_event_id = $NewEventId }
}

function Update-FixtureLedgerEvent {
    param([string]$Workspace, [string]$EventId, [scriptblock]$Mutation)
    $path = Join-Path $Workspace 'iteration-events.jsonl'
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = ConvertFrom-FixtureJsonText -Text $line -Context "fixture ledger event '$path'"
        if ([string]$event.event_id -ceq $EventId) { & $Mutation $event }
        $lines.Add(($event | ConvertTo-Json -Depth 32 -Compress)) | Out-Null
    }
    [IO.File]::WriteAllText($path, (($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine), $encoding)
}

function Add-LaterUnit {
    param([string]$Workspace, [switch]$Accept)
    $laterUnitId = if ($Accept) { 'later-accepted-owner' } else { 'later-current-owner' }
    Write-FixtureJson -Path (Join-Path $Workspace "iteration-units\$laterUnitId.json") -Value (New-FixtureUnit -UnitId $laterUnitId -Status 'proposed')
    Invoke-OwnerAction -Workspace $Workspace -Action Ready -UnitId $laterUnitId -Timestamp '2026-01-02T03:06:00.0000000Z'
    Invoke-OwnerAction -Workspace $Workspace -Action Claim -UnitId $laterUnitId -Timestamp '2026-01-02T03:07:00.0000000Z'
    if ($Accept) {
        Invoke-OwnerAction -Workspace $Workspace -Action BeginValidation -UnitId $laterUnitId -Timestamp '2026-01-02T03:08:00.0000000Z'
        $receipt = New-FixtureValidationReceipt -Workspace $Workspace -UnitId $laterUnitId -Result pass -Suffix pass
        Invoke-OwnerAction -Workspace $Workspace -Action RecordValidation -UnitId $laterUnitId -Timestamp '2026-01-02T03:09:00.0000000Z' -ValidationReceipt $receipt -ValidationResult pass
        Invoke-OwnerAction -Workspace $Workspace -Action Accept -UnitId $laterUnitId -Timestamp '2026-01-02T03:10:00.0000000Z'
    }
}

function Add-OwnerV2SupersessionContinuation {
    param([string]$Workspace)
    $oldId='later-current-owner';$newId='later-v2-owner';$timestamp='2026-01-02T03:09:00.0000000Z'
    Write-FixtureJson -Path (Join-Path $Workspace "iteration-units\$newId.json") -Value (New-FixtureUnit -UnitId $newId -Status 'proposed')
    Invoke-OwnerAction -Workspace $Workspace -Action Ready -UnitId $newId -Timestamp '2026-01-02T03:08:00.0000000Z'
    $statePath=Join-Path $Workspace 'workspace.state.json';$eventsPath=Join-Path $Workspace 'iteration-events.jsonl'
    $oldPath=Join-Path $Workspace "iteration-units\$oldId.json";$newPath=Join-Path $Workspace "iteration-units\$newId.json"
    $state=Read-FixtureJson $statePath;$old=Read-FixtureJson $oldPath;$ready=Read-FixtureJson $newPath
    $tail=ConvertFrom-FixtureJsonText -Text ([string](Get-Content $eventsPath|Where-Object{$_}|Select-Object -Last 1)) -Context 'v2 continuation tail'
    $eventId="$oldId-superseded-by-$newId";$targetState=Copy-FixtureValue $state;$targetState.current_unit=$newId;$targetState.next_ready_unit=$null;$targetState.last_event_id=$eventId
    $active=Copy-FixtureValue $ready;$active.status='active'
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$tail.sequence+1;timestamp=$timestamp;project_id=$projectId;unit_id=$oldId;event_type='state-transition';summary='The exact owner-produced v2 fixture replacement supersedes its authenticated predecessor.';receipts=@()}
    Start-FixtureTransitionLedger -WorkspaceRoot $Workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath "iteration-units/$newId.json" -EventsPath 'iteration-events.jsonl' `
        -TargetState $targetState -TargetUnit $active -Event $event -ExpectedStateSha256 (Get-FixtureCanonicalJsonSha256 $state) -ExpectedUnitSha256 (Get-FixtureCanonicalJsonSha256 $ready) `
        -ExpectedEventTailId ([string]$tail.event_id) -ExpectedEventsSha256 (Get-FixtureFileSha256 $eventsPath) -ExpectedEventsLength ([IO.FileInfo]::new($eventsPath).Length) `
        -ExpectedSupersededUnitSha256 (Get-FixtureCanonicalJsonSha256 $old)|Out-Null
    [pscustomobject][ordered]@{event_id=$eventId;old_id=$oldId;new_id=$newId}
}

function Add-OwnerActiveWriteScopeAmendment {
    param([string]$Workspace, [string]$UnitId, [string]$Timestamp)
    $projectPath = Join-Path $Workspace 'project.spec.json'
    $statePath = Join-Path $Workspace 'workspace.state.json'
    $unitPath = Join-Path $Workspace "iteration-units\$UnitId.json"
    $eventsPath = Join-Path $Workspace 'iteration-events.jsonl'
    $project = Read-FixtureJson -Path $projectPath
    $state = Read-FixtureJson -Path $statePath
    $unit = Read-FixtureJson -Path $unitPath
    $eventTail = ConvertFrom-FixtureJsonText -Text ([string](Get-Content -LiteralPath $eventsPath | Where-Object { $_ } | Select-Object -Last 1)) -Context 'fixture active-write-scope event tail'
    $repository = @($unit.allowed_repositories | Where-Object { [string]$_.repo_id -ceq 'fixture-source' })
    if ($repository.Count -ne 1) { throw 'Owner amendment fixture lacks its exact source repository.' }
    $before = @($repository[0].allowed_paths)
    $after = @(@($before) + 'docs/')
    $amendmentId = "$UnitId-add-docs"
    $amendment = [pscustomobject][ordered]@{
        '$schema' = 'https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/active-write-scope-amendment-v1.schema.json'
        schema = 'rusty.morphospace.workflow.active_write_scope_amendment.v1'
        amendment_id = $amendmentId
        project_id = $projectId
        unit_id = $UnitId
        repository_id = 'fixture-source'
        reason = 'Exercise the owner-authenticated active write-scope continuation after a historical blocked replacement.'
        expected = [pscustomobject][ordered]@{
            status = 'active'
            current_unit = $UnitId
            project_revision = [int]$project.revision
            project_sha256 = Get-FixtureCanonicalJsonSha256 -Value $project
            state_sha256 = Get-FixtureCanonicalJsonSha256 -Value $state
            unit_sha256 = Get-FixtureCanonicalJsonSha256 -Value $unit
            events_sha256 = Get-FixtureFileSha256 -Path $eventsPath
            events_length = [IO.FileInfo]::new($eventsPath).Length
            event_tail_id = [string]$eventTail.event_id
        }
        before_allowed_paths = @($before)
        after_allowed_paths = @($after)
        does_not_prove = @('Does not accept the blocked replacement or authorize product, device, remote, or publication work.')
    }
    $inputPath = Join-Path $testRoot "$amendmentId-input.json"
    $outPath = Join-Path $Workspace "receipts\$amendmentId.json"
    Write-FixtureJson -Path $inputPath -Value $amendment
    $inputHash = Get-FixtureFileSha256 -Path $inputPath
    $dry = & $script:fixtureAmendmentModule.ExportedCommands['Invoke-MorphospaceAmendActiveWriteScope'] -WorkspaceRoot $Workspace -UnitId $UnitId -ActiveWriteScopeAmendment $inputPath -OutPath $outPath -Timestamp $Timestamp
    if ($dry.executed) { throw 'Owner amendment fixture dry run unexpectedly executed.' }
    $result = & $script:fixtureAmendmentModule.ExportedCommands['Invoke-MorphospaceAmendActiveWriteScope'] -WorkspaceRoot $Workspace -UnitId $UnitId -ActiveWriteScopeAmendment $inputPath -ExpectedActiveWriteScopeAmendmentSha256 $inputHash -OutPath $outPath -Timestamp $Timestamp -Execute
    if (-not $result.executed) { throw 'Owner amendment fixture did not execute.' }
    return [string]$result.event_id
}

function Add-OwnerProjectionContinuation {
    param(
        [string]$Workspace,
        [string]$UnitId,
        [string]$EventId,
        [string]$Timestamp,
        [switch]$TwoProjectionAnchor,
        [switch]$AdvanceProjectProjection,
        [switch]$RawBound,
        [switch]$RawPreimages
    )
    if ($TwoProjectionAnchor -eq $AdvanceProjectProjection) { throw 'Owner projection fixture requires exactly one continuation mode.' }
    if ($RawBound -and $RawPreimages) { throw 'Owner projection fixture may select only one raw-binding version.' }
    $statePath = Join-Path $Workspace 'workspace.state.json'
    $unitPath = Join-Path $Workspace "iteration-units\$UnitId.json"
    $eventsPath = Join-Path $Workspace 'iteration-events.jsonl'
    $state = Read-FixtureJson -Path $statePath
    $unit = Read-FixtureJson -Path $unitPath
    $tail = ConvertFrom-FixtureJsonText -Text ([string](Get-Content -LiteralPath $eventsPath | Where-Object { $_ } | Select-Object -Last 1)) -Context 'fixture projection event tail'
    $targetState = Copy-FixtureValue $state
    $targetState.last_event_id = $EventId
    $targetUnit = Copy-FixtureValue $unit
    $requests = [Collections.Generic.List[object]]::new()
    if ($TwoProjectionAnchor) {
        foreach ($relativePath in @('feature.lock.json','project.spec.json')) {
            $document = Read-FixtureProtocolJson -Path (Join-Path $Workspace $relativePath)
            $requests.Add([pscustomobject][ordered]@{
                path = $relativePath
                expected_sha256 = Get-FixtureCanonicalJsonSha256 -Value $document
                document = $document
            }) | Out-Null
        }
    } else {
        $relativePath = 'project.spec.json'
        $current = Read-FixtureProtocolJson -Path (Join-Path $Workspace $relativePath)
        $target = Copy-FixtureValue $current
        $target.purpose = 'Neutral blocked-history fixture with an authenticated chained project projection.'
        $requests.Add([pscustomobject][ordered]@{
            path = $relativePath
            expected_sha256 = Get-FixtureCanonicalJsonSha256 -Value $current
            document = $target
        }) | Out-Null
    }
    $event = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = $EventId
        sequence = [int]$tail.sequence + 1
        timestamp = $Timestamp
        project_id = $projectId
        unit_id = $UnitId
        event_type = 'state-transition'
        summary = if ($TwoProjectionAnchor) { 'Owner-authenticated the exact feature-lock and project-spec projections without changing their bytes.' } else { 'Owner-authenticated a chained project-spec projection advance from its prior target.' }
        receipts = @()
    }
    $rawBinding = @{}
    if ($RawPreimages) {
        $rawBinding.ExpectedPreStateRawSha256 = Get-FixtureFileSha256 -Path $statePath
        $rawBinding.ExpectedPreUnitRawSha256 = Get-FixtureFileSha256 -Path $unitPath
        foreach ($request in $requests) {
            $request | Add-Member -NotePropertyName expected_raw_sha256 -NotePropertyValue (Get-FixtureFileSha256 -Path (Join-Path $Workspace ([string]$request.path)))
        }
    } elseif ($RawBound) {
        $rawBinding.ExpectedPreUnitRawSha256 = Get-FixtureFileSha256 -Path $unitPath
    }
    Start-FixtureTransitionLedger `
        -WorkspaceRoot $Workspace `
        -TransactionId "$EventId-transition" `
        -StatePath 'workspace.state.json' `
        -UnitPath "iteration-units/$UnitId.json" `
        -EventsPath 'iteration-events.jsonl' `
        -TargetState $targetState `
        -TargetUnit $targetUnit `
        -Event $event `
        -ExpectedPreStateSha256 (Get-FixtureCanonicalJsonSha256 -Value $state) `
        -ExpectedPreUnitSha256 (Get-FixtureCanonicalJsonSha256 -Value $unit) `
        -ExpectedEventTailId ([string]$tail.event_id) `
        -ExpectedEventsSha256 (Get-FixtureFileSha256 -Path $eventsPath) `
        -ExpectedEventsLength ([IO.FileInfo]::new($eventsPath).Length) `
        -AdditionalProjections @($requests.ToArray()) `
        @rawBinding | Out-Null
    return $EventId
}

function Add-OwnerRawArtifactContinuation {
    param(
        [string]$Workspace,
        [string]$UnitId,
        [string]$EventId,
        [string]$Timestamp
    )
    $statePath = Join-Path $Workspace 'workspace.state.json'
    $unitPath = Join-Path $Workspace "iteration-units\$UnitId.json"
    $eventsPath = Join-Path $Workspace 'iteration-events.jsonl'
    $state = Read-FixtureJson -Path $statePath
    $unit = Read-FixtureJson -Path $unitPath
    $tail = ConvertFrom-FixtureJsonText -Text ([string](Get-Content -LiteralPath $eventsPath | Where-Object { $_ } | Select-Object -Last 1)) -Context 'fixture raw-artifact event tail'
    $targetState = Copy-FixtureValue $state
    $targetState.last_event_id = $EventId
    $targetUnit = Copy-FixtureValue $unit
    $receiptBytes = $encoding.GetBytes("owner-authenticated raw-artifact receipt`n")
    $sourceBytes = $encoding.GetBytes("owner-authenticated raw-artifact source composition`n")
    $artifacts = @(
        [pscustomobject][ordered]@{ bytes_base64 = [Convert]::ToBase64String($receiptBytes); path = 'receipts/later-current-owner-raw-artifact.json'; sha256 = Get-FixtureSha256Bytes -Bytes $receiptBytes },
        [pscustomobject][ordered]@{ bytes_base64 = [Convert]::ToBase64String($sourceBytes); path = 'source-composition/later-current-owner-raw-artifact.json'; sha256 = Get-FixtureSha256Bytes -Bytes $sourceBytes }
    )
    $event = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = $EventId
        sequence = [int]$tail.sequence + 1
        timestamp = $Timestamp
        project_id = $projectId
        unit_id = $UnitId
        event_type = 'state-transition'
        summary = 'Owner-authenticated exact raw unit bytes and two immutable event artifacts without changing the unit projection.'
        receipts = @($artifacts.path)
    }
    Start-FixtureTransitionLedger `
        -WorkspaceRoot $Workspace `
        -TransactionId "$EventId-transition" `
        -StatePath 'workspace.state.json' `
        -UnitPath "iteration-units/$UnitId.json" `
        -EventsPath 'iteration-events.jsonl' `
        -TargetState $targetState `
        -TargetUnit $targetUnit `
        -Event $event `
        -ExpectedPreStateSha256 (Get-FixtureCanonicalJsonSha256 -Value $state) `
        -ExpectedPreUnitSha256 (Get-FixtureCanonicalJsonSha256 -Value $unit) `
        -ExpectedPreUnitRawSha256 (Get-FixtureFileSha256 -Path $unitPath) `
        -ExpectedEventTailId ([string]$tail.event_id) `
        -ExpectedEventsSha256 (Get-FixtureFileSha256 -Path $eventsPath) `
        -ExpectedEventsLength ([IO.FileInfo]::new($eventsPath).Length) `
        -Artifacts $artifacts | Out-Null
    return $EventId
}

if ($RematerializationV6Only) {
    $blockedModuleSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\MorphospaceBlockedSupersessionTerminalValidation.psm1'))
    if (-not $blockedModuleSource.Contains("'schemas\candidate-freeze-v1.schema.json'", [StringComparison]::Ordinal) -or
        $blockedModuleSource.Contains("'schemas\candidate-freeze.schema.json'", [StringComparison]::Ordinal)) {
        throw 'The targeted blocked-history validator does not bind the exact candidate-freeze v1 schema path.'
    }
    Invoke-Expression (Import-RematerializationV6FixtureDefinitions)
    $targetedFixture = New-RematerializationFixture 'blocked-history-v6'
    try {
        $priorState = Read-FixtureProtocolJson $targetedFixture.state_path
        $priorUnit = Read-FixtureProtocolJson $targetedFixture.unit_path
        $priorStateSha256 = Get-FixtureCanonicalJsonSha256 $priorState
        $priorUnitSha256 = Get-FixtureCanonicalJsonSha256 $priorUnit
        $candidateSha256 = Get-FixtureFileSha256 $targetedFixture.candidate_path
        $executed = & $script:fixtureRematerializationModule.ExportedCommands['Invoke-MorphospaceRematerializeValidatingCandidate'] -WorkspaceRoot $targetedFixture.workspace -UnitId 'unit-remat-001' `
            -CandidateFreeze $targetedFixture.candidate_path -SourceCompositionLock $targetedFixture.source_lock_path `
            -RepoMapPath $targetedFixture.map_path -OutPath $targetedFixture.out_path -ExpectedCandidateFreezeSha256 $candidateSha256 `
            -Timestamp '2026-09-02T00:02:00.0000000Z' -Execute
        if (-not $executed.executed -or [string]$executed.transition -cne 'validating-candidate-rematerialized') {
            throw 'The targeted fixture did not execute the real validating-candidate rematerialization action.'
        }
        $eventId = "rematerialize-blocked-history-v6-recorded"
        $transition = Get-RematerializationV6Transition -Workspace $targetedFixture.workspace -EventId $eventId -PriorStateSha256 $priorStateSha256 -PriorUnitSha256 $priorUnitSha256
        Test-RematerializationV6TransitionDirect -Workspace $targetedFixture.workspace -Transition $transition -PriorState $priorState -PriorStateSha256 $priorStateSha256 -PriorUnit $priorUnit -PriorUnitSha256 $priorUnitSha256

        Assert-RematerializationV6DirectRejects $targetedFixture.workspace $transition $priorState $priorStateSha256 $priorUnit $priorUnitSha256 `
            { param($t) $t.event.summary = 'A near-miss generic v6 continuation.' } 'not the exact validating-candidate rematerialization action'
        Assert-RematerializationV6DirectRejects $targetedFixture.workspace $transition $priorState $priorStateSha256 $priorUnit $priorUnitSha256 `
            { param($t) $t.unit_document.status = 'active' } 'does not preserve the validating captain'
        Assert-RematerializationV6DirectRejects $targetedFixture.workspace $transition $priorState $priorStateSha256 $priorUnit $priorUnitSha256 `
            { param($t) $t.unit_document.objective = 'forged scope expansion' } 'changed the unit outside exact source/freeze replacement'
        Assert-RematerializationV6DirectRejects $targetedFixture.workspace $transition $priorState $priorStateSha256 $priorUnit $priorUnitSha256 `
            { param($t) $t.state_document.last_accepted_receipt = 'receipts/forged.json' } 'changed state outside event tail, selector invalidation, and exact repository-head projection'
        Assert-RematerializationV6DirectRejects $targetedFixture.workspace $transition $priorState $priorStateSha256 $priorUnit $priorUnitSha256 `
            { param($t) $t.state_document.normal_validation_selection = $t.intent.target.state.document.normal_validation_selection = $t.event.receipts[0] } 'does not preserve the validating captain'
        Assert-RematerializationV6DirectRejects $targetedFixture.workspace $transition $priorState $priorStateSha256 $priorUnit $priorUnitSha256 `
            { param($t) $t.intent.artifacts = @($t.intent.artifacts[1],$t.intent.artifacts[0]); $t.event.receipts = @($t.event.receipts[1],$t.event.receipts[0]) } 'artifacts and receipts are not ordinal sorted'

        [pscustomobject][ordered]@{
            schema = 'rusty.morphospace.workflow.blocked_supersession_rematerialization_v6_targeted_test.v1'
            result = 'pass'
            real_action_executed = $true
            exact_damage_cases = 6
            generic_v6_fixture_preserved = $true
            build_or_device_used = $false
        } | ConvertTo-Json -Compress
    } finally {
        if ($null -ne $targetedFixture -and [IO.Directory]::Exists($targetedFixture.root)) {
            Get-ChildItem -LiteralPath $targetedFixture.root -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) } catch {} }
            Remove-Item -LiteralPath $targetedFixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return
}

try {
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'src')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'docs')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'rusty-morphospace')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'system-engineering')) | Out-Null
    & git -C $sourceRoot init -b main | Out-Null
    & git -C $sourceRoot config user.name 'Neutral Fixture'
    & git -C $sourceRoot config user.email 'fixture@example.invalid'
    & git -C $sourceRoot config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'src\seed.txt'), "seed`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'docs\seed.md'), "# Neutral fixture documentation`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'AGENTS.md'), "# Neutral fixture instructions`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'README.md'), "# Neutral fixture router`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'rusty-morphospace\SKILL.md'), "# Neutral Morphospace fixture skill`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'system-engineering\SKILL.md'), "# Neutral system fixture skill`n", $encoding)
    Invoke-FixtureGit @('add','src/seed.txt','docs/seed.md','AGENTS.md','README.md','rusty-morphospace/SKILL.md','system-engineering/SKILL.md') | Out-Null
    Invoke-FixtureGit @('commit','-m','fixture seed') | Out-Null

    [IO.Directory]::CreateDirectory($planningRoot) | Out-Null
    & (Join-Path $PSScriptRoot 'New-ProjectWorkspace.ps1') -ProjectRoot $planningRoot -ProjectId $projectId -Purpose 'Neutral blocked-supersession terminal history fixture.' -SchemaRevision ((git -C $RepoRoot rev-parse HEAD).Trim()) -Execute | Out-Null
    $specPath = Join-Path $workspace 'project.spec.json'
    $spec = Read-FixtureJson -Path $specPath
    $spec.owner = 'fixture-owner'
    $spec.repositories = @([pscustomobject][ordered]@{ repo_id = 'fixture-source'; role = 'tool'; path = '<repository-map:fixture-source>'; allowed_paths = @('src/', 'docs/', 'AGENTS.md', 'README.md', 'rusty-morphospace/SKILL.md', 'system-engineering/SKILL.md') })
    $spec.validation_profiles = @([pscustomobject][ordered]@{ profile_id = 'workflow'; commands = @('Run the neutral workflow fixture.') })
    $spec.acceptance_profiles = @([pscustomobject][ordered]@{ profile_id = 'rollback'; commands = @('Discard the temporary fixture.') })
    $spec.release_policy.push_checkpoint = 'local-only'
    Write-FixtureJson -Path $specPath -Value $spec

    Write-FixtureJson -Path (Join-Path $workspace "iteration-units\$oldUnitId.json") -Value (New-FixtureUnit -UnitId $oldUnitId -Status 'active')
    $readyReplacement = New-FixtureUnit -UnitId $replacementUnitId -Status 'ready'
    Write-FixtureJson -Path (Join-Path $workspace "iteration-units\$replacementUnitId.json") -Value $readyReplacement
    $statePath = Join-Path $workspace 'workspace.state.json'
    $state = Read-FixtureJson -Path $statePath
    $state.current_unit = $oldUnitId
    $state.next_ready_unit = $replacementUnitId
    $state.last_event_id = $null
    Write-FixtureJson -Path $statePath -Value $state
    $producerTemplate = Copy-FixtureWorkspace -Source $workspace -Name 'producer-before-supersession'
    $supersessionEvent = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = $supersessionEventId
        sequence = 1
        timestamp = '2026-01-02T03:03:00.0000000Z'
        project_id = $projectId
        unit_id = $oldUnitId
        event_type = 'state-transition'
        summary = 'The replacement additively supersedes immutable in-flight predecessor state.'
        receipts = @()
    }
    $activeReplacement = Copy-FixtureValue $readyReplacement
    $activeReplacement.status = 'active'
    $supersessionTargetState = Copy-FixtureValue $state
    $supersessionTargetState.current_unit = $replacementUnitId
    $supersessionTargetState.next_ready_unit = $null
    $supersessionTargetState.last_event_id = $supersessionEventId
    Start-FixtureTransitionLedger `
        -WorkspaceRoot $workspace `
        -TransactionId "$supersessionEventId-transition" `
        -StatePath 'workspace.state.json' `
        -UnitPath "iteration-units/$replacementUnitId.json" `
        -EventsPath 'iteration-events.jsonl' `
        -TargetState $supersessionTargetState `
        -TargetUnit $activeReplacement `
        -Event $supersessionEvent | Out-Null
    Write-FixtureJson -Path $repoMapPath -Value ([pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.repository_map.v1'
        repositories = @([pscustomobject][ordered]@{ repo_id = 'fixture-source'; path = $sourceRoot; role = 'source'; aliases = @('repo-root', 'skills-root') })
    })

    $activeWorkspace = Copy-FixtureWorkspace -Source $workspace -Name 'positive-existing-active'
    Invoke-WorkflowContract -Workspace $activeWorkspace | Out-Null
    Assert-Passed $true 'existing-active-replacement'

    Invoke-OwnerAction -Workspace $workspace -Action BeginValidation -UnitId $replacementUnitId -Timestamp '2026-01-02T03:04:00.0000000Z'
    $validatingWorkspace = Copy-FixtureWorkspace -Source $workspace -Name 'positive-existing-validating'
    Invoke-WorkflowContract -Workspace $validatingWorkspace | Out-Null
    Assert-Passed $true 'existing-validating-replacement'

    $acceptedWorkspace = Copy-FixtureWorkspace -Source $workspace -Name 'positive-existing-accepted'
    $acceptedReceipt = New-FixtureValidationReceipt -Workspace $acceptedWorkspace -UnitId $replacementUnitId -Result pass -Suffix pass
    Invoke-OwnerAction -Workspace $acceptedWorkspace -Action RecordValidation -UnitId $replacementUnitId -Timestamp '2026-01-02T03:05:00.0000000Z' -ValidationReceipt $acceptedReceipt -ValidationResult pass
    Invoke-OwnerAction -Workspace $acceptedWorkspace -Action Accept -UnitId $replacementUnitId -Timestamp '2026-01-02T03:06:00.0000000Z'
    Invoke-WorkflowContract -Workspace $acceptedWorkspace | Out-Null
    Assert-Passed $true 'existing-accepted-replacement'

    $failReceipt = New-FixtureValidationReceipt -Workspace $workspace -UnitId $replacementUnitId -Result fail -Suffix fail
    Invoke-OwnerAction -Workspace $workspace -Action RecordValidation -UnitId $replacementUnitId -Timestamp '2026-01-02T03:05:00.0000000Z' -ValidationReceipt $failReceipt -ValidationResult fail
    $baselineWorkspace = Copy-FixtureWorkspace -Source $workspace -Name 'positive-terminal-blocked'
    $events = @(Get-Content -LiteralPath (Join-Path $baselineWorkspace 'iteration-events.jsonl') | Where-Object { $_ } | ForEach-Object { ConvertFrom-FixtureJsonText -Text $_ -Context 'fixture baseline event' })
    $beginEventId = [string]$events[-2].event_id
    $failEventId = [string]$events[-1].event_id
    Assert-HelperPasses -Workspace $baselineWorkspace -Name 'exact-terminal-lifecycle-positive' -ContinuationCount 0
    Invoke-WorkflowContract -Workspace $baselineWorkspace | Out-Null
    Assert-Passed $true 'terminal-lifecycle-aggregate-integration'
    Invoke-ReceiptBearingProducerTerminalCases -Template $producerTemplate

    $laterActiveWorkspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-later-current'
    Add-LaterUnit -Workspace $laterActiveWorkspace
    Assert-HelperPasses -Workspace $laterActiveWorkspace -Name 'historical-later-current-positive' -ContinuationCount 2
    Invoke-WorkflowContract -Workspace $laterActiveWorkspace | Out-Null
    Assert-Passed $true 'historical-later-current-aggregate'

    $ownerV2Workspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-owner-v2-supersession-continuation'
    Add-LaterUnit -Workspace $ownerV2Workspace
    $ownerV2=Add-OwnerV2SupersessionContinuation -Workspace $ownerV2Workspace
    Assert-HelperPasses -Workspace $ownerV2Workspace -Name 'owner-produced-v2-supersession-continuation-positive' -ContinuationCount 4
    Invoke-WorkflowContract -Workspace $ownerV2Workspace | Out-Null
    Assert-Passed $true 'owner-produced-v2-supersession-continuation-aggregate'
    Assert-HelperRejects -Template $ownerV2Workspace -Name 'v2-continuation-missing-intent' -Mutation {param($case)Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$($ownerV2.event_id)-transition.intent.json")}
    Assert-HelperRejects -Template $ownerV2Workspace -Name 'v2-continuation-missing-completion' -Mutation {param($case)Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$($ownerV2.event_id)-transition.completion.json")}
    Assert-HelperRejects -Template $ownerV2Workspace -Name 'v2-continuation-unknown-property' -Mutation {
        param($case);Update-FixtureJson (Join-Path $case "receipts\transactions\$($ownerV2.event_id)-transition.intent.json") {param($i)$i|Add-Member -NotePropertyName unknown_v2_policy -NotePropertyValue 'forbidden'};Rebind-FixtureTransaction -Workspace $case -EventId $ownerV2.event_id
    }
    Assert-HelperRejects -Template $ownerV2Workspace -Name 'v2-continuation-endpoint-detachment' -Mutation {
        param($case);Update-FixtureJson (Join-Path $case "receipts\transactions\$($ownerV2.event_id)-transition.intent.json") {param($i)$i.supersession.old_unit_id='unrelated-owner'};Rebind-FixtureTransaction -Workspace $case -EventId $ownerV2.event_id
    }
    Assert-HelperRejects -Template $ownerV2Workspace -Name 'v2-continuation-status-inference' -Mutation {
        param($case);Update-FixtureJson (Join-Path $case "receipts\transactions\$($ownerV2.event_id)-transition.intent.json") {param($i)$i.target.unit.document.status='accepted'};Rebind-FixtureTransaction -Workspace $case -EventId $ownerV2.event_id
    }
    Assert-HelperRejects -Template $ownerV2Workspace -Name 'v2-continuation-state-inference' -Mutation {
        param($case);Update-FixtureJson (Join-Path $case "receipts\transactions\$($ownerV2.event_id)-transition.intent.json") {param($i)$i.target.state.document.last_accepted_receipt='receipts/fabricated.json'};Rebind-FixtureTransaction -Workspace $case -EventId $ownerV2.event_id
    }

    $laterAcceptedWorkspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-later-accepted'
    Add-LaterUnit -Workspace $laterAcceptedWorkspace -Accept
    Assert-HelperPasses -Workspace $laterAcceptedWorkspace -Name 'historical-later-accepted-positive' -ContinuationCount 5
    Invoke-WorkflowContract -Workspace $laterAcceptedWorkspace | Out-Null
    Assert-Passed $true 'historical-later-accepted-aggregate'

    $ownerAmendWorkspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-owner-active-write-scope-amendment'
    Add-LaterUnit -Workspace $ownerAmendWorkspace
    $ownerAmendEventId = Add-OwnerActiveWriteScopeAmendment -Workspace $ownerAmendWorkspace -UnitId 'later-current-owner' -Timestamp '2026-01-02T03:08:00.0000000Z'
    Assert-HelperPasses -Workspace $ownerAmendWorkspace -Name 'owner-active-write-scope-one-projection-positive' -ContinuationCount 3 -ProjectionCount 1
    Invoke-WorkflowContract -Workspace $ownerAmendWorkspace | Out-Null
    Assert-Passed $true 'owner-active-write-scope-one-projection-aggregate'
    $ownerAmendAcceptedWorkspace = Copy-FixtureWorkspace -Source $ownerAmendWorkspace -Name 'positive-owner-amendment-then-accepted'
    Invoke-OwnerAction -Workspace $ownerAmendAcceptedWorkspace -Action BeginValidation -UnitId 'later-current-owner' -Timestamp '2026-01-02T03:09:00.0000000Z'
    $ownerAmendPassReceipt = New-FixtureValidationReceipt -Workspace $ownerAmendAcceptedWorkspace -UnitId 'later-current-owner' -Result pass -Suffix post-v3-pass
    Invoke-OwnerAction -Workspace $ownerAmendAcceptedWorkspace -Action RecordValidation -UnitId 'later-current-owner' -Timestamp '2026-01-02T03:10:00.0000000Z' -ValidationReceipt $ownerAmendPassReceipt -ValidationResult pass
    Invoke-OwnerAction -Workspace $ownerAmendAcceptedWorkspace -Action Accept -UnitId 'later-current-owner' -Timestamp '2026-01-02T03:11:00.0000000Z'
    Assert-HelperPasses -Workspace $ownerAmendAcceptedWorkspace -Name 'owner-v3-then-later-accepted-positive' -ContinuationCount 6 -ProjectionCount 1
    Invoke-WorkflowContract -Workspace $ownerAmendAcceptedWorkspace | Out-Null
    Assert-Passed $true 'owner-v3-then-later-accepted-aggregate'

    $ownerProjectionWorkspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-owner-two-projection-chain'
    Add-LaterUnit -Workspace $ownerProjectionWorkspace
    $twoProjectionEventId = Add-OwnerProjectionContinuation -Workspace $ownerProjectionWorkspace -UnitId 'later-current-owner' -EventId 'later-current-owner-two-projection-anchor-recorded' -Timestamp '2026-01-02T03:08:00.0000000Z' -TwoProjectionAnchor
    Assert-HelperPasses -Workspace $ownerProjectionWorkspace -Name 'owner-produced-two-projection-positive' -ContinuationCount 3 -ProjectionCount 2
    Invoke-WorkflowContract -Workspace $ownerProjectionWorkspace | Out-Null
    Assert-Passed $true 'owner-produced-two-projection-aggregate'
    $projectionAdvanceEventId = Add-OwnerProjectionContinuation -Workspace $ownerProjectionWorkspace -UnitId 'later-current-owner' -EventId 'later-current-owner-project-projection-advance-recorded' -Timestamp '2026-01-02T03:09:00.0000000Z' -AdvanceProjectProjection
    Assert-HelperPasses -Workspace $ownerProjectionWorkspace -Name 'owner-produced-matching-projection-chain-positive' -ContinuationCount 4 -ProjectionCount 2
    Invoke-WorkflowContract -Workspace $ownerProjectionWorkspace | Out-Null
    Assert-Passed $true 'owner-produced-matching-projection-chain-aggregate'

    $ownerV4Workspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-owner-v4-projection-chain'
    Add-LaterUnit -Workspace $ownerV4Workspace
    $v4ProjectionEventId = Add-OwnerProjectionContinuation -Workspace $ownerV4Workspace -UnitId 'later-current-owner' -EventId 'later-current-owner-v4-two-projection-anchor-recorded' -Timestamp '2026-01-02T03:08:00.0000000Z' -TwoProjectionAnchor -RawBound
    Assert-HelperPasses -Workspace $ownerV4Workspace -Name 'owner-produced-v4-two-projection-positive' -ContinuationCount 3 -ProjectionCount 2
    $v4ProjectionAdvanceEventId = Add-OwnerProjectionContinuation -Workspace $ownerV4Workspace -UnitId 'later-current-owner' -EventId 'later-current-owner-v4-project-projection-advance-recorded' -Timestamp '2026-01-02T03:09:00.0000000Z' -AdvanceProjectProjection -RawBound
    Assert-HelperPasses -Workspace $ownerV4Workspace -Name 'owner-produced-v4-matching-projection-chain-positive' -ContinuationCount 4 -ProjectionCount 2
    Invoke-WorkflowContract -Workspace $ownerV4Workspace | Out-Null
    Assert-Passed $true 'owner-produced-v4-projection-chain-aggregate'
    Assert-HelperRejects -Template $ownerV4Workspace -Name 'v4-missing-raw-binding' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v4ProjectionEventId-transition.intent.json") { param($i) $i.PSObject.Properties.Remove('pre_unit_raw') }
        Rebind-FixtureTransaction -Workspace $case -EventId $v4ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV4Workspace -Name 'v4-raw-binding-unknown-field' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v4ProjectionEventId-transition.intent.json") { param($i) $i.pre_unit_raw | Add-Member -NotePropertyName policy -NotePropertyValue 'forbidden' }
        Rebind-FixtureTransaction -Workspace $case -EventId $v4ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV4Workspace -Name 'v4-raw-binding-path-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v4ProjectionEventId-transition.intent.json") { param($i) $i.pre_unit_raw.path = "iteration-units/$replacementUnitId.json" }
        Rebind-FixtureTransaction -Workspace $case -EventId $v4ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV4Workspace -Name 'v4-raw-binding-noncanonical-sha' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v4ProjectionEventId-transition.intent.json") { param($i) $i.pre_unit_raw.sha256 = ([string]$i.pre_unit_raw.sha256).ToUpperInvariant() }
        Rebind-FixtureTransaction -Workspace $case -EventId $v4ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV4Workspace -Name 'v4-unknown-intent-property' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v4ProjectionEventId-transition.intent.json") { param($i) $i | Add-Member -NotePropertyName unknown_v4_policy -NotePropertyValue 'forbidden' }
        Rebind-FixtureTransaction -Workspace $case -EventId $v4ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV4Workspace -Name 'v4-acceptance-inference' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v4ProjectionEventId-transition.intent.json") { param($i) $i.target.state.document.last_accepted_receipt = 'receipts/fabricated-v4-acceptance.json' }
        Rebind-FixtureTransaction -Workspace $case -EventId $v4ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV4Workspace -Name 'v4-chained-projection-preimage-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v4ProjectionAdvanceEventId-transition.intent.json") { param($i) $i.additional_projections[0].pre_sha256 = ('c' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $v4ProjectionAdvanceEventId
    }

    $ownerV6Workspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-owner-v6-projection-chain'
    Add-LaterUnit -Workspace $ownerV6Workspace
    $v6ProjectionEventId = Add-OwnerProjectionContinuation -Workspace $ownerV6Workspace -UnitId 'later-current-owner' -EventId 'later-current-owner-v6-two-projection-anchor-recorded' -Timestamp '2026-01-02T03:08:00.0000000Z' -TwoProjectionAnchor -RawPreimages
    Assert-HelperPasses -Workspace $ownerV6Workspace -Name 'owner-produced-v6-two-projection-positive' -ContinuationCount 3 -ProjectionCount 2
    $v6ProjectionAdvanceEventId = Add-OwnerProjectionContinuation -Workspace $ownerV6Workspace -UnitId 'later-current-owner' -EventId 'later-current-owner-v6-project-projection-advance-recorded' -Timestamp '2026-01-02T03:09:00.0000000Z' -AdvanceProjectProjection -RawPreimages
    Assert-HelperPasses -Workspace $ownerV6Workspace -Name 'owner-produced-v6-matching-projection-chain-positive' -ContinuationCount 4 -ProjectionCount 2
    Invoke-WorkflowContract -Workspace $ownerV6Workspace | Out-Null
    Assert-Passed $true 'owner-produced-v6-projection-chain-aggregate'
    Assert-HelperRejects -Template $ownerV6Workspace -Name 'v6-missing-raw-state-binding' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v6ProjectionEventId-transition.intent.json") { param($i) $i.PSObject.Properties.Remove('pre_state_raw') }
        Rebind-FixtureTransaction -Workspace $case -EventId $v6ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV6Workspace -Name 'v6-raw-state-path-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v6ProjectionEventId-transition.intent.json") { param($i) $i.pre_state_raw.path = 'project.spec.json' }
        Rebind-FixtureTransaction -Workspace $case -EventId $v6ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV6Workspace -Name 'v6-raw-state-noncanonical-sha' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v6ProjectionEventId-transition.intent.json") { param($i) $i.pre_state_raw.sha256 = ([string]$i.pre_state_raw.sha256).ToUpperInvariant() }
        Rebind-FixtureTransaction -Workspace $case -EventId $v6ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV6Workspace -Name 'v6-missing-projection-raw-binding' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v6ProjectionEventId-transition.intent.json") { param($i) $i.additional_projections[0].PSObject.Properties.Remove('pre_raw_sha256') }
        Rebind-FixtureTransaction -Workspace $case -EventId $v6ProjectionEventId
    }
    Assert-HelperRejects -Template $ownerV6Workspace -Name 'v6-projection-raw-noncanonical-sha' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v6ProjectionAdvanceEventId-transition.intent.json") { param($i) $i.additional_projections[0].pre_raw_sha256 = ([string]$i.additional_projections[0].pre_raw_sha256).ToUpperInvariant() }
        Rebind-FixtureTransaction -Workspace $case -EventId $v6ProjectionAdvanceEventId
    }

    $ownerV5Workspace = Copy-FixtureWorkspace -Source $baselineWorkspace -Name 'positive-owner-v5-raw-artifact-continuation'
    Add-LaterUnit -Workspace $ownerV5Workspace
    $v5EventId = Add-OwnerRawArtifactContinuation -Workspace $ownerV5Workspace -UnitId 'later-current-owner' -EventId 'later-current-owner-raw-artifact-recorded' -Timestamp '2026-01-02T03:08:00.0000000Z'
    Assert-HelperPasses -Workspace $ownerV5Workspace -Name 'owner-produced-v5-raw-artifact-positive' -ContinuationCount 3 -ProjectionCount 0
    Invoke-WorkflowContract -Workspace $ownerV5Workspace | Out-Null
    Assert-Passed $true 'owner-produced-v5-raw-artifact-aggregate'
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-missing-raw-binding' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i.PSObject.Properties.Remove('pre_unit_raw') }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-raw-binding-path-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i.pre_unit_raw.path = "iteration-units/$replacementUnitId.json" }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-raw-binding-noncanonical-sha' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i.pre_unit_raw.sha256 = ([string]$i.pre_unit_raw.sha256).ToUpperInvariant() }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-stray-additional-projection' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i | Add-Member -NotePropertyName additional_projections -NotePropertyValue @() }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-unit-target-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i.target.unit.document.objective = 'forged changed unit target' }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-state-change-beyond-event-tail' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i.target.state.document.last_accepted_receipt = 'receipts/forged-v5-acceptance.json' }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-zero-artifacts' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i.artifacts = @(); $i.event.receipts = @() }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-misordered-artifacts' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i.artifacts = @($i.artifacts[1], $i.artifacts[0]) }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-event-receipt-mismatch' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i.event.receipts[0] = 'receipts/not-the-bound-artifact.json' }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-live-artifact-drift' -Mutation {
        param($case)
        [IO.File]::WriteAllText((Join-Path $case 'receipts\later-current-owner-raw-artifact.json'), "drifted raw-artifact receipt`n", $encoding)
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-chain-preimage-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$v5EventId-transition.intent.json") { param($i) $i.pre.state.sha256 = ('c' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $v5EventId
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-reserved-supersession-delimiter' -Mutation {
        param($case)
        Rewrite-FixtureTransactionEventIdentity -Workspace $case -OldEventId $v5EventId -NewEventId 'later-current-owner-superseded-by-forbidden'
    }
    Assert-HelperRejects -Template $ownerV5Workspace -Name 'v5-reserved-proposed-retirement' -Mutation {
        param($case)
        Rewrite-FixtureTransactionEventIdentity -Workspace $case -OldEventId $v5EventId -NewEventId 'later-current-owner-proposal-retired-0001'
    }

    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-missing-projection-set' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") { param($i) $i.PSObject.Properties.Remove('additional_projections') }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-extra-projection' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") {
            param($i)
            $i.additional_projections = @($i.additional_projections[0], $i.additional_projections[1], $i.additional_projections[1])
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-unknown-intent-property' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") { param($i) $i | Add-Member -NotePropertyName unknown_projection_policy -NotePropertyValue 'forbidden' }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v4-substitution-without-raw-binding' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") { param($i) $i.schema = 'rusty.morphospace.workflow.transition_ledger_intent.v4' }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v5-substitution-with-projection-shape' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") { param($i) $i.schema = 'rusty.morphospace.workflow.transition_ledger_intent.v5' }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-duplicate-projection' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") {
            param($i)
            $i.additional_projections[1].path = [string]$i.additional_projections[0].path
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-out-of-order-projections' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") {
            param($i)
            $i.additional_projections = @($i.additional_projections[1], $i.additional_projections[0])
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-unauthorized-projection' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") { param($i) $i.additional_projections[0].path = 'unauthorized.json' }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-projection-preimage-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") { param($i) $i.additional_projections[0].pre_sha256 = ('8' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-projection-target-hash-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") { param($i) $i.additional_projections[1].target_sha256 = ('9' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-projection-document-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") { param($i) $i.additional_projections[1].document.purpose = 'Detached embedded project document.' }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-live-projection-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case 'project.spec.json') { param($p) $p.purpose = 'Untransactional live project drift.' }
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-ledger-predecessor-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.intent.json") { param($i) $i.expected.event_tail_id = $failEventId }
        Rebind-FixtureTransaction -Workspace $case -EventId $twoProjectionEventId
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-completion-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$twoProjectionEventId-transition.completion.json") { param($c) $c.intent.sha256 = ('a' * 64) }
    }
    Assert-HelperRejects -Template $ownerProjectionWorkspace -Name 'v3-chained-projection-preimage-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$projectionAdvanceEventId-transition.intent.json") { param($i) $i.additional_projections[0].pre_sha256 = ('b' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $projectionAdvanceEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-missing-event-receipt-artifact' -ExpectedMessage 'event receipts do not exactly match its artifact targets' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") { param($i) $i.artifacts = @() }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-malformed-artifact-base64' -ExpectedMessage 'has invalid base64 bytes' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") { param($i) $i.artifacts[0].bytes_base64 = 'not-base64!' }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-noncanonical-artifact-base64' -ExpectedMessage 'base64 bytes are not canonical' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") { param($i) $i.artifacts[0].bytes_base64 = ([string]$i.artifacts[0].bytes_base64) + "`n" }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-duplicate-artifact-path' -ExpectedMessage 'repeats an artifact target path' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") {
            param($i)
            $duplicate = Copy-FixtureValue $i.artifacts[0]
            $i.artifacts = @($i.artifacts[0], $duplicate)
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-case-alias-duplicate-artifact-path' -ExpectedMessage 'repeats an artifact target path' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") {
            param($i)
            $duplicate = Copy-FixtureValue $i.artifacts[0]
            $duplicate.path = 'Receipts/' + ([string]$duplicate.path).Substring('receipts/'.Length)
            $i.artifacts = @($i.artifacts[0], $duplicate)
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-case-alias-duplicate-artifact-path-reverse' -ExpectedMessage 'repeats an artifact target path' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") {
            param($i)
            $original = Copy-FixtureValue $i.artifacts[0]
            $alias = Copy-FixtureValue $original
            $alias.path = 'Receipts/' + ([string]$alias.path).Substring('receipts/'.Length)
            $i.artifacts = @($alias, $original)
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-unique-missing-live-artifact' -ExpectedMessage 'Workspace artifact is missing' -Mutation {
        param($case)
        Remove-Item -LiteralPath (Join-Path $case 'receipts\later-current-owner-add-docs.json') -Force
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-embedded-artifact-hash-drift' -ExpectedMessage 'embedded-byte hash drifted' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") {
            param($i)
            $i.artifacts[0].bytes_base64 = [Convert]::ToBase64String($encoding.GetBytes('substituted embedded artifact'))
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-substituted-embedded-artifact' -ExpectedMessage 'live artifact bytes drifted' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") {
            param($i)
            $bytes = $encoding.GetBytes('coherently substituted embedded artifact')
            $i.artifacts[0].bytes_base64 = [Convert]::ToBase64String($bytes)
            $i.artifacts[0].sha256 = Get-FixtureSha256Bytes -Bytes $bytes
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-live-artifact-drift' -ExpectedMessage 'live artifact bytes drifted' -Mutation {
        param($case)
        [IO.File]::AppendAllText((Join-Path $case 'receipts\later-current-owner-add-docs.json'), "substituted`n", $encoding)
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-state-projection-inference' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") { param($i) $i.target.state.document.plan_revision = [int]$i.target.state.document.plan_revision + 1 }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-unit-status-inference' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") { param($i) $i.target.unit.document.status = 'accepted' }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $ownerAmendWorkspace -Name 'v3-acceptance-inference' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$ownerAmendEventId-transition.intent.json") { param($i) $i.target.state.document.last_accepted_receipt = 'receipts/fabricated-acceptance.json' }
        Rebind-FixtureTransaction -Workspace $case -EventId $ownerAmendEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'v3-wrongly-substituted-for-supersession' -Mutation {
        param($case)
        $intentPath = Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json"
        Update-FixtureJson $intentPath {
            param($i)
            $i.schema = 'rusty.morphospace.workflow.transition_ledger_intent.v3'
            $i.PSObject.Properties.Remove('supersession')
            $project = Read-FixtureProtocolJson -Path (Join-Path $case 'project.spec.json')
            $projectHash = Get-FixtureCanonicalJsonSha256 -Value $project
            $i | Add-Member -NotePropertyName additional_projections -NotePropertyValue @([pscustomobject][ordered]@{ path = 'project.spec.json'; pre_sha256 = $projectHash; target_sha256 = $projectHash; document = $project })
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $supersessionEventId
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.completion.json") { param($c) $c.intent.schema = 'rusty.morphospace.workflow.transition_ledger_intent.v3' }
    }

    Assert-WorkflowRejects -Template $activeWorkspace -Name 'arbitrary-blocked-without-chain' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "iteration-units\$replacementUnitId.json") { param($u) $u.status = 'blocked' }
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.current_unit = $null }
    }
    Assert-WorkflowRejects -Template $activeWorkspace -Name 'legacy-or-unrelated-blocked-replacement' -Mutation {
        param($case)
        $unrelatedId = 'legacy-unrelated-owner'
        Write-FixtureJson -Path (Join-Path $case "iteration-units\$unrelatedId.json") -Value (New-FixtureUnit -UnitId $unrelatedId -Status 'blocked')
        Update-FixtureLedgerEvent -Workspace $case -EventId $supersessionEventId -Mutation { param($e) $e.event_id = "$oldUnitId-superseded-by-$unrelatedId" }
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.current_unit = $null; $s.last_event_id = "$oldUnitId-superseded-by-$unrelatedId" }
    }
    Assert-WorkflowRejects -Template $baselineWorkspace -Name 'manual-supersession-event-without-owner-transaction' -Mutation {
        param($case)
        Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json")
        Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$supersessionEventId-transition.completion.json")
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-supersession-intent' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-supersession-completion' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$supersessionEventId-transition.completion.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-intent-link-mismatch' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.completion.json") { param($c) $c.intent.sha256 = ('3' * 64) }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-completion-target-mismatch' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.completion.json") { param($c) $c.state_sha256 = ('4' * 64) }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-old-unit-binding-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") {
            param($i)
            $i.supersession.old_unit.document.objective = 'Drifted old-unit binding.'
            $i.supersession.old_unit.sha256 = Get-FixtureCanonicalJsonSha256 -Value $i.supersession.old_unit.document
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $supersessionEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-pre-state-identity-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") {
            param($i)
            $i.supersession.pre_state.document.current_unit = 'unrelated-owner'
            $newHash = Get-FixtureCanonicalJsonSha256 -Value $i.supersession.pre_state.document
            $i.supersession.pre_state.sha256 = $newHash
            $i.pre.state.sha256 = $newHash
            $i.expected.state_sha256 = $newHash
        }
        Rebind-FixtureTransaction -Workspace $case -EventId $supersessionEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-target-identity-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") { param($i) $i.target.state.document.current_unit = $oldUnitId }
        Rebind-FixtureTransaction -Workspace $case -EventId $supersessionEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-ledger-prefix-drift' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$supersessionEventId-transition.intent.json") { param($i) $i.expected.events_sha256 = ('5' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $supersessionEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-target-to-begin-state-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$beginEventId-transition.intent.json") { param($i) $i.pre.state.sha256 = ('6' * 64); $i.expected.state_sha256 = ('6' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $beginEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'supersession-target-to-begin-unit-detachment' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$beginEventId-transition.intent.json") { param($i) $i.pre.unit.sha256 = ('7' * 64); $i.expected.unit_sha256 = ('7' * 64) }
        Rebind-FixtureTransaction -Workspace $case -EventId $beginEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-begin-intent' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$beginEventId-transition.intent.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-begin-completion' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$beginEventId-transition.completion.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'damaged-begin-intent-link' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$beginEventId-transition.completion.json") { param($c) $c.intent.path = 'receipts/transactions/wrong.intent.json' }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-fail-intent' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'missing-fail-completion' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\transactions\$failEventId-transition.completion.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'mismatched-fail-event-unit' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.event.unit_id = $oldUnitId }
        $ip = Join-Path $case "receipts\transactions\$failEventId-transition.intent.json"
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.completion.json") { param($c) $c.intent.sha256 = (Get-FileHash $ip -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'completion-target-mismatch' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.completion.json") { param($c) $c.state_sha256 = ('0' * 64) }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'fail-preimage-detached' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.pre.state.sha256 = ('1' * 64); $i.expected.state_sha256 = ('1' * 64) }
        $ip = Join-Path $case "receipts\transactions\$failEventId-transition.intent.json"
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.completion.json") { param($c) $c.intent.sha256 = (Get-FileHash $ip -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    foreach ($substitution in @('pass','blocked')) {
        Assert-HelperRejects -Template $baselineWorkspace -Name "validation-receipt-$substitution-substitution" -Mutation {
            param($case)
            Update-FixtureJson (Join-Path $case "receipts\$replacementUnitId-fail-validation.json") { param($r) $r.result = $substitution }
        }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'validation-receipt-missing' -Mutation { param($case) Remove-Item -LiteralPath (Join-Path $case "receipts\$replacementUnitId-fail-validation.json") }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'validation-receipt-wrong-unit' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\$replacementUnitId-fail-validation.json") { param($r) $r.unit_id = $oldUnitId }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-blocker-projection-tamper' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.blockers[0].condition = 'Fabricated condition.' }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-state-tail-tamper' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.last_event_id = $beginEventId }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-current-contradiction' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.current_unit = $replacementUnitId }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-next-ready-contradiction' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.next_ready_unit = $replacementUnitId }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'coherent-acceptance-inference' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "receipts\transactions\$failEventId-transition.intent.json") { param($i) $i.target.state.document.last_accepted_receipt = "receipts/$replacementUnitId-fail-validation.json" }
        Rebind-FixtureTransaction -Workspace $case -EventId $failEventId
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'status-only-reactivation' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case "iteration-units\$replacementUnitId.json") { param($u) $u.status = 'active' }
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.current_unit = $replacementUnitId }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'live-state-not-derived' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.next_ready_unit = $oldUnitId }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'damaged-supersession-binding' -Mutation {
        param($case)
        Update-FixtureLedgerEvent -Workspace $case -EventId $supersessionEventId -Mutation { param($e) $e.event_id = "$oldUnitId-superseded-by-unrelated-owner" }
    }
    Assert-HelperRejects -Template $baselineWorkspace -Name 'begin-ledger-prefix-tamper' -Mutation {
        param($case)
        Update-FixtureLedgerEvent -Workspace $case -EventId $supersessionEventId -Mutation { param($e) $e.summary = 'Tampered prefix.' }
    }
    Assert-HelperRejects -Template $laterActiveWorkspace -Name 'later-event-chain-tamper' -Mutation {
        param($case)
        $last = (ConvertFrom-FixtureJsonText -Text ([string](Get-Content (Join-Path $case 'iteration-events.jsonl') | Where-Object { $_ } | Select-Object -Last 1)) -Context 'fixture later event tail').event_id
        Update-FixtureLedgerEvent -Workspace $case -EventId $last -Mutation { param($e) $e.summary = 'Tampered later event.' }
    }
    Assert-HelperRejects -Template $laterActiveWorkspace -Name 'later-completion-link-tamper' -Mutation {
        param($case)
        $last = (ConvertFrom-FixtureJsonText -Text ([string](Get-Content (Join-Path $case 'iteration-events.jsonl') | Where-Object { $_ } | Select-Object -Last 1)) -Context 'fixture later event tail').event_id
        Update-FixtureJson (Join-Path $case "receipts\transactions\$last-transition.completion.json") { param($c) $c.intent.sha256 = ('2' * 64) }
    }
    Assert-HelperRejects -Template $laterActiveWorkspace -Name 'later-live-projection-tamper' -Mutation {
        param($case)
        Update-FixtureJson (Join-Path $case 'workspace.state.json') { param($s) $s.current_unit = $null }
    }

    Write-Host "Blocked-supersession terminal validation passed $($assertions.Count) focused assertions."
} finally {
    if ($KeepFixture) {
        Write-Host "Retained fixture: $testRoot"
    } elseif (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove a fixture outside the system temporary directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
