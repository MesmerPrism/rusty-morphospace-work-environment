$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force

function Assert-Launcher { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "Authority-launcher self-test failed: $Message"} }
function Assert-Rejected { param([scriptblock]$Action,[string]$Message) $rejected=$false;try{&$Action}catch{$rejected=$true};Assert-Launcher $rejected $Message }
function Assert-LauncherProcessTerminal { param([int]$ProcessId,[string]$Message) $alive=$false;$process=$null;try{$process=[Diagnostics.Process]::GetProcessById($ProcessId);$alive=-not$process.HasExited}catch [ArgumentException]{}finally{if($null-ne$process){$process.Dispose()}};Assert-Launcher (-not$alive) $Message }

$temp=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-authority-launcher-'+[guid]::NewGuid().ToString('N'));$timeoutPid=0;$timeoutStderr=''
try {
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    $validator=Join-Path $temp 'fixture-validator.ps1'
    $body=@'
param([string]$WorkspaceRoot,[string]$QuestRoot,[string]$RoadmapPath,[string]$UnitId,[string]$OutPath)
[IO.File]::WriteAllText($OutPath,(@{workspace=$WorkspaceRoot;quest=$QuestRoot;roadmap=$RoadmapPath;unit=$UnitId}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
Write-Output 'fixture-validator-ran'
'@
    [IO.File]::WriteAllText($validator,$body,[Text.UTF8Encoding]::new($false))
    $owner=Join-Path $temp 'owner.json';$stdout=Join-Path $temp 'stdout.txt';$stderr=Join-Path $temp 'stderr.txt'
    $run=Invoke-MorphospacePinnedValidator -ValidatorPath $validator -Workspace 'workspace-marker' -Quest 'quest-marker' -Roadmap 'roadmap-marker' -Unit 'unit-marker' -OwnerOut $owner -StdoutPath $stdout -StderrPath $stderr -TimeoutSeconds 15
    $written=Get-Content -LiteralPath $owner -Raw|ConvertFrom-Json
    Assert-Launcher ($run.exit_code-eq0-and$run.stdout-match'fixture-validator-ran') 'child validator did not execute through the pinned launcher'
    Assert-Launcher ([string]$written.workspace-eq'workspace-marker'-and[string]$written.quest-eq'quest-marker'-and[string]$written.roadmap-eq'roadmap-marker'-and[string]$written.unit-eq'unit-marker') 'launcher arguments drifted'
    Assert-Rejected {Invoke-MorphospacePinnedValidator -ValidatorPath $validator -Workspace 'workspace-marker' -Quest 'quest-marker' -Roadmap 'roadmap-marker' -Unit 'unit-marker' -OwnerOut $owner -StdoutPath $stdout -StderrPath $stderr -TimeoutSeconds 15|Out-Null} 'preexisting output did not reject'

    $timeoutRoot=Join-Path $temp 'timeout';[IO.Directory]::CreateDirectory($timeoutRoot)|Out-Null
    $timeoutValidator=Join-Path $timeoutRoot 'hanging-validator.ps1'
    [IO.File]::WriteAllText($timeoutValidator,"param([string]`$WorkspaceRoot,[string]`$QuestRoot,[string]`$RoadmapPath,[string]`$UnitId,[string]`$OutPath)`n[Console]::Error.Write(('hanging-validator-ready:{0}:{1}'-f[Environment]::ProcessId,[Diagnostics.Stopwatch]::GetTimestamp()));[Console]::Error.Flush();[Threading.ManualResetEventSlim]::new(`$false).Wait(300000)",[Text.UTF8Encoding]::new($false))
    $timeoutOwner=Join-Path $timeoutRoot 'owner.json';$timeoutStdout=Join-Path $timeoutRoot 'stdout.txt';$timeoutStderr=Join-Path $timeoutRoot 'stderr.txt';$timeoutMessage=''
    $timeoutReturnedAt=0L;$timeoutClock=[Diagnostics.Stopwatch]::StartNew();try{Invoke-MorphospacePinnedValidator -ValidatorPath $timeoutValidator -Workspace 'workspace-marker' -Quest 'quest-marker' -Roadmap 'roadmap-marker' -Unit 'unit-marker' -OwnerOut $timeoutOwner -StdoutPath $timeoutStdout -StderrPath $timeoutStderr -TimeoutSeconds 1|Out-Null}catch{$timeoutMessage=[string]$_.Exception.Message}finally{$timeoutClock.Stop();$timeoutReturnedAt=[Diagnostics.Stopwatch]::GetTimestamp()}
    Assert-Launcher ($timeoutMessage-ceq'Pinned validator exceeded its registry timeout of 1 seconds.') 'pinned validator did not preserve its domain timeout failure'
    Assert-Launcher ($timeoutClock.Elapsed.TotalSeconds-lt15) 'one-second validator timeout did not complete within its bounded launch, termination, and drain allowance'
    $timeoutStderrText=[IO.File]::ReadAllText($timeoutStderr);$timeoutReadyToReturnSeconds=[double]::PositiveInfinity;if($timeoutStderrText-match'^hanging-validator-ready:([0-9]+):([0-9]+)$'){$timeoutPid=[int]$Matches[1];$timeoutReadyToReturnSeconds=($timeoutReturnedAt-[long]$Matches[2])/[double][Diagnostics.Stopwatch]::Frequency};Assert-Launcher ($timeoutPid-gt0) 'timed-out validator stderr did not drain before return'
    Assert-Launcher ($timeoutReadyToReturnSeconds-ge0-and$timeoutReadyToReturnSeconds-lt5) 'one-second validator deadline was not enforced within five seconds of target readiness'
    Assert-LauncherProcessTerminal $timeoutPid 'timed-out validator remained alive after authority process cleanup'
    foreach($capturePath in @($timeoutStdout,$timeoutStderr)){$capture=[IO.FileStream]::new($capturePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$capture.Dispose()}
    [IO.Directory]::Delete($timeoutRoot,$true);Assert-Launcher (-not[IO.Directory]::Exists($timeoutRoot)) 'timed-out validator captures were not immediately cleanable'
    Write-Host 'Authority-launcher self-test passed.'
} finally {
    if($timeoutPid-eq0-and-not[string]::IsNullOrWhiteSpace($timeoutStderr)-and[IO.File]::Exists($timeoutStderr)){$timeoutText=[IO.File]::ReadAllText($timeoutStderr);if($timeoutText-match'^hanging-validator-ready:([0-9]+):[0-9]+$'){$timeoutPid=[int]$Matches[1]}}
    if($timeoutPid-gt0){$timeoutProcess=$null;try{$timeoutProcess=[Diagnostics.Process]::GetProcessById($timeoutPid);if(-not$timeoutProcess.HasExited){$timeoutProcess.Kill($true);if(-not$timeoutProcess.WaitForExit(10000)){throw "Hanging validator did not terminate during cleanup: $timeoutPid"}}}catch [ArgumentException]{}finally{if($null-ne$timeoutProcess){$timeoutProcess.Dispose()}}}
    if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}
}
