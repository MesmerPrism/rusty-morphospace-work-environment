Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1')
$script:CandidateLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -PassThru
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1')
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1')
Import-Module (Join-Path $PSScriptRoot 'InheritedCandidateMaterialization.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceSourceCompositionIdentity.psm1')

function Invoke-MorphospaceCandidateGit {
    param([string]$Repository,[string[]]$Arguments,[string]$Context)
    $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$output=@(& git -C $Repository @Arguments 2>&1);$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
    if($exit-ne0){throw "Frozen candidate $Context failed for '$Repository': git $($Arguments -join ' ')"}
    return @($output|ForEach-Object{[string]$_})
}
function Test-MorphospaceCandidatePathAllowed {
    param([string]$Path,[string[]]$Allowed)
    $canonical=ConvertTo-MorphospaceProtocolRelativePath $Path
    foreach($entry in @($Allowed)){
        $raw=[string]$entry;$directory=$raw.EndsWith('/');$base=ConvertTo-MorphospaceProtocolRelativePath ($raw.TrimEnd('/'))
        if($canonical-ceq$base-or($directory-and$canonical.StartsWith("$base/",[StringComparison]::Ordinal))){return $true}
    }
    return $false
}
function Get-MorphospaceCandidateRepositoryMap {
    param([string]$Workspace,[string]$RelativePath)
    $path=Resolve-MorphospaceWorkspacePath $Workspace $RelativePath -RequireLeaf
    $repoRoot=Split-Path $PSScriptRoot -Parent
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile (Join-Path $repoRoot 'schemas\repository-map.schema.json'))){throw 'Frozen candidate repository map is malformed.'}
    $document=Read-MorphospaceProtocolJson $path;$map=@{}
    foreach($entry in @($document.repositories)){
        $id=[string]$entry.repo_id
        if(-not$id-or$map.ContainsKey($id)){throw "Frozen candidate repository map repeats or omits repository identity '$id'."}
        $root=[IO.Path]::GetFullPath([string]$entry.path)
        if(-not[IO.Directory]::Exists($root)){throw "Frozen candidate mapped repository '$id' is absent."}
        $map[$id]=[pscustomobject]@{repo_id=$id;path=$root;role=[string]$entry.role}
    }
    return $map
}
function Get-MorphospaceCandidatePreparationProvenance {
    param([string]$Workspace,[string]$UnitId)
    $repoRoot=Split-Path $PSScriptRoot -Parent;$matches=@();foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $Workspace 'receipts') -Filter '*.json' -File)){$doc=Read-MorphospaceProtocolJson $file.FullName;if([string]$doc.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$doc.unit_id-ceq$UnitId){if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $file.FullName) -SchemaFile (Join-Path $repoRoot 'schemas\development-unit-admission-v1.schema.json'))){throw 'Preparation-owned source composition admission receipt is malformed.'};$matches+=,[pscustomobject]@{path=('receipts/'+$file.Name);document=$doc;sha256=(Get-MorphospaceFileSha256 $file.FullName)}}}
    if($matches.Count-ne1){throw 'Preparation-owned source composition requires exactly one authenticated admission receipt.'};return $matches[0]
}
function Get-MorphospaceCandidateSourceComposition {
    param([string]$Workspace,[string]$RelativePath,[string]$ProjectId,[string]$UnitId)
    $path=Resolve-MorphospaceWorkspacePath $Workspace $RelativePath -RequireLeaf
    $repoRoot=Split-Path $PSScriptRoot -Parent
    $composition=Read-MorphospaceProtocolJson $path
    if([string]$composition.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){
        if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile (Join-Path $repoRoot 'schemas/active-development-envelope-source-composition-v1.schema.json'))){throw 'Frozen candidate active envelope source composition is malformed.'}
        if([string]$composition.project_id-cne$ProjectId-or[string]$composition.unit_id-cne$UnitId){throw 'Frozen candidate active envelope identity is detached.'}
        $mapPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$composition.repository_map.path) -RequireLeaf
        $proof=Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $Workspace -UnitId $UnitId -RepositoryMapPath $mapPath
        if([string]$proof.effective.source_composition_binding.path-cne$RelativePath-or[string]$proof.effective.source_composition_binding.raw_sha256-cne(Get-MorphospaceFileSha256 $path)){throw 'Frozen candidate active envelope source lock is detached from its owner lineage.'}
        return $composition
    }
    if([string]$composition.schema-cin@('rusty.morphospace.workflow.development_envelope_source_composition.v1','rusty.morphospace.workflow.development_envelope_source_composition.v2','rusty.morphospace.workflow.development_envelope_source_composition.v3')){
        $schemaFile="development-envelope-source-composition-$(([string]$composition.schema).Split('.')[-1]).schema.json"
        if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile (Join-Path $repoRoot "schemas\$schemaFile"))){throw 'Frozen candidate preparation-owned source composition is malformed.'}
        $admission=Get-MorphospaceCandidatePreparationProvenance $Workspace $UnitId;$preparation=$admission.document.preparation;[void](Test-MorphospaceDevelopmentUnitPreparation -WorkspaceRoot $Workspace -Admission $admission.document -Phase Freeze)
        if([string]$preparation.source_composition_path-cne$RelativePath-or[string]$preparation.source_composition_sha256-cne(Get-MorphospaceFileSha256 $path)){throw 'Frozen candidate preparation source lock is not the exact admitted lock.'}
        $receiptPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$preparation.receipt_path) -RequireLeaf
        $admissionKind=Get-MorphospaceDevelopmentAdmissionKind $admission.document
        $receiptSchema=if($admissionKind-ceq'blocked-successor'){'blocked-successor-preparation-receipt-v1.schema.json'}else{'development-envelope-preparation-receipt-v1.schema.json'}
        if((Get-MorphospaceFileSha256 $receiptPath)-cne[string]$preparation.receipt_sha256-or-not(Test-Json -Json (Get-Content -Raw -LiteralPath $receiptPath) -SchemaFile (Join-Path $repoRoot "schemas\$receiptSchema"))){throw 'Frozen candidate preparation receipt provenance is invalid.'}
        $receipt=Read-MorphospaceProtocolJson $receiptPath
        $expectedSourceHash=if($admissionKind-ceq'blocked-successor'){Get-MorphospaceFileSha256 $path}else{Get-MorphospaceCanonicalJsonSha256 $composition}
        if([string]$receipt.project_id-cne$ProjectId-or[string]$receipt.preparation_id-cne[string]$composition.preparation_id-or[string]$receipt.source_composition.path-cne$RelativePath-or[string]$receipt.source_composition.sha256-cne$expectedSourceHash){throw 'Frozen candidate preparation receipt does not authenticate this source lock.'}
        return $composition
    }
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile (Join-Path $repoRoot 'schemas\source-composition-lock.schema.json'))){throw 'Frozen candidate source composition is not an exact source-composition lock.'}
    if([string]$composition.project_id-cne$ProjectId-or[string]$composition.unit_id-cne$UnitId){throw 'Frozen candidate source composition project or unit identity differs from the candidate.'}
    return $composition
}
function Assert-MorphospaceFrozenCandidateScope {
    param([object]$Candidate,[object]$Unit)
    $scope=$Unit.agent_scope_assessment
    $unitRepos=@($Unit.allowed_repositories.repo_id)
    foreach($r in @($Candidate.final_repositories)){if($unitRepos -cnotcontains [string]$r.repo_id){throw "Frozen source closure includes undeclared repository '$($r.repo_id)'."}}
    foreach($r in @($Candidate.changed_paths)){
        if($unitRepos -cnotcontains [string]$r.repo_id){throw "Frozen changed path set includes undeclared repository '$($r.repo_id)'."}
        $allowed=@($Unit.allowed_repositories|Where-Object{[string]$_.repo_id -ceq [string]$r.repo_id})[0]
        foreach($path in @($r.paths)){if(-not(Test-MorphospaceCandidatePathAllowed -Path ([string]$path).TrimEnd('/') -Allowed @($allowed.allowed_paths))){throw "Frozen path '$($r.repo_id)/$path' exceeds the active write scope."}}
    }
    foreach($effect in @($Candidate.effects)){if(@($scope.allowed_effect_categories) -cnotcontains [string]$effect){throw "Frozen effect '$effect' exceeds the admitted envelope."}}
    foreach($permission in @($Candidate.permissions)){if(@($scope.allowed_permission_categories) -cnotcontains [string]$permission){throw "Frozen permission '$permission' exceeds the admitted envelope."}}
    foreach($device in @($Candidate.device_use)){if([string]$device -cne 'none' -and @($scope.device_envelope.allowed_kinds) -cnotcontains [string]$device){throw "Frozen device '$device' exceeds the admitted envelope."}}
    if(@($Candidate.cleanup_evidence).Count -lt 1 -or @($Candidate.instruction_surfaces).Count -lt 1){throw 'FreezeCandidate requires cleanup/evidence and instruction-surface declarations.'}
}
function Test-MorphospaceSelfHostedPlanningFreezeDirt {
    param(
        [string]$Workspace,
        [object]$Unit,
        [object]$RepositoryEntry,
        [object]$FrozenTransition
    )
    if($null-eq$FrozenTransition-or[string]$RepositoryEntry.role-cne'planning'){return $false}
    $repository=[IO.Path]::GetFullPath([string]$RepositoryEntry.path).TrimEnd('\','/')
    $workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $repositoryPrefix=$repository+[IO.Path]::DirectorySeparatorChar
    $workspaceRelative=if($workspaceFull.Equals($repository,[StringComparison]::OrdinalIgnoreCase)){''}elseif($workspaceFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)){$workspaceFull.Substring($repositoryPrefix.Length).Replace('\','/').TrimEnd('/')+'/' }else{return $false}
    $receiptRelative=([string]$Unit.candidate_freeze.receipt_path).Replace('\','/')
    $ownedWorkspacePaths=@(
        'workspace.state.json',
        'iteration-events.jsonl',
        "iteration-units/$([string]$Unit.unit_id).json",
        $receiptRelative,
        ([string]$FrozenTransition.intent_path).Replace('\','/'),
        ([string]$FrozenTransition.completion_path).Replace('\','/')
    )|Sort-Object -Unique
    if($ownedWorkspacePaths.Count-ne6-or@($ownedWorkspacePaths|Where-Object{[string]::IsNullOrWhiteSpace([string]$_)}).Count-ne0){return $false}
    if($FrozenTransition.PSObject.Properties.Name-ccontains'continuation_paths'){
        $visible=[Collections.Generic.List[string]]::new()
        foreach($path in @($FrozenTransition.continuation_paths)){
            $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$path)
            $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
            try{& git -C $repository check-ignore --quiet -- "$workspaceRelative$relative" 2>$null;$ignoredExit=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
            if($ignoredExit-notin@(0,1)){throw 'Frozen continuation Git ignore observation failed.'}
            if($ignoredExit-eq1){$visible.Add($relative)}
        }
        $ownedWorkspacePaths=@($ownedWorkspacePaths+@($visible.ToArray())|Sort-Object -Unique)
    }
    $expected=@($ownedWorkspacePaths|ForEach-Object{$workspaceRelative+$_}|Sort-Object -Unique)
    $staged=@(Invoke-MorphospaceCandidateGit $repository @('-c','core.safecrlf=false','diff','--cached','--name-only','--no-renames','--') 'self-hosted planning lifecycle staged-dirt observation'|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')}|Sort-Object -Unique)
    $unstaged=@(Invoke-MorphospaceCandidateGit $repository @('-c','core.safecrlf=false','diff','--name-only','--no-renames','--') 'self-hosted planning lifecycle unstaged-dirt observation'|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')}|Sort-Object -Unique)
    $untracked=@(Invoke-MorphospaceCandidateGit $repository @('ls-files','--others','--exclude-standard') 'self-hosted planning lifecycle untracked-dirt observation'|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')}|Sort-Object -Unique)
    $observed=@($staged+$unstaged+$untracked|Sort-Object -Unique)
    if($observed.Count-ne$expected.Count-or($observed-join'|')-cne($expected-join'|')){
        throw "Self-hosted planning repository dirt differs from the exact authenticated freeze transition (expected: $($expected-join', '); observed: $($observed-join', '))."
    }
    return $true
}
function Assert-MorphospaceCandidateRepositoryClosure {
    param([string]$Workspace,[object]$Candidate,[object]$Unit,[object]$FrozenTransition=$null)
    $map=Get-MorphospaceCandidateRepositoryMap $Workspace ([string]$Candidate.expected.repository_map_path)
    $composition=Get-MorphospaceCandidateSourceComposition $Workspace ([string]$Candidate.expected.source_composition_path) ([string]$Candidate.project_id) ([string]$Candidate.unit_id)
    if([string]$composition.schema-ceq'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'){
        $boundMapPath=[string]$composition.repository_map.path;$boundMapSha=[string]$composition.repository_map.raw_sha256
    }elseif([string]$composition.schema-cin@('rusty.morphospace.workflow.development_envelope_source_composition.v1','rusty.morphospace.workflow.development_envelope_source_composition.v2','rusty.morphospace.workflow.development_envelope_source_composition.v3')){
        $admission=Get-MorphospaceCandidatePreparationProvenance $Workspace ([string]$Candidate.unit_id)
        $boundMapPath=[string]$admission.document.expected.repository_map_path;$boundMapSha=[string]$admission.document.expected.repository_map_sha256
    }else{$boundMapPath='';$boundMapSha=''}
    if($boundMapPath-and([string]$Candidate.expected.repository_map_path-cne$boundMapPath-or[string]$Candidate.expected.repository_map_sha256-cne$boundMapSha-or(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $boundMapPath -RequireLeaf))-cne$boundMapSha)){throw 'Frozen candidate repository map is detached from its prepared or extended owner binding.'}
    $finalById=@{};foreach($final in @($Candidate.final_repositories)){
        $id=[string]$final.repo_id
        if(-not$id-or$finalById.ContainsKey($id)){throw "Frozen candidate final repositories repeat or omit '$id'."}
        $finalById[$id]=$final
    }
    $changedById=@{};foreach($changed in @($Candidate.changed_paths)){
        $id=[string]$changed.repo_id
        if(-not$id-or$changedById.ContainsKey($id)){throw "Frozen candidate changed-path records repeat or omit '$id'."}
        $changedById[$id]=$changed
    }
    $scopeById=@{};foreach($scope in @($Unit.allowed_repositories)){if($scopeById.ContainsKey([string]$scope.repo_id)){throw 'Active unit repeats a repository scope.'};$scopeById[[string]$scope.repo_id]=$scope}
    $compositionById=@{};foreach($row in @(Get-MorphospaceSourceCompositionRepositoryPins $composition)){
        $id=[string]$row.repo_id
        if(-not$id-or$compositionById.ContainsKey($id)){throw "Frozen candidate source composition repeats or omits '$id'."}
        $compositionById[$id]=$row
    }
    if($finalById.Count-ne$scopeById.Count-or$changedById.Count-ne$scopeById.Count){throw 'Frozen candidate repository and changed-path sets must exactly equal the active writable scope.'}
    foreach($id in @($compositionById.Keys|Sort-Object)){
        if(-not$map.ContainsKey($id)){throw "Frozen candidate source-composition repository '$id' is absent from the repository map."}
        $bound=$compositionById[$id];$entry=$map[$id]
        if([string]$bound.role-cne[string]$entry.role){throw "Frozen candidate source-composition role differs from the repository map for '$id'."}
        $lockedCommit=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse',"$([string]$bound.commit)^{commit}") 'source-composition commit-object observation')[0]).Trim().ToLowerInvariant()
        $lockedTree=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse',"$([string]$bound.commit)^{tree}") 'source-composition tree-object observation')[0]).Trim().ToLowerInvariant()
        if($lockedCommit-cne[string]$bound.commit-or$lockedTree-cne[string]$bound.tree){throw "Frozen candidate source-composition object identity differs for '$id'."}
        if(-not$scopeById.ContainsKey($id)){
            $head=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse','HEAD') 'read-only dependency commit observation')[0]).Trim().ToLowerInvariant()
            $tree=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse','HEAD^{tree}') 'read-only dependency tree observation')[0]).Trim().ToLowerInvariant()
            if($head-cne[string]$bound.commit-or$tree-cne[string]$bound.tree){throw "Frozen candidate live read-only dependency identity drifted for '$id'."}
            if([string]$entry.role-ceq'source'){
                $tracked=@(Invoke-MorphospaceCandidateGit $entry.path @('status','--porcelain=v1','--untracked-files=no') 'read-only dependency tracked-cleanliness observation')
                if($tracked.Count-ne0){throw "Frozen candidate read-only source dependency '$id' is not tracked-clean."}
            }
        }
    }
    foreach($id in @($scopeById.Keys|Sort-Object)){
        if(-not$finalById.ContainsKey($id)-or-not$changedById.ContainsKey($id)-or-not$compositionById.ContainsKey($id)-or-not$map.ContainsKey($id)){throw "Frozen candidate closure is incomplete for '$id'."}
        $final=$finalById[$id];$bound=$compositionById[$id];$entry=$map[$id]
        $head=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse','HEAD') 'writable candidate commit observation')[0]).Trim().ToLowerInvariant()
        $tree=(@(Invoke-MorphospaceCandidateGit $entry.path @('rev-parse','HEAD^{tree}') 'writable candidate tree observation')[0]).Trim().ToLowerInvariant()
        if($head-cne[string]$final.commit-or$tree-cne[string]$final.tree){throw "Frozen candidate live writable repository identity drifted for '$id'."}
        [void](Invoke-MorphospaceCandidateGit $entry.path @('merge-base','--is-ancestor',[string]$bound.commit,[string]$final.commit) 'baseline-to-candidate ancestry observation')
        $committed=@(Invoke-MorphospaceCandidateGit $entry.path @('diff','--name-only','--no-renames',"$([string]$bound.commit)..$([string]$final.commit)",'--') 'baseline-to-candidate changed-path observation'|Where-Object{$_}|Sort-Object -Unique)
        foreach($path in $committed){
            if(-not(Test-MorphospaceCandidatePathAllowed $path @($changedById[$id].paths))){throw "Frozen candidate committed path '$id/$path' is outside its declared changed-path closure."}
            if(-not(Test-MorphospaceCandidatePathAllowed $path @($scopeById[$id].allowed_paths))){throw "Frozen candidate committed path '$id/$path' exceeds the active scope."}
        }
        if([string]$Candidate.cleanliness_policy-ceq'clean-only'){
            $observed=@(Invoke-MorphospaceCandidateGit $entry.path @('status','--porcelain=v1','--untracked-files=all') 'cleanliness observation')
            if($observed.Count-ne0-and-not(Test-MorphospaceSelfHostedPlanningFreezeDirt -Workspace $workspace -Unit $Unit -RepositoryEntry $entry -FrozenTransition $FrozenTransition)){throw "Frozen candidate clean-only repository '$id' is dirty outside the exact authenticated self-hosted planning freeze transition."}
        }else{
            $tracked=@(Invoke-MorphospaceCandidateGit $entry.path @('diff','--name-only','HEAD','--') 'changed-path observation')
            $untracked=@(Invoke-MorphospaceCandidateGit $entry.path @('ls-files','--others','--exclude-standard') 'untracked-path observation')
            $observed=@($tracked+$untracked|Where-Object{$_}|Sort-Object -Unique)
            if($observed.Count-eq0){throw "Frozen candidate declared-dirty repository '$id' has no observed changes."}
            foreach($path in $observed){if(-not(Test-MorphospaceCandidatePathAllowed $path @($changedById[$id].paths))){throw "Frozen candidate observed dirty path '$id/$path' is outside its declared changed-path closure."}}
        }
        foreach($declared in @($changedById[$id].paths)){if(-not(Test-MorphospaceCandidatePathAllowed ([string]$declared).TrimEnd('/') @($scopeById[$id].allowed_paths))){throw "Frozen candidate changed path '$id/$declared' exceeds the active scope."}}
    }
}
function Copy-FrozenContinuationValue {
    param([object]$Value)
    ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $Value)
}
function Assert-FrozenContinuationEqual {
    param([object]$Expected,[object]$Actual,[string]$Context)
    if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$Expected}))-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$Actual}))){throw "Frozen validation continuation $Context is detached."}
}
function Get-FrozenContinuationAutomationModule {
    param([string]$Workspace,[object]$Unit)
    $root=Split-Path $PSScriptRoot -Parent
    if($Unit.PSObject.Properties.Name-ccontains'tooling_context'){
        $pointer=$Unit.tooling_context;$path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$pointer.path) -RequireLeaf
        $context=Read-MorphospaceProtocolJson $path
        if((Get-MorphospaceFileSha256 $path)-cne[string]$pointer.sha256-or(Get-MorphospaceCanonicalJsonSha256 $context)-cne[string]$pointer.canonical_sha256){throw 'Frozen continuation tooling context pointer is detached.'}
        $toolingModule=Import-Module (Join-Path $PSScriptRoot 'ToolingContextProvenance.psm1') -PassThru
        & $toolingModule { param($parameters) Assert-MorphospaceToolingContextLocalObservation @parameters } @{WorkspaceRoot=$Workspace;Context=$context}|Out-Null
        $resolver=& $toolingModule { param($parameters) Read-MorphospaceToolingContextResolver @parameters } @{WorkspaceRoot=$Workspace;Context=$context}
        $root=[string]$resolver.executor_root
    }
    $automationModule=Import-Module (Join-Path $root 'scripts/WorkUnitAutomation.psm1') -PassThru
    if($Unit.PSObject.Properties.Name-ccontains'tooling_context'){& $toolingModule { param($parameters) Assert-MorphospaceToolingContextLoadedOwnerModule @parameters } @{Context=$context;ExecutorRoot=$root;OwnerModule=$automationModule}|Out-Null}
    return $automationModule
}
function Get-FrozenContinuationRepositoryProjection {
    param([string]$Workspace,[object]$Candidate,[object]$Unit,[object]$BeforeState,[object]$RecordedTarget)
    $projected=Copy-FrozenContinuationValue $BeforeState
    $map=Get-MorphospaceCandidateRepositoryMap $Workspace ([string]$Candidate.expected.repository_map_path)
    $automationModule=Get-FrozenContinuationAutomationModule $Workspace $Unit
    $dirty=@{};foreach($id in @($projected.dirty_repositories)){$dirty[[string]$id]=$true}
    $heads=@{};if($projected.PSObject.Properties.Name-ccontains'repository_heads'){foreach($head in @($projected.repository_heads)){$heads[[string]$head.repo_id]=$head}}
    foreach($allowed in @($Unit.allowed_repositories)){
        $id=[string]$allowed.repo_id;if(-not$map.ContainsKey($id)){continue}
        $observed=& $automationModule { param($parameters) Get-MorphospaceRepositoryState @parameters } @{RepoId=$id;Path=([string]$map[$id].path)}
        if(-not($observed.PSObject.Properties.Name-ccontains'dirty')){continue}
        if($observed.dirty){$dirty[$id]=$true}else{$dirty.Remove($id)}
        if([string]$projected.schema-ceq'rusty.morphospace.workflow.workspace_state.v2'-and$observed.is_git){
            $status=@($observed.status_porcelain|ForEach-Object{[string]$_}|Sort-Object)
            $fingerprint=Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($status-join"`n")))
            $root=[IO.Path]::GetFullPath([string]$map[$id].path).TrimEnd('\','/');$prefix=$root+[IO.Path]::DirectorySeparatorChar
            $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
            $selfHosted=([string]$map[$id].role-ceq'planning')-and([IO.Path]::GetFullPath($Workspace).Equals($root,$comparison)-or[IO.Path]::GetFullPath($Workspace).StartsWith($prefix,$comparison))
            if($selfHosted){
                # Ordinary producers retained this pre-event observation, not a
                # historical Git index. It is not source or scope authority.
                # Current owned dirt is independently authenticated below.
                $recorded=@($RecordedTarget.repository_heads|Where-Object{[string]$_.repo_id-ceq$id})
                if($recorded.Count-ne1-or[string]$recorded[0].dirty_fingerprint-cnotmatch'^[0-9a-f]{64}$'){throw 'Frozen continuation historical planning observation is malformed.'}
                $fingerprint=[string]$recorded[0].dirty_fingerprint
            }
            $heads[$id]=[pscustomobject][ordered]@{repo_id=$id;head=[string]$observed.head;branch=$observed.branch;dirty_fingerprint=$fingerprint}
        }
    }
    $projected.dirty_repositories=@($dirty.Keys|Sort-Object)
    if([string]$projected.schema-ceq'rusty.morphospace.workflow.workspace_state.v2'){
        $projected.repository_heads=@($heads.Values|Sort-Object repo_id)
        $feature=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'feature.lock.json' -RequireLeaf)
        if([string]$feature.schema-ceq'rusty.morphospace.workflow.feature_lock.v2'){
            $project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'project.spec.json' -RequireLeaf)
            $projected.module_registry=[pscustomobject][ordered]@{lock_revision=[int]$feature.revision;lock_fingerprint=[string]$feature.lock_fingerprint;modules=@($project.modules|Where-Object{$_.selected-eq$true}|Sort-Object module_id|ForEach-Object{[pscustomobject][ordered]@{module_id=[string]$_.module_id;owner_repo=[string]$_.source_repo;maturity=[string]$_.maturity;contract=[string]$_.contract;contract_revision=[string]$_.contract_revision}})}
        }
    }
    return $projected
}
function Assert-FrozenContinuationReturnReceipt {
    param([string]$Workspace,[object]$Candidate,[object]$Unit,[object]$Event,[object]$Checkpoint,[string[]]$OwnedBeforePaths=@())
    if(@($Event.receipts).Count-ne1-or[string]$Event.receipts[0]-cne[string]$Checkpoint.receipt-or@('fail','partial','blocked')-cnotcontains[string]$Checkpoint.result){throw 'Frozen continuation Return receipt or nonpassing checkpoint is detached.'}
    $path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Checkpoint.receipt) -RequireLeaf
    $receipt=Assert-MorphospaceValidationReceiptStructure -ReceiptPath $path -AllowedSchemaIds @('rusty.morphospace.workflow.validation_receipt.v1')
    if([string]$receipt.project_id-cne[string]$Unit.project_id-or[string]$receipt.unit_id-cne[string]$Unit.unit_id-or[string]$receipt.result-cne[string]$Checkpoint.result-or[string]$receipt.tier-cne[string]$Checkpoint.tier){throw 'Frozen continuation Return validation identity is detached.'}
    $automationModule=Get-FrozenContinuationAutomationModule $Workspace $Unit
    $inspection=& $automationModule { param($parameters) Invoke-MorphospaceWorkUnitAutomation @parameters } @{WorkspaceRoot=$Workspace;UnitId=([string]$Unit.unit_id);Action='Inspect';RepoMapPath=(Resolve-MorphospaceWorkspacePath $Workspace ([string]$Candidate.expected.repository_map_path) -RequireLeaf);ValidationTier=([string]$receipt.tier)}
    $criteria=@($Unit.acceptance|ForEach-Object{[string]$_.acceptance_id}|Sort-Object -CaseSensitive)
    Assert-FrozenContinuationEqual $criteria @($receipt.criteria|ForEach-Object{[string]$_.acceptance_id}|Sort-Object -CaseSensitive) 'Return criterion set'
    $applicable=@($inspection.validation_matrix|Where-Object{[string]$_.disposition-cne'forbidden'})
    Assert-FrozenContinuationEqual @($applicable|ForEach-Object{[string]$_.gate_id}|Sort-Object -CaseSensitive) @($receipt.gates|ForEach-Object{[string]$_.gate_id}|Sort-Object -CaseSensitive) 'Return gate set'
    foreach($criterion in @($Unit.acceptance)){$row=@($receipt.criteria|Where-Object{[string]$_.acceptance_id-ceq[string]$criterion.acceptance_id});if($row.Count-ne1-or[string]$row[0].command-cne[string]$criterion.command){throw 'Frozen continuation Return criterion command is detached.'}}
    $unmatched=[Collections.Generic.List[object]]::new();foreach($gate in $applicable){$unmatched.Add($gate)}
    foreach($gate in @($receipt.gates)){$index=-1;for($i=0;$i-lt$unmatched.Count;$i++){if([string]$unmatched[$i].gate_id-ceq[string]$gate.gate_id-and[string]$unmatched[$i].command-ceq[string]$gate.command){$index=$i;break}};if($index-lt0){throw 'Frozen continuation Return gate command is detached.'};$unmatched.RemoveAt($index)}
    if($unmatched.Count-ne0){throw 'Frozen continuation Return gate coverage is incomplete.'}
    $artifacts=@{}
    foreach($artifact in @($receipt.artifacts)){
        $artifactId=[string]$artifact.artifact_id;if($artifacts.ContainsKey($artifactId)){throw 'Frozen continuation Return receipt repeats an artifact identity.'};$artifacts[$artifactId]=$artifact
        $artifactPath=if([IO.Path]::IsPathRooted([string]$artifact.path)){[IO.Path]::GetFullPath([string]$artifact.path)}else{[IO.Path]::GetFullPath((Join-Path (Split-Path $path -Parent) ([string]$artifact.path)))}
        if((Get-MorphospaceFileSha256 $artifactPath)-cne([string]$artifact.sha256).ToLowerInvariant()){throw 'Frozen continuation retained validation artifact drifted.'}
    }
    foreach($row in @($receipt.criteria)+@($receipt.gates)){foreach($reference in @($row.evidence_refs)){if(-not$artifacts.ContainsKey([string]$reference)){throw 'Frozen continuation retained validation evidence reference is unknown.'}}}
    if([string]$Unit.device_requirement-ceq'forbidden'-and$null-ne$receipt.device_validation){throw 'Frozen continuation forbidden device evidence is present.'}
    $map=Get-MorphospaceCandidateRepositoryMap $Workspace ([string]$Candidate.expected.repository_map_path)
    $ids=@($Unit.allowed_repositories|ForEach-Object{[string]$_.repo_id}|Sort-Object -CaseSensitive)
    Assert-FrozenContinuationEqual $ids @($receipt.repository_revisions|ForEach-Object{[string]$_.repo_id}|Sort-Object -CaseSensitive) 'Return source set'
    foreach($revision in @($receipt.repository_revisions)){
        $id=[string]$revision.repo_id;$final=@($Candidate.final_repositories|Where-Object{[string]$_.repo_id-ceq$id})
        if($final.Count-ne1-or[string]$revision.head_revision-cne[string]$final[0].commit){throw 'Frozen continuation Return source HEAD is detached.'}
        $repository=[string]$map[$id].path
        $branch=@(Invoke-MorphospaceCandidateGit $repository @('branch','--show-current') 'Return branch')[0]
        if([string]$revision.branch-cne$branch){throw 'Frozen continuation Return source branch is detached.'}
        [void](Invoke-MorphospaceCandidateGit $repository @('merge-base','--is-ancestor',[string]$revision.base_revision,[string]$revision.head_revision) 'Return base ancestry')
        $allowed=@($Unit.allowed_repositories|Where-Object{[string]$_.repo_id-ceq$id})[0]
        $repoFull=[IO.Path]::GetFullPath($repository).TrimEnd('\','/');$workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/');$repoPrefix=$repoFull+[IO.Path]::DirectorySeparatorChar
        $nestedPrefix=if($workspaceFull.StartsWith($repoPrefix,[StringComparison]::OrdinalIgnoreCase)){$workspaceFull.Substring($repoPrefix.Length).Replace('\','/')+'/'}elseif($workspaceFull.Equals($repoFull,[StringComparison]::OrdinalIgnoreCase)){''}else{$null}
        $changed=@(Invoke-MorphospaceCandidateGit $repository @('diff','--name-only','--no-renames',"$([string]$revision.base_revision)..$([string]$revision.head_revision)",'--') 'Return changed paths'|Where-Object{$_})
        # Ordinary receipt validation includes scoped worktree changes.  For
        # historical returns, derive these from the authenticated predecessor
        # controls, rather than observing later suffix dirt as earlier evidence.
        if($null-ne$nestedPrefix-and[string]$map[$id].role-ceq'planning'){
            foreach($owned in @($OwnedBeforePaths)+@([string]$Checkpoint.receipt)){
                $relative=ConvertTo-MorphospaceProtocolRelativePath $owned
                $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
                try{& git -C $repository check-ignore --quiet -- "$nestedPrefix$relative" 2>$null;$ignoredExit=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
                if($ignoredExit-notin@(0,1)){throw 'Frozen continuation Return ignore observation failed.'}
                if($ignoredExit-eq1){$changed+=,"$nestedPrefix$relative"}
            }
        }
        $transactionPrefix=if($null-ne$nestedPrefix){$nestedPrefix+'receipts/transactions/'}else{''}
        $changed=@($changed|Where-Object{(Test-MorphospaceCandidatePathAllowed ([string]$_) @($allowed.allowed_paths))-and(-not$transactionPrefix-or-not([string]$_).StartsWith($transactionPrefix,[StringComparison]::OrdinalIgnoreCase))}|Sort-Object -CaseSensitive -Unique)
        Assert-FrozenContinuationEqual $changed @($receipt.changed_paths|Where-Object{[string]$_.repo_id-ceq$id}|ForEach-Object{[string]$_.path}|Sort-Object -CaseSensitive) 'Return changed paths'
    }
}
function Get-MorphospaceFrozenCandidateTransition {
    param([string]$Workspace,[object]$Candidate,[object]$LiveState,[object]$LiveUnit,[string]$ReceiptRelative,[string]$LedgerWorkspace='')
    if(-not$LedgerWorkspace){$LedgerWorkspace=$Workspace}
    $transactionId="$([string]$Candidate.freeze_id)-recorded-transition"
    $binding=& $script:CandidateLedgerModule { param($parameters) Test-MorphospaceCommittedTransitionLedger @parameters } @{WorkspaceRoot=$LedgerWorkspace;TransactionId=$transactionId;ExpectedStatePath='workspace.state.json';ExpectedUnitPath="iteration-units/$([string]$Candidate.unit_id).json";ExpectedEventsPath='iteration-events.jsonl'}
    $binding|Add-Member -NotePropertyName intent_path -NotePropertyValue "receipts/transactions/$transactionId.intent.json"
    $binding|Add-Member -NotePropertyName completion_path -NotePropertyValue "receipts/transactions/$transactionId.completion.json"
    $intent=$binding.intent;$completion=$binding.completion;$eventId="$([string]$Candidate.freeze_id)-recorded"
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v3'-or[string]$intent.transaction_id-cne$transactionId-or[string]$intent.event.event_id-cne$eventId-or[string]$intent.event.project_id-cne[string]$Candidate.project_id-or[string]$intent.event.unit_id-cne[string]$Candidate.unit_id-or@($intent.event.receipts).Count-ne1-or[string]@($intent.event.receipts)[0]-cne$ReceiptRelative){throw 'Frozen candidate transition identity or receipt binding is not exact.'}
    if([string]$intent.pre.state.sha256-cne[string]$Candidate.expected.state_sha256-or[string]$intent.pre.unit.sha256-cne[string]$Candidate.expected.unit_sha256-or[string]$intent.expected.events_sha256-cne[string]$Candidate.expected.events_sha256-or[int64]$intent.expected.events_length-ne[int64]$Candidate.expected.events_length-or[string]$intent.expected.event_tail_id-cne[string]$Candidate.expected.event_tail_id){throw 'Frozen candidate transition pre-state or ledger binding differs from the receipt.'}
    if([string]$intent.target.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $LiveState)-or[string]$intent.target.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $LiveUnit)){throw 'Frozen candidate transition target state or unit differs from live bytes.'}
    if(@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].path-cne$ReceiptRelative-or[string]$intent.artifacts[0].sha256-cne(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $ReceiptRelative -RequireLeaf))){throw 'Frozen candidate transition artifact binding differs from the receipt.'}
    if([string]$completion.transaction_id-cne$transactionId-or[string]$completion.event_id-cne$eventId-or[string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256){throw 'Frozen candidate transition completion differs from its exact intent.'}
    return $binding
}
function Get-MorphospaceFrozenValidationContinuation {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Unit,[string]$PendingReentry='')
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$unitPath="iteration-units/$([string]$Unit.unit_id).json"
    $liveUnit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    Assert-FrozenContinuationEqual $liveUnit $Unit 'supplied live unit'
    $pending=$null;$ledgerWorkspace=$workspace
    try{
    if($PendingReentry){
        $pendingModule=Import-Module (Join-Path $PSScriptRoot 'FrozenValidationReentry.psm1') -PassThru
        $pending=& $pendingModule { param($parameters) Get-MorphospaceFrozenValidationReentryPendingObservation @parameters } @{WorkspaceRoot=$workspace;RequestPath=$PendingReentry}
        if([string]$pending.unit.unit_id-cne[string]$Unit.unit_id){throw 'Frozen continuation pending request belongs to a different unit.'}
        $ledgerWorkspace=[string]$pending.ledger_workspace;$liveUnit=$pending.unit
    }
    if(-not($liveUnit.PSObject.Properties.Name-ccontains'candidate_freeze')){throw 'Frozen continuation requires an immutable candidate Freeze.'}
    $marker=$liveUnit.candidate_freeze;$receiptPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$marker.receipt_path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $receiptPath)-cne[string]$marker.receipt_sha256){throw 'Frozen candidate receipt hash drifted.'}
    $candidate=Read-MorphospaceProtocolJson $receiptPath;$repoRoot=Split-Path $PSScriptRoot -Parent
    if([string]$candidate.schema-cne'rusty.morphospace.workflow.candidate_freeze.v1'-or-not(Test-Json -Json (Get-Content -LiteralPath $receiptPath -Raw) -SchemaFile (Join-Path $repoRoot 'schemas/candidate-freeze-v1.schema.json') -ErrorAction SilentlyContinue)){throw 'Frozen continuation requires a valid original v1 Freeze.'}
    if([string]$candidate.freeze_id-cne[string]$marker.freeze_id-or[string]$candidate.unit_id-cne[string]$liveUnit.unit_id){throw 'Frozen candidate receipt identity does not match its unit marker.'}
    $state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
    if($null-ne$pending){$state=$pending.state}
    $project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf)
    $feature=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf)
    if([string]$candidate.project_id-cne[string]$project.project_id-or[string]$state.current_unit-cne[string]$liveUnit.unit_id-or@('active','validating')-cnotcontains[string]$liveUnit.status){throw 'Frozen candidate identity no longer matches the live active authority.'}
    foreach($pair in @(@('project',$candidate.expected.project_sha256,(Get-MorphospaceCanonicalJsonSha256 $project)),@('feature lock',$candidate.expected.feature_lock_sha256,(Get-MorphospaceCanonicalJsonSha256 $feature)),@('source composition',$candidate.expected.source_composition_sha256,(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.expected.source_composition_path) -RequireLeaf))),@('repository map',$candidate.expected.repository_map_sha256,(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.expected.repository_map_path) -RequireLeaf))))){if([string]$pair[1]-cne[string]$pair[2]){throw "Frozen candidate $($pair[0]) drifted after freeze."}}
    if([string]$candidate.source_composition.path-cne[string]$candidate.expected.source_composition_path-or[string]$candidate.source_composition.sha256-cne[string]$candidate.expected.source_composition_sha256-or[int]$candidate.feature_lock.revision-ne[int]$feature.revision-or[string]$candidate.feature_lock.sha256-cne[string]$candidate.expected.feature_lock_sha256){throw 'Frozen continuation immutable source or feature closure is detached.'}
    $id="$([string]$candidate.freeze_id)-recorded-transition"
    $original=& $script:CandidateLedgerModule { param($parameters) Test-MorphospaceCommittedTransitionLedger @parameters } @{WorkspaceRoot=$ledgerWorkspace;TransactionId=$id;ExpectedStatePath='workspace.state.json';ExpectedUnitPath=$unitPath;ExpectedEventsPath='iteration-events.jsonl'}
    $originalUnit=$original.intent.target.unit.document;$originalState=$original.intent.target.state.document
    $frozen=Get-MorphospaceFrozenCandidateTransition $workspace $candidate $originalState $originalUnit ([string]$marker.receipt_path) $ledgerWorkspace
    $preState=Copy-FrozenContinuationValue $originalState;$preState.last_event_id=[string]$candidate.expected.event_tail_id
    if((Get-MorphospaceCanonicalJsonSha256 $preState)-cne[string]$candidate.expected.state_sha256-or[string]$originalUnit.status-cne'active'-or[string]$originalState.current_unit-cne[string]$candidate.unit_id-or[string]$original.intent.event.event_type-cne'state-transition'-or[string]$original.intent.event.summary-cne'Froze the exact candidate closure before validation.'){throw 'Frozen continuation original state or producer semantics is detached.'}
    $projections=@($original.intent.additional_projections)
    if($projections.Count-ne2){throw 'Frozen continuation original retained envelope projections are incomplete.'}
    foreach($pair in @(@('project.spec.json',$candidate.expected.project_sha256,$project),@('feature.lock.json',$candidate.expected.feature_lock_sha256,$feature))){$match=@($projections|Where-Object{[string]$_.path-ceq[string]$pair[0]});if($match.Count-ne1-or[string]$match[0].pre_sha256-cne[string]$pair[1]-or[string]$match[0].target_sha256-cne[string]$pair[1]){throw 'Frozen continuation original retained projection hash is detached.'};Assert-FrozenContinuationEqual $pair[2] $match[0].document 'original retained projection'}
    $preUnit=Copy-FrozenContinuationValue $originalUnit;$preUnit.PSObject.Properties.Remove('candidate_freeze')
    if((Get-MorphospaceCanonicalJsonSha256 $preUnit)-cne[string]$candidate.expected.unit_sha256){throw 'Frozen continuation original unit preimage is detached.'}
    Assert-FrozenContinuationEqual $marker $originalUnit.candidate_freeze 'original Freeze marker'
    Assert-MorphospaceFrozenCandidateScope $candidate $preUnit
    $events=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $ledgerWorkspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_}|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$_))})
    $currentUnit=Copy-FrozenContinuationValue $originalUnit;$currentState=Copy-FrozenContinuationValue $originalState
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$transitions=[Collections.Generic.List[object]]::new()
    foreach($event in @($events|Where-Object{[int64]$_.sequence-gt[int64]$original.intent.event.sequence})){
        if([string]$event.project_id-cne[string]$candidate.project_id-or[string]$event.unit_id-cne[string]$candidate.unit_id){throw 'Frozen continuation contains a foreign owner suffix.'}
        $transitionId="$([string]$event.event_id)-transition"
        $proof=& $script:CandidateLedgerModule { param($parameters) Test-MorphospaceCommittedTransitionLedger @parameters } @{WorkspaceRoot=$ledgerWorkspace;TransactionId=$transitionId;ExpectedStatePath='workspace.state.json';ExpectedUnitPath=$unitPath;ExpectedEventsPath='iteration-events.jsonl'}
        $intent=$proof.intent
        if([string]$intent.pre.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $currentUnit)-or[string]$intent.pre.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $currentState)-or[string]$intent.expected.event_tail_id-cne[string]$currentState.last_event_id){throw 'Frozen continuation predecessor authority is detached.'}
        $targetUnit=Copy-FrozenContinuationValue $currentUnit;$targetState=Copy-FrozenContinuationValue $currentState
        $bridge=@();foreach($artifact in @($intent.artifacts)){$doc=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$artifact.bytes_base64));if([string]$doc.schema-ceq'rusty.morphospace.workflow.frozen_validation_reentry.v1'){$bridge+=,$doc}}
        if($bridge.Count-gt0){
            if($bridge.Count-ne1-or[string]$currentUnit.status-cne'active'){throw 'Frozen continuation repeated or misplaced re-entry request.'}
            $reentryModule=Import-Module (Join-Path $PSScriptRoot 'FrozenValidationReentry.psm1') -PassThru
            & $reentryModule { param($parameters) Assert-MorphospaceFrozenValidationReentryHistoricalTransition @parameters } @{WorkspaceRoot=$workspace;Transition=$proof}
            $targetUnit.status='validating'
        }elseif([string]$currentUnit.status-ceq'active'){
            if([string]$event.event_type-cne'state-transition'-or[string]$event.event_id-cnotmatch'-validating-[0-9]{4}$'-or[string]$event.summary-cne'Entered validation with a deterministic command, instruction, graph, and device-impact plan.'-or@($event.receipts).Count-ne0-or@($intent.artifacts).Count-ne0){throw 'Frozen continuation does not contain an ordinary BeginValidation transition.'}
            $targetUnit.status='validating'
            $targetState=Get-FrozenContinuationRepositoryProjection $workspace $candidate $currentUnit $targetState $intent.target.state.document
        }else{
            if([string]$event.event_type-cne'validation'-or[string]$event.event_id-cnotmatch'-validation-(fail|partial|blocked)-return-[0-9]{4}$'-or[string]$event.summary-cne'Retained a non-passing validation attempt and returned the same feature unit to active for an in-scope correction.'-or@($intent.artifacts).Count-ne0){throw 'Frozen continuation does not contain an ordinary nonpassing ReturnToActive transition.'}
            $checkpoint=$intent.target.state.document.validation_checkpoint
            $beforePaths=@('workspace.state.json','iteration-events.jsonl',$unitPath,[string]$marker.receipt_path)+@($paths)
            Assert-FrozenContinuationReturnReceipt $workspace $candidate $currentUnit $event $checkpoint $beforePaths
            $targetUnit.status='active';$targetState.validation_checkpoint=Copy-FrozenContinuationValue $checkpoint
            $targetState=Get-FrozenContinuationRepositoryProjection $workspace $candidate $currentUnit $targetState $intent.target.state.document
            [void]$paths.Add([string]$checkpoint.receipt)
        }
        $targetState.last_event_id=[string]$event.event_id
        Assert-FrozenContinuationEqual $targetUnit $intent.target.unit.document 'target unit'
        Assert-FrozenContinuationEqual $targetState $intent.target.state.document 'target state'
        if($bridge.Count-eq0-and@($(if($intent.PSObject.Properties.Name-ccontains'additional_projections'){$intent.additional_projections})).Count-ne0){throw 'Frozen continuation adds an unexpected envelope projection.'}
        [void]$paths.Add("receipts/transactions/$transitionId.intent.json");[void]$paths.Add("receipts/transactions/$transitionId.completion.json")
        foreach($artifact in @($intent.artifacts)){[void]$paths.Add([string]$artifact.path)}
        $currentUnit=$targetUnit;$currentState=$targetState;$transitions.Add($proof)
    }
    Assert-FrozenContinuationEqual $currentUnit $liveUnit 'terminal live unit'
    Assert-FrozenContinuationEqual $currentState $state 'terminal live state'
    if($null-ne$pending){foreach($path in @($pending.owned_paths)){[void]$paths.Add([string]$path)}}
    $frozen|Add-Member -NotePropertyName continuation_paths -NotePropertyValue @($paths|Sort-Object -CaseSensitive)
    Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $liveUnit $frozen
    [pscustomobject]@{candidate=$candidate;freeze_transition=$frozen;transitions=@($transitions.ToArray());unit=$liveUnit;state=$state;repository_map_path=[string]$candidate.expected.repository_map_path}
    }finally{if($null-ne$pending){& $pendingModule { param($parameters) Remove-ReentryDerivedObservation @parameters } @{Path=([string]$pending.ledger_workspace)}}}
}
function Test-MorphospaceFrozenCandidate {
    param([string]$WorkspaceRoot,[object]$Unit)
    # This applies to all units.  It is deliberately before the W-016
    # admission branch so a historical evidence declaration cannot bypass the
    # post-Claim, task-local materialization gate on a legacy-shaped unit.
    [void](Test-MorphospaceInheritedCandidateMaterializationGate -WorkspaceRoot $WorkspaceRoot -Unit $Unit)
    if(-not($Unit.PSObject.Properties.Name -contains 'agent_scope_assessment')){return $true}
    if(-not($Unit.PSObject.Properties.Name -contains 'candidate_freeze')){throw 'This admitted development unit must be frozen before validation.'}
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$freeze=$Unit.candidate_freeze;$path=Resolve-MorphospaceWorkspacePath $workspace ([string]$freeze.receipt_path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $path) -cne [string]$freeze.receipt_sha256){throw 'Frozen candidate receipt hash drifted.'}
    $repoRoot=Split-Path $PSScriptRoot -Parent
    $candidate=Read-MorphospaceProtocolJson $path
    if([string]$candidate.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v2'){
        if(-not(Test-Json -Json (Get-Content -Raw $path) -SchemaFile (Join-Path $repoRoot 'schemas\candidate-freeze-v2.schema.json'))){throw 'Rematerialized frozen candidate receipt is malformed.'}
        Import-Module (Join-Path $PSScriptRoot 'ValidatingCandidateRematerialization.psm1') -Force
        return [bool](Test-MorphospaceRematerializedCandidate -WorkspaceRoot $workspace -Unit $Unit)
    }
    if([string]$candidate.schema-cne'rusty.morphospace.workflow.candidate_freeze.v1'-or-not(Test-Json -Json (Get-Content -Raw $path) -SchemaFile (Join-Path $repoRoot 'schemas\candidate-freeze-v1.schema.json'))){throw 'Frozen candidate receipt is malformed.'}
    if([string]$candidate.freeze_id -cne [string]$freeze.freeze_id -or [string]$candidate.unit_id -cne [string]$Unit.unit_id){throw 'Frozen candidate receipt identity does not match its unit marker.'}
    [void](Get-MorphospaceFrozenValidationContinuation -WorkspaceRoot $workspace -Unit $Unit)
    return $true
}
function Invoke-MorphospaceFreezeCandidate {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$UnitId,[string]$CandidateFreeze,[string]$ExpectedCandidateFreezeSha256='',[string]$Timestamp='',[string]$OutPath,[switch]$Execute)
    $repoRoot=Split-Path $PSScriptRoot -Parent;$workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $CandidateFreeze).Path
    if(-not(Test-Json -Json (Get-Content -Raw $input) -SchemaFile (Join-Path $repoRoot 'schemas\candidate-freeze-v1.schema.json'))){throw 'Candidate freeze does not satisfy its schema.'}
    $candidate=Read-MorphospaceProtocolJson $input;$project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf);$unitPath="iteration-units/$UnitId.json";$unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf);$featureLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf);$eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf;$events=@(Get-Content $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json});$tail=$events[-1]
    if([string]$candidate.project_id -cne [string]$project.project_id -or [string]$candidate.unit_id -cne $UnitId -or [string]$unit.status -cne 'active' -or [string]$state.current_unit -cne $UnitId){throw 'FreezeCandidate requires the matching active current unit.'}
    if($unit.PSObject.Properties.Name-contains'tooling_context'){
        [void](Get-MorphospaceUnitToolingContextObservation -WorkspaceRoot $workspace -UnitId $UnitId -Action FreezeCandidate -OwnerModule $MyInvocation.MyCommand.Module)
    }
    [void](Test-MorphospaceInheritedCandidateMaterializationGate -WorkspaceRoot $workspace -Unit $unit)
    if(-not($unit.PSObject.Properties.Name -contains 'agent_scope_assessment')){throw 'FreezeCandidate is reserved for development-envelope admitted units.'}
    $inputHash=Get-MorphospaceFileSha256 $input;$outRelative="receipts/$([string]$candidate.freeze_id).json"
    if($unit.PSObject.Properties.Name -contains 'candidate_freeze'){if([string]$unit.candidate_freeze.receipt_sha256 -ceq $inputHash -and [string]$unit.candidate_freeze.freeze_id -ceq [string]$candidate.freeze_id){return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$project.project_id;unit_id=$UnitId;action='FreezeCandidate';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='candidate-already-frozen';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$outRelative;sha256=$inputHash};event_id=$null}};throw 'Conflicting candidate freeze is rejected.'}
    $e=$candidate.expected;foreach($check in @(@{e=$e.project_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $project);n='project'},@{e=$e.state_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $state);n='state'},@{e=$e.unit_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $unit);n='unit'},@{e=$e.feature_lock_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $featureLock);n='feature lock'},@{e=$e.source_composition_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $e.source_composition_path -RequireLeaf));n='source composition'},@{e=$e.repository_map_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $e.repository_map_path -RequireLeaf));n='repository map'},@{e=$e.events_sha256;a=(Get-MorphospaceFileSha256 $eventsPath);n='ledger'})){if([string]$check.e -cne [string]$check.a){throw "FreezeCandidate stale $($check.n) preimage (expected $($check.e), actual $($check.a), state-tail $($state.last_event_id))."}}
    if([int64]$e.events_length -ne ([IO.FileInfo]$eventsPath).Length -or [string]$e.event_tail_id -cne [string]$tail.event_id){throw 'FreezeCandidate stale ledger length or tail.'}
    if([string]$candidate.source_composition.path -cne [string]$e.source_composition_path -or [string]$candidate.source_composition.sha256 -cne [string]$e.source_composition_sha256){throw 'Frozen source-composition closure must exactly restate its CAS-bound source composition.'}
    if([int]$candidate.feature_lock.revision -ne [int]$featureLock.revision -or [string]$candidate.feature_lock.sha256 -cne [string]$e.feature_lock_sha256){throw 'Frozen feature-lock identity must exactly restate its CAS-bound feature lock.'}
    Assert-MorphospaceFrozenCandidateScope $candidate $unit
    Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $unit
    if($ExpectedCandidateFreezeSha256 -and $ExpectedCandidateFreezeSha256 -cne $inputHash){throw 'Expected candidate-freeze hash does not match input.'};if($Execute -and -not $ExpectedCandidateFreezeSha256){throw 'Executed FreezeCandidate requires its dry-run SHA-256.'}
    $outFull=Resolve-MorphospaceWorkspacePath $workspace $outRelative;if([IO.Path]::GetFullPath($OutPath) -cne $outFull){throw "Candidate freeze output must be '$outRelative'."}
    if(-not $Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};$eventId="$([string]$candidate.freeze_id)-recorded";$targetUnit=($unit|ConvertTo-Json -Depth 64|ConvertFrom-Json);$targetUnit|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue ([ordered]@{freeze_id=$candidate.freeze_id;receipt_path=$outRelative;receipt_sha256=$inputHash});$targetState=($state|ConvertTo-Json -Depth 64|ConvertFrom-Json);$targetState.last_event_id=$eventId;$event=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$tail.sequence+1;timestamp=$Timestamp;project_id=$project.project_id;unit_id=$UnitId;event_type='state-transition';summary='Froze the exact candidate closure before validation.';receipts=@($outRelative)}
    if($Execute){Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $unitPath -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event ([pscustomobject]$event) -ExpectedStateSha256 $e.state_sha256 -ExpectedUnitSha256 $e.unit_sha256 -ExpectedEventTailId $e.event_tail_id -ExpectedEventsSha256 $e.events_sha256 -ExpectedEventsLength $e.events_length -AdditionalProjections @([pscustomobject]@{path='feature.lock.json';expected_sha256=$e.feature_lock_sha256;document=$featureLock},[pscustomobject]@{path='project.spec.json';expected_sha256=$e.project_sha256;document=$project}) -Artifacts @([pscustomobject]@{source_path=$input;path=$outRelative;sha256=$inputHash})|Out-Null}
    return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$project.project_id;unit_id=$UnitId;action='FreezeCandidate';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='candidate-frozen';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$outRelative;sha256=$inputHash};event_id=$(if($Execute){$eventId}else{$null})}
}
Export-ModuleMember -Function Invoke-MorphospaceFreezeCandidate,Test-MorphospaceFrozenCandidate,Get-MorphospaceFrozenValidationContinuation
