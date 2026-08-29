Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceHistoricalValidationDebtBaseline.psm1')

function New-MorphospaceHistoricalDebtPhaseException {
    param([Parameter(Mandatory)][string]$Category,[Parameter(Mandatory)][string]$Message)
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['morphospace_phase_category'] = $Category
    return $exception
}

function Get-MorphospaceHistoricalDebtEvidenceRootSha256 {
    param([Parameter(Mandatory)][string]$EvidenceRoot)
    $full = [IO.Path]::GetFullPath($EvidenceRoot)
    return Get-MorphospaceSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($full))
}

function Write-MorphospaceHistoricalDebtCreateNewBytes {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][byte[]]$Bytes)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-collision' -Message "Historical-debt evidence parent is missing: $parent")
    }
    try {
        $stream = [IO.FileStream]::new($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    } catch {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-collision' -Message "Historical-debt evidence output already exists or could not be created exclusively: $full")
    }
    try {
        $stream.Write($Bytes,0,$Bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    return $full
}

function Write-MorphospaceHistoricalDebtCreateNewJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    $schemaPath = Join-Path $moduleRoot 'schemas/historical-validation-debt-phase-receipt-v1.schema.json'
    $json = ConvertTo-MorphospaceCanonicalJson -Value $Value
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop)) {
        throw 'Historical-debt phase receipt failed its closed schema.'
    }
    $bytes = ConvertTo-MorphospaceProtocolJsonBytes -Value $Value
    $full = Write-MorphospaceHistoricalDebtCreateNewBytes -Path $Path -Bytes $bytes
    return [pscustomobject][ordered]@{
        path = [IO.Path]::GetFileName($full)
        sha256 = Get-MorphospaceSha256Bytes -Bytes $bytes
        length = [long]$bytes.Length
    }
}

function Get-MorphospaceHistoricalDebtReadyHandshakePendingPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$HandshakeId
    )
    if ($HandshakeId -cnotmatch '^[0-9a-f]{32}$') {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'handshake-invalid' -Message 'Historical-debt ready handshake ID is invalid.')
    }
    $full = [IO.Path]::GetFullPath($Path)
    return Join-Path ([IO.Path]::GetDirectoryName($full)) (([IO.Path]::GetFileName($full)) + ".${HandshakeId}.pending")
}

function Write-MorphospaceHistoricalDebtReadyHandshake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$HandshakeId,
        [Parameter(Mandatory)][int]$ParentPid,
        [Parameter(Mandatory)][int]$ChildPid,
        [Parameter(Mandatory)][string]$ReadyAt
    )
    if ($HandshakeId -cnotmatch '^[0-9a-f]{32}$') {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'handshake-invalid' -Message 'Historical-debt ready handshake ID is invalid.')
    }
    if ($ParentPid -le 0 -or $ChildPid -le 0 -or $ParentPid -eq $ChildPid) {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'handshake-invalid' -Message 'Historical-debt ready handshake process identities are invalid.')
    }
    try { [void](Test-MorphospaceStrictUtcTimestamp -Value $ReadyAt) }
    catch { throw (New-MorphospaceHistoricalDebtPhaseException -Category 'handshake-invalid' -Message "Historical-debt ready handshake timestamp is invalid. $($_.Exception.Message)") }
    $record = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.historical_validation_debt_child_ready.v1'
        handshake_id = $HandshakeId
        parent_pid = $ParentPid
        child_pid = $ChildPid
        ready_at = $ReadyAt
    }
    $bytes = ConvertTo-MorphospaceProtocolJsonBytes -Value $record
    $full = [IO.Path]::GetFullPath($Path)
    $pending = Get-MorphospaceHistoricalDebtReadyHandshakePendingPath -Path $full -HandshakeId $HandshakeId
    $pendingCreated = $false
    try {
        try {
            $stream = [IO.FileStream]::new($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
            $pendingCreated = $true
        } catch {
            throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-collision' -Message "Historical-debt ready handshake pending output already exists or could not be created exclusively: $pending")
        }
        try {
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        try {
            [IO.File]::Move($pending,$full,$false)
        } catch {
            throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-collision' -Message "Historical-debt ready handshake final path already exists or could not be published without overwrite: $full")
        }
    } finally {
        if ($pendingCreated -and [IO.File]::Exists($pending)) {
            [IO.File]::Delete($pending)
        }
    }
    return [pscustomobject]@{
        record = $record
        path = $full
        pending_path = $pending
        sha256 = Get-MorphospaceSha256Bytes -Bytes $bytes
        length = [long]$bytes.Length
    }
}

function Read-MorphospaceHistoricalDebtReadyHandshake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHandshakeId,
        [Parameter(Mandatory)][int]$ExpectedParentPid,
        [Parameter(Mandatory)][DateTimeOffset]$StartupStartedAt,
        [Parameter(Mandatory)][DateTimeOffset]$StartupDeadline
    )
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'handshake-missing' -Message "Historical-debt ready handshake is missing: $full")
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($full)
        $record = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'historical-debt child-ready handshake'
        Assert-MorphospaceExactPropertySet $record @('schema','handshake_id','parent_pid','child_pid','ready_at') @() 'historical-debt child-ready handshake'
        if ([string]$record.schema -cne 'rusty.morphospace.workflow.historical_validation_debt_child_ready.v1' -or
            [string]$record.handshake_id -cne $ExpectedHandshakeId -or
            [int]$record.parent_pid -ne $ExpectedParentPid -or
            [int]$record.child_pid -le 0 -or
            [int]$record.child_pid -eq $ExpectedParentPid) {
            throw 'Historical-debt child-ready handshake identity is invalid.'
        }
        [byte[]]$canonicalBytes = ConvertTo-MorphospaceProtocolJsonBytes -Value $record
        if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($bytes,$canonicalBytes)) {
            throw 'Historical-debt child-ready handshake bytes are not canonical UTF-8 without BOM with one LF terminator.'
        }
        $readyAt = Test-MorphospaceStrictUtcTimestamp -Value ([string]$record.ready_at)
        if ($readyAt -lt $StartupStartedAt -or $readyAt -gt $StartupDeadline) {
            throw (New-MorphospaceHistoricalDebtPhaseException -Category 'handshake-stale' -Message 'Historical-debt child-ready handshake timestamp is outside the bounded startup window.')
        }
        $parent = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $ExpectedParentPid) -ErrorAction Stop)
        $child = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f ([int]$record.child_pid)) -ErrorAction Stop)
        if ($parent.Count -ne 1 -or $child.Count -ne 1 -or [int]$child[0].ParentProcessId -ne $ExpectedParentPid) {
            throw 'Historical-debt child-ready handshake does not identify one live direct nested child.'
        }
        return [pscustomobject]@{ record=$record;bytes=$bytes;sha256=(Get-MorphospaceSha256Bytes -Bytes $bytes);length=[long]$bytes.Length }
    } catch {
        if ($_.Exception.Data.Contains('morphospace_phase_category')) { throw }
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'handshake-invalid' -Message "Historical-debt ready handshake is invalid. $($_.Exception.Message)")
    }
}

function Get-MorphospaceHistoricalDebtFileReference {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    return [pscustomobject][ordered]@{
        path = [IO.Path]::GetFileName($full)
        sha256 = Get-MorphospaceFileSha256 -Path $full
        length = [long]([IO.FileInfo]$full).Length
    }
}

function Get-MorphospaceHistoricalDebtCommandRecord {
    param(
        [Parameter(Mandatory)][ValidateSet('child','in-process')][string]$Kind,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    $full = (Resolve-Path -LiteralPath $Path).Path
    $argumentValues = @($Arguments | ForEach-Object { [string]$_ })
    return [pscustomobject][ordered]@{
        kind = $Kind
        path = $full
        sha256 = Get-MorphospaceFileSha256 -Path $full
        length = [long]([IO.FileInfo]$full).Length
        arguments = $argumentValues
        arguments_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $argumentValues
        working_directory = [IO.Path]::GetFullPath($WorkingDirectory)
    }
}

function Initialize-MorphospaceHistoricalDebtEvidenceSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EvidenceRoot)
    $full = [IO.Path]::GetFullPath($EvidenceRoot)
    if ([IO.Directory]::Exists($full) -or [IO.File]::Exists($full)) {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-collision' -Message "Historical-debt evidence session already exists: $full")
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.Directory]::CreateDirectory($full) | Out-Null
    Assert-MorphospaceNoReparseAncestor -Root $parent -Candidate $full
    return $full
}

function New-MorphospaceHistoricalDebtPhaseStart {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][int]$Sequence,
        [Parameter(Mandatory)][string]$PhaseId,
        [Parameter(Mandatory)][object]$Command,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$StdoutLeaf,
        [Parameter(Mandatory)][string]$StderrLeaf,
        [string[]]$RemovedGitEnvironment = @(),
        [AllowNull()][Nullable[DateTimeOffset]]$StartedAt = $null
    )
    $startedAt = if ($null -ne $StartedAt) { [DateTimeOffset]$StartedAt } else { [DateTimeOffset]::UtcNow }
    $record = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.historical_validation_debt_phase_receipt.v1'
        record_kind = 'start'
        phase_id = $PhaseId
        sequence = $Sequence
        evidence_root_sha256 = Get-MorphospaceHistoricalDebtEvidenceRootSha256 -EvidenceRoot $EvidenceRoot
        started_at = $startedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        timeout_seconds = $TimeoutSeconds
        command = $Command
        stdout_path = $StdoutLeaf
        stderr_path = $StderrLeaf
        git_environment_removed = @($RemovedGitEnvironment | Sort-Object -Unique -CaseSensitive)
    }
    $leaf = ('{0:d3}-{1}.start.json' -f $Sequence,$PhaseId)
    $reference = Write-MorphospaceHistoricalDebtCreateNewJson -Path (Join-Path $EvidenceRoot $leaf) -Value $record
    Write-Host ("historical-debt-phase-start phase={0} sequence={1} timeout_seconds={2}" -f $PhaseId,$Sequence,$TimeoutSeconds)
    return [pscustomobject]@{ started_at=$startedAt; record=$record; reference=$reference }
}

function New-MorphospaceHistoricalDebtPhaseTerminal {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][int]$Sequence,
        [Parameter(Mandatory)][string]$PhaseId,
        [Parameter(Mandatory)][object]$Command,
        [Parameter(Mandatory)][object]$Start,
        [Parameter(Mandatory)][string]$Result,
        [Parameter(Mandatory)][string]$Category,
        [AllowNull()][Nullable[int]]$ExitCode,
        [Parameter(Mandatory)][bool]$TimedOut,
        [Parameter(Mandatory)][object]$Cleanup,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$StderrPath,
        [Parameter(Mandatory)][long]$DiagnosticBytesStreamed,
        [Parameter(Mandatory)][long]$DiagnosticBytesSuppressed
    )
    $endedAt = [DateTimeOffset]::UtcNow
    $elapsed = [long][Math]::Ceiling(($endedAt - $Start.started_at).TotalMilliseconds)
    $record = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.historical_validation_debt_phase_receipt.v1'
        record_kind = 'terminal'
        phase_id = $PhaseId
        sequence = $Sequence
        evidence_root_sha256 = Get-MorphospaceHistoricalDebtEvidenceRootSha256 -EvidenceRoot $EvidenceRoot
        command = $Command
        started_at = $Start.record.started_at
        ended_at = $endedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        elapsed_ms = $elapsed
        start_receipt = $Start.reference
        result = $Result
        category = $Category
        exit_code = $ExitCode
        timed_out = $TimedOut
        child_tree_cleanup = $Cleanup
        stdout = Get-MorphospaceHistoricalDebtFileReference -Path $StdoutPath
        stderr = Get-MorphospaceHistoricalDebtFileReference -Path $StderrPath
        diagnostics = [pscustomobject][ordered]@{
            streamed_bytes = $DiagnosticBytesStreamed
            suppressed_bytes = $DiagnosticBytesSuppressed
        }
    }
    $leaf = ('{0:d3}-{1}.terminal.json' -f $Sequence,$PhaseId)
    $reference = Write-MorphospaceHistoricalDebtCreateNewJson -Path (Join-Path $EvidenceRoot $leaf) -Value $record
    Write-Host ("historical-debt-phase-terminal phase={0} result={1} category={2} elapsed_ms={3}" -f $PhaseId,$Result,$Category,$elapsed)
    return [pscustomobject]@{ record=$record; reference=$reference }
}

function Invoke-MorphospaceHistoricalDebtChildPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][ValidateRange(1,999)][int]$Sequence,
        [Parameter(Mandatory)][string]$PhaseId,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateRange(1,3600)][int]$TimeoutSeconds = 300,
        [string]$ReadyHandshakePath = '',
        [string]$ReadyHandshakeId = '',
        [ValidateRange(1,60)][int]$StartupTimeoutSeconds = 10,
        [int[]]$ExpectedExitCodes = @(0),
        [ValidateRange(1024,33554432)][long]$MaximumStreamBytes = 16777216,
        [ValidateRange(0,1048576)][long]$MaximumDiagnosticBytes = 32768
    )
    if ($PhaseId -cnotmatch '^[a-z0-9][a-z0-9-]{1,95}$') { throw 'Historical-debt phase ID is invalid.' }
    if ([bool]$ReadyHandshakePath -ne [bool]$ReadyHandshakeId) { throw 'Historical-debt phase readiness path and ID must be supplied together.' }
    if ($ReadyHandshakeId -and $ReadyHandshakeId -cnotmatch '^[0-9a-f]{32}$') { throw 'Historical-debt phase readiness ID is invalid.' }
    $root = (Resolve-Path -LiteralPath $EvidenceRoot).Path
    Assert-MorphospaceNoReparseAncestor -Root $root -Candidate $root
    $stdoutLeaf = ('{0:d3}-{1}.stdout.log' -f $Sequence,$PhaseId)
    $stderrLeaf = ('{0:d3}-{1}.stderr.log' -f $Sequence,$PhaseId)
    $stdoutPath = Join-Path $root $stdoutLeaf
    $stderrPath = Join-Path $root $stderrLeaf
    try {
        $stdoutStream = [IO.FileStream]::new($stdoutPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
        try {
            $stderrStream = [IO.FileStream]::new($stderrPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
        } catch {
            $stdoutStream.Dispose()
            throw
        }
    } catch {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-collision' -Message "Historical-debt phase stream output already exists: $PhaseId")
    }

    $command = Get-MorphospaceHistoricalDebtCommandRecord -Kind child -Path $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $command.path
    $startInfo.WorkingDirectory = $command.working_directory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @($Arguments)) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $removedGit = [Collections.Generic.List[string]]::new()
    foreach ($key in @($startInfo.Environment.Keys)) {
        if ([string]$key -like 'GIT_*') {
            $removedGit.Add([string]$key) | Out-Null
            [void]$startInfo.Environment.Remove([string]$key)
        }
    }
    $start = $null
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $processStarted = $false
    $category = 'completed'
    $result = 'fail'
    $exitCode = $null
    $timedOut = $false
    $cleanupAttempted = $false
    $cleanupSucceeded = $true
    $diagnosticBytes = 0L
    $suppressedBytes = 0L
    $utf8 = [Text.UTF8Encoding]::new($false)
    $readyHandshake = $null
    $readyHandshakePendingPath = ''
    $readinessArtifactsOwned = $false
    $startupTimedOut = $false
    try {
        if (-not $ReadyHandshakePath) {
            $start = New-MorphospaceHistoricalDebtPhaseStart -EvidenceRoot $root -Sequence $Sequence -PhaseId $PhaseId -Command $command -TimeoutSeconds $TimeoutSeconds -StdoutLeaf $stdoutLeaf -StderrLeaf $stderrLeaf -RemovedGitEnvironment @($removedGit.ToArray())
        } else {
            $ReadyHandshakePath = [IO.Path]::GetFullPath($ReadyHandshakePath)
            $readyHandshakePendingPath = Get-MorphospaceHistoricalDebtReadyHandshakePendingPath -Path $ReadyHandshakePath -HandshakeId $ReadyHandshakeId
            if ([IO.File]::Exists($ReadyHandshakePath) -or [IO.File]::Exists($readyHandshakePendingPath)) {
                throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-collision' -Message 'Historical-debt ready handshake final or pending path already exists before child startup.')
            }
            $readinessArtifactsOwned = $true
        }
        try {
            if ($ReadyHandshakePath) {
                $startupStartedAt = [DateTimeOffset]::UtcNow
                $startupDeadline = $startupStartedAt.AddSeconds($StartupTimeoutSeconds)
            }
            if (-not $process.Start()) { throw 'Child process did not start.' }
            $processStarted = $true
            $outBuffer = [byte[]]::new(4096)
            $errBuffer = [byte[]]::new(4096)
            $outTask = $process.StandardOutput.BaseStream.ReadAsync($outBuffer,0,$outBuffer.Length)
            $errTask = $process.StandardError.BaseStream.ReadAsync($errBuffer,0,$errBuffer.Length)
            $outEnded = $false
            $errEnded = $false
            $killRequested = $false
            if ($ReadyHandshakePath) {
                while ($null -eq $readyHandshake) {
                    if ([IO.File]::Exists([IO.Path]::GetFullPath($ReadyHandshakePath))) {
                        $readyHandshake = Read-MorphospaceHistoricalDebtReadyHandshake -Path $ReadyHandshakePath -ExpectedHandshakeId $ReadyHandshakeId -ExpectedParentPid $process.Id -StartupStartedAt $startupStartedAt -StartupDeadline $startupDeadline
                        break
                    }
                    if ($process.HasExited) {
                        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'handshake-missing' -Message 'Historical-debt phase child exited before publishing its ready handshake.')
                    }
                    if ([DateTimeOffset]::UtcNow -ge $startupDeadline) {
                        $startupTimedOut = $true
                        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'handshake-missing' -Message 'Historical-debt phase child did not publish its ready handshake before the startup deadline.')
                    }
                    Start-Sleep -Milliseconds 25
                }
                $start = New-MorphospaceHistoricalDebtPhaseStart -EvidenceRoot $root -Sequence $Sequence -PhaseId $PhaseId -Command $command -TimeoutSeconds $TimeoutSeconds -StdoutLeaf $stdoutLeaf -StderrLeaf $stderrLeaf -RemovedGitEnvironment @($removedGit.ToArray())
            }
            $deadline = $start.started_at.AddSeconds($TimeoutSeconds)
            while (-not ($process.HasExited -and $outEnded -and $errEnded)) {
                foreach ($streamName in @('stdout','stderr')) {
                    $task = if ($streamName -ceq 'stdout') { $outTask } else { $errTask }
                    if ($null -eq $task -or -not $task.IsCompleted) { continue }
                    $count = $task.GetAwaiter().GetResult()
                    if ($count -eq 0) {
                        if ($streamName -ceq 'stdout') { $outEnded=$true;$outTask=$null } else { $errEnded=$true;$errTask=$null }
                        continue
                    }
                    $target = if ($streamName -ceq 'stdout') { $stdoutStream } else { $stderrStream }
                    $buffer = if ($streamName -ceq 'stdout') { $outBuffer } else { $errBuffer }
                    if ($target.Length + $count -gt $MaximumStreamBytes) {
                        $category = 'output-limit'
                        $killRequested = $true
                    } else {
                        $target.Write($buffer,0,$count)
                        $remaining = [Math]::Max(0L,$MaximumDiagnosticBytes-$diagnosticBytes)
                        if ($remaining -gt 0) {
                            $visibleCount = [int][Math]::Min([long]$count,$remaining)
                            $visible = $utf8.GetString($buffer,0,$visibleCount).Replace([char]0,'?')
                            if ($visible.Length -gt 512) { $visible = $visible.Substring(0,512) }
                            if ($visible.Length -gt 0) { Write-Host ("historical-debt-phase-output phase={0} stream={1} text={2}" -f $PhaseId,$streamName,$visible.TrimEnd()) }
                            $diagnosticBytes += $visibleCount
                            $suppressedBytes += ($count-$visibleCount)
                        } else {
                            $suppressedBytes += $count
                        }
                    }
                    if ($streamName -ceq 'stdout') {
                        $outBuffer=[byte[]]::new(4096)
                        $outTask=$process.StandardOutput.BaseStream.ReadAsync($outBuffer,0,$outBuffer.Length)
                    } else {
                        $errBuffer=[byte[]]::new(4096)
                        $errTask=$process.StandardError.BaseStream.ReadAsync($errBuffer,0,$errBuffer.Length)
                    }
                }
                if (-not $process.HasExited -and [DateTimeOffset]::UtcNow -ge $deadline) {
                    $timedOut = $true
                    $category = 'timeout'
                    $killRequested = $true
                }
                if ($killRequested -and -not $process.HasExited) {
                    $cleanupAttempted = $true
                    try {
                        $process.Kill($true)
                        $cleanupSucceeded = $process.WaitForExit(10000)
                    } catch {
                        $cleanupSucceeded = $false
                    }
                    if (-not $cleanupSucceeded) { $category = 'child-cleanup-fail' }
                }
                if (-not ($process.HasExited -and $outEnded -and $errEnded)) { Start-Sleep -Milliseconds 25 }
            }
            $stdoutStream.Flush($true)
            $stderrStream.Flush($true)
            if ($process.HasExited) { $exitCode = [int]$process.ExitCode }
            if ($category -ceq 'completed' -and @($ExpectedExitCodes) -contains $exitCode) { $result='pass' }
            elseif ($category -ceq 'completed') { $category='code-fail' }
        } catch {
            if ($null -eq $start) {
                if (-not $ReadyHandshakePath -or -not $processStarted) { throw }
                $category = if ($_.Exception.Data.Contains('morphospace_phase_category')) { [string]$_.Exception.Data['morphospace_phase_category'] } else { 'process-start-fail' }
                $timedOut = $startupTimedOut
                $start = New-MorphospaceHistoricalDebtPhaseStart -EvidenceRoot $root -Sequence $Sequence -PhaseId $PhaseId -Command $command -TimeoutSeconds $StartupTimeoutSeconds -StdoutLeaf $stdoutLeaf -StderrLeaf $stderrLeaf -RemovedGitEnvironment @($removedGit.ToArray()) -StartedAt $startupStartedAt
            } elseif ($category -ceq 'completed') {
                $category='process-start-fail'
            }
            $messageBytes = $utf8.GetBytes([string]$_.Exception.Message + [Environment]::NewLine)
            if ($stderrStream.Length + $messageBytes.Length -le $MaximumStreamBytes) { $stderrStream.Write($messageBytes,0,$messageBytes.Length) }
        }
    } finally {
        if ($processStarted -and -not $process.HasExited) {
            $cleanupAttempted = $true
            try { $process.Kill($true);$cleanupSucceeded=$process.WaitForExit(10000) } catch { $cleanupSucceeded=$false }
            if (-not $cleanupSucceeded) { $category='child-cleanup-fail';$result='fail' }
        }
        if ($readinessArtifactsOwned) {
            foreach ($ownedReadinessPath in @($readyHandshakePendingPath,$ReadyHandshakePath)) {
                if (-not [string]::IsNullOrWhiteSpace($ownedReadinessPath) -and [IO.File]::Exists($ownedReadinessPath)) {
                    try { [IO.File]::Delete($ownedReadinessPath) }
                    catch { $cleanupSucceeded=$false;$category='child-cleanup-fail';$result='fail' }
                }
            }
        }
        $stdoutStream.Flush($true)
        $stderrStream.Flush($true)
        $stdoutStream.Dispose()
        $stderrStream.Dispose()
        if ($processStarted -and $null -eq $exitCode) {
            try { if ($process.HasExited) { $exitCode=[int]$process.ExitCode } } catch {}
        }
        $process.Dispose()
    }
    $cleanup = [pscustomobject][ordered]@{ attempted=$cleanupAttempted;succeeded=$cleanupSucceeded }
    $terminal = New-MorphospaceHistoricalDebtPhaseTerminal -EvidenceRoot $root -Sequence $Sequence -PhaseId $PhaseId -Command $command -Start $start -Result $result -Category $category -ExitCode $exitCode -TimedOut $timedOut -Cleanup $cleanup -StdoutPath $stdoutPath -StderrPath $stderrPath -DiagnosticBytesStreamed $diagnosticBytes -DiagnosticBytesSuppressed $suppressedBytes
    return [pscustomobject]@{ terminal=$terminal.record;terminal_reference=$terminal.reference;readiness=$readyHandshake;stdout_path=$stdoutPath;stderr_path=$stderrPath }
}

function Invoke-MorphospaceHistoricalDebtActionPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][ValidateRange(1,999)][int]$Sequence,
        [Parameter(Mandatory)][string]$PhaseId,
        [Parameter(Mandatory)][string]$OwnerPath,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$SuccessCategory = 'completed',
        [string]$FailureCategory = 'code-fail'
    )
    $root = (Resolve-Path -LiteralPath $EvidenceRoot).Path
    $stdoutLeaf = ('{0:d3}-{1}.stdout.log' -f $Sequence,$PhaseId)
    $stderrLeaf = ('{0:d3}-{1}.stderr.log' -f $Sequence,$PhaseId)
    $stdoutPath = Join-Path $root $stdoutLeaf
    $stderrPath = Join-Path $root $stderrLeaf
    $stdoutStream = $null
    $stderrStream = $null
    try {
        $stdoutStream = [IO.FileStream]::new($stdoutPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $stderrStream = [IO.FileStream]::new($stderrPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    } catch {
        if ($null -ne $stdoutStream) { $stdoutStream.Dispose() }
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-collision' -Message "Historical-debt action phase stream output already exists: $PhaseId")
    }
    $command = Get-MorphospaceHistoricalDebtCommandRecord -Kind in-process -Path $OwnerPath -Arguments @() -WorkingDirectory $moduleRoot
    $start = New-MorphospaceHistoricalDebtPhaseStart -EvidenceRoot $root -Sequence $Sequence -PhaseId $PhaseId -Command $command -TimeoutSeconds 0 -StdoutLeaf $stdoutLeaf -StderrLeaf $stderrLeaf
    $result='pass'
    $category=$SuccessCategory
    $value=$null
    try {
        $value = & $Action
    } catch {
        $result='fail'
        $category=$FailureCategory
        if ($_.Exception.Data.Contains('morphospace_phase_category')) { $category=[string]$_.Exception.Data['morphospace_phase_category'] }
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes([string]$_.Exception.Message + [Environment]::NewLine)
        $stderrStream.Write($bytes,0,$bytes.Length)
    } finally {
        $stdoutStream.Flush($true);$stderrStream.Flush($true)
        $stdoutStream.Dispose();$stderrStream.Dispose()
    }
    $cleanup=[pscustomobject][ordered]@{attempted=$false;succeeded=$true}
    $terminal=New-MorphospaceHistoricalDebtPhaseTerminal -EvidenceRoot $root -Sequence $Sequence -PhaseId $PhaseId -Command $command -Start $start -Result $result -Category $category -ExitCode $null -TimedOut $false -Cleanup $cleanup -StdoutPath $stdoutPath -StderrPath $stderrPath -DiagnosticBytesStreamed 0 -DiagnosticBytesSuppressed 0
    return [pscustomobject]@{terminal=$terminal.record;terminal_reference=$terminal.reference;value=$value;stdout_path=$stdoutPath;stderr_path=$stderrPath}
}

function Write-MorphospaceHistoricalDebtCanonicalBaselineEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][object]$Baseline
    )
    $json = ConvertTo-MorphospaceCanonicalJson -Value $Baseline
    $schemaPath = Join-Path $moduleRoot 'schemas/historical-validation-debt-baseline-v1.schema.json'
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'Historical-debt baseline evidence failed its closed schema.' }
    [byte[]]$bytes = ConvertTo-MorphospaceProtocolJsonBytes -Value $Baseline
    $path = Write-MorphospaceHistoricalDebtCreateNewBytes -Path $EvidencePath -Bytes $bytes
    return [pscustomobject][ordered]@{path=$path;sha256=Get-MorphospaceSha256Bytes -Bytes $bytes;length=[long]$bytes.Length;baseline=$Baseline}
}

function Read-MorphospaceHistoricalDebtCanonicalBaselineEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    $evidence = [IO.Path]::GetFullPath($EvidencePath)
    if (-not [IO.File]::Exists($evidence)) {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'cache-miss' -Message "Historical-debt baseline evidence cache miss: $evidence")
    }
    if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-reuse-rejection' -Message 'Historical-debt baseline evidence expected SHA-256 is invalid.')
    }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($evidence)
    try {
        $actualSha256 = Get-MorphospaceSha256Bytes -Bytes $bytes
        if ($actualSha256 -cne $ExpectedSha256) { throw 'content identity drift' }
        $baseline = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'historical-debt reusable baseline evidence'
        $schemaPath = Join-Path $moduleRoot 'schemas/historical-validation-debt-baseline-v1.schema.json'
        if (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $baseline) -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'closed schema rejection' }
        [byte[]]$canonicalBytes = ConvertTo-MorphospaceProtocolJsonBytes -Value $baseline
        if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($bytes,$canonicalBytes)) { throw 'noncanonical evidence bytes' }
        return [pscustomobject][ordered]@{path=$evidence;sha256=$actualSha256;length=[long]$bytes.Length;bytes=$bytes;baseline=$baseline}
    } catch {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-reuse-rejection' -Message "Historical-debt baseline evidence reuse rejected: $($_.Exception.Message)")
    }
}

function Write-MorphospaceHistoricalDebtBaselineEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepositoryMapPath,
        [Parameter(Mandatory)][string]$BaselineId,
        [Parameter(Mandatory)][object[]]$FailureRecords,
        [Parameter(Mandatory)][datetimeoffset]$CreatedAt
    )
    $baseline = New-MorphospaceHistoricalValidationDebtBaseline -WorkspaceRoot $WorkspaceRoot -RepoRoot $RepoRoot -RepositoryMapPath $RepositoryMapPath -BaselineId $BaselineId -FailureRecords $FailureRecords -CreatedAt $CreatedAt
    $evidence = Write-MorphospaceHistoricalDebtCanonicalBaselineEvidence -EvidencePath $EvidencePath -Baseline $baseline
    $reuseKey = [ordered]@{
        validator_identity_sha256 = [string]$baseline.validator.identity_sha256
        workspace_anchor_sha256 = [string]$baseline.workspace_anchor.identity_sha256
        source_composition_sha256 = [string]$baseline.source_composition.identity_sha256
        current_unit_raw_sha256 = [string]$baseline.current_unit.raw_sha256
        failure_set_sha256 = [string]$baseline.failure_set.sha256
    }
    return [pscustomobject][ordered]@{path=$evidence.path;sha256=$evidence.sha256;length=$evidence.length;reuse_key_sha256=Get-MorphospaceCanonicalJsonSha256 -Value $reuseKey;baseline=$baseline}
}

function Install-MorphospaceHistoricalDebtBaselineEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepositoryMapPath,
        [Parameter(Mandatory)][string]$ExpectedEvidenceSha256
    )
    $evidence = Read-MorphospaceHistoricalDebtCanonicalBaselineEvidence -EvidencePath $EvidencePath -ExpectedSha256 $ExpectedEvidenceSha256
    [byte[]]$bytes = $evidence.bytes
    $baseline = $evidence.baseline
    try {
        $createdAt = [datetimeoffset]::ParseExact([string]$baseline.created_at,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $expected = New-MorphospaceHistoricalValidationDebtBaseline -WorkspaceRoot $WorkspaceRoot -RepoRoot $RepoRoot -RepositoryMapPath $RepositoryMapPath -BaselineId ([string]$baseline.baseline_id) -FailureRecords @($baseline.failure_records) -CreatedAt $createdAt
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $expected) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $baseline)) { throw 'validator, workspace, source, current-unit, or failure-set identity drift' }
    } catch {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-reuse-rejection' -Message "Historical-debt baseline evidence reuse rejected: $($_.Exception.Message)")
    }
    $relative = "receipts/historical-validation-debt/$([string]$baseline.baseline_id)/baseline.json"
    try {
        Write-MorphospaceManagedProtocolJsonAtomic -WorkspaceRoot $WorkspaceRoot -RelativePath $relative -Value $baseline -NoOverwrite
    } catch {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-collision' -Message "Historical-debt baseline evidence target collision: $($_.Exception.Message)")
    }
    $installed = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $relative -RequireLeaf
    if ((Get-MorphospaceFileSha256 -Path $installed) -cne (Get-MorphospaceSha256Bytes -Bytes $bytes)) {
        throw (New-MorphospaceHistoricalDebtPhaseException -Category 'evidence-reuse-rejection' -Message 'Historical-debt installed baseline bytes differ from reusable evidence.')
    }
    return [pscustomobject][ordered]@{
        status = 'reused'
        source = [pscustomobject][ordered]@{path=$evidence.path;sha256=$evidence.sha256;length=$evidence.length}
        installed = [pscustomobject][ordered]@{path=$relative;sha256=Get-MorphospaceFileSha256 -Path $installed;length=[long]([IO.FileInfo]$installed).Length}
        reuse_key_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value ([ordered]@{
            validator_identity_sha256=[string]$baseline.validator.identity_sha256
            workspace_anchor_sha256=[string]$baseline.workspace_anchor.identity_sha256
            source_composition_sha256=[string]$baseline.source_composition.identity_sha256
            current_unit_raw_sha256=[string]$baseline.current_unit.raw_sha256
            failure_set_sha256=[string]$baseline.failure_set.sha256
        })
        authenticated = $false
        superseded_history_reconstructed = $false
    }
}

Export-ModuleMember -Function Initialize-MorphospaceHistoricalDebtEvidenceSession, Invoke-MorphospaceHistoricalDebtChildPhase, Invoke-MorphospaceHistoricalDebtActionPhase, Write-MorphospaceHistoricalDebtReadyHandshake, Read-MorphospaceHistoricalDebtReadyHandshake, Write-MorphospaceHistoricalDebtCanonicalBaselineEvidence, Read-MorphospaceHistoricalDebtCanonicalBaselineEvidence, Write-MorphospaceHistoricalDebtBaselineEvidence, Install-MorphospaceHistoricalDebtBaselineEvidence
