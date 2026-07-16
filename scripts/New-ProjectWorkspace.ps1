param(
    [string]$ProjectRoot = "",
    [string]$ProjectId = "",
    [string]$Purpose = "",
    [ValidateSet("1", "2")][string]$ProtocolVersion = "2",
    [string]$SchemaRevision = "",
    [switch]$Execute,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not $SchemaRevision) {
    try {
        $SchemaRevision = ([string](& git -C $RepoRoot rev-parse HEAD 2>$null)).Trim()
    } catch {
        $SchemaRevision = "main"
    }
}
if (-not ($SchemaRevision -match "^([0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+|main)$")) {
    throw "SchemaRevision must be a full Git commit, a vMAJOR.MINOR.PATCH tag, or main."
}
$SchemaBase = "https://raw.githubusercontent.com/MesmerPrism/rusty-morphospace-work-environment/$SchemaRevision/schemas"

function Write-JsonDocument {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Get-LockFingerprint {
    param([object]$Lock)
    $copy = ($Lock | ConvertTo-Json -Depth 48 | ConvertFrom-Json)
    $copy.lock_fingerprint = "0" * 64
    $json = $copy | ConvertTo-Json -Depth 48 -Compress
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $sha.Dispose() }
}

function New-ProjectWorkspaceInternal {
    param(
        [string]$Root,
        [string]$Id,
        [string]$ProjectPurpose,
        [string]$Version,
        [bool]$DoExecute
    )

    if (-not ($Id -match "^[a-z0-9][a-z0-9-]{1,127}$")) {
        throw "ProjectId must use 2-128 lowercase letters, digits, or hyphens and start with a letter or digit."
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
    $extractionRoot = Join-Path $target "module-extraction-receipts"
    $unitRoot = Join-Path $target "iteration-units"
    $reviewRoot = Join-Path $target "promotion-reviews"
    $receiptRoot = Join-Path $target "receipts"
    $compositionRoot = Join-Path $target "source-compositions"
    foreach ($path in @($target, $candidateRoot, $extractionRoot, $unitRoot, $reviewRoot, $receiptRoot, $compositionRoot)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }

    if (-not $ProjectPurpose) {
        $ProjectPurpose = "Describe the project purpose before starting implementation."
    }

    $projectSpecV1 = [ordered]@{
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
                    "pwsh -NoProfile -ExecutionPolicy Bypass -File <work-environment-root>/scripts/Test-WorkflowContracts.ps1 -WorkspaceRoot <project-root>/morphospace"
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

    $featureLockV1 = [ordered]@{
        '$schema' = "$SchemaBase/feature-lock.schema.json"
        schema = "rusty.morphospace.workflow.feature_lock.v1"
        project_id = $Id
        revision = 1
        default_activation = "disabled"
        features = @()
    }

    $workspaceStateV1 = [ordered]@{
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

    if ($Version -eq "2") {
        $projectSpec = [ordered]@{
            '$schema' = "$SchemaBase/project-spec-v2.schema.json"
            schema = "rusty.morphospace.workflow.project_spec.v2"
            project_id = $Id
            revision = 1
            owner = "project-owner"
            purpose = $ProjectPurpose
            activation_model = [ordered]@{
                default = "disabled"
                unlisted_modules = "inert"
                runtime_rule = "selected-lock-and-runtime-input"
            }
            composition = [ordered]@{
                selected_features = @()
                denied_features = @()
                selected_modules = @()
                denied_modules = @()
                allowed_permissions = @()
                denied_permissions = @()
                data_classes = @()
            }
            authority_map = @([ordered]@{ parameter = "project.composition"; owner = "project-shell"; adapters = @() })
            repositories = @([ordered]@{ repo_id = "project-shell"; role = "application"; path = ".."; allowed_paths = @("src/", "docs/", "morphospace/") })
            modules = @()
            non_scope = @(
                "Modules and features not declared in this specification.",
                "Private evidence outside the declared project boundary."
            )
            validation_profiles = @([ordered]@{
                profile_id = "workflow"
                commands = @("pwsh -NoProfile -ExecutionPolicy Bypass -File <work-environment-root>/scripts/Test-WorkflowContracts.ps1 -WorkspaceRoot <project-root>/morphospace")
            })
            acceptance_profiles = @([ordered]@{
                profile_id = "rollback"
                commands = @("Disable selected conformance features and verify the effect union is absent.")
            })
            release_policy = [ordered]@{
                versioning = "semver"
                commit_policy = "Commit coherent validated slices locally and use declared push checkpoints."
                push_checkpoint = "integration-batch"
                source_first = $true
                planning_last = $true
                force_push_allowed = $false
            }
            public_boundary = $projectSpecV1.public_boundary
        }
        $featureLock = [ordered]@{
            '$schema' = "$SchemaBase/feature-lock-v2.schema.json"
            schema = "rusty.morphospace.workflow.feature_lock.v2"
            project_id = $Id
            project_revision = 1
            revision = 1
            generated_at = "1970-01-01T00:00:00Z"
            resolver_version = "rusty-morphospace-feature-resolver/2"
            lock_fingerprint = "0" * 64
            default_activation = "disabled"
            activation_rule = "selected-lock-and-runtime-input"
            selected_features = @()
            denied_features = @()
            features = @()
            effect_union = [ordered]@{
                permissions = @(); services = @(); activities = @(); queries = @(); tools = @(); assets = @()
                shaders = @(); native_libraries = @(); commands = @(); routes = @(); streams = @(); inputs = @()
                scenes = @(); markers = @()
            }
        }
        $featureLock.lock_fingerprint = Get-LockFingerprint -Lock $featureLock
        $workspaceState = [ordered]@{
            '$schema' = "$SchemaBase/workspace-state-v2.schema.json"
            schema = "rusty.morphospace.workflow.workspace_state.v2"
            project_id = $Id
            plan_revision = 1
            current_unit = $null
            next_ready_unit = $null
            last_event_id = $null
            last_accepted_receipt = $null
            repository_heads = @()
            repository_checkpoints = @()
            module_registry = [ordered]@{ lock_revision = 1; lock_fingerprint = $featureLock.lock_fingerprint; modules = @() }
            capability_registry = @()
            dirty_repositories = @()
            blockers = @()
            validation_checkpoint = $null
            pending_push_bundle = $null
        }
    } else {
        $projectSpec = $projectSpecV1
        $featureLock = $featureLockV1
        $workspaceState = $workspaceStateV1
    }

    Write-JsonDocument -Path (Join-Path $target "project.spec.json") -Value $projectSpec
    Write-JsonDocument -Path (Join-Path $target "feature.lock.json") -Value $featureLock
    Write-JsonDocument -Path (Join-Path $target "workspace.state.json") -Value $workspaceState
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $target "iteration-events.jsonl"), "", $utf8NoBom)

    $readme = @"
# $Id Morphospace Workspace

This directory was generated from Rusty Morphospace Work Environment protocol
v$Version at schema revision $SchemaRevision.

Start here:

1. Review project.spec.json and replace the placeholder purpose and repository scope.
2. Keep feature.lock.json inert until descriptors have been reviewed and resolved.
3. Add a proposed unit under iteration-units/; do not hand-edit workflow state transitions.
4. Validate from the work-environment clone:

   ``pwsh -NoProfile -ExecutionPolicy Bypass -File <work-environment-root>/scripts/Test-WorkflowContracts.ps1 -WorkspaceRoot <project-root>/morphospace``

The portable protocol guide is docs/PROJECT_WORKSPACE_PROTOCOL.md in the
work-environment repository. Keep machine paths and private evidence outside
tracked files.
"@
    [System.IO.File]::WriteAllText((Join-Path $target "README.md"), $readme.Trim() + [Environment]::NewLine, $utf8NoBom)

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
        $created = New-ProjectWorkspaceInternal -Root $projectRoot -Id "self-test-project" -ProjectPurpose "Exercise portable workspace scaffolding." -Version "2" -DoExecute $true

        foreach ($relative in @(
            "project.spec.json",
            "feature.lock.json",
            "workspace.state.json",
            "iteration-events.jsonl",
            "README.md",
            "module-candidates",
            "module-extraction-receipts",
            "iteration-units",
            "promotion-reviews",
            "receipts",
            "source-compositions"
        )) {
            $path = Join-Path $created $relative
            if (-not (Test-Path -LiteralPath $path)) {
                throw "Scaffold self-test did not create: $relative"
            }
        }

        $spec = Get-Content -Raw -LiteralPath (Join-Path $created "project.spec.json") | ConvertFrom-Json
        if (-not ([string]$spec.'$schema').StartsWith("https://raw.githubusercontent.com/", [System.StringComparison]::Ordinal)) {
            throw "Scaffold self-test expected a raw-content schema URL."
        }
        if ([string]$spec.'$schema' -notmatch "/([0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+|main)/schemas/") {
            throw "Scaffold self-test expected a revision-pinned schema URL."
        }

        $overwriteBlocked = $false
        try {
            New-ProjectWorkspaceInternal -Root $projectRoot -Id "self-test-project" -ProjectPurpose "Must not overwrite." -Version "2" -DoExecute $true | Out-Null
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

New-ProjectWorkspaceInternal -Root $ProjectRoot -Id $ProjectId -ProjectPurpose $Purpose -Version $ProtocolVersion -DoExecute $Execute.IsPresent | Out-Null
