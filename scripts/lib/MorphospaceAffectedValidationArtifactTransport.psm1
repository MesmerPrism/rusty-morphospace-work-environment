Set-StrictMode -Version 2.0

function ConvertFrom-MorphospaceAffectedArtifactPositiveInteger {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Value -notmatch '^[1-9][0-9]*$') {
        throw "Affected-validation artifact $Context must be a canonical positive integer."
    }
    [UInt64]$parsed = 0
    if (-not [UInt64]::TryParse($Value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        throw "Affected-validation artifact $Context exceeds UInt64."
    }
    return $parsed
}

function ConvertFrom-MorphospaceAffectedArtifactName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$CurrentAttempt
    )

    if ($CurrentAttempt -lt 1) { throw 'Affected-validation artifact current attempt must be positive.' }
    $expectedRun = ConvertFrom-MorphospaceAffectedArtifactPositiveInteger -Value $RunId -Context 'run ID'

    $match = [regex]::Match(
        $Name,
        '\A(?:affected-(?<aggregate>plan|linux|windows)|affected-segment-(?<segmentPlatform>linux|windows)-(?<segmentNumber>[0-9]{3}))-(?<digest>[0-9a-f]{64})-(?<run>[1-9][0-9]*)-(?<attempt>[1-9][0-9]*)\z',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) { throw "Affected-validation artifact name is invalid: $Name" }

    $artifactRun = ConvertFrom-MorphospaceAffectedArtifactPositiveInteger -Value ([string]$match.Groups['run'].Value) -Context "run ID in '$Name'"
    $artifactAttempt = ConvertFrom-MorphospaceAffectedArtifactPositiveInteger -Value ([string]$match.Groups['attempt'].Value) -Context "attempt in '$Name'"
    if ($artifactRun -ne $expectedRun) { throw "Affected-validation artifact is from the wrong run: $Name" }
    if ($artifactAttempt -gt [UInt64]$CurrentAttempt) { throw "Affected-validation artifact is from a future attempt: $Name" }

    $kind = $null
    $logicalId = $null
    if ($match.Groups['aggregate'].Success) {
        $kind = [string]$match.Groups['aggregate'].Value
        $logicalId = $kind
    } else {
        $kind = 'segment'
        $logicalId = "$([string]$match.Groups['segmentPlatform'].Value)-$([string]$match.Groups['segmentNumber'].Value)"
    }
    $payloadFileName = switch ($kind) {
        'plan' { 'affected-plan.json' }
        'linux' { 'affected-linux-evidence.json' }
        'windows' { 'affected-windows-evidence.json' }
        'segment' { "$logicalId.json" }
        default { throw "Affected-validation artifact kind is unsupported: $kind" }
    }

    return [pscustomobject][ordered]@{
        kind = $kind
        logical_id = $logicalId
        digest = [string]$match.Groups['digest'].Value
        run_id = [string]$match.Groups['run'].Value
        attempt = [UInt64]$artifactAttempt
        file_name = $payloadFileName
    }
}

function Select-MorphospaceAffectedArtifactAttempts {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExpectedIds,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$CurrentAttempt
    )

    if ($ExpectedIds.Count -eq 0) { throw 'Affected-validation artifact selection requires expected logical IDs.' }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $ExpectedIds) {
        if ([string]::IsNullOrEmpty($id) -or -not $expected.Add($id)) {
            throw "Affected-validation artifact expected logical IDs are missing or duplicate: $id"
        }
    }

    $byLogicalId = @{}
    foreach ($artifact in $Artifacts) {
        if ($null -eq $artifact -or $null -eq $artifact.PSObject.Properties['name']) {
            throw 'Affected-validation artifact selection input has no name member.'
        }
        $identity = ConvertFrom-MorphospaceAffectedArtifactName -Name ([string]$artifact.name) -RunId $RunId -CurrentAttempt $CurrentAttempt
        if (-not $expected.Contains([string]$identity.logical_id)) {
            throw "Affected-validation artifact names an unexpected logical ID: $($identity.logical_id)"
        }
        $key = [string]$identity.logical_id
        if (-not $byLogicalId.ContainsKey($key)) { $byLogicalId[$key] = [Collections.Generic.List[object]]::new() }
        $byLogicalId[$key].Add([pscustomobject][ordered]@{ artifact=$artifact; identity=$identity })
    }

    $selected = [Collections.Generic.List[object]]::new()
    foreach ($expectedId in $ExpectedIds) {
        if (-not $byLogicalId.ContainsKey($expectedId)) { throw "Affected-validation artifact selection is missing '$expectedId'." }
        $candidates = @($byLogicalId[$expectedId].ToArray())
        [UInt64]$maximumAttempt = 0
        foreach ($candidate in $candidates) {
            if ([UInt64]$candidate.identity.attempt -gt $maximumAttempt) { $maximumAttempt = [UInt64]$candidate.identity.attempt }
        }
        $winners = @($candidates | Where-Object { [UInt64]$_.identity.attempt -eq $maximumAttempt })
        if ($winners.Count -ne 1) { throw "Affected-validation artifact selection has duplicate candidates at winning attempt for '$expectedId'." }
        $selected.Add($winners[0])
    }
    return @($selected.ToArray())
}

Export-ModuleMember -Function ConvertFrom-MorphospaceAffectedArtifactName, Select-MorphospaceAffectedArtifactAttempts
