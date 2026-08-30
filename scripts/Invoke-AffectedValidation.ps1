[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$BaseCommit,
    [Parameter(Mandatory = $true)][string]$HeadCommit,
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$Platform,
    [Parameter(Mandatory = $true)][string]$OutPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force

if (-not ('W017BoundedChildCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public sealed class W017BoundedChildResult {
    public bool Started;
    public int? ExitCode;
    public bool TimedOut;
    public bool OutputTruncated;
    public bool PostKillDrainTimedOut;
    public string Error;
    public byte[] Stdout = new byte[0];
    public byte[] Stderr = new byte[0];
}

public static class W017BoundedChildCapture {
    private sealed class CaptureState {
        public readonly int Limit;
        public int Seen;
        public int Truncated;
        public CaptureState(int limit) { Limit = limit; }
    }
    private static void Drain(Stream source, MemoryStream target, CaptureState state) {
        var buffer = new byte[8192];
        int read;
        while ((read = source.Read(buffer, 0, buffer.Length)) > 0) {
            var before = Interlocked.Add(ref state.Seen, read) - read;
            var remaining = state.Limit - before;
            var captured = remaining <= 0 ? 0 : Math.Min(read, remaining);
            if (captured > 0) { target.Write(buffer, 0, captured); }
            if (captured != read) { Interlocked.Exchange(ref state.Truncated, 1); }
        }
    }
    public static W017BoundedChildResult Run(string executable, string workingDirectory, string[] arguments, int budgetSeconds, int outputLimitBytes, int postKillDrainMilliseconds) {
        var result = new W017BoundedChildResult();
        var output = new MemoryStream();
        var error = new MemoryStream();
        Process process = null;
        try {
            var start = new ProcessStartInfo();
            start.FileName = executable;
            start.WorkingDirectory = workingDirectory;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            foreach (var argument in arguments) { start.ArgumentList.Add(argument); }
            process = new Process(); process.StartInfo = start;
            if (!process.Start()) { throw new InvalidOperationException("child process did not start"); }
            result.Started = true;
            var state = new CaptureState(outputLimitBytes);
            var stdoutTask = Task.Run(() => Drain(process.StandardOutput.BaseStream, output, state));
            var stderrTask = Task.Run(() => Drain(process.StandardError.BaseStream, error, state));
            var deadline = DateTime.UtcNow.AddSeconds(budgetSeconds);
            var killed = false;
            while (!process.WaitForExit(100)) {
                if (Volatile.Read(ref state.Truncated) != 0 || DateTime.UtcNow >= deadline) {
                    result.TimedOut = DateTime.UtcNow >= deadline;
                    try { process.Kill(true); } catch { }
                    killed = true;
                    break;
                }
            }
            if (!killed && Volatile.Read(ref state.Truncated) != 0) {
                try { process.Kill(true); } catch { }
                killed = true;
            }
            if (killed) {
                if (!process.WaitForExit(postKillDrainMilliseconds)) { result.PostKillDrainTimedOut = true; }
            }
            if (!Task.WaitAll(new Task[] { stdoutTask, stderrTask }, postKillDrainMilliseconds)) { result.PostKillDrainTimedOut = true; }
            result.OutputTruncated = Volatile.Read(ref state.Truncated) != 0;
            if (process.HasExited && !result.TimedOut) { result.ExitCode = process.ExitCode; }
            result.Stdout = output.ToArray(); result.Stderr = error.ToArray();
        } catch (Exception exception) {
            result.Error = exception.Message;
            result.Stdout = output.ToArray(); result.Stderr = error.ToArray();
        } finally {
            if (process != null) { process.Dispose(); }
            output.Dispose(); error.Dispose();
        }
        return result;
    }
}
'@
}

function Get-AffectedValidationBytesHash([byte[]]$Bytes) { ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant() }
function Get-AffectedValidationCommandBlob([string]$Path) { $blob = (& git -C $root rev-parse "${HeadCommit}:$Path").Trim(); if ($LASTEXITCODE -ne 0 -or $blob -notmatch '^[0-9a-f]{40}$') { throw "Affected-validation command is not an exact head blob: $Path" }; return $blob }
function Invoke-AffectedValidationCheck([object]$Check, [string]$Command) {
    $budget = [Math]::Min([Math]::Max([int]$Check.budget_seconds, 1), 7200)
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $Command) + @($Check.arguments)) { [void]$arguments.Add([string]$argument) }
    $projectedNames = @('RUSTY_AFFECTED_VALIDATION_PHASE_ROOT','RUSTY_AFFECTED_VALIDATION_BASE_COMMIT','RUSTY_AFFECTED_VALIDATION_HEAD_COMMIT','RUSTY_AFFECTED_VALIDATION_PLAN_SHA256','RUSTY_AFFECTED_VALIDATION_PLATFORM','RUSTY_AFFECTED_VALIDATION_CHECK_ID','GIT_PAGER')
    $savedEnvironment = @{}
    foreach ($name in $projectedNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
    try {
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_PHASE_ROOT',$phaseEvidenceRoot,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_BASE_COMMIT',$BaseCommit,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_HEAD_COMMIT',$HeadCommit,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_PLAN_SHA256',[string]$plan.plan_sha256,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_PLATFORM',$Platform,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_CHECK_ID',[string]$Check.check_id,'Process')
        [Environment]::SetEnvironmentVariable('GIT_PAGER',$null,'Process')
        $child = [W017BoundedChildCapture]::Run((Get-Process -Id $PID).Path, $root, @($arguments.ToArray()), $budget, 10485760, 15000)
    } finally {
        foreach ($name in $projectedNames) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process') }
    }
    $stdout = [byte[]]$child.Stdout
    $stderr = [byte[]]$child.Stderr
    if (-not [string]::IsNullOrWhiteSpace([string]$child.Error)) { $stderr = [Text.UTF8Encoding]::new($false).GetBytes([string]$child.Error) }
    # A started check that overruns its contract or floods/drains output is a
    # check failure.  `infra-fail` is reserved for a host/process-start fault;
    # pre-job availability uses the separate typed pending-infrastructure gate.
    $result = if (-not $child.Started) { 'infra-fail' } elseif ($child.TimedOut -or $child.OutputTruncated -or $child.PostKillDrainTimedOut) { 'code-fail' } elseif (-not [string]::IsNullOrWhiteSpace([string]$child.Error)) { 'infra-fail' } elseif ([int]$child.ExitCode -eq 0) { 'pass' } else { 'code-fail' }
    return [pscustomobject][ordered]@{
        check_id=[string]$Check.check_id; command_path=[string]$Check.command_path; command_blob_sha1=Get-AffectedValidationCommandBlob ([string]$Check.command_path)
        result=$result; exit_code=$child.ExitCode; timed_out=[bool]$child.TimedOut; output_truncated=[bool]$child.OutputTruncated; post_kill_drain_timed_out=[bool]$child.PostKillDrainTimedOut
        stdout_sha256=Get-AffectedValidationBytesHash $stdout; stderr_sha256=Get-AffectedValidationBytesHash $stderr
        stdout_bytes=[long]$stdout.Length; stderr_bytes=[long]$stderr.Length
    }
}

$planFull = [IO.Path]::GetFullPath($PlanPath)
if (-not [IO.File]::Exists($planFull)) { throw 'Affected-validation plan is absent.' }
$planRaw = Get-Content -LiteralPath $planFull -Raw
$planSchema = Join-Path $repoRoot 'schemas/affected-validation-plan-v1.schema.json'
if (-not (Test-Json -Json $planRaw -SchemaFile $planSchema -ErrorAction Stop)) { throw 'Affected-validation plan fails its closed schema.' }
$plan = Read-MorphospaceProtocolJson -Path $planFull
$output = [IO.Path]::GetFullPath($OutPath)
$parent = [IO.Path]::GetDirectoryName($output)
if ([IO.File]::Exists($output)) { throw 'Affected-validation evidence output already exists.' }
if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
$phaseEvidenceRoot = Join-Path $parent ("affected-selector-phases-$([string]$plan.plan_sha256)-$Platform")
$registryPath = Join-Path $root 'manifests/affected-validation-registry.json'
$recomputed = Resolve-MorphospaceAffectedValidation -RepositoryRoot $root -BaseRevision $BaseCommit -HeadRevision $HeadCommit -RegistryPath $registryPath -RequestedTier ([string]$plan.requested_tier)
if ((Get-MorphospaceCanonicalJsonSha256 -Value $recomputed) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $plan) -or [string]$plan.plan_sha256 -cne [string]$recomputed.plan_sha256) { throw 'Affected-validation plan differs from the exact current base/head/registry selection.' }
$selected = @($plan.selected_checks | Where-Object { @($_.platforms) -ccontains $Platform })
if ($selected.Count -eq 0) { throw "Affected-validation execution rejects an empty '$Platform' selection." }
$registry = Read-MorphospaceProtocolJson -Path $registryPath
[void](Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $root -SchemaPath (Join-Path $root 'schemas/affected-validation-registry-v1.schema.json'))
$checkMap = @{}; foreach ($check in @($registry.checks)) { $checkMap[[string]$check.check_id] = $check }
$results = [Collections.Generic.List[object]]::new()
foreach ($selectedCheck in $selected) {
    $check = $checkMap[[string]$selectedCheck.check_id]
    if ($null -eq $check) { throw "Affected-validation selected an unknown check '$($selectedCheck.check_id)'." }
    $command = Join-Path $root (([string]$check.command_path) -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not [IO.File]::Exists($command)) { throw "Affected-validation command is absent: $($check.command_path)" }
    $checkResult = Invoke-AffectedValidationCheck -Check $check -Command $command
    $results.Add($checkResult)
    if (([string]$check.check_id).StartsWith('affected-selector-', [StringComparison]::Ordinal) -and [string]$checkResult.result -cne 'pass') {
        break
    }
}
$resultValues = @($results | ForEach-Object result)
$overall = if ($resultValues -ccontains 'infra-fail') { 'infra-fail' } elseif ($resultValues -ccontains 'code-fail') { 'code-fail' } else { 'pass' }
$evidence = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.affected_validation_evidence.v1'; repository=[string]$plan.repository; base=$plan.base; head=$plan.head; plan_sha256=[string]$plan.plan_sha256; platform=$Platform
    runner=[pscustomobject][ordered]@{ os_description=[Environment]::OSVersion.VersionString; powershell_version=$PSVersionTable.PSVersion.ToString() }
    check_results=@($results.ToArray()); result=$overall
    claims=[pscustomobject][ordered]@{ historical_aggregate_reused=$false; acceptance_authority=$false; publication_authority=$false }
}
$evidenceSchema = Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json'
$evidenceJson = ConvertTo-MorphospaceCanonicalJson -Value $evidence
if (-not (Test-Json -Json $evidenceJson -SchemaFile $evidenceSchema -ErrorAction Stop)) { throw 'Affected-validation evidence fails its closed schema.' }
[IO.File]::WriteAllText($output, $evidenceJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
if ($overall -cne 'pass') { throw "Affected-validation execution failed with '$overall'; typed evidence was written to '$output'." }
$evidence
