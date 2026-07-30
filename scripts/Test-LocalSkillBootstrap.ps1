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
$targetRoot = Join-Path $testRoot "skills"
$backupRoot = Join-Path $testRoot "backups"

function Invoke-InstallerChild {
    param([string[]]$Arguments, [int]$ExpectedExit = 0)

    $output = @(& $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $installer @Arguments 2>&1)
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

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

    $planText = Invoke-InstallerChild -Arguments @("-RepoRoot", $RepoRoot, "-TargetRoot", $targetRoot, "-Action", "Plan", "-Json")
    $plan = $planText | ConvertFrom-Json
    Assert-True -Condition (@($plan).Count -eq 5) -Message "Plan did not include all five portable skills (count=$(@($plan).Count)). Output: $planText"
    Assert-True -Condition (@($plan | Where-Object { $_.action -ne "would-install" }).Count -eq 0) -Message "Fresh plan was not entirely would-install."
    Assert-True -Condition (-not (Test-Path -LiteralPath $targetRoot)) -Message "Plan unexpectedly created the target root."

    $dryInstallText = Invoke-InstallerChild -Arguments @("-RepoRoot", $RepoRoot, "-TargetRoot", $targetRoot, "-Action", "Install", "-Json")
    $dryInstall = $dryInstallText | ConvertFrom-Json
    Assert-True -Condition (@($dryInstall | Where-Object { $_.action -ne "would-install" }).Count -eq 0) -Message "Install without -Execute did not remain a dry run."
    Assert-True -Condition (-not (Test-Path -LiteralPath $targetRoot)) -Message "Install without -Execute wrote files."

    $installText = Invoke-InstallerChild -Arguments @("-RepoRoot", $RepoRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "Install", "-Execute", "-AllowDirtySource", "-Json")
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
            Assert-True -Condition (@($metadata.source_files | Where-Object { $_.path -eq "agents\openai.yaml" }).Count -eq 1) -Message "Meta Quest skill provenance does not bind agents/openai.yaml."
        }
        if ($skill -in @("rusty-morphospace", "rusty-morphospace-context")) {
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $skillRoot "agents\openai.yaml")) -Message "$skill agents/openai.yaml is missing."
            Assert-True -Condition (@($metadata.source_files | Where-Object { $_.path -eq "agents\openai.yaml" }).Count -eq 1) -Message "$skill provenance does not bind agents/openai.yaml."
        }
    }

    $verifyText = Invoke-InstallerChild -Arguments @("-RepoRoot", $RepoRoot, "-TargetRoot", $targetRoot, "-Action", "Verify", "-Json")
    $verified = $verifyText | ConvertFrom-Json
    Assert-True -Condition (@($verified | Where-Object { $_.action -ne "verified" }).Count -eq 0) -Message "Freshly installed skills did not verify."

    $contextRoot = Join-Path $targetRoot "rusty-morphospace-context"
    $localNote = Join-Path $contextRoot "references\contributor-local-notes.md"
    [System.IO.File]::WriteAllText($localNote, "unmanaged local note`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::AppendAllText((Join-Path $contextRoot "SKILL.md"), "`nlocal drift`n", (New-Object System.Text.UTF8Encoding($false)))

    $driftText = Invoke-InstallerChild -Arguments @("-RepoRoot", $RepoRoot, "-TargetRoot", $targetRoot, "-Action", "Verify", "-SkillId", "rusty-morphospace-context", "-Json") -ExpectedExit 1
    $drift = $driftText | ConvertFrom-Json
    Assert-True -Condition ($drift[0].action -eq "verification-failed") -Message "Managed drift was not detected."

    $dryUpdateText = Invoke-InstallerChild -Arguments @("-RepoRoot", $RepoRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "Update", "-SkillId", "rusty-morphospace-context", "-Json")
    $dryUpdate = $dryUpdateText | ConvertFrom-Json
    Assert-True -Condition ($dryUpdate[0].action -eq "would-update") -Message "Update without -Execute was not a dry run."
    Assert-True -Condition ((Get-Content -Raw -LiteralPath (Join-Path $contextRoot "SKILL.md")) -match "local drift") -Message "Dry update unexpectedly repaired the file."

    $updateText = Invoke-InstallerChild -Arguments @("-RepoRoot", $RepoRoot, "-TargetRoot", $targetRoot, "-BackupRoot", $backupRoot, "-Action", "Update", "-SkillId", "rusty-morphospace-context", "-Execute", "-AllowDirtySource", "-Json")
    $updated = $updateText | ConvertFrom-Json
    Assert-True -Condition ($updated[0].action -eq "updated") -Message "Explicit update did not run."
    Assert-True -Condition (Test-Path -LiteralPath $updated[0].backup) -Message "Explicit update did not create its backup."
    Assert-True -Condition (Test-Path -LiteralPath $localNote) -Message "Update deleted an unmanaged local file."
    Assert-True -Condition (-not ((Get-Content -Raw -LiteralPath (Join-Path $contextRoot "SKILL.md")) -match "local drift")) -Message "Update did not restore the managed skill."

    Invoke-InstallerChild -Arguments @("-RepoRoot", $RepoRoot, "-TargetRoot", $targetRoot, "-Action", "Verify", "-Json") | Out-Null
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
