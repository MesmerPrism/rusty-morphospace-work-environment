param([string]$Path,[string]$SourceRepository,[string]$PlanningRepository,[string]$WorkspaceRoot,[switch]$SelfTest)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlanningProjection.psm1') -Force
if($SelfTest){
 $d=Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\planning-workspace-projection.example.json')|ConvertFrom-Json
 $temp=Join-Path ([IO.Path]::GetTempPath()) ('projection-'+[guid]::NewGuid().ToString('N')+'.json')
 $repo=Join-Path ([IO.Path]::GetTempPath()) ('projection-repo-'+[guid]::NewGuid().ToString('N'));$linked="$repo-linked"
 try{$d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8;Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null
  $d.source.repo_id=$d.planning.repo_id;$d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Same-repository projection was accepted.'}
  $d=Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\planning-workspace-projection.example.json')|ConvertFrom-Json
  $d.source.upstream='origin/other';$d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Conflicting branch/upstream identity was accepted.'}
  New-Item -ItemType Directory $repo|Out-Null;git -C $repo init -q;git -C $repo config user.name fixture;git -C $repo config user.email fixture@example.invalid
  'x'|Set-Content (Join-Path $repo 'x.txt');git -C $repo add .;git -C $repo commit -q -m init;git -C $repo worktree add -q $linked
  if((Get-GitCommonDirectory $repo)-cne(Get-GitCommonDirectory $linked)){throw'Linked worktree Git identity was not detected.'}
  Write-Host 'Planning-workspace projection self-test passed.'
 }finally{if(Test-Path $linked){git -C $repo worktree remove --force $linked 2>$null};if(Test-Path $repo){Remove-Item -LiteralPath $repo -Recurse -Force};if(Test-Path $temp){Remove-Item -LiteralPath $temp -Force}}
 return
}
if(-not$Path){throw'Path is required.'}
if($SourceRepository){Test-MorphospacePlanningWorkspaceProjectionLive -Path $Path -SourceRepository $SourceRepository -PlanningRepository $PlanningRepository -WorkspaceRoot $WorkspaceRoot|ConvertTo-Json -Depth 16}
else{Test-MorphospacePlanningWorkspaceProjectionDocument $Path|ConvertTo-Json -Depth 16}
