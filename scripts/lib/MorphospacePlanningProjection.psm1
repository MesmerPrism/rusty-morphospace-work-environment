Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-PlanningProjectionSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Test-PlanningProjectionRelativePath([string]$Path, [string]$Context) {
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)' -or
        $Path -match '\\' -or $Path -notmatch '^[a-z0-9.][a-z0-9._/-]*$') {
        throw "$Context is not a canonical portable relative path."
    }
    $segments = @($Path -split '/')
    if ($segments.Count -eq 0 -or @($segments | Where-Object {
        [string]::IsNullOrEmpty($_) -or $_ -ceq '.' -or $_ -ceq '..' -or
        $_.TrimEnd('.') -ceq '.git'
    }).Count -ne 0) {
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
        return ,$memory.ToArray()
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
function Get-GitWorkspaceJsonDocument(
    [string]$RepositoryPath,
    [string]$Revision,
    [string]$Prefix,
    [string]$RelativePath,
    [string]$Context
) {
    Test-PlanningProjectionRelativePath $Prefix 'Embedded workspace path'
    Test-PlanningProjectionRelativePath $RelativePath "$Context path"
    $gitPath = "$($Prefix.TrimEnd('/'))/$RelativePath"
    $blob = (& git -C $RepositoryPath rev-parse "$Revision`:$gitPath" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $blob -notmatch '^[0-9a-f]{40}$') {
        throw "$Context is absent from the published embedded workspace."
    }
    try {
        $bytes = Get-GitBlobBytes $RepositoryPath $blob
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        return $utf8.GetString($bytes) | ConvertFrom-Json
    } catch {
        throw "$Context is not valid UTF-8 JSON: $($_.Exception.Message)"
    }
}
function Get-PublishedProjectionStateBinding(
    [string]$RepositoryPath,
    [string]$Revision,
    [string]$Prefix,
    [string]$SourceRepoId
) {
    $state = Get-GitWorkspaceJsonDocument $RepositoryPath $Revision $Prefix 'workspace.state.json' 'Projected workspace state'
    foreach ($property in @('current_unit', 'next_ready_unit', 'pending_push_bundle', 'dirty_repositories', 'repository_heads')) {
        if ($state.PSObject.Properties.Name -cnotcontains $property) {
            throw "Projected workspace state is missing '$property'."
        }
    }
    if ($null -ne $state.current_unit -or $null -ne $state.next_ready_unit -or $null -ne $state.pending_push_bundle) {
        throw 'Published authority adoption requires null current_unit, next_ready_unit, and pending_push_bundle.'
    }
    $dirtyValues = @($state.dirty_repositories)
    if (@($dirtyValues | Where-Object { $_ -isnot [string] }).Count -ne 0) {
        throw 'Published authority adoption requires string dirty repository IDs.'
    }
    $dirtyIds = @($dirtyValues | ForEach-Object { [string]$_ })
    if ($dirtyIds.Count -lt 1 -or @($dirtyIds | Where-Object { $_ -notmatch '^[a-z0-9][a-z0-9-]{1,127}$' }).Count -ne 0) {
        throw 'Published authority adoption requires nonempty canonical dirty repository IDs.'
    }
    $sortedDirtyIds = @($dirtyIds | Sort-Object -CaseSensitive -Unique)
    if ($sortedDirtyIds.Count -ne $dirtyIds.Count -or @($sortedDirtyIds | Where-Object { $_ -ceq $SourceRepoId }).Count -ne 1) {
        throw 'Published authority adoption requires unique dirty repository IDs containing the source repository.'
    }
    $sourceRows = @($state.repository_heads | Where-Object { [string]$_.repo_id -ceq $SourceRepoId })
    if ($sourceRows.Count -ne 1) {
        throw 'Published authority adoption requires exactly one stale source repository-head entry.'
    }
    $sourceRow = $sourceRows[0]
    foreach ($property in @('repo_id', 'head', 'branch', 'dirty_fingerprint')) {
        if ($sourceRow.PSObject.Properties.Name -cnotcontains $property) {
            throw "Projected source repository-head entry is missing '$property'."
        }
    }
    $staleHead = [string]$sourceRow.head
    if ($staleHead -notmatch '^[0-9a-f]{40}$' -or $staleHead -ceq $Revision) {
        throw 'Published authority adoption requires a canonical stale source repository head.'
    }
    if ($null -ne $sourceRow.branch -and $sourceRow.branch -isnot [string]) {
        throw 'Projected source repository branch must be a string or null.'
    }
    $staleBranch = if ($null -eq $sourceRow.branch) { $null } else { [string]$sourceRow.branch }
    if ($null -ne $staleBranch -and [string]::IsNullOrWhiteSpace($staleBranch)) {
        throw 'Projected source repository branch must be null or nonempty.'
    }
    if ($null -ne $sourceRow.dirty_fingerprint -and $sourceRow.dirty_fingerprint -isnot [string]) {
        throw 'Projected source repository dirty fingerprint must be a string or null.'
    }
    $dirtyFingerprint = if ($null -eq $sourceRow.dirty_fingerprint) { $null } else { [string]$sourceRow.dirty_fingerprint }
    if ($null -ne $dirtyFingerprint -and $dirtyFingerprint -notmatch '^[0-9a-f]{64}$') {
        throw 'Projected source repository dirty fingerprint is noncanonical.'
    }
    return [pscustomobject][ordered]@{
        current_unit = $null
        next_ready_unit = $null
        pending_push_bundle = $null
        dirty_repository_ids = $sortedDirtyIds
        source_repository = [pscustomobject][ordered]@{
            repo_id = $SourceRepoId
            head = $staleHead
            branch = $staleBranch
            dirty_fingerprint = $dirtyFingerprint
        }
    }
}
function Get-GitCommonDirectory([string]$RepositoryPath) {
    $value=(& git -C $RepositoryPath rev-parse --path-format=absolute --git-common-dir).Trim()
    if($LASTEXITCODE-ne0-or-not$value){throw"Repository is not an available Git repository: $RepositoryPath"}
    return [IO.Path]::GetFullPath($value).TrimEnd('\','/')
}
function Get-PlanningProjectionLocalBase([string]$PlanningRepository) {
    $head = (& git -C $PlanningRepository rev-parse --verify HEAD 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
        throw 'V2 planning repository requires an existing base commit.'
    }
    $branch = (& git -C $PlanningRepository symbolic-ref --quiet --short HEAD 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        throw 'V2 planning repository base must be attached to a branch.'
    }
    $remotes = @(& git -C $PlanningRepository remote 2>$null)
    if ($LASTEXITCODE -ne 0 -or $remotes.Count -ne 0) {
        throw 'V2 planning repository base must be local-only with no configured remote.'
    }
    return [pscustomobject][ordered]@{head=$head;branch=$branch}
}
function Get-FreshRemoteRevision([string]$RepositoryPath,[string]$Remote,[string]$RemoteRef) {
    $rows=@(& git -C $RepositoryPath ls-remote --exit-code $Remote $RemoteRef 2>$null)
    if($LASTEXITCODE-ne0-or$rows.Count-ne1-or$rows[0]-notmatch'^([0-9a-f]{40})\s+(.+)$'-or$matches[2]-cne$RemoteRef){throw"Fresh remote readback failed for $Remote $RemoteRef."}
    return $matches[1]
}
function Test-MorphospacePlanningWorkspaceProjectionDocument {
    param([Parameter(Mandatory)][string]$Path)
    $document=Get-PlanningProjectionDocument $Path
    $schema = [string]$document.schema
    if($schema-cnotin@('rusty.morphospace.workflow.planning_workspace_projection.v1','rusty.morphospace.workflow.planning_workspace_projection.v2')){throw'Planning-workspace projection has the wrong schema.'}
    $isV2 = $schema -ceq 'rusty.morphospace.workflow.planning_workspace_projection.v2'
    $expectedClassification = if($isV2){'published-embedded-workspace-authority-adoption'}else{'embedded-workspace-projected-after-source-publication'}
    $expectedTransition = if($isV2){'AdoptPublishedPlanningAuthority'}else{'ReconcilePublication'}
    if([string]$document.status-cne'exact-projection-verified'-or[string]$document.chronology.classification-cne$expectedClassification){throw'Planning-workspace projection chronology/status is invalid.'}
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
    if([string]$document.authority.source_workspace-cne'immutable-historical-snapshot'-or[string]$document.authority.external_workspace-cne'sole-mutable-workflow-authority'-or$document.authority.source_workflow_mutation_performed-ne$false-or$document.authority.git_mutation_performed-ne$false-or[string]$document.authority.next_transition-cne$expectedTransition){throw'Projection authority boundary is invalid.'}
    if(-not$isV2){
        if($document.PSObject.Properties.Name-ccontains'projected_state'){throw'V1 planning-workspace projection cannot carry a v2 projected-state binding.'}
    }else{
        if($document.planning.base_revision-isnot[string]-or[string]$document.planning.base_revision-notmatch'^[0-9a-f]{40}$'){throw'V2 planning-workspace projection requires a full planning base revision.'}
        if($document.PSObject.Properties.Name-cnotcontains'projected_state'){throw'V2 planning-workspace projection lacks projected-state binding.'}
        $state=$document.projected_state
        foreach($property in @('current_unit','next_ready_unit','pending_push_bundle','dirty_repository_ids','source_repository')){
            if($state.PSObject.Properties.Name-cnotcontains$property){throw"V2 projected-state binding is missing '$property'."}
        }
        if($null-ne$state.current_unit-or$null-ne$state.next_ready_unit-or$null-ne$state.pending_push_bundle){throw'V2 projected-state active-work conditions are invalid.'}
        $dirtyValues=@($state.dirty_repository_ids)
        if(@($dirtyValues|Where-Object{$_-isnot[string]}).Count-ne0){throw'V2 projected-state dirty repository IDs must be strings.'}
        $dirtyIds=@($dirtyValues|ForEach-Object{[string]$_})
        $sortedDirtyIds=@($dirtyIds|Sort-Object -CaseSensitive -Unique)
        if($dirtyIds.Count-lt1-or@($dirtyIds|Where-Object{$_-notmatch'^[a-z0-9][a-z0-9-]{1,127}$'}).Count-ne0-or$sortedDirtyIds.Count-ne$dirtyIds.Count-or($dirtyIds-join'|')-cne($sortedDirtyIds-join'|')){throw'V2 projected-state dirty repository IDs must be nonempty, canonical, unique, and ordinally sorted.'}
        $sourceBinding=$state.source_repository
        foreach($property in @('repo_id','head','branch','dirty_fingerprint')){
            if($sourceBinding.PSObject.Properties.Name-cnotcontains$property){throw"V2 source-repository binding is missing '$property'."}
        }
        if($sourceBinding.repo_id-isnot[string]-or$sourceBinding.head-isnot[string]-or[string]$sourceBinding.repo_id-cne[string]$document.source.repo_id-or[string]$sourceBinding.head-notmatch'^[0-9a-f]{40}$'-or[string]$sourceBinding.head-ceq[string]$document.source.published_revision-or@($dirtyIds|Where-Object{$_-ceq[string]$sourceBinding.repo_id}).Count-ne1){throw'V2 source-repository binding does not identify the stale published dirty source.'}
        if($null-ne$sourceBinding.branch-and($sourceBinding.branch-isnot[string]-or[string]::IsNullOrWhiteSpace([string]$sourceBinding.branch))){throw'V2 source-repository branch binding is invalid.'}
        if($null-ne$sourceBinding.dirty_fingerprint-and($sourceBinding.dirty_fingerprint-isnot[string]-or[string]$sourceBinding.dirty_fingerprint-notmatch'^[0-9a-f]{64}$')){throw'V2 source-repository dirty fingerprint is invalid.'}
    }
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
        if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw"Projected file is missing: $($row.path)"}
        if((Get-PlanningProjectionSha256 $target)-cne[string]$row.sha256){throw"Projected file differs from published bytes: $($row.path)"}
    }
    if([string]$d.schema-ceq'rusty.morphospace.workflow.planning_workspace_projection.v2'){
        $actualState=Get-PublishedProjectionStateBinding $sourceRoot ([string]$d.source.published_revision) ([string]$d.source.embedded_workspace_path) ([string]$d.source.repo_id)
        if((@($actualState.dirty_repository_ids)-join'|')-cne(@($d.projected_state.dirty_repository_ids)-join'|')-or
            [string]$actualState.source_repository.repo_id-cne[string]$d.projected_state.source_repository.repo_id-or
            [string]$actualState.source_repository.head-cne[string]$d.projected_state.source_repository.head-or
            (($null-eq$actualState.source_repository.branch)-ne($null-eq$d.projected_state.source_repository.branch))-or
            ($null-ne$actualState.source_repository.branch-and[string]$actualState.source_repository.branch-cne[string]$d.projected_state.source_repository.branch)-or
            (($null-eq$actualState.source_repository.dirty_fingerprint)-ne($null-eq$d.projected_state.source_repository.dirty_fingerprint))-or
            ($null-ne$actualState.source_repository.dirty_fingerprint-and[string]$actualState.source_repository.dirty_fingerprint-cne[string]$d.projected_state.source_repository.dirty_fingerprint)){
            throw'V2 projected-state binding differs from the published workspace bytes.'
        }
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
    if([string]$d.schema-ceq'rusty.morphospace.workflow.planning_workspace_projection.v2'){
        $planningBase=Get-PlanningProjectionLocalBase $planningRoot
        if([string]$planningBase.head-cne[string]$d.planning.base_revision){throw'V2 planning repository HEAD differs from the bound pre-projection base.'}
        $planningStatus=@(& git -C $planningRoot status --porcelain=v1 --untracked-files=all)
        if($LASTEXITCODE-ne0){throw'V2 planning repository status observation failed.'}
        $actualUntracked=@($planningStatus|ForEach-Object{
            $line=[string]$_
            if($line.Length-lt4-or-not$line.StartsWith('?? ',[StringComparison]::Ordinal)){throw'V2 planning repository contains staged, tracked, or malformed worktree changes.'}
            $line.Substring(3).Replace('\','/')
        }|Sort-Object -CaseSensitive)
        $expectedUntracked=@($destinationFiles|ForEach-Object{"$relativeWorkspace/$_"}|Sort-Object -CaseSensitive)
        if(($actualUntracked-join'|')-cne($expectedUntracked-join'|')){throw'V2 planning repository dirt differs from the exact projected workspace.'}
    }
    return $validated
}
Export-ModuleMember -Function Get-GitWorkspaceInventory,Get-GitBlobBytes,Get-GitCommonDirectory,Get-FreshRemoteRevision,Get-PlanningProjectionLocalBase,Get-PublishedProjectionStateBinding,Test-PlanningProjectionRelativePath,Test-MorphospacePlanningWorkspaceProjectionDocument,Test-MorphospacePlanningWorkspaceProjectionLive
