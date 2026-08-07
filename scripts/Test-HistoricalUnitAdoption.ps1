param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1'

function Write-Json($Path, $Value) {
    $Value | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $Path -Encoding utf8
}
function Get-Sha($Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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
function Assert-Rejected($Root, [scriptblock]$Damage, $Name) {
    & $Damage
    $failed=$false
    try { & $validator -RepoRoot $RepoRoot -WorkspaceRoot $Root -SkipOwnerSelfTests *> $null } catch { $failed=$true }
    if(-not $failed){throw "Damaged historical adoption was accepted: $Name"}
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
    Write-Host 'Historical-unit adoption self-test passed (positive, reconstructed projection, and 18 damaged cases).'
} finally { if(Test-Path $base){Remove-Item -LiteralPath $base -Recurse -Force} }
