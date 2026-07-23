param([switch]$SelfTest)

$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "Invoke-ProtectedBranchPushGuard.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("morphospace-protected-push-" + [guid]::NewGuid().ToString("N"))

function Invoke-TestGit([string[]]$Arguments) {
    $output = & git -C $root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $output" }
    return ([string]($output -join "`n")).Trim()
}
function Assert-Reject([string]$Update) {
    Set-Content -LiteralPath $inputPath -Value $Update -Encoding utf8NoBOM
    & pwsh -NoProfile -File $scriptPath -RepositoryPath $root -ProtectedBranch "codex/example" -UpdatePath $inputPath -CanonicalUpdatePath $outputPath *> $null
    if ($LASTEXITCODE -eq 0) { throw "Expected protected push input to reject: $Update" }
}

try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Invoke-TestGit @("init", "--quiet") | Out-Null
    Invoke-TestGit @("config", "user.email", "test@example.invalid") | Out-Null
    Invoke-TestGit @("config", "user.name", "Workflow Test") | Out-Null
    Set-Content -LiteralPath (Join-Path $root "seed.txt") -Value "seed" -Encoding utf8NoBOM
    Invoke-TestGit @("add", "seed.txt") | Out-Null
    Invoke-TestGit @("commit", "--quiet", "-m", "seed") | Out-Null
    Invoke-TestGit @("branch", "-M", "codex/example") | Out-Null
    $head = Invoke-TestGit @("rev-parse", "HEAD")
    $zero = "0" * 40
    $inputPath = Join-Path $root "updates.txt"
    $outputPath = Join-Path $root "canonical.txt"
    Set-Content -LiteralPath $inputPath -Value "HEAD $head refs/heads/codex/example $zero" -Encoding utf8NoBOM
    & pwsh -NoProfile -File $scriptPath -RepositoryPath $root -ProtectedBranch "codex/example" -UpdatePath $inputPath -CanonicalUpdatePath $outputPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Explicit HEAD protected update should pass." }
    $expected = "refs/heads/codex/example $head refs/heads/codex/example $zero"
    if ((Get-Content -Raw -LiteralPath $outputPath).Trim() -cne $expected) { throw "Canonical protected update mismatch." }
    Set-Content -LiteralPath $inputPath -Value "HEAD $head refs/heads/unrelated $zero" -Encoding utf8NoBOM
    & pwsh -NoProfile -File $scriptPath -RepositoryPath $root -ProtectedBranch "codex/example" -UpdatePath $inputPath -CanonicalUpdatePath $outputPath | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Get-Content -Raw -LiteralPath $outputPath).Length -ne 0) { throw "Unrelated destination should pass without a protected update." }
    Assert-Reject "(delete) $zero refs/heads/codex/example $head"
    Assert-Reject "HEAD $head refs/heads/codex/example $zero`nrefs/heads/codex/example $head refs/heads/codex/example $zero"
    Assert-Reject "malformed"
    Invoke-TestGit @("checkout", "--quiet", "--detach", "HEAD") | Out-Null
    Assert-Reject "HEAD $head refs/heads/codex/example $zero"
    Write-Output "PASS: protected branch push guard"
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -Recurse -Force -LiteralPath $root }
}
