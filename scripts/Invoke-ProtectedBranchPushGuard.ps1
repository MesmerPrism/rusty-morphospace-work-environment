param(
    [Parameter(Mandatory = $true)][string]$RepositoryPath,
    [Parameter(Mandatory = $true)][string]$ProtectedBranch,
    [Parameter(Mandatory = $true)][string]$UpdatePath,
    [Parameter(Mandatory = $true)][string]$CanonicalUpdatePath
)

$ErrorActionPreference = "Stop"

function Invoke-GitText {
    param([string[]]$Arguments)
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $output" }
    return ([string]($output -join "`n")).Trim()
}

$repository = (Resolve-Path -LiteralPath $RepositoryPath).Path
$protectedRef = "refs/heads/$ProtectedBranch"
$matches = @()
foreach ($line in @(Get-Content -LiteralPath $UpdatePath)) {
    $parts = @($line -split "\s+")
    if ($parts.Count -ne 4) { throw "Malformed Git pre-push update line." }
    if ($parts[2] -eq $protectedRef) {
        $matches += [pscustomobject]@{ local_ref=$parts[0]; local_sha=$parts[1]; remote_ref=$parts[2]; remote_sha=$parts[3] }
    }
}
if ($matches.Count -eq 0) {
    Set-Content -LiteralPath $CanonicalUpdatePath -Value @() -Encoding utf8NoBOM
    Write-Output "PASS: no protected branch destination update"
    exit 0
}
if ($matches.Count -ne 1) { throw "Expected exactly one protected branch destination update." }
$update = $matches[0]
if ($update.local_sha -match '^0+$') { throw "Deleting the protected branch is forbidden." }
$currentBranch = Invoke-GitText @("branch", "--show-current")
if ($currentBranch -cne $ProtectedBranch) { throw "Protected branch push must originate from the attached protected branch." }
$branchRevision = Invoke-GitText @("rev-parse", "$protectedRef^{commit}")
$localRevision = Invoke-GitText @("rev-parse", "$($update.local_sha)^{commit}")
if ($branchRevision -cne $localRevision) { throw "Protected branch revision does not match the pushed local revision." }
Set-Content -LiteralPath $CanonicalUpdatePath -Value "$protectedRef $localRevision $protectedRef $($update.remote_sha)" -Encoding utf8NoBOM
Write-Output "PASS: resolved $($update.local_ref) to attached protected branch $ProtectedBranch"
