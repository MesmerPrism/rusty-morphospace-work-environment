param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Inspect", "Ready", "Claim", "Resume", "BeginValidation", "PreflightValidation", "RecordValidation", "Accept", "PreparePush", "RetirePreparedPush", "ReconcilePreparedPublication", "ResolveBlocker", "CorrectResolvedBlockerEvidence", "NormalizeEventLedgerPrefix", "RecordPublication", "Recover", "ReconcilePublication", "AdoptPublishedPlanningAuthority", "ReconcilePlanningSuffixRewrite", "ReconcilePublishedPrerequisiteSuffix")]
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
    [string]$PublicationOrderingInterruption = "",
    [string]$PreparedPushRetirement = "",
    [string]$PreparedPublicationReconstruction = "",
    [string]$BlockerResolutionReceipt = "",
    [string]$BlockerResolutionCorrectionReceipt = "",
    [string]$LedgerPrefixNormalizationId = "",
    [string]$ExpectedRepositoryHead = "",
    [string]$ExpectedProjectSha256 = "",
    [string]$ExpectedStateSha256 = "",
    [string]$ExpectedUnitSha256 = "",
    [string]$ExpectedEventsSha256 = "",
    [long]$ExpectedEventsLength = -1,
    [string]$ExpectedEventTailId = "",
    [string]$ExpectedIntentSha256 = "",
    [string]$AdoptionReceipt = "",
    [ValidateSet("quick", "standard", "deep")][string]$ValidationTier = "standard",
    [string[]]$DeviceSerials = @(),
    [string]$AuthorityRunnerPath = "",
    [string[]]$AuthorityRunnerArguments = @(),
    [string]$Timestamp = "",
    [string]$OutPath = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "WorkUnitAutomation.psm1") -Force

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
    PublicationOrderingInterruption = $PublicationOrderingInterruption
    AdoptionReceipt = $AdoptionReceipt
    ValidationTier = $ValidationTier
    DeviceSerials = $DeviceSerials
    AuthorityRunnerPath = $AuthorityRunnerPath
    AuthorityRunnerArguments = $AuthorityRunnerArguments
    Timestamp = $Timestamp
    OutPath = $OutPath
    Execute = $Execute
}

Invoke-MorphospaceWorkUnitAutomation @arguments | ConvertTo-Json -Depth 32
