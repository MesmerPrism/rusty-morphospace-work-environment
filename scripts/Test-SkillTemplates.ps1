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
$expected = @("rust-work-graph", "rusty-morphospace", "rusty-morphospace-context", "system-engineering")
$actual = @(Get-ChildItem -LiteralPath $skillRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md") } | Sort-Object Name)

if (@($actual.Name).Count -ne $expected.Count -or (@($actual.Name) -join "|") -ne (($expected | Sort-Object) -join "|")) {
    throw "Expected exactly the four work-environment-owned portable skills. Found: $($actual.Name -join ', ')"
}
if ((Test-Path -LiteralPath (Join-Path $skillRoot "meta-quest-workflow\SKILL.md") -PathType Leaf) -or
    (Test-Path -LiteralPath (Join-Path $skillRoot "meta-quest-workflow\agents\openai.yaml") -PathType Leaf)) {
    throw "Work Environment must not track a competing Meta Quest skill source."
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
if ($context -notmatch '\$rusty-morphospace') {
    throw "The context resolver does not hand portable guidance to `$rusty-morphospace."
}

$publicPath = Join-Path $skillRoot "rusty-morphospace\SKILL.md"
$publicLines = @(Get-Content -LiteralPath $publicPath)
$public = $publicLines -join "`n"
if ($publicLines.Count -gt 100) {
    throw "The public Morphospace router is too large for progressive disclosure: $($publicLines.Count) lines."
}
foreach ($reference in @("references/ownership-map.md", "references/project-workflow.md")) {
    if ($public -notmatch [regex]::Escape($reference)) {
        throw "The public Morphospace router does not link $reference."
    }
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $publicPath) $reference) -PathType Leaf)) {
        throw "The public Morphospace skill is missing $reference."
    }
}
foreach ($route in @('$meta-quest-workflow', '$system-engineering', '$rust-work-graph')) {
    if (-not $public.Contains($route, [System.StringComparison]::Ordinal)) {
        throw "The public Morphospace router is missing route $route."
    }
}

if ($MetaQuestWorkflowRepoRoot) {
    $MetaQuestWorkflowRepoRoot = (Resolve-Path -LiteralPath $MetaQuestWorkflowRepoRoot).Path
    $metaSkillRoot = Join-Path $MetaQuestWorkflowRepoRoot "skills\meta-quest-workflow"
    $metaSkillPath = Join-Path $metaSkillRoot "SKILL.md"
    $metaAgentPath = Join-Path $metaSkillRoot "agents\openai.yaml"
    foreach ($path in @($metaSkillPath, $metaAgentPath)) {
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
    $metaAgent = Get-Content -Raw -LiteralPath $metaAgentPath
    foreach ($field in @("display_name:", "short_description:", "default_prompt:")) {
        if (-not $metaAgent.Contains($field, [System.StringComparison]::Ordinal)) {
            throw "Meta Quest skill metadata is missing $field"
        }
    }
    if ($metaAgent -match "[A-Za-z]:\\") {
        throw "Meta Quest skill metadata contains an absolute Windows path."
    }
}

$publicAgentPath = Join-Path $skillRoot "rusty-morphospace\agents\openai.yaml"
$contextAgentPath = Join-Path $skillRoot "rusty-morphospace-context\agents\openai.yaml"
foreach ($agentPath in @($publicAgentPath, $contextAgentPath)) {
    if (-not (Test-Path -LiteralPath $agentPath -PathType Leaf)) {
        throw "Changed skill is missing agents/openai.yaml: $agentPath"
    }
    $agent = Get-Content -Raw -LiteralPath $agentPath
    foreach ($field in @("display_name:", "short_description:", "default_prompt:", "allow_implicit_invocation:")) {
        if (-not $agent.Contains($field, [System.StringComparison]::Ordinal)) {
            throw "Changed skill metadata is missing $field ($agentPath)"
        }
    }
    if ($agent -match "[A-Za-z]:\\") {
        throw "Changed skill metadata contains an absolute Windows path: $agentPath"
    }
}
if ((Get-Content -Raw -LiteralPath $publicAgentPath) -notmatch "allow_implicit_invocation:\s*true") {
    throw "The public Morphospace skill must allow implicit invocation."
}
if ((Get-Content -Raw -LiteralPath $contextAgentPath) -notmatch "allow_implicit_invocation:\s*false") {
    throw "The local context resolver must require explicit invocation."
}

$lifecycle = Get-Content -Raw -LiteralPath (
    Join-Path $RepoRoot "manifests/workflow-lifecycle.portable.json"
) | ConvertFrom-Json -Depth 100
$triggerCategories = @(
    $lifecycle.instruction_sync.trigger_categories | ForEach-Object { [string]$_ }
)
$routes = @($lifecycle.instruction_sync.skill_routing)
$routeCategories = @($routes | ForEach-Object { [string]$_.change_category })
if (
    $routeCategories.Count -ne @($routeCategories | Sort-Object -Unique -CaseSensitive).Count -or
    (($routeCategories | Sort-Object -CaseSensitive) -join "`0") -cne
        (($triggerCategories | Sort-Object -CaseSensitive) -join "`0")
) {
    throw "Portable lifecycle skill routing must cover every trigger category exactly once."
}
foreach ($route in $routes) {
    $skillIds = @($route.skill_ids | ForEach-Object { [string]$_ })
    if (-not ($skillIds -ccontains "rusty-morphospace")) {
        throw "Portable lifecycle route '$($route.change_category)' omits rusty-morphospace."
    }
    if ($skillIds -ccontains "rusty-morphospace-context") {
        throw "Portable lifecycle route '$($route.change_category)' uses the machine-local resolver."
    }
}

$installation = Get-Content -Raw -LiteralPath (
    Join-Path $RepoRoot "docs/SKILL_INSTALLATION.md"
)
if (
    $installation -notmatch "ships four local portable skill routers" -or
    $installation -notmatch "canonical" -or
    $installation -notmatch "meta-quest-agent-workflow" -or
    $installation -notmatch '\| `rusty-morphospace` \|' -or
    $installation -notmatch '\| `rusty-morphospace-context` \|'
) {
    throw "Skill installation guidance does not describe the five-skill split."
}

Write-Host "Portable skill template validation passed."
