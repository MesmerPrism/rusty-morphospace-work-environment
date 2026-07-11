param()

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceContentObservation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceEventChain.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
$script:EventModule = Get-Module MorphospaceEventChain
$script:ContentModule = Get-Module MorphospaceContentObservation
$script:CommonModule = Get-Module MorphospaceProtocolCommon

function Assert-Foundation { param([bool]$Condition,[string]$Message) if(-not$Condition){throw "Protocol foundation self-test failed: $Message"} }
function Assert-Rejected { param([scriptblock]$Action,[string]$Message) $rejected=$false;try{&$Action}catch{$rejected=$true};Assert-Foundation $rejected $Message }
function Write-Utf8Lf { param([string]$Path,[string]$Text) [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }
function Invoke-InternalGit { param([string]$Git,[string]$Root,[string[]]$Arguments) &$script:ContentModule {param($g,$r,$a) Invoke-MorphospaceBoundGitBytes -GitExecutable $g -RepositoryPath $r -Arguments $a} $Git $Root $Arguments }
function Invoke-FixtureGit { param([string]$Git,[string]$Root,[string[]]$Arguments) $p=Invoke-InternalGit $Git $Root $Arguments;if($p.exit_code-ne0){throw 'fixture git failed'} }
function Invoke-InternalEventAppend { param([hashtable]$Parameters) & $script:EventModule { param($p) Add-MorphospaceEventV2 @p } $Parameters }
function Invoke-InternalEventRepair { param([string]$WorkspaceRoot,[object]$IntentReference,[object]$AnchorReference) & $script:EventModule { param($w,$r,$a) Repair-MorphospaceEventTransaction $w $r $a } $WorkspaceRoot $IntentReference $AnchorReference }
function Invoke-InternalPendingObservation { param([string]$WorkspaceRoot,[string]$TargetRelativePath,[switch]$KeepLease) & $script:CommonModule { param($w,$t,$k) Get-MorphospacePendingObservation -WorkspaceRoot $w -TargetRelativePath $t -KeepLease:$k } $WorkspaceRoot $TargetRelativePath $KeepLease }
function Invoke-InternalPendingRecovery { param([string]$WorkspaceRoot,[object]$AuthorizationReference) & $script:CommonModule { param($w,$a) Invoke-MorphospacePendingQuarantineRecovery -WorkspaceRoot $w -AuthorizationReference $a } $WorkspaceRoot $AuthorizationReference }
function Invoke-InternalDeterministicJsonRepair { param([string]$WorkspaceRoot,[string]$RelativePath,[object]$Value) & $script:CommonModule { param($w,$p,$v) Repair-MorphospaceDeterministicCanonicalJsonInternal -WorkspaceRoot $w -RelativePath $p -Value $v } $WorkspaceRoot $RelativePath $Value }
function New-TestPendingAuthorization {
    param([string]$WorkspaceRoot,[string]$ProjectId,[string]$UnitId,[string]$TargetRelativePath,[string]$PendingRelativePath,[string]$AuthorizationId)
    $pendingPath=Join-Path $WorkspaceRoot $PendingRelativePath;$pendingHash=Get-MorphospaceFileSha256 $pendingPath;$pendingLength=[IO.FileInfo]::new($pendingPath).Length;$pendingLeaf=[IO.Path]::GetFileName($PendingRelativePath);$base="receipts/pending-quarantine/$UnitId/$AuthorizationId";$authorizationPath="$base/authorization.json";$quarantinePath="$base/$pendingLeaf.preserved"
    $authorization=[ordered]@{schema='rusty.morphospace.workflow.pending_quarantine_authorization.v1';authorization_id=$AuthorizationId;created_at='2026-07-11T16:10:00.0000000Z';project_id=$ProjectId;unit_id=$UnitId;action='quarantine-preserve';target_path=$TargetRelativePath;pending_path=$PendingRelativePath;pending_sha256=$pendingHash;pending_length=[long]$pendingLength;quarantine_path=$quarantinePath;status='authorized'}
    Write-MorphospaceManagedProtocolJsonAtomic $WorkspaceRoot $authorizationPath $authorization -NoOverwrite
    $reference=[pscustomobject][ordered]@{role='pending-quarantine-authorization';path=$authorizationPath;schema=[string]$authorization.schema;sha256=(Get-MorphospaceFileSha256 (Join-Path $WorkspaceRoot $authorizationPath))}
    return [pscustomobject]@{reference=$reference;authorization=$authorization;authorization_path=$authorizationPath;quarantine_path=$quarantinePath;completion_path="$base/completion.json"}
}
function Invoke-TestEventAppend {
    [CmdletBinding()]
    param([string]$WorkspaceRoot,[object]$AnchorReference,[string]$ProjectId,[string]$UnitId,[string]$ActionSlug,[string]$EventType,[string]$Summary,[string]$RunId,[string]$SessionId,[string]$Timestamp,[object[]]$ReceiptReferences=@(),[object]$ExpectedTail=$null,[switch]$Execute)
    $copy=@{};foreach($key in $PSBoundParameters.Keys){$copy[$key]=$PSBoundParameters[$key]};return Invoke-InternalEventAppend $copy
}
function ConvertTo-TestProcessArgument {
    param([string]$Value)
    if($Value-notmatch'[\s"]'){return $Value};$b=[Text.StringBuilder]::new();[void]$b.Append('"');$slashes=0
    foreach($c in $Value.ToCharArray()){if($c-eq'\'){$slashes++;continue};if($c-eq'"'){[void]$b.Append(('\'*(($slashes*2)+1)));[void]$b.Append('"');$slashes=0;continue};if($slashes){[void]$b.Append(('\'*$slashes));$slashes=0};[void]$b.Append($c)}
    if($slashes){[void]$b.Append(('\'*($slashes*2)))};[void]$b.Append('"');return $b.ToString()
}
function Get-TestHostExecutable {
    $processPathProperty=[Environment].GetProperty('ProcessPath')
    if($null-ne$processPathProperty){$candidate=[string]$processPathProperty.GetValue($null,$null);if($candidate){return $candidate}}
    return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}
function Start-TestHostProcess {
    param([string[]]$Arguments)
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=Get-TestHostExecutable;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    if($psi.PSObject.Properties.Name-contains'ArgumentList'){foreach($argument in $Arguments){[void]$psi.ArgumentList.Add([string]$argument)}}else{$psi.Arguments=(@($Arguments|ForEach-Object{ConvertTo-TestProcessArgument ([string]$_)})-join' ')}
    return [Diagnostics.Process]::Start($psi)
}

$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root=Join-Path $tempBase ('morphospace-protocol-foundation-'+[guid]::NewGuid().ToString('N'))
$junctionPath=$null
try{
    [IO.Directory]::CreateDirectory($root)|Out-Null
    Assert-Foundation (@(Get-Command -Module MorphospaceEventChain|Where-Object{$_.Name-in@('Add-MorphospaceEventV2','Repair-MorphospaceEventTransaction')}).Count-eq0) 'unauthorized append/repair primitives are publicly exported'
    Assert-Foundation (@(Get-Command -Module MorphospaceContentObservation|Where-Object{$_.Name-eq'Invoke-MorphospaceBoundGitBytes'}).Count-eq0) 'raw Git invocation primitive is publicly exported'
    Assert-Foundation (@(Get-Command -Module MorphospaceProtocolCommon|Where-Object{$_.Name-in@('Get-MorphospacePendingObservation','Invoke-MorphospacePendingQuarantineRecovery','Repair-MorphospaceDeterministicCanonicalJsonInternal')}).Count-eq0) 'pending/deterministic repair primitives are publicly exported'

    # Strict JSON, semantic canonicalization, invariant time, paths, and atomic no-overwrite.
    $commonRoot=Join-Path $root 'common';[IO.Directory]::CreateDirectory((Join-Path $commonRoot 'receipts'))|Out-Null
    $canonicalA=ConvertTo-MorphospaceCanonicalJson ([ordered]@{z=1;a=[ordered]@{b=2;a=1}})
    $canonicalB=ConvertTo-MorphospaceCanonicalJson ([ordered]@{a=[ordered]@{a=1;b=2};z=1})
    Assert-Foundation ($canonicalA-ceq$canonicalB) 'semantic canonical JSON depends on property order'
    $badJson=@('{"a":1,"a":2}','{"a":1,"A":2}','{"a":1,}','{/*comment*/"a":1}','{"a":1.5}')
    foreach($text in $badJson){$path=Join-Path $commonRoot ([guid]::NewGuid().ToString('N')+'.json');Write-Utf8Lf $path $text;Assert-Rejected {Read-MorphospaceProtocolJson $path|Out-Null} "strict JSON accepted $text"}
    $bomPath=Join-Path $commonRoot 'bom.json';[IO.File]::WriteAllBytes($bomPath,[byte[]](0xef,0xbb,0xbf,0x7b,0x7d));Assert-Rejected {Read-MorphospaceProtocolJson $bomPath|Out-Null} 'UTF-8 BOM accepted'
    $nulPath=Join-Path $commonRoot 'nul.json';[IO.File]::WriteAllBytes($nulPath,[byte[]](0x7b,0x00,0x7d));Assert-Rejected {Read-MorphospaceProtocolJson $nulPath|Out-Null} 'NUL JSON accepted'
    $priorCulture=[Globalization.CultureInfo]::CurrentCulture
    try{[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('de-DE');$parsed=ConvertFrom-MorphospaceInvariantTimestamp '2026-07-11T10:10:00+02:00';Assert-Foundation ($parsed.Month-eq7-and$parsed.Day-eq11-and$parsed.UtcDateTime.Hour-eq8) 'invariant timestamp changed under de-DE'}finally{[Globalization.CultureInfo]::CurrentCulture=$priorCulture}
    foreach($badPath in @('file:stream','dir./file','CON/file','short~1/file',' leading/file','dir/../file')){Assert-Rejected {ConvertTo-MorphospaceProtocolRelativePath $badPath|Out-Null} "unsafe path accepted: $badPath"}
    $junctionTarget=Join-Path $root 'junction-target';[IO.Directory]::CreateDirectory((Join-Path $junctionTarget 'workspace\receipts'))|Out-Null;$junctionPath=Join-Path $root 'ancestor-junction';[void](Microsoft.PowerShell.Management\New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget)
    Assert-Rejected {Write-MorphospaceManagedProtocolJsonAtomic (Join-Path $junctionPath 'workspace') 'receipts/through-junction.json' ([ordered]@{schema='test.junction.v1'}) -NoOverwrite} 'workspace below an ancestor junction was accepted';[IO.Directory]::Delete($junctionPath);$junctionPath=$null
    $managed='receipts/atomic.json';Write-MorphospaceManagedProtocolJsonAtomic $commonRoot $managed ([ordered]@{schema='test.atomic.v1';value=1}) -NoOverwrite
    $firstHash=Get-MorphospaceFileSha256 (Join-Path $commonRoot $managed)
    Assert-Rejected {Write-MorphospaceManagedProtocolJsonAtomic $commonRoot $managed ([ordered]@{schema='test.atomic.v1';value=2}) -NoOverwrite} 'CreateNew/no-overwrite was bypassed'
    Assert-Foundation ((Get-MorphospaceFileSha256 (Join-Path $commonRoot $managed))-ceq$firstHash) 'failed overwrite changed managed bytes'

    # Hard-termination leftovers are observed exactly and can only be preserved under typed authorization.
    $crashTarget='receipts/crash-leftover.json';$crashSuffix=[guid]::NewGuid().ToString('N');$crashPending="$crashTarget.pending-$crashSuffix";Write-Utf8Lf (Join-Path $commonRoot $crashPending) '{"schema":"test.crash.leftover.v1","value":1}'
    $crashObservation=Invoke-InternalPendingObservation $commonRoot $crashTarget;Assert-Foundation (-not$crashObservation.target_exists-and$null-ne$crashObservation.candidate-and[string]$crashObservation.candidate.relative_path-ceq$crashPending) 'exact crash-leftover pending artifact was not classified'
    Assert-Rejected {Write-MorphospaceManagedProtocolJsonAtomic $commonRoot $crashTarget ([ordered]@{schema='test.must.not.publish.v1'}) -NoOverwrite} 'normal publication ignored an unresolved pending artifact'
    Assert-Foundation ([IO.File]::Exists((Join-Path $commonRoot $crashPending))-and-not[IO.File]::Exists((Join-Path $commonRoot $crashTarget))) 'rejected publication deleted/adopted the crash-leftover bytes'
    $crashAuth=New-TestPendingAuthorization $commonRoot test-project unit-test $crashTarget $crashPending ('recover-'+[guid]::NewGuid().ToString('N'));$crashSourceHash=[string]$crashAuth.authorization.pending_sha256
    $crashRecovery=Invoke-InternalPendingRecovery $commonRoot $crashAuth.reference;Assert-Foundation ([string]$crashRecovery.status-ceq'quarantined-preserved'-and-not[IO.File]::Exists((Join-Path $commonRoot $crashPending))-and-not[IO.File]::Exists((Join-Path $commonRoot $crashTarget))) 'authorized pending recovery published or retained the source instead of quarantining it'
    Assert-Foundation ([IO.File]::Exists((Join-Path $commonRoot $crashAuth.quarantine_path))-and(Get-MorphospaceFileSha256 (Join-Path $commonRoot $crashAuth.quarantine_path))-ceq$crashSourceHash) 'authorized pending recovery did not preserve exact source bytes'
    $crashCompletionPath=Join-Path $commonRoot $crashAuth.completion_path;$crashCompletionHash=Get-MorphospaceFileSha256 $crashCompletionPath;$crashReplay=Invoke-InternalPendingRecovery $commonRoot $crashAuth.reference
    Assert-Foundation ([string]$crashReplay.status-ceq'quarantined-preserved'-and(Get-MorphospaceFileSha256 $crashCompletionPath)-ceq$crashCompletionHash) 'completed pending recovery replay was not idempotent'

    $hostileTarget='receipts/hostile.json';$hostilePending="$hostileTarget.pending-$([guid]::NewGuid().ToString('N').ToUpperInvariant())";Write-Utf8Lf (Join-Path $commonRoot $hostilePending) 'hostile'
    Assert-Rejected {Invoke-InternalPendingObservation $commonRoot $hostileTarget|Out-Null} 'uppercase/hostile pending filename was accepted'
    Assert-Foundation ([IO.File]::Exists((Join-Path $commonRoot $hostilePending))-and-not[IO.File]::Exists((Join-Path $commonRoot $hostileTarget))) 'hostile pending classification mutated its source or target';[IO.File]::Delete((Join-Path $commonRoot $hostilePending))

    $coexistTarget='receipts/coexist.json';$coexistPending="$coexistTarget.pending-$([guid]::NewGuid().ToString('N'))";Write-Utf8Lf (Join-Path $commonRoot $coexistPending) 'pending';$coexistAuth=New-TestPendingAuthorization $commonRoot test-project unit-test $coexistTarget $coexistPending ('recover-'+[guid]::NewGuid().ToString('N'));Write-Utf8Lf (Join-Path $commonRoot $coexistTarget) 'published'
    Assert-Rejected {Invoke-InternalPendingRecovery $commonRoot $coexistAuth.reference|Out-Null} 'published-target/pending coexistence was accepted'
    Assert-Foundation ([IO.File]::Exists((Join-Path $commonRoot $coexistTarget))-and[IO.File]::Exists((Join-Path $commonRoot $coexistPending))-and-not[IO.File]::Exists((Join-Path $commonRoot $coexistAuth.quarantine_path))) 'coexistence rejection mutated recovery state';[IO.File]::Delete((Join-Path $commonRoot $coexistTarget));[IO.File]::Delete((Join-Path $commonRoot $coexistPending))

    $partialTarget='receipts/partial-move.json';$partialPending="$partialTarget.pending-$([guid]::NewGuid().ToString('N'))";Write-Utf8Lf (Join-Path $commonRoot $partialPending) 'partial crash';$partialAuth=New-TestPendingAuthorization $commonRoot test-project unit-test $partialTarget $partialPending ('recover-'+[guid]::NewGuid().ToString('N'));$partialQuarantine=Join-Path $commonRoot $partialAuth.quarantine_path;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($partialQuarantine))|Out-Null;[IO.File]::Move((Join-Path $commonRoot $partialPending),$partialQuarantine)
    $partialRecovery=Invoke-InternalPendingRecovery $commonRoot $partialAuth.reference;Assert-Foundation ([string]$partialRecovery.status-ceq'quarantined-preserved'-and[IO.File]::Exists((Join-Path $commonRoot $partialAuth.completion_path))-and-not[IO.File]::Exists((Join-Path $commonRoot $partialTarget))) 'move-before-completion crash recovery did not finish safely'
    $partialCompletionPath=Join-Path $commonRoot $partialAuth.completion_path;$expectedCompletionBytes=[IO.File]::ReadAllBytes($partialCompletionPath);$expectedCompletionHash=Get-MorphospaceSha256Bytes $expectedCompletionBytes
    for($prefixLength=0;$prefixLength-le$expectedCompletionBytes.Length;$prefixLength++){
        [IO.File]::Delete($partialCompletionPath);$prefixBytes=[byte[]]::new($prefixLength);if($prefixLength-gt0){[Array]::Copy($expectedCompletionBytes,0,$prefixBytes,0,$prefixLength)};[IO.File]::WriteAllBytes($partialCompletionPath,$prefixBytes)
        $prefixRecovery=Invoke-InternalPendingRecovery $commonRoot $partialAuth.reference
        Assert-Foundation ([string]$prefixRecovery.status-ceq'quarantined-preserved'-and([IO.FileInfo]::new($partialCompletionPath).Length-eq$expectedCompletionBytes.Length)-and(Get-MorphospaceFileSha256 $partialCompletionPath)-ceq$expectedCompletionHash) "canonical completion prefix boundary $prefixLength was not repaired exactly"
    }
    $secondOrderPending=[Collections.Generic.List[string]]::new();foreach($entry in [IO.Directory]::EnumerateFileSystemEntries([IO.Path]::GetDirectoryName($partialCompletionPath))){if([IO.Path]::GetFileName($entry).StartsWith('completion.json.pending-',[StringComparison]::OrdinalIgnoreCase)){$secondOrderPending.Add($entry)}};Assert-Foundation ($secondOrderPending.Count-eq0) 'deterministic completion repair created second-order pending artifacts'
    [IO.File]::Delete($partialCompletionPath);$divergentLength=[Math]::Min(16,$expectedCompletionBytes.Length);$divergent=[byte[]]::new($divergentLength);[Array]::Copy($expectedCompletionBytes,0,$divergent,0,$divergentLength);$divergent[0]=[byte]($divergent[0]-bxor1);[IO.File]::WriteAllBytes($partialCompletionPath,$divergent);$divergentHash=Get-MorphospaceFileSha256 $partialCompletionPath
    Assert-Rejected {Invoke-InternalPendingRecovery $commonRoot $partialAuth.reference|Out-Null} 'divergent canonical completion prefix was accepted';Assert-Foundation ((Get-MorphospaceFileSha256 $partialCompletionPath)-ceq$divergentHash-and[IO.FileInfo]::new($partialCompletionPath).Length-eq$divergentLength) 'divergent completion rejection truncated or changed bytes'
    [IO.File]::Delete($partialCompletionPath);$extra=[byte[]]::new($expectedCompletionBytes.Length+1);[Array]::Copy($expectedCompletionBytes,0,$extra,0,$expectedCompletionBytes.Length);$extra[$extra.Length-1]=0x20;[IO.File]::WriteAllBytes($partialCompletionPath,$extra);$extraHash=Get-MorphospaceFileSha256 $partialCompletionPath
    Assert-Rejected {Invoke-InternalPendingRecovery $commonRoot $partialAuth.reference|Out-Null} 'canonical completion with extra bytes was accepted';Assert-Foundation ((Get-MorphospaceFileSha256 $partialCompletionPath)-ceq$extraHash-and[IO.FileInfo]::new($partialCompletionPath).Length-eq$extra.Length) 'extra-byte completion rejection truncated or changed bytes';[IO.File]::Delete($partialCompletionPath)

    # The same private primitive lets a future higher authority publish a
    # deterministic authorization/action intent directly, without recursive
    # pending-recovery authorization.
    $authorityIntentPath='receipts/higher-authority-action-intent.json';$authorityIntent=[ordered]@{schema='test.higher_authority_action_intent.v1';intent_id='higher-authority-intent1';created_at='2026-07-11T16:11:00.0000000Z';status='prepared'};$authorityExpected=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $authorityIntent)+"`n");$authorityPrefix=[byte[]]::new([Math]::Floor($authorityExpected.Length/2));[Array]::Copy($authorityExpected,0,$authorityPrefix,0,$authorityPrefix.Length);[IO.File]::WriteAllBytes((Join-Path $commonRoot $authorityIntentPath),$authorityPrefix)
    $authorityRepair=Invoke-InternalDeterministicJsonRepair $commonRoot $authorityIntentPath $authorityIntent;Assert-Foundation ([string]$authorityRepair.relative_path-ceq$authorityIntentPath-and(Get-MorphospaceFileSha256 (Join-Path $commonRoot $authorityIntentPath))-ceq(Get-MorphospaceSha256Bytes $authorityExpected)) 'higher-authority deterministic intent reuse did not repair exact canonical bytes'
    $hostExe=Get-TestHostExecutable
    Assert-Rejected {Invoke-MorphospaceBoundProcessBytes -Executable $hostExe -WorkingDirectory $commonRoot -Arguments @('-NoProfile','-NonInteractive','-Command',"[Console]::Out.Write(('x'*4096))") -MaxOutputBytes 1024|Out-Null} 'streaming process-output cap was not enforced'
    $shadowWorker=Join-Path $root 'shadow-worker.ps1';$shadowWorkerText=@'
param($Common,$Content)
$ErrorActionPreference='Stop'
function global:ForEach-Object { '00' }
function global:Where-Object { throw 'shadowed Where-Object' }
function global:Out-Null { throw 'shadowed Out-Null' }
function global:Set-StrictMode { throw 'shadowed Set-StrictMode' }
function global:Export-ModuleMember { throw 'shadowed Export-ModuleMember' }
try {
    Import-Module $Common -Force
    $a=Get-MorphospaceSha256Bytes ([byte[]](1,2,3));$b=Get-MorphospaceSha256Bytes ([byte[]](1,2,4))
    if($a-eq$b-or$a-notmatch'^[0-9a-f]{64}$'-or$b-notmatch'^[0-9a-f]{64}$'){exit 31}
    $left=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{a=1});$right=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{a=2});if($left-eq$right){exit 32}
    Import-Module $Content -Force;$sorted=@(Sort-MorphospaceOrdinalStrings @('b','a'));if($sorted.Count-ne2-or$sorted[0]-cne'a'-or$sorted[1]-cne'b'){exit 33}
    exit 0
} catch { exit 34 }
'@
    Write-Utf8Lf $shadowWorker $shadowWorkerText;$shadowProcess=Start-TestHostProcess @('-NoProfile','-NonInteractive','-File',$shadowWorker,'-Common',(Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1'),'-Content',(Join-Path $PSScriptRoot 'lib\MorphospaceContentObservation.psm1'));$shadowProcess.WaitForExit();$shadowCode=$shadowProcess.ExitCode;$shadowProcess.Dispose();Assert-Foundation ($shadowCode-eq0) "caller command-shadow regression failed with exit $shadowCode"

    # Raw-byte/NUL-safe Git observation. Scope is separate from attribution.
    $git=(Get-MorphospaceBoundExecutable git).path;$repo=Join-Path $root 'git-repo';[IO.Directory]::CreateDirectory((Join-Path $repo 'src'))|Out-Null;$textconvProbe=Join-Path $root 'textconv-side-effect.txt';$textconvDriver=Join-Path $root 'textconv-driver.ps1';$escapedProbe=$textconvProbe.Replace("'","''");Write-Utf8Lf $textconvDriver "param([string]`$InputPath)`n[IO.File]::WriteAllText('$escapedProbe','invoked')`nif(`$InputPath-and[IO.File]::Exists(`$InputPath)){[Console]::Out.Write([IO.File]::ReadAllText(`$InputPath))}`n";$filterProbe=Join-Path $root 'filter-side-effect.txt';$filterDriver=Join-Path $root 'filter-driver.ps1';$escapedFilterProbe=$filterProbe.Replace("'","''");Write-Utf8Lf $filterDriver "[IO.File]::WriteAllText('$escapedFilterProbe','invoked')`nexit 1`n"
    Invoke-FixtureGit $git $repo @('init');Invoke-FixtureGit $git $repo @('config','user.name','Foundation Test');Invoke-FixtureGit $git $repo @('config','user.email','foundation@example.invalid');Invoke-FixtureGit $git $repo @('config','core.autocrlf','false')
    $driverCommand='"'+$hostExe+'" -NoProfile -NonInteractive -File "'+$textconvDriver+'"';Invoke-FixtureGit $git $repo @('config','diff.foundation-side-effect.textconv',$driverCommand)
    [IO.File]::WriteAllBytes((Join-Path $repo 'src\data.bin'),[byte[]](0,1,2,3));Write-Utf8Lf (Join-Path $repo 'src\rename-me.txt') "rename`n";Write-Utf8Lf (Join-Path $repo 'src\driver.txt') "version one`n";Write-Utf8Lf (Join-Path $repo 'src\filter.dat') "filter version one`n";Write-Utf8Lf (Join-Path $repo '.gitattributes') "*.txt diff=foundation-side-effect`n*.dat filter=foundation-filter`n"
    Invoke-FixtureGit $git $repo @('add','--','.gitattributes','src/data.bin','src/rename-me.txt','src/driver.txt','src/filter.dat');Invoke-FixtureGit $git $repo @('commit','-m','seed')
    $base=([Text.UTF8Encoding]::new($false,$true).GetString((Invoke-InternalGit $git $repo @('rev-parse','HEAD')).stdout)).Trim()
    Write-Utf8Lf (Join-Path $repo 'src\driver.txt') "version two`n";Invoke-FixtureGit $git $repo @('add','--','src/driver.txt');Invoke-FixtureGit $git $repo @('commit','-m','tracked text change')
    [IO.File]::WriteAllBytes((Join-Path $repo 'src\data.bin'),[byte[]](0,9,2,3));Invoke-FixtureGit $git $repo @('add','--','src/data.bin');[IO.File]::WriteAllBytes((Join-Path $repo 'src\data.bin'),[byte[]](0,9,8,3))
    Write-Utf8Lf (Join-Path $repo 'src\square[1].txt') "literal pathspec`n";Invoke-FixtureGit $git $repo @('mv','--','src/rename-me.txt','src/renamed.txt')
    $filterCommand='"'+$hostExe+'" -NoProfile -NonInteractive -File "'+$filterDriver+'"';Invoke-FixtureGit $git $repo @('config','filter.foundation-filter.clean',$filterCommand);Invoke-FixtureGit $git $repo @('config','filter.foundation-filter.process',$filterCommand);Invoke-FixtureGit $git $repo @('config','filter.foundation-filter.smudge',$filterCommand);Invoke-FixtureGit $git $repo @('config','filter.foundation-filter.required','true');Write-Utf8Lf (Join-Path $repo 'src\filter.dat') "filter version two`n"
    if([IO.File]::Exists($textconvProbe)){[IO.File]::Delete($textconvProbe)}
    $oldGitDir=$env:GIT_DIR;$oldConfigCount=$env:GIT_CONFIG_COUNT;$oldConfigKey=$env:GIT_CONFIG_KEY_0;$oldConfigValue=$env:GIT_CONFIG_VALUE_0;$env:GIT_DIR=('Z:'+[IO.Path]::DirectorySeparatorChar+'attacker-does-not-exist');$env:GIT_CONFIG_COUNT='1';$env:GIT_CONFIG_KEY_0='core.bare';$env:GIT_CONFIG_VALUE_0='true'
    try{$observation1=Get-MorphospaceGitRepositoryObservation -RepoId fixture -RepositoryPath $repo -BaseRevision $base -AllowedPaths @('src') -GitExecutable $git}finally{$env:GIT_DIR=$oldGitDir;$env:GIT_CONFIG_COUNT=$oldConfigCount;$env:GIT_CONFIG_KEY_0=$oldConfigKey;$env:GIT_CONFIG_VALUE_0=$oldConfigValue}
    Assert-Foundation ($observation1.scope_violation_count-eq0-and@($observation1.entries).Count-ge4) 'Git observation missed rename/binary/untracked entries'
    Assert-Foundation (@($observation1.entries|Where-Object{$_.attribution-ne'unassigned'}).Count-eq0) 'allowed path was misclassified as owned'
    Assert-Foundation (@($observation1.status_records|Where-Object{$_.xy-eq'MM'}).Count-eq1) 'index/worktree split state was not preserved'
    Assert-Foundation (-not[IO.File]::Exists($textconvProbe)) 'repository textconv driver executed during Git observation'
    Assert-Foundation (-not[IO.File]::Exists($filterProbe)) 'repository clean/process/smudge filter executed during Git observation'
    $worktreeConfigPath=Join-Path $repo '.git\config.worktree';Assert-Foundation (-not[IO.File]::Exists($worktreeConfigPath)) 'Git fixture unexpectedly began with config.worktree'
    Invoke-FixtureGit $git $repo @('config','extensions.worktreeConfig','true');Invoke-FixtureGit $git $repo @('config','--worktree','filter.foundation-worktree.clean',$filterCommand);Invoke-FixtureGit $git $repo @('config','--worktree','filter.foundation-worktree.process',$filterCommand);Invoke-FixtureGit $git $repo @('config','--worktree','filter.foundation-worktree.smudge',$filterCommand);Invoke-FixtureGit $git $repo @('config','--worktree','filter.foundation-worktree.required','true')
    Assert-Foundation ([IO.File]::Exists($worktreeConfigPath)) 'Git fixture did not create the formerly absent worktree config'
    Assert-Rejected {Get-MorphospaceGitRepositoryObservation -RepoId fixture-worktree-config -RepositoryPath $repo -BaseRevision $base -AllowedPaths @('src') -GitExecutable $git|Out-Null} 'extensions.worktreeConfig authority surface was accepted'
    Assert-Foundation (-not[IO.File]::Exists($filterProbe)) 'rejected worktree config executed its filter driver'
    Invoke-FixtureGit $git $repo @('config','--unset','extensions.worktreeConfig');[IO.File]::Delete($worktreeConfigPath)
    $overlay1=[string]$observation1.overlay_fingerprint_sha256;[IO.File]::WriteAllBytes((Join-Path $repo 'src\data.bin'),[byte[]](0,9,7,3))
    $observation2=Get-MorphospaceGitRepositoryObservation -RepoId fixture -RepositoryPath $repo -BaseRevision $base -AllowedPaths @('src') -GitExecutable $git
    Assert-Foundation ($overlay1-cne[string]$observation2.overlay_fingerprint_sha256) 'same-path byte change did not change overlay fingerprint'
    Assert-Foundation (-not[IO.File]::Exists($textconvProbe)) 'repository textconv driver executed during repeated Git observation'
    Assert-Foundation (-not[IO.File]::Exists($filterProbe)) 'repository filter executed during repeated Git observation'
    $gitLatePath=Join-Path $repo 'src\late-during-observation.txt';$gitStop=Join-Path $root 'git-race-stop';$gitReady=Join-Path $root 'git-race-ready';$gitRaceWorker=Join-Path $root 'git-race-worker.ps1';Write-Utf8Lf $gitRaceWorker "param(`$Target,`$Late,`$Stop,`$Ready)`n[IO.File]::WriteAllText(`$Ready,'ready')`n`$deadline=[DateTime]::UtcNow.AddSeconds(10)`nwhile([DateTime]::UtcNow-lt`$deadline-and-not[IO.File]::Exists(`$Stop)){try{`$s=[IO.FileStream]::new(`$Target,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);`$s.Dispose()}catch{[IO.File]::WriteAllText(`$Late,'late');exit 0};[Threading.Thread]::Sleep(1)}`nexit 7`n";$gitRace=Start-TestHostProcess @('-NoProfile','-NonInteractive','-File',$gitRaceWorker,'-Target',(Join-Path $repo 'src\data.bin'),'-Late',$gitLatePath,'-Stop',$gitStop,'-Ready',$gitReady);$gitReadyDeadline=[DateTime]::UtcNow.AddSeconds(5);while(-not[IO.File]::Exists($gitReady)-and[DateTime]::UtcNow-lt$gitReadyDeadline){[Threading.Thread]::Sleep(10)};Assert-Foundation ([IO.File]::Exists($gitReady)) 'Git race worker did not become ready';Assert-Rejected {Get-MorphospaceGitRepositoryObservation -RepoId fixture-race -RepositoryPath $repo -BaseRevision $base -AllowedPaths @('src') -GitExecutable $git|Out-Null} 'concurrent Git mutation/addition returned stale success';[IO.File]::WriteAllText($gitStop,'stop');$gitRace.WaitForExit();$gitRace.Dispose();if([IO.File]::Exists($gitLatePath)){[IO.File]::Delete($gitLatePath)}
    Assert-Rejected {Get-MorphospaceGitRepositoryObservation -RepoId fixture-subdir -RepositoryPath (Join-Path $repo 'src') -BaseRevision $base -AllowedPaths @('.') -GitExecutable $git|Out-Null} 'mapped Git subdirectory was accepted as the repository root'

    # Non-Git evidence is stable only when repeated leased passes agree.
    $nonGit=Join-Path $root 'non-git';[IO.Directory]::CreateDirectory((Join-Path $nonGit 'surface'))|Out-Null;$largePath=Join-Path $nonGit 'surface\large.bin';$large=[IO.FileStream]::new($largePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$large.SetLength(33554432)}finally{$large.Dispose()};$stableNonGit=Get-MorphospaceNonGitTreeObservation -RepoId non-git-fixture -RootPath $nonGit -AllowedPaths @('surface');Assert-Foundation ($stableNonGit.entries.Count-ge2) 'stable non-Git tree was not observed'
    $latePath=Join-Path $nonGit 'surface\late.txt';$stopPath=Join-Path $root 'non-git-stop';$readyPath=Join-Path $root 'non-git-ready';$lateWorker=Join-Path $root 'non-git-late-worker.ps1';$lateWorkerText=@'
param($Target,$Late,$Stop,$Ready)
[IO.File]::WriteAllText($Ready,'ready')
$deadline=[DateTime]::UtcNow.AddSeconds(10)
while([DateTime]::UtcNow-lt$deadline-and-not[IO.File]::Exists($Stop)){
    try{$s=[IO.FileStream]::new($Target,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$s.Dispose()}catch{[IO.File]::WriteAllText($Late,'late');exit 0}
    [Threading.Thread]::Sleep(1)
}
exit 7
'@
    Write-Utf8Lf $lateWorker $lateWorkerText;$lateProcess=Start-TestHostProcess @('-NoProfile','-NonInteractive','-File',$lateWorker,'-Target',$largePath,'-Late',$latePath,'-Stop',$stopPath,'-Ready',$readyPath);$readyDeadline=[DateTime]::UtcNow.AddSeconds(5);while(-not[IO.File]::Exists($readyPath)-and[DateTime]::UtcNow-lt$readyDeadline){[Threading.Thread]::Sleep(10)};Assert-Foundation ([IO.File]::Exists($readyPath)) 'non-Git race worker did not become ready';Assert-Rejected {Get-MorphospaceNonGitTreeObservation -RepoId non-git-race -RootPath $nonGit -AllowedPaths @('surface')|Out-Null} 'concurrent non-Git mutation/addition returned stale success';[IO.File]::WriteAllText($stopPath,'stop');$lateProcess.WaitForExit();$lateProcess.Dispose()

    # Instruction surfaces resolve to one canonical identity and remain leased through repeated full-set passes.
    $instructionRoot=Join-Path $root 'instruction-owner';[IO.Directory]::CreateDirectory((Join-Path $instructionRoot 'docs'))|Out-Null;Write-Utf8Lf (Join-Path $instructionRoot 'AGENTS.md') "agent rules`n";Write-Utf8Lf (Join-Path $instructionRoot 'docs\workflow.md') "workflow rules`n";$repositoryMap=@{'instruction-owner'=[pscustomobject]@{repo_id='instruction-owner';path=$instructionRoot;role='source';aliases=@('owner')}};$instructionUnit=[pscustomobject]@{instruction_impact='update';instruction_surfaces=@([pscustomobject]@{surface_kind='agent';path='<owner>/AGENTS.md';owner='instruction-owner';action='update';status='complete'},[pscustomobject]@{surface_kind='router';path='<owner>/docs/workflow.md';owner='instruction-owner';action='update';status='complete'})};$instructionObservation=@(Get-MorphospaceInstructionObservation $instructionUnit $repositoryMap);Assert-Foundation ($instructionObservation.Count-eq2) 'stable instruction surface set was not observed'
    $duplicateUnit=[pscustomobject]@{instruction_impact='update';instruction_surfaces=@($instructionUnit.instruction_surfaces[0],[pscustomobject]@{surface_kind='agent';path=(Join-Path $instructionRoot 'AGENTS.md');owner='instruction-owner';action='update';status='complete'})};Assert-Rejected {Get-MorphospaceInstructionObservation $duplicateUnit $repositoryMap|Out-Null} 'instruction alias/root path identity collision was accepted'
    $instructionWriter=Join-Path $root 'instruction-writer.ps1';$instructionReady=Join-Path $root 'instruction-ready';$instructionStop=Join-Path $root 'instruction-stop';$instructionWriterText=@'
param($Target,$Ready,$Stop)
$stream=[IO.FileStream]::new($Target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
try{[IO.File]::WriteAllText($Ready,'ready');$value=0;while(-not[IO.File]::Exists($Stop)){$stream.Position=0;$stream.WriteByte([byte]($value%251));$stream.Flush();$value++;[Threading.Thread]::Sleep(1)}}finally{$stream.Dispose()}
'@
    Write-Utf8Lf $instructionWriter $instructionWriterText;$instructionProcess=Start-TestHostProcess @('-NoProfile','-NonInteractive','-File',$instructionWriter,'-Target',(Join-Path $instructionRoot 'AGENTS.md'),'-Ready',$instructionReady,'-Stop',$instructionStop);$instructionDeadline=[DateTime]::UtcNow.AddSeconds(5);while(-not[IO.File]::Exists($instructionReady)-and[DateTime]::UtcNow-lt$instructionDeadline){[Threading.Thread]::Sleep(10)};Assert-Foundation ([IO.File]::Exists($instructionReady)) 'instruction mutation worker did not become ready';Assert-Rejected {Get-MorphospaceInstructionObservation $instructionUnit $repositoryMap|Out-Null} 'concurrent instruction same-path mutation returned stale success';[IO.File]::WriteAllText($instructionStop,'stop');$instructionProcess.WaitForExit();$instructionProcess.Dispose()

    # Legacy prefix high-water projection, SHA-chained receipts, transactions, and repair.
    $eventRoot=Join-Path $root 'event-workspace';[IO.Directory]::CreateDirectory((Join-Path $eventRoot 'receipts'))|Out-Null
    $times=@('2026-07-11T09:00:00Z','2026-07-11T12:10:00+02:00','2026-07-11T11:28:00+02:00','2026-07-11T11:34:00+02:00','2026-07-11T11:35:00+02:00')
    $legacy=New-Object Text.StringBuilder
    for($i=0;$i-lt$times.Count;$i++){$event=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id="unit-test-old-$('{0:d4}'-f($i+1))";sequence=$i+1;timestamp=$times[$i];project_id='test-project';unit_id='unit-test';event_type='validation';summary='legacy';receipts=@()};[void]$legacy.Append(($event|ConvertTo-Json -Compress));[void]$legacy.Append("`n")}
    $eventsPath=Join-Path $eventRoot 'iteration-events.jsonl';Write-Utf8Lf $eventsPath $legacy.ToString()
    $legacyObservation=Get-MorphospaceLegacyEventPrefixObservation $eventsPath 'test-project';Assert-Foundation ($legacyObservation.anomalies.Count-eq3) 'high-water anomaly projection did not include all below-high-water events'
    $projectionPath='receipts/timestamp-anomalies.json';$projection=[ordered]@{schema='rusty.morphospace.workflow.timestamp_anomaly_projection.v1';projection_id='unit-test-anomalies';project_id='test-project';unit_id='unit-test';created_at='2026-07-11T16:00:00.0000000Z';legacy_prefix_sha256=$legacyObservation.prefix_sha256;anomalies=@($legacyObservation.anomalies);safe_to_anchor=$true}
    Write-MorphospaceManagedProtocolJsonAtomic $eventRoot $projectionPath $projection -NoOverwrite;$projectionRef=[pscustomobject][ordered]@{role='timestamp-anomaly-projection';path=$projectionPath;schema=[string]$projection.schema;sha256=(Get-MorphospaceFileSha256 (Join-Path $eventRoot $projectionPath))}
    $run='unit-test-'+[guid]::NewGuid().ToString('N');$anchor=New-MorphospaceLegacyPrefixAnchor -WorkspaceRoot $eventRoot -ProjectId test-project -UnitId unit-test -RunId $run -Timestamp '2026-07-11T16:00:01.0000000Z' -TimestampAnomalyProjection $projectionRef -Execute
    $tamperedAnchor=Read-MorphospaceProtocolJson (Join-Path $eventRoot $anchor.reference.path);$tamperedAnchor.last_sequence=[int]$tamperedAnchor.last_sequence+10;$tamperedAnchorPath='receipts/tampered-anchor.json';Write-MorphospaceManagedProtocolJsonAtomic $eventRoot $tamperedAnchorPath $tamperedAnchor -NoOverwrite;$tamperedAnchorRef=[pscustomobject][ordered]@{role='legacy-prefix-anchor';path=$tamperedAnchorPath;schema='rusty.morphospace.workflow.legacy_event_prefix_anchor.v1';sha256=(Get-MorphospaceFileSha256 (Join-Path $eventRoot $tamperedAnchorPath))}
    Assert-Rejected {Test-MorphospaceEventChain $eventRoot $tamperedAnchorRef|Out-Null} 'self-authored anchor metadata shifted sequence authority'
    $evidencePath='receipts/typed-evidence.json';Write-MorphospaceManagedProtocolJsonAtomic $eventRoot $evidencePath ([ordered]@{schema='test.typed.evidence.v1';result='pass'}) -NoOverwrite;$evidenceRef=[pscustomobject][ordered]@{role='typed-evidence';path=$evidencePath;schema='test.typed.evidence.v1';sha256=(Get-MorphospaceFileSha256 (Join-Path $eventRoot $evidencePath))}
    $append=Invoke-TestEventAppend -WorkspaceRoot $eventRoot -AnchorReference $anchor.reference -ProjectId test-project -UnitId unit-test -ActionSlug validation -EventType validation -Summary 'typed append' -RunId $run -SessionId unit-test-session1 -Timestamp '2026-07-11T16:00:02.0000000Z' -ReceiptReferences @($evidenceRef) -Execute
    $chain=Test-MorphospaceEventChain $eventRoot $anchor.reference $append.tail;Assert-Foundation ($chain.event_count-eq1) 'v2 event append did not validate'
    $nextUnitRun='next-unit-'+[guid]::NewGuid().ToString('N');$nextUnitEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v2';event_id='next-unit-plan-0007';sequence=[int]$append.tail.sequence+1;timestamp='2026-07-11T16:00:03.0000000Z';run_id=$nextUnitRun;session_id='next-unit-session1';project_id='test-project';unit_id='next-unit';event_type='state-transition';summary='authorized by a future higher-layer unit transition';previous_event_sha256=[string]$append.tail.sha256;receipts=@()}
    &$script:EventModule {param($w,$e,$c) Test-MorphospaceCandidateEvent $w $e $c} $eventRoot $nextUnitEvent $chain
    $intentPath=Join-Path $eventRoot $append.transaction.intent;$intentRef=[pscustomobject][ordered]@{role='event-transaction-intent';path=$append.transaction.intent;schema='rusty.morphospace.workflow.event_transaction_intent.v1';sha256=(Get-MorphospaceFileSha256 $intentPath)}
    Assert-Foundation ((Invoke-InternalEventRepair $eventRoot $intentRef $anchor.reference).status-ceq'committed') 'idempotent completed repair failed'
    $completionPath=Join-Path $eventRoot $append.transaction.completion;$savedIntentBytes=[IO.File]::ReadAllBytes($intentPath);$savedCompletionBytes=[IO.File]::ReadAllBytes($completionPath);$damagedIntent=Read-MorphospaceProtocolJson $intentPath;$damagedIntent.anchor=$evidenceRef;Write-Utf8Lf $intentPath ((ConvertTo-MorphospaceCanonicalJson $damagedIntent)+"`n");$damagedCompletion=Read-MorphospaceProtocolJson $completionPath;$damagedCompletion.intent.sha256=Get-MorphospaceFileSha256 $intentPath;Write-Utf8Lf $completionPath ((ConvertTo-MorphospaceCanonicalJson $damagedCompletion)+"`n")
    Assert-Rejected {Test-MorphospaceEventChain $eventRoot $anchor.reference $append.tail|Out-Null} 'ledger accepted an intent bound to a non-authorized anchor';[IO.File]::WriteAllBytes($intentPath,$savedIntentBytes);[IO.File]::WriteAllBytes($completionPath,$savedCompletionBytes)
    $evidenceBytes=[IO.File]::ReadAllBytes((Join-Path $eventRoot $evidencePath));Write-Utf8Lf (Join-Path $eventRoot $evidencePath) '{"schema":"test.typed.evidence.v1","result":"fail"}'
    Assert-Rejected {Test-MorphospaceEventChain $eventRoot $anchor.reference $append.tail|Out-Null} 'referenced receipt substitution was accepted';[IO.File]::WriteAllBytes((Join-Path $eventRoot $evidencePath),$evidenceBytes)

    # Simulate a crash after a partial exact append, then finish without truncation.
    $intent=Read-MorphospaceProtocolJson $intentPath;$fullLog=[IO.File]::ReadAllBytes($eventsPath);$preLength=[int]$intent.pre_event_log_length;$partial=New-Object byte[] ($preLength+11);[Array]::Copy($fullLog,0,$partial,0,$partial.Length);[IO.File]::WriteAllBytes($eventsPath,$partial);[IO.File]::Delete((Join-Path $eventRoot $append.transaction.completion))
    $completion=Invoke-InternalEventRepair $eventRoot $intentRef $anchor.reference;Assert-Foundation ($completion.status-ceq'committed') 'partial exact append was not safely completed'

    # Invalid semantic candidates must fail before intent creation or event mutation.
    $tailBefore=(Test-MorphospaceEventChain $eventRoot $anchor.reference $completion.tail).tail;$logHashBefore=Get-MorphospaceFileSha256 $eventsPath;$transactionCountBefore=@([IO.Directory]::GetFiles((Join-Path $eventRoot 'receipts\event-transactions'),'*.json')).Count
    $badRun='unit-test-'+[guid]::NewGuid().ToString('N')
    Assert-Rejected {Invoke-TestEventAppend -WorkspaceRoot $eventRoot -AnchorReference $anchor.reference -ProjectId wrong-project -UnitId unit-test -ActionSlug wrong-project -EventType validation -Summary blocked -RunId $badRun -SessionId unit-test-session2 -Timestamp '2026-07-11T16:00:03.0000000Z' -ExpectedTail $tailBefore -Execute|Out-Null} 'wrong-project candidate reached mutation'
    Assert-Rejected {Invoke-TestEventAppend -WorkspaceRoot $eventRoot -AnchorReference $anchor.reference -ProjectId test-project -UnitId unit-test -ActionSlug wrong-type -EventType arbitrary -Summary blocked -RunId $badRun -SessionId unit-test-session2 -Timestamp '2026-07-11T16:00:03.0000000Z' -ExpectedTail $tailBefore -Execute|Out-Null} 'arbitrary event type reached mutation'
    Assert-Rejected {Invoke-TestEventAppend -WorkspaceRoot $eventRoot -AnchorReference $anchor.reference -ProjectId test-project -UnitId unit-test -ActionSlug empty-summary -EventType validation -Summary '' -RunId $badRun -SessionId unit-test-session2 -Timestamp '2026-07-11T16:00:03.0000000Z' -ExpectedTail $tailBefore -Execute|Out-Null} 'empty event summary reached mutation'
    Assert-Foundation ((Get-MorphospaceFileSha256 $eventsPath)-ceq$logHashBefore-and@([IO.Directory]::GetFiles((Join-Path $eventRoot 'receipts\event-transactions'),'*.json')).Count-eq$transactionCountBefore) 'rejected semantic candidate left a transaction or changed the log'
    $badCaseEvent=[pscustomobject][ordered]@{Schema='rusty.morphospace.workflow.iteration_event.v2';event_id='unit-test-case-0007';sequence=7;timestamp='2026-07-11T16:00:03.0000000Z';run_id=$badRun;session_id='unit-test-session2';project_id='test-project';unit_id='unit-test';event_type='validation';summary='case';previous_event_sha256=[string]$tailBefore.sha256;receipts=@()}
    Assert-Rejected {&$script:EventModule {param($e) Test-MorphospaceEventV2Document $e} $badCaseEvent} 'wrong-case event property was accepted'

    # Preplanted completion and incomplete intent block before any append.
    $logHashBefore=Get-MorphospaceFileSha256 $eventsPath
    $run2='unit-test-'+[guid]::NewGuid().ToString('N');$sequence=[int]$tailBefore.sequence+1;$txBase="receipts/event-transactions/unit-test-$('{0:d6}'-f$sequence)-$run2";[IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $eventRoot "$txBase.completion.json")))|Out-Null;Write-Utf8Lf (Join-Path $eventRoot "$txBase.completion.json") '{}'
    Assert-Rejected {Invoke-TestEventAppend -WorkspaceRoot $eventRoot -AnchorReference $anchor.reference -ProjectId test-project -UnitId unit-test -ActionSlug blocked -EventType validation -Summary blocked -RunId $run2 -SessionId unit-test-session2 -Timestamp '2026-07-11T16:00:03.0000000Z' -ExpectedTail $tailBefore -Execute|Out-Null} 'preplanted completion did not block before append'
    Assert-Foundation ((Get-MorphospaceFileSha256 $eventsPath)-ceq$logHashBefore) 'preplanted completion attempt changed the event log';[IO.File]::Delete((Join-Path $eventRoot "$txBase.completion.json"))
    Write-Utf8Lf (Join-Path $eventRoot "$txBase.intent.json") '{}';Assert-Rejected {Invoke-TestEventAppend -WorkspaceRoot $eventRoot -AnchorReference $anchor.reference -ProjectId test-project -UnitId unit-test -ActionSlug blocked -EventType validation -Summary blocked -RunId $run2 -SessionId unit-test-session2 -Timestamp '2026-07-11T16:00:03.0000000Z' -ExpectedTail $tailBefore -Execute|Out-Null} 'incomplete intent did not block later append';[IO.File]::Delete((Join-Path $eventRoot "$txBase.intent.json"))
    $otherRun='other-unit-'+[guid]::NewGuid().ToString('N');$otherIntent="receipts/event-transactions/other-unit-$('{0:d6}'-f$sequence)-$otherRun.intent.json";Write-Utf8Lf (Join-Path $eventRoot $otherIntent) '{}'
    Assert-Rejected {Invoke-TestEventAppend -WorkspaceRoot $eventRoot -AnchorReference $anchor.reference -ProjectId test-project -UnitId unit-test -ActionSlug cross-unit-blocked -EventType validation -Summary blocked -RunId $run2 -SessionId unit-test-session2 -Timestamp '2026-07-11T16:00:03.0000000Z' -ExpectedTail $tailBefore -Execute|Out-Null} 'cross-unit unresolved transaction did not block globally'
    Assert-Foundation ((Get-MorphospaceFileSha256 $eventsPath)-ceq$logHashBefore) 'cross-unit unresolved transaction changed the event log';[IO.File]::Delete((Join-Path $eventRoot $otherIntent))

    # A structurally valid manual v2 line without its exact transaction pair is never a valid public chain.
    $manualBefore=[IO.File]::ReadAllBytes($eventsPath);$manualRun='unit-test-'+[guid]::NewGuid().ToString('N');$manualEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v2';event_id="unit-test-manual-$('{0:d4}'-f([int]$tailBefore.sequence+1))";sequence=[int]$tailBefore.sequence+1;timestamp='2026-07-11T16:00:04.0000000Z';run_id=$manualRun;session_id='unit-test-session3';project_id='test-project';unit_id='unit-test';event_type='validation';summary='manual append without transaction';previous_event_sha256=[string]$tailBefore.sha256;receipts=@()};$manualLine=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $manualEvent)+"`n");$manualBytes=[byte[]]::new($manualBefore.Length+$manualLine.Length);[Array]::Copy($manualBefore,0,$manualBytes,0,$manualBefore.Length);[Array]::Copy($manualLine,0,$manualBytes,$manualBefore.Length,$manualLine.Length);[IO.File]::WriteAllBytes($eventsPath,$manualBytes)
    Assert-Rejected {Test-MorphospaceEventChain $eventRoot $anchor.reference|Out-Null} 'public chain accepted a manual v2 line without intent/completion';[IO.File]::WriteAllBytes($eventsPath,$manualBefore)

    # Two separate PowerShell processes race with the same expected tail; exactly one commits.
    $worker=Join-Path $root 'event-worker.ps1';$anchorJson=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($anchor.reference|ConvertTo-Json -Compress)));$tailJson=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($tailBefore|ConvertTo-Json -Compress)))
    $workerText=@'
param($Module,$Workspace,$Anchor64,$Tail64,$RunId)
$ErrorActionPreference='Stop';Import-Module $Module -Force
$u=[Text.UTF8Encoding]::new($false);$anchor=$u.GetString([Convert]::FromBase64String($Anchor64))|ConvertFrom-Json;$tail=$u.GetString([Convert]::FromBase64String($Tail64))|ConvertFrom-Json
try{$m=Get-Module MorphospaceEventChain;&$m {param($w,$a,$r,$t) Add-MorphospaceEventV2 -WorkspaceRoot $w -AnchorReference $a -ProjectId test-project -UnitId unit-test -ActionSlug race -EventType validation -Summary race -RunId $r -SessionId unit-test-session3 -Timestamp '2026-07-11T16:00:04.0000000Z' -ExpectedTail $t -Execute|Out-Null} $Workspace $anchor $RunId $tail;exit 0}catch{exit 23}
'@
    Write-Utf8Lf $worker $workerText;$module=Join-Path $PSScriptRoot 'lib\MorphospaceEventChain.psm1';$processes=@()
    foreach($n in 1..2){$psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$hostExe;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$args=@('-NoProfile','-NonInteractive','-File',$worker,'-Module',$module,'-Workspace',$eventRoot,'-Anchor64',$anchorJson,'-Tail64',$tailJson,'-RunId',('unit-test-'+[guid]::NewGuid().ToString('N')));if($psi.PSObject.Properties.Name-contains'ArgumentList'){foreach($arg in $args){[void]$psi.ArgumentList.Add($arg)}}else{$psi.Arguments=(@($args|ForEach-Object{ConvertTo-TestProcessArgument ([string]$_)})-join' ')};$processes+=@([Diagnostics.Process]::Start($psi))}
    foreach($process in $processes){$process.WaitForExit()};$codes=@($processes|ForEach-Object{$_.ExitCode});foreach($process in $processes){$process.Dispose()};Assert-Foundation (@($codes|Where-Object{$_-eq0}).Count-eq1-and@($codes|Where-Object{$_-eq23}).Count-eq1) 'two-process event race did not produce exactly one winner'
    [void](Test-MorphospaceEventChain $eventRoot $anchor.reference)

    Write-Host 'Protocol foundation self-test passed.'
}finally{
    if($junctionPath-and(Microsoft.PowerShell.Management\Test-Path -LiteralPath $junctionPath)){[IO.Directory]::Delete($junctionPath)}
    if([IO.Directory]::Exists($root)){$resolved=[IO.Path]::GetFullPath($root);if(-not$resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing foundation cleanup outside temp.'};foreach($file in [IO.Directory]::EnumerateFiles($resolved,'*',[IO.SearchOption]::AllDirectories)){[IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal)};[IO.Directory]::Delete($resolved,$true)}
}
