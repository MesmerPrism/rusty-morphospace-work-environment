param(
    [string]$ProfilePath = "",
    [string]$ProfileSha256 = "",
    [string]$SourceRoot = "",
    [string]$ReceiptPath = "",
    [string]$ToolPath = "",
    [string]$ToolSha256 = "",
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 900,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-ExactProperties {
    param([object]$Value, [string[]]$Expected, [string]$Location)
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if (($actual -join "|") -cne ($wanted -join "|")) {
        throw "$Location must contain exactly: $($Expected -join ', ')."
    }
}

function Resolve-ContainedPath {
    param([string]$Root, [string]$Relative, [string]$Location)
    if ([System.IO.Path]::IsPathFullyQualified($Relative)) { throw "$Location must be repository-relative." }
    $resolved = [System.IO.Path]::GetFullPath((Join-Path $Root $Relative))
    $relativeBack = [System.IO.Path]::GetRelativePath($Root, $resolved)
    if ([System.IO.Path]::IsPathRooted($relativeBack) -or
        $relativeBack -ceq ".." -or
        $relativeBack.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)", [System.StringComparison]::Ordinal)) {
        throw "$Location escapes SourceRoot."
    }
    return $resolved
}

function Read-Profile {
    param([string]$Path, [string]$ExpectedSha256, [string]$Root)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Build profile was not found." }
    $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($ExpectedSha256 -cnotmatch "^[a-f0-9]{64}$" -or $actualSha256 -cne $ExpectedSha256) {
        throw "Build profile SHA-256 does not match."
    }
    $profile = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 32
    Assert-ExactProperties $profile @("schema", "profile_id", "working_directory", "executable", "arguments", "artifact") "build profile"
    Assert-ExactProperties $profile.artifact @("relative_path", "kind") "build profile artifact"
    if ([string]$profile.schema -cne "rusty.morphospace.quest_build_profile.v1" -or
        [string]$profile.profile_id -cnotmatch "^[a-z0-9][a-z0-9._-]{0,95}$" -or
        [string]$profile.artifact.kind -cne "single-base-apk") {
        throw "Build profile identity is invalid."
    }
    if (@($profile.arguments).Count -gt 128 -or @($profile.arguments | Where-Object { $_ -isnot [string] -or $_.Length -gt 1024 }).Count -gt 0) {
        throw "Build profile arguments are invalid."
    }
    $working = Resolve-ContainedPath $Root ([string]$profile.working_directory) "working_directory"
    $externalToolId = $null
    if ([string]$profile.executable -ceq "gradle") {
        $executable = $null
        $externalToolId = "gradle"
    } else {
        $executable = Resolve-ContainedPath $Root ([string]$profile.executable) "executable"
    }
    $artifact = Resolve-ContainedPath $Root ([string]$profile.artifact.relative_path) "artifact.relative_path"
    if ([System.IO.Path]::GetExtension($artifact) -cne ".apk") { throw "Build profile artifact must be one APK." }
    if (-not (Test-Path -LiteralPath $working -PathType Container)) { throw "Build working directory does not exist." }
    if ($null -ne $executable -and -not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Build executable does not exist." }
    return [pscustomobject]@{ Document = $profile; Sha256 = $actualSha256; Working = $working; Executable = $executable; ExternalToolId = $externalToolId; Artifact = $artifact }
}

function Invoke-Build {
    param([object]$Resolved, [int]$DeadlineSeconds, [string]$ResolvedToolPath, [string]$ExpectedToolSha256)
    if ($Resolved.ExternalToolId) {
        if ([string]::IsNullOrWhiteSpace($ResolvedToolPath) -or
            -not [System.IO.Path]::IsPathFullyQualified($ResolvedToolPath) -or
            -not (Test-Path -LiteralPath $ResolvedToolPath -PathType Leaf)) {
            throw "The gradle profile requires one absolute private ToolPath."
        }
        $fileName = [System.IO.Path]::GetFullPath($ResolvedToolPath)
        if ([System.IO.Path]::GetFileName($fileName) -cnotin @("gradle.bat", "gradle.exe")) {
            throw "The gradle profile requires gradle.bat or gradle.exe."
        }
        $toolHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fileName).Hash.ToLowerInvariant()
        if ($ExpectedToolSha256 -cnotmatch "^[a-f0-9]{64}$" -or $toolHash -cne $ExpectedToolSha256) {
            throw "The resolved Gradle executable does not match ToolSha256."
        }
        $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
    } else {
        $extension = [System.IO.Path]::GetExtension([string]$Resolved.Executable).ToLowerInvariant()
        $fileName = [string]$Resolved.Executable
        $toolHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fileName).Hash.ToLowerInvariant()
    }
    $boundToolPath = $fileName
    $arguments = @($Resolved.Document.arguments | ForEach-Object { [string]$_ })
    if ($extension -ceq ".ps1") {
        $fileName = (Get-Command pwsh -ErrorAction Stop).Source
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", [string]$Resolved.Executable) + $arguments
    } elseif ($extension -cnotin @(".exe", ".cmd", ".bat")) {
        throw "Build executable type is not allowlisted."
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fileName
    $startInfo.WorkingDirectory = [string]$Resolved.Working
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Build process did not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($DeadlineSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Build process exceeded the bounded timeout."
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $stdoutTask.GetAwaiter().GetResult()
            StandardError = $stderrTask.GetAwaiter().GetResult()
            FileName = $fileName
            Arguments = $arguments
            ToolSha256 = $toolHash
            ResolvedToolPath = $boundToolPath
        }
    } finally { $process.Dispose() }
}

if ($SelfTest) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("quest-build-profile-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path (Join-Path $root "app") -Force | Out-Null
    try {
        $resolved = Resolve-ContainedPath $root "app\output.apk" "fixture"
        if (-not $resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Contained path self-test failed." }
        $rejected = $false
        try { Resolve-ContainedPath $root "..\escape.apk" "fixture" | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Traversal self-test failed." }
        [ordered]@{
            schema = "rusty.morphospace.quest_build_profile_self_test.v1"
            status = "passed"
            traversal_rejected = $true
            allowlisted_executable_types = @("ps1", "exe", "cmd", "bat")
        } | ConvertTo-Json -Depth 4
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    exit 0
}

if (-not $ProfilePath -or -not $SourceRoot -or -not $ReceiptPath) { throw "ProfilePath, SourceRoot, and ReceiptPath are required." }
$source = (Resolve-Path -LiteralPath $SourceRoot).Path
$profile = Read-Profile ([System.IO.Path]::GetFullPath($ProfilePath)) $ProfileSha256 $source
$receipt = [System.IO.Path]::GetFullPath($ReceiptPath)
if (Test-Path -LiteralPath $receipt) { throw "ReceiptPath already exists." }
$receiptParent = Split-Path -Parent $receipt
if (-not (Test-Path -LiteralPath $receiptParent -PathType Container)) { New-Item -ItemType Directory -Path $receiptParent | Out-Null }
$before = if (Test-Path -LiteralPath $profile.Artifact -PathType Leaf) {
    [ordered]@{ sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $profile.Artifact).Hash.ToLowerInvariant(); size_bytes = (Get-Item -LiteralPath $profile.Artifact).Length }
} else { $null }
$execution = Invoke-Build $profile $TimeoutSeconds $ToolPath $ToolSha256
[System.IO.File]::WriteAllText("$receipt.stdout.txt", [string]$execution.StandardOutput, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText("$receipt.stderr.txt", [string]$execution.StandardError, [System.Text.UTF8Encoding]::new($false))
if ($execution.ExitCode -ne 0) { throw "Build profile exited $($execution.ExitCode)." }
if (-not (Test-Path -LiteralPath $profile.Artifact -PathType Leaf)) { throw "Build profile did not produce its declared APK." }
$artifactInfo = Get-Item -LiteralPath $profile.Artifact
if ($artifactInfo.Length -le 0) { throw "Built APK is empty." }
$gitHead = $null
$gitTree = $null
$gitStatus = ""
$insideWorkTree = (& git -C $source rev-parse --is-inside-work-tree 2>$null) -join ""
if ($LASTEXITCODE -eq 0 -and $insideWorkTree.Trim() -ceq "true") {
    $gitHead = ((& git -C $source rev-parse HEAD 2>$null) -join "").Trim()
    $gitTree = ((& git -C $source rev-parse 'HEAD^{tree}' 2>$null) -join "").Trim()
    $gitStatus = (& git -C $source status --porcelain=v1 -z 2>$null) -join ""
}
$result = [ordered]@{
    schema = "rusty.morphospace.quest_build_receipt.v1"
    status = "passed"
    profile_id = [string]$profile.Document.profile_id
    profile_sha256 = [string]$profile.Sha256
    source_revision = if ($gitHead) { [string]$gitHead } else { $null }
    source_tree = if ($gitTree) { [string]$gitTree } else { $null }
    source_dirty = -not [string]::IsNullOrEmpty($gitStatus)
    command = [ordered]@{
        executable = [string]$profile.Document.executable
        resolved_path = [string]$execution.ResolvedToolPath
        resolved_sha256 = [string]$execution.ToolSha256
        arguments = @($profile.Document.arguments)
    }
    artifact = [ordered]@{
        path = [string]$profile.Artifact
        size_bytes = $artifactInfo.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $profile.Artifact).Hash.ToLowerInvariant()
        before = $before
    }
    streams = [ordered]@{
        stdout = "$receipt.stdout.txt"
        stderr = "$receipt.stderr.txt"
    }
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receipt -Encoding utf8NoBOM
$result | ConvertTo-Json -Depth 10
