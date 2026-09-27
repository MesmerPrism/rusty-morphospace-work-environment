param(
 [switch]$SelfTest,
 [ValidateSet('all','shared','legacy-publication')][string]$Stage='all',
 [string]$LegacyExecutorRoot='',
 [string]$LegacyExecutorRevision='',
 [switch]$KeepFailedFixture,
 [string]$FixtureRoot=''
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
# No-argument invocation runs the full suite; -SelfTest remains an explicit registry convention.
if($PSVersionTable.PSVersion-lt[version]'7.6'){throw 'Frozen validation re-entry tests require PowerShell7.6 or newer.'}
$repoRoot=Split-Path $PSScriptRoot -Parent
$testClock=[Diagnostics.Stopwatch]::StartNew()
$assertions=0
function Assert-Reentry([bool]$Value,[string]$Message){if(-not$Value){throw "Frozen re-entry fixture failed: $Message"};$script:assertions++}
function Write-ReentryJson([string]$Path,[object]$Value){
 [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))|Out-Null
 [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 100)+[char]10,[Text.UTF8Encoding]::new($false))
}
function Read-ReentryJson([string]$Path){Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -Depth 100 -DateKind String}
function Assert-ReentryFixtureSchema([string]$Path,[string]$OwnerRoot,[string]$Schema){
 Assert-Reentry (Test-Json -Json ([IO.File]::ReadAllText($Path)) -SchemaFile (Join-Path $OwnerRoot ('schemas/'+$Schema))) "caller fixture metadata violates $Schema : $Path"
}
function Get-ReentryRawHash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Copy-ReentryValue([object]$Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String}
function Invoke-ReentryGit([string]$Root,[string[]]$Arguments){
 $out=@(& git -C $Root @Arguments 2>&1)
 if($LASTEXITCODE-ne0){throw "Frozen fixture Git failed: $($Arguments-join' '): $($out-join' ')"}
 @($out|ForEach-Object{[string]$_})
}
function Get-ReentryGitScalar([string]$Root,[string[]]$Arguments){
 $rows=@(Invoke-ReentryGit $Root $Arguments)
 if($rows.Count-ne1){throw 'Fixture expected exactly one Git scalar'}
 $rows[0].Trim()
}
function Get-ReentryInventory([string]$Root){
 @(
  Get-ChildItem -LiteralPath $Root -Recurse -File -Force|
  Sort-Object FullName|
  ForEach-Object{[pscustomobject][ordered]@{path=[IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=Get-ReentryRawHash $_.FullName}}
 )
}
function Assert-ReentryNoWrite([object[]]$Before,[string]$Root,[string]$Case){
 $after=@(Get-ReentryInventory $Root)
 Assert-Reentry (($Before|ConvertTo-Json -Depth 20 -Compress)-ceq($after|ConvertTo-Json -Depth 20 -Compress)) "$Case changed the rejected fixture"
}
function Assert-ReentryReject([scriptblock]$Action,[string]$Expected,[string]$Root,[string]$Case){
 $before=@(Get-ReentryInventory $Root);$message=$null
 try{&$Action|Out-Null}catch{$message=$_.Exception.Message}
 Assert-Reentry ($null-ne$message-and$message-match$Expected) "$Case rejected at unexpected boundary: $message"
 Assert-ReentryNoWrite $before $Root $Case
}
function Write-ReentryPhase([string]$Name){
 [Console]::Error.WriteLine(('frozen_reentry_phase={0};elapsed_seconds={1:N3}'-f$Name,$testClock.Elapsed.TotalSeconds))
}
function New-ReentryOwnerSnapshot([string]$Source,[string]$Revision,[string]$Destination){
 Assert-Reentry (-not(Test-Path -LiteralPath $Destination)) 'owner snapshot destination must be absent'
 $resolved=Get-ReentryGitScalar $Source @('rev-parse',"$Revision^{commit}")
 Invoke-ReentryGit $Source @('clone','--no-hardlinks','--no-checkout',$Source,$Destination)|Out-Null
 Invoke-ReentryGit $Destination @('config','core.autocrlf','false')|Out-Null
 Invoke-ReentryGit $Destination @('checkout','--detach',$resolved)|Out-Null
 Invoke-ReentryGit $Destination @('config','commit.gpgsign','false')|Out-Null
 Invoke-ReentryGit $Destination @('config','user.name','Frozen Reentry Fixture')|Out-Null
 Invoke-ReentryGit $Destination @('config','user.email','frozen-reentry@example.invalid')|Out-Null
 Assert-Reentry (@(Invoke-ReentryGit $Destination @('status','--porcelain=v1','--untracked-files=all')).Count-eq0) 'exact owner snapshot is clean'
 Assert-Reentry ((Get-ReentryGitScalar $Destination @('rev-parse','HEAD'))-ceq$resolved) 'snapshot commit identity'
 return $Destination
}
function Get-ReentryOwnerClosure([string]$Root){
 @(
  Invoke-ReentryGit $Root @('ls-tree','-r','--name-only','HEAD')|
  Sort-Object -CaseSensitive|
  ForEach-Object{[pscustomobject][ordered]@{path=$_;sha256=Get-ReentryRawHash (Join-Path $Root $_)}}
 )
}
function Assert-ReentryOwnerUnchanged([string]$Root,[string]$Head,[string]$Tree,[object[]]$Closure){
 Assert-Reentry ((Get-ReentryGitScalar $Root @('rev-parse','HEAD'))-ceq$Head-and(Get-ReentryGitScalar $Root @('rev-parse','HEAD^{tree}'))-ceq$Tree) 'original executor Git identity unchanged'
 Assert-Reentry (@(Invoke-ReentryGit $Root @('status','--porcelain=v1','--untracked-files=all')).Count-eq0) 'original executor clean'
 Assert-Reentry (($Closure|ConvertTo-Json -Depth 10 -Compress)-ceq((Get-ReentryOwnerClosure $Root)|ConvertTo-Json -Depth 10 -Compress)) 'original complete raw executor closure unchanged'
}
function Invoke-ReentryChild([string]$Script,[string[]]$Arguments,[string]$Stdout,[string]$Stderr,[int]$BudgetSeconds){
 $psi=[Diagnostics.ProcessStartInfo]::new()
 $psi.FileName=(Get-Process -Id $PID).Path;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
 $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 foreach($arg in (@('-NoProfile','-File',$Script)+$Arguments)){[void]$psi.ArgumentList.Add($arg)}
 $child=[Diagnostics.Process]::new();$child.StartInfo=$psi;$watch=[Diagnostics.Stopwatch]::StartNew()
 try{
  [void]$child.Start();$outTask=$child.StandardOutput.ReadToEndAsync();$errTask=$child.StandardError.ReadToEndAsync()
  $timedOut=-not$child.WaitForExit($BudgetSeconds*1000);if($timedOut){$child.Kill($true);$child.WaitForExit()}
  [IO.File]::WriteAllText($Stdout,$outTask.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($Stderr,$errTask.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
  if($timedOut){throw "Frozen fixture child exceeded $BudgetSeconds seconds; retained raw output, no budget waiver"}
  if($child.ExitCode-ne0){throw "Frozen fixture child exit$($child.ExitCode); retained stderr:$Stderr"}
  return [pscustomobject]@{exit_code=$child.ExitCode;elapsed_seconds=$watch.Elapsed.TotalSeconds;stdout=$Stdout;stderr=$Stderr}
 }finally{$child.Dispose()}
}

# Retained command objects survive producer-equivalent Import-Module -Force reloads.
$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force -PassThru
$transitionLedgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -Force -PassThru
$admissionModule=Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force -PassThru
$candidateModule=Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -Force -PassThru
$automationModule=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force -PassThru
$receiptModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1') -Force -PassThru
. (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')

function Get-ReentryCanonicalHash([object]$Value){&$protocolModule { param($parameters) Get-MorphospaceCanonicalJsonSha256 @parameters } @{Value=$Value}}
function Invoke-ReentryOwnerAction([hashtable]$Parameters){
 $arguments=$Parameters.Clone();$expected=''
 if(-not$arguments.ContainsKey('RepoMapPath')){$arguments.RepoMapPath=Join-Path $arguments.WorkspaceRoot 'repository-map.json'}
 if($arguments.ContainsKey('ExpectedTransition')){$expected=[string]$arguments.ExpectedTransition;$arguments.Remove('ExpectedTransition')}
 $result=&$automationModule { param($parameters) Invoke-MorphospaceWorkUnitAutomation @parameters } $arguments
 if($expected){Assert-Reentry ($result.transition-ceq$expected-or([string]$arguments.Action-ceq'BeginValidation'-and$result.transition-ceq'idempotent')) "Public owner returned $($result.transition), expected $expected"}
 return $result
}
function New-ReentryReceipt([string]$Workspace,[string]$Id,[string]$Result,[string]$Timestamp){
 $unit=Read-ReentryJson (Join-Path $Workspace 'iteration-units/u002.json')
 $matrix=@(&$automationModule {param($u)New-MorphospaceValidationMatrix -Unit $u} $unit)
 $log=Join-Path $Workspace "receipts/$Id.log"
 [IO.Directory]::CreateDirectory((Split-Path $log -Parent))|Out-Null
 [IO.File]::WriteAllText($log,"Genuine lifecycle fixture diagnostic outcome: $Result. This is not product validation."+[char]10,[Text.UTF8Encoding]::new($false))
 $evidence=[ordered]@{receipt_id=$Id;tier='quick';result=$Result;artifacts=@([ordered]@{artifact_id='fixture-outcome';kind='test-log';path="$Id.log"});criteria=@($unit.acceptance|ForEach-Object{[ordered]@{acceptance_id=[string]$_.acceptance_id;status=$Result;command=[string]$_.command;evidence_refs=@('fixture-outcome')}});gates=@($matrix|Where-Object{[string]$_.disposition-cne'forbidden'}|ForEach-Object{[ordered]@{gate_id=[string]$_.gate_id;status=$Result;command=[string]$_.command;evidence_refs=@('fixture-outcome')}});device_validation=$null}
 $relative="receipts/$Id.json"
 $map=Read-ReentryJson (Join-Path $Workspace 'repository-map.json')
 $inside=@($map.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})
 $repository=[IO.Path]::GetFullPath([string]$inside[0].path).TrimEnd('\','/');$prefix=$repository+[IO.Path]::DirectorySeparatorChar
 $composition=Read-ReentryJson (Join-Path $Workspace 'source-composition.json')
 $selfHosted=[IO.Path]::GetFullPath($Workspace).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
 if($selfHosted-or[string]$composition.schema-ceq'rusty.morphospace.workflow.development_envelope_source_composition.v3'){
  # This ordinary external v1 receipt records the actual visible Git delta, not the generic builder's
  # unconditional output-file addition. Exact ignored private evidence is not a Git changed path.
  $composition=Read-ReentryJson (Join-Path $Workspace 'source-composition.json')
  $base=[string]@($composition.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0].commit
  $head=Get-ReentryGitScalar $repository @('rev-parse','HEAD');$branch=Get-ReentryGitScalar $repository @('symbolic-ref','--short','HEAD')
  $wsRelative=[IO.Path]::GetRelativePath($repository,$Workspace).Replace('\','/').TrimEnd('/')
  $transactionPrefix=$wsRelative+'/receipts/transactions/'
  $visible=@(Invoke-ReentryGit $repository @('-c','core.safecrlf=false','-c','core.autocrlf=false','diff','--name-only',$base,'--'))+@(Invoke-ReentryGit $repository @('ls-files','--others','--exclude-standard'))
  $outputRelative=$wsRelative+'/'+$relative
  if($selfHosted){
   & git -C $repository check-ignore --quiet -- $outputRelative
   if($LASTEXITCODE-eq1){$visible+=,$outputRelative}elseif($LASTEXITCODE-ne0){throw 'Could not observe exact receipt Git ignore visibility.'}
  }
  $allowed=@($unit.allowed_repositories[0].allowed_paths)
  $changed=@($visible|Where-Object{if(-not$_){return $false};$path=([string]$_).Replace('\','/');$within=@($allowed|Where-Object{$root=[string]$_;$path-ceq$root-or($root.EndsWith('/')-and$path.StartsWith($root,[StringComparison]::Ordinal))}).Count-gt0;$within-and-not$path.StartsWith($transactionPrefix,[StringComparison]::OrdinalIgnoreCase)}|Sort-Object -Unique|ForEach-Object{[ordered]@{repo_id='project-shell';path=[string]$_}})
  $document=[ordered]@{schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id=$Id;project_id=[string]$unit.project_id;unit_id='u002';created_at=$Timestamp;tier='quick';result=$Result;repository_revisions=@([ordered]@{repo_id='project-shell';base_revision=$base;head_revision=$head;branch=$branch});changed_paths=$changed;artifacts=@([ordered]@{artifact_id='fixture-outcome';kind='test-log';path="$Id.log";sha256=(Get-ReentryRawHash $log)});criteria=$evidence.criteria;gates=$evidence.gates;device_validation=$null}
  if(-not(Test-Json -Json ($document|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $repoRoot 'schemas/validation-receipt.schema.json'))){throw 'External ordinary self-hosted fixture receipt schema rejected.'}
  Write-ReentryJson (Join-Path $Workspace $relative) $document
  return $relative
 }
 &$receiptModule { param($parameters) New-MorphospaceValidationReceiptV1 @parameters } @{WorkspaceRoot=$Workspace;UnitId='u002';RepoMapPath=(Join-Path $Workspace 'repository-map.json');Evidence=([pscustomobject]$evidence);OutPath=$relative;CreatedAt=$Timestamp}|Out-Null
 return $relative
}
function New-ReentryFreezeRequest([string]$Workspace,[string]$Head,[string]$Tree){
 $project=Read-ReentryJson (Join-Path $Workspace 'project.spec.json');$state=Read-ReentryJson (Join-Path $Workspace 'workspace.state.json');$unit=Read-ReentryJson (Join-Path $Workspace 'iteration-units/u002.json');$lock=Read-ReentryJson (Join-Path $Workspace 'feature.lock.json')
 $source=Get-ReentryRawHash (Join-Path $Workspace 'source-composition.json');$events=Join-Path $Workspace 'iteration-events.jsonl';$lockHash=Get-ReentryCanonicalHash $lock
 return [ordered]@{schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id='u002-reentry-freeze';project_id=[string]$project.project_id;unit_id='u002';expected=[ordered]@{project_sha256=(Get-ReentryCanonicalHash $project);state_sha256=(Get-ReentryCanonicalHash $state);unit_sha256=(Get-ReentryCanonicalHash $unit);feature_lock_sha256=$lockHash;source_composition_path='source-composition.json';source_composition_sha256=$source;repository_map_path='repository-map.json';repository_map_sha256=(Get-ReentryRawHash (Join-Path $Workspace 'repository-map.json'));events_sha256=(Get-ReentryRawHash $events);events_length=([IO.FileInfo]$events).Length;event_tail_id=[string]$state.last_event_id};final_repositories=@([ordered]@{repo_id='project-shell';commit=$Head;tree=$Tree});changed_paths=@([ordered]@{repo_id='project-shell';paths=@('morphospace/')});cleanliness_policy='clean-only';instruction_surfaces=@([ordered]@{path='README.md';disposition='reviewed-no-change'});feature_lock=[ordered]@{revision=[int]$lock.revision;sha256=$lockHash};effects=@('none');permissions=@('none');device_use=@('none');test_matrix=@([ordered]@{test_id='quick';command='test'});cleanup_evidence=@('Only isolated lifecycle fixture files.');source_composition=[ordered]@{path='source-composition.json';sha256=$source};does_not_prove=@('Does not prove product acceptance or device behavior.')}
}
function Test-ReentrySharedJourney([string]$Root,[switch]$SelfHosted){
 Write-ReentryPhase 'shared: real Prepare and Admit'
 $seed=New-EnvelopeAdmissionPreparedFixture -Root $Root -RepositoryRoot $repoRoot -TransitionLedgerModule $transitionLedgerModule -OwnerProducedPreparation -AdditiveFeature
 $ws=[string]$seed.workspace;$admit=Join-Path $Root 'admission.json';Write-ReentryJson $admit $seed.admission_template
 $admitArgs=@{WorkspaceRoot=$ws;DevelopmentUnitAdmission=$admit;OutPath=(Join-Path $ws 'receipts/u002-admission.json');Timestamp='2026-08-25T00:01:00.0000000Z'}
 $dry=&$admissionModule { param($parameters) Invoke-MorphospaceAdmitDevelopmentUnit @parameters } $admitArgs
 Assert-Reentry (-not$dry.executed) 'admission dry unexpectedly executed'
 $admitArgs.ExpectedDevelopmentUnitAdmissionSha256=Get-ReentryRawHash $admit;$admitArgs.Execute=$true
 $run=&$admissionModule { param($parameters) Invoke-MorphospaceAdmitDevelopmentUnit @parameters } $admitArgs
 Assert-Reentry $run.executed 'admission execute did not complete'
 $null=Invoke-ReentryOwnerAction @{Action='Ready';WorkspaceRoot=$ws;UnitId='u002';Execute=$true;ExpectedTransition='proposed-to-ready';OutPath=(Join-Path $ws 'receipts/ready.json');Timestamp='2026-08-25T00:01:10.0000000Z'}
 $null=Invoke-ReentryOwnerAction @{Action='Claim';WorkspaceRoot=$ws;UnitId='u002';Execute=$true;ExpectedTransition='ready-to-active';OutPath=(Join-Path $ws 'receipts/claim.json');Timestamp='2026-08-25T00:01:20.0000000Z'}
 # Both cases preserve the real preparation baseline and use a genuine scoped source descendant.
 if($SelfHosted){
  $selfHostedWorkspace=Join-Path $seed.source_repository 'morphospace'
  Get-ChildItem -LiteralPath $ws -Force|ForEach-Object{Copy-Item -LiteralPath $_.FullName -Destination $selfHostedWorkspace -Recurse -Force}
  $ws=$selfHostedWorkspace
  # Exact diagnostic artifacts are private evidence, not new source. Ledger/control files remain visible Git dirt.
  $privateFiles=@(1..3|ForEach-Object{"morphospace/receipts/cycle-$_-fail.json";"morphospace/receipts/cycle-$_-fail.log"})+@('morphospace/receipts/final-pass.json','morphospace/receipts/final-pass.log')
  [IO.File]::AppendAllText((Join-Path $seed.source_repository '.git/info/exclude'),[char]10+($privateFiles-join[char]10)+[char]10,[Text.UTF8Encoding]::new($false))
 }else{
  [IO.File]::AppendAllText((Join-Path $seed.source_repository 'morphospace/README.md'),[char]10+'Scoped frozen source fixture descendant.'+[char]10,[Text.UTF8Encoding]::new($false))
 }
 Invoke-ReentryGit $seed.source_repository @('add','morphospace')|Out-Null
 Invoke-ReentryGit $seed.source_repository @('commit','-m','genuine admitted fixture transport before freeze')|Out-Null
 $head=Get-ReentryGitScalar $seed.source_repository @('rev-parse','HEAD');$tree=Get-ReentryGitScalar $seed.source_repository @('rev-parse','HEAD^{tree}')
 $freeze=New-ReentryFreezeRequest $ws $head $tree;$freezePath=Join-Path $Root 'freeze.json';Write-ReentryJson $freezePath $freeze
 $freezeArgs=@{WorkspaceRoot=$ws;UnitId='u002';CandidateFreeze=$freezePath;OutPath=(Join-Path $ws 'receipts/u002-reentry-freeze.json');Timestamp='2026-08-25T00:01:30.0000000Z'}
 $freezeDry=&$candidateModule { param($parameters) Invoke-MorphospaceFreezeCandidate @parameters } $freezeArgs
 Assert-Reentry (-not$freezeDry.executed) 'freeze dry executed'
 $freezeArgs.ExpectedCandidateFreezeSha256=Get-ReentryRawHash $freezePath;$freezeArgs.Execute=$true
 $null=&$candidateModule { param($parameters) Invoke-MorphospaceFreezeCandidate @parameters } $freezeArgs
 $freezeHash=Get-ReentryRawHash (Join-Path $ws 'receipts/u002-reentry-freeze.json');$sourceHash=Get-ReentryRawHash (Join-Path $ws 'source-composition.json')
 for($cycle=1;$cycle-le3;$cycle++){
  Write-ReentryPhase "shared: genuine Begin/nonpassReturn cycle $cycle"
  $time=[datetime]::Parse('2026-08-25T00:02:00Z').AddMinutes($cycle)
  $begin=@{Action='BeginValidation';WorkspaceRoot=$ws;UnitId='u002';Execute=$true;ExpectedTransition='active-to-validating';Timestamp=$time.ToString('o')}
  $null=Invoke-ReentryOwnerAction $begin
  $eventsBefore=Get-ReentryRawHash (Join-Path $ws 'iteration-events.jsonl')
  $null=Invoke-ReentryOwnerAction $begin
  Assert-Reentry ((Get-ReentryRawHash (Join-Path $ws 'iteration-events.jsonl'))-ceq$eventsBefore) 'same Begin replay duplicated ledger event'
  $receipt=New-ReentryReceipt $ws "cycle-$cycle-fail" 'fail' $time.AddSeconds(5).ToString('o')
  $null=Invoke-ReentryOwnerAction @{Action='ReturnToActive';WorkspaceRoot=$ws;UnitId='u002';ValidationResult='fail';ValidationTier='quick';ValidationReceipt=$receipt;ExpectedTransition='validation-fail-to-active';Execute=$true;Timestamp=$time.AddSeconds(10).ToString('o')}
  Assert-Reentry ((Read-ReentryJson (Join-Path $ws 'iteration-units/u002.json')).status-ceq'active') 'nonpass Return did not restore active'
  Assert-Reentry ((Get-ReentryRawHash (Join-Path $ws 'receipts/u002-reentry-freeze.json'))-ceq$freezeHash) 're-entry rewrote original freeze bytes'
  Assert-Reentry ((Get-ReentryRawHash (Join-Path $ws 'source-composition.json'))-ceq$sourceHash) 're-entry rewrote original source lock bytes'
  Assert-Reentry ((Get-ReentryGitScalar $seed.source_repository @('rev-parse','HEAD'))-ceq$head) 'lifecycle cycle advanced frozen candidate HEAD'
 }
 Write-ReentryPhase 'shared: immutable scope, source, and original freeze damage'
 $unitPath=Join-Path $ws 'iteration-units/u002.json';$unitBytes=[IO.File]::ReadAllBytes($unitPath)
 try{
  $damaged=Read-ReentryJson $unitPath;$damaged.allowed_repositories[0].allowed_paths+=,'outside/'
  Write-ReentryJson $unitPath $damaged
  Assert-ReentryReject {Invoke-ReentryOwnerAction @{Action='BeginValidation';WorkspaceRoot=$ws;UnitId='u002'}|Out-Null} 'freeze|scope|semantic|candidate|change|target unit projection' $ws 'widened frozen scope'
 }finally{[IO.File]::WriteAllBytes($unitPath,$unitBytes)}
 $freezeReceipt=Join-Path $ws 'receipts/u002-reentry-freeze.json';$freezeBytes=[IO.File]::ReadAllBytes($freezeReceipt)
 try{
  $damaged=Read-ReentryJson $freezeReceipt;$damaged.final_repositories[0].tree=('0'*40)
  Write-ReentryJson $freezeReceipt $damaged
  Assert-ReentryReject {Invoke-ReentryOwnerAction @{Action='BeginValidation';WorkspaceRoot=$ws;UnitId='u002'}|Out-Null} 'freeze|hash|bytes|candidate' $ws 'original freeze tamper'
 }finally{[IO.File]::WriteAllBytes($freezeReceipt,$freezeBytes)}
 $sourcePath=Join-Path $seed.source_repository 'morphospace/README.md';$sourceBytes=[IO.File]::ReadAllBytes($sourcePath)
 try{
  [IO.File]::WriteAllText($sourcePath,'unauthorized frozen source modification',[Text.UTF8Encoding]::new($false))
  Assert-ReentryReject {Invoke-ReentryOwnerAction @{Action='BeginValidation';WorkspaceRoot=$ws;UnitId='u002'}|Out-Null} 'dirty|freeze|candidate|path|source|continuation target state is detached' $ws 'frozen source dirt'
 }finally{[IO.File]::WriteAllBytes($sourcePath,$sourceBytes)}
 Write-ReentryPhase 'shared: proper receipt and actual separate Record/Accept'
 $null=Invoke-ReentryOwnerAction @{Action='BeginValidation';WorkspaceRoot=$ws;UnitId='u002';ExpectedTransition='active-to-validating';Execute=$true;Timestamp='2026-08-25T00:10:00Z'}
 $receipt=New-ReentryReceipt $ws 'final-pass' 'pass' '2026-08-25T00:10:05Z'
 $record=Invoke-ReentryOwnerAction @{Action='RecordValidation';WorkspaceRoot=$ws;UnitId='u002';ValidationTier='quick';ValidationResult='pass';ValidationReceipt=$receipt;Execute=$true;Timestamp='2026-08-25T00:10:10Z'}
 $accept=Invoke-ReentryOwnerAction @{Action='Accept';WorkspaceRoot=$ws;UnitId='u002';ValidationTier='quick';Execute=$true;Timestamp='2026-08-25T00:10:20Z'}
 Assert-Reentry ($record.transition-ceq'validation-pass'-and$accept.transition-ceq'validating-to-accepted') 'final producer transitions differ'
 Assert-Reentry ((Read-ReentryJson $unitPath).status-ceq'accepted'-and$null-eq(Read-ReentryJson (Join-Path $ws 'workspace.state.json')).current_unit) 'proper accepted terminal not reached'
 Assert-Reentry ((Get-ReentryRawHash $freezeReceipt)-ceq$freezeHash) 'Record/Accept rewrote original freeze bytes'
 Assert-Reentry ((Get-ReentryRawHash (Join-Path $ws 'source-composition.json'))-ceq$sourceHash) 'Record/Accept rewrote original lock bytes'
 return [pscustomobject]@{workspace=$ws;fixture=$seed;freeze_hash=$freezeHash;source_hash=$sourceHash;candidate_head=$head}
}
# UNEXECUTED functions-only draft for incorporation into the owned portable test.
# Requires the test's neutral helpers and retained public SourceOnly module objects.
# No real workspace, device, installed router, or external Git remote is a target.
function New-ReentryPublisherBootstrap([string]$Root,[string]$Tool,[string]$Skills,[string[]]$ChangedPaths){
 $ownedPrefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
 if(-not[IO.Path]::GetFullPath($Tool).StartsWith($ownedPrefix,[StringComparison]::OrdinalIgnoreCase)-or-not[IO.Path]::GetFullPath($Skills).StartsWith($ownedPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Publisher fixture targets must be beneath this owned temporary fixture root.'}
 $owner=Join-Path $Root 'owner-planning';[IO.Directory]::CreateDirectory($owner)|Out-Null
 Invoke-ReentryGit $owner @('init','--initial-branch=main')|Out-Null
 Invoke-ReentryGit $owner @('config','user.name','Frozen re-entry fixture')|Out-Null
 Invoke-ReentryGit $owner @('config','user.email','frozen-reentry@example.invalid')|Out-Null
 Invoke-ReentryGit $owner @('config','commit.gpgsign','false')|Out-Null
 Invoke-ReentryGit $owner @('config','core.autocrlf','false')|Out-Null
 Invoke-ReentryGit $owner @('config','core.longpaths','true')|Out-Null
 Invoke-ReentryChild (Join-Path $Tool 'scripts/New-ProjectWorkspace.ps1') @('-ProjectRoot',$owner,'-ProjectId','fixture-publisher','-Purpose','Publish a genuinely tested fixture owner snapshot to the local fixture remote.','-Execute') (Join-Path $Root 'bootstrap.stdout') (Join-Path $Root 'bootstrap.stderr') 120|Out-Null
 $ws=Join-Path $owner 'morphospace'
 # Only caller-local diagnostic inputs are ignored. Genuine receipts, ledger, state and
 # unit transport remain visible and are committed in the accepted planning checkpoint.
 [IO.File]::AppendAllText((Join-Path $owner '.git/info/exclude'),[char]10+'/morphospace/local/'+[char]10,[Text.UTF8Encoding]::new($false))
 $project=Read-ReentryJson (Join-Path $ws 'project.spec.json')
 $project.repositories=@([ordered]@{repo_id='workflow';role='tool';path='<workflow>';allowed_paths=@($ChangedPaths)},[ordered]@{repo_id='fixture-planning';role='planning';path='<fixture-planning>';allowed_paths=@('morphospace/')})
 $command='pwsh -NoProfile -File <workflow>/scripts/Test-FixturePublicationOwner.ps1'
 $project.validation_profiles=@([ordered]@{profile_id='fixture-owner';commands=@($command)})
 $unit=Read-ReentryJson (Join-Path $Tool 'examples/hello-morphospace-v2/morphospace/iteration-units/hello-001.json')
 $unit.project_id='fixture-publisher';$unit.unit_id='u002';$unit.status='proposed';$unit.objective='Validate and genuinely publish the local fixture owner snapshot.'
 $unit|Add-Member -NotePropertyName work_mode -NotePropertyValue 'feature';$unit|Add-Member -NotePropertyName claim_requirements -NotePropertyValue ([ordered]@{minimum_free_disk_mib=1;required_tools=@();product_inputs=@()});$unit.tags=@('fixture');$unit.prerequisites=@();$unit.change_categories=@('workflow-automation');$unit.instruction_impact='review';$unit.instruction_none_justification=$null
 $unit.allowed_repositories=@([ordered]@{repo_id='workflow';allowed_paths=@($ChangedPaths)})
 $unit.acceptance=@([ordered]@{acceptance_id='bounded-owner-check';proof='The real bounded owner check exits zero on the exact committed fixture source.';command=$command})
 $unit.validation=@([ordered]@{profile_id='fixture-owner';command=$command});$unit.device_requirement='forbidden'
 $unit.non_scope=@('Real project acceptance.','External publication.','Device operations.','Source changes outside the fixture candidate.')
 $unit.instruction_surfaces=@(
  [ordered]@{surface_kind='agents';path='<workflow>/AGENTS.md';owner='workflow-maintainer';change_reason='Read exact fixture owner instructions.';action='review-no-change';status='planned';validation='Exact fixture source bytes.';skill_id=$null},
  [ordered]@{surface_kind='readme';path='<workflow>/README.md';owner='workflow-maintainer';change_reason='Read exact fixture owner routing.';action='review-no-change';status='planned';validation='Exact fixture source bytes.';skill_id=$null},
  [ordered]@{surface_kind='validation-doc';path='<workflow>/docs/CURRENT_WORK_VALIDATION.md';owner='workflow-maintainer';change_reason='Read current continuation contract.';action='review-no-change';status='planned';validation='Exact fixture source bytes.';skill_id=$null}
 )
 foreach($skill in @('rusty-morphospace','system-engineering','rust-work-graph')){$unit.instruction_surfaces+=,[ordered]@{surface_kind='skill';path="<skills-root>/$skill/SKILL.md";owner='workflow-maintainer';change_reason='Read exact isolated managed router.';action='review-no-change';status='planned';validation='Actual isolated installer metadata and managed bytes.';skill_id=$skill}}
 $unit|Add-Member -NotePropertyName read_only_dependencies -NotePropertyValue @([ordered]@{repo_id='fixture-planning';paths=@('morphospace/');purpose='Private fixture lifecycle transport.';verification='Actual accepted planning checkpoint.'})
 Write-ReentryJson (Join-Path $ws 'project.spec.json') $project;Write-ReentryJson (Join-Path $ws 'iteration-units/u002.json') $unit
 Write-ReentryJson (Join-Path $ws 'local/repository-map.json') ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='workflow';role='source';path=$Tool},[ordered]@{repo_id='fixture-planning';role='planning';path=$owner},[ordered]@{repo_id='skill-surfaces';role='source';path=$Skills;aliases=@('skills-root')})})
 # Initial documents only: genuine Ready/Claim/instruction completion must follow through public producers.
 Invoke-ReentryGit $owner @('add','morphospace')|Out-Null;Invoke-ReentryGit $owner @('commit','-m','initial genuine fixture publisher contract')|Out-Null
 return [pscustomobject]@{owner=$owner;workspace=$ws;map=(Join-Path $ws 'local/repository-map.json');command=$command}
}

function Invoke-ReentryPublisherPublication([object]$Fixture,[string]$Tool,[string]$Root){
 $ownedPrefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
 if(-not[IO.Path]::GetFullPath($Tool).StartsWith($ownedPrefix,[StringComparison]::OrdinalIgnoreCase)-or-not[IO.Path]::GetFullPath($Fixture.workspace).StartsWith($ownedPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Publication fixture targets must be beneath this owned temporary fixture root.'}
 # Preconditions are produced by the caller: real Ready/Claim/Instructions/Begin, actual bounded
 # check with retained streams, truthful generic v1 Record/Accept, then a clean accepted owner commit.
 $ws=$Fixture.workspace;$id='fixture-owner-publication';$planInput=Join-Path $ws 'local/plan-input.json'
 $plan=&$publicationInputsModule { param($parameters) New-MorphospaceSourceOnlyPublicationPlan @parameters } @{WorkspaceRoot=$ws;UnitId='u002';RepoMapPath=$Fixture.map;PublicationId=$id;PublicationMode='fast-forward';OutPath=$planInput}
 & git -C $Fixture.owner check-ignore --quiet -- 'morphospace/local/plan-input.json'
 Assert-Reentry ($LASTEXITCODE-eq0) 'caller-local publication input must be genuinely Git ignored'
 Assert-Reentry (@(Invoke-ReentryGit $Fixture.owner @('status','--porcelain=v1','--untracked-files=all')).Count-eq0) 'accepted fixture planning checkpoint must remain clean before publication Prepare'
 $preparedPath=Join-Path $ws "receipts/$id-plan.json"
 &$publicationModule { param($parameters) Invoke-MorphospacePrepareSourceOnlyPublication @parameters } @{WorkspaceRoot=$ws;UnitId='u002';RepoMapPath=$Fixture.map;SourceOnlyPublicationPlan=$planInput;ExpectedSourceOnlyPublicationPlanSha256=$plan.sha256;OutPath=$preparedPath;Timestamp=([datetime]::UtcNow.ToString('o'));Execute=$true}|Out-Null
 $start=&$publicationInputsModule { param($parameters) Start-MorphospaceSourceOnlyPublicationOperation @parameters } @{PlanPath=$preparedPath;RepoId='workflow';Timestamp=([datetime]::UtcNow.ToString('o'));OutPath=(Join-Path $ws 'local/operation-start.json')}
 $push=@(Invoke-ReentryGit $Tool @('push','origin','HEAD:refs/heads/main'))
 $pushLog=Join-Path $ws 'local/push.log';[IO.File]::WriteAllText($pushLog,($push-join[char]10)+[char]10,[Text.UTF8Encoding]::new($false))
 Invoke-ReentryGit $Tool @('fetch','origin','main')|Out-Null
 $operationPath=Join-Path $ws 'local/operation-evidence.json'
 Write-ReentryJson $operationPath ([ordered]@{schema='rusty.morphospace.workflow.source_only_publication_operation_evidence.v1';operation_start_sha256=(Get-ReentryRawHash $start.path);provider=[ordered]@{repo_id='workflow';executor_id='real-local-fixture-push'};outcome=[ordered]@{operation_finished_at=([datetime]::UtcNow.ToString('o'));push_mode='fast-forward';force_used=$false;result='pass'};artifact=[ordered]@{path='push.log';sha256=(Get-ReentryRawHash $pushLog)}})
 $observation=&$publicationInputsModule { param($parameters) Complete-MorphospaceSourceOnlyPublicationOperationObservation @parameters } @{PlanPath=$preparedPath;OperationStartPath=$start.path;OperationEvidencePath=$operationPath;ExpectedOperationEvidenceSha256=(Get-ReentryRawHash $operationPath);RepoMapPath=$Fixture.map;Timestamp=([datetime]::UtcNow.ToString('o'));OutPath=(Join-Path $ws 'local/operation-observation.json')}
 $executionInput=Join-Path $ws 'local/execution-input.json'
 $execution=&$publicationInputsModule { param($parameters) New-MorphospaceSourceOnlyPublicationExecution @parameters } @{PlanPath=$preparedPath;OperationObservationPaths=@($observation.path);RepoMapPath=$Fixture.map;OutPath=$executionInput}
 $recordedPath=Join-Path $ws "receipts/$id-execution.json"
 &$publicationModule { param($parameters) Invoke-MorphospaceRecordSourceOnlyPublication @parameters } @{WorkspaceRoot=$ws;UnitId='u002';RepoMapPath=$Fixture.map;SourceOnlyPublicationExecution=$executionInput;ExpectedSourceOnlyPublicationExecutionSha256=$execution.sha256;OutPath=$recordedPath;Timestamp=([datetime]::UtcNow.ToString('o'));Execute=$true}|Out-Null
 return [pscustomobject]@{owner_workspace=$ws;plan=[ordered]@{path="receipts/$id-plan.json";sha256=(Get-ReentryRawHash $preparedPath)};execution=[ordered]@{path="receipts/$id-execution.json";sha256=(Get-ReentryRawHash $recordedPath)};record_event_id=[string](Read-ReentryJson (Join-Path $ws 'workspace.state.json')).last_event_id}
}

function Complete-ReentryInstructions([string]$Workspace,[string]$Map,[string]$Id){
 $instructionArguments=@{Action='CompleteInstructionSurfaces';WorkspaceRoot=$Workspace;UnitId='u002';RepoMapPath=$Map;InstructionCompletionId=$Id;OutPath=(Join-Path $Workspace "receipts/$Id-instruction-surfaces.json");Timestamp='2026-08-25T00:01:25Z'}
 $dry=&$automationModule { param($parameters) Invoke-MorphospaceWorkUnitAutomation @parameters } $instructionArguments
 $binding=$dry.instruction_surface_completion
 Assert-Reentry ($binding.all_planned_surfaces_completed) 'instruction dry did not observe the exact planned surfaces'
 $instructionArguments.InstructionSurfaceIds=@($binding.surfaces|ForEach-Object{[string]$_.surface_id});$instructionArguments.ExpectedUnitSha256=[string]$binding.expected_unit_sha256;$instructionArguments.ExpectedInstructionObservationSha256=[string]$binding.observation_sha256;$instructionArguments.Execute=$true
 $actual=&$automationModule { param($parameters) Invoke-MorphospaceWorkUnitAutomation @parameters } $instructionArguments
 Assert-Reentry $actual.executed 'instruction completion did not execute'
 return [string]$instructionArguments.OutPath
}
function New-ReentryPassingOwnerReceipt([object]$Fixture,[string]$Tool,[string]$CheckOut,[string]$CheckErr){
 $ws=$Fixture.workspace;$unit=Read-ReentryJson (Join-Path $ws 'iteration-units/u002.json')
 $artifacts=@();foreach($row in @(@{id='owner-stdout';path=$CheckOut},@{id='owner-stderr';path=$CheckErr},@{id='instruction-completion';path=$Fixture.instructions})){
  $artifacts+=,[ordered]@{artifact_id=$row.id;kind='test-log';path=[IO.Path]::GetRelativePath((Join-Path $ws 'receipts'),$row.path).Replace('\','/');sha256=(Get-ReentryRawHash $row.path)}
 }
 $matrix=@(&$automationModule {param($u)New-MorphospaceValidationMatrix -Unit $u} $unit)
 $evidence=[pscustomobject][ordered]@{receipt_id='owner-pass';tier='quick';result='pass';artifacts=@($artifacts|ForEach-Object{[ordered]@{artifact_id=$_.artifact_id;kind=$_.kind;path=$_.path}});criteria=@($unit.acceptance|ForEach-Object{[ordered]@{acceptance_id=$_.acceptance_id;status='pass';command=$_.command;evidence_refs=@('owner-stdout','owner-stderr')}});gates=@($matrix|Where-Object{$_.disposition-cne'forbidden'}|ForEach-Object{[ordered]@{gate_id=$_.gate_id;status='pass';command=$_.command;evidence_refs=@(if($_.kind-ceq'instruction'){'instruction-completion'}else{'owner-stdout';'owner-stderr'})}});device_validation=$null}
 # The bootstrap has no assessment/Freeze. Its supported ordinary external v1 receipt
 # binds the actual executed check and instruction completion, without a builder claim.
 $composition=Read-ReentryJson (Join-Path $ws 'source-composition.json')
 $base=[string]@($composition.repositories|Where-Object{$_.repo_id-ceq'workflow'})[0].commit
 $head=Get-ReentryGitScalar $Tool @('rev-parse','HEAD')
 $paths=@(Invoke-ReentryGit $Tool @('diff','--name-only',$base,$head))
 $document=[ordered]@{schema='rusty.morphospace.workflow.validation_receipt.v1';receipt_id='owner-pass';project_id=$unit.project_id;unit_id='u002';created_at='2026-08-25T00:10:05Z';tier='quick';result='pass';repository_revisions=@([ordered]@{repo_id='workflow';base_revision=$base;head_revision=$head;branch=(Get-ReentryGitScalar $Tool @('symbolic-ref','--short','HEAD'))});changed_paths=@($paths|ForEach-Object{[ordered]@{repo_id='workflow';path=$_}});artifacts=$artifacts;criteria=$evidence.criteria;gates=$evidence.gates;device_validation=$null}
 Write-ReentryJson (Join-Path $ws 'local/owner-pass-proposed.json') $document
 $schemaErrors=@();$valid=Test-Json -Json ($document|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $repoRoot 'schemas/validation-receipt.schema.json') -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
 if(-not$valid){throw ('Actual publisher external ordinary v1 receipt failed schema:'+(($schemaErrors|ForEach-Object{$_.Exception.Message})-join' | '))}
 Write-ReentryJson (Join-Path $ws 'receipts/owner-pass.json') $document
 return 'receipts/owner-pass.json'
}
function New-ReentryExecutedValidation([string]$Base,[string]$BaseTree,[string]$Head,[string]$Tree,[string]$Out,[string]$Err,[string]$CommandPath='scripts/Test-FixturePublicationOwner.ps1'){
 return [ordered]@{schema='rusty.morphospace.workflow.affected_validation_evidence.v1';repository='MesmerPrism/rusty-morphospace-work-environment';base=[ordered]@{commit=$Base;tree=$BaseTree};head=[ordered]@{commit=$Head;tree=$Tree};plan_sha256=(Get-ReentryCanonicalHash ([pscustomobject]@{command=$CommandPath;head=$Head}));platform='windows';runner=[ordered]@{os_description='Isolated genuine owner publication fixture';powershell_version=$PSVersionTable.PSVersion.ToString()};check_results=@([ordered]@{check_id='fixture-source-integrity';command_path=$CommandPath;command_blob_sha1=(Get-ReentryGitScalar $script:fixtureTool @('rev-parse',($Head+':'+$CommandPath)));mode='executed';result='pass';started=$true;failure_kind=$null;exit_code=0;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout_sha256=(Get-ReentryRawHash $Out);stderr_sha256=(Get-ReentryRawHash $Err);stdout_bytes=([IO.FileInfo]$Out).Length;stderr_bytes=([IO.FileInfo]$Err).Length});result='pass';claims=[ordered]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}
}
function Test-ReentryLegacyPublication([string]$Root){
 Write-ReentryPhase 'legacy: exact old executor and current owner isolated snapshots'
 [IO.Directory]::CreateDirectory($Root)|Out-Null
 $base=Get-ReentryGitScalar $repoRoot @('rev-parse','HEAD')
 while(@(Invoke-ReentryGit $repoRoot @('ls-tree','--name-only',$base,'--','scripts/FrozenValidationReentry.psm1')).Count-gt0){$base=Get-ReentryGitScalar $repoRoot @('rev-parse',($base+'^1'))}
 $legacySource=if($LegacyExecutorRoot){[IO.Path]::GetFullPath($LegacyExecutorRoot)}else{$repoRoot}
 $legacyRevision=if($LegacyExecutorRevision){$LegacyExecutorRevision}elseif($LegacyExecutorRoot){'HEAD'}else{$base}
 $old=New-ReentryOwnerSnapshot $legacySource $legacyRevision (Join-Path $Root 'old-executor')
 Invoke-ReentryGit $old @('config','core.longpaths','true')|Out-Null
 $oldHead=Get-ReentryGitScalar $old @('rev-parse','HEAD');$oldTree=Get-ReentryGitScalar $old @('rev-parse','HEAD^{tree}');$oldClosure=@(Get-ReentryOwnerClosure $old)
 & git -C $repoRoot merge-base --is-ancestor $oldHead $base
 Assert-Reentry ($LASTEXITCODE-eq0) 'original executor must be an actual ancestor of the new fixture baseline'
 $bare=Join-Path $Root 'fixture-origin.git'
 Invoke-ReentryGit $repoRoot @('clone','--bare','--no-hardlinks',$repoRoot,$bare)|Out-Null
 Invoke-ReentryGit $bare @('update-ref','refs/heads/main',$base)|Out-Null
 Invoke-ReentryGit $bare @('symbolic-ref','HEAD','refs/heads/main')|Out-Null
 Invoke-ReentryGit $old @('remote','set-url','origin',$bare)|Out-Null
 $tool=New-ReentryOwnerSnapshot $repoRoot $base (Join-Path $Root 'published-executor')
 $script:fixtureTool=$tool
 Invoke-ReentryGit $tool @('config','core.longpaths','true')|Out-Null
 Invoke-ReentryGit $tool @('remote','set-url','origin',$bare)|Out-Null
 Invoke-ReentryGit $tool @('checkout','-b','fixture-owner-candidate')|Out-Null
 Invoke-ReentryGit $tool @('fetch','origin','main')|Out-Null
 Invoke-ReentryGit $tool @('branch','--set-upstream-to=origin/main')|Out-Null
 $changed=@('scripts/CandidateFreeze.psm1','scripts/FrozenValidationReentry.psm1','scripts/Invoke-FrozenValidationReentry.ps1','scripts/Test-FrozenValidationReentry.ps1','schemas/frozen-validation-reentry-v1.schema.json','manifests/affected-validation-registry.json','docs/WORKFLOW_STABILITY.md','docs/TOOLING_CONTEXT.md','scripts/Test-FixturePublicationOwner.ps1')
 # Every copy is from the actual selected working source and is committed in the isolated candidate.
 foreach($path in @($changed|Where-Object{$_-cne'scripts/Test-FixturePublicationOwner.ps1'})){Assert-Reentry (Test-Path -LiteralPath (Join-Path $repoRoot $path) -PathType Leaf) "fixture candidate source missing:$path"}
 $skills=Join-Path $Root 'routers'
 Invoke-ReentryChild (Join-Path $tool 'scripts/Install-LocalSkills.ps1') @('-RepoRoot',$tool,'-TargetRoot',$skills,'-Action','Install','-Execute') (Join-Path $Root 'install.stdout') (Join-Path $Root 'install.stderr') 120|Out-Null
 $fixture=New-ReentryPublisherBootstrap $Root $tool $skills $changed
 $ws=$fixture.workspace
 # Genuine initial source pin precedes candidate edits and every lifecycle event.
 Invoke-ReentryChild (Join-Path $tool 'scripts/New-SourceCompositionLock.ps1') @('-WorkspaceRoot',$ws,'-UnitId','u002','-RepositoryMapPath',$fixture.map,'-RepoId','workflow','-OutRelativePath','source-composition.json','-Execute') (Join-Path $Root 'lock.stdout') (Join-Path $Root 'lock.stderr') 120|Out-Null
 $unitPath=Join-Path $ws 'iteration-units/u002.json';$unit=Read-ReentryJson $unitPath
 $unit|Add-Member -NotePropertyName source_composition -NotePropertyValue ([ordered]@{mode='exact-lock';lock_path='source-composition.json';materialization_receipt=$null})
 Write-ReentryJson $unitPath $unit
 Invoke-ReentryGit $fixture.owner @('add','morphospace')|Out-Null;Invoke-ReentryGit $fixture.owner @('commit','-m','genuine initial fixture source pin')|Out-Null
 foreach($path in @($changed|Where-Object{$_-cne'scripts/Test-FixturePublicationOwner.ps1'})){$dest=Join-Path $tool $path;[IO.Directory]::CreateDirectory((Split-Path $dest -Parent))|Out-Null;[IO.File]::WriteAllBytes($dest,[IO.File]::ReadAllBytes((Join-Path $repoRoot $path)))}
 $fixtureChecker=@'
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$checks=0
foreach($path in @('scripts/CandidateFreeze.psm1','scripts/FrozenValidationReentry.psm1','scripts/Invoke-FrozenValidationReentry.ps1','scripts/Test-FrozenValidationReentry.ps1')){
 $tokens=$null;$errors=$null
 [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $path),[ref]$tokens,[ref]$errors)|Out-Null
 if($errors.Count-ne0){throw "Fixture owner script parse failed:$path"};$checks++
}
foreach($row in @(@{file='examples/hello-morphospace-v2/morphospace/project.spec.json';schema='schemas/project-spec-v2.schema.json'},@{file='examples/hello-morphospace-v2/morphospace/iteration-units/hello-001.json';schema='schemas/iteration-unit.schema.json'})){
 if(-not(Test-Json -Json ([IO.File]::ReadAllText((Join-Path $root $row.file))) -SchemaFile (Join-Path $root $row.schema))){throw 'Portable owner example schema failed.'};$checks++
}
[pscustomobject]@{result='pass';assertions=$checks;qualification='Fixture source integrity only; not repair acceptance.'}|ConvertTo-Json -Compress
'@
 [IO.File]::WriteAllText((Join-Path $tool 'scripts/Test-FixturePublicationOwner.ps1'),$fixtureChecker,[Text.UTF8Encoding]::new($false))
 Invoke-ReentryGit $tool (@('add','--')+$changed)|Out-Null;Invoke-ReentryGit $tool @('commit','-m','exact current frozen continuation fixture candidate')|Out-Null
 $head=Get-ReentryGitScalar $tool @('rev-parse','HEAD');$tree=Get-ReentryGitScalar $tool @('rev-parse','HEAD^{tree}')
 $actualChanged=@(Invoke-ReentryGit $tool @('diff','--name-only',$base,$head))
 Assert-Reentry (@($actualChanged|Where-Object{$_-cnotin$changed}).Count-eq0) 'fixture candidate changed an undeclared source path'
 Write-ReentryPhase 'legacy: genuine initial publisher Ready Claim instruction completion'
 foreach($action in @('Ready','Claim')){Invoke-ReentryOwnerAction @{Action=$action;WorkspaceRoot=$ws;UnitId='u002';RepoMapPath=$fixture.map;Execute=$true;Timestamp=if($action-ceq'Ready'){'2026-08-25T00:01:10Z'}else{'2026-08-25T00:01:20Z'}}|Out-Null}
 $instructions=Complete-ReentryInstructions $ws $fixture.map 'publisher-reviewed'
 $fixture|Add-Member -NotePropertyName instructions -NotePropertyValue $instructions
 Invoke-ReentryOwnerAction @{Action='BeginValidation';WorkspaceRoot=$ws;UnitId='u002';RepoMapPath=$fixture.map;Execute=$true;Timestamp='2026-08-25T00:10:00Z'}|Out-Null
 $out=Join-Path $ws 'receipts/owner-check.stdout';$err=Join-Path $ws 'receipts/owner-check.stderr'
 Write-ReentryPhase 'legacy: actual bounded published owner check'
 $check=Invoke-ReentryChild (Join-Path $tool 'scripts/Test-FixturePublicationOwner.ps1') @() $out $err 30
 Assert-Reentry ($check.exit_code-eq0) 'real publisher owner check failed'
 $receipt=New-ReentryPassingOwnerReceipt $fixture $tool $out $err
 Invoke-ReentryOwnerAction @{Action='RecordValidation';WorkspaceRoot=$ws;UnitId='u002';RepoMapPath=$fixture.map;ValidationTier='quick';ValidationResult='pass';ValidationReceipt=$receipt;Execute=$true;Timestamp='2026-08-25T00:10:10Z'}|Out-Null
 Invoke-ReentryOwnerAction @{Action='Accept';WorkspaceRoot=$ws;UnitId='u002';RepoMapPath=$fixture.map;ValidationTier='quick';Execute=$true;Timestamp='2026-08-25T00:10:20Z'}|Out-Null
 Assert-Reentry ((Read-ReentryJson $unitPath).status-ceq'accepted') 'publisher must be genuinely accepted'
 Invoke-ReentryGit $fixture.owner @('add','morphospace')|Out-Null;Invoke-ReentryGit $fixture.owner @('commit','-m','real accepted fixture publisher checkpoint')|Out-Null
 $publicationInputsModule=Import-Module (Join-Path $tool 'scripts/SourceOnlyPublicationInputs.psm1') -Force -PassThru
 $publicationModule=Import-Module (Join-Path $tool 'scripts/SourceOnlyPublication.psm1') -Force -PassThru
 Write-ReentryPhase 'legacy: real SourceOnly Prepare local bare push Record'
 $publication=Invoke-ReentryPublisherPublication $fixture $tool $Root
 $validation=New-ReentryExecutedValidation $base (Get-ReentryGitScalar $tool @('rev-parse',($base+'^{tree}'))) $head $tree $out $err
 Write-ReentryJson (Join-Path $ws 'local/actual-owner-validation.json') $validation
 Assert-ReentryOwnerUnchanged $old $oldHead $oldTree $oldClosure
 # The consumer portion must finish before this stage can ever report PASS.
 return Test-ReentryOldConsumer (Join-Path $Root 'old-consumer') $old $tool $bare $publication $fixture
}
function Test-ReentryBridgeCases([object]$Call,[object]$BaselineRequest,[object]$Bridge,[string]$Root,[string]$Workspace,[string]$SourceRepository){
 [IO.Directory]::CreateDirectory($Root)|Out-Null
 $baseline=Join-Path $Root 'pre-reentry-workspace';Copy-Item -LiteralPath $Workspace -Destination $baseline -Recurse -Force
 foreach($case in @('stale-cas','selector','closure-tamper','publication-tamper')){
  $ws=Join-Path $Root $case;Copy-Item -LiteralPath $baseline -Destination $ws -Recurse -Force
  $request=Copy-ReentryValue $BaselineRequest;$request.reentry_id="fixture-$case"
  $bridgeArguments=$Call.Clone();$bridgeArguments.WorkspaceRoot=$ws;$bridgeArguments.OutPath=Join-Path $ws "receipts/$($request.reentry_id)-frozen-validation-reentry.json"
  $path=Join-Path $Root "$case-request.json";$bridgeArguments.FrozenValidationReentry=$path
  $expect=''
  switch($case){
   'stale-cas'{$request.expected.state_sha256='0'*64;$expect='CAS|predecessor'}
   'selector'{$statePath=Join-Path $ws 'workspace.state.json';$state=Read-ReentryJson $statePath;$state|Add-Member -NotePropertyName normal_validation_selection -NotePropertyValue ([ordered]@{selection_id='unexpected-selector'}) -Force;Write-ReentryJson $statePath $state;$expect='selector'}
   'closure-tamper'{$request.executor.closure[0].sha256='0'*64;$expect='closure|bytes|hash|Frozen re-entry executor Git blob drifted:'}
   'publication-tamper'{$request.publication.execution.sha256='0'*64;$expect='execution|publication|bytes|hash'}
  }
  Write-ReentryJson $path $request
  Assert-ReentryReject {&$Bridge { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $bridgeArguments|Out-Null} $expect $ws $case
 }
 foreach($fault in @('after-intent','after-artifact','after-projection','after-event')){
  Write-ReentryPhase "legacy: original writer interruption recovery $fault"
  $ws=Join-Path $Root $fault;Copy-Item -LiteralPath $baseline -Destination $ws -Recurse -Force
  $request=Copy-ReentryValue $BaselineRequest;$request.reentry_id="fixture-$fault"
  $path=Join-Path $Root "$fault-request.json";Write-ReentryJson $path $request
  $bridgeArguments=$Call.Clone();$bridgeArguments.WorkspaceRoot=$ws;$bridgeArguments.FrozenValidationReentry=$path;$bridgeArguments.OutPath=Join-Path $ws "receipts/$($request.reentry_id)-frozen-validation-reentry.json";$bridgeArguments.ExpectedFrozenValidationReentrySha256=Get-ReentryRawHash $path;$bridgeArguments.Execute=$true;$bridgeArguments.FaultAfter=$fault
  $failure=$null;try{&$Bridge { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $bridgeArguments|Out-Null}catch{$failure=$_.Exception.Message}
  Assert-Reentry ($null-ne$failure-and$failure-match'fault|injected') "fault $fault did not stop at the real public transport boundary:$failure"
  $intent=Join-Path $ws "receipts/transactions/$($request.reentry_id)-frozen-validation-reentered-transition.intent.json"
  Assert-Reentry (Test-Path -LiteralPath $intent -PathType Leaf) 'interrupted bridge must retain the actual old writer intent'
  $bridgeArguments.FaultAfter='none';$bridgeArguments.Remove('Execute')
  $intentBytes=[IO.File]::ReadAllBytes($intent)
  try{
   $damaged=Read-ReentryJson $intent;$damaged.event.summary='Tampered pending bridge authority.'
   Write-ReentryJson $intent $damaged
   Assert-ReentryReject {&$Bridge { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $bridgeArguments|Out-Null} 'event|intent|semantic|authority' $ws "pending intent tamper $fault"
  }finally{[IO.File]::WriteAllBytes($intent,$intentBytes)}
  $audit=$bridgeArguments.OutPath
  if(Test-Path -LiteralPath $audit -PathType Leaf){
   $auditBytes=[IO.File]::ReadAllBytes($audit)
   try{
    [IO.File]::AppendAllText($audit,' ',[Text.UTF8Encoding]::new($false))
    Assert-ReentryReject {&$Bridge { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $bridgeArguments|Out-Null} 'artifact|audit|bytes|hash|owned' $ws "pending audit tamper $fault"
   }finally{[IO.File]::WriteAllBytes($audit,$auditBytes)}
  }
  $dry=&$Bridge { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $bridgeArguments
  Assert-Reentry (-not$dry.executed) 'recovery dry unexpectedly wrote'
  $bridgeArguments.Execute=$true;$recovered=&$Bridge { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $bridgeArguments
  Assert-Reentry ($recovered.executed-and(Read-ReentryJson (Join-Path $ws 'iteration-units/u002.json')).status-ceq'validating') 'old public Complete -Repair did not recover the genuine interruption'
  $eventsBefore=Get-ReentryRawHash (Join-Path $ws 'iteration-events.jsonl')
  &$Bridge { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $bridgeArguments|Out-Null
  Assert-Reentry ((Get-ReentryRawHash (Join-Path $ws 'iteration-events.jsonl'))-ceq$eventsBefore) 'completed recovery replay duplicated an event'
 }
 $sourceFile=Join-Path $SourceRepository 'morphospace/README.md';$original=[IO.File]::ReadAllBytes($sourceFile)
 try{[IO.File]::WriteAllText($sourceFile,'actual frozen product damage',[Text.UTF8Encoding]::new($false));Assert-ReentryReject {&$Bridge { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $Call|Out-Null} 'source|candidate|dirty|continuation' $Workspace 'frozen product source tamper'}finally{[IO.File]::WriteAllBytes($sourceFile,$original)}
}
function Test-ReentryOldConsumer([string]$Root,[string]$Old,[string]$Tool,[string]$Bare,[object]$Publication,[object]$Publisher){
 Write-ReentryPhase 'legacy: real old-context prepared consumer'
 $oldHead=Get-ReentryGitScalar $Old @('rev-parse','HEAD');$oldTree=Get-ReentryGitScalar $Old @('rev-parse','HEAD^{tree}')
 $oldSkills=Join-Path $Root 'old-routers';[IO.Directory]::CreateDirectory($Root)|Out-Null
 Invoke-ReentryChild (Join-Path $Old 'scripts/Install-LocalSkills.ps1') @('-RepoRoot',$Old,'-TargetRoot',$oldSkills,'-Action','Install','-Execute') (Join-Path $Root 'old-install.stdout') (Join-Path $Root 'old-install.stderr') 120|Out-Null
 $protocolModule=Import-Module (Join-Path $Old 'scripts/lib/MorphospaceProtocolCommon.psm1') -Force -PassThru
 $transitionLedgerModule=Import-Module (Join-Path $Old 'scripts/lib/MorphospaceTransitionLedger.psm1') -Force -PassThru
 $admissionModule=Import-Module (Join-Path $Old 'scripts/DevelopmentUnitAdmission.psm1') -Force -PassThru
 $automationModule=Import-Module (Join-Path $Old 'scripts/WorkUnitAutomation.psm1') -Force -PassThru
 $receiptModule=Import-Module (Join-Path $Old 'scripts/lib/MorphospaceValidationReceipt.psm1') -Force -PassThru
 $candidateModule=Import-Module (Join-Path $Old 'scripts/CandidateFreeze.psm1') -Force -PassThru
 $oldToolingModule=Import-Module (Join-Path $Old 'scripts/ToolingContextProvenance.psm1') -Force -PassThru
 . (Join-Path $Old 'scripts/test-support/DevelopmentAdmissionFixture.ps1')
 $consumerRoot=Join-Path $Root 'consumer';$ws=Join-Path $consumerRoot 'morphospace'
 foreach($d in @('receipts','local','tooling-contexts')){[IO.Directory]::CreateDirectory((Join-Path $ws $d))|Out-Null}
 $oldOut=Join-Path $ws 'receipts/old-check.stdout';$oldErr=Join-Path $ws 'receipts/old-check.stderr'
 Invoke-ReentryChild (Join-Path $Old 'scripts/Test-DocumentationLinks.ps1') @() $oldOut $oldErr 30|Out-Null
 $savedTool=$script:fixtureTool;try{$script:fixtureTool=$Old;$oldEvidence=New-ReentryExecutedValidation $oldHead $oldTree $oldHead $oldTree $oldOut $oldErr 'scripts/Test-DocumentationLinks.ps1'}finally{$script:fixtureTool=$savedTool}
 Write-ReentryJson (Join-Path $ws 'receipts/old-validation.json') $oldEvidence
 $oldValidation=[ordered]@{path='receipts/old-validation.json';sha256=(Get-ReentryRawHash (Join-Path $ws 'receipts/old-validation.json'))}
 $actions=@(&$oldToolingModule { param($parameters) Get-MorphospaceToolingContextAllowedActions @parameters } @{})
 $protocol=[ordered]@{protocol_id='tooling-context-v1';product_lock_schema='rusty.morphospace.workflow.development_envelope_source_composition.v3';repository_map_schema='rusty.morphospace.workflow.repository_map.v1';allowed_actions=$actions}
 Write-ReentryJson (Join-Path $ws 'receipts/old-observed-publication.json') ([ordered]@{schema='rusty.morphospace.workflow.tooling_context_publication_evidence.v1';publication_id='old-observed';executor=[ordered]@{repo_id='workflow-tooling';remote_url=$Bare;commit=$oldHead;tree=$oldTree};validation=$oldValidation;status='source-observed';does_not_prove=@('Does not independently prove remote publication authority.','Synthetic isolated historical context; not the actual GitHub owner authority. New bridge authority is the genuine accepted SourceOnly publisher.')})
 Write-ReentryJson (Join-Path $ws 'receipts/old-protocol.json') ([ordered]@{schema='rusty.morphospace.workflow.tooling_context_protocol_receipt.v1';receipt_id='old-protocol';executor=[ordered]@{repo_id='workflow-tooling';commit=$oldHead;tree=$oldTree};protocol=$protocol;validation=$oldValidation;status='compatible';does_not_prove=@('Does not authorize product changes.')})
 $routers=@();$resolverRouters=@()
 foreach($id in @('rusty-morphospace','system-engineering','rust-work-graph')){
  $routerRoot=Join-Path $oldSkills $id;$record=Read-ReentryJson (Join-Path $routerRoot '.morphospace-skill-source.json')
  Assert-Reentry (-not$record.source_worktree_dirty-and$record.source_commit-ceq$oldHead) 'old isolated router must bind the exact clean old executor'
  $managed=@($record.source_files|ForEach-Object{[ordered]@{path=([string]$_.path).Replace('\','/');sha256=$_.sha256}})
  foreach($row in $managed){Assert-Reentry ((Get-ReentryRawHash (Join-Path $routerRoot $row.path))-ceq$row.sha256) 'real installed router bytes match its source metadata'}
  $routers+=,[ordered]@{skill_id=$id;source_repo_id='workflow-tooling';commit=$oldHead;tree=$oldTree;source_fingerprint=$record.source_tree_sha256;managed_files=$managed}
  $resolverRouters+=,[ordered]@{skill_id=$id;root=$routerRoot}
 }
 Write-ReentryJson (Join-Path $ws 'local/old-context-resolver.json') ([ordered]@{schema='rusty.morphospace.workflow.tooling_context_resolver.v1';context_id='fixture-old-context';executor_root=$Old;routers=$resolverRouters;status='resolved';does_not_prove=@('Fixture local resolution only.')})
 foreach($pair in @(@('receipts/old-observed-publication.json','tooling-context-publication-evidence-v1.schema.json'),@('receipts/old-protocol.json','tooling-context-protocol-receipt-v1.schema.json'),@('receipts/old-validation.json','affected-validation-evidence-v1.schema.json'),@('local/old-context-resolver.json','tooling-context-resolver-v1.schema.json'))){Assert-ReentryFixtureSchema (Join-Path $ws $pair[0]) $Old $pair[1]}
 $descriptor=[ordered]@{context_id='fixture-old-context';path='tooling-contexts/fixture-old-context.json';resolver=[ordered]@{path='local/old-context-resolver.json';sha256=(Get-ReentryRawHash (Join-Path $ws 'local/old-context-resolver.json'))};executor=[ordered]@{repo_id='workflow-tooling';remote_url=$Bare;commit=$oldHead;tree=$oldTree;publication_evidence=[ordered]@{path='receipts/old-observed-publication.json';sha256=(Get-ReentryRawHash (Join-Path $ws 'receipts/old-observed-publication.json'))};entrypoint='scripts/ToolingContextUpgrade.psm1';closure=@(Get-ReentryOwnerClosure $Old)};routers=$routers;compatibility=[ordered]@{protocol_id='tooling-context-v1';product_lock_schema='rusty.morphospace.workflow.development_envelope_source_composition.v3';repository_map_schema='rusty.morphospace.workflow.repository_map.v1';allowed_actions=$actions;receipt=[ordered]@{path='receipts/old-protocol.json';sha256=(Get-ReentryRawHash (Join-Path $ws 'receipts/old-protocol.json'))}}}
 $seed=New-EnvelopeAdmissionPreparedFixture -Root $consumerRoot -RepositoryRoot $Old -TransitionLedgerModule $transitionLedgerModule -OwnerProducedPreparation -ToolingContextDescriptor ([pscustomobject]$descriptor)
 $admit=Join-Path $consumerRoot 'admission.json';Write-ReentryJson $admit $seed.admission_template
 &$admissionModule { param($parameters) Invoke-MorphospaceAdmitDevelopmentUnit @parameters } @{WorkspaceRoot=$ws;DevelopmentUnitAdmission=$admit;ExpectedDevelopmentUnitAdmissionSha256=(Get-ReentryRawHash $admit);OutPath=(Join-Path $ws 'receipts/u002-admission.json');Timestamp='2026-08-25T00:01:00.0000000Z';Execute=$true}|Out-Null
 foreach($action in @('Ready','Claim')){Invoke-ReentryOwnerAction @{Action=$action;WorkspaceRoot=$ws;UnitId='u002';Execute=$true;Timestamp=if($action-ceq'Ready'){'2026-08-25T00:01:10.0000000Z'}else{'2026-08-25T00:01:20.0000000Z'}}|Out-Null}
 [IO.File]::AppendAllText((Join-Path $seed.source_repository 'morphospace/README.md'),[char]10+'Genuine old-executor frozen fixture source.'+[char]10,[Text.UTF8Encoding]::new($false))
 Invoke-ReentryGit $seed.source_repository @('add','morphospace')|Out-Null;Invoke-ReentryGit $seed.source_repository @('commit','-m','real fixture scoped frozen source')|Out-Null
 $sourceHead=Get-ReentryGitScalar $seed.source_repository @('rev-parse','HEAD');$sourceTree=Get-ReentryGitScalar $seed.source_repository @('rev-parse','HEAD^{tree}')
 $freeze=New-ReentryFreezeRequest $ws $sourceHead $sourceTree;$freezePath=Join-Path $Root 'freeze.json';Write-ReentryJson $freezePath $freeze
 &$candidateModule { param($parameters) Invoke-MorphospaceFreezeCandidate @parameters } @{WorkspaceRoot=$ws;UnitId='u002';CandidateFreeze=$freezePath;ExpectedCandidateFreezeSha256=(Get-ReentryRawHash $freezePath);OutPath=(Join-Path $ws 'receipts/u002-reentry-freeze.json');Timestamp='2026-08-25T00:01:30.0000000Z';Execute=$true}|Out-Null
 Invoke-ReentryOwnerAction @{Action='BeginValidation';WorkspaceRoot=$ws;UnitId='u002';Execute=$true;Timestamp='2026-08-25T00:02:00.0000000Z'}|Out-Null
 $fail=New-ReentryReceipt $ws 'old-fail' 'fail' '2026-08-25T00:02:05.0000000Z'
 Invoke-ReentryOwnerAction @{Action='ReturnToActive';WorkspaceRoot=$ws;UnitId='u002';ValidationResult='fail';ValidationTier='quick';ValidationReceipt=$fail;Execute=$true;Timestamp='2026-08-25T00:02:10.0000000Z'}|Out-Null
 Assert-ReentryReject {Invoke-ReentryOwnerAction @{Action='BeginValidation';WorkspaceRoot=$ws;UnitId='u002'}|Out-Null} 'freeze|tail|candidate|ledger' $ws 'old executor cannot retry original freeze without published bridge'
 $frozen=Read-ReentryJson (Join-Path $ws 'receipts/u002-reentry-freeze.json');$oldUnit=Read-ReentryJson (Join-Path $ws 'iteration-units/u002.json');$oldContext=Copy-ReentryValue $oldUnit.tooling_context
 $sourceHash=Get-ReentryRawHash (Join-Path $ws 'source-composition.json');$contextHash=Get-ReentryRawHash (Join-Path $ws $oldContext.path);$freezeHash=Get-ReentryRawHash (Join-Path $ws 'receipts/u002-reentry-freeze.json')
 Write-ReentryJson (Join-Path $ws 'local/published-owner-resolver.json') ([ordered]@{schema='rusty.morphospace.workflow.frozen_validation_reentry_resolver.v1';owner_workspace=$Publication.owner_workspace;executor_root=$Tool})
 $state=Read-ReentryJson (Join-Path $ws 'workspace.state.json');$events=Join-Path $ws 'iteration-events.jsonl'
 $request=[ordered]@{schema='rusty.morphospace.workflow.frozen_validation_reentry.v1';reentry_id='old-fixture-reentry';project_id=$oldUnit.project_id;unit_id='u002';expected=[ordered]@{state_sha256=(Get-ReentryCanonicalHash $state);state_raw_sha256=(Get-ReentryRawHash (Join-Path $ws 'workspace.state.json'));unit_sha256=(Get-ReentryCanonicalHash $oldUnit);unit_raw_sha256=(Get-ReentryRawHash (Join-Path $ws 'iteration-units/u002.json'));events_sha256=(Get-ReentryRawHash $events);events_length=([IO.FileInfo]$events).Length;event_tail_id=$state.last_event_id};freeze=[ordered]@{freeze_id='u002-reentry-freeze';path='receipts/u002-reentry-freeze.json';sha256=$freezeHash};tooling_context=$oldContext;repository_map=[ordered]@{path='repository-map.json';sha256=(Get-ReentryRawHash (Join-Path $ws 'repository-map.json'))};executor=[ordered]@{repo_id='workflow-tooling';remote_url=$Bare;commit=(Get-ReentryGitScalar $Tool @('rev-parse','HEAD'));tree=(Get-ReentryGitScalar $Tool @('rev-parse','HEAD^{tree}'));entrypoint='scripts/FrozenValidationReentry.psm1';closure=@(Get-ReentryOwnerClosure $Tool)};validation=[ordered]@{path='local/actual-owner-validation.json';sha256=(Get-ReentryRawHash (Join-Path $Publication.owner_workspace 'local/actual-owner-validation.json'))};publication=[ordered]@{resolver=[ordered]@{path='local/published-owner-resolver.json';sha256=(Get-ReentryRawHash (Join-Path $ws 'local/published-owner-resolver.json'))};plan=$Publication.plan;execution=$Publication.execution;record_event_id=$Publication.record_event_id}}
 $bridgeModule=Import-Module (Join-Path $Tool 'scripts/FrozenValidationReentry.psm1') -Force -PassThru
 $requestPath=Join-Path $Root 'reentry-request.json';Write-ReentryJson $requestPath $request
 Assert-ReentryFixtureSchema (Join-Path $ws 'local/published-owner-resolver.json') $Tool 'frozen-validation-reentry-v1.schema.json'
 Assert-ReentryFixtureSchema $requestPath $Tool 'frozen-validation-reentry-v1.schema.json'
 $call=@{WorkspaceRoot=$ws;UnitId='u002';FrozenValidationReentry=$requestPath;OutPath=(Join-Path $ws 'receipts/old-fixture-reentry-frozen-validation-reentry.json');Timestamp=([datetime]::UtcNow.ToString('o'))}
 $backdated=$call.Clone();$backdated.Timestamp='2026-08-24T00:00:00.0000000Z'
 Assert-ReentryReject {&$bridgeModule { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $backdated|Out-Null} 'publication|predat|timestamp|chronolog' $ws 'reentry predates actual publication'
 Write-ReentryPhase 'legacy: strict published bridge dry CAS tamper and execute'
 $dry=&$bridgeModule { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $call
 Assert-Reentry (-not$dry.executed-and$dry.status_after-ceq'validating') 'bridge dry outcome differs'
 $bad=Copy-ReentryValue $request;$bad.expected.unit_sha256='0'*64;$badPath=Join-Path $Root 'stale-request.json';Write-ReentryJson $badPath $bad
 $badCall=$call.Clone();$badCall.FrozenValidationReentry=$badPath
 Assert-ReentryReject {&$bridgeModule { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $badCall|Out-Null} 'CAS|predecessor' $ws 'stale predecessor CAS'
 Test-ReentryBridgeCases $call ([pscustomobject]$request) $bridgeModule (Join-Path $Root 'bridge-cases') $ws $seed.source_repository
 $call.ExpectedFrozenValidationReentrySha256=Get-ReentryRawHash $requestPath;$call.Execute=$true
 $actual=&$bridgeModule { param($parameters) Invoke-MorphospaceFrozenValidationReentry @parameters } $call
 Assert-Reentry ($actual.executed-and$actual.status_after-ceq'validating') 'published bridge did not complete through old executor transport'
 Write-ReentryPhase 'legacy: actual original bound writer RecordPASS Accept'
 $pass=New-ReentryReceipt $ws 'old-pass' 'pass' ([datetime]::UtcNow.ToString('o'))
 Invoke-ReentryOwnerAction @{Action='RecordValidation';WorkspaceRoot=$ws;UnitId='u002';ValidationResult='pass';ValidationTier='quick';ValidationReceipt=$pass;Execute=$true;Timestamp=([datetime]::UtcNow.ToString('o'))}|Out-Null
 Invoke-ReentryOwnerAction @{Action='Accept';WorkspaceRoot=$ws;UnitId='u002';ValidationTier='quick';Execute=$true;Timestamp=([datetime]::UtcNow.ToString('o'))}|Out-Null
 Assert-Reentry ((Read-ReentryJson (Join-Path $ws 'iteration-units/u002.json')).status-ceq'accepted') 'actual original writer did not accept genuine fixture evidence'
 Assert-Reentry ((Get-ReentryRawHash (Join-Path $ws 'source-composition.json'))-ceq$sourceHash-and(Get-ReentryRawHash (Join-Path $ws $oldContext.path))-ceq$contextHash-and(Get-ReentryRawHash (Join-Path $ws 'receipts/u002-reentry-freeze.json'))-ceq$freezeHash) 'bridge or old writer changed immutable original authority bytes'
 return [pscustomobject]@{original_executor=$oldHead;published_executor=$request.executor.commit;original_freeze_sha256=$freezeHash;original_context_sha256=$contextHash;original_source_lock_sha256=$sourceHash;workspace=$ws}
}
function Test-ReentryExecutorPathContract([string]$Root){
 [IO.Directory]::CreateDirectory($Root)|Out-Null
 $executorContractModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceFrozenValidationReentryProof.psm1') -PassThru
 $schema=Read-ReentryJson (Join-Path $repoRoot 'schemas/frozen-validation-reentry-v1.schema.json')
 $zero='0'*64;$oid='a'*40;$file=[ordered]@{path='receipts/example.json';sha256=$zero}
 $document=[ordered]@{schema='rusty.morphospace.workflow.frozen_validation_reentry.v1';reentry_id='fixture-contract';project_id='fixture-project';unit_id='fixture-unit';expected=[ordered]@{state_sha256=$zero;state_raw_sha256=$zero;unit_sha256=$zero;unit_raw_sha256=$zero;events_sha256=$zero;events_length=1;event_tail_id='fixture-event'};freeze=[ordered]@{freeze_id='fixture-freeze';path=$file.path;sha256=$zero};tooling_context=[ordered]@{path='tooling-contexts/example.json';sha256=$zero;canonical_sha256=$zero;protocol_id='tooling-context-v1'};repository_map=$file;executor=[ordered]@{repo_id='fixture-source';remote_url='https://example.invalid/fixture';commit=$oid;tree=$oid;entrypoint='scripts/FrozenValidationReentry.psm1';closure=@()};validation=$file;publication=[ordered]@{resolver=$file;plan=$file;execution=$file;record_event_id='fixture-record'}}
 foreach($case in @('complete','missing-actor','missing-cli','missing-both')){
  $fixture=Join-Path $Root $case;[IO.Directory]::CreateDirectory((Join-Path $fixture 'scripts'))|Out-Null
  [IO.File]::WriteAllText((Join-Path $fixture 'README.md'),'Isolated executor path contract fixture; no lifecycle or publication authority.')
  if($case-notin@('missing-actor','missing-both')){[IO.File]::WriteAllText((Join-Path $fixture 'scripts/FrozenValidationReentry.psm1'),'# inert fixture actor')}
  if($case-notin@('missing-cli','missing-both')){[IO.File]::WriteAllText((Join-Path $fixture 'scripts/Invoke-FrozenValidationReentry.ps1'),'# inert fixture CLI')}
  Invoke-ReentryGit $fixture @('init','--quiet')|Out-Null
  Invoke-ReentryGit $fixture @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','add','.')|Out-Null
  Invoke-ReentryGit $fixture @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','Executor path contract fixture')|Out-Null
  $executor=Copy-ReentryValue $document.executor;$executor.commit=Get-ReentryGitScalar $fixture @('rev-parse','HEAD');$executor.tree=Get-ReentryGitScalar $fixture @('rev-parse','HEAD^{tree}');$executor.closure=@(Get-ReentryOwnerClosure $fixture)
  $document.executor=$executor
  $schemaPass=Test-Json -Json ($document|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $repoRoot 'schemas/frozen-validation-reentry-v1.schema.json') -ErrorAction SilentlyContinue
  Assert-Reentry ($schemaPass-eq($case-ceq'complete')) "executor request schema presence mismatch:$case"
  $before=@(Get-ReentryInventory $fixture);$failure=$null
  try{&$executorContractModule {param($fixtureRoot,$executorDescriptor) Assert-ReentryExecutorClosure -Root $fixtureRoot -Executor $executorDescriptor} $fixture $executor|Out-Null}catch{$failure=$_.Exception.Message}
  if($case-ceq'complete'){Assert-Reentry ($null-eq$failure) "private executor presence rejected valid complete tree:$failure"}else{Assert-Reentry ($failure-ceq'Frozen re-entry executor inventory or entrypoint is incomplete.') "private executor missing path rejection mismatch:$case/$failure"}
  Assert-ReentryNoWrite $before $fixture "private path contract $case"
 }
 foreach($damage in @('clause-count','duplicate-path','extra-shape','noncanonical-path')){
  $contract=Copy-ReentryValue $schema;$node=$contract.'$defs'.request.properties.executor.properties.closure
  switch($damage){
   'clause-count'{$node.allOf=@($node.allOf[0])}
   'duplicate-path'{$node.allOf[1].contains.properties.path.const=$node.allOf[0].contains.properties.path.const}
   'extra-shape'{$node.allOf[0].contains|Add-Member -NotePropertyName minProperties -NotePropertyValue 1}
   'noncanonical-path'{$node.allOf[0].contains.properties.path.const='scripts/../outside.ps1'}
  }
  $failure=$null;try{&$executorContractModule {param($contractDocument) Get-ReentryRequiredExecutorPaths $contractDocument} $contract|Out-Null}catch{$failure=$_.Exception.Message}
  Assert-Reentry ($null-ne$failure-and$failure-match'required executor path contract|relative path') "private required path contract failed to reject:$damage/$failure"
 }
 Write-ReentryPhase 'executor schema/private presence and malformed contract cases passed'
}

if($Stage-ne'shared'-and-not$IsWindows){throw 'The real legacy-publication stage requires Windows SourceOnly FileIdInfo. Invoke -Stage shared on Linux; combined -Stage all never silently omits bridge proof.'}

$runRoot=if($FixtureRoot){[IO.Path]::GetFullPath($FixtureRoot)}else{Join-Path ([IO.Path]::GetTempPath()) ('frozen-validation-reentry-'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $runRoot){throw "Refusing to overwrite fixture root: $runRoot"}
[IO.Directory]::CreateDirectory($runRoot)|Out-Null
try{
 Test-ReentryExecutorPathContract (Join-Path $runRoot 'executor-contract')
 if($Stage-ceq'legacy-publication'){$legacy=Test-ReentryLegacyPublication (Join-Path $runRoot 'legacy');[pscustomobject]@{result='pass';stage='legacy-publication';assertions=$assertions;elapsed_seconds=$testClock.Elapsed.TotalSeconds;fixture_root=$runRoot;legacy=$legacy;product_acceptance=$false;device_use=$false}|ConvertTo-Json -Depth 20 -Compress;return}
 $journey=Test-ReentrySharedJourney (Join-Path $runRoot 'neutral')
 $selfHostedJourney=Test-ReentrySharedJourney (Join-Path $runRoot 'self-hosted') -SelfHosted
 if($Stage-ceq'all'){$legacy=Test-ReentryLegacyPublication (Join-Path $runRoot 'legacy')}
 [pscustomobject]@{result='pass';stage=$Stage;assertions=$assertions;cycles=6;scenarios=@('neutral','self-hosted');elapsed_seconds=$testClock.Elapsed.TotalSeconds;fixture_root=$runRoot;original_freeze_sha256=$journey.freeze_hash;original_source_lock_sha256=$journey.source_hash;self_hosted_freeze_sha256=$selfHostedJourney.freeze_hash;self_hosted_source_lock_sha256=$selfHostedJourney.source_hash;product_acceptance=$false;device_use=$false}|ConvertTo-Json -Depth 20 -Compress
}catch{
 [Console]::Error.WriteLine("frozen_reentry_failed_fixture=$runRoot")
 [Console]::Error.WriteLine($_.ScriptStackTrace)
 throw
}
