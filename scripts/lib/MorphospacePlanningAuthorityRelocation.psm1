Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospacePublishedPlanningAuthorityAdoption.psm1')
function Assert-MorphospacePlanningAuthorityRelocation {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Request,[Parameter(Mandatory)][object]$ParentSource,[Parameter(Mandatory)][object]$EffectiveMap,[switch]$Historical)
    $binding=$Request.planning_authority_relocation;$id=[string]$binding.repo_id
    $rows=@($EffectiveMap.repositories|Where-Object{[string]$_.repo_id-ceq$id});$parents=@($ParentSource.repositories|Where-Object{[string]$_.repo_id-ceq$id})
    if($rows.Count-ne1-or$parents.Count-ne1-or[string]$rows[0].role-cne'planning'-or[string]$parents[0].role-cne'planning'-or@($Request.before.read_only_dependencies|Where-Object{[string]$_.repo_id-ceq$id}).Count-ne1-or@($Request.before.allowed_repositories|Where-Object{[string]$_.repo_id-ceq$id}).Count-ne0){throw 'Planning relocation must select one existing read-only planning dependency.'}
    $root=[IO.Path]::GetFullPath([string]$rows[0].path).TrimEnd('\','/');$workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
    Assert-MorphospaceNoReparseAncestor -Root ([IO.Path]::GetPathRoot($root)) -Candidate $root
    $gitRoot=(@(&git -C $workspace rev-parse --show-toplevel 2>&1)-join'').Trim();if($LASTEXITCODE-ne0){throw 'Planning relocation destination has no backing Git repository.'}
    $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$root.Equals([IO.Path]::GetFullPath($gitRoot).TrimEnd('\','/'),$comparison)-or-not$workspace.StartsWith($root+[IO.Path]::DirectorySeparatorChar,$comparison)-or[IO.Path]::GetRelativePath($root,$workspace).Replace('\','/')-cne[string]$binding.destination.workspace_path){throw 'Planning relocation differs from the explicitly selected workspace Git root.'}
    $head=[string]$binding.destination.head;$tree=(@(&git -C $root rev-parse "$($head)^{tree}" 2>&1)-join'').Trim();if($LASTEXITCODE-ne0-or$tree-cne[string]$binding.destination.tree){throw 'Planning relocation destination commit/tree is unavailable.'}
    if(-not$Historical){
        $current=(@(&git -C $root rev-parse HEAD 2>&1)-join'').Trim();$branch=(@(&git -C $root branch --show-current 2>&1)-join'').Trim();$expectedBranch=if($null-eq$binding.destination.branch){''}else{[string]$binding.destination.branch}
        $dirty=@(&git -C $root status --porcelain=v1 -z --untracked-files=all 2>&1)
        if($LASTEXITCODE-ne0-or$current-cne$head-or$branch-cne$expectedBranch-or$dirty.Count-ne0){throw 'Planning relocation requires the exact clean selected destination.'}
    }
    $validated=Test-MorphospacePublishedPlanningAuthorityAdoptionDocument -Path (Resolve-MorphospaceWorkspacePath $workspace ([string]$binding.adoption.path) -RequireLeaf) -WorkspaceRoot $workspace
    if([string]$validated.document.project_id-cne[string]$Request.project_id-or[string]$validated.document.planning_repository.workspace_path-cne[string]$binding.destination.workspace_path-or[string]$validated.document.planning_workspace_projection.path-cne[string]$binding.projection.path-or[string]$validated.adoption_sha256-cne[string]$binding.adoption.raw_sha256-or[string]$validated.document.planning_workspace_projection.sha256-cne[string]$binding.projection.raw_sha256){throw 'Planning relocation adopted project/workspace/projection join is detached.'}
    $module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ActiveUnitRetirement.psm1') -PassThru
    $proof=&$module {param($w,$repository,$revision,$request,$parent,$binding)
        $prefix=[string]$binding.destination.workspace_path+'/'
        foreach($pair in @(@('project.spec.json','project_raw_sha256'),@('feature.lock.json','feature_lock_raw_sha256'),@('workspace.state.json','state_raw_sha256'),@('iteration-events.jsonl','events_sha256'),@(('iteration-units/'+[string]$request.unit_id+'.json'),'unit_raw_sha256'))){
            $bytes=Read-ActiveRetirementCommittedBytes $repository $revision ($prefix+[string]$pair[0]);if((Get-MorphospaceSha256Bytes $bytes)-cne[string]$request.expected.([string]$pair[1])){throw 'Planning relocation committed preimage differs from exact request CAS.'}
        }
        $unit=ConvertFrom-MorphospaceProtocolJsonBytes (Read-ActiveRetirementCommittedBytes $repository $revision ($prefix+'iteration-units/'+[string]$request.unit_id+'.json'))
        $admissions=@(Get-ChildItem -LiteralPath (Join-Path $w 'receipts') -File -Filter '*.json'|ForEach-Object{$d=Read-MorphospaceProtocolJson $_.FullName;if([string]$d.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$d.unit_id-ceq[string]$request.unit_id){$d}})
        if($admissions.Count-ne1){throw 'Planning relocation requires one original current-unit admission.'}
        $locked=if($parent.PSObject.Properties.Name-ccontains'effective_commit'){[string]$parent.effective_commit}else{[string]$parent.commit}
        $entry=[pscustomobject]@{repo_id=[string]$binding.repo_id;role='planning';path=$repository}
        if(-not(Test-ActiveRetirementPlanningProjectionFromAuthenticatedAdmission -Workspace $w -Unit $unit -RepositoryEntry $entry -StatusPorcelain @() -Admission $admissions[0] -LockedCommit $locked -ObservedHead $revision -CommittedSnapshot)){throw 'Planning relocation lacks a complete authenticated planning projection.'}
        foreach($reference in @($binding.adoption,$binding.projection)){
            $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$reference.path);$live=Resolve-MorphospaceWorkspacePath $w $relative -RequireLeaf
            $intro=[string]$binding.adoption.introduced_commit;$gitPath=$prefix+$relative
            $null=&git -C $repository merge-base --is-ancestor $intro $locked 2>&1;if($LASTEXITCODE-ne0){throw 'Planning relocation adoption did not precede the original source lock.'}
            if((Get-MorphospaceFileSha256 $live)-cne[string]$reference.raw_sha256){throw 'Planning relocation adoption/projection live bytes drifted.'}
            $changes=@(&git -C $repository rev-list "$intro..$revision" -- $gitPath 2>&1);if($LASTEXITCODE-ne0-or$changes.Count-ne0){throw 'Planning relocation adoption/projection history was rewritten.'}
            $committed=Read-ActiveRetirementCommittedBytes $repository $intro $gitPath
            foreach($commit in @($intro,$revision)){if((Get-MorphospaceSha256Bytes (Read-ActiveRetirementCommittedBytes $repository $commit $gitPath))-cne[string]$reference.git_blob_sha256){throw 'Planning relocation adoption/projection committed bytes drifted.'}}
            # Bind both immutable Git bytes and historical checkout bytes. Only the exact
            # CRLF-to-LF checkout form is admissible; no JSON semantic normalization.
            $liveBytes=[IO.File]::ReadAllBytes($live)
            $normalized=[Collections.Generic.List[byte]]::new()
            for($index=0;$index-lt$liveBytes.Length;$index++){
                if($liveBytes[$index]-eq13-and$index+1-lt$liveBytes.Length-and$liveBytes[$index+1]-eq10){continue}
                $normalized.Add($liveBytes[$index])
            }
            if((Get-MorphospaceSha256Bytes $liveBytes)-cne[string]$reference.git_blob_sha256-and(Get-MorphospaceSha256Bytes $normalized.ToArray())-cne[string]$reference.git_blob_sha256){throw 'Planning relocation checkout is not the exact committed bytes or historical CRLF form.'}
        }
        $addition=@(&git -C $repository diff-tree --no-commit-id --name-status -r ([string]$binding.adoption.introduced_commit) -- ($prefix+[string]$binding.adoption.path) 2>&1)
        if($LASTEXITCODE-ne0-or$addition.Count-ne1-or[string]$addition[0]-cne("A`t"+$prefix+[string]$binding.adoption.path)){throw 'Planning relocation adoption must bind its original Git addition.'}
        $true
    } $workspace $root $head $Request $parents[0] $binding
    return $true
}
Export-ModuleMember -Function Assert-MorphospacePlanningAuthorityRelocation
