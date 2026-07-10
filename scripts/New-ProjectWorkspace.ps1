param(
    [string]$ProjectRoot = "",
    [string]$ProjectId = "",
    [string]$Purpose = "",
    [switch]$Execute,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SchemaBase = "https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas"

function Write-JsonDocument {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function New-ProjectWorkspaceInternal {
    param(
        [string]$Root,
        [string]$Id,
        [string]$ProjectPurpose,
        [bool]$DoExecute
    )

    if (-not ($Id -match "^[a-z0-9][a-z0-9-]{1,63}$")) {
        throw "ProjectId must use 2-64 lowercase letters, digits, or hyphens and start with a letter or digit."
    }

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        if ($DoExecute) {
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
        } else {
            $Root = [System.IO.Path]::GetFullPath($Root)
        }
    }

    if (Test-Path -LiteralPath $Root -PathType Container) {
        $Root = (Resolve-Path -LiteralPath $Root).Path
    }

    $target = Join-Path $Root "morphospace"
    if (Test-Path -LiteralPath $target) {
        throw "Refusing to overwrite existing workspace: $target"
    }

    Write-Host "Project: $Id"
    Write-Host "Target: $target"
    if (-not $DoExecute) {
        Write-Host "Dry run. Re-run with -Execute to create the workspace."
        return $target
    }

    $candidateRoot = Join-Path $target "module-candidates"
    $unitRoot = Join-Path $target "iteration-units"
    $reviewRoot = Join-Path $target "promotion-reviews"
    $receiptRoot = Join-Path $target "receipts"
    foreach ($path in @($target, $candidateRoot, $unitRoot, $reviewRoot, $receiptRoot)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }

    if (-not $ProjectPurpose) {
        $ProjectPurpose = "Describe the project purpose before starting implementation."
    }

    $projectSpec = [ordered]@{
        '$schema' = "$SchemaBase/project-spec.schema.json"
        schema = "rusty.morphospace.workflow.project_spec.v1"
        project_id = $Id
        revision = 1
        purpose = $ProjectPurpose
        activation_model = [ordered]@{
            default = "disabled"
            unlisted_modules = "inert"
        }
        authority_map = @(
            [ordered]@{
                parameter = "project.composition"
                owner = "project-shell"
                adapters = @()
            }
        )
        repositories = @(
            [ordered]@{
                repo_id = "project-shell"
                role = "application"
                path = ".."
                allowed_paths = @("src/", "docs/", "morphospace/")
            }
        )
        modules = @()
        non_scope = @(
            "Modules and features not declared in this specification.",
            "Private evidence outside the declared project boundary."
        )
        validation_profiles = @(
            [ordered]@{
                profile_id = "workflow"
                commands = @(
                    "powershell -NoProfile -ExecutionPolicy Bypass -File <work-environment-root>/scripts/Test-WorkflowContracts.ps1 -WorkspaceRoot <project-root>/morphospace"
                )
            }
        )
        public_boundary = [ordered]@{
            mode = "mixed"
            private_overlay = "local/"
            prohibited_evidence = @(
                "device serials",
                "private package identities",
                "raw logs and captures",
                "signing and pairing material"
            )
        }
    }

    $featureLock = [ordered]@{
        '$schema' = "$SchemaBase/feature-lock.schema.json"
        schema = "rusty.morphospace.workflow.feature_lock.v1"
        project_id = $Id
        revision = 1
        default_activation = "disabled"
        features = @()
    }

    $workspaceState = [ordered]@{
        '$schema' = "$SchemaBase/workspace-state.schema.json"
        schema = "rusty.morphospace.workflow.workspace_state.v1"
        project_id = $Id
        plan_revision = 1
        current_unit = $null
        next_ready_unit = $null
        last_event_id = $null
        dirty_repositories = @()
        blockers = @()
        validation_checkpoint = $null
        pending_push_bundle = $null
    }

    Write-JsonDocument -Path (Join-Path $target "project.spec.json") -Value $projectSpec
    Write-JsonDocument -Path (Join-Path $target "feature.lock.json") -Value $featureLock
    Write-JsonDocument -Path (Join-Path $target "workspace.state.json") -Value $workspaceState
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $target "iteration-events.jsonl"), "", $utf8NoBom)

    $validator = Join-Path $RepoRoot "scripts\Test-WorkflowContracts.ps1"
    & $validator -RepoRoot $RepoRoot -WorkspaceRoot $target
    Write-Host "Created project workspace: $target"
    return $target
}

function Invoke-ScaffoldSelfTest {
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $testRoot = Join-Path $tempBase ("rusty-morphospace-scaffold-" + [guid]::NewGuid().ToString("N"))
    $projectRoot = Join-Path $testRoot "project"
    $created = $null
    try {
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        $created = New-ProjectWorkspaceInternal -Root $projectRoot -Id "self-test-project" -ProjectPurpose "Exercise portable workspace scaffolding." -DoExecute $true

        foreach ($relative in @(
            "project.spec.json",
            "feature.lock.json",
            "workspace.state.json",
            "iteration-events.jsonl",
            "module-candidates",
            "iteration-units",
            "promotion-reviews",
            "receipts"
        )) {
            $path = Join-Path $created $relative
            if (-not (Test-Path -LiteralPath $path)) {
                throw "Scaffold self-test did not create: $relative"
            }
        }

        $overwriteBlocked = $false
        try {
            New-ProjectWorkspaceInternal -Root $projectRoot -Id "self-test-project" -ProjectPurpose "Must not overwrite." -DoExecute $true | Out-Null
        } catch {
            if ($_.Exception.Message -like "Refusing to overwrite existing workspace:*") {
                $overwriteBlocked = $true
            } else {
                throw
            }
        }
        if (-not $overwriteBlocked) {
            throw "Scaffold self-test expected overwrite protection."
        }

        Write-Host "Project workspace scaffold self-test passed."
    } finally {
        if (Test-Path -LiteralPath $testRoot) {
            $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
            if (-not $resolvedTestRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to clean self-test path outside the system temporary directory."
            }
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    }
}

if ($SelfTest) {
    Invoke-ScaffoldSelfTest
    exit 0
}

if (-not $ProjectRoot) {
    throw "ProjectRoot is required unless -SelfTest is used."
}
if (-not $ProjectId) {
    throw "ProjectId is required unless -SelfTest is used."
}

New-ProjectWorkspaceInternal -Root $ProjectRoot -Id $ProjectId -ProjectPurpose $Purpose -DoExecute $Execute.IsPresent | Out-Null
