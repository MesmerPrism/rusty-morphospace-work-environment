[CmdletBinding()]
param([switch]$SelfTest,[string]$RepositoryRoot=(Split-Path $PSScriptRoot -Parent),[string]$HarnessRoot='')
# Every positive receipt is produced by the public native constructor.
# Product/SDK/device leaves remain explicitly modeled and unused.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:phase='initialize';$script:refusals=0;$script:run=0;$script:clock=[Diagnostics.Stopwatch]::StartNew()
trap {[pscustomobject]@{result='fail';harness_root=$HarnessRoot;phase=$script:phase;seconds=$script:clock.Elapsed.TotalSeconds;native_calls=$script:run;no_write_refusals=$script:refusals;message=$_.Exception.Message;position=$_.InvocationInfo.PositionMessage;stack=$_.ScriptStackTrace;fixture_retained=$true}|ConvertTo-Json -Depth 6|Write-Host;throw $_}
$repoRoot=[IO.Path]::GetFullPath($RepositoryRoot)
$pwsh=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
$supersessionOwner=Import-Module (Join-Path $repoRoot 'scripts/ActiveUnitSupersession.psm1') -Force -PassThru
Import-Module (Join-Path $repoRoot 'scripts/lib/MorphospaceSourceCompositionIdentity.psm1') -Force
# Dependency owners force-reload common; restore caller bindings last.
Import-Module (Join-Path $repoRoot 'scripts/lib/MorphospaceProtocolCommon.psm1') -Force
if(-not$HarnessRoot){$HarnessRoot=Join-Path ([IO.Path]::GetTempPath()) ('bootstrap-receipt-'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $HarnessRoot){throw 'Bootstrap receipt harness must be fresh.'}
[void][IO.Directory]::CreateDirectory($HarnessRoot)
$script:run=0
Write-Host "Bootstrap receipt retained harness: $([IO.Path]::GetFullPath($HarnessRoot))"
function Phase-Bootstrap([string]$Name){$script:phase=$Name;Write-Host ("bootstrap-receipt phase={0} seconds={1:N3} native_calls={2} refusals={3}"-f$Name,$script:clock.Elapsed.TotalSeconds,$script:run,$script:refusals)}
function Assert-BootstrapTest([bool]$Value,[string]$Why){if(-not$Value){throw "Bootstrap receipt test: $Why"}}
function Read-BootstrapJson([string]$Path){Read-MorphospaceProtocolJson $Path}
function Copy-BootstrapValue($Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String}
function Write-BootstrapJson([string]$Path,$Value){[void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent));[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 100)+"`n",[Text.UTF8Encoding]::new($false))}
function Raw-Bootstrap([string]$Path){Get-MorphospaceFileSha256 $Path}
function Hash-Bootstrap($Value){Get-MorphospaceCanonicalJsonSha256 $Value}
function Git-Bootstrap([string]$Root,[string[]]$Arguments){$rows=@(&git --no-optional-locks -c core.longpaths=true -C $Root @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "Fixture Git failed: $($Arguments-join' ') $($rows-join' ')"};@($rows|ForEach-Object{[string]$_})}
function Run-BootstrapNative([string]$Script,[string[]]$Arguments){
 $script:run++;$output=@(&$pwsh -NoProfile -NonInteractive -File (Join-Path $repoRoot "scripts/$Script") @Arguments 2>&1);$exit=$LASTEXITCODE
 [IO.File]::WriteAllText((Join-Path $HarnessRoot ('native-'+$script:run.ToString('D3')+'.log')),($output-join"`n")+"`n",[Text.UTF8Encoding]::new($false))
 if($exit-ne0){throw "Public $Script exited${exit}: $($output-join"`n")"}
 return @($output|ForEach-Object{[string]$_})
}
function Read-BootstrapTerminal([string[]]$Lines){$text=$Lines-join"`n";$match=[regex]::Match($text,'(?m)^\{');if(-not$match.Success){throw 'Native public output has no JSON terminal.'};$text.Substring($match.Index)|ConvertFrom-Json -Depth 100 -DateKind String}
function Owner-Bootstrap($Fixture,[string]$Action,[string[]]$Extra=@()){
 Run-BootstrapNative 'Invoke-WorkUnitAutomation.ps1' (@('-Action',$Action,'-WorkspaceRoot',$Fixture.workspace,'-UnitId',$Fixture.unit_id,'-RepoMapPath',$Fixture.map)+$Extra)
}
function Inventory-Bootstrap([string]$Workspace){$rows=@(Get-ChildItem -LiteralPath $Workspace -Recurse -File|Sort-Object FullName|ForEach-Object{[ordered]@{path=[IO.Path]::GetRelativePath($Workspace,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=Raw-Bootstrap $_.FullName}});Hash-Bootstrap $rows}
function SourceFence-Bootstrap($Fixture){
 $roots=@($Fixture.root)+@((Read-BootstrapJson $Fixture.map).repositories.path);$observations=@(foreach($root in @($roots|Sort-Object -Unique)){
  $head=@(Git-Bootstrap $root @('rev-parse','HEAD'));$status=@(Git-Bootstrap $root @('status','--porcelain=v2','--branch','--untracked-files=all'));$indexRows=@(Git-Bootstrap $root @('ls-files','--stage'));$indexFlags=@(Git-Bootstrap $root @('ls-files','-v'));$files=@(Git-Bootstrap $root @('ls-files','--cached','--others','--exclude-standard'))
  $raw=@(foreach($relative in @($files|Sort-Object -Unique)){$full=Join-Path $root $relative;[pscustomobject]@{path=$relative;exists=[IO.File]::Exists($full);sha256=if([IO.File]::Exists($full)){Raw-Bootstrap $full}else{$null}}})
  $gitControl=@(foreach($relative in @('.git/HEAD','.git/config','.git/info/exclude')){$full=Join-Path $root $relative;[pscustomobject]@{path=$relative;sha256=Raw-Bootstrap $full}})
  [pscustomobject]@{root=$root;head=$head;status=$status;index=$indexRows;index_flags=$indexFlags;raw_files=$raw;git_control=$gitControl}
 });Hash-Bootstrap $observations
}
$refusalDomains=@{
 'same-canonical lock raw drift'='(?i)(?:Bootstrap\ validation\ source\ lock\ has\ no\ immutable\ native\ witness\.)'
 'recomputed lock fingerprint cannot replace committed native witness'='(?i)(?:Bootstrap\ validation\ source\ lock\ has\ no\ immutable\ native\ witness\.)'
 'missing native source lock'='(?i)(?:Validation\ receipt\ authority\ file\ does\ not\ exist:\ bootstrap\-locks/)'
 'map semantic role substitution'='(?i)(?:Bootstrap\ validation\ repository\ map\ role\ differs\ from\ source\ lock\.|Bootstrap\ validation\ supersession\ repository\ map\ is\ detached\.)'
 'spoofed current unit outside native projection'='(?i)(?:Transition\ ledger\ tail\ completion\ does\ not\ own\ its\ target\ unit\ projection\.|Bootstrap\ validation\ current\ unit\ differs\ from\ its\ native\ origin\.)'
 'live lock schema plus stripped reserved artifacts cannot downgrade'='(?i)(?:Bootstrap\ validation\ document\ is\ malformed:\ source\-composition\-lock\.schema\.json|The\ JSON\ is\ not\ valid\ with\ the\ schema)'
 'fake Freeze plus stripped reserved artifacts cannot downgrade'='(?i)(?:Transition\ ledger\ tail\ completion\ does\ not\ own\ its\ target\ unit\ projection\.|Validation\ receipt\ current\ unit/state\ differs\ from\ its\ committed\ native\ target\.)'
 'removed source binding plus stripped reserved artifacts cannot downgrade'='(?i)(?:Transition\ ledger\ tail\ completion\ does\ not\ own\ its\ target\ unit\ projection\.|Validation\ receipt\ current\ unit/state\ differs\ from\ its\ committed\ native\ target\.)'
 'retained source origin survives missing tail plus removed live binding'='Validation\ receipt\ source\-owning\ origin\ requires\ its\ committed\ native\ tail\.'
 'native tail source deletion plus removed live binding remains authenticated'='Transition\ ledger\ intent\ unit\ hashes\ are\ invalid\ or\ inconsistent\.'
 'missing native Ready history'='(?i)(?:Bootstrap\ validation\ origin\ transition\ is\ damaged:\ event\ order\.|Bootstrap\ validation\ requires\ authenticated\ native\ Ready\ and\ Claim\.)'
 'native Begin completion semantic damage'='(?i)(?:Transition\ ledger\ completion\ is\ not\ canonically\ bound\ to\ its\ exact\ intent\.)'
 'native Begin intent raw drift'='(?i)(?:Transition\ ledger\ completion\ is\ not\ canonically\ bound\ to\ its\ exact\ intent\.)'
 'caller cannot occupy reserved native artifact ID'='(?i)(?:Bootstrap\ validation\ reserved\ artifact\ ID\ is\ caller\ supplied\.)'
 'map raw drift after native receipt generation'='(?i)(?:Bootstrap\ validation\ reserved\ artifact\ binding\ is\ missing\ or\ detached\.|Bootstrap\ validation\ supersession\ repository\ map\ is\ detached\.)'
 'same-delta wrong ancestor receipt base'='(?i)(?:Bootstrap\ validation\ repository\ base\ differs\ from\ exact\ source\ lock\.)'
 'receipt source head drift'='(?i)(?:Validation\ receipt\ does\ not\ match\ current\ HEAD/branch)'
 'missing native owner receipt artifacts'='(?i)(?:Bootstrap\ validation\ reserved\ artifact\ binding\ is\ missing\ or\ detached\.)'
 'artifact drift between genuine Record and Accept'='(?i)(?:Validation\ artifact\ hash\ mismatch)'
 'missing consumed receipt before Accept'='(?i)(?:Workspace\ artifact\ is\ missing:|Validation\ receipt\ does\ not\ exist:|Required\ JSON\ file\ is\ missing:).*retained-validation\.json'
 'consumed receipt raw drift before Accept'='(?i)(?:Transition\ ledger\ committed\ artifact\ differs\ from\ its\ intent:)'
 'accepted current/project reader receipt raw drift'='(?i)(?:Transition\ ledger\ committed\ artifact\ differs\ from\ its\ intent:)'
 'genuine earlier acceptance excludes bootstrap exception'='(?i)(?:Bootstrap\ validation\ requires\ an\ initial\ owner\ without\ an\ accepted\ predecessor\.)'
 'genuine admitted unit still requires Freeze'='(?i)(?:Bootstrap\ validation\ excludes\ admitted,\ frozen\ or\ tooling\-context\ units\.)'
 'ordinary Freeze raw lock fence remains strict'='(?i)(?:Validation\ receipt\ source\-composition\ lock\ does\ not\ match\ the\ candidate\-freeze\ binding\.)'
}
function Refuse-Bootstrap($Fixture,[scriptblock]$Action,[string]$Why){
 Assert-BootstrapTest ($refusalDomains.ContainsKey($Why)) "No owning error domain declared for $Why"
 $before=Inventory-Bootstrap $Fixture.workspace;$sourceBefore=SourceFence-Bootstrap $Fixture;$errorRecord=$null
 try{&$Action|Out-Null}catch{$errorRecord=$_}
 $message=if($null-ne$errorRecord){$errorRecord.Exception.Message}else{'NO REFUSAL'}
 # Strip only lowercase-m SGR presentation; preserve raw errors and exact guard domains.
 $normalizedMessage=(($message-creplace'\x1b\[[0-9;]*m','')-replace'\s+',' ').Trim()
 Assert-BootstrapTest ($null-ne$errorRecord-and$normalizedMessage-match$refusalDomains[$Why]) "$Why did not refuse at its expected owning guard: $message"
 Assert-BootstrapTest ((Inventory-Bootstrap $Fixture.workspace)-ceq$before-and(SourceFence-Bootstrap $Fixture)-ceq$sourceBefore) "$Why wrote owner/source bytes, Git state or staged index"
 [pscustomobject]@{case=$Why;message=$errorRecord.Exception.Message;fully_qualified_error_id=$errorRecord.FullyQualifiedErrorId;position=$errorRecord.InvocationInfo.PositionMessage;stack=$errorRecord.ScriptStackTrace;owner_unchanged=$true}|ConvertTo-Json -Depth 5|Write-Host
 $script:refusals++
}
function Damage-BootstrapFile($Fixture,[string]$Path,[scriptblock]$Damage,[scriptblock]$Probe,[string]$Why){$bytes=[IO.File]::ReadAllBytes($Path);try{&$Damage $Path;Refuse-Bootstrap $Fixture $Probe $Why}finally{[IO.File]::WriteAllBytes($Path,$bytes)}}
function Damage-BootstrapFiles($Fixture,[string[]]$Paths,[scriptblock]$Damage,[scriptblock]$Probe,[string]$Why){
 $original=@{};$damaged=@{}
 foreach($p in $Paths){$original[$p]=[IO.File]::ReadAllBytes($p)}
 try{&$Damage;foreach($p in $Paths){$damaged[$p]=Raw-Bootstrap $p};Refuse-Bootstrap $Fixture $Probe $Why}
 finally{foreach($p in $Paths){if($damaged.ContainsKey($p)-and[IO.File]::Exists($p)-and(Raw-Bootstrap $p)-cne$damaged[$p]){Write-Host "Preserved unexpected native modification at $p";continue};[IO.File]::WriteAllBytes($p,$original[$p])}}
}
function Strip-BootstrapReservedArtifacts([string]$Path){
 $r=Read-BootstrapJson $Path;$r.artifacts=@($r.artifacts|Where-Object{$_.artifact_id-cnotin@('bootstrap-source-lock','bootstrap-repository-map','bootstrap-begin-intent')});Write-BootstrapJson $Path $r
}
function Commit-BootstrapControls($Fixture,[string]$Stage){
 # Checkpoint actual owner bytes only; never change native projections by hand.
 Git-Bootstrap $Fixture.root @('add','--','morphospace/')|Out-Null
 $staged=@(Git-Bootstrap $Fixture.root @('diff','--cached','--name-only','--'))
 Assert-BootstrapTest ($staged.Count-gt0-and@($staged|Where-Object{-not$_.StartsWith('morphospace/',[StringComparison]::Ordinal)}).Count-eq0) "Native $Stage checkpoint must stage only genuine workspace controls"
 Git-Bootstrap $Fixture.root @('commit','--quiet','-m',"native-control-$Stage")|Out-Null
 Assert-BootstrapTest (@(Git-Bootstrap $Fixture.root @('status','--porcelain=v1','--untracked-files=all')).Count-eq0) "Native $Stage planning checkpoint is not clean"
}
function New-BootstrapUnit([string]$ProjectId,[string]$UnitId){
 $u=Read-BootstrapJson (Join-Path $repoRoot 'examples/hello-morphospace-v2/morphospace/iteration-units/hello-001.json')
 $u.project_id=$ProjectId;$u.unit_id=$UnitId;$u.objective='Exercise a real initial native workflow receipt without product or device authority.';$u.tags=@('host-conformance')
 $u.allowed_repositories=@([pscustomobject]@{repo_id='project-shell';allowed_paths=@('morphospace/','AGENTS.md')},[pscustomobject]@{repo_id='product-source';allowed_paths=@('docs/input.txt')})
 $u.instruction_impact='review';$u.instruction_surfaces=@([pscustomobject]@{surface_kind='agents';path='<project-root>/AGENTS.md';owner='project-shell';change_reason='Retain inert host-fixture guidance.';action='review-no-change';status='planned';validation='Native exact-byte instruction observation.';skill_id=$null});$u.instruction_none_justification=$null
 $u.acceptance=@([pscustomobject]@{acceptance_id='neutral-host';proof='Real neutral input content and exact native workflow bindings.';command='neutral-bootstrap-host-check'})
 $u.validation=@([pscustomobject]@{profile_id='workflow';command='neutral-bootstrap-host-check'});$u.prerequisites=@();$u.device_requirement='none';$u.risk_tier='quick'
 $u|Add-Member -NotePropertyName source_composition -NotePropertyValue ([pscustomobject]@{mode='exact-lock';lock_path="bootstrap-locks/$UnitId.json";materialization_receipt=$null}) -Force
 return $u
}
function New-BootstrapFixture([string]$Name,[switch]$Supersede){
 $container=Join-Path $HarnessRoot $Name;$root=Join-Path $container 'planning';$product=Join-Path $container 'product'
 foreach($r in @($root,$product)){[void][IO.Directory]::CreateDirectory($r);Git-Bootstrap $r @('init','--quiet')|Out-Null;Git-Bootstrap $r @('config','user.name','Bootstrap fixture')|Out-Null;Git-Bootstrap $r @('config','user.email','bootstrap@example.invalid')|Out-Null;Git-Bootstrap $r @('config','commit.gpgsign','false')|Out-Null;Git-Bootstrap $r @('config','core.autocrlf','false')|Out-Null;Git-Bootstrap $r @('config','core.longpaths','true')|Out-Null}
 [void][IO.Directory]::CreateDirectory((Join-Path $product 'docs'));[IO.File]::WriteAllText((Join-Path $product 'docs/input.txt'),"neutral seed`n",[Text.UTF8Encoding]::new($false));Git-Bootstrap $product @('add','docs/input.txt')|Out-Null;Git-Bootstrap $product @('commit','--quiet','-m','product-locked-base')|Out-Null;$productBase=(@(Git-Bootstrap $product @('rev-parse','HEAD'))-join'')
 [IO.File]::WriteAllText((Join-Path $root 'AGENTS.md'),"# Neutral fixture`nNo product or device effects.`n",[Text.UTF8Encoding]::new($false))
 Run-BootstrapNative 'New-ProjectWorkspace.ps1' @('-ProjectRoot',$root,'-ProjectId',"bootstrap-$Name",'-Purpose','Neutral native bootstrap receipt conformance.','-Execute')|Out-Null
 if($Supersede){[IO.File]::WriteAllText((Join-Path $root '.gitignore'),"/morphospace/receipts/$Name-supersession-request.json`n",[Text.UTF8Encoding]::new($false))}
 $ws=Join-Path $root 'morphospace';$spec=Read-BootstrapJson (Join-Path $ws 'project.spec.json');$spec.repositories=@([pscustomobject]@{repo_id='project-shell';role='application';path=$root;allowed_paths=@('morphospace/','AGENTS.md')},[pscustomobject]@{repo_id='product-source';role='application';path=$product;allowed_paths=@('docs/input.txt')});$spec.validation_profiles=@([pscustomobject]@{profile_id='workflow';commands=@('neutral-bootstrap-host-check')});Write-BootstrapJson (Join-Path $ws 'project.spec.json') $spec
 $map=Join-Path $ws 'repository-map.json';Write-BootstrapJson $map ([pscustomobject]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([pscustomobject]@{repo_id='project-shell';path=$root;role='planning';aliases=@('project-root')},[pscustomobject]@{repo_id='product-source';path=$product;role='source';aliases=@()})})
 $ids=if($Supersede){@('bootstrap-001','bootstrap-002')}else{@('bootstrap-001')}
 # All authored proposed declarations precede the initial source checkpoint.
 # No owner output/receipt is ignored: the producer's planned output row
 # must equal the consumer's real planning changed-path observation.
 foreach($id in $ids){Write-BootstrapJson (Join-Path $ws "iteration-units/$id.json") (New-BootstrapUnit $spec.project_id $id)}
 Git-Bootstrap $root @('add','.')|Out-Null;Git-Bootstrap $root @('commit','--quiet','-m','native-initial-project-map-proposals')|Out-Null
 foreach($id in $ids){Run-BootstrapNative 'New-SourceCompositionLock.ps1' @('-WorkspaceRoot',$ws,'-UnitId',$id,'-RepositoryMapPath',$map,'-OutRelativePath',"bootstrap-locks/$id.json",'-Execute')|Out-Null;Git-Bootstrap $root @('add',"morphospace/bootstrap-locks/$id.json")|Out-Null;Git-Bootstrap $root @('commit','--quiet','-m',"bind-native-lock-$id")|Out-Null}
 $f=[pscustomobject]@{root=$root;product=$product;workspace=$ws;map=$map;unit_id='bootstrap-001';project_id=$spec.project_id;locked_base=$productBase;witness_head='';planning_witness=(@(Git-Bootstrap $root @('rev-parse','HEAD'))-join'')}
 Owner-Bootstrap $f Ready @('-Execute')|Out-Null;Commit-BootstrapControls $f "$($f.unit_id)-ready";Owner-Bootstrap $f Claim @('-Execute')|Out-Null;Commit-BootstrapControls $f "$($f.unit_id)-claim"
 if($Supersede){
  $request=&$supersessionOwner {
   param($w,$m,$projectIdentity)
   $old=Get-ActiveSupersessionUnitBinding $w bootstrap-001;$next=Get-ActiveSupersessionUnitBinding $w bootstrap-002;$events=Get-ActiveSupersessionEventsSnapshot (Join-Path $w 'iteration-events.jsonl');$map=Get-ActiveSupersessionRepositoryMap $m
   $owners=@([pscustomobject]@{unit_id='bootstrap-002';role='replacement';document=$next.document;binding=$next});$rows=Get-ActiveSupersessionRepositoryObservation $old.document $owners $map.map
   [pscustomobject]@{schema='rusty.morphospace.workflow.active_unit_supersession.v1';supersession_id='bootstrap-001-superseded-by-bootstrap-002';project_id=$projectIdentity;old_unit=[pscustomobject]@{unit_id='bootstrap-001';path=$old.path;raw_sha256=$old.raw_sha256;canonical_sha256=$old.canonical_sha256;status='active'};replacement_unit=[pscustomobject]@{unit_id='bootstrap-002';path=$next.path;raw_sha256=$next.raw_sha256;canonical_sha256=$next.canonical_sha256;status='proposed'};companion_units=@();expected=[pscustomobject]@{project_raw_sha256=Get-MorphospaceFileSha256 (Join-Path $w 'project.spec.json');project_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Join-Path $w 'project.spec.json'));state_raw_sha256=Get-MorphospaceFileSha256 (Join-Path $w 'workspace.state.json');state_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Join-Path $w 'workspace.state.json'));events_sha256=$events.sha256;events_length=$events.length;event_tail_id=$events.tail_id;repository_map_sha256=Get-MorphospaceFileSha256 $m};repositories=@($rows);does_not_authorize=@('No product, device or publication authority.')}
  } $ws $map $spec.project_id
  $r=Join-Path $ws "receipts/$Name-supersession-request.json";Write-BootstrapJson $r $request;$f.unit_id='bootstrap-002';Owner-Bootstrap $f SupersedeActive @('-ActiveUnitSupersession',$r,'-ExpectedActiveUnitSupersessionSha256',(Raw-Bootstrap $r),'-OutPath',(Join-Path $ws 'receipts/supersession.json'),'-Execute')|Out-Null;Commit-BootstrapControls $f 'bootstrap-002-superseded'
 }
 Git-Bootstrap $product @('commit','--quiet','--allow-empty','-m','distinct-same-tree-product-ancestor')|Out-Null;$f.witness_head=(@(Git-Bootstrap $product @('rev-parse','HEAD'))-join'')
 [IO.File]::WriteAllText((Join-Path $product 'docs/input.txt'),"neutral candidate`n",[Text.UTF8Encoding]::new($false));Git-Bootstrap $product @('add','docs/input.txt')|Out-Null;Git-Bootstrap $product @('commit','--quiet','-m','neutral-product-source-advance')|Out-Null
 return $f
}
function Complete-BootstrapInstructions($f){
 $id="$($f.unit_id)-instructions";$plan=Read-BootstrapTerminal (Owner-Bootstrap $f CompleteInstructionSurfaces @('-InstructionCompletionId',$id));$c=$plan.instruction_surface_completion
 $completionArguments=@('-InstructionCompletionId',$id,'-ExpectedUnitSha256',[string]$c.expected_unit_sha256,'-ExpectedInstructionObservationSha256',[string]$c.observation_sha256,'-OutPath',(Join-Path $f.workspace "receipts/$id.json"),'-InstructionSurfaceIds')+@($c.surfaces.surface_id)+@('-Execute');Owner-Bootstrap $f CompleteInstructionSurfaces $completionArguments|Out-Null;Commit-BootstrapControls $f "$($f.unit_id)-instructions"
}
function New-BootstrapEvidence($f,$Begin,[string]$Suffix){
 # This is a real neutral assertion, not a fabricated validation receipt or
 # an invocation of modeled product/SDK/device commands.
 $expected=if($null-ne$f.PSObject.Properties['expected_payload']){$f.expected_payload}else{"neutral candidate`n"};$value=[IO.File]::ReadAllText((Join-Path $f.product 'docs/input.txt'));Assert-BootstrapTest ($value-ceq$expected) 'neutral source payload assertion failed'
 $u=Read-BootstrapJson (Join-Path $f.workspace "iteration-units/$($f.unit_id).json");$log=Join-Path $HarnessRoot "$Suffix-neutral-result.json";Write-BootstrapJson $log ([pscustomobject]@{result='pass';check='actual-neutral-content-equality';input_sha256=Raw-Bootstrap (Join-Path $f.product 'docs/input.txt');product_sdk_device_leaves='modeled/unused; no acceptance credit';device_calls=0})
 $e=[pscustomobject]@{receipt_id="$($f.unit_id)-$Suffix";tier='quick';result='pass';artifacts=@([pscustomobject]@{artifact_id='neutral';kind='test-log';path=$log});criteria=@($u.acceptance|ForEach-Object{[pscustomobject]@{acceptance_id=$_.acceptance_id;status='pass';command=$_.command;evidence_refs=@('neutral')}});gates=@($Begin.validation_matrix|Where-Object disposition -CNE forbidden|ForEach-Object{[pscustomobject]@{gate_id=$_.gate_id;status='pass';command=$_.command;evidence_refs=@('neutral')}});device_validation=$null}
 $path=Join-Path $HarnessRoot "$Suffix-evidence.json";Write-BootstrapJson $path $e;return $path
}
function Make-BootstrapReceipt($f,[string]$Evidence,[string]$Name){Run-BootstrapNative 'New-ValidationReceipt.ps1' @('-WorkspaceRoot',$f.workspace,'-UnitId',$f.unit_id,'-RepoMapPath',$f.map,'-EvidencePath',$Evidence,'-OutPath',"receipts/$Name.json")|Out-Null;Join-Path $f.workspace "receipts/$Name.json"}
function Read-BootstrapConsumers($f){Run-BootstrapNative 'Test-WorkflowContracts.ps1' @('-RepoRoot',$repoRoot,'-WorkspaceRoot',$f.workspace,'-RepositoryMapPath',$f.map,'-CurrentWorkspaceOnly','-CurrentWorkOnly','-SkipOwnerSelfTests')|Out-Null;Run-BootstrapNative 'Test-WorkflowContracts.ps1' @('-RepoRoot',$repoRoot,'-WorkspaceRoot',$f.workspace,'-RepositoryMapPath',$f.map,'-SkipOwnerSelfTests')|Out-Null}
function Test-BootstrapJourney($f,[string]$Name){
 Phase-Bootstrap "$Name-before-instructions-begin"
 Complete-BootstrapInstructions $f;$begin=Read-BootstrapTerminal (Owner-Bootstrap $f BeginValidation @('-ValidationTier','quick','-OutPath',(Join-Path $f.workspace 'receipts/begin.json'),'-Execute'));$e=New-BootstrapEvidence $f $begin $Name
 # Baseline RED must be this real public call's old candidate-freeze refusal.
 $path=Make-BootstrapReceipt $f $e "$Name-pass";$receipt=Read-BootstrapJson $path;Assert-BootstrapTest (@($receipt.repository_revisions|Where-Object repo_id -CEQ 'product-source')[0].base_revision-ceq$f.locked_base) 'producer selected upstream/current/witness instead of exact locked base'
 foreach($reserved in @('bootstrap-source-lock','bootstrap-repository-map','bootstrap-begin-intent')){Assert-BootstrapTest (@($receipt.artifacts|Where-Object artifact_id -CEQ $reserved).Count-eq1) "Missing/duplicate native artifact $reserved"}
 $lock=Join-Path $f.workspace "bootstrap-locks/$($f.unit_id).json";$unitPath=Join-Path $f.workspace "iteration-units/$($f.unit_id).json";$events=Join-Path $f.workspace 'iteration-events.jsonl'
 Damage-BootstrapFile $f $lock {param($p)[IO.File]::AppendAllText($p,' ')} {Make-BootstrapReceipt $f $e 'bad-lock-raw'} 'same-canonical lock raw drift'
 Damage-BootstrapFile $f $lock {param($p)$l=Read-BootstrapJson $p;$row=@($l.repositories|Where-Object repo_id -CEQ 'product-source')[0];$row.commit=$f.witness_head;$row.tree=(@(Git-Bootstrap $f.product @('rev-parse',"$($f.witness_head)^{tree}"))-join'');$l.fingerprint=Get-MorphospaceSourceCompositionFingerprint -ProjectId $f.project_id -UnitId $f.unit_id -Repositories $l.repositories;$l.lock_id="$($f.unit_id)-source-$(([string]$l.fingerprint).Substring(0,12))";Write-BootstrapJson $p $l} {Make-BootstrapReceipt $f $e 'bad-lock-semantic'} 'recomputed lock fingerprint cannot replace committed native witness'
 Damage-BootstrapFile $f $lock {param($p)[IO.File]::Delete($p)} {Make-BootstrapReceipt $f $e 'missing-lock'} 'missing native source lock'
 Damage-BootstrapFile $f $f.map {param($p)$m=Read-BootstrapJson $p;@($m.repositories|Where-Object repo_id -CEQ 'product-source')[0].role='planning';Write-BootstrapJson $p $m} {Make-BootstrapReceipt $f $e 'spoofed-map-role'} 'map semantic role substitution'
 Damage-BootstrapFile $f $unitPath {param($p)$u=Read-BootstrapJson $p;$u.objective+=' spoofed';Write-BootstrapJson $p $u} {Make-BootstrapReceipt $f $e 'bad-unit'} 'spoofed current unit outside native projection'
 Damage-BootstrapFile $f $events {param($p)$lines=[IO.File]::ReadAllLines($p);[IO.File]::WriteAllText($p,($lines[1..($lines.Length-1)]-join"`n")+"`n")} {Make-BootstrapReceipt $f $e 'bad-history'} 'missing native Ready history'
 $beginCompletion=Join-Path $f.workspace "receipts/transactions/$($begin.event_id)-transition.completion.json";Damage-BootstrapFile $f $beginCompletion {param($p)$c=Read-BootstrapJson $p;$c.unit_sha256='0'*64;Write-BootstrapJson $p $c} {Make-BootstrapReceipt $f $e 'bad-begin-completion'} 'native Begin completion semantic damage'
 $beginIntent=Join-Path $f.workspace "receipts/transactions/$($begin.event_id)-transition.intent.json";Damage-BootstrapFile $f $beginIntent {param($p)[IO.File]::AppendAllText($p,' ')} {Make-BootstrapReceipt $f $e 'bad-begin-intent'} 'native Begin intent raw drift'
 $collision=Copy-BootstrapValue (Read-BootstrapJson $e);$collision.artifacts[0].artifact_id='bootstrap-source-lock';foreach($row in @($collision.criteria)+@($collision.gates)){$row.evidence_refs=@('bootstrap-source-lock')};$collisionPath=Join-Path $HarnessRoot "$Name-collision.json";Write-BootstrapJson $collisionPath $collision;Refuse-Bootstrap $f {Make-BootstrapReceipt $f $collisionPath 'reserved-collision'} 'caller cannot occupy reserved native artifact ID'
 Read-BootstrapConsumers $f
 # Native v1 Ready/Claim did not bind historical map raw bytes. The generated
 # receipt DOES bind generation→Record→Accept raw bytes through its artifact.
 Damage-BootstrapFile $f $f.map {param($p)[IO.File]::AppendAllText($p,' ')} {Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute')} 'map raw drift after native receipt generation'
 # Witness commit is still an ancestor, with the SAME allowed source delta.
 # The consumer must compare base to lock, not merely test ancestry.
 $allowed=@('docs/input.txt');$lockedDelta=@(Git-Bootstrap $f.product @('diff','--name-only',"$($f.locked_base)..HEAD",'--')|Where-Object{$_-cin$allowed});$witnessDelta=@(Git-Bootstrap $f.product @('diff','--name-only',"$($f.witness_head)..HEAD",'--')|Where-Object{$_-cin$allowed});Git-Bootstrap $f.product @('merge-base','--is-ancestor',$f.witness_head,'HEAD')|Out-Null;Assert-BootstrapTest (($lockedDelta-join'|')-ceq($witnessDelta-join'|')-and$f.witness_head-cne$f.locked_base) 'wrong-base negative must retain the same real allowed source delta and a distinct ancestor'
 Damage-BootstrapFile $f $path {param($p)$r=Read-BootstrapJson $p;@($r.repository_revisions|Where-Object repo_id -CEQ 'product-source')[0].base_revision=$f.witness_head;Write-BootstrapJson $p $r} {Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute')} 'same-delta wrong ancestor receipt base'
 Damage-BootstrapFile $f $path {param($p)$r=Read-BootstrapJson $p;@($r.repository_revisions|Where-Object repo_id -CEQ 'product-source')[0].head_revision='0'*40;Write-BootstrapJson $p $r} {Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute')} 'receipt source head drift'
 Damage-BootstrapFile $f $path {param($p)$r=Read-BootstrapJson $p;$r.artifacts=@($r.artifacts|Where-Object artifact_id -CEQ neutral);Write-BootstrapJson $p $r} {Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute')} 'missing native owner receipt artifacts'
 # Dispatcher authority comes from committed native target, never these mutable classifiers.
 Damage-BootstrapFiles $f @($lock,$path) {$l=Read-BootstrapJson $lock;$l.schema='rusty.morphospace.workflow.development_envelope_source_composition.v1';Write-BootstrapJson $lock $l;Strip-BootstrapReservedArtifacts $path} {Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute')} 'live lock schema plus stripped reserved artifacts cannot downgrade'
 Damage-BootstrapFiles $f @($unitPath,$path) {$u=Read-BootstrapJson $unitPath;$u|Add-Member -NotePropertyName candidate_freeze -NotePropertyValue ([pscustomobject]@{freeze_id='pretend-frozen';receipt_path='receipts/begin.json';receipt_sha256=Raw-Bootstrap (Join-Path $f.workspace 'receipts/begin.json')}) -Force;Write-BootstrapJson $unitPath $u;Strip-BootstrapReservedArtifacts $path} {Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute')} 'fake Freeze plus stripped reserved artifacts cannot downgrade'
 Damage-BootstrapFiles $f @($unitPath,$path) {$u=Read-BootstrapJson $unitPath;$u.PSObject.Properties.Remove('source_composition');Write-BootstrapJson $unitPath $u;Strip-BootstrapReservedArtifacts $path} {Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute')} 'removed source binding plus stripped reserved artifacts cannot downgrade'
 $originState=Read-BootstrapJson (Join-Path $f.workspace 'workspace.state.json')
 $tailIntentPath=Join-Path $f.workspace "receipts/transactions/$([string]$originState.last_event_id)-transition.intent.json"
 $tailIntentBytes=[IO.File]::ReadAllBytes($tailIntentPath)
 try{
  [IO.File]::Delete($tailIntentPath)
  Damage-BootstrapFiles $f @($unitPath,$path) {
   $u=Read-BootstrapJson $unitPath;$u.PSObject.Properties.Remove('source_composition');Write-BootstrapJson $unitPath $u
   Strip-BootstrapReservedArtifacts $path
  } {Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute')} 'retained source origin survives missing tail plus removed live binding'
 }finally{[IO.File]::WriteAllBytes($tailIntentPath,$tailIntentBytes)}
 Damage-BootstrapFiles $f @($tailIntentPath,$unitPath,$path) {
  $t=Read-BootstrapJson $tailIntentPath;$t.target.unit.document.PSObject.Properties.Remove('source_composition');Write-BootstrapJson $tailIntentPath $t
  $u=Read-BootstrapJson $unitPath;$u.PSObject.Properties.Remove('source_composition');Write-BootstrapJson $unitPath $u
  Strip-BootstrapReservedArtifacts $path
 } {Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute')} 'native tail source deletion plus removed live binding remains authenticated'
 $originalReceiptRaw=Raw-Bootstrap $path
 $record=Read-BootstrapTerminal (Owner-Bootstrap $f RecordValidation @('-ValidationReceipt',"receipts/$Name-pass.json",'-ValidationResult','pass','-ValidationTier','quick','-Execute'))
 $recordIntent=Read-BootstrapJson (Join-Path $f.workspace "receipts/transactions/$($record.event_id)-transition.intent.json")
 $recordedState=Read-BootstrapJson (Join-Path $f.workspace 'workspace.state.json');$retainedReference=[string]$recordedState.validation_checkpoint.receipt
 Assert-BootstrapTest ($retainedReference-cne"receipts/$Name-pass.json"-and$retainedReference-ceq[string]$recordIntent.target.state.document.validation_checkpoint.receipt) 'native Record must select a new retained receipt through its actual target state'
 $retainedPath=[IO.Path]::GetFullPath((Join-Path $f.workspace $retainedReference))
 Assert-BootstrapTest ((Split-Path $retainedPath -Parent)-ceq(Split-Path $path -Parent)-and(Split-Path $retainedPath -Leaf).StartsWith([string]$record.event_id,[StringComparison]::Ordinal)) 'retained receipt must be event-derived in the original receipt directory'
 $ownedReceipts=@($recordIntent.artifacts|Where-Object path -CEQ $retainedReference)
 Assert-BootstrapTest (@($recordIntent.artifacts).Count-eq1-and$ownedReceipts.Count-eq1-and[string]$ownedReceipts[0].sha256-ceq$originalReceiptRaw-and(Raw-Bootstrap $retainedPath)-ceq$originalReceiptRaw-and(Raw-Bootstrap $path)-ceq$originalReceiptRaw) 'native bootstrap Record must retain exact consumed bytes in one new artifact while leaving original unchanged'
 Assert-BootstrapTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))-ceq[string]$ownedReceipts[0].bytes_base64) 'native retained receipt artifact payload differs from consumed receipt'
 Damage-BootstrapFile $f $retainedPath {param($p)[IO.File]::Delete($p)} {Owner-Bootstrap $f Accept @('-Execute')} 'missing consumed receipt before Accept'
 Damage-BootstrapFile $f $retainedPath {param($p)[IO.File]::AppendAllText($p,' ')} {Owner-Bootstrap $f Accept @('-Execute')} 'consumed receipt raw drift before Accept'
 $neutral=(Read-BootstrapJson $e).artifacts[0].path;Damage-BootstrapFile $f $neutral {param($p)[IO.File]::AppendAllText($p,' drift')} {Owner-Bootstrap $f Accept @('-Execute')} 'artifact drift between genuine Record and Accept'
 $accept=Read-BootstrapTerminal (Owner-Bootstrap $f Accept @('-Execute'))
 $acceptedState=Read-BootstrapJson (Join-Path $f.workspace 'workspace.state.json');$finalReference=[string]$acceptedState.validation_checkpoint.receipt
 $acceptIntent=Read-BootstrapJson (Join-Path $f.workspace "receipts/transactions/$($accept.event_id)-transition.intent.json")
 Assert-BootstrapTest ($finalReference-cne$retainedReference-and$finalReference-cne"receipts/$Name-pass.json"-and$finalReference-ceq[string]$acceptedState.last_accepted_receipt-and$finalReference-ceq[string]$acceptIntent.target.state.document.validation_checkpoint.receipt-and$finalReference-ceq[string]$acceptIntent.target.state.document.last_accepted_receipt) 'native Accept must select its own new authoritative final receipt copy'
 $finalPath=[IO.Path]::GetFullPath((Join-Path $f.workspace $finalReference));$expectedFinalName=[string]$accept.event_id+'-retained-validation.json'
 Assert-BootstrapTest ((Split-Path $finalPath -Parent)-ceq(Split-Path $retainedPath -Parent)-and(Split-Path $finalPath -Leaf)-ceq$expectedFinalName) 'Accept-owned receipt must use its event-derived filename in the same directory'
 $acceptedReceipts=@($acceptIntent.event.receipts);$finalArtifacts=@($acceptIntent.artifacts|Where-Object path -CEQ $finalReference)
 Assert-BootstrapTest ($acceptedReceipts.Count-eq2-and[string]$acceptedReceipts[0]-ceq$retainedReference-and[string]$acceptedReceipts[1]-ceq$finalReference-and@($acceptIntent.artifacts).Count-eq1-and$finalArtifacts.Count-eq1) 'Accept must own exactly final-copy artifact and ordered Record/final receipt references'
 Assert-BootstrapTest ([string]$finalArtifacts[0].sha256-ceq$originalReceiptRaw-and(Raw-Bootstrap $finalPath)-ceq$originalReceiptRaw-and(Raw-Bootstrap $retainedPath)-ceq$originalReceiptRaw-and(Raw-Bootstrap $path)-ceq$originalReceiptRaw-and[string]$finalArtifacts[0].bytes_base64-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) 'Accept final artifact bytes must equal preserved Record copy and original output'
 Read-BootstrapConsumers $f
 Damage-BootstrapFile $f $finalPath {param($p)[IO.File]::AppendAllText($p,' ')} {Read-BootstrapConsumers $f} 'accepted current/project reader receipt raw drift'
 Assert-BootstrapTest ((Raw-Bootstrap $path)-ceq$originalReceiptRaw-and(Raw-Bootstrap $retainedPath)-ceq$originalReceiptRaw) 'native Record/Accept changed the original output or Record-owned copy'
 return $f
}

function Test-LaterLegacyBootstrapRefused($f){
 Phase-Bootstrap 'genuine-prior-acceptance-refusal'
 Git-Bootstrap $f.root @('add','morphospace/')|Out-Null;Git-Bootstrap $f.root @('commit','--quiet','-m','retain-genuine-accepted-native-controls')|Out-Null;$f.unit_id='later-004';$u=New-BootstrapUnit $f.project_id $f.unit_id;Write-BootstrapJson (Join-Path $f.workspace "iteration-units/$($f.unit_id).json") $u
 Git-Bootstrap $f.root @('add',"morphospace/iteration-units/$($f.unit_id).json")|Out-Null;Git-Bootstrap $f.root @('commit','--quiet','-m','declare-later-proposed-unit')|Out-Null;Run-BootstrapNative 'New-SourceCompositionLock.ps1' @('-WorkspaceRoot',$f.workspace,'-UnitId',$f.unit_id,'-RepositoryMapPath',$f.map,'-OutRelativePath',"bootstrap-locks/$($f.unit_id).json",'-Execute')|Out-Null;Git-Bootstrap $f.root @('add',"morphospace/bootstrap-locks/$($f.unit_id).json")|Out-Null;Git-Bootstrap $f.root @('commit','--quiet','-m','later-lock-is-not-initial-authority')|Out-Null
 Owner-Bootstrap $f Ready @('-Execute')|Out-Null;Commit-BootstrapControls $f "$($f.unit_id)-ready";Owner-Bootstrap $f Claim @('-Execute')|Out-Null;Commit-BootstrapControls $f "$($f.unit_id)-claim";Complete-BootstrapInstructions $f;$begin=Read-BootstrapTerminal (Owner-Bootstrap $f BeginValidation @('-ValidationTier','quick','-OutPath',(Join-Path $f.workspace 'receipts/later-begin.json'),'-Execute'));$e=New-BootstrapEvidence $f $begin 'later'
 Refuse-Bootstrap $f {Make-BootstrapReceipt $f $e 'not-initial'} 'genuine earlier acceptance excludes bootstrap exception'
}

function Test-AdmittedFreezeJourney($f){
 Phase-Bootstrap 'admitted-native-prepare'
 Commit-BootstrapControls $f "$($f.unit_id)-accepted"
 $w=$f.workspace;$project=Read-BootstrapJson (Join-Path $w 'project.spec.json');$feature=Read-BootstrapJson (Join-Path $w 'feature.lock.json');$state=Read-BootstrapJson (Join-Path $w 'workspace.state.json');$old=Read-BootstrapJson (Join-Path $w "iteration-units/$($f.unit_id).json")
 Assert-BootstrapTest ($old.status-ceq'accepted'-and$null-eq$state.current_unit) 'ordinary admission must start from actual native accepted bootstrap endpoint'
 $target=Copy-BootstrapValue $project;$target.revision=[int]$project.revision+1;$targetLock=Copy-BootstrapValue $feature;$targetLock.revision=[int]$feature.revision+1;$targetLock.project_revision=$target.revision;$targetLock.lock_fingerprint=Get-MorphospaceFeatureLockFingerprint $targetLock
 $roots=@([pscustomobject]@{repo_id='project-shell';source_roots=@('morphospace/','AGENTS.md')},[pscustomobject]@{repo_id='product-source';source_roots=@('docs/input.txt')});$build=[pscustomobject]@{class='none';allowed_profiles=@('workflow')};$device=[pscustomobject]@{requirement='none';allowed_kinds=@()};$eventsPath=Join-Path $w 'iteration-events.jsonl';$sourceRelative='prepared-source/admitted.json';$prepId='bootstrap-ordinary-preparation';$prepOut=Join-Path $w "receipts/$prepId.json"
 $prep=[pscustomobject]@{schema='rusty.morphospace.workflow.development_envelope_preparation.v1';preparation_id=$prepId;project_id=$f.project_id;predecessor_unit_id=$f.unit_id;envelope=[pscustomobject]@{project=$target;feature_lock=$targetLock;owner_repositories=$roots;public_private_boundary='mixed';allowed_change_categories=@('documentation-only');allowed_effect_categories=@('none');allowed_permission_categories=@('none');build_envelope=$build;device_envelope=$device;source_composition=[pscustomobject]@{path=$sourceRelative;repository_ids=@('project-shell','product-source')}};expected=[pscustomobject]@{project_sha256=Hash-Bootstrap $project;state_sha256=Hash-Bootstrap $state;feature_lock_sha256=Hash-Bootstrap $feature;repository_map_path='repository-map.json';repository_map_sha256=Raw-Bootstrap $f.map;predecessor_unit_path="iteration-units/$($f.unit_id).json";predecessor_unit_sha256=Hash-Bootstrap $old;events_sha256=Raw-Bootstrap $eventsPath;events_length=[IO.FileInfo]::new($eventsPath).Length;event_tail_id=$state.last_event_id};does_not_prove=@('No validation, device or publication credit.')}
 $prepPath=Join-Path $HarnessRoot 'admitted-preparation-input.json';Write-BootstrapJson $prepPath $prep
 Owner-Bootstrap $f PrepareDevelopmentEnvelope @('-DevelopmentEnvelopePreparation',$prepPath,'-ExpectedDevelopmentEnvelopePreparationSha256',(Raw-Bootstrap $prepPath),'-OutPath',$prepOut,'-Execute')|Out-Null;Commit-BootstrapControls $f 'ordinary-prepared'
 $project=Read-BootstrapJson (Join-Path $w 'project.spec.json');$feature=Read-BootstrapJson (Join-Path $w 'feature.lock.json');$state=Read-BootstrapJson (Join-Path $w 'workspace.state.json');$id='admitted-003';$u=New-BootstrapUnit $f.project_id $id;$u.source_composition.lock_path=$sourceRelative;$u.allowed_repositories=@([pscustomobject]@{repo_id='product-source';allowed_paths=@('docs/input.txt')});$u|Add-Member -NotePropertyName read_only_dependencies -NotePropertyValue @([pscustomobject]@{repo_id='project-shell';paths=@('AGENTS.md');purpose='Authentic own planning/instruction provenance.';verification='Native prepared owner and exact instruction bytes.'}) -Force
 $assessment=[pscustomobject]@{schema='rusty.morphospace.workflow.agent_scope_assessment.v1';objective=$u.objective;owner_repositories=$roots;public_private_boundary='mixed';allowed_change_categories=@('documentation-only');allowed_effect_categories=@('none');allowed_permission_categories=@('none');build_envelope=$build;device_envelope=$device;non_scope=@('No runtime/device effects.');prerequisites=@();validation_class='quick';evidence_expectations=@('Real neutral assertion and public owner receipts.');cleanup_expectations=@('Retain failure evidence.')}
 $u|Add-Member -NotePropertyName agent_scope_assessment -NotePropertyValue $assessment -Force
 $admit=[pscustomobject]@{schema='rusty.morphospace.workflow.development_unit_admission.v1';admission_id='bootstrap-ordinary-admission';project_id=$f.project_id;unit_id=$id;preparation=[pscustomobject]@{preparation_id=$prepId;receipt_path="receipts/$prepId.json";receipt_sha256=Raw-Bootstrap $prepOut;source_composition_path=$sourceRelative;source_composition_sha256=Raw-Bootstrap (Join-Path $w $sourceRelative)};agent_scope_assessment=$assessment;unit=$u;expected=[pscustomobject]@{project_sha256=Hash-Bootstrap $project;state_sha256=Hash-Bootstrap $state;feature_lock_sha256=Hash-Bootstrap $feature;source_composition_path=$sourceRelative;source_composition_sha256=Raw-Bootstrap (Join-Path $w $sourceRelative);repository_map_path='repository-map.json';repository_map_sha256=Raw-Bootstrap $f.map;events_sha256=Raw-Bootstrap $eventsPath;events_length=[IO.FileInfo]::new($eventsPath).Length;event_tail_id=$state.last_event_id};does_not_prove=@('No claim/validation/acceptance credit.')}
 $admitPath=Join-Path $HarnessRoot 'admitted-input.json';Write-BootstrapJson $admitPath $admit;$f.unit_id=$id
 Owner-Bootstrap $f AdmitDevelopmentUnit @('-DevelopmentUnitAdmission',$admitPath,'-ExpectedDevelopmentUnitAdmissionSha256',(Raw-Bootstrap $admitPath),'-OutPath',(Join-Path $w 'receipts/bootstrap-ordinary-admission.json'),'-Execute')|Out-Null;Commit-BootstrapControls $f 'ordinary-admitted'
 Owner-Bootstrap $f Ready @('-Execute')|Out-Null;Commit-BootstrapControls $f "$($f.unit_id)-ready";Owner-Bootstrap $f Claim @('-Execute')|Out-Null;Commit-BootstrapControls $f "$($f.unit_id)-claim"
 $f|Add-Member -NotePropertyName expected_payload -NotePropertyValue "neutral candidate`nadmitted bounded change`n" -Force;[IO.File]::WriteAllText((Join-Path $f.product 'docs/input.txt'),$f.expected_payload,[Text.UTF8Encoding]::new($false));Complete-BootstrapInstructions $f
 # Negative only: its gates are inert evidence inputs, not a positive receipt.
 # The owning producer must refuse this genuinely admitted unit before Freeze.
 $negativeMatrix=[pscustomobject]@{validation_matrix=@([pscustomobject]@{gate_id='validation-workflow';command='neutral-bootstrap-host-check';disposition='required'})};$negativeEvidence=New-BootstrapEvidence $f $negativeMatrix 'admitted-before-freeze'
 Refuse-Bootstrap $f {Make-BootstrapReceipt $f $negativeEvidence 'admitted-without-freeze'} 'genuine admitted unit still requires Freeze'
 Phase-Bootstrap 'admitted-native-freeze'
 $u=Read-BootstrapJson (Join-Path $w "iteration-units/$id.json");$state=Read-BootstrapJson (Join-Path $w 'workspace.state.json');$feature=Read-BootstrapJson (Join-Path $w 'feature.lock.json');$source=Join-Path $w $sourceRelative;$head=(@(Git-Bootstrap $f.product @('rev-parse','HEAD'))-join'');$tree=(@(Git-Bootstrap $f.product @('rev-parse','HEAD^{tree}'))-join'')
 $frozenBase=[string]@((Read-BootstrapJson $source).repositories|Where-Object repo_id -CEQ 'product-source')[0].commit;$delta=@(Git-Bootstrap $f.product @('diff','--name-only',$frozenBase,'--')|Where-Object{$_-ceq'docs/input.txt'});Assert-BootstrapTest ($delta.Count-eq1-and$delta[0]-ceq'docs/input.txt') 'admitted Freeze must observe its real dirty product source delta'
 $freeze=[pscustomobject]@{schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id='admitted-frozen';project_id=$f.project_id;unit_id=$id;expected=[pscustomobject]@{project_sha256=Hash-Bootstrap (Read-BootstrapJson (Join-Path $w 'project.spec.json'));state_sha256=Hash-Bootstrap $state;unit_sha256=Hash-Bootstrap $u;feature_lock_sha256=Hash-Bootstrap $feature;source_composition_path=$sourceRelative;source_composition_sha256=Raw-Bootstrap $source;repository_map_path='repository-map.json';repository_map_sha256=Raw-Bootstrap $f.map;events_sha256=Raw-Bootstrap $eventsPath;events_length=[IO.FileInfo]::new($eventsPath).Length;event_tail_id=$state.last_event_id};final_repositories=@([pscustomobject]@{repo_id='product-source';commit=$head;tree=$tree});changed_paths=@([pscustomobject]@{repo_id='product-source';paths=$delta});cleanliness_policy='declared-dirty-paths';instruction_surfaces=@([pscustomobject]@{path='<project-root>/AGENTS.md';disposition='reviewed-no-change'});feature_lock=[pscustomobject]@{revision=$feature.revision;sha256=Hash-Bootstrap $feature};effects=@('none');permissions=@();device_use=@('none');test_matrix=@([pscustomobject]@{test_id='neutral';command='neutral-bootstrap-host-check'});cleanup_evidence=@('No product/device effects; fixture retained.');source_composition=[pscustomobject]@{path=$sourceRelative;sha256=Raw-Bootstrap $source};does_not_prove=@('No product/runtime validation credit.')}
 $freezePath=Join-Path $HarnessRoot 'admitted-freeze-input.json';Write-BootstrapJson $freezePath $freeze;Owner-Bootstrap $f FreezeCandidate @('-CandidateFreeze',$freezePath,'-ExpectedCandidateFreezeSha256',(Raw-Bootstrap $freezePath),'-OutPath',(Join-Path $w 'receipts/admitted-frozen.json'),'-Execute')|Out-Null
 $begin=Read-BootstrapTerminal (Owner-Bootstrap $f BeginValidation @('-ValidationTier','quick','-OutPath',(Join-Path $w 'receipts/admitted-begin.json'),'-Execute'));$e=New-BootstrapEvidence $f $begin 'admitted';$path=Make-BootstrapReceipt $f $e 'admitted-pass';$ordinary=Read-BootstrapJson $path;$preparedLock=Read-BootstrapJson $source
 Assert-BootstrapTest (@($ordinary.repository_revisions|Where-Object repo_id -CEQ 'product-source')[0].base_revision-ceq@($preparedLock.repositories|Where-Object repo_id -CEQ 'product-source')[0].commit-and@($ordinary.artifacts|Where-Object{$_.artifact_id-cin@('bootstrap-source-lock','bootstrap-repository-map','bootstrap-begin-intent')}).Count-eq0) 'ordinary frozen receipt acquired bootstrap authority or lost its exact prepared baseline'
 Damage-BootstrapFile $f $source {param($p)[IO.File]::AppendAllText($p,' ')} {Make-BootstrapReceipt $f $e 'admitted-drift'} 'ordinary Freeze raw lock fence remains strict'
 Owner-Bootstrap $f RecordValidation @('-ValidationReceipt','receipts/admitted-pass.json','-ValidationResult','pass','-ValidationTier','quick','-Execute')|Out-Null;Owner-Bootstrap $f Accept @('-Execute')|Out-Null;Read-BootstrapConsumers $f
}

# No manual positive receipts, fake accepted predecessor, or repaired ledger.
$direct=Test-BootstrapJourney (New-BootstrapFixture 'direct') 'direct'
$superseded=Test-BootstrapJourney (New-BootstrapFixture 'superseded' -Supersede) 'superseded'
Test-AdmittedFreezeJourney $direct
Test-LaterLegacyBootstrapRefused $superseded
Phase-Bootstrap 'complete'
[pscustomobject]@{result='pass';direct_bootstrap=$true;typed_supersession_bootstrap=$true;genuine_admitted_freeze=$true;real_neutral_payload_checks=$true;native_public_constructor=$true;record_accept_current_and_project_readers=$true;no_write_refusals=$script:refusals;native_calls=$script:run;seconds=$script:clock.Elapsed.TotalSeconds;harness_root=[IO.Path]::GetFullPath($HarnessRoot);fixture_retained=$true;product_device_leaves='modeled/unused';device_calls=0}|ConvertTo-Json -Depth 6
