Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceCurrentWorkCompatibility.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceDevelopmentEnvelopeSemantics.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceSourceCompositionIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceLegacyToolingReclassification.psm1')
Import-Module (Join-Path $PSScriptRoot '../AcceptedValidationEvidenceRelocation.psm1')

# A read-only lifecycle projection, not a new receipt or recovery mechanism.
# Earlier records cannot grant current authority merely by being classified here.
function Get-MorphospaceAuthenticatedSupersededScopeConflicts {
    param(
        [string]$Workspace,
        [object]$State,
        [hashtable]$Units,
        [object[]]$Events,
        [int]$AcceptedSequence,
        [hashtable]$SuffixTransitions
    )
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($AcceptedSequence -le 0 -or -not [string]$State.current_unit -or -not $Units.ContainsKey([string]$State.current_unit) -or
        @('active','validating') -cnotcontains [string]$Units[[string]$State.current_unit].status) {
        return [pscustomobject]@{ ids=$ids }
    }
    $repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $delimiter = '-superseded-by-'
    $edges = @{}
    foreach ($event in @($Events | Where-Object { [int]$_.sequence -gt $AcceptedSequence -and ([string]$_.event_id).Contains($delimiter,[StringComparison]::Ordinal) })) {
        $oldId = [string]$event.unit_id
        $matches = @($Units.Keys | Where-Object { $_ -cne $oldId -and [string]$event.event_id -ceq (Get-MorphospaceSupersessionEventId -OldUnitId $oldId -ReplacementUnitId $_) })
        if ($matches.Count -ne 1 -or $edges.ContainsKey($oldId) -or -not $SuffixTransitions.ContainsKey([string]$event.event_id)) { continue }
        $replacementId = [string]$matches[0]
        $step = $SuffixTransitions[[string]$event.event_id]
        $intent = $step.intent
        if ([string]$intent.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v2' -or
            [string]$intent.event.event_id -cne [string]$event.event_id -or
            (Get-MorphospaceCanonicalJsonSha256 $intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $event) -or
            @($event.receipts).Count -ne 1 -or @($intent.artifacts).Count -ne 1 -or
            [string]$event.receipts[0] -cne [string]$intent.artifacts[0].path -or
            [string]$intent.supersession.old_unit_id -cne $oldId -or [string]$intent.supersession.new_unit_id -cne $replacementId -or
            [string]$intent.supersession.old_unit.path -cne "iteration-units/$oldId.json" -or
            [string]$intent.supersession.target_unit_path -cne "iteration-units/$replacementId.json" -or
            [string]$intent.unit.path -cne "iteration-units/$replacementId.json" -or
            [string]$intent.supersession.pre_state.path -cne 'workspace.state.json' -or
            [string]$intent.supersession.pre_state.document.current_unit -cne $oldId -or
            [string]$intent.target.state.document.current_unit -cne $replacementId -or
            $null -ne $intent.target.state.document.next_ready_unit -or
            [string]$intent.target.state.document.last_event_id -cne [string]$event.event_id -or
            [string]$intent.target.unit.document.unit_id -cne $replacementId -or [string]$intent.target.unit.document.status -cne 'active') { continue }

        $oldPath = Resolve-MorphospaceWorkspacePath $Workspace "iteration-units/$oldId.json" -RequireLeaf
        if ([string]$intent.supersession.old_unit.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $Units[$oldId]) -or
            [string]$intent.supersession.old_unit.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $intent.supersession.old_unit.document) -or
            [string]$intent.pre.state.sha256 -cne [string]$intent.supersession.pre_state.sha256 -or
            [string]$intent.pre.state.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $intent.supersession.pre_state.document)) { continue }
        $expectedTargetState = $intent.supersession.pre_state.document | ConvertTo-Json -Depth 100 | ConvertFrom-Json -DateKind String
        $expectedTargetState.current_unit = $replacementId
        $expectedTargetState.next_ready_unit = $null
        $expectedTargetState.last_event_id = [string]$event.event_id
        if ((Get-MorphospaceCanonicalJsonSha256 $expectedTargetState) -cne [string]$intent.target.state.sha256 -or
            (Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document) -cne [string]$intent.target.state.sha256) { continue }

        $receiptPath = Resolve-MorphospaceWorkspacePath $Workspace ([string]$intent.artifacts[0].path) -RequireLeaf
        $receipt = Read-MorphospaceProtocolJson $receiptPath
        if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $receiptPath) -SchemaFile (Join-Path $repository 'schemas/work-unit-automation-receipt-v2.schema.json')) -or
            [string]$receipt.schema -cne 'rusty.morphospace.workflow.work_unit_automation_receipt.v2' -or [string]$receipt.action -cne 'SupersedeActive' -or
            -not [bool]$receipt.executed -or [string]$receipt.transition -cne 'active-superseded-by-proposed-to-active' -or
            [string]$receipt.project_id -cne [string]$State.project_id -or [string]$receipt.unit_id -cne $replacementId -or
            [string]$receipt.event_id -cne [string]$event.event_id -or [string]$receipt.current_unit_before -cne $oldId -or
            [string]$receipt.current_unit_after -cne $replacementId -or [string]$receipt.status_before -cne 'proposed' -or [string]$receipt.status_after -cne 'active' -or
            [string]$receipt.timestamp -cne [string]$event.timestamp -or
            [bool]$receipt.preservation.git_mutation_performed -or [bool]$receipt.preservation.device_mutation_performed -or [bool]$receipt.preservation.remote_mutation_performed) { continue }
        $requestPath = Resolve-MorphospaceWorkspacePath $Workspace ([string]$receipt.audit_receipt.path) -RequireLeaf
        if ((Get-MorphospaceFileSha256 $requestPath) -cne [string]$receipt.audit_receipt.sha256 -or
            -not (Test-Json -Json (Get-Content -Raw -LiteralPath $requestPath) -SchemaFile (Join-Path $repository 'schemas/active-unit-supersession-v1.schema.json'))) { continue }
        $request = Read-MorphospaceProtocolJson $requestPath
        $targetPreimage = $intent.target.unit.document | ConvertTo-Json -Depth 100 | ConvertFrom-Json -DateKind String
        $targetPreimage.status = 'proposed'
        if ([string]$request.supersession_id -cne [string]$event.event_id -or [string]$request.project_id -cne [string]$State.project_id -or
            [string]$request.old_unit.unit_id -cne $oldId -or [string]$request.old_unit.path -cne "iteration-units/$oldId.json" -or
            [string]$request.old_unit.status -cne 'active' -or [string]$request.old_unit.raw_sha256 -cne (Get-MorphospaceFileSha256 $oldPath) -or
            [string]$request.old_unit.canonical_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $Units[$oldId]) -or
            [string]$request.replacement_unit.unit_id -cne $replacementId -or [string]$request.replacement_unit.path -cne "iteration-units/$replacementId.json" -or
            [string]$request.replacement_unit.status -cne 'proposed' -or [string]$request.replacement_unit.canonical_sha256 -cne [string]$intent.pre.unit.sha256 -or
            (Get-MorphospaceCanonicalJsonSha256 $targetPreimage) -cne [string]$intent.pre.unit.sha256 -or
            [string]$request.expected.state_canonical_sha256 -cne [string]$intent.pre.state.sha256 -or
            [string]$request.expected.events_sha256 -cne [string]$intent.expected.events_sha256 -or
            [int64]$request.expected.events_length -ne [int64]$intent.expected.events_length -or
            [string]$request.expected.event_tail_id -cne [string]$intent.expected.event_tail_id) { continue }
        $resurrected = @($Events | Where-Object {
            [int]$_.sequence -gt [int]$event.sequence -and [string]$_.unit_id -ceq $oldId -and
            [string]$_.event_id -cmatch '-(?:ready|claimed|active|validating|resumed)(?:-|$)'
        }).Count -ne 0
        if (-not $resurrected) {
            foreach ($later in @($Events | Where-Object { [int]$_.sequence -gt [int]$event.sequence })) {
                if ($SuffixTransitions.ContainsKey([string]$later.event_id) -and [string]$SuffixTransitions[[string]$later.event_id].intent.target.state.document.current_unit -ceq $oldId) {
                    $resurrected = $true; break
                }
            }
        }
        if ($resurrected) { continue }
        $edges[$oldId] = [pscustomobject]@{ replacement=$replacementId; sequence=[int]$event.sequence }
    }

    $prerequisites = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($unit in $Units.Values) {
        if ($unit.PSObject.Properties.Name -contains 'prerequisites') { foreach ($id in @($unit.prerequisites)) { [void]$prerequisites.Add([string]$id) } }
    }
    $incomingCounts = @{}
    foreach ($edge in $edges.Values) {
        $replacementId = [string]$edge.replacement
        if (-not $incomingCounts.ContainsKey($replacementId)) { $incomingCounts[$replacementId] = 0 }
        $incomingCounts[$replacementId] = [int]$incomingCounts[$replacementId] + 1
    }
    foreach ($oldId in @($edges.Keys)) {
        if ([string]$State.current_unit -ceq $oldId -or [string]$State.next_ready_unit -ceq $oldId -or $prerequisites.Contains($oldId)) { continue }
        $cursor = $oldId
        $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $priorSequence = 0
        $ordered = $true
        while ($edges.ContainsKey($cursor) -and $visited.Add($cursor)) {
            $edge = $edges[$cursor]
            if ([int]$edge.sequence -le $priorSequence -or [int]$incomingCounts[[string]$edge.replacement] -ne 1) { $ordered = $false; break }
            $priorSequence = [int]$edge.sequence
            $cursor = [string]$edge.replacement
        }
        if ($ordered -and $cursor -ceq [string]$State.current_unit -and @('active','validating') -ccontains [string]$Units[$cursor].status) { [void]$ids.Add($oldId) }
    }
    return [pscustomobject]@{ ids=$ids }
}

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
    $historicallyRetiredProposed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $historicallyRetiredProposedSequences = @{}
    $retiredActive = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $activeRetirements = @{}
    $activeRetirementSteps = @{}
    $supersededScopeConflicts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
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
        return [pscustomobject]@{ authenticated=$false; sequence=0; historical_ids=$historical; retired_ids=$retired; historically_retired_proposed_ids=$historicallyRetiredProposed; retired_active_ids=$retiredActive; active_retirements=$activeRetirements; authenticated_superseded_scope_conflict_ids=$supersededScopeConflicts; units=$units; events=$events; audit_only=@() }
    }
    if ($accepts.Count -ne 1) { throw 'Current-work accepted checkpoint is ambiguous.' }
    $acceptedEvent = $accepts[0]
    $acceptedId = [string]$acceptedEvent.unit_id
    if (-not $units.ContainsKey($acceptedId)) { throw 'Current-work accepted checkpoint unit is missing.' }
    $accepted = Test-MorphospaceAcceptedCheckpointProof -WorkspaceRoot $workspace -ExpectedEvent $acceptedEvent -AllowFiniteHistoricalV1
    if ([string]$accepted.intent.target.unit.document.status -cne 'accepted' -or
        [string]$accepted.intent.target.unit.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $units[$acceptedId]) -or
        $null -ne $accepted.intent.target.state.document.current_unit -or
        [string]$accepted.intent.target.state.document.last_accepted_receipt -cne [string]$state.last_accepted_receipt) {
        throw 'Current-work accepted checkpoint does not authenticate the retained endpoint.'
    }
    $sequence = [int]$acceptedEvent.sequence
    $priorStateHash = [string]$accepted.intent.target.state.sha256
    $projectionHashes = @{}
    $suffixTransitions = @{}
    $audit = [Collections.Generic.List[object]]::new()
    # Retirement remains independently authenticated even after a later
    # acceptance seals its event. It never enters accepted history.
    foreach ($retirementEvent in @($events | Where-Object { [string]$_.event_id -cmatch '-active-retired$' })) {
        Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1')
        $proof = Test-MorphospaceHistoricalActiveUnitRetirement -WorkspaceRoot $workspace -ExpectedEvent $retirementEvent
        $retiredId = [string]$retirementEvent.unit_id
        if (-not $units.ContainsKey($retiredId) -or [string]$units[$retiredId].status -cne 'active' -or
            -not $retiredActive.Add($retiredId)) { throw 'Current-work active retirement has a missing, changed or ambiguous endpoint.' }
        if ([string]$state.current_unit -ceq $retiredId -or [string]$state.next_ready_unit -ceq $retiredId -or
            @($events | Where-Object { [int]$_.sequence -gt [int]$retirementEvent.sequence -and [string]$_.unit_id -ceq $retiredId -and [string]$_.event_type -ceq 'state-transition' }).Count -gt 0) {
            throw 'Current-work active retirement cannot hide a resurrected owner.'
        }
        $laterAdmissions = @($events | Where-Object { [int]$_.sequence -gt [int]$retirementEvent.sequence -and [string]$_.event_id -cmatch '-admitted$' } | Sort-Object sequence)
        if ($laterAdmissions.Count -gt 0 -and [string]$laterAdmissions[0].unit_id -cne [string]$proof.receipt.replacement_unit_id) {
            throw 'Current-work active retirement was followed by an unnamed replacement admission.'
        }
        $activeRetirements[$retiredId] = $proof
        $activeRetirementSteps[[string]$retirementEvent.event_id] = $proof
        $audit.Add([pscustomobject]@{unit_id=$retiredId; classification='retired-active'; current_policy_revalidated=$false; grants_validation_credit=$false})
    }
    foreach($retirementEvent in @($events|Where-Object{[int]$_.sequence-le$sequence-and[string]$_.event_type-ceq'state-transition'-and[string]$_.event_id-cmatch('^'+[regex]::Escape([string]$_.unit_id)+'-proposal-retired-[0-9]{4}$')})){
        $retiredId=[string]$retirementEvent.unit_id
        if(-not$units.ContainsKey($retiredId)-or[string]$units[$retiredId].status-cne'superseded'){throw 'Current-work accepted prefix contains a proposed-retirement endpoint without its immutable superseded unit.'}
        $retirementTransaction="$([string]$retirementEvent.event_id)-transition";$retirementStep=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $retirementTransaction -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$retiredId.json" -ExpectedEventsPath 'iteration-events.jsonl'
        [void](Test-MorphospaceHistoricalProposedRetirement -WorkspaceRoot $workspace -ExpectedEvent $retirementEvent -CommittedStep $retirementStep)
        if($historicallyRetiredProposedSequences.ContainsKey($retiredId)){throw 'Current-work proposed retirement identity is ambiguous.'};$historicallyRetiredProposedSequences[$retiredId]=[int]$retirementEvent.sequence;[void]$historicallyRetiredProposed.Add($retiredId)
    }
    $recoveryIndex = Get-MorphospaceAdmissionCompletionTimestampRecoveryIndex -WorkspaceRoot $workspace -ExpectedEvents $events -AfterSequence $sequence
    $recoveryByAdmissionEvent = $recoveryIndex.by_admission_event
    $recoveryByCorrectionEvent = $recoveryIndex.by_correction_event
    $preparationRecoveryByOriginal = @{}
    $preparationRecoveryByCorrection = @{}
    if (@($events | Where-Object { [string]$_.event_id -cmatch '^preparation-completion-timestamp-recovered-[0-9]{4,}$' }).Count -gt 0) {
        Import-Module (Join-Path $PSScriptRoot '../PreparationCompletionTimestampRecovery.psm1')
        $preparationRecoveryIndex = Get-MorphospacePreparationCompletionTimestampRecoveryIndex -WorkspaceRoot $workspace -ExpectedEvents $events
        $preparationRecoveryByOriginal = $preparationRecoveryIndex.by_preparation_event
        $preparationRecoveryByCorrection = $preparationRecoveryIndex.by_correction_event
    }
    # Existing owner transactions fence all changes after the accepted boundary.
    foreach ($event in @($events | Where-Object { [int]$_.sequence -gt $sequence })) {
        $id = "$($event.event_id)-transition"
        $step = $null
        $authenticatedArchiveStep = $false
        $intentPath = Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$id.intent.json"
        $specialStep = $null
        $eventReceipts = @($event.receipts)
        if ($activeRetirementSteps.ContainsKey([string]$event.event_id)) {
            $specialStep = $activeRetirementSteps[[string]$event.event_id]
            $intent = $specialStep.intent
        } elseif ($preparationRecoveryByCorrection.ContainsKey([string]$event.event_id)) {
            $specialStep = $preparationRecoveryByCorrection[[string]$event.event_id]
            $intent = $specialStep.intent
        } elseif ($recoveryByAdmissionEvent.ContainsKey([string]$event.event_id)) {
            $recovery = $recoveryByAdmissionEvent[[string]$event.event_id]
            $specialStep = [pscustomobject]@{ intent=$recovery.original_intent; completion=$recovery.malformed_completion; recovered_by=[string]$recovery.recovery_event.event_id }
            $intent = $specialStep.intent
        } elseif ($recoveryByCorrectionEvent.ContainsKey([string]$event.event_id)) {
            $specialStep = $recoveryByCorrectionEvent[[string]$event.event_id]
            $intent = $specialStep.intent
        }
        if ($null -eq $specialStep -and -not [IO.File]::Exists($intentPath) -and $eventReceipts.Count -eq 2) {
            $firstReceiptPath = Resolve-MorphospaceWorkspacePath $workspace ([string]$eventReceipts[0])
            if ([IO.File]::Exists($firstReceiptPath)) {
                $firstReceipt = Read-MorphospaceProtocolJson $firstReceiptPath
                if ([string]$firstReceipt.schema -ceq 'rusty.morphospace.workflow.development_envelope_repreparation_receipt.v1') {
                    $specialStep = Test-MorphospaceCommittedDevelopmentEnvelopeRepreparation -WorkspaceRoot $workspace -ExpectedEvent $event
                    $intent = $specialStep.intent
                    $intentPath = Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$($specialStep.transaction_id).intent.json" -RequireLeaf
                }
            }
        }
        if ($null -eq $specialStep -and [IO.File]::Exists($intentPath) -and $eventReceipts.Count -eq 1) {
            $eventReceiptPath = Resolve-MorphospaceWorkspacePath $workspace ([string]$eventReceipts[0])
            if ([IO.File]::Exists($eventReceiptPath)) {
                $eventReceipt = Read-MorphospaceProtocolJson $eventReceiptPath
                if ([string]$eventReceipt.schema -ceq 'rusty.morphospace.workflow.admission_completion_timestamp_recovery.v1') {
                    $specialStep = Test-MorphospaceHistoricalAdmissionCompletionTimestampRecovery -WorkspaceRoot $workspace -RecoveryPath $eventReceiptPath -ExpectedEvent $event
                    $intent = Read-MorphospaceProtocolJson $intentPath
                }
            }
        }
        if ($null -eq $specialStep -and -not [IO.File]::Exists($intentPath) -and $state.PSObject.Properties.Name -contains 'history_archive' -and $null -ne $state.history_archive) {
            # Archive checkpoints have their own existing transaction namespace.
            if ($null -eq $archive -or [string]$archive.status -cne 'pass') { throw 'Current-work archive checkpoint is not authenticated.' }
            $intentPath = Resolve-MorphospaceWorkspacePath $workspace "history-archive/transactions/$($archive.checkpoint.checkpoint_id)-archive-transition.intent.json" -RequireLeaf
            $intent = Read-MorphospaceProtocolJson $intentPath
            if ((Get-MorphospaceCanonicalJsonSha256 $intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $event)) { throw 'Current-work archive event is detached.' }
            $authenticatedArchiveStep = $true
        } elseif ($null -eq $specialStep) {
            $intent = Read-MorphospaceProtocolJson $intentPath
        }
        if ($null -ne $specialStep -and [string]$intent.schema -ceq 'rusty.morphospace.workflow.development_envelope_repreparation_intent.v1') {
            foreach ($name in @('project','feature_lock')) {
                $path = [string]$intent.target.$name.path
                if ($projectionHashes.ContainsKey($path) -and [string]$intent.pre.$name.sha256 -cne $projectionHashes[$path]) { throw 'Current-work repreparation projection preimage is detached.' }
                $projectionHashes[$path] = [string]$intent.target.$name.sha256
            }
        } elseif ([string]$intent.schema -ceq 'rusty.morphospace.workflow.development_envelope_preparation_intent.v1') {
            if ($preparationRecoveryByOriginal.ContainsKey([string]$event.event_id)) {
                $preparationRecovery = $preparationRecoveryByOriginal[[string]$event.event_id]
                $preparationEvidence = Get-MorphospacePreparationStepEvidence $workspace $intentPath $intent $events $event
                if ($preparationEvidence.chronology_fault -cne 'preparation-completion-precedes-intent' -or
                    $preparationEvidence.intent_raw_sha256 -cne $preparationRecovery.original_intent_raw_sha256 -or
                    $preparationEvidence.completion_raw_sha256 -cne $preparationRecovery.original_completion_raw_sha256 -or
                    (Get-MorphospaceCanonicalJsonSha256 $intent) -cne (Get-MorphospaceCanonicalJsonSha256 $preparationRecovery.original_intent)) {
                    throw 'Current-work preparation timestamp recovery does not bind this exact malformed step.'
                }
            } else {
                Assert-CurrentWorkPreparationStep $workspace $intentPath $intent $events $event
            }
            foreach ($name in @('project','feature_lock')) {
                $path = [string]$intent.target.$name.path
                if ($projectionHashes.ContainsKey($path) -and [string]$intent.pre.$name.sha256 -cne $projectionHashes[$path]) { throw 'Current-work preparation projection preimage is detached.' }
                $projectionHashes[$path] = [string]$intent.target.$name.sha256
            }
        } elseif (-not $authenticatedArchiveStep) {
            $step = if ($null -ne $specialStep) { $specialStep } else { Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId $id -ExpectedStatePath 'workspace.state.json' -ExpectedEventsPath 'iteration-events.jsonl' }
            $intent = $step.intent
            if($intent.PSObject.Properties.Name-contains'artifacts'){
                $ownerActionSchemas=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                $hasNewOwnerAction=$false
                foreach($artifact in @($intent.artifacts)){
                    $bytes=[Convert]::FromBase64String([string]$artifact.bytes_base64)
                    try{$document=ConvertFrom-MorphospaceProtocolJsonBytes $bytes}catch{continue}
                    if($null-eq$document-or-not($document.PSObject.Properties.Name-contains'schema')){continue}
                    if(@('rusty.morphospace.workflow.active_development_envelope_extension.v1','rusty.morphospace.workflow.tooling_context_upgrade.v1','rusty.morphospace.workflow.active_write_scope_amendment.v1')-ccontains[string]$document.schema){
                        if(-not$ownerActionSchemas.Add([string]$document.schema)){throw 'Current-work continuation repeats an owner-action request.'}
                    }
                    if([string]$document.schema-ceq'rusty.morphospace.workflow.active_development_envelope_extension.v1'){
                        $hasNewOwnerAction=$true
                        $extensionOwnerModule=Import-Module (Join-Path $PSScriptRoot '../ActiveDevelopmentEnvelopeExtension.psm1') -PassThru
                        [void](&$extensionOwnerModule {param($root,$event,$transition) Assert-ActiveEnvelopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $event -Transition $transition} $workspace $event $step)
                    }elseif([string]$document.schema-ceq'rusty.morphospace.workflow.tooling_context_upgrade.v1'){
                        $hasNewOwnerAction=$true
                        $toolingUpgradeOwnerModule=Import-Module (Join-Path $PSScriptRoot '../ToolingContextUpgrade.psm1') -PassThru
                        [void](&$toolingUpgradeOwnerModule {param($root,$event,$transition) Assert-ToolingContextHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $event -Transition $transition} $workspace $event $step)
                    }
                }
                if($hasNewOwnerAction-and$ownerActionSchemas.Count-ne1){throw 'Current-work continuation mixes distinct owner actions.'}
            }
            if ($step.PSObject.Properties.Name -contains 'intent') { $suffixTransitions[[string]$event.event_id] = $step }
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
        if ([string]$event.event_id -cmatch '-accepted-evidence-relocated-[0-9]{4,}$') {
            [void](Test-MorphospaceAcceptedEvidenceRelocation -WorkspaceRoot $workspace -RelocationId ([string]$event.event_id))
        }
        $priorStateHash = [string]$intent.target.state.sha256
        $proposedRetirementPattern = '^' + [regex]::Escape([string]$event.unit_id) + '-proposal-retired-[0-9]{4}$'
        if ([string]$event.event_type -ceq 'state-transition' -and [string]$event.event_id -cmatch $proposedRetirementPattern -and
            $units.ContainsKey([string]$event.unit_id) -and [string]$units[[string]$event.unit_id].status -ceq 'superseded' -and
            [string]$intent.target.unit.document.status -ceq 'superseded' -and
            [string]$intent.target.unit.sha256 -ceq (Get-MorphospaceCanonicalJsonSha256 $units[[string]$event.unit_id])) {
            [void](Test-MorphospaceHistoricalProposedRetirement -WorkspaceRoot $workspace -ExpectedEvent $event -CommittedStep $step)
            $retiredId=[string]$event.unit_id;if($historicallyRetiredProposedSequences.ContainsKey($retiredId)){throw 'Current-work proposed retirement identity is ambiguous.'};$historicallyRetiredProposedSequences[$retiredId]=[int]$event.sequence
            [void]$historicallyRetiredProposed.Add([string]$event.unit_id)
        }
    }
    if ($priorStateHash -cne (Get-MorphospaceCanonicalJsonSha256 $state)) { throw 'Current-work transaction suffix does not derive the live state.' }
    foreach ($id in @($historicallyRetiredProposed)) {
        $resurrectionPattern='^'+[regex]::Escape($id)+'-(ready|claimed|active|validating|resumed)(?:-|$)'
        if ([string]$state.current_unit -ceq $id -or [string]$state.next_ready_unit -ceq $id -or
            @($events | Where-Object { [string]$_.unit_id -ceq $id -and [string]$_.event_id -cmatch $resurrectionPattern -and [int]$_.sequence -gt [int]$historicallyRetiredProposedSequences[$id] }).Count -gt 0) {
            throw 'Current-work proposed retirement cannot hide a resurrected owner.'
        }
        $audit.Add([pscustomobject]@{unit_id=$id; classification='retired-proposed'; current_policy_revalidated=$false; grants_validation_credit=$false})
    }
    $supersededScopeResult = Get-MorphospaceAuthenticatedSupersededScopeConflicts -Workspace $workspace -State $state -Units $units -Events $events -AcceptedSequence $sequence -SuffixTransitions $suffixTransitions
    $supersededScopeConflicts = $supersededScopeResult.ids
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
            @($events | Where-Object { [int]$_.sequence -gt $sequence -and [string]$_.unit_id -ceq $id -and [string]$_.event_type -ceq 'state-transition' -and [string]$_.event_id -cmatch '-(claimed|active|ready|validating)-' }).Count -gt 0) {
            throw 'Current-work history cannot hide a resurrected historical owner.'
        }
        $audit.Add([pscustomobject]@{unit_id=$id; classification=$(if($retired.Contains($id)){'retired'}else{'accepted-history'}); current_policy_revalidated=$false; grants_validation_credit=$false})
    }
    # Historical prerequisite evidence remains an actual dependency, even
    # though its old instruction vocabulary is not reinterpreted.
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $units.Keys) {
        if ($historical.Contains($id) -or $historicallyRetiredProposed.Contains($id) -or $retiredActive.Contains($id) -or $units[$id].PSObject.Properties.Name -notcontains 'prerequisites') { continue }
        foreach ($dependency in $units[$id].prerequisites) { [void]$required.Add([string]$dependency) }
    }
    foreach ($id in $required) {
        if (-not $units.ContainsKey($id) -or [string]$units[$id].status -cne 'accepted') { throw "Current-work prerequisite '$id' is not accepted." }
        $terminal = @($events | Where-Object { [string]$_.unit_id -ceq $id -and [string]$_.event_id -cmatch ('^'+[regex]::Escape($id)+'-accepted-[0-9]{4,}$') })
        if ($terminal.Count -ne 1) { throw "Current-work prerequisite '$id' has no unique accepted evidence." }
        $proof = if ($id -ceq $acceptedId -and [string]$terminal[0].event_id -ceq [string]$acceptedEvent.event_id) {
            $accepted
        } else {
            Test-MorphospaceAcceptedCheckpointProof -WorkspaceRoot $workspace -ExpectedEvent $terminal[0] -AllowFiniteHistoricalV1:([int]$terminal[0].sequence-le$sequence)
        }
        if ([string]$proof.intent.target.unit.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $units[$id]) -or [string]$proof.intent.target.unit.document.status -cne 'accepted') { throw "Current-work prerequisite '$id' differs from accepted evidence." }
    }
    return [pscustomobject]@{ authenticated=$true; sequence=$sequence; accepted_unit_id=$acceptedId; historical_ids=$historical; retired_ids=$retired; historically_retired_proposed_ids=$historicallyRetiredProposed; retired_active_ids=$retiredActive; active_retirements=$activeRetirements; authenticated_superseded_scope_conflict_ids=$supersededScopeConflicts; units=$units; events=$events; audit_only=@($audit.ToArray()) }
}

function Get-MorphospacePreparationStepEvidence {
    param([string]$Workspace,[string]$IntentPath,[object]$Intent,[object[]]$Events,[object]$ExpectedEvent)
    $repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $completionPath = Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($Intent.transaction_id).completion.json" -RequireLeaf
    foreach ($pair in @(@($IntentPath,'development-envelope-preparation-intent-v1.schema.json'),@($completionPath,'development-envelope-preparation-completion-v1.schema.json'))) {
        if (-not (Test-Json -Json (Get-Content -LiteralPath $pair[0] -Raw) -SchemaFile (Join-Path $repository "schemas/$($pair[1])"))) { throw 'Current-work preparation suffix schema is invalid.' }
    }
    $completion = Read-MorphospaceProtocolJson $completionPath
    if ([string]$Intent.transaction_id -cne "$($ExpectedEvent.event_id)-transition" -or [string]$Intent.created_at -cne [string]$ExpectedEvent.timestamp -or
        [IO.Path]::GetFullPath($IntentPath) -cne (Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$($ExpectedEvent.event_id)-transition.intent.json") -or
        (Get-MorphospaceCanonicalJsonSha256 $Intent.event) -cne (Get-MorphospaceCanonicalJsonSha256 $ExpectedEvent)) { throw 'Current-work preparation transaction identity is detached.' }
    if ([string]$completion.intent_sha256 -cne (Get-MorphospaceFileSha256 $IntentPath) -or [string]$completion.transaction_id -cne [string]$Intent.transaction_id -or [string]$completion.event_id -cne [string]$Intent.event.event_id) { throw 'Current-work preparation completion is detached.' }
    $chronologyFault = if ((Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at)) -lt (Test-MorphospaceStrictUtcTimestamp ([string]$Intent.created_at))) { 'preparation-completion-precedes-intent' } else { $null }
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
        [string]$Intent.pre.events.path -cne 'iteration-events.jsonl' -or [string]$Intent.target.events.path -cne 'iteration-events.jsonl' -or [string]$Intent.target.events.sha256 -cne [string]$Intent.pre.events.sha256) { throw 'Current-work preparation predecessor or ledger path is detached.' }
    $artifacts=@($Intent.artifacts);$hasTooling=$Intent.PSObject.Properties.Name-ccontains'tooling_context';$expectedArtifactCount=$(if($hasTooling){3}else{2})
    if($artifacts.Count-ne$expectedArtifactCount-or@($ExpectedEvent.receipts).Count-ne1-or-not([string]$ExpectedEvent.event_id).EndsWith('-prepared',[StringComparison]::Ordinal)) { throw 'Current-work preparation does not own its exact receipt, source, and optional tooling-context artifacts.' }
    $preparationId=([string]$ExpectedEvent.event_id).Substring(0,([string]$ExpectedEvent.event_id).Length-'-prepared'.Length);$receiptRelative="receipts/$preparationId.json";$receiptPath=Resolve-MorphospaceWorkspacePath $Workspace $receiptRelative -RequireLeaf
    if([string]$ExpectedEvent.receipts[0]-cne$receiptRelative-or[string]$ExpectedEvent.unit_id-cne[string]$Intent.pre.predecessor_unit.document.unit_id-or[string]$ExpectedEvent.event_type-cne'decision'-or[string]$ExpectedEvent.summary-cne'Prepared one bounded idle-project development envelope; future admission remains bind-only.') { throw 'Current-work preparation event semantics are detached.' }
    if(-not(Test-Json -Json (Get-Content -LiteralPath $receiptPath -Raw) -SchemaFile (Join-Path $repository 'schemas/development-envelope-preparation-receipt-v1.schema.json'))){throw 'Current-work preparation receipt schema is invalid.'};$receipt=Read-MorphospaceProtocolJson $receiptPath
    $sourceRelative=[string]$receipt.source_composition.path;$sourcePath=Resolve-MorphospaceWorkspacePath $Workspace $sourceRelative -RequireLeaf
    $sourceSchema=$(if($hasTooling){'development-envelope-source-composition-v3.schema.json'}else{'development-envelope-source-composition-v1.schema.json'});if(-not(Test-Json -Json (Get-Content -LiteralPath $sourcePath -Raw) -SchemaFile (Join-Path $repository "schemas/$sourceSchema"))){throw 'Current-work preparation source composition schema is invalid.'};$source=Read-MorphospaceProtocolJson $sourcePath
    $hasReclassification=$receipt.PSObject.Properties.Name-ccontains'legacy_tooling_reclassification';if($hasReclassification-ne($Intent.PSObject.Properties.Name-ccontains'legacy_tooling_reclassification')){throw 'Current-work preparation legacy tooling reclassification presence is detached.'}
    $oldMapRelative=[string]$Intent.pre.repository_map.path;$oldMapPath=Resolve-MorphospaceWorkspacePath $Workspace $oldMapRelative -RequireLeaf;$mapRelative=[string]$Intent.target.repository_map.path;$mapPath=Resolve-MorphospaceWorkspacePath $Workspace $mapRelative -RequireLeaf
    foreach($binding in @(@{path=$oldMapPath;hash=[string]$Intent.pre.repository_map.sha256},@{path=$mapPath;hash=[string]$Intent.target.repository_map.sha256})){if($binding.hash-cne(Get-MorphospaceFileSha256 $binding.path)-or-not(Test-Json -Json (Get-Content -LiteralPath $binding.path -Raw) -SchemaFile (Join-Path $repository 'schemas/repository-map.schema.json'))){throw 'Current-work preparation repository map is detached or invalid.'}}
    if(-not$hasReclassification-and($mapRelative-cne$oldMapRelative-or[string]$Intent.target.repository_map.sha256-cne[string]$Intent.pre.repository_map.sha256)){throw 'Ordinary current-work preparation repository-map projection is not preserved.'}
    $mapDocument=Read-MorphospaceProtocolJson $mapPath;$oldMapDocument=Read-MorphospaceProtocolJson $oldMapPath
    if([string]$receipt.preparation_id-cne$preparationId-or[string]$receipt.project_id-cne[string]$ExpectedEvent.project_id-or[string]$receipt.predecessor_unit_id-cne[string]$ExpectedEvent.unit_id-or[string]$receipt.envelope.source_composition.path-cne$sourceRelative-or[string]$receipt.project_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $receipt.envelope.project)-or[string]$receipt.feature_lock_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $receipt.envelope.feature_lock)-or[string]$receipt.project_sha256-cne[string]$Intent.target.project.sha256-or[string]$receipt.feature_lock_sha256-cne[string]$Intent.target.feature_lock.sha256-or[string]$receipt.source_composition.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $source)-or[string]$source.project_id-cne[string]$receipt.project_id-or[string]$source.preparation_id-cne$preparationId-or[string]$source.fingerprint-cne(Get-MorphospacePreparationSourceCompositionFingerprint -Composition $source)-or[string]$source.lock_id-cne"$preparationId-source-$(([string]$source.fingerprint).Substring(0,12))"){throw 'Current-work preparation receipt, envelope, or source composition is detached.'}
    if($hasReclassification){
        $reclassification=$receipt.legacy_tooling_reclassification;if((Get-MorphospaceCanonicalJsonSha256 $reclassification)-cne(Get-MorphospaceCanonicalJsonSha256 $Intent.legacy_tooling_reclassification)-or-not(Test-Json -Json ($reclassification|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repository 'schemas/legacy-tooling-reclassification-v1.schema.json'))){throw 'Current-work legacy tooling reclassification evidence is detached.'}
        if([string]$reclassification.old_repository_map.path-cne$oldMapRelative-or[string]$reclassification.old_repository_map.sha256-cne[string]$Intent.pre.repository_map.sha256-or[string]$reclassification.target_repository_map.path-cne$mapRelative-or[string]$reclassification.target_repository_map.sha256-cne[string]$Intent.target.repository_map.sha256-or$oldMapRelative-ceq$mapRelative-or$oldMapRelative-cnotmatch'^local/'-or$mapRelative-cnotmatch'^local/'){throw 'Current-work legacy tooling map bindings are detached.'}
        if(@($Events|Where-Object{[int]$_.sequence-lt[int]$ExpectedEvent.sequence-and[string]$_.event_id-cmatch'-active-retired$'}).Count-lt1){throw 'Current-work legacy tooling reclassification lacks prior active retirement.'}
        $oldProjectIndex=@{};foreach($row in @($Intent.pre.project.document.repositories)){if($oldProjectIndex.ContainsKey([string]$row.repo_id)){throw 'Current-work legacy tooling old project repeats a repository.'};$oldProjectIndex[[string]$row.repo_id]=$row};$newProjectIndex=@{};foreach($row in @($Intent.target.project.document.repositories)){if($newProjectIndex.ContainsKey([string]$row.repo_id)){throw 'Current-work legacy tooling target project repeats a repository.'};$newProjectIndex[[string]$row.repo_id]=$row};$oldMapIndex=@{};foreach($row in @($oldMapDocument.repositories)){if($oldMapIndex.ContainsKey([string]$row.repo_id)){throw 'Current-work legacy tooling old map repeats a repository.'};$oldMapIndex[[string]$row.repo_id]=$row};$newMapIndex=@{};foreach($row in @($mapDocument.repositories)){if($newMapIndex.ContainsKey([string]$row.repo_id)){throw 'Current-work legacy tooling target map repeats a repository.'};$newMapIndex[[string]$row.repo_id]=$row}
        $declaredRemoved=@($reclassification.removed_tool_repositories|ForEach-Object{[string]$_.repo_id}|Sort-Object);$actualProjectRemoved=@($oldProjectIndex.Keys|Where-Object{-not$newProjectIndex.ContainsKey($_)}|Sort-Object);$actualMapRemoved=@($oldMapIndex.Keys|Where-Object{-not$newMapIndex.ContainsKey($_)}|Sort-Object)
        if(($declaredRemoved-join"`n")-cne($actualProjectRemoved-join"`n")-or($declaredRemoved-join"`n")-cne($actualMapRemoved-join"`n")){throw 'Current-work legacy tooling declared removal set differs from project and map projections.'}
        foreach($id in $newMapIndex.Keys){if($oldMapIndex.ContainsKey($id)-and(Get-MorphospaceCanonicalJsonSha256 $oldMapIndex[$id])-cne(Get-MorphospaceCanonicalJsonSha256 $newMapIndex[$id])){throw 'Current-work legacy tooling rewrites a preserved repository-map row.'}}
        foreach($removed in @($reclassification.removed_tool_repositories)){
            $id=[string]$removed.repo_id;if([string]$oldProjectIndex[$id].role-cne'tool'-or(Get-MorphospaceCanonicalJsonSha256 $oldProjectIndex[$id])-cne[string]$removed.project_row_sha256-or(Get-MorphospaceCanonicalJsonSha256 $oldMapIndex[$id])-cne[string]$removed.map_row_sha256){throw 'Current-work legacy tooling removed row identity is detached.'}
            $retirementProofs=@($Events|Where-Object{[int]$_.sequence-lt[int]$ExpectedEvent.sequence-and[string]$_.event_id-cmatch'-active-retired$'}|ForEach-Object{Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1');Test-MorphospaceHistoricalActiveUnitRetirement -WorkspaceRoot $Workspace -ExpectedEvent $_}|Where-Object{[string]$_.request.source_composition.path-ceq[string]$removed.source_composition.path-and[string]$_.request.source_composition.raw_sha256-ceq[string]$removed.source_composition.sha256-and[string]$_.request.source_composition.canonical_sha256-ceq[string]$removed.source_composition.canonical_sha256-and[string]$_.request.expected.repository_map_sha256-ceq[string]$reclassification.old_repository_map.sha256})
            if($retirementProofs.Count-ne1){throw 'Current-work legacy tooling historical source and map lack one authenticated retirement.'};$retiredUnitId=[string]$retirementProofs[0].request.unit_id
            $admissions=@(Get-ChildItem -LiteralPath (Resolve-MorphospaceWorkspacePath $Workspace 'receipts') -File -Filter '*.json'|ForEach-Object{$candidate=Read-MorphospaceProtocolJson $_.FullName;if([string]$candidate.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'-and[string]$candidate.unit_id-ceq$retiredUnitId){$candidate}})
            if($admissions.Count-ne1-or-not(Test-Json -Json ($admissions[0]|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repository 'schemas/development-unit-admission-v1.schema.json'))-or[string]$admissions[0].expected.repository_map_path-cne$oldMapRelative-or[string]$admissions[0].expected.repository_map_sha256-cne[string]$reclassification.old_repository_map.sha256-or[string]$admissions[0].preparation.source_composition_path-cne[string]$removed.source_composition.path-or[string]$admissions[0].preparation.source_composition_sha256-cne[string]$removed.source_composition.sha256){throw 'Current-work legacy tooling old map and source are detached from retired admission.'}
            $oldSourcePath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$removed.source_composition.path) -RequireLeaf;$oldSource=Read-MorphospaceProtocolJson $oldSourcePath;$oldRows=@($oldSource.repositories|Where-Object{[string]$_.repo_id-ceq$id});if((Get-MorphospaceFileSha256 $oldSourcePath)-cne[string]$removed.source_composition.sha256-or(Get-MorphospaceCanonicalJsonSha256 $oldSource)-cne[string]$removed.source_composition.canonical_sha256-or$oldRows.Count-ne1-or(Get-MorphospaceCanonicalJsonSha256 $oldRows[0])-cne[string]$removed.source_row_sha256-or[string]$oldRows[0].commit-cne[string]$removed.commit-or[string]$oldRows[0].tree-cne[string]$removed.tree-or[string]$oldRows[0].materialization_path-cne[string]$removed.materialization_path){throw 'Current-work legacy tooling historical source pin is detached.'}
        }
    }
    $ownerIds=@($receipt.envelope.owner_repositories|ForEach-Object{[string]$_.repo_id}|Sort-Object -Unique);$declaredSourceIds=@($receipt.envelope.source_composition.repository_ids|ForEach-Object{[string]$_}|Sort-Object -Unique);$sourceIds=@($source.repositories|ForEach-Object{[string]$_.repo_id}|Sort-Object -Unique);$mapIds=@($mapDocument.repositories|ForEach-Object{[string]$_.repo_id}|Sort-Object -Unique);$targetProjectIds=@($Intent.target.project.document.repositories|ForEach-Object{[string]$_.repo_id}|Sort-Object -Unique)
    if($ownerIds.Count-ne$declaredSourceIds.Count-or$ownerIds.Count-ne$sourceIds.Count-or$ownerIds.Count-ne$mapIds.Count-or$ownerIds.Count-ne$targetProjectIds.Count-or@($ownerIds|Where-Object{$declaredSourceIds-cnotcontains$_-or$sourceIds-cnotcontains$_-or$mapIds-cnotcontains$_-or$targetProjectIds-cnotcontains$_}).Count-ne0){throw 'Current-work preparation owner, source, map, and target project repository sets differ.'}
    $mapIndex=@{};foreach($mapRepository in @($mapDocument.repositories)){$mapIndex[[string]$mapRepository.repo_id]=$true};Assert-MorphospaceDevelopmentEnvelopeOwnerRoots @($receipt.envelope.owner_repositories) $Intent.target.project.document $mapIndex
    foreach($sourceRepository in @($source.repositories)){$mapRepository=@($mapDocument.repositories|Where-Object{[string]$_.repo_id-ceq[string]$sourceRepository.repo_id});if($mapRepository.Count-ne1-or[string]$sourceRepository.role-cne[string]$mapRepository[0].role){throw 'Current-work preparation source role differs from its repository map.'}}
    $scopeCurrent=$Intent.pre.project.document;if($hasReclassification){$removedIds=@($receipt.legacy_tooling_reclassification.removed_tool_repositories|ForEach-Object{[string]$_.repo_id});$scopeCurrent=$Intent.pre.project.document|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;$scopeCurrent.repositories=@($scopeCurrent.repositories|Where-Object{$removedIds-cnotcontains[string]$_.repo_id})};Assert-MorphospaceDevelopmentEnvelopeRepositoryRoots @($scopeCurrent.repositories) @($Intent.target.project.document.repositories) @($receipt.envelope.owner_repositories)
    foreach ($artifact in $artifacts) {
        $path = Resolve-MorphospaceWorkspacePath $Workspace ([string]$artifact.path) -RequireLeaf
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [string]$artifact.bytes_base64 -or (Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $path)) -cne [string]$artifact.sha256) { throw 'Current-work preparation artifact is damaged.' }
    }
    if([string]$artifacts[0].path-cne$receiptRelative-or[string]$artifacts[1].path-cne$sourceRelative-or[string]$artifacts[0].sha256-cne(Get-MorphospaceCanonicalJsonSha256 $receipt)-or[string]$artifacts[1].sha256-cne(Get-MorphospaceCanonicalJsonSha256 $source)){throw 'Current-work preparation artifact order or identities are detached.'}
    if($hasTooling){
        if(-not($receipt.PSObject.Properties.Name-ccontains'tooling_context')-or(Get-MorphospaceCanonicalJsonSha256 $receipt.tooling_context)-cne(Get-MorphospaceCanonicalJsonSha256 $Intent.tooling_context)){throw 'Current-work preparation tooling-context pointer is detached.'}
        $pointer=$receipt.tooling_context;$contextRelative=[string]$pointer.path;$contextPath=Resolve-MorphospaceWorkspacePath $Workspace $contextRelative -RequireLeaf;$context=Read-MorphospaceProtocolJson $contextPath
        if(-not(Test-Json -Json ($context|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repository 'schemas/tooling-context-v1.schema.json'))){throw 'Current-work preparation tooling context schema is invalid.'}
        $contextIdentity=[ordered]@{context_id=$context.context_id;project_id=$context.project_id;preparation_id=$context.preparation_id;product_projection=$context.product_projection;resolver=$context.resolver;executor=$context.executor;routers=$context.routers;compatibility=$context.compatibility;limits=$context.limits;status=$context.status};if([string]$context.fingerprint-cne(Get-MorphospaceCanonicalJsonSha256 $contextIdentity)){throw 'Current-work preparation tooling context fingerprint is detached.'}
        if([string]$artifacts[2].path-cne$contextRelative-or[string]$artifacts[2].sha256-cne[string]$pointer.canonical_sha256-or[string]$pointer.sha256-cne(Get-MorphospaceFileSha256 $contextPath)-or[string]$pointer.canonical_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $context)-or[string]$context.project_id-cne[string]$receipt.project_id-or[string]$context.preparation_id-cne$preparationId-or[string]$context.compatibility.protocol_id-cne[string]$pointer.protocol_id-or[string]$source.tooling_protocol.protocol_id-cne[string]$pointer.protocol_id){throw 'Current-work preparation tooling context identity or exact artifact binding is detached.'}
        $featureBytes=ConvertTo-MorphospaceProtocolJsonBytes $Intent.target.feature_lock.document
        if([string]$context.product_projection.source_composition.path-cne$sourceRelative-or[string]$context.product_projection.source_composition.sha256-cne(Get-MorphospaceFileSha256 $sourcePath)-or[string]$context.product_projection.repository_map.path-cne$mapRelative-or[string]$context.product_projection.repository_map.sha256-cne(Get-MorphospaceFileSha256 $mapPath)-or[string]$context.product_projection.feature_lock.path-cne'feature.lock.json'-or[string]$context.product_projection.feature_lock.sha256-cne(Get-MorphospaceSha256Bytes $featureBytes)){throw 'Current-work preparation tooling context changes its original product projection.'}
        if($hasReclassification){$history=Get-MorphospaceLegacyToolingReclassificationHistory -WorkspaceRoot $Workspace -Events $Events -PreparationEventId ([string]$ExpectedEvent.event_id);[void](Assert-MorphospaceLegacyToolingReclassification -WorkspaceRoot $Workspace -Reclassification $receipt.legacy_tooling_reclassification -CurrentProject $Intent.pre.project.document -TargetProject $Intent.target.project.document -CurrentMap $oldMapDocument -TargetMap $mapDocument -ToolingDescriptor $context -History $history -TargetSourceRepositoryIds @($source.repositories|ForEach-Object{[string]$_.repo_id}) -OwnerRepositories @($receipt.envelope.owner_repositories))}
    }elseif($receipt.PSObject.Properties.Name-ccontains'tooling_context'){throw 'Legacy current-work preparation unexpectedly gains a tooling context.'}
    $preparation=[pscustomobject]@{project_id=[string]$receipt.project_id;envelope=$receipt.envelope}
    $preparationMode=$(if($hasReclassification){'ordinary'}else{Get-MorphospaceDevelopmentEnvelopeReplayMode $Intent.pre.project.document $Intent.target.project.document})
    Assert-MorphospaceDevelopmentEnvelopeAdditiveProject $scopeCurrent $Intent.target.project.document $true @($receipt.envelope.owner_repositories) $preparationMode
    $semanticsAccepted=$true
    try{
        Assert-MorphospaceDevelopmentEnvelope $preparation $Intent.pre.project.document $Intent.pre.feature_lock.document $preparationMode
        $derivedState=Get-MorphospaceDevelopmentEnvelopeTargetState $preparation $Intent.pre.project.document $Intent.pre.feature_lock.document $Intent.pre.state.document;$derivedState.last_event_id=[string]$ExpectedEvent.event_id
        if((Get-MorphospaceCanonicalJsonSha256 $derivedState)-cne[string]$Intent.target.state.sha256){throw 'Current-work preparation target state is not the exact owner-derived projection.'}
        Assert-MorphospaceDevelopmentEnvelopeLockAndRegistry $Intent.target.project.document $Intent.target.feature_lock.document $Intent.target.state.document 'historical target'
    }catch{$semanticsAccepted=$false;$semanticFailure=$_}
    if(-not$semanticsAccepted){
        $recoveryEvents=@()
        foreach($candidate in @($Events|Where-Object{
            [int]$_.sequence-gt[int]$ExpectedEvent.sequence-and
            [string]$_.event_type-ceq'decision'-and
            [string]$_.event_id-cmatch'^[a-z0-9][a-z0-9-]{1,127}-prepared$'-and
            @($_.receipts).Count-eq2-and
            [string]$_.receipts[0]-cmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}-repreparation\.json$'-and
            [string]$_.receipts[1]-ceq("receipts/{0}.json"-f([string]$_.event_id).Substring(0,([string]$_.event_id).Length-9))
        })){
            $candidateRecoveryPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$candidate.receipts[0]) -RequireLeaf
            if(-not(Test-Json -Json (Get-Content -LiteralPath $candidateRecoveryPath -Raw) -SchemaFile (Join-Path $repository 'schemas/development-envelope-repreparation-receipt-v1.schema.json'))){throw 'Current-work preparation recovery receipt schema is invalid.'}
            $candidateRecovery=Read-MorphospaceProtocolJson $candidateRecoveryPath
            if([string]$candidateRecovery.original_preparation.event_id-ceq[string]$ExpectedEvent.event_id-and
               [string]$candidateRecovery.original_preparation.receipt.path-ceq$receiptRelative-and
               [string]$candidateRecovery.original_preparation.intent.path-ceq("receipts/transactions/{0}.intent.json"-f[string]$Intent.transaction_id)-and
               [string]$candidateRecovery.original_preparation.completion.path-ceq("receipts/transactions/{0}.completion.json"-f[string]$Intent.transaction_id)-and
               [string]$candidateRecovery.original_preparation.receipt.sha256-ceq(Get-MorphospaceFileSha256 $receiptPath)-and
               [string]$candidateRecovery.original_preparation.intent.sha256-ceq(Get-MorphospaceFileSha256 $IntentPath)-and
               [string]$candidateRecovery.original_preparation.completion.sha256-ceq(Get-MorphospaceFileSha256 $completionPath)){$recoveryEvents+=,$candidate}
        }
        if($recoveryEvents.Count-ne1){throw $semanticFailure}
        $recoveryStep=Test-MorphospaceCommittedDevelopmentEnvelopeRepreparation -WorkspaceRoot $Workspace -ExpectedEvent $recoveryEvents[0]
        $recoveryReceipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $Workspace ([string]$recoveryEvents[0].receipts[0]) -RequireLeaf)
        if([string]$recoveryReceipt.original_preparation.event_id-cne[string]$ExpectedEvent.event_id-or[string]$recoveryStep.intent.pre.project.sha256-cne[string]$Intent.target.project.sha256-or[string]$recoveryStep.intent.pre.feature_lock.sha256-cne[string]$Intent.target.feature_lock.sha256){throw 'Current-work preparation recovery does not bind the exact defective target.'}
        Assert-MorphospaceDevelopmentEnvelopeRepreparationDefect $Intent.target.project.document $Intent.target.feature_lock.document $Intent.target.state.document
        $normalizedLock=$Intent.target.feature_lock.document|ConvertTo-Json -Depth 64|ConvertFrom-Json -DateKind String;$normalizedLock.lock_fingerprint=Get-MorphospaceFeatureLockFingerprint $normalizedLock
        $oldProfiles=@{};foreach($profile in @($Intent.target.project.document.validation_profiles)){$oldProfiles[[string]$profile.profile_id]=$profile};$recoveredProfiles=@{};foreach($profile in @($recoveryStep.intent.target.project.document.validation_profiles)){$recoveredProfiles[[string]$profile.profile_id]=$profile}
        foreach($id in $oldProfiles.Keys){if(-not$recoveredProfiles.ContainsKey($id)-or(Get-MorphospaceCanonicalJsonSha256 $oldProfiles[$id])-cne(Get-MorphospaceCanonicalJsonSha256 $recoveredProfiles[$id])){throw 'Current-work preparation recovery rewrites an existing validation profile.'}}
        $missingDeclared=@($receipt.envelope.build_envelope.allowed_profiles|Where-Object{-not$oldProfiles.ContainsKey([string]$_)}|Sort-Object -Unique);$addedRecovered=@($recoveredProfiles.Keys|Where-Object{-not$oldProfiles.ContainsKey($_)}|Sort-Object -Unique)
        if((Get-MorphospaceCanonicalJsonSha256 $missingDeclared)-cne(Get-MorphospaceCanonicalJsonSha256 $addedRecovered)){throw 'Current-work preparation recovery changes validation profiles beyond the exact missing declared profiles.'}
        $normalizedEnvelope=$receipt.envelope|ConvertTo-Json -Depth 64|ConvertFrom-Json -DateKind String;$normalizedEnvelope.feature_lock=$normalizedLock;$normalizedEnvelope.project.validation_profiles=@($Intent.target.project.document.validation_profiles)+@($addedRecovered|ForEach-Object{$recoveredProfiles[$_]});$normalizedPreparation=[pscustomobject]@{project_id=[string]$receipt.project_id;envelope=$normalizedEnvelope}
        $normalizedTargetState=$Intent.target.state.document|ConvertTo-Json -Depth 64|ConvertFrom-Json -DateKind String;$normalizedTargetState.module_registry=Get-MorphospaceDevelopmentEnvelopeModuleRegistry $Intent.target.project.document $normalizedLock
        Assert-MorphospaceDevelopmentEnvelope $normalizedPreparation $Intent.pre.project.document $Intent.pre.feature_lock.document $preparationMode
        $normalizedDerivedState=Get-MorphospaceDevelopmentEnvelopeTargetState $normalizedPreparation $Intent.pre.project.document $Intent.pre.feature_lock.document $Intent.pre.state.document;$normalizedDerivedState.last_event_id=[string]$ExpectedEvent.event_id
        if((Get-MorphospaceCanonicalJsonSha256 $normalizedDerivedState)-cne(Get-MorphospaceCanonicalJsonSha256 $normalizedTargetState)){throw 'Current-work preparation recovery would conceal damage outside the exact fingerprint and module-registry defect.'}
        Assert-MorphospaceDevelopmentEnvelopeLockAndRegistry $Intent.target.project.document $normalizedLock $normalizedTargetState 'normalized historical target'
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
    return [pscustomobject]@{
        intent=$Intent; completion=$completion; completion_path=$completionPath; chronology_fault=$chronologyFault
        intent_raw_sha256=(Get-MorphospaceFileSha256 $IntentPath); completion_raw_sha256=(Get-MorphospaceFileSha256 $completionPath)
    }
}

function Assert-CurrentWorkPreparationStep {
    param([string]$Workspace,[string]$IntentPath,[object]$Intent,[object[]]$Events,[object]$ExpectedEvent)
    $evidence = Get-MorphospacePreparationStepEvidence @PSBoundParameters
    if ($null -ne $evidence.chronology_fault) { throw 'Current-work preparation completion predates its intent.' }
}

Export-ModuleMember -Function Get-MorphospaceCurrentWorkHistory,Get-MorphospacePreparationStepEvidence
