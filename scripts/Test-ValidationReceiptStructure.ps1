[CmdletBinding()]
param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationReceipt.psm1') -Force

function Assert-ReceiptTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Validation receipt structural self-test failed: $Message" }
}

function Copy-ReceiptTestDocument {
    param([object]$Document)
    return $Document | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String
}

$hash = '0' * 64
$revision = '0' * 40
$v1 = [pscustomobject][ordered]@{
    schema = 'rusty.morphospace.workflow.validation_receipt.v1'
    receipt_id = 'receipt-v1'
    project_id = 'project-v1'
    unit_id = 'unit-v1'
    created_at = '2026-09-08T00:00:00Z'
    tier = 'standard'
    result = 'pass'
    repository_revisions = @()
    changed_paths = @()
    artifacts = @([pscustomobject][ordered]@{ artifact_id='artifact-01'; kind='test-log'; path='artifact.txt'; sha256=$hash })
    criteria = @([pscustomobject][ordered]@{ acceptance_id='criterion-01'; status='pass'; command='test criterion'; evidence_refs=@('artifact-01') })
    gates = @([pscustomobject][ordered]@{ gate_id='gate-01'; status='pass'; command='test gate'; evidence_refs=@('artifact-01') })
    device_validation = $null
}
$zeroAndOne = Assert-MorphospaceValidationReceiptStructure -Document $v1
Assert-ReceiptTest (@($zeroAndOne.repository_revisions).Count -eq 0 -and @($zeroAndOne.changed_paths).Count -eq 0 -and @($zeroAndOne.criteria[0].evidence_refs).Count -eq 1) 'valid zero- and one-cardinality arrays were not preserved'

$many = Copy-ReceiptTestDocument $v1
$many.repository_revisions = @(
    [pscustomobject][ordered]@{ repo_id='repo-01'; base_revision=$revision; head_revision=$revision; branch='main' },
    [pscustomobject][ordered]@{ repo_id='repo-02'; base_revision=$revision; head_revision=$revision; branch=$null }
)
$many.changed_paths = @(
    [pscustomobject][ordered]@{ repo_id='repo-01'; path='src/one.txt' },
    [pscustomobject][ordered]@{ repo_id='repo-02'; path='src/two.txt' }
)
$many.artifacts = @(
    [pscustomobject][ordered]@{ artifact_id='artifact-01'; kind='test-log'; path='artifact-01.txt'; sha256=$hash },
    [pscustomobject][ordered]@{ artifact_id='artifact-02'; kind='test-log'; path='artifact-02.txt'; sha256=$hash }
)
$many.criteria = @(
    [pscustomobject][ordered]@{ acceptance_id='criterion-01'; status='pass'; command='test criterion one'; evidence_refs=@('artifact-01','artifact-02') },
    [pscustomobject][ordered]@{ acceptance_id='criterion-02'; status='pass'; command='test criterion two'; evidence_refs=@('artifact-02') }
)
$many.gates = @(
    [pscustomobject][ordered]@{ gate_id='gate-01'; status='pass'; command='test gate one'; evidence_refs=@('artifact-01') },
    [pscustomobject][ordered]@{ gate_id='gate-02'; status='pass'; command='test gate two'; evidence_refs=@('artifact-01','artifact-02') }
)
$manyResult = Assert-MorphospaceValidationReceiptStructure -Document $many
Assert-ReceiptTest (@($manyResult.repository_revisions).Count -eq 2 -and @($manyResult.criteria[0].evidence_refs).Count -eq 2 -and @($manyResult.gates).Count -eq 2) 'valid many-cardinality arrays were not preserved'

foreach ($field in @('repository_revisions','changed_paths','artifacts','criteria','gates')) {
    $malformed = Copy-ReceiptTestDocument $v1
    $malformed.$field = 'scalar-value'
    $rejected = $false
    try { Assert-MorphospaceValidationReceiptStructure -Document $malformed | Out-Null } catch { $rejected = $_.Exception.Message -like 'Validation receipt does not satisfy structural schema*' }
    Assert-ReceiptTest $rejected "scalar $field was accepted"
}
foreach ($collection in @('criteria','gates')) {
    $malformed = Copy-ReceiptTestDocument $v1
    $malformed.$collection[0].evidence_refs = 'artifact-01'
    $rejected = $false
    try { Assert-MorphospaceValidationReceiptStructure -Document $malformed | Out-Null } catch { $rejected = $_.Exception.Message -like 'Validation receipt does not satisfy structural schema*' }
    Assert-ReceiptTest $rejected "scalar $collection evidence_refs was accepted"
}

$typedReference = [pscustomobject][ordered]@{ role='validation-action'; path='actions/action.json'; schema='rusty.morphospace.workflow.validation_action.v2'; sha256=$hash }
$v2 = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.validation_receipt.v2'; receipt_id='receipt-v2'; created_at='2026-09-08T00:00:00.0000000Z'; project_id='project-v2'; unit_id='unit-v2'; attempt_id='attempt-v2'
    action=$typedReference
    evidence=[pscustomobject][ordered]@{ role='validation-evidence'; path='evidence/evidence.json'; schema='rusty.morphospace.workflow.validation_evidence.v2'; sha256=$hash }
    execution=[pscustomobject][ordered]@{ role='validation-execution'; path='execution/execution.json'; schema='rusty.morphospace.workflow.validation_execution.v1'; sha256=$hash }
    current_protocol=[pscustomobject][ordered]@{ role='current-unit-protocol'; path='protocol/protocol.json'; schema='rusty.morphospace.workflow.current_unit_protocol.v1'; sha256=$hash }
    ownership=[pscustomobject][ordered]@{ role='unit-ownership'; path='ownership/ownership.json'; schema='rusty.morphospace.workflow.unit_ownership.v1'; sha256=$hash }
    registry=[pscustomobject][ordered]@{ role='owner-validator-registry'; path='registry/registry.json'; schema='rusty.morphospace.workflow.owner_validator_registry.v1'; sha256=$hash }
    profile_id='profile-v2'; result='pass'
    criteria=@([pscustomobject][ordered]@{ acceptance_id='criterion-v2'; status='pass'; validator_id='validator-v2'; evidence_ref=[pscustomobject][ordered]@{ role='criterion-evidence'; path='evidence/criterion.json'; schema='rusty.morphospace.workflow.criterion_evidence.v1'; sha256=$hash } })
    validators=@('validator-v2')
    observations=[pscustomobject][ordered]@{ before_sha256=$hash; after_sha256=$hash; allowed_delta_sha256=$hash }
    device_validation=$null; status='accepted-evidence'
}
$v2Result = Assert-MorphospaceValidationReceiptStructure -Document $v2
Assert-ReceiptTest ([string]$v2Result.schema -ceq 'rusty.morphospace.workflow.validation_receipt.v2') 'version-aware dispatch rejected valid v2'
$stageRejected = $false
try { Assert-MorphospaceValidationReceiptStructure -Document $v2 -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1' | Out-Null } catch { $stageRejected = $_.Exception.Message -like '*not allowed by this workflow stage*' }
Assert-ReceiptTest $stageRejected 'stage schema restriction accepted v2 as v1'

$builderRoot = Join-Path ([IO.Path]::GetTempPath()) ('validation-receipt-builder-' + [guid]::NewGuid().ToString('N'))
try {
    $workspace = Join-Path $builderRoot 'morphospace'
    $repository = Join-Path $builderRoot 'source'
    $remote = Join-Path $builderRoot 'source.git'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $repository 'src')) | Out-Null
    & git -C $repository init | Out-Null
    & git -C $repository config user.email fixture@example.invalid
    & git -C $repository config user.name Fixture
    [IO.File]::WriteAllText((Join-Path $repository 'src/base.txt'),'base',[Text.UTF8Encoding]::new($false))
    & git -C $repository add src/base.txt
    & git -C $repository commit -m base | Out-Null
    & git -C $repository branch -M main
    & git init --bare $remote | Out-Null
    & git -C $repository remote add origin $remote
    & git -C $repository push -u origin main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Builder fixture Git initialization failed.' }
    [IO.File]::WriteAllText((Join-Path $repository 'src/committed.txt'),'committed',[Text.UTF8Encoding]::new($false))
    & git -C $repository add src/committed.txt
    & git -C $repository commit -m candidate | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Builder fixture candidate commit failed.' }
    [IO.File]::WriteAllText((Join-Path $repository 'src/new.txt'),'new',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $workspace 'receipts/evidence.txt'),'pass',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $workspace 'project.spec.json'),((@{project_id='builder-project'}|ConvertTo-Json)+"`n"),[Text.UTF8Encoding]::new($false))
    $unit = [pscustomobject][ordered]@{ project_id='builder-project'; unit_id='builder-unit'; allowed_repositories=@([pscustomobject][ordered]@{repo_id='source-repo';allowed_paths=@('src')}) }
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-units/builder-unit.json'),(($unit|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
    $repoMap = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([pscustomobject][ordered]@{repo_id='source-repo';path=$repository;role='source'})}
    $repoMapPath = Join-Path $builderRoot 'repository-map.json'
    [IO.File]::WriteAllText($repoMapPath,(($repoMap|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
    $productEvidence = [pscustomobject][ordered]@{
        receipt_id='builder-receipt'; tier='standard'; result='pass'
        artifacts=@([pscustomobject][ordered]@{artifact_id='builder-evidence';kind='test-log';path='evidence.txt'})
        criteria=@([pscustomobject][ordered]@{acceptance_id='builder-criterion';status='pass';command='project supplied criterion command';evidence_refs=@('builder-evidence')})
        gates=@([pscustomobject][ordered]@{gate_id='builder-gate';status='pass';command='project supplied gate command';evidence_refs=@('builder-evidence')})
        device_validation=$null
    }
    if (-not $IsWindows) {
        $caseDistinctSibling = Join-Path $builderRoot 'MORPHOSPACE'
        [IO.Directory]::CreateDirectory($caseDistinctSibling) | Out-Null
        $caseDistinctRejected = $false
        try { New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId builder-unit -RepoMapPath $repoMapPath -Evidence $productEvidence -OutPath (Join-Path $caseDistinctSibling 'escaped.json') | Out-Null } catch { $caseDistinctRejected = $_.Exception.Message -like '*must stay inside the project workspace*' }
        Assert-ReceiptTest ($caseDistinctRejected -and -not (Test-Path -LiteralPath (Join-Path $caseDistinctSibling 'escaped.json'))) 'v1 builder treated a case-distinct sibling as inside the Linux workspace'
    }
    if ($IsWindows) {
        $junctionTarget = Join-Path $builderRoot 'junction-target'
        $junctionPath = Join-Path $workspace 'receipt-junction'
        [IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
        try {
            $junctionRejected = $false
            try { New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId builder-unit -RepoMapPath $repoMapPath -Evidence $productEvidence -OutPath 'receipt-junction/escaped.json' | Out-Null } catch { $junctionRejected = $_.Exception.Message -like '*traverses a reparse point*' }
            Assert-ReceiptTest ($junctionRejected -and -not (Test-Path -LiteralPath (Join-Path $junctionTarget 'escaped.json'))) 'v1 builder followed an output-directory junction outside the workspace'
        } finally {
            $junctionItem = Get-Item -LiteralPath $junctionPath -Force
            $observedTarget = [string]@($junctionItem.Target)[0]
            if (-not [IO.Path]::IsPathRooted($observedTarget)) { $observedTarget = Join-Path (Split-Path -Parent $junctionPath) $observedTarget }
            $targetMatches = [IO.Path]::GetFullPath($observedTarget).Equals([IO.Path]::GetFullPath($junctionTarget),[StringComparison]::OrdinalIgnoreCase)
            Remove-Item -LiteralPath $junctionPath -Force
            Assert-ReceiptTest $targetMatches 'junction cleanup target was not the exact fixture target'
        }
    }
    $invalidUnitRejected = $false
    try { New-MorphospaceValidationReceiptV1 -WorkspaceRoot (Join-Path $builderRoot 'missing-workspace') -UnitId '../bad' -RepoMapPath (Join-Path $builderRoot 'missing-map.json') -Evidence $productEvidence -OutPath 'receipts/invalid-unit.json' | Out-Null } catch { $invalidUnitRejected = $_.Exception.Message -ceq 'Validation receipt generation UnitId is invalid.' }
    Assert-ReceiptTest $invalidUnitRejected 'v1 builder read filesystem inputs before rejecting an invalid unit ID'

    $hadGitDir = Test-Path Env:GIT_DIR
    $oldGitDir = $env:GIT_DIR
    try {
        $env:GIT_DIR = Join-Path $builderRoot 'hostile-git-dir'
        $built = New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId builder-unit -RepoMapPath $repoMapPath -Evidence $productEvidence -OutPath 'receipts/builder.json' -CreatedAt '2026-09-08T00:00:00Z'
    } finally {
        if ($hadGitDir) { $env:GIT_DIR = $oldGitDir } else { Remove-Item Env:GIT_DIR -ErrorAction SilentlyContinue }
    }
    Assert-ReceiptTest (@($built.repository_revisions).Count -eq 1 -and @($built.changed_paths).Count -eq 2 -and (@($built.changed_paths.path | Sort-Object) -join '|') -ceq 'src/committed.txt|src/new.txt') 'v1 builder did not derive repository identity and changed paths'
    Assert-ReceiptTest ([string]$built.repository_revisions[0].base_revision -cne [string]$built.repository_revisions[0].head_revision) 'v1 builder did not use its configured upstream as the source baseline'
    Assert-ReceiptTest ([string]$built.artifacts[0].sha256 -ceq (Get-FileHash -LiteralPath (Join-Path $workspace 'receipts/evidence.txt') -Algorithm SHA256).Hash.ToLowerInvariant()) 'v1 builder did not derive the artifact hash'
    $malformedEvidence = Copy-ReceiptTestDocument $productEvidence
    $malformedEvidence.criteria = 'scalar-criterion'
    $malformedBuilderRejected = $false
    try { New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId builder-unit -RepoMapPath $repoMapPath -Evidence $malformedEvidence -OutPath 'receipts/malformed.json' -CreatedAt '2026-09-08T00:00:00Z' | Out-Null } catch { $malformedBuilderRejected = $_.Exception.Message -like 'Validation receipt does not satisfy structural schema*' }
    Assert-ReceiptTest ($malformedBuilderRejected -and -not (Test-Path -LiteralPath (Join-Path $workspace 'receipts/malformed.json'))) 'v1 builder wrote malformed scalar evidence'

    [IO.Directory]::CreateDirectory((Join-Path $workspace 'locks')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'local')) | Out-Null
    $lockedMapPath = Join-Path $workspace 'local/repository-map.json'
    [IO.File]::WriteAllText($lockedMapPath,(($repoMap|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
    $lockedBase = (& git -C $repository rev-parse origin/main).Trim()
    $lockedTree = (& git -C $repository rev-parse "$lockedBase^{tree}").Trim()
    $lockedHead = (& git -C $repository rev-parse HEAD).Trim()
    $lockedHeadTree = (& git -C $repository rev-parse 'HEAD^{tree}').Trim()
    $sourceLock = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.source_composition_lock.v1'; lock_id='locked-source'; created_at='2026-09-08T00:00:00.0000000Z'; project_id='builder-project'; unit_id='locked-unit'; fingerprint=$hash
        repositories=@([pscustomobject][ordered]@{repo_id='source-repo';role='source';commit=$lockedBase;tree=$lockedTree;branch='main';remote_url=$remote;materialization_path='source';tracked_worktree_clean=$true})
        status='locked'; does_not_prove=@('Validation result')
    }
    $sourceLockPath = Join-Path $workspace 'locks/source.json'
    [IO.File]::WriteAllText($sourceLockPath,(($sourceLock|ConvertTo-Json -Depth 20)+"`n"),[Text.UTF8Encoding]::new($false))
    $sourceLockHash = (Get-FileHash -LiteralPath $sourceLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $lockedMapHash = (Get-FileHash -LiteralPath $lockedMapPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $candidateFreeze = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id='locked-freeze';project_id='builder-project';unit_id='locked-unit'
        expected=[pscustomobject][ordered]@{project_sha256=$hash;state_sha256=$hash;unit_sha256=$hash;feature_lock_sha256=$hash;source_composition_path='locks/source.json';source_composition_sha256=$sourceLockHash;repository_map_path='local/repository-map.json';repository_map_sha256=$lockedMapHash;events_sha256=$hash;events_length=1;event_tail_id='event-01'}
        final_repositories=@([pscustomobject][ordered]@{repo_id='source-repo';commit=$lockedHead;tree=$lockedHeadTree});changed_paths=@([pscustomobject][ordered]@{repo_id='source-repo';paths=@('src/committed.txt')});cleanliness_policy='declared-dirty-paths'
        instruction_surfaces=@([pscustomobject][ordered]@{path='AGENTS.md';disposition='reviewed-no-change'});feature_lock=[pscustomobject][ordered]@{revision=1;sha256=$hash};effects=@('filesystem');permissions=@('workspace-write');device_use=@('none')
        test_matrix=@([pscustomobject][ordered]@{test_id='test-01';command='project supplied test'});cleanup_evidence=@('clean');source_composition=[pscustomobject][ordered]@{path='locks/source.json';sha256=$sourceLockHash};does_not_prove=@('Validation result')
    }
    $freezePath = Join-Path $workspace 'receipts/locked-freeze.json'
    [IO.File]::WriteAllText($freezePath,(($candidateFreeze|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
    $freezeHash = (Get-FileHash -LiteralPath $freezePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $lockedUnit = [pscustomobject][ordered]@{project_id='builder-project';unit_id='locked-unit';allowed_repositories=@([pscustomobject][ordered]@{repo_id='source-repo';allowed_paths=@('src')});source_composition=[pscustomobject][ordered]@{mode='exact-lock';lock_path='locks/source.json';materialization_receipt=$null};candidate_freeze=[pscustomobject][ordered]@{freeze_id='locked-freeze';receipt_path='receipts/locked-freeze.json';receipt_sha256=$freezeHash}}
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-units/locked-unit.json'),(($lockedUnit|ConvertTo-Json -Depth 20)+"`n"),[Text.UTF8Encoding]::new($false))
    $lockedBuilt = New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId locked-unit -RepoMapPath $lockedMapPath -Evidence $productEvidence -OutPath 'receipts/locked-builder.json' -CreatedAt '2026-09-08T00:00:00Z'
    Assert-ReceiptTest ([string]$lockedBuilt.repository_revisions[0].base_revision -ceq $lockedBase) 'v1 builder did not use the authenticated source-composition baseline'
    Add-Content -LiteralPath $sourceLockPath -Value ' ' -NoNewline
    $driftRejected = $false
    try { New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId locked-unit -RepoMapPath $lockedMapPath -Evidence $productEvidence -OutPath 'receipts/drifted-lock.json' | Out-Null } catch { $driftRejected = $_.Exception.Message -like '*source-composition lock does not match the candidate-freeze binding*' }
    Assert-ReceiptTest ($driftRejected -and -not (Test-Path -LiteralPath (Join-Path $workspace 'receipts/drifted-lock.json'))) 'v1 builder accepted source-lock byte drift after candidate freeze'

    $lockUnit = [pscustomobject][ordered]@{ project_id='builder-project'; unit_id='lock-unit'; allowed_repositories=@([pscustomobject][ordered]@{repo_id='source-repo';allowed_paths=@('src')}); source_composition=[pscustomobject][ordered]@{mode='exact-lock';lock_path='locks/source.json';materialization_receipt=$null} }
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-units/lock-unit.json'),(($lockUnit|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
    $unboundLockRejected = $false
    try { New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId lock-unit -RepoMapPath $repoMapPath -Evidence $productEvidence -OutPath 'receipts/unbound-lock.json' | Out-Null } catch { $unboundLockRejected = $_.Exception.Message -like '*requires the candidate-freeze binding*' }
    Assert-ReceiptTest ($unboundLockRejected -and -not (Test-Path -LiteralPath (Join-Path $workspace 'receipts/unbound-lock.json'))) 'v1 builder trusted an unauthenticated source-composition lock'

    $nonGitRepository = Join-Path $builderRoot 'non-git-source'
    [IO.Directory]::CreateDirectory((Join-Path $nonGitRepository 'src')) | Out-Null
    $nonGitUnit = [pscustomobject][ordered]@{ project_id='builder-project'; unit_id='non-git-unit'; allowed_repositories=@([pscustomobject][ordered]@{repo_id='non-git-repo';allowed_paths=@('src')}) }
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-units/non-git-unit.json'),(($nonGitUnit|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
    $nonGitMap = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([pscustomobject][ordered]@{repo_id='non-git-repo';path=$nonGitRepository;role='source'})}
    $nonGitMapPath = Join-Path $builderRoot 'non-git-map.json'
    [IO.File]::WriteAllText($nonGitMapPath,(($nonGitMap|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
    $nonGitRejected = $false
    try { New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId non-git-unit -RepoMapPath $nonGitMapPath -Evidence $productEvidence -OutPath 'receipts/non-git.json' | Out-Null } catch { $nonGitRejected = $_.Exception.Message -like '*non-Git surfaces require a specialized receipt*' }
    Assert-ReceiptTest ($nonGitRejected -and -not (Test-Path -LiteralPath (Join-Path $workspace 'receipts/non-git.json'))) 'v1 builder silently omitted a mapped non-Git repository'

    $noUpstreamRepository = Join-Path $builderRoot 'no-upstream-source'
    [IO.Directory]::CreateDirectory((Join-Path $noUpstreamRepository 'src')) | Out-Null
    & git -C $noUpstreamRepository init | Out-Null
    & git -C $noUpstreamRepository config user.email fixture@example.invalid
    & git -C $noUpstreamRepository config user.name Fixture
    [IO.File]::WriteAllText((Join-Path $noUpstreamRepository 'src/base.txt'),'base',[Text.UTF8Encoding]::new($false))
    & git -C $noUpstreamRepository add src/base.txt
    & git -C $noUpstreamRepository commit -m base | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No-upstream builder fixture initialization failed.' }
    $noUpstreamUnit = [pscustomobject][ordered]@{ project_id='builder-project'; unit_id='no-upstream-unit'; allowed_repositories=@([pscustomobject][ordered]@{repo_id='no-upstream-repo';allowed_paths=@('src')}) }
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-units/no-upstream-unit.json'),(($noUpstreamUnit|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
    $noUpstreamMap = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([pscustomobject][ordered]@{repo_id='no-upstream-repo';path=$noUpstreamRepository;role='source'})}
    $noUpstreamMapPath = Join-Path $builderRoot 'no-upstream-map.json'
    [IO.File]::WriteAllText($noUpstreamMapPath,(($noUpstreamMap|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
    $noUpstreamRejected = $false
    try { New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId no-upstream-unit -RepoMapPath $noUpstreamMapPath -Evidence $productEvidence -OutPath 'receipts/no-upstream.json' | Out-Null } catch { $noUpstreamRejected = $_.Exception.Message -like '*authenticated source-composition baseline or configured Git upstream*' }
    Assert-ReceiptTest ($noUpstreamRejected -and -not (Test-Path -LiteralPath (Join-Path $workspace 'receipts/no-upstream.json'))) 'v1 builder silently treated HEAD as the baseline without source authority'
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $candidate = [IO.Path]::GetFullPath($builderRoot).TrimEnd('\','/')
    if ([IO.Path]::GetDirectoryName($candidate).TrimEnd('\','/').Equals($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($candidate).StartsWith('validation-receipt-builder-',[StringComparison]::Ordinal)) {
        if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force }
    }
}

'Validation receipt structural self-test passed.'
