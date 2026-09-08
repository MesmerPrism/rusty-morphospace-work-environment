Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:MorphospaceValidationReceiptSchemas = [ordered]@{
    'rusty.morphospace.workflow.validation_receipt.v1' = 'validation-receipt.schema.json'
    'rusty.morphospace.workflow.validation_receipt.v2' = 'validation-receipt-v2.schema.json'
}
$script:MorphospaceValidationReceiptPathComparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Copy-MorphospaceValidationReceiptValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String
}

function Invoke-MorphospaceValidationReceiptGit {
    param([string]$RepositoryPath,[string[]]$Arguments,[switch]$AllowFailure)
    $observationModule = Get-Variable -Name MorphospaceValidationReceiptObservationModule -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $observationModule) {
        $expectedModulePath = Join-Path $PSScriptRoot 'MorphospaceContentObservation.psm1'
        $expectedModulePath = [IO.Path]::GetFullPath($expectedModulePath)
        $exactModule = @(Get-Module | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path).Equals($expectedModulePath,$script:MorphospaceValidationReceiptPathComparison) } | Select-Object -Last 1)
        if ($exactModule.Count -eq 0) {
            $exactModule = @(Import-Module $expectedModulePath -PassThru -DisableNameChecking -Prefix ValidationReceiptDependency)
        }
        $script:MorphospaceValidationReceiptObservationModule = $exactModule[0]
        $observationModule = $script:MorphospaceValidationReceiptObservationModule
    }
    if ($null -eq (Get-Variable -Name MorphospaceValidationReceiptGit -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
        $script:MorphospaceValidationReceiptGit = & $observationModule { Get-MorphospaceBoundExecutable -Name git }
    }
    $result = & $observationModule {
        param($Executable,$ExecutableSha256,$Root,$GitArguments,$PermitFailure)
        Invoke-MorphospaceBoundGitBytes -GitExecutable $Executable -ExpectedExecutableSha256 $ExecutableSha256 -RepositoryPath $Root -Arguments $GitArguments -TimeoutSeconds 30 -MaxOutputBytes 1048576 -AllowFailure:$PermitFailure
    } $script:MorphospaceValidationReceiptGit.path $script:MorphospaceValidationReceiptGit.sha256 $RepositoryPath $Arguments $AllowFailure.IsPresent
    $utf8 = [Text.UTF8Encoding]::new($false,$true)
    try {
        $stdout = $utf8.GetString([byte[]]$result.stdout)
    } catch {
        throw 'Validation receipt Git observation emitted invalid UTF-8.'
    }
    $lines = if ($stdout.Length -eq 0) { @() } else { @($stdout.TrimEnd("`r","`n").Split("`n") | ForEach-Object { $_.TrimEnd("`r") }) }
    return [pscustomobject]@{ exit_code=[int]$result.exit_code; lines=@($lines); text=$stdout.Trim() }
}

function Test-MorphospaceValidationReceiptPathAllowed {
    param([string]$Path,[object[]]$AllowedPaths)
    foreach ($allowedRaw in @($AllowedPaths)) {
        $allowed = ([string]$allowedRaw).Replace('\','/').TrimEnd('/')
        if ($Path.Equals($allowed,[StringComparison]::Ordinal) -or $Path.StartsWith($allowed + '/', [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Resolve-MorphospaceValidationReceiptWorkspacePath {
    param([string]$Workspace,[string]$RelativePath,[switch]$RequireLeaf)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "Validation receipt authority path must be workspace-relative: $RelativePath" }
    $resolved = [IO.Path]::GetFullPath((Join-Path $Workspace $RelativePath))
    $workspacePrefix = $Workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($workspacePrefix,$script:MorphospaceValidationReceiptPathComparison)) { throw "Validation receipt authority path escapes the workspace: $RelativePath" }
    if ($RequireLeaf -and -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Validation receipt authority file does not exist: $RelativePath" }
    return $resolved
}

function Assert-MorphospaceValidationReceiptNoReparseAncestry {
    param([string]$Workspace,[string]$TargetPath)
    $workspaceRoot = [IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $target = [IO.Path]::GetFullPath($TargetPath)
    $workspacePrefix = $workspaceRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($workspacePrefix,$script:MorphospaceValidationReceiptPathComparison)) { throw 'Generated validation receipt must stay inside the project workspace.' }
    $parent = [IO.Path]::GetDirectoryName($target)
    if ($parent.Equals($workspaceRoot,$script:MorphospaceValidationReceiptPathComparison)) { return }
    $relativeParent = $parent.Substring($workspacePrefix.Length)
    $current = $workspaceRoot
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    foreach ($component in @($relativeParent.Split($separators,[StringSplitOptions]::RemoveEmptyEntries))) {
        $current = Join-Path $current $component
        if (-not (Test-Path -LiteralPath $current)) { break }
        if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Generated validation receipt path traverses a reparse point: $current" }
    }
}

function Get-MorphospaceValidationReceiptFileHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-MorphospaceValidationReceiptStructure {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')][string]$ReceiptPath,
        [Parameter(Mandatory = $true, ParameterSetName = 'Document')][object]$Document,
        [string[]]$AllowedSchemaIds = @($script:MorphospaceValidationReceiptSchemas.Keys)
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
            throw "Validation receipt does not exist: $ReceiptPath"
        }
        $json = Get-Content -LiteralPath $ReceiptPath -Raw
    } else {
        $json = $Document | ConvertTo-Json -Depth 100
    }

    try {
        $receipt = $json | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
    } catch {
        throw "Validation receipt is not valid JSON: $($_.Exception.Message)"
    }

    $schemaId = if ($receipt.PSObject.Properties.Name -contains 'schema') { [string]$receipt.schema } else { '' }
    if (-not $script:MorphospaceValidationReceiptSchemas.Contains($schemaId)) {
        throw "Validation receipt has an unsupported schema ID '$schemaId'."
    }
    if (@($AllowedSchemaIds | Where-Object { [string]$_ -ceq $schemaId }).Count -ne 1) {
        throw "Validation receipt schema '$schemaId' is not allowed by this workflow stage."
    }

    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $schemaPath = Join-Path $repositoryRoot "schemas\$($script:MorphospaceValidationReceiptSchemas[$schemaId])"
    try {
        $valid = Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop
    } catch {
        throw "Validation receipt does not satisfy structural schema '$schemaId': $($_.Exception.Message)"
    }
    if (-not $valid) {
        throw "Validation receipt does not satisfy structural schema '$schemaId'."
    }
    return $receipt
}

function New-MorphospaceValidationReceiptV1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$RepoMapPath,
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$OutPath,
        [string]$CreatedAt = ''
    )

    if ($UnitId -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') { throw 'Validation receipt generation UnitId is invalid.' }
    $workspace = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path).TrimEnd('\','/')
    $output = if ([IO.Path]::IsPathRooted($OutPath)) { [IO.Path]::GetFullPath($OutPath) } else { [IO.Path]::GetFullPath((Join-Path $workspace $OutPath)) }
    $workspacePrefix = $workspace + [IO.Path]::DirectorySeparatorChar
    if (-not $output.StartsWith($workspacePrefix,$script:MorphospaceValidationReceiptPathComparison)) { throw 'Generated validation receipt must stay inside the project workspace.' }
    Assert-MorphospaceValidationReceiptNoReparseAncestry $workspace $output
    if (Test-Path -LiteralPath $output) { throw "Generated validation receipt already exists: $output" }
    $outputDirectory = Split-Path -Parent $output

    $Evidence = Copy-MorphospaceValidationReceiptValue $Evidence
    $requiredEvidenceProperties = @('receipt_id','tier','result','artifacts','criteria','gates','device_validation')
    $actualEvidenceProperties = @($Evidence.PSObject.Properties.Name | Sort-Object)
    if (($requiredEvidenceProperties | Sort-Object) -join '|' -cne ($actualEvidenceProperties -join '|')) { throw 'Validation product evidence must contain exactly receipt_id, tier, result, artifacts, criteria, gates, and device_validation.' }
    if (@($Evidence.artifacts).Count -eq 0 -or @($Evidence.criteria).Count -eq 0 -or @($Evidence.gates).Count -eq 0) { throw 'Validation product evidence requires explicit artifacts, criteria, and gates.' }

    $projectPath = Join-Path $workspace 'project.spec.json'
    $unitPath = Join-Path $workspace "iteration-units\$UnitId.json"
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf) -or -not (Test-Path -LiteralPath $unitPath -PathType Leaf)) { throw 'Validation receipt generation requires the project and exact unit documents.' }
    $project = Get-Content -LiteralPath $projectPath -Raw | ConvertFrom-Json -Depth 100 -DateKind String
    $unit = Get-Content -LiteralPath $unitPath -Raw | ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$project.project_id -cne [string]$unit.project_id -or [string]$unit.unit_id -cne $UnitId) { throw 'Validation receipt generation project/unit identity does not match.' }

    $mapPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoMapPath).Path)
    $mapJson = Get-Content -LiteralPath $mapPath -Raw
    $mapSha256 = Get-MorphospaceValidationReceiptFileHash $mapPath
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not (Test-Json -Json $mapJson -SchemaFile (Join-Path $repositoryRoot 'schemas\repository-map.schema.json') -ErrorAction Stop)) { throw 'Validation receipt repository map does not satisfy its schema.' }
    $mapDocument = $mapJson | ConvertFrom-Json -Depth 100 -DateKind String
    $map = @{}
    foreach ($entry in @($mapDocument.repositories)) {
        if ($map.ContainsKey([string]$entry.repo_id)) { throw "Validation receipt repository map repeats '$([string]$entry.repo_id)'." }
        $map[[string]$entry.repo_id] = $entry
    }

    $baseByRepo = @{}
    $sourceLockPresent = $false
    if (($unit.PSObject.Properties.Name -contains 'source_composition') -and $null -ne $unit.source_composition.lock_path) {
        $sourceLockPresent = $true
        if (-not ($unit.PSObject.Properties.Name -contains 'candidate_freeze')) { throw 'Validation receipt generation requires the candidate-freeze binding for a source-composition lock.' }
        $lockRelative = ([string]$unit.source_composition.lock_path).Replace('\','/')
        $lockPath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace $lockRelative -RequireLeaf
        $freezeRelative = ([string]$unit.candidate_freeze.receipt_path).Replace('\','/')
        $freezePath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace $freezeRelative -RequireLeaf
        $freezeSha256 = Get-MorphospaceValidationReceiptFileHash $freezePath
        if ($freezeSha256 -cne [string]$unit.candidate_freeze.receipt_sha256) { throw 'Validation receipt candidate-freeze bytes do not match the unit binding.' }
        $freezeJson = Get-Content -LiteralPath $freezePath -Raw
        try { $freeze = $freezeJson | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop } catch { throw "Validation receipt candidate-freeze receipt is not valid JSON: $($_.Exception.Message)" }
        $freezeSchemas = @{
            'rusty.morphospace.workflow.candidate_freeze.v1'='candidate-freeze-v1.schema.json'
            'rusty.morphospace.workflow.candidate_freeze.v2'='candidate-freeze-v2.schema.json'
        }
        $freezeSchema = [string]$freeze.schema
        if (-not $freezeSchemas.ContainsKey($freezeSchema) -or -not (Test-Json -Json $freezeJson -SchemaFile (Join-Path $repositoryRoot "schemas\$($freezeSchemas[$freezeSchema])") -ErrorAction Stop)) { throw 'Validation receipt candidate-freeze receipt does not satisfy a supported schema.' }
        if ([string]$freeze.freeze_id -cne [string]$unit.candidate_freeze.freeze_id -or [string]$freeze.project_id -cne [string]$project.project_id -or [string]$freeze.unit_id -cne $UnitId) { throw 'Validation receipt candidate-freeze identity does not match the project and unit.' }
        $lockSha256 = Get-MorphospaceValidationReceiptFileHash $lockPath
        if ([string]$freeze.expected.source_composition_path -cne $lockRelative -or [string]$freeze.source_composition.path -cne $lockRelative -or [string]$freeze.expected.source_composition_sha256 -cne $lockSha256 -or [string]$freeze.source_composition.sha256 -cne $lockSha256) { throw 'Validation receipt source-composition lock does not match the candidate-freeze binding.' }
        $expectedMapPath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace ([string]$freeze.expected.repository_map_path) -RequireLeaf
        if (-not $expectedMapPath.Equals($mapPath,$script:MorphospaceValidationReceiptPathComparison) -or [string]$freeze.expected.repository_map_sha256 -cne $mapSha256) { throw 'Validation receipt repository map does not match the candidate-freeze binding.' }

        $lockJson = Get-Content -LiteralPath $lockPath -Raw
        try { $lock = $lockJson | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop } catch { throw "Validation receipt source-composition lock is not valid JSON: $($_.Exception.Message)" }
        $lockSchemas = @{
            'rusty.morphospace.workflow.source_composition_lock.v1'='source-composition-lock.schema.json'
            'rusty.morphospace.workflow.development_envelope_source_composition.v1'='development-envelope-source-composition-v1.schema.json'
            'rusty.morphospace.workflow.development_envelope_source_composition.v2'='development-envelope-source-composition-v2.schema.json'
        }
        $lockSchema = [string]$lock.schema
        if (-not $lockSchemas.ContainsKey($lockSchema) -or -not (Test-Json -Json $lockJson -SchemaFile (Join-Path $repositoryRoot "schemas\$($lockSchemas[$lockSchema])") -ErrorAction Stop)) { throw 'Validation receipt source-composition lock does not satisfy a supported schema.' }
        if ([string]$lock.project_id -cne [string]$project.project_id -or (($lock.PSObject.Properties.Name -contains 'unit_id') -and [string]$lock.unit_id -cne $UnitId)) { throw 'Validation receipt source-composition identity does not match the project and unit.' }
        foreach ($row in @($lock.repositories)) {
            $repoId = [string]$row.repo_id
            if ($baseByRepo.ContainsKey($repoId)) { throw "Validation receipt source-composition lock repeats '$repoId'." }
            $baseByRepo[$repoId] = [string]$row.commit
        }
    }

    $repositoryRevisions = [Collections.Generic.List[object]]::new()
    $changedPaths = [Collections.Generic.List[object]]::new()
    foreach ($allowedRepository in @($unit.allowed_repositories)) {
        $repoId = [string]$allowedRepository.repo_id
        if (-not $map.ContainsKey($repoId)) { throw "Validation receipt generation lacks repository mapping '$repoId'." }
        $repositoryPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath ([string]$map[$repoId].path)).Path)
        $inside = Invoke-MorphospaceValidationReceiptGit $repositoryPath @('rev-parse','--is-inside-work-tree') -AllowFailure
        if ($inside.exit_code -ne 0 -or $inside.text -cne 'true') { throw "Generic v1 validation receipt generation requires mapped unit repositories to be Git worktrees; non-Git surfaces require a specialized receipt that binds their artifact coverage: '$repoId'." }
        $head = (Invoke-MorphospaceValidationReceiptGit $repositoryPath @('rev-parse','HEAD')).text
        $branchResult = Invoke-MorphospaceValidationReceiptGit $repositoryPath @('symbolic-ref','--quiet','--short','HEAD') -AllowFailure
        $branch = if ($branchResult.exit_code -eq 0) { $branchResult.text } else { $null }
        if ($sourceLockPresent -and -not $baseByRepo.ContainsKey($repoId)) { throw "Validation receipt source-composition lock lacks allowed repository '$repoId'." }
        $base = if ($baseByRepo.ContainsKey($repoId)) { [string]$baseByRepo[$repoId] } else {
            $upstream = Invoke-MorphospaceValidationReceiptGit $repositoryPath @('rev-parse','--verify','@{upstream}') -AllowFailure
            if ($upstream.exit_code -ne 0) { throw "Validation receipt generation requires an authenticated source-composition baseline or configured Git upstream for '$repoId'." }
            (Invoke-MorphospaceValidationReceiptGit $repositoryPath @('merge-base','HEAD','@{upstream}')).text
        }
        if ($base -cnotmatch '^[0-9a-f]{40}$' -or $head -cnotmatch '^[0-9a-f]{40}$') { throw "Validation receipt generation observed invalid Git identity for '$repoId'." }
        if ((Invoke-MorphospaceValidationReceiptGit $repositoryPath @('merge-base','--is-ancestor',$base,$head) -AllowFailure).exit_code -ne 0) { throw "Validation receipt baseline is not an ancestor of current HEAD for '$repoId'." }
        $repositoryRevisions.Add([pscustomobject][ordered]@{ repo_id=$repoId; base_revision=$base; head_revision=$head; branch=$branch }) | Out-Null

        $observedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($line in @((Invoke-MorphospaceValidationReceiptGit $repositoryPath @('-c','core.safecrlf=false','-c','core.autocrlf=false','diff','--name-only',$base,'--')).lines) + @((Invoke-MorphospaceValidationReceiptGit $repositoryPath @('ls-files','--others','--exclude-standard')).lines)) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            $relative = ([string]$line).Replace('\','/')
            if (-not (Test-MorphospaceValidationReceiptPathAllowed $relative @($allowedRepository.allowed_paths))) { continue }
            $repositoryPrefix = $repositoryPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
            if ($workspace.StartsWith($repositoryPrefix,$script:MorphospaceValidationReceiptPathComparison)) {
                $transactionPrefix = $workspace.Substring($repositoryPrefix.Length).Replace('\','/').TrimEnd('/') + '/receipts/transactions/'
                if ($relative.StartsWith($transactionPrefix,[StringComparison]::Ordinal)) { continue }
            }
            [void]$observedPaths.Add($relative)
        }
        $repositoryPrefix = $repositoryPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if ($output.StartsWith($repositoryPrefix,$script:MorphospaceValidationReceiptPathComparison)) {
            $outputRelative = $output.Substring($repositoryPrefix.Length).Replace('\','/')
            if (Test-MorphospaceValidationReceiptPathAllowed $outputRelative @($allowedRepository.allowed_paths)) { [void]$observedPaths.Add($outputRelative) }
        }
        foreach ($relative in @($observedPaths | Sort-Object)) { $changedPaths.Add([pscustomobject][ordered]@{ repo_id=$repoId; path=$relative }) | Out-Null }
    }

    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @($Evidence.artifacts)) {
        $properties = @($artifact.PSObject.Properties.Name | Sort-Object)
        if (('artifact_id|kind|path') -cne ($properties -join '|')) { throw 'Each validation artifact input must contain exactly artifact_id, kind, and path; SHA-256 is observed by the builder.' }
        $artifactPath = if ([IO.Path]::IsPathRooted([string]$artifact.path)) { [IO.Path]::GetFullPath([string]$artifact.path) } else { [IO.Path]::GetFullPath((Join-Path $outputDirectory ([string]$artifact.path))) }
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "Validation artifact does not exist: $([string]$artifact.path)" }
        $artifacts.Add([pscustomobject][ordered]@{ artifact_id=[string]$artifact.artifact_id; kind=[string]$artifact.kind; path=[string]$artifact.path; sha256=(Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() }) | Out-Null
    }

    if (-not $CreatedAt) { $CreatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $receipt = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.validation_receipt.v1'; receipt_id=[string]$Evidence.receipt_id; project_id=[string]$project.project_id; unit_id=$UnitId; created_at=$CreatedAt; tier=[string]$Evidence.tier; result=[string]$Evidence.result
        repository_revisions=@($repositoryRevisions.ToArray()); changed_paths=@($changedPaths.ToArray()); artifacts=@($artifacts.ToArray())
        criteria=@($Evidence.criteria | ForEach-Object { Copy-MorphospaceValidationReceiptValue $_ }); gates=@($Evidence.gates | ForEach-Object { Copy-MorphospaceValidationReceiptValue $_ })
        device_validation=Copy-MorphospaceValidationReceiptValue $Evidence.device_validation
    }
    [void](Assert-MorphospaceValidationReceiptStructure -Document $receipt -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1')
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    Assert-MorphospaceValidationReceiptNoReparseAncestry $workspace $output
    $temporary = "$output.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary,(($receipt | ConvertTo-Json -Depth 100) + "`n"),[Text.UTF8Encoding]::new($false))
    Assert-MorphospaceValidationReceiptNoReparseAncestry $workspace $output
    Move-Item -LiteralPath $temporary -Destination $output
    return $receipt
}

Export-ModuleMember -Function Assert-MorphospaceValidationReceiptStructure, New-MorphospaceValidationReceiptV1
