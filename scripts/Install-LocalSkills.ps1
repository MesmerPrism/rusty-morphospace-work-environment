param(
    [string]$RepoRoot = "",
    [string]$MetaQuestWorkflowRepoRoot = "",
    [string]$TargetRoot = "",
    [ValidateSet("Plan", "Install", "Verify", "Update", "PruneUnmanaged")][string]$Action = "Plan",
    [string[]]$SkillId = @(),
    [string]$BackupRoot = "",
    [string]$ExpectedUnmanagedFingerprint = "",
    [switch]$Execute,
    [switch]$AllowDirtySource,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows
)
$pathStringComparison = if ($isWindowsHost) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$pathStringComparer = if ($isWindowsHost) {
    [System.StringComparer]::OrdinalIgnoreCase
} else {
    [System.StringComparer]::Ordinal
}

# Preserve the original script's `-Execute` install shape while making every
# overwrite an explicit Update action.
if ($Execute -and -not $PSBoundParameters.ContainsKey("Action")) {
    $Action = "Install"
}

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$SourceRoot = Join-Path $RepoRoot "skills"

if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "Skill source root not found: $SourceRoot"
}
if ($MetaQuestWorkflowRepoRoot) {
    $MetaQuestWorkflowRepoRoot = (Resolve-Path -LiteralPath $MetaQuestWorkflowRepoRoot).Path
}

if (-not $TargetRoot) {
    if ($env:CODEX_HOME) {
        $TargetRoot = Join-Path $env:CODEX_HOME "skills"
    } elseif ($env:USERPROFILE) {
        $TargetRoot = Join-Path $env:USERPROFILE ".codex\skills"
    } else {
        $TargetRoot = Join-Path $HOME ".codex/skills"
    }
}
$TargetRoot = [System.IO.Path]::GetFullPath($TargetRoot)

if (-not $BackupRoot) {
    $BackupRoot = $TargetRoot.TrimEnd('\', '/') + "-backups"
}
$BackupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
$targetRootPrefix = $TargetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$backupRootPrefix = $BackupRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if ($BackupRoot.Equals($TargetRoot, $pathStringComparison) -or
    $BackupRoot.StartsWith($targetRootPrefix, $pathStringComparison) -or
    $TargetRoot.StartsWith($backupRootPrefix, $pathStringComparison)) {
    throw "BackupRoot and TargetRoot must not overlap."
}

function Get-RelativeFilePath {
    param([string]$BasePath, [string]$FilePath)

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/') + $separator
    $file = [System.IO.Path]::GetFullPath($FilePath)
    $baseUri = New-Object System.Uri($base)
    $fileUri = New-Object System.Uri($file)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fileUri).ToString()).Replace('/', $separator)
}

function Get-StringSha256 {
    param([string]$Text)

    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

function Get-SkillSourceFiles {
    param(
        [string]$SkillRoot,
        [string]$RepositoryRoot
    )

    $relativeSkillRoot = (Get-RelativeFilePath -BasePath $RepositoryRoot -FilePath $SkillRoot).Replace('\', '/')
    if ($relativeSkillRoot -eq ".." -or $relativeSkillRoot.StartsWith("../", [System.StringComparison]::Ordinal)) {
        throw "Skill source root is outside its repository: $SkillRoot"
    }
    $git = @(Get-Command git -ErrorAction Stop | Select-Object -First 1)[0].Source
    $repositoryPaths = @(
        & $git -C $RepositoryRoot ls-files --cached --others --exclude-standard -- $relativeSkillRoot |
            Sort-Object -CaseSensitive
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to enumerate skill source files from Git: $SkillRoot"
    }
    return @(
        $repositoryPaths |
            ForEach-Object {
                $sourcePath = Join-Path $RepositoryRoot $_
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    throw "Tracked skill source file is missing: $_"
                }
                [pscustomobject]@{
                    path = Get-RelativeFilePath -BasePath $SkillRoot -FilePath $sourcePath
                    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
                    source_path = $sourcePath
                }
            }
    )
}

function Get-SkillSourceFingerprint {
    param([object[]]$SourceFiles)

    $inputText = (($SourceFiles | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n") + "`n"
    return Get-StringSha256 -Text $inputText
}

function Get-GeneratedLocalMetadataPaths {
    param([string]$SkillName)

    $paths = @(
        ".morphospace-skill-source.json",
        "references/local-work-environment.json"
    )
    if ($SkillName -eq "meta-quest-workflow") {
        $paths += "references/local-meta-quest-playbooks.json"
    }
    return $paths
}

function Assert-RequiredSkillSourceFiles {
    param(
        [string]$SkillName,
        [object[]]$SourceFiles
    )

    $sourcePaths = @($SourceFiles | ForEach-Object { ([string]$_.path).Replace('\', '/') })
    $requiredPaths = @("SKILL.md")
    if ($SkillName -eq "meta-quest-workflow") {
        $requiredPaths += @(
            "agents/openai.yaml",
            "scripts/Resolve-PlaybookSource.ps1"
        )
    }
    foreach ($requiredPath in $requiredPaths) {
        if ($sourcePaths -cnotcontains $requiredPath) {
            throw "Git-owned skill source inventory is missing required path: $SkillName/$requiredPath"
        }
    }
    foreach ($generatedPath in @(Get-GeneratedLocalMetadataPaths -SkillName $SkillName)) {
        if ($sourcePaths -ccontains $generatedPath) {
            throw "Git-owned skill source inventory contains generated local metadata: $SkillName/$generatedPath"
        }
    }
}

function Get-SkillFileInventory {
    param([string]$Target)

    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        return @()
    }

    $targetFull = [System.IO.Path]::GetFullPath($Target)
    $targetPrefix = $targetFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $targetItem = Get-Item -LiteralPath $targetFull -Force
    if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Skill inventory rejects a reparse-point target: $targetFull"
    }
    $items = @(Get-ChildItem -LiteralPath $Target -Recurse -Force)
    foreach ($item in $items) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Skill inventory rejects reparse points: $($item.FullName)"
        }
    }
    return @(
        $items |
            Where-Object { -not $_.PSIsContainer } |
            ForEach-Object {
                $fullPath = [System.IO.Path]::GetFullPath($_.FullName)
                if (-not $fullPath.StartsWith($targetPrefix, $pathStringComparison)) {
                    throw "Skill file escaped its target root: $fullPath"
                }
                [pscustomobject]@{
                    path = (Get-RelativeFilePath -BasePath $Target -FilePath $fullPath).Replace('\', '/')
                    full_path = $fullPath
                    bytes = [int64]$_.Length
                    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToLowerInvariant()
                }
            } |
            Sort-Object path -CaseSensitive
    )
}

function Get-UnmanagedSkillFiles {
    param(
        [string]$SkillName,
        [object[]]$Inventory,
        [object[]]$SourceFiles
    )

    $managedPaths = New-Object "System.Collections.Generic.HashSet[string]" ($pathStringComparer)
    foreach ($file in $SourceFiles) {
        [void]$managedPaths.Add(([string]$file.path).Replace('\', '/'))
    }
    foreach ($generatedPath in @(Get-GeneratedLocalMetadataPaths -SkillName $SkillName)) {
        [void]$managedPaths.Add($generatedPath)
    }
    return @($Inventory | Where-Object { -not $managedPaths.Contains($_.path) })
}

function Get-InventoryFingerprint {
    param([object[]]$Files)

    $inputText = if ($Files.Count -eq 0) {
        ""
    } else {
        (($Files | ForEach-Object { "$($_.path):$($_.bytes):$($_.sha256)" }) -join "`n") + "`n"
    }
    return Get-StringSha256 -Text $inputText
}

function Compare-FileInventory {
    param(
        [object[]]$Expected,
        [object[]]$Actual,
        [string]$Label
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "$Label inventory count changed."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Expected[$index].path -cne $Actual[$index].path -or
            [int64]$Expected[$index].bytes -ne [int64]$Actual[$index].bytes -or
            $Expected[$index].sha256 -ne $Actual[$index].sha256) {
            throw "$Label inventory changed at $($Expected[$index].path)."
        }
    }
}

function Add-UnmanagedDetail {
    param(
        [string]$Detail,
        [object[]]$UnmanagedFiles
    )

    if ($UnmanagedFiles.Count -eq 0) {
        return $Detail
    }
    return "$Detail Unmanaged files are present ($($UnmanagedFiles.Count)): $(@($UnmanagedFiles.path) -join ', ')."
}

function Get-SourceRepositoryInfo {
    param([string]$RepositoryRoot)

    $git = @(Get-Command git -ErrorAction Stop | Select-Object -First 1)[0].Source
    $root = [System.IO.Path]::GetFullPath((
        ([string](& $git -C $RepositoryRoot rev-parse --show-toplevel)).Trim()
    ))
    $commit = ([string](& $git -C $RepositoryRoot rev-parse HEAD)).Trim()
    $tree = ([string](& $git -C $RepositoryRoot rev-parse 'HEAD^{tree}')).Trim()
    $remote = ([string](& $git -C $RepositoryRoot remote get-url origin 2>$null)).Trim()
    $dirtyLines = @(& $git -C $RepositoryRoot status --porcelain --untracked-files=normal | Sort-Object -CaseSensitive)
    $statusText = if ($dirtyLines.Count -eq 0) { "" } else { ($dirtyLines -join "`n") + "`n" }
    $statusFingerprint = Get-StringSha256 -Text $statusText
    $manifestRoot = Join-Path $RepositoryRoot "manifests"
    $release = if (Test-Path -LiteralPath $manifestRoot -PathType Container) {
        @(
            Get-ChildItem -LiteralPath $manifestRoot -Filter "release-*.json" -File |
            ForEach-Object {
                try {
                    $document = Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
                    [pscustomobject]@{ Version = [version]$document.version; Text = [string]$document.version }
                } catch {
                    $null
                }
            } |
            Where-Object { $null -ne $_ } |
            Sort-Object Version -Descending |
            Select-Object -First 1
        )
    } else {
        @()
    }

    return [pscustomobject]@{
        root = $root
        commit = $commit
        tree = $tree
        remote = $remote
        dirty = ($dirtyLines.Count -gt 0)
        status_fingerprint = $statusFingerprint
        release = if ($release.Count -gt 0) { $release[0].Text } else { $null }
    }
}

function Assert-RepositorySnapshotCurrent {
    param(
        [string]$RepositoryRoot,
        [object]$ExpectedRepositoryInfo,
        [switch]$RequireClean
    )

    $freshRepositoryInfo = Get-SourceRepositoryInfo -RepositoryRoot $RepositoryRoot
    if (($RequireClean -and $freshRepositoryInfo.dirty) -or
        -not $freshRepositoryInfo.root.Equals($ExpectedRepositoryInfo.root, $pathStringComparison) -or
        $freshRepositoryInfo.commit -ne $ExpectedRepositoryInfo.commit -or
        $freshRepositoryInfo.tree -ne $ExpectedRepositoryInfo.tree -or
        $freshRepositoryInfo.remote -ne $ExpectedRepositoryInfo.remote -or
        [bool]$freshRepositoryInfo.dirty -ne [bool]$ExpectedRepositoryInfo.dirty -or
        $freshRepositoryInfo.status_fingerprint -ne $ExpectedRepositoryInfo.status_fingerprint -or
        [string]$freshRepositoryInfo.release -ne [string]$ExpectedRepositoryInfo.release) {
        throw "Skill source repository changed after inspection."
    }
}

function Assert-SourceSnapshotCurrent {
    param(
        [string]$RepositoryRoot,
        [string]$SkillRoot,
        [object]$ExpectedRepositoryInfo,
        [string]$ExpectedSourceFingerprint,
        [switch]$RequireClean
    )

    Assert-RepositorySnapshotCurrent `
        -RepositoryRoot $RepositoryRoot `
        -ExpectedRepositoryInfo $ExpectedRepositoryInfo `
        -RequireClean:$RequireClean
    $freshSourceFiles = @(Get-SkillSourceFiles -SkillRoot $SkillRoot -RepositoryRoot $RepositoryRoot)
    $freshSourceFingerprint = Get-SkillSourceFingerprint -SourceFiles $freshSourceFiles
    if ($freshSourceFingerprint -ne $ExpectedSourceFingerprint) {
        throw "Skill source files changed after inspection."
    }
}

function Write-JsonUtf8NoBom {
    param([string]$Path, [object]$Value)

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 12
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Test-TargetSkill {
    param(
        [string]$SkillName,
        [string]$Target,
        [object[]]$SourceFiles,
        [object]$SourceRepositoryInfo,
        [object]$WorkEnvironmentRepositoryInfo
    )

    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        return [pscustomobject]@{
            status = "absent"
            detail = "Target directory does not exist."
            inventory = @()
            unmanaged_files = @()
            unmanaged_fingerprint = Get-InventoryFingerprint -Files @()
        }
    }

    $inventory = @(Get-SkillFileInventory -Target $Target)
    $unmanagedFiles = @(
        Get-UnmanagedSkillFiles -SkillName $SkillName -Inventory $inventory -SourceFiles $SourceFiles
    )
    $unmanagedFingerprint = Get-InventoryFingerprint -Files $unmanagedFiles
    $differences = New-Object System.Collections.Generic.List[string]
    foreach ($file in $SourceFiles) {
        $targetFile = Join-Path $Target $file.path
        if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
            $differences.Add("missing:$($file.path)")
            continue
        }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetFile).Hash.ToLowerInvariant()
        if ($actual -ne $file.sha256) {
            $differences.Add("hash:$($file.path)")
        }
    }

    $metadataPath = Join-Path $Target ".morphospace-skill-source.json"
    $locatorPath = Join-Path $Target "references\local-work-environment.json"
    $playbookLocatorPath = Join-Path $Target "references\local-meta-quest-playbooks.json"
    $managed = (Test-Path -LiteralPath $metadataPath -PathType Leaf) -and
        (Test-Path -LiteralPath $locatorPath -PathType Leaf) -and
        ($SkillName -ne "meta-quest-workflow" -or
            (Test-Path -LiteralPath $playbookLocatorPath -PathType Leaf))

    if ($managed) {
        try {
            $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
            $locator = Get-Content -Raw -LiteralPath $locatorPath | ConvertFrom-Json
            $playbookLocator = if ($SkillName -eq "meta-quest-workflow") {
                Get-Content -Raw -LiteralPath $playbookLocatorPath | ConvertFrom-Json
            } else {
                $null
            }
            $expectedFingerprint = Get-SkillSourceFingerprint -SourceFiles $SourceFiles
            if ($metadata.schema -ne "rusty.morphospace.local_skill_source.v1" -or
                $metadata.skill_id -ne $SkillName -or
                $metadata.source_repository -ne $SourceRepositoryInfo.remote) { $differences.Add("provenance:identity") }
            if ($metadata.source_commit -ne $SourceRepositoryInfo.commit -or
                [bool]$metadata.source_worktree_dirty -ne [bool]$SourceRepositoryInfo.dirty) { $differences.Add("provenance:source-state") }
            if ([string]$metadata.source_release -ne [string]$SourceRepositoryInfo.release -or
                $metadata.source_tree_sha256 -ne $expectedFingerprint) { $differences.Add("provenance:source-version") }
            if (-not ([string]$metadata.work_environment_root).Equals($RepoRoot, $pathStringComparison)) { $differences.Add("provenance:work-environment-root") }
            if ($locator.schema -ne "rusty.morphospace.local_work_environment.v1" -or
                $locator.source_repository -ne $WorkEnvironmentRepositoryInfo.remote -or
                $locator.source_commit -ne $WorkEnvironmentRepositoryInfo.commit) { $differences.Add("locator:identity") }
            if ([string]$locator.source_release -ne [string]$WorkEnvironmentRepositoryInfo.release -or
                [bool]$locator.source_worktree_dirty -ne [bool]$WorkEnvironmentRepositoryInfo.dirty) { $differences.Add("locator:source-state") }
            if (-not ([string]$locator.work_environment_root).Equals($RepoRoot, $pathStringComparison)) { $differences.Add("locator:work-environment-root") }
            if (-not ([string]$locator.docs_root).Equals((Join-Path $RepoRoot "docs"), $pathStringComparison)) { $differences.Add("locator:docs-root") }
            if ($SkillName -eq "meta-quest-workflow") {
                if ($playbookLocator.schema -ne "rusty.quest.workflow.local_playbook_source.v1" -or
                    $playbookLocator.skill_id -ne $SkillName -or
                    $playbookLocator.source_repository -ne $SourceRepositoryInfo.remote -or
                    $playbookLocator.source_commit -ne $SourceRepositoryInfo.commit -or
                    $playbookLocator.source_tree -ne $SourceRepositoryInfo.tree) { $differences.Add("playbook-locator:identity") }
                if ([bool]$playbookLocator.source_worktree_dirty -ne [bool]$SourceRepositoryInfo.dirty -or
                    $playbookLocator.source_status_fingerprint -ne $SourceRepositoryInfo.status_fingerprint) { $differences.Add("playbook-locator:source-state") }
                if (-not ([string]$playbookLocator.repository_root).Equals($SourceRepositoryInfo.root, $pathStringComparison)) { $differences.Add("playbook-locator:repository-root") }
                if (-not ([string]$playbookLocator.readme_path).Equals((Join-Path $SourceRepositoryInfo.root "README.md"), $pathStringComparison)) { $differences.Add("playbook-locator:readme") }
                if (-not ([string]$playbookLocator.docs_root).Equals((Join-Path $SourceRepositoryInfo.root "docs"), $pathStringComparison)) { $differences.Add("playbook-locator:docs-root") }
                if (-not ([string]$playbookLocator.playbook_index_path).Equals((Join-Path $SourceRepositoryInfo.root "docs\playbook-index.md"), $pathStringComparison)) { $differences.Add("playbook-locator:playbook-index") }
            }
        } catch {
            $differences.Add("provenance:invalid-json")
        }
    }

    if ($differences.Count -eq 0 -and $managed) {
        return [pscustomobject]@{
            status = "current"
            detail = Add-UnmanagedDetail -Detail "Managed source files and local locator are present." -UnmanagedFiles $unmanagedFiles
            inventory = $inventory
            unmanaged_files = $unmanagedFiles
            unmanaged_fingerprint = $unmanagedFingerprint
        }
    }
    if ($differences.Count -eq 0) {
        return [pscustomobject]@{
            status = "unmanaged-identical"
            detail = Add-UnmanagedDetail -Detail "Source files match, but provenance metadata or the local locator is absent." -UnmanagedFiles $unmanagedFiles
            inventory = $inventory
            unmanaged_files = $unmanagedFiles
            unmanaged_fingerprint = $unmanagedFingerprint
        }
    }
    if ($managed) {
        return [pscustomobject]@{
            status = "drifted"
            detail = Add-UnmanagedDetail -Detail ($differences -join ", ") -UnmanagedFiles $unmanagedFiles
            inventory = $inventory
            unmanaged_files = $unmanagedFiles
            unmanaged_fingerprint = $unmanagedFingerprint
        }
    }
    return [pscustomobject]@{
        status = "unmanaged-existing"
        detail = Add-UnmanagedDetail -Detail ($differences -join ", ") -UnmanagedFiles $unmanagedFiles
        inventory = $inventory
        unmanaged_files = $unmanagedFiles
        unmanaged_fingerprint = $unmanagedFingerprint
    }
}

function New-SkillBackup {
    param(
        [string]$Target,
        [string]$Backup,
        [object[]]$ExpectedInventory
    )

    if (Test-Path -LiteralPath $Backup) {
        throw "Refusing to overwrite an existing skill backup: $Backup"
    }
    $backupParent = Split-Path -Parent $Backup
    New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
    Copy-Item -LiteralPath $Target -Destination $Backup -Recurse
    if (-not (Test-Path -LiteralPath $Backup -PathType Container)) {
        throw "Skill backup was not created: $Backup"
    }
    $backupInventory = @(Get-SkillFileInventory -Target $Backup)
    Compare-FileInventory -Expected $ExpectedInventory -Actual $backupInventory -Label "Skill backup"
}

function Remove-UnmanagedSkillFiles {
    param(
        [string]$SkillName,
        [string]$Target,
        [string]$RepositoryRoot,
        [string]$WorkEnvironmentRepositoryRoot,
        [string]$SkillRoot,
        [object[]]$SourceFiles,
        [object]$ExpectedRepositoryInfo,
        [object]$ExpectedWorkEnvironmentRepositoryInfo,
        [string]$ExpectedSourceFingerprint,
        [object[]]$ExpectedInventory,
        [object[]]$ExpectedUnmanagedFiles,
        [string]$ExpectedFingerprint,
        [string]$Backup
    )

    $freshInventory = @(Get-SkillFileInventory -Target $Target)
    Compare-FileInventory -Expected $ExpectedInventory -Actual $freshInventory -Label "Skill target"
    $freshUnmanagedFiles = @(
        Get-UnmanagedSkillFiles -SkillName $SkillName -Inventory $freshInventory -SourceFiles $SourceFiles
    )
    $freshFingerprint = Get-InventoryFingerprint -Files $freshUnmanagedFiles
    if ($freshFingerprint -ne $ExpectedFingerprint) {
        throw "Unmanaged skill fingerprint changed before prune."
    }
    Compare-FileInventory -Expected $ExpectedUnmanagedFiles -Actual $freshUnmanagedFiles -Label "Unmanaged skill"
    Assert-SourceSnapshotCurrent `
        -RepositoryRoot $RepositoryRoot `
        -SkillRoot $SkillRoot `
        -ExpectedRepositoryInfo $ExpectedRepositoryInfo `
        -ExpectedSourceFingerprint $ExpectedSourceFingerprint `
        -RequireClean
    Assert-RepositorySnapshotCurrent `
        -RepositoryRoot $WorkEnvironmentRepositoryRoot `
        -ExpectedRepositoryInfo $ExpectedWorkEnvironmentRepositoryInfo `
        -RequireClean

    $targetFull = [System.IO.Path]::GetFullPath($Target)
    $targetPrefix = $targetFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    foreach ($file in $freshUnmanagedFiles) {
        $fullPath = [System.IO.Path]::GetFullPath($file.full_path)
        if (-not $fullPath.StartsWith($targetPrefix, $pathStringComparison)) {
            throw "Refusing to prune a file outside the skill target: $fullPath"
        }
        $item = Get-Item -LiteralPath $fullPath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to prune a reparse-point file: $fullPath"
        }
        $backupFile = Join-Path $Backup $file.path
        $backupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $backupFile).Hash.ToLowerInvariant()
        $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToLowerInvariant()
        if ([int64]$item.Length -ne [int64]$file.bytes -or
            $currentHash -ne $file.sha256 -or
            $backupHash -ne $file.sha256) {
            throw "Unmanaged skill file changed after backup: $($file.path)"
        }
        Remove-Item -LiteralPath $fullPath -Force
        if (Test-Path -LiteralPath $fullPath) {
            throw "Unmanaged skill file remained after prune: $($file.path)"
        }
    }
}

function Copy-ManagedSkillFiles {
    param([object[]]$SourceFiles, [string]$Target)

    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    foreach ($file in $SourceFiles) {
        $destination = Join-Path $Target $file.path
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Copy-Item -LiteralPath $file.source_path -Destination $destination -Force
        $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
        if ($destinationHash -ne $file.sha256) {
            throw "Managed skill copy readback mismatch: $($file.path)"
        }
    }
}

function Write-InstallationRecords {
    param(
        [string]$SkillName,
        [string]$Target,
        [object[]]$SourceFiles,
        [object]$SourceRepositoryInfo,
        [object]$WorkEnvironmentRepositoryInfo
    )

    $fingerprint = Get-SkillSourceFingerprint -SourceFiles $SourceFiles
    $installedAt = [DateTime]::UtcNow.ToString("o")
    $publicFiles = @($SourceFiles | ForEach-Object { [ordered]@{ path = $_.path; sha256 = $_.sha256 } })

    $metadata = [ordered]@{
        schema = "rusty.morphospace.local_skill_source.v1"
        skill_id = $SkillName
        installed_at = $installedAt
        source_repository = $SourceRepositoryInfo.remote
        source_commit = $SourceRepositoryInfo.commit
        source_worktree_dirty = [bool]$SourceRepositoryInfo.dirty
        source_release = $SourceRepositoryInfo.release
        source_tree_sha256 = $fingerprint
        source_files = $publicFiles
        work_environment_root = $RepoRoot
    }
    Write-JsonUtf8NoBom -Path (Join-Path $Target ".morphospace-skill-source.json") -Value $metadata

    $locator = [ordered]@{
        schema = "rusty.morphospace.local_work_environment.v1"
        work_environment_root = $RepoRoot
        source_repository = $WorkEnvironmentRepositoryInfo.remote
        source_commit = $WorkEnvironmentRepositoryInfo.commit
        source_worktree_dirty = [bool]$WorkEnvironmentRepositoryInfo.dirty
        source_release = $WorkEnvironmentRepositoryInfo.release
        docs_root = (Join-Path $RepoRoot "docs")
    }
    Write-JsonUtf8NoBom -Path (Join-Path $Target "references\local-work-environment.json") -Value $locator

    if ($SkillName -eq "meta-quest-workflow") {
        $playbookLocator = [ordered]@{
            schema = "rusty.quest.workflow.local_playbook_source.v1"
            skill_id = $SkillName
            repository_root = $SourceRepositoryInfo.root
            source_repository = $SourceRepositoryInfo.remote
            source_commit = $SourceRepositoryInfo.commit
            source_tree = $SourceRepositoryInfo.tree
            source_worktree_dirty = [bool]$SourceRepositoryInfo.dirty
            source_status_fingerprint = $SourceRepositoryInfo.status_fingerprint
            readme_path = (Join-Path $SourceRepositoryInfo.root "README.md")
            docs_root = (Join-Path $SourceRepositoryInfo.root "docs")
            playbook_index_path = (Join-Path $SourceRepositoryInfo.root "docs\playbook-index.md")
        }
        Write-JsonUtf8NoBom `
            -Path (Join-Path $Target "references\local-meta-quest-playbooks.json") `
            -Value $playbookLocator
    }
}

$localSkills = @(
    Get-ChildItem -LiteralPath $SourceRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md") } |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                FullName = $_.FullName
                RepositoryRoot = $RepoRoot
            }
        }
)
if ($localSkills.Count -eq 0) {
    throw "No skills found under $SourceRoot"
}

$metaSkillId = "meta-quest-workflow"
$metaSkill = $null
if ($MetaQuestWorkflowRepoRoot) {
    $metaSkillRoot = Join-Path $MetaQuestWorkflowRepoRoot "skills\meta-quest-workflow"
    $metaSkill = [pscustomobject]@{
        Name = $metaSkillId
        FullName = $metaSkillRoot
        RepositoryRoot = $MetaQuestWorkflowRepoRoot
    }
}

if ($Action -eq "PruneUnmanaged" -and $SkillId.Count -ne 1) {
    throw "PruneUnmanaged requires exactly one -SkillId."
}

if ($SkillId.Count -gt 0) {
    if ($SkillId -contains $metaSkillId -and $null -eq $metaSkill) {
        throw "SkillId meta-quest-workflow requires an explicit -MetaQuestWorkflowRepoRoot."
    }
    $knownNames = @($localSkills.Name)
    if ($null -ne $metaSkill) {
        $knownNames += $metaSkillId
    }
    $unknown = @($SkillId | Where-Object { $_ -notin $knownNames })
    if ($unknown.Count -gt 0) {
        throw "Unknown SkillId value(s): $($unknown -join ', ')"
    }
    $skills = @($localSkills | Where-Object { $_.Name -in $SkillId })
    if ($null -ne $metaSkill -and $SkillId -contains $metaSkillId) {
        $skills += $metaSkill
    }
} else {
    $skills = @($localSkills)
    if ($null -ne $metaSkill) {
        $skills += $metaSkill
    }
}
$skills = @($skills | Sort-Object Name)

$workEnvironmentRepositoryInfo = Get-SourceRepositoryInfo -RepositoryRoot $RepoRoot
$skillContexts = @(
    foreach ($skill in $skills) {
        $sourceRepositoryInfo = Get-SourceRepositoryInfo -RepositoryRoot $skill.RepositoryRoot
        if ($skill.Name -eq $metaSkillId -and
            $sourceRepositoryInfo.remote -notmatch '(?i)(?:github\.com[:/])MesmerPrism/meta-quest-agent-workflow(?:\.git)?$') {
            throw "MetaQuestWorkflowRepoRoot origin is not the canonical Meta Quest workflow repository."
        }
        if ($skill.Name -eq $metaSkillId) {
            foreach ($playbookPath in @(
                (Join-Path $skill.RepositoryRoot "README.md"),
                (Join-Path $skill.RepositoryRoot "docs\playbook-index.md")
            )) {
                if (-not (Test-Path -LiteralPath $playbookPath -PathType Leaf)) {
                    throw "Canonical Meta Quest playbook source is missing: $playbookPath"
                }
            }
        }
        $sourceFiles = @(Get-SkillSourceFiles -SkillRoot $skill.FullName -RepositoryRoot $skill.RepositoryRoot)
        Assert-RequiredSkillSourceFiles -SkillName $skill.Name -SourceFiles $sourceFiles
        [pscustomobject]@{
            Skill = $skill
            SourceFiles = $sourceFiles
            SourceFingerprint = Get-SkillSourceFingerprint -SourceFiles $sourceFiles
            SourceRepositoryInfo = $sourceRepositoryInfo
        }
    }
)
$dirtySources = @(
    @($workEnvironmentRepositoryInfo) + @($skillContexts.SourceRepositoryInfo) |
        Where-Object { $_.dirty } |
        Select-Object -Unique commit, remote, dirty, release
)
if ($Execute -and $Action -in @("Install", "Update") -and $dirtySources.Count -gt 0 -and -not $AllowDirtySource) {
    throw "Refusing to install from a dirty source worktree. Commit/stash it, or pass -AllowDirtySource and retain the dirty-source provenance."
}
if ($Execute -and $Action -eq "PruneUnmanaged" -and $dirtySources.Count -gt 0) {
    throw "Refusing to prune against a dirty source worktree."
}

$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
$results = New-Object System.Collections.Generic.List[object]
$failed = $false

foreach ($context in $skillContexts) {
    $skill = $context.Skill
    $sourceFiles = @($context.SourceFiles)
    $sourceFingerprint = $context.SourceFingerprint
    $sourceRepositoryInfo = $context.SourceRepositoryInfo
    $target = Join-Path $TargetRoot $skill.Name
    $inspection = Test-TargetSkill `
        -SkillName $skill.Name `
        -Target $target `
        -SourceFiles $sourceFiles `
        -SourceRepositoryInfo $sourceRepositoryInfo `
        -WorkEnvironmentRepositoryInfo $workEnvironmentRepositoryInfo
    $resultAction = $inspection.status
    $detail = $inspection.detail
    $backup = $null
    $unmanagedFiles = @($inspection.unmanaged_files)
    $unmanagedFingerprint = $inspection.unmanaged_fingerprint
    $prunedFiles = @()
    $prunedFingerprint = $null

    switch ($Action) {
        "Plan" {
            $resultAction = switch ($inspection.status) {
                "absent" { "would-install" }
                "current" { "current" }
                default { "review-required" }
            }
        }
        "Verify" {
            if ($inspection.status -eq "current") {
                $resultAction = "verified"
            } else {
                $resultAction = "verification-failed"
                $failed = $true
            }
        }
        "Install" {
            if ($inspection.status -ne "absent") {
                $resultAction = "blocked-existing"
                $detail = "Install never overwrites an existing skill. Use Verify or an explicit Update. $detail"
                $failed = $true
            } elseif (-not $Execute) {
                $resultAction = "would-install"
                $detail = "No write performed; add -Execute to install."
            } else {
                Assert-SourceSnapshotCurrent `
                    -RepositoryRoot $skill.RepositoryRoot `
                    -SkillRoot $skill.FullName `
                    -ExpectedRepositoryInfo $sourceRepositoryInfo `
                    -ExpectedSourceFingerprint $sourceFingerprint
                Assert-RepositorySnapshotCurrent `
                    -RepositoryRoot $RepoRoot `
                    -ExpectedRepositoryInfo $workEnvironmentRepositoryInfo
                Copy-ManagedSkillFiles -SourceFiles $sourceFiles -Target $target
                Write-InstallationRecords `
                    -SkillName $skill.Name `
                    -Target $target `
                    -SourceFiles $sourceFiles `
                    -SourceRepositoryInfo $sourceRepositoryInfo `
                    -WorkEnvironmentRepositoryInfo $workEnvironmentRepositoryInfo
                Assert-SourceSnapshotCurrent `
                    -RepositoryRoot $skill.RepositoryRoot `
                    -SkillRoot $skill.FullName `
                    -ExpectedRepositoryInfo $sourceRepositoryInfo `
                    -ExpectedSourceFingerprint $sourceFingerprint
                Assert-RepositorySnapshotCurrent `
                    -RepositoryRoot $RepoRoot `
                    -ExpectedRepositoryInfo $workEnvironmentRepositoryInfo
                $finalInspection = Test-TargetSkill `
                    -SkillName $skill.Name `
                    -Target $target `
                    -SourceFiles $sourceFiles `
                    -SourceRepositoryInfo $sourceRepositoryInfo `
                    -WorkEnvironmentRepositoryInfo $workEnvironmentRepositoryInfo
                if ($finalInspection.status -ne "current") {
                    throw "Installed skill did not read back as current."
                }
                $resultAction = "installed"
                $detail = "Installed managed files and local provenance."
            }
        }
        "Update" {
            if ($inspection.status -eq "absent") {
                $resultAction = "blocked-absent"
                $detail = "Update requires an existing target. Use Install for a new skill."
                $failed = $true
            } elseif ($inspection.status -eq "current") {
                $resultAction = "current"
            } elseif (-not $Execute) {
                $resultAction = "would-update"
                $detail = "No write performed; add -Execute to back up and update managed files."
            } else {
                Assert-SourceSnapshotCurrent `
                    -RepositoryRoot $skill.RepositoryRoot `
                    -SkillRoot $skill.FullName `
                    -ExpectedRepositoryInfo $sourceRepositoryInfo `
                    -ExpectedSourceFingerprint $sourceFingerprint
                Assert-RepositorySnapshotCurrent `
                    -RepositoryRoot $RepoRoot `
                    -ExpectedRepositoryInfo $workEnvironmentRepositoryInfo
                $backup = Join-Path (Join-Path $BackupRoot $timestamp) $skill.Name
                New-SkillBackup -Target $target -Backup $backup -ExpectedInventory @($inspection.inventory)
                Assert-SourceSnapshotCurrent `
                    -RepositoryRoot $skill.RepositoryRoot `
                    -SkillRoot $skill.FullName `
                    -ExpectedRepositoryInfo $sourceRepositoryInfo `
                    -ExpectedSourceFingerprint $sourceFingerprint
                Assert-RepositorySnapshotCurrent `
                    -RepositoryRoot $RepoRoot `
                    -ExpectedRepositoryInfo $workEnvironmentRepositoryInfo
                Copy-ManagedSkillFiles -SourceFiles $sourceFiles -Target $target
                Write-InstallationRecords `
                    -SkillName $skill.Name `
                    -Target $target `
                    -SourceFiles $sourceFiles `
                    -SourceRepositoryInfo $sourceRepositoryInfo `
                    -WorkEnvironmentRepositoryInfo $workEnvironmentRepositoryInfo
                Assert-SourceSnapshotCurrent `
                    -RepositoryRoot $skill.RepositoryRoot `
                    -SkillRoot $skill.FullName `
                    -ExpectedRepositoryInfo $sourceRepositoryInfo `
                    -ExpectedSourceFingerprint $sourceFingerprint
                Assert-RepositorySnapshotCurrent `
                    -RepositoryRoot $RepoRoot `
                    -ExpectedRepositoryInfo $workEnvironmentRepositoryInfo
                $finalInspection = Test-TargetSkill `
                    -SkillName $skill.Name `
                    -Target $target `
                    -SourceFiles $sourceFiles `
                    -SourceRepositoryInfo $sourceRepositoryInfo `
                    -WorkEnvironmentRepositoryInfo $workEnvironmentRepositoryInfo
                if ($finalInspection.status -ne "current") {
                    throw "Updated skill did not read back as current."
                }
                $resultAction = "updated"
                $detail = "Updated managed files; unmanaged local files were preserved."
            }
        }
        "PruneUnmanaged" {
            if ($inspection.status -ne "current") {
                $resultAction = "prune-blocked"
                $detail = "PruneUnmanaged requires an otherwise current managed installation. $detail"
                $failed = $true
            } elseif ($unmanagedFiles.Count -eq 0) {
                $resultAction = "current"
                $detail = "No unmanaged files are present."
            } elseif (-not $Execute) {
                $resultAction = "would-prune-unmanaged"
                $detail = "No write performed; pass this unmanaged_fingerprint with -ExpectedUnmanagedFingerprint and add -Execute to prune."
            } elseif ($ExpectedUnmanagedFingerprint -notmatch '^[0-9a-fA-F]{64}$' -or
                $ExpectedUnmanagedFingerprint.ToLowerInvariant() -ne $unmanagedFingerprint) {
                $resultAction = "prune-blocked"
                $detail = "PruneUnmanaged requires the exact current -ExpectedUnmanagedFingerprint."
                $failed = $true
            } else {
                Assert-SourceSnapshotCurrent `
                    -RepositoryRoot $skill.RepositoryRoot `
                    -SkillRoot $skill.FullName `
                    -ExpectedRepositoryInfo $sourceRepositoryInfo `
                    -ExpectedSourceFingerprint $sourceFingerprint `
                    -RequireClean
                Assert-RepositorySnapshotCurrent `
                    -RepositoryRoot $RepoRoot `
                    -ExpectedRepositoryInfo $workEnvironmentRepositoryInfo `
                    -RequireClean
                $backup = Join-Path (Join-Path $BackupRoot $timestamp) $skill.Name
                New-SkillBackup -Target $target -Backup $backup -ExpectedInventory @($inspection.inventory)
                Remove-UnmanagedSkillFiles `
                    -SkillName $skill.Name `
                    -Target $target `
                    -RepositoryRoot $skill.RepositoryRoot `
                    -WorkEnvironmentRepositoryRoot $RepoRoot `
                    -SkillRoot $skill.FullName `
                    -SourceFiles $sourceFiles `
                    -ExpectedRepositoryInfo $sourceRepositoryInfo `
                    -ExpectedWorkEnvironmentRepositoryInfo $workEnvironmentRepositoryInfo `
                    -ExpectedSourceFingerprint $sourceFingerprint `
                    -ExpectedInventory @($inspection.inventory) `
                    -ExpectedUnmanagedFiles $unmanagedFiles `
                    -ExpectedFingerprint $unmanagedFingerprint `
                    -Backup $backup
                $finalInspection = Test-TargetSkill `
                    -SkillName $skill.Name `
                    -Target $target `
                    -SourceFiles $sourceFiles `
                    -SourceRepositoryInfo $sourceRepositoryInfo `
                    -WorkEnvironmentRepositoryInfo $workEnvironmentRepositoryInfo
                if ($finalInspection.status -ne "current" -or @($finalInspection.unmanaged_files).Count -ne 0) {
                    throw "Skill prune did not read back as current with zero unmanaged files."
                }
                $prunedFingerprint = $unmanagedFingerprint
                $prunedFiles = @($unmanagedFiles.path)
                $unmanagedFiles = @()
                $unmanagedFingerprint = $finalInspection.unmanaged_fingerprint
                $resultAction = "pruned-unmanaged"
                $detail = "Pruned only the fingerprinted unmanaged files after complete backup and exact readback."
            }
        }
    }

    $results.Add([pscustomobject]@{
        skill = $skill.Name
        action = $resultAction
        source_repository = $sourceRepositoryInfo.remote
        source_commit = $sourceRepositoryInfo.commit
        source_dirty = [bool]$sourceRepositoryInfo.dirty
        target = $target
        backup = $backup
        unmanaged_count = $unmanagedFiles.Count
        unmanaged_files = @($unmanagedFiles | ForEach-Object { $_.path })
        unmanaged_fingerprint = $unmanagedFingerprint
        pruned_count = $prunedFiles.Count
        pruned_files = @($prunedFiles)
        pruned_fingerprint = $prunedFingerprint
        detail = $detail
    })
}

if ($Json) {
    $results | ConvertTo-Json -Depth 8
} else {
    Write-Host "Action: $Action"
    Write-Host "Source: $SourceRoot"
    Write-Host "Target: $TargetRoot"
    if (-not $Execute -and $Action -in @("Install", "Update", "PruneUnmanaged")) {
        Write-Host "Dry run: no files were written."
    }
    $results | Format-Table skill, action, source_dirty, target -AutoSize
    foreach ($result in $results) {
        Write-Host "$($result.skill): $($result.detail)"
        if ($result.backup) {
            Write-Host "$($result.skill) backup: $($result.backup)"
        }
    }
}

if ($failed) {
    exit 1
}
