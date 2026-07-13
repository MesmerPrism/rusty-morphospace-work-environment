$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceOwnership.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceContentObservation.psm1') -Force

function Assert-Execution { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "Validation-execution authority self-test failed: $Message"} }
function Assert-Rejected { param([scriptblock]$Action,[string]$Message) $rejected=$false;try{&$Action}catch{$rejected=$true};Assert-Execution $rejected $Message }
function Write-TestJson { param([string]$Workspace,[string]$Relative,[object]$Value) $path=Join-Path $Workspace $Relative;$parent=[IO.Path]::GetDirectoryName($path);if(-not[IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)};[IO.File]::WriteAllText($path,(($Value|ConvertTo-Json -Depth 32 -Compress)+"`n"),[Text.UTF8Encoding]::new($false)) }
function Get-TestCanonicalSha { param([object]$Value) return & (Get-Module MorphospaceValidationAuthority) { param($InputValue) Get-MorphospaceCanonicalJsonSha256 $InputValue } $Value }
function Get-TestOrdinalSha { param([object]$Value) return Get-TestCanonicalSha ([pscustomobject]@{value=$Value}) }
function Copy-TestJsonObject { param([object]$Value) return ($Value|ConvertTo-Json -Depth 100 -Compress|ConvertFrom-Json) }
function Invoke-TestGit { param([string]$Git,[string]$Repository,[string[]]$Arguments) $output=@(&$Git -C $Repository @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "Fixture Git failed: $($Arguments-join' ') $($output-join' ')"};return [string]($output-join'') }
function Get-TestObservedEntries {
    param([object]$Observation)
    return @(& (Get-Module MorphospaceOwnership) {
        param($Value)
        $rows=[Collections.Generic.List[object]]::new()
        foreach($entry in @($Value.entries)){
            $normalized=New-MorphospaceObservedEntry $Value $entry;$core=$normalized.core
            $rows.Add([pscustomobject][ordered]@{path=[string]$core.path;entry_fingerprint_sha256=[string]$normalized.fingerprint_sha256;state=[string]$core.state;sha256=$core.sha256;length=$core.length;mode=$core.mode;patch_sha256=$core.patch_sha256;hunks=@($core.hunks)})|Out-Null
        }
        return @($rows.ToArray())
    } $Observation)
}
function New-TestGitBaselineRow {
    param([object]$Observation,[string[]]$AllowedPaths)
    $rows=@(Get-TestObservedEntries $Observation);$instructionSha=Get-TestCanonicalSha ([pscustomobject]@{entries=@()})
    return [pscustomobject][ordered]@{repo_id=[string]$Observation.repo_id;kind='git';head_revision=[string]$Observation.head_revision;head_tree_oid=[string]$Observation.head_tree;branch=[string]$Observation.branch;allowed_paths=@($AllowedPaths);content_observation_sha256=Get-TestCanonicalSha $Observation;status_sha256=[string]$Observation.status_sha256;overlay_fingerprint_sha256=[string]$Observation.overlay_fingerprint_sha256;commit_manifest_fingerprint_sha256=[string]$Observation.commit_fingerprint_sha256;instruction_observation_sha256=$instructionSha;entries_fingerprint_sha256=Get-TestOrdinalSha $rows;entries=$rows;instructions_fingerprint_sha256=$instructionSha;instructions=@()}
}
function New-TestGitOwnershipRow {
    param([object]$BaselineRow,[object]$Observation)
    $preserved=@($BaselineRow.entries|ForEach-Object{[string]$_.entry_fingerprint_sha256}|Sort-Object)
    return [pscustomobject][ordered]@{repo_id=[string]$Observation.repo_id;kind='git';base_revision=[string]$BaselineRow.head_revision;head_revision=[string]$Observation.head_revision;head_tree_oid=[string]$Observation.head_tree;branch=[string]$Observation.branch;allowed_paths=@($BaselineRow.allowed_paths);live_content_observation_sha256=Get-TestCanonicalSha $Observation;live_status_sha256=[string]$Observation.status_sha256;live_overlay_fingerprint_sha256=[string]$Observation.overlay_fingerprint_sha256;live_commit_manifest_fingerprint_sha256=[string]$Observation.commit_fingerprint_sha256;baseline_entries_sha256=[string]$BaselineRow.entries_fingerprint_sha256;preserved_baseline_entries_sha256=Get-TestOrdinalSha $preserved;preserved_baseline_count=$preserved.Count;instruction_observation_sha256=[string]$BaselineRow.instruction_observation_sha256;entries=@()}
}

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

    # Exercise the full seconds-scale publication tail that follows owner validation:
    # strict ownership re-observation, execution construction/publication, receipt
    # construction/publication, output closure, and execution verification.
    $publicationWorkspace=Join-Path $workspace 'publication-workspace'
    [IO.Directory]::CreateDirectory((Join-Path $publicationWorkspace 'publication'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $publicationWorkspace 'publication\.keep'),'baseline',[Text.UTF8Encoding]::new($false))
    $publicationGit=(Get-Command git.exe -CommandType Application -ErrorAction Stop).Source
    Invoke-TestGit $publicationGit $publicationWorkspace @('init','--quiet')|Out-Null
    Invoke-TestGit $publicationGit $publicationWorkspace @('config','user.name','Publication Test')|Out-Null
    Invoke-TestGit $publicationGit $publicationWorkspace @('config','user.email','publication@example.invalid')|Out-Null
    Invoke-TestGit $publicationGit $publicationWorkspace @('config','core.autocrlf','false')|Out-Null
    Invoke-TestGit $publicationGit $publicationWorkspace @('add','--','publication/.keep')|Out-Null
    Invoke-TestGit $publicationGit $publicationWorkspace @('commit','--quiet','-m','publication baseline')|Out-Null
    $publicationHead=(Invoke-TestGit $publicationGit $publicationWorkspace @('rev-parse','HEAD')).Trim()
    $publicationMapReference=[pscustomobject][ordered]@{role='repository-map';path='repository-map.json';schema='rusty.morphospace.workflow.repository_map.v1';sha256=('1'*64)}
    $publicationClaimReference=[pscustomobject][ordered]@{role='claim-baseline';path='claim-baseline.json';schema='rusty.morphospace.workflow.claim_baseline.v1';sha256=('2'*64)}
    $publicationMap=@{'planning'=[pscustomobject]@{path=$publicationWorkspace;aliases=@()}}
    $publicationUnit=[pscustomobject]@{project_id='publication-test';unit_id='publication-unit';device_requirement='none';allowed_repositories=@([pscustomobject]@{repo_id='planning';allowed_paths=@('publication')});instruction_impact='none';instruction_surfaces=@();acceptance=@([pscustomobject]@{acceptance_id='criterion-a'})}
    $publicationBaselineObservation=Get-MorphospaceGitRepositoryObservation -RepoId planning -RepositoryPath $publicationWorkspace -BaseRevision $publicationHead -AllowedPaths @('publication') -GitExecutable $publicationGit
    $publicationBaselineRow=New-TestGitBaselineRow $publicationBaselineObservation @('publication')
    $publicationClaim=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.claim_baseline.v1';baseline_id='publication-baseline';created_at='2026-07-12T10:00:00.0000000Z';project_id='publication-test';unit_id='publication-unit';repository_map=$publicationMapReference;repositories=@($publicationBaselineRow);status='frozen'}
    $publicationOutputs=@(
        [pscustomobject]@{repo_id='planning';path='publication/registry.json';phase='bootstrap';role='owner-validator-registry';schema='rusty.morphospace.workflow.owner_validator_registry.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='publication/ownership.json';phase='bootstrap';role='unit-ownership';schema='rusty.morphospace.workflow.unit_ownership.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='publication/protocol.json';phase='bootstrap';role='current-unit-protocol';schema='rusty.morphospace.workflow.current_unit_protocol.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='publication/action.json';phase='bootstrap';role='validation-action';schema='rusty.morphospace.workflow.validation_action.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='publication/owner.json';phase='validation';role='owner-validation';schema='rusty.morphospace.workflow.owner_validation.v1';validator_id='owner-test'},
        [pscustomobject]@{repo_id='planning';path='publication/evidence.json';phase='validation';role='validation-evidence';schema='rusty.morphospace.workflow.validation_evidence.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='publication/execution.json';phase='validation';role='validation-execution';schema='rusty.morphospace.workflow.validation_execution.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='publication/receipt.json';phase='validation';role='validation-receipt';schema='rusty.morphospace.workflow.validation_receipt.v2';validator_id=$null}
    )
    $publicationComparableBaseline=ConvertTo-MorphospaceComparableRepositoryObservation -Observation $publicationBaselineObservation -AutomationOutputs $publicationOutputs
    $publicationOwnershipRow=New-TestGitOwnershipRow $publicationBaselineRow $publicationComparableBaseline
    $publicationOwnership=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.unit_ownership.v1';ownership_id='publication-ownership';created_at='2026-07-12T10:01:00.0000000Z';project_id='publication-test';unit_id='publication-unit';claim_baseline=$publicationClaimReference;repositories=@($publicationOwnershipRow);shared_overlaps=@();automation_outputs=$publicationOutputs;status='assigned'}
    $publicationContract=@(Get-MorphospaceAutomationOutputContract -Ownership $publicationOwnership -Unit $publicationUnit -Scopes @{'planning'=$publicationUnit.allowed_repositories[0]})
    $publicationBeforeDocument=[pscustomobject][ordered]@{repositories=@($publicationComparableBaseline);instructions=@()}
    $publicationBefore=[pscustomobject]@{observation=[pscustomobject]@{document=$publicationBeforeDocument;sha256=Get-TestCanonicalSha $publicationBeforeDocument};automation_outputs=$publicationContract}
    $publicationAction=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.validation_action.v2';attempt_id='publication-attempt';project_id='publication-test';unit_id='publication-unit';profile_id='deep';pre_observation_sha256=[string]$publicationBefore.observation.sha256;expected_outputs=@($publicationBefore.automation_outputs);status='authorized'}
    $publicationRegistry=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.owner_validator_registry.v1';registry_id='publication-registry'}
    $publicationProtocol=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.current_unit_protocol.v1';project_id='publication-test';unit_id='publication-unit';status='active'}
    $publicationOwner=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.owner_validation.v1';validator_id='owner-test';status='pass'}
    Write-TestJson $publicationWorkspace 'publication/registry.json' $publicationRegistry
    Write-TestJson $publicationWorkspace 'publication/ownership.json' $publicationOwnership
    Write-TestJson $publicationWorkspace 'publication/protocol.json' $publicationProtocol
    Write-TestJson $publicationWorkspace 'publication/action.json' $publicationAction
    Write-TestJson $publicationWorkspace 'publication/owner.json' $publicationOwner
    $publicationEvidence=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.validation_evidence.v2';evidence_id='publication-evidence';project_id='publication-test';unit_id='publication-unit';attempt_id='publication-attempt';profile_id='deep';result='pass'
        action=Get-MorphospaceAuthorityReference $publicationWorkspace (Join-Path $publicationWorkspace 'publication\action.json') 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'
        validator_results=@([pscustomobject]@{validator_id='owner-test';owner_repo_id='planning';acceptance_ids=@('criterion-a');status='pass';owner_evidence=Get-MorphospaceAuthorityReference $publicationWorkspace (Join-Path $publicationWorkspace 'publication\owner.json') 'owner-validation' 'rusty.morphospace.workflow.owner_validation.v1'})
        device_validation=$null;does_not_prove=@('Does not prove a production authority run.')
    }
    Write-TestJson $publicationWorkspace 'publication/evidence.json' $publicationEvidence
    $publicationAfter=Test-MorphospaceUnitOwnership -Ownership $publicationOwnership -ClaimBaseline $publicationClaim -ClaimBaselineReference $publicationClaimReference -Unit $publicationUnit -RepositoryMapReference $publicationMapReference -RepositoryMap $publicationMap
    Assert-Execution ([string]$publicationAfter.observation.sha256-ceq[string]$publicationBefore.observation.sha256) 'late publication outputs changed the ownership observation'
    $decoratedOwnership=Copy-TestJsonObject $publicationOwnership;$decoratedOwnership|Add-Member -NotePropertyName __path -NotePropertyValue (Join-Path $publicationWorkspace 'publication\ownership.json')
    Assert-Rejected {Test-MorphospaceUnitOwnership -Ownership $decoratedOwnership -ClaimBaseline $publicationClaim -ClaimBaselineReference $publicationClaimReference -Unit $publicationUnit -RepositoryMapReference $publicationMapReference -RepositoryMap $publicationMap|Out-Null} 'strict ownership accepted injected path metadata'
    $publicationActionPath=Join-Path $publicationWorkspace 'publication\action.json';$publicationEvidencePath=Join-Path $publicationWorkspace 'publication\evidence.json';$publicationExecutionPath=Join-Path $publicationWorkspace 'publication\execution.json'
    $publicationExecution=New-MorphospaceValidationExecutionV1 -WorkspaceRoot $publicationWorkspace -Unit $publicationUnit -Action $publicationAction -ActionPath $publicationActionPath -Evidence $publicationEvidence -EvidencePath $publicationEvidencePath -Observation $publicationAfter.observation -ExpectedReceiptPath 'publication/receipt.json' -ExecutorPath (Join-Path $PSScriptRoot 'Invoke-MorphospaceValidationAuthority.ps1') -ExecutionNonce ('c'*64)
    Write-TestJson $publicationWorkspace 'publication/execution.json' $publicationExecution
    $publicationReceipt=New-MorphospaceValidationReceiptV2 -WorkspaceRoot $publicationWorkspace -Unit $publicationUnit -Action $publicationAction -ActionPath $publicationActionPath -Evidence $publicationEvidence -EvidencePath $publicationEvidencePath -Execution $publicationExecution -ExecutionPath $publicationExecutionPath -Protocol $publicationProtocol -ProtocolPath (Join-Path $publicationWorkspace 'publication\protocol.json') -Ownership $publicationOwnership -OwnershipPath (Join-Path $publicationWorkspace 'publication\ownership.json') -Registry $publicationRegistry -RegistryPath (Join-Path $publicationWorkspace 'publication\registry.json') -Observation $publicationAfter.observation
    Write-TestJson $publicationWorkspace 'publication/receipt.json' $publicationReceipt
    Test-MorphospaceAutomationOutputSet -AutomationOutputs $publicationBefore.automation_outputs -RepositoryMap $publicationMap -Expected present
    $publicationExecutionReference=Get-MorphospaceAuthorityReference $publicationWorkspace $publicationExecutionPath 'validation-execution' 'rusty.morphospace.workflow.validation_execution.v1'
    $publicationValidated=Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $publicationWorkspace -ExecutionReference $publicationExecutionReference -Unit $publicationUnit -Action $publicationAction -ActionPath $publicationActionPath -Evidence $publicationEvidence -EvidencePath $publicationEvidencePath -AutomationOutputs $publicationBefore.automation_outputs -ReceiptReference 'publication/receipt.json' -Receipt $publicationReceipt -ExpectedExecutionNonce ('c'*64)
    Assert-Execution ([string]$publicationValidated.status-ceq'completed') 'late publication execution did not verify'
    foreach($referenceCheck in @(
        @($publicationReceipt.action,'validation-action','rusty.morphospace.workflow.validation_action.v2'),
        @($publicationReceipt.evidence,'validation-evidence','rusty.morphospace.workflow.validation_evidence.v2'),
        @($publicationReceipt.execution,'validation-execution','rusty.morphospace.workflow.validation_execution.v1'),
        @($publicationReceipt.current_protocol,'current-unit-protocol','rusty.morphospace.workflow.current_unit_protocol.v1'),
        @($publicationReceipt.ownership,'unit-ownership','rusty.morphospace.workflow.unit_ownership.v1'),
        @($publicationReceipt.registry,'owner-validator-registry','rusty.morphospace.workflow.owner_validator_registry.v1')
    )){[void](Assert-MorphospaceAuthorityReference $publicationWorkspace $referenceCheck[0] $referenceCheck[1] $referenceCheck[2])}
    foreach($document in @($publicationAction,$publicationEvidence,$publicationExecution,$publicationProtocol,$publicationOwnership,$publicationRegistry)){Assert-Execution (-not($document.PSObject.Properties.Name-contains'__path')) 'late publication mutated a strict document with path metadata'}
    $decoratedAction=Copy-TestJsonObject $publicationAction;$decoratedAction|Add-Member -NotePropertyName __path -NotePropertyValue $publicationActionPath
    Assert-Rejected {New-MorphospaceValidationExecutionV1 -WorkspaceRoot $publicationWorkspace -Unit $publicationUnit -Action $decoratedAction -ActionPath $publicationActionPath -Evidence $publicationEvidence -EvidencePath $publicationEvidencePath -Observation $publicationAfter.observation -ExpectedReceiptPath 'publication/receipt.json' -ExecutorPath (Join-Path $PSScriptRoot 'Invoke-MorphospaceValidationAuthority.ps1') -ExecutionNonce ('d'*64)|Out-Null} 'execution constructor accepted path metadata inside a schema document'
    $substitutedAction=Copy-TestJsonObject $publicationAction;$substitutedAction.attempt_id='substituted-attempt'
    Assert-Rejected {New-MorphospaceValidationExecutionV1 -WorkspaceRoot $publicationWorkspace -Unit $publicationUnit -Action $substitutedAction -ActionPath $publicationActionPath -Evidence $publicationEvidence -EvidencePath $publicationEvidencePath -Observation $publicationAfter.observation -ExpectedReceiptPath 'publication/receipt.json' -ExecutorPath (Join-Path $PSScriptRoot 'Invoke-MorphospaceValidationAuthority.ps1') -ExecutionNonce ('e'*64)|Out-Null} 'execution constructor accepted a document substituted after path binding'

    $unit = [pscustomobject]@{ project_id='execution-test'; unit_id='receipt-test' }
    $outputs = @(
        [pscustomobject]@{repo_id='planning';path='receipts/owner.json';phase='validation';role='owner-validation';schema='rusty.morphospace.workflow.owner_validation.v1';validator_id='owner-test'},
        [pscustomobject]@{repo_id='planning';path='receipts/evidence.json';phase='validation';role='validation-evidence';schema='rusty.morphospace.workflow.validation_evidence.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='receipts/execution.json';phase='validation';role='validation-execution';schema='rusty.morphospace.workflow.validation_execution.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path='receipts/receipt.json';phase='validation';role='validation-receipt';schema='rusty.morphospace.workflow.validation_receipt.v2';validator_id=$null}
    )
    $action = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.validation_action.v2';attempt_id='attempt-001';pre_observation_sha256=('a'*64);expected_outputs=$outputs}
    Write-TestJson $workspace 'receipts/action.json' $action
    $actionPath=Join-Path $workspace 'receipts\action.json'
    $evidence = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.validation_evidence.v2';evidence_id='evidence-001'}
    Write-TestJson $workspace 'receipts/evidence.json' $evidence
    $evidencePath=Join-Path $workspace 'receipts\evidence.json'
    $receipt=[pscustomobject]@{observations=[pscustomobject]@{after_sha256=('b'*64)}}
    $missing=[pscustomobject]@{role='validation-execution';path='receipts/execution.json';schema='rusty.morphospace.workflow.validation_execution.v1';sha256=('0'*64)}
    Assert-Rejected { Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $workspace -ExecutionReference $missing -Unit $unit -Action $action -ActionPath $actionPath -Evidence $evidence -EvidencePath $evidencePath -AutomationOutputs $outputs -ReceiptReference 'receipts/receipt.json' -Receipt $receipt | Out-Null } 'manual receipt without an authority execution was accepted'
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
    $validated=Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $workspace -ExecutionReference $reference -Unit $unit -Action $action -ActionPath $actionPath -Evidence $evidence -EvidencePath $evidencePath -AutomationOutputs $outputs -ReceiptReference 'receipts/receipt.json' -Receipt $receipt -ExpectedExecutionNonce ('c'*64)
    Assert-Execution ([string]$validated.execution_id -eq 'receipt-test-attempt-001-execution') 'authority execution did not validate its exact action/evidence/output contract'
    $execution.expected_receipt.path='receipts/other.json'
    Write-TestJson $workspace 'receipts/mutated-execution.json' $execution
    $mutatedReference=Get-MorphospaceAuthorityReference $workspace (Join-Path $workspace 'receipts\mutated-execution.json') 'validation-execution' 'rusty.morphospace.workflow.validation_execution.v1'
    Assert-Rejected { Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $workspace -ExecutionReference $mutatedReference -Unit $unit -Action $action -ActionPath $actionPath -Evidence $evidence -EvidencePath $evidencePath -AutomationOutputs $outputs -ReceiptReference 'receipts/receipt.json' -Receipt $receipt | Out-Null } 'execution validation accepted a forged receipt target'
    Assert-Rejected { Test-MorphospaceValidationExecutionV1 -WorkspaceRoot $workspace -ExecutionReference $reference -Unit $unit -Action $action -ActionPath $actionPath -Evidence $evidence -EvidencePath $evidencePath -AutomationOutputs $outputs -ReceiptReference 'receipts/receipt.json' -Receipt $receipt -ExpectedExecutionNonce ('d'*64) | Out-Null } 'execution validation accepted a nonce from another authority invocation'
    Write-Host 'Validation-execution authority self-test passed.'
} finally {
    if([IO.Directory]::Exists($workspace)){
        foreach($file in [IO.Directory]::EnumerateFiles($workspace,'*',[IO.SearchOption]::AllDirectories)){try{[IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal)}catch{}}
        [IO.Directory]::Delete($workspace,$true)
    }
}
