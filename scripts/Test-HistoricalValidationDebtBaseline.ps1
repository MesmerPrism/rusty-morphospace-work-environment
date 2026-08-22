param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceHistoricalValidationDebtBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/ExternalOwnerAuthorization.psm1') -Force

function Assert-HistoricalDebt {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Historical validation-debt self-test failed: $Message" }
}

function Assert-HistoricalDebtRejected {
    param([scriptblock]$Action,[string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-HistoricalDebt $rejected $Message
}

function Copy-HistoricalDebtValue {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String)
}

function Write-HistoricalDebtJson {
    param([string]$Path,[object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (ConvertTo-MorphospaceCanonicalJson -Value $Value) + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-HistoricalDebtLockFingerprint {
    param([object]$Lock)
    $copy = Copy-HistoricalDebtValue $Lock
    $copy.lock_fingerprint = '0' * 64
    return Get-MorphospaceCanonicalJsonSha256 -Value $copy
}

function Get-HistoricalDebtWorkflowCapture {
    param([string]$Workspace,[string]$MapPath,[switch]$FullAggregate)
    $hostPath = [Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($hostPath) -or -not [IO.File]::Exists($hostPath)) { $hostPath = (Get-Command pwsh -ErrorAction Stop).Source }
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('-RepoRoot',$repoRoot,'-WorkspaceRoot',$Workspace,'-RepositoryMapPath',$MapPath)) { $arguments.Add($argument) | Out-Null }
    if (-not $FullAggregate) { $arguments.Add('-SkipOwnerSelfTests') | Out-Null }
    $arguments.Add('-EmitHistoricalValidationDebtCapture') | Out-Null
    $output = @(& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts/Test-WorkflowContracts.ps1') @($arguments.ToArray()) 2>&1)
    $exitCode = $LASTEXITCODE
    $lines = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith('historical_validation_debt_capture_base64=', [StringComparison]::Ordinal) })
    if ($lines.Count -ne 1) { throw 'Cold workflow aggregate did not emit exactly one capture record.' }
    $capture = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Convert]::FromBase64String($lines[0].Substring('historical_validation_debt_capture_base64='.Length))) -Context 'historical-debt cold aggregate capture'
    return [pscustomobject]@{ exit_code=$exitCode; capture=$capture; output=@($output) }
}

function New-HistoricalDebtTestPolicy {
    param([string]$Root,[Security.Cryptography.RSA]$Rsa)
    $pem = $Rsa.ExportSubjectPublicKeyInfoPem().Replace("`r",'')
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    $sourceSchema = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'schemas/external-owner-authorization-policy-v1.schema.json')
    $schema = $sourceSchema.Replace('mesmerprism-owner-policy-authority-v1','synthetic-owner-authority-v1').Replace('MesmerPrism','SyntheticOwner').Replace('rusty-morphospace-external-owner-authorization:v1','synthetic-external-owner:v1').Replace('e6ceb8c9bb2d3c178b28f15b9cd47ff1229e13584cd9c3b7dec1c2cda2f476e6',$fingerprint)
    $schemaPath = Join-Path $Root 'policy.schema.json'
    $policyPath = Join-Path $Root 'policy.json'
    [IO.File]::WriteAllText($schemaPath, $schema, [Text.UTF8Encoding]::new($false))
    $policy = [ordered]@{
        schema='rusty.morphospace.workflow.external_owner_authorization_policy.v1'
        issuer_id='synthetic-owner-authority-v1';owner_login='SyntheticOwner';comment_marker='synthetic-external-owner:v1'
        max_authorization_age_seconds=86400;max_future_skew_seconds=300;maximum_comments=100;maximum_response_bytes=1048576;maximum_comment_bytes=65536
        public_key_spki_sha256=$fingerprint;public_key_pem=$pem
    }
    Write-HistoricalDebtJson $policyPath $policy
    return [pscustomobject]@{path=$policyPath;schema=$schemaPath;fingerprint=$fingerprint;document=$policy}
}

function Write-HistoricalDebtAuthorization {
    param(
        [string]$Workspace,[Security.Cryptography.RSA]$Rsa,[object]$Policy,
        [datetimeoffset]$Now,[scriptblock]$PayloadMutation = $null,
        [string]$BaselineId = 'synthetic-debt-0001',
        [string]$AuthorizationId = 'synthetic-authorization-0001',
        [string]$AuditId = 'synthetic-audit-0001'
    )
    $baselinePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath "receipts/historical-validation-debt/$BaselineId/baseline.json" -RequireLeaf
    $baselineBytes = [IO.File]::ReadAllBytes($baselinePath)
    $baseline = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineBytes -Context 'synthetic historical-debt baseline'
    $payload = New-MorphospaceHistoricalValidationDebtAuthorizationPayload `
        -Baseline $baseline -BaselineSha256 (Get-MorphospaceSha256Bytes -Bytes $baselineBytes) `
        -AuthorizationId $AuthorizationId -AuditId $AuditId `
        -IssuedAt $Now.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") `
        -ExpiresAt $Now.AddHours(1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") `
        -IssuerId ([string]$Policy.document.issuer_id)
    if ($null -ne $PayloadMutation) { & $PayloadMutation $payload }
    [byte[]]$canonical = Get-CanonicalAuthorizationBytes -Payload $payload
    [byte[]]$signature = $Rsa.SignData($canonical,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
    $document = [ordered]@{
        schema='rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1'
        payload=$payload
        signature=[ordered]@{algorithm='RSA-PSS-SHA256';public_key_spki_sha256=[string]$Policy.fingerprint;value_base64=[Convert]::ToBase64String($signature)}
    }
    Write-HistoricalDebtJson (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath "receipts/historical-validation-debt/$BaselineId/authorization.json") $document
}

function New-HistoricalDebtPeerBaseline {
    param([string]$Workspace,[string]$BaselineId)
    $sourcePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath 'receipts/historical-validation-debt/synthetic-debt-0001/baseline.json' -RequireLeaf
    $peer = Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([IO.File]::ReadAllBytes($sourcePath)) -Context 'synthetic source baseline')
    $peer.baseline_id = $BaselineId
    $peer.authorization.path = "receipts/historical-validation-debt/$BaselineId/authorization.json"
    Write-HistoricalDebtJson (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath "receipts/historical-validation-debt/$BaselineId/baseline.json") $peer
}

function Invoke-HistoricalDebtBaselineVerifier {
    param([string]$Workspace,[string]$MapPath,[object[]]$Records,[object]$Policy,[datetimeoffset]$Now)
    return Test-MorphospaceHistoricalValidationDebtBaseline `
        -WorkspaceRoot $Workspace -RepoRoot $repoRoot -RepositoryMapPath $MapPath `
        -BaselinePath 'receipts/historical-validation-debt/synthetic-debt-0001/baseline.json' `
        -FailureRecords $Records -PolicyPath $Policy.path -PolicySchemaPath $Policy.schema -Now $Now
}

function New-HistoricalDebtUnit {
    param([string]$UnitId,[string]$Status,[bool]$Historical)
    $skills = if ($Historical) {
        @(
            [ordered]@{surface_kind='skill';path='<skills-root>/rusty-morphospace/SKILL.md';owner='workflow-maintainer';change_reason='Historical instruction record.';action='update';status='complete';validation='Historical fixture.';skill_id='rusty-morphospace'},
            [ordered]@{surface_kind='skill';path='<skills-root>/system-engineering/SKILL.md';owner='workflow-maintainer';change_reason='Historical instruction record.';action='update';status='complete';validation='Historical fixture.';skill_id='system-engineering'}
        )
    } else {
        @(
            [ordered]@{surface_kind='skill';path='<skills-root>/rusty-morphospace/SKILL.md';owner='workflow-maintainer';change_reason='Exact lifecycle-routed skill review.';action='review-no-change';status='complete';validation='Synthetic completed review.';skill_id='rusty-morphospace'},
            [ordered]@{surface_kind='skill';path='<skills-root>/system-engineering/SKILL.md';owner='workflow-maintainer';change_reason='Exact lifecycle-routed skill review.';action='review-no-change';status='complete';validation='Synthetic completed review.';skill_id='system-engineering'}
        )
    }
    return [ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id=$UnitId;project_id='synthetic-debt-project';status=$Status
        objective=if($Historical){'Retained terminal historical fixture.'}else{'Corrected active feature fixture with exact routed reviews.'}
        architecture_decision=[ordered]@{selected='Retain the bounded synthetic feature contract.';material_advance='Demonstrate current feature validation without changing historical debt.';deferred='Source, device, and remote operations remain outside this fixture.';deferred_reason='This public fixture validates only workflow contracts.'}
        work_mode='feature';guard_profile='locked';change_categories=@('implementation','authority','validation','public-private-boundary')
        instruction_impact='update'
        instruction_surfaces=@(
            [ordered]@{surface_kind='agents';path='<repo-root>/AGENTS.md';owner='workflow-owner';change_reason='Required instruction entrypoint.';action='update';status='complete';validation='Synthetic fixture.';skill_id=$null},
            [ordered]@{surface_kind='readme';path='<repo-root>/README.md';owner='workflow-owner';change_reason='Required instruction router.';action='update';status='complete';validation='Synthetic fixture.';skill_id=$null}
        ) + $skills
        instruction_none_justification=$null;prerequisites=@();allowed_repositories=@([ordered]@{repo_id='project-shell';allowed_paths=@('src/','morphospace/')})
        non_scope=@('Private projects.','Devices.','Remote operations.');acceptance=@([ordered]@{acceptance_id='synthetic-contract';proof='The synthetic workflow contract validates.';command='synthetic-acceptance'})
        risk_tier='quick';device_requirement='forbidden';validation=@([ordered]@{profile_id='quick';command='synthetic-validation'})
        outputs=@('Synthetic contract evidence.');commit_policy='No source commit is made by this synthetic fixture.';push_checkpoint='none'
    }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('historical-validation-debt-' + [guid]::NewGuid().ToString('N'))
$rsa = [Security.Cryptography.RSA]::Create(3072)
try {
    $workspace = Join-Path $temp 'workspace'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'module-candidates')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'promotion-reviews')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null
    $ownerRoot = Join-Path $temp 'owner'; [IO.Directory]::CreateDirectory($ownerRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $ownerRoot 'AGENTS.md'),'# Synthetic agent surface' + "`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $ownerRoot 'README.md'),'# Synthetic router surface' + "`n",[Text.UTF8Encoding]::new($false))

    $project = [ordered]@{
        schema='rusty.morphospace.workflow.project_spec.v2';project_id='synthetic-debt-project';revision=1;owner='workflow-owner';purpose='Public synthetic fixture for immutable historical validation debt.'
        activation_model=[ordered]@{default='disabled';unlisted_modules='inert';runtime_rule='selected-lock-and-runtime-input'}
        composition=[ordered]@{selected_features=@();denied_features=@();selected_modules=@();denied_modules=@();allowed_permissions=@();denied_permissions=@();data_classes=@()}
        authority_map=@([ordered]@{parameter='project.composition';owner='workflow-owner';adapters=@()})
        repositories=@([ordered]@{repo_id='project-shell';role='application';path='<repo-root>';allowed_paths=@('src/','morphospace/')})
        modules=@();non_scope=@('Private data.','Devices.','Remote operations.');validation_profiles=@([ordered]@{profile_id='quick';commands=@('synthetic-validation')})
        acceptance_profiles=@([ordered]@{profile_id='quick';commands=@('synthetic-acceptance')})
        release_policy=[ordered]@{versioning='fixture';commit_policy='Fixture only.';push_checkpoint='none';source_first=$true;planning_last=$true;force_push_allowed=$false}
        public_boundary=[ordered]@{mode='public';private_overlay='local/';prohibited_evidence=@('private data')}
    }
    $effects=[ordered]@{permissions=@();services=@();activities=@();queries=@();tools=@();assets=@();shaders=@();native_libraries=@();commands=@();routes=@();streams=@();inputs=@();scenes=@();markers=@()}
    $lock=[ordered]@{schema='rusty.morphospace.workflow.feature_lock.v2';project_id='synthetic-debt-project';project_revision=1;revision=1;generated_at='2026-08-21T00:00:00Z';resolver_version='synthetic-resolver/2';lock_fingerprint='0'*64;default_activation='disabled';activation_rule='selected-lock-and-runtime-input';selected_features=@();denied_features=@();features=@();effect_union=$effects}
    $lock.lock_fingerprint=Get-HistoricalDebtLockFingerprint $lock
    $historical=New-HistoricalDebtUnit -UnitId 'legacy-terminal' -Status 'accepted' -Historical $true
    $historical.commit_policy=''
    $historicalTwo=New-HistoricalDebtUnit -UnitId 'legacy-terminal-two' -Status 'accepted' -Historical $true
    $historicalTwo.commit_policy=''
    $current=New-HistoricalDebtUnit -UnitId 'current-feature' -Status 'active' -Historical $false
    $state=[ordered]@{schema='rusty.morphospace.workflow.workspace_state.v2';project_id='synthetic-debt-project';plan_revision=1;current_unit='current-feature';next_ready_unit=$null;last_event_id='current-feature-claimed-0003';last_accepted_receipt='receipts/legacy-terminal-validation.json';repository_heads=@();repository_checkpoints=@();module_registry=[ordered]@{lock_revision=1;lock_fingerprint=$lock.lock_fingerprint;modules=@()};capability_registry=@();dirty_repositories=@();blockers=@();validation_checkpoint=$null;pending_push_bundle=$null}
    $events=@(
        [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='legacy-terminal-accepted-0001';sequence=1;timestamp='2026-08-21T00:00:00Z';project_id='synthetic-debt-project';unit_id='legacy-terminal';event_type='state-transition';summary='Accepted the retained historical fixture.';receipts=@()},
        [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='legacy-terminal-two-accepted-0002';sequence=2;timestamp='2026-08-21T00:01:00Z';project_id='synthetic-debt-project';unit_id='legacy-terminal-two';event_type='state-transition';summary='Accepted the second retained historical fixture.';receipts=@()},
        [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='current-feature-claimed-0003';sequence=3;timestamp='2026-08-21T00:02:00Z';project_id='synthetic-debt-project';unit_id='current-feature';event_type='state-transition';summary='Claimed the corrected current feature fixture.';receipts=@()}
    )
    Write-HistoricalDebtJson (Join-Path $workspace 'project.spec.json') $project
    Write-HistoricalDebtJson (Join-Path $workspace 'feature.lock.json') $lock
    Write-HistoricalDebtJson (Join-Path $workspace 'workspace.state.json') $state
    Write-HistoricalDebtJson (Join-Path $workspace 'iteration-units/legacy-terminal.json') $historical
    Write-HistoricalDebtJson (Join-Path $workspace 'iteration-units/legacy-terminal-two.json') $historicalTwo
    Write-HistoricalDebtJson (Join-Path $workspace 'iteration-units/current-feature.json') $current
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'), (($events | ForEach-Object { ConvertTo-MorphospaceCanonicalJson $_ }) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $map=[ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='project-shell';path=$ownerRoot;role='planning';aliases=@('repo-root')})}
    $mapPath=Join-Path $temp 'repository-map.json'; Write-HistoricalDebtJson $mapPath $map

    $cold = Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath -FullAggregate
    Assert-HistoricalDebt ($cold.exit_code -ne 0) 'Normal full cold-process aggregate passed without an authorized baseline.'
    Assert-HistoricalDebt (@($cold.capture.failure_records).Count -eq 2 -and @($cold.capture.failure_records | Where-Object { [string]$_.failure_code -ceq 'historical-unit-contract' }).Count -eq 2) 'Synthetic aggregate did not isolate exactly two terminal historical-unit failures.'

    & (Join-Path $PSScriptRoot 'New-HistoricalValidationDebtBaseline.ps1') -WorkspaceRoot $workspace -RepositoryMapPath $mapPath -RepoRoot $repoRoot -BaselineId 'synthetic-debt-0001' -Execute | Out-Null
    $baselineRelative='receipts/historical-validation-debt/synthetic-debt-0001/baseline.json'
    Assert-HistoricalDebt ([IO.File]::Exists((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative -RequireLeaf))) 'Baseline action did not install its exact immutable request.'
    $policy=New-HistoricalDebtTestPolicy -Root $temp -Rsa $rsa
    $now=[datetimeoffset]::UtcNow
    Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    $result=Invoke-HistoricalDebtBaselineVerifier -Workspace $workspace -MapPath $mapPath -Records @($cold.capture.failure_records) -Policy $policy -Now $now
    Assert-HistoricalDebt ([string]$result.status -ceq 'debt-bearing-success' -and [string]$result.current_validation -ceq 'passed' -and $result.historical_debt_present -eq $true -and [int]$result.historical_debt.count -eq 2) 'Exact baseline did not produce an explicit debt-bearing current-validation success.'
    Assert-HistoricalDebt ((ConvertTo-MorphospaceCanonicalJson $result | Test-Json -SchemaFile (Join-Path $repoRoot 'schemas/historical-validation-debt-result-v1.schema.json'))) 'Debt-bearing result failed its closed schema.'
    $resultRelative = "receipts/historical-validation-debt/synthetic-debt-0001/results/$([string]$result.current_unit.raw_sha256).json"
    Write-HistoricalDebtJson (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $resultRelative) $result
    $debtBinding = [pscustomobject][ordered]@{
        baseline = [pscustomobject][ordered]@{role='historical-validation-debt-baseline';path=$baselineRelative;schema='rusty.morphospace.workflow.historical_validation_debt_baseline.v1';sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative -RequireLeaf)}
        authorization = [pscustomobject][ordered]@{role='historical-validation-debt-authorization';path='receipts/historical-validation-debt/synthetic-debt-0001/authorization.json';schema='rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1';sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'receipts/historical-validation-debt/synthetic-debt-0001/authorization.json' -RequireLeaf)}
        result = [pscustomobject][ordered]@{role='historical-validation-debt-result';path=$resultRelative;schema='rusty.morphospace.workflow.historical_validation_debt_result.v1';sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $resultRelative -RequireLeaf)}
    }
    $boundResult = Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $debtBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now
    Assert-HistoricalDebt ([string]$boundResult.status -ceq 'debt-bearing-success') 'Receipt binding did not revalidate the signed debt-bearing result.'
    New-HistoricalDebtPeerBaseline -Workspace $workspace -BaselineId 'synthetic-debt-0002';Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now -BaselineId 'synthetic-debt-0002' -AuthorizationId 'synthetic-authorization-0001' -AuditId 'synthetic-audit-0002'
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A repeated authorization ID in another signed canonical baseline sibling was accepted.'
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $debtBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'Receipt binding accepted a repeated authorization ID in another signed canonical baseline sibling.'
    [IO.Directory]::Delete((Join-Path $workspace 'receipts/historical-validation-debt/synthetic-debt-0002'), $true)
    New-HistoricalDebtPeerBaseline -Workspace $workspace -BaselineId 'synthetic-debt-0003';Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now -BaselineId 'synthetic-debt-0003' -AuthorizationId 'synthetic-authorization-0003' -AuditId 'synthetic-audit-0001'
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A repeated audit ID in another signed canonical baseline sibling was accepted.'
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $debtBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'Receipt binding accepted a repeated audit ID in another signed canonical baseline sibling.'
    [IO.Directory]::Delete((Join-Path $workspace 'receipts/historical-validation-debt/synthetic-debt-0003'), $true)
    $movedBaselineRelative = 'receipts/historical-validation-debt/relocated-debt-0001/baseline.json';$movedBaselinePath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $movedBaselineRelative;$null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($movedBaselinePath)) -Force;[IO.File]::WriteAllBytes($movedBaselinePath,[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative -RequireLeaf)));$movedBaselineBinding=Copy-HistoricalDebtValue $debtBinding;$movedBaselineBinding.baseline.path=$movedBaselineRelative
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $movedBaselineBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A valid baseline copied outside its canonical baseline directory was accepted.'
    $movedResultRelative = "receipts/historical-validation-debt/relocated-debt-0001/results/$([string]$result.current_unit.raw_sha256).json";$movedResultPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $movedResultRelative;$null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($movedResultPath)) -Force;[IO.File]::WriteAllBytes($movedResultPath,[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $resultRelative -RequireLeaf)));$movedResultBinding=Copy-HistoricalDebtValue $debtBinding;$movedResultBinding.result.path=$movedResultRelative
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $movedResultBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A valid result relocated outside its baseline/current-unit path was accepted.'
    [IO.Directory]::Delete((Join-Path $workspace 'receipts/historical-validation-debt/relocated-debt-0001'), $true)
    $resultPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $resultRelative -RequireLeaf;$resultOriginal=[IO.File]::ReadAllBytes($resultPath);$validatorDriftResult=Copy-HistoricalDebtValue $result;$validatorDriftResult.validator_identity_sha256='0'*64;Write-HistoricalDebtJson $resultPath $validatorDriftResult;$validatorDriftBinding=Copy-HistoricalDebtValue $debtBinding;$validatorDriftBinding.result.sha256=Get-MorphospaceFileSha256 $resultPath
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $validatorDriftBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A result with a validator identity differing from its baseline was accepted.'
    [IO.File]::WriteAllBytes($resultPath,$resultOriginal)
    $baselineReceiptPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative -RequireLeaf;$baselineReceiptOriginal=[IO.File]::ReadAllBytes($baselineReceiptPath);$authorizationReceiptPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'receipts/historical-validation-debt/synthetic-debt-0001/authorization.json' -RequireLeaf;$authorizationReceiptOriginal=[IO.File]::ReadAllBytes($authorizationReceiptPath)
    $liveValidatorDriftBaseline=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineReceiptOriginal -Context 'synthetic baseline');$liveValidatorDriftBaseline.validator.identity_sha256='0'*64;Write-HistoricalDebtJson $baselineReceiptPath $liveValidatorDriftBaseline;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    $liveValidatorDriftResult=Copy-HistoricalDebtValue $result;$liveValidatorDriftResult.baseline.sha256=Get-MorphospaceFileSha256 $baselineReceiptPath;$liveValidatorDriftResult.authorization.sha256=Get-MorphospaceFileSha256 $authorizationReceiptPath;$liveValidatorDriftResult.validator_identity_sha256='0'*64;Write-HistoricalDebtJson $resultPath $liveValidatorDriftResult;$liveValidatorDriftBinding=Copy-HistoricalDebtValue $debtBinding;$liveValidatorDriftBinding.baseline.sha256=Get-MorphospaceFileSha256 $baselineReceiptPath;$liveValidatorDriftBinding.authorization.sha256=Get-MorphospaceFileSha256 $authorizationReceiptPath;$liveValidatorDriftBinding.result.sha256=Get-MorphospaceFileSha256 $resultPath
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $liveValidatorDriftBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A signed result from a validator identity drifting from the live Work Environment validator was accepted.'
    [IO.File]::WriteAllBytes($baselineReceiptPath,$baselineReceiptOriginal);[IO.File]::WriteAllBytes($authorizationReceiptPath,$authorizationReceiptOriginal);[IO.File]::WriteAllBytes($resultPath,$resultOriginal)
    $requiredBinding = Get-MorphospaceHistoricalValidationDebtReceiptRequirement -WorkspaceRoot $workspace -CurrentUnit $current -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now
    Assert-HistoricalDebt ((Get-MorphospaceCanonicalJsonSha256 -Value $requiredBinding) -ceq (Get-MorphospaceCanonicalJsonSha256 -Value $debtBinding)) 'The content-addressed ratchet result did not require its exact validation-receipt binding.'
    Assert-HistoricalDebtRejected { Assert-MorphospaceHistoricalValidationDebtReceiptRequirement -WorkspaceRoot $workspace -CurrentUnit $current -Receipt ([pscustomobject]@{}) -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A debt-bearing result allowed a validation receipt with no historical-debt binding.'
    $matchingReceipt = [pscustomobject]@{ historical_validation_debt=$debtBinding }
    $null = Assert-MorphospaceHistoricalValidationDebtReceiptRequirement -WorkspaceRoot $workspace -CurrentUnit $current -Receipt $matchingReceipt -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now
    $mismatchedReceipt = [pscustomobject]@{ historical_validation_debt=(Copy-HistoricalDebtValue $debtBinding) };$mismatchedReceipt.historical_validation_debt.result.sha256='0'*64
    Assert-HistoricalDebtRejected { Assert-MorphospaceHistoricalValidationDebtReceiptRequirement -WorkspaceRoot $workspace -CurrentUnit $current -Receipt $mismatchedReceipt -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A mismatched debt-bearing validation-receipt binding was accepted.'

    $records=@($cold.capture.failure_records)
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($records[1],$records[0]) $policy $now } 'A reversed canonical historical failure set was accepted.'
    $extra=Copy-HistoricalDebtValue $records[0];$extra.message_sha256='1'*64;$extra.evidence_sha256='2'*64;$extra.record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$extra.failure_code;locus=$extra.locus;message_sha256=[string]$extra.message_sha256;evidence_sha256=[string]$extra.evidence_sha256})
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($records + $extra) $policy $now } 'A new post-anchor failure was accepted.'
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @() $policy $now } 'A removed historical failure was accepted.'
    $altered=Copy-HistoricalDebtValue $records[0];$altered.message_sha256='3'*64;$altered.record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$altered.failure_code;locus=$altered.locus;message_sha256=[string]$altered.message_sha256;evidence_sha256=[string]$altered.evidence_sha256})
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($altered) $policy $now } 'An altered normalized message/evidence record was accepted.'
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($records + $records[0]) $policy $now } 'A duplicate historical failure record was accepted.'

    $baselinePath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative;$baselineOriginal=[IO.File]::ReadAllBytes($baselinePath)
    $baselineDocument=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline'
    $validatorPaths = @($baselineDocument.validator.files | ForEach-Object { [string]$_.path })
    foreach ($requiredValidatorPath in @('scripts/New-HistoricalValidationDebtBaseline.ps1','scripts/Test-WorkflowContracts.ps1','scripts/Test-ExecutedPushReceipt.ps1','scripts/Test-ReleaseCapsule.ps1','scripts/WorkUnitAutomation.psm1','scripts/lib/MorphospaceActiveUnitContractReviewCompatibility.psm1','scripts/lib/MorphospaceBlockedSupersessionTerminalValidation.psm1','scripts/lib/MorphospaceCompletedTransitionSemanticCorrection.psm1','scripts/lib/MorphospaceHistoricalBlockerResolutionIntentBindingCorrection.psm1','scripts/lib/MorphospaceHistoricalUnitCompatibilityProjection.psm1','config/external-owner-authorization.json','schemas/external-owner-authorization-policy-v1.schema.json','manifests/workflow-lifecycle.portable.json','templates/iteration-events.example.jsonl','templates/iteration-events.v2.example.jsonl')) {
        Assert-HistoricalDebt ($validatorPaths -ccontains $requiredValidatorPath) "Validator identity omitted executed dependency '$requiredValidatorPath'."
    }

    $historicalPath=Join-Path $workspace 'iteration-units/legacy-terminal.json';$historicalOriginal=[IO.File]::ReadAllBytes($historicalPath);$nonTerminalHistorical=Copy-HistoricalDebtValue $historical;$nonTerminalHistorical.status='active';Write-HistoricalDebtJson $historicalPath $nonTerminalHistorical
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline covered a non-terminal historical-unit locus.'
    [IO.File]::WriteAllBytes($historicalPath,$historicalOriginal)

    $missingLocus=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$missingLocus.failure_records[0].locus.unit_id='missing-terminal';$missingLocus.failure_records[0].locus.path='iteration-units/missing-terminal.json';$missingLocus.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$missingLocus.failure_records[0].failure_code;locus=$missingLocus.failure_records[0].locus;message_sha256=[string]$missingLocus.failure_records[0].message_sha256;evidence_sha256=[string]$missingLocus.failure_records[0].evidence_sha256});$missingLocus.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($missingLocus.failure_records);Write-HistoricalDebtJson $baselinePath $missingLocus;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($missingLocus.failure_records) $policy $now } 'A baseline covered a nonexistent historical-unit locus.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $unitHashMismatch=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$unitHashMismatch.failure_records[0].locus.raw_sha256='0'*64;$unitHashMismatch.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$unitHashMismatch.failure_records[0].failure_code;locus=$unitHashMismatch.failure_records[0].locus;message_sha256=[string]$unitHashMismatch.failure_records[0].message_sha256;evidence_sha256=[string]$unitHashMismatch.failure_records[0].evidence_sha256});$unitHashMismatch.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($unitHashMismatch.failure_records);Write-HistoricalDebtJson $baselinePath $unitHashMismatch;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($unitHashMismatch.failure_records) $policy $now } 'A baseline covered a historical-unit locus with a mismatched raw hash.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $stateLocusMismatch=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$stateLocusMismatch.failure_records[0].failure_code='legacy-workspace-state-contract';$stateLocusMismatch.failure_records[0].locus=[ordered]@{kind='legacy-workspace-state';path='workspace.state.json';raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'workspace.state.json' -RequireLeaf);canonical_sha256='0'*64};$stateLocusMismatch.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$stateLocusMismatch.failure_records[0].failure_code;locus=$stateLocusMismatch.failure_records[0].locus;message_sha256=[string]$stateLocusMismatch.failure_records[0].message_sha256;evidence_sha256=[string]$stateLocusMismatch.failure_records[0].evidence_sha256});$stateLocusMismatch.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($stateLocusMismatch.failure_records);Write-HistoricalDebtJson $baselinePath $stateLocusMismatch;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($stateLocusMismatch.failure_records) $policy $now } 'A baseline covered legacy workspace-state debt with a canonical hash not frozen by its workspace anchor.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $manifestDrift=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$manifestDrift.validator.files=@($manifestDrift.validator.files|Where-Object{[string]$_.path-cne'scripts/lib/MorphospaceActiveUnitContractReviewCompatibility.psm1'});$manifestCore=[ordered]@{environment_commit=[string]$manifestDrift.validator.environment_commit;environment_tree=[string]$manifestDrift.validator.environment_tree;files=$manifestDrift.validator.files};$manifestDrift.validator.identity_sha256=Get-MorphospaceCanonicalJsonSha256 $manifestCore;Write-HistoricalDebtJson $baselinePath $manifestDrift;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline with an omitted aggregate module digest was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $directScriptDrift=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$directScriptDrift.validator.files=@($directScriptDrift.validator.files|Where-Object{[string]$_.path-cne'scripts/Test-ReleaseCapsule.ps1'});$directScriptCore=[ordered]@{environment_commit=[string]$directScriptDrift.validator.environment_commit;environment_tree=[string]$directScriptDrift.validator.environment_tree;files=$directScriptDrift.validator.files};$directScriptDrift.validator.identity_sha256=Get-MorphospaceCanonicalJsonSha256 $directScriptCore;Write-HistoricalDebtJson $baselinePath $directScriptDrift;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline with an omitted direct aggregate script digest was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $templateDrift=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$templateDrift.validator.files=@($templateDrift.validator.files|Where-Object{[string]$_.path-cne'templates/iteration-events.example.jsonl'});$templateCore=[ordered]@{environment_commit=[string]$templateDrift.validator.environment_commit;environment_tree=[string]$templateDrift.validator.environment_tree;files=$templateDrift.validator.files};$templateDrift.validator.identity_sha256=Get-MorphospaceCanonicalJsonSha256 $templateCore;Write-HistoricalDebtJson $baselinePath $templateDrift;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline with an omitted JSONL aggregate template digest was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $currentPath=Join-Path $workspace 'iteration-units/current-feature.json';$currentOriginal=[IO.File]::ReadAllBytes($currentPath)
    $writableReview=Copy-HistoricalDebtValue $current;$writableReview.allowed_repositories[0].allowed_paths+= '<skills-root>';Write-HistoricalDebtJson $currentPath $writableReview
    $writableCapture=Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath
    Assert-HistoricalDebt ($writableCapture.exit_code -ne 0 -and @($writableCapture.capture.failure_records|Where-Object{[string]$_.failure_code -ceq 'current-unit-contract'}).Count -gt 0) 'A writable current instruction-surface path was classified as historical debt.'
    [IO.File]::WriteAllBytes($currentPath,$currentOriginal)
    $extraSkill=Copy-HistoricalDebtValue $current;$extraSkill.instruction_surfaces+=,[ordered]@{surface_kind='skill';path='<skills-root>/rust-work-graph/SKILL.md';owner='workflow-maintainer';change_reason='Injected non-required review.';action='review-no-change';status='complete';validation='Synthetic damaged fixture.';skill_id='rust-work-graph'};Write-HistoricalDebtJson $currentPath $extraSkill
    $extraSkillCapture=Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath
    Assert-HistoricalDebt ($extraSkillCapture.exit_code -ne 0 -and @($extraSkillCapture.capture.failure_records|Where-Object{[string]$_.failure_code -ceq 'current-unit-contract'}).Count -gt 0) 'A non-required current skill surface was classified as historical debt.'
    [IO.File]::WriteAllBytes($currentPath,$currentOriginal)

    $historicalTwoPath=Join-Path $workspace 'iteration-units/legacy-terminal-two.json';$historicalTwoOriginal=[IO.File]::ReadAllBytes($historicalTwoPath);$validHistoricalTwo=Copy-HistoricalDebtValue $historicalTwo;$validHistoricalTwo.commit_policy='No source commit is made by this synthetic fixture.';Write-HistoricalDebtJson $historicalTwoPath $validHistoricalTwo
    $unknownHistorical=Copy-HistoricalDebtValue $historical;$unknownHistorical.commit_policy='No source commit is made by this synthetic fixture.';$unknownHistorical.change_categories+= 'unknown-legacy-category';Write-HistoricalDebtJson $historicalPath $unknownHistorical
    $unknownHistoricalCapture=Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath
    Assert-HistoricalDebt ($unknownHistoricalCapture.exit_code -ne 0 -and @($unknownHistoricalCapture.capture.failure_records|Where-Object{[string]$_.failure_code -ceq 'historical-unit-contract'}).Count -eq 0 -and @($unknownHistoricalCapture.capture.failure_records|Where-Object{[string]$_.failure_code -ceq 'unclassified-contract'}).Count -gt 0) 'An unknown historical change category was classified as baseline-eligible debt.'
    Assert-HistoricalDebtRejected { & (Join-Path $PSScriptRoot 'New-HistoricalValidationDebtBaseline.ps1') -WorkspaceRoot $workspace -RepositoryMapPath $mapPath -RepoRoot $repoRoot -BaselineId 'synthetic-debt-unknown-category' -Execute } 'An unknown historical change category was allowed to produce a baseline.'
    [IO.File]::WriteAllBytes($historicalPath,$historicalOriginal);[IO.File]::WriteAllBytes($historicalTwoPath,$historicalTwoOriginal)

    $currentDrift=Copy-HistoricalDebtValue $current;$currentDrift.objective='Rewritten current feature fixture after baseline capture.';Write-HistoricalDebtJson $currentPath $currentDrift
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A current-unit rewrite after baseline capture was accepted.'
    [IO.File]::WriteAllBytes($currentPath,$currentOriginal)
    $noCurrentStatePath=Join-Path $workspace 'workspace.state.json';$noCurrentStateOriginal=[IO.File]::ReadAllBytes($noCurrentStatePath);$noCurrentState=Copy-HistoricalDebtValue $state;$noCurrentState.current_unit=$null;Write-HistoricalDebtJson $noCurrentStatePath $noCurrentState
    Assert-HistoricalDebtRejected { New-MorphospaceHistoricalValidationDebtBaseline -WorkspaceRoot $workspace -RepoRoot $repoRoot -RepositoryMapPath $mapPath -BaselineId 'synthetic-debt-no-current' -FailureRecords $records } 'A baseline was emitted without an exact current active/validating unit.'
    [IO.File]::WriteAllBytes($noCurrentStatePath,$noCurrentStateOriginal)

    $ledgerPath=Join-Path $workspace 'iteration-events.jsonl';$ledgerOriginal=[IO.File]::ReadAllBytes($ledgerPath);$postAnchor=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='current-feature-invalid-0003';sequence=3;timestamp='2026-08-21T00:02:00Z';project_id='wrong-project';unit_id='current-feature';event_type='state-transition';summary='Damaged post-anchor transition.';receipts=@()};[IO.File]::AppendAllText($ledgerPath,(ConvertTo-MorphospaceCanonicalJson $postAnchor)+"`n",[Text.UTF8Encoding]::new($false))
    $postAnchorCapture=Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($postAnchorCapture.capture.failure_records) $policy $now } 'A damaged post-baseline transition was accepted as historical debt.'
    [IO.File]::WriteAllBytes($ledgerPath,$ledgerOriginal)

    [IO.File]::WriteAllText($ledgerPath,'not-a-ledger'+"`n",[Text.UTF8Encoding]::new($false))
    Assert-HistoricalDebtRejected { & (Join-Path $PSScriptRoot 'New-HistoricalValidationDebtBaseline.ps1') -WorkspaceRoot $workspace -RepositoryMapPath $mapPath -RepoRoot $repoRoot -BaselineId 'synthetic-debt-0002' -Execute } 'A validator transport/capture failure was allowed to generate a baseline.'
    [IO.File]::WriteAllBytes($ledgerPath,$ledgerOriginal)

    $statePath=Join-Path $workspace 'workspace.state.json';$stateOriginal=[IO.File]::ReadAllBytes($statePath);$drift=Copy-HistoricalDebtValue $state;$drift.plan_revision=2;Write-HistoricalDebtJson $statePath $drift
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'Planning-state drift before a ledger suffix was accepted.'
    [IO.File]::WriteAllBytes($statePath,$stateOriginal)
    $lockPath=Join-Path $workspace 'feature.lock.json';$lockOriginal=[IO.File]::ReadAllBytes($lockPath);$lockDrift=Copy-HistoricalDebtValue $lock;$lockDrift.revision=2;$lockDrift.lock_fingerprint=Get-HistoricalDebtLockFingerprint $lockDrift;Write-HistoricalDebtJson $lockPath $lockDrift
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'Source-lock drift was accepted.'
    [IO.File]::WriteAllBytes($lockPath,$lockOriginal)
    $mapOriginal=[IO.File]::ReadAllBytes($mapPath);$mapDrift=Copy-HistoricalDebtValue $map;$mapDrift.repositories[0].aliases+= 'scope-drift';Write-HistoricalDebtJson $mapPath $mapDrift
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'Repository-map composition drift was accepted.'
    [IO.File]::WriteAllBytes($mapPath,$mapOriginal)
    $authPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'receipts/historical-validation-debt/synthetic-debt-0001/authorization.json';$authOriginal=[IO.File]::ReadAllBytes($authPath);$badAuth=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $authOriginal -Context 'synthetic authorization');$badAuth.signature.value_base64=[Convert]::ToBase64String([byte[]](1..200));Write-HistoricalDebtJson $authPath $badAuth
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A malformed external-owner signature was accepted.'
    [IO.File]::WriteAllBytes($authPath,$authOriginal)
    Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now -PayloadMutation { param($payload) $payload.expires_at=$now.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'An expired authorization was accepted.'
    Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now -PayloadMutation { param($payload) $payload.audit_id='short' }
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A malformed/replayed audit identifier was accepted.'
    Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $validatorDrift=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$validatorDrift.validator.environment_commit='0'*40;$core=[ordered]@{environment_commit=$validatorDrift.validator.environment_commit;environment_tree=[string]$validatorDrift.validator.environment_tree;files=$validatorDrift.validator.files};$validatorDrift.validator.identity_sha256=Get-MorphospaceCanonicalJsonSha256 $core;Write-HistoricalDebtJson $baselinePath $validatorDrift;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'Validator commit/tree drift was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $currentAttempt=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$currentAttempt.failure_records[0].locus.unit_id='current-feature';$currentAttempt.failure_records[0].locus.path='iteration-units/current-feature.json';$currentAttempt.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$currentAttempt.failure_records[0].failure_code;locus=$currentAttempt.failure_records[0].locus;message_sha256=[string]$currentAttempt.failure_records[0].message_sha256;evidence_sha256=[string]$currentAttempt.failure_records[0].evidence_sha256});$currentAttempt.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($currentAttempt.failure_records);Write-HistoricalDebtJson $baselinePath $currentAttempt;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline covering the capture current unit was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $unknownCode=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$unknownCode.failure_records[0].failure_code='unknown-contract';$unknownCode.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code='unknown-contract';locus=$unknownCode.failure_records[0].locus;message_sha256=[string]$unknownCode.failure_records[0].message_sha256;evidence_sha256=[string]$unknownCode.failure_records[0].evidence_sha256});$unknownCode.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($unknownCode.failure_records);Write-HistoricalDebtJson $baselinePath $unknownCode;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'An unknown/malformed historical-debt failure code was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    Write-Output 'Historical validation-debt baseline tests passed (cold aggregate capture, closed validator manifest, exact ratchet, mandatory signed receipt binding, current-feature success, and altered/new/removed/reordered/duplicate/unknown-category/current/state/source/validator/signature/expiry/audit/transport damage rejection).'
} finally {
    $rsa.Dispose()
    if ([IO.Directory]::Exists($temp)) { [IO.Directory]::Delete($temp,$true) }
}
