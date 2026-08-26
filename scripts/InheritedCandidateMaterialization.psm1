Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:InheritedCandidateRequiredNonClaims = @(
    'Does not make inherited bytes live product inputs.',
    'Does not authorize validation.',
    'Does not authorize acceptance.'
)

function Assert-MorphospaceInheritedCandidateNonClaims {
    param([Parameter(Mandatory = $true)][object[]]$Claims, [Parameter(Mandatory = $true)][string]$Context)

    $actual = @($Claims | ForEach-Object { [string]$_ })
    foreach ($required in $script:InheritedCandidateRequiredNonClaims) {
        if ($actual -cnotcontains $required) { throw "$Context omits required nonclaim '$required'." }
    }
}

function Assert-MorphospaceInheritedCandidateEntryPath {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Context = 'Inherited-candidate entry path')

    if ($Path -notmatch '^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$' -or
        $Path.Contains('\') -or $Path.Contains(':') -or $Path.Length -gt 512) {
        throw "$Context is not a canonical portable relative path."
    }
    foreach ($segment in @($Path.Split('/'))) {
        if ($segment -in @('.', '..', '.git') -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
            throw "$Context contains a forbidden or Windows-equivalent path segment."
        }
    }
}

function Resolve-MorphospaceInheritedCandidateEvidencePath {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][string]$RelativePath, [Parameter(Mandatory = $true)][string]$Context)

    if ($RelativePath -notmatch '^inherited-candidates/[a-z0-9][a-z0-9-]{1,127}/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$') {
        throw "$Context must stay below the portable inherited-candidates task-local root."
    }
    $absolute = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -RequireLeaf
    $item = Get-Item -LiteralPath $absolute -Force
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Context is not a regular non-reparse file."
    }
    return $absolute
}

function Test-MorphospaceInheritedCandidateEvidenceFile {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][object]$Reference, [Parameter(Mandatory = $true)][string]$Context)

    $path = Resolve-MorphospaceInheritedCandidateEvidencePath -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$Reference.path) -Context $Context
    $length = [int64](Get-Item -LiteralPath $path -Force).Length
    if ($length -ne [int64]$Reference.length) { throw "$Context length differs from the exact binding." }
    $sha256 = Get-MorphospaceFileSha256 -Path $path
    if ($sha256 -cne [string]$Reference.sha256) { throw "$Context SHA-256 differs from the exact binding." }
    return [pscustomobject][ordered]@{ path = $path; sha256 = $sha256; length = $length }
}

function Assert-MorphospaceInheritedCandidateReferenceEqual {
    param([Parameter(Mandatory = $true)][object]$Expected, [Parameter(Mandatory = $true)][object]$Actual, [Parameter(Mandatory = $true)][string]$Context)

    foreach ($property in @('path', 'sha256', 'length')) {
        if ([string]$Expected.$property -cne [string]$Actual.$property) { throw "$Context $property differs from the binding." }
    }
}

function Get-MorphospaceInheritedCandidateArchiveRows {
    param([Parameter(Mandatory = $true)][string]$ArchivePath, [Parameter(Mandatory = $true)][object[]]$Inventory)

    $expected = @{}
    $expectedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $total = [int64]0
    for ($index = 0; $index -lt $Inventory.Count; $index++) {
        $row = $Inventory[$index]
        if ([int]$row.ordinal -ne $index) { throw 'Inherited-candidate file inventory ordinals must be contiguous.' }
        $path = [string]$row.path
        Assert-MorphospaceInheritedCandidateEntryPath -Path $path -Context 'Inherited-candidate inventory path'
        if (-not $expectedKeys.Add($path)) { throw 'Inherited-candidate file inventory has an equivalent or case-colliding path.' }
        $total += [int64]$row.length
        if ($total -gt 67108864) { throw 'Inherited-candidate file inventory exceeds its 64 MiB aggregate bound.' }
        $expected[$path] = $row
    }

    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $actual = New-Object System.Collections.Generic.List[object]
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($archive.Entries)) {
            $entryPath = ([string]$entry.FullName).Replace('\', '/')
            if ($entryPath.EndsWith('/')) {
                Assert-MorphospaceInheritedCandidateEntryPath -Path ($entryPath.TrimEnd('/')) -Context 'Inherited-candidate archive directory'
                continue
            }
            Assert-MorphospaceInheritedCandidateEntryPath -Path $entryPath -Context 'Inherited-candidate archive entry'
            if (-not $seen.Add($entryPath) -or -not $expected.ContainsKey($entryPath)) { throw "Inherited-candidate archive has an unexpected or duplicate entry '$entryPath'." }
            $expectedRow = $expected[$entryPath]
            $attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
            $modeBits = (($attributes -shr 16) -band 0xffff)
            $mode = ([Convert]::ToString([int]$modeBits, 8)).PadLeft(6, '0')
            if ($mode -notin @('100644', '100755') -or $mode -cne [string]$expectedRow.file_mode) {
                throw "Inherited-candidate archive file mode differs for '$entryPath'."
            }
            if ([int64]$entry.Length -ne [int64]$expectedRow.length) { throw "Inherited-candidate archive length differs for '$entryPath'." }
            $stream = $entry.Open()
            try { $sha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))).ToLowerInvariant() } finally { $stream.Dispose() }
            if ($sha256 -cne [string]$expectedRow.sha256) { throw "Inherited-candidate archive SHA-256 differs for '$entryPath'." }
            $actual.Add([pscustomobject][ordered]@{ ordinal = [int]$expectedRow.ordinal; path = $entryPath; sha256 = $sha256; length = [int64]$entry.Length; file_mode = $mode; entry = $entry }) | Out-Null
        }
        if ($actual.Count -ne $Inventory.Count) { throw 'Inherited-candidate archive omits one or more inventory entries.' }
        return @($actual.ToArray() | Sort-Object ordinal)
    } finally { $archive.Dispose() }
}

function Test-MorphospaceInheritedCandidateEvidenceBinding {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][object]$Unit)

    if ($Unit.PSObject.Properties.Name -notcontains 'inherited_candidate') {
        return [pscustomobject][ordered]@{ declared = $false; status = 'not-applicable' }
    }
    $declaration = $Unit.inherited_candidate
    $bindingPath = Resolve-MorphospaceInheritedCandidateEvidencePath -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$declaration.binding_path) -Context 'Inherited-candidate evidence binding'
    $bindingSha256 = Get-MorphospaceFileSha256 -Path $bindingPath
    if ($bindingSha256 -cne [string]$declaration.binding_sha256) { throw 'Inherited-candidate evidence-binding SHA-256 differs from the unit declaration.' }
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $bindingRaw = Get-Content -LiteralPath $bindingPath -Raw
    if (-not (Test-Json -Json $bindingRaw -SchemaFile (Join-Path $repoRoot 'schemas\inherited-candidate-evidence-binding-v1.schema.json'))) { throw 'Inherited-candidate evidence binding is malformed.' }
    $binding = Read-MorphospaceProtocolJson -Path $bindingPath
    if ([string]$binding.project_id -cne [string]$Unit.project_id -or [string]$binding.unit_id -cne [string]$Unit.unit_id) { throw 'Inherited-candidate evidence binding project or unit differs from the active unit.' }
    if ([string]$binding.materialization.destination_leaf -cne [string]$binding.binding_id) { throw 'Inherited-candidate materialization leaf must equal the binding identity.' }
    Assert-MorphospaceInheritedCandidateNonClaims -Claims @($binding.does_not_prove) -Context 'Inherited-candidate evidence binding'

    $references = @('manifest', 'archive', 'patch', 'file_inventory')
    $resolved = @{}
    $pathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $references) {
        $reference = $binding.$name
        if (-not $pathSet.Add([string]$reference.path)) { throw 'Inherited-candidate evidence binding reuses an evidence path.' }
        $resolved[$name] = Test-MorphospaceInheritedCandidateEvidenceFile -WorkspaceRoot $WorkspaceRoot -Reference $reference -Context "Inherited-candidate $name"
    }

    $manifestRaw = Get-Content -LiteralPath ([string]$resolved.manifest.path) -Raw
    if (-not (Test-Json -Json $manifestRaw -SchemaFile (Join-Path $repoRoot 'schemas\inherited-candidate-manifest-v1.schema.json'))) { throw 'Inherited-candidate task-local manifest is malformed.' }
    $manifest = Read-MorphospaceProtocolJson -Path ([string]$resolved.manifest.path)
    if ([string]$manifest.binding_id -cne [string]$binding.binding_id -or [string]$manifest.project_id -cne [string]$binding.project_id -or [string]$manifest.unit_id -cne [string]$binding.unit_id) { throw 'Inherited-candidate task-local manifest identity differs from the binding.' }
    foreach ($name in @('archive', 'patch', 'file_inventory')) { Assert-MorphospaceInheritedCandidateReferenceEqual -Expected $binding.$name -Actual $manifest.$name -Context "Inherited-candidate task-local manifest $name" }
    if ((Get-MorphospaceCanonicalJsonSha256 $manifest.source) -cne (Get-MorphospaceCanonicalJsonSha256 $binding.source)) { throw 'Inherited-candidate task-local manifest source base/head/tree binding differs.' }
    Assert-MorphospaceInheritedCandidateNonClaims -Claims @($manifest.does_not_prove) -Context 'Inherited-candidate task-local manifest'

    $inventoryRaw = Get-Content -LiteralPath ([string]$resolved.file_inventory.path) -Raw
    if (-not (Test-Json -Json $inventoryRaw -SchemaFile (Join-Path $repoRoot 'schemas\inherited-candidate-file-inventory-v1.schema.json'))) { throw 'Inherited-candidate file inventory is malformed.' }
    $inventory = Read-MorphospaceProtocolJson -Path ([string]$resolved.file_inventory.path)
    if ([string]$inventory.binding_id -cne [string]$binding.binding_id) { throw 'Inherited-candidate file inventory identity differs from the binding.' }
    $archiveRows = @(Get-MorphospaceInheritedCandidateArchiveRows -ArchivePath ([string]$resolved.archive.path) -Inventory @($inventory.files))
    return [pscustomobject][ordered]@{
        declared = $true; status = 'verified'; binding = $binding; binding_path = [string]$declaration.binding_path; binding_sha256 = $bindingSha256
        manifest = $resolved.manifest; archive = $resolved.archive; patch = $resolved.patch; file_inventory = $resolved.file_inventory
        inventory = @($inventory.files); archive_rows = $archiveRows
    }
}

function Get-MorphospaceInheritedCandidateClaimEvent {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][object]$Unit, [Parameter(Mandatory = $true)][object]$Binding)

    $eventsPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath 'iteration-events.jsonl' -RequireLeaf
    $matches = @((Get-Content -LiteralPath $eventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) | Where-Object {
        [string]$_.unit_id -ceq [string]$Unit.unit_id -and [string]$_.event_id -match "^$([regex]::Escape([string]$Unit.unit_id))-claimed-[0-9]{4}$"
    })
    if ($matches.Count -ne 1 -or @($matches[0].receipts | Where-Object { [string]$_ -ceq [string]$Unit.inherited_candidate.binding_path }).Count -ne 1) {
        throw 'Inherited-candidate materialization requires the exact Claim event to bind the evidence declaration.'
    }
    return $matches[0]
}

function Test-MorphospaceInheritedCandidateMaterializationMarker {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][object]$Unit, [Parameter(Mandatory = $true)][object]$BindingEvidence)

    if ($Unit.PSObject.Properties.Name -notcontains 'inherited_candidate_materialization') { throw 'Inherited-candidate evidence requires exact post-Claim materialization before source work.' }
    $markerRef = $Unit.inherited_candidate_materialization
    $markerPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$markerRef.marker_path) -RequireLeaf
    $item = Get-Item -LiteralPath $markerPath -Force
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or (Get-MorphospaceFileSha256 -Path $markerPath) -cne [string]$markerRef.marker_sha256) { throw 'Inherited-candidate materialization marker is missing, reparse-backed, or hash-drifted.' }
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $markerRaw = Get-Content -LiteralPath $markerPath -Raw
    if (-not (Test-Json -Json $markerRaw -SchemaFile (Join-Path $repoRoot 'schemas\inherited-candidate-materialization-marker-v1.schema.json'))) { throw 'Inherited-candidate materialization marker is malformed.' }
    $marker = Read-MorphospaceProtocolJson -Path $markerPath
    $claimEvent = Get-MorphospaceInheritedCandidateClaimEvent -WorkspaceRoot $WorkspaceRoot -Unit $Unit -Binding $BindingEvidence.binding
    if ([string]$marker.project_id -cne [string]$Unit.project_id -or [string]$marker.unit_id -cne [string]$Unit.unit_id -or
        [string]$marker.materialization_id -cne [string]$markerRef.materialization_id -or [string]$marker.claim_event_id -cne [string]$claimEvent.event_id -or
        [string]$marker.binding.binding_id -cne [string]$BindingEvidence.binding.binding_id -or [string]$marker.binding.path -cne [string]$Unit.inherited_candidate.binding_path -or
        [string]$marker.binding.sha256 -cne [string]$BindingEvidence.binding_sha256) { throw 'Inherited-candidate materialization marker identity differs from its Claim binding.' }
    if ([string]$marker.destination.leaf -cne [string]$BindingEvidence.binding.materialization.destination_leaf -or
        [string]$marker.verification.manifest_sha256 -cne [string]$BindingEvidence.manifest.sha256 -or
        [string]$marker.verification.archive_sha256 -cne [string]$BindingEvidence.archive.sha256 -or
        [string]$marker.verification.patch_sha256 -cne [string]$BindingEvidence.patch.sha256 -or
        [string]$marker.verification.inventory_sha256 -cne [string]$BindingEvidence.file_inventory.sha256 -or
        [int]$marker.verification.file_count -ne @($BindingEvidence.inventory).Count) { throw 'Inherited-candidate materialization marker verification differs from the Claim-bound evidence.' }
    Assert-MorphospaceInheritedCandidateNonClaims -Claims @($marker.does_not_prove) -Context 'Inherited-candidate materialization marker'
    return $marker
}

function Test-MorphospaceInheritedCandidateMaterializationGate {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][object]$Unit)

    $binding = Test-MorphospaceInheritedCandidateEvidenceBinding -WorkspaceRoot $WorkspaceRoot -Unit $Unit
    if (-not $binding.declared) { return $true }
    [void](Test-MorphospaceInheritedCandidateMaterializationMarker -WorkspaceRoot $WorkspaceRoot -Unit $Unit -BindingEvidence $binding)
    return $true
}

function Test-MorphospaceInheritedCandidateMaterializedInventory {
    param([Parameter(Mandatory = $true)][string]$Destination, [Parameter(Mandatory = $true)][object[]]$Inventory)

    if (-not [IO.Directory]::Exists($Destination)) { throw 'Inherited-candidate materialization destination is absent.' }
    Assert-MorphospaceNoReparseAncestor -Root $Destination -Candidate $Destination
    $expected = @{}
    foreach ($row in @($Inventory)) { $expected[[string]$row.path] = $row }
    $actual = @{}
    foreach ($item in @(Get-ChildItem -LiteralPath $Destination -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Inherited-candidate materialization contains a reparse point.' }
        if ($item.PSIsContainer) { continue }
        if ($item -isnot [IO.FileInfo]) { throw 'Inherited-candidate materialization contains a non-regular file.' }
        $relative = $item.FullName.Substring($Destination.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        Assert-MorphospaceInheritedCandidateEntryPath -Path $relative -Context 'Inherited-candidate materialized file'
        if ($actual.ContainsKey($relative) -or -not $expected.ContainsKey($relative)) { throw 'Inherited-candidate materialization contains an unexpected or duplicate file.' }
        $expectedRow = $expected[$relative]
        $sha256 = Get-MorphospaceFileSha256 -Path $item.FullName
        if ([int64]$item.Length -ne [int64]$expectedRow.length -or $sha256 -cne [string]$expectedRow.sha256) { throw "Inherited-candidate materialized file differs at '$relative'." }
        $actual[$relative] = $true
    }
    if ($actual.Count -ne $expected.Count) { throw 'Inherited-candidate materialization omits one or more files.' }
    return Get-MorphospaceCanonicalJsonSha256 @($Inventory)
}

function Get-MorphospaceInheritedCandidateMaterializationRootSha256 {
    param([Parameter(Mandatory = $true)][string]$Root)

    $canonical = [IO.Path]::GetFullPath($Root)
    $volume = [IO.Path]::GetPathRoot($canonical)
    if ($canonical.Length -gt $volume.Length) { $canonical = $canonical.TrimEnd('\', '/') }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($canonical)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Get-MorphospaceInheritedCandidateMaterializationProgressRelativePath {
    param([Parameter(Mandatory = $true)][string]$MaterializationId)

    return "receipts/$MaterializationId-progress.json"
}

function Read-MorphospaceInheritedCandidateMaterializationProgress {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -RequireLeaf
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Inherited-candidate materialization progress is not a regular non-reparse file.'
    }
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $raw = Get-Content -LiteralPath $path -Raw
    if (-not (Test-Json -Json $raw -SchemaFile (Join-Path $repoRoot 'schemas\inherited-candidate-materialization-progress-v1.schema.json'))) {
        throw 'Inherited-candidate materialization progress is malformed.'
    }
    return [pscustomobject][ordered]@{ path = $path; sha256 = Get-MorphospaceFileSha256 -Path $path; document = Read-MorphospaceProtocolJson -Path $path }
}

function Assert-MorphospaceInheritedCandidateMaterializationProgress {
    param(
        [Parameter(Mandatory = $true)][object]$Progress,
        [Parameter(Mandatory = $true)][object]$Project,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object]$BindingEvidence,
        [Parameter(Mandatory = $true)][string]$MaterializationId,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)][string]$ClaimEventId,
        [Parameter(Mandatory = $true)][string]$MarkerRelative,
        [Parameter(Mandatory = $true)][string]$MarkerSha256,
        [Parameter(Mandatory = $true)][string]$EventId,
        [Parameter(Mandatory = $true)][string]$RootSha256
    )

    $doc = $Progress.document
    if ([string]$doc.materialization_id -cne $MaterializationId -or [string]$doc.transaction_id -cne $TransactionId -or
        [string]$doc.project_id -cne [string]$Project.project_id -or [string]$doc.unit_id -cne [string]$Unit.unit_id -or
        [string]$doc.claim_event_id -cne $ClaimEventId) {
        throw 'Inherited-candidate materialization progress identity differs from the active Claim.'
    }
    if ([string]$doc.binding.binding_id -cne [string]$BindingEvidence.binding.binding_id -or
        [string]$doc.binding.path -cne [string]$Unit.inherited_candidate.binding_path -or
        [string]$doc.binding.sha256 -cne [string]$BindingEvidence.binding_sha256) {
        throw 'Inherited-candidate materialization progress binding differs from Claim-time evidence.'
    }
    if ([string]$doc.destination.root_kind -cne 'caller-provided-task-local' -or
        [string]$doc.destination.root_sha256 -cne $RootSha256 -or
        [string]$doc.destination.leaf -cne [string]$BindingEvidence.binding.materialization.destination_leaf) {
        throw 'Inherited-candidate materialization progress destination differs from its task-local root binding.'
    }
    if ([string]$doc.marker.path -cne $MarkerRelative -or [string]$doc.marker.sha256 -cne $MarkerSha256 -or [string]$doc.marker.event_id -cne $EventId) {
        throw 'Inherited-candidate materialization progress marker differs from the exact transaction marker.'
    }
    foreach ($check in @(
        @{ expected = $BindingEvidence.manifest.sha256; actual = $doc.verification.manifest_sha256; name = 'manifest' },
        @{ expected = $BindingEvidence.archive.sha256; actual = $doc.verification.archive_sha256; name = 'archive' },
        @{ expected = $BindingEvidence.patch.sha256; actual = $doc.verification.patch_sha256; name = 'patch' },
        @{ expected = $BindingEvidence.file_inventory.sha256; actual = $doc.verification.inventory_sha256; name = 'inventory' },
        @{ expected = (Get-MorphospaceCanonicalJsonSha256 @($BindingEvidence.inventory)); actual = $doc.verification.inventory_fingerprint_sha256; name = 'inventory fingerprint' }
    )) {
        if ([string]$check.expected -cne [string]$check.actual) { throw "Inherited-candidate materialization progress $($check.name) differs from Claim-bound evidence." }
    }
    if ([int]$doc.verification.file_count -ne @($BindingEvidence.inventory).Count -or $doc.verification.archive_file_modes_verified -ne $true) {
        throw 'Inherited-candidate materialization progress verification differs from the exact inventory.'
    }
    Assert-MorphospaceInheritedCandidateNonClaims -Claims @($doc.does_not_prove) -Context 'Inherited-candidate materialization progress'
}

function Assert-MorphospaceInheritedCandidateMaterializationProgressPreimage {
    param([Parameter(Mandatory = $true)][object]$Progress, [Parameter(Mandatory = $true)][object]$State, [Parameter(Mandatory = $true)][object]$Unit, [Parameter(Mandatory = $true)][string]$EventsPath)

    $events = @(Get-Content -LiteralPath $EventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $expected = $Progress.document.expected
    if ([string]$expected.state_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $State) -or
        [string]$expected.unit_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $Unit) -or
        [string]$expected.events_sha256 -cne (Get-MorphospaceFileSha256 $EventsPath) -or
        [int64]$expected.events_length -ne ([IO.FileInfo]$EventsPath).Length -or
        [string]$expected.event_tail_id -cne [string]$events[-1].event_id) {
        throw 'Inherited-candidate materialization progress preimage is stale or conflicting.'
    }
}

function Test-MorphospaceInheritedCandidateMaterializationMarkerArtifact {
    param([Parameter(Mandatory = $true)][string]$MarkerPath, [Parameter(Mandatory = $true)][string]$MarkerSha256)

    if (-not [IO.File]::Exists($MarkerPath) -or [IO.Directory]::Exists($MarkerPath)) { throw 'Inherited-candidate materialization marker artifact is absent.' }
    $item = Get-Item -LiteralPath $MarkerPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or (Get-MorphospaceFileSha256 -Path $MarkerPath) -cne $MarkerSha256) {
        throw 'Inherited-candidate materialization marker artifact is reparse-backed or hash-drifted.'
    }
    $repoRoot = Split-Path $PSScriptRoot -Parent
    if (-not (Test-Json -Json (Get-Content -LiteralPath $MarkerPath -Raw) -SchemaFile (Join-Path $repoRoot 'schemas\inherited-candidate-materialization-marker-v1.schema.json'))) {
        throw 'Inherited-candidate materialization marker artifact is malformed.'
    }
}

function Invoke-MorphospaceMaterializeInheritedCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$RepoMapPath,
        [Parameter(Mandatory = $true)][string]$MaterializationRoot,
        [Parameter(Mandatory = $true)][string]$OutPath,
        [string]$Timestamp = '',
        [ValidateSet('none', 'after-staged-extraction', 'after-destination-install', 'after-marker-install', 'after-ledger-commit')][string]$FaultAfter = 'none',
        [switch]$Execute
    )

    if ($FaultAfter -ne 'none' -and -not $Execute) { throw 'Inherited-candidate materialization fault injection requires Execute.' }
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $project = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf)
    $state = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
    $unitPath = "iteration-units/$UnitId.json"
    $unit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    if ([string]$unit.status -cne 'active' -or [string]$state.current_unit -cne $UnitId) { throw 'Inherited-candidate materialization requires the matching active current unit.' }
    $bindingEvidence = Test-MorphospaceInheritedCandidateEvidenceBinding -WorkspaceRoot $workspace -Unit $unit
    if (-not $bindingEvidence.declared) { throw 'Inherited-candidate materialization requires an inherited-candidate evidence declaration.' }
    $claimEvent = Get-MorphospaceInheritedCandidateClaimEvent -WorkspaceRoot $workspace -Unit $unit -Binding $bindingEvidence.binding
    $materializationId = "$([string]$bindingEvidence.binding.binding_id)-materialized"
    if ($materializationId.Length -gt 128) { throw 'Inherited-candidate binding identity is too long for its materialization event identity.' }
    $markerRelative = "receipts/$materializationId.json"
    $markerAbsolute = Resolve-MorphospaceWorkspacePath $workspace $markerRelative
    if ([IO.Path]::GetFullPath($OutPath) -cne $markerAbsolute) { throw "Inherited-candidate materialization output must be '$markerRelative'." }
    $root = [IO.Path]::GetFullPath($MaterializationRoot)
    $rootVolume = [IO.Path]::GetPathRoot($root)
    if ($root.Length -gt $rootVolume.Length) { $root = $root.TrimEnd('\', '/') }
    if (-not [IO.Directory]::Exists($root)) { throw 'Inherited-candidate materialization root must already exist as a task-local directory.' }
    $workspacePrefix = $workspace.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($root -ceq $workspace -or $root.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase) -or $workspace.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Inherited-candidate materialization root must not overlap the workflow workspace or a product checkout.' }
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $repoMapFull = [IO.Path]::GetFullPath($RepoMapPath)
    $repoMapFilesystemRoot = [IO.Path]::GetPathRoot($repoMapFull)
    Assert-MorphospaceNoReparseAncestor -Root $repoMapFilesystemRoot -Candidate $repoMapFull
    $repoMapItem = Get-Item -LiteralPath $repoMapFull -Force
    if ($repoMapItem.PSIsContainer -or (($repoMapItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Inherited-candidate materialization repository map must be a regular non-reparse file.' }
    $repoMapRaw = Get-Content -LiteralPath $RepoMapPath -Raw
    if (-not (Test-Json -Json $repoMapRaw -SchemaFile (Join-Path $repoRoot 'schemas\repository-map.schema.json'))) { throw 'Inherited-candidate materialization repository map is malformed.' }
    $repoMap = Read-MorphospaceProtocolJson -Path $RepoMapPath
    foreach ($entry in @($repoMap.repositories)) {
        $mappedRoot = [IO.Path]::GetFullPath([string]$entry.path).TrimEnd('\', '/')
        $mappedFilesystemRoot = [IO.Path]::GetPathRoot($mappedRoot)
        if (-not [IO.Directory]::Exists($mappedRoot)) { throw "Inherited-candidate materialization mapped repository '$([string]$entry.repo_id)' is absent." }
        Assert-MorphospaceNoReparseAncestor -Root $mappedFilesystemRoot -Candidate $mappedRoot
        if ($root -ceq $mappedRoot -or $root.StartsWith($mappedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $mappedRoot.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Inherited-candidate materialization root overlaps mapped repository '$([string]$entry.repo_id)'."
        }
    }
    Assert-MorphospaceNoReparseAncestor -Root $root -Candidate $root
    $destination = Join-Path $root ([string]$bindingEvidence.binding.materialization.destination_leaf)
    $stage = Join-Path $root ('.' + [string]$bindingEvidence.binding.materialization.destination_leaf + '.materializing')
    $rootSha256 = Get-MorphospaceInheritedCandidateMaterializationRootSha256 -Root $root
    $eventId = "$materializationId-recorded"
    if ($eventId.Length -gt 128) { throw 'Inherited-candidate materialization event identity exceeds the portable limit.' }
    $transactionId = "$eventId-transition"
    $progressRelative = Get-MorphospaceInheritedCandidateMaterializationProgressRelativePath -MaterializationId $materializationId
    $progressAbsolute = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $progressRelative
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $intentAbsolute = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $intentRelative
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $completionAbsolute = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $completionRelative
    $progress = if ([IO.File]::Exists($progressAbsolute)) { Read-MorphospaceInheritedCandidateMaterializationProgress -WorkspaceRoot $workspace -RelativePath $progressRelative } else { $null }

    if ($unit.PSObject.Properties.Name -contains 'inherited_candidate_materialization') {
        if ($progress) {
            Assert-MorphospaceInheritedCandidateMaterializationProgress -Progress $progress -Project $project -Unit $unit -BindingEvidence $bindingEvidence -MaterializationId $materializationId -TransactionId $transactionId -ClaimEventId ([string]$claimEvent.event_id) -MarkerRelative $markerRelative -MarkerSha256 ([string]$unit.inherited_candidate_materialization.marker_sha256) -EventId $eventId -RootSha256 $rootSha256
        }
        if ([IO.File]::Exists($intentAbsolute)) {
            [void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -Repair)
        } elseif ([IO.File]::Exists($completionAbsolute)) {
            throw 'Inherited-candidate materialization completion exists without its transition intent.'
        }
        [void](Test-MorphospaceInheritedCandidateMaterializationMarker -WorkspaceRoot $workspace -Unit $unit -BindingEvidence $bindingEvidence)
        [void](Test-MorphospaceInheritedCandidateMaterializedInventory -Destination $destination -Inventory @($bindingEvidence.inventory))
        if ($progress) { Remove-Item -LiteralPath $progressAbsolute -Force }
        return [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'; project_id = $project.project_id; unit_id = $UnitId; action = 'MaterializeInheritedCandidate'; timestamp = $Timestamp; executed = $Execute.IsPresent; transition = 'inherited-candidate-already-materialized'; status_before = 'active'; status_after = 'active'; current_unit_before = $UnitId; current_unit_after = $UnitId; preservation = [ordered]@{ git_mutation_performed = $false; device_mutation_performed = $false; remote_mutation_performed = $false }; audit_receipt = [ordered]@{ path = $markerRelative; sha256 = [string]$unit.inherited_candidate_materialization.marker_sha256 }; event_id = $null }
    }

    if ($progress) {
        if ($Timestamp -and $Timestamp -cne [string]$progress.document.timestamp) { throw 'Inherited-candidate materialization retry timestamp differs from its authenticated progress intent.' }
        $Timestamp = [string]$progress.document.timestamp
    } elseif (-not $Timestamp) {
        $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    }
    if (-not (Test-MorphospaceStrictUtcTimestamp $Timestamp)) { throw 'Inherited-candidate materialization timestamp must be strict UTC.' }

    $marker = [ordered]@{
        schema = 'rusty.morphospace.workflow.inherited_candidate_materialization_marker.v1'; materialization_id = $materializationId; project_id = $project.project_id; unit_id = $UnitId; claim_event_id = [string]$claimEvent.event_id
        binding = [ordered]@{ binding_id = [string]$bindingEvidence.binding.binding_id; path = [string]$unit.inherited_candidate.binding_path; sha256 = [string]$bindingEvidence.binding_sha256 }
        destination = [ordered]@{ root_kind = 'caller-provided-task-local'; leaf = [string]$bindingEvidence.binding.materialization.destination_leaf; archive_applied = $true; raw_patch_applied = $false; product_inputs_used = $false }
        verification = [ordered]@{ manifest_sha256 = [string]$bindingEvidence.manifest.sha256; archive_sha256 = [string]$bindingEvidence.archive.sha256; patch_sha256 = [string]$bindingEvidence.patch.sha256; inventory_sha256 = [string]$bindingEvidence.file_inventory.sha256; inventory_fingerprint_sha256 = (Get-MorphospaceCanonicalJsonSha256 @($bindingEvidence.inventory)); file_count = @($bindingEvidence.inventory).Count; archive_file_modes_verified = $true }
        does_not_prove = @($script:InheritedCandidateRequiredNonClaims)
    }
    $markerBytes = [Text.UTF8Encoding]::new($false).GetBytes((($marker | ConvertTo-Json -Depth 32 -Compress) + "`n"))
    $markerSha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($markerBytes))).ToLowerInvariant()

    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    if ($progress) {
        Assert-MorphospaceInheritedCandidateMaterializationProgress -Progress $progress -Project $project -Unit $unit -BindingEvidence $bindingEvidence -MaterializationId $materializationId -TransactionId $transactionId -ClaimEventId ([string]$claimEvent.event_id) -MarkerRelative $markerRelative -MarkerSha256 $markerSha256 -EventId $eventId -RootSha256 $rootSha256
    } else {
        if ([string]$state.last_event_id -cne [string]$claimEvent.event_id) { throw 'Inherited-candidate materialization must occur immediately after the exact Claim event.' }
        if ([IO.Directory]::Exists($destination) -or [IO.File]::Exists($destination) -or [IO.Directory]::Exists($stage) -or [IO.File]::Exists($stage) -or [IO.File]::Exists($markerAbsolute) -or [IO.Directory]::Exists($markerAbsolute) -or [IO.File]::Exists($intentAbsolute)) { throw 'Inherited-candidate materialization target, stage, marker, or transaction intent is already occupied without authenticated progress.' }
        $events = @(Get-Content -LiteralPath $eventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $progressDocument = [ordered]@{
            schema = 'rusty.morphospace.workflow.inherited_candidate_materialization_progress.v1'; materialization_id = $materializationId; transaction_id = $transactionId; project_id = $project.project_id; unit_id = $UnitId; claim_event_id = [string]$claimEvent.event_id; timestamp = $Timestamp
            binding = [ordered]@{ binding_id = [string]$bindingEvidence.binding.binding_id; path = [string]$unit.inherited_candidate.binding_path; sha256 = [string]$bindingEvidence.binding_sha256 }
            destination = [ordered]@{ root_kind = 'caller-provided-task-local'; root_sha256 = $rootSha256; leaf = [string]$bindingEvidence.binding.materialization.destination_leaf }
            marker = [ordered]@{ path = $markerRelative; sha256 = $markerSha256; event_id = $eventId }
            expected = [ordered]@{ state_sha256 = (Get-MorphospaceCanonicalJsonSha256 $state); unit_sha256 = (Get-MorphospaceCanonicalJsonSha256 $unit); events_sha256 = (Get-MorphospaceFileSha256 $eventsPath); events_length = ([IO.FileInfo]$eventsPath).Length; event_tail_id = [string]$events[-1].event_id }
            verification = [ordered]@{ manifest_sha256 = [string]$bindingEvidence.manifest.sha256; archive_sha256 = [string]$bindingEvidence.archive.sha256; patch_sha256 = [string]$bindingEvidence.patch.sha256; inventory_sha256 = [string]$bindingEvidence.file_inventory.sha256; inventory_fingerprint_sha256 = (Get-MorphospaceCanonicalJsonSha256 @($bindingEvidence.inventory)); file_count = @($bindingEvidence.inventory).Count; archive_file_modes_verified = $true }
            does_not_prove = @($script:InheritedCandidateRequiredNonClaims)
        }
        if (-not (Test-Json -Json ($progressDocument | ConvertTo-Json -Depth 32 -Compress) -SchemaFile (Join-Path $repoRoot 'schemas\inherited-candidate-materialization-progress-v1.schema.json'))) { throw 'Generated inherited-candidate materialization progress is malformed.' }
        if (-not $Execute) {
            return [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'; project_id = $project.project_id; unit_id = $UnitId; action = 'MaterializeInheritedCandidate'; timestamp = $Timestamp; executed = $false; transition = 'inherited-candidate-materialized'; status_before = 'active'; status_after = 'active'; current_unit_before = $UnitId; current_unit_after = $UnitId; preservation = [ordered]@{ git_mutation_performed = $false; device_mutation_performed = $false; remote_mutation_performed = $false }; audit_receipt = [ordered]@{ path = $markerRelative; sha256 = $markerSha256 }; event_id = $null }
        }
        Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath $progressRelative -Value ([pscustomobject]$progressDocument) -NoOverwrite
        $progress = Read-MorphospaceInheritedCandidateMaterializationProgress -WorkspaceRoot $workspace -RelativePath $progressRelative
    }
    if (-not $Execute) {
        return [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'; project_id = $project.project_id; unit_id = $UnitId; action = 'MaterializeInheritedCandidate'; timestamp = $Timestamp; executed = $false; transition = 'inherited-candidate-materialized'; status_before = 'active'; status_after = 'active'; current_unit_before = $UnitId; current_unit_after = $UnitId; preservation = [ordered]@{ git_mutation_performed = $false; device_mutation_performed = $false; remote_mutation_performed = $false }; audit_receipt = [ordered]@{ path = $markerRelative; sha256 = $markerSha256 }; event_id = $null }
    }

    $pendingLedgerIntent = [IO.File]::Exists($intentAbsolute)
    if ($pendingLedgerIntent) {
        if ([IO.Directory]::Exists($stage) -and [IO.Directory]::Exists($destination)) { throw 'Inherited-candidate recovery has both stage and destination; refusing ambiguous external bytes.' }
        if ([IO.Directory]::Exists($stage)) {
            [void](Test-MorphospaceInheritedCandidateMaterializedInventory -Destination $stage -Inventory @($bindingEvidence.inventory))
            [IO.Directory]::Move($stage, $destination)
        }
        if (-not [IO.Directory]::Exists($destination)) { throw 'Inherited-candidate recovery ledger intent lacks its verified task-local destination.' }
        [void](Test-MorphospaceInheritedCandidateMaterializedInventory -Destination $destination -Inventory @($bindingEvidence.inventory))
        if ([IO.File]::Exists($markerAbsolute)) { Test-MorphospaceInheritedCandidateMaterializationMarkerArtifact -MarkerPath $markerAbsolute -MarkerSha256 $markerSha256 }
        [void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -Repair)
    } else {
        Assert-MorphospaceInheritedCandidateMaterializationProgressPreimage -Progress $progress -State $state -Unit $unit -EventsPath $eventsPath
        if ([string]$state.last_event_id -cne [string]$claimEvent.event_id) { throw 'Inherited-candidate materialization recovery no longer has the exact Claim event as its live preimage.' }
        if ([IO.File]::Exists($markerAbsolute) -or [IO.Directory]::Exists($markerAbsolute)) { throw 'Inherited-candidate recovery found a marker without a transition-ledger intent.' }
        if ([IO.Directory]::Exists($stage) -and [IO.Directory]::Exists($destination)) { throw 'Inherited-candidate recovery has both stage and destination; refusing ambiguous external bytes.' }
        if ([IO.File]::Exists($stage) -or [IO.File]::Exists($destination)) { throw 'Inherited-candidate recovery stage or destination is not a directory.' }
        if ([IO.Directory]::Exists($stage)) {
            [void](Test-MorphospaceInheritedCandidateMaterializedInventory -Destination $stage -Inventory @($bindingEvidence.inventory))
        } elseif ([IO.Directory]::Exists($destination)) {
            [void](Test-MorphospaceInheritedCandidateMaterializedInventory -Destination $destination -Inventory @($bindingEvidence.inventory))
        } else {
            $stageVerified = $false
            try {
                [IO.Directory]::CreateDirectory($stage) | Out-Null
                Assert-MorphospaceNoReparseAncestor -Root $root -Candidate $stage
                $archive = [IO.Compression.ZipFile]::OpenRead([string]$bindingEvidence.archive.path)
                try {
                    $entryMap = @{}
                    foreach ($entry in @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })) { $entryMap[([string]$entry.FullName).Replace('\', '/')] = $entry }
                    foreach ($row in @($bindingEvidence.inventory)) {
                        $relative = [string]$row.path; $target = Join-Path $stage ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar)); $parent = Split-Path -Parent $target
                        [IO.Directory]::CreateDirectory($parent) | Out-Null; Assert-MorphospaceNoReparseAncestor -Root $stage -Candidate $parent
                        $input = $entryMap[$relative].Open(); $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                        try { $input.CopyTo($output); $output.Flush($true) } finally { $output.Dispose(); $input.Dispose() }
                    }
                } finally { $archive.Dispose() }
                [void](Test-MorphospaceInheritedCandidateMaterializedInventory -Destination $stage -Inventory @($bindingEvidence.inventory))
                $stageVerified = $true
            } finally {
                if (-not $stageVerified -and [IO.Directory]::Exists($stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
            }
            if ($FaultAfter -eq 'after-staged-extraction') { throw 'Injected interruption after verified inherited-candidate staged extraction.' }
        }
        if ([IO.Directory]::Exists($stage)) {
            [IO.Directory]::Move($stage, $destination)
        }
        [void](Test-MorphospaceInheritedCandidateMaterializedInventory -Destination $destination -Inventory @($bindingEvidence.inventory))
        if ($FaultAfter -eq 'after-destination-install') { throw 'Injected interruption after inherited-candidate destination installation.' }
        $events = @(Get-Content -LiteralPath $eventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $targetUnit = $unit | ConvertTo-Json -Depth 64 | ConvertFrom-Json
        $targetState = $state | ConvertTo-Json -Depth 64 | ConvertFrom-Json
        $targetState.last_event_id = $eventId
        $event = [ordered]@{ schema = 'rusty.morphospace.workflow.iteration_event.v1'; event_id = $eventId; sequence = [int]$events[-1].sequence + 1; timestamp = $Timestamp; project_id = $project.project_id; unit_id = $UnitId; event_type = 'state-transition'; summary = 'Materialized and verified sealed inherited-candidate bytes as a task-local reference without applying the raw patch or using product inputs.'; receipts = @($markerRelative, [string]$unit.inherited_candidate.binding_path) }
        $targetUnit | Add-Member -NotePropertyName inherited_candidate_materialization -NotePropertyValue ([ordered]@{ materialization_id = $materializationId; marker_path = $markerRelative; marker_sha256 = $markerSha256 })
        $ledgerFault = if ($FaultAfter -eq 'after-marker-install') { 'after-artifact' } else { 'none' }
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -StatePath 'workspace.state.json' -UnitPath $unitPath -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event ([pscustomobject]$event) -ExpectedStateSha256 ([string]$progress.document.expected.state_sha256) -ExpectedUnitSha256 ([string]$progress.document.expected.unit_sha256) -ExpectedEventTailId ([string]$progress.document.expected.event_tail_id) -ExpectedEventsSha256 ([string]$progress.document.expected.events_sha256) -ExpectedEventsLength ([int64]$progress.document.expected.events_length) -Artifacts @([pscustomobject]@{ bytes_base64 = [Convert]::ToBase64String($markerBytes); path = $markerRelative; sha256 = $markerSha256 }) -FaultAfter $ledgerFault | Out-Null
        if ($FaultAfter -eq 'after-ledger-commit') { throw 'Injected interruption after inherited-candidate transition-ledger commit.' }
    }
    $finalUnit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    [void](Test-MorphospaceInheritedCandidateMaterializationMarker -WorkspaceRoot $workspace -Unit $finalUnit -BindingEvidence $bindingEvidence)
    [void](Test-MorphospaceInheritedCandidateMaterializedInventory -Destination $destination -Inventory @($bindingEvidence.inventory))
    if ([IO.File]::Exists($progressAbsolute)) { Remove-Item -LiteralPath $progressAbsolute -Force }
    return [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'; project_id = $project.project_id; unit_id = $UnitId; action = 'MaterializeInheritedCandidate'; timestamp = $Timestamp; executed = $true; transition = 'inherited-candidate-materialized'; status_before = 'active'; status_after = 'active'; current_unit_before = $UnitId; current_unit_after = $UnitId; preservation = [ordered]@{ git_mutation_performed = $false; device_mutation_performed = $false; remote_mutation_performed = $false }; audit_receipt = [ordered]@{ path = $markerRelative; sha256 = (Get-MorphospaceFileSha256 $markerAbsolute) }; event_id = $eventId }
}

Export-ModuleMember -Function Test-MorphospaceInheritedCandidateEvidenceBinding, Test-MorphospaceInheritedCandidateMaterializationMarker, Test-MorphospaceInheritedCandidateMaterializationGate, Invoke-MorphospaceMaterializeInheritedCandidate
