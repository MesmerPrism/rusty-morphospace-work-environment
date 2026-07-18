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
function Assert-Rejected($Root, [scriptblock]$Damage, $Name) {
    & $Damage
    $failed=$false
    try { & $validator -RepoRoot $RepoRoot -WorkspaceRoot $Root *> $null } catch { $failed=$true }
    if(-not $failed){throw "Damaged historical adoption was accepted: $Name"}
}

if (-not $SelfTest) { throw 'Test-HistoricalUnitAdoption.ps1 is a self-test; pass -SelfTest.' }
$base=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-historical-adoption-'+[guid]::NewGuid().ToString('N'))
try {
    New-Fixture $base
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $base | Out-Null
    $cases=@('receipt-hash','unit-hash','missing-mapping','extra-mapping','invalid-target','missing-instruction-impact','extra-instruction-surface','instruction-action-drift','duplicate-unit','current-unit','terminal-event','current-network-kind')
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
            'duplicate-unit' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units+= $d.units[0];Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'current-unit' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.status='active';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;$r.units[0].terminal_status='accepted';Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'terminal-event' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.event_id='missing-terminal-event';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'current-network-kind' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.PSObject.Properties.Remove('historical_unit_adoption_receipts');Write-Json $s $d } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    Write-Host 'Historical-unit adoption self-test passed (positive plus 12 damaged cases).'
} finally { if(Test-Path $base){Remove-Item -LiteralPath $base -Recurse -Force} }
