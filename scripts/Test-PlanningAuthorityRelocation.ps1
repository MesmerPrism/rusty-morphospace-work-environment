param([switch]$SelfTest,[string]$FixturePath='')
$ErrorActionPreference='Stop'
$owner=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $PSScriptRoot 'ActiveDevelopmentEnvelopeExtension.psm1') -PassThru
function Copy-TestValue($v){$v|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String}
function Deny([scriptblock]$Action,[string]$Name){$denied=$false;try{&$Action|Out-Null}catch{$denied=$true};if(-not$denied){throw "Planning relocation negative admitted: $Name"};Write-Output "PASS deny $Name"}
$old=[pscustomobject]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([pscustomobject]@{repo_id='project-shell';role='planning';path='/old-planning'},[pscustomobject]@{repo_id='source-core';role='source';path='/source-core'})}
$new=Copy-TestValue $old;$new.repositories[0].path='/selected-planning'
$q=[pscustomobject]@{planning_authority_relocation=[pscustomobject]@{repo_id='project-shell'};additions=[pscustomobject]@{repository_ids=@();owner_roots=@()};effective_repository_map=[pscustomobject]@{path='local/relocated-map.json'}}
function Map($request,$map){&$module {param($q,$o,$m)Assert-ActiveEnvelopeMapExtension $q $o $o $m 'local/original-map.json'} $request $old $map}
Map $q $new;Write-Output 'PASS exact planning-row-only map successor'
$bad=Copy-TestValue $new;$bad.repositories[1].path='/changed-product';Deny {Map $q $bad} 'other source row'
$bad=Copy-TestValue $new;$bad.repositories[0].role='source';Deny {Map $q $bad} 'planning role change'
$bad=Copy-TestValue $new;$bad.repositories[0]|Add-Member aliases @('unbound');Deny {Map $q $bad} 'planning aliases change'
$bad=Copy-TestValue $q;$bad.effective_repository_map.path='local/original-map.json';Deny {Map $bad $new} 'old-map replacement'
$bad=Copy-TestValue $q;$bad.additions.repository_ids=@('additional-source');Deny {Map $bad $new} 'unrelated addition'
$bad=Copy-TestValue $q;$bad.PSObject.Properties.Remove('planning_authority_relocation');Deny {Map $bad $new} 'unselected relocation'
if($FixturePath){
 $fixture=Get-Content -LiteralPath $FixturePath -Raw|ConvertFrom-Json -Depth 100 -DateKind String
 Import-Module (Join-Path $PSScriptRoot 'lib/MorphospacePlanningAuthorityRelocation.psm1') -Force
 function Check($value){Assert-MorphospacePlanningAuthorityRelocation -WorkspaceRoot $fixture.workspace -Request $value -ParentSource $fixture.parent_source -EffectiveMap $fixture.effective_map}
 Check $fixture.request|Out-Null;Write-Output 'PASS real adopted committed planning projection'
 $copied=Join-Path ([IO.Path]::GetTempPath()) ('planning-relocation-copied-'+[guid]::NewGuid().ToString('N'))
 try{
  [IO.Directory]::CreateDirectory((Join-Path $copied 'morphospace'))|Out-Null
  foreach($relative in @('project.spec.json','workspace.state.json','feature.lock.json')){Copy-Item -LiteralPath (Join-Path $fixture.workspace $relative) -Destination (Join-Path $copied ('morphospace/'+$relative))}
  $copiedMap=Copy-TestValue $fixture.effective_map;@($copiedMap.repositories|Where-Object repo_id -eq $fixture.request.planning_authority_relocation.repo_id)[0].path=$copied
  $copiedRequest=Copy-TestValue $fixture.request;$copiedRequest.planning_authority_relocation.destination.workspace_path='morphospace'
  Deny {Assert-MorphospacePlanningAuthorityRelocation -WorkspaceRoot (Join-Path $copied 'morphospace') -Request $copiedRequest -ParentSource $fixture.parent_source -EffectiveMap $copiedMap} 'copied control bytes without Git provenance'
 }finally{
  $full=[IO.Path]::GetFullPath($copied);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
  if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full).StartsWith('planning-relocation-copied-')){Remove-Item -LiteralPath $full -Recurse -Force}
 }
 $bad=Copy-TestValue $fixture.request;$bad.planning_authority_relocation.destination.workspace_path='wrong-workspace';Deny {Check $bad} 'wrong selected destination'
 $bad=Copy-TestValue $fixture.request;$bad.planning_authority_relocation.destination.tree='0'*40;Deny {Check $bad} 'wrong committed tree'
 $bad=Copy-TestValue $fixture.request;$bad.expected.project_raw_sha256='0'*64;Deny {Check $bad} 'project CAS drift'
 $bad=Copy-TestValue $fixture.request;$bad.expected.feature_lock_raw_sha256='0'*64;Deny {Check $bad} 'feature CAS drift'
 $bad=Copy-TestValue $fixture.request;$bad.planning_authority_relocation.adoption.path='receipts/missing-adoption.json';Deny {Check $bad} 'no adoption'
 $bad=Copy-TestValue $fixture.request;$bad.planning_authority_relocation.projection.raw_sha256='0'*64;Deny {Check $bad} 'detached projection'
 $bad=Copy-TestValue $fixture.request;$bad.planning_authority_relocation.adoption.git_blob_sha256='0'*64;Deny {Check $bad} 'committed adoption bytes drift'
 $bad=Copy-TestValue $fixture.request;$bad.planning_authority_relocation.destination.branch='unselected-branch';Deny {Check $bad} 'branch drift'
 # Historical replay observes the same captured commit and prefix, not a new live claim.
 Assert-MorphospacePlanningAuthorityRelocation -WorkspaceRoot $fixture.workspace -Request $fixture.request -ParentSource $fixture.parent_source -EffectiveMap $fixture.effective_map -Historical|Out-Null;Write-Output 'PASS captured historical projection'
}
Write-Output 'Planning authority relocation focused controls passed.'