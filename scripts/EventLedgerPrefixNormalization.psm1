$ErrorActionPreference = 'Stop'

$script:TransitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

$script:NormalizationMaximumLedgerBytes = 1048576
$script:NormalizationPrefix = [byte[]]@(0x0d,0x0a)

if($IsWindows-and-not('RustyMorphospace.ExactFileMutation'-as[type])){
    Add-Type -TypeDefinition @'
using Microsoft.Win32.SafeHandles;
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace RustyMorphospace {
    public static class ExactFileMutation {
        private const uint GenericRead = 0x80000000;
        private const uint Delete = 0x00010000;
        private const uint ShareRead = 0x00000001;
        private const uint OpenExisting = 3;
        private const int FileRenameInfo = 3;
        private const int FileDispositionInfo = 4;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string name, uint access, uint share, IntPtr security, uint creation,
            uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle handle, int informationClass, IntPtr information,
            uint bufferSize);

        private static SafeFileHandle OpenExact(string path) {
            var handle = CreateFileW(path, GenericRead | Delete, ShareRead,
                IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Could not lease exact file: " + path);
            }
            return handle;
        }

        private static string Hash(SafeFileHandle handle) {
            long length = RandomAccess.GetLength(handle);
            if (length > Int32.MaxValue) throw new IOException("Exact file exceeds supported length.");
            byte[] bytes = new byte[(int)length];
            int offset = 0;
            while (offset < bytes.Length) {
                int read = RandomAccess.Read(handle, bytes.AsSpan(offset), offset);
                if (read == 0) throw new EndOfStreamException("Exact leased file ended early.");
                offset += read;
            }
            return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        }

        private static void RequireHash(SafeFileHandle handle, string expected, string path) {
            string actual = Hash(handle);
            if (!String.Equals(actual, expected, StringComparison.Ordinal)) {
                throw new IOException("Exact leased file hash differs before mutation: " + path);
            }
        }

        public static void MoveExact(string source, string destination, string expectedSha256) {
            if (File.Exists(destination) || Directory.Exists(destination)) {
                throw new IOException("Exact move destination is occupied: " + destination);
            }
            using (SafeFileHandle handle = OpenExact(source)) {
                RequireHash(handle, expectedSha256, source);
                byte[] name = Encoding.Unicode.GetBytes(@"\\?\" + Path.GetFullPath(destination));
                int size = checked(22 + name.Length);
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try {
                    for (int index = 0; index < size; index++) Marshal.WriteByte(buffer, index, 0);
                    Marshal.WriteByte(buffer, 0, 0);
                    Marshal.WriteIntPtr(buffer, 8, IntPtr.Zero);
                    Marshal.WriteInt32(buffer, 16, name.Length);
                    Marshal.Copy(name, 0, IntPtr.Add(buffer, 20), name.Length);
                    if (!SetFileInformationByHandle(handle, FileRenameInfo, buffer, (uint)size)) {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Exact handle rename failed.");
                    }
                } finally {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }

        public static void DeleteExact(string path, string expectedSha256) {
            using (SafeFileHandle handle = OpenExact(path)) {
                RequireHash(handle, expectedSha256, path);
                IntPtr buffer = Marshal.AllocHGlobal(4);
                try {
                    Marshal.WriteInt32(buffer, 1);
                    if (!SetFileInformationByHandle(handle, FileDispositionInfo, buffer, 4)) {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Exact handle deletion failed.");
                    }
                } finally {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }
    }
}
'@
}

function Move-MorphospaceNormalizationExactFile {
    param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][string]$ExpectedSha256)
    if(-not$IsWindows){throw 'Executed event-ledger prefix normalization requires the Windows exact-handle file mutation primitive.'}
    [RustyMorphospace.ExactFileMutation]::MoveExact($Source,$Destination,$ExpectedSha256)
}

function Remove-MorphospaceNormalizationExactFile {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$ExpectedSha256)
    if(-not$IsWindows){throw 'Executed event-ledger prefix normalization requires the Windows exact-handle file mutation primitive.'}
    [RustyMorphospace.ExactFileMutation]::DeleteExact($Path,$ExpectedSha256)
}

function Test-MorphospaceTransitionLedgerBytes {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    & $script:TransitionLedgerModule {
        param([byte[]]$ProvidedBytes)
        $events=@(Read-MorphospaceLedgerEvents -EventsPath 'provided transition event ledger bytes' -ProvidedBytes $ProvidedBytes)
        [pscustomobject]@{
            length=[int64]$ProvidedBytes.LongLength
            sha256=Get-MorphospaceLedgerByteHash $ProvidedBytes
            events=$events
            tail_id=$(if($events.Count){[string]$events[-1].event_id}else{$null})
        }
    } $Bytes
}

function Get-MorphospaceTransitionLedgerEventLineBytes {
    param([Parameter(Mandatory=$true)][object]$Event)
    & $script:TransitionLedgerModule {param($Value) Get-MorphospaceLedgerEventLineBytes $Value} $Event
}

function Get-MorphospaceNormalizationSchemaPath {
    param([Parameter(Mandatory=$true)][string]$Name)
    Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\$Name"
}

function Get-MorphospaceNormalizationSha256 {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-MorphospaceNormalizationJsonBytes {
    param([Parameter(Mandatory=$true)][object]$Document)
    [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Document)+"`n")
}

function Copy-MorphospaceNormalizationDocument {
    param([Parameter(Mandatory=$true)][object]$Document,[string]$Context='normalization document')
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Document))) -Context $Context
}

function Test-MorphospaceNormalizationSchema {
    param([Parameter(Mandatory=$true)][object]$Document,[Parameter(Mandatory=$true)][string]$Schema,[Parameter(Mandatory=$true)][string]$Context)
    if(-not(Test-Json -Json ($Document|ConvertTo-Json -Depth 64 -Compress) -SchemaFile (Get-MorphospaceNormalizationSchemaPath $Schema))){
        throw "$Context fails its exact schema."
    }
}

function Invoke-MorphospaceNormalizationGit {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string[]]$Arguments)
    $prior=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try{$output=@(& git -C $Path @Arguments 2>&1);$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$prior}
    if($exit-ne0){throw "Event-ledger normalization Git observation failed: git $($Arguments -join ' ')"}
    return @($output|ForEach-Object{[string]$_})
}

function Invoke-MorphospaceNormalizationGitText {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string[]]$Arguments)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName='git'
    $start.WorkingDirectory=$Path
    $start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true)
    $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false,$true)
    foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    if(-not$process.Start()){throw 'Event-ledger normalization could not start Git observation.'}
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
    if($process.ExitCode-ne0){throw "Event-ledger normalization Git observation failed: git $($Arguments -join ' '): $errorText"}
    $output
}

function Get-MorphospaceNormalizationGitStatus {
    param([Parameter(Mandatory=$true)][string]$Root)
    $raw=Invoke-MorphospaceNormalizationGitText $Root @('status','--porcelain=v1','-z','--untracked-files=all')
    if(-not$raw){return @()}
    if($raw[$raw.Length-1]-ne[char]0){throw 'Event-ledger normalization Git status is not NUL terminated.'}
    $records=$raw.Split([char]0,[StringSplitOptions]::None)
    $entries=[Collections.Generic.List[object]]::new()
    for($index=0;$index-lt$records.Length-1;$index++){
        $record=$records[$index]
        if($record.Length-lt4-or$record[2]-cne' '){throw 'Malformed NUL-delimited Git status entry during event-ledger normalization.'}
        $x=[char]$record[0];$y=[char]$record[1]
        if($x-ceq'R'-or$y-ceq'R'-or$x-ceq'C'-or$y-ceq'C'){
            throw 'Event-ledger normalization rejects rename/copy Git status entries.'
        }
        $path=$record.Substring(3)
        if(-not$path-or$path.Contains("`r")-or$path.Contains("`n")-or$path.Contains([char]0)-or
           $path.StartsWith('/')-or$path-cmatch'(^|/)\.\.?(/|$)'){
            throw 'Event-ledger normalization rejects a malformed Git status pathname.'
        }
        $entries.Add([pscustomobject]@{xy="$x$y";path=$path})
    }
    @($entries)
}

function Get-MorphospaceNormalizationGitObservation {
    param([Parameter(Mandatory=$true)][string]$Workspace)
    $rootText=((Invoke-MorphospaceNormalizationGit $Workspace @('rev-parse','--show-toplevel'))-join"`n").Trim()
    $head=((Invoke-MorphospaceNormalizationGit $Workspace @('rev-parse','HEAD'))-join"`n").Trim()
    $branchLines=Invoke-MorphospaceNormalizationGit $Workspace @('symbolic-ref','--quiet','--short','HEAD')
    $branch=if($branchLines.Count){($branchLines-join"`n").Trim()}else{$null}
    $root=[IO.Path]::GetFullPath($rootText)
    $workspacePath=[IO.Path]::GetFullPath($Workspace)
    $prefix=$root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $pathComparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$workspacePath.StartsWith($prefix,$pathComparison)){throw 'Morphospace workspace is not below its observed Git root.'}
    $workspaceRelative=((Invoke-MorphospaceNormalizationGit $Workspace @('rev-parse','--show-prefix'))-join"`n").Trim().Replace('\','/').TrimEnd('/')
    $status=@(Get-MorphospaceNormalizationGitStatus $root)
    [pscustomobject]@{root=$root;head=$head;branch=$branch;workspace_relative=$workspaceRelative;status=@($status)}
}

function Assert-MorphospaceNormalizationGitClean {
    param([Parameter(Mandatory=$true)][object]$Observation)
    if(@($Observation.status).Count){throw 'Event-ledger prefix normalization requires an initially clean Git worktree.'}
}

function Assert-MorphospaceNormalizationOwnedDirt {
    param([Parameter(Mandatory=$true)][object]$Observation,[Parameter(Mandatory=$true)][object]$Paths)
    $allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($relative in @($Paths.state,$Paths.events,$Paths.receipt,$Paths.intent,$Paths.completion,$Paths.stage,$Paths.backup,$Paths.state_stage,$Paths.state_backup)){
        $joined=if($Observation.workspace_relative){"$($Observation.workspace_relative)/$relative"}else{$relative}
        [void]$allowed.Add($joined.Replace('\','/'))
    }
    foreach($entry in @($Observation.status)){
        $dirty=[string]$entry.path
        if(-not$allowed.Contains($dirty)){throw "Event-ledger normalization observed unrelated Git dirt: $dirty"}
    }
}

function Get-MorphospaceNormalizationPaths {
    param([Parameter(Mandatory=$true)][string]$NormalizationId)
    if($NormalizationId-cnotmatch'^[a-z0-9][a-z0-9-]{1,111}$'){throw 'NormalizationId must be a canonical 2-through-112-character workflow ID.'}
    $transactionId="$NormalizationId-normalization"
    [pscustomobject][ordered]@{
        project='project.spec.json'
        state='workspace.state.json'
        unit=$null
        events='iteration-events.jsonl'
        receipt="receipts/$NormalizationId.json"
        intent="receipts/transactions/$transactionId.intent.json"
        completion="receipts/transactions/$transactionId.completion.json"
        stage="iteration-events.jsonl.$transactionId.pending"
        backup="iteration-events.jsonl.$transactionId.before"
        state_stage="workspace.state.json.$transactionId.pending"
        state_backup="workspace.state.json.$transactionId.before"
        transaction_id=$transactionId
    }
}

function Get-MorphospaceNormalizationAbsolute {
    param([string]$Workspace,[string]$Relative,[switch]$RequireLeaf)
    Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath $Relative -RequireLeaf:$RequireLeaf
}

function Assert-MorphospaceNormalizationExpectedHash {
    param([string]$Name,[string]$Expected,[string]$Actual)
    if($Expected-cnotmatch'^[0-9a-f]{64}$'){throw "Expected $Name SHA-256 is not canonical lowercase hex."}
    if($Expected-cne$Actual){throw "Event-ledger prefix normalization failed expected $Name SHA-256 CAS."}
}

function Get-MorphospaceNormalizationCandidate {
    param(
        [Parameter(Mandatory=$true)][string]$Workspace,
        [Parameter(Mandatory=$true)][string]$NormalizationId,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][string]$ExpectedRepositoryHead,
        [Parameter(Mandatory=$true)][string]$ExpectedProjectSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedStateSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedUnitSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedEventsSha256,
        [Parameter(Mandatory=$true)][int64]$ExpectedEventsLength,
        [Parameter(Mandatory=$true)][string]$ExpectedEventTailId,
        [Parameter(Mandatory=$true)][string]$Timestamp
    )
    $paths=Get-MorphospaceNormalizationPaths $NormalizationId
    $paths.unit="iteration-units/$UnitId.json"
    $git=Get-MorphospaceNormalizationGitObservation $Workspace
    if($ExpectedRepositoryHead-cnotmatch'^[0-9a-f]{40}$'-or$git.head-cne$ExpectedRepositoryHead){throw 'Event-ledger prefix normalization failed expected repository-HEAD CAS.'}

    $projectPath=Get-MorphospaceNormalizationAbsolute $Workspace $paths.project -RequireLeaf
    $statePath=Get-MorphospaceNormalizationAbsolute $Workspace $paths.state -RequireLeaf
    $unitPath=Get-MorphospaceNormalizationAbsolute $Workspace $paths.unit -RequireLeaf
    $eventsPath=Get-MorphospaceNormalizationAbsolute $Workspace $paths.events -RequireLeaf
    $project=Read-MorphospaceProtocolJson $projectPath
    $state=Read-MorphospaceProtocolJson $statePath
    $unit=Read-MorphospaceProtocolJson $unitPath
    Test-MorphospaceNormalizationSchema $project 'project-spec-v2.schema.json' 'Event-ledger normalization project specification'
    Test-MorphospaceNormalizationSchema $state 'workspace-state-v2.schema.json' 'Event-ledger normalization workspace state'
    Test-MorphospaceNormalizationSchema $unit 'iteration-unit.schema.json' 'Event-ledger normalization current unit'
    if([string]$project.schema-cne'rusty.morphospace.workflow.project_spec.v2'-or[string]$state.schema-cne'rusty.morphospace.workflow.workspace_state.v2'){
        throw 'Event-ledger prefix normalization is available only to protocol-v2 project workspaces.'
    }
    if([string]$project.project_id-cne[string]$state.project_id-or[string]$project.project_id-cne[string]$unit.project_id){throw 'Event-ledger normalization project identities disagree.'}
    if([string]$state.current_unit-cne$UnitId-or[string]$unit.unit_id-cne$UnitId){throw 'Event-ledger normalization does not bind the exact current unit.'}

    $projectFileHash=Get-MorphospaceFileSha256 $projectPath
    $stateFileBytes=[IO.File]::ReadAllBytes($statePath)
    $stateFileHash=Get-MorphospaceNormalizationSha256 $stateFileBytes
    $unitFileHash=Get-MorphospaceFileSha256 $unitPath
    Assert-MorphospaceNormalizationExpectedHash 'project file' $ExpectedProjectSha256 $projectFileHash
    Assert-MorphospaceNormalizationExpectedHash 'state file' $ExpectedStateSha256 $stateFileHash
    Assert-MorphospaceNormalizationExpectedHash 'unit file' $ExpectedUnitSha256 $unitFileHash

    $before=[IO.File]::ReadAllBytes($eventsPath)
    if($before.LongLength-gt$script:NormalizationMaximumLedgerBytes){throw 'Event-ledger prefix normalization exceeds its one-MiB incident bound.'}
    if($ExpectedEventsLength-lt0-or$before.LongLength-ne$ExpectedEventsLength){throw 'Event-ledger prefix normalization failed expected event-ledger length CAS.'}
    Assert-MorphospaceNormalizationExpectedHash 'event-ledger' $ExpectedEventsSha256 (Get-MorphospaceNormalizationSha256 $before)
    if($before.Length-lt3-or$before[0]-ne0x0d-or$before[1]-ne0x0a){throw 'Event-ledger prefix normalization accepts only one exact leading CRLF record.'}
    $normalized=[byte[]]::new($before.Length-2)
    [Array]::Copy($before,2,$normalized,0,$normalized.Length)
    $snapshot=Test-MorphospaceTransitionLedgerBytes -Bytes $normalized
    if($snapshot.events.Count-lt1){throw 'Event-ledger prefix normalization requires at least one preserved event.'}
    if([string]$snapshot.tail_id-cne$ExpectedEventTailId-or[string]$state.last_event_id-cne$ExpectedEventTailId){throw 'Event-ledger prefix normalization failed expected event-tail CAS.'}
    foreach($priorEvent in @($snapshot.events)){
        if([string]$priorEvent.project_id-cne[string]$project.project_id){throw 'Event-ledger normalization found an event with the wrong project identity.'}
    }

    $timestampValue=Test-MorphospaceStrictUtcTimestamp $Timestamp
    $tailTimestamp=ConvertFrom-MorphospaceInvariantTimestamp ([string]$snapshot.events[-1].timestamp)
    if($timestampValue-lt$tailTimestamp){throw 'Event-ledger normalization timestamp precedes the preserved event tail.'}
    $event=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1'
        event_id=$NormalizationId
        sequence=[int]$snapshot.events[-1].sequence+1
        timestamp=$Timestamp
        project_id=[string]$project.project_id
        unit_id=$UnitId
        event_type='state-transition'
        summary='Removed one unauthorized leading CRLF record through the workflow-owned normalization transaction; prior event records and current-unit bytes remained unchanged.'
        receipts=@($paths.receipt)
    }
    $event=Copy-MorphospaceNormalizationDocument $event 'event-ledger normalization canonical event copy'
    Test-MorphospaceNormalizationSchema $event 'iteration-event.schema.json' 'Event-ledger normalization event'
    $eventLine=Get-MorphospaceTransitionLedgerEventLineBytes $event
    $after=[byte[]]::new($normalized.Length+$eventLine.Length)
    [Array]::Copy($normalized,0,$after,0,$normalized.Length)
    [Array]::Copy($eventLine,0,$after,$normalized.Length,$eventLine.Length)
    [void](Test-MorphospaceTransitionLedgerBytes -Bytes $after)

    $preState=Copy-MorphospaceNormalizationDocument $state 'event-ledger normalization pre-state copy'
    $targetState=Copy-MorphospaceNormalizationDocument $state 'event-ledger normalization target-state copy'
    $targetState.last_event_id=$NormalizationId
    $targetStateBytes=Get-MorphospaceNormalizationJsonBytes $targetState
    $receipt=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.event_ledger_prefix_normalization.v1'
        normalization_id=$NormalizationId
        created_at=$Timestamp
        project_id=[string]$project.project_id
        unit_id=$UnitId
        repository=[pscustomobject][ordered]@{head=$git.head;branch=$git.branch}
        ledger=[pscustomobject][ordered]@{
            path=$paths.events
            before_sha256=Get-MorphospaceNormalizationSha256 $before
            before_length=[int64]$before.LongLength
            removed_prefix_base64='DQo='
            normalized_prefix_sha256=Get-MorphospaceNormalizationSha256 $normalized
            normalized_prefix_length=[int64]$normalized.LongLength
            after_sha256=Get-MorphospaceNormalizationSha256 $after
            after_length=[int64]$after.LongLength
            preserved_event_count=[int]$snapshot.events.Count
            prior_tail_event_id=[string]$snapshot.tail_id
            prior_tail_sequence=[int]$snapshot.events[-1].sequence
        }
        state=[pscustomobject][ordered]@{
            path=$paths.state
            before_file_sha256=$stateFileHash
            before_document_sha256=Get-MorphospaceCanonicalJsonSha256 $state
            after_file_sha256=Get-MorphospaceNormalizationSha256 $targetStateBytes
            after_document_sha256=Get-MorphospaceCanonicalJsonSha256 $targetState
            changed_fields=@('last_event_id')
        }
        unit=[pscustomobject][ordered]@{
            path=$paths.unit
            file_sha256=$unitFileHash
            document_sha256=Get-MorphospaceCanonicalJsonSha256 $unit
            status=[string]$unit.status
        }
        event=[pscustomobject][ordered]@{event_id=$NormalizationId;sequence=[int]$event.sequence;receipt_path=$paths.receipt}
        guarantees=[pscustomobject][ordered]@{
            removed_exactly_one_leading_crlf_record=$true
            prior_event_bytes_unchanged=$true
            current_unit_bytes_unchanged=$true
            state_change_limited_to_last_event_id=$true
            git_mutation_performed=$false
            device_work=$false
        }
        status='normalized'
    }
    Test-MorphospaceNormalizationSchema $receipt 'event-ledger-prefix-normalization-v1.schema.json' 'Event-ledger normalization receipt'
    $receiptBytes=Get-MorphospaceNormalizationJsonBytes $receipt
    [pscustomobject]@{
        paths=$paths;git=$git;project=$project;state=$state;unit=$unit
        before=$before;normalized=$normalized;after=$after;event=$event
        pre_state=$preState;target_state=$targetState;target_state_bytes=$targetStateBytes
        receipt=$receipt;receipt_bytes=$receiptBytes
        state_file_bytes=$stateFileBytes
        project_file_sha256=$projectFileHash;state_file_sha256=$stateFileHash;unit_file_sha256=$unitFileHash
    }
}

function New-MorphospaceNormalizationIntent {
    param([Parameter(Mandatory=$true)][object]$Candidate)
    $c=$Candidate
    [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.event_ledger_prefix_normalization_intent.v1'
        transaction_id=$c.paths.transaction_id
        normalization_id=[string]$c.event.event_id
        created_at=[string]$c.event.timestamp
        paths=[pscustomobject][ordered]@{
            project=$c.paths.project;state=$c.paths.state;unit=$c.paths.unit;events=$c.paths.events
            receipt=$c.paths.receipt;completion=$c.paths.completion
        }
        repository=[pscustomobject][ordered]@{head=$c.git.head;branch=$c.git.branch}
        project=[pscustomobject][ordered]@{
            project_id=[string]$c.project.project_id
            file_sha256=$c.project_file_sha256
            document_sha256=Get-MorphospaceCanonicalJsonSha256 $c.project
        }
        pre=[pscustomobject][ordered]@{
            state_file_sha256=$c.state_file_sha256
            state_document_sha256=Get-MorphospaceCanonicalJsonSha256 $c.state
            unit_file_sha256=$c.unit_file_sha256
            unit_document_sha256=Get-MorphospaceCanonicalJsonSha256 $c.unit
            events_sha256=Get-MorphospaceNormalizationSha256 $c.before
            events_length=[int64]$c.before.LongLength
            event_tail_id=[string]$c.receipt.ledger.prior_tail_event_id
            event_tail_sequence=[int]$c.receipt.ledger.prior_tail_sequence
        }
        target=[pscustomobject][ordered]@{
            state_file_sha256=[string]$c.receipt.state.after_file_sha256
            state_document_sha256=[string]$c.receipt.state.after_document_sha256
            unit_file_sha256=$c.unit_file_sha256
            unit_document_sha256=Get-MorphospaceCanonicalJsonSha256 $c.unit
            normalized_prefix_sha256=[string]$c.receipt.ledger.normalized_prefix_sha256
            normalized_prefix_length=[int64]$c.receipt.ledger.normalized_prefix_length
            events_sha256=[string]$c.receipt.ledger.after_sha256
            events_length=[int64]$c.receipt.ledger.after_length
        }
        pre_events_base64=[Convert]::ToBase64String($c.before)
        pre_state_base64=[Convert]::ToBase64String($c.state_file_bytes)
        pre_state=$c.pre_state
        target_state=$c.target_state
        event=$c.event
        receipt=[pscustomobject][ordered]@{
            path=$c.paths.receipt
            sha256=Get-MorphospaceNormalizationSha256 $c.receipt_bytes
            document=$c.receipt
        }
        status='prepared'
    }
}

function Assert-MorphospaceNormalizationIntent {
    param([Parameter(Mandatory=$true)][object]$Intent,[Parameter(Mandatory=$true)][string]$NormalizationId)
    Test-MorphospaceNormalizationSchema $Intent 'event-ledger-prefix-normalization-intent-v1.schema.json' 'Event-ledger normalization intent'
    Test-MorphospaceNormalizationSchema $Intent.pre_state 'workspace-state-v2.schema.json' 'Event-ledger normalization intent pre-state'
    Test-MorphospaceNormalizationSchema $Intent.target_state 'workspace-state-v2.schema.json' 'Event-ledger normalization intent target-state'
    Test-MorphospaceNormalizationSchema $Intent.event 'iteration-event.schema.json' 'Event-ledger normalization intent event'
    Test-MorphospaceNormalizationSchema $Intent.receipt.document 'event-ledger-prefix-normalization-v1.schema.json' 'Event-ledger normalization intent receipt'
    $paths=Get-MorphospaceNormalizationPaths $NormalizationId
    $paths.unit=[string]$Intent.paths.unit
    $unitId=[IO.Path]::GetFileNameWithoutExtension([string]$Intent.paths.unit)
    if([string]$Intent.normalization_id-cne$NormalizationId-or[string]$Intent.transaction_id-cne$paths.transaction_id-or
       [string]$Intent.paths.project-cne$paths.project-or[string]$Intent.paths.state-cne$paths.state-or
       [string]$Intent.paths.events-cne$paths.events-or[string]$Intent.paths.receipt-cne$paths.receipt-or
       [string]$Intent.paths.completion-cne$paths.completion-or[string]$Intent.event.event_id-cne$NormalizationId-or
       [string]$Intent.status-cne'prepared'){
        throw 'Event-ledger normalization intent identity or path binding is invalid.'
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$Intent.created_at))
    try{$before=[Convert]::FromBase64String([string]$Intent.pre_events_base64)}catch{throw 'Event-ledger normalization intent preimage is not valid base64.'}
    if([Convert]::ToBase64String($before)-cne[string]$Intent.pre_events_base64){throw 'Event-ledger normalization intent preimage is not canonical base64.'}
    if($before.Length-ne[int64]$Intent.pre.events_length-or(Get-MorphospaceNormalizationSha256 $before)-cne[string]$Intent.pre.events_sha256-or
       $before.Length-lt3-or$before[0]-ne0x0d-or$before[1]-ne0x0a){throw 'Event-ledger normalization intent preimage binding is invalid.'}
    try{$beforeStateBytes=[Convert]::FromBase64String([string]$Intent.pre_state_base64)}catch{throw 'Event-ledger normalization intent state preimage is not valid base64.'}
    if([Convert]::ToBase64String($beforeStateBytes)-cne[string]$Intent.pre_state_base64-or
       (Get-MorphospaceNormalizationSha256 $beforeStateBytes)-cne[string]$Intent.pre.state_file_sha256-or
       (Get-MorphospaceCanonicalJsonSha256 (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $beforeStateBytes -Context 'event-ledger normalization intent state preimage'))-cne[string]$Intent.pre.state_document_sha256){
        throw 'Event-ledger normalization intent state preimage binding is invalid.'
    }
    $normalized=[byte[]]::new($before.Length-2);[Array]::Copy($before,2,$normalized,0,$normalized.Length)
    $prior=Test-MorphospaceTransitionLedgerBytes $normalized
    if($prior.events.Count-lt1-or[string]$prior.tail_id-cne[string]$Intent.pre.event_tail_id-or
       [int]$prior.events[-1].sequence-ne[int]$Intent.pre.event_tail_sequence-or
       (Get-MorphospaceNormalizationSha256 $normalized)-cne[string]$Intent.target.normalized_prefix_sha256-or
       $normalized.Length-ne[int64]$Intent.target.normalized_prefix_length){throw 'Event-ledger normalization intent preserved-prefix binding is invalid.'}
    foreach($priorEvent in @($prior.events)){if([string]$priorEvent.project_id-cne[string]$Intent.project.project_id){throw 'Event-ledger normalization intent contains a wrong-project preserved event.'}}
    if([int]$Intent.event.sequence-ne[int]$Intent.pre.event_tail_sequence+1-or[string]$Intent.event.project_id-cne[string]$Intent.project.project_id-or
       [string]$Intent.event.unit_id-cne$unitId-or[string]$Intent.event.timestamp-cne[string]$Intent.created_at-or
       [string]$Intent.event.event_type-cne'state-transition'-or@($Intent.event.receipts).Count-ne1-or[string]$Intent.event.receipts[0]-cne[string]$Intent.paths.receipt){
        throw 'Event-ledger normalization intent event binding is invalid.'
    }
    $line=Get-MorphospaceTransitionLedgerEventLineBytes $Intent.event
    $after=[byte[]]::new($normalized.Length+$line.Length);[Array]::Copy($normalized,0,$after,0,$normalized.Length);[Array]::Copy($line,0,$after,$normalized.Length,$line.Length)
    [void](Test-MorphospaceTransitionLedgerBytes $after)
    if($after.Length-ne[int64]$Intent.target.events_length-or(Get-MorphospaceNormalizationSha256 $after)-cne[string]$Intent.target.events_sha256-or
       [int64]$Intent.pre.events_length-ne[int64]$Intent.target.normalized_prefix_length+2-or
       [int64]$Intent.target.events_length-ne[int64]$Intent.target.normalized_prefix_length+[int64]$line.Length-or
       [string]$Intent.target.unit_file_sha256-cne[string]$Intent.pre.unit_file_sha256-or
       [string]$Intent.target.unit_document_sha256-cne[string]$Intent.pre.unit_document_sha256){
        throw 'Event-ledger normalization intent target ledger or unit binding is invalid.'
    }
    if((Get-MorphospaceCanonicalJsonSha256 $Intent.pre_state)-cne[string]$Intent.pre.state_document_sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $Intent.target_state)-cne[string]$Intent.target.state_document_sha256){throw 'Event-ledger normalization intent state hash binding is invalid.'}
    $expectedTarget=Copy-MorphospaceNormalizationDocument $Intent.pre_state 'event-ledger normalization intent state comparison'
    $expectedTarget.last_event_id=$NormalizationId
    if((Get-MorphospaceCanonicalJsonSha256 $expectedTarget)-cne(Get-MorphospaceCanonicalJsonSha256 $Intent.target_state)){throw 'Event-ledger normalization intent changes state beyond last_event_id.'}
    if([string]$Intent.pre_state.current_unit-cne$unitId-or[string]$Intent.target_state.current_unit-cne$unitId-or
        [string]$Intent.pre_state.project_id-cne[string]$Intent.project.project_id-or[string]$Intent.pre_state.last_event_id-cne[string]$Intent.pre.event_tail_id){
        throw 'Event-ledger normalization intent pre-state identity or tail binding is invalid.'
    }
    $targetStateBytes=Get-MorphospaceNormalizationJsonBytes $Intent.target_state
    if((Get-MorphospaceNormalizationSha256 $targetStateBytes)-cne[string]$Intent.target.state_file_sha256){throw 'Event-ledger normalization intent target state file hash is invalid.'}
    $receiptBytes=Get-MorphospaceNormalizationJsonBytes $Intent.receipt.document
    if((Get-MorphospaceNormalizationSha256 $receiptBytes)-cne[string]$Intent.receipt.sha256){throw 'Event-ledger normalization intent receipt hash is invalid.'}
    $r=$Intent.receipt.document
    if([string]$r.normalization_id-cne$NormalizationId-or[string]$r.project_id-cne[string]$Intent.project.project_id-or
       [string]$r.unit_id-cne$unitId-or[string]$r.created_at-cne[string]$Intent.created_at-or[string]$r.status-cne'normalized'-or
       [string]$r.repository.head-cne[string]$Intent.repository.head-or[string]$r.repository.branch-cne[string]$Intent.repository.branch-or
       [string]$r.ledger.path-cne[string]$Intent.paths.events-or
       [string]$r.ledger.before_sha256-cne[string]$Intent.pre.events_sha256-or[int64]$r.ledger.before_length-ne[int64]$Intent.pre.events_length-or
       [string]$r.ledger.normalized_prefix_sha256-cne[string]$Intent.target.normalized_prefix_sha256-or
       [int64]$r.ledger.normalized_prefix_length-ne[int64]$Intent.target.normalized_prefix_length-or
       [string]$r.ledger.after_sha256-cne[string]$Intent.target.events_sha256-or[int64]$r.ledger.after_length-ne[int64]$Intent.target.events_length-or
       [int]$r.ledger.preserved_event_count-ne[int]$prior.events.Count-or
       [string]$r.ledger.prior_tail_event_id-cne[string]$Intent.pre.event_tail_id-or[int]$r.ledger.prior_tail_sequence-ne[int]$Intent.pre.event_tail_sequence-or
       [string]$r.state.path-cne[string]$Intent.paths.state-or
       [string]$r.state.before_file_sha256-cne[string]$Intent.pre.state_file_sha256-or
       [string]$r.state.before_document_sha256-cne[string]$Intent.pre.state_document_sha256-or
       [string]$r.state.after_file_sha256-cne[string]$Intent.target.state_file_sha256-or
       [string]$r.state.after_document_sha256-cne[string]$Intent.target.state_document_sha256-or
       [string]$r.unit.path-cne[string]$Intent.paths.unit-or
       [string]$r.unit.file_sha256-cne[string]$Intent.pre.unit_file_sha256-or
       [string]$r.unit.document_sha256-cne[string]$Intent.pre.unit_document_sha256-or
       [string]$r.event.event_id-cne$NormalizationId-or[int]$r.event.sequence-ne[int]$Intent.event.sequence-or
       [string]$r.event.receipt_path-cne[string]$Intent.paths.receipt){
        throw 'Event-ledger normalization receipt does not derive from its intent.'
    }
    [pscustomobject]@{paths=$paths;before=$before;before_state=$beforeStateBytes;normalized=$normalized;after=$after;target_state_bytes=$targetStateBytes;receipt_bytes=$receiptBytes}
}

function Assert-MorphospaceNormalizationCallerAuthority {
    param(
        [Parameter(Mandatory=$true)][object]$Intent,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][string]$ExpectedRepositoryHead,
        [Parameter(Mandatory=$true)][string]$ExpectedProjectSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedStateSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedUnitSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedEventsSha256,
        [Parameter(Mandatory=$true)][int64]$ExpectedEventsLength,
        [Parameter(Mandatory=$true)][string]$ExpectedEventTailId
    )
    foreach($expected in @(
        [pscustomobject]@{name='project file';value=$ExpectedProjectSha256;bound=[string]$Intent.project.file_sha256},
        [pscustomobject]@{name='state file';value=$ExpectedStateSha256;bound=[string]$Intent.pre.state_file_sha256},
        [pscustomobject]@{name='unit file';value=$ExpectedUnitSha256;bound=[string]$Intent.pre.unit_file_sha256},
        [pscustomobject]@{name='event-ledger';value=$ExpectedEventsSha256;bound=[string]$Intent.pre.events_sha256}
    )){
        Assert-MorphospaceNormalizationExpectedHash $expected.name ([string]$expected.value) ([string]$expected.bound)
    }
    if($ExpectedRepositoryHead-cnotmatch'^[0-9a-f]{40}$'-or$ExpectedRepositoryHead-cne[string]$Intent.repository.head){
        throw 'Event-ledger prefix normalization caller repository-HEAD CAS does not match the authenticated intent.'
    }
    if($UnitId-cne([IO.Path]::GetFileNameWithoutExtension([string]$Intent.paths.unit))-or[string]$Intent.event.unit_id-cne$UnitId){
        throw 'Event-ledger prefix normalization caller UnitId does not match the authenticated intent.'
    }
    if($ExpectedEventsLength-lt0-or$ExpectedEventsLength-ne[int64]$Intent.pre.events_length){
        throw 'Event-ledger prefix normalization caller event-ledger length CAS does not match the authenticated intent.'
    }
    if($ExpectedEventTailId-cne[string]$Intent.pre.event_tail_id){
        throw 'Event-ledger prefix normalization caller event-tail CAS does not match the authenticated intent.'
    }
}

function Read-MorphospaceNormalizationLeasedBytes {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $bytes=[byte[]]::new($stream.Length)
        $offset=0
        while($offset-lt$bytes.Length){
            $read=$stream.Read($bytes,$offset,$bytes.Length-$offset)
            if($read-eq0){throw 'Event-ledger normalization leased read ended before the exact file length.'}
            $offset+=$read
        }
        $bytes
    }finally{$stream.Dispose()}
}

function Install-MorphospaceNormalizationExactTarget {
    param(
        [Parameter(Mandatory=$true)][string]$Target,
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][string]$Backup,
        [Parameter(Mandatory=$true)][byte[]]$BeforeBytes,
        [Parameter(Mandatory=$true)][byte[]]$TargetBytes,
        [Parameter(Mandatory=$true)][string]$Label
    )
    $beforeHash=Get-MorphospaceNormalizationSha256 $BeforeBytes
    $targetHash=Get-MorphospaceNormalizationSha256 $TargetBytes
    foreach($owned in @([pscustomobject]@{path=$Stage;hash=$targetHash},[pscustomobject]@{path=$Backup;hash=$beforeHash})){
        if([IO.Directory]::Exists($owned.path)){throw "Event-ledger normalization $Label transaction path is occupied by a directory."}
        if([IO.File]::Exists($owned.path)-and(Get-MorphospaceFileSha256 $owned.path)-cne$owned.hash){
            throw "Event-ledger normalization $Label transaction file differs from its exact intended bytes."
        }
    }

    if([IO.File]::Exists($Target)){
        $current=Read-MorphospaceNormalizationLeasedBytes $Target
        $currentHash=Get-MorphospaceNormalizationSha256 $current
        if($currentHash-cne$beforeHash-and$currentHash-cne$targetHash){
            throw "Event-ledger normalization found neither the exact before nor exact after $Label state."
        }
        if($currentHash-ceq$targetHash){
            if([IO.File]::Exists($Stage)){Remove-MorphospaceNormalizationExactFile $Stage $targetHash}
            if([IO.File]::Exists($Backup)){Remove-MorphospaceNormalizationExactFile $Backup $beforeHash}
            return
        }
        if([IO.File]::Exists($Backup)){throw "Event-ledger normalization has an ambiguous before-state plus $Label backup."}
        if(-not[IO.File]::Exists($Stage)){
            $stream=[IO.FileStream]::new($Stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
            try{$stream.Write($TargetBytes,0,$TargetBytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        }
        Move-MorphospaceNormalizationExactFile $Target $Backup $beforeHash
        if((Get-MorphospaceFileSha256 $Backup)-cne$beforeHash){
            throw "Event-ledger normalization exact-handle $Label backup readback failed."
        }
    }elseif(-not[IO.File]::Exists($Backup)){
        throw "Event-ledger normalization $Label target and exact leased backup are both absent."
    }

    if((Get-MorphospaceFileSha256 $Backup)-cne$beforeHash-or-not[IO.File]::Exists($Stage)-or
       (Get-MorphospaceFileSha256 $Stage)-cne$targetHash){
        throw "Event-ledger normalization cannot recover the exact staged $Label replacement."
    }
    if([IO.File]::Exists($Target)){throw "Event-ledger normalization will not overwrite an existing $Label recovery target."}
    Move-MorphospaceNormalizationExactFile $Stage $Target $targetHash
    $readback=Read-MorphospaceNormalizationLeasedBytes $Target
    if((Get-MorphospaceNormalizationSha256 $readback)-cne$targetHash-or(Get-MorphospaceFileSha256 $Backup)-cne$beforeHash){
        throw "Event-ledger normalization exact $Label replacement readback failed."
    }
    Remove-MorphospaceNormalizationExactFile $Backup $beforeHash
}

function Write-MorphospaceNormalizationStateTarget {
    param([Parameter(Mandatory=$true)][string]$Workspace,[Parameter(Mandatory=$true)][object]$Intent,[Parameter(Mandatory=$true)][object]$Derived)
    $state=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Intent.paths.state) -RequireLeaf
    $stage=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Derived.paths.state_stage)
    $backup=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Derived.paths.state_backup)
    Install-MorphospaceNormalizationExactTarget $state $stage $backup $Derived.before_state $Derived.target_state_bytes 'state'
    $stateBytes=Read-MorphospaceNormalizationLeasedBytes $state
    if((Get-MorphospaceNormalizationSha256 $stateBytes)-cne[string]$Intent.target.state_file_sha256-or
       (Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $state))-cne[string]$Intent.target.state_document_sha256){
        throw 'Event-ledger normalization target state readback differs from its intent.'
    }
}

function Write-MorphospaceNormalizationLedgerTarget {
    param([Parameter(Mandatory=$true)][string]$Workspace,[Parameter(Mandatory=$true)][object]$Intent,[Parameter(Mandatory=$true)][object]$Derived)
    $events=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Intent.paths.events) -RequireLeaf
    $stage=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Derived.paths.stage)
    $backup=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Derived.paths.backup)
    Install-MorphospaceNormalizationExactTarget $events $stage $backup $Derived.before $Derived.after 'event-ledger'
    $afterBytes=Read-MorphospaceNormalizationLeasedBytes $events
    if((Get-MorphospaceNormalizationSha256 $afterBytes)-cne[string]$Intent.target.events_sha256){throw 'Event-ledger normalization target ledger changed after replacement.'}
    [void](Test-MorphospaceTransitionLedgerBytes $afterBytes)
}

function Assert-MorphospaceNormalizationFinalProjection {
    param(
        [Parameter(Mandatory=$true)][string]$Workspace,
        [Parameter(Mandatory=$true)][object]$Intent,
        [Parameter(Mandatory=$true)][object]$Derived,
        [Parameter(Mandatory=$true)][string]$ExpectedIntentSha256
    )
    $intentPath=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Derived.paths.intent) -RequireLeaf
    Assert-MorphospaceNormalizationExpectedHash 'intent file' $ExpectedIntentSha256 (Get-MorphospaceFileSha256 $intentPath)
    $git=Get-MorphospaceNormalizationGitObservation $Workspace
    if($git.head-cne[string]$Intent.repository.head-or$git.branch-cne[string]$Intent.repository.branch){
        throw 'Event-ledger normalization repository HEAD or branch drifted before completion.'
    }
    Assert-MorphospaceNormalizationOwnedDirt $git $Derived.paths

    $projectPath=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Intent.paths.project) -RequireLeaf
    $statePath=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Intent.paths.state) -RequireLeaf
    $unitPath=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Intent.paths.unit) -RequireLeaf
    $eventsPath=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Intent.paths.events) -RequireLeaf
    $receiptPath=Get-MorphospaceNormalizationAbsolute $Workspace ([string]$Intent.paths.receipt) -RequireLeaf
    if((Get-MorphospaceFileSha256 $projectPath)-cne[string]$Intent.project.file_sha256){throw 'Event-ledger normalization project bytes drifted before completion.'}
    $project=Read-MorphospaceProtocolJson $projectPath
    if((Get-MorphospaceCanonicalJsonSha256 $project)-cne[string]$Intent.project.document_sha256-or
       [string]$project.project_id-cne[string]$Intent.project.project_id){throw 'Event-ledger normalization project document drifted before completion.'}
    if((Get-MorphospaceFileSha256 $statePath)-cne[string]$Intent.target.state_file_sha256){throw 'Event-ledger normalization state bytes drifted before completion.'}
    $state=Read-MorphospaceProtocolJson $statePath
    if((Get-MorphospaceCanonicalJsonSha256 $state)-cne[string]$Intent.target.state_document_sha256-or
       [string]$state.last_event_id-cne[string]$Intent.event.event_id-or[string]$state.current_unit-cne[string]$Intent.event.unit_id){
        throw 'Event-ledger normalization state document drifted before completion.'
    }
    if((Get-MorphospaceFileSha256 $unitPath)-cne[string]$Intent.pre.unit_file_sha256){throw 'Event-ledger normalization current-unit bytes drifted before completion.'}
    $unit=Read-MorphospaceProtocolJson $unitPath
    if((Get-MorphospaceCanonicalJsonSha256 $unit)-cne[string]$Intent.pre.unit_document_sha256-or
       [string]$unit.unit_id-cne[string]$Intent.event.unit_id-or[string]$unit.project_id-cne[string]$Intent.project.project_id-or
       [string]$unit.status-cne[string]$Intent.receipt.document.unit.status){
        throw 'Event-ledger normalization current-unit document drifted before completion.'
    }
    $events=Read-MorphospaceNormalizationLeasedBytes $eventsPath
    if((Get-MorphospaceNormalizationSha256 $events)-cne[string]$Intent.target.events_sha256-or$events.LongLength-ne[int64]$Intent.target.events_length){
        throw 'Event-ledger normalization ledger bytes drifted before completion.'
    }
    $ledger=Test-MorphospaceTransitionLedgerBytes $events
    if($ledger.events.Count-ne[int]$Intent.receipt.document.ledger.preserved_event_count+1-or
       [string]$ledger.tail_id-cne[string]$Intent.event.event_id-or[int]$ledger.events[-1].sequence-ne[int]$Intent.event.sequence){
        throw 'Event-ledger normalization ledger sequence drifted before completion.'
    }
    if((Get-MorphospaceFileSha256 $receiptPath)-cne[string]$Intent.receipt.sha256){throw 'Event-ledger normalization receipt bytes drifted before completion.'}
    $receipt=Read-MorphospaceProtocolJson $receiptPath
    Test-MorphospaceNormalizationSchema $receipt 'event-ledger-prefix-normalization-v1.schema.json' 'Event-ledger normalization final receipt'
    if((Get-MorphospaceNormalizationSha256 (Get-MorphospaceNormalizationJsonBytes $receipt))-cne[string]$Intent.receipt.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $receipt)-cne(Get-MorphospaceCanonicalJsonSha256 $Intent.receipt.document)){
        throw 'Event-ledger normalization receipt document drifted before completion.'
    }
}

function Complete-MorphospaceEventLedgerPrefixNormalization {
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [Parameter(Mandatory=$true)][string]$NormalizationId,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][string]$ExpectedRepositoryHead,
        [Parameter(Mandatory=$true)][string]$ExpectedProjectSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedStateSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedUnitSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedEventsSha256,
        [Parameter(Mandatory=$true)][int64]$ExpectedEventsLength,
        [Parameter(Mandatory=$true)][string]$ExpectedEventTailId,
        [Parameter(Mandatory=$true)][string]$ExpectedIntentSha256,
        [ValidateSet('none','after-receipt','after-state','after-events')][string]$FaultAfter='none'
    )
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$paths=Get-MorphospaceNormalizationPaths $NormalizationId
    $lock=Enter-MorphospaceWorkspaceMutex $workspace
    try{
        $intentPath=Get-MorphospaceNormalizationAbsolute $workspace $paths.intent -RequireLeaf
        $completionPath=Get-MorphospaceNormalizationAbsolute $workspace $paths.completion
        if([IO.File]::Exists($completionPath)){throw 'Event-ledger prefix normalization rejects replay after committed completion.'}
        $intentBytes=Read-MorphospaceNormalizationLeasedBytes $intentPath
        Assert-MorphospaceNormalizationExpectedHash 'intent file' $ExpectedIntentSha256 (Get-MorphospaceNormalizationSha256 $intentBytes)
        $intent=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $intentBytes -Context 'authenticated event-ledger prefix normalization intent'
        $derived=Assert-MorphospaceNormalizationIntent $intent $NormalizationId
        Assert-MorphospaceNormalizationCallerAuthority $intent $UnitId $ExpectedRepositoryHead $ExpectedProjectSha256 `
            $ExpectedStateSha256 $ExpectedUnitSha256 $ExpectedEventsSha256 $ExpectedEventsLength $ExpectedEventTailId
        $paths=$derived.paths
        $git=Get-MorphospaceNormalizationGitObservation $workspace
        if($git.head-cne[string]$intent.repository.head-or[string]$git.branch-cne[string]$intent.repository.branch){throw 'Event-ledger normalization repository identity drifted after intent publication.'}
        Assert-MorphospaceNormalizationOwnedDirt $git $paths

        $projectPath=Get-MorphospaceNormalizationAbsolute $workspace ([string]$intent.paths.project) -RequireLeaf
        $statePath=Get-MorphospaceNormalizationAbsolute $workspace ([string]$intent.paths.state) -RequireLeaf
        $unitPath=Get-MorphospaceNormalizationAbsolute $workspace ([string]$intent.paths.unit) -RequireLeaf
        if((Get-MorphospaceFileSha256 $projectPath)-cne[string]$intent.project.file_sha256){throw 'Event-ledger normalization project bytes drifted after intent publication.'}
        if((Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $projectPath))-cne[string]$intent.project.document_sha256){throw 'Event-ledger normalization project document drifted after intent publication.'}
        if((Get-MorphospaceFileSha256 $unitPath)-cne[string]$intent.pre.unit_file_sha256){throw 'Event-ledger normalization current-unit bytes drifted after intent publication.'}
        $unit=Read-MorphospaceProtocolJson $unitPath
        if((Get-MorphospaceCanonicalJsonSha256 $unit)-cne[string]$intent.pre.unit_document_sha256-or[string]$unit.status-cne[string]$intent.receipt.document.unit.status){throw 'Event-ledger normalization current-unit document drifted after intent publication.'}
        $stateFileHash=Get-MorphospaceFileSha256 $statePath
        if($stateFileHash-cne[string]$intent.pre.state_file_sha256-and$stateFileHash-cne[string]$intent.target.state_file_sha256){throw 'Event-ledger normalization found neither the exact before nor exact after state.'}

        $receiptPath=Get-MorphospaceNormalizationAbsolute $workspace ([string]$intent.paths.receipt)
        if([IO.Directory]::Exists($receiptPath)){throw 'Event-ledger normalization receipt path is occupied by a directory.'}
        if([IO.File]::Exists($receiptPath)){
            if((Get-MorphospaceFileSha256 $receiptPath)-cne[string]$intent.receipt.sha256){throw 'Event-ledger normalization receipt differs from its intent.'}
            $eventsHash=Get-MorphospaceFileSha256 (Get-MorphospaceNormalizationAbsolute $workspace ([string]$intent.paths.events) -RequireLeaf)
            if($stateFileHash-cne[string]$intent.target.state_file_sha256-or$eventsHash-cne[string]$intent.target.events_sha256){
                throw 'Event-ledger normalization found a prematurely published receipt before its target projection.'
            }
        }

        Write-MorphospaceNormalizationStateTarget $workspace $intent $derived
        if($FaultAfter-eq'after-state'){throw 'Injected interruption after normalization state projection.'}

        Write-MorphospaceNormalizationLedgerTarget $workspace $intent $derived
        if($FaultAfter-eq'after-events'){throw 'Injected interruption after normalized event-ledger publication.'}

        if(-not[IO.File]::Exists($receiptPath)){
            Write-MorphospaceManagedProtocolJsonAtomic $workspace ([string]$intent.paths.receipt) $intent.receipt.document -NoOverwrite
        }
        if((Get-MorphospaceFileSha256 $receiptPath)-cne[string]$intent.receipt.sha256){throw 'Event-ledger normalization truthful receipt publication readback failed.'}
        if($FaultAfter-eq'after-receipt'){throw 'Injected interruption after normalization receipt installation.'}

        Assert-MorphospaceNormalizationFinalProjection $workspace $intent $derived $ExpectedIntentSha256
        $completion=[pscustomobject][ordered]@{
            schema='rusty.morphospace.workflow.event_ledger_prefix_normalization_completion.v1'
            transaction_id=[string]$intent.transaction_id
            normalization_id=$NormalizationId
            completed_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            intent=[pscustomobject][ordered]@{
                role='event-ledger-prefix-normalization-intent';path=$paths.intent
                schema=[string]$intent.schema;sha256=$ExpectedIntentSha256
            }
            receipt=[pscustomobject][ordered]@{
                role='event-ledger-prefix-normalization';path=[string]$intent.paths.receipt
                schema=[string]$intent.receipt.document.schema;sha256=[string]$intent.receipt.sha256
            }
            repository_head=[string]$intent.repository.head
            state_sha256=[string]$intent.target.state_file_sha256
            unit_sha256=[string]$intent.pre.unit_file_sha256
            events_sha256=[string]$intent.target.events_sha256
            event_id=$NormalizationId
            status='committed'
        }
        Test-MorphospaceNormalizationSchema $completion 'event-ledger-prefix-normalization-completion-v1.schema.json' 'Event-ledger normalization completion'
        Assert-MorphospaceNormalizationFinalProjection $workspace $intent $derived $ExpectedIntentSha256
        Write-MorphospaceManagedProtocolJsonAtomic $workspace $paths.completion $completion -NoOverwrite
        return [pscustomobject][ordered]@{
            normalization_id=$NormalizationId;transaction_id=[string]$intent.transaction_id
            status='committed';receipt=[string]$intent.paths.receipt;completion=$paths.completion
            repository_head=[string]$intent.repository.head;events_sha256=[string]$intent.target.events_sha256
            state_sha256=[string]$intent.target.state_file_sha256;unit_sha256=[string]$intent.pre.unit_file_sha256
        }
    }finally{Exit-MorphospaceWorkspaceMutex $lock}
}

function Invoke-MorphospaceEventLedgerPrefixNormalization {
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [Parameter(Mandatory=$true)][string]$NormalizationId,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][string]$ExpectedRepositoryHead,
        [Parameter(Mandatory=$true)][string]$ExpectedProjectSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedStateSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedUnitSha256,
        [Parameter(Mandatory=$true)][string]$ExpectedEventsSha256,
        [Parameter(Mandatory=$true)][int64]$ExpectedEventsLength,
        [Parameter(Mandatory=$true)][string]$ExpectedEventTailId,
        [string]$ExpectedIntentSha256='',
        [string]$Timestamp='',
        [switch]$Execute,
        [ValidateSet('none','after-intent','after-receipt','after-state','after-events')][string]$FaultAfter='none'
    )
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')}
    [void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    $paths=Get-MorphospaceNormalizationPaths $NormalizationId
    $intentPath=Get-MorphospaceNormalizationAbsolute $workspace $paths.intent
    $completionPath=Get-MorphospaceNormalizationAbsolute $workspace $paths.completion
    if([IO.File]::Exists($completionPath)){throw 'Event-ledger prefix normalization rejects replay after committed completion.'}
    if($Execute-and-not$ExpectedIntentSha256){throw 'Executed event-ledger prefix normalization requires ExpectedIntentSha256 from its deterministic dry-run.'}
    if([IO.File]::Exists($intentPath)){
        if(-not$Execute){throw 'Event-ledger prefix normalization has an outstanding intent requiring executed recovery.'}
        return Complete-MorphospaceEventLedgerPrefixNormalization $workspace $NormalizationId $UnitId $ExpectedRepositoryHead `
            $ExpectedProjectSha256 $ExpectedStateSha256 $ExpectedUnitSha256 $ExpectedEventsSha256 $ExpectedEventsLength `
            $ExpectedEventTailId $ExpectedIntentSha256 -FaultAfter $(if($FaultAfter-eq'after-intent'){'none'}else{$FaultAfter})
    }

    $lock=Enter-MorphospaceWorkspaceMutex $workspace
    try{
        if([IO.File]::Exists($intentPath)-or[IO.File]::Exists($completionPath)){throw 'Event-ledger normalization transaction identity is already occupied.'}
        $transactions=Get-MorphospaceNormalizationAbsolute $workspace 'receipts/transactions'
        if([IO.Directory]::Exists($transactions)){
            foreach($priorIntent in @([IO.Directory]::EnumerateFiles($transactions,'*.intent.json',[IO.SearchOption]::TopDirectoryOnly))){
                $priorCompletion=$priorIntent.Substring(0,$priorIntent.Length-'.intent.json'.Length)+'.completion.json'
                if(-not[IO.File]::Exists($priorCompletion)){throw "Workspace has another outstanding transition intent requiring repair: $([IO.Path]::GetFileName($priorIntent))"}
            }
        }
        $candidate=Get-MorphospaceNormalizationCandidate -Workspace $workspace -NormalizationId $NormalizationId -UnitId $UnitId `
            -ExpectedRepositoryHead $ExpectedRepositoryHead -ExpectedProjectSha256 $ExpectedProjectSha256 `
            -ExpectedStateSha256 $ExpectedStateSha256 -ExpectedUnitSha256 $ExpectedUnitSha256 `
            -ExpectedEventsSha256 $ExpectedEventsSha256 -ExpectedEventsLength $ExpectedEventsLength `
            -ExpectedEventTailId $ExpectedEventTailId -Timestamp $Timestamp
        Assert-MorphospaceNormalizationGitClean $candidate.git
        $intent=New-MorphospaceNormalizationIntent $candidate
        Test-MorphospaceNormalizationSchema $intent 'event-ledger-prefix-normalization-intent-v1.schema.json' 'Event-ledger normalization intent'
        $intentBytes=Get-MorphospaceNormalizationJsonBytes $intent
        $intentSha256=Get-MorphospaceNormalizationSha256 $intentBytes
        foreach($relative in @($paths.receipt,$paths.completion,$paths.stage,$paths.backup,$paths.state_stage,$paths.state_backup)){
            $target=Get-MorphospaceNormalizationAbsolute $workspace $relative
            if([IO.File]::Exists($target)-or[IO.Directory]::Exists($target)){throw "Event-ledger normalization target path is occupied: $relative"}
        }
        if(-not$Execute){
            return [pscustomobject][ordered]@{
                normalization_id=$NormalizationId;transaction_id=$paths.transaction_id;status='planned'
                repository_head=$candidate.git.head;project_id=[string]$candidate.project.project_id;unit_id=$UnitId
                before_events_sha256=[string]$intent.pre.events_sha256;after_events_sha256=[string]$intent.target.events_sha256
                before_state_sha256=[string]$intent.pre.state_file_sha256;after_state_sha256=[string]$intent.target.state_file_sha256
                intent=$paths.intent;intent_sha256=$intentSha256;created_at=[string]$intent.created_at
                receipt=$paths.receipt;completion=$paths.completion;execution='not-performed'
            }
        }
        Assert-MorphospaceNormalizationExpectedHash 'intent file' $ExpectedIntentSha256 $intentSha256
        Write-MorphospaceManagedProtocolJsonAtomic $workspace $paths.intent $intent -NoOverwrite
        Assert-MorphospaceNormalizationExpectedHash 'intent file' $ExpectedIntentSha256 (Get-MorphospaceFileSha256 $intentPath)
        if($FaultAfter-eq'after-intent'){throw 'Injected interruption after normalization intent publication.'}
    }finally{Exit-MorphospaceWorkspaceMutex $lock}
    Complete-MorphospaceEventLedgerPrefixNormalization $workspace $NormalizationId $UnitId $ExpectedRepositoryHead `
        $ExpectedProjectSha256 $ExpectedStateSha256 $ExpectedUnitSha256 $ExpectedEventsSha256 $ExpectedEventsLength `
        $ExpectedEventTailId $ExpectedIntentSha256 -FaultAfter $FaultAfter
}

Export-ModuleMember -Function Invoke-MorphospaceEventLedgerPrefixNormalization,Complete-MorphospaceEventLedgerPrefixNormalization
