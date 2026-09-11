param(
    [string]$RepoRoot = "",
    [string]$MetaQuestWorkflowRepoRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$skillRoot = Join-Path $RepoRoot "skills"
$agentPath = Join-Path $RepoRoot "AGENTS.md"
$agentLines = @(Get-Content -LiteralPath $agentPath)
if ($agentLines.Count -gt 120) {
    throw "AGENTS.md exceeds the compact router budget: $($agentLines.Count) lines."
}
$agentContent = $agentLines -join "`n"
$agentDocs = @([regex]::Matches($agentContent, "docs/[A-Za-z0-9_.-]+\\.md") | ForEach-Object { $_.Value } | Sort-Object -Unique)
foreach ($document in $agentDocs) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $document) -PathType Leaf)) {
        throw "AGENTS.md links a missing owner runbook: $document"
    }
}
$limits = [ordered]@{
    "rusty-morphospace" = 4KB
    "system-engineering" = 6KB
    "rust-work-graph" = 4KB
    "rusty-morphospace-context" = 1KB
    "rusty-morphospace-cleanup" = 8KB
}
$actual = @(Get-ChildItem -LiteralPath $skillRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md") } |
    Sort-Object Name)

if ((@($actual.Name) -join "|") -cne (($limits.Keys | Sort-Object) -join "|")) {
    throw "Expected exactly the five work-environment-owned portable skills. Found: $($actual.Name -join ', ')"
}
if (Test-Path -LiteralPath (Join-Path $skillRoot "meta-quest-workflow\SKILL.md") -PathType Leaf) {
    throw "Work Environment must not track a competing Meta Quest skill source."
}

function Assert-Contains {
    param([string]$Content, [string]$Needle, [string]$Message)
    if (-not $Content.Contains($Needle, [System.StringComparison]::Ordinal)) {
        throw $Message
    }
}

$contentByName = @{}
foreach ($directory in $actual) {
    $path = Join-Path $directory.FullName "SKILL.md"
    $content = Get-Content -Raw -LiteralPath $path
    $contentByName[$directory.Name] = $content
    if ([System.Text.Encoding]::UTF8.GetByteCount($content) -gt $limits[$directory.Name]) {
        throw "Skill exceeds its entrypoint budget: $path"
    }
    $frontMatter = [regex]::Match($content, "(?s)^---\s*\r?\n.*?^name:\s*([^\r\n]+).*?^description:\s*([^\r\n]+).*?^---\s*$", [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $frontMatter.Success -or $frontMatter.Groups[1].Value.Trim(" '") -ne $directory.Name) {
        throw "Missing or invalid front matter: $path"
    }
    if ($content -match "[A-Za-z]:\\") {
        throw "Portable skill contains an absolute Windows path: $path"
    }
    $referencePaths = @([regex]::Matches($content, "references/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\\.md") | ForEach-Object { $_.Value } | Sort-Object -Unique)
    foreach ($reference in $referencePaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName $reference) -PathType Leaf)) {
            throw "Skill references a missing packaged resource: $reference ($path)"
        }
    }
    $ownerDocs = @([regex]::Matches($content, "docs/[A-Za-z0-9_.-]+\\.md") | ForEach-Object { $_.Value } | Sort-Object -Unique)
    foreach ($document in $ownerDocs) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $document) -PathType Leaf)) {
            throw "Skill references a missing owner runbook: $document ($path)"
        }
    }
}

# These assertions cover routing decisions, not old entrypoint prose.
foreach ($name in $limits.Keys) {
    Assert-Contains $contentByName[$name] "references/local-work-environment.json" "$name must resolve installed provenance without a machine path."
}
foreach ($name in @("rusty-morphospace", "system-engineering", "rust-work-graph")) {
    Assert-Contains $contentByName[$name] "CURRENT_WORK_VALIDATION.md" "$name must preserve the current-work boundary."
    Assert-Contains $contentByName[$name] "private" "$name must retain portable privacy routing."
}
Assert-Contains $contentByName["rusty-morphospace"] '$system-engineering' "The normal router must route authority decisions."
Assert-Contains $contentByName["rusty-morphospace"] '$rust-work-graph' "The normal router must route inventories and impact."
Assert-Contains $contentByName["rusty-morphospace"] '$meta-quest-workflow' "The normal router must route live device work."
Assert-Contains $contentByName["rusty-morphospace"] 'Select only the specialist routes that match the task' "The normal router must keep specialist routing conditional."
Assert-Contains $contentByName["rusty-morphospace"] 'validation policy, workflow, schema, or runner' "The normal router must identify validation-authority schema changes precisely."
Assert-Contains $contentByName["rusty-morphospace"] 'application, packet, or module contract schema' "The normal router must keep ordinary contract schemas out of the validation-authority route."
Assert-Contains $contentByName["rusty-morphospace"] 'source_commit' "The normal router must report locator source provenance before adoption."
Assert-Contains $contentByName["rusty-morphospace"] 'Install-LocalSkills.ps1 -Action' "The normal router must route currentness checks through the managed verifier."
Assert-Contains $contentByName["rusty-morphospace-context"] '$rusty-morphospace' "The compatibility locator must hand portable work to the normal router."
Assert-Contains $contentByName["system-engineering"] '$meta-quest-workflow' "System engineering must route live device work."
Assert-Contains $contentByName["rust-work-graph"] '$system-engineering' "The graph skill must route authority decisions."
Assert-Contains $contentByName["rust-work-graph"] '$meta-quest-workflow' "The graph skill must route live device work."
Assert-Contains $contentByName["rusty-morphospace-cleanup"] 'user requests cleanup' "The cleanup skill must remain user-invoked."
Assert-Contains $contentByName["rusty-morphospace-cleanup"] 'Do not schedule cleanup' "The cleanup skill must remain manual-only."

$publicPath = Join-Path $skillRoot "rusty-morphospace\SKILL.md"
foreach ($reference in @("references/ownership-map.md", "references/project-workflow.md")) {
    Assert-Contains $contentByName["rusty-morphospace"] $reference "The normal router must expose $reference."
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $publicPath) $reference) -PathType Leaf)) {
        throw "The normal router is missing $reference."
    }
}
$workflowReference = Join-Path (Split-Path -Parent $publicPath) "references\project-workflow.md"
if ((Get-Item -LiteralPath $workflowReference).Length -gt 8KB) {
    throw "The project-workflow reference exceeds its progressive-disclosure budget."
}
$workflowContent = Get-Content -Raw -LiteralPath $workflowReference
Assert-Contains $workflowContent '<work-environment>/docs/' "The project-workflow reference must resolve owner runbooks through the installed locator."
if ($workflowContent.Contains('](../../../docs/', [System.StringComparison]::Ordinal)) {
    throw "The project-workflow reference contains source-tree-relative owner-doc links that break after installation."
}

$lifecycle = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "manifests/workflow-lifecycle.portable.json") | ConvertFrom-Json -Depth 100
$categories = @($lifecycle.instruction_sync.trigger_categories | ForEach-Object { [string]$_ })
$routes = @($lifecycle.instruction_sync.skill_routing)
$routeCategories = @($routes | ForEach-Object { [string]$_.change_category })
if ($routeCategories.Count -ne @($routeCategories | Sort-Object -Unique -CaseSensitive).Count -or (($routeCategories | Sort-Object -CaseSensitive) -join "`0") -cne (($categories | Sort-Object -CaseSensitive) -join "`0")) {
    throw "Portable lifecycle skill routing must cover every trigger category exactly once."
}
foreach ($route in $routes) {
    if (@($route.skill_ids | ForEach-Object { [string]$_ }) -cnotcontains "rusty-morphospace") {
        throw "Portable lifecycle route '$($route.change_category)' omits rusty-morphospace."
    }
}

if ($MetaQuestWorkflowRepoRoot) {
    $MetaQuestWorkflowRepoRoot = (Resolve-Path -LiteralPath $MetaQuestWorkflowRepoRoot).Path
    $metaSkillRoot = Join-Path $MetaQuestWorkflowRepoRoot "skills\meta-quest-workflow"
    foreach ($path in @((Join-Path $metaSkillRoot "SKILL.md"), (Join-Path $metaSkillRoot "agents\openai.yaml"))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Canonical Meta Quest skill source is missing: $path"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $metaSkillRoot "references\local-work-environment.json")) {
        throw "Canonical Meta Quest skill source contains generated locator metadata."
    }
    $metaRemote = ([string](git -C $MetaQuestWorkflowRepoRoot remote get-url origin)).Trim()
    if ($metaRemote -notmatch '(?i)(?:github\.com[:/])MesmerPrism/meta-quest-agent-workflow(?:\.git)?$') {
        throw "Canonical Meta Quest skill source has the wrong origin."
    }
    if (@(git -C $MetaQuestWorkflowRepoRoot status --porcelain --untracked-files=normal).Count -ne 0) {
        throw "Canonical Meta Quest skill source must be clean."
    }
}

Write-Host "Portable skill template validation passed."
