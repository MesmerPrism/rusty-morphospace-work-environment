# Test-only construction of an exact reviewed request; the public writer reobserves every field.
function New-ActiveUnitRetirementRequest {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[string]$RepoMapPath='', [string]$RetirementId='retire-u002', [string]$ReplacementUnitId='u003',[object[]]$RetainedLifecycleDiagnostics=@())
    if(-not$RepoMapPath){$RepoMapPath=Join-Path $WorkspaceRoot 'repository-map.json'}
    $retirementModule=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1') -PassThru
    & $retirementModule {
        param($workspace,$mapPath,$retirementId,$replacement,$diagnostics)
        $state=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json');$id=[string]$state.current_unit
        $unitPath="iteration-units/$id.json";$unit=Read-MorphospaceProtocolJson (Join-Path $workspace $unitPath)
        $unitBinding=Get-ActiveRetirementFileBinding $workspace $unitPath
        $events=Get-ActiveRetirementEvents $workspace
        $expected=[ordered]@{}
        foreach($pair in @(@('project','project.spec.json'),@('feature_lock','feature.lock.json'),@('state','workspace.state.json'))){
            $binding=Get-ActiveRetirementFileBinding $workspace $pair[1];$expected["$($pair[0])_raw_sha256"]=$binding.raw_sha256;$expected["$($pair[0])_canonical_sha256"]=$binding.canonical_sha256
        }
        $expected.events_sha256=$events.sha256;$expected.events_length=$events.length;$expected.event_tail_id=$events.tail_id;$expected.repository_map_sha256=Get-MorphospaceFileSha256 $mapPath
        $request=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.active_unit_retirement.v1';retirement_id=$retirementId;project_id=[string]$state.project_id;unit_id=$id;replacement_unit_id=$replacement;reason='scope-replanned';old_unit=[pscustomobject]@{unit_id=$id;path=$unitPath;raw_sha256=$unitBinding.raw_sha256;canonical_sha256=$unitBinding.canonical_sha256;status='active'};expected=[pscustomobject]$expected;source_composition=Get-ActiveRetirementFileBinding $workspace ([string]$unit.source_composition.lock_path);claim=$null;repositories=@();accepted_receipt=[pscustomobject]@{path=[string]$state.last_accepted_receipt;sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ([string]$state.last_accepted_receipt))}}
        $request.claim=Get-ActiveRetirementClaim $workspace $request $events.events
        $source=Read-MorphospaceProtocolJson (Join-Path $workspace ([string]$request.source_composition.path))
        $request|Add-Member -NotePropertyName retained_lifecycle_diagnostics -NotePropertyValue $diagnostics -Force
        if($diagnostics.Count-eq0){$request.PSObject.Properties.Remove('retained_lifecycle_diagnostics')}
        $request.repositories=@(Get-ActiveRetirementRepositories $unit $source $mapPath $workspace -Request $request)
        return $request
    } $WorkspaceRoot $RepoMapPath $RetirementId $ReplacementUnitId $RetainedLifecycleDiagnostics
}

function New-RetirementNonpassFreezeRequest {
    param([string]$Workspace,[string]$RepositoryMapPath,[string]$RequestPath)
    $project=Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json');$lock=Read-EnvelopeProtocolJson (Join-Path $Workspace 'feature.lock.json');$state=Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json');$unit=Read-EnvelopeProtocolJson (Join-Path $Workspace 'iteration-units\u002.json')
    $eventsPath=Join-Path $Workspace 'iteration-events.jsonl';$events=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String});$map=Read-EnvelopeProtocolJson $RepositoryMapPath;$mapRows=@{};foreach($row in @($map.repositories)){$mapRows[[string]$row.repo_id]=$row}
    $final=[Collections.Generic.List[object]]::new();$changed=[Collections.Generic.List[object]]::new()
    foreach($scope in @($unit.allowed_repositories)){
        $id=[string]$scope.repo_id;if(-not$mapRows.ContainsKey($id)){throw "Freeze fixture writable repository '$id' is absent from the effective map."};$root=[string]$mapRows[$id].path
        $head=(@(Invoke-EnvelopeGit $root @('rev-parse','HEAD'))[0]).Trim().ToLowerInvariant();$tree=(@(Invoke-EnvelopeGit $root @('rev-parse','HEAD^{tree}'))[0]).Trim().ToLowerInvariant()
        $final.Add([pscustomobject][ordered]@{repo_id=$id;commit=$head;tree=$tree})|Out-Null;$changed.Add([pscustomobject][ordered]@{repo_id=$id;paths=@($scope.allowed_paths)})|Out-Null
    }
    $sourceRelative=[string]$unit.source_composition.lock_path;$sourcePath=Join-Path $Workspace $sourceRelative;$mapRelative=[IO.Path]::GetRelativePath($Workspace,$RepositoryMapPath).Replace('\','/');$deviceUse=@(if(@($unit.agent_scope_assessment.device_envelope.allowed_kinds).Count){@($unit.agent_scope_assessment.device_envelope.allowed_kinds)}else{@('none')})
    $freeze=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id='u002-extension-freeze';project_id=[string]$project.project_id;unit_id='u002'
        expected=[pscustomobject][ordered]@{project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $lock;source_composition_path=$sourceRelative;source_composition_sha256=Get-EnvelopeFileSha256 $sourcePath;repository_map_path=$mapRelative;repository_map_sha256=Get-EnvelopeFileSha256 $RepositoryMapPath;events_sha256=Get-EnvelopeFileSha256 $eventsPath;events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$events[-1].event_id}
        final_repositories=@($final.ToArray());changed_paths=@($changed.ToArray());cleanliness_policy='clean-only';instruction_surfaces=@([pscustomobject][ordered]@{path='README.md';disposition='reviewed-no-change'});feature_lock=[pscustomobject][ordered]@{revision=[int]$lock.revision;sha256=Get-EnvelopeCanonicalJsonSha256 $lock};effects=@($unit.agent_scope_assessment.allowed_effect_categories);permissions=@($unit.agent_scope_assessment.allowed_permission_categories);device_use=@($deviceUse);test_matrix=@([pscustomobject][ordered]@{test_id='extension';command='pwsh -NoProfile -File scripts/Test-ActiveDevelopmentEnvelopeExtension.ps1'});cleanup_evidence=@('All source repositories are clean at their exact candidate identities.');source_composition=[pscustomobject][ordered]@{path=$sourceRelative;sha256=Get-EnvelopeFileSha256 $sourcePath};does_not_prove=@('Does not validate, accept, publish, mutate Git, or operate a device.')
    }
    Write-EnvelopeJson $RequestPath $freeze
    return $freeze
}
