[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$AssertCurrent,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Source and digest are from the PowerShell project's v7.6.6 release notes.
# Keep the archive URL versioned; never resolve a floating latest release.
$version = '7.6.6'
$archiveUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'
$archiveSha256 = '02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860'

function Assert-Identity {
    param([string]$ActualPath, [string]$ExpectedPath, [string]$ActualVersion,
          [string]$ExpectedVersion, [string]$ActualExecutableSha256,
          [string]$ExpectedExecutableSha256)
    if (-not [IO.Path]::GetFullPath($ActualPath).Equals(
            [IO.Path]::GetFullPath($ExpectedPath), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Affected Windows segment did not run under the pinned PowerShell executable.'
    }
    if ($ActualVersion -cne $ExpectedVersion) {
        throw 'Affected Windows segment PowerShell version differs from the reviewed pin.'
    }
    if ($ActualExecutableSha256 -cne $ExpectedExecutableSha256) {
        throw 'Affected Windows segment PowerShell executable bytes differ from the reviewed installation.'
    }
}

if ([int][bool]$Install + [int][bool]$AssertCurrent + [int][bool]$SelfTest -ne 1) {
    throw 'Select exactly one pinned PowerShell operation.'
}

if ($SelfTest) {
    $expectedPath = Join-Path ([IO.Path]::GetTempPath()) 'pinned-pwsh/pwsh.exe'
    $digest = 'a' * 64
    Assert-Identity $expectedPath $expectedPath $version $version $digest $digest
    foreach ($case in @(
        @{ path = (Join-Path ([IO.Path]::GetTempPath()) 'ambient-pwsh/pwsh.exe'); version = $version; hash = $digest },
        @{ path = $expectedPath; version = '7.6.5'; hash = $digest },
        @{ path = $expectedPath; version = $version; hash = ('b' * 64) }
    )) {
        $rejected = $false
        try { Assert-Identity $case.path $expectedPath $case.version $version $case.hash $digest }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Pinned PowerShell drift self-test accepted a changed identity.' }
    }
    Write-Host 'Pinned Windows PowerShell identity self-test passed.'
    return
}

if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne
        [Runtime.InteropServices.Architecture]::X64) {
    throw 'The reviewed PowerShell archive supports only Windows x64 segment jobs.'
}
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'RUNNER_TEMP is required.' }
$installRoot = Join-Path $env:RUNNER_TEMP 'affected-pwsh-7.6.6-win-x64'
$archivePath = Join-Path $env:RUNNER_TEMP 'affected-pwsh-7.6.6-win-x64.zip'
$executable = Join-Path $installRoot 'pwsh.exe'
$executableDigestPath = Join-Path $installRoot 'pwsh.exe.sha256'

if ($Install) {
    if ([IO.Directory]::Exists($installRoot) -or [IO.File]::Exists($archivePath)) {
        throw 'Pinned PowerShell output already exists.'
    }
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) { throw 'GITHUB_PATH is required.' }
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -MaximumRedirection 5 -TimeoutSec 180
    $actualArchiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualArchiveSha256 -cne $archiveSha256) {
        throw 'Downloaded PowerShell archive differs from the reviewed upstream SHA-256.'
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $installRoot)
    if (-not [IO.File]::Exists($executable)) { throw 'Pinned PowerShell executable is absent.' }
    $reportedVersion = @(& $executable -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()')
    if ($LASTEXITCODE -ne 0 -or $reportedVersion.Count -ne 1 -or
            [string]$reportedVersion[0] -cne $version) {
        throw 'Pinned PowerShell executable did not report the reviewed version.'
    }
    $executableSha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($executableDigestPath, $executableSha256 + "`n", [Text.UTF8Encoding]::new($false))
    Add-Content -LiteralPath $env:GITHUB_PATH -Value $installRoot
    Write-Host "Installed reviewed PowerShell $version for this Windows segment job."
    return
}

if (-not [IO.File]::Exists($executable) -or -not [IO.File]::Exists($executableDigestPath)) {
    throw 'Pinned PowerShell installation is incomplete.'
}
$expectedExecutableSha256 = [IO.File]::ReadAllText($executableDigestPath).Trim()
if ($expectedExecutableSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Pinned PowerShell executable digest record is invalid.'
}
$actualExecutableSha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
$currentExecutable = (Get-Process -Id $PID).Path
Assert-Identity $currentExecutable $executable $PSVersionTable.PSVersion.ToString() $version `
    $actualExecutableSha256 $expectedExecutableSha256
Write-Host "Running under reviewed PowerShell $version."
