param(
    [string]$RepoRoot = "",
    [string]$WorkspaceRoot = "",
    [string]$RepositoryMapPath = "",
    [switch]$SkipOwnerSelfTests
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:PortableIdPattern = "^[a-z0-9][a-z0-9-]{1,127}$"
$script:LocalRepositoryMap = @{}
if ($RepositoryMapPath) {
    $mapDocument = Get-Content -LiteralPath $RepositoryMapPath -Raw | ConvertFrom-Json
    foreach ($entry in @($mapDocument.repositories)) { $script:LocalRepositoryMap[[string]$entry.repo_id] = [string]$entry.path }
}
Import-Module (Join-Path $RepoRoot 'scripts\lib\MorphospaceProtocolCommon.psm1') -Force

function Invoke-IsolatedWorkflowSelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @()
    )

    $hostPath = [Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($hostPath) -or -not [IO.File]::Exists($hostPath)) {
        $hostPath = (Get-Command pwsh -ErrorAction Stop).Source
    }
    $output = @(& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        throw "Isolated workflow self-test '$([IO.Path]::GetFileName($Path))' failed with exit $exitCode.$([Environment]::NewLine)$detail"
    }
}

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

function Test-PortableRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.StartsWith("/") -or $Path -match "^[A-Za-z]:/" -or $Path.Contains("\")) { return $false }
    return $Path -notmatch "(^|/)\.\.?($|/)"
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

function Get-FileSha256 {
    param([string]$Path)
    return Get-MorphospaceSha256Bytes ([IO.File]::ReadAllBytes($Path))
}

function Test-ExactLegacyMappings {
    param([string[]]$UnknownValues, [object[]]$Mappings, [string[]]$CurrentValues, [string]$Context, [bool]$AllowHistoricalOnly = $false)
    $Mappings = @($Mappings | Where-Object { $null -ne $_ })
    $unknown = @($UnknownValues | Sort-Object -Unique)
    $legacy = @($Mappings | ForEach-Object { [string]$_.legacy } | Sort-Object)
    Assert-Contract (($unknown -join "|") -eq ($legacy -join "|")) "$Context mappings must exactly cover the unknown legacy values."
    Test-UniqueProperty -Items $Mappings -Property "legacy" -Context "$Context mappings"
    foreach ($mapping in $Mappings) {
        Assert-Contract (Test-Text $mapping.retained_as) "$Context mapping '$($mapping.legacy)' must retain its domain meaning as a tag or limitation."
        if ($null -eq $mapping.current) {
            Assert-Contract $AllowHistoricalOnly "$Context mapping '$($mapping.legacy)' cannot use historical-only semantics."
        } else {
            Assert-Contract ($CurrentValues -contains [string]$mapping.current) "$Context mapping '$($mapping.legacy)' targets unknown current value '$($mapping.current)'."
        }
    }
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

    $workspaceRoot = Split-Path -Parent $Bundle.StatePath
    $historicalAdoptions = @{}
    $reconstructionByOriginal = @{}
    $reconstructionReferences = @()
    if ($state.PSObject.Properties.Name -contains "historical_unit_adoption_reconstructions") { $reconstructionReferences = @($state.historical_unit_adoption_reconstructions) }
    Test-UniqueProperty -Items $reconstructionReferences -Property "path" -Context "$Context historical-unit adoption reconstruction references"
    if ($reconstructionReferences.Count -gt 0) {
        Import-Module (Join-Path $RepoRoot "scripts/lib/MorphospaceHistoricalAdoptionReconstruction.psm1") -Force
    }
    foreach ($reference in $reconstructionReferences) {
        $relativePath = [string]$reference.path
        Assert-Contract ($relativePath -match '^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$') "$Context historical reconstruction reference has a noncanonical path."
        $recordPath = Join-Path $workspaceRoot ($relativePath -replace "/", [IO.Path]::DirectorySeparatorChar)
        $validated = $null
        $recordDocument = Read-JsonDocument -Path $recordPath -Context "$Context historical reconstruction record"
        $anchorId = if ($recordDocument) { [string]$recordDocument.immutable_anchor.repository } else { "" }
        Assert-Contract ($script:LocalRepositoryMap.ContainsKey($anchorId)) "$Context historical reconstruction '$relativePath' lacks a mapped immutable anchor repository."
        try {
            if ($script:LocalRepositoryMap.ContainsKey($anchorId)) {
                $validated = Test-MorphospaceHistoricalAdoptionReconstruction -Path $recordPath -WorkspaceRoot $workspaceRoot -AnchorRepository $script:LocalRepositoryMap[$anchorId]
            }
        }
        catch { Add-Failure -Message "$Context historical reconstruction '$relativePath' rejected: $($_.Exception.Message)" }
        if ($null -eq $validated) { continue }
        Assert-Contract ([string]$reference.sha256 -ceq [string]$validated.sha256) "$Context historical reconstruction '$relativePath' reference hash drifted."
        Assert-Contract ([string]$validated.document.project_id -ceq [string]$spec.project_id) "$Context historical reconstruction '$relativePath' belongs to another project."
        $originalPath = [string]$validated.document.damaged_original.path
        Assert-Contract (-not $reconstructionByOriginal.ContainsKey($originalPath)) "$Context historical adoption '$originalPath' has conflicting reconstructions."
        if (-not $reconstructionByOriginal.ContainsKey($originalPath)) { $reconstructionByOriginal[$originalPath] = $validated }
    }
    $adoptionReferences = @()
    $consumedReconstructions = @{}
    if ($state.PSObject.Properties.Name -contains "historical_unit_adoption_receipts") { $adoptionReferences = @($state.historical_unit_adoption_receipts) }
    Test-UniqueProperty -Items $adoptionReferences -Property "path" -Context "$Context historical-unit adoption references"
    foreach ($reference in $adoptionReferences) {
        $relativePath = Normalize-RelativePath ([string]$reference.path)
        Assert-Contract (Test-PortableRelativePath $relativePath) "$Context historical-unit adoption reference has a non-portable path."
        $receiptPath = Join-Path $workspaceRoot ($relativePath -replace "/", [IO.Path]::DirectorySeparatorChar)
        $receipt = Read-JsonDocument -Path $receiptPath -Context "$Context historical-unit adoption receipt"
        if ($null -eq $receipt) { continue }
        $observedHash = Get-FileSha256 $receiptPath
        if ([string]$reference.sha256 -cne $observedHash) {
            Assert-Contract ($reconstructionByOriginal.ContainsKey($relativePath)) "$Context historical-unit adoption receipt '$relativePath' hash drifted without a reconstruction."
            if ($reconstructionByOriginal.ContainsKey($relativePath)) {
                $projection = $reconstructionByOriginal[$relativePath]
                $consumedReconstructions[$relativePath] = $true
                Assert-Contract ([string]$projection.document.damaged_original.expected_sha256 -ceq [string]$reference.sha256) "$Context reconstruction does not preserve the original expected hash for '$relativePath'."
                Assert-Contract ([string]$projection.document.damaged_original.observed_sha256 -ceq $observedHash) "$Context reconstruction does not preserve the observed hash for '$relativePath'."
                $receipt = $projection.receipt
            }
        } else {
            Assert-Contract (-not $reconstructionByOriginal.ContainsKey($relativePath)) "$Context exact historical adoption '$relativePath' must not use a damage reconstruction."
        }
        Assert-Contract ([string]$receipt.schema -eq "rusty.morphospace.workflow.historical_unit_adoption_receipt.v1") "$Context historical-unit adoption receipt '$relativePath' has the wrong schema."
        Assert-Contract ([string]$receipt.project_id -eq [string]$spec.project_id) "$Context historical-unit adoption receipt '$relativePath' belongs to another project."
        Assert-Contract ((Test-Text $receipt.source_workflow.release) -and ([string]$receipt.source_workflow.commit -match '^[0-9a-f]{40}$')) "$Context historical-unit adoption receipt '$relativePath' lacks source workflow identity."
        Test-UniqueProperty -Items @($receipt.units) -Property "unit_id" -Context "$Context historical-unit adoption receipt '$relativePath'"
        foreach ($entry in @($receipt.units)) {
            $unitId = [string]$entry.unit_id
            Assert-Contract (-not $historicalAdoptions.ContainsKey($unitId)) "$Context historical unit '$unitId' appears in more than one adoption receipt."
            if (-not $historicalAdoptions.ContainsKey($unitId)) { $historicalAdoptions[$unitId] = $entry }
        }
    }
    foreach ($originalPath in @($reconstructionByOriginal.Keys)) {
        Assert-Contract ($consumedReconstructions.ContainsKey([string]$originalPath)) "$Context historical reconstruction for '$originalPath' does not correspond to one damaged adoption reference."
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
            Assert-Contract (Test-PortableRelativePath ([string]$feature.descriptor.path)) "$Context feature '$featureId' descriptor path must be portable and project-spec-relative."
            Assert-Contract (Test-PortableRelativePath ([string]$feature.descriptor.source_path)) "$Context feature '$featureId' source path must be portable and repository-relative."
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
        $effectiveChangeCategories = @($changeCategories | ForEach-Object {
            if ($script:ChangeCategories -contains $_) { $_ }
            elseif ($script:ChangeCategoryAliases.ContainsKey($_)) { $script:ChangeCategoryAliases[$_] }
            else { $_ }
        })
        Assert-Contract ($changeCategories.Count -gt 0) "$Context unit '$($unit.unit_id)' needs at least one change category."
        foreach ($categoryGroup in @($changeCategories | Group-Object)) {
            Assert-Contract ($categoryGroup.Count -eq 1) "$Context unit '$($unit.unit_id)' repeats change category '$($categoryGroup.Name)'."
        }
        $unitId = [string]$unit.unit_id
        $adoption = if ($historicalAdoptions.ContainsKey($unitId)) { $historicalAdoptions[$unitId] } else { $null }
        if ($null -ne $adoption) {
            $unitPath = Normalize-RelativePath ([IO.Path]::GetRelativePath((Split-Path -Parent $Bundle.StatePath), $path))
            Assert-Contract ($unitPath -eq [string]$adoption.unit_path) "$Context historical unit '$unitId' adoption path drifted."
            Assert-Contract ((Get-FileSha256 $path) -eq [string]$adoption.unit_sha256) "$Context historical unit '$unitId' bytes drifted."
            Assert-Contract (@("accepted", "blocked") -contains [string]$unit.status) "$Context historical adoption cannot be used by current or future unit '$unitId'."
            Assert-Contract ([string]$unit.status -eq [string]$adoption.terminal_status) "$Context historical unit '$unitId' terminal status drifted."
            $unknownCategories = @($changeCategories | Where-Object { $script:ChangeCategories -notcontains $_ })
            Test-ExactLegacyMappings -UnknownValues $unknownCategories -Mappings @($adoption.normalization.change_categories) -CurrentValues $script:ChangeCategories -Context "$Context historical unit '$unitId' change-category"
        } else {
            foreach ($category in $changeCategories) {
                Assert-Contract (($script:ChangeCategories -contains $category) -or $script:ChangeCategoryAliases.ContainsKey($category)) "$Context unit '$unitId' has unknown change category '$category'."
            }
        }

        $instructionImpact = [string]$unit.instruction_impact
        $instructionSurfaces = @($unit.instruction_surfaces)
        Assert-Contract ($script:InstructionImpactValues -contains $instructionImpact) "$Context unit '$($unit.unit_id)' has unknown instruction impact '$instructionImpact'."
        Test-UniqueProperty -Items $instructionSurfaces -Property "path" -Context "$Context unit '$($unit.unit_id)' instruction surfaces"
        $triggeredCategories = @($effectiveChangeCategories | Where-Object { $script:InstructionTriggerCategories -contains $_ } | Sort-Object -Unique)

        $effectiveInstructionImpact = $instructionImpact
        $effectiveInstructionSurfaces = @($instructionSurfaces)
        if ($null -ne $adoption) {
            $expectedImpactMappings = if ($triggeredCategories.Count -gt 0 -and $instructionImpact -ne "update") { @($instructionImpact) } else { @() }
            $impactMappings = if ($adoption.normalization.PSObject.Properties.Name -contains "instruction_impact") { @($adoption.normalization.instruction_impact) } else { @() }
            Test-ExactLegacyMappings -UnknownValues $expectedImpactMappings -Mappings $impactMappings -CurrentValues @("update") -Context "$Context historical unit '$unitId' instruction-impact"
            if ($expectedImpactMappings.Count -eq 1 -and $impactMappings.Count -eq 1) {
                $effectiveInstructionImpact = [string]$impactMappings[0].current
            }

            $expectedSurfacePaths = if ($triggeredCategories.Count -gt 0) {
                @($instructionSurfaces | Where-Object {
                    ($_.surface_kind -eq "agents" -or $_.surface_kind -eq "readme" -or $_.surface_kind -eq "router-doc") -and $_.action -ne "update"
                } | ForEach-Object { [string]$_.path } | Sort-Object)
            } else { @() }
            $surfaceMappings = if ($adoption.normalization.PSObject.Properties.Name -contains "instruction_surfaces") { @($adoption.normalization.instruction_surfaces | Where-Object { $null -ne $_ }) } else { @() }
            $mappedSurfacePaths = @($surfaceMappings | ForEach-Object { [string]$_.path } | Sort-Object)
            Assert-Contract (($expectedSurfacePaths -join "|") -eq ($mappedSurfacePaths -join "|")) "$Context historical unit '$unitId' instruction-surface mappings must exactly cover required legacy actions."
            if ($surfaceMappings.Count -gt 0) { Test-UniqueProperty -Items $surfaceMappings -Property "path" -Context "$Context historical unit '$unitId' instruction-surface mappings" }
            foreach ($mapping in $surfaceMappings) {
                $matchingSurface = @($instructionSurfaces | Where-Object { [string]$_.path -ceq [string]$mapping.path })
                Assert-Contract ($matchingSurface.Count -eq 1) "$Context historical unit '$unitId' instruction-surface mapping '$($mapping.path)' has no exact surface."
                if ($matchingSurface.Count -eq 1) {
                    Assert-Contract ([string]$matchingSurface[0].action -ceq [string]$mapping.legacy_action) "$Context historical unit '$unitId' instruction-surface mapping '$($mapping.path)' legacy action drifted."
                }
                Assert-Contract ([string]$mapping.current_action -ceq "update") "$Context historical unit '$unitId' instruction-surface mapping '$($mapping.path)' must target update."
                Assert-Contract (Test-Text $mapping.retained_as) "$Context historical unit '$unitId' instruction-surface mapping '$($mapping.path)' must retain its historical meaning."
            }
            $effectiveInstructionSurfaces = @($instructionSurfaces | ForEach-Object {
                $surface = $_ | Select-Object *
                $mapping = @($surfaceMappings | Where-Object { [string]$_.path -ceq [string]$surface.path })
                if ($mapping.Count -eq 1) { $surface.action = [string]$mapping[0].current_action }
                $surface
            })
        }

        if ($effectiveInstructionImpact -eq "none") {
            Assert-Contract ($instructionSurfaces.Count -eq 0) "$Context unit '$($unit.unit_id)' with no instruction impact must not list instruction surfaces."
            Assert-Contract (Test-Text $unit.instruction_none_justification) "$Context unit '$($unit.unit_id)' with no instruction impact needs an explicit justification."
        } else {
            Assert-Contract ($instructionSurfaces.Count -gt 0) "$Context unit '$($unit.unit_id)' instruction impact needs at least one surface."
            Assert-Contract (-not (Test-Text $unit.instruction_none_justification)) "$Context unit '$($unit.unit_id)' must leave instruction_none_justification null unless impact is none."
        }

        foreach ($surface in $effectiveInstructionSurfaces) {
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
            Assert-Contract ($effectiveInstructionImpact -eq "update") "$Context unit '$($unit.unit_id)' changes instruction-triggering categories and must use instruction_impact 'update'."
            $agentSurfaces = @($effectiveInstructionSurfaces | Where-Object { $_.surface_kind -eq "agents" })
            $routerSurfaces = @($effectiveInstructionSurfaces | Where-Object { $_.surface_kind -eq "readme" -or $_.surface_kind -eq "router-doc" })
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
                $matchingSkill = @($effectiveInstructionSurfaces | Where-Object {
                    $_.surface_kind -eq "skill" -and $_.skill_id -eq $requiredSkillId
                })
                Assert-Contract ($matchingSkill.Count -eq 1) "$Context unit '$($unit.unit_id)' needs one instruction surface for relevant skill '$requiredSkillId'."
                if ($matchingSkill.Count -eq 1) {
                    Assert-Contract (@("update", "review-no-change") -contains [string]$matchingSkill[0].action) "$Context unit '$($unit.unit_id)' relevant skill '$requiredSkillId' must be updated or explicitly reviewed without change."
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
                    $matchingSkill = @($effectiveInstructionSurfaces | Where-Object {
                        $_.surface_kind -eq "skill" -and $_.skill_id -eq $requiredSkillId
                    })
                    if ($matchingSkill.Count -eq 1) {
                        Assert-Contract ($matchingSkill[0].status -eq "complete") "$Context accepted unit '$($unit.unit_id)' has incomplete relevant skill '$requiredSkillId'."
                    }
                }
            }
        } elseif ($unit.status -eq "accepted" -and $effectiveInstructionImpact -ne "none") {
            foreach ($surface in $effectiveInstructionSurfaces) {
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
        if ($unit.PSObject.Properties.Name -contains "source_composition") {
            $composition = $unit.source_composition
            $compositionModes = @("observed-working-copies", "exact-lock", "exact-materialization")
            Assert-Contract ($compositionModes -contains [string]$composition.mode) "$Context unit '$($unit.unit_id)' has unknown source composition mode '$($composition.mode)'."
            if ($composition.mode -eq "observed-working-copies") {
                Assert-Contract ($null -eq $composition.lock_path -and $null -eq $composition.materialization_receipt) "$Context unit '$($unit.unit_id)' observed source composition must not cite a lock or materialization receipt."
            } elseif ($composition.mode -eq "exact-lock") {
                Assert-Contract ((Test-Text $composition.lock_path) -and $null -eq $composition.materialization_receipt) "$Context unit '$($unit.unit_id)' exact-lock source composition needs a lock and no materialization receipt."
            } elseif ($composition.mode -eq "exact-materialization") {
                Assert-Contract ((Test-Text $composition.lock_path) -and (Test-Text $composition.materialization_receipt)) "$Context unit '$($unit.unit_id)' exact materialization needs both lock and materialization receipt."
            }
        }
        if ($unit.PSObject.Properties.Name -contains "resource_requirements") {
            $resourceKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($requirement in @($unit.resource_requirements)) {
                $resourceKind = [string]$requirement.resource_kind
                $resourceId = [string]$requirement.resource_id
                if ($null -eq $adoption) {
                    Assert-Contract ($script:ResourceKinds -contains $resourceKind) "$Context unit '$($unit.unit_id)' has unknown resource kind '$resourceKind'."
                }
                Assert-Contract (Test-Text $resourceId) "$Context unit '$($unit.unit_id)' resource '$resourceKind' needs an ID."
                Assert-Contract (@("exclusive", "shared-read") -contains [string]$requirement.mode) "$Context unit '$($unit.unit_id)' resource '$resourceKind/$resourceId' has unknown mode."
                Assert-Contract (@("none", "before-write", "before-run") -contains [string]$requirement.claim_timing) "$Context unit '$($unit.unit_id)' resource '$resourceKind/$resourceId' has unknown claim timing."
                Assert-Contract ($resourceKeys.Add("$resourceKind`n$resourceId")) "$Context unit '$($unit.unit_id)' repeats resource '$resourceKind/$resourceId'."
            }
            if ($unit.device_requirement -eq "required") {
                $headsetRequirements = @($unit.resource_requirements | Where-Object { $_.resource_kind -eq "headset" -and $_.mode -eq "exclusive" -and $_.claim_timing -eq "before-run" })
                Assert-Contract ($headsetRequirements.Count -gt 0) "$Context unit '$($unit.unit_id)' requires a device and must declare an exclusive headset claim before run."
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
            if ($null -eq $adoption) { Assert-Contract ($validationProfileIds -contains [string]$validation.profile_id) "$Context unit '$($unit.unit_id)' references unknown validation profile '$($validation.profile_id)'." }
            Assert-Contract (Test-Text $validation.command) "$Context unit '$($unit.unit_id)' has an empty validation command."
        }
        if ($null -ne $adoption) {
            $unknownProfiles = @($unit.validation | ForEach-Object { [string]$_.profile_id } | Where-Object { $validationProfileIds -notcontains $_ })
            Test-ExactLegacyMappings -UnknownValues $unknownProfiles -Mappings @($adoption.normalization.validation_profiles) -CurrentValues $validationProfileIds -Context "$Context historical unit '$unitId' validation-profile"
            $unknownResources = if ($unit.PSObject.Properties.Name -contains "resource_requirements") { @($unit.resource_requirements | ForEach-Object { [string]$_.resource_kind } | Where-Object { $script:ResourceKinds -notcontains $_ }) } else { @() }
            Test-ExactLegacyMappings -UnknownValues $unknownResources -Mappings @($adoption.normalization.resource_kinds) -CurrentValues $script:ResourceKinds -Context "$Context historical unit '$unitId' resource-kind" -AllowHistoricalOnly $true
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
    foreach ($adoptedUnitId in @($historicalAdoptions.Keys)) {
        Assert-Contract ($unitMap.ContainsKey([string]$adoptedUnitId)) "$Context historical adoption contains extra or missing unit '$adoptedUnitId'."
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
    foreach ($adoptedUnitId in @($historicalAdoptions.Keys)) {
        $entry = $historicalAdoptions[$adoptedUnitId]
        $terminalEventId = [string]$entry.terminal_evidence.event_id
        Assert-Contract ($eventMap.ContainsKey($terminalEventId)) "$Context historical unit '$adoptedUnitId' lacks its declared terminal event '$terminalEventId'."
        if ($eventMap.ContainsKey($terminalEventId)) {
            $terminalEvent = $eventMap[$terminalEventId]
            Assert-Contract ([string]$terminalEvent.unit_id -eq $adoptedUnitId) "$Context historical unit '$adoptedUnitId' terminal event belongs to another unit."
            if ($null -ne $entry.terminal_evidence.receipt_path) {
                Assert-Contract (@($terminalEvent.receipts) -contains [string]$entry.terminal_evidence.receipt_path) "$Context historical unit '$adoptedUnitId' terminal event does not reference its declared evidence receipt."
            }
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
        if ($state.PSObject.Properties.Name -contains "repository_checkpoints") {
            Test-UniqueProperty -Items @($state.repository_checkpoints) -Property "repo_id" -Context "$Context workspace repository checkpoints"
            foreach ($checkpoint in @($state.repository_checkpoints)) {
                $checkpointRepo = [string]$checkpoint.repo_id
                Assert-Contract ($repositoryMap.ContainsKey($checkpointRepo)) "$Context workspace state has a checkpoint for undeclared repo '$checkpointRepo'."
                foreach ($field in @("observed_head", "claimed_head", "validated_head", "accepted_head")) {
                    $value = $checkpoint.$field
                    Assert-Contract ($null -eq $value -or [string]$value -match "^[0-9a-fA-F]{40}$") "$Context workspace repo '$checkpointRepo' has invalid $field."
                }
                Assert-Contract ($null -eq $checkpoint.composition_fingerprint -or [string]$checkpoint.composition_fingerprint -match "^[0-9a-fA-F]{64}$") "$Context workspace repo '$checkpointRepo' has an invalid composition fingerprint."
                Assert-Contract ($null -eq $checkpoint.claimed_head -or $null -ne $checkpoint.observed_head) "$Context workspace repo '$checkpointRepo' cannot be claimed before it is observed."
                Assert-Contract ($null -eq $checkpoint.validated_head -or [string]$checkpoint.validated_head -ceq [string]$checkpoint.claimed_head) "$Context workspace repo '$checkpointRepo' validated revision must equal its claimed revision."
                Assert-Contract ($null -eq $checkpoint.accepted_head -or [string]$checkpoint.accepted_head -ceq [string]$checkpoint.validated_head) "$Context workspace repo '$checkpointRepo' accepted revision must equal its validated revision."
                Assert-Contract ($null -eq $checkpoint.composition_fingerprint -or $null -ne $checkpoint.claimed_head) "$Context workspace repo '$checkpointRepo' composition fingerprint requires a claimed revision."
            }
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
        $pendingRepoIds = @($state.pending_push_bundle.repo_ids | ForEach-Object { [string]$_ })
        $externalPending = @($pendingRepoIds | Where-Object { -not $repositoryMap.ContainsKey($_) })
        if ($state.pending_push_bundle.PSObject.Properties.Name -contains "planning_transport_repo_id") {
            $planningTransportId = [string]$state.pending_push_bundle.planning_transport_repo_id
            Assert-Contract ($externalPending.Count -eq 1 -and $externalPending[0] -ceq $planningTransportId) "$Context pending planned publication must name exactly one external planning transport repository."
            Assert-Contract ($pendingRepoIds[-1] -ceq $planningTransportId) "$Context external planning transport repository must be last."
        } else {
            Assert-Contract ($externalPending.Count -eq 0) "$Context legacy pending push bundle references undeclared repo '$($externalPending -join ',')'."
        }
    }

    $reviews = New-Object System.Collections.Generic.List[object]
    foreach ($path in @($Bundle.ReviewPaths)) {
        if (-not (Test-Text $path)) { continue }
        $review = Read-JsonDocument -Path $path -Context "$Context promotion review"
        if ($null -eq $review) { continue }
        $reviews.Add($review) | Out-Null
        $isReviewV2 = [string]$review.schema -eq "rusty.morphospace.workflow.promotion_review.v2"
        Assert-Contract ($isReviewV2 -or $review.schema -eq "rusty.morphospace.workflow.promotion_review.v1") "$Context review '$($review.review_id)' has the wrong schema ID."
        if ($isReviewV2) {
            Assert-Contract (Test-Text $review.extraction_receipt.path) "$Context v2 review '$($review.review_id)' needs a module extraction receipt path."
            Assert-Contract ([string]$review.extraction_receipt.sha256 -match "^[0-9a-f]{64}$") "$Context v2 review '$($review.review_id)' needs an exact module extraction receipt hash."
            Assert-Contract ([string]$review.extraction_receipt.source_composition_fingerprint -match "^[0-9a-f]{64}$") "$Context v2 review '$($review.review_id)' needs an exact source composition fingerprint."
        }
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
            Assert-Contract (($script:PromotionGates -contains [string]$gate.gate_id) -or ($isReviewV2 -and [string]$gate.gate_id -eq "extraction-boundary")) "$Context review '$($review.review_id)' has unknown gate '$($gate.gate_id)'."
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
            if ($isReviewV2) {
                $extractionGate = @($gateEntries | Where-Object { $_.gate_id -eq "extraction-boundary" })
                Assert-Contract ($extractionGate.Count -eq 1) "$Context stable v2 review '$($review.review_id)' is missing gate 'extraction-boundary'."
                if ($extractionGate.Count -eq 1) {
                    Assert-Contract ($extractionGate[0].result -eq "pass") "$Context stable v2 review '$($review.review_id)' extraction boundary did not pass."
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
    $script:ChangeCategoryAliases = @{}
    foreach ($alias in @($lifecycle.change_category_aliases)) {
        Assert-Contract ((Test-Text $alias.alias) -and (Test-Text $alias.canonical)) "Workflow change-category alias entries must be complete."
        Assert-Contract ($script:ChangeCategories -contains [string]$alias.canonical) "Workflow change-category alias '$($alias.alias)' has an unknown canonical target."
        Assert-Contract (-not $script:ChangeCategoryAliases.ContainsKey([string]$alias.alias)) "Workflow change-category alias '$($alias.alias)' is duplicated."
        Assert-Contract ($script:ChangeCategories -notcontains [string]$alias.alias) "Workflow change-category alias '$($alias.alias)' collides with a canonical category."
        $script:ChangeCategoryAliases[[string]$alias.alias] = [string]$alias.canonical
    }
    $script:ResourceKinds = @("repo-path", "build-output", "android-package", "headset", "property-namespace", "staging-namespace", "bridge-port")
    $script:InstructionImpactValues = @($lifecycle.instruction_sync.impact_values | ForEach-Object { [string]$_ })
    $script:InstructionSurfaceKinds = @($lifecycle.instruction_sync.surface_kinds | ForEach-Object { [string]$_ })
    $script:InstructionTriggerCategories = @($lifecycle.instruction_sync.trigger_categories | ForEach-Object { [string]$_ })
    $script:InstructionSkillRouting = @{}
    foreach ($entry in @($lifecycle.instruction_sync.skill_routing)) {
        $category = [string]$entry.change_category
        $skillIds = @($entry.skill_ids | ForEach-Object { [string]$_ })
        Assert-Contract ($script:InstructionTriggerCategories -ccontains $category) "Workflow skill routing contains unknown trigger category '$category'."
        Assert-Contract (-not $script:InstructionSkillRouting.ContainsKey($category)) "Workflow skill routing duplicates trigger category '$category'."
        Assert-Contract ($skillIds.Count -gt 0) "Workflow skill routing for '$category' must name at least one skill."
        Assert-Contract ($skillIds.Count -eq @($skillIds | Sort-Object -Unique -CaseSensitive).Count) "Workflow skill routing for '$category' contains duplicate skills."
        $script:InstructionSkillRouting[$category] = $skillIds
    }
    Assert-Contract ($script:InstructionSkillRouting.Count -eq $script:InstructionTriggerCategories.Count) "Workflow skill routing must cover every trigger category exactly once."
    foreach ($category in $script:InstructionTriggerCategories) {
        Assert-Contract ($script:InstructionSkillRouting.ContainsKey($category)) "Workflow skill routing omits trigger category '$category'."
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
    $script:ResourceKinds = @()
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
    "planned-publication-accounting-receipt.schema.json",
    "prepared-push-retirement-v1.schema.json",
    "prepared-publication-reconstruction-v1.schema.json",
    "blocker-resolution-receipt-v1.schema.json",
    "blocker-resolution-correction-receipt-v1.schema.json",
    "legacy-embedded-push-bundle-plan-v1.schema.json",
    "work-unit-automation-receipt-v2.schema.json",
    "published-planning-authority-adoption.schema.json",
    "published-prerequisite-suffix-reconciliation.schema.json",
    "historical-release-closure-receipt.schema.json",
    "historical-unit-adoption-receipt.schema.json",
    "historical-unit-adoption-reconstruction.schema.json",
    "feature-descriptor.schema.json",
    "feature-lock.schema.json",
    "feature-lock-v2.schema.json",
    "event-transaction-completion.schema.json",
    "event-transaction-intent.schema.json",
    "inflight-adoption-receipt.schema.json",
    "interruption-receipt.schema.json",
    "planning-workspace-projection.schema.json",
    "iteration-event.schema.json",
    "iteration-event-v2.schema.json",
    "iteration-unit.schema.json",
    "module-candidate.schema.json",
    "module-extraction-receipt.schema.json",
    "pending-quarantine-authorization.schema.json",
    "pending-quarantine-completion.schema.json",
    "project-spec.schema.json",
    "project-spec-v2.schema.json",
    "promotion-review.schema.json",
    "promotion-review-v2.schema.json",
    "resource-claim.schema.json",
    "push-bundle-plan.schema.json",
    "repository-map.schema.json",
    "release-capsule.schema.json",
    "release-capsule-validation-receipt.schema.json",
    "legacy-event-prefix-anchor.schema.json",
    "owner-validator-registry.schema.json",
    "revision-set.schema.json",
    "state-transition-completion.schema.json",
    "state-transition-intent.schema.json",
    "source-composition-lock.schema.json",
    "source-materialization-receipt.schema.json",
    "validation-receipt.schema.json",
    "unit-ownership.schema.json",
    "validation-action-v2.schema.json",
    "validation-evidence-v2.schema.json",
    "validation-execution.schema.json",
    "validation-receipt-v2.schema.json",
    "validator-trust-anchor-migration.schema.json",
    "timestamp-anomaly-projection.schema.json",
    "unplanned-publication-closure.schema.json",
    "unplanned-publication-closure-v2.schema.json",
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
foreach ($contractExample in @(
    [pscustomobject]@{ Template = "planning-workspace-projection.example.json"; Schema = "planning-workspace-projection.schema.json" },
    [pscustomobject]@{ Template = "planning-workspace-projection-v2.example.json"; Schema = "planning-workspace-projection.schema.json" },
    [pscustomobject]@{ Template = "planning-workspace-projection-v3.example.json"; Schema = "planning-workspace-projection.schema.json" },
    [pscustomobject]@{ Template = "published-planning-authority-adoption.example.json"; Schema = "published-planning-authority-adoption.schema.json" },
    [pscustomobject]@{ Template = "published-active-planning-authority-adoption.example.json"; Schema = "published-planning-authority-adoption.schema.json" },
    [pscustomobject]@{ Template = "historical-unit-adoption-reconstruction.example.json"; Schema = "historical-unit-adoption-reconstruction.schema.json" },
    [pscustomobject]@{ Template = "unplanned-publication-closure-v2.example.json"; Schema = "unplanned-publication-closure.schema.json" }
)) {
    $examplePath = Join-Path $templatesRoot $contractExample.Template
    $exampleSchemaPath = Join-Path $schemaRoot $contractExample.Schema
    try {
        Assert-Contract (Get-Content -LiteralPath $examplePath -Raw | Test-Json -SchemaFile $exampleSchemaPath -ErrorAction Stop) "Contract example '$($contractExample.Template)' does not conform to '$($contractExample.Schema)'."
    } catch {
        Add-Failure -Message "Contract example '$($contractExample.Template)' schema validation failed: $($_.Exception.Message)"
    }
}
$automationReceiptSchema = Join-Path $schemaRoot "work-unit-automation-receipt.schema.json"
$automationAdoptionBinding = [ordered]@{
    adoption_id = "example-authority-adoption"
    path = "receipts/example-authority-adoption.json"
    sha256 = ("a" * 64)
}
$automationReceipt = [ordered]@{
    schema = "rusty.morphospace.workflow.work_unit_automation_receipt.v1"
    project_id = "example-project"
    unit_id = "example-unit"
    action = "AdoptPublishedPlanningAuthority"
    timestamp = "2026-07-25T00:00:00Z"
    executed = $true
    transition = "published-planning-authority-adopted"
    status_before = "accepted"
    status_after = "accepted"
    current_unit_before = $null
    current_unit_after = $null
    preservation = [ordered]@{
        git_mutation_performed = $false
        device_mutation_performed = $false
        force_push_allowed = $false
        repository_states = @()
    }
    validation_matrix = @()
    graph_scope = [ordered]@{}
    adoption_receipt = $null
    publication_closure = $null
    published_planning_authority_adoption = $automationAdoptionBinding
    planned_publication = $null
    planning_suffix_rewrite_recovery = $null
    published_prerequisite_suffix_reconciliation = $null
    push_plan = $null
    event_id = "example-unit-planning-authority-adopted-0001"
}
$automationReceiptJson = $automationReceipt | ConvertTo-Json -Depth 16
Assert-Contract ($automationReceiptJson | Test-Json -SchemaFile $automationReceiptSchema -ErrorAction Stop) "Adoption automation receipt with a bound adoption was rejected."
$automationReceipt.published_planning_authority_adoption = $null
Assert-Contract (-not ($automationReceipt | ConvertTo-Json -Depth 16 | Test-Json -SchemaFile $automationReceiptSchema -ErrorAction SilentlyContinue)) "Adoption automation receipt without an adoption binding was accepted."
$automationReceipt.action = "Inspect"
Assert-Contract ($automationReceipt | ConvertTo-Json -Depth 16 | Test-Json -SchemaFile $automationReceiptSchema -ErrorAction Stop) "Non-adoption automation receipt with a null adoption binding was rejected."
$automationReceipt.published_planning_authority_adoption = $automationAdoptionBinding
Assert-Contract (-not ($automationReceipt | ConvertTo-Json -Depth 16 | Test-Json -SchemaFile $automationReceiptSchema -ErrorAction SilentlyContinue)) "Non-adoption automation receipt with an adoption binding was accepted."

$v2ClosureExample = Read-JsonDocument -Path (Join-Path $templatesRoot "unplanned-publication-closure-v2.example.json") -Context "v2 unplanned-publication closure example"
if ($v2ClosureExample) {
    Assert-Contract ([string]$v2ClosureExample.schema -ceq "rusty.morphospace.workflow.unplanned_publication_closure.v2") "V2 unplanned-publication closure example has the wrong discriminator."
    Assert-Contract ($null -ne $v2ClosureExample.planning_workspace_projection) "V2 unplanned-publication closure example lacks projection evidence."
}
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

$candidateContracts = @(
    [pscustomobject]@{ Template = "prepared-push-retirement.example.json"; Schema = "prepared-push-retirement-v1.schema.json"; Label = "Prepared-push retirement" },
    [pscustomobject]@{ Template = "legacy-embedded-push-bundle-plan.example.json"; Schema = "legacy-embedded-push-bundle-plan-v1.schema.json"; Label = "Legacy embedded push-plan" },
    [pscustomobject]@{ Template = "prepared-publication-reconstruction.example.json"; Schema = "prepared-publication-reconstruction-v1.schema.json"; Label = "Prepared-publication reconstruction" },
    [pscustomobject]@{ Template = "blocker-resolution-receipt.example.json"; Schema = "blocker-resolution-receipt-v1.schema.json"; Label = "Blocker-resolution" },
    [pscustomobject]@{ Template = "blocker-resolution-correction-receipt.example.json"; Schema = "blocker-resolution-correction-receipt-v1.schema.json"; Label = "Blocker-resolution correction" }
)
foreach ($candidateContract in $candidateContracts) {
    $candidateTemplate = Join-Path $templatesRoot $candidateContract.Template
    $candidateSchema = Join-Path $schemaRoot $candidateContract.Schema
    Assert-Contract (Test-Path -LiteralPath $candidateTemplate -PathType Leaf) "Required $($candidateContract.Label) example is missing."
    if (Test-Path -LiteralPath $candidateTemplate -PathType Leaf) {
        try {
            Assert-Contract (Test-Json -Json (Get-Content -Raw -LiteralPath $candidateTemplate) -SchemaFile $candidateSchema) "$($candidateContract.Label) example does not satisfy its schema."
        } catch {
            Add-Failure -Message "$($candidateContract.Label) example validation failed: $($_.Exception.Message)"
        }
    }
}
if (-not $SkipOwnerSelfTests) {
    foreach ($selfTest in @("Test-LegacyEmbeddedPushPlanCompatibility.ps1","Test-PreparedPublicationReconstruction.ps1","Test-ResolveBlocker.ps1","Test-CorrectResolvedBlockerEvidence.ps1","Test-TransitionLedger.ps1")) {
        try { Invoke-IsolatedWorkflowSelfTest -Path (Join-Path $RepoRoot "scripts\$selfTest") }
        catch { Add-Failure -Message "$selfTest failed: $($_.Exception.Message)" }
    }
}

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

$publicationRecoveryTemplate = Join-Path $templatesRoot "unplanned-publication-closure.example.json"
$publicationRecoveryValidator = Join-Path $RepoRoot "scripts\Test-UnplannedPublicationClosure.ps1"
Assert-Contract (Test-Path -LiteralPath $publicationRecoveryTemplate -PathType Leaf) "Required unplanned-publication closure example is missing."
Assert-Contract (Test-Path -LiteralPath $publicationRecoveryValidator -PathType Leaf) "Required unplanned-publication closure validator is missing."
if ((-not $SkipOwnerSelfTests) -and (Test-Path -LiteralPath $publicationRecoveryValidator -PathType Leaf)) {
    try {
        & $publicationRecoveryValidator -SelfTest | Out-Null
    } catch {
        Add-Failure -Message "Unplanned-publication closure self-test failed: $($_.Exception.Message)"
    }
}

if (-not $SkipOwnerSelfTests) {
    foreach ($focusedRecoveryTest in @(
        "Test-PlanningWorkspaceProjection.ps1",
        "Test-PublishedPlanningAuthorityAdoption.ps1",
        "Test-HistoricalUnitAdoptionReconstruction.ps1"
    )) {
        $focusedRecoveryPath = Join-Path $RepoRoot "scripts\$focusedRecoveryTest"
        try { & $focusedRecoveryPath -SelfTest | Out-Null }
        catch { Add-Failure -Message "$focusedRecoveryTest self-test failed: $($_.Exception.Message)" }
    }
}

$plannedAccountingTemplate = Join-Path $templatesRoot "planned-publication-accounting.example.json"
$plannedAccountingValidator = Join-Path $RepoRoot "scripts\Test-PlannedPublicationAccounting.ps1"
Assert-Contract (Test-Path -LiteralPath $plannedAccountingTemplate -PathType Leaf) "Required planned-publication accounting example is missing."
Assert-Contract (Test-Path -LiteralPath $plannedAccountingValidator -PathType Leaf) "Required planned-publication accounting validator is missing."
if ((-not $SkipOwnerSelfTests) -and (Test-Path -LiteralPath $plannedAccountingValidator -PathType Leaf)) {
    try { & $plannedAccountingValidator -SelfTest | Out-Null }
    catch { Add-Failure -Message "Planned-publication accounting self-test failed: $($_.Exception.Message)" }
}

$publishedPrerequisiteTemplate = Join-Path $templatesRoot "published-prerequisite-suffix-reconciliation.example.json"
$publishedPrerequisiteValidator = Join-Path $RepoRoot "scripts\Test-PublishedPrerequisiteSuffixReconciliation.ps1"
Assert-Contract (Test-Path -LiteralPath $publishedPrerequisiteTemplate -PathType Leaf) "Required published-prerequisite suffix reconciliation example is missing."
Assert-Contract (Test-Path -LiteralPath $publishedPrerequisiteValidator -PathType Leaf) "Required published-prerequisite suffix reconciliation validator is missing."
if ((-not $SkipOwnerSelfTests) -and (Test-Path -LiteralPath $publishedPrerequisiteValidator -PathType Leaf)) {
    try { & $publishedPrerequisiteValidator -SelfTest | Out-Null }
    catch { Add-Failure -Message "Published-prerequisite suffix reconciliation self-test failed: $($_.Exception.Message)" }
}

$releaseCapsuleTemplate = Join-Path $templatesRoot "release-capsule.example.json"
$releaseCapsuleValidator = Join-Path $RepoRoot "scripts\Test-ReleaseCapsule.ps1"
Assert-Contract (Test-Path -LiteralPath $releaseCapsuleTemplate -PathType Leaf) "Required release-capsule example is missing."
Assert-Contract (Test-Path -LiteralPath $releaseCapsuleValidator -PathType Leaf) "Required release-capsule validator is missing."
if ((Test-Path -LiteralPath $releaseCapsuleTemplate -PathType Leaf) -and (Test-Path -LiteralPath $releaseCapsuleValidator -PathType Leaf)) {
    try {
        & $releaseCapsuleValidator -Path $releaseCapsuleTemplate -SchemaOnly | Out-Null
    } catch {
        Add-Failure -Message "Release-capsule example failed semantic validation: $($_.Exception.Message)"
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
