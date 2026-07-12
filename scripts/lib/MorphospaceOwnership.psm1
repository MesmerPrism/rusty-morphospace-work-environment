Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Microsoft.PowerShell.Core\Import-Module ([IO.Path]::Combine($PSScriptRoot,'MorphospaceProtocolCommon.psm1')) -Force
Microsoft.PowerShell.Core\Import-Module ([IO.Path]::Combine($PSScriptRoot,'MorphospaceContentObservation.psm1')) -Force
$script:ContentModule = Microsoft.PowerShell.Core\Get-Module MorphospaceContentObservation
$script:CleanRoomGuards = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)

function Get-MorphospaceOrdinalFingerprint {
    param([Parameter(Mandatory=$true)][object]$Value)
    return Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$Value})
}

function Test-MorphospaceLowerObjectId {
    param([string]$Value,[string]$Context)
    if($Value-notmatch'^(?:[0-9a-f]{40}|[0-9a-f]{64})$'){throw "$Context is not one lowercase full Git object ID."}
}

function Invoke-MorphospaceOwnershipGit {
    param([string]$GitExecutable,[string]$RepositoryPath,[string[]]$Arguments,[switch]$AllowFailure)
    return & $script:ContentModule {
        param($git,$root,$arguments,$allowFailure)
        $gitHash=Get-MorphospaceFileSha256 $git
        $safety=$null
        try{
            $safety=New-MorphospaceGitSafetyContext $git $root $gitHash
            $result=Invoke-MorphospaceBoundGitBytes -GitExecutable $git -RepositoryPath $root -Arguments $arguments -ExpectedExecutableSha256 $gitHash -SafetyContext $safety -AllowFailure:$allowFailure
            Test-MorphospaceGitSafetyContext $safety $git $root $gitHash
            return $result
        }finally{Close-MorphospaceGitSafetyContext $safety}
    } $GitExecutable $RepositoryPath $Arguments $AllowFailure
}

function ConvertFrom-MorphospaceOwnershipUtf8 {
    param([byte[]]$Bytes)
    return & $script:ContentModule {param($value) ConvertFrom-MorphospaceUtf8Bytes $value} $Bytes
}

function ConvertTo-MorphospaceSortedCanonicalPaths {
    param([object[]]$Paths)
    $list=[Collections.Generic.List[string]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($raw in $Paths){$candidate=([string]$raw).TrimEnd('/','\');if(-not$candidate){throw 'Path scope cannot be empty after a directory suffix is normalized.'};$path=ConvertTo-MorphospaceProtocolRelativePath $candidate;if(-not$seen.Add($path)){throw "Duplicate/case-fold path '$path'."};$list.Add($path)}
    $array=@($list.ToArray());[Array]::Sort($array,[StringComparer]::Ordinal);return $array
}

function Get-MorphospaceFixedRepositoryMap {
    param([string]$WorkspaceRoot,[string[]]$RequiredRepositoryIds)
    $mapPath=Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'repository-map.json' -RequireLeaf
    $document=Read-MorphospaceProtocolJson $mapPath
    Assert-MorphospaceExactPropertySet $document @('schema','repositories') @('$schema') 'fixed repository map'
    if([string]$document.schema-cne'rusty.morphospace.workflow.repository_map.v1'){throw 'Fixed repository map has the wrong schema.'}
    $map=@{};$aliases=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in @($document.repositories)){
        Assert-MorphospaceExactPropertySet $entry @('repo_id','path','role') @('aliases') 'fixed repository-map row'
        $repoId=[string]$entry.repo_id;if($repoId-notmatch'^[a-z0-9][a-z0-9-]{1,63}$'-or$map.ContainsKey($repoId)-or$aliases.ContainsKey($repoId)){throw "Duplicate/invalid repository ID '$repoId'."}
        if([string]$entry.role-notin@('source','planning')){throw "Unsupported repository role for '$repoId'."}
        $path=[IO.Path]::GetFullPath([string]$entry.path);if(-not[IO.Directory]::Exists($path)){throw "Mapped repository is missing: $repoId"};$parent=[IO.Directory]::GetParent($path);if($null-eq$parent){throw "Mapped repository cannot be a volume root: $repoId"};Assert-MorphospaceNoReparseAncestor $parent.FullName $path
        $aliasList=[Collections.Generic.List[string]]::new();foreach($rawAlias in @($entry.aliases)){$alias=[string]$rawAlias;if($alias-notmatch'^[a-z0-9][a-z0-9-]{1,63}$'-or$aliases.ContainsKey($alias)-or$map.ContainsKey($alias)){throw "Duplicate/invalid repository alias '$alias'."};$aliases[$alias]=$repoId;$aliasList.Add($alias)}
        $aliases[$repoId]=$repoId;$map[$repoId]=[pscustomobject]@{repo_id=$repoId;path=$path;role=[string]$entry.role;aliases=@($aliasList.ToArray())}
    }
    $required=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($raw in $RequiredRepositoryIds){$id=[string]$raw;if(-not$aliases.ContainsKey($id)){throw "Required repository '$id' is omitted from the fixed map."};[void]$required.Add([string]$aliases[$id])}
    if($required.Count-ne$map.Count){$extra=[Collections.Generic.List[string]]::new();foreach($id in $map.Keys){if(-not$required.Contains([string]$id)){$extra.Add([string]$id)}};throw "Fixed repository map expands authority: $($extra -join ',')."}
    $ids=@($required);[Array]::Sort($ids,[StringComparer]::Ordinal)
    return [pscustomobject]@{path=$mapPath;document=$document;sha256=(Get-MorphospaceFileSha256 $mapPath);map=$map;aliases=$aliases;canonical_ids=$ids}
}

function Test-MorphospaceInputClosure {
    param([object]$Validator,[hashtable]$RepositoryMap)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($closure in @($Validator.input_closure)){
        Assert-MorphospaceExactPropertySet $closure @('repo_id','kind','paths') @() 'validator input-closure row'
        $repoId=[string]$closure.repo_id;if(-not$RepositoryMap.ContainsKey($repoId)){throw "Validator input repository '$repoId' is not mapped."}
        if([string]$closure.kind-notin@('git-tree','non-git-tree','instructions','project-contracts')){throw 'Validator input kind is unknown.'}
        $paths=@(ConvertTo-MorphospaceSortedCanonicalPaths @($closure.paths));if($paths.Count-eq0){throw 'Validator input closure row is empty.'}
        $key="$repoId/$([string]$closure.kind)";if(-not$seen.Add($key)){throw "Validator repeats input-closure row '$key'."}
        for($i=0;$i-lt$paths.Count;$i++){for($j=$i+1;$j-lt$paths.Count;$j++){if($paths[$j].StartsWith($paths[$i]+'/',[StringComparison]::OrdinalIgnoreCase)){throw "Validator input closure overlaps '$($paths[$i])'."}}}
    }
}

function Test-MorphospaceHistoryBlobClosure {
    param([object[]]$HistoryBlobs,[hashtable]$RepositoryMap)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($blob in @($HistoryBlobs)) {
        Assert-MorphospaceExactPropertySet $blob @('repo_id','object_id','sha256') @() 'validator history blob'
        $repoId = [string]$blob.repo_id
        Test-MorphospaceLowerObjectId ([string]$blob.object_id) "Validator history blob '$repoId' object"
        if (-not $RepositoryMap.ContainsKey($repoId) -or [string]$blob.sha256 -notmatch '^[0-9a-f]{64}$' -or -not $seen.Add("$repoId/$([string]$blob.object_id)")) {
            throw "Validator history blob is malformed or duplicated: $repoId/$([string]$blob.object_id)"
        }
    }
}

function Test-MorphospaceOwnerValidatorRegistry {
    param([object]$Registry,[hashtable]$RepositoryMap)
    Assert-MorphospaceExactPropertySet $Registry @('$schema','schema','registry_id','revision','created_at','foundation_commit','previous_registry','validators') @() 'owner-validator registry'
    if([string]$Registry.schema-cne'rusty.morphospace.workflow.owner_validator_registry.v1'){throw 'Owner-validator registry has the wrong schema.'};[void](Test-MorphospaceStrictUtcTimestamp ([string]$Registry.created_at));Test-MorphospaceLowerObjectId ([string]$Registry.foundation_commit) 'Registry foundation commit'
    if([long]$Registry.revision-lt1-or@($Registry.validators).Count-eq0){throw 'Owner-validator registry revision/entries are invalid.'};if($null-ne$Registry.previous_registry){Assert-MorphospaceExactPropertySet $Registry.previous_registry @('role','path','schema','sha256') @() 'previous registry reference'}
    $validatorIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($validator in @($Registry.validators)){
        Assert-MorphospaceExactPropertySet $validator @('validator_id','owner_repo_id','owner_revision','owner_tree_oid','path','sha256','git_blob_oid','entrypoint','profiles','acceptance_ids','evidence_schema','input_closure','timeout_seconds','max_output_bytes','mutation_policy','device_policy') @('history_blobs') 'owner-validator registry entry'
        $id=[string]$validator.validator_id;if($id-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'-or-not$validatorIds.Add($id)){throw "Duplicate/invalid validator '$id'."};$owner=[string]$validator.owner_repo_id;if(-not$RepositoryMap.ContainsKey($owner)){throw "Validator owner '$owner' is not mapped."}
        Test-MorphospaceLowerObjectId ([string]$validator.owner_revision) "Validator '$id' owner revision";Test-MorphospaceLowerObjectId ([string]$validator.owner_tree_oid) "Validator '$id' owner tree";Test-MorphospaceLowerObjectId ([string]$validator.git_blob_oid) "Validator '$id' blob"
        $path=ConvertTo-MorphospaceProtocolRelativePath ([string]$validator.path);if($path-cne[string]$validator.path-or[string]$validator.sha256-notmatch'^[0-9a-f]{64}$'){throw "Validator '$id' path/hash is invalid."}
        if([string]$validator.entrypoint-cne'powershell-file'-or[string]$validator.evidence_schema-cne'rusty.morphospace.workflow.owner_validation.v1'-or[string]$validator.mutation_policy-cne'temp-output-only'-or[string]$validator.device_policy-notin@('forbidden','required')){throw "Validator '$id' policy is unsafe."};if([long]$validator.timeout_seconds-lt1-or[long]$validator.timeout_seconds-gt600-or[long]$validator.max_output_bytes-lt1024-or[long]$validator.max_output_bytes-gt268435456){throw "Validator '$id' bounds are invalid."}
        foreach($property in @('profiles','acceptance_ids')){$values=@($validator.$property);if($values.Count-eq0){throw "Validator '$id' has empty $property."};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($value in $values){if([string]$value-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'-or-not$seen.Add([string]$value)){throw "Validator '$id' repeats/invalidates $property."}}}
        Test-MorphospaceInputClosure $validator $RepositoryMap
        if ($validator.PSObject.Properties.Name -contains 'history_blobs') { Test-MorphospaceHistoryBlobClosure @($validator.history_blobs) $RepositoryMap }
    }
    return $true
}

function Test-MorphospaceTrackedValidator {
    param([object]$Validator,[object]$RepositoryEntry,[string]$GitExecutable='')
    if(-not$GitExecutable){$GitExecutable=(Get-MorphospaceBoundExecutable git).path};$root=[string]$RepositoryEntry.path;$path=ConvertTo-MorphospaceProtocolRelativePath ([string]$Validator.path);$absolute=[IO.Path]::GetFullPath([IO.Path]::Combine($root,$path));Assert-MorphospaceNoReparseAncestor $root $absolute
    if(-not[IO.File]::Exists($absolute)-or(Get-MorphospaceFileSha256 $absolute)-cne[string]$Validator.sha256){throw "Validator bytes changed: $path"}
    $head=(ConvertFrom-MorphospaceOwnershipUtf8 (Invoke-MorphospaceOwnershipGit $GitExecutable $root @('rev-parse','HEAD')).stdout).Trim();$pinned=(ConvertFrom-MorphospaceOwnershipUtf8 (Invoke-MorphospaceOwnershipGit $GitExecutable $root @('rev-parse',"$([string]$Validator.owner_revision)^{commit}")).stdout).Trim();$treeOid=(ConvertFrom-MorphospaceOwnershipUtf8 (Invoke-MorphospaceOwnershipGit $GitExecutable $root @('rev-parse',"$([string]$Validator.owner_revision)^{tree}")).stdout).Trim();if($pinned-cne[string]$Validator.owner_revision-or$treeOid-cne[string]$Validator.owner_tree_oid){throw "Pinned validator owner revision/tree is unavailable or changed: $path"};$ancestor=Invoke-MorphospaceOwnershipGit $GitExecutable $root @('merge-base','--is-ancestor',[string]$Validator.owner_revision,$head) -AllowFailure;if($ancestor.exit_code-ne0){throw "Pinned validator owner revision is not an ancestor of current HEAD: $path"}
    foreach($revision in @([string]$Validator.owner_revision,'HEAD')){$tree=ConvertFrom-MorphospaceOwnershipUtf8 (Invoke-MorphospaceOwnershipGit $GitExecutable $root @('ls-tree','-z',$revision,'--',$path)).stdout;$tokens=[Collections.Generic.List[string]]::new();foreach($token in $tree.Split([char]0)){if($token){$tokens.Add($token)}};if($tokens.Count-ne1){throw "Validator is not exactly one tracked blob at '$revision': $path"};$match=[regex]::Match($tokens[0],'^[0-9]{6} blob (?<oid>[0-9a-f]{40,64})\t');if(-not$match.Success-or$match.Groups['oid'].Value-cne[string]$Validator.git_blob_oid){throw "Validator blob changed at '$revision': $path"}}
    $status=Invoke-MorphospaceOwnershipGit $GitExecutable $root @('status','--porcelain=v2','-z','--',$path);if($status.stdout.Length-ne0){throw "Validator has index/worktree drift: $path"};return $true
}

function Get-MorphospaceRegistrySelection {
    param([object]$Registry,[object]$Unit,[hashtable]$RepositoryMap,[string]$AssertedProfileId='')
    $profile=[string]$Unit.risk_tier;if($profile-notin@('quick','standard','deep')){throw 'Unit does not derive a supported profile.'};if($AssertedProfileId-and$AssertedProfileId-cne$profile){throw 'Caller profile assertion does not equal the derived profile.'}
    $declaredProfileCount=0;foreach($row in @($Unit.validation)){if([string]$row.profile_id-ceq$profile){$declaredProfileCount++}};if($declaredProfileCount-ne1){throw "Unit must declare exactly one '$profile' profile."}
    $criteria=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($row in @($Unit.acceptance)){if(-not$criteria.Add([string]$row.acceptance_id)){throw 'Unit repeats an acceptance ID.'}}
    $selected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);$coverage=@{}
    foreach($criterion in $criteria){$matches=[Collections.Generic.List[object]]::new();foreach($validator in @($Registry.validators)){if(@($validator.profiles)-ccontains$profile-and@($validator.acceptance_ids)-ccontains$criterion){$matches.Add($validator)}};if($matches.Count-ne1){throw "Acceptance '$criterion' does not resolve to exactly one '$profile' validator."};$validator=$matches[0];$selected[[string]$validator.validator_id]=$validator;$coverage[$criterion]=[string]$validator.validator_id}
    $selectedArray=@($selected.Values);[Array]::Sort($selectedArray,[Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare([string]$left.validator_id,[string]$right.validator_id)});foreach($validator in $selectedArray){[void](Test-MorphospaceTrackedValidator $validator $RepositoryMap[[string]$validator.owner_repo_id])}
    $criteriaArray=@($criteria);[Array]::Sort($criteriaArray,[StringComparer]::Ordinal);return [pscustomobject]@{profile_id=$profile;validators=$selectedArray;coverage=$coverage;acceptance_ids=$criteriaArray}
}

function ConvertTo-MorphospaceEntryCore {
    param([object]$Entry)
    return [pscustomobject][ordered]@{path=[string]$Entry.path;state=[string]$Entry.state;sha256=if($null-eq$Entry.sha256){$null}else{[string]$Entry.sha256};length=if($null-eq$Entry.length){$null}else{[long]$Entry.length};mode=if($null-eq$Entry.mode){$null}else{[string]$Entry.mode};patch_sha256=if($null-eq$Entry.patch_sha256){$null}else{[string]$Entry.patch_sha256};hunks=@($Entry.hunks)}
}

function New-MorphospaceObservedEntry {
    param([object]$RepositoryObservation,[object]$Entry)
    if([string]$RepositoryObservation.kind-ceq'git'){
        $state=if([string]$Entry.worktree.state-ceq'deleted'){'deleted'}elseif([string]$Entry.worktree.kind-ceq'directory'){'directory'}else{'file'}
        $mode=$null;if(@($Entry.index).Count-eq1){$mode=[string]$Entry.index[0].mode}elseif($null-ne$Entry.head){$mode=[string]$Entry.head.mode}elseif($null-ne$Entry.base){$mode=[string]$Entry.base.mode}
        $core=[pscustomobject][ordered]@{path=[string]$Entry.path;state=$state;sha256=if($state-ceq'file'){[string]$Entry.worktree.sha256}else{$null};length=if($state-ceq'file'){[long]$Entry.worktree.length}else{$null};mode=$mode;patch_sha256=[string]$Entry.patch_sha256;hunks=@($Entry.hunks)}
    }else{
        $core=[pscustomobject][ordered]@{path=[string]$Entry.path;state=if([string]$Entry.kind-ceq'directory'){'directory'}else{'file'};sha256=if([string]$Entry.kind-ceq'file'){[string]$Entry.sha256}else{$null};length=if([string]$Entry.kind-ceq'file'){[long]$Entry.length}else{$null};mode=$null;patch_sha256=$null;hunks=@()}
    }
    return [pscustomobject]@{core=$core;fingerprint_sha256=(Get-MorphospaceCanonicalJsonSha256 $core)}
}

function Get-MorphospaceObservedEntryMap {
    param([object]$RepositoryObservation)
    $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in @($RepositoryObservation.entries)){$normalized=New-MorphospaceObservedEntry $RepositoryObservation $entry;if($map.ContainsKey([string]$normalized.core.path)){throw 'Observation repeats an entry path.'};$map[[string]$normalized.core.path]=$normalized}
    return $map
}

function Test-MorphospaceClaimBaseline {
    param([object]$Baseline,[object]$Unit,[object]$RepositoryMapReference,[hashtable]$RepositoryMap)
    Assert-MorphospaceExactPropertySet $Baseline @('schema','baseline_id','created_at','project_id','unit_id','repository_map','repositories','status') @() 'claim baseline'
    if([string]$Baseline.schema-cne'rusty.morphospace.workflow.claim_baseline.v1'-or[string]$Baseline.status-cne'frozen'-or[string]$Baseline.project_id-cne[string]$Unit.project_id-or[string]$Baseline.unit_id-cne[string]$Unit.unit_id){throw 'Claim baseline identity/schema/status is invalid.'};[void](Test-MorphospaceStrictUtcTimestamp ([string]$Baseline.created_at))
    Assert-MorphospaceExactPropertySet $Baseline.repository_map @('role','path','schema','sha256') @() 'claim baseline repository-map reference';if((Get-MorphospaceOrdinalFingerprint $Baseline.repository_map)-cne(Get-MorphospaceOrdinalFingerprint $RepositoryMapReference)){throw 'Claim baseline repository-map binding changed.'}
    $scopes=@{};foreach($scope in @($Unit.allowed_repositories)){$id=[string]$scope.repo_id;if($scopes.ContainsKey($id)){throw 'Unit repeats a repository scope.'};$scopes[$id]=$scope}
    $rows=@{};foreach($row in @($Baseline.repositories)){
        Assert-MorphospaceExactPropertySet $row @('repo_id','kind','head_revision','head_tree_oid','branch','allowed_paths','content_observation_sha256','status_sha256','overlay_fingerprint_sha256','commit_manifest_fingerprint_sha256','instruction_observation_sha256','entries_fingerprint_sha256','entries','instructions_fingerprint_sha256','instructions') @() 'claim baseline repository'
        $id=[string]$row.repo_id;if($rows.ContainsKey($id)-or-not$scopes.ContainsKey($id)-or-not$RepositoryMap.ContainsKey($id)){throw "Unexpected/duplicate baseline repository '$id'."}
        $expected=ConvertTo-MorphospaceSortedCanonicalPaths @($scopes[$id].allowed_paths);$actual=ConvertTo-MorphospaceSortedCanonicalPaths @($row.allowed_paths);if(($expected-join"`n")-cne($actual-join"`n")){throw "Baseline path scope changed for '$id'."}
        if([string]$row.kind-ceq'git'){Test-MorphospaceLowerObjectId ([string]$row.head_revision) "Baseline '$id' HEAD";Test-MorphospaceLowerObjectId ([string]$row.head_tree_oid) "Baseline '$id' tree";if([string]$row.status_sha256-notmatch'^[0-9a-f]{64}$'-or[string]$row.overlay_fingerprint_sha256-notmatch'^[0-9a-f]{64}$'-or[string]$row.commit_manifest_fingerprint_sha256-notmatch'^[0-9a-f]{64}$'){throw "Baseline '$id' Git fingerprints are invalid."}}
        elseif([string]$row.kind-cne'non-git'-or$null-ne$row.head_revision-or$null-ne$row.head_tree_oid-or$null-ne$row.branch-or$null-ne$row.status_sha256-or$null-ne$row.commit_manifest_fingerprint_sha256){throw "Baseline '$id' non-Git identity is invalid."}
        $entryMap=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);$priorPath=$null;foreach($entry in @($row.entries)){Assert-MorphospaceExactPropertySet $entry @('path','entry_fingerprint_sha256','state','sha256','length','mode','patch_sha256','hunks') @() 'claim baseline entry';$path=ConvertTo-MorphospaceProtocolRelativePath ([string]$entry.path);if([string]$entry.path-cne$path-or$entryMap.ContainsKey($path)-or($null-ne$priorPath-and[StringComparer]::Ordinal.Compare($priorPath,$path)-ge0)){throw "Baseline entry order/path is non-canonical: '$id/$path'."};$priorPath=$path;$core=ConvertTo-MorphospaceEntryCore $entry;$fingerprint=Get-MorphospaceCanonicalJsonSha256 $core;if($fingerprint-cne[string]$entry.entry_fingerprint_sha256){throw "Baseline entry fingerprint changed: $id/$path"};$entryMap[$path]=[pscustomobject]@{core=$core;fingerprint_sha256=$fingerprint}}
        if((Get-MorphospaceOrdinalFingerprint @($row.entries))-cne[string]$row.entries_fingerprint_sha256){throw "Baseline entry set fingerprint changed for '$id'."}
        $instructionSeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$priorInstruction=$null;foreach($instruction in @($row.instructions)){Assert-MorphospaceExactPropertySet $instruction @('repo_id','path','relative_path','sha256') @() 'claim baseline instruction';$relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$instruction.relative_path);$key="$([string]$instruction.repo_id)/$relative";if([string]$instruction.repo_id-cne$id-or[string]$instruction.relative_path-cne$relative-or[string]$instruction.sha256-notmatch'^[0-9a-f]{64}$'-or-not$instructionSeen.Add($key)-or($null-ne$priorInstruction-and[StringComparer]::Ordinal.Compare($priorInstruction,$key)-ge0)){throw "Baseline instruction identity/order changed for '$id'."};$priorInstruction=$key}
        $instructionFingerprint=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=@($row.instructions)});if($instructionFingerprint-cne[string]$row.instructions_fingerprint_sha256-or[string]$row.instruction_observation_sha256-cne$instructionFingerprint){throw "Baseline instruction fingerprint changed for '$id'."}
        $rows[$id]=[pscustomobject]@{document=$row;entry_map=$entryMap}
    }
    if($rows.Count-ne$scopes.Count){throw 'Claim baseline repository set is incomplete.'};return $rows
}

function Get-MorphospaceAuthorityObservation {
    param([object]$Unit,[hashtable]$RepositoryMap,[object]$Ownership,[string]$GitExecutable='',[object[]]$AutomationOutputs=@())
    if(-not$GitExecutable){$GitExecutable=(Get-MorphospaceBoundExecutable git).path};$ownedByRepo=@{};foreach($row in @($Ownership.repositories)){$ownedByRepo[[string]$row.repo_id]=$row};$repositories=[Collections.Generic.List[object]]::new()
    foreach($scope in @($Unit.allowed_repositories)){$id=[string]$scope.repo_id;if(-not$RepositoryMap.ContainsKey($id)-or-not$ownedByRepo.ContainsKey($id)){throw "Observation lacks '$id'."};$owned=$ownedByRepo[$id];if([string]$owned.kind-ceq'git'){$observation=Get-MorphospaceGitRepositoryObservation -RepoId $id -RepositoryPath ([string]$RepositoryMap[$id].path) -BaseRevision ([string]$owned.base_revision) -AllowedPaths @($scope.allowed_paths) -GitExecutable $GitExecutable}else{$observation=Get-MorphospaceNonGitTreeObservation -RepoId $id -RootPath ([string]$RepositoryMap[$id].path) -AllowedPaths @($scope.allowed_paths)};$repositories.Add((ConvertTo-MorphospaceComparableRepositoryObservation -Observation $observation -AutomationOutputs @($AutomationOutputs | Where-Object { [string]$_.repo_id -ceq $id })))}
    $instructions=@(Get-MorphospaceInstructionObservation $Unit $RepositoryMap);$document=[pscustomobject][ordered]@{repositories=@($repositories.ToArray());instructions=$instructions};return [pscustomobject]@{document=$document;sha256=(Get-MorphospaceCanonicalJsonSha256 $document)}
}

function Get-MorphospaceAutomationOutputContract {
    param([Parameter(Mandatory=$true)][object]$Ownership,[Parameter(Mandatory=$true)][object]$Unit,[Parameter(Mandatory=$true)][hashtable]$Scopes)
    $allowedRoles=@{
        'owner-validator-registry'=[pscustomobject]@{phase='bootstrap';schema='rusty.morphospace.workflow.owner_validator_registry.v1'}
        'unit-ownership'=[pscustomobject]@{phase='bootstrap';schema='rusty.morphospace.workflow.unit_ownership.v1'}
        'legacy-prefix-anchor'=[pscustomobject]@{phase='bootstrap';schema='rusty.morphospace.workflow.legacy_event_prefix_anchor.v1'}
        'validator-trust-anchor-migration'=[pscustomobject]@{phase='bootstrap';schema='rusty.morphospace.workflow.validator_trust_anchor_migration.v1'}
        'current-unit-protocol'=[pscustomobject]@{phase='bootstrap';schema='rusty.morphospace.workflow.current_unit_protocol.v1'}
        'validation-action'=[pscustomobject]@{phase='bootstrap';schema='rusty.morphospace.workflow.validation_action.v2'}
        'owner-validation'=[pscustomobject]@{phase='validation';schema='rusty.morphospace.workflow.owner_validation.v1'}
        'validation-evidence'=[pscustomobject]@{phase='validation';schema='rusty.morphospace.workflow.validation_evidence.v2'}
        'validation-execution'=[pscustomobject]@{phase='validation';schema='rusty.morphospace.workflow.validation_execution.v1'}
        'validation-receipt'=[pscustomobject]@{phase='validation';schema='rusty.morphospace.workflow.validation_receipt.v2'}
        'transition-ledger-intent'=[pscustomobject]@{phase='transition';schema='rusty.morphospace.workflow.transition_ledger_intent.v1'}
        'transition-ledger-completion'=[pscustomobject]@{phase='transition';schema='rusty.morphospace.workflow.transition_ledger_completion.v1'}
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$rows=[Collections.Generic.List[object]]::new()
    $rawOutputs=if($Ownership.PSObject.Properties.Name-contains'automation_outputs'){@($Ownership.automation_outputs)}else{@()}
    foreach($output in $rawOutputs){
        Assert-MorphospaceExactPropertySet $output @('repo_id','path','phase','role','schema','validator_id') @() 'automation output'
        $repoId=[string]$output.repo_id;if(-not$Scopes.ContainsKey($repoId)){throw "Automation output names an unowned repository: $repoId"}
        $path=ConvertTo-MorphospaceProtocolRelativePath ([string]$output.path);if([string]$output.path-cne$path-or-not(Test-MorphospacePathInClosure $path @($Scopes[$repoId].allowed_paths))){throw "Automation output is outside unit scope: $repoId/$path"}
        $role=[string]$output.role;if(-not$allowedRoles.ContainsKey($role)){throw "Automation output role is not allowlisted: $role"};$rule=$allowedRoles[$role]
        if([string]$output.phase-cne[string]$rule.phase-or[string]$output.schema-cne[string]$rule.schema){throw "Automation output phase/schema is not canonical: $repoId/$path"}
        $validatorId=[string]$output.validator_id
        if($role-ceq'owner-validation') {if($validatorId-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'){throw "Owner-validation output lacks a validator id: $repoId/$path"}}elseif($null-ne$output.validator_id){throw "Non-owner automation output carries a validator id: $repoId/$path"}
        if(-not$seen.Add("$repoId/$path")){throw "Automation output repeats: $repoId/$path"}
        $rows.Add([pscustomobject][ordered]@{repo_id=$repoId;path=$path;phase=[string]$output.phase;role=$role;schema=[string]$output.schema;validator_id=if($role-ceq'owner-validation'){$validatorId}else{$null}})|Out-Null
    }
    $array=@($rows.ToArray());[Array]::Sort($array,[Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare("$([string]$left.repo_id)/$([string]$left.path)","$([string]$right.repo_id)/$([string]$right.path)")});return $array
}

function Test-MorphospaceAutomationOutputSet {
    param([Parameter(Mandatory=$true)][object[]]$AutomationOutputs,[Parameter(Mandatory=$true)][hashtable]$RepositoryMap,[ValidateSet('present','absent')][string]$Expected='present',[string]$Phase='')
    foreach($output in @($AutomationOutputs | Where-Object { if ($Phase) { [string]$_.phase -ceq $Phase } else { $true } })){$repoId=[string]$output.repo_id;if(-not$RepositoryMap.ContainsKey($repoId)){throw "Automation output repository is unavailable: $repoId"};$root=[IO.Path]::GetFullPath([string]$RepositoryMap[$repoId].path);$candidate=[IO.Path]::GetFullPath([IO.Path]::Combine($root,[string]$output.path));Assert-MorphospaceNoReparseAncestor $root $candidate;$exists=[IO.File]::Exists($candidate);if($Expected-ceq'present' -and-not$exists){throw "Required automation output is missing: $repoId/$([string]$output.path)"};if($Expected-ceq'absent' -and($exists-or[IO.Directory]::Exists($candidate))){throw "Automation output already exists: $repoId/$([string]$output.path)"}}
}

function ConvertTo-MorphospaceComparableRepositoryObservation {
    param([Parameter(Mandatory=$true)][object]$Observation,[object[]]$AutomationOutputs=@())
    $excluded=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($output in @($AutomationOutputs)){[void]$excluded.Add((ConvertTo-MorphospaceProtocolRelativePath ([string]$output.path)))}
    if($excluded.Count-eq0){return $Observation}
    $entries=[Collections.Generic.List[object]]::new();foreach($entry in @($Observation.entries)){if(-not$excluded.Contains([string]$entry.path)){$entries.Add($entry);continue};if([string]$entry.scope-cne'allowed'-or$null-eq$entry.status-or[string]$entry.status.record_type-cne'untracked'-or[string]$entry.status.xy-cne'??'-or$null-ne$entry.base-or$null-ne$entry.head-or@($entry.index).Count-ne0-or[string]$entry.worktree.state-cne'present'-or[string]$entry.worktree.kind-cne'file'){throw "Automation output is not an untracked file-only delta: $([string]$Observation.repo_id)/$([string]$entry.path)"}}
    $entryArray=@($entries.ToArray())
    if([string]$Observation.kind-ceq'git'){
        $statusRows=[Collections.Generic.List[object]]::new();foreach($record in @($Observation.status_records)){if($excluded.Contains([string]$record.path)-or($null-ne$record.original_path-and$excluded.Contains([string]$record.original_path))){if([string]$record.record_type-cne'untracked'-or[string]$record.xy-cne'??'){throw "Automation output has non-untracked Git status: $([string]$Observation.repo_id)/$([string]$record.path)"};continue};$statusRows.Add($record)|Out-Null}
        $statusArray=@($statusRows.ToArray());$statusFingerprint=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{records=$statusArray});$entryFingerprint=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$entryArray})
        return [pscustomobject][ordered]@{repo_id=[string]$Observation.repo_id;kind='git';git_executable_sha256=[string]$Observation.git_executable_sha256;git_version=[string]$Observation.git_version;object_format=[string]$Observation.object_format;base_revision=[string]$Observation.base_revision;head_revision=[string]$Observation.head_revision;head_tree=[string]$Observation.head_tree;branch=[string]$Observation.branch;status_sha256=$statusFingerprint;status_records=$statusArray;commits=@($Observation.commits);commit_fingerprint_sha256=[string]$Observation.commit_fingerprint_sha256;patch_sha256=(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$entryArray}));entries=$entryArray;overlay_fingerprint_sha256=$entryFingerprint;scope_violation_count=@($entryArray|Where-Object{[string]$_.scope-cne'allowed'}).Count;attribution='unassigned'}
    }
    $treeFingerprint=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$entryArray});return [pscustomobject][ordered]@{repo_id=[string]$Observation.repo_id;kind='non-git';entries=$entryArray;tree_fingerprint_sha256=$treeFingerprint;attribution='unassigned'}
}

function Get-MorphospaceReobservedTerminalEntry {
    param([string]$Root,[string]$Kind,[string]$BaseRevision,[object]$BaselineEntry,[string]$GitExecutable)
    $relative=[string]$BaselineEntry.core.path;$absolute=[IO.Path]::GetFullPath([IO.Path]::Combine($Root,$relative));Assert-MorphospaceNoReparseAncestor $Root $absolute;$emptyHash=Get-MorphospaceSha256Bytes ([byte[]]::new(0))
    if($Kind-ceq'git'){$status=Invoke-MorphospaceOwnershipGit $GitExecutable $Root @('status','--porcelain=v2','-z','--',$relative);if($status.stdout.Length-ne0){throw "Baseline path disappeared from the aggregate observation but remains dirty: $relative"};$treeText=ConvertFrom-MorphospaceOwnershipUtf8 (Invoke-MorphospaceOwnershipGit $GitExecutable $Root @('ls-tree','-z',$BaseRevision,'--',$relative)).stdout;$tokens=[Collections.Generic.List[string]]::new();foreach($token in $treeText.Split([char]0)){if($token){$tokens.Add($token)}}
        if($tokens.Count-eq0){if([IO.File]::Exists($absolute)-or[IO.Directory]::Exists($absolute)){throw "Untracked baseline path reappeared outside the aggregate observation: $relative"};$core=[pscustomobject][ordered]@{path=$relative;state='deleted';sha256=$null;length=$null;mode=$BaselineEntry.core.mode;patch_sha256=$emptyHash;hunks=@()}}
        elseif($tokens.Count-eq1){$match=[regex]::Match($tokens[0],'^(?<mode>100644|100755) blob (?<oid>[0-9a-f]{40,64})\t');if(-not$match.Success-or-not[IO.File]::Exists($absolute)){throw "Tracked baseline terminal state is damaged: $relative"};$blob=(Invoke-MorphospaceOwnershipGit $GitExecutable $Root @('cat-file','blob',$match.Groups['oid'].Value)).stdout;$stream=[IO.FileStream]::new($absolute,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{$blobHash=Get-MorphospaceSha256Bytes $blob;$liveHash=Get-MorphospaceStreamSha256 $stream;if($blob.Length-ne$stream.Length-or$blobHash-cne$liveHash){throw "Tracked baseline terminal bytes differ from the exact base: $relative"};$core=[pscustomobject][ordered]@{path=$relative;state='file';sha256=$liveHash;length=[long]$stream.Length;mode=$match.Groups['mode'].Value;patch_sha256=$emptyHash;hunks=@()}}finally{$stream.Dispose()}}
        else{throw "Tracked baseline terminal path is ambiguous: $relative"}
    }else{if([IO.File]::Exists($absolute)-or[IO.Directory]::Exists($absolute)){throw "Non-Git baseline path disappeared from its full-tree observation but still exists: $relative"};$core=[pscustomobject][ordered]@{path=$relative;state='deleted';sha256=$null;length=$null;mode=$BaselineEntry.core.mode;patch_sha256=$null;hunks=@()}}
    return [pscustomobject]@{core=$core;fingerprint_sha256=(Get-MorphospaceCanonicalJsonSha256 $core)}
}

function Test-MorphospaceUnitOwnership {
    param([object]$Ownership,[object]$ClaimBaseline,[object]$ClaimBaselineReference,[object]$Unit,[object]$RepositoryMapReference,[hashtable]$RepositoryMap,[switch]$BootstrapException,[string[]]$CommittedTransitionPaths=@())
    Assert-MorphospaceExactPropertySet $Ownership @('schema','ownership_id','created_at','project_id','unit_id','claim_baseline','repositories','shared_overlaps','status') @('automation_outputs') 'unit ownership';if([string]$Ownership.schema-cne'rusty.morphospace.workflow.unit_ownership.v1'-or[string]$Ownership.status-cne'assigned'-or[string]$Ownership.project_id-cne[string]$Unit.project_id-or[string]$Ownership.unit_id-cne[string]$Unit.unit_id){throw 'Unit ownership identity/schema/status is invalid.'};[void](Test-MorphospaceStrictUtcTimestamp ([string]$Ownership.created_at));Assert-MorphospaceExactPropertySet $Ownership.claim_baseline @('role','path','schema','sha256') @() 'ownership baseline reference';if((Get-MorphospaceOrdinalFingerprint $Ownership.claim_baseline)-cne(Get-MorphospaceOrdinalFingerprint $ClaimBaselineReference)){throw 'Ownership claim-baseline reference changed.'}
    $baselineRows=Test-MorphospaceClaimBaseline $ClaimBaseline $Unit $RepositoryMapReference $RepositoryMap;$scopes=@{};foreach($scope in @($Unit.allowed_repositories)){$scopes[[string]$scope.repo_id]=$scope};$transitionPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($transitionPath in @($CommittedTransitionPaths)){$canonical=ConvertTo-MorphospaceProtocolRelativePath ([string]$transitionPath);if(-not$transitionPaths.Add($canonical)){throw "Committed transition path repeats: $canonical"}};$ownershipRows=@{}
    foreach($row in @($Ownership.repositories)){Assert-MorphospaceExactPropertySet $row @('repo_id','kind','base_revision','head_revision','head_tree_oid','branch','allowed_paths','live_content_observation_sha256','live_status_sha256','live_overlay_fingerprint_sha256','live_commit_manifest_fingerprint_sha256','baseline_entries_sha256','preserved_baseline_entries_sha256','preserved_baseline_count','instruction_observation_sha256','entries') @() 'ownership repository';$id=[string]$row.repo_id;if($ownershipRows.ContainsKey($id)-or-not$baselineRows.ContainsKey($id)){throw "Unexpected ownership repository '$id'."};$baselineDocument=$baselineRows[$id].document;$expectedPaths=@(ConvertTo-MorphospaceSortedCanonicalPaths @($scopes[$id].allowed_paths));$ownedPaths=@(ConvertTo-MorphospaceSortedCanonicalPaths @($row.allowed_paths));if([string]$row.kind-cne[string]$baselineDocument.kind-or($expectedPaths-join"`n")-cne($ownedPaths-join"`n")-or[string]$row.branch-cne[string]$baselineDocument.branch){throw "Ownership identity/scope differs from unit baseline for '$id'."};if(-not$BootstrapException-and[string]$row.base_revision-cne[string]$baselineDocument.head_revision){throw "Ownership for '$id' reuses a cumulative pre-claim base."};if([string]$row.kind-ceq'non-git'-and($null-ne$row.base_revision-or$null-ne$row.head_revision-or$null-ne$row.head_tree_oid-or$null-ne$row.branch-or$null-ne$row.live_status_sha256-or$null-ne$row.live_commit_manifest_fingerprint_sha256)){throw "Non-Git ownership row '$id' has Git identity state."};$ownershipRows[$id]=$row}
    if($ownershipRows.Count-ne$baselineRows.Count){throw 'Ownership repository set is incomplete.'};$automationOutputs=@(Get-MorphospaceAutomationOutputContract $Ownership $Unit $scopes);foreach($output in $automationOutputs){if($baselineRows[[string]$output.repo_id].entry_map.ContainsKey([string]$output.path)){throw "Automation output was already present in the claim baseline: $([string]$output.repo_id)/$([string]$output.path)"}};$observation=Get-MorphospaceAuthorityObservation $Unit $RepositoryMap $Ownership -AutomationOutputs $automationOutputs
    $instructionByRepo=@{};foreach($id in $RepositoryMap.Keys){$list=[Collections.Generic.List[object]]::new();foreach($instruction in @($observation.document.instructions)){if([string]$instruction.repo_id-ceq$id){$list.Add([pscustomobject][ordered]@{repo_id=[string]$instruction.repo_id;path=[string]$instruction.path;relative_path=[string]$instruction.relative_path;sha256=[string]$instruction.sha256})}};$instructionByRepo[$id]=@($list.ToArray())}
    $gitExecutable=(Get-MorphospaceBoundExecutable git).path;foreach($repoObservation in @($observation.document.repositories)){$id=[string]$repoObservation.repo_id;$row=$ownershipRows[$id];$baselineContext=$baselineRows[$id];$baseline=$baselineContext.document;$hasTransitionProjection=@($transitionPaths|Where-Object{$_ -like "$id/*"}).Count-gt0;if(-not$hasTransitionProjection-and(Get-MorphospaceCanonicalJsonSha256 $repoObservation)-cne[string]$row.live_content_observation_sha256){throw "Live content observation changed for '$id'."};if(-not$hasTransitionProjection-and[string]$repoObservation.kind-ceq'git'){if([string]$repoObservation.head_revision-cne[string]$row.head_revision-or[string]$repoObservation.head_tree-cne[string]$row.head_tree_oid-or[string]$repoObservation.status_sha256-cne[string]$row.live_status_sha256-or[string]$repoObservation.overlay_fingerprint_sha256-cne[string]$row.live_overlay_fingerprint_sha256-or[string]$repoObservation.commit_fingerprint_sha256-cne[string]$row.live_commit_manifest_fingerprint_sha256){throw "Live Git identity/fingerprint changed for '$id'."}}
        if([string]$row.baseline_entries_sha256-cne[string]$baseline.entries_fingerprint_sha256){throw "Ownership baseline-entry binding changed for '$id'."};$current=Get-MorphospaceObservedEntryMap $repoObservation;$preserved=[Collections.Generic.List[string]]::new();$expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($path in $baselineContext.entry_map.Keys){$baseEntry=$baselineContext.entry_map[$path];$transitionKey="$id/$path";if($transitionPaths.Contains($transitionKey)){$preserved.Add([string]$baseEntry.fingerprint_sha256);if($current.ContainsKey($path)){[void]$current.Remove($path)};continue};$final=if($current.ContainsKey($path)){$current[$path]}else{Get-MorphospaceReobservedTerminalEntry ([string]$RepositoryMap[$id].path) ([string]$row.kind) ([string]$row.base_revision) $baseEntry $gitExecutable};if([string]$final.fingerprint_sha256-ceq[string]$baseEntry.fingerprint_sha256){$preserved.Add([string]$baseEntry.fingerprint_sha256);if($current.ContainsKey($path)){[void]$current.Remove($path)}}else{$expected[$path]=[pscustomobject]@{final=$final;baseline=$baseEntry;attribution='shared'};if($current.ContainsKey($path)){[void]$current.Remove($path)}}}
        foreach($path in $current.Keys){$expected[$path]=[pscustomobject]@{final=$current[$path];baseline=$null;attribution='unit'}};$preservedArray=@($preserved.ToArray());[Array]::Sort($preservedArray,[StringComparer]::Ordinal);if([long]$row.preserved_baseline_count-ne$preservedArray.Count-or[string]$row.preserved_baseline_entries_sha256-cne(Get-MorphospaceOrdinalFingerprint $preservedArray)){throw "Preserved baseline set changed for '$id'."}
        $manifestEntries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);foreach($entry in @($row.entries)){Assert-MorphospaceExactPropertySet $entry @('path','final_entry_fingerprint_sha256','baseline_entry_fingerprint_sha256','state','sha256','length','mode','patch_sha256','hunks','attribution') @() 'ownership entry';$path=ConvertTo-MorphospaceProtocolRelativePath ([string]$entry.path);if($manifestEntries.ContainsKey($path)){throw "Ownership repeats '$id/$path'."};$core=ConvertTo-MorphospaceEntryCore $entry;$fingerprint=Get-MorphospaceCanonicalJsonSha256 $core;if($fingerprint-cne[string]$entry.final_entry_fingerprint_sha256){throw "Final ownership fingerprint changed: $id/$path"};$manifestEntries[$path]=[pscustomobject]@{document=$entry;core=$core;fingerprint_sha256=$fingerprint}}
        if($manifestEntries.Count-ne$expected.Count){throw "Ownership entry set does not subtract the claim baseline for '$id'."};foreach($path in $expected.Keys){if(-not$manifestEntries.ContainsKey($path)){throw "Ownership omits '$id/$path'."};$actual=$manifestEntries[$path];$wanted=$expected[$path];if([string]$actual.fingerprint_sha256-cne[string]$wanted.final.fingerprint_sha256-or[string]$actual.document.attribution-cne[string]$wanted.attribution){throw "Ownership misattributes '$id/$path'."};$baselineFingerprint=if($null-eq$wanted.baseline){$null}else{[string]$wanted.baseline.fingerprint_sha256};if([string]$actual.document.baseline_entry_fingerprint_sha256-cne[string]$baselineFingerprint){throw "Ownership baseline binding changed: $id/$path"}}
        $instructionHash=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=@($instructionByRepo[$id])});if([string]$row.instruction_observation_sha256-cne$instructionHash){throw "Instruction observation changed for '$id'."}
    }
    $sharedBindings=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);$integrationIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($decision in @($Ownership.shared_overlaps)){Assert-MorphospaceExactPropertySet $decision @('integration_id','repo_id','bindings','contributing_units','integration_owner','decision') @() 'shared overlap';$contributors=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($contributor in @($decision.contributing_units)){if([string]$contributor-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'-or-not$contributors.Add([string]$contributor)){throw 'Shared overlap repeats/invalidates a contributing unit.'}};$decisionRepo=[string]$decision.repo_id;if(-not$ownershipRows.ContainsKey($decisionRepo)-or@($decision.bindings).Count-eq0-or[string]$decision.integration_id-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'-or-not$integrationIds.Add([string]$decision.integration_id)-or[string]$decision.decision-cne'accepted'-or$contributors.Count-lt2-or$contributors.Contains([string]$decision.integration_owner)-or-not$contributors.Contains([string]$Unit.unit_id)){throw 'Shared overlap repo/identity/contributors/integration owner are invalid.'};foreach($binding in @($decision.bindings)){Assert-MorphospaceExactPropertySet $binding @('path','baseline_entry_fingerprint_sha256','final_entry_fingerprint_sha256','patch_sha256','hunks') @() 'shared overlap binding';$bindingPath=ConvertTo-MorphospaceProtocolRelativePath ([string]$binding.path);if([string]$binding.path-cne$bindingPath-or-not(Test-MorphospacePathInClosure $bindingPath ([string[]]$ownershipRows[$decisionRepo].allowed_paths))){throw 'Shared binding path is non-canonical or outside ownership.'};$key="$decisionRepo/$bindingPath";if($sharedBindings.ContainsKey($key)){throw "Shared binding repeats '$key'."};$sharedBindings[$key]=[pscustomobject]@{document=$binding;used=$false}}}
    foreach($row in @($Ownership.repositories)){foreach($entry in @($row.entries)){if([string]$entry.attribution-ceq'shared'){$key="$([string]$row.repo_id)/$([string]$entry.path)";if(-not$sharedBindings.ContainsKey($key)){throw "Shared entry lacks a binding: $key"};$record=$sharedBindings[$key];$binding=$record.document;if([string]$binding.baseline_entry_fingerprint_sha256-cne[string]$entry.baseline_entry_fingerprint_sha256-or[string]$binding.final_entry_fingerprint_sha256-cne[string]$entry.final_entry_fingerprint_sha256-or[string]$binding.patch_sha256-cne[string]$entry.patch_sha256-or(Get-MorphospaceOrdinalFingerprint @($binding.hunks))-cne(Get-MorphospaceOrdinalFingerprint @($entry.hunks))){throw "Shared hunk binding changed: $key"};$record.used=$true}}};foreach($key in $sharedBindings.Keys){if(-not[bool]$sharedBindings[$key].used){throw "Orphan shared binding '$key'."}}
    $finalObservation=Get-MorphospaceAuthorityObservation $Unit $RepositoryMap $Ownership -AutomationOutputs $automationOutputs;if([string]$finalObservation.sha256-cne[string]$observation.sha256){throw 'Repository/instruction state changed after terminal ownership probes.'};return [pscustomobject]@{observation=$finalObservation;ownership_by_repo=$ownershipRows;baseline_by_repo=$baselineRows;automation_outputs=$automationOutputs}
}

function Test-MorphospacePathInClosure {
    param([string]$Path,[string[]]$AllowedPaths)
    $candidate=ConvertTo-MorphospaceProtocolRelativePath $Path
    foreach($raw in $AllowedPaths){$scope=([string]$raw).TrimEnd('/','\');if(-not$scope){throw 'Path scope cannot be empty after a directory suffix is normalized.'};$allowed=ConvertTo-MorphospaceProtocolRelativePath $scope;if($candidate.Equals($allowed,[StringComparison]::OrdinalIgnoreCase)-or$candidate.StartsWith($allowed+'/',[StringComparison]::OrdinalIgnoreCase)){return $true}}
    return $false
}

function Get-MorphospaceCleanClosureMap {
    param([object[]]$InputClosure,[hashtable]$OwnershipByRepo)
    $map=@{}
    foreach($row in $InputClosure){Assert-MorphospaceExactPropertySet $row @('repo_id','kind','paths') @() 'clean-room input closure';$id=[string]$row.repo_id;if(-not$OwnershipByRepo.ContainsKey($id)){throw "Input closure expands beyond ownership: $id"};$paths=@(ConvertTo-MorphospaceSortedCanonicalPaths @($row.paths));if($paths.Count-eq0){throw "Input closure for '$id' is empty."};if(-not$map.ContainsKey($id)){$map[$id]=[Collections.Generic.List[string]]::new()};foreach($path in $paths){if(-not(Test-MorphospacePathInClosure $path @($OwnershipByRepo[$id].allowed_paths))){throw "Input closure path is outside ownership: $id/$path"};$map[$id].Add($path)}}
    foreach($id in @($map.Keys)){$values=@($map[$id].ToArray());[Array]::Sort($values,[StringComparer]::Ordinal);for($i=0;$i-lt$values.Count;$i++){if($i-gt0-and$values[$i].Equals($values[$i-1],[StringComparison]::OrdinalIgnoreCase)){throw "Input closure repeats '$id/$($values[$i])'."};for($j=$i+1;$j-lt$values.Count;$j++){if($values[$j].StartsWith($values[$i]+'/',[StringComparison]::OrdinalIgnoreCase)){throw "Input closure overlaps '$id/$($values[$i])'."}}};$map[$id]=$values}
    return $map
}

function Write-MorphospaceCleanBlob {
    param([string]$Target,[byte[]]$Bytes)
    $parent=[IO.Path]::GetDirectoryName($Target);if(-not[IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)};$stream=[IO.FileStream]::new($Target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough);try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

function Copy-MorphospaceLeasedOverlay {
    param([string]$Source,[string]$Target,[object]$Entry)
    $sourceStream=[IO.FileStream]::new($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{if($sourceStream.Length-ne[long]$Entry.length-or(Get-MorphospaceStreamSha256 $sourceStream)-cne[string]$Entry.sha256){throw "Owned overlay changed before clean-room copy: $([string]$Entry.path)"};$parent=[IO.Path]::GetDirectoryName($Target);if(-not[IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)};if([IO.File]::Exists($Target)){[IO.File]::Delete($Target)};$targetStream=[IO.FileStream]::new($Target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough);try{$sourceStream.Position=0;$sourceStream.CopyTo($targetStream);$targetStream.Flush($true)}finally{$targetStream.Dispose()};if((Get-MorphospaceStreamSha256 $sourceStream)-cne[string]$Entry.sha256-or(Get-MorphospaceFileSha256 $Target)-cne[string]$Entry.sha256){throw "Owned overlay changed during clean-room copy: $([string]$Entry.path)"};$result=[pscustomobject]@{path=$Source;length=[long]$Entry.length;sha256=[string]$Entry.sha256;stream=$sourceStream};$sourceStream=$null;return $result}finally{if($null-ne$sourceStream){$sourceStream.Dispose()}}
}

function Get-MorphospaceNoFollowTreeRows {
    param([string]$Root,[string]$RepoId,[hashtable]$Modes)
    $rows=[Collections.Generic.List[object]]::new();$pending=[Collections.Generic.Stack[string]]::new();$pending.Push($Root);$prefix=$Root.TrimEnd('\','/')
    while($pending.Count-gt0){$path=$pending.Pop();$attributes=[IO.File]::GetAttributes($path);if(($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Clean room contains a reparse point: $path"};if(($attributes-band[IO.FileAttributes]::Directory)-ne0){$children=@([IO.Directory]::GetFileSystemEntries($path));[Array]::Sort($children,[StringComparer]::Ordinal);for($index=$children.Length-1;$index-ge0;$index--){$pending.Push($children[$index])}}else{$relative=$path.Substring($prefix.Length).TrimStart('\','/').Replace('\','/');$rows.Add([pscustomobject][ordered]@{repo_id=$RepoId;path=$relative;length=[IO.FileInfo]::new($path).Length;sha256=(Get-MorphospaceFileSha256 $path);mode=if($Modes.ContainsKey($relative)){[string]$Modes[$relative]}else{$null}})}}
    return @($rows.ToArray())
}

function Get-MorphospaceBytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
}

function Add-MorphospaceCleanHistoryObjects {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRepository,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][object[]]$HistoryBlobs,
        [Parameter(Mandatory = $true)][string]$GitExecutable
    )
    $items = @($HistoryBlobs)
    if ($items.Count -eq 0) { return @() }
    foreach ($item in $items) { if ([string]$item.object_id -notmatch '^[0-9a-f]{40}$') { throw 'Clean history currently supports SHA-1 Git blob IDs only.' } }
    $initOutput = @(& $GitExecutable -C $Destination init --quiet --object-format=sha1 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Unable to initialize the sealed clean-room history store: $($initOutput -join [Environment]::NewLine)" }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        $objectId = [string]$item.object_id
        $bytes = (Invoke-MorphospaceOwnershipGit $GitExecutable $SourceRepository @('cat-file','blob',$objectId)).stdout
        $sha = Get-MorphospaceBytesSha256 $bytes
        if ($sha -cne [string]$item.sha256) { throw "Historical clean-room blob bytes drifted: $objectId" }
        $temporary = Join-Path $Destination ('.morphospace-history-' + [guid]::NewGuid().ToString('N') + '.blob')
        [IO.File]::WriteAllBytes($temporary, $bytes)
        try {
            $output = @(& $GitExecutable -C $Destination hash-object -w --no-filters $temporary 2>&1)
            $exitCode = $LASTEXITCODE
            $stdout = ([string]($output -join [Environment]::NewLine)).Trim().ToLowerInvariant()
            if ($exitCode -ne 0 -or -not $stdout.Equals($objectId, [StringComparison]::Ordinal)) { throw "Unable to seal historical clean-room blob '$objectId' (exit=$exitCode, output='$stdout')." }
        } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        $rows.Add([pscustomobject][ordered]@{ repo_id = [string]$item.repo_id; path = "git-history/$objectId"; object_id = $objectId; sha256 = $sha }) | Out-Null
    }
    return @($rows.ToArray())
}

function New-MorphospaceCleanRoom {
    param([object]$Ownership,[object]$ClaimBaseline,[hashtable]$RepositoryMap,[object[]]$InputClosure,[string]$AttemptId,[string]$GitExecutable='',[object[]]$HistoryBlobs=@())
    if($AttemptId-notmatch'^[a-z0-9][a-z0-9-]{7,95}$'){throw 'Clean-room attempt ID is invalid.'};if(-not$GitExecutable){$GitExecutable=(Get-MorphospaceBoundExecutable git).path};$ownedByRepo=@{};foreach($row in @($Ownership.repositories)){$ownedByRepo[[string]$row.repo_id]=$row};$baselineByRepo=@{};foreach($row in @($ClaimBaseline.repositories)){$baselineByRepo[[string]$row.repo_id]=$row};$closure=Get-MorphospaceCleanClosureMap $InputClosure $ownedByRepo
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');$parent=[IO.Path]::Combine($temp,'rusty-morphospace-cleanrooms');if(-not[IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)};Assert-MorphospaceNoReparseAncestor $temp $parent;$root=[IO.Path]::Combine($parent,"$AttemptId-$([guid]::NewGuid().ToString('N'))");[void][IO.Directory]::CreateDirectory($root);$guard=[guid]::NewGuid().ToString('N');$script:CleanRoomGuards[$root]=$guard;$roots=@{};$modesByRepo=@{};$total=[long]0;$sourceLeases=[Collections.Generic.List[object]]::new();$historyRows=[Collections.Generic.List[object]]::new()
    try{
        Test-MorphospaceHistoryBlobClosure @($HistoryBlobs) $RepositoryMap
        foreach($repoId in @($closure.Keys)){$owned=$ownedByRepo[$repoId];$source=[string]$RepositoryMap[$repoId].path;$destination=[IO.Path]::Combine($root,$repoId);[void][IO.Directory]::CreateDirectory($destination);$modes=@{};$paths=[string[]]$closure[$repoId]
            if([string]$owned.kind-ceq'git'){$arguments=[Collections.Generic.List[string]]::new();foreach($value in @('ls-tree','-r','-z','--full-tree',[string]$owned.base_revision,'--')){$arguments.Add($value)};foreach($path in $paths){$arguments.Add($path)};$treeText=ConvertFrom-MorphospaceOwnershipUtf8 (Invoke-MorphospaceOwnershipGit $GitExecutable $source @($arguments.ToArray())).stdout
                foreach($token in $treeText.Split([char]0)){if(-not$token){continue};$match=[regex]::Match($token,'^(?<mode>[0-9]{6}) (?<kind>\S+) (?<oid>[0-9a-f]{40,64})\t(?<path>.+)$');if(-not$match.Success-or$match.Groups['kind'].Value-cne'blob'-or$match.Groups['mode'].Value-notin@('100644','100755')){throw "Unsupported base entry in '$repoId'."};$relative=ConvertTo-MorphospaceProtocolRelativePath $match.Groups['path'].Value;if(-not(Test-MorphospacePathInClosure $relative $paths)){throw "Git returned an out-of-closure base path: $repoId/$relative"};$target=[IO.Path]::GetFullPath([IO.Path]::Combine($destination,$relative));Assert-MorphospaceNoReparseAncestor $destination $target;$blob=(Invoke-MorphospaceOwnershipGit $GitExecutable $source @('cat-file','blob',$match.Groups['oid'].Value)).stdout;$total+=$blob.Length;if($total-gt536870912){throw 'Clean-room input exceeds 512 MiB.'};Write-MorphospaceCleanBlob $target $blob;$modes[$relative]=$match.Groups['mode'].Value}
            }else{if(-not$baselineByRepo.ContainsKey($repoId)){throw "Non-Git clean room lacks claim baseline '$repoId'."};$ownedPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($entry in @($owned.entries)){[void]$ownedPaths.Add([string]$entry.path)};foreach($entry in @($baselineByRepo[$repoId].entries)){if(-not(Test-MorphospacePathInClosure ([string]$entry.path) $paths)-or$ownedPaths.Contains([string]$entry.path)){continue};$relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$entry.path);$target=[IO.Path]::GetFullPath([IO.Path]::Combine($destination,$relative));Assert-MorphospaceNoReparseAncestor $destination $target;if([string]$entry.state-ceq'directory'){if(-not[IO.Directory]::Exists($target)){[void][IO.Directory]::CreateDirectory($target)}}elseif([string]$entry.state-ceq'file'){$live=[IO.Path]::GetFullPath([IO.Path]::Combine($source,$relative));Assert-MorphospaceNoReparseAncestor $source $live;$sourceLeases.Add((Copy-MorphospaceLeasedOverlay $live $target $entry))}}}
            # The claim baseline may contain pre-existing dirty Git bytes.  Those bytes
            # are deliberately not attributed to the current unit, but a validator
            # must still see the exact observed baseline rather than the repository
            # base tree.  Materialize them before the unit-owned overlay so a later
            # owned entry can replace the baseline value deterministically.
            foreach($entry in @($baselineByRepo[$repoId].entries)){
                if(-not(Test-MorphospacePathInClosure ([string]$entry.path) $paths)){continue}
                $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$entry.path)
                $target=[IO.Path]::GetFullPath([IO.Path]::Combine($destination,$relative));Assert-MorphospaceNoReparseAncestor $destination $target
                if([string]$entry.state-ceq'deleted'){
                    if([IO.File]::Exists($target)){[IO.File]::Delete($target)}
                    $modes.Remove($relative)
                    continue
                }
                if([string]$entry.state-ceq'directory'){
                    if(-not[IO.Directory]::Exists($target)){[void][IO.Directory]::CreateDirectory($target)}
                    continue
                }
                if($null-ne$entry.mode-and[string]$entry.mode-notin@('100644','100755')){throw "Baseline overlay has unsupported mode: $repoId/$relative"}
                $live=[IO.Path]::GetFullPath([IO.Path]::Combine($source,$relative));Assert-MorphospaceNoReparseAncestor $source $live
                $sourceLeases.Add((Copy-MorphospaceLeasedOverlay $live $target $entry))
                if($null-ne$entry.mode){$modes[$relative]=[string]$entry.mode}else{[void]$modes.Remove($relative)}
            }
            foreach($entry in @($owned.entries)){if([string]$entry.attribution-notin@('unit','shared')-or-not(Test-MorphospacePathInClosure ([string]$entry.path) $paths)){continue};$relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$entry.path);$target=[IO.Path]::GetFullPath([IO.Path]::Combine($destination,$relative));Assert-MorphospaceNoReparseAncestor $destination $target;if([string]$entry.state-ceq'deleted'){if([IO.File]::Exists($target)){[IO.File]::Delete($target)};$modes.Remove($relative);continue};if([string]$entry.state-ceq'directory'){if(-not[IO.Directory]::Exists($target)){[void][IO.Directory]::CreateDirectory($target)};continue};if($null-ne$entry.mode-and[string]$entry.mode-notin@('100644','100755')){throw "Owned overlay has unsupported mode: $repoId/$relative"};$live=[IO.Path]::GetFullPath([IO.Path]::Combine($source,$relative));Assert-MorphospaceNoReparseAncestor $source $live;$sourceLeases.Add((Copy-MorphospaceLeasedOverlay $live $target $entry));if($null-ne$entry.mode){$modes[$relative]=[string]$entry.mode}else{[void]$modes.Remove($relative)}}
            foreach($requiredPath in $paths){$required=[IO.Path]::GetFullPath([IO.Path]::Combine($destination,$requiredPath));if(-not([IO.File]::Exists($required)-or[IO.Directory]::Exists($required))){throw "Clean-room closure path is absent: $repoId/$requiredPath"}}
            $repoHistory = @($HistoryBlobs | Where-Object { [string]$_.repo_id -ceq $repoId })
            if ($repoHistory.Count -gt 0) {
                foreach ($row in @(Add-MorphospaceCleanHistoryObjects -SourceRepository $source -Destination $destination -HistoryBlobs $repoHistory -GitExecutable $GitExecutable)) { $historyRows.Add($row) | Out-Null }
            }
            $roots[$repoId]=$destination;$modesByRepo[$repoId]=$modes
        }
        $rows=[Collections.Generic.List[object]]::new();foreach($repoId in @($roots.Keys)){foreach($row in @(Get-MorphospaceNoFollowTreeRows ([string]$roots[$repoId]) $repoId $modesByRepo[$repoId])){if([string]$row.path -like '.git/*'){if(@($HistoryBlobs|Where-Object{[string]$_.repo_id-ceq$repoId}).Count-eq0){throw "Clean room contains undeclared Git metadata: $repoId/$([string]$row.path)"};continue};if(-not(Test-MorphospacePathInClosure ([string]$row.path) ([string[]]$closure[$repoId]))){throw "Clean room contains out-of-closure path: $repoId/$([string]$row.path)"};$rows.Add($row)}}
        foreach($historyRow in @($historyRows)){ $rows.Add($historyRow) | Out-Null }
        foreach($lease in $sourceLeases){if([long]$lease.stream.Length-ne[long]$lease.length-or(Get-MorphospaceStreamSha256 $lease.stream)-cne[string]$lease.sha256){throw "Owned overlay changed before clean-room finalization: $([string]$lease.path)"}};$sorted=@($rows.ToArray());[Array]::Sort($sorted,[Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare("$([string]$left.repo_id)/$([string]$left.path)","$([string]$right.repo_id)/$([string]$right.path)")})
        return [pscustomobject]@{root=$root;parent=$parent;guard=$guard;repositories=$roots;closure=$closure;modes_by_repository=$modesByRepo;history_rows=@($historyRows.ToArray());fingerprint_sha256=(Get-MorphospaceOrdinalFingerprint $sorted)}
    }catch{try{Remove-MorphospaceCleanRoom ([pscustomobject]@{root=$root;parent=$parent;guard=$guard})}catch{};throw}finally{foreach($lease in $sourceLeases){$lease.stream.Dispose()}}
}

function Get-MorphospaceCleanRoomFingerprint {
    param([Parameter(Mandatory=$true)][object]$CleanRoom)
    $root=[IO.Path]::GetFullPath([string]$CleanRoom.root)
    if(-not$script:CleanRoomGuards.ContainsKey($root)-or[string]$script:CleanRoomGuards[$root]-cne[string]$CleanRoom.guard){throw 'Clean-room fingerprint authority is missing or forged.'}
    $rows=[Collections.Generic.List[object]]::new()
    foreach($repoId in @($CleanRoom.repositories.Keys)){
        $repoRoot=[string]$CleanRoom.repositories[$repoId]
        $modes=@{}
        if($null-ne$CleanRoom.modes_by_repository-and$null-ne$CleanRoom.modes_by_repository[$repoId]){$modes=$CleanRoom.modes_by_repository[$repoId]}
        foreach($row in @(Get-MorphospaceNoFollowTreeRows $repoRoot ([string]$repoId) $modes)){
            if([string]$row.path -like '.git/*'){
                if(@($CleanRoom.history_rows|Where-Object{[string]$_.repo_id-ceq$repoId}).Count-eq0){throw "Clean room contains undeclared Git metadata: $repoId/$([string]$row.path)"}
                continue
            }
            if(-not(Test-MorphospacePathInClosure ([string]$row.path) ([string[]]$CleanRoom.closure[$repoId]))){throw "Clean room contains out-of-closure path: $repoId/$([string]$row.path)"}
            $rows.Add($row)
        }
    }
    foreach($historyRow in @($CleanRoom.history_rows)){ $rows.Add($historyRow) | Out-Null }
    $sorted=@($rows.ToArray());[Array]::Sort($sorted,[Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare("$([string]$left.repo_id)/$([string]$left.path)","$([string]$right.repo_id)/$([string]$right.path)")})
    return Get-MorphospaceOrdinalFingerprint $sorted
}

function Remove-MorphospaceNoFollowTree {
    param([string]$Root)
    $stack=[Collections.Generic.Stack[object]]::new();$stack.Push([pscustomobject]@{path=$Root;visited=$false})
    while($stack.Count-gt0){$item=$stack.Pop();$path=[string]$item.path;if(-not([IO.File]::Exists($path)-or[IO.Directory]::Exists($path))){continue};$attributes=[IO.File]::GetAttributes($path);$directory=($attributes-band[IO.FileAttributes]::Directory)-ne0;$reparse=($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0;if($reparse){if($directory){[IO.Directory]::Delete($path)}else{[IO.File]::Delete($path)};continue};if(-not$directory){[IO.File]::SetAttributes($path,[IO.FileAttributes]::Normal);[IO.File]::Delete($path);continue};if([bool]$item.visited){[IO.Directory]::Delete($path);continue};$stack.Push([pscustomobject]@{path=$path;visited=$true});$children=@([IO.Directory]::GetFileSystemEntries($path));for($index=0;$index-lt$children.Length;$index++){$stack.Push([pscustomobject]@{path=$children[$index];visited=$false})}}
}

function Remove-MorphospaceCleanRoom {
    param([object]$CleanRoom)
    $root=[IO.Path]::GetFullPath([string]$CleanRoom.root);$parent=[IO.Path]::GetFullPath([string]$CleanRoom.parent).TrimEnd('\','/');$actualParent=[IO.Path]::GetDirectoryName($root).TrimEnd('\','/');if(-not$actualParent.Equals($parent,[StringComparison]::OrdinalIgnoreCase)-or-not$script:CleanRoomGuards.ContainsKey($root)-or[string]$script:CleanRoomGuards[$root]-cne[string]$CleanRoom.guard){throw 'Clean-room cleanup authority is missing or forged.'};$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');if(-not[IO.Path]::GetDirectoryName($parent).TrimEnd('\','/').Equals($temp,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($parent)-cne'rusty-morphospace-cleanrooms'){throw 'Clean-room cleanup parent is outside the owned temp root.'};Assert-MorphospaceNoReparseAncestor $temp $parent;Assert-MorphospaceNoReparseAncestor $parent $root;if([IO.Directory]::Exists($root)){Remove-MorphospaceNoFollowTree $root};[void]$script:CleanRoomGuards.Remove($root)
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Get-MorphospaceFixedRepositoryMap,Test-MorphospaceOwnerValidatorRegistry,Get-MorphospaceRegistrySelection,Test-MorphospaceClaimBaseline,Test-MorphospaceUnitOwnership,Get-MorphospaceAuthorityObservation,Get-MorphospaceAutomationOutputContract,Test-MorphospaceAutomationOutputSet,ConvertTo-MorphospaceComparableRepositoryObservation,New-MorphospaceCleanRoom,Get-MorphospaceCleanRoomFingerprint,Remove-MorphospaceCleanRoom
