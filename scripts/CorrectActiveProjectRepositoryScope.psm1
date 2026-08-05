Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force

function Copy-ActiveProjectScopeDocument {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Get-ActiveProjectScopeCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -cmatch '\\') { throw "Project repository paths must use forward slashes: '$Path'." }
    $directory = $Path.EndsWith('/')
    $body = if ($directory) { $Path.TrimEnd('/') } else { $Path }
    $normalized = ConvertTo-MorphospaceProtocolRelativePath $body
    $canonical = if ($directory) { "$normalized/" } else { $normalized }
    if ($canonical -cne $Path) { throw "Project repository path is not canonical: '$Path'." }
    return $canonical
}

function Assert-ActiveProjectScopePathSet {
    param([Parameter(Mandatory)][object[]]$Paths,[Parameter(Mandatory)][string]$Name)
    $canonical = @($Paths | ForEach-Object { Get-ActiveProjectScopeCanonicalPath ([string]$_) })
    $folded = @($canonical | ForEach-Object { $_.ToLowerInvariant() })
    if (@($folded | Sort-Object -Unique).Count -ne $folded.Count) { throw "$Name contains duplicate or case-fold duplicate paths." }
    return $canonical
}

function Test-ActiveProjectScopePathAllowed {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object[]]$AllowedPaths)
    $candidate = (Get-ActiveProjectScopeCanonicalPath $Path).TrimEnd('/')
    foreach ($raw in @($AllowedPaths)) {
        $allowed = (Get-ActiveProjectScopeCanonicalPath ([string]$raw)).TrimEnd('/')
        if ($candidate.Equals($allowed,[StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($allowed + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-ActiveProjectScopePathSetHash {
    param([Parameter(Mandatory)][object[]]$Paths)
    return Get-MorphospaceCanonicalJsonSha256 ([pscustomobject][ordered]@{ allowed_paths = @($Paths) })
}

function Get-ActiveProjectScopeFeatureLockFingerprint {
    param([Parameter(Mandatory)][object]$Lock)
    $copy = Copy-ActiveProjectScopeDocument $Lock
    $copy.lock_fingerprint = '0' * 64
    $json = $copy | ConvertTo-Json -Depth 48 -Compress
    return Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Read-ActiveProjectScopeEvents {
    param([Parameter(Mandatory)][string]$Path)
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events.Add(($line | ConvertFrom-Json)) | Out-Null } catch { throw 'Iteration event ledger contains malformed JSON.' }
    }
    if ($events.Count -eq 0) { throw 'CorrectActiveProjectRepositoryScope requires a non-empty iteration event ledger.' }
    return @($events.ToArray())
}

function Assert-ActiveProjectScopeProtocolDocument {
    param([Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][object]$Document,[Parameter(Mandatory)][string]$RepositoryRoot)
    $schemaName = switch ([string]$Document.schema) {
        'rusty.morphospace.workflow.project_spec.v2' { 'project-spec-v2.schema.json' }
        'rusty.morphospace.workflow.feature_lock.v2' { 'feature-lock-v2.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v2' { 'workspace-state-v2.schema.json' }
        'rusty.morphospace.workflow.iteration_unit.v1' { 'iteration-unit.schema.json' }
        'rusty.morphospace.workflow.iteration_event.v1' { 'iteration-event.schema.json' }
        default { throw "Unsupported workflow document schema for ${Label}: $([string]$Document.schema)" }
    }
    if (-not (Test-Json -Json ($Document | ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $RepositoryRoot "schemas\$schemaName"))) {
        throw "Workflow document '$Label' does not satisfy '$schemaName'."
    }
}

function Invoke-MorphospaceCorrectActiveProjectRepositoryScope {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$ProjectRepositoryScopeCorrection,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedProjectRepositoryScopeCorrectionSha256 = '',
        [string]$Timestamp = '',
        [scriptblock]$BeforeTransitionHook,
        [switch]$Execute
    )

    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workspace = (Resolve-Path $WorkspaceRoot).Path
    $correctionPath = (Resolve-Path $ProjectRepositoryScopeCorrection).Path
    $correctionSchema = Join-Path $repoRoot 'schemas\active-project-repository-scope-correction-v1.schema.json'
    $correctionRaw = Get-Content -Raw -LiteralPath $correctionPath
    if (-not (Test-Json -Json $correctionRaw -SchemaFile $correctionSchema)) { throw 'Project repository scope correction does not satisfy its schema.' }
    $correction = Read-MorphospaceProtocolJson $correctionPath
    if ([string]$correction.unit_id -cne $UnitId -or [string]$correction.expected.current_unit -cne $UnitId) {
        throw 'Correction identity and expected current unit must exactly match UnitId.'
    }

    $projectRelative = 'project.spec.json'
    $lockRelative = 'feature.lock.json'
    $stateRelative = 'workspace.state.json'
    $unitRelative = "iteration-units/$UnitId.json"
    $eventsRelative = 'iteration-events.jsonl'
    $projectPath = Resolve-MorphospaceWorkspacePath $workspace $projectRelative -RequireLeaf
    $lockPath = Resolve-MorphospaceWorkspacePath $workspace $lockRelative -RequireLeaf
    $statePath = Resolve-MorphospaceWorkspacePath $workspace $stateRelative -RequireLeaf
    $unitPath = Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace $eventsRelative -RequireLeaf
    $project = Read-MorphospaceProtocolJson $projectPath
    $lock = Read-MorphospaceProtocolJson $lockPath
    $state = Read-MorphospaceProtocolJson $statePath
    $unit = Read-MorphospaceProtocolJson $unitPath
    $events = @(Read-ActiveProjectScopeEvents $eventsPath)

    if ([string]$project.schema -cne 'rusty.morphospace.workflow.project_spec.v2' -or
        [string]$lock.schema -cne 'rusty.morphospace.workflow.feature_lock.v2' -or
        [string]$state.schema -cne 'rusty.morphospace.workflow.workspace_state.v2') {
        throw 'CorrectActiveProjectRepositoryScope requires project_spec.v2, feature_lock.v2, and workspace_state.v2.'
    }
    if ([string]$correction.project_id -cne [string]$project.project_id -or
        [string]$lock.project_id -cne [string]$project.project_id -or
        [string]$state.project_id -cne [string]$project.project_id -or
        [string]$unit.project_id -cne [string]$project.project_id -or
        [string]$unit.unit_id -cne $UnitId -or
        [string]$state.current_unit -cne $UnitId -or
        [string]$unit.status -cne 'active') {
        throw 'CorrectActiveProjectRepositoryScope requires the exact current unit with status active.'
    }

    $projectHash = Get-MorphospaceCanonicalJsonSha256 $project
    $lockHash = Get-MorphospaceCanonicalJsonSha256 $lock
    $stateHash = Get-MorphospaceCanonicalJsonSha256 $state
    $unitHash = Get-MorphospaceCanonicalJsonSha256 $unit
    $eventsHash = Get-MorphospaceFileSha256 $eventsPath
    $eventsLength = [IO.FileInfo]::new($eventsPath).Length
    $tailId = [string]$events[-1].event_id
    if ([string]$state.last_event_id -cne $tailId) { throw 'Workspace last_event_id does not match the iteration event tail.' }
    foreach ($binding in @(
        [pscustomobject]@{name='project SHA-256';expected=[string]$correction.expected.project_sha256;actual=$projectHash},
        [pscustomobject]@{name='feature-lock SHA-256';expected=[string]$correction.expected.feature_lock_sha256;actual=$lockHash},
        [pscustomobject]@{name='state SHA-256';expected=[string]$correction.expected.state_sha256;actual=$stateHash},
        [pscustomobject]@{name='unit SHA-256';expected=[string]$correction.expected.unit_sha256;actual=$unitHash},
        [pscustomobject]@{name='event-ledger SHA-256';expected=[string]$correction.expected.events_sha256;actual=$eventsHash},
        [pscustomobject]@{name='event tail';expected=[string]$correction.expected.event_tail_id;actual=$tailId}
    )) {
        if ([string]$binding.expected -cne [string]$binding.actual) { throw "Correction expected $([string]$binding.name) does not match the current workspace." }
    }
    if ([int64]$correction.expected.events_length -ne $eventsLength) { throw 'Correction expected event-ledger byte length does not match the current workspace.' }
    foreach ($revision in @(
        [pscustomobject]@{name='project revision';expected=[int]$correction.expected.project_revision;actual=[int]$project.revision},
        [pscustomobject]@{name='feature-lock revision';expected=[int]$correction.expected.feature_lock_revision;actual=[int]$lock.revision},
        [pscustomobject]@{name='plan revision';expected=[int]$correction.expected.plan_revision;actual=[int]$state.plan_revision}
    )) {
        if ($revision.expected -ne $revision.actual) { throw "Correction expected $([string]$revision.name) does not match the current workspace." }
    }
    if ([int]$lock.project_revision -ne [int]$project.revision -or
        [int]$state.module_registry.lock_revision -ne [int]$lock.revision -or
        [string]$state.module_registry.lock_fingerprint -cne [string]$lock.lock_fingerprint -or
        (Get-ActiveProjectScopeFeatureLockFingerprint $lock) -cne [string]$lock.lock_fingerprint) {
        throw 'Current project, feature lock, and module registry are not mutually consistent.'
    }

    $projectMatches = @($project.repositories | Where-Object { [string]$_.repo_id -ceq [string]$correction.repository_id })
    $unitMatches = @($unit.allowed_repositories | Where-Object { [string]$_.repo_id -ceq [string]$correction.repository_id })
    if ($projectMatches.Count -ne 1 -or $unitMatches.Count -ne 1) { throw 'Correction repository must occur exactly once in both project and active-unit write scope.' }
    $before = @(Assert-ActiveProjectScopePathSet @($correction.before_allowed_paths) 'Correction before paths')
    $after = @(Assert-ActiveProjectScopePathSet @($correction.after_allowed_paths) 'Correction after paths')
    if ((Get-ActiveProjectScopePathSetHash @($projectMatches[0].allowed_paths)) -cne (Get-ActiveProjectScopePathSetHash $before)) {
        throw 'Correction before paths do not exactly match the project repository scope.'
    }
    if ($after.Count -le $before.Count) { throw 'Correction must add at least one project repository path.' }
    $afterSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $after) { [void]$afterSet.Add($path) }
    foreach ($path in $before) { if (-not $afterSet.Contains($path)) { throw "Correction may not remove existing project repository path '$path'." } }
    $beforeSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $before) { [void]$beforeSet.Add($path) }
    $unitPaths = @(Assert-ActiveProjectScopePathSet @($unitMatches[0].allowed_paths) 'Active-unit repository paths')
    $unitSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $unitPaths) { [void]$unitSet.Add($path) }
    foreach ($path in $after) {
        if (-not $beforeSet.Contains($path) -and -not $unitSet.Contains($path)) {
            throw "Added project repository path '$path' is not an exact path already declared by the active unit."
        }
    }
    foreach ($path in $unitPaths) {
        if (-not (Test-ActiveProjectScopePathAllowed $path $after)) { throw "Corrected project scope still excludes active-unit path '$path'." }
    }

    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    if (-not (Test-MorphospaceStrictUtcTimestamp $Timestamp)) { throw 'Timestamp must be a strict UTC timestamp.' }
    $eventId = "$([string]$correction.correction_id)-recorded"
    $targetProject = Copy-ActiveProjectScopeDocument $project
    $targetProject.revision = [int]$project.revision + 1
    $targetProjectRepository = @($targetProject.repositories | Where-Object { [string]$_.repo_id -ceq [string]$correction.repository_id })[0]
    $targetProjectRepository.allowed_paths = @(Copy-ActiveProjectScopeDocument $after)
    $targetLock = Copy-ActiveProjectScopeDocument $lock
    $targetLock.project_revision = [int]$targetProject.revision
    $targetLock.revision = [int]$lock.revision + 1
    $targetLock.generated_at = $Timestamp
    $targetLock.lock_fingerprint = '0' * 64
    $targetLock = ConvertFrom-MorphospaceProtocolJsonBytes `
        -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $targetLock))) `
        -Context 'canonical target feature lock'
    $targetLock.lock_fingerprint = Get-ActiveProjectScopeFeatureLockFingerprint $targetLock
    $targetState = Copy-ActiveProjectScopeDocument $state
    $targetState.plan_revision = [int]$state.plan_revision + 1
    $targetState.last_event_id = $eventId
    $targetState.module_registry.lock_revision = [int]$targetLock.revision
    $targetState.module_registry.lock_fingerprint = [string]$targetLock.lock_fingerprint
    $targetUnit = Copy-ActiveProjectScopeDocument $unit
    $event = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = $eventId
        sequence = [int]$events[-1].sequence + 1
        timestamp = $Timestamp
        project_id = [string]$correction.project_id
        unit_id = $UnitId
        event_type = 'state-transition'
        summary = "Added only active-unit-declared paths to project repository scope '$([string]$correction.repository_id)' and transactionally synchronized the project revision, feature lock, and workspace registry."
        receipts = @()
    }

    $correctionHash = Get-MorphospaceFileSha256 $correctionPath
    if ($ExpectedProjectRepositoryScopeCorrectionSha256 -and $ExpectedProjectRepositoryScopeCorrectionSha256 -cne $correctionHash) {
        throw 'ExpectedProjectRepositoryScopeCorrectionSha256 does not match the correction input.'
    }
    if ($Execute -and -not $ExpectedProjectRepositoryScopeCorrectionSha256) {
        throw 'Executed CorrectActiveProjectRepositoryScope requires ExpectedProjectRepositoryScopeCorrectionSha256 from the dry run.'
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
    $event.receipts = @($outRelative)

    foreach ($document in @(
        [pscustomobject]@{label='target project';value=$targetProject},
        [pscustomobject]@{label='target feature lock';value=$targetLock},
        [pscustomobject]@{label='target state';value=$targetState},
        [pscustomobject]@{label='event';value=$event}
    )) { Assert-ActiveProjectScopeProtocolDocument $document.label $document.value $repoRoot }
    if ((Get-MorphospaceCanonicalJsonSha256 $targetUnit) -cne $unitHash) { throw 'Correction must not change the active unit document.' }

    if ($Execute) {
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" `
            -StatePath $stateRelative -UnitPath $unitRelative -EventsPath $eventsRelative `
            -TargetState $targetState -TargetUnit $targetUnit -Event $event `
            -ExpectedStateSha256 $stateHash -ExpectedUnitSha256 $unitHash `
            -ExpectedEventTailId $tailId -ExpectedEventsSha256 $eventsHash -ExpectedEventsLength $eventsLength `
            -AdditionalProjections @(
                [pscustomobject]@{path=$lockRelative;expected_sha256=$lockHash;document=$targetLock},
                [pscustomobject]@{path=$projectRelative;expected_sha256=$projectHash;document=$targetProject}
            ) `
            -Artifacts @([pscustomobject]@{source_path=$correctionPath;path=$outRelative;sha256=$correctionHash}) | Out-Null
    }

    $result = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id = [string]$correction.project_id
        unit_id = $UnitId
        action = 'CorrectActiveProjectRepositoryScope'
        timestamp = $Timestamp
        executed = $Execute.IsPresent
        transition = 'active-project-repository-scope-corrected'
        status_before = [string]$unit.status
        status_after = [string]$targetUnit.status
        current_unit_before = $state.current_unit
        current_unit_after = $targetState.current_unit
        preservation = [pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt = [pscustomobject][ordered]@{path=$outRelative;sha256=$correctionHash}
        event_id = $(if ($Execute) { $eventId } else { $null })
    }
    $resultSchema = Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile $resultSchema)) { throw 'CorrectActiveProjectRepositoryScope emitted an invalid automation receipt.' }
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceCorrectActiveProjectRepositoryScope
