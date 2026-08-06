param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ("morphospace-handoff-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $source = Join-Path $root "source"
    & git init $source | Out-Null
    & git -C $source config user.name "Handoff Test"
    & git -C $source config user.email "handoff@example.invalid"
    [IO.File]::WriteAllText((Join-Path $source "seed.txt"), "seed`n", [Text.UTF8Encoding]::new($false))
    & git -C $source add seed.txt
    & git -C $source commit -m seed | Out-Null

    $project = Join-Path $root "project"
    & (Join-Path $PSScriptRoot "New-ProjectWorkspace.ps1") -ProjectRoot $project -ProjectId "handoff-test" -Purpose "Verify exact command handoff generation." -Execute | Out-Null
    $workspace = Join-Path $project "morphospace"
    $unitId = "handoff-unit-001"
    $unit = Get-Content -LiteralPath (Join-Path $repoRoot "templates\iteration-unit.example.json") -Raw | ConvertFrom-Json
    $unit.unit_id = $unitId; $unit.project_id = "handoff-test"; $unit.status = "ready"
    $unit.change_categories = @("implementation"); $unit.instruction_impact = "none"; $unit.instruction_surfaces = @(); $unit.instruction_none_justification = "The handoff fixture changes no reusable instructions."
    $unit.allowed_repositories = @([pscustomobject]@{ repo_id = "source-repo"; allowed_paths = @("seed.txt") })
    $unit.validation = @([pscustomobject]@{ profile_id = "host-check"; command = "pwsh -NoProfile -File ./verify-host.ps1 --exact" })
    $unit.acceptance = @([pscustomobject]@{ acceptance_id = "feature-proof"; proof = "The exact host command passes."; command = "pwsh -NoProfile -File ./accept-feature.ps1 --exact" })
    $unit.outputs = @("Exact handoff bundle")
    [IO.File]::WriteAllText((Join-Path $workspace "iteration-units\$unitId.json"), (($unit | ConvertTo-Json -Depth 32) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $mapPath = Join-Path $root "map.json"
    $map = [ordered]@{ schema = "rusty.morphospace.workflow.repository_map.v1"; repositories = @([ordered]@{ repo_id = "source-repo"; path = $source; role = "source" }) }
    [IO.File]::WriteAllText($mapPath, (($map | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $outPath = Join-Path $workspace "receipts\handoff.json"
    $handoff = & (Join-Path $PSScriptRoot "New-WorkUnitHandoff.ps1") -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $mapPath -Timestamp "2026-08-06T00:00:00Z" -OutPath $outPath -Execute | ConvertFrom-Json
    if ([string]$handoff.commands.validation[0].command -cne [string]$unit.validation[0].command -or [string]$handoff.commands.acceptance[0].command -cne [string]$unit.acceptance[0].command) { throw "Handoff command bytes drifted from the unit." }
    if ([string]$handoff.repositories[0].head -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$' -or [string]$handoff.repositories[0].tree -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw "Handoff lacks exact repository commit/tree evidence." }
    if (-not (Get-Content -LiteralPath $outPath -Raw | Test-Json -SchemaFile (Join-Path $repoRoot "schemas\work-unit-handoff.schema.json"))) { throw "Handoff failed its schema." }
    Write-Host "Work-unit handoff self-test passed."
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
