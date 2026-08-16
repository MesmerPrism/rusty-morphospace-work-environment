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
            terminal_evidence=[pscustomobject]@{event_id='unit-example-001-accepted';event_sha256=Get-EventLineSha (Join-Path $Root 'iteration-events.jsonl');receipt_path='receipts/unit-example-001-validation.json';receipt_sha256=Get-Sha (Join-Path $Root 'receipts/unit-example-001-validation.json')}
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
    $receipt.units[0].terminal_evidence.event_sha256=Get-EventLineSha (Join-Path $Root 'iteration-events.jsonl')
    $receipt.units[0].terminal_evidence.receipt_sha256=Get-Sha (Join-Path $Root 'receipts/unit-example-001-validation.json')
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
    $validationPath=Join-Path $Root 'receipts/unit-example-001-validation.json'
    Write-Json $validationPath ([pscustomobject][ordered]@{
        '$schema'='../schemas/validation-receipt.schema.json';schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id='unit-example-001-validation-blocked';project_id='example-project';unit_id='unit-example-001';created_at='2026-01-01T00:00:00Z';tier='standard';result='blocked'
        repository_revisions=@();changed_paths=@();artifacts=@([pscustomobject]@{artifact_id='historical-skill-blocker';kind='workflow-blocker';path='evidence/historical-skill-blocker.json';sha256=('0'*64)})
        criteria=@([pscustomobject]@{acceptance_id='historical-skill-routing';status='blocked';command='Fixture only.';evidence_refs=@('historical-skill-blocker')})
        gates=@([pscustomobject]@{gate_id='instruction-routing';status='blocked';command='Fixture only.';evidence_refs=@('historical-skill-blocker')});device_validation=$null
    })
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-example-001-validation-blocked';sequence=1;timestamp='2026-01-01T00:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='blocker';summary='Blocked with required historical skill surfaces absent.';receipts=@('receipts/unit-example-001-validation.json')}
    $eventPath=Join-Path $Root 'iteration-events.jsonl';($event|ConvertTo-Json -Compress)|Set-Content -LiteralPath $eventPath -Encoding utf8
    $receiptPath=Join-Path $Root 'receipts/historical-unit-adoption-example.json';$receipt=Get-Content -Raw $receiptPath|ConvertFrom-Json
    $receipt.units[0].unit_sha256=Get-Sha $unitPath;$receipt.units[0].terminal_status='blocked'
    $receipt.units[0].terminal_evidence=[pscustomobject][ordered]@{event_id='unit-example-001-validation-blocked';event_sha256=Get-EventLineSha $eventPath;receipt_path='receipts/unit-example-001-validation.json';receipt_sha256=Get-Sha $validationPath}
    $receipt.units[0].normalization.change_categories=@();$receipt.units[0].normalization.instruction_impact=@();$receipt.units[0].normalization.instruction_surfaces=@()
    $receipt.units[0].normalization|Add-Member -NotePropertyName missing_required_skill_surfaces -NotePropertyValue @(
        @('rust-work-graph','rusty-morphospace','system-engineering')|ForEach-Object{[pscustomobject][ordered]@{skill_id=$_;path="<skills-root>/$_/SKILL.md";current_action='update';retained_status='planned';retained_as='required historical skill surface remained absent and planned; no instruction edit, completion, or validation execution is claimed'}}
    )
    Write-Json $receiptPath $receipt
    $statePath=Join-Path $Root 'workspace.state.json';$state=Get-Content -Raw $statePath|ConvertFrom-Json;$state.last_event_id='unit-example-001-validation-blocked';Write-Json $statePath $state
    Refresh-ReceiptReference $Root
}
function Convert-ToAcceptedLaterRequiredSkillFixture($Root) {
    $unitPath=Join-Path $Root 'iteration-units/unit-example-001.json';$unit=Get-Content -Raw $unitPath|ConvertFrom-Json
    $unit.instruction_surfaces=@($unit.instruction_surfaces|Where-Object{[string]$_.skill_id-cne'rusty-morphospace'})
    Write-Json $unitPath $unit
    $validationPath=Join-Path $Root 'receipts/unit-example-001-validation.json'
    Write-Json $validationPath ([pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id='unit-example-001-validation';project_id='example-project';unit_id='unit-example-001';created_at='2026-01-01T00:00:00Z';tier='standard';result='pass'
        repository_revisions=@();changed_paths=@();artifacts=@();criteria=@();gates=@();device_validation=$null
    })
    $receiptPath=Join-Path $Root 'receipts/historical-unit-adoption-example.json';$receipt=Get-Content -Raw $receiptPath|ConvertFrom-Json
    $receipt.units[0].unit_sha256=Get-Sha $unitPath
    $receipt.units[0].terminal_evidence.receipt_sha256=Get-Sha $validationPath
    $receipt.units[0].normalization|Add-Member -NotePropertyName later_required_skill_surfaces -NotePropertyValue @(
        [pscustomobject][ordered]@{skill_id='rusty-morphospace';path='<skills-root>/rusty-morphospace/SKILL.md';current_action='update';terminal_requirement='not-required-at-acceptance';retained_as='The current skill route postdates this exact accepted unit; no historical edit, completion, or execution is claimed.'}
    )
    Write-Json $receiptPath $receipt
    Refresh-ReceiptReference $Root
}
function Convert-ToSupersededInstructionDebtFixture($Root) {
    $oldId='unit-example-001';$replacementId='unit-example-002'
    $oldPath=Join-Path $Root "iteration-units/$oldId.json"
    $old=Get-Content -Raw (Join-Path $RepoRoot 'templates/iteration-unit.example.json')|ConvertFrom-Json
    $old.unit_id=$oldId;$old.status='active'
    $old.instruction_surfaces=@($old.instruction_surfaces|Where-Object{[string]$_.skill_id-cne'rusty-morphospace'})
    foreach($surface in @($old.instruction_surfaces)){$surface.action='review-no-change'}
    Write-Json $oldPath $old
    $replacement=Get-Content -Raw (Join-Path $RepoRoot 'templates/iteration-unit.example.json')|ConvertFrom-Json
    $replacement.unit_id=$replacementId;$replacement.status='active'
    Write-Json (Join-Path $Root "iteration-units/$replacementId.json") $replacement
    $eventId="$oldId-superseded-by-$replacementId"
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=1;timestamp='2026-01-01T00:00:00Z';project_id='example-project';unit_id=$oldId;event_type='state-transition';summary='Replace an immutable historical in-flight unit without rewriting it.';receipts=@()}
    ($event|ConvertTo-Json -Compress)|Set-Content -LiteralPath (Join-Path $Root 'iteration-events.jsonl') -Encoding utf8
    $statePath=Join-Path $Root 'workspace.state.json';$state=Get-Content -Raw $statePath|ConvertFrom-Json
    $state.current_unit=$replacementId;$state.next_ready_unit=$null;$state.last_event_id=$eventId;$state.pending_push_bundle=$null
    $state.PSObject.Properties.Remove('historical_unit_adoption_receipts')
    Write-Json $statePath $state
}
function Write-BlockedValidationFixture($Root, $UnitId, $EventId) {
    $blockerPath=Join-Path $Root 'receipts/evidence/historical-scope-blocker.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $blockerPath) -Force|Out-Null
    Write-Json $blockerPath ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.historical_scope_blocker.v1';unit_id=$UnitId;event_id=$EventId;status='blocked'})
    $validationPath=Join-Path $Root "receipts/$UnitId-validation.json"
    Write-Json $validationPath ([pscustomobject][ordered]@{
        '$schema'='../schemas/validation-receipt.schema.json';schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id="$UnitId-validation-blocked";project_id='example-project';unit_id=$UnitId;created_at='2026-01-02T00:00:00Z';tier='standard';result='blocked'
        repository_revisions=@();changed_paths=@();artifacts=@([pscustomobject]@{artifact_id='historical-scope-blocker';kind='workflow-blocker';path='evidence/historical-scope-blocker.json';sha256=Get-Sha $blockerPath})
        criteria=@([pscustomobject]@{acceptance_id='historical-scope';status='blocked';command='Fixture only.';evidence_refs=@('historical-scope-blocker')})
        gates=@([pscustomobject]@{gate_id='historical-scope';status='blocked';command='Fixture only.';evidence_refs=@('historical-scope-blocker')});device_validation=$null
    })
    return $validationPath
}
function Set-HistoricalTerminalEvidence($Root, $UnitPath, $EventId, $ValidationPath) {
    $eventPath=Join-Path $Root 'iteration-events.jsonl'
    $receiptPath=Join-Path $Root 'receipts/historical-unit-adoption-example.json';$receipt=Get-Content -Raw $receiptPath|ConvertFrom-Json
    $receipt.units[0].unit_sha256=Get-Sha $UnitPath;$receipt.units[0].terminal_status='blocked'
    $receipt.units[0].terminal_evidence=[pscustomobject][ordered]@{event_id=$EventId;event_sha256=Get-EventLineSha $eventPath;receipt_path=(Normalize-FixturePath $Root $ValidationPath);receipt_sha256=Get-Sha $ValidationPath}
    Write-Json $receiptPath $receipt
    $statePath=Join-Path $Root 'workspace.state.json';$state=Get-Content -Raw $statePath|ConvertFrom-Json;$state.current_unit=$null;$state.next_ready_unit=$null;$state.last_event_id=$EventId;Write-Json $statePath $state
    Refresh-ReceiptReference $Root
}
function Normalize-FixturePath($Root, $Path) {
    return [IO.Path]::GetRelativePath($Root,$Path).Replace('\','/')
}
function Get-SortedPathSha([string[]]$Paths) {
    $payload=[string]::Join([char]10,@($Paths|Sort-Object -CaseSensitive))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false,$true).GetBytes($payload))).ToLowerInvariant()
}
function Convert-ToBlockedReadOnlyDependencyScopeFixture($Root) {
    $specPath=Join-Path $Root 'project.spec.json';$spec=Get-Content -Raw $specPath|ConvertFrom-Json
    $matter=@($spec.repositories|Where-Object{$_.repo_id-eq'matter-core'})[0]
    $matter.allowed_paths=@('crates/particle-field/src/lib.rs','schemas/','fixtures/','docs/')
    Write-Json $specPath $spec
    $unitPath=Join-Path $Root 'iteration-units/unit-example-001.json';$unit=Get-Content -Raw $unitPath|ConvertFrom-Json
    $unit.status='blocked';$unit.work_mode='validation-only';$unit.change_categories=@('validation');$unit.instruction_impact='review';$unit.device_requirement='none';$unit.resource_requirements=@()
    $unit.validation[0].profile_id='quick'
    $unit.allowed_repositories=@([pscustomobject]@{repo_id='project-shell';allowed_paths=@('morphospace/')})
    $unit|Add-Member -Force -NotePropertyName read_only_dependencies -NotePropertyValue @([pscustomobject][ordered]@{repo_id='matter-core';paths=@('crates/particle-field/','schemas/');purpose='Historical read-only fixture.';verification='Fixture only.'})
    foreach($surface in @($unit.instruction_surfaces)){$surface.action='review-no-change';$surface.status='planned'}
    Write-Json $unitPath $unit
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-example-001-validation-blocked';sequence=1;timestamp='2026-01-02T00:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='blocker';summary='Blocked on historical read-only directory scope.';receipts=@('receipts/unit-example-001-validation.json')}
    $eventPath=Join-Path $Root 'iteration-events.jsonl';($event|ConvertTo-Json -Compress)|Set-Content -LiteralPath $eventPath -Encoding utf8
    $validationPath=Write-BlockedValidationFixture $Root 'unit-example-001' $event.event_id
    $closurePaths=@('crates/particle-field/src/lib.rs','schemas/')
    $closure=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.proposed_unit_project_read_scope_closure.v1';status='complete'
        source_terminal_unit=[pscustomobject][ordered]@{unit_id='unit-example-001';status='blocked';byte_length=(Get-Item $unitPath).Length;sha256=Get-Sha $unitPath;terminal_event_id=$event.event_id;blocker_evidence_sha256=('0'*64)}
        proposed_read_only_dependencies=@([pscustomobject][ordered]@{repo_id='matter-core';path_count=$closurePaths.Count;sorted_lf_joined_path_sha256=Get-SortedPathSha $closurePaths;paths=$closurePaths})
    }
    $closurePath=Join-Path $Root 'receipts/read-only-scope-closure.json';Write-Json $closurePath $closure
    $adoptionPath=Join-Path $Root 'receipts/historical-unit-adoption-example.json';$adoption=Get-Content -Raw $adoptionPath|ConvertFrom-Json
    $adoption.units[0].normalization=[pscustomobject][ordered]@{
        change_categories=@();validation_profiles=@();resource_kinds=@()
        read_only_dependency_scope=[pscustomobject][ordered]@{
            closure=[pscustomobject]@{path='receipts/read-only-scope-closure.json';sha256=Get-Sha $closurePath}
            mappings=@([pscustomobject][ordered]@{repo_id='matter-core';legacy_path='crates/particle-field/';current_paths=@('crates/particle-field/src/lib.rs');retained_as='Historical directory read projected to the exact closure leaf.'})
            retained_as='Current validation only; no source or historical unit mutation.'
        }
    }
    Write-Json $adoptionPath $adoption
    Set-HistoricalTerminalEvidence $Root $unitPath $event.event_id $validationPath
}
function Convert-ToBlockedCompletedProjectScopeFixture($Root) {
    $specPath=Join-Path $Root 'project.spec.json';$spec=Get-Content -Raw $specPath|ConvertFrom-Json
    $matter=@($spec.repositories|Where-Object{$_.repo_id-eq'matter-core'})[0]
    $beforePaths=@($matter.allowed_paths);$matter.allowed_paths=@($beforePaths+'tools/exact.ps1')
    Write-Json $specPath $spec
    $unitPath=Join-Path $Root 'iteration-units/unit-example-001.json';$unit=Get-Content -Raw $unitPath|ConvertFrom-Json
    $unit.status='blocked';$unit.work_mode='validation-only';$unit.change_categories=@('repo-routing');$unit.instruction_impact='review';$unit.device_requirement='none';$unit.resource_requirements=@()
    $unit.validation[0].profile_id='quick'
    $unit.allowed_repositories=@([pscustomobject]@{repo_id='project-shell';allowed_paths=@('morphospace/')},[pscustomobject]@{repo_id='matter-core';allowed_paths=@('tools/exact.ps1')})
    foreach($surface in @($unit.instruction_surfaces)){$surface.action='review-no-change';$surface.status='planned'}
    Write-Json $unitPath $unit
    $scopeReceipt=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.active_project_repository_scope_correction.v1';correction_id='fixture-scope-correction';project_id='example-project';unit_id='unit-example-001';repository_id='matter-core';reason='Fixture additions-only scope correction.';expected=[pscustomobject]@{status='active';current_unit='unit-example-001'};before_allowed_paths=$beforePaths;after_allowed_paths=@($matter.allowed_paths);does_not_prove=@('Does not change source, execute validation, authorize publication, reserve resources, or contact a device.')}
    $scopeReceiptPath=Join-Path $Root 'receipts/fixture-scope-correction.json';Write-Json $scopeReceiptPath $scopeReceipt
    $scopeReceiptSha=Get-Sha $scopeReceiptPath;$scopeReceiptBytes=[IO.File]::ReadAllBytes($scopeReceiptPath)
    $correctionEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='fixture-scope-correction-recorded';sequence=1;timestamp='2026-01-01T12:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='state-transition';summary='Recorded fixture additions-only project scope.';receipts=@('receipts/fixture-scope-correction.json')}
    $terminalEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-example-001-validation-blocked';sequence=2;timestamp='2026-01-02T00:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='blocker';summary='Blocked after completed historical project scope.';receipts=@('receipts/unit-example-001-validation.json')}
    $eventPath=Join-Path $Root 'iteration-events.jsonl';@(($correctionEvent|ConvertTo-Json -Compress),($terminalEvent|ConvertTo-Json -Compress))|Set-Content -LiteralPath $eventPath -Encoding utf8
    $validationPath=Write-BlockedValidationFixture $Root 'unit-example-001' $terminalEvent.event_id
    $transactionId='fixture-scope-correction-recorded-transition'
    $intentRelative='receipts/transactions/fixture-scope-correction-recorded-transition.intent.json';$completionRelative='receipts/transactions/fixture-scope-correction-recorded-transition.completion.json'
    New-Item -ItemType Directory -Path (Join-Path $Root 'receipts/transactions') -Force|Out-Null
    $lockPath=Join-Path $Root 'feature.lock.json';$statePath=Join-Path $Root 'workspace.state.json';$state=Get-Content -Raw $statePath|ConvertFrom-Json
    $unitSha=Get-Sha $unitPath;$stateSha=Get-Sha $statePath;$projectSha=Get-Sha $specPath;$lockSha=Get-Sha $lockPath
    $intent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.transition_ledger_intent.v3';transaction_id=$transactionId;status='prepared';unit=[pscustomobject]@{path='iteration-units/unit-example-001.json'};event=$correctionEvent;pre=[pscustomobject]@{unit=[pscustomobject]@{sha256=$unitSha}};target=[pscustomobject]@{unit=[pscustomobject]@{sha256=$unitSha};state=[pscustomobject]@{sha256=$stateSha;document=$state}};additional_projections=@([pscustomobject]@{path='project.spec.json';target_sha256=$projectSha;document=$spec},[pscustomobject]@{path='feature.lock.json';target_sha256=$lockSha;document=(Get-Content -Raw $lockPath|ConvertFrom-Json)});artifacts=@([pscustomobject]@{path='receipts/fixture-scope-correction.json';sha256=$scopeReceiptSha;bytes_base64=[Convert]::ToBase64String($scopeReceiptBytes)})}
    $intentPath=Join-Path $Root ($intentRelative-replace'/','\');Write-Json $intentPath $intent
    $completion=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.transition_ledger_completion.v1';transaction_id=$transactionId;status='committed';event_id=$correctionEvent.event_id;unit_sha256=$unitSha;state_sha256=$stateSha;intent=[pscustomobject]@{path=$intentRelative;role='transition-ledger-intent';schema='rusty.morphospace.workflow.transition_ledger_intent.v3';sha256=Get-Sha $intentPath}}
    $completionPath=Join-Path $Root ($completionRelative-replace'/','\');Write-Json $completionPath $completion
    $correctionLine=@(Get-Content $eventPath)[0];$correctionEventSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false,$true).GetBytes($correctionLine))).ToLowerInvariant()
    $adoptionPath=Join-Path $Root 'receipts/historical-unit-adoption-example.json';$adoption=Get-Content -Raw $adoptionPath|ConvertFrom-Json
    $adoption.units[0].normalization=[pscustomobject][ordered]@{
        change_categories=@();validation_profiles=@();resource_kinds=@()
        completed_project_scope=[pscustomobject][ordered]@{
            work_mode='validation-only';change_categories=@('validation');allowed_repositories=@([pscustomobject]@{repo_id='project-shell';allowed_paths=@('morphospace/')})
            blocker_evidence=[pscustomobject]@{path='receipts/evidence/historical-scope-blocker.json';sha256=Get-Sha (Join-Path $Root 'receipts/evidence/historical-scope-blocker.json')}
            project_snapshot=[pscustomobject]@{project_revision=$spec.revision;project_sha256=$projectSha;feature_lock_revision=(Get-Content -Raw $lockPath|ConvertFrom-Json).revision;feature_lock_sha256=$lockSha;plan_revision=$state.plan_revision}
            corrections=@([pscustomobject][ordered]@{repository_id='matter-core';receipt_path='receipts/fixture-scope-correction.json';receipt_sha256=$scopeReceiptSha;event_id=$correctionEvent.event_id;event_sha256=$correctionEventSha;intent_path=$intentRelative;intent_sha256=Get-Sha $intentPath;completion_path=$completionRelative;completion_sha256=Get-Sha $completionPath})
            mutation_performed=[pscustomobject]@{git=$false;device=$false;remote=$false};retained_as='Current validation only; completed additions remain historical declarations, not write authority.'
        }
    }
    Write-Json $adoptionPath $adoption
    Set-HistoricalTerminalEvidence $Root $unitPath $terminalEvent.event_id $validationPath
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
    $laterSkillRoot="$base-later-required-skill";Copy-Item $base $laterSkillRoot -Recurse
    Convert-ToAcceptedLaterRequiredSkillFixture $laterSkillRoot
    if(-not(Get-Content -Raw (Join-Path $laterSkillRoot 'receipts/historical-unit-adoption-example.json')|Test-Json -SchemaFile (Join-Path $RepoRoot 'schemas/historical-unit-adoption-receipt.schema.json') -ErrorAction SilentlyContinue)){throw'Accepted later-required-skill adoption fixture failed its schema.'}
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $laterSkillRoot -SkipOwnerSelfTests | Out-Null
    $laterSkillCases=@('later-skill-missing-mapping','later-skill-extra-mapping','later-skill-already-present','later-skill-wrong-path','later-skill-action-claim','later-skill-terminal-requirement','later-skill-blocked-status','later-skill-current-unit','later-skill-event-type','later-skill-event-hash','later-skill-receipt-hash','later-skill-receipt-result','later-skill-reference-removed')
    foreach($case in $laterSkillCases){
        $root="$laterSkillRoot-$case";Copy-Item $laterSkillRoot $root -Recurse
        switch($case){
            'later-skill-missing-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.later_required_skill_surfaces=@();Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'later-skill-extra-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.later_required_skill_surfaces+=[pscustomobject][ordered]@{skill_id='optional-skill';path='<skills-root>/optional-skill/SKILL.md';current_action='update';terminal_requirement='not-required-at-acceptance';retained_as='must reject optional current route'};Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'later-skill-already-present' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.instruction_surfaces+=[pscustomobject]@{surface_kind='skill';skill_id='rusty-morphospace';path='<skills-root>/rusty-morphospace/SKILL.md';owner='workflow-maintainer';change_reason='Already present immutable skill surface.';action='update';status='complete';validation='Fixture.'};Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'later-skill-wrong-path' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.later_required_skill_surfaces[0].path='<skills-root>/wrong-skill/SKILL.md';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'later-skill-action-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.later_required_skill_surfaces[0].current_action='review-no-change';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'later-skill-terminal-requirement' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.later_required_skill_surfaces[0].terminal_requirement='complete';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'later-skill-blocked-status' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.status='blocked';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;$r.units[0].terminal_status='blocked';Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'later-skill-current-unit' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.current_unit='unit-example-001';Write-Json $s $d } $case }
            'later-skill-event-type' { Assert-Rejected $root { $e=Join-Path $root 'iteration-events.jsonl';$d=@(Get-Content $e|ForEach-Object{$_|ConvertFrom-Json})[0];$d.event_type='blocker';($d|ConvertTo-Json -Compress)|Set-Content -LiteralPath $e -Encoding utf8;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].terminal_evidence.event_sha256=Get-EventLineSha $e;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'later-skill-event-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.event_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'later-skill-receipt-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.receipt_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'later-skill-receipt-result' { Assert-Rejected $root { $v=Join-Path $root 'receipts/unit-example-001-validation.json';$d=Get-Content -Raw $v|ConvertFrom-Json;$d.result='blocked';Write-Json $v $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].terminal_evidence.receipt_sha256=Get-Sha $v;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'later-skill-reference-removed' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.PSObject.Properties.Remove('historical_unit_adoption_receipts');Write-Json $s $d } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    Remove-Item -LiteralPath $laterSkillRoot -Recurse -Force
    $supersededInstructionRoot="$base-superseded-instruction";Copy-Item $base $supersededInstructionRoot -Recurse
    Convert-ToSupersededInstructionDebtFixture $supersededInstructionRoot
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $supersededInstructionRoot -SkipOwnerSelfTests | Out-Null
    foreach($case in @('supersession-event-missing','supersession-event-id','supersession-old-binding','supersession-current-old')){
        $root="$supersededInstructionRoot-$case";Copy-Item $supersededInstructionRoot $root -Recurse
        switch($case){
            'supersession-event-missing' { Assert-Rejected $root { Set-Content -LiteralPath (Join-Path $root 'iteration-events.jsonl') -Value '' -Encoding utf8;$s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.last_event_id=$null;Write-Json $s $d } $case }
            'supersession-event-id' { Assert-Rejected $root { $e=Join-Path $root 'iteration-events.jsonl';$d=@(Get-Content $e|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|ForEach-Object{$_|ConvertFrom-Json})[0];$d.event_id='unit-example-001-replaced-by-unit-example-002';($d|ConvertTo-Json -Compress)|Set-Content -LiteralPath $e -Encoding utf8;$s=Join-Path $root 'workspace.state.json';$state=Get-Content -Raw $s|ConvertFrom-Json;$state.last_event_id=$d.event_id;Write-Json $s $state } $case }
            'supersession-old-binding' { Assert-Rejected $root { $e=Join-Path $root 'iteration-events.jsonl';$d=@(Get-Content $e|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|ForEach-Object{$_|ConvertFrom-Json})[0];$d.unit_id='unit-example-002';($d|ConvertTo-Json -Compress)|Set-Content -LiteralPath $e -Encoding utf8 } $case }
            'supersession-current-old' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.current_unit='unit-example-001';Write-Json $s $d } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    Remove-Item -LiteralPath $supersededInstructionRoot -Recurse -Force
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
    $missingSkillCases=@('missing-required-skill-mapping','extra-optional-skill-mapping','duplicate-required-skill-mapping','already-present-skill-mapping','wrong-required-skill-path','wrong-required-skill-action','wrong-required-skill-owner-claim','required-skill-status-claim','required-skill-edit-claim','required-skill-completion-claim','required-skill-validation-claim','missing-skill-unit-acceptance-claim','missing-skill-normalization-execution-claim','missing-skill-non-feature','missing-skill-non-update-impact','missing-skill-accepted-status','missing-skill-active-status','missing-skill-current-unit','missing-skill-unit-hash','missing-skill-event','missing-skill-event-type','missing-skill-nonterminal-event','missing-skill-event-hash-property','missing-skill-event-hash','missing-skill-receipt-hash-property','missing-skill-receipt-hash','missing-skill-receipt-semantics','missing-skill-unrelated-unit')
    foreach($case in $missingSkillCases){
        $root="$missingSkillRoot-$case";Copy-Item $missingSkillRoot $root -Recurse
        switch($case){
            'missing-required-skill-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces=@($d.units[0].normalization.missing_required_skill_surfaces|Where-Object{$_.skill_id-ne'rusty-morphospace'});Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'extra-optional-skill-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces+=[pscustomobject][ordered]@{skill_id='optional-skill';path='<skills-root>/optional-skill/SKILL.md';current_action='update';retained_status='planned';retained_as='must reject optional surface'};Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'duplicate-required-skill-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces+=$d.units[0].normalization.missing_required_skill_surfaces[0];Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'already-present-skill-mapping' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.instruction_surfaces+=[pscustomobject]@{surface_kind='skill';skill_id='rusty-morphospace';path='<skills-root>/rusty-morphospace/SKILL.md';owner='workflow-maintainer';change_reason='Already present immutable skill surface.';action='update';status='planned';validation='Fixture.'};Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'wrong-required-skill-path' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0].path='<skills-root>/wrong-skill/SKILL.md';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'wrong-required-skill-action' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0].current_action='review-no-change';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'wrong-required-skill-owner-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0]|Add-Member -NotePropertyName owner -NotePropertyValue unrelated-owner;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'required-skill-status-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0].retained_status='complete';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'required-skill-edit-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0]|Add-Member -NotePropertyName instruction_edited -NotePropertyValue $true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'required-skill-completion-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0]|Add-Member -NotePropertyName completion_claimed -NotePropertyValue $true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'required-skill-validation-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.missing_required_skill_surfaces[0]|Add-Member -NotePropertyName validation_executed -NotePropertyValue $true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-unit-acceptance-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0]|Add-Member -NotePropertyName acceptance_claimed -NotePropertyValue $true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-normalization-execution-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization|Add-Member -NotePropertyName validation_executed -NotePropertyValue $true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-non-feature' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.work_mode='validation-only';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'missing-skill-non-update-impact' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.instruction_impact='review';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;$r.units[0].normalization.instruction_impact=@([pscustomobject]@{legacy='review';current='update';retained_as='must not combine with missing-skill projection'});Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'missing-skill-accepted-status' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.status='accepted';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;$r.units[0].terminal_status='accepted';Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'missing-skill-active-status' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.status='active';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'missing-skill-current-unit' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.current_unit='unit-example-001';Write-Json $s $d } $case }
            'missing-skill-unit-hash' { Assert-Rejected $root { Add-Content -LiteralPath (Join-Path $root 'iteration-units/unit-example-001.json') ' ' } $case }
            'missing-skill-event' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.event_id='missing-terminal-event';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-event-type' { Assert-Rejected $root { $e=Join-Path $root 'iteration-events.jsonl';$d=@(Get-Content $e|ForEach-Object{$_|ConvertFrom-Json})[0];$d.event_type='state-transition';($d|ConvertTo-Json -Compress)|Set-Content -LiteralPath $e -Encoding utf8;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].terminal_evidence.event_sha256=Get-EventLineSha $e;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'missing-skill-nonterminal-event' { Assert-Rejected $root { $e=Join-Path $root 'iteration-events.jsonl';$later=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-example-001-later-blocked';sequence=2;timestamp='2026-01-02T00:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='blocker';summary='Later same-unit blocker.';receipts=@('receipts/unit-example-001-validation.json')};($later|ConvertTo-Json -Compress)|Add-Content -LiteralPath $e -Encoding utf8;$s=Join-Path $root 'workspace.state.json';$state=Get-Content -Raw $s|ConvertFrom-Json;$state.last_event_id='unit-example-001-later-blocked';Write-Json $s $state } $case }
            'missing-skill-event-hash-property' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.PSObject.Properties.Remove('event_sha256');Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-event-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.event_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-receipt-hash-property' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.PSObject.Properties.Remove('receipt_sha256');Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-receipt-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.receipt_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-receipt-semantics' { Assert-Rejected $root { $v=Join-Path $root 'receipts/unit-example-001-validation.json';$validation=Get-Content -Raw $v|ConvertFrom-Json;$validation.result='partial';Write-Json $v $validation;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].terminal_evidence.receipt_sha256=Get-Sha $v;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'missing-skill-unrelated-unit' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].unit_id='unrelated-unit';$d.units[0].unit_path='iteration-units/unrelated-unit.json';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    Remove-Item -LiteralPath $missingSkillRoot -Recurse -Force
    $readOnlyScopeRoot="$base-read-only-dependency-scope";Copy-Item $base $readOnlyScopeRoot -Recurse
    Convert-ToBlockedReadOnlyDependencyScopeFixture $readOnlyScopeRoot
    if(-not(Get-Content -Raw (Join-Path $readOnlyScopeRoot 'receipts/historical-unit-adoption-example.json')|Test-Json -SchemaFile (Join-Path $RepoRoot 'schemas/historical-unit-adoption-receipt.schema.json') -ErrorAction SilentlyContinue)){throw'Read-only dependency scope adoption fixture failed its schema.'}
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $readOnlyScopeRoot -SkipOwnerSelfTests | Out-Null
    $readOnlyScopeCases=@('read-scope-missing-mapping','read-scope-extra-valid-row-mapping','read-scope-broader-target','read-scope-optional-target','read-scope-closure-hash','read-scope-renamed-repo','read-scope-current-unit','read-scope-accepted-unit','read-scope-terminal-receipt','read-scope-reference-removed')
    foreach($case in $readOnlyScopeCases){
        $root="$readOnlyScopeRoot-$case";Copy-Item $readOnlyScopeRoot $root -Recurse
        switch($case){
            'read-scope-missing-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.read_only_dependency_scope.mappings=@();Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'read-scope-extra-valid-row-mapping' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.read_only_dependency_scope.mappings+=[pscustomobject]@{repo_id='matter-core';legacy_path='schemas/';current_paths=@('schemas/');retained_as='must reject valid row mapping'};Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'read-scope-broader-target' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.read_only_dependency_scope.mappings[0].current_paths=@('crates/particle-field/');Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'read-scope-optional-target' { Assert-Rejected $root { $c=Join-Path $root 'receipts/read-only-scope-closure.json';$closure=Get-Content -Raw $c|ConvertFrom-Json;$paths=@('crates/particle-field/src/optional.rs','schemas/');$closure.proposed_read_only_dependencies[0].paths=$paths;$closure.proposed_read_only_dependencies[0].path_count=$paths.Count;$closure.proposed_read_only_dependencies[0].sorted_lf_joined_path_sha256=Get-SortedPathSha $paths;Write-Json $c $closure;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.read_only_dependency_scope.closure.sha256=Get-Sha $c;$d.units[0].normalization.read_only_dependency_scope.mappings[0].current_paths=@('crates/particle-field/src/optional.rs');Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'read-scope-closure-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.read_only_dependency_scope.closure.sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'read-scope-renamed-repo' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.read_only_dependency_scope.mappings[0].repo_id='project-shell';Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'read-scope-current-unit' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.current_unit='unit-example-001';Write-Json $s $d } $case }
            'read-scope-accepted-unit' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;$d.status='accepted';Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;$r.units[0].terminal_status='accepted';Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'read-scope-terminal-receipt' { Assert-Rejected $root { $v=Join-Path $root 'receipts/unit-example-001-validation.json';$d=Get-Content -Raw $v|ConvertFrom-Json;$d.result='partial';Write-Json $v $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].terminal_evidence.receipt_sha256=Get-Sha $v;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'read-scope-reference-removed' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.PSObject.Properties.Remove('historical_unit_adoption_receipts');Write-Json $s $d } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    Remove-Item -LiteralPath $readOnlyScopeRoot -Recurse -Force
    $completedScopeRoot="$base-completed-project-scope";Copy-Item $base $completedScopeRoot -Recurse
    Convert-ToBlockedCompletedProjectScopeFixture $completedScopeRoot
    if(-not(Get-Content -Raw (Join-Path $completedScopeRoot 'receipts/historical-unit-adoption-example.json')|Test-Json -SchemaFile (Join-Path $RepoRoot 'schemas/historical-unit-adoption-receipt.schema.json') -ErrorAction SilentlyContinue)){throw'Completed project scope adoption fixture failed its schema.'}
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $completedScopeRoot -SkipOwnerSelfTests | Out-Null
    $completedScopeCases=@('completed-scope-missing-correction','completed-scope-extra-correction','completed-scope-retained-write-repo','completed-scope-category-drift','completed-scope-project-hash','completed-scope-blocker-hash','completed-scope-blocker-missing','completed-scope-receipt-hash','completed-scope-missing-receipt','completed-scope-event-hash','completed-scope-intent-hash','completed-scope-unit-path-drift','completed-scope-mutation-claim','completed-scope-current-unit','completed-scope-later-event','completed-scope-terminal-receipt','completed-scope-reference-removed')
    foreach($case in $completedScopeCases){
        $root="$completedScopeRoot-$case";Copy-Item $completedScopeRoot $root -Recurse
        switch($case){
            'completed-scope-missing-correction' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.corrections=@();Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-extra-correction' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.corrections+=$d.units[0].normalization.completed_project_scope.corrections[0];Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-retained-write-repo' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.allowed_repositories+=[pscustomobject]@{repo_id='matter-core';allowed_paths=@('tools/exact.ps1')};Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-category-drift' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.change_categories=@('validation','repo-routing');Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-project-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.project_snapshot.project_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-blocker-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.blocker_evidence.sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-blocker-missing' { Assert-Rejected $root { Remove-Item -LiteralPath (Join-Path $root 'receipts/evidence/historical-scope-blocker.json') -Force } $case }
            'completed-scope-receipt-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.corrections[0].receipt_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-missing-receipt' { Assert-Rejected $root { Move-Item (Join-Path $root 'receipts/fixture-scope-correction.json') (Join-Path $root 'receipts/fixture-scope-correction.missing') } $case }
            'completed-scope-event-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.corrections[0].event_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-intent-hash' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.corrections[0].intent_sha256=('0'*64);Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-unit-path-drift' { Assert-Rejected $root { $u=Join-Path $root 'iteration-units/unit-example-001.json';$d=Get-Content -Raw $u|ConvertFrom-Json;@($d.allowed_repositories|Where-Object{$_.repo_id-eq'matter-core'})[0].allowed_paths=@('tools/other.ps1');Write-Json $u $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].unit_sha256=Get-Sha $u;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'completed-scope-mutation-claim' { Assert-Rejected $root { $p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$d=Get-Content -Raw $p|ConvertFrom-Json;$d.units[0].normalization.completed_project_scope.mutation_performed.git=$true;Write-Json $p $d;Refresh-ReceiptReference $root } $case }
            'completed-scope-current-unit' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.current_unit='unit-example-001';Write-Json $s $d } $case }
            'completed-scope-later-event' { Assert-Rejected $root { $e=Join-Path $root 'iteration-events.jsonl';$later=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unit-example-001-later-blocked';sequence=3;timestamp='2026-01-03T00:00:00Z';project_id='example-project';unit_id='unit-example-001';event_type='blocker';summary='Later event.';receipts=@('receipts/unit-example-001-validation.json')};($later|ConvertTo-Json -Compress)|Add-Content -LiteralPath $e -Encoding utf8;$s=Join-Path $root 'workspace.state.json';$state=Get-Content -Raw $s|ConvertFrom-Json;$state.last_event_id='unit-example-001-later-blocked';Write-Json $s $state } $case }
            'completed-scope-terminal-receipt' { Assert-Rejected $root { $v=Join-Path $root 'receipts/unit-example-001-validation.json';$d=Get-Content -Raw $v|ConvertFrom-Json;$d.result='partial';Write-Json $v $d;$p=Join-Path $root 'receipts/historical-unit-adoption-example.json';$r=Get-Content -Raw $p|ConvertFrom-Json;$r.units[0].terminal_evidence.receipt_sha256=Get-Sha $v;Write-Json $p $r;Refresh-ReceiptReference $root } $case }
            'completed-scope-reference-removed' { Assert-Rejected $root { $s=Join-Path $root 'workspace.state.json';$d=Get-Content -Raw $s|ConvertFrom-Json;$d.PSObject.Properties.Remove('historical_unit_adoption_receipts');Write-Json $s $d } $case }
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    Remove-Item -LiteralPath $completedScopeRoot -Recurse -Force
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
