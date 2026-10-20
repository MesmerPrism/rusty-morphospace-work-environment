[CmdletBinding()]
param([string]$OutPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$owner=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
$local=Join-Path $owner ('local/advisory-budget-control-'+[Guid]::NewGuid().ToString('N'))
$fixture=Join-Path $local 'source'
[void][IO.Directory]::CreateDirectory($fixture)
function Assert-Control([bool]$Condition,[string]$Message){if(-not$Condition){throw "Public affected-runner control failed: $Message"}}
function Write-ControlText([string]$Path,[string]$Text){[void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Invoke-ControlGit([string[]]$Arguments){$output=@(& git -C $fixture @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "Fixture Git failed [$fixture] ($($Arguments-join' ')): $($output -join ' ')"};return ($output -join "`n").Trim()}
function Read-ControlJson([string]$Path){Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -Depth 64 -DateKind String}
function Get-ControlEnvironmentHash {
    $values=[Environment]::GetEnvironmentVariables('Process');[string[]]$names=@($values.Keys);[Array]::Sort($names,[StringComparer]::Ordinal)
    $bytes=[Text.Encoding]::UTF8.GetBytes((@($names|ForEach-Object{"$_`0$($values[$_])`0"})-join''))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}
$template=Read-ControlJson (Join-Path $owner 'manifests/affected-validation-registry.json')
$phaseSourceCheck=@($template.checks|Where-Object check_id -ceq 'affected-selector-executor-pass-schema')
Assert-Control ($phaseSourceCheck.Count-eq1-and$phaseSourceCheck[0].command_path-ceq'scripts/Invoke-AffectedValidationSelfTestPhase.ps1') 'Registry does not select the real public phase command'
$phaseArguments=@($phaseSourceCheck[0].arguments)
Assert-Control ($phaseArguments.Count-eq4-and$phaseArguments[0]-ceq'-Phase'-and$phaseArguments[1]-ceq'executor-pass-schema'-and$phaseArguments[2]-ceq'-BudgetSeconds'-and$phaseArguments[3]-match'^[1-9][0-9]*$'-and[int]$phaseArguments[3]-le600) 'Registry does not retain the exact supported phase argument contract'
$phaseCommandPath=[string]$phaseSourceCheck[0].command_path
foreach($path in @(
    'scripts/Invoke-AffectedValidation.ps1',$phaseCommandPath,
    'scripts/lib/MorphospaceProtocolCommon.psm1','scripts/lib/MorphospaceAffectedValidation.psm1',
    'scripts/lib/MorphospaceAffectedValidationCheckEvidence.psm1','scripts/lib/MorphospaceAffectedValidationDependencyClosure.psm1',
    'schemas/affected-validation-registry-v1.schema.json','schemas/affected-validation-plan-v2.schema.json',
    'schemas/affected-validation-check-evidence-v1.schema.json','schemas/affected-validation-check-inventory-v1.schema.json',
    'schemas/affected-validation-evidence-v1.schema.json','schemas/affected-validation-self-test-phase-receipt-v1.schema.json',
    'schemas/affected-validation-self-test-dependency-projection-v1.schema.json'
)){
    $target=Join-Path $fixture $path;$sourcePath=Join-Path $owner $path;[void][IO.Directory]::CreateDirectory((Split-Path $target -Parent));Copy-Item -LiteralPath $sourcePath -Destination $target
    Assert-Control ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash-ceq(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash) 'Fixture source copy differs from the registry-selected owner bytes'
}
Write-ControlText (Join-Path $fixture '.gitignore') "local/`n"
[void](Invoke-ControlGit @('init','-b','main'))
[void](Invoke-ControlGit @('config','user.name','Public runner control'))
[void](Invoke-ControlGit @('config','user.email','public-runner@example.invalid'))
[void](Invoke-ControlGit @('config','commit.gpgsign','false'))
$checkTemplate=@($template.checks|Where-Object check_id -ceq 'documentation-links')[0]
function New-ControlCheck([string]$Id,[string]$Command,[int]$Budget=15,[string[]]$Prerequisites=@(),[string[]]$Arguments=@()){
    $check=$checkTemplate|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64
    $check.check_id=$Id;$check.command_path=$Command;$check.budget_seconds=$Budget;$check.arguments=@($Arguments)
    $check.platforms=@('windows','linux');$check.minimum_tier='quick';$check.trigger_path_sets=@('fixture-all');$check.consume_path_sets=@('fixture-all')
    $check.prerequisite_checks=@($Prerequisites);$check.provides_contracts=@();$check.consumes_contracts=@();$check.always_run=$true;$check.cache_policy='exact-host'
    if($null-ne$check.PSObject.Properties['execution_after_checks']){$check.PSObject.Properties.Remove('execution_after_checks')}
    return $check
}
function Set-ControlCandidate([object[]]$Checks,[string]$Name){
    $registry=$template|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64
    $registry.checks=@($Checks);$registry.path_sets=@([pscustomobject]@{path_set_id='fixture-all';patterns=@('**')})
    $registry.dependency_declarations=@();$registry.always_run_check_ids=@($Checks|Where-Object always_run|ForEach-Object check_id);$registry.deep_escalation_path_sets=@()
    Write-ControlText (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson $registry)+"`n")
    [void](Invoke-ControlGit @('add','.'));[void](Invoke-ControlGit @('commit','-m',$Name))
    $head=Invoke-ControlGit @('rev-parse','HEAD')
    $plan=Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $head -HeadRevision $head -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    $planPath=Join-Path $local "$Name.plan.json";Write-ControlText $planPath ((ConvertTo-MorphospaceCanonicalJson $plan)+"`n")
    [pscustomobject]@{head=$head;plan=$planPath;checks=@($Checks|Where-Object always_run|ForEach-Object check_id)}
}
function Invoke-ControlRunner([object]$Candidate,[string]$Name,[switch]$Strict,[string]$Prior='',[switch]$ExpectedFailure,[switch]$EarlyRefusal){
    $root=Join-Path $local $Name;[void][IO.Directory]::CreateDirectory($root)
    $parameters=@{RepositoryRoot=$fixture;BaseCommit=$Candidate.head;HeadCommit=$Candidate.head;PlanPath=$Candidate.plan;Platform=$(if($IsWindows){'windows'}else{'linux'});OutPath=(Join-Path $root 'evidence.json');CheckEvidenceDirectory=(Join-Path $root 'checks');StrictBudget=$Strict.IsPresent}
    if($Prior){$parameters.PriorEvidenceDirectory=$Prior}
    $failed=$false;$warnings=@()
    try{& (Join-Path $fixture 'scripts/Invoke-AffectedValidation.ps1') @parameters -WarningVariable warnings|Out-Null}catch{$failed=$true;Write-ControlText (Join-Path $root 'failure.txt') $_.Exception.Message}
    Assert-Control ($failed-eq$ExpectedFailure.IsPresent) "$Name had unexpected public outcome; inspect $root"
    if($EarlyRefusal-and-not[IO.File]::Exists($parameters.OutPath)){return [pscustomobject]@{root=$root;checks=$parameters.CheckEvidenceDirectory;evidence=$null;warnings=@($warnings)}}
    $evidence=Read-ControlJson $parameters.OutPath
    # The aggregate's v1 rows describe executed/reused commands. Blocked
    # terminals belong to the complete finalized per-check inventory.
    $inventory=Read-ControlJson (Join-Path $parameters.CheckEvidenceDirectory 'inventory.json')
    Assert-Control ((@($inventory.entries.check_id|Sort-Object)-join',')-ceq(@($Candidate.checks|Sort-Object)-join',')) "$Name lost or duplicated a selected check terminal"
    [pscustomobject]@{root=$root;checks=$parameters.CheckEvidenceDirectory;evidence=$evidence;warnings=@($warnings)}
}
function Get-ControlReceipt([object]$Run,[string]$Id){Read-ControlJson (Join-Path $Run.checks "$Id/receipt.json")}
function Get-ControlStream([object]$Run,[string]$Id,[string]$Stream){[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $Run.checks "$Id/$Stream.bin")))}

# The estimate applies to the real public dispatch, containment and persistence path.
Write-ControlText (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "'boundary-complete'`n"
$boundary=New-ControlCheck 'public-boundary' 'scripts/Test-PublicBoundary.ps1'
Write-ControlText (Join-Path $fixture 'scripts/Leaf.ps1') "Start-Sleep -Milliseconds 2200`n[Console]::Out.Write('actual-complete')`n[Console]::Error.Write('actual-stderr')`n"
$candidate=Set-ControlCandidate @($boundary,(New-ControlCheck 'fixture-leaf' 'scripts/Leaf.ps1' 1)) 'advisory'
$savedWarningPreference=$WarningPreference
try{$WarningPreference='Stop';$advisory=Invoke-ControlRunner $candidate 'advisory-run'}finally{$WarningPreference=$savedWarningPreference}
$receipt=Get-ControlReceipt $advisory 'fixture-leaf'
Assert-Control ($advisory.evidence.result-ceq'pass'-and$receipt.mode-ceq'executed'-and$receipt.elapsed_ms-ge2200-and-not$receipt.child.timed_out-and-not$receipt.child.post_kill_drain_timed_out) 'Advisory overrun did not finalize an actual passing child'
Assert-Control (@($advisory.warnings|Where-Object{[string]$_-like'*exceeded its estimated*'}).Count-eq1) 'Public advisory warning was absent or stopped completion'
Assert-Control ((Get-ControlStream $advisory 'fixture-leaf' 'stdout')-ceq'actual-complete'-and(Get-ControlStream $advisory 'fixture-leaf' 'stderr')-ceq'actual-stderr') 'Public advisory stream bytes did not reach EOF'
$strict=Invoke-ControlRunner $candidate 'strict-run' -Strict -ExpectedFailure
$strictReceipt=Get-ControlReceipt $strict 'fixture-leaf'
Assert-Control ($strictReceipt.result-ceq'code-fail'-and$strictReceipt.child.failure_kind-ceq'timeout'-and$strictReceipt.child.timed_out-and-not(Get-ControlStream $strict 'fixture-leaf' 'stdout').Contains('actual-complete')) 'Strict cancellation claimed a completed original'

# A real phase launcher makes a second hop into this small committed test command.
$environmentLeaf=@'
param([string]$SelfTestPhase)
$ErrorActionPreference='Stop'
foreach($name in @('GIT_PAGER','GIT_OBJECT_DIRECTORY','GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0','WEF002_UNOWNED_MARKER')){
    if($null-ne[Environment]::GetEnvironmentVariable($name,'Process')){throw "Inherited parent selector: $name"}
}
[Console]::Out.Write('second-hop-closed')
'@
Write-ControlText (Join-Path $fixture 'scripts/Test-AffectedValidation.ps1') $environmentLeaf
$phaseCheck=New-ControlCheck 'affected-selector-executor-pass-schema' $phaseCommandPath 30 @() $phaseArguments
# The phase reader authenticates its complete sibling registry contract, even
# though this control executes only one tiny phase and the public boundary.
$phaseFamily=@($template.checks|Where-Object{[string]$_.command_path-ceq$phaseCommandPath-and[string]$_.check_id-cne$phaseCheck.check_id}|ForEach-Object{
    $sibling=New-ControlCheck ([string]$_.check_id) ([string]$_.command_path) 30 @() @($_.arguments)
    $sibling.always_run=$false;$sibling.trigger_path_sets=@();$sibling
})
$environmentCandidate=Set-ControlCandidate (@($boundary,$phaseCheck)+$phaseFamily) 'environment'
$poison=@{GIT_PAGER='parent-pager';GIT_CONFIG_COUNT='1';GIT_CONFIG_KEY_0='core.pager';GIT_CONFIG_VALUE_0='parent-pager';WEF002_UNOWNED_MARKER='private-marker'}
$saved=@{}
try{
    foreach($name in $poison.Keys){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process');[Environment]::SetEnvironmentVariable($name,$poison[$name],'Process')}
    $before=Get-ControlEnvironmentHash
    $environmentRun=Invoke-ControlRunner $environmentCandidate 'environment-run'
    Assert-Control ((Get-ControlEnvironmentHash)-ceq$before) 'Public runner changed parent environment bytes'
}finally{foreach($name in $saved.Keys){if($null-eq$saved[$name]){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}}}
$phaseReceipt=Get-ControlReceipt $environmentRun 'affected-selector-executor-pass-schema'
Assert-Control ($phaseReceipt.result-ceq'pass'-and$phaseReceipt.environment.parent_environment_unchanged-and@($phaseReceipt.artifacts).Count-ge4) 'Second-hop closed environment did not persist actual phase artifacts'
$phaseStdout=@($phaseReceipt.artifacts|Where-Object path -Like '*executor-pass-schema.stdout.bin')
Assert-Control ($phaseStdout.Count-eq1-and[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $environmentRun.checks ('affected-selector-executor-pass-schema/artifacts/'+$phaseStdout[0].path))))-ceq'second-hop-closed') 'Second-hop command did not execute the environment assertions'
$savedObjects=[Environment]::GetEnvironmentVariable('GIT_OBJECT_DIRECTORY','Process');$beforeObjects=Get-ControlEnvironmentHash
try{
    [Environment]::SetEnvironmentVariable('GIT_OBJECT_DIRECTORY',(Join-Path $local 'absent-object-store'),'Process');$before=Get-ControlEnvironmentHash
    $objectRefusal=Invoke-ControlRunner $environmentCandidate 'object-store-refusal' -ExpectedFailure -EarlyRefusal
    Assert-Control ($null-eq$objectRefusal.evidence-and(Get-ControlEnvironmentHash)-ceq$before) 'Dangerous outer Git redirection did not refuse before evidence or changed its parent'
}finally{if($null-eq$savedObjects){Remove-Item -LiteralPath 'Env:GIT_OBJECT_DIRECTORY' -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable('GIT_OBJECT_DIRECTORY',$savedObjects,'Process')}}
Assert-Control ((Get-ControlEnvironmentHash)-ceq$beforeObjects) 'Object redirection refusal did not restore its parent environment exactly'
foreach($drift in @('manifests/affected-validation-registry.json',$phaseCommandPath)){
    $path=Join-Path $fixture $drift;$bytes=[IO.File]::ReadAllBytes($path)
    try{
        [IO.File]::AppendAllText($path,"`n ")
        $name=if($drift.EndsWith('.json')){'registry-drift'}else{'phase-source-drift'}
        $refusal=Invoke-ControlRunner $environmentCandidate $name -ExpectedFailure -EarlyRefusal
        Assert-Control ($null-eq$refusal.evidence-or$refusal.evidence.result-cne'pass') 'Registry-selected phase source or registry drift supplied passing evidence'
    }finally{[IO.File]::WriteAllBytes($path,$bytes)}
}

# A parent exits with a live descendant retaining both inherited pipes.
# Bind the original in this observer's PID namespace before allowing that exit.
# A namespace-local PID is never a host PID or proof of host process identity.
$descendantChild=@'
param([string]$ControlRoot,[string]$Nonce)
$ErrorActionPreference='Stop'
if($Nonce-cnotmatch'^[0-9a-f]{32}$'){throw 'Exact descendant fixture nonce required'}
$birth=if($IsLinux){[long](([IO.File]::ReadAllText('/proc/self/stat')-split'\) ',2)[1].Split(' ')[19])}else{(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks}
$namespace=if($IsLinux){([IO.FileInfo]::new('/proc/self/ns/pid')).LinkTarget}else{''}
[Console]::Out.Write('descendant-stdout');[Console]::Error.Write('descendant-stderr')
$ready=[Text.UTF8Encoding]::new($false).GetBytes(([ordered]@{schema='fixture.descendant-ready.v1';nonce=$Nonce;namespace_pid=$PID;pid_namespace=$namespace;birth_ticks=$birth}|ConvertTo-Json -Compress))
$pending=Join-Path $ControlRoot 'descendant-ready.pending';$final=Join-Path $ControlRoot 'descendant-ready.json'
$stream=[IO.FileStream]::new($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($ready,0,$ready.Length);$stream.Flush($true)}finally{$stream.Dispose()}
[IO.File]::Move($pending,$final)
Start-Sleep -Seconds 60
[Console]::Out.Write('unsettled-descendant-complete')
'@
$descendantNonce=[Guid]::NewGuid().ToString('N')
$descendantLeaf=@'
$ErrorActionPreference='Stop'
$exe=(Get-Process -Id $PID).Path
$root=$env:RUSTY_AFFECTED_VALIDATION_PHASE_ROOT
[void][IO.Directory]::CreateDirectory($root)
$start=[Diagnostics.ProcessStartInfo]::new($exe);$start.UseShellExecute=$false
foreach($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Descendant.ps1'),'-ControlRoot',$root,'-Nonce','__NONCE__')){$start.ArgumentList.Add($arg)}
$child=[Diagnostics.Process]::Start($start)
try{
 [Console]::Out.WriteLine('descendant-pid:'+$child.Id)
 $ready=Join-Path $root 'descendant-ready.json';$ack=Join-Path $root 'descendant-observed.txt'
 $deadline=[DateTime]::UtcNow.AddSeconds(45)
 while(-not[IO.File]::Exists($ack)){
  if([IO.File]::Exists((Join-Path $root 'descendant-refused.txt'))){throw 'Descendant host identity observation refused'}
  if($child.HasExited){throw 'Descendant exited before its live original was observed'}
  if([DateTime]::UtcNow-ge$deadline){throw 'Descendant identity handshake did not complete'}
  Start-Sleep -Milliseconds 10
 }
 $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($ready))).ToLowerInvariant()
 if([IO.File]::ReadAllText($ack)-cne("observed:$hash`n")-or$child.HasExited){throw 'Exact live descendant observation ACK required'}
}finally{$child.Dispose()}
'@
Write-ControlText (Join-Path $fixture 'scripts/Descendant.ps1') $descendantChild
Write-ControlText (Join-Path $fixture 'scripts/Leaf.ps1') ($descendantLeaf.Replace('__NONCE__',$descendantNonce))
$descendantCandidate=Set-ControlCandidate @($boundary,(New-ControlCheck 'fixture-leaf' 'scripts/Leaf.ps1')) 'descendant'
$descendantPlan=Read-ControlJson $descendantCandidate.plan
$descendantControlRoot=Join-Path (Join-Path $local 'descendant-run') ("affected-selector-phases-$($descendantPlan.plan_sha256)-"+$(if($IsWindows){'windows'}else{'linux'}))
$trackerSource=@'
param([string]$Root,[string]$Nonce,[string]$ProcessName,[Threading.ManualResetEventSlim]$Stop)
$ErrorActionPreference='Stop'
try{
$readyPath=Join-Path $Root 'descendant-ready.json'
while(-not[IO.File]::Exists($readyPath)){if($Stop.IsSet){throw 'Runner ended without a descendant readiness record'};Start-Sleep -Milliseconds 10}
$raw=[IO.File]::ReadAllBytes($readyPath);$ready=[Text.Encoding]::UTF8.GetString($raw)|ConvertFrom-Json
if((@($ready.PSObject.Properties.Name|Sort-Object)-join',')-cne'birth_ticks,namespace_pid,nonce,pid_namespace,schema'-or$ready.schema-cne'fixture.descendant-ready.v1'-or$ready.nonce-cne$Nonce-or$ready.namespace_pid-le0-or$ready.birth_ticks-le0){throw 'Closed actual descendant readiness record required'}
if($IsLinux-and($ready.pid_namespace-cnotmatch'^pid:\[[0-9]+\]$'-or$ready.pid_namespace-ceq([IO.FileInfo]::new('/proc/self/ns/pid')).LinkTarget)){throw 'Actual separate descendant PID namespace required'}
$found=$null
while($null-eq$found){
 if($Stop.IsSet){throw 'Runner ended before the actual descendant original was mapped'}
 foreach($process in [Diagnostics.Process]::GetProcessesByName($ProcessName)){
  try{
   if($IsLinux){
    $base='/proc/'+$process.Id
    if(([IO.FileInfo]::new($base+'/ns/pid')).LinkTarget-cne$ready.pid_namespace){continue}
    $status=[IO.File]::ReadAllText($base+'/status');$match=[regex]::Match($status,'(?m)^NSpid:\s+([0-9 \t]+)$')
    if(-not$match.Success-or[long]($match.Groups[1].Value.Trim()-split'\s+')[-1]-ne$ready.namespace_pid){continue}
    $birth=[long](([IO.File]::ReadAllText($base+'/stat')-split'\) ',2)[1].Split(' ')[19])
   }else{if($process.Id-ne$ready.namespace_pid){continue};$birth=$process.StartTime.ToUniversalTime().Ticks}
   if($birth-ne$ready.birth_ticks){throw 'Descendant birth differs from the exact host original'}
   if($process.HasExited){throw 'Descendant exited before its host original was observed'}
   if($null-ne$found){throw 'Descendant namespace/birth did not identify one host original'}
   $found=[pscustomobject]@{host_pid=$process.Id;namespace_pid=[long]$ready.namespace_pid;pid_namespace=[string]$ready.pid_namespace;birth_ticks=$birth;live_original_observed=$true;ready_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()}
  }catch [IO.FileNotFoundException]{}catch [IO.DirectoryNotFoundException]{}catch [InvalidOperationException]{}finally{$process.Dispose()}
 }
 if($null-eq$found){Start-Sleep -Milliseconds 10}
}
$pending=Join-Path $Root 'descendant-observed.pending';$ack=Join-Path $Root 'descendant-observed.txt'
[IO.File]::WriteAllText($pending,("observed:$($found.ready_sha256)`n"),[Text.UTF8Encoding]::new($false));[IO.File]::Move($pending,$ack)
$found
}catch{if([IO.Directory]::Exists($Root)){[IO.File]::WriteAllText((Join-Path $Root 'descendant-refused.txt'),[string]$_,[Text.UTF8Encoding]::new($false))};throw}
'@
$trackerStop=[Threading.ManualResetEventSlim]::new($false);$tracker=[PowerShell]::Create()
[void]$tracker.AddScript($trackerSource).AddArgument($descendantControlRoot).AddArgument($descendantNonce).AddArgument([IO.Path]::GetFileNameWithoutExtension((Get-Process -Id $PID).Path)).AddArgument($trackerStop)
$trackerFuture=$tracker.BeginInvoke()
$dispatchError=$null;$trackerError=$null;$trackerHadErrors=$false;$trackerErrors='';$tracked=@()
try{$descendant=Invoke-ControlRunner $descendantCandidate 'descendant-run'}catch{$dispatchError=$_}finally{
 $trackerStop.Set()
 try{$tracked=@($tracker.EndInvoke($trackerFuture))}catch{$trackerError=$_}finally{$trackerHadErrors=$tracker.HadErrors;$trackerErrors=$tracker.Streams.Error-join'; ';$tracker.Dispose();$trackerStop.Dispose()}
}
if($null-ne$dispatchError){throw $dispatchError}
if($null-ne$trackerError){throw $trackerError}
Assert-Control (-not$trackerHadErrors-and$tracked.Count-eq1) ('Actual descendant host identity was not retained: '+$trackerErrors)
$descendantOriginal=$tracked[0]
Write-ControlText (Join-Path $local 'descendant-original.json') ($descendantOriginal|ConvertTo-Json -Depth 5)
$descendantReceipt=Get-ControlReceipt $descendant 'fixture-leaf'
$stdout=Get-ControlStream $descendant 'fixture-leaf' 'stdout';$stderr=Get-ControlStream $descendant 'fixture-leaf' 'stderr'
Assert-Control ($stdout-match'descendant-pid:([0-9]+)') 'Descendant original was not issued'
Assert-Control ([long]$Matches[1]-eq$descendantOriginal.namespace_pid-and$descendantOriginal.live_original_observed) 'Namespace-local descendant PID differs from its observed original'
$originalPresent=$false
if($IsLinux){
 try{$stat=[IO.File]::ReadAllText('/proc/'+$descendantOriginal.host_pid+'/stat');$originalPresent=[long](($stat-split'\) ',2)[1].Split(' ')[19])-eq$descendantOriginal.birth_ticks}catch [IO.FileNotFoundException]{}catch [IO.DirectoryNotFoundException]{}
}else{
 $process=Get-Process -Id $descendantOriginal.host_pid -ErrorAction SilentlyContinue
 if($null-ne$process){try{$originalPresent=$process.StartTime.ToUniversalTime().Ticks-eq$descendantOriginal.birth_ticks}finally{$process.Dispose()}}
}
Assert-Control (-not$originalPresent) 'Terminal preceded the exact observed host descendant exit/reap'
Assert-Control ($descendantReceipt.result-ceq'pass'-and-not$descendantReceipt.child.post_kill_drain_timed_out-and$stdout.Contains('descendant-stdout')-and-not$stdout.Contains('unsettled-descendant-complete')-and$stderr-ceq'descendant-stderr') 'Terminal preceded owned descendant dual EOF or truthful containment completion'

# Plan binding cannot authorize mutated working bytes; no passing terminal is reusable.
$leafPath=Join-Path $fixture 'scripts/Leaf.ps1';$original=[IO.File]::ReadAllBytes($leafPath)
try{
    [IO.File]::AppendAllText($leafPath,"`n# source changed after plan binding`n")
    $mutation=Invoke-ControlRunner $descendantCandidate 'mutation-run' -ExpectedFailure -EarlyRefusal
    Assert-Control ($null-eq$mutation.evidence-or($mutation.evidence.result-cne'pass'-and@($mutation.evidence.check_results|Where-Object result -ceq'pass').Count-eq0)) 'Mutated source supplied passing check evidence'
}finally{[IO.File]::WriteAllBytes($leafPath,$original)}

# Failed semantic prerequisites block only dependents. The independent original
# completes, stays in the finalized inventory and reuses on the unchanged retry.
Write-ControlText (Join-Path $fixture 'scripts/Fail.ps1') "[Console]::Error.Write('expected-failure');exit 7`n"
Write-ControlText (Join-Path $fixture 'scripts/Dependent.ps1') "throw 'Blocked dependent must never execute'`n"
Write-ControlText (Join-Path $fixture 'scripts/Independent.ps1') "[Console]::Out.Write('independent-complete')`n"
$failureCandidate=Set-ControlCandidate @($boundary,(New-ControlCheck 'fixture-fail' 'scripts/Fail.ps1'),(New-ControlCheck 'fixture-dependent' 'scripts/Dependent.ps1' 15 @('fixture-fail')),(New-ControlCheck 'fixture-independent' 'scripts/Independent.ps1')) 'prerequisite'
$failure=Invoke-ControlRunner $failureCandidate 'prerequisite-run' -ExpectedFailure
$retry=Invoke-ControlRunner $failureCandidate 'prerequisite-retry' -Prior $failure.checks -ExpectedFailure
foreach($run in @($failure,$retry)){
    $dependent=Get-ControlReceipt $run 'fixture-dependent';$independent=Get-ControlReceipt $run 'fixture-independent'
    Assert-Control ($dependent.mode-ceq'blocked'-and$dependent.result-ceq'blocked'-and-not$dependent.child.started-and(@($dependent.blocked_by)-join',')-ceq'fixture-fail'-and$independent.result-ceq'pass') 'Semantic failure stopped an independent check or launched its dependent'
}
Assert-Control ((Get-ControlReceipt $failure 'fixture-independent').mode-ceq'executed'-and(Get-ControlReceipt $retry 'fixture-independent').mode-ceq'reused') 'Independent pass was not reusable after sibling failure'
$result=[ordered]@{passed=$true;public_runner=$true;committed_minimal_registry=$true;real_leaf_outlasts_estimate=$true;warning_preference_stop_does_not_deny=$true;strict_timeout_truthful=$true;second_hop_environment_closed=$true;parent_environment_unchanged=$true;outer_object_store_redirection_refused=$true;registry_and_phase_source_drift_refused=$true;descendant_exit_dual_eof_reap=$true;source_mutation_refused=$true;semantic_dependent_blocked=$true;independent_pass_reused=$true;evidence_root=$local;dynamic_candidate_evidence_only=$true;acceptance_authority=$false;publication_authority=$false;device_used=$false}
if($OutPath){Write-ControlText ([IO.Path]::GetFullPath($OutPath)) ($result|ConvertTo-Json -Depth 10)}
$result|ConvertTo-Json -Depth 10
