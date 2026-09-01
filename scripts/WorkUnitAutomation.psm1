Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalValidationDebtBaseline.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceContentObservation.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'InheritedCandidateMaterialization.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePublicationRecovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePublishedPlanningAuthorityAdoption.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlannedPublication.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlanningSuffixRewrite.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePublishedPrerequisiteSuffix.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceExecutedPreparedPublication.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceNormalValidationSelector.psm1') -Force
# Retain the aggregate's public binding for this shared predicate. A private
# force reload unloads that binding even though this module can still call it.
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceActiveUnitContractReviewCompatibility.psm1')

function Read-MorphospaceJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file is missing: $Path"
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String
    } catch {
        throw "Invalid JSON in '$Path': $($_.Exception.Message)"
    }
}

function Get-MorphospaceGitCommonDirectory {
    param([Parameter(Mandatory = $true)][string]$RepositoryPath)
    $value = (& git -C $RepositoryPath rev-parse --path-format=absolute --git-common-dir).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $value) { throw "Repository is not an available Git repository: $RepositoryPath" }
    return [IO.Path]::GetFullPath($value).TrimEnd('\','/')
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
            $events.Add(($line | ConvertFrom-Json -DateKind String)) | Out-Null
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
            head = $null; tree = $null; branch = $null; upstream = $null; dirty = $null
            tracked_changes = $null; untracked_changes = $null; ahead = $null
            behind = $null; diverged = $null; relation = "missing"; status_porcelain = @()
        }
    }

    $inside = Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "--is-inside-work-tree") -AllowFailure
    if ($inside.exit_code -ne 0 -or $inside.text -ne "true") {
        return [pscustomobject][ordered]@{
            repo_id = $RepoId; path = $Path; available = $true; is_git = $false
            head = $null; tree = $null; branch = $null; upstream = $null; dirty = $null
            tracked_changes = $null; untracked_changes = $null; ahead = $null
            behind = $null; diverged = $null; relation = "not-git"; status_porcelain = @()
        }
    }

    $head = (Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "HEAD")).text
    $tree = (Get-MorphospaceGitOutput -RepositoryPath $Path -Arguments @("rev-parse", "HEAD^{tree}")).text
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
        tree = $tree
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
    foreach ($name in @("mapped", "available", "is_git", "head", "tree", "branch", "upstream", "dirty", "tracked_changes", "untracked_changes", "ahead", "behind", "diverged", "relation")) {
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

function New-MorphospaceClaimPreflight {
    param(
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap,
        [Parameter(Mandatory = $true)][object[]]$RepositoryStates,
        [Parameter(Mandatory = $true)][object[]]$ValidationMatrix,
        [Parameter(Mandatory = $true)][string]$ValidationTier,
        [Parameter(Mandatory = $true)][string]$Action
    )

    $issues = New-Object System.Collections.Generic.List[string]
    $stateMap = @{}
    foreach ($repositoryState in @($RepositoryStates)) { $stateMap[[string]$repositoryState.repo_id] = $repositoryState }

    $writable = New-Object System.Collections.Generic.List[object]
    foreach ($repo in @($Unit.allowed_repositories | Sort-Object repo_id)) {
        $repoId = [string]$repo.repo_id
        $mapped = $RepositoryMap.ContainsKey($repoId)
        $repositoryState = if ($stateMap.ContainsKey($repoId)) { $stateMap[$repoId] } else { $null }
        $available = $mapped -and $null -ne $repositoryState -and $repositoryState.available -eq $true
        if (-not $mapped) { $issues.Add("Writable repository '$repoId' is absent from the repository map.") | Out-Null }
        elseif (-not $available) { $issues.Add("Writable repository '$repoId' is not available at its mapped path.") | Out-Null }
        $writable.Add([pscustomobject][ordered]@{
            repo_id = $repoId; mapped = $mapped; available = $available
            is_git = if ($null -ne $repositoryState -and $repositoryState.PSObject.Properties.Name -contains 'is_git') { $repositoryState.is_git } else { $null }
            head = if ($null -ne $repositoryState -and $repositoryState.PSObject.Properties.Name -contains 'head') { $repositoryState.head } else { $null }
            tree = if ($null -ne $repositoryState -and $repositoryState.PSObject.Properties.Name -contains 'tree') { $repositoryState.tree } else { $null }
            allowed_paths = @($repo.allowed_paths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
        }) | Out-Null
    }

    $dependencies = New-Object System.Collections.Generic.List[object]
    foreach ($dependency in @($(if ($Unit.PSObject.Properties.Name -contains 'read_only_dependencies') { @($Unit.read_only_dependencies) } else { @() }) | Sort-Object repo_id)) {
        $repoId = [string]$dependency.repo_id
        $mapped = $RepositoryMap.ContainsKey($repoId)
        $repositoryState = if ($stateMap.ContainsKey($repoId)) { $stateMap[$repoId] } else { $null }
        if (-not $mapped) {
            $issues.Add("Read-only dependency repository '$repoId' is absent from the repository map.") | Out-Null
        }
        foreach ($declaredPath in @($dependency.paths | Sort-Object -Unique)) {
            $relative = $null; $exists = $false; $kind = $null
            try {
                $relative = ConvertTo-MorphospaceRelativePath -Path ([string]$declaredPath)
                if (-not $mapped) { throw "repository is not mapped" }
                $root = [IO.Path]::GetFullPath([string]$RepositoryMap[$repoId].path).TrimEnd('\', '/')
                $absolute = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $relative))
                if (-not $absolute.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "path escapes its mapped repository"
                }
                $exists = Test-Path -LiteralPath $absolute
                if (-not $exists) { throw "path is missing" }
                $kind = if (Test-Path -LiteralPath $absolute -PathType Leaf) { 'file' } else { 'directory' }
            } catch {
                $issues.Add("Read-only dependency '$repoId/$([string]$declaredPath)' failed preflight: $($_.Exception.Message)") | Out-Null
            }
            $dependencies.Add([pscustomobject][ordered]@{
                repo_id = $repoId; path = ([string]$declaredPath).Replace('\', '/'); mapped = $mapped
                exists = $exists; kind = $kind
                head = if ($null -ne $repositoryState -and $repositoryState.PSObject.Properties.Name -contains 'head') { $repositoryState.head } else { $null }
                tree = if ($null -ne $repositoryState -and $repositoryState.PSObject.Properties.Name -contains 'tree') { $repositoryState.tree } else { $null }
            }) | Out-Null
        }
    }

    $instructionObservations = @()
    $instructionObservationFailed = $false
    if ([string]$Unit.instruction_impact -ne 'none') {
        try {
            $instructionRepositoryMap = @{}
            foreach ($repoId in @($RepositoryMap.Keys)) {
                $entry = ($RepositoryMap[$repoId] | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
                if ($entry.PSObject.Properties.Name -notcontains 'aliases') { $entry | Add-Member -NotePropertyName aliases -NotePropertyValue @() }
                $instructionRepositoryMap[[string]$repoId] = $entry
            }
            $instructionUnit = ($Unit | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
            foreach ($surface in @($instructionUnit.instruction_surfaces)) { $surface.status = 'complete' }
            $instructionObservations = @(Get-MorphospaceInstructionObservation -Unit $instructionUnit -RepositoryMap $instructionRepositoryMap)
        } catch {
            $instructionObservationFailed = $true
            $issues.Add("Instruction surface preflight failed: $($_.Exception.Message)") | Out-Null
        }
    }

    $resources = @($(if ($Unit.PSObject.Properties.Name -contains 'resource_requirements') { @($Unit.resource_requirements) } else { @() }))
    foreach ($group in @($resources | Group-Object resource_id | Where-Object { $_.Count -gt 1 })) {
        $issues.Add("Resource requirement '$($group.Name)' is declared more than once.") | Out-Null
    }
    foreach ($deviceGate in @($ValidationMatrix | Where-Object { [string]$_.kind -eq 'device' -and [string]$_.disposition -eq 'blocked-missing-serials' })) {
        $issues.Add("Required device validation has no explicitly supplied serial.") | Out-Null
    }

    $requirementsDeclared = $Unit.PSObject.Properties.Name -contains 'claim_requirements'
    if (($Unit.PSObject.Properties.Name -contains 'work_mode') -and -not $requirementsDeclared) {
        $issues.Add("Explicit work_mode requires complete claim_requirements.") | Out-Null
    }
    $diskRows = New-Object System.Collections.Generic.List[object]
    $toolRows = New-Object System.Collections.Generic.List[object]
    $inputRows = New-Object System.Collections.Generic.List[object]
    $executionPreflightDeclared = $false
    $executionPreflightStatus = 'not-declared'
    $executionPreflightObservation = $null
    $executionPreflightRows = New-Object System.Collections.Generic.List[object]
    $executionPreflightIssues = New-Object System.Collections.Generic.List[string]
    if ($requirementsDeclared) {
        $requirements = $Unit.claim_requirements
        $minimumBytes = [long]$requirements.minimum_free_disk_mib * 1MB
        $roots = @($Unit.allowed_repositories | ForEach-Object {
            $repoId = [string]$_.repo_id
            if ($RepositoryMap.ContainsKey($repoId)) { [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$RepositoryMap[$repoId].path)) }
        } | Where-Object { $_ } | Sort-Object -Unique)
        $volumeIndex = 0
        foreach ($root in $roots) {
            $volumeIndex++
            $availableBytes = $null; $passed = $false
            try {
                $drive = [IO.DriveInfo]::new([string]$root)
                $availableBytes = [long]$drive.AvailableFreeSpace
                $passed = $availableBytes -ge $minimumBytes
                if (-not $passed) { $issues.Add("Writable volume $volumeIndex lacks the declared minimum free disk space.") | Out-Null }
            } catch { $issues.Add("Writable volume $volumeIndex disk capacity could not be observed: $($_.Exception.Message)") | Out-Null }
            $diskRows.Add([pscustomobject][ordered]@{ volume_index = $volumeIndex; minimum_free_mib = [long]$requirements.minimum_free_disk_mib; available_free_mib = if ($null -ne $availableBytes) { [long][Math]::Floor($availableBytes / 1MB) } else { $null }; passed = $passed }) | Out-Null
        }
        foreach ($tool in @($requirements.required_tools | Sort-Object tool_id)) {
            $matches = @(Get-Command -Name ([string]$tool.executable) -CommandType Application -ErrorAction SilentlyContinue)
            $available = $matches.Count -gt 0
            if (-not $available) { $issues.Add("Required tool '$([string]$tool.tool_id)' is unavailable as executable '$([string]$tool.executable)'.") | Out-Null }
            $toolRows.Add([pscustomobject][ordered]@{ tool_id = [string]$tool.tool_id; executable = [string]$tool.executable; available = $available }) | Out-Null
        }
        foreach ($input in @($requirements.product_inputs | Sort-Object input_id)) {
            $repoId = [string]$input.repo_id; $declaredPath = [string]$input.path
            $exists = $false; $kindMatches = $false; $sha256 = $null; $hashMatches = $null
            try {
                if (-not $RepositoryMap.ContainsKey($repoId)) { throw "repository is not mapped" }
                $relative = ConvertTo-MorphospaceRelativePath -Path $declaredPath
                $root = [IO.Path]::GetFullPath([string]$RepositoryMap[$repoId].path).TrimEnd('\', '/')
                $absolute = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $relative))
                if (-not $absolute.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "path escapes its mapped repository" }
                $exists = Test-Path -LiteralPath $absolute
                if (-not $exists) { throw "path is missing" }
                $kindMatches = if ([string]$input.kind -eq 'file') { Test-Path -LiteralPath $absolute -PathType Leaf } else { Test-Path -LiteralPath $absolute -PathType Container }
                if (-not $kindMatches) { throw "path kind does not match '$([string]$input.kind)'" }
                if ([string]$input.kind -eq 'file') {
                    $sha256 = Get-MorphospaceFileSha256 -Path $absolute
                    if ($null -ne $input.expected_sha256) {
                        $hashMatches = $sha256 -ceq [string]$input.expected_sha256
                        if (-not $hashMatches) { throw "file SHA-256 differs from expected_sha256" }
                    }
                }
            } catch { $issues.Add("Product input '$([string]$input.input_id)' failed preflight: $($_.Exception.Message)") | Out-Null }
            $inputRows.Add([pscustomobject][ordered]@{ input_id = [string]$input.input_id; repo_id = $repoId; path = $declaredPath.Replace('\', '/'); kind = [string]$input.kind; exists = $exists; kind_matches = $kindMatches; sha256 = $sha256; hash_matches = $hashMatches }) | Out-Null
        }
        if ($requirements.PSObject.Properties.Name -contains 'execution_preflight') {
            $executionPreflightDeclared = $true
            $executionPreflightStatus = 'incomplete'
            $preflightContract = $requirements.execution_preflight
            $observationContract = $preflightContract.observation
            $observationRepoId = [string]$observationContract.repo_id
            $observationDeclaredPath = [string]$observationContract.path
            $expectedObservationSha256 = [string]$observationContract.expected_sha256
            $observedSha256 = $null
            $observationHashMatches = $null
            $observationSchema = $null
            $observationId = $null
            try {
                if (-not $RepositoryMap.ContainsKey($observationRepoId)) { throw "repository is not mapped" }
                $observationRelative = ConvertTo-MorphospaceRelativePath -Path $observationDeclaredPath
                $observationRoot = [IO.Path]::GetFullPath([string]$RepositoryMap[$observationRepoId].path).TrimEnd('\', '/')
                $observationAbsolute = [IO.Path]::GetFullPath([IO.Path]::Combine($observationRoot, $observationRelative))
                if (-not $observationAbsolute.StartsWith($observationRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "path escapes its mapped repository" }
                if (-not (Test-Path -LiteralPath $observationAbsolute -PathType Leaf)) { throw "observation file is missing" }
                $observedSha256 = Get-MorphospaceFileSha256 -Path $observationAbsolute
                $observationHashMatches = $observedSha256 -ceq $expectedObservationSha256
                if (-not $observationHashMatches) {
                    $executionPreflightStatus = 'fail'
                    throw "observation SHA-256 differs from expected_sha256"
                }
                $executionPreflightStatus = 'fail'
                $executionObservationSchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\execution-preflight-observation.schema.json'
                $observationJson = Get-Content -LiteralPath $observationAbsolute -Raw
                if (-not (Test-Json -Json $observationJson -SchemaFile $executionObservationSchemaPath -ErrorAction SilentlyContinue)) {
                    throw "observation does not conform to execution-preflight-observation.schema.json"
                }
                $observationDocument = $observationJson | ConvertFrom-Json
                $observationSchema = [string]$observationDocument.schema
                $observationId = [string]$observationDocument.observation_id
                if ($observationSchema -cne 'rusty.morphospace.workflow.execution_preflight_observation.v1') {
                    $executionPreflightStatus = 'fail'
                    throw "observation has the wrong schema ID"
                }
                if ($observationId -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') {
                    $executionPreflightStatus = 'fail'
                    throw "observation_id is invalid"
                }
                $valueMap = @{}
                foreach ($entry in @($observationDocument.values)) {
                    $key = [string]$entry.key
                    if ($valueMap.ContainsKey($key)) { $executionPreflightStatus = 'fail'; throw "observation repeats value key '$key'" }
                    $valueMap[$key] = [string]$entry.value
                }
                $capabilityMap = @{}
                foreach ($entry in @($observationDocument.capabilities)) {
                    $key = [string]$entry.capability_id
                    if ($capabilityMap.ContainsKey($key)) { $executionPreflightStatus = 'fail'; throw "observation repeats capability '$key'" }
                    $capabilityMap[$key] = [bool]$entry.available
                }
                foreach ($assertion in @($preflightContract.assertions | Sort-Object assertion_id)) {
                    $assertionId = [string]$assertion.assertion_id
                    $kind = [string]$assertion.kind
                    $key = [string]$assertion.key
                    $expected = if ($null -ne $assertion.expected) { [string]$assertion.expected } else { $null }
                    $observed = $null
                    $passed = $false
                    if ($kind -eq 'value-equals') {
                        if ($valueMap.ContainsKey($key)) { $observed = [string]$valueMap[$key] }
                        $passed = $null -ne $observed -and $observed -ceq $expected
                    } elseif ($kind -eq 'capability-present') {
                        if ($capabilityMap.ContainsKey($key)) { $observed = [bool]$capabilityMap[$key] }
                        $passed = $null -ne $observed -and $observed -eq $true
                    } else {
                        $executionPreflightStatus = 'fail'
                        throw "assertion '$assertionId' has unsupported kind '$kind'"
                    }
                    $executionPreflightRows.Add([pscustomobject][ordered]@{
                        assertion_id = $assertionId; kind = $kind; key = $key
                        expected = $expected; observed = $observed; passed = $passed
                    }) | Out-Null
                    if (-not $passed) {
                        $executionPreflightStatus = 'fail'
                        $executionPreflightIssues.Add("Execution preflight assertion '$assertionId' did not pass.") | Out-Null
                    }
                }
                $executionPreflightStatus = if ($executionPreflightIssues.Count -eq 0) { 'pass' } else { 'fail' }
            } catch {
                $executionPreflightIssues.Add("Execution preflight observation failed: $($_.Exception.Message)") | Out-Null
            }
            $executionPreflightObservation = [pscustomobject][ordered]@{
                repo_id = $observationRepoId
                path = $observationDeclaredPath.Replace('\', '/')
                expected_sha256 = $expectedObservationSha256
                sha256 = $observedSha256
                hash_matches = $observationHashMatches
                schema = $observationSchema
                observation_id = if ($observationId) { $observationId } else { $null }
            }
            foreach ($preflightIssue in @($executionPreflightIssues.ToArray())) { $issues.Add($preflightIssue) | Out-Null }
        }
    }

    $lifecyclePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'manifests\workflow-lifecycle.portable.json'
    $unitSchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\iteration-unit.schema.json'
    $automationSchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\work-unit-automation-receipt.schema.json'
    $executionObservationSchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\execution-preflight-observation.schema.json'
    $validatorRegistryPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'manifests\owner-validator-registry.json'
    $instructionRouterPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\rusty-morphospace\references\project-workflow.md'
    $lifecycle = Get-Content -LiteralPath $lifecyclePath -Raw | ConvertFrom-Json
    $guardProfileExplicit = $Unit.PSObject.Properties.Name -contains 'guard_profile'
    $guardProfileId = if ($guardProfileExplicit) {
        [string]$Unit.guard_profile
    } else {
        switch ([string]$Unit.risk_tier) {
            'quick' { 'fast' }
            'deep' { 'locked' }
            default { 'labs' }
        }
    }
    $guardReasonCodes = New-Object System.Collections.Generic.List[string]
    $knownGuardProfiles = @($lifecycle.guard_profiles | ForEach-Object { [string]$_.id })
    $guardRanks = @{ fast = 0; labs = 1; locked = 2 }
    $guardCategoryAliases = @{}
    foreach ($alias in @($lifecycle.change_category_aliases)) { $guardCategoryAliases[[string]$alias.alias] = [string]$alias.canonical }
    $guardEffectiveCategories = @($Unit.change_categories | ForEach-Object {
        $category = [string]$_
        if ($guardCategoryAliases.ContainsKey($category)) { $guardCategoryAliases[$category] } else { $category }
    })
    $lockedCategories = @('public-private-boundary', 'workflow-automation', 'state-machine', 'validation-routing', 'recovery')
    $labsCategories = @('authority', 'module-layout', 'feature-activation', 'device-policy', 'repo-routing')
    $requiredGuardRank = 0
    if (@($guardEffectiveCategories | Where-Object { $lockedCategories -contains $_ }).Count -gt 0 -or [string]$Unit.push_checkpoint -eq 'release') {
        $requiredGuardRank = 2
    } elseif (@($guardEffectiveCategories | Where-Object { $labsCategories -contains $_ }).Count -gt 0) {
        $requiredGuardRank = 1
    }
    if ($guardProfileExplicit) {
        if ($knownGuardProfiles -notcontains $guardProfileId) {
            $guardReasonCodes.Add('guard-profile-unknown') | Out-Null
            $issues.Add("Explicit guard profile '$guardProfileId' is not declared by the lifecycle contract.") | Out-Null
        } elseif ([int]$guardRanks[$guardProfileId] -lt $requiredGuardRank) {
            $requiredGuardProfile = @('fast', 'labs', 'locked')[$requiredGuardRank]
            $guardReasonCodes.Add('guard-profile-insufficient') | Out-Null
            $issues.Add("Guard profile '$guardProfileId' is insufficient; this unit requires '$requiredGuardProfile' or stricter authority.") | Out-Null
        }
    } else {
        $guardReasonCodes.Add('legacy-risk-inference') | Out-Null
    }
    $guardProfile = [pscustomobject][ordered]@{
        id = $guardProfileId
        explicit = $guardProfileExplicit
        source = if ($guardProfileExplicit) { 'unit' } else { 'legacy-risk-inference' }
        status = if (-not $guardProfileExplicit) { 'legacy-compatible' } elseif ($guardReasonCodes.Count -eq 0) { 'pass' } else { 'fail' }
        reason_codes = @($guardReasonCodes.ToArray())
    }
    $contractBindings = [pscustomobject][ordered]@{
        project_revision = [int]$Spec.revision
        workflow_lifecycle_sha256 = Get-MorphospaceFileSha256 -Path $lifecyclePath
        iteration_unit_schema_sha256 = Get-MorphospaceFileSha256 -Path $unitSchemaPath
        automation_receipt_schema_sha256 = Get-MorphospaceFileSha256 -Path $automationSchemaPath
        execution_preflight_observation_schema_sha256 = Get-MorphospaceFileSha256 -Path $executionObservationSchemaPath
        owner_validator_registry_sha256 = Get-MorphospaceFileSha256 -Path $validatorRegistryPath
        instruction_router_sha256 = Get-MorphospaceFileSha256 -Path $instructionRouterPath
    }
    $candidateFingerprint = Get-MorphospaceCanonicalJsonSha256 ([pscustomobject][ordered]@{
        unit_sha256 = Get-MorphospaceCanonicalJsonSha256 $Unit
        validation_tier = $ValidationTier
        contract_bindings = $contractBindings
    })

    $checks = New-Object System.Collections.Generic.List[object]
    $addCheck = {
        param([string]$CheckId, [string]$Outcome, [string]$CoverageState, [string[]]$ReasonCodes)
        $checks.Add([pscustomobject][ordered]@{
            check_id = $CheckId
            outcome = $Outcome
            coverage_state = $CoverageState
            reason_codes = @($ReasonCodes | Sort-Object -Unique)
        }) | Out-Null
    }
    & $addCheck 'contract-bindings' 'pass' 'completed' @()
    if (-not $guardProfileExplicit) {
        & $addCheck 'guard-profile' 'pass' 'skipped' @('legacy-risk-inference')
    } elseif ($guardReasonCodes.Count -gt 0) {
        & $addCheck 'guard-profile' 'fail' 'completed' @($guardReasonCodes.ToArray())
    } else {
        & $addCheck 'guard-profile' 'pass' 'completed' @()
    }

    $knownProfileIds = @($Spec.validation_profiles | ForEach-Object { [string]$_.profile_id })
    $unknownProfileIds = @($Unit.validation | ForEach-Object { [string]$_.profile_id } | Where-Object { $knownProfileIds -notcontains $_ } | Sort-Object -Unique)
    if ($unknownProfileIds.Count -gt 0) {
        & $addCheck 'validation-profile-closure' 'fail' 'completed' @('validation-profile-unknown')
    } else {
        & $addCheck 'validation-profile-closure' 'pass' 'completed' @()
    }

    $unavailableWritable = @($writable.ToArray() | Where-Object { -not $_.mapped -or -not $_.available })
    if ($unavailableWritable.Count -gt 0) {
        & $addCheck 'writable-repository-availability' 'incomplete' 'missing' @('writable-repository-unavailable')
    } else {
        & $addCheck 'writable-repository-availability' 'pass' 'completed' @()
    }

    if ($dependencies.Count -eq 0) {
        & $addCheck 'read-only-dependency-availability' 'pass' 'skipped' @('not-applicable')
    } elseif (@($dependencies.ToArray() | Where-Object { -not $_.mapped -or -not $_.exists }).Count -gt 0) {
        & $addCheck 'read-only-dependency-availability' 'incomplete' 'missing' @('read-only-dependency-unavailable')
    } else {
        & $addCheck 'read-only-dependency-availability' 'pass' 'completed' @()
    }

    $workMode = if ($Unit.PSObject.Properties.Name -contains 'work_mode') { [string]$Unit.work_mode } else { 'feature' }
    $knownWorkModes = @($lifecycle.work_modes | ForEach-Object { [string]$_ })
    $instructionReasons = New-Object System.Collections.Generic.List[string]
    if ($knownWorkModes -notcontains $workMode) { $instructionReasons.Add('work-mode-unknown') | Out-Null }
    $categoryAliases = @{}
    foreach ($alias in @($lifecycle.change_category_aliases)) { $categoryAliases[[string]$alias.alias] = [string]$alias.canonical }
    $effectiveCategories = @($Unit.change_categories | ForEach-Object {
        $category = [string]$_
        if ($categoryAliases.ContainsKey($category)) { $categoryAliases[$category] } else { $category }
    })
    $triggerCategories = @($lifecycle.instruction_sync.trigger_categories | ForEach-Object { [string]$_ })
    $triggered = @($effectiveCategories | Where-Object { $triggerCategories -contains $_ } | Sort-Object -Unique)
    if ($triggered.Count -eq 0 -and [string]$Unit.instruction_impact -eq 'none') {
        & $addCheck 'instruction-action-compatibility' 'pass' 'skipped' @('not-applicable')
    } else {
        $expectedImpact = if ($workMode -eq 'validation-only') { 'review' } else { 'update' }
        $expectedAction = if ($workMode -eq 'validation-only') { 'review-no-change' } else { 'update' }
        if ([string]$Unit.instruction_impact -ne $expectedImpact) { $instructionReasons.Add('instruction-impact-mode-mismatch') | Out-Null }
        if (-not $instructionObservationFailed) {
            foreach ($surface in @($Unit.instruction_surfaces | Where-Object { [string]$_.action -ceq 'update' })) {
                $matches = @($instructionObservations | Where-Object { [string]$_.path -ceq ([string]$surface.path).Replace('\', '/') })
                if ($matches.Count -ne 1) {
                    $instructionReasons.Add('instruction-surface-unresolved') | Out-Null
                    continue
                }
                $observation = $matches[0]
                $allowedRepository = @($Unit.allowed_repositories | Where-Object { [string]$_.repo_id -ceq [string]$observation.repo_id })
                if ($allowedRepository.Count -ne 1 -or -not (Test-MorphospacePathAllowed -Path ([string]$observation.relative_path) -AllowedPaths @($allowedRepository[0].allowed_paths))) {
                    $instructionReasons.Add('instruction-update-outside-write-scope') | Out-Null
                }
            }
        }
        # The action preflight is shared by lifecycle actions that are not
        # themselves instruction-admission transitions.  Keep those actions
        # on the aggregate contract branch; only Ready, Inspect, and Claim
        # need their transition-specific status assertions.
        $instructionCompatibilityPhase = if ($Action -in @('Inspect', 'Ready', 'Claim')) { $Action } else { 'Aggregate' }
        $activeContractReviewCompatible = Test-MorphospaceActiveUnitContractReviewCompatibility `
            -Unit $Unit -State $State -Lifecycle $lifecycle -Phase $instructionCompatibilityPhase -RepositoryMap $RepositoryMap
        if ($instructionObservationFailed) { $instructionReasons.Add('instruction-surface-unresolved') | Out-Null }
        foreach ($surface in @($Unit.instruction_surfaces)) {
            if ([string]$surface.action -ne $expectedAction -and -not $activeContractReviewCompatible) {
                $instructionReasons.Add('instruction-action-mode-mismatch') | Out-Null
            }
        }
        if ($instructionReasons.Count -gt 0) {
            & $addCheck 'instruction-action-compatibility' 'fail' 'completed' @($instructionReasons.ToArray())
        } else {
            & $addCheck 'instruction-action-compatibility' 'pass' 'completed' @()
        }
    }

    if (-not $requirementsDeclared) {
        if ($Unit.PSObject.Properties.Name -contains 'work_mode') {
            & $addCheck 'claim-requirements' 'fail' 'completed' @('claim-requirements-missing')
        } else {
            & $addCheck 'claim-requirements' 'pass' 'skipped' @('legacy-implicit-work-mode')
        }
    } else {
        $requirementsIncomplete = @($toolRows.ToArray() | Where-Object { -not $_.available }).Count -gt 0 -or
            @($inputRows.ToArray() | Where-Object { -not $_.exists -or -not $_.kind_matches }).Count -gt 0
        $requirementsFailed = @($diskRows.ToArray() | Where-Object { -not $_.passed -and $null -ne $_.available_free_mib }).Count -gt 0 -or
            @($inputRows.ToArray() | Where-Object { $null -ne $_.hash_matches -and -not $_.hash_matches }).Count -gt 0
        if ($requirementsFailed) { & $addCheck 'claim-requirements' 'fail' 'completed' @('claim-requirement-mismatch') }
        elseif ($requirementsIncomplete) { & $addCheck 'claim-requirements' 'incomplete' 'missing' @('claim-requirement-unavailable') }
        else { & $addCheck 'claim-requirements' 'pass' 'completed' @() }
    }

    if (-not $executionPreflightDeclared) {
        & $addCheck 'execution-preflight' 'pass' 'skipped' @('not-applicable')
    } elseif ($executionPreflightStatus -eq 'pass') {
        & $addCheck 'execution-preflight' 'pass' 'completed' @()
    } elseif ($executionPreflightStatus -eq 'fail') {
        & $addCheck 'execution-preflight' 'fail' 'completed' @('execution-preflight-mismatch')
    } else {
        & $addCheck 'execution-preflight' 'incomplete' 'missing' @('execution-preflight-unavailable')
    }

    if ($resources.Count -eq 0) {
        & $addCheck 'resource-declaration-uniqueness' 'pass' 'skipped' @('not-applicable')
    } elseif (@($resources | Group-Object resource_id | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
        & $addCheck 'resource-declaration-uniqueness' 'fail' 'completed' @('resource-declaration-duplicate')
    } else {
        & $addCheck 'resource-declaration-uniqueness' 'pass' 'completed' @()
    }

    if (@($ValidationMatrix | Where-Object { [string]$_.kind -eq 'device' }).Count -eq 0) {
        & $addCheck 'device-selection' 'pass' 'skipped' @('not-applicable')
    } elseif (@($ValidationMatrix | Where-Object { [string]$_.kind -eq 'device' -and [string]$_.disposition -eq 'blocked-missing-serials' }).Count -gt 0) {
        & $addCheck 'device-selection' 'incomplete' 'missing' @('device-serial-missing')
    } else {
        & $addCheck 'device-selection' 'pass' 'completed' @()
    }

    $declaredPaths = @(
        @($Unit.allowed_repositories | ForEach-Object { @($_.allowed_paths) })
        @($(if ($Unit.PSObject.Properties.Name -contains 'read_only_dependencies') { @($Unit.read_only_dependencies | ForEach-Object { @($_.paths) }) } else { @() }))
    ) | ForEach-Object { ([string]$_).Replace('\', '/') }
    $longDeclaredPaths = @($declaredPaths | Where-Object { $_.Length -gt 180 })
    if ($longDeclaredPaths.Count -gt 0) {
        & $addCheck 'declared-path-budget' 'incomplete' 'missing' @('declared-path-capability-unproven')
    } else {
        & $addCheck 'declared-path-budget' 'pass' 'completed' @()
    }

    $writableRoots = @($Unit.allowed_repositories | ForEach-Object {
        $repoId = [string]$_.repo_id
        if ($RepositoryMap.ContainsKey($repoId)) {
            [IO.Path]::GetFullPath([string]$RepositoryMap[$repoId].path).TrimEnd('\', '/').Replace('\', '/').ToLowerInvariant()
        }
    } | Where-Object { $_ })
    if (@($writableRoots | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
        & $addCheck 'single-writer-repository-map' 'fail' 'completed' @('writable-repository-map-alias')
    } else {
        & $addCheck 'single-writer-repository-map' 'pass' 'completed' @()
    }

    $checkRows = @($checks.ToArray() | Sort-Object check_id)
    $failedChecks = @($checkRows | Where-Object { $_.outcome -eq 'fail' })
    $missingChecks = @($checkRows | Where-Object { $_.coverage_state -eq 'missing' })
    $advisoryStatus = if ($failedChecks.Count -gt 0) { 'fail' } elseif ($missingChecks.Count -gt 0) { 'incomplete' } else { 'pass' }
    $coverage = [pscustomobject][ordered]@{
        expected = @($checkRows | ForEach-Object { [string]$_.check_id })
        completed = @($checkRows | Where-Object { $_.coverage_state -eq 'completed' } | ForEach-Object { [string]$_.check_id })
        skipped = @($checkRows | Where-Object { $_.coverage_state -eq 'skipped' } | ForEach-Object { [string]$_.check_id })
        missing = @($missingChecks | ForEach-Object { [string]$_.check_id })
        checks = $checkRows
    }

    return [pscustomobject][ordered]@{
        version = 'v2'
        ready_to_claim = ($issues.Count -eq 0)
        advisory_status = $advisoryStatus
        candidate_fingerprint = $candidateFingerprint
        state_mutation_performed = $false
        reason_codes = @($checkRows | ForEach-Object { @($_.reason_codes) } | Sort-Object -Unique | Where-Object { $_ -notin @('not-applicable', 'legacy-implicit-work-mode', 'legacy-risk-inference') })
        contract_bindings = $contractBindings
        coverage = $coverage
        validation_tier = $ValidationTier
        guard_profile = $guardProfile
        execution_preflight = [pscustomobject][ordered]@{
            declared = $executionPreflightDeclared
            status = $executionPreflightStatus
            observation = $executionPreflightObservation
            assertions = @($executionPreflightRows.ToArray())
            issues = @($executionPreflightIssues.ToArray())
        }
        requirements_declared = $requirementsDeclared
        disk = @($diskRows.ToArray())
        tools = @($toolRows.ToArray())
        product_inputs = @($inputRows.ToArray())
        writable_repositories = @($writable.ToArray())
        read_only_dependencies = @($dependencies.ToArray())
        instruction_surfaces = @($instructionObservations)
        resources = @($resources | Sort-Object resource_id)
        validation_matrix = @($ValidationMatrix)
        issues = @($issues.ToArray())
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

function Get-MorphospaceInstructionSurfaceCompletionPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap
    )

    if ([string]$Unit.instruction_impact -eq "none") {
        throw "Instruction-surface completion requires review or update impact."
    }
    $planned = @($Unit.instruction_surfaces | Where-Object { [string]$_.status -eq "planned" })
    if ($planned.Count -eq 0) { throw "Instruction-surface completion requires at least one planned surface." }
    if ($planned.Count -gt 64) { throw "Instruction-surface completion is limited to 64 planned surfaces." }

    $instructionRepositoryMap = @{}
    foreach ($repoId in @($RepositoryMap.Keys)) {
        $entry = ($RepositoryMap[$repoId] | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        if ($entry.PSObject.Properties.Name -notcontains "aliases") {
            $entry | Add-Member -NotePropertyName aliases -NotePropertyValue @()
        }
        $instructionRepositoryMap[[string]$repoId] = $entry
    }

    $targetUnit = ($Unit | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
    foreach ($surface in @($targetUnit.instruction_surfaces)) {
        if ([string]$surface.status -eq "planned") {
            $surface.status = "complete"
        } elseif ([string]$surface.status -ne "complete") {
            throw "Instruction surface has an unsupported status: $([string]$surface.path)"
        }
    }

    $observations = @(Get-MorphospaceInstructionObservation -Unit $targetUnit -RepositoryMap $instructionRepositoryMap)
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($surface in $planned) {
        $declaredPath = ([string]$surface.path).Replace("\", "/")
        $matches = @($observations | Where-Object { [string]$_.path -ceq $declaredPath })
        if ($matches.Count -ne 1) {
            throw "Planned instruction surface did not resolve to one stable observation: $declaredPath"
        }
        $observation = $matches[0]
        $skillId = if ($surface.PSObject.Properties.Name -contains "skill_id") { $surface.skill_id } else { $null }
        $identity = [pscustomobject][ordered]@{
            surface_kind = [string]$surface.surface_kind
            declared_path = $declaredPath
            repo_id = [string]$observation.repo_id
            relative_path = [string]$observation.relative_path
            owner = [string]$surface.owner
            action = [string]$surface.action
            validation = [string]$surface.validation
            skill_id = $skillId
        }
        $records.Add([pscustomobject][ordered]@{
            surface_id = Get-MorphospaceCanonicalJsonSha256 $identity
            surface_kind = [string]$identity.surface_kind
            declared_path = [string]$identity.declared_path
            repo_id = [string]$identity.repo_id
            relative_path = [string]$identity.relative_path
            owner = [string]$identity.owner
            action = [string]$identity.action
            validation = [string]$identity.validation
            skill_id = $identity.skill_id
            previous_status = "planned"
            resulting_status = "complete"
            sha256 = [string]$observation.sha256
        }) | Out-Null
    }
    $surfaceRecords = @($records.ToArray() | Sort-Object surface_id -CaseSensitive)
    $observationDocument = [pscustomobject][ordered]@{ surfaces = $surfaceRecords }
    return [pscustomobject][ordered]@{
        target_unit = $targetUnit
        resulting_unit_sha256 = Get-MorphospaceCanonicalJsonSha256 $targetUnit
        observation_sha256 = Get-MorphospaceCanonicalJsonSha256 $observationDocument
        surfaces = $surfaceRecords
    }
}

function Assert-MorphospaceExactInstructionSurfaceIds {
    param(
        [Parameter(Mandatory = $true)][object[]]$Surfaces,
        [AllowEmptyCollection()][string[]]$RequestedIds = @(),
        [switch]$Required
    )

    $expected = @($Surfaces | ForEach-Object { [string]$_.surface_id } | Sort-Object -CaseSensitive)
    $provided = @($RequestedIds | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
    if ($Required -and $provided.Count -eq 0) { throw "Executed instruction-surface completion requires exact InstructionSurfaceIds from the dry run." }
    if ($provided.Count -eq 0) { return }
    if (@($provided | Select-Object -Unique).Count -ne $provided.Count) { throw "InstructionSurfaceIds contains a duplicate identity." }
    if ($provided.Count -ne $expected.Count) { throw "InstructionSurfaceIds must equal the complete planned surface set." }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($provided[$index] -cne $expected[$index]) { throw "InstructionSurfaceIds must equal the complete planned surface set." }
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
    $observedRepositoryIds = @{}
    foreach ($repo in @($unit.allowed_repositories | Sort-Object repo_id)) {
        $repoId = [string]$repo.repo_id
        $observedRepositoryIds[$repoId] = $true
        if ($repoMap.ContainsKey($repoId)) {
            $repositoryStates.Add((Get-MorphospaceRepositoryState -RepoId $repoId -Path ([string]$repoMap[$repoId].path))) | Out-Null
        }
    }
    foreach ($dependency in @($(if ($unit.PSObject.Properties.Name -contains 'read_only_dependencies') { @($unit.read_only_dependencies) } else { @() }) | Sort-Object repo_id)) {
        $repoId = [string]$dependency.repo_id
        if ($observedRepositoryIds.ContainsKey($repoId)) { continue }
        $observedRepositoryIds[$repoId] = $true
        if ($repoMap.ContainsKey($repoId)) {
            $repositoryStates.Add((Get-MorphospaceRepositoryState -RepoId $repoId -Path ([string]$repoMap[$repoId].path))) | Out-Null
        } else {
            $repositoryStates.Add([pscustomobject][ordered]@{ repo_id = $repoId; mapped = $false; relation = 'not-mapped' }) | Out-Null
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
    $requiredDebtBinding = Assert-MorphospaceHistoricalValidationDebtReceiptRequirement -WorkspaceRoot $WorkspaceRoot -CurrentUnit $Unit -Receipt $receipt
    if ($receipt.PSObject.Properties.Name -contains 'historical_validation_debt') {
        $debtResult = Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $WorkspaceRoot -Binding $receipt.historical_validation_debt
        $currentUnitPath = Join-Path $WorkspaceRoot ("iteration-units/{0}.json" -f [string]$Unit.unit_id)
        if ([string]$debtResult.project_id -cne [string]$Spec.project_id -or
            [string]$debtResult.current_unit.unit_id -cne [string]$Unit.unit_id -or
            -not (Test-Path -LiteralPath $currentUnitPath -PathType Leaf) -or
            [string]$debtResult.current_unit.raw_sha256 -cne (Get-MorphospaceFileSha256 -Path $currentUnitPath) -or
            [string]$debtResult.current_unit.canonical_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 -Value $Unit)) {
            throw 'Validation receipt historical-debt binding does not match the exact current unit.'
        }
    }

    $artifactMap = @{}
    $artifactPathMap = @{}
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
        $artifactPathMap[$artifactId] = $artifactPath
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
    $unmatchedGateDefinitions = New-Object System.Collections.Generic.List[object]
    foreach ($definition in @($ValidationMatrix | Where-Object { [string]$_.disposition -ne "forbidden" })) {
        $unmatchedGateDefinitions.Add($definition) | Out-Null
    }
    foreach ($gate in @($receipt.gates)) {
        $definitionIndex = -1
        for ($index = 0; $index -lt $unmatchedGateDefinitions.Count; $index++) {
            $candidate = $unmatchedGateDefinitions[$index]
            if (
                [string]$candidate.gate_id -eq [string]$gate.gate_id -and
                [string]$candidate.command -ceq [string]$gate.command
            ) {
                $definitionIndex = $index
                break
            }
        }
        if ($definitionIndex -lt 0) { throw "Validation command drifted for gate '$($gate.gate_id)'." }
        $unmatchedGateDefinitions.RemoveAt($definitionIndex)
        if ($ExpectedResult -eq "pass" -and [string]$gate.status -ne "pass") { throw "Passing validation has a non-passing gate '$($gate.gate_id)'." }
        foreach ($reference in @($gate.evidence_refs)) {
            if (-not $artifactMap.ContainsKey([string]$reference)) { throw "Gate '$($gate.gate_id)' references unknown artifact '$reference'." }
        }
        if (@($gate.evidence_refs).Count -eq 0) { throw "Gate '$($gate.gate_id)' has no evidence references." }
        if (($definition.PSObject.Properties.Name -contains 'selection_kind') -and [string]$definition.selection_kind -ceq 'exact-external-evidence') {
            $expectedEvidencePath = [IO.Path]::GetFullPath([string]$definition.selector.evidence.path)
            $matchingEvidenceReferences = @($gate.evidence_refs | Where-Object {
                $referenceId = [string]$_
                $artifactPathMap.ContainsKey($referenceId) -and
                [string]$artifactPathMap[$referenceId] -ceq $expectedEvidencePath
            })
            if ($matchingEvidenceReferences.Count -ne 1) {
                throw "Selected validation gate '$($gate.gate_id)' must reference exactly its bound external evidence artifact."
            }
            $selectedArtifact = $artifactMap[[string]$matchingEvidenceReferences[0]]
            if ([string]$selectedArtifact.sha256 -cne [string]$definition.selector.evidence.sha256) {
                throw "Selected validation gate '$($gate.gate_id)' external evidence hash drifted."
            }
        }
    }
    if ($unmatchedGateDefinitions.Count -ne 0) { throw "Validation receipt does not cover the exact validation-gate set." }

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

function Get-MorphospaceReadyUnitQueue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$UnitMap,
        [string]$ExcludeUnitId = ''
    )

    $ready = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($UnitMap.Values)) {
        $candidate = $entry.document
        if ([string]$candidate.status -ne "ready") { continue }
        if ($ExcludeUnitId -and [string]$candidate.unit_id -ceq $ExcludeUnitId) { continue }
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
    return @($ready | Sort-Object)
}

function Get-MorphospaceNextReadyUnit {
    param([Parameter(Mandatory = $true)][hashtable]$UnitMap)

    return @(Get-MorphospaceReadyUnitQueue -UnitMap $UnitMap | Select-Object -First 1)
}

function Get-MorphospaceAutomationEventLedgerSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$EventsPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events
    )

    $bytes = [IO.File]::ReadAllBytes($EventsPath)
    if ($bytes.LongLength -gt 0 -and $bytes[$bytes.LongLength - 1] -ne 0x0a) {
        throw 'Work-unit automation requires the event ledger to end with LF before an owned append.'
    }
    return [pscustomobject][ordered]@{
        sha256 = Get-MorphospaceSha256Bytes -Bytes $bytes
        length = [int64]$bytes.LongLength
        tail_id = if ($Events.Count -gt 0) { [string]$Events[-1].event_id } else { $null }
    }
}

function Get-MorphospaceReadyWithdrawalBinding {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitRelativePath,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][object]$LiveState,
        [Parameter(Mandatory = $true)][object]$LiveUnit,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory = $true)][hashtable]$UnitMap,
        [Parameter(Mandatory = $true)][string]$ExpectedStateSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedUnitSha256
    )

    if ([string]$LiveState.next_ready_unit -cne $UnitId) {
        throw "WithdrawReady requires '$UnitId' to be the exact next-ready unit."
    }
    if ([string]$LiveUnit.status -cne 'ready') {
        throw "WithdrawReady requires ready status; '$UnitId' is '$([string]$LiveUnit.status)'."
    }
    if ([string]$LiveState.current_unit -ceq $UnitId) {
        throw 'WithdrawReady may not target the current unit.'
    }

    $queueBefore = @(Get-MorphospaceReadyUnitQueue -UnitMap $UnitMap)
    if ($queueBefore.Count -eq 0 -or [string]$queueBefore[0] -cne $UnitId) {
        throw 'WithdrawReady found a contradictory or non-derivable next-ready projection.'
    }

    $expectedSummary = 'Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites.'
    $escapedUnitId = [regex]::Escape($UnitId)
    $readyEvents = @($Events | Where-Object {
        [string]$_.project_id -ceq $ProjectId -and
        [string]$_.unit_id -ceq $UnitId -and
        [string]$_.event_type -ceq 'state-transition' -and
        [string]$_.summary -ceq $expectedSummary -and
        [string]$_.event_id -cmatch "^$escapedUnitId-ready-[0-9]{4}$" -and
        @($_.receipts).Count -eq 0
    })
    if ($readyEvents.Count -ne 1) {
        throw "WithdrawReady requires exactly one owner-generated Ready event for '$UnitId'."
    }
    $readyEvent = $readyEvents[0]
    $transactionId = "$([string]$readyEvent.event_id)-transition"
    $authentication = Complete-MorphospaceTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId
    if ([string]$authentication.status -cne 'already-committed') {
        throw 'WithdrawReady requires an already committed Ready transaction.'
    }

    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentPath = Join-Path $WorkspaceRoot ($intentRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $completionPath = Join-Path $WorkspaceRoot ($completionRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $intent = Read-MorphospaceProtocolJson -Path $intentPath
    $completion = Read-MorphospaceProtocolJson -Path $completionPath
    if ([string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
        [string]$intent.transaction_id -cne $transactionId -or
        [string]$intent.state.path -cne 'workspace.state.json' -or
        [string]$intent.unit.path -cne $UnitRelativePath -or
        [string]$intent.events.path -cne 'iteration-events.jsonl' -or
        [string]$intent.event.event_id -cne [string]$readyEvent.event_id -or
        [int]$intent.event.sequence -ne [int]$readyEvent.sequence -or
        [string]$intent.target.unit.document.project_id -cne $ProjectId -or
        [string]$intent.target.unit.document.unit_id -cne $UnitId -or
        [string]$intent.target.unit.document.status -cne 'ready' -or
        [string]$intent.target.state.document.project_id -cne $ProjectId -or
        [string]$intent.target.state.document.last_event_id -cne [string]$readyEvent.event_id -or
        [string]$intent.target.unit.sha256 -cne $ExpectedUnitSha256 -or
        [string]$completion.transaction_id -cne $transactionId -or
        [string]$completion.event_id -cne [string]$readyEvent.event_id -or
        [string]$completion.unit_sha256 -cne $ExpectedUnitSha256) {
        throw 'WithdrawReady original Ready transaction does not bind the exact live unit and historical ready projection.'
    }

    $eventsPath = Join-Path $WorkspaceRoot 'iteration-events.jsonl'
    $ledger = Get-MorphospaceAutomationEventLedgerSnapshot -EventsPath $eventsPath -Events $Events
    $queueAfter = @(Get-MorphospaceReadyUnitQueue -UnitMap $UnitMap -ExcludeUnitId $UnitId)
    return [pscustomobject][ordered]@{
        original_ready_event = [pscustomobject][ordered]@{
            event_id = [string]$intent.event.event_id
            sequence = [int]$intent.event.sequence
            sha256 = Get-MorphospaceCanonicalJsonSha256 $intent.event
        }
        original_ready_transaction = [pscustomobject][ordered]@{
            transaction_id = $transactionId
            intent = [pscustomobject][ordered]@{ path = $intentRelative; sha256 = Get-MorphospaceFileSha256 $intentPath }
            completion = [pscustomobject][ordered]@{ path = $completionRelative; sha256 = Get-MorphospaceFileSha256 $completionPath }
            target_state_sha256 = [string]$intent.target.state.sha256
            target_unit_sha256 = [string]$intent.target.unit.sha256
        }
        authenticated_preimage = [pscustomobject][ordered]@{
            state_sha256 = $ExpectedStateSha256
            unit_sha256 = $ExpectedUnitSha256
            events_sha256 = [string]$ledger.sha256
            events_length = [int64]$ledger.length
            event_tail_id = $ledger.tail_id
        }
        next_ready_unit_before = $UnitId
        next_ready_unit_after = if ($queueAfter.Count -gt 0) { [string]$queueAfter[0] } else { $null }
        ready_queue_before = @($queueBefore)
        ready_queue_after = @($queueAfter)
        original_ready_event_preserved = $true
    }
}

function Get-MorphospaceBlockedSuccessorTerminalRelease {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][object]$Unit,
        [Parameter(Mandatory)][string]$UnitRelativePath,
        [Parameter(Mandatory)][object]$SelectedUnitEntry,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object[]]$Events,
        [Parameter(Mandatory)][object]$Selection,
        [Parameter(Mandatory)][hashtable]$RepositoryMap,
        [Parameter(Mandatory)][string]$Timestamp
    )
    if([string]$Unit.status-cne'proposed'-or$Events.Count-lt3-or[string]$State.last_event_id-cne[string]$Events[-1].event_id){throw 'Blocked-successor Ready requires its proposed unit and exact admission tail.'}
    $admissionEvent=$Events[-1];$admissionMatch=[regex]::Match([string]$admissionEvent.event_id,'^(?<admission>[a-z0-9][a-z0-9-]{1,127})-admitted$')
    if(-not$admissionMatch.Success-or[string]$admissionEvent.unit_id-cne$UnitId-or[string]$admissionEvent.event_type-cne'state-transition'-or@($admissionEvent.receipts).Count-ne1){throw 'Blocked-successor Ready lacks its exact admission event.'}
    $admissionId=[string]$admissionMatch.Groups['admission'].Value;$admissionRelative="receipts/$admissionId.json"
    if([string]$admissionEvent.receipts[0]-cne$admissionRelative){throw 'Blocked-successor admission event references a different receipt.'}
    $admissionPath=Resolve-MorphospaceWorkspacePath $WorkspaceRoot $admissionRelative -RequireLeaf
    $admissionSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\development-unit-admission-v1.schema.json'
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $admissionPath) -SchemaFile $admissionSchema)){throw 'Blocked-successor admission receipt is invalid.'}
    $admission=Read-MorphospaceProtocolJson $admissionPath
    if((Get-MorphospaceDevelopmentAdmissionKind $admission)-cne'blocked-successor'-or[string]$admission.unit_id-cne$UnitId-or(Get-MorphospaceCanonicalJsonSha256 $admission.unit)-cne(Get-MorphospaceCanonicalJsonSha256 $Unit)){throw 'Ready target is not the exact blocked-successor admission.'}
    $provenance=Test-MorphospaceDevelopmentUnitPreparation -WorkspaceRoot $WorkspaceRoot -Admission $admission -Phase Release
    $preparation=$provenance.receipt;$terminal=$preparation.terminal;$verifiedTerminal=$provenance.terminal_observation
    if($null-eq$verifiedTerminal-or(Get-MorphospaceCanonicalJsonSha256 $verifiedTerminal.unit)-cne(Get-MorphospaceCanonicalJsonSha256 $SelectedUnitEntry.document)-or(Get-MorphospaceFileSha256 $SelectedUnitEntry.path)-cne[string]$terminal.unit_raw_sha256-or[string]$verifiedTerminal.event.event_id-cne[string]$terminal.event_id){throw 'Blocked-successor Ready did not consume the exact verified terminal observation.'}
    if([string]$Selection.unit_id-cne[string]$terminal.unit_id-or(Get-MorphospaceCanonicalJsonSha256 $Selection)-cne[string]$terminal.selector_binding_sha256-or[string]$Selection.tier-cne'quick'){throw 'Blocked-successor Ready stale selector binding drifted.'}
    if([string]$SelectedUnitEntry.document.status-cne'blocked'-or[string]$SelectedUnitEntry.document.unit_id-cne[string]$terminal.unit_id){throw 'Blocked-successor Ready terminal unit is absent or no longer blocked.'}
    if($Events.Count-lt3){throw 'Blocked-successor Ready lacks its exact three-event suffix.'}
    $terminalEvent=$Events[-3];$preparationEvent=$Events[-2]
    if([string]$terminalEvent.event_id-cne[string]$terminal.event_id-or(Get-MorphospaceCanonicalJsonSha256 $terminalEvent)-cne[string]$terminal.event_sha256-or[string]$preparationEvent.event_id-cne"$([string]$preparation.preparation_id)-prepared"-or[string]$provenance.preparation_event.event_id-cne[string]$preparationEvent.event_id-or[int]$preparationEvent.sequence-ne([int]$terminalEvent.sequence+1)-or[int]$admissionEvent.sequence-ne([int]$preparationEvent.sequence+1)){throw 'Blocked-successor Ready terminal/preparation/admission suffix is not contiguous and exact.'}
    $checkpoint=$State.validation_checkpoint
    if($null-eq$checkpoint-or[string]$checkpoint.tier-cne'standard'-or[string]$checkpoint.result-cne[string]$terminal.checkpoint.result-or[string]$checkpoint.receipt-cne[string]$terminal.checkpoint.receipt_path){throw 'Blocked-successor Ready Standard checkpoint drifted.'}
    $blocker=@($State.blockers|Where-Object{[string]$_.blocker_id-ceq"$([string]$terminal.unit_id)-validation-$([string]$terminal.checkpoint.result)"})
    if($blocker.Count-ne1-or(Get-MorphospaceCanonicalJsonSha256 $blocker[0])-cne[string]$terminal.blocker_sha256){throw 'Blocked-successor Ready terminal blocker drifted.'}
    $admissionTx="$admissionId-admitted-transition";[void](Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId $admissionTx -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $UnitRelativePath -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail)
    foreach($sourceRepo in @($provenance.source_lock.repositories)){
        $id=[string]$sourceRepo.repo_id;if(-not$RepositoryMap.ContainsKey($id)){throw "Blocked-successor Ready source repository '$id' is unmapped."}
        $observed=Get-MorphospaceRepositoryState -RepoId $id -Path ([string]$RepositoryMap[$id].path)
        if(-not[bool]$observed.available-or-not[bool]$observed.is_git-or[bool]$observed.dirty-or@($observed.status_porcelain).Count-ne0-or[string]$observed.head-cne[string]$sourceRepo.commit-or[string]$observed.tree-cne[string]$sourceRepo.tree){throw "Blocked-successor Ready source repository '$id' drifted from its prepared clean lock."}
    }
    $proof=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.terminal_validation_selection_release.v2'
        release_id="$UnitId-terminal-validation-selection-release"
        created_at=$Timestamp
        project_id=[string]$State.project_id
        successor=[pscustomobject][ordered]@{
            unit_id=$UnitId;path=$UnitRelativePath;raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $WorkspaceRoot $UnitRelativePath -RequireLeaf);canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $Unit
            admission_id=$admissionId;admission_receipt_path=$admissionRelative;admission_receipt_sha256=Get-MorphospaceFileSha256 $admissionPath;terminal_binding_sha256=[string]$preparation.terminal_binding_sha256
        }
        terminal=[pscustomobject][ordered]@{
            binding=$terminal
            preparation=[pscustomobject][ordered]@{preparation_id=[string]$preparation.preparation_id;receipt_path=[string]$admission.preparation.receipt_path;receipt_sha256=[string]$admission.preparation.receipt_sha256;event_id=[string]$preparationEvent.event_id;transaction_id="$([string]$preparation.preparation_id)-prepared-transition"}
            admission=[pscustomobject][ordered]@{event_id=[string]$admissionEvent.event_id;transaction_id=$admissionTx}
        }
        selector_evidence_verified=$false
        selector_evidence_reused=$false
        does_not_authorize=@('Releases only the exact stale Quick selector during Ready of the authenticated bounded successor; no selector evidence is claimed, verified, or reused, and no source, build, device, acceptance, or publication action is authorized.')
    }
    $schema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\terminal-validation-selection-release-v2.schema.json'
    if(-not(Test-Json -Json ($proof|ConvertTo-Json -Depth 100 -Compress) -SchemaFile $schema)){throw 'Blocked-successor terminal selector release does not satisfy release-v2.'}
    return $proof
}

function Get-MorphospaceProposedRetirementBinding {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitRelativePath,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$ReplacementUnitId,
        [Parameter(Mandatory = $true)][ValidateSet('contract-invalid')][string]$Reason,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][object]$LiveState,
        [Parameter(Mandatory = $true)][object]$LiveUnit,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory = $true)][hashtable]$UnitMap,
        [Parameter(Mandatory = $true)][string]$ExpectedStateSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedUnitSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedUnitRawSha256
    )

    if ([string]$LiveUnit.status -cne 'proposed') {
        throw "RetireProposed requires proposed status; '$UnitId' is '$([string]$LiveUnit.status)'."
    }
    if ($null -ne $LiveState.current_unit -or $null -ne $LiveState.next_ready_unit) {
        throw 'RetireProposed requires an idle project with no current or next-ready unit.'
    }
    foreach ($identity in @($UnitId, $ReplacementUnitId)) {
        if ($identity -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$' -or $identity.Contains('-superseded-by-', [StringComparison]::Ordinal)) {
            throw "RetireProposed received a non-portable or reserved unit identity '$identity'."
        }
    }
    if ($UnitId -ceq $ReplacementUnitId) { throw 'RetireProposed requires a distinct replacement unit identity.' }
    if ($UnitMap.ContainsKey($ReplacementUnitId)) { throw "RetireProposed replacement identity '$ReplacementUnitId' already exists." }
    if ($Events.Count -lt 1) { throw 'RetireProposed requires the exact owner-generated admission event.' }

    $eventsPath = Join-Path $WorkspaceRoot 'iteration-events.jsonl'
    $ledger = Get-MorphospaceAutomationEventLedgerSnapshot -EventsPath $eventsPath -Events $Events
    $admissionEvent = $Events[-1]
    $admissionMatch = [regex]::Match([string]$admissionEvent.event_id, '^(?<admission>[a-z0-9][a-z0-9-]{1,127})-admitted$')
    if ([string]$LiveState.last_event_id -cne [string]$admissionEvent.event_id -or
        [string]$admissionEvent.project_id -cne $ProjectId -or
        [string]$admissionEvent.unit_id -cne $UnitId -or
        [string]$admissionEvent.event_type -cne 'state-transition' -or
        [string]$admissionEvent.summary -cne 'Admitted a bounded proposed development unit; normal Ready, Inspect, and Claim remain required.' -or
        -not $admissionMatch.Success -or
        @($admissionEvent.receipts).Count -ne 1) {
        throw 'RetireProposed requires the admission event to be the exact current ledger tail.'
    }

    $admissionId = [string]$admissionMatch.Groups['admission'].Value
    $receiptRelative = "receipts/$admissionId.json"
    if ([string]@($admissionEvent.receipts)[0] -cne $receiptRelative) {
        throw 'RetireProposed admission event does not reference its exact admission receipt.'
    }
    $receiptPath = Join-Path $WorkspaceRoot ($receiptRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $receiptSchema = Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\development-unit-admission-v1.schema.json'
    if (-not [IO.File]::Exists($receiptPath) -or
        -not (Test-Json -Json (Get-Content -LiteralPath $receiptPath -Raw) -SchemaFile $receiptSchema)) {
        throw 'RetireProposed admission receipt is absent or invalid.'
    }
    $admission = Read-MorphospaceProtocolJson -Path $receiptPath
    if ([string]$admission.admission_id -cne $admissionId -or
        [string]$admission.project_id -cne $ProjectId -or
        [string]$admission.unit_id -cne $UnitId -or
        [string]$admission.unit.project_id -cne $ProjectId -or
        [string]$admission.unit.unit_id -cne $UnitId -or
        [string]$admission.unit.status -cne 'proposed' -or
        (Get-MorphospaceCanonicalJsonSha256 $admission.unit) -cne $ExpectedUnitSha256) {
        throw 'RetireProposed admission receipt does not bind the exact live proposed unit.'
    }

    $transactionId = "$admissionId-admitted-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentPath = Join-Path $WorkspaceRoot ($intentRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $completionPath = Join-Path $WorkspaceRoot ($completionRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not [IO.File]::Exists($intentPath) -or -not [IO.File]::Exists($completionPath)) {
        throw 'RetireProposed requires a complete admission intent/completion chain.'
    }
    $authentication = Complete-MorphospaceTransitionLedger -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId
    if ([string]$authentication.status -cne 'already-committed') {
        throw 'RetireProposed requires an already committed admission transaction.'
    }
    $intent = Read-MorphospaceProtocolJson -Path $intentPath
    $completion = Read-MorphospaceProtocolJson -Path $completionPath
    $receiptHash = Get-MorphospaceFileSha256 $receiptPath
    $receiptBytesBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($receiptPath))
    if ([string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
        [string]$intent.transaction_id -cne $transactionId -or
        [string]$intent.state.path -cne 'workspace.state.json' -or
        [string]$intent.unit.path -cne $UnitRelativePath -or
        [string]$intent.events.path -cne 'iteration-events.jsonl' -or
        [string]$intent.event.event_id -cne [string]$admissionEvent.event_id -or
        [int]$intent.event.sequence -ne [int]$admissionEvent.sequence -or
        [string]$intent.target.state.sha256 -cne $ExpectedStateSha256 -or
        [string]$intent.target.unit.sha256 -cne $ExpectedUnitSha256 -or
        @($intent.artifacts).Count -ne 1 -or
        [string]$intent.artifacts[0].path -cne $receiptRelative -or
        [string]$intent.artifacts[0].sha256 -cne $receiptHash -or
        [string]$intent.artifacts[0].bytes_base64 -cne $receiptBytesBase64 -or
        [string]$completion.transaction_id -cne $transactionId -or
        [string]$completion.event_id -cne [string]$admissionEvent.event_id -or
        [string]$completion.state_sha256 -cne $ExpectedStateSha256 -or
        [string]$completion.unit_sha256 -cne $ExpectedUnitSha256) {
        throw 'RetireProposed admission transaction does not bind the exact live state, unit, event, and receipt bytes.'
    }

    $base = [pscustomobject][ordered]@{
        replacement_unit_id = $ReplacementUnitId
        reason = $Reason
        authenticated_admission = [pscustomobject][ordered]@{
            admission_id = $admissionId
            event = [pscustomobject][ordered]@{
                event_id = [string]$admissionEvent.event_id
                sequence = [int]$admissionEvent.sequence
                sha256 = Get-MorphospaceCanonicalJsonSha256 $intent.event
            }
            receipt = [pscustomobject][ordered]@{ path = $receiptRelative; sha256 = $receiptHash }
            transaction = [pscustomobject][ordered]@{
                transaction_id = $transactionId
                intent = [pscustomobject][ordered]@{ path = $intentRelative; sha256 = Get-MorphospaceFileSha256 $intentPath }
                completion = [pscustomobject][ordered]@{ path = $completionRelative; sha256 = Get-MorphospaceFileSha256 $completionPath }
                target_state_sha256 = [string]$intent.target.state.sha256
                target_unit_sha256 = [string]$intent.target.unit.sha256
            }
        }
        authenticated_preimage = [pscustomobject][ordered]@{
            state_sha256 = $ExpectedStateSha256
            unit_sha256 = $ExpectedUnitSha256
            unit_raw_sha256 = $ExpectedUnitRawSha256
            events_sha256 = [string]$ledger.sha256
            events_length = [int64]$ledger.length
            event_tail_id = [string]$ledger.tail_id
        }
        replacement_identity_absent = $true
        current_unit_absent = $true
        next_ready_unit_absent = $true
        original_admission_preserved = $true
    }
    return [pscustomobject][ordered]@{
        replacement_unit_id = $base.replacement_unit_id
        reason = $base.reason
        authenticated_admission = $base.authenticated_admission
        authenticated_preimage = $base.authenticated_preimage
        replacement_identity_absent = $base.replacement_identity_absent
        current_unit_absent = $base.current_unit_absent
        next_ready_unit_absent = $base.next_ready_unit_absent
        original_admission_preserved = $base.original_admission_preserved
        binding_sha256 = Get-MorphospaceCanonicalJsonSha256 $base
    }
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
        [Parameter(Mandatory = $true)][ValidateSet("Inspect", "RetireProposed", "Ready", "WithdrawReady", "Claim", "Resume", "CompleteInstructionSurfaces", "BeginValidation", "ReturnToActive", "PreflightValidation", "RecordValidation", "Accept", "PreparePush", "RecordPublication", "Recover", "ReconcilePublication", "AdoptPublishedPlanningAuthority", "ReconcilePlanningSuffixRewrite", "ReconcilePublishedPrerequisiteSuffix", "ReconcileExecutedPreparedPublication")][string]$Action,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [string]$UnitId = "",
        [string]$RepoMapPath = "",
        [string]$RevisionsPath = "",
        [ValidateSet("pass", "partial", "fail", "blocked")][string]$ValidationResult = "pass",
        [string]$ValidationReceipt = "",
        [string]$RecoveryReceipt = "",
        [string]$PublicationClosure = "",
        [string]$PublishedPlanningAuthorityAdoption = "",
        [string]$PublicationAccounting = "",
        [string]$PlanningSuffixRewriteRecovery = "",
        [string]$PublishedPrerequisiteSuffixReconciliation = "",
        [string]$ExecutedPreparedPublicationReconciliation = "",
        [string]$PublicationOrderingInterruption = "",
        [string]$AdoptionReceipt = "",
        [string]$InstructionCompletionId = "",
        [string[]]$InstructionSurfaceIds = @(),
        [string]$ExpectedUnitSha256 = "",
        [string]$ExpectedUnitRawSha256 = "",
        [string]$ExpectedStateSha256 = "",
        [string]$ExpectedEventsSha256 = "",
        [long]$ExpectedEventsLength = -1,
        [string]$ExpectedEventTailId = "",
        [string]$ReplacementUnitId = "",
        [ValidateSet('contract-invalid')][string]$RetirementReason = 'contract-invalid',
        [string]$ExpectedProposedRetirementBindingSha256 = "",
        [string]$ExpectedInstructionObservationSha256 = "",
        [ValidateSet("quick", "standard", "deep")][string]$ValidationTier = "standard",
        [string]$ValidationSelector = "",
        [string]$ExpectedValidationSelectorSha256 = "",
        [string]$ValidationEvidencePath = "",
        [string[]]$DeviceSerials = @(),
        [string]$AuthorityRunnerPath = "",
        [string[]]$AuthorityRunnerArguments = @(),
        [string]$Timestamp = "",
        [string]$OutPath = "",
        [ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$TransitionFaultAfter = 'none',
        [switch]$Execute
    )

    $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    if ($TransitionFaultAfter -ne 'none' -and ($Action -notin @('WithdrawReady', 'RetireProposed') -or -not $Execute)) {
        throw 'Transition fault injection is available only to executed WithdrawReady or RetireProposed owner tests.'
    }
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
    if ($Action -in @("PreparePush", "RecordPublication", "ReconcilePublication", "AdoptPublishedPlanningAuthority", "ReconcilePlanningSuffixRewrite", "ReconcilePublishedPrerequisiteSuffix", "ReconcileExecutedPreparedPublication")) {
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
        $planningCommon = Get-MorphospaceGitCommonDirectory ([string]$planningEntry.path)
        foreach ($repo in @($unit.allowed_repositories)) {
            $repoId = [string]$repo.repo_id
            if ($repoMap.ContainsKey($repoId) -and (Get-MorphospaceGitCommonDirectory ([string]$repoMap[$repoId].path)) -ceq $planningCommon) {
                throw "The external planning repository may not share Git common-directory authority with source repository '$repoId'."
            }
        }
        $planningState = Get-MorphospaceRepositoryState -RepoId ([string]$planningEntry.repo_id) -Path ([string]$planningEntry.path)
        $planningState | Add-Member -NotePropertyName workflow_transport -NotePropertyValue $true
        $repositoryStates.Add($planningState) | Out-Null
    }
    $repoStatesArray = @($repositoryStates.ToArray())
    $beforeStatus = [string]$unit.status
    $existingValidationSelection = if (
        ($state.PSObject.Properties.Name -contains 'normal_validation_selection') -and
        $null -ne $state.normal_validation_selection
    ) { $state.normal_validation_selection } else { $null }
    $releaseTerminalValidationSelection = $false
    $terminalSelectionReleaseProof = $null
    $terminalSelectionReleaseProofReference = ''
    if ($null -ne $existingValidationSelection -and [string]$existingValidationSelection.unit_id -cne $UnitId) {
        $selectedUnitId = [string]$existingValidationSelection.unit_id
        $selectedUnitEntry = if ($unitMap.ContainsKey($selectedUnitId)) { $unitMap[$selectedUnitId] } else { $null }
        $checkpoint = if ($state.PSObject.Properties.Name -contains 'validation_checkpoint') { $state.validation_checkpoint } else { $null }
        $checkpointResult = if ($null -ne $checkpoint) { [string]$checkpoint.result } else { '' }
        $checkpointReceipt = if ($null -ne $checkpoint) { [string]$checkpoint.receipt } else { '' }
        $expectedBlockerId = "$selectedUnitId-validation-$checkpointResult"
        $expectedBlockerCondition = "Validation result is $checkpointResult in $checkpointReceipt."
        $expectedBlockerResume = 'Correct the failure and explicitly resume the unit.'
        $terminalBlockersById = @($state.blockers | Where-Object { [string]$_.blocker_id -ceq $expectedBlockerId })
        $matchingTerminalBlockers = @($terminalBlockersById | Where-Object {
            [string]$_.condition -ceq $expectedBlockerCondition -and
            [string]$_.resume_when -ceq $expectedBlockerResume
        })
        $selectedUnitContract = if ($null -ne $selectedUnitEntry) {
            (($selectedUnitEntry.document | ConvertTo-Json -Depth 100) | ConvertFrom-Json)
        } else { $null }
        if ($null -ne $selectedUnitContract -and $selectedUnitContract.PSObject.Properties.Name -contains 'status') {
            $selectedUnitContract.PSObject.Properties.Remove('status')
        }
        $selectedUnitContractSha256 = if ($null -ne $selectedUnitContract) { Get-MorphospaceCanonicalJsonSha256 $selectedUnitContract } else { '' }
        $terminalReceipt = $null
        $terminalEvent = $null
        $terminalLedgerValid = $false
        $terminalLedgerFailure = 'not-evaluated'
        $terminalReceiptValid = $false
        $terminalReceiptFailure = 'not-evaluated'
        $terminalReleaseV2Failure = 'not-applicable'
        if($Action-ceq'Ready'-and$beforeStatus-ceq'proposed'-and$null-ne$selectedUnitEntry){
            try{
                $successorRelativePath=$unitEntry.path.Substring(($resolvedWorkspace.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar).Length).Replace('\', '/')
                $terminalSelectionReleaseProof=Get-MorphospaceBlockedSuccessorTerminalRelease -WorkspaceRoot $resolvedWorkspace -UnitId $UnitId -Unit $unit -UnitRelativePath $successorRelativePath -SelectedUnitEntry $selectedUnitEntry -State $state -Events $events -Selection $existingValidationSelection -RepositoryMap $repoMap -Timestamp $Timestamp
                $terminalSelectionReleaseProofReference="receipts/$UnitId-terminal-validation-selection-release.json"
                $releaseTerminalValidationSelection=$true
                $terminalReleaseV2Failure=''
            }catch{$terminalReleaseV2Failure=$_.Exception.Message}
        }
        if (
            -not $releaseTerminalValidationSelection -and
            $Action -ceq 'Ready' -and
            $beforeStatus -ceq 'proposed' -and
            [string]$checkpoint.tier -ceq 'quick' -and
            [string]$existingValidationSelection.tier -ceq 'quick' -and
            -not [string]::IsNullOrWhiteSpace($checkpointReceipt) -and
            $checkpointReceipt -cmatch '^receipts/[a-z0-9][a-z0-9._-]{1,191}\.json$'
        ) {
            try {
                $terminalReceiptPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $checkpointReceipt
                $terminalReceipt = Read-MorphospaceProtocolJson -Path $terminalReceiptPath
                $terminalEvent = if ($events.Count -gt 0) { $events[-1] } else { $null }
                $terminalEventMatches = $null -ne $terminalEvent -and
                    [string]$terminalEvent.unit_id -ceq $selectedUnitId -and
                    [string]$terminalEvent.event_type -ceq 'blocker' -and
                    [string]$terminalEvent.event_id -cmatch "^$([regex]::Escape($selectedUnitId))-validation-$([regex]::Escape($checkpointResult))-[0-9]{4}$" -and
                    @($terminalEvent.receipts).Count -eq 1 -and
                    [string]@($terminalEvent.receipts)[0] -ceq $checkpointReceipt
                if ($terminalEventMatches -and [string]$state.last_event_id -ceq [string]$terminalEvent.event_id) {
                    $transactionId = "$([string]$terminalEvent.event_id)-transition"
                    $selectedUnitRelativePath = $selectedUnitEntry.path.Substring(($resolvedWorkspace.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar).Length).Replace('\', '/')
                    $terminalLedgerFailure = 'canonical-committed-transition'
                    $terminalLedger = Test-MorphospaceCommittedTransitionLedger `
                        -WorkspaceRoot $resolvedWorkspace `
                        -TransactionId $transactionId `
                        -ExpectedStatePath 'workspace.state.json' `
                        -ExpectedUnitPath $selectedUnitRelativePath `
                        -ExpectedEventsPath 'iteration-events.jsonl' `
                        -RequireTail
                    $terminalLedgerValid = $true
                    $terminalLedgerFailure = ''

                    $terminalReceiptFailure = 'selector-evidence-binding'
                    $selectorPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference ([string]$existingValidationSelection.selector_path)
                    $selector = Read-MorphospaceProtocolJson -Path $selectorPath
                    $expectedEvidenceLeaf = [string]$selector.selection.output_evidence.file_name
                    $terminalReceiptDirectory = Split-Path -Parent $terminalReceiptPath
                    $terminalEvidenceCandidates = @(@($terminalReceipt.artifacts) | ForEach-Object {
                        $artifactPath = if ([IO.Path]::IsPathRooted([string]$_.path)) {
                            [IO.Path]::GetFullPath([string]$_.path)
                        } else {
                            [IO.Path]::GetFullPath((Join-Path $terminalReceiptDirectory ([string]$_.path)))
                        }
                        if ([IO.Path]::GetFileName($artifactPath) -ceq $expectedEvidenceLeaf) { $artifactPath }
                    })
                    if ($terminalEvidenceCandidates.Count -ne 1) {
                        throw 'Terminal validation receipt does not identify exactly one selector evidence artifact.'
                    }
                    $terminalDeclaredMatrix = @(New-MorphospaceValidationMatrix -Unit $selectedUnitEntry.document)
                    $terminalSelectorResult = Resolve-MorphospaceNormalValidationSelector `
                        -WorkspaceRoot $resolvedWorkspace `
                        -SelectorReference ([string]$existingValidationSelection.selector_path) `
                        -ExpectedSelectorSha256 ([string]$existingValidationSelection.selector_sha256) `
                        -EvidencePath ([string]$terminalEvidenceCandidates[0]) `
                        -Spec $spec `
                        -Unit $selectedUnitEntry.document `
                        -DeclaredValidationMatrix $terminalDeclaredMatrix `
                        -Action RecordValidation `
                        -ValidationTier quick `
                        -BoundSelection $existingValidationSelection
                    $missingTerminalRepositoryMappings = @($selectedUnitEntry.document.allowed_repositories | Where-Object {
                        -not $repoMap.ContainsKey([string]$_.repo_id)
                    } | ForEach-Object { [string]$_.repo_id } | Sort-Object -Unique)
                    if ($missingTerminalRepositoryMappings.Count -ne 0) {
                        throw "Terminal selector release requires complete repository mappings: $($missingTerminalRepositoryMappings -join ', ')."
                    }
                    $terminalRepositoryStates = New-Object System.Collections.Generic.List[object]
                    foreach ($repo in @($selectedUnitEntry.document.allowed_repositories | Sort-Object repo_id)) {
                        $repoId = [string]$repo.repo_id
                        if ($repoMap.ContainsKey($repoId)) {
                            $terminalRepositoryStates.Add((Get-MorphospaceRepositoryState -RepoId $repoId -Path ([string]$repoMap[$repoId].path))) | Out-Null
                        }
                    }
                    $invalidTerminalRepositories = @($terminalRepositoryStates.ToArray() | Where-Object {
                        -not [bool]$_.available -or -not [bool]$_.is_git
                    } | ForEach-Object { [string]$_.repo_id })
                    if ($invalidTerminalRepositories.Count -ne 0) {
                        throw "Terminal selector release requires exact Git repository observations: $($invalidTerminalRepositories -join ', ')."
                    }
                    $dirtyTerminalRepositories = @($terminalRepositoryStates.ToArray() | Where-Object {
                        [bool]$_.dirty -or @($_.status_porcelain).Count -ne 0
                    } | ForEach-Object { [string]$_.repo_id })
                    if ($dirtyTerminalRepositories.Count -ne 0) {
                        throw "Terminal selector release requires exact clean Git repository observations: $($dirtyTerminalRepositories -join ', ')."
                    }
                    $terminalReceiptFailure = 'validation-receipt-contract'
                    $null = Test-MorphospaceValidationReceipt `
                        -WorkspaceRoot $resolvedWorkspace `
                        -ReceiptReference $checkpointReceipt `
                        -Spec $spec `
                        -Unit $selectedUnitEntry.document `
                        -RepositoryMap $repoMap `
                        -RepositoryStates @($terminalRepositoryStates.ToArray()) `
                        -ValidationMatrix @($terminalSelectorResult.validation_matrix) `
                        -ExpectedResult $checkpointResult `
                        -ExpectedTier ([string]$checkpoint.tier)
                    $terminalReceiptValid = $true
                    $terminalReceiptFailure = ''

                    $terminalEvidencePath = [string]$terminalEvidenceCandidates[0]
                    $terminalEvidenceArtifact = @($terminalReceipt.artifacts | Where-Object {
                        $candidateArtifactPath = if ([IO.Path]::IsPathRooted([string]$_.path)) {
                            [IO.Path]::GetFullPath([string]$_.path)
                        } else {
                            [IO.Path]::GetFullPath((Join-Path $terminalReceiptDirectory ([string]$_.path)))
                        }
                        $candidateArtifactPath -ceq $terminalEvidencePath
                    })
                    if ($terminalEvidenceArtifact.Count -ne 1) {
                        throw 'Terminal validation receipt evidence artifact binding is ambiguous.'
                    }
                    $terminalSelectionReleaseProofReference = "receipts/$UnitId-terminal-validation-selection-release.json"
                    $terminalEventDocument = (($terminalEvent | ConvertTo-Json -Depth 32 -Compress) | ConvertFrom-Json -DateKind String)
                    $terminalSelectionReleaseProof = [pscustomobject][ordered]@{
                        schema = 'rusty.morphospace.workflow.terminal_validation_selection_release.v1'
                        release_id = "$UnitId-terminal-validation-selection-release"
                        created_at = $Timestamp
                        project_id = [string]$state.project_id
                        successor = [pscustomobject][ordered]@{
                            unit_id = $UnitId
                            path = $unitEntry.path.Substring(($resolvedWorkspace.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar).Length).Replace('\', '/')
                            raw_sha256 = Get-MorphospaceFileSha256 $unitEntry.path
                            canonical_sha256 = Get-MorphospaceCanonicalJsonSha256 $unit
                        }
                        terminal = [pscustomobject][ordered]@{
                            unit_id = $selectedUnitId
                            path = $selectedUnitRelativePath
                            raw_sha256 = Get-MorphospaceFileSha256 $selectedUnitEntry.path
                            canonical_sha256 = Get-MorphospaceCanonicalJsonSha256 $selectedUnitEntry.document
                            contract_sha256 = $selectedUnitContractSha256
                            selector_binding_sha256 = Get-MorphospaceCanonicalJsonSha256 $existingValidationSelection
                            checkpoint = [pscustomobject][ordered]@{
                                tier = [string]$checkpoint.tier
                                result = $checkpointResult
                                receipt_path = $checkpointReceipt
                                receipt_sha256 = Get-MorphospaceFileSha256 $terminalReceiptPath
                            }
                            evidence = [pscustomobject][ordered]@{
                                artifact_id = [string]$terminalEvidenceArtifact[0].artifact_id
                                canonical_path_sha256 = [string]$existingValidationSelection.evidence_path_sha256
                                sha256 = Get-MorphospaceFileSha256 $terminalEvidencePath
                            }
                            blocker_sha256 = Get-MorphospaceCanonicalJsonSha256 $matchingTerminalBlockers[0]
                            event_id = [string]$terminalEvent.event_id
                            event_sha256 = Get-MorphospaceCanonicalJsonSha256 $terminalEventDocument
                            transaction = [pscustomobject][ordered]@{
                                transaction_id = $transactionId
                                intent_path = "receipts/transactions/$transactionId.intent.json"
                                intent_sha256 = Get-MorphospaceFileSha256 (Join-Path $resolvedWorkspace "receipts/transactions/$transactionId.intent.json")
                                completion_path = "receipts/transactions/$transactionId.completion.json"
                                completion_sha256 = Get-MorphospaceFileSha256 (Join-Path $resolvedWorkspace "receipts/transactions/$transactionId.completion.json")
                            }
                            repositories = @($terminalRepositoryStates.ToArray() | Sort-Object repo_id | ForEach-Object {
                                [pscustomobject][ordered]@{
                                    repo_id = [string]$_.repo_id
                                    available = [bool]$_.available
                                    is_git = [bool]$_.is_git
                                    dirty = [bool]$_.dirty
                                    dirty_fingerprint = Get-MorphospaceDirtyFingerprint -State $_
                                    head = if (($_.PSObject.Properties.Name -contains 'head') -and -not [string]::IsNullOrWhiteSpace([string]$_.head)) { [string]$_.head } else { $null }
                                    tree = if (($_.PSObject.Properties.Name -contains 'tree') -and -not [string]::IsNullOrWhiteSpace([string]$_.tree)) { [string]$_.tree } else { $null }
                                    branch = if (($_.PSObject.Properties.Name -contains 'branch') -and -not [string]::IsNullOrWhiteSpace([string]$_.branch)) { [string]$_.branch } else { $null }
                                }
                            })
                        }
                        does_not_authorize = @('The proof authorizes only release of the exact stale selector binding in this Ready transition; it authorizes no source, build, device, acceptance, or publication action.')
                    }
                    $terminalReleaseSchema = Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\terminal-validation-selection-release-v1.schema.json'
                    if (-not (Test-Json -Json ($terminalSelectionReleaseProof | ConvertTo-Json -Depth 32 -Compress) -SchemaFile $terminalReleaseSchema)) {
                        throw 'Terminal validation selection release proof does not satisfy its exact schema.'
                    }
                }
            } catch {
                if (-not $terminalLedgerValid) {
                    $terminalLedgerFailure = "$terminalLedgerFailure`:$($_.Exception.Message)"
                } else {
                    $terminalReceiptValid = $false
                    $terminalReceiptFailure = "$terminalReceiptFailure`:$($_.Exception.Message)"
                }
            }
        }
        if(-not$releaseTerminalValidationSelection){
        $terminalReleaseChecks = [ordered]@{
            action_ready = $Action -ceq 'Ready'
            target_proposed = $beforeStatus -ceq 'proposed'
            no_current_unit = -not $state.current_unit
            selected_unit_exists = $null -ne $selectedUnitEntry
            selected_unit_blocked = $null -ne $selectedUnitEntry -and [string]$selectedUnitEntry.document.status -ceq 'blocked'
            selected_unit_contract = [string]$existingValidationSelection.unit_contract_sha256 -ceq $selectedUnitContractSha256
            selection_tier = [string]$existingValidationSelection.tier -ceq 'quick' -and [string]$checkpoint.tier -ceq 'quick'
            checkpoint_result = $checkpointResult -in @('partial', 'fail', 'blocked')
            checkpoint_receipt = -not [string]::IsNullOrWhiteSpace($checkpointReceipt)
            blocker_unique = $terminalBlockersById.Count -eq 1
            blocker_exact = $matchingTerminalBlockers.Count -eq 1
            receipt_contract = $terminalReceiptValid
            terminal_ledger = $terminalLedgerValid
            release_proof = $null -ne $terminalSelectionReleaseProof
        }
        $failedTerminalReleaseChecks = @($terminalReleaseChecks.Keys | Where-Object { $terminalReleaseChecks[$_] -ne $true })
        $releaseTerminalValidationSelection = $failedTerminalReleaseChecks.Count -eq 0
        if (-not $releaseTerminalValidationSelection) {
            $terminalReleaseDetail = @($failedTerminalReleaseChecks | ForEach-Object {
                if ($_ -ceq 'terminal_ledger') { "terminal_ledger[$terminalLedgerFailure]" }
                elseif ($_ -ceq 'receipt_contract') { "receipt_contract[$terminalReceiptFailure]" }
                else { $_ }
            })
            throw "Workspace state carries a normal-validation selection for a different unit; terminal release proof failed: $($terminalReleaseDetail -join ', '); blocked-successor-v2[$terminalReleaseV2Failure]."
        }
        }
    }
    $validationMatrix = @(New-MorphospaceValidationMatrix -Unit $unit -DeviceSerials $DeviceSerials)
    $selectorResult = $null
    if ($ValidationSelector) {
        if (-not $ExpectedValidationSelectorSha256 -or -not $ValidationEvidencePath) {
            throw 'ValidationSelector requires ExpectedValidationSelectorSha256 and ValidationEvidencePath.'
        }
        $receiptConsumingSelectorAction = $Action -in @('ReturnToActive', 'RecordValidation', 'Accept')
        if ($receiptConsumingSelectorAction -and $null -eq $existingValidationSelection) {
            throw "$Action requires the exact normal-validation selection bound by an executed BeginValidation action."
        }
        $boundSelectionForResolution = if (
            $receiptConsumingSelectorAction -or
            ($Action -ceq 'BeginValidation' -and $beforeStatus -ceq 'validating' -and $null -ne $existingValidationSelection)
        ) { $existingValidationSelection } else { $null }
        $selectorResult = Resolve-MorphospaceNormalValidationSelector `
            -WorkspaceRoot $resolvedWorkspace `
            -SelectorReference $ValidationSelector `
            -ExpectedSelectorSha256 $ExpectedValidationSelectorSha256 `
            -EvidencePath $ValidationEvidencePath `
            -Spec $spec `
            -Unit $unit `
            -DeclaredValidationMatrix $validationMatrix `
            -Action $Action `
            -ValidationTier $ValidationTier `
            -BoundSelection $boundSelectionForResolution
        $mustMatchExistingSelection = $receiptConsumingSelectorAction -or (
            $Action -ceq 'BeginValidation' -and $beforeStatus -ceq 'validating' -and $null -ne $existingValidationSelection
        )
        if ($mustMatchExistingSelection) {
            $observedBinding = $selectorResult.state_binding
            if (
                [string]$existingValidationSelection.unit_id -cne [string]$observedBinding.unit_id -or
                [string]$existingValidationSelection.unit_raw_sha256 -cne [string]$observedBinding.unit_raw_sha256 -or
                [string]$existingValidationSelection.unit_contract_sha256 -cne [string]$observedBinding.unit_contract_sha256 -or
                [string]$existingValidationSelection.tier -cne [string]$observedBinding.tier -or
                [string]$existingValidationSelection.selector_id -cne [string]$observedBinding.selector_id -or
                [string]$existingValidationSelection.selector_path -cne [string]$observedBinding.selector_path -or
                [string]$existingValidationSelection.selector_sha256 -cne [string]$observedBinding.selector_sha256 -or
                [string]$existingValidationSelection.evidence_path_sha256 -cne [string]$observedBinding.evidence_path_sha256
            ) {
                throw "$Action normal-validation selection does not match the exact binding established by BeginValidation."
            }
        }
        $validationMatrix = @($selectorResult.validation_matrix)
    } elseif ($ExpectedValidationSelectorSha256 -or $ValidationEvidencePath) {
        throw 'ExpectedValidationSelectorSha256 and ValidationEvidencePath are invalid without ValidationSelector.'
    } elseif (
        $null -ne $existingValidationSelection -and
        ($Action -in @('BeginValidation', 'ReturnToActive', 'RecordValidation') -or ($Action -ceq 'Accept' -and $beforeStatus -cne 'accepted'))
    ) {
        throw "$Action requires the exact normal-validation selector and evidence path bound in workspace state."
    }
    $graphScope = New-MorphospaceGraphScope -Unit $unit
    $claimPreflight = New-MorphospaceClaimPreflight -Unit $unit -State $state -Spec $spec -RepositoryMap $repoMap -RepositoryStates $repoStatesArray -ValidationMatrix $validationMatrix -ValidationTier $ValidationTier -Action $Action
    $beforeCurrent = $state.current_unit
    $expectedPreStateSha256 = Get-MorphospaceCanonicalJsonSha256 $state
    $expectedPreUnitSha256 = Get-MorphospaceCanonicalJsonSha256 $unit
    $transition = "inspect-only"
    $event = $null
    $pushPlan = $null
    $adoptionReference = $null
    $publicationClosureReference = $null
    $publicationClosureBinding = $null
    $publishedPlanningAuthorityAdoptionBinding = $null
    $publicationAccountingBinding = $null
    $planningSuffixRewriteBinding = $null
    $publishedPrerequisiteSuffixBinding = $null
    $executedPreparedPublicationBinding = $null
    $skipAutomaticRepositoryProjection = $false
    $publicationOrderingInterruptionBinding = $null
    $instructionSurfaceCompletionBinding = $null
    $readyWithdrawalBinding = $null
    $proposedRetirementBinding = $null
    $inheritedCandidateEvidence = $null
    $transitionEventSnapshot = $null

    switch ($Action) {
        "Inspect" {
            $transition = "inspect-only"
        }
        "RetireProposed" {
            if (-not $ReplacementUnitId) { throw 'RetireProposed requires ReplacementUnitId.' }
            if (-not $OutPath) { throw 'RetireProposed requires OutPath for its transaction-owned receipt.' }
            $unitRelativePath = $unitEntry.path.Substring(($resolvedWorkspace.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar).Length).Replace('\', '/')
            $liveUnitRawSha256 = Get-MorphospaceFileSha256 $unitEntry.path
            $proposedRetirementBinding = Get-MorphospaceProposedRetirementBinding `
                -WorkspaceRoot $resolvedWorkspace `
                -UnitRelativePath $unitRelativePath `
                -UnitId $UnitId `
                -ReplacementUnitId $ReplacementUnitId `
                -Reason $RetirementReason `
                -ProjectId ([string]$spec.project_id) `
                -LiveState $state `
                -LiveUnit $unit `
                -Events $events `
                -UnitMap $unitMap `
                -ExpectedStateSha256 $expectedPreStateSha256 `
                -ExpectedUnitSha256 $expectedPreUnitSha256 `
                -ExpectedUnitRawSha256 $liveUnitRawSha256
            foreach ($expectation in @(
                [pscustomobject]@{ name = 'state'; supplied = $ExpectedStateSha256; actual = $expectedPreStateSha256 },
                [pscustomobject]@{ name = 'unit'; supplied = $ExpectedUnitSha256; actual = $expectedPreUnitSha256 },
                [pscustomobject]@{ name = 'unit raw'; supplied = $ExpectedUnitRawSha256; actual = $liveUnitRawSha256 },
                [pscustomobject]@{ name = 'events'; supplied = $ExpectedEventsSha256; actual = [string]$proposedRetirementBinding.authenticated_preimage.events_sha256 },
                [pscustomobject]@{ name = 'event tail'; supplied = $ExpectedEventTailId; actual = [string]$proposedRetirementBinding.authenticated_preimage.event_tail_id },
                [pscustomobject]@{ name = 'retirement binding'; supplied = $ExpectedProposedRetirementBindingSha256; actual = [string]$proposedRetirementBinding.binding_sha256 }
            )) {
                if ($expectation.supplied -and [string]$expectation.supplied -cne [string]$expectation.actual) {
                    throw "RetireProposed expected $([string]$expectation.name) identity does not match the live authenticated boundary."
                }
            }
            if ($ExpectedEventsLength -ge 0 -and $ExpectedEventsLength -ne [int64]$proposedRetirementBinding.authenticated_preimage.events_length) {
                throw 'RetireProposed expected event-ledger length does not match the live authenticated boundary.'
            }
            if ($Execute) {
                foreach ($required in @(
                    [pscustomobject]@{ name = 'ExpectedStateSha256'; value = $ExpectedStateSha256 },
                    [pscustomobject]@{ name = 'ExpectedUnitSha256'; value = $ExpectedUnitSha256 },
                    [pscustomobject]@{ name = 'ExpectedUnitRawSha256'; value = $ExpectedUnitRawSha256 },
                    [pscustomobject]@{ name = 'ExpectedEventsSha256'; value = $ExpectedEventsSha256 },
                    [pscustomobject]@{ name = 'ExpectedEventTailId'; value = $ExpectedEventTailId },
                    [pscustomobject]@{ name = 'ExpectedProposedRetirementBindingSha256'; value = $ExpectedProposedRetirementBindingSha256 }
                )) {
                    if (-not [string]$required.value) { throw "Executed RetireProposed requires $([string]$required.name) from its dry run." }
                }
                if ($ExpectedEventsLength -lt 0) { throw 'Executed RetireProposed requires ExpectedEventsLength from its dry run.' }
            }
            $transitionEventSnapshot = $proposedRetirementBinding.authenticated_preimage
            $transition = 'proposed-to-superseded-retired'
            if ($Execute) {
                $unit.status = 'superseded'
                $skipAutomaticRepositoryProjection = $true
                $event = New-MorphospaceEvent `
                    -State $state `
                    -Events $events `
                    -UnitId $UnitId `
                    -ActionSlug 'proposal-retired' `
                    -Timestamp $Timestamp `
                    -EventType 'state-transition' `
                    -Summary "Retired the exact admitted proposed unit because its contract is invalid; preserved its admission chain and recorded intended replacement identity '$ReplacementUnitId' for separate admission." `
                    -Receipts @($receiptReference)
            }
        }
        "Ready" {
            if ($beforeStatus -eq "ready") {
                $transition = "idempotent"
            } else {
                if ($beforeStatus -ne "proposed") { throw "Ready requires proposed status; '$UnitId' is '$beforeStatus'." }
                $withdrawalEvents = @($events | Where-Object {
                    [string]$_.unit_id -ceq $UnitId -and
                    [string]$_.event_id -cmatch "^$([regex]::Escape($UnitId))-ready-withdrawn-[0-9]{4}$"
                })
                if ($withdrawalEvents.Count -gt 0) {
                    throw "Ready refuses withdrawn unit identity '$UnitId'; revise the proposal under a new unit identity."
                }
                Test-MorphospacePrerequisites -Unit $unit -UnitMap $unitMap
                $readyInstructionCheck = @($claimPreflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
                if ($readyInstructionCheck.Count -ne 1 -or [string]$readyInstructionCheck[0].outcome -cne 'pass') {
                    throw "Ready preflight blocked: instruction action $(@($readyInstructionCheck[0].reason_codes) -join ' ')"
                }
                if ($state.current_unit) {
                    try {
                        [void](Get-MorphospaceSupersessionEventId -OldUnitId ([string]$state.current_unit) -ReplacementUnitId $UnitId)
                    } catch {
                        throw "Ready supersession-composability preflight failed: $($_.Exception.Message)"
                    }
                }
                $transition = "proposed-to-ready"
                if ($Execute) {
                    if ($releaseTerminalValidationSelection) {
                        $state.normal_validation_selection = $null
                    }
                    $unit.status = "ready"
                    $nextReady = @(Get-MorphospaceNextReadyUnit -UnitMap $unitMap)
                    $state.next_ready_unit = if ($nextReady.Count -gt 0) { [string]$nextReady[0] } else { $UnitId }
                    $readyReceipts = @()
                    if ($releaseTerminalValidationSelection) {
                        $readyReceipts = @($terminalSelectionReleaseProofReference)
                    }
                    $readySummary = if ($releaseTerminalValidationSelection) {
                        'Reviewed the bounded successor proposal, transactionally released one hash-bound terminal selector binding, and made the successor claimable without expanding its repositories, paths, or prerequisites.'
                    } else {
                        'Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites.'
                    }
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "ready" -Timestamp $Timestamp -EventType "state-transition" -Summary $readySummary -Receipts $readyReceipts
                }
            }
        }
        "WithdrawReady" {
            if ($Execute -and -not $OutPath) {
                throw 'Executed WithdrawReady requires OutPath for its transaction-owned receipt.'
            }
            $unitRelativePath = $unitEntry.path.Substring(($resolvedWorkspace.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar).Length).Replace('\', '/')
            $readyWithdrawalBinding = Get-MorphospaceReadyWithdrawalBinding `
                -WorkspaceRoot $resolvedWorkspace `
                -UnitRelativePath $unitRelativePath `
                -UnitId $UnitId `
                -ProjectId ([string]$spec.project_id) `
                -LiveState $state `
                -LiveUnit $unit `
                -Events $events `
                -UnitMap $unitMap `
                -ExpectedStateSha256 $expectedPreStateSha256 `
                -ExpectedUnitSha256 $expectedPreUnitSha256
            $transitionEventSnapshot = $readyWithdrawalBinding.authenticated_preimage
            $transition = 'ready-to-proposed-withdrawn'
            if ($Execute) {
                $unit.status = 'proposed'
                $state.next_ready_unit = $readyWithdrawalBinding.next_ready_unit_after
                $skipAutomaticRepositoryProjection = $true
                $event = New-MorphospaceEvent `
                    -State $state `
                    -Events $events `
                    -UnitId $UnitId `
                    -ActionSlug 'ready-withdrawn' `
                    -Timestamp $Timestamp `
                    -EventType 'state-transition' `
                    -Summary 'Withdrew the exact next-ready unit through its authenticated Ready transaction while preserving current authority and deterministic queue order.' `
                    -Receipts @($receiptReference)
            }
        }
        "Claim" {
            # An inherited candidate is historical evidence only.  Claim binds
            # every declared byte before changing ownership, but cannot make
            # those bytes product inputs or authorize validation/acceptance.
            $inheritedCandidateEvidence = Test-MorphospaceInheritedCandidateEvidenceBinding -WorkspaceRoot $resolvedWorkspace -Unit $unit
            if ($beforeStatus -eq "active" -and [string]$state.current_unit -eq $UnitId) {
                $transition = "idempotent"
            } else {
                if ($beforeStatus -ne "ready") { throw "Claim requires ready status; '$UnitId' is '$beforeStatus'." }
                if ($state.current_unit) { throw "Workspace already has current unit '$($state.current_unit)'." }
                Test-MorphospacePrerequisites -Unit $unit -UnitMap $unitMap
                $claimInstructionCheck = @($claimPreflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
                if ($claimInstructionCheck.Count -ne 1 -or [string]$claimInstructionCheck[0].outcome -cne 'pass') {
                    throw "Claim preflight blocked: instruction action $(@($claimInstructionCheck[0].reason_codes) -join ' ')"
                }
                if (-not $claimPreflight.ready_to_claim) {
                    throw "Claim preflight blocked: $(@($claimPreflight.issues) -join ' ')"
                }
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
                    $claimReceipts = @($adoptionReference | Where-Object { $_ })
                    if ($inheritedCandidateEvidence.declared) { $claimReceipts += [string]$inheritedCandidateEvidence.binding_path }
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "claimed" -Timestamp $Timestamp -EventType "state-transition" -Summary $summary -Receipts $claimReceipts
                }
            }
        }
        "CompleteInstructionSurfaces" {
            if ($beforeStatus -notin @("active", "validating") -or [string]$state.current_unit -ne $UnitId) {
                throw "CompleteInstructionSurfaces requires the matching in-flight unit."
            }
            if (-not $RepoMapPath) { throw "CompleteInstructionSurfaces requires RepoMapPath." }
            if (-not $InstructionCompletionId -or $InstructionCompletionId -cnotmatch '^[a-z0-9][a-z0-9-]{1,95}$') {
                throw "InstructionCompletionId must contain 2 through 96 lowercase alphanumeric/hyphen characters."
            }
            $completionPlan = Get-MorphospaceInstructionSurfaceCompletionPlan -Unit $unit -RepositoryMap $repoMap
            Assert-MorphospaceExactInstructionSurfaceIds -Surfaces $completionPlan.surfaces -RequestedIds $InstructionSurfaceIds -Required:$Execute
            if ($ExpectedUnitSha256 -and $ExpectedUnitSha256 -cne $expectedPreUnitSha256) {
                throw "ExpectedUnitSha256 does not match the current active unit."
            }
            if ($ExpectedInstructionObservationSha256 -and $ExpectedInstructionObservationSha256 -cne [string]$completionPlan.observation_sha256) {
                throw "ExpectedInstructionObservationSha256 does not match the stable instruction observation."
            }
            if ($Execute) {
                if (-not $OutPath) { throw "Executed CompleteInstructionSurfaces requires OutPath for its transaction-owned receipt." }
                if (-not $ExpectedUnitSha256) { throw "Executed CompleteInstructionSurfaces requires ExpectedUnitSha256 from the dry run." }
                if (-not $ExpectedInstructionObservationSha256) { throw "Executed CompleteInstructionSurfaces requires ExpectedInstructionObservationSha256 from the dry run." }
            }
            $instructionSurfaceCompletionBinding = [pscustomobject][ordered]@{
                completion_id = $InstructionCompletionId
                expected_unit_sha256 = $expectedPreUnitSha256
                resulting_unit_sha256 = [string]$completionPlan.resulting_unit_sha256
                observation_sha256 = [string]$completionPlan.observation_sha256
                all_planned_surfaces_completed = $true
                surface_files_observed_stable = $true
                validation_commands_executed = $false
                surfaces = @($completionPlan.surfaces)
            }
            $transition = "planned-instruction-surfaces-to-complete"
            if ($Execute) {
                $unit = $completionPlan.target_unit
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "instructions" -Timestamp $Timestamp -EventType "state-transition" -Summary "Completed the exact declared instruction-surface set after stable content observation without executing validation commands." -Receipts @($receiptReference)
                $event.event_id = "$InstructionCompletionId-recorded"
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
                if ($null -ne $selectorResult -and $null -eq $existingValidationSelection) {
                    $transition = 'validation-selector-bound'
                    if ($Execute) {
                        if ($state.PSObject.Properties.Name -contains 'normal_validation_selection') {
                            $state.normal_validation_selection = $selectorResult.state_binding
                        } else {
                            $state | Add-Member -NotePropertyName normal_validation_selection -NotePropertyValue $selectorResult.state_binding
                        }
                        $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug 'validation-selector-bound' -Timestamp $Timestamp -EventType 'validation' -Summary 'Bound an exact external Quick evidence selector to the already-validating frozen unit without executing its producer.'
                    }
                } else {
                    $transition = "idempotent"
                }
            } else {
                if ($beforeStatus -ne "active" -or [string]$state.current_unit -ne $UnitId) { throw "BeginValidation requires the matching active unit." }
                [void](Test-MorphospaceFrozenCandidate -WorkspaceRoot $resolvedWorkspace -Unit $unit)
                $requiredDeviceBlock = @($validationMatrix | Where-Object { $_.kind -eq "device" -and $_.disposition -eq "blocked-missing-serials" })
                if ($requiredDeviceBlock.Count -gt 0) { throw "Required device validation has no explicit serials." }
                $transition = "active-to-validating"
                if ($Execute) {
                    $unit.status = "validating"
                    if ($null -ne $selectorResult) {
                        if ($state.PSObject.Properties.Name -contains 'normal_validation_selection') {
                            $state.normal_validation_selection = $selectorResult.state_binding
                        } else {
                            $state | Add-Member -NotePropertyName normal_validation_selection -NotePropertyValue $selectorResult.state_binding
                        }
                    }
                    $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "validating" -Timestamp $Timestamp -EventType "state-transition" -Summary "Entered validation with a deterministic command, instruction, graph, and device-impact plan."
                }
            }
        }
        "ReturnToActive" {
            if ($beforeStatus -ne "validating" -or [string]$state.current_unit -ne $UnitId) {
                throw "ReturnToActive requires the matching validating unit."
            }
            $workMode = if ($unit.PSObject.Properties.Name -contains 'work_mode') { [string]$unit.work_mode } else { 'feature' }
            if ($workMode -ne 'feature') { throw "ReturnToActive is available only to feature units." }
            if ($ValidationResult -eq 'pass') { throw "ReturnToActive requires a non-passing ValidationResult." }
            if (-not $ValidationReceipt) { throw "ReturnToActive requires ValidationReceipt for the retained attempt." }
            if (($unit.PSObject.Properties.Name -contains 'tags') -and @($unit.tags | Where-Object { [string]$_ -eq 'receipt-security' }).Count -ne 0) {
                throw "Receipt-security units must record validation through the pinned authority path."
            }
            $null = Test-MorphospaceValidationReceipt `
                -WorkspaceRoot $resolvedWorkspace `
                -ReceiptReference $ValidationReceipt `
                -Spec $spec `
                -Unit $unit `
                -RepositoryMap $repoMap `
                -RepositoryStates $repoStatesArray `
                -ValidationMatrix $validationMatrix `
                -ExpectedResult $ValidationResult `
                -ExpectedTier $ValidationTier
            $validatedReceiptPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $ValidationReceipt
            $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
            $ValidationReceipt = $validatedReceiptPath.Substring($workspacePrefix.Length).Replace("\", "/")
            $transition = "validation-$ValidationResult-to-active"
            if ($Execute) {
                $state.validation_checkpoint = [pscustomobject][ordered]@{
                    tier = $ValidationTier
                    receipt = $ValidationReceipt
                    result = $ValidationResult
                }
                $unit.status = 'active'
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "validation-$ValidationResult-return" -Timestamp $Timestamp -EventType "validation" -Summary "Retained a non-passing validation attempt and returned the same feature unit to active for an in-scope correction." -Receipts @($ValidationReceipt)
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
                    if ($state.PSObject.Properties.Name -contains 'normal_validation_selection') {
                        $state.normal_validation_selection = $null
                    }
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
                    if ($state.PSObject.Properties.Name -contains 'normal_validation_selection') {
                        $state.normal_validation_selection = $null
                    }
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
        "AdoptPublishedPlanningAuthority" {
            if (-not $PublishedPlanningAuthorityAdoption) { throw "AdoptPublishedPlanningAuthority requires PublishedPlanningAuthorityAdoption." }
            if (-not $RepoMapPath) { throw "AdoptPublishedPlanningAuthority requires RepoMapPath." }
            $adoptionPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $PublishedPlanningAuthorityAdoption
            $validatedAdoptionDocument = Test-MorphospacePublishedPlanningAuthorityAdoptionDocument -Path $adoptionPath -WorkspaceRoot $resolvedWorkspace
            $adoptionDocument = $validatedAdoptionDocument.document
            $activeAdoption = [string]$adoptionDocument.schema -ceq "rusty.morphospace.workflow.published_planning_authority_adoption.v2"
            if ($activeAdoption) {
                if ($beforeStatus -notin @("active", "validating") -or [string]$state.current_unit -cne $UnitId -or
                    $null -ne $state.next_ready_unit -or $null -ne $state.pending_push_bundle) {
                    throw "Active published planning authority adoption requires the matching active or validating unit and null next-ready and pending-bundle state."
                }
            } elseif ($beforeStatus -ne "accepted" -or $null -ne $state.current_unit -or
                $null -ne $state.next_ready_unit -or $null -ne $state.pending_push_bundle) {
                throw "Inactive published planning authority adoption requires the accepted triggering unit and null current, next-ready, and pending-bundle state."
            }
            if ([string]$validatedAdoptionDocument.projection.unit_id -cne $UnitId) {
                throw "Published planning authority adoption projection unit does not match the requested unit."
            }
            if ([string]$adoptionDocument.project_id -cne [string]$state.project_id) {
                throw "Published planning authority adoption project does not match the workspace."
            }
            $sourceRepositoryId = [string]$adoptionDocument.source_publication.repo_id
            $planningRepositoryId = [string]$adoptionDocument.planning_repository.repo_id
            $unitRepositoryIds = @($unit.allowed_repositories | ForEach-Object { [string]$_.repo_id })
            if ($unitRepositoryIds -cnotcontains $sourceRepositoryId) {
                throw "Published planning authority adoption source repository is outside the triggering unit."
            }
            if (-not $repoMap.ContainsKey($sourceRepositoryId) -or -not $repoMap.ContainsKey($planningRepositoryId)) {
                throw "Published planning authority adoption source or planning repository is not mapped."
            }
            if ([string]$planningEntry.repo_id -cne $planningRepositoryId) {
                throw "Published planning authority adoption planning repository does not match the external planning owner."
            }
            $validatedAdoption = Test-MorphospacePublishedPlanningAuthorityAdoptionLive `
                -Path $adoptionPath `
                -WorkspaceRoot $resolvedWorkspace `
                -SourceRepository ([string]$repoMap[$sourceRepositoryId].path) `
                -PlanningRepository ([string]$repoMap[$planningRepositoryId].path)
            $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
            $adoptionReference = $adoptionPath.Substring($workspacePrefix.Length).Replace("\", "/")
            $publishedPlanningAuthorityAdoptionBinding = [pscustomobject][ordered]@{
                adoption_id = [string]$adoptionDocument.adoption_id
                path = $adoptionReference
                sha256 = [string]$validatedAdoption.adoption_sha256
            }
            $transition = "published-planning-authority-adopted"
            if ($Execute) {
                $state = $validatedAdoptionDocument.workspace_state_after
                $actionSlug = if ($activeAdoption) { "active-planning-authority-adopted" } else { "planning-authority-adopted" }
                $summary = if ($activeAdoption) {
                    "Adopted the exact published embedded active workspace as external planning authority while preserving the active unit and every source projection; no Git, validation, acceptance, or dirty-state mutation was performed."
                } else {
                    "Adopted the exact published embedded workspace as external planning authority by clearing only the bound source dirty marker and synchronizing only its stale repository-head projection; no Git, validation, or acceptance mutation was performed."
                }
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug $actionSlug -Timestamp $Timestamp -EventType "state-transition" -Summary $summary -Receipts @($adoptionReference)
                if ([string]$event.event_id -cne [string]$adoptionDocument.state_delta.last_event_id_after) {
                    throw "Published planning authority adoption expected-after state does not bind the deterministic transition event."
                }
                $skipAutomaticRepositoryProjection = $true
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
        "ReconcileExecutedPreparedPublication" {
            if (-not $ExecutedPreparedPublicationReconciliation) { throw "ReconcileExecutedPreparedPublication requires ExecutedPreparedPublicationReconciliation." }
            if (-not $RepoMapPath) { throw "ReconcileExecutedPreparedPublication requires RepoMapPath." }
            if ($beforeStatus -ne "accepted") { throw "ReconcileExecutedPreparedPublication requires the triggering unit to remain accepted." }
            $reconciliationPath = Resolve-MorphospaceReceiptPath -WorkspaceRoot $resolvedWorkspace -ReceiptReference $ExecutedPreparedPublicationReconciliation
            $validatedReconciliation = Test-MorphospaceExecutedPreparedPublicationLive -Path $reconciliationPath -WorkspaceRoot $resolvedWorkspace -Spec $spec -State $state -RepositoryMap $repoMap -RepositoryStates $repoStatesArray
            if ([string]$validatedReconciliation.document.trigger_unit_id -cne $UnitId) { throw "Executed prepared-publication reconciliation trigger unit does not match the requested unit." }
            $workspacePrefix = $resolvedWorkspace.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
            $reconciliationReference = $reconciliationPath.Substring($workspacePrefix.Length).Replace("\", "/")
            $executedPreparedPublicationBinding = [pscustomobject][ordered]@{
                reconciliation_id = [string]$validatedReconciliation.document.reconciliation_id
                path = $reconciliationReference
                sha256 = [string]$validatedReconciliation.reconciliation_sha256
                executed_push_receipt = [pscustomobject][ordered]@{
                    path = [string]$validatedReconciliation.document.executed_push_receipt.path
                    sha256 = [string]$validatedReconciliation.document.executed_push_receipt.sha256
                }
            }
            $transition = "executed-prepared-publication-reconciled"
            if ($Execute) {
                $state.pending_push_bundle = $null
                $event = New-MorphospaceEvent -State $state -Events $events -UnitId $UnitId -ActionSlug "executed-prepared-publication-reconciled" -Timestamp $Timestamp -EventType "push" -Summary "Reconciled exact immutable evidence for an already executed prepared publication whose chronology and merge integration remain explicitly non-ordinary; no Git, validation, acceptance, device, or release mutation was performed." -Receipts @($reconciliationReference, [string]$validatedReconciliation.document.executed_push_receipt.path, [string]$validatedReconciliation.document.prepared_plan.container.path)
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
                $publicationOrderingInterruptionBinding = [pscustomobject][ordered]@{ path = $interruptionPath.Substring($workspacePrefix.Length).Replace("\", "/"); sha256 = Get-MorphospaceFileSha256 $interruptionPath; kind = [string]$interruption.kind; early_planning_checkpoint_preserved = $true; source_publication_claimed = $false }
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

    $newAutomationResult = {
        [pscustomobject][ordered]@{
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
            claim_preflight = $claimPreflight
            adoption_receipt = $adoptionReference
            publication_closure = $publicationClosureBinding
            published_planning_authority_adoption = $publishedPlanningAuthorityAdoptionBinding
            planned_publication = $publicationAccountingBinding
            planning_suffix_rewrite_recovery = $planningSuffixRewriteBinding
            published_prerequisite_suffix_reconciliation = $publishedPrerequisiteSuffixBinding
            executed_prepared_publication_reconciliation = $executedPreparedPublicationBinding
            instruction_surface_completion = $instructionSurfaceCompletionBinding
            ready_withdrawal = $readyWithdrawalBinding
            proposed_retirement = $proposedRetirementBinding
            terminal_validation_selection_release = if ($null -ne $terminalSelectionReleaseProof) {
                [pscustomobject][ordered]@{
                    path = $terminalSelectionReleaseProofReference
                    sha256 = Get-MorphospaceSha256Bytes -Bytes (ConvertTo-MorphospaceProtocolJsonBytes -Value $terminalSelectionReleaseProof)
                    terminal_unit_id = [string]$terminalSelectionReleaseProof.terminal.binding.unit_id
                }
            } else { $null }
            push_plan = $pushPlan
            event_id = if ($event) { [string]$event.event_id } else { $null }
        }
    }
    $result = $null
    $transitionArtifacts = @()
    $transitionOwnsOutPath = $false
    if ($Execute -and $event) {
        $state.last_event_id = [string]$event.event_id
        if (-not $skipAutomaticRepositoryProjection) {
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
        }
        if ($Action -in @("PreparePush", "CompleteInstructionSurfaces", "WithdrawReady", "RetireProposed")) {
            $result = & $newAutomationResult
            $receiptBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
                (($result | ConvertTo-Json -Depth 32) + [Environment]::NewLine)
            )
            $transitionArtifacts = @([pscustomobject][ordered]@{
                bytes_base64 = [Convert]::ToBase64String($receiptBytes)
                path = $receiptReference
                sha256 = Get-MorphospaceSha256Bytes -Bytes $receiptBytes
            })
            $transitionOwnsOutPath = $true
        }
        if ($Action -ceq 'Ready' -and $releaseTerminalValidationSelection) {
            $releaseBytes = ConvertTo-MorphospaceProtocolJsonBytes -Value $terminalSelectionReleaseProof
            $transitionArtifacts = @([pscustomobject][ordered]@{
                bytes_base64 = [Convert]::ToBase64String($releaseBytes)
                path = $terminalSelectionReleaseProofReference
                sha256 = Get-MorphospaceSha256Bytes -Bytes $releaseBytes
            })
        }
        $transactionId = "$([string]$event.event_id)-transition"
        $unitRelativePath = $unitEntry.path.Substring(($resolvedWorkspace.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar).Length).Replace('\', '/')
        $transitionArguments = @{
            WorkspaceRoot = $resolvedWorkspace
            TransactionId = $transactionId
            StatePath = 'workspace.state.json'
            UnitPath = $unitRelativePath
            EventsPath = 'iteration-events.jsonl'
            TargetState = $state
            TargetUnit = $unit
            Event = $event
            ExpectedPreStateSha256 = $expectedPreStateSha256
            ExpectedPreUnitSha256 = $expectedPreUnitSha256
            Artifacts = $transitionArtifacts
            FaultAfter = $TransitionFaultAfter
        }
        if ($Action -eq 'WithdrawReady') {
            $transitionArguments.ExpectedEventTailId = $transitionEventSnapshot.event_tail_id
            $transitionArguments.ExpectedEventsSha256 = [string]$transitionEventSnapshot.events_sha256
            $transitionArguments.ExpectedEventsLength = [int64]$transitionEventSnapshot.events_length
        }
        if ($Action -eq 'RetireProposed') {
            $transitionArguments.ExpectedPreUnitRawSha256 = [string]$transitionEventSnapshot.unit_raw_sha256
            $transitionArguments.ExpectedEventTailId = [string]$transitionEventSnapshot.event_tail_id
            $transitionArguments.ExpectedEventsSha256 = [string]$transitionEventSnapshot.events_sha256
            $transitionArguments.ExpectedEventsLength = [int64]$transitionEventSnapshot.events_length
        }
        Start-MorphospaceTransitionLedger @transitionArguments | Out-Null
    }

    if ($null -eq $result) { $result = & $newAutomationResult }
    if ($Execute -and $OutPath -and -not $transitionOwnsOutPath) { Write-MorphospaceJson -Path $OutPath -Value $result }
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceWorkUnitAutomation, Get-MorphospaceRepositoryState, New-MorphospaceInflightAdoptionReceipt
