param(
    [ValidateSet("Inspect", "Observe", "Install", "Deploy")]
    [string]$Mode = "Inspect",
    [string]$ApkPath = "",
    [string]$Serial = "",
    [string]$EvidenceDirectory = "",
    [string]$ConfigPath = "",
    [ValidateSet("Android2d", "ImmersiveXr", "ProcessAlive")]
    [string]$RuntimeShape = "Android2d",
    [string]$ExpectedComponent = "",
    [ValidateRange(5, 60)]
    [int]$LaunchWaitSeconds = 30,
    [ValidateRange(10, 300)]
    [int]$TimeoutSeconds = 180,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$MaximumProviderClosurePathLength = 240
Import-Module (Join-Path $PSScriptRoot 'lib\QuestFileManagerRuntimeObservationAdapter.psm1') -Force

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

function Assert-LaunchAdmitted {
    param([object]$Envelope)
    if ([string]$Envelope.schema -cne "questionable.file_manager.apk_launch_result.v1" -or
        -not [bool]$Envelope.succeeded -or
        $null -eq $Envelope.result -or
        -not [bool]$Envelope.result.CommandResult.Succeeded -or
        [string]$Envelope.mutation.Stage -cnotin @("pending", "confirmed")) {
        throw "Launch was not admitted by the inspected File Manager provider."
    }
}

function Assert-RuntimeObservation {
    param(
        [object]$Observation,
        [ValidateSet("Android2d", "ImmersiveXr", "ProcessAlive")]
        [string]$Shape,
        [string]$Component = ""
    )

    $adapted = Convert-QfmRuntimeObservation -Observation $Observation
    if ([string]$adapted.status -ne 'supported') {
        throw "Runtime observation uses an unsupported QFM fact contract: $($adapted.input_contract)"
    }
    # RuntimeShape and Component remain accepted legacy request inputs, but are
    # never readiness assertions. Process, task, and focus remain raw facts;
    # application/OpenXR readiness stays unknown until app-owned evidence exists.
    return $adapted
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
        [string]$EvidenceName = "",
        [string]$ExpectedExecutableSha256,
        [object]$ProviderClosure = $null,
        [int]$DeadlineSeconds
    )

    $arguments = Get-StepArguments -Step $Step -Artifact $Artifact -TargetSerial $TargetSerial
    if ($null -ne $ProviderClosure) { Test-LockedProviderClosure -Closure $ProviderClosure }
    $beforeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Executable).Hash.ToLowerInvariant()
    if ($beforeSha256 -cne $ExpectedExecutableSha256) {
        throw "$Step refused an executable whose SHA-256 no longer matches provider resolution."
    }
    $execution = Invoke-BoundedProcess -Executable $Executable -Arguments $arguments -DeadlineSeconds $DeadlineSeconds
    if ($EvidenceRoot) {
        $name = if ($EvidenceName) { $EvidenceName } else { $Step.ToLowerInvariant() }
        Write-StepEvidence -Directory $EvidenceRoot -Name $name -Execution $execution
    }
    $afterSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Executable).Hash.ToLowerInvariant()
    if ($afterSha256 -cne $ExpectedExecutableSha256) {
        throw "$Step executable changed during the typed invocation."
    }
    if ($null -ne $ProviderClosure) { Test-LockedProviderClosure -Closure $ProviderClosure }
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

function Get-ProviderClosureFilePath {
    param([string]$Root, [string]$RelativePath)

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
    $relative = [System.IO.Path]::GetRelativePath($Root, $candidate)
    if ([System.IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or
        $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal)) {
        throw "Provider closure path escapes its declared root: $RelativePath"
    }
    return $candidate
}

function Test-LockedProviderClosure {
    param([object]$Closure)

    $actualRelativePaths = @(
        Get-ChildItem -LiteralPath $Closure.Root -Recurse -File | ForEach-Object {
            [System.IO.Path]::GetRelativePath($Closure.Root, $_.FullName).Replace('\\', '/')
        } | Sort-Object)
    $expectedRelativePaths = @($Closure.Files | ForEach-Object { [string]$_.relative_path } | Sort-Object)
    if (($actualRelativePaths -join "`n") -cne ($expectedRelativePaths -join "`n")) {
        throw "Staged provider closure contains a missing or undeclared runtime file."
    }
    foreach ($file in @($Closure.Files)) {
        $path = Get-ProviderClosureFilePath -Root $Closure.Root -RelativePath ([string]$file.relative_path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Staged provider runtime file is missing: $($file.relative_path)" }
        $item = Get-Item -LiteralPath $path
        $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($item.Length -ne [long]$file.size_bytes -or $sha256 -cne [string]$file.sha256) {
            throw "Staged provider runtime file changed: $($file.relative_path)"
        }
    }
}

function New-LockedProviderClosure {
    param([object]$Resolution, [string]$Directory)

    $closureDigest = [string]$Resolution.closure_sha256
    if ($closureDigest -cnotmatch '^[a-f0-9]{64}$') { throw "Provider resolution did not return a valid closure digest." }
    $staging = Join-Path $Directory (".provider-closure-staging-" + [Guid]::NewGuid().ToString('N'))
    $retained = Join-Path $Directory ("provider-closure-" + $closureDigest)
    if (Test-Path -LiteralPath $retained) { throw "Content-addressed provider closure root already exists for this run." }
    New-Item -ItemType Directory -Path $staging | Out-Null
    $leases = [Collections.Generic.List[object]]::new()
    try {
        foreach ($file in @($Resolution.closure_files | Sort-Object relative_path)) {
            $source = Get-ProviderClosureFilePath -Root ([string]$Resolution.runtime_root) -RelativePath ([string]$file.relative_path)
            if ($source.Length -gt $MaximumProviderClosurePathLength) {
                throw "Provider source closure path exceeds the $MaximumProviderClosurePathLength-character run bound: $($file.relative_path)"
            }
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Provider source closure is missing: $($file.relative_path)" }
            $destination = Get-ProviderClosureFilePath -Root $staging -RelativePath ([string]$file.relative_path)
            if ($destination.Length -gt $MaximumProviderClosurePathLength) {
                throw "Provider staged closure path exceeds the $MaximumProviderClosurePathLength-character run bound: $($file.relative_path)"
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
            $item = Get-Item -LiteralPath $destination
            $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
            if ($item.Length -ne [long]$file.size_bytes -or $sha256 -cne [string]$file.sha256) {
                throw "Partial or changed provider runtime copy: $($file.relative_path)"
            }
        }
        $closure = [pscustomobject]@{ Root = $staging; Files = @($Resolution.closure_files); ClosureSha256 = $closureDigest }
        Test-LockedProviderClosure -Closure $closure
        Move-Item -LiteralPath $staging -Destination $retained
        $closure.Root = $retained
        foreach ($file in @($closure.Files)) {
            $leases.Add([System.IO.File]::Open((Get-ProviderClosureFilePath -Root $retained -RelativePath ([string]$file.relative_path)), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)) | Out-Null
        }
        Test-LockedProviderClosure -Closure $closure
        $closure | Add-Member -NotePropertyName EntryPointPath -NotePropertyValue (Get-ProviderClosureFilePath -Root $retained -RelativePath ([string]$Resolution.entry_point_relative_path))
        $closure | Add-Member -NotePropertyName Locks -NotePropertyValue $leases
        return $closure
    } catch {
        foreach ($lease in $leases) { $lease.Dispose() }
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        throw
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
    $immersiveObservation = [pscustomobject]@{
        ObservationContract = "questionable.file_manager.app_runtime_observation.v5"
        IsForeground = $false
        IsTopResumed = $true
        ProcessAlive = $true
        ProcessIds = @(123)
        TopResumedComponents = @("com.example.app/com.example.app.Main")
        BlockingSystemComponents = @()
    }
    $adaptedObservation = Assert-RuntimeObservation `
        -Observation $immersiveObservation `
        -Shape ImmersiveXr `
        -Component "com.example.app/com.example.app.Main"
    Assert-LaunchAdmitted ([pscustomobject]@{
        schema = "questionable.file_manager.apk_launch_result.v1"
        succeeded = $true
        mutation = [pscustomobject]@{ Stage = "pending" }
        result = [pscustomobject]@{ CommandResult = [pscustomobject]@{ Succeeded = $true } }
    })
    if ($adaptedObservation.fact_families.application_evidence.application_readiness -cne 'unknown' -or
        $adaptedObservation.fact_families.application_evidence.openxr_readiness -cne 'unknown') {
        throw "Self-test allowed Android transport facts to become application or OpenXR readiness."
    }
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
    $providerClosure = $null
    $hostReadLockEnforced = $false
    $portableContentAddressingVerified = $false
    try {
        $source = Join-Path $temporaryRoot "source.apk"
        [System.IO.File]::WriteAllBytes($source, [byte[]](1, 2, 3, 4))
        $lockedCopy = New-LockedRunCopy `
            -Source $source `
            -Directory $temporaryRoot `
            -Prefix "artifact" `
            -Extension ".apk"
        $expectedName = "artifact-$($lockedCopy.Sha256).apk"
        $retainedName = [System.IO.Path]::GetFileName($lockedCopy.Path)
        $retainedSha256 = (Get-FileHash -Algorithm SHA256 `
            -LiteralPath $lockedCopy.Path).Hash.ToLowerInvariant()
        if ($retainedName -cne $expectedName -or
            $retainedSha256 -cne $lockedCopy.Sha256) {
            throw "Self-test did not retain an exact content-addressed run copy."
        }
        $portableContentAddressingVerified = $true

        $providerRoot = Join-Path $temporaryRoot 'provider runtime with spaces'
        New-Item -ItemType Directory -Path (Join-Path $providerRoot 'runtimes\win-x64') -Force | Out-Null
        $providerEntry = Join-Path $providerRoot 'questionable-file-manager.exe'
        $providerSibling = Join-Path $providerRoot 'runtimes\win-x64\hostfxr.dll'
        [System.IO.File]::WriteAllBytes($providerEntry, [byte[]](9, 8, 7, 6))
        [System.IO.File]::WriteAllBytes($providerSibling, [byte[]](6, 7, 8, 9))
        $duplicateSibling = Join-Path $providerRoot 'plugins\hostfxr.dll'
        New-Item -ItemType Directory -Path (Split-Path -Parent $duplicateSibling) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($duplicateSibling, [byte[]](5, 5, 5, 5))
        $providerFiles = @($providerEntry, $providerSibling, $duplicateSibling | ForEach-Object { $_ }) | ForEach-Object {
            $relative = [System.IO.Path]::GetRelativePath($providerRoot, $_).Replace('\\', '/')
            [pscustomobject]@{ relative_path = $relative; size_bytes = (Get-Item -LiteralPath $_).Length; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant() }
        }
        $providerClosure = New-LockedProviderClosure -Resolution ([pscustomobject]@{
            closure_sha256 = ('b' * 64); runtime_root = $providerRoot; closure_files = $providerFiles; entry_point_relative_path = 'questionable-file-manager.exe'
        }) -Directory $temporaryRoot
        Test-LockedProviderClosure -Closure $providerClosure
        foreach ($lease in $providerClosure.Locks) { $lease.Dispose() }
        $providerClosure.Locks = @()
        Remove-Item -LiteralPath (Get-ProviderClosureFilePath -Root $providerClosure.Root -RelativePath 'runtimes/win-x64/hostfxr.dll') -Force
        $missingSiblingRejected = $false
        try { Test-LockedProviderClosure -Closure $providerClosure } catch { $missingSiblingRejected = $true }
        if (-not $missingSiblingRejected) { throw "Self-test did not reject a missing staged provider runtime sibling." }
        $longPathRejected = $false
        $overlongRelativePath = [string]::Concat(('bounded/' * 40)) + 'hostfxr.dll'
        try {
            New-LockedProviderClosure -Resolution ([pscustomobject]@{
                closure_sha256 = ('c' * 64); runtime_root = $providerRoot
                closure_files = @([pscustomobject]@{ relative_path = $overlongRelativePath; size_bytes = 1; sha256 = ('0' * 64) })
                entry_point_relative_path = $overlongRelativePath
            }) -Directory $temporaryRoot | Out-Null
        } catch { $longPathRejected = $true }
        if (-not $longPathRejected) { throw "Self-test did not reject an overlong provider closure path before copy." }

        if ($IsWindows) {
            $mutationRejected = $false
            try {
                [System.IO.File]::WriteAllBytes(
                    $lockedCopy.Path,
                    [byte[]](5, 6, 7, 8))
            } catch {
                $mutationRejected = $true
            }
            if (-not $mutationRejected) {
                throw "Self-test did not retain a Windows read-locked run copy."
            }
            $hostReadLockEnforced = $true
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
        if ($null -ne $providerClosure) {
            foreach ($lease in $providerClosure.Locks) { $lease.Dispose() }
        }
        [System.IO.Directory]::Delete($temporaryRoot, $true)
    }
    [ordered]@{
        schema = "rusty.morphospace.quest_file_manager_deployment_self_test.v1"
        status = "passed"
        exact_typed_vectors = $true
        mismatch_rejected = $true
        immutable_run_copy = $true
        portable_content_addressing_verified = $portableContentAddressingVerified
        host_read_lock_enforced = $hostReadLockEnforced
        process_failure_retained = $true
        provider_runtime_closure = $true
        missing_runtime_sibling_rejected = $true
        duplicate_runtime_filenames_preserved = $true
        windows_path_bound_enforced = $true
        runtime_facts_do_not_establish_readiness = $true
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
$providerClosure = $null
$artifactRunCopy = $null
$executionProvider = [string]$resolution.executable_path
$executionArtifact = $artifactPath
$inspection = $null
try {
    if ($deviceMode) {
        $providerClosure = New-LockedProviderClosure -Resolution $resolution -Directory $evidenceRoot
        [ordered]@{
            schema = "rusty.morphospace.quest_file_manager_provider_closure.v1"
            source_revision = [string]$resolution.source_revision
            source_tree = [string]$resolution.source_tree
            distribution_manifest_sha256 = [string]$resolution.distribution_manifest_sha256
            closure_sha256 = [string]$resolution.closure_sha256
            entry_point_relative_path = [string]$resolution.entry_point_relative_path
            files = @($resolution.closure_files)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidenceRoot "provider-closure-manifest.json") -Encoding utf8NoBOM
        $artifactRunCopy = New-LockedRunCopy `
            -Source $artifactPath `
            -Directory $evidenceRoot `
            -Prefix "artifact" `
            -Extension ".apk"
        $executionProvider = $providerClosure.EntryPointPath
        $executionArtifact = $artifactRunCopy.Path
    }

    $inspection = Invoke-Step `
        -Executable $executionProvider `
        -Step Inspect `
        -Artifact $executionArtifact `
        -TargetSerial $Serial `
        -EvidenceRoot $evidenceRoot `
        -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
        -ProviderClosure $providerClosure `
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
            -ProviderClosure $providerClosure `
            -DeadlineSeconds $TimeoutSeconds
        Assert-InstalledArtifact -Expected $inspection -Installed $observation.Installed -ExpectedSerial $Serial -Step Observe
        Assert-RuntimeObservation `
            -Observation $observation `
            -Shape $RuntimeShape `
            -Component $ExpectedComponent
    }

    if ($Mode -in @("Install", "Deploy")) {
        $install = Invoke-Step `
            -Executable $executionProvider `
            -Step Install `
            -Artifact $executionArtifact `
            -TargetSerial $Serial `
            -EvidenceRoot $evidenceRoot `
            -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
            -ProviderClosure $providerClosure `
            -DeadlineSeconds $TimeoutSeconds
        Assert-MutationConfirmed -Envelope $install -Step Install
        $postInstallObservation = Invoke-Step `
            -Executable $executionProvider `
            -Step Observe `
            -Artifact $executionArtifact `
            -TargetSerial $Serial `
            -EvidenceRoot $evidenceRoot `
            -EvidenceName "post-install-observe" `
            -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
            -ProviderClosure $providerClosure `
            -DeadlineSeconds $TimeoutSeconds
        Assert-InstalledArtifact `
            -Expected $inspection `
            -Installed $postInstallObservation.Installed `
            -ExpectedSerial $Serial `
            -Step "Post-install observe"
    }

    if ($Mode -eq "Deploy") {
        $launch = Invoke-Step `
            -Executable $executionProvider `
            -Step Launch `
            -Artifact $executionArtifact `
            -TargetSerial $Serial `
            -EvidenceRoot $evidenceRoot `
            -EvidenceName "launch" `
            -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
            -ProviderClosure $providerClosure `
            -DeadlineSeconds $TimeoutSeconds
        Assert-LaunchAdmitted -Envelope $launch
        Assert-InstalledArtifact -Expected $inspection -Installed $launch.result.Installed -ExpectedSerial $Serial -Step Launch
        $observation = Invoke-Step `
            -Executable $executionProvider `
            -Step Observe `
            -Artifact $executionArtifact `
            -TargetSerial $Serial `
            -EvidenceRoot $evidenceRoot `
            -EvidenceName 'post-launch-observe' `
            -ExpectedExecutableSha256 ([string]$resolution.executable_sha256) `
            -ProviderClosure $providerClosure `
            -DeadlineSeconds $TimeoutSeconds
        Assert-InstalledArtifact -Expected $inspection -Installed $observation.Installed -ExpectedSerial $Serial -Step Observe
        Assert-RuntimeObservation -Observation $observation -Shape $RuntimeShape -Component $ExpectedComponent | Out-Null
    }
} finally {
    if ($null -ne $artifactRunCopy) {
        $artifactRunCopy.Lock.Dispose()
    }
    if ($null -ne $providerRunCopy) {
        $providerRunCopy.Lock.Dispose()
    }
    if ($null -ne $providerClosure) {
        foreach ($lease in $providerClosure.Locks) { $lease.Dispose() }
    }
}

[ordered]@{
    schema = "rusty.morphospace.quest_file_manager_deployment.v1"
    status = "passed"
    mode = $Mode.ToLowerInvariant()
    provider_sha256 = [string]$resolution.executable_sha256
    provider_source_revision = [string]$resolution.source_revision
    provider_source_tree = [string]$resolution.source_tree
    provider_distribution_manifest_sha256 = [string]$resolution.distribution_manifest_sha256
    provider_closure_sha256 = [string]$resolution.closure_sha256
    provider_staged_entry_point = [string]$resolution.entry_point_relative_path
    artifact_sha256 = [string]$inspection.Sha256
    artifact_size_bytes = [long]$inspection.SizeBytes
    evidence_directory = $evidenceRoot
    runtime_shape = $RuntimeShape
    expected_component = if ([string]::IsNullOrWhiteSpace($ExpectedComponent)) { $null } else { $ExpectedComponent }
    runtime_observation_interpretation = 'android-facts-only'
} | ConvertTo-Json -Depth 6
