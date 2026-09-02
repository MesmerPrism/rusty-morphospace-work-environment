param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $SelfTest) {
    throw 'Test-AutomationReceiptV2Compatibility.ps1 requires -SelfTest.'
}

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$schemaPath = Join-Path $repositoryRoot 'schemas\work-unit-automation-receipt-v2.schema.json'
$automationModule = Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force -PassThru

function Assert-AutomationReceiptCompatibility {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Automation receipt-v2 compatibility self-test failed: $Message" }
}

function Test-AutomationReceiptSchema {
    param([Parameter(Mandatory)][object]$Receipt)
    try {
        return [bool](Test-Json -Json ($Receipt | ConvertTo-Json -Depth 32 -Compress) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Copy-AutomationReceiptValue {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 32 -Compress) | ConvertFrom-Json -DateKind String
}

function Assert-ReceiptCorpusMatchesSchema {
    param([Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Corpus)
    $schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json -DateKind String
    $schemaActions = @($schema.properties.action.enum | ForEach-Object { [string]$_ })
    $corpusActions = @($Corpus.Keys | ForEach-Object { [string]$_ })
    Assert-AutomationReceiptCompatibility (($schemaActions -join "`n") -ceq ($corpusActions -join "`n")) 'schema action enum drifted from the exact compatibility corpus'

    $corpusTransitions = [System.Collections.Generic.List[string]]::new()
    $seenTransitions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($action in $corpusActions) {
        $allowed = @($Corpus[$action] | ForEach-Object { [string]$_ })
        Assert-AutomationReceiptCompatibility ($allowed.Count -gt 0) "action '$action' has no allowed transition"
        foreach ($transition in $allowed) {
            Assert-AutomationReceiptCompatibility ($seenTransitions.Add($transition)) "transition '$transition' is assigned to more than one action"
            $corpusTransitions.Add($transition) | Out-Null
        }
    }
    $schemaTransitions = @($schema.properties.transition.enum | ForEach-Object { [string]$_ })
    Assert-AutomationReceiptCompatibility (($schemaTransitions -join "`n") -ceq (@($corpusTransitions) -join "`n")) 'schema transition enum drifted from the exact action/transition corpus'
}

function Test-ReceiptPairAllowed {
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Corpus,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Transition
    )
    return $Corpus.Contains($Action) -and @($Corpus[$Action]) -ccontains $Transition
}

function New-CanonicalAutomationReceipt {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Transition,
        [AllowNull()][object]$StatusBefore = 'active',
        [string]$StatusAfter = 'active',
        [AllowNull()][object]$CurrentUnitBefore = 'compatibility-unit',
        [AllowNull()][object]$CurrentUnitAfter = 'compatibility-unit',
        [ValidateSet('receipt','history-archive')][string]$AuditPathKind = 'receipt'
    )
    return [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id = 'compatibility-project'
        unit_id = 'compatibility-unit'
        action = $Action
        timestamp = '2026-09-01T00:00:00Z'
        executed = $false
        transition = $Transition
        status_before = $StatusBefore
        status_after = $StatusAfter
        current_unit_before = $CurrentUnitBefore
        current_unit_after = $CurrentUnitAfter
        preservation = [pscustomobject][ordered]@{
            git_mutation_performed = $false
            device_mutation_performed = $false
            remote_mutation_performed = $false
        }
        audit_receipt = [pscustomobject][ordered]@{
            path = $(if ($AuditPathKind -ceq 'history-archive') { 'history-archive/checkpoints/compatibility-checkpoint.json' } else { 'receipts/compatibility-receipt.json' })
            sha256 = '0' * 64
        }
        event_id = $null
    }
}

function Write-CompatibilityJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 32) + "`n"), [Text.UTF8Encoding]::new($false))
}

function New-DevelopmentAdmissionFixture {
    param(
        [Parameter(Mandatory)][string]$AdmissionId,
        [Parameter(Mandatory)][string]$UnitId,
        [ValidateSet('ordinary', 'blocked-successor')][string]$Kind
    )
    $hash = '1' * 64
    $preparation = [ordered]@{
        preparation_id = "$AdmissionId-preparation"
        receipt_path = "receipts/$AdmissionId-preparation.json"
        receipt_sha256 = $hash
        source_composition_path = "source-composition/$AdmissionId.json"
        source_composition_sha256 = $hash
    }
    $result = [ordered]@{
        schema = 'rusty.morphospace.workflow.development_unit_admission.v1'
        admission_id = $AdmissionId
        project_id = 'compatibility-project'
        unit_id = $UnitId
        preparation = $preparation
        agent_scope_assessment = [ordered]@{}
        unit = [ordered]@{ project_id = 'compatibility-project'; unit_id = $UnitId; status = 'proposed' }
        expected = [ordered]@{
            project_sha256 = $hash
            state_sha256 = $hash
            feature_lock_sha256 = $hash
            source_composition_path = "source-composition/$AdmissionId.json"
            source_composition_sha256 = $hash
            repository_map_path = 'repository-map.json'
            repository_map_sha256 = $hash
            events_sha256 = $hash
            events_length = 1
            event_tail_id = "$AdmissionId-tail"
        }
        does_not_prove = @('Compatibility fixture only.')
    }
    if ($Kind -ceq 'blocked-successor') {
        $result.admission_kind = 'blocked-successor'
        $result.preparation.terminal_binding_sha256 = $hash
        $result.blocked_successor = [ordered]@{ terminal_unit_id = 'terminal-unit'; terminal_binding_sha256 = $hash }
    }
    return $result
}

function New-AdmissionEventFixture {
    param([Parameter(Mandatory)][string]$AdmissionId, [Parameter(Mandatory)][string]$UnitId)
    return [pscustomobject][ordered]@{
        event_id = "$AdmissionId-admitted"
        unit_id = $UnitId
        event_type = 'state-transition'
        receipts = @("receipts/$AdmissionId.json")
    }
}

$corpus = [ordered]@{
    RetirePreparedPush = @('prepared-push-retired')
    ReconcilePreparedPublication = @('prepared-publication-reconstructed')
    ReconcilePreparedPushTransactionSuffix = @('prepared-push-transaction-suffix-reconciled')
    ResolveBlocker = @('blocker-resolved')
    CorrectResolvedBlockerEvidence = @('blocker-resolution-corrected')
    CorrectHistoricalBlockerResolutionIntentBinding = @('historical-blocker-resolution-intent-binding-corrected')
    CorrectCompletedTransitionSemantics = @('completed-transition-semantics-corrected')
    CorrectActiveReadOnlyDependencies = @('active-read-only-dependencies-corrected')
    CorrectActiveProjectRepositoryScope = @('active-project-repository-scope-corrected')
    CorrectActiveUnitContract = @('active-unit-contract-corrected')
    AmendActiveWriteScope = @('active-write-scope-amended')
    RecordHistoricalUnitCompatibilityProjection = @('historical-unit-compatibility-projected')
    PrepareDevelopmentEnvelope = @('idle-project-envelope-prepared')
    PrepareBlockedSuccessor = @('blocked-successor-prepared')
    SupersedeActive = @('active-superseded-by-proposed-to-active')
    AdmitDevelopmentUnit = @('development-unit-admitted', 'development-unit-already-admitted')
    FreezeCandidate = @('candidate-frozen', 'candidate-already-frozen')
    MaterializeInheritedCandidate = @('inherited-candidate-materialized', 'inherited-candidate-already-materialized')
    ArchiveHistoryCheckpoint = @('history-archive-checkpointed')
}

$producerContracts = [ordered]@{
    RetirePreparedPush = [ordered]@{ producer='scripts/PreparedPushRetirement.psm1'; owner_test='scripts/Test-WorkUnitAutomation.ps1' }
    ReconcilePreparedPublication = [ordered]@{ producer='scripts/PreparedPublicationReconstruction.psm1'; owner_test='scripts/Test-PreparedPublicationReconstruction.ps1' }
    ReconcilePreparedPushTransactionSuffix = [ordered]@{ producer='scripts/ReconcilePreparedPushTransactionSuffix.psm1'; owner_test='scripts/Test-PreparedPushTransactionSuffixReconciliation.ps1' }
    ResolveBlocker = [ordered]@{ producer='scripts/ResolveBlocker.psm1'; owner_test='scripts/Test-ResolveBlocker.ps1' }
    CorrectResolvedBlockerEvidence = [ordered]@{ producer='scripts/CorrectResolvedBlockerEvidence.psm1'; owner_test='scripts/Test-CorrectResolvedBlockerEvidence.ps1' }
    CorrectHistoricalBlockerResolutionIntentBinding = [ordered]@{ producer='scripts/CorrectHistoricalBlockerResolutionIntentBinding.psm1'; owner_test='scripts/Test-HistoricalBlockerResolutionIntentBindingCorrection.ps1' }
    CorrectCompletedTransitionSemantics = [ordered]@{ producer='scripts/CompletedTransitionSemanticCorrection.psm1'; owner_test='scripts/Test-CompletedTransitionSemanticCorrection.ps1' }
    CorrectActiveReadOnlyDependencies = [ordered]@{ producer='scripts/CorrectActiveReadOnlyDependencies.psm1'; owner_test='scripts/Test-CorrectActiveReadOnlyDependencies.ps1' }
    CorrectActiveProjectRepositoryScope = [ordered]@{ producer='scripts/CorrectActiveProjectRepositoryScope.psm1'; owner_test='scripts/Test-CorrectActiveProjectRepositoryScope.ps1' }
    CorrectActiveUnitContract = [ordered]@{ producer='scripts/CorrectActiveUnitContract.psm1'; owner_test='scripts/Test-CorrectActiveUnitContract.ps1' }
    AmendActiveWriteScope = [ordered]@{ producer='scripts/ActiveWriteScopeAmendment.psm1'; owner_test='scripts/Test-ActiveWriteScopeAmendment.ps1' }
    RecordHistoricalUnitCompatibilityProjection = [ordered]@{ producer='scripts/HistoricalUnitCompatibilityProjection.psm1'; owner_test='scripts/Test-HistoricalUnitCompatibilityProjection.ps1' }
    PrepareDevelopmentEnvelope = [ordered]@{ producer='scripts/DevelopmentEnvelopePreparation.psm1'; owner_test='scripts/Test-DevelopmentEnvelopePreparation.ps1' }
    PrepareBlockedSuccessor = [ordered]@{ producer='scripts/BlockedSuccessorPreparation.psm1'; owner_test='scripts/Test-BlockedSuccessorPreparation.ps1' }
    SupersedeActive = [ordered]@{ producer='scripts/ActiveUnitSupersession.psm1'; owner_test='scripts/Test-ActiveUnitSupersession.ps1' }
    AdmitDevelopmentUnit = [ordered]@{ producer='scripts/DevelopmentUnitAdmission.psm1'; owner_test='scripts/Test-DevelopmentUnitAdmission.ps1' }
    FreezeCandidate = [ordered]@{ producer='scripts/CandidateFreeze.psm1'; owner_test='scripts/Test-WorkUnitAutomation.ps1' }
    MaterializeInheritedCandidate = [ordered]@{ producer='scripts/InheritedCandidateMaterialization.psm1'; owner_test='scripts/Test-WorkUnitAutomation.ps1' }
    ArchiveHistoryCheckpoint = [ordered]@{ producer='scripts/lib/MorphospaceHistoryArchive.psm1'; owner_test='scripts/Test-HistoryArchiveCheckpoint.ps1' }
}

$receiptShapes = [ordered]@{}
foreach ($action in @($corpus.Keys)) {
    foreach ($transition in @($corpus[$action])) {
        $receiptShapes[[string]$transition] = [ordered]@{
            status_before = 'active'
            status_after = 'active'
            current_unit_before = 'compatibility-unit'
            current_unit_after = 'compatibility-unit'
            audit_path_kind = 'receipt'
        }
    }
}
$receiptShapes['idle-project-envelope-prepared'] = [ordered]@{status_before='accepted';status_after='accepted';current_unit_before=$null;current_unit_after=$null;audit_path_kind='receipt'}
$receiptShapes['blocked-successor-prepared'] = [ordered]@{status_before='blocked';status_after='blocked';current_unit_before=$null;current_unit_after=$null;audit_path_kind='receipt'}
$receiptShapes['active-superseded-by-proposed-to-active'] = [ordered]@{status_before='proposed';status_after='proposed';current_unit_before='terminal-unit';current_unit_after='terminal-unit';audit_path_kind='receipt'}
$receiptShapes['development-unit-admitted'] = [ordered]@{status_before=$null;status_after='proposed';current_unit_before=$null;current_unit_after=$null;audit_path_kind='receipt'}
$receiptShapes['development-unit-already-admitted'] = [ordered]@{status_before=$null;status_after='proposed';current_unit_before=$null;current_unit_after=$null;audit_path_kind='receipt'}
$receiptShapes['history-archive-checkpointed'] = [ordered]@{status_before='accepted';status_after='accepted';current_unit_before=$null;current_unit_after=$null;audit_path_kind='history-archive'}

Assert-AutomationReceiptCompatibility ((@($producerContracts.Keys) -join "`n") -ceq (@($corpus.Keys) -join "`n")) 'producer inventory drifted from the exact action corpus'
foreach ($action in @($producerContracts.Keys)) {
    $contract = $producerContracts[$action]
    $producerPath = Join-Path $repositoryRoot ([string]$contract.producer -replace '/', '\\')
    $ownerTestPath = Join-Path $repositoryRoot ([string]$contract.owner_test -replace '/', '\\')
    Assert-AutomationReceiptCompatibility ([IO.File]::Exists($producerPath)) "producer '$($contract.producer)' is absent"
    Assert-AutomationReceiptCompatibility ([IO.File]::Exists($ownerTestPath)) "owner test '$($contract.owner_test)' is absent"
    $producerSource = [IO.File]::ReadAllText($producerPath)
    Assert-AutomationReceiptCompatibility ($producerSource.Contains('rusty.morphospace.workflow.work_unit_automation_receipt.v2', [StringComparison]::Ordinal)) "producer '$($contract.producer)' no longer emits receipt v2"
    Assert-AutomationReceiptCompatibility ($producerSource.Contains("'$action'", [StringComparison]::Ordinal) -or $producerSource.Contains("`"$action`"", [StringComparison]::Ordinal)) "producer '$($contract.producer)' no longer binds action '$action'"
    foreach ($transition in @($corpus[$action])) {
        Assert-AutomationReceiptCompatibility ($producerSource.Contains([string]$transition, [StringComparison]::Ordinal)) "producer '$($contract.producer)' no longer binds transition '$transition'"
    }
}

Assert-ReceiptCorpusMatchesSchema -Corpus $corpus
$validatedPairCount = 0
foreach ($action in @($corpus.Keys)) {
    foreach ($transition in @($corpus[$action])) {
        $shape = $receiptShapes[[string]$transition]
        $receipt = New-CanonicalAutomationReceipt -Action ([string]$action) -Transition ([string]$transition) -StatusBefore $shape.status_before -StatusAfter ([string]$shape.status_after) -CurrentUnitBefore $shape.current_unit_before -CurrentUnitAfter $shape.current_unit_after -AuditPathKind ([string]$shape.audit_path_kind)
        Assert-AutomationReceiptCompatibility (Test-ReceiptPairAllowed -Corpus $corpus -Action ([string]$action) -Transition ([string]$transition)) "corpus rejected its own '$action'/'$transition' pair"
        Assert-AutomationReceiptCompatibility (Test-AutomationReceiptSchema -Receipt $receipt) "canonical '$action'/'$transition' receipt failed the v2 schema"
        $validatedPairCount++
    }
}
Assert-AutomationReceiptCompatibility ($validatedPairCount -eq 22) "expected 22 canonical action/transition receipts, observed $validatedPairCount"

$admissionShapeDamage = New-CanonicalAutomationReceipt -Action 'AdmitDevelopmentUnit' -Transition 'development-unit-admitted'
Assert-AutomationReceiptCompatibility (-not (Test-AutomationReceiptSchema -Receipt $admissionShapeDamage)) 'schema accepted an admission receipt with a fabricated prior status'
Assert-AutomationReceiptCompatibility ($null -eq $receiptShapes['development-unit-admitted'].status_before -and $null -ne $admissionShapeDamage.status_before) 'admission absent-status compatibility damage was not distinguished'
$ordinaryNullDamage = New-CanonicalAutomationReceipt -Action 'RetirePreparedPush' -Transition 'prepared-push-retired' -StatusBefore $null
Assert-AutomationReceiptCompatibility (-not (Test-AutomationReceiptSchema -Receipt $ordinaryNullDamage)) 'schema accepted null prior status for a non-admission producer'
Assert-AutomationReceiptCompatibility ($null -ne $receiptShapes['prepared-push-retired'].status_before -and $null -eq $ordinaryNullDamage.status_before) 'ordinary producer null-status compatibility damage was not distinguished'

$structuralBase = New-CanonicalAutomationReceipt -Action 'RetirePreparedPush' -Transition 'prepared-push-retired'
$dryEventDamage = Copy-AutomationReceiptValue $structuralBase
$dryEventDamage.event_id = 'fabricated-dry-event'
Assert-AutomationReceiptCompatibility (-not (Test-AutomationReceiptSchema -Receipt $dryEventDamage)) 'schema accepted an event identity on an unexecuted receipt'
$executedNullEvent = Copy-AutomationReceiptValue $structuralBase
$executedNullEvent.executed = $true
Assert-AutomationReceiptCompatibility (Test-AutomationReceiptSchema -Receipt $executedNullEvent) 'schema incorrectly required an event identity for every executed already/idempotent outcome'
foreach ($damage in @('missing-action', 'unknown-property', 'wrong-preservation', 'bad-audit-hash')) {
    $damaged = Copy-AutomationReceiptValue $structuralBase
    switch ($damage) {
        'missing-action' { $damaged.PSObject.Properties.Remove('action') }
        'unknown-property' { $damaged | Add-Member -NotePropertyName untrusted -NotePropertyValue $true }
        'wrong-preservation' { $damaged.preservation.git_mutation_performed = $true }
        'bad-audit-hash' { $damaged.audit_receipt.sha256 = 'not-a-hash' }
    }
    Assert-AutomationReceiptCompatibility (-not (Test-AutomationReceiptSchema -Receipt $damaged)) "schema accepted $damage damage"
}
$wrongPair = New-CanonicalAutomationReceipt -Action 'RetirePreparedPush' -Transition 'blocker-resolved'
Assert-AutomationReceiptCompatibility (-not (Test-AutomationReceiptSchema -Receipt $wrongPair)) 'schema accepted a cross-action transition pair'
Assert-AutomationReceiptCompatibility (-not (Test-ReceiptPairAllowed -Corpus $corpus -Action $wrongPair.action -Transition $wrongPair.transition)) 'compatibility corpus accepted a valid-enum cross-action transition'
$driftedCorpus = [ordered]@{}
foreach ($action in @($corpus.Keys | Select-Object -Skip 1)) { $driftedCorpus[$action] = @($corpus[$action]) }
$corpusDriftRejected = $false
try { Assert-ReceiptCorpusMatchesSchema -Corpus $driftedCorpus } catch { $corpusDriftRejected = $_.Exception.Message -like '*schema action enum drifted*' }
Assert-AutomationReceiptCompatibility $corpusDriftRejected 'schema/corpus action drift was accepted'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('automation-receipt-v2-compatibility-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory((Join-Path $testRoot 'receipts')) | Out-Null
    $ordinaryId = 'ordinary-admission'
    $blockedId = 'blocked-admission'
    $secondBlockedId = 'second-blocked-admission'
    Write-CompatibilityJson -Path (Join-Path $testRoot "receipts\$ordinaryId.json") -Value (New-DevelopmentAdmissionFixture -AdmissionId $ordinaryId -UnitId 'successor-unit' -Kind ordinary)
    Write-CompatibilityJson -Path (Join-Path $testRoot "receipts\$blockedId.json") -Value (New-DevelopmentAdmissionFixture -AdmissionId $blockedId -UnitId 'successor-unit' -Kind blocked-successor)
    Write-CompatibilityJson -Path (Join-Path $testRoot "receipts\$secondBlockedId.json") -Value (New-DevelopmentAdmissionFixture -AdmissionId $secondBlockedId -UnitId 'successor-unit' -Kind blocked-successor)

    $ordinaryEvent = New-AdmissionEventFixture -AdmissionId $ordinaryId -UnitId 'successor-unit'
    $blockedEvent = New-AdmissionEventFixture -AdmissionId $blockedId -UnitId 'successor-unit'
    $secondBlockedEvent = New-AdmissionEventFixture -AdmissionId $secondBlockedId -UnitId 'successor-unit'
    $ordinaryRoute = & $automationModule { param($arguments) Get-MorphospaceReadyTerminalReleaseRoute @arguments } @{ WorkspaceRoot = $testRoot; UnitId = 'successor-unit'; Events = @($ordinaryEvent) }
    $blockedRoute = & $automationModule { param($arguments) Get-MorphospaceReadyTerminalReleaseRoute @arguments } @{ WorkspaceRoot = $testRoot; UnitId = 'successor-unit'; Events = @($blockedEvent) }
    $emptyHistoryRoute = & $automationModule { param($arguments) Get-MorphospaceReadyTerminalReleaseRoute @arguments } @{ WorkspaceRoot = $testRoot; UnitId = 'successor-unit'; Events = @() }
    $nonAdmissionHistoryRoute = & $automationModule { param($arguments) Get-MorphospaceReadyTerminalReleaseRoute @arguments } @{ WorkspaceRoot = $testRoot; UnitId = 'successor-unit'; Events = @([pscustomobject]@{event_id='successor-unit-ready-withdrawn-0001';unit_id='successor-unit';event_type='state-transition';receipts=@()}) }
    Assert-AutomationReceiptCompatibility ([string]$ordinaryRoute -ceq 'legacy-v1') 'ordinary admission did not select legacy release-v1'
    Assert-AutomationReceiptCompatibility ([string]$blockedRoute -ceq 'blocked-successor-v2') 'blocked-successor admission did not select release-v2'
    Assert-AutomationReceiptCompatibility ([string]$emptyHistoryRoute -ceq 'legacy-v1') 'empty pre-admission history did not retain legacy release-v1 compatibility'
    Assert-AutomationReceiptCompatibility ([string]$nonAdmissionHistoryRoute -ceq 'legacy-v1') 'non-admission lifecycle history was misclassified as an admission chain'

    $malformedEvent = Copy-AutomationReceiptValue $blockedEvent
    $malformedEvent.receipts = @($malformedEvent.receipts[0], $malformedEvent.receipts[0])
    $malformedRejected = $false
    try { & $automationModule { param($arguments) Get-MorphospaceReadyTerminalReleaseRoute @arguments } @{ WorkspaceRoot = $testRoot; UnitId = 'successor-unit'; Events = @($malformedEvent) } | Out-Null } catch { $malformedRejected = $_.Exception.Message -like '*malformed or ambiguous latest admission event*' }
    Assert-AutomationReceiptCompatibility $malformedRejected 'malformed admission event silently fell back to release-v1'
    $ambiguousRejected = $false
    try { & $automationModule { param($arguments) Get-MorphospaceReadyTerminalReleaseRoute @arguments } @{ WorkspaceRoot = $testRoot; UnitId = 'successor-unit'; Events = @($blockedEvent, $secondBlockedEvent) } | Out-Null } catch { $ambiguousRejected = $_.Exception.Message -like '*malformed or ambiguous admission chain*' }
    Assert-AutomationReceiptCompatibility $ambiguousRejected 'ambiguous admission chain silently selected one route'

    $foreignSelector = [pscustomobject]@{ unit_id = 'terminal-unit' }
    & $automationModule { param($arguments) Assert-MorphospaceReadyTerminalReleaseSelectorBinding @arguments } @{ Route = 'blocked-successor-v2'; UnitId = 'successor-unit'; Selection = $foreignSelector }
    $absentRejected = $false
    try { & $automationModule { param($arguments) Assert-MorphospaceReadyTerminalReleaseSelectorBinding @arguments } @{ Route = 'blocked-successor-v2'; UnitId = 'successor-unit'; Selection = $null } } catch { $absentRejected = $_.Exception.Message -like '*requires the preserved differing terminal selector binding*' }
    Assert-AutomationReceiptCompatibility $absentRejected 'blocked-successor release-v2 accepted an absent selector binding'
    $selfBoundRejected = $false
    try { & $automationModule { param($arguments) Assert-MorphospaceReadyTerminalReleaseSelectorBinding @arguments } @{ Route = 'blocked-successor-v2'; UnitId = 'successor-unit'; Selection = ([pscustomobject]@{ unit_id = 'successor-unit' }) } } catch { $selfBoundRejected = $_.Exception.Message -like '*rejects a selector binding rebound to the successor*' }
    Assert-AutomationReceiptCompatibility $selfBoundRejected 'blocked-successor release-v2 accepted a self-bound selector'
    & $automationModule { param($arguments) Assert-MorphospaceReadyTerminalReleaseSelectorBinding @arguments } @{ Route = 'legacy-v1'; UnitId = 'successor-unit'; Selection = $null }
    & $automationModule { param($arguments) Assert-MorphospaceReadyTerminalReleaseSelectorBinding @arguments } @{ Route = 'legacy-v1'; UnitId = 'successor-unit'; Selection = ([pscustomobject]@{ unit_id = 'successor-unit' }) }
} finally {
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host "Automation receipt-v2 compatibility self-test passed: $validatedPairCount canonical action/transition receipts; ordinary/v2 Ready dispatch and selector invariants exact."
