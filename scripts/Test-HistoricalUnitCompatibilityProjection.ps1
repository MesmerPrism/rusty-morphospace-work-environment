param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HistoricalUnitCompatibilityProjection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalUnitCompatibilityProjection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
$ledgerModule = Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force -PassThru
$encoding = [Text.UTF8Encoding]::new($false)
$assertions = [Collections.Generic.List[string]]::new()

function Start-MorphospaceTransitionLedger {
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

function Complete-MorphospaceTransitionLedger {
    param(
        [string]$WorkspaceRoot, [string]$TransactionId, [switch]$Repair,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter = 'none'
    )
    & $ledgerModule { param($Arguments) Complete-MorphospaceTransitionLedger @Arguments } $PSBoundParameters
}

function Assert-HucTest { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "Historical compatibility self-test failed: $Message"};$assertions.Add($Message)|Out-Null }
function ConvertFrom-HucCliOutput { param([object[]]$Lines,[string]$Context) $text=@($Lines|ForEach-Object{[string]$_})-join"`n";$start=$text.IndexOf('{',[StringComparison]::Ordinal);if($start-lt0){throw "$Context emitted no JSON."};$text.Substring($start)|ConvertFrom-Json }
function Write-HucTestJson { param([string]$Path,[object]$Value) $parent=Split-Path $Path -Parent;if($parent){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllText($Path,(ConvertTo-MorphospaceCanonicalJson $Value)+"`n",$encoding) }
function Write-HucTestText { param([string]$Path,[string]$Value) $parent=Split-Path $Path -Parent;if($parent){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllText($Path,$Value,$encoding) }
function Copy-HucTestValue { param([object]$Value) ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $encoding.GetBytes(($Value|ConvertTo-Json -Depth 100 -Compress)) -Context 'historical compatibility test clone' }
function Copy-HucTestWorkspace { param([string]$Source,[string]$Destination) if(Test-Path $Destination){throw "Fixture already exists: $Destination"};Copy-Item -LiteralPath $Source -Destination $Destination -Recurse;$Destination }
function Assert-HucRejected { param([scriptblock]$Action,[string]$Pattern,[string]$Label) $message='';try{&$Action|Out-Null}catch{$message=$_.Exception.Message};Assert-HucTest ($message -like $Pattern) "$Label (actual: $message)" }

function Add-HucTestTransition {
    param([string]$Workspace,[string]$UnitId,[string]$EventId,[string]$Timestamp,[string]$EventType,[string]$Summary,[object]$TargetState,[object]$TargetUnit,[string[]]$Receipts=@(),[object[]]$Artifacts=@())
    $statePath=Join-Path $Workspace 'workspace.state.json';$unitPath=Join-Path $Workspace "iteration-units\$UnitId.json";$eventsPath=Join-Path $Workspace 'iteration-events.jsonl'
    $state=Read-MorphospaceProtocolJson $statePath;$unit=Read-MorphospaceProtocolJson $unitPath
    $TargetState.last_event_id=$EventId
    $sequence=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}).Count+1
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$EventId;sequence=$sequence;timestamp=$Timestamp;project_id=[string]$state.project_id;unit_id=$UnitId;event_type=$EventType;summary=$Summary;receipts=@($Receipts)}
    Start-MorphospaceTransitionLedger -WorkspaceRoot $Workspace -TransactionId "$EventId-transition" -StatePath 'workspace.state.json' -UnitPath "iteration-units/$UnitId.json" -EventsPath 'iteration-events.jsonl' `
        -TargetState $TargetState -TargetUnit $TargetUnit -Event $event -ExpectedStateSha256 (Get-MorphospaceCanonicalJsonSha256 $state) -ExpectedUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $unit) `
        -ExpectedEventTailId ([string]$state.last_event_id) -ExpectedEventsSha256 (Get-MorphospaceFileSha256 $eventsPath) -ExpectedEventsLength ([IO.FileInfo]::new($eventsPath).Length) -Artifacts $Artifacts|Out-Null
}

function New-HucTestUnit {
    param([string]$ProjectId,[string]$UnitId,[string]$Status,[switch]$LegacyProfiles)
    $validation = if($LegacyProfiles){
        @(
            [pscustomobject][ordered]@{profile_id='focused';command='pwsh -File tools/Test-Collector.ps1'},
            [pscustomobject][ordered]@{profile_id='windows-integration';command='pwsh -File tools/Invoke-CollectorQualification.ps1 -RepeatCount 5'},
            [pscustomobject][ordered]@{profile_id='host';command='pwsh -File tools/check_all.ps1'},
            [pscustomobject][ordered]@{profile_id='workflow';command='pwsh -File <work-environment-root>/scripts/Test-WorkflowContracts.ps1'}
        )
    } else {
        @(
            [pscustomobject][ordered]@{profile_id='host';command='pwsh -File tools/Test-Collector.ps1'},
            [pscustomobject][ordered]@{profile_id='host';command='pwsh -File tools/Invoke-CollectorQualification.ps1 -RepeatCount 5'},
            [pscustomobject][ordered]@{profile_id='host';command='pwsh -File tools/check_all.ps1'},
            [pscustomobject][ordered]@{profile_id='workflow';command='pwsh -File <work-environment-root>/scripts/Test-WorkflowContracts.ps1'}
        )
    }
    [pscustomobject][ordered]@{
        '$schema'='../schemas/iteration-unit.schema.json';schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id=$UnitId;project_id=$ProjectId;status=$Status
        objective="Exercise authenticated historical compatibility for $UnitId.";work_mode='feature';guard_profile='locked';change_categories=@('implementation','validation');instruction_impact='update';instruction_none_justification=$null
        instruction_surfaces=@(
            [pscustomobject][ordered]@{surface_kind='agents';path='<project-root>/AGENTS.md';owner='fixture';change_reason='Synchronize fixture instructions.';action='update';status='planned';validation='fixture';skill_id=$null},
            [pscustomobject][ordered]@{surface_kind='readme';path='<project-root>/README.md';owner='fixture';change_reason='Synchronize fixture routing.';action='update';status='planned';validation='fixture';skill_id=$null},
            [pscustomobject][ordered]@{surface_kind='skill';path='<skills-root>/rusty-morphospace/SKILL.md';owner='workflow';change_reason='Retain historical no-edit review.';action='review-no-change';status='planned';validation='fixture';skill_id='rusty-morphospace'},
            [pscustomobject][ordered]@{surface_kind='skill';path='<skills-root>/system-engineering/SKILL.md';owner='workflow';change_reason='Retain historical no-edit review.';action='review-no-change';status='planned';validation='fixture';skill_id='system-engineering'},
            [pscustomobject][ordered]@{surface_kind='skill';path='<skills-root>/rust-work-graph/SKILL.md';owner='workflow';change_reason='Retain unrelated historical review.';action='review-no-change';status='planned';validation='fixture';skill_id='rust-work-graph'}
        )
        prerequisites=@();allowed_repositories=@([pscustomobject][ordered]@{repo_id='fixture-source';allowed_paths=@('AGENTS.md','README.md','tools/')})
        claim_requirements=[pscustomobject][ordered]@{minimum_free_disk_mib=0;required_tools=@();product_inputs=@()}
        non_scope=@('Real repositories, remotes, products, and devices.');acceptance=@([pscustomobject][ordered]@{acceptance_id='fixture';proof='The focused fixture passes.';command='Test-HistoricalUnitCompatibilityProjection.ps1'})
        risk_tier='deep';device_requirement='none';validation=$validation;outputs=@('Authenticated projection fixture.');commit_policy='Temporary fixture only.';push_checkpoint='local-only'
        read_only_dependencies=@();resource_requirements=@();source_composition=[pscustomobject][ordered]@{mode='observed-working-copies';lock_path=$null;materialization_receipt=$null}
    }
}

function New-HucOwnerFixture {
    param([string]$Root)
    $projectId='historical-compatibility-fixture';$oldId='legacy-validator-unit';$withdrawId='withdrawn-validator-unit';$currentId='current-validator-unit'
    & (Join-Path $PSScriptRoot 'New-ProjectWorkspace.ps1') -ProjectRoot $Root -ProjectId $projectId -Purpose 'Historical compatibility fixture.' -Execute|Out-Null
    $workspace=Join-Path $Root 'morphospace'
    $projectPath=Join-Path $workspace 'project.spec.json';$project=Read-MorphospaceProtocolJson $projectPath
    $project.repositories=@([pscustomobject][ordered]@{repo_id='fixture-source';role='application';path='..';allowed_paths=@('AGENTS.md','README.md','tools/')})
    $project.validation_profiles=@(@($project.validation_profiles)+[pscustomobject][ordered]@{profile_id='host';commands=@('pwsh -File tools/check_all.ps1')})
    Write-HucTestJson $projectPath $project
    $old=New-HucTestUnit $projectId $oldId active -LegacyProfiles
    $withdraw=New-HucTestUnit $projectId $withdrawId proposed
    $current=New-HucTestUnit $projectId $currentId proposed
    foreach($unit in @($old,$withdraw,$current)){Write-HucTestJson (Join-Path $workspace "iteration-units\$([string]$unit.unit_id).json") $unit}
    $statePath=Join-Path $workspace 'workspace.state.json';$state=Read-MorphospaceProtocolJson $statePath;$state.current_unit=$oldId;$state.next_ready_unit=$null;$state.last_event_id=$null;Write-HucTestJson $statePath $state
    $eventsPath=Join-Path $workspace 'iteration-events.jsonl';[IO.File]::WriteAllBytes($eventsPath,[byte[]]::new(0))
    $fixed='2026-01-02T03:04:05.0000000Z'
    # These two Ready records are immutable pre-W-013 history.  Build their
    # authenticated ledger transitions directly; fixture construction grants
    # no current admission authority.  Today's Ready must still reject this
    # deliberately unresolved legacy instruction shape.
    $rejectedReadyPaths=@($statePath,(Join-Path $workspace "iteration-units\\$withdrawId.json"),$eventsPath)
    $rejectedReadyBefore=@($rejectedReadyPaths|ForEach-Object{[pscustomobject]@{path=$_;sha256=Get-MorphospaceFileSha256 $_}})
    $transactionRoot=Join-Path $workspace 'receipts\transactions'
    $rejectedReadyInventory=if(Test-Path $transactionRoot){@([IO.Directory]::EnumerateFiles($transactionRoot,'*',[IO.SearchOption]::AllDirectories)|ForEach-Object{[pscustomobject]@{path=$_.FullName.Substring($transactionRoot.Length);sha256=Get-MorphospaceFileSha256 $_.FullName}}|Sort-Object path)}else{@()}
    Assert-HucRejected { Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $workspace -UnitId $withdrawId -Timestamp $fixed -Execute } 'Ready preflight blocked: instruction action instruction-action-mode-mismatch instruction-surface-unresolved' 'current Ready rejects unresolved legacy instruction surfaces with both closed action reasons'
    $rejectedReadyAfter=@($rejectedReadyPaths|ForEach-Object{[pscustomobject]@{path=$_;sha256=Get-MorphospaceFileSha256 $_}})
    $rejectedReadyInventoryAfter=if(Test-Path $transactionRoot){@([IO.Directory]::EnumerateFiles($transactionRoot,'*',[IO.SearchOption]::AllDirectories)|ForEach-Object{[pscustomobject]@{path=$_.FullName.Substring($transactionRoot.Length);sha256=Get-MorphospaceFileSha256 $_.FullName}}|Sort-Object path)}else{@()}
    Assert-HucTest ((($rejectedReadyBefore|ConvertTo-Json -Compress)-ceq($rejectedReadyAfter|ConvertTo-Json -Compress)) -and (($rejectedReadyInventory|ConvertTo-Json -Compress)-ceq($rejectedReadyInventoryAfter|ConvertTo-Json -Compress))) 'rejected current Ready preserves state, unresolved unit, ledger bytes, and transaction inventory'
    $withdrawTarget=Copy-HucTestValue (Read-MorphospaceProtocolJson (Join-Path $workspace "iteration-units\\$withdrawId.json"));$withdrawTarget.status='ready'
    $withdrawState=Copy-HucTestValue (Read-MorphospaceProtocolJson $statePath);$withdrawState.next_ready_unit=$withdrawId
    Add-HucTestTransition -Workspace $workspace -UnitId $withdrawId -EventId "$withdrawId-ready-0001" -Timestamp $fixed -EventType state-transition -Summary 'Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites.' -TargetState $withdrawState -TargetUnit $withdrawTarget
    $withdrawReceipt=Join-Path $workspace 'receipts\withdrawn-validator-unit-withdraw-ready.json'
    Invoke-MorphospaceWorkUnitAutomation -Action WithdrawReady -WorkspaceRoot $workspace -UnitId $withdrawId -Timestamp '2026-01-02T03:05:05.0000000Z' -OutPath $withdrawReceipt -Execute|Out-Null
    $currentTarget=Copy-HucTestValue (Read-MorphospaceProtocolJson (Join-Path $workspace "iteration-units\\$currentId.json"));$currentTarget.status='ready'
    $currentReadyState=Copy-HucTestValue (Read-MorphospaceProtocolJson $statePath);$currentReadyState.next_ready_unit=$currentId
    Add-HucTestTransition -Workspace $workspace -UnitId $currentId -EventId "$currentId-ready-0003" -Timestamp '2026-01-02T03:06:05.0000000Z' -EventType state-transition -Summary 'Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites.' -TargetState $currentReadyState -TargetUnit $currentTarget
    $state=Read-MorphospaceProtocolJson $statePath;$current=Read-MorphospaceProtocolJson (Join-Path $workspace "iteration-units\$currentId.json");$old=Read-MorphospaceProtocolJson (Join-Path $workspace "iteration-units\$oldId.json")
    $eventId="$oldId-superseded-by-$currentId";$targetState=Copy-HucTestValue $state;$targetState.current_unit=$currentId;$targetState.next_ready_unit=$null;$targetState.last_event_id=$eventId
    $targetUnit=Copy-HucTestValue $current;$targetUnit.status='active'
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=4;timestamp='2026-01-02T03:07:05.0000000Z';project_id=$projectId;unit_id=$oldId;event_type='state-transition';summary='Superseded the immutable active fixture with its exact ready replacement.';receipts=@()}
    Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath "iteration-units/$currentId.json" -EventsPath 'iteration-events.jsonl' `
        -TargetState $targetState -TargetUnit $targetUnit -Event $event -ExpectedStateSha256 (Get-MorphospaceCanonicalJsonSha256 $state) -ExpectedUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $current) `
        -ExpectedEventTailId ([string]$state.last_event_id) -ExpectedEventsSha256 (Get-MorphospaceFileSha256 $eventsPath) -ExpectedEventsLength ([IO.FileInfo]::new($eventsPath).Length) `
        -ExpectedSupersededUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $old)|Out-Null
    [pscustomobject][ordered]@{workspace=$workspace;project_id=$projectId;old_id=$oldId;withdraw_id=$withdrawId;current_id=$currentId;receipt_id='historical-compatibility-fixture-projection'}
}

if(-not $SelfTest){$SelfTest=$true}
$root=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-historical-compatibility-'+[guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $fixture=New-HucOwnerFixture (Join-Path $root 'positive')
    $oldPath=Join-Path $fixture.workspace "iteration-units\$($fixture.old_id).json";$withdrawPath=Join-Path $fixture.workspace "iteration-units\$($fixture.withdraw_id).json"
    $oldRaw=Get-MorphospaceFileSha256 $oldPath;$withdrawRaw=Get-MorphospaceFileSha256 $withdrawPath
    $projectionInput=Join-Path $root 'projection-input.json'
    & (Join-Path $PSScriptRoot 'New-HistoricalUnitCompatibilityProjection.ps1') -WorkspaceRoot $fixture.workspace -ValidationUnitId $fixture.old_id -WithdrawnUnitId $fixture.withdraw_id -ReceiptId $fixture.receipt_id -Timestamp '2026-01-02T03:08:05.0000000Z' -OutPath $projectionInput|Out-Null
    $inputHash=Get-MorphospaceFileSha256 $projectionInput;$out=Join-Path $fixture.workspace "receipts\$($fixture.receipt_id).json"
    $beforeState=Read-MorphospaceProtocolJson (Join-Path $fixture.workspace 'workspace.state.json')
    $cli=Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'
    $dryLines=@(& pwsh -NoProfile -File $cli -Action RecordHistoricalUnitCompatibilityProjection -WorkspaceRoot $fixture.workspace -UnitId $fixture.current_id -HistoricalUnitCompatibilityProjection $projectionInput -OutPath $out)
    if($LASTEXITCODE-ne0){throw 'Historical compatibility CLI dry run failed.'}
    $dry=ConvertFrom-HucCliOutput $dryLines 'Historical compatibility CLI dry run'
    Assert-HucTest (-not $dry.executed -and -not(Test-Path $out)) 'dry run preserves workspace bytes'
    $runLines=@(& pwsh -NoProfile -File $cli -Action RecordHistoricalUnitCompatibilityProjection -WorkspaceRoot $fixture.workspace -UnitId $fixture.current_id -HistoricalUnitCompatibilityProjection $projectionInput -ExpectedHistoricalUnitCompatibilityProjectionSha256 $inputHash -OutPath $out -Execute)
    if($LASTEXITCODE-ne0){throw 'Historical compatibility CLI execute failed.'}
    $run=ConvertFrom-HucCliOutput $runLines 'Historical compatibility CLI execute'
    $verified=Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $fixture.workspace -ReceiptPath $out -Mode PostApply
    $map=Get-MorphospaceHistoricalUnitCompatibilityProjectionMap -WorkspaceRoot $fixture.workspace -ProjectId $fixture.project_id
    Assert-HucTest ($run.executed -and $verified.authenticated -and $map.Count -eq 3) 'owner-produced positive projection authenticates exactly two historical targets plus its bounded authority continuation mapping'
    Assert-HucTest ((Get-MorphospaceFileSha256 $oldPath)-ceq$oldRaw -and (Get-MorphospaceFileSha256 $withdrawPath)-ceq$withdrawRaw) 'historical unit bytes remain exact'
    $afterState=Read-MorphospaceProtocolJson (Join-Path $fixture.workspace 'workspace.state.json');$expectedState=Copy-HucTestValue $beforeState;$expectedState.last_event_id=[string]$run.event_id
    Assert-HucTest ((Get-MorphospaceCanonicalJsonSha256 $expectedState)-ceq(Get-MorphospaceCanonicalJsonSha256 $afterState) -and [string]$afterState.current_unit-ceq$fixture.current_id -and $null-eq$afterState.next_ready_unit) 'projection changes only the event tail and preserves current/next authority'
    Assert-HucTest (-not$verified.acceptance_inferred -and -not$verified.instruction_execution_inferred -and -not$verified.publication_authority) 'projection infers no completion, execution, acceptance, or publication authority'
    Assert-HucRejected {Invoke-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $fixture.workspace -UnitId $fixture.current_id -CompatibilityProjection $projectionInput -ExpectedCompatibilityProjectionSha256 $inputHash -OutPath $out -Execute} '*pre-apply current-state or ledger CAS drifted*' 'stale replay is rejected before output replacement'

    $authorityPath=Join-Path $fixture.workspace "iteration-units\$($fixture.current_id).json"
    $instructionEventId="$($fixture.current_id)-instructions-recorded";$instructionReceiptRelative="receipts/$($fixture.current_id)-instructions.json";$instructionReceiptPath=Join-Path $fixture.workspace $instructionReceiptRelative
    $instructionReceiptSource=Join-Path $root "$($fixture.current_id)-instructions-source.json"
    $instructionState=Copy-HucTestValue (Read-MorphospaceProtocolJson (Join-Path $fixture.workspace 'workspace.state.json'))
    $instructionUnit=Copy-HucTestValue (Read-MorphospaceProtocolJson $authorityPath);$instructionPreSha=Get-MorphospaceCanonicalJsonSha256 $instructionUnit
    foreach($surface in @($instructionUnit.instruction_surfaces)){$surface.status='complete'}
    $instructionResultSha=Get-MorphospaceCanonicalJsonSha256 $instructionUnit
    $instructionState.dirty_repositories=@($instructionState.dirty_repositories|Where-Object{[string]$_-cne'fixture-source'})
    $instructionState.repository_heads=@(@($instructionState.repository_heads|Where-Object{[string]$_.repo_id-cne'fixture-source'})+[pscustomobject][ordered]@{repo_id='fixture-source';head=('1'*40);branch='main';dirty_fingerprint='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'}|Sort-Object repo_id)
    $instructionReceipt=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.work_unit_automation_receipt.v1';project_id=$fixture.project_id;unit_id=$fixture.current_id;action='CompleteInstructionSurfaces';timestamp='2026-01-02T03:09:05.0000000Z';executed=$true
        transition='planned-instruction-surfaces-to-complete';status_before='active';status_after='active';current_unit_before=$fixture.current_id;current_unit_after=$fixture.current_id
        preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;force_push_allowed=$false;repository_states=@([pscustomobject][ordered]@{repo_id='fixture-source';available=$true;is_git=$true;head=('1'*40);tree=('2'*40);branch='main';upstream=$null;dirty=$false;tracked_changes=0;untracked_changes=0;ahead=$null;behind=$null;diverged=$false;relation='no-upstream'})}
        instruction_surface_completion=[pscustomobject][ordered]@{completion_id="$($fixture.current_id)-instructions";expected_unit_sha256=$instructionPreSha;resulting_unit_sha256=$instructionResultSha;observation_sha256=('3'*64);all_planned_surfaces_completed=$true;surface_files_observed_stable=$true;validation_commands_executed=$false;surfaces=@()}
        event_id=$instructionEventId
    }
    Write-HucTestJson $instructionReceiptSource $instructionReceipt
    Add-HucTestTransition -Workspace $fixture.workspace -UnitId $fixture.current_id -EventId $instructionEventId -Timestamp '2026-01-02T03:09:05.0000000Z' -EventType state-transition -Summary 'Completed the exact declared instruction-surface set after stable content observation without executing validation commands.' -TargetState $instructionState -TargetUnit $instructionUnit -Receipts @($instructionReceiptRelative) -Artifacts @([pscustomobject]@{source_path=$instructionReceiptSource;path=$instructionReceiptRelative;sha256=Get-MorphospaceFileSha256 $instructionReceiptSource})

    $validatingEventId="$($fixture.current_id)-validating-0007";$validatingState=Copy-HucTestValue (Read-MorphospaceProtocolJson (Join-Path $fixture.workspace 'workspace.state.json'));$validatingUnit=Copy-HucTestValue (Read-MorphospaceProtocolJson $authorityPath);$validatingUnit.status='validating'
    Add-HucTestTransition -Workspace $fixture.workspace -UnitId $fixture.current_id -EventId $validatingEventId -Timestamp '2026-01-02T03:10:05.0000000Z' -EventType state-transition -Summary 'Entered validation with a deterministic command, instruction, graph, and device-impact plan.' -TargetState $validatingState -TargetUnit $validatingUnit

    $validationEvidencePath=Join-Path $fixture.workspace 'receipts\fixture-evidence.txt';Write-HucTestText $validationEvidencePath 'fixture evidence'
    $validationReceiptRelative="receipts/$($fixture.current_id)-validation.json";$validationReceiptPath=Join-Path $fixture.workspace $validationReceiptRelative
    $validationReceipt=[pscustomobject][ordered]@{
        '$schema'='validation-receipt.schema.json';schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id="$($fixture.current_id)-validation";project_id=$fixture.project_id;unit_id=$fixture.current_id;created_at='2026-01-02T03:11:05Z';tier='deep';result='pass'
        repository_revisions=@([pscustomobject][ordered]@{repo_id='fixture-source';base_revision=('0'*40);head_revision=('1'*40);branch='main'});changed_paths=@()
        artifacts=@([pscustomobject][ordered]@{artifact_id='fixture-evidence';kind='validation-summary';path='fixture-evidence.txt';sha256=Get-MorphospaceFileSha256 $validationEvidencePath})
        criteria=@([pscustomobject][ordered]@{acceptance_id='fixture';status='pass';command='Test-HistoricalUnitCompatibilityProjection.ps1';evidence_refs=@('fixture-evidence')})
        gates=@([pscustomobject][ordered]@{gate_id='validation-host';status='pass';command='fixture';evidence_refs=@('fixture-evidence')});device_validation=$null
    }
    Write-HucTestJson $validationReceiptPath $validationReceipt
    $validationEventId="$($fixture.current_id)-validation-pass-0008";$validationState=Copy-HucTestValue (Read-MorphospaceProtocolJson (Join-Path $fixture.workspace 'workspace.state.json'));$validationState.validation_checkpoint=[pscustomobject][ordered]@{tier='deep';receipt=$validationReceiptRelative;result='pass'};$validationUnit=Copy-HucTestValue (Read-MorphospaceProtocolJson $authorityPath)
    Add-HucTestTransition -Workspace $fixture.workspace -UnitId $fixture.current_id -EventId $validationEventId -Timestamp '2026-01-02T03:11:05.0000000Z' -EventType validation -Summary 'Recorded passing validation; acceptance remains a separate explicit transition.' -TargetState $validationState -TargetUnit $validationUnit -Receipts @($validationReceiptRelative)

    $acceptedEventId="$($fixture.current_id)-accepted-0009";$acceptedState=Copy-HucTestValue (Read-MorphospaceProtocolJson (Join-Path $fixture.workspace 'workspace.state.json'));$acceptedState.current_unit=$null;$acceptedState.next_ready_unit=$null;$acceptedState.last_accepted_receipt=$validationReceiptRelative;$acceptedUnit=Copy-HucTestValue (Read-MorphospaceProtocolJson $authorityPath);$acceptedUnit.status='accepted'
    Add-HucTestTransition -Workspace $fixture.workspace -UnitId $fixture.current_id -EventId $acceptedEventId -Timestamp '2026-01-02T03:12:05.0000000Z' -EventType state-transition -Summary 'Accepted the unit after passing validation and instruction synchronization.' -TargetState $acceptedState -TargetUnit $acceptedUnit -Receipts @($validationReceiptRelative)
    $terminalVerified=Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $fixture.workspace -ReceiptPath $out -Mode PostApply
    $terminalMap=Get-MorphospaceHistoricalUnitCompatibilityProjectionMap -WorkspaceRoot $fixture.workspace -ProjectId $fixture.project_id
    Assert-HucTest ($terminalVerified.terminal_accepted -and $terminalVerified.continuation_event_count-eq4 -and $terminalMap.Count-eq3) 'exact owner-ledger instruction, deep pass, and Accept suffix remains authenticated after terminal closure'
    Assert-HucTest ((Read-MorphospaceProtocolJson $authorityPath).status-ceq'accepted' -and $null-eq(Read-MorphospaceProtocolJson (Join-Path $fixture.workspace 'workspace.state.json')).current_unit) 'terminal continuation derives accepted status with null current authority'

    $closureDamageCases=@(
        [pscustomobject]@{name='missing-accept-completion';message='*Workspace artifact is missing*'},
        [pscustomobject]@{name='detached-begin-intent';message='*completion is detached from its intent or targets*'},
        [pscustomobject]@{name='terminal-live-state-drift';message='*derived live state document drifted*'},
        [pscustomobject]@{name='terminal-live-unit-drift';message='*derived live authority unit document drifted*'}
    )
    foreach($damage in $closureDamageCases){
        $copyRoot=Copy-HucTestWorkspace (Split-Path $fixture.workspace -Parent) (Join-Path $root "closure-$($damage.name)");$copyWorkspace=Join-Path $copyRoot 'morphospace'
        switch([string]$damage.name){
            'missing-accept-completion' {Remove-Item -LiteralPath (Join-Path $copyWorkspace "receipts\transactions\$acceptedEventId-transition.completion.json") -Force}
            'detached-begin-intent' {[IO.File]::AppendAllText((Join-Path $copyWorkspace "receipts\transactions\$validatingEventId-transition.intent.json"),' ',$encoding)}
            'terminal-live-state-drift' {$p=Join-Path $copyWorkspace 'workspace.state.json';$d=Read-MorphospaceProtocolJson $p;$d.current_unit=$fixture.current_id;Write-HucTestJson $p $d}
            'terminal-live-unit-drift' {$p=Join-Path $copyWorkspace "iteration-units\$($fixture.current_id).json";$d=Read-MorphospaceProtocolJson $p;$d.status='validating';Write-HucTestJson $p $d}
            default {throw "Unknown closure damage case '$([string]$damage.name)'."}
        }
        $copyReceipt=Join-Path $copyWorkspace "receipts\$($fixture.receipt_id).json";$damagePattern=[string]$damage.message
        Assert-HucRejected {Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $copyWorkspace -ReceiptPath $copyReceipt -Mode PostApply} $damagePattern "closure damage '$($damage.name)' rejects at its intended boundary"
    }

    $damageFixture=New-HucOwnerFixture (Join-Path $root 'damage-base')
    $damageInput=Join-Path $root 'damage-input.json'
    & (Join-Path $PSScriptRoot 'New-HistoricalUnitCompatibilityProjection.ps1') -WorkspaceRoot $damageFixture.workspace -ValidationUnitId $damageFixture.old_id -WithdrawnUnitId $damageFixture.withdraw_id -ReceiptId $damageFixture.receipt_id -Timestamp '2026-01-02T03:08:05.0000000Z' -OutPath $damageInput|Out-Null

    $damageCases=@(
        [pscustomobject]@{name='missing-mapping';message='*not valid with the schema*';mutate={param($r)$r.targets[0].validation_profiles=@($r.targets[0].validation_profiles[0])}},
        [pscustomobject]@{name='extra-mapping';message='*not valid with the schema*';mutate={param($r)$r.targets[0].validation_profiles=@($r.targets[0].validation_profiles)+[pscustomobject]@{legacy='other';current='host';command_sha256=('0'*64)}}},
        [pscustomobject]@{name='reordered-mapping';message='*not valid with the schema*';mutate={param($r)$r.targets[0].validation_profiles=@($r.targets[0].validation_profiles[1],$r.targets[0].validation_profiles[0])}},
        [pscustomobject]@{name='broadened-skill';message='*not valid with the schema*';mutate={param($r)$r.targets[1].instruction_actions[0].effective_action='review-no-change'}},
        [pscustomobject]@{name='missing-authority-mapping';message='*not valid with the schema*';mutate={param($r)$r.authority_instruction_actions=@($r.authority_instruction_actions[0])}},
        [pscustomobject]@{name='broadened-authority-mapping';message='*not valid with the schema*';mutate={param($r)$r.authority_instruction_actions[0].effective_action='review-no-change'}},
        [pscustomobject]@{name='acceptance-inference';message='*not valid with the schema*';mutate={param($r)$r.limitations.acceptance_inferred=$true}},
        [pscustomobject]@{name='registered-host-drift';message='*registered host contract drifted*';mutate={param($r)$r.registered_host_profile.profile_sha256='0'*64}},
        [pscustomobject]@{name='supersession-intent-drift';message='*intent file hash drifted*';mutate={param($r)$r.targets[0].supersession.intent_sha256='0'*64}},
        [pscustomobject]@{name='ready-completion-drift';message='*completion file hash drifted*';mutate={param($r)$r.targets[1].ready.completion_sha256='0'*64}},
        [pscustomobject]@{name='withdraw-event-drift';message='*sequence or immutable line hash drifted*';mutate={param($r)$r.targets[1].withdraw_ready.event_sha256='0'*64}}
    )
    foreach($damage in $damageCases){
        $path=Join-Path $root "$($damage.name).json";$doc=Read-MorphospaceProtocolJson $damageInput;&$damage.mutate $doc;Write-HucTestJson $path $doc
        $damagePattern=[string]$damage.message
        Assert-HucRejected {Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $damageFixture.workspace -ReceiptPath $path -Mode PreApply} $damagePattern "damage '$($damage.name)' rejects at its intended boundary"
    }

    $currentInput=Join-Path $root 'current-target-input.json';Copy-Item $damageInput $currentInput
    $doc=Read-MorphospaceProtocolJson $currentInput;$doc.targets[0].unit_id=$fixture.current_id;$doc.targets[0].unit_path="iteration-units/$($fixture.current_id).json";Write-HucTestJson $currentInput $doc
    Assert-HucRejected {Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $damageFixture.workspace -ReceiptPath $currentInput -Mode PreApply} '*current or next-ready*' 'current target rejects'

    $liveDamageCases=@(
        [pscustomobject]@{name='missing-ready-intent';message='*Workspace artifact is missing*';mutate={param($w)Remove-Item -LiteralPath (Join-Path $w 'receipts\transactions\withdrawn-validator-unit-ready-0001-transition.intent.json') -Force}},
        [pscustomobject]@{name='damaged-withdraw-completion';message='*completion file hash drifted*';mutate={param($w)[IO.File]::AppendAllText((Join-Path $w 'receipts\transactions\withdrawn-validator-unit-ready-withdrawn-0002-transition.completion.json'),' ', $encoding)}},
        [pscustomobject]@{name='missing-supersession-intent';message='*Workspace artifact is missing*';mutate={param($w)Remove-Item -LiteralPath (Join-Path $w 'receipts\transactions\legacy-validator-unit-superseded-by-current-validator-unit-transition.intent.json') -Force}},
        [pscustomobject]@{name='immutable-validation-unit-drift';message='*immutable bytes drifted*';mutate={param($w)[IO.File]::AppendAllText((Join-Path $w 'iteration-units\legacy-validator-unit.json'),' ', $encoding)}},
        [pscustomobject]@{name='current-state-drift';message='*current/next projection drifted*';mutate={param($w)$p=Join-Path $w 'workspace.state.json';$d=Read-MorphospaceProtocolJson $p;$d.current_unit='legacy-validator-unit';Write-HucTestJson $p $d}}
    )
    foreach($damage in $liveDamageCases){
        $copyRoot=Copy-HucTestWorkspace (Split-Path $damageFixture.workspace -Parent) (Join-Path $root "live-$($damage.name)")
        $copyWorkspace=Join-Path $copyRoot 'morphospace';&$damage.mutate $copyWorkspace
        $damagePattern=[string]$damage.message
        Assert-HucRejected {Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $copyWorkspace -ReceiptPath $damageInput -Mode PreApply} $damagePattern "live damage '$($damage.name)' rejects at its intended boundary"
    }

    $raceFixture=New-HucOwnerFixture (Join-Path $root 'race');$raceInput=Join-Path $root 'race-input.json'
    & (Join-Path $PSScriptRoot 'New-HistoricalUnitCompatibilityProjection.ps1') -WorkspaceRoot $raceFixture.workspace -ValidationUnitId $raceFixture.old_id -WithdrawnUnitId $raceFixture.withdraw_id -ReceiptId $raceFixture.receipt_id -Timestamp '2026-01-02T03:08:05.0000000Z' -OutPath $raceInput|Out-Null
    $raceBefore=Get-Content -Raw (Join-Path $raceFixture.workspace 'iteration-events.jsonl');$raceStatePath=Join-Path $raceFixture.workspace 'workspace.state.json'
    $raceHook={ $d=Get-Content -Raw -LiteralPath $raceStatePath|ConvertFrom-Json;$d.plan_revision=[int]$d.plan_revision+1;[IO.File]::WriteAllText($raceStatePath,(($d|ConvertTo-Json -Depth 100 -Compress)+"`n"),[Text.UTF8Encoding]::new($false)) }.GetNewClosure()
    Assert-HucRejected {Invoke-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $raceFixture.workspace -UnitId $raceFixture.current_id -CompatibilityProjection $raceInput -ExpectedCompatibilityProjectionSha256 (Get-MorphospaceFileSha256 $raceInput) -OutPath (Join-Path $raceFixture.workspace "receipts\$($raceFixture.receipt_id).json") -BeforeTransitionHook $raceHook -Execute} '*expected pre-state SHA-256*' 'mutex-protected state race rejects atomically'
    Assert-HucTest ($raceBefore-ceq(Get-Content -Raw (Join-Path $raceFixture.workspace 'iteration-events.jsonl'))) 'failed atomic projection appends no event'

    $faultFixture=New-HucOwnerFixture (Join-Path $root 'fault-repair');$faultInput=Join-Path $root 'fault-input.json'
    & (Join-Path $PSScriptRoot 'New-HistoricalUnitCompatibilityProjection.ps1') -WorkspaceRoot $faultFixture.workspace -ValidationUnitId $faultFixture.old_id -WithdrawnUnitId $faultFixture.withdraw_id -ReceiptId $faultFixture.receipt_id -Timestamp '2026-01-02T03:08:05.0000000Z' -OutPath $faultInput|Out-Null
    $faultOut=Join-Path $faultFixture.workspace "receipts\$($faultFixture.receipt_id).json";$faultLedger=Join-Path $faultFixture.workspace 'iteration-events.jsonl';$faultBefore=Get-Content -Raw $faultLedger
    Assert-HucRejected {Invoke-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $faultFixture.workspace -UnitId $faultFixture.current_id -CompatibilityProjection $faultInput -ExpectedCompatibilityProjectionSha256 (Get-MorphospaceFileSha256 $faultInput) -OutPath $faultOut -FaultAfter after-intent -Execute} '*Injected interruption after intent publication*' 'after-intent interruption is retained for owner repair'
    Assert-HucTest (($faultBefore-ceq(Get-Content -Raw $faultLedger)) -and -not(Test-Path $faultOut)) 'interrupted transaction changes no state, event, unit, or receipt projection'
    $faultEventId="$($faultFixture.receipt_id)-recorded"
    $repair=Complete-MorphospaceTransitionLedger -WorkspaceRoot $faultFixture.workspace -TransactionId "$faultEventId-transition" -Repair
    $repairVerified=Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $faultFixture.workspace -ReceiptPath $faultOut -Mode PostApply
    Assert-HucTest ($repair.status-ceq'committed' -and $repairVerified.authenticated -and @(Get-Content $faultLedger|Where-Object{$_}).Count-eq5) 'owner repair completes the interrupted projection exactly once'

    [pscustomobject][ordered]@{result='pass';assertion_count=$assertions.Count;owner_ready_withdraw=$true;owner_v2_supersession=$true;atomic_projection=$true;historical_bytes_mutated=$false;acceptance_inferred=$false;publication_authority=$false}|ConvertTo-Json -Compress
} finally {
    if(Test-Path $root){foreach($file in [IO.Directory]::EnumerateFiles($root,'*',[IO.SearchOption]::AllDirectories)){try{[IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal)}catch{}};[IO.Directory]::Delete($root,$true)}
}
