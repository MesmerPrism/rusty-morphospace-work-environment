param([string]$Path,[string]$SourceRepository,[string]$PlanningRepository,[string]$WorkspaceRoot,[switch]$SelfTest)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlanningProjection.psm1') -Force
if($SelfTest){
 $repoRoot=Split-Path -Parent $PSScriptRoot
 $schemaPath=Join-Path $repoRoot 'schemas\planning-workspace-projection.schema.json'
 $v1Template=Join-Path $repoRoot 'templates\planning-workspace-projection.example.json'
  $v2Template=Join-Path $repoRoot 'templates\planning-workspace-projection-v2.example.json'
  $v3Template=Join-Path $repoRoot 'templates\planning-workspace-projection-v3.example.json'
  foreach($template in @($v1Template,$v2Template,$v3Template)){
  if(-not(Get-Content -Raw $template|Test-Json -SchemaFile $schemaPath -ErrorAction Stop)){throw"Projection template does not conform to the shared schema: $template"}
  Test-MorphospacePlanningWorkspaceProjectionDocument $template|Out-Null
 }
 $d=Get-Content -Raw $v1Template|ConvertFrom-Json
 $temp=Join-Path ([IO.Path]::GetTempPath()) ('projection-'+[guid]::NewGuid().ToString('N')+'.json')
 $repo=Join-Path ([IO.Path]::GetTempPath()) ('projection-repo-'+[guid]::NewGuid().ToString('N'));$linked="$repo-linked"
 $fixture=Join-Path ([IO.Path]::GetTempPath()) ('projection-live-'+[guid]::NewGuid().ToString('N'))
 try{$d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8;Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null
  $d.source.repo_id=$d.planning.repo_id;$d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Same-repository projection was accepted.'}
  $d=Get-Content -Raw $v1Template|ConvertFrom-Json
  $d.source.upstream='origin/other';$d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Conflicting branch/upstream identity was accepted.'}
  $d=Get-Content -Raw $v1Template|ConvertFrom-Json
  $d|Add-Member -NotePropertyName projected_state -NotePropertyValue ([pscustomobject]@{current_unit=$null;next_ready_unit=$null;pending_push_bundle=$null;dirty_repository_ids=@('source-owner');source_repository=[pscustomobject]@{repo_id='source-owner';head=('1'*40);branch='main';dirty_fingerprint=('e'*64)}})
  $d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'V1 projection accepted a v2 projected-state binding.'}
  $d=Get-Content -Raw $v2Template|ConvertFrom-Json
  $d.projected_state.dirty_repository_ids=@('unrelated-owner')
  $d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'V2 projection accepted a dirty set that omitted the published source.'}
  $d=Get-Content -Raw $v2Template|ConvertFrom-Json
  $d.projected_state.dirty_repository_ids=@('source-owner',12)
  $d|ConvertTo-Json -Depth 16|Set-Content $temp -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $temp|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'V2 projection accepted a non-string dirty repository ID.'}
  foreach($acceptedPath in @('.gitattributes','receipts/.keep')){Test-PlanningProjectionRelativePath $acceptedPath 'Accepted dotfile path'}
  foreach($damagedPath in @('.','..','.git','.git/config','.git./config','.git.../config','receipts/.','receipts/.git/HEAD','receipts/../state.json','receipts//state.json','receipts\state.json')){
   $rejected=$false;try{Test-PlanningProjectionRelativePath $damagedPath 'Damaged path'}catch{$rejected=$true};if(-not$rejected){throw "Projection path guard accepted damaged path '$damagedPath'."}
  }
  New-Item -ItemType Directory $repo|Out-Null;git -C $repo init -q;git -C $repo config user.name fixture;git -C $repo config user.email fixture@example.invalid
  'x'|Set-Content (Join-Path $repo 'x.txt');git -C $repo add .;git -C $repo commit -q -m init;git -C $repo worktree add -q $linked
  if((Get-GitCommonDirectory $repo)-cne(Get-GitCommonDirectory $linked)){throw'Linked worktree Git identity was not detected.'}

  $source=Join-Path $fixture 'source';$remote=Join-Path $fixture 'source.git';$planning=Join-Path $fixture 'planning'
  New-Item -ItemType Directory $source,$planning|Out-Null;git -C $source init -q;git -C $source config user.name fixture;git -C $source config user.email fixture@example.invalid
  New-Item -ItemType Directory (Join-Path $source 'morphospace\receipts')|Out-Null
  '* -text'|Set-Content (Join-Path $source 'morphospace\.gitattributes') -Encoding utf8
  '{"project_id":"fixture"}'|Set-Content (Join-Path $source 'morphospace\project.spec.json') -Encoding utf8
  New-Item -ItemType File (Join-Path $source 'morphospace\empty.json')|Out-Null
  git -C $source add .;git -C $source commit -q -m old;$old=(git -C $source rev-parse HEAD).Trim()
  '{"project_id":"fixture","current_unit":null}'|Set-Content (Join-Path $source 'morphospace\workspace.state.json') -Encoding utf8
  git -C $source add .;git -C $source commit -q -m published;$published=(git -C $source rev-parse HEAD).Trim();git -C $source branch -M main
  git init -q --bare $remote;git -C $source remote add origin $remote;git -C $source push -q -u origin main
  git -C $planning init -q;git -C $planning config user.name fixture;git -C $planning config user.email fixture@example.invalid
  'planning'|Set-Content (Join-Path $planning 'README.md');git -C $planning add .;git -C $planning commit -q -m init
  $workspace=Join-Path $planning 'projects\fixture\morphospace';$projection=Join-Path $workspace 'receipts\projection.json'
  & (Join-Path $PSScriptRoot 'New-ExternalPlanningWorkspace.ps1') -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspace -ProjectionPath $projection -ProjectionId fixture-projection -ProjectId fixture -UnitId fixture-unit -SourceRepoId source-owner -PlanningRepoId planning-owner -Branch main -Upstream origin/main -OldRevision $old -PublishedRevision $published -Timestamp '2026-01-02T03:04:05Z' -Execute|Out-Null
  $generatedV1=Get-Content -Raw $projection|ConvertFrom-Json
  if([string]$generatedV1.schema-cne'rusty.morphospace.workflow.planning_workspace_projection.v1'-or$null-ne$generatedV1.planning.base_revision){throw'Default generator output is not unchanged v1 with a null planning base.'}
  if(@($generatedV1.inventory|Where-Object{[string]$_.path-ceq'.gitattributes'}).Count-ne1){throw'Generator omitted a canonical leading-dot workspace file.'}
  $closure=Join-Path $workspace 'receipts\closure.json';'{}'|Set-Content $closure -Encoding utf8
  Test-MorphospacePlanningWorkspaceProjectionLive -Path $projection -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspace -AllowedAdditivePaths @('receipts/closure.json')|Out-Null
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionLive -Path $projection -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspace|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Unbound additive file was accepted.'}
  '{}'|Set-Content (Join-Path $workspace 'unexpected.json') -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionLive -Path $projection -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspace -AllowedAdditivePaths @('receipts/closure.json')|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Unexpected additive file was accepted.'}
  git -C $planning add .;git -C $planning commit -q -m v1-projection-fixture;$planningBase=(git -C $planning rev-parse HEAD).Trim()

  $lockFingerprint='4142867dc0e3e62f910761aa5a24a75fc74400c34a33af1e38dee2fb9ab7f7be'
  $dirtyFingerprint='5152867dc0e3e62f910761aa5a24a75fc74400c34a33af1e38dee2fb9ab7f7bf'
  [ordered]@{schema='rusty.morphospace.workflow.feature_lock.v2';lock_fingerprint=$lockFingerprint}|ConvertTo-Json|Set-Content (Join-Path $source 'morphospace\feature.lock.json') -Encoding utf8
  [ordered]@{schema='rusty.morphospace.workflow.workspace_state.v2';current_unit=$null;next_ready_unit=$null;pending_push_bundle=$null;dirty_repositories=@('unrelated-owner','source-owner');repository_heads=@([ordered]@{repo_id='source-owner';head=$published;branch='main';dirty_fingerprint=$dirtyFingerprint})}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $source 'morphospace\workspace.state.json') -Encoding utf8
  git -C $source add .;git -C $source commit -q -m adoptable;$publishedV2=(git -C $source rev-parse HEAD).Trim();git -C $source push -q origin main
  $workspaceV2=Join-Path $planning 'projects\fixture-v2\morphospace';$projectionV2=Join-Path $workspaceV2 'receipts\projection.json'
  & (Join-Path $PSScriptRoot 'New-ExternalPlanningWorkspace.ps1') -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspaceV2 -ProjectionPath $projectionV2 -ProjectionId fixture-projection-v2 -ProjectId fixture-v2 -UnitId fixture-adoption -SourceRepoId source-owner -PlanningRepoId planning-owner -Branch main -Upstream origin/main -OldRevision $published -PublishedRevision $publishedV2 -Timestamp '2026-01-02T03:04:05Z' -ProjectionVersion v2 -Execute|Out-Null
  $generatedV2=Get-Content -Raw $projectionV2|ConvertFrom-Json
  if([string]$generatedV2.schema-cne'rusty.morphospace.workflow.planning_workspace_projection.v2'-or[string]$generatedV2.authority.next_transition-cne'AdoptPublishedPlanningAuthority'){throw'Explicit v2 generator output has the wrong discriminator or transition.'}
  if([string]$generatedV2.planning.base_revision-cne$planningBase){throw'V2 generator did not bind the clean local planning base HEAD.'}
  if((@($generatedV2.projected_state.dirty_repository_ids)-join'|')-cne'source-owner|unrelated-owner'-or[string]$generatedV2.projected_state.source_repository.head-cne$published-or[string]$generatedV2.projected_state.source_repository.dirty_fingerprint-cne$dirtyFingerprint){throw'V2 generator did not bind the exact stale published source state.'}
  Test-MorphospacePlanningWorkspaceProjectionLive -Path $projectionV2 -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspaceV2|Out-Null
  $projectionV2Raw=Get-Content -Raw $projectionV2
  $generatedV2.planning.base_revision=$null;$generatedV2|ConvertTo-Json -Depth 16|Set-Content $projectionV2 -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $projectionV2|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'V2 projection accepted a null planning base revision.'}
  Set-Content -LiteralPath $projectionV2 -Value $projectionV2Raw -NoNewline -Encoding utf8
  $generatedV2=$projectionV2Raw|ConvertFrom-Json
  $generatedV2.projected_state.source_repository.head=$publishedV2;$generatedV2|ConvertTo-Json -Depth 16|Set-Content $projectionV2 -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionDocument $projectionV2|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'V2 projection accepted a damaged published-source binding.'}
  Set-Content -LiteralPath $projectionV2 -Value $projectionV2Raw -NoNewline -Encoding utf8
  '{"adopted":true}'|Set-Content (Join-Path $workspaceV2 'workspace.state.json') -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionLive -Path $projectionV2 -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspaceV2|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'V2 projection silently accepted a replaced workspace state.'}
  Copy-Item -LiteralPath (Join-Path $source 'morphospace\workspace.state.json') -Destination (Join-Path $workspaceV2 'workspace.state.json') -Force
  '{"damaged":true}'|Set-Content (Join-Path $workspaceV2 'project.spec.json') -Encoding utf8
  $rejected=$false;try{Test-MorphospacePlanningWorkspaceProjectionLive -Path $projectionV2 -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspaceV2|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'V2 projection accepted damage to another projected file.'}
  Copy-Item -LiteralPath (Join-Path $source 'morphospace\project.spec.json') -Destination (Join-Path $workspaceV2 'project.spec.json') -Force
  git -C $planning add .;git -C $planning commit -q -m v2-projection-fixture

  New-Item -ItemType Directory (Join-Path $source 'morphospace\iteration-units') -Force|Out-Null
  [ordered]@{schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id='active-unit';project_id='fixture-v3';status='active'}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $source 'morphospace\iteration-units\active-unit.json') -Encoding utf8
  [ordered]@{schema='rusty.morphospace.workflow.workspace_state.v2';current_unit='active-unit';next_ready_unit=$null;pending_push_bundle=$null;dirty_repositories=@('source-owner');repository_heads=@([ordered]@{repo_id='source-owner';head=$publishedV2;branch='main';dirty_fingerprint=$dirtyFingerprint})}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $source 'morphospace\workspace.state.json') -Encoding utf8
  git -C $source add .;git -C $source commit -q -m active-state;$active=(git -C $source rev-parse HEAD).Trim();git -C $source push -q origin main
  $rejected=$false;try{& (Join-Path $PSScriptRoot 'New-ExternalPlanningWorkspace.ps1') -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot (Join-Path $planning 'projects\rejected\morphospace') -ProjectionPath (Join-Path $planning 'projects\rejected\morphospace\receipts\projection.json') -ProjectionId rejected-projection -ProjectId rejected-project -UnitId rejected-unit -SourceRepoId source-owner -PlanningRepoId planning-owner -Branch main -Upstream origin/main -OldRevision $publishedV2 -PublishedRevision $active -ProjectionVersion v2|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'V2 generator accepted a published workspace with an active current unit.'}
  $workspaceV3=Join-Path $planning 'projects\fixture-v3\morphospace';$projectionV3=Join-Path $workspaceV3 'receipts\projection.json'
  & (Join-Path $PSScriptRoot 'New-ExternalPlanningWorkspace.ps1') -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspaceV3 -ProjectionPath $projectionV3 -ProjectionId fixture-projection-v3 -ProjectId fixture-v3 -UnitId active-unit -SourceRepoId source-owner -PlanningRepoId planning-owner -Branch main -Upstream origin/main -OldRevision $publishedV2 -PublishedRevision $active -Timestamp '2026-01-02T03:04:05Z' -ProjectionVersion v3 -Execute|Out-Null
  $generatedV3=Get-Content -Raw $projectionV3|ConvertFrom-Json
  if([string]$generatedV3.schema-cne'rusty.morphospace.workflow.planning_workspace_projection.v3'-or[string]$generatedV3.projected_state.current_unit-cne'active-unit'-or[string]$generatedV3.chronology.classification-cne'published-embedded-active-workspace-authority-adoption'){throw'Explicit v3 generator did not bind the exact active workspace.'}
  Test-MorphospacePlanningWorkspaceProjectionLive -Path $projectionV3 -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspaceV3|Out-Null
  git -C $planning add .;git -C $planning commit -q -m v3-projection-fixture
  [IO.File]::WriteAllBytes((Join-Path $source 'morphospace\workspace.state.json'),[byte[]](0xff,0xfe,0xfd))
  git -C $source add .;git -C $source commit -q -m invalid-utf8;$invalidUtf8=(git -C $source rev-parse HEAD).Trim();git -C $source push -q origin main
  $rejected=$false;try{& (Join-Path $PSScriptRoot 'New-ExternalPlanningWorkspace.ps1') -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot (Join-Path $planning 'projects\invalid-utf8\morphospace') -ProjectionPath (Join-Path $planning 'projects\invalid-utf8\morphospace\receipts\projection.json') -ProjectionId invalid-utf8-projection -ProjectId invalid-utf8-project -UnitId invalid-utf8-unit -SourceRepoId source-owner -PlanningRepoId planning-owner -Branch main -Upstream origin/main -OldRevision $active -PublishedRevision $invalidUtf8 -ProjectionVersion v2|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'V2 generator accepted invalid UTF-8 projected state.'}
  Write-Host 'Planning-workspace projection self-test passed.'
 }finally{if(Test-Path $linked){git -C $repo worktree remove --force $linked 2>$null};if(Test-Path $repo){Remove-Item -LiteralPath $repo -Recurse -Force};if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force};if(Test-Path $temp){Remove-Item -LiteralPath $temp -Force}}
 return
}
if(-not$Path){throw'Path is required.'}
if($SourceRepository){Test-MorphospacePlanningWorkspaceProjectionLive -Path $Path -SourceRepository $SourceRepository -PlanningRepository $PlanningRepository -WorkspaceRoot $WorkspaceRoot|ConvertTo-Json -Depth 16}
else{Test-MorphospacePlanningWorkspaceProjectionDocument $Path|ConvertTo-Json -Depth 16}
