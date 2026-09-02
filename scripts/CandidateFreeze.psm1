Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'InheritedCandidateMaterialization.psm1') -Force

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
    if([string]$composition.schema-ceq'rusty.morphospace.workflow.development_envelope_source_composition.v1'){
        if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile (Join-Path $repoRoot 'schemas\development-envelope-source-composition-v1.schema.json'))){throw 'Frozen candidate preparation-owned source composition is malformed.'}
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
function Assert-MorphospaceCandidateRepositoryClosure {
    param([string]$Workspace,[object]$Candidate,[object]$Unit)
    $map=Get-MorphospaceCandidateRepositoryMap $Workspace ([string]$Candidate.expected.repository_map_path)
    $composition=Get-MorphospaceCandidateSourceComposition $Workspace ([string]$Candidate.expected.source_composition_path) ([string]$Candidate.project_id) ([string]$Candidate.unit_id)
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
    $compositionById=@{};foreach($row in @($composition.repositories)){
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
            if($observed.Count-ne0){throw "Frozen candidate clean-only repository '$id' is dirty."}
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
    $unitPath="iteration-units/$([string]$Unit.unit_id).json";$liveUnit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    $project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf);$featureLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf)
    if([string]$candidate.project_id -cne [string]$project.project_id -or [string]$candidate.unit_id -cne [string]$liveUnit.unit_id -or [string]$state.current_unit -cne [string]$liveUnit.unit_id -or [string]$state.last_event_id -cne "$([string]$candidate.freeze_id)-recorded"){throw 'Frozen candidate identity no longer matches the live active authority.'}
    $marker=$liveUnit.candidate_freeze;$liveUnit.PSObject.Properties.Remove('candidate_freeze')
    foreach($check in @(@{e=$candidate.expected.project_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $project);n='project'},@{e=$candidate.expected.unit_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $liveUnit);n='unit'},@{e=$candidate.expected.feature_lock_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $featureLock);n='feature lock'},@{e=$candidate.expected.source_composition_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $candidate.expected.source_composition_path -RequireLeaf));n='source composition'},@{e=$candidate.expected.repository_map_sha256;a=(Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace $candidate.expected.repository_map_path -RequireLeaf));n='repository map'})){if([string]$check.e -cne [string]$check.a){throw "Frozen candidate $($check.n) drifted after freeze."}}
    if([string]$candidate.source_composition.path -cne [string]$candidate.expected.source_composition_path -or [string]$candidate.source_composition.sha256 -cne [string]$candidate.expected.source_composition_sha256){throw 'Frozen source-composition closure no longer matches its receipt CAS binding.'}
    if([int]$candidate.feature_lock.revision -ne [int]$featureLock.revision -or [string]$candidate.feature_lock.sha256 -cne [string]$candidate.expected.feature_lock_sha256){throw 'Frozen feature-lock closure no longer matches its receipt CAS binding.'}
    Assert-MorphospaceFrozenCandidateScope $candidate $liveUnit
    Assert-MorphospaceCandidateRepositoryClosure $workspace $candidate $liveUnit
    $liveUnit|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue $marker
    [void](Get-MorphospaceFrozenCandidateTransition $workspace $candidate $state $liveUnit ([string]$freeze.receipt_path))
    $eventLines=@(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf)|Where-Object{$_})
    $tail=$eventLines[-1]|ConvertFrom-Json
    if([string]$tail.event_id-cne"$([string]$candidate.freeze_id)-recorded"){throw 'Frozen candidate transition is no longer the exact ledger tail.'}
    return $true
}
function Invoke-MorphospaceFreezeCandidate {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$UnitId,[string]$CandidateFreeze,[string]$ExpectedCandidateFreezeSha256='',[string]$Timestamp='',[string]$OutPath,[switch]$Execute)
    $repoRoot=Split-Path $PSScriptRoot -Parent;$workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $CandidateFreeze).Path
    if(-not(Test-Json -Json (Get-Content -Raw $input) -SchemaFile (Join-Path $repoRoot 'schemas\candidate-freeze-v1.schema.json'))){throw 'Candidate freeze does not satisfy its schema.'}
    $candidate=Read-MorphospaceProtocolJson $input;$project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf);$unitPath="iteration-units/$UnitId.json";$unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf);$featureLock=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf);$eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf;$events=@(Get-Content $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json});$tail=$events[-1]
    if([string]$candidate.project_id -cne [string]$project.project_id -or [string]$candidate.unit_id -cne $UnitId -or [string]$unit.status -cne 'active' -or [string]$state.current_unit -cne $UnitId){throw 'FreezeCandidate requires the matching active current unit.'}
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
Export-ModuleMember -Function Invoke-MorphospaceFreezeCandidate,Test-MorphospaceFrozenCandidate
