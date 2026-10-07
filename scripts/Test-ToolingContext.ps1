param([switch]$ArtifactSelectionOnly,[string]$ActualIntentPath='', [string]$ExpectedActualIntentSha256='', [switch]$SelfTest,[switch]$Child,[switch]$KeepFailedFixture,[string]$OldCommit='',[string]$NewCommit='',[string]$HarnessRoot='',[ValidateSet('all','lifecycle','recovery','product-negative','provenance-negative','instruction-context','ready-lifecycle')][string]$Scenario='all',[ValidateSet('all','after-intent','after-artifact','after-projection','after-event')][string]$RecoveryFault='all')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:TestClosurePaths=$null
$script:ToolingTestClock=[Diagnostics.Stopwatch]::StartNew()
function Write-TCPhase([string]$Name){[Console]::Error.WriteLine(('tooling_context_phase={0}; elapsed_seconds={1:N1}' -f $Name,$script:ToolingTestClock.Elapsed.TotalSeconds))}
if(-not$SelfTest){throw 'Test-ToolingContext requires -SelfTest.'}
trap { [Console]::Error.WriteLine("$($_.Exception.Message)`n$($_.ScriptStackTrace)"); exit 1 }

if($ArtifactSelectionOnly){
 $pairModule=Import-Module (Join-Path $PSScriptRoot 'ToolingContextUpgrade.psm1') -Force -PassThru
 $pairProtocol=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
 $pairCases=0
 function Assert-PairCase([bool]$Ok,[string]$Name){if(-not$Ok){throw "Artifact-selection case failed: $Name"};$script:pairCases++}
 function New-PairArtifact([string]$Json){$body=[Text.UTF8Encoding]::new($false).GetBytes($Json);[pscustomobject]@{path='receipts/fixture.json';bytes_base64=[Convert]::ToBase64String($body);sha256=(&$pairProtocol {param($b)Get-MorphospaceSha256Bytes $b} $body)}}
 function New-PairIntent { [pscustomobject]@{artifacts=@(New-PairArtifact '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","value":"request"}';New-PairArtifact '{"schema":"rusty.morphospace.workflow.tooling_context.v1","value":"context"}')} }
 function Test-PairEquivalent($Intent,[string]$Name){
  $old=&$pairModule {param($i) [pscustomobject]@{request=Get-ToolingUpgradeArtifactDocument $i 'rusty.morphospace.workflow.tooling_context_upgrade.v1';context=Get-ToolingUpgradeArtifactDocument $i 'rusty.morphospace.workflow.tooling_context.v1'}} $Intent
  $new=&$pairModule {param($i)Get-ToolingUpgradeArtifactPair $i} $Intent
  foreach($role in @('request','context')){
   Assert-PairCase (($old.$role.bytes.Length-eq$new.$role.bytes.Length)-and[Convert]::ToBase64String($old.$role.bytes)-ceq[Convert]::ToBase64String($new.$role.bytes)) "$Name/$role raw"
   $hashes=&$pairProtocol {param($a,$b) @(Get-MorphospaceCanonicalJsonSha256 $a;Get-MorphospaceCanonicalJsonSha256 $b)} $old.$role.document $new.$role.document
   Assert-PairCase ($hashes[0]-ceq$hashes[1]) "$Name/$role canonical"
  }
 }
 function Test-PairRejected($Intent,[string]$Name){
  $oldDenied=$false;$newDenied=$false
  try{&$pairModule {param($i)Get-ToolingUpgradeArtifactDocument $i 'rusty.morphospace.workflow.tooling_context_upgrade.v1';Get-ToolingUpgradeArtifactDocument $i 'rusty.morphospace.workflow.tooling_context.v1'} $Intent|Out-Null}catch{$oldDenied=$true}
  try{&$pairModule {param($i)Get-ToolingUpgradeArtifactPair $i} $Intent|Out-Null}catch{$newDenied=$true}
  Assert-PairCase ($oldDenied-and$newDenied) $Name
 }
 Test-PairEquivalent (New-PairIntent) 'ordinary'
 $unicode=New-PairIntent;$unicode.artifacts[0]=New-PairArtifact '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","text":"\uD83D\uDE80\n\t\\\"","min":-9223372036854775808,"max":9223372036854775807,"array":[null,true,false,0]}'
 Test-PairEquivalent $unicode 'unicode-and-numeric-boundaries'
 $literal=New-PairIntent;$literal.artifacts[0]=New-PairArtifact ('{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","text":"'+[char]0x00e9+[char]0xd83d+[char]0xde80+'"}')
 Test-PairEquivalent $literal 'literal-utf8'
 foreach($body in @(
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","x":1.0}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","x":1e0}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","x":9223372036854775808}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","x":-9223372036854775809}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","x":01}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","x":"\uD800"}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","x":"\uDC00"}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","X":1,"x":2}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1","x":1,"x":2}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1",}',
 '{"schema":"rusty.morphospace.workflow.tooling_context_upgrade.v1"} false',
 '[1,2]')){$bad=New-PairIntent;$bad.artifacts[0]=New-PairArtifact $body;Test-PairRejected $bad 'strict-json-negative'}
 foreach($rawBad in @([byte[]](0xc3,0x28),[byte[]](0xef,0xbb,0xbf,0x7b,0x7d),[byte[]](0x7b,0x00,0x7d))){$bad=New-PairIntent;$bad.artifacts[0].bytes_base64=[Convert]::ToBase64String($rawBad);$bad.artifacts[0].sha256=(&$pairProtocol {param($b)Get-MorphospaceSha256Bytes $b} $rawBad);Test-PairRejected $bad 'invalid-utf8-bom-or-nul'}
 # Count only the selection seam with a tiny decoder stub; all strict-format
 # equivalence and rejection cases above and actual input below use the real decoder.
 $bad=New-PairIntent;$bad.artifacts[0].bytes_base64='!';Test-PairRejected $bad 'invalid-base64'
 $bad=New-PairIntent;$bad.artifacts[1].sha256='0'*64;Test-PairRejected $bad 'wrong-hash'
 $bad=New-PairIntent;$bad.artifacts=@($bad.artifacts[0]);Test-PairRejected $bad 'missing-context'
 $bad=New-PairIntent;$bad.artifacts=@($bad.artifacts[1]);Test-PairRejected $bad 'missing-request'
 $bad=New-PairIntent;$bad.artifacts+=,$bad.artifacts[0];Test-PairRejected $bad 'duplicate-request'
 $bad=New-PairIntent;$bad.artifacts+=,$bad.artifacts[1];Test-PairRejected $bad 'duplicate-context'
 $bad=New-PairIntent;$bad.artifacts[1]=New-PairArtifact '{"schema":"RUSTY.morphospace.workflow.tooling_context.v1"}';Test-PairRejected $bad 'schema-case'
 $bad=New-PairIntent;$bad.artifacts+=,(New-PairArtifact '{"schema":"unused","x":1.5}');Test-PairRejected $bad 'malformed-unused-artifact'
 $bad=New-PairIntent;$bad.artifacts+=,(New-PairArtifact '{"schema":"unused"}');$bad.artifacts[2].sha256='0'*64;Test-PairRejected $bad 'wrong-hash-unused-artifact'
 $unused=New-PairIntent;$unused.artifacts+=,(New-PairArtifact '{"schema":"unused","x":1}');Test-PairEquivalent $unused 'authenticated-unused-artifact'
 &$pairModule {$script:PairTestDecodeCount=0;function script:ConvertFrom-MorphospaceProtocolJsonBytes {param([byte[]]$Bytes,[string]$Context)$script:PairTestDecodeCount++;[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)|ConvertFrom-Json -DateKind String}}
 try{
  $fixture=New-PairIntent
  &$pairModule {param($i)Get-ToolingUpgradeArtifactPair $i|Out-Null} $fixture
  Assert-PairCase ((&$pairModule {$script:PairTestDecodeCount})-eq2) 'one-decode-per-artifact'
  &$pairModule {param($i)Get-ToolingUpgradeArtifactPair $i|Out-Null} $fixture
  Assert-PairCase ((&$pairModule {$script:PairTestDecodeCount})-eq4) 'next-call-redecodes'
  $fixture.artifacts[0].sha256='0'*64;Test-PairRejected $fixture 'next-call-drift-denies'
 }finally{&$pairModule {Remove-Item Function:ConvertFrom-MorphospaceProtocolJsonBytes;Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force;Remove-Variable PairTestDecodeCount -Scope Script}}
 $actualRows=@()
 if($ActualIntentPath){
  if($ExpectedActualIntentSha256-cnotmatch'^[0-9a-f]{64}$'){throw 'Actual artifact-selection input requires its exact SHA-256.'}
  $raw=[IO.File]::ReadAllBytes($ActualIntentPath)
  if((&$pairProtocol {param($b)Get-MorphospaceSha256Bytes $b} $raw)-cne$ExpectedActualIntentSha256){throw 'Actual artifact-selection input bytes drifted.'}
  $actual=&$pairProtocol {param($b)ConvertFrom-MorphospaceProtocolJsonBytes $b 'actual artifact selection'} $raw
  Test-PairEquivalent $actual 'actual-retained-intent'
  for($trial=0;$trial-lt3;$trial++){
   $clock=[Diagnostics.Stopwatch]::StartNew();&$pairModule {param($i)Get-ToolingUpgradeArtifactDocument $i 'rusty.morphospace.workflow.tooling_context_upgrade.v1'|Out-Null;Get-ToolingUpgradeArtifactDocument $i 'rusty.morphospace.workflow.tooling_context.v1'|Out-Null} $actual;$clock.Stop();$oldMs=$clock.Elapsed.TotalMilliseconds
   $clock.Restart();&$pairModule {param($i)Get-ToolingUpgradeArtifactPair $i|Out-Null} $actual;$clock.Stop()
   $actualRows+=@{trial=$trial;old_ms=$oldMs;paired_ms=$clock.Elapsed.TotalMilliseconds;old_decodes=4;paired_decodes=2}
  }
 }
 [pscustomobject]@{result='pass';cases=$pairCases;action='authenticated-artifact-pair';actual_input_sha256=$ExpectedActualIntentSha256;microprofile=$actualRows;device_calls=0;aggregate_invoked=$false}|ConvertTo-Json -Depth 8
 return
}

function Remove-ToolingTestRoot([string]$Path){$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');$target=[IO.Path]::GetFullPath($Path).TrimEnd('\','/');if(-not([IO.Path]::GetDirectoryName($target).Equals($temp,[StringComparison]::OrdinalIgnoreCase))-or-not([IO.Path]::GetFileName($target).StartsWith('tooling-context-', [StringComparison]::Ordinal))){throw "Refusing tooling-context fixture cleanup: $target"};if(Test-Path $target){Remove-Item -LiteralPath $target -Recurse -Force}}
if(-not$Child){
 $sourceRoot=Split-Path $PSScriptRoot -Parent;$root=if($HarnessRoot){[IO.Path]::GetFullPath($HarnessRoot)}else{Join-Path ([IO.Path]::GetTempPath()) ('tooling-context-'+[guid]::NewGuid().ToString('N'))};if(Test-Path -LiteralPath $root){throw 'Tooling-context parent fixture root already exists.'};Remove-ToolingTestRoot $root;$tool=Join-Path $root 'tool-owner';$preserve=$false
 $readyProcess=$null;$readyOutput=$null;$readyError=$null;$readyRoot=Join-Path ([IO.Path]::GetTempPath()) ('tooling-context-'+[guid]::NewGuid().ToString('N'));$readyClock=[Diagnostics.Stopwatch]::StartNew()
 try{
  if($Scenario-in@('all','lifecycle')){
   # Independent fixture roots and child process: no shared Git checkout,
   # project ledger, router installation, modules, or external effects.
   $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(@(Get-Command pwsh -CommandType Application)[0]).Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
   foreach($argument in @('-NoProfile','-NonInteractive','-File',(Join-Path $sourceRoot 'scripts/Test-ToolingContext.ps1'),'-SelfTest','-Scenario','ready-lifecycle','-HarnessRoot',$readyRoot)){[void]$start.ArgumentList.Add($argument)}
   if($KeepFailedFixture){[void]$start.ArgumentList.Add('-KeepFailedFixture')}
   $readyProcess=[Diagnostics.Process]::new();$readyProcess.StartInfo=$start;[void]$readyProcess.Start();$readyOutput=$readyProcess.StandardOutput.ReadToEndAsync();$readyError=$readyProcess.StandardError.ReadToEndAsync()
  }
  [IO.Directory]::CreateDirectory($tool)|Out-Null;foreach($name in @('.github','config','docs','examples','fixtures','manifests','schemas','scripts','skills','templates','tools')){Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $tool $name) -Recurse};foreach($name in @('.gitattributes','.gitignore','AGENTS.md','CHANGELOG.md','CONTRIBUTING.md','LICENSE','NOTICE.md','README.md','SECURITY.md')){Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $tool $name)};foreach($file in @(Get-ChildItem -LiteralPath $tool -Recurse -File)){if(@('.ps1','.psm1','.psd1','.json','.md','.yml','.yaml','.toml','.txt','.gitignore','.gitattributes')-contains$file.Extension-or$file.Name-in@('.gitignore','.gitattributes')){$text=[IO.File]::ReadAllText($file.FullName);if($text.IndexOf([char]0)-lt0){[IO.File]::WriteAllText($file.FullName,$text.Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))}}}
  & git -C $tool init --initial-branch=main|Out-Null;& git -C $tool config user.name 'Tooling Context Test';& git -C $tool config user.email 'tooling-context@example.invalid';& git -C $tool config commit.gpgsign false;& git -C $tool config core.autocrlf false;& git -C $tool remote add origin 'https://example.invalid/work-environment.git';& git -C $tool add --all;& git -C $tool commit -m 'old tooling context'|Out-Null;& git -C $tool checkout-index -a -f;& git -C $tool reset --hard HEAD|Out-Null;$old=(& git -C $tool rev-parse HEAD).Trim().ToLowerInvariant()
  [IO.File]::AppendAllText((Join-Path $tool 'scripts/ToolingContextUpgrade.psm1'),"`n# fixture new tooling revision`n",[Text.UTF8Encoding]::new($false));& git -C $tool add scripts/ToolingContextUpgrade.psm1;& git -C $tool commit -m 'new tooling context'|Out-Null;& git -C $tool checkout-index -a -f;& git -C $tool reset --hard HEAD|Out-Null
   $new=(& git -C $tool rev-parse HEAD).Trim().ToLowerInvariant();& pwsh -NoProfile -File (Join-Path $tool 'scripts/Test-ToolingContext.ps1') -SelfTest -Child -OldCommit $old -NewCommit $new -HarnessRoot $root -Scenario $Scenario -RecoveryFault $RecoveryFault
  if($LASTEXITCODE-ne0){throw "Tooling-context bound-child self-test failed with exit code $LASTEXITCODE."}
  if($null-ne$readyProcess){
   $remaining=[Math]::Max(0,590000-[int]$readyClock.ElapsedMilliseconds)
   if(-not$readyProcess.WaitForExit($remaining)){throw 'Independent Ready tooling child exceeded the shared bounded lifecycle deadline.'}
   if(-not[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($readyOutput,$readyError),5000)){throw 'Independent Ready tooling child output drain exceeded its bounded deadline.'}
   $readyStdout=$readyOutput.GetAwaiter().GetResult();$readyStderr=$readyError.GetAwaiter().GetResult()
   if($readyStdout){[Console]::Out.Write($readyStdout)};if($readyStderr){[Console]::Error.Write($readyStderr)}
   if($readyProcess.ExitCode-ne0){throw "Independent Ready tooling child failed with exit code $($readyProcess.ExitCode)."}
  }

  }catch{if($KeepFailedFixture){$preserve=$true;[Console]::Error.WriteLine("tooling_context_failed_fixture=$root")};throw}finally{
   if($null-ne$readyProcess){
    if(-not$readyProcess.HasExited){$readyProcess.Kill($true);if(-not$readyProcess.WaitForExit(5000)){throw 'Independent Ready tooling child did not stop after bounded cancellation.'}}
    $readyProcess.Dispose()
    if(-not$KeepFailedFixture){Remove-ToolingTestRoot $readyRoot}
   }
   if(-not$preserve){Remove-ToolingTestRoot $root}
  }
 return
}

$repoRoot=Split-Path $PSScriptRoot -Parent
& git -C $repoRoot checkout --detach $OldCommit|Out-Null;if($LASTEXITCODE-ne0){throw 'Fixture could not materialize old tooling HEAD.'}
Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1')
$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$ledgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
$automationModule=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru
$provenanceModule=Import-Module (Join-Path $PSScriptRoot 'ToolingContextProvenance.psm1') -Force -PassThru
$upgradeModule=Import-Module (Join-Path $PSScriptRoot 'ToolingContextUpgrade.psm1') -Force -PassThru
. (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')
function Get-MorphospaceToolingContextAllowedActions { &$provenanceModule {Get-MorphospaceToolingContextAllowedActions} }
function New-MorphospaceToolingContext { [CmdletBinding()]param([string]$ContextId,[string]$ProjectId,[string]$PreparationId,[object]$ProductProjection,[object]$Resolver,[object]$Executor,[object[]]$Routers,[object]$Compatibility);&$provenanceModule {param($p)New-MorphospaceToolingContext @p} $PSBoundParameters }
function Invoke-MorphospaceUpgradeToolingContext { [CmdletBinding()]param([string]$WorkspaceRoot,[string]$UnitId,[string]$ToolingContextUpgrade,[string]$ExpectedToolingContextUpgradeSha256,[string]$OutPath,[string]$Timestamp,[string]$FaultAfter,[switch]$Execute);&$upgradeModule {param($p)Invoke-MorphospaceUpgradeToolingContext @p} $PSBoundParameters }
function Test-MorphospaceHistoricalToolingContextUpgrade { param([string]$WorkspaceRoot,[object]$ExpectedEvent);&$upgradeModule {param($w,$e)Test-MorphospaceHistoricalToolingContextUpgrade -WorkspaceRoot $w -ExpectedEvent $e} $WorkspaceRoot $ExpectedEvent }
function Assert-TC([bool]$Value,[string]$Name){if(-not$Value){throw "Tooling-context self-test failed: $Name"}}
function Assert-TCError([string]$Actual,[string]$Expected,[string]$Name){if($Actual-cne$Expected){throw "Tooling-context self-test unexpected $Name error: $Actual"};$true}
function Read-TC([string]$Path){&$protocolModule {param($p)Read-MorphospaceProtocolJson $p} $Path}
function ToBytes([object]$Value){&$protocolModule {param($v),[byte[]](ConvertTo-MorphospaceProtocolJsonBytes $v)} $Value}
function FromBytes([byte[]]$Bytes){&$protocolModule {param($b)ConvertFrom-MorphospaceProtocolJsonBytes $b} $Bytes}
function BytesHash([byte[]]$Bytes){&$protocolModule {param($b)Get-MorphospaceSha256Bytes $b} $Bytes}
function Write-TC([string]$Path,[object]$Value){$parent=Split-Path $Path -Parent;if(-not(Test-Path $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllBytes($Path,(ToBytes $Value))}
function FileHash([string]$Path){&$protocolModule {param($p)Get-MorphospaceFileSha256 $p} $Path}
function Canonical([object]$Value){&$protocolModule {param($v)Get-MorphospaceCanonicalJsonSha256 $v} $Value}
function Clone([object]$Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String}
function GitScalar([string]$Root,[string[]]$Arguments){$rows=@(& git -C $Root @Arguments 2>&1);if($LASTEXITCODE-ne0-or$rows.Count-ne1){throw "Fixture Git failed: $($Arguments-join' ')"};([string]$rows[0]).Trim().ToLowerInvariant()}
function GitBlob([string]$Root,[string]$Commit,[string]$Path){$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(@(Get-Command git -CommandType Application)[0]).Source;$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;foreach($a in @('-C',$Root,'cat-file','blob',"$Commit`:$Path")){[void]$start.ArgumentList.Add($a)};$p=[Diagnostics.Process]::new();$p.StartInfo=$start;[void]$p.Start();$m=[IO.MemoryStream]::new();$p.StandardOutput.BaseStream.CopyTo($m);$err=$p.StandardError.ReadToEnd();$p.WaitForExit();if($p.ExitCode-ne0){throw $err};$m.ToArray()}
function GitBlobMap([string]$Root,[string]$Commit,[string[]]$Paths){$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(@(Get-Command git -CommandType Application)[0]).Source;$start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.StandardInputEncoding=[Text.UTF8Encoding]::new($false);foreach($a in @('-C',$Root,'cat-file','--batch')){[void]$start.ArgumentList.Add($a)};$p=[Diagnostics.Process]::new();$p.StartInfo=$start;[void]$p.Start();$inputText=(@($Paths|ForEach-Object{"$Commit`:$($_)"})-join"`n")+"`n";$writeTask=$p.StandardInput.WriteAsync($inputText);$s=$p.StandardOutput.BaseStream;$map=@{};foreach($path in $Paths){$h=[Collections.Generic.List[byte]]::new();while(($b=$s.ReadByte())-ne10){if($b-lt0){throw 'Fixture batch header ended.'};if($b-ne13){$h.Add([byte]$b)}};$header=[Text.Encoding]::ASCII.GetString($h.ToArray());if($header-cnotmatch'^[0-9a-f]{40} blob (?<size>[0-9]+)$'){throw $header};$bytes=[byte[]]::new([int]$Matches.size);$o=0;while($o-lt$bytes.Length){$n=$s.Read($bytes,$o,$bytes.Length-$o);if($n-le0){throw 'Fixture batch payload ended.'};$o+=$n};if($s.ReadByte()-ne10){throw 'Fixture batch delimiter absent.'};$map[$path]=$bytes};[void]$writeTask.GetAwaiter().GetResult();$p.StandardInput.Close();$err=$p.StandardError.ReadToEnd();$p.WaitForExit();if($p.ExitCode-ne0){throw $err};$map}
function Get-ClosurePaths([string]$Root){
 if($null-ne$script:TestClosurePaths){return @($script:TestClosurePaths)}
 $records=@(git -C $Root ls-tree -r --full-tree HEAD|ForEach-Object{if([string]$_ -cnotmatch'^(?<mode>[0-9]{6})\s+(?<type>blob|tree|commit)\s+(?<oid>[0-9a-f]{40})\t(?<path>.+)$'){throw 'Fixture tree inventory malformed.'};[pscustomobject]@{mode=[string]$Matches.mode;type=[string]$Matches.type;oid=[string]$Matches.oid;path=([string]$Matches.path).Replace('\','/')}})
 $script:TestClosurePaths=@($records|Where-Object{[string]$_.type-ceq'blob'}|ForEach-Object{[string]$_.path}|Sort-Object -CaseSensitive);@($script:TestClosurePaths)
}
function New-Closure([string]$Tool,[string]$Commit){$paths=@(Get-ClosurePaths $Tool);$head=GitScalar $Tool @('rev-parse','HEAD');$blobs=$(if($Commit-cne$head){GitBlobMap $Tool $Commit $paths}else{$null});@($paths|ForEach-Object{$path=[string]$_;$bytes=if($null-eq$blobs){[IO.File]::ReadAllBytes((Join-Path $Tool $path))}else{[byte[]]($blobs[$path])};if($null-eq$bytes){throw "Fixture batch omitted '$path' ($($blobs.GetType().FullName)); count=$(@($blobs).Count)"};[pscustomobject][ordered]@{path=$path;sha256=BytesHash $bytes}})}
function New-RouterRoot([string]$Root,[string]$Id,[string]$Commit,[string]$Tree,[string]$Tool){$router=Join-Path $Root $Id;[IO.Directory]::CreateDirectory($router)|Out-Null;[IO.File]::WriteAllText((Join-Path $router 'SKILL.md'),"# $Id`n",[Text.UTF8Encoding]::new($false));$sha=FileHash (Join-Path $router 'SKILL.md');$fingerprint=Canonical ([pscustomobject]@{files=@([pscustomobject]@{path='SKILL.md';sha256=$sha})});$record=[pscustomobject][ordered]@{schema='rusty.morphospace.local_skill_source.v1';skill_id=$Id;installed_at='2026-09-15T08:00:00.0000000Z';source_repository='https://example.invalid/work-environment.git';source_commit=$Commit;source_worktree_dirty=$false;source_release='fixture';source_tree_sha256=$fingerprint;source_files=@([pscustomobject][ordered]@{path='SKILL.md';sha256=$sha});work_environment_root=$Tool};Write-TC (Join-Path $router '.morphospace-skill-source.json') $record;[pscustomobject]@{root=$router;row=[pscustomobject][ordered]@{skill_id=$Id;source_repo_id='workflow';commit=$Commit;tree=$Tree;source_fingerprint=$fingerprint;managed_files=@([pscustomobject][ordered]@{path='SKILL.md';sha256=$sha})}}}
function New-OwnerValidation([string]$BaseCommit,[string]$BaseTree,[string]$HeadCommit,[string]$HeadTree){$empty='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_evidence.v1';repository='MesmerPrism/rusty-morphospace-work-environment';base=[pscustomobject]@{commit=$BaseCommit;tree=$BaseTree};head=[pscustomobject]@{commit=$HeadCommit;tree=$HeadTree};plan_sha256='1'*64;platform='windows';runner=[pscustomobject]@{os_description='Windows tooling-context fixture';powershell_version=$PSVersionTable.PSVersion.ToString()};check_results=@([pscustomobject][ordered]@{check_id='tooling-context-contracts';command_path='scripts/Test-WorkflowContracts.ps1';command_blob_sha1=$HeadCommit;mode='executed';result='pass';started=$true;failure_kind=$null;exit_code=0;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout_sha256=$empty;stderr_sha256=$empty;stdout_bytes=0;stderr_bytes=0});result='pass';claims=[pscustomobject]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}}
function Save-Request([string]$Root,[object]$Request,[string]$Name){$path=Join-Path $Root $Name;Write-TC $path $Request;$path}
function Set-ContextFingerprint([object]$Context){$identity=[ordered]@{context_id=$Context.context_id;project_id=$Context.project_id;preparation_id=$Context.preparation_id;product_projection=$Context.product_projection;resolver=$Context.resolver;executor=$Context.executor;routers=$Context.routers;compatibility=$Context.compatibility;limits=$Context.limits;status=$Context.status};$Context.fingerprint=Canonical $identity;$Context}
function Invoke-Upgrade([object]$Fixture,[string]$RequestPath,[string]$Fault='none'){Invoke-MorphospaceUpgradeToolingContext -WorkspaceRoot $Fixture.workspace -UnitId 'u002' -ToolingContextUpgrade $RequestPath -ExpectedToolingContextUpgradeSha256 (FileHash $RequestPath) -OutPath (Join-Path $Fixture.workspace "receipts/$([string](Read-TC $RequestPath).upgrade_id)-tooling-context-upgrade-request.json") -Timestamp '2026-09-15T09:00:00.0000000Z' -Execute -FaultAfter $Fault}
function WorkspaceFingerprint([string]$Workspace){Canonical @(Get-ChildItem $Workspace -Recurse -File|Sort-Object FullName|ForEach-Object{[pscustomobject]@{p=$_.FullName.Substring($Workspace.Length).Replace('\','/');h=FileHash $_.FullName}})}

$tool=$repoRoot;$newCommit=$NewCommit;$oldTree=GitScalar $tool @('rev-parse',"$OldCommit^{tree}");$newTree=GitScalar $tool @('rev-parse',"$newCommit^{tree}");$fixtureRoot=Join-Path $HarnessRoot 'project-fixture';$workspace=Join-Path $fixtureRoot 'morphospace';foreach($d in @('receipts','local','tooling-contexts')){[IO.Directory]::CreateDirectory((Join-Path $workspace $d))|Out-Null}
Write-TC (Join-Path $workspace 'receipts/tool-validation-old.json') (New-OwnerValidation $OldCommit $oldTree $OldCommit $oldTree);Write-TC (Join-Path $workspace 'receipts/tool-validation-new.json') (New-OwnerValidation $OldCommit $oldTree $newCommit $newTree);$oldValidation=[pscustomobject]@{path='receipts/tool-validation-old.json';sha256=FileHash (Join-Path $workspace 'receipts/tool-validation-old.json')};$newValidation=[pscustomobject]@{path='receipts/tool-validation-new.json';sha256=FileHash (Join-Path $workspace 'receipts/tool-validation-new.json')}
$actions=@(Get-MorphospaceToolingContextAllowedActions);$protocol=[pscustomobject][ordered]@{protocol_id='tooling-context-v1';product_lock_schema='rusty.morphospace.workflow.development_envelope_source_composition.v3';repository_map_schema='rusty.morphospace.workflow.repository_map.v1';allowed_actions=$actions}
Write-TC (Join-Path $workspace 'receipts/tool-publication-old.json') ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.tooling_context_publication_evidence.v1';publication_id='tool-old-observed';executor=[pscustomobject][ordered]@{repo_id='workflow';remote_url='https://example.invalid/work-environment.git';commit=$OldCommit;tree=$oldTree};validation=$oldValidation;status='source-observed';does_not_prove=@('Does not independently prove remote publication authority.')})
Write-TC (Join-Path $workspace 'receipts/tool-publication-new.json') ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.tooling_context_publication_evidence.v1';publication_id='tool-new-observed';executor=[pscustomobject][ordered]@{repo_id='workflow';remote_url='https://example.invalid/work-environment.git';commit=$newCommit;tree=$newTree};validation=$newValidation;status='source-observed';does_not_prove=@('Does not independently prove remote publication authority.')})
Write-TC (Join-Path $workspace 'receipts/tool-protocol-old.json') ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.tooling_context_protocol_receipt.v1';receipt_id='tool-old-protocol';executor=[pscustomobject][ordered]@{repo_id='workflow';commit=$OldCommit;tree=$oldTree};protocol=$protocol;validation=$oldValidation;status='compatible';does_not_prove=@('Does not authorize product mutation.')})
Write-TC (Join-Path $workspace 'receipts/tool-protocol-new.json') ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.tooling_context_protocol_receipt.v1';receipt_id='tool-new-protocol';executor=[pscustomobject][ordered]@{repo_id='workflow';commit=$newCommit;tree=$newTree};protocol=$protocol;validation=$newValidation;status='compatible';does_not_prove=@('Does not authorize product mutation.')})
$oldRouterRoot=Join-Path $HarnessRoot 'router-old';$newRouterRoot=Join-Path $HarnessRoot 'router-new';$oldRouter=New-RouterRoot $oldRouterRoot 'rusty-morphospace' $OldCommit $oldTree $tool;$oldSystemRouter=New-RouterRoot $oldRouterRoot 'system-engineering' $OldCommit $oldTree $tool;$oldGraphRouter=New-RouterRoot $oldRouterRoot 'rust-work-graph' $OldCommit $oldTree $tool;$newRouter=New-RouterRoot $newRouterRoot 'rusty-morphospace' $newCommit $newTree $tool;$newSystemRouter=New-RouterRoot $newRouterRoot 'system-engineering' $newCommit $newTree $tool;$newGraphRouter=New-RouterRoot $newRouterRoot 'rust-work-graph' $newCommit $newTree $tool
foreach($row in @([pscustomobject]@{id='ctx-old';routers=@($oldRouter,$oldSystemRouter,$oldGraphRouter)},[pscustomobject]@{id='ctx-new';routers=@($newRouter,$newSystemRouter,$newGraphRouter)})){Write-TC (Join-Path $workspace "local/$($row.id)-resolver.json") ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.tooling_context_resolver.v1';context_id=$row.id;executor_root=$tool;routers=@($row.routers|ForEach-Object{[pscustomobject][ordered]@{skill_id=[string]$_.row.skill_id;root=[string]$_.root}});status='resolved';does_not_prove=@('Local resolution only.')})}
$oldCompat=[pscustomobject][ordered]@{protocol_id='tooling-context-v1';product_lock_schema='rusty.morphospace.workflow.development_envelope_source_composition.v3';repository_map_schema='rusty.morphospace.workflow.repository_map.v1';allowed_actions=$actions;receipt=[pscustomobject]@{path='receipts/tool-protocol-old.json';sha256=FileHash (Join-Path $workspace 'receipts/tool-protocol-old.json')}};$newCompat=Clone $oldCompat;$newCompat.receipt=[pscustomobject]@{path='receipts/tool-protocol-new.json';sha256=FileHash (Join-Path $workspace 'receipts/tool-protocol-new.json')}
$oldExecutor=[pscustomobject][ordered]@{repo_id='workflow';remote_url='https://example.invalid/work-environment.git';commit=$OldCommit;tree=$oldTree;publication_evidence=[pscustomobject]@{path='receipts/tool-publication-old.json';sha256=FileHash (Join-Path $workspace 'receipts/tool-publication-old.json')};entrypoint='scripts/ToolingContextUpgrade.psm1';closure=New-Closure $tool $OldCommit};$newExecutor=Clone $oldExecutor;$newExecutor.commit=$newCommit;$newExecutor.tree=$newTree;$newExecutor.publication_evidence=[pscustomobject]@{path='receipts/tool-publication-new.json';sha256=FileHash (Join-Path $workspace 'receipts/tool-publication-new.json')};$newExecutor.closure=New-Closure $tool $newCommit
$descriptor=[pscustomobject][ordered]@{context_id='ctx-old';path='tooling-contexts/ctx-old.json';resolver=[pscustomobject]@{path='local/ctx-old-resolver.json';sha256=FileHash (Join-Path $workspace 'local/ctx-old-resolver.json')};executor=$oldExecutor;routers=@($oldRouter.row,$oldSystemRouter.row,$oldGraphRouter.row);compatibility=$oldCompat}
$seed=New-EnvelopeAdmissionPreparedFixture -Root $fixtureRoot -RepositoryRoot $repoRoot -TransitionLedgerModule $ledgerModule -OwnerProducedPreparation -NearestAgentInstructions -ToolingContextDescriptor $descriptor;$workspace=$seed.workspace
$projection=[pscustomobject][ordered]@{source_composition=[pscustomobject][ordered]@{path='source-composition.json';sha256=FileHash (Join-Path $workspace 'source-composition.json')};repository_map=[pscustomobject][ordered]@{path='repository-map.json';sha256=FileHash (Join-Path $workspace 'repository-map.json')};feature_lock=[pscustomobject][ordered]@{path='feature.lock.json';sha256=FileHash (Join-Path $workspace 'feature.lock.json')}}
$old=Read-TC (Join-Path $workspace 'tooling-contexts/ctx-old.json')
$new=New-MorphospaceToolingContext -ContextId 'ctx-new' -ProjectId 'envelope-test' -PreparationId 'u002-envelope' -ProductProjection $projection -Resolver ([pscustomobject]@{path='local/ctx-new-resolver.json';sha256=FileHash (Join-Path $workspace 'local/ctx-new-resolver.json')}) -Executor $newExecutor -Routers @($newRouter.row,$newSystemRouter.row,$newGraphRouter.row) -Compatibility $newCompat
$oldPointer=Clone $seed.preparation_receipt.tooling_context
$admission=Clone $seed.admission_template;
# This fixture's planning root needs a nearest instruction surface for the shortcut.
# Declare it before the actual admission producer; never alter an admitted unit.
[IO.File]::WriteAllText((Join-Path $seed.source_repository 'AGENTS.md'),"# Fixture agent instructions`nUse the bound owner tooling; perform no external effects.`n",[Text.UTF8Encoding]::new($false))
$admission.unit.instruction_surfaces+=,[pscustomobject][ordered]@{surface_kind='agents';path='<project-shell>/AGENTS.md';owner='project-owner';change_reason='Review the nearest fixture planning instructions.';action='review-no-change';status='complete';validation='Read the fixture AGENTS.md before owner admission.';skill_id=$null}
if($admission.PSObject.Properties.Name-cnotcontains'admission_kind'){$admission|Add-Member -NotePropertyName admission_kind -NotePropertyValue 'ordinary'};if($admission.preparation.PSObject.Properties.Name-cnotcontains'preparation_kind'){$admission.preparation|Add-Member -NotePropertyName preparation_kind -NotePropertyValue 'ordinary'};$admissionPath=Join-Path $HarnessRoot 'admission.json';Write-TC $admissionPath $admission;Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (FileHash $admissionPath) -OutPath (Join-Path $workspace 'receipts/u002-admission.json') -Timestamp '2026-09-15T08:10:00.0000000Z' -Execute|Out-Null
$args=@{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=(Join-Path $workspace 'repository-map.json');ValidationTier='quick'};&$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Ready -Timestamp '2026-09-15T08:11:00.0000000Z' -Execute} $args|Out-Null;$readyBase=Join-Path $HarnessRoot 'ready-base';Copy-Item -LiteralPath $workspace -Destination $readyBase -Recurse;if($Scenario-cne'ready-lifecycle'){&$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Claim -Timestamp '2026-09-15T08:12:00.0000000Z' -Execute} $args|Out-Null}
# Exercise the actual shortcut CLI against owner-produced active tooling context.
# The lifecycle registration includes these cases; the focused scenario omits upgrades.
if($Scenario-in@('all','lifecycle','instruction-context')){
 $instructionCases=0
 function Invoke-TCInstructionShortcut([bool]$IncludeMap=$true){
  $cliArgs=@('-NoProfile','-NonInteractive','-File',(Join-Path $tool 'scripts/Test-WorkflowContracts.ps1'),'-RepoRoot',$tool,'-WorkspaceRoot',$workspace,'-CurrentUnitInstructionOnly')
  if($IncludeMap){$cliArgs+=@('-RepositoryMapPath',(Join-Path $workspace 'repository-map.json'))}
  $text=(& pwsh @cliArgs 2>&1|Out-String)
  [pscustomobject]@{exit_code=$LASTEXITCODE;text=$text}
 }
 function Assert-TCInstructionShortcut($Result,[bool]$Expected,[string]$Name){
  $marker=if($Expected){'Current-unit instruction contract passed;'}else{'review lacks exact owner-tracked provenance'}
  if(($Result.exit_code-eq0)-ne$Expected-or$Result.text-notmatch[regex]::Escape($marker)){throw "Instruction shortcut case '$Name' failed: $($Result.text)"}
  $script:instructionCases++
 }
 Assert-TCInstructionShortcut (Invoke-TCInstructionShortcut) $true 'actual prepared tooling context'
 Assert-TCInstructionShortcut (Invoke-TCInstructionShortcut $false) $false 'missing repository map'
 $contextFile=Join-Path $workspace 'tooling-contexts/ctx-old.json'
 $contextBytes=[IO.File]::ReadAllBytes($contextFile)
 try{
  [IO.File]::AppendAllText($contextFile,' ',[Text.UTF8Encoding]::new($false))
  Assert-TCInstructionShortcut (Invoke-TCInstructionShortcut) $false 'damaged raw context pin'
 }finally{[IO.File]::WriteAllBytes($contextFile,$contextBytes)}
 $resolverFile=Join-Path $workspace 'local/ctx-old-resolver.json'
 $resolverBytes=[IO.File]::ReadAllBytes($resolverFile)
 try{
  $resolver=Read-TC $resolverFile;$resolver.context_id='ctx-unrelated';Write-TC $resolverFile $resolver
  Assert-TCInstructionShortcut (Invoke-TCInstructionShortcut) $false 'mismatched resolver context'
 }finally{[IO.File]::WriteAllBytes($resolverFile,$resolverBytes)}
 try{
  [IO.File]::Move($contextFile,"$contextFile.absent")
  Assert-TCInstructionShortcut (Invoke-TCInstructionShortcut) $false 'absent context document'
 }finally{if([IO.File]::Exists("$contextFile.absent")){[IO.File]::Move("$contextFile.absent",$contextFile)}}
 Assert-TCInstructionShortcut (Invoke-TCInstructionShortcut) $true 'restored exact context'
 Write-TCPhase 'instruction-context-complete'
 if($Scenario-ceq'instruction-context'){
  [pscustomobject]@{result='pass';scenario=$Scenario;production_shortcut_cases=$instructionCases;real_git=$true;owner_produced_preparation=$true;guard_mocked=$false;device_calls=0}|ConvertTo-Json -Compress
  return
 }
}
& git -C $tool checkout --detach $newCommit|Out-Null;if($LASTEXITCODE-ne0){throw 'Fixture could not advance to new tooling HEAD.'};$automationModule=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force -PassThru;$provenanceModule=Import-Module (Join-Path $PSScriptRoot 'ToolingContextProvenance.psm1') -Force -PassThru;$upgradeModule=Import-Module (Join-Path $PSScriptRoot 'ToolingContextUpgrade.psm1') -Force -PassThru
$base=Join-Path $HarnessRoot 'active-base';Copy-Item -LiteralPath $workspace -Destination $base -Recurse
Write-TCPhase 'setup-complete'
function New-UpgradeRequest([string]$Workspace,[string]$Id,[object]$NewContext=$new){
 $state=Read-TC (Join-Path $Workspace 'workspace.state.json');$unit=Read-TC (Join-Path $Workspace 'iteration-units/u002.json');$events=Join-Path $Workspace 'iteration-events.jsonl';$newBytes=ToBytes $NewContext
 $proof=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.tooling_context_compatibility_receipt.v1';proof_id="$Id-proof";project_id='envelope-test';old_context=[pscustomobject]@{context_id=$old.context_id;fingerprint=$old.fingerprint;commit=$old.executor.commit;tree=$old.executor.tree};new_context=[pscustomobject]@{context_id=$NewContext.context_id;fingerprint=$NewContext.fingerprint;commit=$NewContext.executor.commit;tree=$NewContext.executor.tree};consumer=[pscustomobject]@{protocol_id='tooling-context-v1';product_projection=$projection;allowed_actions=$actions};validation=[pscustomobject]@{evidence=[pscustomobject]@{path='receipts/tool-validation-new.json';sha256=FileHash (Join-Path $Workspace 'receipts/tool-validation-new.json')};result='pass'};claims=[pscustomobject]@{same_product_projection=$true;protocol_compatible=$true};status='compatible';does_not_prove=@('Does not validate or publish product bytes.')};$proofPath="receipts/$Id-compatibility.json";Write-TC (Join-Path $Workspace $proofPath) $proof
 [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.tooling_context_upgrade.v1';upgrade_id=$Id;project_id='envelope-test';unit_id='u002';old_context=$oldPointer;new_context=[pscustomobject][ordered]@{path="tooling-contexts/$($NewContext.context_id).json";sha256=BytesHash $newBytes;canonical_sha256=Canonical $NewContext;protocol_id='tooling-context-v1';document=$NewContext};product_projection=$projection;compatibility_receipt=[pscustomobject]@{path=$proofPath;sha256=FileHash (Join-Path $Workspace $proofPath)};expected=[pscustomobject][ordered]@{state_sha256=Canonical $state;state_raw_sha256=FileHash (Join-Path $Workspace 'workspace.state.json');unit_sha256=Canonical $unit;unit_raw_sha256=FileHash (Join-Path $Workspace 'iteration-units/u002.json');events_sha256=FileHash $events;events_length=[IO.FileInfo]::new($events).Length;event_tail_id=[string]$state.last_event_id};does_not_prove=@('Does not mutate product inputs.')}
}
function New-Case([string]$Name){$case=Join-Path $HarnessRoot $Name;Copy-Item -LiteralPath $base -Destination $case -Recurse;[pscustomobject]@{workspace=$case}}



if($Scenario-in@('all','lifecycle')){$positive=New-Case 'positive';$request=New-UpgradeRequest $positive.workspace 'upgrade-positive';$requestPath=Save-Request $HarnessRoot $request 'upgrade-positive.json';$productBefore=(@($projection.PSObject.Properties|ForEach-Object{FileHash (Join-Path $positive.workspace ([string]$_.Value.path))}))-join'|';$dry=Invoke-MorphospaceUpgradeToolingContext -WorkspaceRoot $positive.workspace -UnitId u002 -ToolingContextUpgrade $requestPath -OutPath (Join-Path $positive.workspace 'receipts/upgrade-positive-tooling-context-upgrade-request.json') -Timestamp '2026-09-15T09:00:00.0000000Z';Assert-TC (-not$dry.executed) 'dry run';$done=Invoke-Upgrade $positive $requestPath;Assert-TC $done.executed 'positive execute'
$unitAfter=Read-TC (Join-Path $positive.workspace 'iteration-units/u002.json');Assert-TC ([string]$unitAfter.tooling_context.path-ceq'tooling-contexts/ctx-new.json') 'positive pointer';Assert-TC (((@($projection.PSObject.Properties|ForEach-Object{FileHash (Join-Path $positive.workspace ([string]$_.Value.path))}))-join'|')-ceq$productBefore) 'positive preserved product bytes';$inspectArgs=@{WorkspaceRoot=$positive.workspace;UnitId='u002';RepoMapPath=(Join-Path $positive.workspace 'repository-map.json');ValidationTier='quick'};$inspection=&$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Inspect} $inspectArgs;Assert-TC ([string]$inspection.action-ceq'Inspect') 'post-upgrade Inspect';$beforeReplay=WorkspaceFingerprint $positive.workspace;$replay=Invoke-Upgrade $positive $requestPath;Assert-TC ($replay.executed-and(WorkspaceFingerprint $positive.workspace)-ceq$beforeReplay) 'exact replay';$event=@(Get-Content -LiteralPath (Join-Path $positive.workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{FromBytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$_))})[-1];Test-MorphospaceHistoricalToolingContextUpgrade $positive.workspace $event|Out-Null
$retirementModule=Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -Force -PassThru;$proofs=@(&$retirementModule {param($workspace,$upgrade,$context)Get-ActiveRetirementToolingProofBindings -WorkspaceRoot $workspace -Request $upgrade -Context $context} $positive.workspace $request $new);$expectedProofs=@('receipts/tool-validation-new.json','receipts/tool-publication-new.json','receipts/tool-protocol-new.json','receipts/upgrade-positive-compatibility.json')|Sort-Object -CaseSensitive;Assert-TC ((@($proofs|ForEach-Object{[string]$_.path})-join'|')-ceq($expectedProofs-join'|')) 'retirement proof closure after upgrade';foreach($proof in $proofs){Assert-TC ((FileHash (Join-Path $positive.workspace ([string]$proof.path)))-ceq[string]$proof.sha256) 'retirement proof byte binding'};Write-TCPhase 'lifecycle-complete'}
if($Scenario-in@('all','lifecycle')){$proofPath=Join-Path $positive.workspace 'receipts/tool-validation-new.json';$proofBytes=[IO.File]::ReadAllBytes($proofPath);try{[IO.File]::AppendAllText($proofPath,' ');$message='';try{&$retirementModule {param($workspace,$upgrade,$context)Get-ActiveRetirementToolingProofBindings -WorkspaceRoot $workspace -Request $upgrade -Context $context} $positive.workspace $request $new|Out-Null}catch{$message=$_.Exception.Message};Assert-TC ($message-like'*differs from its authenticated binding*') 'retirement proof tamper rejection'}finally{[IO.File]::WriteAllBytes($proofPath,$proofBytes)}}

if($Scenario-in@('all','recovery')){$faultMessages=@{'after-intent'='Injected interruption after intent publication.';'after-artifact'='Injected interruption after artifact installation.';'after-projection'='Injected interruption after projections.';'after-event'='Injected interruption after event append.'};$faults=if($RecoveryFault-ceq'all'){@('after-intent','after-artifact','after-projection','after-event')}else{@($RecoveryFault)};foreach($fault in $faults){$f=New-Case "recovery-$fault";$r=New-UpgradeRequest $f.workspace "upgrade-$fault";$rp=Save-Request $HarnessRoot $r "upgrade-$fault.json";$threw=$false;try{Invoke-Upgrade $f $rp $fault|Out-Null}catch{if($_.Exception.Message-cne[string]$faultMessages[$fault]){throw};$threw=$true};Assert-TC $threw "fault $fault";$recovered=Invoke-Upgrade $f $rp;Assert-TC $recovered.executed "recovery $fault";$replayed=Invoke-Upgrade $f $rp;Assert-TC $replayed.executed "replay $fault";Write-TCPhase "recovery-$fault-complete"}}

if($Scenario-in@('all','product-negative')){$negative=New-Case 'negative-product';$stale=New-UpgradeRequest $negative.workspace 'upgrade-stale';$stale.expected.unit_raw_sha256='0'*64;$stalePath=Save-Request $HarnessRoot $stale 'stale.json';$rejected=$false;try{Invoke-MorphospaceUpgradeToolingContext -WorkspaceRoot $negative.workspace -UnitId u002 -ToolingContextUpgrade $stalePath -OutPath (Join-Path $negative.workspace 'receipts/upgrade-stale-tooling-context-upgrade-request.json')|Out-Null}catch{$rejected=Assert-TCError $_.Exception.Message 'Tooling-context upgrade expected unit raw is stale.' 'stale CAS'};Assert-TC $rejected 'stale CAS rejection'
$mapBytes=[IO.File]::ReadAllBytes((Join-Path $negative.workspace 'repository-map.json'));try{[IO.File]::AppendAllText((Join-Path $negative.workspace 'repository-map.json'),' ');$r=New-UpgradeRequest $negative.workspace 'upgrade-map';$r.product_projection=$projection;$rp=Save-Request $HarnessRoot $r 'map.json';$rejected=$false;try{Invoke-MorphospaceUpgradeToolingContext -WorkspaceRoot $negative.workspace -UnitId u002 -ToolingContextUpgrade $rp -OutPath (Join-Path $negative.workspace 'receipts/upgrade-map-tooling-context-upgrade-request.json')|Out-Null}catch{$rejected=Assert-TCError $_.Exception.Message 'Tooling-context upgrade current product repository_map bytes drifted.' 'changed map'};Assert-TC $rejected 'changed map rejection'}finally{[IO.File]::WriteAllBytes((Join-Path $negative.workspace 'repository-map.json'),$mapBytes)}
$sourcePath=Join-Path $negative.workspace 'source-composition.json';$sourceBytes=[IO.File]::ReadAllBytes($sourcePath);try{[IO.File]::AppendAllText($sourcePath,' ');$r=New-UpgradeRequest $negative.workspace 'upgrade-source';$rp=Save-Request $HarnessRoot $r 'source.json';$rejected=$false;try{Invoke-MorphospaceUpgradeToolingContext -WorkspaceRoot $negative.workspace -UnitId u002 -ToolingContextUpgrade $rp -OutPath (Join-Path $negative.workspace 'receipts/upgrade-source-tooling-context-upgrade-request.json')|Out-Null}catch{$rejected=Assert-TCError $_.Exception.Message 'Tooling-context upgrade current product source_composition bytes drifted.' 'changed source'};Assert-TC $rejected 'changed source rejection'}finally{[IO.File]::WriteAllBytes($sourcePath,$sourceBytes)};Write-TCPhase 'product-negative-complete'}
if($Scenario-in@('all','provenance-negative')){$negative=New-Case 'negative-provenance';$closurePath=Join-Path $tool 'scripts/ToolingContextUpgrade.psm1';$closureBytes=[IO.File]::ReadAllBytes($closurePath);try{[IO.File]::AppendAllText($closurePath,' ');$r=New-UpgradeRequest $negative.workspace 'upgrade-closure';$rp=Save-Request $HarnessRoot $r 'closure.json';$rejected=$false;try{Invoke-MorphospaceUpgradeToolingContext -WorkspaceRoot $negative.workspace -UnitId u002 -ToolingContextUpgrade $rp -OutPath (Join-Path $negative.workspace 'receipts/upgrade-closure-tooling-context-upgrade-request.json')|Out-Null}catch{$rejected=Assert-TCError $_.Exception.Message "Loaded owner module 'scripts/ToolingContextUpgrade.psm1' differs from the exact executor bytes on disk." 'changed closure'};Assert-TC $rejected 'changed closure rejection'}finally{[IO.File]::WriteAllBytes($closurePath,$closureBytes)}
$maskedPath='docs/TOOLING_CONTEXT.md';$maskedAbsolute=Join-Path $tool $maskedPath;$maskedBytes=[IO.File]::ReadAllBytes($maskedAbsolute);try{[IO.File]::AppendAllText($maskedAbsolute,' ');& git -C $tool update-index --assume-unchanged -- $maskedPath;if($LASTEXITCODE-ne0){throw 'Fixture could not mask the historical-blob negative.'};$masked=Clone $new;@($masked.executor.closure|Where-Object{[string]$_.path-ceq$maskedPath})[0].sha256=FileHash $maskedAbsolute;$masked=Set-ContextFingerprint $masked;$r=New-UpgradeRequest $negative.workspace 'upgrade-masked-closure' $masked;$rp=Save-Request $HarnessRoot $r 'masked-closure.json';$rejected=$false;try{Invoke-MorphospaceUpgradeToolingContext -WorkspaceRoot $negative.workspace -UnitId u002 -ToolingContextUpgrade $rp -OutPath (Join-Path $negative.workspace 'receipts/upgrade-masked-closure-tooling-context-upgrade-request.json')|Out-Null}catch{$rejected=Assert-TCError $_.Exception.Message "Tooling context historical executor closure '$maskedPath' drifted." 'masked historical blob'};Assert-TC $rejected 'assume-unchanged historical blob rejection'}finally{& git -C $tool update-index --no-assume-unchanged -- $maskedPath;[IO.File]::WriteAllBytes($maskedAbsolute,$maskedBytes)}
$dynamic=New-Case 'missing-dynamic-dependency';Write-TC (Join-Path $dynamic.workspace 'local/ctx-missing-dependency-resolver.json') ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.tooling_context_resolver.v1';context_id='ctx-missing-dependency';executor_root=$tool;routers=@([pscustomobject][ordered]@{skill_id='rusty-morphospace';root=$newRouter.root},[pscustomobject][ordered]@{skill_id='system-engineering';root=$newSystemRouter.root},[pscustomobject][ordered]@{skill_id='rust-work-graph';root=$newGraphRouter.root});status='resolved';does_not_prove=@('Local resolution only.')});$missingExecutor=Clone $newExecutor;$missingExecutor.closure=@($missingExecutor.closure|Where-Object{[string]$_.path-cne'scripts/Invoke-WorkUnitAutomation.ps1'});Assert-TC ($missingExecutor.closure.Count-lt$newExecutor.closure.Count) 'dynamic dependency fixture selection';$missing=New-MorphospaceToolingContext -ContextId 'ctx-missing-dependency' -ProjectId 'envelope-test' -PreparationId 'u002-envelope' -ProductProjection $projection -Resolver ([pscustomobject]@{path='local/ctx-missing-dependency-resolver.json';sha256=FileHash (Join-Path $dynamic.workspace 'local/ctx-missing-dependency-resolver.json')}) -Executor $missingExecutor -Routers @($newRouter.row,$newSystemRouter.row,$newGraphRouter.row) -Compatibility $newCompat;$r=New-UpgradeRequest $dynamic.workspace 'upgrade-missing-dependency' $missing;$rp=Save-Request $HarnessRoot $r 'missing-dependency.json';$rejected=$false;try{Invoke-MorphospaceUpgradeToolingContext -WorkspaceRoot $dynamic.workspace -UnitId u002 -ToolingContextUpgrade $rp -OutPath (Join-Path $dynamic.workspace 'receipts/upgrade-missing-dependency-tooling-context-upgrade-request.json')|Out-Null}catch{$rejected=Assert-TCError $_.Exception.Message "Tooling context closure omits owner-derived dependency 'scripts/Invoke-WorkUnitAutomation.ps1' (full-tracked-executor-tree)." 'missing dependency'};Assert-TC $rejected 'undeclared dynamic dependency rejection'
$forged=New-Case 'forged';$r=New-UpgradeRequest $forged.workspace 'upgrade-forged';$proofPath=Join-Path $forged.workspace $r.compatibility_receipt.path;$proof=Read-TC $proofPath;$proof.new_context.commit=$OldCommit;Write-TC $proofPath $proof;$r.compatibility_receipt.sha256=FileHash $proofPath;$rp=Save-Request $HarnessRoot $r 'forged.json';$rejected=$false;try{Invoke-MorphospaceUpgradeToolingContext -WorkspaceRoot $forged.workspace -UnitId u002 -ToolingContextUpgrade $rp -OutPath (Join-Path $forged.workspace 'receipts/upgrade-forged-tooling-context-upgrade-request.json')|Out-Null}catch{$rejected=Assert-TCError $_.Exception.Message 'Tooling-context compatibility receipt new_context binding is detached.' 'forged compatibility'};Assert-TC $rejected 'forged compatibility rejection';Write-TCPhase 'provenance-negative-complete'}
if($Scenario-in@('all','ready-lifecycle')){
 $base=$readyBase
 foreach($damage in @('wrong-unit-id','wrong-ready-slot','occupied-current','wrong-status')){
  $case=New-Case ("ready-negative-$damage");$up=Join-Path $case.workspace 'iteration-units/u002.json';$sp=Join-Path $case.workspace 'workspace.state.json';$u=Read-TC $up;$st=Read-TC $sp
  switch($damage){'wrong-unit-id'{$u.unit_id='other-unit'};'wrong-ready-slot'{$st.next_ready_unit='other-unit'};'occupied-current'{$st.current_unit='u002'};'wrong-status'{$u.status='proposed'}}
  Write-TC $up $u;Write-TC $sp $st;$bad=New-UpgradeRequest $case.workspace ("upgrade-$damage");$badPath=Save-Request $HarnessRoot $bad ("upgrade-$damage.json");$before=WorkspaceFingerprint $case.workspace;$denied=$false
  try{Invoke-Upgrade $case $badPath|Out-Null}catch{$denied=Assert-TCError $_.Exception.Message 'Tooling upgrade requires exact active ownership or exact next-ready slot before Freeze.' $damage}
  Assert-TC ($denied-and(WorkspaceFingerprint $case.workspace)-ceq$before) ("Ready upgrade $damage rejects without writes")
 }
 $positive=New-Case 'ready-upgrade';$request=New-UpgradeRequest $positive.workspace 'upgrade-ready';$rp=Save-Request $HarnessRoot $request 'upgrade-ready.json'
 $beforeState=Read-TC (Join-Path $positive.workspace 'workspace.state.json');$beforeUnit=Read-TC (Join-Path $positive.workspace 'iteration-units/u002.json')
 Assert-TC ($null-eq$beforeState.current_unit-and[string]$beforeState.next_ready_unit-ceq'u002'-and[string]$beforeUnit.status-ceq'ready') 'owner-produced Ready slot'
 $done=Invoke-Upgrade $positive $rp;Assert-TC ($done.executed-and$done.status_before-ceq'ready'-and$done.status_after-ceq'ready'-and$null-eq$done.current_unit_after) 'Ready upgrade receipt'
 $afterState=Read-TC (Join-Path $positive.workspace 'workspace.state.json');$afterUnit=Read-TC (Join-Path $positive.workspace 'iteration-units/u002.json')
 Assert-TC ($null-eq$afterState.current_unit-and[string]$afterState.next_ready_unit-ceq'u002'-and[string]$afterUnit.status-ceq'ready') 'Ready upgrade preserves queue and status'
 $withdrawDenied=$false;$beforeWithdraw=WorkspaceFingerprint $positive.workspace
 try{&$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action WithdrawReady -OutPath (Join-Path $a.WorkspaceRoot 'receipts/ready-upgrade-withdraw.json') -Timestamp '2026-09-15T09:01:00.0000000Z' -Execute} @{WorkspaceRoot=$positive.workspace;UnitId='u002';RepoMapPath=(Join-Path $positive.workspace 'repository-map.json');ValidationTier='quick'}|Out-Null}catch{$withdrawDenied=Assert-TCError $_.Exception.Message 'WithdrawReady original Ready transaction does not bind the exact live unit and historical ready projection.' 'post-upgrade withdrawal'}
 Assert-TC ($withdrawDenied-and(WorkspaceFingerprint $positive.workspace)-ceq$beforeWithdraw) 'post-upgrade Withdraw remains fail-closed without writes'
 $effectiveModule=Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1') -PassThru
 $unclaimedDenied=$false
 try{&$effectiveModule {param($w)Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $w -UnitId u002 -RepositoryMapPath (Join-Path $w 'repository-map.json')} $positive.workspace|Out-Null}catch{$unclaimedDenied=$true}
 Assert-TC $unclaimedDenied 'upgraded Ready cannot masquerade as completed Claim for Freeze'
 $claimArgs=@{WorkspaceRoot=$positive.workspace;UnitId='u002';RepoMapPath=(Join-Path $positive.workspace 'repository-map.json');ValidationTier='quick'}
 $claim=&$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Claim -Timestamp '2026-09-15T09:02:00.0000000Z' -Execute} $claimArgs
 Assert-TC ($claim.executed-and$claim.status_after-ceq'active') 'Ready upgrade supports actual Claim'
 $effectiveModule=Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1') -PassThru
 &$effectiveModule {param($w)Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $w -UnitId u002 -RepositoryMapPath (Join-Path $w 'repository-map.json')} $positive.workspace|Out-Null

 $unit=Read-TC (Join-Path $positive.workspace 'iteration-units/u002.json');$state=Read-TC (Join-Path $positive.workspace 'workspace.state.json');$lock=Read-TC (Join-Path $positive.workspace 'feature.lock.json');$events=Join-Path $positive.workspace 'iteration-events.jsonl'
 $freeze=[ordered]@{schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id='u002-ready-permission-free';project_id='envelope-test';unit_id='u002';expected=[ordered]@{project_sha256=Canonical (Read-TC (Join-Path $positive.workspace 'project.spec.json'));state_sha256=Canonical $state;unit_sha256=Canonical $unit;feature_lock_sha256=Canonical $lock;source_composition_path='source-composition.json';source_composition_sha256=FileHash (Join-Path $positive.workspace 'source-composition.json');repository_map_path='repository-map.json';repository_map_sha256=FileHash (Join-Path $positive.workspace 'repository-map.json');events_sha256=FileHash $events;events_length=[IO.FileInfo]::new($events).Length;event_tail_id=[string]$state.last_event_id};final_repositories=@([ordered]@{repo_id='project-shell';commit=$seed.source_commit;tree=$seed.source_tree});changed_paths=@([ordered]@{repo_id='project-shell';paths=@('morphospace/')});cleanliness_policy='clean-only';instruction_surfaces=@([ordered]@{path='morphospace/README.md';disposition='reviewed-no-change'});feature_lock=[ordered]@{revision=[int]$lock.revision;sha256=Canonical $lock};effects=@('none');permissions=@();device_use=@('none');test_matrix=@([ordered]@{test_id='ready-upgrade';command='owner lifecycle conformance'});cleanup_evidence=@('No device effects.');source_composition=[ordered]@{path='source-composition.json';sha256=FileHash (Join-Path $positive.workspace 'source-composition.json')};does_not_prove=@('Host conformance fixture only.')}
 $freezePath=Save-Request $HarnessRoot $freeze 'ready-freeze.json'
 $freezeModule=Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -PassThru
 $frozen=&$freezeModule {param($w,$p,$h)Invoke-MorphospaceFreezeCandidate -WorkspaceRoot $w -UnitId u002 -CandidateFreeze $p -ExpectedCandidateFreezeSha256 $h -OutPath (Join-Path $w 'receipts/u002-ready-permission-free.json') -Timestamp '2026-09-15T09:02:30.0000000Z' -Execute} $positive.workspace $freezePath (FileHash $freezePath)
 Assert-TC ($frozen.executed-and$frozen.transition-ceq'candidate-frozen') 'Ready upgrade Claim permits exact permission-free Freeze'
 $ordinary=New-Case 'unupgraded-withdraw'
 & git -C $tool checkout --detach $OldCommit|Out-Null
 # Fresh process authenticates the old executor; no new-revision modules
 # retained in this child's session can impersonate that exact old context.
 $withdrawText=(& pwsh -NoProfile -NonInteractive -File (Join-Path $tool 'scripts/Invoke-WorkUnitAutomation.ps1') -Action WithdrawReady -WorkspaceRoot $ordinary.workspace -UnitId u002 -RepoMapPath (Join-Path $ordinary.workspace 'repository-map.json') -ValidationTier quick -OutPath (Join-Path $ordinary.workspace 'receipts/ordinary-withdraw.json') -Timestamp '2026-09-15T09:03:00.0000000Z' -Execute|Out-String)
 if($LASTEXITCODE-ne0){throw 'Ordinary unupgraded withdrawal child failed.'};$withdraw=$withdrawText|ConvertFrom-Json -Depth 100 -DateKind String
 Assert-TC ($withdraw.executed-and$withdraw.status_after-ceq'proposed') 'ordinary unupgraded withdrawal retained'
 Write-TCPhase 'ready-lifecycle-complete'
 [pscustomobject]@{result='pass';scenario=$Scenario;owner_produced_ready=$true;actual_upgrade_claim=$true;post_upgrade_withdraw='unsupported-fail-closed';device_calls=0}|ConvertTo-Json -Compress
 if($Scenario-ceq'ready-lifecycle'){return}
}

[pscustomobject]@{result='pass';action='UpgradeToolingContext';scenario=$Scenario;faults=$(if($Scenario-in@('all','recovery')){if($RecoveryFault-ceq'all'){@('after-intent','after-artifact','after-projection','after-event')}else{@($RecoveryFault)}}else{@()});real_git=$true;bound_executor=$true;remote_mutation_performed=$false}|ConvertTo-Json -Compress
