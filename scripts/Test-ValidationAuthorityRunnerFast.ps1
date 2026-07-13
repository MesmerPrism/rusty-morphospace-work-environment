$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$warningPreferenceBeforeImports = $WarningPreference
try {
    $WarningPreference = 'SilentlyContinue'
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceOwnership.psm1') -Force
    $script:OwnershipModule = Get-Module MorphospaceOwnership
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceContentObservation.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
} finally {
    $WarningPreference = $warningPreferenceBeforeImports
}

function Assert-RunnerFast {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Fast validation-authority runner self-test failed: $Message" }
}

function Write-TestText {
    param([string]$Path,[string]$Text)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

function Write-TestJson {
    param([string]$Path,[object]$Value)
    Write-TestText $Path (($Value | ConvertTo-Json -Depth 100 -Compress) + "`n")
}

function Invoke-TestGit {
    param([string]$Git,[string]$Repository,[string[]]$Arguments)
    $output = @(& $Git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($Arguments -join ' ') $($output -join ' ')" }
    return [string]($output -join '')
}

function Initialize-TestGitRepository {
    param([string]$Git,[string]$Repository,[string]$Message)
    Invoke-TestGit $Git $Repository @('init','--quiet') | Out-Null
    Invoke-TestGit $Git $Repository @('config','user.name','Authority Runner Fixture') | Out-Null
    Invoke-TestGit $Git $Repository @('config','user.email','authority-runner@example.invalid') | Out-Null
    Invoke-TestGit $Git $Repository @('config','core.autocrlf','false') | Out-Null
    Invoke-TestGit $Git $Repository @('add','--','.') | Out-Null
    Invoke-TestGit $Git $Repository @('commit','--quiet','-m',$Message) | Out-Null
}

function Get-TestObservedEntries {
    param([object]$Observation,[switch]$Baseline)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Observation.entries)) {
        $normalized = & $script:OwnershipModule { param($RepositoryObservation,$RepositoryEntry) New-MorphospaceObservedEntry $RepositoryObservation $RepositoryEntry } $Observation $entry
        $core = $normalized.core
        if ($Baseline) {
            $rows.Add([pscustomobject][ordered]@{path=[string]$core.path;entry_fingerprint_sha256=[string]$normalized.fingerprint_sha256;state=[string]$core.state;sha256=$core.sha256;length=$core.length;mode=$core.mode;patch_sha256=$core.patch_sha256;hunks=@($core.hunks)}) | Out-Null
        } else {
            $rows.Add($normalized) | Out-Null
        }
    }
    $array = @($rows.ToArray())
    [Array]::Sort($array,[Comparison[object]]{
        param($Left,$Right)
        $leftPath = if ($Baseline) { [string]$Left.path } else { [string]$Left.core.path }
        $rightPath = if ($Baseline) { [string]$Right.path } else { [string]$Right.core.path }
        [StringComparer]::Ordinal.Compare($leftPath,$rightPath)
    })
    return $array
}

function Get-TestOrdinalSha256 {
    param([object]$Value)
    return Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$Value})
}

function Get-TestComparableObservation {
    param([object]$Observation,[object[]]$AutomationOutputs)
    return & $script:OwnershipModule {
        param($RepositoryObservation,$Outputs)
        ConvertTo-MorphospaceComparableRepositoryObservation -Observation $RepositoryObservation -AutomationOutputs $Outputs
    } $Observation $AutomationOutputs
}

function Get-TestAutomationOutputContract {
    param([object]$Ownership,[object]$Unit)
    $scopes = @{}
    foreach ($scope in @($Unit.allowed_repositories)) { $scopes[[string]$scope.repo_id] = $scope }
    return @(& $script:OwnershipModule {
        param($Owned,$IterationUnit,$AllowedScopes)
        Get-MorphospaceAutomationOutputContract -Ownership $Owned -Unit $IterationUnit -Scopes $AllowedScopes
    } $Ownership $Unit $scopes)
}

function Invoke-TestAutomationOutputCheck {
    param([object[]]$AutomationOutputs,[hashtable]$RepositoryMap,[string]$Expected,[string]$Phase)
    & $script:OwnershipModule {
        param($Outputs,$Map,$ExpectedState,$OutputPhase)
        Test-MorphospaceAutomationOutputSet -AutomationOutputs $Outputs -RepositoryMap $Map -Expected $ExpectedState -Phase $OutputPhase
    } $AutomationOutputs $RepositoryMap $Expected $Phase
}

function Remove-TestContentAddressedCache {
    param([string]$CapsuleSha256)
    & $script:OwnershipModule {
        param($Capsule)
        $cached = Open-MorphospaceContentAddressedCleanRoom -CapsuleSha256 $Capsule -MaterializedInputsSha256 $Capsule
        if ($null -ne $cached) { Remove-MorphospaceContentAddressedCleanRoom $cached -RemoveManifest }
    } $CapsuleSha256
}

function New-TestBaselineRow {
    param([object]$Observation,[string[]]$AllowedPaths)
    $entries = @(Get-TestObservedEntries $Observation -Baseline)
    $instructionSha = Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=@()})
    return [pscustomobject][ordered]@{
        repo_id=[string]$Observation.repo_id;kind=[string]$Observation.kind;head_revision=if([string]$Observation.kind-ceq'git'){[string]$Observation.head_revision}else{$null};head_tree_oid=if([string]$Observation.kind-ceq'git'){[string]$Observation.head_tree}else{$null};branch=if([string]$Observation.kind-ceq'git'){[string]$Observation.branch}else{$null}
        allowed_paths=@($AllowedPaths);content_observation_sha256=Get-MorphospaceCanonicalJsonSha256 $Observation;status_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.status_sha256}else{$null};overlay_fingerprint_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.overlay_fingerprint_sha256}else{[string]$Observation.tree_fingerprint_sha256}
        commit_manifest_fingerprint_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.commit_fingerprint_sha256}else{$null};instruction_observation_sha256=$instructionSha;entries_fingerprint_sha256=Get-TestOrdinalSha256 $entries;entries=$entries
        instructions_fingerprint_sha256=$instructionSha;instructions=@()
    }
}

function New-TestOwnershipRow {
    param([object]$BaselineRow,[object]$Observation)
    $baseline = @{}
    foreach ($entry in @($BaselineRow.entries)) { $baseline[[string]$entry.path] = $entry }
    $preserved = [Collections.Generic.List[string]]::new()
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($normalized in @(Get-TestObservedEntries $Observation)) {
        $core = $normalized.core
        $path = [string]$core.path
        $prior = if ($baseline.ContainsKey($path)) { $baseline[$path] } else { $null }
        if ($null -ne $prior -and [string]$prior.entry_fingerprint_sha256 -ceq [string]$normalized.fingerprint_sha256) {
            $preserved.Add([string]$prior.entry_fingerprint_sha256) | Out-Null
            continue
        }
        $entries.Add([pscustomobject][ordered]@{
            path=$path;final_entry_fingerprint_sha256=[string]$normalized.fingerprint_sha256;baseline_entry_fingerprint_sha256=if($null -eq $prior){$null}else{[string]$prior.entry_fingerprint_sha256}
            state=[string]$core.state;sha256=$core.sha256;length=$core.length;mode=$core.mode;patch_sha256=$core.patch_sha256;hunks=@($core.hunks);attribution=if($null -eq $prior){'unit'}else{'shared'}
        }) | Out-Null
    }
    foreach ($prior in @($BaselineRow.entries)) {
        if (@($Observation.entries | Where-Object { [string]$_.path -ceq [string]$prior.path }).Count -eq 0) { $preserved.Add([string]$prior.entry_fingerprint_sha256) | Out-Null }
    }
    $entryArray = @($entries.ToArray())
    [Array]::Sort($entryArray,[Comparison[object]]{param($Left,$Right)[StringComparer]::Ordinal.Compare([string]$Left.path,[string]$Right.path)})
    $preservedArray = @($preserved.ToArray() | Sort-Object -Unique)
    return [pscustomobject][ordered]@{
        repo_id=[string]$Observation.repo_id;kind=[string]$Observation.kind;base_revision=if([string]$Observation.kind-ceq'git'){[string]$BaselineRow.head_revision}else{$null};head_revision=if([string]$Observation.kind-ceq'git'){[string]$Observation.head_revision}else{$null};head_tree_oid=if([string]$Observation.kind-ceq'git'){[string]$Observation.head_tree}else{$null};branch=if([string]$Observation.kind-ceq'git'){[string]$Observation.branch}else{$null}
        allowed_paths=@($BaselineRow.allowed_paths);live_content_observation_sha256=Get-MorphospaceCanonicalJsonSha256 $Observation;live_status_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.status_sha256}else{$null};live_overlay_fingerprint_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.overlay_fingerprint_sha256}else{[string]$Observation.tree_fingerprint_sha256}
        live_commit_manifest_fingerprint_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.commit_fingerprint_sha256}else{$null};baseline_entries_sha256=[string]$BaselineRow.entries_fingerprint_sha256;preserved_baseline_entries_sha256=Get-TestOrdinalSha256 $preservedArray
        preserved_baseline_count=$preservedArray.Count;instruction_observation_sha256=[string]$BaselineRow.instruction_observation_sha256;entries=$entryArray
    }
}

function ConvertTo-TestProcessArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"','\"') + '"'
}

function Get-TestPowerShellHost {
    $property = [Environment].GetProperty('ProcessPath')
    if ($null -ne $property) {
        $candidate = [string]$property.GetValue($null,$null)
        if ($candidate) { return $candidate }
    }
    return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

function Invoke-TestRunnerProcess {
    param([string]$Runner,[string[]]$Arguments,[int]$TimeoutSeconds=120)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Get-TestPowerShellHost
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $processArguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Runner) + $Arguments
    if ($start.PSObject.Properties.Name -contains 'ArgumentList') {
        foreach ($argument in $processArguments) { [void]$start.ArgumentList.Add([string]$argument) }
    } else {
        $start.Arguments = (@($processArguments | ForEach-Object { ConvertTo-TestProcessArgument ([string]$_) }) -join ' ')
    }
    $process = [Diagnostics.Process]::Start($start)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "Authority runner fixture exceeded ${TimeoutSeconds}s."
        }
        $exitCode = [int]$process.ExitCode
    } finally {
        if (-not $process.HasExited) { try { $process.Kill() } catch {} }
    }
    $stdout = [string]$stdoutTask.Result
    $stderr = [string]$stderrTask.Result
    $process.Dispose()
    return [pscustomobject]@{exit_code=$exitCode;stdout=$stdout;stderr=$stderr}
}

function New-TestNonce {
    $bytes = [byte[]]::new(32)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
}

function Remove-TestTree {
    param([string]$Path,[string]$ExpectedParent)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $resolved = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing fixture cleanup outside $ExpectedParent" }
    foreach ($file in [IO.Directory]::EnumerateFiles($resolved,'*',[IO.SearchOption]::AllDirectories)) { try { [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal) } catch {} }
    [IO.Directory]::Delete($resolved,$true)
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$root = Join-Path $tempRoot ('morphospace-authority-runner-fast-' + [guid]::NewGuid().ToString('N'))
$capsuleSha256 = ''
$reportRoots = [Collections.Generic.List[string]]::new()
try {
    $git = (Get-MorphospaceBoundExecutable git).path
    $planning = Join-Path $root 'planning'
    $quest = Join-Path $root 'quest'
    $workEnvironment = Join-Path $root 'work-environment'
    $workspaceRelative = 'workspaces/morphospace-platform-iteration/morphospace'
    $workspace = Join-Path $planning ($workspaceRelative.Replace('/','\'))
    foreach ($directory in @($planning,$quest,$workEnvironment,$workspace,(Join-Path $quest 'fixture'))) { [IO.Directory]::CreateDirectory($directory) | Out-Null }

    $authorityPaths = @(
        'scripts/Invoke-MorphospaceValidationAuthority.ps1','scripts/Invoke-WorkUnitAutomation.ps1','scripts/Invoke-Wf005OwnerValidator.ps1','scripts/Test-ValidationAuthorityLauncher.ps1',
        'scripts/Test-AuthorityRunnerHandoff.ps1','scripts/Test-AuthorityRecordReadiness.ps1','scripts/Test-TrustMigrationAuthority.ps1','scripts/Test-ValidationExecutionAuthority.ps1',
        'scripts/Test-TransitionLedger.ps1','scripts/WorkUnitAutomation.psm1','scripts/lib/MorphospaceAuthorityReadiness.psm1','scripts/lib/MorphospaceContentObservation.psm1',
        'scripts/lib/MorphospaceOwnership.psm1','scripts/lib/MorphospaceProtocolCommon.psm1','scripts/lib/MorphospaceTransitionLedger.psm1','scripts/lib/MorphospaceValidationAuthority.psm1'
    )
    $validatorPath = 'scripts/Invoke-Wf005OwnerValidator.ps1'
    foreach ($relative in $authorityPaths) {
        $source = Join-Path $repoRoot $relative
        $target = Join-Path $workEnvironment ($relative.Replace('/','\'))
        $parent = [IO.Path]::GetDirectoryName($target)
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        [IO.File]::Copy($source,$target,$true)
    }
    $fixtureValidator = @'
param([string]$WorkspaceRoot,[string]$QuestRoot,[string]$RoadmapPath,[string]$UnitId,[string]$OutPath,[switch]$ProbeOnly)
$ErrorActionPreference='Stop'
if($UnitId-ne'wf-005'){throw 'fixture unit mismatch'}
$write={param($value)[IO.File]::WriteAllText($OutPath,(($value|ConvertTo-Json -Depth 20 -Compress)+"`n"),[Text.UTF8Encoding]::new($false));$value|ConvertTo-Json -Depth 20 -Compress}
if($ProbeOnly){
  $contract="quick`nnone`ncriterion-a"
  $canonical=([pscustomobject]@{value=$contract}|ConvertTo-Json -Compress)
  $sha=[Security.Cryptography.SHA256]::Create();try{$contractSha=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
  $probe=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.owner_validator_admission_probe.v1';validator_id='fixture-owner';created_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');project_id='fixture-project';unit_id=$UnitId;unit_contract_sha256=$contractSha;commands=@([pscustomobject][ordered]@{command_id='fixture-owner';command_name='fixture-owner.ps1';command_sha256=('1'*64)});acceptance_bindings=@([pscustomobject][ordered]@{acceptance_id='criterion-a';command_id='fixture-owner'});status='pass';does_not_prove=@('Admission-only fixture probe does not execute or prove acceptance.')}
  &$write $probe
  exit 0
}
$criterion=[pscustomobject][ordered]@{acceptance_id='criterion-a';status='pass';command_id='fixture-owner';command_path='fixture-owner.ps1';command_sha256=('1'*64);output_sha256=('2'*64);exit_code=0}
$document=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.owner_validation.v1';validator_id='fixture-owner';created_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');project_id='fixture-project';unit_id=$UnitId;acceptance_ids=@('criterion-a');status='pass';criteria=@($criterion);does_not_prove=@('Fixture evidence proves only the bounded authority-runner test.')}
&$write $document
'@
    Write-TestText (Join-Path $workEnvironment 'scripts\Invoke-Wf005OwnerValidator.ps1') $fixtureValidator
    Initialize-TestGitRepository $git $workEnvironment 'fixture authority release'
    $workEnvironmentHead = (Invoke-TestGit $git $workEnvironment @('rev-parse','HEAD')).Trim()
    $workEnvironmentTree = (Invoke-TestGit $git $workEnvironment @('rev-parse','HEAD^{tree}')).Trim()

    Write-TestText (Join-Path $quest 'fixture\input.txt') "quest-input`n"

    $unit = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';project_id='fixture-project';unit_id='wf-005';status='validating';risk_tier='quick';device_requirement='none';instruction_impact='none';instruction_surfaces=@()
        allowed_repositories=@(
            [pscustomobject]@{repo_id='planning';allowed_paths=@($workspaceRelative)},
            [pscustomobject]@{repo_id='quest';allowed_paths=@('fixture')},
            [pscustomobject]@{repo_id='work-environment';allowed_paths=@($validatorPath)}
        )
        acceptance=@([pscustomobject]@{acceptance_id='criterion-a';proof='fixture';command='fixture-owner'})
        validation=@([pscustomobject]@{profile_id='quick';command='fixture-owner'})
    }
    $repositoryMap = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.repository_map.v1';repositories=@(
            [pscustomobject]@{repo_id='planning';path=$planning;role='planning';aliases=@()},
            [pscustomobject]@{repo_id='quest';path=$quest;role='source';aliases=@()},
            [pscustomobject]@{repo_id='work-environment';path=$workEnvironment;role='source';aliases=@()}
        )
    }
    Write-TestJson (Join-Path $workspace 'project.spec.json') ([pscustomobject]@{schema='rusty.morphospace.workflow.project_spec.v2';project_id='fixture-project'})
    Write-TestJson (Join-Path $workspace 'workspace.state.json') ([pscustomobject]@{schema='rusty.morphospace.workflow.workspace_state.v2';project_id='fixture-project';current_unit='wf-005'})
    Write-TestJson (Join-Path $workspace 'iteration-units\wf-005.json') $unit
    Write-TestJson (Join-Path $workspace 'repository-map.json') $repositoryMap
    Write-TestText (Join-Path $workspace 'fixture-input.txt') "planning-input`n"

    $map = @{
        planning=[pscustomobject]@{repo_id='planning';path=$planning;role='planning';aliases=@()}
        quest=[pscustomobject]@{repo_id='quest';path=$quest;role='source';aliases=@()}
        'work-environment'=[pscustomobject]@{repo_id='work-environment';path=$workEnvironment;role='source';aliases=@()}
    }
    $mapReference = Get-MorphospaceAuthorityReference $workspace (Join-Path $workspace 'repository-map.json') 'repository-map' 'rusty.morphospace.workflow.repository_map.v1'
    $planningBaselineObservation = Get-MorphospaceNonGitTreeObservation planning $planning @($workspaceRelative)
    $questBaselineObservation = Get-MorphospaceNonGitTreeObservation quest $quest @('fixture')
    $workEnvironmentBaselineObservation = Get-MorphospaceGitRepositoryObservation work-environment $workEnvironment $workEnvironmentHead @($validatorPath) $git
    $baselineRows = @(
        New-TestBaselineRow $planningBaselineObservation @($workspaceRelative)
        New-TestBaselineRow $questBaselineObservation @('fixture')
        New-TestBaselineRow $workEnvironmentBaselineObservation @($validatorPath)
    )
    $claim = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.claim_baseline.v1';baseline_id='fixture-claim';created_at='2026-07-13T10:00:00.0000000Z';project_id='fixture-project';unit_id='wf-005';repository_map=$mapReference;repositories=$baselineRows;status='frozen'}
    $claimPath = Join-Path $workspace 'receipts\fixture\claim-baseline.json'
    Write-TestJson $claimPath $claim
    $claimReference = Get-MorphospaceAuthorityReference $workspace $claimPath 'claim-baseline' 'rusty.morphospace.workflow.claim_baseline.v1'

    $automationOutputs = @(
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/registry.json";phase='bootstrap';role='owner-validator-registry';schema='rusty.morphospace.workflow.owner_validator_registry.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/ownership.json";phase='bootstrap';role='unit-ownership';schema='rusty.morphospace.workflow.unit_ownership.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/anchor.json";phase='bootstrap';role='legacy-prefix-anchor';schema='rusty.morphospace.workflow.legacy_event_prefix_anchor.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/migration.json";phase='bootstrap';role='validator-trust-anchor-migration';schema='rusty.morphospace.workflow.validator_trust_anchor_migration.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/protocol.json";phase='bootstrap';role='current-unit-protocol';schema='rusty.morphospace.workflow.current_unit_protocol.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/action.json";phase='bootstrap';role='validation-action';schema='rusty.morphospace.workflow.validation_action.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/runner-release.json";phase='readiness';role='authority-runner-release';schema='rusty.morphospace.workflow.authority_runner_release.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/capsule.json";phase='readiness';role='authority-input-capsule';schema='rusty.morphospace.workflow.authority_input_capsule.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/host.json";phase='readiness';role='authority-host-capabilities';schema='rusty.morphospace.workflow.authority_host_capabilities.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/preflight.json";phase='readiness';role='authority-preflight-result';schema='rusty.morphospace.workflow.authority_preflight_result.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/owner.json";phase='validation';role='owner-validation';schema='rusty.morphospace.workflow.owner_validation.v1';validator_id='fixture-owner'},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/evidence.json";phase='validation';role='validation-evidence';schema='rusty.morphospace.workflow.validation_evidence.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/execution.json";phase='validation';role='validation-execution';schema='rusty.morphospace.workflow.validation_execution.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/receipt.json";phase='validation';role='validation-receipt';schema='rusty.morphospace.workflow.validation_receipt.v2';validator_id=$null}
    )

    $planningCurrent = Get-MorphospaceNonGitTreeObservation planning $planning @($workspaceRelative)
    $questCurrent = Get-MorphospaceNonGitTreeObservation quest $quest @('fixture')
    $workEnvironmentCurrent = Get-MorphospaceGitRepositoryObservation work-environment $workEnvironment $workEnvironmentHead @($validatorPath) $git
    $planningComparableCurrent = Get-TestComparableObservation $planningCurrent @($automationOutputs | Where-Object { [string]$_.repo_id -ceq 'planning' })
    $ownership = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.unit_ownership.v1';ownership_id='fixture-ownership';created_at='2026-07-13T10:01:00.0000000Z';project_id='fixture-project';unit_id='wf-005';claim_baseline=$claimReference
        repositories=@(
            New-TestOwnershipRow $baselineRows[0] $planningComparableCurrent
            New-TestOwnershipRow $baselineRows[1] $questCurrent
            New-TestOwnershipRow $baselineRows[2] $workEnvironmentCurrent
        )
        shared_overlaps=@();automation_outputs=$automationOutputs;status='assigned'
    }

    $validatorAbsolute = Join-Path $workEnvironment ($validatorPath.Replace('/','\'))
    $validatorBlob = (Invoke-TestGit $git $workEnvironment @('rev-parse',"HEAD:$validatorPath")).Trim()
    $validator = [pscustomobject][ordered]@{
        validator_id='fixture-owner';owner_repo_id='work-environment';owner_revision=$workEnvironmentHead;owner_tree_oid=$workEnvironmentTree;path=$validatorPath;sha256=Get-MorphospaceAuthoritySha256 $validatorAbsolute;git_blob_oid=$validatorBlob
        entrypoint='powershell-file';profiles=@('quick');acceptance_ids=@('criterion-a');evidence_schema='rusty.morphospace.workflow.owner_validation.v1'
        input_closure=@(
            [pscustomobject]@{repo_id='planning';kind='non-git-tree';paths=@("$workspaceRelative/fixture-input.txt")},
            [pscustomobject]@{repo_id='quest';kind='non-git-tree';paths=@('fixture/input.txt')},
            [pscustomobject]@{repo_id='work-environment';kind='git-tree';paths=@($validatorPath)}
        )
        history_blobs=@()
        timeout_seconds=30;max_output_bytes=1048576;mutation_policy='temp-output-only';device_policy='forbidden'
    }
    $registry = [pscustomobject][ordered]@{'$schema'='https://example.invalid/owner-validator-registry.schema.json';schema='rusty.morphospace.workflow.owner_validator_registry.v1';registry_id='fixture-registry';revision=1;created_at='2026-07-13T10:02:00.0000000Z';foundation_commit=$workEnvironmentHead;previous_registry=$null;validators=@($validator)}
    $registryPath = Join-Path $workspace 'receipts\fixture\registry.json'
    Write-TestJson $registryPath $registry
    $registryReference = Get-MorphospaceAuthorityReference $workspace $registryPath 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'

    $anchor = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.legacy_event_prefix_anchor.v1';anchor_id='wf-005-legacy-prefix';created_at='2026-07-13T10:03:00.0000000Z';project_id='fixture-project';unit_id='wf-005';event_log_path='iteration-events.jsonl';last_sequence=1;prefix_sha256=('3'*64);status='frozen'}
    $anchorPath = Join-Path $workspace 'receipts\fixture\anchor.json'
    Write-TestJson $anchorPath $anchor
    $anchorReference = Get-MorphospaceAuthorityReference $workspace $anchorPath 'legacy-prefix-anchor' 'rusty.morphospace.workflow.legacy_event_prefix_anchor.v1'

    $artifacts = @($authorityPaths | ForEach-Object {
        $relative = [string]$_
        $absolute = Join-Path $workEnvironment ($relative.Replace('/','\'))
        $blob = (Invoke-TestGit $git $workEnvironment @('rev-parse',"HEAD:$relative")).Trim()
        [pscustomobject]@{repo_id='work-environment';path=$relative;sha256=Get-MorphospaceAuthoritySha256 $absolute;git_blob_oid=$blob}
    })
    $migration = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.validator_trust_anchor_migration.v1';project_id='fixture-project';unit_id='wf-005';status='accepted'
        bootstrap_exception=[pscustomobject]@{one_time=$true;non_promotional=$true;self_authorization_scope='authority-adoption-only';normal_ownership_after_commit=$true}
        lineage=@([pscustomobject]@{role='legacy-bootstrap'},[pscustomobject]@{role='protocol-v2'},[pscustomobject]@{role='foundation'},[pscustomobject]@{role='authority'})
        registry=$registryReference;prior_event_anchor=$anchorReference;authority_artifacts=$artifacts
    }
    $migrationPath = Join-Path $workspace 'receipts\fixture\migration.json'
    Write-TestJson $migrationPath $migration
    $migrationReference = Get-MorphospaceAuthorityReference $workspace $migrationPath 'validator-trust-anchor-migration' 'rusty.morphospace.workflow.validator_trust_anchor_migration.v1'

    $ownershipPath = Join-Path $workspace 'receipts\fixture\ownership.json'
    Write-TestJson $ownershipPath $ownership
    $ownershipReference = Get-MorphospaceAuthorityReference $workspace $ownershipPath 'unit-ownership' 'rusty.morphospace.workflow.unit_ownership.v1'
    $protocol = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.current_unit_protocol.v1';protocol_id='fixture-protocol';created_at='2026-07-13T10:04:00.0000000Z';project_id='fixture-project';unit_id='wf-005';authority_revision=$workEnvironmentHead
        registry=$registryReference;trust_anchor_migration=$migrationReference;repository_map=$mapReference;claim_baseline=$claimReference;unit_ownership=$ownershipReference;event_anchor=$anchorReference
        state_sha256=Get-MorphospaceAuthoritySha256 (Join-Path $workspace 'workspace.state.json');unit_sha256=Get-MorphospaceAuthoritySha256 (Join-Path $workspace 'iteration-units\wf-005.json');status='active'
    }
    $protocolPath = Join-Path $workspace 'receipts\fixture\protocol.json'
    Write-TestJson $protocolPath $protocol
    $protocolReference = Get-MorphospaceAuthorityReference $workspace $protocolPath 'current-unit-protocol' 'rusty.morphospace.workflow.current_unit_protocol.v1'

    $automationContract = @(Get-TestAutomationOutputContract -Ownership $ownership -Unit $unit)
    $preObservationDocument = [pscustomobject][ordered]@{repositories=@($planningComparableCurrent,$questCurrent,$workEnvironmentCurrent);instructions=@()}
    $observation = [pscustomobject]@{observation=[pscustomobject]@{document=$preObservationDocument;sha256=Get-MorphospaceCanonicalJsonSha256 $preObservationDocument};automation_outputs=$automationContract}
    $action = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.validation_action.v2';action_id='fixture-action';created_at='2026-07-13T10:05:00.0000000Z';project_id='fixture-project';unit_id='wf-005';attempt_id='fixture-attempt-001';profile_id='quick'
        current_protocol=$protocolReference;registry=$registryReference;ownership=$ownershipReference;claim_baseline=$claimReference;repository_map=$mapReference
        selected_validators=@([pscustomobject]@{validator_id='fixture-owner';registry_entry_sha256=Get-MorphospaceCanonicalJsonSha256 $validator})
        expected_outputs=@($observation.automation_outputs | Where-Object { [string]$_.phase -ceq 'validation' } | Sort-Object repo_id,path)
        pre_observation_sha256=[string]$observation.observation.sha256;device_validation=$null;status='authorized'
    }
    $actionPath = Join-Path $workspace 'receipts\fixture\action.json'
    Write-TestJson $actionPath $action
    Invoke-TestAutomationOutputCheck $observation.automation_outputs $map present bootstrap

    $runner = Join-Path $workEnvironment 'scripts\Invoke-MorphospaceValidationAuthority.ps1'
    $commonArguments = @(
        '-WorkspaceRoot',$workspace,'-UnitId','wf-005','-RegistryPath','receipts/fixture/registry.json','-RepositoryMapPath','repository-map.json',
        '-CurrentProtocolPath','receipts/fixture/protocol.json','-TrustMigrationPath','receipts/fixture/migration.json','-ClaimBaselinePath','receipts/fixture/claim-baseline.json',
        '-OwnershipPath','receipts/fixture/ownership.json','-ValidationActionPath','receipts/fixture/action.json'
    )
    $preflightNonce = New-TestNonce
    $preflightReport = Join-Path ([IO.Path]::GetTempPath()) "rusty-morphospace-authority-reports\fixture-project\wf-005\fixture-attempt-001\preflight-$preflightNonce"
    $reportRoots.Add($preflightReport) | Out-Null
    $preflightRun = Invoke-TestRunnerProcess $runner (@('-Action','Preflight') + $commonArguments + @('-ExecutionNonce',$preflightNonce))
    Assert-RunnerFast ($preflightRun.exit_code -eq 0) "real Preflight branch failed: $($preflightRun.stderr)"
    $preflightResult = $preflightRun.stdout | ConvertFrom-Json
    Assert-RunnerFast ([string]$preflightResult.status -ceq 'ready-for-record') 'real Preflight branch did not publish ready-for-record'
    $capsule = Get-Content -LiteralPath (Join-Path $workspace 'receipts\fixture\capsule.json') -Raw | ConvertFrom-Json
    $capsuleSha256 = [string]$capsule.capsule_sha256

    $recordNonce = New-TestNonce
    $recordReport = Join-Path ([IO.Path]::GetTempPath()) "rusty-morphospace-authority-reports\fixture-project\wf-005\fixture-attempt-001\record-$recordNonce"
    $reportRoots.Add($recordReport) | Out-Null
    $recordRun = Invoke-TestRunnerProcess $runner (@('-Action','Validate') + $commonArguments + @('-ExecutionNonce',$recordNonce,'-EvidencePath','receipts/fixture/evidence.json','-OutPath','receipts/fixture/receipt.json'))
    Assert-RunnerFast ($recordRun.exit_code -eq 0) "real Validate branch failed: $($recordRun.stderr)"
    $receipt = $recordRun.stdout | ConvertFrom-Json
    Assert-RunnerFast ([string]$receipt.result -ceq 'pass') 'real Validate branch did not produce a passing receipt'
    try {
        $validatedReceipt = Test-MorphospaceValidationReceiptV2 -WorkspaceRoot $workspace -ReceiptReference 'receipts/fixture/receipt.json' -Unit $unit -RepositoryMap $map -ExpectedResult pass -ExpectedExecutionNonce $recordNonce
    } catch {
        throw "Full receipt consumer failed: $([string]$_.Exception.Message)`n$([string]$_.ScriptStackTrace)"
    }
    Assert-RunnerFast ([string]$validatedReceipt.status -ceq 'accepted-evidence') 'published receipt did not survive full consumer validation'

    Write-Host 'Fast validation-authority runner self-test passed.'
} finally {
    if ($capsuleSha256 -match '^[0-9a-f]{64}$') {
        try {
            Remove-TestContentAddressedCache $capsuleSha256
        } catch {}
    }
    foreach ($reportRoot in $reportRoots) {
        try { Remove-TestTree $reportRoot (Join-Path ([IO.Path]::GetTempPath()) 'rusty-morphospace-authority-reports') } catch {}
    }
    if ([IO.Directory]::Exists($root)) { Remove-TestTree $root $tempRoot }
}
