param(
    [ValidateSet("Inspect", "Observe", "Install", "Deploy")]
    [string]$Mode = "Inspect",
    [string]$ApkPath = "",
    [string]$Serial = "",
    [string]$EvidenceDirectory = "",
    [string]$ConfigPath = "",
    [ValidateRange(10, 300)]
    [int]$TimeoutSeconds = 180,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-StepArguments {
    param(
        [ValidateSet("Inspect", "Observe", "Install", "Launch")]
        [string]$Step,
        [string]$Artifact,
        [string]$TargetSerial
    )

    switch ($Step) {
        "Inspect" { return @("apk", "inspect", "--file", $Artifact, "--json") }
        "Observe" { return @("apk", "observe", "--serial", $TargetSerial, "--file", $Artifact, "--json") }
        "Install" { return @("apk", "install", "--serial", $TargetSerial, "--file", $Artifact, "--json") }
        "Launch" { return @("apk", "launch", "--serial", $TargetSerial, "--file", $Artifact, "--json") }
    }
}

function Invoke-BoundedProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [int]$DeadlineSeconds
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    try {
        if (-not $process.Start()) {
            throw "File Manager CLI process did not start."
        }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($DeadlineSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            return [pscustomobject]@{
                ExitCode = -1
                StandardOutput = $stdoutTask.GetAwaiter().GetResult()
                StandardError = $stderrTask.GetAwaiter().GetResult()
                FailureCode = "timeout"
                FailureMessage = "File Manager CLI process exceeded $DeadlineSeconds seconds."
            }
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $stdoutTask.GetAwaiter().GetResult()
            StandardError = $stderrTask.GetAwaiter().GetResult()
            FailureCode = $null
            FailureMessage = $null
        }
    } catch {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        return [pscustomobject]@{
            ExitCode = -1
            StandardOutput = if ($null -eq $stdoutTask) { "" } else { $stdoutTask.GetAwaiter().GetResult() }
            StandardError = if ($null -eq $stderrTask) { "" } else { $stderrTask.GetAwaiter().GetResult() }
            FailureCode = "process-failure"
            FailureMessage = $_.Exception.Message
        }
    } finally {
        $process.Dispose()
    }
}

function Convert-StrictJson {
    param([string]$Json, [string]$Step)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "$Step returned no JSON evidence."
    }
    try {
        return $Json | ConvertFrom-Json -Depth 64
    } catch {
        throw "$Step returned malformed JSON evidence: $($_.Exception.Message)"
    }
}

function Assert-InstalledArtifact {
    param(
        [object]$Expected,
        [object]$Installed,
        [string]$ExpectedSerial,
        [string]$Step
    )

    if ($null -eq $Installed -or $null -eq $Installed.Identity) {
        throw "$Step did not return a confirmed installed identity."
    }
    if ([string]$Installed.Serial -cne $ExpectedSerial -or
        [string]$Installed.BaseApkSha256 -cne [string]$Expected.Sha256 -or
        [long]$Installed.BaseApkSizeBytes -ne [long]$Expected.SizeBytes) {
        throw "$Step installed-artifact readback does not match the inspected artifact and exact serial."
    }
}

function Assert-MutationConfirmed {
    param([object]$Envelope, [string]$Step)

    if ($null -eq $Envelope.mutation -or
        [string]$Envelope.mutation.Stage -cne "confirmed") {
        $stage = if ($null -eq $Envelope.mutation) { "missing" } else { [string]$Envelope.mutation.Stage }
        throw "$Step mutation is not headset-confirmed (stage: $stage)."
    }
}

function Write-StepEvidence {
    param(
        [string]$Directory,
        [string]$Name,
        [object]$Execution
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText(
        (Join-Path $Directory "$Name.json"),
        [string]$Execution.StandardOutput,
        $utf8)
    [ordered]@{
        schema = "rusty.morphospace.quest_file_manager_step_execution.v1"
        exit_code = [int]$Execution.ExitCode
        failure_code = $Execution.FailureCode
        failure_message = $Execution.FailureMessage
        standard_error_retained = -not [string]::IsNullOrWhiteSpace([string]$Execution.StandardError)
    } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $Directory "$Name.execution.json") -Encoding utf8NoBOM
    if (-not [string]::IsNullOrWhiteSpace([string]$Execution.StandardError)) {
        [System.IO.File]::WriteAllText(
            (Join-Path $Directory "$Name.stderr.txt"),
            [string]$Execution.StandardError,
            $utf8)
    }
}

function Invoke-Step {
    param(
        [string]$Executable,
        [string]$Step,
        [string]$Artifact,
        [string]$TargetSerial,
        [string]$EvidenceRoot,
        [string]$ExpectedExecutableSha256,
        [int]$DeadlineSeconds
    )

    $arguments = Get-StepArguments -Step $Step -Artifact $Artifact -TargetSerial $TargetSerial
    $beforeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Executable).Hash.ToLowerInvariant()
    if ($beforeSha256 -cne $ExpectedExecutableSha256) {
        throw "$Step refused an executable whose SHA-256 no longer matches provider resolution."
    }
    $execution = Invoke-BoundedProcess -Executable $Executable -Arguments $arguments -DeadlineSeconds $DeadlineSeconds
    if ($EvidenceRoot) {
        Write-StepEvidence -Directory $EvidenceRoot -Name $Step.ToLowerInvariant() -Execution $execution
    }
    $afterSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Executable).Hash.ToLowerInvariant()
    if ($afterSha256 -cne $ExpectedExecutableSha256) {
        throw "$Step executable changed during the typed invocation."
    }
    if ($execution.FailureCode) {
        throw "$Step process failed before a normal exit; retained execution evidence records the failure."
    }
    $result = Convert-StrictJson -Json $execution.StandardOutput -Step $Step
    if (-not [string]::IsNullOrWhiteSpace($execution.StandardError)) {
        throw "$Step emitted unexpected standard error; retained evidence contains the exact text."
    }
    if ($execution.ExitCode -ne 0) {
        throw "$Step failed with exit code $($execution.ExitCode); retained JSON contains the typed failure."
    }
    return $result
}

function Test-PathWithin {
    param([string]$Candidate, [string]$Parent)

    $relative = [System.IO.Path]::GetRelativePath($Parent, $Candidate)
    return -not [System.IO.Path]::IsPathRooted($relative) -and
        $relative -cne ".." -and
        -not $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)",
            [System.StringComparison]::Ordinal)
}

function New-LockedRunCopy {
    param(
        [string]$Source,
        [string]$Directory,
        [string]$Prefix,
        [string]$Extension,
        [string]$ExpectedSha256 = ""
    )

    $temporary = Join-Path $Directory "$Prefix-staging$Extension"
    Copy-Item -LiteralPath $Source -Destination $temporary
    $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $temporary).Hash.ToLowerInvariant()
    if ($ExpectedSha256 -and $sha256 -cne $ExpectedSha256) {
        throw "$Prefix run copy does not match its resolved SHA-256."
    }
    $retained = Join-Path $Directory "$Prefix-$sha256$Extension"
    Move-Item -LiteralPath $temporary -Destination $retained
    $lock = [System.IO.File]::Open(
        $retained,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read)
    $lockedSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $retained).Hash.ToLowerInvariant()
    if ($lockedSha256 -cne $sha256) {
        $lock.Dispose()
        throw "$Prefix run copy changed before its immutable lease was acquired."
    }
    return [pscustomobject]@{
        Path = $retained
        Sha256 = $sha256
        Lock = $lock
    }
}

function Invoke-SelfTest {
    $artifact = [pscustomobject]@{ Sha256 = ("a" * 64); SizeBytes = 4 }
    $installed = [pscustomobject]@{
        Serial = "QUEST123"
        Identity = [pscustomobject]@{ PackageName = "com.example.app" }
        BaseApkSha256 = ("a" * 64)
        BaseApkSizeBytes = 4
    }
    Assert-InstalledArtifact -Expected $artifact -Installed $installed -ExpectedSerial "QUEST123" -Step "self-test"
    $rejected = $false
    try {
        Assert-InstalledArtifact -Expected $artifact `
            -Installed ($installed | Select-Object *, @{ Name = "BaseApkSizeBytes"; Expression = { 5 } }) `
            -ExpectedSerial "QUEST123" -Step "self-test"
    } catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Self-test did not reject mismatched installed bytes."
    }
    $actual = (Get-StepArguments -Step Install -Artifact "example.apk" -TargetSerial "QUEST123") -join "|"
    if ($actual -cne "apk|install|--serial|QUEST123|--file|example.apk|--json") {
        throw "Self-test observed an unexpected install argument vector."
    }
    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
        "rusty-qfm-deployment-self-test-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $lockedCopy = $null
    try {
        $source = Join-Path $temporaryRoot "source.apk"
        [System.IO.File]::WriteAllBytes($source, [byte[]](1, 2, 3, 4))
        $lockedCopy = New-LockedRunCopy `
            -Source $source `
            -Directory $temporaryRoot `
            -Prefix "artifact" `
            -Extension ".apk"
        $mutationRejected = $false
        try {
            [System.IO.File]::WriteAllBytes($lockedCopy.Path, [byte[]](5, 6, 7, 8))
        } catch {
            $mutationRejected = $true
        }
        if (-not $mutationRejected) {
            throw "Self-test did not retain a read-locked run copy."
        }

        $failure = Invoke-BoundedProcess `
            -Executable (Join-Path $temporaryRoot "missing-provider.exe") `
            -Arguments @("--json") `
            -DeadlineSeconds 10
        Write-StepEvidence -Directory $temporaryRoot -Name "failed-start" -Execution $failure
        if ([string]$failure.FailureCode -cne "process-failure" -or
            -not (Test-Path -LiteralPath (Join-Path $temporaryRoot "failed-start.execution.json"))) {
            throw "Self-test did not retain process-start failure evidence."
        }
    } finally {
        if ($null -ne $lockedCopy) {
            $lockedCopy.Lock.Dispose()
        }
        [System.IO.Directory]::Delete($temporaryRoot, $true)
    }
    [ordered]@{
        schema = "rusty.morphospace.quest_file_manager_deployment_self_test.v1"
        status = "passed"
        exact_typed_vectors = $true
        mismatch_rejected = $true
        immutable_run_copy = $true
        process_failure_retained = $true
    } | ConvertTo-Json -Depth 4
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ApkPath)) {
    throw "ApkPath is required."
}
$artifactPath = [System.IO.Path]::GetFullPath($ApkPath)
if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "APK artifact was not found: $artifactPath"
}
if ([System.IO.Path]::GetExtension($artifactPath) -cne ".apk") {
    throw "ApkPath must identify one .apk file."
}

$deviceMode = $Mode -ne "Inspect"
if ($deviceMode -and [string]::IsNullOrWhiteSpace($Serial)) {
    throw "Serial is required for $Mode mode."
}
if ($deviceMode -and [string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    throw "EvidenceDirectory is required for $Mode mode."
}

$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$resolver = Join-Path $PSScriptRoot "Resolve-QuestFileManagerCli.ps1"
$resolverArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolver, "-Json")
if ($ConfigPath) {
    $resolverArguments += @("-ConfigPath", [System.IO.Path]::GetFullPath($ConfigPath))
}
$resolutionText = (& pwsh @resolverArguments) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw "Hash-pinned File Manager provider resolution failed."
}
$resolution = Convert-StrictJson -Json $resolutionText -Step "Provider resolution"
if ([string]$resolution.status -cne "ready" -or
    [string]$resolution.identity_probe -cne "passed" -or
    [string]$resolution.command_probe -cne "passed") {
    throw "Hash-pinned File Manager provider is not ready."
}

$evidenceRoot = ""
if ($deviceMode) {
    $evidenceRoot = [System.IO.Path]::GetFullPath($EvidenceDirectory)
    $localEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "local"))
    $artifactEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "artifacts"))
    if ((Test-PathWithin -Candidate $evidenceRoot -Parent $repoRoot) -and
        -not (Test-PathWithin -Candidate $evidenceRoot -Parent $localEvidenceRoot) -and
        -not (Test-PathWithin -Candidate $evidenceRoot -Parent $artifactEvidenceRoot)) {
        throw "In-repository device evidence must stay below ignored local/ or artifacts/."
    }
    if (Test-Path -LiteralPath $evidenceRoot) {
        throw "EvidenceDirectory already exists; choose a new run-owned directory."
    }
    New-Item -ItemType Directory -Path $evidenceRoot | Out-Null
    $resolution | ConvertTo-Json -Depth 16 |
        Set-Content -LiteralPath (Join-Path $evidenceRoot "provider-resolution.json") -Encoding utf8NoBOM
}

$providerRunCopy = $null
$artifactRunCopy = $null
$executionProvider = [string]$resolution.executable_path
$executionArtifact = $artifactPath
$inspection = $null
try {
    if ($deviceMode) {
        $providerRunCopy = New-LockedRunCopy `
            -Source ([string]$resolution.executable_path) `
            -Directory $evidenceRoot `
            -Prefix "provider" `
            -Extension ".exe" `
            -ExpectedSha256 ([string]$resolution.executable_sha256)
        $artifactRunCopy = New-LockedRunCopy `
            -Source $artifactPath `
            -Directory $evidenceRoot `
            -Prefix "artifact" `
            -Extension ".apk"
        $executionProvider = $providerRunCopy.Path
        $executionArtifact = $artifactRunCopy.Path
    }

    $inspection = Invoke-Step `
        -Executable $executionProvider `
        -Step Inspect `
        -Artifact $executionArtifact `
        -TargetSerial $Serial `
        -EvidenceRoot $evidenceRoot `
        -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
        -DeadlineSeconds $TimeoutSeconds
    if ($deviceMode -and [string]$inspection.Sha256 -cne $artifactRunCopy.Sha256) {
        throw "File Manager inspection does not match the immutable run-owned APK copy."
    }

    if ($Mode -eq "Observe") {
        $observation = Invoke-Step `
            -Executable $executionProvider `
            -Step Observe `
            -Artifact $executionArtifact `
            -TargetSerial $Serial `
            -EvidenceRoot $evidenceRoot `
            -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
            -DeadlineSeconds $TimeoutSeconds
        Assert-InstalledArtifact -Expected $inspection -Installed $observation.Installed -ExpectedSerial $Serial -Step Observe
    }

    if ($Mode -in @("Install", "Deploy")) {
        $install = Invoke-Step `
            -Executable $executionProvider `
            -Step Install `
            -Artifact $executionArtifact `
            -TargetSerial $Serial `
            -EvidenceRoot $evidenceRoot `
            -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
            -DeadlineSeconds $TimeoutSeconds
        Assert-MutationConfirmed -Envelope $install -Step Install
        Assert-InstalledArtifact -Expected $inspection -Installed $install.result.Installed -ExpectedSerial $Serial -Step Install
    }

    if ($Mode -eq "Deploy") {
        $launch = Invoke-Step `
            -Executable $executionProvider `
            -Step Launch `
            -Artifact $executionArtifact `
            -TargetSerial $Serial `
            -EvidenceRoot $evidenceRoot `
            -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
            -DeadlineSeconds $TimeoutSeconds
        Assert-MutationConfirmed -Envelope $launch -Step Launch
        Assert-InstalledArtifact -Expected $inspection -Installed $launch.result.Installed -ExpectedSerial $Serial -Step Launch
        if (-not [bool]$launch.result.ComponentObservedResumed) {
            throw "Launch did not return resumed-component confirmation."
        }

        $observation = Invoke-Step `
            -Executable $executionProvider `
            -Step Observe `
            -Artifact $executionArtifact `
            -TargetSerial $Serial `
            -EvidenceRoot $evidenceRoot `
            -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
            -DeadlineSeconds $TimeoutSeconds
        Assert-InstalledArtifact -Expected $inspection -Installed $observation.Installed -ExpectedSerial $Serial -Step Observe
        if (-not [bool]$observation.IsForeground -or
            -not [bool]$observation.IsTopResumed -or
            @($observation.ProcessIds).Count -eq 0) {
            throw "Post-launch observation did not confirm foreground, top-resumed, and process state."
        }
    }
} finally {
    if ($null -ne $artifactRunCopy) {
        $artifactRunCopy.Lock.Dispose()
    }
    if ($null -ne $providerRunCopy) {
        $providerRunCopy.Lock.Dispose()
    }
}

[ordered]@{
    schema = "rusty.morphospace.quest_file_manager_deployment.v1"
    status = "passed"
    mode = $Mode.ToLowerInvariant()
    provider_sha256 = [string]$resolution.executable_sha256
    provider_source_revision = [string]$resolution.source_revision
    artifact_sha256 = [string]$inspection.Sha256
    artifact_size_bytes = [long]$inspection.SizeBytes
    evidence_directory = $evidenceRoot
} | ConvertTo-Json -Depth 6
