Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force

function Get-HistoryArchiveHash { param([object]$Value) Get-MorphospaceCanonicalJsonSha256 -Value $Value }
function Get-HistoryArchiveFileHash { param([string]$Path) Get-MorphospaceFileSha256 -Path $Path }
function Copy-HistoryArchiveValue { param([object]$Value) $Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 }
function Get-HistoryArchivePath { param([string]$Workspace,[string]$Relative,[switch]$RequireLeaf) Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath $Relative -RequireLeaf:$RequireLeaf }
function Get-HistoryArchiveRepoRoot { param([string]$ModuleRoot) Split-Path (Split-Path $ModuleRoot -Parent) -Parent }

function Assert-HistoryArchiveSchema {
    param([string]$RepositoryRoot,[string]$Path,[string]$Schema,[string]$Context)
    try { $valid = Test-Json -Json (Get-Content -Raw -LiteralPath $Path) -SchemaFile (Join-Path $RepositoryRoot "schemas\\$Schema") -ErrorAction Stop }
    catch { throw "$Context schema evaluation failed: $($_.Exception.Message) [$Path]" }
    if (-not $valid) { throw "$Context does not satisfy $Schema." }
}

function Get-HistoryArchiveManagedJsonHash {
    param([object]$Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Value) + "`n")
    return Get-MorphospaceSha256Bytes -Bytes $bytes
}

function Assert-HistoryArchiveValueSchema {
    param([string]$RepositoryRoot,[object]$Value,[string]$Schema,[string]$Context)
    try { $valid = Test-Json -Json (ConvertTo-MorphospaceCanonicalJson $Value) -SchemaFile (Join-Path $RepositoryRoot "schemas\\$Schema") -ErrorAction Stop }
    catch { throw "$Context schema evaluation failed: $($_.Exception.Message)" }
    if (-not $valid) { throw "$Context does not satisfy $Schema." }
}

function Get-HistoryArchiveCanonicalPathArray {
    param([AllowEmptyCollection()][string[]]$Paths,[string]$Context)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result = [Collections.Generic.List[string]]::new()
    foreach ($rawPath in @($Paths)) {
        $path = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$rawPath)
        if (-not $seen.Add($path)) { throw "$Context has a duplicate or case-colliding path '$path'." }
        $result.Add($path)
    }
    $array = @($result.ToArray())
    [Array]::Sort($array, [StringComparer]::Ordinal)
    return @($array)
}

function Test-HistoryArchiveSourcePath {
    param([string]$Path)
    $canonical = ConvertTo-MorphospaceProtocolRelativePath -Path $Path
    if ($canonical -eq 'iteration-events.jsonl') { return 'event-ledger-prefix' }
    if ($canonical -match '^iteration-units/[a-z0-9][a-z0-9-]{1,127}\.json$') { return 'terminal-unit' }
    if ($canonical -match '^receipts/transactions/[a-z0-9][a-z0-9-]{1,127}\.(?:intent|completion)\.json$') { return 'transaction' }
    if ($canonical -match '^receipts/(?:[a-z0-9][a-z0-9-]{1,127}/)*[a-z0-9][a-z0-9-]{1,127}\.json$') { return 'receipt' }
    throw "History archive source path is outside the closed historical surface: $canonical"
}

function Get-HistoryArchiveDirectoryFiles {
    param([string]$Workspace,[string]$RelativeRoot)
    $rootPath = Get-HistoryArchivePath $Workspace $RelativeRoot
    if (-not [IO.Directory]::Exists($rootPath)) { return @() }
    $result = [Collections.Generic.List[string]]::new()
    function Visit-HistoryArchiveDirectory {
        param([string]$Absolute,[string]$Relative)
        $attributes = [IO.File]::GetAttributes($Absolute)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "History archive refuses reparse directory: $Relative" }
        $entries = @([IO.Directory]::EnumerateFileSystemEntries($Absolute))
        [Array]::Sort($entries, [StringComparer]::Ordinal)
        foreach ($entry in $entries) {
            $name = [IO.Path]::GetFileName($entry)
            $childRelative = if ($Relative) { "$Relative/$name" } else { $name }
            $childAttributes = [IO.File]::GetAttributes($entry)
            if (($childAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "History archive refuses reparse entry: $childRelative" }
            if (($childAttributes -band [IO.FileAttributes]::Directory) -ne 0) { Visit-HistoryArchiveDirectory $entry $childRelative }
            else { $result.Add((ConvertTo-MorphospaceProtocolRelativePath -Path $childRelative)) }
        }
    }
    Visit-HistoryArchiveDirectory $rootPath $RelativeRoot
    return @(Get-HistoryArchiveCanonicalPathArray -Paths @($result.ToArray()) -Context "History archive $RelativeRoot inventory")
}

function Get-HistoryArchiveEventPrefix {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    if ($Bytes.Length -eq 0) { throw 'History archive requires a nonempty event ledger.' }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString($Bytes)
    if ($text.Contains("`r") -or -not $text.EndsWith("`n", [StringComparison]::Ordinal)) { throw 'History archive requires canonical LF-terminated event ledger bytes.' }
    $lines = @($text.Substring(0, $text.Length - 1).Split("`n"))
    if ($lines.Count -eq 0 -or @($lines | Where-Object { $_.Length -eq 0 }).Count -gt 0) { throw 'History archive rejects blank event ledger records.' }
    $previous = 0; $tail = $null
    foreach ($line in $lines) {
        $event = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $encoding.GetBytes($line) -Context 'history archive event record'
        if ([string]$event.schema -cne 'rusty.morphospace.workflow.iteration_event.v1' -or [int]$event.sequence -ne ($previous + 1) -or [string]::IsNullOrWhiteSpace([string]$event.event_id)) { throw 'History archive event prefix has noncanonical identity or sequence.' }
        $previous = [int]$event.sequence; $tail = $event
    }
    return [pscustomobject]@{ bytes = $Bytes; sha256 = Get-MorphospaceSha256Bytes -Bytes $Bytes; byte_length = [long]$Bytes.Length; line_count = $lines.Count; tail = $tail }
}

function Get-HistoryArchivePathReferences {
    param([object]$Value)
    $paths = [Collections.Generic.List[string]]::new()
    function Visit-HistoryArchiveValue {
        param([object]$Item)
        if ($null -eq $Item) { return }
        if ($Item -is [string]) {
            if ($Item.StartsWith('receipts/', [StringComparison]::Ordinal)) { $paths.Add((ConvertTo-MorphospaceProtocolRelativePath -Path $Item)) }
            return
        }
        if ($Item -is [Collections.IEnumerable] -and $Item -isnot [string]) { foreach ($child in $Item) { Visit-HistoryArchiveValue $child }; return }
        foreach ($property in $Item.PSObject.Properties) { Visit-HistoryArchiveValue $property.Value }
    }
    Visit-HistoryArchiveValue $Value
    return @(Get-HistoryArchiveCanonicalPathArray -Paths @($paths.ToArray()) -Context 'History archive carry-forward references')
}

function Get-HistoryArchiveSourceInventory {
    param([string]$Workspace,[object]$State,[byte[]]$EventPrefixBytes=$null)
    $records = [Collections.Generic.List[object]]::new()
    $eventsPath = Get-HistoryArchivePath $Workspace 'iteration-events.jsonl' -RequireLeaf
    $eventBytes = if ($null -ne $EventPrefixBytes) { $EventPrefixBytes } else { [IO.File]::ReadAllBytes($eventsPath) }
    $eventPrefix = Get-HistoryArchiveEventPrefix -Bytes $eventBytes
    $records.Add([pscustomobject][ordered]@{ source_path='iteration-events.jsonl'; kind='event-ledger-prefix'; sha256=$eventPrefix.sha256; byte_length=$eventPrefix.byte_length }) | Out-Null
    foreach ($relative in @(Get-HistoryArchiveDirectoryFiles $Workspace 'iteration-units')) {
        $path = Get-HistoryArchivePath $Workspace $relative -RequireLeaf
        $unit = Read-MorphospaceProtocolJson -Path $path
        if ([string]$unit.status -notin @('accepted','blocked','superseded')) { throw "History archive requires terminal units; '$relative' is '$([string]$unit.status)'." }
        $records.Add([pscustomobject][ordered]@{ source_path=$relative; kind='terminal-unit'; sha256=(Get-HistoryArchiveFileHash $path); byte_length=[long]([IO.FileInfo]$path).Length }) | Out-Null
    }
    foreach ($relative in @(Get-HistoryArchiveDirectoryFiles $Workspace 'receipts')) {
        $kind = Test-HistoryArchiveSourcePath $relative
        $path = Get-HistoryArchivePath $Workspace $relative -RequireLeaf
        $records.Add([pscustomobject][ordered]@{ source_path=$relative; kind=$kind; sha256=(Get-HistoryArchiveFileHash $path); byte_length=[long]([IO.FileInfo]$path).Length }) | Out-Null
    }
    $paths = @(Get-HistoryArchiveCanonicalPathArray -Paths @($records | ForEach-Object { [string]$_.source_path }) -Context 'History archive source inventory')
    if ($paths.Count -ne $records.Count) { throw 'History archive inventory cardinality is not canonical.' }
    $byPath = @{}; foreach ($record in $records) { $byPath[[string]$record.source_path] = $record }
    $ordered = @($paths | ForEach-Object { $byPath[$_] })
    $carryForward = [Collections.Generic.List[object]]::new()
    foreach ($reference in @(Get-HistoryArchivePathReferences $State)) {
        if (-not $byPath.ContainsKey($reference)) { throw "History archive compact state references a receipt outside its raw inventory: $reference" }
        $carryForward.Add([pscustomobject][ordered]@{ source_path=$reference; sha256=[string]$byPath[$reference].sha256; reason='compact-state-reference' }) | Out-Null
    }
    return [pscustomobject]@{ records=@($ordered); event_prefix=$eventPrefix; carry_forward=@($carryForward.ToArray()) }
}

function Get-HistoryArchiveInventoryCommitment {
    param([object[]]$Records,[string]$Context)
    $commitment = [Collections.Generic.List[object]]::new()
    foreach ($record in @($Records)) {
        $sourcePath = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$record.source_path)
        $kind = Test-HistoryArchiveSourcePath $sourcePath
        if ($record.PSObject.Properties.Name -contains 'kind' -and [string]$record.kind -cne $kind) { throw "$Context assigns '$([string]$record.kind)' to '$sourcePath', but its source-derived kind is '$kind'." }
        $sha256 = [string]$record.sha256
        $byteLength = [long]$record.byte_length
        if ($sha256 -notmatch '^[0-9a-f]{64}$' -or $byteLength -lt 1) { throw "$Context contains an invalid raw-byte source record." }
        $commitment.Add([pscustomobject][ordered]@{source_path=$sourcePath;kind=$kind;sha256=$sha256;byte_length=$byteLength}) | Out-Null
    }
    $canonicalPaths = @(Get-HistoryArchiveCanonicalPathArray -Paths @($commitment | ForEach-Object { [string]$_.source_path }) -Context $Context)
    if ($canonicalPaths.Count -ne $commitment.Count) { throw "$Context cardinality is not canonical." }
    for ($index = 0; $index -lt $canonicalPaths.Count; $index++) {
        if ([string]$commitment[$index].source_path -cne [string]$canonicalPaths[$index]) { throw "$Context is not in canonical source-path order." }
    }
    return @($commitment.ToArray())
}

function Get-HistoryArchiveRawObjectPath {
    param([string]$Sha256)
    if ($Sha256 -notmatch '^[0-9a-f]{64}$') { throw 'History archive object SHA-256 is invalid.' }
    return "history-archive/objects/sha256/$Sha256.blob"
}

function Get-HistoryArchiveComparableObjects {
    param([object[]]$Records,[string]$Context)
    $normalized = [Collections.Generic.List[object]]::new()
    foreach ($record in @($Records)) {
        $sourcePath = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$record.source_path)
        $objectPath = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$record.object_path)
        $sha256 = [string]$record.sha256
        $byteLength = [long]$record.byte_length
        if ($sha256 -notmatch '^[0-9a-f]{64}$' -or $byteLength -lt 0 -or $objectPath -cne (Get-HistoryArchiveRawObjectPath $sha256)) { throw "$Context contains a noncanonical content-addressed object record." }
        $normalized.Add([pscustomobject][ordered]@{source_path=$sourcePath;object_path=$objectPath;sha256=$sha256;byte_length=$byteLength}) | Out-Null
    }
    $canonicalPaths = @(Get-HistoryArchiveCanonicalPathArray -Paths @($normalized | ForEach-Object { [string]$_.source_path }) -Context $Context)
    if ($canonicalPaths.Count -ne $normalized.Count) { throw "$Context cardinality is not canonical." }
    for ($index = 0; $index -lt $canonicalPaths.Count; $index++) {
        if ([string]$normalized[$index].source_path -cne [string]$canonicalPaths[$index]) { throw "$Context is not in canonical source-path order." }
    }
    return @($normalized.ToArray())
}

function Assert-HistoryArchiveExactObjectInventory {
    param([object[]]$Expected,[object[]]$Actual,[string]$Context)
    $expectedObjects = @(Get-HistoryArchiveComparableObjects -Records $Expected -Context "$Context expected inventory")
    $actualObjects = @(Get-HistoryArchiveComparableObjects -Records $Actual -Context "$Context actual inventory")
    if ($expectedObjects.Count -ne $actualObjects.Count -or (Get-HistoryArchiveHash $expectedObjects) -cne (Get-HistoryArchiveHash $actualObjects)) { throw "$Context is not an exact canonical object inventory." }
    return $expectedObjects
}

function Install-HistoryArchiveRawObject {
    param([string]$Workspace,[string]$RelativePath,[byte[]]$Bytes,[string]$ExpectedSha256)
    if ((Get-MorphospaceSha256Bytes -Bytes $Bytes) -cne $ExpectedSha256) { throw 'History archive source bytes changed before object installation.' }
    $target = Get-HistoryArchivePath $Workspace $RelativePath
    if ([IO.File]::Exists($target)) {
        if ((Get-HistoryArchiveFileHash $target) -cne $ExpectedSha256 -or ([IO.FileInfo]$target).Length -ne $Bytes.Length) { throw "History archive object conflicts with its content address: $RelativePath" }
        return
    }
    $parent = [IO.Path]::GetDirectoryName($target); if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    Assert-MorphospaceNoReparseAncestor -Root ([IO.Path]::GetFullPath($Workspace)) -Candidate $parent
    $pending = @([IO.Directory]::EnumerateFiles($parent, ([IO.Path]::GetFileName($target) + '.pending-*')))
    if ($pending.Count -gt 1) { throw "History archive object has multiple pending candidates: $RelativePath" }
    if ($pending.Count -eq 1) {
        $pendingPath = $pending[0]; Assert-MorphospaceNoReparseAncestor -Root ([IO.Path]::GetFullPath($Workspace)) -Candidate $pendingPath
        if ((Get-HistoryArchiveFileHash $pendingPath) -cne $ExpectedSha256 -or ([IO.FileInfo]$pendingPath).Length -ne $Bytes.Length) { throw "History archive pending object is damaged: $RelativePath" }
        [IO.File]::Move($pendingPath, $target); return
    }
    $pendingPath = "$target.pending-$([guid]::NewGuid().ToString('N'))"
    $stream = [IO.FileStream]::new($pendingPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ((Get-HistoryArchiveFileHash $pendingPath) -cne $ExpectedSha256 -or ([IO.FileInfo]$pendingPath).Length -ne $Bytes.Length) { throw "History archive pending object readback failed: $RelativePath" }
    [IO.File]::Move($pendingPath, $target)
    if ((Get-HistoryArchiveFileHash $target) -cne $ExpectedSha256 -or ([IO.FileInfo]$target).Length -ne $Bytes.Length) { throw "History archive object publication readback failed: $RelativePath" }
}

function New-HistoryArchiveRoot {
    param([object]$Request,[object]$Inventory,[string]$Timestamp)
    $objects = [Collections.Generic.List[object]]::new()
    foreach ($record in @($Inventory.records)) {
        $objects.Add([pscustomobject][ordered]@{ source_path=[string]$record.source_path; object_path=(Get-HistoryArchiveRawObjectPath ([string]$record.sha256)); kind=[string]$record.kind; sha256=[string]$record.sha256; byte_length=[long]$record.byte_length }) | Out-Null
    }
    return [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.history_archive_root.v1'; root_id=[string]$Request.checkpoint_id; checkpoint_id=[string]$Request.checkpoint_id; project_id=[string]$Request.project_id; created_at=$Timestamp
        source_prefix=[pscustomobject][ordered]@{ path='iteration-events.jsonl'; sha256=[string]$Inventory.event_prefix.sha256; byte_length=[long]$Inventory.event_prefix.byte_length; line_count=[int]$Inventory.event_prefix.line_count; tail_event_id=[string]$Inventory.event_prefix.tail.event_id; tail_sequence=[int]$Inventory.event_prefix.tail.sequence }
        objects=@($objects.ToArray()); carry_forward=@($Inventory.carry_forward); does_not_prove=@('Does not delete, move, rewrite, normalize, accept, publish, build, deploy, launch, or mutate a device.')
    }
}

function New-HistoryArchiveTargetState {
    param([object]$State,[object]$Root,[string]$RootPath,[string]$RootSha256,[string]$EventId)
    $target = Copy-HistoryArchiveValue $State
    $archiveBinding = [pscustomobject][ordered]@{ checkpoint_id=[string]$Root.checkpoint_id; root_path=$RootPath; root_sha256=$RootSha256; source_prefix_sha256=[string]$Root.source_prefix.sha256; source_prefix_length=[long]$Root.source_prefix.byte_length }
    if ($target.PSObject.Properties.Name -contains 'history_archive') { $target.history_archive = $archiveBinding }
    else { $target | Add-Member -NotePropertyName history_archive -NotePropertyValue $archiveBinding }
    $target.last_event_id = $EventId
    return $target
}

function New-HistoryArchiveCheckpointReceipt {
    param([object]$Request,[string]$RequestPath,[string]$RequestHash,[object]$Root,[string]$RootPath,[string]$RootSha256,[object]$PreEvents,[object]$TargetState,[object]$Event)
    return [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.history_archive_checkpoint.v1'; record_kind='receipt'; checkpoint_id=[string]$Request.checkpoint_id; project_id=[string]$Request.project_id
        input=[pscustomobject][ordered]@{path=$RequestPath;sha256=$RequestHash}; root=[pscustomobject][ordered]@{path=$RootPath;sha256=$RootSha256}
        source_prefix=[pscustomobject][ordered]@{path='iteration-events.jsonl';sha256=[string]$PreEvents.sha256;byte_length=[long]$PreEvents.byte_length;tail_event_id=[string]$PreEvents.tail.event_id}
        state=[pscustomobject][ordered]@{path='workspace.state.json';sha256=(Get-HistoryArchiveHash $TargetState);document=$TargetState};event=$Event
        preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false;history_bytes_moved=$false;history_bytes_deleted=$false;history_bytes_rewritten=$false}
        does_not_prove=@('Does not claim a historical aggregate passed, repair historical evidence, accept a unit, or authorize publication.')
    }
}

function Assert-HistoryArchiveIdlePreflight {
    param([string]$Workspace,[string]$RepositoryRoot,[object]$Request,[string]$RequestHash)
    $projectPath=Get-HistoryArchivePath $Workspace 'project.spec.json' -RequireLeaf;$statePath=Get-HistoryArchivePath $Workspace 'workspace.state.json' -RequireLeaf;$eventsPath=Get-HistoryArchivePath $Workspace 'iteration-events.jsonl' -RequireLeaf
    Assert-HistoryArchiveSchema $RepositoryRoot $projectPath 'project-spec-v2.schema.json' 'History archive project';Assert-HistoryArchiveSchema $RepositoryRoot $statePath 'workspace-state-v2.schema.json' 'History archive state'
    $project=Read-MorphospaceProtocolJson $projectPath;$state=Read-MorphospaceProtocolJson $statePath;$events=Get-HistoryArchiveEventPrefix -Bytes ([IO.File]::ReadAllBytes($eventsPath))
    if ([string]$project.project_id -cne [string]$Request.project_id -or [string]$state.project_id -cne [string]$Request.project_id) { throw 'History archive project identity is not exact.' }
    if ($null -ne $state.current_unit -or $null -ne $state.next_ready_unit -or @($state.blockers).Count -ne 0 -or $null -ne $state.pending_push_bundle) { throw 'History archive requires an idle project with no current, ready, blocker, or pending-push authority.' }
    if ($state.PSObject.Properties.Name -contains 'history_archive' -and $null -ne $state.history_archive) { throw 'History archive checkpoint already exists; replay only its exact typed transaction.' }
    foreach ($check in @(@{expected=$Request.expected.project_sha256;actual=(Get-HistoryArchiveHash $project);name='project'},@{expected=$Request.expected.state_sha256;actual=(Get-HistoryArchiveHash $state);name='state'},@{expected=$Request.expected.events_sha256;actual=$events.sha256;name='event ledger'})) { if ([string]$check.expected -cne [string]$check.actual) { throw "History archive stale $($check.name) preimage." } }
    if ([long]$Request.expected.events_length -ne [long]$events.byte_length -or [string]$Request.expected.event_tail_id -cne [string]$events.tail.event_id) { throw 'History archive event offset or tail preimage is stale.' }
    $inventory=Get-HistoryArchiveSourceInventory $Workspace $state
    $inventoryCommitment=Get-HistoryArchiveInventoryCommitment -Records @($inventory.records) -Context 'History archive observed source inventory'
    if ((Get-HistoryArchiveHash $inventoryCommitment) -cne [string]$Request.expected.source_inventory_sha256) { throw 'History archive stale caller-pinned source inventory preimage.' }
    $anchorRelative="iteration-units/$([string]$events.tail.unit_id).json"; if (-not (@($inventory.records | ForEach-Object { [string]$_.source_path }) -ccontains $anchorRelative)) { throw 'History archive event tail does not bind a terminal archived unit.' }
    return [pscustomobject]@{project=$project;state=$state;events=$events;inventory=$inventory;inventory_commitment=$inventoryCommitment;project_path=$projectPath;state_path=$statePath;events_path=$eventsPath;request_hash=$RequestHash}
}

function Assert-HistoryArchiveIntent {
    param([string]$RepositoryRoot,[string]$Path,[object]$Request,[string]$RequestHash)
    Assert-HistoryArchiveSchema $RepositoryRoot $Path 'history-archive-checkpoint-v1.schema.json' 'History archive intent'
    $intent=Read-MorphospaceProtocolJson $Path
    $checkpointId=[string]$Request.checkpoint_id
    if ([string]$intent.record_kind -cne 'intent' -or [string]$intent.transaction_id -cne "$checkpointId-archive-transition" -or [string]$intent.checkpoint_id -cne $checkpointId -or [string]$intent.project_id -cne [string]$Request.project_id -or [string]$intent.request.path -cne "history-archive/requests/$checkpointId.json" -or [string]$intent.request.sha256 -cne $RequestHash) { throw 'History archive intent is not bound to the exact request.' }
    if ([string]$intent.pre.project.sha256 -cne [string]$Request.expected.project_sha256 -or [string]$intent.pre.state.sha256 -cne [string]$Request.expected.state_sha256 -or [string]$intent.pre.events.sha256 -cne [string]$Request.expected.events_sha256 -or [long]$intent.pre.events.byte_length -ne [long]$Request.expected.events_length -or [string]$intent.pre.events.tail_event_id -cne [string]$Request.expected.event_tail_id) { throw 'History archive intent preimages are not bound to the exact request.' }
    foreach($binding in @($intent.pre.state,$intent.target.state)) {
        if((Get-HistoryArchiveHash $binding.document) -cne [string]$binding.sha256) { throw 'History archive intent state document hash binding is invalid.' }
        Assert-HistoryArchiveValueSchema $RepositoryRoot $binding.document 'workspace-state-v2.schema.json' 'History archive intent state document'
    }
    if((Get-HistoryArchiveManagedJsonHash $intent.root.document) -cne [string]$intent.root.sha256 -or (Get-HistoryArchiveHash $intent.root.document) -cne ([IO.Path]::GetFileNameWithoutExtension([string]$intent.root.path))) { throw 'History archive root document hash binding is invalid.' }
    Assert-HistoryArchiveValueSchema $RepositoryRoot $intent.root.document 'history-archive-root-v1.schema.json' 'History archive intent root document'
    if((Get-HistoryArchiveManagedJsonHash $intent.receipt.document) -cne [string]$intent.receipt.sha256) { throw 'History archive receipt document hash binding is invalid.' }
    Assert-HistoryArchiveValueSchema $RepositoryRoot $intent.receipt.document 'history-archive-checkpoint-v1.schema.json' 'History archive intent receipt document'
    $expectedState=New-HistoryArchiveTargetState $intent.pre.state.document $intent.root.document ([string]$intent.root.path) ([string]$intent.root.sha256) ([string]$intent.event.event_id)
    if((Get-HistoryArchiveHash $expectedState) -cne [string]$intent.target.state.sha256 -or (Get-HistoryArchiveHash $expectedState) -cne (Get-HistoryArchiveHash $intent.target.state.document)) { throw 'History archive intent target state changes authority beyond the checkpoint binding.' }
    if([string]$intent.root.document.project_id -cne [string]$intent.project_id -or [string]$intent.root.document.checkpoint_id -cne $checkpointId -or [string]$intent.root.document.source_prefix.sha256 -cne [string]$intent.pre.events.sha256 -or [long]$intent.root.document.source_prefix.byte_length -ne [long]$intent.pre.events.byte_length -or [string]$intent.root.document.source_prefix.tail_event_id -cne [string]$intent.pre.events.tail_event_id) { throw 'History archive root is not bound to the exact preimage.' }
    $rootCommitment=Get-HistoryArchiveInventoryCommitment -Records @($intent.root.document.objects) -Context 'History archive immutable root inventory'
    if ((Get-HistoryArchiveHash $rootCommitment) -cne [string]$Request.expected.source_inventory_sha256) { throw 'History archive immutable root inventory is not bound to the caller-pinned source inventory preimage.' }
    [void](Assert-HistoryArchiveExactObjectInventory -Expected @($intent.root.document.objects) -Actual @($intent.objects) -Context 'History archive intent versus immutable root inventory')
    if([string]$intent.event.project_id -cne [string]$intent.project_id -or [string]$intent.event.event_id -cne "$checkpointId-archived" -or [int]$intent.event.sequence -le 0 -or @($intent.event.receipts).Count -ne 1 -or [string]$intent.event.receipts[0] -cne [string]$intent.receipt.path) { throw 'History archive event is not bound to the exact checkpoint receipt.' }
    $receipt=$intent.receipt.document
    if([string]$receipt.record_kind -cne 'receipt' -or [string]$receipt.project_id -cne [string]$intent.project_id -or [string]$receipt.checkpoint_id -cne $checkpointId -or [string]$receipt.input.path -cne [string]$intent.request.path -or [string]$receipt.input.sha256 -cne [string]$intent.request.sha256 -or [string]$receipt.root.path -cne [string]$intent.root.path -or [string]$receipt.root.sha256 -cne [string]$intent.root.sha256 -or [string]$receipt.state.sha256 -cne [string]$intent.target.state.sha256 -or (Get-HistoryArchiveHash $receipt.state.document) -cne [string]$intent.target.state.sha256 -or (Get-HistoryArchiveHash $receipt.event) -cne (Get-HistoryArchiveHash $intent.event)) { throw 'History archive receipt is not bound to the exact intent.' }
    return $intent
}

function Assert-HistoryArchiveCompletion {
    param([string]$RepositoryRoot,[string]$CompletionPath,[string]$IntentRelative,[string]$IntentPath,[object]$Intent)
    Assert-HistoryArchiveSchema $RepositoryRoot $CompletionPath 'history-archive-checkpoint-v1.schema.json' 'History archive completion'
    $completion=Read-MorphospaceProtocolJson $CompletionPath
    if([string]$completion.record_kind -cne 'completion' -or [string]$completion.transaction_id -cne [string]$Intent.transaction_id -or [string]$completion.checkpoint_id -cne [string]$Intent.checkpoint_id -or [string]$completion.project_id -cne [string]$Intent.project_id -or [string]$completion.intent.path -cne $IntentRelative -or [string]$completion.intent.sha256 -cne (Get-HistoryArchiveFileHash $IntentPath) -or [string]$completion.root.path -cne [string]$Intent.root.path -or [string]$completion.root.sha256 -cne [string]$Intent.root.sha256 -or [string]$completion.target_state_sha256 -cne [string]$Intent.target.state.sha256 -or [string]$completion.event_id -cne [string]$Intent.event.event_id -or [string]$completion.status -cne 'committed') { throw 'History archive completion does not authenticate the exact intent.' }
    return $completion
}

function Get-HistoryArchiveTailEvents {
    param([byte[]]$Bytes,[long]$PrefixLength)
    if($Bytes.Length -le $PrefixLength) { throw 'archive-event-missing' }
    $tailLength=[int]($Bytes.Length-$PrefixLength);$tailBytes=[byte[]]::new($tailLength);[Array]::Copy($Bytes,[int]$PrefixLength,$tailBytes,0,$tailLength)
    $encoding=[Text.UTF8Encoding]::new($false,$true);$text=$encoding.GetString($tailBytes)
    if($text.Contains([string][char]13) -or -not $text.EndsWith([string][char]10,[StringComparison]::Ordinal)) { throw 'archive-tail-drift' }
    $lines=@($text.Substring(0,$text.Length-1).Split([string][char]10));if($lines.Count -eq 0 -or @($lines|Where-Object{$_.Length -eq 0}).Count -gt 0){throw 'archive-tail-drift'}
    return @($lines|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $encoding.GetBytes($_) -Context 'history archive tail event'})
}

function Assert-HistoryArchiveCompletedSurface {
    param([string]$Workspace,[string]$RepositoryRoot,[string]$IntentRelative,[string]$CompletionRelative,[object]$Intent)
    $intentPath=Get-HistoryArchivePath $Workspace $IntentRelative -RequireLeaf;$completionPath=Get-HistoryArchivePath $Workspace $CompletionRelative -RequireLeaf
    [void](Assert-HistoryArchiveCompletion $RepositoryRoot $completionPath $IntentRelative $intentPath $Intent)
    $rootPath=Get-HistoryArchivePath $Workspace ([string]$Intent.root.path) -RequireLeaf
    if((Get-HistoryArchiveFileHash $rootPath) -cne [string]$Intent.root.sha256){throw 'History archive completed root bytes differ from the exact intent.'}
    Assert-HistoryArchiveSchema $RepositoryRoot $rootPath 'history-archive-root-v1.schema.json' 'History archive completed root'
    if((Get-HistoryArchiveHash (Read-MorphospaceProtocolJson $rootPath)) -cne (Get-HistoryArchiveHash $Intent.root.document)){throw 'History archive completed root document differs from the exact intent.'}
    $receiptPath=Get-HistoryArchivePath $Workspace ([string]$Intent.receipt.path) -RequireLeaf
    if((Get-HistoryArchiveFileHash $receiptPath) -cne [string]$Intent.receipt.sha256){throw 'History archive completed receipt bytes differ from the exact intent.'}
    Assert-HistoryArchiveSchema $RepositoryRoot $receiptPath 'history-archive-checkpoint-v1.schema.json' 'History archive completed receipt'
    if((Get-HistoryArchiveHash (Read-MorphospaceProtocolJson $receiptPath)) -cne (Get-HistoryArchiveHash $Intent.receipt.document)){throw 'History archive completed receipt document differs from the exact intent.'}
    foreach($record in @($Intent.objects)){$objectPath=Get-HistoryArchivePath $Workspace ([string]$record.object_path) -RequireLeaf;if((Get-HistoryArchiveFileHash $objectPath) -cne [string]$record.sha256 -or [long]([IO.FileInfo]$objectPath).Length -ne [long]$record.byte_length){throw 'History archive completed raw object differs from the exact intent.'}}
    $statePath=Get-HistoryArchivePath $Workspace 'workspace.state.json' -RequireLeaf;Assert-HistoryArchiveSchema $RepositoryRoot $statePath 'workspace-state-v2.schema.json' 'History archive completed state';$state=Read-MorphospaceProtocolJson $statePath
    if((Get-HistoryArchiveHash $state) -cne [string]$Intent.target.state.sha256 -or [string]$state.last_event_id -cne [string]$Intent.event.event_id){throw 'History archive completed state differs from the exact intent.'}
    $eventPath=Get-HistoryArchivePath $Workspace 'iteration-events.jsonl' -RequireLeaf;$events=[IO.File]::ReadAllBytes($eventPath);if($events.Length -lt [long]$Intent.pre.events.byte_length){throw 'History archive completed ledger is shorter than its bound prefix.'};$prefix=[byte[]]::new([int]$Intent.pre.events.byte_length);[Array]::Copy($events,0,$prefix,0,$prefix.Length)
    if((Get-MorphospaceSha256Bytes $prefix) -cne [string]$Intent.pre.events.sha256){throw 'History archive completed ledger prefix differs from the exact intent.'}
    $fullEvents=Get-HistoryArchiveEventPrefix -Bytes $events
    $tail=@(Get-HistoryArchiveTailEvents $events ([long]$Intent.pre.events.byte_length));if((Get-HistoryArchiveHash $tail[0]) -cne (Get-HistoryArchiveHash $Intent.event)){throw 'History archive completed event differs from the exact intent.'}
    if([string]$state.last_event_id -cne [string]$fullEvents.tail.event_id){throw 'History archive completed state does not bind the exact live ledger tail.'}
}

function Complete-MorphospaceHistoryArchiveCheckpoint {
    param([string]$Workspace,[string]$RepositoryRoot,[string]$IntentRelative,[string]$CompletionRelative,[ValidateSet('none','after-objects','after-root','after-receipt','after-state','after-event')][string]$FaultAfter='none')
    $intentPath=Get-HistoryArchivePath $Workspace $IntentRelative -RequireLeaf
    $intentProbe=Read-MorphospaceProtocolJson $intentPath
    $requestPath=Get-HistoryArchivePath $Workspace ([string]$intentProbe.request.path) -RequireLeaf
    Assert-HistoryArchiveSchema $RepositoryRoot $requestPath 'history-archive-checkpoint-v1.schema.json' 'History archive request'
    $request=Read-MorphospaceProtocolJson $requestPath;$requestHash=Get-HistoryArchiveFileHash $requestPath
    $intent=Assert-HistoryArchiveIntent $RepositoryRoot $intentPath $request $requestHash
    $completedPath=Get-HistoryArchivePath $Workspace $CompletionRelative
    if([IO.File]::Exists($completedPath)){[void](Assert-HistoryArchiveCompletedSurface $Workspace $RepositoryRoot $IntentRelative $CompletionRelative $intent);return 'already-committed'}
    $projectPath=Get-HistoryArchivePath $Workspace 'project.spec.json' -RequireLeaf;$statePath=Get-HistoryArchivePath $Workspace 'workspace.state.json' -RequireLeaf;$eventPath=Get-HistoryArchivePath $Workspace 'iteration-events.jsonl' -RequireLeaf
    Assert-HistoryArchiveSchema $RepositoryRoot $projectPath 'project-spec-v2.schema.json' 'History archive recovery project';Assert-HistoryArchiveSchema $RepositoryRoot $statePath 'workspace-state-v2.schema.json' 'History archive recovery state'
    $project=Read-MorphospaceProtocolJson $projectPath;$state=Read-MorphospaceProtocolJson $statePath
    if((Get-HistoryArchiveHash $project) -cne [string]$intent.pre.project.sha256 -or [string]$project.project_id -cne [string]$intent.project_id){throw 'History archive project drifted after intent.'}
    $stateHash=Get-HistoryArchiveHash $state
    if($stateHash -cne [string]$intent.pre.state.sha256 -and $stateHash -cne [string]$intent.target.state.sha256){throw 'History archive state conflicts with the exact intent.'}
    $liveEventBytes=[IO.File]::ReadAllBytes($eventPath)
    if($liveEventBytes.Length -lt [long]$intent.pre.events.byte_length){throw 'History archive event ledger became shorter than its bound prefix.'}
    $prefix=[byte[]]::new([int]$intent.pre.events.byte_length);[Array]::Copy($liveEventBytes,0,$prefix,0,$prefix.Length)
    if((Get-MorphospaceSha256Bytes $prefix) -cne [string]$intent.pre.events.sha256){throw 'History archive event prefix drifted after intent.'}
    $fullEvents=Get-HistoryArchiveEventPrefix -Bytes $liveEventBytes
    if($stateHash -ceq [string]$intent.pre.state.sha256) {
        if($liveEventBytes.Length -ne [long]$intent.pre.events.byte_length){throw 'History archive recovery ledger conflicts with the exact predecessor before persistence.'}
    } elseif($liveEventBytes.Length -gt [long]$intent.pre.events.byte_length) {
        $preexistingTail=@(Get-HistoryArchiveTailEvents $liveEventBytes ([long]$intent.pre.events.byte_length))
        if($preexistingTail.Count -ne 1 -or (Get-HistoryArchiveHash $preexistingTail[0]) -cne (Get-HistoryArchiveHash $intent.event) -or [string]$fullEvents.tail.event_id -cne [string]$intent.event.event_id){throw 'History archive target state conflicts with the exact live ledger tail before persistence.'}
    }
    $sourceInventory=Get-HistoryArchiveSourceInventory -Workspace $Workspace -State $intent.pre.state.document -EventPrefixBytes $prefix
    $sourceCommitment=Get-HistoryArchiveInventoryCommitment -Records @($sourceInventory.records) -Context 'History archive recovery observed source inventory'
    if((Get-HistoryArchiveHash $sourceCommitment) -cne [string]$request.expected.source_inventory_sha256){throw 'History archive recovery source inventory drifted from the caller-pinned preimage.'}
    $sourceObjects=@($sourceInventory.records|ForEach-Object{[pscustomobject][ordered]@{source_path=[string]$_.source_path;object_path=(Get-HistoryArchiveRawObjectPath ([string]$_.sha256));sha256=[string]$_.sha256;byte_length=[long]$_.byte_length}})
    [void](Assert-HistoryArchiveExactObjectInventory -Expected $sourceObjects -Actual @($intent.root.document.objects) -Context 'History archive recovery source versus root inventory')
    [void](Assert-HistoryArchiveExactObjectInventory -Expected $sourceObjects -Actual @($intent.objects) -Context 'History archive recovery source versus intent inventory')
    foreach($record in @($intent.objects)){
        $sourcePath=[string]$record.source_path;$bytes=if($sourcePath -ceq 'iteration-events.jsonl'){$prefix}else{[IO.File]::ReadAllBytes((Get-HistoryArchivePath $Workspace $sourcePath -RequireLeaf))}
        if($bytes.Length -ne [long]$record.byte_length -or (Get-MorphospaceSha256Bytes $bytes) -cne [string]$record.sha256){throw "History archive source drifted after intent: $sourcePath"}
        Install-HistoryArchiveRawObject $Workspace ([string]$record.object_path) $bytes ([string]$record.sha256)
    }
    if($FaultAfter -eq 'after-objects'){throw 'Injected history archive interruption after raw objects.'}
    $rootPath=Get-HistoryArchivePath $Workspace ([string]$intent.root.path)
    if([IO.File]::Exists($rootPath)){if((Get-HistoryArchiveFileHash $rootPath) -cne [string]$intent.root.sha256){throw 'History archive root conflicts with the intent.'}}else{Write-MorphospaceManagedProtocolJsonAtomic $Workspace ([string]$intent.root.path) $intent.root.document -NoOverwrite}
    if((Get-HistoryArchiveFileHash $rootPath) -cne [string]$intent.root.sha256){throw 'History archive root bytes differ from the intent.'};Assert-HistoryArchiveSchema $RepositoryRoot $rootPath 'history-archive-root-v1.schema.json' 'History archive root'
    if($FaultAfter -eq 'after-root'){throw 'Injected history archive interruption after root.'}
    $receiptPath=Get-HistoryArchivePath $Workspace ([string]$intent.receipt.path)
    if([IO.File]::Exists($receiptPath)){if((Get-HistoryArchiveFileHash $receiptPath) -cne [string]$intent.receipt.sha256){throw 'History archive receipt conflicts with the intent.'}}else{Write-MorphospaceManagedProtocolJsonAtomic $Workspace ([string]$intent.receipt.path) $intent.receipt.document -NoOverwrite}
    if((Get-HistoryArchiveFileHash $receiptPath) -cne [string]$intent.receipt.sha256){throw 'History archive receipt bytes differ from the intent.'};Assert-HistoryArchiveSchema $RepositoryRoot $receiptPath 'history-archive-checkpoint-v1.schema.json' 'History archive receipt'
    if($FaultAfter -eq 'after-receipt'){throw 'Injected history archive interruption after receipt.'}
    if($stateHash -ceq [string]$intent.pre.state.sha256){Write-MorphospaceManagedProtocolJsonAtomic $Workspace 'workspace.state.json' $intent.target.state.document}
    $state=Read-MorphospaceProtocolJson $statePath
    Assert-HistoryArchiveSchema $RepositoryRoot $statePath 'workspace-state-v2.schema.json' 'History archive target state'
    if((Get-HistoryArchiveHash $state) -cne [string]$intent.target.state.sha256 -or [string]$state.last_event_id -cne [string]$intent.event.event_id){throw 'History archive target state does not match the exact intent.'}
    if($FaultAfter -eq 'after-state'){throw 'Injected history archive interruption after state.'}
    $currentBytes=[IO.File]::ReadAllBytes($eventPath)
    $tailEvents=if($currentBytes.Length -eq [long]$intent.pre.events.byte_length){@()}else{@(Get-HistoryArchiveTailEvents $currentBytes ([long]$intent.pre.events.byte_length))}
    $matches=@($tailEvents|Where-Object{[string]$_.event_id -ceq [string]$intent.event.event_id})
    if($matches.Count -gt 1 -or ($matches.Count -eq 1 -and (Get-HistoryArchiveHash $matches[0]) -cne (Get-HistoryArchiveHash $intent.event)) -or ($matches.Count -eq 1 -and (Get-HistoryArchiveHash $tailEvents[0]) -cne (Get-HistoryArchiveHash $intent.event))){throw 'History archive event conflicts with the intent.'}
    if($matches.Count -eq 0){
        if((Get-HistoryArchiveFileHash $eventPath) -cne [string]$intent.pre.events.sha256){throw 'History archive event predecessor drifted before append.'}
        [IO.File]::AppendAllText($eventPath,(ConvertTo-MorphospaceCanonicalJson $intent.event)+[string][char]10,[Text.UTF8Encoding]::new($false))
    }
    $finalEvents=Get-HistoryArchiveEventPrefix -Bytes ([IO.File]::ReadAllBytes($eventPath))
    if([string]$finalEvents.tail.event_id -cne [string]$intent.event.event_id){throw 'History archive event tail does not match the exact intent.'}
    if($FaultAfter -eq 'after-event'){throw 'Injected history archive interruption after event.'}
    $completionPath=Get-HistoryArchivePath $Workspace $CompletionRelative
    $completion=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.history_archive_checkpoint.v1';record_kind='completion';transaction_id=$intent.transaction_id;completed_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');intent=[pscustomobject][ordered]@{path=$IntentRelative;sha256=(Get-HistoryArchiveFileHash $intentPath)};checkpoint_id=$intent.checkpoint_id;project_id=$intent.project_id;root=[pscustomobject][ordered]@{path=$intent.root.path;sha256=$intent.root.sha256};target_state_sha256=$intent.target.state.sha256;event_id=$intent.event.event_id;status='committed'}
    Write-MorphospaceManagedProtocolJsonAtomic $Workspace $CompletionRelative $completion -NoOverwrite
    [void](Assert-HistoryArchiveCompletion $RepositoryRoot $completionPath $IntentRelative $intentPath $intent)
    return 'committed'
}
function Invoke-MorphospaceArchiveHistoryCheckpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$WorkspaceRoot,[Parameter(Mandatory=$true)][string]$HistoryArchiveCheckpoint,[Parameter(Mandatory=$true)][string]$OutPath,[string]$ExpectedHistoryArchiveCheckpointSha256='',[string]$Timestamp='',[switch]$Execute,[ValidateSet('none','after-intent','after-objects','after-root','after-receipt','after-state','after-event')][string]$FaultAfter='none')
    $repositoryRoot=Get-HistoryArchiveRepoRoot $PSScriptRoot;$workspace=(Resolve-Path $WorkspaceRoot).Path;$requestPath=(Resolve-Path $HistoryArchiveCheckpoint).Path;Assert-HistoryArchiveSchema $repositoryRoot $requestPath 'history-archive-checkpoint-v1.schema.json' 'History archive input';$request=Read-MorphospaceProtocolJson $requestPath;if([string]$request.record_kind-cne'request'){throw 'History archive input must be a request record.'};$requestRelative="history-archive/requests/$([string]$request.checkpoint_id).json";if([IO.Path]::GetFullPath($requestPath)-cne(Get-HistoryArchivePath $workspace $requestRelative -RequireLeaf)){throw "History archive input must be '$requestRelative'."};$requestHash=Get-HistoryArchiveFileHash $requestPath
    if($Execute-and-not$ExpectedHistoryArchiveCheckpointSha256){throw 'Executed history archive checkpoint requires the dry-run request SHA-256.'};if($ExpectedHistoryArchiveCheckpointSha256-and$ExpectedHistoryArchiveCheckpointSha256-cne$requestHash){throw 'History archive expected request SHA-256 does not match input.'};if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};[void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    $checkpointId=[string]$request.checkpoint_id;$receiptRelative="history-archive/checkpoints/$checkpointId.json";$transactionId="$checkpointId-archive-transition";$intentRelative="history-archive/transactions/$transactionId.intent.json";$completionRelative="history-archive/transactions/$transactionId.completion.json";if([IO.Path]::GetFullPath($OutPath)-cne(Get-HistoryArchivePath $workspace $receiptRelative)){throw "History archive output must be '$receiptRelative'."}
    $intentPath=Get-HistoryArchivePath $workspace $intentRelative;if([IO.File]::Exists($intentPath)){$intent=Assert-HistoryArchiveIntent $repositoryRoot $intentPath $request $requestHash;if($Execute){$mutex=Enter-MorphospaceWorkspaceMutex $workspace;try{[void](Complete-MorphospaceHistoryArchiveCheckpoint $workspace $repositoryRoot $intentRelative $completionRelative -FaultAfter $FaultAfter)}finally{Exit-MorphospaceWorkspaceMutex $mutex}};return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$request.project_id;unit_id=[string]$intent.event.unit_id;action='ArchiveHistoryCheckpoint';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='history-archive-checkpointed';status_before='accepted';status_after='accepted';current_unit_before=$null;current_unit_after=$null;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$receiptRelative;sha256=[string]$intent.receipt.sha256};event_id=$(if($Execute){[string]$intent.event.event_id}else{$null})}}
    $context=Assert-HistoryArchiveIdlePreflight $workspace $repositoryRoot $request $requestHash;$root=New-HistoryArchiveRoot $request $context.inventory $Timestamp;$rootCanonicalHash=Get-HistoryArchiveHash $root;$rootRelative="history-archive/roots/$rootCanonicalHash.json";$rootBytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $root)+"`n");$rootRawHash=Get-MorphospaceSha256Bytes $rootBytes;$eventId="$checkpointId-archived";$targetState=New-HistoryArchiveTargetState $context.state $root $rootRelative $rootRawHash $eventId;$event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=([int]$context.events.tail.sequence+1);timestamp=$Timestamp;project_id=$request.project_id;unit_id=[string]$context.events.tail.unit_id;event_type='decision';summary='Archived a raw-byte historical prefix into a content-addressed checkpoint; current authority and tail validation remain live.';receipts=@($receiptRelative)};$receipt=New-HistoryArchiveCheckpointReceipt $request $requestRelative $requestHash $root $rootRelative $rootRawHash $context.events $targetState $event;$receiptBytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $receipt)+"`n");$receiptHash=Get-MorphospaceSha256Bytes $receiptBytes
    if(-not$Execute){return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$request.project_id;unit_id=[string]$event.unit_id;action='ArchiveHistoryCheckpoint';timestamp=$Timestamp;executed=$false;transition='history-archive-checkpointed';status_before='accepted';status_after='accepted';current_unit_before=$null;current_unit_after=$null;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$receiptRelative;sha256=$receiptHash};event_id=$null}}
    $intent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.history_archive_checkpoint.v1';record_kind='intent';transaction_id=$transactionId;created_at=$Timestamp;checkpoint_id=$checkpointId;project_id=$request.project_id;request=[pscustomobject][ordered]@{path=$requestRelative;sha256=$requestHash};pre=[pscustomobject][ordered]@{project=[pscustomobject][ordered]@{path='project.spec.json';sha256=(Get-HistoryArchiveHash $context.project)};state=[pscustomobject][ordered]@{path='workspace.state.json';sha256=(Get-HistoryArchiveHash $context.state);document=$context.state};events=[pscustomobject][ordered]@{path='iteration-events.jsonl';sha256=$context.events.sha256;byte_length=$context.events.byte_length;tail_event_id=$context.events.tail.event_id}};target=[pscustomobject][ordered]@{state=[pscustomobject][ordered]@{path='workspace.state.json';sha256=(Get-HistoryArchiveHash $targetState);document=$targetState}};root=[pscustomobject][ordered]@{path=$rootRelative;sha256=$rootRawHash;document=$root};objects=@($context.inventory.records|ForEach-Object{[pscustomobject][ordered]@{source_path=$_.source_path;object_path=(Get-HistoryArchiveRawObjectPath $_.sha256);sha256=$_.sha256;byte_length=$_.byte_length}});event=$event;receipt=[pscustomobject][ordered]@{path=$receiptRelative;sha256=$receiptHash;document=$receipt};status='prepared'}
    $mutex=Enter-MorphospaceWorkspaceMutex $workspace;try{if([IO.File]::Exists($intentPath)){throw 'History archive intent appeared during observation; retry against that exact typed intent.'};Write-MorphospaceManagedProtocolJsonAtomic $workspace $intentRelative $intent -NoOverwrite;if($FaultAfter-eq'after-intent'){throw 'Injected history archive interruption after intent.'};[void](Complete-MorphospaceHistoryArchiveCheckpoint $workspace $repositoryRoot $intentRelative $completionRelative -FaultAfter $FaultAfter)}finally{Exit-MorphospaceWorkspaceMutex $mutex}
    return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$request.project_id;unit_id=[string]$event.unit_id;action='ArchiveHistoryCheckpoint';timestamp=$Timestamp;executed=$true;transition='history-archive-checkpointed';status_before='accepted';status_after='accepted';current_unit_before=$null;current_unit_after=$null;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$receiptRelative;sha256=$receiptHash};event_id=$eventId}
}

function Test-MorphospaceHistoryArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$WorkspaceRoot,[ValidateSet('quick','deep','audit','migration')][string]$Tier='quick',[string]$ValidationId='history-archive-validation')
    $repositoryRoot=Get-HistoryArchiveRepoRoot $PSScriptRoot
    $workspace=(Resolve-Path $WorkspaceRoot).Path
    $state=Read-MorphospaceProtocolJson (Get-HistoryArchivePath $workspace 'workspace.state.json' -RequireLeaf)
    $checkpoint=[pscustomobject]@{checkpoint_id='none';root_path=('history-archive/roots/'+('0'*64)+'.json');root_sha256=('0'*64)}
    $checked=[Collections.Generic.List[string]]::new()
    try {
        Assert-HistoryArchiveSchema $repositoryRoot (Get-HistoryArchivePath $workspace 'workspace.state.json' -RequireLeaf) 'workspace-state-v2.schema.json' 'History archive live state'
        $pending=@()
        foreach($intentPath in @(Get-HistoryArchiveDirectoryFiles $workspace 'history-archive/transactions' | Where-Object { $_ -match '^history-archive/transactions/[a-z0-9][a-z0-9-]{1,127}\.intent\.json$' })) {
            $completionRelative=$intentPath -replace '\.intent\.json$','.completion.json'
            if(-not [IO.File]::Exists((Get-HistoryArchivePath $workspace $completionRelative))) {$pending += $intentPath}
        }
        if($pending.Count -ne 0){throw 'incomplete-transaction'}
        if (-not($state.PSObject.Properties.Name -contains 'history_archive') -or $null -eq $state.history_archive) {
            $completed=@(Get-HistoryArchiveDirectoryFiles $workspace 'history-archive/transactions' | Where-Object { $_ -match '^history-archive/transactions/[a-z0-9][a-z0-9-]{1,127}\.completion\.json$' })
            if($completed.Count -ne 0){throw 'unregistered-checkpoint'}
            return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.history_archive_validation_result.v1';validation_id=$ValidationId;project_id=$state.project_id;tier=$Tier;mode='tail-only';status='pass';checkpoint=$checkpoint;source_prefix=[pscustomobject]@{matches=$true;byte_length=1;sha256=('0'*64)};carry_forward=[pscustomobject]@{complete=$true;checked_paths=@()};reason_codes=@('none');does_not_prove=@('Does not claim an archive checkpoint exists for a project that has not been archived.')}
        }
        Assert-MorphospaceExactPropertySet $state.history_archive @('checkpoint_id','root_path','root_sha256','source_prefix_sha256','source_prefix_length') @() 'History archive state binding'
        $checkpoint=[pscustomobject]@{checkpoint_id=[string]$state.history_archive.checkpoint_id;root_path=[string]$state.history_archive.root_path;root_sha256=[string]$state.history_archive.root_sha256}
        $checkpointId=[string]$checkpoint.checkpoint_id;$requestRelative="history-archive/requests/$checkpointId.json";$intentRelative="history-archive/transactions/$checkpointId-archive-transition.intent.json";$completionRelative="history-archive/transactions/$checkpointId-archive-transition.completion.json";$receiptRelative="history-archive/checkpoints/$checkpointId.json"
        $requestPath=Get-HistoryArchivePath $workspace $requestRelative -RequireLeaf;$request=Read-MorphospaceProtocolJson $requestPath;$intentPath=Get-HistoryArchivePath $workspace $intentRelative -RequireLeaf
        $intent=Assert-HistoryArchiveIntent $repositoryRoot $intentPath $request (Get-HistoryArchiveFileHash $requestPath)
        if([string]$intent.root.path -cne $checkpoint.root_path -or [string]$intent.root.sha256 -cne $checkpoint.root_sha256 -or [string]$intent.receipt.path -cne $receiptRelative){throw 'root-tamper'}
        $rootPath=Get-HistoryArchivePath $workspace $checkpoint.root_path -RequireLeaf
        if((Get-HistoryArchiveFileHash $rootPath) -cne $checkpoint.root_sha256){throw 'root-tamper'}
        Assert-HistoryArchiveSchema $repositoryRoot $rootPath 'history-archive-root-v1.schema.json' 'History archive root'
        $root=Read-MorphospaceProtocolJson $rootPath
        if((Get-HistoryArchiveHash $root) -cne (Get-HistoryArchiveHash $intent.root.document) -or [string]$root.checkpoint_id -cne $checkpointId -or [string]$root.source_prefix.sha256 -cne [string]$state.history_archive.source_prefix_sha256 -or [long]$root.source_prefix.byte_length -ne [long]$state.history_archive.source_prefix_length){throw 'root-tamper'}
        $receiptPath=Get-HistoryArchivePath $workspace $receiptRelative -RequireLeaf
        if((Get-HistoryArchiveFileHash $receiptPath) -cne [string]$intent.receipt.sha256){throw 'archive-receipt-tamper'}
        Assert-HistoryArchiveSchema $repositoryRoot $receiptPath 'history-archive-checkpoint-v1.schema.json' 'History archive checkpoint receipt'
        if((Get-HistoryArchiveHash (Read-MorphospaceProtocolJson $receiptPath)) -cne (Get-HistoryArchiveHash $intent.receipt.document)){throw 'archive-receipt-document-tamper'}
        [void](Assert-HistoryArchiveCompletion $repositoryRoot (Get-HistoryArchivePath $workspace $completionRelative -RequireLeaf) $intentRelative $intentPath $intent)
        $sourcePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($object in @($root.objects)){
            if(-not $sourcePaths.Add([string]$object.source_path)){throw 'object-tamper'}
            $objectPath=Get-HistoryArchivePath $workspace ([string]$object.object_path) -RequireLeaf
            if((Get-HistoryArchiveFileHash $objectPath) -cne [string]$object.sha256 -or [long]([IO.FileInfo]$objectPath).Length -ne [long]$object.byte_length){throw 'object-tamper'}
        }
        $eventsPath=Get-HistoryArchivePath $workspace 'iteration-events.jsonl' -RequireLeaf;$events=[IO.File]::ReadAllBytes($eventsPath);$fullEvents=Get-HistoryArchiveEventPrefix -Bytes $events
        if($events.Length -lt [long]$root.source_prefix.byte_length){throw 'source-prefix-drift'}
        $prefix=[byte[]]::new([int]$root.source_prefix.byte_length);[Array]::Copy($events,0,$prefix,0,$prefix.Length)
        if((Get-MorphospaceSha256Bytes $prefix) -cne [string]$root.source_prefix.sha256){throw 'source-prefix-drift'}
        $tailEvents=@(Get-HistoryArchiveTailEvents $events ([long]$root.source_prefix.byte_length))
        if((Get-HistoryArchiveHash $tailEvents[0]) -cne (Get-HistoryArchiveHash $intent.event)){throw 'archive-event-missing'}
        if([string]$state.last_event_id -cne [string]$fullEvents.tail.event_id){throw 'state-tail-drift'}
        $postTailReferences=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        for($index=0;$index -lt $tailEvents.Count;$index++){
            $event=$tailEvents[$index];$references=@(if($index -eq 0){@($event.receipts|ForEach-Object{ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$_)})}else{@(Get-HistoryArchivePathReferences $event)})
            if($index -eq 0) {
                if($references.Count -ne 1 -or [string]$references[0] -cne $receiptRelative){throw 'archive-event-reference-tamper'}
                $checked.Add([string]$references[0])|Out-Null
                continue
            }
            foreach($reference in $references) {
                if(-not $postTailReferences.Add($reference) -and -not $sourcePaths.Contains($reference)){throw 'archive-tail-drift'}
                $referencePath=Get-HistoryArchivePath $workspace $reference -RequireLeaf
                if($sourcePaths.Contains($reference)){
                    $archived=@($root.objects|Where-Object{[string]$_.source_path -ceq $reference})
                    if($archived.Count -ne 1 -or (Get-HistoryArchiveFileHash $referencePath) -cne [string]$archived[0].sha256){throw 'unknown-precheckpoint-reference'}
                } else {
                    [void](Test-HistoryArchiveSourcePath $reference)
                    $checked.Add($reference)|Out-Null
                }
            }
        }
        $carry=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($reference in @($root.carry_forward)){if(-not $carry.Add([string]$reference.source_path)){throw 'carry-forward-drift'}}
        foreach($reference in @(Get-HistoryArchivePathReferences $state)) {
            $referencePath=Get-HistoryArchivePath $workspace $reference -RequireLeaf
            $match=@($root.carry_forward|Where-Object{[string]$_.source_path -ceq $reference})
            if($match.Count -eq 1) {
                if([string]$match[0].sha256 -cne (Get-HistoryArchiveFileHash $referencePath)){throw 'carry-forward-drift'}
            } elseif(-not $postTailReferences.Contains($reference)) { throw 'unknown-precheckpoint-reference' }
            $checked.Add($reference)|Out-Null
        }
        if($Tier -in @('deep','audit','migration')) {$mode='archive-replay';$status='pass';$codes=@('archive-replay-selected')}else{$mode='tail-only';$status='pass';$codes=@('none')}
        return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.history_archive_validation_result.v1';validation_id=$ValidationId;project_id=$state.project_id;tier=$Tier;mode=$mode;status=$status;checkpoint=$checkpoint;source_prefix=[pscustomobject]@{matches=$true;byte_length=[long]$root.source_prefix.byte_length;sha256=[string]$root.source_prefix.sha256};carry_forward=[pscustomobject]@{complete=$true;checked_paths=@($checked.ToArray())};reason_codes=$codes;does_not_prove=@('Does not substitute archive integrity for a selected historical aggregate.')}
    } catch {
        $reason=$_.Exception.Message
        if($reason -notin @('incomplete-transaction','unregistered-checkpoint','archive-event-missing','archive-event-tamper','archive-receipt-tamper','archive-receipt-document-tamper','archive-event-reference-tamper','archive-tail-drift','state-tail-drift','root-tamper','object-tamper','source-prefix-drift','carry-forward-drift','unknown-precheckpoint-reference')){$reason='unknown-precheckpoint-reference'}
        return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.history_archive_validation_result.v1';validation_id=$ValidationId;project_id=$state.project_id;tier=$Tier;mode='archive-replay-required';status='replay-required';checkpoint=$checkpoint;source_prefix=[pscustomobject]@{matches=$false;byte_length=if($state.PSObject.Properties.Name -contains 'history_archive' -and $null -ne $state.history_archive){[long]$state.history_archive.source_prefix_length}else{1};sha256=if($state.PSObject.Properties.Name -contains 'history_archive' -and $null -ne $state.history_archive){[string]$state.history_archive.source_prefix_sha256}else{('0'*64)}};carry_forward=[pscustomobject]@{complete=$false;checked_paths=@($checked.ToArray())};reason_codes=@($reason);does_not_prove=@('Does not treat an incomplete, damaged, or unresolved archive transaction as a passing Quick result.')}
    }
}
Export-ModuleMember -Function Invoke-MorphospaceArchiveHistoryCheckpoint, Test-MorphospaceHistoryArchive
