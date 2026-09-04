param([switch]$LifecycleRouterSelfTestOnly)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot "WorkUnitAutomation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\MorphospacePlanningProjection.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceProtocolCommon.psm1") -Force
$transitionLedgerModule=Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceTransitionLedger.psm1") -Force -PassThru
$reconstructionModule=Import-Module (Join-Path $PSScriptRoot "PreparedPublicationReconstruction.psm1") -Force -PassThru
$retirementModule=Import-Module (Join-Path $PSScriptRoot "PreparedPushRetirement.psm1") -Force -PassThru

function Assert-Automation {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Automation self-test failed: $Message" }
}

$automationEntry=Get-Command (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1');$actionSet=@($automationEntry.Parameters['Action'].Attributes|Where-Object{$_-is[Management.Automation.ValidateSetAttribute]}|ForEach-Object{$_.ValidValues});Assert-Automation ($actionSet-ccontains'ReprepareRetiredDevelopmentEnvelope') 'public automation entrypoint does not register ReprepareRetiredDevelopmentEnvelope'

function Get-TestCanonicalHash {
    param([object]$Value)
    $module = Get-Module WorkUnitAutomation
    return & $module { param($Document) Get-MorphospaceCanonicalJsonSha256 $Document } $Value
}

function Get-TestNullableCanonicalHash {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '<null>' }
    return Get-TestCanonicalHash $Value
}

function Get-TestFileHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-TestProtocolJson {
    param([string]$Path)
    $module = Get-Module WorkUnitAutomation
    return & $module { param($DocumentPath) Read-MorphospaceProtocolJson -Path $DocumentPath } $Path
}

# Exercise the lifecycle branches through the exact public script while
# replacing only their already independently tested owner modules with a
# closed capture seam. This keeps wrapper-only changes cheap while proving
# parameter forwarding, dry/execute switch projection, replay stability, and
# absence of wrapper-owned workspace/output mutation.
$lifecycleRouterRoot = Join-Path ([IO.Path]::GetTempPath()) ('work-unit-lifecycle-router-' + [Guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($lifecycleRouterRoot)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Destination (Join-Path $lifecycleRouterRoot 'Invoke-WorkUnitAutomation.ps1')
    [IO.File]::WriteAllText((Join-Path $lifecycleRouterRoot 'WorkUnitAutomation.psm1'),"# lifecycle router capture seam`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $lifecycleRouterRoot 'BlockedSuccessorPreparation.psm1'),@'
function Invoke-MorphospacePrepareBlockedSuccessor {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$BlockedSuccessorPreparation,[string]$ExpectedBlockedSuccessorPreparationSha256,[string]$Timestamp,[string]$OutPath,[switch]$Execute)
    [pscustomobject][ordered]@{action='PrepareBlockedSuccessor';workspace_root=$WorkspaceRoot;request=$BlockedSuccessorPreparation;expected_sha256=$ExpectedBlockedSuccessorPreparationSha256;timestamp=$Timestamp;out_path=$OutPath;executed=$Execute.IsPresent}
}
Export-ModuleMember -Function Invoke-MorphospacePrepareBlockedSuccessor
'@,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $lifecycleRouterRoot 'DevelopmentEnvelopeRepreparation.psm1'),@'
function Invoke-MorphospaceReprepareRetiredDevelopmentEnvelope {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$DevelopmentEnvelopeRepreparation,[string]$ExpectedDevelopmentEnvelopeRepreparationSha256,[string]$Timestamp,[string]$OutPath,[switch]$Execute)
    [pscustomobject][ordered]@{action='ReprepareRetiredDevelopmentEnvelope';workspace_root=$WorkspaceRoot;request=$DevelopmentEnvelopeRepreparation;expected_sha256=$ExpectedDevelopmentEnvelopeRepreparationSha256;timestamp=$Timestamp;out_path=$OutPath;executed=$Execute.IsPresent}
}
Export-ModuleMember -Function Invoke-MorphospaceReprepareRetiredDevelopmentEnvelope
'@,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $lifecycleRouterRoot 'ActiveUnitSupersession.psm1'),@'
function Invoke-MorphospaceSupersedeActive {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$UnitId,[string]$RepoMapPath,[string]$ActiveUnitSupersession,[string]$ExpectedActiveUnitSupersessionSha256,[string]$Timestamp,[string]$OutPath,[switch]$Execute)
    [pscustomobject][ordered]@{action='SupersedeActive';workspace_root=$WorkspaceRoot;unit_id=$UnitId;repository_map=$RepoMapPath;request=$ActiveUnitSupersession;expected_sha256=$ExpectedActiveUnitSupersessionSha256;timestamp=$Timestamp;out_path=$OutPath;executed=$Execute.IsPresent}
}
Export-ModuleMember -Function Invoke-MorphospaceSupersedeActive
'@,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $lifecycleRouterRoot 'ValidatingCandidateRematerialization.psm1'),@'
function Invoke-MorphospaceRematerializeValidatingCandidate {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$UnitId,[string]$RepoMapPath,[string]$CandidateFreeze,[string]$SourceCompositionLock,[string]$ExpectedCandidateFreezeSha256,[string]$Timestamp,[string]$OutPath,[switch]$Execute)
    [pscustomobject][ordered]@{action='RematerializeValidatingCandidate';workspace_root=$WorkspaceRoot;unit_id=$UnitId;repository_map=$RepoMapPath;request=$CandidateFreeze;source_composition=$SourceCompositionLock;expected_sha256=$ExpectedCandidateFreezeSha256;timestamp=$Timestamp;out_path=$OutPath;executed=$Execute.IsPresent}
}
Export-ModuleMember -Function Invoke-MorphospaceRematerializeValidatingCandidate
'@,[Text.UTF8Encoding]::new($false))
    $lifecycleWorkspace = Join-Path $lifecycleRouterRoot 'workspace'
    [void][IO.Directory]::CreateDirectory($lifecycleWorkspace)
    $lifecycleMarker = Join-Path $lifecycleWorkspace 'marker.txt'
    [IO.File]::WriteAllText($lifecycleMarker,"unchanged`n",[Text.UTF8Encoding]::new($false))
    $blockedRequest = Join-Path $lifecycleRouterRoot 'blocked-request.json'
    $repreparationRequest = Join-Path $lifecycleRouterRoot 'repreparation-request.json'
    $activeRequest = Join-Path $lifecycleRouterRoot 'active-request.json'
    $rematerializationRequest = Join-Path $lifecycleRouterRoot 'rematerialization-request.json'
    $replacementSourceComposition = Join-Path $lifecycleRouterRoot 'replacement-source-composition.json'
    $routerRepoMap = Join-Path $lifecycleRouterRoot 'repository-map.json'
    foreach ($path in @($blockedRequest,$repreparationRequest,$activeRequest,$rematerializationRequest,$replacementSourceComposition,$routerRepoMap)) { [IO.File]::WriteAllText($path,"{}`n",[Text.UTF8Encoding]::new($false)) }
    $blockedOut = Join-Path $lifecycleWorkspace 'blocked-result.json'
    $repreparationOut = Join-Path $lifecycleWorkspace 'repreparation-result.json'
    $activeOut = Join-Path $lifecycleWorkspace 'active-result.json'
    $rematerializationOut = Join-Path $lifecycleWorkspace 'rematerialization-result.json'
    $blockedHash = Get-TestFileHash $blockedRequest
    $repreparationHash = Get-TestFileHash $repreparationRequest
    $activeHash = Get-TestFileHash $activeRequest
    $rematerializationHash = Get-TestFileHash $rematerializationRequest
    $markerHash = Get-TestFileHash $lifecycleMarker
    $routerScript = Join-Path $lifecycleRouterRoot 'Invoke-WorkUnitAutomation.ps1'
    $freshPwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    function Invoke-LifecycleRouterCapture([string[]]$Arguments) {
        $raw = @(& $freshPwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $routerScript @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Lifecycle router capture failed: $($raw -join [Environment]::NewLine)" }
        return (($raw -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32 -DateKind String)
    }
    $blockedArguments = @('-Action','PrepareBlockedSuccessor','-WorkspaceRoot',$lifecycleWorkspace,'-BlockedSuccessorPreparation',$blockedRequest,'-ExpectedBlockedSuccessorPreparationSha256',$blockedHash,'-Timestamp','2026-09-01T00:03:00.0000000Z','-OutPath',$blockedOut)
    $blockedDry = Invoke-LifecycleRouterCapture $blockedArguments
    $blockedRun = Invoke-LifecycleRouterCapture (@($blockedArguments) + '-Execute')
    $blockedReplay = Invoke-LifecycleRouterCapture (@($blockedArguments) + '-Execute')
    $blockedExpectedDry = [pscustomobject][ordered]@{action='PrepareBlockedSuccessor';workspace_root=$lifecycleWorkspace;request=$blockedRequest;expected_sha256=$blockedHash;timestamp='2026-09-01T00:03:00.0000000Z';out_path=$blockedOut;executed=$false}
    $blockedExpectedRun = $blockedExpectedDry | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8 -DateKind String
    $blockedExpectedRun.executed = $true
    Assert-Automation (
        (Get-TestCanonicalHash $blockedDry) -ceq (Get-TestCanonicalHash $blockedExpectedDry) -and
        (Get-TestCanonicalHash $blockedRun) -ceq (Get-TestCanonicalHash $blockedExpectedRun) -and
        (Get-TestCanonicalHash $blockedReplay) -ceq (Get-TestCanonicalHash $blockedExpectedRun)
    ) 'public PrepareBlockedSuccessor wrapper did not preserve exact dry/execute/replay forwarding'
    $repreparationArguments = @('-Action','ReprepareRetiredDevelopmentEnvelope','-WorkspaceRoot',$lifecycleWorkspace,'-DevelopmentEnvelopeRepreparation',$repreparationRequest,'-ExpectedDevelopmentEnvelopeRepreparationSha256',$repreparationHash,'-Timestamp','2026-09-01T00:03:30.0000000Z','-OutPath',$repreparationOut)
    $repreparationDry = Invoke-LifecycleRouterCapture $repreparationArguments
    $repreparationRun = Invoke-LifecycleRouterCapture (@($repreparationArguments) + '-Execute')
    $repreparationReplay = Invoke-LifecycleRouterCapture (@($repreparationArguments) + '-Execute')
    $repreparationExpectedDry = [pscustomobject][ordered]@{action='ReprepareRetiredDevelopmentEnvelope';workspace_root=$lifecycleWorkspace;request=$repreparationRequest;expected_sha256=$repreparationHash;timestamp='2026-09-01T00:03:30.0000000Z';out_path=$repreparationOut;executed=$false}
    $repreparationExpectedRun = $repreparationExpectedDry | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8 -DateKind String
    $repreparationExpectedRun.executed = $true
    Assert-Automation (
        (Get-TestCanonicalHash $repreparationDry) -ceq (Get-TestCanonicalHash $repreparationExpectedDry) -and
        (Get-TestCanonicalHash $repreparationRun) -ceq (Get-TestCanonicalHash $repreparationExpectedRun) -and
        (Get-TestCanonicalHash $repreparationReplay) -ceq (Get-TestCanonicalHash $repreparationExpectedRun)
    ) 'public ReprepareRetiredDevelopmentEnvelope wrapper did not preserve exact dry/execute/replay forwarding'
    $activeArguments = @('-Action','SupersedeActive','-WorkspaceRoot',$lifecycleWorkspace,'-UnitId','replacement-unit','-RepoMapPath',$routerRepoMap,'-ActiveUnitSupersession',$activeRequest,'-ExpectedActiveUnitSupersessionSha256',$activeHash,'-Timestamp','2026-09-01T00:04:00.0000000Z','-OutPath',$activeOut)
    $activeDry = Invoke-LifecycleRouterCapture $activeArguments
    $activeRun = Invoke-LifecycleRouterCapture (@($activeArguments) + '-Execute')
    $activeReplay = Invoke-LifecycleRouterCapture (@($activeArguments) + '-Execute')
    $activeExpectedDry = [pscustomobject][ordered]@{action='SupersedeActive';workspace_root=$lifecycleWorkspace;unit_id='replacement-unit';repository_map=$routerRepoMap;request=$activeRequest;expected_sha256=$activeHash;timestamp='2026-09-01T00:04:00.0000000Z';out_path=$activeOut;executed=$false}
    $activeExpectedRun = $activeExpectedDry | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8 -DateKind String
    $activeExpectedRun.executed = $true
    Assert-Automation (
        (Get-TestCanonicalHash $activeDry) -ceq (Get-TestCanonicalHash $activeExpectedDry) -and
        (Get-TestCanonicalHash $activeRun) -ceq (Get-TestCanonicalHash $activeExpectedRun) -and
        (Get-TestCanonicalHash $activeReplay) -ceq (Get-TestCanonicalHash $activeExpectedRun)
    ) 'public SupersedeActive wrapper did not preserve exact dry/execute/replay forwarding'
    $rematerializationArguments = @('-Action','RematerializeValidatingCandidate','-WorkspaceRoot',$lifecycleWorkspace,'-UnitId','validating-unit','-RepoMapPath',$routerRepoMap,'-ValidatingCandidateRematerialization',$rematerializationRequest,'-ReplacementSourceComposition',$replacementSourceComposition,'-ExpectedValidatingCandidateRematerializationSha256',$rematerializationHash,'-Timestamp','2026-09-02T00:05:00.0000000Z','-OutPath',$rematerializationOut)
    $rematerializationDry = Invoke-LifecycleRouterCapture $rematerializationArguments
    $rematerializationRun = Invoke-LifecycleRouterCapture (@($rematerializationArguments) + '-Execute')
    $rematerializationReplay = Invoke-LifecycleRouterCapture (@($rematerializationArguments) + '-Execute')
    $rematerializationExpectedDry = [pscustomobject][ordered]@{action='RematerializeValidatingCandidate';workspace_root=$lifecycleWorkspace;unit_id='validating-unit';repository_map=$routerRepoMap;request=$rematerializationRequest;source_composition=$replacementSourceComposition;expected_sha256=$rematerializationHash;timestamp='2026-09-02T00:05:00.0000000Z';out_path=$rematerializationOut;executed=$false}
    $rematerializationExpectedRun = $rematerializationExpectedDry | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8 -DateKind String
    $rematerializationExpectedRun.executed = $true
    Assert-Automation (
        (Get-TestCanonicalHash $rematerializationDry) -ceq (Get-TestCanonicalHash $rematerializationExpectedDry) -and
        (Get-TestCanonicalHash $rematerializationRun) -ceq (Get-TestCanonicalHash $rematerializationExpectedRun) -and
        (Get-TestCanonicalHash $rematerializationReplay) -ceq (Get-TestCanonicalHash $rematerializationExpectedRun)
    ) 'public RematerializeValidatingCandidate wrapper did not preserve exact dry/execute/replay forwarding'
    Assert-Automation ((Get-TestFileHash $lifecycleMarker) -ceq $markerHash -and -not (Test-Path -LiteralPath $blockedOut) -and -not (Test-Path -LiteralPath $repreparationOut) -and -not (Test-Path -LiteralPath $activeOut) -and -not (Test-Path -LiteralPath $rematerializationOut)) 'public lifecycle wrapper capture seam mutated workspace or output bytes'
} finally {
    Remove-Item Function:Invoke-LifecycleRouterCapture -ErrorAction SilentlyContinue
    if ([IO.Directory]::Exists($lifecycleRouterRoot)) { Remove-Item -LiteralPath $lifecycleRouterRoot -Recurse -Force }
}
if ($LifecycleRouterSelfTestOnly) { Write-Host 'Work-unit lifecycle router focused self-test passed.'; return }

# Exercise the public archive action in a fresh process: parameter routing must
# reach the owner adapter before any workspace-dependent preflight can run.
$archiveStdout = [IO.Path]::GetTempFileName()
$archiveStderr = [IO.Path]::GetTempFileName()
$archiveProbe = $null
try {
    $freshPwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $archiveProbe = Start-Process -FilePath $freshPwsh -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'),
        '-Action', 'ArchiveHistoryCheckpoint', '-WorkspaceRoot', (Join-Path ([IO.Path]::GetTempPath()) 'missing-history-archive-workspace')
    ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $archiveStdout -RedirectStandardError $archiveStderr
    $archiveText = ((Get-Content -Raw $archiveStdout -ErrorAction SilentlyContinue) + (Get-Content -Raw $archiveStderr -ErrorAction SilentlyContinue))
    Assert-Automation ($archiveProbe.ExitCode -ne 0) 'fresh-process archive action probe unexpectedly succeeded'
    Assert-Automation ($archiveText -match 'ArchiveHistoryCheckpoint requires HistoryArchiveCheckpoint and OutPath' -and $archiveText -notmatch "Cannot validate argument on parameter 'Action'") 'public Invoke entrypoint does not route ArchiveHistoryCheckpoint to its typed owner adapter'
} finally {
    if ($null -ne $archiveProbe) { $archiveProbe.Dispose() }
    Remove-Item -LiteralPath $archiveStdout,$archiveStderr -Force -ErrorAction SilentlyContinue
}

# Exercise the public script in a fresh pwsh process so action/parameter routing
# cannot pass merely because this test imported the module in-process.
$freshStdout = [IO.Path]::GetTempFileName()
$freshStderr = [IO.Path]::GetTempFileName()
try {
    $freshPwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $fresh = Start-Process -FilePath $freshPwsh -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1"),
        "-Action", "ReconcilePublishedPrerequisiteSuffix", "-WorkspaceRoot", (Join-Path ([IO.Path]::GetTempPath()) "missing-published-prerequisite-workspace"),
        "-UnitId", "test-unit", "-RepoMapPath", "missing-repository-map.json",
        "-PublishedPrerequisiteSuffixReconciliation", "receipts/missing-reconciliation.json"
    ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $freshStdout -RedirectStandardError $freshStderr
    $freshText = ((Get-Content -Raw $freshStdout -ErrorAction SilentlyContinue) + (Get-Content -Raw $freshStderr -ErrorAction SilentlyContinue))
    Assert-Automation ($fresh.ExitCode -ne 0) "fresh-process reconciliation probe unexpectedly succeeded"
    Assert-Automation ($freshText -notmatch "Cannot validate argument on parameter 'Action'|named PublishedPrerequisiteSuffixReconciliation parameter cannot be found") "fresh-process public Invoke entrypoint does not expose published-prerequisite reconciliation"
} finally {
    if ($null -ne $fresh) { $fresh.Dispose() }
    Remove-Item -LiteralPath $freshStdout,$freshStderr -Force -ErrorAction SilentlyContinue
}

$freshStdout = [IO.Path]::GetTempFileName()
$freshStderr = [IO.Path]::GetTempFileName()
$fresh = $null
try {
    $freshPwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $fresh = Start-Process -FilePath $freshPwsh -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1"),
        "-Action", "ReconcileExecutedPreparedPublication", "-WorkspaceRoot", (Join-Path ([IO.Path]::GetTempPath()) "missing-executed-prepared-workspace"),
        "-UnitId", "test-unit", "-RepoMapPath", "missing-repository-map.json",
        "-ExecutedPreparedPublicationReconciliation", "receipts/missing-reconciliation.json"
    ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $freshStdout -RedirectStandardError $freshStderr
    $freshText = ((Get-Content -Raw $freshStdout -ErrorAction SilentlyContinue) + (Get-Content -Raw $freshStderr -ErrorAction SilentlyContinue))
    Assert-Automation ($fresh.ExitCode -ne 0) "fresh-process executed prepared-publication probe unexpectedly succeeded"
    Assert-Automation ($freshText -notmatch "Cannot validate argument on parameter 'Action'|named ExecutedPreparedPublicationReconciliation parameter cannot be found") "fresh-process public Invoke entrypoint does not expose executed prepared-publication reconciliation"
} finally {
    if ($null -ne $fresh) { $fresh.Dispose() }
    Remove-Item -LiteralPath $freshStdout,$freshStderr -Force -ErrorAction SilentlyContinue
}

$freshStdout = [IO.Path]::GetTempFileName()
$freshStderr = [IO.Path]::GetTempFileName()
$fresh = $null
try {
    $freshPwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $fresh = Start-Process -FilePath $freshPwsh -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1"),
        "-Action", "ReconcilePreparedPushTransactionSuffix", "-WorkspaceRoot", (Join-Path ([IO.Path]::GetTempPath()) "missing-prepared-push-suffix-workspace"),
        "-UnitId", "test-unit", "-RepoMapPath", "missing-repository-map.json",
        "-PreparedPushTransactionSuffixReconciliation", "receipts/missing-reconciliation.json",
        "-OutPath", "receipts/missing-output.json"
    ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $freshStdout -RedirectStandardError $freshStderr
    $freshText = ((Get-Content -Raw $freshStdout -ErrorAction SilentlyContinue) + (Get-Content -Raw $freshStderr -ErrorAction SilentlyContinue))
    Assert-Automation ($fresh.ExitCode -ne 0) "fresh-process prepared-push transaction-suffix probe unexpectedly succeeded"
    Assert-Automation ($freshText -notmatch "Cannot validate argument on parameter 'Action'|named PreparedPushTransactionSuffixReconciliation parameter cannot be found|named OutPath parameter cannot be found") "fresh-process public Invoke entrypoint does not expose prepared-push transaction-suffix reconciliation"
} finally {
    if ($null -ne $fresh) { $fresh.Dispose() }
    Remove-Item -LiteralPath $freshStdout,$freshStderr -Force -ErrorAction SilentlyContinue
}

$freshStdout = [IO.Path]::GetTempFileName()
$freshStderr = [IO.Path]::GetTempFileName()
$fresh = $null
try {
    $freshPwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $fresh = Start-Process -FilePath $freshPwsh -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1"),
        "-Action", "AdoptPublishedPlanningAuthority", "-WorkspaceRoot", (Join-Path ([IO.Path]::GetTempPath()) "missing-planning-authority-adoption-workspace"),
        "-UnitId", "test-unit", "-RepoMapPath", "missing-repository-map.json",
        "-PublishedPlanningAuthorityAdoption", "receipts/missing-adoption.json"
    ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $freshStdout -RedirectStandardError $freshStderr
    $freshText = ((Get-Content -Raw $freshStdout -ErrorAction SilentlyContinue) + (Get-Content -Raw $freshStderr -ErrorAction SilentlyContinue))
    Assert-Automation ($fresh.ExitCode -ne 0) "fresh-process planning-authority adoption probe unexpectedly succeeded"
    Assert-Automation ($freshText -notmatch "Cannot validate argument on parameter 'Action'|named PublishedPlanningAuthorityAdoption parameter cannot be found") "fresh-process public Invoke entrypoint does not expose planning-authority adoption"
} finally {
    if ($null -ne $fresh) { $fresh.Dispose() }
    Remove-Item -LiteralPath $freshStdout,$freshStderr -Force -ErrorAction SilentlyContinue
}

$workUnitAutomationModule = Get-Module WorkUnitAutomation
$pathNormalizationResults = & $workUnitAutomationModule {
    [pscustomobject]@{
        exact = Test-MorphospacePathAllowed -Path ".github/workflows/ci.yml" -AllowedPaths @(".github/workflows/ci.yml")
        optional_prefix = Test-MorphospacePathAllowed -Path ".github/workflows/ci.yml" -AllowedPaths @("./.github/workflows/ci.yml")
        leading_dot_preserved = -not (Test-MorphospacePathAllowed -Path "github/workflows/ci.yml" -AllowedPaths @(".github/workflows/ci.yml"))
        hidden_directory = Test-MorphospacePathAllowed -Path ".config/tool/settings.json" -AllowedPaths @(".config/")
        explicit_relative = Test-MorphospacePathAllowed -Path "src/lib.rs" -AllowedPaths @("./src/")
    }
}
Assert-Automation ($pathNormalizationResults.exact -and $pathNormalizationResults.optional_prefix -and $pathNormalizationResults.leading_dot_preserved -and $pathNormalizationResults.hidden_directory -and $pathNormalizationResults.explicit_relative) "repository-relative path normalization"

$traversalRejected = $false
try {
    & $workUnitAutomationModule {
        Test-MorphospacePathAllowed -Path "src/lib.rs" -AllowedPaths @("../src/")
    } | Out-Null
} catch {
    $traversalRejected = $_.Exception.Message -like "Repository-relative path may not contain '..'*"
}
Assert-Automation $traversalRejected "traversal in an allowed path did not fail closed"

function Write-TestJson {
    param([string]$Path, [object]$Value)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 32) + [Environment]::NewLine), $encoding)
}

function Invoke-TestGit {
    param([string]$Path, [string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git -C $Path @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { throw "Test Git command failed: git -C $Path $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)" }
    return @($output)
}

function New-TestUnit {
    param([string]$ProjectId, [string]$UnitId)
    return [ordered]@{
        '$schema' = "../schemas/iteration-unit.schema.json"
        schema = "rusty.morphospace.workflow.iteration_unit.v1"
        unit_id = $UnitId; project_id = $ProjectId; status = "ready"
        objective = "Exercise fail-closed work-unit automation without touching real repositories or devices."
        change_categories = @("implementation")
        instruction_impact = "none"; instruction_surfaces = @()
        instruction_none_justification = "The temporary unit only exercises the existing automation contract."
        prerequisites = @()
        allowed_repositories = @([ordered]@{ repo_id = "project-shell"; allowed_paths = @("src/", "docs/", "morphospace/") })
        non_scope = @("Real repositories and live devices.")
        acceptance = @([ordered]@{ acceptance_id = "self-test"; proof = "The simulation passes."; command = "Test-WorkUnitAutomation.ps1" })
        risk_tier = "standard"; device_requirement = "none"
        validation = @([ordered]@{ profile_id = "workflow"; command = "temporary validation command" })
        outputs = @("automation receipt"); commit_policy = "Temporary repository only."
        push_checkpoint = "integration-batch"
    }
}

function New-TestWorkspace {
    param([string]$Root, [string]$ProjectId, [string]$UnitId)
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    & (Join-Path $PSScriptRoot "New-ProjectWorkspace.ps1") -ProjectRoot $Root -ProjectId $ProjectId -Purpose "Automation simulation." -Execute | Out-Null
    $workspace = Join-Path $Root "morphospace"
    Write-TestJson -Path (Join-Path $workspace "iteration-units\$UnitId.json") -Value (New-TestUnit -ProjectId $ProjectId -UnitId $UnitId)
    $statePath = Join-Path $workspace "workspace.state.json"
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.next_ready_unit = $UnitId
    Write-TestJson -Path $statePath -Value $state
    return $workspace
}

function New-TestReadyWithdrawalWorkspace {
    param(
        [string]$Root,
        [string]$ProjectId,
        [switch]$IncludeSecondReady
    )

    $currentId = 'unit-current-001'
    $withdrawId = 'unit-next-a-001'
    $remainingId = 'unit-next-b-001'
    $workspace = New-TestWorkspace -Root $Root -ProjectId $ProjectId -UnitId $currentId
    $currentPath = Join-Path $workspace "iteration-units\$currentId.json"
    $current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
    $current.status = 'active'
    Write-TestJson -Path $currentPath -Value $current
    $statePath = Join-Path $workspace 'workspace.state.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.current_unit = $currentId
    $state.next_ready_unit = $null
    Write-TestJson -Path $statePath -Value $state

    foreach ($candidateId in @($withdrawId) + $(if ($IncludeSecondReady) { @($remainingId) } else { @() })) {
        $candidate = New-TestUnit -ProjectId $ProjectId -UnitId $candidateId
        $candidate.status = 'proposed'
        Write-TestJson -Path (Join-Path $workspace "iteration-units\$candidateId.json") -Value $candidate
        Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $workspace -UnitId $candidateId -Timestamp '2026-01-02T03:04:05Z' -Execute | Out-Null
    }
    return [pscustomobject][ordered]@{
        workspace = $workspace
        project_id = $ProjectId
        current_id = $currentId
        withdraw_id = $withdrawId
        remaining_id = if ($IncludeSecondReady) { $remainingId } else { $null }
    }
}

function Copy-TestWorkspace {
    param([string]$Source,[string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw "Test destination already exists: $Destination" }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    return $Destination
}

function New-TestValidationReceipt {
    param(
        [string]$Workspace,
        [string]$ProjectId,
        [string]$UnitId,
        [string]$Tier,
        [string]$Result,
        [object[]]$RepositoryRevisions = @(),
        [object[]]$ChangedPaths = @(),
        [object[]]$Gates = @(),
        [string]$EvidenceName = "self-test-evidence.txt",
        [switch]$InstructionSynchronization
    )

    $receiptRoot = Join-Path $Workspace "receipts"
    [System.IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
    $evidencePath = Join-Path $receiptRoot $EvidenceName
    [System.IO.File]::WriteAllText($evidencePath, "validation evidence for $UnitId $Result`n", (New-Object System.Text.UTF8Encoding($false)))
    $hash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $status = if ($Result -eq "pass") { "pass" } else { "fail" }
    $receiptGates = New-Object System.Collections.Generic.List[object]
    if ($Gates.Count -ne 0) {
        foreach ($gate in @($Gates)) { $receiptGates.Add($gate) | Out-Null }
    } else {
        $receiptGates.Add([pscustomobject][ordered]@{
            gate_id = "validation-workflow"
            status = $status
            command = "temporary validation command"
            evidence_refs = @("validation-evidence")
        }) | Out-Null
    }
    if ($InstructionSynchronization) {
        $receiptGates.Add([pscustomobject][ordered]@{
            gate_id = "instruction-synchronization"
            status = $status
            command = "Verify every declared instruction surface is complete and validated."
            evidence_refs = @("validation-evidence")
        }) | Out-Null
    }
    $receipt = [ordered]@{
        '$schema' = "../schemas/validation-receipt.schema.json"
        schema = "rusty.morphospace.workflow.validation_receipt.v1"
        receipt_id = "$UnitId-$Result-validation"
        project_id = $ProjectId
        unit_id = $UnitId
        created_at = "2026-01-02T03:04:05Z"
        tier = $Tier
        result = $Result
        repository_revisions = @($RepositoryRevisions)
        changed_paths = @($ChangedPaths)
        artifacts = @([ordered]@{
            artifact_id = "validation-evidence"
            kind = "test-log"
            path = $EvidenceName
            sha256 = $hash
        })
        criteria = @([ordered]@{
            acceptance_id = "self-test"
            status = $status
            command = "Test-WorkUnitAutomation.ps1"
            evidence_refs = @("validation-evidence")
        })
        gates = @($receiptGates.ToArray())
        device_validation = $null
    }
    $receiptPath = Join-Path $receiptRoot "$UnitId-$Result-validation.json"
    Write-TestJson -Path $receiptPath -Value $receipt
    return $receiptPath
}

function New-TestInterruptionReceipt {
    param(
        [string]$Workspace,
        [string]$ProjectId,
        [string]$UnitId,
        [string]$Kind,
        [string]$Revision,
        [bool]$Safe = $true,
        [bool]$Cleanup = $true
    )

    $receiptRoot = Join-Path $Workspace "receipts"
    [System.IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
    $evidenceName = "$Kind-evidence.txt"
    $evidencePath = Join-Path $receiptRoot $evidenceName
    [System.IO.File]::WriteAllText($evidencePath, "interruption evidence for $Kind`n", (New-Object System.Text.UTF8Encoding($false)))
    $hash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $repositories = if ($Kind -eq "partial-cross-repo-commit") {
        @(
            [ordered]@{ repo_id = "project-shell"; observed_revision = $Revision; state = "committed" },
            [ordered]@{ repo_id = "planning-surface"; observed_revision = $Revision; state = "pending" }
        )
    } else {
        @([ordered]@{ repo_id = "project-shell"; observed_revision = $Revision; state = "preserved" })
    }
    $buildCleanup = if ($Kind -eq "interrupted-build") {
        [ordered]@{ active_process_count = 0; outputs_quarantined = $Cleanup; cleanup_actions = @("stop bounded build process", "quarantine partial output") }
    } else { $null }
    $deviceCleanup = if ($Kind -eq "interrupted-device") {
        [ordered]@{ serials = @("test-device-a", "test-device-b"); packages_remaining = @(); routes_inactive = $Cleanup; package_fatal_count = 0; system_fatal_count = 0 }
    } else { $null }
    $receipt = [ordered]@{
        '$schema' = "../schemas/interruption-receipt.schema.json"
        schema = "rusty.morphospace.workflow.interruption_receipt.v1"
        receipt_id = "$UnitId-$Kind-recovery"
        project_id = $ProjectId; unit_id = $UnitId; captured_at = "2026-01-02T03:04:05Z"
        interruption_kind = $Kind; safe_to_resume = $Safe; cleanup_complete = $Cleanup
        repositories = $repositories; build_cleanup = $buildCleanup; device_cleanup = $deviceCleanup
        artifacts = @([ordered]@{ artifact_id = "recovery-evidence"; path = $evidenceName; sha256 = $hash })
    }
    $path = Join-Path $receiptRoot "$UnitId-$Kind-recovery.json"
    Write-TestJson -Path $path -Value $receipt
    return $path
}

function New-TestInflightAdoptionReceipt {
    param(
        [string]$Workspace,
        [string]$UnitId,
        [string]$RepoMapPath,
        [string]$Timestamp
    )

    $path = Join-Path $Workspace "receipts\$UnitId-inflight-adoption.json"
    New-MorphospaceInflightAdoptionReceipt -WorkspaceRoot $Workspace -UnitId $UnitId -RepoMapPath $RepoMapPath -Timestamp $Timestamp -OutPath $path -Execute | Out-Null
    return $path
}

function New-TestUnplannedPublicationClosure {
    param(
        [string]$Workspace,
        [string]$ProjectId,
        [string]$UnitId,
        [string]$RepoId,
        [string]$Branch,
        [string]$Upstream,
        [string]$OldRevision,
        [string]$NewRevision,
        [string]$PendingBundle,
        [string]$ValidationReceipt
    )

    $statePath = Join-Path $Workspace 'workspace.state.json'
    $validationPath = Join-Path $Workspace $ValidationReceipt
    $stateHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $validationHash = (Get-FileHash -LiteralPath $validationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $closure = [ordered]@{
        schema = 'rusty.morphospace.workflow.unplanned_publication_closure.v1'
        closure_id = "$UnitId-unplanned-publication-closure"
        project_id = $ProjectId
        unit_id = $UnitId
        recorded_at = '2026-01-02T03:04:05Z'
        status = 'independent-reconstruction-verified'
        chronology = [ordered]@{
            classification = 'unplanned-push-before-prepare'
            prepared_plan_present = $false
            executed_push_receipt_present = $false
            does_not_claim = @('No pre-push PreparePush plan or executed-push receipt is claimed.')
        }
        workspace_state_before = [ordered]@{ path = 'workspace.state.json'; sha256 = $stateHash }
        repository = [ordered]@{
            repo_id = $RepoId; role = 'source-owner'; branch = $Branch; remote = 'origin'; upstream = $Upstream; action = 'pushed'
            old_revision = $OldRevision; new_revision = $NewRevision; observed_remote_revision = $NewRevision; rollback_revision = $OldRevision
            fast_forward_verified = $true; remote_match = $true; force_push_used = $false; worktree_clean = $true
            validation_refs = @('standard-validation')
        }
        validation = @([ordered]@{
            gate_id = 'standard-validation'; status = 'pass'
            evidence = [ordered]@{ path = $ValidationReceipt.Replace('\', '/'); sha256 = $validationHash }
        })
        observers = @([ordered]@{ observer_id = 'external-coordinator'; recorded_at = '2026-01-02T03:04:05Z'; evidence_sha256 = ('4' * 64) })
        workspace_transition = [ordered]@{
            pending_push_bundle_before = $PendingBundle; pending_push_bundle_after = $null
            dirty_repository_ids_to_clear = @($RepoId); repository_head_after = $NewRevision
        }
        remote_readback_complete = $true; recovery_scope = 'workflow-state-only'; failure = $null
    }
    $path = Join-Path $Workspace "receipts\$UnitId-unplanned-publication-closure.json"
    Write-TestJson -Path $path -Value $closure
    return $path
}

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("rusty-morphospace-automation-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $remote = Join-Path $testRoot "remote.git"
    $repo = Join-Path $testRoot "project-repo"
    $peer = Join-Path $testRoot "peer-repo"
    $planningRemote = Join-Path $testRoot "planning-remote.git"
    $planningRepo = Join-Path $testRoot "planning-repo"
    & git init --bare $remote | Out-Null
    & git init $repo | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("config", "user.name", "Automation Test") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("config", "user.email", "automation@example.invalid") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("config", "core.autocrlf", "false") | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.Directory]::CreateDirectory((Join-Path $repo "src")) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repo "src\seed.txt"), "seed`n", $encoding)
    Invoke-TestGit -Path $repo -Arguments @("add", "src/seed.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "seed") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("branch", "-M", "main") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("remote", "add", "origin", $remote) | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("push", "-u", "origin", "main") | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repo "docs")) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repo "AGENTS.md"), "bounded agent routing`n", $encoding)
    [System.IO.File]::WriteAllText((Join-Path $repo "docs\workflow.md"), "bounded workflow routing`n", $encoding)
    [System.IO.File]::WriteAllText((Join-Path $repo "docs\compatibility.md"), "bounded compatibility record`n", $encoding)
    [System.IO.File]::WriteAllText((Join-Path $repo "docs\roadmap.md"), "bounded roadmap record`n", $encoding)
    Invoke-TestGit -Path $repo -Arguments @("add", "AGENTS.md", "docs/workflow.md", "docs/compatibility.md", "docs/roadmap.md") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "add instruction surfaces") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("push", "origin", "main") | Out-Null
    $skillsRoot = Join-Path $testRoot 'registered-skill-surfaces'
    $canonicalSkillRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills'
    foreach ($skillId in @('rusty-morphospace', 'system-engineering')) {
        $skillDirectory = Join-Path $skillsRoot $skillId
        [System.IO.Directory]::CreateDirectory($skillDirectory) | Out-Null
        # The registered external copy must bind to this source revision's
        # tracked router bytes, not merely look like the expected path.
        [System.IO.File]::WriteAllBytes((Join-Path $skillDirectory 'SKILL.md'), [System.IO.File]::ReadAllBytes((Join-Path $canonicalSkillRoot "$skillId\SKILL.md")))
    }
    $executionObservationPath = Join-Path $repo "src\execution-preflight.json"
    Write-TestJson -Path $executionObservationPath -Value ([ordered]@{
        '$schema' = "../schemas/execution-preflight-observation.schema.json"
        schema = "rusty.morphospace.workflow.execution_preflight_observation.v1"
        observation_id = "synthetic-android-execution"
        created_at = "2026-01-02T03:04:05Z"
        subject = "Synthetic Android build and bridge inputs."
        values = @(
            [ordered]@{ key = "android.package"; value = "org.example.synthetic" },
            [ordered]@{ key = "signing.fingerprint"; value = "test-fingerprint" }
        )
        capabilities = @(
            [ordered]@{ capability_id = "ndk-available"; available = $true; detail = "synthetic-r27" },
            [ordered]@{ capability_id = "bridge-port-available"; available = $true; detail = "synthetic-44800" }
        )
    })
    Invoke-TestGit -Path $repo -Arguments @("add", "src/execution-preflight.json") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "add execution preflight fixture") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("push", "origin", "main") | Out-Null
    $executionObservationSha256 = (Get-FileHash -LiteralPath $executionObservationPath -Algorithm SHA256).Hash.ToLowerInvariant()

    & git init --bare $planningRemote | Out-Null
    & git init $planningRepo | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("config", "user.name", "Automation Planning Test") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("config", "user.email", "planning@example.invalid") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("config", "core.autocrlf", "false") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $planningRepo "planning-seed.txt"), "planning seed`n", $encoding)
    Invoke-TestGit -Path $planningRepo -Arguments @("add", "planning-seed.txt") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "planning seed") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("branch", "-M", "main") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("remote", "add", "origin", $planningRemote) | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("push", "-u", "origin", "main") | Out-Null

    $workspace = New-TestWorkspace -Root (Join-Path $planningRepo "project") -ProjectId "automation-test" -UnitId "unit-auto-001"
    $instructionUnitPath = Join-Path $workspace "iteration-units\unit-auto-001.json"
    $instructionUnit = Get-Content -LiteralPath $instructionUnitPath -Raw | ConvertFrom-Json
    $instructionUnit | Add-Member -NotePropertyName work_mode -NotePropertyValue "feature"
    $instructionUnit | Add-Member -NotePropertyName claim_requirements -NotePropertyValue ([pscustomobject][ordered]@{
        minimum_free_disk_mib = 1
        required_tools = @(
            [pscustomobject][ordered]@{ tool_id = "git"; executable = "git"; purpose = "Observe exact repository identities." },
            [pscustomobject][ordered]@{ tool_id = "pwsh"; executable = "pwsh"; purpose = "Run portable workflow checks." }
        )
        product_inputs = @([pscustomobject][ordered]@{ input_id = "seed-source"; repo_id = "project-shell"; path = "src/seed.txt"; kind = "file"; expected_sha256 = (Get-FileHash -LiteralPath (Join-Path $repo "src\seed.txt") -Algorithm SHA256).Hash.ToLowerInvariant() })
    })
    $instructionUnit.instruction_impact = "update"
    [void]$instructionUnit.PSObject.Properties.Remove("instruction_none_justification")
    $instructionUnit.allowed_repositories[0].allowed_paths += "AGENTS.md"
    $instructionUnit.instruction_surfaces = @(
        [pscustomobject][ordered]@{ surface_kind = "agents"; path = "<project-shell>/AGENTS.md"; owner = "project-shell"; change_reason = "Exercise exact agent-entrypoint completion."; action = "update"; status = "planned"; validation = "Review the stable observed file hash."; skill_id = $null },
        [pscustomobject][ordered]@{ surface_kind = "router-doc"; path = "<project-shell>/docs/workflow.md"; owner = "project-shell"; change_reason = "Exercise exact router completion."; action = "update"; status = "planned"; validation = "Review the stable observed file hash."; skill_id = $null },
        [pscustomobject][ordered]@{ surface_kind = "compatibility-doc"; path = "<project-shell>/docs/compatibility.md"; owner = "project-shell"; change_reason = "Exercise exact compatibility-record completion."; action = "update"; status = "planned"; validation = "Review the stable observed file hash."; skill_id = $null },
        [pscustomobject][ordered]@{ surface_kind = "roadmap-doc"; path = "<project-shell>/docs/roadmap.md"; owner = "project-shell"; change_reason = "Exercise exact roadmap-record completion."; action = "update"; status = "planned"; validation = "Review the stable observed file hash."; skill_id = $null }
    )
    Write-TestJson -Path $instructionUnitPath -Value $instructionUnit
    $nextUnit = New-TestUnit -ProjectId "automation-test" -UnitId "unit-auto-002"
    $nextUnit.prerequisites = @("unit-auto-001")
    Write-TestJson -Path (Join-Path $workspace "iteration-units\unit-auto-002.json") -Value $nextUnit
    $repoMapPath = Join-Path $testRoot "repo-map.json"
    Write-TestJson -Path $repoMapPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.repository_map.v1"; repositories = @(
        [ordered]@{ repo_id = "project-shell"; path = $repo; role = "source" },
        [ordered]@{ repo_id = "workflow-planning"; path = $planningRepo; role = "planning" },
        [ordered]@{ repo_id = "skill-surfaces"; path = $skillsRoot; role = "source"; aliases = @("skills-root") }
    ) })
    $receiptRoot = Join-Path $workspace "receipts"
    $fixed = "2026-01-02T03:04:05.0000000Z"

    # The exact current-feature shape that needs a schema-only correction may
    # retain two non-writable lifecycle-routed skill reviews. Inspect must use
    # the same bounded semantic as the correction and contract validator.
    $reviewCompatibilityUnitId = "unit-current-review-compatibility"
    $reviewCompatibilityWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "current-review-compatibility") -ProjectId "current-review-compatibility" -UnitId $reviewCompatibilityUnitId
    $reviewCompatibilityUnitPath = Join-Path $reviewCompatibilityWorkspace "iteration-units\$reviewCompatibilityUnitId.json"
    $reviewCompatibilityUnit = Get-Content -LiteralPath $reviewCompatibilityUnitPath -Raw | ConvertFrom-Json
    $reviewCompatibilityUnit.status = "active"
    $reviewCompatibilityUnit | Add-Member -NotePropertyName work_mode -NotePropertyValue "feature"
    $reviewCompatibilityUnit | Add-Member -NotePropertyName guard_profile -NotePropertyValue "locked"
    $reviewCompatibilityUnit.change_categories = @("implementation", "authority", "validation", "public-private-boundary")
    $reviewCompatibilityUnit.instruction_impact = "update"
    $reviewCompatibilityUnit.allowed_repositories[0].allowed_paths += "AGENTS.md"
    [void]$reviewCompatibilityUnit.PSObject.Properties.Remove("instruction_none_justification")
    $reviewCompatibilityUnit.instruction_surfaces = @(
        [pscustomobject][ordered]@{ surface_kind = "agents"; path = "<project-shell>/AGENTS.md"; owner = "project-shell"; change_reason = "Retain the required current-unit entrypoint."; action = "update"; status = "planned"; validation = "Synthetic current-unit instruction fixture."; skill_id = $null },
        [pscustomobject][ordered]@{ surface_kind = "router-doc"; path = "<project-shell>/docs/workflow.md"; owner = "project-shell"; change_reason = "Retain the required current-unit router."; action = "update"; status = "planned"; validation = "Synthetic current-unit instruction fixture."; skill_id = $null },
        [pscustomobject][ordered]@{ surface_kind = "skill"; path = "<skills-root>/rusty-morphospace/SKILL.md"; owner = "workflow-maintainer"; change_reason = "Correct the current active-unit contract without claiming an instruction update."; action = "review-no-change"; status = "planned"; validation = "CompleteInstructionSurfaces must observe and complete this declared surface separately."; skill_id = "rusty-morphospace" },
        [pscustomobject][ordered]@{ surface_kind = "skill"; path = "<skills-root>/system-engineering/SKILL.md"; owner = "workflow-maintainer"; change_reason = "Correct the current active-unit contract without claiming an instruction update."; action = "review-no-change"; status = "planned"; validation = "CompleteInstructionSurfaces must observe and complete this declared surface separately."; skill_id = "system-engineering" }
    )
    Write-TestJson -Path $reviewCompatibilityUnitPath -Value $reviewCompatibilityUnit
    $reviewCompatibilityStatePath = Join-Path $reviewCompatibilityWorkspace "workspace.state.json"
    $reviewCompatibilityState = Get-Content -LiteralPath $reviewCompatibilityStatePath -Raw | ConvertFrom-Json
    $reviewCompatibilityState.current_unit = $reviewCompatibilityUnitId
    $reviewCompatibilityState.next_ready_unit = $null
    Write-TestJson -Path $reviewCompatibilityStatePath -Value $reviewCompatibilityState
    $reviewCompatibilityInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $reviewCompatibilityWorkspace -UnitId $reviewCompatibilityUnitId -RepoMapPath $repoMapPath -Timestamp $fixed
    $reviewCompatibilityCheck = @($reviewCompatibilityInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq "instruction-action-compatibility" })
    Assert-Automation ($reviewCompatibilityCheck.Count -eq 1 -and [string]$reviewCompatibilityCheck[0].outcome -ceq "pass") "current lifecycle-routed skill reviews did not pass Inspect instruction compatibility"

    $extraReviewUnit = $reviewCompatibilityUnit | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $extraReviewUnit.instruction_surfaces += [pscustomobject][ordered]@{ surface_kind = "skill"; path = "<skills-root>/rust-work-graph/SKILL.md"; owner = "workflow-maintainer"; change_reason = "Negative extra skill fixture."; action = "review-no-change"; status = "planned"; validation = "Must reject as non-required."; skill_id = "rust-work-graph" }
    Write-TestJson -Path $reviewCompatibilityUnitPath -Value $extraReviewUnit
    $extraReviewInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $reviewCompatibilityWorkspace -UnitId $reviewCompatibilityUnitId -RepoMapPath $repoMapPath -Timestamp $fixed
    $extraReviewCheck = @($extraReviewInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq "instruction-action-compatibility" })
    Assert-Automation ($extraReviewCheck.Count -eq 1 -and [string]$extraReviewCheck[0].outcome -ceq "fail" -and @($extraReviewCheck[0].reason_codes) -contains "instruction-action-mode-mismatch") "non-required review skill weakened Inspect compatibility"

    $writableReviewUnit = $reviewCompatibilityUnit | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $writableReviewUnit.allowed_repositories[0].allowed_paths += "<skills-root>/rusty-morphospace/"
    Write-TestJson -Path $reviewCompatibilityUnitPath -Value $writableReviewUnit
    $writableReviewInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $reviewCompatibilityWorkspace -UnitId $reviewCompatibilityUnitId -RepoMapPath $repoMapPath -Timestamp $fixed
    $writableReviewCheck = @($writableReviewInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq "instruction-action-compatibility" })
    Assert-Automation ($writableReviewCheck.Count -eq 1 -and [string]$writableReviewCheck[0].outcome -ceq "fail" -and @($writableReviewCheck[0].reason_codes) -contains "instruction-action-mode-mismatch") "writable review skill weakened Inspect compatibility"

    # This portable fixture has the same public structural shape as the parked
    # persistent Float32 inlet proposal: one source repository can update its
    # own instructions, while the exact lifecycle-routed installed skills are
    # registered separately and remain review-only. It contains no live plan,
    # proposal digest, host path, or private planning evidence.
    $portableProposalId = 'portable-inlet-instruction-preflight'
    $portableWorkspace = New-TestWorkspace -Root (Join-Path $testRoot 'portable-inlet-instruction-preflight') -ProjectId 'portable-inlet-instruction-preflight' -UnitId $portableProposalId
    $portableUnitPath = Join-Path $portableWorkspace "iteration-units\$portableProposalId.json"
    $portableUnit = Get-Content -LiteralPath $portableUnitPath -Raw | ConvertFrom-Json
    $portableUnit.status = 'proposed'
    $portableUnit | Add-Member -NotePropertyName work_mode -NotePropertyValue 'feature'
    $portableUnit | Add-Member -NotePropertyName guard_profile -NotePropertyValue 'locked'
    $portableUnit | Add-Member -NotePropertyName claim_requirements -NotePropertyValue ([pscustomobject][ordered]@{
        minimum_free_disk_mib = 1; required_tools = @(); product_inputs = @()
    })
    $portableUnit.change_categories = @('state-machine', 'validation-routing')
    $portableUnit.instruction_impact = 'update'
    [void]$portableUnit.PSObject.Properties.Remove('instruction_none_justification')
    $portableUnit.allowed_repositories[0].allowed_paths = @('AGENTS.md', 'docs/workflow.md', 'src/', 'morphospace/')
    $portableUnit.instruction_surfaces = @(
        [pscustomobject][ordered]@{ surface_kind='agents'; path='<project-shell>/AGENTS.md'; owner='project-shell'; change_reason='Update the repository-owned validation entrypoint.'; action='update'; status='planned'; validation='Synthetic Ready/Inspect/Claim parity fixture.'; skill_id=$null },
        [pscustomobject][ordered]@{ surface_kind='router-doc'; path='<project-shell>/docs/workflow.md'; owner='project-shell'; change_reason='Update the repository-owned validation router.'; action='update'; status='planned'; validation='Synthetic Ready/Inspect/Claim parity fixture.'; skill_id=$null },
        [pscustomobject][ordered]@{ surface_kind='skill'; path='<skills-root>/rusty-morphospace/SKILL.md'; owner='workflow-maintainer'; change_reason='Review the registered external lifecycle skill without claiming a repository edit.'; action='review-no-change'; status='planned'; validation='Bound repository-map skill registration.'; skill_id='rusty-morphospace' },
        [pscustomobject][ordered]@{ surface_kind='skill'; path='<skills-root>/system-engineering/SKILL.md'; owner='workflow-maintainer'; change_reason='Review the registered external lifecycle skill without claiming a repository edit.'; action='review-no-change'; status='planned'; validation='Bound repository-map skill registration.'; skill_id='system-engineering' }
    )
    Write-TestJson -Path $portableUnitPath -Value $portableUnit
    $portableStatePath = Join-Path $portableWorkspace 'workspace.state.json'
    $portableState = Get-Content -LiteralPath $portableStatePath -Raw | ConvertFrom-Json
    $portableState.next_ready_unit = $null
    Write-TestJson -Path $portableStatePath -Value $portableState
    $portableInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $repoMapPath -Timestamp $fixed
    $portableInspectCheck = @($portableInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
    Assert-Automation ($portableInspect.claim_preflight.ready_to_claim -and $portableInspectCheck.Count -eq 1 -and [string]$portableInspectCheck[0].outcome -ceq 'pass') 'proposed feature review compatibility did not pass Inspect'
    $portableReady = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $repoMapPath -Timestamp $fixed -Execute
    Assert-Automation ($portableReady.transition -eq 'proposed-to-ready' -and [string](Get-Content -LiteralPath $portableUnitPath -Raw | ConvertFrom-Json).status -eq 'ready') 'Ready rejected the registered external-skill review shape'
    $portableReadyInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $repoMapPath -Timestamp $fixed
    $portableClaim = Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $repoMapPath -Timestamp $fixed -Execute
    Assert-Automation ($portableReadyInspect.claim_preflight.ready_to_claim -and $portableClaim.transition -eq 'ready-to-active') 'Ready, Inspect, and Claim did not agree on the registered external-skill review shape'

    # W-014 begins a successor only through the public owner action.  Keep this
    # fixture on the established repository-map/guard path; no synthetic
    # canonicalization or direct state transition is used here.
    $envelopeWorkspace = New-TestWorkspace -Root (Join-Path $testRoot 'development-envelope-admission') -ProjectId 'development-envelope-admission' -UnitId 'u001'
    $envelopeUnitPath = Join-Path $envelopeWorkspace 'iteration-units\u001.json'
    $envelopeUnit = Get-Content -Raw -LiteralPath $envelopeUnitPath | ConvertFrom-Json
    $envelopeUnit.status = 'accepted'
    Write-TestJson -Path $envelopeUnitPath -Value $envelopeUnit
    $envelopeStatePath = Join-Path $envelopeWorkspace 'workspace.state.json'
    $envelopeState = Get-Content -Raw -LiteralPath $envelopeStatePath | ConvertFrom-Json
    $envelopeState.current_unit = $null; $envelopeState.next_ready_unit = $null; $envelopeState.last_accepted_receipt = 'receipts/u001-accepted.json'; $envelopeState.last_event_id = 'u001-accepted'
    Write-TestJson -Path $envelopeStatePath -Value $envelopeState
    $envelopeEventsPath = Join-Path $envelopeWorkspace 'iteration-events.jsonl'
    [IO.File]::WriteAllText($envelopeEventsPath, (([ordered]@{ schema='rusty.morphospace.workflow.iteration_event.v1'; event_id='u001-accepted'; sequence=1; timestamp=$fixed; project_id='development-envelope-admission'; unit_id='u001'; event_type='state-transition'; summary='Accepted predecessor.'; receipts=@('receipts/u001-accepted.json') } | ConvertTo-Json -Compress) + [Environment]::NewLine), $encoding)
    $envelopeSourceCommit = (@(Invoke-TestGit -Path $repo -Arguments @('rev-parse','HEAD'))[0]).Trim().ToLowerInvariant()
    $envelopeSourceTree = (@(Invoke-TestGit -Path $repo -Arguments @('rev-parse','HEAD^{tree}'))[0]).Trim().ToLowerInvariant()
    $envelopePreparationId = 'u002-envelope'; $envelopePreparationReceiptRelative = 'receipts/u002-envelope.json'; $envelopeSourceRelative = 'source-composition.json'; $envelopePreparationTransactionId = "$envelopePreparationId-prepared-transition"; $envelopePreparationEventId = "$envelopePreparationId-prepared"
    $envelopeSourceRow = [ordered]@{ repo_id='project-shell'; role='source'; commit=$envelopeSourceCommit; tree=$envelopeSourceTree; branch='main'; materialization_path='project-repo'; tracked_worktree_clean=$true }
    $envelopeSourceIdentity = [ordered]@{ project_id='development-envelope-admission'; preparation_id=$envelopePreparationId; repositories=@($envelopeSourceRow) }
    $envelopeSourceComposition = [ordered]@{ schema='rusty.morphospace.workflow.development_envelope_source_composition.v1'; lock_id='u002-envelope-source-fixture'; preparation_id=$envelopePreparationId; project_id='development-envelope-admission'; fingerprint=(Get-TestCanonicalHash ([pscustomobject]$envelopeSourceIdentity)); repositories=@($envelopeSourceRow); status='locked'; does_not_prove=@('Fixture-only preparation source lock; does not admit a unit.') }
    $envelopeSourcePath = Join-Path $envelopeWorkspace $envelopeSourceRelative; Write-TestJson -Path $envelopeSourcePath -Value $envelopeSourceComposition
    $envelopeMapPath = Join-Path $envelopeWorkspace 'repository-map.json'; Copy-Item -LiteralPath $repoMapPath -Destination $envelopeMapPath
    $envelopeScope = [ordered]@{ schema='rusty.morphospace.workflow.agent_scope_assessment.v1'; objective='Add one bounded successor without declaring every discovered path.'; owner_repositories=@([ordered]@{repo_id='project-shell';source_roots=@('docs/','src/')}); public_private_boundary='public'; allowed_change_categories=@('implementation'); allowed_effect_categories=@('none'); allowed_permission_categories=@('none'); build_envelope=[ordered]@{class='none';allowed_profiles=@('workflow')}; device_envelope=[ordered]@{requirement='forbidden';allowed_kinds=@()}; non_scope=@('Devices.'); prerequisites=@('u001'); validation_class='quick'; evidence_expectations=@('receipt'); cleanup_expectations=@('no residue') }
    $envelopePredecessor = Read-TestProtocolJson $envelopeUnitPath; $envelopeProject = Read-TestProtocolJson (Join-Path $envelopeWorkspace 'project.spec.json'); $envelopeFeatureLock = Read-TestProtocolJson (Join-Path $envelopeWorkspace 'feature.lock.json'); $envelopePreparationPreState = Read-TestProtocolJson $envelopeStatePath
    $envelopePreEventsHash = Get-TestFileHash $envelopeEventsPath; $envelopeMapHash = Get-TestFileHash $envelopeMapPath; $envelopeSourceHash = Get-TestFileHash $envelopeSourcePath; $envelopeSourceCanonicalHash = Get-TestCanonicalHash $envelopeSourceComposition
    $envelopePreparationReceipt = [ordered]@{ schema='rusty.morphospace.workflow.development_envelope_preparation_receipt.v1'; preparation_id=$envelopePreparationId; project_id='development-envelope-admission'; predecessor_unit_id='u001'; input_sha256=('0'*64); envelope=[ordered]@{owner_repositories=$envelopeScope.owner_repositories;public_private_boundary=$envelopeScope.public_private_boundary;allowed_change_categories=$envelopeScope.allowed_change_categories;allowed_effect_categories=$envelopeScope.allowed_effect_categories;allowed_permission_categories=$envelopeScope.allowed_permission_categories;build_envelope=$envelopeScope.build_envelope;device_envelope=$envelopeScope.device_envelope}; project_sha256=(Get-TestCanonicalHash $envelopeProject); feature_lock_sha256=(Get-TestCanonicalHash $envelopeFeatureLock); source_composition=[ordered]@{path=$envelopeSourceRelative;sha256=$envelopeSourceCanonicalHash}; does_not_prove=@('Fixture preparation does not admit, claim, validate, accept, or publish a future unit.') }
    $envelopePreparationReceiptPath = Join-Path $envelopeWorkspace $envelopePreparationReceiptRelative; Write-TestJson -Path $envelopePreparationReceiptPath -Value $envelopePreparationReceipt
    $envelopePreparationEvent = [ordered]@{ schema='rusty.morphospace.workflow.iteration_event.v1'; event_id=$envelopePreparationEventId; sequence=2; timestamp=$fixed; project_id='development-envelope-admission'; unit_id='u001'; event_type='decision'; summary='Prepared fixture development envelope; future admission remains bind-only.'; receipts=@($envelopePreparationReceiptRelative) }
    $envelopePreparationState = $envelopePreparationPreState | ConvertTo-Json -Depth 64 | ConvertFrom-Json; $envelopePreparationState.last_event_id=$envelopePreparationEventId; Write-TestJson -Path $envelopeStatePath -Value $envelopePreparationState; [IO.File]::AppendAllText($envelopeEventsPath, (($envelopePreparationEvent | ConvertTo-Json -Compress) + [Environment]::NewLine), $encoding)
    $envelopePreparationIntent = [ordered]@{ schema='rusty.morphospace.workflow.development_envelope_preparation_intent.v1'; transaction_id=$envelopePreparationTransactionId; created_at=$fixed; pre=[ordered]@{project=[ordered]@{path='project.spec.json';sha256=(Get-TestCanonicalHash $envelopeProject);document=$envelopeProject};state=[ordered]@{path='workspace.state.json';sha256=(Get-TestCanonicalHash $envelopePreparationPreState);document=$envelopePreparationPreState};feature_lock=[ordered]@{path='feature.lock.json';sha256=(Get-TestCanonicalHash $envelopeFeatureLock);document=$envelopeFeatureLock};predecessor_unit=[ordered]@{path='iteration-units/u001.json';sha256=(Get-TestCanonicalHash $envelopePredecessor);document=$envelopePredecessor};events=[ordered]@{path='iteration-events.jsonl';sha256=$envelopePreEventsHash};repository_map=[ordered]@{path='repository-map.json';sha256=$envelopeMapHash}};target=[ordered]@{project=[ordered]@{path='project.spec.json';sha256=(Get-TestCanonicalHash $envelopeProject);document=$envelopeProject};state=[ordered]@{path='workspace.state.json';sha256=(Get-TestCanonicalHash $envelopePreparationState);document=$envelopePreparationState};feature_lock=[ordered]@{path='feature.lock.json';sha256=(Get-TestCanonicalHash $envelopeFeatureLock);document=$envelopeFeatureLock};predecessor_unit=[ordered]@{path='iteration-units/u001.json';sha256=(Get-TestCanonicalHash $envelopePredecessor);document=$envelopePredecessor};events=[ordered]@{path='iteration-events.jsonl';sha256=$envelopePreEventsHash};repository_map=[ordered]@{path='repository-map.json';sha256=$envelopeMapHash}};artifacts=@([ordered]@{path=$envelopePreparationReceiptRelative;sha256=(Get-TestCanonicalHash $envelopePreparationReceipt);bytes_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($envelopePreparationReceiptPath))},[ordered]@{path=$envelopeSourceRelative;sha256=(Get-TestCanonicalHash $envelopeSourceComposition);bytes_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($envelopeSourcePath))});event=$envelopePreparationEvent;status='prepared'}
    $envelopePreparationIntentPath = Join-Path $envelopeWorkspace "receipts\transactions\$envelopePreparationTransactionId.intent.json"; [IO.Directory]::CreateDirectory((Split-Path -Parent $envelopePreparationIntentPath)) | Out-Null; Write-TestJson -Path $envelopePreparationIntentPath -Value $envelopePreparationIntent
    $envelopePreparationCompletionPath = Join-Path $envelopeWorkspace "receipts\transactions\$envelopePreparationTransactionId.completion.json"; Write-TestJson -Path $envelopePreparationCompletionPath -Value ([ordered]@{schema='rusty.morphospace.workflow.development_envelope_preparation_completion.v1';transaction_id=$envelopePreparationTransactionId;completed_at=$fixed;intent_sha256=(Get-TestFileHash $envelopePreparationIntentPath);target_project_sha256=(Get-TestCanonicalHash $envelopeProject);target_state_sha256=(Get-TestCanonicalHash $envelopePreparationState);target_feature_lock_sha256=(Get-TestCanonicalHash $envelopeFeatureLock);event_id=$envelopePreparationEventId;status='committed'})
    $envelopeU002 = $envelopeUnit | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $envelopeU002.unit_id='u002'; $envelopeU002.status='proposed'; $envelopeU002.prerequisites=@('u001'); $envelopeU002.allowed_repositories[0].allowed_paths=@('docs/')
    $envelopeU002 | Add-Member -NotePropertyName agent_scope_assessment -NotePropertyValue ([pscustomobject]$envelopeScope)
    $envelopeU002 | Add-Member -NotePropertyName source_composition -NotePropertyValue ([pscustomobject][ordered]@{mode='exact-lock';lock_path='source-composition.json';materialization_receipt=$null})
    $envelopeProject = Read-TestProtocolJson (Join-Path $envelopeWorkspace 'project.spec.json')
    $envelopeStateForAdmission = Read-TestProtocolJson $envelopeStatePath
    $envelopeFeatureLock = Read-TestProtocolJson (Join-Path $envelopeWorkspace 'feature.lock.json')
    $envelopeProjectHash = Get-TestCanonicalHash $envelopeProject
    $envelopeStateHash = Get-TestCanonicalHash $envelopeStateForAdmission
    $envelopeFeatureLockHash = Get-TestCanonicalHash $envelopeFeatureLock
    $envelopeAdmission=[ordered]@{ schema='rusty.morphospace.workflow.development_unit_admission.v1'; admission_id='u002-admission'; project_id='development-envelope-admission'; unit_id='u002'; preparation=[ordered]@{preparation_id=$envelopePreparationId;receipt_path=$envelopePreparationReceiptRelative;receipt_sha256=(Get-TestFileHash $envelopePreparationReceiptPath);source_composition_path=$envelopeSourceRelative;source_composition_sha256=(Get-TestFileHash $envelopeSourcePath)}; agent_scope_assessment=$envelopeScope; unit=$envelopeU002; expected=[ordered]@{ project_sha256=$envelopeProjectHash; state_sha256=$envelopeStateHash; feature_lock_sha256=$envelopeFeatureLockHash; source_composition_path=$envelopeSourceRelative;source_composition_sha256=(Get-TestFileHash $envelopeSourcePath);repository_map_path='repository-map.json';repository_map_sha256=(Get-TestFileHash $envelopeMapPath);events_sha256=(Get-TestFileHash $envelopeEventsPath);events_length=([IO.FileInfo]$envelopeEventsPath).Length;event_tail_id=$envelopePreparationEventId}; does_not_prove=@('Does not claim, validate, accept, or publish.') }
    $envelopeAdmissionPath=Join-Path $testRoot 'development-envelope-admission.json'; $envelopeAdmissionOut=Join-Path $envelopeWorkspace 'receipts\u002-admission.json'; Write-TestJson -Path $envelopeAdmissionPath -Value $envelopeAdmission
    $envelopeAdmissionDry=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action AdmitDevelopmentUnit -WorkspaceRoot $envelopeWorkspace -DevelopmentUnitAdmission $envelopeAdmissionPath -OutPath $envelopeAdmissionOut -Timestamp $fixed | ConvertFrom-Json
    $envelopeAdmissionRun=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action AdmitDevelopmentUnit -WorkspaceRoot $envelopeWorkspace -DevelopmentUnitAdmission $envelopeAdmissionPath -ExpectedDevelopmentUnitAdmissionSha256 $envelopeAdmissionDry.audit_receipt.sha256 -OutPath $envelopeAdmissionOut -Timestamp $fixed -Execute | ConvertFrom-Json
    $envelopeAdmissionReplay=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action AdmitDevelopmentUnit -WorkspaceRoot $envelopeWorkspace -DevelopmentUnitAdmission $envelopeAdmissionPath -ExpectedDevelopmentUnitAdmissionSha256 $envelopeAdmissionDry.audit_receipt.sha256 -OutPath $envelopeAdmissionOut -Timestamp $fixed -Execute | ConvertFrom-Json
    $automationReceiptV2 = Join-Path $RepoRoot 'schemas\work-unit-automation-receipt-v2.schema.json'
    Assert-Automation (
        (Test-Json -Json ($envelopeAdmissionDry | ConvertTo-Json -Depth 32 -Compress) -SchemaFile $automationReceiptV2) -and
        (Test-Json -Json ($envelopeAdmissionRun | ConvertTo-Json -Depth 32 -Compress) -SchemaFile $automationReceiptV2) -and
        (Test-Json -Json ($envelopeAdmissionReplay | ConvertTo-Json -Depth 32 -Compress) -SchemaFile $automationReceiptV2) -and
        $null -eq $envelopeAdmissionDry.status_before -and $null -eq $envelopeAdmissionDry.event_id -and
        $envelopeAdmissionRun.transition -eq 'development-unit-admitted' -and $null -ne $envelopeAdmissionRun.event_id -and
        $envelopeAdmissionReplay.transition -eq 'development-unit-already-admitted' -and $null -eq $envelopeAdmissionReplay.event_id -and
        (Test-Path -LiteralPath (Join-Path $envelopeWorkspace 'iteration-units\u002.json')) -and
        (Test-Path -LiteralPath $envelopeAdmissionOut)
    ) 'public AdmitDevelopmentUnit did not emit schema-valid dry/executed receipts or atomically admit the accepted-predecessor successor'
    $envelopeReady = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action Ready -WorkspaceRoot $envelopeWorkspace -UnitId 'u002' -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | ConvertFrom-Json
    $envelopeInspect = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action Inspect -WorkspaceRoot $envelopeWorkspace -UnitId 'u002' -RepoMapPath $repoMapPath -Timestamp $fixed | ConvertFrom-Json
    $envelopeClaim = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action Claim -WorkspaceRoot $envelopeWorkspace -UnitId 'u002' -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | ConvertFrom-Json
    Assert-Automation ($envelopeReady.transition -eq 'proposed-to-ready' -and $envelopeInspect.claim_preflight.ready_to_claim -and $envelopeClaim.transition -eq 'ready-to-active') 'admitted successor did not traverse normal Ready, Inspect, and Claim routes'
    $envelopeU002Path=Join-Path $envelopeWorkspace 'iteration-units\u002.json'
    $envelopeAmendment=[ordered]@{schema='rusty.morphospace.workflow.active_write_scope_amendment.v1';amendment_id='u002-discovered';project_id='development-envelope-admission';unit_id='u002';repository_id='project-shell';reason='The discovered documentation path is semantically related to the admitted objective.';semantic_rationale='The discovered path completes the bounded successor without widening its envelope.';ownership_proof=[ordered]@{repo_id='project-shell';source_roots=@('docs/','src/');tracked_paths=@('docs/','src/')};source_composition=[ordered]@{mode='exact-lock';lock_path='source-composition.json';lock_sha256=(Get-TestFileHash (Join-Path $envelopeWorkspace 'source-composition.json'))};expected=[ordered]@{status='active';current_unit='u002';project_revision=1;project_sha256=(Get-TestCanonicalHash (Read-TestProtocolJson (Join-Path $envelopeWorkspace 'project.spec.json')));state_sha256=(Get-TestCanonicalHash (Read-TestProtocolJson $envelopeStatePath));unit_sha256=(Get-TestCanonicalHash (Read-TestProtocolJson $envelopeU002Path));events_sha256=(Get-TestFileHash $envelopeEventsPath);events_length=([IO.FileInfo]$envelopeEventsPath).Length;event_tail_id=(Read-TestProtocolJson $envelopeStatePath).last_event_id};before_allowed_paths=@('docs/');after_allowed_paths=@('docs/','src/');does_not_prove=@('Does not validate, accept, or publish.')}
    $envelopeAmendmentPath=Join-Path $testRoot 'development-envelope-amendment.json';$envelopeAmendmentOut=Join-Path $envelopeWorkspace 'receipts\u002-discovered.json';Write-TestJson -Path $envelopeAmendmentPath -Value $envelopeAmendment
    $envelopeAmendmentDry=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action AmendActiveWriteScope -WorkspaceRoot $envelopeWorkspace -UnitId 'u002' -ActiveWriteScopeAmendment $envelopeAmendmentPath -OutPath $envelopeAmendmentOut -Timestamp $fixed | ConvertFrom-Json
    $envelopeAmendmentRun=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action AmendActiveWriteScope -WorkspaceRoot $envelopeWorkspace -UnitId 'u002' -ActiveWriteScopeAmendment $envelopeAmendmentPath -ExpectedActiveWriteScopeAmendmentSha256 $envelopeAmendmentDry.audit_receipt.sha256 -OutPath $envelopeAmendmentOut -Timestamp $fixed -Execute | ConvertFrom-Json
    Assert-Automation ($envelopeAmendmentRun.transition -eq 'active-write-scope-amended' -and (@((Get-Content -Raw $envelopeU002Path|ConvertFrom-Json).allowed_repositories[0].allowed_paths) -join '|') -eq 'docs/|src/' -and (Test-Path -LiteralPath $envelopeAmendmentOut)) 'public admitted-unit amendment did not preserve bounded CAS receipt semantics'

    # The same public path must bind the exact frozen closure before validation.
    $envelopeUnitBeforeFreeze = Read-TestProtocolJson $envelopeU002Path
    $envelopeStateBeforeFreeze = Read-TestProtocolJson $envelopeStatePath
    $envelopeLockBeforeFreeze = Read-TestProtocolJson (Join-Path $envelopeWorkspace 'feature.lock.json')
    $envelopeFreeze = [ordered]@{
        schema='rusty.morphospace.workflow.candidate_freeze.v1'; freeze_id='u002-freeze'; project_id='development-envelope-admission'; unit_id='u002'
        expected=[ordered]@{
            project_sha256=(Get-TestCanonicalHash (Read-TestProtocolJson (Join-Path $envelopeWorkspace 'project.spec.json'))); state_sha256=(Get-TestCanonicalHash $envelopeStateBeforeFreeze); unit_sha256=(Get-TestCanonicalHash $envelopeUnitBeforeFreeze); feature_lock_sha256=(Get-TestCanonicalHash $envelopeLockBeforeFreeze)
            source_composition_path='source-composition.json'; source_composition_sha256=(Get-TestFileHash (Join-Path $envelopeWorkspace 'source-composition.json')); repository_map_path='repository-map.json'; repository_map_sha256=(Get-TestFileHash (Join-Path $envelopeWorkspace 'repository-map.json')); events_sha256=(Get-TestFileHash $envelopeEventsPath); events_length=([IO.FileInfo]$envelopeEventsPath).Length; event_tail_id=$envelopeStateBeforeFreeze.last_event_id
        }
        final_repositories=@([ordered]@{repo_id='project-shell';commit=$envelopeSourceCommit;tree=$envelopeSourceTree}); changed_paths=@([ordered]@{repo_id='project-shell';paths=@('docs/','src/')}); cleanliness_policy='clean-only'
        instruction_surfaces=@([ordered]@{path='README.md';disposition='reviewed-no-change'}); feature_lock=[ordered]@{revision=$envelopeLockBeforeFreeze.revision;sha256=(Get-TestCanonicalHash $envelopeLockBeforeFreeze)}; effects=@('none'); permissions=@('none'); device_use=@('none')
        test_matrix=@([ordered]@{test_id='quick';command='Test-WorkUnitAutomation.ps1'}); cleanup_evidence=@('Synthetic workspace cleanup is owned by the fixture finally block.'); source_composition=[ordered]@{path='source-composition.json';sha256=(Get-TestFileHash (Join-Path $envelopeWorkspace 'source-composition.json'))}; does_not_prove=@('Does not validate, accept, or publish.')
    }
    $envelopeFreezePath=Join-Path $testRoot 'development-envelope-freeze.json'; $envelopeFreezeOut=Join-Path $envelopeWorkspace 'receipts\u002-freeze.json'; Write-TestJson -Path $envelopeFreezePath -Value $envelopeFreeze
    $envelopeFreezeDry=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action FreezeCandidate -WorkspaceRoot $envelopeWorkspace -UnitId 'u002' -CandidateFreeze $envelopeFreezePath -OutPath $envelopeFreezeOut -Timestamp $fixed | ConvertFrom-Json
    $envelopeFreezeRun=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action FreezeCandidate -WorkspaceRoot $envelopeWorkspace -UnitId 'u002' -CandidateFreeze $envelopeFreezePath -ExpectedCandidateFreezeSha256 $envelopeFreezeDry.audit_receipt.sha256 -OutPath $envelopeFreezeOut -Timestamp $fixed -Execute | ConvertFrom-Json
    $envelopeFrozenUnit=Read-TestProtocolJson $envelopeU002Path; $envelopeFrozenState=Read-TestProtocolJson $envelopeStatePath
    $envelopeFreezeIntent=Join-Path $envelopeWorkspace 'receipts\transactions\u002-freeze-recorded-transition.intent.json'; $envelopeFreezeCompletion=Join-Path $envelopeWorkspace 'receipts\transactions\u002-freeze-recorded-transition.completion.json'
    $envelopeFreezeEvents=@(Get-Content -LiteralPath $envelopeEventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Automation (
        $envelopeFreezeRun.transition -eq 'candidate-frozen' -and $envelopeFreezeRun.status_before -eq 'active' -and $envelopeFreezeRun.status_after -eq 'active' -and $envelopeFreezeRun.current_unit_before -eq 'u002' -and $envelopeFreezeRun.current_unit_after -eq 'u002' -and
        (Test-Json -Json ($envelopeFreezeDry | ConvertTo-Json -Depth 32) -SchemaFile $automationReceiptV2) -and $null -eq $envelopeFreezeDry.event_id -and
        (Test-Json -Json ($envelopeFreezeRun | ConvertTo-Json -Depth 32) -SchemaFile $automationReceiptV2) -and $null -ne $envelopeFreezeRun.event_id -and
        $envelopeFrozenState.current_unit -eq 'u002' -and $envelopeFrozenState.last_event_id -eq 'u002-freeze-recorded' -and $envelopeFrozenUnit.status -eq 'active' -and $envelopeFrozenUnit.candidate_freeze.freeze_id -eq 'u002-freeze' -and $envelopeFrozenUnit.candidate_freeze.receipt_path -eq 'receipts/u002-freeze.json' -and $envelopeFrozenUnit.candidate_freeze.receipt_sha256 -eq $envelopeFreezeDry.audit_receipt.sha256 -and
        (Get-TestFileHash $envelopeFreezeOut) -eq $envelopeFreezeDry.audit_receipt.sha256 -and (Test-Path -LiteralPath $envelopeFreezeIntent) -and (Test-Path -LiteralPath $envelopeFreezeCompletion) -and
        (@($envelopeFreezeEvents | Where-Object { $_.event_id -eq 'u002-freeze-recorded' -and $_.unit_id -eq 'u002' -and @($_.receipts) -contains 'receipts/u002-freeze.json' }).Count -eq 1)
    ) 'public FreezeCandidate did not preserve exact receipt, state, event, CAS, and transition evidence'
    $envelopeFreezeReplay=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action FreezeCandidate -WorkspaceRoot $envelopeWorkspace -UnitId 'u002' -CandidateFreeze $envelopeFreezePath -ExpectedCandidateFreezeSha256 $envelopeFreezeDry.audit_receipt.sha256 -OutPath $envelopeFreezeOut -Timestamp $fixed -Execute | ConvertFrom-Json
    Assert-Automation ($envelopeFreezeReplay.transition -eq 'candidate-already-frozen' -and $null -eq $envelopeFreezeReplay.event_id -and (Test-Json -Json ($envelopeFreezeReplay | ConvertTo-Json -Depth 32) -SchemaFile $automationReceiptV2) -and (Get-TestFileHash $envelopeFreezeOut) -eq $envelopeFreezeDry.audit_receipt.sha256) 'identical public FreezeCandidate replay was not schema-valid and idempotent'
    Remove-Module CandidateFreeze -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -Force
    Assert-Automation (Test-MorphospaceFrozenCandidate -WorkspaceRoot $envelopeWorkspace -Unit (Read-TestProtocolJson $envelopeU002Path)) 'frozen candidate did not survive a verifier module reload'

    # A freeze is a live validation gate, not merely a marker: every frozen
    # authority input and the assessment-derived instruction/effect/device
    # envelope must reject drift before the public BeginValidation transition.
    $freezeDrifts = @(
        [pscustomobject]@{ name='project'; mutate={ param($root) $p=Join-Path $root 'project.spec.json'; $d=Read-TestProtocolJson $p; $d.revision=[int]$d.revision+1; Write-TestJson $p $d } },
        [pscustomobject]@{ name='feature-lock'; mutate={ param($root) $p=Join-Path $root 'feature.lock.json'; $d=Read-TestProtocolJson $p; $d.revision=[int]$d.revision+1; Write-TestJson $p $d } },
        [pscustomobject]@{ name='source-composition'; mutate={ param($root) $p=Join-Path $root 'source-composition.json'; [IO.File]::AppendAllText($p," `n",$encoding) } },
        [pscustomobject]@{ name='repository-map'; mutate={ param($root) $p=Join-Path $root 'repository-map.json'; [IO.File]::AppendAllText($p," `n",$encoding) } },
        [pscustomobject]@{ name='state-transition'; mutate={ param($root) $p=Join-Path $root 'workspace.state.json'; $d=Read-TestProtocolJson $p; $d.last_accepted_receipt='receipts/substituted.json'; Write-TestJson $p $d } },
        [pscustomobject]@{ name='ledger-transition'; mutate={ param($root) $p=Join-Path $root 'iteration-events.jsonl'; [IO.File]::AppendAllText($p,((@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='u002-post-freeze';sequence=5;timestamp=$fixed;project_id='development-envelope-admission';unit_id='u002';event_type='state-transition';summary='Injected post-freeze ledger drift.';receipts=@()}|ConvertTo-Json -Compress)+"`n"),$encoding) } },
        [pscustomobject]@{ name='instruction-surface'; mutate={ param($root) $p=Join-Path $root 'iteration-units\u002.json'; $d=Read-TestProtocolJson $p; $d.instruction_none_justification='Changed instruction evidence after freeze.'; Write-TestJson $p $d } },
        [pscustomobject]@{ name='effect-envelope'; mutate={ param($root) $p=Join-Path $root 'iteration-units\u002.json'; $d=Read-TestProtocolJson $p; $d.agent_scope_assessment.allowed_effect_categories=@('filesystem'); Write-TestJson $p $d } },
        [pscustomobject]@{ name='permission-envelope'; mutate={ param($root) $p=Join-Path $root 'iteration-units\u002.json'; $d=Read-TestProtocolJson $p; $d.agent_scope_assessment.allowed_permission_categories=@('filesystem-write'); Write-TestJson $p $d } },
        [pscustomobject]@{ name='device-envelope'; mutate={ param($root) $p=Join-Path $root 'iteration-units\u002.json'; $d=Read-TestProtocolJson $p; $d.agent_scope_assessment.device_envelope.requirement='required'; Write-TestJson $p $d } },
        [pscustomobject]@{ name='candidate-identity'; mutate={ param($root) $p=Join-Path $root 'iteration-units\u002.json'; $d=Read-TestProtocolJson $p; $d.candidate_freeze.freeze_id='u002-wrong-freeze'; Write-TestJson $p $d } }
    )
    foreach($drift in $freezeDrifts) {
        $driftWorkspace=Copy-TestWorkspace -Source $envelopeWorkspace -Destination (Join-Path $testRoot "development-envelope-freeze-drift-$($drift.name)")
        & $drift.mutate $driftWorkspace
        $driftRejected=$false
        try { & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action BeginValidation -WorkspaceRoot $driftWorkspace -UnitId 'u002' -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null } catch { $driftRejected=$true }
        Assert-Automation $driftRejected "BeginValidation accepted post-freeze $($drift.name) drift"
    }
    $envelopeBeginValidation=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action BeginValidation -WorkspaceRoot $envelopeWorkspace -UnitId 'u002' -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | ConvertFrom-Json
    $envelopeValidatingUnit=Read-TestProtocolJson $envelopeU002Path
    Assert-Automation ($envelopeBeginValidation.transition -eq 'active-to-validating' -and $envelopeValidatingUnit.status -eq 'validating' -and (Read-TestProtocolJson $envelopeStatePath).current_unit -eq 'u002') 'BeginValidation did not consume the exact frozen admitted candidate through the public router'
    # Public-router force imports intentionally refresh their nested helper
    # modules. Restore this aggregate fixture's independently declared planning
    # helper before its later adoption coverage consumes that exported command.
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlanningProjection.psm1') -Force
    Assert-Automation ($null -ne (Get-Command Get-GitWorkspaceInventory -ErrorAction SilentlyContinue)) 'public W-014 router exercise did not restore the later adoption helper'

    $portableDamageRoot = Join-Path $testRoot 'unregistered-skill-lookalike'
    foreach ($skillId in @('rusty-morphospace', 'system-engineering')) {
        [System.IO.Directory]::CreateDirectory((Join-Path $portableDamageRoot $skillId)) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $portableDamageRoot "$skillId\SKILL.md"), "# lookalike $skillId`n", $encoding)
    }
    $unregisteredMapPath = Join-Path $testRoot 'unregistered-skill-map.json'
    $unregisteredMap = Get-Content -LiteralPath $repoMapPath -Raw | ConvertFrom-Json
    $unregisteredMap.repositories = @($unregisteredMap.repositories | Where-Object { [string]$_.repo_id -cne 'skill-surfaces' }) + @([pscustomobject][ordered]@{ repo_id='lookalike-skill-root'; path=$portableDamageRoot; role='source'; aliases=@('skills-root') })
    Write-TestJson -Path $unregisteredMapPath -Value $unregisteredMap
    $unregisteredUnit = $portableUnit | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    Write-TestJson -Path $portableUnitPath -Value $unregisteredUnit
    $unregisteredInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $unregisteredMapPath -Timestamp $fixed
    $unregisteredCheck = @($unregisteredInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
    Assert-Automation ($unregisteredCheck.Count -eq 1 -and [string]$unregisteredCheck[0].outcome -ceq 'fail') 'an arbitrary external path that resembles a skill surface passed compatibility'

    $byteDamagedMapPath = Join-Path $testRoot 'byte-damaged-skill-map.json'
    $byteDamagedMap = Get-Content -LiteralPath $repoMapPath -Raw | ConvertFrom-Json
    $byteDamagedMap.repositories = @($byteDamagedMap.repositories | ForEach-Object {
        if ([string]$_.repo_id -ceq 'skill-surfaces') {
            [pscustomobject][ordered]@{ repo_id='skill-surfaces'; path=$portableDamageRoot; role='source'; aliases=@('skills-root') }
        } else { $_ }
    })
    Write-TestJson -Path $byteDamagedMapPath -Value $byteDamagedMap
    Write-TestJson -Path $portableUnitPath -Value ($portableUnit | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
    $byteDamagedInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $byteDamagedMapPath -Timestamp $fixed
    $byteDamagedCheck = @($byteDamagedInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
    Assert-Automation ($byteDamagedCheck.Count -eq 1 -and [string]$byteDamagedCheck[0].outcome -ceq 'fail' -and @($byteDamagedCheck[0].reason_codes) -contains 'instruction-action-mode-mismatch') 'changed bytes under the registered skill-surfaces identity passed compatibility'

    $extraAliasMapPath = Join-Path $testRoot 'extra-alias-skill-map.json'
    $extraAliasMap = Get-Content -LiteralPath $repoMapPath -Raw | ConvertFrom-Json
    @($extraAliasMap.repositories | Where-Object { [string]$_.repo_id -ceq 'skill-surfaces' })[0].aliases = @('skills-root', 'extra-root')
    Write-TestJson -Path $extraAliasMapPath -Value $extraAliasMap
    $extraAliasInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $extraAliasMapPath -Timestamp $fixed
    $extraAliasCheck = @($extraAliasInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
    Assert-Automation ($extraAliasCheck.Count -eq 1 -and [string]$extraAliasCheck[0].outcome -ceq 'fail') 'extra skill-surfaces alias passed compatibility'

    $sameRootMapPath = Join-Path $testRoot 'same-root-skill-map.json'
    foreach ($skillId in @('rusty-morphospace', 'system-engineering')) {
        $sameRootDirectory = Join-Path $repo $skillId
        [System.IO.Directory]::CreateDirectory($sameRootDirectory) | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $sameRootDirectory 'SKILL.md'), [System.IO.File]::ReadAllBytes((Join-Path $canonicalSkillRoot "$skillId\SKILL.md")))
    }
    $sameRootMap = Get-Content -LiteralPath $repoMapPath -Raw | ConvertFrom-Json
    @($sameRootMap.repositories | Where-Object { [string]$_.repo_id -ceq 'skill-surfaces' })[0].path = $repo
    Write-TestJson -Path $sameRootMapPath -Value $sameRootMap
    $sameRootInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $sameRootMapPath -Timestamp $fixed
    $sameRootCheck = @($sameRootInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
    Assert-Automation ($sameRootCheck.Count -eq 1 -and [string]$sameRootCheck[0].outcome -ceq 'fail') 'skill root equal to a writable repository passed compatibility'

    $containedRoot = Join-Path $repo 'registered-skill-surfaces'
    foreach ($skillId in @('rusty-morphospace', 'system-engineering')) {
        $containedDirectory = Join-Path $containedRoot $skillId
        [System.IO.Directory]::CreateDirectory($containedDirectory) | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $containedDirectory 'SKILL.md'), [System.IO.File]::ReadAllBytes((Join-Path $canonicalSkillRoot "$skillId\SKILL.md")))
    }
    $containedRootMapPath = Join-Path $testRoot 'contained-root-skill-map.json'
    $containedRootMap = Get-Content -LiteralPath $repoMapPath -Raw | ConvertFrom-Json
    @($containedRootMap.repositories | Where-Object { [string]$_.repo_id -ceq 'skill-surfaces' })[0].path = $containedRoot
    Write-TestJson -Path $containedRootMapPath -Value $containedRootMap
    $containedRootInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $containedRootMapPath -Timestamp $fixed
    $containedRootCheck = @($containedRootInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
    Assert-Automation ($containedRootCheck.Count -eq 1 -and [string]$containedRootCheck[0].outcome -ceq 'fail') 'skill root contained by a writable repository passed compatibility'
    # These paths belong only to this damage fixture. Restore its shared
    # synthetic repository before later cases require a clean source state.
    foreach ($skillId in @('rusty-morphospace', 'system-engineering')) {
        $sameRootDirectory = Join-Path $repo $skillId
        if ([IO.Directory]::Exists($sameRootDirectory)) { [IO.Directory]::Delete($sameRootDirectory, $true) }
    }
    if ([IO.Directory]::Exists($containedRoot)) { [IO.Directory]::Delete($containedRoot, $true) }

    $writableSkillUnit = $portableUnit | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $writableSkillUnit.allowed_repositories += [pscustomobject][ordered]@{ repo_id='skill-surfaces'; allowed_paths=@('rusty-morphospace/', 'system-engineering/') }
    Assert-Automation (@($writableSkillUnit.allowed_repositories | Where-Object { [string]$_.repo_id -ceq 'skill-surfaces' }).Count -eq 1) 'writable registered-skill damage fixture did not declare the external repository'
    Write-TestJson -Path $portableUnitPath -Value $writableSkillUnit
    $writableSkillInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $repoMapPath -Timestamp $fixed
    $writableSkillCheck = @($writableSkillInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
    Assert-Automation ($writableSkillCheck.Count -eq 1 -and [string]$writableSkillCheck[0].outcome -ceq 'fail' -and @($writableSkillCheck[0].reason_codes) -contains 'instruction-action-mode-mismatch') 'review-no-change on a writable registered skill surface passed compatibility'

    $wrongCategoryUnit = $portableUnit | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $wrongCategoryUnit.change_categories += 'module-layout'
    Write-TestJson -Path $portableUnitPath -Value $wrongCategoryUnit
    $wrongCategoryInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $repoMapPath -Timestamp $fixed
    $wrongCategoryCheck = @($wrongCategoryInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
    Assert-Automation ($wrongCategoryCheck.Count -eq 1 -and [string]$wrongCategoryCheck[0].outcome -ceq 'fail' -and @($wrongCategoryCheck[0].reason_codes) -contains 'instruction-action-mode-mismatch') 'a category requiring an unreviewed third skill passed compatibility'

    $outsideUpdateUnit = $portableUnit | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    @($outsideUpdateUnit.instruction_surfaces | Where-Object { [string]$_.surface_kind -ceq 'skill' })[0].action = 'update'
    Write-TestJson -Path $portableUnitPath -Value $outsideUpdateUnit
    $outsideUpdateInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $portableWorkspace -UnitId $portableProposalId -RepoMapPath $repoMapPath -Timestamp $fixed
    $outsideUpdateCheck = @($outsideUpdateInspect.claim_preflight.coverage.checks | Where-Object { [string]$_.check_id -ceq 'instruction-action-compatibility' })
    Assert-Automation ([string]$outsideUpdateCheck[0].outcome -ceq 'fail' -and @($outsideUpdateCheck[0].reason_codes) -contains 'instruction-update-outside-write-scope') 'an update outside declared repository write scope passed compatibility'

    Write-TestJson -Path $portableUnitPath -Value $portableUnit

    # PRE-001 keeps Claim behavior unchanged while making Inspect coverage
    # explicit and machine-readable. The named shapes are synthetic; they
    # contain no private workspace evidence.
    $positivePaths = @(
        $instructionUnitPath,
        (Join-Path $workspace "workspace.state.json"),
        (Join-Path $workspace "iteration-events.jsonl")
    )
    $positiveBefore = @($positivePaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    $unit047Inspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    $unit047InspectAgain = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    $positiveAfter = @($positivePaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    Assert-Automation (
        $unit047Inspect.claim_preflight.version -eq "v2" -and
        $unit047Inspect.claim_preflight.advisory_status -eq "pass" -and
        $unit047Inspect.claim_preflight.state_mutation_performed -eq $false -and
        $unit047Inspect.claim_preflight.coverage.missing.Count -eq 0 -and
        $unit047Inspect.claim_preflight.candidate_fingerprint -match '^[0-9a-f]{64}$'
    ) "Unit047-shaped positive advisory preflight"
    Assert-Automation (
        $unit047Inspect.claim_preflight.candidate_fingerprint -ceq $unit047InspectAgain.claim_preflight.candidate_fingerprint -and
        ($unit047Inspect.claim_preflight.coverage.expected -join "`n") -ceq ($unit047InspectAgain.claim_preflight.coverage.expected -join "`n")
    ) "advisory preflight was not deterministic"
    $automationReceiptSchema = Join-Path $RepoRoot "schemas\work-unit-automation-receipt.schema.json"
    $unit047InspectJson = $unit047Inspect | ConvertTo-Json -Depth 100
    Assert-Automation (Test-Json -Json $unit047InspectJson -SchemaFile $automationReceiptSchema) "v2 advisory Inspect receipt failed its schema"
    $mislabeledV1Inspect = $unit047InspectJson | ConvertFrom-Json
    $mislabeledV1Inspect.claim_preflight.version = "v1"
    $mislabeledV1Accepted = Test-Json -Json ($mislabeledV1Inspect | ConvertTo-Json -Depth 100) -SchemaFile $automationReceiptSchema -ErrorAction SilentlyContinue
    Assert-Automation (-not $mislabeledV1Accepted) "v1 claim preflight accepted v2-only advisory fields"
    $legacyV1Inspect = $unit047InspectJson | ConvertFrom-Json
    $legacyV1Inspect.claim_preflight.version = "v1"
    foreach ($propertyName in @("advisory_status", "candidate_fingerprint", "state_mutation_performed", "reason_codes", "contract_bindings", "coverage", "guard_profile", "execution_preflight")) {
        $legacyV1Inspect.claim_preflight.PSObject.Properties.Remove($propertyName)
    }
    Assert-Automation (Test-Json -Json ($legacyV1Inspect | ConvertTo-Json -Depth 100) -SchemaFile $automationReceiptSchema) "legacy v1 claim preflight shape was not preserved"
    Assert-Automation (($positiveBefore -join "`n") -ceq ($positiveAfter -join "`n")) "Inspect advisory preflight mutated workflow bytes"

    # A fully declared all-green candidate has no reason token on any check.
    # Keep this synthetic so the regression covers strict-mode aggregation
    # without binding the test suite to a private product unit or live device.
    $allGreenUnitId = "unit-auto-all-green"
    $allGreenUnitPath = Join-Path $workspace "iteration-units\$allGreenUnitId.json"
    $allGreenUnit = $instructionUnit | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $allGreenUnit.unit_id = $allGreenUnitId
    $allGreenUnit.objective = "Exercise an all-green claim preflight whose check reason arrays are all empty."
    $allGreenUnit.device_requirement = "required"
    $allGreenUnit | Add-Member -NotePropertyName guard_profile -NotePropertyValue "fast"
    $allGreenUnit.claim_requirements | Add-Member -NotePropertyName execution_preflight -NotePropertyValue ([pscustomobject][ordered]@{
        observation = [pscustomobject][ordered]@{ repo_id = "project-shell"; path = "src/execution-preflight.json"; expected_sha256 = $executionObservationSha256 }
        assertions = @(
            [pscustomobject][ordered]@{ assertion_id = "package-match"; kind = "value-equals"; key = "android.package"; expected = "org.example.synthetic" },
            [pscustomobject][ordered]@{ assertion_id = "ndk-ready"; kind = "capability-present"; key = "ndk-available"; expected = $null }
        )
    })
    $allGreenUnit | Add-Member -NotePropertyName read_only_dependencies -NotePropertyValue @(
        [pscustomobject][ordered]@{ repo_id = "workflow-planning"; paths = @("planning-seed.txt"); purpose = "Exercise an available read-only input."; verification = "Inspect the exact synthetic seed file." }
    )
    $allGreenUnit | Add-Member -NotePropertyName resource_requirements -NotePropertyValue @(
        [pscustomobject][ordered]@{ resource_kind = "headset"; resource_id = "quest:test-device-a"; mode = "exclusive"; claim_timing = "before-run" }
    )
    Write-TestJson -Path $allGreenUnitPath -Value $allGreenUnit
    $allGreenPaths = @(
        $allGreenUnitPath,
        (Join-Path $workspace "workspace.state.json"),
        (Join-Path $workspace "iteration-events.jsonl")
    )
    $allGreenBefore = @($allGreenPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    $allGreenInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $workspace -UnitId $allGreenUnitId -RepoMapPath $repoMapPath -DeviceSerials @("test-device-a") -Timestamp $fixed
    $allGreenAfter = @($allGreenPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    Assert-Automation (
        $allGreenInspect.claim_preflight.advisory_status -eq "pass" -and
        $allGreenInspect.claim_preflight.state_mutation_performed -eq $false -and
        $allGreenInspect.claim_preflight.execution_preflight.status -eq "pass" -and
        @($allGreenInspect.claim_preflight.execution_preflight.assertions | Where-Object { -not $_.passed }).Count -eq 0 -and
        @($allGreenInspect.claim_preflight.reason_codes).Count -eq 0 -and
        @($allGreenInspect.claim_preflight.coverage.missing).Count -eq 0 -and
        @($allGreenInspect.claim_preflight.coverage.skipped).Count -eq 0 -and
        @($allGreenInspect.claim_preflight.coverage.checks | Where-Object { @($_.reason_codes).Count -ne 0 }).Count -eq 0 -and
        ($allGreenBefore -join "`n") -ceq ($allGreenAfter -join "`n")
    ) "all-green advisory preflight did not preserve empty reason arrays without mutation"

    $executionMismatchId = "unit-execution-mismatch"
    $executionMismatchPath = Join-Path $workspace "iteration-units\$executionMismatchId.json"
    $executionMismatchUnit = $allGreenUnit | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $executionMismatchUnit.unit_id = $executionMismatchId
    $executionMismatchUnit.objective = "Reject a stale or substituted execution-preflight observation before Claim."
    $executionMismatchUnit.claim_requirements.execution_preflight.observation.expected_sha256 = ('0' * 64)
    Write-TestJson -Path $executionMismatchPath -Value $executionMismatchUnit
    $executionMismatchInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $workspace -UnitId $executionMismatchId -RepoMapPath $repoMapPath -DeviceSerials @("test-device-a") -Timestamp $fixed
    Assert-Automation (-not $executionMismatchInspect.claim_preflight.ready_to_claim -and $executionMismatchInspect.claim_preflight.execution_preflight.status -eq "fail" -and @($executionMismatchInspect.claim_preflight.reason_codes) -contains "execution-preflight-mismatch") "execution preflight accepted a substituted observation"

    $unit045Workspace = New-TestWorkspace -Root (Join-Path $testRoot "unit045-shape") -ProjectId "unit045-shape" -UnitId "unit045-shape-001"
    $unit045Path = Join-Path $unit045Workspace "iteration-units\unit045-shape-001.json"
    $unit045 = Get-Content -LiteralPath $unit045Path -Raw | ConvertFrom-Json
    $unit045.validation[0].profile_id = "unknown-host-profile"
    Write-TestJson -Path $unit045Path -Value $unit045
    $unit045Inspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $unit045Workspace -UnitId "unit045-shape-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    Assert-Automation (
        $unit045Inspect.claim_preflight.advisory_status -eq "fail" -and
        @($unit045Inspect.claim_preflight.reason_codes) -contains "validation-profile-unknown" -and
        $unit045Inspect.claim_preflight.ready_to_claim
    ) "Unit045-shaped unknown validation profile was not advisory-failed without changing Claim behavior"

    $unit046Workspace = New-TestWorkspace -Root (Join-Path $testRoot "unit046-shape") -ProjectId "unit046-shape" -UnitId "unit046-shape-001"
    $unit046Path = Join-Path $unit046Workspace "iteration-units\unit046-shape-001.json"
    $unit046 = Get-Content -LiteralPath $unit046Path -Raw | ConvertFrom-Json
    $unit046 | Add-Member -NotePropertyName read_only_dependencies -NotePropertyValue @(
        [pscustomobject][ordered]@{ repo_id = "missing-manifold-input"; paths = @("crates/required/Cargo.toml"); purpose = "Exercise an unavailable read-only build edge."; verification = "Inspect the declared manifest." }
    )
    Write-TestJson -Path $unit046Path -Value $unit046
    $unit046Inspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $unit046Workspace -UnitId "unit046-shape-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    Assert-Automation (
        $unit046Inspect.claim_preflight.advisory_status -eq "incomplete" -and
        @($unit046Inspect.claim_preflight.reason_codes) -contains "read-only-dependency-unavailable" -and
        @($unit046Inspect.claim_preflight.coverage.missing) -contains "read-only-dependency-availability"
    ) "Unit046-shaped missing read-only dependency was not advisory-incomplete"

    $unit048Workspace = New-TestWorkspace -Root (Join-Path $testRoot "unit048-shape") -ProjectId "unit048-shape" -UnitId "unit048-shape-001"
    $unit048Path = Join-Path $unit048Workspace "iteration-units\unit048-shape-001.json"
    $unit048 = Get-Content -LiteralPath $unit048Path -Raw | ConvertFrom-Json
    $unit048.allowed_repositories += [pscustomobject][ordered]@{ repo_id = "duplicate-writer"; allowed_paths = @("docs/") }
    Write-TestJson -Path $unit048Path -Value $unit048
    $duplicateMapPath = Join-Path $testRoot "duplicate-writer-repo-map.json"
    Write-TestJson -Path $duplicateMapPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.repository_map.v1"; repositories = @(
        [ordered]@{ repo_id = "project-shell"; path = $repo; role = "source" },
        [ordered]@{ repo_id = "duplicate-writer"; path = $repo; role = "source" },
        [ordered]@{ repo_id = "workflow-planning"; path = $planningRepo; role = "planning" }
    ) })
    $unit048Inspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $unit048Workspace -UnitId "unit048-shape-001" -RepoMapPath $duplicateMapPath -Timestamp $fixed
    Assert-Automation (
        $unit048Inspect.claim_preflight.advisory_status -eq "fail" -and
        @($unit048Inspect.claim_preflight.reason_codes) -contains "writable-repository-map-alias"
    ) "Unit048-shaped duplicate writer map was not advisory-failed"

    $longPathWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "long-path-shape") -ProjectId "long-path-shape" -UnitId "long-path-shape-001"
    $longPathUnitPath = Join-Path $longPathWorkspace "iteration-units\long-path-shape-001.json"
    $longPathUnit = Get-Content -LiteralPath $longPathUnitPath -Raw | ConvertFrom-Json
    $longPathUnit.allowed_repositories[0].allowed_paths += ("generated/" + ("segment/" * 24) + "artifact.json")
    Write-TestJson -Path $longPathUnitPath -Value $longPathUnit
    $longPathInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $longPathWorkspace -UnitId "long-path-shape-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    Assert-Automation (
        $longPathInspect.claim_preflight.advisory_status -eq "incomplete" -and
        @($longPathInspect.claim_preflight.reason_codes) -contains "declared-path-capability-unproven"
    ) "long declared path was not advisory-incomplete"

    # Exercise the one behavior-neutral bridge from an already published
    # embedded workspace into a distinct local-only planning authority.
    $adoptionRemote = Join-Path $testRoot "adoption-source-remote.git"
    $adoptionSource = Join-Path $testRoot "adoption-source"
    $adoptionPlanning = Join-Path $testRoot "adoption-planning"
    & git init --bare $adoptionRemote | Out-Null
    & git init $adoptionSource | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("config", "user.name", "Automation Adoption Source") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("config", "user.email", "adoption-source@example.invalid") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("config", "core.autocrlf", "false") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $adoptionSource "README.md"), "stale source checkpoint`n", $encoding)
    Invoke-TestGit -Path $adoptionSource -Arguments @("add", "README.md") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("commit", "-m", "stale source checkpoint") | Out-Null
    $adoptionStaleRevision = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "HEAD"))[0])
    [System.IO.File]::WriteAllText((Join-Path $adoptionSource "README.md"), "pre-merge source checkpoint`n", $encoding)
    Invoke-TestGit -Path $adoptionSource -Arguments @("add", "README.md") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("commit", "-m", "pre-merge source checkpoint") | Out-Null
    $adoptionPreMergeRevision = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "HEAD"))[0])

    $adoptionSourceWorkspace = New-TestWorkspace -Root $adoptionSource -ProjectId "adoption-e2e" -UnitId "unit-adoption-001"
    $adoptionUnitPath = Join-Path $adoptionSourceWorkspace "iteration-units\unit-adoption-001.json"
    $adoptionUnit = Get-Content -LiteralPath $adoptionUnitPath -Raw | ConvertFrom-Json
    $adoptionUnit.status = "accepted"
    Write-TestJson -Path $adoptionUnitPath -Value $adoptionUnit
    $adoptionDirtyFingerprint = "c" * 64
    $adoptionStatePath = Join-Path $adoptionSourceWorkspace "workspace.state.json"
    $adoptionBeforeState = Get-Content -LiteralPath $adoptionStatePath -Raw | ConvertFrom-Json
    $adoptionBeforeState.current_unit = $null
    $adoptionBeforeState.next_ready_unit = $null
    $adoptionBeforeState.last_event_id = $null
    $adoptionBeforeState.pending_push_bundle = $null
    $adoptionBeforeState.dirty_repositories = @("other-repo", "project-shell")
    $adoptionBeforeState.repository_heads = @(
        [pscustomobject][ordered]@{
            repo_id = "other-repo"; head = ("9" * 40); branch = "main"; dirty_fingerprint = ("8" * 64)
        },
        [pscustomobject][ordered]@{
            repo_id = "project-shell"; head = $adoptionStaleRevision
            branch = "codex/stale-work"; dirty_fingerprint = $adoptionDirtyFingerprint
        }
    )
    $adoptionBeforeState.blockers = @([pscustomobject][ordered]@{
        blocker_id = "preserved-unrelated-blocker"
        condition = "Unrelated evidence remains immutable."
        resume_when = "A separate corrective unit is accepted."
    })
    Write-TestJson -Path $adoptionStatePath -Value $adoptionBeforeState
    [System.IO.File]::WriteAllText((Join-Path $adoptionSourceWorkspace "iteration-events.jsonl"), "", $encoding)
    Invoke-TestGit -Path $adoptionSource -Arguments @("add", "morphospace") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("commit", "-m", "publish embedded planning workspace") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("branch", "-M", "main") | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("remote", "add", "origin", $adoptionRemote) | Out-Null
    Invoke-TestGit -Path $adoptionSource -Arguments @("push", "-u", "origin", "main") | Out-Null
    $adoptionPublishedRevision = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "HEAD"))[0])
    $adoptionPublishedTree = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "HEAD^{tree}"))[0])
    $adoptionEmbeddedTree = [string](@(Invoke-TestGit -Path $adoptionSource -Arguments @("rev-parse", "${adoptionPublishedRevision}:morphospace"))[0])

    & git init $adoptionPlanning | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("config", "user.name", "Automation Adoption Planning") | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("config", "user.email", "adoption-planning@example.invalid") | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("config", "core.autocrlf", "false") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $adoptionPlanning "README.md"), "local-only planning authority`n", $encoding)
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("add", "README.md") | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("commit", "-m", "initialize local planning authority") | Out-Null
    Invoke-TestGit -Path $adoptionPlanning -Arguments @("branch", "-M", "main") | Out-Null
    $adoptionPlanningRevision = [string](@(Invoke-TestGit -Path $adoptionPlanning -Arguments @("rev-parse", "HEAD"))[0])
    $adoptionPlanningTree = [string](@(Invoke-TestGit -Path $adoptionPlanning -Arguments @("rev-parse", "HEAD^{tree}"))[0])
    $adoptionWorkspace = Join-Path $adoptionPlanning "projects\adoption-e2e\morphospace"
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $adoptionSourceWorkspace -File -Recurse)) {
        $relative = $sourceFile.FullName.Substring($adoptionSourceWorkspace.Length + 1)
        $destination = Join-Path $adoptionWorkspace $relative
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [System.IO.File]::Copy($sourceFile.FullName, $destination, $true)
    }
    $adoptionReceiptRoot = Join-Path $adoptionWorkspace "receipts"
    [System.IO.Directory]::CreateDirectory($adoptionReceiptRoot) | Out-Null
    $adoptionInventory = @(Get-GitWorkspaceInventory $adoptionSource $adoptionPublishedRevision "morphospace" | ForEach-Object {
        [ordered]@{
            path = [string]$_.path; git_mode = [string]$_.git_mode
            size = [int64]$_.size; sha256 = [string]$_.sha256
        }
    })
    $adoptionProjectionPath = Join-Path $adoptionReceiptRoot "adoption-projection-v2.json"
    $adoptionProjection = [ordered]@{
        schema = "rusty.morphospace.workflow.planning_workspace_projection.v2"
        projection_id = "adoption-projection-v2"; project_id = "adoption-e2e"; unit_id = "unit-adoption-001"
        recorded_at = $fixed; status = "exact-projection-verified"
        chronology = [ordered]@{
            classification = "published-embedded-workspace-authority-adoption"
            source_publication_preceded_projection = $true; prepared_plan_present = $false
            executed_push_receipt_present = $false
            does_not_claim = @("prospective preparation", "planning-last publication", "source acceptance", "Git execution")
        }
        source = [ordered]@{
            repo_id = "project-shell"; branch = "main"; remote = "origin"
            remote_ref = "refs/heads/main"; upstream = "origin/main"
            old_revision = $adoptionPreMergeRevision; published_revision = $adoptionPublishedRevision
            observed_remote_revision = $adoptionPublishedRevision
            embedded_workspace_path = "morphospace"; embedded_workspace_tree = $adoptionEmbeddedTree
            fast_forward_verified = $true; remote_match = $true; force_push_used = $false
        }
        planning = [ordered]@{
            repo_id = "workflow-planning"; workspace_path = "projects/adoption-e2e/morphospace"
            projection_record_path = "receipts/adoption-projection-v2.json"
            distinct_from_source = $true; base_revision = $adoptionPlanningRevision
        }
        inventory = $adoptionInventory
        projected_state = [ordered]@{
            current_unit = $null; next_ready_unit = $null; pending_push_bundle = $null
            dirty_repository_ids = @("other-repo", "project-shell")
            source_repository = [ordered]@{
                repo_id = "project-shell"; head = $adoptionStaleRevision
                branch = "codex/stale-work"; dirty_fingerprint = $adoptionDirtyFingerprint
            }
        }
        authority = [ordered]@{
            source_workspace = "immutable-historical-snapshot"
            external_workspace = "sole-mutable-workflow-authority"
            source_workflow_mutation_performed = $false; git_mutation_performed = $false
            next_transition = "AdoptPublishedPlanningAuthority"
        }
        failure = $null
    }
    Write-TestJson -Path $adoptionProjectionPath -Value $adoptionProjection
    $adoptionBeforePath = Join-Path $adoptionReceiptRoot "adoption-state-before.json"
    [System.IO.File]::Copy((Join-Path $adoptionWorkspace "workspace.state.json"), $adoptionBeforePath, $true)
    $adoptionExpectedEventId = "unit-adoption-001-planning-authority-adopted-0001"
    $adoptionAfterState = $adoptionBeforeState | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $adoptionAfterState.dirty_repositories = @("other-repo")
    $adoptionAfterState.last_event_id = $adoptionExpectedEventId
    $adoptionAfterSource = @($adoptionAfterState.repository_heads | Where-Object { [string]$_.repo_id -ceq "project-shell" })[0]
    $adoptionAfterSource.head = $adoptionPublishedRevision
    $adoptionAfterSource.branch = "main"
    $adoptionAfterSource.dirty_fingerprint = $null
    $adoptionAfterPath = Join-Path $adoptionReceiptRoot "adoption-state-after.json"
    Write-TestJson -Path $adoptionAfterPath -Value $adoptionAfterState
    $adoptionValidationPath = Join-Path $adoptionReceiptRoot "adoption-validation.json"
    $adoptionObserverPath = Join-Path $adoptionReceiptRoot "adoption-observer.json"
    Write-TestJson -Path $adoptionValidationPath -Value ([ordered]@{
        schema = "test.validation.v1"; status = "pass"; revision = $adoptionPublishedRevision
    })
    Write-TestJson -Path $adoptionObserverPath -Value ([ordered]@{
        schema = "test.observer.v1"; observed_revision = $adoptionPublishedRevision
    })
    $adoptionBeforeBinding = [ordered]@{
        path = "receipts/adoption-state-before.json"
        sha256 = (Get-FileHash -LiteralPath $adoptionBeforePath -Algorithm SHA256).Hash.ToLowerInvariant()
        current_unit = $null; next_ready_unit = $null; pending_push_bundle = $null
        dirty_repository_ids = @("other-repo", "project-shell")
        source_repository = $adoptionProjection.projected_state.source_repository
    }
    $adoptionAfterBinding = [ordered]@{
        path = "receipts/adoption-state-after.json"
        sha256 = (Get-FileHash -LiteralPath $adoptionAfterPath -Algorithm SHA256).Hash.ToLowerInvariant()
        current_unit = $null; next_ready_unit = $null; pending_push_bundle = $null
        dirty_repository_ids = @("other-repo")
        source_repository = [ordered]@{
            repo_id = "project-shell"; head = $adoptionPublishedRevision
            branch = "main"; dirty_fingerprint = $null
        }
    }
    $adoptionDocument = [ordered]@{
        schema = "rusty.morphospace.workflow.published_planning_authority_adoption.v1"
        adoption_id = "adoption-e2e-published-planning-authority"
        project_id = "adoption-e2e"; recorded_at = $fixed
        status = "published-planning-authority-adopted"
        planning_workspace_projection = [ordered]@{
            path = "receipts/adoption-projection-v2.json"; projection_id = "adoption-projection-v2"
            sha256 = (Get-FileHash -LiteralPath $adoptionProjectionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        workspace_state_before = $adoptionBeforeBinding
        workspace_state_after = $adoptionAfterBinding
        source_publication = [ordered]@{
            repo_id = "project-shell"; branch = "main"; remote = "origin"
            remote_ref = "refs/heads/main"; upstream = "origin/main"
            pre_merge_revision = $adoptionPreMergeRevision; published_revision = $adoptionPublishedRevision
            readback_revision = $adoptionPublishedRevision; published_tree = $adoptionPublishedTree
            worktree_clean = $true; synchronized = $true; fast_forward_verified = $true
            remote_match = $true; force_push_used = $false; history_rewrite_used = $false
        }
        planning_repository = [ordered]@{
            repo_id = "workflow-planning"; branch = "main"
            head_revision = $adoptionPlanningRevision; head_tree = $adoptionPlanningTree
            workspace_path = "projects/adoption-e2e/morphospace"; distinct_from_source = $true
            remote_configured = $false; unrelated_worktree_clean = $true
        }
        validation = @([ordered]@{
            gate_id = "published-source-readback"; status = "pass"
            evidence = [ordered]@{
                path = "receipts/adoption-validation.json"
                sha256 = (Get-FileHash -LiteralPath $adoptionValidationPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        observers = @([ordered]@{
            observer_id = "external-coordinator"; recorded_at = $fixed
            evidence = [ordered]@{
                path = "receipts/adoption-observer.json"
                sha256 = (Get-FileHash -LiteralPath $adoptionObserverPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        state_delta = [ordered]@{
            cleared_dirty_repository_id = "project-shell"
            dirty_repository_ids_before = @("other-repo", "project-shell")
            dirty_repository_ids_after = @("other-repo")
            repository_before = $adoptionBeforeBinding.source_repository
            repository_after = $adoptionAfterBinding.source_repository
            last_event_id_before = $null; last_event_id_after = $adoptionExpectedEventId
            preserved_fields = @(
                "blockers", "capability_registry", "current_unit", "last_accepted_receipt",
                "module_registry", "next_ready_unit", "pending_push_bundle", "plan_revision",
                "project_id", "repository_checkpoints", "unrelated_repository_heads",
                "validation_checkpoint"
            )
        }
        nonclaims = [ordered]@{
            external_planning_authority_existed_at_publication = $false
            prepared_plan_or_executed_push_reconstructed = $false
            source_acceptance_created = $false; git_or_remote_mutation_performed = $false
            force_push_or_history_rewrite_used = $false
            unrelated_dirty_repositories_cleared = $false
        }
        failure = $null
    }
    $adoptionDocumentPath = Join-Path $adoptionReceiptRoot "adoption.json"
    Write-TestJson -Path $adoptionDocumentPath -Value $adoptionDocument
    $adoptionRepoMapPath = Join-Path $testRoot "adoption-repo-map.json"
    Write-TestJson -Path $adoptionRepoMapPath -Value ([ordered]@{
        schema = "rusty.morphospace.workflow.repository_map.v1"
        repositories = @(
            [ordered]@{ repo_id = "project-shell"; path = $adoptionSource; role = "source" },
            [ordered]@{ repo_id = "workflow-planning"; path = $adoptionPlanning; role = "planning" }
        )
    })

    $adoptionLiveStatePath = Join-Path $adoptionWorkspace "workspace.state.json"
    $adoptionLiveUnitPath = Join-Path $adoptionWorkspace "iteration-units\unit-adoption-001.json"
    $adoptionEventsPath = Join-Path $adoptionWorkspace "iteration-events.jsonl"
    $adoptionStateBeforeDryRun = Get-Content -LiteralPath $adoptionLiveStatePath -Raw
    $adoptionUnitBeforeDryRun = Get-Content -LiteralPath $adoptionLiveUnitPath -Raw
    $adoptionEventsBeforeDryRun = Get-Content -LiteralPath $adoptionEventsPath -Raw
    $adoptionDryRun = Invoke-MorphospaceWorkUnitAutomation `
        -Action AdoptPublishedPlanningAuthority `
        -WorkspaceRoot $adoptionWorkspace `
        -UnitId "unit-adoption-001" `
        -RepoMapPath $adoptionRepoMapPath `
        -PublishedPlanningAuthorityAdoption "receipts/adoption.json" `
        -Timestamp $fixed
    $adoptionExpectedHash = (Get-FileHash -LiteralPath $adoptionDocumentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Automation (
        $adoptionDryRun.transition -eq "published-planning-authority-adopted" -and
        -not $adoptionDryRun.executed -and $null -eq $adoptionDryRun.event_id -and
        $adoptionDryRun.status_before -eq "accepted" -and $adoptionDryRun.status_after -eq "accepted" -and
        [string]$adoptionDryRun.published_planning_authority_adoption.adoption_id -eq "adoption-e2e-published-planning-authority" -and
        [string]$adoptionDryRun.published_planning_authority_adoption.path -eq "receipts/adoption.json" -and
        [string]$adoptionDryRun.published_planning_authority_adoption.sha256 -eq $adoptionExpectedHash
    ) "planning-authority adoption dry run did not return the exact binding"
    Assert-Automation (
        $adoptionStateBeforeDryRun -ceq (Get-Content -LiteralPath $adoptionLiveStatePath -Raw) -and
        $adoptionUnitBeforeDryRun -ceq (Get-Content -LiteralPath $adoptionLiveUnitPath -Raw) -and
        $adoptionEventsBeforeDryRun -ceq (Get-Content -LiteralPath $adoptionEventsPath -Raw)
    ) "planning-authority adoption dry run mutated workspace projections"

    $adoptionAutomationReceiptPath = Join-Path $adoptionReceiptRoot "adoption-automation-receipt.json"
    $adoptionExecuted = Invoke-MorphospaceWorkUnitAutomation `
        -Action AdoptPublishedPlanningAuthority `
        -WorkspaceRoot $adoptionWorkspace `
        -UnitId "unit-adoption-001" `
        -RepoMapPath $adoptionRepoMapPath `
        -PublishedPlanningAuthorityAdoption "receipts/adoption.json" `
        -Timestamp $fixed `
        -OutPath $adoptionAutomationReceiptPath `
        -Execute
    Assert-Automation (
        $adoptionExecuted.transition -eq "published-planning-authority-adopted" -and
        $adoptionExecuted.executed -and $adoptionExecuted.event_id -eq $adoptionExpectedEventId -and
        $adoptionExecuted.status_before -eq "accepted" -and $adoptionExecuted.status_after -eq "accepted" -and
        [string]$adoptionExecuted.published_planning_authority_adoption.sha256 -eq $adoptionExpectedHash -and
        (Test-Path -LiteralPath $adoptionAutomationReceiptPath -PathType Leaf)
    ) "planning-authority adoption execution did not return the exact transition"
    $adoptionActualState = Get-Content -LiteralPath $adoptionLiveStatePath -Raw | ConvertFrom-Json
    $adoptionExpectedState = Get-Content -LiteralPath $adoptionAfterPath -Raw | ConvertFrom-Json
    Assert-Automation (
        (ConvertTo-MorphospaceCanonicalJson $adoptionActualState) -ceq
            (ConvertTo-MorphospaceCanonicalJson $adoptionExpectedState)
    ) "planning-authority adoption did not write the exact bound after state"
    Assert-Automation (
        $adoptionUnitBeforeDryRun -ceq (Get-Content -LiteralPath $adoptionLiveUnitPath -Raw)
    ) "planning-authority adoption rewrote the accepted unit"
    $adoptionEvents = @(Get-Content -LiteralPath $adoptionEventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Automation (
        $adoptionEvents.Count -eq 1 -and
        [string]$adoptionEvents[0].event_id -eq $adoptionExpectedEventId -and
        [string]$adoptionEvents[0].event_type -eq "state-transition" -and
        @($adoptionEvents[0].receipts).Count -eq 1 -and
        [string]$adoptionEvents[0].receipts[0] -eq "receipts/adoption.json"
    ) "planning-authority adoption did not append exactly one bound receipt event"
    $adoptionTransactionId = "$adoptionExpectedEventId-transition"
    $adoptionTransactionRoot = Join-Path $adoptionReceiptRoot "transactions"
    $adoptionIntentPath = Join-Path $adoptionTransactionRoot "$adoptionTransactionId.intent.json"
    $adoptionCompletionPath = Join-Path $adoptionTransactionRoot "$adoptionTransactionId.completion.json"
    $adoptionIntent = Get-Content -LiteralPath $adoptionIntentPath -Raw | ConvertFrom-Json
    $adoptionCompletion = Get-Content -LiteralPath $adoptionCompletionPath -Raw | ConvertFrom-Json
    Assert-Automation (
        @(Get-ChildItem -LiteralPath $adoptionTransactionRoot -File).Count -eq 2 -and
        [string]$adoptionIntent.schema -eq "rusty.morphospace.workflow.transition_ledger_intent.v1" -and
        [string]$adoptionIntent.transaction_id -eq $adoptionTransactionId -and
        [string]$adoptionIntent.status -eq "prepared" -and
        [string]$adoptionIntent.event.event_id -eq $adoptionExpectedEventId -and
        [string]$adoptionCompletion.schema -eq "rusty.morphospace.workflow.transition_ledger_completion.v1" -and
        [string]$adoptionCompletion.transaction_id -eq $adoptionTransactionId -and
        [string]$adoptionCompletion.status -eq "committed" -and
        [string]$adoptionCompletion.event_id -eq $adoptionExpectedEventId
    ) "planning-authority adoption transaction intent/completion artifacts are incomplete"
    $adoptionReplayRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation `
            -Action AdoptPublishedPlanningAuthority `
            -WorkspaceRoot $adoptionWorkspace `
            -UnitId "unit-adoption-001" `
            -RepoMapPath $adoptionRepoMapPath `
            -PublishedPlanningAuthorityAdoption "receipts/adoption.json" `
            -Timestamp $fixed `
            -Execute | Out-Null
    } catch {
        $adoptionReplayRejected = $true
    }
    Assert-Automation (
        $adoptionReplayRejected -and
        @(Get-Content -LiteralPath $adoptionEventsPath | Where-Object { $_ }).Count -eq 1 -and
        @(Get-ChildItem -LiteralPath $adoptionTransactionRoot -File).Count -eq 2
    ) "planning-authority adoption replay was not rejected without a second event or transaction"

    $readyWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "ready-project") -ProjectId "ready-test" -UnitId "unit-ready-001"
    $readyUnitPath = Join-Path $readyWorkspace "iteration-units\unit-ready-001.json"
    $readyUnit = Get-Content -LiteralPath $readyUnitPath -Raw | ConvertFrom-Json
    $readyUnit.status = "proposed"
    Write-TestJson -Path $readyUnitPath -Value $readyUnit
    $readyStatePath = Join-Path $readyWorkspace "workspace.state.json"
    $readyState = Get-Content -LiteralPath $readyStatePath -Raw | ConvertFrom-Json
    $readyState.next_ready_unit = $null
    Write-TestJson -Path $readyStatePath -Value $readyState
    $readyResult = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $readyWorkspace -UnitId "unit-ready-001" -Timestamp $fixed -Execute
    Assert-Automation ($readyResult.transition -eq "proposed-to-ready" -and $readyResult.status_after -eq "ready") "proposal review transition"
    $readyState = Get-Content -LiteralPath $readyStatePath -Raw | ConvertFrom-Json
    Assert-Automation ([string]$readyState.next_ready_unit -eq "unit-ready-001") "proposal review did not derive next-ready state"
    $readyEventCount = @(Get-Content (Join-Path $readyWorkspace "iteration-events.jsonl")).Count
    $readyAgain = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $readyWorkspace -UnitId "unit-ready-001" -Timestamp $fixed -Execute
    Assert-Automation ($readyAgain.transition -eq "idempotent") "idempotent proposal review"
    Assert-Automation (@(Get-Content (Join-Path $readyWorkspace "iteration-events.jsonl")).Count -eq $readyEventCount) "idempotent proposal review appended an event"

    $blockedReadyWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "blocked-ready-project") -ProjectId "blocked-ready-test" -UnitId "unit-blocked-ready-001"
    $blockedReadyPath = Join-Path $blockedReadyWorkspace "iteration-units\unit-blocked-ready-001.json"
    $blockedReadyUnit = Get-Content -LiteralPath $blockedReadyPath -Raw | ConvertFrom-Json
    $blockedReadyUnit.status = "proposed"
    $blockedReadyUnit.prerequisites = @("missing-prerequisite")
    Write-TestJson -Path $blockedReadyPath -Value $blockedReadyUnit
    $blockedReadyRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $blockedReadyWorkspace -UnitId "unit-blocked-ready-001" -Timestamp $fixed -Execute | Out-Null
    } catch { $blockedReadyRejected = $true }
    Assert-Automation $blockedReadyRejected "proposal review accepted an unmet prerequisite"

    # Ready must prove that the canonical v2 supersession identity remains
    # representable before publishing any ready-state bytes.
    foreach ($boundary in @(
        [pscustomobject]@{ name = 'exact-128'; candidate = ('b' * 111); should_pass = $true },
        [pscustomobject]@{ name = 'overlong-129'; candidate = ('b' * 112); should_pass = $false }
    )) {
        $boundaryWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "ready-boundary-$($boundary.name)") -ProjectId "ready-boundary-$($boundary.name)" -UnitId 'aa'
        $boundaryCurrentPath = Join-Path $boundaryWorkspace 'iteration-units\aa.json'
        $boundaryCurrent = Get-Content -LiteralPath $boundaryCurrentPath -Raw | ConvertFrom-Json
        $boundaryCurrent.status = 'active'
        Write-TestJson -Path $boundaryCurrentPath -Value $boundaryCurrent
        $boundaryStatePath = Join-Path $boundaryWorkspace 'workspace.state.json'
        $boundaryState = Get-Content -LiteralPath $boundaryStatePath -Raw | ConvertFrom-Json
        $boundaryState.current_unit = 'aa'
        $boundaryState.next_ready_unit = $null
        Write-TestJson -Path $boundaryStatePath -Value $boundaryState
        $boundaryCandidatePath = Join-Path $boundaryWorkspace "iteration-units\$([string]$boundary.candidate).json"
        $boundaryCandidate = New-TestUnit -ProjectId "ready-boundary-$($boundary.name)" -UnitId ([string]$boundary.candidate)
        $boundaryCandidate.status = 'proposed'
        Write-TestJson -Path $boundaryCandidatePath -Value $boundaryCandidate
        $beforeBoundaryState = Get-Content -LiteralPath $boundaryStatePath -Raw
        $beforeBoundaryUnit = Get-Content -LiteralPath $boundaryCandidatePath -Raw
        $beforeBoundaryEvents = Get-Content -LiteralPath (Join-Path $boundaryWorkspace 'iteration-events.jsonl') -Raw
        $boundaryRejected = $false
        try {
            $boundaryResult = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $boundaryWorkspace -UnitId ([string]$boundary.candidate) -Timestamp $fixed -Execute
        } catch {
            $boundaryRejected = $_.Exception.Message -like 'Ready supersession-composability preflight failed:*128-character event-ID contract*'
        }
        if ($boundary.should_pass) {
            Assert-Automation (-not $boundaryRejected -and $boundaryResult.status_after -eq 'ready') 'Ready rejected the exact 128-character supersession identity'
        } else {
            Assert-Automation (
                $boundaryRejected -and
                $beforeBoundaryState -ceq (Get-Content -LiteralPath $boundaryStatePath -Raw) -and
                $beforeBoundaryUnit -ceq (Get-Content -LiteralPath $boundaryCandidatePath -Raw) -and
                $beforeBoundaryEvents -ceq (Get-Content -LiteralPath (Join-Path $boundaryWorkspace 'iteration-events.jsonl') -Raw) -and
                @(Get-ChildItem -LiteralPath (Join-Path $boundaryWorkspace 'receipts\transactions') -File -ErrorAction SilentlyContinue).Count -eq 0
            ) 'Ready overlong supersession preflight mutated workflow bytes or failed with the wrong boundary'
            $boundaryCandidate.status = 'ready'
            Write-TestJson -Path $boundaryCandidatePath -Value $boundaryCandidate
            $boundaryState.next_ready_unit = [string]$boundary.candidate
            Write-TestJson -Path $boundaryStatePath -Value $boundaryState
            $idempotentOverlong = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $boundaryWorkspace -UnitId ([string]$boundary.candidate) -Timestamp $fixed -Execute
            Assert-Automation ($idempotentOverlong.transition -eq 'idempotent') 'Ready changed already-ready idempotence at the overlong supersession boundary'
        }
    }

    $withdrawFixture = New-TestReadyWithdrawalWorkspace -Root (Join-Path $testRoot 'withdraw-ready-positive') -ProjectId 'withdraw-ready-positive' -IncludeSecondReady
    $withdrawWorkspace = $withdrawFixture.workspace
    $withdrawStatePath = Join-Path $withdrawWorkspace 'workspace.state.json'
    $withdrawUnitPath = Join-Path $withdrawWorkspace "iteration-units\$($withdrawFixture.withdraw_id).json"
    $withdrawEventsPath = Join-Path $withdrawWorkspace 'iteration-events.jsonl'
    $withdrawStateBefore = Get-Content -LiteralPath $withdrawStatePath -Raw | ConvertFrom-Json
    $withdrawUnitBefore = Get-Content -LiteralPath $withdrawUnitPath -Raw | ConvertFrom-Json
    $withdrawEventLinesBefore = @(Get-Content -LiteralPath $withdrawEventsPath)
    $withdrawReceiptPath = Join-Path $withdrawWorkspace 'receipts\withdraw-ready.json'
    $withdrawDry = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') `
        -Action WithdrawReady -WorkspaceRoot $withdrawWorkspace -UnitId $withdrawFixture.withdraw_id `
        -Timestamp $fixed -OutPath $withdrawReceiptPath | ConvertFrom-Json
    Assert-Automation (
        -not $withdrawDry.executed -and
        $withdrawDry.transition -eq 'ready-to-proposed-withdrawn' -and
        [string]$withdrawDry.ready_withdrawal.next_ready_unit_before -eq $withdrawFixture.withdraw_id -and
        [string]$withdrawDry.ready_withdrawal.next_ready_unit_after -eq $withdrawFixture.remaining_id -and
        -not (Test-Path -LiteralPath $withdrawReceiptPath)
    ) 'WithdrawReady public dry run did not authenticate and derive the ready queue without mutation'
    $withdrawResult = Invoke-MorphospaceWorkUnitAutomation `
        -Action WithdrawReady -WorkspaceRoot $withdrawWorkspace -UnitId $withdrawFixture.withdraw_id `
        -Timestamp $fixed -OutPath $withdrawReceiptPath -Execute
    $withdrawStateAfter = Get-Content -LiteralPath $withdrawStatePath -Raw | ConvertFrom-Json
    $withdrawUnitAfter = Get-Content -LiteralPath $withdrawUnitPath -Raw | ConvertFrom-Json
    $withdrawEventLinesAfter = @(Get-Content -LiteralPath $withdrawEventsPath)
    Assert-Automation (
        $withdrawResult.executed -and
        $withdrawResult.transition -eq 'ready-to-proposed-withdrawn' -and
        $withdrawResult.status_before -eq 'ready' -and $withdrawResult.status_after -eq 'proposed' -and
        [string]$withdrawStateAfter.current_unit -eq $withdrawFixture.current_id -and
        [string]$withdrawStateAfter.next_ready_unit -eq $withdrawFixture.remaining_id -and
        [string]$withdrawUnitAfter.status -eq 'proposed' -and
        $withdrawResult.ready_withdrawal.original_ready_event_preserved -and
        $withdrawEventLinesAfter.Count -eq ($withdrawEventLinesBefore.Count + 1) -and
        ($withdrawEventLinesAfter[0..($withdrawEventLinesBefore.Count - 1)] -join "`n") -ceq ($withdrawEventLinesBefore -join "`n") -and
        (Test-Path -LiteralPath $withdrawReceiptPath -PathType Leaf)
    ) 'WithdrawReady did not produce the exact state/unit/ledger projection'
    Assert-Automation (
        (Get-TestNullableCanonicalHash $withdrawStateBefore.blockers) -ceq (Get-TestNullableCanonicalHash $withdrawStateAfter.blockers) -and
        (Get-TestNullableCanonicalHash $withdrawStateBefore.validation_checkpoint) -ceq (Get-TestNullableCanonicalHash $withdrawStateAfter.validation_checkpoint) -and
        (Get-TestNullableCanonicalHash $withdrawStateBefore.repository_heads) -ceq (Get-TestNullableCanonicalHash $withdrawStateAfter.repository_heads) -and
        [string]$withdrawUnitBefore.objective -ceq [string]$withdrawUnitAfter.objective -and
        (Get-TestCanonicalHash $withdrawUnitBefore.allowed_repositories) -ceq (Get-TestCanonicalHash $withdrawUnitAfter.allowed_repositories)
    ) 'WithdrawReady changed unrelated state or unit fields'
    Assert-Automation (
        (Test-Json -Json (Get-Content -LiteralPath $withdrawReceiptPath -Raw) -SchemaFile (Join-Path $RepoRoot 'schemas\work-unit-automation-receipt.schema.json'))
    ) 'WithdrawReady receipt does not satisfy the strict action receipt schema'
    $remainingReceiptPath = Join-Path $withdrawWorkspace 'receipts\withdraw-ready-remaining.json'
    $remainingWithdrawal = Invoke-MorphospaceWorkUnitAutomation `
        -Action WithdrawReady -WorkspaceRoot $withdrawWorkspace -UnitId $withdrawFixture.remaining_id `
        -Timestamp $fixed -OutPath $remainingReceiptPath -Execute
    $stateAfterRemainingWithdrawal = Get-Content -LiteralPath $withdrawStatePath -Raw | ConvertFrom-Json
    Assert-Automation (
        $remainingWithdrawal.status_after -eq 'proposed' -and
        $null -eq $stateAfterRemainingWithdrawal.next_ready_unit -and
        [string]$remainingWithdrawal.ready_withdrawal.original_ready_transaction.target_state_sha256 -match '^[0-9a-f]{64}$'
    ) 'WithdrawReady rejected a later queued unit after deterministic promotion to next-ready'
    $withdrawReplayRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action WithdrawReady -WorkspaceRoot $withdrawWorkspace -UnitId $withdrawFixture.withdraw_id -Timestamp $fixed -OutPath (Join-Path $withdrawWorkspace 'receipts\withdraw-ready-replay.json') -Execute | Out-Null
    } catch { $withdrawReplayRejected = $_.Exception.Message -like 'WithdrawReady requires*' }
    Assert-Automation $withdrawReplayRejected 'WithdrawReady replay was not rejected after the committed withdrawal'
    $withdrawIdentityReuseRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $withdrawWorkspace -UnitId $withdrawFixture.withdraw_id -Timestamp $fixed -Execute | Out-Null
    } catch { $withdrawIdentityReuseRejected = $_.Exception.Message -like "Ready refuses withdrawn unit identity*" }
    Assert-Automation $withdrawIdentityReuseRejected 'WithdrawReady allowed the withdrawn identity to be readied again'
    $replacementIdentity = 'unit-next-c-001'
    $replacementUnit = New-TestUnit -ProjectId $withdrawFixture.project_id -UnitId $replacementIdentity
    $replacementUnit.status = 'proposed'
    Write-TestJson -Path (Join-Path $withdrawWorkspace "iteration-units\$replacementIdentity.json") -Value $replacementUnit
    $replacementReady = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $withdrawWorkspace -UnitId $replacementIdentity -Timestamp $fixed -Execute
    Assert-Automation ($replacementReady.status_after -eq 'ready') 'WithdrawReady prevented a revised proposal under a fresh unit identity'

    $withdrawDamageBase = New-TestReadyWithdrawalWorkspace -Root (Join-Path $testRoot 'withdraw-ready-damage-base') -ProjectId 'withdraw-ready-damage-base'
    $withdrawDamageCases = @(
        [pscustomobject]@{ name = 'wrong-next'; mutate = {
            param($w,$f)
            $path = Join-Path $w 'workspace.state.json'; $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json; $doc.next_ready_unit = $null; Write-TestJson $path $doc
        }; expected = '*exact next-ready unit*' },
        [pscustomobject]@{ name = 'wrong-status'; mutate = {
            param($w,$f)
            $path = Join-Path $w "iteration-units\$($f.withdraw_id).json"; $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json; $doc.status = 'proposed'; Write-TestJson $path $doc
        }; expected = '*requires ready status*' },
        [pscustomobject]@{ name = 'current-target'; mutate = {
            param($w,$f)
            $path = Join-Path $w 'workspace.state.json'; $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json; $doc.current_unit = $f.withdraw_id; Write-TestJson $path $doc
        }; expected = '*may not target the current unit*' },
        [pscustomobject]@{ name = 'missing-ready-event'; mutate = {
            param($w,$f)
            [IO.File]::WriteAllText((Join-Path $w 'iteration-events.jsonl'), '', [Text.UTF8Encoding]::new($false))
        }; expected = '*exactly one owner-generated Ready event*' },
        [pscustomobject]@{ name = 'ready-event-project-drift'; mutate = {
            param($w,$f)
            $path = Join-Path $w 'iteration-events.jsonl'; $text = [IO.File]::ReadAllText($path).Replace('"project_id":"withdraw-ready-damage-base"', '"project_id":"wrong-project"'); [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        }; expected = '*exactly one owner-generated Ready event*' },
        [pscustomobject]@{ name = 'ready-event-unit-drift'; mutate = {
            param($w,$f)
            $path = Join-Path $w 'iteration-events.jsonl'; $old = '"unit_id":"{0}"' -f $f.withdraw_id; $text = [IO.File]::ReadAllText($path).Replace($old, '"unit_id":"wrong-unit"'); [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        }; expected = '*exactly one owner-generated Ready event*' },
        [pscustomobject]@{ name = 'ready-event-id-drift'; mutate = {
            param($w,$f)
            $path = Join-Path $w 'iteration-events.jsonl'; $old = '"event_id":"{0}-ready-0001"' -f $f.withdraw_id; $new = '"event_id":"{0}-other-0001"' -f $f.withdraw_id; $text = [IO.File]::ReadAllText($path).Replace($old, $new); [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        }; expected = '*exactly one owner-generated Ready event*' },
        [pscustomobject]@{ name = 'ready-event-sequence-drift'; mutate = {
            param($w,$f)
            $path = Join-Path $w 'iteration-events.jsonl'; $text = [IO.File]::ReadAllText($path).Replace('"sequence":1', '"sequence":2'); [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        }; expected = '*sequence is not contiguous*' },
        [pscustomobject]@{ name = 'ready-event-hash-drift'; mutate = {
            param($w,$f)
            $path = Join-Path $w 'iteration-events.jsonl'; $text = [IO.File]::ReadAllText($path).Replace('Reviewed the bounded proposal', 'Altered the bounded proposal'); [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        }; expected = '*exactly one owner-generated Ready event*' },
        [pscustomobject]@{ name = 'missing-ready-intent'; mutate = {
            param($w,$f)
            $event = Get-Content -LiteralPath (Join-Path $w 'iteration-events.jsonl') | Select-Object -First 1 | ConvertFrom-Json
            Remove-Item -LiteralPath (Join-Path $w "receipts\transactions\$([string]$event.event_id)-transition.intent.json") -Force
        }; expected = '*missing*' },
        [pscustomobject]@{ name = 'damaged-ready-completion'; mutate = {
            param($w,$f)
            $event = Get-Content -LiteralPath (Join-Path $w 'iteration-events.jsonl') | Select-Object -First 1 | ConvertFrom-Json
            $path = Join-Path $w "receipts\transactions\$([string]$event.event_id)-transition.completion.json"
            $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json; $doc.intent.sha256 = '0' * 64; Write-TestJson $path $doc
        }; expected = '*completion is not canonically bound*' },
        [pscustomobject]@{ name = 'target-unit-drift'; mutate = {
            param($w,$f)
            $path = Join-Path $w "iteration-units\$($f.withdraw_id).json"; $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json; $doc.objective = 'Unauthorized live target drift.'; Write-TestJson $path $doc
        }; expected = '*target unit projection*' },
        [pscustomobject]@{ name = 'ledger-prefix-drift'; mutate = {
            param($w,$f)
            $path = Join-Path $w 'iteration-events.jsonl'; $bytes = [IO.File]::ReadAllBytes($path); [IO.File]::WriteAllBytes($path, @([byte]0x20) + $bytes)
        }; expected = '*exact canonical event append*' },
        [pscustomobject]@{ name = 'duplicate-receipt-target'; mutate = {
            param($w,$f)
            $path = Join-Path $w 'receipts\withdraw-ready.json'; [IO.File]::WriteAllText($path, "occupied`n", [Text.UTF8Encoding]::new($false))
        }; expected = '*artifact target must be absent*' },
        [pscustomobject]@{ name = 'contradictory-ready-order'; mutate = {
            param($w,$f)
            $candidate = New-TestUnit -ProjectId $f.project_id -UnitId 'aaa-ready-001'; $candidate.status = 'ready'; Write-TestJson (Join-Path $w 'iteration-units\aaa-ready-001.json') $candidate
        }; expected = '*contradictory or non-derivable next-ready projection*' }
    )
    foreach ($damage in $withdrawDamageCases) {
        $damageWorkspace = Copy-TestWorkspace -Source $withdrawDamageBase.workspace -Destination (Join-Path $testRoot "withdraw-ready-damage-$($damage.name)")
        & $damage.mutate $damageWorkspace $withdrawDamageBase
        $damageRejected = $false
        $damageMessage = ''
        try {
            Invoke-MorphospaceWorkUnitAutomation -Action WithdrawReady -WorkspaceRoot $damageWorkspace -UnitId $withdrawDamageBase.withdraw_id -Timestamp $fixed -OutPath (Join-Path $damageWorkspace 'receipts\withdraw-ready.json') -Execute | Out-Null
        } catch { $damageMessage = $_.Exception.Message; $damageRejected = $damageMessage -like [string]$damage.expected }
        Assert-Automation $damageRejected "WithdrawReady damage '$($damage.name)' did not reject at its intended authority boundary (actual: $damageMessage)"
    }

    $ambiguousReadyWorkspace = Copy-TestWorkspace -Source $withdrawDamageBase.workspace -Destination (Join-Path $testRoot 'withdraw-ready-ambiguous-event')
    $ambiguousEventPath = Join-Path $ambiguousReadyWorkspace 'iteration-events.jsonl'
    $ambiguousEvent = [ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'; event_id = "$($withdrawDamageBase.withdraw_id)-ready-0002"; sequence = 2
        timestamp = $fixed; project_id = $withdrawDamageBase.project_id; unit_id = $withdrawDamageBase.withdraw_id
        event_type = 'state-transition'; summary = 'Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites.'; receipts = @()
    }
    [IO.File]::AppendAllText($ambiguousEventPath, (($ambiguousEvent | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $ambiguousReadyRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action WithdrawReady -WorkspaceRoot $ambiguousReadyWorkspace -UnitId $withdrawDamageBase.withdraw_id -Timestamp $fixed -OutPath (Join-Path $ambiguousReadyWorkspace 'receipts\withdraw-ready.json') -Execute | Out-Null
    } catch { $ambiguousReadyRejected = $_.Exception.Message -like '*exactly one owner-generated Ready event*' }
    Assert-Automation $ambiguousReadyRejected 'WithdrawReady accepted ambiguous Ready-event authority'

    $faultFixture = New-TestReadyWithdrawalWorkspace -Root (Join-Path $testRoot 'withdraw-ready-fault') -ProjectId 'withdraw-ready-fault'
    $faultReceiptPath = Join-Path $faultFixture.workspace 'receipts\withdraw-ready.json'
    $faultInterrupted = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action WithdrawReady -WorkspaceRoot $faultFixture.workspace -UnitId $faultFixture.withdraw_id -Timestamp $fixed -OutPath $faultReceiptPath -TransitionFaultAfter after-intent -Execute | Out-Null
    } catch { $faultInterrupted = $_.Exception.Message -like '*Injected interruption after intent publication*' }
    $faultUnitPath = Join-Path $faultFixture.workspace "iteration-units\$($faultFixture.withdraw_id).json"
    Assert-Automation (
        $faultInterrupted -and
        [string](Get-Content -LiteralPath $faultUnitPath -Raw | ConvertFrom-Json).status -eq 'ready' -and
        -not (Test-Path -LiteralPath $faultReceiptPath)
    ) 'WithdrawReady fault injection changed the live target before recovery'
    $faultWithdrawalEvent = "$($faultFixture.withdraw_id)-ready-withdrawn-0002"
    $faultRecovery = & $transitionLedgerModule {
        param($Workspace,$Transaction)
        Complete-MorphospaceTransitionLedger -WorkspaceRoot $Workspace -TransactionId $Transaction -Repair
    } $faultFixture.workspace "$faultWithdrawalEvent-transition"
    Assert-Automation (
        $faultRecovery.status -eq 'committed' -and
        [string](Get-Content -LiteralPath $faultUnitPath -Raw | ConvertFrom-Json).status -eq 'proposed' -and
        (Test-Path -LiteralPath $faultReceiptPath -PathType Leaf) -and
        @((Get-Content -LiteralPath (Join-Path $faultFixture.workspace 'iteration-events.jsonl')) | Where-Object { $_ -like "*$faultWithdrawalEvent*" }).Count -eq 1
    ) 'WithdrawReady transaction recovery did not complete exactly once'

    $unresolvedWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "unresolved-instruction-project") -ProjectId "unresolved-instruction-test" -UnitId "unit-unresolved-001"
    $unresolvedUnitPath = Join-Path $unresolvedWorkspace "iteration-units\unit-unresolved-001.json"
    $unresolvedUnit = Get-Content -LiteralPath $unresolvedUnitPath -Raw | ConvertFrom-Json
    $unresolvedUnit.instruction_impact = "review"
    $unresolvedUnit.instruction_none_justification = $null
    $unresolvedUnit.instruction_surfaces = @(
        [pscustomobject][ordered]@{ surface_kind = "agents"; path = "<missing-root>/AGENTS.md"; owner = "missing-root"; change_reason = "Prove unresolved aliases fail before claim."; action = "review-no-change"; status = "planned"; validation = "Observe the exact stable file."; skill_id = $null }
    )
    Write-TestJson -Path $unresolvedUnitPath -Value $unresolvedUnit
    $unresolvedInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $unresolvedWorkspace -UnitId "unit-unresolved-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    Assert-Automation (-not $unresolvedInspect.claim_preflight.ready_to_claim -and @($unresolvedInspect.claim_preflight.issues | Where-Object { $_ -like "Instruction surface preflight failed*" }).Count -eq 1) "claim preflight did not report an unresolved instruction alias"
    $unresolvedClaimRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $unresolvedWorkspace -UnitId "unit-unresolved-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    } catch { $unresolvedClaimRejected = $_.Exception.Message -like "Claim preflight blocked:*" }
    Assert-Automation ($unresolvedClaimRejected -and [string](Get-Content -LiteralPath $unresolvedUnitPath -Raw | ConvertFrom-Json).status -eq "ready") "claim crossed the state boundary with an unresolved instruction alias"

    $guardWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "guard-profile-project") -ProjectId "guard-profile-test" -UnitId "unit-guard-001"
    $guardUnitPath = Join-Path $guardWorkspace "iteration-units\unit-guard-001.json"
    $guardUnit = Get-Content -LiteralPath $guardUnitPath -Raw | ConvertFrom-Json
    $guardUnit | Add-Member -NotePropertyName guard_profile -NotePropertyValue "fast"
    Write-TestJson -Path $guardUnitPath -Value $guardUnit
    $fastInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $guardWorkspace -UnitId "unit-guard-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    Assert-Automation ($fastInspect.claim_preflight.guard_profile.status -eq "pass" -and $fastInspect.claim_preflight.ready_to_claim) "explicit fast product guard was not claimable"
    $guardUnit.change_categories = @("workflow-automation")
    Write-TestJson -Path $guardUnitPath -Value $guardUnit
    $lockedInspect = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $guardWorkspace -UnitId "unit-guard-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    Assert-Automation (-not $lockedInspect.claim_preflight.ready_to_claim -and $lockedInspect.claim_preflight.guard_profile.status -eq "fail" -and @($lockedInspect.claim_preflight.guard_profile.reason_codes) -contains "guard-profile-insufficient") "fast guard did not reject workflow trust-root work"

    $claim = Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed -OutPath (Join-Path $receiptRoot "claim.json") -Execute
    Assert-Automation ($claim.transition -eq "ready-to-active" -and $claim.status_after -eq "active" -and $claim.claim_preflight.ready_to_claim -and $claim.claim_preflight.requirements_declared -and @($claim.claim_preflight.tools | Where-Object { -not $_.available }).Count -eq 0 -and $claim.claim_preflight.product_inputs[0].hash_matches -and [string]$claim.claim_preflight.writable_repositories[0].tree -match '^[0-9a-f]{40}$') "claim transition and complete exact preflight evidence"
    $eventCount = @(Get-Content (Join-Path $workspace "iteration-events.jsonl")).Count
    $claimAgain = Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute
    Assert-Automation ($claimAgain.transition -eq "idempotent") "idempotent claim"
    Assert-Automation (@(Get-Content (Join-Path $workspace "iteration-events.jsonl")).Count -eq $eventCount) "idempotent claim appended an event"

    $completionId = "unit-auto-001-instruction-completion"
    $nonInFlightRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action CompleteInstructionSurfaces -WorkspaceRoot $readyWorkspace -UnitId "unit-ready-001" `
            -RepoMapPath $repoMapPath -InstructionCompletionId "unit-ready-001-instruction-completion" -Timestamp $fixed | Out-Null
    } catch { $nonInFlightRejected = $_.Exception.Message -like "CompleteInstructionSurfaces requires the matching in-flight unit.*" }
    Assert-Automation $nonInFlightRejected "instruction completion accepted a non-in-flight unit"

    $validatingEntry = Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute
    Assert-Automation ($validatingEntry.status_after -eq "validating") "instruction completion fixture did not enter validating state"
    $completionPlan = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") `
        -Action CompleteInstructionSurfaces -WorkspaceRoot $workspace -UnitId "unit-auto-001" `
        -RepoMapPath $repoMapPath -InstructionCompletionId $completionId -Timestamp $fixed |
        ConvertFrom-Json
    $completionSurfaceKinds = @($completionPlan.instruction_surface_completion.surfaces.surface_kind | ForEach-Object { [string]$_ })
    Assert-Automation (
        -not $completionPlan.executed -and
        $completionSurfaceKinds.Count -eq 4 -and
        @("agents", "router-doc", "compatibility-doc", "roadmap-doc" | Where-Object { $completionSurfaceKinds -cnotcontains $_ }).Count -eq 0
    ) "instruction completion dry run"
    Assert-Automation (@((Get-Content -LiteralPath $instructionUnitPath -Raw | ConvertFrom-Json).instruction_surfaces | Where-Object { [string]$_.status -ne "planned" }).Count -eq 0) "instruction completion dry run mutated the unit"
    $completionEventCount = @(Get-Content (Join-Path $workspace "iteration-events.jsonl")).Count
    $completionStateBefore = Get-Content -LiteralPath (Join-Path $workspace "workspace.state.json") -Raw | ConvertFrom-Json
    $completionUnitBefore = Get-Content -LiteralPath $instructionUnitPath -Raw | ConvertFrom-Json

    $wrongIdentityRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action CompleteInstructionSurfaces -WorkspaceRoot $workspace -UnitId "unit-auto-001" `
            -RepoMapPath $repoMapPath -InstructionCompletionId $completionId -InstructionSurfaceIds (('0' * 64) -join '') `
            -ExpectedUnitSha256 ([string]$completionPlan.instruction_surface_completion.expected_unit_sha256) `
            -ExpectedInstructionObservationSha256 ([string]$completionPlan.instruction_surface_completion.observation_sha256) `
            -OutPath (Join-Path $receiptRoot "instruction-completion.json") -Timestamp $fixed -Execute | Out-Null
    } catch { $wrongIdentityRejected = $_.Exception.Message -like "InstructionSurfaceIds must equal*" }
    Assert-Automation $wrongIdentityRejected "instruction completion accepted an unexpected surface identity"

    $instructionBytes = [System.IO.File]::ReadAllBytes((Join-Path $repo "AGENTS.md"))
    try {
        [System.IO.File]::WriteAllText((Join-Path $repo "AGENTS.md"), "one-byte-drift!`n", $encoding)
        $staleObservationRejected = $false
        try {
            Invoke-MorphospaceWorkUnitAutomation -Action CompleteInstructionSurfaces -WorkspaceRoot $workspace -UnitId "unit-auto-001" `
                -RepoMapPath $repoMapPath -InstructionCompletionId $completionId `
                -InstructionSurfaceIds @($completionPlan.instruction_surface_completion.surfaces.surface_id) `
                -ExpectedUnitSha256 ([string]$completionPlan.instruction_surface_completion.expected_unit_sha256) `
                -ExpectedInstructionObservationSha256 ([string]$completionPlan.instruction_surface_completion.observation_sha256) `
                -OutPath (Join-Path $receiptRoot "instruction-completion.json") -Timestamp $fixed -Execute | Out-Null
        } catch { $staleObservationRejected = $_.Exception.Message -like "ExpectedInstructionObservationSha256 does not match*" }
        Assert-Automation $staleObservationRejected "instruction completion accepted changed surface evidence"
    } finally {
        [System.IO.File]::WriteAllBytes((Join-Path $repo "AGENTS.md"), $instructionBytes)
    }

    $completionReceiptPath = Join-Path $receiptRoot "instruction-completion.json"
    $completed = Invoke-MorphospaceWorkUnitAutomation -Action CompleteInstructionSurfaces -WorkspaceRoot $workspace -UnitId "unit-auto-001" `
        -RepoMapPath $repoMapPath -InstructionCompletionId $completionId `
        -InstructionSurfaceIds @($completionPlan.instruction_surface_completion.surfaces.surface_id) `
        -ExpectedUnitSha256 ([string]$completionPlan.instruction_surface_completion.expected_unit_sha256) `
        -ExpectedInstructionObservationSha256 ([string]$completionPlan.instruction_surface_completion.observation_sha256) `
        -OutPath $completionReceiptPath -Timestamp $fixed -Execute
    Assert-Automation ($completed.transition -eq "planned-instruction-surfaces-to-complete" -and $completed.instruction_surface_completion.validation_commands_executed -eq $false) "instruction completion transition"
    Assert-Automation (Test-Path -LiteralPath $completionReceiptPath -PathType Leaf) "instruction completion receipt was not installed transactionally"
    $completedUnit = Get-Content -LiteralPath $instructionUnitPath -Raw | ConvertFrom-Json
    Assert-Automation (@($completedUnit.instruction_surfaces | Where-Object { [string]$_.status -ne "complete" }).Count -eq 0) "instruction completion did not complete every planned surface"
    foreach ($surface in @($completedUnit.instruction_surfaces)) { $surface.status = "planned" }
    Assert-Automation ((Get-TestCanonicalHash $completedUnit) -ceq (Get-TestCanonicalHash $completionUnitBefore)) "instruction completion changed unit fields other than declared surface status"
    $completionStateAfter = Get-Content -LiteralPath (Join-Path $workspace "workspace.state.json") -Raw | ConvertFrom-Json
    $completionStateAfter.last_event_id = $completionStateBefore.last_event_id
    Assert-Automation ((Get-TestCanonicalHash $completionStateAfter) -ceq (Get-TestCanonicalHash $completionStateBefore)) "instruction completion changed state fields other than last_event_id"
    Assert-Automation (@(Get-Content (Join-Path $workspace "iteration-events.jsonl")).Count -eq ($completionEventCount + 1)) "instruction completion did not append exactly one event"
    $completionReceipt = Get-Content -LiteralPath $completionReceiptPath -Raw
    Assert-Automation (Test-Json -Json $completionReceipt -SchemaFile (Join-Path $RepoRoot "schemas\work-unit-automation-receipt.schema.json")) "instruction completion receipt failed its schema"
    $damagedCompletionReceipt = $completionReceipt | ConvertFrom-Json -Depth 100
    @($damagedCompletionReceipt.instruction_surface_completion.surfaces | Where-Object { [string]$_.surface_kind -ceq "compatibility-doc" })[0].surface_kind = "unknown-doc"
    Assert-Automation (-not ($damagedCompletionReceipt | ConvertTo-Json -Depth 100 | Test-Json -SchemaFile (Join-Path $RepoRoot "schemas\work-unit-automation-receipt.schema.json") -ErrorAction SilentlyContinue)) "instruction completion receipt accepted an unknown surface kind"

    $preflightWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "preflight-project") -ProjectId "preflight-test" -UnitId "unit-preflight-001"
    $preflightUnitPath = Join-Path $preflightWorkspace "iteration-units\unit-preflight-001.json"
    $preflightUnit = Get-Content -LiteralPath $preflightUnitPath -Raw | ConvertFrom-Json
    $preflightUnit | Add-Member -NotePropertyName tags -NotePropertyValue @("receipt-security")
    Write-TestJson -Path $preflightUnitPath -Value $preflightUnit
    Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $preflightWorkspace -UnitId "unit-preflight-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $preflightWorkspace -UnitId "unit-preflight-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    $preflightStatePath = Join-Path $preflightWorkspace "workspace.state.json"
    $preflightEventsPath = Join-Path $preflightWorkspace "iteration-events.jsonl"
    $preflightBefore = @(@($preflightUnitPath, $preflightStatePath, $preflightEventsPath) | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    $automationModule = Get-Module WorkUnitAutomation
    $preflightResult = & $automationModule {
        param($Workspace, $UnitId, $MapPath, $Timestamp)
        function Invoke-MorphospaceAuthorityRunnerForRecord {
            param($WorkspaceRoot, $UnitId, $RepositoryMap, $AuthorityRunnerPath, $AuthorityRunnerArguments, $RunnerAction, $ValidationReceipt)
            return "stub-preflight-nonce"
        }
        Invoke-MorphospaceWorkUnitAutomation -Action PreflightValidation -WorkspaceRoot $Workspace -UnitId $UnitId -RepoMapPath $MapPath -AuthorityRunnerPath "stub-authority-runner.ps1" -Timestamp $Timestamp -Execute
    } $preflightWorkspace "unit-preflight-001" $repoMapPath $fixed
    $preflightAfter = @(@($preflightUnitPath, $preflightStatePath, $preflightEventsPath) | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    Assert-Automation ($preflightResult.transition -eq "authority-preflight-ready") "receipt-security preflight did not complete"
    Assert-Automation (($preflightBefore -join "`n") -ceq ($preflightAfter -join "`n")) "preflight rewrote workflow state without an event"

    $statusBefore = (Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $repo "local-only.txt"), "preserve me`n", $encoding)
    $dirtyBefore = (Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n"
    $inspectDirty = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    $dirtyAfter = (Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n"
    Assert-Automation ($inspectDirty.preservation.repository_states[0].dirty -eq $true) "dirty repository was not reported"
    Assert-Automation ($dirtyBefore -eq $dirtyAfter -and (Test-Path (Join-Path $repo "local-only.txt"))) "dirty repository was rewritten"
    Remove-Item -LiteralPath (Join-Path $repo "local-only.txt")
    Assert-Automation ($statusBefore -eq ((Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) -join "`n")) "test cleanup failed"

    $dirtyClaimWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "dirty-claim-project") -ProjectId "dirty-claim-test" -UnitId "unit-dirty-001"
    [System.IO.File]::WriteAllText((Join-Path $repo "src\preexisting.txt"), "preexisting`n", $encoding)
    $dirtyClaimRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $dirtyClaimWorkspace -UnitId "unit-dirty-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    } catch {
        $dirtyClaimRejected = $_.Exception.Message -like "Claim refused pre-existing dirty-path overlap*"
    }
    Assert-Automation $dirtyClaimRejected "claim did not reject pre-existing dirty overlap inside allowed paths"
    $adoptionPath = New-TestInflightAdoptionReceipt -Workspace $dirtyClaimWorkspace -UnitId "unit-dirty-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    $adoptedClaim = Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $dirtyClaimWorkspace -UnitId "unit-dirty-001" -RepoMapPath $repoMapPath -AdoptionReceipt "receipts/unit-dirty-001-inflight-adoption.json" -Timestamp $fixed -Execute
    Assert-Automation ($adoptedClaim.transition -eq "ready-to-active" -and $adoptedClaim.adoption_receipt -eq "receipts/unit-dirty-001-inflight-adoption.json") "hashed in-flight adoption did not claim bounded pre-protocol work"
    Assert-Automation (Test-Path -LiteralPath $adoptionPath -PathType Leaf) "in-flight adoption receipt was not preserved"
    Remove-Item -LiteralPath (Join-Path $repo "src\preexisting.txt")

    $tamperedAdoptionWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "tampered-adoption-project") -ProjectId "tampered-adoption-test" -UnitId "unit-adopt-001"
    [System.IO.File]::WriteAllText((Join-Path $repo "src\preexisting.txt"), "first version`n", $encoding)
    New-TestInflightAdoptionReceipt -Workspace $tamperedAdoptionWorkspace -UnitId "unit-adopt-001" -RepoMapPath $repoMapPath -Timestamp $fixed | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repo "src\preexisting.txt"), "changed after receipt`n", $encoding)
    $tamperedAdoptionRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $tamperedAdoptionWorkspace -UnitId "unit-adopt-001" -RepoMapPath $repoMapPath -AdoptionReceipt "receipts/unit-adopt-001-inflight-adoption.json" -Timestamp $fixed -Execute | Out-Null
    } catch {
        $tamperedAdoptionRejected = $_.Exception.Message -like "In-flight adoption receipt hash mismatch*"
    }
    Assert-Automation $tamperedAdoptionRejected "claim accepted work that changed after its in-flight adoption receipt"
    Remove-Item -LiteralPath (Join-Path $repo "src\preexisting.txt")

    $headBeforeDetach = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    Invoke-TestGit -Path $repo -Arguments @("checkout", "--detach") | Out-Null
    $inspectDetached = Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed
    Assert-Automation ($inspectDetached.preservation.repository_states[0].relation -eq "detached") "detached HEAD was not reported"
    Assert-Automation ((@(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]) -eq $headBeforeDetach) "detached inspection changed HEAD"
    Invoke-TestGit -Path $repo -Arguments @("switch", "main") | Out-Null

    $begin = Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed -OutPath (Join-Path $receiptRoot "begin-validation.json") -Execute
    Assert-Automation ($begin.status_after -eq "validating" -and @($begin.validation_matrix).Count -eq 2) "validation plan including instruction synchronization"
    $missingReceiptRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -ValidationTier deep -ValidationResult pass -ValidationReceipt "receipts/does-not-exist.json" -Timestamp $fixed | Out-Null
    } catch {
        $missingReceiptRejected = $_.Exception.Message -like "Validation receipt does not exist:*"
    }
    Assert-Automation $missingReceiptRejected "nonexistent validation receipt was accepted"
    $validationHead = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $validationBranch = @(Invoke-TestGit -Path $repo -Arguments @("branch", "--show-current"))[0]
    $validReceiptPath = New-TestValidationReceipt -Workspace $workspace -ProjectId "automation-test" -UnitId "unit-auto-001" -Tier deep -Result pass -RepositoryRevisions @([ordered]@{
        repo_id = "project-shell"; base_revision = $validationHead; head_revision = $validationHead; branch = $validationBranch
    }) -InstructionSynchronization
    $record = Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -ValidationTier deep -ValidationResult pass -ValidationReceipt "receipts/unit-auto-001-pass-validation.json" -Timestamp $fixed -OutPath (Join-Path $receiptRoot "validation.json") -Execute
    Assert-Automation ($record.transition -eq "validation-pass") "passing validation record"

    $duplicateGateWorkspace = New-TestWorkspace -Root (Join-Path $planningRepo "duplicate-gate-project") -ProjectId "duplicate-gate-test" -UnitId "unit-duplicate-gate-001"
    $duplicateGateUnitPath = Join-Path $duplicateGateWorkspace "iteration-units\unit-duplicate-gate-001.json"
    $duplicateGateUnit = Get-Content -LiteralPath $duplicateGateUnitPath -Raw | ConvertFrom-Json
    $duplicateGateUnit.validation = @(
        [pscustomobject][ordered]@{ profile_id = "source-only"; command = "first source-only command" },
        [pscustomobject][ordered]@{ profile_id = "source-only"; command = "second source-only command" },
        [pscustomobject][ordered]@{ profile_id = "source-only"; command = "third source-only command" }
    )
    Write-TestJson -Path $duplicateGateUnitPath -Value $duplicateGateUnit
    Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $duplicateGateWorkspace -UnitId "unit-duplicate-gate-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $duplicateGateWorkspace -UnitId "unit-duplicate-gate-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    $duplicateGateHead = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $duplicateGateBranch = @(Invoke-TestGit -Path $repo -Arguments @("branch", "--show-current"))[0]
    $duplicateGateRows = @(
        [ordered]@{ gate_id = "validation-source-only"; status = "pass"; command = "third source-only command"; evidence_refs = @("validation-evidence") },
        [ordered]@{ gate_id = "validation-source-only"; status = "pass"; command = "first source-only command"; evidence_refs = @("validation-evidence") },
        [ordered]@{ gate_id = "validation-source-only"; status = "pass"; command = "second source-only command"; evidence_refs = @("validation-evidence") }
    )
    $duplicateGateReceiptPath = New-TestValidationReceipt -Workspace $duplicateGateWorkspace -ProjectId "duplicate-gate-test" -UnitId "unit-duplicate-gate-001" -Tier standard -Result pass -RepositoryRevisions @([ordered]@{
        repo_id = "project-shell"; base_revision = $duplicateGateHead; head_revision = $duplicateGateHead; branch = $duplicateGateBranch
    }) -Gates $duplicateGateRows -EvidenceName "duplicate-gate-validation-evidence.txt"
    $duplicateGateReceiptReference = "receipts/unit-duplicate-gate-001-pass-validation.json"
    $duplicateGatePositive = Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $duplicateGateWorkspace -UnitId "unit-duplicate-gate-001" -RepoMapPath $repoMapPath -ValidationTier standard -ValidationResult pass -ValidationReceipt $duplicateGateReceiptReference -Timestamp $fixed
    Assert-Automation ($duplicateGatePositive.transition -eq "validation-pass") "distinct commands sharing one gate ID did not pair as an exact multiset"

    $validDuplicateGateReceipt = Get-Content -LiteralPath $duplicateGateReceiptPath -Raw | ConvertFrom-Json
    $duplicateGateDamageCases = @(
        [pscustomobject]@{ name = "missing"; expected = "Validation receipt does not cover the exact validation-gate set."; mutate = { param($receipt) $receipt.gates = @($receipt.gates | Select-Object -First 2) } },
        [pscustomobject]@{ name = "extra"; expected = "Validation receipt does not cover the exact validation-gate set."; mutate = { param($receipt) $receipt.gates = @($receipt.gates) + @([pscustomobject][ordered]@{ gate_id = "validation-extra"; status = "pass"; command = "unexpected command"; evidence_refs = @("validation-evidence") }) } },
        [pscustomobject]@{ name = "command-drift"; expected = "Validation command drifted for gate 'validation-source-only'."; mutate = { param($receipt) $receipt.gates[0].command = "THIRD SOURCE-ONLY COMMAND" } },
        [pscustomobject]@{ name = "duplicate-count"; expected = "Validation command drifted for gate 'validation-source-only'."; mutate = { param($receipt) $receipt.gates[2].command = [string]$receipt.gates[1].command } },
        [pscustomobject]@{ name = "status"; expected = "Passing validation has a non-passing gate 'validation-source-only'."; mutate = { param($receipt) $receipt.gates[1].status = "fail" } },
        [pscustomobject]@{ name = "evidence"; expected = "Gate 'validation-source-only' references unknown artifact 'missing-evidence'."; mutate = { param($receipt) $receipt.gates[1].evidence_refs = @("missing-evidence") } }
    )
    foreach ($damageCase in $duplicateGateDamageCases) {
        $damagedReceipt = $validDuplicateGateReceipt | ConvertTo-Json -Depth 32 | ConvertFrom-Json
        & $damageCase.mutate $damagedReceipt
        Write-TestJson -Path $duplicateGateReceiptPath -Value $damagedReceipt
        $damageRejected = $false
        try {
            Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $duplicateGateWorkspace -UnitId "unit-duplicate-gate-001" -RepoMapPath $repoMapPath -ValidationTier standard -ValidationResult pass -ValidationReceipt $duplicateGateReceiptReference -Timestamp $fixed | Out-Null
        } catch {
            $damageRejected = $_.Exception.Message -ceq [string]$damageCase.expected
        }
        Assert-Automation $damageRejected "duplicate gate $($damageCase.name) damage did not fail closed"
    }
    Write-TestJson -Path $duplicateGateReceiptPath -Value $validDuplicateGateReceipt

    $validationEvidencePath = Join-Path $receiptRoot "self-test-evidence.txt"
    [System.IO.File]::WriteAllText($validationEvidencePath, "tampered after validation`n", $encoding)
    $tamperedAcceptanceRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed | Out-Null
    } catch {
        $tamperedAcceptanceRejected = $_.Exception.Message -like "Validation artifact hash mismatch*"
    }
    Assert-Automation $tamperedAcceptanceRejected "acceptance did not revalidate a tampered artifact"
    [System.IO.File]::WriteAllText($validationEvidencePath, "validation evidence for unit-auto-001 pass`n", $encoding)
    $accepted = Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -Timestamp $fixed -OutPath (Join-Path $receiptRoot "accept.json") -Execute
    Assert-Automation ($accepted.status_after -eq "accepted" -and $null -eq $accepted.current_unit_after) "accept transition"
    $acceptedState = Get-Content -LiteralPath (Join-Path $workspace "workspace.state.json") -Raw | ConvertFrom-Json
    Assert-Automation ([string]$acceptedState.next_ready_unit -eq "unit-auto-002") "deterministic next-ready selection"
    Assert-Automation ([string]$acceptedState.last_accepted_receipt -eq "receipts/unit-auto-001-pass-validation.json") "v2 last accepted receipt projection"
    Assert-Automation (@($acceptedState.repository_heads).Count -eq 1) "v2 repository-head projection"

    $unplannedOld = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    [System.IO.File]::WriteAllText((Join-Path $repo "src\unplanned.txt"), "published before PreparePush`n", $encoding)
    Invoke-TestGit -Path $repo -Arguments @("add", "src/unplanned.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "unplanned publication fixture") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("push", "origin", "main") | Out-Null
    $unplannedNew = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $staleStatePath = Join-Path $workspace "workspace.state.json"
    $staleState = Get-Content -LiteralPath $staleStatePath -Raw | ConvertFrom-Json
    $staleState.dirty_repositories = @("project-shell")
    $staleState.pending_push_bundle = [pscustomobject][ordered]@{
        bundle_id = "older-unit-push-bundle"; unit_ids = @("unit-auto-001"); repo_ids = @("project-shell"); ready = $true
    }
    $staleState.repository_heads = @([pscustomobject][ordered]@{
        repo_id = "project-shell"; head = $unplannedOld; branch = "main"; dirty_fingerprint = ('0' * 64)
    })
    Write-TestJson -Path $staleStatePath -Value $staleState
    $closurePath = New-TestUnplannedPublicationClosure `
        -Workspace $workspace `
        -ProjectId "automation-test" `
        -UnitId "unit-auto-001" `
        -RepoId "project-shell" `
        -Branch "main" `
        -Upstream "origin/main" `
        -OldRevision $unplannedOld `
        -NewRevision $unplannedNew `
        -PendingBundle "older-unit-push-bundle" `
        -ValidationReceipt "receipts/unit-auto-001-pass-validation.json"
    $reconciledPublication = Invoke-MorphospaceWorkUnitAutomation `
        -Action ReconcilePublication `
        -WorkspaceRoot $workspace `
        -UnitId "unit-auto-001" `
        -RepoMapPath $repoMapPath `
        -PublicationClosure "receipts/unit-auto-001-unplanned-publication-closure.json" `
        -Timestamp $fixed `
        -Execute
    Assert-Automation ($reconciledPublication.transition -eq "unplanned-publication-reconciled") "unplanned publication recovery transition"
    Assert-Automation ([string]$reconciledPublication.publication_closure.closure_id -eq "unit-auto-001-unplanned-publication-closure") "unplanned publication closure binding"
    $reconciledState = Get-Content -LiteralPath $staleStatePath -Raw | ConvertFrom-Json
    Assert-Automation ($null -eq $reconciledState.pending_push_bundle -and @($reconciledState.dirty_repositories).Count -eq 0) "unplanned publication recovery did not clear stale state"
    Assert-Automation ([string]$reconciledState.repository_heads[0].head -eq $unplannedNew) "unplanned publication recovery did not project the observed head"
    Assert-Automation ((@(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]) -eq $unplannedNew) "unplanned publication recovery mutated Git"
    Assert-Automation (Test-Path -LiteralPath $closurePath -PathType Leaf) "unplanned publication closure was not preserved"

    $scopeWorkspace = New-TestWorkspace -Root (Join-Path $repo "morphospace-scope-test") -ProjectId "scope-test" -UnitId "unit-scope-001"
    $scopeUnitPath = Join-Path $scopeWorkspace "iteration-units\unit-scope-001.json"
    $scopeUnit = Get-Content -LiteralPath $scopeUnitPath -Raw | ConvertFrom-Json
    $scopeUnit.allowed_repositories[0].allowed_paths = @($scopeUnit.allowed_repositories[0].allowed_paths) + ".github/workflows/ci.yml"
    Write-TestJson -Path $scopeUnitPath -Value $scopeUnit
    [System.IO.File]::WriteAllText((Join-Path $repo "outside.txt"), "outside unit scope`n", $encoding)
    Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repo ".github\workflows")) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repo ".github\workflows\ci.yml"), "name: hidden-path-regression`n", $encoding)
    $scopeHead = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $scopeBranch = @(Invoke-TestGit -Path $repo -Arguments @("branch", "--show-current"))[0]
    New-TestValidationReceipt -Workspace $scopeWorkspace -ProjectId "scope-test" -UnitId "unit-scope-001" -Tier standard -Result pass -RepositoryRevisions @([ordered]@{
        repo_id = "project-shell"; base_revision = $scopeHead; head_revision = $scopeHead; branch = $scopeBranch
    }) -ChangedPaths @([ordered]@{ repo_id = "project-shell"; path = ".github/workflows/ci.yml" }) | Out-Null
    $scopeRecord = Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -ValidationTier standard -ValidationResult pass -ValidationReceipt "receipts/unit-scope-001-pass-validation.json" -Timestamp $fixed
    $scopeTransactions = @(Get-ChildItem -LiteralPath (Join-Path $scopeWorkspace "receipts\transactions") -File -ErrorAction SilentlyContinue)
    Assert-Automation ($scopeRecord.transition -eq "validation-pass" -and (Test-Path -LiteralPath (Join-Path $repo "outside.txt")) -and $scopeTransactions.Count -gt 0) "hidden in-scope path, out-of-scope user work, or protocol-owned transaction artifacts blocked validation or were modified"
    New-TestValidationReceipt -Workspace $scopeWorkspace -ProjectId "scope-test" -UnitId "unit-scope-001" -Tier standard -Result pass -RepositoryRevisions @([ordered]@{
        repo_id = "project-shell"; base_revision = $scopeHead; head_revision = $scopeHead; branch = $scopeBranch
    }) -ChangedPaths @(
        [ordered]@{ repo_id = "project-shell"; path = ".github/workflows/ci.yml" },
        [ordered]@{ repo_id = "project-shell"; path = "outside.txt" }
    ) | Out-Null
    $outsideScopeRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $scopeWorkspace -UnitId "unit-scope-001" -RepoMapPath $repoMapPath -ValidationTier standard -ValidationResult pass -ValidationReceipt "receipts/unit-scope-001-pass-validation.json" -Timestamp $fixed | Out-Null
    } catch {
        $outsideScopeRejected = $_.Exception.Message -like "Validation changed path is outside unit scope*"
    }
    Assert-Automation $outsideScopeRejected "validation did not reject an out-of-scope changed path"
    Remove-Item -LiteralPath (Join-Path $repo "outside.txt")
    Remove-Item -LiteralPath (Join-Path $repo ".github") -Recurse -Force
    Remove-Item -LiteralPath $scopeWorkspace -Recurse -Force

    [System.IO.File]::WriteAllText((Join-Path $repo "src\ahead.txt"), "ahead`n", $encoding)
    Invoke-TestGit -Path $repo -Arguments @("add", "src/ahead.txt") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("commit", "-m", "ahead") | Out-Null
    $localHead = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
    $remoteBefore = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "origin/main"))[0]
    $revisionsPath = Join-Path $testRoot "revisions.json"
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "planning state before prepared push") | Out-Null
    $planningHead = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "HEAD"))[0]
    Write-TestJson -Path $revisionsPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.revision_set.v1"; repositories = @(
        [ordered]@{ repo_id = "project-shell"; commit = $localHead },
        [ordered]@{ repo_id = "workflow-planning"; commit = $planningHead }
    ) })
    $pushPlanPath = Join-Path $receiptRoot "push-plan.json"
    $prepared = Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -RevisionsPath $revisionsPath -Timestamp $fixed -OutPath $pushPlanPath -Execute
    Assert-Automation ($prepared.push_plan.schema -eq "rusty.morphospace.workflow.push_bundle_plan.v1" -and $prepared.push_plan.execution -eq "not-performed" -and -not $prepared.push_plan.force_push_allowed) "push plan execution boundary"
    Assert-Automation ($prepared.push_plan.repositories[-1].role -eq "planning" -and $prepared.push_plan.repositories[-1].repo_id -eq "workflow-planning") "push plan did not place the distinct planning repository last"
    Assert-Automation (-not ($prepared.push_plan.PSObject.Properties.Name -contains "remote_readback_complete")) "automation fabricated executed-push evidence"
    Assert-Automation ((@(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "origin/main"))[0]) -eq $remoteBefore) "push preparation changed the remote"

    # A legacy pending bundle stores its plan in the executed PreparePush automation
    # receipt and its event in the immutable transition-ledger pair.
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "retain prepared push evidence") | Out-Null
    $preparedEventId = [string]$prepared.event_id
    $preparedIntentRelative = "receipts/transactions/$preparedEventId-transition.intent.json"
    $preparedCompletionRelative = "receipts/transactions/$preparedEventId-transition.completion.json"
    $preparedIntentPath = Join-Path $workspace ($preparedIntentRelative -replace "/", "\")
    $preparedCompletionPath = Join-Path $workspace ($preparedCompletionRelative -replace "/", "\")
    $realPreparedIntent = Get-Content -Raw $preparedIntentPath | ConvertFrom-Json
    $realPreparedCompletion = Get-Content -Raw $preparedCompletionPath | ConvertFrom-Json
    $realPreparedPlanBytes = [IO.File]::ReadAllBytes($pushPlanPath)
    $realPreparedPlanHash = (Get-FileHash $pushPlanPath).Hash.ToLowerInvariant()
    $realPreparedArtifacts = @($realPreparedIntent.artifacts)
    $realPreparedLedgerEvents = @(Get-Content (Join-Path $workspace "iteration-events.jsonl") | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $realPreparedEvent = @($realPreparedLedgerEvents | Where-Object { [string]$_.event_id -eq $preparedEventId })
    Assert-Automation (
        [string]$realPreparedIntent.schema -eq "rusty.morphospace.workflow.transition_ledger_intent.v1" -and
        [string]$realPreparedIntent.transaction_id -eq "$preparedEventId-transition" -and
        [string]$realPreparedIntent.event.event_type -eq "commit" -and
        [string]$realPreparedCompletion.intent.role -eq "transition-ledger-intent" -and
        [string]$realPreparedCompletion.intent.path -eq $preparedIntentRelative -and
        [string]$realPreparedCompletion.intent.schema -eq [string]$realPreparedIntent.schema -and
        [string]$realPreparedCompletion.intent.sha256 -eq (Get-FileHash $preparedIntentPath).Hash.ToLowerInvariant() -and
        $realPreparedArtifacts.Count -eq 1 -and
        [string]$realPreparedArtifacts[0].path -eq "receipts/push-plan.json" -and
        [string]$realPreparedArtifacts[0].sha256 -eq $realPreparedPlanHash -and
        [Convert]::ToHexString([Convert]::FromBase64String([string]$realPreparedArtifacts[0].bytes_base64)) -ceq [Convert]::ToHexString($realPreparedPlanBytes) -and
        $realPreparedEvent.Count -eq 1
    ) "real PreparePush receipt is not owned byte-for-byte by its transition-ledger provenance"
    $retirementInput = Join-Path $testRoot "prepared-push-retirement-input.json"
    $retirementOutput = Join-Path $receiptRoot "prepared-push-retirement.json"
    $retirementStatePath = Join-Path $workspace "workspace.state.json"
    $retirementState = Get-Content -Raw $retirementStatePath | ConvertFrom-Json
    $staleBlocker = [pscustomobject][ordered]@{
        blocker_id = "stale-auto-push-plan"
        condition = "The exact prepared bundle remains pending."
        resume_when = "Typed stale-bookkeeping evidence is accepted."
    }
    $unrelatedBlocker = [pscustomobject][ordered]@{
        blocker_id = "unrelated-auto-blocker"
        condition = "An unrelated condition remains unresolved."
        resume_when = "Separate unrelated evidence passes."
    }
    $retirementState.blockers = @($retirementState.blockers) + $staleBlocker + $unrelatedBlocker
    Write-TestJson -Path $retirementStatePath -Value $retirementState
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "bind exact stale prepared-push blocker") | Out-Null
    $retirementRepositories = @($prepared.push_plan.repositories | ForEach-Object {
        $path = if ([string]$_.repo_id -eq "project-shell") { $repo } else { $planningRepo }
        $head = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "HEAD"))[0]
        $upstream = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"))[0]
        $remoteName = @(Invoke-TestGit -Path $path -Arguments @("config", "--get", "branch.$([string]$_.branch).remote"))[0]
        $remoteFetchIdentity = & $retirementModule {param($root,$remote)Get-PreparedPushRemoteIdentity $root $remote} $path $remoteName
        $remotePushIdentity = & $retirementModule {param($root,$remote)Get-PreparedPushRemoteIdentity $root $remote -Push} $path $remoteName
        $remoteRevision = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "@{upstream}"))[0]
        $counts = (@(Invoke-TestGit -Path $path -Arguments @("rev-list", "--left-right", "--count", "HEAD...@{upstream}"))[0] -split "\s+")
        [ordered]@{
            repo_id = [string]$_.repo_id; role = [string]$_.role; branch = [string]$_.branch; upstream = $upstream
            prepared_revision = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "$([string]$_.commit)^{commit}"))[0]
            local_head = $head; remote_readback_revision = $remoteRevision; worktree_clean = $true
            detached = $false; ahead = [int]$counts[0]; behind = [int]$counts[1]; diverged = $false
            remote_fetch_identity = $remoteFetchIdentity; remote_push_identity = $remotePushIdentity
        }
    })
    $retirementDocument = [ordered]@{
        schema = "rusty.morphospace.workflow.prepared_push_retirement.v1"
        retirement_id = "retirement-auto-001"; project_id = "automation-test"
        bundle_id = [string]$prepared.push_plan.bundle_id; unit_ids = @("unit-auto-001"); reason = "reprepared"
        repository_map_sha256 = (Get-FileHash $repoMapPath).Hash.ToLowerInvariant()
        prepared_plan = [ordered]@{
            container = [ordered]@{ path = "receipts/push-plan.json"; sha256 = (Get-FileHash $pushPlanPath).Hash.ToLowerInvariant() }
            member = "push_plan"
        }
        prepared_event = [ordered]@{
            event_id = $preparedEventId
            intent = [ordered]@{ path = $preparedIntentRelative; sha256 = (Get-FileHash $preparedIntentPath).Hash.ToLowerInvariant() }
            completion = [ordered]@{ path = $preparedCompletionRelative; sha256 = (Get-FileHash $preparedCompletionPath).Hash.ToLowerInvariant() }
            member = "event"
        }
        pending_bundle = [ordered]@{
            value = $retirementState.pending_push_bundle
            sha256 = Get-MorphospaceCanonicalJsonSha256 $retirementState.pending_push_bundle
        }
        stale_blocker = [ordered]@{
            value = $staleBlocker
            sha256 = Get-MorphospaceCanonicalJsonSha256 $staleBlocker
        }
        observed_at = $fixed; repositories = $retirementRepositories
        evidence_search = [ordered]@{ workspace_relative_roots = @("receipts","iteration-events.jsonl"); recognized_binding_count = 0; complete = $true }
        claims = [ordered]@{ workflow_recognized_execution_or_publication_asserted = $false; historical_publication_impossible = $false; remote_mutation_performed = $false }
        mutation = [ordered]@{ pending_bundle_consumed = $true; blocker_id = "stale-auto-push-plan" }
    }
    Write-TestJson -Path $retirementInput -Value $retirementDocument

    $substitutedPlanRejected = $false
    $substitutedPlanMessage = ""
    try {
        $substitutedPlanOwner = Get-Content -Raw $pushPlanPath | ConvertFrom-Json
        $substitutedPlanOwner.push_plan.repositories[0].commit = $remoteBefore
        Write-TestJson -Path $pushPlanPath -Value $substitutedPlanOwner
        $substitutedRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $substitutedRetirement.prepared_plan.container.sha256 = (Get-FileHash $pushPlanPath).Hash.ToLowerInvariant()
        Write-TestJson -Path $retirementInput -Value $substitutedRetirement
        try {
            & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace `
                -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null
        } catch {
            $substitutedPlanMessage = $_.Exception.Message
            $substitutedPlanRejected = $substitutedPlanMessage -like "*transaction-owned preparation artifact*"
        }
    } finally {
        [IO.File]::WriteAllBytes($pushPlanPath, $realPreparedPlanBytes)
        Write-TestJson -Path $retirementInput -Value $retirementDocument
    }
    Assert-Automation $substitutedPlanRejected "prepared-push retirement accepted a post-PreparePush plan substitution: $substitutedPlanMessage"

    $retirementDryRun = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace `
        -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | ConvertFrom-Json
    Assert-Automation ($retirementDryRun.transition -eq "prepared-push-retired" -and -not $retirementDryRun.executed) "prepared-push retirement dry run"
    Assert-Automation ($null -ne (Get-Content -Raw (Join-Path $workspace "workspace.state.json") | ConvertFrom-Json).pending_push_bundle) "prepared-push retirement dry run mutated state"
    $retirementModule=Get-Module PreparedPushRetirement
    $selfRetirementRelative="receipts/current-retirement-input.json"
    $selfRetirementPath=Join-Path $workspace ($selfRetirementRelative-replace"/","\")
    $competingRetirementPath=Join-Path $workspace "receipts\distinct-retirement-competitor.json"
    try{
        Write-TestJson -Path $selfRetirementPath -Value $retirementDocument
        $selfExcluded=& $retirementModule {
            param($root,$bundle,$self,$plan,$intent,$completion)
            try{Test-PreparedPushConflictingEvidence $root $bundle @($self,$plan,$intent,$completion);$true}catch{$false}
        } $workspace ([string]$retirementDocument.bundle_id) $selfRetirementRelative ([string]$retirementDocument.prepared_plan.container.path) ([string]$retirementDocument.prepared_event.intent.path) ([string]$retirementDocument.prepared_event.completion.path)
        Assert-Automation $selfExcluded "prepared-push retirement conflict scan treated its exact current receipt input as competing evidence"
        Write-TestJson -Path $competingRetirementPath -Value $retirementDocument
        $distinctCompetitorRejected=& $retirementModule {
            param($root,$bundle,$self,$plan,$intent,$completion)
            try{Test-PreparedPushConflictingEvidence $root $bundle @($self,$plan,$intent,$completion);$false}catch{$true}
        } $workspace ([string]$retirementDocument.bundle_id) $selfRetirementRelative ([string]$retirementDocument.prepared_plan.container.path) ([string]$retirementDocument.prepared_event.intent.path) ([string]$retirementDocument.prepared_event.completion.path)
        Assert-Automation $distinctCompetitorRejected "prepared-push retirement conflict scan excluded a distinct competing retirement"
    }finally{
        foreach($path in @($selfRetirementPath,$competingRetirementPath)){if([IO.File]::Exists($path)){Remove-Item -LiteralPath $path -Force}}
    }
    Assert-Automation (& $retirementModule {try{ConvertFrom-PreparedPushStrictTimestamp 'not-a-timestamp'|Out-Null;$false}catch{$true}}) "prepared-push retirement accepted an invalid timestamp"
    Assert-Automation (& $retirementModule {try{ConvertFrom-PreparedPushStrictTimestamp ' 2026-01-01T00:00:03Z'|Out-Null;$false}catch{$true}}) "prepared-push retirement accepted timestamp whitespace"
    Assert-Automation (& $retirementModule {try{New-PreparedPushRetirementEventId ('a'*128) 4|Out-Null;$false}catch{$true}}) "prepared-push retirement accepted an oversized derived event identity"
    $ordinalKeyA=& $retirementModule {New-PreparedPushPhysicalGroupKey 'same-physical-id' 'main' 'origin/main'}
    $ordinalKeyB=& $retirementModule {New-PreparedPushPhysicalGroupKey 'same-physical-id' 'Main' 'Origin/Main'}
    Assert-Automation ($ordinalKeyA-cne$ordinalKeyB) "prepared-push retirement physical grouping folded case-distinct branch or upstream authority"
    $caseObservations=@(
        [pscustomobject]@{physical_key=$ordinalKeyA;prepared_reachable=$true},
        [pscustomobject]@{physical_key=$ordinalKeyB;prepared_reachable=$false}
    )
    $caseReachabilityForward=& $retirementModule {param($items)Test-PreparedPushHasUnreachablePhysicalGroup $items} $caseObservations
    $caseReachabilityReverse=& $retirementModule {param($items)Test-PreparedPushHasUnreachablePhysicalGroup $items} @($caseObservations[1],$caseObservations[0])
    Assert-Automation ($caseReachabilityForward-and$caseReachabilityReverse) "prepared-push retirement reachability grouping folded case-distinct authority or depended on input order"

    $stateBytesBeforeTailDamage=[IO.File]::ReadAllBytes($retirementStatePath)
    $tailDamageRejected=$false
    try{
        $tailDamagedState=Get-Content -Raw $retirementStatePath|ConvertFrom-Json
        $tailDamagedState.last_event_id=$null
        Write-TestJson -Path $retirementStatePath -Value $tailDamagedState
        try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$tailDamageRejected=$true}
    }finally{[IO.File]::WriteAllBytes($retirementStatePath,$stateBytesBeforeTailDamage)}
    Assert-Automation $tailDamageRejected "prepared-push retirement accepted split workspace-state and event-ledger tails"

    $alternateRetirementRemote=Join-Path $testRoot 'retirement-retarget.git'
    & git clone --bare --quiet $remote $alternateRetirementRemote
    if($LASTEXITCODE-ne0){throw "Could not create same-tip retirement retarget fixture."}
    $remoteRetargetRejected=$false
    try{
        Invoke-TestGit -Path $repo -Arguments @('remote','set-url','origin',$alternateRetirementRemote)|Out-Null
        try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$remoteRetargetRejected=$true}
    }finally{Invoke-TestGit -Path $repo -Arguments @('remote','set-url','origin',$remote)|Out-Null}
    Assert-Automation $remoteRetargetRejected "prepared-push retirement accepted a same-tip remote identity retarget"

    $fabricatedEventId='unit-auto-001-fabricated-push-prepared-9999'
    $fabricatedTransactionId="$fabricatedEventId-transition"
    $fabricatedPlanRelative='receipts/fabricated-push-plan.json'
    $fabricatedIntentRelative="receipts/transactions/$fabricatedTransactionId.intent.json"
    $fabricatedCompletionRelative="receipts/transactions/$fabricatedTransactionId.completion.json"
    $fabricatedPlanPath=Join-Path $workspace ($fabricatedPlanRelative-replace'/','\')
    $fabricatedIntentPath=Join-Path $workspace ($fabricatedIntentRelative-replace'/','\')
    $fabricatedCompletionPath=Join-Path $workspace ($fabricatedCompletionRelative-replace'/','\')
    try{
        $fabricatedPlanOwner=Get-Content -Raw $pushPlanPath|ConvertFrom-Json
        $fabricatedPlanOwner.event_id=$fabricatedEventId
        Write-TestJson -Path $fabricatedPlanPath -Value $fabricatedPlanOwner
        $fabricatedIntent=$realPreparedIntent|ConvertTo-Json -Depth 32|ConvertFrom-Json
        $fabricatedIntent.created_at=& $retirementModule {param($value)ConvertTo-MorphospaceUtcTimestamp ([DateTimeOffset]$value)} $fabricatedIntent.created_at
        $fabricatedIntent.transaction_id=$fabricatedTransactionId
        $fabricatedIntent.event.event_id=$fabricatedEventId
        $fabricatedIntent.event.sequence=[int]$realPreparedEvent[0].sequence+1
        $fabricatedIntent.event.receipts=@($fabricatedPlanRelative)
        $fabricatedIntent.expected.event_tail_id=$preparedEventId
        $fabricatedIntent.target.state.document.last_event_id=$fabricatedEventId
        $fabricatedIntent.target.state.sha256=& $retirementModule {param($document)Get-MorphospaceCanonicalJsonSha256 $document} $fabricatedIntent.target.state.document
        $fabricatedPlanBytes=[IO.File]::ReadAllBytes($fabricatedPlanPath)
        $fabricatedIntent.artifacts=@([pscustomobject][ordered]@{
            path=$fabricatedPlanRelative
            sha256=(Get-FileHash $fabricatedPlanPath).Hash.ToLowerInvariant()
            bytes_base64=[Convert]::ToBase64String($fabricatedPlanBytes)
        })
        Write-TestJson -Path $fabricatedIntentPath -Value $fabricatedIntent
        $fabricatedCompletion=$realPreparedCompletion|ConvertTo-Json -Depth 32|ConvertFrom-Json
        $fabricatedCompletion.completed_at=& $retirementModule {param($value)ConvertTo-MorphospaceUtcTimestamp ([DateTimeOffset]$value)} $fabricatedCompletion.completed_at
        $fabricatedCompletion.transaction_id=$fabricatedTransactionId
        $fabricatedCompletion.intent.path=$fabricatedIntentRelative
        $fabricatedCompletion.intent.sha256=(Get-FileHash $fabricatedIntentPath).Hash.ToLowerInvariant()
        $fabricatedCompletion.state_sha256=[string]$fabricatedIntent.target.state.sha256
        $fabricatedCompletion.event_id=$fabricatedEventId
        Write-TestJson -Path $fabricatedCompletionPath -Value $fabricatedCompletion
        $fabricatedRetirement=$retirementDocument|ConvertTo-Json -Depth 32|ConvertFrom-Json
        $fabricatedRetirement.prepared_plan.container.path=$fabricatedPlanRelative
        $fabricatedRetirement.prepared_plan.container.sha256=(Get-FileHash $fabricatedPlanPath).Hash.ToLowerInvariant()
        $fabricatedRetirement.prepared_event.event_id=$fabricatedEventId
        $fabricatedRetirement.prepared_event.intent.path=$fabricatedIntentRelative
        $fabricatedRetirement.prepared_event.intent.sha256=(Get-FileHash $fabricatedIntentPath).Hash.ToLowerInvariant()
        $fabricatedRetirement.prepared_event.completion.path=$fabricatedCompletionRelative
        $fabricatedRetirement.prepared_event.completion.sha256=(Get-FileHash $fabricatedCompletionPath).Hash.ToLowerInvariant()
        Write-TestJson -Path $retirementInput -Value $fabricatedRetirement
        $fabricatedProvenanceRejected=$false
        $fabricatedProvenanceMessage=''
        try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$fabricatedProvenanceMessage=$_.Exception.Message;$fabricatedProvenanceRejected=$fabricatedProvenanceMessage-like'*absent, duplicated, or differs*'}
        Assert-Automation $fabricatedProvenanceRejected "prepared-push retirement fabricated-provenance rejection was not ledger membership: $fabricatedProvenanceMessage"
    }finally{
        Write-TestJson -Path $retirementInput -Value $retirementDocument
        Remove-Item -LiteralPath $fabricatedPlanPath,$fabricatedIntentPath,$fabricatedCompletionPath -Force -ErrorAction SilentlyContinue
    }

    $inputLease=& $retirementModule {param($path)Open-PreparedPushProtocolSnapshot $path '' 'lease-test'} $retirementInput
    $leaseBlockedOverwrite=$false
    try{
        try{[IO.File]::WriteAllText($retirementInput,'{"schema":"swapped"}',[Text.UTF8Encoding]::new($false))}catch{$leaseBlockedOverwrite=$true}
    }finally{$inputLease.stream.Dispose()}
    Write-TestJson -Path $retirementInput -Value $retirementDocument
    Assert-Automation $leaseBlockedOverwrite "prepared-push retirement retained-input lease allowed an in-place binding swap"

    $damagedRetirement=$retirementDocument|ConvertTo-Json -Depth 32|ConvertFrom-Json
    $damagedRetirement.repository_map_sha256='0'*64
    Write-TestJson -Path $retirementInput -Value $damagedRetirement
    $mapSwapRejected=$false
    try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$mapSwapRejected=$true}
    Assert-Automation $mapSwapRejected "prepared-push retirement accepted unbound repository-map bytes"
    $damagedRetirement=$retirementDocument|ConvertTo-Json -Depth 32|ConvertFrom-Json
    $damagedRetirement.observed_at='not-a-timestamp'
    Write-TestJson -Path $retirementInput -Value $damagedRetirement
    $observedAtRejected=$false
    try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$observedAtRejected=$true}
    Assert-Automation $observedAtRejected "prepared-push retirement accepted an invalid observed_at timestamp"
    Write-TestJson -Path $retirementInput -Value $retirementDocument

    $gitOverrideRejected=$false
    try{
        $env:GIT_INDEX_FILE=Join-Path $testRoot 'hostile-retirement-index'
        try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$gitOverrideRejected=$true}
    }finally{Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue}
    Assert-Automation $gitOverrideRejected "prepared-push retirement accepted a Git environment override"

    $repoGitDir=[string](@(Invoke-TestGit -Path $repo -Arguments @('rev-parse','--absolute-git-dir'))[0])
    $replaceSource=[string](@(Invoke-TestGit -Path $repo -Arguments @('rev-parse','HEAD'))[0])
    $replaceTarget=[string](@(Invoke-TestGit -Path $repo -Arguments @('rev-parse','HEAD^'))[0])
    $graftsPath=Join-Path $repoGitDir 'info\grafts'
    $shallowPath=Join-Path $repoGitDir 'shallow'
    $alternatesPath=Join-Path $repoGitDir 'objects\info\alternates'
    foreach($graphCase in @(
        @{name='replacement ref';setup={Invoke-TestGit -Path $repo -Arguments @('replace',$replaceSource,$replaceTarget)|Out-Null};cleanup={Invoke-TestGit -Path $repo -Arguments @('replace','-d',$replaceSource)|Out-Null}},
        @{name='legacy graft';setup={[IO.File]::WriteAllText($graftsPath,"$replaceSource $replaceTarget`n",$encoding)};cleanup={Remove-Item -LiteralPath $graftsPath -Force -ErrorAction SilentlyContinue}},
        @{name='shallow history';setup={[IO.File]::WriteAllText($shallowPath,"$replaceTarget`n",$encoding)};cleanup={Remove-Item -LiteralPath $shallowPath -Force -ErrorAction SilentlyContinue}},
        @{name='object alternate';setup={[IO.File]::WriteAllText($alternatesPath,"$(Join-Path $remote 'objects')`n",$encoding)};cleanup={Remove-Item -LiteralPath $alternatesPath -Force -ErrorAction SilentlyContinue}}
    )){
        $graphRejected=$false
        try{
            & $graphCase.setup
            try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$graphRejected=$true}
        }finally{& $graphCase.cleanup}
        Assert-Automation $graphRejected "prepared-push retirement accepted $($graphCase.name)"
    }

    $damagedRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $damagedRetirement.bundle_id = "wrong-bundle"
    Write-TestJson -Path $retirementInput -Value $damagedRetirement
    $wrongBundleRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $wrongBundleRejected = $_.Exception.Message -like "*bundle identity mismatch*" }
    Assert-Automation $wrongBundleRejected "prepared-push retirement accepted a mismatched bundle"

    $damagedRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $damagedRetirement.repositories = @($damagedRetirement.repositories[0])
    Write-TestJson -Path $retirementInput -Value $damagedRetirement
    $partialCoverageRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $partialCoverageRejected = $_.Exception.Message -like "*coverage is incomplete*" }
    Assert-Automation $partialCoverageRejected "prepared-push retirement accepted partial repository coverage"

    $damagedRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $damagedRetirement.repositories[0].remote_readback_revision = "0000000000000000000000000000000000000000"
    Write-TestJson -Path $retirementInput -Value $damagedRetirement
    $staleObservationRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $staleObservationRejected = $_.Exception.Message -like "*stale or mismatched*" }
    Assert-Automation $staleObservationRejected "prepared-push retirement accepted stale remote observation"

    $conflictingPath = Join-Path $receiptRoot "conflicting-executed-push.json"
    $conflictingRepoRelative = [IO.Path]::GetRelativePath($planningRepo, $conflictingPath).Replace("\","/")
    [IO.File]::AppendAllText((Join-Path $planningRepo ".git\info\exclude"), "$conflictingRepoRelative`n", $encoding)
    Write-TestJson -Path $conflictingPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.executed_push_receipt.v1"; bundle_id = [string]$prepared.push_plan.bundle_id })
    Write-TestJson -Path $retirementInput -Value $retirementDocument
    $executionEvidenceRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $executionEvidenceRejected = $_.Exception.Message -like "*execution/publication evidence*" }
    Assert-Automation $executionEvidenceRejected "prepared-push retirement ignored bound execution evidence"
    Remove-Item -LiteralPath $conflictingPath

    foreach($schemaName in @("rusty.morphospace.workflow.prepared_publication_reconstruction.v1","rusty.morphospace.workflow.prepared_push_retirement.v1")){
        $schemaSlug=($schemaName-split"\.")[-2]-replace"_","-"
        $competingPath=Join-Path $receiptRoot "competing-$schemaSlug.json"
        $competingRepoRelative=[IO.Path]::GetRelativePath($planningRepo,$competingPath).Replace("\","/")
        [IO.File]::AppendAllText((Join-Path $planningRepo ".git\info\exclude"),"$competingRepoRelative`n",$encoding)
        Write-TestJson -Path $competingPath -Value ([ordered]@{schema=$schemaName;bundle_id=[string]$prepared.push_plan.bundle_id})
        $competingRejected=$false
        try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$competingRejected=$true}
        Assert-Automation $competingRejected "prepared-push retirement accepted competing $schemaName evidence"
        Remove-Item -LiteralPath $competingPath
    }
    foreach($actionName in @("ReconcilePreparedPublication","RetirePreparedPush")){
        $actionSlug=($actionName-replace"([a-z])([A-Z])",'$1-$2').ToLowerInvariant()
        $competingPath=Join-Path $receiptRoot "competing-$actionSlug.json"
        $competingRepoRelative=[IO.Path]::GetRelativePath($planningRepo,$competingPath).Replace("\","/")
        [IO.File]::AppendAllText((Join-Path $planningRepo ".git\info\exclude"),"$competingRepoRelative`n",$encoding)
        Write-TestJson -Path $competingPath -Value ([ordered]@{schema="rusty.morphospace.workflow.work_unit_automation_receipt.v2";action=$actionName;audit_receipt=[ordered]@{bundle_id=[string]$prepared.push_plan.bundle_id}})
        $competingRejected=$false
        try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$competingRejected=$true}
        Assert-Automation $competingRejected "prepared-push retirement accepted competing $actionName automation evidence"
        Remove-Item -LiteralPath $competingPath
    }

    $retirementLedgerPath=Join-Path $workspace "iteration-events.jsonl"
    $retirementLedgerBytes=[IO.File]::ReadAllBytes($retirementLedgerPath)
    $retirementAppendPrefix=if($retirementLedgerBytes.Length-and$retirementLedgerBytes[-1]-ne0x0a){"`n"}else{""}
    $retirementLedgerEvents=@(Get-Content -LiteralPath $retirementLedgerPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
    $retirementNextSequence=[int]$retirementLedgerEvents[-1].sequence+1
    $missingReceiptsEvent=[ordered]@{schema="rusty.morphospace.workflow.iteration_event.v1";event_id="unit-auto-001-missing-receipts";sequence=$retirementNextSequence;timestamp=$fixed;project_id="automation-test";unit_id="unit-auto-001";event_type="decision";summary="Malformed missing receipts fixture."}
    [IO.File]::AppendAllText($retirementLedgerPath,($retirementAppendPrefix+($missingReceiptsEvent|ConvertTo-Json -Depth 10 -Compress)+"`n"),$encoding)
    Write-TestJson -Path $retirementInput -Value $retirementDocument
    $missingReceiptsRejected=$false
    try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$missingReceiptsRejected=$true}
    Assert-Automation $missingReceiptsRejected "prepared-push retirement accepted an event without a receipts property"
    [IO.File]::WriteAllBytes($retirementLedgerPath,$retirementLedgerBytes)

    $unboundPushEvent=[ordered]@{schema="rusty.morphospace.workflow.iteration_event.v1";event_id="unit-auto-001-unbound-push";sequence=$retirementNextSequence;timestamp=$fixed;project_id="automation-test";unit_id="unit-auto-001";event_type="push";summary="Unbound push fixture.";receipts=@()}
    [IO.File]::AppendAllText($retirementLedgerPath,($retirementAppendPrefix+($unboundPushEvent|ConvertTo-Json -Depth 10 -Compress)+"`n"),$encoding)
    $unboundPushRejected=$false
    try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$unboundPushRejected=$true}
    Assert-Automation $unboundPushRejected "prepared-push retirement accepted a push event without evidence"
    [IO.File]::WriteAllBytes($retirementLedgerPath,$retirementLedgerBytes)

    $unresolvedEvent=[ordered]@{schema="rusty.morphospace.workflow.iteration_event.v1";event_id="unit-auto-001-unresolved-evidence";sequence=$retirementNextSequence;timestamp=$fixed;project_id="automation-test";unit_id="unit-auto-001";event_type="decision";summary="Unresolved event evidence fixture.";receipts=@("event-evidence/missing.json")}
    [IO.File]::AppendAllText($retirementLedgerPath,($retirementAppendPrefix+($unresolvedEvent|ConvertTo-Json -Depth 10 -Compress)+"`n"),$encoding)
    $unresolvedEventRejected=$false
    try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$unresolvedEventRejected=$true}
    Assert-Automation $unresolvedEventRejected "prepared-push retirement accepted an unresolved non-push event receipt"
    [IO.File]::WriteAllBytes($retirementLedgerPath,$retirementLedgerBytes)

    $eventEvidenceRelative="event-evidence/non-push-publication.json"
    $eventEvidencePath=Join-Path $workspace ($eventEvidenceRelative-replace"/","\")
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($eventEvidencePath))|Out-Null
    Write-TestJson -Path $eventEvidencePath -Value ([ordered]@{schema="rusty.morphospace.workflow.executed_push_receipt.v1";bundle_id=[string]$prepared.push_plan.bundle_id})
    $nonPushBoundEvent=[ordered]@{schema="rusty.morphospace.workflow.iteration_event.v1";event_id="unit-auto-001-non-push-publication";sequence=$retirementNextSequence;timestamp=$fixed;project_id="automation-test";unit_id="unit-auto-001";event_type="decision";summary="Non-push bound publication fixture.";receipts=@($eventEvidenceRelative)}
    [IO.File]::AppendAllText($retirementLedgerPath,($retirementAppendPrefix+($nonPushBoundEvent|ConvertTo-Json -Depth 10 -Compress)+"`n"),$encoding)
    $nonPushBoundRejected=$false
    try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed|Out-Null}catch{$nonPushBoundRejected=$true}
    Assert-Automation $nonPushBoundRejected "prepared-push retirement ignored bundle-bound publication evidence on a non-push event"
    [IO.File]::WriteAllBytes($retirementLedgerPath,$retirementLedgerBytes)
    Remove-Item -LiteralPath (Join-Path $workspace "event-evidence") -Recurse -Force

    Invoke-TestGit -Path $repo -Arguments @("push", "origin", "main") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("fetch", "origin") | Out-Null
    $planningRemoteBefore = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "origin/main"))[0]
    Invoke-TestGit -Path $planningRepo -Arguments @("push", "origin", "main") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("fetch", "origin") | Out-Null
    $publishedPrepared = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $publishedSourceObservation = @($publishedPrepared.repositories | Where-Object { [string]$_.repo_id -eq "project-shell" })[0]
    $publishedSourceObservation.remote_readback_revision = $localHead
    $publishedSourceObservation.ahead = 0
    $publishedPlanningObservation = @($publishedPrepared.repositories | Where-Object { [string]$_.repo_id -eq "workflow-planning" })[0]
    $publishedPlanningObservation.remote_readback_revision = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "origin/main"))[0]
    $publishedPlanningObservation.ahead = 0
    Write-TestJson -Path $retirementInput -Value $publishedPrepared
    $reachablePreparedRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $reachablePreparedRejected = $_.Exception.Message -like "*requires at least one distinct prepared revision*" }
    Assert-Automation $reachablePreparedRejected "prepared-push retirement became an alternate accounting path for a remotely reachable prepared revision"

    # Build an uncontaminated real RecordValidation -> Accept -> PreparePush
    # chain. The primary fixture above intentionally injected legacy state
    # between transitions and is not valid continuity evidence.
    $reconstructionProjectId="ar"
    $reconstructionUnitId="ur"
    $reconstructionPlanningRemote=Join-Path $testRoot "rpr.git"
    $reconstructionPlanningRepo=Join-Path $testRoot "rp"
    & git init --bare --quiet $reconstructionPlanningRemote
    & git init --quiet -b main $reconstructionPlanningRepo
    Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("config","user.name","Automation Test")|Out-Null
    Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("config","user.email","automation@example.invalid")|Out-Null
    Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("remote","add","origin",$reconstructionPlanningRemote)|Out-Null
    [IO.File]::WriteAllText((Join-Path $reconstructionPlanningRepo "seed.txt"),"seed`n",$encoding)
    Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("add","seed.txt")|Out-Null
    Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("commit","-m","seed")|Out-Null
    Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("push","-u","origin","main")|Out-Null
    $reconstructionRepoMapPath=Join-Path $testRoot "rm.json"
    Write-TestJson -Path $reconstructionRepoMapPath -Value ([ordered]@{schema="rusty.morphospace.workflow.repository_map.v1";repositories=@(
        [ordered]@{repo_id="project-shell";path=$repo;role="source"},
        [ordered]@{repo_id="workflow-planning";path=$reconstructionPlanningRepo;role="planning"}
    )})
    $reconstructionWorkspace=New-TestWorkspace -Root (Join-Path $reconstructionPlanningRepo "rr") -ProjectId $reconstructionProjectId -UnitId $reconstructionUnitId
    Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $reconstructionWorkspace -UnitId $reconstructionUnitId -RepoMapPath $reconstructionRepoMapPath -Timestamp $fixed -Execute|Out-Null
    $reconstructionBegin=Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $reconstructionWorkspace -UnitId $reconstructionUnitId -RepoMapPath $reconstructionRepoMapPath -Timestamp $fixed -Execute
    $reconstructionHead=@(Invoke-TestGit -Path $repo -Arguments @("rev-parse","HEAD"))[0]
    $reconstructionBranch=@(Invoke-TestGit -Path $repo -Arguments @("branch","--show-current"))[0]
    $reconstructionValidationPath=New-TestValidationReceipt -Workspace $reconstructionWorkspace -ProjectId $reconstructionProjectId -UnitId $reconstructionUnitId -Tier deep -Result pass -RepositoryRevisions @([ordered]@{repo_id="project-shell";base_revision=$reconstructionHead;head_revision=$reconstructionHead;branch=$reconstructionBranch})
    $reconstructionRecord=Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $reconstructionWorkspace -UnitId $reconstructionUnitId -RepoMapPath $reconstructionRepoMapPath -ValidationTier deep -ValidationResult pass -ValidationReceipt "receipts/$reconstructionUnitId-pass-validation.json" -Timestamp $fixed -Execute
    $reconstructionAccepted=Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $reconstructionWorkspace -UnitId $reconstructionUnitId -RepoMapPath $reconstructionRepoMapPath -Timestamp $fixed -Execute
    $reconstructionMidState=Read-MorphospaceProtocolJson (Join-Path $reconstructionWorkspace "workspace.state.json")
    $reconstructionMidUnit=Read-MorphospaceProtocolJson (Join-Path $reconstructionWorkspace "iteration-units\$reconstructionUnitId.json")
    $reconstructionMidEvents=@(Get-Content -LiteralPath (Join-Path $reconstructionWorkspace "iteration-events.jsonl")|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
    $reconstructionMidSequence=[int]$reconstructionMidEvents[-1].sequence+1
    $reconstructionMidEventId="$reconstructionUnitId-continuity-probe-$('{0:d4}'-f$reconstructionMidSequence)"
    $reconstructionMidTarget=$reconstructionMidState|ConvertTo-Json -Depth 32|ConvertFrom-Json
    $reconstructionMidTarget.last_event_id=$reconstructionMidEventId
    $reconstructionMidEvent=[pscustomobject][ordered]@{schema="rusty.morphospace.workflow.iteration_event.v1";event_id=$reconstructionMidEventId;sequence=$reconstructionMidSequence;timestamp=$fixed;project_id=$reconstructionProjectId;unit_id=$reconstructionUnitId;event_type="state-transition";summary="Synthetic fully ledgered continuity probe.";receipts=@()}
    $reconstructionMidArgs=@{WorkspaceRoot=$reconstructionWorkspace;TransactionId="$reconstructionMidEventId-transition";StatePath="workspace.state.json";UnitPath="iteration-units/$reconstructionUnitId.json";EventsPath="iteration-events.jsonl";TargetState=$reconstructionMidTarget;TargetUnit=$reconstructionMidUnit;Event=$reconstructionMidEvent;ExpectedStateSha256=(Get-MorphospaceCanonicalJsonSha256 $reconstructionMidState);ExpectedUnitSha256=(Get-MorphospaceCanonicalJsonSha256 $reconstructionMidUnit);ExpectedEventTailId=([string]$reconstructionAccepted.event_id)}
    & $transitionLedgerModule {param($arguments) Start-MorphospaceTransitionLedger @arguments} $reconstructionMidArgs|Out-Null
    $reconstructionRevisionsPath=Join-Path $testRoot "real-reconstruction-revisions.json"
    Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("add","rr")|Out-Null
    Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("commit","-m","real reconstruction planning state")|Out-Null
    $reconstructionPlanningHead=@(Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("rev-parse","HEAD"))[0]
    Write-TestJson -Path $reconstructionRevisionsPath -Value ([ordered]@{schema="rusty.morphospace.workflow.revision_set.v1";repositories=@(
        [ordered]@{repo_id="project-shell";commit=$reconstructionHead},
        [ordered]@{repo_id="workflow-planning";commit=$reconstructionPlanningHead}
    )})
    $reconstructionPrepared=Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $reconstructionWorkspace -UnitId $reconstructionUnitId -RepoMapPath $reconstructionRepoMapPath -RevisionsPath $reconstructionRevisionsPath -Timestamp $fixed -OutPath (Join-Path $reconstructionWorkspace "receipts\p.json") -Execute
    Invoke-TestGit -Path $reconstructionPlanningRepo -Arguments @("push","origin","main")|Out-Null
    $reconstructionStatePath=Join-Path $reconstructionWorkspace "workspace.state.json"
    $reconstructionState=Read-MorphospaceProtocolJson $reconstructionStatePath
    $reconstructionState.blockers=@($reconstructionState.blockers)+@($staleBlocker)
    Write-TestJson -Path $reconstructionStatePath -Value $reconstructionState

    # The real chain must be accepted by reconstruction when observed through
    # independent clean readback clones.
    $sourceReadback = Join-Path $testRoot "sr"
    $planningReadback = Join-Path $testRoot "pr"
    Invoke-TestGit -Path $testRoot -Arguments @("-c", "core.autocrlf=false", "clone", "--quiet", "--branch", "main", $remote, $sourceReadback) | Out-Null
    Invoke-TestGit -Path $testRoot -Arguments @("-c", "core.autocrlf=false", "clone", "--quiet", "--branch", "main", $reconstructionPlanningRemote, $planningReadback) | Out-Null
    $reconstructionMapPath = Join-Path $testRoot "repository-map-real-reconstruction.json"
    Write-TestJson -Path $reconstructionMapPath -Value ([ordered]@{
        schema = "rusty.morphospace.workflow.repository_map.v1"
        repositories = @(
            [ordered]@{ repo_id = "project-shell"; path = $sourceReadback; role = "source"; aliases = @() },
            [ordered]@{ repo_id = "workflow-planning"; path = $planningReadback; role = "planning"; aliases = @() }
        )
    })
    Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceProtocolCommon.psm1") -Force
    $realReconstructionState = Get-Content -Raw $reconstructionStatePath | ConvertFrom-Json
    $realUnitRelative = "iteration-units/$reconstructionUnitId.json"
    $realValidationRelative = [IO.Path]::GetRelativePath($reconstructionWorkspace, $reconstructionValidationPath).Replace("\","/")
    $realValidationIntentRelative = "receipts/transactions/$([string]$reconstructionRecord.event_id)-transition.intent.json"
    $realValidationCompletionRelative = "receipts/transactions/$([string]$reconstructionRecord.event_id)-transition.completion.json"
    $realAcceptanceIntentRelative = "receipts/transactions/$([string]$reconstructionAccepted.event_id)-transition.intent.json"
    $realAcceptanceCompletionRelative = "receipts/transactions/$([string]$reconstructionAccepted.event_id)-transition.completion.json"
    $realFileBinding = {
        param([string]$Relative)
        $absolute = Join-Path $reconstructionWorkspace ($Relative -replace "/","\")
        [ordered]@{ path = $Relative; sha256 = (Get-FileHash $absolute).Hash.ToLowerInvariant() }
    }
    $realLogicalLegs = @()
    $realPhysicalRefs = @()
    foreach($planRepository in @($reconstructionPrepared.push_plan.repositories)){
        $repoId = [string]$planRepository.repo_id
        $readback = if($repoId -eq "project-shell"){$sourceReadback}else{$planningReadback}
        $physicalId = "$repoId-main-readback"
        $tip = @(Invoke-TestGit -Path $readback -Arguments @("rev-parse","HEAD"))[0]
        $preparedRevision = [string]$planRepository.commit
        $historyIds = @((@(Invoke-TestGit -Path $readback -Arguments @("rev-list","--reverse","$preparedRevision..$tip")) -join "`n") -split "`n" | Where-Object { $_ })
        $history = @($historyIds | ForEach-Object {
            $revision = [string]$_
            [ordered]@{
                revision = $revision
                parents = @(((@(Invoke-TestGit -Path $readback -Arguments @("show","-s","--format=%P",$revision)) -join "") -split " ") | Where-Object { $_ })
                tree = (@(Invoke-TestGit -Path $readback -Arguments @("show","-s","--format=%T",$revision)) -join "")
                changed_paths = @(((@(Invoke-TestGit -Path $readback -Arguments @("diff-tree","--no-commit-id","--name-only","-r","--root",$revision)) -join "`n") -split "`n" | Where-Object { $_ } | Sort-Object -Unique))
            }
        })
        $realLogicalLegs += [ordered]@{ repo_id=$repoId; role=[string]$planRepository.role; physical_ref_id=$physicalId; prepared_revision=$preparedRevision }
        $realPhysicalRefs += [ordered]@{
            physical_ref_id=$physicalId; observation_repo_id=$repoId; logical_repo_ids=@($repoId)
            remote="origin"; ref="refs/heads/main"; branch="main"; upstream="origin/main"
            remote_fetch_identity=& $reconstructionModule {param($repo) Get-ReconstructionRemoteIdentity $repo "origin"} $readback
            remote_push_identity=& $reconstructionModule {param($repo) Get-ReconstructionRemoteIdentity $repo "origin" -Push} $readback
            prepared_revision=$preparedRevision
            prepared_tree=(@(Invoke-TestGit -Path $readback -Arguments @("show","-s","--format=%T",$preparedRevision)) -join "")
            remote_tip_revision=$tip
            remote_tip_tree=(@(Invoke-TestGit -Path $readback -Arguments @("show","-s","--format=%T",$tip)) -join "")
            ancestor_or_equal=$true; history=$history
        }
    }
    $reconstructionPreparedEventId=[string]$reconstructionPrepared.event_id
    $reconstructionPreparedIntentRelative="receipts/transactions/$reconstructionPreparedEventId-transition.intent.json"
    $reconstructionPreparedCompletionRelative="receipts/transactions/$reconstructionPreparedEventId-transition.completion.json"
    $reconstructionMidIntentRelative="receipts/transactions/$reconstructionMidEventId-transition.intent.json"
    $reconstructionMidCompletionRelative="receipts/transactions/$reconstructionMidEventId-transition.completion.json"
    $realReconstructionDocument = [ordered]@{
        schema="rusty.morphospace.workflow.prepared_publication_reconstruction.v1"
        reconstruction_id="rr";project_id=$reconstructionProjectId
        bundle_id=[string]$reconstructionPrepared.push_plan.bundle_id;unit_ids=@($reconstructionUnitId)
        repository_map_sha256=(Get-FileHash $reconstructionMapPath).Hash.ToLowerInvariant()
        prepared_plan=[ordered]@{container=&$realFileBinding "receipts/p.json";member="push_plan"}
        prepared_event=[ordered]@{event_id=$reconstructionPreparedEventId;intent=&$realFileBinding $reconstructionPreparedIntentRelative;completion=&$realFileBinding $reconstructionPreparedCompletionRelative;member="event"}
        accepted_unit=&$realFileBinding $realUnitRelative
        validation_receipt=&$realFileBinding $realValidationRelative
        validation_predecessor=[ordered]@{event_id=[string]$reconstructionBegin.event_id;intent=&$realFileBinding "receipts/transactions/$([string]$reconstructionBegin.event_id)-transition.intent.json";completion=&$realFileBinding "receipts/transactions/$([string]$reconstructionBegin.event_id)-transition.completion.json"}
        validation_event=[ordered]@{event_id=[string]$reconstructionRecord.event_id;intent=&$realFileBinding $realValidationIntentRelative;completion=&$realFileBinding $realValidationCompletionRelative}
        acceptance_event=[ordered]@{event_id=[string]$reconstructionAccepted.event_id;intent=&$realFileBinding $realAcceptanceIntentRelative;completion=&$realFileBinding $realAcceptanceCompletionRelative}
        intervening_transitions=@([ordered]@{event_id=$reconstructionMidEventId;intent=&$realFileBinding $reconstructionMidIntentRelative;completion=&$realFileBinding $reconstructionMidCompletionRelative})
        pending_bundle=[ordered]@{value=$realReconstructionState.pending_push_bundle;sha256=Get-MorphospaceCanonicalJsonSha256 $realReconstructionState.pending_push_bundle}
        stale_blocker=[ordered]@{value=$staleBlocker;sha256=Get-MorphospaceCanonicalJsonSha256 $staleBlocker}
        active_workspace_observation=[ordered]@{evidentiary=$false;repositories=@()}
        logical_legs=$realLogicalLegs;physical_refs=$realPhysicalRefs
        conflicting_evidence=[ordered]@{executed_push_receipt_present=$false;planned_accounting_present=$false;unplanned_closure_present=$false}
        claims=[ordered]@{original_plan_execution=$false;cross_repository_execution_or_publication_order=$false;source_first_planning_last_execution=$false;force_or_no_force_history=$false;publication_actor_or_timestamp=$false;historical_nonpublication_or_impossibility=$false;original_not_performed_preserved=$true}
        mutation=[ordered]@{pending_bundle_consumed=$true;blocker_consumed=$true}
    }
    $realReconstructionInput = Join-Path $testRoot "real-prepared-publication-reconstruction.json"
    Write-TestJson -Path $realReconstructionInput -Value $realReconstructionDocument
    $realReconstructionDryRun = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action ReconcilePreparedPublication -WorkspaceRoot $reconstructionWorkspace `
        -UnitId $reconstructionUnitId -RepoMapPath $reconstructionMapPath -PreparedPublicationReconstruction $realReconstructionInput -Timestamp $fixed | ConvertFrom-Json
    Assert-Automation ($realReconstructionDryRun.transition -eq "prepared-publication-reconstructed" -and -not $realReconstructionDryRun.executed) "real RecordValidation/Accept/PreparePush provenance did not pass prepared-publication reconstruction"

    $realPreparedPlanPath=Join-Path $reconstructionWorkspace "receipts\p.json"
    $realPreparedPlanBytes=[IO.File]::ReadAllBytes($realPreparedPlanPath)
    $realSubstitutedPlanBytes=[byte[]]::new($realPreparedPlanBytes.Length+1)
    $realSubstitutedPlanBytes[0]=0x20
    [Array]::Copy($realPreparedPlanBytes,0,$realSubstitutedPlanBytes,1,$realPreparedPlanBytes.Length)
    try{
        [IO.File]::WriteAllBytes($realPreparedPlanPath,$realSubstitutedPlanBytes)
        $realSubstitutedPlanDocument=$realReconstructionDocument|ConvertTo-Json -Depth 40|ConvertFrom-Json
        $realSubstitutedPlanDocument.prepared_plan.container.sha256=(Get-FileHash $realPreparedPlanPath).Hash.ToLowerInvariant()
        Write-TestJson -Path $realReconstructionInput -Value $realSubstitutedPlanDocument
        $realSubstitutedPlanRejected=$false;$realSubstitutedPlanMessage=''
        try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action ReconcilePreparedPublication -WorkspaceRoot $reconstructionWorkspace -UnitId $reconstructionUnitId -RepoMapPath $reconstructionMapPath -PreparedPublicationReconstruction $realReconstructionInput -Timestamp $fixed|Out-Null}catch{$realSubstitutedPlanMessage=$_.Exception.Message;$realSubstitutedPlanRejected=$realSubstitutedPlanMessage-like'*transaction-owned preparation artifact*'}
        Assert-Automation $realSubstitutedPlanRejected "reconstruction accepted byte-substituted real PreparePush owner: $realSubstitutedPlanMessage"
    }finally{
        [IO.File]::WriteAllBytes($realPreparedPlanPath,$realPreparedPlanBytes)
        Write-TestJson -Path $realReconstructionInput -Value $realReconstructionDocument
    }

    $omittedIntervening=$realReconstructionDocument|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $omittedIntervening.intervening_transitions=@()
    Write-TestJson -Path $realReconstructionInput -Value $omittedIntervening
    $omittedInterveningRejected=$false
    try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action ReconcilePreparedPublication -WorkspaceRoot $reconstructionWorkspace -UnitId $reconstructionUnitId -RepoMapPath $reconstructionMapPath -PreparedPublicationReconstruction $realReconstructionInput -Timestamp $fixed|Out-Null}catch{$omittedInterveningRejected=$true}
    Assert-Automation $omittedInterveningRejected "reconstruction accepted an omitted intervening transition"

    $substitutedIntervening=$realReconstructionDocument|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $substitutedIntervening.intervening_transitions=@($substitutedIntervening.acceptance_event)
    Write-TestJson -Path $realReconstructionInput -Value $substitutedIntervening
    $substitutedInterveningRejected=$false
    try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action ReconcilePreparedPublication -WorkspaceRoot $reconstructionWorkspace -UnitId $reconstructionUnitId -RepoMapPath $reconstructionMapPath -PreparedPublicationReconstruction $realReconstructionInput -Timestamp $fixed|Out-Null}catch{$substitutedInterveningRejected=$true}
    Assert-Automation $substitutedInterveningRejected "reconstruction accepted a substituted real intervening transition"

    $realValidationIntentPath=Join-Path $reconstructionWorkspace ($realValidationIntentRelative-replace"/","\")
    $realValidationCompletionPath=Join-Path $reconstructionWorkspace ($realValidationCompletionRelative-replace"/","\")
    $originalValidationIntentBytes=[IO.File]::ReadAllBytes($realValidationIntentPath)
    $originalValidationCompletionBytes=[IO.File]::ReadAllBytes($realValidationCompletionPath)
    try{
        $damagedValidationIntent=Get-Content -Raw -LiteralPath $realValidationIntentPath|ConvertFrom-Json
        $damagedValidationIntent.pre.state.sha256='0'*64
        $damagedValidationIntent.expected.state_sha256='0'*64
        Write-TestJson -Path $realValidationIntentPath -Value $damagedValidationIntent
        $damagedValidationCompletion=Get-Content -Raw -LiteralPath $realValidationCompletionPath|ConvertFrom-Json
        $damagedValidationCompletion.intent.sha256=(Get-FileHash $realValidationIntentPath).Hash.ToLowerInvariant()
        Write-TestJson -Path $realValidationCompletionPath -Value $damagedValidationCompletion
        $disconnectedPredecessor=$realReconstructionDocument|ConvertTo-Json -Depth 40|ConvertFrom-Json
        $disconnectedPredecessor.validation_event.intent.sha256=(Get-FileHash $realValidationIntentPath).Hash.ToLowerInvariant()
        $disconnectedPredecessor.validation_event.completion.sha256=(Get-FileHash $realValidationCompletionPath).Hash.ToLowerInvariant()
        Write-TestJson -Path $realReconstructionInput -Value $disconnectedPredecessor
        $disconnectedPredecessorRejected=$false
        try{& (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action ReconcilePreparedPublication -WorkspaceRoot $reconstructionWorkspace -UnitId $reconstructionUnitId -RepoMapPath $reconstructionMapPath -PreparedPublicationReconstruction $realReconstructionInput -Timestamp $fixed|Out-Null}catch{$disconnectedPredecessorRejected=$true}
        Assert-Automation $disconnectedPredecessorRejected "reconstruction accepted validation disconnected from its real predecessor completion"
    }finally{
        [IO.File]::WriteAllBytes($realValidationIntentPath,$originalValidationIntentBytes)
        [IO.File]::WriteAllBytes($realValidationCompletionPath,$originalValidationCompletionBytes)
    }
    Write-TestJson -Path $realReconstructionInput -Value $realReconstructionDocument

    Invoke-TestGit -Path $remote -Arguments @("update-ref", "refs/heads/main", $remoteBefore) | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("fetch", "origin") | Out-Null
    Invoke-TestGit -Path $planningRemote -Arguments @("update-ref", "refs/heads/main", $planningRemoteBefore) | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("fetch", "origin") | Out-Null
    Write-TestJson -Path $retirementInput -Value $retirementDocument

    $mismatchedBlockerRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $mismatchedBlockerRetirement.mutation.blocker_id = "unrelated-auto-blocker"
    Write-TestJson -Path $retirementInput -Value $mismatchedBlockerRetirement
    $mismatchedBlockerRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $mismatchedBlockerRejected = $_.Exception.Message -like "*blocker identity mismatch*" }
    Assert-Automation $mismatchedBlockerRejected "prepared-push retirement accepted a non-null blocker ID different from the canonical stale blocker"

    $nullPlanningRepo = Join-Path $testRoot "planning-null-retirement"
    Invoke-TestGit -Path $testRoot -Arguments @("-c", "core.autocrlf=false", "clone", "--quiet", "--branch", "main", $planningRepo, $nullPlanningRepo) | Out-Null
    $workspaceRelative = [IO.Path]::GetRelativePath($planningRepo, $workspace)
    $nullWorkspace = Join-Path $nullPlanningRepo $workspaceRelative
    $nullRepoMapPath = Join-Path $testRoot "repository-map-null-retirement.json"
    $nullRepoMap = Get-Content -Raw $repoMapPath | ConvertFrom-Json
    (@($nullRepoMap.repositories | Where-Object { [string]$_.repo_id -eq "workflow-planning" }))[0].path = $nullPlanningRepo
    Write-TestJson -Path $nullRepoMapPath -Value $nullRepoMap
    $nullRetirement = $retirementDocument | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $nullRetirement.mutation.blocker_id = $null
    $nullRetirement.repositories = @($prepared.push_plan.repositories | ForEach-Object {
        $path = if ([string]$_.repo_id -eq "project-shell") { $repo } else { $nullPlanningRepo }
        $head = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "HEAD"))[0]
        $upstream = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"))[0]
        $remoteName = @(Invoke-TestGit -Path $path -Arguments @("config", "--get", "branch.$([string]$_.branch).remote"))[0]
        $remoteFetchIdentity = & $retirementModule {param($root,$remote)Get-PreparedPushRemoteIdentity $root $remote} $path $remoteName
        $remotePushIdentity = & $retirementModule {param($root,$remote)Get-PreparedPushRemoteIdentity $root $remote -Push} $path $remoteName
        $remoteRevision = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "@{upstream}"))[0]
        $counts = (@(Invoke-TestGit -Path $path -Arguments @("rev-list", "--left-right", "--count", "HEAD...@{upstream}"))[0] -split "\s+")
        [ordered]@{
            repo_id = [string]$_.repo_id; role = [string]$_.role; branch = [string]$_.branch; upstream = $upstream
            prepared_revision = @(Invoke-TestGit -Path $path -Arguments @("rev-parse", "$([string]$_.commit)^{commit}"))[0]
            local_head = $head; remote_readback_revision = $remoteRevision; worktree_clean = $true
            detached = $false; ahead = [int]$counts[0]; behind = [int]$counts[1]; diverged = $false
            remote_fetch_identity = $remoteFetchIdentity; remote_push_identity = $remotePushIdentity
        }
    })
    $nullRetirementInput = Join-Path $testRoot "prepared-push-retirement-null-input.json"
    $nullRetirementOutput = Join-Path $nullWorkspace "receipts\prepared-push-retirement-null.json"
    $nullRetirement.repository_map_sha256 = (Get-FileHash $nullRepoMapPath).Hash.ToLowerInvariant()
    Write-TestJson -Path $nullRetirementInput -Value $nullRetirement
    $nullRetired = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $nullWorkspace `
        -UnitId "unit-auto-001" -RepoMapPath $nullRepoMapPath -PreparedPushRetirement $nullRetirementInput -Timestamp $fixed `
        -OutPath $nullRetirementOutput -Execute | ConvertFrom-Json
    $nullRetiredState = Get-Content -Raw (Join-Path $nullWorkspace "workspace.state.json") | ConvertFrom-Json
    Assert-Automation ($nullRetired.executed -and $null-eq$nullRetiredState.pending_push_bundle) "null-blocker retirement did not consume the pending bundle"
    Assert-Automation (@($nullRetiredState.blockers | Where-Object blocker_id -eq "stale-auto-push-plan").Count -eq 1) "null-blocker retirement removed the canonically observed stale blocker"
    Assert-Automation (@($nullRetiredState.blockers | Where-Object blocker_id -eq "unrelated-auto-blocker").Count -eq 1) "null-blocker retirement removed an unrelated blocker"
    Write-TestJson -Path $retirementInput -Value $retirementDocument

    $faultBaselineState=[IO.File]::ReadAllBytes((Join-Path $workspace "workspace.state.json"))
    $faultBaselineUnit=[IO.File]::ReadAllBytes((Join-Path $workspace "iteration-units\unit-auto-001.json"))
    $faultBaselineEvents=[IO.File]::ReadAllBytes((Join-Path $workspace "iteration-events.jsonl"))
    foreach($retirementFault in @("after-intent","after-artifact","after-projection","after-event")){
        $faultOutput=Join-Path $workspace "receipts\prepared-push-retirement.json"
        $faultInterrupted=$false
        $faultEventId=$null
        $laterEventId=$null
        try{
            try{
                Invoke-MorphospacePreparedPushRetirement -WorkspaceRoot $workspace -UnitId "unit-auto-001" `
                    -RepoMapPath $repoMapPath -RetirementReceipt $retirementInput -Timestamp $fixed `
                    -OutPath $faultOutput -Execute -FaultAfter $retirementFault | Out-Null
            }catch{$faultInterrupted=$_.Exception.Message-like"*Injected interruption*"}
            Assert-Automation $faultInterrupted "prepared-push retirement did not stop at $retirementFault"
            $faultRecovered=Invoke-MorphospacePreparedPushRetirement -WorkspaceRoot $workspace -UnitId "unit-auto-001" `
                -RepoMapPath $repoMapPath -RetirementReceipt $retirementInput -Timestamp $fixed `
                -OutPath $faultOutput -Execute
            $faultEventId=[string]$faultRecovered.event_id
            $faultState=Get-Content -Raw (Join-Path $workspace "workspace.state.json")|ConvertFrom-Json
            $faultEvents=@(Get-Content (Join-Path $workspace "iteration-events.jsonl")|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
            $faultRetirementEvents=@($faultEvents|Where-Object{[string]$_.event_id-ceq$faultEventId})
            Assert-Automation ($faultRecovered.executed-and
                $faultRetirementEvents.Count-eq1-and
                $null-eq$faultState.pending_push_bundle-and
                -not($faultState.PSObject.Properties.Name-contains"prepared_push_retirements")-and
                (Get-FileHash $faultOutput).Hash-ceq(Get-FileHash $retirementInput).Hash
            ) "prepared-push retirement $retirementFault retry did not repair exactly once"
            $faultIdempotent=Invoke-MorphospacePreparedPushRetirement -WorkspaceRoot $workspace -UnitId "unit-auto-001" `
                -RepoMapPath $repoMapPath -RetirementReceipt $retirementInput -Timestamp $fixed `
                -OutPath $faultOutput -Execute
            Assert-Automation ([string]$faultIdempotent.event_id-ceq$faultEventId) "prepared-push retirement $retirementFault immediate retry was not idempotent"
            if($retirementFault-eq"after-event"){
                $laterState=Get-Content -Raw (Join-Path $workspace "workspace.state.json")|ConvertFrom-Json
                $laterUnit=Get-Content -Raw (Join-Path $workspace "iteration-units\unit-auto-001.json")|ConvertFrom-Json
                $laterSequence=$faultEvents.Count+1
                $laterEventId="unit-auto-001-retirement-later-$('{0:d4}'-f$laterSequence)"
                $laterEvent=[pscustomobject][ordered]@{
                    schema="rusty.morphospace.workflow.iteration_event.v1";event_id=$laterEventId;sequence=$laterSequence
                    timestamp=$fixed;project_id="automation-test";unit_id="unit-auto-001";event_type="state-transition"
                    summary="Legitimate later transition used to prove historical retirement idempotence.";receipts=@()
                }
                $laterState.last_event_id=$laterEventId
                Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceTransitionLedger.psm1") -Force
                Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$laterEventId-transition" `
                    -StatePath "workspace.state.json" -UnitPath "iteration-units/unit-auto-001.json" -EventsPath "iteration-events.jsonl" `
                    -TargetState $laterState -TargetUnit $laterUnit -Event $laterEvent -ExpectedEventTailId $faultEventId|Out-Null
                $historicalRetry=Invoke-MorphospacePreparedPushRetirement -WorkspaceRoot $workspace -UnitId "unit-auto-001" `
                    -RepoMapPath $repoMapPath -RetirementReceipt $retirementInput -Timestamp $fixed `
                    -OutPath $faultOutput -Execute
                Assert-Automation ([string]$historicalRetry.event_id-ceq$faultEventId-and
                    @(Get-Content (Join-Path $workspace "iteration-events.jsonl")|Where-Object{$_}).Count-eq$laterSequence
                ) "historical committed retirement retry did not authenticate after a later transition"
            }
        }finally{
            [IO.File]::WriteAllBytes((Join-Path $workspace "workspace.state.json"),$faultBaselineState)
            [IO.File]::WriteAllBytes((Join-Path $workspace "iteration-units\unit-auto-001.json"),$faultBaselineUnit)
            [IO.File]::WriteAllBytes((Join-Path $workspace "iteration-events.jsonl"),$faultBaselineEvents)
            $cleanupPaths=@($faultOutput)
            if($faultEventId){
                $cleanupPaths+=@(
                    (Join-Path $workspace "receipts\transactions\$faultEventId-transition.intent.json"),
                    (Join-Path $workspace "receipts\transactions\$faultEventId-transition.completion.json"),
                    (Join-Path $workspace "receipts\transactions\$faultEventId-transition.artifact-0.pending")
                )
            }
            if($laterEventId){
                $cleanupPaths+=@(
                    (Join-Path $workspace "receipts\transactions\$laterEventId-transition.intent.json"),
                    (Join-Path $workspace "receipts\transactions\$laterEventId-transition.completion.json")
                )
            }
            foreach($cleanupPath in $cleanupPaths){if([IO.File]::Exists($cleanupPath)){Remove-Item -LiteralPath $cleanupPath -Force}}
        }
    }

    $retired = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace `
        -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed `
        -OutPath $retirementOutput -Execute | ConvertFrom-Json
    $retiredState = Get-Content -Raw (Join-Path $workspace "workspace.state.json") | ConvertFrom-Json
    Assert-Automation ($retired.executed -and $retired.event_id -like "*prepared-push-retired*" -and $null -eq $retiredState.pending_push_bundle) "prepared-push retirement did not consume exactly one pending bundle"
    Assert-Automation ((-not ($retiredState.PSObject.Properties.Name -contains "prepared_push_retirements")) -and
        (Test-Path $retirementOutput) -and
        (Get-FileHash $retirementOutput).Hash-ceq(Get-FileHash $retirementInput).Hash-and
        @($retiredState.blockers | Where-Object blocker_id -eq "stale-auto-push-plan").Count -eq 0) "prepared-push retirement receipt was not retained byte-for-byte, transaction-owned, or exact blocker was not removed"
    Assert-Automation (@($retiredState.blockers | Where-Object blocker_id -eq "unrelated-auto-blocker").Count -eq 1) "prepared-push retirement removed an unrelated blocker"
    $repeatRejected = $false
    try { & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action RetirePreparedPush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -PreparedPushRetirement $retirementInput -Timestamp $fixed | Out-Null } catch { $repeatRejected = $_.Exception.Message -like "*already consumed*" }
    Assert-Automation $repeatRejected "prepared-push retirement permitted repeated consumption"

    $orderingInterruptionPath = Join-Path $receiptRoot "publication-ordering-interruption.json"
    Write-TestJson -Path $orderingInterruptionPath -Value ([ordered]@{
        schema = "rusty.morphospace.workflow.publication_ordering_interruption.v1"; project_id = "automation-test"; unit_id = "unit-auto-001"
        kind = "planning-published-before-source"; observed_at = $fixed
        planning = [ordered]@{ repo_id = "workflow-planning"; early_remote_revision = (@(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "@{upstream}"))[0]); local_prepared_revision = $planningHead }
        sources = @([ordered]@{ repo_id = "project-shell"; unpublished_remote_revision = $remoteBefore; local_revision = $localHead })
        does_not_claim = @("planning-last chronology", "source publication", "executed push", "publication accounting", "recorded publication")
    })
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "preserve publication ordering interruption") | Out-Null
    $planningRecoveryHead = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "HEAD"))[0]
    Write-TestJson -Path $revisionsPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.revision_set.v1"; repositories = @(
        [ordered]@{ repo_id = "project-shell"; commit = $localHead },
        [ordered]@{ repo_id = "workflow-planning"; commit = $planningRecoveryHead }
    ) })
    $recoveredPlan = Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -RevisionsPath $revisionsPath -PublicationOrderingInterruption "receipts/publication-ordering-interruption.json" -Timestamp $fixed -OutPath (Join-Path $receiptRoot "recovered-push-plan.json")
    Assert-Automation ($recoveredPlan.push_plan.publication_ordering_interruption.early_planning_checkpoint_preserved -and -not $recoveredPlan.push_plan.publication_ordering_interruption.source_publication_claimed) "fresh plan did not preserve the early-planning ordering fault"
    $damagedInterruption = Get-Content -Raw $orderingInterruptionPath | ConvertFrom-Json
    $damagedInterruption.sources[0].unpublished_remote_revision = "0000000000000000000000000000000000000000"
    Write-TestJson -Path $orderingInterruptionPath -Value $damagedInterruption
    Invoke-TestGit -Path $planningRepo -Arguments @("add", ".") | Out-Null
    Invoke-TestGit -Path $planningRepo -Arguments @("commit", "-m", "damage publication ordering interruption fixture") | Out-Null
    $planningDamagedHead = @(Invoke-TestGit -Path $planningRepo -Arguments @("rev-parse", "HEAD"))[0]
    Write-TestJson -Path $revisionsPath -Value ([ordered]@{ schema = "rusty.morphospace.workflow.revision_set.v1"; repositories = @(
        [ordered]@{ repo_id = "project-shell"; commit = $localHead },
        [ordered]@{ repo_id = "workflow-planning"; commit = $planningDamagedHead }
    ) })
    $damagedOrderingRejected = $false
    try { Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -RevisionsPath $revisionsPath -PublicationOrderingInterruption "receipts/publication-ordering-interruption.json" -Timestamp $fixed | Out-Null } catch { $damagedOrderingRejected = $_.Exception.Message -like "Publication-ordering interruption source refs do not match*" }
    Assert-Automation $damagedOrderingRejected "damaged unpublished source readback was accepted"

    & git clone --quiet --branch main $remote $peer 2>$null | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("config", "user.name", "Automation Peer") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("config", "user.email", "peer@example.invalid") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("config", "core.autocrlf", "false") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("switch", "main") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $peer "peer.txt"), "peer`n", $encoding)
    Invoke-TestGit -Path $peer -Arguments @("add", "peer.txt") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("commit", "-m", "peer") | Out-Null
    Invoke-TestGit -Path $peer -Arguments @("push", "origin", "main") | Out-Null
    Invoke-TestGit -Path $repo -Arguments @("fetch", "origin") | Out-Null
    $divergedBefore = (Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--branch")) -join "`n"
    $blockedPush = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId "unit-auto-001" -RepoMapPath $repoMapPath -RevisionsPath $revisionsPath -Timestamp $fixed -OutPath (Join-Path $receiptRoot "must-not-exist.json") -Execute | Out-Null
    } catch {
        $blockedPush = $_.Exception.Message -like "Push preparation refused unsafe repo*"
    }
    Assert-Automation $blockedPush "divergent push preparation was not refused"
    Assert-Automation ($divergedBefore -eq ((Invoke-TestGit -Path $repo -Arguments @("status", "--porcelain=v1", "--branch")) -join "`n")) "divergent repo was rewritten"

    $recoveryWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "recovery-project") -ProjectId "recovery-test" -UnitId "unit-recover-001"
    $recoveryStatePath = Join-Path $recoveryWorkspace "workspace.state.json"
    $initialRecoveryState = Get-Content $recoveryStatePath -Raw | ConvertFrom-Json
    $initialRecoveryState.dirty_repositories = @("project-shell")
    Write-TestJson -Path $recoveryStatePath -Value $initialRecoveryState
    $recoveryClaim = Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute
    Assert-Automation ($recoveryClaim.claim_preflight.ready_to_claim -and [string]$recoveryClaim.claim_preflight.writable_repositories[0].head -match '^[0-9a-f]{40}$') "mapped recovery claim lacks exact preflight evidence"
    Assert-Automation (@((Get-Content $recoveryStatePath -Raw | ConvertFrom-Json).dirty_repositories) -notcontains "project-shell") "mapped clean repository was not projected deterministically"
    Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -Timestamp $fixed -Execute | Out-Null
    $failureReceiptPath = New-TestValidationReceipt -Workspace $recoveryWorkspace -ProjectId "recovery-test" -UnitId "unit-recover-001" -Tier standard -Result fail -EvidenceName "failure-evidence.txt"
    Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -ValidationTier standard -ValidationResult fail -ValidationReceipt "receipts/unit-recover-001-fail-validation.json" -Timestamp $fixed -Execute | Out-Null
    $blockedState = Get-Content (Join-Path $recoveryWorkspace "workspace.state.json") -Raw | ConvertFrom-Json
    Assert-Automation ($blockedState.blockers.Count -eq 1 -and $null -eq $blockedState.current_unit) "failed validation did not persist blocker"
    Invoke-MorphospaceWorkUnitAutomation -Action Resume -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -Timestamp $fixed -Execute | Out-Null
    $resumedState = Get-Content (Join-Path $recoveryWorkspace "workspace.state.json") -Raw | ConvertFrom-Json
    Assert-Automation ($resumedState.blockers.Count -eq 1) "resume discarded blocker history"

    $returnWorkspace = New-TestWorkspace -Root (Join-Path $testRoot "validation-return-project") -ProjectId "validation-return-test" -UnitId "unit-return-001"
    Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $returnWorkspace -UnitId "unit-return-001" -RepoMapPath $repoMapPath -Timestamp $fixed -Execute | Out-Null
    Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $returnWorkspace -UnitId "unit-return-001" -Timestamp $fixed -Execute | Out-Null
    New-TestValidationReceipt -Workspace $returnWorkspace -ProjectId "validation-return-test" -UnitId "unit-return-001" -Tier standard -Result fail -EvidenceName "return-failure-evidence.txt" | Out-Null
    $passReturnRejected = $false
    try {
        Invoke-MorphospaceWorkUnitAutomation -Action ReturnToActive -WorkspaceRoot $returnWorkspace -UnitId "unit-return-001" -ValidationTier standard -ValidationResult pass -ValidationReceipt "receipts/unit-return-001-fail-validation.json" -Timestamp $fixed | Out-Null
    } catch { $passReturnRejected = $_.Exception.Message -like "ReturnToActive requires a non-passing*" }
    Assert-Automation $passReturnRejected "ReturnToActive accepted a passing result"
    $returnReceiptPath = Join-Path $returnWorkspace "receipts\return-to-active.json"
    $returned = & (Join-Path $PSScriptRoot "Invoke-WorkUnitAutomation.ps1") -Action ReturnToActive -WorkspaceRoot $returnWorkspace -UnitId "unit-return-001" -ValidationTier standard -ValidationResult fail -ValidationReceipt "receipts/unit-return-001-fail-validation.json" -Timestamp $fixed -OutPath $returnReceiptPath -Execute | ConvertFrom-Json
    $returnedState = Get-Content (Join-Path $returnWorkspace "workspace.state.json") -Raw | ConvertFrom-Json
    Assert-Automation ($returned.transition -eq "validation-fail-to-active" -and $returned.status_after -eq "active" -and [string]$returnedState.current_unit -eq "unit-return-001" -and @($returnedState.blockers).Count -eq 0) "non-passing validation did not return the same feature unit to active"
    Assert-Automation ([string]$returnedState.validation_checkpoint.receipt -eq "receipts/unit-return-001-fail-validation.json" -and [string]$returnedState.validation_checkpoint.result -eq "fail") "ReturnToActive did not retain the failed validation checkpoint"
    Assert-Automation (Test-Json -Json (Get-Content -LiteralPath $returnReceiptPath -Raw) -SchemaFile (Join-Path $RepoRoot "schemas\work-unit-automation-receipt.schema.json")) "ReturnToActive receipt failed its schema"
    $resumedState.current_unit = $null
    Write-TestJson -Path (Join-Path $recoveryWorkspace "workspace.state.json") -Value $resumedState
    $recovered = Invoke-MorphospaceWorkUnitAutomation -Action Recover -WorkspaceRoot $recoveryWorkspace -UnitId "unit-recover-001" -Timestamp $fixed -Execute
    Assert-Automation ($recovered.transition -eq "restore-current-unit" -and [string]$recovered.current_unit_after -eq "unit-recover-001") "interrupted recovery"

    $interruptionCases = @(
        [ordered]@{ kind = "partial-cross-repo-commit"; project = "partial-recovery-test"; unit = "unit-partial-001" },
        [ordered]@{ kind = "interrupted-build"; project = "build-recovery-test"; unit = "unit-build-001" },
        [ordered]@{ kind = "interrupted-device"; project = "device-recovery-test"; unit = "unit-device-001" }
    )
    foreach ($case in $interruptionCases) {
        $caseWorkspace = New-TestWorkspace -Root (Join-Path $testRoot $case.project) -ProjectId $case.project -UnitId $case.unit
        $caseUnitPath = Join-Path $caseWorkspace "iteration-units\$($case.unit).json"
        $caseUnit = Get-Content -LiteralPath $caseUnitPath -Raw | ConvertFrom-Json
        $caseUnit.status = "active"
        if ($case.kind -eq "partial-cross-repo-commit") {
            $caseUnit.allowed_repositories = @($caseUnit.allowed_repositories) + [pscustomobject][ordered]@{ repo_id = "planning-surface"; allowed_paths = @("workspaces/") }
            $caseSpecPath = Join-Path $caseWorkspace "project.spec.json"
            $caseSpec = Get-Content -LiteralPath $caseSpecPath -Raw | ConvertFrom-Json
            $caseSpec.repositories = @($caseSpec.repositories) + [pscustomobject][ordered]@{ repo_id = "planning-surface"; role = "planning"; path = "<planning>"; allowed_paths = @("workspaces/") }
            Write-TestJson -Path $caseSpecPath -Value $caseSpec
        }
        Write-TestJson -Path $caseUnitPath -Value $caseUnit
        $caseStatePath = Join-Path $caseWorkspace "workspace.state.json"
        $caseState = Get-Content -LiteralPath $caseStatePath -Raw | ConvertFrom-Json
        $caseState.current_unit = $null; $caseState.next_ready_unit = $null
        $caseState.blockers = @([pscustomobject][ordered]@{
            blocker_id = "$($case.unit)-interrupted"
            condition = "Interrupted $($case.kind) requires structured cleanup evidence."
            resume_when = "A typed recovery receipt proves safe cleanup."
        })
        Write-TestJson -Path $caseStatePath -Value $caseState

        $missingRecoveryRejected = $false
        try { Invoke-MorphospaceWorkUnitAutomation -Action Recover -WorkspaceRoot $caseWorkspace -UnitId $case.unit -RepoMapPath $repoMapPath -Timestamp $fixed | Out-Null }
        catch { $missingRecoveryRejected = $_.Exception.Message -eq "Interrupted work requires a typed recovery receipt before state restoration." }
        Assert-Automation $missingRecoveryRejected "$($case.kind) recovered without a typed receipt"
        $currentRevision = @(Invoke-TestGit -Path $repo -Arguments @("rev-parse", "HEAD"))[0]
        New-TestInterruptionReceipt -Workspace $caseWorkspace -ProjectId $case.project -UnitId $case.unit -Kind $case.kind -Revision $currentRevision -Safe $false -Cleanup $false | Out-Null
        $unsafeRecoveryRejected = $false
        try { Invoke-MorphospaceWorkUnitAutomation -Action Recover -WorkspaceRoot $caseWorkspace -UnitId $case.unit -RepoMapPath $repoMapPath -RecoveryReceipt "receipts/$($case.unit)-$($case.kind)-recovery.json" -Timestamp $fixed | Out-Null }
        catch { $unsafeRecoveryRejected = $_.Exception.Message -eq "Recovery receipt does not prove safe, complete cleanup." }
        Assert-Automation $unsafeRecoveryRejected "$($case.kind) accepted incomplete cleanup"
        New-TestInterruptionReceipt -Workspace $caseWorkspace -ProjectId $case.project -UnitId $case.unit -Kind $case.kind -Revision $currentRevision | Out-Null
        $safeRecovery = Invoke-MorphospaceWorkUnitAutomation -Action Recover -WorkspaceRoot $caseWorkspace -UnitId $case.unit -RepoMapPath $repoMapPath -RecoveryReceipt "receipts/$($case.unit)-$($case.kind)-recovery.json" -Timestamp $fixed -Execute
        Assert-Automation ($safeRecovery.transition -eq "restore-current-unit" -and [string]$safeRecovery.current_unit_after -eq [string]$case.unit) "$($case.kind) safe recovery"
        Assert-Automation ($safeRecovery.preservation.git_mutation_performed -eq $false -and $safeRecovery.preservation.device_mutation_performed -eq $false) "$($case.kind) recovery mutated external state"
        & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $caseWorkspace -SkipOwnerSelfTests
    }

    $supersessionWorkspace = New-TestWorkspace `
        -Root (Join-Path $testRoot "supersession-test") `
        -ProjectId "supersession-test" `
        -UnitId "old-unit"
    $oldUnitPath = Join-Path $supersessionWorkspace "iteration-units\old-unit.json"
    $oldUnit = Get-Content -LiteralPath $oldUnitPath -Raw | ConvertFrom-Json
    $oldUnit.status = "active"
    Write-TestJson -Path $oldUnitPath -Value $oldUnit
    $currentUnit = New-TestUnit -ProjectId "supersession-test" -UnitId "current-unit"
    $currentUnit.status = "validating"
    $currentUnit.prerequisites = @("old-unit")
    Write-TestJson -Path (Join-Path $supersessionWorkspace "iteration-units\current-unit.json") -Value $currentUnit
    $supersessionEvent = [ordered]@{
        schema = "rusty.morphospace.workflow.iteration_event.v1"
        event_id = "old-unit-superseded-by-current-unit"
        sequence = 1
        timestamp = "2026-01-02T03:04:05Z"
        project_id = "supersession-test"
        unit_id = "old-unit"
        event_type = "state-transition"
        summary = "The corrective current unit additively supersedes immutable historical in-flight state."
        receipts = @()
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $supersessionWorkspace "iteration-events.jsonl"),
        (($supersessionEvent | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $encoding
    )
    $supersessionStatePath = Join-Path $supersessionWorkspace "workspace.state.json"
    $supersessionState = Get-Content -LiteralPath $supersessionStatePath -Raw | ConvertFrom-Json
    $supersessionState.current_unit = "current-unit"
    $supersessionState.next_ready_unit = $null
    $supersessionState.last_event_id = "old-unit-superseded-by-current-unit"
    Write-TestJson -Path $supersessionStatePath -Value $supersessionState
    & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $supersessionWorkspace -SkipOwnerSelfTests

    $supersessionEvent.event_type = "validation"
    [System.IO.File]::WriteAllText(
        (Join-Path $supersessionWorkspace "iteration-events.jsonl"),
        (($supersessionEvent | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $encoding
    )
    $damagedSupersessionRejected = $false
    try {
        & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $supersessionWorkspace -SkipOwnerSelfTests
    } catch {
        $damagedSupersessionRejected = $_.Exception.Message -like "Workflow contract validation failed*"
    }
    Assert-Automation $damagedSupersessionRejected "supersession accepted a non-state-transition event"

    $supersessionEvent.event_type = "state-transition"
    $supersessionEvent.event_id = "old-unit-superseded-by-injected-superseded-by-current-unit"
    [System.IO.File]::WriteAllText(
        (Join-Path $supersessionWorkspace "iteration-events.jsonl"),
        (($supersessionEvent | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $encoding
    )
    $supersessionState.last_event_id = [string]$supersessionEvent.event_id
    Write-TestJson -Path $supersessionStatePath -Value $supersessionState
    $ambiguousSupersessionRejected = $false
    try {
        & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $supersessionWorkspace -SkipOwnerSelfTests
    } catch {
        $ambiguousSupersessionRejected = $_.Exception.Message -like "Workflow contract validation failed*"
    }
    Assert-Automation $ambiguousSupersessionRejected "supersession validator accepted an ambiguous repeated delimiter"

    $supersessionEvent.event_id = "counterfeit-old-unit-superseded-by-current-unit"
    [System.IO.File]::WriteAllText(
        (Join-Path $supersessionWorkspace "iteration-events.jsonl"),
        (($supersessionEvent | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $encoding
    )
    $supersessionState.last_event_id = [string]$supersessionEvent.event_id
    Write-TestJson -Path $supersessionStatePath -Value $supersessionState
    $damagedEndpointRejected = $false
    try {
        & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $supersessionWorkspace -SkipOwnerSelfTests
    } catch {
        $damagedEndpointRejected = $_.Exception.Message -like "Workflow contract validation failed*"
    }
    Assert-Automation $damagedEndpointRejected "supersession validator inferred a damaged old endpoint from the event ID"

    & (Join-Path $PSScriptRoot "Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -WorkspaceRoot $recoveryWorkspace -SkipOwnerSelfTests
    Write-Host "Work-unit automation self-test passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        if (-not $resolved.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a test directory outside the system temporary directory."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
