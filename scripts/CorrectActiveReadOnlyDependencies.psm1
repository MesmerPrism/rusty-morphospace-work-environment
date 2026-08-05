Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force

function Copy-ActiveReadOnlyDependencyDocument {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Invoke-ActiveReadOnlyDependencyGit {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Repository @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0) { throw "CorrectActiveReadOnlyDependencies Git observation failed: git $($Arguments -join ' ')" }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-ActiveReadOnlyDependencyVerification {
    param([Parameter(Mandatory)][object]$Identity)
    return "Exact Git revision $([string]$Identity.revision) with tree $([string]$Identity.tree); role $([string]$Identity.role)."
}

function Get-ActiveReadOnlyDependencySetHash {
    param([AllowEmptyCollection()][object[]]$Dependencies)
    return Get-MorphospaceCanonicalJsonSha256 ([pscustomobject][ordered]@{ read_only_dependencies = @($Dependencies) })
}

function Get-ActiveReadOnlyDependencyCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -cmatch '\\') { throw "Read-only dependency paths must use forward slashes: '$Path'." }
    $directory = $Path.EndsWith('/')
    $body = if ($directory) { $Path.TrimEnd('/') } else { $Path }
    $normalized = ConvertTo-MorphospaceProtocolRelativePath $body
    $canonical = if ($directory) { "$normalized/" } else { $normalized }
    if ($canonical -cne $Path) { throw "Read-only dependency path is not canonical: '$Path'." }
    return $canonical
}

function Test-ActiveReadOnlyDependencyPathAllowed {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object[]]$AllowedPaths)
    $candidate = (Get-ActiveReadOnlyDependencyCanonicalPath $Path).TrimEnd('/')
    foreach ($raw in @($AllowedPaths)) {
        $allowedRaw = ([string]$raw).Replace('\','/').TrimEnd('/')
        $allowed = ConvertTo-MorphospaceProtocolRelativePath $allowedRaw
        if ($candidate.Equals($allowed,[StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($allowed + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Assert-ActiveReadOnlyDependencyOrdering {
    param([Parameter(Mandatory)][object[]]$Dependencies,[Parameter(Mandatory)][string]$Name)
    $ids = @($Dependencies | ForEach-Object { [string]$_.repo_id })
    $folded = @($ids | ForEach-Object { $_.ToLowerInvariant() })
    if (@($folded | Sort-Object -Unique).Count -ne $folded.Count) { throw "$Name contains duplicate or case-fold duplicate repository IDs." }
    if (($ids -join '|') -cne (@($ids | Sort-Object -CaseSensitive) -join '|')) { throw "$Name must be ordered by repo_id." }
    foreach ($dependency in @($Dependencies)) {
        $paths = @($dependency.paths | ForEach-Object { Get-ActiveReadOnlyDependencyCanonicalPath ([string]$_) })
        $pathFolded = @($paths | ForEach-Object { $_.ToLowerInvariant() })
        if (@($pathFolded | Sort-Object -Unique).Count -ne $pathFolded.Count) { throw "$Name contains duplicate or case-fold duplicate paths for '$($dependency.repo_id)'." }
    }
}

function Read-ActiveReadOnlyDependencyEvents {
    param([Parameter(Mandatory)][string]$Path)
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events.Add(($line | ConvertFrom-Json)) | Out-Null } catch { throw 'Iteration event ledger contains malformed JSON.' }
    }
    if ($events.Count -eq 0) { throw 'CorrectActiveReadOnlyDependencies requires a non-empty iteration event ledger.' }
    return @($events.ToArray())
}

function Assert-ActiveReadOnlyDependencyProtocolDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    $schemaName = switch ([string]$Document.schema) {
        'rusty.morphospace.workflow.project_spec.v1' { 'project-spec.schema.json' }
        'rusty.morphospace.workflow.project_spec.v2' { 'project-spec-v2.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v1' { 'workspace-state.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v2' { 'workspace-state-v2.schema.json' }
        'rusty.morphospace.workflow.iteration_unit.v1' { 'iteration-unit.schema.json' }
        'rusty.morphospace.workflow.iteration_event.v1' { 'iteration-event.schema.json' }
        default { throw "Unsupported workflow document schema: $([string]$Document.schema)" }
    }
    $json = if ([IO.File]::Exists($Path)) { Get-Content -Raw -LiteralPath $Path } else { $Document | ConvertTo-Json -Depth 64 }
    if (-not (Test-Json -Json $json -SchemaFile (Join-Path $RepositoryRoot "schemas\$schemaName"))) {
        throw "Workflow document does not satisfy '$schemaName': $Path"
    }
}

function Assert-ActiveReadOnlyDependencyGitIdentities {
    param([Parameter(Mandatory)][object[]]$Identities,[Parameter(Mandatory)][hashtable]$RepositoryMap)
    foreach ($identity in @($Identities)) {
        $repoId = [string]$identity.repo_id
        if (-not $RepositoryMap.ContainsKey($repoId)) { throw "Exact read-only dependency repository '$repoId' is not mapped." }
        $entry = $RepositoryMap[$repoId]
        if ([string]$entry.role -cne 'source') { throw "Exact read-only dependency repository '$repoId' must be mapped as source." }
        $root = (Resolve-Path ([string]$entry.path)).Path
        if ((Invoke-ActiveReadOnlyDependencyGit $root @('rev-parse','--is-inside-work-tree')) -cne 'true') { throw "Mapped read-only dependency '$repoId' is not a Git worktree." }
        $resolved = Invoke-ActiveReadOnlyDependencyGit $root @('rev-parse','--verify',"$([string]$identity.revision)^{commit}")
        if ($resolved -cne [string]$identity.revision) { throw "Read-only dependency revision identity mismatch for '$repoId'." }
        $tree = Invoke-ActiveReadOnlyDependencyGit $root @('rev-parse','--verify',"$([string]$identity.revision)^{tree}")
        if ($tree -cne [string]$identity.tree) { throw "Read-only dependency tree identity mismatch for '$repoId'." }
    }
}

function Invoke-MorphospaceCorrectActiveReadOnlyDependencies {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$ReadOnlyDependencyCorrection,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedReadOnlyDependencyCorrectionSha256 = '',
        [string]$Timestamp = '',
        [scriptblock]$BeforeTransitionHook,
        [switch]$Execute
    )

    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workspace = (Resolve-Path $WorkspaceRoot).Path
    $correctionPath = (Resolve-Path $ReadOnlyDependencyCorrection).Path
    $correctionSchema = Join-Path $repoRoot 'schemas\active-read-only-dependency-correction-v1.schema.json'
    $correctionRaw = Get-Content -Raw -LiteralPath $correctionPath
    if (-not (Test-Json -Json $correctionRaw -SchemaFile $correctionSchema)) { throw 'Read-only dependency correction does not satisfy its schema.' }
    $correction = Read-MorphospaceProtocolJson $correctionPath
    if ([string]$correction.unit_id -cne $UnitId -or [string]$correction.expected.current_unit -cne $UnitId) { throw 'Correction identity and expected current unit must exactly match UnitId.' }

    $projectPath = Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf
    $statePath = Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
    $unitRelative = "iteration-units/$UnitId.json"
    $unitPath = Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf
    $eventsRelative = 'iteration-events.jsonl'
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace $eventsRelative -RequireLeaf
    $project = Read-MorphospaceProtocolJson $projectPath
    $state = Read-MorphospaceProtocolJson $statePath
    $unit = Read-MorphospaceProtocolJson $unitPath
    $events = @(Read-ActiveReadOnlyDependencyEvents $eventsPath)

    if ([string]$correction.project_id -cne [string]$project.project_id -or
        [string]$state.project_id -cne [string]$project.project_id -or
        [string]$unit.project_id -cne [string]$project.project_id -or
        [string]$unit.unit_id -cne $UnitId -or
        [string]$state.current_unit -cne $UnitId -or
        [string]$unit.status -cne 'active') {
        throw 'CorrectActiveReadOnlyDependencies requires the exact current unit with status active.'
    }

    $stateHash = Get-MorphospaceCanonicalJsonSha256 $state
    $unitHash = Get-MorphospaceCanonicalJsonSha256 $unit
    $eventsHash = Get-MorphospaceFileSha256 $eventsPath
    $eventsLength = [IO.FileInfo]::new($eventsPath).Length
    $tailId = [string]$events[-1].event_id
    if ([string]$state.last_event_id -cne $tailId) { throw 'Workspace last_event_id does not match the iteration event tail.' }
    foreach ($binding in @(
        [pscustomobject]@{name='state SHA-256';expected=[string]$correction.expected.state_sha256;actual=$stateHash},
        [pscustomobject]@{name='unit SHA-256';expected=[string]$correction.expected.unit_sha256;actual=$unitHash},
        [pscustomobject]@{name='event-ledger SHA-256';expected=[string]$correction.expected.events_sha256;actual=$eventsHash},
        [pscustomobject]@{name='event tail';expected=[string]$correction.expected.event_tail_id;actual=$tailId}
    )) {
        if ([string]$binding.expected -cne [string]$binding.actual) { throw "Correction expected $([string]$binding.name) does not match the current workspace." }
    }
    if ([int64]$correction.expected.events_length -ne $eventsLength) { throw 'Correction expected event-ledger byte length does not match the current workspace.' }

    $currentDependencies = if ($unit.PSObject.Properties.Name -contains 'read_only_dependencies') { @($unit.read_only_dependencies) } else { @() }
    Assert-ActiveReadOnlyDependencyOrdering -Dependencies @($correction.before) -Name 'Correction before dependencies'
    Assert-ActiveReadOnlyDependencyOrdering -Dependencies @($correction.after) -Name 'Correction after dependencies'
    if ((Get-ActiveReadOnlyDependencySetHash -Dependencies $currentDependencies) -cne (Get-ActiveReadOnlyDependencySetHash -Dependencies @($correction.before))) {
        throw 'Correction before dependencies do not exactly match the active unit.'
    }

    $beforeById = @{}
    foreach ($dependency in @($correction.before)) { $beforeById[[string]$dependency.repo_id] = $dependency }
    $afterById = @{}
    foreach ($dependency in @($correction.after)) { $afterById[[string]$dependency.repo_id] = $dependency }
    foreach ($repoId in @($beforeById.Keys)) {
        if (-not $afterById.ContainsKey($repoId)) { throw "Correction may not remove existing read-only dependency '$repoId'." }
        $before = $beforeById[$repoId]
        $after = $afterById[$repoId]
        if ((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{paths=@($before.paths);purpose=[string]$before.purpose})) -cne
            (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{paths=@($after.paths);purpose=[string]$after.purpose}))) {
            throw "Correction may change only verification for existing read-only dependency '$repoId'."
        }
    }

    $identityIds = @($correction.repository_identities | ForEach-Object { [string]$_.repo_id })
    $identityFolded = @($identityIds | ForEach-Object { $_.ToLowerInvariant() })
    if (@($identityFolded | Sort-Object -Unique).Count -ne $identityFolded.Count) { throw 'Correction repository_identities contains duplicate or case-fold duplicate IDs.' }
    if (($identityIds -join '|') -cne (@($identityIds | Sort-Object -CaseSensitive) -join '|')) { throw 'Correction repository_identities must be ordered by repo_id.' }
    $afterIds = @($correction.after | ForEach-Object { [string]$_.repo_id })
    if (($identityIds -join '|') -cne ($afterIds -join '|')) { throw 'Correction repository_identities must exactly cover the resulting read-only dependencies.' }

    $projectById = @{}
    foreach ($entry in @($project.repositories)) {
        $key = [string]$entry.repo_id
        if ($projectById.ContainsKey($key)) { throw 'Project specification contains duplicate repository IDs.' }
        $projectById[$key] = $entry
    }
    $writeIds = @($unit.allowed_repositories | ForEach-Object { [string]$_.repo_id })
    for ($index = 0; $index -lt @($correction.after).Count; $index++) {
        $dependency = @($correction.after)[$index]
        $identity = @($correction.repository_identities)[$index]
        $repoId = [string]$dependency.repo_id
        if (-not $projectById.ContainsKey($repoId)) { throw "Read-only dependency '$repoId' is not declared by the project specification." }
        if ($writeIds -ccontains $repoId) { throw "Repository '$repoId' may not be both writable and a read-only dependency." }
        foreach ($path in @($dependency.paths)) {
            if (-not (Test-ActiveReadOnlyDependencyPathAllowed -Path ([string]$path) -AllowedPaths @($projectById[$repoId].allowed_paths))) {
                throw "Read-only dependency path '${repoId}:$path' is outside the project specification."
            }
        }
        $requiredVerification = Get-ActiveReadOnlyDependencyVerification $identity
        if ([string]$dependency.verification -cne $requiredVerification) { throw "Read-only dependency '$repoId' does not use the canonical exact identity verification." }
    }

    $mapSchema = Join-Path $repoRoot 'schemas\repository-map.schema.json'
    $mapRaw = Get-Content -Raw -LiteralPath (Resolve-Path $RepoMapPath)
    if (-not (Test-Json -Json $mapRaw -SchemaFile $mapSchema)) { throw 'Repository map does not satisfy its schema.' }
    $mapDocument = Read-MorphospaceProtocolJson (Resolve-Path $RepoMapPath)
    $repositoryMap = @{}
    $mapFolded = @{}
    foreach ($entry in @($mapDocument.repositories)) {
        $repoId = [string]$entry.repo_id
        $folded = $repoId.ToLowerInvariant()
        if ($mapFolded.ContainsKey($folded)) { throw 'Repository map contains duplicate or case-fold duplicate IDs.' }
        $mapFolded[$folded] = $true
        $repositoryMap[$repoId] = $entry
    }
    Assert-ActiveReadOnlyDependencyGitIdentities -Identities @($correction.repository_identities) -RepositoryMap $repositoryMap

    $correctionHash = Get-MorphospaceFileSha256 $correctionPath
    if ($ExpectedReadOnlyDependencyCorrectionSha256 -and $ExpectedReadOnlyDependencyCorrectionSha256 -cne $correctionHash) {
        throw 'ExpectedReadOnlyDependencyCorrectionSha256 does not match the correction input.'
    }
    if ($Execute -and -not $ExpectedReadOnlyDependencyCorrectionSha256) {
        throw 'Executed CorrectActiveReadOnlyDependencies requires ExpectedReadOnlyDependencyCorrectionSha256 from the dry run.'
    }

    $outAbsolute = [IO.Path]::GetFullPath($OutPath)
    $workspacePrefix = $workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $outAbsolute.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Correction output must stay inside the project workspace.' }
    Assert-MorphospaceNoReparseAncestor -Root $workspace -Candidate $outAbsolute
    $outRelative = $outAbsolute.Substring($workspacePrefix.Length).Replace('\','/')
    $expectedOutRelative = "receipts/$([string]$correction.correction_id).json"
    if ($outRelative -cne $expectedOutRelative) { throw "Correction output must be '$expectedOutRelative'." }
    if ([IO.File]::Exists($outAbsolute)) { throw 'Correction output already exists.' }
    if ([IO.Path]::GetFullPath($correctionPath) -ceq $outAbsolute) { throw 'Correction input and transaction-owned output must be distinct.' }

    $targetUnit = Copy-ActiveReadOnlyDependencyDocument $unit
    if ($targetUnit.PSObject.Properties.Name -contains 'read_only_dependencies') {
        $targetUnit.read_only_dependencies = @(Copy-ActiveReadOnlyDependencyDocument @($correction.after))
    } else {
        $targetUnit | Add-Member -NotePropertyName read_only_dependencies -NotePropertyValue @(Copy-ActiveReadOnlyDependencyDocument @($correction.after))
    }
    $targetState = Copy-ActiveReadOnlyDependencyDocument $state
    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    if (-not (Test-MorphospaceStrictUtcTimestamp $Timestamp)) { throw 'Timestamp must be a strict UTC timestamp.' }
    $eventId = "$([string]$correction.correction_id)-recorded"
    $event = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = $eventId
        sequence = [int]$events[-1].sequence + 1
        timestamp = $Timestamp
        project_id = [string]$correction.project_id
        unit_id = $UnitId
        event_type = 'state-transition'
        summary = 'Corrected only the current active unit read-only dependency declaration using exact project scope, Git object identities, and compare-and-swap bindings.'
        receipts = @($outRelative)
    }
    $targetState.last_event_id = $eventId
    Assert-ActiveReadOnlyDependencyProtocolDocument '<event>' $event $repoRoot

    if ($Execute) {
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        Assert-ActiveReadOnlyDependencyGitIdentities -Identities @($correction.repository_identities) -RepositoryMap $repositoryMap
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" `
            -StatePath 'workspace.state.json' -UnitPath $unitRelative -EventsPath $eventsRelative `
            -TargetState $targetState -TargetUnit $targetUnit -Event $event `
            -ExpectedStateSha256 $stateHash -ExpectedUnitSha256 $unitHash `
            -ExpectedEventTailId $tailId -ExpectedEventsSha256 $eventsHash -ExpectedEventsLength $eventsLength `
            -Artifacts @([pscustomobject]@{source_path=$correctionPath;path=$outRelative;sha256=$correctionHash}) | Out-Null
    }

    $result = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id = [string]$correction.project_id
        unit_id = $UnitId
        action = 'CorrectActiveReadOnlyDependencies'
        timestamp = $Timestamp
        executed = $Execute.IsPresent
        transition = 'active-read-only-dependencies-corrected'
        status_before = [string]$unit.status
        status_after = [string]$targetUnit.status
        current_unit_before = $state.current_unit
        current_unit_after = $targetState.current_unit
        preservation = [pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt = [pscustomobject][ordered]@{path=$outRelative;sha256=$correctionHash}
        event_id = $(if ($Execute) { $eventId } else { $null })
    }
    $resultSchema = Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile $resultSchema)) { throw 'CorrectActiveReadOnlyDependencies emitted an invalid automation receipt.' }
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceCorrectActiveReadOnlyDependencies
