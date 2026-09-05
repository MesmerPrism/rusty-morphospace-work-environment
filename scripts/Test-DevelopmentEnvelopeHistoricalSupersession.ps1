param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopePreparation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
$preparationModule=Get-Module DevelopmentEnvelopePreparation
function Assert-History([bool]$ok,[string]$message){if(-not$ok){throw "Development-envelope historical-supersession self-test failed: $message"}}
function Write-HistoryJson([string]$path,[object]$value){[IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null;[IO.File]::WriteAllText($path,(($value|ConvertTo-Json -Depth 64)+"`n"),[Text.UTF8Encoding]::new($false))}
function Copy-History([object]$value){$value|ConvertTo-Json -Depth 64|ConvertFrom-Json -DateKind String}
function Add-HistoryTransition([string]$root,[string]$oldId,[string]$replacementId,[int]$sequence){
    $statePath=Join-Path $root 'workspace.state.json';$state=Read-MorphospaceProtocolJson $statePath
    $replacementPath="iteration-units/$replacementId.json";$replacement=Read-MorphospaceProtocolJson (Join-Path $root $replacementPath)
    $targetState=Copy-History $state;$targetState.current_unit=$replacementId;$targetState.next_ready_unit=$null;$eventId=Get-MorphospaceSupersessionEventId -OldUnitId $oldId -ReplacementUnitId $replacementId;$targetState.last_event_id=$eventId
    $targetUnit=Copy-History $replacement;$targetUnit.status='active'
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=$sequence;timestamp="2026-09-04T00:0$sequence`:00.0000000Z";project_id='morphovision-shaped';unit_id=$oldId;event_type='state-transition';summary='Superseded the exact historical unit with its reviewed replacement.';receipts=@("receipts/$eventId.json")}
    Start-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $replacementPath -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event -ExpectedPreStateSha256 (Get-MorphospaceCanonicalJsonSha256 $state) -ExpectedPreUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $replacement)|Out-Null
}
function Add-AcceptedTransition([string]$root,[string]$unitId,[int]$sequence){
    $statePath=Join-Path $root 'workspace.state.json';$state=Read-MorphospaceProtocolJson $statePath;$unitPath="iteration-units/$unitId.json";$unit=Read-MorphospaceProtocolJson (Join-Path $root $unitPath)
    $eventId="$unitId-accepted-$('{0:d4}'-f$sequence)";$targetState=Copy-History $state;$targetState.current_unit=$null;$targetState.next_ready_unit=$null;$targetState.last_event_id=$eventId;$targetState.last_accepted_receipt='receipts/unit013-validation.json';$targetUnit=Copy-History $unit;$targetUnit.status='accepted'
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=$sequence;timestamp="2026-09-04T00:0$sequence`:00.0000000Z";project_id='morphovision-shaped';unit_id=$unitId;event_type='state-transition';summary='Accepted the replacement after owner validation.';receipts=@('receipts/unit013-validation.json')}
    Start-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $unitPath -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event -ExpectedPreStateSha256 (Get-MorphospaceCanonicalJsonSha256 $state) -ExpectedPreUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $unit)|Out-Null
}
function Assert-Closure([string]$root){&$preparationModule {param($workspace)Assert-PreparationHistoricalSupersessionClosure $workspace} $root}
function Assert-AuditRejected([string]$template,[string]$name,[scriptblock]$damage){
    $root=Join-Path $temp $name;Copy-Item $template $root -Recurse;&$damage $root
    Assert-Closure $root
    $rejected=$false;try{&$preparationModule {param($workspace)Assert-PreparationHistoricalSupersessionAudit $workspace} $root}catch{$rejected=$true}
    Assert-History $rejected "historical audit did not retain $name damage"
}
function Assert-Rejected([string]$template,[string]$name,[scriptblock]$damage){$root=Join-Path $temp $name;Copy-Item $template $root -Recurse;&$damage $root;$rejected=$false;try{Assert-Closure $root}catch{$rejected=$true};Assert-History $rejected "accepted $name damage"}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('workenv-preparation-history-'+[guid]::NewGuid().ToString('N'))
try{
    $workspace=Join-Path $temp 'morphospace';[IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts'))|Out-Null
    $state=[ordered]@{schema='rusty.morphospace.workflow.workspace_state.v2';project_id='morphovision-shaped';current_unit='unit009';next_ready_unit='unit010';last_event_id='unit008-accepted-0001';last_accepted_receipt='receipts/unit008-validation.json'}
    foreach($row in @(@('unit008','accepted'),@('unit009','active'),@('unit010','proposed'),@('unit013','proposed'))){Write-HistoryJson (Join-Path $workspace "iteration-units\$($row[0]).json") ([ordered]@{schema='rusty.morphospace.workflow.iteration_unit.v1';project_id='morphovision-shaped';unit_id=$row[0];status=$row[1]})}
    Write-HistoryJson (Join-Path $workspace 'workspace.state.json') $state
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'),(([ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit008-accepted-0001';sequence=1;timestamp='2026-09-04T00:01:00.0000000Z';project_id='morphovision-shaped';unit_id='unit008';event_type='state-transition';summary='Accepted the prior unit.';receipts=@('receipts/unit008-validation.json')}|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
    Add-HistoryTransition $workspace 'unit009' 'unit010' 2
    Write-HistoryJson (Join-Path $workspace 'iteration-units\unit013.json') ([ordered]@{schema='rusty.morphospace.workflow.iteration_unit.v1';project_id='morphovision-shaped';unit_id='unit013';status='proposed'})
    $midState=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json');$midState.next_ready_unit='unit013';Write-HistoryJson (Join-Path $workspace 'workspace.state.json') $midState
    Add-HistoryTransition $workspace 'unit010' 'unit013' 3
    Add-AcceptedTransition $workspace 'unit013' 4
    $before=@(Get-ChildItem $workspace -Recurse -File|Sort-Object FullName|ForEach-Object{"$($_.FullName.Substring($workspace.Length))=$(Get-MorphospaceFileSha256 $_.FullName)"})
    Assert-Closure $workspace
    $after=@(Get-ChildItem $workspace -Recurse -File|Sort-Object FullName|ForEach-Object{"$($_.FullName.Substring($workspace.Length))=$(Get-MorphospaceFileSha256 $_.FullName)"})
    Assert-History (($before-join"`n")-ceq($after-join"`n")) 'positive validation rewrote immutable workspace bytes'
    Assert-Rejected $workspace 'future-proposed' {param($r)Write-HistoryJson (Join-Path $r 'iteration-units\unit014.json') ([ordered]@{unit_id='unit014';status='proposed'})}
    Assert-Rejected $workspace 'current-authority' {param($r)$p=Join-Path $r 'workspace.state.json';$d=Read-MorphospaceProtocolJson $p;$d.current_unit='unit013';Write-HistoryJson $p $d}
    Assert-AuditRejected $workspace 'missing-supersession-completion' {param($r)Remove-Item -LiteralPath (Join-Path $r 'receipts\transactions\unit009-superseded-by-unit010-transition.completion.json')}
    Assert-AuditRejected $workspace 'damaged-supersession-intent' {param($r)$p=Join-Path $r 'receipts\transactions\unit009-superseded-by-unit010-transition.intent.json';$d=Read-MorphospaceProtocolJson $p;$d.supersession.old_unit.sha256='0'*64;Write-HistoryJson $p $d}
    Assert-AuditRejected $workspace 'rewritten-historical-unit' {param($r)$p=Join-Path $r 'iteration-units\unit009.json';$d=Read-MorphospaceProtocolJson $p;$d|Add-Member -NotePropertyName objective -NotePropertyValue 'rewritten';Write-HistoryJson $p $d}
    Assert-Rejected $workspace 'rewritten-accepted-unit' {param($r)$p=Join-Path $r 'iteration-units\unit013.json';$d=Read-MorphospaceProtocolJson $p;$d|Add-Member -NotePropertyName objective -NotePropertyValue 'forged accepted endpoint';Write-HistoryJson $p $d}
    Assert-Rejected $workspace 'orphan-replacement' {param($r)Remove-Item -LiteralPath (Join-Path $r 'iteration-units\unit010.json')}
    Assert-Rejected $workspace 'missing-acceptance-completion' {param($r)Remove-Item -LiteralPath (Join-Path $r 'receipts\transactions\unit013-accepted-0004-transition.completion.json')}
    Assert-Rejected $workspace 'pending-publication' {param($r)$p=Join-Path $r 'workspace.state.json';$d=Read-MorphospaceProtocolJson $p;$d|Add-Member pending_push_bundle 'pending';Write-HistoryJson $p $d}
    Assert-Rejected $workspace 'live-blocker' {param($r)$p=Join-Path $r 'workspace.state.json';$d=Read-MorphospaceProtocolJson $p;$d|Add-Member blockers @('unresolved');Write-HistoryJson $p $d}
    Assert-Rejected $workspace 'current-intent-under-old-name' {param($r)
        $p=Join-Path $r 'receipts\transactions\unit009-superseded-by-unit010-transition.intent.json'
        Remove-Item -LiteralPath ($p -replace '\.intent\.json$','.completion.json')
        $d=Read-MorphospaceProtocolJson $p;$d.pre.state.sha256=Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Join-Path $r 'workspace.state.json'));Write-HistoryJson $p $d
    }
    Assert-Rejected $workspace 'required-retired-unit' {param($r)
        Write-HistoryJson (Join-Path $r 'iteration-units\unit014.json') ([ordered]@{schema='rusty.morphospace.workflow.iteration_unit.v1';project_id='morphovision-shaped';unit_id='unit014';status='proposed';prerequisites=@('unit009')})
    }
    Assert-Rejected $workspace 'ambiguous-supersession' {param($r)$p=Join-Path $r 'iteration-events.jsonl';$e=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit009-superseded-by-unit013';sequence=5;timestamp='2026-09-04T00:05:00.0000000Z';project_id='morphovision-shaped';unit_id='unit009';event_type='state-transition';summary='Counterfeit alternate replacement.';receipts=@()};[IO.File]::AppendAllText($p,(($e|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))}
    Write-Host 'Development-envelope historical-supersession self-test passed.'
}finally{if(Test-Path $temp){$resolved=[IO.Path]::GetFullPath($temp);if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-notlike'workenv-preparation-history-*'){throw 'Unsafe self-test cleanup target.'};Remove-Item -LiteralPath $resolved -Recurse -Force}}
