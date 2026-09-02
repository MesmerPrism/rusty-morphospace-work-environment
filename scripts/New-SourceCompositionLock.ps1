param(
    [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
    [Parameter(Mandatory=$true)][string]$UnitId,
    [Parameter(Mandatory=$true)][string]$RepositoryMapPath,
    [string[]]$RepoId = @(),
    [string]$OutRelativePath = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceSourceCompositionIdentity.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceProtocolCommon.psm1") -Force

function Invoke-ExactGit { param([string]$Root,[string[]]$Arguments) $out=@(& git --no-optional-locks --no-pager --no-replace-objects -c core.pager=cat -C $Root @Arguments 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "Git query failed in '$Root': git $($Arguments -join ' ')"};return @($out) }

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$spec = MorphospaceProtocolCommon\Read-MorphospaceProtocolJson -Path (Join-Path $workspace "project.spec.json")
$unit = MorphospaceProtocolCommon\Read-MorphospaceProtocolJson -Path (Join-Path $workspace (Join-Path "iteration-units" "$UnitId.json"))
$map = MorphospaceProtocolCommon\Read-MorphospaceProtocolJson -Path $RepositoryMapPath
if ([string]$spec.project_id -ne [string]$unit.project_id -or [string]$unit.unit_id -ne $UnitId) { throw "Project and unit identity do not agree." }
$selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($id in @($RepoId)){if(-not[string]::IsNullOrWhiteSpace($id)){[void]$selected.Add($id)}}
$records = [Collections.Generic.List[object]]::new();$paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($entry in @($map.repositories|Sort-Object repo_id)){
    $id=[string]$entry.repo_id;if($selected.Count-gt0-and-not$selected.Contains($id)){continue}
    $root=[IO.Path]::GetFullPath([string]$entry.path);if(-not[IO.Directory]::Exists($root)){throw "Mapped repository is missing: $id ($root)"}
    $status=@(Invoke-ExactGit $root @("status","--porcelain=v1","--untracked-files=all"));if($status.Count-gt0){throw "Source composition repository is not completely clean: $id"}
    $commit=([string]@(Invoke-ExactGit $root @("rev-parse","HEAD"))[0]).Trim().ToLowerInvariant();$tree=([string]@(Invoke-ExactGit $root @("rev-parse","HEAD^{tree}"))[0]).Trim().ToLowerInvariant()
    if($commit-notmatch'^[0-9a-f]{40}$'-or$tree-notmatch'^[0-9a-f]{40}$'){throw "Source composition repository lacks an exact commit/tree: $id"}
    $branchText=([string]@(Invoke-ExactGit $root @("rev-parse","--abbrev-ref","HEAD"))[0]).Trim();$branch=if($branchText-eq"HEAD"){$null}else{$branchText}
    $remote=@(& git --no-optional-locks --no-pager --no-replace-objects -c core.pager=cat -C $root remote get-url origin 2>$null);$remoteUrl=if($LASTEXITCODE-eq0-and$remote.Count-gt0){([string]$remote[0]).Trim()}else{$null}
    $materializationPath=Split-Path -Leaf $root;if($materializationPath-notmatch'^[A-Za-z0-9._-]+$'){throw "Repository leaf cannot be used as a portable materialization path: $materializationPath"};if(-not$paths.Add($materializationPath)){throw "Duplicate source materialization path: $materializationPath"}
    $records.Add([pscustomobject][ordered]@{repo_id=$id;role=[string]$entry.role;commit=$commit;tree=$tree;branch=$branch;remote_url=$remoteUrl;materialization_path=$materializationPath;tracked_worktree_clean=$true})|Out-Null
}
if($records.Count-eq0){throw "Source composition selected no repositories."}
$fingerprint=MorphospaceSourceCompositionIdentity\Get-MorphospaceSourceCompositionFingerprint -ProjectId ([string]$spec.project_id) -UnitId $UnitId -Repositories @($records.ToArray())
$lock=[pscustomobject][ordered]@{schema="rusty.morphospace.workflow.source_composition_lock.v1";lock_id="$UnitId-source-$($fingerprint.Substring(0,12))";created_at=[DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ");project_id=[string]$spec.project_id;unit_id=$UnitId;fingerprint=$fingerprint;repositories=@($records.ToArray());status="locked";does_not_prove=@("Does not accept the iteration unit, enable a feature, claim a device, or authorize publication.","Does not include uncommitted tracked changes or untracked files.")}
if(-not$Execute){$lock|ConvertTo-Json -Depth 12;return}
if([string]::IsNullOrWhiteSpace($OutRelativePath)){$OutRelativePath="source-compositions/$UnitId-$fingerprint.lock.json"}
MorphospaceProtocolCommon\Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath $OutRelativePath -Value $lock -NoOverwrite
$lock|ConvertTo-Json -Depth 12
