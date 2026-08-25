param(
    [string]$RepoRoot = "",
    [string]$ConfigPath = "",
    [switch]$SkipExecutableProbe,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $RepoRoot "local\quest-file-manager-cli.json"
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Quest File Manager CLI resolver config not found: $ConfigPath"
}
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path

function Assert-ExactProperties {
    param(
        [object]$Value,
        [string[]]$Expected,
        [string]$Location
    )

    if ($null -eq $Value) {
        throw "$Location is required."
    }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if (($actual -join "|") -cne ($wanted -join "|")) {
        throw "$Location must contain exactly: $($Expected -join ', ')."
    }
}

function Get-Utf8Sha256 {
    param([string]$Text)

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    try {
        return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Convert-ClosureRelativePath {
    param([string]$Path, [string]$Location)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        [System.IO.Path]::IsPathFullyQualified($Path) -or
        $Path.Contains(':') -or $Path.Contains('\0')) {
        throw "$Location must be one non-rooted portable relative path."
    }
    $segments = @($Path.Replace('\\', '/').Split('/', [System.StringSplitOptions]::None))
    $invalidSegments = @($segments | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' })
    if ($segments.Count -eq 0 -or $invalidSegments.Count -gt 0) {
        throw "$Location must not contain empty, dot, or parent path segments."
    }
    return $segments -join '/'
}

function Get-DistributionManifestSha256 {
    param([string]$EntryPoint, [object[]]$Files)

    $lines = @("rusty.morphospace.quest_file_manager_distribution_manifest.v1", "entry_point=$EntryPoint")
    foreach ($file in @($Files | Sort-Object relative_path)) {
        $lines += "file=$($file.relative_path)`t$($file.size_bytes)`t$($file.sha256)"
    }
    return Get-Utf8Sha256 (($lines -join "`n") + "`n")
}

function Invoke-HelpProbe {
    param([string]$ExecutablePath)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add("--help")

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "File Manager CLI help probe did not start."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill($true)
            throw "File Manager CLI help probe exceeded 15 seconds."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "File Manager CLI help probe exited $($process.ExitCode): $stderr"
        }
        return $stdout
    } finally {
        $process.Dispose()
    }
}

function Invoke-ContractProbe {
    param([string]$ExecutablePath)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @("operator-actions", "--json")) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "File Manager CLI contract probe did not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill($true)
            throw "File Manager CLI contract probe exceeded 15 seconds."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($stderr)) {
            throw "File Manager CLI contract probe failed."
        }
        return $stdout | ConvertFrom-Json -Depth 32
    } finally {
        $process.Dispose()
    }
}

$config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
Assert-ExactProperties -Value $config -Expected @(
    "schema",
    "provider_id",
    "runtime_root",
    "entry_point_relative_path",
    "distribution_manifest_sha256",
    "distribution_files",
    "source_kind",
    "source_version",
    "source_revision",
    "source_tree",
    "inspected_deployment_contract",
    "apk_preflight_result_contract",
    "apk_deploy_result_contract",
    "apk_diagnostic_result_contract",
    "apk_diagnostic_bundle_contract",
    "apk_stop_result_contract",
    "apk_permission_observation_contract",
    "adb_forward_inventory_result_contract",
    "apk_launch_result_contract",
    "launcher_export_proof_contract",
    "runtime_observation_contract",
    "global_focus_observation_contract"
) -Location "resolver config"

if ($config.schema -cne "rusty.morphospace.local_quest_file_manager_cli.v4") {
    throw "Unsupported Quest File Manager CLI resolver schema."
}
if ($config.inspected_deployment_contract -cne
    "questionable.file_manager.inspected_deployment.v5") {
    throw "inspected_deployment_contract must require the QFM v5 deployment contract."
}
if ($config.apk_preflight_result_contract -cne "questionable.file_manager.apk_preflight_result.v1" -or
    $config.apk_deploy_result_contract -cne "questionable.file_manager.apk_deploy_result.v1" -or
    $config.apk_diagnostic_result_contract -cne "questionable.file_manager.apk_diagnostic_result.v3" -or
    $config.apk_diagnostic_bundle_contract -cne "questionable.file_manager.apk_diagnostic_bundle.v3" -or
    $config.apk_stop_result_contract -cne "questionable.file_manager.apk_stop_result.v1" -or
    $config.apk_permission_observation_contract -cne "questionable.file_manager.apk_permission_observation.v1" -or
    $config.adb_forward_inventory_result_contract -cne "questionable.file_manager.adb_forward_inventory_result.v1") {
    throw "Resolver config does not pin the adopted QFM deployment, diagnostic, stop, permission-observation, and forward contracts."
}
if ($config.apk_launch_result_contract -cne
    "questionable.file_manager.apk_launch_result.v1") {
    throw "apk_launch_result_contract must require the QFM v1 JSON launch result contract."
}
if ($config.launcher_export_proof_contract -cne
    "questionable.file_manager.launcher_export_proof.v2") {
    throw "launcher_export_proof_contract must require the QFM v2 launcher proof contract."
}
if ($config.runtime_observation_contract -cne
    "questionable.file_manager.app_runtime_observation.v5") {
    throw "runtime_observation_contract must require the QFM v5 fact contract."
}
if ($config.global_focus_observation_contract -cne
    "questionable.file_manager.android_global_focus_observation.v1") {
    throw "global_focus_observation_contract must require QFM global-focus observation v1."
}
if ($config.provider_id -cne "file-manager-local") {
    throw "Quest File Manager CLI resolver provider_id must be file-manager-local."
}
if ($config.source_kind -cnotin @("signed-release", "source-build")) {
    throw "source_kind must be signed-release or source-build."
}
if ($config.source_version -isnot [string] -or
    $config.source_version -cnotmatch "^[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z0-9.-]+)?$") {
    throw "source_version must be a lowercase semantic version."
}
if ($config.source_revision -isnot [string] -or
    $config.source_revision -cnotmatch "^[a-f0-9]{40}$") {
    throw "source_revision must be one full lowercase Git commit."
}
if ($config.source_tree -isnot [string] -or
    $config.source_tree -cnotmatch "^[a-f0-9]{40}$") {
    throw "source_tree must be one full lowercase Git tree."
}
if ($config.runtime_root -isnot [string] -or
    -not [System.IO.Path]::IsPathFullyQualified($config.runtime_root)) {
    throw "runtime_root must be an absolute machine-local directory path."
}
$runtimeRoot = [System.IO.Path]::GetFullPath($config.runtime_root)
if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
    throw "Configured File Manager runtime root does not exist: $runtimeRoot"
}
$entryPointRelativePath = Convert-ClosureRelativePath -Path ([string]$config.entry_point_relative_path) -Location "entry_point_relative_path"
if ($config.distribution_manifest_sha256 -isnot [string] -or
    $config.distribution_manifest_sha256 -cnotmatch "^[a-f0-9]{64}$") {
    throw "distribution_manifest_sha256 must be one lowercase SHA-256 digest."
}
if ($null -eq $config.distribution_files -or @($config.distribution_files).Count -eq 0) {
    throw "distribution_files must declare the complete non-empty provider runtime closure."
}
$distributionFiles = [Collections.Generic.List[object]]::new()
$seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($declaredFile in @($config.distribution_files)) {
    Assert-ExactProperties -Value $declaredFile -Expected @("relative_path", "size_bytes", "sha256") -Location "distribution_files entry"
    $relativePath = Convert-ClosureRelativePath -Path ([string]$declaredFile.relative_path) -Location "distribution_files.relative_path"
    if (-not $seenPaths.Add($relativePath)) { throw "distribution_files contains duplicate relative path '$relativePath'." }
    if ($declaredFile.sha256 -isnot [string] -or [string]$declaredFile.sha256 -cnotmatch "^[a-f0-9]{64}$") {
        throw "distribution_files '$relativePath' must declare one lowercase SHA-256 digest."
    }
    if ([long]$declaredFile.size_bytes -lt 0) { throw "distribution_files '$relativePath' has an invalid size_bytes value." }
    $distributionFiles.Add([pscustomobject][ordered]@{
        relative_path = $relativePath
        size_bytes = [long]$declaredFile.size_bytes
        sha256 = ([string]$declaredFile.sha256).ToLowerInvariant()
    }) | Out-Null
}
if (-not $seenPaths.Contains($entryPointRelativePath)) {
    throw "entry_point_relative_path must name one declared distribution file."
}
$actualDistributionManifestSha256 = Get-DistributionManifestSha256 -EntryPoint $entryPointRelativePath -Files $distributionFiles.ToArray()
if ($actualDistributionManifestSha256 -cne [string]$config.distribution_manifest_sha256) {
    throw "distribution_manifest_sha256 does not match the declared provider closure."
}
foreach ($file in $distributionFiles) {
    $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $file.relative_path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
    $relativeToRoot = [System.IO.Path]::GetRelativePath($runtimeRoot, $sourcePath)
    if ([System.IO.Path]::IsPathRooted($relativeToRoot) -or $relativeToRoot -eq '..' -or $relativeToRoot.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal)) {
        throw "distribution_files '$($file.relative_path)' escapes runtime_root."
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Declared provider runtime file is missing: $($file.relative_path)" }
    $actualSize = (Get-Item -LiteralPath $sourcePath).Length
    $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
    if ($actualSize -ne $file.size_bytes -or $actualSha256 -cne $file.sha256) {
        throw "Declared provider runtime file does not match its size or SHA-256: $($file.relative_path)"
    }
}

$executablePath = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $entryPointRelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Resolved File Manager CLI does not exist: $executablePath"
}
if (-not [System.IO.Path]::GetExtension($executablePath).Equals(
        ".exe",
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved File Manager CLI must be an .exe file."
}

$actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $executablePath).Hash.ToLowerInvariant()
$entryPointDeclaration = @($distributionFiles | Where-Object { $_.relative_path -ceq $entryPointRelativePath })
if ($entryPointDeclaration.Count -ne 1 -or $actualSha256 -cne [string]$entryPointDeclaration[0].sha256) { throw "Resolved entry point does not match its declared closure digest." }

$requiredRoutes = @(
    "apk preflight --serial",
    "apk deploy --serial",
    "apk diagnose --serial",
    "apk stop --serial",
    "apk permissions --serial",
    "adb forwards --serial"
)
$probeStatus = "skipped"
$identityStatus = "skipped"
$signatureStatus = "not-checked"
if (-not $SkipExecutableProbe) {
    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($executablePath)
    if ($versionInfo.CompanyName -cne "Mesmer Prism" -or
        $versionInfo.ProductName -cne "questionable-file-manager") {
        throw "Resolved executable does not have the expected File Manager product identity."
    }
    if (-not $versionInfo.ProductVersion.StartsWith(
            ([string]$config.source_version),
            [System.StringComparison]::Ordinal) -or
        -not $versionInfo.ProductVersion.Contains(
            ([string]$config.source_revision),
            [System.StringComparison]::Ordinal)) {
        throw "Resolved File Manager CLI product version does not bind the configured version and source revision."
    }
    $identityStatus = "passed"

    $signature = Get-AuthenticodeSignature -LiteralPath $executablePath
    $signatureStatus = [string]$signature.Status
    if ($config.source_kind -ceq "signed-release" -and
        $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Configured signed-release File Manager CLI does not have a valid Authenticode signature."
    }

    $help = Invoke-HelpProbe -ExecutablePath $executablePath
    foreach ($route in $requiredRoutes) {
        if (-not $help.Contains($route, [System.StringComparison]::Ordinal)) {
            throw "Resolved File Manager CLI does not advertise required route '$route'."
        }
    }
    $contracts = Invoke-ContractProbe -ExecutablePath $executablePath
    if ([string]$contracts.schema -cne "questionable.file_manager.operator_actions.v1" -or
        [string]$contracts.contracts.inspectedDeployment -cne
            [string]$config.inspected_deployment_contract -or
        [string]$contracts.contracts.apkPreflightResult -cne [string]$config.apk_preflight_result_contract -or
        [string]$contracts.contracts.apkDeployResult -cne [string]$config.apk_deploy_result_contract -or
        [string]$contracts.contracts.apkDiagnosticResult -cne [string]$config.apk_diagnostic_result_contract -or
        [string]$contracts.contracts.apkStopResult -cne [string]$config.apk_stop_result_contract -or
        [string]$contracts.contracts.apkPermissionObservation -cne [string]$config.apk_permission_observation_contract -or
        [string]$contracts.contracts.adbForwardInventoryResult -cne [string]$config.adb_forward_inventory_result_contract -or
        [string]$contracts.contracts.apkLaunchResult -cne
            [string]$config.apk_launch_result_contract -or
        [string]$contracts.contracts.launcherExportProof -cne
            [string]$config.launcher_export_proof_contract -or
        [string]$contracts.contracts.runtimeObservation -cne
            [string]$config.runtime_observation_contract) {
        throw "Resolved File Manager CLI does not advertise the complete inspected-deployment contract set."
    }
    $probeStatus = "passed"
}

$result = [ordered]@{
    schema = "rusty.morphospace.local_quest_provider_resolution.v1"
    status = "ready"
    provider_id = "file-manager-local"
    runtime_root = $runtimeRoot
    executable_path = $executablePath
    executable_sha256 = $actualSha256
    entry_point_relative_path = $entryPointRelativePath
    distribution_manifest_sha256 = $actualDistributionManifestSha256
    closure_sha256 = (Get-Utf8Sha256 ("rusty.morphospace.quest_file_manager_provider_closure.v1`n$actualDistributionManifestSha256`n$entryPointRelativePath`n"))
    closure_files = @($distributionFiles.ToArray())
    source_kind = [string]$config.source_kind
    source_version = [string]$config.source_version
    source_revision = [string]$config.source_revision
    source_tree = [string]$config.source_tree
    identity_probe = $identityStatus
    signature_status = $signatureStatus
    command_probe = $probeStatus
    required_routes = $requiredRoutes
    inspected_deployment_contract = [string]$config.inspected_deployment_contract
    apk_preflight_result_contract = [string]$config.apk_preflight_result_contract
    apk_deploy_result_contract = [string]$config.apk_deploy_result_contract
    apk_diagnostic_result_contract = [string]$config.apk_diagnostic_result_contract
    apk_diagnostic_bundle_contract = [string]$config.apk_diagnostic_bundle_contract
    apk_stop_result_contract = [string]$config.apk_stop_result_contract
    apk_permission_observation_contract = [string]$config.apk_permission_observation_contract
    adb_forward_inventory_result_contract = [string]$config.adb_forward_inventory_result_contract
    apk_launch_result_contract = [string]$config.apk_launch_result_contract
    launcher_export_proof_contract = [string]$config.launcher_export_proof_contract
    runtime_observation_contract = [string]$config.runtime_observation_contract
    global_focus_observation_contract = [string]$config.global_focus_observation_contract
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    [pscustomobject]$result | Format-List
}
