[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$BaseCommit,
    [Parameter(Mandatory = $true)][string]$HeadCommit,
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$Platform,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [string]$CheckEvidenceDirectory,
    [string]$PriorEvidenceDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationCheckEvidence.psm1') -Force

if (-not ('W017BoundedChildCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class W017BoundedChildResult {
    public bool Started;
    public int? ExitCode;
    public bool TimedOut;
    public bool OutputTruncated;
    public bool PostKillDrainTimedOut;
    public bool ChildTreeCleanupAttempted;
    public bool ChildTreeCleanupSucceeded;
    public bool ContainmentCleanupSucceeded;
    public bool SupervisorEvidenceCleanupSucceeded;
    public string Error;
    public byte[] Stdout = new byte[0];
    public byte[] Stderr = new byte[0];
}

public static class W017BoundedChildCapture {
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const int JobObjectExtendedLimitInformation = 9;
    private const int JobObjectBasicAccountingInformation = 1;
    [StructLayout(LayoutKind.Sequential)] private struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] private struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public IntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
    [StructLayout(LayoutKind.Sequential)] private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION { public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime; public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct PROCESSENTRY32 { public uint dwSize,cntUsage,th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID,cntThreads,th32ParentProcessID; public int pcPriClassBase; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string szExeFile; }
    [StructLayout(LayoutKind.Sequential)] private struct THREADENTRY32 { public uint dwSize,cntUsage,th32ThreadID,th32OwnerProcessID; public int tpBasePri,tpDeltaPri; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential)] private struct TOKEN_DEFAULT_DACL { public IntPtr DefaultDacl; }
    [StructLayout(LayoutKind.Sequential)] private struct TOKEN_OWNER_RECORD { public IntPtr Owner; }
    [StructLayout(LayoutKind.Sequential)] private struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length, IntPtr returnedLength);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access,bool inherit,int processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenThread(uint access,bool inherit,uint threadId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags,uint processId);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode,SetLastError = true)] private static extern bool Process32First(IntPtr snapshot,ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode,SetLastError = true)] private static extern bool Process32Next(IntPtr snapshot,ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool Thread32First(IntPtr snapshot,ref THREADENTRY32 entry);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool Thread32Next(IntPtr snapshot,ref THREADENTRY32 entry);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr value);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token,uint information,IntPtr buffer,uint length,out uint required);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetTokenInformation(IntPtr token,uint information,IntPtr buffer,uint length);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetKernelObjectSecurity(IntPtr handle,uint information,IntPtr descriptor,uint length,out uint required);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetKernelObjectSecurity(IntPtr handle,uint information,IntPtr descriptor);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetSecurityDescriptorDacl(IntPtr descriptor,out bool present,out IntPtr dacl,out bool defaulted);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode,SetLastError = true)] private static extern bool ConvertSidToStringSid(IntPtr sid,out IntPtr text);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode,SetLastError = true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text,uint revision,out IntPtr descriptor,out uint length);
    [DllImport("libc", SetLastError = true)] private static extern int kill(int pid, int signal);
    private sealed class CaptureState {
        public readonly int Limit;
        public int Seen;
        public int Truncated;
        public CaptureState(int limit) { Limit = limit; }
    }
    private sealed class AncestorRestoreSet {
        private readonly System.Collections.Generic.List<IntPtr> handles=new System.Collections.Generic.List<IntPtr>();
        private readonly System.Collections.Generic.List<byte[]> descriptors=new System.Collections.Generic.List<byte[]>();
        private readonly System.Collections.Generic.HashSet<uint> retainedThreadIds=new System.Collections.Generic.HashSet<uint>();
        private readonly System.Collections.Generic.List<IntPtr> tokens=new System.Collections.Generic.List<IntPtr>();
        private readonly System.Collections.Generic.List<byte[]> tokenDacls=new System.Collections.Generic.List<byte[]>();
        private int processId;
        private byte[] protectedDacl;
        private byte[] futureThreadOriginalSecurity;
        public void Add(IntPtr handle,byte[] descriptor){handles.Add(handle);descriptors.Add((byte[])descriptor.Clone());}
        public void AddThread(IntPtr handle,byte[] descriptor,uint id){Add(handle,descriptor);if(id==0||!retainedThreadIds.Add(id))throw new InvalidOperationException("trusted completion parent retained a duplicate thread identity");}
        public void AddToken(IntPtr token,byte[] dacl){tokens.Add(token);tokenDacls.Add((byte[])dacl.Clone());}
        public byte[] FutureThreadOriginalSecurity { get { return (byte[])futureThreadOriginalSecurity.Clone(); } }
        public void ConfigureFutureThreads(int id,byte[] protectedAcl,byte[] originalSecurity){processId=id;protectedDacl=(byte[])protectedAcl.Clone();futureThreadOriginalSecurity=(byte[])originalSecurity.Clone();}
        public IntPtr RetainFutureThread(uint id){if(id==0||futureThreadOriginalSecurity==null)throw new InvalidOperationException("trusted completion parent future-thread verification identity is absent");var handle=OpenThread(0x000e0000,false,id);if(handle==IntPtr.Zero)throw new InvalidOperationException("trusted completion parent future thread could not be retained while protected: "+Marshal.GetLastWin32Error());return handle;}
        public void VerifyFutureThread(IntPtr handle){if(handle==IntPtr.Zero||futureThreadOriginalSecurity==null)throw new InvalidOperationException("trusted completion parent future-thread verification handle is absent");if(!SameSecurity(futureThreadOriginalSecurity,ReadAncestorSecurity(handle)))throw new InvalidOperationException("trusted completion parent future thread retained a non-original owner/DACL after restoration");}
        public void Restore(){Exception failure=null;for(var index=tokens.Count-1;index>=0;index--){var acl=Marshal.AllocHGlobal(tokenDacls[index].Length);var record=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(TOKEN_DEFAULT_DACL)));try{Marshal.Copy(tokenDacls[index],0,acl,tokenDacls[index].Length);Marshal.StructureToPtr(new TOKEN_DEFAULT_DACL{DefaultDacl=acl},record,false);if(!SetTokenInformation(tokens[index],6,record,(uint)Marshal.SizeOf(typeof(TOKEN_DEFAULT_DACL)))){if(failure==null)failure=new InvalidOperationException("trusted ancestor fallback token-default-DACL restoration failed: "+Marshal.GetLastWin32Error());}else{var observed=ReadTokenDefaultDacl(tokens[index]);if(!SameSecurity(tokenDacls[index],observed)&&failure==null)failure=new InvalidOperationException("trusted ancestor fallback token-default-DACL restoration readback differs");}}catch(Exception exception){if(failure==null)failure=exception;}finally{Marshal.FreeHGlobal(record);Marshal.FreeHGlobal(acl);CloseHandle(tokens[index]);}}tokens.Clear();tokenDacls.Clear();for(var index=handles.Count-1;index>=0;index--){var value=Marshal.AllocHGlobal(descriptors[index].Length);try{Marshal.Copy(descriptors[index],0,value,descriptors[index].Length);if(!SetKernelObjectSecurity(handles[index],5,value)){if(failure==null)failure=new InvalidOperationException("trusted ancestor fallback process/thread restoration failed: "+Marshal.GetLastWin32Error());}else{var observed=ReadAncestorSecurity(handles[index]);if(!SameSecurity(descriptors[index],observed)&&failure==null)failure=new InvalidOperationException("trusted ancestor fallback process/thread restoration readback differs from the exact retained owner/DACL");}}catch(Exception exception){if(failure==null)failure=exception;}finally{Marshal.FreeHGlobal(value);}}try{if(processId>0&&protectedDacl!=null&&futureThreadOriginalSecurity!=null)RestoreProtectedFutureThreads(processId,protectedDacl,futureThreadOriginalSecurity,retainedThreadIds);}catch(Exception exception){if(failure==null)failure=exception;}finally{for(var index=handles.Count-1;index>=0;index--)CloseHandle(handles[index]);handles.Clear();descriptors.Clear();retainedThreadIds.Clear();}if(failure!=null)throw failure;}
    }
    private static bool SameSecurity(byte[] expected,byte[] observed){if(expected==null||observed==null||expected.Length!=observed.Length)return false;for(var index=0;index<expected.Length;index++)if(expected[index]!=observed[index])return false;return true;}
    private static byte[] ReadAncestorSecurity(IntPtr handle){uint required;GetKernelObjectSecurity(handle,5,IntPtr.Zero,0,out required);if(required==0)throw new InvalidOperationException("trusted ancestor fallback descriptor size could not be read: "+Marshal.GetLastWin32Error());var value=Marshal.AllocHGlobal((int)required);try{if(!GetKernelObjectSecurity(handle,5,value,required,out required))throw new InvalidOperationException("trusted ancestor fallback descriptor could not be read: "+Marshal.GetLastWin32Error());var bytes=new byte[required];Marshal.Copy(value,bytes,0,(int)required);return bytes;}finally{Marshal.FreeHGlobal(value);}}
    private static byte[] ReadTokenDefaultDacl(IntPtr token){uint required;GetTokenInformation(token,6,IntPtr.Zero,0,out required);if(required<(uint)Marshal.SizeOf(typeof(TOKEN_DEFAULT_DACL)))throw new InvalidOperationException("trusted completion parent token default DACL size could not be read: "+Marshal.GetLastWin32Error());var buffer=Marshal.AllocHGlobal((int)required);try{if(!GetTokenInformation(token,6,buffer,required,out required))throw new InvalidOperationException("trusted completion parent token default DACL could not be read: "+Marshal.GetLastWin32Error());var record=(TOKEN_DEFAULT_DACL)Marshal.PtrToStructure(buffer,typeof(TOKEN_DEFAULT_DACL));if(record.DefaultDacl==IntPtr.Zero)throw new InvalidOperationException("trusted completion parent token has a null default DACL");var length=unchecked((ushort)Marshal.ReadInt16(record.DefaultDacl,2));var bytes=new byte[length];Marshal.Copy(record.DefaultDacl,bytes,0,length);return bytes;}finally{Marshal.FreeHGlobal(buffer);}}
    private static string RenderSid(IntPtr sid){IntPtr text;if(!ConvertSidToStringSid(sid,out text))throw new InvalidOperationException("trusted authority SID could not be rendered: "+Marshal.GetLastWin32Error());try{return Marshal.PtrToStringUni(text);}finally{LocalFree(text);}}
    private static string TokenOwnerSid(IntPtr token){uint required;GetTokenInformation(token,4,IntPtr.Zero,0,out required);var buffer=Marshal.AllocHGlobal((int)required);try{if(!GetTokenInformation(token,4,buffer,required,out required))throw new InvalidOperationException("trusted authority token owner could not be read: "+Marshal.GetLastWin32Error());return RenderSid(((TOKEN_OWNER_RECORD)Marshal.PtrToStructure(buffer,typeof(TOKEN_OWNER_RECORD))).Owner);}finally{Marshal.FreeHGlobal(buffer);}}
    private static string GuardSid(IntPtr token){uint required;GetTokenInformation(token,2,IntPtr.Zero,0,out required);var buffer=Marshal.AllocHGlobal((int)required);try{if(!GetTokenInformation(token,2,buffer,required,out required))throw new InvalidOperationException("trusted authority token groups could not be read: "+Marshal.GetLastWin32Error());var count=Marshal.ReadInt32(buffer);var offset=IntPtr.Size==8?8:4;var size=Marshal.SizeOf(typeof(SID_AND_ATTRIBUTES));var groups=new System.Collections.Generic.Dictionary<string,uint>(StringComparer.Ordinal);for(var index=0;index<count;index++){var value=(SID_AND_ATTRIBUTES)Marshal.PtrToStructure(IntPtr.Add(buffer,offset+index*size),typeof(SID_AND_ATTRIBUTES));groups[RenderSid(value.Sid)]=value.Attributes;}var priority=new string[]{"S-1-5-113","S-1-2-0","S-1-5-15","S-1-5-4","S-1-5-11","S-1-5-32-545","S-1-1-0"};foreach(var sid in priority){uint attributes;if(groups.TryGetValue(sid,out attributes)&&(attributes&4)!=0&&(attributes&16)==0)return sid;}var candidates=new System.Collections.Generic.List<string>();foreach(var pair in groups)if((pair.Value&4)!=0&&(pair.Value&16)==0)candidates.Add(pair.Key);candidates.Sort(StringComparer.Ordinal);if(candidates.Count==0)throw new InvalidOperationException("trusted authority token has no enabled guard group");return candidates[0];}finally{Marshal.FreeHGlobal(buffer);}}
    private static IntPtr BuildProtectionDescriptor(IntPtr token,out byte[] protectedDacl){IntPtr descriptor;uint length;var sddl="O:"+TokenOwnerSid(token)+"D:P(A;;0x1fffff;;;"+GuardSid(token)+")(A;;0x1fffff;;;SY)(D;;RCWDWO;;;OW)";if(!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out descriptor,out length))throw new InvalidOperationException("trusted authority protection descriptor could not be created: "+Marshal.GetLastWin32Error());protectedDacl=DaclBytes(descriptor);return descriptor;}
    private static byte[] DaclBytes(IntPtr descriptor){bool present,defaulted;IntPtr dacl;if(!GetSecurityDescriptorDacl(descriptor,out present,out dacl,out defaulted)||!present||dacl==IntPtr.Zero)throw new InvalidOperationException("trusted authority descriptor has no DACL");var length=unchecked((ushort)Marshal.ReadInt16(dacl,2));var bytes=new byte[length];Marshal.Copy(dacl,bytes,0,length);return bytes;}
    private static byte[] DaclBytes(byte[] descriptor){var value=Marshal.AllocHGlobal(descriptor.Length);try{Marshal.Copy(descriptor,0,value,descriptor.Length);return DaclBytes(value);}finally{Marshal.FreeHGlobal(value);}}
    private static byte[] CaptureDefaultThreadSecurity(){var ready=new ManualResetEventSlim(false);var stop=new ManualResetEventSlim(false);uint id=0;var thread=new Thread(()=>{id=GetCurrentThreadId();ready.Set();stop.Wait();});thread.IsBackground=true;thread.Start();try{if(!ready.Wait(5000)||id==0)throw new InvalidOperationException("trusted completion parent default-thread template did not start");var handle=OpenThread(0x000e0000,false,id);if(handle==IntPtr.Zero)throw new InvalidOperationException("trusted completion parent default-thread template could not be opened: "+Marshal.GetLastWin32Error());try{return ReadAncestorSecurity(handle);}finally{CloseHandle(handle);}}finally{stop.Set();if(!thread.Join(5000))throw new InvalidOperationException("trusted completion parent default-thread template did not stop");ready.Dispose();stop.Dispose();}}
    private static uint[] SnapshotThreadIds(int processId){var values=new System.Collections.Generic.List<uint>();var snapshot=CreateToolhelp32Snapshot(4,0);if(snapshot==new IntPtr(-1))throw new InvalidOperationException("trusted future-thread cleanup snapshot failed: "+Marshal.GetLastWin32Error());try{var entry=new THREADENTRY32();entry.dwSize=(uint)Marshal.SizeOf(typeof(THREADENTRY32));if(Thread32First(snapshot,ref entry)){do{if(entry.th32OwnerProcessID==unchecked((uint)processId))values.Add(entry.th32ThreadID);entry.dwSize=(uint)Marshal.SizeOf(typeof(THREADENTRY32));}while(Thread32Next(snapshot,ref entry));}}finally{CloseHandle(snapshot);}values.Sort();return values.ToArray();}
    private static bool SameIds(uint[] left,uint[] right){if(left.Length!=right.Length)return false;for(var index=0;index<left.Length;index++)if(left[index]!=right[index])return false;return true;}
    private static void RestoreProtectedFutureThreads(int processId,byte[] protectedDacl,byte[] originalSecurity,System.Collections.Generic.HashSet<uint> retainedThreadIds){var restoredThreadIds=new System.Collections.Generic.HashSet<uint>();var restoredThreadHandles=new System.Collections.Generic.List<IntPtr>();try{for(var attempt=0;attempt<16;attempt++){var before=SnapshotThreadIds(processId);var restored=0;foreach(var id in before){if(retainedThreadIds.Contains(id)||restoredThreadIds.Contains(id))continue;var handle=OpenThread(0x000e0000,false,id);if(handle==IntPtr.Zero){var error=Marshal.GetLastWin32Error();if(error==5||error==87)continue;throw new InvalidOperationException("trusted future-thread cleanup could not open thread: tid="+id+" error="+error);}try{var observed=ReadAncestorSecurity(handle);if(SameSecurity(DaclBytes(observed),protectedDacl)){var value=Marshal.AllocHGlobal(originalSecurity.Length);try{Marshal.Copy(originalSecurity,0,value,originalSecurity.Length);if(!SetKernelObjectSecurity(handle,5,value))throw new InvalidOperationException("trusted future-thread cleanup could not restore thread: tid="+id+" error="+Marshal.GetLastWin32Error());var readback=ReadAncestorSecurity(handle);if(!SameSecurity(originalSecurity,readback))throw new InvalidOperationException("trusted future-thread cleanup readback differs from the exact default-thread template: tid="+id);if(!restoredThreadIds.Add(id))throw new InvalidOperationException("trusted future-thread cleanup observed a duplicate restored identity: tid="+id);restoredThreadHandles.Add(handle);handle=IntPtr.Zero;restored++;}finally{Marshal.FreeHGlobal(value);}}}finally{if(handle!=IntPtr.Zero)CloseHandle(handle);}}var after=SnapshotThreadIds(processId);if(restored==0&&SameIds(before,after))return;Thread.Sleep(10);}throw new InvalidOperationException("trusted future-thread cleanup did not reach a stable residue-free thread set");}finally{for(var index=restoredThreadHandles.Count-1;index>=0;index--)CloseHandle(restoredThreadHandles[index]);}}
    private static AncestorRestoreSet SnapshotAncestorSecurity(){var result=new AncestorRestoreSet();var current=Process.GetCurrentProcess().Id;var handle=OpenProcess(0x000e1000,false,current);if(handle==IntPtr.Zero)throw new InvalidOperationException("trusted completion parent could not retain its fallback security descriptor: "+Marshal.GetLastWin32Error());IntPtr token=IntPtr.Zero,snapshot=IntPtr.Zero,protectedDescriptor=IntPtr.Zero;try{if(!OpenProcessToken(handle,0x0088,out token))throw new InvalidOperationException("trusted completion parent token could not retain its fallback default DACL: "+Marshal.GetLastWin32Error());byte[] protectedDacl;protectedDescriptor=BuildProtectionDescriptor(token,out protectedDacl);result.ConfigureFutureThreads(current,protectedDacl,CaptureDefaultThreadSecurity());result.AddToken(token,ReadTokenDefaultDacl(token));token=IntPtr.Zero;snapshot=CreateToolhelp32Snapshot(4,0);if(snapshot==new IntPtr(-1))throw new InvalidOperationException("trusted completion parent thread snapshot failed: "+Marshal.GetLastWin32Error());var entry=new THREADENTRY32();entry.dwSize=(uint)Marshal.SizeOf(typeof(THREADENTRY32));var count=0;if(Thread32First(snapshot,ref entry)){do{if(entry.th32OwnerProcessID==unchecked((uint)current)){var thread=OpenThread(0x000e0000,false,entry.th32ThreadID);if(thread==IntPtr.Zero){if(Marshal.GetLastWin32Error()==5){entry.dwSize=(uint)Marshal.SizeOf(typeof(THREADENTRY32));continue;}throw new InvalidOperationException("trusted completion parent thread could not retain its fallback descriptor: tid="+entry.th32ThreadID+" error="+Marshal.GetLastWin32Error());}try{result.AddThread(thread,ReadAncestorSecurity(thread),entry.th32ThreadID);thread=IntPtr.Zero;count++;}finally{if(thread!=IntPtr.Zero)CloseHandle(thread);}}entry.dwSize=(uint)Marshal.SizeOf(typeof(THREADENTRY32));}while(Thread32Next(snapshot,ref entry));}if(count==0)throw new InvalidOperationException("trusted completion parent had no snapshot threads");result.Add(handle,ReadAncestorSecurity(handle));handle=IntPtr.Zero;return result;}catch{try{result.Restore();}catch{}throw;}finally{if(protectedDescriptor!=IntPtr.Zero)LocalFree(protectedDescriptor);if(snapshot!=IntPtr.Zero&&snapshot!=new IntPtr(-1))CloseHandle(snapshot);if(token!=IntPtr.Zero)CloseHandle(token);if(handle!=IntPtr.Zero)CloseHandle(handle);}}
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
    private static readonly string SupervisorSource = @"param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$ChildWorkingDirectory,
    [Parameter(Mandatory = $true)][string]$ReadyPath,
    [Parameter(Mandatory = $true)][string]$GoPath,
    [Parameter(Mandatory = $true)][string]$ProtectedPath,
    [Parameter(Mandatory = $true)][string]$FutureThreadPath,
    [Parameter(Mandatory = $true)][string]$AncestorTemplatePath,
    [Parameter(Mandatory = $true)][string]$ArgumentsBase64,
    [Parameter(Mandatory = $true)][string]$CompletionHandle,
    [Parameter(Mandatory = $true)][int]$OutputLimitBytes
)
$ErrorActionPreference = 'Stop'
function Publish-Control([string]$Path,[string]$Record) {
    $pending = $Path + '.pending'
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($Record)
    $stream = [IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [IO.File]::Move($pending,$Path,$false)
}
function Wait-Control([string]$Path,[string]$Expected) {
    while (-not [IO.File]::Exists($Path)) { [Threading.Thread]::Sleep(10) }
    if ([IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true)) -cne $Expected) { throw 'owned validation supervisor control record is malformed' }
}
function Initialize-LeafWritableRoot([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not[IO.Directory]::Exists($full)){[void][IO.Directory]::CreateDirectory($full)}
    if(([IO.File]::GetAttributes($full)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'leaf writable root is a reparse point'}
}
function Resolve-ExactApplication([string]$Name) {
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($command in @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)){$path=[IO.Path]::GetFullPath([string]$command.Source);if(-not[IO.File]::Exists($path)){throw ""resolved $Name executable does not exist""};[void]$paths.Add($path)}
    if($paths.Count-eq0){throw ""required $Name executable is unavailable for isolated Linux validation""}
    [string[]]$ordered=@($paths);[Array]::Sort($ordered,[StringComparer]::Ordinal);return $ordered[0]
}
function Start-Pump([Diagnostics.ProcessStartInfo]$Start) {
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $Start
    if (-not $process.Start()) { throw 'owned validation inner process did not start' }
    $stdoutTarget = [Console]::OpenStandardOutput(); $stderrTarget = [Console]::OpenStandardError()
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutTarget)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrTarget)
    return [pscustomobject]@{process=$process;stdout_target=$stdoutTarget;stderr_target=$stderrTarget;stdout_task=$stdoutTask;stderr_task=$stderrTask}
}
function Complete-Pump([object]$Pump) {
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($Pump.stdout_task,$Pump.stderr_task),15000)) { throw 'owned validation inner streams did not drain completely after containment termination' }
    $Pump.stdout_target.Flush(); $Pump.stderr_target.Flush()
}
$completion = [IO.Pipes.AnonymousPipeClientStream]::new([IO.Pipes.PipeDirection]::Out,$CompletionHandle)
function Publish-Completion([string]$Record) {
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($Record)
    $completion.Write($bytes,0,$bytes.Length); $completion.Flush()
}
$innerJob = [IntPtr]::Zero
$pump = $null
$ancestorProtection = $null
try {
    $windowsHost = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
    if ($windowsHost) {
        Add-Type -TypeDefinition @""
using System;
using System.Runtime.InteropServices;
public static class W017SupervisorProtection {
    private const uint TokenQuery=0x0008,TokenAdjustDefault=0x0080,TokenGroups=2,TokenOwner=4,TokenDefaultDacl=6,OwnerSecurityInformation=0x00000001,DaclSecurityInformation=0x00000004,HandleFlagInherit=1;
    [StructLayout(LayoutKind.Sequential)] private struct TokenOwnerRecord { public IntPtr sid; }
    [StructLayout(LayoutKind.Sequential)] private struct SidAndAttributes { public IntPtr sid; public uint attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct TokenDefaultDaclRecord { public IntPtr dacl; }
    [StructLayout(LayoutKind.Sequential)] private struct ThreadEntry32 { public uint size,usage,threadId,ownerProcessId; public int basePriority,deltaPriority; public uint flags; }
    [DllImport(""kernel32.dll"")] private static extern IntPtr GetCurrentProcess();
    [DllImport(""kernel32.dll"")] private static extern int GetCurrentProcessId();
    [DllImport(""kernel32.dll"")] private static extern uint GetCurrentThreadId();
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool GetTokenInformation(IntPtr token,uint information,IntPtr buffer,uint length,out uint required);
    [DllImport(""advapi32.dll"",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text,uint revision,out IntPtr descriptor,out uint length);
    [DllImport(""advapi32.dll"",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool ConvertSidToStringSid(IntPtr sid,out IntPtr text);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool GetSecurityDescriptorDacl(IntPtr descriptor,out bool present,out IntPtr dacl,out bool defaulted);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool GetSecurityDescriptorOwner(IntPtr descriptor,out IntPtr owner,out bool defaulted);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool EqualSid(IntPtr left,IntPtr right);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool SetTokenInformation(IntPtr token,uint information,IntPtr buffer,uint length);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool SetKernelObjectSecurity(IntPtr handle,uint information,IntPtr descriptor);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool GetKernelObjectSecurity(IntPtr handle,uint information,IntPtr descriptor,uint length,out uint required);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern IntPtr OpenProcess(uint access,bool inherit,int processId);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern IntPtr OpenThread(uint access,bool inherit,uint threadId);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags,uint processId);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool Thread32First(IntPtr snapshot,ref ThreadEntry32 entry);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool Thread32Next(IntPtr snapshot,ref ThreadEntry32 entry);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport(""kernel32.dll"")] private static extern IntPtr LocalFree(IntPtr value);
    private static string RenderSid(IntPtr sid){IntPtr text;if(!ConvertSidToStringSid(sid,out text))throw new InvalidOperationException(""trusted authority SID could not be rendered: ""+Marshal.GetLastWin32Error());try{return Marshal.PtrToStringUni(text);}finally{LocalFree(text);}}
    private static string TokenOwnerSid(IntPtr token){uint required;GetTokenInformation(token,TokenOwner,IntPtr.Zero,0,out required);var buffer=Marshal.AllocHGlobal((int)required);try{if(!GetTokenInformation(token,TokenOwner,buffer,required,out required))throw new InvalidOperationException(""trusted authority token owner could not be read: ""+Marshal.GetLastWin32Error());return RenderSid(((TokenOwnerRecord)Marshal.PtrToStructure(buffer,typeof(TokenOwnerRecord))).sid);}finally{Marshal.FreeHGlobal(buffer);}}
    private static bool SecurityDescriptorOwnerMatchesToken(IntPtr descriptor,IntPtr token){uint required;GetTokenInformation(token,TokenOwner,IntPtr.Zero,0,out required);if(required<(uint)Marshal.SizeOf(typeof(TokenOwnerRecord)))throw new InvalidOperationException(""trusted authority token owner size could not be read: ""+Marshal.GetLastWin32Error());var buffer=Marshal.AllocHGlobal((int)required);try{if(!GetTokenInformation(token,TokenOwner,buffer,required,out required))throw new InvalidOperationException(""trusted authority token owner could not be read for comparison: ""+Marshal.GetLastWin32Error());var tokenOwner=((TokenOwnerRecord)Marshal.PtrToStructure(buffer,typeof(TokenOwnerRecord))).sid;IntPtr descriptorOwner;bool defaulted;if(!GetSecurityDescriptorOwner(descriptor,out descriptorOwner,out defaulted)||descriptorOwner==IntPtr.Zero)throw new InvalidOperationException(""supervisor process owner readback could not be obtained: ""+Marshal.GetLastWin32Error());return EqualSid(tokenOwner,descriptorOwner);}finally{Marshal.FreeHGlobal(buffer);}}
    private static string GuardSid(IntPtr token){uint required;GetTokenInformation(token,TokenGroups,IntPtr.Zero,0,out required);var buffer=Marshal.AllocHGlobal((int)required);try{if(!GetTokenInformation(token,TokenGroups,buffer,required,out required))throw new InvalidOperationException(""trusted authority token groups could not be read: ""+Marshal.GetLastWin32Error());var count=Marshal.ReadInt32(buffer);var offset=IntPtr.Size==8?8:4;var size=Marshal.SizeOf(typeof(SidAndAttributes));var groups=new System.Collections.Generic.Dictionary<string,uint>(StringComparer.Ordinal);for(var index=0;index<count;index++){var value=(SidAndAttributes)Marshal.PtrToStructure(IntPtr.Add(buffer,offset+index*size),typeof(SidAndAttributes));groups[RenderSid(value.sid)]=value.attributes;}var priority=new string[]{""S-1-5-113"",""S-1-2-0"",""S-1-5-15"",""S-1-5-4"",""S-1-5-11"",""S-1-5-32-545"",""S-1-1-0""};foreach(var sid in priority){uint attributes;if(groups.TryGetValue(sid,out attributes)&&(attributes&4)!=0&&(attributes&16)==0)return sid;}var candidates=new System.Collections.Generic.List<string>();foreach(var pair in groups)if((pair.Value&4)!=0&&(pair.Value&16)==0)candidates.Add(pair.Key);candidates.Sort(StringComparer.Ordinal);if(candidates.Count==0)throw new InvalidOperationException(""trusted authority token has no enabled guard group"");return candidates[0];}finally{Marshal.FreeHGlobal(buffer);}}
    private static IntPtr BuildProtectionDescriptor(IntPtr token,out byte[] protectedDacl,out string guardSid){guardSid=GuardSid(token);var sddl=""O:""+TokenOwnerSid(token)+""D:P(A;;0x1fffff;;;""+guardSid+"")(A;;0x1fffff;;;SY)(D;;RCWDWO;;;OW)"";IntPtr descriptor;uint length;if(!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out descriptor,out length))throw new InvalidOperationException(""trusted authority protection descriptor could not be created: ""+Marshal.GetLastWin32Error());IntPtr dacl;protectedDacl=DaclBytes(descriptor,out dacl);return descriptor;}
    private static byte[] ReadTokenDefaultDacl(IntPtr token){uint required;GetTokenInformation(token,TokenDefaultDacl,IntPtr.Zero,0,out required);if(required<(uint)Marshal.SizeOf(typeof(TokenDefaultDaclRecord)))throw new InvalidOperationException(""trusted authority token default DACL size could not be read: ""+Marshal.GetLastWin32Error());var buffer=Marshal.AllocHGlobal((int)required);try{if(!GetTokenInformation(token,TokenDefaultDacl,buffer,required,out required))throw new InvalidOperationException(""trusted authority token default DACL could not be read: ""+Marshal.GetLastWin32Error());var record=(TokenDefaultDaclRecord)Marshal.PtrToStructure(buffer,typeof(TokenDefaultDaclRecord));if(record.dacl==IntPtr.Zero)throw new InvalidOperationException(""trusted authority token has a null default DACL"");var length=unchecked((ushort)Marshal.ReadInt16(record.dacl,2));if(length<8)throw new InvalidOperationException(""trusted authority token default DACL is malformed"");var bytes=new byte[length];Marshal.Copy(record.dacl,bytes,0,length);return bytes;}finally{Marshal.FreeHGlobal(buffer);}}
    private static void SetTokenDefaultDacl(IntPtr token,IntPtr dacl,byte[] expected){var record=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(TokenDefaultDaclRecord)));try{Marshal.StructureToPtr(new TokenDefaultDaclRecord{dacl=dacl},record,false);if(!SetTokenInformation(token,TokenDefaultDacl,record,(uint)Marshal.SizeOf(typeof(TokenDefaultDaclRecord))))throw new InvalidOperationException(""trusted authority token default DACL could not be installed: ""+Marshal.GetLastWin32Error());var observed=ReadTokenDefaultDacl(token);if(!SameSecurity(expected,observed))throw new InvalidOperationException(""trusted authority token default DACL readback differs from the exact installed ACL"");}finally{Marshal.FreeHGlobal(record);}}
    private static byte[] ReadSecurity(IntPtr handle){uint required;GetKernelObjectSecurity(handle,OwnerSecurityInformation|DaclSecurityInformation,IntPtr.Zero,0,out required);if(required==0)throw new InvalidOperationException(""ancestor owner/DACL size could not be read: ""+Marshal.GetLastWin32Error());var value=Marshal.AllocHGlobal((int)required);try{if(!GetKernelObjectSecurity(handle,OwnerSecurityInformation|DaclSecurityInformation,value,required,out required))throw new InvalidOperationException(""ancestor owner/DACL could not be read: ""+Marshal.GetLastWin32Error());var bytes=new byte[required];Marshal.Copy(value,bytes,0,(int)required);return bytes;}finally{Marshal.FreeHGlobal(value);}}
    private static bool SameSecurity(byte[] expected,byte[] observed){if(expected==null||observed==null||expected.Length!=observed.Length)return false;for(var index=0;index<expected.Length;index++)if(expected[index]!=observed[index])return false;return true;}
    private static byte[] DaclBytes(IntPtr descriptor,out IntPtr dacl){bool present,defaulted;if(!GetSecurityDescriptorDacl(descriptor,out present,out dacl,out defaulted)||!present||dacl==IntPtr.Zero)throw new InvalidOperationException(""trusted authority protection descriptor has no DACL"");var length=unchecked((ushort)Marshal.ReadInt16(dacl,2));var bytes=new byte[length];Marshal.Copy(dacl,bytes,0,length);return bytes;}
    private static byte[] DaclBytes(byte[] descriptor){var value=Marshal.AllocHGlobal(descriptor.Length);try{Marshal.Copy(descriptor,0,value,descriptor.Length);IntPtr dacl;return DaclBytes(value,out dacl);}finally{Marshal.FreeHGlobal(value);}}
    private static void ProtectThreads(int processId,IntPtr descriptor,AncestorGuard guard){var snapshot=CreateToolhelp32Snapshot(4,0);if(snapshot==new IntPtr(-1))throw new InvalidOperationException(""trusted authority thread snapshot failed: ""+Marshal.GetLastWin32Error());var count=0;try{var entry=new ThreadEntry32();entry.size=(uint)Marshal.SizeOf(typeof(ThreadEntry32));if(Thread32First(snapshot,ref entry)){do{if(entry.ownerProcessId==unchecked((uint)processId)){count++;var handle=OpenThread(0x000e0000,false,entry.threadId);if(handle==IntPtr.Zero){if(Marshal.GetLastWin32Error()==5){entry.size=(uint)Marshal.SizeOf(typeof(ThreadEntry32));continue;}throw new InvalidOperationException(""trusted authority thread could not be opened for protection: tid=""+entry.threadId+"" error=""+Marshal.GetLastWin32Error());}try{var original=ReadSecurity(handle);if(!SetKernelObjectSecurity(handle,OwnerSecurityInformation|DaclSecurityInformation,descriptor))throw new InvalidOperationException(""trusted authority thread protection could not be installed: tid=""+entry.threadId+"" error=""+Marshal.GetLastWin32Error());if(guard!=null){guard.AddThread(handle,original,entry.threadId);handle=IntPtr.Zero;}}finally{if(handle!=IntPtr.Zero)CloseHandle(handle);}}entry.size=(uint)Marshal.SizeOf(typeof(ThreadEntry32));}while(Thread32Next(snapshot,ref entry));}}finally{CloseHandle(snapshot);}if(count==0)throw new InvalidOperationException(""trusted authority process had no threads at protection readback: pid=""+processId);}
    private static uint[] SnapshotThreadIds(int processId){var values=new System.Collections.Generic.List<uint>();var snapshot=CreateToolhelp32Snapshot(4,0);if(snapshot==new IntPtr(-1))throw new InvalidOperationException(""trusted future-thread cleanup snapshot failed: ""+Marshal.GetLastWin32Error());try{var entry=new ThreadEntry32();entry.size=(uint)Marshal.SizeOf(typeof(ThreadEntry32));if(Thread32First(snapshot,ref entry)){do{if(entry.ownerProcessId==unchecked((uint)processId))values.Add(entry.threadId);entry.size=(uint)Marshal.SizeOf(typeof(ThreadEntry32));}while(Thread32Next(snapshot,ref entry));}}finally{CloseHandle(snapshot);}values.Sort();return values.ToArray();}
    private static bool SameIds(uint[] left,uint[] right){if(left.Length!=right.Length)return false;for(var index=0;index<left.Length;index++)if(left[index]!=right[index])return false;return true;}
    private static void RestoreProtectedFutureThreads(int processId,byte[] protectedDacl,byte[] originalSecurity,System.Collections.Generic.HashSet<uint> retainedThreadIds){var restoredThreadIds=new System.Collections.Generic.HashSet<uint>();var restoredThreadHandles=new System.Collections.Generic.List<IntPtr>();try{for(var attempt=0;attempt<16;attempt++){var before=SnapshotThreadIds(processId);var restored=0;foreach(var id in before){if(retainedThreadIds.Contains(id)||restoredThreadIds.Contains(id))continue;var handle=OpenThread(0x000e0000,false,id);if(handle==IntPtr.Zero){var error=Marshal.GetLastWin32Error();if(error==5||error==87)continue;throw new InvalidOperationException(""trusted future-thread cleanup could not open thread: tid=""+id+"" error=""+error);}try{var observed=ReadSecurity(handle);if(SameSecurity(DaclBytes(observed),protectedDacl)){var value=Marshal.AllocHGlobal(originalSecurity.Length);try{Marshal.Copy(originalSecurity,0,value,originalSecurity.Length);if(!SetKernelObjectSecurity(handle,OwnerSecurityInformation|DaclSecurityInformation,value))throw new InvalidOperationException(""trusted future-thread cleanup could not restore thread: tid=""+id+"" error=""+Marshal.GetLastWin32Error());var readback=ReadSecurity(handle);if(!SameSecurity(originalSecurity,readback))throw new InvalidOperationException(""trusted future-thread cleanup readback differs from the exact default-thread template: tid=""+id);if(!restoredThreadIds.Add(id))throw new InvalidOperationException(""trusted future-thread cleanup observed a duplicate restored identity: tid=""+id);restoredThreadHandles.Add(handle);handle=IntPtr.Zero;restored++;}finally{Marshal.FreeHGlobal(value);}}}finally{if(handle!=IntPtr.Zero)CloseHandle(handle);}}var after=SnapshotThreadIds(processId);if(restored==0&&SameIds(before,after))return;System.Threading.Thread.Sleep(10);}throw new InvalidOperationException(""trusted future-thread cleanup did not reach a stable residue-free thread set"");}finally{for(var index=restoredThreadHandles.Count-1;index>=0;index--)CloseHandle(restoredThreadHandles[index]);}}
    public sealed class AncestorGuard : IDisposable {
        private readonly System.Collections.Generic.List<IntPtr> handles=new System.Collections.Generic.List<IntPtr>();
        private readonly System.Collections.Generic.List<byte[]> descriptors=new System.Collections.Generic.List<byte[]>();
        private readonly System.Collections.Generic.HashSet<uint> retainedThreadIds=new System.Collections.Generic.HashSet<uint>();
        private readonly System.Collections.Generic.List<IntPtr> tokens=new System.Collections.Generic.List<IntPtr>();
        private readonly System.Collections.Generic.List<byte[]> tokenDacls=new System.Collections.Generic.List<byte[]>();
        private int processId;private byte[] protectedDacl;private byte[] futureThreadOriginalSecurity;
        internal void Add(IntPtr handle,byte[] descriptor){handles.Add(handle);descriptors.Add((byte[])descriptor.Clone());}
        internal void AddThread(IntPtr handle,byte[] descriptor,uint id){Add(handle,descriptor);if(id==0||!retainedThreadIds.Add(id))throw new InvalidOperationException(""trusted ancestor retained a duplicate thread identity"");}
        internal void AddToken(IntPtr token,byte[] dacl){tokens.Add(token);tokenDacls.Add((byte[])dacl.Clone());}
        internal void ConfigureFutureThreads(int id,byte[] protectedAcl,byte[] originalSecurity){processId=id;protectedDacl=(byte[])protectedAcl.Clone();futureThreadOriginalSecurity=(byte[])originalSecurity.Clone();}
        public void Dispose(){Exception failure=null;for(var index=tokens.Count-1;index>=0;index--){var acl=Marshal.AllocHGlobal(tokenDacls[index].Length);try{Marshal.Copy(tokenDacls[index],0,acl,tokenDacls[index].Length);SetTokenDefaultDacl(tokens[index],acl,tokenDacls[index]);}catch(Exception exception){if(failure==null)failure=exception;}finally{Marshal.FreeHGlobal(acl);CloseHandle(tokens[index]);}}tokens.Clear();tokenDacls.Clear();for(var index=handles.Count-1;index>=0;index--){var value=Marshal.AllocHGlobal(descriptors[index].Length);try{Marshal.Copy(descriptors[index],0,value,descriptors[index].Length);if(!SetKernelObjectSecurity(handles[index],OwnerSecurityInformation|DaclSecurityInformation,value)){if(failure==null)failure=new InvalidOperationException(""trusted ancestor process/thread owner/DACL restoration failed: ""+Marshal.GetLastWin32Error());}else{var observed=ReadSecurity(handles[index]);if(!SameSecurity(descriptors[index],observed)&&failure==null)failure=new InvalidOperationException(""trusted ancestor process/thread owner/DACL restoration readback differs from the exact retained descriptor"");}}catch(Exception exception){if(failure==null)failure=exception;}finally{Marshal.FreeHGlobal(value);}}try{if(processId>0&&protectedDacl!=null&&futureThreadOriginalSecurity!=null)RestoreProtectedFutureThreads(processId,protectedDacl,futureThreadOriginalSecurity,retainedThreadIds);}catch(Exception exception){if(failure==null)failure=exception;}finally{for(var index=handles.Count-1;index>=0;index--)CloseHandle(handles[index]);handles.Clear();descriptors.Clear();retainedThreadIds.Clear();}if(failure!=null)throw failure;}
    }
    public static AncestorGuard ProtectAncestors(int[] processIds,byte[] futureThreadOriginalSecurity){if(futureThreadOriginalSecurity==null||futureThreadOriginalSecurity.Length==0)throw new InvalidOperationException(""future-thread original security template is absent"");var guard=new AncestorGuard();var seen=new System.Collections.Generic.HashSet<int>();foreach(var processId in processIds??new int[0]){if(processId<=0||processId==GetCurrentProcessId()||!seen.Add(processId))continue;var handle=OpenProcess(0x000e1000,false,processId);if(handle==IntPtr.Zero)throw new InvalidOperationException(""trusted ancestor process could not be opened for protection: pid=""+processId+"" error=""+Marshal.GetLastWin32Error());IntPtr token=IntPtr.Zero,descriptor=IntPtr.Zero;try{if(!OpenProcessToken(handle,TokenQuery|TokenAdjustDefault,out token))throw new InvalidOperationException(""trusted ancestor token could not be opened for default-thread protection: pid=""+processId+"" error=""+Marshal.GetLastWin32Error());byte[] protectedDaclBytes;string guardSid;descriptor=BuildProtectionDescriptor(token,out protectedDaclBytes,out guardSid);var expectedGuard=Environment.GetEnvironmentVariable(""RUSTY_AFFECTED_VALIDATION_GUARD_SID"");if(!String.Equals(guardSid,expectedGuard,StringComparison.Ordinal))throw new InvalidOperationException(""trusted ancestor guard identity differs from the supervisor identity"");IntPtr protectedDacl;DaclBytes(descriptor,out protectedDacl);var originalTokenDacl=ReadTokenDefaultDacl(token);SetTokenDefaultDacl(token,protectedDacl,protectedDaclBytes);guard.AddToken(token,originalTokenDacl);token=IntPtr.Zero;guard.ConfigureFutureThreads(processId,protectedDaclBytes,futureThreadOriginalSecurity);ProtectThreads(processId,descriptor,guard);var original=ReadSecurity(handle);if(!SetKernelObjectSecurity(handle,OwnerSecurityInformation|DaclSecurityInformation,descriptor))throw new InvalidOperationException(""trusted ancestor process protection could not be installed: pid=""+processId+"" error=""+Marshal.GetLastWin32Error());guard.Add(handle,original);handle=IntPtr.Zero;}catch{try{guard.Dispose();}catch{}throw;}finally{if(descriptor!=IntPtr.Zero)LocalFree(descriptor);if(token!=IntPtr.Zero)CloseHandle(token);if(handle!=IntPtr.Zero)CloseHandle(handle);}}return guard;}
    private static void WriteExactSecurity(IntPtr handle,byte[] descriptor,string context){var value=Marshal.AllocHGlobal(descriptor.Length);try{Marshal.Copy(descriptor,0,value,descriptor.Length);if(!SetKernelObjectSecurity(handle,OwnerSecurityInformation|DaclSecurityInformation,value))throw new InvalidOperationException(context+"": ""+Marshal.GetLastWin32Error());}finally{Marshal.FreeHGlobal(value);}}
    private static void RunRestorationCollisionCase(bool sameTemplate){var preReady=new System.Threading.ManualResetEventSlim(false);var lateReady=new System.Threading.ManualResetEventSlim(false);var stop=new System.Threading.ManualResetEventSlim(false);uint preId=0,lateId=0;var preThread=new System.Threading.Thread(()=>{preId=GetCurrentThreadId();preReady.Set();stop.Wait();});var lateThread=new System.Threading.Thread(()=>{lateId=GetCurrentThreadId();lateReady.Set();stop.Wait();});preThread.IsBackground=true;lateThread.IsBackground=true;IntPtr preHandle=IntPtr.Zero,lateHandle=IntPtr.Zero,token=IntPtr.Zero,protectedDescriptor=IntPtr.Zero;byte[] preOriginal=null,lateOriginal=null;try{preThread.Start();lateThread.Start();if(!preReady.Wait(5000)||!lateReady.Wait(5000)||preId==0||lateId==0||preId==lateId)throw new InvalidOperationException(""future-thread collision self-test identities are invalid"");preHandle=OpenThread(0x000e0000,false,preId);lateHandle=OpenThread(0x000e0000,false,lateId);if(preHandle==IntPtr.Zero||lateHandle==IntPtr.Zero)throw new InvalidOperationException(""future-thread collision self-test could not retain its threads: ""+Marshal.GetLastWin32Error());preOriginal=ReadSecurity(preHandle);lateOriginal=ReadSecurity(lateHandle);if(!OpenProcessToken(GetCurrentProcess(),TokenQuery,out token))throw new InvalidOperationException(""future-thread collision self-test token could not be opened: ""+Marshal.GetLastWin32Error());byte[] protectedDacl;string guardSid;protectedDescriptor=BuildProtectionDescriptor(token,out protectedDacl,out guardSid);if(!SetKernelObjectSecurity(preHandle,OwnerSecurityInformation|DaclSecurityInformation,protectedDescriptor)||!SetKernelObjectSecurity(lateHandle,OwnerSecurityInformation|DaclSecurityInformation,protectedDescriptor))throw new InvalidOperationException(""future-thread collision self-test protection failed: ""+Marshal.GetLastWin32Error());var protectedSecurity=ReadSecurity(preHandle);var template=sameTemplate?protectedSecurity:lateOriginal;RestoreProtectedFutureThreads(GetCurrentProcessId(),protectedDacl,template,new System.Collections.Generic.HashSet<uint>{preId});if(!SameSecurity(protectedSecurity,ReadSecurity(preHandle)))throw new InvalidOperationException(""future-thread collision self-test changed an excluded pre-existing descriptor"");if(!SameSecurity(template,ReadSecurity(lateHandle)))throw new InvalidOperationException(""future-thread collision self-test did not restore the late-thread template"");}finally{if(preHandle!=IntPtr.Zero&&preOriginal!=null)try{WriteExactSecurity(preHandle,preOriginal,""future-thread collision self-test pre-existing cleanup failed"");}catch{}if(lateHandle!=IntPtr.Zero&&lateOriginal!=null)try{WriteExactSecurity(lateHandle,lateOriginal,""future-thread collision self-test late cleanup failed"");}catch{}stop.Set();preThread.Join(5000);lateThread.Join(5000);if(protectedDescriptor!=IntPtr.Zero)LocalFree(protectedDescriptor);if(token!=IntPtr.Zero)CloseHandle(token);if(preHandle!=IntPtr.Zero)CloseHandle(preHandle);if(lateHandle!=IntPtr.Zero)CloseHandle(lateHandle);preReady.Dispose();lateReady.Dispose();stop.Dispose();}}
    public static void RunRestorationCollisionSelfTests(){RunRestorationCollisionCase(false);RunRestorationCollisionCase(true);}
    public static void Protect(IntPtr completionHandle){
        if(!SetHandleInformation(completionHandle,HandleFlagInherit,0))throw new InvalidOperationException(""completion pipe inheritance could not be removed: ""+Marshal.GetLastWin32Error());
        IntPtr token=IntPtr.Zero,descriptor=IntPtr.Zero;
        try{
            if(!OpenProcessToken(GetCurrentProcess(),TokenQuery|TokenAdjustDefault,out token))throw new InvalidOperationException(""supervisor token could not be opened: ""+Marshal.GetLastWin32Error());
            byte[] protectedDacl;string guardSid;descriptor=BuildProtectionDescriptor(token,out protectedDacl,out guardSid);Environment.SetEnvironmentVariable(""RUSTY_AFFECTED_VALIDATION_GUARD_SID"",guardSid);
            ProtectThreads(GetCurrentProcessId(),descriptor,null);
            if(!SetKernelObjectSecurity(GetCurrentProcess(),OwnerSecurityInformation|DaclSecurityInformation,descriptor))throw new InvalidOperationException(""supervisor process protection could not be installed: ""+Marshal.GetLastWin32Error());
            uint observedLength;GetKernelObjectSecurity(GetCurrentProcess(),OwnerSecurityInformation|DaclSecurityInformation,IntPtr.Zero,0,out observedLength);var observed=Marshal.AllocHGlobal((int)observedLength);
            try{if(!GetKernelObjectSecurity(GetCurrentProcess(),OwnerSecurityInformation|DaclSecurityInformation,observed,observedLength,out observedLength))throw new InvalidOperationException(""supervisor process protection could not be read back: ""+Marshal.GetLastWin32Error());IntPtr observedDacl;var observedDaclBytes=DaclBytes(observed,out observedDacl);if(!SameSecurity(protectedDacl,observedDaclBytes))throw new InvalidOperationException(""supervisor process DACL readback differs from the exact protected ACL"");if(!SecurityDescriptorOwnerMatchesToken(observed,token))throw new InvalidOperationException(""supervisor process owner readback differs from the exact protected owner"");}finally{Marshal.FreeHGlobal(observed);}
        }finally{if(descriptor!=IntPtr.Zero)LocalFree(descriptor);if(token!=IntPtr.Zero)CloseHandle(token);}
    }
    public static void ProtectFutureThreads(){IntPtr token=IntPtr.Zero,descriptor=IntPtr.Zero;try{if(!OpenProcessToken(GetCurrentProcess(),TokenQuery|TokenAdjustDefault,out token))throw new InvalidOperationException(""future-thread token could not be opened: ""+Marshal.GetLastWin32Error());byte[] bytes;string guardSid;descriptor=BuildProtectionDescriptor(token,out bytes,out guardSid);if(!String.Equals(guardSid,Environment.GetEnvironmentVariable(""RUSTY_AFFECTED_VALIDATION_GUARD_SID""),StringComparison.Ordinal))throw new InvalidOperationException(""future-thread guard identity differs from the protected supervisor identity"");ProtectThreads(GetCurrentProcessId(),descriptor,null);IntPtr protectedDacl;DaclBytes(descriptor,out protectedDacl);SetTokenDefaultDacl(token,protectedDacl,bytes);}finally{if(token!=IntPtr.Zero)CloseHandle(token);if(descriptor!=IntPtr.Zero)LocalFree(descriptor);}}
}
""@
        $trustedAncestors=[Collections.Generic.List[int]]::new();$seenAncestors=[Collections.Generic.HashSet[int]]::new()
        $cursor=[int]$PID
        while($cursor-gt0-and$seenAncestors.Add($cursor)-and$trustedAncestors.Count-lt2){$trustedAncestors.Add($cursor);$record=Get-CimInstance Win32_Process -Filter ""ProcessId=$cursor"" -ErrorAction Stop;if($null-eq$record){break};$cursor=[int]$record.ParentProcessId}
        if($trustedAncestors.Count-ne2){throw 'exact two-process completion authority chain could not be resolved'}
        if ([Environment]::GetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_RESTORATION_COLLISION_SELFTEST','Process') -ceq '1') { [W017SupervisorProtection]::RunRestorationCollisionSelfTests() }
        [W017SupervisorProtection]::Protect($completion.SafePipeHandle.DangerousGetHandle())
        $env:RUSTY_AFFECTED_VALIDATION_TRUSTED_ANCESTORS=($trustedAncestors -join ',')
        $leafTemp=Join-Path ([IO.Path]::GetDirectoryName($ReadyPath)) 'l';Initialize-LeafWritableRoot $leafTemp;$env:TEMP=$leafTemp;$env:TMP=$leafTemp
        $phaseRoot=[Environment]::GetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_PHASE_ROOT','Process');if(-not[string]::IsNullOrWhiteSpace($phaseRoot)){Initialize-LeafWritableRoot $phaseRoot}
    } else {
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class W017UnixProcessGroup { [DllImport(""libc"", SetLastError=true)] public static extern int setpgid(int pid, int pgid); [DllImport(""libc"", SetLastError=true)] public static extern int fcntl(int fd, int command, int value); [DllImport(""libc"")] public static extern uint geteuid(); [DllImport(""libc"")] public static extern uint getegid(); }'
        if ([W017UnixProcessGroup]::fcntl([int]$completion.SafePipeHandle.DangerousGetHandle(),2,1) -ne 0) { throw ""unable to make the completion pipe close-on-exec: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"" }
        if ([W017UnixProcessGroup]::setpgid(0,0) -ne 0) { throw ""unable to establish owned supervisor process group: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"" }
    }
    $decoded=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgumentsBase64))
    [string[]]$childArguments=if($decoded.Length-eq 0){@()}else{@($decoded.Split([char]0))}
    if($childArguments.Count-lt 4-or$childArguments[0]-cne '-NoProfile'-or$childArguments[1]-cne '-NonInteractive'-or$childArguments[2]-cne '-File'){throw 'owned validation leaf arguments are malformed'}
    Publish-Control $ReadyPath (""ready:{0}`n"" -f $PID)
    Wait-Control $GoPath ""go`n""
    if ($windowsHost) {
        $futureThreadOriginalSecurity=[IO.File]::ReadAllBytes($AncestorTemplatePath)
        $ancestorProtection=[W017SupervisorProtection]::ProtectAncestors($trustedAncestors.ToArray(),$futureThreadOriginalSecurity)
        Publish-Control $ProtectedPath ""protected`n""
        while(-not[IO.File]::Exists($FutureThreadPath)){[Threading.Thread]::Sleep(10)}
        $futureThreadRecord=[IO.File]::ReadAllText($FutureThreadPath,[Text.UTF8Encoding]::new($false,$true))
        if($futureThreadRecord-cnotmatch '^thread:([1-9][0-9]*)\n$'){throw 'trusted completion parent future-thread control record is malformed'}
        $env:RUSTY_AFFECTED_VALIDATION_PARENT_FUTURE_THREAD_ID=$Matches[1]
        Add-Type -TypeDefinition @""
using System;
using System.IO;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public static class W017SupervisorInnerJob {
    private const uint KillOnClose = 0x00002000;
    private const int Extended = 9;
    private const int Accounting = 1;
    [StructLayout(LayoutKind.Sequential)] private struct Io { public ulong a,b,c,d,e,f; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimit { public long a,b; public uint flags; public UIntPtr c,d; public uint e; public IntPtr f; public uint g,h; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimit { public BasicLimit basic; public Io io; public UIntPtr a,b,c,d; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicAccounting { public long a,b,c,d; public uint e,f,active,h; }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct StartupInfo { public int cb; public string reserved; public string desktop; public string title; public int x,y,xSize,ySize,xChars,yChars,fill,flags; public short show; public short reserved2; public IntPtr reservedPtr; public IntPtr stdin,stdout,stderr; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr process,thread; public int processId,threadId; }
    [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint low; public int high; }
    [StructLayout(LayoutKind.Sequential)] private struct LuidAttributes { public Luid luid; public uint attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct SidAndAttributes { public IntPtr sid; public uint attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct ThreadEntry32 { public uint size,usage,threadId,ownerProcessId; public int basePriority,deltaPriority; public uint flags; }
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern IntPtr CreateJobObject(IntPtr attributes,string name);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool SetInformationJobObject(IntPtr job,int info,IntPtr value,uint length);
    [DllImport(""kernel32.dll"",SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport(""kernel32.dll"",SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job,uint code);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool QueryInformationJobObject(IntPtr job,int info,IntPtr value,uint length,IntPtr returned);
    [DllImport(""kernel32.dll"",SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref SecurityAttributes attributes,uint size);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
    [DllImport(""kernel32.dll"",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CreateProcess(string application,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInformation information);
    [DllImport(""kernel32.dll"")] private static extern IntPtr GetCurrentProcess();
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool CreateRestrictedToken(IntPtr existing,uint flags,uint disableCount,IntPtr disableSids,uint deletePrivilegeCount,IntPtr deletePrivileges,uint restrictedCount,IntPtr restrictedSids,out IntPtr token);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool GetTokenInformation(IntPtr token,uint information,IntPtr buffer,uint length,out uint required);
    [DllImport(""advapi32.dll"",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool LookupPrivilegeValue(string system,string name,out Luid value);
    [DllImport(""advapi32.dll"",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool ConvertStringSidToSid(string text,out IntPtr sid);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool EqualSid(IntPtr left,IntPtr right);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool DuplicateTokenEx(IntPtr existing,uint access,IntPtr attributes,int impersonationLevel,int tokenType,out IntPtr token);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool ImpersonateLoggedOnUser(IntPtr token);
    [DllImport(""advapi32.dll"",SetLastError=true)] private static extern bool RevertToSelf();
    [DllImport(""advapi32.dll"",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CreateProcessAsUser(IntPtr token,string application,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInformation information);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern IntPtr OpenProcess(uint access,bool inherit,int processId);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern IntPtr OpenThread(uint access,bool inherit,uint threadId);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags,uint processId);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool Thread32First(IntPtr snapshot,ref ThreadEntry32 entry);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool Thread32Next(IntPtr snapshot,ref ThreadEntry32 entry);
    [DllImport(""kernel32.dll"")] private static extern uint GetCurrentThreadId();
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport(""kernel32.dll"",SetLastError=true)] private static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport(""kernel32.dll"")] private static extern IntPtr GetStdHandle(int handle);
    [DllImport(""kernel32.dll"")] private static extern IntPtr LocalFree(IntPtr value);
    public sealed class RunResult { public int ExitCode; public bool Truncated; }
    private sealed class OutputState { public readonly int limit; public readonly IntPtr job; public long seen; public int truncated; public OutputState(int value,IntPtr handle){limit=value;job=handle;} }
    public static IntPtr Create(){var job=CreateJobObject(IntPtr.Zero,null);if(job==IntPtr.Zero)throw new InvalidOperationException(""inner job create failed: ""+Marshal.GetLastWin32Error());var value=new ExtendedLimit();value.basic.flags=KillOnClose;var size=Marshal.SizeOf(typeof(ExtendedLimit));var pointer=Marshal.AllocHGlobal(size);try{Marshal.StructureToPtr(value,pointer,false);if(!SetInformationJobObject(job,Extended,pointer,(uint)size))throw new InvalidOperationException(""inner job policy failed: ""+Marshal.GetLastWin32Error());return job;}catch{CloseHandle(job);throw;}finally{Marshal.FreeHGlobal(pointer);}}
    public static uint Active(IntPtr job){var size=Marshal.SizeOf(typeof(BasicAccounting));var pointer=Marshal.AllocHGlobal(size);try{if(!QueryInformationJobObject(job,Accounting,pointer,(uint)size,IntPtr.Zero))throw new InvalidOperationException(""inner job readback failed: ""+Marshal.GetLastWin32Error());return ((BasicAccounting)Marshal.PtrToStructure(pointer,typeof(BasicAccounting))).active;}finally{Marshal.FreeHGlobal(pointer);}}
    private static string Quote(string value){if(value.Length>0&&value.IndexOfAny(new char[]{' ','\t','""'})<0)return value;var result=new StringBuilder();result.Append('""');var slashes=0;foreach(var character in value){if(character=='\\'){slashes++;continue;}if(character=='""'){result.Append('\\',slashes*2+1);result.Append('""');slashes=0;continue;}result.Append('\\',slashes);slashes=0;result.Append(character);}result.Append('\\',slashes*2);result.Append('""');return result.ToString();}
    private static void Forward(IntPtr readHandle,Stream target,OutputState state){using(var source=new FileStream(new SafeFileHandle(readHandle,true),FileAccess.Read,8192,false)){var buffer=new byte[8192];int read;while((read=source.Read(buffer,0,buffer.Length))>0){var before=Interlocked.Add(ref state.seen,read)-read;var remaining=state.limit-before;var captured=remaining<=0?0:(int)Math.Min((long)read,remaining);if(captured>0){target.Write(buffer,0,captured);target.Flush();}if(captured!=read&&Interlocked.Exchange(ref state.truncated,1)==0){TerminateJobObject(state.job,1);}}}}
    private static void ProtectFutureThreads(){Type type=null;foreach(var assembly in AppDomain.CurrentDomain.GetAssemblies()){type=assembly.GetType(""W017SupervisorProtection"",false,false);if(type!=null)break;}if(type==null)throw new InvalidOperationException(""future-thread protection type is unavailable"");var method=type.GetMethod(""ProtectFutureThreads"",System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.Static);if(method==null)throw new InvalidOperationException(""future-thread protection method is unavailable"");try{method.Invoke(null,null);}catch(System.Reflection.TargetInvocationException exception){throw new InvalidOperationException(""future-thread protection failed"",exception.InnerException??exception);}}
    private static bool SameLuid(Luid left,Luid right){return left.low==right.low&&left.high==right.high;}
    private static LuidAttributes[] ReadPrivileges(IntPtr token){uint required;GetTokenInformation(token,3,IntPtr.Zero,0,out required);if(required<4)throw new InvalidOperationException(""token privilege size could not be read: ""+Marshal.GetLastWin32Error());var buffer=Marshal.AllocHGlobal((int)required);try{if(!GetTokenInformation(token,3,buffer,required,out required))throw new InvalidOperationException(""token privileges could not be read: ""+Marshal.GetLastWin32Error());var count=Marshal.ReadInt32(buffer);if(count<0||4L+(long)count*Marshal.SizeOf(typeof(LuidAttributes))>required)throw new InvalidOperationException(""token privilege payload is malformed"");var result=new LuidAttributes[count];var size=Marshal.SizeOf(typeof(LuidAttributes));for(var index=0;index<count;index++)result[index]=(LuidAttributes)Marshal.PtrToStructure(IntPtr.Add(buffer,4+index*size),typeof(LuidAttributes));return result;}finally{Marshal.FreeHGlobal(buffer);}}
    private static uint ReadGroupAttributes(IntPtr token,IntPtr sid){uint required;GetTokenInformation(token,2,IntPtr.Zero,0,out required);if(required<4)throw new InvalidOperationException(""token group size could not be read: ""+Marshal.GetLastWin32Error());var buffer=Marshal.AllocHGlobal((int)required);try{if(!GetTokenInformation(token,2,buffer,required,out required))throw new InvalidOperationException(""token groups could not be read: ""+Marshal.GetLastWin32Error());var count=Marshal.ReadInt32(buffer);var offset=IntPtr.Size==8?8:4;var size=Marshal.SizeOf(typeof(SidAndAttributes));for(var index=0;index<count;index++){var value=(SidAndAttributes)Marshal.PtrToStructure(IntPtr.Add(buffer,offset+index*size),typeof(SidAndAttributes));if(EqualSid(value.sid,sid))return value.attributes;}throw new InvalidOperationException(""trusted authority guard SID is absent from the token"");}finally{Marshal.FreeHGlobal(buffer);}}
    private static IntPtr CreatePrivilegeStrippedToken(IntPtr sourceToken){Luid allowed;if(!LookupPrivilegeValue(null,""SeChangeNotifyPrivilege"",out allowed))throw new InvalidOperationException(""allowlisted privilege identity could not be resolved: ""+Marshal.GetLastWin32Error());var source=ReadPrivileges(sourceToken);var deleted=new System.Collections.Generic.List<LuidAttributes>();foreach(var privilege in source)if(!SameLuid(privilege.luid,allowed))deleted.Add(new LuidAttributes{luid=privilege.luid,attributes=0});var guardText=Environment.GetEnvironmentVariable(""RUSTY_AFFECTED_VALIDATION_GUARD_SID"");if(String.IsNullOrWhiteSpace(guardText))throw new InvalidOperationException(""trusted authority guard identity is absent"");IntPtr deleteBuffer=IntPtr.Zero,disableBuffer=IntPtr.Zero,guardSid=IntPtr.Zero,restricted=IntPtr.Zero;try{if(!ConvertStringSidToSid(guardText,out guardSid))throw new InvalidOperationException(""trusted authority guard SID could not be parsed: ""+Marshal.GetLastWin32Error());var sourceGuardAttributes=ReadGroupAttributes(sourceToken,guardSid);if((sourceGuardAttributes&4)==0||(sourceGuardAttributes&16)!=0)throw new InvalidOperationException(""trusted authority guard SID is not enabled on the source token"");disableBuffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SidAndAttributes)));Marshal.StructureToPtr(new SidAndAttributes{sid=guardSid,attributes=0},disableBuffer,false);if(deleted.Count>0){var size=Marshal.SizeOf(typeof(LuidAttributes));deleteBuffer=Marshal.AllocHGlobal(size*deleted.Count);for(var index=0;index<deleted.Count;index++)Marshal.StructureToPtr(deleted[index],IntPtr.Add(deleteBuffer,index*size),false);}Environment.SetEnvironmentVariable(""RUSTY_AFFECTED_VALIDATION_REMOVED_PRIVILEGE_LUID"",deleted.Count==0?null:(deleted[0].luid.high.ToString(System.Globalization.CultureInfo.InvariantCulture)+"":""+deleted[0].luid.low.ToString(System.Globalization.CultureInfo.InvariantCulture)));if(!CreateRestrictedToken(sourceToken,0,1,disableBuffer,(uint)deleted.Count,deleteBuffer,0,IntPtr.Zero,out restricted))throw new InvalidOperationException(""guard-disabled privilege-deleted leaf token creation failed: ""+Marshal.GetLastWin32Error());var observedGuardAttributes=ReadGroupAttributes(restricted,guardSid);if((observedGuardAttributes&16)==0||(observedGuardAttributes&4)!=0)throw new InvalidOperationException(""guard-disabled leaf token did not retain the authority group as deny-only"");var observed=ReadPrivileges(restricted);foreach(var privilege in observed)if(!SameLuid(privilege.luid,allowed))throw new InvalidOperationException(""privilege-deleted leaf token retained a non-allowlisted privilege"");if(deleted.Count>0)foreach(var privilege in observed)if(SameLuid(privilege.luid,deleted[0].luid))throw new InvalidOperationException(""privilege-deleted leaf token retained the source privilege selected for irreversible-removal proof"");return restricted;}catch{if(restricted!=IntPtr.Zero)CloseHandle(restricted);throw;}finally{if(deleteBuffer!=IntPtr.Zero)Marshal.FreeHGlobal(deleteBuffer);if(disableBuffer!=IntPtr.Zero)Marshal.FreeHGlobal(disableBuffer);if(guardSid!=IntPtr.Zero)LocalFree(guardSid);}}
    private static void AssertAncestorIsolation(IntPtr restrictedToken,int[] trustedPids){IntPtr impersonation=IntPtr.Zero,snapshot=IntPtr.Zero;try{if(!DuplicateTokenEx(restrictedToken,0x000c,IntPtr.Zero,2,2,out impersonation))throw new InvalidOperationException(""restricted impersonation token creation failed: ""+Marshal.GetLastWin32Error());if(!ImpersonateLoggedOnUser(impersonation))throw new InvalidOperationException(""restricted ancestor-isolation impersonation failed: ""+Marshal.GetLastWin32Error());var seen=new System.Collections.Generic.HashSet<int>();var trusted=new System.Collections.Generic.HashSet<uint>();foreach(var pid in trustedPids??new int[0]){if(pid<=0||!seen.Add(pid))continue;trusted.Add(unchecked((uint)pid));var accesses=new uint[]{0x0001,0x0002,0x0008,0x0010,0x0020,0x0040,0x0200,0x0400,0x0800,0x1000,0x2000,0x00040000,0x00080000};foreach(var access in accesses){var forbidden=OpenProcess(access,false,pid);if(forbidden!=IntPtr.Zero){CloseHandle(forbidden);throw new InvalidOperationException(""privilege-deleted leaf token can target or query a trusted ancestor process: pid=""+pid+"" access=0x""+access.ToString(""x8""));}}}snapshot=CreateToolhelp32Snapshot(4,0);if(snapshot==new IntPtr(-1))throw new InvalidOperationException(""trusted ancestor thread snapshot failed: ""+Marshal.GetLastWin32Error());var entry=new ThreadEntry32();entry.size=(uint)Marshal.SizeOf(typeof(ThreadEntry32));if(Thread32First(snapshot,ref entry)){do{if(trusted.Contains(entry.ownerProcessId)){foreach(var access in new uint[]{0x0001,0x0002,0x0008,0x0010,0x0020,0x0040,0x0080,0x0100,0x0200,0x0400,0x0800,0x00040000,0x00080000}){var forbidden=OpenThread(access,false,entry.threadId);if(forbidden!=IntPtr.Zero){CloseHandle(forbidden);throw new InvalidOperationException(""privilege-deleted leaf token can target or query a trusted ancestor thread: tid=""+entry.threadId+"" access=0x""+access.ToString(""x8""));}}}entry.size=(uint)Marshal.SizeOf(typeof(ThreadEntry32));}while(Thread32Next(snapshot,ref entry));}}finally{RevertToSelf();if(snapshot!=IntPtr.Zero&&snapshot!=new IntPtr(-1))CloseHandle(snapshot);if(impersonation!=IntPtr.Zero)CloseHandle(impersonation);}}
    public static RunResult Run(string executable,string directory,string[] arguments,int outputLimitBytes,int[] trustedPids){const uint suspended=4,noWindow=0x08000000,infinite=0xffffffff,inheritFlag=1,tokenAccess=0x008b;var security=new SecurityAttributes{length=Marshal.SizeOf(typeof(SecurityAttributes)),inherit=1};IntPtr stdoutRead=IntPtr.Zero,stdoutWrite=IntPtr.Zero,stderrRead=IntPtr.Zero,stderrWrite=IntPtr.Zero,job=IntPtr.Zero,sourceToken=IntPtr.Zero,restrictedToken=IntPtr.Zero;var information=new ProcessInformation();Task stdoutTask=null,stderrTask=null;ManualResetEventSlim futureReady=null,futureStop=null;Thread futureThread=null;try{if(!CreatePipe(out stdoutRead,out stdoutWrite,ref security,0))throw new InvalidOperationException(""stdout pipe create failed: ""+Marshal.GetLastWin32Error());if(!SetHandleInformation(stdoutRead,inheritFlag,0))throw new InvalidOperationException(""stdout pipe protection failed: ""+Marshal.GetLastWin32Error());if(!CreatePipe(out stderrRead,out stderrWrite,ref security,0))throw new InvalidOperationException(""stderr pipe create failed: ""+Marshal.GetLastWin32Error());if(!SetHandleInformation(stderrRead,inheritFlag,0))throw new InvalidOperationException(""stderr pipe protection failed: ""+Marshal.GetLastWin32Error());if(!OpenProcessToken(GetCurrentProcess(),tokenAccess,out sourceToken))throw new InvalidOperationException(""source token open failed: ""+Marshal.GetLastWin32Error());restrictedToken=CreatePrivilegeStrippedToken(sourceToken);job=Create();ProtectFutureThreads();AssertAncestorIsolation(restrictedToken,trustedPids);futureReady=new ManualResetEventSlim(false);futureStop=new ManualResetEventSlim(false);futureThread=new Thread(()=>{Environment.SetEnvironmentVariable(""RUSTY_AFFECTED_VALIDATION_FUTURE_THREAD_ID"",GetCurrentThreadId().ToString(System.Globalization.CultureInfo.InvariantCulture));futureReady.Set();futureStop.Wait();});futureThread.IsBackground=true;futureThread.Start();if(!futureReady.Wait(5000))throw new InvalidOperationException(""future trusted-thread sentinel did not publish its identity"");var startup=new StartupInfo{cb=Marshal.SizeOf(typeof(StartupInfo)),flags=0x100,stdin=GetStdHandle(-10),stdout=stdoutWrite,stderr=stderrWrite};var command=new StringBuilder(Quote(executable));foreach(var argument in arguments){command.Append(' ');command.Append(Quote(argument));}if(!CreateProcessAsUser(restrictedToken,executable,command,IntPtr.Zero,IntPtr.Zero,true,suspended|noWindow,IntPtr.Zero,directory,ref startup,out information))throw new InvalidOperationException(""privilege-deleted inner process create failed: ""+Marshal.GetLastWin32Error());if(!AssignProcessToJobObject(job,information.process))throw new InvalidOperationException(""inner job assignment failed: ""+Marshal.GetLastWin32Error());var state=new OutputState(outputLimitBytes,job);var stdoutTarget=Console.OpenStandardOutput();var stderrTarget=Console.OpenStandardError();var stdoutReadForTask=stdoutRead;stdoutTask=Task.Run(()=>Forward(stdoutReadForTask,stdoutTarget,state));stdoutRead=IntPtr.Zero;var stderrReadForTask=stderrRead;stderrTask=Task.Run(()=>Forward(stderrReadForTask,stderrTarget,state));stderrRead=IntPtr.Zero;if(ResumeThread(information.thread)==0xffffffff)throw new InvalidOperationException(""inner process resume failed: ""+Marshal.GetLastWin32Error());CloseHandle(stdoutWrite);stdoutWrite=IntPtr.Zero;CloseHandle(stderrWrite);stderrWrite=IntPtr.Zero;if(WaitForSingleObject(information.process,infinite)!=0)throw new InvalidOperationException(""inner process wait failed: ""+Marshal.GetLastWin32Error());uint exitCode;if(!GetExitCodeProcess(information.process,out exitCode))throw new InvalidOperationException(""inner exit read failed: ""+Marshal.GetLastWin32Error());if(!TerminateJobObject(job,1))throw new InvalidOperationException(""inner job termination failed: ""+Marshal.GetLastWin32Error());var deadline=DateTime.UtcNow.AddSeconds(15);while(Active(job)!=0&&DateTime.UtcNow<deadline)Thread.Sleep(25);if(Active(job)!=0)throw new InvalidOperationException(""inner job retained processes"");if(!Task.WaitAll(new Task[]{stdoutTask,stderrTask},15000))throw new InvalidOperationException(""inner output pipes did not drain completely"");return new RunResult{ExitCode=unchecked((int)exitCode),Truncated=Volatile.Read(ref state.truncated)!=0};}finally{var futureStopped=true;if(futureStop!=null)futureStop.Set();if(futureThread!=null)futureStopped=futureThread.Join(5000);Environment.SetEnvironmentVariable(""RUSTY_AFFECTED_VALIDATION_FUTURE_THREAD_ID"",null);if(information.process!=IntPtr.Zero){TerminateProcess(information.process,1);CloseHandle(information.process);}if(information.thread!=IntPtr.Zero)CloseHandle(information.thread);if(job!=IntPtr.Zero){TerminateJobObject(job,1);CloseHandle(job);}if(restrictedToken!=IntPtr.Zero)CloseHandle(restrictedToken);if(sourceToken!=IntPtr.Zero)CloseHandle(sourceToken);if(stdoutRead!=IntPtr.Zero)CloseHandle(stdoutRead);if(stdoutWrite!=IntPtr.Zero)CloseHandle(stdoutWrite);if(stderrRead!=IntPtr.Zero)CloseHandle(stderrRead);if(stderrWrite!=IntPtr.Zero)CloseHandle(stderrWrite);if(futureReady!=null)futureReady.Dispose();if(futureStop!=null)futureStop.Dispose();if(!futureStopped)throw new InvalidOperationException(""future trusted-thread sentinel did not stop"");}}
}
""@
        try{$innerResult=[W017SupervisorInnerJob]::Run($Executable,$ChildWorkingDirectory,$childArguments,$OutputLimitBytes,$trustedAncestors.ToArray())}finally{if($ancestorProtection-ne$null){$ancestorProtection.Dispose();$ancestorProtection=$null}}
        $exitCode=$innerResult.ExitCode;$outputTruncated=[bool]$innerResult.Truncated
    } else {
        $sudoPath=Resolve-ExactApplication 'sudo';$unsharePath=Resolve-ExactApplication 'unshare';$setprivPath=Resolve-ExactApplication 'setpriv'
        $uid=[W017UnixProcessGroup]::geteuid();$gid=[W017UnixProcessGroup]::getegid()
        $start=[Diagnostics.ProcessStartInfo]::new($sudoPath);$start.WorkingDirectory=$ChildWorkingDirectory;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($argument in @('--non-interactive','--preserve-env','--',$unsharePath,'--pid','--fork','--kill-child=KILL','--mount-proc',$setprivPath,(""--reuid={0}"" -f $uid),(""--regid={0}"" -f $gid),'--keep-groups',$Executable)+@($childArguments)){[void]$start.ArgumentList.Add([string]$argument)}
        $pump=Start-Pump $start;$pump.process.WaitForExit();$exitCode=$pump.process.ExitCode;Complete-Pump $pump;$outputTruncated=$false
    }
    Publish-Completion (""leaf:{0}:{1}`n"" -f $exitCode,([int]$outputTruncated))
    exit 0
} catch {
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$_.Exception.Message))
    try { Publish-Completion (""infra:{0}`n"" -f $encoded) } catch {}
    [Console]::Error.WriteLine('W017_SUPERVISOR_ERROR:'+$encoded)
    exit 125
} finally {
    if($pump-ne$null){try{if(-not$pump.process.HasExited){$pump.process.Kill($true);$pump.process.WaitForExit(15000)}}catch{};try{$pump.process.Dispose()}catch{}}
    if($innerJob-ne[IntPtr]::Zero){try{[void][W017SupervisorInnerJob]::TerminateJobObject($innerJob,1)}catch{};try{[void][W017SupervisorInnerJob]::CloseHandle($innerJob)}catch{}}
    if($ancestorProtection-ne$null){try{$ancestorProtection.Dispose()}catch{}}
    try{$completion.Dispose()}catch{}
}
";
    private static void AppendError(W017BoundedChildResult result, string message) {
        result.Error = String.IsNullOrWhiteSpace(result.Error) ? message : result.Error + Environment.NewLine + message;
    }
    private static void WriteCreateNew(string path, byte[] bytes) {
        var pending = path + ".pending";
        try {
            using (var stream = new FileStream(pending, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
            File.Move(pending, path);
        } catch {
            try { if (File.Exists(pending)) { File.Delete(pending); } } catch { }
            throw;
        }
    }
    private static bool IsPublishedControlReadPending(IOException exception) {
        var code = exception.HResult & 0xffff;
        return code == 32 || code == 33;
    }
    private static bool SameBytes(byte[] expected, byte[] observed) {
        if (expected == null || observed == null || expected.Length != observed.Length) { return false; }
        for (var index = 0; index < expected.Length; index++) { if (expected[index] != observed[index]) { return false; } }
        return true;
    }
    private static bool TryReadExactPublishedControl(string path, byte[] expected, string malformedMessage) {
        if (!File.Exists(path)) { return false; }
        byte[] observed;
        try {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                if (stream.Length != expected.Length) { throw new InvalidOperationException(malformedMessage); }
                observed = new byte[expected.Length];
                var offset = 0;
                while (offset < observed.Length) {
                    var read = stream.Read(observed, offset, observed.Length - offset);
                    if (read == 0) { throw new InvalidOperationException(malformedMessage); }
                    offset += read;
                }
                if (stream.ReadByte() != -1) { throw new InvalidOperationException(malformedMessage); }
            }
        } catch (IOException exception) {
            if (!IsPublishedControlReadPending(exception)) { throw; }
            return false;
        }
        if (!SameBytes(expected, observed)) { throw new InvalidOperationException(malformedMessage); }
        return true;
    }
    private static byte[] ReadBoundedCompletion(Stream source) {
        using (var target = new MemoryStream()) {
            var buffer = new byte[512]; int read;
            while ((read = source.Read(buffer, 0, buffer.Length)) > 0) {
                if (target.Length + read > 8192) { throw new InvalidOperationException("owned validation supervisor completion exceeds its closed bound"); }
                target.Write(buffer, 0, read);
            }
            return target.ToArray();
        }
    }
    private static void ApplySupervisorCompletion(W017BoundedChildResult result, byte[] bytes) {
        string record;
        try { record = new UTF8Encoding(false, true).GetString(bytes); }
        catch (Exception exception) { throw new InvalidOperationException("owned validation supervisor completion is not strict UTF-8: " + exception.Message); }
        if (record.StartsWith("leaf:", StringComparison.Ordinal) && record.EndsWith("\n", StringComparison.Ordinal)) {
            var fields = record.Substring(0, record.Length - 1).Split(':'); int exitCode, truncated;
            if (fields.Length != 3 || !Int32.TryParse(fields[1], System.Globalization.NumberStyles.AllowLeadingSign, System.Globalization.CultureInfo.InvariantCulture, out exitCode) || !Int32.TryParse(fields[2], out truncated) || (truncated != 0 && truncated != 1)) { throw new InvalidOperationException("owned validation leaf completion is malformed"); }
            result.ExitCode = exitCode; result.OutputTruncated = truncated == 1; return;
        }
        if (record.StartsWith("infra:", StringComparison.Ordinal) && record.EndsWith("\n", StringComparison.Ordinal)) {
            try {
                var message = new UTF8Encoding(false, true).GetString(Convert.FromBase64String(record.Substring(6, record.Length - 7)));
                if (String.IsNullOrWhiteSpace(message) || message.Length > 4096) { throw new InvalidOperationException("supervisor message is outside its closed bound"); }
                AppendError(result, "owned validation supervisor reported an infrastructure failure: " + message); return;
            } catch (Exception exception) { throw new InvalidOperationException("owned validation supervisor error completion is malformed: " + exception.Message); }
        }
        throw new InvalidOperationException("owned validation supervisor did not emit exactly one tagged completion");
    }
    private static IntPtr CreateKillOnCloseJob() {
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) { throw new InvalidOperationException("owned validation job creation failed: " + Marshal.GetLastWin32Error()); }
        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION(); limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
        var size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)); var pointer = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(limits, pointer, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, pointer, (uint)size)) { throw new InvalidOperationException("owned validation job policy failed: " + Marshal.GetLastWin32Error()); }
            return job;
        } catch { CloseHandle(job); throw; } finally { Marshal.FreeHGlobal(pointer); }
    }
    private static string ResolveSupervisorBaseDirectory() {
        var root = Path.GetFullPath(Path.GetTempPath());
        if (String.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.Ordinal)) {
            var runnerRoot = Environment.GetEnvironmentVariable("RUNNER_TEMP");
            if (String.IsNullOrWhiteSpace(runnerRoot) || !Path.IsPathRooted(runnerRoot)) { throw new InvalidOperationException("GitHub Actions runner temporary root is absent or not absolute"); }
            root = Path.GetFullPath(runnerRoot);
        }
        if (!Directory.Exists(root)) { throw new InvalidOperationException("owned validation supervisor temporary root does not exist"); }
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) { throw new InvalidOperationException("owned validation supervisor temporary root is a reparse point"); }
        return root;
    }
    private static uint GetJobActiveProcessCount(IntPtr job) {
        var size = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)); var pointer = Marshal.AllocHGlobal(size);
        try {
            if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, pointer, (uint)size, IntPtr.Zero)) { throw new InvalidOperationException("owned validation job readback failed: " + Marshal.GetLastWin32Error()); }
            return ((JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(pointer, typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION))).ActiveProcesses;
        } finally { Marshal.FreeHGlobal(pointer); }
    }
    private static bool WaitForContainmentEmpty(IntPtr job, int processGroupId, int milliseconds) {
        var deadline = DateTime.UtcNow.AddMilliseconds(milliseconds);
        while (DateTime.UtcNow < deadline) {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) { if (GetJobActiveProcessCount(job) == 0) { return true; } }
            else { if (kill(-processGroupId, 0) != 0 && Marshal.GetLastWin32Error() == 3) { return true; } }
            Thread.Sleep(25);
        }
        return RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? GetJobActiveProcessCount(job) == 0 : (kill(-processGroupId, 0) != 0 && Marshal.GetLastWin32Error() == 3);
    }
    private static void NormalizeOwnedSupervisorTreeForDeletion(string root) {
        var pending = new System.Collections.Generic.Stack<string>();
        var directories = new System.Collections.Generic.List<string>();
        pending.Push(root);
        while (pending.Count > 0) {
            var directory = pending.Pop(); directories.Add(directory);
            foreach (var path in Directory.GetFileSystemEntries(directory)) {
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidOperationException("owned validation supervisor evidence contains a reparse point"); }
                if ((attributes & FileAttributes.Directory) != 0) { pending.Push(path); continue; }
                if ((attributes & FileAttributes.ReadOnly) != 0) { File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly); }
            }
        }
        directories.Sort((left, right) => right.Length.CompareTo(left.Length));
        foreach (var directory in directories) {
            var attributes = File.GetAttributes(directory);
            if ((attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidOperationException("owned validation supervisor evidence contains a reparse point"); }
            if ((attributes & FileAttributes.ReadOnly) != 0) { File.SetAttributes(directory, attributes & ~FileAttributes.ReadOnly); }
        }
    }
    private static void DeleteOwnedSupervisorDirectory(string directory, int milliseconds) {
        if (!Directory.Exists(directory) && !File.Exists(directory)) { return; }
        var deadline = DateTime.UtcNow.AddMilliseconds(milliseconds);
        Exception last = null;
        while (true) {
            try { NormalizeOwnedSupervisorTreeForDeletion(directory); Directory.Delete(directory, true); return; }
            catch (Exception exception) when (exception is IOException || exception is UnauthorizedAccessException) {
                last = exception;
                if (DateTime.UtcNow >= deadline) { break; }
                Thread.Sleep(25);
            }
        }
        throw new InvalidOperationException("owned validation supervisor evidence remained undeletable after its bounded cleanup deadline: " + last.Message, last);
    }
    private static W017BoundedChildResult RunCore(string executable, string workingDirectory, string[] arguments, string[] environmentNamesToRemove, int budgetSeconds, int outputLimitBytes, int postKillDrainMilliseconds, string setupDamage) {
        var result = new W017BoundedChildResult();
        var output = new MemoryStream();
        var error = new MemoryStream();
        Process process = null;
        Task stdoutTask = null;
        Task stderrTask = null;
        Task<byte[]> completionTask = null;
        AnonymousPipeServerStream completionPipe = null;
        string supervisorDirectory = null;
        IntPtr job = IntPtr.Zero;
        int processGroupId = 0;
        AncestorRestoreSet ancestorRestore = null;
        ManualResetEventSlim parentFutureReady = null;
        ManualResetEventSlim parentFutureStop = null;
        Thread parentFutureThread = null;
        uint parentFutureThreadId = 0;
        IntPtr parentFutureVerificationHandle = IntPtr.Zero;
        try {
            supervisorDirectory = Path.Combine(ResolveSupervisorBaseDirectory(), "w7-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(supervisorDirectory);
            var supervisorPath = Path.Combine(supervisorDirectory, "supervisor.ps1");
            var readyPath = Path.Combine(supervisorDirectory, "ready.control");
            var goPath = Path.Combine(supervisorDirectory, "go.control");
            var protectedPath = Path.Combine(supervisorDirectory, "protected.control");
            var futureThreadPath = Path.Combine(supervisorDirectory, "future-thread.control");
            var ancestorTemplatePath = Path.Combine(supervisorDirectory, "ancestor-thread-template.bin");
            completionPipe = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
            var completionHandle = completionPipe.GetClientHandleAsString();
            using (var supervisorStream = new FileStream(supervisorPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) {
                var supervisorBytes = new UTF8Encoding(false).GetBytes(SupervisorSource);
                supervisorStream.Write(supervisorBytes, 0, supervisorBytes.Length);
                supervisorStream.Flush(true);
            }
            var argumentPayload = Convert.ToBase64String(Encoding.UTF8.GetBytes(String.Join("\0", arguments)));
            var start = new ProcessStartInfo();
            start.FileName = executable;
            start.WorkingDirectory = workingDirectory;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            foreach (var name in environmentNamesToRemove) { start.Environment.Remove(name); }
            foreach (var argument in new string[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", supervisorPath, "-Executable", executable, "-ChildWorkingDirectory", workingDirectory, "-ReadyPath", readyPath, "-GoPath", goPath, "-ProtectedPath", protectedPath, "-FutureThreadPath", futureThreadPath, "-AncestorTemplatePath", ancestorTemplatePath, "-ArgumentsBase64", argumentPayload, "-CompletionHandle", completionHandle, "-OutputLimitBytes", outputLimitBytes.ToString(System.Globalization.CultureInfo.InvariantCulture) }) { start.ArgumentList.Add(argument); }
            process = new Process(); process.StartInfo = start;
            if (!process.Start()) { throw new InvalidOperationException("owned validation supervisor did not start"); }
            completionPipe.DisposeLocalCopyOfClientHandle();
            completionTask = Task.Run(() => ReadBoundedCompletion(completionPipe));
            result.Started = true;
            if (String.Equals(setupDamage, "before-containment", StringComparison.Ordinal)) { throw new InvalidOperationException("injected pre-containment setup failure"); }
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) {
                job = CreateKillOnCloseJob();
                if (String.Equals(setupDamage, "after-job-create", StringComparison.Ordinal)) { throw new InvalidOperationException("injected post-job-create setup failure"); }
                if (!AssignProcessToJobObject(job, process.Handle)) { throw new InvalidOperationException("owned validation supervisor job assignment failed: " + Marshal.GetLastWin32Error()); }
            } else { processGroupId = process.Id; }
            var state = new CaptureState(outputLimitBytes);
            stdoutTask = Task.Run(() => Drain(process.StandardOutput.BaseStream, output, state));
            stderrTask = Task.Run(() => Drain(process.StandardError.BaseStream, error, state));
            var startupDeadline = DateTime.UtcNow.AddMilliseconds(postKillDrainMilliseconds);
            var expectedReady = new UTF8Encoding(false).GetBytes("ready:" + process.Id.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\n");
            var ready = false;
            while (!ready) {
                if (DateTime.UtcNow >= startupDeadline) { AppendError(result, "owned validation supervisor readiness exceeded its bounded startup deadline"); break; }
                if (TryReadExactPublishedControl(readyPath, expectedReady, "owned validation supervisor readiness is malformed")) { ready = true; break; }
                if (process.WaitForExit(25)) { result.ExitCode = process.ExitCode; AppendError(result, "owned validation supervisor exited before readiness"); break; }
            }
            if (ready) {
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) { ancestorRestore = SnapshotAncestorSecurity(); WriteCreateNew(ancestorTemplatePath, ancestorRestore.FutureThreadOriginalSecurity); }
                WriteCreateNew(goPath, new UTF8Encoding(false).GetBytes("go\n"));
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) {
                    var protectionDeadline = DateTime.UtcNow.AddMilliseconds(postKillDrainMilliseconds);
                    var expectedProtection = new UTF8Encoding(false).GetBytes("protected\n");
                    while (!TryReadExactPublishedControl(protectedPath, expectedProtection, "trusted authority protection handshake is malformed")) {
                        if (DateTime.UtcNow >= protectionDeadline) { throw new InvalidOperationException("trusted authority protection handshake exceeded its bounded deadline"); }
                        if (process.WaitForExit(25)) { throw new InvalidOperationException("owned validation supervisor exited before trusted authority protection completed"); }
                    }
                    parentFutureReady = new ManualResetEventSlim(false); parentFutureStop = new ManualResetEventSlim(false);
                    var futureReady = parentFutureReady; var futureStop = parentFutureStop;
                    parentFutureThread = new Thread(() => { parentFutureThreadId = GetCurrentThreadId(); futureReady.Set(); futureStop.Wait(); });
                    parentFutureThread.IsBackground = true; parentFutureThread.Start();
                    if (!parentFutureReady.Wait(5000) || parentFutureThreadId == 0) { throw new InvalidOperationException("trusted completion parent future-thread sentinel did not start"); }
                    parentFutureVerificationHandle = ancestorRestore.RetainFutureThread(parentFutureThreadId);
                    WriteCreateNew(futureThreadPath, new UTF8Encoding(false).GetBytes("thread:" + parentFutureThreadId.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\n"));
                    if (String.Equals(setupDamage, "terminate-supervisor-after-go", StringComparison.Ordinal)) {
                        if (!TerminateProcess(process.Handle, 0)) { throw new InvalidOperationException("injected supervisor termination failed: " + Marshal.GetLastWin32Error()); }
                    }
                }
            }
            var deadline = DateTime.UtcNow.AddSeconds(budgetSeconds);
            while (true) {
                if (!ready || result.TimedOut || !String.IsNullOrWhiteSpace(result.Error)) { break; }
                if (Volatile.Read(ref state.Truncated) != 0) { break; }
                if (DateTime.UtcNow >= deadline) { result.TimedOut = true; break; }
                if (process.WaitForExit(50)) {
                    if (completionTask == null || !completionTask.Wait(postKillDrainMilliseconds)) { AppendError(result, "owned validation supervisor completion did not close within its bounded deadline"); }
                    else { try { ApplySupervisorCompletion(result, completionTask.Result); } catch (Exception exception) { AppendError(result, exception.Message); } }
                    break;
                }
            }
            result.OutputTruncated = result.OutputTruncated || Volatile.Read(ref state.Truncated) != 0;
        } catch (Exception exception) {
            AppendError(result, exception.Message);
        } finally {
            var cleanupSucceeded = !result.Started;
            if (process != null && result.Started) {
                result.ChildTreeCleanupAttempted = true;
                cleanupSucceeded = false;
                try {
                    var containmentEmpty = true;
                    if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) {
                        if (job != IntPtr.Zero) {
                            if (!TerminateJobObject(job, 1)) { throw new InvalidOperationException("owned validation job termination failed: " + Marshal.GetLastWin32Error()); }
                            containmentEmpty = WaitForContainmentEmpty(job, 0, postKillDrainMilliseconds);
                        }
                    } else if (processGroupId > 0) {
                        if (kill(-processGroupId, 9) != 0 && Marshal.GetLastWin32Error() != 3) { throw new InvalidOperationException("owned validation process-group termination failed: " + Marshal.GetLastWin32Error()); }
                        containmentEmpty = WaitForContainmentEmpty(IntPtr.Zero, processGroupId, postKillDrainMilliseconds);
                    }
                    if (!process.HasExited) { try { process.Kill(true); } catch { } }
                    if (!process.HasExited && !process.WaitForExit(postKillDrainMilliseconds)) { result.PostKillDrainTimedOut = true; }
                    cleanupSucceeded = !result.PostKillDrainTimedOut && containmentEmpty && process.HasExited;
                    if (!cleanupSucceeded) { AppendError(result, "owned validation containment readback retained one or more processes"); }
                } catch (Exception exception) { AppendError(result, "owned validation process-tree cleanup failed: " + exception.Message); }
            }
            if (stdoutTask != null && stderrTask != null) {
                try {
                    if (!Task.WaitAll(new Task[] { stdoutTask, stderrTask }, postKillDrainMilliseconds)) { result.PostKillDrainTimedOut = true; cleanupSucceeded = false; }
                } catch (Exception exception) { AppendError(result, "owned validation stream drain failed: " + exception.Message); cleanupSucceeded = false; }
            }
            if (completionTask != null && !completionTask.IsCompleted) {
                try { completionPipe.Dispose(); if (!completionTask.Wait(postKillDrainMilliseconds)) { result.PostKillDrainTimedOut = true; cleanupSucceeded = false; } }
                catch (Exception exception) { AppendError(result, "owned validation completion drain failed: " + exception.Message); cleanupSucceeded = false; }
            }
            if (ancestorRestore != null) {
                try { ancestorRestore.Restore(); if (parentFutureThread != null) { ancestorRestore.VerifyFutureThread(parentFutureVerificationHandle); } ancestorRestore = null; }
                catch (Exception exception) { AppendError(result, "trusted ancestor fallback restoration failed: " + exception.Message); cleanupSucceeded = false; }
            }
            if (parentFutureVerificationHandle != IntPtr.Zero) { CloseHandle(parentFutureVerificationHandle); parentFutureVerificationHandle = IntPtr.Zero; }
            if (parentFutureStop != null) { parentFutureStop.Set(); }
            if (parentFutureThread != null && !parentFutureThread.Join(5000)) { AppendError(result, "trusted completion parent future-thread sentinel did not stop"); cleanupSucceeded = false; }
            if (!String.IsNullOrWhiteSpace(result.Error) && error.Length > 0) {
                try {
                    var supervisorError = new UTF8Encoding(false, true).GetString(error.ToArray()).Trim();
                    if (supervisorError.Length > 4096) { supervisorError = supervisorError.Substring(0, 4096); }
                    if (!String.IsNullOrWhiteSpace(supervisorError)) { AppendError(result, "owned validation supervisor stderr: " + supervisorError); }
                } catch (Exception exception) { AppendError(result, "owned validation supervisor stderr is not strict UTF-8: " + exception.Message); }
            }
            result.Stdout = output.ToArray(); result.Stderr = error.ToArray();
            result.ContainmentCleanupSucceeded = cleanupSucceeded;
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (process != null) { process.Dispose(); process = null; }
            if (completionPipe != null) { completionPipe.Dispose(); completionPipe = null; }
            var evidenceCleanupSucceeded = supervisorDirectory == null;
            if (supervisorDirectory != null) {
                try { DeleteOwnedSupervisorDirectory(supervisorDirectory, postKillDrainMilliseconds); evidenceCleanupSucceeded = true; }
                catch (Exception exception) { AppendError(result, "owned validation supervisor evidence cleanup failed: " + exception.Message); }
                if (Directory.Exists(supervisorDirectory) || File.Exists(supervisorDirectory)) { AppendError(result, "owned validation supervisor evidence cleanup readback failed"); evidenceCleanupSucceeded = false; }
            }
            result.SupervisorEvidenceCleanupSucceeded = evidenceCleanupSucceeded;
            result.ChildTreeCleanupSucceeded = cleanupSucceeded && evidenceCleanupSucceeded;
            if (result.Started && !result.ChildTreeCleanupSucceeded) { AppendError(result, "complete owned validation child-tree cleanup/readback did not succeed"); }
            if (job != IntPtr.Zero) { CloseHandle(job); }
            if (process != null) { process.Dispose(); }
            if (completionPipe != null) { completionPipe.Dispose(); }
            if (ancestorRestore != null) { try { ancestorRestore.Restore(); } catch { } }
            if (parentFutureReady != null) { parentFutureReady.Dispose(); }
            if (parentFutureStop != null) { parentFutureStop.Dispose(); }
            output.Dispose(); error.Dispose();
        }
        return result;
    }
    private static void WriteExactSecurity(IntPtr handle,byte[] descriptor,string context){var value=Marshal.AllocHGlobal(descriptor.Length);try{Marshal.Copy(descriptor,0,value,descriptor.Length);if(!SetKernelObjectSecurity(handle,5,value))throw new InvalidOperationException(context+": "+Marshal.GetLastWin32Error());}finally{Marshal.FreeHGlobal(value);}}
    private static void RunRestorationCollisionCase(bool sameTemplate){var preReady=new ManualResetEventSlim(false);var lateReady=new ManualResetEventSlim(false);var stop=new ManualResetEventSlim(false);uint preId=0,lateId=0;var preThread=new Thread(()=>{preId=GetCurrentThreadId();preReady.Set();stop.Wait();});var lateThread=new Thread(()=>{lateId=GetCurrentThreadId();lateReady.Set();stop.Wait();});preThread.IsBackground=true;lateThread.IsBackground=true;IntPtr preHandle=IntPtr.Zero,lateHandle=IntPtr.Zero,token=IntPtr.Zero,protectedDescriptor=IntPtr.Zero;byte[] preOriginal=null,lateOriginal=null;try{preThread.Start();lateThread.Start();if(!preReady.Wait(5000)||!lateReady.Wait(5000)||preId==0||lateId==0||preId==lateId)throw new InvalidOperationException("future-thread collision self-test identities are invalid");preHandle=OpenThread(0x000e0000,false,preId);lateHandle=OpenThread(0x000e0000,false,lateId);if(preHandle==IntPtr.Zero||lateHandle==IntPtr.Zero)throw new InvalidOperationException("future-thread collision self-test could not retain its threads: "+Marshal.GetLastWin32Error());preOriginal=ReadAncestorSecurity(preHandle);lateOriginal=ReadAncestorSecurity(lateHandle);if(!OpenProcessToken(GetCurrentProcess(),0x0008,out token))throw new InvalidOperationException("future-thread collision self-test token could not be opened: "+Marshal.GetLastWin32Error());byte[] protectedDacl;protectedDescriptor=BuildProtectionDescriptor(token,out protectedDacl);if(!SetKernelObjectSecurity(preHandle,5,protectedDescriptor)||!SetKernelObjectSecurity(lateHandle,5,protectedDescriptor))throw new InvalidOperationException("future-thread collision self-test protection failed: "+Marshal.GetLastWin32Error());var protectedSecurity=ReadAncestorSecurity(preHandle);var template=sameTemplate?protectedSecurity:lateOriginal;RestoreProtectedFutureThreads(Process.GetCurrentProcess().Id,protectedDacl,template,new System.Collections.Generic.HashSet<uint>{preId});if(!SameSecurity(protectedSecurity,ReadAncestorSecurity(preHandle)))throw new InvalidOperationException("future-thread collision self-test changed an excluded pre-existing descriptor");if(!SameSecurity(template,ReadAncestorSecurity(lateHandle)))throw new InvalidOperationException("future-thread collision self-test did not restore the late-thread template");}finally{if(preHandle!=IntPtr.Zero&&preOriginal!=null)try{WriteExactSecurity(preHandle,preOriginal,"future-thread collision self-test pre-existing cleanup failed");}catch{}if(lateHandle!=IntPtr.Zero&&lateOriginal!=null)try{WriteExactSecurity(lateHandle,lateOriginal,"future-thread collision self-test late cleanup failed");}catch{}stop.Set();preThread.Join(5000);lateThread.Join(5000);if(protectedDescriptor!=IntPtr.Zero)LocalFree(protectedDescriptor);if(token!=IntPtr.Zero)CloseHandle(token);if(preHandle!=IntPtr.Zero)CloseHandle(preHandle);if(lateHandle!=IntPtr.Zero)CloseHandle(lateHandle);preReady.Dispose();lateReady.Dispose();stop.Dispose();}}
    public static void RunRestorationCollisionSelfTests(){RunRestorationCollisionCase(false);RunRestorationCollisionCase(true);}
    public static void RunPublishedControlReadSelfTests() {
        var root = Path.Combine(Path.GetTempPath(), "w017-published-control-read-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try {
            var expected = new UTF8Encoding(false).GetBytes("published\n");
            var heldPath = Path.Combine(root, "held.control");
            if (TryReadExactPublishedControl(heldPath, expected, "published-control self-test record is malformed")) { throw new InvalidOperationException("missing published-control self-test record was accepted"); }
            using (var stream = new FileStream(heldPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.WriteThrough)) {
                stream.Write(expected, 0, expected.Length); stream.Flush(true);
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows) && TryReadExactPublishedControl(heldPath, expected, "published-control self-test record is malformed")) { throw new InvalidOperationException("exclusively held published-control self-test record was accepted as readable"); }
            }
            if (!TryReadExactPublishedControl(heldPath, expected, "published-control self-test record is malformed")) { throw new InvalidOperationException("released published-control self-test record was not readable"); }
            var malformedPath = Path.Combine(root, "malformed.control");
            WriteCreateNew(malformedPath, new UTF8Encoding(false).GetBytes("damaged\n"));
            var rejected = false;
            try { TryReadExactPublishedControl(malformedPath, expected, "published-control self-test record is malformed"); }
            catch (InvalidOperationException exception) { rejected = String.Equals(exception.Message, "published-control self-test record is malformed", StringComparison.Ordinal); }
            if (!rejected) { throw new InvalidOperationException("readable malformed published-control self-test record was not rejected exactly"); }
        } finally {
            try { if (Directory.Exists(root)) { Directory.Delete(root, true); } } catch { }
        }
    }
    public static void RunOwnedSupervisorDeletionSelfTests() {
        var root = Path.Combine(Path.GetTempPath(), "w7-" + Guid.NewGuid().ToString("N"));
        var objectDirectory = Path.Combine(root, "l", "fixture", ".git", "objects", "aa");
        var objectPath = Path.Combine(objectDirectory, "b3bcd923e45600fe0cde641c463ebcaae63a66");
        Directory.CreateDirectory(objectDirectory);
        File.WriteAllText(objectPath, "owned", new UTF8Encoding(false));
        File.SetAttributes(objectPath, File.GetAttributes(objectPath) | FileAttributes.ReadOnly);
        DeleteOwnedSupervisorDirectory(root, 1000);
        if (Directory.Exists(root) || File.Exists(root)) { throw new InvalidOperationException("read-only owned supervisor evidence survived cleanup self-test"); }
    }
    public static W017BoundedChildResult Run(string executable, string workingDirectory, string[] arguments, string[] environmentNamesToRemove, int budgetSeconds, int outputLimitBytes, int postKillDrainMilliseconds) {
        return RunCore(executable, workingDirectory, arguments, environmentNamesToRemove, budgetSeconds, outputLimitBytes, postKillDrainMilliseconds, null);
    }
    public static W017BoundedChildResult RunForSetupFailureTest(string executable, string workingDirectory, string setupDamage, int postKillDrainMilliseconds) {
        if (!String.Equals(setupDamage, "before-containment", StringComparison.Ordinal) && !String.Equals(setupDamage, "after-job-create", StringComparison.Ordinal) && !String.Equals(setupDamage, "terminate-supervisor-after-go", StringComparison.Ordinal)) { throw new ArgumentException("unknown setup damage", "setupDamage"); }
        var arguments = String.Equals(setupDamage, "terminate-supervisor-after-go", StringComparison.Ordinal) ? new string[] { "-NoProfile", "-NonInteractive", "-File", Path.Combine(workingDirectory, "scripts", "Test-PublicBoundary.ps1") } : new string[0];
        return RunCore(executable, workingDirectory, arguments, new string[0], 5, 1024, postKillDrainMilliseconds, setupDamage);
    }
}
'@
}

function Get-AffectedValidationBytesHash([byte[]]$Bytes) { ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant() }
function Get-AffectedValidationCommandBlob([string]$Path) { $blob = (& git -C $root rev-parse "${HeadCommit}:$Path").Trim(); if ($LASTEXITCODE -ne 0 -or $blob -notmatch '^[0-9a-f]{40}$') { throw "Affected-validation command is not an exact head blob: $Path" }; return $blob }
function Invoke-AffectedValidationCheck([object]$Check, [string]$Command, [string[]]$IntegrityPaths, [object]$Inventory) {
    $started = [DateTimeOffset]::UtcNow
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $budget = [Math]::Min([Math]::Max([int]$Check.budget_seconds, 1), 7200)
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $Command) + @($Check.arguments)) { [void]$arguments.Add([string]$argument) }
    $projectedNames = @('RUSTY_AFFECTED_VALIDATION_PHASE_ROOT','RUSTY_AFFECTED_VALIDATION_BASE_COMMIT','RUSTY_AFFECTED_VALIDATION_HEAD_COMMIT','RUSTY_AFFECTED_VALIDATION_PLAN_SHA256','RUSTY_AFFECTED_VALIDATION_PLATFORM','RUSTY_AFFECTED_VALIDATION_CHECK_ID')
    [string[]]$gitEnvironmentNames = @(Get-ChildItem Env: | Where-Object { ([string]$_.Name).StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [string]$_.Name })
    if ($gitEnvironmentNames.Count -gt 1) { [Array]::Sort($gitEnvironmentNames,[StringComparer]::Ordinal) }
    $projectedNames = @($projectedNames + $gitEnvironmentNames)
    $savedEnvironment = @{}
    foreach ($name in $projectedNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
    try {
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_PHASE_ROOT',$phaseEvidenceRoot,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_BASE_COMMIT',$BaseCommit,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_HEAD_COMMIT',$HeadCommit,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_PLAN_SHA256',[string]$plan.plan_sha256,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_PLATFORM',$Platform,'Process')
        [Environment]::SetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_CHECK_ID',[string]$Check.check_id,'Process')
        foreach ($name in $gitEnvironmentNames) { Remove-Item -LiteralPath ("Env:$name") -ErrorAction Stop }
        $child = [W017BoundedChildResult]::new()
        $integrityError = $null
        try { [void](Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $root -ExpectedHead $plan.head -Inventory $Inventory -Paths $IntegrityPaths) } catch { $integrityError = "Pre-execution affected-check input integrity failed: $($_.Exception.Message)" }
        if ($null -eq $integrityError) {
            $child = [W017BoundedChildCapture]::Run((Get-Process -Id $PID).Path, $root, @($arguments.ToArray()), @('GITHUB_OUTPUT','GITHUB_ENV','GITHUB_PATH','GITHUB_STEP_SUMMARY'), $budget, 10485760, 15000)
            if ($child.Started -and (-not $child.ChildTreeCleanupAttempted -or -not $child.ContainmentCleanupSucceeded)) {
                $integrityError = 'Post-execution affected-check child-tree cleanup/readback did not succeed.'
            }
            try { [void](Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $root -ExpectedHead $plan.head -Inventory $Inventory -Paths $IntegrityPaths) } catch {
                $postIntegrityError = "Post-execution affected-check input integrity failed: $($_.Exception.Message)"
                $integrityError = if ($null -eq $integrityError) { $postIntegrityError } else { "$integrityError $postIntegrityError" }
            }
        }
        if ($null -ne $integrityError) { $child.Error = if ([string]::IsNullOrWhiteSpace([string]$child.Error)) { $integrityError } else { ([string]$child.Error + [Environment]::NewLine + $integrityError) } }
    } finally {
        foreach ($name in $projectedNames) {
            if ($null -eq $savedEnvironment[$name]) { Remove-Item -LiteralPath ("Env:$name") -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name,[string]$savedEnvironment[$name],'Process') }
        }
    }
    $stdout = [byte[]]$child.Stdout
    $stderr = [byte[]]$child.Stderr
    if (-not [string]::IsNullOrWhiteSpace([string]$child.Error)) { $stderr = [Text.UTF8Encoding]::new($false).GetBytes([string]$child.Error) }
    # A started check that overruns its contract or floods/drains output is a
    # check failure.  `infra-fail` is reserved for a host/process-start fault;
    # pre-job availability uses the separate typed pending-infrastructure gate.
    $result = if (-not $child.Started) { 'infra-fail' } elseif ($child.TimedOut -or $child.OutputTruncated -or $child.PostKillDrainTimedOut) { 'code-fail' } elseif (-not [string]::IsNullOrWhiteSpace([string]$child.Error)) { 'infra-fail' } elseif ([int]$child.ExitCode -eq 0) { 'pass' } else { 'code-fail' }
    $clock.Stop()
    $aggregate = [pscustomobject][ordered]@{
        check_id=[string]$Check.check_id; command_path=[string]$Check.command_path; command_blob_sha1=Get-AffectedValidationCommandBlob ([string]$Check.command_path)
        result=$result; exit_code=$child.ExitCode; timed_out=[bool]$child.TimedOut; output_truncated=[bool]$child.OutputTruncated; post_kill_drain_timed_out=[bool]$child.PostKillDrainTimedOut
        stdout_sha256=Get-AffectedValidationBytesHash $stdout; stderr_sha256=Get-AffectedValidationBytesHash $stderr
        stdout_bytes=[long]$stdout.Length; stderr_bytes=[long]$stderr.Length
    }
    return [pscustomobject][ordered]@{aggregate=$aggregate;child=$child;stdout=$stdout;stderr=$stderr;started=$started;ended=[DateTimeOffset]::UtcNow;elapsed_ms=[long]$clock.Elapsed.TotalMilliseconds;integrity_failed=($null -ne $integrityError)}
}

function Get-AffectedValidationProducerBinding {
    $github = [string][Environment]::GetEnvironmentVariable('GITHUB_ACTIONS','Process') -ceq 'true'
    if ($github) {
        $required = @('GITHUB_REPOSITORY','GITHUB_EVENT_NAME','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_WORKFLOW_REF','GITHUB_JOB')
        foreach ($name in $required) { if ([string]::IsNullOrWhiteSpace([string][Environment]::GetEnvironmentVariable($name,'Process'))) { throw "Affected check producer environment is incomplete: $name" } }
        $eventName = [string]$env:GITHUB_EVENT_NAME
        if ([string]$env:GITHUB_REPOSITORY -cne [string]$plan.repository -or @('pull_request','push') -cnotcontains $eventName -or [string]$env:GITHUB_WORKFLOW_REF -cnotmatch '^MesmerPrism/rusty-morphospace-work-environment/\.github/workflows/validate\.yml@') { throw 'Affected check producer GitHub workflow identity is invalid.' }
        $pullRequestNumber = 0
        if ($eventName -ceq 'pull_request') {
            $rawPullRequestNumber = [string][Environment]::GetEnvironmentVariable('PR_NUMBER','Process')
            if ([string]::IsNullOrWhiteSpace($rawPullRequestNumber) -or -not [int]::TryParse($rawPullRequestNumber,[ref]$pullRequestNumber) -or $pullRequestNumber -le 0) { throw 'Affected check producer pull-request identity is incomplete.' }
        } elseif (-not [string]::IsNullOrWhiteSpace([string][Environment]::GetEnvironmentVariable('PR_NUMBER','Process'))) {
            throw 'Affected check push producer unexpectedly inherited a pull-request number.'
        }
        return [pscustomobject][ordered]@{context='github-actions';execution_id=[guid]::NewGuid().ToString('N');repository=[string]$plan.repository;event_name=$eventName;pull_request_number=$pullRequestNumber;run_id=[string]$env:GITHUB_RUN_ID;run_attempt=[int]$env:GITHUB_RUN_ATTEMPT;workflow_path='.github/workflows/validate.yml';job=[string]$env:GITHUB_JOB}
    }
    return [pscustomobject][ordered]@{context='local';execution_id=[guid]::NewGuid().ToString('N');repository=[string]$plan.repository;event_name='local';pull_request_number=0;run_id='local';run_attempt=0;workflow_path='local';job='local'}
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
$checkEvidenceRoot = if ([string]::IsNullOrWhiteSpace($CheckEvidenceDirectory)) { Join-Path $parent ("affected-check-evidence-$([string]$plan.plan_sha256)-$Platform") } else { [IO.Path]::GetFullPath($CheckEvidenceDirectory) }
if ([IO.Directory]::Exists($checkEvidenceRoot) -or [IO.File]::Exists($checkEvidenceRoot)) { throw 'Affected-validation check evidence root already exists.' }
$phaseEvidenceRoot = Join-Path $parent ("affected-selector-phases-$([string]$plan.plan_sha256)-$Platform")
$registryPath = Join-Path $root 'manifests/affected-validation-registry.json'
$recomputed = Resolve-MorphospaceAffectedValidation -RepositoryRoot $root -BaseRevision $BaseCommit -HeadRevision $HeadCommit -RegistryPath $registryPath -RequestedTier ([string]$plan.requested_tier)
if ((Get-MorphospaceCanonicalJsonSha256 -Value $recomputed) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $plan) -or [string]$plan.plan_sha256 -cne [string]$recomputed.plan_sha256) { throw 'Affected-validation plan differs from the exact current base/head/registry selection.' }
$selected = @($plan.selected_checks | Where-Object { @($_.platforms) -ccontains $Platform })
if ($selected.Count -eq 0) { throw "Affected-validation execution rejects an empty '$Platform' selection." }
$registry = Read-MorphospaceProtocolJson -Path $registryPath
$compiledRegistry = Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $root -SchemaPath (Join-Path $root 'schemas/affected-validation-registry-v1.schema.json')
$checkMap = @{}; foreach ($check in @($registry.checks)) { $checkMap[[string]$check.check_id] = $check }
$inventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $root -Commit ([string]$plan.head.commit)
$runnerBinding = Get-MorphospaceAffectedCheckRunnerBinding
$runnerSourceManifest = @(Get-MorphospaceAffectedCheckRunnerSourceManifest -Inventory $inventory)
$checkReceiptSchema = Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json'
$checkInventorySchema = Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json'
$producer = Get-AffectedValidationProducerBinding
$results = [Collections.Generic.List[object]]::new()
$outcomes = @{}
$bindings = @{}
$bindingRecords = [Collections.Generic.List[object]]::new()
$emptyBytes = [byte[]]::new(0)
foreach ($selectedCheck in $selected) {
    $check = $checkMap[[string]$selectedCheck.check_id]
    if ($null -eq $check) { throw "Affected-validation selected an unknown check '$($selectedCheck.check_id)'." }
    $prerequisiteBindings = [Collections.Generic.List[object]]::new()
    foreach ($prerequisiteId in @($check.prerequisite_checks)) {
        $prerequisite = [string]$prerequisiteId
        if (-not $bindings.ContainsKey($prerequisite)) { throw "Affected-validation selected order omitted prerequisite binding '$prerequisite' before '$($check.check_id)'." }
        $prerequisiteBindings.Add([pscustomobject][ordered]@{check_id=$prerequisite;binding_sha256=[string]$bindings[$prerequisite]})
    }
    $dependencyClosure = Get-MorphospaceAffectedCheckDependencyClosure -Check $check -CompiledRegistry $compiledRegistry -Inventory $inventory -RepositoryRoot $root
    $dependencyManifest = @($dependencyClosure.manifest)
    $binding = New-MorphospaceAffectedCheckBinding -Repository ([string]$plan.repository) -Platform $Platform -Check $check -Runner $runnerBinding -RunnerSourceManifest $runnerSourceManifest -DependencyManifest $dependencyManifest -DependencyResolution $dependencyClosure.resolution -PrerequisiteBindings @($prerequisiteBindings.ToArray())
    $bindingSha = Get-MorphospaceCanonicalJsonSha256 -Value $binding
    $bindings[[string]$check.check_id] = $bindingSha
    $integrityPathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($integrityPath in @(@($runnerSourceManifest.path) + @($dependencyManifest.path))) { [void]$integrityPathSet.Add([string]$integrityPath) }
    [string[]]$integrityPaths = @($integrityPathSet)
    [Array]::Sort($integrityPaths,[StringComparer]::Ordinal)
    $bindingRecords.Add([pscustomobject][ordered]@{check=$check;binding=$binding;binding_sha256=$bindingSha;integrity_paths=@($integrityPaths)})
}

$priorEvidenceSnapshots = $null
if (-not [string]::IsNullOrWhiteSpace($PriorEvidenceDirectory) -and [IO.Directory]::Exists([IO.Path]::GetFullPath($PriorEvidenceDirectory))) {
    try { $priorEvidenceSnapshots = @((Read-MorphospaceAffectedCheckInventory -EvidenceDirectory $PriorEvidenceDirectory -ExpectedProducerContext $producer -InventorySchemaPath $checkInventorySchema).candidate_snapshots) } catch { $priorEvidenceSnapshots = @() }
}
$reuseSnapshots = @{}
foreach ($record in @($bindingRecords.ToArray())) {
    $check = $record.check
    if ([string]$check.cache_policy -ceq 'disabled' -or [string]$check.external_state -cne 'none' -or $null -eq $priorEvidenceSnapshots -or $priorEvidenceSnapshots.Count -eq 0) { continue }
    $reusable = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $PriorEvidenceDirectory -SchemaPath $checkReceiptSchema -ExpectedBinding $record.binding -ExpectedBindingSha256 ([string]$record.binding_sha256) -RepositoryRoot $root -CurrentHeadCommit ([string]$plan.head.commit) -CandidateEvidenceSnapshots $priorEvidenceSnapshots
    if ($null -ne $reusable) { $reuseSnapshots[[string]$check.check_id] = $reusable }
}

$terminalIntegrityFailure = $false
$infrastructureReasons = [Collections.Generic.List[string]]::new()
$codeFailureReasons = [Collections.Generic.List[string]]::new()
$parentSnapshots = [Collections.Generic.List[object]]::new()
foreach ($record in @($bindingRecords.ToArray())) {
    $check = $record.check
    $binding = $record.binding
    $bindingSha = [string]$record.binding_sha256
    $blockedBy = [Collections.Generic.List[string]]::new()
    foreach ($prerequisiteId in @($check.prerequisite_checks)) {
        $prerequisite = [string]$prerequisiteId
        if (-not $outcomes.ContainsKey($prerequisite)) { throw "Affected-validation execution omitted prerequisite outcome '$prerequisite' before '$($check.check_id)'." }
        if ([string]$outcomes[$prerequisite] -cne 'pass') { $blockedBy.Add($prerequisite) }
    }
    if ($blockedBy.Count -gt 0) {
        $now = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
        [string[]]$blockedIds = @($blockedBy.ToArray()); [Array]::Sort($blockedIds,[StringComparer]::Ordinal)
        $blockedReceipt = [pscustomobject][ordered]@{
            schema='rusty.morphospace.workflow.affected_validation_check_evidence.v1';source=[pscustomobject][ordered]@{base=$plan.base;head=$plan.head};binding=$binding;binding_sha256=$bindingSha
            mode='blocked';started_at=$now;ended_at=$now;elapsed_ms=0;result='blocked';blocked_by=@($blockedIds)
            child=[pscustomobject][ordered]@{started=$false;exit_code=$null;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout=[pscustomobject][ordered]@{path='stdout.bin';bytes=0;sha256=Get-AffectedValidationBytesHash $emptyBytes};stderr=[pscustomobject][ordered]@{path='stderr.bin';bytes=0;sha256=Get-AffectedValidationBytesHash $emptyBytes}}
            artifacts=@()
            reused_from=$null;claims=[pscustomobject][ordered]@{check_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}
        }
        $parentSnapshots.Add((New-MorphospaceAffectedCheckSnapshot -Receipt $blockedReceipt -Stdout $emptyBytes -Stderr $emptyBytes -Artifacts @() -SchemaPath $checkReceiptSchema))
        $outcomes[[string]$check.check_id] = 'blocked'
        continue
    }
    $reusable = if ($reuseSnapshots.ContainsKey([string]$check.check_id)) { $reuseSnapshots[[string]$check.check_id] } else { $null }
    if ($null -ne $reusable) {
        $stdout = [byte[]]$reusable.stdout
        $stderr = [byte[]]$reusable.stderr
        $artifacts = @($reusable.artifacts)
        if ($artifacts.Count -gt 0) { Restore-MorphospaceAffectedCheckArtifacts -PhaseEvidenceRoot $phaseEvidenceRoot -Artifacts $artifacts }
        $artifactReferences = @(Get-MorphospaceAffectedCheckArtifactReferences -Artifacts $artifacts)
        $now = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
        $reusedReceipt = [pscustomobject][ordered]@{
            schema='rusty.morphospace.workflow.affected_validation_check_evidence.v1';source=[pscustomobject][ordered]@{base=$plan.base;head=$plan.head};binding=$binding;binding_sha256=$bindingSha
            mode='reused';started_at=$now;ended_at=$now;elapsed_ms=0;result='pass';blocked_by=@()
            child=[pscustomobject][ordered]@{started=$false;exit_code=0;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout=[pscustomobject][ordered]@{path='stdout.bin';bytes=[long]$stdout.Length;sha256=Get-AffectedValidationBytesHash $stdout};stderr=[pscustomobject][ordered]@{path='stderr.bin';bytes=[long]$stderr.Length;sha256=Get-AffectedValidationBytesHash $stderr}}
            artifacts=@($artifactReferences)
            reused_from=[pscustomobject][ordered]@{receipt_sha256=[string]$reusable.receipt_sha256;source_head=$reusable.receipt.source.head};claims=[pscustomobject][ordered]@{check_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}
        }
        $parentSnapshots.Add((New-MorphospaceAffectedCheckSnapshot -Receipt $reusedReceipt -Stdout $stdout -Stderr $stderr -Artifacts $artifacts -SchemaPath $checkReceiptSchema))
        $aggregate = [pscustomobject][ordered]@{check_id=[string]$check.check_id;command_path=[string]$check.command_path;command_blob_sha1=[string]$binding.command_blob_sha1;result='pass';exit_code=0;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout_sha256=Get-AffectedValidationBytesHash $stdout;stderr_sha256=Get-AffectedValidationBytesHash $stderr;stdout_bytes=[long]$stdout.Length;stderr_bytes=[long]$stderr.Length}
        $results.Add($aggregate); $outcomes[[string]$check.check_id] = 'pass'
        continue
    }
    $command = Join-Path $root (([string]$check.command_path) -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not [IO.File]::Exists($command)) { throw "Affected-validation command is absent: $($check.command_path)" }
    $execution = Invoke-AffectedValidationCheck -Check $check -Command $command -IntegrityPaths @($record.integrity_paths) -Inventory $inventory
    $checkResult = $execution.aggregate
    $artifacts = if ([string]$checkResult.result -ceq 'pass') { @(Get-MorphospaceAffectedCheckPhaseArtifacts -Check $check -PhaseEvidenceRoot $phaseEvidenceRoot) } else { @() }
    $artifactReferences = @(Get-MorphospaceAffectedCheckArtifactReferences -Artifacts $artifacts)
    $executedReceipt = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.affected_validation_check_evidence.v1';source=[pscustomobject][ordered]@{base=$plan.base;head=$plan.head};binding=$binding;binding_sha256=$bindingSha
        mode='executed';started_at=$execution.started.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture);ended_at=$execution.ended.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture);elapsed_ms=[long]$execution.elapsed_ms;result=[string]$checkResult.result;blocked_by=@()
        child=[pscustomobject][ordered]@{started=[bool]$execution.child.Started;exit_code=$execution.child.ExitCode;timed_out=[bool]$execution.child.TimedOut;output_truncated=[bool]$execution.child.OutputTruncated;post_kill_drain_timed_out=[bool]$execution.child.PostKillDrainTimedOut;stdout=[pscustomobject][ordered]@{path='stdout.bin';bytes=[long]$execution.stdout.Length;sha256=[string]$checkResult.stdout_sha256};stderr=[pscustomobject][ordered]@{path='stderr.bin';bytes=[long]$execution.stderr.Length;sha256=[string]$checkResult.stderr_sha256}}
        artifacts=@($artifactReferences)
        reused_from=$null;claims=[pscustomobject][ordered]@{check_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}
    }
    $parentSnapshots.Add((New-MorphospaceAffectedCheckSnapshot -Receipt $executedReceipt -Stdout $execution.stdout -Stderr $execution.stderr -Artifacts $artifacts -SchemaPath $checkReceiptSchema))
    $results.Add($checkResult); $outcomes[[string]$check.check_id] = [string]$checkResult.result
    if ([string]$checkResult.result -ceq 'infra-fail') {
        $reason = if ([string]::IsNullOrWhiteSpace([string]$execution.child.Error)) { 'child process did not start without a typed launch reason' } else { ([string]$execution.child.Error).Replace("`r",' ').Replace("`n",' ') }
        if ($reason.Length -gt 1024) { $reason = $reason.Substring(0,1024) }
        $infrastructureReasons.Add("$([string]$check.check_id): $reason")
    }
    if ([string]$checkResult.result -ceq 'code-fail') {
        $terminalBytes = if ($execution.stderr.Length -gt 0) { [byte[]]$execution.stderr } else { [byte[]]$execution.stdout }
        $terminal = try { ([Text.UTF8Encoding]::new($false,$true)).GetString($terminalBytes) } catch { "<non-UTF8 terminal; stdout=$([string]$checkResult.stdout_sha256); stderr=$([string]$checkResult.stderr_sha256)>" }
        $terminal = $terminal.Replace("`r",' ').Replace("`n",' ').Trim()
        if ($terminal.Length -gt 1024) { $terminal = $terminal.Substring($terminal.Length-1024) }
        if ([string]::IsNullOrWhiteSpace($terminal)) { $terminal = "<empty terminal; exit=$($execution.child.ExitCode)>" }
        $codeFailureReasons.Add("$([string]$check.check_id): exit=$($execution.child.ExitCode); $terminal")
    }
    if ([bool]$execution.integrity_failed) { $terminalIntegrityFailure = $true; break }
}
$resultValues = @($results | ForEach-Object result)
$outcomeValues = @($outcomes.Values)
$overall = if ($resultValues -ccontains 'infra-fail') { 'infra-fail' } elseif ($resultValues -ccontains 'code-fail' -or $outcomeValues -ccontains 'blocked') { 'code-fail' } else { 'pass' }
$evidence = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.affected_validation_evidence.v1'; repository=[string]$plan.repository; base=$plan.base; head=$plan.head; plan_sha256=[string]$plan.plan_sha256; platform=$Platform
    runner=[pscustomobject][ordered]@{ os_description=[Environment]::OSVersion.VersionString; powershell_version=$PSVersionTable.PSVersion.ToString() }
    check_results=@($results.ToArray()); result=$overall
    claims=[pscustomobject][ordered]@{ historical_aggregate_reused=$false; acceptance_authority=$false; publication_authority=$false }
}
$evidenceSchema = Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json'
$evidenceJson = ConvertTo-MorphospaceCanonicalJson -Value $evidence
if (-not (Test-Json -Json $evidenceJson -SchemaFile $evidenceSchema -ErrorAction Stop)) { throw 'Affected-validation evidence fails its closed schema.' }
$inventoryFinalized = $false
$inventoryReceipt = $null
if (-not $terminalIntegrityFailure -and $outcomes.Count -eq $selected.Count) {
    $inventoryReceipt = Write-MorphospaceAffectedCheckCache -EvidenceDirectory $checkEvidenceRoot -Snapshots @($parentSnapshots.ToArray()) -Producer $producer -Source ([pscustomobject][ordered]@{base=$plan.base;head=$plan.head}) -PlanSha256 ([string]$plan.plan_sha256) -Platform $Platform -ReceiptSchemaPath $checkReceiptSchema -InventorySchemaPath $checkInventorySchema
    if ([int]$inventoryReceipt.entry_count -ne $selected.Count) { throw 'Affected check finalized inventory does not cover every selected check.' }
    $inventoryFinalized = $true
}
$evidenceBytes = [Text.UTF8Encoding]::new($false).GetBytes($evidenceJson + [Environment]::NewLine)
$evidenceStream = [IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $evidenceStream.Write($evidenceBytes,0,$evidenceBytes.Length);$evidenceStream.Flush($true) } finally { $evidenceStream.Dispose() }
if ($overall -cne 'pass') {
    $reasonParts = @($infrastructureReasons.ToArray()) + @($codeFailureReasons.ToArray())
    $reasonSuffix = if ($reasonParts.Count -eq 0) { '' } else { " Terminal reason(s): $($reasonParts -join ' | ')" }
    $exception = [InvalidOperationException]::new("Affected-validation execution failed with '$overall'; typed evidence was written to '$output'.$reasonSuffix")
    if ($inventoryFinalized) { $exception.Data['AffectedCacheFinalized'] = 'true'; $exception.Data['AffectedInventorySha256'] = [string]$inventoryReceipt.sha256 }
    throw $exception
}
if (-not $inventoryFinalized) { throw 'Affected-validation passing execution did not finalize its cache inventory.' }
$evidence | Add-Member -MemberType NoteProperty -Name cache_inventory_sha256 -Value ([string]$inventoryReceipt.sha256)
$evidence
