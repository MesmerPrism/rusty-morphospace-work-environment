$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force

function Assert-Migration { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "Trust-migration authority self-test failed: $Message"} }
function Assert-Rejected { param([scriptblock]$Action,[string]$Message) $rejected=$false;try{&$Action}catch{$rejected=$true};Assert-Migration $rejected $Message }
function Write-Json { param([string]$Path,[object]$Value) [IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 32)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false)) }

$workspace=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-trust-migration-'+[guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($workspace)|Out-Null
    $repo=Split-Path -Parent $PSScriptRoot
    $registryPath=Join-Path $workspace 'registry.json';$anchorPath=Join-Path $workspace 'anchor.json';Write-Json $registryPath ([pscustomobject]@{fixture='registry'});Write-Json $anchorPath ([pscustomobject]@{fixture='anchor'})
    $registry=Get-MorphospaceAuthorityReference $workspace $registryPath 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'
    $anchor=Get-MorphospaceAuthorityReference $workspace $anchorPath 'legacy-prefix-anchor' 'rusty.morphospace.workflow.legacy_event_prefix_anchor.v1'
    $paths=@('scripts/Invoke-MorphospaceValidationAuthority.ps1','scripts/Invoke-Wf005OwnerValidator.ps1','scripts/Test-ValidationAuthorityLauncher.ps1','scripts/Test-AuthorityRunnerHandoff.ps1','scripts/Test-TrustMigrationAuthority.ps1','scripts/Test-ValidationExecutionAuthority.ps1','scripts/Test-TransitionLedger.ps1','scripts/WorkUnitAutomation.psm1','scripts/lib/MorphospaceOwnership.psm1','scripts/lib/MorphospaceTransitionLedger.psm1')
    $artifacts=@($paths|ForEach-Object{[pscustomobject]@{repo_id='work-environment';path=$_;sha256=(Get-MorphospaceAuthoritySha256 (Join-Path $repo $_));git_blob_oid=((& git -C $repo rev-parse "HEAD:$_").Trim().ToLowerInvariant()}})
    $migration=[pscustomobject]@{schema='rusty.morphospace.workflow.validator_trust_anchor_migration.v1';project_id='fixture-project';unit_id='fixture-unit';status='accepted';bootstrap_exception=[pscustomobject]@{one_time=$true;non_promotional=$true;self_authorization_scope='authority-adoption-only';normal_ownership_after_commit=$true};lineage=@([pscustomobject]@{role='legacy-bootstrap'},[pscustomobject]@{role='protocol-v2'},[pscustomobject]@{role='foundation'},[pscustomobject]@{role='authority'});registry=$registry;prior_event_anchor=$anchor;authority_artifacts=$artifacts}
    $migrationPath=Join-Path $workspace 'migration.json';Write-Json $migrationPath $migration
    $map=@{'work-environment'=[pscustomobject]@{path=$repo}}
    $validated=Test-MorphospaceValidatorTrustAnchorMigration -WorkspaceRoot $workspace -MigrationPath 'migration.json' -RegistryReference $registry -ExpectedProjectId 'fixture-project' -ExpectedUnitId 'fixture-unit' -RepositoryMap $map
    Assert-Migration (@($validated.authority_artifacts).Count-eq$paths.Count) 'exact tracked authority artifact set did not validate'
    $migration.authority_artifacts[0].sha256=('0'*64);Write-Json (Join-Path $workspace 'damaged.json') $migration
    Assert-Rejected {Test-MorphospaceValidatorTrustAnchorMigration -WorkspaceRoot $workspace -MigrationPath 'damaged.json' -RegistryReference $registry -ExpectedProjectId 'fixture-project' -ExpectedUnitId 'fixture-unit' -RepositoryMap $map|Out-Null} 'migration accepted a substituted authority artifact'
    Write-Host 'Trust-migration authority self-test passed.'
} finally {if([IO.Directory]::Exists($workspace)){[IO.Directory]::Delete($workspace,$true)}}
