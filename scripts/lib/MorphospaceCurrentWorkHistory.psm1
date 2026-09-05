Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')

# A read-only lifecycle projection, not a new receipt or recovery mechanism.
# Earlier records cannot grant current authority merely by being classified here.
function Get-MorphospaceCurrentWorkHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [switch]$RequireIdle)
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $state = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
    $archive = $null
    $archiveTransactions = Join-Path $workspace 'history-archive/transactions'
    if (($state.PSObject.Properties.Name -contains 'history_archive' -and $null -ne $state.history_archive) -or
        ([IO.Directory]::Exists($archiveTransactions) -and @(Get-ChildItem -LiteralPath $archiveTransactions -File).Count -gt 0)) {
        Import-Module (Join-Path $PSScriptRoot 'MorphospaceHistoryArchive.psm1')
        $archive = Test-MorphospaceHistoryArchive -WorkspaceRoot $workspace -Tier quick
        if ([string]$archive.status -cne 'pass') { throw 'Current-work archive checkpoint is incomplete or unauthenticated.' }
    }
    if ($RequireIdle) {
        if ($null -ne $state.current_unit -or $null -ne $state.next_ready_unit -or
            ($state.PSObject.Properties.Name -contains 'blockers' -and @($state.blockers).Count -gt 0) -or
            ($state.PSObject.Properties.Name -contains 'pending_push_bundle' -and $null -ne $state.pending_push_bundle)) {
            throw 'Current-work preparation requires idle ownership without blockers or pending publication.'
        }
    }
    $units = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $workspace 'iteration-units') -Filter '*.json' -File)) {
        $unit = Read-MorphospaceProtocolJson $file.FullName
        $id = [string]$unit.unit_id
        if ($id -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$' -or $units.ContainsKey($id) -or
            [string]$unit.project_id -cne [string]$state.project_id -or
            [IO.Path]::GetFullPath($file.FullName) -cne (Resolve-MorphospaceWorkspacePath $workspace "iteration-units/$id.json")) {
            throw 'Current-work history contains a damaged, repeated or noncanonical unit identity.'
        }
        $units[$id] = $unit
    }
    $eventsPath = Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    $events = @(Get-Content -LiteralPath $eventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
    $eventIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $events.Count; $index++) {
        $event = $events[$index]
        if (-not $eventIds.Add([string]$event.event_id) -or [int]$event.sequence -ne $index + 1 -or
            [string]$event.project_id -cne [string]$state.project_id) { throw 'Current-work event identity or sequence is damaged.' }
    }
    if ($events.Count -eq 0 -or [string]$events[-1].event_id -cne [string]$state.last_event_id) { throw 'Current-work state does not match its ledger tail.' }
    $historical = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $retired = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $accepts = @($events | Where-Object {
        [string]$_.event_type -ceq 'state-transition' -and
        [string]$_.event_id -cmatch ('^' + [regex]::Escape([string]$_.unit_id) + '-accepted-[0-9]{4,}$') -and
        @($_.receipts) -ccontains [string]$state.last_accepted_receipt
    })
    # A workspace without an authenticated checkpoint receives no history exemption.
    if ($accepts.Count -eq 0) {
        foreach ($pending in @(Get-ChildItem -LiteralPath (Join-Path $workspace 'receipts/transactions') -Filter '*.intent.json' -File -ErrorAction SilentlyContinue)) {
            if (-not [IO.File]::Exists(($pending.FullName -creplace '\.intent\.json$','.completion.json'))) { throw 'Current-work has an incomplete transaction without an authenticated historical boundary.' }
        }
        return [pscustomobject]@{ authenticated=$false; sequence=0; historical_ids=$historical; retired_ids=$retired; units=$units; events=$events; audit_only=@() }
    }
    if ($accepts.Count -ne 1) { throw 'Current-work accepted checkpoint is ambiguous.' }
    $acceptedEvent = $accepts[0]
    $acceptedId = [string]$acceptedEvent.unit_id
    if (-not $units.ContainsKey($acceptedId)) { throw 'Current-work accepted checkpoint unit is missing.' }
    $accepted = Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId "$($acceptedEvent.event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$acceptedId.json" -ExpectedEventsPath 'iteration-events.jsonl'
    if ([string]$accepted.intent.target.unit.document.status -cne 'accepted' -or
        [string]$accepted.intent.target.unit.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $units[$acceptedId]) -or
        $null -ne $accepted.intent.target.state.document.current_unit -or
        [string]$accepted.intent.target.state.document.last_accepted_receipt -cne [string]$state.last_accepted_receipt) {
        throw 'Current-work accepted checkpoint does not authenticate the retained endpoint.'
    }
    $sequence = [int]$acceptedEvent.sequence
    $priorStateHash = [string]$accepted.intent.target.state.sha256
    $projectionHashes = @{}
    $audit = [Collections.Generic.List[object]]::new()
    # Existing owner transactions fence all changes after the accepted boundary.
    foreach ($event in @($events | Where-Object { [int]$_.sequence -gt $sequence })) {
        $id = "$($event.event_id)-transition"
        $authenticatedArchiveStep = $false
        $intentPath = Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$id.intent.json"
        if (-not [IO.File]::Exists($intentPath) -and $state.PSObject.Properties.Name -contains 'history_archive' -and $null -ne $state.history_archive) {
            # Archive checkpoints have their own existing transaction namespace.
            if ($null -eq $archive -or [string]$archive.status -cne 'pass') { throw 'Current-work archive checkpoint is not authenticated.' }
            $intentPath = Resolve-MorphospaceWorkspacePath $workspace "history-archive/transactions/$($archive.checkpoint.checkpoint_id)-archive-transition.intent.json" -RequireLeaf
            $intent = Read-MorphospaceProtocolJson $intentPath
            if ((Get-MorphospaceCanonicalJsonSha256 $intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $event)) { throw 'Current-work archive event is detached.' }
            $authenticatedArchiveStep = $true
        } else {
            $intent = Read-MorphospaceProtocolJson $intentPath
        }
        if ([string]$intent.schema -ceq 'rusty.morphospace.workflow.development_envelope_preparation_intent.v1') {
            Assert-CurrentWorkPreparationStep $workspace $intentPath $intent $events $event
            foreach ($name in @('project','feature_lock')) {
                $path = [string]$intent.target.$name.path
                if ($projectionHashes.ContainsKey($path) -and [string]$intent.pre.$name.sha256 -cne $projectionHashes[$path]) { throw 'Current-work preparation projection preimage is detached.' }
                $projectionHashes[$path] = [string]$intent.target.$name.sha256
            }
        } elseif (-not $authenticatedArchiveStep) {
            $step = Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $id -ExpectedStatePath 'workspace.state.json' -ExpectedEventsPath 'iteration-events.jsonl'
            $intent = $step.intent
            if ($intent.PSObject.Properties.Name -contains 'additional_projections') {
                foreach ($projection in $intent.additional_projections) {
                    $path = [string]$projection.path
                    if ($projectionHashes.ContainsKey($path) -and [string]$projection.pre_sha256 -cne $projectionHashes[$path]) { throw 'Current-work additional projection preimage is detached.' }
                    $projectionHashes[$path] = [string]$projection.target_sha256
                }
            }
        }
        if ([string]$intent.pre.state.sha256 -cne $priorStateHash) {
            throw 'Current-work transaction suffix has a detached state preimage.'
        }
        $priorStateHash = [string]$intent.target.state.sha256
    }
    if ($priorStateHash -cne (Get-MorphospaceCanonicalJsonSha256 $state)) { throw 'Current-work transaction suffix does not derive the live state.' }
    foreach ($path in $projectionHashes.Keys) {
        if ((Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $path -RequireLeaf))) -cne $projectionHashes[$path]) {
            throw "Current-work live projection '$path' differs from its latest transaction."
        }
    }
    foreach ($pending in @(Get-ChildItem -LiteralPath (Join-Path $workspace 'receipts/transactions') -Filter '*.intent.json' -File)) {
        $completionPath = $pending.FullName -creplace '\.intent\.json$','.completion.json'
        if ([IO.File]::Exists($completionPath)) { continue }
        $intent = Read-MorphospaceProtocolJson $pending.FullName
        $sealed = @($events | Where-Object { [string]$_.event_id -ceq [string]$intent.event.event_id -and [int]$_.sequence -lt $sequence })
        if ($sealed.Count -ne 1 -or $pending.Name -cne "$($sealed[0].event_id)-transition.intent.json" -or
            [string]$intent.transaction_id -cne "$($sealed[0].event_id)-transition" -or
            (Get-MorphospaceCanonicalJsonSha256 $intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $sealed[0]) -or
            [string]$intent.pre.state.sha256 -ceq $priorStateHash -or [string]$intent.target.state.sha256 -ceq $priorStateHash) {
            throw 'Current-work has an incomplete or unmatched current transaction.'
        }
        $audit.Add([pscustomobject]@{transaction_id=$intent.transaction_id; classification='sealed-incomplete-history'; current_policy_revalidated=$false; grants_validation_credit=$false})
    }
    $edges = @{}
    foreach ($event in $events) {
        if (-not ([string]$event.event_id).Contains('-superseded-by-', [StringComparison]::Ordinal)) { continue }
        $old = [string]$event.unit_id
        if (-not $units.ContainsKey($old)) { throw 'Current-work supersession names an absent old unit.' }
        $matches = @($units.Keys | Where-Object { $_ -cne $old -and [string]$event.event_id -ceq (Get-MorphospaceSupersessionEventId -OldUnitId $old -ReplacementUnitId $_) })
        if ($matches.Count -ne 1 -or $edges.ContainsKey($old) -or [string]$event.event_type -cne 'state-transition') { throw 'Current-work supersession is orphaned or ambiguous.' }
        $edges[$old] = [pscustomobject]@{ replacement=[string]$matches[0]; sequence=[int]$event.sequence }
    }
    foreach ($id in $units.Keys) {
        if ([string]$units[$id].status -ceq 'accepted') {
            $terminal = @($events | Where-Object { [int]$_.sequence -le $sequence -and [string]$_.unit_id -ceq $id -and [string]$_.event_id -cmatch ('^'+[regex]::Escape($id)+'-accepted-[0-9]{4,}$') })
            if ($terminal.Count -eq 1) { [void]$historical.Add($id) }
            continue
        }
        if (@('active','validating') -cnotcontains [string]$units[$id].status -or -not $edges.ContainsKey($id)) { continue }
        $cursor = [string]$id
        $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $previousSequence = 0
        while ([string]$units[$cursor].status -cne 'accepted') {
            if (-not $visited.Add($cursor) -or -not $edges.ContainsKey($cursor)) { throw 'Current-work supersession chain is cyclic or incomplete.' }
            $edge = $edges[$cursor]
            if ($edge.sequence -le $previousSequence -or $edge.sequence -gt $sequence) { break }
            $previousSequence = $edge.sequence
            $cursor = [string]$edge.replacement
        }
        if ([string]$units[$cursor].status -cne 'accepted' -or $previousSequence -eq 0) { continue }
        $terminal = @($events | Where-Object { [string]$_.unit_id -ceq $cursor -and [int]$_.sequence -gt $previousSequence -and [int]$_.sequence -le $sequence -and [string]$_.event_id -cmatch ('^'+[regex]::Escape($cursor)+'-accepted-[0-9]{4,}$') })
        if ($terminal.Count -ne 1) { throw 'Current-work retired chain lacks an accepted endpoint in the sealed prefix.' }
        [void]$historical.Add($id); [void]$retired.Add($id)
    }
    foreach ($id in @($historical)) {
        if ([string]$state.current_unit -ceq $id -or [string]$state.next_ready_unit -ceq $id -or
            @($events | Where-Object { [int]$_.sequence -gt $sequence -and [string]$_.unit_id -ceq $id -and [string]$_.event_id -cmatch '-(claimed|active|ready|validating)-' }).Count -gt 0) {
            throw 'Current-work history cannot hide a resurrected historical owner.'
        }
        $audit.Add([pscustomobject]@{unit_id=$id; classification=$(if($retired.Contains($id)){'retired'}else{'accepted-history'}); current_policy_revalidated=$false; grants_validation_credit=$false})
    }
    # Historical prerequisite evidence remains an actual dependency, even
    # though its old instruction vocabulary is not reinterpreted.
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $units.Keys) {
        if ($historical.Contains($id) -or $units[$id].PSObject.Properties.Name -notcontains 'prerequisites') { continue }
        foreach ($dependency in $units[$id].prerequisites) { [void]$required.Add([string]$dependency) }
    }
    foreach ($id in $required) {
        if (-not $units.ContainsKey($id) -or [string]$units[$id].status -cne 'accepted') { throw "Current-work prerequisite '$id' is not accepted." }
        $terminal = @($events | Where-Object { [string]$_.unit_id -ceq $id -and [string]$_.event_id -cmatch ('^'+[regex]::Escape($id)+'-accepted-[0-9]{4,}$') })
        if ($terminal.Count -ne 1) { throw "Current-work prerequisite '$id' has no unique accepted evidence." }
        $proof = Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId "$($terminal[0].event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$id.json" -ExpectedEventsPath 'iteration-events.jsonl'
        if ([string]$proof.intent.target.unit.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $units[$id]) -or [string]$proof.intent.target.unit.document.status -cne 'accepted') { throw "Current-work prerequisite '$id' differs from accepted evidence." }
    }
    return [pscustomobject]@{ authenticated=$true; sequence=$sequence; accepted_unit_id=$acceptedId; historical_ids=$historical; retired_ids=$retired; units=$units; events=$events; audit_only=@($audit.ToArray()) }
}

function Assert-CurrentWorkPreparationStep {
    param([string]$Workspace,[string]$IntentPath,[object]$Intent,[object[]]$Events,[object]$ExpectedEvent)
    $repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $completionPath = Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($Intent.transaction_id).completion.json" -RequireLeaf
    foreach ($pair in @(@($IntentPath,'development-envelope-preparation-intent-v1.schema.json'),@($completionPath,'development-envelope-preparation-completion-v1.schema.json'))) {
        if (-not (Test-Json -Json (Get-Content -LiteralPath $pair[0] -Raw) -SchemaFile (Join-Path $repository "schemas/$($pair[1])"))) { throw 'Current-work preparation suffix schema is invalid.' }
    }
    $completion = Read-MorphospaceProtocolJson $completionPath
    if ([string]$Intent.transaction_id -cne "$($ExpectedEvent.event_id)-transition" -or
        [IO.Path]::GetFullPath($IntentPath) -cne (Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($ExpectedEvent.event_id)-transition.intent.json") -or
        (Get-MorphospaceCanonicalJsonSha256 $Intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $ExpectedEvent)) { throw 'Current-work preparation transaction identity is detached.' }
    if ([string]$completion.intent_sha256 -cne (Get-MorphospaceFileSha256 $IntentPath) -or [string]$completion.transaction_id -cne [string]$Intent.transaction_id -or [string]$completion.event_id -cne [string]$Intent.event.event_id) { throw 'Current-work preparation completion is detached.' }
    if ((Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at)) -lt (Test-MorphospaceStrictUtcTimestamp ([string]$Intent.created_at))) { throw 'Current-work preparation completion predates its intent.' }
    foreach ($name in @('project','state','feature_lock')) {
        $canonicalPath = switch ($name) { 'project' {'project.spec.json'} 'state' {'workspace.state.json'} 'feature_lock' {'feature.lock.json'} }
        if ([string]$Intent.pre.$name.path -cne $canonicalPath -or [string]$Intent.target.$name.path -cne $canonicalPath -or
            (Get-MorphospaceCanonicalJsonSha256 $Intent.pre.$name.document) -cne [string]$Intent.pre.$name.sha256) { throw 'Current-work preparation projection path or preimage is detached.' }
        if ([string]$completion."target_$($name)_sha256" -cne [string]$Intent.target.$name.sha256 -or (Get-MorphospaceCanonicalJsonSha256 $Intent.target.$name.document) -cne [string]$Intent.target.$name.sha256) { throw 'Current-work preparation target is damaged.' }
    }
    $predecessorPath = "iteration-units/$($Intent.event.unit_id).json"
    if ([string]$Intent.pre.predecessor_unit.path -cne $predecessorPath -or [string]$Intent.target.predecessor_unit.path -cne $predecessorPath -or
        [string]$Intent.pre.predecessor_unit.sha256 -cne [string]$Intent.target.predecessor_unit.sha256 -or
        (Get-MorphospaceCanonicalJsonSha256 $Intent.pre.predecessor_unit.document) -cne [string]$Intent.pre.predecessor_unit.sha256 -or
        (Get-MorphospaceCanonicalJsonSha256 $Intent.target.predecessor_unit.document) -cne [string]$Intent.pre.predecessor_unit.sha256 -or
        (Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace $predecessorPath -RequireLeaf))) -cne [string]$Intent.pre.predecessor_unit.sha256 -or
        [string]$Intent.pre.events.path -cne 'iteration-events.jsonl' -or [string]$Intent.target.events.path -cne 'iteration-events.jsonl') { throw 'Current-work preparation predecessor or ledger path is detached.' }
    foreach ($artifact in $Intent.artifacts) {
        $path = Resolve-MorphospaceWorkspacePath $Workspace ([string]$artifact.path) -RequireLeaf
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [string]$artifact.bytes_base64 -or (Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $path)) -cne [string]$artifact.sha256) { throw 'Current-work preparation artifact is damaged.' }
    }
    $row = @($Events | Where-Object { [string]$_.event_id -ceq [string]$Intent.event.event_id })
    if ($row.Count -ne 1 -or (Get-MorphospaceCanonicalJsonSha256 $row[0]) -cne (Get-MorphospaceCanonicalJsonSha256 $Intent.event)) { throw 'Current-work preparation event is detached.' }
    $bytes = [IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl'))
    $lineCount = 0; $offset = 0
    while ($offset -lt $bytes.Length -and $lineCount -lt [int]$Intent.event.sequence - 1) {
        if ($bytes[$offset] -eq 10) { $lineCount++ }; $offset++
    }
    if ($lineCount -ne [int]$Intent.event.sequence - 1) { throw 'Current-work preparation ledger prefix is incomplete.' }
    $prefix = [byte[]]::new($offset); [Array]::Copy($bytes,0,$prefix,0,$offset)
    if ((Get-MorphospaceSha256Bytes $prefix) -cne [string]$Intent.pre.events.sha256) { throw 'Current-work preparation ledger prefix is detached.' }
}

Export-ModuleMember -Function Get-MorphospaceCurrentWorkHistory
