Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceProtocolCommon.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceTransitionLedger.psm1") -Force

$preparedPushRetirementIsWindows=[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT
if($preparedPushRetirementIsWindows-and-not('RustyMorphospacePreparedPushRetirementFileIdentity'-as[type])){
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class RustyMorphospacePreparedPushRetirementFileIdentity
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
            if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + value.Substring(8);
            if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) return value.Substring(4);
            return value;
        }
    }
}
'@
}

function Invoke-PreparedPushGit {
    param([string]$Path, [string[]]$Arguments, [switch]$AllowFailure)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git --no-replace-objects -C $Path @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Prepared-push retirement Git observation failed in '$Path': git $($Arguments -join ' ')"
    }
    [pscustomobject]@{ code = $code; text = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim() }
}

function Resolve-PreparedPushGitPath {
    param([string]$Repo,[string]$Value)
    if([IO.Path]::IsPathFullyQualified($Value)){return [IO.Path]::GetFullPath($Value)}
    [IO.Path]::GetFullPath((Join-Path $Repo $Value))
}

function Get-PreparedPushPhysicalDirectory {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not[IO.Directory]::Exists($full)){throw "Prepared-push retirement physical directory is missing: $full"}
    Assert-MorphospaceNoReparseAncestor -Root ([IO.Path]::GetPathRoot($full)) -Candidate $full
    if($preparedPushRetirementIsWindows){
        $canonical=[IO.Path]::GetFullPath([RustyMorphospacePreparedPushRetirementFileIdentity]::GetFinalPath($full))
        $identity=[RustyMorphospacePreparedPushRetirementFileIdentity]::GetIdentity($full)
    }else{
        $canonical=((& realpath -- $full 2>$null)|Out-String).Trim()
        if($LASTEXITCODE-ne0-or-not$canonical){throw "Prepared-push retirement could not resolve physical directory path: $full"}
        $identity=((& stat -Lc '%d:%i' -- $canonical 2>$null)|Out-String).Trim()
        if($LASTEXITCODE-ne0-or$identity-cnotmatch'^[0-9]+:[0-9]+$'){throw "Prepared-push retirement could not query physical directory identity: $full"}
    }
    [pscustomobject][ordered]@{path=$full;canonical_path=$canonical;identity=$identity}
}

function Assert-PreparedPushNoGitEnvironmentOverride {
    foreach($entry in @(Get-ChildItem Env:|Where-Object{$_.Name-like'GIT_*'})){
        throw "Prepared-push retirement rejects Git environment override '$([string]$entry.Name)'."
    }
}

function Assert-PreparedPushSafeObjectGraph {
    param([string]$Root)
    Assert-PreparedPushNoGitEnvironmentOverride
    $gitDir=Resolve-PreparedPushGitPath $Root (Invoke-PreparedPushGit $Root @('rev-parse','--absolute-git-dir')).text
    $commonDir=Resolve-PreparedPushGitPath $Root (Invoke-PreparedPushGit $Root @('rev-parse','--git-common-dir')).text
    $objects=Resolve-PreparedPushGitPath $Root (Invoke-PreparedPushGit $Root @('rev-parse','--git-path','objects')).text
    $rootPhysical=Get-PreparedPushPhysicalDirectory $Root
    $gitPhysical=Get-PreparedPushPhysicalDirectory $gitDir
    $commonPhysical=Get-PreparedPushPhysicalDirectory $commonDir
    $objectsPhysical=Get-PreparedPushPhysicalDirectory $objects
    $expectedGitPhysical=Get-PreparedPushPhysicalDirectory (Join-Path $Root '.git')
    $expectedObjectsPhysical=Get-PreparedPushPhysicalDirectory (Join-Path $expectedGitPhysical.canonical_path 'objects')
    if($gitPhysical.identity-cne$expectedGitPhysical.identity-or
       $commonPhysical.identity-cne$expectedGitPhysical.identity-or
       $objectsPhysical.identity-cne$expectedObjectsPhysical.identity){
        throw "Prepared-push retirement requires repository-owned .git and object directories."
    }
    foreach($leaf in @('info\alternates','info\http-alternates')){
        if([IO.File]::Exists((Join-Path $objects $leaf))){throw "Prepared-push retirement rejects Git object alternates."}
    }
    if((Invoke-PreparedPushGit $Root @('for-each-ref','--format=%(refname)','refs/replace')).text){throw "Prepared-push retirement rejects Git replacement refs."}
    foreach($graftsPath in @((Join-Path $commonDir 'info\grafts'),(Join-Path $objects 'info\grafts'))){
        if([IO.File]::Exists($graftsPath)){throw "Prepared-push retirement rejects legacy Git grafts."}
    }
    if((Invoke-PreparedPushGit $Root @('rev-parse','--is-shallow-repository')).text-cne'false'){throw "Prepared-push retirement rejects shallow Git history."}
    [pscustomobject][ordered]@{
        root=$rootPhysical
        git_dir=$gitPhysical
        common_dir=$commonPhysical
        object_dir=$objectsPhysical
    }
}

function Get-PreparedPushRemoteIdentity {
    param([string]$Root,[string]$Remote,[switch]$Push)
    $arguments=@('remote','get-url');if($Push){$arguments+='--push'};$arguments+='--all';$arguments+=$Remote
    $lines=@((Invoke-PreparedPushGit $Root $arguments).text-split"`n"|Where-Object{$_})
    if($lines.Count-ne1){throw "Prepared-push retirement requires exactly one resolved $(if($Push){'push'}else{'fetch'}) URL for remote '$Remote'."}
    $value=[string]$lines[0]
    $descriptor=$null
    if([IO.Path]::IsPathFullyQualified($value)){
        $physical=Get-PreparedPushPhysicalDirectory $value
        $descriptor="file|$($physical.canonical_path)|$($physical.identity)"
    }else{
        $uri=$null
        if([Uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri)-and$uri.IsFile){
            $physical=Get-PreparedPushPhysicalDirectory $uri.LocalPath
            $descriptor="file|$($physical.canonical_path)|$($physical.identity)"
        }elseif($null-ne$uri){
            if($uri.UserInfo){throw "Prepared-push retirement rejects credential-bearing remote '$Remote'."}
            $descriptor="uri|$($uri.AbsoluteUri)"
        }elseif($value-match'^[^/:@\s]+@?[^/:\s]+:.+$'){
            $descriptor="scp|$value"
        }else{
            $physical=Get-PreparedPushPhysicalDirectory (Join-Path $Root $value)
            $descriptor="file|$($physical.canonical_path)|$($physical.identity)"
        }
    }
    Get-MorphospaceSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($descriptor))
}

function Open-PreparedPushProtocolSnapshot {
    param([string]$Path,[string]$ExpectedSha256='',[string]$Context='protocol document')
    $stream=$null
    try{
        $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($stream.Length-gt67108864){throw "Prepared-push retirement $Context exceeds the 64 MiB protocol bound."}
        $bytes=[byte[]]::new([int]$stream.Length);$read=0
        while($read-lt$bytes.Length){
            $count=$stream.Read($bytes,$read,$bytes.Length-$read)
            if($count-le0){throw "Prepared-push retirement encountered a short read for $Context."}
            $read+=$count
        }
        $sha256=Get-MorphospaceSha256Bytes -Bytes $bytes
        if($ExpectedSha256-and$sha256-cne$ExpectedSha256){throw "Prepared-push retirement evidence hash mismatch for $Context."}
        $document=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context $Context
        [pscustomobject][ordered]@{path=[IO.Path]::GetFullPath($Path);sha256=$sha256;bytes=$bytes;document=$document;stream=$stream}
    }catch{
        if($null-ne$stream){$stream.Dispose()}
        throw
    }
}

function Test-PreparedPushByteArrayEqual {
    param([byte[]]$First,[byte[]]$Second)
    if($First.Length-ne$Second.Length){return $false}
    for($index=0;$index-lt$First.Length;$index++){if($First[$index]-ne$Second[$index]){return $false}}
    $true
}

function Assert-PreparedPushSnapshotStillCurrent {
    param([object]$Snapshot,[string]$Context='protocol document')
    $stream=$null
    try{
        $stream=[IO.FileStream]::new([string]$Snapshot.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($stream.Length-ne$Snapshot.bytes.Length){throw "Prepared-push retirement $Context bytes changed after validation."}
        $current=[byte[]]::new([int]$stream.Length);$read=0
        while($read-lt$current.Length){
            $count=$stream.Read($current,$read,$current.Length-$read)
            if($count-le0){throw "Prepared-push retirement encountered a short admission read for $Context."}
            $read+=$count
        }
        if(-not(Test-PreparedPushByteArrayEqual $Snapshot.bytes $current)){throw "Prepared-push retirement $Context bytes changed after validation."}
    }finally{if($null-ne$stream){$stream.Dispose()}}
}

function Get-PreparedPushBindingSnapshot {
    param([string]$Workspace,[object]$Reference,[object]$Leases)
    $path=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath ([string]$Reference.path) -RequireLeaf
    $snapshot=Open-PreparedPushProtocolSnapshot $path ([string]$Reference.sha256) "'$([string]$Reference.path)'"
    $Leases.Add($snapshot)|Out-Null
    $snapshot
}

function New-PreparedPushPhysicalGroupKey {
    param([string]$PhysicalIdentity,[string]$Branch,[string]$Upstream)
    "$PhysicalIdentity|$Branch|$Upstream"
}

function Test-PreparedPushHasUnreachablePhysicalGroup {
    param([object[]]$Observations)
    $reachability=[Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::Ordinal)
    foreach($observation in @($Observations)){
        $key=[string]$observation.physical_key
        if(-not$key){throw "Prepared-push retirement physical observation key is absent."}
        $value=[bool]$observation.prepared_reachable
        if($reachability.ContainsKey($key)){
            if($reachability[$key]-ne$value){throw "Prepared-push retirement one physical group has inconsistent reachability."}
        }else{$reachability.Add($key,$value)}
    }
    @($reachability.Values|Where-Object{$_-eq$false}).Count-gt0
}

function Get-PreparedPushRepositoryObservation {
    param([object]$PlanRepository, [object]$MapEntry, [string[]]$AllowedPreparationPaths = @(),[switch]$SourceLike)
    $repoId = [string]$PlanRepository.repo_id
    $path = [IO.Path]::GetFullPath([string]$MapEntry.path)
    if (-not [IO.Directory]::Exists($path)) { throw "Prepared-push retirement repository '$repoId' is unavailable." }
    Assert-PreparedPushNoGitEnvironmentOverride
    if ((Invoke-PreparedPushGit $path @("rev-parse", "--is-inside-work-tree")).text -ne "true") {
        throw "Prepared-push retirement repository '$repoId' is not a Git worktree."
    }
    $root=[IO.Path]::GetFullPath((Invoke-PreparedPushGit $path @('rev-parse','--show-toplevel')).text)
    $mappedPhysical=Get-PreparedPushPhysicalDirectory $path
    $graph=Assert-PreparedPushSafeObjectGraph $root
    if($mappedPhysical.identity-cne$graph.root.identity){
        throw "Prepared-push retirement repository '$repoId' map entry is not the repository root."
    }
    $head = (Invoke-PreparedPushGit $path @("rev-parse", "HEAD")).text
    $branchResult = Invoke-PreparedPushGit $path @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
    if ($branchResult.code -ne 0) { throw "Prepared-push retirement repository '$repoId' is detached." }
    $branch = $branchResult.text
    $upstreamResult = Invoke-PreparedPushGit $path @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}") -AllowFailure
    if ($upstreamResult.code -ne 0) { throw "Prepared-push retirement repository '$repoId' has no upstream." }
    $upstream = $upstreamResult.text
    $status = (Invoke-PreparedPushGit $path @("status", "--porcelain=v1", "--untracked-files=all")).text
    if ($status) { throw "Prepared-push retirement repository '$repoId' is dirty." }
    $counts = (Invoke-PreparedPushGit $path @("rev-list", "--left-right", "--count", "HEAD...@{upstream}")).text -split "\s+"
    if ($counts.Count -ne 2) { throw "Prepared-push retirement repository '$repoId' has malformed divergence observations." }
    $ahead = [int]$counts[0]; $behind = [int]$counts[1]
    if ($behind -ne 0) { throw "Prepared-push retirement repository '$repoId' is behind or divergent." }
    if ($branch -cne [string]$PlanRepository.branch -or $upstream -cne [string]$PlanRepository.upstream) {
        throw "Prepared-push retirement repository '$repoId' branch/upstream does not match the immutable plan."
    }
    $prepared = (Invoke-PreparedPushGit $path @("rev-parse", "$([string]$PlanRepository.commit)^{commit}")).text
    $preparedToHead = Invoke-PreparedPushGit $path @("merge-base", "--is-ancestor", $prepared, $head) -AllowFailure
    if ($preparedToHead.code -ne 0) { throw "Prepared-push retirement repository '$repoId' current HEAD is not a descendant of its prepared revision." }
    $remoteName = (Invoke-PreparedPushGit $path @("config", "--get", "branch.$branch.remote")).text
    $mergeRef = (Invoke-PreparedPushGit $path @("config", "--get", "branch.$branch.merge")).text
    if (-not $remoteName -or $remoteName -eq "." -or $mergeRef -notmatch "^refs/heads/") {
        throw "Prepared-push retirement repository '$repoId' has no remotely readable branch upstream."
    }
    $remoteFetchIdentity=Get-PreparedPushRemoteIdentity $root $remoteName
    $remotePushIdentity=Get-PreparedPushRemoteIdentity $root $remoteName -Push
    if($remoteFetchIdentity-cne$remotePushIdentity){throw "Prepared-push retirement rejects split fetch/push endpoints for '$repoId'."}
    $remoteLookup = Invoke-PreparedPushGit $path @("ls-remote", "--exit-code", $remoteName, $mergeRef) -AllowFailure
    if ($remoteLookup.code -ne 0) { throw "Prepared-push retirement remote lookup failed for '$repoId'." }
    $remoteFields = $remoteLookup.text -split "\s+"
    if ($remoteFields.Count -lt 2 -or $remoteFields[0] -notmatch "^[0-9a-f]{40}$") {
        throw "Prepared-push retirement remote lookup was malformed for '$repoId'."
    }
    $remoteRevision = $remoteFields[0]
    $trackingRevision = (Invoke-PreparedPushGit $path @("rev-parse", "@{upstream}^{commit}")).text
    if ($remoteRevision -cne $trackingRevision) {
        throw "Prepared-push retirement repository '$repoId' has stale remote-tracking observations."
    }
    $reachable = Invoke-PreparedPushGit $path @("merge-base", "--is-ancestor", $prepared, $remoteRevision) -AllowFailure
    if ($reachable.code -notin @(0,1)) { throw "Prepared-push retirement reachability lookup failed for '$repoId'." }
    $preparedReachable = ($reachable.code -eq 0)
    if ($SourceLike -and $head -cne $prepared) {
        throw "Prepared-push retirement source repository '$repoId' advanced after preparation."
    }
    if (-not $preparedReachable) {
        if ($head -cne $prepared) {
            $changedPaths = @((Invoke-PreparedPushGit $path @("diff", "--name-only", "$prepared..$head")).text -split "`n" | Where-Object { $_ })
            $unexpected = @($changedPaths | Where-Object { $AllowedPreparationPaths -cnotcontains $_ })
            if ($unexpected.Count -or $changedPaths.Count -eq 0) {
                throw "Prepared-push retirement planning repository '$repoId' has an unrelated post-preparation suffix."
            }
        }
    }
    $result=[pscustomobject][ordered]@{
        repo_id = $repoId
        role = [string]$PlanRepository.role
        branch = $branch
        upstream = $upstream
        prepared_revision = $prepared
        local_head = $head
        remote_readback_revision = $remoteRevision
        worktree_clean = $true
        detached = $false
        ahead = $ahead
        behind = $behind
        diverged = $false
        prepared_reachable = $preparedReachable
        root_canonical = [string]$graph.root.canonical_path
        root_physical_id = [string]$graph.root.identity
        git_dir_canonical = [string]$graph.git_dir.canonical_path
        git_dir_physical_id = [string]$graph.git_dir.identity
        common_dir_canonical = [string]$graph.common_dir.canonical_path
        common_dir_physical_id = [string]$graph.common_dir.identity
        object_dir_canonical = [string]$graph.object_dir.canonical_path
        object_dir_physical_id = [string]$graph.object_dir.identity
        remote_fetch_identity = $remoteFetchIdentity
        remote_push_identity = $remotePushIdentity
        physical_key = "$([string]$graph.root.identity)|$remoteFetchIdentity|$remoteName|$mergeRef"
    }
    $result
}

function Assert-PreparedPushObservationEqual {
    param([object]$Declared, [object]$Observed)
    $names=@("repo_id","role","branch","upstream","prepared_revision","local_head","remote_readback_revision","worktree_clean","detached","ahead","behind","diverged","remote_fetch_identity","remote_push_identity")
    if($Declared.PSObject.Properties.Name-ccontains'root_physical_id'){
        $names+=@("prepared_reachable","root_canonical","root_physical_id","git_dir_canonical","git_dir_physical_id","common_dir_canonical","common_dir_physical_id","object_dir_canonical","object_dir_physical_id","physical_key")
    }
    foreach ($name in $names) {
        if ([string]$Declared.$name -cne [string]$Observed.$name) {
            throw "Prepared-push retirement stale or mismatched repository observation for '$($Observed.repo_id)' field '$name'."
        }
    }
}
function Get-PreparedPushBundleBindings {
    param([AllowNull()][object]$Node)
    if($null-eq$Node){return}
    if($Node-is[pscustomobject]){
        foreach($property in $Node.PSObject.Properties){
            if($property.Name-ceq'bundle_id'){[string]$property.Value}
            Get-PreparedPushBundleBindings $property.Value
        }
    }elseif($Node-is[System.Collections.IEnumerable]-and$Node-isnot[string]){
        foreach($item in $Node){Get-PreparedPushBundleBindings $item}
    }
}

function ConvertFrom-PreparedPushStrictTimestamp {
    param([Parameter(Mandatory)][string]$Value,[string]$Context='timestamp')
    if($Value-cnotmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$'){
        throw "Prepared-push retirement $Context is not a strict invariant ISO-8601 date-time."
    }
    try{return ConvertFrom-MorphospaceInvariantTimestamp -Value $Value}
    catch{throw "Prepared-push retirement $Context is not a valid invariant ISO-8601 date-time."}
}

function New-PreparedPushRetirementEventId {
    param([string]$UnitId,[int]$Sequence)
    $value="$UnitId-prepared-push-retired-$('{0:d4}' -f $Sequence)"
    if($value.Length-gt128-or$value-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){
        throw "Prepared-push retirement event identity is not portable."
    }
    $value
}

function Get-PreparedPushEventLedger {
    param([string]$WorkspaceRoot)
    $eventsPath=Join-Path $WorkspaceRoot "iteration-events.jsonl"
    $bytes=[IO.File]::ReadAllBytes($eventsPath)
    if($bytes.Length-gt67108864){throw "Prepared-push retirement event ledger exceeds the 64 MiB protocol bound."}
    if($bytes.Length-ge3-and$bytes[0]-eq0xef-and$bytes[1]-eq0xbb-and$bytes[2]-eq0xbf){throw "Prepared-push retirement event ledger must not contain a UTF-8 BOM."}
    if($bytes-contains0){throw "Prepared-push retirement event ledger contains NUL bytes."}
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)}catch{throw "Prepared-push retirement event ledger is not strict UTF-8."}
    $lines=$text-split"`n",0
    $events=@();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$previousTimestamp=$null
    for($index=0;$index-lt$lines.Count;$index++){
        $line=$lines[$index];if($line.EndsWith("`r")){$line=$line.Substring(0,$line.Length-1)}
        if(-not$line){
            if($index-eq$lines.Count-1-and$text.EndsWith("`n")){continue}
            throw "Prepared-push retirement event ledger contains a blank record at line $($index+1)."
        }
        try{$event=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line)) -Context "iteration-events.jsonl:$($index+1)"}catch{throw "Prepared-push retirement event ledger contains malformed JSON at line $($index+1): $($_.Exception.Message)"}
        $schemaPath=Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\iteration-event.schema.json"
        if(-not(Test-Json -Json ($event|ConvertTo-Json -Depth 16 -Compress) -SchemaFile $schemaPath)){throw "Prepared-push retirement event ledger entry fails its schema at line $($index+1)."}
        $eventId=[string]$event.event_id
        if(-not$seen.Add($eventId)){throw "Prepared-push retirement event ledger repeats event identity '$eventId'."}
        if([int]$event.sequence-ne$events.Count+1){throw "Prepared-push retirement event ledger sequence is not contiguous at line $($index+1)."}
        $timestamp=ConvertFrom-PreparedPushStrictTimestamp ([string]$event.timestamp) "event ledger timestamp at line $($index+1)"
        if($null-ne$previousTimestamp-and$timestamp-lt$previousTimestamp){throw "Prepared-push retirement event ledger chronology regresses at line $($index+1)."}
        $receiptSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($reference in @($event.receipts)){if(-not$receiptSet.Add([string]$reference)){throw "Prepared-push retirement event ledger repeats a receipt alias at line $($index+1)."}}
        $previousTimestamp=$timestamp;$events+=,$event
    }
    @($events)
}

function Test-PreparedPushConflictingEvidence {
    param([string]$WorkspaceRoot, [string]$BundleId, [string[]]$ExcludedPaths)
    $recognized = @(
        "rusty.morphospace.workflow.executed_push_receipt.v1",
        "rusty.morphospace.workflow.planned_publication_accounting.v1",
        "rusty.morphospace.workflow.published_prerequisite_suffix_reconciliation.v1",
        "rusty.morphospace.workflow.published_prerequisite_suffix_reconciliation.v2",
        "rusty.morphospace.workflow.planning_suffix_rewrite_recovery.v1",
        "rusty.morphospace.workflow.unplanned_publication_closure.v1",
        "rusty.morphospace.workflow.unplanned_publication_closure.v2",
        "rusty.morphospace.workflow.prepared_publication_reconstruction.v1",
        "rusty.morphospace.workflow.prepared_push_retirement.v1"
    )
    $consumingActions=@("RecordPublication","ReconcilePublication","ReconcilePlanningSuffixRewrite","ReconcilePublishedPrerequisiteSuffix","ReconcilePreparedPublication","RetirePreparedPush")
    $receiptsRoot = Join-Path $WorkspaceRoot "receipts"
    foreach ($file in @(Get-ChildItem -LiteralPath $receiptsRoot -File -Recurse -Filter *.json -ErrorAction Stop)) {
        $relative = [IO.Path]::GetRelativePath($WorkspaceRoot, $file.FullName).Replace("\","/")
        if ($ExcludedPaths -ccontains $relative) { continue }
        try { $document = Read-MorphospaceProtocolJson $file.FullName } catch {
            throw "Prepared-push retirement evidence search encountered malformed JSON at '$relative'."
        }
        $schema = [string]$document.schema
        $bundleValues = @(Get-PreparedPushBundleBindings $document)
        if ($bundleValues -ccontains $BundleId -and $recognized -ccontains $schema) {
            throw "Prepared-push retirement found workflow-recognized execution/publication evidence for bundle '$BundleId' at '$relative'."
        }
        if ($schema -like "rusty.morphospace.workflow.work_unit_automation_receipt.v*" -and
            $consumingActions -ccontains [string]$document.action -and
            $bundleValues -ccontains $BundleId) {
            throw "Prepared-push retirement found a consuming automation receipt for bundle '$BundleId' at '$relative'."
        }
    }
    foreach($event in @(Get-PreparedPushEventLedger $WorkspaceRoot)){
        if([string]$event.event_type-ceq"push"-and@($event.receipts).Count-eq0){throw "Prepared-push retirement rejects an unbound push event '$([string]$event.event_id)'."}
        foreach($reference in @($event.receipts)){
            try{
                $resolved=Resolve-MorphospaceWorkspacePath $WorkspaceRoot ([string]$reference) -RequireLeaf
                $owned=Read-MorphospaceProtocolJson $resolved
            }catch{
                throw "Prepared-push retirement could not authenticate event receipt '$([string]$reference)' for event '$([string]$event.event_id)'."
            }
            $bundleValues=@(Get-PreparedPushBundleBindings $owned)
            if(-not($bundleValues-ccontains$BundleId)){continue}
            $recognizedConflict=$recognized-ccontains[string]$owned.schema
            $automationConflict=[string]$owned.schema-like"rusty.morphospace.workflow.work_unit_automation_receipt.v*"-and$consumingActions-ccontains[string]$owned.action
            if([string]$event.event_type-ceq"push"-or$recognizedConflict-or$automationConflict){
                throw "Prepared-push retirement found bundle-bound execution/publication evidence in event '$([string]$event.event_id)'."
            }
        }
    }
}

function Assert-PreparedPushTransitionProvenance {
    param(
        [string]$Workspace,
        [string]$ProjectId,
        [string]$UnitId,
        [object]$Receipt,
        [object]$Unit,
        [object]$PlanContainerSnapshot,
        [object]$IntentSnapshot,
        [object]$CompletionSnapshot,
        [object[]]$Ledger
    )
    $intent=$IntentSnapshot.document
    $completion=$CompletionSnapshot.document
    $eventId=[string]$Receipt.prepared_event.event_id
    $transactionId="$eventId-transition"
    $intentRelative="receipts/transactions/$transactionId.intent.json"
    $completionRelative="receipts/transactions/$transactionId.completion.json"
    if([string]$Receipt.prepared_event.intent.path-cne$intentRelative-or[string]$Receipt.prepared_event.completion.path-cne$completionRelative){
        throw "Prepared-push retirement preparation transition paths are not canonical."
    }
    Assert-MorphospaceExactPropertySet $intent @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status') @() 'Prepared-push retirement preparation intent'
    Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() 'Prepared-push retirement preparation completion'
    foreach($referenceName in @('state','unit','events')){Assert-MorphospaceExactPropertySet $intent.$referenceName @('path') @() "Prepared-push retirement preparation intent $referenceName reference"}
    Assert-MorphospaceExactPropertySet $intent.pre @('state','unit') @() 'Prepared-push retirement preparation intent pre'
    Assert-MorphospaceExactPropertySet $intent.target @('state','unit') @() 'Prepared-push retirement preparation intent target'
    Assert-MorphospaceExactPropertySet $intent.expected @('state_sha256','unit_sha256','event_tail_id') @() 'Prepared-push retirement preparation intent expected'
    Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() 'Prepared-push retirement preparation completion intent reference'
    $artifacts=@($intent.artifacts)
    if($artifacts.Count-ne1){throw "Prepared-push retirement preparation intent must own exactly one immutable plan artifact."}
    $planArtifact=$artifacts[0]
    Assert-MorphospaceExactPropertySet $planArtifact @('path','sha256','bytes_base64') @() 'Prepared-push retirement preparation plan artifact'
    try{$planArtifactBytes=[Convert]::FromBase64String([string]$planArtifact.bytes_base64)}catch{throw "Prepared-push retirement preparation plan artifact payload is not valid base64."}
    if([string]$planArtifact.path-cne[string]$Receipt.prepared_plan.container.path-or
       [string]$planArtifact.sha256-cne[string]$PlanContainerSnapshot.sha256-or
       (Get-MorphospaceSha256Bytes -Bytes $planArtifactBytes)-cne[string]$PlanContainerSnapshot.sha256-or
       -not(Test-PreparedPushByteArrayEqual $planArtifactBytes $PlanContainerSnapshot.bytes)){
        throw "Prepared-push retirement plan owner bytes do not match the transaction-owned preparation artifact."
    }
    foreach($projection in @('state','unit')){
        Assert-MorphospaceExactPropertySet $intent.pre.$projection @('sha256') @() "Prepared-push retirement preparation pre-$projection"
        Assert-MorphospaceExactPropertySet $intent.target.$projection @('sha256','document') @() "Prepared-push retirement preparation target-$projection"
        if((Get-MorphospaceCanonicalJsonSha256 $intent.target.$projection.document)-cne[string]$intent.target.$projection.sha256-or
           [string]$intent.expected."${projection}_sha256"-cne[string]$intent.pre.$projection.sha256){
            throw "Prepared-push retirement preparation $projection transition hashes are inconsistent."
        }
    }
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or[string]$intent.status-cne'prepared'-or
       [string]$intent.transaction_id-cne$transactionId-or[string]$intent.state.path-cne'workspace.state.json'-or
       [string]$intent.unit.path-cne"iteration-units/$UnitId.json"-or[string]$intent.events.path-cne'iteration-events.jsonl'-or
       [string]$intent.event.event_id-cne$eventId-or[string]$intent.event.event_type-cne'commit'-or
       [string]$intent.event.project_id-cne$ProjectId-or[string]$intent.event.unit_id-cne$UnitId-or
       @($intent.event.receipts).Count-ne1-or[string]$intent.event.receipts[0]-cne[string]$Receipt.prepared_plan.container.path-or
       (Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document.pending_push_bundle)-cne[string]$Receipt.pending_bundle.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document)-cne(Get-MorphospaceCanonicalJsonSha256 $Unit)-or
       [string]$intent.target.state.document.last_event_id-cne$eventId){
        throw "Prepared-push retirement preparation intent is not canonically bound to the exact plan, pending bundle, accepted unit, and event."
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))
    if([string]$completion.schema-cne'rusty.morphospace.workflow.transition_ledger_completion.v1'-or
       [string]$completion.status-cne'committed'-or[string]$completion.transaction_id-cne$transactionId-or
       [string]$completion.intent.role-cne'transition-ledger-intent'-or[string]$completion.intent.path-cne$intentRelative-or
       [string]$completion.intent.schema-cne[string]$intent.schema-or[string]$completion.intent.sha256-cne[string]$IntentSnapshot.sha256-or
       [string]$completion.state_sha256-cne[string]$intent.target.state.sha256-or
       [string]$completion.unit_sha256-cne[string]$intent.target.unit.sha256-or[string]$completion.event_id-cne$eventId){
        throw "Prepared-push retirement preparation completion is not canonically bound to the exact intent and targets."
    }
    $matches=@($Ledger|Where-Object{[string]$_.event_id-ceq$eventId})
    if($matches.Count-ne1-or(Get-MorphospaceCanonicalJsonSha256 $matches[0])-cne(Get-MorphospaceCanonicalJsonSha256 $intent.event)){
        throw "Prepared-push retirement preparation event is absent, duplicated, or differs from the immutable event ledger."
    }
    $eventIndex=[int]$matches[0].sequence-1
    $expectedTail=if($eventIndex-gt0){[string]$Ledger[$eventIndex-1].event_id}else{$null}
    if($eventIndex-lt0-or$eventIndex-ge$Ledger.Count-or[string]$intent.expected.event_tail_id-cne[string]$expectedTail){
        throw "Prepared-push retirement preparation event has the wrong preceding event tail."
    }
}

function Invoke-MorphospacePreparedPushRetirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][string]$RepoMapPath,
        [Parameter(Mandatory=$true)][string]$RetirementReceipt,
        [string]$Timestamp = "",
        [string]$OutPath = "",
        [switch]$Execute
    )
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $receiptPath = (Resolve-Path -LiteralPath $RetirementReceipt).Path
    $leases=[Collections.Generic.List[object]]::new()
    try{
    $receiptRelative = $null
    if ($Execute) {
        if (-not $OutPath) { throw "Executed prepared-push retirement requires OutPath for the retained receipt." }
        $retainedPath = [IO.Path]::GetFullPath($OutPath)
        $workspacePrefix = $workspace.TrimEnd("\","/") + [IO.Path]::DirectorySeparatorChar
        if (-not $retainedPath.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Prepared-push retirement OutPath must stay inside the workspace."
        }
        $receiptRelative = [IO.Path]::GetRelativePath($workspace,$retainedPath).Replace("\","/")
        if ($receiptRelative -notmatch "^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$") {
            throw "Prepared-push retirement OutPath must be a portable top-level receipts path."
        }
        if ([IO.File]::Exists($retainedPath)) { throw "Prepared-push retirement OutPath already exists." }
        if($retainedPath-ceq[IO.Path]::GetFullPath($receiptPath)){throw "Prepared-push retirement output must be distinct from its input."}
    }
    $receiptSnapshot=Open-PreparedPushProtocolSnapshot $receiptPath '' 'retirement input';$leases.Add($receiptSnapshot)|Out-Null
    $receipt = $receiptSnapshot.document
    $schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\prepared-push-retirement-v1.schema.json"
    if (-not (Test-Json -Json ($receipt|ConvertTo-Json -Depth 32 -Compress) -SchemaFile $schemaPath)) {
        throw "Prepared-push retirement receipt does not satisfy its schema."
    }
    [void](ConvertFrom-PreparedPushStrictTimestamp ([string]$receipt.observed_at) 'observed_at')
    $statePath = Join-Path $workspace "workspace.state.json"
    $state = Read-MorphospaceProtocolJson $statePath
    $spec = Read-MorphospaceProtocolJson (Join-Path $workspace "project.spec.json")
    $unitPath = "iteration-units/$UnitId.json"
    $unit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    $events=@(Get-PreparedPushEventLedger $workspace)
    $ledgerTail=if($events.Count){[string]$events[-1].event_id}else{$null}
    if([string]$state.last_event_id-cne[string]$ledgerTail){throw "Prepared-push retirement workspace-state event tail does not match the authenticated event ledger."}
    $currentUnitBefore = $state.current_unit
    if ([string]$receipt.project_id -cne [string]$state.project_id -or [string]$receipt.project_id -cne [string]$spec.project_id) {
        throw "Prepared-push retirement project identity mismatch."
    }
    if ($null -eq $state.pending_push_bundle) { throw "Prepared-push retirement bundle was already consumed or is not pending." }
    if ([string]$state.pending_push_bundle.bundle_id -cne [string]$receipt.bundle_id) { throw "Prepared-push retirement bundle identity mismatch." }
    $pendingUnits = @($state.pending_push_bundle.unit_ids | ForEach-Object {[string]$_} | Sort-Object)
    $receiptUnits = @($receipt.unit_ids | ForEach-Object {[string]$_} | Sort-Object)
    if (($pendingUnits -join "`n") -cne ($receiptUnits -join "`n") -or $pendingUnits -notcontains $UnitId) {
        throw "Prepared-push retirement unit identities do not exactly match the pending bundle."
    }
    if((Get-MorphospaceCanonicalJsonSha256 $state.pending_push_bundle)-cne[string]$receipt.pending_bundle.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $receipt.pending_bundle.value)-cne[string]$receipt.pending_bundle.sha256){
        throw "Prepared-push retirement pending bundle canonical hash mismatch."
    }

    $planContainerSnapshot=Get-PreparedPushBindingSnapshot $workspace $receipt.prepared_plan.container $leases
    $planContainerPath=$planContainerSnapshot.path
    $planContainer = $planContainerSnapshot.document
    if ([string]$planContainer.schema -cne "rusty.morphospace.workflow.work_unit_automation_receipt.v1" -or
        [string]$planContainer.action -cne "PreparePush" -or -not $planContainer.executed -or
        [string]$planContainer.transition -cne "push-bundle-prepared" -or $null -eq $planContainer.push_plan) {
        throw "Prepared-push retirement plan owner is not an executed immutable PreparePush container."
    }
    $plan = $planContainer.push_plan
    $planSchemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\legacy-embedded-push-bundle-plan-v1.schema.json"
    if (-not (Test-Json -Json ($plan | ConvertTo-Json -Depth 32) -SchemaFile $planSchemaPath)) {
        throw "Prepared-push retirement retained historical embedded plan is malformed or outside the additive legacy compatibility contract."
    }
    if ([string]$plan.schema -cne "rusty.morphospace.workflow.push_bundle_plan.v1" -or
        [string]$plan.execution -cne "not-performed" -or $plan.force_push_allowed -ne $false) {
        throw "Prepared-push retirement plan does not preserve the non-executing/no-force boundary."
    }
    if ([string]$plan.bundle_id -cne [string]$receipt.bundle_id -or [string]$plan.project_id -cne [string]$receipt.project_id -or
        (@($plan.unit_ids | Sort-Object) -join "`n") -cne ($receiptUnits -join "`n")) {
        throw "Prepared-push retirement immutable plan identities mismatch."
    }
    if ([string]$planContainer.event_id -cne [string]$receipt.prepared_event.event_id) {
        throw "Prepared-push retirement preparation event identity mismatch."
    }
    $intentSnapshot=Get-PreparedPushBindingSnapshot $workspace $receipt.prepared_event.intent $leases
    $completionSnapshot=Get-PreparedPushBindingSnapshot $workspace $receipt.prepared_event.completion $leases
    $intentPath=$intentSnapshot.path
    $completionPath=$completionSnapshot.path
    $intent = $intentSnapshot.document
    $completion = $completionSnapshot.document
    $eventChecks = [ordered]@{
        intent_schema = ([string]$intent.schema -ceq "rusty.morphospace.workflow.transition_ledger_intent.v1")
        intent_status = ([string]$intent.status -ceq "prepared")
        intent_event = ([string]$intent.event.event_id -ceq [string]$receipt.prepared_event.event_id)
        event_project = ([string]$intent.event.project_id -ceq [string]$receipt.project_id)
        event_unit = ([string]$intent.event.unit_id -ceq $UnitId)
        event_type = ([string]$intent.event.event_type -ceq "commit")
        completion_schema = ([string]$completion.schema -ceq "rusty.morphospace.workflow.transition_ledger_completion.v1")
        completion_status = ([string]$completion.status -ceq "committed")
        transaction = ([string]$completion.transaction_id -ceq [string]$intent.transaction_id)
        completion_event = ([string]$completion.event_id -ceq [string]$receipt.prepared_event.event_id)
        intent_hash = ([string]$completion.intent.sha256 -ceq [string]$intentSnapshot.sha256)
    }
    $failedEventChecks = @($eventChecks.Keys | Where-Object { -not $eventChecks[$_] })
    if ($failedEventChecks.Count) {
        throw "Prepared-push retirement preparation event owner containers do not form the committed original event: $($failedEventChecks -join ', ')."
    }
    if (@($intent.event.receipts) -notcontains [string]$receipt.prepared_plan.container.path) {
        throw "Prepared-push retirement preparation event does not link to the exact plan owner container."
    }
    Assert-PreparedPushTransitionProvenance $workspace ([string]$receipt.project_id) $UnitId $receipt $unit $planContainerSnapshot $intentSnapshot $completionSnapshot $events

    $repoMapSnapshot=Open-PreparedPushProtocolSnapshot (Resolve-Path -LiteralPath $RepoMapPath).Path ([string]$receipt.repository_map_sha256) 'repository map';$leases.Add($repoMapSnapshot)|Out-Null
    $repoMap = $repoMapSnapshot.document
    $repoMapSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\repository-map.schema.json'
    if ([string]$repoMap.schema -cne "rusty.morphospace.workflow.repository_map.v1"-or
        -not(Test-Json -Json ($repoMap|ConvertTo-Json -Depth 32 -Compress) -SchemaFile $repoMapSchema)) { throw "Prepared-push retirement repository map schema mismatch." }
    $map = @{}; foreach ($entry in @($repoMap.repositories)) {
        if ($map.ContainsKey([string]$entry.repo_id)) { throw "Prepared-push retirement repository map repeats an identity." }
        $map[[string]$entry.repo_id] = $entry
    }
    $planIds = @($plan.repositories | ForEach-Object {[string]$_.repo_id} | Sort-Object)
    $pendingIds = @($state.pending_push_bundle.repo_ids | ForEach-Object {[string]$_} | Sort-Object)
    $receiptIds = @($receipt.repositories | ForEach-Object {[string]$_.repo_id} | Sort-Object)
    if (($planIds -join "`n") -cne ($pendingIds -join "`n") -or ($planIds -join "`n") -cne ($receiptIds -join "`n") -or
        @($planIds | Select-Object -Unique).Count -ne $planIds.Count) {
        throw "Prepared-push retirement repository coverage is incomplete or mismatched."
    }
    $physicalGroups=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $groupKeyByRepoId=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $physicalByRepoId=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($planRepo in @($plan.repositories)){
        if([string]$planRepo.role -notin @('application','adapter','source','planning')){throw "Prepared-push retirement plan has unsupported legacy role."}
        $repoId=[string]$planRepo.repo_id
        if(-not$map.ContainsKey($repoId)){throw "Prepared-push retirement repository '$repoId' is not mapped."}
        $physical=Get-PreparedPushPhysicalDirectory ([string]$map[$repoId].path)
        $key=New-PreparedPushPhysicalGroupKey ([string]$physical.identity) ([string]$planRepo.branch) ([string]$planRepo.upstream)
        if(-not$physicalGroups.ContainsKey($key)){$physicalGroups[$key]=@()}
        $physicalGroups[$key]=@($physicalGroups[$key])+$planRepo
        $groupKeyByRepoId.Add($repoId,$key)
        $physicalByRepoId.Add($repoId,$physical)
    }
    $first = @(); foreach ($planRepo in @($plan.repositories)) {
        $repoId = [string]$planRepo.repo_id
        if (-not $map.ContainsKey($repoId)) { throw "Prepared-push retirement repository '$repoId' is not mapped." }
        $allowedPreparationPaths = @()
        if ([string]$planRepo.role -eq "planning") {
            $repoRoot = [IO.Path]::GetFullPath([string]$map[$repoId].path)
            foreach ($relative in @(
                [string]$receipt.prepared_plan.container.path,
                [string]$receipt.prepared_event.intent.path,
                [string]$receipt.prepared_event.completion.path,
                "workspace.state.json", "iteration-events.jsonl"
            )) {
                $absolute = Resolve-MorphospaceWorkspacePath $workspace $relative
                $allowedPreparationPaths += [IO.Path]::GetRelativePath($repoRoot, $absolute).Replace("\","/")
            }
        }
        $groupKey=$groupKeyByRepoId[$repoId]
        $aliases=@($physicalGroups[$groupKey]);$sourceLike=@($aliases|Where-Object{[string]$_.role-ne'planning'}).Count-gt0
        if(@($aliases|ForEach-Object{[string]$_.commit}|Sort-Object -Unique).Count-ne1){throw "Prepared-push retirement alias revision mismatch."}
        $existing=@($first|Where-Object{
            [string]$_.root_physical_id-ceq[string]$physicalByRepoId[$repoId].identity-and
            [string]$_.branch-ceq[string]$planRepo.branch-and
            [string]$_.upstream-ceq[string]$planRepo.upstream
        })
        $observed=if($existing.Count){$clone=$existing[0].psobject.Copy();$clone.repo_id=$repoId;$clone.role=[string]$planRepo.role;$clone}else{Get-PreparedPushRepositoryObservation $planRepo $map[$repoId] $allowedPreparationPaths -SourceLike:$sourceLike}
        $declared = @($receipt.repositories | Where-Object {[string]$_.repo_id -eq $repoId})
        if ($declared.Count -ne 1) { throw "Prepared-push retirement repository '$repoId' is not declared exactly once." }
        Assert-PreparedPushObservationEqual $declared[0] $observed
        $first += $observed
    }
    if(-not(Test-PreparedPushHasUnreachablePhysicalGroup $first)){
        throw "Prepared-push retirement requires at least one distinct prepared revision that is not remotely reachable; use prepared-publication reconstruction."
    }
    Test-PreparedPushConflictingEvidence $workspace ([string]$receipt.bundle_id) @(
        [string]$receipt.prepared_plan.container.path,
        [string]$receipt.prepared_event.intent.path, [string]$receipt.prepared_event.completion.path
    )
    if(-not$Execute){foreach ($planRepo in @($plan.repositories)) {
        $allowedPreparationPaths = @()
        if ([string]$planRepo.role -eq "planning") {
            $repoRoot = [IO.Path]::GetFullPath([string]$map[[string]$planRepo.repo_id].path)
            foreach ($relative in @([string]$receipt.prepared_plan.container.path,[string]$receipt.prepared_event.intent.path,[string]$receipt.prepared_event.completion.path,"workspace.state.json","iteration-events.jsonl")) {
                $allowedPreparationPaths += [IO.Path]::GetRelativePath($repoRoot,(Resolve-MorphospaceWorkspacePath $workspace $relative)).Replace("\","/")
            }
        }
        $aliases=@($physicalGroups[$groupKeyByRepoId[[string]$planRepo.repo_id]])
        $sourceLike=@($aliases|ForEach-Object{$_}|Where-Object{[string]$_.role-ne'planning'}).Count-gt0
        $second = Get-PreparedPushRepositoryObservation $planRepo $map[[string]$planRepo.repo_id] $allowedPreparationPaths -SourceLike:$sourceLike
        Assert-PreparedPushObservationEqual (@($first | Where-Object repo_id -eq ([string]$planRepo.repo_id))[0]) $second
    }}

    $blockerId = [string]$receipt.stale_blocker.value.blocker_id
    $mutationBlockerId = if($null-eq$receipt.mutation.blocker_id){$null}else{[string]$receipt.mutation.blocker_id}
    $blockers=@($state.blockers|Where-Object{[string]$_.blocker_id-ceq$blockerId})
    if($blockers.Count-ne1-or(Get-MorphospaceCanonicalJsonSha256 $blockers[0])-cne[string]$receipt.stale_blocker.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $receipt.stale_blocker.value)-cne[string]$receipt.stale_blocker.sha256){throw "Prepared-push retirement stale blocker canonical hash mismatch."}
    if($null-ne$mutationBlockerId-and$mutationBlockerId-cne$blockerId){throw "Prepared-push retirement blocker identity mismatch."}
    $receiptHash = [string]$receiptSnapshot.sha256
    $sequence = if ($events.Count) { [int]$events[-1].sequence + 1 } else { 1 }
    $eventId = New-PreparedPushRetirementEventId $UnitId $sequence
    if (-not $Timestamp) { $Timestamp = ConvertTo-MorphospaceUtcTimestamp ([DateTimeOffset]::UtcNow) }
    $eventTimestamp=ConvertFrom-PreparedPushStrictTimestamp $Timestamp "requested timestamp"
    $Timestamp=ConvertTo-MorphospaceUtcTimestamp $eventTimestamp
    if($events.Count-and$eventTimestamp-lt(ConvertFrom-PreparedPushStrictTimestamp ([string]$events[-1].timestamp) "current event-ledger tail timestamp")){
        throw "Prepared-push retirement timestamp precedes the current event-ledger tail."
    }
    $eventReceiptRelative=if($receiptRelative){$receiptRelative}else{"receipts/$([string]$receipt.retirement_id).json"}
    $event = [pscustomobject][ordered]@{
        schema = "rusty.morphospace.workflow.iteration_event.v1"; event_id = $eventId; sequence = $sequence
        timestamp = $Timestamp; project_id = [string]$receipt.project_id; unit_id = $UnitId; event_type = "push"
        summary = "Retired one exact unexecuted prepared push bundle without asserting historical non-publication or mutating Git, remotes, validation, acceptance, or unit history."
        receipts = @($eventReceiptRelative)
    }
    $eventSchema=Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\iteration-event.schema.json"
    if(-not(Test-Json -Json ($event|ConvertTo-Json -Depth 16 -Compress) -SchemaFile $eventSchema)){throw "Prepared-push retirement would emit an invalid iteration event."}
    $transactionId="$eventId-transition"
    if($transactionId.Length-gt192-or$transactionId-cnotmatch'^[a-z0-9][a-z0-9-]+$'){throw "Prepared-push retirement transaction identity is not portable."}
    $result=[pscustomobject][ordered]@{
        schema = "rusty.morphospace.workflow.work_unit_automation_receipt.v2"
        project_id = [string]$receipt.project_id; unit_id = $UnitId; action = "RetirePreparedPush"
        timestamp = $Timestamp; executed = $Execute.IsPresent; transition = "prepared-push-retired"
        status_before = [string]$unit.status; status_after = [string]$unit.status
        current_unit_before = $currentUnitBefore; current_unit_after = $state.current_unit
        preservation = [pscustomobject][ordered]@{ git_mutation_performed=$false; device_mutation_performed=$false; remote_mutation_performed=$false }
        audit_receipt=[pscustomobject]@{path=$eventReceiptRelative;sha256=$receiptHash}
        event_id = if ($Execute) {$eventId} else {$null}
    }
    $outputSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\work-unit-automation-receipt-v2.schema.json'
    if(-not(Test-Json -Json ($result|ConvertTo-Json -Depth 32) -SchemaFile $outputSchema)){throw "Prepared-push retirement would emit an invalid automation receipt."}
    if ($Execute) {
        $boundaryLock=Enter-MorphospaceWorkspaceMutex -WorkspaceRoot $workspace
        try{
            foreach($snapshot in $leases){Assert-PreparedPushSnapshotStillCurrent $snapshot "'$([IO.Path]::GetFileName([string]$snapshot.path))'"}
            $lockedState=Read-MorphospaceProtocolJson $statePath
            $lockedSpec=Read-MorphospaceProtocolJson (Join-Path $workspace "project.spec.json")
            $lockedUnit=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
            if((Get-MorphospaceCanonicalJsonSha256 $lockedState)-cne(Get-MorphospaceCanonicalJsonSha256 $state)-or
               (Get-MorphospaceCanonicalJsonSha256 $lockedSpec)-cne(Get-MorphospaceCanonicalJsonSha256 $spec)-or
               (Get-MorphospaceCanonicalJsonSha256 $lockedUnit)-cne(Get-MorphospaceCanonicalJsonSha256 $unit)){
                throw "Prepared-push retirement workspace state, project specification, or unit changed after validation."
            }
            Test-PreparedPushConflictingEvidence $workspace ([string]$receipt.bundle_id) @(
                [string]$receipt.prepared_plan.container.path,
                [string]$receipt.prepared_event.intent.path,[string]$receipt.prepared_event.completion.path
            )
            $lockedEvents=@(Get-PreparedPushEventLedger $workspace)
            if($lockedEvents.Count-ne$events.Count){throw "Prepared-push retirement event ledger changed after validation."}
            for($index=0;$index-lt$events.Count;$index++){
                if((Get-MorphospaceCanonicalJsonSha256 $lockedEvents[$index])-cne(Get-MorphospaceCanonicalJsonSha256 $events[$index])){
                    throw "Prepared-push retirement event ledger changed after validation."
                }
            }
            if($lockedEvents.Count-and$eventTimestamp-lt(ConvertFrom-PreparedPushStrictTimestamp ([string]$lockedEvents[-1].timestamp) "locked event-ledger tail timestamp")){
                throw "Prepared-push retirement timestamp precedes the locked event-ledger tail."
            }
            $lockedTail=if($lockedEvents.Count){[string]$lockedEvents[-1].event_id}else{$null}
            if([string]$lockedState.last_event_id-cne[string]$lockedTail){throw "Prepared-push retirement locked workspace-state event tail does not match the authenticated event ledger."}
            if([IO.File]::Exists($retainedPath)){throw "Prepared-push retirement output appeared after validation."}
            foreach ($planRepo in @($plan.repositories)) {
                $repoId=[string]$planRepo.repo_id
                $allowedPreparationPaths = @()
                if ([string]$planRepo.role -eq "planning") {
                    $repoRoot = [IO.Path]::GetFullPath([string]$map[$repoId].path)
                    foreach ($relative in @([string]$receipt.prepared_plan.container.path,[string]$receipt.prepared_event.intent.path,[string]$receipt.prepared_event.completion.path,"workspace.state.json","iteration-events.jsonl")) {
                        $allowedPreparationPaths += [IO.Path]::GetRelativePath($repoRoot,(Resolve-MorphospaceWorkspacePath $workspace $relative)).Replace("\","/")
                    }
                }
                $aliases=@($physicalGroups[$groupKeyByRepoId[$repoId]])
                $sourceLike=@($aliases|Where-Object{[string]$_.role-ne'planning'}).Count-gt0
                $second=Get-PreparedPushRepositoryObservation $planRepo $map[$repoId] $allowedPreparationPaths -SourceLike:$sourceLike
                Assert-PreparedPushObservationEqual (@($first|Where-Object{[string]$_.repo_id-ceq$repoId})[0]) $second
            }
            $state=$lockedState;$unit=$lockedUnit
            $preStateHash=Get-MorphospaceCanonicalJsonSha256 $state
            $preTail=$lockedTail
            $state.pending_push_bundle = $null
            if ($null -ne $mutationBlockerId) { $state.blockers = @($state.blockers | Where-Object {[string]$_.blocker_id -cne $mutationBlockerId}) }
            $state.last_event_id = $eventId
            Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId $transactionId `
                -StatePath "workspace.state.json" -UnitPath $unitPath -EventsPath "iteration-events.jsonl" `
                -TargetState $state -TargetUnit $unit -Event $event -ExpectedStateSha256 $preStateHash `
                -ExpectedUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $unit) -ExpectedEventTailId $preTail `
                -Artifacts @([pscustomobject]@{bytes_base64=[Convert]::ToBase64String($receiptSnapshot.bytes);path=$receiptRelative;sha256=$receiptHash}) | Out-Null
        }finally{Exit-MorphospaceWorkspaceMutex $boundaryLock}
    }
    $result
    }finally{
        for($index=$leases.Count-1;$index-ge0;$index--){if($null-ne$leases[$index].stream){$leases[$index].stream.Dispose()}}
    }
}

Export-ModuleMember -Function Invoke-MorphospacePreparedPushRetirement
