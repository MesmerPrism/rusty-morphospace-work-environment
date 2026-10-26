# Shared owner for isolated workflow self-tests. No workflow or fixture module is imported here.
function New-IsolatedWorkflowSelfTestStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @()
    )
    $hostPath = [Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($hostPath) -or -not [IO.File]::Exists($hostPath)) {
        $hostPath = (Get-Command pwsh -ErrorAction Stop).Source
    }
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$hostPath;$start.WorkingDirectory=[IO.Path]::GetFullPath($RepositoryRoot);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Path)+@($Arguments)){[void]$start.ArgumentList.Add([string]$argument)}
    $start.Environment.Clear()
    $runtimeNames=@('COMSPEC','HOME','PATH','PATHEXT','SYSTEMROOT','TEMP','TMP','TMPDIR','WINDIR')
    foreach($name in $runtimeNames){$value=[Environment]::GetEnvironmentVariable($name,'Process');if($null-ne$value){$start.Environment[$name]=[string]$value}}
    if(@($start.Environment.Keys|Where-Object{[string]$_-like'GIT_*'-or$runtimeNames-cnotcontains[string]$_}).Count-ne0){throw 'Isolated workflow self-test environment projection is not closed.'}
    return $start
}

function Invoke-IsolatedWorkflowSelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @(),
        [ValidateRange(1,900)][int]$TimeoutSeconds = 240,
        # In this mode TimeoutSeconds does not establish a cancellation deadline.
        [switch]$CompletionPreserving
    )

    $parentEnvironmentBefore = Get-WorkflowProcessEnvironmentDigest
    $start=New-IsolatedWorkflowSelfTestStartInfo -RepositoryRoot $RepositoryRoot -Path $Path -Arguments $Arguments
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $stdout=[IO.MemoryStream]::new();$stderr=[IO.MemoryStream]::new();$stdoutBuffer=[byte[]]::new(8192);$stderrBuffer=[byte[]]::new(8192);$stdoutTask=$null;$stderrTask=$null;$deadline=if($CompletionPreserving){$null}else{[DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)};$started=$false;$runFailure=$null;$cleanupFailure=$null;$exitCode=$null
    try {
        if(-not$process.Start()){throw "Isolated workflow self-test '$([IO.Path]::GetFileName($Path))' did not start."};$started=$true
        $stdoutTask=$process.StandardOutput.BaseStream.ReadAsync($stdoutBuffer,0,$stdoutBuffer.Length)
        $stderrTask=$process.StandardError.BaseStream.ReadAsync($stderrBuffer,0,$stderrBuffer.Length)
        while($null-ne$stdoutTask-or$null-ne$stderrTask){
            if(-not$CompletionPreserving-and[DateTimeOffset]::UtcNow-ge$deadline){throw "Isolated workflow self-test '$([IO.Path]::GetFileName($Path))' exceeded its $TimeoutSeconds second bound."}
            $pending=[Collections.Generic.List[Threading.Tasks.Task]]::new();$labels=[Collections.Generic.List[string]]::new()
            if($null-ne$stdoutTask){$pending.Add($stdoutTask);$labels.Add('stdout')};if($null-ne$stderrTask){$pending.Add($stderrTask);$labels.Add('stderr')}
            $completed=[Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]$pending.ToArray(),100)
            if($completed-lt0){continue};$label=$labels[$completed]
            if($label-ceq'stdout'){$read=$stdoutTask.GetAwaiter().GetResult();if($read-eq0){$stdoutTask=$null}else{$stdout.Write($stdoutBuffer,0,$read);$stdoutTask=$process.StandardOutput.BaseStream.ReadAsync($stdoutBuffer,0,$stdoutBuffer.Length)}}else{$read=$stderrTask.GetAwaiter().GetResult();if($read-eq0){$stderrTask=$null}else{$stderr.Write($stderrBuffer,0,$read);$stderrTask=$process.StandardError.BaseStream.ReadAsync($stderrBuffer,0,$stderrBuffer.Length)}}
            if($stdout.Length+$stderr.Length-gt10485760){throw "Isolated workflow self-test '$([IO.Path]::GetFileName($Path))' exceeded its combined 10 MiB output bound."}
        }
        if(-not$process.HasExited){
            if($CompletionPreserving){$process.WaitForExit()}else{$remaining=[Math]::Max(1,[int]($deadline-[DateTimeOffset]::UtcNow).TotalMilliseconds);if(-not$process.WaitForExit($remaining)){throw "Isolated workflow self-test '$([IO.Path]::GetFileName($Path))' exceeded its $TimeoutSeconds second bound."}}
        }
        $exitCode=$process.ExitCode
    } catch {
        $runFailure=$_.Exception
    } finally {
        if($started-and-not$process.HasExited){try{$process.Kill($true)}catch{$cleanupFailure=$_.Exception};if(-not$process.WaitForExit(5000)-and$null-eq$cleanupFailure){$cleanupFailure=[TimeoutException]::new('Isolated workflow self-test killed child did not exit within 5 seconds.')}}
        $drains=[Collections.Generic.List[Threading.Tasks.Task]]::new();if($null-ne$stdoutTask){$drains.Add($stdoutTask)};if($null-ne$stderrTask){$drains.Add($stderrTask)}
        if($drains.Count-gt0){try{if(-not[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$drains.ToArray(),5000)-and$null-eq$cleanupFailure){$cleanupFailure=[TimeoutException]::new('Isolated workflow self-test streams did not drain within 5 seconds after child termination.')}}catch{if($null-eq$cleanupFailure){$cleanupFailure=$_.Exception}}}
        $stdoutBytes=$stdout.ToArray();$stderrBytes=$stderr.ToArray();$stdout.Dispose();$stderr.Dispose();$process.Dispose()
    }
    if((Get-WorkflowProcessEnvironmentDigest)-cne$parentEnvironmentBefore){throw 'Isolated workflow self-test changed parent environment bytes.'}
    if($null-ne$cleanupFailure){throw $cleanupFailure};if($null-ne$runFailure){throw $runFailure}
    if ($exitCode -ne 0) {
        $detail = ([Text.UTF8Encoding]::new($false).GetString($stdoutBytes)+[Environment]::NewLine+[Text.UTF8Encoding]::new($false).GetString($stderrBytes)).Trim()
        throw "Isolated workflow self-test '$([IO.Path]::GetFileName($Path))' failed with exit $exitCode.$([Environment]::NewLine)$detail"
    }
    return [pscustomobject][ordered]@{exit_code=$exitCode;stdout=$stdoutBytes;stderr=$stderrBytes}
}

function Get-WorkflowProcessEnvironmentDigest {
    [string[]]$names=@([Environment]::GetEnvironmentVariables('Process').Keys|ForEach-Object{[string]$_});if($names.Count-gt1){[Array]::Sort($names,[StringComparer]::Ordinal)}
    $text=[Text.StringBuilder]::new();foreach($name in $names){[void]$text.Append($name);[void]$text.Append("`0");[void]$text.Append([string][Environment]::GetEnvironmentVariable($name,'Process'));[void]$text.Append("`0")}
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($text.ToString())))).ToLowerInvariant()
}

Export-ModuleMember -Function New-IsolatedWorkflowSelfTestStartInfo, Invoke-IsolatedWorkflowSelfTest, Get-WorkflowProcessEnvironmentDigest
