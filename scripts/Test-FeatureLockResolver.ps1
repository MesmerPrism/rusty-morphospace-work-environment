param()

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$root = Join-Path $tempBase ("rusty-morphospace-feature-lock-" + [guid]::NewGuid().ToString("N"))
$encoding = New-Object System.Text.UTF8Encoding($false)

function Write-Json {
    param([string]$Path, [object]$Value)
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 48) + [Environment]::NewLine), $encoding)
}

function Assert-FeatureLock {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Feature-lock resolver self-test failed: $Message" }
}

function New-Descriptor {
    param([string]$FeatureId, [string]$ModuleId, [string[]]$Dependencies, [string]$Parameter, [string]$RuntimeInput)
    return [ordered]@{
        '$schema' = (Join-Path $RepoRoot "schemas\feature-descriptor.schema.json")
        schema = "rusty.morphospace.workflow.feature_descriptor.v1"
        feature_id = $FeatureId; module_id = $ModuleId; version = "0.2.0"; owner_lane = "matter"
        source = [ordered]@{ repo_id = "matter-core"; revision = ("1" * 40); path = "crates/$ModuleId"; sha256 = ("2" * 64) }
        dependencies = @($Dependencies); conflicts = @(); exclusive_group = $null
        effects = [ordered]@{
            permissions = @(); services = @(); activities = @(); queries = @(); tools = @(); assets = @()
            shaders = @(); native_libraries = @(); commands = @(); routes = @(); streams = @(); inputs = @()
            scenes = @(); markers = @("rusty.$FeatureId.effective")
        }
        parameter_authorities = @([ordered]@{ parameter = $Parameter; owner = "matter" })
        activation = [ordered]@{
            rule = "selected-lock-and-runtime-input"; runtime_inputs = @($RuntimeInput)
            receipt_schema = "rusty.matter.$FeatureId.activation_receipt.v1"
            effective_marker = "rusty.matter.$FeatureId.effective"
        }
        validation_profile = "workflow"; rollback_profile = "rollback"
    }
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $projectRoot = Join-Path $root "project"
    $descriptorRoot = Join-Path $projectRoot "features"
    New-Item -ItemType Directory -Path $descriptorRoot -Force | Out-Null
    $kernelPath = Join-Path $descriptorRoot "kernel.json"
    $appPath = Join-Path $descriptorRoot "app.json"
    Write-Json -Path $kernelPath -Value (New-Descriptor -FeatureId "feature-kernel" -ModuleId "module-kernel" -Dependencies @() -Parameter "feature-kernel.step-rate" -RuntimeInput "profile:kernel")
    Write-Json -Path $appPath -Value (New-Descriptor -FeatureId "feature-app" -ModuleId "module-app" -Dependencies @("feature-kernel") -Parameter "feature-app.enabled" -RuntimeInput "profile:conformance")

    $project = [ordered]@{
        '$schema' = (Join-Path $RepoRoot "schemas\project-spec-v2.schema.json")
        schema = "rusty.morphospace.workflow.project_spec.v2"
        project_id = "feature-lock-test"; revision = 2; owner = "workflow-self-test"; purpose = "Prove closed-world lock generation."
        activation_model = [ordered]@{ default = "disabled"; unlisted_modules = "inert"; runtime_rule = "selected-lock-and-runtime-input" }
        composition = [ordered]@{
            selected_features = @("feature-app"); denied_features = @("feature-denied")
            selected_modules = @("module-app", "module-kernel"); denied_modules = @("module-denied")
            allowed_permissions = @(); denied_permissions = @("android.permission.CAMERA"); data_classes = @("public-test-data")
        }
        authority_map = @(
            [ordered]@{ parameter = "feature-kernel.step-rate"; owner = "matter"; adapters = @("project-shell") },
            [ordered]@{ parameter = "feature-app.enabled"; owner = "matter"; adapters = @("project-shell") }
        )
        repositories = @(
            [ordered]@{ repo_id = "project-shell"; role = "application"; path = ".."; allowed_paths = @("src/", "morphospace/") },
            [ordered]@{ repo_id = "matter-core"; role = "core"; path = "<matter>"; allowed_paths = @("crates/", "fixtures/") }
        )
        modules = @(
            [ordered]@{ module_id = "module-app"; feature_id = "feature-app"; lane = "matter"; maturity = "candidate"; contract = "rusty.matter.feature-app.v1"; contract_revision = "0.2.0"; source_repo = "matter-core"; dependencies = @("module-kernel"); selected = $true },
            [ordered]@{ module_id = "module-kernel"; feature_id = "feature-kernel"; lane = "matter"; maturity = "candidate"; contract = "rusty.matter.feature-kernel.v1"; contract_revision = "0.2.0"; source_repo = "matter-core"; dependencies = @(); selected = $true }
        )
        non_scope = @("Undeclared features and ambient permissions.")
        validation_profiles = @([ordered]@{ profile_id = "workflow"; commands = @("Test-FeatureLockResolver.ps1") })
        acceptance_profiles = @([ordered]@{ profile_id = "rollback"; commands = @("disable the feature and verify no effects") })
        release_policy = [ordered]@{ versioning = "semver"; commit_policy = "validated slices"; push_checkpoint = "integration-batch"; source_first = $true; planning_last = $true; force_push_allowed = $false }
        public_boundary = [ordered]@{ mode = "public"; private_overlay = "local/"; prohibited_evidence = @("device serials") }
    }
    $projectPath = Join-Path $projectRoot "project.spec.json"
    $lockPath = Join-Path $projectRoot "feature.lock.json"
    Write-Json -Path $projectPath -Value $project
    & (Join-Path $PSScriptRoot "Resolve-FeatureLock.ps1") -ProjectSpecPath $projectPath -DescriptorPaths @($kernelPath, $appPath) -OutPath $lockPath -LockRevision 3 -GeneratedAt "2026-01-02T03:04:05Z" -Execute | Out-Null
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    Assert-FeatureLock ($lock.schema -eq "rusty.morphospace.workflow.feature_lock.v2") "schema"
    Assert-FeatureLock ((@($lock.selected_features) -join ",") -eq "feature-app,feature-kernel") "dependency closure"
    Assert-FeatureLock ($lock.default_activation -eq "disabled" -and $lock.activation_rule -eq "selected-lock-and-runtime-input") "activation rule"
    Assert-FeatureLock (@($lock.effect_union.markers).Count -eq 2) "effect union"
    Assert-FeatureLock ((@($lock.features | ForEach-Object { [string]$_.descriptor.path }) -join ",") -eq "features/app.json,features/kernel.json") "portable descriptor paths"
    Assert-FeatureLock (@($lock.features | Where-Object { [string]$_.descriptor.path -match "^[A-Za-z]:/|^/|\\|(^|/)\.\.?($|/)" }).Count -eq 0) "descriptor path boundary"

    $mirrorRoot = Join-Path $root "mirror"
    $mirrorDescriptorRoot = Join-Path $mirrorRoot "features"
    New-Item -ItemType Directory -Path $mirrorDescriptorRoot -Force | Out-Null
    $mirrorKernelPath = Join-Path $mirrorDescriptorRoot "kernel.json"
    $mirrorAppPath = Join-Path $mirrorDescriptorRoot "app.json"
    $mirrorProjectPath = Join-Path $mirrorRoot "project.spec.json"
    $mirrorLockPath = Join-Path $mirrorRoot "feature.lock.json"
    Write-Json -Path $mirrorKernelPath -Value (New-Descriptor -FeatureId "feature-kernel" -ModuleId "module-kernel" -Dependencies @() -Parameter "feature-kernel.step-rate" -RuntimeInput "profile:kernel")
    Write-Json -Path $mirrorAppPath -Value (New-Descriptor -FeatureId "feature-app" -ModuleId "module-app" -Dependencies @("feature-kernel") -Parameter "feature-app.enabled" -RuntimeInput "profile:conformance")
    Write-Json -Path $mirrorProjectPath -Value $project
    & (Join-Path $PSScriptRoot "Resolve-FeatureLock.ps1") -ProjectSpecPath $mirrorProjectPath -DescriptorPaths @($mirrorKernelPath, $mirrorAppPath) -OutPath $mirrorLockPath -LockRevision 3 -GeneratedAt "2026-01-02T03:04:05Z" -Execute | Out-Null
    $mirrorLock = Get-Content -LiteralPath $mirrorLockPath -Raw | ConvertFrom-Json
    Assert-FeatureLock ($mirrorLock.lock_fingerprint -eq $lock.lock_fingerprint) "location-independent fingerprint"

    $outsidePath = Join-Path $root "outside.json"
    Write-Json -Path $outsidePath -Value (New-Descriptor -FeatureId "feature-kernel" -ModuleId "module-kernel" -Dependencies @() -Parameter "feature-kernel.step-rate" -RuntimeInput "profile:kernel")
    $outsideRejected = $false
    try { & (Join-Path $PSScriptRoot "Resolve-FeatureLock.ps1") -ProjectSpecPath $projectPath -DescriptorPaths @($outsidePath, $appPath) -LockRevision 3 -GeneratedAt "2026-01-02T03:04:05Z" | Out-Null }
    catch { $outsideRejected = $_.Exception.Message -like "Feature descriptor must be inside the project workspace:*" }
    Assert-FeatureLock $outsideRejected "descriptor outside project boundary"

    $accepted = & (Join-Path $PSScriptRoot "Test-FeatureActivationAgainstLock.ps1") -LockPath $lockPath -FeatureId "feature-app" -RuntimeInput "profile:conformance" -ExpectedFingerprint $lock.lock_fingerprint
    Assert-FeatureLock ($accepted.accepted -eq $true -and $accepted.lock_revision -eq 3) "selected runtime activation"
    $absentRejected = $false
    try { & (Join-Path $PSScriptRoot "Test-FeatureActivationAgainstLock.ps1") -LockPath $lockPath -FeatureId "feature-denied" -RuntimeInput "profile:conformance" | Out-Null }
    catch { $absentRejected = $_.Exception.Message -like "Feature 'feature-denied' is absent*" }
    Assert-FeatureLock $absentRejected "off-lock activation"
    $wrongInputRejected = $false
    try { & (Join-Path $PSScriptRoot "Test-FeatureActivationAgainstLock.ps1") -LockPath $lockPath -FeatureId "feature-app" -RuntimeInput "property:ambient" | Out-Null }
    catch { $wrongInputRejected = $_.Exception.Message -like "Runtime input 'property:ambient' is not accepted*" }
    Assert-FeatureLock $wrongInputRejected "ambient runtime input"

    $damaged = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $damaged.effect_union.permissions = @("android.permission.CAMERA")
    Write-Json -Path $lockPath -Value $damaged
    $fingerprintRejected = $false
    try { & (Join-Path $PSScriptRoot "Test-FeatureActivationAgainstLock.ps1") -LockPath $lockPath -FeatureId "feature-app" -RuntimeInput "profile:conformance" | Out-Null }
    catch { $fingerprintRejected = $_.Exception.Message -eq "Feature lock fingerprint is stale or damaged." }
    Assert-FeatureLock $fingerprintRejected "stale fingerprint"
    Write-Host "Feature-lock resolver self-test passed."
} finally {
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if (-not $resolved.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to clean outside temp." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
