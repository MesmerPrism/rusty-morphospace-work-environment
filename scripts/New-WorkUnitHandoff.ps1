param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$RepoMapPath,
    [string]$Timestamp = "",
    [string]$OutPath = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Read-HandoffJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required handoff input is missing: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-HandoffSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-HandoffGit([string]$Path, [string[]]$Arguments) {
    $output = @(& git -C $Path @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Git handoff observation failed for '$Path': git $($Arguments -join ' ')" }
    return ($output -join "`n").Trim()
}

$workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$unitRelative = "iteration-units/$UnitId.json"
$unitPath = Join-Path $workspace $unitRelative
$statePath = Join-Path $workspace "workspace.state.json"
$eventsPath = Join-Path $workspace "iteration-events.jsonl"
$spec = Read-HandoffJson (Join-Path $workspace "project.spec.json")
$unit = Read-HandoffJson $unitPath
$state = Read-HandoffJson $statePath
$repoMapDocument = Read-HandoffJson $RepoMapPath
if ([string]$repoMapDocument.schema -ne "rusty.morphospace.workflow.repository_map.v1") { throw "Repository map has the wrong schema ID." }
if ([string]$unit.unit_id -ne $UnitId -or [string]$unit.project_id -ne [string]$spec.project_id -or [string]$state.project_id -ne [string]$spec.project_id) { throw "Handoff project/unit identities do not agree." }
if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString("o") }

$repoMap = @{}
foreach ($entry in @($repoMapDocument.repositories)) {
    $repoId = [string]$entry.repo_id
    if ($repoMap.ContainsKey($repoId)) { throw "Repository map repeats '$repoId'." }
    $repoMap[$repoId] = $entry
}

$repositoryRows = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($repo in @($unit.allowed_repositories | Sort-Object repo_id)) {
    $repoId = [string]$repo.repo_id
    if (-not $repoMap.ContainsKey($repoId)) { throw "Writable repository '$repoId' is absent from the repository map." }
    $root = [string]$repoMap[$repoId].path
    $head = Invoke-HandoffGit $root @("rev-parse", "HEAD")
    $tree = Invoke-HandoffGit $root @("rev-parse", "HEAD^{tree}")
    $dirty = [bool](Invoke-HandoffGit $root @("status", "--porcelain=v1", "--untracked-files=all"))
    $repositoryRows.Add([pscustomobject][ordered]@{ repo_id = $repoId; access = "write"; head = $head; tree = $tree; dirty = $dirty; paths = @($repo.allowed_paths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique) }) | Out-Null
    $seen[$repoId] = $true
}
foreach ($dependency in @($(if ($unit.PSObject.Properties.Name -contains "read_only_dependencies") { @($unit.read_only_dependencies) } else { @() }) | Sort-Object repo_id)) {
    $repoId = [string]$dependency.repo_id
    if ($seen.ContainsKey($repoId)) { continue }
    if (-not $repoMap.ContainsKey($repoId)) { throw "Read-only repository '$repoId' is absent from the repository map." }
    $root = [string]$repoMap[$repoId].path
    $inside = @(& git -C $root rev-parse --is-inside-work-tree 2>$null)
    if ($LASTEXITCODE -eq 0 -and ($inside -join '').Trim() -eq 'true') {
        $head = Invoke-HandoffGit $root @("rev-parse", "HEAD")
        $tree = Invoke-HandoffGit $root @("rev-parse", "HEAD^{tree}")
        $dirty = [bool](Invoke-HandoffGit $root @("status", "--porcelain=v1", "--untracked-files=all"))
    } else { $head = $null; $tree = $null; $dirty = $null }
    $repositoryRows.Add([pscustomobject][ordered]@{ repo_id = $repoId; access = "read-only"; head = $head; tree = $tree; dirty = $dirty; paths = @($dependency.paths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique) }) | Out-Null
    $seen[$repoId] = $true
}

$eventLines = @(Get-Content -LiteralPath $eventsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$workMode = if ($unit.PSObject.Properties.Name -contains "work_mode") { [string]$unit.work_mode } else { "feature" }
$nextAction = switch ([string]$unit.status) {
    "proposed" { "Ready" }
    "ready" { "Claim" }
    "active" { if ([string]$unit.instruction_impact -ne "none" -and @($unit.instruction_surfaces | Where-Object { [string]$_.status -ne "complete" }).Count -gt 0) { "CompleteInstructionSurfaces" } else { "BeginValidation" } }
    "validating" { if ($null -ne $state.validation_checkpoint) { "Accept" } else { "RecordValidation" } }
    "accepted" { if ([string]$unit.push_checkpoint -eq "none") { "terminal" } else { "PreparePush" } }
    default { "terminal" }
}

$document = [pscustomobject][ordered]@{
    schema = "rusty.morphospace.workflow.work_unit_handoff.v1"
    generated_at = $Timestamp
    project_id = [string]$spec.project_id
    unit = [pscustomobject][ordered]@{
        unit_id = $UnitId; path = $unitRelative; sha256 = Get-HandoffSha256 $unitPath
        status = [string]$unit.status; work_mode = $workMode; objective = [string]$unit.objective
        risk_tier = [string]$unit.risk_tier; device_requirement = [string]$unit.device_requirement
    }
    workspace = [pscustomobject][ordered]@{
        state_sha256 = Get-HandoffSha256 $statePath; event_ledger_sha256 = Get-HandoffSha256 $eventsPath
        current_unit = $state.current_unit; last_event_id = $state.last_event_id
        event_count = $eventLines.Count; blockers = @($state.blockers)
    }
    repositories = @($repositoryRows.ToArray())
    commands = [pscustomobject][ordered]@{
        validation = @($unit.validation | ForEach-Object { [pscustomobject][ordered]@{ command_id = [string]$_.profile_id; command = [string]$_.command } })
        acceptance = @($unit.acceptance | ForEach-Object { [pscustomobject][ordered]@{ command_id = [string]$_.acceptance_id; command = [string]$_.command } })
    }
    instruction_surfaces = @($unit.instruction_surfaces | ForEach-Object { [pscustomobject][ordered]@{ path = ([string]$_.path).Replace('\', '/'); action = [string]$_.action; status = [string]$_.status } })
    claim_requirements = if ($unit.PSObject.Properties.Name -contains "claim_requirements") { $unit.claim_requirements } else { $null }
    resources = @($(if ($unit.PSObject.Properties.Name -contains "resource_requirements") { @($unit.resource_requirements) } else { @() }))
    outputs = @($unit.outputs)
    next_action = $nextAction
}

if ($Execute) {
    if (-not $OutPath) { throw "Executed handoff generation requires OutPath." }
    $out = [IO.Path]::GetFullPath($OutPath)
    $prefix = $workspace.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $out.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Handoff OutPath must remain inside the project morphospace workspace." }
    $parent = Split-Path -Parent $out
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($out, (($document | ConvertTo-Json -Depth 32) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

$document | ConvertTo-Json -Depth 32
