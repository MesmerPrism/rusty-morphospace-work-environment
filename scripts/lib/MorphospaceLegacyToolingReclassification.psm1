Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospacePreparationRepositoryScope.psm1')

function Test-MorphospaceLegacyToolingExactValue {
    param([AllowNull()][object]$Value,[string]$Expected)
    if($null-eq$Value){return $false}
    if($Value-is[string]){return [string]$Value-ceq$Expected}
    if($Value-is[Collections.IDictionary]){foreach($key in $Value.Keys){if(Test-MorphospaceLegacyToolingExactValue $Value[$key] $Expected){return $true}};return $false}
    if($Value-is[Collections.IEnumerable]){foreach($item in $Value){if(Test-MorphospaceLegacyToolingExactValue $item $Expected){return $true}};return $false}
    foreach($property in @($Value.PSObject.Properties)){if(Test-MorphospaceLegacyToolingExactValue $property.Value $Expected){return $true}}
    $false
}
function Get-MorphospaceLegacyToolingIndex {
    param([object[]]$Rows,[string]$Name)
    $result=@{};foreach($row in @($Rows)){$id=[string]$row.repo_id;if(-not$id-or$result.ContainsKey($id)){throw "$Name has a missing or duplicate repository identity."};$result[$id]=$row};$result
}
function Invoke-MorphospaceLegacyToolingGit {
    param([string]$Root,[string[]]$Arguments,[string]$Name)
    $rows=@(& git --no-optional-locks --no-replace-objects -C $Root @Arguments 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "Legacy tooling reclassification Git $Name failed.`n$($rows-join"`n")"};@($rows)
}
function Get-MorphospaceLegacyToolingReclassificationHistory {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object[]]$Events,[Parameter(Mandatory)][string]$PreparationEventId)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1')
    $preparationEvent=@($Events|Where-Object{[string]$_.event_id-ceq$PreparationEventId});if($preparationEvent.Count-gt1){throw 'Legacy tooling reclassification has an ambiguous preparation event.'};$ceiling=$(if($preparationEvent.Count-eq1){[int]$preparationEvent[0].sequence}else{[int]::MaxValue})
    $retired=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$proofs=@{}
    foreach($event in @($Events|Where-Object{[int]$_.sequence-lt$ceiling-and[string]$_.event_id-cmatch'-active-retired$'})){$proof=Test-MorphospaceHistoricalActiveUnitRetirement -WorkspaceRoot $workspace -ExpectedEvent $event;$id=[string]$proof.request.unit_id;if(-not$retired.Add($id)){throw 'Legacy tooling reclassification repeats an authenticated active retirement.'};$proofs[$id]=$proof}
    $units=@{};foreach($file in @(Get-ChildItem -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace 'iteration-units') -File -Filter '*.json')){$unit=Read-MorphospaceProtocolJson $file.FullName;if($units.ContainsKey([string]$unit.unit_id)){throw 'Legacy tooling reclassification finds duplicate unit identities.'};$units[[string]$unit.unit_id]=$unit}
    [pscustomobject]@{authenticated=($proofs.Count-gt0);retired_active_ids=$retired;historical_ids=@();retired_ids=@();historically_retired_proposed_ids=@();active_retirements=$proofs;units=$units}
}
function Assert-MorphospaceLegacyToolingReclassification {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$Reclassification,
        [Parameter(Mandatory)][object]$CurrentProject,
        [Parameter(Mandatory)][object]$TargetProject,
        [Parameter(Mandatory)][object]$CurrentMap,
        [Parameter(Mandatory)][object]$TargetMap,
        [Parameter(Mandatory)][object]$ToolingDescriptor,
        [Parameter(Mandatory)][object]$History,
        [Parameter(Mandatory)][string[]]$TargetSourceRepositoryIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnerRepositories
    )
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    if(-not(Test-Json -Json ($Reclassification|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) '../schemas/legacy-tooling-reclassification-v1.schema.json'))){throw 'Legacy tooling reclassification violates its closed owner schema.'}
    $oldMapPath=ConvertTo-MorphospaceProtocolRelativePath ([string]$Reclassification.old_repository_map.path);$targetMapPath=ConvertTo-MorphospaceProtocolRelativePath ([string]$Reclassification.target_repository_map.path)
    if($oldMapPath-cnotmatch'^local/'-or$targetMapPath-cnotmatch'^local/'-or$oldMapPath-ceq$targetMapPath){throw 'Legacy tooling reclassification requires distinct ignored old and target repository maps.'}
    foreach($binding in @($Reclassification.old_repository_map,$Reclassification.target_repository_map)){$path=Resolve-MorphospaceWorkspacePath $workspace ([string]$binding.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $path)-cne[string]$binding.sha256){throw 'Legacy tooling reclassification repository-map bytes drifted.'}}
    if(-not$History.authenticated-or@($History.retired_active_ids).Count-lt1){throw 'Legacy tooling reclassification requires authenticated idle history after active retirement.'}
    $currentProjectRows=Get-MorphospaceLegacyToolingIndex @($CurrentProject.repositories) 'Current project';$targetProjectRows=Get-MorphospaceLegacyToolingIndex @($TargetProject.repositories) 'Target project';$currentMapRows=Get-MorphospaceLegacyToolingIndex @($CurrentMap.repositories) 'Current repository map';$targetMapRows=Get-MorphospaceLegacyToolingIndex @($TargetMap.repositories) 'Target repository map'
    $removedIds=@($Reclassification.removed_tool_repositories|ForEach-Object{[string]$_.repo_id});if($removedIds.Count-ne@($removedIds|Sort-Object -Unique -CaseSensitive).Count){throw 'Legacy tooling reclassification repeats a removed repository.'}
    $actualProjectRemoved=@($currentProjectRows.Keys|Where-Object{-not$targetProjectRows.ContainsKey($_)}|Sort-Object);$actualMapRemoved=@($currentMapRows.Keys|Where-Object{-not$targetMapRows.ContainsKey($_)}|Sort-Object);$declaredRemoved=@($removedIds|Sort-Object)
    if(($actualProjectRemoved-join"`n")-cne($declaredRemoved-join"`n")-or($actualMapRemoved-join"`n")-cne($declaredRemoved-join"`n")){throw 'Legacy tooling reclassification removal set differs across project, maps, and declaration.'}
    foreach($id in $targetMapRows.Keys){if($currentMapRows.ContainsKey($id)-and(Get-MorphospaceCanonicalJsonSha256 $currentMapRows[$id])-cne(Get-MorphospaceCanonicalJsonSha256 $targetMapRows[$id])){throw "Legacy tooling reclassification rewrites remaining repository-map row '$id'."}}
    $targetIds=@($targetProjectRows.Keys|Sort-Object);if(($targetIds-join"`n")-cne(@($targetMapRows.Keys|Sort-Object)-join"`n")-or($targetIds-join"`n")-cne(@($TargetSourceRepositoryIds|Sort-Object)-join"`n")){throw 'Legacy tooling reclassification target project, map, and source sets differ.'}
    $descriptorRouters=@{};foreach($router in @($ToolingDescriptor.routers)){$descriptorRouters[[string]$router.skill_id]=$router}
    $terminalUnitIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($set in @($History.historical_ids,$History.retired_ids,$History.historically_retired_proposed_ids,$History.retired_active_ids)){foreach($unitId in @($set)){[void]$terminalUnitIds.Add([string]$unitId)}}
    foreach($entry in @($Reclassification.removed_tool_repositories)){
        $id=[string]$entry.repo_id;$projectRow=$currentProjectRows[$id];$mapRow=$currentMapRows[$id]
        if($null-eq$projectRow-or$null-eq$mapRow-or[string]$projectRow.role-cne'tool'){throw "Legacy tooling reclassification '$id' is not an exact current tool repository."}
        if((Get-MorphospaceCanonicalJsonSha256 $projectRow)-cne[string]$entry.project_row_sha256-or(Get-MorphospaceCanonicalJsonSha256 $mapRow)-cne[string]$entry.map_row_sha256){throw "Legacy tooling reclassification '$id' row binding drifted."}
        $allowed=@($projectRow.allowed_paths|ForEach-Object{ConvertTo-MorphospaceProtocolRelativePath ([string]$_)}|Sort-Object);if(($allowed-join"`n")-cne(@($entry.canonical_allowed_paths|Sort-Object)-join"`n")){throw "Legacy tooling reclassification '$id' allowed paths differ."}
        foreach($unit in @($History.units.Values|Where-Object{[string]$_.status-cin@('proposed','ready','active')-and-not$terminalUnitIds.Contains([string]$_.unit_id)})){if(Test-MorphospaceLegacyToolingExactValue $unit $id){throw "Nonterminal unit still depends on legacy tooling repository '$id'."}}
        if(Test-MorphospaceLegacyToolingExactValue $TargetProject $id){throw "Target project still names removed tooling repository '$id'."}
        $retirementProofs=@($History.active_retirements.Values|Where-Object{
            [string]$_.request.unit_id-ceq[string]$_.receipt.unit_id-and
            [string]$_.request.source_composition.path-ceq[string]$entry.source_composition.path-and
            [string]$_.request.source_composition.raw_sha256-ceq[string]$entry.source_composition.sha256-and
            [string]$_.request.source_composition.canonical_sha256-ceq[string]$entry.source_composition.canonical_sha256-and
            [string]$_.request.expected.repository_map_sha256-ceq[string]$Reclassification.old_repository_map.sha256
        })
        if($retirementProofs.Count-ne1){throw "Legacy tooling reclassification '$id' is not bound to one authenticated active retirement."}
        $retiredUnitId=[string]$retirementProofs[0].request.unit_id
        $admissions=@(Get-ChildItem -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace 'receipts') -File -Filter '*.json'|ForEach-Object{$candidate=Read-MorphospaceProtocolJson $_.FullName;if([string]$candidate.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$candidate.unit_id-ceq$retiredUnitId){$candidate}})
        if($admissions.Count-ne1-or-not(Test-Json -Json ($admissions[0]|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) '../schemas/development-unit-admission-v1.schema.json'))-or
            [string]$admissions[0].expected.repository_map_path-cne$oldMapPath-or[string]$admissions[0].expected.repository_map_sha256-cne[string]$Reclassification.old_repository_map.sha256-or
            [string]$admissions[0].preparation.source_composition_path-cne[string]$entry.source_composition.path-or[string]$admissions[0].preparation.source_composition_sha256-cne[string]$entry.source_composition.sha256){throw "Legacy tooling reclassification '$id' old map and source are detached from the retired unit admission."}
        $sourcePath=Resolve-MorphospaceWorkspacePath $workspace ([string]$entry.source_composition.path) -RequireLeaf;$source=Read-MorphospaceProtocolJson $sourcePath
        if((Get-MorphospaceFileSha256 $sourcePath)-cne[string]$entry.source_composition.sha256-or(Get-MorphospaceCanonicalJsonSha256 $source)-cne[string]$entry.source_composition.canonical_sha256){throw "Legacy tooling reclassification '$id' source-lock bytes drifted."}
        $sourceRows=@($source.repositories|Where-Object{[string]$_.repo_id-ceq$id});if($sourceRows.Count-ne1){throw "Legacy tooling reclassification '$id' lacks one old source row."};$sourceRow=$sourceRows[0]
        if((Get-MorphospaceCanonicalJsonSha256 $sourceRow)-cne[string]$entry.source_row_sha256-or[string]$sourceRow.commit-cne[string]$entry.commit-or[string]$sourceRow.tree-cne[string]$entry.tree-or[string]$sourceRow.materialization_path-cne[string]$entry.materialization_path-or[string]$sourceRow.role-cnotin@('source','planning')){throw "Legacy tooling reclassification '$id' source row is detached."}
        $mappedRoot=[IO.Path]::GetFullPath([string]$mapRow.path);$remote=@(Invoke-MorphospaceLegacyToolingGit $mappedRoot @('remote','get-url','origin') 'remote');if($remote.Count-ne1-or[string]$remote[0]-cne[string]$ToolingDescriptor.executor.remote_url){throw "Legacy tooling reclassification '$id' source repository identity differs from the new tooling executor."};$oldTree=@(Invoke-MorphospaceLegacyToolingGit $mappedRoot @('rev-parse',"$([string]$entry.commit)^{tree}") 'historical tree');if($oldTree.Count-ne1-or[string]$oldTree[0].Trim().ToLowerInvariant()-cne[string]$entry.tree){throw "Legacy tooling reclassification '$id' historical Git tree is absent."}
        $routerIds=@($entry.router_skill_ids|Sort-Object);$managed=[Collections.Generic.List[string]]::new();$matchedRouters=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($skillId in $routerIds){if(-not$descriptorRouters.ContainsKey([string]$skillId)){throw "Legacy tooling reclassification '$id' router '$skillId' is absent."};$router=$descriptorRouters[[string]$skillId];if([string]$router.source_repo_id-cne[string]$ToolingDescriptor.executor.repo_id){throw "Legacy tooling reclassification '$id' router source identity differs."};foreach($file in @($router.managed_files)){$managed.Add("$skillId/$([string]$file.path)")|Out-Null}}
        foreach($path in $allowed){if(@($managed|Where-Object{[string]$_-ceq$path}).Count-ne1){throw "Legacy tooling reclassification '$id' allowed path '$path' is not one exact reviewed router file."};[void]$matchedRouters.Add(($path-split'/',2)[0]);$gitPath=([string]$entry.materialization_path).TrimEnd('/')+'/'+$path;[void](Invoke-MorphospaceLegacyToolingGit $mappedRoot @('cat-file','-e',"$([string]$entry.commit):$gitPath") "historical blob '$gitPath'")}
        if(($matchedRouters.Count-ne$routerIds.Count)-or@($routerIds|Where-Object{-not$matchedRouters.Contains([string]$_)}).Count-ne0){throw "Legacy tooling reclassification '$id' declares a router without one old allowed path."}
    }
    Assert-MorphospacePreparationRepositoryRoots -CurrentRepositories @($CurrentProject.repositories) -TargetRepositories @($TargetProject.repositories) -OwnerRepositories @($OwnerRepositories) -Mode legacy-tooling-reclassification -RemovedToolRepositoryIds $removedIds
    $Reclassification
}

Export-ModuleMember -Function Assert-MorphospaceLegacyToolingReclassification,Get-MorphospaceLegacyToolingReclassificationHistory
