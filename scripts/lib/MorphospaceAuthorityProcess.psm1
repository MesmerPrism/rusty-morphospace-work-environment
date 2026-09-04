Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-MorphospaceCapturedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments=@(),
        [Parameter(Mandatory=$true)][string]$StdoutPath,
        [Parameter(Mandatory=$true)][string]$StderrPath,
        [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$TimeoutMilliseconds,
        [ValidateRange(1,60000)][int]$TerminationTimeoutMilliseconds=10000,
        [ValidateRange(1,60000)][int]$DrainTimeoutMilliseconds=10000
    )
    $executable=[IO.Path]::GetFullPath($FilePath)
    if(-not[IO.File]::Exists($executable)){throw "Authority child executable does not exist: $executable"}
    $stdout=[IO.Path]::GetFullPath($StdoutPath);$stderr=[IO.Path]::GetFullPath($StderrPath)
    if($stdout.Equals($stderr,[StringComparison]::OrdinalIgnoreCase)){throw 'Authority child stdout and stderr paths must be distinct.'}
    foreach($path in @($stdout,$stderr)){
        if([IO.File]::Exists($path)-or[IO.Directory]::Exists($path)){throw "Authority child capture path must be absent before launch: $path"}
        $parent=[IO.Path]::GetDirectoryName($path);if(-not[IO.Directory]::Exists($parent)){throw "Authority child capture parent does not exist: $parent"}
    }
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$executable;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @($Arguments)){[void]$start.ArgumentList.Add([string]$argument)}
    $fileOptions=[IO.FileOptions]([int][IO.FileOptions]::Asynchronous -bor [int][IO.FileOptions]::WriteThrough)
    $stdoutStream=$null;$stderrStream=$null;$stdoutTask=$null;$stderrTask=$null;$process=[Diagnostics.Process]::new();$process.StartInfo=$start;$started=$false
    try{
        $stdoutStream=[IO.FileStream]::new($stdout,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,65536,$fileOptions)
        $stderrStream=[IO.FileStream]::new($stderr,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,65536,$fileOptions)
        if(-not$process.Start()){throw 'Authority child process did not start.'};$started=$true
        $stdoutTask=$process.StandardOutput.BaseStream.CopyToAsync($stdoutStream);$stderrTask=$process.StandardError.BaseStream.CopyToAsync($stderrStream)
        $tasks=[Threading.Tasks.Task[]]@($stdoutTask,$stderrTask)
        if(-not$process.WaitForExit($TimeoutMilliseconds)){
            if(-not$process.HasExited){try{$process.Kill($true)}catch{throw "Authority child timed out and its process tree could not be terminated: $([string]$_.Exception.Message)"}}
            if(-not$process.WaitForExit($TerminationTimeoutMilliseconds)){throw "Authority child timed out and its process tree did not terminate within $TerminationTimeoutMilliseconds milliseconds."}
            if(-not[Threading.Tasks.Task]::WaitAll($tasks,$DrainTimeoutMilliseconds)){throw "Authority child timed out and its redirected streams did not drain within $DrainTimeoutMilliseconds milliseconds after termination."}
            [void]$stdoutTask.GetAwaiter().GetResult();[void]$stderrTask.GetAwaiter().GetResult()
            $stdoutStream.Flush($true);$stderrStream.Flush($true)
            throw [TimeoutException]::new("Authority child exceeded its timeout of $TimeoutMilliseconds milliseconds.")
        }
        $exitCode=[int]$process.ExitCode
        if(-not[Threading.Tasks.Task]::WaitAll($tasks,$DrainTimeoutMilliseconds)){throw "Authority child exited but its redirected streams did not drain within $DrainTimeoutMilliseconds milliseconds."}
        [void]$stdoutTask.GetAwaiter().GetResult();[void]$stderrTask.GetAwaiter().GetResult()
        $stdoutStream.Flush($true);$stderrStream.Flush($true)
        $result=[pscustomobject][ordered]@{exit_code=$exitCode;stdout_path=$stdout;stderr_path=$stderr}
    }finally{
        if($started){
            $running=$false;try{$running=-not$process.HasExited}catch{}
            if($running){try{$process.Kill($true)}catch{};try{[void]$process.WaitForExit($TerminationTimeoutMilliseconds)}catch{}}
        }
        if(($null-ne$stdoutTask-and-not$stdoutTask.IsCompleted)-or($null-ne$stderrTask-and-not$stderrTask.IsCompleted)){
            try{$process.StandardOutput.Dispose()}catch{};try{$process.StandardError.Dispose()}catch{}
            $pending=@($stdoutTask,$stderrTask)|Where-Object{$null-ne$_};if($pending.Count-gt0){try{[void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$pending,$DrainTimeoutMilliseconds)}catch{}}
        }
        if($null-ne$stdoutStream){$stdoutStream.Dispose()};if($null-ne$stderrStream){$stderrStream.Dispose()};$process.Dispose()
    }
    return $result
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Invoke-MorphospaceCapturedProcess
