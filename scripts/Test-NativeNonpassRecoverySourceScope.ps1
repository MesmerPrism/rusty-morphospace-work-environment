param([switch]$SelfTest,[switch]$WithoutScopedReuse,[switch]$ReopenOwnerRequestPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('native-recovery-source-scope-'+[guid]::NewGuid().ToString('N'))
$module=$null;$breakpoint=$null;$global:NativeRecoveryScopePhysicalObservations=0
function Scope-Git([string]$At,[string[]]$Argv){$out=@(&(@(Get-Command git -CommandType Application)[0]).Source -C $At @Argv 2>&1);if($LASTEXITCODE-ne0){throw "Scope fixture Git failed: $($out-join' ')"};($out-join"`n").Trim()}
function Scope-Refuses([string]$Label,[scriptblock]$Action){$caught=$null;try{&$Action|Out-Null}catch{$caught=$_};if($null-eq$caught-or$caught.Exception-is[Management.Automation.CommandNotFoundException]){throw "Source scope did not refuse $Label."}}
try{
    $a=Join-Path $root 'authority';$b=Join-Path $root 'executor';$w=Join-Path $root 'workspace';$request=Join-Path $root 'request.json'
    foreach($at in @($a,$b,$w)){[IO.Directory]::CreateDirectory($at)|Out-Null}
    foreach($path in @('scripts/lib/NativeNonpassRecoveryAuthority.psm1','scripts/lib/ExternalOwnerAuthorization.psm1','config/native-nonpass-recovery-authority.json')){$dest=Join-Path $a $path;[IO.Directory]::CreateDirectory((Split-Path $dest -Parent))|Out-Null;[IO.File]::Copy((Join-Path $source $path),$dest)}
    if($WithoutScopedReuse){
        # Causal negative control in the disposable source only: retain every
        # real guard while forcing complete physical observation on each use.
        $fixtureModule=Join-Path $a 'scripts/lib/NativeNonpassRecoveryAuthority.psm1';$text=[IO.File]::ReadAllText($fixtureModule);$needle='if($IsWindows-and$null-ne$script:NativeSourceScopeOwner-and$null-ne$script:NativeSourceScope-and$script:NativeSourceScope.ContainsKey($rootPath))'
        if(-not$text.Contains($needle,[StringComparison]::Ordinal)){throw 'Scoped reuse boundary missing.'};[IO.File]::WriteAllText($fixtureModule,$text.Replace($needle,$needle.Replace('$IsWindows-and','$false-and')),[Text.UTF8Encoding]::new($false))
    }
    if($ReopenOwnerRequestPath){
        # Reproduce the old lifetime bug only in disposable test source.
        $fixtureModule=Join-Path $a 'scripts/lib/NativeNonpassRecoveryAuthority.psm1';$text=[IO.File]::ReadAllText($fixtureModule);$begin=$text.IndexOf('    $held=$owner.request_hold',[StringComparison]::Ordinal);$end=$text.IndexOf('    foreach($stream in $owner.files)',$begin,[StringComparison]::Ordinal)
        if($begin-lt0-or$end-le$begin){throw 'Held request-data boundary missing.'}
        $legacy='    if((Get-NativeRecoveryDigest (Read-NativeRecoveryBytes $owner.request))-cne$owner.request_raw_sha256){throw ''Native recovery source scope original request changed.''}'+"`n"
        [IO.File]::WriteAllText($fixtureModule,($text.Substring(0,$begin)+$legacy+$text.Substring($end)),[Text.UTF8Encoding]::new($false))
    }
    [IO.Directory]::CreateDirectory((Join-Path $b 'src/nested'))|Out-Null;[IO.File]::WriteAllText((Join-Path $b 'src/nested/code.ps1'),"'held code'`n");[IO.File]::WriteAllText($request,'{"schema":"rusty.morphospace.workflow.candidate_freeze.v4"}')
    foreach($at in @($a,$b)){Scope-Git $at @('init','-b','main')|Out-Null;Scope-Git $at @('config','user.name','Fixture')|Out-Null;Scope-Git $at @('config','user.email','fixture@example.invalid')|Out-Null;Scope-Git $at @('config','core.autocrlf','false')|Out-Null;Scope-Git $at @('remote','add','origin','https://github.com/MesmerPrism/rusty-morphospace-work-environment.git')|Out-Null;Scope-Git $at @('add','--all')|Out-Null;Scope-Git $at @('commit','-m','actual source fixture')|Out-Null}
    $path=Join-Path $a 'scripts/lib/NativeNonpassRecoveryAuthority.psm1';$module=Import-Module $path -PassThru -Force
    $line=@(Get-Content -LiteralPath $path);$loop=1+[array]::FindIndex($line,[Predicate[string]]{param($s)$s.Contains('$rows=[Collections.Generic.List[object]]::new();$total=0L')})
    if($loop-lt1){throw 'Source observation boundary missing.'}
    $breakpoint=Set-PSBreakpoint -Script $path -Line $loop -Action {$global:NativeRecoveryScopePhysicalObservations++}
    &$module {param($w,$r,$b)Open-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b
    if($global:NativeRecoveryScopePhysicalObservations-ne2){throw 'Opening scope did not independently observe both complete sources.'}
    for($i=0;$i-lt3;$i++){&$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b}
    $expected=if($IsWindows){2}else{8};if($global:NativeRecoveryScopePhysicalObservations-ne$expected){throw "Repeated source proof physical observation count expected $expected; actual $global:NativeRecoveryScopePhysicalObservations."}
    Scope-Refuses 'nested scope' {&$module {param($w,$r,$b)Open-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b}
    Scope-Refuses 'cross workspace' {&$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $root $request $b}
    Scope-Refuses 'cross executor' {&$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $a}
    $other=Join-Path $root 'other-request.json';[IO.File]::Copy($request,$other)
    Scope-Refuses 'cross request' {&$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $other $b}
    if($IsWindows){Scope-Refuses 'held original request write' {[IO.File]::WriteAllText($request,'{"schema":"changed-scope-fixture"}')}}else{
        [IO.File]::WriteAllText($request,'{"schema":"changed-scope-fixture"}');Scope-Refuses 'changed held request data' {&$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b};[IO.File]::WriteAllText($request,'{"schema":"rusty.morphospace.workflow.candidate_freeze.v4"}')
    }
    $movedRequest=Join-Path $root 'installed-request.json';[IO.File]::Move($request,$movedRequest)
    &$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b
    [IO.File]::Move($movedRequest,$request)
    if($IsWindows){
        foreach($leaf in @((Join-Path $a 'config/native-nonpass-recovery-authority.json'),(Join-Path $a 'scripts/lib/NativeNonpassRecoveryAuthority.psm1'),(Join-Path $b 'src/nested/code.ps1'))){Scope-Refuses 'held source write' {[IO.File]::WriteAllText($leaf,'changed')}}
        foreach($directory in @((Join-Path $b 'src/nested'),$b,$root)){Scope-Refuses 'held directory rename/replacement' {[IO.Directory]::Move($directory,($directory+'-moved'))}}
    }
    $old=Scope-Git $b @('rev-parse','HEAD');Scope-Git $b @('commit','--allow-empty','-m','changed metadata')|Out-Null
    Scope-Refuses 'changed HEAD' {&$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b};Scope-Git $b @('reset','--soft',$old)|Out-Null
    Scope-Git $b @('remote','set-url','origin','https://github.com/Other/changed.git')|Out-Null
    Scope-Refuses 'changed origin' {&$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b};Scope-Git $b @('remote','set-url','origin','https://github.com/MesmerPrism/rusty-morphospace-work-environment.git')|Out-Null
    $extra=Join-Path $b 'unexpected-source.txt';[IO.File]::WriteAllText($extra,'unexpected source')
    Scope-Refuses 'new untracked source' {&$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b};[IO.File]::Delete($extra)
    $envPresent=[Environment]::GetEnvironmentVariables().Contains('GIT_INDEX_FILE');$envBefore=[Environment]::GetEnvironmentVariable('GIT_INDEX_FILE')
    try{foreach($selector in @((Join-Path $root 'untrusted-index'),'')){[Environment]::SetEnvironmentVariable('GIT_INDEX_FILE',$selector);Scope-Refuses 'inherited Git selector including empty' {&$module {param($w,$r,$b)Assert-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b}}}finally{if($envPresent){[Environment]::SetEnvironmentVariable('GIT_INDEX_FILE',$envBefore)}else{Remove-Item -LiteralPath 'Env:GIT_INDEX_FILE' -ErrorAction SilentlyContinue}}
    &$module {Close-NativeRecoverySourceScope}
    [IO.File]::WriteAllText($request,'{"schema":"rusty.morphospace.workflow.candidate_freeze.v4"}')
    if($IsWindows){$nested=Join-Path $b 'src/nested';[IO.Directory]::Move($nested,($nested+'-moved'));[IO.Directory]::Move(($nested+'-moved'),$nested)}
    $code=Join-Path $b 'src/nested/code.ps1';[IO.File]::WriteAllText($code,"'changed after release'`n")
    Scope-Refuses 'source mutation after release' {&$module {param($p)Get-NativeRecoverySourceIdentity $p} $b}
    Scope-Refuses 'failed open with dirty executor' {&$module {param($w,$r,$b)Open-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $w $request $b}
    $policy=Join-Path $a 'config/native-nonpass-recovery-authority.json';$policyBytes=[IO.File]::ReadAllBytes($policy);[IO.File]::WriteAllBytes($policy,$policyBytes)
    [IO.File]::WriteAllText($code,"'held code'`n")
    &$module {param($w,$r,$b)Open-NativeRecoverySourceScope -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b;Close-NativeRecoverySourceScope} $w $request $b
    [ordered]@{schema='rusty.morphospace.test.native_recovery_source_scope.v1';result='pass';platform_reuses_held_physical_closure=[bool]$IsWindows;complete_observations_before_reuse=2;complete_observations_after_three_reuses=$expected;fresh_git_identity_refusals=$true;directory_rename_refused=[bool]$IsWindows;cross_scope_refused=$true;held_owner_data_survives_native_rename=$true;handles_released=$true;failed_open_releases_handles=$true;source_mutation_refused=$true}|ConvertTo-Json
}catch{
    Write-Error -Message ("Scope fixture failure at: "+$_.ScriptStackTrace) -ErrorAction Continue
    foreach($at in @($a,$b)){Write-Error -Message ("Scope fixture Git status: "+(Scope-Git $at @('status','--porcelain=v2','--untracked-files=all'))) -ErrorAction Continue};throw
}finally{
    if($module){&$module {if($null-ne(Get-Command Close-NativeRecoverySourceScope -ErrorAction SilentlyContinue)){Close-NativeRecoverySourceScope}}}
    if($breakpoint){Remove-PSBreakpoint $breakpoint};Remove-Variable NativeRecoveryScopePhysicalObservations -Scope Global -ErrorAction SilentlyContinue
    $full=[IO.Path]::GetFullPath($root);if([IO.Path]::GetDirectoryName($full)-cne[IO.Path]::GetTempPath().TrimEnd('\','/')-or[IO.Path]::GetFileName($full)-cnotmatch'^native-recovery-source-scope-[0-9a-f]{32}$'){throw 'Unsafe source-scope fixture cleanup.'};if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
