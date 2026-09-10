param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$protocolModule = Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$ledgerModule = Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1')
. (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')

function Assert-Retirement([bool]$Condition,[string]$Message){if(-not$Condition){throw "Proposed-unit retirement self-test failed: $Message"}}
function Test-RetirementSchemaAccepts([object]$Value,[string]$Schema){try{Test-Json -Json ($Value|ConvertTo-Json -Depth 64 -Compress) -SchemaFile $Schema -ErrorAction Stop}catch{$false}}
function Copy-RetirementObject([object]$Value){$Value|ConvertTo-Json -Depth 64|ConvertFrom-Json -DateKind String}
function New-TestLegacyRetirementEnvelope([object]$Owner){
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.work_unit_automation_receipt.v1';project_id=[string]$Owner.project_id;unit_id=[string]$Owner.unit_id;action='RetireProposed'
        timestamp=[string]$Owner.timestamp;executed=[bool]$Owner.executed;transition=[string]$Owner.transition;status_before=[string]$Owner.status_before;status_after=[string]$Owner.status_after
        current_unit_before=$Owner.current_unit_before;current_unit_after=$Owner.current_unit_after
        preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;force_push_allowed=$false;repository_states=@()}
        validation_matrix=@();graph_scope=[pscustomobject][ordered]@{fixture='self-contained'};claim_preflight=[pscustomobject][ordered]@{version='v1';ready_to_claim=$false;validation_tier='standard';requirements_declared=$false;disk=@();tools=@();product_inputs=@();writable_repositories=@();read_only_dependencies=@();instruction_surfaces=@();resources=@();validation_matrix=@();issues=@('test-only legacy adapter envelope')}
        adoption_receipt=$null;publication_closure=$null;published_planning_authority_adoption=$null;planned_publication=$null;planning_suffix_rewrite_recovery=$null
        published_prerequisite_suffix_reconciliation=$null;executed_prepared_publication_reconciliation=$null;instruction_surface_completion=$null;ready_withdrawal=$null
        proposed_retirement=$Owner.proposed_retirement;terminal_validation_selection_release=$null;push_plan=$null;event_id=$Owner.event_id
    }
}
function Get-RetirementInventory([string]$Workspace){
    $root=[IO.Path]::GetFullPath($Workspace);$rows=@(Get-ChildItem -LiteralPath $root -Recurse -File|Sort-Object FullName|ForEach-Object{[pscustomobject][ordered]@{path=$_.FullName.Substring($root.Length).TrimStart('\').Replace('\','/');sha256=Get-EnvelopeFileSha256 $_.FullName;bytes=$_.Length}})
    Get-EnvelopeCanonicalJsonSha256 $rows
}
function Copy-RetirementFixture([string]$Source,[string]$Root,[string]$Name){$target=Join-Path $Root $Name;Copy-Item -LiteralPath $Source -Destination $target -Recurse;return $target}
function Get-RetirementExecutionArguments([object]$Dry,[string]$Workspace,[string]$OutPath,[string]$Timestamp){
    $pre=$Dry.proposed_retirement.authenticated_preimage
    @{
        WorkspaceRoot=$Workspace;UnitId='u002';ReplacementUnitId='u003';RetirementReason='contract-invalid';OutPath=$OutPath;Timestamp=$Timestamp
        ExpectedStateSha256=[string]$pre.state_sha256;ExpectedUnitSha256=[string]$pre.unit_sha256;ExpectedUnitRawSha256=[string]$pre.unit_raw_sha256
        ExpectedEventsSha256=[string]$pre.events_sha256;ExpectedEventsLength=[long]$pre.events_length;ExpectedEventTailId=[string]$pre.event_tail_id
        ExpectedProposedRetirementBindingSha256=[string]$Dry.proposed_retirement.binding_sha256;Execute=$true
    }
}
function New-RetirementAdmittedFixture([string]$Root){
    $seed=New-EnvelopeAdmissionPreparedFixture -Root $Root -RepositoryRoot $repoRoot -TransitionLedgerModule $ledgerModule
    $admissionPath=Join-Path $Root 'u002-admission.json';Write-EnvelopeJson $admissionPath $seed.admission_template
    $out=Join-Path $seed.workspace 'receipts/u002-admission.json'
    $dry=Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $seed.workspace -DevelopmentUnitAdmission $admissionPath -OutPath $out -Timestamp '2026-08-25T00:01:00.0000000Z'
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $seed.workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 $dry.audit_receipt.sha256 -OutPath $out -Timestamp '2026-08-25T00:01:00.0000000Z' -Execute|Out-Null
    $seed.workspace
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('proposed-unit-retirement-'+[guid]::NewGuid().ToString('N'))
try{
    $admitted=New-RetirementAdmittedFixture (Join-Path $temp 'seed')
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
    $publicBefore=Get-Command Get-MorphospaceCanonicalJsonSha256 -ErrorAction Stop
    $ownerModule=Import-Module (Join-Path $PSScriptRoot 'ProposedUnitRetirement.psm1') -PassThru
    Assert-Retirement ($null-ne(Get-Command Get-MorphospaceCanonicalJsonSha256 -ErrorAction SilentlyContinue)) 'typed owner import removed a caller-visible dependency command'
    Assert-Retirement (@($ownerModule.ExportedFunctions.Keys).Count-eq1-and$ownerModule.ExportedFunctions.ContainsKey('Invoke-MorphospaceProposedUnitRetirement')) 'typed owner exported a private helper'
    $recoveryLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru

    $narrowWorkspace=Copy-RetirementFixture $admitted $temp 'narrow'
    $narrowOut=Join-Path $narrowWorkspace 'receipts/u002-contract-retirement.json';$timestamp='2026-08-25T00:01:30.0000000Z'
    $before=Get-RetirementInventory $narrowWorkspace
    $dry=Invoke-MorphospaceProposedUnitRetirement -WorkspaceRoot $narrowWorkspace -UnitId u002 -ReplacementUnitId u003 -OutPath $narrowOut -Timestamp $timestamp
    Assert-Retirement (-not$dry.executed-and$null-eq$dry.event_id-and[string]$dry.schema-ceq'rusty.morphospace.workflow.proposed_unit_retirement_receipt.v1'-and$before-ceq(Get-RetirementInventory $narrowWorkspace)) 'narrow dry run changed bytes or returned the wrong format'
    $execute=Get-RetirementExecutionArguments $dry $narrowWorkspace $narrowOut $timestamp
    $preserved=@('receipts/u002-admission.json','receipts/transactions/u002-admission-admitted-transition.intent.json','receipts/transactions/u002-admission-admitted-transition.completion.json')|ForEach-Object{[pscustomobject]@{path=$_;sha256=Get-EnvelopeFileSha256 (Join-Path $narrowWorkspace $_)}}
    $run=Invoke-MorphospaceProposedUnitRetirement @execute
    Assert-Retirement ($run.executed-and[string]$run.status_after-ceq'superseded'-and[string]$run.transaction.transaction_id-ceq"$([string]$run.event_id)-transition") 'narrow execution did not publish its exact result and transaction identity'
    Assert-Retirement (Test-Json -Json (Get-Content -LiteralPath $narrowOut -Raw) -SchemaFile (Join-Path $repoRoot 'schemas/proposed-unit-retirement-receipt-v1.schema.json')) 'narrow receipt fails its closed schema'
    $transactionBound=Copy-RetirementObject $dry;$transactionBound.transaction.transaction_id='a'*192;$transactionBound.proposed_retirement.authenticated_admission.transaction.transaction_id='b'*192
    $narrowSchema=Join-Path $repoRoot 'schemas/proposed-unit-retirement-receipt-v1.schema.json'
    Assert-Retirement (Test-RetirementSchemaAccepts $transactionBound $narrowSchema) 'narrow schema rejected its 192-character transaction identity boundary'
    $transactionBound.transaction.transaction_id='a'*193
    Assert-Retirement (-not(Test-RetirementSchemaAccepts $transactionBound $narrowSchema)) 'narrow schema accepted a 193-character retirement transaction identity'
    $transactionBound.transaction.transaction_id='a'*192;$transactionBound.proposed_retirement.authenticated_admission.transaction.transaction_id='b'*193
    Assert-Retirement (-not(Test-RetirementSchemaAccepts $transactionBound $narrowSchema)) 'narrow schema accepted a 193-character admission transaction identity'
    $offsetDry=Invoke-MorphospaceProposedUnitRetirement -WorkspaceRoot (Copy-RetirementFixture $admitted $temp 'narrow-offset-timestamp') -UnitId u002 -ReplacementUnitId u003 -OutPath (Join-Path $temp 'narrow-offset-timestamp/receipts/u002-contract-retirement.json') -Timestamp '2026-08-25T02:01:30+02:00'
    Assert-Retirement ([string]$offsetDry.timestamp-ceq'2026-08-25T00:01:30.0000000Z') 'narrow retirement did not canonicalize its timestamp'
    foreach($item in $preserved){Assert-Retirement ((Get-EnvelopeFileSha256 (Join-Path $narrowWorkspace $item.path))-ceq$item.sha256) "narrow retirement changed preserved evidence '$($item.path)'"}
    $replayRejected=$false;try{Invoke-MorphospaceProposedUnitRetirement @execute|Out-Null}catch{$replayRejected=$true};Assert-Retirement $replayRejected 'narrow retirement replayed a terminal unit'

    foreach($cas in @('state','unit','unit-raw','events','event-length','event-tail','binding')){
        $workspace=Copy-RetirementFixture $admitted $temp "stale-$cas";$out=Join-Path $workspace 'receipts/u002-contract-retirement.json';$candidateDry=Invoke-MorphospaceProposedUnitRetirement -WorkspaceRoot $workspace -UnitId u002 -ReplacementUnitId u003 -OutPath $out -Timestamp $timestamp;$arguments=Get-RetirementExecutionArguments $candidateDry $workspace $out $timestamp
        switch($cas){'state'{$arguments.ExpectedStateSha256='0'*64}'unit'{$arguments.ExpectedUnitSha256='0'*64}'unit-raw'{$arguments.ExpectedUnitRawSha256='0'*64}'events'{$arguments.ExpectedEventsSha256='0'*64}'event-length'{$arguments.ExpectedEventsLength=[long]$arguments.ExpectedEventsLength+1}'event-tail'{$arguments.ExpectedEventTailId='wrong-tail'}'binding'{$arguments.ExpectedProposedRetirementBindingSha256='0'*64}}
        $snapshot=Get-RetirementInventory $workspace;$rejected=$false;try{Invoke-MorphospaceProposedUnitRetirement @arguments|Out-Null}catch{$rejected=$true};Assert-Retirement ($rejected-and$snapshot-ceq(Get-RetirementInventory $workspace)) "narrow retirement accepted or mutated stale $cas CAS"
    }

    foreach($damage in @('admission-receipt','admission-completion','intervening-event')){
        $workspace=Copy-RetirementFixture $admitted $temp "damage-$damage";$out=Join-Path $workspace 'receipts/u002-contract-retirement.json'
        if($damage-ceq'admission-receipt'){[IO.File]::AppendAllText((Join-Path $workspace 'receipts/u002-admission.json'),' ')}
        elseif($damage-ceq'admission-completion'){$completionPath=Join-Path $workspace 'receipts/transactions/u002-admission-admitted-transition.completion.json';$completion=Read-EnvelopeProtocolJson $completionPath;$completion.transaction_id='wrong-transition';Write-EnvelopeJson $completionPath $completion}
        else{$state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$event=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unrelated-event';sequence=4;timestamp='2026-08-25T00:01:01.0000000Z';project_id='envelope-test';unit_id='u002';event_type='decision';summary='Unrelated event.';receipts=@()};[IO.File]::AppendAllText((Join-Path $workspace 'iteration-events.jsonl'),(($event|ConvertTo-Json -Compress)+"`n"));$state.last_event_id='unrelated-event';Write-EnvelopeJson (Join-Path $workspace 'workspace.state.json') $state}
        $snapshot=Get-RetirementInventory $workspace;$rejected=$false;try{Invoke-MorphospaceProposedUnitRetirement -WorkspaceRoot $workspace -UnitId u002 -ReplacementUnitId u003 -OutPath $out -Timestamp $timestamp|Out-Null}catch{$rejected=$true};Assert-Retirement ($rejected-and$snapshot-ceq(Get-RetirementInventory $workspace)) "narrow retirement accepted or mutated damaged $damage"
    }

    foreach($fault in @('after-intent','after-artifact','after-projection','after-event')){
        $workspace=Copy-RetirementFixture $admitted $temp "fault-$fault";$out=Join-Path $workspace 'receipts/u002-contract-retirement.json';$faultDry=Invoke-MorphospaceProposedUnitRetirement -WorkspaceRoot $workspace -UnitId u002 -ReplacementUnitId u003 -OutPath $out -Timestamp $timestamp;$arguments=Get-RetirementExecutionArguments $faultDry $workspace $out $timestamp;$arguments.TransitionFaultAfter=$fault
        $interrupted=$false;try{Invoke-MorphospaceProposedUnitRetirement @arguments|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption*'};Assert-Retirement $interrupted "narrow fault $fault did not interrupt"
        $transaction="$([string]$faultDry.transaction.transaction_id)";$recovered=&$recoveryLedgerModule {param($root,$id)Complete-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId $id -Repair} $workspace $transaction;$replayed=&$recoveryLedgerModule {param($root,$id)Complete-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId $id} $workspace $transaction
        Assert-Retirement ([string]$recovered.status-ceq'committed'-and[string]$replayed.status-ceq'already-committed'-and[string](Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json')).status-ceq'superseded'-and(Test-Path $out)) "narrow fault $fault did not resume idempotently"
    }

    $legacyA=Copy-RetirementFixture $admitted $temp 'legacy-private';$legacyOutA=Join-Path $legacyA 'receipts/u002-contract-retirement.json';$legacyFactory={param($context)New-TestLegacyRetirementEnvelope $context}
    $legacyDryArguments=@{ReceiptFormat='LegacyAutomationV1';WorkspaceRoot=$legacyA;UnitId='u002';ReplacementUnitId='u003';RetirementReason='contract-invalid';Timestamp=$timestamp;OutPath=$legacyOutA;LegacyEnvelopeFactory=$legacyFactory}
    $legacyDryA=&$ownerModule {param($arguments)Invoke-MorphospaceProposedUnitRetirementCore @arguments} $legacyDryArguments
    $legacyExecA=Get-RetirementExecutionArguments $legacyDryA $legacyA $legacyOutA $timestamp;$legacyExecA.ReceiptFormat='LegacyAutomationV1';$legacyExecA.LegacyEnvelopeFactory=$legacyFactory
    $legacyRunA=&$ownerModule {param($arguments)Invoke-MorphospaceProposedUnitRetirementCore @arguments} $legacyExecA

    $compatibilityModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkCompatibility.psm1') -PassThru
    foreach($dispatch in @(@{name='unknown';source=$narrowWorkspace;schema='rusty.morphospace.workflow.unknown_retirement.v1';message='*unsupported*'},@{name='narrow-as-legacy';source=$narrowWorkspace;schema='rusty.morphospace.workflow.work_unit_automation_receipt.v1';message='*schema*'},@{name='legacy-as-narrow';source=$legacyA;schema='rusty.morphospace.workflow.proposed_unit_retirement_receipt.v1';message='*schema*'})){
        $workspace=Copy-RetirementFixture $dispatch.source $temp "dispatch-$($dispatch.name)";$receiptPath=Join-Path $workspace 'receipts/u002-contract-retirement.json';$receipt=Read-EnvelopeProtocolJson $receiptPath;$receipt.schema=$dispatch.schema;Write-EnvelopeJson $receiptPath $receipt
        $event=@(Get-Content -LiteralPath (Join-Path $workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})[-1];$intentPath=Join-Path $workspace "receipts/transactions/$([string]$event.event_id)-transition.intent.json";$intent=Read-EnvelopeProtocolJson $intentPath;$intent.artifacts[0].sha256=Get-EnvelopeFileSha256 $receiptPath;$intent.artifacts[0].bytes_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($receiptPath));Write-EnvelopeJson $intentPath $intent;$completionPath=$intentPath.Replace('.intent.json','.completion.json');$completion=Read-EnvelopeProtocolJson $completionPath;$completion.intent.sha256=Get-EnvelopeFileSha256 $intentPath;Write-EnvelopeJson $completionPath $completion
        $transactionId="$([string]$event.event_id)-transition";$message='';try{$step=&$recoveryLedgerModule {param($root,$id)Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $root -TransactionId $id -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath 'iteration-units/u002.json' -ExpectedEventsPath 'iteration-events.jsonl'} $workspace $transactionId;&$compatibilityModule {param($root,$expected,$committed)Test-MorphospaceHistoricalProposedRetirement -WorkspaceRoot $root -ExpectedEvent $expected -CommittedStep $committed|Out-Null} $workspace $event $step}catch{$message=$_.Exception.Message};Assert-Retirement ($message-like[string]$dispatch.message) "current-work reader did not reject $($dispatch.name) retirement dispatch at its schema boundary (observed '$message')"
    }

    foreach($mutation in @('schema','action','event','binding','target','cas','non-lossless','context-binding','context-state','context-unit','context-event','publish')){
        $workspace=Copy-RetirementFixture $admitted $temp "callback-$mutation";$out=Join-Path $workspace 'receipts/u002-contract-retirement.json';$factory={param($context)$receipt=New-TestLegacyRetirementEnvelope $context;switch($mutation){'schema'{$receipt.schema='unknown'}'action'{$receipt.action='Inspect'}'event'{$receipt.event_id='wrong-event'}'binding'{$receipt.proposed_retirement.binding_sha256='0'*64}'target'{$receipt.status_after='superseded'}'cas'{$receipt.proposed_retirement.authenticated_preimage.state_sha256='0'*64}'non-lossless'{$receipt.timestamp=[DateTimeOffset]::Parse([string]$receipt.timestamp)}'context-binding'{$context.proposed_retirement.reason='other';$receipt.proposed_retirement=$context.proposed_retirement}'context-state'{$context.state.last_event_id='wrong'}'context-unit'{$context.unit.status='superseded'}'context-event'{$context.event=[pscustomobject]@{event_id='forged'}}'publish'{[IO.File]::WriteAllText((Join-Path $workspace 'receipts/transactions/u002-proposal-retired-0004-transition.intent.json'),'{}')}};return $receipt}.GetNewClosure()
        $arguments=@{ReceiptFormat='LegacyAutomationV1';WorkspaceRoot=$workspace;UnitId='u002';ReplacementUnitId='u003';RetirementReason='contract-invalid';OutPath=$out;Timestamp=$timestamp;LegacyEnvelopeFactory=$factory}
        $snapshot=Get-RetirementInventory $workspace;$rejected=$false;try{&$ownerModule {param($arguments)Invoke-MorphospaceProposedUnitRetirementCore @arguments} $arguments|Out-Null}catch{$rejected=$true};Assert-Retirement $rejected "private legacy callback accepted $mutation mutation"
        if($mutation-cne'publish'){Assert-Retirement ($snapshot-ceq(Get-RetirementInventory $workspace)) "private legacy callback $mutation changed workspace bytes"}
    }

    [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.proposed_unit_retirement_self_test.v1';status='pass';narrow_schema='rusty.morphospace.workflow.proposed_unit_retirement_receipt.v1';fault_cuts=4;stale_cas_cases=7;private_legacy_adapter_negative_cases=12;caller_command_preserved=([string]$publicBefore.Name)}|ConvertTo-Json -Depth 8
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
