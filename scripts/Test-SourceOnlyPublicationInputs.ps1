[CmdletBinding()]
param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$module = Import-Module (Join-Path $PSScriptRoot 'SourceOnlyPublicationInputs.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'SourceOnlyPublication.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationReceipt.psm1') -Force

$encoding = [Text.UTF8Encoding]::new($false)
$gitExecutable = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function Assert-Builder([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"), $encoding) }
function Copy-Document([object]$Value) { return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String) }
function Invoke-FixtureGit([string]$Repository, [string[]]$Arguments) {
    $output = @(& $gitExecutable -c core.hooksPath=NUL -c core.autocrlf=false -C $Repository @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "Synthetic Git failed: git -C $Repository $($Arguments -join ' ')`n$($output -join "`n")" }
    return @($output)
}
function Git-Value([string]$Repository, [string[]]$Arguments) { $rows = @(Invoke-FixtureGit $Repository $Arguments); if ($rows.Count -ne 1) { throw 'Synthetic Git did not return one value.' }; return $rows[0].Trim() }
function Assert-Rejected([scriptblock]$Action, [string]$Pattern, [string]$Label) {
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -like $Pattern) { return }; throw "$Label returned a different failure: $($_.Exception.Message)" }
    throw "$Label was not rejected."
}

function New-SyntheticSource([string]$Root, [string]$RepoId, [string]$Path, [string]$Secret) {
    $bare = Join-Path $Root "$RepoId-remote.git"; $repo = Join-Path $Root "$RepoId-work"
    [IO.Directory]::CreateDirectory($bare) | Out-Null
    & $gitExecutable init --bare --initial-branch=main $bare 2>&1 | Out-Null
    & $gitExecutable -c core.autocrlf=false clone $bare $repo 2>&1 | Out-Null
    Invoke-FixtureGit $repo @('config', 'user.email', 'fixture@example.invalid') | Out-Null; Invoke-FixtureGit $repo @('config', 'user.name', 'Fixture') | Out-Null; Invoke-FixtureGit $repo @('config', 'core.autocrlf', 'false') | Out-Null
    $file = Join-Path $repo $Path; [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null
    [IO.File]::WriteAllText($file, "baseline`n", $encoding); Invoke-FixtureGit $repo @('add', '--', $Path) | Out-Null; Invoke-FixtureGit $repo @('commit', '-m', 'baseline') | Out-Null; Invoke-FixtureGit $repo @('push', '-u', 'origin', 'main') | Out-Null
    $old = Git-Value $repo @('rev-parse', 'HEAD')
    [IO.File]::WriteAllText($file, "candidate $Secret`n", $encoding); Invoke-FixtureGit $repo @('add', '--', $Path) | Out-Null; Invoke-FixtureGit $repo @('commit', '-m', 'candidate') | Out-Null
    return [pscustomobject]@{ id = $RepoId; repo = $repo; remote = $bare; path = $Path; old = $old; candidate = Git-Value $repo @('rev-parse', 'HEAD') }
}

function Publish-SyntheticProviderMerge([object]$Source, [string]$Root) {
    Invoke-FixtureGit $Source.repo @('push', 'origin', "$($Source.candidate):refs/heads/candidate") | Out-Null
    $merger = Join-Path $Root "merge-$($Source.id)"; & $gitExecutable -c core.autocrlf=false clone $Source.remote $merger 2>&1 | Out-Null
    Invoke-FixtureGit $merger @('config', 'user.email', 'fixture@example.invalid') | Out-Null; Invoke-FixtureGit $merger @('config', 'user.name', 'Fixture') | Out-Null; Invoke-FixtureGit $merger @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-FixtureGit $merger @('checkout', 'main') | Out-Null; Invoke-FixtureGit $merger @('merge', '--no-ff', '--no-edit', 'origin/candidate') | Out-Null
    $pushOutput = @(Invoke-FixtureGit $merger @('push', 'origin', 'main'))
    Invoke-FixtureGit $Source.repo @('fetch', 'origin', 'main') | Out-Null
    $artifactPath = Join-Path $Root "inputs/$($Source.id)-push.log"
    [IO.File]::WriteAllText($artifactPath, (($pushOutput -join "`n") + "`n"), $encoding)
    return [pscustomobject]@{ final = Git-Value $merger @('rev-parse', 'HEAD'); artifact = $artifactPath }
}

function New-SyntheticOperationEvidence([object]$Start, [object]$Published, [string]$FinishedAt, [string]$OutPath) {
    # Only called after this harness's checked, non-force Git push completed.
    $document = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.source_only_publication_operation_evidence.v1'
        operation_start_sha256 = Get-MorphospaceFileSha256 $Start.path
        provider = [pscustomobject][ordered]@{ repo_id = $Start.document.repo_id; executor_id = 'synthetic-provider' }
        outcome = [pscustomobject][ordered]@{ operation_finished_at = $FinishedAt; push_mode = 'fast-forward'; force_used = $false; result = 'pass' }
        artifact = [pscustomobject][ordered]@{ path = [IO.Path]::GetFileName($Published.artifact); sha256 = Get-MorphospaceFileSha256 $Published.artifact }
    }
    Write-Json $OutPath $document
    return [pscustomobject]@{ path = $OutPath; sha256 = Get-MorphospaceFileSha256 $OutPath; document = $document }
}

function New-RehearsalFixture([string]$Root) {
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $provider = New-SyntheticSource $Root 'provider-source' 'provider.txt' 'SYNTHETIC-CONTENT-ONE'
    $consumer = New-SyntheticSource $Root 'consumer-source' 'consumer.txt' 'SYNTHETIC-CONTENT-TWO'
    $readonly = New-SyntheticSource $Root 'reference-source' 'reference.txt' 'SYNTHETIC-CONTENT-THREE'
    Invoke-FixtureGit $readonly.repo @('push', 'origin', 'main') | Out-Null
    $planning = Join-Path $Root 'planning'; $workspace = Join-Path $planning 'morphospace'; $inputs = Join-Path $Root 'inputs'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null; [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null; [IO.Directory]::CreateDirectory($inputs) | Out-Null
    & $gitExecutable init --initial-branch=main $planning 2>&1 | Out-Null; Invoke-FixtureGit $planning @('config', 'user.email', 'fixture@example.invalid') | Out-Null; Invoke-FixtureGit $planning @('config', 'user.name', 'Fixture') | Out-Null; Invoke-FixtureGit $planning @('config', 'core.autocrlf', 'false') | Out-Null
    $example = Join-Path (Split-Path $PSScriptRoot -Parent) 'examples\hello-morphospace-v2\morphospace'
    $project = Get-Content -Raw (Join-Path $example 'project.spec.json') | ConvertFrom-Json -Depth 64 -DateKind String
    $project.project_id = 'publication-rehearsal'; $project.purpose = 'Synthetic source-only publication builder rehearsal.'; $project.authority_map[0].owner = 'provider-source'
    $project.repositories = @(
        [pscustomobject][ordered]@{ repo_id = 'provider-source'; role = 'core'; path = '<provider-source>'; allowed_paths = @('provider.txt') },
        [pscustomobject][ordered]@{ repo_id = 'consumer-source'; role = 'application'; path = '<consumer-source>'; allowed_paths = @('consumer.txt') },
        [pscustomobject][ordered]@{ repo_id = 'reference-source'; role = 'core'; path = '<reference-source>'; allowed_paths = @('reference.txt') }
    )
    $project.validation_profiles = @([pscustomobject][ordered]@{ profile_id = 'snapshot'; commands = @('synthetic snapshot validation') })
    $lock = Get-Content -Raw (Join-Path $example 'feature.lock.json') | ConvertFrom-Json -Depth 64 -DateKind String; $lock.project_id = 'publication-rehearsal'; $lock.lock_fingerprint = Get-MorphospaceFeatureLockFingerprint $lock
    $unit = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_unit.v1'; unit_id = 'snapshot-unit'; project_id = 'publication-rehearsal'; status = 'validating'; objective = 'Validate an unchanged source snapshot before source-only publication.'
        work_mode = 'validation-only'; guard_profile = 'fast'; change_categories = @('validation'); instruction_impact = 'review'
        instruction_surfaces = @([pscustomobject][ordered]@{ surface_kind = 'agents'; path = 'AGENTS.md'; owner = 'fixture-owner'; change_reason = 'Review only.'; action = 'review-no-change'; status = 'complete'; validation = 'synthetic instruction review'; skill_id = $null }); instruction_none_justification = $null
        prerequisites = @(); allowed_repositories = @([pscustomobject][ordered]@{ repo_id = 'provider-source'; allowed_paths = @() }, [pscustomobject][ordered]@{ repo_id = 'consumer-source'; allowed_paths = @() })
        read_only_dependencies = @([pscustomobject][ordered]@{ repo_id = 'reference-source'; paths = @('reference.txt'); purpose = 'Synthetic pinned reference.'; verification = 'Exact candidate revision.' })
        claim_requirements = [pscustomobject][ordered]@{ minimum_free_disk_mib = 0; required_tools = @(); product_inputs = @() }
        non_scope = @('Source mutation.', 'Planning publication.', 'Runtime or wearer claims.'); acceptance = @([pscustomobject][ordered]@{ acceptance_id = 'source-review'; proof = 'Synthetic source snapshot is reviewed.'; command = 'synthetic source review' })
        risk_tier = 'standard'; device_requirement = 'none'; validation = @([pscustomobject][ordered]@{ profile_id = 'snapshot'; command = 'synthetic snapshot validation' }); outputs = @('validation receipt'); commit_policy = 'Synthetic fixture only.'; push_checkpoint = 'integration-batch'
    }
    foreach ($surface in @(
        @{kind='readme';path='README.md';skill=$null},
        @{kind='skill';path='skills/rusty-morphospace/SKILL.md';skill='rusty-morphospace'},
        @{kind='skill';path='skills/system-engineering/SKILL.md';skill='system-engineering'}
    )) {
        $unit.instruction_surfaces += [pscustomobject][ordered]@{ surface_kind=$surface.kind; path=$surface.path; owner='fixture-owner'; change_reason='Review only.'; action='review-no-change'; status='complete'; validation='synthetic instruction review'; skill_id=$surface.skill }
    }
    $state = Get-Content -Raw (Join-Path $example 'workspace.state.json') | ConvertFrom-Json -Depth 64 -DateKind String
    $state.project_id = 'publication-rehearsal'; $state.current_unit = 'snapshot-unit'; $state.next_ready_unit = $null; $state.last_event_id = 'snapshot-unit-validating-0001'; $state.last_accepted_receipt = $null; $state.validation_checkpoint = $null; $state.repository_heads = @(); $state.dirty_repositories = @(); $state.module_registry.lock_fingerprint = $lock.lock_fingerprint
    $event = [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.iteration_event.v1'; event_id = 'snapshot-unit-validating-0001'; sequence = 1; timestamp = '2026-09-08T09:00:00.0000000Z'; project_id = 'publication-rehearsal'; unit_id = 'snapshot-unit'; event_type = 'state-transition'; summary = 'Synthetic validating baseline.'; receipts = @() }
    Write-Json (Join-Path $workspace 'project.spec.json') $project; Write-Json (Join-Path $workspace 'feature.lock.json') $lock; Write-Json (Join-Path $workspace 'workspace.state.json') $state; Write-Json (Join-Path $workspace 'iteration-units\snapshot-unit.json') $unit
    $retired = Copy-Document $unit; $retired.unit_id = 'retired-unit'; $retired.status = 'superseded'
    Write-Json (Join-Path $workspace 'iteration-units\retired-unit.json') $retired
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'), (($event | ConvertTo-Json -Compress) + "`n"), $encoding)
    [IO.File]::WriteAllText((Join-Path $workspace 'receipts\validation-evidence.txt'), "synthetic validation evidence`n", $encoding)
    $evidence = [pscustomobject][ordered]@{
        receipt_id = 'snapshot-unit-pass-validation'; tier = 'standard'; result = 'pass'
        artifacts = @([pscustomobject][ordered]@{ artifact_id = 'validation-evidence'; kind = 'test-log'; path = 'validation-evidence.txt' })
        criteria = @([pscustomobject][ordered]@{ acceptance_id = 'source-review'; status = 'pass'; command = 'synthetic source review'; evidence_refs = @('validation-evidence') })
        gates = @(
            [pscustomobject][ordered]@{ gate_id = 'validation-snapshot'; status = 'pass'; command = 'synthetic snapshot validation'; evidence_refs = @('validation-evidence') },
            [pscustomobject][ordered]@{ gate_id = 'instruction-synchronization'; status = 'pass'; command = 'Verify every declared instruction surface is complete and validated.'; evidence_refs = @('validation-evidence') }
        ); device_validation = $null
    }
    $receiptPath = Join-Path $workspace 'receipts\snapshot-unit-pass-validation.json'
    $map = [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.repository_map.v1'; repositories = @(
        [pscustomobject][ordered]@{ repo_id = 'provider-source'; path = $provider.repo; role = 'source' }, [pscustomobject][ordered]@{ repo_id = 'consumer-source'; path = $consumer.repo; role = 'source' },
        [pscustomobject][ordered]@{ repo_id = 'reference-source'; path = $readonly.repo; role = 'source' }, [pscustomobject][ordered]@{ repo_id = 'planning-owner'; path = $planning; role = 'planning' },
        [pscustomobject][ordered]@{ repo_id = 'skill-surfaces'; path = $inputs; role = 'source' }
    ) }
    $mapPath = Join-Path $inputs 'repository-map.json'; Write-Json $mapPath $map
    New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId 'snapshot-unit' -RepoMapPath $mapPath -Evidence $evidence -OutPath $receiptPath -CreatedAt '2026-09-08T09:01:00.0000000Z' | Out-Null
    Invoke-FixtureGit $planning @('add', 'morphospace') | Out-Null; Invoke-FixtureGit $planning @('commit', '-m', 'validating snapshot') | Out-Null
    return [pscustomobject]@{ root = $Root; planning = $planning; workspace = $workspace; inputs = $inputs; map = $mapPath; provider = $provider; consumer = $consumer; readonly = $readonly; receipt = $receiptPath }
}

function Assert-CurrentWork([object]$Fixture, [string]$Phase) {
    $output = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -RepoRoot (Split-Path $PSScriptRoot -Parent) -WorkspaceRoot $Fixture.workspace -RepositoryMapPath $Fixture.map -CurrentWorkOnly -SkipOwnerSelfTests 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "Current-work validation failed after $Phase`: $($output -join ' ')" }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('source-only-input-builders-' + [guid]::NewGuid().ToString('N'))
try {
    $f = New-RehearsalFixture $testRoot
    $retiredPath = Join-Path $f.workspace 'iteration-units/retired-unit.json'; $retiredHash = Get-MorphospaceFileSha256 $retiredPath
    $malformed = Copy-Document (Get-Content -Raw $f.receipt | ConvertFrom-Json -Depth 64 -DateKind String); $malformed.criteria[0].evidence_refs = 'validation-evidence'
    $malformedPath = Join-Path $f.workspace 'receipts\malformed-validation.json'; Write-Json $malformedPath $malformed
    Assert-Rejected { Assert-MorphospaceValidationReceiptStructure -ReceiptPath $malformedPath -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1' } '*does not satisfy*' 'malformed v1 singleton receipt'
    $beforeStateHash = Get-MorphospaceFileSha256 (Join-Path $f.workspace 'workspace.state.json')
    Assert-Rejected { Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -ValidationTier standard -ValidationResult pass -ValidationReceipt 'receipts/malformed-validation.json' -Timestamp '2026-09-08T09:02:00.0000000Z' -Execute } '*does not satisfy*' 'malformed receipt at first workflow write boundary'
    Assert-Builder ((Get-MorphospaceFileSha256 (Join-Path $f.workspace 'workspace.state.json')) -ceq $beforeStateHash) 'Malformed receipt changed workflow state.'
    Remove-Item -LiteralPath $malformedPath
    Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -ValidationTier standard -ValidationResult pass -ValidationReceipt 'receipts/snapshot-unit-pass-validation.json' -Timestamp '2026-09-08T09:02:00.0000000Z' -Execute | Out-Null
    Assert-CurrentWork $f 'builder-backed validation recording'
    Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -Timestamp '2026-09-08T09:03:00.0000000Z' -Execute | Out-Null
    Assert-CurrentWork $f 'builder-backed acceptance'
    Invoke-FixtureGit $f.planning @('add', 'morphospace') | Out-Null; Invoke-FixtureGit $f.planning @('commit', '-m', 'accept snapshot') | Out-Null

    $publicationId = 'synthetic-source-publication'; $readinessPath = Join-Path $f.inputs 'readiness.json'
    $readiness = Get-MorphospaceSourceOnlyPublicationReadiness -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -PublicationId $publicationId -OutPath $readinessPath
    Assert-Builder ([string]$readiness.document.status -ceq 'supported') "Readiness did not support the neutral snapshot: $(@($readiness.document.reason_codes) -join ', ')."
    Assert-Builder (@($readiness.document.source_repositories).Count -eq 2) 'Readiness included a read-only dependency or non-project skill support map as a publication row.'
    $missingMap = Get-Content -Raw $f.map | ConvertFrom-Json -Depth 64 -DateKind String
    $missingMap.repositories = @($missingMap.repositories | Where-Object { $_.repo_id -cne 'consumer-source' })
    $missingMapPath = Join-Path $f.inputs 'missing-source-map.json'; Write-Json $missingMapPath $missingMap
    $missingReadiness = Get-MorphospaceSourceOnlyPublicationReadiness -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $missingMapPath -PublicationId $publicationId
    Assert-Builder ($missingReadiness.status -ceq 'unsupported' -and @($missingReadiness.reason_codes) -ccontains 'allowed-source-shape-unsupported:consumer-source') 'Missing project source was not rejected by readiness.'
    $readinessRaw = Get-Content -Raw $readinessPath
    foreach ($forbidden in @($f.provider.repo, $f.consumer.repo, 'SYNTHETIC-CONTENT-ONE', 'SYNTHETIC-CONTENT-TWO')) { Assert-Builder (-not $readinessRaw.Contains($forbidden)) 'Readiness leaked a local source path or payload.' }

    $noDeltaRoot = Join-Path $testRoot 'no-delta'; [IO.Directory]::CreateDirectory($noDeltaRoot) | Out-Null
    $candidateBytes = [IO.File]::ReadAllBytes((Join-Path $f.provider.repo 'provider.txt'))
    Invoke-FixtureGit $f.provider.repo @('push', 'origin', 'HEAD:main') | Out-Null
    $noDelta = Get-MorphospaceSourceOnlyPublicationReadiness -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -PublicationId 'unsupported-source-publication'
    Assert-Builder ([string]$noDelta.status -ceq 'unsupported' -and @($noDelta.reason_codes) -contains 'no-publication-delta:provider-source') 'Readiness did not expose the unsupported no-delta source shape.'
    & $gitExecutable -C $f.provider.remote update-ref refs/heads/main $f.provider.old | Out-Null
    & $gitExecutable -C $f.provider.repo update-ref refs/remotes/origin/main $f.provider.old | Out-Null

    $planInput = Join-Path $f.inputs 'plan.json'
    $planResult = New-MorphospaceSourceOnlyPublicationPlan -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -PublicationId $publicationId -OutPath $planInput
    Assert-Builder (@($planResult.document.source_repositories | Where-Object { @($_.trigger_unit_paths).Count -ne 0 }).Count -eq 0) 'Validation-only empty write scope gained trigger paths.'
    Assert-Builder (@($planResult.document.source_repositories | Where-Object { @($_.carried_paths).Count -ne 1 }).Count -eq 0) 'Builder did not retain both carried source deltas.'
    $planRaw = Get-Content -Raw $planInput; Assert-Builder (-not $planRaw.Contains('SYNTHETIC-CONTENT-ONE') -and -not $planRaw.Contains('SYNTHETIC-CONTENT-TWO')) 'Plan embedded source payload bytes.'
    $supportPlan = Copy-Document $planResult.document; $supportPlan.source_repositories[1].repo_id = 'skill-surfaces'
    $supportPlanPath = Join-Path $f.inputs 'support-source-plan.json'; Write-Json $supportPlanPath $supportPlan
    Assert-Rejected { Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationPlan $supportPlanPath -ExpectedSourceOnlyPublicationPlanSha256 (Get-MorphospaceFileSha256 $supportPlanPath) -OutPath (Join-Path $f.workspace "receipts/$publicationId-plan.json") } '*source*' 'external support entry used as a publication target'
    $artifactPath = Join-Path $f.workspace 'receipts/validation-evidence.txt'; $artifactBytes = [IO.File]::ReadAllBytes($artifactPath)
    [IO.File]::WriteAllText($artifactPath, 'altered evidence', $encoding)
    Assert-Rejected { New-MorphospaceSourceOnlyPublicationPlan -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -PublicationId $publicationId -OutPath (Join-Path $f.inputs 'altered-evidence-plan.json') } '*planning-owner-dirty*' 'altered committed validation evidence'
    [IO.File]::WriteAllBytes($artifactPath, $artifactBytes)

    [IO.File]::WriteAllText((Join-Path $f.provider.repo 'provider.txt'), "drift after plan`n", $encoding)
    Assert-Rejected { Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationPlan $planInput -ExpectedSourceOnlyPublicationPlanSha256 $planResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-plan.json") -Timestamp '2026-09-08T09:59:00.0000000Z' } "*Source repository 'provider-source' is dirty*" 'source drift after plan'
    [IO.File]::WriteAllBytes((Join-Path $f.provider.repo 'provider.txt'), $candidateBytes)
    Assert-Builder (@(Invoke-FixtureGit $f.provider.repo @('status', '--porcelain=v1', '--untracked-files=all')).Count -eq 0) 'Synthetic source drift cleanup did not restore exact bytes.'

    Assert-Rejected { Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationPlan $planInput -ExpectedSourceOnlyPublicationPlanSha256 $planResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-plan.json") -Timestamp '2026-09-08T09:59:00.0000000Z' -FaultAfter after-artifact -Execute } 'Injected interruption after artifact installation.' 'interrupted preparation'
    Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationPlan $planInput -ExpectedSourceOnlyPublicationPlanSha256 $planResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-plan.json") -Timestamp '2026-09-08T09:59:00.0000000Z' -Execute | Out-Null
    Assert-CurrentWork $f 'builder-backed preparation recovery'
    $preparedPlan = Join-Path $f.workspace "receipts/$publicationId-plan.json"

    $providerStart = Start-MorphospaceSourceOnlyPublicationOperation -PlanPath $preparedPlan -RepoId 'provider-source' -Timestamp '2026-09-08T10:00:00.0000000Z' -OutPath (Join-Path $f.inputs 'provider-start.json')
    $providerPublished = Publish-SyntheticProviderMerge $f.provider $testRoot
    $providerEvidence = New-SyntheticOperationEvidence $providerStart $providerPublished '2026-09-08T10:00:05.0000000Z' (Join-Path $f.inputs 'provider-evidence.json')
    foreach ($damage in @('force','unknown-force','wrong-provider','wrong-start','missing-artifact')) {
        $damaged = Copy-Document $providerEvidence.document
        switch ($damage) {
            'force' { $damaged.outcome.force_used = $true }
            'unknown-force' { $damaged.outcome.force_used = $null }
            'wrong-provider' { $damaged.provider.repo_id = 'consumer-source' }
            'wrong-start' { $damaged.operation_start_sha256 = '0' * 64 }
            'missing-artifact' { $damaged.artifact.path = 'absent-operation.log' }
        }
        $damagedPath = Join-Path $f.inputs "$damage-evidence.json"; Write-Json $damagedPath $damaged
        Assert-Rejected { Complete-MorphospaceSourceOnlyPublicationOperationObservation -PlanPath $preparedPlan -OperationStartPath $providerStart.path -OperationEvidencePath $damagedPath -ExpectedOperationEvidenceSha256 (Get-MorphospaceFileSha256 $damagedPath) -RepoMapPath $f.map -Timestamp '2026-09-08T10:00:10.0000000Z' -OutPath (Join-Path $f.inputs "$damage-observation.json") } '*evidence*' "operation evidence $damage"
    }
    $providerObservation = Complete-MorphospaceSourceOnlyPublicationOperationObservation -PlanPath $preparedPlan -OperationStartPath $providerStart.path -OperationEvidencePath $providerEvidence.path -ExpectedOperationEvidenceSha256 $providerEvidence.sha256 -RepoMapPath $f.map -Timestamp '2026-09-08T10:00:10.0000000Z' -OutPath (Join-Path $f.inputs 'provider-observation.json')
    $consumerStart = Start-MorphospaceSourceOnlyPublicationOperation -PlanPath $preparedPlan -RepoId 'consumer-source' -Timestamp '2026-09-08T10:00:11.0000000Z' -OutPath (Join-Path $f.inputs 'consumer-start.json')
    $consumerPublished = Publish-SyntheticProviderMerge $f.consumer $testRoot
    $consumerEvidence = New-SyntheticOperationEvidence $consumerStart $consumerPublished '2026-09-08T10:00:15.0000000Z' (Join-Path $f.inputs 'consumer-evidence.json')
    $consumerObservation = Complete-MorphospaceSourceOnlyPublicationOperationObservation -PlanPath $preparedPlan -OperationStartPath $consumerStart.path -OperationEvidencePath $consumerEvidence.path -ExpectedOperationEvidenceSha256 $consumerEvidence.sha256 -RepoMapPath $f.map -Timestamp '2026-09-08T10:00:20.0000000Z' -OutPath (Join-Path $f.inputs 'consumer-observation.json')
    $executionInput = Join-Path $f.inputs 'execution.json'
    Assert-Rejected { New-MorphospaceSourceOnlyPublicationExecution -PlanPath $preparedPlan -OperationObservationPaths @($consumerObservation.path, $providerObservation.path) -RepoMapPath $f.map -OutPath (Join-Path $f.inputs 'reordered-execution.json') } '*ordinal*' 'reordered operation observations'
    $operationBytes = [IO.File]::ReadAllBytes($providerPublished.artifact)
    [IO.File]::WriteAllText($providerPublished.artifact, 'changed after observation', $encoding)
    Assert-Rejected { New-MorphospaceSourceOnlyPublicationExecution -PlanPath $preparedPlan -OperationObservationPaths @($providerObservation.path, $consumerObservation.path) -RepoMapPath $f.map -OutPath (Join-Path $f.inputs 'altered-operation-execution.json') } '*evidence*' 'operation evidence changed after observation'
    [IO.File]::WriteAllBytes($providerPublished.artifact, $operationBytes)
    $executionResult = New-MorphospaceSourceOnlyPublicationExecution -PlanPath $preparedPlan -OperationObservationPaths @($providerObservation.path, $consumerObservation.path) -RepoMapPath $f.map -OutPath $executionInput
    Assert-Builder (@($executionResult.document.source_repositories).Count -eq 2) 'Execution builder did not preserve the ordered source set.'

    Assert-Rejected { Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationExecution $executionInput -ExpectedSourceOnlyPublicationExecutionSha256 $executionResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-execution.json") -Timestamp '2026-09-08T10:01:00.0000000Z' -FaultAfter after-projection -Execute } 'Injected interruption after projections.' 'interrupted recording'
    Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationExecution $executionInput -ExpectedSourceOnlyPublicationExecutionSha256 $executionResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-execution.json") -Timestamp '2026-09-08T10:01:00.0000000Z' -Execute | Out-Null
    Assert-CurrentWork $f 'builder-backed recording recovery'
    Assert-Builder ((Get-MorphospaceFileSha256 $retiredPath) -ceq $retiredHash) 'Publication changed a preserved superseded unit.'
    'Source-only publication input builder self-test passed.'
} finally {
    $cleanupRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\','/'); $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if (-not [IO.Path]::GetDirectoryName($cleanupRoot).Equals($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($cleanupRoot).StartsWith('source-only-input-builders-',[StringComparison]::Ordinal)) { throw 'Fixture cleanup target is outside the direct temporary namespace.' }
    if (Test-Path -LiteralPath $cleanupRoot) { Remove-Item -LiteralPath $cleanupRoot -Recurse -Force }
}
