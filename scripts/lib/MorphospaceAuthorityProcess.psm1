Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if($IsWindows-and$null-eq('Rusty.Morphospace.AuthorityProcessJob'-as[type])){
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Rusty.Morphospace {
    public sealed class AuthorityProcessJob : IDisposable {
        const uint JobObjectAssociateCompletionPortInformation = 7;
        const uint JobObjectExtendedLimitInformation = 9;
        const uint JobObjectBasicAccountingInformation = 1;
        const uint JobObjectLimitKillOnJobClose = 0x00002000;
        const int WaitTimeout = 258;
        IntPtr job;
        IntPtr completionPort;

        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimitInformation {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimitInformation {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct AssociateCompletionPort {
            public IntPtr CompletionKey;
            public IntPtr CompletionPort;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct BasicAccountingInformation {
            public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
        }

        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr CreateJobObjectW(IntPtr jobAttributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool SetInformationJobObject(IntPtr job, uint informationClass, IntPtr information, uint informationLength);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool QueryInformationJobObject(IntPtr job, uint informationClass, IntPtr information, uint informationLength, out uint returnLength);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr CreateIoCompletionPort(IntPtr file, IntPtr existingCompletionPort, UIntPtr completionKey, uint concurrentThreads);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetQueuedCompletionStatus(IntPtr completionPort, out uint completionCode, out UIntPtr completionKey, out IntPtr overlapped, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool CloseHandle(IntPtr handle);

        static void SetJobInformation<T>(IntPtr jobHandle, uint informationClass, T value) where T : struct {
            int size = Marshal.SizeOf<T>();
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(value, buffer, false);
                if(!SetInformationJobObject(jobHandle, informationClass, buffer, (uint)size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        public AuthorityProcessJob() {
            job = CreateJobObjectW(IntPtr.Zero, null);
            if(job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                var limits = new ExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
                SetJobInformation(job, JobObjectExtendedLimitInformation, limits);
                completionPort = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
                if(completionPort == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                var association = new AssociateCompletionPort { CompletionKey = job, CompletionPort = completionPort };
                SetJobInformation(job, JobObjectAssociateCompletionPortInformation, association);
            } catch { Dispose(); throw; }
        }

        public void AssignProcess(IntPtr processHandle) {
            if(job == IntPtr.Zero) throw new ObjectDisposedException(nameof(AuthorityProcessJob));
            if(!AssignProcessToJobObject(job, processHandle)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        public void Terminate() {
            if(job == IntPtr.Zero) throw new ObjectDisposedException(nameof(AuthorityProcessJob));
            if(!TerminateJobObject(job, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        uint GetActiveProcessCount() {
            int size = Marshal.SizeOf<BasicAccountingInformation>();
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                uint returnLength;
                if(!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, buffer, (uint)size, out returnLength)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return Marshal.PtrToStructure<BasicAccountingInformation>(buffer).ActiveProcesses;
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        public bool WaitForEmpty(int timeoutMilliseconds) {
            if(completionPort == IntPtr.Zero) throw new ObjectDisposedException(nameof(AuthorityProcessJob));
            long deadline = Environment.TickCount64 + timeoutMilliseconds;
            while(true) {
                if(GetActiveProcessCount() == 0) return true;
                long remaining = deadline - Environment.TickCount64;
                if(remaining <= 0) return false;
                uint code;
                UIntPtr key;
                IntPtr overlapped;
                bool completed = GetQueuedCompletionStatus(completionPort, out code, out key, out overlapped, (uint)Math.Min(remaining, uint.MaxValue));
                if(!completed) {
                    int error = Marshal.GetLastWin32Error();
                    if(error == WaitTimeout) return GetActiveProcessCount() == 0;
                    throw new Win32Exception(error);
                }
            }
        }

        public void Dispose() {
            IntPtr jobHandle = job;
            IntPtr portHandle = completionPort;
            job = IntPtr.Zero;
            completionPort = IntPtr.Zero;
            if(jobHandle != IntPtr.Zero) CloseHandle(jobHandle);
            if(portHandle != IntPtr.Zero) CloseHandle(portHandle);
            GC.SuppressFinalize(this);
        }

        ~AuthorityProcessJob() { Dispose(); }
    }
}
'@
}

function ConvertTo-MorphospaceWindowsProcessArgument {
    param([AllowEmptyString()][string]$Value)
    if($Value.Length-eq0){return '""'}
    if($Value-notmatch'[\s"]'){return $Value}
    $builder=[Text.StringBuilder]::new();[void]$builder.Append([char]34);$slashes=0
    foreach($character in $Value.ToCharArray()){
        if($character-eq[char]92){$slashes++;continue}
        if($character-eq[char]34){[void]$builder.Append([char]92,(2*$slashes)+1);[void]$builder.Append([char]34);$slashes=0;continue}
        if($slashes-gt0){[void]$builder.Append([char]92,$slashes);$slashes=0};[void]$builder.Append($character)
    }
    if($slashes-gt0){[void]$builder.Append([char]92,2*$slashes)};[void]$builder.Append([char]34);return $builder.ToString()
}

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
    if(-not$IsWindows){throw 'Authority process supervision requires Windows Job Object support.'}
    $executable=[IO.Path]::GetFullPath($FilePath)
    if(-not[IO.File]::Exists($executable)){throw "Authority child executable does not exist: $executable"}
    $supervisor=[IO.Path]::Combine($PSHOME,'pwsh.exe');if(-not[IO.File]::Exists($supervisor)){throw "Authority process supervisor is unavailable: $supervisor"}
    $stdout=[IO.Path]::GetFullPath($StdoutPath);$stderr=[IO.Path]::GetFullPath($StderrPath)
    if($stdout.Equals($stderr,[StringComparison]::OrdinalIgnoreCase)){throw 'Authority child stdout and stderr paths must be distinct.'}
    foreach($path in @($stdout,$stderr)){
        if([IO.File]::Exists($path)-or[IO.Directory]::Exists($path)){throw "Authority child capture path must be absent before launch: $path"}
        $parent=[IO.Path]::GetDirectoryName($path);if(-not[IO.Directory]::Exists($parent)){throw "Authority child capture parent does not exist: $parent"}
    }
    $argumentLine=(@($Arguments)|ForEach-Object{ConvertTo-MorphospaceWindowsProcessArgument ([string]$_)})-join' '
    $supervisorWait=[int]$(if($TimeoutMilliseconds-le2147423647){$TimeoutMilliseconds+60000}else{2147483647})
    $launchEventName='Local\MorphospaceAuthorityLaunch-'+[guid]::NewGuid().ToString('N');$launchReady=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$launchEventName)
    $payload=[pscustomobject][ordered]@{file_path=$executable;argument_line=$argumentLine;wait_milliseconds=$supervisorWait;launch_event=$launchEventName}
    $payloadBase64=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($payload|ConvertTo-Json -Compress)))
    $supervisorBody=@"
`$ErrorActionPreference='Stop'
`$payload=[Text.UTF8Encoding]::new(`$false).GetString([Convert]::FromBase64String('$payloadBase64'))|ConvertFrom-Json
`$launchReady=[Threading.EventWaitHandle]::OpenExisting([string]`$payload.launch_event);`$child=`$null
try{
    if([Console]::In.ReadLine()-cne'launch'){exit 125}
    `$start=@{FilePath=[string]`$payload.file_path;NoNewWindow=`$true;PassThru=`$true}
    if(-not[string]::IsNullOrEmpty([string]`$payload.argument_line)){`$start.ArgumentList=[string]`$payload.argument_line}
    `$child=Start-Process @start;`$launchReady.Set()|Out-Null
    if(-not`$child.WaitForExit([int]`$payload.wait_milliseconds)){exit 124};exit [int]`$child.ExitCode
}finally{if(`$null-ne`$child){`$child.Dispose()};`$launchReady.Dispose()}
"@
    $encodedSupervisor=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($supervisorBody))
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$supervisor;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encodedSupervisor)){[void]$start.ArgumentList.Add($argument)}
    $fileOptions=[IO.FileOptions]([int][IO.FileOptions]::Asynchronous -bor [int][IO.FileOptions]::WriteThrough)
    $stdoutStream=$null;$stderrStream=$null;$stdoutTask=$null;$stderrTask=$null;$process=[Diagnostics.Process]::new();$process.StartInfo=$start;$job=$null;$started=$false;$assigned=$false;$terminationVerified=$false
    try{
        $stdoutStream=[IO.FileStream]::new($stdout,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,65536,$fileOptions)
        $stderrStream=[IO.FileStream]::new($stderr,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,65536,$fileOptions)
        $job=[Rusty.Morphospace.AuthorityProcessJob]::new()
        if(-not$process.Start()){throw 'Authority process supervisor did not start.'};$started=$true
        $stdoutTask=$process.StandardOutput.BaseStream.CopyToAsync($stdoutStream);$stderrTask=$process.StandardError.BaseStream.CopyToAsync($stderrStream);$tasks=[Threading.Tasks.Task[]]@($stdoutTask,$stderrTask)
        $job.AssignProcess($process.Handle);$assigned=$true
        $process.StandardInput.WriteLine('launch');$process.StandardInput.Dispose()
        if(-not$launchReady.WaitOne($TerminationTimeoutMilliseconds)){throw "Authority target did not start within $TerminationTimeoutMilliseconds milliseconds."}
        $timedOut=-not$process.WaitForExit($TimeoutMilliseconds)
        $exitCode=if($timedOut){$null}else{[int]$process.ExitCode}
        $job.Terminate()
        if(-not$job.WaitForEmpty($TerminationTimeoutMilliseconds)){throw "Authority process tree did not terminate within $TerminationTimeoutMilliseconds milliseconds."}
        $terminationVerified=$true
        if(-not$process.HasExited-and-not$process.WaitForExit($TerminationTimeoutMilliseconds)){throw "Authority process supervisor did not terminate within $TerminationTimeoutMilliseconds milliseconds."}
        if(-not[Threading.Tasks.Task]::WaitAll($tasks,$DrainTimeoutMilliseconds)){throw "Authority process tree terminated but its redirected streams did not drain within $DrainTimeoutMilliseconds milliseconds."}
        [void]$stdoutTask.GetAwaiter().GetResult();[void]$stderrTask.GetAwaiter().GetResult();$stdoutStream.Flush($true);$stderrStream.Flush($true)
        if($timedOut){throw [TimeoutException]::new("Authority child exceeded its timeout of $TimeoutMilliseconds milliseconds.")}
        $result=[pscustomobject][ordered]@{exit_code=$exitCode;stdout_path=$stdout;stderr_path=$stderr}
    }finally{
        $cleanupFailure=$null
        if($assigned-and-not$terminationVerified){
            try{
                $terminationFailure=$null;try{$job.Terminate()}catch{$terminationFailure=$_.Exception}
                if($job.WaitForEmpty($TerminationTimeoutMilliseconds)){$terminationVerified=$true}
                elseif($null-ne$terminationFailure){throw $terminationFailure}
                else{throw [InvalidOperationException]::new("Authority process cleanup did not observe an empty job within $TerminationTimeoutMilliseconds milliseconds.")}
            }catch{$cleanupFailure=$_.Exception}
        }
        if($started-and-not$process.HasExited){try{$process.Kill($true);if(-not$process.WaitForExit($TerminationTimeoutMilliseconds)-and$null-eq$cleanupFailure){$cleanupFailure=[InvalidOperationException]::new("Authority process supervisor cleanup did not finish within $TerminationTimeoutMilliseconds milliseconds.")}}catch{if($null-eq$cleanupFailure){$cleanupFailure=$_.Exception}}}
        try{$process.StandardInput.Dispose()}catch{}
        if(($null-ne$stdoutTask-and-not$stdoutTask.IsCompleted)-or($null-ne$stderrTask-and-not$stderrTask.IsCompleted)){try{$process.StandardOutput.Dispose()}catch{};try{$process.StandardError.Dispose()}catch{};$pending=@($stdoutTask,$stderrTask)|Where-Object{$null-ne$_};if($pending.Count-gt0){try{[void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$pending,$DrainTimeoutMilliseconds)}catch{}}}
        if($null-ne$stdoutStream){$stdoutStream.Dispose()};if($null-ne$stderrStream){$stderrStream.Dispose()};$process.Dispose();if($null-ne$job){$job.Dispose()};$launchReady.Dispose()
        if($null-ne$cleanupFailure){throw $cleanupFailure}
    }
    return $result
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Invoke-MorphospaceCapturedProcess
