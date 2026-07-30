param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$installer = Join-Path $RepoRoot "scripts\Install-LocalSkills.ps1"
$hostExecutable = (Get-Process -Id $PID).Path
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("rusty-morphospace-skill-bootstrap-" + [guid]::NewGuid().ToString("N"))
$installerSourceRoot = Join-Path $testRoot "source"
$metaSourceRoot = Join-Path $testRoot "meta-source"
$targetRoot = Join-Path $testRoot "skills"
$backupRoot = Join-Path $testRoot "backups"

function Invoke-InstallerChild {
    param(
        [string[]]$Arguments,
        [int]$ExpectedExit = 0,
        [switch]$NoMetaSource
    )

    $effectiveArguments = @($Arguments)
    if (-not $NoMetaSource) {
        $effectiveArguments += @("-MetaQuestWorkflowRepoRoot", $metaSourceRoot)
    }
    $output = @(& $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $installer @effectiveArguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne $ExpectedExit) {
        throw "Installer exit $exitCode; expected $ExpectedExit. Output: $($output -join ' | ')"
    }
    return ($output -join [Environment]::NewLine)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-IgnoredMetaRequiredFileRejected {
    param([string]$RelativePath)

    $excludePath = Join-Path $metaSourceRoot ".git\info\exclude"
    $originalExclude = [System.IO.File]::ReadAllText($excludePath)
    & git -C $metaSourceRoot rm -q --cached -- $RelativePath
    & git -C $metaSourceRoot commit -q --no-verify -m "test: remove required Meta source ownership"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create ignored-required-file fixture for $RelativePath."
    }
    try {
        [System.IO.File]::AppendAllText(
            $excludePath,
            "`n/$($RelativePath.Replace('\', '/'))`n",
            (New-Object System.Text.UTF8Encoding($false))
        )
        $status = @(& git -C $metaSourceRoot status --porcelain --untracked-files=normal)
        Assert-True -Condition ($status.Count -eq 0) -Message "Ignored-required-file fixture was not clean for $RelativePath."
        $rejection = Invoke-InstallerChild -Arguments @(
            "-RepoRoot", $installerSourceRoot,
            "-TargetRoot", $targetRoot,
            "-Action", "Plan",
            "-SkillId", "meta-quest-workflow",
            "-Json"
        ) -ExpectedExit 1
        Assert-True `
            -Condition ($rejection -match "Git-owned skill source inventory is missing required path") `
            -Message "Ignored required Meta file was not rejected from the Git-owned inventory: $RelativePath"
    } finally {
        [System.IO.File]::WriteAllText(
            $excludePath,
            $originalExclude,
            (New-Object System.Text.UTF8Encoding($false))
        )
        & git -C $metaSourceRoot add -- $RelativePath
        & git -C $metaSourceRoot commit -q --no-verify -m "test: restore required Meta source ownership"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to restore required Meta source fixture for $RelativePath."
        }
    }
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $installerSourceRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot "skills") -Destination (Join-Path $installerSourceRoot "skills") -Recurse
    if (Test-Path -LiteralPath (Join-Path $RepoRoot "manifests") -PathType Container) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "manifests") -Destination (Join-Path $installerSourceRoot "manifests") -Recurse
    }
    & git -C $installerSourceRoot init -q -b main
    & git -C $installerSourceRoot config core.autocrlf false
    & git -C $installerSourceRoot config commit.gpgsign false
    $emptyHooks = Join-Path $installerSourceRoot ".empty-hooks"
    New-Item -ItemType Directory -Force -Path $emptyHooks | Out-Null
    & git -C $installerSourceRoot config core.hooksPath $emptyHooks
    & git -C $installerSourceRoot config user.name "Rusty Morphospace Bootstrap Test"
    & git -C $installerSourceRoot config user.email "bootstrap-test@example.invalid"
    & git -C $installerSourceRoot add -- .
    & git -C $installerSourceRoot commit -q --no-verify -m "test: materialize clean skill source"
    & git -C $installerSourceRoot remote add origin "https://example.invalid/rusty-morphospace-work-environment.git"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the clean temporary skill source."
    }

    $metaSkillRoot = Join-Path $metaSourceRoot "skills\meta-quest-workflow"
    New-Item -ItemType Directory -Force -Path (Join-Path $metaSkillRoot "agents") | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $metaSkillRoot "SKILL.md"),
        "---`nname: meta-quest-workflow`ndescription: 'Canonical external test skill.'`n---`n`n# Meta Quest Workflow`n`nOptional local metadata: references/local-work-environment.json`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $metaSkillRoot "agents\openai.yaml"),
        "interface:`n  display_name: `"Meta Quest Workflow`"`n  short_description: `"Quest ecosystem routing and validation`"`n  default_prompt: `"Use `$meta-quest-workflow for the narrowest provider.`"`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    & git -C $metaSourceRoot init -q -b main
    & git -C $metaSourceRoot config core.autocrlf false
    & git -C $metaSourceRoot config commit.gpgsign false
    $metaEmptyHooks = Join-Path $metaSourceRoot ".empty-hooks"
    New-Item -ItemType Directory -Force -Path $metaEmptyHooks | Out-Null
    & git -C $metaSourceRoot config core.hooksPath $metaEmptyHooks
    & git -C $metaSourceRoot config user.name "Meta Quest Bootstrap Test"
    & git -C $metaSourceRoot config user.email "bootstrap-test@example.invalid"
    & git -C $metaSourceRoot add -- .
    & git -C $metaSourceRoot commit -q --no-verify -m "test: materialize canonical Meta skill source"
    & git -C $metaSourceRoot remote add origin "https://github.com/MesmerPrism/meta-quest-agent-workflow.git"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the clean temporary Meta Quest skill source."
    }

    Assert-IgnoredMetaRequiredFileRejected -RelativePath "skills/meta-quest-workflow/SKILL.md"
    Assert-IgnoredMetaRequiredFileRejected -RelativePath "skills/meta-quest-workflow/agents/openai.yaml"

    Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "Plan", "-SkillId", "meta-quest-workflow", "-Json") -ExpectedExit 1 -NoMetaSource | Out-Null

    $planText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "Plan", "-Json")
    $plan = $planText | ConvertFrom-Json
    Assert-True -Condition (@($plan).Count -eq 5) -Message "Plan did not include all five portable skills (count=$(@($plan).Count)). Output: $planText"
    Assert-True -Condition (@($plan | Where-Object { $_.action -ne "would-install" }).Count -eq 0) -Message "Fresh plan was not entirely would-install."
    Assert-True -Condition (-not (Test-Path -LiteralPath $targetRoot)) -Message "Plan unexpectedly created the target root."

    $dryInstallText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "Install", "-Json")
    $dryInstall = $dryInstallText | ConvertFrom-Json
    Assert-True -Condition (@($dryInstall | Where-Object { $_.action -ne "would-install" }).Count -eq 0) -Message "Install without -Execute did not remain a dry run."
    Assert-True -Condition (-not (Test-Path -LiteralPath $targetRoot)) -Message "Install without -Execute wrote files."

    $installText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "Install", "-Execute", "-Json")
    $installed = $installText | ConvertFrom-Json
    Assert-True -Condition (@($installed | Where-Object { $_.action -ne "installed" }).Count -eq 0) -Message "One or more skills were not installed."

    foreach ($skill in @("meta-quest-workflow", "rust-work-graph", "rusty-morphospace", "rusty-morphospace-context", "system-engineering")) {
        $skillRoot = Join-Path $targetRoot $skill
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $skillRoot "SKILL.md")) -Message "$skill SKILL.md is missing."
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $skillRoot ".morphospace-skill-source.json")) -Message "$skill provenance is missing."
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $skillRoot "references\local-work-environment.json")) -Message "$skill local locator is missing."
        $metadata = Get-Content -Raw -LiteralPath (Join-Path $skillRoot ".morphospace-skill-source.json") | ConvertFrom-Json
        Assert-True -Condition ($metadata.schema -eq "rusty.morphospace.local_skill_source.v1") -Message "$skill provenance schema is wrong."
        Assert-True -Condition ($metadata.source_files.Count -gt 0) -Message "$skill provenance has no managed file hashes."
        if ($skill -eq "meta-quest-workflow") {
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $skillRoot "agents\openai.yaml")) -Message "Meta Quest agents/openai.yaml is missing."
            Assert-True -Condition (@($metadata.source_files | Where-Object {
                ([string]$_.path).Replace("\", "/") -ceq "agents/openai.yaml"
            }).Count -eq 1) -Message "Meta Quest skill provenance does not bind agents/openai.yaml."
            $metaCommit = ([string](git -C $metaSourceRoot rev-parse HEAD)).Trim()
            Assert-True -Condition ($metadata.source_repository -eq "https://github.com/MesmerPrism/meta-quest-agent-workflow.git") -Message "Meta Quest skill provenance does not name the canonical repository."
            Assert-True -Condition ($metadata.source_commit -eq $metaCommit) -Message "Meta Quest skill provenance does not bind the canonical source commit."
            $locator = Get-Content -Raw -LiteralPath (Join-Path $skillRoot "references\local-work-environment.json") | ConvertFrom-Json
            $workEnvironmentCommit = ([string](git -C $installerSourceRoot rev-parse HEAD)).Trim()
            Assert-True -Condition ($locator.source_repository -eq "https://example.invalid/rusty-morphospace-work-environment.git") -Message "Meta Quest locator does not retain Work Environment provenance."
            Assert-True -Condition ($locator.source_commit -eq $workEnvironmentCommit) -Message "Meta Quest locator does not bind the Work Environment commit."
        }
        if ($skill -in @("rusty-morphospace", "rusty-morphospace-context")) {
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $skillRoot "agents\openai.yaml")) -Message "$skill agents/openai.yaml is missing."
            Assert-True -Condition (@($metadata.source_files | Where-Object {
                ([string]$_.path).Replace("\", "/") -ceq "agents/openai.yaml"
            }).Count -eq 1) -Message "$skill provenance does not bind agents/openai.yaml."
        }
    }

    $verifyText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "Verify", "-Json")
    $verified = $verifyText | ConvertFrom-Json
    Assert-True -Condition (@($verified | Where-Object { $_.action -ne "verified" }).Count -eq 0) -Message "Freshly installed skills did not verify."
    Assert-True -Condition (@($verified | Where-Object { $_.unmanaged_count -ne 0 }).Count -eq 0) -Message "Freshly installed skills unexpectedly reported unmanaged files."

    $contextRoot = Join-Path $targetRoot "rusty-morphospace-context"
    $localNote = Join-Path $contextRoot "references\contributor-local-notes.md"
    [System.IO.File]::WriteAllText($localNote, "unmanaged local note`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::AppendAllText((Join-Path $contextRoot "SKILL.md"), "`nlocal drift`n", (New-Object System.Text.UTF8Encoding($false)))

    $driftText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "Verify", "-SkillId", "rusty-morphospace-context", "-Json") -ExpectedExit 1
    $drift = $driftText | ConvertFrom-Json
    Assert-True -Condition ($drift[0].action -eq "verification-failed") -Message "Managed drift was not detected."
    Assert-True -Condition ($drift[0].unmanaged_count -eq 1) -Message "Verify did not report the unmanaged local note."
    Assert-True -Condition ($drift[0].unmanaged_files[0] -eq "references/contributor-local-notes.md") -Message "Verify reported the wrong unmanaged path."

    $blockedPruneText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Execute", "-ExpectedUnmanagedFingerprint", $drift[0].unmanaged_fingerprint, "-Json") -ExpectedExit 1
    $blockedPrune = $blockedPruneText | ConvertFrom-Json
    Assert-True -Condition ($blockedPrune[0].action -eq "prune-blocked") -Message "Prune did not reject managed drift."
    Assert-True -Condition (Test-Path -LiteralPath $localNote) -Message "Blocked prune deleted the unmanaged local note."

    $dryUpdateText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "Update", "-SkillId", "rusty-morphospace-context", "-Json")
    $dryUpdate = $dryUpdateText | ConvertFrom-Json
    Assert-True -Condition ($dryUpdate[0].action -eq "would-update") -Message "Update without -Execute was not a dry run."
    Assert-True -Condition ((Get-Content -Raw -LiteralPath (Join-Path $contextRoot "SKILL.md")) -match "local drift") -Message "Dry update unexpectedly repaired the file."

    $updateText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "Update", "-SkillId", "rusty-morphospace-context", "-Execute", "-Json")
    $updated = $updateText | ConvertFrom-Json
    Assert-True -Condition ($updated[0].action -eq "updated") -Message "Explicit update did not run."
    Assert-True -Condition (Test-Path -LiteralPath $updated[0].backup) -Message "Explicit update did not create its backup."
    Assert-True -Condition (Test-Path -LiteralPath $localNote) -Message "Update deleted an unmanaged local file."
    Assert-True -Condition (-not ((Get-Content -Raw -LiteralPath (Join-Path $contextRoot "SKILL.md")) -match "local drift")) -Message "Update did not restore the managed skill."

    $preservedText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "Verify", "-SkillId", "rusty-morphospace-context", "-Json")
    $preserved = $preservedText | ConvertFrom-Json
    Assert-True -Condition ($preserved[0].action -eq "verified") -Message "Verify failed solely because an unmanaged file was present."
    Assert-True -Condition ($preserved[0].unmanaged_count -eq 1) -Message "Verify did not report the preserved unmanaged file."

    Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "PruneUnmanaged", "-Json") -ExpectedExit 1 | Out-Null
    Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", (Join-Path $targetRoot "nested-backups"), "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Json") -ExpectedExit 1 | Out-Null
    Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $testRoot, "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Json") -ExpectedExit 1 | Out-Null

    $dryPruneText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Json")
    $dryPrune = $dryPruneText | ConvertFrom-Json
    Assert-True -Condition ($dryPrune[0].action -eq "would-prune-unmanaged") -Message "PruneUnmanaged without -Execute was not a dry run."
    Assert-True -Condition ($dryPrune[0].unmanaged_count -eq 1) -Message "Dry prune did not report the unmanaged file."
    Assert-True -Condition (Test-Path -LiteralPath $localNote) -Message "Dry prune deleted the unmanaged local note."

    $wrongFingerprint = "0" * 64
    $wrongPruneText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Execute", "-ExpectedUnmanagedFingerprint", $wrongFingerprint, "-Json") -ExpectedExit 1
    $wrongPrune = $wrongPruneText | ConvertFrom-Json
    Assert-True -Condition ($wrongPrune[0].action -eq "prune-blocked") -Message "Prune accepted the wrong unmanaged fingerprint."
    Assert-True -Condition (Test-Path -LiteralPath $localNote) -Message "Wrong-fingerprint prune deleted the unmanaged local note."

    $missingFingerprintText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Execute", "-Json") -ExpectedExit 1
    $missingFingerprint = $missingFingerprintText | ConvertFrom-Json
    Assert-True -Condition ($missingFingerprint[0].action -eq "prune-blocked") -Message "Prune accepted a missing unmanaged fingerprint."

    [System.IO.File]::AppendAllText($localNote, "changed after review`n", (New-Object System.Text.UTF8Encoding($false)))
    $staleFingerprintText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Execute", "-ExpectedUnmanagedFingerprint", $dryPrune[0].unmanaged_fingerprint, "-Json") -ExpectedExit 1
    $staleFingerprint = $staleFingerprintText | ConvertFrom-Json
    Assert-True -Condition ($staleFingerprint[0].action -eq "prune-blocked") -Message "Prune accepted a stale unmanaged fingerprint."
    [System.IO.File]::WriteAllText($localNote, "unmanaged local note`n", (New-Object System.Text.UTF8Encoding($false)))

    $dirtyMarker = Join-Path $installerSourceRoot "dirty-source-marker.txt"
    [System.IO.File]::WriteAllText($dirtyMarker, "dirty`n", (New-Object System.Text.UTF8Encoding($false)))
    Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Execute", "-AllowDirtySource", "-ExpectedUnmanagedFingerprint", $dryPrune[0].unmanaged_fingerprint, "-Json") -ExpectedExit 1 | Out-Null
    Remove-Item -LiteralPath $dirtyMarker -Force

    $dirtyMetaMarker = Join-Path $metaSourceRoot "dirty-meta-source-marker.txt"
    [System.IO.File]::WriteAllText($dirtyMetaMarker, "dirty`n", (New-Object System.Text.UTF8Encoding($false)))
    Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "Update", "-SkillId", "meta-quest-workflow", "-Execute", "-Json") -ExpectedExit 1 | Out-Null
    Remove-Item -LiteralPath $dirtyMetaMarker -Force

    $pruneText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Execute", "-ExpectedUnmanagedFingerprint", $dryPrune[0].unmanaged_fingerprint, "-Json")
    $pruned = $pruneText | ConvertFrom-Json
    Assert-True -Condition ($pruned[0].action -eq "pruned-unmanaged") -Message "Explicit PruneUnmanaged did not run."
    Assert-True -Condition ($pruned[0].pruned_count -eq 1) -Message "Explicit prune did not report the removed file."
    Assert-True -Condition ($pruned[0].pruned_fingerprint -eq $dryPrune[0].unmanaged_fingerprint) -Message "Explicit prune did not retain its authorized pre-state fingerprint."
    Assert-True -Condition ($pruned[0].unmanaged_count -eq 0) -Message "Explicit prune did not read back zero unmanaged files."
    Assert-True -Condition (Test-Path -LiteralPath $pruned[0].backup) -Message "Explicit prune did not create its backup."
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $pruned[0].backup "references\contributor-local-notes.md")) -Message "Prune backup did not retain the unmanaged file."
    Assert-True -Condition (-not (Test-Path -LiteralPath $localNote)) -Message "Explicit prune left the unmanaged local note in the skill root."

    $reparseTarget = Join-Path $testRoot "reparse-target"
    $reparsePath = Join-Path $contextRoot "references\reparse-probe"
    New-Item -ItemType Directory -Force -Path $reparseTarget | Out-Null
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        New-Item -ItemType Junction -Path $reparsePath -Target $reparseTarget | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $reparsePath -Target $reparseTarget | Out-Null
    }
    Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "Verify", "-SkillId", "rusty-morphospace-context", "-Json") -ExpectedExit 1 | Out-Null
    Remove-Item -LiteralPath $reparsePath -Force

    $finalVerifyText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-Action", "Verify", "-Json")
    $finalVerify = $finalVerifyText | ConvertFrom-Json
    Assert-True -Condition (@($finalVerify | Where-Object { $_.action -ne "verified" -or $_.unmanaged_count -ne 0 }).Count -eq 0) -Message "Final verification was not clean."

    $noCandidateText = Invoke-InstallerChild -Arguments @("-RepoRoot", $installerSourceRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "PruneUnmanaged", "-SkillId", "rusty-morphospace-context", "-Execute", "-Json")
    $noCandidate = $noCandidateText | ConvertFrom-Json
    Assert-True -Condition ($noCandidate[0].action -eq "current") -Message "Zero-candidate prune was not a no-op."
    Assert-True -Condition ($null -eq $noCandidate[0].backup) -Message "Zero-candidate prune created a backup."
    Write-Host "Local skill bootstrap self-test passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        if (-not $resolved.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a skill-bootstrap test path outside the system temporary directory."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
