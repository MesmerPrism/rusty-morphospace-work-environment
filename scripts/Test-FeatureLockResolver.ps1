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
    # The retained native initial golden lock uses a legacy ordered fingerprint. Public
    # protocol serialization sorts its object keys but preserves its meaning.
    $initialPath=Join-Path $RepoRoot 'examples/hello-morphospace-v2/morphospace/feature.lock.json'
    $initialRaw=Get-MorphospaceFileSha256 $initialPath
    $initial=Read-MorphospaceProtocolJson $initialPath
    $initialBefore=$initial|ConvertTo-Json -Depth 48 -Compress
    Assert-FeatureLock ([string]$initial.lock_fingerprint-ceq'7811b69fc171fd85dc4214da62618bcbdc02ad7d3b1e9eb430317fe4025be8d4'-and($initial.PSObject.Properties.Name-join',')-ceq'$schema,schema,project_id,project_revision,revision,generated_at,resolver_version,lock_fingerprint,default_activation,activation_rule,selected_features,denied_features,features,effect_union') 'initial golden producer identity or field order changed'
    Assert-FeatureLock (Test-MorphospaceFeatureLockFingerprint $initial) 'initial golden producer fingerprint'
    $roundtrip=ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $initial)
    $roundtripBefore=$roundtrip|ConvertTo-Json -Depth 48 -Compress
    Assert-FeatureLock ((Get-MorphospaceCanonicalJsonSha256 $roundtrip)-ceq(Get-MorphospaceCanonicalJsonSha256 $initial)) 'initial roundtrip changed canonical identity'
    Assert-FeatureLock (Test-MorphospaceFeatureLockFingerprint $roundtrip) 'canonical roundtrip of native initial legacy fingerprint'
    $initialCases=@('fake-hash','schema','project-id','project-revision','revision','timestamp','resolver','activation','selected','denied','features','null-selected','null-effects','missing-root','extra-root','missing-effect','extra-effect')
    $initialAxes=@('permissions','services','activities','queries','tools','assets','shaders','native_libraries','commands','routes','streams','inputs','scenes','markers')
    foreach($case in @($initialCases)+@($initialAxes|ForEach-Object{'effect-'+$_})){
        $damaged=ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $roundtrip)
        switch($case){
            'fake-hash'{$damaged.lock_fingerprint='0'*64}
            'schema'{$damaged.schema='rusty.morphospace.workflow.feature_lock.v3'}
            'project-id'{$damaged.project_id='other-initial-project'}
            'project-revision'{$damaged.project_revision=2}
            'revision'{$damaged.revision=2}
            'timestamp'{$damaged.generated_at='1970-01-01T00:00:01Z'}
            'resolver'{$damaged.resolver_version='rusty-morphospace-feature-resolver/3'}
            'activation'{$damaged.default_activation='enabled'}
            'selected'{$damaged.selected_features=@('unexpected-feature')}
            'denied'{$damaged.denied_features=@('unexpected-feature')}
            'features'{$damaged.features=@([pscustomobject]@{feature_id='unexpected-feature'})}
            'null-selected'{$damaged.selected_features=$null}
            'null-effects'{$damaged.effect_union.permissions=$null}
            'missing-root'{$damaged.PSObject.Properties.Remove('denied_features')}
            'extra-root'{$damaged|Add-Member unexpected 'value'}
            'missing-effect'{$damaged.effect_union.PSObject.Properties.Remove('markers')}
            'extra-effect'{$damaged.effect_union|Add-Member unexpected @()}
            default{$damaged.effect_union.($case.Substring(7))=@('unexpected-effect')}
        }
        $damageBefore=$damaged|ConvertTo-Json -Depth 48 -Compress
        Assert-FeatureLock (-not(Test-MorphospaceFeatureLockFingerprint $damaged)) "initial finite codec accepted stale damaged payload: $case"
        Assert-FeatureLock (($damaged|ConvertTo-Json -Depth 48 -Compress)-ceq$damageBefore) "initial codec mutated rejected input: $case"
    }
    foreach($case in @('later-revision','invalid-project-id','null-project-id','numeric-project-id')){
        $outside=$initial|ConvertTo-Json -Depth 48|ConvertFrom-Json -DateKind String
        switch($case){
            'later-revision'{$outside.revision=2}
            'invalid-project-id'{$outside.project_id='Invalid_ID'}
            'null-project-id'{$outside.project_id=$null}
            'numeric-project-id'{$outside.project_id=42}
        }
        $outside.lock_fingerprint='0'*64
        $legacyCopy=$outside|ConvertTo-Json -Depth 48|ConvertFrom-Json
        $outside.lock_fingerprint=Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($legacyCopy|ConvertTo-Json -Depth 48 -Compress)))
        Assert-FeatureLock (Test-MorphospaceFeatureLockFingerprint $outside) "existing observed-order legacy verification changed: $case"
        $sortedOutside=ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $outside)
        $outsideBefore=$sortedOutside|ConvertTo-Json -Depth 48 -Compress
        Assert-FeatureLock (-not(Test-MorphospaceFeatureLockFingerprint $sortedOutside)) "finite initial codec accepted correctly legacy-hashed nonproducer shape: $case"
        Assert-FeatureLock (($sortedOutside|ConvertTo-Json -Depth 48 -Compress)-ceq$outsideBefore) "finite codec mutated nonproducer shape: $case"
    }
    $canonicalNonempty=ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $initial)
    $canonicalNonempty.selected_features=@('canonical-feature')
    $canonicalNonempty.lock_fingerprint=Get-MorphospaceFeatureLockFingerprint $canonicalNonempty
    Assert-FeatureLock (Test-MorphospaceFeatureLockFingerprint $canonicalNonempty) 'canonical fingerprint behavior outside initial featureless codec changed'
    Assert-FeatureLock (($roundtrip|ConvertTo-Json -Depth 48 -Compress)-ceq$roundtripBefore-and($initial|ConvertTo-Json -Depth 48 -Compress)-ceq$initialBefore-and(Get-MorphospaceFileSha256 $initialPath)-ceq$initialRaw) 'initial codec mutated input order or native golden producer file'

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

    foreach ($timestamp in @('2026-01-02T03:04:05.1234000Z','2026-01-02T04:04:05+01:00')) {
        $candidate=Read-MorphospaceProtocolJson $lockPath
        $candidate.generated_at=$timestamp
        $candidate.lock_fingerprint=Get-MorphospaceFeatureLockFingerprint $candidate
        $candidatePath=Join-Path $root 'timestamp-lock.json'
        Write-Json $candidatePath $candidate
        $before=Get-MorphospaceFileSha256 $candidatePath
        $decision=& (Join-Path $PSScriptRoot 'Test-FeatureActivationAgainstLock.ps1') -LockPath $candidatePath -FeatureId 'feature-app' -RuntimeInput 'profile:conformance'
        Assert-FeatureLock ($decision.accepted-and$before-ceq(Get-MorphospaceFileSha256 $candidatePath)) 'canonical timestamp spelling or validation immutability'
        $legacy=$candidate|ConvertTo-Json -Depth 48|ConvertFrom-Json
        $legacy.lock_fingerprint='0'*64
        $candidate.lock_fingerprint=Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($legacy|ConvertTo-Json -Depth 48 -Compress)))
        Write-Json $candidatePath $candidate
        $decision=& (Join-Path $PSScriptRoot 'Test-FeatureActivationAgainstLock.ps1') -LockPath $candidatePath -FeatureId 'feature-app' -RuntimeInput 'profile:conformance'
        Assert-FeatureLock $decision.accepted 'existing resolver fingerprint rejected'
        $candidate.selected_features+=,'tampered-feature'
        Assert-FeatureLock (-not(Test-MorphospaceFeatureLockFingerprint $candidate)) 'changed legacy payload accepted'
    }

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
