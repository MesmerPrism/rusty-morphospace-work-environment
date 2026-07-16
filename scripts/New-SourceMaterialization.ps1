param(
    [Parameter(Mandatory=$true)][string]$LockPath,
    [Parameter(Mandatory=$true)][string]$RepositoryMapPath,
    [Parameter(Mandatory=$true)][string]$MaterializationRoot,
    [switch]$Execute
)

$ErrorActionPreference="Stop"
Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceProtocolCommon.psm1") -Force
function Invoke-GitChecked{param([string]$Root,[string[]]$Arguments)$out=@(& git -C $Root @Arguments 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "Git failed in '$Root': git $($Arguments -join ' ')`n$($out-join"`n")"};return @($out)}
$lock=Read-MorphospaceProtocolJson -Path $LockPath;$map=Read-MorphospaceProtocolJson -Path $RepositoryMapPath
if([string]$lock.schema-ne"rusty.morphospace.workflow.source_composition_lock.v1"-or[string]$lock.status-ne"locked"){throw "Unsupported source composition lock."}
$mapById=@{};foreach($entry in @($map.repositories)){$mapById[[string]$entry.repo_id]=$entry}
$base=[IO.Path]::GetFullPath($MaterializationRoot);$address=([string]$lock.fingerprint).Substring(0,24);$final=Join-Path $base $address;$pending=Join-Path $base (".pending-$address-"+$([guid]::NewGuid().ToString('N').Substring(0,8)))
$plan=[pscustomobject][ordered]@{schema="rusty.morphospace.workflow.source_materialization_plan.v1";lock_fingerprint=[string]$lock.fingerprint;root=$final;repositories=@($lock.repositories|ForEach-Object{[pscustomobject][ordered]@{repo_id=[string]$_.repo_id;source=if($mapById.ContainsKey([string]$_.repo_id)){[string]$mapById[[string]$_.repo_id].path}else{$null};target=Join-Path $final ([string]$_.materialization_path);commit=[string]$_.commit}})}
if(-not$Execute){$plan|ConvertTo-Json -Depth 10;return}
if([IO.Directory]::Exists($final)){throw "Content-addressed source materialization already exists: $final"}
[void][IO.Directory]::CreateDirectory($base);$basePrefix=$base.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
if(-not([IO.Path]::GetFullPath($pending).StartsWith($basePrefix,[StringComparison]::OrdinalIgnoreCase))){throw "Pending materialization escapes its root."}
[void][IO.Directory]::CreateDirectory($pending)
try{
    $receipts=[Collections.Generic.List[object]]::new()
    foreach($repo in @($lock.repositories)){
        $id=[string]$repo.repo_id;if(-not$mapById.ContainsKey($id)){throw "Source composition repository is not mapped: $id"};$source=[IO.Path]::GetFullPath([string]$mapById[$id].path);$target=Join-Path $pending ([string]$repo.materialization_path)
        $cloneOutput=@(& git clone --quiet --no-checkout --shared $source $target 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "Could not clone exact source repository: $id`n$($cloneOutput-join"`n")"}
        Invoke-GitChecked $target @("checkout","--quiet","--detach",[string]$repo.commit)|Out-Null
        $head=([string]@(Invoke-GitChecked $target @("rev-parse","HEAD"))[0]).Trim().ToLowerInvariant();$tree=([string]@(Invoke-GitChecked $target @("rev-parse","HEAD^{tree}"))[0]).Trim().ToLowerInvariant();$status=@(Invoke-GitChecked $target @("status","--porcelain=v1","--untracked-files=all"));$branch=([string]@(Invoke-GitChecked $target @("rev-parse","--abbrev-ref","HEAD"))[0]).Trim()
        if($head-ne[string]$repo.commit-or$tree-ne[string]$repo.tree-or$status.Count-ne0-or$branch-ne"HEAD"){throw "Exact source materialization verification failed: $id"}
        $receipts.Add([pscustomobject][ordered]@{repo_id=$id;path=Join-Path $final ([string]$repo.materialization_path);commit=$head;tree=$tree;detached=$true;clean=$true})|Out-Null
    }
    $meta=Join-Path $pending "_morphospace";[void][IO.Directory]::CreateDirectory($meta)
    $receipt=[pscustomobject][ordered]@{schema="rusty.morphospace.workflow.source_materialization_receipt.v1";materialization_id="materialization-$([string]$lock.fingerprint)";created_at=[DateTime]::UtcNow.ToString("o");lock=[pscustomobject][ordered]@{path=[IO.Path]::GetFullPath($LockPath);sha256=Get-MorphospaceFileSha256 -Path $LockPath;fingerprint=[string]$lock.fingerprint};root=$final;repositories=@($receipts.ToArray());status="materialized"}
    [IO.File]::WriteAllText((Join-Path $meta "materialization.json"),(ConvertTo-MorphospaceCanonicalJson -Value $receipt)+"`n",[Text.UTF8Encoding]::new($false))
    [IO.Directory]::Move($pending,$final);$receipt|ConvertTo-Json -Depth 12
}catch{if([IO.Directory]::Exists($pending)-and[IO.Path]::GetFullPath($pending).StartsWith($basePrefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $pending -Recurse -Force};throw}
