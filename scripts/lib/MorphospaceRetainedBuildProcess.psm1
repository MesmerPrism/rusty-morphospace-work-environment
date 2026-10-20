Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$script:RetainedBuildCode=@'
using System;
using System.IO;
using System.Threading.Tasks;
namespace Morphospace.RetainedBuildV2 {
  public sealed class Signals : IDisposable {
    public volatile bool ConsoleCancelled;
    readonly ConsoleCancelEventHandler handler;
    public Signals() {
      handler=(sender,args)=>{args.Cancel=true; ConsoleCancelled=true;};
      Console.CancelKeyPress+=handler;
    }
    public void Dispose(){Console.CancelKeyPress-=handler;}
  }
  public sealed class Drain {
    public long DrainedBytes,StoredBytes;
    public bool Eof;
    public string ReadError,StorageError;
    public Task Completion;
    public static Drain Start(Stream input,FileStream sink,long failAfterBytes) {
      var d=new Drain();
      d.Completion=Task.Run(async ()=>{
        var buffer=new byte[65536];
        bool writable=sink!=null;
        if(!writable)d.StorageError="raw-sink-unavailable";
        while(true){
          int n;
          try {n=await input.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false);}
          catch {d.ReadError="raw-read-failed"; break;}
          if(n==0){d.Eof=true;break;}
          d.DrainedBytes+=n;
          if(!writable)continue;
          try {
            if(failAfterBytes>=0 && d.StoredBytes+n>failAfterBytes)throw new IOException("injected-sink-failure");
            await sink.WriteAsync(buffer,0,n).ConfigureAwait(false);
            d.StoredBytes+=n;
          } catch {d.StorageError="raw-write-failed";writable=false;}
        }
        if(sink!=null){try{sink.Flush(true);}catch{d.StorageError="raw-flush-failed";}}
      });
      return d;
    }
  }
}
'@
if(-not('Morphospace.RetainedBuildV2.Drain'-as[type])){Add-Type -TypeDefinition $script:RetainedBuildCode}

function Invoke-MorphospaceRetainedBuildProcess {
    [CmdletBinding()]
    param(
      [Parameter(Mandatory)][object]$Execution,
      [Parameter(Mandatory)][hashtable]$EnvironmentValues,
      [Parameter(Mandatory)][string]$BaseReceiptPath,
      [Parameter(Mandatory)][long]$EstimatedWarningSeconds,
      [int]$CancelAfterMilliseconds=0,
      [string]$TestCancellationGate='',
      [long]$TestFailStdoutAfterBytes=-1,
      [switch]$TestWarningPublicationFailure
    )
    if($EstimatedWarningSeconds-lt1){throw 'Positive warning estimate required'}
    $stdoutFinal="$BaseReceiptPath.stdout.bin";$stderrFinal="$BaseReceiptPath.stderr.bin"
    foreach($path in @($stdoutFinal,$stderrFinal)){if(Test-Path -LiteralPath $path){throw 'Create-new raw evidence paths required'}}
    $stdoutTemp="$stdoutFinal.$([guid]::NewGuid().ToString('N')).tmp"
    $stderrTemp="$stderrFinal.$([guid]::NewGuid().ToString('N')).tmp"
    $parent=Split-Path -Parent ([IO.Path]::GetFullPath($BaseReceiptPath))
    [IO.Directory]::CreateDirectory($parent)|Out-Null
    $stdoutStream=$null;$stderrStream=$null;$process=$null;$signals=$null
    $stdoutDrain=$null;$stderrDrain=$null;$started=$false
    $timer=[Diagnostics.Stopwatch]::new()
    $errors=[Collections.Generic.List[string]]::new()
    $warningCount=0L;$warningFailures=0L;$terminationRequested=$false
    $cancellation='not-requested'
    try {
      # Prepare both sinks before the only dispatch. Never abandon an issued
      # child because opening the second sink or publishing a warning failed.
      $stdoutStream=[IO.File]::Open($stdoutTemp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
      $stderrStream=[IO.File]::Open($stderrTemp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
      $psi=[Diagnostics.ProcessStartInfo]::new()
      $psi.FileName=[string]$Execution.FileName;$psi.WorkingDirectory=[string]$Execution.WorkingDirectory
      $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
      $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
      $psi.Environment.Clear()
      foreach($name in @($EnvironmentValues.Keys|Sort-Object)){$psi.Environment[$name]=[string]$EnvironmentValues[$name]}
      foreach($argument in @($Execution.Arguments)){[void]$psi.ArgumentList.Add([string]$argument)}
      $signals=[Morphospace.RetainedBuildV2.Signals]::new()
      $process=[Diagnostics.Process]::new();$process.StartInfo=$psi
      if(-not$process.Start()){throw 'Build process did not start'}
      $started=$true;$timer.Start()
      $stdoutDrain=[Morphospace.RetainedBuildV2.Drain]::Start($process.StandardOutput.BaseStream,$stdoutStream,$TestFailStdoutAfterBytes)
      $stderrDrain=[Morphospace.RetainedBuildV2.Drain]::Start($process.StandardError.BaseStream,$stderrStream,-1)
      $nextWarning=[double]$EstimatedWarningSeconds
      while(-not$process.HasExited-or-not$stdoutDrain.Completion.IsCompleted-or-not$stderrDrain.Completion.IsCompleted){
        $testCancel=($CancelAfterMilliseconds-gt0-and$timer.ElapsedMilliseconds-ge$CancelAfterMilliseconds)-or($TestCancellationGate-and(Test-Path -LiteralPath $TestCancellationGate))
        if(-not$terminationRequested-and($signals.ConsoleCancelled-or$testCancel)){
          $terminationRequested=$true
          $cancellation=if($signals.ConsoleCancelled){'console-cancel'}else{'test-cancel'}
          if(-not$process.HasExited){try{$process.Kill($true)}catch{$errors.Add('requested-cancel-signal-failed')}}
        }
        if($timer.Elapsed.TotalSeconds-ge$nextWarning){
          $warningCount++
          try{
            if($TestWarningPublicationFailure){throw 'modeled-warning-sink-failure'}
            [Console]::Error.WriteLine('WARNING: build exceeds its estimate; retaining the same child and both readers until actual exit/reap/EOF. Explicit cancellation remains available.')
          }catch{$warningFailures++}
          $nextWarning=$timer.Elapsed.TotalSeconds+[double]$EstimatedWarningSeconds
        }
        [Threading.Thread]::Sleep(25)
      }
      $process.WaitForExit()
      foreach($drain in @($stdoutDrain,$stderrDrain)){try{[void]$drain.Completion.GetAwaiter().GetResult()}catch{$errors.Add('reader-task-failed')}}
      $timer.Stop();$exitCode=[int]$process.ExitCode
      try{$stdoutStream.Dispose()}catch{$errors.Add('stdout-final-close-failed')};$stdoutStream=$null
      try{$stderrStream.Dispose()}catch{$errors.Add('stderr-final-close-failed')};$stderrStream=$null
      # Partial raw output is evidence too. Retain it under the final immutable
      # name, then report capture failure honestly after settling the original.
      $streams=[ordered]@{captured=$true;stdout=$null;stderr=$null}
      foreach($row in @(@{name='stdout';temp=$stdoutTemp;final=$stdoutFinal;drain=$stdoutDrain},@{name='stderr';temp=$stderrTemp;final=$stderrFinal;drain=$stderrDrain})){
        $length=$null;$sha=$null;$rawPath=$row.temp
        try{
          $length=(Get-Item -LiteralPath $row.temp).Length
          $sha=(Get-FileHash -LiteralPath $row.temp -Algorithm SHA256).Hash.ToLowerInvariant()
        }catch{$errors.Add($row.name+'-raw-authentication-failed')}
        try{[IO.File]::Move($row.temp,$row.final);$rawPath=$row.final}catch{$errors.Add($row.name+'-raw-finalization-failed')}
        $streams[$row.name]=[ordered]@{path=$rawPath;sha256=$sha;size_bytes=$length;drained_bytes=$row.drain.DrainedBytes;stored_bytes=$row.drain.StoredBytes;eof=$row.drain.Eof;storage_error=$row.drain.StorageError;read_error=$row.drain.ReadError}
      }
      $rawComplete=$errors.Count-eq0
      foreach($s in @($streams.stdout,$streams.stderr)){
        if(-not$s.eof-or$null-eq$s.sha256-or$null-eq$s.size_bytes-or$null-ne$s.storage_error-or$null-ne$s.read_error-or$s.drained_bytes-ne$s.stored_bytes-or$s.stored_bytes-ne$s.size_bytes){$rawComplete=$false}
      }
      $status=if($terminationRequested){'cancelled'}elseif($exitCode-ne0-or-not$rawComplete){'failed'}else{'passed'}
      return [pscustomobject]@{Status=$status;ExitCode=$exitCode;Streams=$streams;ChildProcess=[ordered]@{
        started=$true;outcome=$status;estimated_warning_seconds=$EstimatedWarningSeconds;elapsed_milliseconds=$timer.ElapsedMilliseconds
        cancellation=$cancellation;termination_requested=$terminationRequested;automatic_retry=$false;process_reaped=$true
        stdout_eof=$stdoutDrain.Eof;stderr_eof=$stderrDrain.Eof;raw_capture_complete=$rawComplete
        warning_count=$warningCount;warning_publication_failures=$warningFailures;observer_errors=@($errors.ToArray());exit_code=$exitCode
      }}
    } finally {
      # No automatic kill in error cleanup. Keep the once-issued process and
      # actual readers owned even if an observer/publication operation throws.
      if($started){
        if($null-eq$stdoutDrain){$stdoutDrain=[Morphospace.RetainedBuildV2.Drain]::Start($process.StandardOutput.BaseStream,$stdoutStream,-1)}
        if($null-eq$stderrDrain){$stderrDrain=[Morphospace.RetainedBuildV2.Drain]::Start($process.StandardError.BaseStream,$stderrStream,-1)}
        $process.WaitForExit()
        foreach($drain in @($stdoutDrain,$stderrDrain)){try{[void]$drain.Completion.GetAwaiter().GetResult()}catch{}}
      }
      if($null-ne$signals){$signals.Dispose()}
      foreach($stream in @($stdoutStream,$stderrStream)){if($null-ne$stream){$stream.Dispose()}}
      if($null-ne$process){$process.Dispose()}
      # No deletion of partial raw evidence, and no replay.
    }
}
Export-ModuleMember -Function Invoke-MorphospaceRetainedBuildProcess
