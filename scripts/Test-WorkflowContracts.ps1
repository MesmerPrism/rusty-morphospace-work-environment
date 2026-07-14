param(
    [string]$RepoRoot = "",
    [string]$WorkspaceRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:PortableIdPattern = "^[a-z0-9][a-z0-9-]{1,127}$"
Import-Module (Join-Path $RepoRoot 'scripts\lib\MorphospaceProtocolCommon.psm1') -Force

function Add-Failure {
    param([string]$Message)

    $script:Failures.Add($Message) | Out-Null
}

function Assert-Contract {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        Add-Failure -Message $Message
    }
}

function Test-Text {
    param([object]$Value)

    return -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Read-JsonDocument {
    param(
        [string]$Path,
        [string]$Context
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Failure -Message "$Context is missing: $Path"
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    } catch {
        Add-Failure -Message "$Context is not valid JSON: $($_.Exception.Message)"
        return $null
    }
}

function Test-UniqueProperty {
    param(
        [object[]]$Items,
        [string]$Property,
        [string]$Context
    )

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Items)) {
        $value = [string]$item.$Property
        if (-not (Test-Text $value)) {
            Add-Failure -Message "$Context contains an item without '$Property'."
            continue
        }
        $values.Add($value) | Out-Null
    }

    foreach ($group in @($values | Group-Object)) {
        if ($group.Count -gt 1) {
            Add-Failure -Message "$Context contains duplicate $Property '$($group.Name)'."
        }
    }
}

function Test-NonEmptyTextArray {
    param(
        [object]$Value,
        [string]$Context,
        [bool]$Required = $true
    )

    $items = @($Value)
    if ($Required -and $items.Count -eq 0) {
        Add-Failure -Message "$Context must contain at least one item."
        return
    }

    foreach ($item in $items) {
        if (-not (Test-Text $item)) {
            Add-Failure -Message "$Context contains an empty value."
        }
    }
}

function Normalize-RelativePath {
    param([string]$Path)

    return (($Path -replace "\\", "/").Trim()).TrimStart("./")
}

function Test-PathInScope {
    param(
        [string]$Candidate,
        [object[]]$Allowed
    )

    $candidatePath = Normalize-RelativePath $Candidate
    foreach ($entry in @($Allowed)) {
        $allowedPath = Normalize-RelativePath ([string]$entry)
        if ($allowedPath -eq "" -or $allowedPath -eq ".") {
            return $true
        }
        if ($candidatePath -eq $allowedPath.TrimEnd("/")) {
            return $true
        }
        if ($candidatePath.StartsWith($allowedPath.TrimEnd("/") + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-FeatureLockFingerprint {
    param([object]$Lock)

    $copy = ($Lock | ConvertTo-Json -Depth 48 | ConvertFrom-Json)
    $copy.lock_fingerprint = "0" * 64
    $json = $copy | ConvertTo-Json -Depth 48 -Compress
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $sha.Dispose() }
}

function Get-JsonFiles {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $Path -Filter "*.json" -File | Sort-Object Name | Select-Object -ExpandProperty FullName)
}

function Read-EventLog {
    param(
        [string]$Path,
        [string]$Context
    )

    $events = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Failure -Message "$Context is missing: $Path"
        return @()
    }

    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $bytes=(New-Object System.Text.UTF8Encoding($false,$true)).GetBytes([string]$line)
            $document=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context "$Context line $lineNumber"
            $document.PSObject.Properties.Add([Management.Automation.PSNoteProperty]::new('__line_sha256',(Get-MorphospaceSha256Bytes $bytes)))
            $events.Add($document) | Out-Null
        } catch {
            Add-Failure -Message "$Context line $lineNumber is not valid JSON: $($_.Exception.Message)"
        }
    }
    return $events.ToArray()
}

function Test-V2EventInstance {
    param([object]$Event,[string]$Context)
    $required=@('schema','event_id','sequence','timestamp','run_id','session_id','project_id','unit_id','event_type','summary','previous_event_sha256','receipts');$actual=@($Event.PSObject.Properties.Name|Where-Object{$_-ne'__line_sha256'})
    foreach($name in $required){Assert-Contract ($actual-ccontains$name) "$Context v2 event is missing '$name'."};foreach($name in $actual){Assert-Contract ($required-ccontains$name) "$Context v2 event has unexpected '$name'."}
    foreach($field in @('event_id','run_id','project_id','unit_id')){Assert-Contract ([string]$Event.$field-match$script:PortableIdPattern) "$Context v2 '$field' is invalid."}
    Assert-Contract ($null-eq$Event.session_id-or[string]$Event.session_id-match'^[a-z0-9][a-z0-9-]{7,95}$') "$Context v2 session_id is invalid."
    Assert-Contract ([string]$Event.timestamp-match'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') "$Context v2 timestamp is not strict UTC."
    Assert-Contract (@('state-transition','decision','extraction','validation','commit','push','promotion','blocker')-ccontains[string]$Event.event_type) "$Context v2 event_type is invalid."
    Assert-Contract (-not[string]::IsNullOrWhiteSpace([string]$Event.summary)-and([string]$Event.summary).Length-le4096) "$Context v2 summary is invalid."
    Assert-Contract ([string]$Event.previous_event_sha256-match'^[0-9a-f]{64}$') "$Context v2 previous hash is invalid."
    Assert-Contract (@($Event.receipts).Count-le64) "$Context v2 has too many receipts."
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($reference in @($Event.receipts)){$names=@($reference.PSObject.Properties.Name);Assert-Contract ($names.Count-eq4-and$names-ccontains'role'-and$names-ccontains'path'-and$names-ccontains'schema'-and$names-ccontains'sha256') "$Context v2 receipt property set is invalid.";Assert-Contract ([string]$reference.role-match'^[a-z0-9][a-z0-9-]{1,95}$') "$Context v2 receipt role is invalid.";Assert-Contract ([string]$reference.schema-match'^[a-z0-9][a-z0-9_.-]{2,191}$') "$Context v2 receipt schema is invalid.";Assert-Contract ([string]$reference.sha256-match'^[0-9a-f]{64}$') "$Context v2 receipt hash is invalid.";Assert-Contract ((Test-Text $reference.path)-and$paths.Add(([string]$reference.path).Replace('\','/'))) "$Context v2 receipt path is empty or duplicated."}
}

function New-Bundle {
    param(
        [string]$SpecPath,
        [string]$LockPath,
        [string]$StatePath,
        [string[]]$CandidatePaths,
        [string[]]$UnitPaths,
        [string[]]$ReviewPaths,
        [string]$EventsPath
    )

    return [pscustomobject]@{
        SpecPath = $SpecPath
        LockPath = $LockPath
        StatePath = $StatePath
        CandidatePaths = @($CandidatePaths)
        UnitPaths = @($UnitPaths)
        ReviewPaths = @($ReviewPaths)
        EventsPath = $EventsPath
    }
}

function Test-ProjectBundle {
    param(
        [object]$Bundle,
        [string]$Context
    )

    $spec = Read-JsonDocument -Path $Bundle.SpecPath -Context "$Context project spec"
    $lock = Read-JsonDocument -Path $Bundle.LockPath -Context "$Context feature lock"
    $state = Read-JsonDocument -Path $Bundle.StatePath -Context "$Context workspace state"
    if ($null -eq $spec -or $null -eq $lock -or $null -eq $state) {
        return
    }

    $isProjectV2 = [string]$spec.schema -eq "rusty.morphospace.workflow.project_spec.v2"
    Assert-Contract ($isProjectV2 -or $spec.schema -eq "rusty.morphospace.workflow.project_spec.v1") "$Context project spec has the wrong schema ID."
    Assert-Contract (Test-Text $spec.project_id) "$Context project spec needs project_id."
    Assert-Contract ([int]$spec.revision -ge 1) "$Context project revision must be at least 1."
    Assert-Contract (Test-Text $spec.purpose) "$Context project spec needs purpose."
    Assert-Contract ($spec.activation_model.default -eq "disabled") "$Context default feature activation must be disabled."
    Assert-Contract ($spec.activation_model.unlisted_modules -eq "inert") "$Context unlisted modules must be inert."
    if ($isProjectV2) {
        Assert-Contract (Test-Text $spec.owner) "$Context project_spec.v2 needs an owner."
        Assert-Contract ($spec.activation_model.runtime_rule -eq "selected-lock-and-runtime-input") "$Context project_spec.v2 must require selected lock plus runtime input."
        foreach ($field in @("selected_features", "denied_features", "selected_modules", "denied_modules", "allowed_permissions", "denied_permissions", "data_classes")) {
            $values = @($spec.composition.$field | ForEach-Object { [string]$_ })
            foreach ($group in @($values | Group-Object | Where-Object { $_.Count -gt 1 })) {
                Add-Failure -Message "$Context project composition repeats '$($group.Name)' in $field."
            }
        }
        $selectedFeatureIds = @($spec.composition.selected_features | ForEach-Object { [string]$_ })
        $deniedFeatureIds = @($spec.composition.denied_features | ForEach-Object { [string]$_ })
        foreach ($id in $selectedFeatureIds) { Assert-Contract ($deniedFeatureIds -notcontains $id) "$Context feature '$id' is both selected and denied." }
        $selectedModuleIds = @($spec.composition.selected_modules | ForEach-Object { [string]$_ })
        $deniedModuleIds = @($spec.composition.denied_modules | ForEach-Object { [string]$_ })
        foreach ($id in $selectedModuleIds) { Assert-Contract ($deniedModuleIds -notcontains $id) "$Context module '$id' is both selected and denied." }
        Assert-Contract ($spec.release_policy.source_first -eq $true -and $spec.release_policy.planning_last -eq $true -and $spec.release_policy.force_push_allowed -eq $false) "$Context project_spec.v2 release policy must be source-first, planning-last, and no-force-push."
        Assert-Contract (Test-Text $spec.release_policy.commit_policy) "$Context project_spec.v2 needs a commit policy."
    }
    Test-NonEmptyTextArray -Value $spec.non_scope -Context "$Context project non_scope"

    $authorityEntries = @($spec.authority_map)
    Assert-Contract ($authorityEntries.Count -gt 0) "$Context authority_map must not be empty."
    Test-UniqueProperty -Items $authorityEntries -Property "parameter" -Context "$Context authority_map"
    $authorityOwners = @{}
    foreach ($entry in $authorityEntries) {
        if (Test-Text $entry.parameter) {
            Assert-Contract (Test-Text $entry.owner) "$Context authority '$($entry.parameter)' needs one owner."
            $authorityOwners[[string]$entry.parameter] = [string]$entry.owner
        }
    }

    $repositories = @($spec.repositories)
    Assert-Contract ($repositories.Count -gt 0) "$Context project must declare at least one repository."
    Test-UniqueProperty -Items $repositories -Property "repo_id" -Context "$Context repositories"
    $repositoryMap = @{}
    foreach ($repo in $repositories) {
        $repoId = [string]$repo.repo_id
        if (Test-Text $repoId) {
            $repositoryMap[$repoId] = $repo
        }
        Assert-Contract (Test-Text $repo.path) "$Context repository '$repoId' needs a path."
        Test-NonEmptyTextArray -Value $repo.allowed_paths -Context "$Context repository '$repoId' allowed_paths"
    }

    $modules = @($spec.modules)
    Test-UniqueProperty -Items $modules -Property "module_id" -Context "$Context modules"
    Test-UniqueProperty -Items $modules -Property "feature_id" -Context "$Context modules"
    $moduleMap = @{}
    foreach ($module in $modules) {
        $moduleId = [string]$module.module_id
        if (Test-Text $moduleId) {
            $moduleMap[$moduleId] = $module
        }
        Assert-Contract ($script:ModuleMaturityIds -contains [string]$module.maturity) "$Context module '$moduleId' has unknown maturity '$($module.maturity)'."
        Assert-Contract ($repositoryMap.ContainsKey([string]$module.source_repo)) "$Context module '$moduleId' references unknown source repo '$($module.source_repo)'."
        if ($isProjectV2) {
            Assert-Contract (Test-Text $module.contract_revision) "$Context project_spec.v2 module '$moduleId' needs contract_revision."
            Assert-Contract ($module.selected -is [bool]) "$Context project_spec.v2 module '$moduleId' needs Boolean selected."
            if ($module.selected -eq $true) { Assert-Contract ($selectedModuleIds -contains $moduleId) "$Context selected module '$moduleId' is absent from composition.selected_modules." }
        }
    }
    foreach ($module in $modules) {
        foreach ($dependency in @($module.dependencies)) {
            Assert-Contract ($moduleMap.ContainsKey([string]$dependency)) "$Context module '$($module.module_id)' references undeclared dependency '$dependency'."
        }
    }

    $validationProfiles = @($spec.validation_profiles)
    Assert-Contract ($validationProfiles.Count -gt 0) "$Context needs at least one validation profile."
    Test-UniqueProperty -Items $validationProfiles -Property "profile_id" -Context "$Context validation profiles"
    $validationProfileIds = @($validationProfiles | ForEach-Object { [string]$_.profile_id })
    foreach ($profile in $validationProfiles) {
        Test-NonEmptyTextArray -Value $profile.commands -Context "$Context validation profile '$($profile.profile_id)' commands"
    }
    if ($isProjectV2) {
        $acceptanceProfiles = @($spec.acceptance_profiles)
        Assert-Contract ($acceptanceProfiles.Count -gt 0) "$Context project_spec.v2 needs acceptance profiles."
        Test-UniqueProperty -Items $acceptanceProfiles -Property "profile_id" -Context "$Context acceptance profiles"
        foreach ($profile in $acceptanceProfiles) { Test-NonEmptyTextArray -Value $profile.commands -Context "$Context acceptance profile '$($profile.profile_id)' commands" }
    }

    $isLockV2 = [string]$lock.schema -eq "rusty.morphospace.workflow.feature_lock.v2"
    Assert-Contract (($isProjectV2 -and $isLockV2) -or (-not $isProjectV2 -and $lock.schema -eq "rusty.morphospace.workflow.feature_lock.v1")) "$Context feature lock schema must match the project protocol version."
    Assert-Contract ($lock.project_id -eq $spec.project_id) "$Context feature lock project_id does not match the project spec."
    Assert-Contract ($lock.default_activation -eq "disabled") "$Context feature lock default must be disabled."
    $features = @($lock.features)
    Test-UniqueProperty -Items $features -Property "feature_id" -Context "$Context feature lock"
    Test-UniqueProperty -Items $features -Property "module_id" -Context "$Context feature lock"
    if ($isLockV2) {
        Assert-Contract ([int]$lock.project_revision -eq [int]$spec.revision) "$Context feature_lock.v2 project revision drifted."
        Assert-Contract ($lock.activation_rule -eq "selected-lock-and-runtime-input") "$Context feature_lock.v2 activation rule drifted."
        Assert-Contract ([string]$lock.lock_fingerprint -eq (Get-FeatureLockFingerprint -Lock $lock)) "$Context feature_lock.v2 fingerprint is stale or damaged."
        $selectedLockIds = @($lock.selected_features | ForEach-Object { [string]$_ } | Sort-Object)
        $featureIds = @($features | ForEach-Object { [string]$_.feature_id } | Sort-Object)
        Assert-Contract (($selectedLockIds -join "|") -eq ($featureIds -join "|")) "$Context feature_lock.v2 selected_features must exactly match feature entries."
        foreach ($id in @($lock.denied_features)) { Assert-Contract ($selectedLockIds -notcontains [string]$id) "$Context feature_lock.v2 selects denied feature '$id'." }
        foreach ($requestedId in @($spec.composition.selected_features)) { Assert-Contract ($selectedLockIds -contains [string]$requestedId) "$Context feature_lock.v2 is missing requested feature '$requestedId'." }
        $exclusiveGroups = @{}
        $observedUnion = @{}
        foreach ($effectName in @("permissions", "services", "activities", "queries", "tools", "assets", "shaders", "native_libraries", "commands", "routes", "streams", "inputs", "scenes", "markers")) { $observedUnion[$effectName] = New-Object System.Collections.Generic.List[string] }
        foreach ($feature in $features) {
            $featureId = [string]$feature.feature_id; $moduleId = [string]$feature.module_id
            Assert-Contract ($feature.selected -eq $true -and $feature.run_activation_default -eq "disabled") "$Context feature_lock.v2 feature '$featureId' must be selected but default runtime-disabled."
            Assert-Contract ($moduleMap.ContainsKey($moduleId)) "$Context feature '$featureId' references undeclared module '$moduleId'."
            if ($moduleMap.ContainsKey($moduleId)) { Assert-Contract ($moduleMap[$moduleId].feature_id -eq $featureId) "$Context feature '$featureId' does not match module '$moduleId'." }
            Assert-Contract ([string]$feature.descriptor.sha256 -match "^[0-9a-fA-F]{64}$" -and [string]$feature.descriptor.source_revision -match "^[0-9a-fA-F]{40}$" -and [string]$feature.descriptor.source_sha256 -match "^[0-9a-fA-F]{64}$") "$Context feature '$featureId' lacks exact descriptor/source hashes."
            foreach ($dependency in @($feature.dependencies)) { Assert-Contract ($selectedLockIds -contains [string]$dependency) "$Context feature '$featureId' has unselected dependency '$dependency'." }
            foreach ($conflict in @($feature.conflicts)) { Assert-Contract ($selectedLockIds -notcontains [string]$conflict) "$Context feature '$featureId' conflicts with '$conflict'." }
            if ($null -ne $feature.exclusive_group) {
                $group = [string]$feature.exclusive_group
                Assert-Contract (-not $exclusiveGroups.ContainsKey($group)) "$Context feature '$featureId' repeats exclusive group '$group'."
                $exclusiveGroups[$group] = $featureId
            }
            Assert-Contract ($feature.activation.rule -eq "selected-lock-and-runtime-input" -and @($feature.activation.runtime_inputs).Count -gt 0) "$Context feature '$featureId' lacks explicit lock-bound runtime inputs."
            Test-UniqueProperty -Items @($feature.parameter_authorities) -Property "parameter" -Context "$Context feature '$featureId' parameter authorities"
            foreach ($parameterAuthority in @($feature.parameter_authorities)) {
                $parameter = [string]$parameterAuthority.parameter
                Assert-Contract ($authorityOwners.ContainsKey($parameter) -and $authorityOwners[$parameter] -eq [string]$parameterAuthority.owner) "$Context feature '$featureId' disagrees with authority for '$parameter'."
            }
            foreach ($effectName in $observedUnion.Keys) {
                foreach ($effect in @($feature.effects.$effectName | ForEach-Object { [string]$_ })) {
                    if (-not $observedUnion[$effectName].Contains($effect)) { $observedUnion[$effectName].Add($effect) | Out-Null }
                }
            }
        }
        foreach ($effectName in $observedUnion.Keys) {
            $expected = @($observedUnion[$effectName] | Sort-Object -Unique)
            $actual = @($lock.effect_union.$effectName | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            Assert-Contract (($expected -join "|") -eq ($actual -join "|")) "$Context feature_lock.v2 effect union drifted for '$effectName'."
        }
    } else {
        $enabledFeatureIds = @($features | Where-Object { $_.enabled -eq $true } | ForEach-Object { [string]$_.feature_id })
        foreach ($feature in $features) {
            $featureId = [string]$feature.feature_id; $moduleId = [string]$feature.module_id
            Assert-Contract ($moduleMap.ContainsKey($moduleId)) "$Context feature '$featureId' references undeclared module '$moduleId'."
            if ($moduleMap.ContainsKey($moduleId)) { Assert-Contract ($moduleMap[$moduleId].feature_id -eq $featureId) "$Context feature '$featureId' does not match module '$moduleId' feature_id." }
            foreach ($dependency in @($feature.dependencies)) { Assert-Contract ($moduleMap.ContainsKey([string]$dependency)) "$Context feature '$featureId' references undeclared dependency '$dependency'." }
            if ($feature.enabled -eq $true) {
                Assert-Contract ((Test-Text $feature.requested_by) -and (Test-Text $feature.descriptor)) "$Context enabled feature '$featureId' needs requested_by and descriptor."
                Assert-Contract ($feature.activation_receipt.required -eq $true -and (Test-Text $feature.activation_receipt.schema) -and (Test-Text $feature.activation_receipt.effective_marker)) "$Context enabled feature '$featureId' needs an effective-runtime receipt."
                Test-UniqueProperty -Items @($feature.parameter_authorities) -Property "parameter" -Context "$Context feature '$featureId' parameter authorities"
                foreach ($parameterAuthority in @($feature.parameter_authorities)) {
                    $parameter = [string]$parameterAuthority.parameter
                    Assert-Contract ($authorityOwners.ContainsKey($parameter) -and $authorityOwners[$parameter] -eq [string]$parameterAuthority.owner) "$Context enabled feature '$featureId' disagrees with authority for '$parameter'."
                }
            }
        }
        foreach ($feature in @($features | Where-Object { $_.enabled -eq $true })) { foreach ($conflict in @($feature.conflicts)) { Assert-Contract (-not ($enabledFeatureIds -contains [string]$conflict)) "$Context enabled feature '$($feature.feature_id)' conflicts with '$conflict'." } }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($path in @($Bundle.CandidatePaths)) {
        if (-not (Test-Text $path)) { continue }
        $candidate = Read-JsonDocument -Path $path -Context "$Context module candidate"
        if ($null -eq $candidate) { continue }
        $candidates.Add($candidate) | Out-Null
        Assert-Contract ($candidate.schema -eq "rusty.morphospace.workflow.module_candidate.v1") "$Context candidate '$($candidate.candidate_id)' has the wrong schema ID."
        Assert-Contract ($candidate.source_project -eq $spec.project_id) "$Context candidate '$($candidate.candidate_id)' source project does not match."
        Assert-Contract ($script:ModuleMaturityIds -contains [string]$candidate.maturity) "$Context candidate '$($candidate.candidate_id)' has unknown maturity."
        Assert-Contract ($script:ModuleMaturityIds -contains [string]$candidate.promotion_target) "$Context candidate '$($candidate.candidate_id)' has unknown promotion target."
        if ($script:ModuleMaturityNext.ContainsKey([string]$candidate.maturity)) {
            Assert-Contract ($script:ModuleMaturityNext[[string]$candidate.maturity] -contains [string]$candidate.promotion_target) "$Context candidate '$($candidate.candidate_id)' promotion target is not a valid next maturity state."
        }
        Assert-Contract (Test-Text $candidate.problem) "$Context candidate '$($candidate.candidate_id)' needs a neutral problem statement."
        Assert-Contract (Test-Text $candidate.neutral_contract) "$Context candidate '$($candidate.candidate_id)' needs a neutral contract."
        Test-NonEmptyTextArray -Value $candidate.owns -Context "$Context candidate '$($candidate.candidate_id)' owns"
        Test-NonEmptyTextArray -Value $candidate.does_not_own -Context "$Context candidate '$($candidate.candidate_id)' does_not_own"
        Test-NonEmptyTextArray -Value $candidate.app_specific_exclusions -Context "$Context candidate '$($candidate.candidate_id)' app-specific exclusions"
        Assert-Contract (@($candidate.provenance).Count -gt 0) "$Context candidate '$($candidate.candidate_id)' needs provenance."
        foreach ($source in @($candidate.provenance)) {
            Assert-Contract ((Test-Text $source.source) -and (Test-Text $source.license) -and (Test-Text $source.lesson) -and (Test-Text $source.rejected_overreach)) "$Context candidate '$($candidate.candidate_id)' has incomplete provenance."
        }
        Assert-Contract (@($candidate.consumers).Count -gt 0) "$Context candidate '$($candidate.candidate_id)' needs at least one consumer."
        Assert-Contract ((Test-Text $candidate.rollback.strategy) -and (Test-Text $candidate.rollback.acceptance)) "$Context candidate '$($candidate.candidate_id)' needs rollback strategy and acceptance."
    }
    Test-UniqueProperty -Items ($candidates.ToArray()) -Property "candidate_id" -Context "$Context module candidates"
    $candidateMap = @{}
    foreach ($candidate in $candidates.ToArray()) {
        $candidateMap[[string]$candidate.candidate_id] = $candidate
    }

    $units = New-Object System.Collections.Generic.List[object]
    foreach ($path in @($Bundle.UnitPaths)) {
        if (-not (Test-Text $path)) { continue }
        $unit = Read-JsonDocument -Path $path -Context "$Context iteration unit"
        if ($null -eq $unit) { continue }
        $units.Add($unit) | Out-Null
        Assert-Contract ([string]$unit.unit_id -match $script:PortableIdPattern) "$Context unit has invalid unit_id '$($unit.unit_id)'."
        Assert-Contract ($unit.schema -eq "rusty.morphospace.workflow.iteration_unit.v1") "$Context unit '$($unit.unit_id)' has the wrong schema ID."
        Assert-Contract ($unit.project_id -eq $spec.project_id) "$Context unit '$($unit.unit_id)' project_id does not match."
        Assert-Contract ($script:IterationStateIds -contains [string]$unit.status) "$Context unit '$($unit.unit_id)' has unknown status '$($unit.status)'."
        Assert-Contract (Test-Text $unit.objective) "$Context unit '$($unit.unit_id)' needs an objective."

        $unitTags = if ($unit.PSObject.Properties.Name -contains "tags") {
            @($unit.tags | ForEach-Object { [string]$_ })
        } else {
            @()
        }
        foreach ($tag in $unitTags) {
            Assert-Contract ($tag -match "^[a-z0-9][a-z0-9-]{1,127}$") "$Context unit '$($unit.unit_id)' has invalid tag '$tag'."
        }
        foreach ($tagGroup in @($unitTags | Group-Object)) {
            Assert-Contract ($tagGroup.Count -eq 1) "$Context unit '$($unit.unit_id)' repeats tag '$($tagGroup.Name)'."
        }

        $changeCategories = @($unit.change_categories | ForEach-Object { [string]$_ })
        Assert-Contract ($changeCategories.Count -gt 0) "$Context unit '$($unit.unit_id)' needs at least one change category."
        foreach ($categoryGroup in @($changeCategories | Group-Object)) {
            Assert-Contract ($categoryGroup.Count -eq 1) "$Context unit '$($unit.unit_id)' repeats change category '$($categoryGroup.Name)'."
        }
        foreach ($category in $changeCategories) {
            Assert-Contract ($script:ChangeCategories -contains $category) "$Context unit '$($unit.unit_id)' has unknown change category '$category'."
        }

        $instructionImpact = [string]$unit.instruction_impact
        $instructionSurfaces = @($unit.instruction_surfaces)
        Assert-Contract ($script:InstructionImpactValues -contains $instructionImpact) "$Context unit '$($unit.unit_id)' has unknown instruction impact '$instructionImpact'."
        Test-UniqueProperty -Items $instructionSurfaces -Property "path" -Context "$Context unit '$($unit.unit_id)' instruction surfaces"
        $triggeredCategories = @($changeCategories | Where-Object { $script:InstructionTriggerCategories -contains $_ })

        if ($instructionImpact -eq "none") {
            Assert-Contract ($instructionSurfaces.Count -eq 0) "$Context unit '$($unit.unit_id)' with no instruction impact must not list instruction surfaces."
            Assert-Contract (Test-Text $unit.instruction_none_justification) "$Context unit '$($unit.unit_id)' with no instruction impact needs an explicit justification."
        } else {
            Assert-Contract ($instructionSurfaces.Count -gt 0) "$Context unit '$($unit.unit_id)' instruction impact needs at least one surface."
            Assert-Contract (-not (Test-Text $unit.instruction_none_justification)) "$Context unit '$($unit.unit_id)' must leave instruction_none_justification null unless impact is none."
        }

        foreach ($surface in $instructionSurfaces) {
            Assert-Contract ($script:InstructionSurfaceKinds -contains [string]$surface.surface_kind) "$Context unit '$($unit.unit_id)' has unknown instruction surface kind '$($surface.surface_kind)'."
            Assert-Contract (Test-Text $surface.path) "$Context unit '$($unit.unit_id)' instruction surface needs a path."
            Assert-Contract (Test-Text $surface.owner) "$Context unit '$($unit.unit_id)' instruction surface '$($surface.path)' needs an owner."
            Assert-Contract (Test-Text $surface.change_reason) "$Context unit '$($unit.unit_id)' instruction surface '$($surface.path)' needs a change reason."
            Assert-Contract (@("update", "review-no-change") -contains [string]$surface.action) "$Context unit '$($unit.unit_id)' instruction surface '$($surface.path)' has unknown action."
            Assert-Contract (@("planned", "complete") -contains [string]$surface.status) "$Context unit '$($unit.unit_id)' instruction surface '$($surface.path)' has unknown status."
            Assert-Contract (Test-Text $surface.validation) "$Context unit '$($unit.unit_id)' instruction surface '$($surface.path)' needs validation."
            if ($surface.surface_kind -eq "skill") {
                Assert-Contract (Test-Text $surface.skill_id) "$Context unit '$($unit.unit_id)' skill surface '$($surface.path)' needs skill_id."
            } else {
                Assert-Contract ($null -eq $surface.skill_id) "$Context unit '$($unit.unit_id)' non-skill surface '$($surface.path)' must use null skill_id."
            }
        }

        if ($triggeredCategories.Count -gt 0) {
            Assert-Contract ($instructionImpact -eq "update") "$Context unit '$($unit.unit_id)' changes instruction-triggering categories and must use instruction_impact 'update'."
            $agentSurfaces = @($instructionSurfaces | Where-Object { $_.surface_kind -eq "agents" })
            $routerSurfaces = @($instructionSurfaces | Where-Object { $_.surface_kind -eq "readme" -or $_.surface_kind -eq "router-doc" })
            Assert-Contract ($agentSurfaces.Count -gt 0) "$Context unit '$($unit.unit_id)' needs the nearest AGENTS.md instruction surface."
            Assert-Contract ($routerSurfaces.Count -gt 0) "$Context unit '$($unit.unit_id)' needs a README or router-doc instruction surface."

            $requiredSkillIds = New-Object System.Collections.Generic.List[string]
            foreach ($category in $triggeredCategories) {
                if ($script:InstructionSkillRouting.ContainsKey($category)) {
                    foreach ($skillId in @($script:InstructionSkillRouting[$category])) {
                        if (-not $requiredSkillIds.Contains([string]$skillId)) {
                            $requiredSkillIds.Add([string]$skillId) | Out-Null
                        }
                    }
                }
            }
            foreach ($requiredSkillId in $requiredSkillIds.ToArray()) {
                $matchingSkill = @($instructionSurfaces | Where-Object {
                    $_.surface_kind -eq "skill" -and $_.skill_id -eq $requiredSkillId
                })
                Assert-Contract ($matchingSkill.Count -eq 1) "$Context unit '$($unit.unit_id)' needs one instruction surface for relevant skill '$requiredSkillId'."
                if ($matchingSkill.Count -eq 1) {
                    Assert-Contract ($matchingSkill[0].action -eq "update") "$Context unit '$($unit.unit_id)' relevant skill '$requiredSkillId' must be updated."
                }
            }

            foreach ($requiredSurface in @($agentSurfaces + $routerSurfaces)) {
                Assert-Contract ($requiredSurface.action -eq "update") "$Context unit '$($unit.unit_id)' required instruction surface '$($requiredSurface.path)' must be updated."
            }

            if ($unit.status -eq "accepted") {
                foreach ($requiredSurface in @($agentSurfaces + $routerSurfaces)) {
                    Assert-Contract ($requiredSurface.status -eq "complete") "$Context accepted unit '$($unit.unit_id)' has incomplete instruction surface '$($requiredSurface.path)'."
                }
                foreach ($requiredSkillId in $requiredSkillIds.ToArray()) {
                    $matchingSkill = @($instructionSurfaces | Where-Object {
                        $_.surface_kind -eq "skill" -and $_.skill_id -eq $requiredSkillId
                    })
                    if ($matchingSkill.Count -eq 1) {
                        Assert-Contract ($matchingSkill[0].status -eq "complete") "$Context accepted unit '$($unit.unit_id)' has incomplete relevant skill '$requiredSkillId'."
                    }
                }
            }
        } elseif ($unit.status -eq "accepted" -and $instructionImpact -ne "none") {
            foreach ($surface in $instructionSurfaces) {
                Assert-Contract ($surface.status -eq "complete") "$Context accepted unit '$($unit.unit_id)' has incomplete instruction surface '$($surface.path)'."
            }
        }

        Assert-Contract (@($unit.allowed_repositories).Count -gt 0) "$Context unit '$($unit.unit_id)' needs allowed repositories."
        $writeRepositoryIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($allowedRepo in @($unit.allowed_repositories)) {
            $repoId = [string]$allowedRepo.repo_id
            Assert-Contract ($writeRepositoryIds.Add($repoId)) "$Context unit '$($unit.unit_id)' repeats writable repository '$repoId'."
            Assert-Contract ($repositoryMap.ContainsKey($repoId)) "$Context unit '$($unit.unit_id)' references undeclared repo '$repoId'."
            Test-NonEmptyTextArray -Value $allowedRepo.allowed_paths -Context "$Context unit '$($unit.unit_id)' repo '$repoId' allowed paths"
            if ($repositoryMap.ContainsKey($repoId)) {
                foreach ($candidatePath in @($allowedRepo.allowed_paths)) {
                    Assert-Contract (Test-PathInScope -Candidate ([string]$candidatePath) -Allowed @($repositoryMap[$repoId].allowed_paths)) "$Context unit '$($unit.unit_id)' path '$candidatePath' expands project scope for '$repoId'."
                }
            }
        }
        $readOnlyDependencies = if ($unit.PSObject.Properties.Name -contains 'read_only_dependencies') { @($unit.read_only_dependencies) } else { @() }
        foreach ($dependency in $readOnlyDependencies) {
            $repoId = [string]$dependency.repo_id
            Assert-Contract (-not $writeRepositoryIds.Contains($repoId)) "$Context unit '$($unit.unit_id)' cannot make '$repoId' both writable scope and a read-only dependency."
            Assert-Contract ($repositoryMap.ContainsKey($repoId)) "$Context unit '$($unit.unit_id)' read-only dependency references undeclared repo '$repoId'."
            Test-NonEmptyTextArray -Value $dependency.paths -Context "$Context unit '$($unit.unit_id)' read-only dependency '$repoId' paths"
            Assert-Contract (Test-Text ([string]$dependency.purpose)) "$Context unit '$($unit.unit_id)' read-only dependency '$repoId' needs a purpose."
            Assert-Contract (Test-Text ([string]$dependency.verification)) "$Context unit '$($unit.unit_id)' read-only dependency '$repoId' needs a verification command."
            if ($repositoryMap.ContainsKey($repoId)) {
                foreach ($candidatePath in @($dependency.paths)) {
                    Assert-Contract (Test-PathInScope -Candidate ([string]$candidatePath) -Allowed @($repositoryMap[$repoId].allowed_paths)) "$Context unit '$($unit.unit_id)' read-only dependency path '$candidatePath' expands project scope for '$repoId'."
                }
            }
        }
        Test-NonEmptyTextArray -Value $unit.non_scope -Context "$Context unit '$($unit.unit_id)' non_scope"
        Assert-Contract (@($unit.acceptance).Count -gt 0) "$Context unit '$($unit.unit_id)' needs acceptance proofs."
        Test-UniqueProperty -Items @($unit.acceptance) -Property "acceptance_id" -Context "$Context unit '$($unit.unit_id)' acceptance"
        foreach ($acceptance in @($unit.acceptance)) {
            Assert-Contract ((Test-Text $acceptance.proof) -and (Test-Text $acceptance.command)) "$Context unit '$($unit.unit_id)' has incomplete acceptance proof."
        }
        Assert-Contract ($script:RiskTiers -contains [string]$unit.risk_tier) "$Context unit '$($unit.unit_id)' has unknown risk tier."
        Assert-Contract ($script:DeviceRequirements -contains [string]$unit.device_requirement) "$Context unit '$($unit.unit_id)' has unknown device requirement."
        Assert-Contract ($script:PushCheckpoints -contains [string]$unit.push_checkpoint) "$Context unit '$($unit.unit_id)' has unknown push checkpoint."
        Assert-Contract (@($unit.validation).Count -gt 0) "$Context unit '$($unit.unit_id)' needs validation commands."
        foreach ($validation in @($unit.validation)) {
            Assert-Contract ($validationProfileIds -contains [string]$validation.profile_id) "$Context unit '$($unit.unit_id)' references unknown validation profile '$($validation.profile_id)'."
            Assert-Contract (Test-Text $validation.command) "$Context unit '$($unit.unit_id)' has an empty validation command."
        }
        Test-NonEmptyTextArray -Value $unit.outputs -Context "$Context unit '$($unit.unit_id)' outputs"
        Assert-Contract (Test-Text $unit.commit_policy) "$Context unit '$($unit.unit_id)' needs a commit policy."
    }
    Test-UniqueProperty -Items ($units.ToArray()) -Property "unit_id" -Context "$Context iteration units"
    $unitMap = @{}
    foreach ($unit in $units.ToArray()) {
        $unitMap[[string]$unit.unit_id] = $unit
    }
    foreach ($unit in $units.ToArray()) {
        foreach ($prerequisite in @($unit.prerequisites)) {
            Assert-Contract ($unitMap.ContainsKey([string]$prerequisite)) "$Context unit '$($unit.unit_id)' references missing prerequisite '$prerequisite'."
        }
    }
    $events = @(Read-EventLog -Path $Bundle.EventsPath -Context "$Context iteration event log")
    Test-UniqueProperty -Items $events -Property "event_id" -Context "$Context iteration events"
    $eventMap = @{}
    $previousSequence = 0
    $previousEvent = $null
    foreach ($event in $events) {
        $eventId = [string]$event.event_id
        if (Test-Text $eventId) { $eventMap[$eventId] = $event }
        $isEventV2=[string]$event.schema-eq'rusty.morphospace.workflow.iteration_event.v2'
        Assert-Contract ($isEventV2-or[string]$event.schema-eq'rusty.morphospace.workflow.iteration_event.v1') "$Context event '$eventId' has the wrong schema ID."
        if($isEventV2){Test-V2EventInstance -Event $event -Context "$Context event '$eventId'";Assert-Contract ([int]$event.sequence-eq$previousSequence+1) "$Context v2 event '$eventId' sequence must extend the exact prior sequence.";if($null-ne$previousEvent-and[string]$previousEvent.schema-eq'rusty.morphospace.workflow.iteration_event.v2'){Assert-Contract ([string]$event.previous_event_sha256-ceq[string]$previousEvent.__line_sha256) "$Context v2 event '$eventId' previous hash does not bind the prior v2 line."}}
        Assert-Contract ($event.project_id -eq $spec.project_id) "$Context event '$eventId' project_id does not match."
        Assert-Contract ([int]$event.sequence -gt $previousSequence) "$Context event sequences must be strictly increasing."
        $previousSequence = [int]$event.sequence
        $previousEvent = $event
        if ($null -ne $event.unit_id) {
            Assert-Contract ($unitMap.ContainsKey([string]$event.unit_id)) "$Context event '$eventId' references missing unit '$($event.unit_id)'."
        }
    }

    # A corrective unit may supersede an immutable historical active/validating
    # unit without rewriting that unit artifact or its earlier event prefix.
    # The additive state-transition event is the projection override and must
    # use the exact `<old-unit>-superseded-by-<current-unit>` identity.
    $supersededInFlightIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($event in $events) {
        $eventId = [string]$event.event_id
        $match = [regex]::Match($eventId, '^(?<old>[a-z0-9][a-z0-9-]{1,127})-superseded-by-(?<current>[a-z0-9][a-z0-9-]{1,127})$')
        if (-not $match.Success) { continue }
        $oldId = $match.Groups['old'].Value
        $currentId = $match.Groups['current'].Value
        Assert-Contract ($event.event_type -eq "state-transition") "$Context supersession event '$eventId' must be a state transition."
        Assert-Contract ([string]$event.unit_id -eq $oldId) "$Context supersession event '$eventId' must target old unit '$oldId'."
        Assert-Contract ($unitMap.ContainsKey($oldId)) "$Context supersession event '$eventId' references missing old unit '$oldId'."
        Assert-Contract ($unitMap.ContainsKey($currentId)) "$Context supersession event '$eventId' references missing current unit '$currentId'."
        if ($unitMap.ContainsKey($oldId)) {
            Assert-Contract (@("active", "validating") -contains [string]$unitMap[$oldId].status) "$Context supersession event '$eventId' may override only an immutable active/validating unit."
        }
        if ($unitMap.ContainsKey($currentId)) {
            Assert-Contract (@("active", "validating", "accepted") -contains [string]$unitMap[$currentId].status) "$Context supersession replacement '$currentId' is not current or accepted."
        }
        [void]$supersededInFlightIds.Add($oldId)
    }
    $activeUnits = @($units | Where-Object {
        $_.status -eq "active" -and -not $supersededInFlightIds.Contains([string]$_.unit_id)
    })
    Assert-Contract ($activeUnits.Count -le 1) "$Context has more than one effective active iteration unit."
    $inFlightUnits = @($units | Where-Object {
        ($_.status -eq "active" -or $_.status -eq "validating") -and
        -not $supersededInFlightIds.Contains([string]$_.unit_id)
    })
    Assert-Contract ($inFlightUnits.Count -le 1) "$Context has more than one effective in-flight iteration unit."

    $isStateV2 = [string]$state.schema -eq "rusty.morphospace.workflow.workspace_state.v2"
    Assert-Contract (($isProjectV2 -and $isStateV2) -or (-not $isProjectV2 -and $state.schema -eq "rusty.morphospace.workflow.workspace_state.v1")) "$Context workspace state schema must match the project protocol version."
    Assert-Contract ($state.project_id -eq $spec.project_id) "$Context workspace state project_id does not match."
    Assert-Contract ([int]$state.plan_revision -ge 1) "$Context workspace plan revision must be at least 1."
    if ($null -eq $state.current_unit) {
        Assert-Contract ($inFlightUnits.Count -eq 0) "$Context has an in-flight unit but workspace state has no current_unit."
    } else {
        $currentId = [string]$state.current_unit
        Assert-Contract ($unitMap.ContainsKey($currentId)) "$Context workspace state references missing current unit '$currentId'."
        if ($unitMap.ContainsKey($currentId)) {
            Assert-Contract ($unitMap[$currentId].status -eq "active" -or $unitMap[$currentId].status -eq "validating") "$Context current unit '$currentId' is not active or validating."
        }
        Assert-Contract ($inFlightUnits.Count -eq 1) "$Context workspace state needs exactly one in-flight current unit."
    }
    if ($null -ne $state.next_ready_unit) {
        $nextId = [string]$state.next_ready_unit
        Assert-Contract ($unitMap.ContainsKey($nextId)) "$Context workspace state references missing next-ready unit '$nextId'."
        if ($unitMap.ContainsKey($nextId)) {
            Assert-Contract ($unitMap[$nextId].status -eq "ready") "$Context next-ready unit '$nextId' is not ready."
        }
    }
    if ($null -ne $state.last_event_id) {
        Assert-Contract ($eventMap.ContainsKey([string]$state.last_event_id)) "$Context workspace state references missing last event '$($state.last_event_id)'."
    }
    foreach ($dirtyRepo in @($state.dirty_repositories)) {
        Assert-Contract ($repositoryMap.ContainsKey([string]$dirtyRepo)) "$Context workspace state references undeclared dirty repo '$dirtyRepo'."
    }
    if ($isStateV2) {
        Test-UniqueProperty -Items @($state.repository_heads) -Property "repo_id" -Context "$Context workspace repository heads"
        foreach ($head in @($state.repository_heads)) {
            Assert-Contract ($repositoryMap.ContainsKey([string]$head.repo_id)) "$Context workspace state has a head for undeclared repo '$($head.repo_id)'."
            Assert-Contract ([string]$head.head -match "^[0-9a-fA-F]{40}$") "$Context workspace repo '$($head.repo_id)' has invalid HEAD."
        }
        if ($null -ne $state.module_registry.lock_revision) {
            Assert-Contract ([int]$state.module_registry.lock_revision -eq [int]$lock.revision -and [string]$state.module_registry.lock_fingerprint -eq [string]$lock.lock_fingerprint) "$Context module registry does not match feature lock revision/fingerprint."
        }
        Test-UniqueProperty -Items @($state.module_registry.modules) -Property "module_id" -Context "$Context workspace module registry"
        foreach ($registered in @($state.module_registry.modules)) {
            Assert-Contract ($moduleMap.ContainsKey([string]$registered.module_id)) "$Context workspace registry references undeclared module '$($registered.module_id)'."
            Assert-Contract ($repositoryMap.ContainsKey([string]$registered.owner_repo)) "$Context workspace registry module '$($registered.module_id)' has undeclared owner repo."
        }
        Test-UniqueProperty -Items @($state.capability_registry) -Property "capability_id" -Context "$Context workspace capability registry"
        if (@($units | Where-Object { $_.status -eq "accepted" }).Count -gt 0) {
            Assert-Contract (Test-Text $state.last_accepted_receipt) "$Context accepted units require last_accepted_receipt in workspace_state.v2."
        }
    }
    if ($null -ne $state.pending_push_bundle) {
        foreach ($unitId in @($state.pending_push_bundle.unit_ids)) {
            Assert-Contract ($unitMap.ContainsKey([string]$unitId)) "$Context pending push bundle references missing unit '$unitId'."
        }
        foreach ($repoId in @($state.pending_push_bundle.repo_ids)) {
            Assert-Contract ($repositoryMap.ContainsKey([string]$repoId)) "$Context pending push bundle references undeclared repo '$repoId'."
        }
    }

    $reviews = New-Object System.Collections.Generic.List[object]
    foreach ($path in @($Bundle.ReviewPaths)) {
        if (-not (Test-Text $path)) { continue }
        $review = Read-JsonDocument -Path $path -Context "$Context promotion review"
        if ($null -eq $review) { continue }
        $reviews.Add($review) | Out-Null
        Assert-Contract ($review.schema -eq "rusty.morphospace.workflow.promotion_review.v1") "$Context review '$($review.review_id)' has the wrong schema ID."
        Assert-Contract ($candidateMap.ContainsKey([string]$review.candidate_id)) "$Context review '$($review.review_id)' references missing candidate '$($review.candidate_id)'."
        if ($candidateMap.ContainsKey([string]$review.candidate_id)) {
            $candidate = $candidateMap[[string]$review.candidate_id]
            Assert-Contract ($candidate.module_id -eq $review.module_id) "$Context review '$($review.review_id)' module does not match its candidate."
            Assert-Contract ($candidate.maturity -eq $review.from_maturity) "$Context review '$($review.review_id)' from_maturity does not match its candidate."
        }
        Assert-Contract ($script:ModuleMaturityIds -contains [string]$review.from_maturity) "$Context review '$($review.review_id)' has unknown from_maturity."
        Assert-Contract ($script:ModuleMaturityIds -contains [string]$review.target_maturity) "$Context review '$($review.review_id)' has unknown target_maturity."
        if ($script:ModuleMaturityNext.ContainsKey([string]$review.from_maturity)) {
            Assert-Contract ($script:ModuleMaturityNext[[string]$review.from_maturity] -contains [string]$review.target_maturity) "$Context review '$($review.review_id)' target is not a valid next maturity state."
        }
        $gateEntries = @($review.gates)
        Test-UniqueProperty -Items $gateEntries -Property "gate_id" -Context "$Context review '$($review.review_id)' gates"
        foreach ($gate in $gateEntries) {
            Assert-Contract ($script:PromotionGates -contains [string]$gate.gate_id) "$Context review '$($review.review_id)' has unknown gate '$($gate.gate_id)'."
            Assert-Contract (Test-Text $gate.evidence) "$Context review '$($review.review_id)' gate '$($gate.gate_id)' needs evidence."
        }
        if ($review.decision -eq "accepted" -and $review.target_maturity -eq "stable") {
            foreach ($gateId in $script:PromotionGates) {
                $matchingGate = @($gateEntries | Where-Object { $_.gate_id -eq $gateId })
                Assert-Contract ($matchingGate.Count -eq 1) "$Context stable review '$($review.review_id)' is missing gate '$gateId'."
                if ($matchingGate.Count -eq 1) {
                    Assert-Contract ($matchingGate[0].result -eq "pass") "$Context stable review '$($review.review_id)' gate '$gateId' did not pass."
                }
            }
            Assert-Contract ($review.rollback_verified -eq $true) "$Context stable review '$($review.review_id)' must verify rollback."
            if ($candidateMap.ContainsKey([string]$review.candidate_id)) {
                $independentConsumers = @($candidateMap[[string]$review.candidate_id].consumers | Where-Object {
                    ($_.kind -eq "independent-app" -or $_.kind -eq "conformance-harness") -and $_.contract_only -eq $true
                })
                Assert-Contract ($independentConsumers.Count -gt 0) "$Context stable review '$($review.review_id)' needs an independent consumer or conformance harness."
            }
        }
    }
    Test-UniqueProperty -Items ($reviews.ToArray()) -Property "review_id" -Context "$Context promotion reviews"

    foreach ($candidate in @($candidates | Where-Object { $_.maturity -eq "stable" })) {
        $accepted = @($reviews | Where-Object {
            $_.candidate_id -eq $candidate.candidate_id -and $_.target_maturity -eq "stable" -and $_.decision -eq "accepted"
        })
        Assert-Contract ($accepted.Count -eq 1) "$Context stable candidate '$($candidate.candidate_id)' needs one accepted stable review."
    }
}

$lifecyclePath = Join-Path $RepoRoot "manifests\workflow-lifecycle.portable.json"
$lifecycle = Read-JsonDocument -Path $lifecyclePath -Context "workflow lifecycle manifest"
if ($null -ne $lifecycle) {
    Assert-Contract ($lifecycle.schema -eq "rusty.morphospace.work_environment.workflow_lifecycle.v1") "Workflow lifecycle manifest has the wrong schema ID."
    $script:ModuleMaturityIds = @($lifecycle.module_maturity | ForEach-Object { [string]$_.id })
    $script:ModuleMaturityNext = @{}
    foreach ($entry in @($lifecycle.module_maturity)) {
        $script:ModuleMaturityNext[[string]$entry.id] = @($entry.next | ForEach-Object { [string]$_ })
    }
    $script:IterationStateIds = @($lifecycle.iteration_states | ForEach-Object { [string]$_.id })
    $script:PromotionGates = @($lifecycle.promotion_gates | ForEach-Object { [string]$_ })
    $script:RiskTiers = @($lifecycle.risk_tiers | ForEach-Object { [string]$_ })
    $script:DeviceRequirements = @($lifecycle.device_requirements | ForEach-Object { [string]$_ })
    $script:PushCheckpoints = @($lifecycle.push_checkpoints | ForEach-Object { [string]$_ })
    $script:ChangeCategories = @($lifecycle.change_categories | ForEach-Object { [string]$_ })
    $script:InstructionImpactValues = @($lifecycle.instruction_sync.impact_values | ForEach-Object { [string]$_ })
    $script:InstructionSurfaceKinds = @($lifecycle.instruction_sync.surface_kinds | ForEach-Object { [string]$_ })
    $script:InstructionTriggerCategories = @($lifecycle.instruction_sync.trigger_categories | ForEach-Object { [string]$_ })
    $script:InstructionSkillRouting = @{}
    foreach ($entry in @($lifecycle.instruction_sync.skill_routing)) {
        $script:InstructionSkillRouting[[string]$entry.change_category] = @($entry.skill_ids | ForEach-Object { [string]$_ })
    }
    Test-UniqueProperty -Items @($lifecycle.module_maturity) -Property "id" -Context "module maturity lifecycle"
    Test-UniqueProperty -Items @($lifecycle.iteration_states) -Property "id" -Context "iteration state lifecycle"
    Assert-Contract ($lifecycle.feature_activation.default -eq "disabled") "Workflow default activation must be disabled."
    Assert-Contract ($lifecycle.feature_activation.unlisted_modules -eq "inert") "Workflow unlisted modules must be inert."
    Assert-Contract ($lifecycle.feature_activation.protocol_v2_rule -eq "selected-lock-and-runtime-input") "Workflow protocol-v2 activation rule must require selected lock plus runtime input."
} else {
    $script:ModuleMaturityIds = @()
    $script:ModuleMaturityNext = @{}
    $script:IterationStateIds = @()
    $script:PromotionGates = @()
    $script:RiskTiers = @()
    $script:DeviceRequirements = @()
    $script:PushCheckpoints = @()
    $script:ChangeCategories = @()
    $script:InstructionImpactValues = @()
    $script:InstructionSurfaceKinds = @()
    $script:InstructionTriggerCategories = @()
    $script:InstructionSkillRouting = @{}
}

$schemaRoot = Join-Path $RepoRoot "schemas"
$schemaFiles = @(Get-ChildItem -LiteralPath $schemaRoot -Filter "*.schema.json" -File | Sort-Object Name)
$requiredSchemaNames = @(
    "authority-failure-report.schema.json",
    "authority-host-capabilities.schema.json",
    "authority-input-capsule.schema.json",
    "authority-preflight-result.schema.json",
    "authority-runner-release.schema.json",
    "authority-stage-result.schema.json",
    "claim-baseline.schema.json",
    "current-unit-protocol.schema.json",
    "executed-push-receipt.schema.json",
    "feature-descriptor.schema.json",
    "feature-lock.schema.json",
    "feature-lock-v2.schema.json",
    "event-transaction-completion.schema.json",
    "event-transaction-intent.schema.json",
    "inflight-adoption-receipt.schema.json",
    "interruption-receipt.schema.json",
    "iteration-event.schema.json",
    "iteration-event-v2.schema.json",
    "iteration-unit.schema.json",
    "module-candidate.schema.json",
    "pending-quarantine-authorization.schema.json",
    "pending-quarantine-completion.schema.json",
    "project-spec.schema.json",
    "project-spec-v2.schema.json",
    "promotion-review.schema.json",
    "push-bundle-plan.schema.json",
    "repository-map.schema.json",
    "legacy-event-prefix-anchor.schema.json",
    "owner-validator-registry.schema.json",
    "revision-set.schema.json",
    "state-transition-completion.schema.json",
    "state-transition-intent.schema.json",
    "validation-receipt.schema.json",
    "unit-ownership.schema.json",
    "validation-action-v2.schema.json",
    "validation-evidence-v2.schema.json",
    "validation-execution.schema.json",
    "validation-receipt-v2.schema.json",
    "validator-trust-anchor-migration.schema.json",
    "timestamp-anomaly-projection.schema.json",
    "work-unit-automation-receipt.schema.json",
    "workspace-state.schema.json",
    "workspace-state-v2.schema.json"
)
foreach ($requiredSchemaName in $requiredSchemaNames) {
    Assert-Contract (Test-Path -LiteralPath (Join-Path $schemaRoot $requiredSchemaName) -PathType Leaf) "Required workflow schema is missing: $requiredSchemaName"
}
foreach ($schemaFile in $schemaFiles) {
    $schemaDocument = Read-JsonDocument -Path $schemaFile.FullName -Context "schema '$($schemaFile.Name)'"
    if ($null -eq $schemaDocument) { continue }
    Assert-Contract ($schemaDocument.'$schema' -eq "https://json-schema.org/draft/2020-12/schema") "Schema '$($schemaFile.Name)' must use JSON Schema 2020-12."
    Assert-Contract (Test-Text $schemaDocument.'$id') "Schema '$($schemaFile.Name)' needs a canonical id."
    Assert-Contract ($schemaDocument.type -eq "object") "Schema '$($schemaFile.Name)' must describe an object."
}

$templatesRoot = Join-Path $RepoRoot "templates"
$templateBundle = New-Bundle `
    -SpecPath (Join-Path $templatesRoot "project.spec.example.json") `
    -LockPath (Join-Path $templatesRoot "feature.lock.example.json") `
    -StatePath (Join-Path $templatesRoot "workspace.state.example.json") `
    -CandidatePaths @((Join-Path $templatesRoot "module-candidate.example.json")) `
    -UnitPaths @((Join-Path $templatesRoot "iteration-unit.example.json")) `
    -ReviewPaths @((Join-Path $templatesRoot "promotion-review.example.json")) `
    -EventsPath (Join-Path $templatesRoot "iteration-events.example.jsonl")
Test-ProjectBundle -Bundle $templateBundle -Context "portable example"

$templateV2Bundle = New-Bundle `
    -SpecPath (Join-Path $templatesRoot "project.spec.v2.example.json") `
    -LockPath (Join-Path $templatesRoot "feature.lock.v2.example.json") `
    -StatePath (Join-Path $templatesRoot "workspace.state.v2.example.json") `
    -CandidatePaths @() `
    -UnitPaths @() `
    -ReviewPaths @() `
    -EventsPath (Join-Path $templatesRoot "iteration-events.v2.example.jsonl")
Test-ProjectBundle -Bundle $templateV2Bundle -Context "portable v2 example"

$executedPushTemplate = Join-Path $templatesRoot "executed-push-receipt.example.json"
$executedPushValidator = Join-Path $RepoRoot "scripts\Test-ExecutedPushReceipt.ps1"
Assert-Contract (Test-Path -LiteralPath $executedPushTemplate -PathType Leaf) "Required executed-push receipt example is missing."
Assert-Contract (Test-Path -LiteralPath $executedPushValidator -PathType Leaf) "Required executed-push receipt validator is missing."
if ((Test-Path -LiteralPath $executedPushTemplate -PathType Leaf) -and (Test-Path -LiteralPath $executedPushValidator -PathType Leaf)) {
    try {
        & $executedPushValidator -Path $executedPushTemplate | Out-Null
    } catch {
        Add-Failure -Message "Executed-push receipt example failed semantic validation: $($_.Exception.Message)"
    }
}

if ($WorkspaceRoot) {
    $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $workspaceBundle = New-Bundle `
        -SpecPath (Join-Path $resolvedWorkspace "project.spec.json") `
        -LockPath (Join-Path $resolvedWorkspace "feature.lock.json") `
        -StatePath (Join-Path $resolvedWorkspace "workspace.state.json") `
        -CandidatePaths (Get-JsonFiles (Join-Path $resolvedWorkspace "module-candidates")) `
        -UnitPaths (Get-JsonFiles (Join-Path $resolvedWorkspace "iteration-units")) `
        -ReviewPaths (Get-JsonFiles (Join-Path $resolvedWorkspace "promotion-reviews")) `
        -EventsPath (Join-Path $resolvedWorkspace "iteration-events.jsonl")
    Test-ProjectBundle -Bundle $workspaceBundle -Context "project workspace"
}

if ($script:Failures.Count -gt 0) {
    Write-Host "Workflow contract validation failures:"
    foreach ($failure in $script:Failures) {
        Write-Host " - $failure"
    }
    throw "Workflow contract validation failed with $($script:Failures.Count) error(s)."
}

$scope = if ($WorkspaceRoot) { "portable examples and project workspace" } else { "portable examples" }
Write-Host "Workflow contract validation passed for $scope."
