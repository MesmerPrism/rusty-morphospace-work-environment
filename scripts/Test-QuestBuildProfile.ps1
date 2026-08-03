param([string]$RepoRoot = "")

$ErrorActionPreference = "Stop"
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$runner = Join-Path $RepoRoot "scripts\Invoke-QuestBuildProfile.ps1"
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("quest-build-profile-e2e-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path (Join-Path $root "out") -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $root "build.ps1"),
        "param([string]`$Output)`n[System.IO.File]::WriteAllBytes((Join-Path `$PSScriptRoot `$Output), [byte[]](1,2,3,4))`n",
        [System.Text.UTF8Encoding]::new($false))
    $profilePath = Join-Path $root "profile.json"
    [ordered]@{
        schema = "rusty.morphospace.quest_build_profile.v1"
        profile_id = "fixture-apk"
        working_directory = "."
        executable = "build.ps1"
        arguments = @("out\fixture.apk")
        artifact = [ordered]@{ relative_path = "out\fixture.apk"; kind = "single-base-apk" }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $profilePath -Encoding utf8NoBOM
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $profilePath).Hash.ToLowerInvariant()
    $receiptPath = Join-Path $root "receipt.json"
    $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner `
        -ProfilePath $profilePath -ProfileSha256 $sha -SourceRoot $root -ReceiptPath $receiptPath
    if ($LASTEXITCODE -ne 0) { throw "Build-profile fixture execution failed." }
    $receipt = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    if ([string]$receipt.status -cne "passed" -or
        [long]$receipt.artifact.size_bytes -ne 4 -or
        -not (Test-Path -LiteralPath $receipt.artifact.path -PathType Leaf)) {
        throw "Build-profile fixture receipt is invalid."
    }
    $rejected = $false
    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner `
            -ProfilePath $profilePath -ProfileSha256 ("0" * 64) -SourceRoot $root `
            -ReceiptPath (Join-Path $root "bad.json") 2>$null | Out-Null
    } catch { $rejected = $true }
    if ($LASTEXITCODE -ne 0) { $rejected = $true }
    if (-not $rejected) { throw "Build-profile runner accepted a wrong profile digest." }
    Write-Host "Quest build-profile execution and tamper rejection passed."
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
