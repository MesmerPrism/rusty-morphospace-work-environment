param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Inspect", "PrepareDevelopmentEnvelope", "ReprepareRetiredDevelopmentEnvelope", "PrepareBlockedSuccessor", "SupersedeActive", "ArchiveHistoryCheckpoint", "AdmitDevelopmentUnit", "RetireProposed", "Ready", "WithdrawReady", "Claim", "Resume", "CompleteInstructionSurfaces", "AmendActiveWriteScope", "FreezeCandidate", "RematerializeValidatingCandidate", "MaterializeInheritedCandidate", "CorrectActiveReadOnlyDependencies", "CorrectActiveProjectRepositoryScope", "CorrectActiveUnitContract", "RecordHistoricalUnitCompatibilityProjection", "BeginValidation", "ReturnToActive", "PreflightValidation", "RecordValidation", "Accept", "PreparePush", "RetirePreparedPush", "ReconcilePreparedPublication", "ReconcilePreparedPushTransactionSuffix", "ResolveBlocker", "CorrectResolvedBlockerEvidence", "CorrectHistoricalBlockerResolutionIntentBinding", "CorrectCompletedTransitionSemantics", "NormalizeEventLedgerPrefix", "RecordPublication", "Recover", "ReconcilePublication", "AdoptPublishedPlanningAuthority", "ReconcilePlanningSuffixRewrite", "ReconcilePublishedPrerequisiteSuffix", "ReconcileExecutedPreparedPublication")]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [string]$UnitId = "",
    [string]$RepoMapPath = "",
    [string]$RevisionsPath = "",
    [ValidateSet("pass", "partial", "fail", "blocked")][string]$ValidationResult = "pass",
    [string]$ValidationReceipt = "",
    [string]$RecoveryReceipt = "",
    [string]$PublicationClosure = "",
    [string]$PublishedPlanningAuthorityAdoption = "",
    [string]$PublicationAccounting = "",
    [string]$PlanningSuffixRewriteRecovery = "",
    [string]$PublishedPrerequisiteSuffixReconciliation = "",
    [string]$ExecutedPreparedPublicationReconciliation = "",
    [string]$PublicationOrderingInterruption = "",
    [string]$PreparedPushRetirement = "",
    [string]$PreparedPublicationReconstruction = "",
    [string]$PreparedPushTransactionSuffixReconciliation = "",
    [string]$ExpectedPreparedPushTransactionSuffixReconciliationSha256 = "",
    [string]$BlockerResolutionReceipt = "",
    [string]$BlockerResolutionCorrectionReceipt = "",
    [string]$HistoricalBlockerResolutionIntentBindingCorrection = "",
    [string]$ExpectedHistoricalBlockerResolutionIntentBindingCorrectionSha256 = "",
    [string]$CompletedTransitionSemanticCorrection = "",
    [string]$ReadOnlyDependencyCorrection = "",
    [string]$ExpectedReadOnlyDependencyCorrectionSha256 = "",
    [string]$ProjectRepositoryScopeCorrection = "",
    [string]$ExpectedProjectRepositoryScopeCorrectionSha256 = "",
    [string]$ActiveUnitContractCorrection = "",
    [string]$ExpectedActiveUnitContractCorrectionSha256 = "",
    [string]$ActiveWriteScopeAmendment = "",
    [string]$ExpectedActiveWriteScopeAmendmentSha256 = "",
    [string]$DevelopmentUnitAdmission = "",
    [string]$ExpectedDevelopmentUnitAdmissionSha256 = "",
    [string]$DevelopmentEnvelopePreparation = "",
    [string]$ExpectedDevelopmentEnvelopePreparationSha256 = "",
    [string]$DevelopmentEnvelopeRepreparation = "",
    [string]$ExpectedDevelopmentEnvelopeRepreparationSha256 = "",
    [string]$BlockedSuccessorPreparation = "",
    [string]$ExpectedBlockedSuccessorPreparationSha256 = "",
    [string]$ActiveUnitSupersession = "",
    [string]$ExpectedActiveUnitSupersessionSha256 = "",
    [string]$HistoryArchiveCheckpoint = "",
    [string]$ExpectedHistoryArchiveCheckpointSha256 = "",
    [string]$CandidateFreeze = "",
    [string]$ExpectedCandidateFreezeSha256 = "",
    [string]$ValidatingCandidateRematerialization = "",
    [string]$ExpectedValidatingCandidateRematerializationSha256 = "",
    [string]$ReplacementSourceComposition = "",
    [string]$MaterializationRoot = "",
    [string]$HistoricalUnitCompatibilityProjection = "",
    [string]$ExpectedHistoricalUnitCompatibilityProjectionSha256 = "",
    [string]$LedgerPrefixNormalizationId = "",
    [string]$ExpectedRepositoryHead = "",
    [string]$ExpectedProjectSha256 = "",
    [string]$ExpectedStateSha256 = "",
    [string]$ExpectedUnitSha256 = "",
    [string]$ExpectedUnitRawSha256 = "",
    [string]$ExpectedEventsSha256 = "",
    [long]$ExpectedEventsLength = -1,
    [string]$ExpectedEventTailId = "",
    [string]$ReplacementUnitId = "",
    [ValidateSet("contract-invalid")][string]$RetirementReason = "contract-invalid",
    [string]$ExpectedProposedRetirementBindingSha256 = "",
    [string]$ExpectedIntentSha256 = "",
    [string]$AdoptionReceipt = "",
    [string]$InstructionCompletionId = "",
    [string[]]$InstructionSurfaceIds = @(),
    [string]$ExpectedInstructionObservationSha256 = "",
    [ValidateSet("quick", "standard", "deep")][string]$ValidationTier = "standard",
    [string]$ValidationSelector = "",
    [string]$ExpectedValidationSelectorSha256 = "",
    [string]$ValidationEvidencePath = "",
    [string[]]$DeviceSerials = @(),
    [string]$AuthorityRunnerPath = "",
    [string[]]$AuthorityRunnerArguments = @(),
    [string]$Timestamp = "",
    [string]$OutPath = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "WorkUnitAutomation.psm1") -Force

if ($Action -eq "PrepareDevelopmentEnvelope") {
    if (-not $DevelopmentEnvelopePreparation -or -not $OutPath) { throw "PrepareDevelopmentEnvelope requires DevelopmentEnvelopePreparation and OutPath." }
    Import-Module (Join-Path $PSScriptRoot "DevelopmentEnvelopePreparation.psm1") -Force
    Invoke-MorphospacePrepareDevelopmentEnvelope -WorkspaceRoot $WorkspaceRoot -DevelopmentEnvelopePreparation $DevelopmentEnvelopePreparation -ExpectedDevelopmentEnvelopePreparationSha256 $ExpectedDevelopmentEnvelopePreparationSha256 -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute | ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "ReprepareRetiredDevelopmentEnvelope") {
    if (-not $DevelopmentEnvelopeRepreparation -or -not $OutPath) { throw "ReprepareRetiredDevelopmentEnvelope requires DevelopmentEnvelopeRepreparation and OutPath." }
    Import-Module (Join-Path $PSScriptRoot "DevelopmentEnvelopeRepreparation.psm1") -Force
    Invoke-MorphospaceReprepareRetiredDevelopmentEnvelope -WorkspaceRoot $WorkspaceRoot -DevelopmentEnvelopeRepreparation $DevelopmentEnvelopeRepreparation -ExpectedDevelopmentEnvelopeRepreparationSha256 $ExpectedDevelopmentEnvelopeRepreparationSha256 -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute | ConvertTo-Json -Depth 64
    return
}
if ($Action -eq "PrepareBlockedSuccessor") {
    if (-not $BlockedSuccessorPreparation -or -not $OutPath) { throw "PrepareBlockedSuccessor requires BlockedSuccessorPreparation and OutPath." }
    Import-Module (Join-Path $PSScriptRoot "BlockedSuccessorPreparation.psm1") -Force
    Invoke-MorphospacePrepareBlockedSuccessor -WorkspaceRoot $WorkspaceRoot -BlockedSuccessorPreparation $BlockedSuccessorPreparation -ExpectedBlockedSuccessorPreparationSha256 $ExpectedBlockedSuccessorPreparationSha256 -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute | ConvertTo-Json -Depth 64
    return
}
if ($Action -eq "SupersedeActive") {
    if (-not $ActiveUnitSupersession -or -not $RepoMapPath -or -not $OutPath) { throw "SupersedeActive requires ActiveUnitSupersession, RepoMapPath, and OutPath." }
    Import-Module (Join-Path $PSScriptRoot "ActiveUnitSupersession.psm1") -Force
    Invoke-MorphospaceSupersedeActive -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -RepoMapPath $RepoMapPath -ActiveUnitSupersession $ActiveUnitSupersession -ExpectedActiveUnitSupersessionSha256 $ExpectedActiveUnitSupersessionSha256 -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute | ConvertTo-Json -Depth 64
    return
}
if ($Action -eq "ArchiveHistoryCheckpoint") {
    if (-not $HistoryArchiveCheckpoint -or -not $OutPath) { throw "ArchiveHistoryCheckpoint requires HistoryArchiveCheckpoint and OutPath." }
    Import-Module (Join-Path $PSScriptRoot "HistoryArchiveCheckpoint.psm1") -Force
    Invoke-MorphospaceHistoryArchiveCheckpoint -WorkspaceRoot $WorkspaceRoot -HistoryArchiveCheckpoint $HistoryArchiveCheckpoint -ExpectedHistoryArchiveCheckpointSha256 $ExpectedHistoryArchiveCheckpointSha256 -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute | ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "AdmitDevelopmentUnit") {
    if (-not $DevelopmentUnitAdmission -or -not $OutPath) { throw "AdmitDevelopmentUnit requires DevelopmentUnitAdmission and OutPath." }
    Import-Module (Join-Path $PSScriptRoot "DevelopmentUnitAdmission.psm1") -Force
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $WorkspaceRoot -DevelopmentUnitAdmission $DevelopmentUnitAdmission -ExpectedDevelopmentUnitAdmissionSha256 $ExpectedDevelopmentUnitAdmissionSha256 -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute | ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "FreezeCandidate") {
    if (-not $CandidateFreeze -or -not $OutPath) { throw "FreezeCandidate requires CandidateFreeze and OutPath." }
    Import-Module (Join-Path $PSScriptRoot "CandidateFreeze.psm1") -Force
    Invoke-MorphospaceFreezeCandidate -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -CandidateFreeze $CandidateFreeze -ExpectedCandidateFreezeSha256 $ExpectedCandidateFreezeSha256 -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute | ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "RematerializeValidatingCandidate") {
    if (-not $ValidatingCandidateRematerialization -or -not $ReplacementSourceComposition -or -not $RepoMapPath -or -not $OutPath) {
        throw "RematerializeValidatingCandidate requires ValidatingCandidateRematerialization, ReplacementSourceComposition, RepoMapPath, and OutPath."
    }
    Import-Module (Join-Path $PSScriptRoot "ValidatingCandidateRematerialization.psm1") -Force
    Invoke-MorphospaceRematerializeValidatingCandidate -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -RepoMapPath $RepoMapPath -CandidateFreeze $ValidatingCandidateRematerialization `
        -SourceCompositionLock $ReplacementSourceComposition `
        -ExpectedCandidateFreezeSha256 $ExpectedValidatingCandidateRematerializationSha256 `
        -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 64
    return
}
if ($Action -eq "MaterializeInheritedCandidate") {
    if (-not $RepoMapPath -or -not $MaterializationRoot -or -not $OutPath) { throw "MaterializeInheritedCandidate requires RepoMapPath, MaterializationRoot, and OutPath." }
    Import-Module (Join-Path $PSScriptRoot "InheritedCandidateMaterialization.psm1") -Force
    Invoke-MorphospaceMaterializeInheritedCandidate -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -RepoMapPath $RepoMapPath -MaterializationRoot $MaterializationRoot -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute | ConvertTo-Json -Depth 32
    return
}

if ($Action -eq "RetirePreparedPush") {
    if (-not $PreparedPushRetirement) { throw "RetirePreparedPush requires PreparedPushRetirement." }
    if (-not $RepoMapPath) { throw "RetirePreparedPush requires RepoMapPath." }
    Import-Module (Join-Path $PSScriptRoot "PreparedPushRetirement.psm1") -Force
    try {
        Invoke-MorphospacePreparedPushRetirement -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
            -RepoMapPath $RepoMapPath -RetirementReceipt $PreparedPushRetirement `
            -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
            ConvertTo-Json -Depth 32
    } catch { throw "$($_.Exception.Message) [$($_.ScriptStackTrace)]" }
    return
}
if ($Action -eq "ReconcilePreparedPublication") {
    if (-not $PreparedPublicationReconstruction) { throw "ReconcilePreparedPublication requires PreparedPublicationReconstruction." }
    if (-not $RepoMapPath) { throw "ReconcilePreparedPublication requires RepoMapPath." }
    Import-Module (Join-Path $PSScriptRoot "PreparedPublicationReconstruction.psm1") -Force
    Invoke-MorphospacePreparedPublicationReconstruction -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -RepoMapPath $RepoMapPath -ReconstructionReceipt $PreparedPublicationReconstruction `
        -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "ReconcilePreparedPushTransactionSuffix") {
    if (-not $PreparedPushTransactionSuffixReconciliation) { throw "ReconcilePreparedPushTransactionSuffix requires PreparedPushTransactionSuffixReconciliation." }
    if (-not $RepoMapPath) { throw "ReconcilePreparedPushTransactionSuffix requires RepoMapPath." }
    if (-not $OutPath) { throw "ReconcilePreparedPushTransactionSuffix requires OutPath." }
    Import-Module (Join-Path $PSScriptRoot "ReconcilePreparedPushTransactionSuffix.psm1") -Force
    Invoke-MorphospaceReconcilePreparedPushTransactionSuffix -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -RepoMapPath $RepoMapPath -Reconciliation $PreparedPushTransactionSuffixReconciliation `
        -ExpectedReconciliationSha256 $ExpectedPreparedPushTransactionSuffixReconciliationSha256 `
        -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "ResolveBlocker") {
    if (-not $BlockerResolutionReceipt) { throw "ResolveBlocker requires BlockerResolutionReceipt." }
    if (-not $RepoMapPath) { throw "ResolveBlocker requires RepoMapPath." }
    Import-Module (Join-Path $PSScriptRoot "ResolveBlocker.psm1") -Force
    Invoke-MorphospaceResolveBlocker -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -RepoMapPath $RepoMapPath -BlockerResolutionReceipt $BlockerResolutionReceipt `
        -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "CorrectResolvedBlockerEvidence") {
    if (-not $BlockerResolutionCorrectionReceipt) { throw "CorrectResolvedBlockerEvidence requires BlockerResolutionCorrectionReceipt." }
    if (-not $RepoMapPath) { throw "CorrectResolvedBlockerEvidence requires RepoMapPath." }
    Import-Module (Join-Path $PSScriptRoot "CorrectResolvedBlockerEvidence.psm1") -Force
    Invoke-MorphospaceCorrectResolvedBlockerEvidence -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -RepoMapPath $RepoMapPath -CorrectionReceipt $BlockerResolutionCorrectionReceipt `
        -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "CorrectHistoricalBlockerResolutionIntentBinding") {
    if (-not $HistoricalBlockerResolutionIntentBindingCorrection) { throw "CorrectHistoricalBlockerResolutionIntentBinding requires HistoricalBlockerResolutionIntentBindingCorrection." }
    if (-not $OutPath) { throw "CorrectHistoricalBlockerResolutionIntentBinding requires OutPath." }
    Import-Module (Join-Path $PSScriptRoot "CorrectHistoricalBlockerResolutionIntentBinding.psm1") -Force
    Invoke-MorphospaceCorrectHistoricalBlockerResolutionIntentBinding -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -CorrectionReceipt $HistoricalBlockerResolutionIntentBindingCorrection `
        -ExpectedCorrectionSha256 $ExpectedHistoricalBlockerResolutionIntentBindingCorrectionSha256 `
        -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "CorrectCompletedTransitionSemantics") {
    if (-not $CompletedTransitionSemanticCorrection) { throw "CorrectCompletedTransitionSemantics requires CompletedTransitionSemanticCorrection." }
    Import-Module (Join-Path $PSScriptRoot "CompletedTransitionSemanticCorrection.psm1") -Force
    Invoke-MorphospaceCompletedTransitionSemanticCorrection -WorkspaceRoot $WorkspaceRoot `
        -CorrectionReceipt $CompletedTransitionSemanticCorrection -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "CorrectActiveReadOnlyDependencies") {
    if (-not $ReadOnlyDependencyCorrection) { throw "CorrectActiveReadOnlyDependencies requires ReadOnlyDependencyCorrection." }
    if (-not $RepoMapPath) { throw "CorrectActiveReadOnlyDependencies requires RepoMapPath." }
    if (-not $OutPath) { throw "CorrectActiveReadOnlyDependencies requires OutPath." }
    Import-Module (Join-Path $PSScriptRoot "CorrectActiveReadOnlyDependencies.psm1") -Force
    Invoke-MorphospaceCorrectActiveReadOnlyDependencies -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -RepoMapPath $RepoMapPath -ReadOnlyDependencyCorrection $ReadOnlyDependencyCorrection `
        -ExpectedReadOnlyDependencyCorrectionSha256 $ExpectedReadOnlyDependencyCorrectionSha256 `
        -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "CorrectActiveProjectRepositoryScope") {
    if (-not $ProjectRepositoryScopeCorrection) { throw "CorrectActiveProjectRepositoryScope requires ProjectRepositoryScopeCorrection." }
    if (-not $OutPath) { throw "CorrectActiveProjectRepositoryScope requires OutPath." }
    Import-Module (Join-Path $PSScriptRoot "CorrectActiveProjectRepositoryScope.psm1") -Force
    Invoke-MorphospaceCorrectActiveProjectRepositoryScope -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -ProjectRepositoryScopeCorrection $ProjectRepositoryScopeCorrection `
        -ExpectedProjectRepositoryScopeCorrectionSha256 $ExpectedProjectRepositoryScopeCorrectionSha256 `
        -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "CorrectActiveUnitContract") {
    if (-not $ActiveUnitContractCorrection) { throw "CorrectActiveUnitContract requires ActiveUnitContractCorrection." }
    if (-not $OutPath) { throw "CorrectActiveUnitContract requires OutPath." }
    Import-Module (Join-Path $PSScriptRoot "CorrectActiveUnitContract.psm1") -Force
    Invoke-MorphospaceCorrectActiveUnitContract -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -ActiveUnitContractCorrection $ActiveUnitContractCorrection `
        -ExpectedActiveUnitContractCorrectionSha256 $ExpectedActiveUnitContractCorrectionSha256 `
        -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "AmendActiveWriteScope") {
    if (-not $ActiveWriteScopeAmendment) { throw "AmendActiveWriteScope requires ActiveWriteScopeAmendment." }
    if (-not $OutPath) { throw "AmendActiveWriteScope requires OutPath." }
    Import-Module (Join-Path $PSScriptRoot "ActiveWriteScopeAmendment.psm1") -Force
    Invoke-MorphospaceAmendActiveWriteScope -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -ActiveWriteScopeAmendment $ActiveWriteScopeAmendment `
        -ExpectedActiveWriteScopeAmendmentSha256 $ExpectedActiveWriteScopeAmendmentSha256 `
        -Timestamp $Timestamp -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "RecordHistoricalUnitCompatibilityProjection") {
    if (-not $HistoricalUnitCompatibilityProjection) { throw "RecordHistoricalUnitCompatibilityProjection requires HistoricalUnitCompatibilityProjection." }
    if (-not $OutPath) { throw "RecordHistoricalUnitCompatibilityProjection requires OutPath." }
    Import-Module (Join-Path $PSScriptRoot "HistoricalUnitCompatibilityProjection.psm1") -Force
    Invoke-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId `
        -CompatibilityProjection $HistoricalUnitCompatibilityProjection `
        -ExpectedCompatibilityProjectionSha256 $ExpectedHistoricalUnitCompatibilityProjectionSha256 `
        -OutPath $OutPath -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}
if ($Action -eq "NormalizeEventLedgerPrefix") {
    foreach ($required in @(
        [pscustomobject]@{name='LedgerPrefixNormalizationId';value=$LedgerPrefixNormalizationId},
        [pscustomobject]@{name='UnitId';value=$UnitId},
        [pscustomobject]@{name='ExpectedRepositoryHead';value=$ExpectedRepositoryHead},
        [pscustomobject]@{name='ExpectedProjectSha256';value=$ExpectedProjectSha256},
        [pscustomobject]@{name='ExpectedStateSha256';value=$ExpectedStateSha256},
        [pscustomobject]@{name='ExpectedUnitSha256';value=$ExpectedUnitSha256},
        [pscustomobject]@{name='ExpectedEventsSha256';value=$ExpectedEventsSha256},
        [pscustomobject]@{name='ExpectedEventTailId';value=$ExpectedEventTailId}
    )) {
        if (-not [string]$required.value) { throw "NormalizeEventLedgerPrefix requires $([string]$required.name)." }
    }
    if ($ExpectedEventsLength -lt 0) { throw "NormalizeEventLedgerPrefix requires ExpectedEventsLength." }
    if ($Execute -and -not $ExpectedIntentSha256) { throw "Executed NormalizeEventLedgerPrefix requires ExpectedIntentSha256 from its dry-run." }
    Import-Module (Join-Path $PSScriptRoot "EventLedgerPrefixNormalization.psm1") -Force
    Invoke-MorphospaceEventLedgerPrefixNormalization -WorkspaceRoot $WorkspaceRoot `
        -NormalizationId $LedgerPrefixNormalizationId -UnitId $UnitId `
        -ExpectedRepositoryHead $ExpectedRepositoryHead -ExpectedProjectSha256 $ExpectedProjectSha256 `
        -ExpectedStateSha256 $ExpectedStateSha256 -ExpectedUnitSha256 $ExpectedUnitSha256 `
        -ExpectedEventsSha256 $ExpectedEventsSha256 -ExpectedEventsLength $ExpectedEventsLength `
        -ExpectedEventTailId $ExpectedEventTailId -ExpectedIntentSha256 $ExpectedIntentSha256 `
        -Timestamp $Timestamp -Execute:$Execute |
        ConvertTo-Json -Depth 32
    return
}

$arguments = @{
    Action = $Action
    WorkspaceRoot = $WorkspaceRoot
    UnitId = $UnitId
    RepoMapPath = $RepoMapPath
    RevisionsPath = $RevisionsPath
    ValidationResult = $ValidationResult
    ValidationReceipt = $ValidationReceipt
    RecoveryReceipt = $RecoveryReceipt
    PublicationClosure = $PublicationClosure
    PublishedPlanningAuthorityAdoption = $PublishedPlanningAuthorityAdoption
    PublicationAccounting = $PublicationAccounting
    PlanningSuffixRewriteRecovery = $PlanningSuffixRewriteRecovery
    PublishedPrerequisiteSuffixReconciliation = $PublishedPrerequisiteSuffixReconciliation
    ExecutedPreparedPublicationReconciliation = $ExecutedPreparedPublicationReconciliation
    PublicationOrderingInterruption = $PublicationOrderingInterruption
    AdoptionReceipt = $AdoptionReceipt
    InstructionCompletionId = $InstructionCompletionId
    InstructionSurfaceIds = $InstructionSurfaceIds
    ExpectedUnitSha256 = $ExpectedUnitSha256
    ExpectedUnitRawSha256 = $ExpectedUnitRawSha256
    ExpectedStateSha256 = $ExpectedStateSha256
    ExpectedEventsSha256 = $ExpectedEventsSha256
    ExpectedEventsLength = $ExpectedEventsLength
    ExpectedEventTailId = $ExpectedEventTailId
    ReplacementUnitId = $ReplacementUnitId
    RetirementReason = $RetirementReason
    ExpectedProposedRetirementBindingSha256 = $ExpectedProposedRetirementBindingSha256
    ExpectedInstructionObservationSha256 = $ExpectedInstructionObservationSha256
    ValidationTier = $ValidationTier
    ValidationSelector = $ValidationSelector
    ExpectedValidationSelectorSha256 = $ExpectedValidationSelectorSha256
    ValidationEvidencePath = $ValidationEvidencePath
    DeviceSerials = $DeviceSerials
    AuthorityRunnerPath = $AuthorityRunnerPath
    AuthorityRunnerArguments = $AuthorityRunnerArguments
    Timestamp = $Timestamp
    OutPath = $OutPath
    Execute = $Execute
}

Invoke-MorphospaceWorkUnitAutomation @arguments | ConvertTo-Json -Depth 32
