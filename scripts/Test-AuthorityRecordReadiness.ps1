$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceOwnership.psm1') -Force
$script:OwnershipModule=Get-Module MorphospaceOwnership
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceAuthorityReadiness.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceAuthorityProcess.psm1') -Force

function Assert-Readiness {param([bool]$Condition,[string]$Message)if(-not$Condition){throw "Authority-readiness self-test failed: $Message"}}
function Assert-Rejected {param([scriptblock]$Action,[string]$Message)$rejected=$false;try{&$Action}catch{$rejected=$true};Assert-Readiness $rejected $Message}
function Write-TestText {param([string]$Path,[string]$Text)$parent=[IO.Path]::GetDirectoryName($Path);if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Get-TestSha {param([string]$Text)$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Get-TestEncodedCommand {param([string]$Text)return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))}
function Assert-TestCaptureUnlocked {
    param([string[]]$Paths)
    foreach($path in $Paths){$stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$stream.Dispose()}
}
function Assert-TestProcessTerminal {
    param([int]$ProcessId,[string]$Message)
    $alive=$false;$process=$null;try{$process=[Diagnostics.Process]::GetProcessById($ProcessId);$alive=-not$process.HasExited}catch{}finally{if($null-ne$process){$process.Dispose()}}
    Assert-Readiness (-not$alive) $Message
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-readiness-test-'+[guid]::NewGuid().ToString('N'));$adversaryPidFiles=[Collections.Generic.List[string]]::new();$adversaryPids=[Collections.Generic.HashSet[int]]::new()
try{
    [IO.Directory]::CreateDirectory($temp)|Out-Null

    $hostCommand=Get-Command pwsh -CommandType Application -ErrorAction Stop|Where-Object{[IO.File]::Exists([string]$_.Source)}|Sort-Object -Property @{Expression={[version]$_.Version};Descending=$true},@{Expression={[string]$_.Source};Descending=$false}|Select-Object -First 1
    Assert-Readiness ($null-ne$hostCommand) 'PowerShell 7 capture-test host is unavailable'
    $hostPath=[IO.Path]::GetFullPath([string]$hostCommand.Source)

    $successRoot=Join-Path $temp 'capture-success';[IO.Directory]::CreateDirectory($successRoot)|Out-Null;$successOut=Join-Path $successRoot 'stdout.bin';$successErr=Join-Path $successRoot 'stderr.bin'
    $success=Invoke-MorphospaceCapturedProcess -FilePath $hostPath -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',(Get-TestEncodedCommand "[Console]::Out.Write('capture-out');[Console]::Error.Write('capture-err')")) -StdoutPath $successOut -StderrPath $successErr -TimeoutMilliseconds 30000
    Assert-Readiness ([int]$success.exit_code-eq0-and[IO.File]::ReadAllText($successOut)-ceq'capture-out'-and[IO.File]::ReadAllText($successErr)-ceq'capture-err') 'bounded process capture lost successful stdout/stderr'
    Assert-TestCaptureUnlocked @($successOut,$successErr);[IO.Directory]::Delete($successRoot,$true);Assert-Readiness (-not[IO.Directory]::Exists($successRoot)) 'successful process capture was not immediately cleanable'

    $argumentRoot=Join-Path $temp 'capture-arguments';[IO.Directory]::CreateDirectory($argumentRoot)|Out-Null;$argumentScript=Join-Path $argumentRoot 'arguments.ps1';$argumentOut=Join-Path $argumentRoot 'stdout.bin';$argumentErr=Join-Path $argumentRoot 'stderr.bin'
    Write-TestText $argumentScript "`$json=ConvertTo-Json -InputObject @(`$args) -Compress;[Console]::Out.Write([Convert]::ToBase64String([Text.UTF8Encoding]::new(`$false).GetBytes(`$json)))"
    $argumentRun=Invoke-MorphospaceCapturedProcess -FilePath $hostPath -Arguments @('-NoProfile','-NonInteractive','-File',$argumentScript,'','space value','embedded"quote','trailing\','slashes\\\"before-quote','quoted trailing\\','Grüße-東京','--') -StdoutPath $argumentOut -StderrPath $argumentErr -TimeoutMilliseconds 30000
    $argumentJson=[Text.UTF8Encoding]::new($false).GetString([Convert]::FromBase64String([IO.File]::ReadAllText($argumentOut)));$argumentValues=@($argumentJson|ConvertFrom-Json);Assert-Readiness ([int]$argumentRun.exit_code-eq0-and$argumentValues.Count-eq8-and[string]$argumentValues[0]-ceq''-and[string]$argumentValues[1]-ceq'space value'-and[string]$argumentValues[2]-ceq'embedded"quote'-and[string]$argumentValues[3]-ceq'trailing\'-and[string]$argumentValues[4]-ceq'slashes\\\"before-quote'-and[string]$argumentValues[5]-ceq'quoted trailing\\'-and[string]$argumentValues[6]-ceq'Grüße-東京'-and[string]$argumentValues[7]-ceq'--') 'supervisor bridge changed an authority argument boundary or byte sequence'
    Assert-TestCaptureUnlocked @($argumentOut,$argumentErr);[IO.Directory]::Delete($argumentRoot,$true)

    $accountingJob=$null;$accountingProcess=$null
    try{
        $accountingBody=Get-TestEncodedCommand '[Threading.ManualResetEventSlim]::new($false).Wait(300000)'
        $accountingStart=[Diagnostics.ProcessStartInfo]::new();$accountingStart.FileName=$hostPath;$accountingStart.UseShellExecute=$false;$accountingStart.CreateNoWindow=$true
        foreach($accountingArgument in @('-NoProfile','-NonInteractive','-EncodedCommand',$accountingBody)){[void]$accountingStart.ArgumentList.Add($accountingArgument)}
        $accountingJob=[Rusty.Morphospace.AuthorityProcessJob]::new();$accountingProcess=[Diagnostics.Process]::new();$accountingProcess.StartInfo=$accountingStart
        Assert-Readiness $accountingProcess.Start() 'job-accounting fixture did not start';[void]$adversaryPids.Add($accountingProcess.Id);$accountingJob.AssignProcess($accountingProcess.Handle)
        Assert-Readiness (-not$accountingJob.WaitForEmpty(250)) 'job-accounting wait reported empty while an assigned process was active'
        $accountingJob.Terminate();Assert-Readiness $accountingJob.WaitForEmpty(10000) 'job-accounting wait did not verify zero active processes after termination'
        Assert-Readiness ($accountingProcess.WaitForExit(10000)-and$accountingProcess.HasExited) 'job-accounting fixture was not terminal after zero-member verification'
    }finally{
        if($null-ne$accountingJob){$accountingJob.Dispose()}
        if($null-ne$accountingProcess){if(-not$accountingProcess.HasExited){$accountingProcess.Kill($true);[void]$accountingProcess.WaitForExit(10000)};$accountingProcess.Dispose()}
    }

    $nonzeroRoot=Join-Path $temp 'capture-nonzero';[IO.Directory]::CreateDirectory($nonzeroRoot)|Out-Null;$nonzeroOut=Join-Path $nonzeroRoot 'stdout.bin';$nonzeroErr=Join-Path $nonzeroRoot 'stderr.bin'
    $nonzero=Invoke-MorphospaceCapturedProcess -FilePath $hostPath -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',(Get-TestEncodedCommand "[Console]::Out.Write('nonzero-out');[Console]::Error.Write('nonzero-err');exit 23")) -StdoutPath $nonzeroOut -StderrPath $nonzeroErr -TimeoutMilliseconds 30000
    Assert-Readiness ([int]$nonzero.exit_code-eq23-and[IO.File]::ReadAllText($nonzeroOut)-ceq'nonzero-out'-and[IO.File]::ReadAllText($nonzeroErr)-ceq'nonzero-err') 'bounded process capture lost nonzero-exit output'
    Assert-TestCaptureUnlocked @($nonzeroOut,$nonzeroErr);[IO.Directory]::Delete($nonzeroRoot,$true)

    $drainRoot=Join-Path $temp 'capture-drain';[IO.Directory]::CreateDirectory($drainRoot)|Out-Null;$drainOut=Join-Path $drainRoot 'stdout.bin';$drainErr=Join-Path $drainRoot 'stderr.bin'
    $drain=Invoke-MorphospaceCapturedProcess -FilePath $hostPath -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',(Get-TestEncodedCommand "[Console]::Out.Write(('o'*262144));[Console]::Error.Write(('e'*262144))")) -StdoutPath $drainOut -StderrPath $drainErr -TimeoutMilliseconds 30000
    Assert-Readiness ([int]$drain.exit_code-eq0-and([IO.FileInfo]$drainOut).Length-eq262144-and([IO.FileInfo]$drainErr).Length-eq262144) 'bounded process capture returned before both streams drained'
    Assert-TestCaptureUnlocked @($drainOut,$drainErr);[IO.Directory]::Delete($drainRoot,$true)

    $inheritedRoot=Join-Path $temp 'capture-root-exit-inherited';[IO.Directory]::CreateDirectory($inheritedRoot)|Out-Null;$inheritedOut=Join-Path $inheritedRoot 'stdout.bin';$inheritedErr=Join-Path $inheritedRoot 'stderr.bin';$inheritedEvent='Local\MorphospaceAuthorityInherited-'+[guid]::NewGuid().ToString('N')
    $inheritedChildEncoded=Get-TestEncodedCommand "`$ready=[Threading.EventWaitHandle]::OpenExisting('$inheritedEvent');try{[Console]::Error.Write('inherited-child-ready');[Console]::Error.Flush();`$ready.Set()|Out-Null}finally{`$ready.Dispose()};[Threading.ManualResetEventSlim]::new(`$false).Wait(300000)"
    $inheritedBody=@"
`$ready=[Threading.EventWaitHandle]::new(`$false,[Threading.EventResetMode]::ManualReset,'$inheritedEvent')
try{`$child=Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand','$inheritedChildEncoded') -NoNewWindow -PassThru;[Console]::Out.WriteLine(`$child.Id);[Console]::Out.Flush();if(-not`$ready.WaitOne(10000)){exit 91};`$child.Dispose()}finally{`$ready.Dispose()}
exit 0
"@
    $adversaryPidFiles.Add($inheritedOut);$inheritedRun=Invoke-MorphospaceCapturedProcess -FilePath $hostPath -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',(Get-TestEncodedCommand $inheritedBody)) -StdoutPath $inheritedOut -StderrPath $inheritedErr -TimeoutMilliseconds 30000
    $inheritedPidText=[IO.File]::ReadAllText($inheritedOut).Trim();if($inheritedPidText-match'^[0-9]+$'){[void]$adversaryPids.Add([int]$inheritedPidText)};Assert-Readiness ([int]$inheritedRun.exit_code-eq0-and$inheritedPidText-match'^[0-9]+$'-and[IO.File]::ReadAllText($inheritedErr)-ceq'inherited-child-ready') 'root-exit inherited-pipe adversary did not complete its handshake'
    Assert-TestProcessTerminal ([int]$inheritedPidText) 'inherited-pipe descendant survived root exit and job termination'
    Assert-TestCaptureUnlocked @($inheritedOut,$inheritedErr);[IO.Directory]::Delete($inheritedRoot,$true);Assert-Readiness (-not[IO.Directory]::Exists($inheritedRoot)) 'inherited-pipe root-exit captures were not immediately cleanable'

    $independentRoot=Join-Path $temp 'capture-root-exit-independent';[IO.Directory]::CreateDirectory($independentRoot)|Out-Null;$independentOut=Join-Path $independentRoot 'stdout.bin';$independentErr=Join-Path $independentRoot 'stderr.bin';$independentChildOut=Join-Path $independentRoot 'child-stdout.bin';$independentChildErr=Join-Path $independentRoot 'child-stderr.bin';$independentEvent='Local\MorphospaceAuthorityIndependent-'+[guid]::NewGuid().ToString('N')
    $independentChildEncoded=Get-TestEncodedCommand "`$ready=[Threading.EventWaitHandle]::OpenExisting('$independentEvent');try{[Console]::Out.Write('independent-child-out');[Console]::Out.Flush();[Console]::Error.Write('independent-child-ready');[Console]::Error.Flush();`$ready.Set()|Out-Null}finally{`$ready.Dispose()};[Threading.ManualResetEventSlim]::new(`$false).Wait(300000)"
    $independentBody=@"
`$ready=[Threading.EventWaitHandle]::new(`$false,[Threading.EventResetMode]::ManualReset,'$independentEvent')
try{`$child=Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand','$independentChildEncoded') -RedirectStandardOutput '$independentChildOut' -RedirectStandardError '$independentChildErr' -WindowStyle Hidden -PassThru;[Console]::Out.WriteLine(`$child.Id);[Console]::Out.Flush();if(-not`$ready.WaitOne(10000)){exit 92};`$child.Dispose()}finally{`$ready.Dispose()}
exit 0
"@
    $adversaryPidFiles.Add($independentOut);$independentRun=Invoke-MorphospaceCapturedProcess -FilePath $hostPath -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',(Get-TestEncodedCommand $independentBody)) -StdoutPath $independentOut -StderrPath $independentErr -TimeoutMilliseconds 30000
    $independentPidText=[IO.File]::ReadAllText($independentOut).Trim();if($independentPidText-match'^[0-9]+$'){[void]$adversaryPids.Add([int]$independentPidText)};Assert-Readiness ([int]$independentRun.exit_code-eq0-and$independentPidText-match'^[0-9]+$'-and[IO.File]::ReadAllText($independentChildOut)-ceq'independent-child-out'-and[IO.File]::ReadAllText($independentChildErr)-ceq'independent-child-ready') 'root-exit independently redirected adversary did not complete its handshake'
    Assert-TestProcessTerminal ([int]$independentPidText) 'independently redirected descendant survived root exit and job termination'
    Assert-TestCaptureUnlocked @($independentOut,$independentErr,$independentChildOut,$independentChildErr);[IO.Directory]::Delete($independentRoot,$true);Assert-Readiness (-not[IO.Directory]::Exists($independentRoot)) 'independently redirected root-exit captures were not immediately cleanable'

    $treeChildEncoded=Get-TestEncodedCommand "[Console]::Error.Write('tree-child-ready');[Console]::Error.Flush();[Threading.ManualResetEventSlim]::new(`$false).Wait(300000)"
    $treeBody=@"
`$child=Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand','$treeChildEncoded') -NoNewWindow -PassThru
[Console]::Out.WriteLine(`$child.Id);[Console]::Out.Flush();[Threading.ManualResetEventSlim]::new(`$false).Wait(300000)
"@
    $timeoutRoot=Join-Path $temp 'capture-timeout';[IO.Directory]::CreateDirectory($timeoutRoot)|Out-Null;$timeoutOut=Join-Path $timeoutRoot 'stdout.bin';$timeoutErr=Join-Path $timeoutRoot 'stderr.bin';$timedOut=$false
    $adversaryPidFiles.Add($timeoutOut);try{Invoke-MorphospaceCapturedProcess -FilePath $hostPath -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',(Get-TestEncodedCommand $treeBody)) -StdoutPath $timeoutOut -StderrPath $timeoutErr -TimeoutMilliseconds 3000|Out-Null}catch [TimeoutException]{$timedOut=$true}
    $treePidText=[IO.File]::ReadAllText($timeoutOut).Trim();if($treePidText-match'^[0-9]+$'){[void]$adversaryPids.Add([int]$treePidText)};Assert-Readiness ($timedOut-and$treePidText-match'^[0-9]+$') 'bounded process capture did not report the expected tree timeout'
    Assert-TestProcessTerminal ([int]$treePidText) 'timed-out process descendant survived tree termination and stream drain'
    Assert-Readiness ([IO.File]::ReadAllText($timeoutErr)-ceq'tree-child-ready') 'timed-out descendant stderr did not drain before return'
    Assert-TestCaptureUnlocked @($timeoutOut,$timeoutErr);[IO.Directory]::Delete($timeoutRoot,$true);Assert-Readiness (-not[IO.Directory]::Exists($timeoutRoot)) 'timed-out process capture was not immediately cleanable'

    $stressText="[Console]::Out.Write('stress-out');[Console]::Error.Write('stress-err')";$stressEncoded=Get-TestEncodedCommand $stressText;$processModule=(Resolve-Path (Join-Path $PSScriptRoot 'lib\MorphospaceAuthorityProcess.psm1')).Path
    $stressCount=24;if(-not[string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('MORPHOSPACE_AUTHORITY_CAPTURE_STRESS_COUNT'))){$stressCount=[int][Environment]::GetEnvironmentVariable('MORPHOSPACE_AUTHORITY_CAPTURE_STRESS_COUNT')};Assert-Readiness ($stressCount-ge1-and$stressCount-le256) 'capture stress count is outside 1..256'
    $stressThrottle=[Math]::Min(8,$stressCount);$stressResults=1..$stressCount|ForEach-Object -Parallel {
        Import-Module $using:processModule -Force;$captureRoot=Join-Path $using:temp ('capture-stress-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($captureRoot)|Out-Null;$stdout=Join-Path $captureRoot 'stdout.bin';$stderr=Join-Path $captureRoot 'stderr.bin'
        try{$capture=Invoke-MorphospaceCapturedProcess -FilePath $using:hostPath -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',$using:stressEncoded) -StdoutPath $stdout -StderrPath $stderr -TimeoutMilliseconds 30000;$ok=([int]$capture.exit_code-eq0-and[IO.File]::ReadAllText($stdout)-ceq'stress-out'-and[IO.File]::ReadAllText($stderr)-ceq'stress-err');foreach($path in @($stdout,$stderr)){$stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$stream.Dispose()};[IO.Directory]::Delete($captureRoot,$true);[pscustomobject]@{ok=$ok;message=''}}catch{[pscustomobject]@{ok=$false;message=[string]$_.Exception.Message}}
    } -ThrottleLimit $stressThrottle
    $stressFailures=@($stressResults|Where-Object{-not$_.ok});Assert-Readiness ($stressFailures.Count-eq0) "bounded process capture stress failed: $([string]($stressFailures.message|Select-Object -First 1))"

    $hostProbe=Invoke-MorphospaceAuthorityHostProbe -RequiredCommands @('git.exe')
    Test-MorphospaceAuthorityHostCapabilitiesV1 $hostProbe @('git.exe')|Out-Null
    $missing=Invoke-MorphospaceAuthorityHostProbe -RequiredCommands @('morphospace-command-that-does-not-exist.exe')
    Assert-Readiness ([string]$missing.result-eq'fail') 'missing declared host command passed'

    $repo=Join-Path $temp 'owner';$runner=Join-Path $repo 'scripts\Invoke-MorphospaceValidationAuthority.ps1';Write-TestText $runner 'param()'
    $runnerSha=Get-MorphospaceReadinessSha256 $runner;$migration=[pscustomobject]@{authority_artifacts=@([pscustomobject]@{repo_id='work-environment';path='scripts/Invoke-MorphospaceValidationAuthority.ps1';sha256=$runnerSha;git_blob_oid=('a'*40)})}
    $map=@{'work-environment'=[pscustomobject]@{path=$repo}}
    $release=New-MorphospaceAuthorityRunnerReleaseV1 $migration $map $runner
    Test-MorphospaceAuthorityRunnerReleaseV1 $release $map|Out-Null

    $reference=[pscustomobject]@{role='validation-action';path='receipts/action.json';schema='rusty.morphospace.workflow.validation_action.v2';sha256=('b'*64)}
    $validator=[pscustomobject]@{validator_id='owner-test';owner_repo_id='work-environment';sha256=('c'*64);input_closure=@([pscustomobject]@{repo_id='work-environment';kind='git-tree';paths=@('scripts/')});history_blobs=@();timeout_seconds=30;max_output_bytes=4096;mutation_policy='temp-output-only';device_policy='forbidden'}
    $capsule=New-MorphospaceAuthorityInputCapsuleV1 -ProjectId 'readiness-test' -UnitId 'unit-test' -AttemptId 'attempt-test' -References @($reference) -Validator $validator -RunnerRelease $release
    Test-MorphospaceAuthorityInputCapsuleV1 $capsule|Out-Null
    $damaged=($capsule|ConvertTo-Json -Depth 30|ConvertFrom-Json);$damaged.content.attempt_id='attempt-damaged'
    Assert-Rejected {Test-MorphospaceAuthorityInputCapsuleV1 $damaged|Out-Null} 'capsule content drift was accepted'

    $cacheResult=&$script:OwnershipModule {
        param($capsuleSha,$materializedSha)
        $parent=Join-Path ([IO.Path]::GetTempPath()) 'rusty-morphospace-cleanrooms';if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null}
        $source=Join-Path $parent ('readiness-fixture-'+[guid]::NewGuid().ToString('N'));$repoRoot=Join-Path $source 'fixture-repo';[IO.Directory]::CreateDirectory($repoRoot)|Out-Null;[IO.File]::WriteAllText((Join-Path $repoRoot 'input.txt'),'sealed',[Text.UTF8Encoding]::new($false))
        $guard=[guid]::NewGuid().ToString('N');$script:CleanRoomGuards[$source]=$guard;$repositories=@{'fixture-repo'=$repoRoot};$closure=@{'fixture-repo'=[string[]]@('input.txt')};$modes=@{'fixture-repo'=@{}}
        $clean=[pscustomobject]@{root=$source;parent=$parent;guard=$guard;repositories=$repositories;closure=$closure;modes_by_repository=$modes;history_rows=@()};$clean|Add-Member fingerprint_sha256 (Get-MorphospaceCleanRoomFingerprint $clean)
        $saved=Save-MorphospaceContentAddressedCleanRoom $clean $capsuleSha $materializedSha;Close-MorphospaceContentAddressedCleanRoom $saved
        $opened=Open-MorphospaceContentAddressedCleanRoom $capsuleSha $materializedSha;$reused=[bool]$opened.reused;$same=((Get-MorphospaceCleanRoomFingerprint $opened)-ceq[string]$opened.fingerprint_sha256);$rootPath=[string]$opened.root;$manifest=[string]$opened.cache_manifest;Close-MorphospaceContentAddressedCleanRoom $opened
        [IO.File]::AppendAllText((Join-Path $rootPath 'fixture-repo\input.txt'),'damage',[Text.UTF8Encoding]::new($false));$rejected=$false;try{$null=Open-MorphospaceContentAddressedCleanRoom $capsuleSha $materializedSha}catch{$rejected=$true}
        if([IO.Directory]::Exists($rootPath)){Remove-MorphospaceNoFollowTree $rootPath};if([IO.File]::Exists($manifest)){[IO.File]::Delete($manifest)}

        $capsule2=('7'*64);$source2=Join-Path $parent ('readiness-fixture-'+[guid]::NewGuid().ToString('N'));$repoRoot2=Join-Path $source2 'fixture-repo';[IO.Directory]::CreateDirectory($repoRoot2)|Out-Null;[IO.File]::WriteAllText((Join-Path $repoRoot2 'input.txt'),'sealed',[Text.UTF8Encoding]::new($false))
        $guard2=[guid]::NewGuid().ToString('N');$script:CleanRoomGuards[$source2]=$guard2;$clean2=[pscustomobject]@{root=$source2;parent=$parent;guard=$guard2;repositories=@{'fixture-repo'=$repoRoot2};closure=@{'fixture-repo'=[string[]]@('input.txt')};modes_by_repository=@{'fixture-repo'=@{}};history_rows=@()};$clean2|Add-Member fingerprint_sha256 (Get-MorphospaceCleanRoomFingerprint $clean2)
        $saved2=Save-MorphospaceContentAddressedCleanRoom $clean2 $capsule2 $capsule2;$root2=[string]$saved2.root;$manifest2=[string]$saved2.cache_manifest;Remove-MorphospaceContentAddressedCleanRoom $saved2 -RemoveManifest
        $removed=(-not [IO.Directory]::Exists($root2) -and -not [IO.File]::Exists($manifest2))

        $partial=('8'*64);$partialPaths=Get-MorphospaceCleanRoomCachePaths $partial;[IO.Directory]::CreateDirectory($partialPaths.root)|Out-Null;$partialRejected=$false;try{$null=Open-MorphospaceContentAddressedCleanRoom $partial $partial}catch{$partialRejected=$true};if([IO.Directory]::Exists($partialPaths.root)){Remove-MorphospaceNoFollowTree $partialPaths.root}
        return [pscustomobject]@{reused=$reused;same=$same;tamper_rejected=$rejected;removed=$removed;partial_rejected=$partialRejected}
    } ([string]$capsule.capsule_sha256) ([string]$capsule.capsule_sha256)
    Assert-Readiness ($cacheResult.reused-and$cacheResult.same-and$cacheResult.tamper_rejected-and$cacheResult.removed-and$cacheResult.partial_rejected) 'content-addressed clean-room reuse/tamper/cleanup gate failed'

    $actionRef=[pscustomobject]@{role='validation-action';path='receipts/action.json';schema='rusty.morphospace.workflow.validation_action.v2';sha256=('d'*64)};$capsuleRef=[pscustomobject]@{role='authority-input-capsule';path='receipts/capsule.json';schema='rusty.morphospace.workflow.authority_input_capsule.v1';sha256=('e'*64)};$hostRef=[pscustomobject]@{role='authority-host-capabilities';path='receipts/host.json';schema='rusty.morphospace.workflow.authority_host_capabilities.v1';sha256=('f'*64)};$releaseRef=[pscustomobject]@{role='authority-runner-release';path='receipts/release.json';schema='rusty.morphospace.workflow.authority_runner_release.v1';sha256=('1'*64)}
    $probeUnit=[pscustomobject]@{project_id='readiness-test';unit_id='unit-test';risk_tier='quick';device_requirement='none';acceptance=@([pscustomobject]@{acceptance_id='criterion-a'})}
    $unitContractText="quick`nnone`ncriterion-a";$probeDocument=[pscustomobject]@{schema='rusty.morphospace.workflow.owner_validator_admission_probe.v1';validator_id='owner-test';created_at='2026-07-13T10:00:00.0000000Z';project_id='readiness-test';unit_id='unit-test';unit_contract_sha256=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$unitContractText});commands=@([pscustomobject]@{command_id='command-a';command_name='command-a.ps1';command_sha256=('4'*64)});acceptance_bindings=@([pscustomobject]@{acceptance_id='criterion-a';command_id='command-a'});status='pass';does_not_prove=@('Admission only.')}
    Test-MorphospaceOwnerValidatorAdmissionProbeV1 $probeDocument $validator $probeUnit|Out-Null
    $probe=[pscustomobject]@{validator_id='owner-test';status='pass';exit_code=0;probe_schema='rusty.morphospace.workflow.owner_validator_admission_probe.v1';probe_sha256=('4'*64);stdout_sha256=('5'*64);stderr_sha256=('6'*64)}
    $preflight=New-MorphospaceAuthorityPreflightV2 'readiness-test' 'unit-test' 'attempt-test' $actionRef $capsuleRef $hostRef $releaseRef $probe ('2'*64) $true
    Test-MorphospaceAuthorityPreflightV2 $preflight $actionRef $capsuleRef $hostRef $releaseRef 'readiness-test' 'unit-test' 'attempt-test'|Out-Null
    $stale=($preflight|ConvertTo-Json -Depth 20|ConvertFrom-Json);$stale.capsule.sha256=('3'*64)
    Assert-Rejected {Test-MorphospaceAuthorityPreflightV2 $stale $actionRef $capsuleRef $hostRef $releaseRef 'readiness-test' 'unit-test' 'attempt-test'|Out-Null} 'stale preflight capsule was accepted'
    $wrongIdentity=($preflight|ConvertTo-Json -Depth 20|ConvertFrom-Json);$wrongIdentity.unit_id='other-unit'
    Assert-Rejected {Test-MorphospaceAuthorityPreflightV2 $wrongIdentity $actionRef $capsuleRef $hostRef $releaseRef 'readiness-test' 'unit-test' 'attempt-test'|Out-Null} 'wrong preflight identity was accepted'
    $forgedProbe=($preflight|ConvertTo-Json -Depth 20|ConvertFrom-Json);$forgedProbe.validator_probe.probe_sha256='not-a-hash'
    Assert-Rejected {Test-MorphospaceAuthorityPreflightV2 $forgedProbe $actionRef $capsuleRef $hostRef $releaseRef 'readiness-test' 'unit-test' 'attempt-test'|Out-Null} 'malformed validator probe was accepted'
    $forgedAdmission=($probeDocument|ConvertTo-Json -Depth 20|ConvertFrom-Json);$forgedAdmission.acceptance_bindings[0].command_id='missing-command'
    Assert-Rejected {Test-MorphospaceOwnerValidatorAdmissionProbeV1 $forgedAdmission $validator $probeUnit|Out-Null} 'admission probe accepted an unbound command'

    $context=New-MorphospaceAuthorityReportContext 'readiness-test' 'unit-test' 'attempt-test' preflight;$contextRoot=[string]$context.root
    try{
        try{throw 'nested readiness failure'}catch{$report=Write-MorphospaceAuthorityFailureReport $context 'sealed-validator-admission' $_ ([DateTime]::UtcNow);Write-MorphospaceAuthorityStageResult $context 'sealed-validator-admission' fail ([DateTime]::UtcNow) -FailureReportPath $context.failure_report|Out-Null}
        Assert-Readiness ([IO.File]::Exists($context.failure_report)-and[IO.File]::Exists($context.stage_result)) 'typed failure/stage reports were not retained'
        Assert-Rejected {Write-MorphospaceAuthorityStageResult $context 'sealed-validator-admission' fail ([DateTime]::UtcNow)|Out-Null} 'stage result overwrite was accepted'
    }finally{if([IO.Directory]::Exists($contextRoot)){[IO.Directory]::Delete($contextRoot,$true)}}
    Assert-Readiness (-not[IO.Directory]::Exists($contextRoot)) 'readiness report-context fixture left its owned run directory behind'

    $authoritySources=@('scripts/Invoke-MorphospaceValidationAuthority.ps1','scripts/WorkUnitAutomation.psm1','scripts/lib/MorphospaceAuthorityProcess.psm1','scripts/lib/MorphospaceOwnership.psm1','scripts/lib/MorphospaceValidationAuthority.psm1','scripts/lib/MorphospaceAuthorityReadiness.psm1')
    foreach($relative in $authoritySources){$path=Join-Path $root $relative;$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);if($errors){throw "Authority source does not parse: $relative"};$ambient=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and[string]$node.GetCommandName()-ceq'Get-FileHash'},$true));Assert-Readiness ($ambient.Count-eq0) "authority source uses ambient Get-FileHash: $relative"}
    foreach($relative in @('scripts/Invoke-MorphospaceValidationAuthority.ps1','scripts/lib/MorphospaceValidationAuthority.psm1','scripts/lib/MorphospaceAuthorityReadiness.psm1')){$text=Get-Content -LiteralPath (Join-Path $root $relative) -Raw;Assert-Readiness (-not($text.Contains('Start-Process')-and$text.Contains('RedirectStandardOutput'))) "timed authority launcher still delegates capture-file lifetime to Start-Process: $relative"}
    $processText=Get-Content -LiteralPath (Join-Path $root 'scripts/lib/MorphospaceAuthorityProcess.psm1') -Raw;$assignIndex=$processText.IndexOf('$job.AssignProcess($process.Handle)',[StringComparison]::Ordinal);$launchIndex=$processText.IndexOf('$process.StandardInput.WriteLine(''launch'')',[StringComparison]::Ordinal)
    Assert-Readiness ($processText.Contains('JobObjectLimitKillOnJobClose')-and$processText.Contains('TerminateJobObject')-and$processText.Contains('QueryInformationJobObject')-and$processText.Contains('ActiveProcesses')-and$processText.Contains("if(-not`$IsWindows){throw 'Authority process supervision requires Windows Job Object support.'}")-and$assignIndex-ge0-and$launchIndex-gt$assignIndex) 'authority process supervision lost kill-on-close, terminal accounting, Windows fail-closed, or assign-before-launch containment'
    $runnerText=Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-MorphospaceValidationAuthority.ps1') -Raw
    Assert-Readiness ($runnerText.Contains('function Invoke-MorphospaceIsolatedAuthoritySelfTest')-and@([regex]::Matches($runnerText,'Invoke-MorphospaceIsolatedAuthoritySelfTest -Migration \$migration')).Count-eq3) 'record self-tests are not isolated child processes'
    Assert-Readiness ($runnerText.Contains('-ProbeOnly')-and$runnerText.Contains('Test-MorphospaceOwnerValidatorAdmissionProbeV1')) 'preflight does not use the bounded typed validator admission probe'
    foreach($selfTestName in @('Test-ValidationAuthorityLauncher.ps1','Test-AuthorityRunnerHandoff.ps1','Test-TrustMigrationAuthority.ps1')){Assert-Readiness (-not$runnerText.Contains("& (Join-Path `$PSScriptRoot '$selfTestName')")) "record self-test still mutates the authority process module graph: $selfTestName"}

    $validationModuleText=Get-Content -LiteralPath (Join-Path $root 'scripts\lib\MorphospaceValidationAuthority.psm1') -Raw
    Assert-Readiness (-not$runnerText.Contains('__path')-and-not$validationModuleText.Contains('Add-Member -NotePropertyName __path')) 'authority path metadata is still injected into strict schema documents'

    Write-Host 'Authority record-readiness self-test passed.'
}finally{
    foreach($pidPath in $adversaryPidFiles){if([IO.File]::Exists($pidPath)){$pidText=[IO.File]::ReadAllText($pidPath).Trim();if($pidText-match'^[0-9]+$'){[void]$adversaryPids.Add([int]$pidText)}}}
    foreach($adversaryPid in @($adversaryPids|Sort-Object)){$adversaryProcess=$null;try{$adversaryProcess=[Diagnostics.Process]::GetProcessById($adversaryPid);if(-not$adversaryProcess.HasExited){$adversaryProcess.Kill($true);if(-not$adversaryProcess.WaitForExit(10000)){throw "Adversarial fixture process did not terminate during cleanup: $adversaryPid"}}}catch [ArgumentException]{}finally{if($null-ne$adversaryProcess){$adversaryProcess.Dispose()}}}
    if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}
}
