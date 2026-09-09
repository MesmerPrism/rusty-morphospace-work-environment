param([switch]$SelfTest)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePreparationRepositoryScope.psm1') -Force

function Assert-PreparationRepositoryScope {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Preparation repository-scope self-test failed: $Message" }
}

function Copy-PreparationRepositoryScopeValue {
    param([object]$Value)
    return $Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json -DateKind String
}

function Assert-PreparationRepositoryScopeRejected {
    param([object[]]$Current,[object[]]$Target,[object[]]$Owners,[string]$Case)
    $rejected = $false
    try { Assert-MorphospacePreparationRepositoryRoots -CurrentRepositories $Current -TargetRepositories $Target -OwnerRepositories $Owners }
    catch { $rejected = $true }
    Assert-PreparationRepositoryScope $rejected "accepted $Case"
}

$current = @(
    [pscustomobject][ordered]@{ repo_id = 'owner'; role = 'core'; path = '../owner'; allowed_paths = @('src/app/'); stable_metadata = [ordered]@{ lane = 'primary'; revision = 1 } },
    [pscustomobject][ordered]@{ repo_id = 'unchanged'; role = 'tool'; path = '../unchanged'; allowed_paths = @('legacy//shape/') }
)
$target = Copy-PreparationRepositoryScopeValue $current
$target[0].allowed_paths = @('src/app/','src/peer/','runtime-host/')
$owners = @(
    [pscustomobject][ordered]@{ repo_id = 'owner'; source_roots = @('src/app/','src/peer/','runtime-host/') },
    [pscustomobject][ordered]@{ repo_id = 'read-only'; source_roots = @('runtime-host/') }
)

Assert-MorphospacePreparationRepositoryRoots -CurrentRepositories $current -TargetRepositories $target -OwnerRepositories $owners
Assert-PreparationRepositoryScope ($target[0].role -ceq 'core' -and $target[0].path -ceq '../owner' -and @($target[0].allowed_paths)[0] -ceq 'src/app/' -and @($target[1].allowed_paths)[0] -ceq 'legacy//shape/') 'positive validation did not preserve unrelated repository fields and existing paths'

$removed = Copy-PreparationRepositoryScopeValue $target
$removed[0].allowed_paths = @('src/peer/','runtime-host/')
Assert-PreparationRepositoryScopeRejected $current $removed $owners 'existing root removal'

$roleRewrite = Copy-PreparationRepositoryScopeValue $target
$roleRewrite[0].role = 'adapter'
Assert-PreparationRepositoryScopeRejected $current $roleRewrite $owners 'role rewrite'

$pathRewrite = Copy-PreparationRepositoryScopeValue $target
$pathRewrite[0].path = '../relocated-owner'
Assert-PreparationRepositoryScopeRejected $current $pathRewrite $owners 'path rewrite'

$unknownRewrite = Copy-PreparationRepositoryScopeValue $target
$unknownRewrite[0].stable_metadata.lane = 'rewritten'
Assert-PreparationRepositoryScopeRejected $current $unknownRewrite $owners 'unknown field rewrite'

$absoluteTestRoot = [IO.Path]::Combine([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($PSScriptRoot)), 'outside-root').Replace('\','/')
foreach ($invalidRoot in @('../escape/',$absoluteTestRoot,'./','src/*/')) {
    $invalid = Copy-PreparationRepositoryScopeValue $current
    $invalid[0].allowed_paths = @('src/app/',$invalidRoot)
    Assert-PreparationRepositoryScopeRejected $current $invalid $owners "invalid new root '$invalidRoot'"
}

$ancestor = Copy-PreparationRepositoryScopeValue $current
$ancestor[0].allowed_paths = @('src/app/','src/')
$ancestorOwners = Copy-PreparationRepositoryScopeValue $owners
$ancestorOwners[0].source_roots += 'src/'
Assert-PreparationRepositoryScopeRejected $current $ancestor $ancestorOwners 'new ancestor overlap'

$broader = Copy-PreparationRepositoryScopeValue $current
$broader[0].allowed_paths = @('src/app/','src/')
Assert-PreparationRepositoryScopeRejected $current $broader $owners 'undeclared broader root'

$caseAlias = Copy-PreparationRepositoryScopeValue $current
$caseAlias[0].allowed_paths = @('src/app/','SRC/app/')
$caseOwners = Copy-PreparationRepositoryScopeValue $owners
$caseOwners[0].source_roots += 'SRC/app/'
Assert-PreparationRepositoryScopeRejected $current $caseAlias $caseOwners 'case-alias root'

$duplicateTarget = Copy-PreparationRepositoryScopeValue $target
$duplicateTarget += [pscustomobject][ordered]@{ repo_id = 'OWNER'; role = 'core'; path = '../another'; allowed_paths = @('other/') }
Assert-PreparationRepositoryScopeRejected $current $duplicateTarget $owners 'case-fold duplicate repository identity'

$duplicateOwner = Copy-PreparationRepositoryScopeValue $owners
$duplicateOwner += [pscustomobject][ordered]@{ repo_id = 'OWNER'; source_roots = @('src/peer/') }
Assert-PreparationRepositoryScopeRejected $current $target $duplicateOwner 'case-fold duplicate owner identity'

$readonlyOnly = Copy-PreparationRepositoryScopeValue $current
$readonlyOnly[0].allowed_paths = @('src/app/','runtime-host/')
$readonlyOwners = Copy-PreparationRepositoryScopeValue $owners
$readonlyOwners[0].source_roots = @('src/app/','src/peer/')
Assert-PreparationRepositoryScopeRejected $current $readonlyOnly $readonlyOwners 'read-only-only source-root absence'

Write-Host 'Preparation repository-scope self-test passed.'
