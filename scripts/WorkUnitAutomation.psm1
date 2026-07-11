Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Read-MorphospaceJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file is missing: $Path"
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Invalid JSON in '$Path': $($_.Exception.Message)"
    }
}

function Write-MorphospaceJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 32) + [Environment]::NewLine), $encoding)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-MorphospaceEvents {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Iteration event log is missing: $Path"
    }
    $events = New-Object System.Collections.Generic.List[object]
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $events.Add(($line | ConvertFrom-Json)) | Out-Null
        } catch {
            throw "Invalid JSON in '$Path' at line $lineNumber`: $($_.Exception.Message)"
        }
    }
    return @($events.ToArray())
}

function Add-MorphospaceEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Event
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $line = ($Event | ConvertTo-Json -Depth 16 -Compress) + [Environment]::NewLine
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        try { $writer.Write($line) } finally { $writer.Dispose() }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-MorphospaceGitOutput {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git -C $RepositoryPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Git command failed in '$RepositoryPath': git $($Arguments -join ' ')"
    }
    return [pscustomobject]@{ exit_code = $exitCode; lines = @($output); text = ($output -join [Environment]::NewLine).Trim() }
}

function Get-MorphospaceRepositoryState {
    param(
        [Parameter(Mandatory = $true)][string]$RepoId,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject][ordered]@{
            repo_id = $RepoId; path = $Path; available = $false; is_git = $false
            head = $null; branch = $null; upstream = $null; dirty = $null
            tracked_changes = $null; untracked_changes = $null; ahead = $null
            behind = $null; diverged = $null; relation = "missing"; status_porcelain = @()
        }
    }

    $inside = Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "--is-inside-work-tree") -AllowFailure
    if ($inside.exit_code -ne 0 -or $inside.text -ne "true") {
        return [pscustomobject][ordered]@{
            repo_id = $RepoId; path = $Path; available = $true; is_git = $false
            head = $null; branch = $null; upstream = $null; dirty = $null
            tracked_changes = $null; untracked_changes = $null; ahead = $null
            behind = $null; diverged = $null; relation = "not-git"; status_porcelain = @()
        }
    }

    $head = (Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "HEAD")).text
    $branchResult = Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
    $branch = if ($branchResult.exit_code -eq 0) { $branchResult.text } else { $null }
    $upstreamResult = Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}") -AllowFailure
    $upstream = if ($upstreamResult.exit_code -eq 0) { $upstreamResult.text } else { $null }
    $status = Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    $statusLines = @($status.lines | ForEach-Object { [string]$_ })
    $tracked = @($statusLines | Where-Object { -not $_.StartsWith("??") }).Count
    $untracked = @($statusLines | Where-Object { $_.StartsWith("??") }).Count
    $ahead = $null
    $behind = $null
    $relation = if ($null -eq $branch) { "detached" } elseif ($null -eq $upstream) { "no-upstream" } else { "unknown" }
    if ($upstream) {
        $counts = (Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-list", "--left-right", "--count", "HEAD...@{upstream}")).text -split "\s+"
        if ($counts.Count -ne 2) { throw "Unexpected ahead/behind output for '$RepoId'." }
        $ahead = [int]$counts[0]
        $behind = [int]$counts[1]
        if ($ahead -gt 0 -and $behind -gt 0) { $relation = "diverged" }
        elseif ($ahead -gt 0) { $relation = "ahead" }
        elseif ($behind -gt 0) { $relation = "behind" }
        else { $relation = "synchronized" }
    }

    return [pscustomobject][ordered]@{
        repo_id = $RepoId
        path = (Resolve-Path -LiteralPath $Path).Path
        available = $true
        is_git = $true
        head = $head
        branch = $branch
        upstream = $upstream
        dirty = ($statusLines.Count -gt 0)
        tracked_changes = $tracked
        untracked_changes = $untracked
        ahead = $ahead
        behind = $behind
        diverged = ($relation -eq "diverged")
        relation = $relation
        status_porcelain = $statusLines
    }
}

function Get-MorphospaceRepositoryMap {
    param([string]$RepoMapPath)

    $map = @{}
    if (-not $RepoMapPath) { return $map }
    $document = Read-MorphospaceJson -Path $RepoMapPath
    if ([string]$document.schema -ne "rusty.morphospace.workflow.repository_map.v1") {
        throw "Repository map has the wrong schema ID."
    }
    foreach ($entry in @($document.repositories)) {
        $repoId = [string]$entry.repo_id
        if (-not $repoId) { throw "Repository map contains an entry without repo_id." }
        if ($map.ContainsKey($repoId)) { throw "Repository map repeats '$repoId'." }
        $map[$repoId] = $entry
    }
    return $map
}

function New-MorphospaceRepositorySummary {
    param([Parameter(Mandatory = $true)][object]$State)

    $summary = [ordered]@{ repo_id = [string]$State.repo_id }
    foreach ($name in @("mapped", "available", "is_git", "head", "branch", "upstream", "dirty", "tracked_changes", "untracked_changes", "ahead", "behind", "diverged", "relation")) {
        if ($State.PSObject.Properties.Name -contains $name) { $summary[$name] = $State.$name }
    }
    return [pscustomobject]$summary
}

function Get-MorphospaceUnitMap {
    param([Parameter(Mandatory = $true)][string]$UnitRoot)

    $map = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $UnitRoot -Filter "*.json" -File | Sort-Object Name)) {
        $unit = Read-MorphospaceJson -Path $file.FullName
        $unitId = [string]$unit.unit_id
        if ($map.ContainsKey($unitId)) { throw "Duplicate iteration unit '$unitId'." }
        $map[$unitId] = [pscustomobject]@{ document = $unit; path = $file.FullName }
    }
    return $map
}

function New-MorphospaceValidationMatrix {
    param(
        [Parameter(Mandatory = $true)][object]$Unit,
        [string[]]$DeviceSerials = @()
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $order = 0
    foreach ($validation in @($Unit.validation)) {
        $order++
        $rows.Add([pscustomobject][ordered]@{
            order = $order; gate_id = "validation-$([string]$validation.profile_id)"
            kind = "command"; profile_id = [string]$validation.profile_id
            command = [string]$validation.command; disposition = "required"
        }) | Out-Null
    }
    if ([string]$Unit.instruction_impact -ne "none") {
        $order++
        $rows.Add([pscustomobject][ordered]@{
            order = $order; gate_id = "instruction-synchronization"; kind = "instruction"
            profile_id = "instruction-sync"; command = "Verify every declared instruction surface is complete and validated."
            disposition = "required"
        }) | Out-Null
    }
    $deviceRequirement = [string]$Unit.device_requirement
    if ($deviceRequirement -eq "forbidden") {
        $order++
        $rows.Add([pscustomobject][ordered]@{
            order = $order; gate_id = "device-validation"; kind = "device"
            profile_id = "device"; command = "Do not run live device operations for this unit."
            disposition = "forbidden"; serials = @()
        }) | Out-Null
    } elseif ($deviceRequirement -ne "none") {
        $order++
        $disposition = if ($DeviceSerials.Count -gt 0) { "serial-scoped-plan-required" } elseif ($deviceRequirement -eq "required") { "blocked-missing-serials" } else { "optional-not-selected" }
        $rows.Add([pscustomobject][ordered]@{
            order = $order; gate_id = "device-validation"; kind = "device"
            profile_id = "device"; command = "Use the device workflow with only the explicitly supplied serials."
            disposition = $disposition; serials = @($DeviceSerials | Sort-Object -Unique)
        }) | Out-Null
    }
    return @($rows.ToArray())
}

function New-MorphospaceGraphScope {
    param([Parameter(Mandatory = $true)][object]$Unit)

    $repos = New-Object System.Collections.Generic.List[object]
    foreach ($repo in @($Unit.allowed_repositories | Sort-Object repo_id)) {
        $repos.Add([pscustomobject][ordered]@{
            repo_id = [string]$repo.repo_id
            allowed_paths = @($repo.allowed_paths | ForEach-Object { ([string]$_ -replace "\\", "/") } | Sort-Object -Unique)
        }) | Out-Null
    }
    return [pscustomobject][ordered]@{
        change_categories = @($Unit.change_categories | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        repositories = @($repos.ToArray())
        exclusion = "Do not scan repositories or paths outside this list."
    }
}

function New-MorphospaceEvent {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$ActionSlug,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$EventType,
        [Parameter(Mandatory = $true)][string]$Summary,
        [string[]]$Receipts = @()
    )

    $sequence = if ($Events.Count -eq 0) { 1 } else { ([int]($Events | Sort-Object sequence | Select-Object -Last 1).sequence) + 1 }
    $eventId = "$UnitId-$ActionSlug-$('{0:d4}' -f $sequence)"
    return [pscustomobject][ordered]@{
        schema = "rusty.morphospace.workflow.iteration_event.v1"
        event_id = $eventId; sequence = $sequence; timestamp = $Timestamp
        project_id = [string]$State.project_id; unit_id = $UnitId
        event_type = $EventType; summary = $Summary; receipts = @($Receipts)
    }
}

function Test-MorphospacePrerequisites {
    param(
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][hashtable]$UnitMap
    )

    foreach ($prerequisite in @($Unit.prerequisites)) {
        $id = [string]$prerequisite
        if (-not $UnitMap.ContainsKey($id) -or [string]$UnitMap[$id].document.status -ne "accepted") {
            throw "Prerequisite '$id' is not accepted."
        }
    }
}

function Test-MorphospaceInstructionCompletion {
    param([Parameter(Mandatory = $true)][object]$Unit)

    if ([string]$Unit.instruction_impact -eq "none") { return }
    $incomplete = @($Unit.instruction_surfaces | Where-Object { [string]$_.status -ne "complete" })
    if ($incomplete.Count -gt 0) {
        throw "Instruction surfaces are incomplete: $(@($incomplete | ForEach-Object { [string]$_.path }) -join ', ')"
    }
}

function Invoke-MorphospaceWorkUnitAutomation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Inspect", "Claim", "Resume", "BeginValidation", "RecordValidation", "Accept", "PreparePush", "Recover")][string]$Action,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [string]$UnitId = "",
        [string]$RepoMapPath = "",
        [string]$RevisionsPath = "",
        [ValidateSet("pass", "partial", "fail", "blocked")][string]$ValidationResult = "pass",
        [string]$ValidationReceipt = "",
        [ValidateSet("quick", "standard", "deep")][string]$ValidationTier = "standard",
        [string[]]$DeviceSerials = @(),
        [string]$Timestamp = "",
        [string]$OutPath = "",
        [switch]$Execute
    )

    $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $receiptReference = $null
    if ($Execute -and $OutPath) {
        $resolvedOutPath = [System.IO.Path]::GetFullPath($OutPath)
        $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedOutPath.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "OutPath for an executed action must stay inside the project morphospace workspace."
        }
        $OutPath = $resolvedOutPath
        $receiptReference = $resolvedOutPath.Substring($workspacePrefix.Length).Replace("\", "/")
    }
    $spec = Read-MorphospaceJson -Path (Join-Path $resolvedWorkspace "project.spec.json")
    $statePath = Join-Path $resolvedWorkspace "workspace.state.json"
    $eventsPath = Join-Path $resolvedWorkspace "iteration-events.jsonl"
    $state = Read-MorphospaceJson -Path $statePath
    $events = @(Read-MorphospaceEvents -Path $eventsPath)
    $unitMap = Get-MorphospaceUnitMap -UnitRoot (Join-Path $resolvedWorkspace "iteration-units")
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString("o") }

    if (-not $UnitId) {
        if ($state.current_unit) { $UnitId = [string]$state.current_unit }
        elseif ($state.next_ready_unit) { $UnitId = [string]$state.next_ready_unit }
        else { throw "UnitId is required because workspace state has no current or next-ready unit." }
    }
    if (-not $unitMap.ContainsKey($UnitId)) { throw "Iteration unit '$UnitId' does not exist." }
    $unitEntry = $unitMap[$UnitId]
    $unit = $unitEntry.document
    if ([string]$unit.project_id -ne [string]$spec.project_id -or [string]$state.project_id -ne [string]$spec.project_id) {
        throw "Project identifiers do not agree."
    }

    $repoMap = Get-MorphospaceRepositoryMap -RepoMapPath $RepoMapPath
    $repositoryStates = New-Object System.Collections.Generic.List[object]
    foreach ($repo in @($unit.allowed_repositories | Sort-Object repo_id)) {
        $repoId = [string]$repo.repo_id
        if ($repoMap.ContainsKey($repoId)) {
            $repositoryStates.Add((Get-MorphospaceRepositoryState -RepoId $repoId -Path ([string]$repoMap[$repoId].path))) | Out-Null
        } else {
            $repositoryStates.Add([pscustomobject][ordered]@{ repo_id = $repoId; mapped = $false; relation = "not-mapped" }) | Out-Null
        }
    }
    $repoStatesArray = @($repositoryStates.ToArray())
    $validationMatrix = @(New-MorphospaceValidationMatrix -Unit $unit -DeviceSerials $DeviceSerials)
    $graphScope = New-MorphospaceGraphScope -Unit $unit
    $beforeStatus = [string]$unit.status
    $beforeCurrent = $state.current_unit
    $transition = "inspect-only"
    $event = $null
    $pushPlan = $null

    switch ($Action) {
        "Inspect" {
            $transition = "inspect-only"
        }
        "Claim" {
            if ($beforeStatus -eq "active" -and [string]$state.current_unit -eq $UnitId) {
                $transition = "idempotent"
            } else {
                if ($beforeStatus -ne "ready") { throw "Claim requires ready status; '$UnitId' is '$beforeStatus'." }
                if ($state.current_unit) { throw "Workspace already has current unit '$($state.current_unit)'." }
                Test-MorphospacePrerequisites -Unit $unit -UnitMap $unitMap
                $transition = "ready-to-active"
                if ($Execute) {
                    $unit.status = "active"; $state.current_unit = $UnitId
                    if ([string]$state.next_ready_unit -eq $UnitId) { $state.next_ready_unit = $null }
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "claimed" -Timestamp $Timestamp -EventType "state-transition" -Summary "Claimed one ready iteration unit without expanding repository or path scope."
                }
            }
        }
        "Resume" {
            if (($beforeStatus -eq "active" -or $beforeStatus -eq "validating") -and [string]$state.current_unit -eq $UnitId) {
                $transition = "idempotent"
            } elseif ($beforeStatus -eq "blocked" -and -not $state.current_unit) {
                $transition = "blocked-to-active"
                if ($Execute) {
                    $unit.status = "active"; $state.current_unit = $UnitId
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "resumed" -Timestamp $Timestamp -EventType "state-transition" -Summary "Resumed a blocked unit while preserving blocker and validation history."
                }
            } else { throw "Resume requires the matching in-flight unit or a blocked unit with no current owner." }
        }
        "BeginValidation" {
            if ($beforeStatus -eq "validating" -and [string]$state.current_unit -eq $UnitId) {
                $transition = "idempotent"
            } else {
                if ($beforeStatus -ne "active" -or [string]$state.current_unit -ne $UnitId) { throw "BeginValidation requires the matching active unit." }
                $requiredDeviceBlock = @($validationMatrix | Where-Object { $_.kind -eq "device" -and $_.disposition -eq "blocked-missing-serials" })
                if ($requiredDeviceBlock.Count -gt 0) { throw "Required device validation has no explicit serials." }
                $transition = "active-to-validating"
                if ($Execute) {
                    $unit.status = "validating"
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "validating" -Timestamp $Timestamp -EventType "state-transition" -Summary "Entered validation with a deterministic command, instruction, graph, and device-impact plan."
                }
            }
        }
        "RecordValidation" {
            if ($beforeStatus -ne "validating" -or [string]$state.current_unit -ne $UnitId) { throw "RecordValidation requires the matching validating unit." }
            if (-not $ValidationReceipt) { throw "ValidationReceipt is required." }
            $transition = "validation-$ValidationResult"
            if ($Execute) {
                $state.validation_checkpoint = [pscustomobject][ordered]@{ tier = $ValidationTier; receipt = $ValidationReceipt; result = $ValidationResult }
                if ($ValidationResult -ne "pass") {
                    $unit.status = "blocked"; $state.current_unit = $null
                    $blockerId = "$UnitId-validation-$ValidationResult"
                    if (@($state.blockers | Where-Object { [string]$_.blocker_id -eq $blockerId }).Count -eq 0) {
                        $state.blockers = @($state.blockers) + [pscustomobject][ordered]@{
                            blocker_id = $blockerId
                            condition = "Validation result is $ValidationResult in $ValidationReceipt."
                            resume_when = "Correct the failure and explicitly resume the unit."
                        }
                    }
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "validation-$ValidationResult" -Timestamp $Timestamp -EventType "blocker" -Summary "Recorded non-passing validation and blocked further acceptance." -Receipts @($ValidationReceipt)
                } else {
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "validation-pass" -Timestamp $Timestamp -EventType "validation" -Summary "Recorded passing validation; acceptance remains a separate explicit transition." -Receipts @($ValidationReceipt)
                }
            }
        }
        "Accept" {
            if ($beforeStatus -eq "accepted" -and -not $state.current_unit) {
                $transition = "idempotent"
            } else {
                if ($beforeStatus -ne "validating" -or [string]$state.current_unit -ne $UnitId) { throw "Accept requires the matching validating unit." }
                if ($null -eq $state.validation_checkpoint -or [string]$state.validation_checkpoint.result -ne "pass") { throw "Acceptance requires a passing validation checkpoint." }
                Test-MorphospaceInstructionCompletion -Unit $unit
                $transition = "validating-to-accepted"
                if ($Execute) {
                    $unit.status = "accepted"; $state.current_unit = $null
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "accepted" -Timestamp $Timestamp -EventType "state-transition" -Summary "Accepted the unit after passing validation and instruction synchronization." -Receipts @([string]$state.validation_checkpoint.receipt)
                }
            }
        }
        "Recover" {
            $inFlight = @($unitMap.Values | Where-Object { [string]$_.document.status -in @("active", "validating") })
            if (-not $state.current_unit -and $inFlight.Count -eq 1) {
                $recoveredId = [string]$inFlight[0].document.unit_id
                if ($recoveredId -ne $UnitId) { throw "Recover resolved '$recoveredId', not requested '$UnitId'." }
                $transition = "restore-current-unit"
                if ($Execute) {
                    $state.current_unit = $UnitId
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "recovered" -Timestamp $Timestamp -EventType "state-transition" -Summary "Recovered the sole interrupted in-flight unit without changing repository contents or prior evidence."
                }
            } elseif ($state.current_unit -and [string]$state.current_unit -eq $UnitId -and $beforeStatus -notin @("active", "validating")) {
                $transition = "clear-stale-current-unit"
                if ($Execute) {
                    $state.current_unit = $null
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "recovered" -Timestamp $Timestamp -EventType "state-transition" -Summary "Cleared a stale current-unit pointer while preserving unit status, blockers, and evidence."
                }
            } else { $transition = "idempotent" }
        }
        "PreparePush" {
            if ($beforeStatus -ne "accepted") { throw "PreparePush requires an accepted unit." }
            if (-not $RepoMapPath -or -not $RevisionsPath) { throw "PreparePush requires RepoMapPath and RevisionsPath." }
            $revisions = Read-MorphospaceJson -Path $RevisionsPath
            if ([string]$revisions.schema -ne "rusty.morphospace.workflow.revision_set.v1") { throw "Revision set has the wrong schema ID." }
            $revisionMap = @{}
            foreach ($revision in @($revisions.repositories)) {
                $revisionId = [string]$revision.repo_id
                if ($revisionMap.ContainsKey($revisionId)) { throw "Revision set repeats '$revisionId'." }
                $revisionMap[$revisionId] = $revision
            }
            foreach ($repo in @($unit.allowed_repositories)) {
                $repoId = [string]$repo.repo_id
                if (-not $repoMap.ContainsKey($repoId) -or -not $revisionMap.ContainsKey($repoId)) { throw "Push preparation needs mapping and revision for '$repoId'." }
            }
            foreach ($repoState in $repoStatesArray) {
                if (-not $repoState.is_git -or $repoState.dirty -or $null -eq $repoState.branch -or $repoState.behind -gt 0 -or $repoState.diverged) {
                    throw "Push preparation refused unsafe repo '$($repoState.repo_id)' ($($repoState.relation), dirty=$($repoState.dirty))."
                }
                if ([string]$revisionMap[[string]$repoState.repo_id].commit -ne [string]$repoState.head) {
                    throw "Recorded revision for '$($repoState.repo_id)' does not match HEAD."
                }
            }
            $sourceRepoIds = @($unit.allowed_repositories.repo_id | Where-Object { [string]$repoMap[[string]$_].role -ne "planning" } | Sort-Object)
            $planningRepoIds = @($unit.allowed_repositories.repo_id | Where-Object { [string]$repoMap[[string]$_].role -eq "planning" } | Sort-Object)
            $orderedRepoIds = @($sourceRepoIds) + @($planningRepoIds)
            $pushRepos = New-Object System.Collections.Generic.List[object]
            foreach ($repoIdValue in $orderedRepoIds) {
                $repoId = [string]$repoIdValue
                $repoState = @($repoStatesArray | Where-Object { [string]$_.repo_id -eq $repoId })[0]
                $pushRepos.Add([pscustomobject][ordered]@{
                    repo_id = $repoId; branch = $repoState.branch; commit = $repoState.head
                    upstream = $repoState.upstream; ahead = $repoState.ahead; behind = $repoState.behind
                }) | Out-Null
            }
            $bundleId = "$UnitId-push-bundle"
            $pushPlan = [pscustomobject][ordered]@{
                schema = "rusty.morphospace.workflow.push_bundle_plan.v1"
                bundle_id = $bundleId; project_id = [string]$state.project_id
                unit_ids = @($UnitId); prepared_at = $Timestamp
                dependency_order = $orderedRepoIds; repositories = @($pushRepos.ToArray())
                source_first = $true; planning_last = ($planningRepoIds.Count -eq 0 -or [string]$repoMap[[string]$orderedRepoIds[-1]].role -eq "planning")
                execution = "not-performed"; force_push_allowed = $false
            }
            $transition = "push-bundle-prepared"
            if ($Execute) {
                if (-not $OutPath) { throw "PreparePush with -Execute requires OutPath for the immutable plan." }
                $state.pending_push_bundle = [pscustomobject][ordered]@{
                    bundle_id = $bundleId; unit_ids = @($UnitId); repo_ids = $orderedRepoIds; ready = $true
                }
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "push-prepared" -Timestamp $Timestamp -EventType "commit" -Summary "Prepared a source-first, planning-last push bundle without executing Git push." -Receipts @($receiptReference)
            }
        }
    }

    if ($Execute -and $transition -ne "idempotent" -and $transition -ne "inspect-only") {
        Write-MorphospaceJson -Path $unitEntry.path -Value $unit
        if ($event) {
            $state.last_event_id = [string]$event.event_id
            Add-MorphospaceEvent -Path $eventsPath -Event $event
        }
        $state.dirty_repositories = @($repoStatesArray | Where-Object { $_.PSObject.Properties.Name -contains "dirty" -and $_.dirty -eq $true } | ForEach-Object { [string]$_.repo_id } | Sort-Object -Unique)
        Write-MorphospaceJson -Path $statePath -Value $state
    }

    $result = [pscustomobject][ordered]@{
        schema = "rusty.morphospace.workflow.work_unit_automation_receipt.v1"
        project_id = [string]$state.project_id; unit_id = $UnitId; action = $Action
        timestamp = $Timestamp; executed = $Execute.IsPresent; transition = $transition
        status_before = $beforeStatus; status_after = [string]$unit.status
        current_unit_before = $beforeCurrent; current_unit_after = $state.current_unit
        preservation = [pscustomobject][ordered]@{
            git_mutation_performed = $false; device_mutation_performed = $false
            force_push_allowed = $false; repository_states = @($repoStatesArray | ForEach-Object { New-MorphospaceRepositorySummary -State $_ })
        }
        validation_matrix = $validationMatrix; graph_scope = $graphScope
        push_plan = $pushPlan
        event_id = if ($event) { [string]$event.event_id } else { $null }
    }
    if ($Execute -and $OutPath) { Write-MorphospaceJson -Path $OutPath -Value $result }
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceWorkUnitAutomation, Get-MorphospaceRepositoryState
