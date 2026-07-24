Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-PlanningProjectionSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Test-PlanningProjectionRelativePath([string]$Path, [string]$Context) {
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)' -or
        $Path -match '\\' -or $Path -notmatch '^[a-z0-9][a-z0-9._/-]*$') {
        throw "$Context is not a canonical portable relative path."
    }
}
function Get-PlanningProjectionDocument([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Invalid planning-workspace projection JSON: $($_.Exception.Message)" }
}
function Get-GitBlobBytes([string]$RepositoryPath, [string]$Blob) {
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    $psi.WorkingDirectory = $RepositoryPath
    foreach ($argument in @('cat-file', 'blob', $Blob)) { [void]$psi.ArgumentList.Add($argument) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($psi)
    $memory = [IO.MemoryStream]::new()
    try {
        $process.StandardOutput.BaseStream.CopyTo($memory); $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git cat-file failed: $($process.StandardError.ReadToEnd())" }
        return $memory.ToArray()
    } finally { $memory.Dispose(); $process.Dispose() }
}
function Get-GitWorkspaceInventory([string]$RepositoryPath, [string]$Revision, [string]$Prefix) {
    Test-PlanningProjectionRelativePath $Prefix 'Embedded workspace path'
    $rows = New-Object System.Collections.Generic.List[object]
    $output = & git -C $RepositoryPath ls-tree -r -l $Revision -- $Prefix 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { throw 'Published revision does not contain the embedded workspace.' }
    foreach ($line in @($output)) {
        if ($line -notmatch '^([0-9]{6}) blob ([0-9a-f]{40})\s+([0-9-]+)\t(.+)$') { throw "Unsupported Git tree entry: $line" }
        $mode=$matches[1];$blob=$matches[2];$size=[int64]$matches[3];$full=$matches[4].Replace('\','/')
        if ($mode -notin @('100644','100755')) { throw "Embedded workspace contains unsupported mode '$mode'." }
        $relative=$full.Substring($Prefix.TrimEnd('/').Length).TrimStart('/')
        Test-PlanningProjectionRelativePath $relative 'Projected file path'
        $bytes=Get-GitBlobBytes $RepositoryPath $blob
        $hash=[Security.Cryptography.SHA256]::HashData($bytes)
        $rows.Add([pscustomobject][ordered]@{path=$relative;git_mode=$mode;size=$size;sha256=[Convert]::ToHexString($hash).ToLowerInvariant();blob=$blob})|Out-Null
    }
    return @($rows | Sort-Object path)
}
function Get-GitCommonDirectory([string]$RepositoryPath) {
    $value=(& git -C $RepositoryPath rev-parse --path-format=absolute --git-common-dir).Trim()
    if($LASTEXITCODE-ne0-or-not$value){throw"Repository is not an available Git repository: $RepositoryPath"}
    return [IO.Path]::GetFullPath($value).TrimEnd('\','/')
}
function Get-FreshRemoteRevision([string]$RepositoryPath,[string]$Remote,[string]$RemoteRef) {
    $rows=@(& git -C $RepositoryPath ls-remote --exit-code $Remote $RemoteRef 2>$null)
    if($LASTEXITCODE-ne0-or$rows.Count-ne1-or$rows[0]-notmatch'^([0-9a-f]{40})\s+(.+)$'-or$matches[2]-cne$RemoteRef){throw"Fresh remote readback failed for $Remote $RemoteRef."}
    return $matches[1]
}
function Test-MorphospacePlanningWorkspaceProjectionDocument {
    param([Parameter(Mandatory)][string]$Path)
    $document=Get-PlanningProjectionDocument $Path
    if([string]$document.schema-cne'rusty.morphospace.workflow.planning_workspace_projection.v1'){throw'Planning-workspace projection has the wrong schema.'}
    if([string]$document.status-cne'exact-projection-verified'-or[string]$document.chronology.classification-cne'embedded-workspace-projected-after-source-publication'){throw'Planning-workspace projection chronology/status is invalid.'}
    if($document.chronology.source_publication_preceded_projection-ne$true-or$document.chronology.prepared_plan_present-ne$false-or$document.chronology.executed_push_receipt_present-ne$false){throw'Planning-workspace projection fabricates publication chronology.'}
    if([string]$document.source.repo_id-ceq[string]$document.planning.repo_id-or$document.planning.distinct_from_source-ne$true){throw'Source and planning repositories must be distinct.'}
    if([string]$document.source.old_revision-ceq[string]$document.source.published_revision-or[string]$document.source.published_revision-cne[string]$document.source.observed_remote_revision){throw'Projection does not bind one real published advance.'}
    if($document.source.fast_forward_verified-ne$true-or$document.source.remote_match-ne$true-or$document.source.force_push_used-ne$false){throw'Projection does not bind clean no-force readback.'}
    foreach($p in @([string]$document.source.embedded_workspace_path,[string]$document.planning.workspace_path,[string]$document.planning.projection_record_path)){Test-PlanningProjectionRelativePath $p 'Projection workspace path'}
    $upstreamParts=@([string]$document.source.upstream -split '/',2)
    if($upstreamParts.Count-ne2-or$upstreamParts[0]-cne[string]$document.source.remote-or$upstreamParts[1]-cne[string]$document.source.branch-or[string]$document.source.remote_ref-cne"refs/heads/$([string]$document.source.branch)"){throw'Projection branch, remote, upstream, and remote ref are inconsistent.'}
    $paths=@($document.inventory|ForEach-Object{[string]$_.path})
    foreach($p in $paths){Test-PlanningProjectionRelativePath $p 'Projection inventory path'}
    if((@($paths|Sort-Object -Unique).Count-ne$paths.Count)-or(($paths-join'|')-cne(@($paths|Sort-Object)-join'|'))){throw'Projection inventory paths must be unique and ordinally sorted.'}
    if(@($document.chronology.does_not_claim).Count-lt4){throw'Projection must retain all material nonclaims.'}
    if([string]$document.authority.source_workspace-cne'immutable-historical-snapshot'-or[string]$document.authority.external_workspace-cne'sole-mutable-workflow-authority'-or$document.authority.source_workflow_mutation_performed-ne$false-or$document.authority.git_mutation_performed-ne$false-or[string]$document.authority.next_transition-cne'ReconcilePublication'){throw'Projection authority boundary is invalid.'}
    return [pscustomobject][ordered]@{document=$document;sha256=Get-PlanningProjectionSha256 $Path}
}
function Test-MorphospacePlanningWorkspaceProjectionLive {
    param(
        [Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$SourceRepository,
        [Parameter(Mandatory)][string]$PlanningRepository,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [string[]]$AllowedAdditivePaths=@()
    )
    $validated=Test-MorphospacePlanningWorkspaceProjectionDocument $Path;$d=$validated.document
    $sourceRoot=[IO.Path]::GetFullPath($SourceRepository).TrimEnd('\','/');$planningRoot=[IO.Path]::GetFullPath($PlanningRepository).TrimEnd('\','/')
    if($sourceRoot-ceq$planningRoot){throw'Source and planning repositories resolve to the same root.'}
    if((Get-GitCommonDirectory $sourceRoot)-ceq(Get-GitCommonDirectory $planningRoot)){throw'Source and planning repositories share Git common-directory authority.'}
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');$planningPrefix=$planningRoot+[IO.Path]::DirectorySeparatorChar
    if(-not$workspace.StartsWith($planningPrefix,[StringComparison]::OrdinalIgnoreCase)){throw'Projected workspace is outside the planning repository.'}
    $relativeWorkspace=$workspace.Substring($planningRoot.Length+1).Replace('\','/')
    if($relativeWorkspace-cne[string]$d.planning.workspace_path){throw'Projected workspace does not match the declared planning workspace path.'}
    $projectionFull=[IO.Path]::GetFullPath($Path)
    $workspacePrefix=$workspace+[IO.Path]::DirectorySeparatorChar
    if(-not$projectionFull.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)){throw'Projection record is outside the projected workspace.'}
    $relativeProjection=$projectionFull.Substring($workspace.Length+1).Replace('\','/')
    if($relativeProjection-cne[string]$d.planning.projection_record_path){throw'Projection record path does not match the declared additive evidence path.'}
    $tree=(& git -C $sourceRoot rev-parse "$([string]$d.source.published_revision):$([string]$d.source.embedded_workspace_path)").Trim()
    if($LASTEXITCODE-ne0-or$tree-cne[string]$d.source.embedded_workspace_tree){throw'Embedded workspace tree does not match the published revision.'}
    & git -C $sourceRoot merge-base --is-ancestor ([string]$d.source.old_revision) ([string]$d.source.published_revision) 2>$null
    if($LASTEXITCODE-ne0){throw'Projection old revision is not an ancestor of the published revision.'}
    $fresh=Get-FreshRemoteRevision $sourceRoot ([string]$d.source.remote) ([string]$d.source.remote_ref)
    if($fresh-cne[string]$d.source.published_revision){throw'Fresh source remote readback no longer equals the projected publication.'}
    $actual=@(Get-GitWorkspaceInventory $sourceRoot ([string]$d.source.published_revision) ([string]$d.source.embedded_workspace_path))
    if($actual.Count-ne@($d.inventory).Count){throw'Projected workspace inventory count differs from the published tree.'}
    for($i=0;$i-lt$actual.Count;$i++){
        $expected=$d.inventory[$i];$row=$actual[$i]
        if([string]$expected.path-cne[string]$row.path-or[string]$expected.git_mode-cne[string]$row.git_mode-or[int64]$expected.size-ne[int64]$row.size-or[string]$expected.sha256-cne[string]$row.sha256){throw"Projection inventory differs at '$($row.path)'."}
        $target=Join-Path $workspace ([string]$row.path)
        if(-not(Test-Path -LiteralPath $target -PathType Leaf)-or(Get-PlanningProjectionSha256 $target)-cne[string]$row.sha256){throw"Projected file differs from published bytes: $($row.path)"}
    }
    $destinationFiles=@(Get-ChildItem -LiteralPath $workspace -File -Recurse -Force|ForEach-Object{
        if($_.Attributes-band[IO.FileAttributes]::ReparsePoint){throw"Projected workspace contains a reparse-point file: $($_.FullName)"}
        $_.FullName.Substring($workspace.Length+1).Replace('\','/')
    }|Sort-Object)
    $destinationDirectories=@(Get-ChildItem -LiteralPath $workspace -Directory -Recurse -Force)
    foreach($directory in $destinationDirectories){if($directory.Attributes-band[IO.FileAttributes]::ReparsePoint){throw"Projected workspace contains a reparse-point directory: $($directory.FullName)"}}
    $allowedAdditiveSet=@{}
    foreach($allowedPath in @($AllowedAdditivePaths)){
        Test-PlanningProjectionRelativePath $allowedPath 'Allowed additive path'
        if($allowedPath-ceq$relativeProjection-or@($actual|Where-Object{$_.path-ceq$allowedPath}).Count-ne0-or$allowedAdditiveSet.ContainsKey($allowedPath)){
            throw"Allowed additive path conflicts with projected evidence: $allowedPath"
        }
        $allowedAdditiveSet[$allowedPath]=$true
    }
    $expectedFiles=@(@($actual|ForEach-Object{$_.path})+$relativeProjection+@($allowedAdditiveSet.Keys)|Sort-Object)
    if(($destinationFiles-join'|')-cne($expectedFiles-join'|')){throw'Projected workspace contains missing or additional files beyond the exact source inventory and bound projection record.'}
    return $validated
}
Export-ModuleMember -Function Get-GitWorkspaceInventory,Get-GitBlobBytes,Get-GitCommonDirectory,Get-FreshRemoteRevision,Test-PlanningProjectionRelativePath,Test-MorphospacePlanningWorkspaceProjectionDocument,Test-MorphospacePlanningWorkspaceProjectionLive
