param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repoRoot=Split-Path $PSScriptRoot -Parent
$active=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitSupersession.psm1') -Force -PassThru
$protocol=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force -PassThru
$ledger=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -Force -PassThru
$history=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkHistory.psm1') -Force -PassThru

function Assert-ScopeTest([bool]$Condition,[string]$Message){if(-not$Condition){throw "Superseded scope-conflict self-test failed: $Message"}}
function Write-ScopeJson([string]$Path,[object]$Value){[IO.Directory]::CreateDirectory((Split-Path $Path -Parent))|Out-Null;[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 100)+[char]10),[Text.UTF8Encoding]::new($false))}
function Read-ScopeJson([string]$Path){&$protocol {param($p)Read-MorphospaceProtocolJson $p} $Path}
function Get-ScopeFileHash([string]$Path){&$protocol {param($p)Get-MorphospaceFileSha256 $p} $Path}
function Get-ScopeCanonicalHash([object]$Value){&$protocol {param($v)Get-MorphospaceCanonicalJsonSha256 $v} $Value}
function Get-ScopeBytesHash([byte[]]$Value){&$protocol {param($v)Get-MorphospaceSha256Bytes $v} $Value}
function Invoke-ScopePrivate([object]$Module,[scriptblock]$Script,[object[]]$Arguments){&$Module $Script $Arguments}
function Copy-ScopeValue([object]$Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String}

function New-ScopeUnit([string]$Id,[string]$Status,[switch]$Overlap,[string[]]$Prerequisites=@(),[switch]$LowGuard){
    $unit=[ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id=$Id;project_id='scope-conflict-test';status=$Status
        objective="Exercise authenticated supersession history for $Id.";change_categories=@('implementation')
        instruction_impact='none';instruction_surfaces=@();instruction_none_justification='The synthetic fixture changes no instruction surface.'
        prerequisites=@($Prerequisites);allowed_repositories=@([ordered]@{repo_id='source-repo';allowed_paths=@('src/feature.rs')})
        non_scope=@('Real product, publication, build, device, and remote work.')
        acceptance=@([ordered]@{acceptance_id='focused-self-test';proof='The focused synthetic contract passes.';command='Test-SupersededScopeConflict.ps1 -SelfTest'})
        risk_tier='quick';device_requirement='none';validation=@([ordered]@{profile_id='quick';command='Test-SupersededScopeConflict.ps1 -SelfTest'})
        outputs=@('One focused synthetic result.');commit_policy='Synthetic fixture only.';push_checkpoint='none'
    }
    if($LowGuard){$unit.guard_profile='labs';$unit.change_categories=@('state-machine')}
    if($Overlap){$unit.read_only_dependencies=@([ordered]@{repo_id='source-repo';paths=@('src/feature.rs');purpose='Preserved obsolete declaration.';verification='Authenticated exact supersession only.'})}
    [pscustomobject]$unit
}

function Start-ScopeTransition([string]$Workspace,[string]$Transaction,[string]$UnitId,[object]$TargetState,[object]$TargetUnit,[object]$Event,[object[]]$Artifacts=@()){
    $arguments=@{WorkspaceRoot=$Workspace;TransactionId=$Transaction;StatePath='workspace.state.json';UnitPath="iteration-units/$UnitId.json";EventsPath='iteration-events.jsonl';TargetState=$TargetState;TargetUnit=$TargetUnit;Event=$Event;Artifacts=@($Artifacts)}
    &$ledger {param($a)Start-MorphospaceTransitionLedger @a} $arguments|Out-Null
}

function New-ScopeRequest([string]$Workspace,[string]$OldId,[string]$NewId){
    $project=Read-ScopeJson (Join-Path $Workspace 'project.spec.json')
    $state=Read-ScopeJson (Join-Path $Workspace 'workspace.state.json')
    $old=Invoke-ScopePrivate $active {param($a)Get-ActiveSupersessionUnitBinding @a} @($Workspace,$OldId)
    $replacement=Invoke-ScopePrivate $active {param($a)Get-ActiveSupersessionUnitBinding @a} @($Workspace,$NewId)
    $events=Invoke-ScopePrivate $active {param($a)Get-ActiveSupersessionEventsSnapshot @a} @((Join-Path $Workspace 'iteration-events.jsonl'))
    $repoMap=Invoke-ScopePrivate $active {param($a)Get-ActiveSupersessionRepositoryMap @a} @((Join-Path $Workspace 'repository-map.json'))
    $ownership=@([pscustomobject]@{unit_id=$NewId;role='replacement';document=$replacement.document;binding=$replacement})
    $repositories=Invoke-ScopePrivate $active {param($a)Get-ActiveSupersessionRepositoryObservation @a} @($old.document,$ownership,$repoMap.map)
    [ordered]@{
        schema='rusty.morphospace.workflow.active_unit_supersession.v1';supersession_id="$OldId-superseded-by-$NewId";project_id='scope-conflict-test'
        old_unit=[ordered]@{unit_id=$OldId;path=[string]$old.path;raw_sha256=[string]$old.raw_sha256;canonical_sha256=[string]$old.canonical_sha256;status='active'}
        replacement_unit=[ordered]@{unit_id=$NewId;path=[string]$replacement.path;raw_sha256=[string]$replacement.raw_sha256;canonical_sha256=[string]$replacement.canonical_sha256;status='proposed'}
        companion_units=@()
        expected=[ordered]@{project_raw_sha256=Get-ScopeFileHash (Join-Path $Workspace 'project.spec.json');project_canonical_sha256=Get-ScopeCanonicalHash $project;state_raw_sha256=Get-ScopeFileHash (Join-Path $Workspace 'workspace.state.json');state_canonical_sha256=Get-ScopeCanonicalHash $state;events_sha256=[string]$events.sha256;events_length=[int64]$events.length;event_tail_id=[string]$events.tail_id;repository_map_sha256=Get-ScopeFileHash (Join-Path $Workspace 'repository-map.json')}
        repositories=@($repositories);does_not_authorize=@('This request changes only workflow lifecycle ownership; it authorizes no acceptance, source edit, build, device, Git, remote, or publication action.')
    }
}

function Invoke-ScopeSupersession([string]$Workspace,[string]$OldId,[string]$NewId,[string]$Timestamp){
    $id="$OldId-superseded-by-$NewId"
    $requestPath=Join-Path $Workspace "receipts/$id-request.json"
    Write-ScopeJson $requestPath (New-ScopeRequest $Workspace $OldId $NewId)
    Invoke-MorphospaceSupersedeActive -WorkspaceRoot $Workspace -UnitId $NewId -RepoMapPath (Join-Path $Workspace 'repository-map.json') -ActiveUnitSupersession $requestPath -ExpectedActiveUnitSupersessionSha256 (Get-ScopeFileHash $requestPath) -OutPath (Join-Path $Workspace "receipts/$id-automation.json") -Timestamp $Timestamp -Execute|Out-Null
}

function New-ScopeWorkspace([string]$Root,[string]$Name,[string]$Source,[switch]$Accepted,[string[]]$ExtraIds=@(),[switch]$LowGuard){
    $workspace=Join-Path $Root $Name
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units'))|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts'))|Out-Null
    Write-ScopeJson (Join-Path $workspace 'project.spec.json') ([ordered]@{schema='test';project_id='scope-conflict-test'})
    Write-ScopeJson (Join-Path $workspace 'repository-map.json') ([ordered]@{'$schema'='fixture';schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='source-repo';path=$Source;role='source'})})
    Write-ScopeJson (Join-Path $workspace 'iteration-units/unit-old.json') (New-ScopeUnit unit-old active -Overlap -LowGuard:$LowGuard)
    Write-ScopeJson (Join-Path $workspace 'iteration-units/unit-new.json') (New-ScopeUnit unit-new proposed)
    foreach($id in $ExtraIds){Write-ScopeJson (Join-Path $workspace "iteration-units/$id.json") (New-ScopeUnit $id proposed)}
    if(-not$Accepted){
        $state=[ordered]@{schema='test';project_id='scope-conflict-test';current_unit='unit-old';next_ready_unit='unit-new';normal_validation_selection=$null;last_accepted_receipt=$null;last_event_id='unit-old-claimed-0001'}
        $event=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-old-claimed-0001';sequence=1;timestamp='2026-09-08T08:00:00.0000000Z';project_id='scope-conflict-test';unit_id='unit-old';event_type='state-transition';summary='Established an unaccepted owner.';receipts=@()}
        Write-ScopeJson (Join-Path $workspace 'workspace.state.json') $state
        [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'),(($event|ConvertTo-Json -Compress)+[char]10),[Text.UTF8Encoding]::new($false))
        return $workspace
    }
    Write-ScopeJson (Join-Path $workspace 'iteration-units/unit-accepted.json') (New-ScopeUnit unit-accepted validating)
    $state=[ordered]@{schema='test';project_id='scope-conflict-test';current_unit='unit-accepted';next_ready_unit=$null;normal_validation_selection=$null;last_accepted_receipt=$null;last_event_id='unit-accepted-validating-0001'}
    $seed=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-accepted-validating-0001';sequence=1;timestamp='2026-09-08T08:00:00.0000000Z';project_id='scope-conflict-test';unit_id='unit-accepted';event_type='state-transition';summary='Established an accepted-boundary preimage.';receipts=@()}
    Write-ScopeJson (Join-Path $workspace 'workspace.state.json') $state
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'),(($seed|ConvertTo-Json -Compress)+[char]10),[Text.UTF8Encoding]::new($false))
    $acceptedUnit=Read-ScopeJson (Join-Path $workspace 'iteration-units/unit-accepted.json');$acceptedUnit.status='accepted'
    $acceptedState=Copy-ScopeValue $state;$acceptedState.current_unit=$null;$acceptedState.last_accepted_receipt='receipts/unit-accepted.json';$acceptedState.last_event_id='unit-accepted-accepted-0002'
    $acceptedEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-accepted-accepted-0002';sequence=2;timestamp='2026-09-08T08:01:00.0000000Z';project_id='scope-conflict-test';unit_id='unit-accepted';event_type='state-transition';summary='Accepted the exact synthetic boundary.';receipts=@('receipts/unit-accepted.json')}
    $receiptBytes=[Text.UTF8Encoding]::new($false).GetBytes('{"fixture":"accepted"}'+[char]10)
    $artifact=[pscustomobject]@{bytes_base64=[Convert]::ToBase64String($receiptBytes);path='receipts/unit-accepted.json';sha256=Get-ScopeBytesHash $receiptBytes}
    Start-ScopeTransition $workspace 'unit-accepted-accepted-0002-transition' unit-accepted $acceptedState $acceptedUnit $acceptedEvent @($artifact)
    $claimState=Copy-ScopeValue $acceptedState;$claimState.current_unit='unit-old';$claimState.next_ready_unit='unit-new';$claimState.last_event_id='unit-old-claimed-0003'
    $claimEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-old-claimed-0003';sequence=3;timestamp='2026-09-08T08:02:00.0000000Z';project_id='scope-conflict-test';unit_id='unit-old';event_type='state-transition';summary='Claimed the exact active predecessor.';receipts=@()}
    Start-ScopeTransition $workspace 'unit-old-claimed-0003-transition' unit-old $claimState (Read-ScopeJson (Join-Path $workspace 'iteration-units/unit-old.json')) $claimEvent
    return $workspace
}

function Get-ScopeHistory([string]$Workspace){&$history {param($w)Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $w} $Workspace}
# Exercise the actual production guard block against real owner-produced history.
# No complete project validator or hand-authored positive history is substituted.
$guardTokens=$null;$guardErrors=$null
$guardAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1'),[ref]$guardTokens,[ref]$guardErrors)
Assert-ScopeTest (@($guardErrors).Count-eq0) 'production guard source did not parse'
$guardBlocks=@($guardAst.FindAll({param($node)
    $node-is[Management.Automation.Language.IfStatementAst]-and$node.Clauses.Count-eq1-and
    $node.Clauses[0].Item1.Extent.Text-ceq'$unit.PSObject.Properties.Name -contains "guard_profile"'
},$true))
Assert-ScopeTest ($guardBlocks.Count-eq1) 'one exact production guard-profile block required'
$guardBlock=[scriptblock]::Create($guardBlocks[0].Extent.Text)
function Test-ScopeGuard([object]$Unit,[object]$CurrentHistory){
    $script:ScopeGuardFailures=[Collections.Generic.List[string]]::new()
    $script:GuardProfiles=@('fast','labs','locked')
    function Assert-Contract([bool]$Condition,[string]$Message){if(-not$Condition){$script:ScopeGuardFailures.Add($Message)|Out-Null}}
    $unit=$Unit;$currentHistory=$CurrentHistory;$effectiveChangeCategories=@($unit.change_categories);$Context='synthetic guard fixture'
    &$guardBlock
    return @($script:ScopeGuardFailures.ToArray())
}

# Exercise the actual aggregate dispatch and the factored production reader.
# Preparation is mocked at its existing authenticated-proof seam: this test
# covers dispatch, proof refusal and live binding equality, while the existing
# tooling fixtures retain complete preparation/context/blob authentication.
$toolingBlocks=@($guardAst.FindAll({param($node)
    $node-is[Management.Automation.Language.IfStatementAst]-and$node.Clauses.Count-eq1-and
    $node.Clauses[0].Item1.Extent.Text.StartsWith("@('proposed','ready','active','validating')",[StringComparison]::Ordinal)-and
    $node.Extent.Text.Contains('current development provenance failed',[StringComparison]::Ordinal)
},$true))
Assert-ScopeTest ($toolingBlocks.Count-eq1) 'one production development-provenance dispatch block required'
$toolingBlock=[scriptblock]::Create($toolingBlocks[0].Extent.Text)
$provenanceTokens=$null;$provenanceErrors=$null
$provenanceAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1'),[ref]$provenanceTokens,[ref]$provenanceErrors)
Assert-ScopeTest (@($provenanceErrors).Count-eq0) 'production provenance reader source did not parse'
$readerFunctions=@($provenanceAst.FindAll({param($node)
    $node-is[Management.Automation.Language.FunctionDefinitionAst]-and
    @('Get-MorphospaceUnitToolingContextProvenance','Get-MorphospaceUnitToolingContextObservation')-ccontains$node.Name
},$true))
Assert-ScopeTest ($readerFunctions.Count-eq2) 'exact production provenance and strict observation functions required'
$script:ScopeToolingHarness=New-Module -ArgumentList $protocol.Path,@($readerFunctions|ForEach-Object{$_.Name;$_.Body.Extent.Text}) -ScriptBlock {
    param($ProtocolPath,$Definitions)
    Import-Module $ProtocolPath
    for($i=0;$i-lt$Definitions.Count;$i+=2){Set-Item -Path "Function:script:$($Definitions[$i])" -Value ([scriptblock]::Create($Definitions[$i+1].Substring(1,$Definitions[$i+1].Length-2)))}
    $script:Proof=$null;$script:ProofRefused=$false;$script:ProofCalls=0;$script:ExecutorCalls=0
    function Test-MorphospaceDevelopmentUnitPreparation {
        param($WorkspaceRoot,$Admission,$Phase,[switch]$ReadOnlyReady)
        $script:ProofCalls++
        if($Phase-cne'Freeze'-or-not$ReadOnlyReady){throw 'fixture requires the unchanged read-only prepared-proof route'}
        if($script:ProofRefused){throw 'fixture authenticated prepared proof refused'}
        return $script:Proof
    }
    function Assert-MorphospaceToolingContextExecutor {
        param($WorkspaceRoot,$Binding,$Action,$OwnerModule)
        $script:ExecutorCalls++
        throw 'fixture owner action is outside its exact bound tooling checkout'
    }
    Export-ModuleMember -Function Get-MorphospaceUnitToolingContextProvenance,Get-MorphospaceUnitToolingContextObservation
}
function Test-ScopeToolingDispatch([object]$Unit,[object]$CurrentHistory,[string]$Workspace){
    $script:ScopeToolingFailures=[Collections.Generic.List[string]]::new()
    function Add-Failure([string]$Message){$script:ScopeToolingFailures.Add($Message)|Out-Null}
    function Import-Module {param([string]$Name,[switch]$PassThru) return $script:ScopeToolingHarness}
    $unit=$Unit;$currentHistory=$CurrentHistory;$workspaceRoot=$Workspace;$Context='synthetic tooling fixture'
    $RepoRoot=$repoRoot;$RepositoryMapPath=Join-Path $Workspace 'repository-map.json'
    &$toolingBlock
    return @($script:ScopeToolingFailures.ToArray())
}
function Reset-ScopeToolingCalls {&$script:ScopeToolingHarness {$script:ProofCalls=0;$script:ExecutorCalls=0}}
function Assert-ScopeToolingDispatch([object]$Unit,[object]$CurrentHistory,[string]$Workspace,[bool]$Pure,[string]$Case){
    Reset-ScopeToolingCalls
    $failures=@(Test-ScopeToolingDispatch $Unit $CurrentHistory $Workspace)
    $counts=&$script:ScopeToolingHarness { @($script:ProofCalls,$script:ExecutorCalls) }
    Assert-ScopeTest ($counts[0]-eq1-and$counts[1]-eq$(if($Pure){0}else{1})-and$failures.Count-eq$(if($Pure){0}else{1})) "$Case selected the wrong data/action provenance route"
}

function Copy-ScopeWorkspace([string]$Source,[string]$Root,[string]$Name){$target=Join-Path $Root $Name;Copy-Item -LiteralPath $Source -Destination $target -Recurse;return $target}

if(-not$SelfTest){throw 'Test-SupersededScopeConflict requires -SelfTest.'}
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
$temp=[IO.Path]::GetFullPath((Join-Path $tempBase ('morphospace-superseded-scope-'+[guid]::NewGuid().ToString('N'))))
$tempPrefix=$tempBase+[IO.Path]::DirectorySeparatorChar
if(-not$temp.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Synthetic fixture root escaped the system temporary directory.'}
[IO.Directory]::CreateDirectory($temp)|Out-Null
try{
    $source=Join-Path $temp 'source';[IO.Directory]::CreateDirectory((Join-Path $source 'src'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'src/feature.rs'),('baseline'+[char]10),[Text.UTF8Encoding]::new($false))
    &git -C $source init|Out-Null;&git -C $source config user.email fixture@example.invalid;&git -C $source config user.name Fixture;&git -C $source add src/feature.rs;&git -C $source commit -m fixture|Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'src/feature.rs'),('owned overlay'+[char]10),[Text.UTF8Encoding]::new($false))

    $before=New-ScopeWorkspace $temp before $source -Accepted -LowGuard
    $plain=Get-ScopeHistory $before
    Assert-ScopeTest ($plain.authenticated-and-not$plain.authenticated_superseded_scope_conflict_ids.Contains('unit-old')) 'an accepted boundary without SupersedeActive admitted the old unit'

    $positive=Copy-ScopeWorkspace $before $temp positive
    Invoke-ScopeSupersession $positive unit-old unit-new '2026-09-08T08:03:00.0000000Z'
    $projected=Get-ScopeHistory $positive
    Assert-ScopeTest ($projected.authenticated_superseded_scope_conflict_ids.Contains('unit-old')-and-not$projected.historical_ids.Contains('unit-old')) 'the exact supported handoff was not classified without historical credit'
    $lowOld=Read-ScopeJson (Join-Path $positive 'iteration-units/unit-old.json')
    Assert-ScopeTest (@(Test-ScopeGuard $lowOld $projected).Count-eq0) 'a known obsolete labs profile failed after exact authenticated handoff'
    Assert-ScopeTest (@(Test-ScopeGuard $lowOld $null).Count-eq1) 'full historical audit without current history gained the minimum-rank exception'
    Assert-ScopeTest (@(Test-ScopeGuard $lowOld $plain).Count-eq1) 'accepted history without supersession gained the minimum-rank exception'
    $unauthenticated=Get-ScopeHistory (New-ScopeWorkspace $temp guard-no-boundary $source -LowGuard)
    Assert-ScopeTest (@(Test-ScopeGuard $lowOld $unauthenticated).Count-eq1) 'unauthenticated current history gained the minimum-rank exception'
    $lowCurrent=Read-ScopeJson (Join-Path $positive 'iteration-units/unit-new.json')
    $lowCurrent|Add-Member -NotePropertyName guard_profile -NotePropertyValue labs -Force;$lowCurrent.change_categories=@('state-machine')
    Assert-ScopeTest (@(Test-ScopeGuard $lowCurrent $projected).Count-eq1) 'the current owner gained obsolete predecessor authority'
    $unknown=Copy-ScopeValue $lowOld;$unknown.guard_profile='unknown'
    $unknownFailures=@(Test-ScopeGuard $unknown $projected)
    Assert-ScopeTest ($unknownFailures.Count-eq1-and$unknownFailures[0]-like'*unknown guard profile*') 'unknown profile vocabulary was deferred with the obsolete minimum'

    $queued=Copy-ScopeWorkspace $positive $temp guard-next-ready
    $queuedState=Read-ScopeJson (Join-Path $queued 'workspace.state.json');$queuedState.next_ready_unit='unit-old';$queuedState.last_event_id='unit-old-queued-0005'
    $queuedEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-old-queued-0005';sequence=5;timestamp='2026-09-08T08:04:00.0000000Z';project_id='scope-conflict-test';unit_id='unit-new';event_type='state-transition';summary='Negative fixture queues the preserved predecessor.';receipts=@()}
    Start-ScopeTransition $queued 'unit-old-queued-0005-transition' unit-new $queuedState (Read-ScopeJson (Join-Path $queued 'iteration-units/unit-new.json')) $queuedEvent
    $queuedHistory=Get-ScopeHistory $queued
    Assert-ScopeTest (-not$queuedHistory.authenticated_superseded_scope_conflict_ids.Contains('unit-old')-and@(Test-ScopeGuard $lowOld $queuedHistory).Count-eq1) 'a next-ready predecessor gained the minimum-rank exception'


    $raw=Copy-ScopeWorkspace $positive $temp raw-tamper
    $oldPath=Join-Path $raw 'iteration-units/unit-old.json';$oldDocument=Read-ScopeJson $oldPath
    [IO.File]::WriteAllText($oldPath,(($oldDocument|ConvertTo-Json -Depth 100 -Compress)+[char]10),[Text.UTF8Encoding]::new($false))
    Assert-ScopeTest (-not(Get-ScopeHistory $raw).authenticated_superseded_scope_conflict_ids.Contains('unit-old')) 'raw predecessor tamper retained the exception'
    Assert-ScopeTest (@(Test-ScopeGuard $lowOld (Get-ScopeHistory $raw)).Count-eq1) 'raw predecessor tamper retained the minimum-rank exception'

    $chain=Copy-ScopeWorkspace $positive $temp chained-positive
    Write-ScopeJson (Join-Path $chain 'iteration-units/unit-final.json') (New-ScopeUnit unit-final proposed)
    Invoke-ScopeSupersession $chain unit-new unit-final '2026-09-08T08:04:00.0000000Z'
    $chainHistory=Get-ScopeHistory $chain
    Assert-ScopeTest ($chainHistory.authenticated_superseded_scope_conflict_ids.Contains('unit-old')-and$chainHistory.authenticated_superseded_scope_conflict_ids.Contains('unit-new')) 'an ordered unique supersession chain did not reach the current owner'
    Assert-ScopeTest (@(Test-ScopeGuard $lowOld $chainHistory).Count-eq0) 'an ordered unique chain lost obsolete minimum-rank classification'

    $prerequisite=Copy-ScopeWorkspace $positive $temp prerequisite
    $dependent=Read-ScopeJson (Join-Path $prerequisite 'iteration-units/unit-new.json');$dependent.prerequisites=@('unit-old');Write-ScopeJson (Join-Path $prerequisite 'iteration-units/unit-new.json') $dependent
    $prerequisiteRejected=$false;try{Get-ScopeHistory $prerequisite|Out-Null}catch{$prerequisiteRejected=$true}
    Assert-ScopeTest $prerequisiteRejected 'a predecessor required by the current unit retained the exception'

    $converged=Copy-ScopeWorkspace $positive $temp converged
    Write-ScopeJson (Join-Path $converged 'iteration-units/unit-other.json') (New-ScopeUnit unit-other active -Overlap)
    $resetUnit=Read-ScopeJson (Join-Path $converged 'iteration-units/unit-new.json');$resetUnit.status='proposed'
    $resetState=Read-ScopeJson (Join-Path $converged 'workspace.state.json');$resetState.current_unit='unit-other';$resetState.next_ready_unit='unit-new';$resetState.last_event_id='unit-new-reopened-0005'
    $resetEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-new-reopened-0005';sequence=5;timestamp='2026-09-08T08:04:00.0000000Z';project_id='scope-conflict-test';unit_id='unit-new';event_type='state-transition';summary='Projected a second synthetic predecessor for convergence damage.';receipts=@()}
    Start-ScopeTransition $converged 'unit-new-reopened-0005-transition' unit-new $resetState $resetUnit $resetEvent
    Invoke-ScopeSupersession $converged unit-other unit-new '2026-09-08T08:05:00.0000000Z'
    $convergedHistory=Get-ScopeHistory $converged
    Assert-ScopeTest (-not$convergedHistory.authenticated_superseded_scope_conflict_ids.Contains('unit-old')-and-not$convergedHistory.authenticated_superseded_scope_conflict_ids.Contains('unit-other')) 'converging authenticated predecessors retained the exception'

    $noBoundary=New-ScopeWorkspace $temp no-boundary $source
    Invoke-ScopeSupersession $noBoundary unit-old unit-new '2026-09-08T08:03:00.0000000Z'
    $unaccepted=Get-ScopeHistory $noBoundary
    Assert-ScopeTest (-not$unaccepted.authenticated-and-not$unaccepted.authenticated_superseded_scope_conflict_ids.Contains('unit-old')) 'a workspace without an accepted boundary gained the exception'

    $resurrected=Copy-ScopeWorkspace $positive $temp resurrected
    $liveState=Read-ScopeJson (Join-Path $resurrected 'workspace.state.json');$liveState.current_unit='unit-old';$liveState.last_event_id='unit-old-resumed-0005'
    $resumedEvent=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-old-resumed-0005';sequence=5;timestamp='2026-09-08T08:04:00.0000000Z';project_id='scope-conflict-test';unit_id='unit-old';event_type='state-transition';summary='Resurrected the preserved predecessor.';receipts=@()}
    Start-ScopeTransition $resurrected 'unit-old-resumed-0005-transition' unit-old $liveState (Read-ScopeJson (Join-Path $resurrected 'iteration-units/unit-old.json')) $resumedEvent
    Assert-ScopeTest (-not(Get-ScopeHistory $resurrected).authenticated_superseded_scope_conflict_ids.Contains('unit-old')) 'a resurrected predecessor retained the exception'

    $structural=Copy-ScopeWorkspace $positive $temp structural-damage
    $lines=[Collections.Generic.List[string]]::new();foreach($line in Get-Content (Join-Path $structural 'iteration-events.jsonl')){$lines.Add($line)}
    $damaged=$lines[0]|ConvertFrom-Json -DateKind String;$damaged.sequence=9;$lines[0]=$damaged|ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $structural 'iteration-events.jsonl'),(($lines-join[char]10)+[char]10),[Text.UTF8Encoding]::new($false))
    $rejected=$false;try{Get-ScopeHistory $structural|Out-Null}catch{$rejected=$true}
    Assert-ScopeTest $rejected 'unrelated event-sequence damage was deferred'

    $toolingWorkspace=Join-Path $temp 'tooling-reader'
    $binding=[pscustomobject]@{path='tooling-contexts/old.json';sha256=('a'*64);canonical_sha256=('b'*64);protocol_id='tooling-context-v1'}
    $toolingOld=Copy-ScopeValue $lowOld;$toolingOld|Add-Member -NotePropertyName tooling_context -NotePropertyValue $binding
    $toolingCurrent=Copy-ScopeValue $lowCurrent;$toolingCurrent|Add-Member -NotePropertyName tooling_context -NotePropertyValue $binding
    foreach($u in @($toolingOld,$toolingCurrent)){
        Write-ScopeJson (Join-Path $toolingWorkspace "iteration-units/$($u.unit_id).json") $u
        Write-ScopeJson (Join-Path $toolingWorkspace "receipts/$($u.unit_id)-admitted.json") ([pscustomobject]@{schema='rusty.morphospace.workflow.development_unit_admission.v1';unit_id=$u.unit_id})
    }
    &$script:ScopeToolingHarness {param($b)$script:Proof=[pscustomobject]@{tooling_context=[pscustomobject]@{binding=$b;document=[pscustomobject]@{fixture='authenticated prepared context'}}}} $binding
    Assert-ScopeToolingDispatch $toolingOld $projected $toolingWorkspace $true 'exact authenticated superseded predecessor'
    Assert-ScopeToolingDispatch $toolingOld $chainHistory $toolingWorkspace $true 'ordered authenticated successor chain'
    $unauthenticatedProjected=$projected.PSObject.Copy();$unauthenticatedProjected.authenticated=$false
    Assert-ScopeTest ($projected.authenticated-and$unauthenticatedProjected.authenticated_superseded_scope_conflict_ids.Contains('unit-old')) 'unauthenticated clone lost the original classified ID or changed its source history'
    Assert-ScopeToolingDispatch $toolingOld $unauthenticatedProjected $toolingWorkspace $false 'unauthenticated history retaining the classified ID'
    Assert-ScopeToolingDispatch $toolingOld $null $toolingWorkspace $false 'full audit without current history'
    Assert-ScopeToolingDispatch $toolingOld $plain $toolingWorkspace $false 'no supersession'
    Assert-ScopeToolingDispatch $toolingOld $unaccepted $toolingWorkspace $false 'no accepted boundary'
    Assert-ScopeToolingDispatch $toolingCurrent $projected $toolingWorkspace $false 'current owner'
    Assert-ScopeToolingDispatch $toolingOld $queuedHistory $toolingWorkspace $false 'next-ready predecessor'
    Assert-ScopeToolingDispatch $toolingOld (Get-ScopeHistory $raw) $toolingWorkspace $false 'raw predecessor tamper'
    Assert-ScopeToolingDispatch $toolingOld (Get-ScopeHistory $resurrected) $toolingWorkspace $false 'resurrected predecessor'
    Assert-ScopeToolingDispatch $toolingOld $convergedHistory $toolingWorkspace $false 'ambiguous converging predecessors'

    # A rejected prepared proof and a detached live pointer still refuse even
    # when the independent supersession classifier selected the DATA route.
    &$script:ScopeToolingHarness {$script:ProofRefused=$true}
    $proofFailures=@(Test-ScopeToolingDispatch $toolingOld $projected $toolingWorkspace)
    Assert-ScopeTest ($proofFailures.Count-eq1-and$proofFailures[0]-like'*authenticated prepared proof refused*') 'prepared-proof refusal was suppressed for preserved data'
    &$script:ScopeToolingHarness {$script:ProofRefused=$false}
    $detached=Copy-ScopeValue $toolingOld;$detached.tooling_context.sha256=('c'*64)
    Write-ScopeJson (Join-Path $toolingWorkspace 'iteration-units/unit-old.json') $detached
    $pointerFailures=@(Test-ScopeToolingDispatch $detached $projected $toolingWorkspace)
    Assert-ScopeTest ($pointerFailures.Count-eq1-and$pointerFailures[0]-like'*authenticated continuation*') 'detached live tooling pointer was accepted by the pure reader'
    Write-ScopeJson (Join-Path $toolingWorkspace 'iteration-units/unit-old.json') $toolingOld

    Write-ScopeJson (Join-Path $toolingWorkspace 'receipts/unit-old-duplicate.json') ([pscustomobject]@{schema='rusty.morphospace.workflow.development_unit_admission.v1';unit_id='unit-old'})
    $admissionFailures=@(Test-ScopeToolingDispatch $toolingOld $projected $toolingWorkspace)
    Assert-ScopeTest ($admissionFailures.Count-eq1-and$admissionFailures[0]-like'*one exact owner admission*') 'ambiguous admission was accepted by the pure reader'
    [IO.File]::Delete((Join-Path $toolingWorkspace 'receipts/unit-old-duplicate.json'))

    Write-ScopeJson (Join-Path $toolingWorkspace 'iteration-units/unit-ordinary.json') (New-ScopeUnit unit-ordinary active)
    Reset-ScopeToolingCalls
    $ordinaryResult=&$script:ScopeToolingHarness {param($w)Get-MorphospaceUnitToolingContextObservation -WorkspaceRoot $w -UnitId unit-ordinary -Action Inspect} $toolingWorkspace
    $ordinaryCalls=&$script:ScopeToolingHarness { @($script:ProofCalls,$script:ExecutorCalls) }
    Assert-ScopeTest ($null-eq$ordinaryResult-and$ordinaryCalls[0]-eq0-and$ordinaryCalls[1]-eq0) 'ordinary unit acquired a tooling context or executor requirement'

    # Calling the public action reader directly never acquires the aggregate's
    # classification. Every action still reaches the exact executor assertion.
    foreach($action in @('Inspect','Ready','Claim','FreezeCandidate')){
        Reset-ScopeToolingCalls;$actionRefused=$false
        try{&$script:ScopeToolingHarness {param($w,$a)Get-MorphospaceUnitToolingContextObservation -WorkspaceRoot $w -UnitId unit-old -Action $a} $toolingWorkspace $action|Out-Null}catch{$actionRefused=$_.Exception.Message-like'*outside its exact bound tooling checkout*'}
        $calls=&$script:ScopeToolingHarness { @($script:ProofCalls,$script:ExecutorCalls) }
        Assert-ScopeTest ($actionRefused-and$calls[0]-eq1-and$calls[1]-eq1) "strict $action observation bypassed executor attestation"
    }

    [pscustomobject][ordered]@{status='pass';check='superseded-scope-conflict';positive=@('exact-owner-supersession','ordered-unique-chain','known-obsolete-labs-minimum','superseded-tooling-data-provenance','ordinary-unit-null-observation');guard_negative_cases=@('no-current-history','no-supersession','unauthenticated-history','current-owner','next-ready-owner','unknown-profile-vocabulary','raw-old-tamper');tooling_negative_cases=@('no-current-history','no-supersession','no-accepted-boundary','unauthenticated-classified-history','current-owner','next-ready-owner','raw-old-tamper','resurrection','convergence','prepared-proof-refusal','detached-context-pointer','ambiguous-admission','representative-direct-owner-actions');negative_cases=@('no-supersession','raw-old-tamper','no-accepted-boundary','prerequisite','converging-predecessors','resurrection','unrelated-structural-damage')}|ConvertTo-Json -Depth 8
}finally{
    if(Test-Path -LiteralPath $temp){
        $item=Get-Item -LiteralPath $temp -Force
        $resolved=[IO.Path]::GetFullPath($item.FullName)
        if(-not$resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or($item.PSObject.Properties.Name-contains'LinkType'-and[string]$item.LinkType)){
            throw 'Refusing to remove an untrusted synthetic fixture root.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
