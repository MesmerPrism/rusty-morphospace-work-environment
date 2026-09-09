Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')

function Get-MorphospacePreparationProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context is missing '$Name'." }
    return $property.Value
}

function Get-MorphospacePreparationRepositoryIndex {
    param(
        [Parameter(Mandatory = $true)][object[]]$Repositories,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $index = @{}
    foreach ($repository in @($Repositories)) {
        if ($null -eq $repository) { throw "$Context contains a null repository record." }
        $repoId = [string](Get-MorphospacePreparationProperty $repository 'repo_id' "$Context repository")
        if ([string]::IsNullOrWhiteSpace($repoId)) { throw "$Context contains a missing repository identity." }
        if ($index.ContainsKey($repoId)) { throw "$Context repeats repository identity '$repoId' case-insensitively." }
        $index[$repoId] = $repository
    }
    return $index
}

function Get-MorphospacePreparationRecordWithoutAllowedPaths {
    param([Parameter(Mandatory = $true)][object]$Repository)

    $copy = [ordered]@{}
    foreach ($property in @($Repository.PSObject.Properties)) {
        if ($property.Name -cne 'allowed_paths') { $copy[$property.Name] = $property.Value }
    }
    return [pscustomobject]$copy
}

function Get-MorphospacePreparationRoots {
    param(
        [Parameter(Mandatory = $true)][object]$Repository,
        [Parameter(Mandatory = $true)][string]$Context
    )

    return @((Get-MorphospacePreparationProperty $Repository 'allowed_paths' $Context))
}

function Get-MorphospacePreparationCanonicalRoot {
    param(
        [Parameter(Mandatory = $true)][object]$Root,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Root -isnot [string]) { throw "$Context must be a string." }
    if ($Root -match '[*?\[\]]') { throw "$Context must not contain a wildcard." }
    $directory = $Root.EndsWith('/', [StringComparison]::Ordinal)
    $body = if ($directory) { $Root.TrimEnd('/') } else { $Root }
    if ([string]::IsNullOrEmpty($body) -or $body -ceq '.') { throw "$Context must name a bounded relative path." }
    $canonical = ConvertTo-MorphospaceProtocolRelativePath -Path $body
    if ($directory) { $canonical += '/' }
    if ($canonical -cne $Root) { throw "$Context is not a canonical portable relative path." }
    return $canonical
}

function Test-MorphospacePreparationRootOverlap {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftBody = $Left.TrimEnd('/')
    $rightBody = $Right.TrimEnd('/')
    return $leftBody.Equals($rightBody, [StringComparison]::OrdinalIgnoreCase) -or
        $leftBody.StartsWith($rightBody + '/', [StringComparison]::OrdinalIgnoreCase) -or
        $rightBody.StartsWith($leftBody + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-MorphospacePreparationRepositoryRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$CurrentRepositories,
        [Parameter(Mandatory = $true)][object[]]$TargetRepositories,
        [Parameter(Mandatory = $true)][object[]]$OwnerRepositories
    )

    $currentById = Get-MorphospacePreparationRepositoryIndex -Repositories $CurrentRepositories -Context 'Current preparation repositories'
    $targetById = Get-MorphospacePreparationRepositoryIndex -Repositories $TargetRepositories -Context 'Target preparation repositories'
    $ownerById = Get-MorphospacePreparationRepositoryIndex -Repositories $OwnerRepositories -Context 'Reviewed owner repositories'

    foreach ($repoId in $currentById.Keys) {
        if (-not $targetById.ContainsKey($repoId)) { throw "Preparation removes existing repository '$repoId'." }

        $current = $currentById[$repoId]
        $target = $targetById[$repoId]
        if ((Get-MorphospaceCanonicalJsonSha256 (Get-MorphospacePreparationRecordWithoutAllowedPaths $current)) -cne
            (Get-MorphospaceCanonicalJsonSha256 (Get-MorphospacePreparationRecordWithoutAllowedPaths $target))) {
            throw "Preparation rewrites existing repository '$repoId' outside allowed_paths."
        }

        $remainingCurrentRoots = [Collections.Generic.List[object]]::new()
        foreach ($root in @(Get-MorphospacePreparationRoots $current "Current repository '$repoId'")) { $remainingCurrentRoots.Add($root) }
        $newRoots = [Collections.Generic.List[object]]::new()
        foreach ($targetRoot in @(Get-MorphospacePreparationRoots $target "Target repository '$repoId'")) {
            $matchIndex = -1
            for ($index = 0; $index -lt $remainingCurrentRoots.Count; $index++) {
                if ($remainingCurrentRoots[$index] -ceq $targetRoot) { $matchIndex = $index; break }
            }
            if ($matchIndex -ge 0) { $remainingCurrentRoots.RemoveAt($matchIndex) }
            else { $newRoots.Add($targetRoot) }
        }
        if ($remainingCurrentRoots.Count -ne 0) { throw "Preparation removes an existing allowed path from repository '$repoId'." }

        if ($newRoots.Count -eq 0) { continue }
        if (-not $ownerById.ContainsKey($repoId)) { throw "Preparation adds roots for '$repoId' without reviewed owner source-root authority." }
        $ownerRoots = @(Get-MorphospacePreparationProperty $ownerById[$repoId] 'source_roots' "Reviewed owner repository '$repoId'")
        $checkedNewRoots = [Collections.Generic.List[string]]::new()
        foreach ($newRootValue in @($newRoots.ToArray())) {
            $newRoot = Get-MorphospacePreparationCanonicalRoot -Root $newRootValue -Context "Preparation new root '$repoId/$newRootValue'"
            foreach ($existingRoot in @(Get-MorphospacePreparationRoots $current "Current repository '$repoId'")) {
                if ($existingRoot -is [string] -and (Test-MorphospacePreparationRootOverlap -Left $newRoot -Right $existingRoot)) {
                    throw "Preparation new root '$repoId/$newRoot' overlaps an existing allowed path."
                }
            }
            foreach ($otherNewRoot in @($checkedNewRoots.ToArray())) {
                if (Test-MorphospacePreparationRootOverlap -Left $newRoot -Right $otherNewRoot) {
                    throw "Preparation new root '$repoId/$newRoot' overlaps another added root."
                }
            }
            if (@($ownerRoots | Where-Object { $_ -is [string] -and $_ -ceq $newRoot }).Count -eq 0) {
                throw "Preparation new root '$repoId/$newRoot' is not an exact reviewed owner source root."
            }
            $checkedNewRoots.Add($newRoot)
        }
    }
}

Export-ModuleMember -Function Assert-MorphospacePreparationRepositoryRoots
