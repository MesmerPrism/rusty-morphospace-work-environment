Set-StrictMode -Version 2.0

# Pure declaration predicates shared by lifecycle admission and workspace
# validation. Availability, historical projections and effects stay with callers.
function Test-MorphospaceDeclaredChangeCategory {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Category, [Parameter(Mandatory)][object]$Lifecycle)
    if (@($Lifecycle.change_categories) -ccontains $Category) { return $true }
    return @($Lifecycle.change_category_aliases | Where-Object {
        [string]$_.alias -eq $Category -and @($Lifecycle.change_categories) -ccontains [string]$_.canonical
    }).Count -eq 1
}

function Get-MorphospaceWritableRepositoryIds {
    param([AllowEmptyCollection()][object[]]$AllowedRepositories, [string]$WorkMode = 'feature')
    foreach ($repository in @($AllowedRepositories)) {
        # Only an explicit validation-only empty path array is membership,
        # rather than write authority. Feature rows never gain this exception.
        if ($WorkMode -ceq 'validation-only' -and $null -ne $repository.allowed_paths -and @($repository.allowed_paths).Count -eq 0) { continue }
        [string]$repository.repo_id
    }
}

Export-ModuleMember -Function Test-MorphospaceDeclaredChangeCategory, Get-MorphospaceWritableRepositoryIds
