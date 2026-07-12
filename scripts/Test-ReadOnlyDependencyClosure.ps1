param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$RepositoryMapPath,
    [Parameter(Mandatory = $true)][string]$ClosurePath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Read-ClosureJson { param([string]$Path) try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { throw "Invalid closure JSON '$Path': $($_.Exception.Message)" } }
function Get-ClosureGit { param([string]$Root,[string[]]$Arguments) $lines=@(& git -C $Root @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "Git query failed in '$Root': git $($Arguments -join ' ')"};return @($lines|ForEach-Object{[string]$_}) }

$workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$closureAbsolute=[IO.Path]::GetFullPath($ClosurePath);$workspacePrefix=$workspace.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
if(-not $closureAbsolute.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Closure must stay inside the project workspace.'}
$unit=Read-ClosureJson (Join-Path $workspace (Join-Path 'iteration-units' "$UnitId.json"));$closure=Read-ClosureJson $closureAbsolute;$map=Read-ClosureJson $RepositoryMapPath
if([string]$closure.schema-ne'rusty.morphospace.workflow.read_only_dependency_closure.v1'-or[string]$closure.project_id-ne[string]$unit.project_id-or[string]$closure.unit_id-ne$UnitId-or[string]$closure.status-ne'captured'){throw 'Closure identity or status is invalid.'}
$mapById=@{};foreach($repo in @($map.repositories)){$mapById[[string]$repo.repo_id]=$repo};$unitById=@{};foreach($dependency in @($unit.read_only_dependencies)){$unitById[[string]$dependency.repo_id]=$dependency}
foreach($dependency in @($closure.dependencies)){
    $repoId=[string]$dependency.repo_id;if(-not $mapById.ContainsKey($repoId)-or-not $unitById.ContainsKey($repoId)){throw "Closure dependency '$repoId' is no longer declared and mapped."}
    $root=[IO.Path]::GetFullPath([string]$mapById[$repoId].path);$head=([string](@(Get-ClosureGit $root @('rev-parse','HEAD'))[0])).Trim().ToLowerInvariant();$branch=([string](@(Get-ClosureGit $root @('rev-parse','--abbrev-ref','HEAD'))[0])).Trim()
    if($head-ne[string]$dependency.head-or$branch-ne[string]$dependency.branch){throw "Closure repository identity drifted: $repoId"}
    foreach($file in @($dependency.files)){
        $relative=ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$file.path);$absolute=[IO.Path]::GetFullPath((Join-Path $root $relative));$prefix=$root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-or-not[IO.File]::Exists($absolute)){throw "Closure file is absent or escapes its repository: $repoId/$relative"}
        $info=[IO.FileInfo]::new($absolute);if([long]$info.Length-ne[long]$file.length-or(Get-MorphospaceFileSha256 -Path $absolute)-ne[string]$file.worktree_sha256){throw "Closure file hash drifted: $repoId/$relative"}
        $index=@(Get-ClosureGit $root @('ls-files','--stage','--',$relative));$indexBlob=if($index.Count-eq0){$null}elseif($index[0]-match'^[0-7]+\s+([0-9a-f]{40})\s+[0-3]\t'){$Matches[1].ToLowerInvariant()}else{throw "Could not parse Git index row for '$relative'."};if($indexBlob-ne$file.index_blob_sha256){throw "Closure index blob drifted: $repoId/$relative"}
        $headBlob=@(& git -C $root rev-parse --verify --quiet ("HEAD:"+$relative) 2>$null);if($LASTEXITCODE-ne0){$headBlob=$null}else{$headBlob=[string]$headBlob[0]};if($headBlob-ne$file.head_blob_sha256){throw "Closure HEAD blob drifted: $repoId/$relative"}
        $status=@(Get-ClosureGit $root @('status','--porcelain=v1','--untracked-files=all','--',$relative)|Sort-Object);if((@($status)-join"`n")-ne(@($file.status_porcelain|Sort-Object)-join"`n")){throw "Closure working-tree status drifted: $repoId/$relative"}
    }
}
[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.read_only_dependency_closure_verification.v1';project_id=[string]$unit.project_id;unit_id=$UnitId;closure_path=$closureAbsolute;status='pass'}|ConvertTo-Json -Depth 8
