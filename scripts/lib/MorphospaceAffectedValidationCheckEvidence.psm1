Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-MorphospaceAffectedCheckBytesSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function Get-MorphospaceAffectedCheckRunnerBinding {
    $powerShellPath = [IO.Path]::GetFullPath((Get-Process -Id $PID).Path)
    $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace([string]$gitCommand.Source)) { throw 'Affected check evidence could not resolve the Git executable.' }
    $gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Source)
    $gitVersion = (& $gitPath --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $gitVersion -cnotmatch '^git version [0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[A-Za-z0-9.-]+)?$') { throw 'Affected check evidence could not resolve a canonical Git version.' }
    return [pscustomobject][ordered]@{
        os_description=[Runtime.InteropServices.RuntimeInformation]::OSDescription
        process_architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
        powershell_version=$PSVersionTable.PSVersion.ToString()
        powershell_executable_sha256=Get-MorphospaceAffectedCheckBytesSha256 ([IO.File]::ReadAllBytes($powerShellPath))
        git_version=$gitVersion
        git_executable_sha256=Get-MorphospaceAffectedCheckBytesSha256 ([IO.File]::ReadAllBytes($gitPath))
    }
}

function ConvertTo-MorphospaceAffectedCheckPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $normalized = $Path.Replace('\','/')
    if ($normalized -notmatch '^[^/:][^:]*$' -or $normalized -match '(?:^|/)\.\.?/') { throw "Affected check path is not canonical: $Path" }
    return $normalized
}

function Get-MorphospaceAffectedCheckManifestRecords {
    param(
        [Parameter(Mandatory = $true)][object]$Inventory,
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $exact = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in @($Paths)) { [void]$exact.Add((ConvertTo-MorphospaceAffectedCheckPath -Path ([string]$candidate))) }
    [string[]]$ordered = @($exact)
    [Array]::Sort($ordered,[StringComparer]::Ordinal)
    $records = [Collections.Generic.List[object]]::new()
    foreach ($path in $ordered) {
        $entry = $Inventory.by_path[$path]
        if ($null -eq $entry -or [string]$entry.type -cne 'blob' -or @('100644','100755') -cnotcontains [string]$entry.mode) { throw "$Context is not a tracked regular exact-head file: $path" }
        $records.Add([pscustomobject][ordered]@{path=$path;mode=[string]$entry.mode;blob=[string]$entry.blob})
    }
    return @($records.ToArray())
}

function Get-MorphospaceAffectedCheckStaticClosurePaths {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Entrypoint,
        [Parameter(Mandatory = $true)][object]$Inventory
    )
    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    $trackedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $trackedScripts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Inventory.records)) {
        if ([string]$entry.type -cne 'blob' -or @('100644','100755') -cnotcontains [string]$entry.mode) { continue }
        [void]$trackedFiles.Add([string]$entry.path)
        if ([string]$entry.path -match '^scripts/.+\.ps(?:m)?1$') { [void]$trackedScripts.Add([string]$entry.path) }
    }
    $nodes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Queue[string]]::new()
    function Add-TrackedClosurePath([string]$Importer,[string]$Value) {
        $normalized = $Value.Replace('\','/')
        $importerDirectory = [IO.Path]::GetDirectoryName((Join-Path $root $Importer))
        $candidates = [Collections.Generic.List[string]]::new()
        if ($normalized -match '^(?:scripts|schemas|manifests|docs|templates|config)/') { $candidates.Add([IO.Path]::GetFullPath((Join-Path $root $normalized))) }
        $candidates.Add([IO.Path]::GetFullPath((Join-Path $importerDirectory $normalized)))
        $candidates.Add([IO.Path]::GetFullPath((Join-Path $root $normalized)))
        if ($normalized -notmatch '/') {
            foreach ($directory in @('schemas','manifests','config','templates')) { $candidates.Add([IO.Path]::GetFullPath((Join-Path $root (Join-Path $directory $normalized)))) }
        }
        foreach ($absolute in @($candidates)) {
            if (-not $absolute.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = [IO.Path]::GetRelativePath($root,$absolute).Replace('\','/')
            if (-not $trackedFiles.Contains($relative)) { continue }
            if ($nodes.Add($relative) -and $trackedScripts.Contains($relative)) { $pending.Enqueue($relative) }
            return $true
        }
        return $false
    }
    if (-not (Add-TrackedClosurePath -Importer $Entrypoint -Value $Entrypoint)) { throw "Affected check entrypoint is not a tracked PowerShell file: $Entrypoint" }
    $fallbackToAllTrackedScripts = $false
    $fallbackExpanded = $false
    while ($true) {
        while ($pending.Count -gt 0) {
            $importer = $pending.Dequeue()
            $absolute = Join-Path $root $importer
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($absolute,[ref]$tokens,[ref]$errors)
            if (@($errors).Count -ne 0) { throw "Affected check dependency closure could not parse tracked source: $importer" }
            $literalOffsets = [Collections.Generic.HashSet[int]]::new()
            foreach ($literal in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Value -match '(?i)\.(?:ps1|psm1|json|jsonl|ya?ml|toml|md)$' },$true))) {
                if (Add-TrackedClosurePath -Importer $importer -Value ([string]$literal.Value)) {
                    if ([string]$literal.Value -match '(?i)\.ps(?:m)?1$') { [void]$literalOffsets.Add([int]$literal.Extent.StartOffset) }
                }
            }
            foreach ($command in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] },$true))) {
                $isImport = [string]$command.GetCommandName() -match '(?i)(?:^|\\)Import-Module$'
                $isInvocation = $command.InvocationOperator -in @([Management.Automation.Language.TokenKind]::Ampersand,[Management.Automation.Language.TokenKind]::Dot)
                if (-not $isImport -and -not $isInvocation) { continue }
                $trackedLiteral = @($command.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $literalOffsets.Contains([int]$node.Extent.StartOffset) },$true)).Count -ne 0
                if ($trackedLiteral) { continue }
                $elements = @($command.CommandElements)
                $first = $elements[0]
                if ($isImport) {
                    $importArguments = @($elements | Select-Object -Skip 1)
                    if ($importArguments.Count -eq 1 -and $importArguments[0] -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$importArguments[0].Value -notmatch '[\\/]|(?i)\.psm1$') { continue }
                    $fallbackToAllTrackedScripts = $true
                    continue
                }
                if ($isInvocation -and ($first -is [Management.Automation.Language.StringConstantExpressionAst] -or $first -is [Management.Automation.Language.ScriptBlockExpressionAst])) { continue }
                if ($isInvocation -and $first -is [Management.Automation.Language.VariableExpressionAst]) {
                    $name = [string]$first.VariablePath.UserPath
                    $typedScriptBlock = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.ParameterAst] -and [string]$node.Name.VariablePath.UserPath -ceq $name -and $node.StaticType -eq [scriptblock] },$true)).Count -ne 0
                    $externalBinding = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and [string]$node.Left.VariablePath.UserPath -ceq $name -and [string]$node.Right.Extent.Text -match '(?i)\b(?:Get-Command|Get-Process)\b' },$true)).Count -ne 0
                    if ($typedScriptBlock -or $externalBinding -or $name -match '(?i)(?:git|pwsh|powershell|python|executable)$') { continue }
                }
                # An unresolved tracked-script dispatch is safe only when the
                # manifest conservatively binds and traverses every tracked
                # PowerShell source.
                $fallbackToAllTrackedScripts = $true
            }
        }
        if (-not $fallbackToAllTrackedScripts -or $fallbackExpanded) { break }
        $fallbackExpanded = $true
        foreach ($path in @($trackedScripts)) { if ($nodes.Add([string]$path)) { $pending.Enqueue([string]$path) } }
    }
    [string[]]$result = @($nodes)
    [Array]::Sort($result,[StringComparer]::Ordinal)
    return $result
}

function Get-MorphospaceAffectedCheckRunnerSourceManifest {
    param([Parameter(Mandatory = $true)][object]$Inventory)
    return @(Get-MorphospaceAffectedCheckManifestRecords -Inventory $Inventory -Context 'Affected check runner source' -Paths @(
        'schemas/affected-validation-check-evidence-v1.schema.json',
        'schemas/affected-validation-check-inventory-v1.schema.json',
        'schemas/affected-validation-plan-v1.schema.json',
        'schemas/affected-validation-registry-v1.schema.json',
        'scripts/Invoke-AffectedValidation.ps1',
        'scripts/lib/MorphospaceAffectedValidation.psm1',
        'scripts/lib/MorphospaceAffectedValidationCheckEvidence.psm1',
        'scripts/lib/MorphospaceProtocolCommon.psm1'
    ))
}

function Get-MorphospaceAffectedCheckDependencyManifest {
    param(
        [Parameter(Mandatory = $true)][object]$Check,
        [Parameter(Mandatory = $true)][object]$CompiledRegistry,
        [Parameter(Mandatory = $true)][object]$Inventory,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @(Get-MorphospaceAffectedCheckStaticClosurePaths -RepositoryRoot $RepositoryRoot -Entrypoint ([string]$Check.command_path) -Inventory $Inventory)) { [void]$paths.Add([string]$path) }
    foreach ($entry in @($Inventory.records)) {
        if ([string]$entry.type -cne 'blob' -or @('100644','100755') -cnotcontains [string]$entry.mode) { continue }
        foreach ($pathSetId in @($Check.consume_path_sets)) {
            foreach ($pattern in @($CompiledRegistry.path_sets[[string]$pathSetId])) {
                if ($pattern.IsMatch([string]$entry.path)) { [void]$paths.Add([string]$entry.path); break }
            }
            if ($paths.Contains([string]$entry.path)) { break }
        }
    }
    return @(Get-MorphospaceAffectedCheckManifestRecords -Inventory $Inventory -Paths @($paths) -Context 'Affected check dependency')
}

function Get-MorphospaceAffectedCheckEvidenceDefinition {
    param([Parameter(Mandatory = $true)][object]$Check)
    $definition = [ordered]@{}
    foreach ($property in @($Check.PSObject.Properties)) {
        if ([string]$property.Name -ceq 'execution_after_checks') { continue }
        $definition[[string]$property.Name] = $property.Value
    }
    return [pscustomobject]$definition
}

function New-MorphospaceAffectedCheckBinding {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][ValidateSet('windows','linux')][string]$Platform,
        [Parameter(Mandatory = $true)][object]$Check,
        [Parameter(Mandatory = $true)][object]$Runner,
        [Parameter(Mandatory = $true)][object[]]$RunnerSourceManifest,
        [Parameter(Mandatory = $true)][object[]]$DependencyManifest,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$PrerequisiteBindings
    )
    $prerequisites = @($PrerequisiteBindings)
    if ($prerequisites.Count -gt 1) { [Array]::Sort($prerequisites,[Collections.Generic.Comparer[object]]::Create({ param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.check_id,[string]$right.check_id) })) }
    $commandIndex = [array]::IndexOf(@($DependencyManifest.path),[string]$Check.command_path)
    if ($commandIndex -lt 0) { throw 'Affected check dependency manifest omits its command path.' }
    return [pscustomobject][ordered]@{
        repository=$Repository
        platform=$Platform
        check_id=[string]$Check.check_id
        command_path=[string]$Check.command_path
        command_blob_sha1=[string]$DependencyManifest[$commandIndex].blob
        arguments=@($Check.arguments | ForEach-Object { [string]$_ })
        check_definition_sha256=Get-MorphospaceCanonicalJsonSha256 -Value (Get-MorphospaceAffectedCheckEvidenceDefinition -Check $Check)
        cache_policy=[string]$Check.cache_policy
        external_state=[string]$Check.external_state
        runner=$Runner
        runner_source_manifest=@($RunnerSourceManifest)
        dependency_manifest=@($DependencyManifest)
        prerequisite_bindings=@($prerequisites)
    }
}

function Assert-MorphospaceAffectedCheckManifestAtSource {
    param(
        [Parameter(Mandatory = $true)][object]$SourceInventory,
        [Parameter(Mandatory = $true)][object[]]$Manifest,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $previous = $null
    foreach ($record in @($Manifest)) {
        $path = ConvertTo-MorphospaceAffectedCheckPath -Path ([string]$record.path)
        if ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$path) -ge 0) { throw "$Context is not unique and ordinal sorted." }
        $entry = $SourceInventory.by_path[$path]
        if ($null -eq $entry -or [string]$entry.type -cne 'blob' -or [string]$entry.mode -cne [string]$record.mode -or [string]$entry.blob -cne [string]$record.blob) { throw "$Context does not exist at the receipt source commit: $path" }
        $previous = $path
    }
}

function Assert-MorphospaceAffectedCheckNoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Root,[Parameter(Mandatory = $true)][string]$Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Affected check evidence path escapes its prior-evidence root.' }
    $cursor = $pathFull
    while ($cursor.Length -ge $rootFull.Length) {
        if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Affected check evidence path contains a reparse point.' }
        if ($cursor.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { throw 'Affected check evidence path ancestry is invalid.' }
        $cursor = $parent
    }
}

function Read-MorphospaceAffectedCheckStableBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 10485760) { throw 'Affected check evidence file exceeds the bounded size.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($read -le 0) { throw 'Affected check evidence file ended before its observed length.' }
            $offset += $read
        }
        if ($stream.Position -ne $stream.Length) { throw 'Affected check evidence file length drifted during read.' }
        return ,$bytes
    } finally { $stream.Dispose() }
}

function ConvertTo-MorphospaceAffectedCheckArtifactPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $normalized = ConvertTo-MorphospaceAffectedCheckPath -Path $Path
    if ($normalized -match '(?:^|/)\.\.?$' -or $normalized.StartsWith('artifacts/',[StringComparison]::Ordinal)) { throw 'Affected check artifact path is not a canonical phase-relative path.' }
    return $normalized
}

function Get-MorphospaceAffectedCheckArtifactReferences {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Artifacts)
    $records = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($artifact in @($Artifacts)) {
        if ($null -eq $artifact) { continue }
        $path = ConvertTo-MorphospaceAffectedCheckArtifactPath -Path ([string]$artifact.path)
        if (-not $seen.Add($path)) { throw 'Affected check artifact paths are not unique.' }
        [byte[]]$bytes = [byte[]]$artifact.bytes
        if ($bytes.Length -gt 10485760) { throw 'Affected check artifact exceeds the bounded size.' }
        $records.Add([pscustomobject][ordered]@{path=$path;bytes=[long]$bytes.Length;sha256=Get-MorphospaceAffectedCheckBytesSha256 $bytes})
    }
    $ordered = @($records.ToArray())
    if ($ordered.Count -gt 1) { [Array]::Sort($ordered,[Collections.Generic.Comparer[object]]::Create({ param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path) })) }
    return @($ordered)
}

function New-MorphospaceAffectedCheckSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Stdout,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Stderr,
        [AllowNull()][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory = $true)][string]$SchemaPath
    )
    $artifactBytes = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @($Artifacts)) { if ($null -ne $artifact) { $artifactBytes.Add([pscustomobject][ordered]@{path=ConvertTo-MorphospaceAffectedCheckArtifactPath -Path ([string]$artifact.path);bytes=[byte[]]$artifact.bytes}) } }
    $orderedArtifacts = @($artifactBytes.ToArray())
    if ($orderedArtifacts.Count -gt 1) { [Array]::Sort($orderedArtifacts,[Collections.Generic.Comparer[object]]::Create({ param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path) })) }
    $artifactReferences = @(Get-MorphospaceAffectedCheckArtifactReferences -Artifacts $orderedArtifacts)
    if ((Get-MorphospaceCanonicalJsonSha256 -Value @($Receipt.artifacts)) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $artifactReferences)) { throw 'Affected check receipt artifact references differ from the parent-owned artifact snapshot.' }
    foreach ($streamRecord in @([pscustomobject]@{name='stdout';bytes=[byte[]]$Stdout},[pscustomobject]@{name='stderr';bytes=[byte[]]$Stderr})) {
        $reference = $Receipt.child.([string]$streamRecord.name)
        if ([long]$reference.bytes -ne [long]([byte[]]$streamRecord.bytes).Length -or [string]$reference.sha256 -cne (Get-MorphospaceAffectedCheckBytesSha256 ([byte[]]$streamRecord.bytes))) { throw "Affected check receipt $([string]$streamRecord.name) reference differs from the parent-owned stream snapshot." }
    }
    $json = ConvertTo-MorphospaceCanonicalJson -Value $Receipt
    if (-not (Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop)) { throw 'Affected check receipt fails its closed schema before parent snapshot retention.' }
    [byte[]]$receiptBytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    $retainedReceipt = $json | ConvertFrom-Json -Depth 64 -DateKind String
    return [pscustomobject][ordered]@{
        check_id=[string]$retainedReceipt.binding.check_id;receipt=$retainedReceipt;receipt_bytes=$receiptBytes;receipt_sha256=Get-MorphospaceAffectedCheckBytesSha256 $receiptBytes
        stdout=[byte[]]$Stdout.Clone();stderr=[byte[]]$Stderr.Clone();artifacts=@($orderedArtifacts)
    }
}

function Get-MorphospaceAffectedCheckPhaseArtifacts {
    param(
        [Parameter(Mandatory = $true)][object]$Check,
        [Parameter(Mandatory = $true)][string]$PhaseEvidenceRoot
    )
    if ([string]$Check.command_path -cne 'scripts/Invoke-AffectedValidationSelfTestPhase.ps1') { return @() }
    [string[]]$arguments = @($Check.arguments | ForEach-Object { [string]$_ })
    $phaseIndex = [Array]::IndexOf($arguments,'-Phase')
    if ($phaseIndex -lt 0) { return @() }
    if ($phaseIndex + 1 -ge $arguments.Count) { throw 'Affected check phase arguments omit the phase identity.' }
    $phase = [string]$arguments[$phaseIndex + 1]
    if ($phase -notmatch '^[a-z0-9][a-z0-9-]{1,95}$') { throw 'Affected check phase identity is invalid.' }
    $root = [IO.Path]::GetFullPath($PhaseEvidenceRoot)
    if (-not [IO.Directory]::Exists($root)) { throw 'Affected check passing phase did not create its evidence root.' }
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($suffix in @('start.json','stdout.bin','stderr.bin','terminal.json')) { $paths.Add("$phase.$suffix") }
    $terminalPath = Join-Path $root "$phase.terminal.json"
    Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $terminalPath
    [byte[]]$terminalBytes = Read-MorphospaceAffectedCheckStableBytes -Path $terminalPath
    $terminalRaw = [Text.UTF8Encoding]::new($false,$true).GetString($terminalBytes)
    $terminal = $terminalRaw | ConvertFrom-Json -Depth 64 -DateKind String
    if ([string]$terminal.phase_id -cne $phase -or [string]$terminal.result -cne 'pass') { throw 'Affected check passing phase terminal identity or result is invalid.' }
    foreach ($output in @($terminal.outputs)) { $paths.Add((ConvertTo-MorphospaceAffectedCheckArtifactPath -Path ([string]$output.path))) }
    $pathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidatePath in @($paths)) { if (-not $pathSet.Add((ConvertTo-MorphospaceAffectedCheckArtifactPath -Path ([string]$candidatePath)))) { throw 'Affected check phase terminal repeats an artifact path.' } }
    [string[]]$orderedPaths = @($pathSet)
    [Array]::Sort($orderedPaths,[StringComparer]::Ordinal)
    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($relative in $orderedPaths) {
        $relative = ConvertTo-MorphospaceAffectedCheckArtifactPath -Path $relative
        $path = Join-Path $root $relative
        Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $path
        [byte[]]$bytes = Read-MorphospaceAffectedCheckStableBytes -Path $path
        $artifacts.Add([pscustomobject][ordered]@{path=$relative;bytes=$bytes})
    }
    foreach ($output in @($terminal.outputs)) {
        $match = @($artifacts | Where-Object path -CEQ ([string]$output.path))
        if ($match.Count -ne 1 -or [long]$match[0].bytes.Length -ne [long]$output.bytes -or (Get-MorphospaceAffectedCheckBytesSha256 ([byte[]]$match[0].bytes)) -cne [string]$output.sha256) { throw 'Affected check phase output differs from its terminal reference.' }
    }
    return @($artifacts.ToArray())
}

function Restore-MorphospaceAffectedCheckArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$PhaseEvidenceRoot,
        [AllowNull()][AllowEmptyCollection()][object[]]$Artifacts
    )
    $root = [IO.Path]::GetFullPath($PhaseEvidenceRoot)
    if (-not [IO.Directory]::Exists($root)) { [void][IO.Directory]::CreateDirectory($root) }
    $writes = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @($Artifacts)) {
        if ($null -eq $artifact) { continue }
        $relative = ConvertTo-MorphospaceAffectedCheckArtifactPath -Path ([string]$artifact.path)
        [byte[]]$bytes = [byte[]]$artifact.bytes
        $path = Join-Path $root $relative
        $parent = [IO.Path]::GetDirectoryName($path)
        if (-not $parent.StartsWith(($root + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase) -and $parent -cne $root) { throw 'Affected check artifact restoration escaped its phase root.' }
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        if ([IO.File]::Exists($path)) {
            Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $path
            [byte[]]$existing = Read-MorphospaceAffectedCheckStableBytes -Path $path
            if ($existing.Length -ne $bytes.Length -or (Get-MorphospaceAffectedCheckBytesSha256 $existing) -cne (Get-MorphospaceAffectedCheckBytesSha256 $bytes)) { throw 'Affected check phase artifact collision differs from the reusable snapshot.' }
            continue
        }
        $writes.Add([pscustomobject][ordered]@{path=$path;bytes=$bytes})
    }
    foreach ($write in @($writes.ToArray())) {
        [byte[]]$bytes = [byte[]]$write.bytes
        $path = [string]$write.path
        $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
    }
}

function Test-MorphospaceAffectedCheckReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [Parameter(Mandatory = $true)][string]$SchemaPath,
        [Parameter(Mandatory = $true)][object]$ExpectedBinding,
        [Parameter(Mandatory = $true)][string]$ExpectedBindingSha256,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CurrentHeadCommit,
        [AllowNull()][string]$PriorEvidenceRoot,
        [AllowNull()][object]$CandidateSnapshot
    )
    $receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
    if (-not [string]::IsNullOrWhiteSpace($PriorEvidenceRoot)) { Assert-MorphospaceAffectedCheckNoReparsePath -Root $PriorEvidenceRoot -Path $receiptFull }
    [byte[]]$receiptBytes = if ($null -eq $CandidateSnapshot) { Read-MorphospaceAffectedCheckStableBytes -Path $receiptFull } else {
        if ([IO.Path]::GetFullPath([string]$CandidateSnapshot.receipt_path) -cne $receiptFull) { throw 'Affected check inventory snapshot receipt path is inconsistent.' }
        [Convert]::FromBase64String([string]$CandidateSnapshot.receipt_base64)
    }
    $raw = [Text.UTF8Encoding]::new($false,$true).GetString($receiptBytes)
    if (-not (Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction Stop)) { throw 'Affected check receipt fails its closed schema.' }
    $receipt = $raw | ConvertFrom-Json -Depth 64 -DateKind String
    if ([string]$receipt.binding_sha256 -cne $ExpectedBindingSha256 -or (Get-MorphospaceCanonicalJsonSha256 -Value $receipt.binding) -cne $ExpectedBindingSha256) { throw 'Affected check receipt binding differs from the exact current check binding.' }
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $receipt.binding) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $ExpectedBinding)) { throw 'Affected check receipt contains a noncanonical binding collision.' }
    if ([string]$receipt.result -cne 'pass' -or @('executed','reused') -cnotcontains [string]$receipt.mode) { throw 'Affected check receipt is not reusable passing evidence.' }
    if ([string]$receipt.binding.cache_policy -ceq 'disabled' -or [string]$receipt.binding.external_state -cne 'none') { throw 'Affected check receipt policy forbids reuse.' }
    $ancestor = & git -C $RepositoryRoot merge-base --is-ancestor ([string]$receipt.source.head.commit) $CurrentHeadCommit 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Affected check receipt source head is not an ancestor of the current head.' }
    $sourceTree = (& git -C $RepositoryRoot rev-parse "$([string]$receipt.source.head.commit)^{tree}").Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceTree -cne [string]$receipt.source.head.tree) { throw 'Affected check receipt source tree identity is invalid.' }
    $sourceInventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $RepositoryRoot -Commit ([string]$receipt.source.head.commit)
    Assert-MorphospaceAffectedCheckManifestAtSource -SourceInventory $sourceInventory -Manifest @($receipt.binding.runner_source_manifest) -Context 'Affected check runner-source manifest'
    Assert-MorphospaceAffectedCheckManifestAtSource -SourceInventory $sourceInventory -Manifest @($receipt.binding.dependency_manifest) -Context 'Affected check dependency manifest'
    $directory = [IO.Path]::GetDirectoryName($receiptFull)
    $streamBytes = @{}
    foreach ($streamName in @('stdout','stderr')) {
        $stream = $receipt.child.$streamName
        $expectedLeaf = "$streamName.bin"
        if ([string]$stream.path -cne $expectedLeaf) { throw "Affected check $streamName stream leaf is invalid." }
        $path = Join-Path $directory $expectedLeaf
        if (-not [string]::IsNullOrWhiteSpace($PriorEvidenceRoot)) { Assert-MorphospaceAffectedCheckNoReparsePath -Root $PriorEvidenceRoot -Path $path }
        [byte[]]$bytes = [byte[]]::new(0)
        if ($null -eq $CandidateSnapshot) {
            if (-not [IO.File]::Exists($path)) { throw "Affected check $streamName stream is absent." }
            $bytes = Read-MorphospaceAffectedCheckStableBytes -Path $path
        } else {
            if ([IO.Path]::GetFullPath([string]$CandidateSnapshot."${streamName}_path") -cne [IO.Path]::GetFullPath($path)) { throw "Affected check inventory snapshot $streamName path is inconsistent." }
            $bytes = [Convert]::FromBase64String([string]$CandidateSnapshot."${streamName}_base64")
        }
        if ([long]$bytes.Length -ne [long]$stream.bytes -or (Get-MorphospaceAffectedCheckBytesSha256 $bytes) -cne [string]$stream.sha256) { throw "Affected check $streamName stream differs from its receipt." }
        $streamBytes[$streamName] = $bytes
    }
    $artifactBytes = [Collections.Generic.List[object]]::new()
    $snapshotArtifacts = @(if ($null -ne $CandidateSnapshot) { @($CandidateSnapshot.artifacts) })
    $currentHeadTree = $null
    $previousArtifact = $null
    foreach ($artifact in @($receipt.artifacts)) {
        $phasePath = ConvertTo-MorphospaceAffectedCheckArtifactPath -Path ([string]$artifact.path)
        if ($null -ne $previousArtifact -and [StringComparer]::Ordinal.Compare($previousArtifact,$phasePath) -ge 0) { throw 'Affected check receipt artifact references are not unique and ordinal sorted.' }
        [byte[]]$bytes = [byte[]]::new(0)
        if ($null -eq $CandidateSnapshot) {
            $path = Join-Path $directory (Join-Path 'artifacts' $phasePath)
            if (-not [string]::IsNullOrWhiteSpace($PriorEvidenceRoot)) { Assert-MorphospaceAffectedCheckNoReparsePath -Root $PriorEvidenceRoot -Path $path }
            $bytes = Read-MorphospaceAffectedCheckStableBytes -Path $path
        } else {
            $matched = @($snapshotArtifacts | Where-Object phase_path -CEQ $phasePath)
            if ($matched.Count -ne 1) { throw 'Affected check inventory snapshot does not contain exactly one bound phase artifact.' }
            $expectedCachePath = Join-Path $directory (Join-Path 'artifacts' $phasePath)
            if ([IO.Path]::GetFullPath([string]$matched[0].cache_path) -cne [IO.Path]::GetFullPath($expectedCachePath)) { throw 'Affected check inventory snapshot phase-artifact path is inconsistent.' }
            $bytes = [Convert]::FromBase64String([string]$matched[0].bytes_base64)
        }
        if ([long]$bytes.Length -ne [long]$artifact.bytes -or (Get-MorphospaceAffectedCheckBytesSha256 $bytes) -cne [string]$artifact.sha256) { throw 'Affected check phase artifact differs from its receipt.' }
        if ($phasePath -match '\.(?:start|terminal)\.json$') {
            $artifactRaw = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
            $artifactDocument = $artifactRaw | ConvertFrom-Json -Depth 64 -DateKind String
            if ($null -eq $artifactDocument.binding -or [string]$artifactDocument.binding.head_commit -cne $CurrentHeadCommit) { throw 'Affected check phase artifact does not bind the exact current head.' }
            if ($null -eq $currentHeadTree) {
                $currentHeadTree = (& git -C $RepositoryRoot rev-parse "$CurrentHeadCommit^{tree}").Trim()
                if ($LASTEXITCODE -ne 0 -or $currentHeadTree -notmatch '^[0-9a-f]{40}$') { throw 'Affected check phase artifact current tree could not be resolved.' }
            }
            if ([string]$artifactDocument.binding.head_tree -cne $currentHeadTree) { throw 'Affected check phase artifact does not bind the exact current tree.' }
        }
        $artifactBytes.Add([pscustomobject][ordered]@{path=$phasePath;bytes=$bytes})
        $previousArtifact = $phasePath
    }
    if ($snapshotArtifacts.Count -ne @($receipt.artifacts).Count) { throw 'Affected check inventory snapshot contains unbound phase artifacts.' }
    return [pscustomobject][ordered]@{receipt=$receipt;receipt_path=$receiptFull;receipt_sha256=(Get-MorphospaceAffectedCheckBytesSha256 $receiptBytes);stdout=[byte[]]$streamBytes.stdout;stderr=[byte[]]$streamBytes.stderr;artifacts=@($artifactBytes.ToArray())}
}

function Find-MorphospaceAffectedReusableCheckReceipt {
    param(
        [AllowNull()][string]$PriorEvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$SchemaPath,
        [Parameter(Mandatory = $true)][object]$ExpectedBinding,
        [Parameter(Mandatory = $true)][string]$ExpectedBindingSha256,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CurrentHeadCommit,
        [AllowNull()][string[]]$CandidateReceiptPaths,
        [AllowNull()][object[]]$CandidateEvidenceSnapshots
    )
    if ([string]::IsNullOrWhiteSpace($PriorEvidenceDirectory) -or -not [IO.Directory]::Exists([IO.Path]::GetFullPath($PriorEvidenceDirectory))) { return $null }
    $priorRoot = [IO.Path]::GetFullPath($PriorEvidenceDirectory)
    Assert-MorphospaceAffectedCheckNoReparsePath -Root ([IO.Path]::GetDirectoryName($priorRoot)) -Path $priorRoot
    $candidateItems = [Collections.Generic.List[object]]::new()
    if ($null -ne $CandidateEvidenceSnapshots) {
        foreach ($snapshot in @($CandidateEvidenceSnapshots)) { $candidateItems.Add([pscustomobject][ordered]@{path=[IO.Path]::GetFullPath([string]$snapshot.receipt_path);snapshot=$snapshot}) }
    } else {
        [string[]]$candidatePaths = if ($null -ne $CandidateReceiptPaths) { @($CandidateReceiptPaths | ForEach-Object { [IO.Path]::GetFullPath($_) }) } else { @(Get-ChildItem -LiteralPath $priorRoot -Filter receipt.json -File -Recurse | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) }) }
        foreach ($candidatePath in $candidatePaths) { $candidateItems.Add([pscustomobject][ordered]@{path=$candidatePath;snapshot=$null}) }
    }
    $orderedItems = @($candidateItems.ToArray())
    if ($orderedItems.Count -gt 1) { [Array]::Sort($orderedItems,[Collections.Generic.Comparer[object]]::Create({ param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path) })) }
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($candidateItem in $orderedItems) {
        try {
            $validated = Test-MorphospaceAffectedCheckReceipt -ReceiptPath ([string]$candidateItem.path) -SchemaPath $SchemaPath -ExpectedBinding $ExpectedBinding -ExpectedBindingSha256 $ExpectedBindingSha256 -RepositoryRoot $RepositoryRoot -CurrentHeadCommit $CurrentHeadCommit -PriorEvidenceRoot $priorRoot -CandidateSnapshot $candidateItem.snapshot
            $matches.Add($validated)
        } catch {
            continue
        }
    }
    if ($matches.Count -gt 1) { throw 'Affected check prior evidence contains duplicate exact-binding reusable receipts.' }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Write-MorphospaceAffectedCheckReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Stdout,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Stderr,
        [Parameter(Mandatory = $true)][string]$SchemaPath
    )
    $root = [IO.Path]::GetFullPath($EvidenceDirectory)
    if ([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)) { throw 'Affected check evidence directory already exists.' }
    [void][IO.Directory]::CreateDirectory($root)
    $stdoutPath = Join-Path $root 'stdout.bin'
    $stderrPath = Join-Path $root 'stderr.bin'
    $receiptPath = Join-Path $root 'receipt.json'
    $json = ConvertTo-MorphospaceCanonicalJson -Value $Receipt
    if (-not (Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop)) { throw 'Affected check receipt fails its closed schema before publication.' }
    foreach ($record in @(
        [pscustomobject]@{path=$stdoutPath;bytes=$Stdout},
        [pscustomobject]@{path=$stderrPath;bytes=$Stderr},
        [pscustomobject]@{path=$receiptPath;bytes=[Text.UTF8Encoding]::new($false).GetBytes($json + "`n")}
    )) {
        $stream = [IO.File]::Open([string]$record.path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write([byte[]]$record.bytes,0,([byte[]]$record.bytes).Length); $stream.Flush($true) } finally { $stream.Dispose() }
    }
    return [pscustomobject][ordered]@{receipt_path=$receiptPath;receipt_sha256=(Get-MorphospaceAffectedCheckBytesSha256 ([IO.File]::ReadAllBytes($receiptPath)))}
}

function Write-MorphospaceAffectedCheckCache {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][object[]]$Snapshots,
        [Parameter(Mandatory = $true)][object]$Producer,
        [Parameter(Mandatory = $true)][object]$Source,
        [Parameter(Mandatory = $true)][string]$PlanSha256,
        [Parameter(Mandatory = $true)][ValidateSet('windows','linux')][string]$Platform,
        [Parameter(Mandatory = $true)][string]$ReceiptSchemaPath,
        [Parameter(Mandatory = $true)][string]$InventorySchemaPath
    )
    $root = [IO.Path]::GetFullPath($EvidenceDirectory)
    if ([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)) { throw 'Affected check evidence root already exists before parent-owned cache materialization.' }
    $ordered = @($Snapshots)
    if ($ordered.Count -eq 0) { throw 'Affected check parent snapshot set is empty.' }
    if ($ordered.Count -gt 1) { [Array]::Sort($ordered,[Collections.Generic.Comparer[object]]::Create({ param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.check_id,[string]$right.check_id) })) }
    for ($index=1; $index -lt $ordered.Count; $index++) { if ([StringComparer]::Ordinal.Compare([string]$ordered[$index-1].check_id,[string]$ordered[$index].check_id) -ge 0) { throw 'Affected check parent snapshots are not unique and ordinal sorted.' } }
    [void][IO.Directory]::CreateDirectory($root)
    $entries = [Collections.Generic.List[object]]::new()
    $expectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectedFiles = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
    [void]$expectedPaths.Add('inventory.json')
    foreach ($snapshot in $ordered) {
        $checkId = [string]$snapshot.check_id
        if ($checkId -notmatch '^[a-z0-9][a-z0-9-]{1,95}$' -or [string]$snapshot.receipt.binding.check_id -cne $checkId) { throw 'Affected check parent snapshot identity is invalid.' }
        $receiptRaw = [Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$snapshot.receipt_bytes)
        if (-not (Test-Json -Json $receiptRaw -SchemaFile $ReceiptSchemaPath -ErrorAction Stop)) { throw 'Affected check parent snapshot receipt fails its closed schema at materialization.' }
        $directory = Join-Path $root $checkId
        [void][IO.Directory]::CreateDirectory($directory)
        $files = @(
            [pscustomobject][ordered]@{name='stdout';relative="$checkId/stdout.bin";path=Join-Path $directory 'stdout.bin';bytes=[byte[]]$snapshot.stdout},
            [pscustomobject][ordered]@{name='stderr';relative="$checkId/stderr.bin";path=Join-Path $directory 'stderr.bin';bytes=[byte[]]$snapshot.stderr},
            [pscustomobject][ordered]@{name='receipt';relative="$checkId/receipt.json";path=Join-Path $directory 'receipt.json';bytes=[byte[]]$snapshot.receipt_bytes}
        )
        $fileRecords = @{}
        foreach ($file in $files) {
            if (-not $expectedPaths.Add([string]$file.relative)) { throw 'Affected check parent cache repeats a materialized path.' }
            $expectedFiles.Add([string]$file.relative,[byte[]]$file.bytes)
            $stream = [IO.File]::Open([string]$file.path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $stream.Write([byte[]]$file.bytes,0,([byte[]]$file.bytes).Length);$stream.Flush($true) } finally { $stream.Dispose() }
            $fileRecords[[string]$file.name] = [pscustomobject][ordered]@{path=[string]$file.relative;bytes=[long]([byte[]]$file.bytes).Length;sha256=Get-MorphospaceAffectedCheckBytesSha256 ([byte[]]$file.bytes)}
        }
        $artifactRecords = [Collections.Generic.List[object]]::new()
        foreach ($artifact in @($snapshot.artifacts)) {
            $phasePath = ConvertTo-MorphospaceAffectedCheckArtifactPath -Path ([string]$artifact.path)
            [byte[]]$bytes = [byte[]]$artifact.bytes
            $relative = "$checkId/artifacts/$phasePath"
            if (-not $expectedPaths.Add($relative)) { throw 'Affected check parent cache repeats an artifact path.' }
            $expectedFiles.Add($relative,$bytes)
            $path = Join-Path $directory (Join-Path 'artifacts' $phasePath)
            $parent = [IO.Path]::GetDirectoryName($path)
            if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
            $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
            $artifactRecords.Add([pscustomobject][ordered]@{phase_path=$phasePath;path=$relative;bytes=[long]$bytes.Length;sha256=Get-MorphospaceAffectedCheckBytesSha256 $bytes})
        }
        $entries.Add([pscustomobject][ordered]@{
            check_id=$checkId;binding_sha256=[string]$snapshot.receipt.binding_sha256;mode=[string]$snapshot.receipt.mode;result=[string]$snapshot.receipt.result
            receipt=$fileRecords.receipt;stdout=$fileRecords.stdout;stderr=$fileRecords.stderr;artifacts=@($artifactRecords.ToArray())
        })
    }
    $inventory = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.affected_validation_check_inventory.v1';producer=$Producer;source=$Source;plan_sha256=$PlanSha256;platform=$Platform;entries=@($entries.ToArray())
        claims=[pscustomobject][ordered]@{cache_transport_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false}
    }
    $json = ConvertTo-MorphospaceCanonicalJson -Value $inventory
    if (-not (Test-Json -Json $json -SchemaFile $InventorySchemaPath -ErrorAction Stop)) { throw 'Affected check parent-owned inventory fails its closed schema before publication.' }
    [byte[]]$inventoryBytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    $expectedFiles.Add('inventory.json',$inventoryBytes)
    $inventoryPath = Join-Path $root 'inventory.json'
    $stream = [IO.File]::Open($inventoryPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($inventoryBytes,0,$inventoryBytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
    for ($pass=0; $pass -lt 2; $pass++) {
        [string[]]$actualPaths = @(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/') })
        if ($actualPaths.Count -ne $expectedPaths.Count -or @($actualPaths | Where-Object { -not $expectedPaths.Contains($_) }).Count -ne 0) { throw 'Affected check parent-owned cache materialization contains files outside its immutable snapshots.' }
        foreach ($relative in $expectedFiles.Keys) {
            $path = Join-Path $root ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
            Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $path
            [byte[]]$expected = $expectedFiles[$relative]
            [byte[]]$observed = Read-MorphospaceAffectedCheckStableBytes -Path $path
            if ($observed.Length -ne $expected.Length -or
                (Get-MorphospaceAffectedCheckBytesSha256 $observed) -cne (Get-MorphospaceAffectedCheckBytesSha256 $expected) -or
                -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($observed,$expected)) {
                throw "Affected check parent-owned cache materialization differs from the retained snapshot: $relative"
            }
        }
    }
    [byte[]]$publishedInventoryBytes = Read-MorphospaceAffectedCheckStableBytes -Path $inventoryPath
    return [pscustomobject][ordered]@{path=$inventoryPath;sha256=Get-MorphospaceAffectedCheckBytesSha256 $publishedInventoryBytes;entry_count=[int]$ordered.Count}
}

function Write-MorphospaceAffectedCheckInventory {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][object]$Producer,
        [Parameter(Mandatory = $true)][object]$Source,
        [Parameter(Mandatory = $true)][string]$PlanSha256,
        [Parameter(Mandatory = $true)][ValidateSet('windows','linux')][string]$Platform,
        [Parameter(Mandatory = $true)][string]$ReceiptSchemaPath,
        [Parameter(Mandatory = $true)][string]$InventorySchemaPath
    )
    $root = [IO.Path]::GetFullPath($EvidenceDirectory)
    if (-not [IO.Directory]::Exists($root)) { throw 'Affected check evidence root is absent before inventory finalization.' }
    $inventoryPath = Join-Path $root 'inventory.json'
    if ([IO.File]::Exists($inventoryPath)) { throw 'Affected check evidence inventory already exists.' }
    $entries = [Collections.Generic.List[object]]::new()
    [string[]]$receiptPaths = @(Get-ChildItem -LiteralPath $root -Filter receipt.json -File -Recurse | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
    [Array]::Sort($receiptPaths,[StringComparer]::Ordinal)
    foreach ($receiptPath in $receiptPaths) {
        Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $receiptPath
        [byte[]]$receiptBytes = Read-MorphospaceAffectedCheckStableBytes -Path $receiptPath
        $receiptRaw = [Text.UTF8Encoding]::new($false,$true).GetString($receiptBytes)
        if (-not (Test-Json -Json $receiptRaw -SchemaFile $ReceiptSchemaPath -ErrorAction Stop)) { throw 'Affected check evidence inventory found a receipt outside its closed schema.' }
        $receipt = $receiptRaw | ConvertFrom-Json -Depth 64 -DateKind String
        $directory = [IO.Path]::GetDirectoryName($receiptPath)
        $records = @{}
        foreach ($leaf in @('stdout.bin','stderr.bin')) {
            $path = Join-Path $directory $leaf
            Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $path
            [byte[]]$bytes = Read-MorphospaceAffectedCheckStableBytes -Path $path
            $records[$leaf] = [pscustomobject][ordered]@{path=[IO.Path]::GetRelativePath($root,$path).Replace('\','/');bytes=[long]$bytes.Length;sha256=Get-MorphospaceAffectedCheckBytesSha256 $bytes}
        }
        $artifactRecords = [Collections.Generic.List[object]]::new()
        foreach ($artifact in @($receipt.artifacts)) {
            $phasePath = ConvertTo-MorphospaceAffectedCheckArtifactPath -Path ([string]$artifact.path)
            $path = Join-Path $directory (Join-Path 'artifacts' $phasePath)
            Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $path
            [byte[]]$bytes = Read-MorphospaceAffectedCheckStableBytes -Path $path
            if ([long]$bytes.Length -ne [long]$artifact.bytes -or (Get-MorphospaceAffectedCheckBytesSha256 $bytes) -cne [string]$artifact.sha256) { throw 'Affected check evidence inventory found a phase artifact that differs from its receipt.' }
            $artifactRecords.Add([pscustomobject][ordered]@{phase_path=$phasePath;path=[IO.Path]::GetRelativePath($root,$path).Replace('\','/');bytes=[long]$bytes.Length;sha256=Get-MorphospaceAffectedCheckBytesSha256 $bytes})
        }
        $entries.Add([pscustomobject][ordered]@{
            check_id=[string]$receipt.binding.check_id;binding_sha256=[string]$receipt.binding_sha256;mode=[string]$receipt.mode;result=[string]$receipt.result
            receipt=[pscustomobject][ordered]@{path=[IO.Path]::GetRelativePath($root,$receiptPath).Replace('\','/');bytes=[long]$receiptBytes.Length;sha256=Get-MorphospaceAffectedCheckBytesSha256 $receiptBytes}
            stdout=$records['stdout.bin'];stderr=$records['stderr.bin'];artifacts=@($artifactRecords.ToArray())
        })
    }
    $ordered = @($entries.ToArray())
    if ($ordered.Count -gt 1) { [Array]::Sort($ordered,[Collections.Generic.Comparer[object]]::Create({ param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.check_id,[string]$right.check_id) })) }
    for ($index=1; $index -lt $ordered.Count; $index++) { if ([StringComparer]::Ordinal.Compare([string]$ordered[$index-1].check_id,[string]$ordered[$index].check_id) -ge 0) { throw 'Affected check evidence inventory check identities are not unique and ordinal sorted.' } }
    $expectedFiles = 1 + (3 * $ordered.Count) + [int](@($ordered | ForEach-Object { @($_.artifacts).Count }) | Measure-Object -Sum).Sum
    if (@(Get-ChildItem -LiteralPath $root -File -Recurse).Count -ne ($expectedFiles - 1)) { throw 'Affected check evidence root contains files outside the finalized receipt inventory.' }
    $inventory = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.affected_validation_check_inventory.v1';producer=$Producer;source=$Source;plan_sha256=$PlanSha256;platform=$Platform;entries=@($ordered)
        claims=[pscustomobject][ordered]@{cache_transport_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false}
    }
    $json = ConvertTo-MorphospaceCanonicalJson -Value $inventory
    if (-not (Test-Json -Json $json -SchemaFile $InventorySchemaPath -ErrorAction Stop)) { throw 'Affected check evidence inventory fails its closed schema before publication.' }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    $stream = [IO.File]::Open($inventoryPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
    return [pscustomobject][ordered]@{path=$inventoryPath;sha256=Get-MorphospaceAffectedCheckBytesSha256 $bytes;entry_count=[int]$ordered.Count}
}

function Read-MorphospaceAffectedCheckInventory {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][object]$ExpectedProducerContext,
        [Parameter(Mandatory = $true)][string]$InventorySchemaPath
    )
    $root = [IO.Path]::GetFullPath($EvidenceDirectory)
    Assert-MorphospaceAffectedCheckNoReparsePath -Root ([IO.Path]::GetDirectoryName($root)) -Path $root
    $inventoryPath = Join-Path $root 'inventory.json'
    Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $inventoryPath
    [byte[]]$inventoryBytes = Read-MorphospaceAffectedCheckStableBytes -Path $inventoryPath
    $raw = [Text.UTF8Encoding]::new($false,$true).GetString($inventoryBytes)
    if (-not (Test-Json -Json $raw -SchemaFile $InventorySchemaPath -ErrorAction Stop)) { throw 'Affected check prior inventory fails its closed schema.' }
    $inventory = $raw | ConvertFrom-Json -Depth 64 -DateKind String
    foreach ($field in @('context','repository','event_name','pull_request_number','workflow_path')) {
        if ([string]$inventory.producer.$field -cne [string]$ExpectedProducerContext.$field) { throw "Affected check prior inventory producer differs in '$field'." }
    }
    $expectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$expectedPaths.Add('inventory.json')
    $candidateSnapshots = [Collections.Generic.List[object]]::new()
    $previous = $null
    foreach ($entry in @($inventory.entries)) {
        $checkId = [string]$entry.check_id
        if ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$checkId) -ge 0) { throw 'Affected check prior inventory entries are not unique and ordinal sorted.' }
        $entryBytes = @{}
        $entryPaths = @{}
        foreach ($recordName in @('receipt','stdout','stderr')) {
            $record = $entry.$recordName
            $relative = ConvertTo-MorphospaceAffectedCheckPath -Path ([string]$record.path)
            if (-not $expectedPaths.Add($relative)) { throw 'Affected check prior inventory repeats an evidence path.' }
            $path = Join-Path $root $relative
            Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $path
            [byte[]]$bytes = Read-MorphospaceAffectedCheckStableBytes -Path $path
            if ([long]$bytes.Length -ne [long]$record.bytes -or (Get-MorphospaceAffectedCheckBytesSha256 $bytes) -cne [string]$record.sha256) { throw 'Affected check prior inventory file differs from its finalized record.' }
            $entryBytes[$recordName] = [byte[]]$bytes
            $entryPaths[$recordName] = $path
        }
        $receiptRaw = [Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$entryBytes.receipt)
        $receipt = $receiptRaw | ConvertFrom-Json -Depth 64 -DateKind String
        if ([string]$receipt.binding.check_id -cne $checkId) { throw 'Affected check prior inventory entry and receipt identities differ.' }
        $artifactSnapshots = [Collections.Generic.List[object]]::new()
        $entryArtifacts = @($entry.artifacts)
        $receiptArtifacts = @($receipt.artifacts)
        if ($entryArtifacts.Count -ne $receiptArtifacts.Count) { throw 'Affected check prior inventory artifact count differs from its receipt.' }
        for ($artifactIndex=0; $artifactIndex -lt $entryArtifacts.Count; $artifactIndex++) {
            $artifactRecord = $entryArtifacts[$artifactIndex]
            $receiptArtifact = $receiptArtifacts[$artifactIndex]
            $phasePath = ConvertTo-MorphospaceAffectedCheckArtifactPath -Path ([string]$artifactRecord.phase_path)
            if ([string]$receiptArtifact.path -cne $phasePath -or [long]$receiptArtifact.bytes -ne [long]$artifactRecord.bytes -or [string]$receiptArtifact.sha256 -cne [string]$artifactRecord.sha256) { throw 'Affected check prior inventory artifact record differs from its receipt.' }
            $relative = ConvertTo-MorphospaceAffectedCheckPath -Path ([string]$artifactRecord.path)
            if (-not $expectedPaths.Add($relative)) { throw 'Affected check prior inventory repeats an artifact evidence path.' }
            $path = Join-Path $root $relative
            Assert-MorphospaceAffectedCheckNoReparsePath -Root $root -Path $path
            [byte[]]$bytes = Read-MorphospaceAffectedCheckStableBytes -Path $path
            if ([long]$bytes.Length -ne [long]$artifactRecord.bytes -or (Get-MorphospaceAffectedCheckBytesSha256 $bytes) -cne [string]$artifactRecord.sha256) { throw 'Affected check prior inventory artifact differs from its finalized record.' }
            $artifactSnapshots.Add([pscustomobject][ordered]@{phase_path=$phasePath;cache_path=$path;bytes_base64=[Convert]::ToBase64String($bytes)})
        }
        $candidateSnapshots.Add([pscustomobject][ordered]@{check_id=$checkId;receipt_path=[string]$entryPaths.receipt;receipt_base64=[Convert]::ToBase64String([byte[]]$entryBytes.receipt);stdout_path=[string]$entryPaths.stdout;stdout_base64=[Convert]::ToBase64String([byte[]]$entryBytes.stdout);stderr_path=[string]$entryPaths.stderr;stderr_base64=[Convert]::ToBase64String([byte[]]$entryBytes.stderr);artifacts=@($artifactSnapshots.ToArray())})
        $previous = $checkId
    }
    [string[]]$actualPaths = @(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/') })
    if ($actualPaths.Count -ne $expectedPaths.Count -or @($actualPaths | Where-Object { -not $expectedPaths.Contains($_) }).Count -ne 0) { throw 'Affected check prior inventory is not a complete closed file inventory.' }
    return [pscustomobject][ordered]@{inventory=$inventory;inventory_sha256=Get-MorphospaceAffectedCheckBytesSha256 $inventoryBytes;candidate_snapshots=@($candidateSnapshots.ToArray())}
}

Export-ModuleMember -Function Get-MorphospaceAffectedCheckBytesSha256, Get-MorphospaceAffectedCheckRunnerBinding, Get-MorphospaceAffectedCheckRunnerSourceManifest, Get-MorphospaceAffectedCheckDependencyManifest, New-MorphospaceAffectedCheckBinding, Get-MorphospaceAffectedCheckArtifactReferences, New-MorphospaceAffectedCheckSnapshot, Get-MorphospaceAffectedCheckPhaseArtifacts, Restore-MorphospaceAffectedCheckArtifacts, Test-MorphospaceAffectedCheckReceipt, Find-MorphospaceAffectedReusableCheckReceipt, Write-MorphospaceAffectedCheckReceipt, Write-MorphospaceAffectedCheckCache, Write-MorphospaceAffectedCheckInventory, Read-MorphospaceAffectedCheckInventory
