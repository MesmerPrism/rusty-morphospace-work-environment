param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$skillRoot = Join-Path $RepoRoot "skills"
$expected = @("meta-quest-workflow", "rust-work-graph", "rusty-morphospace-context", "system-engineering")
$publicQuestWorkflowDocs = @(
    "docs/agent-execution-providers.md",
    "docs/adb-basics.md",
    "docs/apk-install-launch.md",
    "docs/managed-device-store-apps.md",
    "docs/artifact-and-evidence-discipline.md",
    "docs/quest-signal-patterns.md",
    "docs/accessibility-foreground-watchdogs.md",
    "docs/termux-linux-sidecars.md"
)
$actual = @(Get-ChildItem -LiteralPath $skillRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md") } | Sort-Object Name)

if (@($actual.Name).Count -ne $expected.Count -or (@($actual.Name) -join "|") -ne (($expected | Sort-Object) -join "|")) {
    throw "Expected exactly the four supported portable skills. Found: $($actual.Name -join ', ')"
}

foreach ($directory in $actual) {
    $path = Join-Path $directory.FullName "SKILL.md"
    $content = Get-Content -Raw -LiteralPath $path
    $frontMatter = [regex]::Match($content, "(?s)^---\s*\r?\n.*?^name:\s*([^\r\n]+).*?^---\s*$", [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $frontMatter.Success) {
        throw "Missing or invalid front matter: $path"
    }
    if ($frontMatter.Groups[1].Value.Trim(" '") -ne $directory.Name) {
        throw "Skill name does not match directory: $path"
    }
    if ($content -notmatch [regex]::Escape("references/local-work-environment.json")) {
        throw "Skill does not describe the generated local work-environment locator: $path"
    }
    if ($content -match "[A-Za-z]:\\") {
        throw "Portable skill contains an absolute Windows path: $path"
    }

    $docReferences = @([regex]::Matches($content, "docs/[A-Za-z0-9_.-]+\.md") | ForEach-Object { $_.Value } | Sort-Object -Unique)
    foreach ($reference in $docReferences) {
        if ($directory.Name -eq "meta-quest-workflow" -and $reference -in $publicQuestWorkflowDocs) {
            continue
        }
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $reference) -PathType Leaf)) {
            throw "Skill references a missing work-environment document: $reference ($path)"
        }
    }
}

$contextPath = Join-Path $skillRoot "rusty-morphospace-context\SKILL.md"
$contextLines = @(Get-Content -LiteralPath $contextPath)
$context = $contextLines -join "`n"
if ($contextLines.Count -gt 180) {
    throw "The context router is too large for a first-hop skill: $($contextLines.Count) lines."
}
if ($context -match "WF-005|NET-013|REL-003|unreleased until") {
    throw "The context router contains transient roadmap or release state."
}

Write-Host "Portable skill template validation passed."
