# Test-only construction of an exact reviewed request; the public writer reobserves every field.
function New-ActiveUnitRetirementRequest {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[string]$RepoMapPath='', [string]$RetirementId='retire-u002', [string]$ReplacementUnitId='u003')
    if(-not$RepoMapPath){$RepoMapPath=Join-Path $WorkspaceRoot 'repository-map.json'}
    $retirementModule=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1') -PassThru
    & $retirementModule {
        param($workspace,$mapPath,$retirementId,$replacement)
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
        $request.repositories=@(Get-ActiveRetirementRepositories $unit $source $mapPath $workspace)
        return $request
    } $WorkspaceRoot $RepoMapPath $RetirementId $ReplacementUnitId
}
