param([string]$RepoRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent $PSScriptRoot}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('quest-build-retained-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$module=Join-Path $RepoRoot 'scripts/lib/MorphospaceRetainedBuildProcess.psm1'
$runner=Join-Path $RepoRoot 'scripts/Invoke-QuestBuildProfile.ps1'
$pwsh=(Get-Command pwsh -ErrorAction Stop).Source
$python=(Get-Command python -ErrorAction Stop).Source
$issued=[Collections.Generic.List[object]]::new()
$gates=[Collections.Generic.List[string]]::new()
$reports=[Collections.Generic.List[object]]::new()
function Write-Text([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Assert-Actual([bool]$Value,[string]$Reason){if(-not$Value){throw "Retained build control: $Reason"}}
function Read-Live([string]$Path){
 if(-not(Test-Path -LiteralPath $Path)){return ''}
 $f=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 $r=[IO.StreamReader]::new($f)
 try{return $r.ReadToEnd()}finally{$r.Dispose();$f.Dispose()}
}
function Start-Fixture([string[]]$Arguments,[string]$Capture){
 [IO.Directory]::CreateDirectory($Capture)|Out-Null
 $outPath=Join-Path $Capture 'stdout.log';$errPath=Join-Path $Capture 'stderr.log'
 $o=[IO.FileStream]::new($outPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,1,$true)
 $e=[IO.FileStream]::new($errPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,1,$true)
 $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$pwsh;$psi.WorkingDirectory=$root
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 foreach($a in $Arguments){[void]$psi.ArgumentList.Add($a)}
 $p=[Diagnostics.Process]::Start($psi)
 $row=[pscustomobject]@{process=$p;stdout=$outPath;stderr=$errPath;outstream=$o;errstream=$e;outtask=$p.StandardOutput.BaseStream.CopyToAsync($o);errtask=$p.StandardError.BaseStream.CopyToAsync($e);finished=$false;exit=$null}
 $issued.Add($row);return $row
}
function Finish-Fixture([object]$Row){
 if($Row.finished){return}
 $Row.process.WaitForExit()
 $failures=[Collections.Generic.List[string]]::new()
 foreach($task in @($Row.outtask,$Row.errtask)){try{[void]$task.GetAwaiter().GetResult()}catch{$failures.Add('fixture-reader-failed')}}
 $Row.exit=$Row.process.ExitCode
 foreach($stream in @($Row.outstream,$Row.errstream)){try{$stream.Flush($true)}finally{$stream.Dispose()}}
 $Row.process.Dispose();$Row.finished=$true
 if($failures.Count){throw 'Fixture raw reader failed after actual settlement'}
}
function Wait-Actual([scriptblock]$Condition,[object]$Driver,[string]$Reason){
 $clock=[Diagnostics.Stopwatch]::StartNew();$next=10.0
 while(-not(& $Condition)){
   if($Driver.process.HasExited){Finish-Fixture $Driver;throw "Fixture exited before $Reason"}
   if($clock.Elapsed.TotalSeconds-ge$next){try{[Console]::Error.WriteLine("WARNING: waiting for actual $Reason; no fixture timeout or retry.")}catch{};$next=$clock.Elapsed.TotalSeconds+10.0}
   [Threading.Thread]::Sleep(25)
 }
}
$producer=Join-Path $root 'producer.py'
Write-Text $producer @'
import argparse, ctypes, json, os, subprocess, sys, time, uuid
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--mode',required=True);p.add_argument('--root',required=True);p.add_argument('--exit-code',type=int,default=0)
a=p.parse_args();root=Path(a.root)
def marker(name,value):
    target=root/name;temp=root/(name+'.'+uuid.uuid4().hex+'.tmp')
    temp.write_text(json.dumps(value),encoding='utf-8');os.replace(temp,target)
def wait(name):
    while not (root/name).exists():time.sleep(.025)
if a.mode!='Child':
    with (root/'launches.txt').open('a',encoding='utf-8') as f:f.write(str(os.getpid())+'\n')
if a.mode=='Parent':
    child=subprocess.Popen([sys.executable,__file__,'--mode','Child','--root',str(root)],stdout=sys.stdout,stderr=sys.stderr,close_fds=False)
    if os.name=='nt':
        from ctypes import wintypes
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.GetCurrentProcess.restype=wintypes.HANDLE
        kernel.GetProcessTimes.argtypes=[wintypes.HANDLE]+[ctypes.POINTER(wintypes.FILETIME)]*4
        creation=wintypes.FILETIME();exit_time=wintypes.FILETIME();kernel_time=wintypes.FILETIME();user_time=wintypes.FILETIME()
        if not kernel.GetProcessTimes(kernel.GetCurrentProcess(),ctypes.byref(creation),ctypes.byref(exit_time),ctypes.byref(kernel_time),ctypes.byref(user_time)):raise ctypes.WinError(ctypes.get_last_error())
        identity={'pid':os.getpid(),'creation_filetime':(creation.dwHighDateTime<<32)|creation.dwLowDateTime}
    else:
        identity={'pid':os.getpid(),'creation_filetime':None}
    marker('PARENT_READY.json',identity);wait('ALLOW_PARENT_EXIT');sys.exit(0)
sys.stdout.buffer.write(b'x'*2097152);sys.stdout.buffer.flush()
sys.stderr.buffer.write(b'y'*2097152);sys.stderr.buffer.flush()
marker('READY.json',{'pid':os.getpid()});wait('RELEASE')
sys.stdout.buffer.write(b'late-out');sys.stdout.buffer.flush()
sys.stderr.buffer.write(b'late-err');sys.stderr.buffer.flush()
sys.exit(a.exit_code)
'@
$driver=Join-Path $root 'driver.ps1'
Write-Text $driver @'
param([string]$ModulePath,[string]$Producer,[string]$Root,[string]$Mode,[int]$ExitCode=0,[long]$SinkFail=-1,[switch]$WarningFail,[int]$CancelAfter=0,[switch]$CausalCancel,[string]$PythonPath)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$envs=@{};foreach($key in [Environment]::GetEnvironmentVariables('Process').Keys){$envs[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
$execution=[pscustomobject]@{FileName=$PythonPath;WorkingDirectory=$Root;Arguments=@($Producer,'--mode',$Mode,'--root',$Root,'--exit-code',[string]$ExitCode)}
$cancelGate=if($CausalCancel){Join-Path $Root 'CANCEL'}else{''}
$result=Invoke-MorphospaceRetainedBuildProcess -Execution $execution -EnvironmentValues $envs -BaseReceiptPath (Join-Path $Root 'receipt.json') -EstimatedWarningSeconds 1 -CancelAfterMilliseconds $CancelAfter -TestCancellationGate $cancelGate -TestFailStdoutAfterBytes $SinkFail -TestWarningPublicationFailure:$WarningFail
[IO.File]::WriteAllText((Join-Path $Root 'RESULT.json'),($result|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false))
'@
function Start-Case([string]$Name,[string]$Mode='Solo',[int]$ExitCode=0,[long]$SinkFail=-1,[switch]$WarningFail,[int]$CancelAfter=0,[switch]$CausalCancel){
 $case=Join-Path $root $Name;[IO.Directory]::CreateDirectory($case)|Out-Null
 foreach($gate in @('ALLOW_PARENT_EXIT','RELEASE')){$gates.Add((Join-Path $case $gate))}
 $args=@('-NoProfile','-NonInteractive','-File',$driver,'-ModulePath',$module,'-Producer',$producer,'-Root',$case,'-Mode',$Mode,'-ExitCode',[string]$ExitCode,'-SinkFail',[string]$SinkFail,'-CancelAfter',[string]$CancelAfter,'-PythonPath',$python)
 if($WarningFail){$args+='-WarningFail'}
 if($CausalCancel){$args+='-CausalCancel'}
 return [pscustomobject]@{root=$case;driver=(Start-Fixture $args (Join-Path $case 'driver-capture'))}
}
function Read-Result([object]$Case){
 Finish-Fixture $Case.driver
 Assert-Actual ($Case.driver.exit-eq0) ('driver failed: '+(Read-Live $Case.driver.stderr))
 $r=Get-Content -LiteralPath (Join-Path $Case.root 'RESULT.json') -Raw|ConvertFrom-Json -Depth 32
 Assert-Actual ($r.ChildProcess.process_reaped-and$r.ChildProcess.stdout_eof-and$r.ChildProcess.stderr_eof-and-not$r.ChildProcess.automatic_retry) 'actual child/reap/both EOF/no replay required'
 Assert-Actual (@(Get-Content -LiteralPath (Join-Path $Case.root 'launches.txt')).Count-eq1) 'original was dispatched more than once'
 return $r
}
try{
 $case=Start-Case 'held-descendant' 'Parent'
 Wait-Actual {Test-Path -LiteralPath (Join-Path $case.root 'PARENT_READY.json')} $case.driver 'parent entry'
 $identity=Get-Content -LiteralPath (Join-Path $case.root 'PARENT_READY.json') -Raw|ConvertFrom-Json
 $parent=[Diagnostics.Process]::GetProcessById($identity.pid)
 try{
  if($IsWindows){Assert-Actual ($parent.StartTime.ToUniversalTime().Ticks-eq[DateTime]::FromFileTimeUtc([long]$identity.creation_filetime).Ticks) 'parent PID birth changed'}
  Write-Text (Join-Path $case.root 'ALLOW_PARENT_EXIT') 'release'
  $parent.WaitForExit()
  Wait-Actual {Test-Path -LiteralPath (Join-Path $case.root 'READY.json')} $case.driver 'descendant output'
  $warningsAfterParentExit=([regex]::Matches((Read-Live $case.driver.stderr),'build exceeds its estimate')).Count
  Wait-Actual {([regex]::Matches((Read-Live $case.driver.stderr),'build exceeds its estimate')).Count-gt$warningsAfterParentExit} $case.driver 'new warning after actual parent exit with descendant pipes held'
  Assert-Actual (-not$case.driver.process.HasExited-and-not(Test-Path -LiteralPath (Join-Path $case.root 'RESULT.json'))) 'parent exit or estimate abandoned descendant pipes'
 }finally{$parent.Dispose();Write-Text (Join-Path $case.root 'RELEASE') 'release'}
 $r=Read-Result $case
 Assert-Actual ($r.Status-ceq'passed'-and$r.ChildProcess.raw_capture_complete-and$r.ChildProcess.warning_count-ge1) 'retained descendant completion failed'
 Assert-Actual ([IO.File]::ReadAllText($r.Streams.stdout.path)-ceq(('x'*2097152)+'late-out')) 'stdout large output/late tail changed'
 Assert-Actual ([IO.File]::ReadAllText($r.Streams.stderr.path)-ceq(('y'*2097152)+'late-err')) 'stderr large output/late tail changed'
 $reports.Add(@{control='actual-parent-exit-before-dual-eof';passed=$true;warning_count=$r.ChildProcess.warning_count;bytes_per_stream=$r.Streams.stdout.size_bytes})

 $case=Start-Case 'warning-publication-failure' -WarningFail
 Wait-Actual {Test-Path -LiteralPath (Join-Path $case.root 'READY.json')} $case.driver 'warning-failure producer entry'
 [Threading.Thread]::Sleep(1500) # Deliberate stimulus beyond the estimate, never a cancellation deadline.
 Assert-Actual (-not$case.driver.process.HasExited) 'failed warning publication abandoned the original'
 Write-Text (Join-Path $case.root 'RELEASE') 'release';$r=Read-Result $case
 Assert-Actual ($r.Status-ceq'passed'-and$r.ChildProcess.warning_publication_failures-ge1-and$r.ChildProcess.raw_capture_complete) 'warning failure changed actual child result'
 $reports.Add(@{control='warning-publication-failure';passed=$true;MODELED_warning_sink_failure=$true;actual_process_and_pipes=$true})

 $case=Start-Case 'raw-write-failure' -SinkFail 100
 Wait-Actual {Test-Path -LiteralPath (Join-Path $case.root 'READY.json')} $case.driver 'actual producer after sink failure'
 Write-Text (Join-Path $case.root 'RELEASE') 'release';$r=Read-Result $case
 Assert-Actual ($r.Status-ceq'failed'-and$r.ExitCode-eq0-and-not$r.ChildProcess.raw_capture_complete) 'raw sink failure misreported child outcome'
 Assert-Actual ($r.Streams.stdout.drained_bytes-eq2097160-and$r.Streams.stdout.stored_bytes-lt$r.Streams.stdout.drained_bytes-and$r.Streams.stdout.storage_error-ceq'raw-write-failed') 'failed sink did not drain actual producer and late tail'
 Assert-Actual ($r.Streams.stderr.drained_bytes-eq2097160-and$r.Streams.stderr.stored_bytes-eq2097160) 'independent stderr capture was lost'
 $reports.Add(@{control='drain-after-raw-write-failure';passed=$true;MODELED_raw_write_failure=$true;actual_producer_exit_reap_dual_eof=$true})

 $case=Start-Case 'actual-nonzero' -ExitCode 7
 Wait-Actual {Test-Path -LiteralPath (Join-Path $case.root 'READY.json')} $case.driver 'nonzero producer entry'
 Write-Text (Join-Path $case.root 'RELEASE') 'release';$r=Read-Result $case
 Assert-Actual ($r.Status-ceq'failed'-and$r.ExitCode-eq7-and$r.ChildProcess.raw_capture_complete) 'actual nonzero result was lost'
 $reports.Add(@{control='actual-nonzero';passed=$true;actual_exit=7})

 $case=Start-Case 'explicit-cancel' -CausalCancel
 Wait-Actual {Test-Path -LiteralPath (Join-Path $case.root 'READY.json')} $case.driver 'actual producer before explicit cancellation'
 Write-Text (Join-Path $case.root 'CANCEL') 'requested cancellation'
 $r=Read-Result $case
 Assert-Actual ($r.Status-ceq'cancelled'-and$r.ChildProcess.termination_requested-and$r.ChildProcess.cancellation-ceq'test-cancel') 'explicit cancellation was not distinguished'
 $reports.Add(@{control='explicit-cancellation';passed=$true;actual_requested_cancel=$true})

 # Exercise the public owner runner too, with a genuine fixture source Git
 # baseline, its normal preflight and an actual causally released build child.
 $source=Join-Path $root 'build-source';[IO.Directory]::CreateDirectory($source)|Out-Null
 $buildScript=Join-Path $source 'build.ps1'
 Write-Text $buildScript @'
param([string]$Output,[string]$Entered,[string]$Release)
$ErrorActionPreference='Stop'
[IO.File]::WriteAllText($Entered,'entered')
while(-not(Test-Path -LiteralPath $Release)){[Threading.Thread]::Sleep(25)}
$p=Join-Path $PSScriptRoot $Output;[IO.Directory]::CreateDirectory((Split-Path -Parent $p))|Out-Null
[IO.File]::WriteAllBytes($p,[byte[]](1,2,3,4))
'@
 Write-Text (Join-Path $source 'AndroidManifest.xml') '<manifest package="example.retained" />'
 & git -C $source init -q; if($LASTEXITCODE){throw 'fixture Git init failed'}
 & git -C $source config user.email fixture@example.invalid
 & git -C $source config user.name 'Retained Build Fixture'
 & git -C $source add build.ps1 AndroidManifest.xml
 & git -C $source commit -qm 'fixture source baseline';if($LASTEXITCODE){throw 'fixture Git commit failed'}
 $entered=Join-Path $root 'BUILD_ENTERED';$release=Join-Path $root 'BUILD_RELEASE';$gates.Add($release)
 $profile=[ordered]@{schema='rusty.morphospace.quest_build_profile.v1';profile_id='retained-fixture';working_directory='.';executable='build.ps1';arguments=@('out/fixture.apk',$entered,$release);environment=[ordered]@{};artifact=[ordered]@{relative_path='out/fixture.apk';kind='single-base-apk'};preflight=[ordered]@{manifest_relative_dependencies=@('AndroidManifest.xml');toolchain=[ordered]@{repository_files=@();required_targets=@()};identity=[ordered]@{package_id='example.retained';application_id='example.retained'};environment_projection=[ordered]@{passthrough=@('HOME','PATH','TEMP','TMP','TMPDIR');prohibited_parent_variables=@()};output=[ordered]@{lane='warm';collision_policy='new-only';allow_source_root=$true}}}
 $profilePath=Join-Path $root 'profile.json';Write-Text $profilePath ($profile|ConvertTo-Json -Depth 32)
 $sha=(Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
 # ValidateSet accepts case variants; they must select the same retained policy.
 $common=@('-NoProfile','-NonInteractive','-File',$runner,'-ProfilePath',$profilePath,'-ProfileSha256',$sha,'-SourceRoot',$source,'-WaitPolicy','retained','-EstimatedWarningSeconds','1')
 $pre=Start-Fixture ($common+@('-Mode','Preflight')) (Join-Path $root 'public-preflight')
 Finish-Fixture $pre
 Assert-Actual ($pre.exit-eq0) ('actual retained preflight failed: '+(Read-Live $pre.stdout))
 $preResult=Get-Content -LiteralPath $pre.stdout -Raw|ConvertFrom-Json -Depth 64
 Assert-Actual ($preResult.schema-ceq'rusty.morphospace.quest_build_terminal_result.v2'-and-not$preResult.child_process.started) 'public retained preflight contract differs'
 $receipt=Join-Path $root 'public-build-receipt.json'
 $build=Start-Fixture ($common+@('-Mode','Build','-ReceiptPath',$receipt)) (Join-Path $root 'public-build')
 Wait-Actual {Test-Path -LiteralPath $entered} $build 'public build child entry'
 Wait-Actual {(Read-Live $build.stderr).Contains('build exceeds its estimate')} $build 'public build warning'
 Assert-Actual (-not(Test-Path -LiteralPath $receipt)-and-not$build.process.HasExited) 'public runner published before original settled'
 Write-Text $release 'release';Finish-Fixture $build
 Assert-Actual ($build.exit-eq0) ('public build failed: '+(Read-Live $build.stdout))
 $result=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json -Depth 64
 Assert-Actual ($result.schema-ceq'rusty.morphospace.quest_build_terminal_result.v2'-and$result.terminal_status-ceq'passed'-and$result.child_process.raw_capture_complete-and$result.invocation.wait_policy-ceq'retained-warning') 'public retained terminal differs'
 Assert-Actual (Test-Json -Json ($result|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $RepoRoot 'schemas/quest-build-terminal-result-v2.schema.json')) 'actual public terminal schema rejected'
 Assert-Actual ($result.owner_payload.artifact.size_bytes-eq4-and$result.child_process.process_reaped-and$result.child_process.stdout_eof-and$result.child_process.stderr_eof) 'actual artifact or process closure missing'
 $reports.Add(@{control='public-preflight-and-build-v2';passed=$true;actual_fixture_apk_bytes=4;device_calls=0})
 [ordered]@{schema='rusty.morphospace.quest_build_retained_original_controls.v1';status='passed';controls=@($reports.ToArray());evidence_root=$root;limits='Actual host child, descendant, process handles, raw pipes and public build-profile fixture. Raw/warning sink faults are deliberately modeled. The four-byte fixture is no Android APK, SDK, signer or device validation.'}|ConvertTo-Json -Depth 12
}finally{
 foreach($gate in $gates.ToArray()){if(-not(Test-Path -LiteralPath $gate)){Write-Text $gate 'release'}}
 foreach($row in $issued.ToArray()){if(-not$row.finished){Finish-Fixture $row}}
 # Preserve exact raw/partial fixture evidence; no automatic replay or deletion.
}
