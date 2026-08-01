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
$hostSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $hostExecutable).Hash.ToLowerInvariant()
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("rusty-morphospace-qfm-resolver-" + [guid]::NewGuid().ToString("N"))
$configPath = Join-Path $testRoot "resolver.json"

function Write-JsonUtf8NoBom {
    param([string]$Path, [object]$Value)

    $json = $Value | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
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
    $config = [ordered]@{
        schema = "rusty.morphospace.local_quest_file_manager_cli.v1"
        provider_id = "file-manager-local"
        executable_path = $hostExecutable
        executable_sha256 = $hostSha256
        source_kind = "source-build"
        source_version = "0.1.0-dev"
        source_revision = ("a" * 40)
    }
    Write-JsonUtf8NoBom -Path $configPath -Value $config

    $result = Invoke-ResolverChild -ExpectedExit 0 | ConvertFrom-Json
    if ($result.status -cne "ready" -or
        $result.provider_id -cne "file-manager-local" -or
        $result.identity_probe -cne "skipped" -or
        $result.command_probe -cne "skipped" -or
        $result.executable_sha256 -cne $hostSha256) {
        throw "Resolver did not return the expected hash-pinned ready result."
    }

    $config.executable_sha256 = ("0" * 64)
    Write-JsonUtf8NoBom -Path $configPath -Value $config
    Invoke-ResolverChild -ExpectedExit 1 | Out-Null

    $config.executable_sha256 = $hostSha256
    $config.extra = "not-allowed"
    Write-JsonUtf8NoBom -Path $configPath -Value $config
    Invoke-ResolverChild -ExpectedExit 1 | Out-Null

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
        -not $deploymentResult.process_failure_retained) {
        throw "Deployment wrapper self-test did not return its complete passing contract."
    }

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
