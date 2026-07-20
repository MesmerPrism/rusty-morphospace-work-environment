Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePublicationRecovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlannedPublication.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlanningSuffixRewrite.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePublishedPrerequisiteSuffix.psm1') -Force

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

function Get-MorphospaceDirtyFingerprint {
    param([Parameter(Mandatory = $true)][object]$State)

    $lines = if ($State.PSObject.Properties.Name -contains "status_porcelain") {
        @($State.status_porcelain | ForEach-Object { [string]$_ } | Sort-Object)
    } else { @() }
    $text = ($lines -join "`n")
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $sha.Dispose() }
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
        read_only_dependencies = @($(if ($Unit.PSObject.Properties.Name -contains 'read_only_dependencies') { @($Unit.read_only_dependencies) } else { @() }) | ForEach-Object {
            [pscustomobject][ordered]@{
                repo_id = [string]$_.repo_id
                paths = @($_.paths | ForEach-Object { ([string]$_ -replace "\\", "/") } | Sort-Object -Unique)
                purpose = [string]$_.purpose
                verification = [string]$_.verification
            }
        } | Sort-Object repo_id)
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

function ConvertTo-MorphospaceRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace("\", "/").Trim()
    while ($normalized.StartsWith("./")) { $normalized = $normalized.Substring(2) }
    if (-not $normalized -or [System.IO.Path]::IsPathRooted($normalized)) {
        throw "Expected a non-rooted repository-relative path, received '$Path'."
    }
    if (@($normalized.Split("/") | Where-Object { $_ -eq ".." }).Count -gt 0) {
        throw "Repository-relative path may not contain '..': $Path"
    }
    return $normalized
}

function Test-MorphospacePathAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$AllowedPaths
    )

    $normalized = ConvertTo-MorphospaceRelativePath -Path $Path
    foreach ($candidate in @($AllowedPaths)) {
        $allowed = ([string]$candidate).Trim()
        if (-not $allowed) { continue }
        $allowed = (ConvertTo-MorphospaceRelativePath -Path $allowed).TrimEnd("/")
        if ($normalized.Equals($allowed, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($allowed + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-MorphospaceStatusPath {
    param([Parameter(Mandatory = $true)][string]$StatusLine)

    if ($StatusLine.Length -lt 4) { return $null }
    $value = $StatusLine.Substring(3).Trim()
    if ($value.Contains(" -> ")) { $value = @($value -split " -> ")[-1] }
    return (ConvertTo-MorphospaceRelativePath -Path $value.Trim('"'))
}

function Get-MorphospaceClaimDirtyOverlap {
    param(
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object[]]$RepositoryStates
    )

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($repo in @($Unit.allowed_repositories)) {
        $repoId = [string]$repo.repo_id
        $state = @($RepositoryStates | Where-Object { [string]$_.repo_id -eq $repoId } | Select-Object -First 1)
        if ($state.Count -eq 0 -or -not ($state[0].PSObject.Properties.Name -contains "status_porcelain")) { continue }
        $overlap = New-Object System.Collections.Generic.List[string]
        foreach ($line in @($state[0].status_porcelain)) {
            $path = Get-MorphospaceStatusPath -StatusLine ([string]$line)
            if ($path -and (Test-MorphospacePathAllowed -Path $path -AllowedPaths @($repo.allowed_paths))) {
                $overlap.Add($path) | Out-Null
            }
        }
        if ($overlap.Count -gt 0) {
            $result.Add([pscustomobject][ordered]@{
                repo_id = $repoId
                paths = @($overlap | Sort-Object -Unique)
            }) | Out-Null
        }
    }
    return @($result.ToArray())
}

function Test-MorphospaceClaimDirtyOverlap {
    param(
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object[]]$RepositoryStates
    )

    $overlaps = @(Get-MorphospaceClaimDirtyOverlap -Unit $Unit -RepositoryStates $RepositoryStates)
    if ($overlaps.Count -gt 0) {
        $detail = @($overlaps | ForEach-Object { "'$([string]$_.repo_id)': $(@($_.paths) -join ', ')" }) -join '; '
        throw "Claim refused pre-existing dirty-path overlap in $detail."
    }
}

function Get-MorphospaceAdoptionFileEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($pathValue in @($Paths | Sort-Object -Unique)) {
        $path = ConvertTo-MorphospaceRelativePath -Path ([string]$pathValue)
        $absolute = Join-Path $RepositoryPath ($path.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (Test-Path -LiteralPath $absolute -PathType Leaf) {
            $items.Add([pscustomobject][ordered]@{
                path = $path
                state = "present"
                sha256 = Get-MorphospaceFileSha256 -Path $absolute
            }) | Out-Null
        } elseif (-not (Test-Path -LiteralPath $absolute)) {
            $items.Add([pscustomobject][ordered]@{ path = $path; state = "deleted"; sha256 = $null }) | Out-Null
        } else {
            throw "In-flight adoption only supports file or deletion evidence, not directory '$path'."
        }
    }
    return @($items.ToArray())
}

function Test-MorphospaceInflightAdoptionReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptReference,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap,
        [Parameter(Mandatory = $true)][object[]]$RepositoryStates,
        [Parameter(Mandatory = $true)][object[]]$Overlaps
    )

    $receiptPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $WorkspaceRoot -ReceiptReference $ReceiptReference
    $receipt = Read-MorphospaceJson -Path $receiptPath
    if ([string]$receipt.schema -ne "rusty.morphospace.workflow.inflight_adoption_receipt.v1") { throw "In-flight adoption receipt has the wrong schema ID." }
    if ([string]$receipt.project_id -ne [string]$Spec.project_id -or [string]$receipt.unit_id -ne [string]$Unit.unit_id) { throw "In-flight adoption receipt identity does not match the requested unit." }
    if ([string]$receipt.reason -ne "work-started-before-protocol-v2" -or $receipt.safe_to_claim -ne $true -or $receipt.external_mutation_performed -ne $false) {
        throw "In-flight adoption receipt must explicitly prove bounded pre-protocol work, safe claim, and no external mutation."
    }

    $receiptRepos = @{}
    foreach ($entry in @($receipt.repositories)) {
        $repoId = [string]$entry.repo_id
        if (-not $repoId -or $receiptRepos.ContainsKey($repoId)) { throw "In-flight adoption receipt contains a missing or duplicate repository identity." }
        $receiptRepos[$repoId] = $entry
    }
    $expectedRepoIds = @($Overlaps | ForEach-Object { [string]$_.repo_id } | Sort-Object)
    $actualRepoIds = @($receiptRepos.Keys | Sort-Object)
    if (($expectedRepoIds -join "`n") -ne ($actualRepoIds -join "`n")) { throw "In-flight adoption receipt repository set does not match dirty in-scope repositories." }

    foreach ($overlap in @($Overlaps)) {
        $repoId = [string]$overlap.repo_id
        if (-not $RepositoryMap.ContainsKey($repoId)) { throw "In-flight adoption repository '$repoId' is not mapped." }
        $repositoryPath = [System.IO.Path]::GetFullPath([string]$RepositoryMap[$repoId].path)
        $repositoryPrefix = $repositoryPath.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
        $receiptRelativePath = $null
        if ($receiptPath.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $receiptRelativePath = ConvertTo-MorphospaceRelativePath -Path ($receiptPath.Substring($repositoryPrefix.Length))
        }
        $repoState = @($RepositoryStates | Where-Object { [string]$_.repo_id -eq $repoId } | Select-Object -First 1)[0]
        $entry = $receiptRepos[$repoId]
        if ([string]$entry.observed_revision -ne [string]$repoState.head) { throw "In-flight adoption receipt revision mismatch for '$repoId'." }
        $recordedFiles = @($entry.files)
        $recordedPaths = @($recordedFiles | ForEach-Object { ConvertTo-MorphospaceRelativePath -Path ([string]$_.path) } | Sort-Object)
        # The generated adoption receipt is itself a validated workflow-control
        # artifact. When the workspace lives inside a mapped planning repo it
        # appears only after capture, so exclude that one exact path from the
        # pre-existing source/WIP overlay instead of requiring a self-hash.
        $expectedPaths = @($overlap.paths | Where-Object {
            $null -eq $receiptRelativePath -or
            (ConvertTo-MorphospaceRelativePath -Path ([string]$_)) -ne $receiptRelativePath
        } | Sort-Object)
        if ($recordedPaths.Count -ne @($recordedPaths | Sort-Object -Unique).Count -or ($recordedPaths -join "`n") -ne ($expectedPaths -join "`n")) {
            throw "In-flight adoption receipt path set mismatch for '$repoId'."
        }
        $actualFiles = @(Get-MorphospaceAdoptionFileEvidence -RepositoryPath $repositoryPath -Paths $expectedPaths)
        $actualMap = @{}
        foreach ($file in $actualFiles) { $actualMap[[string]$file.path] = $file }
        foreach ($file in $recordedFiles) {
            $path = ConvertTo-MorphospaceRelativePath -Path ([string]$file.path)
            $actual = $actualMap[$path]
            if ([string]$file.state -ne [string]$actual.state) { throw "In-flight adoption receipt file-state mismatch for '$repoId/$path'." }
            if ([string]$file.sha256 -ne [string]$actual.sha256) { throw "In-flight adoption receipt hash mismatch for '$repoId/$path'." }
        }
    }
    return $receiptPath
}

function New-MorphospaceInflightAdoptionReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$RepoMapPath,
        [string]$Timestamp = "",
        [Parameter(Mandatory = $true)][string]$OutPath,
        [switch]$Execute
    )

    $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $resolvedOutPath = [System.IO.Path]::GetFullPath($OutPath)
    $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedOutPath.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "In-flight adoption receipt output must stay inside the project morphospace workspace."
    }
    $spec = Read-MorphospaceJson -Path (Join-Path $resolvedWorkspace "project.spec.json")
    $unitMap = Get-MorphospaceUnitMap -UnitRoot (Join-Path $resolvedWorkspace "iteration-units")
    if (-not $unitMap.ContainsKey($UnitId)) { throw "Iteration unit '$UnitId' does not exist." }
    $unit = $unitMap[$UnitId].document
    if ([string]$unit.status -ne "ready") { throw "In-flight adoption receipt requires a ready unit; '$UnitId' is '$([string]$unit.status)'." }
    $repoMap = Get-MorphospaceRepositoryMap -RepoMapPath $RepoMapPath
    $repositoryStates = New-Object System.Collections.Generic.List[object]
    foreach ($repo in @($unit.allowed_repositories | Sort-Object repo_id)) {
        $repoId = [string]$repo.repo_id
        if ($repoMap.ContainsKey($repoId)) {
            $repositoryStates.Add((Get-MorphospaceRepositoryState -RepoId $repoId -Path ([string]$repoMap[$repoId].path))) | Out-Null
        }
    }
    $repoStatesArray = @($repositoryStates.ToArray())
    $overlaps = @(Get-MorphospaceClaimDirtyOverlap -Unit $unit -RepositoryStates $repoStatesArray)
    if ($overlaps.Count -eq 0) { throw "In-flight adoption receipt is unnecessary because no dirty in-scope paths exist." }
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString("o") }

    $repositories = New-Object System.Collections.Generic.List[object]
    foreach ($overlap in @($overlaps | Sort-Object repo_id)) {
        $repoId = [string]$overlap.repo_id
        $state = @($repoStatesArray | Where-Object { [string]$_.repo_id -eq $repoId } | Select-Object -First 1)[0]
        $repositories.Add([pscustomobject][ordered]@{
            repo_id = $repoId
            observed_revision = [string]$state.head
            files = @(Get-MorphospaceAdoptionFileEvidence -RepositoryPath ([string]$repoMap[$repoId].path) -Paths @($overlap.paths))
        }) | Out-Null
    }
    $receipt = [pscustomobject][ordered]@{
        '$schema' = "https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/inflight-adoption-receipt.schema.json"
        schema = "rusty.morphospace.workflow.inflight_adoption_receipt.v1"
        receipt_id = "$UnitId-inflight-adoption"
        project_id = [string]$spec.project_id
        unit_id = $UnitId
        captured_at = $Timestamp
        reason = "work-started-before-protocol-v2"
        safe_to_claim = $true
        external_mutation_performed = $false
        repositories = @($repositories.ToArray())
    }
    if ($Execute) { Write-MorphospaceJson -Path $resolvedOutPath -Value $receipt }
    return $receipt
}

function Get-MorphospaceChangedPaths {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string]$BaseRevision
    )

    $changed = New-Object System.Collections.Generic.List[string]
    # Disable checkout line-ending projection for this path-only query. On
    # Windows, Git otherwise writes CRLF advisory messages to stderr; the
    # generic command wrapper intentionally captures stderr for diagnostics,
    # so those advisories could be mistaken for changed paths.
    $diff = Get-MorphospaceGitOutput -RepositoryPath $RepositoryPath -Arguments @("-c", "core.safecrlf=false", "-c", "core.autocrlf=false", "diff", "--name-only", $BaseRevision, "--")
    foreach ($line in @($diff.lines)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            $changed.Add((ConvertTo-MorphospaceRelativePath -Path ([string]$line))) | Out-Null
        }
    }
    $untracked = Get-MorphospaceGitOutput -RepositoryPath $RepositoryPath -Arguments @("ls-files", "--others", "--exclude-standard")
    foreach ($line in @($untracked.lines)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            $changed.Add((ConvertTo-MorphospaceRelativePath -Path ([string]$line))) | Out-Null
        }
    }
    return @($changed | Sort-Object -Unique)
}

function Resolve-MorphospaceReceiptPath {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptReference
    )

    $candidate = if ([System.IO.Path]::IsPathRooted($ReceiptReference)) {
        [System.IO.Path]::GetFullPath($ReceiptReference)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $ReceiptReference))
    }
    $workspacePrefix = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Validation receipt must stay inside the project workspace: $ReceiptReference"
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Validation receipt does not exist: $ReceiptReference"
    }
    return $candidate
}

function Test-MorphospaceValidationReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptReference,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap,
        [Parameter(Mandatory = $true)][object[]]$RepositoryStates,
        [Parameter(Mandatory = $true)][object[]]$ValidationMatrix,
        [Parameter(Mandatory = $true)][string]$ExpectedResult,
        [Parameter(Mandatory = $true)][string]$ExpectedTier,
        [string]$ExpectedExecutionNonce = ''
    )

    $receiptPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $WorkspaceRoot -ReceiptReference $ReceiptReference
    $receipt = Read-MorphospaceJson -Path $receiptPath
    $receiptSecurityUnit = (
        [string]$Unit.project_id -eq 'morphospace-platform-iteration' -and
        [string]$Unit.unit_id -eq 'wf-005'
    ) -or (
        ($Unit.PSObject.Properties.Name -contains 'tags') -and
        @($Unit.tags | Where-Object { [string]$_ -eq 'receipt-security' }).Count -ne 0
    )
    if ([string]$receipt.schema -eq "rusty.morphospace.workflow.validation_receipt.v2") {
        if (-not $receiptSecurityUnit) { throw 'Validation receipt v2 is reserved for a receipt-security corrective unit.' }
        return Test-MorphospaceValidationReceiptV2 -WorkspaceRoot $WorkspaceRoot -ReceiptReference $ReceiptReference -Unit $Unit -RepositoryMap $RepositoryMap -ExpectedResult $ExpectedResult -ExpectedExecutionNonce $ExpectedExecutionNonce
    }
    if ($receiptSecurityUnit) { throw 'Receipt-security corrective units require an authority-derived validation_receipt.v2; v1/manual receipts are rejected.' }
    if ([string]$receipt.schema -ne "rusty.morphospace.workflow.validation_receipt.v1") { throw "Validation receipt has the wrong schema ID." }
    if ([string]$receipt.project_id -ne [string]$Spec.project_id -or [string]$receipt.unit_id -ne [string]$Unit.unit_id) {
        throw "Validation receipt project/unit identity does not match the active unit."
    }
    if ([string]$receipt.result -ne $ExpectedResult -or [string]$receipt.tier -ne $ExpectedTier) {
        throw "Validation receipt result/tier does not match the requested checkpoint."
    }

    $artifactMap = @{}
    $receiptDirectory = Split-Path -Parent $receiptPath
    foreach ($artifact in @($receipt.artifacts)) {
        $artifactId = [string]$artifact.artifact_id
        if (-not $artifactId -or $artifactMap.ContainsKey($artifactId)) { throw "Validation receipt contains a missing or duplicate artifact ID '$artifactId'." }
        $artifactPath = if ([System.IO.Path]::IsPathRooted([string]$artifact.path)) {
            [System.IO.Path]::GetFullPath([string]$artifact.path)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $receiptDirectory ([string]$artifact.path)))
        }
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "Validation artifact does not exist: $($artifact.path)" }
        $actualHash = Get-MorphospaceAuthoritySha256 $artifactPath
        if ($actualHash -ne ([string]$artifact.sha256).ToLowerInvariant()) { throw "Validation artifact hash mismatch for '$artifactId'." }
        $artifactMap[$artifactId] = $artifact
    }
    if ($artifactMap.Count -eq 0) { throw "Validation receipt must contain at least one hashed artifact." }

    $expectedCriteria = @($Unit.acceptance | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
    $actualCriteria = @($receipt.criteria | ForEach-Object { [string]$_.acceptance_id } | Sort-Object)
    if (($expectedCriteria -join "|") -ne ($actualCriteria -join "|")) { throw "Validation receipt does not cover the exact acceptance-criterion set." }
    foreach ($criterion in @($receipt.criteria)) {
        $definition = @($Unit.acceptance | Where-Object { [string]$_.acceptance_id -eq [string]$criterion.acceptance_id } | Select-Object -First 1)[0]
        if ([string]$criterion.command -ne [string]$definition.command) { throw "Validation command drifted for criterion '$($criterion.acceptance_id)'." }
        if ($ExpectedResult -eq "pass" -and [string]$criterion.status -ne "pass") { throw "Passing validation has a non-passing criterion '$($criterion.acceptance_id)'." }
        foreach ($reference in @($criterion.evidence_refs)) {
            if (-not $artifactMap.ContainsKey([string]$reference)) { throw "Criterion '$($criterion.acceptance_id)' references unknown artifact '$reference'." }
        }
        if (@($criterion.evidence_refs).Count -eq 0) { throw "Criterion '$($criterion.acceptance_id)' has no evidence references." }
    }

    $expectedGates = @($ValidationMatrix | Where-Object { [string]$_.disposition -ne "forbidden" } | ForEach-Object { [string]$_.gate_id } | Sort-Object)
    $actualGates = @($receipt.gates | ForEach-Object { [string]$_.gate_id } | Sort-Object)
    if (($expectedGates -join "|") -ne ($actualGates -join "|")) { throw "Validation receipt does not cover the exact validation-gate set." }
    foreach ($gate in @($receipt.gates)) {
        $definition = @($ValidationMatrix | Where-Object { [string]$_.gate_id -eq [string]$gate.gate_id } | Select-Object -First 1)[0]
        if ([string]$gate.command -ne [string]$definition.command) { throw "Validation command drifted for gate '$($gate.gate_id)'." }
        if ($ExpectedResult -eq "pass" -and [string]$gate.status -ne "pass") { throw "Passing validation has a non-passing gate '$($gate.gate_id)'." }
        foreach ($reference in @($gate.evidence_refs)) {
            if (-not $artifactMap.ContainsKey([string]$reference)) { throw "Gate '$($gate.gate_id)' references unknown artifact '$reference'." }
        }
        if (@($gate.evidence_refs).Count -eq 0) { throw "Gate '$($gate.gate_id)' has no evidence references." }
    }

    $revisionMap = @{}
    foreach ($revision in @($receipt.repository_revisions)) {
        $repoId = [string]$revision.repo_id
        if (-not $repoId -or $revisionMap.ContainsKey($repoId)) { throw "Validation receipt repeats repository revision '$repoId'." }
        $revisionMap[$repoId] = $revision
    }
    $changedByRepo = @{}
    foreach ($change in @($receipt.changed_paths)) {
        $repoId = [string]$change.repo_id
        if (-not $changedByRepo.ContainsKey($repoId)) { $changedByRepo[$repoId] = New-Object System.Collections.Generic.List[string] }
        $changedByRepo[$repoId].Add((ConvertTo-MorphospaceRelativePath -Path ([string]$change.path))) | Out-Null
    }
    foreach ($repo in @($Unit.allowed_repositories)) {
        $repoId = [string]$repo.repo_id
        if (-not $RepositoryMap.ContainsKey($repoId)) {
            if ($ExpectedResult -eq "pass") { throw "Passing validation requires a repository mapping for '$repoId'." }
            continue
        }
        $repositoryPath = [string]$RepositoryMap[$repoId].path
        $state = @($RepositoryStates | Where-Object { [string]$_.repo_id -eq $repoId } | Select-Object -First 1)[0]
        if (-not $state.is_git) {
            if (-not $state.available) { throw "Validation repository/tool surface is unavailable for '$repoId'." }
            if ($revisionMap.ContainsKey($repoId)) { throw "Non-Git surface '$repoId' must be evidenced by artifact hashes, not a fabricated Git revision." }
            if ($changedByRepo.ContainsKey($repoId)) { throw "Non-Git surface '$repoId' cannot use Git changed_paths; hash its changed artifacts instead." }
            continue
        }
        if (-not $revisionMap.ContainsKey($repoId)) { throw "Validation receipt is missing repository revision '$repoId'." }
        $revision = $revisionMap[$repoId]
        if ([string]$revision.head_revision -ne [string]$state.head -or [string]$revision.branch -ne [string]$state.branch) {
            throw "Validation receipt does not match current HEAD/branch for '$repoId'."
        }
        $ancestor = Get-MorphospaceGitOutput -RepositoryPath $repositoryPath -Arguments @("merge-base", "--is-ancestor", [string]$revision.base_revision, [string]$revision.head_revision) -AllowFailure
        if ($ancestor.exit_code -ne 0) { throw "Validation base revision is not an ancestor of HEAD for '$repoId'." }
        $transactionPrefix = $null
        $repositoryFull = [System.IO.Path]::GetFullPath($repositoryPath).TrimEnd("\", "/")
        $workspaceFull = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd("\", "/")
        $repositoryPrefix = $repositoryFull + [System.IO.Path]::DirectorySeparatorChar
        if ($workspaceFull.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $workspaceRelative = $workspaceFull.Substring($repositoryPrefix.Length).Replace("\", "/").TrimEnd("/")
            $transactionPrefix = "$workspaceRelative/receipts/transactions/"
        }
        $actualChanged = @(Get-MorphospaceChangedPaths -RepositoryPath $repositoryPath -BaseRevision ([string]$revision.base_revision) | Where-Object {
            $candidatePath = ConvertTo-MorphospaceRelativePath -Path ([string]$_)
            (Test-MorphospacePathAllowed -Path $candidatePath -AllowedPaths @($repo.allowed_paths)) -and
            (-not $transactionPrefix -or -not $candidatePath.StartsWith($transactionPrefix, [System.StringComparison]::OrdinalIgnoreCase))
        })
        $recordedChanged = if ($changedByRepo.ContainsKey($repoId)) { @($changedByRepo[$repoId] | Sort-Object -Unique) } else { @() }
        foreach ($path in $recordedChanged) {
            if (-not (Test-MorphospacePathAllowed -Path $path -AllowedPaths @($repo.allowed_paths))) {
                throw "Validation changed path is outside unit scope for '$repoId': $path"
            }
        }
        if (($actualChanged -join "|") -ne ($recordedChanged -join "|")) { throw "Validation changed-path set does not match repository '$repoId'." }
    }
    foreach ($repoId in $changedByRepo.Keys) {
        if (@($Unit.allowed_repositories | Where-Object { [string]$_.repo_id -eq [string]$repoId }).Count -eq 0) {
            throw "Validation receipt contains a changed path for undeclared repository '$repoId'."
        }
    }

    $deviceRequirement = [string]$Unit.device_requirement
    if ($deviceRequirement -eq "required" -and $ExpectedResult -eq "pass" -and $null -eq $receipt.device_validation) {
        throw "Passing required-device validation needs explicit device evidence."
    }
    if ($null -ne $receipt.device_validation) {
        if (@($receipt.device_validation.serials).Count -eq 0) { throw "Device validation must name at least one serial." }
        if ($ExpectedResult -eq "pass" -and (-not [bool]$receipt.device_validation.cleanup_complete -or [int]$receipt.device_validation.package_fatal_count -ne 0 -or [int]$receipt.device_validation.system_fatal_count -ne 0)) {
            throw "Passing device validation requires complete cleanup and zero bounded package/system fatals."
        }
        foreach ($reference in @($receipt.device_validation.evidence_refs)) {
            if (-not $artifactMap.ContainsKey([string]$reference)) { throw "Device validation references unknown artifact '$reference'." }
        }
    }
    return $receipt
}

function Test-MorphospaceRecoveryReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ReceiptReference,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap,
        [Parameter(Mandatory = $true)][object[]]$RepositoryStates
    )

    $receiptPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $WorkspaceRoot -ReceiptReference $ReceiptReference
    $receipt = Read-MorphospaceJson -Path $receiptPath
    if ([string]$receipt.schema -ne "rusty.morphospace.workflow.interruption_receipt.v1") { throw "Recovery receipt has the wrong schema ID." }
    if ([string]$receipt.project_id -ne [string]$Spec.project_id -or [string]$receipt.unit_id -ne [string]$Unit.unit_id) { throw "Recovery receipt identity does not match the requested unit." }
    if ($receipt.safe_to_resume -ne $true -or $receipt.cleanup_complete -ne $true) { throw "Recovery receipt does not prove safe, complete cleanup." }

    $artifactIds = @{}
    $receiptDirectory = Split-Path -Parent $receiptPath
    foreach ($artifact in @($receipt.artifacts)) {
        $artifactId = [string]$artifact.artifact_id
        if (-not $artifactId -or $artifactIds.ContainsKey($artifactId)) { throw "Recovery receipt has a missing or duplicate artifact ID." }
        $artifactPath = if ([System.IO.Path]::IsPathRooted([string]$artifact.path)) { [System.IO.Path]::GetFullPath([string]$artifact.path) } else { [System.IO.Path]::GetFullPath((Join-Path $receiptDirectory ([string]$artifact.path))) }
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "Recovery artifact does not exist: $($artifact.path)" }
        $actualHash = Get-MorphospaceAuthoritySha256 $artifactPath
        if ($actualHash -ne ([string]$artifact.sha256).ToLowerInvariant()) { throw "Recovery artifact hash mismatch for '$artifactId'." }
        $artifactIds[$artifactId] = $true
    }
    if ($artifactIds.Count -eq 0) { throw "Recovery receipt requires hashed evidence." }

    $kind = [string]$receipt.interruption_kind
    if ($kind -eq "partial-cross-repo-commit") {
        $states = @($receipt.repositories | ForEach-Object { [string]$_.state })
        if ($states -notcontains "committed" -or $states -notcontains "pending") { throw "Partial-commit recovery must preserve both committed and pending repository checkpoints." }
    } elseif ($kind -eq "interrupted-build") {
        if ($null -eq $receipt.build_cleanup -or [int]$receipt.build_cleanup.active_process_count -ne 0 -or $receipt.build_cleanup.outputs_quarantined -ne $true) { throw "Interrupted-build recovery requires zero active processes and quarantined partial outputs." }
    } elseif ($kind -eq "interrupted-device") {
        if ($null -eq $receipt.device_cleanup -or @($receipt.device_cleanup.serials).Count -eq 0 -or @($receipt.device_cleanup.packages_remaining).Count -ne 0 -or $receipt.device_cleanup.routes_inactive -ne $true -or [int]$receipt.device_cleanup.package_fatal_count -ne 0 -or [int]$receipt.device_cleanup.system_fatal_count -ne 0) {
            throw "Interrupted-device recovery requires explicit serials, no remaining packages, inactive routes, and zero bounded fatals."
        }
    } else { throw "Unsupported interruption kind '$kind'." }

    $seenRepos = @{}
    foreach ($checkpoint in @($receipt.repositories)) {
        $repoId = [string]$checkpoint.repo_id
        if (-not $repoId -or $seenRepos.ContainsKey($repoId)) { throw "Recovery receipt repeats repository '$repoId'." }
        $seenRepos[$repoId] = $true
        if (@($Unit.allowed_repositories | Where-Object { [string]$_.repo_id -eq $repoId }).Count -ne 1) { throw "Recovery checkpoint references repository outside the unit: '$repoId'." }
        if ([string]$checkpoint.observed_revision -notmatch "^[0-9a-fA-F]{40}$") { throw "Recovery checkpoint '$repoId' has an invalid revision." }
        if ($RepositoryMap.ContainsKey($repoId)) {
            $state = @($RepositoryStates | Where-Object { [string]$_.repo_id -eq $repoId } | Select-Object -First 1)
            if ($state.Count -eq 1 -and $state[0].is_git -eq $true -and [string]$state[0].head -ne [string]$checkpoint.observed_revision) {
                throw "Recovery checkpoint '$repoId' no longer matches current HEAD."
            }
        }
    }
    return $receipt
}

function Get-MorphospaceNextReadyUnit {
    param([Parameter(Mandatory = $true)][hashtable]$UnitMap)

    $ready = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($UnitMap.Values)) {
        $candidate = $entry.document
        if ([string]$candidate.status -ne "ready") { continue }
        $prerequisitesAccepted = $true
        foreach ($prerequisite in @($candidate.prerequisites)) {
            $id = [string]$prerequisite
            if (-not $UnitMap.ContainsKey($id) -or [string]$UnitMap[$id].document.status -ne "accepted") {
                $prerequisitesAccepted = $false
                break
            }
        }
        if ($prerequisitesAccepted) { $ready.Add([string]$candidate.unit_id) | Out-Null }
    }
    return @($ready | Sort-Object | Select-Object -First 1)
}

function Invoke-MorphospaceAuthorityRunnerForRecord {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap,
        [Parameter(Mandatory = $true)][string]$AuthorityRunnerPath,
        [Parameter(Mandatory = $true)][string[]]$AuthorityRunnerArguments,
        [Parameter(Mandatory = $true)][ValidateSet('Preflight','Validate')][string]$RunnerAction,
        [string]$ValidationReceipt = ''
    )

    if (($AuthorityRunnerArguments.Count % 2) -ne 0) { throw 'Authority runner arguments must be explicit parameter/value pairs.' }
    $required = @('RegistryPath','RepositoryMapPath','CurrentProtocolPath','TrustMigrationPath','ClaimBaselinePath','OwnershipPath','ValidationActionPath','EvidencePath')
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $required) { [void]$allowed.Add($name) }
    $provided = @{}
    for ($index = 0; $index -lt $AuthorityRunnerArguments.Count; $index += 2) {
        $rawName = [string]$AuthorityRunnerArguments[$index]
        if (-not $rawName.StartsWith('-') -or $rawName.Length -lt 2) { throw 'Authority runner arguments must use named parameters only.' }
        $name = $rawName.Substring(1)
        if (-not $allowed.Contains($name) -or $provided.ContainsKey($name)) { throw "Authority runner argument is forbidden or duplicated: $rawName" }
        $provided[$name] = [string]$AuthorityRunnerArguments[$index + 1]
    }
    foreach ($name in $required) { if (-not $provided.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$provided[$name])) { throw "Authority runner argument is missing: -$name" } }
    $migrationPath = Resolve-MorphospaceAuthorityPath $WorkspaceRoot ([string]$provided['TrustMigrationPath'])
    $migration = Read-MorphospaceAuthorityJson $migrationPath
    $runnerArtifacts = @($migration.authority_artifacts | Where-Object { [string]$_.repo_id -ceq 'work-environment' -and [string]$_.path -ceq 'scripts/Invoke-MorphospaceValidationAuthority.ps1' })
    if ($runnerArtifacts.Count -ne 1 -or -not $RepositoryMap.ContainsKey('work-environment')) { throw 'Authority runner is absent from the migrated authority artifact set.' }
    $expectedRunner = [IO.Path]::GetFullPath((Join-Path ([string]$RepositoryMap['work-environment'].path) ([string]$runnerArtifacts[0].path)))
    $resolvedRunner = [IO.Path]::GetFullPath($AuthorityRunnerPath)
    if (-not $resolvedRunner.Equals($expectedRunner, [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($resolvedRunner) -or (Get-MorphospaceAuthoritySha256 $resolvedRunner) -cne [string]$runnerArtifacts[0].sha256) {
        throw 'Authority runner path or bytes do not match the migrated trust anchor.'
    }
    if($RunnerAction-eq'Validate'-and-not$ValidationReceipt){throw 'Validate authority handoff requires a validation receipt target.'}
    if($RunnerAction-eq'Preflight'-and$ValidationReceipt){throw 'Preflight authority handoff must not carry a validation receipt target.'}
    $nonceBytes = [byte[]]::new(32)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($nonceBytes) } finally { $rng.Dispose() }
    $nonce = ([BitConverter]::ToString($nonceBytes)).Replace('-', '').ToLowerInvariant()
    $hostCommand=Get-Command pwsh -CommandType Application -ErrorAction Stop|Where-Object{[IO.File]::Exists([string]$_.Source)}|Sort-Object -Property @{Expression={[version]$_.Version};Descending=$true},@{Expression={[string]$_.Source};Descending=$false}|Select-Object -First 1
    if($null-eq$hostCommand){throw'PowerShell 7 child host is unavailable.'}
    $host=[IO.Path]::GetFullPath([string]$hostCommand.Source)
    $nativeArguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$resolvedRunner,'-Action',$RunnerAction,'-WorkspaceRoot',$WorkspaceRoot,'-UnitId',$UnitId,'-ExecutionNonce',$nonce) + @($AuthorityRunnerArguments)
    if($RunnerAction-eq'Validate'){$nativeArguments+=@('-OutPath',$ValidationReceipt)}
    $captureRoot=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-authority-handoff-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($captureRoot)|Out-Null;$stdoutPath=Join-Path $captureRoot 'stdout.txt';$stderrPath=Join-Path $captureRoot 'stderr.txt'
    try{
        try{$process=Start-Process -FilePath $host -ArgumentList $nativeArguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath}catch{throw "Authority runner launch failed ($RunnerAction): $([string]$_.Exception.Message)"}
        try{$process.WaitForExit();$exitCode=[int]$process.ExitCode}finally{$process.Dispose()}
        $stdout=if([IO.File]::Exists($stdoutPath)){[IO.File]::ReadAllText($stdoutPath,[Text.UTF8Encoding]::new($false))}else{''};$stderr=if([IO.File]::Exists($stderrPath)){[IO.File]::ReadAllText($stderrPath,[Text.UTF8Encoding]::new($false))}else{''}
        if($exitCode-ne0){$failureLine=@(($stderr-split"`r?`n")|Where-Object{$_ -match'AUTHORITY_FAILURE'}|Select-Object -Last 1);$detail=if($failureLine){[string]$failureLine[0]}else{($stderr.Trim())};throw "Authority runner $RunnerAction failed with exit code $exitCode. $detail"}
    }finally{if([IO.Directory]::Exists($captureRoot)){[IO.Directory]::Delete($captureRoot,$true)}}
    return $nonce
}

function Invoke-MorphospaceWorkUnitAutomation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Inspect", "Ready", "Claim", "Resume", "BeginValidation", "PreflightValidation", "RecordValidation", "Accept", "PreparePush", "RecordPublication", "Recover", "ReconcilePublication", "ReconcilePlanningSuffixRewrite", "ReconcilePublishedPrerequisiteSuffix")][string]$Action,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [string]$UnitId = "",
        [string]$RepoMapPath = "",
        [string]$RevisionsPath = "",
        [ValidateSet("pass", "partial", "fail", "blocked")][string]$ValidationResult = "pass",
        [string]$ValidationReceipt = "",
        [string]$RecoveryReceipt = "",
        [string]$PublicationClosure = "",
        [string]$PublicationAccounting = "",
        [string]$PlanningSuffixRewriteRecovery = "",
        [string]$PublishedPrerequisiteSuffixReconciliation = "",
        [string]$PublicationOrderingInterruption = "",
        [string]$AdoptionReceipt = "",
        [ValidateSet("quick", "standard", "deep")][string]$ValidationTier = "standard",
        [string[]]$DeviceSerials = @(),
        [string]$AuthorityRunnerPath = "",
        [string[]]$AuthorityRunnerArguments = @(),
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
    $featureLock = Read-MorphospaceJson -Path (Join-Path $resolvedWorkspace "feature.lock.json")
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
    if ([string]$featureLock.project_id -ne [string]$spec.project_id) { throw "Feature lock project identifier does not agree." }

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
    if ($Action -in @("PreparePush", "RecordPublication", "ReconcilePlanningSuffixRewrite", "ReconcilePublishedPrerequisiteSuffix")) {
        $unitRepoIds = @{}
        foreach ($repo in @($unit.allowed_repositories)) { $unitRepoIds[[string]$repo.repo_id] = $true }
        $externalPlanningEntries = @($repoMap.Values | Where-Object {
            [string]$_.role -eq "planning" -and -not $unitRepoIds.ContainsKey([string]$_.repo_id)
        } | Sort-Object repo_id)
        if ($externalPlanningEntries.Count -ne 1) {
            throw "$Action requires exactly one distinct external planning repository in the local repository map."
        }
        $planningEntry = $externalPlanningEntries[0]
        $planningPath = [System.IO.Path]::GetFullPath([string]$planningEntry.path).TrimEnd("\", "/")
        $workspaceFull = [System.IO.Path]::GetFullPath($resolvedWorkspace).TrimEnd("\", "/")
        $planningPrefix = $planningPath + [System.IO.Path]::DirectorySeparatorChar
        if (-not $workspaceFull.StartsWith($planningPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "The external planning repository must contain the project workspace used for $Action."
        }
        $planningState = Get-MorphospaceRepositoryState -RepoId ([string]$planningEntry.repo_id) -Path ([string]$planningEntry.path)
        $planningState | Add-Member -NotePropertyName workflow_transport -NotePropertyValue $true
        $repositoryStates.Add($planningState) | Out-Null
    }
    $repoStatesArray = @($repositoryStates.ToArray())
    $validationMatrix = @(New-MorphospaceValidationMatrix -Unit $unit -DeviceSerials $DeviceSerials)
    $graphScope = New-MorphospaceGraphScope -Unit $unit
    $beforeStatus = [string]$unit.status
    $beforeCurrent = $state.current_unit
    $transition = "inspect-only"
    $event = $null
    $pushPlan = $null
    $adoptionReference = $null
    $publicationClosureReference = $null
    $publicationClosureBinding = $null
    $publicationAccountingBinding = $null
    $planningSuffixRewriteBinding = $null
    $publishedPrerequisiteSuffixBinding = $null
    $publicationOrderingInterruptionBinding = $null

    switch ($Action) {
        "Inspect" {
            $transition = "inspect-only"
        }
        "Ready" {
            if ($beforeStatus -eq "ready") {
                $transition = "idempotent"
            } else {
                if ($beforeStatus -ne "proposed") { throw "Ready requires proposed status; '$UnitId' is '$beforeStatus'." }
                Test-MorphospacePrerequisites -Unit $unit -UnitMap $unitMap
                $transition = "proposed-to-ready"
                if ($Execute) {
                    $unit.status = "ready"
                    $nextReady = @(Get-MorphospaceNextReadyUnit -UnitMap $unitMap)
                    $state.next_ready_unit = if ($nextReady.Count -gt 0) { [string]$nextReady[0] } else { $UnitId }
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "ready" -Timestamp $Timestamp -EventType "state-transition" -Summary "Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites."
                }
            }
        }
        "Claim" {
            if ($beforeStatus -eq "active" -and [string]$state.current_unit -eq $UnitId) {
                $transition = "idempotent"
            } else {
                if ($beforeStatus -ne "ready") { throw "Claim requires ready status; '$UnitId' is '$beforeStatus'." }
                if ($state.current_unit) { throw "Workspace already has current unit '$($state.current_unit)'." }
                Test-MorphospacePrerequisites -Unit $unit -UnitMap $unitMap
                $claimOverlaps = @(Get-MorphospaceClaimDirtyOverlap -Unit $unit -RepositoryStates $repoStatesArray)
                if ($claimOverlaps.Count -gt 0) {
                    if (-not $AdoptionReceipt) { Test-MorphospaceClaimDirtyOverlap -Unit $unit -RepositoryStates $repoStatesArray }
                    $adoptionPath = Test-MorphospaceInflightAdoptionReceipt -WorkspaceRoot $resolvedWorkspace -ReceiptReference $AdoptionReceipt -Spec $spec -Unit $unit -RepositoryMap $repoMap -RepositoryStates $repoStatesArray -Overlaps $claimOverlaps
                    $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
                    $adoptionReference = $adoptionPath.Substring($workspacePrefix.Length).Replace("\", "/")
                } elseif ($AdoptionReceipt) {
                    throw "In-flight adoption receipt is unnecessary because no dirty in-scope paths exist."
                }
                $transition = "ready-to-active"
                if ($Execute) {
                    $unit.status = "active"; $state.current_unit = $UnitId
                    if ([string]$state.next_ready_unit -eq $UnitId) { $state.next_ready_unit = $null }
                    $summary = if ($adoptionReference) { "Claimed one ready iteration unit with an exact hashed receipt for in-flight work that began before protocol v2." } else { "Claimed one ready iteration unit without expanding repository or path scope." }
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "claimed" -Timestamp $Timestamp -EventType "state-transition" -Summary $summary -Receipts @($adoptionReference | Where-Object { $_ })
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
        "PreflightValidation" {
            if ($beforeStatus -ne "validating" -or [string]$state.current_unit -ne $UnitId) { throw "PreflightValidation requires the matching validating unit." }
            $receiptSecurityUnit = (
                [string]$unit.project_id -eq 'morphospace-platform-iteration' -and
                [string]$unit.unit_id -eq 'wf-005'
            ) -or (
                ($unit.PSObject.Properties.Name -contains 'tags') -and
                @($unit.tags | Where-Object { [string]$_ -eq 'receipt-security' }).Count -ne 0
            )
            if (-not $receiptSecurityUnit) { throw 'PreflightValidation is reserved for receipt-security validation.' }
            if (-not $Execute) { throw 'PreflightValidation must execute the pinned authority runner.' }
            if (-not $AuthorityRunnerPath) { throw 'PreflightValidation requires AuthorityRunnerPath.' }
            [void](Invoke-MorphospaceAuthorityRunnerForRecord -WorkspaceRoot $resolvedWorkspace -UnitId $UnitId -RepositoryMap $repoMap -AuthorityRunnerPath $AuthorityRunnerPath -AuthorityRunnerArguments $AuthorityRunnerArguments -RunnerAction Preflight)
            $transition = 'authority-preflight-ready'
        }
        "RecordValidation" {
            if ($beforeStatus -ne "validating" -or [string]$state.current_unit -ne $UnitId) { throw "RecordValidation requires the matching validating unit." }
            if (-not $ValidationReceipt) { throw "ValidationReceipt is required." }
            $receiptSecurityUnit = (
                [string]$unit.project_id -eq 'morphospace-platform-iteration' -and
                [string]$unit.unit_id -eq 'wf-005'
            ) -or (
                ($unit.PSObject.Properties.Name -contains 'tags') -and
                @($unit.tags | Where-Object { [string]$_ -eq 'receipt-security' }).Count -ne 0
            )
            $authorityNonce = ''
            if ($receiptSecurityUnit) {
                if (-not $Execute) { throw 'Receipt-security validation must invoke the pinned authority runner in the same executed RecordValidation action.' }
                if (-not $AuthorityRunnerPath) { throw 'Receipt-security validation requires AuthorityRunnerPath; manual v2 receipt recording is rejected.' }
                $authorityNonce = Invoke-MorphospaceAuthorityRunnerForRecord -WorkspaceRoot $resolvedWorkspace -UnitId $UnitId -RepositoryMap $repoMap -AuthorityRunnerPath $AuthorityRunnerPath -AuthorityRunnerArguments $AuthorityRunnerArguments -RunnerAction Validate -ValidationReceipt $ValidationReceipt
            }
            $validatedReceipt = Test-MorphospaceValidationReceipt `
                -WorkspaceRoot $resolvedWorkspace `
                -ReceiptReference $ValidationReceipt `
                -Spec $spec `
                -Unit $unit `
                -RepositoryMap $repoMap `
                -RepositoryStates $repoStatesArray `
                -ValidationMatrix $validationMatrix `
                -ExpectedResult $ValidationResult `
                -ExpectedTier $ValidationTier `
                -ExpectedExecutionNonce $authorityNonce
            $validatedReceiptPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $ValidationReceipt
            $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
            $ValidationReceipt = $validatedReceiptPath.Substring($workspacePrefix.Length).Replace("\", "/")
            $transition = "validation-$ValidationResult"
            if ($Execute) {
                $state.validation_checkpoint = [pscustomobject][ordered]@{
                    tier = $ValidationTier
                    receipt = $ValidationReceipt
                    result = $ValidationResult
                }
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
                $validatedReceipt = Test-MorphospaceValidationReceipt `
                    -WorkspaceRoot $resolvedWorkspace `
                    -ReceiptReference ([string]$state.validation_checkpoint.receipt) `
                    -Spec $spec `
                    -Unit $unit `
                    -RepositoryMap $repoMap `
                    -RepositoryStates $repoStatesArray `
                    -ValidationMatrix $validationMatrix `
                    -ExpectedResult "pass" `
                    -ExpectedTier ([string]$state.validation_checkpoint.tier)
                Test-MorphospaceInstructionCompletion -Unit $unit
                $transition = "validating-to-accepted"
                if ($Execute) {
                    $unit.status = "accepted"; $state.current_unit = $null
                    if ([string]$state.schema -eq "rusty.morphospace.workflow.workspace_state.v2") {
                        $state.last_accepted_receipt = [string]$state.validation_checkpoint.receipt
                    }
                    $nextReady = @(Get-MorphospaceNextReadyUnit -UnitMap $unitMap)
                    $state.next_ready_unit = if ($nextReady.Count -gt 0) { [string]$nextReady[0] } else { $null }
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "accepted" -Timestamp $Timestamp -EventType "state-transition" -Summary "Accepted the unit after passing validation and instruction synchronization." -Receipts @([string]$state.validation_checkpoint.receipt)
                }
            }
        }
        "Recover" {
            $interruptionBlockers = @($state.blockers | Where-Object {
                ([string]$_.blocker_id -match "interrupt|partial-commit") -or ([string]$_.condition -match "(?i)interrupt|partial commit")
            })
            $recoveryReference = $null
            if ($interruptionBlockers.Count -gt 0 -and -not $RecoveryReceipt) {
                throw "Interrupted work requires a typed recovery receipt before state restoration."
            }
            if ($RecoveryReceipt) {
                $null = Test-MorphospaceRecoveryReceipt -WorkspaceRoot $resolvedWorkspace -ReceiptReference $RecoveryReceipt -Spec $spec -Unit $unit -RepositoryMap $repoMap -RepositoryStates $repoStatesArray
                $recoveryPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $RecoveryReceipt
                $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
                $recoveryReference = $recoveryPath.Substring($workspacePrefix.Length).Replace("\", "/")
            }
            $inFlight = @($unitMap.Values | Where-Object { [string]$_.document.status -in @("active", "validating") })
            if (-not $state.current_unit -and $inFlight.Count -eq 1) {
                $recoveredId = [string]$inFlight[0].document.unit_id
                if ($recoveredId -ne $UnitId) { throw "Recover resolved '$recoveredId', not requested '$UnitId'." }
                $transition = "restore-current-unit"
                if ($Execute) {
                    $state.current_unit = $UnitId
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "recovered" -Timestamp $Timestamp -EventType "state-transition" -Summary "Recovered the sole interrupted in-flight unit without changing repository contents or prior evidence." -Receipts @($recoveryReference | Where-Object { $_ })
                }
            } elseif ($state.current_unit -and [string]$state.current_unit -eq $UnitId -and $beforeStatus -notin @("active", "validating")) {
                $transition = "clear-stale-current-unit"
                if ($Execute) {
                    $state.current_unit = $null
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "recovered" -Timestamp $Timestamp -EventType "state-transition" -Summary "Cleared a stale current-unit pointer while preserving unit status, blockers, and evidence."
                }
            } else { $transition = "idempotent" }
        }
        "ReconcilePublication" {
            if (-not $PublicationClosure) { throw "ReconcilePublication requires PublicationClosure." }
            $closurePath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $PublicationClosure
            $validatedClosure = Test-MorphospaceUnplannedPublicationClosureLive `
                -Path $closurePath `
                -WorkspaceRoot $resolvedWorkspace `
                -Spec $spec `
                -Unit $unit `
                -State $state `
                -RepositoryMap $repoMap `
                -RepositoryStates $repoStatesArray
            $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
            $publicationClosureReference = $closurePath.Substring($workspacePrefix.Length).Replace("\", "/")
            $publicationClosureBinding = [pscustomobject][ordered]@{
                closure_id = [string]$validatedClosure.document.closure_id
                sha256 = [string]$validatedClosure.closure_sha256
            }
            $transition = "unplanned-publication-reconciled"
            if ($Execute) {
                $state.pending_push_bundle = $null
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "publication-reconciled" -Timestamp $Timestamp -EventType "push" -Summary "Reconciled an independently verified no-force publication that preceded push preparation without fabricating a pre-push plan or executed-push receipt." -Receipts @($publicationClosureReference)
            }
        }
        "RecordPublication" {
            if (-not $PublicationAccounting) { throw "RecordPublication requires PublicationAccounting." }
            if (-not $RepoMapPath) { throw "RecordPublication requires RepoMapPath." }
            if ($beforeStatus -ne "accepted") { throw "RecordPublication requires the triggering unit to remain accepted." }
            $accountingPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $PublicationAccounting
            $validatedAccounting = Test-MorphospacePlannedPublicationLive -Path $accountingPath -WorkspaceRoot $resolvedWorkspace -Spec $spec -State $state -RepositoryMap $repoMap -RepositoryStates $repoStatesArray
            if ([string]$validatedAccounting.document.trigger_unit_id -cne $UnitId) { throw "Publication accounting trigger unit does not match the requested unit." }
            $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
            $accountingReference = $accountingPath.Substring($workspacePrefix.Length).Replace("\", "/")
            $publicationAccountingBinding = [pscustomobject][ordered]@{
                accounting_id = [string]$validatedAccounting.document.accounting_id
                path = $accountingReference
                sha256 = [string]$validatedAccounting.accounting_sha256
                executed_push_receipt = [pscustomobject][ordered]@{
                    path = [string]$validatedAccounting.document.executed_push_receipt.path
                    sha256 = [string]$validatedAccounting.document.executed_push_receipt.sha256
                }
            }
            $transition = "planned-publication-recorded"
            if ($Execute) {
                $state.pending_push_bundle = $null
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "publication-recorded" -Timestamp $Timestamp -EventType "push" -Summary "Recorded complete planned-publication accounting after exact no-force remote readback; no Git, device, or acceptance mutation was performed." -Receipts @($accountingReference, [string]$validatedAccounting.document.executed_push_receipt.path)
            }
        }
        "ReconcilePlanningSuffixRewrite" {
            if (-not $PlanningSuffixRewriteRecovery) { throw "ReconcilePlanningSuffixRewrite requires PlanningSuffixRewriteRecovery." }
            if (-not $RepoMapPath) { throw "ReconcilePlanningSuffixRewrite requires RepoMapPath." }
            if ($beforeStatus -ne "accepted") { throw "ReconcilePlanningSuffixRewrite requires the triggering unit to remain accepted." }
            $recoveryPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $PlanningSuffixRewriteRecovery
            $validatedRecovery = Test-MorphospacePlanningSuffixRewriteLive -Path $recoveryPath -WorkspaceRoot $resolvedWorkspace -Spec $spec -State $state -RepositoryMap $repoMap -RepositoryStates $repoStatesArray
            if ([string]$validatedRecovery.document.trigger_unit_id -cne $UnitId) { throw "Planning-suffix rewrite recovery trigger unit does not match the requested unit." }
            $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
            $recoveryReference = $recoveryPath.Substring($workspacePrefix.Length).Replace("\", "/")
            $planningSuffixRewriteBinding = [pscustomobject][ordered]@{ recovery_id = [string]$validatedRecovery.document.recovery_id; path = $recoveryReference; sha256 = [string]$validatedRecovery.recovery_sha256 }
            $transition = "planning-suffix-rewrite-incident-reconciled"
            if ($Execute) {
                $state.pending_push_bundle = $null
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "planning-suffix-rewrite-reconciled" -Timestamp $Timestamp -EventType "push" -Summary "Reconciled a force-with-lease replacement of an already published planning-only finalization suffix while preserving the original no-force prepared execution and unchanged source history; no Git, validation, or acceptance mutation was performed." -Receipts @($recoveryReference, [string]$validatedRecovery.document.planned_publication_accounting.path)
            }
        }
        "ReconcilePublishedPrerequisiteSuffix" {
            if (-not $PublishedPrerequisiteSuffixReconciliation) { throw "ReconcilePublishedPrerequisiteSuffix requires PublishedPrerequisiteSuffixReconciliation." }
            if (-not $RepoMapPath) { throw "ReconcilePublishedPrerequisiteSuffix requires RepoMapPath." }
            if ($beforeStatus -ne "accepted") { throw "ReconcilePublishedPrerequisiteSuffix requires the triggering unit to remain accepted." }
            $reconciliationPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $PublishedPrerequisiteSuffixReconciliation
            $validatedReconciliation = Test-MorphospacePublishedPrerequisiteSuffixLive -Path $reconciliationPath -WorkspaceRoot $resolvedWorkspace -Spec $spec -State $state -RepositoryMap $repoMap -RepositoryStates $repoStatesArray
            if ([string]$validatedReconciliation.document.trigger_unit_id -cne $UnitId) { throw "Published-prerequisite reconciliation trigger unit does not match the requested unit." }
            $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
            $reconciliationReference = $reconciliationPath.Substring($workspacePrefix.Length).Replace("\", "/")
            $publishedPrerequisiteSuffixBinding = [pscustomobject][ordered]@{ reconciliation_id = [string]$validatedReconciliation.document.reconciliation_id; path = $reconciliationReference; sha256 = [string]$validatedReconciliation.reconciliation_sha256 }
            $transition = "published-prerequisite-suffix-reconciled"
            if ($Execute) {
                $state.pending_push_bundle = $null
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "published-prerequisite-suffix-reconciled" -Timestamp $Timestamp -EventType "push" -Summary "Reconciled one already-published no-force planning prerequisite commit containing exactly the bound executed-push and planned-publication-accounting receipts; no Git, validation, or acceptance mutation was performed." -Receipts @($reconciliationReference, [string]$validatedReconciliation.document.planned_publication_accounting.path, [string]$validatedReconciliation.document.planning_repository.executed_push_receipt.path)
            }
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
            $sourceRepoIds = @($unit.allowed_repositories.repo_id | Where-Object { [string]$repoMap[[string]$_].role -ne "planning" } | Sort-Object)
            $planningRepoIds = @($repoStatesArray | Where-Object {
                $repoMap.ContainsKey([string]$_.repo_id) -and [string]$repoMap[[string]$_.repo_id].role -eq "planning"
            } | ForEach-Object { [string]$_.repo_id } | Sort-Object)
            if ($planningRepoIds.Count -ne 1) { throw "PreparePush requires exactly one planning repository final suffix." }
            $orderedRepoIds = @($sourceRepoIds) + @($planningRepoIds)
            foreach ($repoIdValue in $orderedRepoIds) {
                $repoId = [string]$repoIdValue
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
            if ($PublicationOrderingInterruption) {
                $interruptionPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $PublicationOrderingInterruption
                $interruption = Read-MorphospaceJson -Path $interruptionPath
                if ([string]$interruption.schema -ne "rusty.morphospace.workflow.publication_ordering_interruption.v1") { throw "Publication-ordering interruption receipt has the wrong schema ID." }
                if ([string]$interruption.project_id -ne [string]$state.project_id -or [string]$interruption.unit_id -ne $UnitId) { throw "Publication-ordering interruption receipt identity does not match the prepared unit." }
                if ([string]$interruption.kind -ne "planning-published-before-source") { throw "Publication-ordering interruption kind is not supported." }
                $planningFault = $interruption.planning
                if ([string]$planningFault.repo_id -ne [string]$planningRepoIds[0]) { throw "Publication-ordering interruption planning repository does not match the external planning owner." }
                $planningLive = @($repoStatesArray | Where-Object { [string]$_.repo_id -eq [string]$planningFault.repo_id })[0]
                $planningRemote = (Get-MorphospaceGitOutput -RepositoryPath ([string]$repoMap[[string]$planningFault.repo_id].path) -Arguments @("rev-parse", "@{upstream}")).text
                if ($planningRemote -ne [string]$planningFault.early_remote_revision) { throw "Publication-ordering interruption planning remote does not match live readback." }
                if ((Get-MorphospaceGitOutput -RepositoryPath ([string]$repoMap[[string]$planningFault.repo_id].path) -Arguments @("merge-base", "--is-ancestor", [string]$planningFault.early_remote_revision, [string]$planningFault.local_prepared_revision) -AllowFailure).exit_code -ne 0) { throw "Preserved early planning checkpoint is not an ancestor of the local prepared checkpoint." }
                if ((Get-MorphospaceGitOutput -RepositoryPath ([string]$repoMap[[string]$planningFault.repo_id].path) -Arguments @("merge-base", "--is-ancestor", [string]$planningFault.local_prepared_revision, [string]$planningLive.head) -AllowFailure).exit_code -ne 0) { throw "Live planning head does not preserve the recorded local prepared checkpoint." }
                $sourceFaultMap = @{}
                foreach ($entry in @($interruption.sources)) { if ($sourceFaultMap.ContainsKey([string]$entry.repo_id)) { throw "Publication-ordering interruption repeats a source repository." }; $sourceFaultMap[[string]$entry.repo_id] = $entry }
                foreach ($sourceRepoId in $sourceRepoIds) {
                    if (-not $sourceFaultMap.ContainsKey([string]$sourceRepoId)) { throw "Publication-ordering interruption omits source repository '$sourceRepoId'." }
                    $entry = $sourceFaultMap[[string]$sourceRepoId]
                    $live = @($repoStatesArray | Where-Object { [string]$_.repo_id -eq [string]$sourceRepoId })[0]
                    $remote = (Get-MorphospaceGitOutput -RepositoryPath ([string]$repoMap[[string]$sourceRepoId].path) -Arguments @("rev-parse", "@{upstream}")).text
                    if ($remote -ne [string]$entry.unpublished_remote_revision -or [string]$live.head -ne [string]$entry.local_revision) { throw "Publication-ordering interruption source refs do not match live readback for '$sourceRepoId'." }
                    if ((Get-MorphospaceGitOutput -RepositoryPath ([string]$repoMap[[string]$sourceRepoId].path) -Arguments @("merge-base", "--is-ancestor", [string]$entry.unpublished_remote_revision, [string]$entry.local_revision) -AllowFailure).exit_code -ne 0) { throw "Unpublished source remote is not an ancestor of the local revision for '$sourceRepoId'." }
                }
                if (@($sourceFaultMap.Keys).Count -ne @($sourceRepoIds).Count) { throw "Publication-ordering interruption contains an undeclared source repository." }
                $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
                $publicationOrderingInterruptionBinding = [pscustomobject][ordered]@{ path = $interruptionPath.Substring($workspacePrefix.Length).Replace("\", "/"); sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $interruptionPath).Hash.ToLowerInvariant(); kind = [string]$interruption.kind; early_planning_checkpoint_preserved = $true; source_publication_claimed = $false }
            }
            $pushRepos = New-Object System.Collections.Generic.List[object]
            foreach ($repoIdValue in $orderedRepoIds) {
                $repoId = [string]$repoIdValue
                $repoState = @($repoStatesArray | Where-Object { [string]$_.repo_id -eq $repoId })[0]
                $pushRepos.Add([pscustomobject][ordered]@{
                    repo_id = $repoId; role = [string]$repoMap[$repoId].role; branch = $repoState.branch; commit = $repoState.head
                    upstream = $repoState.upstream; ahead = $repoState.ahead; behind = $repoState.behind
                }) | Out-Null
            }
            $bundleId = "$UnitId-push-bundle"
            $pushPlan = [pscustomobject][ordered]@{
                schema = "rusty.morphospace.workflow.push_bundle_plan.v1"
                bundle_id = $bundleId; project_id = [string]$state.project_id
                unit_ids = @($UnitId); prepared_at = $Timestamp
                dependency_order = $orderedRepoIds; repositories = @($pushRepos.ToArray())
                source_first = $true; planning_last = ([string]$repoMap[[string]$orderedRepoIds[-1]].role -eq "planning")
                execution = "not-performed"; force_push_allowed = $false
                publication_ordering_interruption = $publicationOrderingInterruptionBinding
            }
            $transition = "push-bundle-prepared"
            if ($Execute) {
                if (-not $OutPath) { throw "PreparePush with -Execute requires OutPath for the immutable plan." }
                $state.pending_push_bundle = [pscustomobject][ordered]@{
                    bundle_id = $bundleId; unit_ids = @($UnitId); repo_ids = $orderedRepoIds
                    planning_transport_repo_id = [string]$planningRepoIds[0]; ready = $true
                }
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "push-prepared" -Timestamp $Timestamp -EventType "commit" -Summary "Prepared a source-first, planning-last push bundle without executing Git push." -Receipts @($receiptReference)
            }
        }
    }

    if ($Execute -and $event) {
        $state.last_event_id = [string]$event.event_id
        if ($RepoMapPath) {
            $dirtySet = @{}
            foreach ($repoId in @($state.dirty_repositories)) { $dirtySet[[string]$repoId] = $true }
            foreach ($repoState in @($repoStatesArray | Where-Object { -not ($_.PSObject.Properties.Name -contains "workflow_transport") })) {
                $repoId = [string]$repoState.repo_id
                if (-not $repoMap.ContainsKey($repoId) -or -not ($repoState.PSObject.Properties.Name -contains "dirty")) { continue }
                if ($repoState.dirty -eq $true) { $dirtySet[$repoId] = $true } else { $dirtySet.Remove($repoId) }
            }
            $state.dirty_repositories = @($dirtySet.Keys | Sort-Object)
        }
        if ([string]$state.schema -eq "rusty.morphospace.workflow.workspace_state.v2") {
            if ($RepoMapPath) {
                $headMap = @{}
                foreach ($head in @($state.repository_heads)) { $headMap[[string]$head.repo_id] = $head }
                foreach ($repoState in @($repoStatesArray | Where-Object {
                    $_.PSObject.Properties.Name -contains "is_git" -and $_.is_git -eq $true -and -not ($_.PSObject.Properties.Name -contains "workflow_transport")
                })) {
                    $headMap[[string]$repoState.repo_id] = [pscustomobject][ordered]@{
                        repo_id = [string]$repoState.repo_id
                        head = [string]$repoState.head
                        branch = $repoState.branch
                        dirty_fingerprint = Get-MorphospaceDirtyFingerprint -State $repoState
                    }
                }
                $state.repository_heads = @($headMap.Values | Sort-Object repo_id)
            }
            if ([string]$featureLock.schema -eq "rusty.morphospace.workflow.feature_lock.v2") {
                $state.module_registry = [pscustomobject][ordered]@{
                    lock_revision = [int]$featureLock.revision
                    lock_fingerprint = [string]$featureLock.lock_fingerprint
                    modules = @($spec.modules | Where-Object { $_.selected -eq $true } | Sort-Object module_id | ForEach-Object {
                        [pscustomobject][ordered]@{
                            module_id = [string]$_.module_id
                            owner_repo = [string]$_.source_repo
                            maturity = [string]$_.maturity
                            contract = [string]$_.contract
                            contract_revision = [string]$_.contract_revision
                        }
                    })
                }
            }
        }
        $transactionId = "$([string]$event.event_id)-transition"
        $unitRelativePath = $unitEntry.path.Substring(($resolvedWorkspace.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar).Length).Replace('\', '/')
        Start-MorphospaceTransitionLedger `
            -WorkspaceRoot $resolvedWorkspace `
            -TransactionId $transactionId `
            -StatePath 'workspace.state.json' `
            -UnitPath $unitRelativePath `
            -EventsPath 'iteration-events.jsonl' `
            -TargetState $state `
            -TargetUnit $unit `
            -Event $event | Out-Null
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
        adoption_receipt = $adoptionReference
        publication_closure = $publicationClosureBinding
        planned_publication = $publicationAccountingBinding
        planning_suffix_rewrite_recovery = $planningSuffixRewriteBinding
        published_prerequisite_suffix_reconciliation = $publishedPrerequisiteSuffixBinding
        push_plan = $pushPlan
        event_id = if ($event) { [string]$event.event_id } else { $null }
    }
    if ($Execute -and $OutPath) { Write-MorphospaceJson -Path $OutPath -Value $result }
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceWorkUnitAutomation, Get-MorphospaceRepositoryState, New-MorphospaceInflightAdoptionReceipt
