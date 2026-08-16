param(
    [string]$RepoRoot = "",
    [string]$WorkspaceRoot = "",
    [string]$RepositoryMapPath = "",
    [switch]$CurrentUnitInstructionOnly,
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
Import-Module (Join-Path $RepoRoot 'scripts\lib\MorphospaceCompletedTransitionSemanticCorrection.psm1') -Force
Import-Module (Join-Path $RepoRoot 'scripts\lib\MorphospaceHistoricalBlockerResolutionIntentBindingCorrection.psm1') -Force
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
    $ambientGitEnvironment = @{}
    foreach ($item in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' })) {
        $ambientGitEnvironment[[string]$item.Name] = [string]$item.Value
        Remove-Item -LiteralPath "Env:$($item.Name)" -ErrorAction SilentlyContinue
    }
    try {
        $output = @(& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        foreach ($entry in $ambientGitEnvironment.GetEnumerator()) {
            Set-Item -LiteralPath "Env:$($entry.Key)" -Value ([string]$entry.Value)
        }
    }
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

function Assert-EvolvingInstructionPolicy {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$DeferredSupersededFailures,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Condition) { return }

    $unitId = [string]$Unit.unit_id
    $mayBeHistoricalInFlight = @("active", "validating") -ccontains [string]$Unit.status -and
        [string]$State.current_unit -cne $unitId -and
        [string]$State.next_ready_unit -cne $unitId
    if ($mayBeHistoricalInFlight) {
        $DeferredSupersededFailures.Add([pscustomobject][ordered]@{
            unit_id = $unitId
            message = $Message
        }) | Out-Null
        return
    }

    Add-Failure -Message $Message
}

function Test-Text {
    param([object]$Value)

    return -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Test-LegacySkillReviewCompatibility {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][hashtable]$UnitMap,
        [Parameter(Mandatory = $true)][hashtable]$EventMap,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$SupersededInFlightIds,
        [Parameter(Mandatory = $true)][object]$State
    )

    if ($Candidate.work_mode_explicit -or
        [string]$Candidate.action -cne "review-no-change" -or
        [string]$Candidate.status -cne "complete") {
        return $false
    }

    $unitId = [string]$Candidate.unit_id
    if ($SupersededInFlightIds.Contains($unitId)) { return $true }
    if (-not $UnitMap.ContainsKey($unitId)) { return $false }

    $unit = $UnitMap[$unitId]
    $unitEvents = @($EventMap.Values | Where-Object { [string]$_.unit_id -ceq $unitId } | Sort-Object { [int]$_.sequence })
    if ([string]$unit.status -ceq "accepted") {
        return @($unitEvents | Where-Object {
            [string]$_.event_type -ceq "state-transition" -and
            [string]$_.event_id -cmatch "^$([regex]::Escape($unitId))-accepted-[0-9]{4,}$"
        }).Count -eq 1
    }

    if ([string]$unit.status -ceq "blocked" -and [string]$State.current_unit -cne $unitId -and $unitEvents.Count -gt 0) {
        $latest = $unitEvents[-1]
        return [string]$latest.event_type -ceq "blocker"
    }

    return $false
}

function Invoke-LegacySkillReviewCompatibilitySelfTest {
    $acceptedId = "legacy-accepted"
    $blockedId = "legacy-blocked"
    $blockedLaterId = "legacy-blocked-later"
    $acceptedMissingId = "legacy-accepted-missing"
    $activeId = "legacy-active"
    $supersededId = "legacy-superseded"
    $unitMap = @{
        $acceptedId = [pscustomobject]@{ unit_id = $acceptedId; status = "accepted" }
        $blockedId = [pscustomobject]@{ unit_id = $blockedId; status = "blocked" }
        $blockedLaterId = [pscustomobject]@{ unit_id = $blockedLaterId; status = "blocked" }
        $acceptedMissingId = [pscustomobject]@{ unit_id = $acceptedMissingId; status = "accepted" }
        $activeId = [pscustomobject]@{ unit_id = $activeId; status = "active" }
        $supersededId = [pscustomobject]@{ unit_id = $supersededId; status = "active" }
    }
    $eventMap = @{
        "$acceptedId-ready-0001" = [pscustomobject]@{ event_id = "$acceptedId-ready-0001"; event_type = "state-transition"; unit_id = $acceptedId; sequence = 1 }
        "$acceptedId-accepted-0002" = [pscustomobject]@{ event_id = "$acceptedId-accepted-0002"; event_type = "state-transition"; unit_id = $acceptedId; sequence = 2 }
        "$blockedId-blocker-0003" = [pscustomobject]@{ event_id = "$blockedId-blocker-0003"; event_type = "blocker"; unit_id = $blockedId; sequence = 3 }
        "$activeId-claimed-0004" = [pscustomobject]@{ event_id = "$activeId-claimed-0004"; event_type = "state-transition"; unit_id = $activeId; sequence = 4 }
        "$blockedLaterId-blocker-0005" = [pscustomobject]@{ event_id = "$blockedLaterId-blocker-0005"; event_type = "blocker"; unit_id = $blockedLaterId; sequence = 5 }
        "$blockedLaterId-validation-0006" = [pscustomobject]@{ event_id = "$blockedLaterId-validation-0006"; event_type = "validation"; unit_id = $blockedLaterId; sequence = 6 }
        "$acceptedMissingId-validating-0007" = [pscustomobject]@{ event_id = "$acceptedMissingId-validating-0007"; event_type = "state-transition"; unit_id = $acceptedMissingId; sequence = 7 }
    }
    $superseded = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$superseded.Add($supersededId)
    $state = [pscustomobject]@{ current_unit = $activeId }
    $candidate = [pscustomobject]@{
        unit_id = $acceptedId
        action = "review-no-change"
        status = "complete"
        work_mode_explicit = $false
    }

    Assert-Contract (Test-LegacySkillReviewCompatibility -Candidate $candidate -UnitMap $unitMap -EventMap $eventMap -SupersededInFlightIds $superseded -State $state) "Legacy accepted skill-review compatibility self-test failed."
    $candidate.unit_id = $blockedId
    Assert-Contract (Test-LegacySkillReviewCompatibility -Candidate $candidate -UnitMap $unitMap -EventMap $eventMap -SupersededInFlightIds $superseded -State $state) "Legacy blocked skill-review compatibility self-test failed."
    $candidate.unit_id = $supersededId
    Assert-Contract (Test-LegacySkillReviewCompatibility -Candidate $candidate -UnitMap $unitMap -EventMap $eventMap -SupersededInFlightIds $superseded -State $state) "Legacy superseded skill-review compatibility self-test failed."
    $candidate.unit_id = $activeId
    Assert-Contract (-not (Test-LegacySkillReviewCompatibility -Candidate $candidate -UnitMap $unitMap -EventMap $eventMap -SupersededInFlightIds $superseded -State $state)) "Unsuperseded active legacy skill review was accepted."
    $candidate.unit_id = $acceptedMissingId
    Assert-Contract (-not (Test-LegacySkillReviewCompatibility -Candidate $candidate -UnitMap $unitMap -EventMap $eventMap -SupersededInFlightIds $superseded -State $state)) "Legacy accepted skill review without an acceptance event was accepted."
    $candidate.unit_id = $blockedLaterId
    Assert-Contract (-not (Test-LegacySkillReviewCompatibility -Candidate $candidate -UnitMap $unitMap -EventMap $eventMap -SupersededInFlightIds $superseded -State $state)) "Legacy blocked skill review whose latest event was not a blocker was accepted."
    $candidate.unit_id = $acceptedId
    $candidate.work_mode_explicit = $true
    Assert-Contract (-not (Test-LegacySkillReviewCompatibility -Candidate $candidate -UnitMap $unitMap -EventMap $eventMap -SupersededInFlightIds $superseded -State $state)) "Explicit feature-mode skill review was accepted through legacy compatibility."
    $candidate.work_mode_explicit = $false
    $candidate.status = "pending"
    Assert-Contract (-not (Test-LegacySkillReviewCompatibility -Candidate $candidate -UnitMap $unitMap -EventMap $eventMap -SupersededInFlightIds $superseded -State $state)) "Incomplete legacy skill review was accepted."
    $candidate.status = "complete"
    $candidate.action = "update"
    Assert-Contract (-not (Test-LegacySkillReviewCompatibility -Candidate $candidate -UnitMap $unitMap -EventMap $eventMap -SupersededInFlightIds $superseded -State $state)) "Wrong-action legacy skill review was accepted."
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

function Test-CurrentSkillReviewNoChangeCompatibility {
    param(
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string[]]$EffectiveChangeCategories,
        [Parameter(Mandatory = $true)][object[]]$EffectiveAllowedRepositories,
        [Parameter(Mandatory = $true)][object]$SkillSurface
    )

    if ([string]$Unit.work_mode -cne "feature" -or
        -not ($Unit.PSObject.Properties.Name -contains "work_mode") -or
        @("active", "validating") -cnotcontains [string]$Unit.status -or
        [string]$State.current_unit -cne [string]$Unit.unit_id -or
        [string]$SkillSurface.action -cne "review-no-change") {
        return $false
    }

    $portablePolicyCategories = @(
        "authority",
        "module-layout",
        "feature-activation",
        "device-policy",
        "repo-routing",
        "public-private-boundary",
        "workflow-automation",
        "state-machine",
        "validation-routing",
        "recovery"
    )
    if (@($EffectiveChangeCategories | Where-Object {
        $portablePolicyCategories -ccontains [string]$_
    }).Count -gt 0) {
        return $false
    }

    $writablePaths = @($EffectiveAllowedRepositories | ForEach-Object {
        @($_.allowed_paths | ForEach-Object { [string]$_ })
    })
    return -not (Test-PathInScope -Candidate ([string]$SkillSurface.path) -Allowed $writablePaths)
}

function Test-CurrentUnitInstructionWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SchemaPath,
        [string]$Context = "current-unit instruction contract"
    )

    $statePath = Join-Path $Root "workspace.state.json"
    $state = Read-JsonDocument -Path $statePath -Context "$Context workspace state"
    if ($null -eq $state) { return }
    $currentUnitId = [string]$state.current_unit
    Assert-Contract ($currentUnitId -match $script:PortableIdPattern) "$Context requires one canonical current_unit."
    if ($currentUnitId -notmatch $script:PortableIdPattern) { return }

    $unitPath = Join-Path $Root ("iteration-units/{0}.json" -f $currentUnitId)
    $unit = Read-JsonDocument -Path $unitPath -Context "$Context current unit '$currentUnitId'"
    if ($null -eq $unit) { return }
    try {
        Assert-Contract (Get-Content -Raw -LiteralPath $unitPath | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop) "$Context current unit '$currentUnitId' failed its schema."
    } catch {
        Add-Failure -Message "$Context current unit '$currentUnitId' schema validation failed: $($_.Exception.Message)"
    }

    Assert-Contract ([string]$unit.unit_id -ceq $currentUnitId) "$Context current unit identity drifted."
    Assert-Contract ([string]$unit.project_id -ceq [string]$state.project_id) "$Context current unit project_id does not match workspace state."
    Assert-Contract (@("active", "validating") -ccontains [string]$unit.status) "$Context current unit must be active or validating."

    $workModeExplicit = $unit.PSObject.Properties.Name -contains "work_mode"
    $workMode = if ($workModeExplicit) { [string]$unit.work_mode } else { "feature" }
    Assert-Contract ($script:WorkModes -ccontains $workMode) "$Context current unit has unknown work mode '$workMode'."

    $changeCategories = @($unit.change_categories | ForEach-Object { [string]$_ })
    $effectiveChangeCategories = @($changeCategories | ForEach-Object {
        if ($script:ChangeCategories -ccontains $_) { $_ }
        elseif ($script:ChangeCategoryAliases.ContainsKey($_)) { $script:ChangeCategoryAliases[$_] }
        else { $_ }
    })
    foreach ($category in $changeCategories) {
        Assert-Contract (($script:ChangeCategories -ccontains $category) -or $script:ChangeCategoryAliases.ContainsKey($category)) "$Context current unit has unknown change category '$category'."
    }

    $instructionImpact = [string]$unit.instruction_impact
    $instructionSurfaces = @($unit.instruction_surfaces)
    $effectiveAllowedRepositories = @($unit.allowed_repositories)
    Assert-Contract ($script:InstructionImpactValues -ccontains $instructionImpact) "$Context current unit has unknown instruction impact '$instructionImpact'."
    Test-UniqueProperty -Items $instructionSurfaces -Property "path" -Context "$Context current unit instruction surfaces"
    foreach ($surface in $instructionSurfaces) {
        Assert-Contract ($script:InstructionSurfaceKinds -ccontains [string]$surface.surface_kind) "$Context current unit has unknown instruction surface kind '$($surface.surface_kind)'."
        Assert-Contract (Test-Text $surface.path) "$Context current unit instruction surface needs a path."
        Assert-Contract (Test-Text $surface.owner) "$Context current unit instruction surface '$($surface.path)' needs an owner."
        Assert-Contract (Test-Text $surface.change_reason) "$Context current unit instruction surface '$($surface.path)' needs a change reason."
        Assert-Contract (@("update", "review-no-change") -ccontains [string]$surface.action) "$Context current unit instruction surface '$($surface.path)' has unknown action."
        Assert-Contract (@("planned", "complete") -ccontains [string]$surface.status) "$Context current unit instruction surface '$($surface.path)' has unknown status."
        Assert-Contract (Test-Text $surface.validation) "$Context current unit instruction surface '$($surface.path)' needs validation."
        if ([string]$surface.surface_kind -ceq "skill") {
            Assert-Contract (Test-Text $surface.skill_id) "$Context current unit skill surface '$($surface.path)' needs skill_id."
        } else {
            Assert-Contract ($null -eq $surface.skill_id) "$Context current unit non-skill surface '$($surface.path)' must use null skill_id."
        }
    }

    $triggeredCategories = @($effectiveChangeCategories | Where-Object {
        $script:InstructionTriggerCategories -ccontains [string]$_
    } | Sort-Object -Unique -CaseSensitive)
    if ($triggeredCategories.Count -eq 0) { return }

    $expectedInstructionImpact = if ($workMode -ceq "validation-only") { "review" } else { "update" }
    $expectedRequiredAction = if ($workMode -ceq "validation-only") { "review-no-change" } else { "update" }
    Assert-Contract ($instructionImpact -ceq $expectedInstructionImpact) "$Context current unit work mode '$workMode' must use instruction_impact '$expectedInstructionImpact'."
    $agentSurfaces = @($instructionSurfaces | Where-Object { [string]$_.surface_kind -ceq "agents" })
    $routerSurfaces = @($instructionSurfaces | Where-Object {
        @("readme", "router-doc") -ccontains [string]$_.surface_kind
    })
    Assert-Contract ($agentSurfaces.Count -gt 0) "$Context current unit needs the nearest AGENTS.md instruction surface."
    Assert-Contract ($routerSurfaces.Count -gt 0) "$Context current unit needs a README or router-doc instruction surface."
    foreach ($surface in @($agentSurfaces + $routerSurfaces)) {
        Assert-Contract ([string]$surface.action -ceq $expectedRequiredAction) "$Context current unit required instruction surface '$($surface.path)' must use '$expectedRequiredAction'."
    }

    $requiredSkillIds = [Collections.Generic.List[string]]::new()
    foreach ($category in $triggeredCategories) {
        foreach ($skillId in @($script:InstructionSkillRouting[[string]$category])) {
            if (-not $requiredSkillIds.Contains([string]$skillId)) { $requiredSkillIds.Add([string]$skillId) }
        }
    }
    foreach ($requiredSkillId in $requiredSkillIds.ToArray()) {
        $matching = @($instructionSurfaces | Where-Object {
            [string]$_.surface_kind -ceq "skill" -and [string]$_.skill_id -ceq [string]$requiredSkillId
        })
        Assert-Contract ($matching.Count -eq 1) "$Context current unit needs one instruction surface for relevant skill '$requiredSkillId'."
        if ($matching.Count -eq 1 -and [string]$matching[0].action -cne $expectedRequiredAction) {
            Assert-Contract (Test-CurrentSkillReviewNoChangeCompatibility `
                -Unit $unit `
                -State $state `
                -EffectiveChangeCategories $effectiveChangeCategories `
                -EffectiveAllowedRepositories $effectiveAllowedRepositories `
                -SkillSurface $matching[0]) "$Context current unit relevant skill '$requiredSkillId' must use '$expectedRequiredAction'."
        }
    }

    if ($workMode -ceq "validation-only") {
        Assert-Contract ($effectiveChangeCategories.Count -eq 1 -and [string]$effectiveChangeCategories[0] -ceq "validation") "$Context validation-only current unit may declare only validation."
        Assert-Contract (@($instructionSurfaces | Where-Object { [string]$_.action -cne "review-no-change" }).Count -eq 0) "$Context validation-only current unit may only review instruction surfaces without change."
    }
}

function Invoke-CurrentInstructionSurfacePolicySelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$TemplateRoot,
        [Parameter(Mandatory = $true)][string]$SchemaPath
    )

    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("morphospace-current-instruction-" + [guid]::NewGuid().ToString("N"))
    [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot "iteration-units")) | Out-Null
    try {
        $unit = Read-JsonDocument -Path (Join-Path $TemplateRoot "iteration-unit.example.json") -Context "current instruction fixture unit source"
        $state = Read-JsonDocument -Path (Join-Path $TemplateRoot "workspace.state.example.json") -Context "current instruction fixture state source"
        if ($null -eq $unit -or $null -eq $state) { return }
        $unit.unit_id = "current-instruction-surface"
        $unit.status = "active"
        $unit.work_mode = "feature"
        $unit.change_categories = @("implementation", "validation")
        $unit.instruction_impact = "update"
        $unit.instruction_surfaces = @(
            [pscustomobject][ordered]@{ surface_kind="agents"; path="<repo-root>/AGENTS.md"; owner="example-owner"; change_reason="Review the local product instructions."; action="update"; status="planned"; validation="<instruction-validation>"; skill_id=$null },
            [pscustomobject][ordered]@{ surface_kind="readme"; path="<repo-root>/README.md"; owner="example-owner"; change_reason="Review the public product router."; action="update"; status="planned"; validation="<instruction-validation>"; skill_id=$null },
            [pscustomobject][ordered]@{ surface_kind="compatibility-doc"; path="docs/COMPATIBILITY.md"; owner="example-owner"; change_reason="Record the compatibility boundary."; action="update"; status="planned"; validation="<instruction-validation>"; skill_id=$null },
            [pscustomobject][ordered]@{ surface_kind="roadmap-doc"; path="docs/ROADMAP.md"; owner="example-owner"; change_reason="Record the deferred follow-up."; action="update"; status="planned"; validation="<instruction-validation>"; skill_id=$null },
            [pscustomobject][ordered]@{ surface_kind="skill"; path="<skills-root>/rusty-morphospace/SKILL.md"; owner="workflow-maintainer"; change_reason="The portable routing remains unchanged."; action="review-no-change"; status="planned"; validation="<skill-validation>"; skill_id="rusty-morphospace" },
            [pscustomobject][ordered]@{ surface_kind="skill"; path="<skills-root>/system-engineering/SKILL.md"; owner="workflow-maintainer"; change_reason="The system authority remains unchanged."; action="review-no-change"; status="planned"; validation="<skill-validation>"; skill_id="system-engineering" }
        )
        $state.current_unit = [string]$unit.unit_id
        $state.project_id = [string]$unit.project_id

        $unitJson = $unit | ConvertTo-Json -Depth 40
        Assert-Contract ($unitJson | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop) "Synthetic current update unit with compatibility and roadmap documents was rejected."
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $fixtureRoot "workspace.state.json"), ($state | ConvertTo-Json -Depth 40), $utf8)
        [IO.File]::WriteAllText((Join-Path $fixtureRoot "iteration-units/current-instruction-surface.json"), $unitJson, $utf8)
        Test-CurrentUnitInstructionWorkspace -Root $fixtureRoot -SchemaPath $SchemaPath -Context "synthetic current instruction fixture"

        $skillSurface = @($unit.instruction_surfaces | Where-Object { [string]$_.skill_id -ceq "rusty-morphospace" })[0]
        Assert-Contract (Test-CurrentSkillReviewNoChangeCompatibility -Unit $unit -State $state -EffectiveChangeCategories @("implementation", "validation") -EffectiveAllowedRepositories @($unit.allowed_repositories) -SkillSurface $skillSurface) "Out-of-scope current skill review-no-change was rejected."
        Assert-Contract (-not (Test-CurrentSkillReviewNoChangeCompatibility -Unit $unit -State $state -EffectiveChangeCategories @("authority") -EffectiveAllowedRepositories @($unit.allowed_repositories) -SkillSurface $skillSurface)) "Authority-changing current unit weakened the required skill update."
        $writableSkillScope = @([pscustomobject]@{ repo_id="workflow-owner"; allowed_paths=@("<skills-root>/rusty-morphospace/SKILL.md") })
        Assert-Contract (-not (Test-CurrentSkillReviewNoChangeCompatibility -Unit $unit -State $state -EffectiveChangeCategories @("validation") -EffectiveAllowedRepositories $writableSkillScope -SkillSurface $skillSurface)) "Writable current skill path weakened the required skill update."
        $otherState = $state | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $otherState.current_unit = "different-current-unit"
        Assert-Contract (-not (Test-CurrentSkillReviewNoChangeCompatibility -Unit $unit -State $otherState -EffectiveChangeCategories @("validation") -EffectiveAllowedRepositories @($unit.allowed_repositories) -SkillSurface $skillSurface)) "Non-current unit used current skill-review compatibility."

        $unknownUnit = $unitJson | ConvertFrom-Json -Depth 40
        @($unknownUnit.instruction_surfaces | Where-Object { [string]$_.surface_kind -ceq "compatibility-doc" })[0].surface_kind = "unknown-doc"
        Assert-Contract (-not ($unknownUnit | ConvertTo-Json -Depth 40 | Test-Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) "Unknown instruction surface kind passed the iteration-unit schema."
        Assert-Contract ($script:InstructionSurfaceKinds -cnotcontains "unknown-doc") "Unknown instruction surface kind entered the lifecycle manifest."
    } finally {
        if ([IO.Directory]::Exists($fixtureRoot)) { [IO.Directory]::Delete($fixtureRoot, $true) }
    }
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
    $legacySkillReviewCandidates = New-Object System.Collections.Generic.List[object]
    $deferredSupersededInstructionFailures = New-Object System.Collections.Generic.List[object]
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
        $unitId = [string]$unit.unit_id
        $adoption = if ($historicalAdoptions.ContainsKey($unitId)) { $historicalAdoptions[$unitId] } else { $null }
        $readOnlyDependencyScopeProjection = $null
        $completedProjectScopeProjection = $null
        if ($null -ne $adoption) {
            $unitPath = Normalize-RelativePath ([IO.Path]::GetRelativePath((Split-Path -Parent $Bundle.StatePath), $path))
            Assert-Contract ($unitPath -eq [string]$adoption.unit_path) "$Context historical unit '$unitId' adoption path drifted."
            Assert-Contract ((Get-FileSha256 $path) -eq [string]$adoption.unit_sha256) "$Context historical unit '$unitId' bytes drifted."
            Assert-Contract (@("accepted", "blocked") -contains [string]$unit.status) "$Context historical adoption cannot be used by current or future unit '$unitId'."
            Assert-Contract ([string]$unit.status -eq [string]$adoption.terminal_status) "$Context historical unit '$unitId' terminal status drifted."
            if ($adoption.normalization.PSObject.Properties.Name -contains "read_only_dependency_scope") {
                $readOnlyDependencyScopeProjection = $adoption.normalization.read_only_dependency_scope
            }
            if ($adoption.normalization.PSObject.Properties.Name -contains "completed_project_scope") {
                $completedProjectScopeProjection = $adoption.normalization.completed_project_scope
            }
            Assert-Contract (-not ($null -ne $readOnlyDependencyScopeProjection -and $null -ne $completedProjectScopeProjection)) "$Context historical unit '$unitId' cannot combine read-only and completed-project scope projections."
            if ($null -ne $readOnlyDependencyScopeProjection -or $null -ne $completedProjectScopeProjection) {
                $adoptionProperties = @($adoption.PSObject.Properties.Name | Sort-Object)
                Assert-Contract (($adoptionProperties -join "|") -ceq "normalization|terminal_evidence|terminal_status|unit_id|unit_path|unit_sha256") "$Context historical scope projection for '$unitId' has an unexpected unit-level property."
                Assert-Contract ([string]$unit.status -ceq "blocked" -and [string]$adoption.terminal_status -ceq "blocked") "$Context historical scope projection is limited to terminal blocked unit '$unitId'."
                Assert-Contract ([string]$state.current_unit -cne $unitId -and [string]$state.next_ready_unit -cne $unitId) "$Context historical scope projection cannot apply to current or next-ready unit '$unitId'."
                Assert-Contract (@($adoption.normalization.change_categories).Count -eq 0 -and @($adoption.normalization.validation_profiles).Count -eq 0 -and @($adoption.normalization.resource_kinds).Count -eq 0) "$Context historical scope projection for '$unitId' cannot combine unrelated legacy mappings."
                $normalizationProperties = @($adoption.normalization.PSObject.Properties.Name | Sort-Object)
                $expectedNormalizationProperties = if ($null -ne $readOnlyDependencyScopeProjection) {
                    "change_categories|read_only_dependency_scope|resource_kinds|validation_profiles"
                } else {
                    "change_categories|completed_project_scope|resource_kinds|validation_profiles"
                }
                Assert-Contract (($normalizationProperties -join "|") -ceq $expectedNormalizationProperties) "$Context historical scope projection for '$unitId' has an unexpected normalization property."
            }
        }

        $workModeExplicit = $unit.PSObject.Properties.Name -contains "work_mode"
        $workMode = if ($workModeExplicit) { [string]$unit.work_mode } else { "feature" }
        $effectiveWorkMode = $workMode
        if ($null -ne $adoption) {
            $unknownWorkModes = if ($script:WorkModes -contains $workMode) { @() } else { @($workMode) }
            $workModeMappings = if ($adoption.normalization.PSObject.Properties.Name -contains "work_modes") { @($adoption.normalization.work_modes | Where-Object { $null -ne $_ }) } else { @() }
            Test-ExactLegacyMappings -UnknownValues $unknownWorkModes -Mappings $workModeMappings -CurrentValues @("feature") -Context "$Context historical unit '$unitId' work-mode"
            foreach ($mapping in $workModeMappings) {
                $mappingProperties = @($mapping.PSObject.Properties.Name | Sort-Object)
                Assert-Contract (($mappingProperties -join "|") -ceq "current|legacy|retained_as") "$Context historical unit '$unitId' work-mode mapping has an unexpected property."
                Assert-Contract ([string]$mapping.legacy -ceq "publication") "$Context historical unit '$unitId' may normalize only retired publication work mode."
                Assert-Contract ([string]$mapping.current -ceq "feature") "$Context historical unit '$unitId' publication work mode must target feature."
            }
            if ($workModeMappings.Count -gt 0) {
                Assert-Contract ([string]$unit.status -ceq "blocked") "$Context historical publication work-mode adoption is limited to terminal blocked unit '$unitId'."
            }
            if ($unknownWorkModes.Count -eq 1 -and $workModeMappings.Count -eq 1) {
                $effectiveWorkMode = [string]$workModeMappings[0].current
            }
            if ($null -ne $completedProjectScopeProjection) {
                Assert-Contract ([string]$workMode -ceq "validation-only" -and $workModeMappings.Count -eq 0) "$Context completed-project scope projection requires immutable validation-only work mode for '$unitId'."
                Assert-Contract ([string]$completedProjectScopeProjection.work_mode -ceq "validation-only") "$Context completed-project scope projection for '$unitId' must remain validation-only."
                $effectiveWorkMode = [string]$completedProjectScopeProjection.work_mode
            }
        } else {
            Assert-Contract ($script:WorkModes -contains $workMode) "$Context unit '$($unit.unit_id)' has unknown work mode '$workMode'."
        }
        $effectiveChangeCategories = @($changeCategories | ForEach-Object {
            if ($script:ChangeCategories -contains $_) { $_ }
            elseif ($script:ChangeCategoryAliases.ContainsKey($_)) { $script:ChangeCategoryAliases[$_] }
            else { $_ }
        })
        Assert-Contract ($changeCategories.Count -gt 0) "$Context unit '$($unit.unit_id)' needs at least one change category."
        foreach ($categoryGroup in @($changeCategories | Group-Object)) {
            Assert-Contract ($categoryGroup.Count -eq 1) "$Context unit '$($unit.unit_id)' repeats change category '$($categoryGroup.Name)'."
        }
        if ($null -ne $completedProjectScopeProjection) {
            Assert-Contract (@($completedProjectScopeProjection.change_categories).Count -eq 1 -and [string]$completedProjectScopeProjection.change_categories[0] -ceq "validation") "$Context completed-project scope projection for '$unitId' must project only validation."
            $effectiveChangeCategories = @("validation")
        } elseif ($null -ne $adoption) {
            $unknownCategories = @($changeCategories | Where-Object { $script:ChangeCategories -notcontains $_ })
            Test-ExactLegacyMappings -UnknownValues $unknownCategories -Mappings @($adoption.normalization.change_categories) -CurrentValues $script:ChangeCategories -Context "$Context historical unit '$unitId' change-category"
        } else {
            foreach ($category in $changeCategories) {
                Assert-Contract (($script:ChangeCategories -contains $category) -or $script:ChangeCategoryAliases.ContainsKey($category)) "$Context unit '$unitId' has unknown change category '$category'."
            }
        }

        $effectiveAllowedRepositories = @($unit.allowed_repositories)
        if ($null -ne $completedProjectScopeProjection) {
            $projectionProperties = @($completedProjectScopeProjection.PSObject.Properties.Name | Sort-Object)
            Assert-Contract (($projectionProperties -join "|") -ceq "allowed_repositories|blocker_evidence|change_categories|corrections|mutation_performed|project_snapshot|retained_as|work_mode") "$Context completed-project scope projection for '$unitId' has an unexpected property."
            Assert-Contract (Test-Text $completedProjectScopeProjection.retained_as) "$Context completed-project scope projection for '$unitId' must retain its historical meaning."
            Assert-Contract ([int]$completedProjectScopeProjection.project_snapshot.project_revision -le [int]$spec.revision) "$Context completed-project scope projection for '$unitId' project revision is newer than current project state."
            Assert-Contract ([int]$completedProjectScopeProjection.project_snapshot.feature_lock_revision -le [int]$lock.revision) "$Context completed-project scope projection for '$unitId' feature-lock revision is newer than current project state."
            Assert-Contract ([int]$completedProjectScopeProjection.project_snapshot.plan_revision -le [int]$state.plan_revision) "$Context completed-project scope projection for '$unitId' plan revision is newer than current workspace state."
            $mutationProperties = @($completedProjectScopeProjection.mutation_performed.PSObject.Properties.Name | Sort-Object)
            Assert-Contract (($mutationProperties -join "|") -ceq "device|git|remote") "$Context completed-project scope projection for '$unitId' mutation statement has an unexpected property."
            Assert-Contract ($completedProjectScopeProjection.mutation_performed.git -eq $false -and $completedProjectScopeProjection.mutation_performed.device -eq $false -and $completedProjectScopeProjection.mutation_performed.remote -eq $false) "$Context completed-project scope projection for '$unitId' cannot claim Git, device, or remote mutation."
            Assert-Contract ([string]$unit.device_requirement -ceq "none" -and @($unit.resource_requirements).Count -eq 0) "$Context completed-project scope projection for '$unitId' cannot retain device or resource authority."

            $expectedPlanningRepositories = @($unit.allowed_repositories | Where-Object {
                @($_.allowed_paths).Count -gt 0 -and @($_.allowed_paths | Where-Object { (Normalize-RelativePath ([string]$_)) -notmatch '^morphospace(?:/|$)' }).Count -eq 0
            })
            $projectedRepositories = @($completedProjectScopeProjection.allowed_repositories)
            Test-UniqueProperty -Items $projectedRepositories -Property "repo_id" -Context "$Context completed-project scope projection for '$unitId' allowed repositories"
            Assert-Contract ($projectedRepositories.Count -eq $expectedPlanningRepositories.Count) "$Context completed-project scope projection for '$unitId' must retain only immutable planning repositories."
            foreach ($projectedRepo in $projectedRepositories) {
                $repoId = [string]$projectedRepo.repo_id
                $immutableRepo = @($expectedPlanningRepositories | Where-Object { [string]$_.repo_id -ceq $repoId })
                Assert-Contract ($immutableRepo.Count -eq 1) "$Context completed-project scope projection for '$unitId' introduced repository '$repoId'."
                Test-NonEmptyTextArray -Value $projectedRepo.allowed_paths -Context "$Context completed-project scope projection for '$unitId' repository '$repoId' paths"
                $projectedPaths = @($projectedRepo.allowed_paths | ForEach-Object { Normalize-RelativePath ([string]$_) } | Sort-Object -CaseSensitive)
                $immutablePaths = if ($immutableRepo.Count -eq 1) { @($immutableRepo[0].allowed_paths | ForEach-Object { Normalize-RelativePath ([string]$_) } | Sort-Object -CaseSensitive) } else { @() }
                Assert-Contract (($projectedPaths -join "|") -ceq ($immutablePaths -join "|")) "$Context completed-project scope projection for '$unitId' planning paths drifted."
                Assert-Contract (@($projectedPaths | Where-Object { $_ -notmatch '^morphospace(?:/|$)' }).Count -eq 0) "$Context completed-project scope projection for '$unitId' may retain only morphospace planning paths."
            }
            $effectiveAllowedRepositories = @($projectedRepositories)
        }

        $instructionImpact = [string]$unit.instruction_impact
        $instructionSurfaces = @($unit.instruction_surfaces)
        Assert-Contract ($script:InstructionImpactValues -contains $instructionImpact) "$Context unit '$($unit.unit_id)' has unknown instruction impact '$instructionImpact'."
        Test-UniqueProperty -Items $instructionSurfaces -Property "path" -Context "$Context unit '$($unit.unit_id)' instruction surfaces"
        $triggeredCategories = @($effectiveChangeCategories | Where-Object { $script:InstructionTriggerCategories -contains $_ } | Sort-Object -Unique)
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

        $effectiveInstructionImpact = $instructionImpact
        $effectiveInstructionSurfaces = @($instructionSurfaces)
        if ($null -ne $adoption) {
            $projectedInstructionImpact = if ($effectiveWorkMode -eq "validation-only") { "review" } else { "update" }
            $expectedImpactMappings = if ($triggeredCategories.Count -gt 0 -and $instructionImpact -ne $projectedInstructionImpact) { @($instructionImpact) } else { @() }
            $impactMappings = if ($adoption.normalization.PSObject.Properties.Name -contains "instruction_impact") { @($adoption.normalization.instruction_impact) } else { @() }
            Test-ExactLegacyMappings -UnknownValues $expectedImpactMappings -Mappings $impactMappings -CurrentValues @($projectedInstructionImpact) -Context "$Context historical unit '$unitId' instruction-impact"
            if ($expectedImpactMappings.Count -eq 1 -and $impactMappings.Count -eq 1) {
                $effectiveInstructionImpact = [string]$impactMappings[0].current
            }

            $expectedSurfacePaths = if ($triggeredCategories.Count -gt 0 -and $effectiveWorkMode -ne "validation-only") {
                @($instructionSurfaces | Where-Object {
                    (($_.surface_kind -eq "agents" -or $_.surface_kind -eq "readme" -or $_.surface_kind -eq "router-doc") -and $_.action -eq "review-no-change") -or
                    ($_.surface_kind -eq "skill" -and $requiredSkillIds.Contains([string]$_.skill_id) -and $_.action -eq "review-no-change")
                } | ForEach-Object { [string]$_.path } | Sort-Object)
            } else { @() }
            $surfaceMappings = if ($adoption.normalization.PSObject.Properties.Name -contains "instruction_surfaces") { @($adoption.normalization.instruction_surfaces | Where-Object { $null -ne $_ }) } else { @() }
            $mappedSurfacePaths = @($surfaceMappings | ForEach-Object { [string]$_.path } | Sort-Object)
            Assert-Contract (($expectedSurfacePaths -join "|") -eq ($mappedSurfacePaths -join "|")) "$Context historical unit '$unitId' instruction-surface mappings must exactly cover required legacy actions."
            if ($surfaceMappings.Count -gt 0) { Test-UniqueProperty -Items $surfaceMappings -Property "path" -Context "$Context historical unit '$unitId' instruction-surface mappings" }
            foreach ($mapping in $surfaceMappings) {
                $mappingProperties = @($mapping.PSObject.Properties.Name | Sort-Object)
                Assert-Contract (($mappingProperties -join "|") -ceq "current_action|legacy_action|path|retained_as") "$Context historical unit '$unitId' instruction-surface mapping '$($mapping.path)' has an unexpected property."
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

            $missingSkillMappings = if ($adoption.normalization.PSObject.Properties.Name -contains "missing_required_skill_surfaces") {
                @($adoption.normalization.missing_required_skill_surfaces | Where-Object { $null -ne $_ })
            } else { @() }
            $laterRequiredSkillMappings = if ($adoption.normalization.PSObject.Properties.Name -contains "later_required_skill_surfaces") {
                @($adoption.normalization.later_required_skill_surfaces | Where-Object { $null -ne $_ })
            } else { @() }
            $expectedMissingSkillIds = @($requiredSkillIds.ToArray() | Where-Object {
                $requiredSkillId = [string]$_
                @($instructionSurfaces | Where-Object {
                    [string]$_.surface_kind -ceq "skill" -and [string]$_.skill_id -ceq $requiredSkillId
                }).Count -eq 0
            } | Sort-Object)
            $allMissingSkillMappings = @($missingSkillMappings) + @($laterRequiredSkillMappings)
            $mappedMissingSkillIds = @($allMissingSkillMappings | ForEach-Object { [string]$_.skill_id } | Sort-Object)
            Assert-Contract (($expectedMissingSkillIds -join "|") -ceq ($mappedMissingSkillIds -join "|")) "$Context historical unit '$unitId' missing-skill mappings must exactly cover wholly absent required skill surfaces."
            Assert-Contract (@($mappedMissingSkillIds | Group-Object -CaseSensitive | Where-Object { $_.Count -ne 1 }).Count -eq 0) "$Context historical unit '$unitId' missing-skill mappings overlap or repeat a required skill."
            if ($missingSkillMappings.Count -gt 0) {
                $adoptionProperties = @($adoption.PSObject.Properties.Name | Sort-Object)
                Assert-Contract (($adoptionProperties -join "|") -ceq "normalization|terminal_evidence|terminal_status|unit_id|unit_path|unit_sha256") "$Context missing-skill projection for '$unitId' has an unexpected unit-level property."
                $allowedNormalizationProperties = @("change_categories", "instruction_impact", "instruction_surfaces", "missing_required_skill_surfaces", "resource_kinds", "validation_profiles", "work_modes")
                $unexpectedNormalizationProperties = @($adoption.normalization.PSObject.Properties.Name | Where-Object { $allowedNormalizationProperties -cnotcontains [string]$_ })
                Assert-Contract ($unexpectedNormalizationProperties.Count -eq 0) "$Context missing-skill projection for '$unitId' has an unexpected normalization property."
                Assert-Contract ([string]$workMode -ceq "feature" -and $workModeMappings.Count -eq 0) "$Context missing-skill projection requires immutable feature work mode for '$unitId'."
                Assert-Contract ([string]$instructionImpact -ceq "update" -and $impactMappings.Count -eq 0) "$Context missing-skill projection requires immutable update instruction impact for '$unitId'."
                Assert-Contract ([string]$unit.status -ceq "blocked") "$Context missing-skill projection is limited to terminal blocked unit '$unitId'."
                Assert-Contract ([string]$state.current_unit -cne $unitId -and [string]$state.next_ready_unit -cne $unitId) "$Context missing-skill projection cannot apply to current or next-ready unit '$unitId'."
                Test-UniqueProperty -Items $missingSkillMappings -Property "skill_id" -Context "$Context historical unit '$unitId' missing-skill mappings"
                Test-UniqueProperty -Items $missingSkillMappings -Property "path" -Context "$Context historical unit '$unitId' missing-skill mappings"
            }
            if ($laterRequiredSkillMappings.Count -gt 0) {
                $adoptionProperties = @($adoption.PSObject.Properties.Name | Sort-Object)
                Assert-Contract (($adoptionProperties -join "|") -ceq "normalization|terminal_evidence|terminal_status|unit_id|unit_path|unit_sha256") "$Context later-required-skill projection for '$unitId' has an unexpected unit-level property."
                $allowedNormalizationProperties = @("change_categories", "instruction_impact", "instruction_surfaces", "later_required_skill_surfaces", "resource_kinds", "validation_profiles", "work_modes")
                $unexpectedNormalizationProperties = @($adoption.normalization.PSObject.Properties.Name | Where-Object { $allowedNormalizationProperties -cnotcontains [string]$_ })
                Assert-Contract ($unexpectedNormalizationProperties.Count -eq 0) "$Context later-required-skill projection for '$unitId' has an unexpected normalization property."
                Assert-Contract ([string]$unit.status -ceq "accepted" -and [string]$adoption.terminal_status -ceq "accepted") "$Context later-required-skill projection is limited to immutable accepted unit '$unitId'."
                Assert-Contract ([string]$state.current_unit -cne $unitId -and [string]$state.next_ready_unit -cne $unitId) "$Context later-required-skill projection cannot apply to current or next-ready unit '$unitId'."
                Test-UniqueProperty -Items $laterRequiredSkillMappings -Property "skill_id" -Context "$Context historical unit '$unitId' later-required-skill mappings"
                Test-UniqueProperty -Items $laterRequiredSkillMappings -Property "path" -Context "$Context historical unit '$unitId' later-required-skill mappings"
            }
            foreach ($mapping in $missingSkillMappings) {
                $mappingProperties = @($mapping.PSObject.Properties.Name | Sort-Object)
                Assert-Contract (($mappingProperties -join "|") -ceq "current_action|path|retained_as|retained_status|skill_id") "$Context historical unit '$unitId' missing-skill mapping '$($mapping.path)' has an unexpected property."
                $skillId = [string]$mapping.skill_id
                $expectedPath = "<skills-root>/$skillId/SKILL.md"
                Assert-Contract ([string]$mapping.path -ceq $expectedPath) "$Context historical unit '$unitId' missing-skill mapping '$($mapping.path)' does not use the canonical required-skill path."
                Assert-Contract ([string]$mapping.current_action -ceq "update") "$Context historical unit '$unitId' missing-skill mapping '$($mapping.path)' must project update."
                Assert-Contract ([string]$mapping.retained_status -ceq "planned") "$Context historical unit '$unitId' missing-skill mapping '$($mapping.path)' must retain planned status."
                Assert-Contract (Test-Text $mapping.retained_as) "$Context historical unit '$unitId' missing-skill mapping '$($mapping.path)' must state the retained historical meaning."
                Assert-Contract (@($instructionSurfaces | Where-Object { [string]$_.path -ceq [string]$mapping.path -or ([string]$_.surface_kind -ceq "skill" -and [string]$_.skill_id -ceq $skillId) }).Count -eq 0) "$Context historical unit '$unitId' missing-skill mapping '$($mapping.path)' is not wholly absent from immutable unit bytes."
            }
            foreach ($mapping in $laterRequiredSkillMappings) {
                $mappingProperties = @($mapping.PSObject.Properties.Name | Sort-Object)
                Assert-Contract (($mappingProperties -join "|") -ceq "current_action|path|retained_as|skill_id|terminal_requirement") "$Context historical unit '$unitId' later-required-skill mapping '$($mapping.path)' has an unexpected property."
                $skillId = [string]$mapping.skill_id
                $expectedPath = "<skills-root>/$skillId/SKILL.md"
                Assert-Contract ([string]$mapping.path -ceq $expectedPath) "$Context historical unit '$unitId' later-required-skill mapping '$($mapping.path)' does not use the canonical current skill path."
                Assert-Contract ([string]$mapping.current_action -ceq "update") "$Context historical unit '$unitId' later-required-skill mapping '$($mapping.path)' must record the current update requirement."
                Assert-Contract ([string]$mapping.terminal_requirement -ceq "not-required-at-acceptance") "$Context historical unit '$unitId' later-required-skill mapping '$($mapping.path)' must preserve non-applicability at acceptance."
                Assert-Contract (Test-Text $mapping.retained_as) "$Context historical unit '$unitId' later-required-skill mapping '$($mapping.path)' must state the retained historical meaning."
                Assert-Contract (@($instructionSurfaces | Where-Object { [string]$_.path -ceq [string]$mapping.path -or ([string]$_.surface_kind -ceq "skill" -and [string]$_.skill_id -ceq $skillId) }).Count -eq 0) "$Context historical unit '$unitId' later-required-skill mapping '$($mapping.path)' is not wholly absent from immutable unit bytes."
            }
            if ($missingSkillMappings.Count -gt 0) {
                $effectiveInstructionSurfaces = @($effectiveInstructionSurfaces + @($missingSkillMappings | ForEach-Object {
                    [pscustomobject][ordered]@{
                        surface_kind = "skill"
                        path = [string]$_.path
                        owner = "historical-adoption-projection"
                        change_reason = "A required skill surface is absent from immutable terminal historical unit bytes."
                        action = [string]$_.current_action
                        status = [string]$_.retained_status
                        validation = "Current validation projection only; no historical instruction edit, completion, or execution is claimed."
                        skill_id = [string]$_.skill_id
                    }
                }))
            }
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
            $expectedInstructionImpact = if ($effectiveWorkMode -eq "validation-only") { "review" } else { "update" }
            $expectedRequiredAction = if ($effectiveWorkMode -eq "validation-only") { "review-no-change" } else { "update" }
            Assert-EvolvingInstructionPolicy `
                -Condition ($effectiveInstructionImpact -eq $expectedInstructionImpact) `
                -Unit $unit -State $state -DeferredSupersededFailures $deferredSupersededInstructionFailures `
                -Message "$Context unit '$($unit.unit_id)' effective work mode '$effectiveWorkMode' must use instruction_impact '$expectedInstructionImpact'."
            $agentSurfaces = @($effectiveInstructionSurfaces | Where-Object { $_.surface_kind -eq "agents" })
            $routerSurfaces = @($effectiveInstructionSurfaces | Where-Object { $_.surface_kind -eq "readme" -or $_.surface_kind -eq "router-doc" })
            Assert-EvolvingInstructionPolicy `
                -Condition ($agentSurfaces.Count -gt 0) `
                -Unit $unit -State $state -DeferredSupersededFailures $deferredSupersededInstructionFailures `
                -Message "$Context unit '$($unit.unit_id)' needs the nearest AGENTS.md instruction surface."
            Assert-EvolvingInstructionPolicy `
                -Condition ($routerSurfaces.Count -gt 0) `
                -Unit $unit -State $state -DeferredSupersededFailures $deferredSupersededInstructionFailures `
                -Message "$Context unit '$($unit.unit_id)' needs a README or router-doc instruction surface."

            foreach ($requiredSkillId in $requiredSkillIds.ToArray()) {
                $matchingSkill = @($effectiveInstructionSurfaces | Where-Object {
                    $_.surface_kind -eq "skill" -and $_.skill_id -eq $requiredSkillId
                })
                $laterRequiredSkillCompatibility = if ($null -ne $adoption -and $adoption.normalization.PSObject.Properties.Name -contains "later_required_skill_surfaces") {
                    @($adoption.normalization.later_required_skill_surfaces | Where-Object { [string]$_.skill_id -ceq [string]$requiredSkillId })
                } else { @() }
                Assert-EvolvingInstructionPolicy `
                    -Condition ($matchingSkill.Count -eq 1 -or ($matchingSkill.Count -eq 0 -and $laterRequiredSkillCompatibility.Count -eq 1)) `
                    -Unit $unit -State $state -DeferredSupersededFailures $deferredSupersededInstructionFailures `
                    -Message "$Context unit '$($unit.unit_id)' needs one instruction surface for relevant skill '$requiredSkillId'."
                if ($matchingSkill.Count -eq 1) {
                    $skillSurface = $matchingSkill[0]
                    if ([string]$skillSurface.action -ceq $expectedRequiredAction) {
                        # Current feature and validation-only records use the exact mode action.
                    } elseif (Test-CurrentSkillReviewNoChangeCompatibility `
                        -Unit $unit `
                        -State $state `
                        -EffectiveChangeCategories $effectiveChangeCategories `
                        -EffectiveAllowedRepositories $effectiveAllowedRepositories `
                        -SkillSurface $skillSurface) {
                        # Current feature units may retain an out-of-scope skill
                        # review only for validation work that changes no
                        # portable authority, routing, module, or policy rule.
                    } elseif (-not $workModeExplicit -and [string]$skillSurface.action -ceq "review-no-change") {
                        $legacySkillReviewCandidates.Add([pscustomobject][ordered]@{
                            unit_id = [string]$unit.unit_id
                            skill_id = [string]$requiredSkillId
                            action = [string]$skillSurface.action
                            status = [string]$skillSurface.status
                            work_mode_explicit = $false
                        }) | Out-Null
                    } else {
                        Assert-EvolvingInstructionPolicy `
                            -Condition $false `
                            -Unit $unit -State $state -DeferredSupersededFailures $deferredSupersededInstructionFailures `
                            -Message "$Context unit '$($unit.unit_id)' relevant skill '$requiredSkillId' must use '$expectedRequiredAction'."
                    }
                }
            }

            foreach ($requiredSurface in @($agentSurfaces + $routerSurfaces)) {
                Assert-EvolvingInstructionPolicy `
                    -Condition ($requiredSurface.action -eq $expectedRequiredAction) `
                    -Unit $unit -State $state -DeferredSupersededFailures $deferredSupersededInstructionFailures `
                    -Message "$Context unit '$($unit.unit_id)' required instruction surface '$($requiredSurface.path)' must use '$expectedRequiredAction'."
            }

            if ($effectiveWorkMode -eq "validation-only") {
                Assert-Contract ($effectiveChangeCategories.Count -eq 1 -and $effectiveChangeCategories[0] -eq "validation") "$Context validation-only unit '$($unit.unit_id)' may declare only the validation change category."
                Assert-Contract (@($effectiveInstructionSurfaces | Where-Object { [string]$_.action -ne "review-no-change" }).Count -eq 0) "$Context validation-only unit '$($unit.unit_id)' may only review instruction surfaces without change."
                foreach ($allowedRepo in @($effectiveAllowedRepositories)) {
                    Assert-Contract (@($allowedRepo.allowed_paths | Where-Object { (Normalize-RelativePath ([string]$_)) -notmatch '^morphospace(?:/|$)' }).Count -eq 0) "$Context validation-only unit '$($unit.unit_id)' may write only project morphospace state/evidence paths."
                }
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

        $immutableReadOnlyDependencies = if ($unit.PSObject.Properties.Name -contains 'read_only_dependencies') { @($unit.read_only_dependencies) } else { @() }
        $effectiveReadOnlyDependencies = @($immutableReadOnlyDependencies)
        if ($null -ne $readOnlyDependencyScopeProjection) {
            $projectionProperties = @($readOnlyDependencyScopeProjection.PSObject.Properties.Name | Sort-Object)
            Assert-Contract (($projectionProperties -join "|") -ceq "closure|mappings|retained_as") "$Context read-only dependency scope projection for '$unitId' has an unexpected property."
            Assert-Contract (Test-Text $readOnlyDependencyScopeProjection.retained_as) "$Context read-only dependency scope projection for '$unitId' must retain its historical meaning."
            Assert-Contract ([string]$workMode -ceq "validation-only" -and $effectiveChangeCategories.Count -eq 1 -and [string]$effectiveChangeCategories[0] -ceq "validation") "$Context read-only dependency scope projection for '$unitId' is limited to immutable validation-only units."
            Assert-Contract (@($effectiveAllowedRepositories | Where-Object { @($_.allowed_paths | Where-Object { (Normalize-RelativePath ([string]$_)) -notmatch '^morphospace(?:/|$)' }).Count -gt 0 }).Count -eq 0) "$Context read-only dependency scope projection for '$unitId' cannot retain source write authority."

            $closureReferenceProperties = @($readOnlyDependencyScopeProjection.closure.PSObject.Properties.Name | Sort-Object)
            Assert-Contract (($closureReferenceProperties -join "|") -ceq "path|sha256") "$Context read-only dependency scope projection for '$unitId' closure reference has an unexpected property."
            $closureRelativePath = Normalize-RelativePath ([string]$readOnlyDependencyScopeProjection.closure.path)
            Assert-Contract (Test-PortableRelativePath $closureRelativePath) "$Context read-only dependency scope projection for '$unitId' closure path is not portable."
            $closurePath = Join-Path $workspaceRoot ($closureRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
            Assert-Contract (Test-Path -LiteralPath $closurePath -PathType Leaf) "$Context read-only dependency scope projection for '$unitId' closure is missing."
            Assert-Contract ([string]$readOnlyDependencyScopeProjection.closure.sha256 -ceq (Get-FileSha256 $closurePath)) "$Context read-only dependency scope projection for '$unitId' closure hash drifted."
            $closure = Read-JsonDocument -Path $closurePath -Context "$Context read-only dependency scope closure for '$unitId'"
            if ($null -ne $closure) {
                Assert-Contract ([string]$closure.schema -match '^[a-z0-9][a-z0-9_.-]{2,191}$') "$Context read-only dependency scope projection for '$unitId' closure lacks a portable schema identity."
                Assert-Contract ([string]$closure.source_terminal_unit.unit_id -ceq $unitId -and [string]$closure.source_terminal_unit.status -ceq "blocked") "$Context read-only dependency scope projection for '$unitId' closure belongs to another unit or status."
                Assert-Contract ([string]$closure.source_terminal_unit.sha256 -ceq [string]$adoption.unit_sha256 -and [int64]$closure.source_terminal_unit.byte_length -eq (Get-Item -LiteralPath $path).Length) "$Context read-only dependency scope projection for '$unitId' closure unit identity drifted."
                Assert-Contract ([string]$closure.source_terminal_unit.terminal_event_id -ceq [string]$adoption.terminal_evidence.event_id) "$Context read-only dependency scope projection for '$unitId' closure terminal event drifted."
                Assert-Contract ([string]$closure.source_terminal_unit.blocker_evidence_sha256 -match '^[0-9a-f]{64}$') "$Context read-only dependency scope projection for '$unitId' closure lacks blocker evidence identity."
            }

            Test-UniqueProperty -Items $immutableReadOnlyDependencies -Property "repo_id" -Context "$Context immutable read-only dependencies for '$unitId'"
            $closureDependencies = if ($null -ne $closure) { @($closure.proposed_read_only_dependencies) } else { @() }
            Test-UniqueProperty -Items $closureDependencies -Property "repo_id" -Context "$Context read-only dependency scope closure for '$unitId'"
            $immutableRepoIds = @($immutableReadOnlyDependencies | ForEach-Object { [string]$_.repo_id } | Sort-Object -CaseSensitive)
            $closureRepoIds = @($closureDependencies | ForEach-Object { [string]$_.repo_id } | Sort-Object -CaseSensitive)
            Assert-Contract (($immutableRepoIds -join "|") -ceq ($closureRepoIds -join "|")) "$Context read-only dependency scope projection for '$unitId' closure repository identities drifted."

            $closurePathsByRepo = @{}
            foreach ($closureDependency in $closureDependencies) {
                $repoId = [string]$closureDependency.repo_id
                $closurePaths = @($closureDependency.paths | ForEach-Object { Normalize-RelativePath ([string]$_) })
                Test-NonEmptyTextArray -Value $closurePaths -Context "$Context read-only dependency scope closure for '$unitId' repository '$repoId' paths"
                Assert-Contract (@($closurePaths | Group-Object -CaseSensitive | Where-Object { $_.Count -ne 1 }).Count -eq 0) "$Context read-only dependency scope closure for '$unitId' repository '$repoId' repeats a path."
                $sortedClosurePaths = @($closurePaths | Sort-Object -CaseSensitive)
                $joinedClosurePaths = [string]::Join([char]10, $sortedClosurePaths)
                $closurePathsSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false, $true).GetBytes($joinedClosurePaths))).ToLowerInvariant()
                Assert-Contract ([int]$closureDependency.path_count -eq $sortedClosurePaths.Count -and [string]$closureDependency.sorted_lf_joined_path_sha256 -ceq $closurePathsSha) "$Context read-only dependency scope closure for '$unitId' repository '$repoId' path inventory drifted."
                Assert-Contract ($repositoryMap.ContainsKey($repoId)) "$Context read-only dependency scope closure for '$unitId' references undeclared repository '$repoId'."
                $immutableDependency = @($immutableReadOnlyDependencies | Where-Object { [string]$_.repo_id -ceq $repoId })
                Assert-Contract ($immutableDependency.Count -eq 1) "$Context read-only dependency scope closure for '$unitId' cannot resolve repository '$repoId'."
                foreach ($closureCandidate in $sortedClosurePaths) {
                    Assert-Contract (Test-PortableRelativePath $closureCandidate) "$Context read-only dependency scope closure for '$unitId' has non-portable path '$closureCandidate'."
                    if ($repositoryMap.ContainsKey($repoId)) {
                        Assert-Contract (Test-PathInScope -Candidate $closureCandidate -Allowed @($repositoryMap[$repoId].allowed_paths)) "$Context read-only dependency scope closure for '$unitId' path '$closureCandidate' is outside current project scope for '$repoId'."
                    }
                    $containingLegacyRows = if ($immutableDependency.Count -eq 1) { @($immutableDependency[0].paths | Where-Object { Test-PathInScope -Candidate $closureCandidate -Allowed @([string]$_) }) } else { @() }
                    Assert-Contract ($containingLegacyRows.Count -le 1) "$Context read-only dependency scope closure for '$unitId' path '$closureCandidate' collides across immutable legacy rows."
                }
                $closurePathsByRepo[$repoId] = $sortedClosurePaths
            }

            $invalidLegacyRows = New-Object System.Collections.Generic.List[object]
            foreach ($dependency in $immutableReadOnlyDependencies) {
                $repoId = [string]$dependency.repo_id
                foreach ($legacyPathValue in @($dependency.paths)) {
                    $legacyPath = Normalize-RelativePath ([string]$legacyPathValue)
                    if (-not $repositoryMap.ContainsKey($repoId) -or -not (Test-PathInScope -Candidate $legacyPath -Allowed @($repositoryMap[$repoId].allowed_paths))) {
                        $invalidLegacyRows.Add([pscustomobject][ordered]@{ repo_id = $repoId; legacy_path = $legacyPath }) | Out-Null
                    }
                }
            }
            $scopeMappings = @($readOnlyDependencyScopeProjection.mappings)
            $mappingKeys = @($scopeMappings | ForEach-Object { "{0}`n{1}" -f [string]$_.repo_id, (Normalize-RelativePath ([string]$_.legacy_path)) })
            Assert-Contract (@($mappingKeys | Group-Object -CaseSensitive | Where-Object { $_.Count -ne 1 }).Count -eq 0) "$Context read-only dependency scope projection for '$unitId' repeats a legacy row."
            $invalidKeys = @($invalidLegacyRows | ForEach-Object { "{0}`n{1}" -f [string]$_.repo_id, [string]$_.legacy_path } | Sort-Object -CaseSensitive)
            Assert-Contract ((@($mappingKeys | Sort-Object -CaseSensitive) -join "|") -ceq ($invalidKeys -join "|")) "$Context read-only dependency scope projection for '$unitId' must map every and only invalid legacy rows."
            $allMappedTargets = New-Object System.Collections.Generic.List[string]
            foreach ($mapping in $scopeMappings) {
                $mappingProperties = @($mapping.PSObject.Properties.Name | Sort-Object)
                Assert-Contract (($mappingProperties -join "|") -ceq "current_paths|legacy_path|repo_id|retained_as") "$Context read-only dependency scope projection for '$unitId' mapping has an unexpected property."
                $repoId = [string]$mapping.repo_id
                $legacyPath = Normalize-RelativePath ([string]$mapping.legacy_path)
                Assert-Contract (Test-Text $mapping.retained_as) "$Context read-only dependency scope projection for '$unitId' mapping '$repoId/$legacyPath' must retain its historical meaning."
                $currentPaths = @($mapping.current_paths | ForEach-Object { Normalize-RelativePath ([string]$_) } | Sort-Object -CaseSensitive)
                Test-NonEmptyTextArray -Value $currentPaths -Context "$Context read-only dependency scope projection for '$unitId' mapping '$repoId/$legacyPath' current paths"
                Assert-Contract (@($currentPaths | Group-Object -CaseSensitive | Where-Object { $_.Count -ne 1 }).Count -eq 0) "$Context read-only dependency scope projection for '$unitId' mapping '$repoId/$legacyPath' repeats a current path."
                $expectedCurrentPaths = if ($closurePathsByRepo.ContainsKey($repoId)) { @($closurePathsByRepo[$repoId] | Where-Object { $_ -cne $legacyPath -and (Test-PathInScope -Candidate $_ -Allowed @($legacyPath)) } | Sort-Object -CaseSensitive) } else { @() }
                Assert-Contract (($currentPaths -join "|") -ceq ($expectedCurrentPaths -join "|")) "$Context read-only dependency scope projection for '$unitId' mapping '$repoId/$legacyPath' does not equal the closure descendants."
                foreach ($currentPath in $currentPaths) {
                    Assert-Contract ($currentPath -cne $legacyPath -and (Test-PathInScope -Candidate $currentPath -Allowed @($legacyPath))) "$Context read-only dependency scope projection for '$unitId' target '$currentPath' is not a strict descendant of '$legacyPath'."
                    Assert-Contract ($repositoryMap.ContainsKey($repoId) -and @($repositoryMap[$repoId].allowed_paths | ForEach-Object { Normalize-RelativePath ([string]$_) }) -ccontains $currentPath) "$Context read-only dependency scope projection for '$unitId' target '$currentPath' is not an exact current project path for '$repoId'."
                    Assert-Contract (-not $allMappedTargets.Contains("$repoId`n$currentPath")) "$Context read-only dependency scope projection for '$unitId' maps target '$currentPath' more than once for '$repoId'."
                    $allMappedTargets.Add("$repoId`n$currentPath") | Out-Null
                }
            }

            $effectiveReadOnlyDependencies = @($immutableReadOnlyDependencies | ForEach-Object {
                $dependency = $_ | Select-Object *
                $repoId = [string]$dependency.repo_id
                $projectedPaths = New-Object System.Collections.Generic.List[string]
                foreach ($legacyPathValue in @($dependency.paths)) {
                    $legacyPath = Normalize-RelativePath ([string]$legacyPathValue)
                    $mapping = @($scopeMappings | Where-Object { [string]$_.repo_id -ceq $repoId -and (Normalize-RelativePath ([string]$_.legacy_path)) -ceq $legacyPath })
                    if ($mapping.Count -eq 1) {
                        foreach ($currentPath in @($mapping[0].current_paths)) { $projectedPaths.Add((Normalize-RelativePath ([string]$currentPath))) | Out-Null }
                    } else {
                        $projectedPaths.Add($legacyPath) | Out-Null
                    }
                }
                Assert-Contract (@($projectedPaths | Group-Object -CaseSensitive | Where-Object { $_.Count -ne 1 }).Count -eq 0) "$Context read-only dependency scope projection for '$unitId' produces duplicate dependency paths for '$repoId'."
                $dependency.paths = @($projectedPaths)
                $dependency
            })
        }

        Assert-Contract (@($effectiveAllowedRepositories).Count -gt 0) "$Context unit '$($unit.unit_id)' needs allowed repositories."
        $writeRepositoryIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($allowedRepo in @($effectiveAllowedRepositories)) {
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
        $readOnlyDependencies = @($effectiveReadOnlyDependencies)
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
        if ($unit.PSObject.Properties.Name -contains "guard_profile") {
            $guardProfile = [string]$unit.guard_profile
            Assert-Contract ($script:GuardProfiles -contains $guardProfile) "$Context unit '$($unit.unit_id)' has unknown guard profile '$guardProfile'."
            $guardRanks = @{ fast = 0; labs = 1; locked = 2 }
            $lockedCategories = @("public-private-boundary", "workflow-automation", "state-machine", "validation-routing", "recovery")
            $labsCategories = @("authority", "module-layout", "feature-activation", "device-policy", "repo-routing")
            $minimumGuardRank = 0
            if (@($effectiveChangeCategories | Where-Object { $lockedCategories -contains $_ }).Count -gt 0 -or [string]$unit.push_checkpoint -eq "release") {
                $minimumGuardRank = 2
            } elseif (@($effectiveChangeCategories | Where-Object { $labsCategories -contains $_ }).Count -gt 0) {
                $minimumGuardRank = 1
            }
            Assert-Contract ([int]$guardRanks[$guardProfile] -ge $minimumGuardRank) "$Context unit '$($unit.unit_id)' guard profile '$guardProfile' is below the required authority level."
        }
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
        $workModeMappings = if ($entry.normalization.PSObject.Properties.Name -contains "work_modes") { @($entry.normalization.work_modes | Where-Object { $null -ne $_ }) } else { @() }
        $missingSkillMappings = if ($entry.normalization.PSObject.Properties.Name -contains "missing_required_skill_surfaces") { @($entry.normalization.missing_required_skill_surfaces | Where-Object { $null -ne $_ }) } else { @() }
        $laterRequiredSkillMappings = if ($entry.normalization.PSObject.Properties.Name -contains "later_required_skill_surfaces") { @($entry.normalization.later_required_skill_surfaces | Where-Object { $null -ne $_ }) } else { @() }
        $instructionImpactMappings = if ($entry.normalization.PSObject.Properties.Name -contains "instruction_impact") { @($entry.normalization.instruction_impact | Where-Object { $null -ne $_ }) } else { @() }
        $instructionSurfaceMappings = if ($entry.normalization.PSObject.Properties.Name -contains "instruction_surfaces") { @($entry.normalization.instruction_surfaces | Where-Object { $null -ne $_ }) } else { @() }
        $terminalReceipt = $null
        $hasReadOnlyDependencyScopeProjection = $entry.normalization.PSObject.Properties.Name -contains "read_only_dependency_scope"
        $hasCompletedProjectScopeProjection = $entry.normalization.PSObject.Properties.Name -contains "completed_project_scope"
        $requiresScopeTerminalEvidence = $hasReadOnlyDependencyScopeProjection -or $hasCompletedProjectScopeProjection
        $requiresExactTerminalEvidence = $workModeMappings.Count -gt 0 -or
            $missingSkillMappings.Count -gt 0 -or
            $laterRequiredSkillMappings.Count -gt 0 -or
            $instructionImpactMappings.Count -gt 0 -or
            $instructionSurfaceMappings.Count -gt 0 -or
            $requiresScopeTerminalEvidence
        if ($requiresExactTerminalEvidence) {
            $terminalProperties = @($entry.terminal_evidence.PSObject.Properties.Name | Sort-Object)
            Assert-Contract (($terminalProperties -join "|") -ceq "event_id|event_sha256|receipt_path|receipt_sha256") "$Context evidence-bound historical adoption for '$adoptedUnitId' must bind exact event and receipt evidence."
            Assert-Contract (Test-Text $entry.terminal_evidence.receipt_path) "$Context evidence-bound historical adoption for '$adoptedUnitId' requires a terminal receipt path."
        }
        Assert-Contract ($eventMap.ContainsKey($terminalEventId)) "$Context historical unit '$adoptedUnitId' lacks its declared terminal event '$terminalEventId'."
        if ($eventMap.ContainsKey($terminalEventId)) {
            $terminalEvent = $eventMap[$terminalEventId]
            Assert-Contract ([string]$terminalEvent.unit_id -eq $adoptedUnitId) "$Context historical unit '$adoptedUnitId' terminal event belongs to another unit."
            if ($requiresExactTerminalEvidence) {
                Assert-Contract ([string]$entry.terminal_evidence.event_sha256 -ceq [string]$terminalEvent.__line_sha256) "$Context evidence-bound historical adoption for '$adoptedUnitId' terminal event hash drifted."
            }
            if ($missingSkillMappings.Count -gt 0 -or $requiresScopeTerminalEvidence) {
                $projectionKind = if ($missingSkillMappings.Count -gt 0) { "missing-skill" } else { "historical scope" }
                Assert-Contract ([string]$terminalEvent.event_type -ceq "blocker") "$Context $projectionKind projection for '$adoptedUnitId' requires its terminal blocker event."
                $latestUnitEvent = @($events | Where-Object { [string]$_.unit_id -ceq $adoptedUnitId } | Select-Object -Last 1)
                Assert-Contract ($latestUnitEvent.Count -eq 1 -and [string]$latestUnitEvent[0].event_id -ceq $terminalEventId) "$Context $projectionKind projection for '$adoptedUnitId' must bind its latest same-unit event."
            }
            if ($laterRequiredSkillMappings.Count -gt 0) {
                Assert-Contract ([string]$terminalEvent.event_type -ceq "state-transition") "$Context later-required-skill projection for '$adoptedUnitId' requires its accepted state-transition event."
                Assert-Contract ([string]$terminalEvent.event_id -cmatch "^$([regex]::Escape($adoptedUnitId))-accepted(?:-|$)") "$Context later-required-skill projection for '$adoptedUnitId' must bind its accepted event."
            }
            if ($null -ne $entry.terminal_evidence.receipt_path) {
                Assert-Contract (@($terminalEvent.receipts) -contains [string]$entry.terminal_evidence.receipt_path) "$Context historical unit '$adoptedUnitId' terminal event does not reference its declared evidence receipt."
                if ($requiresExactTerminalEvidence) {
                    $terminalReceiptRelativePath = Normalize-RelativePath ([string]$entry.terminal_evidence.receipt_path)
                    Assert-Contract (Test-PortableRelativePath $terminalReceiptRelativePath) "$Context evidence-bound historical adoption for '$adoptedUnitId' receipt path is not portable."
                    $terminalReceiptPath = Join-Path $workspaceRoot ($terminalReceiptRelativePath -replace "/", [IO.Path]::DirectorySeparatorChar)
                    Assert-Contract (Test-Path -LiteralPath $terminalReceiptPath -PathType Leaf) "$Context evidence-bound historical adoption for '$adoptedUnitId' receipt is missing."
                    if (Test-Path -LiteralPath $terminalReceiptPath -PathType Leaf) {
                        Assert-Contract ([string]$entry.terminal_evidence.receipt_sha256 -ceq (Get-FileSha256 $terminalReceiptPath)) "$Context evidence-bound historical adoption for '$adoptedUnitId' receipt hash drifted."
                        if ($missingSkillMappings.Count -gt 0 -or $laterRequiredSkillMappings.Count -gt 0 -or $requiresScopeTerminalEvidence) {
                            $projectionKind = if ($missingSkillMappings.Count -gt 0) { "missing-skill" } elseif ($laterRequiredSkillMappings.Count -gt 0) { "later-required-skill" } else { "historical scope" }
                            $terminalReceipt = Read-JsonDocument -Path $terminalReceiptPath -Context "$Context $projectionKind terminal receipt for '$adoptedUnitId'"
                            if ($null -ne $terminalReceipt) {
                                Assert-Contract ([string]$terminalReceipt.schema -ceq "rusty.morphospace.workflow.validation_receipt.v1") "$Context $projectionKind projection for '$adoptedUnitId' requires a validation receipt."
                                Assert-Contract ([string]$terminalReceipt.project_id -ceq [string]$spec.project_id) "$Context $projectionKind projection for '$adoptedUnitId' terminal receipt belongs to another project."
                                Assert-Contract ([string]$terminalReceipt.unit_id -ceq $adoptedUnitId) "$Context $projectionKind projection for '$adoptedUnitId' terminal receipt belongs to another unit."
                                $expectedTerminalResult = if ($laterRequiredSkillMappings.Count -gt 0) { "pass" } else { "blocked" }
                                Assert-Contract ([string]$terminalReceipt.result -ceq $expectedTerminalResult) "$Context $projectionKind projection for '$adoptedUnitId' requires a '$expectedTerminalResult' validation receipt."
                            }
                        }
                    }
                }
            }
        }
        if ($hasCompletedProjectScopeProjection) {
            $projection = $entry.normalization.completed_project_scope
            $blockerEvidenceProperties = @($projection.blocker_evidence.PSObject.Properties.Name | Sort-Object)
            Assert-Contract (($blockerEvidenceProperties -join "|") -ceq "path|sha256") "$Context completed-project scope projection for '$adoptedUnitId' blocker evidence has an unexpected property."
            $blockerRelativePath = Normalize-RelativePath ([string]$projection.blocker_evidence.path)
            Assert-Contract (Test-PortableRelativePath $blockerRelativePath) "$Context completed-project scope projection for '$adoptedUnitId' blocker path is not portable."
            $blockerPath = Join-Path $workspaceRoot ($blockerRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
            Assert-Contract (Test-Path -LiteralPath $blockerPath -PathType Leaf) "$Context completed-project scope projection for '$adoptedUnitId' blocker evidence is missing."
            Assert-Contract ([string]$projection.blocker_evidence.sha256 -ceq (Get-FileSha256 $blockerPath)) "$Context completed-project scope projection for '$adoptedUnitId' blocker evidence hash drifted."
            if ($null -ne $terminalReceipt) {
                $validationReceiptDirectory = Split-Path -Parent (Normalize-RelativePath ([string]$entry.terminal_evidence.receipt_path))
                $matchingBlockerArtifacts = @($terminalReceipt.artifacts | Where-Object {
                    $artifactRelativePath = Normalize-RelativePath (Join-Path $validationReceiptDirectory ([string]$_.path))
                    $artifactRelativePath -ceq $blockerRelativePath -and [string]$_.sha256 -ceq [string]$projection.blocker_evidence.sha256
                })
                Assert-Contract ($matchingBlockerArtifacts.Count -eq 1) "$Context completed-project scope projection for '$adoptedUnitId' terminal validation receipt must bind the exact blocker evidence."
            }
            $immutableUnit = $unitMap[$adoptedUnitId]
            $projectedRepoIds = @($projection.allowed_repositories | ForEach-Object { [string]$_.repo_id })
            $historicalExternalRows = @($immutableUnit.allowed_repositories | Where-Object { $projectedRepoIds -cnotcontains [string]$_.repo_id })
            $corrections = @($projection.corrections)
            Test-UniqueProperty -Items $corrections -Property "repository_id" -Context "$Context completed-project scope projection for '$adoptedUnitId' corrections"
            $historicalRepoIds = @($historicalExternalRows | ForEach-Object { [string]$_.repo_id })
            $correctionRepoIds = @($corrections | ForEach-Object { [string]$_.repository_id })
            Assert-Contract (($correctionRepoIds -join "|") -ceq ($historicalRepoIds -join "|")) "$Context completed-project scope projection for '$adoptedUnitId' corrections must exactly cover retained external repository declarations in original order."
            $priorCorrectionSequence = 0
            $lastCorrectionIntent = $null
            foreach ($correction in $corrections) {
                $correctionProperties = @($correction.PSObject.Properties.Name | Sort-Object)
                Assert-Contract (($correctionProperties -join "|") -ceq "completion_path|completion_sha256|event_id|event_sha256|intent_path|intent_sha256|receipt_path|receipt_sha256|repository_id") "$Context completed-project scope projection for '$adoptedUnitId' correction has an unexpected property."
                $repoId = [string]$correction.repository_id
                $historicalRepo = @($historicalExternalRows | Where-Object { [string]$_.repo_id -ceq $repoId })
                Assert-Contract ($historicalRepo.Count -eq 1) "$Context completed-project scope projection for '$adoptedUnitId' correction renamed or duplicated repository '$repoId'."

                $receiptRelativePath = Normalize-RelativePath ([string]$correction.receipt_path)
                Assert-Contract (Test-PortableRelativePath $receiptRelativePath) "$Context completed-project scope projection for '$adoptedUnitId' correction receipt path is not portable."
                $receiptPath = Join-Path $workspaceRoot ($receiptRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
                Assert-Contract (Test-Path -LiteralPath $receiptPath -PathType Leaf) "$Context completed-project scope projection for '$adoptedUnitId' correction receipt is missing."
                Assert-Contract ([string]$correction.receipt_sha256 -ceq (Get-FileSha256 $receiptPath)) "$Context completed-project scope projection for '$adoptedUnitId' correction receipt hash drifted."
                $scopeReceipt = Read-JsonDocument -Path $receiptPath -Context "$Context completed-project scope correction receipt for '$adoptedUnitId/$repoId'"
                if ($null -ne $scopeReceipt) {
                    Assert-Contract ([string]$scopeReceipt.schema -ceq "rusty.morphospace.workflow.active_project_repository_scope_correction.v1") "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction receipt has the wrong schema."
                    Assert-Contract ([string]$scopeReceipt.project_id -ceq [string]$spec.project_id -and [string]$scopeReceipt.unit_id -ceq $adoptedUnitId -and [string]$scopeReceipt.repository_id -ceq $repoId) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction receipt identity drifted."
                    $beforePaths = @($scopeReceipt.before_allowed_paths | ForEach-Object { Normalize-RelativePath ([string]$_) })
                    $afterPaths = @($scopeReceipt.after_allowed_paths | ForEach-Object { Normalize-RelativePath ([string]$_) })
                    Assert-Contract (@($beforePaths | Where-Object { $afterPaths -cnotcontains $_ }).Count -eq 0) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction removed project paths."
                    $addedPaths = @($afterPaths | Where-Object { $beforePaths -cnotcontains $_ } | Sort-Object -CaseSensitive)
                    $historicalPaths = if ($historicalRepo.Count -eq 1) { @($historicalRepo[0].allowed_paths | ForEach-Object { Normalize-RelativePath ([string]$_) } | Sort-Object -CaseSensitive) } else { @() }
                    Assert-Contract (($addedPaths -join "|") -ceq ($historicalPaths -join "|")) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction additions do not equal the immutable historical declaration."
                    Assert-Contract ($repositoryMap.ContainsKey($repoId)) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction repository is absent from current project scope."
                    if ($repositoryMap.ContainsKey($repoId)) {
                        $currentPaths = @($repositoryMap[$repoId].allowed_paths | ForEach-Object { Normalize-RelativePath ([string]$_) } | Sort-Object -CaseSensitive)
                        Assert-Contract (@($afterPaths | Where-Object { $currentPaths -cnotcontains $_ }).Count -eq 0) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction paths are no longer retained by current project scope."
                    }
                    Assert-Contract (@($scopeReceipt.does_not_prove).Count -eq 1 -and [string]$scopeReceipt.does_not_prove[0] -match 'Does not change source' -and [string]$scopeReceipt.does_not_prove[0] -match 'device') "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction overclaims execution authority."
                }

                $correctionEventId = [string]$correction.event_id
                Assert-Contract ($eventMap.ContainsKey($correctionEventId)) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction event is missing."
                if ($eventMap.ContainsKey($correctionEventId)) {
                    $correctionEvent = $eventMap[$correctionEventId]
                    Assert-Contract ([string]$correction.event_sha256 -ceq [string]$correctionEvent.__line_sha256) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction event hash drifted."
                    Assert-Contract ([string]$correctionEvent.unit_id -ceq $adoptedUnitId -and [string]$correctionEvent.event_type -ceq "state-transition") "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction event has the wrong identity or type."
                    Assert-Contract (@($correctionEvent.receipts).Count -eq 1 -and [string]$correctionEvent.receipts[0] -ceq $receiptRelativePath) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction event receipt binding drifted."
                    Assert-Contract ([int]$correctionEvent.sequence -gt $priorCorrectionSequence -and [int]$correctionEvent.sequence -lt [int]$terminalEvent.sequence) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction chronology drifted."
                    $priorCorrectionSequence = [int]$correctionEvent.sequence
                }

                $intentRelativePath = Normalize-RelativePath ([string]$correction.intent_path)
                $completionRelativePath = Normalize-RelativePath ([string]$correction.completion_path)
                Assert-Contract ((Test-PortableRelativePath $intentRelativePath) -and (Test-PortableRelativePath $completionRelativePath)) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' transaction paths are not portable."
                $intentPath = Join-Path $workspaceRoot ($intentRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
                $completionPath = Join-Path $workspaceRoot ($completionRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
                Assert-Contract ((Test-Path -LiteralPath $intentPath -PathType Leaf) -and (Test-Path -LiteralPath $completionPath -PathType Leaf)) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' transaction evidence is missing."
                Assert-Contract ([string]$correction.intent_sha256 -ceq (Get-FileSha256 $intentPath) -and [string]$correction.completion_sha256 -ceq (Get-FileSha256 $completionPath)) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' transaction evidence hash drifted."
                $intent = Read-JsonDocument -Path $intentPath -Context "$Context completed-project scope intent for '$adoptedUnitId/$repoId'"
                $completion = Read-JsonDocument -Path $completionPath -Context "$Context completed-project scope completion for '$adoptedUnitId/$repoId'"
                if ($null -ne $intent -and $null -ne $completion) {
                    Assert-Contract ([string]$intent.schema -ceq "rusty.morphospace.workflow.transition_ledger_intent.v3" -and [string]$intent.status -ceq "prepared") "$Context completed-project scope projection for '$adoptedUnitId/$repoId' intent has the wrong schema or status."
                    Assert-Contract ([string]$completion.schema -ceq "rusty.morphospace.workflow.transition_ledger_completion.v1" -and [string]$completion.status -ceq "committed") "$Context completed-project scope projection for '$adoptedUnitId/$repoId' completion has the wrong schema or status."
                    Assert-Contract ([string]$completion.transaction_id -ceq [string]$intent.transaction_id -and [string]$completion.event_id -ceq $correctionEventId) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' transaction identity drifted."
                    Assert-Contract ([string]$completion.intent.path -ceq $intentRelativePath -and [string]$completion.intent.sha256 -ceq [string]$correction.intent_sha256 -and [string]$completion.intent.schema -ceq [string]$intent.schema) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' completion does not bind its intent."
                    Assert-Contract ([string]$intent.unit.path -ceq [string]$entry.unit_path -and [string]$intent.event.event_id -ceq $correctionEventId -and [string]$intent.event.unit_id -ceq $adoptedUnitId) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' intent unit or event binding drifted."
                    if ($eventMap.ContainsKey($correctionEventId)) {
                        foreach ($eventProperty in @('schema','event_id','sequence','project_id','unit_id','event_type','summary')) {
                            Assert-Contract ([string]$intent.event.$eventProperty -ceq [string]$eventMap[$correctionEventId].$eventProperty) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' intent event property '$eventProperty' drifted."
                        }
                        Assert-Contract ([DateTimeOffset]$intent.event.timestamp -eq [DateTimeOffset]$eventMap[$correctionEventId].timestamp) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' intent event timestamp drifted."
                        Assert-Contract ((@($intent.event.receipts | ForEach-Object { [string]$_ }) -join "|") -ceq (@($eventMap[$correctionEventId].receipts | ForEach-Object { [string]$_ }) -join "|")) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' intent event receipt set drifted."
                    }
                    Assert-Contract ([string]$completion.unit_sha256 -ceq [string]$intent.target.unit.sha256 -and [string]$completion.state_sha256 -ceq [string]$intent.target.state.sha256) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' completion target binding drifted."
                    Assert-Contract ([string]$intent.pre.unit.sha256 -ceq [string]$intent.target.unit.sha256) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' correction changed immutable unit bytes."
                    Assert-Contract (@($intent.artifacts).Count -eq 1) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' intent must bind exactly one correction artifact."
                    if (@($intent.artifacts).Count -eq 1) {
                        $artifact = @($intent.artifacts)[0]
                        Assert-Contract ([string]$artifact.path -ceq $receiptRelativePath -and [string]$artifact.sha256 -ceq [string]$correction.receipt_sha256) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' intent artifact identity drifted."
                        try {
                            $embeddedReceiptBytes = [Convert]::FromBase64String([string]$artifact.bytes_base64)
                            $embeddedReceiptSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($embeddedReceiptBytes)).ToLowerInvariant()
                            Assert-Contract ($embeddedReceiptSha -ceq [string]$correction.receipt_sha256 -and $embeddedReceiptBytes.Length -eq (Get-Item -LiteralPath $receiptPath).Length) "$Context completed-project scope projection for '$adoptedUnitId/$repoId' intent artifact bytes drifted."
                        } catch {
                            Assert-Contract $false "$Context completed-project scope projection for '$adoptedUnitId/$repoId' intent artifact bytes are invalid."
                        }
                    }
                    $lastCorrectionIntent = $intent
                }
            }
            Assert-Contract ($null -ne $lastCorrectionIntent) "$Context completed-project scope projection for '$adoptedUnitId' lacks its final correction intent."
            if ($null -ne $lastCorrectionIntent) {
                $projectProjection = @($lastCorrectionIntent.additional_projections | Where-Object { [string]$_.path -ceq 'project.spec.json' })
                $lockProjection = @($lastCorrectionIntent.additional_projections | Where-Object { [string]$_.path -ceq 'feature.lock.json' })
                Assert-Contract ($projectProjection.Count -eq 1 -and $lockProjection.Count -eq 1) "$Context completed-project scope projection for '$adoptedUnitId' final intent must bind one project spec and one feature lock."
                if ($projectProjection.Count -eq 1) {
                    Assert-Contract ([string]$projectProjection[0].target_sha256 -ceq [string]$projection.project_snapshot.project_sha256 -and [int]$projectProjection[0].document.revision -eq [int]$projection.project_snapshot.project_revision) "$Context completed-project scope projection for '$adoptedUnitId' project snapshot is not bound by the final correction intent."
                }
                if ($lockProjection.Count -eq 1) {
                    Assert-Contract ([string]$lockProjection[0].target_sha256 -ceq [string]$projection.project_snapshot.feature_lock_sha256 -and [int]$lockProjection[0].document.revision -eq [int]$projection.project_snapshot.feature_lock_revision) "$Context completed-project scope projection for '$adoptedUnitId' feature-lock snapshot is not bound by the final correction intent."
                }
                Assert-Contract ([int]$lastCorrectionIntent.target.state.document.plan_revision -eq [int]$projection.project_snapshot.plan_revision) "$Context completed-project scope projection for '$adoptedUnitId' plan snapshot is not bound by the final correction intent."
            }
        }
    }

    # Authenticate every additive cross-unit repair of a historical
    # blocker-resolution completion-to-intent hash mismatch. The shared
    # verifier rejects any second fault, altered retained byte, ambiguous
    # correction, or correction transaction whose current-unit CAS is not
    # recoverable from its immutable intent.
    try {
        [void](Get-MorphospaceHistoricalBlockerResolutionIntentBindingCorrectionIndex -WorkspaceRoot $workspaceRoot -Events $events)
    } catch {
        Add-Failure -Message "$Context historical blocker-resolution intent-binding correction is unauthenticated: $($_.Exception.Message)"
    }

    # Authenticate the one narrow append-only correction that can project a
    # malformed completed legacy-v1 supersession event with its independently
    # retained old-unit endpoint. A receipt path alone never authorizes this
    # projection: the shared verifier binds the historical ledger prefix,
    # original intent/completion, embedded state/units, and correction
    # intent/completion before returning the effective endpoint.
    $completedTransitionCorrections = @{}
    $correctionEventPrefix = 'completed-transition-semantics-corrected-'
    foreach ($candidateCorrectionEvent in @($events | Where-Object { ([string]$_.event_id).StartsWith($correctionEventPrefix, [StringComparison]::Ordinal) })) {
        $candidateId = [string]$candidateCorrectionEvent.event_id
        try {
            if ($candidateId -cnotmatch '^completed-transition-semantics-corrected-[0-9]{4,}$' -or
                [string]$candidateCorrectionEvent.schema -cne 'rusty.morphospace.workflow.iteration_event.v1' -or
                [string]$candidateCorrectionEvent.event_type -cne 'state-transition' -or
                @($candidateCorrectionEvent.receipts).Count -ne 1 -or
                @($candidateCorrectionEvent.receipts)[0] -isnot [string]) {
                throw "Correction event '$candidateId' does not have its exact v1 event shape."
            }
            $receiptRelative = [string]@($candidateCorrectionEvent.receipts)[0]
            $receiptAbsolute = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspaceRoot -RelativePath $receiptRelative -RequireLeaf
            $strictEventBytes = [Text.UTF8Encoding]::new($false).GetBytes(($candidateCorrectionEvent | ConvertTo-Json -Depth 32 -Compress))
            $strictEvent = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $strictEventBytes -Context "correction event '$candidateId'"
            [void]$strictEvent.PSObject.Properties.Remove('__line_sha256')
            $verifiedCorrection = Test-MorphospaceCompletedTransitionSemanticCorrection `
                -WorkspaceRoot $workspaceRoot -ReceiptPath $receiptAbsolute -Mode Projection -CorrectionEvent $strictEvent
            $originalId = [string]$verifiedCorrection.original_event.event_id
            if ($completedTransitionCorrections.ContainsKey($originalId)) {
                throw "Original event '$originalId' has more than one completed-transition semantic correction."
            }
            $completedTransitionCorrections[$originalId] = [pscustomobject][ordered]@{
                correction_event_id = $candidateId
                effective_old_unit_id = [string]$verifiedCorrection.receipt.semantic_correction.effective_old_unit_id
                replacement_unit_id = [string]$verifiedCorrection.receipt.semantic_correction.replacement_unit_id
            }
        } catch {
            Add-Failure -Message "$Context completed-transition correction '$candidateId' is unauthenticated: $($_.Exception.Message)"
        }
    }

    # A corrective unit may supersede an immutable historical active/validating
    # unit without rewriting that unit artifact or its earlier event prefix.
    # The additive state-transition event is the projection override and must
    # render the independently bound event.unit_id and replacement unit as the
    # exact `<old-unit>-superseded-by-<current-unit>` identity. Never infer the
    # old endpoint with a greedy delimiter split.
    $supersededInFlightIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $supersessionDelimiter = '-superseded-by-'
    foreach ($event in $events) {
        $eventId = [string]$event.event_id
        $firstDelimiter = $eventId.IndexOf($supersessionDelimiter, [StringComparison]::Ordinal)
        if ($firstDelimiter -lt 0) { continue }
        $hasOneDelimiter = $firstDelimiter -eq $eventId.LastIndexOf($supersessionDelimiter, [StringComparison]::Ordinal)
        Assert-Contract $hasOneDelimiter "$Context supersession event '$eventId' contains an ambiguous repeated delimiter."
        if (-not $hasOneDelimiter) { continue }
        $oldId = if ($completedTransitionCorrections.ContainsKey($eventId)) {
            [string]$completedTransitionCorrections[$eventId].effective_old_unit_id
        } else {
            [string]$event.unit_id
        }
        $oldEndpointValid = $oldId -match '^[a-z0-9][a-z0-9-]{1,127}$' -and -not $oldId.Contains($supersessionDelimiter, [StringComparison]::Ordinal)
        Assert-Contract $oldEndpointValid "$Context supersession event '$eventId' lacks a portable independently bound old unit or uses the reserved delimiter inside it."
        if (-not $oldEndpointValid) { continue }
        $replacementCandidates = @($unitMap.Keys | Where-Object {
            $candidateId = [string]$_
            $candidateId -cne $oldId -and
            $candidateId -match '^[a-z0-9][a-z0-9-]{1,127}$' -and
            -not $candidateId.Contains($supersessionDelimiter, [StringComparison]::Ordinal) -and
            $eventId -ceq "$oldId$supersessionDelimiter$candidateId"
        })
        Assert-Contract ($replacementCandidates.Count -eq 1) "$Context supersession event '$eventId' does not exactly bind event.unit_id '$oldId' to one independently identified replacement unit document."
        if ($replacementCandidates.Count -ne 1) { continue }
        $currentId = [string]$replacementCandidates[0]
        if ($completedTransitionCorrections.ContainsKey($eventId)) {
            Assert-Contract ([string]$completedTransitionCorrections[$eventId].replacement_unit_id -ceq $currentId) "$Context correction for supersession event '$eventId' does not bind its independently derived replacement '$currentId'."
        }
        Assert-Contract ($eventId -ceq "$oldId$supersessionDelimiter$currentId") "$Context supersession event '$eventId' is not the exact old-to-replacement rendering."
        Assert-Contract ($event.event_type -eq "state-transition") "$Context supersession event '$eventId' must be a state transition."
        Assert-Contract ($unitMap.ContainsKey($oldId)) "$Context supersession event '$eventId' references missing old unit '$oldId'."
        Assert-Contract ($unitMap.ContainsKey($currentId)) "$Context supersession event '$eventId' references missing current unit '$currentId'."
        if ($unitMap.ContainsKey($oldId)) {
            Assert-Contract (@("active", "validating") -contains [string]$unitMap[$oldId].status) "$Context supersession event '$eventId' may override only an immutable active/validating unit."
        }
        if ($unitMap.ContainsKey($currentId)) {
            Assert-Contract (@("active", "validating", "accepted") -contains [string]$unitMap[$currentId].status) "$Context supersession replacement '$currentId' is not current or accepted."
        }
        if ([string]$state.last_event_id -ceq $eventId) {
            Assert-Contract ([string]$state.current_unit -ceq $currentId) "$Context supersession tail '$eventId' does not project replacement '$currentId' as current_unit."
        }
        [void]$supersededInFlightIds.Add($oldId)
    }
    foreach ($candidate in $deferredSupersededInstructionFailures.ToArray()) {
        Assert-Contract ($supersededInFlightIds.Contains([string]$candidate.unit_id)) ([string]$candidate.message)
    }
    foreach ($candidate in $legacySkillReviewCandidates.ToArray()) {
        Assert-Contract (Test-LegacySkillReviewCompatibility `
            -Candidate $candidate `
            -UnitMap $unitMap `
            -EventMap $eventMap `
            -SupersededInFlightIds $supersededInFlightIds `
            -State $state) "$Context legacy unit '$($candidate.unit_id)' relevant skill '$($candidate.skill_id)' review-no-change is not eligible for the canonical legacy terminal skill-review compatibility projection."
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
    $script:GuardProfiles = @($lifecycle.guard_profiles | ForEach-Object { [string]$_.id })
    $script:WorkModes = @($lifecycle.work_modes | ForEach-Object { [string]$_ })
    $script:DeviceRequirements = @($lifecycle.device_requirements | ForEach-Object { [string]$_ })
    $script:PushCheckpoints = @($lifecycle.push_checkpoints | ForEach-Object { [string]$_ })
    $script:ChangeCategories = @($lifecycle.change_categories | ForEach-Object { [string]$_ })
    Assert-Contract (($script:WorkModes -join "|") -eq "feature|validation-only") "Workflow work modes must expose feature and validation-only in that order."
    Assert-Contract (($script:GuardProfiles -join "|") -eq "fast|labs|locked") "Workflow guard profiles must expose fast, labs, and locked in increasing authority order."
    Assert-Contract ([int]$lifecycle.workflow_stability.feature_units_before_protocol_change -eq 3) "Workflow stability must freeze protocol changes for three feature units."
    Assert-Contract ([int]$lifecycle.workflow_stability.target_feature_work_percent -eq 70) "Workflow stability must target seventy percent feature work."
    Assert-Contract ([string]$lifecycle.workflow_stability.validation_only_instruction_action -eq "review-no-change") "Validation-only units must use review-no-change instruction handling."
    Assert-Contract ($lifecycle.workflow_stability.unit_captain_through_acceptance -eq $true) "Workflow stability must keep one unit captain through acceptance."
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
    $script:WorkModes = @()
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
    "historical-blocker-resolution-intent-binding-correction-v1.schema.json",
    "active-read-only-dependency-correction-v1.schema.json",
    "completed-transition-semantic-correction-v1.schema.json",
    "legacy-embedded-push-bundle-plan-v1.schema.json",
    "work-unit-automation-receipt-v2.schema.json",
    "published-planning-authority-adoption.schema.json",
    "published-prerequisite-suffix-reconciliation.schema.json",
    "executed-prepared-publication-reconciliation.schema.json",
    "prepared-push-transaction-suffix-reconciliation-v1.schema.json",
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
    "unpublished-workspace-materialization-v1.schema.json",
    "unpublished-planning-authority-receipt-v1.schema.json",
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
$iterationUnitSchemaPath = Join-Path $schemaRoot "iteration-unit.schema.json"
$iterationUnitSchema = Read-JsonDocument -Path $iterationUnitSchemaPath -Context "iteration-unit schema parity"
if ($null -ne $iterationUnitSchema) {
    $expectedPushCheckpoints = @("none", "local-only", "integration-batch", "manual-owner-review", "release")
    $schemaPushCheckpoints = @($iterationUnitSchema.properties.push_checkpoint.enum | ForEach-Object { [string]$_ })
    Assert-Contract (($script:PushCheckpoints -join "|") -ceq ($expectedPushCheckpoints -join "|")) "Workflow lifecycle push checkpoints are not in the established closed order."
    Assert-Contract (($script:PushCheckpoints -join "|") -ceq ($schemaPushCheckpoints -join "|")) "Workflow lifecycle and iteration-unit schema push checkpoints drifted."
    $schemaInstructionSurfaceKinds = @($iterationUnitSchema.properties.instruction_surfaces.items.properties.surface_kind.enum | ForEach-Object { [string]$_ })
    $expectedInstructionSurfaceKinds = @("agents", "readme", "router-doc", "validation-doc", "compatibility-doc", "roadmap-doc", "skill")
    Assert-Contract (($script:InstructionSurfaceKinds -join "|") -ceq ($expectedInstructionSurfaceKinds -join "|")) "Workflow lifecycle instruction surface kinds are not in the established closed order."
    Assert-Contract (($script:InstructionSurfaceKinds -join "|") -ceq ($schemaInstructionSurfaceKinds -join "|")) "Workflow lifecycle and iteration-unit schema instruction surface kinds drifted."
}
$projectSpecV2SchemaPath = Join-Path $schemaRoot "project-spec-v2.schema.json"
$projectSpecV2Schema = Read-JsonDocument -Path $projectSpecV2SchemaPath -Context "project-spec push checkpoint parity"
if ($null -ne $projectSpecV2Schema) {
    $projectPushCheckpoints = @($projectSpecV2Schema.properties.release_policy.properties.push_checkpoint.enum | ForEach-Object { [string]$_ })
    Assert-Contract (($script:PushCheckpoints -join "|") -ceq ($projectPushCheckpoints -join "|")) "Workflow lifecycle and project-spec schema push checkpoints drifted."
}
$automationReceiptSchemaPath = Join-Path $schemaRoot "work-unit-automation-receipt.schema.json"
$automationReceiptSchemaDocument = Read-JsonDocument -Path $automationReceiptSchemaPath -Context "automation-receipt instruction surface parity"
if ($null -ne $automationReceiptSchemaDocument) {
    $receiptInstructionSurfaceKinds = @($automationReceiptSchemaDocument.properties.instruction_surface_completion.oneOf[0].properties.surfaces.items.properties.surface_kind.enum | ForEach-Object { [string]$_ })
    Assert-Contract (($script:InstructionSurfaceKinds -join "|") -ceq ($receiptInstructionSurfaceKinds -join "|")) "Workflow lifecycle and automation-receipt instruction surface kinds drifted."
}
Invoke-CurrentInstructionSurfacePolicySelfTest -TemplateRoot $templatesRoot -SchemaPath $iterationUnitSchemaPath

if ($CurrentUnitInstructionOnly) {
    if (-not $WorkspaceRoot) {
        Add-Failure -Message "CurrentUnitInstructionOnly requires WorkspaceRoot."
    } else {
        $resolvedCurrentWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
        Test-CurrentUnitInstructionWorkspace -Root $resolvedCurrentWorkspace -SchemaPath $iterationUnitSchemaPath
    }
    if ($script:Failures.Count -gt 0) {
        Write-Host "Current-unit instruction contract failures:"
        foreach ($failure in $script:Failures) { Write-Host " - $failure" }
        throw "Current-unit instruction contract failed with $($script:Failures.Count) error(s)."
    }
    Write-Host "Current-unit instruction contract passed; immutable historical units were not inspected or reclassified."
    return
}

foreach ($contractExample in @(
    [pscustomobject]@{ Template = "unpublished-workspace-materialization.example.json"; Schema = "unpublished-workspace-materialization-v1.schema.json" },
    [pscustomobject]@{ Template = "planning-workspace-projection.example.json"; Schema = "planning-workspace-projection.schema.json" },
    [pscustomobject]@{ Template = "planning-workspace-projection-v2.example.json"; Schema = "planning-workspace-projection.schema.json" },
    [pscustomobject]@{ Template = "planning-workspace-projection-v3.example.json"; Schema = "planning-workspace-projection.schema.json" },
    [pscustomobject]@{ Template = "published-planning-authority-adoption.example.json"; Schema = "published-planning-authority-adoption.schema.json" },
    [pscustomobject]@{ Template = "published-active-planning-authority-adoption.example.json"; Schema = "published-planning-authority-adoption.schema.json" },
    [pscustomobject]@{ Template = "historical-unit-adoption-reconstruction.example.json"; Schema = "historical-unit-adoption-reconstruction.schema.json" },
    [pscustomobject]@{ Template = "external-validation-authority-policy.example.json"; Schema = "external-validation-authority-policy-v1.schema.json" },
    [pscustomobject]@{ Template = "iteration-unit-validation-only.example.json"; Schema = "iteration-unit.schema.json" },
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
    claim_preflight = [ordered]@{
        version = "v1"; ready_to_claim = $true; validation_tier = "standard"; requirements_declared = $false
        disk = @(); tools = @(); product_inputs = @()
        writable_repositories = @(); read_only_dependencies = @(); instruction_surfaces = @()
        resources = @(); validation_matrix = @(); issues = @()
    }
    adoption_receipt = $null
    publication_closure = $null
    published_planning_authority_adoption = $automationAdoptionBinding
    planned_publication = $null
    planning_suffix_rewrite_recovery = $null
    published_prerequisite_suffix_reconciliation = $null
    executed_prepared_publication_reconciliation = $null
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
$automationReceipt.published_planning_authority_adoption = $null
$automationReceipt.action = "ReconcileExecutedPreparedPublication"
$automationReceipt.executed_prepared_publication_reconciliation = [ordered]@{
    reconciliation_id = "example-executed-prepared-reconciliation"
    path = "receipts/example-executed-prepared-reconciliation.json"
    sha256 = ("b" * 64)
    executed_push_receipt = [ordered]@{ path = "receipts/example-executed-push.json"; sha256 = ("c" * 64) }
}
Assert-Contract ($automationReceipt | ConvertTo-Json -Depth 16 | Test-Json -SchemaFile $automationReceiptSchema -ErrorAction Stop) "Executed prepared-publication automation receipt with its exact binding was rejected."
$automationReceipt.executed_prepared_publication_reconciliation = $null
Assert-Contract (-not ($automationReceipt | ConvertTo-Json -Depth 16 | Test-Json -SchemaFile $automationReceiptSchema -ErrorAction SilentlyContinue)) "Executed prepared-publication automation receipt without its binding was accepted."
$automationReceipt.action = "Inspect"
$automationReceipt.executed_prepared_publication_reconciliation = [ordered]@{ reconciliation_id = "example-executed-prepared-reconciliation"; path = "receipts/example.json"; sha256 = ("b" * 64); executed_push_receipt = [ordered]@{ path = "receipts/executed.json"; sha256 = ("c" * 64) } }
Assert-Contract (-not ($automationReceipt | ConvertTo-Json -Depth 16 | Test-Json -SchemaFile $automationReceiptSchema -ErrorAction SilentlyContinue)) "Non-reconciliation automation receipt with an executed prepared-publication binding was accepted."

$v2ClosureExample = Read-JsonDocument -Path (Join-Path $templatesRoot "unplanned-publication-closure-v2.example.json") -Context "v2 unplanned-publication closure example"
if ($v2ClosureExample) {
    Assert-Contract ([string]$v2ClosureExample.schema -ceq "rusty.morphospace.workflow.unplanned_publication_closure.v2") "V2 unplanned-publication closure example has the wrong discriminator."
    Assert-Contract ($null -ne $v2ClosureExample.planning_workspace_projection) "V2 unplanned-publication closure example lacks projection evidence."
}
Invoke-LegacySkillReviewCompatibilitySelfTest

function Invoke-LegacySkillReviewBundleSelfTest {
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("morphospace-legacy-skill-review-" + [guid]::NewGuid().ToString("N"))
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    try {
        $unit = Read-JsonDocument -Path (Join-Path $templatesRoot "iteration-unit.example.json") -Context "legacy skill-review fixture unit source"
        [void]$unit.PSObject.Properties.Remove("work_mode")
        $unit.status = "accepted"
        foreach ($surface in @($unit.instruction_surfaces)) {
            $surface.status = "complete"
            if ([string]$surface.surface_kind -ceq "skill") { $surface.action = "review-no-change" }
        }
        $state = Read-JsonDocument -Path (Join-Path $templatesRoot "workspace.state.example.json") -Context "legacy skill-review fixture state source"
        $state.current_unit = $null
        $state.last_event_id = "$([string]$unit.unit_id)-accepted-0001"
        $event = [pscustomobject][ordered]@{
            schema = "rusty.morphospace.workflow.iteration_event.v1"
            event_id = [string]$state.last_event_id
            sequence = 1
            timestamp = "2026-01-01T00:00:00Z"
            project_id = [string]$unit.project_id
            unit_id = [string]$unit.unit_id
            event_type = "state-transition"
            summary = "Accepted the immutable pre-work_mode compatibility fixture."
            receipts = @()
        }
        $utf8 = [Text.UTF8Encoding]::new($false)
        $unitPath = Join-Path $fixtureRoot "unit.json"
        $statePath = Join-Path $fixtureRoot "state.json"
        $eventsPath = Join-Path $fixtureRoot "events.jsonl"
        [IO.File]::WriteAllText($unitPath, ($unit | ConvertTo-Json -Depth 32), $utf8)
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 32), $utf8)
        [IO.File]::WriteAllText($eventsPath, (($event | ConvertTo-Json -Depth 16 -Compress) + [Environment]::NewLine), $utf8)
        $bundle = New-Bundle `
            -SpecPath (Join-Path $templatesRoot "project.spec.example.json") `
            -LockPath (Join-Path $templatesRoot "feature.lock.example.json") `
            -StatePath $statePath `
            -CandidatePaths @((Join-Path $templatesRoot "module-candidate.example.json")) `
            -UnitPaths @($unitPath) `
            -ReviewPaths @((Join-Path $templatesRoot "promotion-review.example.json")) `
            -EventsPath $eventsPath
        Test-ProjectBundle -Bundle $bundle -Context "legacy terminal skill-review compatibility fixture"
    } finally {
        if ([IO.Directory]::Exists($fixtureRoot)) {
            [IO.Directory]::Delete($fixtureRoot, $true)
        }
    }
}

Invoke-LegacySkillReviewBundleSelfTest

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
    [pscustomobject]@{ Template = "prepared-push-transaction-suffix-reconciliation.example.json"; Schema = "prepared-push-transaction-suffix-reconciliation-v1.schema.json"; Label = "Prepared-push transaction-suffix reconciliation" },
    [pscustomobject]@{ Template = "prepared-push-retirement.example.json"; Schema = "prepared-push-retirement-v1.schema.json"; Label = "Prepared-push retirement" },
    [pscustomobject]@{ Template = "legacy-embedded-push-bundle-plan.example.json"; Schema = "legacy-embedded-push-bundle-plan-v1.schema.json"; Label = "Legacy embedded push-plan" },
    [pscustomobject]@{ Template = "prepared-publication-reconstruction.example.json"; Schema = "prepared-publication-reconstruction-v1.schema.json"; Label = "Prepared-publication reconstruction" },
    [pscustomobject]@{ Template = "blocker-resolution-receipt.example.json"; Schema = "blocker-resolution-receipt-v1.schema.json"; Label = "Blocker-resolution" },
    [pscustomobject]@{ Template = "blocker-resolution-correction-receipt.example.json"; Schema = "blocker-resolution-correction-receipt-v1.schema.json"; Label = "Blocker-resolution correction" },
    [pscustomobject]@{ Template = "historical-blocker-resolution-intent-binding-correction.example.json"; Schema = "historical-blocker-resolution-intent-binding-correction-v1.schema.json"; Label = "Historical blocker-resolution intent-binding correction" },
    [pscustomobject]@{ Template = "active-read-only-dependency-correction.example.json"; Schema = "active-read-only-dependency-correction-v1.schema.json"; Label = "Active read-only dependency correction" },
    [pscustomobject]@{ Template = "active-write-scope-amendment.example.json"; Schema = "active-write-scope-amendment-v1.schema.json"; Label = "Active write-scope amendment" }
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
    foreach ($selfTest in @("Test-LegacyEmbeddedPushPlanCompatibility.ps1","Test-PreparedPublicationReconstruction.ps1","Test-ResolveBlocker.ps1","Test-CorrectResolvedBlockerEvidence.ps1","Test-HistoricalBlockerResolutionIntentBindingCorrection.ps1","Test-CorrectActiveReadOnlyDependencies.ps1","Test-CorrectActiveProjectRepositoryScope.ps1","Test-ActiveWriteScopeAmendment.ps1","Test-CompletedTransitionSemanticCorrection.ps1","Test-TransitionLedger.ps1")) {
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

$executedPreparedTemplate = Join-Path $templatesRoot "executed-prepared-publication-reconciliation.example.json"
$executedPreparedValidator = Join-Path $RepoRoot "scripts\Test-ExecutedPreparedPublicationReconciliation.ps1"
Assert-Contract (Test-Path -LiteralPath $executedPreparedTemplate -PathType Leaf) "Required executed prepared-publication reconciliation example is missing."
Assert-Contract (Test-Path -LiteralPath $executedPreparedValidator -PathType Leaf) "Required executed prepared-publication reconciliation validator is missing."
if (Test-Path -LiteralPath $executedPreparedTemplate -PathType Leaf) {
    try { Assert-Contract (Get-Content -Raw -LiteralPath $executedPreparedTemplate | Test-Json -SchemaFile (Join-Path $schemaRoot 'executed-prepared-publication-reconciliation.schema.json') -ErrorAction Stop) "Executed prepared-publication reconciliation example was rejected by its schema." }
    catch { Add-Failure -Message "Executed prepared-publication reconciliation example schema validation failed: $($_.Exception.Message)" }
}
if ((-not $SkipOwnerSelfTests) -and (Test-Path -LiteralPath $executedPreparedValidator -PathType Leaf)) {
    try { & $executedPreparedValidator -SelfTest | Out-Null }
    catch { Add-Failure -Message "Executed prepared-publication reconciliation self-test failed: $($_.Exception.Message)" }
}

$preparedPushSuffixTemplate = Join-Path $templatesRoot "prepared-push-transaction-suffix-reconciliation.example.json"
$preparedPushSuffixValidator = Join-Path $RepoRoot "scripts\Test-PreparedPushTransactionSuffixReconciliation.ps1"
Assert-Contract (Test-Path -LiteralPath $preparedPushSuffixTemplate -PathType Leaf) "Required prepared-push transaction-suffix reconciliation example is missing."
Assert-Contract (Test-Path -LiteralPath $preparedPushSuffixValidator -PathType Leaf) "Required prepared-push transaction-suffix reconciliation validator is missing."
if ((-not $SkipOwnerSelfTests) -and (Test-Path -LiteralPath $preparedPushSuffixValidator -PathType Leaf)) {
    try { & $preparedPushSuffixValidator -SelfTest | Out-Null }
    catch { Add-Failure -Message "Prepared-push transaction-suffix reconciliation self-test failed: $($_.Exception.Message)" }
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
