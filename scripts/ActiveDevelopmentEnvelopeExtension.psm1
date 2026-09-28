Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospacePlanningLifecycleProjection.psm1')
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceDevelopmentEnvelopeSemantics.psm1')
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceCurrentWorkCompatibility.psm1')

$script:ActiveEnvelopeExtensionSchema = 'rusty.morphospace.workflow.active_development_envelope_extension.v1'
$script:ActiveEnvelopeSourceSchema = 'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'
$script:ActiveEnvelopeEffectAxes = @('permissions','services','activities','queries','tools','assets','shaders','native_libraries','commands','routes','streams','inputs','scenes','markers')

function Copy-ActiveEnvelopeValue {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String)
}

function Get-ActiveEnvelopeHash {
    param([Parameter(Mandatory)][object]$Value)
    return Get-MorphospaceCanonicalJsonSha256 $Value
}

function Assert-ActiveEnvelopeValidationCheckpoint {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$CurrentUnitId,[Parameter(Mandatory)][object]$Expected)
    if($null-eq$State.validation_checkpoint){return}
    $checkpoint=$State.validation_checkpoint
    $names=@($checkpoint.PSObject.Properties.Name|Sort-Object)
    if(($names-join ',')-cne'receipt,result,tier'-or[string]$checkpoint.result-cne'pass'-or
       [string]$checkpoint.tier-cnotin@('quick','standard','deep')-or
       [string]::IsNullOrWhiteSpace([string]$checkpoint.receipt)-or
       [string]$checkpoint.receipt-cne[string]$State.last_accepted_receipt){
        throw 'Active-envelope validation checkpoint must be the retained passing accepted predecessor.'
    }
    # Recovery and later read-only replay authenticate the captured predecessor,
    # even when the live ledger already contains this extension or later work.
    $eventsPath=Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'iteration-events.jsonl' -RequireLeaf
    $raw=[IO.File]::ReadAllBytes($eventsPath);$length=[int64]$Expected.events_length
    if($length-le0-or$length-gt$raw.LongLength-or$length-gt[int]::MaxValue){throw 'Active-envelope accepted checkpoint predecessor prefix is unavailable.'}
    $prefix=[byte[]]::new([int]$length);[Array]::Copy($raw,$prefix,[int]$length)
    if((Get-MorphospaceSha256Bytes $prefix)-cne[string]$Expected.events_sha256){throw 'Active-envelope accepted checkpoint predecessor prefix drifted.'}
    $events=@([Text.UTF8Encoding]::new($false,$true).GetString($prefix)-split "`n"|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String})
    if($events.Count-eq0-or[string]$events[-1].event_id-cne[string]$Expected.event_tail_id){throw 'Active-envelope accepted checkpoint predecessor tail differs.'}
    $accepts=@($events|Where-Object{[string]$_.event_type-ceq'state-transition'-and
        [string]$_.event_id-cmatch('^'+[regex]::Escape([string]$_.unit_id)+'-accepted-[0-9]{4,}$')-and
        @($_.receipts)-ccontains[string]$checkpoint.receipt})
    if($accepts.Count-ne1-or[string]$accepts[0].unit_id-ceq$CurrentUnitId){throw 'Active-envelope validation checkpoint lacks one accepted predecessor.'}
    $accepted=Test-MorphospaceAcceptedCheckpointProof -WorkspaceRoot $WorkspaceRoot -ExpectedEvent $accepts[0] -AllowFiniteHistoricalV1
    # Finite historical tuples retain the producer-era schema authenticated by the existing proof.
    if(-not($accepted.PSObject.Properties.Name-contains'historical_only'-and$accepted.historical_only)){
        $receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $WorkspaceRoot ([string]$checkpoint.receipt) -RequireLeaf)
    $receiptSchema=switch([string]$receipt.schema){
        'rusty.morphospace.workflow.validation_receipt.v1'{'validation-receipt.schema.json'}
        'rusty.morphospace.workflow.validation_receipt.v2'{'validation-receipt-v2.schema.json'}
        default{throw 'Active-envelope accepted predecessor receipt schema is unsupported.'}
    }
    Assert-ActiveEnvelopeSchema $receipt $receiptSchema 'Active-envelope accepted predecessor receipt violates its closed schema.'
    if([string]$receipt.project_id-cne[string]$State.project_id-or[string]$receipt.unit_id-cne[string]$accepts[0].unit_id-or
       [string]$receipt.result-cne'pass'-or
       ([string]$receipt.schema-ceq'rusty.morphospace.workflow.validation_receipt.v1'-and[string]$receipt.tier-cne[string]$checkpoint.tier)){
        throw 'Active-envelope accepted predecessor receipt identity or result differs.'
    }
    }
    $acceptedState=$accepted.intent.target.state.document
    $acceptedUnitPath=Resolve-MorphospaceWorkspacePath $WorkspaceRoot "iteration-units/$([string]$accepts[0].unit_id).json" -RequireLeaf
    $acceptedUnit=Read-MorphospaceProtocolJson $acceptedUnitPath
    if([string]$acceptedUnit.status-cne'accepted'-or[string]$acceptedUnit.project_id-cne[string]$State.project_id-or
       (Get-ActiveEnvelopeHash $acceptedUnit)-cne[string]$accepted.intent.target.unit.sha256-or
       $null-ne$acceptedState.current_unit-or[string]$acceptedState.last_accepted_receipt-cne[string]$checkpoint.receipt-or
       $null-eq$acceptedState.validation_checkpoint-or
       (Get-ActiveEnvelopeHash $checkpoint)-cne(Get-ActiveEnvelopeHash $acceptedState.validation_checkpoint)){
        throw 'Active-envelope validation checkpoint differs from authenticated retained acceptance.'
    }
}

function Assert-ActiveEnvelopeSchema {
    param([Parameter(Mandatory)][object]$Value,[Parameter(Mandatory)][string]$SchemaName,[Parameter(Mandatory)][string]$Message)
    $schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\$SchemaName"
    if (-not (Test-Json -Json ($Value | ConvertTo-Json -Depth 100 -Compress) -SchemaFile $schemaPath)) { throw $Message }
}

function Get-ActiveEnvelopeIndex {
    param([AllowEmptyCollection()][object[]]$Rows,[Parameter(Mandatory)][string]$Key,[Parameter(Mandatory)][string]$Label)
    $index = @{}
    foreach ($row in @($Rows)) {
        $property = $row.PSObject.Properties[$Key]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { throw "$Label row omits '$Key'." }
        $id = [string]$property.Value
        if ($index.ContainsKey($id)) { throw "$Label repeats '$id' case-insensitively." }
        $index[$id] = $row
    }
    return $index
}

function Get-ActiveEnvelopeSortedStrings {
    param([AllowEmptyCollection()][object[]]$Values)
    return @($Values | ForEach-Object { [string]$_ } | Sort-Object -Unique -CaseSensitive)
}

function Assert-ActiveEnvelopeExactSet {
    param([AllowEmptyCollection()][object[]]$Actual,[AllowEmptyCollection()][object[]]$Expected,[Parameter(Mandatory)][string]$Label)
    $actualValues=@(Get-ActiveEnvelopeSortedStrings $Actual)
    $expectedValues=@(Get-ActiveEnvelopeSortedStrings $Expected)
    $equal=$actualValues.Count -eq $expectedValues.Count
    if($equal){for($i=0;$i-lt$actualValues.Count;$i++){if([string]$actualValues[$i]-cne[string]$expectedValues[$i]){$equal=$false;break}}}
    if (-not $equal) {
        throw "$Label differs from the explicit additions (actual=[$($actualValues -join ',')], expected=[$($expectedValues -join ',')])."
    }
}

function Get-ActiveEnvelopeAddedIds {
    param([AllowEmptyCollection()][object[]]$Current,[AllowEmptyCollection()][object[]]$Target)
    $old = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Current)) { [void]$old.Add([string]$id) }
    return @(Get-ActiveEnvelopeSortedStrings @($Target | Where-Object { -not $old.Contains([string]$_) }))
}

function Assert-ActiveEnvelopeRetainedRows {
    param(
        [AllowEmptyCollection()][object[]]$Current,
        [AllowEmptyCollection()][object[]]$Target,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [string]$AdditiveProperty=''
    )
    $old = Get-ActiveEnvelopeIndex $Current $Key "Current $Label"
    $new = Get-ActiveEnvelopeIndex $Target $Key "Target $Label"
    foreach ($id in $old.Keys) {
        if (-not $new.ContainsKey($id)) { throw "Target $Label removes '$id'." }
        if ($AdditiveProperty) {
            $before = Copy-ActiveEnvelopeValue $old[$id]
            $after = Copy-ActiveEnvelopeValue $new[$id]
            $beforeValues = Get-ActiveEnvelopeSortedStrings @($before.$AdditiveProperty)
            $afterValues = Get-ActiveEnvelopeSortedStrings @($after.$AdditiveProperty)
            $before.$AdditiveProperty = @(); $after.$AdditiveProperty = @()
            if ((Get-ActiveEnvelopeHash $before) -cne (Get-ActiveEnvelopeHash $after)) { throw "Target $Label rewrites '$id' outside $AdditiveProperty." }
            foreach ($value in $beforeValues) { if ($afterValues -cnotcontains $value) { throw "Target $Label removes '$id/$value'." } }
        } elseif ((Get-ActiveEnvelopeHash $old[$id]) -cne (Get-ActiveEnvelopeHash $new[$id])) {
            throw "Target $Label rewrites '$id'."
        }
    }
    return [pscustomobject]@{ current=$old; target=$new }
}

function Get-ActiveEnvelopeCanonicalWorkspaceBinding {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$Path,[switch]$RequireLeaf)
    $absolute = [IO.Path]::GetFullPath($Path)
    $prefix = $Workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Active-envelope path must stay inside the project workspace.' }
    Assert-MorphospaceNoReparseAncestor -Root $Workspace -Candidate $absolute
    $relative = $absolute.Substring($prefix.Length).Replace('\','/')
    $canonical = ConvertTo-MorphospaceProtocolRelativePath $relative
    if ($canonical -cne $relative) { throw "Active-envelope path is not canonical: '$relative'." }
    if ($RequireLeaf -and -not [IO.File]::Exists($absolute)) { throw "Active-envelope input is missing: '$relative'." }
    return [pscustomobject]@{ path=$absolute; relative=$relative }
}

function Get-ActiveEnvelopeSourceRowFields {
    param([Parameter(Mandatory)][object]$Row)
    if ([string]$Row.schema -ceq $script:ActiveEnvelopeSourceSchema) { return $Row }
    return $Row
}

function Get-ActiveEnvelopeParentCommit {
    param([Parameter(Mandatory)][object]$Row,[ValidateSet('commit','tree')][string]$Kind)
    $effective = "effective_$Kind"
    if ($null -ne $Row.PSObject.Properties[$effective]) { return [string]$Row.$effective }
    return [string]$Row.$Kind
}

function Get-ActiveEnvelopeBaselineCommit {
    param([Parameter(Mandatory)][object]$Row,[ValidateSet('commit','tree')][string]$Kind)
    $baseline = "baseline_$Kind"
    if ($null -ne $Row.PSObject.Properties[$baseline]) { return [string]$Row.$baseline }
    return [string]$Row.$Kind
}

function Test-ActiveEnvelopePathAllowed {
    param([Parameter(Mandatory)][string]$Path,[AllowEmptyCollection()][object[]]$AllowedPaths)
    $candidate = $Path.Replace('\','/').TrimEnd('/')
    foreach ($raw in @($AllowedPaths)) {
        $allowed = ([string]$raw).Replace('\','/').TrimEnd('/')
        if ($candidate.Equals($allowed,[StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($allowed + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-ActiveEnvelopeGitLines {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$Failure)
    $output = @(& git -C $Root @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) { throw $Failure }
    return @($output | ForEach-Object { ([string]$_).TrimEnd("`r") } | Where-Object { $_ -ne '' })
}

function Get-ActiveEnvelopeDirtyRows {
    param([Parameter(Mandatory)][string]$Root)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-ActiveEnvelopeGitLines $Root @('status','--porcelain=v1','--untracked-files=all') 'Cannot observe repository worktree state.')) {
        if ($line.Length -lt 4) { throw 'Repository worktree status is malformed.' }
        $status = $line.Substring(0,2)
        $path = $line.Substring(3).Replace('\','/')
        if ($path.Contains(' -> ')) { $path = $path.Substring($path.IndexOf(' -> ',[StringComparison]::Ordinal) + 4) }
        $path = ConvertTo-MorphospaceProtocolRelativePath $path
        $absolute = Join-Path $Root $path.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $sha = if ([IO.File]::Exists($absolute)) { Get-MorphospaceFileSha256 $absolute } else { $null }
        $rows.Add([pscustomobject][ordered]@{path=$path;status=$status;sha256=$sha}) | Out-Null
    }
    return @($rows.ToArray() | Sort-Object path,status)
}

function Get-ActiveEnvelopeSourceComposition {
    param(
        [Parameter(Mandatory)][object]$Extension,
        [Parameter(Mandatory)][object]$Provenance,
        [Parameter(Mandatory)][object]$RepositoryMap,
        [Parameter(Mandatory)][string]$RepositoryMapRelative,
        [Parameter(Mandatory)][string]$RepositoryMapRawSha256,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$PendingExtensionPath,
        [string]$ExpectedPendingExtensionSha256
    )
    $parentBinding = $Provenance.effective.source_composition_binding
    $originalBinding = $Provenance.original.source_composition_binding
    $parent = $Provenance.effective.source_composition
    $original = $Provenance.original.source_composition
    $parentRows = Get-ActiveEnvelopeIndex @($parent.repositories) 'repo_id' 'Parent source composition'
    $mapRows = Get-ActiveEnvelopeIndex @($RepositoryMap.repositories) 'repo_id' 'Effective repository map'
    $oldWritable = Get-ActiveEnvelopeIndex @($Provenance.effective.unit.allowed_repositories) 'repo_id' 'Current writable scope'
    $oldReadOnly = Get-ActiveEnvelopeIndex @($(if ($null -ne $Provenance.effective.unit.PSObject.Properties['read_only_dependencies']) { $Provenance.effective.unit.read_only_dependencies } else { @() })) 'repo_id' 'Current read-only scope'
    $records = [Collections.Generic.List[object]]::new()
    $materializations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @(Get-ActiveEnvelopeSortedStrings @($Extension.source_composition.repository_ids))) {
        if (-not $mapRows.ContainsKey($id)) { throw "Source-composition repository '$id' is absent from the effective repository map." }
        $mapRow = $mapRows[$id]
        $root = [IO.Path]::GetFullPath([string]$mapRow.path)
        if (-not [IO.Directory]::Exists($root)) { throw "Source-composition repository '$id' is unavailable." }
        $head = @(Get-ActiveEnvelopeGitLines $root @('rev-parse','HEAD') "Repository '$id' has no exact HEAD.")
        $tree = @(Get-ActiveEnvelopeGitLines $root @('rev-parse','HEAD^{tree}') "Repository '$id' has no exact tree.")
        if ($head.Count -ne 1 -or $tree.Count -ne 1) { throw "Repository '$id' has ambiguous Git identities." }
        $commit = ([string]$head[0]).ToLowerInvariant(); $effectiveTree = ([string]$tree[0]).ToLowerInvariant()
        if ($commit -cnotmatch '^[0-9a-f]{40}$' -or $effectiveTree -cnotmatch '^[0-9a-f]{40}$') { throw "Repository '$id' lacks canonical commit/tree identities." }
        $branchRows = @(Get-ActiveEnvelopeGitLines $root @('rev-parse','--abbrev-ref','HEAD') "Repository '$id' branch cannot be observed.")
        $branch = if ($branchRows.Count -eq 1 -and [string]$branchRows[0] -cne 'HEAD') { [string]$branchRows[0] } else { $null }
        $leaf = Split-Path -Leaf $root
        if (-not $materializations.Add($leaf)) { throw "Source composition repeats materialization leaf '$leaf'." }
        $dirty = @(Get-ActiveEnvelopeDirtyRows $root)
        if ($parentRows.ContainsKey($id)) {
            $old = $parentRows[$id]
            if ([string]$old.role -cne [string]$mapRow.role) { throw "Repository-map role for existing source '$id' changed." }
            $parentCommit = Get-ActiveEnvelopeParentCommit $old commit
            $parentTree = Get-ActiveEnvelopeParentCommit $old tree
            $baselineCommit = Get-ActiveEnvelopeBaselineCommit $old commit
            $baselineTree = Get-ActiveEnvelopeBaselineCommit $old tree
            $introducedBy = if ($null -ne $old.PSObject.Properties['introduced_by']) { [string]$old.introduced_by } else { [string]$Provenance.original.preparation_receipt.preparation_id }
            if ($oldReadOnly.ContainsKey($id)) {
                if ([string]$mapRow.role -ceq 'planning' -and ($commit -cne $parentCommit -or $effectiveTree -cne $parentTree -or $dirty.Count -ne 0)) {
                    Assert-MorphospaceReadOnlyPlanningLifecycleProjection -Workspace $WorkspaceRoot -Unit $Provenance.effective.unit -RepositoryEntry $mapRow -Dependency $oldReadOnly[$id] -LockedCommit $parentCommit -LockedTree $parentTree -CapturedExpected $Extension.expected -PendingExtensionPath $PendingExtensionPath -ExpectedPendingExtensionSha256 $ExpectedPendingExtensionSha256
                    $commit=$parentCommit;$effectiveTree=$parentTree;$dirty=@()
                } elseif ($commit -cne $parentCommit -or $effectiveTree -cne $parentTree -or $dirty.Count -ne 0) { throw "Read-only repository '$id' drifted from its exact parent source identity." }
            } elseif ($oldWritable.ContainsKey($id)) {
                & git -C $root merge-base --is-ancestor $parentCommit $commit 2>$null
                if ($LASTEXITCODE -ne 0) { throw "Writable repository '$id' is not a descendant of its parent source identity." }
                $changed = @(Get-ActiveEnvelopeGitLines $root @('diff','--name-only',"$parentCommit..$commit",'--') "Writable repository '$id' committed delta cannot be observed.")
                foreach ($path in @($changed) + @($dirty | ForEach-Object { $_.path })) {
                    if (-not (Test-ActiveEnvelopePathAllowed ([string]$path) @($oldWritable[$id].allowed_paths))) { throw "Writable repository '$id' changed '$path' outside the pre-extension active scope." }
                }
            } else { throw "Existing source repository '$id' is neither writable nor read-only in the active unit." }
        } else {
            if ($dirty.Count -ne 0) { throw "New source repository '$id' must be clean." }
            $baselineCommit=$commit; $baselineTree=$effectiveTree; $parentCommit=$commit; $parentTree=$effectiveTree; $introducedBy=[string]$Extension.extension_id
        }
        $records.Add([pscustomobject][ordered]@{
            repo_id=$id; role=[string]$mapRow.role; introduced_by=$introducedBy
            baseline_commit=$baselineCommit; baseline_tree=$baselineTree
            parent_commit=$parentCommit; parent_tree=$parentTree
            effective_commit=$commit; effective_tree=$effectiveTree; branch=$branch
            materialization_path=$leaf
            worktree_state=$(if ($dirty.Count) { 'permitted-active-dirt' } else { 'clean' })
            permitted_active_dirt=@($dirty)
        }) | Out-Null
    }
    $source = [pscustomobject][ordered]@{
        schema=$script:ActiveEnvelopeSourceSchema
        lock_id="$([string]$Extension.extension_id)-source"
        extension_id=[string]$Extension.extension_id
        project_id=[string]$Extension.project_id
        unit_id=[string]$Extension.unit_id
        parent=[pscustomobject][ordered]@{
            path=[string]$parentBinding.path;raw_sha256=[string]$parentBinding.raw_sha256;canonical_sha256=[string]$parentBinding.canonical_sha256
            schema=[string]$parent.schema;lock_id=[string]$parent.lock_id;fingerprint=[string]$parent.fingerprint
        }
        original_preparation=[pscustomobject][ordered]@{
            preparation_id=[string]$Provenance.original.preparation_receipt.preparation_id
            path=[string]$originalBinding.path;raw_sha256=[string]$originalBinding.raw_sha256;canonical_sha256=[string]$originalBinding.canonical_sha256
            schema=[string]$original.schema;lock_id=[string]$original.lock_id;fingerprint=[string]$original.fingerprint
        }
        repository_map=[pscustomobject][ordered]@{
            path=$RepositoryMapRelative;raw_sha256=$RepositoryMapRawSha256
            original_path=[string]$Provenance.original.repository_map.path
            original_raw_sha256=[string]$Provenance.original.repository_map.raw_sha256
        }
        fingerprint=('0' * 64)
        repositories=@($records.ToArray())
        status='locked'
        does_not_prove=@('Does not change the admitted objective, accept or validate work, mutate Git or a device, grant publication authority, or waive any owner boundary.')
    }
    $source.fingerprint = Get-ActiveEnvelopeHash $source
    Assert-ActiveEnvelopeSchema $source 'active-development-envelope-source-composition-v1.schema.json' 'Generated active-envelope source composition violates its closed schema.'
    return $source
}

function Assert-ActiveEnvelopeMapExtension {
    param([Parameter(Mandatory)][object]$Extension,[Parameter(Mandatory)][object]$OriginalMap,[Parameter(Mandatory)][object]$PreviousMap,[Parameter(Mandatory)][object]$EffectiveMap,[Parameter(Mandatory)][string]$PreviousMapPath)
    Assert-ActiveEnvelopeSchema $OriginalMap 'repository-map.schema.json' 'Original authenticated repository map violates its schema.'
    Assert-ActiveEnvelopeSchema $PreviousMap 'repository-map.schema.json' 'Previous effective repository map violates its schema.'
    Assert-ActiveEnvelopeSchema $EffectiveMap 'repository-map.schema.json' 'Effective repository map violates its schema.'
    $original = Get-ActiveEnvelopeIndex @($OriginalMap.repositories) 'repo_id' 'Original repository map'
    $old = Get-ActiveEnvelopeIndex @($PreviousMap.repositories) 'repo_id' 'Previous effective repository map'
    $new = Get-ActiveEnvelopeIndex @($EffectiveMap.repositories) 'repo_id' 'Effective repository map'
    foreach ($id in $original.Keys) {
        if (-not $old.ContainsKey($id) -or (Get-ActiveEnvelopeHash $original[$id]) -cne (Get-ActiveEnvelopeHash $old[$id])) { throw "Previous effective repository map lost original row '$id'." }
    }
    foreach ($id in $old.Keys) {
        if (-not $new.ContainsKey($id) -or (Get-ActiveEnvelopeHash $old[$id]) -cne (Get-ActiveEnvelopeHash $new[$id])) { throw "Effective repository map removes or rewrites previous row '$id'." }
    }
    $added = @($new.Keys | Where-Object { -not $old.ContainsKey($_) } | Sort-Object)
    Assert-ActiveEnvelopeExactSet -Actual $added -Expected @($Extension.additions.repository_ids) -Label 'Effective repository-map additions'
    if ($added.Count -gt 0 -and [string]$Extension.effective_repository_map.path -ceq $PreviousMapPath) { throw 'Adding a repository requires a distinct new ignored repository map.' }
    if ($added.Count -eq 0 -and [string]$Extension.effective_repository_map.path -cne $PreviousMapPath) { throw 'A roots-only extension must reuse the unchanged effective repository map.' }
}

function Assert-ActiveEnvelopeExplicitAdditions {
    param([Parameter(Mandatory)][object]$Extension,[Parameter(Mandatory)][object]$CurrentProject,[Parameter(Mandatory)][object]$CurrentLock,[Parameter(Mandatory)][object]$CurrentAssessment)
    $targetProject=$Extension.target.project; $targetLock=$Extension.target.feature_lock; $targetAssessment=$Extension.target.agent_scope_assessment
    Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds @($CurrentProject.repositories.repo_id) @($targetProject.repositories.repo_id)) -Expected @($Extension.additions.repository_ids) -Label 'Project repository additions'
    Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds @($CurrentLock.features.feature_id) @($targetLock.features.feature_id)) -Expected @($Extension.additions.feature_ids) -Label 'Feature additions'
    Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds @($CurrentProject.modules.module_id) @($targetProject.modules.module_id)) -Expected @($Extension.additions.module_ids) -Label 'Module additions'
    Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds @($CurrentProject.authority_map.parameter) @($targetProject.authority_map.parameter)) -Expected @($Extension.additions.authority_parameters) -Label 'Authority additions'
    Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds @($CurrentProject.validation_profiles.profile_id) @($targetProject.validation_profiles.profile_id)) -Expected @($Extension.additions.validation_profile_ids) -Label 'Validation-profile additions'
    Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds @($CurrentProject.acceptance_profiles.profile_id) @($targetProject.acceptance_profiles.profile_id)) -Expected @($Extension.additions.acceptance_profile_ids) -Label 'Acceptance-profile additions'
    Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds @($CurrentAssessment.allowed_permission_categories) @($targetAssessment.allowed_permission_categories)) -Expected @($Extension.additions.permissions) -Label 'Permission additions'
    Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds @($CurrentAssessment.build_envelope.allowed_profiles) @($targetAssessment.build_envelope.allowed_profiles)) -Expected @($Extension.additions.build_profile_ids) -Label 'Build-profile additions'
    Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds @($CurrentAssessment.device_envelope.allowed_kinds) @($targetAssessment.device_envelope.allowed_kinds)) -Expected @($Extension.additions.device_kinds) -Label 'Device-kind additions'
    foreach ($axis in $script:ActiveEnvelopeEffectAxes) {
        $before = if ($axis -ceq 'permissions') { @($CurrentAssessment.allowed_permission_categories | Where-Object { [string]$_ -cne 'none' }) } else { @($CurrentLock.effect_union.$axis) }
        $after = if ($axis -ceq 'permissions') { @($targetAssessment.allowed_permission_categories | Where-Object { [string]$_ -cne 'none' }) } else { @($targetLock.effect_union.$axis) }
        Assert-ActiveEnvelopeExactSet -Actual @(Get-ActiveEnvelopeAddedIds $before $after) -Expected @($Extension.additions.effects.$axis) -Label "Effect '$axis' additions"
    }
    Assert-ActiveEnvelopeExactSet -Actual @($Extension.additions.permissions) -Expected @($Extension.additions.effects.permissions) -Label 'Permission/effect additions'
    $oldOwners=Get-ActiveEnvelopeIndex @($CurrentAssessment.owner_repositories) 'repo_id' 'Current assessment owners'
    $newOwners=Get-ActiveEnvelopeIndex @($targetAssessment.owner_repositories) 'repo_id' 'Target assessment owners'
    $actualRoots=[Collections.Generic.List[object]]::new()
    foreach($id in $newOwners.Keys){
        $before=@(if($oldOwners.ContainsKey($id)){Get-ActiveEnvelopeSortedStrings @($oldOwners[$id].source_roots)}else{@()})
        $after=@(Get-ActiveEnvelopeSortedStrings @($newOwners[$id].source_roots))
        $addedRoots=@(Get-ActiveEnvelopeAddedIds $before $after)
        if($addedRoots.Count){$actualRoots.Add([pscustomobject][ordered]@{repo_id=$id;source_roots=@($addedRoots)})|Out-Null}
    }
    if((Get-ActiveEnvelopeHash @($actualRoots.ToArray()|Sort-Object repo_id))-cne(Get-ActiveEnvelopeHash @($Extension.additions.owner_roots|Sort-Object repo_id))){throw 'Owner-root additions differ from the explicit additions.'}
}

function Assert-ActiveEnvelopeTargetSemantics {
    param([Parameter(Mandatory)][object]$Extension,[Parameter(Mandatory)][object]$Provenance,[Parameter(Mandatory)][object]$EffectiveMap)
    $currentProject=$Provenance.effective.project; $currentLock=$Provenance.effective.feature_lock; $currentUnit=$Provenance.effective.unit; $currentAssessment=$Provenance.effective.assessment
    $targetProject=$Extension.target.project; $targetLock=$Extension.target.feature_lock; $targetAssessment=$Extension.target.agent_scope_assessment
    foreach($binding in @(
        @{name='project';actual=$currentProject;expected=$Extension.before.project},
        @{name='feature lock';actual=$currentLock;expected=$Extension.before.feature_lock},
        @{name='state';actual=$Provenance.effective.state;expected=$Extension.before.state},
        @{name='assessment';actual=$currentAssessment;expected=$Extension.before.agent_scope_assessment},
        @{name='writable scope';actual=@($currentUnit.allowed_repositories);expected=@($Extension.before.allowed_repositories)},
        @{name='read-only scope';actual=@($(if($currentUnit.PSObject.Properties.Name-contains'read_only_dependencies'){$currentUnit.read_only_dependencies}else{@()}));expected=@($Extension.before.read_only_dependencies)}
    )){if((Get-ActiveEnvelopeHash $binding.actual)-cne(Get-ActiveEnvelopeHash $binding.expected)){throw "Reviewed extension before $($binding.name) differs from authenticated provenance."}}
    Assert-ActiveEnvelopeSchema $targetProject 'project-spec-v2.schema.json' 'Target project violates project_spec.v2.'
    Assert-ActiveEnvelopeSchema $targetLock 'feature-lock-v2.schema.json' 'Target feature lock violates feature_lock.v2.'
    Assert-ActiveEnvelopeSchema $targetAssessment 'agent-scope-assessment-v1.schema.json' 'Target scope assessment violates its closed schema.'
    $pseudo=[pscustomobject][ordered]@{project_id=[string]$Extension.project_id;envelope=[pscustomobject][ordered]@{
        project=$targetProject;feature_lock=$targetLock;owner_repositories=@($targetAssessment.owner_repositories)
        public_private_boundary=[string]$targetAssessment.public_private_boundary
        allowed_change_categories=@($targetAssessment.allowed_change_categories)
        allowed_effect_categories=@($targetAssessment.allowed_effect_categories)
        allowed_permission_categories=@($targetAssessment.allowed_permission_categories)
        build_envelope=$targetAssessment.build_envelope;device_envelope=$targetAssessment.device_envelope
    }}
    Assert-MorphospaceDevelopmentEnvelopeAdditiveProject $currentProject $targetProject $false @($targetAssessment.owner_repositories) ordinary
    Assert-MorphospaceDevelopmentEnvelope -Preparation $pseudo -Project $currentProject -FeatureLock $currentLock -Mode ordinary
    $mapIndex=Get-ActiveEnvelopeIndex @($EffectiveMap.repositories) 'repo_id' 'Effective repository map'
    Assert-MorphospaceDevelopmentEnvelopeOwnerRoots @($targetAssessment.owner_repositories) $targetProject $mapIndex
    Assert-MorphospaceDevelopmentEnvelopeLockAndRegistry $currentProject $currentLock $Provenance.effective.state 'current'
    foreach($name in @('feature_ids','module_ids','authority_parameters','permissions','validation_profile_ids','acceptance_profile_ids','build_profile_ids','device_kinds')){if(@($Extension.additions.$name).Count-ne0){throw "Active-envelope extension may not add $name."}}
    foreach($axis in $script:ActiveEnvelopeEffectAxes){if(@($Extension.additions.effects.$axis).Count-ne0){throw "Active-envelope extension may not add effect '$axis'."}}
    $projectBefore=Copy-ActiveEnvelopeValue $currentProject;$projectAfter=Copy-ActiveEnvelopeValue $targetProject;$projectBefore.revision=0;$projectAfter.revision=0;$projectBefore.repositories=@();$projectAfter.repositories=@()
    if((Get-ActiveEnvelopeHash $projectBefore)-cne(Get-ActiveEnvelopeHash $projectAfter)){throw 'Active-envelope extension changes project authority outside repositories and revision.'}
    $lockBefore=Copy-ActiveEnvelopeValue $currentLock;$lockAfter=Copy-ActiveEnvelopeValue $targetLock
    foreach($copy in @($lockBefore,$lockAfter)){$copy.project_revision=0;$copy.revision=0;$copy.generated_at='2000-01-01T00:00:00.0000000Z';$copy.lock_fingerprint='0'*64}
    if((Get-ActiveEnvelopeHash $lockBefore)-cne(Get-ActiveEnvelopeHash $lockAfter)){throw 'Active-envelope extension changes feature, effect, permission, or activation authority.'}
    $assessmentBefore=Copy-ActiveEnvelopeValue $currentAssessment;$assessmentAfter=Copy-ActiveEnvelopeValue $targetAssessment;$assessmentBefore.owner_repositories=@();$assessmentAfter.owner_repositories=@()
    if((Get-ActiveEnvelopeHash $assessmentBefore)-cne(Get-ActiveEnvelopeHash $assessmentAfter)){throw 'Active-envelope extension changes the admitted assessment outside owner roots.'}
    if([string]$targetAssessment.objective-cne[string]$currentAssessment.objective){throw 'Active-envelope extension must preserve objective bytes.'}
    foreach($name in @('public_private_boundary','non_scope','prerequisites','validation_class','evidence_expectations','cleanup_expectations')){
        if((Get-ActiveEnvelopeHash $targetAssessment.$name)-cne(Get-ActiveEnvelopeHash $currentAssessment.$name)){throw "Active-envelope extension changes immutable assessment field '$name'."}
    }
    if([string]$targetAssessment.build_envelope.class-cne[string]$currentAssessment.build_envelope.class-or[string]$targetAssessment.device_envelope.requirement-cne[string]$currentAssessment.device_envelope.requirement){throw 'Active-envelope extension changes build or device class.'}
    $owners=Assert-ActiveEnvelopeRetainedRows @($currentAssessment.owner_repositories) @($targetAssessment.owner_repositories) 'repo_id' 'assessment owner repositories' -AdditiveProperty 'source_roots'
    [void]$owners
    $currentUnitClone=Copy-ActiveEnvelopeValue $currentUnit
    foreach($field in @('agent_scope_assessment','allowed_repositories','read_only_dependencies','source_composition')){$currentUnitClone.PSObject.Properties.Remove($field)}
    $targetUnitClone=Copy-ActiveEnvelopeValue $currentUnit
    $targetUnitClone.agent_scope_assessment=Copy-ActiveEnvelopeValue $targetAssessment
    $writableCopy=Copy-ActiveEnvelopeValue ([pscustomobject][ordered]@{values=@($Extension.target.allowed_repositories)})
    $readOnlyCopy=Copy-ActiveEnvelopeValue ([pscustomobject][ordered]@{values=@($Extension.target.read_only_dependencies)})
    $targetUnitClone.allowed_repositories=@($writableCopy.values)
    if($targetUnitClone.PSObject.Properties.Name-contains'read_only_dependencies'){$targetUnitClone.read_only_dependencies=@($readOnlyCopy.values)}else{$targetUnitClone|Add-Member -NotePropertyName read_only_dependencies -NotePropertyValue @($readOnlyCopy.values)}
    $targetUnitClone.source_composition=[pscustomobject][ordered]@{mode='exact-lock';lock_path=[string]$Extension.source_composition.path;materialization_receipt=$null}
    $targetImmutable=Copy-ActiveEnvelopeValue $targetUnitClone
    foreach($field in @('agent_scope_assessment','allowed_repositories','read_only_dependencies','source_composition')){$targetImmutable.PSObject.Properties.Remove($field)}
    if((Get-ActiveEnvelopeHash $currentUnitClone)-cne(Get-ActiveEnvelopeHash $targetImmutable)){throw 'Active-envelope extension changes a unit field outside the effective envelope.'}
    [void](Assert-ActiveEnvelopeRetainedRows @($currentUnit.allowed_repositories) @($Extension.target.allowed_repositories) 'repo_id' 'writable repositories' -AdditiveProperty 'allowed_paths')
    [void](Assert-ActiveEnvelopeRetainedRows @($(if($currentUnit.PSObject.Properties.Name-contains'read_only_dependencies'){$currentUnit.read_only_dependencies}else{@()})) @($Extension.target.read_only_dependencies) 'repo_id' 'read-only dependencies' -AdditiveProperty 'paths')
    $writable=Get-ActiveEnvelopeIndex @($Extension.target.allowed_repositories) 'repo_id' 'Target writable scope';$readOnly=Get-ActiveEnvelopeIndex @($Extension.target.read_only_dependencies) 'repo_id' 'Target read-only scope'
    foreach($id in $writable.Keys){if($readOnly.ContainsKey($id)){throw "Repository '$id' cannot be both writable and read-only."}}
    $ownerIndex=Get-ActiveEnvelopeIndex @($targetAssessment.owner_repositories) 'repo_id' 'Target assessment owners'
    $projectIndex=Get-ActiveEnvelopeIndex @($targetProject.repositories) 'repo_id' 'Target project repositories'
    foreach($id in $ownerIndex.Keys){if(-not$projectIndex.ContainsKey($id)-or(-not$writable.ContainsKey($id)-and-not$readOnly.ContainsKey($id))){throw "Target owner repository '$id' lacks exact project and unit closure."}}
    foreach($id in @($writable.Keys)+@($readOnly.Keys)){
        if(-not$ownerIndex.ContainsKey($id)-or-not$projectIndex.ContainsKey($id)){throw "Target unit repository '$id' lacks exact owner and project closure."}
        $paths=if($writable.ContainsKey($id)){@($writable[$id].allowed_paths)}else{@($readOnly[$id].paths)}
        foreach($path in $paths){
            if(-not(Test-ActiveEnvelopePathAllowed ([string]$path) @($ownerIndex[$id].source_roots))){throw "Target unit path '$id/$path' exceeds owner roots."}
            if(-not(Test-ActiveEnvelopePathAllowed ([string]$path) @($projectIndex[$id].allowed_paths))){throw "Target unit path '$id/$path' exceeds project scope."}
        }
    }
    $sourceIds=Get-ActiveEnvelopeSortedStrings @($Extension.source_composition.repository_ids)
    foreach($set in @(
        @{name='owner';values=@($ownerIndex.Keys)},
        @{name='project';values=@($projectIndex.Keys)},
        @{name='unit';values=@($writable.Keys)+@($readOnly.Keys)},
        @{name='repository map';values=@($mapIndex.Keys)}
    )){Assert-ActiveEnvelopeExactSet -Actual $sourceIds -Expected @($set.values) -Label "Target $($set.name) repository closure"}
    Assert-ActiveEnvelopeExplicitAdditions $Extension $currentProject $currentLock $currentAssessment
    return $targetUnitClone
}

function Get-ActiveEnvelopeArtifactDocument {
    param([Parameter(Mandatory)][object]$Intent,[Parameter(Mandatory)][string]$Schema,[Parameter(Mandatory)][string]$SchemaFile)
    $matches=[Collections.Generic.List[object]]::new()
    foreach($artifact in @($Intent.artifacts)){
        try{$bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64);$document=ConvertFrom-MorphospaceProtocolJsonBytes $bytes 'active-envelope artifact'}catch{continue}
        if([string]$document.schema-ceq$Schema){$matches.Add([pscustomobject]@{artifact=$artifact;bytes=$bytes;document=$document})|Out-Null}
    }
    if($matches.Count-ne1){throw "Active-envelope transition requires exactly one '$Schema' artifact."}
    if((Get-MorphospaceSha256Bytes $matches[0].bytes)-cne[string]$matches[0].artifact.sha256){throw 'Active-envelope artifact hash is detached.'}
    Assert-ActiveEnvelopeSchema $matches[0].document $SchemaFile 'Active-envelope transition artifact violates its schema.'
    return $matches[0]
}

function Assert-ActiveEnvelopeCapturedSourceObservation {
    param([Parameter(Mandatory)][object]$Source,[Parameter(Mandatory)][object]$RepositoryMap,[Parameter(Mandatory)][object]$UnitEndpoint,[switch]$AllowWritableDescendant,[string]$WorkspaceRoot,[object]$RecoveryIntent=$null)
    $map=Get-ActiveEnvelopeIndex @($RepositoryMap.repositories) 'repo_id' 'Observed repository map'
    $sourceRows=Get-ActiveEnvelopeIndex @($Source.repositories) 'repo_id' 'Captured source composition'
    $writable=Get-ActiveEnvelopeIndex @($UnitEndpoint.allowed_repositories) 'repo_id' 'Observed writable scope'
    $readOnly=Get-ActiveEnvelopeIndex @($UnitEndpoint.read_only_dependencies) 'repo_id' 'Observed read-only scope'
    foreach($id in $sourceRows.Keys){
        if(-not$map.ContainsKey($id)-or[string]$map[$id].role-cne[string]$sourceRows[$id].role){throw "Captured source repository '$id' is detached from its map role."}
        $root=[IO.Path]::GetFullPath([string]$map[$id].path);if(-not[IO.Directory]::Exists($root)){throw "Captured source repository '$id' is unavailable."}
        $head=@(Get-ActiveEnvelopeGitLines $root @('rev-parse','HEAD') "Captured source repository '$id' has no HEAD.");$tree=@(Get-ActiveEnvelopeGitLines $root @('rev-parse','HEAD^{tree}') "Captured source repository '$id' has no tree.")
        if($head.Count-ne1-or$tree.Count-ne1){throw "Captured source repository '$id' has ambiguous identities."};$currentCommit=([string]$head[0]).ToLowerInvariant();$currentTree=([string]$tree[0]).ToLowerInvariant();$capturedCommit=[string]$sourceRows[$id].effective_commit;$capturedTree=[string]$sourceRows[$id].effective_tree;$dirty=@(Get-ActiveEnvelopeDirtyRows $root)
        $objectTree=@(Get-ActiveEnvelopeGitLines $root @('rev-parse',"$capturedCommit^{tree}") "Captured source commit for '$id' is unavailable.")
        if($objectTree.Count-ne1-or[string]$objectTree[0]-cne$capturedTree){throw "Captured source tree for '$id' is detached from its commit."}
        if($readOnly.ContainsKey($id)){
            if([string]$map[$id].role-ceq'planning'-and($currentCommit-cne$capturedCommit-or$currentTree-cne$capturedTree-or$dirty.Count-ne0)){
                $observedUnit=[pscustomobject]@{unit_id=[string]$Source.unit_id}
                Assert-MorphospaceReadOnlyPlanningLifecycleProjection -Workspace $WorkspaceRoot -Unit $observedUnit -RepositoryEntry $map[$id] -Dependency $readOnly[$id] -LockedCommit $capturedCommit -LockedTree $capturedTree -RecoveryIntent $RecoveryIntent
            }elseif($currentCommit-cne$capturedCommit-or$currentTree-cne$capturedTree-or$dirty.Count-ne0){throw "Read-only captured source '$id' drifted."}
        }elseif($writable.ContainsKey($id)){
            if($AllowWritableDescendant){
                &git -C $root merge-base --is-ancestor $capturedCommit $currentCommit 2>$null;if($LASTEXITCODE-ne0){throw "Writable captured source '$id' is not an effective-source descendant."}
                $paths=@(Get-ActiveEnvelopeGitLines $root @('diff','--name-only',"$capturedCommit..$currentCommit",'--') "Writable captured source '$id' delta is unavailable.")+@($dirty|ForEach-Object{$_.path})
                foreach($path in $paths){if(-not(Test-ActiveEnvelopePathAllowed ([string]$path) @($writable[$id].allowed_paths))){throw "Writable captured source '$id' escaped its effective scope at '$path'."}}
            }else{
                if($currentCommit-cne$capturedCommit-or$currentTree-cne$capturedTree-or(Get-ActiveEnvelopeHash $dirty)-cne(Get-ActiveEnvelopeHash @($sourceRows[$id].permitted_active_dirt))){throw "Captured source observation for '$id' drifted before recovery."}
            }
        }else{throw "Captured source '$id' lacks writable/read-only unit closure."}
    }
}

function Assert-ActiveEnvelopeArtifactBindings {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Intent,[switch]$ObserveRepositories)
    $workspace=(Resolve-Path $WorkspaceRoot).Path
    if([string]$Intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v6'){throw 'Active-envelope recovery requires transition-ledger intent v6.'}
    if(@($Intent.artifacts).Count-ne2){throw 'Active-envelope extension requires exactly its reviewed request and derivative source artifacts.'}
    $requestBinding=Get-ActiveEnvelopeArtifactDocument $Intent $script:ActiveEnvelopeExtensionSchema 'active-development-envelope-extension-v1.schema.json'
    $sourceBinding=Get-ActiveEnvelopeArtifactDocument $Intent $script:ActiveEnvelopeSourceSchema 'active-development-envelope-source-composition-v1.schema.json'
    $request=$requestBinding.document;$source=$sourceBinding.document
    if([string]$Intent.state.path-cne'workspace.state.json'-or[string]$Intent.unit.path-cne"iteration-units/$([string]$request.unit_id).json"-or[string]$Intent.events.path-cne'iteration-events.jsonl'){
        throw 'Active-envelope recovery control references are not the canonical owner paths.'
    }
    Assert-ActiveEnvelopeValidationCheckpoint -WorkspaceRoot $workspace -State $request.before.state -CurrentUnitId ([string]$request.unit_id) -Expected $request.expected
    $eventId="$([string]$request.extension_id)-recorded"
    if([string]$Intent.transaction_id-cne"$eventId-transition"-or[string]$Intent.event.event_id-cne$eventId-or[string]$Intent.event.project_id-cne[string]$request.project_id-or[string]$Intent.event.unit_id-cne[string]$request.unit_id){throw 'Active-envelope recovery transaction identity is detached.'}
    $expectedReceipts=[string[]]@([string]$requestBinding.artifact.path,[string]$sourceBinding.artifact.path);[Array]::Sort($expectedReceipts,[StringComparer]::Ordinal)
    $actualReceipts=[string[]]@($Intent.event.receipts);[Array]::Sort($actualReceipts,[StringComparer]::Ordinal)
    if([string]$Intent.event.event_type-cne'state-transition'-or[string]$Intent.event.summary-cne'Extended the active development envelope through one owner-reviewed additive dependency and root transaction.'-or$actualReceipts.Count-ne2-or($actualReceipts-join[char]0)-cne($expectedReceipts-join[char]0)){throw 'Active-envelope recovery event semantics or artifact receipts are detached.'}
    if([string]$source.extension_id-cne[string]$request.extension_id-or[string]$source.project_id-cne[string]$request.project_id-or[string]$source.unit_id-cne[string]$request.unit_id-or[string]$Intent.target.unit.document.source_composition.lock_path-cne[string]$request.source_composition.path-or[string]$sourceBinding.artifact.path-cne[string]$request.source_composition.path){throw 'Active-envelope recovery source artifact is detached.'}
    if([string]$requestBinding.artifact.path-cne"receipts/$([string]$request.extension_id).json"){throw 'Active-envelope recovery receipt artifact path is detached.'}
    foreach($binding in @(
        @{n='project';p='project.spec.json';e=[string]$request.expected.project_sha256;r=[string]$request.expected.project_raw_sha256},
        @{n='feature lock';p='feature.lock.json';e=[string]$request.expected.feature_lock_sha256;r=[string]$request.expected.feature_lock_raw_sha256}
    )){
        $projection=@($Intent.additional_projections|Where-Object{[string]$_.path-ceq$binding.p});if($projection.Count-ne1-or[string]$projection[0].pre_sha256-cne$binding.e-or[string]$projection[0].pre_raw_sha256-cne$binding.r){throw "Active-envelope recovery $($binding.n) preimage is detached."}
    }
    if([string]$Intent.pre.state.sha256-cne[string]$request.expected.state_sha256-or[string]$Intent.pre_state_raw.sha256-cne[string]$request.expected.state_raw_sha256-or[string]$Intent.pre.unit.sha256-cne[string]$request.expected.unit_sha256-or[string]$Intent.pre_unit_raw.sha256-cne[string]$request.expected.unit_raw_sha256-or[string]$Intent.expected.events_sha256-cne[string]$request.expected.events_sha256-or[int64]$Intent.expected.events_length-ne[int64]$request.expected.events_length-or[string]$Intent.expected.event_tail_id-cne[string]$request.expected.event_tail_id){throw 'Active-envelope recovery state, unit, or event prefix is detached.'}
    $projectProjection=@($Intent.additional_projections|Where-Object{[string]$_.path-ceq'project.spec.json'})
    $lockProjection=@($Intent.additional_projections|Where-Object{[string]$_.path-ceq'feature.lock.json'})
    if($projectProjection.Count-ne1-or$lockProjection.Count-ne1-or
       (Get-ActiveEnvelopeHash $Intent.target.state.document)-cne[string]$Intent.target.state.sha256-or
       (Get-ActiveEnvelopeHash $Intent.target.unit.document)-cne[string]$Intent.target.unit.sha256-or
       (Get-ActiveEnvelopeHash $request.target.project)-cne[string]$projectProjection[0].target_sha256-or
       (Get-ActiveEnvelopeHash $request.target.feature_lock)-cne[string]$lockProjection[0].target_sha256){
        throw 'Active-envelope recovery target projections are detached.'
    }
    $mapPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$request.effective_repository_map.path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $mapPath)-cne[string]$request.effective_repository_map.raw_sha256-or[string]$source.repository_map.path-cne[string]$request.effective_repository_map.path-or[string]$source.repository_map.raw_sha256-cne[string]$request.effective_repository_map.raw_sha256){throw 'Active-envelope recovery effective repository map drifted.'}
    foreach($binding in @($source.parent,$source.original_preparation)){
        $path=Resolve-MorphospaceWorkspacePath $workspace ([string]$binding.path) -RequireLeaf
        $document=Read-MorphospaceProtocolJson $path
        if((Get-MorphospaceFileSha256 $path)-cne[string]$binding.raw_sha256-or(Get-ActiveEnvelopeHash $document)-cne[string]$binding.canonical_sha256-or[string]$document.schema-cne[string]$binding.schema-or[string]$document.lock_id-cne[string]$binding.lock_id-or[string]$document.fingerprint-cne[string]$binding.fingerprint){throw 'Active-envelope recovery source lineage drifted.'}
    }
    $parentSource=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$source.parent.path) -RequireLeaf)
    if([string]$request.expected.source_composition_path-cne[string]$source.parent.path-or[string]$request.expected.source_composition_raw_sha256-cne[string]$source.parent.raw_sha256-or[string]$request.expected.source_composition_canonical_sha256-cne[string]$source.parent.canonical_sha256-or[string]$request.expected.original_source_composition_path-cne[string]$source.original_preparation.path-or[string]$request.expected.original_source_composition_raw_sha256-cne[string]$source.original_preparation.raw_sha256){throw 'Active-envelope recovery request source lineage is detached.'}
    $parentMapPath=if([string]$parentSource.schema-ceq$script:ActiveEnvelopeSourceSchema){[string]$parentSource.repository_map.path}else{[string]$request.expected.original_repository_map_path}
    $parentMapHash=if([string]$parentSource.schema-ceq$script:ActiveEnvelopeSourceSchema){[string]$parentSource.repository_map.raw_sha256}else{[string]$request.expected.original_repository_map_raw_sha256}
    if([string]$request.expected.repository_map_path-cne$parentMapPath-or[string]$request.expected.repository_map_raw_sha256-cne$parentMapHash){throw 'Active-envelope recovery request repository-map lineage is detached.'}
    $originalMapPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$source.repository_map.original_path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $originalMapPath)-cne[string]$source.repository_map.original_raw_sha256){throw 'Active-envelope recovery original repository map drifted.'}
    $fingerprint=[string]$source.fingerprint;$copy=Copy-ActiveEnvelopeValue $source;$copy.fingerprint='0'*64
    if($fingerprint-cne(Get-ActiveEnvelopeHash $copy)){throw 'Active-envelope recovery source fingerprint is detached.'}
    if($ObserveRepositories){$effectiveMap=Read-MorphospaceProtocolJson $mapPath;Assert-ActiveEnvelopeCapturedSourceObservation $source $effectiveMap $request.target -WorkspaceRoot $workspace -RecoveryIntent $Intent}
    return [pscustomobject]@{request=$request;source_composition=$source}
}

function Assert-MorphospaceActiveEnvelopeExtensionRecoveryBindings {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Intent)
    [void](Assert-ActiveEnvelopeHistoricalTransition -WorkspaceRoot $WorkspaceRoot -ExpectedEvent $Intent.event -Transition ([pscustomobject]@{intent=$Intent}))
    return Assert-ActiveEnvelopeArtifactBindings -WorkspaceRoot $WorkspaceRoot -Intent $Intent -ObserveRepositories
}

function Assert-ActiveEnvelopeHistoricalSourceSemantics {
    param([Parameter(Mandatory)][object]$Request,[Parameter(Mandatory)][object]$Source,[Parameter(Mandatory)][object]$ParentSource,[Parameter(Mandatory)][object]$Map,[string]$WorkspaceRoot,[int]$BeforeSequence)
    $before=Get-ActiveEnvelopeIndex @($ParentSource.repositories) 'repo_id' 'Historical parent source'
    $after=Get-ActiveEnvelopeIndex @($Source.repositories) 'repo_id' 'Historical derivative source'
    $beforeWritable=Get-ActiveEnvelopeIndex @($Request.before.allowed_repositories) 'repo_id' 'Historical pre-extension writable scope'
    $beforeReadOnly=Get-ActiveEnvelopeIndex @($Request.before.read_only_dependencies) 'repo_id' 'Historical pre-extension read-only scope'
    Assert-ActiveEnvelopeExactSet -Actual @($after.Keys) -Expected @($Request.source_composition.repository_ids) -Label 'Historical derivative repository closure'
    Assert-ActiveEnvelopeExactSet -Actual @($after.Keys|Where-Object{-not$before.ContainsKey($_)}) -Expected @($Request.additions.repository_ids) -Label 'Historical derivative repository additions'
    $mapIndex=Get-ActiveEnvelopeIndex @($Map.repositories) 'repo_id' 'Historical effective map'
    foreach($id in $after.Keys){
        $row=$after[$id];if(-not$mapIndex.ContainsKey($id)-or[string]$mapIndex[$id].role-cne[string]$row.role){throw "Historical source row '$id' differs from its map."}
        $root=[IO.Path]::GetFullPath([string]$mapIndex[$id].path)
        $objectTree=@(Get-ActiveEnvelopeGitLines $root @('rev-parse',"$([string]$row.effective_commit)^{tree}") "Historical source commit for '$id' is unavailable.")
        if($objectTree.Count-ne1-or[string]$objectTree[0]-cne[string]$row.effective_tree){throw "Historical source tree for '$id' is detached from its commit."}
        if($before.ContainsKey($id)){
            $old=$before[$id]
            $expectedIntroducer=if($old.PSObject.Properties.Name-contains'introduced_by'){[string]$old.introduced_by}else{[string]$Source.original_preparation.preparation_id}
            if([string]$row.role-cne[string]$old.role-or[string]$row.introduced_by-cne$expectedIntroducer-or[string]$row.materialization_path-cne[string]$old.materialization_path-or[string]$row.baseline_commit-cne(Get-ActiveEnvelopeBaselineCommit $old commit)-or[string]$row.baseline_tree-cne(Get-ActiveEnvelopeBaselineCommit $old tree)-or[string]$row.parent_commit-cne(Get-ActiveEnvelopeParentCommit $old commit)-or[string]$row.parent_tree-cne(Get-ActiveEnvelopeParentCommit $old tree)){throw "Historical source row '$id' rewrites retained lineage identity."}
            if($beforeReadOnly.ContainsKey($id)){
                if([string]$row.effective_commit-cne[string]$row.parent_commit-or[string]$row.effective_tree-cne[string]$row.parent_tree-or[string]$row.worktree_state-cne'clean'-or@($row.permitted_active_dirt).Count-ne0){throw "Historical read-only source row '$id' drifted from its exact parent identity."}
                if([string]$mapIndex[$id].role-ceq'planning'-and[IO.Path]::GetFullPath($WorkspaceRoot).StartsWith($root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,$(if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}))){
                    Assert-MorphospaceReadOnlyPlanningLifecycleProjection -Workspace $WorkspaceRoot -Unit ([pscustomobject]@{unit_id=[string]$Request.unit_id}) -RepositoryEntry $mapIndex[$id] -Dependency $beforeReadOnly[$id] -LockedCommit ([string]$row.parent_commit) -LockedTree ([string]$row.parent_tree) -CapturedExpected $Request.expected -HistoricalOnly -BeforeSequence $BeforeSequence
                }
            }elseif($beforeWritable.ContainsKey($id)){
                &git -C $root merge-base --is-ancestor ([string]$row.parent_commit) ([string]$row.effective_commit) 2>$null;if($LASTEXITCODE-ne0){throw "Historical writable source row '$id' is not a descendant of its parent identity."}
                $paths=@(Get-ActiveEnvelopeGitLines $root @('diff','--name-only',"$([string]$row.parent_commit)..$([string]$row.effective_commit)",'--') "Historical writable source row '$id' delta is unavailable.")+@($row.permitted_active_dirt|ForEach-Object{$_.path})
                foreach($path in $paths){if(-not(Test-ActiveEnvelopePathAllowed ([string]$path) @($beforeWritable[$id].allowed_paths))){throw "Historical writable source row '$id' changed '$path' outside its pre-extension active scope."}}
                if(([string]$row.worktree_state-ceq'clean')-ne(@($row.permitted_active_dirt).Count-eq0)){throw "Historical writable source row '$id' worktree-state evidence is inconsistent."}
            }else{throw "Historical retained source row '$id' was outside the pre-extension unit closure."}
        }else{
            if([string]$row.introduced_by-cne[string]$Request.extension_id-or[string]$row.baseline_commit-cne[string]$row.parent_commit-or[string]$row.baseline_commit-cne[string]$row.effective_commit-or[string]$row.baseline_tree-cne[string]$row.parent_tree-or[string]$row.baseline_tree-cne[string]$row.effective_tree-or[string]$row.worktree_state-cne'clean'-or@($row.permitted_active_dirt).Count-ne0){throw "Historical new source row '$id' is not one clean exact baseline."}
        }
    }
}

function Assert-ActiveEnvelopeHistoricalTransition {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$ExpectedEvent,[Parameter(Mandatory)][object]$Transition)
    $workspace=(Resolve-Path $WorkspaceRoot).Path;$intent=$Transition.intent
    if($ExpectedEvent.timestamp-isnot[string]){throw 'Historical active-envelope extension expected event must retain its protocol timestamp bytes.'}
    Assert-ActiveEnvelopeSchema $ExpectedEvent 'iteration-event.schema.json' 'Historical active-envelope extension expected event violates its schema.'
    if((Get-ActiveEnvelopeHash $intent.event)-cne(Get-ActiveEnvelopeHash $ExpectedEvent)){throw "Historical active-envelope extension event is detached (intent=$([string]$intent.event.event_id)/$([string]$intent.event.sequence), expected=$([string]$ExpectedEvent.event_id)/$([string]$ExpectedEvent.sequence))."}
    $proof=Assert-ActiveEnvelopeArtifactBindings -WorkspaceRoot $workspace -Intent $intent;$request=$proof.request;$source=$proof.source_composition
    foreach($binding in @(@{n='project';v=$request.before.project;h=$request.expected.project_sha256;r=$request.expected.project_raw_sha256},@{n='feature lock';v=$request.before.feature_lock;h=$request.expected.feature_lock_sha256;r=$request.expected.feature_lock_raw_sha256})){
        if((Get-ActiveEnvelopeHash $binding.v)-cne[string]$binding.h){throw "Historical extension before $($binding.n) hash is detached."}
    }
    $beforeUnit=Copy-ActiveEnvelopeValue $intent.target.unit.document
    $beforeWritable=Copy-ActiveEnvelopeValue ([pscustomobject][ordered]@{values=@($request.before.allowed_repositories)})
    $beforeReadOnly=Copy-ActiveEnvelopeValue ([pscustomobject][ordered]@{values=@($request.before.read_only_dependencies)})
    $beforeUnit.agent_scope_assessment=Copy-ActiveEnvelopeValue $request.before.agent_scope_assessment
    $beforeUnit.allowed_repositories=@($beforeWritable.values)
    $beforeUnit.read_only_dependencies=@($beforeReadOnly.values)
    $beforeUnit.source_composition=[pscustomobject][ordered]@{mode='exact-lock';lock_path=[string]$request.expected.source_composition_path;materialization_receipt=$null}
    if((Get-ActiveEnvelopeHash $beforeUnit)-cne[string]$intent.pre.unit.sha256-or(Get-ActiveEnvelopeHash $beforeUnit)-cne[string]$request.expected.unit_sha256-or(Get-ActiveEnvelopeHash $request.before.state)-cne[string]$intent.pre.state.sha256-or(Get-ActiveEnvelopeHash $request.before.state)-cne[string]$request.expected.state_sha256){throw 'Historical extension before state or unit is detached.'}
    $provenance=[pscustomobject]@{effective=[pscustomobject]@{project=$request.before.project;feature_lock=$request.before.feature_lock;state=$request.before.state;unit=$beforeUnit;assessment=$request.before.agent_scope_assessment}}
    $targetUnit=Assert-ActiveEnvelopeTargetSemantics $request $provenance (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$request.effective_repository_map.path) -RequireLeaf))
    $targetState=Copy-ActiveEnvelopeValue $request.before.state;$targetState.plan_revision=[int]$targetState.plan_revision+1;$targetState.last_event_id=[string]$ExpectedEvent.event_id;$targetState.module_registry=Get-MorphospaceDevelopmentEnvelopeModuleRegistry $request.target.project $request.target.feature_lock
    if((Get-ActiveEnvelopeHash $targetUnit)-cne[string]$intent.target.unit.sha256-or(Get-ActiveEnvelopeHash $request.target.state)-cne[string]$intent.target.state.sha256-or(Get-ActiveEnvelopeHash $request.target.state)-cne(Get-ActiveEnvelopeHash $targetState)){throw 'Historical extension target state or unit is not the exact derived projection.'}
    $originalMap=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$request.expected.original_repository_map_path) -RequireLeaf);$previousMap=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$request.expected.repository_map_path) -RequireLeaf);$effectiveMap=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$request.effective_repository_map.path) -RequireLeaf)
    Assert-ActiveEnvelopeMapExtension $request $originalMap $previousMap $effectiveMap ([string]$request.expected.repository_map_path)
    $parentSource=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$source.parent.path) -RequireLeaf);Assert-ActiveEnvelopeHistoricalSourceSemantics $request $source $parentSource $effectiveMap -WorkspaceRoot $workspace -BeforeSequence ([int]$ExpectedEvent.sequence)
    return $Transition
}

function Test-MorphospaceHistoricalActiveDevelopmentEnvelopeExtension {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$ExpectedEvent)
    $transaction=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId "$([string]$ExpectedEvent.event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$([string]$ExpectedEvent.unit_id).json" -ExpectedEventsPath 'iteration-events.jsonl'
    return Assert-ActiveEnvelopeHistoricalTransition -WorkspaceRoot $WorkspaceRoot -ExpectedEvent $ExpectedEvent -Transition $transaction
}

function Invoke-MorphospaceExtendActiveDevelopmentEnvelope {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$ActiveDevelopmentEnvelopeExtension,
        [Parameter(Mandatory)][string]$RepositoryMapPath,
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$SourceCompositionOutPath,
        [string]$ExpectedActiveDevelopmentEnvelopeExtensionSha256='',
        [string]$Timestamp='',
        [scriptblock]$BeforeTransitionHook,
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none',
        [switch]$Execute
    )
    $workspace=(Resolve-Path $WorkspaceRoot).Path
    $requestPath=(Resolve-Path $ActiveDevelopmentEnvelopeExtension).Path
    $request=Read-MorphospaceProtocolJson $requestPath
    Assert-ActiveEnvelopeSchema $request 'active-development-envelope-extension-v1.schema.json' 'Active development-envelope extension violates its closed schema.'
    if([string]$request.unit_id-cne$UnitId-or[string]$request.expected.current_unit-cne$UnitId){throw 'Extension identity and current unit differ from UnitId.'}
    $inputHash=Get-MorphospaceFileSha256 $requestPath
    if($ExpectedActiveDevelopmentEnvelopeExtensionSha256-and$ExpectedActiveDevelopmentEnvelopeExtensionSha256-cne$inputHash){throw 'Expected active-envelope extension hash differs from the input.'}
    if($Execute-and-not$ExpectedActiveDevelopmentEnvelopeExtensionSha256){throw 'Executed ExtendActiveDevelopmentEnvelope requires the exact dry-run input hash.'}
    $mapBinding=Get-ActiveEnvelopeCanonicalWorkspaceBinding $workspace $RepositoryMapPath -RequireLeaf
    $outBinding=Get-ActiveEnvelopeCanonicalWorkspaceBinding $workspace $OutPath
    $sourceOutBinding=Get-ActiveEnvelopeCanonicalWorkspaceBinding $workspace $SourceCompositionOutPath
    if($outBinding.relative-cne"receipts/$([string]$request.extension_id).json"-or$sourceOutBinding.relative-cne[string]$request.source_composition.path-or$mapBinding.relative-cne[string]$request.effective_repository_map.path){throw 'Extension output, source output, or repository-map path differs from the reviewed request.'}
    $eventId="$([string]$request.extension_id)-recorded";$transactionId="$eventId-transition";$intentPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.intent.json"
    if([IO.File]::Exists($intentPath)){
        $intent=Read-MorphospaceProtocolJson $intentPath;$proof=Assert-MorphospaceActiveEnvelopeExtensionRecoveryBindings -WorkspaceRoot $workspace -Intent $intent
        if((Get-ActiveEnvelopeHash $proof.request)-cne(Get-ActiveEnvelopeHash $request)-or[string]$proof.request.effective_repository_map.path-cne$mapBinding.relative-or[string]$proof.request.source_composition.path-cne$sourceOutBinding.relative){throw 'Active-envelope extension replay conflicts with the durable intent.'}
        if($Execute){Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -FaultAfter $FaultAfter|Out-Null}
        $completionPath=Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$transactionId.completion.json"
        $completed=[IO.File]::Exists($completionPath)
        $replayResult=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$request.project_id;unit_id=$UnitId;action='ExtendActiveDevelopmentEnvelope';timestamp=[string]$intent.event.timestamp;executed=$Execute.IsPresent;transition='active-development-envelope-extended';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject][ordered]@{path=$outBinding.relative;sha256=$inputHash};event_id=$(if($completed){$eventId}else{$null})}
        Assert-ActiveEnvelopeSchema $replayResult 'work-unit-automation-receipt-v2.schema.json' 'ExtendActiveDevelopmentEnvelope replay emitted an invalid automation receipt.'
        return $replayResult
    }
    if([IO.File]::Exists($outBinding.path)-or[IO.File]::Exists($sourceOutBinding.path)){throw 'Extension-owned artifact output already exists.'}
    $statePath=Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf;$unitRelative="iteration-units/$UnitId.json";$unitPath=Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf
    $projectPath=Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf;$lockPath=Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf;$eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $state=Read-MorphospaceProtocolJson $statePath;$unit=Read-MorphospaceProtocolJson $unitPath;$project=Read-MorphospaceProtocolJson $projectPath;$lock=Read-MorphospaceProtocolJson $lockPath;$map=Read-MorphospaceProtocolJson $mapBinding.path
    $mapHash=Get-MorphospaceFileSha256 $mapBinding.path
    if($mapHash-cne[string]$request.effective_repository_map.raw_sha256){throw 'Effective repository map raw hash differs from the reviewed request.'}
    $currentMapBinding=Get-ActiveEnvelopeCanonicalWorkspaceBinding $workspace (Join-Path $workspace ([string]$request.expected.repository_map_path)) -RequireLeaf
    $provenance=Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId $UnitId -RepositoryMapPath $currentMapBinding.path
    if($provenance.effective.unit.PSObject.Properties.Name-contains'tooling_context'){
        [void](Assert-MorphospaceToolingContextExecutor -WorkspaceRoot $workspace -Binding $provenance.effective.unit.tooling_context -Action ExtendActiveDevelopmentEnvelope -OwnerModule $MyInvocation.MyCommand.Module)
    }
    foreach($pair in @(@('project',$project),@('feature_lock',$lock),@('state',$state),@('unit',$unit))){if((Get-ActiveEnvelopeHash $pair[1])-cne(Get-ActiveEnvelopeHash $provenance.effective.($pair[0]))){throw "Live $($pair[0]) differs from authenticated effective-envelope provenance."}}
    if([string]$state.project_id-cne[string]$request.project_id-or[string]$state.current_unit-cne$UnitId-or$null-ne$state.next_ready_unit-or[string]$unit.project_id-cne[string]$request.project_id-or[string]$unit.status-cne'active'-or($unit.PSObject.Properties.Name-contains'candidate_freeze')){throw 'ExtendActiveDevelopmentEnvelope requires the exact unfrozen current active unit.'}
    if(@($state.blockers).Count-ne0-or$null-ne$state.pending_push_bundle){throw 'ExtendActiveDevelopmentEnvelope requires no blocker or pending publication.'}
    Assert-ActiveEnvelopeValidationCheckpoint -WorkspaceRoot $workspace -State $state -CurrentUnitId $UnitId -Expected $request.expected
    $workMode=if($unit.PSObject.Properties.Name-contains'work_mode'){[string]$unit.work_mode}else{'feature'};if($workMode-cne'feature'-or-not($unit.PSObject.Properties.Name-contains'agent_scope_assessment')){throw 'ExtendActiveDevelopmentEnvelope requires an admitted feature unit.'}
    $eventsRaw=[IO.File]::ReadAllBytes($eventsPath);$events=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100});if($events.Count-eq0){throw 'Active-envelope extension requires a non-empty event ledger.'};$tail=$events[-1]
    foreach($check in @(
        @{n='project';e=$request.expected.project_sha256;a=Get-ActiveEnvelopeHash $project},@{n='project raw';e=$request.expected.project_raw_sha256;a=Get-MorphospaceFileSha256 $projectPath},
        @{n='feature lock';e=$request.expected.feature_lock_sha256;a=Get-ActiveEnvelopeHash $lock},@{n='feature lock raw';e=$request.expected.feature_lock_raw_sha256;a=Get-MorphospaceFileSha256 $lockPath},
        @{n='state';e=$request.expected.state_sha256;a=Get-ActiveEnvelopeHash $state},@{n='state raw';e=$request.expected.state_raw_sha256;a=Get-MorphospaceFileSha256 $statePath},
        @{n='unit';e=$request.expected.unit_sha256;a=Get-ActiveEnvelopeHash $unit},@{n='unit raw';e=$request.expected.unit_raw_sha256;a=Get-MorphospaceFileSha256 $unitPath},
        @{n='events';e=$request.expected.events_sha256;a=Get-MorphospaceFileSha256 $eventsPath},@{n='event tail';e=$request.expected.event_tail_id;a=[string]$tail.event_id},
        @{n='source raw';e=$request.expected.source_composition_raw_sha256;a=[string]$provenance.effective.source_composition_binding.raw_sha256},@{n='source canonical';e=$request.expected.source_composition_canonical_sha256;a=[string]$provenance.effective.source_composition_binding.canonical_sha256},
        @{n='repository map raw';e=$request.expected.repository_map_raw_sha256;a=[string]$provenance.effective.repository_map.raw_sha256},
        @{n='original source raw';e=$request.expected.original_source_composition_raw_sha256;a=[string]$provenance.original.source_composition_binding.raw_sha256},@{n='original map raw';e=$request.expected.original_repository_map_raw_sha256;a=[string]$provenance.original.repository_map.raw_sha256}
    )){if([string]$check.e-cne[string]$check.a){throw "Extension stale $($check.n) preimage."}}
    if([int64]$request.expected.events_length-ne$eventsRaw.LongLength-or[int]$request.expected.project_revision-ne[int]$project.revision-or[int]$request.expected.feature_lock_revision-ne[int]$lock.revision-or[int]$request.expected.plan_revision-ne[int]$state.plan_revision-or[string]$request.expected.source_composition_path-cne[string]$provenance.effective.source_composition_binding.path-or[string]$request.expected.repository_map_path-cne[string]$provenance.effective.repository_map.path-or[string]$request.expected.original_source_composition_path-cne[string]$provenance.original.source_composition_binding.path-or[string]$request.expected.original_repository_map_path-cne[string]$provenance.original.repository_map.path){throw 'Extension revision, ledger, source, or repository-map preimage is stale.'}
    $originalMap=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$provenance.original.repository_map.path) -RequireLeaf)
    $previousMap=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$provenance.effective.repository_map.path) -RequireLeaf)
    Assert-ActiveEnvelopeMapExtension $request $originalMap $previousMap $map ([string]$provenance.effective.repository_map.path)
    $targetUnit=Assert-ActiveEnvelopeTargetSemantics $request $provenance $map
    $source=Get-ActiveEnvelopeSourceComposition $request $provenance $map $mapBinding.relative $mapHash $workspace $requestPath $inputHash
    $sourceBytes=ConvertTo-MorphospaceProtocolJsonBytes $source
    $targetState=Copy-ActiveEnvelopeValue $state;$targetState.plan_revision=[int]$state.plan_revision+1;$targetState.last_event_id=$eventId;$targetState.module_registry=Get-MorphospaceDevelopmentEnvelopeModuleRegistry $request.target.project $request.target.feature_lock
    if((Get-ActiveEnvelopeHash $targetState)-cne(Get-ActiveEnvelopeHash $request.target.state)){throw 'Reviewed target state differs from the exact derived plan and registry projection.'}
    Assert-ActiveEnvelopeSchema $targetState 'workspace-state-v2.schema.json' 'Target active-envelope workspace state violates its schema.'
    Assert-ActiveEnvelopeSchema $targetUnit 'iteration-unit.schema.json' 'Target active-envelope unit violates its schema.'
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$tail.sequence+1;timestamp=$(if($Timestamp){$Timestamp}else{[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')});project_id=[string]$request.project_id;unit_id=$UnitId;event_type='state-transition';summary='Extended the active development envelope through one owner-reviewed additive dependency and root transaction.';receipts=@($outBinding.relative,$sourceOutBinding.relative|Sort-Object)}
    if(-not(Test-MorphospaceStrictUtcTimestamp ([string]$event.timestamp))){throw 'Extension timestamp must be strict UTC.'}
    Assert-ActiveEnvelopeSchema $event 'iteration-event.schema.json' 'Active-envelope extension event violates its schema.'
    if($Execute){
        if($BeforeTransitionHook){&$BeforeTransitionHook}
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" -StatePath 'workspace.state.json' -UnitPath $unitRelative -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event -ExpectedPreStateSha256 (Get-ActiveEnvelopeHash $state) -ExpectedPreStateRawSha256 (Get-MorphospaceFileSha256 $statePath) -ExpectedPreUnitSha256 (Get-ActiveEnvelopeHash $unit) -ExpectedPreUnitRawSha256 (Get-MorphospaceFileSha256 $unitPath) -ExpectedEventTailId ([string]$tail.event_id) -ExpectedEventsSha256 (Get-MorphospaceFileSha256 $eventsPath) -ExpectedEventsLength $eventsRaw.LongLength -AdditionalProjections @([pscustomobject]@{path='feature.lock.json';expected_sha256=(Get-ActiveEnvelopeHash $lock);expected_raw_sha256=(Get-MorphospaceFileSha256 $lockPath);document=$request.target.feature_lock},[pscustomobject]@{path='project.spec.json';expected_sha256=(Get-ActiveEnvelopeHash $project);expected_raw_sha256=(Get-MorphospaceFileSha256 $projectPath);document=$request.target.project}) -Artifacts @([pscustomobject]@{source_path=$requestPath;path=$outBinding.relative;sha256=$inputHash},[pscustomobject]@{bytes_base64=[Convert]::ToBase64String($sourceBytes);path=$sourceOutBinding.relative;sha256=(Get-MorphospaceSha256Bytes $sourceBytes)}) -FaultAfter $FaultAfter | Out-Null
        [void](Test-MorphospaceHistoricalActiveDevelopmentEnvelopeExtension -WorkspaceRoot $workspace -ExpectedEvent $event)
    }
    $result=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$request.project_id;unit_id=$UnitId;action='ExtendActiveDevelopmentEnvelope';timestamp=[string]$event.timestamp;executed=$Execute.IsPresent;transition='active-development-envelope-extended';status_before='active';status_after='active';current_unit_before=$UnitId;current_unit_after=$UnitId;preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject][ordered]@{path=$outBinding.relative;sha256=$inputHash};event_id=$(if($Execute){$eventId}else{$null})}
    Assert-ActiveEnvelopeSchema $result 'work-unit-automation-receipt-v2.schema.json' 'ExtendActiveDevelopmentEnvelope emitted an invalid automation receipt.'
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceExtendActiveDevelopmentEnvelope,Test-MorphospaceHistoricalActiveDevelopmentEnvelopeExtension,Assert-MorphospaceActiveEnvelopeExtensionRecoveryBindings
