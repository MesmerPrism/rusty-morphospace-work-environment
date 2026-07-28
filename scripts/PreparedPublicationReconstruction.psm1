Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force

$reconstructionIsWindows=[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT
if($reconstructionIsWindows-and-not('RustyMorphospaceReconstructionFileIdentity'-as[type])){
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class RustyMorphospaceReconstructionFileIdentity
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInformation
    {
        public ulong VolumeSerialNumber;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=16)]
        public byte[] FileId;
    }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName, uint desiredAccess, FileShare shareMode, IntPtr securityAttributes,
        FileMode creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file, int informationClass, out FileIdInformation information, uint bufferSize);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle file, StringBuilder path, uint pathLength, uint flags);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetLongPathNameW(
        string shortPath, StringBuilder longPath, uint bufferLength);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetShortPathNameW(
        string longPath, StringBuilder shortPath, uint bufferLength);

    private static SafeFileHandle OpenDirectory(string path)
    {
        const uint FileFlagBackupSemantics = 0x02000000;
        SafeFileHandle handle = CreateFileW(
            path, 0, FileShare.ReadWrite | FileShare.Delete, IntPtr.Zero,
            FileMode.Open, FileFlagBackupSemantics, IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "Could not open directory for physical identity.");
        }
        return handle;
    }

    public static string GetIdentity(string path)
    {
        using (SafeFileHandle handle = OpenDirectory(path)) {
            const int FileIdInfo = 18;
            FileIdInformation information;
            uint size = (uint)Marshal.SizeOf(typeof(FileIdInformation));
            if (!GetFileInformationByHandleEx(handle, FileIdInfo, out information, size)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not query directory identity.");
            }
            if (information.FileId == null || information.FileId.Length != 16) {
                throw new IOException("Directory identity did not contain a 128-bit file identifier.");
            }
            StringBuilder id = new StringBuilder(32);
            foreach (byte value in information.FileId) id.Append(value.ToString("x2"));
            return information.VolumeSerialNumber.ToString("x16") + ":" + id.ToString();
        }
    }

    public static string GetFinalPath(string path)
    {
        using (SafeFileHandle handle = OpenDirectory(path)) {
            StringBuilder buffer = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not resolve final directory path.");
            }
            string value = buffer.ToString();
            if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) {
                return @"\\" + value.Substring(8);
            }
            if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) {
                return value.Substring(4);
            }
            return value;
        }
    }

    public static string GetLongPath(string path)
    {
        StringBuilder buffer = new StringBuilder(32768);
        uint length = GetLongPathNameW(path, buffer, (uint)buffer.Capacity);
        if (length == 0 || length >= buffer.Capacity) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not resolve long directory path.");
        }
        return buffer.ToString();
    }

    public static string GetShortPath(string path)
    {
        StringBuilder buffer = new StringBuilder(32768);
        uint length = GetShortPathNameW(path, buffer, (uint)buffer.Capacity);
        if (length == 0 || length >= buffer.Capacity) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not resolve short directory path.");
        }
        return buffer.ToString();
    }
}
'@
}

function Invoke-ReconstructionGit {
    param([string]$Path,[string[]]$Arguments,[switch]$AllowFailure)
    $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$output=@(& git --no-replace-objects -C $Path @Arguments 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    if($code-ne0-and-not$AllowFailure){throw "Prepared-publication reconstruction Git observation failed: git $($Arguments-join' ')"}
    [pscustomobject]@{code=$code;text=(($output|ForEach-Object{[string]$_})-join"`n").Trim()}
}
function Resolve-ReconstructionGitPath {
    param([string]$Repo,[string]$Value)
    if([IO.Path]::IsPathFullyQualified($Value)){return [IO.Path]::GetFullPath($Value)}
    [IO.Path]::GetFullPath((Join-Path $Repo $Value))
}
function Get-ReconstructionPhysicalDirectory {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not[IO.Directory]::Exists($full)){throw "Prepared-publication reconstruction physical directory is missing: $full"}
    Assert-MorphospaceNoReparseAncestor -Root ([IO.Path]::GetPathRoot($full)) -Candidate $full
    if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){
        $longPath=[IO.Path]::GetFullPath([RustyMorphospaceReconstructionFileIdentity]::GetLongPath($full))
        if(-not$full.Equals($longPath,[StringComparison]::OrdinalIgnoreCase)){
            throw "Prepared-publication reconstruction rejects filesystem aliases that differ from the canonical long path: $full"
        }
        $canonical=[IO.Path]::GetFullPath([RustyMorphospaceReconstructionFileIdentity]::GetFinalPath($full))
        $identity=[RustyMorphospaceReconstructionFileIdentity]::GetIdentity($full)
    }else{
        $canonical=((& realpath -- $full 2>$null)|Out-String).Trim()
        if($LASTEXITCODE-ne0-or-not$canonical){throw "Prepared-publication reconstruction could not resolve physical directory path: $full"}
        $identity=((& stat -Lc '%d:%i' -- $canonical 2>$null)|Out-String).Trim()
        if($LASTEXITCODE-ne0-or$identity-cnotmatch'^[0-9]+:[0-9]+$'){throw "Prepared-publication reconstruction could not query physical directory identity: $full"}
    }
    [pscustomobject][ordered]@{path=$full;canonical_path=$canonical;identity=$identity}
}
function Test-ReconstructionPathOverlap {
    param([string]$First,[string]$Second)
    $firstPath=$First.TrimEnd('\','/');$secondPath=$Second.TrimEnd('\','/')
    $firstPrefix=$firstPath+[IO.Path]::DirectorySeparatorChar;$secondPrefix=$secondPath+[IO.Path]::DirectorySeparatorChar
    $firstPath.Equals($secondPath,[StringComparison]::OrdinalIgnoreCase)-or
        $firstPath.StartsWith($secondPrefix,[StringComparison]::OrdinalIgnoreCase)-or
        $secondPath.StartsWith($firstPrefix,[StringComparison]::OrdinalIgnoreCase)
}
function Assert-ReconstructionNoGitEnvironmentOverride {
    foreach($entry in @(Get-ChildItem Env:|Where-Object{$_.Name-like'GIT_*'})){
        throw "Prepared-publication reconstruction rejects Git environment override '$([string]$entry.Name)'."
    }
}
function Assert-ReconstructionNoAlternateObjectDatabase {
    param([string]$Root,[string]$CommonDir)
    Assert-ReconstructionNoGitEnvironmentOverride
    $objects=Resolve-ReconstructionGitPath $Root (Invoke-ReconstructionGit $Root @('rev-parse','--git-path','objects')).text
    $expectedObjects=[IO.Path]::GetFullPath((Join-Path $CommonDir 'objects'))
    $objectsPhysical=Get-ReconstructionPhysicalDirectory $objects
    $expectedPhysical=Get-ReconstructionPhysicalDirectory $expectedObjects
    if($objectsPhysical.identity-cne$expectedPhysical.identity-or$objectsPhysical.canonical_path-cne$expectedPhysical.canonical_path){
        throw 'Prepared-publication reconstruction rejects external Git object directories.'
    }
    foreach($leaf in @('info\alternates','info\http-alternates')){
        $alternatePath=Join-Path $objects $leaf
        if([IO.File]::Exists($alternatePath)){throw "Prepared-publication reconstruction rejects Git object alternates: $alternatePath"}
    }
    $replaceRefs=(Invoke-ReconstructionGit $Root @('for-each-ref','--format=%(refname)','refs/replace')).text
    if($replaceRefs){throw 'Prepared-publication reconstruction rejects Git replacement refs.'}
    foreach($graftsPath in @((Join-Path $CommonDir 'info\grafts'),(Join-Path $objects 'info\grafts'))){
        if([IO.File]::Exists($graftsPath)){throw "Prepared-publication reconstruction rejects legacy Git grafts: $graftsPath"}
    }
    if((Invoke-ReconstructionGit $Root @('rev-parse','--is-shallow-repository')).text-cne'false'){
        throw 'Prepared-publication reconstruction rejects shallow Git history.'
    }
    $objectsPhysical
}
function Get-ReconstructionRemoteIdentity {
    param([string]$Root,[string]$Remote,[switch]$Push)
    $arguments=@('remote','get-url');if($Push){$arguments+='--push'};$arguments+='--all';$arguments+=$Remote
    $lines=@((Invoke-ReconstructionGit $Root $arguments).text-split"`n"|Where-Object{$_})
    if($lines.Count-ne1){throw "Prepared-publication reconstruction requires exactly one resolved $(if($Push){'push'}else{'fetch'}) URL for remote '$Remote'."}
    $value=[string]$lines[0]
    $descriptor=$null
    if([IO.Path]::IsPathFullyQualified($value)){
        $physical=Get-ReconstructionPhysicalDirectory $value
        $descriptor="file|$($physical.canonical_path)|$($physical.identity)"
    }else{
        $uri=$null
        if([Uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri)-and$uri.IsFile){
            $physical=Get-ReconstructionPhysicalDirectory $uri.LocalPath
            $descriptor="file|$($physical.canonical_path)|$($physical.identity)"
        }elseif($null-ne$uri){
            if($uri.UserInfo){throw "Prepared-publication reconstruction rejects credential-bearing remote '$Remote'."}
            $descriptor="uri|$($uri.AbsoluteUri)"
        }elseif($value-match'^[^/:@\s]+@?[^/:\s]+:.+$'){
            $descriptor="scp|$value"
        }else{
            $physical=Get-ReconstructionPhysicalDirectory (Join-Path $Root $value)
            $descriptor="file|$($physical.canonical_path)|$($physical.identity)"
        }
    }
    Get-MorphospaceSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($descriptor))
}
function Get-ReconstructionReadbackObservation {
    param([string]$Repo,[string]$Remote,[string]$Ref)
    Assert-ReconstructionNoGitEnvironmentOverride
    $root=[IO.Path]::GetFullPath((Invoke-ReconstructionGit $Repo @('rev-parse','--show-toplevel')).text)
    $gitDir=Resolve-ReconstructionGitPath $root (Invoke-ReconstructionGit $Repo @('rev-parse','--absolute-git-dir')).text
    $commonDir=Resolve-ReconstructionGitPath $root (Invoke-ReconstructionGit $Repo @('rev-parse','--git-common-dir')).text
    $rootPhysical=Get-ReconstructionPhysicalDirectory $root
    $gitDirPhysical=Get-ReconstructionPhysicalDirectory $gitDir
    $commonDirPhysical=Get-ReconstructionPhysicalDirectory $commonDir
    $objectsPhysical=Assert-ReconstructionNoAlternateObjectDatabase $root $commonDir
    try{$expectedGitDirPhysical=Get-ReconstructionPhysicalDirectory (Join-Path $root '.git')}catch{
        throw "Prepared-publication reconstruction readback '$Repo' resolved root '$root' without repository-owned .git storage: $($_.Exception.Message)"
    }
    $expectedObjectsPhysical=Get-ReconstructionPhysicalDirectory (Join-Path $expectedGitDirPhysical.canonical_path 'objects')
    if($gitDirPhysical.identity-cne$expectedGitDirPhysical.identity-or
       $gitDirPhysical.canonical_path-cne$expectedGitDirPhysical.canonical_path-or
       $commonDirPhysical.identity-cne$expectedGitDirPhysical.identity-or
       $commonDirPhysical.canonical_path-cne$expectedGitDirPhysical.canonical_path-or
       $objectsPhysical.identity-cne$expectedObjectsPhysical.identity-or
       $objectsPhysical.canonical_path-cne$expectedObjectsPhysical.canonical_path){
        throw 'Prepared-publication reconstruction requires repository-owned .git and object directories below the readback root.'
    }
    $remoteFetchIdentity=Get-ReconstructionRemoteIdentity $root $Remote
    $remotePushIdentity=Get-ReconstructionRemoteIdentity $root $Remote -Push
    $branch=(Invoke-ReconstructionGit $Repo @('branch','--show-current')).text
    $upstream=(Invoke-ReconstructionGit $Repo @('rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}')).text
    $head=(Invoke-ReconstructionGit $Repo @('rev-parse','HEAD^{commit}')).text
    $upstreamTip=(Invoke-ReconstructionGit $Repo @('rev-parse','@{upstream}^{commit}')).text
    $counts=(Invoke-ReconstructionGit $Repo @('rev-list','--left-right','--count','HEAD...@{upstream}')).text-split'\s+'
    if($counts.Count-ne2){throw 'Prepared-publication reconstruction readback divergence observation was malformed.'}
    $status=(Invoke-ReconstructionGit $Repo @('status','--porcelain=v1','--untracked-files=all')).text
    $remoteFields=(Invoke-ReconstructionGit $Repo @('ls-remote','--exit-code',$Remote,$Ref)).text-split'\s+'
    if($remoteFields.Count-lt2-or$remoteFields[0]-notmatch'^[0-9a-f]{40}$'){throw 'Prepared-publication reconstruction remote readback was malformed.'}
    [pscustomobject][ordered]@{
        root=$root;git_dir=$gitDir;common_dir=$commonDir;branch=$branch;upstream=$upstream
        head=$head;upstream_tip=$upstreamTip;ahead=[int]$counts[0];behind=[int]$counts[1]
        clean=(-not[bool]$status);remote_tip=[string]$remoteFields[0]
        root_canonical=$rootPhysical.canonical_path;root_physical_id=$rootPhysical.identity
        git_dir_canonical=$gitDirPhysical.canonical_path;git_dir_physical_id=$gitDirPhysical.identity
        common_dir_canonical=$commonDirPhysical.canonical_path;common_dir_physical_id=$commonDirPhysical.identity
        object_dir_canonical=$objectsPhysical.canonical_path;object_dir_physical_id=$objectsPhysical.identity
        remote_fetch_identity=$remoteFetchIdentity;remote_push_identity=$remotePushIdentity
    }
}
function Assert-ReconstructionObservationEqual {
    param([object]$First,[object]$Second,[string]$Id)
    foreach($field in @('root','git_dir','common_dir','branch','upstream','head','upstream_tip','ahead','behind','clean','remote_tip','root_canonical','root_physical_id','git_dir_canonical','git_dir_physical_id','common_dir_canonical','common_dir_physical_id','object_dir_canonical','object_dir_physical_id','remote_fetch_identity','remote_push_identity')){
        if([string]$First.$field-cne[string]$Second.$field){throw "Prepared-publication reconstruction readback observation changed for '$Id' field '$field'."}
    }
}
function Open-ReconstructionProtocolSnapshot {
    param([string]$Path,[string]$ExpectedSha256='',[string]$Context='protocol document')
    $stream=$null
    try{
        $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($stream.Length-gt67108864){throw "Prepared-publication reconstruction $Context exceeds the 64 MiB protocol bound."}
        $bytes=[byte[]]::new([int]$stream.Length);$read=0
        while($read-lt$bytes.Length){
            $count=$stream.Read($bytes,$read,$bytes.Length-$read)
            if($count-le0){throw "Prepared-publication reconstruction encountered a short read for $Context."}
            $read+=$count
        }
        $sha256=Get-MorphospaceSha256Bytes -Bytes $bytes
        if($ExpectedSha256-and$sha256-cne$ExpectedSha256){throw "Prepared-publication reconstruction evidence hash mismatch for $Context."}
        $document=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context $Context
        [pscustomobject][ordered]@{path=[IO.Path]::GetFullPath($Path);sha256=$sha256;bytes=$bytes;document=$document;stream=$stream}
    }catch{
        if($null-ne$stream){$stream.Dispose()}
        throw
    }
}
function Test-ReconstructionByteArrayEqual {
    param([byte[]]$First,[byte[]]$Second)
    if($First.Length-ne$Second.Length){return $false}
    for($index=0;$index-lt$First.Length;$index++){if($First[$index]-ne$Second[$index]){return $false}}
    $true
}
function Assert-ReconstructionSnapshotStillCurrent {
    param([object]$Snapshot,[string]$Context='protocol document')
    $stream=$null
    try{
        $stream=[IO.FileStream]::new([string]$Snapshot.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($stream.Length-ne$Snapshot.bytes.Length){throw "Prepared-publication reconstruction $Context bytes changed after validation."}
        $current=[byte[]]::new([int]$stream.Length);$read=0
        while($read-lt$current.Length){
            $count=$stream.Read($current,$read,$current.Length-$read)
            if($count-le0){throw "Prepared-publication reconstruction encountered a short admission read for $Context."}
            $read+=$count
        }
        if(-not(Test-ReconstructionByteArrayEqual $Snapshot.bytes $current)){throw "Prepared-publication reconstruction $Context bytes changed after validation."}
    }finally{if($null-ne$stream){$stream.Dispose()}}
}
function Get-ReconstructionBindingSnapshot {
    param([string]$Workspace,[object]$Binding,[object]$Cache,[object]$Leases)
    $path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Binding.path) -RequireLeaf
    $key=[IO.Path]::GetFullPath($path)
    if($Cache.ContainsKey($key)){
        $snapshot=$Cache[$key]
        if([string]$snapshot.sha256-cne[string]$Binding.sha256){throw "Prepared-publication reconstruction repeats '$($Binding.path)' with a different hash."}
        return $snapshot
    }
    $snapshot=Open-ReconstructionProtocolSnapshot $key ([string]$Binding.sha256) "'$([string]$Binding.path)'"
    $Cache.Add($key,$snapshot);$Leases.Add($snapshot)|Out-Null
    $snapshot
}
function Assert-ReconstructionCanonicalBinding {
    param([object]$Actual,[object]$Binding,[string]$Name)
    $expected=[string]$Binding.sha256
    if((Get-MorphospaceCanonicalJsonSha256 $Actual)-cne$expected-or(Get-MorphospaceCanonicalJsonSha256 $Binding.value)-cne$expected){throw "Prepared-publication reconstruction $Name canonical hash mismatch."}
}
function Test-ReconstructionExactReceiptVector {
    param([AllowNull()][object]$Receipts,[string]$Expected)
    $values=@($Receipts)
    $values.Count-eq1-and[string]$values[0]-ceq$Expected
}
function Assert-ReconstructionExactProperties {
    param([AllowNull()][object]$Value,[string[]]$Names,[string]$Name)
    if($null-eq$Value){throw "Prepared-publication reconstruction $Name is absent."}
    $actual=@($Value.PSObject.Properties.Name|Sort-Object)
    $expected=@($Names|Sort-Object)
    if(($actual-join'|')-cne($expected-join'|')){throw "Prepared-publication reconstruction $Name has a non-canonical shape."}
}
function Get-ReconstructionTransitionBinding {
    param(
        [string]$Workspace,
        [object]$Binding,
        [string]$Name,
        [string]$ProjectId,
        [string]$UnitId,
        [object]$Cache,
        [object]$Leases
    )
    $intentSnapshot=Get-ReconstructionBindingSnapshot $Workspace $Binding.intent $Cache $Leases
    $completionSnapshot=Get-ReconstructionBindingSnapshot $Workspace $Binding.completion $Cache $Leases
    $intentPath=$intentSnapshot.path;$completionPath=$completionSnapshot.path
    $intent=$intentSnapshot.document;$completion=$completionSnapshot.document
    Assert-ReconstructionExactProperties $intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') "$Name intent"
    Assert-ReconstructionExactProperties $intent.state @('path') "$Name intent state reference"
    Assert-ReconstructionExactProperties $intent.unit @('path') "$Name intent unit reference"
    Assert-ReconstructionExactProperties $intent.events @('path') "$Name intent events reference"
    Assert-ReconstructionExactProperties $intent.pre @('state','unit') "$Name intent pre"
    Assert-ReconstructionExactProperties $intent.pre.state @('sha256') "$Name intent pre-state"
    Assert-ReconstructionExactProperties $intent.pre.unit @('sha256') "$Name intent pre-unit"
    Assert-ReconstructionExactProperties $intent.target @('state','unit') "$Name intent target"
    Assert-ReconstructionExactProperties $intent.target.state @('sha256','document') "$Name intent target-state"
    Assert-ReconstructionExactProperties $intent.target.unit @('sha256','document') "$Name intent target-unit"
    Assert-ReconstructionExactProperties $intent.expected @('state_sha256','unit_sha256','event_tail_id') "$Name intent expected"
    Assert-ReconstructionExactProperties $intent.event @('schema','event_id','sequence','timestamp','project_id','unit_id','event_type','summary','receipts') "$Name intent event"
    Assert-ReconstructionExactProperties $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') "$Name completion"
    Assert-ReconstructionExactProperties $completion.intent @('role','path','schema','sha256') "$Name completion intent reference"
    $transactionId=[string]$intent.transaction_id
    $expectedIntentPath="receipts/transactions/$transactionId.intent.json"
    $expectedCompletionPath="receipts/transactions/$transactionId.completion.json"
    $targetStateHash=Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document
    $targetUnitHash=Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document
    $checks=[ordered]@{
        intent_schema=([string]$intent.schema-ceq'rusty.morphospace.workflow.transition_ledger_intent.v1')
        intent_status=([string]$intent.status-ceq'prepared')
        transaction_id=($transactionId-ceq"$([string]$Binding.event_id)-transition")
        intent_path=([string]$Binding.intent.path-ceq$expectedIntentPath)
        completion_path=([string]$Binding.completion.path-ceq$expectedCompletionPath)
        state_path=([string]$intent.state.path-ceq'workspace.state.json')
        unit_path=([string]$intent.unit.path-ceq"iteration-units/$UnitId.json")
        events_path=([string]$intent.events.path-ceq'iteration-events.jsonl')
        expected_state=([string]$intent.expected.state_sha256-ceq[string]$intent.pre.state.sha256)
        expected_unit=([string]$intent.expected.unit_sha256-ceq[string]$intent.pre.unit.sha256)
        target_state=([string]$intent.target.state.sha256-ceq$targetStateHash)
        target_unit=([string]$intent.target.unit.sha256-ceq$targetUnitHash)
        target_project=([string]$intent.target.state.document.project_id-ceq$ProjectId)
        target_unit_id=([string]$intent.target.unit.document.unit_id-ceq$UnitId)
        event_schema=([string]$intent.event.schema-ceq'rusty.morphospace.workflow.iteration_event.v1')
        event_id=([string]$intent.event.event_id-ceq[string]$Binding.event_id)
        event_project=([string]$intent.event.project_id-ceq$ProjectId)
        event_unit=([string]$intent.event.unit_id-ceq$UnitId)
        completion_schema=([string]$completion.schema-ceq'rusty.morphospace.workflow.transition_ledger_completion.v1')
        completion_status=([string]$completion.status-ceq'committed')
        completion_transaction=([string]$completion.transaction_id-ceq$transactionId)
        completion_event=([string]$completion.event_id-ceq[string]$Binding.event_id)
        completion_intent_role=([string]$completion.intent.role-ceq'transition-ledger-intent')
        completion_intent_path=([string]$completion.intent.path-ceq$expectedIntentPath)
        completion_intent_schema=([string]$completion.intent.schema-ceq[string]$intent.schema)
        completion_intent_hash=([string]$completion.intent.sha256-ceq[string]$intentSnapshot.sha256)
        completion_state=([string]$completion.state_sha256-ceq$targetStateHash)
        completion_unit=([string]$completion.unit_sha256-ceq$targetUnitHash)
    }
    $failed=@($checks.Keys|Where-Object{-not$checks[$_]})
    if($failed.Count){throw "Prepared-publication reconstruction $Name transition binding mismatch: $($failed-join', ')."}
    [pscustomobject]@{intent=$intent;completion=$completion;intent_path=$intentPath;completion_path=$completionPath}
}
function Assert-ReconstructionTransitionContinuity {
    param([object[]]$Transitions)
    if($Transitions.Count-lt2){throw 'Prepared-publication reconstruction transition chain is incomplete.'}
    for($index=1;$index-lt$Transitions.Count;$index++){
        $previous=$Transitions[$index-1];$current=$Transitions[$index]
        if([string]$current.intent.pre.state.sha256-cne[string]$previous.completion.state_sha256-or
           [string]$current.intent.pre.unit.sha256-cne[string]$previous.completion.unit_sha256){
            throw "Prepared-publication reconstruction transition chain is not state/unit continuous before event '$([string]$current.intent.event.event_id)'."
        }
    }
}
function Get-ReconstructionCompleteTransitionChain {
    param(
        [string]$Workspace,
        [object]$Document,
        [object[]]$Ledger,
        [object]$Validation,
        [object]$Acceptance,
        [object]$Prepared,
        [int]$ValidationSequence,
        [int]$AcceptanceSequence,
        [int]$PreparedSequence,
        [string]$ProjectId,
        [string]$UnitId,
        [object]$Cache,
        [object]$Leases
    )
    $expectedEvents=@($Ledger|Where-Object{[int]$_.sequence-gt$ValidationSequence-and[int]$_.sequence-lt$PreparedSequence-and[int]$_.sequence-ne$AcceptanceSequence})
    $declared=@($Document.intervening_transitions)
    if($declared.Count-ne$expectedEvents.Count){throw 'Prepared-publication reconstruction intervening transition coverage is incomplete.'}
    $byEvent=@{
        ([string]$Validation.intent.event.event_id)=$Validation
        ([string]$Acceptance.intent.event.event_id)=$Acceptance
        ([string]$Prepared.intent.event.event_id)=$Prepared
    }
    for($index=0;$index-lt$expectedEvents.Count;$index++){
        if([string]$declared[$index].event_id-cne[string]$expectedEvents[$index].event_id){throw 'Prepared-publication reconstruction intervening transitions are reordered or substituted.'}
        $transition=Get-ReconstructionTransitionBinding $Workspace $declared[$index] 'intervening' $ProjectId $UnitId $Cache $Leases
        [void](Assert-ReconstructionLedgerEvent $Ledger $transition 'intervening')
        $byEvent[[string]$declared[$index].event_id]=$transition
    }
    $chain=@()
    foreach($event in @($Ledger|Where-Object{[int]$_.sequence-ge$ValidationSequence-and[int]$_.sequence-le$PreparedSequence})){
        $eventId=[string]$event.event_id
        if(-not$byEvent.ContainsKey($eventId)){throw "Prepared-publication reconstruction transition chain omits ledger event '$eventId'."}
        $chain+=,$byEvent[$eventId]
    }
    if($ValidationSequence-gt1){
        $predecessorEvent=$Ledger[$ValidationSequence-2]
        if($null-eq$Document.validation_predecessor-or[string]$Document.validation_predecessor.event_id-cne[string]$predecessorEvent.event_id){
            throw 'Prepared-publication reconstruction validation predecessor transition is absent or substituted.'
        }
        $predecessor=Get-ReconstructionTransitionBinding $Workspace $Document.validation_predecessor 'validation predecessor' $ProjectId $UnitId $Cache $Leases
        $predecessorSequence=Assert-ReconstructionLedgerEvent $Ledger $predecessor 'validation predecessor'
        if($predecessorSequence-ne$ValidationSequence-1){throw 'Prepared-publication reconstruction validation predecessor is not adjacent.'}
        $chain=@($predecessor)+@($chain)
    }elseif($null-ne$Document.validation_predecessor){
        throw 'Prepared-publication reconstruction first-ledger validation must not declare a predecessor.'
    }
    Assert-ReconstructionTransitionContinuity $chain
    $chain
}
function Get-ReconstructionPlanAuthority {
    param([object]$Plan,[object]$MapDocument)
    $aliases=@{};$entries=@{}
    foreach($entry in @($MapDocument.repositories)){
        $physicalId=[string]$entry.repo_id
        if($entries.ContainsKey($physicalId)){throw 'Prepared-publication reconstruction repository map contains duplicate IDs.'}
        $entries[$physicalId]=$entry
        foreach($logicalId in @($physicalId)+@($entry.aliases)){
            $logical=[string]$logicalId
            if($aliases.ContainsKey($logical)){throw "Prepared-publication reconstruction repository map alias '$logical' is ambiguous."}
            $aliases[$logical]=$entry
        }
    }
    $logicalSeen=@{};$groups=@{}
    foreach($leg in @($Plan.repositories)){
        $logical=[string]$leg.repo_id
        if($logicalSeen.ContainsKey($logical)){throw "Prepared-publication reconstruction prepared plan duplicates logical repository '$logical'."}
        $logicalSeen[$logical]=$true
        if(-not$aliases.ContainsKey($logical)){throw "Prepared-publication reconstruction prepared plan repository '$logical' is not mapped."}
        $upstream=[string]$leg.upstream
        if($upstream-notmatch'^([^/]+)/(.+)$'){throw "Prepared-publication reconstruction plan upstream for '$logical' is not canonical."}
        $remote=$Matches[1];$mergeBranch=$Matches[2];$mergeRef="refs/heads/$mergeBranch"
        $entry=$aliases[$logical];$repo=[IO.Path]::GetFullPath([string]$entry.path)
        $repoPhysical=Get-ReconstructionPhysicalDirectory $repo
        $key="$([string]$repoPhysical.identity)|$remote|$mergeRef"
        if(-not$groups.ContainsKey($key)){$groups[$key]=[pscustomobject][ordered]@{key=$key;observation_repo_id=[string]$entry.repo_id;repo=$repo;remote=$remote;ref=$mergeRef;branch=[string]$leg.branch;upstream=$upstream;prepared_revision=[string]$leg.commit;logical_repo_ids=[Collections.Generic.List[string]]::new()}}
        $group=$groups[$key]
        if([string]$group.prepared_revision-cne[string]$leg.commit-or[string]$group.branch-cne[string]$leg.branch-or[string]$group.upstream-cne$upstream){throw "Prepared-publication reconstruction logical aliases do not share one physical branch/upstream/prepared revision for '$logical'."}
        $group.logical_repo_ids.Add($logical)
    }
    [pscustomobject]@{logical_ids=@($logicalSeen.Keys);groups=@($groups.Values);entries=$entries}
}
function Get-ReconstructionHistory {
    param([string]$Repo,[string]$Prepared,[string]$Tip)
    $ids=@((Invoke-ReconstructionGit $Repo @('rev-list','--reverse',"$Prepared..$Tip")).text-split"`n"|Where-Object{$_})
    @($ids|ForEach-Object{
        $id=$_;$parents=@((Invoke-ReconstructionGit $Repo @('show','-s','--format=%P',$id)).text-split' '|Where-Object{$_})
        $tree=(Invoke-ReconstructionGit $Repo @('show','-s','--format=%T',$id)).text
        $paths=@((Invoke-ReconstructionGit $Repo @('diff-tree','--no-commit-id','--name-only','-r','--root',$id)).text-split"`n"|Where-Object{$_}|Sort-Object -Unique)
        [pscustomobject][ordered]@{revision=$id;parents=$parents;tree=$tree;changed_paths=$paths}
    })
}
function Assert-ReconstructionHistory {
    param([object[]]$Declared,[object[]]$Actual,[string]$Id)
    if($Declared.Count-ne$Actual.Count){throw "Prepared-publication reconstruction incomplete intervening history for '$Id'."}
    for($i=0;$i-lt$Actual.Count;$i++){
        foreach($field in @('revision','tree')){if([string]$Declared[$i].$field-cne[string]$Actual[$i].$field){throw "Prepared-publication reconstruction reordered or abbreviated intervening history for '$Id'."}}
        if((@($Declared[$i].parents)-join'|')-cne(@($Actual[$i].parents)-join'|')-or(@($Declared[$i].changed_paths)-join'|')-cne(@($Actual[$i].changed_paths)-join'|')){throw "Prepared-publication reconstruction incomplete commit detail for '$Id'."}
    }
}
function New-ReconstructionEventId {
    param([string]$UnitId,[int]$Sequence)
    $value="$UnitId-prepared-publication-reconstructed-$('{0:d4}'-f$Sequence)"
    if($value.Length-gt128-or$value-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){
        throw 'Prepared-publication reconstruction event identity is not portable.'
    }
    $value
}
function ConvertFrom-ReconstructionStrictTimestamp {
    param([Parameter(Mandatory)][string]$Value,[string]$Context='timestamp')
    if($Value-cnotmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$'){
        throw "Prepared-publication reconstruction $Context is not a strict invariant ISO-8601 date-time."
    }
    try{return ConvertFrom-MorphospaceInvariantTimestamp -Value $Value}
    catch{throw "Prepared-publication reconstruction $Context is not a valid invariant ISO-8601 date-time."}
}
function Get-ReconstructionBundleBindings {
    param([AllowNull()][object]$Node)
    if($null-eq$Node){return}
    if($Node-is[pscustomobject]){foreach($p in $Node.PSObject.Properties){if($p.Name-ceq'bundle_id'){[string]$p.Value};Get-ReconstructionBundleBindings $p.Value}}
    elseif($Node-is[System.Collections.IEnumerable]-and$Node-isnot[string]){foreach($item in $Node){Get-ReconstructionBundleBindings $item}}
}
function Get-ReconstructionEventLedger {
    param([string]$Workspace)
    $path=Join-Path $Workspace 'iteration-events.jsonl'
    $bytes=[IO.File]::ReadAllBytes($path)
    if($bytes.Length-gt67108864){throw 'Prepared-publication reconstruction event ledger exceeds the 64 MiB protocol bound.'}
    if($bytes.Length-ge3-and$bytes[0]-eq0xef-and$bytes[1]-eq0xbb-and$bytes[2]-eq0xbf){throw 'Prepared-publication reconstruction event ledger must not contain a UTF-8 BOM.'}
    if($bytes-contains0){throw 'Prepared-publication reconstruction event ledger contains NUL bytes.'}
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)}catch{throw 'Prepared-publication reconstruction event ledger is not strict UTF-8.'}
    $lines=$text-split"`n",0
    $events=@();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$previousTimestamp=$null
    $eventSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\iteration-event.schema.json'
    for($index=0;$index-lt$lines.Count;$index++){
        $line=$lines[$index];if($line.EndsWith("`r")){$line=$line.Substring(0,$line.Length-1)}
        if(-not$line){
            if($index-eq$lines.Count-1-and$text.EndsWith("`n")){continue}
            throw "Prepared-publication reconstruction event ledger contains a blank record at line $($index+1)."
        }
        try{$event=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line)) -Context "iteration-events.jsonl:$($index+1)"}catch{throw "Prepared-publication reconstruction event ledger contains malformed JSON at line $($index+1): $($_.Exception.Message)"}
        if(-not(Test-Json -Json ($event|ConvertTo-Json -Depth 16 -Compress) -SchemaFile $eventSchema)){throw "Prepared-publication reconstruction event ledger entry fails its schema at line $($index+1)."}
        $eventId=[string]$event.event_id
        if([string]$event.schema-cne'rusty.morphospace.workflow.iteration_event.v1'-or-not$eventId-or-not$seen.Add($eventId)){
            throw "Prepared-publication reconstruction event ledger schema or event identity is invalid at line $($index+1)."
        }
        if([int]$event.sequence-ne$events.Count+1){throw "Prepared-publication reconstruction event ledger sequence is not contiguous at line $($index+1)."}
        $timestamp=ConvertFrom-ReconstructionStrictTimestamp ([string]$event.timestamp) "event ledger timestamp at line $($index+1)"
        if($null-ne$previousTimestamp-and$timestamp-lt$previousTimestamp){throw "Prepared-publication reconstruction event ledger chronology regresses at line $($index+1)."}
        $receiptSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($reference in @($event.receipts)){if(-not$receiptSet.Add([string]$reference)){throw "Prepared-publication reconstruction event ledger repeats a receipt alias at line $($index+1)."}}
        $previousTimestamp=$timestamp;$events+=,$event
    }
    @($events)
}
function Assert-ReconstructionLedgerEvent {
    param([object[]]$Ledger,[object]$Transition,[string]$Name)
    $eventId=[string]$Transition.intent.event.event_id
    $matches=@($Ledger|Where-Object{[string]$_.event_id-ceq$eventId})
    if($matches.Count-ne1-or(Get-MorphospaceCanonicalJsonSha256 $matches[0])-cne(Get-MorphospaceCanonicalJsonSha256 $Transition.intent.event)){
        throw "Prepared-publication reconstruction $Name event is absent, duplicated, or differs from the immutable event ledger."
    }
    $index=[int]$matches[0].sequence-1
    $expectedTail=if($index-gt0){[string]$Ledger[$index-1].event_id}else{$null}
    if([string]$Transition.intent.expected.event_tail_id-cne[string]$expectedTail){
        throw "Prepared-publication reconstruction $Name event has the wrong preceding event tail."
    }
    [int]$matches[0].sequence
}
function Assert-NoReconstructionConflict {
    param([string]$Workspace,[string]$BundleId,[string[]]$Excluded,[object[]]$Ledger)
    $recognized=@('rusty.morphospace.workflow.executed_push_receipt.v1','rusty.morphospace.workflow.planned_publication_accounting.v1','rusty.morphospace.workflow.unplanned_publication_closure.v1','rusty.morphospace.workflow.unplanned_publication_closure.v2','rusty.morphospace.workflow.published_prerequisite_suffix_reconciliation.v1','rusty.morphospace.workflow.published_prerequisite_suffix_reconciliation.v2','rusty.morphospace.workflow.planning_suffix_rewrite_recovery.v1','rusty.morphospace.workflow.prepared_publication_reconstruction.v1','rusty.morphospace.workflow.prepared_push_retirement.v1')
    $consumingActions=@('RecordPublication','ReconcilePublication','ReconcilePlanningSuffixRewrite','ReconcilePublishedPrerequisiteSuffix','ReconcilePreparedPublication','RetirePreparedPush')
    foreach($file in @(Get-ChildItem (Join-Path $Workspace 'receipts') -File -Recurse -Filter *.json)){
        $relative=[IO.Path]::GetRelativePath($Workspace,$file.FullName).Replace('\','/');if($Excluded-ccontains$relative){continue}
        try{$candidate=Read-MorphospaceProtocolJson $file.FullName}catch{throw "Prepared-publication reconstruction encountered malformed evidence '$relative'."}
        $bundleValues=@(Get-ReconstructionBundleBindings $candidate)
        if(($recognized-contains[string]$candidate.schema-and$bundleValues-contains$BundleId)-or
           ([string]$candidate.schema-like'rusty.morphospace.workflow.work_unit_automation_receipt.v*'-and
             $consumingActions-ccontains[string]$candidate.action-and
            $bundleValues-contains$BundleId)){
            throw "Prepared-publication reconstruction found mutually exclusive execution/accounting/reconciliation evidence at '$relative'."
        }
    }
    foreach($event in @($Ledger)){
        foreach($reference in @($event.receipts)){
            $relative=[string]$reference
            if($Excluded-ccontains$relative){continue}
            try{
                $resolved=Resolve-MorphospaceWorkspacePath $Workspace $relative -RequireLeaf
                $candidate=Read-MorphospaceProtocolJson $resolved
            }catch{throw "Prepared-publication reconstruction could not authenticate event receipt '$relative' for event '$([string]$event.event_id)'."}
            $bundleValues=@(Get-ReconstructionBundleBindings $candidate)
            if(($recognized-contains[string]$candidate.schema-and$bundleValues-contains$BundleId)-or
               ([string]$candidate.schema-like'rusty.morphospace.workflow.work_unit_automation_receipt.v*'-and
                 $consumingActions-ccontains[string]$candidate.action-and
                $bundleValues-contains$BundleId)){
                throw "Prepared-publication reconstruction found event-bound mutually exclusive evidence at '$relative'."
            }
        }
    }
}
function Invoke-MorphospacePreparedPublicationReconstruction {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$UnitId,[Parameter(Mandatory)][string]$RepoMapPath,[Parameter(Mandatory)][string]$ReconstructionReceipt,[string]$Timestamp='',[string]$OutPath='',[switch]$Execute,[ValidateSet('none','after-intent','after-projection','after-event')][string]$FaultAfter='none')
    $bindingCache=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $leases=[Collections.Generic.List[object]]::new()
    try{
    $workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $ReconstructionReceipt).Path
    $schema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\prepared-publication-reconstruction-v1.schema.json'
    $inputSnapshot=Open-ReconstructionProtocolSnapshot $input '' "'$input'";$leases.Add($inputSnapshot)|Out-Null
    $validatedInputBytes=$inputSnapshot.bytes
    $validatedInputHash=$inputSnapshot.sha256
    $doc=$inputSnapshot.document
    if(-not(Test-Json -Json ($doc|ConvertTo-Json -Depth 64 -Compress) -SchemaFile $schema)){throw 'Prepared-publication reconstruction receipt does not satisfy its schema.'}
    $statePath=Join-Path $workspace 'workspace.state.json';$state=Read-MorphospaceProtocolJson $statePath
    $unitRelative="iteration-units/$UnitId.json";$unit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf)
    if([string]$unit.status-cne'accepted'-or[string]$doc.project_id-cne[string]$state.project_id-or[string]$doc.bundle_id-cne[string]$state.pending_push_bundle.bundle_id){throw 'Prepared-publication reconstruction project, accepted unit, or pending bundle mismatch.'}
    $requestUnits=@([string]$UnitId)
    $documentUnits=@($doc.unit_ids|ForEach-Object{[string]$_})
    $pendingUnits=@($state.pending_push_bundle.unit_ids|ForEach-Object{[string]$_})
    if(($documentUnits-join'|')-cne($requestUnits-join'|')-or($pendingUnits-join'|')-cne($requestUnits-join'|')){
        throw 'Prepared-publication reconstruction unit_ids must exactly equal the requested accepted unit and pending bundle.'
    }
    Assert-ReconstructionCanonicalBinding $state.pending_push_bundle $doc.pending_bundle 'pending bundle'
    $blockers=@($state.blockers|Where-Object{[string]$_.blocker_id-ceq[string]$doc.stale_blocker.value.blocker_id})
    if($blockers.Count-ne1){throw 'Prepared-publication reconstruction exact stale blocker is absent.'};Assert-ReconstructionCanonicalBinding $blockers[0] $doc.stale_blocker 'stale blocker'
    $planSnapshot=Get-ReconstructionBindingSnapshot $workspace $doc.prepared_plan.container $bindingCache $leases;$planPath=$planSnapshot.path;$owner=$planSnapshot.document;$plan=$owner.push_plan
    $planSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\legacy-embedded-push-bundle-plan-v1.schema.json'
    if($null-eq$plan-or-not(Test-Json -Json ($plan|ConvertTo-Json -Depth 32) -SchemaFile $planSchema)){throw 'Prepared-publication reconstruction prepared plan is malformed.'}
    $planUnits=@($plan.unit_ids|ForEach-Object{[string]$_})
    if([string]$owner.schema-cne'rusty.morphospace.workflow.work_unit_automation_receipt.v1'-or[string]$owner.action-cne'PreparePush'-or
       $owner.executed-ne$true-or[string]$owner.transition-cne'push-bundle-prepared'-or[string]$owner.event_id-cne[string]$doc.prepared_event.event_id-or
       [string]$owner.project_id-cne[string]$doc.project_id-or[string]$owner.unit_id-cne$UnitId-or
       [string]$plan.execution-cne'not-performed'-or$plan.force_push_allowed-ne$false-or[string]$plan.bundle_id-cne[string]$doc.bundle_id-or
       [string]$plan.project_id-cne[string]$doc.project_id-or($planUnits-join'|')-cne($requestUnits-join'|')){
        throw 'Prepared-publication reconstruction does not bind the original not-performed PreparePush owner/member and exact unit set.'
    }
    $preparedTransition=Get-ReconstructionTransitionBinding $workspace $doc.prepared_event 'prepared' ([string]$doc.project_id) $UnitId $bindingCache $leases
    if([string]$preparedTransition.intent.event.event_type-cne'commit'-or
       @($preparedTransition.intent.event.receipts).Count-ne1-or
       [string]$preparedTransition.intent.event.receipts[0]-cne[string]$doc.prepared_plan.container.path-or
       (Get-MorphospaceCanonicalJsonSha256 $preparedTransition.intent.target.state.document.pending_push_bundle)-cne[string]$doc.pending_bundle.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $preparedTransition.intent.target.unit.document)-cne(Get-MorphospaceCanonicalJsonSha256 $unit)){
        throw 'Prepared-publication reconstruction prepared event containers are not canonically linked to the plan, pending bundle, and accepted unit.'
    }
    $acceptedSnapshot=Get-ReconstructionBindingSnapshot $workspace $doc.accepted_unit $bindingCache $leases;$acceptedPath=$acceptedSnapshot.path;$accepted=$acceptedSnapshot.document
    if([IO.Path]::GetFullPath($acceptedPath)-cne[IO.Path]::GetFullPath((Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf))-or[string]$accepted.unit_id-cne$UnitId-or[string]$accepted.status-cne'accepted'-or(Get-MorphospaceCanonicalJsonSha256 $accepted)-cne(Get-MorphospaceCanonicalJsonSha256 $unit)){throw 'Prepared-publication reconstruction accepted-unit binding mismatch.'}
    $validationSnapshot=Get-ReconstructionBindingSnapshot $workspace $doc.validation_receipt $bindingCache $leases;$validationPath=$validationSnapshot.path
    $validationSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\validation-receipt.schema.json'
    if(-not(Test-Json -Json ($validationSnapshot.document|ConvertTo-Json -Depth 32 -Compress) -SchemaFile $validationSchema)){throw 'Prepared-publication reconstruction validation receipt does not satisfy the full validation schema.'}
    $validation=$validationSnapshot.document
    if([string]$validation.schema-cne'rusty.morphospace.workflow.validation_receipt.v1'-or[string]$validation.result-cne'pass'-or[string]$validation.unit_id-cne$UnitId){throw 'Prepared-publication reconstruction validation receipt is not the accepted passing evidence.'}
    $validationTransition=Get-ReconstructionTransitionBinding $workspace $doc.validation_event 'validation-pass' ([string]$doc.project_id) $UnitId $bindingCache $leases
    $acceptanceTransition=Get-ReconstructionTransitionBinding $workspace $doc.acceptance_event 'acceptance' ([string]$doc.project_id) $UnitId $bindingCache $leases
    if([string]$validationTransition.intent.event.event_type-cne'validation'-or-not(Test-ReconstructionExactReceiptVector $validationTransition.intent.event.receipts ([string]$doc.validation_receipt.path))-or[string]$validationTransition.intent.target.unit.document.unit_id-cne$UnitId){throw 'Prepared-publication reconstruction validation-pass event is not bound to the exact passing receipt and unit.'}
    if([string]$acceptanceTransition.intent.event.event_type-cne'state-transition'-or-not(Test-ReconstructionExactReceiptVector $acceptanceTransition.intent.event.receipts ([string]$doc.validation_receipt.path))-or[string]$acceptanceTransition.intent.target.unit.document.status-cne'accepted'-or(Get-MorphospaceCanonicalJsonSha256 $acceptanceTransition.intent.target.unit.document)-cne(Get-MorphospaceCanonicalJsonSha256 $accepted)-or[string]$acceptanceTransition.completion.unit_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $accepted)){throw 'Prepared-publication reconstruction acceptance event is not bound to the exact passing receipt and accepted unit bytes.'}
    $ledger=Get-ReconstructionEventLedger $workspace
    $ledgerTail=if($ledger.Count){[string]$ledger[-1].event_id}else{$null}
    if([string]$state.last_event_id-cne[string]$ledgerTail){
        throw 'Prepared-publication reconstruction workspace-state event tail does not match the authenticated event ledger.'
    }
    $validationSequence=Assert-ReconstructionLedgerEvent $ledger $validationTransition 'validation-pass'
    $acceptanceSequence=Assert-ReconstructionLedgerEvent $ledger $acceptanceTransition 'acceptance'
    $preparedSequence=Assert-ReconstructionLedgerEvent $ledger $preparedTransition 'prepared'
    if(-not($validationSequence-lt$acceptanceSequence-and$acceptanceSequence-lt$preparedSequence)){
        throw 'Prepared-publication reconstruction validation, acceptance, and preparation chronology is invalid.'
    }
    [void](Get-ReconstructionCompleteTransitionChain $workspace $doc $ledger $validationTransition $acceptanceTransition $preparedTransition $validationSequence $acceptanceSequence $preparedSequence ([string]$doc.project_id) $UnitId $bindingCache $leases)
    if($doc.conflicting_evidence.executed_push_receipt_present-ne$false-or$doc.conflicting_evidence.planned_accounting_present-ne$false-or$doc.conflicting_evidence.unplanned_closure_present-ne$false){throw 'Prepared-publication reconstruction is mutually exclusive with execution/accounting/unplanned closure.'}
    Assert-NoReconstructionConflict $workspace ([string]$doc.bundle_id) @([string]$doc.prepared_plan.container.path,[string]$doc.prepared_event.intent.path,[string]$doc.prepared_event.completion.path,[string]$doc.accepted_unit.path,[string]$doc.validation_receipt.path,[string]$doc.validation_event.intent.path,[string]$doc.validation_event.completion.path,[string]$doc.acceptance_event.intent.path,[string]$doc.acceptance_event.completion.path) $ledger
    $mapSnapshot=Open-ReconstructionProtocolSnapshot (Resolve-Path $RepoMapPath).Path ([string]$doc.repository_map_sha256) "'$RepoMapPath'";$leases.Add($mapSnapshot)|Out-Null
    $mapDoc=$mapSnapshot.document
    $mapSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\repository-map.schema.json'
    if(-not(Test-Json -Json ($mapDoc|ConvertTo-Json -Depth 32 -Compress) -SchemaFile $mapSchema)){throw 'Prepared-publication reconstruction repository map does not satisfy its full schema.'}
    $authority=Get-ReconstructionPlanAuthority $plan $mapDoc
    $legIds=@($doc.logical_legs|ForEach-Object{[string]$_.repo_id});$planIds=@($authority.logical_ids)
    $sortedLegIds=@($legIds|Sort-Object);$sortedPlanIds=@($planIds|Sort-Object)
    if(@($legIds|Sort-Object -Unique).Count-ne$legIds.Count-or($sortedLegIds-join'|')-cne($sortedPlanIds-join'|')){throw 'Prepared-publication reconstruction logical plan-leg coverage mismatch.'}
    $physicalIds=@($doc.physical_refs|ForEach-Object{[string]$_.physical_ref_id})
    if(@($physicalIds|Sort-Object -Unique).Count-ne$physicalIds.Count-or$doc.physical_refs.Count-ne$authority.groups.Count){throw 'Prepared-publication reconstruction physical refs are duplicated, split, merged, or unused.'}
    foreach($leg in @($doc.logical_legs)){
        $planned=@($plan.repositories|Where-Object{[string]$_.repo_id-ceq[string]$leg.repo_id})
        if($planned.Count-ne1-or[string]$planned[0].role-cne[string]$leg.role-or[string]$planned[0].commit-cne[string]$leg.prepared_revision){throw "Prepared-publication reconstruction logical leg mismatch for '$($leg.repo_id)'."}
        $physical=@($doc.physical_refs|Where-Object{@($_.logical_repo_ids)-contains[string]$leg.repo_id})
        if($physical.Count-ne1-or[string]$physical[0].physical_ref_id-cne[string]$leg.physical_ref_id-or[string]$physical[0].prepared_revision-cne[string]$leg.prepared_revision){throw "Prepared-publication reconstruction physical alias binding mismatch for '$($leg.repo_id)'."}
    }
    foreach($group in @($authority.groups)){
        $physical=@($doc.physical_refs|Where-Object{[string]$_.observation_repo_id-ceq[string]$group.observation_repo_id-and[string]$_.remote-ceq[string]$group.remote-and[string]$_.ref-ceq[string]$group.ref})
        if($physical.Count-ne1){throw 'Prepared-publication reconstruction physical refs do not canonically collapse by resolved repository, intended remote, and intended merge ref.'}
        $declaredIds=@($physical[0].logical_repo_ids|ForEach-Object{[string]$_}|Sort-Object)
        $expectedIds=@($group.logical_repo_ids|Sort-Object)
        if(($declaredIds-join'|')-cne($expectedIds-join'|')-or[string]$physical[0].prepared_revision-cne[string]$group.prepared_revision-or[string]$physical[0].branch-cne[string]$group.branch-or[string]$physical[0].upstream-cne[string]$group.upstream){throw 'Prepared-publication reconstruction physical ref authority differs from the immutable plan and repository map.'}
    }
    $workspacePhysical=Get-ReconstructionPhysicalDirectory $workspace
    $workspaceComponents=[Collections.Generic.List[object]]::new()
    $workspaceComponents.Add([pscustomobject]@{name='workspace';canonical=[string]$workspacePhysical.canonical_path;identity=[string]$workspacePhysical.identity})|Out-Null
    $workspaceGitRootResult=Invoke-ReconstructionGit $workspace @('rev-parse','--show-toplevel') -AllowFailure
    if($workspaceGitRootResult.code-eq0){
        $workspaceGitRoot=Get-ReconstructionPhysicalDirectory $workspaceGitRootResult.text
        $workspaceGitDir=Get-ReconstructionPhysicalDirectory (Resolve-ReconstructionGitPath $workspace (Invoke-ReconstructionGit $workspace @('rev-parse','--absolute-git-dir')).text)
        $workspaceCommonDir=Get-ReconstructionPhysicalDirectory (Resolve-ReconstructionGitPath $workspace (Invoke-ReconstructionGit $workspace @('rev-parse','--git-common-dir')).text)
        $workspaceObjectDir=Get-ReconstructionPhysicalDirectory (Resolve-ReconstructionGitPath $workspace (Invoke-ReconstructionGit $workspace @('rev-parse','--git-path','objects')).text)
        foreach($component in @($workspaceGitRoot,$workspaceGitDir,$workspaceCommonDir,$workspaceObjectDir)){
            if(-not@($workspaceComponents|Where-Object{$_.identity-ceq$component.identity}).Count){
                $workspaceComponents.Add([pscustomobject]@{name='workspace-git';canonical=[string]$component.canonical_path;identity=[string]$component.identity})|Out-Null
            }
        }
    }
    $readbackFirst=@{};$readbackComponents=[Collections.Generic.List[object]]::new()
    foreach($physical in @($doc.physical_refs)){
        if(-not$authority.entries.ContainsKey([string]$physical.observation_repo_id)){throw "Prepared-publication reconstruction physical observation repository is not mapped."}
        $repo=[IO.Path]::GetFullPath([string]$authority.entries[[string]$physical.observation_repo_id].path)
        $observation=Get-ReconstructionReadbackObservation $repo ([string]$physical.remote) ([string]$physical.ref)
        if($observation.root-cne$repo){throw 'Prepared-publication reconstruction repository map must name the canonical readback worktree root.'}
        if($observation.git_dir-cne$observation.common_dir-or$observation.git_dir_physical_id-cne$observation.common_dir_physical_id-or$observation.git_dir_canonical-cne$observation.common_dir_canonical){throw 'Prepared-publication reconstruction rejects linked worktrees and shared Git ownership.'}
        if([string]$physical.remote_fetch_identity-cne[string]$observation.remote_fetch_identity-or
           [string]$physical.remote_push_identity-cne[string]$observation.remote_push_identity-or
           [string]$observation.remote_fetch_identity-cne[string]$observation.remote_push_identity){
            throw 'Prepared-publication reconstruction remote fetch/push identity differs from retained authority or uses a split endpoint.'
        }
        $components=@(
            [pscustomobject]@{name='root';canonical=[string]$observation.root_canonical;identity=[string]$observation.root_physical_id},
            [pscustomobject]@{name='git';canonical=[string]$observation.git_dir_canonical;identity=[string]$observation.git_dir_physical_id},
            [pscustomobject]@{name='common';canonical=[string]$observation.common_dir_canonical;identity=[string]$observation.common_dir_physical_id},
            [pscustomobject]@{name='objects';canonical=[string]$observation.object_dir_canonical;identity=[string]$observation.object_dir_physical_id}
        )
        foreach($component in $components){
            foreach($workspaceComponent in $workspaceComponents){
                if($component.identity-ceq$workspaceComponent.identity-or(Test-ReconstructionPathOverlap $component.canonical $workspaceComponent.canonical)){
                    throw 'Prepared-publication reconstruction readback repositories and Git storage must be physically isolated from the active workflow workspace and its repository.'
                }
            }
            foreach($existingComponent in $readbackComponents){
                if($component.identity-ceq$existingComponent.identity-or(Test-ReconstructionPathOverlap $component.canonical $existingComponent.canonical)){
                    throw 'Prepared-publication reconstruction physical observations overlap or alias another readback repository.'
                }
            }
        }
        foreach($component in $components){$readbackComponents.Add($component)|Out-Null}
        if(-not$observation.clean){throw 'Prepared-publication reconstruction requires a clean isolated readback repository.'}
        if($observation.branch-cne[string]$physical.branch-or$observation.upstream-cne[string]$physical.upstream){throw 'Prepared-publication reconstruction live branch/upstream differs from plan authority.'}
        [void](Invoke-ReconstructionGit $repo @('remote','get-url',[string]$physical.remote))
        if($observation.remote_tip-cne[string]$physical.remote_tip_revision){throw "Prepared-publication reconstruction remote tip changed before history validation."}
        $prepared=(Invoke-ReconstructionGit $repo @('rev-parse',"$([string]$physical.prepared_revision)^{commit}")).text
        $tip=(Invoke-ReconstructionGit $repo @('rev-parse',"$([string]$physical.remote_tip_revision)^{commit}")).text
        if($observation.head-cne$tip-or$observation.upstream_tip-cne$tip-or$observation.ahead-ne0-or$observation.behind-ne0){
            throw 'Prepared-publication reconstruction requires an exact synchronized isolated readback checkout.'
        }
        if((Invoke-ReconstructionGit $repo @('merge-base','--is-ancestor',$prepared,$tip) -AllowFailure).code-ne0){throw 'Prepared-publication reconstruction requires every distinct prepared revision to be reachable.'}
        if((Invoke-ReconstructionGit $repo @('show','-s','--format=%T',$prepared)).text-cne[string]$physical.prepared_tree-or(Invoke-ReconstructionGit $repo @('show','-s','--format=%T',$tip)).text-cne[string]$physical.remote_tip_tree){throw 'Prepared-publication reconstruction tree binding mismatch.'}
        Assert-ReconstructionHistory @($physical.history) @(Get-ReconstructionHistory $repo $prepared $tip) ([string]$physical.physical_ref_id)
        $readbackFirst[[string]$physical.physical_ref_id]=$observation
    }
    $events=$ledger;$sequence=if($events.Count){[int]$events[-1].sequence+1}else{1}
    $eventId=New-ReconstructionEventId $UnitId $sequence
    if(-not$Timestamp){$Timestamp=ConvertTo-MorphospaceUtcTimestamp ([DateTimeOffset]::UtcNow)}
    $eventTimestamp=ConvertFrom-ReconstructionStrictTimestamp $Timestamp 'requested timestamp'
    $Timestamp=ConvertTo-MorphospaceUtcTimestamp $eventTimestamp
    if($events.Count-and$eventTimestamp-lt(ConvertFrom-ReconstructionStrictTimestamp ([string]$events[-1].timestamp) 'current ledger tail timestamp')){
        throw 'Prepared-publication reconstruction timestamp precedes the current event-ledger tail.'
    }
    $relative=if($OutPath){[IO.Path]::GetRelativePath($workspace,[IO.Path]::GetFullPath($OutPath)).Replace('\','/')}else{"receipts/$([string]$doc.reconstruction_id).json"}
    if($relative-notmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'){throw 'Prepared-publication reconstruction output must be a portable top-level receipt path.'}
    $artifactTarget=Resolve-MorphospaceWorkspacePath $workspace $relative
    if($Execute-and([IO.Path]::GetFullPath($input)-ceq[IO.Path]::GetFullPath($artifactTarget)-or[IO.File]::Exists($artifactTarget))){throw 'Prepared-publication reconstruction requires a new transaction-owned output artifact distinct from its input.'}
    $hash=$validatedInputHash;$event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=$sequence;timestamp=$Timestamp;project_id=[string]$doc.project_id;unit_id=$UnitId;event_type='push';summary='Reconstructed current prepared-revision reachability and closed only stale bookkeeping without making execution, chronology, force-history, actor, timestamp, or historical-nonpublication claims.';receipts=@($relative)}
    $beforeCurrent=$state.current_unit
    $eventSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\iteration-event.schema.json'
    if(-not(Test-Json -Json ($event|ConvertTo-Json -Depth 16 -Compress) -SchemaFile $eventSchema)){throw 'Prepared-publication reconstruction would emit an invalid iteration event.'}
    $transactionId="$eventId-transition"
    if($transactionId.Length-gt192-or$transactionId-cnotmatch'^[a-z0-9][a-z0-9-]+$'){throw 'Prepared-publication reconstruction transaction identity is not portable.'}
    $result=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=[string]$doc.project_id;unit_id=$UnitId;action='ReconcilePreparedPublication';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='prepared-publication-reconstructed';status_before=[string]$unit.status;status_after=[string]$unit.status;current_unit_before=$beforeCurrent;current_unit_after=$state.current_unit;preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[pscustomobject][ordered]@{path=$relative;sha256=$hash};event_id=$(if($Execute){$eventId}else{$null})}
    $outSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\work-unit-automation-receipt-v2.schema.json'
    if(-not(Test-Json -Json ($result|ConvertTo-Json -Depth 32 -Compress) -SchemaFile $outSchema)){throw 'Prepared-publication reconstruction would emit an invalid automation receipt.'}
    if(-not$Execute){
        foreach($physical in @($doc.physical_refs)){
            $repo=[IO.Path]::GetFullPath([string]$authority.entries[[string]$physical.observation_repo_id].path)
            $second=Get-ReconstructionReadbackObservation $repo ([string]$physical.remote) ([string]$physical.ref)
            Assert-ReconstructionObservationEqual $readbackFirst[[string]$physical.physical_ref_id] $second ([string]$physical.physical_ref_id)
        }
    }
    if($Execute){
        if(-not$OutPath){throw 'Executed prepared-publication reconstruction requires OutPath.'}
        $boundaryLock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $workspace
        try{
            foreach($physical in @($doc.physical_refs)){
                $repo=[IO.Path]::GetFullPath([string]$authority.entries[[string]$physical.observation_repo_id].path)
                $second=Get-ReconstructionReadbackObservation $repo ([string]$physical.remote) ([string]$physical.ref)
                Assert-ReconstructionObservationEqual $readbackFirst[[string]$physical.physical_ref_id] $second ([string]$physical.physical_ref_id)
            }
            Assert-ReconstructionSnapshotStillCurrent $inputSnapshot 'input'
            Assert-ReconstructionSnapshotStillCurrent $mapSnapshot 'repository map'
            foreach($snapshot in $bindingCache.Values){Assert-ReconstructionSnapshotStillCurrent $snapshot "'$([IO.Path]::GetRelativePath($workspace,[string]$snapshot.path).Replace('\','/'))'"}
            $lockedState=Read-MorphospaceProtocolJson $statePath
            $lockedUnit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitRelative -RequireLeaf)
            if((Get-MorphospaceCanonicalJsonSha256 $lockedState)-cne(Get-MorphospaceCanonicalJsonSha256 $state)-or
               (Get-MorphospaceCanonicalJsonSha256 $lockedUnit)-cne(Get-MorphospaceCanonicalJsonSha256 $unit)){
                throw 'Prepared-publication reconstruction workspace state or accepted unit changed after validation.'
            }
            $state=$lockedState;$unit=$lockedUnit
            $lockedPreparedTransition=Get-ReconstructionTransitionBinding $workspace $doc.prepared_event 'prepared' ([string]$doc.project_id) $UnitId $bindingCache $leases
            $lockedValidationTransition=Get-ReconstructionTransitionBinding $workspace $doc.validation_event 'validation-pass' ([string]$doc.project_id) $UnitId $bindingCache $leases
            $lockedAcceptanceTransition=Get-ReconstructionTransitionBinding $workspace $doc.acceptance_event 'acceptance' ([string]$doc.project_id) $UnitId $bindingCache $leases
            $lockedLedger=Get-ReconstructionEventLedger $workspace
            $lockedTail=if($lockedLedger.Count){[string]$lockedLedger[-1].event_id}else{$null}
            if([string]$lockedTail-cne[string]$ledgerTail){throw 'Prepared-publication reconstruction event ledger changed after validation.'}
            if($lockedLedger.Count-and$eventTimestamp-lt(ConvertFrom-ReconstructionStrictTimestamp ([string]$lockedLedger[-1].timestamp) 'locked event-ledger tail timestamp')){
                throw 'Prepared-publication reconstruction timestamp precedes the locked event-ledger tail.'
            }
            $lockedValidationSequence=Assert-ReconstructionLedgerEvent $lockedLedger $lockedValidationTransition 'validation-pass'
            $lockedAcceptanceSequence=Assert-ReconstructionLedgerEvent $lockedLedger $lockedAcceptanceTransition 'acceptance'
            $lockedPreparedSequence=Assert-ReconstructionLedgerEvent $lockedLedger $lockedPreparedTransition 'prepared'
            [void](Get-ReconstructionCompleteTransitionChain $workspace $doc $lockedLedger $lockedValidationTransition $lockedAcceptanceTransition $lockedPreparedTransition $lockedValidationSequence $lockedAcceptanceSequence $lockedPreparedSequence ([string]$doc.project_id) $UnitId $bindingCache $leases)
            Assert-NoReconstructionConflict $workspace ([string]$doc.bundle_id) @([string]$doc.prepared_plan.container.path,[string]$doc.prepared_event.intent.path,[string]$doc.prepared_event.completion.path,[string]$doc.accepted_unit.path,[string]$doc.validation_receipt.path,[string]$doc.validation_event.intent.path,[string]$doc.validation_event.completion.path,[string]$doc.acceptance_event.intent.path,[string]$doc.acceptance_event.completion.path) $lockedLedger
            $preHash=Get-MorphospaceCanonicalJsonSha256 $state;$preTail=$lockedTail
            $state.pending_push_bundle=$null;$state.blockers=@($state.blockers|Where-Object{[string]$_.blocker_id-cne[string]$doc.stale_blocker.value.blocker_id});$state.last_event_id=$eventId
            Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId -StatePath 'workspace.state.json' -UnitPath $unitRelative -EventsPath 'iteration-events.jsonl' -TargetState $state -TargetUnit $unit -Event $event -ExpectedStateSha256 $preHash -ExpectedUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $unit) -ExpectedEventTailId $preTail -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($validatedInputBytes);path=$relative;sha256=$validatedInputHash}) -FaultAfter $FaultAfter|Out-Null
        }finally{Exit-MorphospaceWorkspaceMutex $boundaryLock}
    }
    $result
    }finally{
        for($index=$leases.Count-1;$index-ge0;$index--){if($null-ne$leases[$index].stream){$leases[$index].stream.Dispose()}}
    }
}
Export-ModuleMember -Function Invoke-MorphospacePreparedPublicationReconstruction
