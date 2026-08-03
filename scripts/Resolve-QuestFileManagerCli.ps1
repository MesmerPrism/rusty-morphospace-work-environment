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
    "executable_path",
    "executable_sha256",
    "source_kind",
    "source_version",
    "source_revision",
    "runtime_observation_contract"
) -Location "resolver config"

if ($config.schema -cne "rusty.morphospace.local_quest_file_manager_cli.v2") {
    throw "Unsupported Quest File Manager CLI resolver schema."
}
if ($config.runtime_observation_contract -cne
    "questionable.file_manager.app_runtime_observation.v2") {
    throw "runtime_observation_contract must require the QFM v2 fact contract."
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
if ($config.executable_sha256 -isnot [string] -or
    $config.executable_sha256 -cnotmatch "^[a-f0-9]{64}$") {
    throw "executable_sha256 must be one lowercase SHA-256 digest."
}
if ($config.executable_path -isnot [string] -or
    -not [System.IO.Path]::IsPathFullyQualified($config.executable_path)) {
    throw "executable_path must be an absolute machine-local path."
}

$executablePath = [System.IO.Path]::GetFullPath($config.executable_path)
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Resolved File Manager CLI does not exist: $executablePath"
}
if (-not [System.IO.Path]::GetExtension($executablePath).Equals(
        ".exe",
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved File Manager CLI must be an .exe file."
}

$actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $executablePath).Hash.ToLowerInvariant()
if ($actualSha256 -cne $config.executable_sha256) {
    throw "Resolved File Manager CLI SHA-256 does not match the private resolver config."
}

$requiredRoutes = @(
    "apk inspect --file",
    "apk install --serial",
    "apk launch --serial",
    "apk observe --serial",
    "kiosk status --serial",
    "kiosk command --serial"
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
        [string]$contracts.contracts.runtimeObservation -cne
            [string]$config.runtime_observation_contract) {
        throw "Resolved File Manager CLI does not advertise the required runtime-observation contract."
    }
    $probeStatus = "passed"
}

$result = [ordered]@{
    schema = "rusty.morphospace.local_quest_provider_resolution.v1"
    status = "ready"
    provider_id = "file-manager-local"
    executable_path = $executablePath
    executable_sha256 = $actualSha256
    source_kind = [string]$config.source_kind
    source_version = [string]$config.source_version
    source_revision = [string]$config.source_revision
    identity_probe = $identityStatus
    signature_status = $signatureStatus
    command_probe = $probeStatus
    required_routes = $requiredRoutes
    runtime_observation_contract = [string]$config.runtime_observation_contract
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    [pscustomobject]$result | Format-List
}
