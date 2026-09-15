[CmdletBinding()]
param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceLegacyToolingReclassification.psm1')

function Invoke-TestGit([string]$Root,[string[]]$Arguments){$output=@(& git -C $Root @Arguments 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw ($output-join"`n")};@($output)}
function Copy-TestValue([object]$Value){$Value|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String}
function Assert-TestThrows([scriptblock]$Action,[string]$Pattern){try{&$Action;throw "Expected failure matching '$Pattern'."}catch{if($_.Exception.Message-cnotmatch$Pattern){throw}}}
function Remove-TestRoot([string]$Path){$full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/');$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');if([IO.Path]::GetDirectoryName($full)-ine$temp-or[IO.Path]::GetFileName($full)-cnotmatch'^morphospace-legacy-tooling-[0-9a-f]{32}$'){throw "Refusing to remove unexpected legacy tooling test path '$full'."};if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}}

$root=Join-Path ([IO.Path]::GetTempPath()) "morphospace-legacy-tooling-$([guid]::NewGuid().ToString('N'))"
try{
    $workspace=Join-Path $root 'workspace';$executor=Join-Path $root 'executor';[void][IO.Directory]::CreateDirectory((Join-Path $workspace 'local'));[void][IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts'));[void][IO.Directory]::CreateDirectory((Join-Path $executor 'skills/alpha'))
    [IO.File]::WriteAllText((Join-Path $executor 'skills/alpha/SKILL.md'),'old reviewed router',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $executor 'skills/alpha/reference.md'),'old referenced closure',[Text.UTF8Encoding]::new($false))
    [void](Invoke-TestGit $executor @('init'));[void](Invoke-TestGit $executor @('config','user.email','fixture@example.invalid'));[void](Invoke-TestGit $executor @('config','user.name','Fixture'));[void](Invoke-TestGit $executor @('remote','add','origin','https://example.invalid/tooling.git'));[void](Invoke-TestGit $executor @('add','.'));[void](Invoke-TestGit $executor @('commit','-m','old tooling'))
    $oldCommit=[string](@(Invoke-TestGit $executor @('rev-parse','HEAD'))[0]);$oldTree=[string](@(Invoke-TestGit $executor @('rev-parse','HEAD^{tree}'))[0])
    [IO.File]::WriteAllText((Join-Path $executor 'skills/alpha/SKILL.md'),'new reviewed router',[Text.UTF8Encoding]::new($false));[void](Invoke-TestGit $executor @('add','.'));[void](Invoke-TestGit $executor @('commit','-m','new tooling'))

    $toolProject=[pscustomobject][ordered]@{repo_id='legacy-skill-surfaces';role='tool';path='skills';allowed_paths=@('alpha/SKILL.md')}
    $productCurrent=[pscustomobject][ordered]@{repo_id='quest-app';role='application';path='quest';allowed_paths=@('app/')}
    $productTarget=[pscustomobject][ordered]@{repo_id='quest-app';role='application';path='quest';allowed_paths=@('app/','broker-contracts/')}
    $currentProject=[pscustomobject]@{repositories=@($productCurrent,$toolProject)};$targetProject=[pscustomobject]@{repositories=@($productTarget)}
    $productMap=[pscustomobject][ordered]@{repo_id='quest-app';path=(Join-Path $root 'quest-app');role='source'};[void][IO.Directory]::CreateDirectory([string]$productMap.path)
    $toolMap=[pscustomobject][ordered]@{repo_id='legacy-skill-surfaces';path=$executor;role='source'}
    $oldMap=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@($productMap,$toolMap)};$targetMap=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@($productMap)}
    Write-MorphospaceManagedProtocolJsonAtomic $workspace 'local/repository-map-old.json' $oldMap;Write-MorphospaceManagedProtocolJsonAtomic $workspace 'local/repository-map-target.json' $targetMap
    $oldSourceRow=[pscustomobject][ordered]@{repo_id='legacy-skill-surfaces';role='source';commit=$oldCommit;tree=$oldTree;branch='main';materialization_path='skills';tracked_worktree_clean=$true}
    $oldSource=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.development_envelope_source_composition.v1';lock_id='old-source-lock';preparation_id='old-preparation';project_id='fixture-project';fingerprint=('0'*64);repositories=@($oldSourceRow);status='locked';does_not_prove=@('Historical product success.')}
    Write-MorphospaceManagedProtocolJsonAtomic $workspace 'receipts/old-source.json' $oldSource
    $oldMapHash=Get-MorphospaceFileSha256 (Join-Path $workspace 'local/repository-map-old.json');$targetMapHash=Get-MorphospaceFileSha256 (Join-Path $workspace 'local/repository-map-target.json');$sourceHash=Get-MorphospaceFileSha256 (Join-Path $workspace 'receipts/old-source.json');$sourceCanonical=Get-MorphospaceCanonicalJsonSha256 $oldSource
    $admission=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.development_unit_admission.v1';admission_kind='ordinary';admission_id='legacy-admission';project_id='fixture-project';unit_id='legacy-unit';preparation=[pscustomobject]@{preparation_id='old-preparation';receipt_path='receipts/old-preparation.json';receipt_sha256=('1'*64);source_composition_path='receipts/old-source.json';source_composition_sha256=$sourceHash};agent_scope_assessment=[pscustomobject]@{reviewed=$true};unit=[pscustomobject]@{unit_id='legacy-unit'};expected=[pscustomobject]@{project_sha256=('2'*64);state_sha256=('3'*64);feature_lock_sha256=('4'*64);source_composition_path='receipts/old-source.json';source_composition_sha256=$sourceHash;repository_map_path='local/repository-map-old.json';repository_map_sha256=$oldMapHash;events_sha256=('5'*64);events_length=1;event_tail_id='old-tail'};does_not_prove=@('Future execution.')}
    Write-MorphospaceManagedProtocolJsonAtomic $workspace 'receipts/legacy-admission.json' $admission
    $reclassification=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.legacy_tooling_reclassification.v1';reclassification_id='legacy-tooling-review';old_repository_map=[pscustomobject]@{path='local/repository-map-old.json';sha256=$oldMapHash};target_repository_map=[pscustomobject]@{path='local/repository-map-target.json';sha256=$targetMapHash};removed_tool_repositories=@([pscustomobject][ordered]@{repo_id='legacy-skill-surfaces';project_row_sha256=(Get-MorphospaceCanonicalJsonSha256 $toolProject);map_row_sha256=(Get-MorphospaceCanonicalJsonSha256 $toolMap);source_composition=[pscustomobject]@{path='receipts/old-source.json';sha256=$sourceHash;canonical_sha256=$sourceCanonical};source_row_sha256=(Get-MorphospaceCanonicalJsonSha256 $oldSourceRow);commit=$oldCommit;tree=$oldTree;materialization_path='skills';canonical_allowed_paths=@('alpha/SKILL.md');router_skill_ids=@('alpha')});status='reviewed';does_not_prove=@('Product source removal.')}
    $tooling=[pscustomobject]@{executor=[pscustomobject]@{repo_id='tooling-executor';remote_url='https://example.invalid/tooling.git'};routers=@([pscustomobject]@{skill_id='alpha';source_repo_id='tooling-executor';managed_files=@([pscustomobject]@{path='SKILL.md'},[pscustomobject]@{path='reference.md'})})}
    $proof=[pscustomobject]@{request=[pscustomobject]@{unit_id='legacy-unit';source_composition=[pscustomobject]@{path='receipts/old-source.json';raw_sha256=$sourceHash;canonical_sha256=$sourceCanonical};expected=[pscustomobject]@{repository_map_sha256=$oldMapHash}};receipt=[pscustomobject]@{unit_id='legacy-unit'}}
    $history=[pscustomobject]@{authenticated=$true;retired_active_ids=@('legacy-unit');historical_ids=@();retired_ids=@();historically_retired_proposed_ids=@();active_retirements=@{'legacy-unit'=$proof};units=@{'legacy-unit'=[pscustomobject]@{unit_id='legacy-unit';status='active';allowed_repositories=@([pscustomobject]@{repo_id='legacy-skill-surfaces'})}}}
    $owners=@([pscustomobject]@{repo_id='quest-app';source_roots=@('broker-contracts/')})
    [void](Assert-MorphospaceLegacyToolingReclassification -WorkspaceRoot $workspace -Reclassification $reclassification -CurrentProject $currentProject -TargetProject $targetProject -CurrentMap $oldMap -TargetMap $targetMap -ToolingDescriptor $tooling -History $history -TargetSourceRepositoryIds @('quest-app') -OwnerRepositories $owners)

    $history.units['live-unit']=[pscustomobject]@{unit_id='live-unit';status='active';allowed_repositories=@([pscustomobject]@{repo_id='legacy-skill-surfaces'})}
    Assert-TestThrows {Assert-MorphospaceLegacyToolingReclassification -WorkspaceRoot $workspace -Reclassification $reclassification -CurrentProject $currentProject -TargetProject $targetProject -CurrentMap $oldMap -TargetMap $targetMap -ToolingDescriptor $tooling -History $history -TargetSourceRepositoryIds @('quest-app') -OwnerRepositories $owners} 'Nonterminal unit'
    $history.units.Remove('live-unit')
    $badTooling=Copy-TestValue $tooling;$badTooling.routers[0].managed_files=@([pscustomobject]@{path='reference.md'})
    Assert-TestThrows {Assert-MorphospaceLegacyToolingReclassification -WorkspaceRoot $workspace -Reclassification $reclassification -CurrentProject $currentProject -TargetProject $targetProject -CurrentMap $oldMap -TargetMap $targetMap -ToolingDescriptor $badTooling -History $history -TargetSourceRepositoryIds @('quest-app') -OwnerRepositories $owners} 'reviewed router file'
    Assert-TestThrows {Assert-MorphospaceLegacyToolingReclassification -WorkspaceRoot $workspace -Reclassification $reclassification -CurrentProject $currentProject -TargetProject $targetProject -CurrentMap $oldMap -TargetMap $targetMap -ToolingDescriptor $tooling -History $history -TargetSourceRepositoryIds @('quest-app') -OwnerRepositories @()} 'reviewed owner source-root authority'
    [pscustomobject]@{status='PASS';scenario='legacy-tooling-reclassification';checks=4;old_commit=$oldCommit;current_executor_commit=[string](@(Invoke-TestGit $executor @('rev-parse','HEAD'))[0])}
}finally{Remove-TestRoot $root}
