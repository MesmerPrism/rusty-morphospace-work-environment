Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force

function Copy-ActiveWriteScopeDocument {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Get-ActiveWriteScopeCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -cmatch '\\') { throw "Write-scope paths must use forward slashes: '$Path'." }
    $directory = $Path.EndsWith('/')
    $body = if ($directory) { $Path.TrimEnd('/') } else { $Path }
    $normalized = ConvertTo-MorphospaceProtocolRelativePath $body
    $canonical = if ($directory) { "$normalized/" } else { $normalized }
    if ($canonical -cne $Path) { throw "Write-scope path is not canonical: '$Path'." }
    return $canonical
}

function Assert-ActiveWriteScopePathSet {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Paths,
        [Parameter(Mandatory)][string]$Name
    )
    $canonical = @($Paths | ForEach-Object { Get-ActiveWriteScopeCanonicalPath ([string]$_) })
    $folded = @($canonical | ForEach-Object { $_.ToLowerInvariant() })
    if (@($folded | Sort-Object -Unique).Count -ne $folded.Count) { throw "$Name contains duplicate or case-fold duplicate paths." }
    return $canonical
}

function Get-ActiveWriteScopePathSetHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Paths)
    return Get-MorphospaceCanonicalJsonSha256 ([pscustomobject][ordered]@{ allowed_paths = @($Paths) })
}

function Test-ActiveWriteScopePathAllowed {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object[]]$AllowedPaths)
    $candidate = (Get-ActiveWriteScopeCanonicalPath $Path).TrimEnd('/')
    foreach ($raw in @($AllowedPaths)) {
        $allowed = (Get-ActiveWriteScopeCanonicalPath ([string]$raw)).TrimEnd('/')
        if ($candidate.Equals($allowed,[StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($allowed + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Read-ActiveWriteScopeEvents {
    param([Parameter(Mandatory)][string]$Path)
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line)
            $events.Add((ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'iteration event ledger entry')) | Out-Null
        } catch { throw 'Iteration event ledger contains malformed JSON.' }
    }
    if ($events.Count -eq 0) { throw 'AmendActiveWriteScope requires a non-empty iteration event ledger.' }
    return @($events.ToArray())
}

function Assert-ActiveWriteScopeProtocolDocument {
    param([Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][object]$Document,[Parameter(Mandatory)][string]$RepositoryRoot)
    $schemaName = switch ([string]$Document.schema) {
        'rusty.morphospace.workflow.project_spec.v2' { 'project-spec-v2.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v2' { 'workspace-state-v2.schema.json' }
        'rusty.morphospace.workflow.iteration_unit.v1' { 'iteration-unit.schema.json' }
        'rusty.morphospace.workflow.iteration_event.v1' { 'iteration-event.schema.json' }
        'rusty.morphospace.workflow.iteration_event.v2' { 'iteration-event-v2.schema.json' }
        default { throw "Unsupported workflow document schema for ${Label}: $([string]$Document.schema)" }
    }
    if (-not (Test-Json -Json ($Document | ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $RepositoryRoot "schemas\$schemaName"))) {
        throw "Workflow document '$Label' does not satisfy '$schemaName'."
    }
}

function Invoke-MorphospaceAmendActiveWriteScope {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$ActiveWriteScopeAmendment,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedActiveWriteScopeAmendmentSha256 = '',
        [string]$Timestamp = '',
        [scriptblock]$BeforeTransitionHook,
        [switch]$Execute
    )

    $repoRoot = Split-Path $PSScriptRoot -Parent
    $workspace = (Resolve-Path $WorkspaceRoot).Path
    $amendmentPath = (Resolve-Path $ActiveWriteScopeAmendment).Path
    $amendmentSchema = Join-Path $repoRoot 'schemas\active-write-scope-amendment-v1.schema.json'
    $amendmentRaw = Get-Content -Raw -LiteralPath $amendmentPath
    if (-not (Test-Json -Json $amendmentRaw -SchemaFile $amendmentSchema)) { throw 'Active write-scope amendment does not satisfy its schema.' }
    $amendment = Read-MorphospaceProtocolJson $amendmentPath
    if ([string]$amendment.unit_id -cne $UnitId -or [string]$amendment.expected.current_unit -cne $UnitId) {
        throw 'Amendment identity and expected current unit must exactly match UnitId.'
    }

    $projectRelative = 'project.spec.json'
    $stateRelative = 'workspace.state.json'
    $unitRelative = "iteration-units/$UnitId.json"
    $eventsRelative = 'iteration-events.jsonl'
    $projectPath = Resolve-MorphospaceWorkspacePath $workspace $projectRelative -RequireLeaf
    $statePath = Resolve-MorphospaceWorkspacePath $workspace $stateRelative -RequireLeaf
    $unitPath = Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace $eventsRelative -RequireLeaf
    $project = Read-MorphospaceProtocolJson $projectPath
    $state = Read-MorphospaceProtocolJson $statePath
    $unit = Read-MorphospaceProtocolJson $unitPath
    $events = @(Read-ActiveWriteScopeEvents $eventsPath)

    foreach ($document in @(
        [pscustomobject]@{label='project';value=$project},
        [pscustomobject]@{label='state';value=$state},
        [pscustomobject]@{label='unit';value=$unit}
    )) { Assert-ActiveWriteScopeProtocolDocument $document.label $document.value $repoRoot }
    for ($eventIndex = 0; $eventIndex -lt $events.Count; $eventIndex++) {
        $ledgerEvent = $events[$eventIndex]
        if ([string]$ledgerEvent.schema -ceq 'rusty.morphospace.workflow.iteration_event.v2') {
            if ($eventIndex -ne 0) {
                throw "Iteration event ledger contains a v2 event outside the historical bootstrap position at line $($eventIndex + 1)."
            }
            if ([string]$ledgerEvent.previous_event_sha256 -cne ('0' * 64)) {
                throw 'Iteration event ledger historical v2 bootstrap does not use the zero predecessor.'
            }
        }
        Assert-ActiveWriteScopeProtocolDocument 'event' $ledgerEvent $repoRoot
    }

    if ([string]$project.schema -cne 'rusty.morphospace.workflow.project_spec.v2' -or
        [string]$state.schema -cne 'rusty.morphospace.workflow.workspace_state.v2') {
        throw 'AmendActiveWriteScope requires project_spec.v2 and workspace_state.v2.'
    }
    $workMode = if ($unit.PSObject.Properties.Name -contains 'work_mode') { [string]$unit.work_mode } else { 'feature' }
    if ([string]$amendment.project_id -cne [string]$project.project_id -or
        [string]$state.project_id -cne [string]$project.project_id -or
        [string]$unit.project_id -cne [string]$project.project_id -or
        [string]$unit.unit_id -cne $UnitId -or
        [string]$state.current_unit -cne $UnitId -or
        [string]$unit.status -cne 'active' -or $workMode -cne 'feature') {
        throw 'AmendActiveWriteScope requires the exact current active feature unit.'
    }

    $projectHash = Get-MorphospaceCanonicalJsonSha256 $project
    $stateHash = Get-MorphospaceCanonicalJsonSha256 $state
    $unitHash = Get-MorphospaceCanonicalJsonSha256 $unit
    $eventsHash = Get-MorphospaceFileSha256 $eventsPath
    $eventsLength = [IO.FileInfo]::new($eventsPath).Length
    $tailId = [string]$events[-1].event_id
    if ([string]$state.last_event_id -cne $tailId) { throw 'Workspace last_event_id does not match the iteration event tail.' }
    foreach ($binding in @(
        [pscustomobject]@{name='project SHA-256';expected=[string]$amendment.expected.project_sha256;actual=$projectHash},
        [pscustomobject]@{name='state SHA-256';expected=[string]$amendment.expected.state_sha256;actual=$stateHash},
        [pscustomobject]@{name='unit SHA-256';expected=[string]$amendment.expected.unit_sha256;actual=$unitHash},
        [pscustomobject]@{name='event-ledger SHA-256';expected=[string]$amendment.expected.events_sha256;actual=$eventsHash},
        [pscustomobject]@{name='event tail';expected=[string]$amendment.expected.event_tail_id;actual=$tailId}
    )) {
        if ([string]$binding.expected -cne [string]$binding.actual) { throw "Amendment expected $([string]$binding.name) does not match the current workspace." }
    }
    if ([int]$amendment.expected.project_revision -ne [int]$project.revision) { throw 'Amendment expected project revision does not match the current workspace.' }
    if ([int64]$amendment.expected.events_length -ne $eventsLength) { throw 'Amendment expected event-ledger byte length does not match the current workspace.' }

    $projectMatches = @($project.repositories | Where-Object { [string]$_.repo_id -ceq [string]$amendment.repository_id })
    $unitMatches = @($unit.allowed_repositories | Where-Object { [string]$_.repo_id -ceq [string]$amendment.repository_id })
    if ($projectMatches.Count -ne 1 -or $unitMatches.Count -gt 1) { throw 'Amendment repository must occur exactly once in project scope and at most once in active-unit write scope.' }
    $before = @(Assert-ActiveWriteScopePathSet -Paths @($amendment.before_allowed_paths) -Name 'Amendment before paths')
    $after = @(Assert-ActiveWriteScopePathSet -Paths @($amendment.after_allowed_paths) -Name 'Amendment after paths')
    $actualBefore = [Collections.Generic.List[string]]::new()
    if ($unitMatches.Count -eq 1) {
        foreach ($path in @(Assert-ActiveWriteScopePathSet -Paths @($unitMatches[0].allowed_paths) -Name 'Active-unit repository paths')) {
            $actualBefore.Add($path) | Out-Null
        }
    }
    if ((Get-ActiveWriteScopePathSetHash -Paths $actualBefore) -cne (Get-ActiveWriteScopePathSetHash -Paths $before)) { throw 'Amendment before paths do not exactly match the active unit.' }
    if ($after.Count -le $before.Count) { throw 'Amendment must add at least one write path.' }
    $afterSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $after) { [void]$afterSet.Add($path) }
    foreach ($path in $before) { if (-not $afterSet.Contains($path)) { throw "Amendment may not remove existing active-unit path '$path'." } }
    foreach ($path in $after) {
        if (-not (Test-ActiveWriteScopePathAllowed $path @($projectMatches[0].allowed_paths))) {
            throw "Amended write path '$path' is outside project repository scope."
        }
    }

    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    if (-not (Test-MorphospaceStrictUtcTimestamp $Timestamp)) { throw 'Timestamp must be a strict UTC timestamp.' }
    $eventId = "$([string]$amendment.amendment_id)-recorded"
    $targetUnit = Copy-ActiveWriteScopeDocument $unit
    $targetMatches = @($targetUnit.allowed_repositories | Where-Object { [string]$_.repo_id -ceq [string]$amendment.repository_id })
    if ($targetMatches.Count -eq 1) {
        $targetMatches[0].allowed_paths = @(Copy-ActiveWriteScopeDocument $after)
    } else {
        $addedRepository = [pscustomobject][ordered]@{
            repo_id = [string]$amendment.repository_id
            allowed_paths = @(Copy-ActiveWriteScopeDocument $after)
        }
        $targetUnit.allowed_repositories = @(@($targetUnit.allowed_repositories) + $addedRepository | Sort-Object repo_id)
    }
    $targetState = Copy-ActiveWriteScopeDocument $state
    $targetState.last_event_id = $eventId
    $event = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'
        event_id = $eventId
        sequence = [int]$events[-1].sequence + 1
        timestamp = $Timestamp
        project_id = [string]$amendment.project_id
        unit_id = $UnitId
        event_type = 'state-transition'
        summary = "Added only project-approved paths to active feature-unit write scope '$([string]$amendment.repository_id)' while retaining the same captain and status."
        receipts = @()
    }

    $amendmentHash = Get-MorphospaceFileSha256 $amendmentPath
    if ($ExpectedActiveWriteScopeAmendmentSha256 -and $ExpectedActiveWriteScopeAmendmentSha256 -cne $amendmentHash) { throw 'ExpectedActiveWriteScopeAmendmentSha256 does not match the amendment input.' }
    if ($Execute -and -not $ExpectedActiveWriteScopeAmendmentSha256) { throw 'Executed AmendActiveWriteScope requires ExpectedActiveWriteScopeAmendmentSha256 from the dry run.' }
    $outAbsolute = [IO.Path]::GetFullPath($OutPath)
    $workspacePrefix = $workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $outAbsolute.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Amendment output must stay inside the project workspace.' }
    Assert-MorphospaceNoReparseAncestor -Root $workspace -Candidate $outAbsolute
    $outRelative = $outAbsolute.Substring($workspacePrefix.Length).Replace('\','/')
    $expectedOutRelative = "receipts/$([string]$amendment.amendment_id).json"
    if ($outRelative -cne $expectedOutRelative) { throw "Amendment output must be '$expectedOutRelative'." }
    if ([IO.File]::Exists($outAbsolute)) { throw 'Amendment output already exists.' }
    if ([IO.Path]::GetFullPath($amendmentPath) -ceq $outAbsolute) { throw 'Amendment input and transaction-owned output must be distinct.' }
    $event.receipts = @($outRelative)

    foreach ($document in @(
        [pscustomobject]@{label='target state';value=$targetState},
        [pscustomobject]@{label='target unit';value=$targetUnit},
        [pscustomobject]@{label='event';value=$event}
    )) { Assert-ActiveWriteScopeProtocolDocument $document.label $document.value $repoRoot }
    if ((Get-MorphospaceCanonicalJsonSha256 $project) -cne $projectHash) { throw 'Amendment must not change the project document.' }

    if ($Execute) {
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" `
            -StatePath $stateRelative -UnitPath $unitRelative -EventsPath $eventsRelative `
            -TargetState $targetState -TargetUnit $targetUnit -Event $event `
            -ExpectedStateSha256 $stateHash -ExpectedUnitSha256 $unitHash `
            -ExpectedEventTailId $tailId -ExpectedEventsSha256 $eventsHash -ExpectedEventsLength $eventsLength `
            -AdditionalProjections @([pscustomobject]@{path=$projectRelative;expected_sha256=$projectHash;document=$project}) `
            -Artifacts @([pscustomobject]@{source_path=$amendmentPath;path=$outRelative;sha256=$amendmentHash}) | Out-Null
    }

    $result = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id = [string]$amendment.project_id
        unit_id = $UnitId
        action = 'AmendActiveWriteScope'
        timestamp = $Timestamp
        executed = $Execute.IsPresent
        transition = 'active-write-scope-amended'
        status_before = [string]$unit.status
        status_after = [string]$targetUnit.status
        current_unit_before = $state.current_unit
        current_unit_after = $targetState.current_unit
        preservation = [pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt = [pscustomobject][ordered]@{path=$outRelative;sha256=$amendmentHash}
        event_id = $(if ($Execute) { $eventId } else { $null })
    }
    $resultSchema = Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile $resultSchema)) { throw 'AmendActiveWriteScope emitted an invalid automation receipt.' }
    return $result
}

Export-ModuleMember -Function Invoke-MorphospaceAmendActiveWriteScope
