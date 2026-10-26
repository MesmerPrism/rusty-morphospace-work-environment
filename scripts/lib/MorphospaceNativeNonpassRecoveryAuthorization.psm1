Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
$script:RecoveryExecutorRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:RecoverySourceScope=$null

function Assert-RecoveryAuthorityPhysicalPath([string]$Path){
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            if(((Get-Item -LiteralPath $cursor -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Recovery authority aliases and reparse points are forbidden.'}
        }
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent-ceq$cursor){break};$cursor=$parent
    }
}
function Invoke-RecoveryAuthorityGit([string]$Root,[string[]]$Arguments){
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=[Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName=(@(Get-Command git -CommandType Application -ErrorAction Stop)[0]).Source
    $process.StartInfo.WorkingDirectory=$Root;$process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
    foreach($name in @($process.StartInfo.Environment.Keys)){if($name-match'^GIT_'){$process.StartInfo.Environment.Remove($name)|Out-Null}}
    $process.StartInfo.Environment['GIT_CONFIG_NOSYSTEM']='1'
    $process.StartInfo.Environment['GIT_CONFIG_GLOBAL']=if($IsWindows){'NUL'}else{'/dev/null'}
    foreach($argument in @('--no-optional-locks','--no-pager','--no-replace-objects','-c','core.fsmonitor=false','-c','core.hooksPath=','-c','diff.external=')+$Arguments){$process.StartInfo.ArgumentList.Add($argument)}
    try{
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
        $result=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode-ne0){throw 'Recovery authority Git identity inspection failed.'}
        $result.TrimEnd("`r","`n")
    }finally{$process.Dispose()}
}
function Assert-RecoverySourceScope([string]$WorkspaceRoot){
    $scope=$script:RecoverySourceScope
    if($null-eq$scope){throw 'Native recovery source scope is not open.'}
    if($scope.thread_id-ne[Threading.Thread]::CurrentThread.ManagedThreadId-or-not[string]::Equals([IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/'),$scope.workspace,[StringComparison]::OrdinalIgnoreCase)){throw 'Native recovery source scope cannot cross its owning thread or workspace.'}
    if((Get-MorphospaceFileSha256 $scope.binding_path)-cne$scope.binding_sha256){throw 'Native recovery adopted authority binding changed during its source scope.'}
    $authorityModule=$scope.authority.module
    $null=&$authorityModule {param($w,$p,$e) Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $p -ExecutorRoot $e} $scope.workspace $scope.request $script:RecoveryExecutorRoot
}
function Assert-RecoveryBindingProgramOrigin([byte[]]$Raw){
    $root=$script:RecoveryExecutorRoot
    Assert-RecoveryAuthorityPhysicalPath $root
    $top=Invoke-RecoveryAuthorityGit $root @('rev-parse','--show-toplevel')
    if(-not[string]::Equals([IO.Path]::GetFullPath($top).TrimEnd('\','/'),$root.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Native recovery binding program is not its exact Git root.'}
    if((Invoke-RecoveryAuthorityGit $root @('rev-parse','--is-shallow-repository'))-cne'false'){throw 'Native recovery binding program has shallow history.'}
    foreach($relative in @('objects/info/alternates','info/grafts')){
        $path=Invoke-RecoveryAuthorityGit $root @('rev-parse','--git-path',$relative)
        if(-not[IO.Path]::IsPathRooted($path)){$path=Join-Path $root $path}
        if(Test-Path -LiteralPath $path){throw 'Native recovery binding program has alternate or graft history.'}
    }
    if(Invoke-RecoveryAuthorityGit $root @('for-each-ref','--format=%(refname)','refs/replace')){throw 'Native recovery binding program has replacement refs.'}
    if(Invoke-RecoveryAuthorityGit $root @('status','--porcelain=v2','--untracked-files=all')){throw 'Native recovery binding program must be clean before authority import.'}
    $head=Invoke-RecoveryAuthorityGit $root @('rev-parse','HEAD')
    $entry=Invoke-RecoveryAuthorityGit $root @('ls-tree','-l','HEAD','--','config/native-nonpass-recovery-authority-binding.json')
    if($entry-cnotmatch'^(100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64}) +([0-9]+)\tconfig/native-nonpass-recovery-authority-binding\.json$'){throw 'Native recovery binding is not a committed regular program file.'}
    $blob=$Matches[2];$length=[long]$Matches[3]
    if($length-ne$Raw.LongLength){throw 'Native recovery binding differs from its committed program blob.'}
    $algorithm=if($blob.Length-eq40){[Security.Cryptography.HashAlgorithmName]::SHA1}else{[Security.Cryptography.HashAlgorithmName]::SHA256}
    $hash=[Security.Cryptography.IncrementalHash]::CreateHash($algorithm)
    try{
        $hash.AppendData([Text.Encoding]::ASCII.GetBytes("blob $length"+[char]0));$hash.AppendData($Raw)
        if([Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()-cne$blob){throw 'Native recovery binding differs from its committed program blob.'}
    }finally{$hash.Dispose()}
    if((Invoke-RecoveryAuthorityGit $root @('rev-parse','HEAD'))-cne$head-or(Invoke-RecoveryAuthorityGit $root @('status','--porcelain=v2','--untracked-files=all'))){throw 'Native recovery binding program changed during authentication.'}
}
function Open-PinnedRecoveryAuthority([object]$Request,[string]$WorkspaceRoot){
    $bindingPath=Join-Path $script:RecoveryExecutorRoot 'config/native-nonpass-recovery-authority-binding.json'
    Assert-RecoveryAuthorityPhysicalPath $bindingPath
    $bindingHold=[IO.File]::Open($bindingPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($bindingHold.Length-gt16777216){throw 'Native recovery authority binding exceeds its protocol byte bound.'}
        $raw=[byte[]]::new([int]$bindingHold.Length);$bindingHold.ReadExactly($raw)
        $binding=ConvertFrom-MorphospaceProtocolJsonBytes $raw
        Assert-MorphospaceExactPropertySet $binding @('schema','authorities') @() 'Recovery authority binding'
        if(@($binding.authorities).Count-eq0){throw 'Independent native recovery authority has not been adopted in this executor.'}
        if([string]$binding.schema-cne'rusty.morphospace.workflow.native_nonpass_recovery_authority_binding.v2'){throw 'Configured native recovery authority binding version is unsupported.'}
        if($null-eq$script:RecoverySourceScope){Assert-RecoveryBindingProgramOrigin $raw}
        $authority=Open-PinnedRecoveryAuthorityCore $Request $WorkspaceRoot $binding
        $authority.holds=@($authority.holds)+@($bindingHold)
        $authority|Add-Member -NotePropertyName binding_sha256 -NotePropertyValue (Get-MorphospaceSha256Bytes $raw)
        $bindingHold=$null
        return $authority
    }finally{if($null-ne$bindingHold){$bindingHold.Dispose()}}
}
function Open-PinnedRecoveryAuthorityCore([object]$Request,[string]$WorkspaceRoot,[object]$binding){
    Assert-MorphospaceExactPropertySet $binding @('schema','authorities') @() 'Recovery authority binding'
    if(@($binding.authorities).Count-eq0){throw 'Independent native recovery authority has not been adopted in this executor.'}
    if([string]$binding.schema-cne'rusty.morphospace.workflow.native_nonpass_recovery_authority_binding.v2'){throw 'Configured native recovery authority binding version is unsupported.'}
    $root=[IO.Path]::GetFullPath([string]$Request.recovery_authorization.trusted_authority_root).TrimEnd('\','/')
    if($null-ne$script:RecoverySourceScope){
        Assert-RecoverySourceScope $WorkspaceRoot
        $active=$script:RecoverySourceScope.authority
        if([string]::Equals($root,$active.root,[StringComparison]::OrdinalIgnoreCase)){
            # Only immutable source facts are reused. The actual C/Q record,
            # signature, transaction and current control checks still run.
            return [pscustomobject]@{module=$active.module;holds=@();root=$active.root;commit=$active.commit;borrowed=$true}
        }
    }
    Assert-RecoveryAuthorityPhysicalPath $root
    $top=Invoke-RecoveryAuthorityGit $root @('rev-parse','--show-toplevel')
    if(-not[string]::Equals([IO.Path]::GetFullPath($top).TrimEnd('\','/'),$root,[StringComparison]::OrdinalIgnoreCase)){throw 'Recovery authority locator is not an exact Git root.'}
    $commit=Invoke-RecoveryAuthorityGit $root @('rev-parse','HEAD')
    $anchors=@($binding.authorities|Where-Object { [string]$_.commit-ceq$commit })
    if($anchors.Count-ne1){throw 'Recovery authority locator does not match an independently adopted source.'}
    $anchor=$anchors[0]
    Assert-MorphospaceExactPropertySet $anchor @('repository','commit','tree','entrypoint','artifacts') @() 'Recovery authority source anchor'
    if([string]$anchor.repository-cne'MesmerPrism/rusty-morphospace-work-environment'-or[string]$anchor.commit-cnotmatch'^[0-9a-f]{40}$'-or[string]$anchor.tree-cnotmatch'^[0-9a-f]{40}$'){throw 'Recovery authority source anchor is invalid.'}
    $origin=Invoke-RecoveryAuthorityGit $root @('remote','get-url','origin')
    if($origin-cne"https://github.com/$($anchor.repository).git"-and$origin-cne"https://github.com/$($anchor.repository)"){throw 'Recovery authority repository origin differs from its adopted owner.'}
    if((Invoke-RecoveryAuthorityGit $root @('rev-parse','HEAD^{tree}'))-cne[string]$anchor.tree-or(Invoke-RecoveryAuthorityGit $root @('rev-parse','--is-shallow-repository'))-cne'false'){throw 'Recovery authority Git tree or history is detached.'}
    if(Invoke-RecoveryAuthorityGit $root @('status','--porcelain=v2','--untracked-files=all')){throw 'Recovery authority source must be clean.'}
    if(Invoke-RecoveryAuthorityGit $root @('for-each-ref','--format=%(refname)','refs/replace')){throw 'Recovery authority replacement refs are forbidden.'}
    foreach($relative in @('objects/info/alternates','info/grafts')){
        $path=Invoke-RecoveryAuthorityGit $root @('rev-parse','--git-path',$relative)
        if(-not[IO.Path]::IsPathRooted($path)){$path=Join-Path $root $path}
        if(Test-Path -LiteralPath $path){throw 'Recovery authority alternate or graft history is forbidden.'}
    }
    $holds=[Collections.Generic.List[IO.FileStream]]::new()
    try{
        $entries=(Invoke-RecoveryAuthorityGit $root @('-c','core.quotePath=false','ls-tree','-rlz','--full-tree','HEAD')).Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)
        if($entries.Count-ne@($anchor.artifacts).Count-or$entries.Count-eq0){throw 'Recovery authority complete artifact set differs.'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in $entries){
            if($entry-cnotmatch'^(100644|100755) blob ([0-9a-f]{40}) +([0-9]+)\t(.+)$'){throw 'Recovery authority has an unsupported tree entry.'}
            $mode=$Matches[1];$blob=$Matches[2];$length=[long]$Matches[3];$relative=$Matches[4]
            if(-not$seen.Add($relative)-or$relative-cmatch'(^|/)\.\.(/|$)|[\\:\x00-\x1f\x7f]'-or[IO.Path]::IsPathRooted($relative)){throw 'Recovery authority artifact path is unsafe or ambiguous.'}
            $rows=@($anchor.artifacts|Where-Object { [string]$_.path-ceq$relative })
            if($rows.Count-ne1){throw 'Recovery authority artifact is absent from its exact source anchor.'}
            $row=$rows[0];Assert-MorphospaceExactPropertySet $row @('path','mode','size_bytes','sha256') @() 'Recovery authority artifact'
            if([string]$row.mode-cne$mode-or[long]$row.size_bytes-ne$length-or[string]$row.sha256-cnotmatch'^[0-9a-f]{64}$'){throw 'Recovery authority artifact metadata differs.'}
            $path=[IO.Path]::GetFullPath((Join-Path $root $relative));Assert-RecoveryAuthorityPhysicalPath $path
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($stream)
            if($stream.Length-ne$length){throw 'Recovery authority physical artifact length differs.'}
            $gitHash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
            $rawHash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            try{
                $gitHash.AppendData([Text.Encoding]::ASCII.GetBytes("blob $length"+[char]0));$buffer=[byte[]]::new(65536)
                while(($count=$stream.Read($buffer,0,$buffer.Length))-gt0){$gitHash.AppendData($buffer,0,$count);$rawHash.AppendData($buffer,0,$count)}
                if([Convert]::ToHexString($gitHash.GetHashAndReset()).ToLowerInvariant()-cne$blob-or[Convert]::ToHexString($rawHash.GetHashAndReset()).ToLowerInvariant()-cne[string]$row.sha256){throw 'Recovery authority physical source bytes differ from its adopted Git closure.'}
            }finally{$gitHash.Dispose();$rawHash.Dispose()}
        }
        if((Invoke-RecoveryAuthorityGit $root @('rev-parse','HEAD'))-cne$commit-or(Invoke-RecoveryAuthorityGit $root @('status','--porcelain=v2','--untracked-files=all'))){throw 'Recovery authority changed during authentication.'}
        $entrypoint=$anchor.entrypoint
        if($entrypoint-isnot[string]-or-not$entrypoint.StartsWith('scripts/lib/',[StringComparison]::Ordinal)-or$entrypoint-cnotmatch'^(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.psm1$'-or$entrypoint-cmatch'(^|/)\.\.?(/|$)'){throw 'Recovery authority entrypoint is not a canonical native module path.'}
        $authorityModuleRows=@($anchor.artifacts|Where-Object { [string]$_.path-ceq$entrypoint })
        if($authorityModuleRows.Count-ne1){throw 'Recovery authority fixed module is absent from its verified source anchor.'}
        $authorityModulePath=Join-Path $root ([string]$authorityModuleRows[0].path)
        $modules=@(Import-Module $authorityModulePath -PassThru -Scope Local -Force)
        if($modules.Count-ne1){throw 'Recovery authority entrypoint did not load exactly one module.'}
        $module=$modules[0]
        foreach($name in @('New-NativeNonpassRecoveryAuthorizationRequest','Assert-MorphospaceNativeNonpassRecoveryAuthorization','Assert-MorphospaceNativeNonpassRecoveryHistory','Invoke-NativeNonpassRecoveryAuthority')){
            if(-not$module.ExportedCommands.ContainsKey($name)-or$module.ExportedCommands[$name].CommandType-ne[Management.Automation.CommandTypes]::Function){throw 'Recovery authority entrypoint lacks its fixed native function interface.'}
        }
        return [pscustomobject]@{module=$module;holds=$holds;root=$root;commit=$commit;borrowed=$false}
    }catch{foreach($stream in $holds){$stream.Dispose()};throw}
}
function Open-MorphospaceNativeNonpassRecoverySourceScope {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ExecutorRoot)
    if($null-ne$script:RecoverySourceScope){throw 'Native recovery source scope cannot nest.'}
    if(-not[string]::Equals([IO.Path]::GetFullPath($ExecutorRoot).TrimEnd('\','/'),$script:RecoveryExecutorRoot.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Native recovery source scope cannot choose a different executor binding.'}
    $request=Read-MorphospaceProtocolJson $RequestPath
    if([string]$request.schema-cne'rusty.morphospace.workflow.candidate_freeze.v4'){throw 'Native recovery source scope requires its actual v4 input.'}
    $authority=Open-PinnedRecoveryAuthority $request $WorkspaceRoot
    $authorityModule=$authority.module
    $opened=$false
    try{
        $null=&$authorityModule {param($w,$p,$e) Open-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $p -ExecutorRoot $e} $WorkspaceRoot $RequestPath $ExecutorRoot
        $opened=$true
        $bindingPath=Join-Path $script:RecoveryExecutorRoot 'config/native-nonpass-recovery-authority-binding.json'
        $script:RecoverySourceScope=[pscustomobject]@{authority=$authority;workspace=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/');request=[IO.Path]::GetFullPath($RequestPath);binding_path=$bindingPath;binding_sha256=$authority.binding_sha256;thread_id=[Threading.Thread]::CurrentThread.ManagedThreadId}
        Assert-RecoverySourceScope $WorkspaceRoot
    }catch{
        $script:RecoverySourceScope=$null
        try{if($opened){$null=&$authorityModule {Close-NativeRecoverySourceScope}}}finally{foreach($stream in $authority.holds){$stream.Dispose()}}
        throw
    }
}
function Close-MorphospaceNativeNonpassRecoverySourceScope {
    $scope=$script:RecoverySourceScope
    if($null-eq$scope){return}
    if($scope.thread_id-ne[Threading.Thread]::CurrentThread.ManagedThreadId){throw 'Native recovery source scope belongs to another thread.'}
    $script:RecoverySourceScope=$null
    $authorityModule=$scope.authority.module
    try{$null=&$authorityModule {Close-NativeRecoverySourceScope}}finally{foreach($stream in $scope.authority.holds){$stream.Dispose()}}
}
function Assert-MorphospaceNativeNonpassRecoveryAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Request,[Parameter(Mandatory)][object]$CurrentBindings,[Parameter(Mandatory)][string]$ExecutorRoot)
    if(-not[string]::Equals([IO.Path]::GetFullPath($ExecutorRoot).TrimEnd('\','/'),$script:RecoveryExecutorRoot.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Native recovery executor cannot select a different authority binding.'}
    $authority=Open-PinnedRecoveryAuthority $Request $WorkspaceRoot
    $authorityModule=$authority.module
    try{
        $null=&$authorityModule {param($w,$r,$c,$e) Assert-MorphospaceNativeNonpassRecoveryAuthorization -WorkspaceRoot $w -Request $r -CurrentBindings $c -ExecutorRoot $e} $WorkspaceRoot $Request $CurrentBindings $ExecutorRoot
    }finally{foreach($stream in $authority.holds){$stream.Dispose()}}
}
function Assert-MorphospaceHistoricalNativeNonpassRecoveryAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Request,[Parameter(Mandatory)][object]$Intent,[Parameter(Mandatory)][object]$Completion,[Parameter(Mandatory)][object]$ExecutorOrigin)
    $bindings=[ordered]@{request_path=[string]$ExecutorOrigin.request_path;request_raw_sha256=[string]$ExecutorOrigin.request_raw_sha256;execution_intent_path=[string]$ExecutorOrigin.intent_path;execution_intent_raw_sha256=[string]$ExecutorOrigin.intent_raw_sha256;execution_completion_path=[string]$ExecutorOrigin.completion_path;execution_completion_raw_sha256=[string]$ExecutorOrigin.completion_raw_sha256;execution_time=[string]$Intent.created_at}
    foreach($row in @(@($bindings.execution_intent_path,$bindings.execution_intent_raw_sha256,$Intent),@($bindings.execution_completion_path,$bindings.execution_completion_raw_sha256,$Completion))){
        if((Get-MorphospaceFileSha256 $row[0])-cne$row[1]-or(Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $row[0]))-cne(Get-MorphospaceCanonicalJsonSha256 $row[2])){throw 'Native recovery historical transition bytes differ from the committed proof.'}
    }
    if([string]$Completion.transaction_id-cne[string]$Intent.transaction_id-or[string]$Completion.event_id-cne[string]$Intent.event.event_id-or[string]$Completion.status-cne'committed'-or[DateTimeOffset]::Parse([string]$Completion.completed_at)-lt[DateTimeOffset]::Parse([string]$Intent.created_at)){throw 'Native recovery historical execution chronology is invalid.'}
    $authority=Open-PinnedRecoveryAuthority $Request $WorkspaceRoot
    $authorityModule=$authority.module
    try{
        $null=&$authorityModule {param($w,$r,$c,$e) Assert-MorphospaceNativeNonpassRecoveryHistory -WorkspaceRoot $w -Request $r -CurrentBindings $c -ExecutorRoot $e} $WorkspaceRoot $Request $bindings $script:RecoveryExecutorRoot
    }finally{foreach($stream in $authority.holds){$stream.Dispose()}}
}
Export-ModuleMember -Function Assert-MorphospaceNativeNonpassRecoveryAuthorization,Assert-MorphospaceHistoricalNativeNonpassRecoveryAuthorization
