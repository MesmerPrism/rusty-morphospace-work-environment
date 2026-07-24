param(
    [Parameter(Mandatory)][string]$SourceRepository,[Parameter(Mandatory)][string]$PlanningRepository,
    [Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ProjectionPath,
    [Parameter(Mandatory)][string]$ProjectionId,[Parameter(Mandatory)][string]$ProjectId,[Parameter(Mandatory)][string]$UnitId,
    [Parameter(Mandatory)][string]$SourceRepoId,[Parameter(Mandatory)][string]$PlanningRepoId,
    [Parameter(Mandatory)][string]$Branch,[Parameter(Mandatory)][string]$Upstream,
    [Parameter(Mandatory)][string]$OldRevision,[Parameter(Mandatory)][string]$PublishedRevision,
    [string]$EmbeddedWorkspacePath='morphospace',[string]$Timestamp='',[switch]$Execute
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlanningProjection.psm1') -Force
$source=[IO.Path]::GetFullPath($SourceRepository).TrimEnd('\','/');$planning=[IO.Path]::GetFullPath($PlanningRepository).TrimEnd('\','/')
$workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');$projection=[IO.Path]::GetFullPath($ProjectionPath)
if($source-ceq$planning){throw'Source and planning repositories must be distinct.'}
if((Get-GitCommonDirectory $source)-ceq(Get-GitCommonDirectory $planning)){throw'Source and planning repositories share Git common-directory authority.'}
if(-not$workspace.StartsWith($planning+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw'WorkspaceRoot must be inside PlanningRepository.'}
if(-not$projection.StartsWith($workspace+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw'ProjectionPath must be inside WorkspaceRoot.'}
if(Test-Path -LiteralPath $workspace){throw'WorkspaceRoot already exists; projection is one-time and no-overwrite.'}
& git -C $source merge-base --is-ancestor $OldRevision $PublishedRevision 2>$null;if($LASTEXITCODE-ne0){throw'OldRevision is not an ancestor of PublishedRevision.'}
$remote=($Upstream-split'/',2)[0];$branchPart=($Upstream-split'/',2)[1];if(-not$branchPart){throw'Upstream must name remote/branch.'};$remoteRef="refs/heads/$branchPart"
$readback=Get-FreshRemoteRevision $source $remote $remoteRef
if($readback-cne$PublishedRevision){throw'Fresh remote readback does not equal PublishedRevision.'}
$tree=(& git -C $source rev-parse "$PublishedRevision`:$EmbeddedWorkspacePath").Trim();if($LASTEXITCODE-ne0){throw'Embedded workspace is absent at PublishedRevision.'}
$inventory=@(Get-GitWorkspaceInventory $source $PublishedRevision $EmbeddedWorkspacePath)
if(-not$Timestamp){$Timestamp=(Get-Date).ToUniversalTime().ToString('o')}
$relativeWorkspace=$workspace.Substring($planning.Length+1).Replace('\','/')
$relativeProjection=$projection.Substring($workspace.Length+1).Replace('\','/')
Test-PlanningProjectionRelativePath $relativeProjection 'Projection record path'
if(@($inventory|Where-Object{$_.path-ceq$relativeProjection}).Count-ne0){throw'ProjectionPath collides with a published workspace file.'}
$document=[ordered]@{
 '$schema'='../schemas/planning-workspace-projection.schema.json';schema='rusty.morphospace.workflow.planning_workspace_projection.v1'
 projection_id=$ProjectionId;project_id=$ProjectId;unit_id=$UnitId;recorded_at=$Timestamp;status='exact-projection-verified'
 chronology=[ordered]@{classification='embedded-workspace-projected-after-source-publication';source_publication_preceded_projection=$true;prepared_plan_present=$false;executed_push_receipt_present=$false;does_not_claim=@('prospective preparation','planning-last publication','source acceptance','Git execution')}
 source=[ordered]@{repo_id=$SourceRepoId;branch=$Branch;remote=$remote;remote_ref=$remoteRef;upstream=$Upstream;old_revision=$OldRevision;published_revision=$PublishedRevision;observed_remote_revision=$readback;embedded_workspace_path=$EmbeddedWorkspacePath;embedded_workspace_tree=$tree;fast_forward_verified=$true;remote_match=$true;force_push_used=$false}
 planning=[ordered]@{repo_id=$PlanningRepoId;workspace_path=$relativeWorkspace;projection_record_path=$relativeProjection;distinct_from_source=$true;base_revision=$null}
 inventory=@($inventory|ForEach-Object{[ordered]@{path=$_.path;git_mode=$_.git_mode;size=$_.size;sha256=$_.sha256}})
 authority=[ordered]@{source_workspace='immutable-historical-snapshot';external_workspace='sole-mutable-workflow-authority';source_workflow_mutation_performed=$false;git_mutation_performed=$false;next_transition='ReconcilePublication'}
 failure=$null
}
if(-not$Execute){$document|ConvertTo-Json -Depth 16;return}
[IO.Directory]::CreateDirectory($workspace)|Out-Null
foreach($row in $inventory){$target=Join-Path $workspace $row.path;$parent=Split-Path -Parent $target;[IO.Directory]::CreateDirectory($parent)|Out-Null;$bytes=Get-GitBlobBytes $source $row.blob;[IO.File]::WriteAllBytes($target,$bytes)}
[IO.Directory]::CreateDirectory((Split-Path -Parent $projection))|Out-Null
$document|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $projection -Encoding utf8
Test-MorphospacePlanningWorkspaceProjectionLive -Path $projection -SourceRepository $source -PlanningRepository $planning -WorkspaceRoot $workspace|ConvertTo-Json -Depth 8
