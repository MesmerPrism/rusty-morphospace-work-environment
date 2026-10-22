Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1')
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
        if(@($r.paths).Count-eq0){
            $validationOnly=$Unit.PSObject.Properties.Name-contains'work_mode'-and[string]$Unit.work_mode-ceq'validation-only'
            if(-not$validationOnly-or@($allowed.allowed_paths).Count-ne0-or[string]$Candidate.cleanliness_policy-cne'clean-only'){throw 'Empty frozen path rows require an explicit validation-only unit, empty admitted write scope and clean-only observation.'}
        }
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
function Test-MorphospaceOwnPlanningCandidateHistory {
    param([string]$Workspace,[object]$RepositoryEntry,[object]$Bound,[object]$Composition,[object]$Unit,[object]$FrozenTransition)
    # Get-MorphospaceCandidateSourceComposition has already authenticated the
    # exact preparation/effective continuation. A generic lock is insufficient.
    if([string]$RepositoryEntry.role-cne'planning'-or[string]$Composition.schema-cnotin@(
        'rusty.morphospace.workflow.development_envelope_source_composition.v1',
        'rusty.morphospace.workflow.development_envelope_source_composition.v2',
        'rusty.morphospace.workflow.development_envelope_source_composition.v3',
        'rusty.morphospace.workflow.active_development_envelope_source_composition.v1')){return $false}
    $pathComparison=if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $repository=[IO.Path]::GetFullPath([string]$RepositoryEntry.path).TrimEnd('\','/')
    $workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $gitRoot=(@(Invoke-MorphospaceCandidateGit $repository @('rev-parse','--show-toplevel') 'own-planning Git-root observation')[0]).Trim()
    if(-not([IO.Path]::GetFullPath($gitRoot).TrimEnd('\','/').Equals($repository,$pathComparison))){return $false}
    $prefix=$repository+[IO.Path]::DirectorySeparatorChar
    # This bounded route is for a nested control workspace, never a blanket
    # role=planning exemption for an entire repository or a sibling workspace.
    if(-not$workspaceFull.StartsWith($prefix,$pathComparison)){return $false}
    $workspaceGitRoot=(@(Invoke-MorphospaceCandidateGit $workspaceFull @('rev-parse','--show-toplevel') 'own-planning workspace Git-root observation')[0]).Trim()
    if(-not([IO.Path]::GetFullPath($workspaceGitRoot).TrimEnd('\','/').Equals($repository,$pathComparison))){return $false}
    $controlPrefix=$workspaceFull.Substring($prefix.Length).Replace('\','/').TrimEnd('/')+'/'
    $head=(@(Invoke-MorphospaceCandidateGit $repository @('rev-parse','HEAD') 'own-planning live commit observation')[0]).Trim().ToLowerInvariant()
    [void](Invoke-MorphospaceCandidateGit $repository @('merge-base','--is-ancestor',[string]$Bound.commit,$head) 'own-planning historical ancestry observation')
    # Inspect each intervening commit, not merely the endpoint diff: a source
    # or docs change followed by a revert must not gain this control-only route.
    $changed=@(Invoke-MorphospaceCandidateGit $repository @('-c','core.quotepath=false','log','--format=','--name-only','--no-renames','--full-history','-m',"$([string]$Bound.commit)..$head",'--') 'own-planning lifecycle history observation')
    foreach($path in @($changed|Where-Object{$_}|Sort-Object -Unique)){
        if(-not([string]$path).StartsWith($controlPrefix,[StringComparison]::Ordinal)){throw "Frozen candidate own-planning history changed '$path' outside its exact control workspace."}
    }
    $dirty=@(Invoke-MorphospaceCandidateGit $repository @('status','--porcelain=v1','--untracked-files=all') 'own-planning cleanliness observation')
    if($dirty.Count-ne0-and-not(Test-MorphospaceSelfHostedPlanningFreezeDirt -Workspace $Workspace -Unit $Unit -RepositoryEntry $RepositoryEntry -FrozenTransition $FrozenTransition)){throw 'Frozen candidate own-planning repository is dirty outside its authenticated freeze transition.'}
    return $true
}
function Assert-MorphospaceCandidateRepositoryClosure {
    param([string]$Workspace,[object]$Candidate,[object]$Unit,[object]$FrozenTransition=$null,[object]$AuthenticatedComposition=$null)
    $map=Get-MorphospaceCandidateRepositoryMap $Workspace ([string]$Candidate.expected.repository_map_path)
    $composition=if($null-ne$AuthenticatedComposition){$AuthenticatedComposition}else{Get-MorphospaceCandidateSourceComposition $Workspace ([string]$Candidate.expected.source_composition_path) ([string]$Candidate.project_id) ([string]$Candidate.unit_id)}
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
            if(Test-MorphospaceOwnPlanningCandidateHistory -Workspace $workspace -RepositoryEntry $entry -Bound $bound -Composition $composition -Unit $Unit -FrozenTransition $FrozenTransition){continue}
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
        if(@($changedById[$id].paths).Count-eq0-and([string]$final.commit-cne[string]$bound.commit-or[string]$final.tree-cne[string]$bound.tree)){throw "Frozen read-only observation '$id' must retain its exact locked commit and tree."}
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
function Get-MorphospaceFrozenCandidateTransition {
    param([string]$Workspace,[object]$Candidate,[object]$LiveState,[object]$LiveUnit,[string]$ReceiptRelative)
    $transactionId="$([string]$Candidate.freeze_id)-recorded-transition";$ledger=Get-Module MorphospaceTransitionLedger -All | Select-Object -First 1
    if($null-eq$ledger){throw 'Frozen candidate transition-ledger validator is unavailable.'}
    $binding=& $ledger {
        param($Root,$Id)
        $intentRelative=Get-MorphospaceLedgerPath $Root $Id intent;$completionRelative=Get-MorphospaceLedgerPath $Root $Id completion
        $intentAbsolute=Resolve-MorphospaceWorkspacePath $Root $intentRelative -RequireLeaf;$completionAbsolute=Resolve-MorphospaceWorkspacePath $Root $completionRelative -RequireLeaf
        $intent=Read-MorphospaceLedgerJson $intentAbsolute;Assert-MorphospaceLedgerIntent $intent $Id
        Assert-MorphospaceLedgerCommittedCompletion $Root $Id $intentRelative $intentAbsolute $intent $completionAbsolute
        [pscustomobject]@{intent=$intent;completion=(Read-MorphospaceLedgerJson $completionAbsolute);intent_path=$intentRelative;completion_path=$completionRelative}
    } $Workspace $transactionId
    $intent=$binding.intent;$completion=$binding.completion;$eventId="$([string]$Candidate.freeze_id)-recorded"
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v3'-or[string]$intent.transaction_id-cne$transactionId-or[string]$intent.event.event_id-cne$eventId-or[string]$intent.event.project_id-cne[string]$Candidate.project_id-or[string]$intent.event.unit_id-cne[string]$Candidate.unit_id-or@($intent.event.receipts).Count-ne1-or[string]@($intent.event.receipts)[0]-cne$ReceiptRelative){throw 'Frozen candidate transition identity or receipt binding is not exact.'}
    if([string]$intent.pre.state.sha256-cne[string]$Candidate.expected.state_sha256-or[string]$intent.pre.unit.sha256-cne[string]$Candidate.expected.unit_sha256-or[string]$intent.expected.events_sha256-cne[string]$Candidate.expected.events_sha256-or[int64]$intent.expected.events_length-ne[int64]$Candidate.expected.events_length-or[string]$intent.expected.event_tail_id-cne[string]$Candidate.expected.event_tail_id){throw 'Frozen candidate transition pre-state or ledger binding differs from the receipt.'}
    if([string]$intent.target.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $LiveState)-or[string]$intent.target.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $LiveUnit)){throw 'Frozen candidate transition target state or unit differs from live bytes.'}
    if(@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].path-cne$ReceiptRelative-or[string]$intent.artifacts[0].sha256-cne(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $ReceiptRelative -RequireLeaf))){throw 'Frozen candidate transition artifact binding differs from the receipt.'}
    if([string]$completion.transaction_id-cne$transactionId-or[string]$completion.event_id-cne$eventId-or[string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or[string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256){throw 'Frozen candidate transition completion differs from its exact intent.'}
    return $binding
}
function Assert-CandidateRevisionEqual {
    param([object]$Expected,[object]$Actual,[string]$Context)
    if((Get-MorphospaceCanonicalJsonSha256 $Expected)-cne(Get-MorphospaceCanonicalJsonSha256 $Actual)){throw "Candidate revision $Context is detached."}
}
function Get-CandidateRevisionTransition {
    param([string]$Workspace,[string]$EventId,[string]$UnitId)
    # Recovery may already have installed B's projections while Return remains
    # the physical event tail. Authenticate historical evidence independently;
    # the revision transform and ledger CAS authenticate the live endpoint.
    $retirementOwner=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -PassThru
    $proof=&$retirementOwner {param($root,$id) Get-ActiveRetirementPlanningTransition $root $id -HistoricalProjection} $Workspace "$EventId-transition"
    if([string]$proof.intent.state.path-cne'workspace.state.json'-or[string]$proof.intent.unit.path-cne"iteration-units/$UnitId.json"-or[string]$proof.intent.events.path-cne'iteration-events.jsonl'){throw 'Candidate revision predecessor projection paths are detached.'}
    return $proof
}
function Assert-MorphospaceCandidateRevisionPredecessor {
    param([string]$Workspace,[object]$Candidate,[object]$BeforeUnit,[object]$BeforeState,[int]$Depth=0)
    if($Depth-ge32){throw 'Candidate revision predecessor chain exceeds the supported depth.'}
    $owner=Split-Path $PSScriptRoot -Parent
    if(-not(Test-Json -Json ($Candidate|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $owner 'schemas/candidate-freeze-v3.schema.json'))){throw 'Candidate revision schema is invalid.'}
    $id=[string]$Candidate.unit_id;$predecessor=$Candidate.predecessor
    if([string]$BeforeUnit.unit_id-cne$id-or[string]$BeforeUnit.project_id-cne[string]$Candidate.project_id-or[string]$BeforeUnit.status-cne'active'-or[string]$BeforeState.current_unit-cne$id-or$null-ne$BeforeState.next_ready_unit-or@($BeforeState.blockers).Count-ne0-or($BeforeUnit.PSObject.Properties.Name-contains'work_mode'-and[string]$BeforeUnit.work_mode-cne'feature')){throw 'Candidate revision requires the same blocker-free active feature owner.'}
    Assert-CandidateRevisionEqual $BeforeUnit.candidate_freeze $predecessor.freeze 'predecessor marker'
    if([string]$Candidate.freeze_id-ceq[string]$predecessor.freeze.freeze_id-or[string]$BeforeState.last_event_id-cne[string]$predecessor.return_event_id){throw 'Candidate revision requires a fresh identity immediately after ReturnToActive.'}
    $oldPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$predecessor.freeze.receipt_path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $oldPath)-cne[string]$predecessor.freeze.receipt_sha256){throw 'Candidate revision predecessor freeze bytes drifted.'}
    $old=Read-MorphospaceProtocolJson $oldPath
    if([string]$old.schema-cnotin@('rusty.morphospace.workflow.candidate_freeze.v1','rusty.morphospace.workflow.candidate_freeze.v3')-or[string]$old.freeze_id-cne[string]$predecessor.freeze.freeze_id-or[string]$old.unit_id-cne$id-or[string]$old.project_id-cne[string]$Candidate.project_id){throw 'Candidate revision predecessor identity is detached.'}
    $oldSchema=if([string]$old.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v1'){'candidate-freeze-v1.schema.json'}else{'candidate-freeze-v3.schema.json'}
    if(-not(Test-Json -Json ($old|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $owner "schemas/$oldSchema"))){throw 'Candidate revision predecessor schema is invalid.'}
    $frozen=Get-CandidateRevisionTransition $Workspace "$([string]$old.freeze_id)-recorded" $id
    [void](Get-MorphospaceFrozenCandidateTransition $Workspace $old $frozen.intent.target.state.document $frozen.intent.target.unit.document ([string]$predecessor.freeze.receipt_path))
    $originalUnit=$frozen.intent.target.unit.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
    if([string]$old.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v1'){$originalUnit.PSObject.Properties.Remove('candidate_freeze')}else{$originalUnit.candidate_freeze=$old.predecessor.freeze}
    if((Get-MorphospaceCanonicalJsonSha256 $originalUnit)-cne[string]$old.expected.unit_sha256){throw 'Candidate revision original freeze changed its admitted unit authority.'}
    if([string]$old.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3'){
        $oldReturn=Get-CandidateRevisionTransition $Workspace ([string]$old.predecessor.return_event_id) $id
        Assert-MorphospaceCandidateRevisionPredecessor $Workspace $old $oldReturn.intent.target.unit.document $oldReturn.intent.target.state.document ($Depth+1)
        $oldState=$oldReturn.intent.target.state.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
        $oldState.last_event_id="$($old.freeze_id)-recorded";$oldState.validation_checkpoint=$null
        if($oldState.PSObject.Properties.Name-contains'normal_validation_selection'){$oldState.normal_validation_selection=$null}
        Assert-CandidateRevisionEqual $oldState $frozen.intent.target.state.document 'predecessor revision target state'
    }
    $returned=Get-CandidateRevisionTransition $Workspace ([string]$predecessor.return_event_id) $id
    $begin=Get-CandidateRevisionTransition $Workspace ([string]$returned.intent.expected.event_tail_id) $id
    $returnEvent=$returned.intent.event;$beginEvent=$begin.intent.event
    if([string]$begin.intent.expected.event_tail_id-cne[string]$frozen.intent.event.event_id-or[int]$beginEvent.sequence-ne([int]$frozen.intent.event.sequence+1)-or[int]$returnEvent.sequence-ne([int]$beginEvent.sequence+1)-or[string]$beginEvent.event_id-cnotmatch('^'+[regex]::Escape($id)+'-validating-[0-9]{4,}$')-or[string]$beginEvent.summary-cne'Entered validation with a deterministic command, instruction, graph, and device-impact plan.'-or@($beginEvent.receipts).Count-ne0-or@($begin.intent.artifacts).Count-ne0){throw 'Candidate revision requires the exact Freeze, BeginValidation, ReturnToActive chain.'}
    foreach($pair in @(@($frozen,$begin),@($begin,$returned))){if([string]$pair[1].intent.pre.state.sha256-cne[string]$pair[0].intent.target.state.sha256-or[string]$pair[1].intent.pre.unit.sha256-cne[string]$pair[0].intent.target.unit.sha256){throw 'Candidate revision lifecycle predecessor chain is detached.'}}
    $validating=($frozen.intent.target.unit.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String);$validating.status='validating'
    Assert-CandidateRevisionEqual $validating $begin.intent.target.unit.document 'BeginValidation unit'
    $validating.status='active';Assert-CandidateRevisionEqual $validating $BeforeUnit 'retained unit authority'
    Assert-CandidateRevisionEqual $BeforeUnit $returned.intent.target.unit.document 'ReturnToActive unit'
    Assert-CandidateRevisionEqual $BeforeState $returned.intent.target.state.document 'ReturnToActive state'
    $checkpoint=$BeforeState.validation_checkpoint;$result=[string]$checkpoint.result
    if($result-cnotin@('fail','blocked','partial')-or[string]$returnEvent.event_id-cnotmatch('^'+[regex]::Escape($id)+'-validation-'+[regex]::Escape($result)+'-return-[0-9]{4,}$')-or[string]$returnEvent.event_type-cne'validation'-or[string]$returnEvent.summary-cne'Retained a non-passing validation attempt and returned the same feature unit to active for an in-scope correction.'-or@($returnEvent.receipts).Count-ne2-or[string]$returnEvent.receipts[0]-cne[string]$checkpoint.receipt-or[string]$returnEvent.receipts[1]-cne[string]$predecessor.validation_receipt.path){throw 'Candidate revision lacks the exact retained non-passing ReturnToActive attempt.'}
    $artifacts=@($returned.intent.artifacts)
    if($artifacts.Count-ne1-or[string]$artifacts[0].path-cne[string]$predecessor.validation_receipt.path-or[string]$artifacts[0].sha256-cne[string]$predecessor.validation_receipt.sha256){throw 'Candidate revision failed receipt is not owned by ReturnToActive.'}
    foreach($relative in @([string]$checkpoint.receipt,[string]$predecessor.validation_receipt.path)){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf))-cne[string]$predecessor.validation_receipt.sha256){throw 'Candidate revision failed receipt bytes drifted.'}}
    $receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$predecessor.validation_receipt.path) -RequireLeaf)
    if([string]$receipt.schema-cne'rusty.morphospace.workflow.validation_receipt.v1'-or[string]$receipt.unit_id-cne$id-or[string]$receipt.project_id-cne[string]$Candidate.project_id-or[string]$receipt.result-cne$result-or[string]$receipt.tier-cne[string]$checkpoint.tier){throw 'Candidate revision failed receipt identity is detached.'}
    if(-not(Test-Json -Json ($receipt|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $owner 'schemas/validation-receipt.schema.json'))){throw 'Candidate revision failed receipt schema is invalid.'}
    $artifactIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $receiptDirectory=Split-Path (Resolve-MorphospaceWorkspacePath $Workspace ([string]$checkpoint.receipt) -RequireLeaf) -Parent
    foreach($artifact in @($receipt.artifacts)){
        $artifactPath=if([IO.Path]::IsPathFullyQualified([string]$artifact.path)){[string]$artifact.path}else{Join-Path $receiptDirectory ([string]$artifact.path)}
        if(-not$artifactIds.Add([string]$artifact.artifact_id)-or(Get-MorphospaceFileSha256 $artifactPath)-cne([string]$artifact.sha256).ToLowerInvariant()){throw 'Candidate revision failed validation evidence bytes drifted.'}
    }
    foreach($evidence in @($receipt.criteria)+@($receipt.gates)+@(if($null-ne$receipt.device_validation){$receipt.device_validation})){foreach($reference in @($evidence.evidence_refs)){if(-not$artifactIds.Contains([string]$reference)){throw 'Candidate revision failed receipt references unknown evidence.'}}}
    foreach($repository in @($old.final_repositories)){
        $revisions=@($receipt.repository_revisions|Where-Object{[string]$_.repo_id-ceq[string]$repository.repo_id})
        if($revisions.Count-ne1-or[string]$revisions[0].head_revision-cne[string]$repository.commit){throw 'Candidate revision failed attempt source differs from its predecessor freeze.'}
    }
    foreach($name in @('project_sha256','feature_lock_sha256','source_composition_path','source_composition_sha256','repository_map_path','repository_map_sha256')){if([string]$Candidate.expected.$name-cne[string]$old.expected.$name){throw "Candidate revision changes frozen authority input '$name'."}}
    if([string]$Candidate.expected.state_sha256-cne[string]$returned.intent.target.state.sha256-or[string]$Candidate.expected.unit_sha256-cne[string]$returned.intent.target.unit.sha256-or[string]$Candidate.expected.event_tail_id-cne[string]$returnEvent.event_id){throw 'Candidate revision CAS is detached from ReturnToActive.'}
    # Approval and validation identities are not carried to the changed source.
    return $returned
}
function Assert-MorphospaceCandidateRevisionRecoveryBindings {
    param([string]$WorkspaceRoot,[object]$Intent,[switch]$Historical)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    if(@($Intent.artifacts).Count-ne1){throw 'Candidate revision requires one transaction-owned freeze artifact.'}
    $artifact=$Intent.artifacts[0];$bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64)
    if((Get-MorphospaceSha256Bytes $bytes)-cne[string]$artifact.sha256){throw 'Candidate revision artifact bytes drifted.'}
    $candidate=ConvertFrom-MorphospaceProtocolJsonBytes $bytes
    if([string]$candidate.source_composition.path-cne[string]$candidate.expected.source_composition_path-or[string]$candidate.source_composition.sha256-cne[string]$candidate.expected.source_composition_sha256-or[string]$candidate.feature_lock.sha256-cne[string]$candidate.expected.feature_lock_sha256){throw 'Candidate revision source or feature closure detaches from its CAS.'}
    $returned=Get-CandidateRevisionTransition $workspace ([string]$candidate.predecessor.return_event_id) ([string]$candidate.unit_id)
    [void](Assert-MorphospaceCandidateRevisionPredecessor $workspace $candidate $returned.intent.target.unit.document $returned.intent.target.state.document)
    $targetUnit=$returned.intent.target.unit.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
    $targetUnit.candidate_freeze=[pscustomobject]@{freeze_id=$candidate.freeze_id;receipt_path="receipts/$($candidate.freeze_id).json";receipt_sha256=$artifact.sha256}
    $targetState=$returned.intent.target.state.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
    $eventId="$($candidate.freeze_id)-recorded";$targetState.last_event_id=$eventId
    $targetState.validation_checkpoint=$null
    if($targetState.PSObject.Properties.Name-contains'normal_validation_selection'){$targetState.normal_validation_selection=$null}
    Assert-CandidateRevisionEqual $targetUnit $Intent.target.unit.document 'revision target unit'
    Assert-CandidateRevisionEqual $targetState $Intent.target.state.document 'revision target state'
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v3'-or[string]$Intent.transaction_id-cne"$eventId-transition"-or[string]$Intent.event.event_id-cne$eventId-or[string]$Intent.event.summary-cne'Froze a linked in-scope candidate correction after retaining the non-passing validation attempt.'-or[string]$Intent.event.unit_id-cne[string]$candidate.unit_id-or[string]$Intent.event.project_id-cne[string]$candidate.project_id-or[string]$Intent.event.event_type-cne'state-transition'-or[int]$Intent.event.sequence-ne([int]$returned.intent.event.sequence+1)-or@($Intent.event.receipts).Count-ne1-or[string]$Intent.event.receipts[0]-cne[string]$artifact.path-or[string]$artifact.path-cne"receipts/$($candidate.freeze_id).json"-or[string]$Intent.pre.state.sha256-cne[string]$candidate.expected.state_sha256-or[string]$Intent.pre.unit.sha256-cne[string]$candidate.expected.unit_sha256-or[string]$Intent.expected.event_tail_id-cne[string]$candidate.expected.event_tail_id-or[string]$Intent.expected.events_sha256-cne[string]$candidate.expected.events_sha256-or[int64]$Intent.expected.events_length-ne[int64]$candidate.expected.events_length){throw 'Candidate revision transition is detached.'}
    if(@($Intent.additional_projections).Count-ne2){throw 'Candidate revision authority fences are incomplete.'}
    $fences=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($projection in @($Intent.additional_projections)){$name=switch -CaseSensitive ([string]$projection.path){'project.spec.json'{'project_sha256'};'feature.lock.json'{'feature_lock_sha256'};default{throw 'Candidate revision contains an unknown authority fence.'}};if(-not$fences.Add([string]$projection.path)-or[string]$projection.pre_sha256-cne[string]$candidate.expected.$name-or[string]$projection.target_sha256-cne[string]$candidate.expected.$name-or(Get-MorphospaceCanonicalJsonSha256 $projection.document)-cne[string]$candidate.expected.$name){throw 'Candidate revision authority fence changes its projection.'}}
    Assert-MorphospaceFrozenCandidateScope $candidate $targetUnit
    if($Historical){return}
    foreach($pair in @(@('project.spec.json','project_sha256'),@('feature.lock.json','feature_lock_sha256'))){if((Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $pair[0] -RequireLeaf)))-cne[string]$candidate.expected.($pair[1])){throw 'Candidate revision live authority fence drifted.'}}
    $featureLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf)
    if([int]$candidate.feature_lock.revision-ne[int]$featureLock.revision){throw 'Candidate revision feature-lock revision drifted.'}
    foreach($pair in @(@('source_composition_path','source_composition_sha256'),@('repository_map_path','repository_map_sha256'))){if((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.expected.($pair[0])) -RequireLeaf))-cne[string]$candidate.expected.($pair[1])){throw 'Candidate revision live source binding drifted.'}}
    # The original freeze and contiguous owner transactions authenticate this
    # unchanged lock. Recovery may have installed the new projection already.
    $composition=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$candidate.source_composition.path) -RequireLeaf)
    $frozenTransition=[pscustomobject]@{intent=$Intent;intent_path="receipts/transactions/$($Intent.transaction_id).intent.json";completion_path="receipts/transactions/$($Intent.transaction_id).completion.json"}
    Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $targetUnit $frozenTransition $composition
}
function Get-MorphospaceFrozenCandidateToolingProjection {
    param([string]$Workspace,[object]$Candidate,[object]$LiveState,[object]$LiveUnit,[string]$ReceiptRelative)
    # A typed compatible upgrade changes the live pointer, never the original
    # frozen unit/hash. Reconstruct that original view only through the complete
    # committed continuation and its authenticated immediate Freeze/Begin slot.
    $frozen=Get-CandidateRevisionTransition $Workspace "$([string]$Candidate.freeze_id)-recorded" ([string]$Candidate.unit_id)
    $originalUnit=$frozen.intent.target.unit.document;$originalState=$frozen.intent.target.state.document
    [void](Get-MorphospaceFrozenCandidateTransition $Workspace $Candidate $originalState $originalUnit $ReceiptRelative)
    if($LiveUnit.PSObject.Properties.Name-cnotcontains'tooling_context'-or$originalUnit.PSObject.Properties.Name-cnotcontains'tooling_context'-or[string]$LiveUnit.status-cne'validating'-or[string]$LiveState.current_unit-cne[string]$Candidate.unit_id){throw 'Frozen tooling projection requires the same current validating owner.'}
    Assert-CandidateRevisionEqual $LiveUnit.candidate_freeze $originalUnit.candidate_freeze 'tooling upgrade frozen marker'
    $map=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Candidate.expected.repository_map_path) -RequireLeaf
    $effective=Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $Workspace -UnitId ([string]$Candidate.unit_id) -RepositoryMapPath $map
    Assert-CandidateRevisionEqual $LiveUnit $effective.effective.unit 'tooling upgrade live unit'
    Assert-CandidateRevisionEqual $LiveState $effective.effective.state 'tooling upgrade live state'
    $upgrades=@($effective.tooling_upgrades|Where-Object{
        [int]$_.intent.event.sequence-gt[int]$frozen.intent.event.sequence-and
        (Get-MorphospaceCanonicalJsonSha256 $_.intent.target.unit.document.tooling_context)-ceq(Get-MorphospaceCanonicalJsonSha256 $LiveUnit.tooling_context)
    })
    if($upgrades.Count-ne1){throw 'Frozen tooling projection requires one authenticated upgrade to the selected live pointer.'}
    $before=$originalUnit|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String;$before.status='validating'
    if((Get-MorphospaceCanonicalJsonSha256 $before)-cne[string]$upgrades[0].intent.pre.unit.sha256){throw 'Frozen tooling upgrade preimage differs from the original frozen unit.'}
    $after=$before|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String;$after.tooling_context=$LiveUnit.tooling_context
    Assert-CandidateRevisionEqual $after $upgrades[0].intent.target.unit.document 'tooling upgrade pointer-only target'
    [pscustomobject]@{unit=$originalUnit;state=$originalState;event_tail=$effective.effective.event_tail}
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
    $schema=if([string]$candidate.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3'){'candidate-freeze-v3.schema.json'}else{'candidate-freeze-v1.schema.json'}
    if([string]$candidate.schema-cnotin@('rusty.morphospace.workflow.candidate_freeze.v1','rusty.morphospace.workflow.candidate_freeze.v3')-or-not(Test-Json -Json (Get-Content -Raw $path) -SchemaFile (Join-Path $repoRoot "schemas/$schema"))){throw 'Frozen candidate receipt is malformed.'}
    if([string]$candidate.freeze_id -cne [string]$freeze.freeze_id -or [string]$candidate.unit_id -cne [string]$Unit.unit_id){throw 'Frozen candidate receipt identity does not match its unit marker.'}
    $unitPath="iteration-units/$([string]$Unit.unit_id).json";$liveUnit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    $project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf);$featureLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf)
    $toolingProjection=$null
    if($liveUnit.PSObject.Properties.Name-ccontains'tooling_context'){
        $original=Get-CandidateRevisionTransition $workspace "$([string]$candidate.freeze_id)-recorded" ([string]$candidate.unit_id)
        if((Get-MorphospaceCanonicalJsonSha256 $liveUnit.tooling_context)-cne(Get-MorphospaceCanonicalJsonSha256 $original.intent.target.unit.document.tooling_context)){
            $toolingProjection=Get-MorphospaceFrozenCandidateToolingProjection $workspace $candidate $state $liveUnit ([string]$freeze.receipt_path)
            $liveUnit=$toolingProjection.unit|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
            $state=$toolingProjection.state|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
        }
    }
    if([string]$candidate.project_id -cne [string]$project.project_id -or [string]$candidate.unit_id -cne [string]$liveUnit.unit_id -or [string]$state.current_unit -cne [string]$liveUnit.unit_id -or [string]$state.last_event_id -cne "$([string]$candidate.freeze_id)-recorded"){throw 'Frozen candidate identity no longer matches the live active authority.'}
    $marker=$liveUnit.candidate_freeze;if([string]$candidate.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3'){$liveUnit.candidate_freeze=$candidate.predecessor.freeze}else{$liveUnit.PSObject.Properties.Remove('candidate_freeze')}
    foreach($check in @(@{e=$candidate.expected.project_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $project);n='project'},@{e=$candidate.expected.unit_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $liveUnit);n='unit'},@{e=$candidate.expected.feature_lock_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $featureLock);n='feature lock'},@{e=$candidate.expected.source_composition_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $candidate.expected.source_composition_path -RequireLeaf));n='source composition'},@{e=$candidate.expected.repository_map_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $candidate.expected.repository_map_path -RequireLeaf));n='repository map'})){if([string]$check.e -cne [string]$check.a){throw "Frozen candidate $($check.n) drifted after freeze."}}
    if([string]$candidate.source_composition.path -cne [string]$candidate.expected.source_composition_path -or [string]$candidate.source_composition.sha256 -cne [string]$candidate.expected.source_composition_sha256){throw 'Frozen source-composition closure no longer matches its receipt CAS binding.'}
    if([int]$candidate.feature_lock.revision -ne [int]$featureLock.revision -or [string]$candidate.feature_lock.sha256 -cne [string]$candidate.expected.feature_lock_sha256){throw 'Frozen feature-lock closure no longer matches its receipt CAS binding.'}
    Assert-MorphospaceFrozenCandidateScope $candidate $liveUnit
    $liveUnit|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue $marker -Force
    $frozenTransition=Get-MorphospaceFrozenCandidateTransition $workspace $candidate $state $liveUnit ([string]$freeze.receipt_path)
    if([string]$candidate.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3'){Assert-MorphospaceCandidateRevisionRecoveryBindings $workspace $frozenTransition.intent}
    Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $liveUnit $frozenTransition
    $eventLines=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_})
    $tail=$eventLines[-1]|ConvertFrom-Json
    $expectedTail=if($null-ne$toolingProjection){[string]$toolingProjection.event_tail.event_id}else{"$([string]$candidate.freeze_id)-recorded"}
    if([string]$tail.event_id-cne$expectedTail){throw 'Frozen candidate transition is no longer the exact ledger tail.'}
    return $true
}
function Invoke-MorphospaceFreezeCandidate {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$UnitId,[string]$CandidateFreeze,[string]$ExpectedCandidateFreezeSha256='',[string]$Timestamp='',[string]$OutPath,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none',[switch]$Execute)
    $repoRoot=Split-Path $PSScriptRoot -Parent;$workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $CandidateFreeze).Path
    $inputDocument=Read-MorphospaceProtocolJson $input;$isRevision=[string]$inputDocument.schema-ceq'rusty.morphospace.workflow.candidate_freeze.v3';$schema=if($isRevision){'candidate-freeze-v3.schema.json'}else{'candidate-freeze-v1.schema.json'}
    if(-not(Test-Json -Json (Get-Content -Raw $input) -SchemaFile (Join-Path $repoRoot "schemas/$schema"))){throw 'Candidate freeze does not satisfy its schema.'}
    $candidate=Read-MorphospaceProtocolJson $input;$project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf);$unitPath="iteration-units/$UnitId.json";$unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf);$featureLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf);$eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf;$events=@(Get-Content $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json});$tail=$events[-1]
    if($isRevision){
        $revisionHash=Get-MorphospaceFileSha256 $input
        $revisionRelative="receipts/$($candidate.freeze_id).json";$revisionEvent="$($candidate.freeze_id)-recorded";$revisionTransaction="$revisionEvent-transition"
        $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$revisionTransaction.intent.json"
        if([IO.File]::Exists($intentPath)){
            if($ExpectedCandidateFreezeSha256-cne$revisionHash-or[IO.Path]::GetFullPath($OutPath)-cne(Resolve-MorphospaceWorkspacePath $workspace $revisionRelative)){throw 'Candidate revision replay requires its exact request hash and output path.'}
            $intent=Read-MorphospaceProtocolJson $intentPath
            if(@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].sha256-cne$revisionHash){throw 'Candidate revision replay input differs from the durable intent.'}
            Assert-MorphospaceCandidateRevisionRecoveryBindings $workspace $intent
            $completion=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$revisionTransaction.completion.json"
            if(-not[IO.File]::Exists($completion)){
                if(-not$Execute){throw 'Interrupted candidate revision requires executed recovery.'}
                Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $revisionTransaction -Repair -FaultAfter $FaultAfter|Out-Null
            }
            [void](Get-CandidateRevisionTransition $workspace $revisionEvent $UnitId)
            return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$project.project_id;unit_id=$UnitId;action='FreezeCandidate';timestamp=[string]$intent.event.timestamp;executed=$Execute.IsPresent;transition='candidate-already-frozen';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$revisionRelative;sha256=$revisionHash};event_id=$null}
        }
    }
    if([string]$candidate.project_id -cne [string]$project.project_id -or [string]$candidate.unit_id -cne $UnitId -or [string]$unit.status -cne 'active' -or [string]$state.current_unit -cne $UnitId){throw 'FreezeCandidate requires the matching active current unit.'}
    if($unit.PSObject.Properties.Name-contains'tooling_context'){
        [void](Get-MorphospaceUnitToolingContextObservation -WorkspaceRoot $workspace -UnitId $UnitId -Action FreezeCandidate -OwnerModule $MyInvocation.MyCommand.Module)
    }
    [void](Test-MorphospaceInheritedCandidateMaterializationGate -WorkspaceRoot $workspace -Unit $unit)
    if(-not($unit.PSObject.Properties.Name -contains 'agent_scope_assessment')){throw 'FreezeCandidate is reserved for development-envelope admitted units.'}
    $inputHash=Get-MorphospaceFileSha256 $input;$outRelative="receipts/$([string]$candidate.freeze_id).json"
    if($unit.PSObject.Properties.Name -contains 'candidate_freeze'){if([string]$unit.candidate_freeze.receipt_sha256 -ceq $inputHash -and [string]$unit.candidate_freeze.freeze_id -ceq [string]$candidate.freeze_id){return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$project.project_id;unit_id=$UnitId;action='FreezeCandidate';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='candidate-already-frozen';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$outRelative;sha256=$inputHash};event_id=$null}};if(-not$isRevision){throw 'Conflicting candidate freeze is rejected.'}}
    if($isRevision){[void](Assert-MorphospaceCandidateRevisionPredecessor $workspace $candidate $unit $state)}
    $e=$candidate.expected;foreach($check in @(@{e=$e.project_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $project);n='project'},@{e=$e.state_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $state);n='state'},@{e=$e.unit_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $unit);n='unit'},@{e=$e.feature_lock_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $featureLock);n='feature lock'},@{e=$e.source_composition_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $e.source_composition_path -RequireLeaf));n='source composition'},@{e=$e.repository_map_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $e.repository_map_path -RequireLeaf));n='repository map'},@{e=$e.events_sha256;a=(Get-MorphospaceFileSha256 $eventsPath);n='ledger'})){if([string]$check.e -cne [string]$check.a){throw "FreezeCandidate stale $($check.n) preimage (expected $($check.e), actual $($check.a), state-tail $($state.last_event_id))."}}
    if([int64]$e.events_length -ne ([IO.FileInfo]$eventsPath).Length -or [string]$e.event_tail_id -cne [string]$tail.event_id){throw 'FreezeCandidate stale ledger length or tail.'}
    if([string]$candidate.source_composition.path -cne [string]$e.source_composition_path -or [string]$candidate.source_composition.sha256 -cne [string]$e.source_composition_sha256){throw 'Frozen source-composition closure must exactly restate its CAS-bound source composition.'}
    if([int]$candidate.feature_lock.revision -ne [int]$featureLock.revision -or [string]$candidate.feature_lock.sha256 -cne [string]$e.feature_lock_sha256){throw 'Frozen feature-lock identity must exactly restate its CAS-bound feature lock.'}
    Assert-MorphospaceFrozenCandidateScope $candidate $unit
    Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $unit
    if($ExpectedCandidateFreezeSha256 -and $ExpectedCandidateFreezeSha256 -cne $inputHash){throw 'Expected candidate-freeze hash does not match input.'};if($Execute -and -not $ExpectedCandidateFreezeSha256){throw 'Executed FreezeCandidate requires its dry-run SHA-256.'}
    $outFull=Resolve-MorphospaceWorkspacePath $workspace $outRelative;if([IO.Path]::GetFullPath($OutPath) -cne $outFull){throw "Candidate freeze output must be '$outRelative'."}
    if(-not $Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};$eventId="$([string]$candidate.freeze_id)-recorded";$targetUnit=($unit|ConvertTo-Json -Depth 64|ConvertFrom-Json);$targetUnit|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue ([ordered]@{freeze_id=$candidate.freeze_id;receipt_path=$outRelative;receipt_sha256=$inputHash}) -Force;$targetState=($state|ConvertTo-Json -Depth 64|ConvertFrom-Json);$targetState.last_event_id=$eventId;$event=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$tail.sequence+1;timestamp=$Timestamp;project_id=$project.project_id;unit_id=$UnitId;event_type='state-transition';summary='Froze the exact candidate closure before validation.';receipts=@($outRelative)}
    if($isRevision){$targetState.validation_checkpoint=$null;if($targetState.PSObject.Properties.Name-contains'normal_validation_selection'){$targetState.normal_validation_selection=$null};$event.summary='Froze a linked in-scope candidate correction after retaining the non-passing validation attempt.'}
    if($Execute){Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $unitPath -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event ([pscustomobject]$event) -ExpectedStateSha256 $e.state_sha256 -ExpectedUnitSha256 $e.unit_sha256 -ExpectedEventTailId $e.event_tail_id -ExpectedEventsSha256 $e.events_sha256 -ExpectedEventsLength $e.events_length -AdditionalProjections @([pscustomobject]@{path='feature.lock.json';expected_sha256=$e.feature_lock_sha256;document=$featureLock},[pscustomobject]@{path='project.spec.json';expected_sha256=$e.project_sha256;document=$project}) -Artifacts @([pscustomobject]@{source_path=$input;path=$outRelative;sha256=$inputHash}) -FaultAfter $FaultAfter|Out-Null}
    return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$project.project_id;unit_id=$UnitId;action='FreezeCandidate';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='candidate-frozen';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$outRelative;sha256=$inputHash};event_id=$(if($Execute){$eventId}else{$null})}
}
Export-ModuleMember -Function Invoke-MorphospaceFreezeCandidate,Test-MorphospaceFrozenCandidate,Assert-MorphospaceCandidateRevisionRecoveryBindings
