param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1'
$script:HistoricalAdoptionRejectedCases = 0

function Write-Json($Path, $Value) {
    $Value | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $Path -Encoding utf8
}
function Get-Sha($Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-EventLineSha($Path) {
    $line = @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes([string]$line)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function New-Fixture($Root) {
    New-Item -ItemType Directory -Path $Root, (Join-Path $Root 'iteration-units'), (Join-Path $Root 'module-candidates'), (Join-Path $Root 'promotion-reviews'), (Join-Path $Root 'receipts') -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot 'templates/project.spec.example.json') (Join-Path $Root 'project.spec.json')
    Copy-Item (Join-Path $RepoRoot 'templates/feature.lock.example.json') (Join-Path $Root 'feature.lock.json')
    Copy-Item (Join-Path $RepoRoot 'templates/module-candidate.example.json') (Join-Path $Root 'module-candidates/module-candidate.example.json')
    Copy-Item (Join-Path $RepoRoot 'templates/promotion-review.example.json') (Join-Path $Root 'promotion-reviews/promotion-review.example.json')
    $unit = Get-Content -Raw (Join-Path $RepoRoot 'templates/iteration-unit.example.json') | ConvertFrom-Json
    $unit.status = 'accepted'
    $unit.change_categories = @('activation', 'validation')
    $unit.tags = @('particle', 'contract-extraction', 'legacy-activation')
    $unit.instruction_impact = 'review'
    foreach ($surface in @($unit.instruction_surfaces)) { $surface.status = 'complete'; if ($surface.surface_kind -ne 'skill') { $surface.action = 'review-no-change' } }
    $unit.validation[0].profile_id = 'compatibility'
    $unit.resource_requirements = @([pscustomobject]@{resource_kind='network-interface';resource_id='historical-interface';mode='exclusive';claim_timing='before-run'})
    $unitPath = Join-Path $Root 'iteration-units/unit-example-001.json'
    Write-Json $unitPath $unit
    $event = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-example-001-accepted';sequence=1;timestamp='2026-01-01T00:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='state-transition';summary='Accepted under the historical workflow.';receipts=@('receipts/unit-example-001-validation.json')}
    ($event | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $Root 'iteration-events.jsonl') -Encoding utf8
    '{}' | Set-Content -LiteralPath (Join-Path $Root 'receipts/unit-example-001-validation.json') -Encoding utf8
    $receipt = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.historical_unit_adoption_receipt.v1';receipt_id='historical-unit-adoption-example';project_id='example-project'
        source_workflow=[pscustomobject]@{release='0.1.0';commit=('a'*40)}
        units=@([pscustomobject][ordered]@{
            unit_id='unit-example-001';unit_path='iteration-units/unit-example-001.json';unit_sha256=(Get-Sha $unitPath);terminal_status='accepted'
            terminal_evidence=[pscustomobject]@{event_id='unit-example-001-accepted';receipt_path='receipts/unit-example-001-validation.json'}
            normalization=[pscustomobject]@{
                change_categories=@([pscustomobject]@{legacy='activation';current='feature-activation';retained_as='legacy-activation tag'})
                validation_profiles=@([pscustomobject]@{legacy='compatibility';current='quick';retained_as='historical compatibility limitation'})
                resource_kinds=@([pscustomobject]@{legacy='network-interface';current=$null;retained_as='historical observation-only network limitation'})
                instruction_impact=@([pscustomobject]@{legacy='review';current='update';retained_as='historical review decision retained by the immutable unit'})
                instruction_surfaces=@($unit.instruction_surfaces | Where-Object { $_.surface_kind -ne 'skill' } | ForEach-Object { [pscustomobject]@{path=$_.path;legacy_action='review-no-change';current_action='update';retained_as='historical no-change review retained by the immutable unit'} })
            }
        })
    }
    $receiptPath = Join-Path $Root 'receipts/historical-unit-adoption-example.json'
    Write-Json $receiptPath $receipt
    $state = Get-Content -Raw (Join-Path $RepoRoot 'templates/workspace.state.example.json') | ConvertFrom-Json
    $state.current_unit = $null; $state.last_event_id = 'unit-example-001-accepted'; $state.pending_push_bundle = $null
    $state | Add-Member -NotePropertyName historical_unit_adoption_receipts -NotePropertyValue @([pscustomobject]@{path='receipts/historical-unit-adoption-example.json';sha256=(Get-Sha $receiptPath)})
    Write-Json (Join-Path $Root 'workspace.state.json') $state
}
function Refresh-ReceiptReference($Root) {
    $statePath=Join-Path $Root 'workspace.state.json';$state=Get-Content -Raw $statePath|ConvertFrom-Json
    $state.historical_unit_adoption_receipts[0].sha256=Get-Sha (Join-Path $Root $state.historical_unit_adoption_receipts[0].path)
    Write-Json $statePath $state
}
function Convert-ToBlockedPlannedSkillFixture($Root) {
    $unitPath=Join-Path $Root 'iteration-units/unit-example-001.json';$unit=Get-Content -Raw $unitPath|ConvertFrom-Json
    $unit.status='blocked'
    $requiredSkills=@($unit.instruction_surfaces|Where-Object{$_.surface_kind-eq'skill'-and$_.skill_id-in@('rusty-morphospace','system-engineering')})
    foreach($surface in @($unit.instruction_surfaces|Where-Object{$_.surface_kind-eq'skill'})){$surface.action='review-no-change';$surface.status='planned'}
    $unit.instruction_surfaces+= [pscustomobject]@{surface_kind='skill';skill_id='optional-skill';path='<skills-root>/optional-skill/SKILL.md';owner='optional-skill-owner';change_reason='Unrelated optional historical skill.';action='review-no-change';status='planned';validation='No normalization is required.'}
    Write-Json $unitPath $unit
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-example-001-validation-blocked';sequence=1;timestamp='2026-01-01T00:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='blocker';summary='Blocked under the historical workflow.';receipts=@('receipts/unit-example-001-validation.json')}
    ($event|ConvertTo-Json -Compress)|Set-Content -LiteralPath (Join-Path $Root 'iteration-events.jsonl') -Encoding utf8
    $receiptPath=Join-Path $Root 'receipts/historical-unit-adoption-example.json';$receipt=Get-Content -Raw $receiptPath|ConvertFrom-Json
    $receipt.units[0].unit_sha256=Get-Sha $unitPath;$receipt.units[0].terminal_status='blocked';$receipt.units[0].terminal_evidence.event_id='unit-example-001-validation-blocked'
    $receipt.units[0].normalization.instruction_surfaces+=@($requiredSkills|ForEach-Object{[pscustomobject]@{path=$_.path;legacy_action='review-no-change';current_action='update';retained_as='historical planned skill action retained without a completion claim'}})
    Write-Json $receiptPath $receipt
    $statePath=Join-Path $Root 'workspace.state.json';$state=Get-Content -Raw $statePath|ConvertFrom-Json;$state.last_event_id='unit-example-001-validation-blocked';Write-Json $statePath $state
    Refresh-ReceiptReference $Root
}
function Convert-ToBlockedPublicationFixture($Root) {
    $unitPath=Join-Path $Root 'iteration-units/unit-example-001.json';$unit=Get-Content -Raw $unitPath|ConvertFrom-Json
    $unit.status='blocked';$unit.work_mode='publication';$unit.instruction_impact='review'
    $requiredSkills=@('rusty-morphospace','system-engineering')
    foreach($surface in @($unit.instruction_surfaces|Where-Object{$_.surface_kind-ne'skill'-or$_.skill_id-in$requiredSkills})){$surface.action='review-no-change'}
    Write-Json $unitPath $unit
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-example-001-validation-blocked';sequence=1;timestamp='2026-01-01T00:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='blocker';summary='Blocked retired publication unit.';receipts=@('receipts/unit-example-001-validation.json')}
    $eventPath=Join-Path $Root 'iteration-events.jsonl';($event|ConvertTo-Json -Compress)|Set-Content -LiteralPath $eventPath -Encoding utf8
    $receiptPath=Join-Path $Root 'receipts/historical-unit-adoption-example.json';$receipt=Get-Content -Raw $receiptPath|ConvertFrom-Json
    $receipt.units[0].unit_sha256=Get-Sha $unitPath;$receipt.units[0].terminal_status='blocked'
    $receipt.units[0].terminal_evidence=[pscustomobject][ordered]@{event_id='unit-example-001-validation-blocked';event_sha256=Get-EventLineSha $eventPath;receipt_path='receipts/unit-example-001-validation.json';receipt_sha256=Get-Sha (Join-Path $Root 'receipts/unit-example-001-validation.json')}
    $receipt.units[0].normalization|Add-Member -NotePropertyName work_modes -NotePropertyValue @([pscustomobject]@{legacy='publication';current='feature';retained_as='retired publication accounting mode; no publication is claimed'})
    $receipt.units[0].normalization.instruction_surfaces=@($unit.instruction_surfaces|Where-Object{$_.surface_kind-ne'skill'-or$_.skill_id-in$requiredSkills}|ForEach-Object{[pscustomobject]@{path=$_.path;legacy_action='review-no-change';current_action='update';retained_as='historical review retained without edit, completion, execution, acceptance, or publication claim'}})
    Write-Json $receiptPath $receipt
    $statePath=Join-Path $Root 'workspace.state.json';$state=Get-Content -Raw $statePath|ConvertFrom-Json;$state.last_event_id='unit-example-001-validation-blocked';Write-Json $statePath $state
    Refresh-ReceiptReference $Root
}
function Convert-ToBlockedMissingRequiredSkillFixture($Root) {
    $unitPath=Join-Path $Root 'iteration-units/unit-example-001.json';$unit=Get-Content -Raw $unitPath|ConvertFrom-Json
    $unit.status='blocked';$unit.work_mode='feature';$unit.change_categories=@('implementation','authority','validation','repo-routing');$unit.instruction_impact='update'
    $unit.instruction_surfaces=@($unit.instruction_surfaces|Where-Object{$_.surface_kind-ne'skill'})
    foreach($surface in @($unit.instruction_surfaces)){$surface.action='update';$surface.status='planned'}
    Write-Json $unitPath $unit
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-example-001-validation-blocked';sequence=1;timestamp='2026-01-01T00:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='blocker';summary='Blocked with required historical skill surfaces absent.';receipts=@('receipts/unit-example-001-validation.json')}
    $eventPath=Join-Path $Root 'iteration-events.jsonl';($event|ConvertTo-Json -Compress)|Set-Content -LiteralPath $eventPath -Encoding utf8
    $receiptPath=Join-Path $Root 'receipts/historical-unit-adoption-example.json';$receipt=Get-Content -Raw $receiptPath|ConvertFrom-Json
    $receipt.units[0].unit_sha256=Get-Sha $unitPath;$receipt.units[0].terminal_status='blocked'
    $receipt.units[0].terminal_evidence=[pscustomobject][ordered]@{event_id='unit-example-001-validation-blocked';event_sha256=Get-EventLineSha $eventPath;receipt_path='receipts/unit-example-001-validation.json';receipt_sha256=Get-Sha (Join-Path $Root 'receipts/unit-example-001-validation.json')}
    $receipt.units[0].normalization.change_categories=@();$receipt.units[0].normalization.instruction_impact=@();$receipt.units[0].normalization.instruction_surfaces=@()
    $receipt.units[0].normalization|Add-Member -NotePropertyName missing_required_skill_surfaces -NotePropertyValue @(
        @('rust-work-graph','rusty-morphospace','system-engineering')|ForEach-Object{[pscustomobject][ordered]@{skill_id=$_;path="<skills-root>/$_/SKILL.md";current_action='update';retained_status='planned';retained_as='required historical skill surface remained absent and planned; no instruction edit, completion, or validation execution is claimed'}}
    )
    Write-Json $receiptPath $receipt
    $statePath=Join-Path $Root 'workspace.state.json';$state=Get-Content -Raw $statePath|ConvertFrom-Json;$state.last_event_id='unit-example-001-validation-blocked';Write-Json $statePath $state
    Refresh-ReceiptReference $Root
}
function Assert-Rejected($Root, [scriptblock]$Damage, $Name) {
    & $Damage
    $failed=$false
    try { & $validator -RepoRoot $RepoRoot -WorkspaceRoot $Root -SkipOwnerSelfTests *> $null } catch { $failed=$true }
    if(-not $failed){throw "Damaged historical adoption was accepted: $Name"}
    $script:HistoricalAdoptionRejectedCases++
}

if (-not $SelfTest) { throw 'Test-HistoricalUnitAdoption.ps1 is a self-test; pass -SelfTest.' }
$base=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-historical-adoption-'+[guid]::NewGuid().ToString('N'))
try {
    New-Fixture $base
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $base -SkipOwnerSelfTests | Out-Null
    $blockedSkillRoot="$base-blocked-skill";Copy-Item $base $blockedSkillRoot -Recurse
    Convert-ToBlockedPlannedSkillFixture $blockedSkillRoot
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $blockedSkillRoot -SkipOwnerSelfTests | Out-Null
    foreach($case in @('missing-skill-surface','skill-status-claim','unknown-skill-action')){
        $root="$blockedSkillRoot-$case";Copy-Item $blockedSkillRoot $root -Recurse
        switch($case){
            'missing-skill-surface' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.instruction_surfaces=@($d.units[0].normalization.instruction_surfaces|Where-Object{$_.path-ne'<skills-root>/rusty-morphospace/SKILL.md'});Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'skill-status-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$skill=@($d.units[0].normalization.instruction_surfaces|Where-Object{$_.path-like'<skills-root>/*'})[0];$skill|Add-Member -NotePropertyName current_status -NotePropertyValue complete;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'unknown-skill-action' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$skill=@($d.instruction_surfaces|Where-Object{$_.skill_id-eq'rusty-morphospace'})[0];$skill.action='skip';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    Remove-Item -LiteralPath $blockedSkillRoot -Recurse -Force
    $missingSkillRoot="$base-missing-required-skill";Copy-Item $base $missingSkillRoot -Recurse
    Convert-ToBlockedMissingRequiredSkillFixture $missingSkillRoot
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $missingSkillRoot -SkipOwnerSelfTests | Out-Null
    $missingSkillCases=@('missing-required-skill-mapping','extra-optional-skill-mapping','already-present-skill-mapping','wrong-required-skill-path','wrong-required-skill-action','required-skill-status-claim','required-skill-completion-claim','missing-skill-unit-acceptance-claim','missing-skill-normalization-execution-claim','missing-skill-accepted-status','missing-skill-active-status','missing-skill-current-unit','missing-skill-unit-hash','missing-skill-event','missing-skill-event-type','missing-skill-event-hash-property','missing-skill-event-hash','missing-skill-receipt-hash-property','missing-skill-receipt-hash','missing-skill-unrelated-unit')
    foreach($case in $missingSkillCases){
        $root="$missingSkillRoot-$case";Copy-Item $missingSkillRoot $root -Recurse
        switch($case){
            'missing-required-skill-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces=@($d.units[0].normalization.missing_required_skill_surfaces|Where-Object{$_.skill_id-ne'rusty-morphospace'});Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'extra-optional-skill-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces+=[pscustomobject][ordered]@{skill_id='optional-skill';path='<skills-root>/optional-skill/SKILL.md';current_action='update';retained_status='planned';retained_as='must reject optional surface'};Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'already-present-skill-mapping' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.instruction_surfaces+=[pscustomobject]@{surface_kind='skill';skill_id='rusty-morphospace';path='<skills-root>/rusty-morphospace/SKILL.md';owner='workflow-maintainer';change_reason='Already present immutable skill surface.';action='update';status='planned';validation='Fixture.'};Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'wrong-required-skill-path' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0].path='<skills-root>/wrong-skill/SKILL.md';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'wrong-required-skill-action' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0].current_action='review-no-change';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'required-skill-status-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0].retained_status='complete';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'required-skill-completion-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0]|Add-Member -NotePropertyName completion_claimed -NotePropertyValue $true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-unit-acceptance-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0]|Add-Member -NotePropertyName acceptance_claimed -NotePropertyValue $true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-normalization-execution-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization|Add-Member -NotePropertyName validation_executed -NotePropertyValue $true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-accepted-status' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.status='accepted';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;$r.units[0].terminal_status='accepted';Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'missing-skill-active-status' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.status='active';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'missing-skill-current-unit' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.current_unit='unit-example-001';Write-Json $s $d } $case }
            'missing-skill-unit-hash' { Assert-Rejected $root { Add-Content -LiteralPath (Join-Path $root 'iteration-units/unit-example-001.json') ' ' } $case }
            'missing-skill-event' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.event_id='missing-terminal-event';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-event-type' { Assert-Rejected $root { $e=Join-Path $root 'iteration-events.jsonl';$d=@(Get-Content $e|ForEach-Object{$_|ConvertFrom-Json})[0];$d.event_type='state-transition';($d|ConvertTo-Json -Compress)|Set-Content -LiteralPath $e -Encoding utf8;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].terminal_evidence.event_sha256=Get-EventLineSha $e;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'missing-skill-event-hash-property' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.PSObject.Properties.Remove('event_sha256');Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-event-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.event_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-receipt-hash-property' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.PSObject.Properties.Remove('receipt_sha256');Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-receipt-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.receipt_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-unrelated-unit' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].unit_id='unrelated-unit';$d.units[0].unit_path='iteration-units/unrelated-unit.json';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    Remove-Item -LiteralPath $missingSkillRoot -Recurse -Force
    $publicationRoot="$base-publication";Copy-Item $base $publicationRoot -Recurse
    Convert-ToBlockedPublicationFixture $publicationRoot
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $publicationRoot -SkipOwnerSelfTests | Out-Null
    $publicationCases=@('missing-work-mode-mapping','extra-work-mode-mapping','invalid-work-mode-target','wrong-work-mode-legacy','work-mode-accepted-status','work-mode-status-claim','work-mode-completion-claim','work-mode-unit-hash','missing-work-mode-event-hash','work-mode-event-hash','missing-work-mode-receipt-hash','work-mode-receipt-hash','work-mode-current-unit')
    foreach($case in $publicationCases){
        $root="$publicationRoot-$case";Copy-Item $publicationRoot $root -Recurse
        switch($case){
            'missing-work-mode-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.work_modes=@();Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'extra-work-mode-mapping' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.work_mode='feature';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'invalid-work-mode-target' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.work_modes[0].current='validation-only';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'wrong-work-mode-legacy' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.work_modes[0].legacy='release';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'work-mode-accepted-status' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.status='accepted';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;$r.units[0].terminal_status='accepted';Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'work-mode-status-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.work_modes[0]|Add-Member -NotePropertyName current_status -NotePropertyValue accepted;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'work-mode-completion-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.work_modes[0]|Add-Member -NotePropertyName completion_claimed -NotePropertyValue $true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'work-mode-unit-hash' { Assert-Rejected $root { Add-Content -LiteralPath (Join-Path $root 'iteration-units/unit-example-001.json') ' ' } $case }
            'missing-work-mode-event-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.PSObject.Properties.Remove('event_sha256');Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'work-mode-event-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.event_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-work-mode-receipt-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.PSObject.Properties.Remove('receipt_sha256');Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'work-mode-receipt-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.receipt_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'work-mode-current-unit' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.current_unit='unit-example-001';Write-Json $s $d } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    Remove-Item -LiteralPath $publicationRoot -Recurse -Force
    $cases=@('receipt-hash','unit-hash','missing-mapping','extra-mapping','invalid-target','missing-instruction-impact','extra-instruction-surface','instruction-action-drift','unknown-agent-action','unknown-router-action','duplicate-unit','current-unit','terminal-event','current-network-kind')
    foreach($case in $cases){
        $root="$base-$case";Copy-Item $base $root -Recurse
        switch($case){
            'receipt-hash' { Assert-Rejected $root { Add-Content (Join-Path $root 'receipts/historical-unit-adoption-example.json') ' ' } $case }
            'unit-hash' { Assert-Rejected $root { Add-Content (Join-Path $root 'iteration-units/unit-example-001.json') ' ' } $case }
            'missing-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.change_categories=@();Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'extra-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.change_categories+= [pscustomobject]@{legacy='documentation';current='documentation-only';retained_as='tag'};Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'invalid-target' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.change_categories[0].current='compatibility';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-instruction-impact' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.instruction_impact=@();Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'extra-instruction-surface' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.instruction_surfaces+= [pscustomobject]@{path='docs/extra.md';legacy_action='review-no-change';current_action='update';retained_as='extra'};Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'instruction-action-drift' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.instruction_surfaces[0].legacy_action='update';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'unknown-agent-action' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$surface=@($d.instruction_surfaces|Where-Object{$_.surface_kind-eq'agents'})[0];$surface.action='skip';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;$mapping=@($r.units[0].normalization.instruction_surfaces|Where-Object{$_.path-eq$surface.path})[0];$mapping.legacy_action='skip';Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'unknown-router-action' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$surfaces=@($d.instruction_surfaces|Where-Object{$_.surface_kind-eq'readme'-or$_.surface_kind-eq'router-doc'});foreach($surface in $surfaces){$surface.action='skip'};Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;foreach($surface in $surfaces){$mapping=@($r.units[0].normalization.instruction_surfaces|Where-Object{$_.path-eq$surface.path})[0];$mapping.legacy_action='skip'};Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'duplicate-unit' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units+= $d.units[0];Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'current-unit' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.status='active';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;$r.units[0].terminal_status='accepted';Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'terminal-event' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.event_id='missing-terminal-event';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'current-network-kind' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.PSObject.Properties.Remove('historical_unit_adoption_receipts');Write-Json $s $d } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    $reconstructionRoot="$base-reconstruction";Copy-Item $base $reconstructionRoot -Recurse
    $original=Join-Path $reconstructionRoot 'receipts/historical-unit-adoption-example.json'
    $reconstructed=Join-Path $reconstructionRoot 'receipts/historical-unit-adoption-reconstructed.json'
    Copy-Item $original $reconstructed
    Add-Content -LiteralPath $original ' '
    $anchor=Join-Path $reconstructionRoot 'anchor-repository';New-Item -ItemType Directory $anchor|Out-Null
    git -C $anchor init -q;git -C $anchor config user.name fixture;git -C $anchor config user.email fixture@example.invalid
    New-Item -ItemType Directory (Join-Path $anchor 'receipts')|Out-Null
    Copy-Item $reconstructed (Join-Path $anchor 'receipts\historical-unit-adoption-example.json')
    git -C $anchor -c core.autocrlf=false add .;git -C $anchor commit -q -m anchor
    $anchorRevision=(git -C $anchor rev-parse HEAD).Trim();$anchorTree=(git -C $anchor rev-parse 'HEAD^{tree}').Trim();$anchorBlob=(git -C $anchor rev-parse 'HEAD:receipts/historical-unit-adoption-example.json').Trim()
    $statePath=Join-Path $reconstructionRoot 'workspace.state.json';$state=Get-Content -Raw $statePath|ConvertFrom-Json
    $record=[ordered]@{
        schema='rusty.morphospace.workflow.historical_unit_adoption_reconstruction.v1';reconstruction_id='historical-adoption-reconstruction-example';project_id='example-project';recorded_at='2026-01-02T03:04:05Z';status='independent-reconstruction-verified'
        damaged_original=[ordered]@{path='receipts/historical-unit-adoption-example.json';expected_sha256=[string]$state.historical_unit_adoption_receipts[0].sha256;observed_sha256=Get-Sha $original;integrity='damaged-original-unavailable'}
        reconstruction=[ordered]@{path='receipts/historical-unit-adoption-reconstructed.json';sha256=Get-Sha $reconstructed;claim='independent-reconstruction-not-original-bytes'}
        immutable_anchor=[ordered]@{repository='source-owner';revision=$anchorRevision;tree=$anchorTree;source_path='receipts/historical-unit-adoption-example.json';source_blob=$anchorBlob;content_sha256=Get-Sha $reconstructed}
        projection=[ordered]@{scope='current-validation-only';original_reference_preserved=$true;accepted_evidence_rewritten=$false;current_or_inflight_units_allowed=$false;conflicting_reconstruction_allowed=$false};failure=$null
    }
    $recordPath=Join-Path $reconstructionRoot 'receipts/historical-adoption-reconstruction-example.json';Write-Json $recordPath $record
    $state|Add-Member -NotePropertyName historical_unit_adoption_reconstructions -NotePropertyValue @([pscustomobject]@{path='receipts/historical-adoption-reconstruction-example.json';sha256=Get-Sha $recordPath})
    Write-Json $statePath $state
    $repoMapPath=Join-Path $reconstructionRoot 'repository-map.json';Write-Json $repoMapPath ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='source-owner';path=$anchor;role='source'})})
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $reconstructionRoot -RepositoryMapPath $repoMapPath -SkipOwnerSelfTests | Out-Null
    Add-Content -LiteralPath $recordPath ' '
    $failed=$false;try{& $validator -RepoRoot $RepoRoot -WorkspaceRoot $reconstructionRoot -RepositoryMapPath $repoMapPath -SkipOwnerSelfTests *> $null}catch{$failed=$true}
    if(-not$failed){throw'Tampered historical reconstruction reference was accepted.'}
    Remove-Item -LiteralPath $reconstructionRoot -Recurse -Force
    Write-Host "Historical-unit adoption self-test passed (positive, reconstructed projection, and $script:HistoricalAdoptionRejectedCases damaged cases)."
} finally { if(Test-Path $base){Remove-Item -LiteralPath $base -Recurse -Force} }
