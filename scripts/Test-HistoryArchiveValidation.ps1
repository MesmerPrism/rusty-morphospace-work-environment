param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$pass = [ordered]@{
    schema='rusty.morphospace.workflow.history_archive_validation_result.v1';validation_id='archive-validation';project_id='archive-fixture';tier='quick';mode='tail-only';status='pass'
    checkpoint=[ordered]@{checkpoint_id='none';root_path=('history-archive/roots/'+('0'*64)+'.json');root_sha256=('0'*64)}
    source_prefix=[ordered]@{matches=$true;byte_length=1;sha256=('0'*64)};carry_forward=[ordered]@{complete=$true;checked_paths=@()};reason_codes=@('none');does_not_prove=@('Schema fixture only.')
}
if(-not(Test-Json -Json ($pass|ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\history-archive-validation-result-v1.schema.json'))){throw 'History archive validation self-test failed: pass result rejected by its schema.'}
$damage=$pass|ConvertTo-Json -Depth 32|ConvertFrom-Json;$damage.reason_codes=@('not-a-reason');$rejected=$false
try {$rejected=-not(Test-Json -Json ($damage|ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\history-archive-validation-result-v1.schema.json') -ErrorAction Stop)}catch{$rejected=$true}
if(-not$rejected){throw 'History archive validation self-test failed: unknown result reason accepted.'}
$audit=$pass|ConvertTo-Json -Depth 32|ConvertFrom-Json;$audit.tier='audit';$audit.mode='archive-replay'
if(-not(Test-Json -Json ($audit|ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\history-archive-validation-result-v1.schema.json'))){throw 'History archive validation self-test failed: audit result rejected by its schema.'}
$receiptSchema=Get-Content -LiteralPath (Join-Path $repoRoot 'schemas\validation-receipt.schema.json') -Raw | ConvertFrom-Json -Depth 100
$historyBindingSchema=[ordered]@{type='object';additionalProperties=$false;required=@('root','result');properties=[ordered]@{root=$receiptSchema.'$defs'.historyArchiveValidationBinding.properties.root;result=$receiptSchema.'$defs'.historyArchiveValidationBinding.properties.result};'$defs'=$receiptSchema.'$defs'}
$historyBinding=[ordered]@{root=[ordered]@{path=$audit.checkpoint.root_path;sha256=$audit.checkpoint.root_sha256;schema='rusty.morphospace.workflow.history_archive_root.v1'};result=$audit}
if(-not(Test-Json -Json ($historyBinding|ConvertTo-Json -Depth 32) -Schema ($historyBindingSchema|ConvertTo-Json -Depth 64))){throw 'History archive validation self-test failed: validation-receipt binding rejected audit archive tier.'}
$migration=$audit|ConvertTo-Json -Depth 32|ConvertFrom-Json;$migration.tier='migration';$migrationBinding=$historyBinding|ConvertTo-Json -Depth 32|ConvertFrom-Json;$migrationBinding.result=$migration
if(-not(Test-Json -Json ($migrationBinding|ConvertTo-Json -Depth 32) -Schema ($historyBindingSchema|ConvertTo-Json -Depth 64))){throw 'History archive validation self-test failed: validation-receipt binding rejected migration archive tier.'}
$invalidBinding=$historyBinding|ConvertTo-Json -Depth 32|ConvertFrom-Json;$invalidBinding.result.tier='standard';$invalidTierRejected=$false
try {$invalidTierRejected=-not(Test-Json -Json ($invalidBinding|ConvertTo-Json -Depth 32) -Schema ($historyBindingSchema|ConvertTo-Json -Depth 64) -ErrorAction Stop)}catch{$invalidTierRejected=$true}
if(-not$invalidTierRejected){throw 'History archive validation self-test failed: validation-receipt binding accepted unsupported standard archive tier.'}
& (Join-Path $PSScriptRoot 'Test-HistoryArchiveCheckpoint.ps1') -SelfTest
Write-Host 'History archive validation self-test passed.'
