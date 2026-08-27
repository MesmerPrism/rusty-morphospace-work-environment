param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoryArchive.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Assert-Archive([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "History archive checkpoint self-test failed: $Message" }
}

function Write-ArchiveJson([string]$Path, [object]$Value) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-MorphospaceCanonicalJson $Value) + "`n", [Text.UTF8Encoding]::new($false))
}

function Copy-ArchiveValue([object]$Value) { $Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 }
function Get-ArchiveCanonicalHash([object]$Value) { Get-MorphospaceCanonicalJsonSha256 -Value $Value }
function Get-ArchiveManagedHash([object]$Value) { Get-MorphospaceSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Value) + "`n")) }
function Get-ArchiveSourceInventoryHash([string]$Workspace) {
    $state = Read-MorphospaceProtocolJson (Join-Path $Workspace 'workspace.state.json')
    $archiveModule = Get-Module MorphospaceHistoryArchive
    return (& $archiveModule { param($Root,$PreState) $inventory = Get-HistoryArchiveSourceInventory -Workspace $Root -State $PreState; Get-HistoryArchiveHash (Get-HistoryArchiveInventoryCommitment -Records @($inventory.records) -Context 'fixture caller-pinned source inventory') } $Workspace $state)
}

function New-ArchiveWorkspace([string]$Root) {
    $workspace = Join-Path $Root 'workspace'
    foreach ($relative in @('iteration-units', 'receipts', 'morphospace')) { [IO.Directory]::CreateDirectory((Join-Path $workspace $relative)) | Out-Null }
    $project = [ordered]@{
        schema='rusty.morphospace.workflow.project_spec.v2'; project_id='archive-fixture'; revision=1; owner='fixture-owner'; purpose='portable archive fixture'
        activation_model=[ordered]@{default='disabled';unlisted_modules='inert';runtime_rule='selected-lock-and-runtime-input'}
        composition=[ordered]@{selected_features=@();denied_features=@();selected_modules=@();denied_modules=@();allowed_permissions=@();denied_permissions=@();data_classes=@()}
        authority_map=@([ordered]@{parameter='project.composition';owner='fixture-owner';adapters=@()})
        repositories=@([ordered]@{repo_id='planning';role='planning';path='.';allowed_paths=@('morphospace/')})
        modules=@(); non_scope=@('archive fixture does not materialize history'); validation_profiles=@([ordered]@{profile_id='quick';commands=@('fixture')}); acceptance_profiles=@([ordered]@{profile_id='rollback';commands=@('fixture')})
        release_policy=[ordered]@{versioning='semver';commit_policy='fixture';push_checkpoint='none';source_first=$true;planning_last=$true;force_push_allowed=$false}
        public_boundary=[ordered]@{mode='mixed';private_overlay='local/';prohibited_evidence=@('private-identities')}
    }
    $state = [ordered]@{
        schema='rusty.morphospace.workflow.workspace_state.v2'; project_id='archive-fixture'; plan_revision=1; current_unit=$null; next_ready_unit=$null
        last_event_id='u001-accepted'; last_accepted_receipt='receipts/u001-accepted.json'; repository_heads=@(); repository_checkpoints=@()
        module_registry=[ordered]@{lock_revision=$null;lock_fingerprint=$null;modules=@()}; capability_registry=@(); dirty_repositories=@(); blockers=@(); validation_checkpoint=$null; pending_push_bundle=$null
    }
    $unit = [ordered]@{schema='rusty.morphospace.workflow.iteration_unit.v1';project_id='archive-fixture';unit_id='u001';status='accepted'}
    $event = [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='u001-accepted';sequence=1;timestamp='2026-08-27T00:00:00.0000000Z';project_id='archive-fixture';unit_id='u001';event_type='state-transition';summary='Accepted portable fixture.';receipts=@('receipts/u001-accepted.json')}
    Write-ArchiveJson (Join-Path $workspace 'project.spec.json') $project
    Write-ArchiveJson (Join-Path $workspace 'workspace.state.json') $state
    Write-ArchiveJson (Join-Path $workspace 'iteration-units\u001.json') $unit
    Write-ArchiveJson (Join-Path $workspace 'receipts\u001-accepted.json') ([ordered]@{schema='fixture.receipt.v1';receipt_id='u001-accepted';project_id='archive-fixture';status='accepted'})
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'), (ConvertTo-MorphospaceCanonicalJson $event) + "`n", [Text.UTF8Encoding]::new($false))
    return $workspace
}

function New-ArchiveRequest([string]$Workspace, [string]$Path, [string]$CheckpointId = 'archive-001') {
    $project = Read-MorphospaceProtocolJson (Join-Path $Workspace 'project.spec.json')
    $state = Read-MorphospaceProtocolJson (Join-Path $Workspace 'workspace.state.json')
    $eventsPath = Join-Path $Workspace 'iteration-events.jsonl'
    $request = [ordered]@{
        schema='rusty.morphospace.workflow.history_archive_checkpoint.v1';record_kind='request';checkpoint_id=$CheckpointId;project_id='archive-fixture'
        expected=[ordered]@{project_sha256=(Get-ArchiveCanonicalHash $project);state_sha256=(Get-ArchiveCanonicalHash $state);events_sha256=(Get-MorphospaceFileSha256 $eventsPath);events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id='u001-accepted';source_inventory_sha256=(Get-ArchiveSourceInventoryHash $Workspace)}
        does_not_prove=@('Does not delete, move, rewrite, normalize, or substitute historical evidence.')
    }
    Write-ArchiveJson $Path $request
    return $request
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('workenv-history-archive-' + [guid]::NewGuid().ToString('N'))
try {
    $workspace = New-ArchiveWorkspace $temp
    $requestPath = Join-Path $workspace 'history-archive\requests\archive-001.json'
    [void](New-ArchiveRequest $workspace $requestPath)
    $outPath = Join-Path $workspace 'history-archive\checkpoints\archive-001.json'
    $dry = Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $workspace -HistoryArchiveCheckpoint $requestPath -OutPath $outPath -Timestamp '2026-08-27T00:01:00.0000000Z'
    Assert-Archive (-not $dry.executed -and $dry.action -ceq 'ArchiveHistoryCheckpoint' -and $dry.transition -ceq 'history-archive-checkpointed') 'dry run did not produce the typed automation receipt'
    $requestHash = Get-MorphospaceFileSha256 $requestPath
    $run = Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $workspace -HistoryArchiveCheckpoint $requestPath -ExpectedHistoryArchiveCheckpointSha256 $requestHash -OutPath $outPath -Timestamp '2026-08-27T00:01:00.0000000Z' -Execute
    Assert-Archive ($run.executed -and (Test-Path -LiteralPath $outPath) -and (Test-Path -LiteralPath (Join-Path $workspace 'history-archive\transactions\archive-001-archive-transition.completion.json'))) 'executed checkpoint did not materialize its typed transaction'
    $state = Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
    Assert-Archive ($null -eq $state.current_unit -and $null -eq $state.next_ready_unit -and $state.history_archive.checkpoint_id -ceq 'archive-001') 'checkpoint did not preserve the idle project state'
    Assert-Archive ((Test-Json -Json ($run | ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'))) 'automation receipt did not satisfy receipt-v2'
    $quick = Test-MorphospaceHistoryArchive -WorkspaceRoot $workspace -Tier quick
    $deep = Test-MorphospaceHistoryArchive -WorkspaceRoot $workspace -Tier deep
    Assert-Archive ($quick.status -ceq 'pass' -and $quick.mode -ceq 'tail-only') 'Quick did not validate the intact root, prefix, carry-forward, and live tail'
    Assert-Archive ((Test-Json -Json ($quick | ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\history-archive-validation-result-v1.schema.json'))) 'Quick archive validation result did not satisfy its typed schema'
    Assert-Archive ($deep.status -ceq 'pass' -and $deep.mode -ceq 'archive-replay' -and $deep.reason_codes -ccontains 'archive-replay-selected') 'Deep did not select archived replay'
    $receiptHashBeforeReplay = Get-MorphospaceFileSha256 $outPath
    $replay = Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $workspace -HistoryArchiveCheckpoint $requestPath -ExpectedHistoryArchiveCheckpointSha256 $requestHash -OutPath $outPath -Timestamp '2026-08-27T00:01:01.0000000Z' -Execute
    Assert-Archive ($replay.executed -and $receiptHashBeforeReplay -ceq (Get-MorphospaceFileSha256 $outPath)) 'exact completed replay was not byte-equivalent'
    $routerReplay = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action ArchiveHistoryCheckpoint -WorkspaceRoot $workspace -HistoryArchiveCheckpoint $requestPath -ExpectedHistoryArchiveCheckpointSha256 $requestHash -OutPath $outPath -Timestamp '2026-08-27T00:01:02.0000000Z' -Execute | ConvertFrom-Json
    Assert-Archive ($routerReplay.action -ceq 'ArchiveHistoryCheckpoint' -and $routerReplay.transition -ceq 'history-archive-checkpointed' -and $routerReplay.executed) 'public router did not preserve the typed archive receipt'
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoryArchive.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
    foreach ($cut in @('after-intent','after-objects','after-root','after-receipt','after-state','after-event')) {
        $recoveryRoot = Join-Path $temp ('recovery-' + $cut)
        Copy-Item -LiteralPath $workspace -Destination $recoveryRoot -Recurse
        $recoveryWorkspace = $recoveryRoot
        Remove-Item -LiteralPath (Join-Path $recoveryWorkspace 'history-archive') -Recurse -Force
        $recoveryState = Read-MorphospaceProtocolJson (Join-Path $recoveryWorkspace 'workspace.state.json'); $recoveryState.PSObject.Properties.Remove('history_archive'); $recoveryState.last_event_id='u001-accepted'; Write-ArchiveJson (Join-Path $recoveryWorkspace 'workspace.state.json') $recoveryState
        [IO.File]::WriteAllText((Join-Path $recoveryWorkspace 'iteration-events.jsonl'), (Get-Content -LiteralPath (Join-Path $recoveryWorkspace 'iteration-events.jsonl') -First 1) + "`n", [Text.UTF8Encoding]::new($false))
        $recoveryRequest = Join-Path $recoveryWorkspace 'history-archive\requests\archive-001.json'; [void](New-ArchiveRequest $recoveryWorkspace $recoveryRequest)
        $recoveryOut = Join-Path $recoveryWorkspace 'history-archive\checkpoints\archive-001.json'; $interrupted = $false
        try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $recoveryWorkspace -HistoryArchiveCheckpoint $recoveryRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $recoveryRequest) -OutPath $recoveryOut -Timestamp '2026-08-27T00:01:00.0000000Z' -Execute -FaultAfter $cut | Out-Null } catch { $interrupted = $true }
        $incomplete = Test-MorphospaceHistoryArchive -WorkspaceRoot $recoveryWorkspace -Tier quick
        Assert-Archive ($incomplete.status -ceq 'replay-required' -and $incomplete.reason_codes -ccontains 'incomplete-transaction') "recovery cut '$cut' incorrectly passed Quick before typed recovery"
        $resumed = Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $recoveryWorkspace -HistoryArchiveCheckpoint $recoveryRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $recoveryRequest) -OutPath $recoveryOut -Timestamp '2026-08-27T00:01:01.0000000Z' -Execute
        Assert-Archive ($interrupted -and $resumed.executed -and (Test-Path -LiteralPath $recoveryOut) -and (Test-MorphospaceHistoryArchive -WorkspaceRoot $recoveryWorkspace -Tier quick).status -ceq 'pass') "recovery cut '$cut' did not finish the exact durable transaction"
    }
    $staleRequest = Join-Path $workspace 'history-archive\requests\archive-002.json'; $stale = New-ArchiveRequest $workspace $staleRequest 'archive-002'; $stale.expected.events_length = [long]$stale.expected.events_length + 1; Write-ArchiveJson $staleRequest $stale
    $staleRejected = $false; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $workspace -HistoryArchiveCheckpoint $staleRequest -OutPath (Join-Path $workspace 'history-archive\checkpoints\archive-002.json') | Out-Null } catch { $staleRejected = $true }
    Assert-Archive $staleRejected 'stale event-offset preimage was accepted'
    $damageRoot = Join-Path $temp 'damage'; Copy-Item -LiteralPath $workspace -Destination $damageRoot -Recurse
    $damageWorkspace = $damageRoot; $damageState = Read-MorphospaceProtocolJson (Join-Path $damageWorkspace 'workspace.state.json'); $rootPath = Join-Path $damageWorkspace $damageState.history_archive.root_path.Replace('/','\\'); [IO.File]::AppendAllText($rootPath, 'tamper', [Text.UTF8Encoding]::new($false))
    $damageResult = Test-MorphospaceHistoryArchive -WorkspaceRoot $damageWorkspace -Tier quick
    Assert-Archive ($damageResult.status -ceq 'replay-required' -and $damageResult.reason_codes -ccontains 'root-tamper') 'root tamper was not fail-closed to archive replay'
    $objectRoot = Join-Path $temp 'object-damage'; Copy-Item -LiteralPath $workspace -Destination $objectRoot -Recurse
    $objectWorkspace = $objectRoot; $objectState = Read-MorphospaceProtocolJson (Join-Path $objectWorkspace 'workspace.state.json'); $objectDocument = Read-MorphospaceProtocolJson (Join-Path $objectWorkspace $objectState.history_archive.root_path.Replace('/','\\')); Remove-Item -LiteralPath (Join-Path $objectWorkspace ([string]$objectDocument.objects[0].object_path).Replace('/','\\')) -Force
    $objectResult = Test-MorphospaceHistoryArchive -WorkspaceRoot $objectWorkspace -Tier quick
    Assert-Archive ($objectResult.status -ceq 'replay-required') 'partial archive object was not fail-closed to archive replay'
    $eventRoot = Join-Path $temp 'event-damage'; Copy-Item -LiteralPath $workspace -Destination $eventRoot -Recurse
    [IO.File]::WriteAllText((Join-Path $eventRoot 'iteration-events.jsonl'), (Get-Content -LiteralPath (Join-Path $eventRoot 'iteration-events.jsonl') -First 1) + "`n", [Text.UTF8Encoding]::new($false))
    $eventResult = Test-MorphospaceHistoryArchive -WorkspaceRoot $eventRoot -Tier quick
    Assert-Archive ($eventResult.status -ceq 'replay-required' -and $eventResult.reason_codes -ccontains 'archive-event-missing') 'removed archive event was not fail-closed to archive replay'
    $intentRoot = Join-Path $temp 'intent-damage'; $intentWorkspace = New-ArchiveWorkspace $intentRoot
    $intentRequest = Join-Path $intentWorkspace 'history-archive\requests\archive-003.json'; [void](New-ArchiveRequest $intentWorkspace $intentRequest 'archive-003')
    $intentOut = Join-Path $intentWorkspace 'history-archive\checkpoints\archive-003.json'; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $intentWorkspace -HistoryArchiveCheckpoint $intentRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $intentRequest) -OutPath $intentOut -Timestamp '2026-08-27T00:01:00.0000000Z' -Execute -FaultAfter after-intent | Out-Null } catch { }
    $intentPath = Join-Path $intentWorkspace 'history-archive\transactions\archive-003-archive-transition.intent.json'; $tamperedIntent = Read-MorphospaceProtocolJson $intentPath; $tamperedIntent.target.state.sha256 = [string]$tamperedIntent.pre.state.sha256; $tamperedIntent.target.state.document = $tamperedIntent.pre.state.document; Write-ArchiveJson $intentPath $tamperedIntent
    $intentRejected = $false; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $intentWorkspace -HistoryArchiveCheckpoint $intentRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $intentRequest) -OutPath $intentOut -Timestamp '2026-08-27T00:01:01.0000000Z' -Execute | Out-Null } catch { $intentRejected = $true }
    Assert-Archive $intentRejected 'schema-valid target-state intent tamper was accepted during recovery'
    $objectIntentRoot = Join-Path $temp 'intent-object-damage'; $objectIntentWorkspace = New-ArchiveWorkspace $objectIntentRoot
    $objectIntentRequest = Join-Path $objectIntentWorkspace 'history-archive\requests\archive-004.json'; [void](New-ArchiveRequest $objectIntentWorkspace $objectIntentRequest 'archive-004')
    $objectIntentOut = Join-Path $objectIntentWorkspace 'history-archive\checkpoints\archive-004.json'; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $objectIntentWorkspace -HistoryArchiveCheckpoint $objectIntentRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $objectIntentRequest) -OutPath $objectIntentOut -Timestamp '2026-08-27T00:01:00.0000000Z' -Execute -FaultAfter after-intent | Out-Null } catch { }
    $objectIntentPath = Join-Path $objectIntentWorkspace 'history-archive\transactions\archive-004-archive-transition.intent.json'; $objectTamperedIntent = Read-MorphospaceProtocolJson $objectIntentPath; $objectTamperedIntent.objects = @($objectTamperedIntent.objects | Select-Object -Skip 1); Write-ArchiveJson $objectIntentPath $objectTamperedIntent
    $objectIntentRejected = $false; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $objectIntentWorkspace -HistoryArchiveCheckpoint $objectIntentRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $objectIntentRequest) -OutPath $objectIntentOut -Timestamp '2026-08-27T00:01:01.0000000Z' -Execute | Out-Null } catch { $objectIntentRejected = $true }
    $objectIntentState = Read-MorphospaceProtocolJson (Join-Path $objectIntentWorkspace 'workspace.state.json')
    Assert-Archive ($objectIntentRejected -and -not(Test-Path -LiteralPath $objectIntentOut) -and -not($objectIntentState.PSObject.Properties.Name -contains 'history_archive')) 'schema-valid intent object omission reached recovery state or receipt materialization'
    $coordinatedRoot = Join-Path $temp 'coordinated-inventory-damage'; $coordinatedWorkspace = New-ArchiveWorkspace $coordinatedRoot
    $coordinatedRequest = Join-Path $coordinatedWorkspace 'history-archive\requests\archive-005.json'; [void](New-ArchiveRequest $coordinatedWorkspace $coordinatedRequest 'archive-005')
    $coordinatedOut = Join-Path $coordinatedWorkspace 'history-archive\checkpoints\archive-005.json'; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $coordinatedWorkspace -HistoryArchiveCheckpoint $coordinatedRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $coordinatedRequest) -OutPath $coordinatedOut -Timestamp '2026-08-27T00:01:00.0000000Z' -Execute -FaultAfter after-intent | Out-Null } catch { }
    $coordinatedIntentPath = Join-Path $coordinatedWorkspace 'history-archive\transactions\archive-005-archive-transition.intent.json'; $coordinatedIntent = Read-MorphospaceProtocolJson $coordinatedIntentPath
    $coordinatedIntent.objects = @($coordinatedIntent.objects | Where-Object { [string]$_.source_path -cne 'iteration-units/u001.json' })
    $coordinatedArchiveRoot = $coordinatedIntent.root.document; $coordinatedArchiveRoot.objects = @($coordinatedArchiveRoot.objects | Where-Object { [string]$_.source_path -cne 'iteration-units/u001.json' })
    $coordinatedRootCanonicalHash = Get-ArchiveCanonicalHash $coordinatedArchiveRoot; $coordinatedRootRelative = "history-archive/roots/$coordinatedRootCanonicalHash.json"; $coordinatedRootRawHash = Get-ArchiveManagedHash $coordinatedArchiveRoot
    $coordinatedIntent.root.path = $coordinatedRootRelative; $coordinatedIntent.root.sha256 = $coordinatedRootRawHash
    $coordinatedTargetState = Copy-ArchiveValue $coordinatedIntent.pre.state.document; $coordinatedTargetState | Add-Member -NotePropertyName history_archive -NotePropertyValue ([ordered]@{checkpoint_id='archive-005';root_path=$coordinatedRootRelative;root_sha256=$coordinatedRootRawHash;source_prefix_sha256=[string]$coordinatedIntent.pre.events.sha256;source_prefix_length=[long]$coordinatedIntent.pre.events.byte_length}); $coordinatedTargetState.last_event_id = [string]$coordinatedIntent.event.event_id
    $coordinatedIntent.target.state.document = $coordinatedTargetState; $coordinatedIntent.target.state.sha256 = Get-ArchiveCanonicalHash $coordinatedTargetState
    $coordinatedReceipt = $coordinatedIntent.receipt.document; $coordinatedReceipt.root.path = $coordinatedRootRelative; $coordinatedReceipt.root.sha256 = $coordinatedRootRawHash; $coordinatedReceipt.state.sha256 = [string]$coordinatedIntent.target.state.sha256; $coordinatedReceipt.state.document = $coordinatedTargetState
    $coordinatedIntent.receipt.document = $coordinatedReceipt; $coordinatedIntent.receipt.sha256 = Get-ArchiveManagedHash $coordinatedReceipt; Write-ArchiveJson $coordinatedIntentPath $coordinatedIntent
    Remove-Item -LiteralPath (Join-Path $coordinatedWorkspace 'iteration-units\u001.json') -Force
    $coordinatedRejected = $false; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $coordinatedWorkspace -HistoryArchiveCheckpoint $coordinatedRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $coordinatedRequest) -OutPath $coordinatedOut -Timestamp '2026-08-27T00:01:01.0000000Z' -Execute | Out-Null } catch { $coordinatedRejected = $_.Exception.Message -like '*source inventory*' }
    $coordinatedState = Read-MorphospaceProtocolJson (Join-Path $coordinatedWorkspace 'workspace.state.json')
    Assert-Archive ($coordinatedRejected -and -not(Test-Path -LiteralPath $coordinatedOut) -and -not($coordinatedState.PSObject.Properties.Name -contains 'history_archive')) 'coordinated source deletion plus root and intent inventory omission reached recovery state or receipt materialization'
    $foreignTailRoot = Join-Path $temp 'foreign-tail-before-recovery'; $foreignTailWorkspace = New-ArchiveWorkspace $foreignTailRoot
    $foreignTailRequest = Join-Path $foreignTailWorkspace 'history-archive\requests\archive-006.json'; [void](New-ArchiveRequest $foreignTailWorkspace $foreignTailRequest 'archive-006')
    $foreignTailOut = Join-Path $foreignTailWorkspace 'history-archive\checkpoints\archive-006.json'; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $foreignTailWorkspace -HistoryArchiveCheckpoint $foreignTailRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $foreignTailRequest) -OutPath $foreignTailOut -Timestamp '2026-08-27T00:01:00.0000000Z' -Execute -FaultAfter after-intent | Out-Null } catch { }
    $foreignTailEvent = [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='u002-foreign';sequence=2;timestamp='2026-08-27T00:01:01.0000000Z';project_id='archive-fixture';unit_id='u001';event_type='decision';summary='Fixture conflicting predecessor tail.';receipts=@('receipts/u001-accepted.json')}
    $foreignTailEventsPath = Join-Path $foreignTailWorkspace 'iteration-events.jsonl'; [IO.File]::AppendAllText($foreignTailEventsPath, (ConvertTo-MorphospaceCanonicalJson $foreignTailEvent) + "`n", [Text.UTF8Encoding]::new($false)); $foreignTailBytes = [IO.File]::ReadAllBytes($foreignTailEventsPath)
    $foreignTailRejected = $false; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $foreignTailWorkspace -HistoryArchiveCheckpoint $foreignTailRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $foreignTailRequest) -OutPath $foreignTailOut -Timestamp '2026-08-27T00:01:02.0000000Z' -Execute | Out-Null } catch { $foreignTailRejected = $_.Exception.Message -like '*ledger conflicts*before persistence*' }
    $foreignTailState = Read-MorphospaceProtocolJson (Join-Path $foreignTailWorkspace 'workspace.state.json')
    Assert-Archive ($foreignTailRejected -and -not(Test-Path -LiteralPath $foreignTailOut) -and -not(Test-Path -LiteralPath (Join-Path $foreignTailWorkspace 'history-archive\objects')) -and -not($foreignTailState.PSObject.Properties.Name -contains 'history_archive') -and ([Convert]::ToHexString($foreignTailBytes) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes($foreignTailEventsPath)))) 'foreign predecessor tail wrote archive objects, receipt, state, or ledger bytes before conflict rejection'
    $kindRoot = Join-Path $temp 'root-kind-damage'; $kindWorkspace = New-ArchiveWorkspace $kindRoot
    $kindRequest = Join-Path $kindWorkspace 'history-archive\requests\archive-007.json'; [void](New-ArchiveRequest $kindWorkspace $kindRequest 'archive-007')
    $kindOut = Join-Path $kindWorkspace 'history-archive\checkpoints\archive-007.json'; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $kindWorkspace -HistoryArchiveCheckpoint $kindRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $kindRequest) -OutPath $kindOut -Timestamp '2026-08-27T00:01:00.0000000Z' -Execute -FaultAfter after-intent | Out-Null } catch { }
    $kindIntentPath = Join-Path $kindWorkspace 'history-archive\transactions\archive-007-archive-transition.intent.json'; $kindIntent = Read-MorphospaceProtocolJson $kindIntentPath; $kindArchiveRoot = $kindIntent.root.document; (@($kindArchiveRoot.objects | Where-Object { [string]$_.source_path -ceq 'iteration-units/u001.json' }))[0].kind = 'receipt'
    $kindRootCanonicalHash = Get-ArchiveCanonicalHash $kindArchiveRoot; $kindRootRelative = "history-archive/roots/$kindRootCanonicalHash.json"; $kindRootRawHash = Get-ArchiveManagedHash $kindArchiveRoot; $kindIntent.root.path = $kindRootRelative; $kindIntent.root.sha256 = $kindRootRawHash
    $kindTargetState = Copy-ArchiveValue $kindIntent.pre.state.document; $kindTargetState | Add-Member -NotePropertyName history_archive -NotePropertyValue ([ordered]@{checkpoint_id='archive-007';root_path=$kindRootRelative;root_sha256=$kindRootRawHash;source_prefix_sha256=[string]$kindIntent.pre.events.sha256;source_prefix_length=[long]$kindIntent.pre.events.byte_length}); $kindTargetState.last_event_id = [string]$kindIntent.event.event_id
    $kindIntent.target.state.document = $kindTargetState; $kindIntent.target.state.sha256 = Get-ArchiveCanonicalHash $kindTargetState; $kindReceipt = $kindIntent.receipt.document; $kindReceipt.root.path = $kindRootRelative; $kindReceipt.root.sha256 = $kindRootRawHash; $kindReceipt.state.sha256 = [string]$kindIntent.target.state.sha256; $kindReceipt.state.document = $kindTargetState; $kindIntent.receipt.document = $kindReceipt; $kindIntent.receipt.sha256 = Get-ArchiveManagedHash $kindReceipt; Write-ArchiveJson $kindIntentPath $kindIntent
    $kindRejected = $false; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $kindWorkspace -HistoryArchiveCheckpoint $kindRequest -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 $kindRequest) -OutPath $kindOut -Timestamp '2026-08-27T00:01:01.0000000Z' -Execute | Out-Null } catch { $kindRejected = $_.Exception.Message -like '*source-derived kind*' }
    Assert-Archive ($kindRejected -and -not(Test-Path -LiteralPath $kindOut)) 'rehashed root object kind substitution was accepted'
    $unregisteredRoot = Join-Path $temp 'unregistered-checkpoint'; Copy-Item -LiteralPath $workspace -Destination $unregisteredRoot -Recurse
    $unregisteredState = Read-MorphospaceProtocolJson (Join-Path $unregisteredRoot 'workspace.state.json'); $unregisteredState.PSObject.Properties.Remove('history_archive'); Write-ArchiveJson (Join-Path $unregisteredRoot 'workspace.state.json') $unregisteredState
    $unregisteredResult = Test-MorphospaceHistoryArchive -WorkspaceRoot $unregisteredRoot -Tier quick
    Assert-Archive ($unregisteredResult.status -ceq 'replay-required' -and $unregisteredResult.reason_codes -ccontains 'unregistered-checkpoint') 'completed checkpoint without its state binding was accepted as unarchived'
    $completedEventRoot = Join-Path $temp 'completed-event-damage'; Copy-Item -LiteralPath $workspace -Destination $completedEventRoot -Recurse
    [IO.File]::WriteAllText((Join-Path $completedEventRoot 'iteration-events.jsonl'), (Get-Content -LiteralPath (Join-Path $completedEventRoot 'iteration-events.jsonl') -First 1) + "`n", [Text.UTF8Encoding]::new($false))
    $completedEventRejected = $false; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $completedEventRoot -HistoryArchiveCheckpoint (Join-Path $completedEventRoot 'history-archive\requests\archive-001.json') -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 (Join-Path $completedEventRoot 'history-archive\requests\archive-001.json')) -OutPath (Join-Path $completedEventRoot 'history-archive\checkpoints\archive-001.json') -Timestamp '2026-08-27T00:01:01.0000000Z' -Execute | Out-Null } catch { $completedEventRejected = $true }
    Assert-Archive $completedEventRejected 'completed archive event removal was silently repaired on replay'
    $completedTailRoot = Join-Path $temp 'completed-tail-damage'; Copy-Item -LiteralPath $workspace -Destination $completedTailRoot -Recurse
    [IO.File]::AppendAllText((Join-Path $completedTailRoot 'iteration-events.jsonl'), ("{}" + "`n"), [Text.UTF8Encoding]::new($false)); $completedTailBytes = [IO.File]::ReadAllBytes((Join-Path $completedTailRoot 'iteration-events.jsonl'))
    $completedTailRejected = $false; try { Invoke-MorphospaceArchiveHistoryCheckpoint -WorkspaceRoot $completedTailRoot -HistoryArchiveCheckpoint (Join-Path $completedTailRoot 'history-archive\requests\archive-001.json') -ExpectedHistoryArchiveCheckpointSha256 (Get-MorphospaceFileSha256 (Join-Path $completedTailRoot 'history-archive\requests\archive-001.json')) -OutPath (Join-Path $completedTailRoot 'history-archive\checkpoints\archive-001.json') -Timestamp '2026-08-27T00:01:01.0000000Z' -Execute | Out-Null } catch { $completedTailRejected = $true }
    Assert-Archive ($completedTailRejected -and ([Convert]::ToHexString($completedTailBytes) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $completedTailRoot 'iteration-events.jsonl'))))) 'completed archive replay accepted or rewrote an invalid appended ledger tail'
    $validTailRoot = Join-Path $temp 'valid-tail'; Copy-Item -LiteralPath $workspace -Destination $validTailRoot -Recurse
    Write-ArchiveJson (Join-Path $validTailRoot 'receipts\u002-later.json') ([ordered]@{schema='fixture.receipt.v1';receipt_id='u002-later';project_id='archive-fixture';status='accepted'})
    $validTailEvent = [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='u002-later';sequence=3;timestamp='2026-08-27T00:02:00.0000000Z';project_id='archive-fixture';unit_id='u001';event_type='decision';summary='Fixture valid post-checkpoint receipt.';receipts=@('receipts/u002-later.json')}
    [IO.File]::AppendAllText((Join-Path $validTailRoot 'iteration-events.jsonl'), (ConvertTo-MorphospaceCanonicalJson $validTailEvent) + "`n", [Text.UTF8Encoding]::new($false))
    $validTailState = Read-MorphospaceProtocolJson (Join-Path $validTailRoot 'workspace.state.json'); $validTailState.last_event_id='u002-later'; $validTailState.last_accepted_receipt='receipts/u002-later.json'; Write-ArchiveJson (Join-Path $validTailRoot 'workspace.state.json') $validTailState
    $validTailResult = Test-MorphospaceHistoryArchive -WorkspaceRoot $validTailRoot -Tier quick
    Assert-Archive ($validTailResult.status -ceq 'pass' -and $validTailResult.mode -ceq 'tail-only') 'valid post-checkpoint tail receipt was incorrectly treated as archived damage'
    $tailRoot = Join-Path $temp 'tail-damage'; Copy-Item -LiteralPath $workspace -Destination $tailRoot -Recurse
    $tailEvent = [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='u002-tail';sequence=3;timestamp='2026-08-27T00:02:00.0000000Z';project_id='archive-fixture';unit_id='u001';event_type='decision';summary='Fixture unknown reference.';receipts=@('receipts/unknown-precheckpoint.json')}
    [IO.File]::AppendAllText((Join-Path $tailRoot 'iteration-events.jsonl'), (ConvertTo-MorphospaceCanonicalJson $tailEvent) + "`n", [Text.UTF8Encoding]::new($false))
    $tailState = Read-MorphospaceProtocolJson (Join-Path $tailRoot 'workspace.state.json'); $tailState.last_event_id='u002-tail'; Write-ArchiveJson (Join-Path $tailRoot 'workspace.state.json') $tailState
    $tailResult = Test-MorphospaceHistoryArchive -WorkspaceRoot $tailRoot -Tier quick
    Assert-Archive ($tailResult.status -ceq 'replay-required' -and $tailResult.reason_codes -ccontains 'unknown-precheckpoint-reference') 'unknown tail reference did not force archived replay'
    Write-Host 'History archive checkpoint self-test passed.'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
