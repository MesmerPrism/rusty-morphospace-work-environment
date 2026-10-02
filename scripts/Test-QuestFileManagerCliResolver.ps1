param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$resolver = Join-Path $RepoRoot "scripts\Resolve-QuestFileManagerCli.ps1"
$deployment = Join-Path $RepoRoot "scripts\Invoke-QuestFileManagerDeployment.ps1"
$hostExecutable = (Get-Process -Id $PID).Path
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("rusty-morphospace-qfm-resolver-" + [guid]::NewGuid().ToString("N"))
$configPath = Join-Path $testRoot "resolver.json"
$fixtureExecutable = Join-Path $testRoot "questionable-file-manager.exe"
$fixtureSibling = Join-Path $testRoot "runtime\hostfxr.dll"
$invalidExtensionFixture = Join-Path $testRoot "questionable-file-manager.bin"

function Write-JsonUtf8NoBom {
    param([string]$Path, [object]$Value)

    $json = $Value | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
}

function Get-DistributionManifestSha256 {
    param([string]$EntryPoint, [object[]]$Files)
    $lines = @("rusty.morphospace.quest_file_manager_distribution_manifest.v1", "entry_point=$EntryPoint")
    foreach ($file in @($Files | Sort-Object relative_path)) {
        $lines += "file=$($file.relative_path)`t$($file.size_bytes)`t$($file.sha256)"
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($lines -join "`n") + "`n"))
    try { return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Invoke-ResolverChild {
    param([int]$ExpectedExit)

    $output = @(
        & $hostExecutable -NoProfile -ExecutionPolicy Bypass `
            -File $resolver `
            -RepoRoot $RepoRoot `
            -ConfigPath $configPath `
            -SkipExecutableProbe `
            -Json 2>&1
    )
    if ($LASTEXITCODE -ne $ExpectedExit) {
        throw "Resolver exit $LASTEXITCODE; expected $ExpectedExit. Output: $($output -join ' | ')"
    }
    return ($output -join [Environment]::NewLine)
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $fixtureBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
        "portable Quest File Manager resolver fixture`n")
    [System.IO.File]::WriteAllBytes($fixtureExecutable, $fixtureBytes)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fixtureSibling) | Out-Null
    [System.IO.File]::WriteAllBytes($fixtureSibling, [byte[]](1, 2, 3, 4))
    [System.IO.File]::WriteAllBytes($invalidExtensionFixture, $fixtureBytes)
    $fixtureSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixtureExecutable).Hash.ToLowerInvariant()
    $distributionFiles = @($fixtureExecutable, $fixtureSibling | ForEach-Object { $_ }) | ForEach-Object {
        [pscustomobject]@{
            relative_path = [System.IO.Path]::GetRelativePath($testRoot, $_).Replace('\\', '/')
            size_bytes = (Get-Item -LiteralPath $_).Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()
        }
    }
    $config = [ordered]@{
        schema = "rusty.morphospace.local_quest_file_manager_cli.v4"
        provider_id = "file-manager-local"
        runtime_root = $testRoot
        entry_point_relative_path = "questionable-file-manager.exe"
        distribution_manifest_sha256 = Get-DistributionManifestSha256 -EntryPoint "questionable-file-manager.exe" -Files $distributionFiles
        distribution_files = $distributionFiles
        source_kind = "source-build"
        source_version = "0.1.0-dev"
        source_revision = ("a" * 40)
        source_tree = ("b" * 40)
        inspected_deployment_contract = "questionable.file_manager.inspected_deployment.v5"
        apk_preflight_result_contract = "questionable.file_manager.apk_preflight_result.v1"
        apk_deploy_result_contract = "questionable.file_manager.apk_deploy_result.v1"
        apk_diagnostic_result_contract = "questionable.file_manager.apk_diagnostic_result.v3"
        apk_diagnostic_bundle_contract = "questionable.file_manager.apk_diagnostic_bundle.v3"
        apk_stop_result_contract = "questionable.file_manager.apk_stop_result.v1"
        apk_permission_observation_contract = "questionable.file_manager.apk_permission_observation.v1"
        adb_forward_inventory_result_contract = "questionable.file_manager.adb_forward_inventory_result.v1"
        apk_launch_result_contract = "questionable.file_manager.apk_launch_result.v1"
        launcher_export_proof_contract = "questionable.file_manager.launcher_export_proof.v2"
        runtime_observation_contract = "questionable.file_manager.app_runtime_observation.v5"
        global_focus_observation_contract = "questionable.file_manager.android_global_focus_observation.v1"
    }
    Write-JsonUtf8NoBom -Path $configPath -Value $config

    $result = Invoke-ResolverChild -ExpectedExit 0 | ConvertFrom-Json
    if ($result.status -cne "ready" -or
        $result.provider_id -cne "file-manager-local" -or
        $result.identity_probe -cne "skipped" -or
        $result.command_probe -cne "skipped" -or
        $result.executable_sha256 -cne $fixtureSha256 -or
        $result.apk_permission_observation_contract -cne "questionable.file_manager.apk_permission_observation.v1") {
        throw "Resolver did not return the expected hash-pinned ready result."
    }

    $config.distribution_files[0].sha256 = ("0" * 64)
    Write-JsonUtf8NoBom -Path $configPath -Value $config
    Invoke-ResolverChild -ExpectedExit 1 | Out-Null

    $config.distribution_files[0].sha256 = $fixtureSha256
    $config.apk_launch_result_contract = "questionable.file_manager.apk_launch_result.v0"
    Write-JsonUtf8NoBom -Path $configPath -Value $config
    Invoke-ResolverChild -ExpectedExit 1 | Out-Null

    $config.apk_launch_result_contract = "questionable.file_manager.apk_launch_result.v1"
    $config.apk_permission_observation_contract = "questionable.file_manager.apk_permission_observation.v0"
    Write-JsonUtf8NoBom -Path $configPath -Value $config
    Invoke-ResolverChild -ExpectedExit 1 | Out-Null

    $config.apk_permission_observation_contract = "questionable.file_manager.apk_permission_observation.v1"
    $config.apk_deploy_result_contract = 'questionable.file_manager.apk_deploy_result.v0'
    Write-JsonUtf8NoBom -Path $configPath -Value $config
    Invoke-ResolverChild -ExpectedExit 1 | Out-Null
    $config.Remove('apk_deploy_result_contract')
    Write-JsonUtf8NoBom -Path $configPath -Value $config
    Invoke-ResolverChild -ExpectedExit 1 | Out-Null
    $config.apk_deploy_result_contract = 'questionable.file_manager.apk_deploy_result.v1'
    $config.executable_path = $invalidExtensionFixture
    Write-JsonUtf8NoBom -Path $configPath -Value $config
    Invoke-ResolverChild -ExpectedExit 1 | Out-Null

    $config.executable_path = $fixtureExecutable
    $config.extra = "not-allowed"
    Write-JsonUtf8NoBom -Path $configPath -Value $config
    Invoke-ResolverChild -ExpectedExit 1 | Out-Null

    if ($IsWindows) {
        # Run the production target-free executable probe, not the inert-byte
        # path above. The fixture admits only help and operator-actions.
        $probeProject = Join-Path $testRoot 'probe-project'
        $probeRuntime = Join-Path $testRoot 'probe-runtime'
        New-Item -ItemType Directory -Path $probeProject, $probeRuntime | Out-Null
        $sdkVersion = ([string](& dotnet --version)).Trim()
        if ($LASTEXITCODE -ne 0 -or $sdkVersion -notmatch '^(\d+)\.') { throw 'Probe fixture needs the installed .NET SDK.' }
        $targetFramework = "net$($Matches[1]).0"
        [IO.File]::WriteAllText((Join-Path $probeProject 'NuGet.Config'), '<configuration><packageSources><clear /></packageSources></configuration>')
        [IO.File]::WriteAllText((Join-Path $probeProject 'Fixture.csproj'), @"
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>$targetFramework</TargetFramework><AssemblyName>questionable-file-manager</AssemblyName><Company>Mesmer Prism</Company><Product>questionable-file-manager</Product><Version>0.1.0-dev</Version><InformationalVersion>0.1.0-dev+$('a' * 40)</InformationalVersion><AppendSourceRevisionToInformationalVersion>false</AppendSourceRevisionToInformationalVersion></PropertyGroup></Project>
"@)
        [IO.File]::WriteAllText((Join-Path $probeProject 'Program.cs'), @'
using System;
using System.IO;
File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "..", "probe-calls.txt"), string.Join("|", args) + "\n");
if (args.Length == 1 && args[0] == "--help") {
 Console.WriteLine("apk preflight --serial\napk deploy --serial\napk diagnose --serial\napk stop --serial\napk permissions --serial\nadb forwards --serial");
} else if (args.Length == 2 && args[0] == "operator-actions" && args[1] == "--json") {
 Console.WriteLine(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "contracts.json")));
} else { Environment.Exit(19); }
'@)
        $buildLog = Join-Path $testRoot 'probe-build.log'
        & dotnet build (Join-Path $probeProject 'Fixture.csproj') --nologo --configuration Release --output $probeRuntime *> $buildLog
        if ($LASTEXITCODE -ne 0) { throw "Target-free probe fixture build failed; see $buildLog" }
        $probeConfig = $config | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $probeConfig.PSObject.Properties.Remove('extra')
        $probeConfig.PSObject.Properties.Remove('executable_path')
        $probeConfig.runtime_root = $probeRuntime
        $contracts = [ordered]@{
            inspectedDeployment = $config.inspected_deployment_contract; apkPreflightResult = $config.apk_preflight_result_contract
            apkDeployResult = $config.apk_deploy_result_contract; apkDiagnosticResult = $config.apk_diagnostic_result_contract
            apkStopResult = $config.apk_stop_result_contract; apkPermissionObservation = $config.apk_permission_observation_contract
            adbForwardInventoryResult = $config.adb_forward_inventory_result_contract; apkLaunchResult = $config.apk_launch_result_contract
            launcherExportProof = $config.launcher_export_proof_contract; runtimeObservation = $config.runtime_observation_contract
        }
        foreach ($probeCase in @('current', 'mismatched-deploy', 'missing-deploy')) {
            $caseContracts = $contracts | ConvertTo-Json | ConvertFrom-Json
            if ($probeCase -eq 'mismatched-deploy') { $caseContracts.apkDeployResult = 'questionable.file_manager.apk_deploy_result.v0' }
            if ($probeCase -eq 'missing-deploy') { $caseContracts.PSObject.Properties.Remove('apkDeployResult') }
            Write-JsonUtf8NoBom -Path (Join-Path $probeRuntime 'contracts.json') -Value @{ schema = 'questionable.file_manager.operator_actions.v1'; contracts = $caseContracts }
            $probeConfig.distribution_files = @(Get-ChildItem -LiteralPath $probeRuntime -File | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{ relative_path = $_.Name; size_bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
            })
            $probeConfig.distribution_manifest_sha256 = Get-DistributionManifestSha256 -EntryPoint $probeConfig.entry_point_relative_path -Files $probeConfig.distribution_files
            Write-JsonUtf8NoBom -Path $configPath -Value $probeConfig
            $probeLog = Join-Path $testRoot 'probe-calls.txt'
            if (Test-Path -LiteralPath $probeLog) { Remove-Item -LiteralPath $probeLog }
            $probeOutput = @(& $hostExecutable -NoProfile -File $resolver -RepoRoot $RepoRoot -ConfigPath $configPath -Json 2>&1)
            $expectedExit = if ($probeCase -eq 'current') { 0 } else { 1 }
            if ($LASTEXITCODE -ne $expectedExit) { throw "Actual provider probe case failed: $probeCase ($($probeOutput -join ' | '))" }
            $probeCalls = @(Get-Content -LiteralPath $probeLog)
            if ($probeCalls.Count -ne 2 -or $probeCalls[0] -cne '--help' -or $probeCalls[1] -cne 'operator-actions|--json') { throw 'Resolver probe entered a device route.' }
        }
    }

    $deploymentOutput = @(
        & $hostExecutable -NoProfile -ExecutionPolicy Bypass `
            -File $deployment -SelfTest 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment wrapper self-test failed: $($deploymentOutput -join ' | ')"
    }
    $deploymentResult = ($deploymentOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($deploymentResult.status -cne "passed" -or
        -not $deploymentResult.immutable_run_copy -or
        -not $deploymentResult.portable_content_addressing_verified -or
        -not $deploymentResult.provider_runtime_closure -or
        -not $deploymentResult.missing_runtime_sibling_rejected -or
        -not $deploymentResult.changed_runtime_sibling_rejected -or
        -not $deploymentResult.partial_runtime_copy_rejected -or
        -not $deploymentResult.duplicate_runtime_filenames_preserved -or
        -not $deploymentResult.windows_path_bound_enforced -or
        $deploymentResult.composed_deployment_cases -ne 12 -or
        -not $deploymentResult.composed_deployment_single_dispatch -or
        -not $deploymentResult.composed_deployment_no_uncertainty_retry -or
        ($IsWindows -and -not $deploymentResult.host_read_lock_enforced) -or
        (-not $IsWindows -and $deploymentResult.host_read_lock_enforced) -or
        -not $deploymentResult.process_failure_retained) {
        throw "Deployment wrapper self-test did not return its complete passing contract."
    }

    $buildOutput = @(
        & $hostExecutable -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $RepoRoot "scripts\Invoke-QuestBuildProfile.ps1") -SelfTest 2>&1
    )
    if ($LASTEXITCODE -ne 0 -or
        [string](($buildOutput -join [Environment]::NewLine) | ConvertFrom-Json).status -cne "passed") {
        throw "Quest build-profile self-test failed."
    }
    & $hostExecutable -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepoRoot "scripts\Test-QuestBuildProfile.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Quest build-profile execution test failed." }

    & $hostExecutable -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepoRoot "scripts\Test-QuestFileManagerConsumerContract.ps1") `
        -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "Quest File Manager synthetic consumer contract test failed." }

    Write-Host "Quest File Manager CLI resolver and deployment self-tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        if (-not $resolved.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a resolver test path outside the system temporary directory."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
