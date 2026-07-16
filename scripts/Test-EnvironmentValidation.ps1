param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$validator = Join-Path $RepoRoot "scripts\Test-WorkEnvironment.ps1"
$hostExecutable = (Get-Process -Id $PID).Path
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("rusty-morphospace-environment-validation-" + [guid]::NewGuid().ToString("N"))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Config {
    param([string]$Path, [object]$Value)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8) + [Environment]::NewLine, $utf8NoBom)
}

function Write-FakeCommand {
    param(
        [string]$Directory,
        [string]$Name,
        [string]$Output,
        [switch]$StandardError
    )

    if ($IsWindows) {
        $path = Join-Path $Directory ($Name + ".cmd")
        $redirect = if ($StandardError) { " 1^>^&2" } else { "" }
        [System.IO.File]::WriteAllText($path, "@echo $Output$redirect`r`n", $utf8NoBom)
        return
    }

    $path = Join-Path $Directory $Name
    $redirect = if ($StandardError) { " >&2" } else { "" }
    [System.IO.File]::WriteAllText($path, "#!/bin/sh`nprintf '%s\n' '$Output'$redirect`n", $utf8NoBom)
    [System.IO.File]::SetUnixFileMode(
        $path,
        [System.IO.UnixFileMode]::UserRead -bor
        [System.IO.UnixFileMode]::UserWrite -bor
        [System.IO.UnixFileMode]::UserExecute -bor
        [System.IO.UnixFileMode]::GroupRead -bor
        [System.IO.UnixFileMode]::GroupExecute -bor
        [System.IO.UnixFileMode]::OtherRead -bor
        [System.IO.UnixFileMode]::OtherExecute
    )
}

function Invoke-EnvironmentChild {
    param(
        [string]$ConfigPath,
        [string]$Profile,
        [int]$ExpectedExit,
        [string]$ExpectedText,
        [string]$PathPrefix = ""
    )

    $oldPath = $env:PATH
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        if ($PathPrefix) {
            $env:PATH = $PathPrefix + [System.IO.Path]::PathSeparator + $oldPath
        }
        $ErrorActionPreference = "Continue"
        $output = @(& $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $validator -ConfigPath $ConfigPath -Profile $Profile -Strict 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:PATH = $oldPath
        $ErrorActionPreference = $oldErrorActionPreference
    }
    $text = $output -join [Environment]::NewLine
    if ($exitCode -ne $ExpectedExit) {
        throw "Environment validator exit $exitCode; expected $ExpectedExit. Output: $text"
    }
    if ($ExpectedText -and $text -notmatch [regex]::Escape($ExpectedText)) {
        throw "Environment validator output did not contain '$ExpectedText'. Output: $text"
    }
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $valid = [ordered]@{
        schema = "rusty.morphospace.work_environment.local_paths.v1"
        workspace_root = $testRoot
        work_environment_root = $RepoRoot
        repos_root = $testRoot
        artifacts_root = $testRoot
        skills_root = $testRoot
        android = [ordered]@{
            sdk_root = $testRoot
            ndk_root = $testRoot
            jdk_root = $testRoot
            openxr_loader_quest = "<openxr-loader-so>"
        }
        repos = [ordered]@{ example_repo = $testRoot }
    }

    $validPath = Join-Path $testRoot "valid.json"
    Write-Config -Path $validPath -Value $valid
    Invoke-EnvironmentChild -ConfigPath $validPath -Profile "Core" -ExpectedExit 0 -ExpectedText "Environment check complete."

    $placeholder = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $placeholder.workspace_root = "<workspace-root>"
    $placeholderPath = Join-Path $testRoot "placeholder.json"
    Write-Config -Path $placeholderPath -Value $placeholder
    Invoke-EnvironmentChild -ConfigPath $placeholderPath -Profile "Core" -ExpectedExit 1 -ExpectedText "workspace_root"

    $missingRepo = $valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $missingRepo.repos.example_repo = Join-Path $testRoot "does-not-exist"
    $missingRepoPath = Join-Path $testRoot "missing-repo.json"
    Write-Config -Path $missingRepoPath -Value $missingRepo
    Invoke-EnvironmentChild -ConfigPath $missingRepoPath -Profile "Core" -ExpectedExit 1 -ExpectedText "repos.example_repo"

    $oldPythonRoot = Join-Path $testRoot "old-python"
    New-Item -ItemType Directory -Force -Path $oldPythonRoot | Out-Null
    Write-FakeCommand -Directory $oldPythonRoot -Name "python" -Output "Python 3.10.9"
    Invoke-EnvironmentChild -ConfigPath $validPath -Profile "Core" -ExpectedExit 1 -ExpectedText "version-too-old" -PathPrefix $oldPythonRoot

    $oldJavaRoot = Join-Path $testRoot "old-java"
    New-Item -ItemType Directory -Force -Path $oldJavaRoot | Out-Null
    Write-FakeCommand -Directory $oldJavaRoot -Name "java" -Output "openjdk version 16.0.2" -StandardError
    Invoke-EnvironmentChild -ConfigPath $validPath -Profile "Quest" -ExpectedExit 1 -ExpectedText "version-too-old" -PathPrefix $oldJavaRoot

    Write-Host "Environment validation regression tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        if (-not $resolved.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an environment-validation test path outside the system temporary directory."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
