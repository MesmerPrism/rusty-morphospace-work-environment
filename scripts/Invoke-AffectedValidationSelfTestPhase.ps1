[CmdletBinding(DefaultParameterSetName='Phase')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Phase')]
    [ValidateSet('graph-import-closure','executor-pass-schema','executor-damage','selection-scenarios','trust-self-executor','trust-routing-contracts','trust-proportional-mappings','trust-damage-final')]
    [string]$Phase,
    [Parameter(Mandatory=$true,ParameterSetName='Phase')][ValidateRange(1,600)][int]$BudgetSeconds,
    [Parameter(Mandatory=$true,ParameterSetName='Verify')][switch]$Verify
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force

$phaseIds = @('graph-import-closure','executor-pass-schema','executor-damage','selection-scenarios','trust-self-executor','trust-routing-contracts','trust-proportional-mappings','trust-damage-final')
$checkIds = [ordered]@{
    'graph-import-closure'='affected-selector-graph-import-closure'
    'executor-pass-schema'='affected-selector-executor-pass-schema'
    'executor-damage'='affected-selector-executor-damage'
    'selection-scenarios'='affected-selector-selection-scenarios'
    'trust-self-executor'='affected-selector-trust-self-executor'
    'trust-routing-contracts'='affected-selector-trust-routing-contracts'
    'trust-proportional-mappings'='affected-selector-trust-proportional-mappings'
    'trust-damage-final'='affected-selector-trust-damage-final'
}
$dependencyPaths = @(
    'manifests/affected-validation-registry.json',
    'schemas/affected-validation-registry-v1.schema.json',
    'schemas/affected-validation-self-test-phase-receipt-v1.schema.json',
    'scripts/Invoke-AffectedValidationSelfTestPhase.ps1',
    'scripts/Test-AffectedValidation.ps1',
    'scripts/lib/MorphospaceAffectedValidation.psm1',
    'scripts/lib/MorphospaceProtocolCommon.psm1'
)

function Get-RequiredEnvironment([string]$Name,[string]$Pattern) {
    $value = [Environment]::GetEnvironmentVariable($Name,'Process')
    if ([string]::IsNullOrWhiteSpace($value) -or $value -cnotmatch $Pattern) { throw "Affected phase runner requires canonical environment '$Name'." }
    return $value
}
function Get-Sha256([byte[]]$Bytes) { ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant() }
function Get-FileReference([string]$Root,[string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($full)) { throw 'Affected phase stream/output is absent or outside its evidence root.' }
    $bytes = [IO.File]::ReadAllBytes($full)
    return [pscustomobject][ordered]@{path=[IO.Path]::GetRelativePath($Root,$full).Replace('\','/');bytes=[long]$bytes.Length;sha256=Get-Sha256 $bytes}
}
function Assert-FileReference([string]$Root,[object]$Reference) {
    $properties = @($Reference.PSObject.Properties.Name)
    [Array]::Sort($properties,[StringComparer]::Ordinal)
    if (($properties -join ',') -cne 'bytes,path,sha256') { throw 'Affected phase stream/output reference has unknown or missing properties.' }
    $full = [IO.Path]::GetFullPath((Join-Path $Root (([string]$Reference.path).Replace('/',[IO.Path]::DirectorySeparatorChar))))
    $observed = Get-FileReference -Root $Root -Path $full
    if ([string]$observed.path -cne [string]$Reference.path -or [long]$observed.bytes -ne [long]$Reference.bytes -or [string]$observed.sha256 -cne [string]$Reference.sha256) { throw "Affected phase stream/output reference drifted: $($Reference.path)" }
}
function Write-NewBytes([string]$Path,[byte[]]$Bytes) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    try {
        $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    } catch [IO.IOException] { throw "Affected phase evidence path already exists: $Path" }
}
function Write-NewJson([string]$Path,[object]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $Value) + "`n")
    Write-NewBytes -Path $Path -Bytes $bytes
}
function Get-DependencyManifest([string]$ExpectedHead,[string]$ExpectedTree) {
    $module = Get-Module MorphospaceAffectedValidation
    $head = & $module { param($Root) Get-MorphospaceAffectedGitIdentity -RepositoryRoot $Root -Revision HEAD } $repoRoot
    if ([string]$head.commit -cne $ExpectedHead -or [string]$head.tree -cne $ExpectedTree) { throw 'Affected phase repository HEAD/tree differs from the managed execution identity.' }
    $inventory = & $module { param($Root,$Commit) Get-MorphospaceAffectedTreeInventory -RepositoryRoot $Root -Commit $Commit } $repoRoot $ExpectedHead
    [void](& $module { param($Root,$Head,$Inventory,$Paths) Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $Root -ExpectedHead $Head -Inventory $Inventory -Paths $Paths } $repoRoot $head $inventory $dependencyPaths)
    $records = [Collections.Generic.List[object]]::new()
    foreach ($path in $dependencyPaths) {
        $entry = $inventory.by_path[$path]
        if ($null -eq $entry) { throw "Affected phase dependency is absent from the exact head: $path" }
        $bytes = [IO.File]::ReadAllBytes((Join-Path $repoRoot ($path.Replace('/',[IO.Path]::DirectorySeparatorChar))))
        $records.Add([pscustomobject][ordered]@{path=$path;blob=[string]$entry.blob;bytes=[long]$bytes.Length;sha256=Get-Sha256 $bytes})
    }
    return @($records.ToArray())
}
function Get-RunnerBinding {
    $powerShellPath = [IO.Path]::GetFullPath((Get-Process -Id $PID).Path)
    $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace([string]$gitCommand.Source)) { throw 'Affected phase runner could not resolve the Git executable.' }
    $gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Source)
    $gitVersion = (& $gitPath --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $gitVersion -cnotmatch '^git version [0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[A-Za-z0-9.-]+)?$') { throw 'Affected phase runner could not resolve a canonical Git version.' }
    return [pscustomobject][ordered]@{
        os_description=[Runtime.InteropServices.RuntimeInformation]::OSDescription
        process_architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
        powershell_version=$PSVersionTable.PSVersion.ToString()
        powershell_executable_sha256=Get-Sha256 ([IO.File]::ReadAllBytes($powerShellPath))
        git_version=$gitVersion
        git_executable_sha256=Get-Sha256 ([IO.File]::ReadAllBytes($gitPath))
    }
}
function Get-Binding([string]$PhaseId,[string]$CheckId,[string]$Base,[string]$Head,[string]$Tree,[string]$Plan,[string]$Platform,[object[]]$Manifest,[object]$Runner) {
    return [pscustomobject][ordered]@{repository='MesmerPrism/rusty-morphospace-work-environment';base_commit=$Base;head_commit=$Head;head_tree=$Tree;plan_sha256=$Plan;platform=$Platform;check_id=$CheckId;phase_id=$PhaseId;runner=$Runner;dependency_manifest=@($Manifest)}
}
function Test-Terminal([string]$Root,[string]$Path,[object]$ExpectedBinding,[string]$ExpectedBindingSha,[bool]$RequirePass) {
    $schemaPath = Join-Path $repoRoot 'schemas/affected-validation-self-test-phase-receipt-v1.schema.json'
    $raw = [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    if (-not (Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'Affected phase terminal fails its closed schema.' }
    $terminal = Read-MorphospaceProtocolJson -Path $Path
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $terminal.binding) -cne [string]$terminal.binding_sha256) { throw 'Affected phase terminal binding hash is damaged.' }
    if ([string]$terminal.binding_sha256 -cne $ExpectedBindingSha -or (Get-MorphospaceCanonicalJsonSha256 -Value $terminal.binding) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $ExpectedBinding)) { throw 'Affected phase terminal does not match the exact current binding.' }
    Assert-FileReference -Root $Root -Reference $terminal.child.stdout
    Assert-FileReference -Root $Root -Reference $terminal.child.stderr
    foreach ($output in @($terminal.outputs)) { Assert-FileReference -Root $Root -Reference $output }
    if ($RequirePass -and [string]$terminal.result -cne 'pass') { throw "Affected phase terminal is not passing: $($terminal.phase_id)=$($terminal.result)" }
    return $terminal
}

$evidenceRoot = [IO.Path]::GetFullPath((Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_PHASE_ROOT' '^.+$'))
$baseCommit = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_BASE_COMMIT' '^[0-9a-f]{40}$'
$headCommit = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_HEAD_COMMIT' '^[0-9a-f]{40}$'
$planSha256 = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_PLAN_SHA256' '^[0-9a-f]{64}$'
$platform = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_PLATFORM' '^(windows|linux)$'
$headTree = (& git -C $repoRoot rev-parse "$headCommit^{tree}").Trim()
if ($LASTEXITCODE -ne 0 -or $headTree -cnotmatch '^[0-9a-f]{40}$') { throw 'Affected phase runner could not resolve the exact head tree.' }
$dependencyManifest = Get-DependencyManifest -ExpectedHead $headCommit -ExpectedTree $headTree
$runnerBinding = Get-RunnerBinding

if ($Verify) {
    $managedVerifierCheckId = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_CHECK_ID' '^[a-z0-9][a-z0-9-]{1,95}$'
    if ($managedVerifierCheckId -cne 'affected-selector-selftest') { throw "Affected phase verifier/check routing mismatch: $managedVerifierCheckId" }
    $terminalFiles = @(Get-ChildItem -LiteralPath $evidenceRoot -File -Filter '*.terminal.json' -ErrorAction SilentlyContinue)
    if ($terminalFiles.Count -ne $phaseIds.Count) { throw 'Affected phase verifier requires exactly one terminal for every phase.' }
    foreach ($phaseId in $phaseIds) {
        $terminalPath = Join-Path $evidenceRoot "$phaseId.terminal.json"
        if (-not [IO.File]::Exists($terminalPath)) { throw "Affected phase verifier is missing '$phaseId'." }
        $binding = Get-Binding -PhaseId $phaseId -CheckId ([string]$checkIds[$phaseId]) -Base $baseCommit -Head $headCommit -Tree $headTree -Plan $planSha256 -Platform $platform -Manifest $dependencyManifest -Runner $runnerBinding
        $bindingSha = Get-MorphospaceCanonicalJsonSha256 -Value $binding
        [void](Test-Terminal -Root $evidenceRoot -Path $terminalPath -ExpectedBinding $binding -ExpectedBindingSha $bindingSha -RequirePass $true)
    }
    Write-Host 'Affected-validation phased selector receipt set passed without replay.'
    return
}

$expectedCheckId = [string]$checkIds[$Phase]
$managedCheckId = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_CHECK_ID' '^[a-z0-9][a-z0-9-]{1,95}$'
if ($managedCheckId -cne $expectedCheckId) { throw "Affected phase/check routing mismatch: phase=$Phase check=$managedCheckId expected=$expectedCheckId" }
$binding = Get-Binding -PhaseId $Phase -CheckId $managedCheckId -Base $baseCommit -Head $headCommit -Tree $headTree -Plan $planSha256 -Platform $platform -Manifest $dependencyManifest -Runner $runnerBinding
$bindingSha = Get-MorphospaceCanonicalJsonSha256 -Value $binding
$terminalPath = Join-Path $evidenceRoot "$Phase.terminal.json"
if ([IO.File]::Exists($terminalPath)) {
    [void](Test-Terminal -Root $evidenceRoot -Path $terminalPath -ExpectedBinding $binding -ExpectedBindingSha $bindingSha -RequirePass $true)
    Write-Host "Affected-validation phase '$Phase' reused its exact passing terminal."
    return
}

$startPath = Join-Path $evidenceRoot "$Phase.start.json"
$stdoutPath = Join-Path $evidenceRoot "$Phase.stdout.bin"
$stderrPath = Join-Path $evidenceRoot "$Phase.stderr.bin"
$started = [DateTimeOffset]::UtcNow
Write-NewJson -Path $startPath -Value ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_self_test_phase_start.v1';phase_id=$Phase;binding=$binding;binding_sha256=$bindingSha;started_at=$started.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture);budget_seconds=$BudgetSeconds})

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = (Get-Process -Id $PID).Path
$startInfo.WorkingDirectory = $repoRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
[void]$startInfo.Environment.Remove('GIT_PAGER')
foreach ($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Test-AffectedValidation.ps1'),'-SelfTestPhase',$Phase)) { [void]$startInfo.ArgumentList.Add($argument) }
if ($Phase -ceq 'selection-scenarios') { [void]$startInfo.ArgumentList.Add('-SelectionScenarioEvidenceRoot'); [void]$startInfo.ArgumentList.Add((Join-Path $evidenceRoot 'selection-scenarios')) }
$process = [Diagnostics.Process]::new(); $process.StartInfo = $startInfo
$stdoutMemory = [IO.MemoryStream]::new(); $stderrMemory = [IO.MemoryStream]::new()
$childStarted = $false; $timedOut = $false; $drainTimedOut = $false; $exitCode = $null; $launchError = $null
try {
    try {
        if (-not $process.Start()) { throw 'Affected phase child did not start.' }
        $childStarted = $true
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutMemory)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrMemory)
        if (-not $process.WaitForExit($BudgetSeconds * 1000)) { $timedOut = $true; try { $process.Kill($true) } catch {}; [void]$process.WaitForExit(15000) }
        if (-not [Threading.Tasks.Task]::WaitAll(@($stdoutTask,$stderrTask),15000)) { $drainTimedOut = $true }
        if ($process.HasExited -and -not $timedOut) { $exitCode = [int]$process.ExitCode }
    } catch { $launchError = [string]$_.Exception.Message }
    [byte[]]$stdoutBytes = @($stdoutMemory.ToArray())
    [byte[]]$stderrBytes = @(if ([string]::IsNullOrWhiteSpace($launchError)) { $stderrMemory.ToArray() } else { [Text.UTF8Encoding]::new($false).GetBytes($launchError) })
    Write-NewBytes -Path $stdoutPath -Bytes $stdoutBytes
    Write-NewBytes -Path $stderrPath -Bytes $stderrBytes
} finally {
    $process.Dispose(); $stdoutMemory.Dispose(); $stderrMemory.Dispose()
}
$ended = [DateTimeOffset]::UtcNow
$result = if (-not $childStarted -or -not [string]::IsNullOrWhiteSpace($launchError)) { 'infra-fail' } elseif ($timedOut -or $drainTimedOut -or $exitCode -ne 0) { 'code-fail' } else { 'pass' }
$outputs = [Collections.Generic.List[object]]::new()
if ($Phase -ceq 'graph-import-closure') {
    $graphOutputPath = Join-Path $evidenceRoot 'graph-import-closure.output.json'
    if ([IO.File]::Exists($graphOutputPath)) { $outputs.Add((Get-FileReference -Root $evidenceRoot -Path $graphOutputPath)) }
}
$terminal = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.affected_validation_self_test_phase_receipt.v1';phase_id=$Phase;binding=$binding;binding_sha256=$bindingSha
    started_at=$started.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture);ended_at=$ended.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
    budget_seconds=$BudgetSeconds;elapsed_ms=[long]($ended-$started).TotalMilliseconds;result=$result
    child=[pscustomobject][ordered]@{started=$childStarted;exit_code=$exitCode;timed_out=$timedOut;post_kill_drain_timed_out=$drainTimedOut;stdout=Get-FileReference -Root $evidenceRoot -Path $stdoutPath;stderr=Get-FileReference -Root $evidenceRoot -Path $stderrPath}
    outputs=@($outputs.ToArray());claims=[pscustomobject][ordered]@{phase_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}
}
$terminalJson = ConvertTo-MorphospaceCanonicalJson -Value $terminal
if (-not (Test-Json -Json $terminalJson -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-self-test-phase-receipt-v1.schema.json') -ErrorAction Stop)) { throw 'Affected phase terminal fails its closed schema.' }
Write-NewJson -Path $terminalPath -Value $terminal
if ($result -cne 'pass') { throw "Affected-validation phase '$Phase' failed with '$result'; typed evidence is preserved." }
Write-Host "Affected-validation phase '$Phase' passed in $($terminal.elapsed_ms)ms."
