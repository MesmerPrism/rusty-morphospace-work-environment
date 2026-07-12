$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force

function Assert-Handoff { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "Authority-runner handoff self-test failed: $Message"} }
function Assert-Rejected { param([scriptblock]$Action,[string]$Message) $rejected=$false;try{&$Action}catch{$rejected=$true};Assert-Handoff $rejected $Message }

$root=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-authority-handoff-'+[guid]::NewGuid().ToString('N'))
try {
    $workspace=Join-Path $root 'workspace';$owner=Join-Path $root 'owner';$runnerDirectory=Join-Path $owner 'scripts';[IO.Directory]::CreateDirectory($workspace)|Out-Null;[IO.Directory]::CreateDirectory($runnerDirectory)|Out-Null
    $runner=Join-Path $runnerDirectory 'Invoke-MorphospaceValidationAuthority.ps1';$marker=Join-Path $root 'marker.json'
    $body=@'
param([string]$Action,[string]$WorkspaceRoot,[string]$UnitId,[string]$ExecutionNonce,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Remaining)
[IO.File]::WriteAllText($env:MORPHOSPACE_HANDOFF_MARKER,(@{action=$Action;workspace=$WorkspaceRoot;unit=$UnitId;nonce=$ExecutionNonce;remaining=$Remaining}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
'@
    [IO.File]::WriteAllText($runner,$body,[Text.UTF8Encoding]::new($false));$runnerSha=(Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash.ToLowerInvariant()
    $migration=[pscustomobject]@{authority_artifacts=@([pscustomobject]@{repo_id='work-environment';path='scripts/Invoke-MorphospaceValidationAuthority.ps1';sha256=$runnerSha;git_blob_oid=('a'*40)})};$migrationPath=Join-Path $workspace 'migration.json';[IO.File]::WriteAllText($migrationPath,(($migration|ConvertTo-Json -Depth 10)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    $repoMap=@{'work-environment'=[pscustomobject]@{path=$owner}}
    $arguments=@('-RegistryPath','registry.json','-RepositoryMapPath','repository-map.json','-CurrentProtocolPath','protocol.json','-TrustMigrationPath','migration.json','-ClaimBaselinePath','baseline.json','-OwnershipPath','ownership.json','-ValidationActionPath','action.json','-EvidencePath','evidence.json')
    $env:MORPHOSPACE_HANDOFF_MARKER=$marker
    $module=Get-Module WorkUnitAutomation
    $nonce=&$module {param($workspace,$repoMap,$runner,$arguments)& Invoke-MorphospaceAuthorityRunnerForRecord -WorkspaceRoot $workspace -UnitId 'unit-test' -RepositoryMap $repoMap -AuthorityRunnerPath $runner -AuthorityRunnerArguments $arguments -ValidationReceipt 'receipt.json'} $workspace $repoMap $runner $arguments
    $written=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
    Assert-Handoff ($nonce -match '^[0-9a-f]{64}$' -and [string]$written.nonce-ceq$nonce) 'handoff did not generate and bind a fresh 32-byte nonce'
    Assert-Handoff ([string]$written.action-ceq'Validate'-and[string]$written.workspace-ceq$workspace-and[string]$written.unit-ceq'unit-test') 'handoff did not bind the fixed runner parameters'
    $other=Join-Path $root 'other.ps1';[IO.File]::WriteAllText($other,$body,[Text.UTF8Encoding]::new($false));Assert-Rejected {&$module {param($workspace,$repoMap,$other,$arguments)& Invoke-MorphospaceAuthorityRunnerForRecord -WorkspaceRoot $workspace -UnitId 'unit-test' -RepositoryMap $repoMap -AuthorityRunnerPath $other -AuthorityRunnerArguments $arguments -ValidationReceipt 'receipt.json'} $workspace $repoMap $other $arguments|Out-Null} 'unanchored runner path was accepted'
    Assert-Rejected {&$module {param($workspace,$repoMap,$runner)& Invoke-MorphospaceAuthorityRunnerForRecord -WorkspaceRoot $workspace -UnitId 'unit-test' -RepositoryMap $repoMap -AuthorityRunnerPath $runner -AuthorityRunnerArguments @('-TrustMigrationPath','migration.json') -ValidationReceipt 'receipt.json'} $workspace $repoMap $runner|Out-Null} 'incomplete authority runner arguments were accepted'
    Write-Host 'Authority-runner handoff self-test passed.'
} finally {
    Remove-Item -LiteralPath Env:MORPHOSPACE_HANDOFF_MARKER -ErrorAction SilentlyContinue
    if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}
}
