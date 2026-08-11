[CmdletBinding(DefaultParameterSetName = "Path")]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = "Path")]
    [string]$Path,

    [Parameter(Mandatory, ParameterSetName = "SelfTest")]
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$schemaId = "rusty.morphospace.workflow.direct_work_package.v1"
$assessmentSchema = "rusty.morphospace.workflow.direct_work_package_assessment.v1"
$lifecyclePath = Join-Path (Split-Path $PSScriptRoot -Parent) "manifests\workflow-lifecycle.portable.json"
$lifecycle = Get-Content -LiteralPath $lifecyclePath -Raw | ConvertFrom-Json -Depth 30

function Get-RequiredValue {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Missing required property '$Name'." }
    return $property.Value
}

function Get-RequiredText {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $value = Get-RequiredValue -Object $Object -Name $Name
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Property '$Name' must be non-empty text."
    }
    return $value
}

function Get-RequiredArray {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Missing required property '$Name'." }
    $value = $property.Value
    if ($value -isnot [array] -or $value.Count -eq 0) {
        throw "Property '$Name' must be a non-empty JSON array."
    }
    return @($value)
}

function Assert-UniqueTextArray {
    param([Parameter(Mandatory)][array]$Values, [Parameter(Mandatory)][string]$Name)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $Values) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw "Property '$Name' must contain only non-empty text values."
        }
        if (-not $seen.Add($value)) { throw "Property '$Name' contains duplicate value '$value'." }
    }
}

function Test-PortableRelativePath {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.Contains("\") -or $Value.StartsWith("/") -or $Value -match "^[A-Za-z]:") { return $false }
    if ($Value -match "(^|/)\.\.?($|/)") { return $false }
    return -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-DirectWorkPackageDocument {
    param([Parameter(Mandatory)]$Document)

    $schema = Get-RequiredText -Object $Document -Name "schema"
    if ($schema -cne $schemaId) { throw "Unsupported direct work package schema '$schema'." }

    $packageId = Get-RequiredText -Object $Document -Name "package_id"
    if ($packageId -cnotmatch "^[a-z0-9][a-z0-9-]{1,95}$") { throw "package_id is not a portable slug." }
    $objective = Get-RequiredText -Object $Document -Name "objective"

    $profileNames = @($lifecycle.guard_profiles | ForEach-Object { [string]$_.id })
    $declaredProfile = Get-RequiredText -Object $Document -Name "guard_profile"
    $declaredRank = [array]::IndexOf($profileNames, $declaredProfile)
    if ($declaredRank -lt 0) { throw "Unknown guard_profile '$declaredProfile'." }

    $riskTier = Get-RequiredText -Object $Document -Name "risk_tier"
    if ($riskTier -cnotin @($lifecycle.risk_tiers)) { throw "Unknown risk_tier '$riskTier'." }

    $categoryProfiles = @{}
    for ($rank = 0; $rank -lt $lifecycle.guard_profiles.Count; $rank++) {
        foreach ($category in @($lifecycle.guard_profiles[$rank].minimum_for)) {
            $categoryProfiles[[string]$category] = $rank
        }
    }
    $aliases = @{}
    foreach ($alias in @($lifecycle.change_category_aliases)) {
        $aliases[[string]$alias.alias] = [string]$alias.canonical
    }

    $categories = @(Get-RequiredArray -Object $Document -Name "change_categories")
    Assert-UniqueTextArray -Values $categories -Name "change_categories"
    $canonicalCategories = [Collections.Generic.List[string]]::new()
    $canonicalSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $minimumRank = 0
    foreach ($categoryValue in $categories) {
        $category = [string]$categoryValue
        $canonical = if ($aliases.ContainsKey($category)) { [string]$aliases[$category] } else { $category }
        if (-not $categoryProfiles.ContainsKey($canonical)) { throw "Unknown change category '$category'." }
        if (-not $canonicalSeen.Add($canonical)) { throw "change_categories resolves to duplicate canonical category '$canonical'." }
        $canonicalCategories.Add($canonical)
        $minimumRank = [Math]::Max($minimumRank, [int]$categoryProfiles[$canonical])
    }
    $minimumProfile = $profileNames[$minimumRank]
    if ($declaredRank -lt $minimumRank) {
        throw "guard_profile '$declaredProfile' under-declares the minimum '$minimumProfile' profile."
    }

    $repositories = @(Get-RequiredArray -Object $Document -Name "repositories")
    $repositorySeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($repositoryEntry in $repositories) {
        $repository = Get-RequiredText -Object $repositoryEntry -Name "repository"
        if ($repository -cnotmatch "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") {
            throw "Repository '$repository' must use portable owner/repository identity."
        }
        if (-not $repositorySeen.Add($repository)) { throw "Duplicate repository '$repository'." }
        $baseCommit = Get-RequiredText -Object $repositoryEntry -Name "base_commit"
        if ($baseCommit -cnotmatch "^[0-9a-f]{40}$") { throw "Repository '$repository' base_commit must be a lowercase 40-character Git object ID." }
        if ($repositoryEntry.PSObject.Properties.Name -contains "allowed_paths") {
            $allowedPaths = @(Get-RequiredArray -Object $repositoryEntry -Name "allowed_paths")
            Assert-UniqueTextArray -Values $allowedPaths -Name "allowed_paths"
            foreach ($allowedPath in $allowedPaths) {
                if (-not (Test-PortableRelativePath -Value $allowedPath)) { throw "allowed_paths contains non-portable path '$allowedPath'." }
            }
        }
    }

    $validation = @(Get-RequiredArray -Object $Document -Name "validation")
    Assert-UniqueTextArray -Values $validation -Name "validation"

    $recovery = @(Get-RequiredArray -Object $Document -Name "recovery_checkpoints")
    Assert-UniqueTextArray -Values $recovery -Name "recovery_checkpoints"
    foreach ($requiredCheckpoint in @("local-commit-before-handoff", "remote-update-before-handoff")) {
        if ($requiredCheckpoint -cnotin $recovery) { throw "Missing required recovery checkpoint '$requiredCheckpoint'." }
    }

    $history = Get-RequiredValue -Object $Document -Name "history"
    $historyMode = Get-RequiredText -Object $history -Name "mode"
    if ($historyMode -cnotin @("rebuild-first", "history-required")) { throw "Unknown history mode '$historyMode'." }
    $historyMinutes = Get-RequiredValue -Object $history -Name "max_minutes"
    if ($historyMinutes -isnot [int] -and $historyMinutes -isnot [long]) { throw "history.max_minutes must be an integer." }
    $minimumMinutes = if ($historyMode -ceq "history-required") { 1 } else { 0 }
    $maximumMinutes = if ($historyMode -ceq "history-required") { 240 } else { 120 }
    if ($historyMinutes -lt $minimumMinutes -or $historyMinutes -gt $maximumMinutes) {
        throw "history.max_minutes for '$historyMode' must be between $minimumMinutes and $maximumMinutes."
    }

    $requiresUnit = $declaredProfile -cne "fast" -or $minimumProfile -cne "fast"
    return [ordered]@{
        schema = $assessmentSchema
        package_id = $packageId
        valid = $true
        objective = $objective
        declared_guard_profile = $declaredProfile
        minimum_guard_profile = $minimumProfile
        risk_tier = $riskTier
        canonical_change_categories = @($canonicalCategories)
        repository_count = $repositories.Count
        validation_step_count = $validation.Count
        recovery_checkpoints = @($recovery)
        history = [ordered]@{ mode = $historyMode; max_minutes = [int]$historyMinutes }
        direct_execution_allowed = -not $requiresUnit
        requires_autonomous_unit = $requiresUnit
        next_step = if ($requiresUnit) { "Create an autonomous unit before mutation." } else { "Proceed on clean branches or worktrees from the declared base commits." }
        git_mutation_performed = $false
        source_mutation_performed = $false
        remote_mutation_performed = $false
        device_mutation_performed = $false
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Label)
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "$Label was accepted unexpectedly." }
}

if ($SelfTest) {
    $fastJson = @'
{
  "schema": "rusty.morphospace.workflow.direct_work_package.v1",
  "package_id": "fast-cross-repo",
  "objective": "Exercise bounded implementation across exact repositories.",
  "guard_profile": "fast",
  "risk_tier": "quick",
  "change_categories": ["implementation", "validation"],
  "repositories": [
    {"repository":"Example/one","base_commit":"0123456789abcdef0123456789abcdef01234567","allowed_paths":["src/"]},
    {"repository":"Example/two","base_commit":"89abcdef0123456789abcdef0123456789abcdef"}
  ],
  "validation": ["focused tests"],
  "recovery_checkpoints": ["local-commit-before-handoff", "remote-update-before-handoff"],
  "history": {"mode":"rebuild-first","max_minutes":20}
}
'@
    $fast = $fastJson | ConvertFrom-Json -Depth 20
    $assessment = Test-DirectWorkPackageDocument -Document $fast
    Assert-True ($assessment.direct_execution_allowed -and -not $assessment.requires_autonomous_unit) "Fast package did not remain direct."
    Assert-True ($assessment.repository_count -eq 2 -and $assessment.minimum_guard_profile -ceq "fast") "Fast package assessment is incorrect."

    $labs = $fastJson | ConvertFrom-Json -Depth 20
    $labs.package_id = "guarded-composition"
    $labs.guard_profile = "labs"
    $labs.change_categories = @("module-composition")
    $labsAssessment = Test-DirectWorkPackageDocument -Document $labs
    Assert-True ($labsAssessment.requires_autonomous_unit -and $labsAssessment.minimum_guard_profile -ceq "labs") "Labs alias did not graduate to an autonomous unit."

    $locked = $fastJson | ConvertFrom-Json -Depth 20
    $locked.package_id = "locked-workflow"
    $locked.guard_profile = "locked"
    $locked.change_categories = @("workflow-automation")
    $lockedAssessment = Test-DirectWorkPackageDocument -Document $locked
    Assert-True ($lockedAssessment.requires_autonomous_unit -and $lockedAssessment.minimum_guard_profile -ceq "locked") "Locked package did not graduate to an autonomous unit."

    $underDeclared = $fastJson | ConvertFrom-Json -Depth 20
    $underDeclared.change_categories = @("authority")
    Assert-Rejected { Test-DirectWorkPackageDocument -Document $underDeclared } "Under-declared guard profile"

    $badHash = $fastJson | ConvertFrom-Json -Depth 20
    $badHash.repositories[0].base_commit = "abc"
    Assert-Rejected { Test-DirectWorkPackageDocument -Document $badHash } "Short base commit"

    $missingCheckpoint = $fastJson | ConvertFrom-Json -Depth 20
    $missingCheckpoint.recovery_checkpoints = @("local-commit-before-handoff")
    Assert-Rejected { Test-DirectWorkPackageDocument -Document $missingCheckpoint } "Missing remote recovery checkpoint"

    Write-Output "Direct work package self-test passed (fast cross-repository lane, labs/locked graduation, alias resolution, guard underspecification, exact base, and recovery checkpoint negatives)."
    return
}

$resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
$document = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json -Depth 30
$result = Test-DirectWorkPackageDocument -Document $document
$result | ConvertTo-Json -Depth 20
