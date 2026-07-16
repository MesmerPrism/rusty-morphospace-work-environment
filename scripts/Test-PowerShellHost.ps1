param(
    [version]$MinimumVersion = [version]"7.6.0",
    [switch]$SelfTest,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Test-SupportedPowerShellHost {
    param(
        [version]$Version,
        [string]$Edition,
        [version]$Minimum
    )

    return $Edition -eq "Core" -and $Version -ge $Minimum
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

if ($SelfTest) {
    Assert-True (Test-SupportedPowerShellHost -Version ([version]"7.6.0") -Edition "Core" -Minimum $MinimumVersion) "PowerShell 7.6 Core should satisfy the host contract."
    Assert-True (-not (Test-SupportedPowerShellHost -Version ([version]"7.5.9") -Edition "Core" -Minimum $MinimumVersion)) "PowerShell below 7.6 should fail the host contract."
    Assert-True (-not (Test-SupportedPowerShellHost -Version ([version]"7.6.0") -Edition "Desktop" -Minimum $MinimumVersion)) "Windows PowerShell Desktop edition should fail the host contract."

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $candidateRoots = @(
        (Join-Path $repoRoot ".github"),
        (Join-Path $repoRoot "docs"),
        (Join-Path $repoRoot "examples"),
        (Join-Path $repoRoot "manifests"),
        (Join-Path $repoRoot "scripts"),
        (Join-Path $repoRoot "skills"),
        (Join-Path $repoRoot "templates"),
        (Join-Path $repoRoot "AGENTS.md"),
        (Join-Path $repoRoot "CONTRIBUTING.md"),
        (Join-Path $repoRoot "README.md")
    )
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($root in $candidateRoots) {
        if (Test-Path -LiteralPath $root -PathType Leaf) {
            $files.Add((Get-Item -LiteralPath $root))
        } elseif (Test-Path -LiteralPath $root -PathType Container) {
            Get-ChildItem -LiteralPath $root -Recurse -File |
                Where-Object { $_.Extension -in @(".json", ".md", ".ps1", ".psm1", ".yaml", ".yml") } |
                ForEach-Object { $files.Add($_) }
        }
    }

    $thisScript = [IO.Path]::GetFullPath($PSCommandPath)
    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        if ([IO.Path]::GetFullPath($file.FullName) -eq $thisScript) { continue }
        $text = [IO.File]::ReadAllText($file.FullName)
        if ($text -match "(?im)(?<![A-Za-z0-9_.-])powershell(?:\.exe)?\s+(?:-NoProfile|-ExecutionPolicy)" -or
            $text -match "(?im)Get-Command\s+powershell\.exe" -or
            $text -match "(?im)^\s*shell:\s*powershell\s*$") {
            $violations.Add($file.FullName)
        }
    }
    Assert-True ($violations.Count -eq 0) ("Authoritative workflows still invoke Windows PowerShell: " + (($violations | Sort-Object -Unique) -join ", "))
}

$currentVersion = [version]$PSVersionTable.PSVersion
$currentEdition = [string]$PSVersionTable.PSEdition
if (-not (Test-SupportedPowerShellHost -Version $currentVersion -Edition $currentEdition -Minimum $MinimumVersion)) {
    [Console]::Error.WriteLine("PowerShell $MinimumVersion or newer (Core edition, executable 'pwsh') is required. Current host: $currentVersion $currentEdition. On Windows run 'winget install --id Microsoft.PowerShell --source winget', then invoke this workflow with 'pwsh'. PowerShell 7 installs side-by-side with Windows PowerShell 5.1.")
    exit 1
}

if (-not $Quiet) {
    Write-Host "PowerShell host contract passed: $currentVersion $currentEdition"
}

if ($SelfTest) {
    Write-Host "PowerShell 7.6 host-policy self-test passed."
}
