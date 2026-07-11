param(
    [Parameter(Mandatory = $true)][string]$ProjectSpecPath,
    [Parameter(Mandatory = $true)][string[]]$DescriptorPaths,
    [string]$OutPath = "",
    [int]$LockRevision = 1,
    [string]$GeneratedAt = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
$EffectNames = @(
    "permissions", "services", "activities", "queries", "tools", "assets",
    "shaders", "native_libraries", "commands", "routes", "streams", "inputs",
    "scenes", "markers"
)

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required JSON file is missing: $Path" }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Invalid JSON in '$Path': $($_.Exception.Message)" }
}

function Assert-UniqueStrings {
    param([object[]]$Values, [string]$Label)
    $strings = @($Values | ForEach-Object { [string]$_ })
    if (@($strings | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw "$Label contains an empty value." }
    if (@($strings | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0) { throw "$Label contains duplicate values." }
    return $strings
}

function Get-ObjectFingerprint {
    param([object]$Value)
    $copy = ($Value | ConvertTo-Json -Depth 48 | ConvertFrom-Json)
    $copy.lock_fingerprint = "0" * 64
    $json = $copy | ConvertTo-Json -Depth 48 -Compress
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $sha.Dispose() }
}

$projectPath = (Resolve-Path -LiteralPath $ProjectSpecPath).Path
$project = Read-JsonFile -Path $projectPath
if ([string]$project.schema -ne "rusty.morphospace.workflow.project_spec.v2") { throw "Feature-lock v2 resolution requires project_spec.v2." }
if ($LockRevision -lt 1) { throw "LockRevision must be at least 1." }
if (-not $GeneratedAt) { $GeneratedAt = (Get-Date).ToUniversalTime().ToString("o") }

$selectedInitial = @(Assert-UniqueStrings -Values @($project.composition.selected_features) -Label "selected_features")
$denied = @(Assert-UniqueStrings -Values @($project.composition.denied_features) -Label "denied_features")
$selectedModules = @(Assert-UniqueStrings -Values @($project.composition.selected_modules) -Label "selected_modules")
$deniedModules = @(Assert-UniqueStrings -Values @($project.composition.denied_modules) -Label "denied_modules")
foreach ($featureId in $selectedInitial) { if ($denied -contains $featureId) { throw "Feature '$featureId' is both selected and denied." } }
foreach ($moduleId in $selectedModules) { if ($deniedModules -contains $moduleId) { throw "Module '$moduleId' is both selected and denied." } }

$descriptorMap = @{}
$descriptorPathMap = @{}
$descriptorHashMap = @{}
foreach ($pathValue in @($DescriptorPaths | Sort-Object -Unique)) {
    $path = (Resolve-Path -LiteralPath $pathValue).Path
    $descriptor = Read-JsonFile -Path $path
    if ([string]$descriptor.schema -ne "rusty.morphospace.workflow.feature_descriptor.v1") { throw "Feature descriptor has the wrong schema ID: $path" }
    $featureId = [string]$descriptor.feature_id
    if (-not $featureId -or $descriptorMap.ContainsKey($featureId)) { throw "Feature descriptor ID is missing or repeated: '$featureId'." }
    $descriptorMap[$featureId] = $descriptor
    $descriptorPathMap[$featureId] = $path.Replace("\", "/")
    $descriptorHashMap[$featureId] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$selectedSet = @{}
$pending = New-Object System.Collections.Generic.Queue[string]
foreach ($featureId in $selectedInitial) { $pending.Enqueue($featureId) }
while ($pending.Count -gt 0) {
    $featureId = $pending.Dequeue()
    if ($selectedSet.ContainsKey($featureId)) { continue }
    if ($denied -contains $featureId) { throw "Selected dependency closure reaches denied feature '$featureId'." }
    if (-not $descriptorMap.ContainsKey($featureId)) { throw "Selected feature '$featureId' has no descriptor." }
    $selectedSet[$featureId] = $true
    foreach ($dependency in @($descriptorMap[$featureId].dependencies)) { $pending.Enqueue([string]$dependency) }
}
$selected = @($selectedSet.Keys | Sort-Object)

$projectModuleMap = @{}
foreach ($module in @($project.modules)) {
    $moduleId = [string]$module.module_id
    if ($projectModuleMap.ContainsKey($moduleId)) { throw "Project repeats module '$moduleId'." }
    $projectModuleMap[$moduleId] = $module
}
$repoIds = @($project.repositories | ForEach-Object { [string]$_.repo_id })
$authorityMap = @{}
foreach ($authority in @($project.authority_map)) {
    $parameter = [string]$authority.parameter
    if ($authorityMap.ContainsKey($parameter)) { throw "Project repeats parameter authority '$parameter'." }
    $authorityMap[$parameter] = [string]$authority.owner
}
$validationIds = @($project.validation_profiles | ForEach-Object { [string]$_.profile_id })
$acceptanceIds = @($project.acceptance_profiles | ForEach-Object { [string]$_.profile_id })
$allowedPermissions = @($project.composition.allowed_permissions | ForEach-Object { [string]$_ })
$deniedPermissions = @($project.composition.denied_permissions | ForEach-Object { [string]$_ })

$exclusiveGroups = @{}
$lockFeatures = New-Object System.Collections.Generic.List[object]
$effectUnion = [ordered]@{}
foreach ($effectName in $EffectNames) { $effectUnion[$effectName] = New-Object System.Collections.Generic.List[string] }

foreach ($featureId in $selected) {
    $descriptor = $descriptorMap[$featureId]
    $moduleId = [string]$descriptor.module_id
    if (-not $projectModuleMap.ContainsKey($moduleId) -or $selectedModules -notcontains $moduleId -or $deniedModules -contains $moduleId) {
        throw "Feature '$featureId' references module '$moduleId' that is not explicitly selected in the project."
    }
    $projectModule = $projectModuleMap[$moduleId]
    if ([string]$projectModule.feature_id -ne $featureId -or $projectModule.selected -ne $true) { throw "Project module '$moduleId' selection disagrees with feature '$featureId'." }
    if ($repoIds -notcontains [string]$descriptor.source.repo_id) { throw "Feature '$featureId' references undeclared source repo '$($descriptor.source.repo_id)'." }
    if ([string]$descriptor.source.revision -notmatch "^[0-9a-fA-F]{40}$" -or [string]$descriptor.source.sha256 -notmatch "^[0-9a-fA-F]{64}$") { throw "Feature '$featureId' has invalid source revision/hash." }
    foreach ($conflict in @($descriptor.conflicts)) { if ($selected -contains [string]$conflict) { throw "Selected feature '$featureId' conflicts with '$conflict'." } }
    $exclusiveGroup = $descriptor.exclusive_group
    if ($null -ne $exclusiveGroup) {
        $group = [string]$exclusiveGroup
        if ($exclusiveGroups.ContainsKey($group)) { throw "Features '$($exclusiveGroups[$group])' and '$featureId' share exclusive group '$group'." }
        $exclusiveGroups[$group] = $featureId
    }
    foreach ($parameterAuthority in @($descriptor.parameter_authorities)) {
        $parameter = [string]$parameterAuthority.parameter
        if (-not $authorityMap.ContainsKey($parameter) -or $authorityMap[$parameter] -ne [string]$parameterAuthority.owner) {
            throw "Feature '$featureId' disagrees with project authority for '$parameter'."
        }
    }
    if ([string]$descriptor.activation.rule -ne "selected-lock-and-runtime-input" -or @($descriptor.activation.runtime_inputs).Count -eq 0) {
        throw "Feature '$featureId' must require selected lock plus an explicit runtime input."
    }
    if ($validationIds -notcontains [string]$descriptor.validation_profile) { throw "Feature '$featureId' references unknown validation profile." }
    if ($acceptanceIds -notcontains [string]$descriptor.rollback_profile) { throw "Feature '$featureId' references unknown rollback profile." }
    foreach ($effectName in $EffectNames) {
        foreach ($effect in @(Assert-UniqueStrings -Values @($descriptor.effects.$effectName) -Label "$featureId.$effectName")) {
            if ($effectName -eq "permissions") {
                if ($deniedPermissions -contains $effect) { throw "Feature '$featureId' requests denied permission '$effect'." }
                if ($allowedPermissions -notcontains $effect) { throw "Feature '$featureId' requests permission '$effect' outside the project allow-list." }
            }
            if (-not $effectUnion[$effectName].Contains($effect)) { $effectUnion[$effectName].Add($effect) | Out-Null }
        }
    }
    $lockFeatures.Add([pscustomobject][ordered]@{
        feature_id = $featureId
        module_id = $moduleId
        version = [string]$descriptor.version
        owner_lane = [string]$descriptor.owner_lane
        selected = $true
        run_activation_default = "disabled"
        descriptor = [pscustomobject][ordered]@{
            path = $descriptorPathMap[$featureId]
            sha256 = $descriptorHashMap[$featureId]
            source_repo = [string]$descriptor.source.repo_id
            source_revision = ([string]$descriptor.source.revision).ToLowerInvariant()
            source_path = [string]$descriptor.source.path
            source_sha256 = ([string]$descriptor.source.sha256).ToLowerInvariant()
        }
        dependencies = @($descriptor.dependencies | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        conflicts = @($descriptor.conflicts | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        exclusive_group = $descriptor.exclusive_group
        effects = $descriptor.effects
        parameter_authorities = @($descriptor.parameter_authorities)
        activation = $descriptor.activation
        validation_profile = [string]$descriptor.validation_profile
        rollback_profile = [string]$descriptor.rollback_profile
    }) | Out-Null
}

$union = [ordered]@{}
foreach ($effectName in $EffectNames) { $union[$effectName] = @($effectUnion[$effectName] | Sort-Object -Unique) }
$lock = [pscustomobject][ordered]@{
    '$schema' = "https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/feature-lock-v2.schema.json"
    schema = "rusty.morphospace.workflow.feature_lock.v2"
    project_id = [string]$project.project_id
    project_revision = [int]$project.revision
    revision = $LockRevision
    generated_at = $GeneratedAt
    resolver_version = "rusty-morphospace-feature-resolver/2"
    lock_fingerprint = "0" * 64
    default_activation = "disabled"
    activation_rule = "selected-lock-and-runtime-input"
    selected_features = $selected
    denied_features = @($denied | Sort-Object)
    features = @($lockFeatures.ToArray())
    effect_union = [pscustomobject]$union
}
$lock.lock_fingerprint = Get-ObjectFingerprint -Value $lock

if ($Execute) {
    if (-not $OutPath) { throw "OutPath is required with -Execute." }
    $resolvedOut = [System.IO.Path]::GetFullPath($OutPath)
    $parent = Split-Path -Parent $resolvedOut
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($resolvedOut, (($lock | ConvertTo-Json -Depth 48) + [Environment]::NewLine), $encoding)
    Write-Host "Wrote feature lock v2: $resolvedOut"
} else {
    $lock | ConvertTo-Json -Depth 48
}
