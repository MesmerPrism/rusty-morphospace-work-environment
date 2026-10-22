param([string]$RepoRoot = "", [string]$SeedContextPath = "", [string]$SeedContextSha256 = "", [switch]$ProviderOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$runner = Join-Path $RepoRoot "scripts\Invoke-QuestBuildProfile.ps1"
$progressInspector = Join-Path $RepoRoot "scripts\Inspect-QuestBuildProgress.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("quest-build-profile-corpus-" + [guid]::NewGuid().ToString("N"))
$profileRoot = "$testRoot-profiles"
$externalSourceRoot = "$testRoot-qfm-source"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Quest build-profile corpus failed: $Message" }
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-Progress {
    param([string]$BaseReceiptPath)
    $output = & pwsh -NoProfile -NonInteractive -File $progressInspector -BaseReceiptPath $BaseReceiptPath
    Assert-True ($LASTEXITCODE -eq 0) "Build progress observer failed."
    return ($output | ConvertFrom-Json -Depth 8)
}

function Write-Profile {
    param([object]$Profile)
    if (-not (Test-Path -LiteralPath $profileRoot)) { New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null }
    $path = Join-Path $profileRoot "profile.json"
    Write-Utf8 $path ($Profile | ConvertTo-Json -Depth 32)
    return [pscustomobject]@{ Path = $path; Sha256 = Get-Sha $path }
}

function New-Profile {
    param([string]$ArtifactRelativePath = "out\fixture.apk", [string[]]$Arguments = @("out\fixture.apk"))
    return [ordered]@{
        schema = "rusty.morphospace.quest_build_profile.v1"
        profile_id = "fixture-apk"
        working_directory = "."
        executable = "build.ps1"
        arguments = @($Arguments)
        environment = [ordered]@{}
        artifact = [ordered]@{ relative_path = $ArtifactRelativePath; kind = "single-base-apk" }
        preflight = [ordered]@{
            manifest_relative_dependencies = @("AndroidManifest.xml")
            toolchain = [ordered]@{ repository_files = @("rust-toolchain.toml"); required_targets = @() }
            identity = [ordered]@{ package_id = "example.fixture"; application_id = "example.fixture" }
            environment_projection = [ordered]@{ passthrough = @("HOME", "PATH", "TEMP", "TMP", "TMPDIR"); prohibited_parent_variables = @() }
            output = [ordered]@{ lane = "warm"; collision_policy = "new-only"; allow_source_root = $true }
        }
    }
}

function Invoke-Runner {
    param(
        [string]$Mode,
        [object]$ProfileRecord,
        [string]$Receipt = "",
        [string]$SignerPath = "",
        [string]$SignerSha256 = "",
        [string]$EnvironmentBindingsPath = "",
        [string]$EnvironmentBindingsSha256 = "",
        [int]$Timeout = 30,
        [int]$CancelAfterMilliseconds = 0,
        [switch]$Interrupt,
        [string]$BuildContextPath = "",
        [string]$BuildContextSha256 = "",
        [switch]$Retained
    )
    $runnerArguments = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $runner,
        "-Mode", $Mode,
        "-ProfilePath", $ProfileRecord.Path,
        "-ProfileSha256", $ProfileRecord.Sha256,
        "-SourceRoot", $testRoot,
        "-TimeoutSeconds", [string]$Timeout
    )
    if ($Retained) { $runnerArguments += @("-WaitPolicy", "Retained", "-EstimatedWarningSeconds", "30") }
    if ($BuildContextPath) { $runnerArguments += @("-BuildContextPath", $BuildContextPath, "-BuildContextSha256", $BuildContextSha256) }
    if ($Receipt) { $runnerArguments += @("-ReceiptPath", $Receipt) }
    if ($SignerPath) { $runnerArguments += @("-SignerObservationPath", $SignerPath, "-SignerObservationSha256", $SignerSha256) }
    if ($EnvironmentBindingsPath) { $runnerArguments += @("-EnvironmentBindingsPath", $EnvironmentBindingsPath, "-EnvironmentBindingsSha256", $EnvironmentBindingsSha256) }
    if ($CancelAfterMilliseconds -gt 0) { $runnerArguments += @("-TestCancelAfterMilliseconds", [string]$CancelAfterMilliseconds) }
    if ($Interrupt) { $runnerArguments += "-TestInterruptBeforePublish" }
    $outputLines = @(& pwsh @runnerArguments 2>&1)
    $childExit = $LASTEXITCODE
    $jsonText = @($outputLines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    try { $result = $jsonText | ConvertFrom-Json -Depth 64 }
    catch { throw "Runner did not emit one terminal JSON document (exit $childExit): $jsonText" }
    return [pscustomobject]@{ ExitCode = $childExit; Result = $result; Json = $jsonText }
}

function Assert-Terminal {
    param([object]$Invocation, [string]$ExpectedOperation, [string]$ExpectedStatus, [int]$ExpectedExit)
    Assert-True ($Invocation.ExitCode -eq $ExpectedExit) "Expected exit $ExpectedExit, got $($Invocation.ExitCode): $($Invocation.Json)"
    $expectedProperties = @("child_process", "invocation", "observation", "operation", "owner_payload", "profile", "reason_codes", "schema", "streams", "terminal_status")
    $actualProperties = @($Invocation.Result.PSObject.Properties.Name | Sort-Object)
    Assert-True (($actualProperties -join "|") -ceq ($expectedProperties -join "|")) "Terminal result property set is not exact."
    Assert-True ([string]$Invocation.Result.schema -ceq "rusty.morphospace.quest_build_terminal_result.v1") "Terminal result schema is incorrect."
    Assert-True ([string]$Invocation.Result.operation -ceq $ExpectedOperation) "Terminal operation is incorrect."
    Assert-True ([string]$Invocation.Result.terminal_status -ceq $ExpectedStatus) "Terminal status is incorrect."
    Assert-True ([string]$Invocation.Result.invocation.binding_sha256 -match "^[a-f0-9]{64}$") "Terminal invocation binding digest is missing."
    Assert-True ([int]$Invocation.Result.invocation.timeout_seconds -ge 1) "Terminal invocation budget is missing."
    $projectedEnvironment = $null -ne $Invocation.Result.observation.observation_id
    if ($projectedEnvironment) {
        Assert-True ($null -eq $Invocation.Result.invocation.child_environment_sha256 -and [int]$Invocation.Result.invocation.child_environment_variable_count -ge 0) "Projected child-environment evidence must be presence-only with a JSON-null value digest."
    } else {
        Assert-True ($null -eq $Invocation.Result.invocation.child_environment_sha256 -and [int]$Invocation.Result.invocation.child_environment_variable_count -eq 0 -and -not [bool]$Invocation.Result.child_process.started) "No-projection terminal evidence is inconsistent."
    }
    Assert-True ([string]$Invocation.Result.child_process.outcome -in @("not-started", "passed", "failed", "timed_out", "cancelled") -and [int]$Invocation.Result.child_process.timeout_seconds -eq [int]$Invocation.Result.invocation.timeout_seconds) "Terminal child-process evidence is invalid."
    $payloadProperties = @($Invocation.Result.owner_payload.PSObject.Properties.Name | Sort-Object)
    $expectedPayloadProperties = @("artifact", "environment", "execution_preflight_observation", "identity", "lockfiles", "output", "source", "source_composition", "toolchain")
    Assert-True (($payloadProperties -join "|") -ceq ($expectedPayloadProperties -join "|")) "Terminal owner payload property set is not exact."
    if ($null -ne $Invocation.Result.owner_payload.execution_preflight_observation) {
        $observation = $Invocation.Result.owner_payload.execution_preflight_observation
        Assert-True ([string]$observation.schema -ceq "rusty.morphospace.workflow.execution_preflight_observation.v1" -and [string]$observation.observation_id -match "^[a-z0-9][a-z0-9-]{1,127}$" -and [string]$Invocation.Result.observation.observation_id -ceq [string]$observation.observation_id -and [string]$Invocation.Result.observation.sha256 -match "^[a-f0-9]{64}$" -and [string]$Invocation.Result.observation.content_sha256 -match "^[a-f0-9]{64}$" -and [string]$Invocation.Result.observation.content_sha256 -ceq [string]$observation.content_sha256) "Terminal observation binding is invalid."
        foreach ($capability in @($observation.capabilities)) { Assert-True ([string]$capability.capability_id -match "^[a-z0-9][a-z0-9-]{1,127}$") "Observation capability identifier is not schema-valid." }
    }
    if ($ExpectedOperation -eq "preflight") {
        Assert-True ($ExpectedStatus -in @("passed", "contradiction", "incomplete")) "Preflight used a build-only terminal status."
    }
}


# Obviously synthetic literals live only in this owning test fixture. They are
# never profile/context/argv values or persisted environment observations.
function Get-PrivacyCanaries {
    return @('SYNTHETIC-NOT-A-CREDENTIAL::alpha-040::v1', 'SYNTHETIC-NOT-A-CREDENTIAL::bravo-041::v1')
}
function Assert-PrivacyPublicText([string]$Text) {
    foreach ($value in @(Get-PrivacyCanaries)) {
        $utf8 = [Text.Encoding]::UTF8.GetBytes($value)
        $utf16 = [Text.Encoding]::Unicode.GetBytes($value)
        $json = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $value -Compress))
        $forms = @($value, [Convert]::ToBase64String($utf8), [Convert]::ToBase64String($utf16))
        foreach ($bytes in @($utf8, $utf16, $json)) {
            $digest = [Security.Cryptography.SHA256]::HashData($bytes)
            $forms += [Convert]::ToHexString($digest).ToLowerInvariant()
            $forms += [Convert]::ToBase64String($digest)
        }
        foreach ($form in $forms) {
            if ($Text.IndexOf($form, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Synthetic credential representation leaked into public evidence' }
        }
    }
}
function Assert-PrivacyEvidence([object]$Value) {
    if ($null -eq $Value) { return }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ([string]$key -in @('value_sha256', 'environment_sha256', 'child_environment_sha256')) {
                if ($null -ne $Value[$key]) { throw 'Public environment value fingerprint must be JSON null' }
            }
            Assert-PrivacyEvidence $Value[$key]
        }
    } elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Assert-PrivacyEvidence $item }
    }
}
function Assert-PrivacyJson([string]$Text) {
    Assert-PrivacyPublicText $Text
    Assert-PrivacyEvidence (ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 100 -DateKind String)
}
function Set-PrivacyVariable([string]$Name, [AllowNull()][object]$Value) {
    if ($null -eq $Value) { [Environment]::SetEnvironmentVariable($Name, [System.Management.Automation.Language.NullString]::Value) }
    else { [Environment]::SetEnvironmentVariable($Name, [string]$Value) }
}

function Get-PrivacyParentFingerprint {
    # Private, transient comparison only; never returned as public evidence.
    $pairs = @([Environment]::GetEnvironmentVariables().GetEnumerator() | Sort-Object Key | ForEach-Object { [ordered]@{name=[string]$_.Key;value=[string]$_.Value} })
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($pairs | ConvertTo-Json -Compress -Depth 4)))).ToLowerInvariant()
}
function Get-PrivacyStableView([object]$Result) {
    return ([ordered]@{
        binding_sha256=$Result.invocation.binding_sha256
        child_environment_sha256=$Result.invocation.child_environment_sha256
        child_environment_variable_count=$Result.invocation.child_environment_variable_count
        environment=@($Result.owner_payload.environment)
        selected_context=@($Result.owner_payload.toolchain | Where-Object kind -CEQ 'selected-context')
        observation_content_sha256=$Result.observation.content_sha256
    } | ConvertTo-Json -Depth 64 -Compress)
}
function Assert-PrivacyRunner([object]$Invocation, [string]$Mode, [string]$Receipt='', [int]$ExpectedChildExit=13) {
    Assert-PrivacyJson $Invocation.Json
    Assert-True ($null-eq$Invocation.Result.invocation.child_environment_sha256) 'Public child-environment digest is not JSON null.'
    $observation=$Invocation.Result.owner_payload.execution_preflight_observation
    $policy=@($observation.values | Where-Object key -CEQ 'quest-build.environment-observation-policy')
    Assert-True ($policy.Count-eq1-and$policy[0].value-ceq'presence-only-v1') 'Presence-only preflight policy missing.'
    Assert-True (@($observation.values | Where-Object key -CEQ 'quest-build.child-environment-sha256').Count-eq0) 'Legacy environment fingerprint persisted.'
    if($Mode-ceq'Preflight') {
        Assert-True ($Invocation.ExitCode-eq0-and$Invocation.Result.terminal_status-ceq'passed'-and-not$Invocation.Result.child_process.started) 'Privacy Preflight unexpectedly failed or dispatched.'
    }else{
        $child=$Invocation.Result.child_process
        Assert-True ($Invocation.Result.schema-ceq'rusty.morphospace.quest_build_terminal_result.v2'-and$Invocation.ExitCode-eq1-and$Invocation.Result.terminal_status-ceq'failed') 'Synthetic retained failure terminal differs.'
        Assert-True ($child.started-and$child.process_reaped-and$child.stdout_eof-and$child.stderr_eof-and$child.raw_capture_complete-and$child.exit_code-eq$ExpectedChildExit-and-not$child.termination_requested-and-not$child.automatic_retry-and@($child.observer_errors).Count-eq0) 'Synthetic retained child lacks genuine exit/reap/dual EOF.'
        Assert-True (@($Invocation.Result.reason_codes | Where-Object {$_-ceq'child-exit-nonzero'}).Count-eq1) 'Failure was not the intended exact-value child exit.'
        Assert-True (Test-Path -LiteralPath $Receipt -PathType Leaf) 'Retained synthetic terminal was not persisted.'
        $stored=Get-Content -LiteralPath $Receipt -Raw
        Assert-PrivacyJson $stored
        Assert-True (($stored|ConvertFrom-Json -Depth 100).invocation.binding_sha256-ceq$Invocation.Result.invocation.binding_sha256) 'Published terminal binding differs.'
        foreach($stream in @($Invocation.Result.streams.stdout,$Invocation.Result.streams.stderr)) {
            Assert-True ((Get-Sha $stream.path)-ceq$stream.sha256-and(Get-Item -LiteralPath $stream.path).Length-eq$stream.size_bytes) 'Synthetic raw stream identity differs.'
            Assert-PrivacyPublicText (Get-Content -LiteralPath $stream.path -Raw)
        }
        if($ExpectedChildExit-eq13){
            Assert-True ((Get-Content -LiteralPath $Invocation.Result.streams.stdout.path -Raw).Trim()-ceq'privacy-child-exact-value:true') 'Child did not confirm independent exact-value assertion.'
            Assert-True ((Get-Content -LiteralPath $Invocation.Result.streams.stderr.path -Raw).Trim()-ceq'privacy-child-intentional-failure:true') 'Synthetic failure stderr differs.'
        }else{
            Assert-True ($ExpectedChildExit-eq97-and$Invocation.Result.streams.stdout.size_bytes-eq0-and$Invocation.Result.streams.stderr.size_bytes-eq0) 'Mismatch receiver falsely confirmed exact delivery.'
        }
        Assert-True ($null-eq$Invocation.Result.owner_payload.artifact) 'Synthetic failure acquired artifact credit.'
    }
}
function New-PrivacySeedContext {
    if([bool]$SeedContextPath-ne[bool]$SeedContextSha256){throw 'Seed context path and hash must be paired'}
    if($SeedContextPath){
        Assert-True ((Get-Sha $SeedContextPath)-ceq$SeedContextSha256) 'Privacy seed context identity differs.'
        return [pscustomobject]@{Path=$SeedContextPath;Sha256=$SeedContextSha256}
    }
    # Registered CI has no authored context. Declare only actual OS facts and
    # actual existing Git/pwsh, preserving the inherited PATH (no masking).
    $environment=@{}
    foreach($name in @('HOME','USERPROFILE','SYSTEMROOT','SYSTEMDRIVE','WINDIR','COMSPEC','PATHEXT','TEMP','TMP','TMPDIR','PATH')) {
        $value=[Environment]::GetEnvironmentVariable($name)
        if($null-ne$value){$environment[$name]=$value}
    }
    if($IsWindows){
        if(-not$environment.ContainsKey('SYSTEMDRIVE')){$environment.SYSTEMDRIVE=[IO.Path]::GetPathRoot([string]$environment.SYSTEMROOT).TrimEnd('\')}
        if(-not$environment.ContainsKey('USERPROFILE')){$environment.USERPROFILE=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)}
    }
    # Drop only invalid/nonexistent entries: no real Application or its ordering
    # changes, including multiple installed pwsh/Git applications. Do not mask.
    if($environment.ContainsKey('PATH')){
        $validEntries=@($environment.PATH.Split([IO.Path]::PathSeparator)|Where-Object {$_-and[IO.Path]::IsPathFullyQualified($_)-and(Test-Path -LiteralPath $_ -PathType Container -ErrorAction SilentlyContinue)})
        $environment.PATH=$validEntries-join[IO.Path]::PathSeparator
    }
    $gitTool=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
    $paths=@{git=$gitTool;pwsh=[Environment]::ProcessPath};$tools=@{}
    foreach($id in $paths.Keys){$tools[$id]=[ordered]@{path=[IO.Path]::GetFullPath($paths[$id]);sha256=(Get-Sha $paths[$id])}}
    $context=[ordered]@{schema='rusty.morphospace.local_quest_build_context.v1';environment=$environment;tools=$tools}
    $path=Join-Path $profileRoot 'privacy-context.json'
    Write-Utf8 $path ($context|ConvertTo-Json -Depth 16)
    return [pscustomobject]@{Path=$path;Sha256=(Get-Sha $path)}
}

function Invoke-ProviderControls {
    # This transport fixture models the Quest assertion API. The Quest owner
    # tests its canonical fingerprint/overlay algorithm; WEF must not copy it.
    $modulePath=Join-Path $externalSourceRoot 'tools/lib/SourceComposition.psm1'
    Write-Utf8 $modulePath @'
function Assert-QuestBuildSourceCompositionCurrent {
 param($Composition,[switch]$AllowWorkingTreeChanges)
 if($Composition.fingerprint -cne ('f'*64)){throw 'MODELED provider fingerprint differs'}
 foreach($row in $Composition.repositories){
  if((-not $row.tracked_worktree_clean)-and-not $AllowWorkingTreeChanges){throw 'MODELED provider requires clean sources'}
  $marker=if($row.repository_id-ceq'rusty-quest'){'qfm-marker.txt'}else{'AndroidManifest.xml'}
  if(-not $row.tracked_worktree_clean-and(Get-FileHash -LiteralPath (Join-Path $row.repository $marker) -Algorithm SHA256).Hash.ToLowerInvariant()-cne$row.worktree_overlay_sha256){throw 'MODELED provider overlay drift'}
 }
}
Export-ModuleMember -Function Assert-QuestBuildSourceCompositionCurrent
'@
    & git -C $externalSourceRoot add tools/lib/SourceComposition.psm1
    & git -C $externalSourceRoot commit -qm 'MODELED fixed provider API fixture'
    $qr=((& git -C $externalSourceRoot rev-parse HEAD)-join '').Trim()
    $qt=((& git -C $externalSourceRoot rev-parse 'HEAD^{tree}')-join '').Trim()
    $pr=((& git -C $testRoot rev-parse HEAD)-join '').Trim()
    $pt=((& git -C $testRoot rev-parse 'HEAD^{tree}')-join '').Trim()
    $manifest=Join-Path $testRoot 'AndroidManifest.xml';$qm=Join-Path $externalSourceRoot 'qfm-marker.txt'
    $savedManifest=[IO.File]::ReadAllBytes($manifest);$savedQm=[IO.File]::ReadAllBytes($qm)
    $providerPath=Join-Path $profileRoot 'quest-provider.json'
    $bindingPath=Join-Path $profileRoot 'provider-bindings.json'
    $binding=[ordered]@{schema='rusty.morphospace.local_quest_build_environment.v1';bindings=@([ordered]@{id='quest-root';path=$externalSourceRoot;kind='directory';git_revision=$qr;git_tree=$qt})}
    Write-Utf8 $bindingPath ($binding|ConvertTo-Json -Depth 20)
    $p=New-Profile
    $p.environment=[ordered]@{QUEST_ROOT='quest-root'}
    $p.preflight.source_composition=[ordered]@{source=[ordered]@{git_revision=$pr;git_tree=$pt;require_clean=$false};external_sources=@([ordered]@{source_id='rusty-quest';binding_id='quest-root';git_revision=$qr;git_tree=$qt});provider_document=[ordered]@{path=$providerPath;sha256='0'*64;provider_binding_id='quest-root';provider_module_sha256=Get-Sha $modulePath}}
    $options=@{EnvironmentBindingsPath=$bindingPath;EnvironmentBindingsSha256=Get-Sha $bindingPath}
    if($SeedContextPath){$options.BuildContextPath=$SeedContextPath;$options.BuildContextSha256=$SeedContextSha256}
    try {
        Write-Utf8 $manifest '<manifest package="example.fixture" /><!-- local iteration -->'
        Write-Utf8 $qm 'local Quest iteration'
        $doc=[ordered]@{schema='rusty.quest.apk_source_composition.v2';fingerprint='f'*64;packages=@('MODELED-transport');repositories=@(
            [ordered]@{repository_id='rusty-quest';role='primary';repository=$externalSourceRoot;commit=$qr;tree=$qt;tracked_worktree_clean=$false;worktree_overlay_sha256=Get-Sha $qm},
            [ordered]@{repository_id='private-fixture';role='app-owned-input';repository=$testRoot;commit=$pr;tree=$pt;tracked_worktree_clean=$false;worktree_overlay_sha256=Get-Sha $manifest})}
        Write-Utf8 $providerPath ($doc|ConvertTo-Json -Depth 20)
        $p.preflight.source_composition.provider_document.sha256=Get-Sha $providerPath
        $positive=Invoke-Runner Preflight (Write-Profile $p) @options
        Assert-Terminal $positive preflight passed 0
        Assert-True ($positive.Result.owner_payload.source_composition.provider_document.fingerprint-ceq$doc.fingerprint) 'Provider identity missing from bound source evidence.'
        # Two legitimate build inputs can refer to one canonical provider row.
        $aliasBinding=$binding|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable -Depth 20
        $aliasBinding.bindings+=@([ordered]@{id='native-quest-root';path=$externalSourceRoot;kind='directory';git_revision=$qr;git_tree=$qt})
        $aliasPath=Join-Path $profileRoot 'alias-bindings.json';Write-Utf8 $aliasPath ($aliasBinding|ConvertTo-Json -Depth 20)
        $aliasProfile=$p|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable -Depth 20
        $aliasProfile.environment.NATIVE_QUEST_ROOT='native-quest-root'
        $aliasProfile.preflight.source_composition.external_sources+=@([ordered]@{source_id='native-quest';binding_id='native-quest-root';git_revision=$qr;git_tree=$qt})
        $aliasOptions=$options.Clone();$aliasOptions.EnvironmentBindingsPath=$aliasPath;$aliasOptions.EnvironmentBindingsSha256=Get-Sha $aliasPath
        Assert-Terminal (Invoke-Runner Preflight (Write-Profile $aliasProfile) @aliasOptions) preflight passed 0
        # The selected tooling checkout is not necessarily the primary app input.
        # Keep the transport model explicit; the Quest owner tests real identities.
        $toolingRoot=Join-Path $profileRoot 'selected-provider-tooling'
        New-Item -ItemType Directory -Path $toolingRoot -Force|Out-Null
        & git -C $toolingRoot init -q
        & git -C $toolingRoot config user.name 'Provider transport fixture'
        & git -C $toolingRoot config user.email 'fixture@example.invalid'
        $toolingModule=Join-Path $toolingRoot 'tools/lib/SourceComposition.psm1'
        Write-Utf8 $toolingModule ([IO.File]::ReadAllText($modulePath))
        Write-Utf8 (Join-Path $toolingRoot 'AndroidManifest.xml') '<manifest package="example.tooling" />'
        & git -C $toolingRoot add .
        & git -C $toolingRoot commit -qm 'MODELED separate provider tooling fixture'
        Assert-True ($LASTEXITCODE-eq0) 'Separate provider tooling Git fixture failed.'
        $tr=((& git -C $toolingRoot rev-parse HEAD)-join '').Trim()
        $tt=((& git -C $toolingRoot rev-parse 'HEAD^{tree}')-join '').Trim()
        $separatedDoc=$doc|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable -Depth 20
        $separatedDoc.repositories+=@([ordered]@{repository_id='tooling-fixture';role='app-owned-input';repository=$toolingRoot;commit=$tr;tree=$tt;tracked_worktree_clean=$true;worktree_overlay_sha256=''})
        $separatedBinding=$binding|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable -Depth 20
        $separatedBinding.bindings+=@([ordered]@{id='tooling-root';path=$toolingRoot;kind='directory';git_revision=$tr;git_tree=$tt})
        $separatedPath=Join-Path $profileRoot 'separated-provider-bindings.json'
        Write-Utf8 $separatedPath ($separatedBinding|ConvertTo-Json -Depth 20)
        $separatedProfile=$p|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable -Depth 20
        $separatedProfile.environment.TOOLING_ROOT='tooling-root'
        $separatedProfile.preflight.source_composition.external_sources+=@([ordered]@{source_id='selected-tooling';binding_id='tooling-root';git_revision=$tr;git_tree=$tt})
        $separatedProfile.preflight.source_composition.provider_document.provider_binding_id='tooling-root'
        $separatedProfile.preflight.source_composition.provider_document.provider_module_sha256=Get-Sha $toolingModule
        $separatedOptions=$options.Clone();$separatedOptions.EnvironmentBindingsPath=$separatedPath;$separatedOptions.EnvironmentBindingsSha256=Get-Sha $separatedPath
        Write-Utf8 $providerPath ($separatedDoc|ConvertTo-Json -Depth 20)
        $separatedProfile.preflight.source_composition.provider_document.sha256=Get-Sha $providerPath
        $separated=Invoke-Runner Preflight (Write-Profile $separatedProfile) @separatedOptions
        Assert-Terminal $separated preflight passed 0
        Assert-True ($separated.Result.owner_payload.source_composition.provider_document.provider_binding_id-ceq'tooling-root') 'Separate selected tooling identity was substituted with the primary input.'
        foreach($damage in @('missing-tooling-row','tooling-base','tooling-root','duplicate-tooling-row','tooling-module-hash','tooling-primary')) {
            $bad=$separatedProfile|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable -Depth 20
            $badDoc=$separatedDoc|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable -Depth 20
            switch($damage) {
                'missing-tooling-row' {$badDoc.repositories=@($badDoc.repositories|Where-Object repository_id -CNE 'tooling-fixture')}
                'tooling-base' {$badDoc.repositories[2].commit='0'*40}
                'tooling-root' {$badDoc.repositories[2].repository=$profileRoot}
                'duplicate-tooling-row' {$badDoc.repositories+=@($badDoc.repositories[2])}
                'tooling-module-hash' {$bad.preflight.source_composition.provider_document.provider_module_sha256='0'*64}
                'tooling-primary' {$badDoc.repositories[2].role='primary'}
            }
            Write-Utf8 $providerPath ($badDoc|ConvertTo-Json -Depth 20)
            $bad.preflight.source_composition.provider_document.sha256=Get-Sha $providerPath
            Assert-Terminal (Invoke-Runner Preflight (Write-Profile $bad) @separatedOptions) preflight contradiction 2
        }
        Write-Utf8 $providerPath ($doc|ConvertTo-Json -Depth 20)
        $p.preflight.source_composition.provider_document.sha256=Get-Sha $providerPath
        $goodJson=$doc|ConvertTo-Json -Depth 20
        $goodProfile=$p|ConvertTo-Json -Depth 20
        foreach($damage in @('document-hash','module-hash','missing-binding','no-bindings','duplicate-id','duplicate-root','wrong-base','unmatched-root','wrong-primary','fingerprint','candidate','require-clean')) {
            $bad=$goodProfile|ConvertFrom-Json -AsHashtable -Depth 30
            $badDoc=$goodJson|ConvertFrom-Json -AsHashtable -Depth 30
            switch($damage) {
                'document-hash' {$bad.preflight.source_composition.provider_document.sha256='0'*64}
                'module-hash' {$bad.preflight.source_composition.provider_document.provider_module_sha256='0'*64}
                'missing-binding' {$bad.preflight.source_composition.provider_document.provider_binding_id='absent'}
                'no-bindings' {$bad.environment=[ordered]@{}}
                'duplicate-id' {$badDoc.repositories[1].repository_id='rusty-quest'}
                'duplicate-root' {$badDoc.repositories[1].repository=$externalSourceRoot}
                'wrong-base' {$badDoc.repositories[1].commit='0'*40}
                'unmatched-root' {$badDoc.repositories[1].repository=$profileRoot}
                'wrong-primary' {$badDoc.repositories[0].role='path-dependency'}
                'fingerprint' {$badDoc.fingerprint='0'*64}
                'candidate' {$bad.preflight.output.lane='candidate';$bad.preflight.output.collision_policy='content-addressed';$bad.artifact.relative_path='out/candidate-{content_sha256}.apk'}
                'require-clean' {$bad.preflight.source_composition.source.require_clean=$true}
            }
            Write-Utf8 $providerPath ($badDoc|ConvertTo-Json -Depth 20)
            if($damage-cne'document-hash'){$bad.preflight.source_composition.provider_document.sha256=Get-Sha $providerPath}
            if($damage-ceq'no-bindings') {
                $noBindingOptions=$options.Clone();$noBindingOptions.Remove('EnvironmentBindingsPath');$noBindingOptions.Remove('EnvironmentBindingsSha256')
                Assert-Terminal (Invoke-Runner Preflight (Write-Profile $bad) @noBindingOptions) preflight contradiction 2
            } else {Assert-Terminal (Invoke-Runner Preflight (Write-Profile $bad) @options) preflight contradiction 2}
        }
        Write-Utf8 $providerPath $goodJson
        $p.preflight.source_composition.provider_document.sha256=Get-Sha $providerPath
        $moduleBytes=[IO.File]::ReadAllBytes($modulePath)
        try {
            Write-Utf8 $modulePath 'function Other-Export {}; Export-ModuleMember -Function Other-Export'
            $p.preflight.source_composition.provider_document.provider_module_sha256=Get-Sha $modulePath
            Assert-Terminal (Invoke-Runner Preflight (Write-Profile $p) @options) preflight contradiction 2
        } finally {[IO.File]::WriteAllBytes($modulePath,$moduleBytes)}
        $p.preflight.source_composition.provider_document.provider_module_sha256=Get-Sha $modulePath
        foreach($exit in @(0,13)) {
            $p.arguments=@("out/provider-$exit.apk",'-ProviderMarker',$qm,'-ExitCode',[string]$exit)
            $p.artifact.relative_path="out/provider-$exit.apk"
            $invocation=Invoke-Runner Build (Write-Profile $p) @options -Receipt (Join-Path $profileRoot "provider-$exit.receipt.json") -Retained
            Assert-True ($invocation.ExitCode-eq1-and$invocation.Result.child_process.started-and$invocation.Result.child_process.exit_code-eq$exit-and$invocation.Result.reason_codes-ccontains'source-provider-drift') 'Post-child provider drift discarded or relabeled actual child evidence.'
            Assert-True ($invocation.Result.streams.captured-and$invocation.Result.child_process.raw_capture_complete-and$invocation.Result.child_process.process_reaped) 'Provider drift lost retained child raw closure.'
            if($exit-eq13){Assert-True ($invocation.Result.reason_codes-ccontains'child-exit-nonzero') 'Provider drift masked original child failure.'}
            Write-Utf8 $qm 'local Quest iteration'
        }
        Write-Host 'MODELED provider transport: authenticated local source/external dirt accepted.'
    } finally {
        [IO.File]::WriteAllBytes($manifest,$savedManifest);[IO.File]::WriteAllBytes($qm,$savedQm)
        foreach($relative in @('out/provider-0.apk','out/provider-13.apk','captured.txt')) {
            $owned=Join-Path $testRoot $relative
            if(Test-Path -LiteralPath $owned -PathType Leaf){Remove-Item -LiteralPath $owned -Force}
        }
    }
}

try {
    New-Item -ItemType Directory -Path (Join-Path $testRoot "out") -Force | Out-Null
    Write-Utf8 (Join-Path $testRoot "AndroidManifest.xml") "<manifest package=\"example.fixture\" />`n"
    Write-Utf8 (Join-Path $testRoot "rust-toolchain.toml") "[toolchain]`nchannel = \"1.97.1\"`n"
    Write-Utf8 (Join-Path $testRoot "build.ps1") @'
param(
    [string]$Output,
    [string]$Text = "",
    [switch]$Large,
    [switch]$Sleep,
    [string]$ProviderMarker='',
    [int]$ExitCode=0
)
if ($Sleep) { [Threading.Thread]::Sleep(5000) }
if ($Large) {
    $chunk = "x" * 32768
    for ($index = 0; $index -lt 32; $index++) {
        [Console]::Out.Write($chunk)
        [Console]::Error.Write($chunk)
    }
}
$outputPath = if ($env:MORPHOSPACE_CONTENT_ADDRESSED_ARTIFACT) { $env:MORPHOSPACE_CONTENT_ADDRESSED_ARTIFACT } else { Join-Path $PSScriptRoot $Output }
$outputParent = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputParent)) { New-Item -ItemType Directory -Path $outputParent -Force | Out-Null }
[System.IO.File]::WriteAllBytes($outputPath, [byte[]](1, 2, 3, 4))
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot "captured.txt"), "output=$Output|text=$Text|pager=$env:GIT_PAGER", [System.Text.UTF8Encoding]::new($false))
if($ProviderMarker){[IO.File]::WriteAllText($ProviderMarker,'MODELED post-child source drift')}
exit $ExitCode
'@
    & git -C $testRoot init -q
    & git -C $testRoot config user.email "fixture@example.invalid"
    & git -C $testRoot config user.name "Quest Build Fixture"
    & git -C $testRoot add AndroidManifest.xml rust-toolchain.toml build.ps1
    & git -C $testRoot commit -qm "fixture baseline"

    $base = New-Profile
    $baseRecord = Write-Profile $base
    $beforeStatus = (& git -C $testRoot status --porcelain=v1 -z) -join ""
    $firstPreflight = Invoke-Runner "Preflight" $baseRecord
    Assert-Terminal $firstPreflight "preflight" "passed" 0
    Start-Sleep -Milliseconds 10
    $secondPreflight = Invoke-Runner "Preflight" $baseRecord
    Assert-Terminal $secondPreflight "preflight" "passed" 0
    Assert-True ($firstPreflight.Result.invocation.binding_sha256 -ceq $secondPreflight.Result.invocation.binding_sha256) "Unchanged preflight invocation digest was not deterministic."
    Assert-True ($firstPreflight.Result.observation.content_sha256 -ceq $secondPreflight.Result.observation.content_sha256) "Observation content identity changed without a semantic input change."
    Assert-True ($firstPreflight.Result.observation.sha256 -cne $secondPreflight.Result.observation.sha256) "Timestamped receipt identity did not remain distinct across observations."
    $afterStatus = (& git -C $testRoot status --porcelain=v1 -z) -join ""
    Assert-True ($beforeStatus -ceq $afterStatus) "Preflight changed source bytes or Git state."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "out\fixture.apk"))) "Preflight created the build artifact."

    New-Item -ItemType Directory -Path $externalSourceRoot -Force | Out-Null
    Write-Utf8 (Join-Path $externalSourceRoot "qfm-marker.txt") "fixture QFM source composition"
    & git -C $externalSourceRoot init -q
    & git -C $externalSourceRoot config user.email "fixture-qfm@example.invalid"
    & git -C $externalSourceRoot config user.name "Quest File Manager Fixture"
    & git -C $externalSourceRoot add qfm-marker.txt
    & git -C $externalSourceRoot commit -qm "QFM fixture baseline"
    $externalRevision = ((& git -C $externalSourceRoot rev-parse HEAD) -join "").Trim()
    $externalTree = ((& git -C $externalSourceRoot rev-parse "HEAD^{tree}") -join "").Trim()
    $sourceRevision = ((& git -C $testRoot rev-parse HEAD) -join "").Trim()
    $sourceTree = ((& git -C $testRoot rev-parse "HEAD^{tree}") -join "").Trim()
    Invoke-ProviderControls
    if($ProviderOnly){return}
    $externalRevision = ((& git -C $externalSourceRoot rev-parse HEAD) -join "").Trim()
    $externalTree = ((& git -C $externalSourceRoot rev-parse "HEAD^{tree}") -join "").Trim()
    $environmentBindingsPath = Join-Path $profileRoot "environment-bindings.json"
    $environmentBindings = [ordered]@{
        schema = "rusty.morphospace.local_quest_build_environment.v1"
        bindings = @([ordered]@{ id = "qfm-source"; path = $externalSourceRoot; kind = "directory"; git_revision = $externalRevision; git_tree = $externalTree })
    }
    Write-Utf8 $environmentBindingsPath ($environmentBindings | ConvertTo-Json -Depth 16)
    $twoOwner = New-Profile
    $twoOwner.environment = [ordered]@{ QFM_SOURCE = "qfm-source" }
    $twoOwner.preflight.source_composition = [ordered]@{
        source = [ordered]@{ git_revision = $sourceRevision; git_tree = $sourceTree; require_clean = $true }
        external_sources = @([ordered]@{ source_id = "quest-file-manager"; binding_id = "qfm-source"; git_revision = $externalRevision; git_tree = $externalTree })
    }
    $twoOwnerRecord = Write-Profile $twoOwner
    $twoOwnerPreflight = Invoke-Runner "Preflight" $twoOwnerRecord -EnvironmentBindingsPath $environmentBindingsPath -EnvironmentBindingsSha256 (Get-Sha $environmentBindingsPath)
    Assert-Terminal $twoOwnerPreflight "preflight" "passed" 0
    Assert-True (@($twoOwnerPreflight.Result.owner_payload.source_composition.external_sources).Count -eq 1 -and [string]$twoOwnerPreflight.Result.owner_payload.source_composition.external_sources[0].source_id -ceq "quest-file-manager") "Two-owner source composition evidence is incomplete."
    $twoOwner.preflight.source_composition.external_sources[0].git_tree = (("0" * 40) -join "")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $twoOwner) -EnvironmentBindingsPath $environmentBindingsPath -EnvironmentBindingsSha256 (Get-Sha $environmentBindingsPath)) "preflight" "contradiction" 2

    $candidate = New-Profile
    $candidate.preflight.output.lane = "candidate"
    $candidate.preflight.output.collision_policy = "content-addressed"
    $candidate.artifact.relative_path = "out\candidate-{content_sha256}.apk"
    $candidateRecord = Write-Profile $candidate
    $candidatePreflight = Invoke-Runner "Preflight" $candidateRecord
    Assert-Terminal $candidatePreflight "preflight" "passed" 0
    $candidateReceipt = Join-Path $testRoot "candidate-receipt.json"
    $candidateBuild = Invoke-Runner "Build" $candidateRecord -Receipt $candidateReceipt
    Assert-Terminal $candidateBuild "build" "passed" 0
    Assert-PrivacyJson $candidatePreflight.Json
    Assert-PrivacyJson $candidateBuild.Json
    $derived=@($candidateBuild.Result.owner_payload.environment|Where-Object source -CEQ 'wrapper-derived')
    Assert-True ($derived.Count-eq1-and$derived[0].variable-ceq'MORPHOSPACE_CONTENT_ADDRESSED_ARTIFACT'-and$derived[0].present-and$null-eq$derived[0].value_sha256) 'Wrapper-derived environment row is not presence-only.'
    $candidateArtifact = [string]$candidateBuild.Result.owner_payload.output.effective_artifact
    Assert-True ((Split-Path -Leaf $candidateArtifact) -ceq "candidate-$($candidateBuild.Result.invocation.binding_sha256).apk") "Content-addressed output path was not derived from the binding digest."
    Assert-True ([string]$candidateBuild.Result.owner_payload.artifact.kind -ceq "single-base-apk" -and [string]$candidateBuild.Result.owner_payload.artifact.path -ceq $candidateArtifact -and (Test-Path -LiteralPath $candidateArtifact)) "Candidate build did not retain one derived base APK proof."
    Write-Utf8 (Join-Path $testRoot "candidate-dirty.txt") "candidate source drift"
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $candidate)) "preflight" "contradiction" 2
    Remove-Item -LiteralPath (Join-Path $testRoot "candidate-dirty.txt") -Force
    foreach ($candidateEphemera in @($candidateArtifact, (Join-Path $testRoot "captured.txt"), $candidateReceipt, "$candidateReceipt.stdout.bin", "$candidateReceipt.stderr.bin")) {
        if (Test-Path -LiteralPath $candidateEphemera) { Remove-Item -LiteralPath $candidateEphemera -Force }
    }

    $missingApplication = New-Profile
    $missingApplication.preflight.identity.application_id = ""
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $missingApplication)) "preflight" "contradiction" 2

    $missingToolchain = New-Profile
    $missingToolchain.preflight.toolchain.repository_files = @("missing-toolchain.toml")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $missingToolchain)) "preflight" "contradiction" 2

    $wrongToolchainTarget = New-Profile
    $wrongToolchainTarget.preflight.toolchain.required_targets = @("not-a-real-rust-target")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $wrongToolchainTarget)) "preflight" "contradiction" 2

    $missingScript = New-Profile
    $missingScript.executable = "does-not-exist.ps1"
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $missingScript)) "preflight" "contradiction" 2

    $wrongDependency = New-Profile
    $wrongDependency.preflight.manifest_relative_dependencies = @("missing/AndroidManifest.xml")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $wrongDependency)) "preflight" "contradiction" 2

    $missingLockfile = New-Profile
    $missingLockfile.preflight.lockfiles = @("missing/Cargo.lock")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $missingLockfile)) "preflight" "contradiction" 2

    $savedPager = $env:GIT_PAGER
    try {
        $env:GIT_PAGER = "fixture-prohibited-pager"
        $prohibitedEnvironment = New-Profile
        $prohibitedEnvironment.preflight.environment_projection.prohibited_parent_variables = @("GIT_PAGER")
        Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $prohibitedEnvironment)) "preflight" "contradiction" 2
    } finally { $env:GIT_PAGER = $savedPager }

    [System.IO.File]::WriteAllBytes((Join-Path $testRoot "out\fixture.apk"), [byte[]](9))
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile (New-Profile))) "preflight" "contradiction" 2
    Remove-Item -LiteralPath (Join-Path $testRoot "out\fixture.apk") -Force

    $incompleteSigner = New-Profile
    $incompleteSigner.preflight.identity.expected_current_signer_sha256 = @(("a" * 64) -join "")
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $incompleteSigner)) "preflight" "incomplete" 3

    $mismatchSigner = New-Profile
    $mismatchSigner.preflight.identity.expected_current_signer_sha256 = @(("a" * 64) -join "")
    $signerPath = Join-Path $testRoot "signer.json"
    Write-Utf8 $signerPath (([ordered]@{ schema = "rusty.morphospace.quest_signer_observation.v1"; application_id = "example.fixture"; current_signer_sha256 = @(("b" * 64) -join "") }) | ConvertTo-Json -Depth 8)
    Assert-Terminal (Invoke-Runner "Preflight" (Write-Profile $mismatchSigner) -SignerPath $signerPath -SignerSha256 (Get-Sha $signerPath)) "preflight" "contradiction" 2

    $quoted = New-Profile -ArtifactRelativePath "out\quoted.apk" -Arguments @("out\quoted.apk", 'value with spaces and "quotes"')
    $quotedRecord = Write-Profile $quoted
    $savedPager = $env:GIT_PAGER
    try {
        $env:GIT_PAGER = "ambient-control-must-not-reach-child"
        $quotedReceipt = Join-Path $testRoot "quoted-receipt.json"
        $quotedBuild = Invoke-Runner "Build" $quotedRecord -Receipt $quotedReceipt
        Assert-Terminal $quotedBuild "build" "passed" 0
        Assert-True (Test-Path -LiteralPath $quotedReceipt) "Passed build did not atomically publish its terminal result."
        $storedReceipt = Get-Content -Raw -LiteralPath $quotedReceipt | ConvertFrom-Json -Depth 64
        Assert-True ($storedReceipt.terminal_status -eq "passed") "Published terminal result is invalid."
        Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $testRoot "captured.txt")) -match 'text=value with spaces and "quotes"\|pager=$') "Argument quoting or child environment projection drifted."
        Assert-True ((Get-Sha $quotedBuild.Result.streams.stdout.path) -ceq $quotedBuild.Result.streams.stdout.sha256) "stdout digest is not bound."
        Assert-True ((Get-Sha $quotedBuild.Result.streams.stderr.path) -ceq $quotedBuild.Result.streams.stderr.sha256) "stderr digest is not bound."
    } finally { $env:GIT_PAGER = $savedPager }

    $large = New-Profile -ArtifactRelativePath "out\large.apk" -Arguments @("out\large.apk", "", "-Large")
    $largeBuild = Invoke-Runner "Build" (Write-Profile $large) -Receipt (Join-Path $testRoot "large-receipt.json")
    Assert-Terminal $largeBuild "build" "passed" 0
    Assert-True ($largeBuild.Result.streams.stdout.size_bytes -ge 1048576 -and $largeBuild.Result.streams.stderr.size_bytes -ge 1048576) "Large simultaneous stdout/stderr streams were not retained."

    $timeout = New-Profile -ArtifactRelativePath "out\timeout.apk" -Arguments @("out\timeout.apk", "", "-Sleep")
    $timeoutBuild = Invoke-Runner "Build" (Write-Profile $timeout) -Receipt (Join-Path $testRoot "timeout-receipt.json") -Timeout 1
    Assert-Terminal $timeoutBuild "build" "timed_out" 1

    $cancel = New-Profile -ArtifactRelativePath "out\cancel.apk" -Arguments @("out\cancel.apk", "", "-Sleep")
    $cancelBuild = Invoke-Runner "Build" (Write-Profile $cancel) -Receipt (Join-Path $testRoot "cancel-receipt.json") -CancelAfterMilliseconds 100
    Assert-Terminal $cancelBuild "build" "cancelled" 1

    $interrupted = New-Profile -ArtifactRelativePath "out\interrupted.apk" -Arguments @("out\interrupted.apk")
    $interruptedReceipt = Join-Path $testRoot "interrupted-receipt.json"
    $interruptedBuild = Invoke-Runner "Build" (Write-Profile $interrupted) -Receipt $interruptedReceipt -Interrupt
    Assert-True ($interruptedBuild.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $interruptedReceipt)) "Interrupted terminal publication exposed a final result file."
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter "interrupted-receipt.json.*.tmp" -File).Count -eq 0) "Interrupted terminal publication retained a temporary result file."

    $progressBase = Join-Path $testRoot "progress-receipt.json"
    $missingProgress = Read-Progress $progressBase
    Assert-True ($missingProgress.schema -ceq "rusty.morphospace.quest_build_progress_observation.v1" -and
        $missingProgress.receipt_present -eq $false -and
        $missingProgress.streams[0].phase -ceq "absent" -and
        $missingProgress.streams[1].phase -ceq "absent") "Absent progress was not explicit."
    $progressTemp = "$progressBase.stdout.bin.$([guid]::NewGuid().ToString('N')).tmp"
    $progressWriter = [IO.File]::Open($progressTemp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $progressBytes = [Text.UTF8Encoding]::new($false).GetBytes("BUILD_PHASE native-compile-link status=pass`n" + ('x' * 9000) + "`n")
        $progressWriter.Write($progressBytes, 0, $progressBytes.Length)
        $progressWriter.Flush($true)
        $liveProgress = Read-Progress $progressBase
        Assert-True ($liveProgress.streams[0].phase -ceq "active_temp" -and
            $liveProgress.streams[0].read_state -ceq "readable" -and
            $liveProgress.streams[0].bytes_observed -eq $progressBytes.Length -and
            $liveProgress.streams[0].last_line.Length -le 200 -and
            $liveProgress.receipt_present -eq $false) "Read-shared live progress was not bounded or was mistaken for a receipt."
        $secondTemp = "$progressBase.stdout.bin.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($secondTemp, "second", [Text.UTF8Encoding]::new($false))
        $ambiguousProgress = Read-Progress $progressBase
        Assert-True ($ambiguousProgress.streams[0].phase -ceq "ambiguous_temp" -and
            $ambiguousProgress.streams[0].read_state -ceq "not_read") "Ambiguous temporary progress was read."
    } finally { $progressWriter.Dispose() }
    $exclusiveBase = Join-Path $testRoot "exclusive-receipt.json"
    $exclusiveTemp = "$exclusiveBase.stdout.bin.$([guid]::NewGuid().ToString('N')).tmp"
    $exclusiveWriter = [IO.File]::Open($exclusiveTemp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $exclusiveWriter.WriteByte(65)
        $exclusiveWriter.Flush($true)
        $exclusiveProgress = Read-Progress $exclusiveBase
        Assert-True ($exclusiveProgress.streams[0].phase -ceq "active_temp" -and
            $exclusiveProgress.streams[0].read_state -ceq "read_unavailable") "Exclusive live writer was treated as readable."
    } finally { $exclusiveWriter.Dispose() }
    [IO.File]::WriteAllText("$progressBase.stdout.bin", "BUILD_PHASE final status=pass`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($progressBase, "retained terminal receipt", [Text.UTF8Encoding]::new($false))
    $finalProgress = Read-Progress $progressBase
    Assert-True ($finalProgress.receipt_present -eq $true -and
        $finalProgress.streams[0].phase -ceq "final" -and
        $finalProgress.streams[0].read_state -ceq "readable" -and
        $finalProgress.streams[0].last_milestone -cmatch "BUILD_PHASE final") "Final stream did not supersede temporary streams."
    $raceBase = Join-Path $testRoot "race-receipt.json"
    $raceTemp = "$raceBase.stdout.bin.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($raceTemp, "BUILD_PHASE temporary status=pass`n", [Text.UTF8Encoding]::new($false))
    . $progressInspector -BaseReceiptPath $raceBase | Out-Null
    $selectedBeforeRename = Select-ProgressStream $raceBase "stdout"
    Assert-True ($selectedBeforeRename.phase -ceq "active_temp") "Race fixture did not select the temporary stream."
    Move-Item -LiteralPath $raceTemp -Destination "$raceBase.stdout.bin"
    $staleSelection = Read-ProgressStreamSelection $selectedBeforeRename "stdout"
    Assert-True ($staleSelection.phase -ceq "active_temp" -and
        $staleSelection.read_state -ceq "read_unavailable" -and
        $null -eq $staleSelection.last_write_utc) "Temp-to-final rename changed selected phase or raised a metadata error."
    $afterRename = Read-Progress $raceBase
    Assert-True ($afterRename.streams[0].phase -ceq "final" -and
        $afterRename.streams[0].read_state -ceq "readable") "Fresh selection did not observe finalized stream."


    # Same child bytes/profile/context/argv across A/B. Only the synthetic value
    # and its nonsecret expected-case selector differ in transient parent env.
    Write-Utf8 (Join-Path $testRoot 'privacy-child.ps1') @'
$expected = switch ([Environment]::GetEnvironmentVariable('WEF_PRIVACY_CASE')) {
    'A' { 'SYNTHETIC-NOT-A-CREDENTIAL::alpha-040::v1' }
    'B' { 'SYNTHETIC-NOT-A-CREDENTIAL::bravo-041::v1' }
    default { $null }
}
if ($null-eq$expected-or[Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')-cne$expected) { exit 97 }
[Console]::Out.WriteLine('privacy-child-exact-value:true')
[Console]::Error.WriteLine('privacy-child-intentional-failure:true')
exit 13
'@
    $privacyChildSha=Get-Sha (Join-Path $testRoot 'privacy-child.ps1')
    $privacyProfile=New-Profile -ArtifactRelativePath 'out/privacy-unused.apk' -Arguments @()
    $privacyProfile.executable='privacy-child.ps1'
    $privacyProfile.preflight.toolchain.repository_files=@()
    $privacyProfile.preflight.environment_projection.passthrough=@('HOME','PATH','TEMP','TMP','TMPDIR','SYSTEMROOT','SYSTEMDRIVE','USERPROFILE','COMSPEC','WINDIR','PATHEXT','WEF_PRIVACY_CANARY','WEF_PRIVACY_CASE')
    $privacyRecord=Write-Profile $privacyProfile
    $privacySeed=New-PrivacySeedContext
    $oldCanary=[Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')
    $oldCase=[Environment]::GetEnvironmentVariable('WEF_PRIVACY_CASE')
    $privacyParentBefore=Get-PrivacyParentFingerprint
    $privacyComparisons=0;$privacyChildClosures=0;$privacyMismatchClosures=0
    try {
        foreach($lane in @('legacy','selected-context')) {
            foreach($operation in @('Preflight','Build')) {
                $views=@();$sample=0
                foreach($expected in @(Get-PrivacyCanaries)) {
                    Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $expected
                    Set-PrivacyVariable 'WEF_PRIVACY_CASE' (@('A','B')[$sample])
                    $before=Get-PrivacyParentFingerprint
                    $receipt=Join-Path $profileRoot "privacy-$lane-$operation-$sample.json"
                    $options=@{Mode=$operation;ProfileRecord=$privacyRecord;Receipt=$receipt;Retained=$true}
                    if($lane-ceq'selected-context'){$options.BuildContextPath=$privacySeed.Path;$options.BuildContextSha256=$privacySeed.Sha256}
                    $r=Invoke-Runner @options
                    Assert-PrivacyRunner $r $operation $receipt
                    Assert-True ((Get-PrivacyParentFingerprint)-ceq$before) 'Runner changed the synthetic parent environment.'
                    Assert-True ((Get-Sha (Join-Path $testRoot 'privacy-child.ps1'))-ceq$privacyChildSha-and(Get-Sha $privacyRecord.Path)-ceq$privacyRecord.Sha256-and(Get-Sha $privacySeed.Path)-ceq$privacySeed.Sha256) 'A/B fixture bytes changed.'
                    $row=@($r.Result.owner_payload.environment|Where-Object variable -CEQ 'WEF_PRIVACY_CANARY')
                    Assert-True ($row.Count-eq1-and$row[0].present-and$null-eq$row[0].value_sha256) 'Synthetic environment presence row differs.'
                    $view=Get-PrivacyStableView $r.Result;Assert-PrivacyJson $view;$views+=,$view
                    if($operation-ceq'Build'){$privacyChildClosures++}
                    $sample++
                }
                Assert-True ($views.Count-eq2-and$views[0]-ceq$views[1]) 'A/B value-only change altered permitted binding/evidence.'
                $privacyComparisons++
            }
        }
        # Causal receiver negative: same literal child and profile, intentionally
        # wrong nonsecret selector must exit97 without claiming exact delivery.
        Set-PrivacyVariable 'WEF_PRIVACY_CANARY' (@(Get-PrivacyCanaries)[0])
        Set-PrivacyVariable 'WEF_PRIVACY_CASE' 'B'
        foreach($lane in @('legacy','selected-context')) {
            $receipt=Join-Path $profileRoot "privacy-$lane-mismatch.json"
            $options=@{Mode='Build';ProfileRecord=$privacyRecord;Receipt=$receipt;Retained=$true}
            if($lane-ceq'selected-context'){$options.BuildContextPath=$privacySeed.Path;$options.BuildContextSha256=$privacySeed.Sha256}
            $r=Invoke-Runner @options;Assert-PrivacyRunner $r 'Build' $receipt 97
            $privacyMismatchClosures++
        }
        # Absence and prohibition use the same real public Preflight path.
        Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $null
        Set-PrivacyVariable 'WEF_PRIVACY_CASE' $null
        foreach($lane in @('legacy','selected-context')) {
            $options=@{Mode='Preflight';ProfileRecord=$privacyRecord;Retained=$true}
            if($lane-ceq'selected-context'){$options.BuildContextPath=$privacySeed.Path;$options.BuildContextSha256=$privacySeed.Sha256}
            $r=Invoke-Runner @options;Assert-PrivacyRunner $r 'Preflight'
            $row=@($r.Result.owner_payload.environment|Where-Object variable -CEQ 'WEF_PRIVACY_CANARY')
            Assert-True ($row.Count-le1-and@($row|Where-Object {$_.present-or$null-ne$_.value_sha256}).Count-eq0) 'Absent synthetic variable was observed present.'
        }
        $privacyProfile.preflight.environment_projection.prohibited_parent_variables=@('WEF_PRIVACY_CANARY')
        $prohibitedRecord=Write-Profile $privacyProfile
        Set-PrivacyVariable 'WEF_PRIVACY_CANARY' (@(Get-PrivacyCanaries)[0])
        foreach($lane in @('legacy','selected-context')) {
            $options=@{Mode='Preflight';ProfileRecord=$prohibitedRecord;Retained=$true}
            if($lane-ceq'selected-context'){$options.BuildContextPath=$privacySeed.Path;$options.BuildContextSha256=$privacySeed.Sha256}
            $r=Invoke-Runner @options;Assert-PrivacyJson $r.Json
            Assert-True ($r.ExitCode-eq2-and$r.Result.terminal_status-ceq'contradiction'-and-not$r.Result.child_process.started-and@($r.Result.reason_codes|Where-Object {$_-ceq'prohibited-parent-environment'}).Count-eq1) 'Prohibited synthetic variable did not refuse before child.'
        }
    } finally {
        Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $oldCanary
        Set-PrivacyVariable 'WEF_PRIVACY_CASE' $oldCase
    }
    Assert-True ((Get-PrivacyParentFingerprint)-ceq$privacyParentBefore) 'Privacy orchestration failed exact parent restoration.'
    Assert-True ($privacyComparisons-eq4-and$privacyChildClosures-eq4-and$privacyMismatchClosures-eq2) 'Privacy public runner coverage incomplete.'
    Write-Host 'Synthetic privacy public-runner controls passed: four A/B comparisons, four exact-value retained failures, two receiver-mismatch controls, absence/prohibition, exact parent restoration.'

    Write-Host "Quest build-profile preflight, terminal-result, deterministic identity, zero-side-effect, bounded progress, rename-race, and fault-corpus tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $fullTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        if (-not $fullTestRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to clean a test path outside the system temporary directory." }
        Remove-Item -LiteralPath $fullTestRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $profileRoot) {
        $fullProfileRoot = [System.IO.Path]::GetFullPath($profileRoot)
        if (-not $fullProfileRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to clean a profile path outside the system temporary directory." }
        Remove-Item -LiteralPath $fullProfileRoot -Recurse -Force
    }
    if(Test-Path -LiteralPath $externalSourceRoot) {
        $externalFull=[IO.Path]::GetFullPath($externalSourceRoot)
        if([IO.Path]::GetDirectoryName($externalFull)-cne[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')){throw 'Unsafe external fixture cleanup root.'}
        Remove-Item -LiteralPath $externalFull -Recurse -Force
    }
}
# One declared affected check covers the unchanged legacy corpus and the
# actual retained-v2 original/pipe/capture controls.
& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-QuestBuildRetainedOriginal.ps1') -RepoRoot $RepoRoot
if($LASTEXITCODE-ne0){throw 'Retained build original controls failed'}
$contextCorpusOptions=@{}
if($SeedContextPath){$contextCorpusOptions.SeedContextPath=$SeedContextPath;$contextCorpusOptions.SeedContextSha256=$SeedContextSha256}
& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-QuestBuildEnvironment.ps1') -RepoRoot $RepoRoot @contextCorpusOptions
if($LASTEXITCODE-ne0){throw 'Quest selected build environment corpus failed.'}
exit 0
