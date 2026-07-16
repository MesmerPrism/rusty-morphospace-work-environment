param()

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Git {
    param([string]$Root, [string[]]$Arguments)
    $output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed in '$Root': git $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return @($output)
}

function New-FixtureRepository {
    param([string]$Path, [string]$Name)
    [void][IO.Directory]::CreateDirectory($Path)
    Invoke-Git $Path @("init", "--quiet") | Out-Null
    Invoke-Git $Path @("config", "user.email", "isolation-test@example.invalid") | Out-Null
    Invoke-Git $Path @("config", "user.name", "Isolation Test") | Out-Null
    [IO.File]::WriteAllText((Join-Path $Path "README.md"), "# $Name`n", [Text.UTF8Encoding]::new($false))
    Invoke-Git $Path @("add", "README.md") | Out-Null
    Invoke-Git $Path @("commit", "--quiet", "-m", "fixture") | Out-Null
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("rusty-morphospace-isolation-" + [guid]::NewGuid().ToString("N"))
$workspace = Join-Path $tempRoot "workspace\morphospace"
$repoA = Join-Path $tempRoot "repos\source-a"
$repoB = Join-Path $tempRoot "repos\source-b"
$mapPath = Join-Path $tempRoot "repository-map.json"
$materializationRoot = Join-Path $tempRoot "materializations"
$registryRoot = Join-Path $tempRoot "claims"

try {
    New-FixtureRepository -Path $repoA -Name "source-a"
    New-FixtureRepository -Path $repoB -Name "source-b"
    [void][IO.Directory]::CreateDirectory((Join-Path $workspace "iteration-units"))

    $spec = [ordered]@{ schema = "fixture"; project_id = "isolation-project" }
    $unit = [ordered]@{ schema = "fixture"; unit_id = "isolation-unit"; project_id = "isolation-project" }
    $map = [ordered]@{
        schema = "rusty.morphospace.workflow.repository_map.v1"
        repositories = @(
            [ordered]@{ repo_id = "source-a"; path = $repoA; role = "source" },
            [ordered]@{ repo_id = "source-b"; path = $repoB; role = "source" }
        )
    }
    $jsonOptions = @{ Depth = 12 }
    [IO.File]::WriteAllText((Join-Path $workspace "project.spec.json"), (($spec | ConvertTo-Json @jsonOptions) + "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $workspace "iteration-units\isolation-unit.json"), (($unit | ConvertTo-Json @jsonOptions) + "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($mapPath, (($map | ConvertTo-Json @jsonOptions) + "`n"), [Text.UTF8Encoding]::new($false))

    $lockRelative = "source-compositions/isolation-unit.lock.json"
    $lockPath = Join-Path $workspace $lockRelative
    $plan = & (Join-Path $PSScriptRoot "New-SourceCompositionLock.ps1") -WorkspaceRoot $workspace -UnitId "isolation-unit" -RepositoryMapPath $mapPath -OutRelativePath $lockRelative | ConvertFrom-Json
    Assert-True ($plan.status -eq "locked") "Source composition plan did not resolve a locked identity."
    Assert-True (-not [IO.File]::Exists($lockPath)) "Source composition planning wrote a lock."

    $lock = & (Join-Path $PSScriptRoot "New-SourceCompositionLock.ps1") -WorkspaceRoot $workspace -UnitId "isolation-unit" -RepositoryMapPath $mapPath -OutRelativePath $lockRelative -Execute | ConvertFrom-Json
    Assert-True ([IO.File]::Exists($lockPath)) "Source composition execution did not write its lock."
    Assert-True (@($lock.repositories).Count -eq 2) "Source composition did not bind both repositories."
    Assert-True ([string]$lock.fingerprint -match "^[0-9a-f]{64}$") "Source composition fingerprint is invalid."

    $materializationPlan = & (Join-Path $PSScriptRoot "New-SourceMaterialization.ps1") -LockPath $lockPath -RepositoryMapPath $mapPath -MaterializationRoot $materializationRoot | ConvertFrom-Json
    Assert-True (-not [IO.Directory]::Exists([string]$materializationPlan.root)) "Source materialization planning created its target."
    $receipt = & (Join-Path $PSScriptRoot "New-SourceMaterialization.ps1") -LockPath $lockPath -RepositoryMapPath $mapPath -MaterializationRoot $materializationRoot -Execute | ConvertFrom-Json
    Assert-True ([IO.Directory]::Exists([string]$receipt.root)) "Exact source materialization is missing."
    foreach ($repository in @($receipt.repositories)) {
        $branch = ([string]@(Invoke-Git ([string]$repository.path) @("rev-parse", "--abbrev-ref", "HEAD"))[0]).Trim()
        $status = @(Invoke-Git ([string]$repository.path) @("status", "--porcelain=v1", "--untracked-files=all"))
        Assert-True ($branch -eq "HEAD") "Materialized repository is not detached: $($repository.repo_id)"
        Assert-True ($status.Count -eq 0) "Materialized repository is not clean: $($repository.repo_id)"
    }
    $duplicateFailed = $false
    try {
        & (Join-Path $PSScriptRoot "New-SourceMaterialization.ps1") -LockPath $lockPath -RepositoryMapPath $mapPath -MaterializationRoot $materializationRoot -Execute | Out-Null
    } catch {
        $duplicateFailed = $true
    }
    Assert-True $duplicateFailed "Existing content-addressed source materialization was overwritten."

    $claimScript = Join-Path $PSScriptRoot "Invoke-ResourceClaim.ps1"
    $claimPlan = & $claimScript -Action Acquire -RegistryRoot $registryRoot -ClaimId "claim-one" -ProjectId "isolation-project" -UnitId "isolation-unit" -ResourceKind "build-output" -ResourceId (Join-Path $tempRoot "builds\app") | ConvertFrom-Json
    Assert-True (-not [IO.File]::Exists((Join-Path $registryRoot "claims.json"))) "Resource claim planning wrote the registry."
    Assert-True ($claimPlan.action -eq "acquire") "Resource claim plan has the wrong action."
    & $claimScript -Action Acquire -RegistryRoot $registryRoot -ClaimId "claim-one" -ProjectId "isolation-project" -UnitId "isolation-unit" -ResourceKind "build-output" -ResourceId (Join-Path $tempRoot "builds\app") -Execute | Out-Null
    $conflictFailed = $false
    try {
        & $claimScript -Action Acquire -RegistryRoot $registryRoot -ClaimId "claim-two" -ProjectId "other-project" -UnitId "other-unit" -ResourceKind "build-output" -ResourceId (Join-Path $tempRoot "builds\app\nested") -Execute | Out-Null
    } catch {
        $conflictFailed = $true
    }
    Assert-True $conflictFailed "Overlapping exclusive resource claims were both accepted."
    & $claimScript -Action Release -RegistryRoot $registryRoot -ClaimId "claim-one" -Execute | Out-Null
    & $claimScript -Action Acquire -RegistryRoot $registryRoot -ClaimId "claim-two" -ProjectId "other-project" -UnitId "other-unit" -ResourceKind "build-output" -ResourceId (Join-Path $tempRoot "builds\app\nested") -Execute | Out-Null

    Write-Output "Project isolation validation passed."
} finally {
    if ([IO.Directory]::Exists($tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
