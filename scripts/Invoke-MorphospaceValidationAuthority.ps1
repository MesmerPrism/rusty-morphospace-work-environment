param(
    [Parameter(Mandatory = $true)][ValidateSet('Inspect', 'Preflight', 'Validate')][string]$Action,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$UnitId,
    [Parameter(Mandatory = $true)][string]$RegistryPath,
    [Parameter(Mandatory = $true)][string]$RepositoryMapPath,
    [Parameter(Mandatory = $true)][string]$CurrentProtocolPath,
    [Parameter(Mandatory = $true)][string]$TrustMigrationPath,
    [Parameter(Mandatory = $true)][string]$ClaimBaselinePath,
    [Parameter(Mandatory = $true)][string]$OwnershipPath,
    [Parameter(Mandatory = $true)][string]$ValidationActionPath,
    [string]$ExecutionNonce = '',
    [string]$EvidencePath,
    [string]$OutPath
)

$ErrorActionPreference = 'Stop'
$warningPreferenceBeforeImports = $WarningPreference
try {
    $WarningPreference = 'SilentlyContinue'
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceOwnership.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceAuthorityReadiness.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
} finally {
    $WarningPreference = $warningPreferenceBeforeImports
}

$script:AuthorityReportContext = $null
$script:AuthorityStage = 'context-load'
$script:AuthorityStartedAt = [DateTime]::UtcNow
$script:AuthorityCapsuleSha256 = ''
$script:AuthorityRunnerReleaseSha256 = ''

trap {
    $failurePath = ''
    if ($null -ne $script:AuthorityReportContext) {
        try {
            $failure = Write-MorphospaceAuthorityFailureReport -Context $script:AuthorityReportContext -Stage $script:AuthorityStage -ErrorRecord $_ -StartedAt $script:AuthorityStartedAt -CapsuleSha256 $script:AuthorityCapsuleSha256 -RunnerReleaseSha256 $script:AuthorityRunnerReleaseSha256
            $failurePath = [string]$script:AuthorityReportContext.failure_report
            if (-not (Test-Path -LiteralPath $script:AuthorityReportContext.stage_result -PathType Leaf)) {
                Write-MorphospaceAuthorityStageResult -Context $script:AuthorityReportContext -Stage $script:AuthorityStage -Result fail -StartedAt $script:AuthorityStartedAt -CapsuleSha256 $script:AuthorityCapsuleSha256 -RunnerReleaseSha256 $script:AuthorityRunnerReleaseSha256 -FailureReportPath $failurePath | Out-Null
            }
        } catch {}
    }
    [Console]::Error.WriteLine("AUTHORITY_FAILURE stage=$script:AuthorityStage report=$failurePath message=$([string]$_.Exception.Message)")
    exit 1
}

function Get-MorphospaceAutomationWorkspacePath {
    param([Parameter(Mandatory = $true)][object]$Output, [Parameter(Mandatory = $true)][hashtable]$RepositoryMap, [Parameter(Mandatory = $true)][string]$Workspace)
    $repoId = [string]$Output.repo_id
    if (-not $RepositoryMap.ContainsKey($repoId)) { throw "Automation output repository is unavailable: $repoId" }
    $candidate = [IO.Path]::GetFullPath((Join-Path ([string]$RepositoryMap[$repoId].path) ([string]$Output.path)))
    $prefix = $Workspace.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Automation output is outside the workspace: $repoId/$([string]$Output.path)" }
    return $candidate
}

function Get-MorphospaceAutomationWorkspaceRelativePath {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$AbsolutePath)
    $root = [IO.Path]::GetFullPath($Workspace).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath($AbsolutePath)
    if (-not $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Automation output is outside the workspace: $AbsolutePath" }
    return $candidate.Substring($root.Length).Replace('\', '/')
}

function Get-MorphospaceReadinessOutput {
    param([object[]]$AutomationOutputs,[string]$Role,[hashtable]$RepositoryMap,[string]$Workspace)
    $rows=@($AutomationOutputs|Where-Object{[string]$_.phase-ceq'readiness'-and[string]$_.role-ceq$Role})
    if($rows.Count-ne1){throw "Readiness automation contract requires exactly one $Role output."}
    return Get-MorphospaceAutomationWorkspacePath -Output $rows[0] -RepositoryMap $RepositoryMap -Workspace $Workspace
}

function Get-MorphospaceReadinessReference {
    param([string]$Workspace,[string]$Path,[string]$Role,[string]$Schema)
    return Get-MorphospaceAuthorityReference -WorkspaceRoot $Workspace -Path $Path -Role $Role -Schema $Schema
}

function Invoke-MorphospaceIsolatedAuthoritySelfTest {
    param(
        [Parameter(Mandatory = $true)][object]$Migration,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 300
    )
    $artifacts = @($Migration.authority_artifacts | Where-Object { [string]$_.repo_id -ceq 'work-environment' -and [string]$_.path -ceq $RelativePath })
    if ($artifacts.Count -ne 1) { throw "Authority self-test is not uniquely pinned by the trust migration: $RelativePath" }
    $repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $path = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $RelativePath))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-MorphospaceAuthoritySha256 $path) -cne [string]$artifacts[0].sha256) { throw "Authority self-test bytes do not match the trust migration: $RelativePath" }
    $hostPath = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
    $captureRoot = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-authority-selftest-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($captureRoot) | Out-Null
    $stdoutPath = Join-Path $captureRoot 'stdout.txt'; $stderrPath = Join-Path $captureRoot 'stderr.txt'
    try {
        $process = Start-Process -FilePath $hostPath -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$path) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        try {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch {}; throw "Authority self-test timed out: $RelativePath" }
            $exitCode = [int]$process.ExitCode
        } finally { $process.Dispose() }
        $stdout = if ([IO.File]::Exists($stdoutPath)) { [IO.File]::ReadAllText($stdoutPath, [Text.UTF8Encoding]::new($false)) } else { '' }
        $stderr = if ([IO.File]::Exists($stderrPath)) { [IO.File]::ReadAllText($stderrPath, [Text.UTF8Encoding]::new($false)) } else { '' }
        if (([Text.Encoding]::UTF8.GetByteCount($stdout) + [Text.Encoding]::UTF8.GetByteCount($stderr)) -gt 1048576) { throw "Authority self-test output exceeded 1 MiB: $RelativePath" }
        if ($exitCode -ne 0) {
            $detail = ($stderr + "`n" + $stdout).Trim(); if ($detail.Length -gt 2048) { $detail = $detail.Substring($detail.Length - 2048) }
            throw "Authority self-test failed with exit code ${exitCode}: $RelativePath`n$detail"
        }
    } finally { if ([IO.Directory]::Exists($captureRoot)) { [IO.Directory]::Delete($captureRoot, $true) } }
}

function Assert-MorphospaceAuthorizedAction {
    param([Parameter(Mandatory = $true)][object]$ActionDocument, [Parameter(Mandatory = $true)][object]$Selection, [Parameter(Mandatory = $true)][object]$Unit, [Parameter(Mandatory = $true)][object[]]$AutomationOutputs)
    if ([string]$ActionDocument.schema -ne 'rusty.morphospace.workflow.validation_action.v2' -or [string]$ActionDocument.project_id -ne [string]$Unit.project_id -or [string]$ActionDocument.unit_id -ne [string]$Unit.unit_id -or [string]$ActionDocument.status -ne 'authorized' -or [string]$ActionDocument.profile_id -ne [string]$Selection.profile_id) { throw 'Validation action is not bound to the active unit and selected profile.' }
    if ([string]$Unit.device_requirement -eq 'none' -and $null -ne $ActionDocument.device_validation) { throw 'No-device unit validation action must not carry a device payload.' }
    $selected = @($Selection.validators | ForEach-Object { [pscustomobject]@{ validator_id = [string]$_.validator_id; registry_entry_sha256 = (Get-MorphospaceCanonicalJsonSha256 $_) } } | Sort-Object validator_id)
    $asserted = @($ActionDocument.selected_validators | Sort-Object validator_id)
    if ((Get-MorphospaceCanonicalJsonSha256 $asserted) -ne (Get-MorphospaceCanonicalJsonSha256 $selected)) { throw 'Validation action selected validators are not the exact registry selection.' }
    $expected = @($AutomationOutputs | Where-Object { [string]$_.phase -eq 'validation' } | Sort-Object repo_id,path)
    $assertedOutputs = @($ActionDocument.expected_outputs | Sort-Object repo_id,path)
    if ((Get-MorphospaceCanonicalJsonSha256 $assertedOutputs) -ne (Get-MorphospaceCanonicalJsonSha256 $expected)) { throw 'Validation action output set is not the exact ownership automation contract.' }
    $ownerOutputs = @($expected | Where-Object { [string]$_.role -eq 'owner-validation' })
    if ($ownerOutputs.Count -ne @($Selection.validators).Count -or @($ownerOutputs | Where-Object { [string]$_.validator_id -notin @($Selection.validators | ForEach-Object { [string]$_.validator_id }) }).Count -ne 0 -or @($expected | Where-Object { [string]$_.role -eq 'validation-evidence' }).Count -ne 1 -or @($expected | Where-Object { [string]$_.role -eq 'validation-execution' }).Count -ne 1 -or @($expected | Where-Object { [string]$_.role -eq 'validation-receipt' }).Count -ne 1) { throw 'Validation action automation contract does not cover the exact selected validators and execution outputs.' }
}

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$spec = Read-MorphospaceAuthorityJson (Join-Path $workspace 'project.spec.json')
$unitPath = Join-Path $workspace (Join-Path 'iteration-units' "$UnitId.json")
$unit = Read-MorphospaceAuthorityJson $unitPath
if ([string]$unit.unit_id -ne $UnitId -or [string]$unit.project_id -ne [string]$spec.project_id) { throw 'Unit identity does not match the workspace.' }
$actionAbsolute = Resolve-MorphospaceAuthorityPath $workspace $ValidationActionPath
$actionDocument = Read-MorphospaceAuthorityJson $actionAbsolute
if ($Action -ne 'Inspect') {
    $reportAction = if ($Action -eq 'Preflight') { 'preflight' } else { 'record' }
    $runIdentity = if ($ExecutionNonce) { $ExecutionNonce } else { [guid]::NewGuid().ToString('N') }
    $script:AuthorityReportContext = New-MorphospaceAuthorityReportContext -ProjectId ([string]$unit.project_id) -UnitId $UnitId -AttemptId ([string]$actionDocument.attempt_id) -Action $reportAction -RunIdentity $runIdentity
}
$map = Get-MorphospaceFixedRepositoryMap -WorkspaceRoot $workspace -RequiredRepositoryIds @($unit.allowed_repositories | ForEach-Object { [string]$_.repo_id })
$registryAbsolute = Resolve-MorphospaceAuthorityPath $workspace $RegistryPath
$registry = Read-MorphospaceAuthorityJson $registryAbsolute
Test-MorphospaceOwnerValidatorRegistry -Registry $registry -RepositoryMap $map.map | Out-Null
$protocolAbsolute = Resolve-MorphospaceAuthorityPath $workspace $CurrentProtocolPath
$protocol = Read-MorphospaceAuthorityJson $protocolAbsolute
if ([string]$protocol.project_id -ne [string]$unit.project_id -or [string]$protocol.unit_id -ne $UnitId -or [string]$protocol.status -ne 'active') { throw 'Current protocol does not bind the active unit.' }
$migration = Test-MorphospaceValidatorTrustAnchorMigration -WorkspaceRoot $workspace -MigrationPath $TrustMigrationPath -RegistryReference $protocol.registry -ExpectedProjectId ([string]$unit.project_id) -ExpectedUnitId $UnitId -RepositoryMap $map.map
$baseline = Read-MorphospaceAuthorityJson (Resolve-MorphospaceAuthorityPath $workspace $ClaimBaselinePath)
$ownershipAbsolute = Resolve-MorphospaceAuthorityPath $workspace $OwnershipPath
$ownership = Read-MorphospaceAuthorityJson $ownershipAbsolute
Test-MorphospaceClaimBaseline -Baseline $baseline -Unit $unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $map.map | Out-Null
$observation = Test-MorphospaceUnitOwnership -Ownership $ownership -ClaimBaseline $baseline -ClaimBaselineReference $protocol.claim_baseline -Unit $unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $map.map
$automationOutputs = @($observation.automation_outputs)
Test-MorphospaceAutomationOutputSet -AutomationOutputs $automationOutputs -RepositoryMap $map.map -Expected present -Phase 'bootstrap'
if ([string]$actionDocument.pre_observation_sha256 -ne [string]$observation.observation.sha256) { throw 'Validation action is not bound to the current ownership observation.' }
$selection = Get-MorphospaceRegistrySelection -Registry $registry -Unit $unit -RepositoryMap $map.map -AssertedProfileId ([string]$actionDocument.profile_id)
Assert-MorphospaceAuthorizedAction -ActionDocument $actionDocument -Selection $selection -Unit $unit -AutomationOutputs $automationOutputs
if ($Action -eq 'Inspect') { [pscustomobject][ordered]@{ action = 'Inspect'; project_id = $unit.project_id; unit_id = $UnitId; validators = @($selection.validators | ForEach-Object { $_.validator_id }); observation_sha256 = $observation.observation.sha256; trust_migration = $migration.migration_id } | ConvertTo-Json -Depth 20; exit 0 }

$script:AuthorityStage='output-collision'

$runnerReleasePath=Get-MorphospaceReadinessOutput $automationOutputs 'authority-runner-release' $map.map $workspace
$capsulePath=Get-MorphospaceReadinessOutput $automationOutputs 'authority-input-capsule' $map.map $workspace
$hostCapabilitiesPath=Get-MorphospaceReadinessOutput $automationOutputs 'authority-host-capabilities' $map.map $workspace
$preflightPath=Get-MorphospaceReadinessOutput $automationOutputs 'authority-preflight-result' $map.map $workspace
$actionReference=Get-MorphospaceReadinessReference $workspace $actionAbsolute 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'
$protocolReference=Get-MorphospaceReadinessReference $workspace $protocolAbsolute 'current-unit-protocol' 'rusty.morphospace.workflow.current_unit_protocol.v1'
$stateAbsolute=Join-Path $workspace 'workspace.state.json';$stateDocument=Read-MorphospaceAuthorityJson $stateAbsolute
$stateReference=Get-MorphospaceReadinessReference $workspace $stateAbsolute 'workspace-state' ([string]$stateDocument.schema)
$unitReference=Get-MorphospaceReadinessReference $workspace $unitPath 'iteration-unit' ([string]$unit.schema)
$capsuleReferences=@($protocol.registry,$protocol.trust_anchor_migration,$protocol.claim_baseline,$protocol.unit_ownership,$protocol.repository_map,$protocol.event_anchor,$protocolReference,$actionReference,$stateReference,$unitReference)
$validator=@($selection.validators)[0]
if(@($selection.validators).Count-ne1){throw 'The current readiness path requires exactly one selected owner validator.'}
$runnerRelease=New-MorphospaceAuthorityRunnerReleaseV1 -Migration $migration -RepositoryMap $map.map -RunnerPath $PSCommandPath
$script:AuthorityRunnerReleaseSha256=[string]$runnerRelease.content_sha256
$capsule=New-MorphospaceAuthorityInputCapsuleV1 -ProjectId ([string]$unit.project_id) -UnitId $UnitId -AttemptId ([string]$actionDocument.attempt_id) -References $capsuleReferences -Validator $validator -RunnerRelease $runnerRelease
$script:AuthorityCapsuleSha256=[string]$capsule.capsule_sha256

if($Action-eq'Preflight'){
    Test-MorphospaceAutomationOutputSet -AutomationOutputs $automationOutputs -RepositoryMap $map.map -Expected absent -Phase 'readiness'
    $script:AuthorityStage='host-probe'
    $hostCapabilities=Invoke-MorphospaceAuthorityHostProbe -RequiredCommands @('git.exe')
    Test-MorphospaceAuthorityHostCapabilitiesV1 $hostCapabilities @('git.exe')|Out-Null
    Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath (Get-MorphospaceAutomationWorkspaceRelativePath $workspace $runnerReleasePath) -Value $runnerRelease -NoOverwrite
    Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath (Get-MorphospaceAutomationWorkspaceRelativePath $workspace $hostCapabilitiesPath) -Value $hostCapabilities -NoOverwrite
    Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath (Get-MorphospaceAutomationWorkspaceRelativePath $workspace $capsulePath) -Value $capsule -NoOverwrite
    $runnerReference=Get-MorphospaceReadinessReference $workspace $runnerReleasePath 'authority-runner-release' 'rusty.morphospace.workflow.authority_runner_release.v1'
    $hostReference=Get-MorphospaceReadinessReference $workspace $hostCapabilitiesPath 'authority-host-capabilities' 'rusty.morphospace.workflow.authority_host_capabilities.v1'
    $capsuleReference=Get-MorphospaceReadinessReference $workspace $capsulePath 'authority-input-capsule' 'rusty.morphospace.workflow.authority_input_capsule.v1'
    $script:AuthorityStage='capsule-materialization'
    $cleanRoom=Open-MorphospaceContentAddressedCleanRoom -CapsuleSha256 ([string]$capsule.capsule_sha256) -MaterializedInputsSha256 ([string]$capsule.capsule_sha256);$ephemeral=$null
    if($null-eq$cleanRoom){$ephemeral=New-MorphospaceCleanRoom -Ownership $ownership -ClaimBaseline $baseline -RepositoryMap $map.map -InputClosure @($validator.input_closure) -HistoryBlobs @($validator.history_blobs) -AttemptId "$UnitId-$($actionDocument.attempt_id)-$([string]$validator.validator_id)";$cleanRoom=Save-MorphospaceContentAddressedCleanRoom -CleanRoom $ephemeral -CapsuleSha256 ([string]$capsule.capsule_sha256) -MaterializedInputsSha256 ([string]$capsule.capsule_sha256);$ephemeral=$null}
    try{
        $cleanBefore=Get-MorphospaceCleanRoomFingerprint $cleanRoom
        if($cleanBefore-cne[string]$cleanRoom.fingerprint_sha256){throw 'Content-addressed clean room does not match its sealed manifest.'}
        $script:AuthorityStage='sealed-validator-admission'
        $validatorPath=[IO.Path]::GetFullPath((Join-Path ([string]$cleanRoom.repositories[[string]$validator.owner_repo_id]) ([string]$validator.path)))
        if(-not(Test-Path -LiteralPath $validatorPath -PathType Leaf)-or(Get-MorphospaceAuthoritySha256 $validatorPath)-cne[string]$validator.sha256){throw "Clean-room validator bytes do not match the registry: $($validator.validator_id)"}
        $stagedProbeOut=Join-Path $script:AuthorityReportContext.root 'validator-probe.json'
        $planningRoot=[string]$cleanRoom.repositories['planning'];$questRoot=[string]$cleanRoom.repositories['quest'];$cleanWorkspace=Join-Path $planningRoot 'workspaces\morphospace-platform-iteration\morphospace';$cleanRoadmap=Join-Path $planningRoot 'agent-state\morphospace-autonomous-iteration-roadmap-2026-07-10.json'
        $run=Invoke-MorphospacePinnedValidator -ValidatorPath $validatorPath -Workspace $cleanWorkspace -Quest $questRoot -Roadmap $cleanRoadmap -Unit $UnitId -OwnerOut $stagedProbeOut -StdoutPath $script:AuthorityReportContext.stdout -StderrPath $script:AuthorityReportContext.stderr -TimeoutSeconds ([Math]::Min([int]$validator.timeout_seconds,60)) -ProbeOnly
        if(([Text.Encoding]::UTF8.GetByteCount([string]$run.stdout)+[Text.Encoding]::UTF8.GetByteCount([string]$run.stderr))-gt[int]$validator.max_output_bytes){throw "Validator output exceeded its registered limit: $($validator.validator_id)"}
        if((Get-MorphospaceCleanRoomFingerprint $cleanRoom)-cne$cleanBefore){throw "Validator modified its clean-room input closure: $($validator.validator_id)"}
        if(-not(Test-Path -LiteralPath $stagedProbeOut -PathType Leaf)){throw "Selected validator did not emit its admission probe: $($validator.validator_id)"}
        $probeDocument=Read-MorphospaceAuthorityJson $stagedProbeOut
        Test-MorphospaceOwnerValidatorAdmissionProbeV1 -Probe $probeDocument -Validator $validator -Unit $unit|Out-Null
        if($run.exit_code-ne0){throw "Sealed owner-validator admission probe did not pass: $($validator.validator_id)"}
        $validatorProbe=[pscustomobject][ordered]@{validator_id=[string]$validator.validator_id;status='pass';exit_code=[int]$run.exit_code;probe_schema=[string]$probeDocument.schema;probe_sha256=Get-MorphospaceAuthoritySha256 $stagedProbeOut;stdout_sha256=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=[string]$run.stdout});stderr_sha256=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=[string]$run.stderr})}
        $preflight=New-MorphospaceAuthorityPreflightV2 -ProjectId ([string]$unit.project_id) -UnitId $UnitId -AttemptId ([string]$actionDocument.attempt_id) -ActionReference $actionReference -CapsuleReference $capsuleReference -HostReference $hostReference -RunnerReleaseReference $runnerReference -ValidatorProbe $validatorProbe -CleanroomFingerprint $cleanBefore -CapsuleReused ([bool]$cleanRoom.reused)
        Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath (Get-MorphospaceAutomationWorkspaceRelativePath $workspace $preflightPath) -Value $preflight -NoOverwrite
        Test-MorphospaceAutomationOutputSet -AutomationOutputs $automationOutputs -RepositoryMap $map.map -Expected present -Phase 'readiness'
        Write-MorphospaceAuthorityStageResult -Context $script:AuthorityReportContext -Stage 'sealed-validator-admission' -Result pass -StartedAt $script:AuthorityStartedAt -CapsuleSha256 $script:AuthorityCapsuleSha256 -RunnerReleaseSha256 $script:AuthorityRunnerReleaseSha256|Out-Null
        [pscustomobject][ordered]@{action='Preflight';project_id=[string]$unit.project_id;unit_id=$UnitId;attempt_id=[string]$actionDocument.attempt_id;capsule_sha256=[string]$capsule.capsule_sha256;cleanroom_fingerprint_sha256=$cleanBefore;capsule_reused=[bool]$cleanRoom.reused;preflight_path=(Get-MorphospaceAutomationWorkspaceRelativePath $workspace $preflightPath);report_root=[string]$script:AuthorityReportContext.root;status='ready-for-record'}|ConvertTo-Json -Depth 20
        exit 0
    }finally{if($null-ne$cleanRoom){Close-MorphospaceContentAddressedCleanRoom $cleanRoom};if($null-ne$ephemeral){Remove-MorphospaceCleanRoom $ephemeral}}
}

$script:AuthorityStage='readiness-revalidation'
Test-MorphospaceAutomationOutputSet -AutomationOutputs $automationOutputs -RepositoryMap $map.map -Expected present -Phase 'readiness'
$storedRunner=Read-MorphospaceAuthorityJson $runnerReleasePath;Test-MorphospaceAuthorityRunnerReleaseV1 $storedRunner $map.map|Out-Null
if([string]$storedRunner.content_sha256-cne[string]$runnerRelease.content_sha256){throw 'Authority runner release changed after preflight.'}
$storedCapsule=Read-MorphospaceAuthorityJson $capsulePath;Test-MorphospaceAuthorityInputCapsuleV1 $storedCapsule|Out-Null
if([string]$storedCapsule.capsule_sha256-cne[string]$capsule.capsule_sha256){throw 'Authority input capsule changed after preflight.'}
$storedHost=Read-MorphospaceAuthorityJson $hostCapabilitiesPath;Test-MorphospaceAuthorityHostCapabilitiesV1 $storedHost @('git.exe')|Out-Null
$freshHost=Invoke-MorphospaceAuthorityHostProbe -RequiredCommands @('git.exe');Test-MorphospaceAuthorityHostCapabilitiesV1 $freshHost @('git.exe')|Out-Null
if([string]$freshHost.content_sha256-cne[string]$storedHost.content_sha256){throw 'Authority child-host capabilities changed after preflight.'}
$runnerReference=Get-MorphospaceReadinessReference $workspace $runnerReleasePath 'authority-runner-release' 'rusty.morphospace.workflow.authority_runner_release.v1';$capsuleReference=Get-MorphospaceReadinessReference $workspace $capsulePath 'authority-input-capsule' 'rusty.morphospace.workflow.authority_input_capsule.v1';$hostReference=Get-MorphospaceReadinessReference $workspace $hostCapabilitiesPath 'authority-host-capabilities' 'rusty.morphospace.workflow.authority_host_capabilities.v1'
$preflight=Read-MorphospaceAuthorityJson $preflightPath;Test-MorphospaceAuthorityPreflightV2 $preflight $actionReference $capsuleReference $hostReference $runnerReference ([string]$unit.project_id) $UnitId ([string]$actionDocument.attempt_id)|Out-Null
$cached=Open-MorphospaceContentAddressedCleanRoom -CapsuleSha256 ([string]$capsule.capsule_sha256) -MaterializedInputsSha256 ([string]$capsule.capsule_sha256)
if($null-eq$cached){throw 'Passing preflight has no reusable content-addressed clean-room capsule.'}
try{if((Get-MorphospaceCleanRoomFingerprint $cached)-cne[string]$preflight.cleanroom_fingerprint_sha256){throw 'Cached clean-room manifest changed after preflight.'}}finally{Close-MorphospaceContentAddressedCleanRoom $cached}

if (-not $EvidencePath -or -not $OutPath) { throw 'Validate requires EvidencePath and OutPath.' }
if ($ExecutionNonce -notmatch '^[0-9a-f]{64}$') { throw 'Validate requires an authority-generated 32-byte execution nonce.' }
$script:AuthorityStage='record-self-tests'
Invoke-MorphospaceIsolatedAuthoritySelfTest -Migration $migration -RelativePath 'scripts/Test-ValidationAuthorityLauncher.ps1'
Invoke-MorphospaceIsolatedAuthoritySelfTest -Migration $migration -RelativePath 'scripts/Test-AuthorityRunnerHandoff.ps1'
Invoke-MorphospaceIsolatedAuthoritySelfTest -Migration $migration -RelativePath 'scripts/Test-TrustMigrationAuthority.ps1'
$evidenceAbsolute = Resolve-MorphospaceAuthorityPath $workspace $EvidencePath
$receiptAbsolute = Resolve-MorphospaceAuthorityPath $workspace $OutPath
$evidenceOutput = @($automationOutputs | Where-Object { [string]$_.phase -eq 'validation' -and [string]$_.role -eq 'validation-evidence' })
$executionOutput = @($automationOutputs | Where-Object { [string]$_.phase -eq 'validation' -and [string]$_.role -eq 'validation-execution' })
$receiptOutput = @($automationOutputs | Where-Object { [string]$_.phase -eq 'validation' -and [string]$_.role -eq 'validation-receipt' })
$executionAbsolute = if ($executionOutput.Count -eq 1) { Get-MorphospaceAutomationWorkspacePath -Output $executionOutput[0] -RepositoryMap $map.map -Workspace $workspace } else { $null }
$script:AuthorityStage='record-output-collision'
if ($evidenceOutput.Count -ne 1 -or $executionOutput.Count -ne 1 -or $receiptOutput.Count -ne 1 -or -not $evidenceAbsolute.Equals((Get-MorphospaceAutomationWorkspacePath -Output $evidenceOutput[0] -RepositoryMap $map.map -Workspace $workspace), [StringComparison]::OrdinalIgnoreCase) -or -not $receiptAbsolute.Equals((Get-MorphospaceAutomationWorkspacePath -Output $receiptOutput[0] -RepositoryMap $map.map -Workspace $workspace), [StringComparison]::OrdinalIgnoreCase)) { throw 'Validation paths do not match the exact authorized automation outputs.' }
Test-MorphospaceAutomationOutputSet -AutomationOutputs $automationOutputs -RepositoryMap $map.map -Expected absent -Phase 'validation'
$validatorResults = [Collections.Generic.List[object]]::new()
foreach ($validator in @($selection.validators)) {
    $script:AuthorityStage='record-owner-validator'
    if ([string]$UnitId -ne 'wf-005') { throw 'The current authority runner supports only the WF-005 owner-validator contract.' }
    $cleanRoom = $null; $tempRoot = $null
    try {
        $cleanRoom = New-MorphospaceCleanRoom -Ownership $ownership -ClaimBaseline $baseline -RepositoryMap $map.map -InputClosure @($validator.input_closure) -HistoryBlobs @($validator.history_blobs) -AttemptId "$UnitId-$($actionDocument.attempt_id)-$([string]$validator.validator_id)"
        $cleanBefore = Get-MorphospaceCleanRoomFingerprint $cleanRoom
        if ($cleanBefore -ne [string]$cleanRoom.fingerprint_sha256) { throw 'New clean room does not match its reported fingerprint.' }
        $validatorPath = [IO.Path]::GetFullPath((Join-Path ([string]$cleanRoom.repositories[[string]$validator.owner_repo_id]) ([string]$validator.path)))
        if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf) -or (Get-MorphospaceAuthoritySha256 $validatorPath) -ne [string]$validator.sha256) { throw "Clean-room validator bytes do not match the registry: $($validator.validator_id)" }
        $ownerOutput = @($automationOutputs | Where-Object { [string]$_.phase -eq 'validation' -and [string]$_.role -eq 'owner-validation' -and [string]$_.validator_id -eq [string]$validator.validator_id })
        if ($ownerOutput.Count -ne 1) { throw "Validation automation contract is missing owner evidence for $($validator.validator_id)." }
        $ownerOut = Get-MorphospaceAutomationWorkspacePath -Output $ownerOutput[0] -RepositoryMap $map.map -Workspace $workspace
        $stagedOwnerOut = Join-Path $script:AuthorityReportContext.root 'owner-evidence.json'
        $stdoutPath = $script:AuthorityReportContext.stdout
        $stderrPath = $script:AuthorityReportContext.stderr
        $planningRoot = [string]$cleanRoom.repositories['planning']
        $questRoot = [string]$cleanRoom.repositories['quest']
        $cleanWorkspace = Join-Path $planningRoot 'workspaces\morphospace-platform-iteration\morphospace'
        $cleanRoadmap = Join-Path $planningRoot 'agent-state\morphospace-autonomous-iteration-roadmap-2026-07-10.json'
        $run = Invoke-MorphospacePinnedValidator -ValidatorPath $validatorPath -Workspace $cleanWorkspace -Quest $questRoot -Roadmap $cleanRoadmap -Unit $UnitId -OwnerOut $stagedOwnerOut -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds ([int]$validator.timeout_seconds)
        if (([Text.Encoding]::UTF8.GetByteCount([string]$run.stdout) + [Text.Encoding]::UTF8.GetByteCount([string]$run.stderr)) -gt [int]$validator.max_output_bytes) { throw "Validator output exceeded its registered limit: $($validator.validator_id)" }
        $cleanAfter = Get-MorphospaceCleanRoomFingerprint $cleanRoom
        if ($cleanAfter -ne $cleanBefore) { throw "Validator modified its clean-room input closure: $($validator.validator_id)" }
        if ((Get-MorphospaceAuthoritySha256 $validatorPath) -ne [string]$validator.sha256) { throw "Validator bytes changed during execution: $($validator.validator_id)" }
        if (-not (Test-Path -LiteralPath $stagedOwnerOut -PathType Leaf)) { throw "Selected validator did not emit its owner evidence: $($validator.validator_id)" }
        $owner = Read-MorphospaceAuthorityJson $stagedOwnerOut
        $ownerStatus = if ($run.exit_code -eq 0 -and [string]$owner.status -eq 'pass') { 'pass' } elseif ($run.exit_code -eq 0) { 'fail' } else { 'fail' }
        Test-MorphospaceOwnerValidation -OwnerEvidence $owner -Validator $validator -Unit $unit -ExpectedStatus $ownerStatus | Out-Null
        Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath (Get-MorphospaceAutomationWorkspaceRelativePath -Workspace $workspace -AbsolutePath $ownerOut) -Value $owner -NoOverwrite
        $owner = Read-MorphospaceAuthorityJson $ownerOut
        $validatorResults.Add([pscustomobject][ordered]@{
            validator_id = [string]$validator.validator_id; owner_repo_id = [string]$validator.owner_repo_id; acceptance_ids = @($validator.acceptance_ids | Sort-Object); status = $ownerStatus; command_identity_sha256 = (Get-MorphospaceAuthoritySha256 $validatorPath); exit_code = [int]$run.exit_code; stdout_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ value = [string]$run.stdout })); stderr_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ value = [string]$run.stderr })); owner_evidence = Get-MorphospaceAuthorityReference $workspace $ownerOut 'owner-validation' ([string]$validator.evidence_schema); cleanroom_fingerprint_sha256 = $cleanBefore; input_closure_sha256 = (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{ closure = @($validator.input_closure) }))
        }) | Out-Null
    } finally { if ($null -ne $cleanRoom) { Remove-MorphospaceCleanRoom $cleanRoom }; if ($tempRoot -and [IO.Directory]::Exists($tempRoot)) { [IO.Directory]::Delete($tempRoot, $true) } }
}
$evidenceResult = if (@($validatorResults | Where-Object { [string]$_.status -ne 'pass' }).Count -eq 0) { 'pass' } else { 'fail' }
$script:AuthorityStage='record-publication'
$evidenceDocument = [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.validation_evidence.v2'; evidence_id = "$UnitId-$($actionDocument.attempt_id)-evidence"; created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); project_id = [string]$unit.project_id; unit_id = $UnitId; attempt_id = [string]$actionDocument.attempt_id; action = Get-MorphospaceAuthorityReference $workspace $actionAbsolute 'validation-action' 'rusty.morphospace.workflow.validation_action.v2'; profile_id = [string]$actionDocument.profile_id; result = $evidenceResult; validator_results = @($validatorResults.ToArray()); device_validation = $null; does_not_prove = @('Does not prove device validation, stable promotion, external Git push, or any downstream NET-013/MOD-006 acceptance.') }
Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath (Get-MorphospaceAutomationWorkspaceRelativePath -Workspace $workspace -AbsolutePath $evidenceAbsolute) -Value $evidenceDocument -NoOverwrite
$evidence = Test-MorphospaceValidationEvidenceV2 -WorkspaceRoot $workspace -EvidencePath $EvidencePath -Unit $unit -SelectedValidators @($selection.validators) -Action $actionDocument
$afterObservation = Test-MorphospaceUnitOwnership -Ownership $ownership -ClaimBaseline $baseline -ClaimBaselineReference $protocol.claim_baseline -Unit $unit -RepositoryMapReference $protocol.repository_map -RepositoryMap $map.map
if ([string]$afterObservation.observation.sha256 -ne [string]$observation.observation.sha256) { throw 'Validation created a repository delta outside the exact automation contract.' }
$executionDocument = New-MorphospaceValidationExecutionV1 -WorkspaceRoot $workspace -Unit $unit -Action $actionDocument -ActionPath $actionAbsolute -Evidence $evidence -EvidencePath $evidenceAbsolute -Observation $afterObservation.observation -ExpectedReceiptPath ([string]$receiptOutput[0].path) -ExecutorPath $PSCommandPath -ExecutionNonce $ExecutionNonce
Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath (Get-MorphospaceAutomationWorkspaceRelativePath -Workspace $workspace -AbsolutePath $executionAbsolute) -Value $executionDocument -NoOverwrite
$execution = Read-MorphospaceAuthorityJson $executionAbsolute
$receipt = New-MorphospaceValidationReceiptV2 -WorkspaceRoot $workspace -Unit $unit -Action $actionDocument -ActionPath $actionAbsolute -Evidence $evidence -EvidencePath $evidenceAbsolute -Execution $execution -ExecutionPath $executionAbsolute -Protocol $protocol -ProtocolPath $protocolAbsolute -Ownership $ownership -OwnershipPath $ownershipAbsolute -Registry $registry -RegistryPath $registryAbsolute -Observation $afterObservation.observation
Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $workspace -RelativePath (Get-MorphospaceAutomationWorkspaceRelativePath -Workspace $workspace -AbsolutePath $receiptAbsolute) -Value $receipt -NoOverwrite
Test-MorphospaceAutomationOutputSet -AutomationOutputs $automationOutputs -RepositoryMap $map.map -Expected present -Phase 'validation'
Write-MorphospaceAuthorityStageResult -Context $script:AuthorityReportContext -Stage 'record-validation' -Result pass -StartedAt $script:AuthorityStartedAt -CapsuleSha256 $script:AuthorityCapsuleSha256 -RunnerReleaseSha256 $script:AuthorityRunnerReleaseSha256|Out-Null
$receipt | ConvertTo-Json -Depth 30
