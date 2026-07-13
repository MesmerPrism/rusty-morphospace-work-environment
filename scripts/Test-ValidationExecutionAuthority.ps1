$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force

function Assert-Execution { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "Validation-execution authority self-test failed: $Message"} }
function Assert-Rejected { param([scriptblock]$Action,[string]$Message) $rejected=$false;try{&$Action}catch{$rejected=$true};Assert-Execution $rejected $Message }
function Write-TestJson { param([string]$Workspace,[string]$Relative,[object]$Value) $path=Join-Path $Workspace $Relative;$parent=[IO.Path]::GetDirectoryName($path);if(-not[IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)};[IO.File]::WriteAllText($path,(($Value|ConvertTo-Json -Depth 32 -Compress)+"`n"),[Text.UTF8Encoding]::new($false)) }
function Get-TestCanonicalSha { param([object]$Value) return & (Get-Module MorphospaceValidationAuthority) { param($InputValue) Get-MorphospaceCanonicalJsonSha256 $InputValue } $Value }

$workspace = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-validation-execution-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    $coverageUnit=[pscustomobject]@{project_id='coverage-test';unit_id='coverage-unit';device_requirement='none';acceptance=@([pscustomobject]@{acceptance_id='criterion-a'},[pscustomobject]@{acceptance_id='criterion-b'})}
    $coverageValidator=[pscustomobject]@{validator_id='coverage-owner';owner_repo_id='work-environment';sha256=('d'*64);input_closure=@();acceptance_ids=@('criterion-a','criterion-b');evidence_schema='rusty.morphospace.workflow.owner_validation.v1'}
    $coverageOwner=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.owner_validation.v1';validator_id='coverage-owner';created_at='2026-07-12T10:00:00.0000000Z';project_id='coverage-test';unit_id='coverage-unit';acceptance_ids=@('criterion-a','criterion-b');status='pass';criteria=@(
        [pscustomobject]@{acceptance_id='criterion-a';status='pass';command_id='coverage-command';command_path='coverage.ps1';command_sha256=('1'*64);output_sha256=('2'*64);exit_code=0},
        [pscustomobject]@{acceptance_id='criterion-b';status='pass';command_id='coverage-command';command_path='coverage.ps1';command_sha256=('1'*64);output_sha256=('2'*64);exit_code=0}
    );does_not_prove=@('Does not prove unrelated acceptance.')}
    Write-TestJson $workspace 'coverage\owner.json' $coverageOwner
    $coverageAction=[pscustomobject]@{schema='rusty.morphospace.workflow.validation_action.v2';attempt_id='coverage-attempt';profile_id='deep'}
    Write-TestJson $workspace 'coverage\action.json' $coverageAction
    $coverageEvidence=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.validation_evidence.v2';evidence_id='coverage-evidence';project_id='coverage-test';unit_id='coverage-unit';attempt_id='coverage-attempt';profile_id='deep';result='pass';action=Get-MorphospaceAuthorityReference $workspace (Join-Path $workspace 'coverage\action.json') 'validation-action' 'rusty.morphospace.workflow.validation_action.v2';device_validation=$null;validator_results=@([pscustomobject]@{validator_id='coverage-owner';owner_repo_id='work-environment';status='pass';exit_code=0;command_identity_sha256=('d'*64);cleanroom_fingerprint_sha256=('e'*64);input_closure_sha256=Get-TestCanonicalSha ([pscustomobject]@{closure=@()});acceptance_ids=@('criterion-a','criterion-b');owner_evidence=Get-MorphospaceAuthorityReference $workspace (Join-Path $workspace 'coverage\owner.json') 'owner-validation' 'rusty.morphospace.workflow.owner_validation.v1'})}
    Write-TestJson $workspace 'coverage\evidence.json' $coverageEvidence
    $coverageValidated=Test-MorphospaceValidationEvidenceV2 -WorkspaceRoot $workspace -EvidencePath 'coverage/evidence.json' -Unit $coverageUnit -SelectedValidators @($coverageValidator) -Action $coverageAction
    Assert-Execution ([string]$coverageValidated.result-eq'pass') 'exact multi-criterion evidence coverage was rejected'
    $coverageDamaged=($coverageEvidence|ConvertTo-Json -Depth 32|ConvertFrom-Json);$coverageDamaged.validator_results[0].acceptance_ids=@('criterion-a');Write-TestJson $workspace 'coverage\evidence-damaged.json' $coverageDamaged
    Assert-Rejected {Test-MorphospaceValidationEvidenceV2 -WorkspaceRoot $workspace -EvidencePath 'coverage/evidence-damaged.json' -Unit $coverageUnit -SelectedValidators @($coverageValidator) -Action $coverageAction|Out-Null} 'incomplete evidence acceptance coverage was accepted'

    $unit = [pscustomobject]@{ project_id='execution-test'; unit_id='receipt-test' }
    $outputs = @(
        [pscustomobject]@{repo_id='planning';path='receipts/owner.json';phase='validation';role='owner-validation';schema='rusty.morphospace.workflow.owner_validation.v1';validator_id='owner-test'},
        [pscustomobject]@{repo_id='planning';path='receipts/evidence.json';phase='validation';role='validation-evidence';schema='rusty.morphospace.workflow.validation_evidence.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='receipts/execution.json';phase='validation';role='validation-execution';schema='rusty.morphospace.workflow.validation_execution.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='receipts/receipt.json';phase='validation';role='validation-receipt';schema='rusty.morphospace.workflow.validation_receipt.v2';validator_id=$null}
    )
    $action = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.validation_action.v2';attempt_id='attempt-001';pre_observation_sha256=('a'*64);expected_outputs=$outputs}
    Write-TestJson $workspace 'receipts/action.json' $action
    $actionPath=Join-Path $workspace 'receipts\action.json';$action | Add-Member -NotePropertyName __path -NotePropertyValue $actionPath
    $evidence = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.validation_evidence.v2';evidence_id='evidence-001'}
    Write-TestJson $workspace 'receipts/evidence.json' $evidence
    $evidencePath=Join-Path $workspace 'receipts\evidence.json';$evidence | Add-Member -NotePropertyName __path -NotePropertyValue $evidencePath
    $receipt=[pscustomobject]@{observations=[pscustomobject]@{after_sha256=('b'*64)}}
    $missing=[pscustomobject]@{role='validation-execution';path='receipts/execution.json';schema='rusty.morphospace.workflow.validation_execution.v1';sha256=('0'*64)}
    Assert-Rejected { Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $workspace -ExecutionReference $missing -Unit $unit -Action $action -Evidence $evidence -AutomationOutputs $outputs -ReceiptReference 'receipts/receipt.json' -Receipt $receipt | Out-Null } 'manual receipt without an authority execution was accepted'
    $execution=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.validation_execution.v1';execution_id='receipt-test-attempt-001-execution';completed_at='2026-07-12T10:00:00.0000000Z';execution_nonce=('c'*64);project_id='execution-test';unit_id='receipt-test';attempt_id='attempt-001'
        action=Get-MorphospaceAuthorityReference $workspace $actionPath 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'
        evidence=Get-MorphospaceAuthorityReference $workspace $evidencePath 'validation-evidence' 'rusty.morphospace.workflow.validation_evidence.v2'
        expected_receipt=[pscustomobject]@{role='validation-receipt';path='receipts/receipt.json';schema='rusty.morphospace.workflow.validation_receipt.v2'}
        output_contract_sha256=Get-TestCanonicalSha ([pscustomobject]@{outputs=@($outputs|Sort-Object repo_id,path)})
        observations=[pscustomobject]@{before_sha256=('a'*64);after_sha256=('b'*64)}
        executor=[pscustomobject]@{command='Invoke-MorphospaceValidationAuthority.ps1';command_sha256=(Get-MorphospaceAuthoritySha256 (Join-Path $PSScriptRoot 'Invoke-MorphospaceValidationAuthority.ps1'))}
        status='completed'
    }
    Write-TestJson $workspace 'receipts/execution.json' $execution
    $reference=Get-MorphospaceAuthorityReference $workspace (Join-Path $workspace 'receipts\execution.json') 'validation-execution' 'rusty.morphospace.workflow.validation_execution.v1'
    $validated=Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $workspace -ExecutionReference $reference -Unit $unit -Action $action -Evidence $evidence -AutomationOutputs $outputs -ReceiptReference 'receipts/receipt.json' -Receipt $receipt -ExpectedExecutionNonce ('c'*64)
    Assert-Execution ([string]$validated.execution_id -eq 'receipt-test-attempt-001-execution') 'authority execution did not validate its exact action/evidence/output contract'
    $execution.expected_receipt.path='receipts/other.json'
    Write-TestJson $workspace 'receipts/mutated-execution.json' $execution
    $mutatedReference=Get-MorphospaceAuthorityReference $workspace (Join-Path $workspace 'receipts\mutated-execution.json') 'validation-execution' 'rusty.morphospace.workflow.validation_execution.v1'
    Assert-Rejected { Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $workspace -ExecutionReference $mutatedReference -Unit $unit -Action $action -Evidence $evidence -AutomationOutputs $outputs -ReceiptReference 'receipts/receipt.json' -Receipt $receipt | Out-Null } 'execution validation accepted a forged receipt target'
    Assert-Rejected { Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $workspace -ExecutionReference $reference -Unit $unit -Action $action -Evidence $evidence -AutomationOutputs $outputs -ReceiptReference 'receipts/receipt.json' -Receipt $receipt -ExpectedExecutionNonce ('d'*64) | Out-Null } 'execution validation accepted a nonce from another authority invocation'
    Write-Host 'Validation-execution authority self-test passed.'
} finally {
    if([IO.Directory]::Exists($workspace)){[IO.Directory]::Delete($workspace,$true)}
}
