param([string]$Path,[string]$SourceRepository,[string]$PlanningRepository,[string]$WorkspaceRoot,[switch]$SelfTest)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlanningProjection.psm1') -Force
if($SelfTest){
 $d=Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\planning-workspace-projection.example.json')|ConvertFrom-Json
 $temp=Join-Path ([IO.Path]::GetTempPath()) ('projection-'+[guid]::NewGuid().ToString('N')+'.json')
 $repo=Join-Path ([IO.Path]::GetTempPath()) ('projection-repo-'+[guid]::NewGuid().ToString('N'));$linked="$repo-linked"
 $fixture=Join-Path ([IO.Path]::GetTempPath()) ('projection-live-'+[guid]::NewGuid().ToString('N'))
 try{$d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8;Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null
  $d.source.repo_id=$d.planning.repo_id;$d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Same-repository projection was accepted.'}
  $d=Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\planning-workspace-projection.example.json')|ConvertFrom-Json
  $d.source.upstream='origin/other';$d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Conflicting branch/upstream identity was accepted.'}
  New-Item -ItemType Directory $repo|Out-Null;git -C $repo init -q;git -C $repo config user.name fixture;git -C $repo config user.email fixture@example.invalid
  'x'|Set-Content (Join-Path $repo 'x.txt');git -C $repo add .;git -C $repo commit -q -m init;git -C $repo worktree add -q $linked
  if((Get-GitCommonDirectory $repo)-cne(Get-GitCommonDirectory $linked)){throw'Linked worktree Git identity was not detected.'}

  $source=Join-Path $fixture 'source';$remote=Join-Path $fixture 'source.git';$planning=Join-Path $fixture 'planning'
  New-Item -ItemType Directory $source,$planning|Out-Null;git -C $source init -q;git -C $source config user.name fixture;git -C $source config user.email fixture@example.invalid
  New-Item -ItemType Directory (Join-Path $source 'morphospace\receipts')|Out-Null
  '{"project_id":"fixture"}'|Set-Content (Join-Path $source 'morphospace\project.spec.json') -Encoding utf8
  git -C $source add .;git -C $source commit -q -m old;$old=(git -C $source rev-parse HEAD).Trim()
  '{"project_id":"fixture","current_unit":null}'|Set-Content (Join-Path $source 'morphospace\workspace.state.json') -Encoding utf8
  git -C $source add .;git -C $source commit -q -m published;$published=(git -C $source rev-parse HEAD).Trim();git -C $source branch -M main
  git init -q --bare $remote;git -C $source remote add origin $remote;git -C $source push -q -u origin main
  git -C $planning init -q;git -C $planning config user.name fixture;git -C $planning config user.email fixture@example.invalid
  'planning'|Set-Content (Join-Path $planning 'README.md');git -C $planning add .;git -C $planning commit -q -m init
  $workspace=Join-Path $planning 'projects\fixture\morphospace';$projection=Join-Path $workspace 'receipts\projection.json'
  & (Join-Path $PSScriptRoot 'New-ExternalPlanningWorkspace.ps1') -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspace -ProjectionPath $projection -ProjectionId fixture-projection -ProjectId fixture -UnitId fixture-unit -SourceRepoId source-owner -PlanningRepoId planning-owner -Branch main -Upstream origin/main -OldRevision $old -PublishedRevision $published -Timestamp '2026-01-02T03:04:05Z' -Execute|Out-Null
  $closure=Join-Path $workspace 'receipts\closure.json';'{}'|Set-Content $closure -Encoding utf8
  Test-MorphospacePlanningWorkspaceProjectionLive -Path $projection -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspace -AllowedAdditivePaths @('receipts/closure.json')|Out-Null
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionLive -Path $projection -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspace|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Unbound additive file was accepted.'}
  '{}'|Set-Content (Join-Path $workspace 'unexpected.json') -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionLive -Path $projection -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspace -AllowedAdditivePaths @('receipts/closure.json')|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Unexpected additive file was accepted.'}
  Write-Host 'Planning-workspace projection self-test passed.'
 }finally{if(Test-Path $linked){git -C $repo worktree remove --force $linked 2>$null};if(Test-Path $repo){Remove-Item -LiteralPath $repo -Recurse -Force};if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force};if(Test-Path $temp){Remove-Item -LiteralPath $temp -Force}}
 return
}
if(-not$Path){throw'Path is required.'}
if($SourceRepository){Test-MorphospacePlanningWorkspaceProjectionLive -Path $Path -SourceRepository $SourceRepository -PlanningRepository $PlanningRepository -WorkspaceRoot $WorkspaceRoot|ConvertTo-Json -Depth 16}
else{Test-MorphospacePlanningWorkspaceProjectionDocument $Path|ConvertTo-Json -Depth 16}
