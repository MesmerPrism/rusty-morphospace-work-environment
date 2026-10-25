Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:NativeAuthorityRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:NativeSourceScope=$null
$script:NativeSourceScopeOwner=$null
Import-Module (Join-Path $PSScriptRoot 'ExternalOwnerAuthorization.psm1') -Force -Scope Local

function Get-NativeRecoveryDigest([byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
function Get-NativeRecoveryValueDigest([object]$Value){Get-NativeRecoveryDigest (Get-CanonicalAuthorizationBytes $Value)}
function Get-NativeRecoveryNativeProjection([object]$Value){
    $shell=[PowerShell]::Create()
    try{
        $code={param($root,$value)$ErrorActionPreference='Stop';$module=Import-Module (Join-Path $root 'scripts/lib/MorphospaceProtocolCommon.psm1') -PassThru;&$module {param($v)$bytes=ConvertTo-MorphospaceProtocolJsonBytes $v;[pscustomobject]@{sha256=Get-MorphospaceCanonicalJsonSha256 $v;bytes_base64=[Convert]::ToBase64String($bytes)}} $value}
        $null=$shell.AddScript($code.ToString()).AddArgument($script:NativeAuthorityRoot).AddArgument($Value);$result=$shell.Invoke()
        if($shell.HadErrors-or$result.Count-ne1){throw 'Native recovery native projection serializer failed.'};$result[0]
    }finally{$shell.Dispose()}
}
function Get-NativeRecoveryProjectionDigest([object]$Value){(Get-NativeRecoveryNativeProjection $Value).sha256}
function Test-NativeRecoveryField([object]$Value,[string]$Name){($Value-is[Collections.IDictionary]-and$Value.Contains($Name))-or($Value.PSObject.Properties.Name-ccontains$Name)}
function Assert-NativeRecoveryEqual([object]$Actual,[object]$Expected,[string]$Label){if((Get-NativeRecoveryValueDigest $Actual)-cne(Get-NativeRecoveryValueDigest $Expected)){throw "Native recovery $Label differs from independently observed evidence."}}
function Resolve-NativeRecoveryPath([string]$Root,[string]$Path,[switch]$Leaf){
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if([IO.Path]::IsPathRooted($Path)-or$Path-cmatch'(^|/)\.\.(/|$)|[\\:\x00-\x1f\x7f]' -or -not$Path){throw 'Native recovery relative path is unsafe.'}
    $resolved=[IO.Path]::GetFullPath((Join-Path $base $Path))
    if(-not$resolved.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Native recovery path escapes its root.'}
    Assert-NativeRecoveryNoAlias $resolved
    if($Leaf-and-not[IO.File]::Exists($resolved)){throw 'Native recovery required leaf is unavailable.'}
    $resolved
}
function Assert-NativeRecoveryNoAlias([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){try{$attributes=[IO.File]::GetAttributes($current);if(($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Native recovery reparse/alias path is forbidden.'}}catch [IO.FileNotFoundException]{}catch [IO.DirectoryNotFoundException]{};$parent=[IO.Path]::GetDirectoryName($current);if($parent-ceq$current){break};$current=$parent}
}
function Read-NativeRecoveryBytes([string]$Path,[long]$Limit=16777216){
    Assert-NativeRecoveryNoAlias $Path
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{if($stream.Length-gt$Limit){throw 'Native recovery input exceeds the byte bound.'};$buffer=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($buffer);return ,$buffer}finally{$stream.Dispose()}
}
function Read-NativeRecoveryJson([string]$Path){ConvertFrom-ExternalOwnerJsonStrict ([Text.UTF8Encoding]::new($false,$true).GetString((Read-NativeRecoveryBytes $Path)))}
function Invoke-NativeRecoveryGit([string]$Root,[string[]]$Arguments){
    $environment=[Environment]::GetEnvironmentVariables()
    foreach($key in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES','GIT_NAMESPACE','GIT_SHALLOW_FILE','GIT_CONFIG','GIT_CONFIG_COUNT','GIT_CONFIG_PARAMETERS','GIT_REPLACE_REF_BASE')){if($environment.Contains($key)){throw 'Native recovery inherited Git selectors are forbidden.'}}
    $p=[Diagnostics.Process]::new();$p.StartInfo=[Diagnostics.ProcessStartInfo]::new();$p.StartInfo.FileName=(@(Get-Command git -CommandType Application -ErrorAction Stop)[0]).Source;$p.StartInfo.WorkingDirectory=$Root;$p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    foreach($arg in @('--no-optional-locks','--no-pager','--no-replace-objects','-c','core.fsmonitor=false','-c','core.hooksPath=','-c','diff.external=')+$Arguments){$p.StartInfo.ArgumentList.Add($arg)}
    $p.StartInfo.Environment['GIT_CONFIG_NOSYSTEM']='1';$p.StartInfo.Environment['GIT_CONFIG_GLOBAL']=$(if($IsWindows){'NUL'}else{'/dev/null'})
    try{$null=$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync();$p.WaitForExit();$text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult();if($p.ExitCode-ne0){throw 'Native recovery Git inspection failed.'};$text.TrimEnd("`r","`n")}finally{$p.Dispose()}
}
function Add-NativeRecoveryDirectoryHolds([string]$Directory){
    if(-not$IsWindows-or$null-eq$script:NativeSourceScopeOwner){return}
    if(-not('NativeRecoveryDirectoryHoldV1'-as[type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class NativeRecoveryDirectoryHoldV1 {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
}
'@
    }
    $at=[IO.Path]::GetFullPath($Directory);$ancestry=[Collections.Generic.List[string]]::new()
    while($at){$ancestry.Add($at);$parent=[IO.Path]::GetDirectoryName($at);if($parent-ceq$at){break};$at=$parent}
    # Pin from the volume down so no unheld ancestor can be replaced while
    # opening a descendant and leave the descendant hold at a detached path.
    for($i=$ancestry.Count-1;$i-ge0;$i--){
        $at=$ancestry[$i]
        Assert-NativeRecoveryNoAlias $at
        if(-not$script:NativeSourceScopeOwner.directories.ContainsKey($at)){
            # Directory handles permit child writes but deny deleting/renaming
            # this directory. Pin every ancestor, including the source root.
            $handle=[NativeRecoveryDirectoryHoldV1]::CreateFileW($at,0,3,[IntPtr]::Zero,3,0x02000000,[IntPtr]::Zero)
            if($handle.IsInvalid){$errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error();$handle.Dispose();throw [ComponentModel.Win32Exception]::new($errorCode,'Native recovery cannot hold source directory ancestry.')}
            $script:NativeSourceScopeOwner.directories.Add($at,$handle)
            Assert-NativeRecoveryNoAlias $at
        }
    }
}
function Assert-NativeRecoverySourceScopeBinding([string]$WorkspaceRoot,[string]$RequestPath,[string]$ExecutorRoot){
    $owner=$script:NativeSourceScopeOwner
    if($null-eq$owner){throw 'Native recovery source scope is not open.'}
    if($owner.thread_id-ne[Threading.Thread]::CurrentThread.ManagedThreadId){throw 'Native recovery source scope belongs to another thread.'}
    foreach($pair in @(@($WorkspaceRoot,$owner.workspace),@($RequestPath,$owner.request),@($ExecutorRoot,$owner.executor))){if(-not[string]::Equals([IO.Path]::GetFullPath($pair[0]).TrimEnd('\','/'),$pair[1],[StringComparison]::OrdinalIgnoreCase)){throw 'Native recovery source scope cannot cross workspace/request/executor boundaries.'}}
    $held=$owner.request_hold
    if($held.SafeFileHandle.IsClosed-or$held.SafeFileHandle.IsInvalid-or$held.Length-gt16777216){throw 'Native recovery source scope lost its original request data hold.'}
    try{$held.Position=0;$bytes=[byte[]]::new([int]$held.Length);$held.ReadExactly($bytes);if((Get-NativeRecoveryDigest $bytes)-cne$owner.request_raw_sha256){throw 'Native recovery source scope original request data changed.'}}finally{$held.Position=0}
    foreach($stream in $owner.files){if($stream.SafeFileHandle.IsClosed-or$stream.SafeFileHandle.IsInvalid){throw 'Native recovery source scope lost a source file hold.'}}
    foreach($handle in $owner.directories.Values){if($handle.IsClosed-or$handle.IsInvalid){throw 'Native recovery source scope lost a directory hold.'}}
}
function Open-NativeRecoverySourceScope {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ExecutorRoot)
    if($null-ne$script:NativeSourceScopeOwner){throw 'Native recovery source scope cannot nest or replace an active scope.'}
    Assert-NativeRecoveryNoAlias $RequestPath
    # Native completion may rename an owned pending request into its receipt.
    # Pin the data against writes while permitting that legitimate move. This
    # hold confers no authority on another request path or C data record.
    $requestHold=[IO.File]::Open($RequestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read-bor[IO.FileShare]::Delete))
    try{
        Assert-NativeRecoveryNoAlias $RequestPath
        if($requestHold.Length-gt16777216){throw 'Native recovery request exceeds the byte bound.'};$raw=[byte[]]::new([int]$requestHold.Length);$requestHold.ReadExactly($raw);$requestHold.Position=0
        if((ConvertFrom-ExternalOwnerJsonStrict ([Text.UTF8Encoding]::new($false,$true).GetString($raw))).schema-cne'rusty.morphospace.workflow.candidate_freeze.v4'){throw 'Native recovery source scope supports only the separate v4 request.'}
    }catch{$requestHold.Dispose();throw}
    $script:NativeSourceScopeOwner=@{workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');request=[IO.Path]::GetFullPath($RequestPath).TrimEnd('\','/');request_hold=$requestHold;executor=[IO.Path]::GetFullPath($ExecutorRoot).TrimEnd('\','/');thread_id=[Threading.Thread]::CurrentThread.ManagedThreadId;request_raw_sha256=Get-NativeRecoveryDigest $raw;files=[Collections.Generic.List[IO.FileStream]]::new();directories=[Collections.Generic.Dictionary[string,Microsoft.Win32.SafeHandles.SafeFileHandle]]::new([StringComparer]::OrdinalIgnoreCase);previous=$script:NativeSourceScope}
    $script:NativeSourceScope=@{}
    try{
        Add-NativeRecoveryDirectoryHolds $script:NativeAuthorityRoot;Add-NativeRecoveryDirectoryHolds $ExecutorRoot
        $null=Get-NativeRecoverySourceIdentity $script:NativeAuthorityRoot $script:NativeSourceScopeOwner.files
        $null=Get-NativeRecoverySourceIdentity $ExecutorRoot $script:NativeSourceScopeOwner.files
        Assert-NativeRecoverySourceScopeBinding $WorkspaceRoot $RequestPath $ExecutorRoot
    }catch{Close-NativeRecoverySourceScope;throw}
}
function Assert-NativeRecoverySourceScope {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ExecutorRoot)
    Assert-NativeRecoverySourceScopeBinding $WorkspaceRoot $RequestPath $ExecutorRoot
    # All metadata and unsafe-Git guards still run inside each lookup. Only
    # Windows physical bytes protected by live exclusive-write holds are reused.
    $null=Get-NativeRecoverySourceIdentity $script:NativeAuthorityRoot
    $null=Get-NativeRecoverySourceIdentity $ExecutorRoot
}
function Close-NativeRecoverySourceScope {
    if($null-eq$script:NativeSourceScopeOwner){return}
    if($script:NativeSourceScopeOwner.thread_id-ne[Threading.Thread]::CurrentThread.ManagedThreadId){throw 'Native recovery source scope belongs to another thread.'}
    $owner=$script:NativeSourceScopeOwner;$script:NativeSourceScopeOwner=$null;$script:NativeSourceScope=$owner.previous
    try{foreach($stream in $owner.files){$stream.Dispose()};foreach($handle in $owner.directories.Values){$handle.Dispose()}}finally{$owner.request_hold.Dispose()}
}
function Get-NativeRecoverySourceIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Collections.Generic.List[IO.FileStream]]$Holds)
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');Assert-NativeRecoveryNoAlias $rootPath
    $top=Invoke-NativeRecoveryGit $rootPath @('rev-parse','--show-toplevel')
    if(-not[string]::Equals([IO.Path]::GetFullPath($top).TrimEnd('\','/'),$rootPath,[StringComparison]::OrdinalIgnoreCase)){throw 'Native recovery source must be the exact Git root.'}
    if((Invoke-NativeRecoveryGit $rootPath @('rev-parse','--is-shallow-repository'))-cne'false'){throw 'Native recovery shallow source is forbidden.'}
    foreach($relative in @('objects/info/alternates','info/grafts')){$path=Invoke-NativeRecoveryGit $rootPath @('rev-parse','--git-path',$relative);if(-not[IO.Path]::IsPathRooted($path)){$path=Join-Path $rootPath $path};if(Test-Path -LiteralPath $path){throw 'Native recovery alternate/graft source is forbidden.'}}
    if(Invoke-NativeRecoveryGit $rootPath @('for-each-ref','--format=%(refname)','refs/replace')){throw 'Native recovery replacement refs are forbidden.'}
    if(Invoke-NativeRecoveryGit $rootPath @('status','--porcelain=v2','--untracked-files=all')){throw 'Native recovery source is dirty or has untracked files.'}
    $commit=Invoke-NativeRecoveryGit $rootPath @('rev-parse','HEAD');$tree=Invoke-NativeRecoveryGit $rootPath @('rev-parse','HEAD^{tree}');$remote=Invoke-NativeRecoveryGit $rootPath @('remote','get-url','origin')
    if($remote-cnotmatch'^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?$'){throw 'Native recovery source origin must be a canonical GitHub HTTPS repository.'};$repository=$Matches[1]
    if($IsWindows-and$null-ne$script:NativeSourceScopeOwner-and$null-ne$script:NativeSourceScope-and$script:NativeSourceScope.ContainsKey($rootPath)){
        Assert-NativeRecoverySourceScopeBinding $script:NativeSourceScopeOwner.workspace $script:NativeSourceScopeOwner.request $script:NativeSourceScopeOwner.executor
        $cached=$script:NativeSourceScope[$rootPath]
        if($cached.commit-cne$commit-or$cached.tree-cne$tree-or$cached.repository-cne$repository){throw 'Native recovery held source Git identity changed.'}
        return $cached
    }
    $rows=[Collections.Generic.List[object]]::new();$total=0L
    foreach($entry in (Invoke-NativeRecoveryGit $rootPath @('-c','core.quotePath=false','ls-tree','-rlz','--full-tree','HEAD')).Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)){
        if($entry-cnotmatch'^(100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64}) +([0-9]+)\t(.+)$'){throw 'Native recovery source contains unsupported Git entries.'}
        $mode=$Matches[1];$blob=$Matches[2];$size=[long]$Matches[3];$path=$Matches[4];$total+=$size
        if($rows.Count-ge4096-or$size-gt16777216-or$total-gt134217728){throw 'Native recovery source closure exceeds its bound.'}
        $full=Resolve-NativeRecoveryPath $rootPath $path -Leaf
        if($null-ne$Holds){Add-NativeRecoveryDirectoryHolds ([IO.Path]::GetDirectoryName($full))}
        $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{
            Assert-NativeRecoveryNoAlias $full
            if($stream.Length-ne$size){throw 'Native recovery physical source length differs from Git.'};$bytes=[byte[]]::new([int]$size);$stream.ReadExactly($bytes)
            $algorithm=if($blob.Length-eq40){[Security.Cryptography.HashAlgorithmName]::SHA1}else{[Security.Cryptography.HashAlgorithmName]::SHA256};$gitHash=[Security.Cryptography.IncrementalHash]::CreateHash($algorithm)
            try{$gitHash.AppendData([Text.Encoding]::ASCII.GetBytes("blob $size"+[char]0));$gitHash.AppendData($bytes);$physicalBlob=[Convert]::ToHexString($gitHash.GetHashAndReset()).ToLowerInvariant()}finally{$gitHash.Dispose()}
            if($physicalBlob-cne$blob){throw 'Native recovery physical source bytes differ from pinned Git blob.'}
            $rows.Add([ordered]@{path=$path;state='present';mode=$mode;size_bytes=$size;sha256=Get-NativeRecoveryDigest $bytes})
            if($null-ne$Holds){$Holds.Add($stream);$stream=$null}
        }finally{if($null-ne$stream){$stream.Dispose()}}
    }
    $artifacts=@($rows.ToArray())
    if((Invoke-NativeRecoveryGit $rootPath @('rev-parse','HEAD'))-cne$commit-or(Invoke-NativeRecoveryGit $rootPath @('status','--porcelain=v2','--untracked-files=all'))){throw 'Native recovery source changed during observation.'}
    $identity=[ordered]@{repository=$repository;commit=$commit;tree=$tree;closure_sha256=Get-NativeRecoveryValueDigest $artifacts;artifacts=$artifacts}
    if($IsWindows-and$null-ne$Holds-and$null-ne$script:NativeSourceScopeOwner-and$null-ne$script:NativeSourceScope){$script:NativeSourceScope[$rootPath]=$identity}
    $identity
}
function Get-NativeRecoveryAuthorityIdentity {
    $identity=Get-NativeRecoverySourceIdentity $script:NativeAuthorityRoot
    $policyPath=Join-Path $script:NativeAuthorityRoot 'config/native-nonpass-recovery-authority.json'
    [ordered]@{repository=$identity.repository;commit=$identity.commit;tree=$identity.tree;closure_sha256=$identity.closure_sha256;policy_sha256=Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $policyPath)}
}
function Get-NativeRecoveryPolicy {
    $policy=Read-NativeRecoveryJson (Join-Path $script:NativeAuthorityRoot 'config/native-nonpass-recovery-authority.json')
    $required=@('schema','policy_id','repository','issuer_id','public_key_spki_sha256','public_key_pem','max_authorization_age_seconds','max_future_skew_seconds','allowed_purpose','required_qualification_evidence')
    Assert-NativeRecoveryEqual @($policy.PSObject.Properties.Name|Sort-Object -CaseSensitive) @($required|Sort-Object -CaseSensitive) 'closed policy properties'
    if($policy.schema-cne'rusty.morphospace.workflow.native_nonpass_recovery_authority_policy.v1'-or$policy.allowed_purpose-cne'nonaccepting-corrective-freeze'-or$policy.max_authorization_age_seconds-gt86400-or$policy.max_future_skew_seconds-gt300){throw 'Native recovery authority policy is unsupported.'}
    if($policy.max_authorization_age_seconds-isnot[int]-and$policy.max_authorization_age_seconds-isnot[long]-or$policy.max_future_skew_seconds-isnot[int]-and$policy.max_future_skew_seconds-isnot[long]-or$policy.max_authorization_age_seconds-lt1-or$policy.max_future_skew_seconds-lt0){throw 'Native recovery authority policy timing bounds are invalid.'}
    Assert-NativeRecoveryEqual @($policy.required_qualification_evidence|Sort-Object -CaseSensitive) @('focused-conformance','implementation-landing','policy-landing','quick-linux','quick-windows','source-review','standard-windows','static-admission') 'mandatory qualification evidence policy'
    $policy
}
function Get-NativeRecoveryChangedArtifacts([string]$Root,[string]$Base,[object]$SourceIdentity=$null){
    if($Base-cnotmatch'^[0-9a-f]{40}$|^[0-9a-f]{64}$'){throw 'Native recovery qualification base is invalid.'}
    $identity=if($null-ne$SourceIdentity){$SourceIdentity}else{Get-NativeRecoverySourceIdentity $Root}
    $null=Invoke-NativeRecoveryGit $Root @('merge-base','--is-ancestor',$Base,$identity.commit)
    $paths=(Invoke-NativeRecoveryGit $Root @('diff','--name-status','-z','--no-renames',"$Base..$($identity.commit)")).Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)
    $rows=@();for($i=0;$i-lt$paths.Count;$i+=2){if($i+1-ge$paths.Count-or$paths[$i]-cnotin@('A','M','D','T')){throw 'Native recovery changed-path set is unsupported.'};$path=$paths[$i+1];$null=Resolve-NativeRecoveryPath $Root $path;if($paths[$i]-ceq'D'){$rows+=,[ordered]@{path=$path;state='absent'}}else{$found=@($identity.artifacts|Where-Object path -CEQ $path);if($found.Count-ne1){throw 'Native recovery changed artifact lacks an exact source entry.'};$rows+=,$found[0]}}
    @($rows)
}
function Assert-NativeRecoveryQualification([string]$Path,[object]$Authority,[object]$Executor,[datetimeoffset]$At=[datetimeoffset]::UtcNow){
    $policy=Get-NativeRecoveryPolicy;$doc=Read-NativeRecoveryJson $Path
    if($doc.payload.schema-cne'rusty.morphospace.workflow.native_nonpass_repair_qualification_payload.v1'-or$doc.payload.decision-cne'qualify-native-nonpass-repair-source'){throw 'Native recovery source qualification purpose is invalid.'}
    if([datetimeoffset]::Parse($doc.payload.issued_at,[Globalization.CultureInfo]::InvariantCulture)-gt$At){throw 'Native recovery source qualification was not issued before use.'}
    Assert-NativeRecoveryEqual $doc.payload.authority $Authority 'qualified authority anchor'
    Assert-NativeRecoveryEqual $doc.payload.executor $Executor 'qualified executor closure'
    if($Executor.repository-cne$policy.repository){throw 'Native recovery executor repository is outside policy.'}
    Assert-NativeRecoveryEqual $doc.payload.changed_artifacts @(Get-NativeRecoveryChangedArtifacts $script:ObservedExecutorRoot $doc.payload.qualification_base_commit $Executor) 'complete changed artifact set'
    $parents=(Invoke-NativeRecoveryGit $script:ObservedExecutorRoot @('rev-list','--parents','-n','1',[string]$doc.payload.landing.commit)).Split(' ')
    if($parents.Count-ne3-or$parents[2]-cne$Executor.commit-or$parents[1]-cne$doc.payload.qualification_base_commit){throw 'Native recovery source landing is not its exact normal two-parent merge.'}
    Assert-NativeRecoveryEqual @($parents[1],$parents[2]) @($doc.payload.landing.parents) 'landing parent order'
    if((Invoke-NativeRecoveryGit $script:ObservedExecutorRoot @('rev-parse',"$($doc.payload.landing.commit)^{tree}"))-cne$Executor.tree-or$doc.payload.landing.tree-cne$Executor.tree){throw 'Native recovery landing does not retain the exact executor tree.'}
    $kinds=@($doc.payload.evidence|ForEach-Object kind);Assert-NativeRecoveryEqual @($kinds|Sort-Object -CaseSensitive) @($policy.required_qualification_evidence|Sort-Object -CaseSensitive) 'source qualification evidence kinds'
    foreach($artifact in $doc.payload.evidence){$file=Resolve-NativeRecoveryPath (Split-Path $Path -Parent) ([string]$artifact.path) -Leaf;$bytes=Read-NativeRecoveryBytes $file;if($bytes.Length-ne$artifact.size_bytes-or(Get-NativeRecoveryDigest $bytes)-cne$artifact.sha256){throw 'Native recovery source qualification original changed.'}}
    $null=Test-ExternalOwnerSignedPayload -DocumentText ([IO.File]::ReadAllText($Path)) -ExpectedPayload $doc.payload -Policy $policy -SchemaPath (Join-Path $script:NativeAuthorityRoot 'schemas/native-nonpass-repair-qualification-v1.schema.json') -Now $At
    Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $Path)
}
function Get-NativeRecoveryCurrentBindings([string]$WorkspaceRoot,[object]$Request){
    if($Request.unit_id-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){throw 'Native recovery unit identity is invalid.'}
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');Assert-NativeRecoveryNoAlias $workspace
    $files=[ordered]@{project_raw_sha256='project.spec.json';state_raw_sha256='workspace.state.json';unit_raw_sha256="iteration-units/$($Request.unit_id).json";feature_lock_raw_sha256='feature.lock.json';events_raw_sha256='iteration-events.jsonl';source_composition_raw_sha256=[string]$Request.expected.source_composition_path;repository_map_raw_sha256=[string]$Request.expected.repository_map_path}
    $bindings=[ordered]@{}
    foreach($key in $files.Keys){$bindings[$key]=Get-NativeRecoveryDigest (Read-NativeRecoveryBytes (Resolve-NativeRecoveryPath $workspace $files[$key] -Leaf))}
    $project=Read-NativeRecoveryJson (Join-Path $workspace 'project.spec.json');$state=Read-NativeRecoveryJson (Join-Path $workspace 'workspace.state.json');$unit=Read-NativeRecoveryJson (Join-Path $workspace "iteration-units/$($Request.unit_id).json")
    if(Test-NativeRecoveryField $unit 'tooling_context'){throw 'Native NONPASS custody recovery supports only an uncontexted unit; tooling_context is unsupported.'}
    if($project.project_id-cne$Request.project_id-or$unit.unit_id-cne$Request.unit_id-or$state.current_unit-cne$Request.unit_id-or$unit.status-cne'active'){throw 'Native recovery requires the exact active current project/unit.'}
    if($state.PSObject.Properties.Name-ccontains'next_ready_unit'-and$null-ne$state.next_ready_unit-and[string]$state.next_ready_unit){throw 'Native recovery has a competing Ready owner.'}
    $eventBytes=Read-NativeRecoveryBytes (Join-Path $workspace 'iteration-events.jsonl');$lines=([Text.UTF8Encoding]::new($false,$true).GetString($eventBytes)).Split("`n",[StringSplitOptions]::RemoveEmptyEntries);if($lines.Count-eq0){throw 'Native recovery ledger is empty.'};$tail=ConvertFrom-ExternalOwnerJsonStrict $lines[-1]
    if($tail.event_id-cne$state.last_event_id-or$tail.event_id-cne$Request.predecessor.return_event_id){throw 'Native recovery current ledger is not the exact failed Return endpoint.'}
    $retained=Resolve-NativeRecoveryPath $workspace ([string]$Request.predecessor.validation_receipt.path) -Leaf;$failed=Read-NativeRecoveryJson $retained
    if($failed.project_id-cne$Request.project_id-or$failed.unit_id-cne$Request.unit_id-or$failed.result-cnotin@('fail','partial','blocked')-or(Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $retained))-cne$Request.predecessor.validation_receipt.sha256){throw 'Native recovery retained receipt is not the exact same-unit NONPASS.'}
    $freeze=Resolve-NativeRecoveryPath $workspace ([string]$Request.predecessor.freeze.receipt_path) -Leaf
    if((Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $freeze))-cne$Request.predecessor.freeze.receipt_sha256){throw 'Native recovery original freeze changed.'}
    if(@($Request.nonpass_custody_defect.artifacts).Count-lt1-or@($Request.nonpass_custody_defect.artifacts).Count-gt16){throw 'Native recovery defect inventory is empty or oversized.'}
    $map=Read-NativeRecoveryJson (Resolve-NativeRecoveryPath $workspace ([string]$Request.expected.repository_map_path) -Leaf)
    foreach($repository in @($Request.final_repositories)){
        $row=@($map.repositories|Where-Object repo_id -CEQ $repository.repo_id);if($row.Count-ne1){throw 'Native recovery final source is absent or ambiguous in its map.'}
        # Product maps may select an admitted repository subroot. Executor-source
        # publication policy must not invent origin/root requirements for it.
        $sourcePath=[IO.Path]::GetFullPath([string]$row[0].path);Assert-NativeRecoveryNoAlias $sourcePath
        $head=Invoke-NativeRecoveryGit $sourcePath @('rev-parse','HEAD');$tree=Invoke-NativeRecoveryGit $sourcePath @('rev-parse','HEAD^{tree}')
        if($head-cne$repository.commit-or$tree-cne$repository.tree){throw 'Native recovery final source identity is stale.'}
    }
    $bindings.events_length=$eventBytes.Length;$bindings.event_tail_id=[string]$tail.event_id;$bindings.final_repositories=@($Request.final_repositories)
    $bindings.workspace_path_sha256=Get-NativeRecoveryDigest ([Text.Encoding]::UTF8.GetBytes($(if($IsWindows){$workspace.ToUpperInvariant()}else{$workspace})))
    $bindings.planning_commit=Invoke-NativeRecoveryGit $workspace @('rev-parse','HEAD');$bindings.planning_tree=Invoke-NativeRecoveryGit $workspace @('rev-parse','HEAD^{tree}')
    $bindings
}
function New-NativeNonpassRecoveryAuthorizationRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ExecutorRoot)
    $request=Read-NativeRecoveryJson $RequestPath
    if($request.schema-cne'rusty.morphospace.workflow.candidate_freeze.v4'){throw 'Native recovery authority supports only the separate v4 corrective request.'}
    if(-not[string]::Equals([IO.Path]::GetFullPath($request.recovery_authorization.trusted_authority_root).TrimEnd('\','/'),$script:NativeAuthorityRoot.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Native recovery request cannot choose another policy root.'}
    $policy=Get-NativeRecoveryPolicy;$authority=Get-NativeRecoveryAuthorityIdentity;$executor=Get-NativeRecoverySourceIdentity $ExecutorRoot
    $script:ObservedExecutorRoot=$ExecutorRoot
    $qualification=Assert-NativeRecoveryQualification $request.recovery_authorization.source_qualification_path $authority $executor
    $bindings=Get-NativeRecoveryCurrentBindings $WorkspaceRoot $request
    $bindings.request_raw_sha256=Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $RequestPath)
    $derived=[ordered]@{schema='rusty.morphospace.workflow.native_nonpass_recovery_request.v1';project_id=[string]$request.project_id;unit_id=[string]$request.unit_id;freeze_id=[string]$request.freeze_id;request_raw_sha256=$bindings.request_raw_sha256;authority=$authority;executor=$executor;qualification_raw_sha256=$qualification;current_bindings=$bindings;failure_tuple_sha256=Get-NativeRecoveryValueDigest $request.predecessor;defects_sha256=Get-NativeRecoveryValueDigest $request.nonpass_custody_defect}
    if(-not(Test-Json -Json ($derived|ConvertTo-Json -Depth 30 -Compress) -SchemaFile (Join-Path $script:NativeAuthorityRoot 'schemas/native-nonpass-recovery-request-v1.schema.json') -ErrorAction Stop)){throw 'Native recovery derived request failed its closed schema.'}
    $derived
}
function Assert-MorphospaceNativeNonpassRecoveryAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Request,[Parameter(Mandatory)][object]$CurrentBindings,[Parameter(Mandatory)][string]$ExecutorRoot)
    if((Test-NativeRecoveryField $CurrentBindings 'mode')-and$CurrentBindings.mode-ceq'pending'){return Assert-NativeRecoveryTransactionAuthorization -WorkspaceRoot $WorkspaceRoot -Request $Request -CurrentBindings $CurrentBindings -ExecutorRoot $ExecutorRoot -Pending}
    if(-not$CurrentBindings.request_path){throw 'Native recovery needs the physical original request path.'}
    $physical=Read-NativeRecoveryJson $CurrentBindings.request_path;Assert-NativeRecoveryEqual $Request $physical 'raw request document'
    $derived=New-NativeNonpassRecoveryAuthorizationRequest -WorkspaceRoot $WorkspaceRoot -RequestPath $CurrentBindings.request_path -ExecutorRoot $ExecutorRoot
    foreach($key in @('request_raw_sha256','project_raw_sha256','state_raw_sha256','unit_raw_sha256','feature_lock_raw_sha256','events_raw_sha256','events_length','event_tail_id','source_composition_raw_sha256','repository_map_raw_sha256','final_repositories')){
        $value=if($CurrentBindings-is[Collections.IDictionary]){$CurrentBindings[$key]}else{$CurrentBindings.$key}
        Assert-NativeRecoveryEqual $value $derived.current_bindings[$key] "live $key"
    }
    $path=[string]$physical.recovery_authorization.authorization_path;$document=Read-NativeRecoveryJson $path
    $policy=Get-NativeRecoveryPolicy
    if([datetimeoffset]::Parse($document.payload.issued_at,[Globalization.CultureInfo]::InvariantCulture)-gt[datetimeoffset]::UtcNow){throw 'Native recovery authorization is not yet issued.'}
    $expected=[ordered]@{schema='rusty.morphospace.workflow.native_nonpass_recovery_authorization_payload.v1';issuer_id=$policy.issuer_id;authorization_id=$document.payload.authorization_id;issued_at=$document.payload.issued_at;expires_at=$document.payload.expires_at;decision='authorize-native-nonpass-custody-recovery';purpose='nonaccepting-corrective-freeze';request=$derived;limitations=@('no-pass-or-acceptance-credit','no-source-scope-extension','no-publication-or-runtime-authority')}
    $null=Test-ExternalOwnerSignedPayload -DocumentText ([IO.File]::ReadAllText($path)) -ExpectedPayload $expected -Policy $policy -SchemaPath (Join-Path $script:NativeAuthorityRoot 'schemas/native-nonpass-recovery-authorization-v1.schema.json')
    [ordered]@{schema='rusty.morphospace.workflow.native_nonpass_recovery_assessment.v1';authorization_id=$document.payload.authorization_id;request_raw_sha256=$derived.request_raw_sha256;authority=$derived.authority;executor=$derived.executor;executed=$false;acceptance_authority=$false;publication_authority=$false}
}
function Get-NativeRecoveryObjectSourceIdentity([string]$Root,[string]$Commit){
    if($Commit-cnotmatch'^[0-9a-f]{40}$|^[0-9a-f]{64}$'){throw 'Native recovery historical executor commit is invalid.'}
    $tree=Invoke-NativeRecoveryGit $Root @('rev-parse',"$Commit`^{tree}");$remote=Invoke-NativeRecoveryGit $Root @('remote','get-url','origin')
    if($remote-cnotmatch'^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?$'){throw 'Native recovery historical executor origin is invalid.'};$repository=$Matches[1]
    if((Invoke-NativeRecoveryGit $Root @('rev-parse','--is-shallow-repository'))-cne'false'){throw 'Native recovery historical executor is shallow.'}
    foreach($relative in @('objects/info/alternates','info/grafts')){$p=Invoke-NativeRecoveryGit $Root @('rev-parse','--git-path',$relative);if(-not[IO.Path]::IsPathRooted($p)){$p=Join-Path $Root $p};if(Test-Path -LiteralPath $p){throw 'Native recovery historical object store has alternates/grafts.'}}
    if(Invoke-NativeRecoveryGit $Root @('for-each-ref','--format=%(refname)','refs/replace')){throw 'Native recovery historical replacement refs are forbidden.'}
    $entries=@();$total=0L
    foreach($line in (Invoke-NativeRecoveryGit $Root @('ls-tree','-rlz','--full-tree',$Commit)).Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)){
        if($line-cnotmatch'^(100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64}) +([0-9]+)\t(.+)$'){throw 'Native recovery historical executor contains unsupported entries.'};$size=[long]$Matches[3];$total+=$size
        if($entries.Count-ge4096-or$size-gt16777216-or$total-gt134217728){throw 'Native recovery historical executor exceeds closure bounds.'}
        $entries+=,[ordered]@{path=$Matches[4];mode=$Matches[1];blob=$Matches[2];size=$size}
    }
    $p=[Diagnostics.Process]::new();$p.StartInfo=[Diagnostics.ProcessStartInfo]::new();$p.StartInfo.FileName=(@(Get-Command git -CommandType Application -ErrorAction Stop)[0]).Source;$p.StartInfo.WorkingDirectory=[IO.Path]::GetFullPath($Root);$p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true;$p.StartInfo.RedirectStandardInput=$true;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    foreach($arg in @('--no-optional-locks','--no-pager','--no-replace-objects','-c','core.fsmonitor=false','cat-file','--batch')){$p.StartInfo.ArgumentList.Add($arg)}
    $p.StartInfo.Environment['GIT_CONFIG_NOSYSTEM']='1';$p.StartInfo.Environment['GIT_CONFIG_GLOBAL']=$(if($IsWindows){'NUL'}else{'/dev/null'})
    $memory=[IO.MemoryStream]::new()
    try{
        $null=$p.Start();$read=$p.StandardOutput.BaseStream.CopyToAsync($memory);$err=$p.StandardError.ReadToEndAsync();foreach($entry in $entries){$p.StandardInput.WriteLine($entry.blob)};$p.StandardInput.Close()
        $p.WaitForExit();$null=$read.GetAwaiter().GetResult();$null=$err.GetAwaiter().GetResult();if($p.ExitCode-ne0){throw 'Native recovery historical Git blob inspection failed.'}
        if($memory.Length-gt$total+($entries.Count*160)){throw 'Native recovery historical blob output exceeds bound.'};$memory.Position=0;$artifacts=@()
        foreach($entry in $entries){$header=[Collections.Generic.List[byte]]::new();while(($ch=$memory.ReadByte())-ne10){if($ch-lt0-or$header.Count-ge128){throw 'Native recovery historical blob header is invalid.'};$header.Add([byte]$ch)}
            if([Text.Encoding]::ASCII.GetString($header.ToArray())-cne"$($entry.blob) blob $($entry.size)"){throw 'Native recovery historical blob metadata differs.'}
            $bytes=[byte[]]::new([int]$entry.size);$memory.ReadExactly($bytes);if($memory.ReadByte()-ne10){throw 'Native recovery historical blob frame is invalid.'}
            $algorithm=if($entry.blob.Length-eq40){[Security.Cryptography.HashAlgorithmName]::SHA1}else{[Security.Cryptography.HashAlgorithmName]::SHA256};$hash=[Security.Cryptography.IncrementalHash]::CreateHash($algorithm)
            try{$hash.AppendData([Text.Encoding]::ASCII.GetBytes("blob $($entry.size)"+[char]0));$hash.AppendData($bytes);if([Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()-cne$entry.blob){throw 'Native recovery historical Git object content differs.'}}finally{$hash.Dispose()}
            $artifacts+=,[ordered]@{path=$entry.path;state='present';mode=$entry.mode;size_bytes=$entry.size;sha256=Get-NativeRecoveryDigest $bytes}
        }
        if($memory.Position-ne$memory.Length){throw 'Native recovery historical blob output has trailing data.'}
        [ordered]@{repository=$repository;commit=$Commit;tree=$tree;closure_sha256=Get-NativeRecoveryValueDigest $artifacts;artifacts=$artifacts}
    }finally{$memory.Dispose();$p.Dispose()}
}
function Assert-NativeRecoveryNativeTransaction([string]$Workspace,[string]$IntentPath,[string]$CompletionPath,[switch]$Pending){
    # Use the independently adopted A ledger's structural owner in a separate
    # runspace: importing it must not replace B's loaded native modules.
    $shell=[PowerShell]::Create()
    try{
        $code={param($authority,$workspace,$intentPath,$completionPath,$pending)
            $ErrorActionPreference='Stop';$module=Import-Module (Join-Path $authority 'scripts/lib/MorphospaceTransitionLedger.psm1') -PassThru
            &$module {param($workspace,$intentPath,$completionPath,$pending)
                $intent=Read-MorphospaceLedgerJson $intentPath;Assert-MorphospaceLedgerIntent $intent $intent.transaction_id
                if($intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v6'){throw 'Native recovery requires its exact raw-preimage v6 intent.'}
                $relative=Get-MorphospaceLedgerPath $workspace $intent.transaction_id intent
                if([IO.Path]::GetFullPath((Join-Path $workspace $relative))-ine[IO.Path]::GetFullPath($intentPath)){throw 'Native recovery intent is outside its owned transaction namespace.'}
                if($pending){$null=Assert-MorphospaceLedgerEventPlacement (Join-Path $workspace $intent.events.path) $intent}else{
                    $expectedCompletion=Join-Path $workspace (Get-MorphospaceLedgerPath $workspace $intent.transaction_id completion)
                    if([IO.Path]::GetFullPath($expectedCompletion)-ine[IO.Path]::GetFullPath($completionPath)){throw 'Native recovery completion is outside its owned transaction namespace.'}
                    Assert-MorphospaceLedgerCommittedCompletion $workspace $intent.transaction_id $relative $intentPath $intent $completionPath
                }
            } $workspace $intentPath $completionPath $pending
        }
        $null=$shell.AddScript($code.ToString()).AddArgument($script:NativeAuthorityRoot).AddArgument($Workspace).AddArgument($IntentPath).AddArgument($CompletionPath).AddArgument($Pending.IsPresent)
        $null=$shell.Invoke();if($shell.HadErrors){throw "Native recovery trusted ledger structural proof failed: $($shell.Streams.Error[0].Exception.Message)"}
    }finally{$shell.Dispose()}
}
function Assert-NativeRecoveryTransactionAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Request,[Parameter(Mandatory)][object]$CurrentBindings,[Parameter(Mandatory)][string]$ExecutorRoot,[switch]$Pending)
    $path=[string]$CurrentBindings.request_path;$raw=Read-NativeRecoveryBytes $path;Assert-NativeRecoveryEqual $Request (Read-NativeRecoveryJson $path) 'historical request document'
    $intentPath=[string]$CurrentBindings.execution_intent_path;$intentRaw=Read-NativeRecoveryBytes $intentPath
    if((Get-NativeRecoveryDigest $intentRaw)-cne$CurrentBindings.execution_intent_raw_sha256){throw 'Native recovery original intent raw bytes changed.'}
    $completionPath=if($Pending){''}else{[string]$CurrentBindings.execution_completion_path}
    if(-not$Pending-and(Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $completionPath))-cne$CurrentBindings.execution_completion_raw_sha256){throw 'Native recovery original completion raw bytes changed.'}
    Assert-NativeRecoveryNativeTransaction $WorkspaceRoot $intentPath $completionPath -Pending:$Pending
    $intent=Read-NativeRecoveryJson $intentPath;$completed=if($Pending){$null}else{Read-NativeRecoveryJson $completionPath};$createdAt=[datetimeoffset]::Parse($intent.created_at,[Globalization.CultureInfo]::InvariantCulture);$completedAt=if($Pending){[datetimeoffset]::UtcNow}else{[datetimeoffset]::Parse($completed.completed_at,[Globalization.CultureInfo]::InvariantCulture)}
    $oldReturnRef=$Request.nonpass_custody_defect.return.intent;$oldReturnPath=Resolve-NativeRecoveryPath $WorkspaceRoot ([string]$oldReturnRef.path) -Leaf
    if((Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $oldReturnPath))-cne$oldReturnRef.sha256){throw 'Native recovery original Return intent changed.'}
    $oldReturn=Read-NativeRecoveryJson $oldReturnPath
    if((Test-NativeRecoveryField $intent.target.unit.document 'tooling_context')-or(Test-NativeRecoveryField $oldReturn.target.unit.document 'tooling_context')){throw 'Native NONPASS custody recovery history supports only an uncontexted original unit.'}
    if((Test-NativeRecoveryField $CurrentBindings 'execution_time')-and[datetimeoffset]::Parse($CurrentBindings.execution_time)-ne$createdAt){throw 'Native recovery caller execution time differs from original native intent.'}
    if($completedAt-lt$createdAt){throw 'Native recovery completion precedes its original intent.'}
    $document=Read-NativeRecoveryJson $Request.recovery_authorization.authorization_path;$signed=$document.payload.request;$policy=Get-NativeRecoveryPolicy
    if([datetimeoffset]::Parse($document.payload.issued_at,[Globalization.CultureInfo]::InvariantCulture)-gt$createdAt){throw 'Native recovery authorization was not issued before original execution.'}
    $authority=Get-NativeRecoveryAuthorityIdentity;Assert-NativeRecoveryEqual $signed.authority $authority 'historical independent authority'
    if(-not[string]::Equals([IO.Path]::GetFullPath($Request.recovery_authorization.trusted_authority_root).TrimEnd('\','/'),$script:NativeAuthorityRoot.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Native recovery historical locator differs from adopted authority root.'}
    $executor=if($Pending){Get-NativeRecoverySourceIdentity $ExecutorRoot}else{Get-NativeRecoveryObjectSourceIdentity $ExecutorRoot $signed.executor.commit};Assert-NativeRecoveryEqual $signed.executor $executor 'historical qualified executor'
    $script:ObservedExecutorRoot=$ExecutorRoot
    foreach($at in @($createdAt,$completedAt)){
        $qualification=Assert-NativeRecoveryQualification $Request.recovery_authorization.source_qualification_path $authority $executor $at
        if($qualification-cne$signed.qualification_raw_sha256){throw 'Native recovery historical source qualification original changed.'}
        $expected=[ordered]@{schema='rusty.morphospace.workflow.native_nonpass_recovery_authorization_payload.v1';issuer_id=$policy.issuer_id;authorization_id=$document.payload.authorization_id;issued_at=$document.payload.issued_at;expires_at=$document.payload.expires_at;decision='authorize-native-nonpass-custody-recovery';purpose='nonaccepting-corrective-freeze';request=$signed;limitations=@('no-pass-or-acceptance-credit','no-source-scope-extension','no-publication-or-runtime-authority')}
        $null=Test-ExternalOwnerSignedPayload -DocumentText ([IO.File]::ReadAllText($Request.recovery_authorization.authorization_path)) -ExpectedPayload $expected -Policy $policy -SchemaPath (Join-Path $script:NativeAuthorityRoot 'schemas/native-nonpass-recovery-authorization-v1.schema.json') -Now $at
    }
    if($signed.request_raw_sha256-cne(Get-NativeRecoveryDigest $raw)-or$CurrentBindings.request_raw_sha256-cne$signed.request_raw_sha256-or$signed.project_id-cne$Request.project_id-or$signed.unit_id-cne$Request.unit_id-or$signed.freeze_id-cne$Request.freeze_id-or$signed.failure_tuple_sha256-cne(Get-NativeRecoveryValueDigest $Request.predecessor)-or$signed.defects_sha256-cne(Get-NativeRecoveryValueDigest $Request.nonpass_custody_defect)){throw 'Native recovery historical request/failure/defect binding differs.'}
    $owned=@($intent.artifacts|Where-Object sha256 -CEQ $signed.request_raw_sha256)
    if($owned.Count-ne1-or(Get-NativeRecoveryDigest ([Convert]::FromBase64String($owned[0].bytes_base64)))-cne$signed.request_raw_sha256-or$intent.event.project_id-cne$Request.project_id-or$intent.event.unit_id-cne$Request.unit_id-or$intent.target.unit.document.candidate_freeze.freeze_id-cne$Request.freeze_id-or$intent.target.unit.document.candidate_freeze.receipt_sha256-cne$signed.request_raw_sha256-or$intent.target.unit.document.candidate_freeze.receipt_path-cne$owned[0].path){throw 'Native recovery request is not the exact native owned artifact/target.'}
    $original=$signed.current_bindings
    if($intent.pre_state_raw.sha256-cne$original.state_raw_sha256-or$intent.pre_unit_raw.sha256-cne$original.unit_raw_sha256-or$intent.expected.events_sha256-cne$original.events_raw_sha256-or$intent.expected.events_length-ne$original.events_length-or$intent.expected.event_tail_id-cne$original.event_tail_id){throw 'Native recovery original signed CAS differs from native intent.'}
    foreach($pair in @(@('project.spec.json','project_raw_sha256'),@('feature.lock.json','feature_lock_raw_sha256'))){$projection=@($intent.additional_projections|Where-Object path -CEQ $pair[0]);if($projection.Count-ne1-or$projection[0].pre_raw_sha256-cne$original.($pair[1])){throw 'Native recovery original signed control differs from native intent.'}}
    foreach($pair in @(@($Request.expected.source_composition_path,'source_composition_raw_sha256'),@($Request.expected.repository_map_path,'repository_map_raw_sha256'))){if((Get-NativeRecoveryDigest (Read-NativeRecoveryBytes (Resolve-NativeRecoveryPath $WorkspaceRoot $pair[0] -Leaf)))-cne$original.($pair[1])){throw 'Native recovery immutable historical source/map binding changed.'}}
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');$workspaceDigest=Get-NativeRecoveryDigest ([Text.Encoding]::UTF8.GetBytes($(if($IsWindows){$workspace.ToUpperInvariant()}else{$workspace})))
    if($workspaceDigest-cne$original.workspace_path_sha256){throw 'Native recovery historical workspace identity changed.'}
    Assert-NativeRecoveryEqual $Request.final_repositories $original.final_repositories 'historical final repositories'
    if($Pending){
        foreach($pair in @(@('workspace.state.json','state','state_raw_sha256'),@("iteration-units/$($Request.unit_id).json",'unit','unit_raw_sha256'))){$file=Resolve-NativeRecoveryPath $WorkspaceRoot $pair[0] -Leaf;$observed=Read-NativeRecoveryBytes $file;if((Get-NativeRecoveryDigest $observed)-cne$original.($pair[2])-and(Get-NativeRecoveryProjectionDigest (Read-NativeRecoveryJson $file))-cne$intent.target.($pair[1]).sha256){throw 'Native recovery pending projection is neither exact original nor native target.'}}
        foreach($pair in @(@('project.spec.json','project_raw_sha256'),@('feature.lock.json','feature_lock_raw_sha256'))){$file=Resolve-NativeRecoveryPath $WorkspaceRoot $pair[0] -Leaf;$projection=@($intent.additional_projections|Where-Object path -CEQ $pair[0])[0];if((Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $file))-cne$original.($pair[1])-and(Get-NativeRecoveryProjectionDigest (Read-NativeRecoveryJson $file))-cne$projection.target_sha256){throw 'Native recovery pending control is neither exact original nor native target.'}}
    }
    [ordered]@{schema='rusty.morphospace.workflow.native_nonpass_recovery_assessment.v1';authorization_id=$document.payload.authorization_id;request_raw_sha256=$signed.request_raw_sha256;authority=$authority;executor=$executor;executed=$false;historical=(-not$Pending);pending=$Pending.IsPresent;execution_created_at=$intent.created_at;execution_completed_at=$(if($Pending){$null}else{$completed.completed_at});acceptance_authority=$false;publication_authority=$false}
}
function Assert-MorphospaceNativeNonpassRecoveryHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Request,[Parameter(Mandatory)][object]$CurrentBindings,[Parameter(Mandatory)][string]$ExecutorRoot)
    Assert-NativeRecoveryTransactionAuthorization -WorkspaceRoot $WorkspaceRoot -Request $Request -CurrentBindings $CurrentBindings -ExecutorRoot $ExecutorRoot
}
function Invoke-NativeNonpassRecoveryAuthority {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ExecutorRoot,[switch]$Execute)
    Open-NativeRecoverySourceScope -WorkspaceRoot $WorkspaceRoot -RequestPath $RequestPath -ExecutorRoot $ExecutorRoot
    try{
        $request=Read-NativeRecoveryJson $RequestPath;$bindings=Get-NativeRecoveryCurrentBindings $WorkspaceRoot $request;$bindings.request_raw_sha256=Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $RequestPath);$bindings.request_path=$RequestPath
        $assessment=Assert-MorphospaceNativeNonpassRecoveryAuthorization -WorkspaceRoot $WorkspaceRoot -Request $request -CurrentBindings $bindings -ExecutorRoot $ExecutorRoot
        if(-not$Execute){return $assessment}
        Assert-NativeRecoverySourceScope -WorkspaceRoot $WorkspaceRoot -RequestPath $RequestPath -ExecutorRoot $ExecutorRoot
        # Fixed native entrypoint and argument vector: no caller command, shell,
        # inherited authority token or candidate-selected policy loader.
        $entry=Resolve-NativeRecoveryPath $ExecutorRoot 'scripts/Invoke-WorkUnitAutomation.ps1' -Leaf
        $child=[Diagnostics.Process]::new();$child.StartInfo=[Diagnostics.ProcessStartInfo]::new();$child.StartInfo.FileName=(Get-Process -Id $PID).Path;$child.StartInfo.WorkingDirectory=[IO.Path]::GetFullPath($ExecutorRoot);$child.StartInfo.UseShellExecute=$false;$child.StartInfo.CreateNoWindow=$true;$child.StartInfo.RedirectStandardOutput=$true;$child.StartInfo.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-NonInteractive','-File',$entry,'-Action','FreezeCandidate','-WorkspaceRoot',[IO.Path]::GetFullPath($WorkspaceRoot),'-UnitId',[string]$request.unit_id,'-CandidateFreeze',[IO.Path]::GetFullPath($RequestPath),'-ExpectedCandidateFreezeSha256',$assessment.request_raw_sha256,'-OutPath',(Resolve-NativeRecoveryPath $WorkspaceRoot "receipts/$($request.freeze_id).json"),'-Execute')){$child.StartInfo.ArgumentList.Add($arg)}
        foreach($key in @($child.StartInfo.Environment.Keys)){if($key-match'^(GIT_|RUSTY_|PSModulePath$|POWERSHELL_TELEMETRY_OPTOUT$)'){$child.StartInfo.Environment.Remove($key)|Out-Null}}
        # Source handles remain held until real exit and both stream EOFs. Native
        # B must independently recheck C and live CAS before its first write.
        try{$null=$child.Start();$stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync();$child.WaitForExit();$out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult();$assessment.executed=$true;$assessment.exit_code=$child.ExitCode;$assessment.stdout=$out;$assessment.stderr=$err;return $assessment}finally{$child.Dispose()}
    }finally{Close-NativeRecoverySourceScope}
}
Export-ModuleMember -Function New-NativeNonpassRecoveryAuthorizationRequest, Assert-MorphospaceNativeNonpassRecoveryAuthorization, Assert-MorphospaceNativeNonpassRecoveryHistory, Invoke-NativeNonpassRecoveryAuthority
