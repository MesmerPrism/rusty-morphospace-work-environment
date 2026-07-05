param(
    [string]$RepoRoot = "",
    [string]$TargetRoot = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$SourceRoot = Join-Path $RepoRoot "skills"

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    Write-Error "Skill source root not found: $SourceRoot"
    exit 1
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

$skills = Get-ChildItem -LiteralPath $SourceRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md") } |
    Sort-Object Name

if ($skills.Count -eq 0) {
    Write-Error "No skills found under $SourceRoot"
    exit 1
}

Write-Host "Source: $SourceRoot"
Write-Host "Target: $TargetRoot"
if (-not $Execute) {
    Write-Host "Dry run. Re-run with -Execute to copy."
}

if ($Execute) {
    New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
}

$results = foreach ($skill in $skills) {
    $target = Join-Path $TargetRoot $skill.Name
    $exists = Test-Path -LiteralPath $target

    if ($exists) {
        [pscustomobject]@{
            Skill = $skill.Name
            Action = "skip-existing"
            Target = $target
        }
        continue
    }

    if ($Execute) {
        Copy-Item -LiteralPath $skill.FullName -Destination $target -Recurse
        $action = "copied"
    } else {
        $action = "would-copy"
    }

    [pscustomobject]@{
        Skill = $skill.Name
        Action = $action
        Target = $target
    }
}

$results | Format-Table -AutoSize

if (($results | Where-Object { $_.Action -eq "skip-existing" }).Count -gt 0) {
    Write-Warning "Existing skill directories were not overwritten."
}
