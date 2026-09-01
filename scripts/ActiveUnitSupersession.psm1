Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force

function Copy-ActiveSupersessionValue {
    param([object]$Value)
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -DateKind String
}

function Get-ActiveSupersessionRelativePath {
    param([string]$WorkspaceRoot,[string]$Path,[switch]$RequireLeaf)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
    $absolute=if([IO.Path]::IsPathRooted($Path)){[IO.Path]::GetFullPath($Path)}else{[IO.Path]::GetFullPath((Join-Path $workspace $Path))}
    $prefix=$workspace+[IO.Path]::DirectorySeparatorChar
    if(-not$absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Active-unit supersession evidence must stay inside the project workspace.'}
    if($RequireLeaf-and-not[IO.File]::Exists($absolute)){throw "Active-unit supersession evidence is missing: $absolute"}
    $relative=$absolute.Substring($prefix.Length).Replace('\','/')
    [void](ConvertTo-MorphospaceProtocolRelativePath $relative)
    [pscustomobject]@{absolute=$absolute;relative=$relative}
}

function ConvertTo-ActiveSupersessionSourcePath {
    param([string]$Path)
    $value=$Path.Replace('\','/').Trim()
    if(-not$value-or[IO.Path]::IsPathRooted($value)-or$value-cmatch'(^|/)\.\.(/|$)'-or$value-cmatch'(^|/)\.(/|$)'-or$value.Contains('//',[StringComparison]::Ordinal)){
        throw "Active-unit supersession source path is not canonical: '$Path'."
    }
    return $value
}

function Test-ActiveSupersessionPathAllowed {
    param([string]$Path,[object[]]$AllowedPaths)
    $normalized=ConvertTo-ActiveSupersessionSourcePath $Path
    foreach($candidate in @($AllowedPaths)){
        $allowed=(ConvertTo-ActiveSupersessionSourcePath ([string]$candidate)).TrimEnd('/')
        if($normalized.Equals($allowed,[StringComparison]::Ordinal)-or$normalized.StartsWith($allowed+'/',[StringComparison]::Ordinal)){return $true}
    }
    return $false
}

function Get-ActiveSupersessionStatusPaths {
    param([string]$StatusLine)
    if($StatusLine.Length-lt4){throw 'Active-unit supersession observed malformed Git status output.'}
    $value=$StatusLine.Substring(3).Trim()
    if($value.StartsWith('"',[StringComparison]::Ordinal)-or$value.EndsWith('"',[StringComparison]::Ordinal)){
        throw 'Active-unit supersession requires unquoted portable Git status paths.'
    }
    $source=$null;$target=$value
    if($value.Contains(' -> ',[StringComparison]::Ordinal)){
        $parts=@($value -split ' -> ')
        if($parts.Count-ne2){throw 'Active-unit supersession observed ambiguous Git rename status.'}
        $source=ConvertTo-ActiveSupersessionSourcePath $parts[0]
        $target=$parts[1]
    }
    [pscustomobject]@{source_path=$source;path=(ConvertTo-ActiveSupersessionSourcePath $target)}
}

function Get-ActiveSupersessionDirtyFingerprint {
    param([string[]]$StatusLines)
    $ordered=@($StatusLines|Sort-Object -CaseSensitive)
    Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($ordered -join [char]10)))
}

function Get-ActiveSupersessionEventsSnapshot {
    param([string]$Path)
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($bytes.Length-gt67108864){throw 'Active-unit supersession event ledger exceeds the bounded protocol limit.'}
    if($bytes.Length-gt0-and$bytes[$bytes.Length-1]-ne0x0a){throw 'Active-unit supersession event ledger must end with LF.'}
    if($bytes-contains0x0d){throw 'Active-unit supersession event ledger must be LF-only.'}
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)}catch{throw 'Active-unit supersession event ledger is not strict UTF-8.'}
    $events=@()
    foreach($line in @($text -split [char]10|Where-Object{$_})){
        try{$event=$line|ConvertFrom-Json -DateKind String}catch{throw "Active-unit supersession event ledger contains malformed JSON: $($_.Exception.Message)"}
        $events+=,$event
    }
    $tail=if($events.Count){[string]$events[-1].event_id}else{$null}
    [pscustomobject]@{bytes=$bytes;sha256=Get-MorphospaceSha256Bytes $bytes;length=[int64]$bytes.Length;tail_id=$tail;events=@($events)}
}

function Get-ActiveSupersessionUnitBinding {
    param([string]$WorkspaceRoot,[string]$UnitId,[switch]$RequireIterationUnitSchema)
    $matches=@()
    foreach($path in @([IO.Directory]::EnumerateFiles((Join-Path $WorkspaceRoot 'iteration-units'),'*.json',[IO.SearchOption]::TopDirectoryOnly)|Sort-Object)){
        $document=Read-MorphospaceProtocolJson $path
        if([string]$document.unit_id-ceq$UnitId){
            if($RequireIterationUnitSchema){
                $schemaPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\iteration-unit.schema.json'
                $schemaValid=$false
                try{$schemaValid=Test-Json -Json (Get-Content -Raw -LiteralPath $path) -SchemaFile $schemaPath -ErrorAction SilentlyContinue}catch{$schemaValid=$false}
                if(-not$schemaValid){throw "Active-unit supersession live unit '$UnitId' does not satisfy the repository-owned iteration-unit schema."}
            }
            $relative=[IO.Path]::GetRelativePath($WorkspaceRoot,$path).Replace('\','/')
            $matches+=,[pscustomobject][ordered]@{
                unit_id=$UnitId
                path=$relative
                raw_sha256=Get-MorphospaceFileSha256 $path
                canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $document
                status=[string]$document.status
                document=$document
                absolute=$path
            }
        }
    }
    if($matches.Count-ne1){throw "Active-unit supersession requires exactly one unit document for '$UnitId'."}
    return $matches[0]
}

function Assert-ActiveSupersessionNoSourceWidening {
    param([object]$OldUnit,[object]$ReplacementUnit)
    $oldMap=@{}
    foreach($repo in @($OldUnit.allowed_repositories)){
        $id=[string]$repo.repo_id
        if($oldMap.ContainsKey($id)){throw "Active unit repeats allowed repository '$id'."}
        $oldMap[$id]=@($repo.allowed_paths)
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($repo in @($ReplacementUnit.allowed_repositories)){
        $id=[string]$repo.repo_id
        if(-not$seen.Add($id)){throw "Replacement unit repeats allowed repository '$id'."}
        if(-not$oldMap.ContainsKey($id)){throw "Replacement unit widens source authority to repository '$id'."}
        foreach($path in @($repo.allowed_paths)){
            if(-not(Test-ActiveSupersessionPathAllowed -Path ([string]$path) -AllowedPaths @($oldMap[$id]))){
                throw "Replacement unit widens source authority at '${id}:$path'."
            }
        }
    }
}

function Get-ActiveSupersessionCompanionBindings {
    param([string]$WorkspaceRoot,[object[]]$RequestedCompanions,[object]$Project,[object]$State,[string]$OldUnitId,[string]$ReplacementUnitId)
    $bindings=@();$seenIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$seenPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$previous=$null
    foreach($request in @($RequestedCompanions)){
        $id=[string]$request.unit_id
        if(-not$id-or$id-ceq$OldUnitId-or$id-ceq$ReplacementUnitId-or-not$seenIds.Add($id)){throw 'Active-unit supersession companion identities are missing, repeated, or reuse a lifecycle endpoint.'}
        if($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,$id)-ge0){throw 'Active-unit supersession companion identities are not in canonical ordinal order.'}
        $previous=$id
        $binding=Get-ActiveSupersessionUnitBinding $WorkspaceRoot $id -RequireIterationUnitSchema
        if(-not$seenPaths.Add([string]$binding.path)){throw 'Active-unit supersession companion paths are not unique.'}
        if([string]$binding.status-cne'proposed'){throw "Active-unit supersession companion '$id' is not proposed."}
        if([string]$binding.document.project_id-cne[string]$Project.project_id-or[string]$binding.document.project_id-cne[string]$State.project_id){throw "Active-unit supersession companion '$id' has a different project identity."}
        $actual=[pscustomobject][ordered]@{unit_id=$id;path=[string]$binding.path;raw_sha256=[string]$binding.raw_sha256;canonical_sha256=[string]$binding.canonical_sha256;status='proposed';lifecycle_effect='preserve-proposed'}
        if((Get-MorphospaceCanonicalJsonSha256 $request)-cne(Get-MorphospaceCanonicalJsonSha256 $actual)){throw "Active-unit supersession companion '$id' binding drifted."}
        $bindings+=,[pscustomobject]@{unit_id=$id;role='companion-overlay-only';document=$binding.document;binding=$binding;request=$actual}
    }
    return @($bindings)
}

function Test-ActiveSupersessionScopeOverlap {
    param([string]$Left,[string]$Right)
    $leftPath=(ConvertTo-ActiveSupersessionSourcePath $Left).TrimEnd('/')
    $rightPath=(ConvertTo-ActiveSupersessionSourcePath $Right).TrimEnd('/')
    return $leftPath.Equals($rightPath,[StringComparison]::Ordinal)-or$leftPath.StartsWith($rightPath+'/',[StringComparison]::Ordinal)-or$rightPath.StartsWith($leftPath+'/',[StringComparison]::Ordinal)
}

function Get-ActiveSupersessionPathOwner {
    param([string]$Path,[object[]]$OwnershipScopes,[string]$RepositoryId)
    $owners=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($scope in @($OwnershipScopes)){
        if(Test-ActiveSupersessionPathAllowed -Path $Path -AllowedPaths @($scope.allowed_paths)){[void]$owners.Add([string]$scope.unit_id)}
    }
    $ordered=@($owners|Sort-Object -CaseSensitive)
    if($ordered.Count-eq0){throw "Active-unit supersession rejects unowned overlay '${RepositoryId}:$Path'."}
    if($ordered.Count-ne1){throw "Active-unit supersession rejects ambiguously owned overlay '${RepositoryId}:$Path'."}
    return [string]$ordered[0]
}

function Get-ActiveSupersessionRepositoryMap {
    param([string]$Path)
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $Path) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\repository-map.schema.json'))){
        throw 'Active-unit supersession repository map is invalid.'
    }
    $document=Read-MorphospaceProtocolJson $Path
    $map=@{}
    foreach($entry in @($document.repositories)){
        $id=[string]$entry.repo_id
        if($map.ContainsKey($id)){throw "Active-unit supersession repository map repeats '$id'."}
        $map[$id]=$entry
    }
    [pscustomobject]@{document=$document;map=$map;sha256=Get-MorphospaceFileSha256 $Path}
}

function Get-ActiveSupersessionRepositoryObservation {
    param([object]$OldUnit,[object[]]$OwnershipUnits,[hashtable]$RepositoryMap)
    $oldRepositories=@{};$rows=@();$companionDirt=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($repo in @($OldUnit.allowed_repositories)){
        $id=[string]$repo.repo_id
        if(-not$id-or$oldRepositories.ContainsKey($id)){throw "Active unit repeats allowed repository '$id'."}
        $oldRepositories[$id]=$repo
    }
    foreach($unit in @($OwnershipUnits)){Assert-ActiveSupersessionNoSourceWidening $OldUnit $unit.document}
    foreach($unit in @($OwnershipUnits)){
        foreach($repo in @($unit.document.allowed_repositories)){
            if(-not$oldRepositories.ContainsKey([string]$repo.repo_id)){throw "Successor overlay ownership widens source authority to repository '$([string]$repo.repo_id)'."}
        }
    }
    $previous=$null
    foreach($id in @($oldRepositories.Keys|Sort-Object -CaseSensitive)){
        if($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,$id)-ge0){throw 'Active-unit repository scope is not uniquely orderable.'}
        $previous=$id
        if(-not$RepositoryMap.ContainsKey($id)){throw "Active-unit supersession source repository '$id' is unmapped."}
        $state=Get-MorphospaceRepositoryState -RepoId $id -Path ([string]$RepositoryMap[$id].path)
        if(-not[bool]$state.available-or-not[bool]$state.is_git-or[string]$state.head-cnotmatch'^[0-9a-f]{40}$'-or[string]$state.tree-cnotmatch'^[0-9a-f]{40}$'){
            throw "Active-unit supersession source repository '$id' is unavailable or not an exact Git materialization."
        }
        $ownershipScopes=@()
        foreach($unit in @($OwnershipUnits|Sort-Object -Property @{Expression={[string]$_.unit_id}} -CaseSensitive)){
            $matching=@($unit.document.allowed_repositories|Where-Object{[string]$_.repo_id-ceq$id})
            if($matching.Count-eq0){continue}
            if($matching.Count-ne1){throw "Successor unit '$([string]$unit.unit_id)' repeats repository '$id'."}
            $allowed=@($matching[0].allowed_paths|ForEach-Object{ConvertTo-ActiveSupersessionSourcePath ([string]$_)}|Sort-Object -CaseSensitive)
            if($allowed.Count-ne@($matching[0].allowed_paths).Count-or$allowed.Count-eq0){throw "Successor repository '$id' has invalid allowed paths."}
            for($index=1;$index-lt$allowed.Count;$index++){if([StringComparer]::Ordinal.Compare($allowed[$index-1],$allowed[$index])-ge0){throw "Successor repository '$id' allowed paths are not unique."}}
            $ownershipScopes+=,[pscustomobject][ordered]@{unit_id=[string]$unit.unit_id;role=[string]$unit.role;allowed_paths=$allowed}
        }
        for($left=0;$left-lt$ownershipScopes.Count;$left++){
            for($right=$left+1;$right-lt$ownershipScopes.Count;$right++){
                foreach($leftPath in @($ownershipScopes[$left].allowed_paths)){foreach($rightPath in @($ownershipScopes[$right].allowed_paths)){
                    if(Test-ActiveSupersessionScopeOverlap $leftPath $rightPath){throw "Active-unit supersession ownership scopes overlap at repository '$id': '$leftPath' and '$rightPath'."}
                }}
            }
        }
        $allowedSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($scope in $ownershipScopes){foreach($path in @($scope.allowed_paths)){[void]$allowedSet.Add([string]$path)}}
        $allowed=@($allowedSet|Sort-Object -CaseSensitive)
        $statusLines=@($state.status_porcelain|ForEach-Object{[string]$_}|Sort-Object -CaseSensitive)
        if($ownershipScopes.Count-eq0-and$statusLines.Count){throw "Active-unit supersession omitted repository '$id' is not clean."}
        $overlay=@()
        foreach($line in $statusLines){
            $paths=Get-ActiveSupersessionStatusPaths $line
            $pathOwners=@();foreach($candidate in @(@($paths.source_path,$paths.path)|Where-Object{$_})){$pathOwners+=,(Get-ActiveSupersessionPathOwner -Path ([string]$candidate) -OwnershipScopes $ownershipScopes -RepositoryId $id)}
            $ownerSet=@($pathOwners|Sort-Object -CaseSensitive -Unique)
            if($ownerSet.Count-ne1){throw "Active-unit supersession rejects a rename whose endpoints have different owners in repository '$id'."}
            $owner=[string]$ownerSet[0]
            $ownerScope=@($ownershipScopes|Where-Object{[string]$_.unit_id-ceq$owner})[0]
            if([string]$ownerScope.role-ceq'companion-overlay-only'){[void]$companionDirt.Add($owner)}
            $absolute=Join-Path ([string]$state.path) ([string]$paths.path).Replace('/',[IO.Path]::DirectorySeparatorChar)
            $present=[IO.File]::Exists($absolute)
            if(-not$present-and[IO.Directory]::Exists($absolute)){throw "Active-unit supersession overlay path is not a file: '${id}:$($paths.path)'."}
            $overlay+=,[pscustomobject][ordered]@{
                status_line=$line
                path=[string]$paths.path
                source_path=$paths.source_path
                owner_unit_id=$owner
                present=$present
                sha256=$(if($present){Get-MorphospaceFileSha256 $absolute}else{$null})
            }
        }
        $rows+=,[pscustomobject][ordered]@{
            repo_id=$id
            head=[string]$state.head
            tree=[string]$state.tree
            branch=$(if($null-eq$state.branch){$null}else{[string]$state.branch})
            dirty_fingerprint=Get-ActiveSupersessionDirtyFingerprint @($state.status_porcelain)
            scope_disposition=$(if($ownershipScopes.Count){'owned'}else{'omitted-clean'})
            ownership_scopes=@($ownershipScopes)
            allowed_paths=$allowed
            overlay=@($overlay)
        }
    }
    foreach($unit in @($OwnershipUnits|Where-Object{[string]$_.role-ceq'companion-overlay-only'})){if(-not$companionDirt.Contains([string]$unit.unit_id)){throw "Active-unit supersession companion '$([string]$unit.unit_id)' owns no dirty overlay path."}}
    return @($rows)
}

function Get-ActiveSupersessionBinding {
    param([string]$WorkspaceRoot,[string]$ReplacementUnitId,[string]$RepoMapPath,[object]$Request)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    $projectPath=Join-Path $workspace 'project.spec.json'
    $statePath=Join-Path $workspace 'workspace.state.json'
    $eventsPath=Join-Path $workspace 'iteration-events.jsonl'
    $project=Read-MorphospaceProtocolJson $projectPath
    $state=Read-MorphospaceProtocolJson $statePath
    $events=Get-ActiveSupersessionEventsSnapshot $eventsPath
    $oldId=[string]$state.current_unit
    if(-not$oldId){throw 'SupersedeActive requires one exact current active unit.'}
    if($oldId-ceq$ReplacementUnitId){throw 'SupersedeActive old and replacement unit identities must differ.'}
    $old=Get-ActiveSupersessionUnitBinding $workspace $oldId
    $replacement=Get-ActiveSupersessionUnitBinding $workspace $ReplacementUnitId -RequireIterationUnitSchema
    if([string]$old.status-cne'active'){throw "SupersedeActive requires current unit '$oldId' to be active."}
    if([string]$replacement.status-cne'proposed'){throw "SupersedeActive requires replacement '$ReplacementUnitId' to be proposed."}
    foreach($unit in @($old.document,$replacement.document)){
        if([string]$unit.project_id-cne[string]$project.project_id-or[string]$unit.project_id-cne[string]$state.project_id){throw 'SupersedeActive project identities do not agree.'}
    }
    if($null-ne$state.next_ready_unit-and[string]$state.next_ready_unit-cne$ReplacementUnitId){throw 'SupersedeActive rejects a different next-ready unit.'}
    if($null-ne$state.normal_validation_selection){throw 'SupersedeActive refuses to orphan a normal-validation selector binding.'}
    Assert-ActiveSupersessionNoSourceWidening $old.document $replacement.document
    $companions=Get-ActiveSupersessionCompanionBindings $workspace @($Request.companion_units) $project $state $oldId $ReplacementUnitId
    $ownershipUnits=@([pscustomobject]@{unit_id=$ReplacementUnitId;role='replacement';document=$replacement.document;binding=$replacement})+@($companions)
    $repoMap=Get-ActiveSupersessionRepositoryMap $RepoMapPath
    $repositories=Get-ActiveSupersessionRepositoryObservation $old.document $ownershipUnits $repoMap.map
    $expected=[pscustomobject][ordered]@{
        project_raw_sha256=Get-MorphospaceFileSha256 $projectPath
        project_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $project
        state_raw_sha256=Get-MorphospaceFileSha256 $statePath
        state_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $state
        events_sha256=[string]$events.sha256
        events_length=[int64]$events.length
        event_tail_id=$events.tail_id
        repository_map_sha256=[string]$repoMap.sha256
    }
    $oldRequest=[pscustomobject][ordered]@{unit_id=$old.unit_id;path=$old.path;raw_sha256=$old.raw_sha256;canonical_sha256=$old.canonical_sha256;status='active'}
    $replacementRequest=[pscustomobject][ordered]@{unit_id=$replacement.unit_id;path=$replacement.path;raw_sha256=$replacement.raw_sha256;canonical_sha256=$replacement.canonical_sha256;status='proposed'}
    if([string]$Request.project_id-cne[string]$project.project_id-or[string]$Request.supersession_id-cne(Get-MorphospaceSupersessionEventId -OldUnitId $oldId -ReplacementUnitId $ReplacementUnitId)){
        throw 'Active-unit supersession request identity does not match the exact current endpoints.'
    }
    foreach($comparison in @(
        [pscustomobject]@{name='old unit';expected=$Request.old_unit;actual=$oldRequest},
        [pscustomobject]@{name='replacement unit';expected=$Request.replacement_unit;actual=$replacementRequest},
        [pscustomobject]@{name='companion units';expected=@($Request.companion_units);actual=@($companions|ForEach-Object{$_.request})},
        [pscustomobject]@{name='project/state/ledger/repository-map';expected=$Request.expected;actual=$expected},
        [pscustomobject]@{name='repository and overlay';expected=@($Request.repositories);actual=@($repositories)}
    )){
        if((Get-MorphospaceCanonicalJsonSha256 $comparison.expected)-cne(Get-MorphospaceCanonicalJsonSha256 $comparison.actual)){
            throw "Active-unit supersession $([string]$comparison.name) binding drifted."
        }
    }
    [pscustomobject]@{project=$project;state=$state;events=$events;old=$old;replacement=$replacement;companions=@($companions);ownership_units=@($ownershipUnits);repositories=@($repositories);expected=$expected}
}

function New-ActiveSupersessionResult {
    param([object]$Request,[string]$RequestPath,[string]$RequestSha256,[string]$Timestamp,[bool]$Executed,[string]$EventId)
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id=[string]$Request.project_id
        unit_id=[string]$Request.replacement_unit.unit_id
        action='SupersedeActive'
        timestamp=$Timestamp
        executed=$Executed
        transition='active-superseded-by-proposed-to-active'
        status_before='proposed'
        status_after=$(if($Executed){'active'}else{'proposed'})
        current_unit_before=[string]$Request.old_unit.unit_id
        current_unit_after=$(if($Executed){[string]$Request.replacement_unit.unit_id}else{[string]$Request.old_unit.unit_id})
        preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt=[pscustomobject][ordered]@{path=$RequestPath;sha256=$RequestSha256}
        event_id=$(if($Executed){$EventId}else{$null})
    }
}

function Assert-ActiveSupersessionPreservedBindings {
    param([string]$Workspace,[object]$Request,[object]$Project,[object]$State)
    $old=Get-ActiveSupersessionUnitBinding $Workspace ([string]$Request.old_unit.unit_id)
    $oldActual=[pscustomobject][ordered]@{unit_id=$old.unit_id;path=$old.path;raw_sha256=$old.raw_sha256;canonical_sha256=$old.canonical_sha256;status='active'}
    if((Get-MorphospaceCanonicalJsonSha256 $oldActual)-cne(Get-MorphospaceCanonicalJsonSha256 $Request.old_unit)){throw 'Active-unit supersession preserved old unit binding drifted.'}
    $companions=Get-ActiveSupersessionCompanionBindings $Workspace @($Request.companion_units) $Project $State ([string]$Request.old_unit.unit_id) ([string]$Request.replacement_unit.unit_id)
    return @($companions)
}

function Get-ActiveSupersessionRecoveryIntent {
    param([string]$Workspace,[string]$TransactionId,[object]$Request,[string]$RequestPath,[string]$RequestSha256,[string]$OutPath)
    $intentPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$TransactionId.intent.json" -RequireLeaf
    $intent=Read-MorphospaceProtocolJson $intentPath
    Assert-MorphospaceExactPropertySet $intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','supersession','status') @() 'Active-unit supersession recovery intent'
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v2'-or[string]$intent.transaction_id-cne$TransactionId-or[string]$intent.status-cne'prepared'){throw 'Active-unit supersession recovery intent identity is invalid.'}
    if([string]$intent.state.path-cne'workspace.state.json'-or[string]$intent.unit.path-cne[string]$Request.replacement_unit.path-or[string]$intent.events.path-cne'iteration-events.jsonl'){throw 'Active-unit supersession recovery intent paths are invalid.'}
    if([string]$intent.pre.state.sha256-cne[string]$Request.expected.state_canonical_sha256-or[string]$intent.pre.unit.sha256-cne[string]$Request.replacement_unit.canonical_sha256){throw 'Active-unit supersession recovery intent preimage differs from the reviewed request.'}
    foreach($check in @(
        [pscustomobject]@{expected=[string]$Request.expected.state_canonical_sha256;actual=[string]$intent.expected.state_sha256},
        [pscustomobject]@{expected=[string]$Request.replacement_unit.canonical_sha256;actual=[string]$intent.expected.unit_sha256},
        [pscustomobject]@{expected=[string]$Request.expected.event_tail_id;actual=[string]$intent.expected.event_tail_id},
        [pscustomobject]@{expected=[string]$Request.expected.events_sha256;actual=[string]$intent.expected.events_sha256},
        [pscustomobject]@{expected=[string]$Request.expected.events_length;actual=[string]$intent.expected.events_length}
    )){if($check.expected-cne$check.actual){throw 'Active-unit supersession recovery intent expected preimage differs from the reviewed request.'}}
    $supersession=$intent.supersession
    if([string]$supersession.old_unit_id-cne[string]$Request.old_unit.unit_id-or[string]$supersession.new_unit_id-cne[string]$Request.replacement_unit.unit_id-or[string]$supersession.target_unit_path-cne[string]$Request.replacement_unit.path-or[string]$supersession.pre_state.path-cne'workspace.state.json'-or[string]$supersession.pre_state.sha256-cne[string]$Request.expected.state_canonical_sha256-or[string]$supersession.old_unit.path-cne[string]$Request.old_unit.path-or[string]$supersession.old_unit.sha256-cne[string]$Request.old_unit.canonical_sha256){throw 'Active-unit supersession recovery intent endpoint binding differs from the reviewed request.'}
    if((Get-MorphospaceCanonicalJsonSha256 $supersession.pre_state.document)-cne[string]$Request.expected.state_canonical_sha256-or(Get-MorphospaceCanonicalJsonSha256 $supersession.old_unit.document)-cne[string]$Request.old_unit.canonical_sha256){throw 'Active-unit supersession recovery intent embeds damaged predecessor documents.'}
    $preReplacement=Copy-ActiveSupersessionValue $intent.target.unit.document;$preReplacement.status='proposed'
    if([string]$intent.target.unit.document.unit_id-cne[string]$Request.replacement_unit.unit_id-or[string]$intent.target.unit.document.project_id-cne[string]$Request.project_id-or[string]$intent.target.unit.document.status-cne'active'-or(Get-MorphospaceCanonicalJsonSha256 $preReplacement)-cne[string]$Request.replacement_unit.canonical_sha256-or(Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document)-cne[string]$intent.target.unit.sha256){throw 'Active-unit supersession recovery target unit is not the exact proposed-to-active projection.'}
    $expectedState=Copy-ActiveSupersessionValue $supersession.pre_state.document;$expectedState.current_unit=[string]$Request.replacement_unit.unit_id;$expectedState.next_ready_unit=$null;$expectedState.last_event_id=[string]$Request.supersession_id
    if((Get-MorphospaceCanonicalJsonSha256 $expectedState)-cne[string]$intent.target.state.sha256-or(Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document)-cne[string]$intent.target.state.sha256){throw 'Active-unit supersession recovery target state is not the exact successor projection.'}
    $event=$intent.event
    if([string]$event.event_id-cne[string]$Request.supersession_id-or[string]$event.project_id-cne[string]$Request.project_id-or[string]$event.unit_id-cne[string]$Request.old_unit.unit_id-or[string]$event.event_type-cne'state-transition'-or@($event.receipts).Count-ne1-or[string]$event.receipts[0]-cne$OutPath){throw 'Active-unit supersession recovery event differs from the reviewed endpoints.'}
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$event.timestamp))
    if(@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].path-cne$OutPath){throw 'Active-unit supersession recovery intent does not own exactly the requested receipt artifact.'}
    try{$receiptBytes=[Convert]::FromBase64String([string]$intent.artifacts[0].bytes_base64)}catch{throw 'Active-unit supersession recovery receipt payload is not valid base64.'}
    if((Get-MorphospaceSha256Bytes $receiptBytes)-cne[string]$intent.artifacts[0].sha256){throw 'Active-unit supersession recovery receipt payload hash is invalid.'}
    $receipt=ConvertFrom-MorphospaceProtocolJsonBytes $receiptBytes
    $expectedReceipt=New-ActiveSupersessionResult $Request $RequestPath $RequestSha256 ([string]$event.timestamp) $true ([string]$Request.supersession_id)
    if((Get-MorphospaceCanonicalJsonSha256 $receipt)-cne(Get-MorphospaceCanonicalJsonSha256 $expectedReceipt)){throw 'Active-unit supersession recovery receipt differs from the reviewed request.'}
    [pscustomobject]@{intent=$intent;receipt=$receipt;receipt_bytes=$receiptBytes}
}

function Assert-ActiveSupersessionRecoveryRepositoryBinding {
    param([string]$Workspace,[object]$Request,[string]$RepoMapPath,[object[]]$Companions)
    if((Get-MorphospaceFileSha256 ([IO.Path]::GetFullPath($RepoMapPath)))-cne[string]$Request.expected.repository_map_sha256){throw 'Active-unit supersession recovery repository-map bytes drifted.'}
    $repoMap=Get-ActiveSupersessionRepositoryMap $RepoMapPath
    if([string]$repoMap.sha256-cne[string]$Request.expected.repository_map_sha256){throw 'Active-unit supersession recovery repository-map identity drifted.'}
    $old=Get-ActiveSupersessionUnitBinding $Workspace ([string]$Request.old_unit.unit_id);$replacement=Get-ActiveSupersessionUnitBinding $Workspace ([string]$Request.replacement_unit.unit_id) -RequireIterationUnitSchema
    $ownershipUnits=@([pscustomobject]@{unit_id=[string]$replacement.unit_id;role='replacement';document=$replacement.document;binding=$replacement})+@($Companions)
    $repositories=Get-ActiveSupersessionRepositoryObservation $old.document $ownershipUnits $repoMap.map
    if((Get-MorphospaceCanonicalJsonSha256 @($repositories))-cne(Get-MorphospaceCanonicalJsonSha256 @($Request.repositories))){throw 'Active-unit supersession recovery repository and overlay binding drifted.'}
}

function Invoke-ActiveSupersessionExistingIntent {
    param([string]$Workspace,[string]$TransactionId,[object]$Request,[string]$RequestPath,[string]$RequestSha256,[string]$OutPath,[string]$RepoMapPath,[switch]$Execute)
    $recovery=Get-ActiveSupersessionRecoveryIntent $Workspace $TransactionId $Request $RequestPath $RequestSha256 $OutPath
    $completionPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$TransactionId.completion.json"
    if([IO.File]::Exists($completionPath)){
        [void](Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $TransactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$Request.replacement_unit.path) -ExpectedEventsPath 'iteration-events.jsonl')
        $outAbsolute=Resolve-MorphospaceWorkspacePath $Workspace $OutPath -RequireLeaf
        if((Get-MorphospaceFileSha256 $outAbsolute)-cne[string]$recovery.intent.artifacts[0].sha256){throw 'Active-unit supersession committed receipt bytes differ from the exact intent.'}
        return $recovery.receipt
    }
    if(-not$Execute){throw 'Active-unit supersession has an outstanding exact intent; Execute is required to repair it.'}
    $project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'project.spec.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'workspace.state.json' -RequireLeaf)
    if([string]$project.project_id-cne[string]$Request.project_id-or[string]$state.project_id-cne[string]$Request.project_id){throw 'Active-unit supersession recovery project identity drifted.'}
    $companions=@(Assert-ActiveSupersessionPreservedBindings $Workspace $Request $project $state)
    $replacement=Get-ActiveSupersessionUnitBinding $Workspace ([string]$Request.replacement_unit.unit_id) -RequireIterationUnitSchema
    if([string]$replacement.raw_sha256-cne[string]$Request.replacement_unit.raw_sha256-and[string]$replacement.canonical_sha256-cne[string]$recovery.intent.target.unit.sha256){throw 'Active-unit supersession recovery replacement bytes are neither the exact preimage nor target.'}
    Assert-ActiveSupersessionRecoveryRepositoryBinding $Workspace $Request $RepoMapPath $companions
    [void](Assert-ActiveSupersessionPreservedBindings $Workspace $Request $project $state)
    Assert-ActiveSupersessionRecoveryRepositoryBinding $Workspace $Request $RepoMapPath $companions
    [void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $Workspace -TransactionId $TransactionId -Repair)
    [void](Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $TransactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$Request.replacement_unit.path) -ExpectedEventsPath 'iteration-events.jsonl')
    $outAbsolute=Resolve-MorphospaceWorkspacePath $Workspace $OutPath -RequireLeaf
    if((Get-MorphospaceFileSha256 $outAbsolute)-cne[string]$recovery.intent.artifacts[0].sha256){throw 'Active-unit supersession committed receipt bytes differ from the exact intent.'}
    $postProject=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'project.spec.json' -RequireLeaf);$postState=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace 'workspace.state.json' -RequireLeaf)
    [void](Assert-ActiveSupersessionPreservedBindings $Workspace $Request $postProject $postState)
    return $recovery.receipt
}

function Invoke-MorphospaceSupersedeActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$ActiveUnitSupersession,
        [string]$ExpectedActiveUnitSupersessionSha256='',
        [string]$Timestamp='',
        [string]$OutPath='',
        [switch]$Execute,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none'
    )
    $workspace=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path)
    $requestReference=Get-ActiveSupersessionRelativePath $workspace $ActiveUnitSupersession -RequireLeaf
    if($requestReference.relative-cnotmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'){throw 'Active-unit supersession request must use the workspace receipts namespace.'}
    $schemaPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\active-unit-supersession-v1.schema.json'
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $requestReference.absolute) -SchemaFile $schemaPath)){throw 'Active-unit supersession request is invalid.'}
    $request=Read-MorphospaceProtocolJson $requestReference.absolute
    $requestHash=Get-MorphospaceFileSha256 $requestReference.absolute
    if($ExpectedActiveUnitSupersessionSha256-and$ExpectedActiveUnitSupersessionSha256-cne$requestHash){throw 'Expected active-unit supersession request SHA-256 drifted.'}
    if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')}else{[void](Test-MorphospaceStrictUtcTimestamp $Timestamp)}
    $eventId=Get-MorphospaceSupersessionEventId -OldUnitId ([string]$request.old_unit.unit_id) -ReplacementUnitId ([string]$request.replacement_unit.unit_id)
    if([string]$request.supersession_id-cne$eventId-or$UnitId-cne[string]$request.replacement_unit.unit_id){throw 'Active-unit supersession request identity is not canonical.'}
    if($Execute-and-not$ExpectedActiveUnitSupersessionSha256){throw 'Executed SupersedeActive requires ExpectedActiveUnitSupersessionSha256 from its reviewed request.'}
    if($Execute-and-not$OutPath){throw 'Executed SupersedeActive requires OutPath for its transaction-owned receipt.'}
    $outReference=$null
    if($OutPath){
        $outReference=Get-ActiveSupersessionRelativePath $workspace $OutPath
        if($outReference.relative-cnotmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'){throw 'SupersedeActive OutPath must use the workspace receipts namespace.'}
    }
    $transactionId="$eventId-transition"
    $intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.intent.json"
    $completionPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.completion.json"
    $preBindingEvents=Get-ActiveSupersessionEventsSnapshot (Join-Path $workspace 'iteration-events.jsonl')
    $intentExists=[IO.File]::Exists($intentPath);$completionExists=[IO.File]::Exists($completionPath);$eventCount=@($preBindingEvents.events|Where-Object{[string]$_.event_id-ceq$eventId}).Count
    if(-not$intentExists-and($completionExists-or$eventCount)){throw 'SupersedeActive rejects an orphan completion or conflicting event without its exact intent.'}
    if($intentExists){
        if(-not$outReference){throw 'Active-unit supersession existing-intent recovery requires OutPath.'}
        return Invoke-ActiveSupersessionExistingIntent $workspace $transactionId $request $requestReference.relative $requestHash $outReference.relative $RepoMapPath -Execute:$Execute
    }
    $binding=Get-ActiveSupersessionBinding $workspace $UnitId $RepoMapPath $request
    if($Execute-and([IO.File]::Exists($outReference.absolute)-or[IO.Directory]::Exists($outReference.absolute))){throw 'SupersedeActive receipt target already exists.'}
    $result=New-ActiveSupersessionResult $request $requestReference.relative $requestHash $Timestamp $Execute.IsPresent $eventId
    $receiptSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\work-unit-automation-receipt-v2.schema.json'
    if(-not(Test-Json -Json ($result|ConvertTo-Json -Depth 32 -Compress) -SchemaFile $receiptSchema)){throw 'SupersedeActive result does not satisfy the automation receipt contract.'}
    if(-not$Execute){return $result}
    $repoMap=Get-ActiveSupersessionRepositoryMap $RepoMapPath
    $preStartRepositories=Get-ActiveSupersessionRepositoryObservation $binding.old.document $binding.ownership_units $repoMap.map
    if((Get-MorphospaceCanonicalJsonSha256 @($preStartRepositories))-cne(Get-MorphospaceCanonicalJsonSha256 @($binding.repositories))){throw 'SupersedeActive repository or overlay bytes drifted immediately before its transaction.'}
    $preStartFiles=@(
        [pscustomobject]@{name='project';path=(Join-Path $workspace 'project.spec.json');sha=[string]$request.expected.project_raw_sha256},
        [pscustomobject]@{name='state';path=(Join-Path $workspace 'workspace.state.json');sha=[string]$request.expected.state_raw_sha256},
        [pscustomobject]@{name='old unit';path=[string]$binding.old.absolute;sha=[string]$request.old_unit.raw_sha256},
        [pscustomobject]@{name='replacement unit';path=[string]$binding.replacement.absolute;sha=[string]$request.replacement_unit.raw_sha256},
        [pscustomobject]@{name='repository map';path=[IO.Path]::GetFullPath($RepoMapPath);sha=[string]$request.expected.repository_map_sha256}
    )
    foreach($companion in @($binding.companions)){$preStartFiles+=,[pscustomobject]@{name="companion unit '$([string]$companion.unit_id)'";path=[string]$companion.binding.absolute;sha=[string]$companion.request.raw_sha256}}
    foreach($file in $preStartFiles){
        if((Get-MorphospaceFileSha256 $file.path)-cne$file.sha){throw "SupersedeActive $([string]$file.name) bytes drifted immediately before its transaction."}
    }
    $freshEvents=Get-ActiveSupersessionEventsSnapshot (Join-Path $workspace 'iteration-events.jsonl')
    if([string]$freshEvents.sha256-cne[string]$request.expected.events_sha256-or[int64]$freshEvents.length-ne[int64]$request.expected.events_length-or[string]$freshEvents.tail_id-cne[string]$request.expected.event_tail_id){throw 'SupersedeActive event-ledger bytes drifted immediately before its transaction.'}
    $targetState=Copy-ActiveSupersessionValue $binding.state
    $targetState.current_unit=$UnitId
    $targetState.next_ready_unit=$null
    $targetState.last_event_id=$eventId
    $targetUnit=Copy-ActiveSupersessionValue $binding.replacement.document
    $targetUnit.status='active'
    $sequence=if($binding.events.events.Count){[int]$binding.events.events[-1].sequence+1}else{1}
    $event=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1'
        event_id=$eventId
        sequence=$sequence
        timestamp=$Timestamp
        project_id=[string]$binding.project.project_id
        unit_id=[string]$binding.old.unit_id
        event_type='state-transition'
        summary='Superseded the exact active unit with one reviewed proposed replacement while preserving the old unit and all acceptance evidence.'
        receipts=@($outReference.relative)
    }
    $receiptBytes=ConvertTo-MorphospaceProtocolJsonBytes $result
    Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -StatePath 'workspace.state.json' -UnitPath ([string]$binding.replacement.path) -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event -ExpectedPreStateSha256 ([string]$request.expected.state_canonical_sha256) -ExpectedPreUnitSha256 ([string]$request.replacement_unit.canonical_sha256) -ExpectedSupersededUnitSha256 ([string]$request.old_unit.canonical_sha256) -ExpectedEventTailId ([string]$request.expected.event_tail_id) -ExpectedEventsSha256 ([string]$request.expected.events_sha256) -ExpectedEventsLength ([int64]$request.expected.events_length) -Artifacts @([pscustomobject][ordered]@{bytes_base64=[Convert]::ToBase64String($receiptBytes);path=$outReference.relative;sha256=Get-MorphospaceSha256Bytes $receiptBytes}) -FaultAfter $FaultAfter|Out-Null
    if((Get-MorphospaceFileSha256 $binding.old.absolute)-cne[string]$request.old_unit.raw_sha256){throw 'SupersedeActive changed the preserved old unit bytes.'}
    $liveReplacement=Read-MorphospaceProtocolJson $binding.replacement.absolute
    if([string]$liveReplacement.status-cne'active'){throw 'SupersedeActive did not activate the replacement.'}
    $postProject=Read-MorphospaceProtocolJson (Join-Path $workspace 'project.spec.json');$postState=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
    [void](Assert-ActiveSupersessionPreservedBindings $workspace $request $postProject $postState)
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceSupersedeActive
