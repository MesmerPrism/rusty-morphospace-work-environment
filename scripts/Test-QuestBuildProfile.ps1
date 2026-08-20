param([string]$RepoRoot = "")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$runner = Join-Path $RepoRoot "scripts\Invoke-QuestBuildProfile.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("quest-build-profile-corpus-" + [guid]::NewGuid().ToString("N"))
$profileRoot = "$testRoot-profiles"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Quest build-profile corpus failed: $Message" }
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-Profile {
    param([object]$Profile)
    if (-not (Test-Path -LiteralPath $profileRoot)) { New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null }
    $path = Join-Path $profileRoot "profile.json"
    Write-Utf8 $path ($Profile | ConvertTo-Json -Depth 32)
    return [pscustomobject]@{ Path = $path; Sha256 = Get-Sha $path }
}

function New-Profile {
    param([string]$ArtifactRelativePath = "out\fixture.apk", [string[]]$Arguments = @("out\fixture.apk"))
    return [ordered]@{
        schema = "rusty.morphospace.quest_build_profile.v1"
        profile_id = "fixture-apk"
        working_directory = "."
        executable = "build.ps1"
        arguments = @($Arguments)
        environment = [ordered]@{}
        artifact = [ordered]@{ relative_path = $ArtifactRelativePath; kind = "single-base-apk" }
        preflight = [ordered]@{
            manifest_relative_dependencies = @("AndroidManifest.xml")
            toolchain = [ordered]@{ repository_files = @("rust-toolchain.toml"); required_targets = @() }
            identity = [ordered]@{ package_id = "example.fixture"; application_id = "example.fixture" }
            environment_projection = [ordered]@{ passthrough = @("HOME", "PATH", "TEMP", "TMP", "TMPDIR"); prohibited_parent_variables = @() }
            output = [ordered]@{ lane = "warm"; collision_policy = "new-only"; allow_source_root = $true }
        }
    }
}

function Invoke-Runner {
    param(
        [string]$Mode,
        [object]$ProfileRecord,
        [string]$Receipt = "",
        [string]$SignerPath = "",
        [string]$SignerSha256 = "",
        [int]$Timeout = 30,
        [int]$CancelAfterMilliseconds = 0,
        [switch]$Interrupt
    )
    $runnerArguments = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $runner,
        "-Mode", $Mode,
        "-ProfilePath", $ProfileRecord.Path,
        "-ProfileSha256", $ProfileRecord.Sha256,
        "-SourceRoot", $testRoot,
        "-TimeoutSeconds", [string]$Timeout
    )
    if ($Receipt) { $runnerArguments += @("-ReceiptPath", $Receipt) }
    if ($SignerPath) { $runnerArguments += @("-SignerObservationPath", $SignerPath, "-SignerObservationSha256", $SignerSha256) }
    if ($CancelAfterMilliseconds -gt 0) { $runnerArguments += @("-TestCancelAfterMilliseconds", [string]$CancelAfterMilliseconds) }
    if ($Interrupt) { $runnerArguments += "-TestInterruptBeforePublish" }
    $outputLines = @(& pwsh @runnerArguments 2>&1)
    $childExit = $LASTEXITCODE
    $jsonText = @($outputLines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    try { $result = $jsonText | ConvertFrom-Json -Depth 64 }
    catch { throw "Runner did not emit one terminal JSON document (exit $childExit): $jsonText" }
    return [pscustomobject]@{ ExitCode = $childExit; Result = $result; Json = $jsonText }
}

function Assert-Terminal {
    param([object]$Invocation, [string]$ExpectedOperation, [string]$ExpectedStatus, [int]$ExpectedExit)
    Assert-True ($Invocation.ExitCode -eq $ExpectedExit) "Expected exit $ExpectedExit, got $($Invocation.ExitCode): $($Invocation.Json)"
    $expectedProperties = @("invocation", "observation", "operation", "owner_payload", "profile", "reason_codes", "schema", "streams", "terminal_status")
    $actualProperties = @($Invocation.Result.PSObject.Properties.Name | Sort-Object)
    Assert-True (($actualProperties -join "|") -ceq ($expectedProperties -join "|")) "Terminal result property set is not exact."
    Assert-True ([string]$Invocation.Result.schema -ceq "rusty.morphospace.quest_build_terminal_result.v1") "Terminal result schema is incorrect."
    Assert-True ([string]$Invocation.Result.operation -ceq $ExpectedOperation) "Terminal operation is incorrect."
    Assert-True ([string]$Invocation.Result.terminal_status -ceq $ExpectedStatus) "Terminal status is incorrect."
    Assert-True ([string]$Invocation.Result.invocation.binding_sha256 -match "^[a-f0-9]{64}$") "Terminal invocation binding digest is missing."
    $payloadProperties = @($Invocation.Result.owner_payload.PSObject.Properties.Name | Sort-Object)
    $expectedPayloadProperties = @("artifact", "environment", "execution_preflight_observation", "identity", "lockfiles", "output", "source", "toolchain")
    Assert-True (($payloadProperties -join "|") -ceq ($expectedPayloadProperties -join "|")) "Terminal owner payload property set is not exact."
    if ($null -ne $Invocation.Result.owner_payload.execution_preflight_observation) {
        $observation = $Invocation.Result.owner_payload.execution_preflight_observation
        Assert-True ([string]$observation.schema -ceq "rusty.morphospace.workflow.execution_preflight_observation.v1" -and [string]$observation.observation_id -match "^[a-z0-9][a-z0-9-]{1,127}$" -and [string]$Invocation.Result.observation.observation_id -ceq [string]$observation.observation_id -and [string]$Invocation.Result.observation.sha256 -match "^[a-f0-9]{64}$") "Terminal observation binding is invalid."
        foreach ($capability in @($observation.capabilities)) { Assert-True ([string]$capability.capability_id -match "^[a-z0-9][a-z0-9-]{1,127}$") "Observation capability identifier is not schema-valid." }
    }
    if ($ExpectedOperation -eq "preflight") {
        Assert-True ($ExpectedStatus -in @("passed", "contradiction", "incomplete")) "Preflight used a build-only terminal status."
    }
}

try {
    New-Item -ItemType Directory -Path (Join-Path $testRoot "out") -Force | Out-Null
    Write-Utf8 (Join-Path $testRoot "AndroidManifest.xml") "<manifest package=\"example.fixture\" />`n"
    Write-Utf8 (Join-Path $testRoot "rust-toolchain.toml") "[toolchain]`nchannel = \"1.97.1\"`n"
    Write-Utf8 (Join-Path $testRoot "build.ps1") @'
param(
    [string]$Output,
    [string]$Text = "",
    [switch]$Large,
    [switch]$Sleep
)
if ($Sleep) { [Threading.Thread]::Sleep(5000) }
if ($Large) {
    $chunk = "x" * 32768
    for ($index = 0; $index -lt 32; $index++) {
        [Console]::Out.Write($chunk)
        [Console]::Error.Write($chunk)
    }
}
[System.IO.File]::WriteAllBytes((Join-Path $PSScriptRoot $Output), [byte[]](1, 2, 3, 4))
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot "captured.txt"), "output=$Output|text=$Text|pager=$env:GIT_PAGER", [System.Text.UTF8Encoding]::new($false))
'@
    & git -C $testRoot init -q
    & git -C $testRoot config user.email "fixture@example.invalid"
    & git -C $testRoot config user.name "Quest Build Fixture"
    & git -C $testRoot add AndroidManifest.xml rust-toolchain.toml build.ps1
    & git -C $testRoot commit -qm "fixture baseline"

    $base = New-Profile
    $baseRecord = Write-Profile $base
    $beforeStatus = (& git -C $testRoot status --porcelain=v1 -z) -join ""
    $firstPreflight = Invoke-Runner "Preflight" $baseRecord
    Assert-Terminal $firstPreflight "preflight" "passed" 0
    $secondPreflight = Invoke-Runner "Preflight" $baseRecord
    Assert-Terminal $secondPreflight "preflight" "passed" 0
    Assert-True ($firstPreflight.Result.invocation.binding_sha256 -ceq $secondPreflight.Result.invocation.binding_sha256) "Unchanged preflight invocation digest was not deterministic."
    $afterStatus = (& git -C $testRoot status --porcelain=v1 -z) -join ""
    Assert-True ($beforeStatus -ceq $afterStatus) "Preflight changed source bytes or Git state."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "out\fixture.apk"))) "Preflight created the build artifact."

    $candidate = New-Profile
    $candidate.preflight.output.lane = "candidate"
    $candidate.preflight.output.collision_policy = "content-addressed"
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $candidate)) "preflight" "passed" 0
    Write-Utf8 (Join-Path $testRoot "candidate-dirty.txt") "candidate source drift"
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $candidate)) "preflight" "contradiction" 2
    Remove-Item -LiteralPath (Join-Path $testRoot "candidate-dirty.txt") -Force

    $missingApplication = New-Profile
    $missingApplication.preflight.identity.application_id = ""
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $missingApplication)) "preflight" "contradiction" 2

    $missingToolchain = New-Profile
    $missingToolchain.preflight.toolchain.repository_files = @("missing-toolchain.toml")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $missingToolchain)) "preflight" "contradiction" 2

    $wrongToolchainTarget = New-Profile
    $wrongToolchainTarget.preflight.toolchain.required_targets = @("not-a-real-rust-target")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $wrongToolchainTarget)) "preflight" "contradiction" 2

    $missingScript = New-Profile
    $missingScript.executable = "does-not-exist.ps1"
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $missingScript)) "preflight" "contradiction" 2

    $wrongDependency = New-Profile
    $wrongDependency.preflight.manifest_relative_dependencies = @("missing/AndroidManifest.xml")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $wrongDependency)) "preflight" "contradiction" 2

    $missingLockfile = New-Profile
    $missingLockfile.preflight.lockfiles = @("missing/Cargo.lock")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $missingLockfile)) "preflight" "contradiction" 2

    $savedPager = $env:GIT_PAGER
    try {
        $env:GIT_PAGER = "fixture-prohibited-pager"
        $prohibitedEnvironment = New-Profile
        $prohibitedEnvironment.preflight.environment_projection.prohibited_parent_variables = @("GIT_PAGER")
        Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $prohibitedEnvironment)) "preflight" "contradiction" 2
    } finally { $env:GIT_PAGER = $savedPager }

    [System.IO.File]::WriteAllBytes((Join-Path $testRoot "out\fixture.apk"), [byte[]](9))
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile (New-Profile))) "preflight" "contradiction" 2
    Remove-Item -LiteralPath (Join-Path $testRoot "out\fixture.apk") -Force

    $incompleteSigner = New-Profile
    $incompleteSigner.preflight.identity.expected_current_signer_sha256 = @(("a" * 64) -join "")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $incompleteSigner)) "preflight" "incomplete" 3

    $mismatchSigner = New-Profile
    $mismatchSigner.preflight.identity.expected_current_signer_sha256 = @(("a" * 64) -join "")
    $signerPath = Join-Path $testRoot "signer.json"
    Write-Utf8 $signerPath (([ordered]@{ schema = "rusty.morphospace.quest_signer_observation.v1"; application_id = "example.fixture"; current_signer_sha256 = @(("b" * 64) -join "") }) | ConvertTo-Json -Depth 8)
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $mismatchSigner) -SignerPath $signerPath -SignerSha256 (Get-Sha $signerPath)) "preflight" "contradiction" 2

    $quoted = New-Profile -ArtifactRelativePath "out\quoted.apk" -Arguments @("out\quoted.apk", 'value with spaces and "quotes"')
    $quotedRecord = Write-Profile $quoted
    $savedPager = $env:GIT_PAGER
    try {
        $env:GIT_PAGER = "ambient-control-must-not-reach-child"
        $quotedReceipt = Join-Path $testRoot "quoted-receipt.json"
        $quotedBuild = Invoke-Runner "Build" $quotedRecord -Receipt $quotedReceipt
        Assert-Terminal $quotedBuild "build" "passed" 0
        Assert-True (Test-Path -LiteralPath $quotedReceipt) "Passed build did not atomically publish its terminal result."
        $storedReceipt = Get-Content -Raw -LiteralPath $quotedReceipt | ConvertFrom-Json -Depth 64
        Assert-True ($storedReceipt.terminal_status -eq "passed") "Published terminal result is invalid."
        Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $testRoot "captured.txt")) -match 'text=value with spaces and "quotes"\|pager=$') "Argument quoting or child environment projection drifted."
        Assert-True ((Get-Sha $quotedBuild.Result.streams.stdout.path) -ceq $quotedBuild.Result.streams.stdout.sha256) "stdout digest is not bound."
        Assert-True ((Get-Sha $quotedBuild.Result.streams.stderr.path) -ceq $quotedBuild.Result.streams.stderr.sha256) "stderr digest is not bound."
    } finally { $env:GIT_PAGER = $savedPager }

    $large = New-Profile -ArtifactRelativePath "out\large.apk" -Arguments @("out\large.apk", "", "-Large")
    $largeBuild = Invoke-Runner "Build" (Write-Profile $large) -Receipt (Join-Path $testRoot "large-receipt.json")
    Assert-Terminal $largeBuild "build" "passed" 0
    Assert-True ($largeBuild.Result.streams.stdout.size_bytes -ge 1048576 -and $largeBuild.Result.streams.stderr.size_bytes -ge 1048576) "Large simultaneous stdout/stderr streams were not retained."

    $timeout = New-Profile -ArtifactRelativePath "out\timeout.apk" -Arguments @("out\timeout.apk", "", "-Sleep")
    $timeoutBuild = Invoke-Runner "Build" (Write-Profile $timeout) -Receipt (Join-Path $testRoot "timeout-receipt.json") -Timeout 1
    Assert-Terminal $timeoutBuild "build" "timed_out" 1

    $cancel = New-Profile -ArtifactRelativePath "out\cancel.apk" -Arguments @("out\cancel.apk", "", "-Sleep")
    $cancelBuild = Invoke-Runner "Build" (Write-Profile $cancel) -Receipt (Join-Path $testRoot "cancel-receipt.json") -CancelAfterMilliseconds 100
    Assert-Terminal $cancelBuild "build" "cancelled" 1

    $interrupted = New-Profile -ArtifactRelativePath "out\interrupted.apk" -Arguments @("out\interrupted.apk")
    $interruptedReceipt = Join-Path $testRoot "interrupted-receipt.json"
    $interruptedBuild = Invoke-Runner "Build" (Write-Profile $interrupted) -Receipt $interruptedReceipt -Interrupt
    Assert-True ($interruptedBuild.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $interruptedReceipt)) "Interrupted terminal publication exposed a final result file."
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter "interrupted-receipt.json.*.tmp" -File).Count -eq 0) "Interrupted terminal publication retained a temporary result file."

    Write-Host "Quest build-profile preflight, terminal-result, deterministic identity, zero-side-effect, and fault-corpus tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $fullTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        if (-not $fullTestRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to clean a test path outside the system temporary directory." }
        Remove-Item -LiteralPath $fullTestRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $profileRoot) {
        $fullProfileRoot = [System.IO.Path]::GetFullPath($profileRoot)
        if (-not $fullProfileRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to clean a profile path outside the system temporary directory." }
        Remove-Item -LiteralPath $fullProfileRoot -Recurse -Force
    }
}
exit 0
