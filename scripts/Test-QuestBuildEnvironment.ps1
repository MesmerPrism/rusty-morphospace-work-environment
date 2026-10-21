param([string]$RepoRoot='', [string]$SeedContextPath='', [string]$SeedContextSha256='', [string]$EvidenceRoot='', [switch]$RequireCompilerMismatch, [switch]$TemplateOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent $PSScriptRoot}
$RepoRoot=[IO.Path]::GetFullPath($RepoRoot)
if($TemplateOnly){
 $template=Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'templates/quest-build-context.example.json')
 if(-not(Test-Json -Json $template -SchemaFile (Join-Path $RepoRoot 'schemas/local-quest-build-context-v1.schema.json') -ErrorAction Stop)){throw 'Quest context example violates its closed schema'}
 [Console]::Out.WriteLine('{"quest_context_template":"passed","tool_probes":0,"execution_authority":false}')
 exit 0
}
if(-not$EvidenceRoot){$EvidenceRoot=Join-Path ([IO.Path]::GetTempPath()) ('quest-context-corpus-'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $EvidenceRoot){throw 'Fresh test evidence root required'}
[void][IO.Directory]::CreateDirectory($EvidenceRoot)
$workingDirectory=$EvidenceRoot
$gitFixture=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
function Fixture-Git([string[]]$Arguments){$out=@(& $gitFixture -C $workingDirectory @Arguments 2>&1);if($LASTEXITCODE-ne0){throw 'Fixture Git failed'};return $out}
if(-not$SeedContextPath){
 # Explicit fixture selection is test data. Compatibility cases preserve ordinary
 # first-Application PATH precedence; explicit contexts pin exact tools.
 $rustupFixture=(Get-Command rustup -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
 $channel=((& $rustupFixture show active-toolchain)-join'').Split(' ')[0]
 if($LASTEXITCODE-ne0){throw 'Fixture Rust toolchain observation failed'}
 $cargoFixture=((& $rustupFixture which --toolchain $channel cargo)-join'').Trim()
 if($LASTEXITCODE-ne0){throw 'Fixture Cargo selection failed'}
 $rustcFixture=((& $rustupFixture which --toolchain $channel rustc)-join'').Trim()
 if($LASTEXITCODE-ne0){throw 'Fixture compiler selection failed'}
 $paths=@{cargo=$cargoFixture;rustc=$rustcFixture;rustup=$rustupFixture;pwsh=[Environment]::ProcessPath;git=$gitFixture}
 $toolRecords=@{};foreach($id in $paths.Keys){$toolRecords[$id]=[ordered]@{path=[IO.Path]::GetFullPath($paths[$id]);sha256=(Get-FileHash -LiteralPath $paths[$id] -Algorithm SHA256).Hash.ToLowerInvariant()}}
 $environment=@{};foreach($name in @('HOME','USERPROFILE','SYSTEMROOT','SYSTEMDRIVE','WINDIR','COMSPEC','PATHEXT','TEMP','TMP','TMPDIR','RUSTUP_HOME','CARGO_HOME')){$value=[Environment]::GetEnvironmentVariable($name);if($null-ne$value){$environment[$name]=$value}}
 $pathParts=@($paths.Values|ForEach-Object{Split-Path $_ -Parent})+@(([Environment]::GetEnvironmentVariable('PATH'))-split[regex]::Escape([string][IO.Path]::PathSeparator)|Where-Object{$_-and(Test-Path -LiteralPath $_ -PathType Container -ErrorAction SilentlyContinue)})
 # The validation supervisor deliberately omits these ambient names. The fixture
 # declares actual Windows facts without changing the parent or production guard.
 if($IsWindows){
  if(-not$environment.ContainsKey('SYSTEMDRIVE')){$environment.SYSTEMDRIVE=[IO.Path]::GetPathRoot([string]$environment.SYSTEMROOT).TrimEnd('\')}
  if(-not$environment.ContainsKey('USERPROFILE')){$environment.USERPROFILE=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)}
 }
 $environment.PATH=(@($pathParts|Select-Object -Unique)-join[IO.Path]::PathSeparator)
 $seed=[ordered]@{schema='rusty.morphospace.local_quest_build_context.v1';environment=$environment;tools=$toolRecords;rust_toolchain=[ordered]@{channel=$channel}}
 $SeedContextPath=Join-Path $EvidenceRoot 'seed.json'
 [IO.File]::WriteAllText($SeedContextPath,($seed|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
 $SeedContextSha256=(Get-FileHash -LiteralPath $SeedContextPath -Algorithm SHA256).Hash.ToLowerInvariant()
}


Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# This uses production API only. A missing baseline API is a genuine red, never a skip/pass.
# Evidence root created by owning corpus header.
# Existing fresh fixture root.
$module=Join-Path $RepoRoot 'scripts/lib/MorphospaceQuestBuildEnvironment.psm1'
$results=[Collections.Generic.List[object]]::new()
$script:RealCompilerMismatchExercised=$false
function Sha([string]$p){(Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant()}
function Assert([bool]$v,[string]$m){if(-not$v){throw $m}}
function Clone([object]$v){$v|ConvertTo-Json -Depth 40|ConvertFrom-Json -Depth 40 -DateKind String}
function Store([string]$id,[object]$v){$p=Join-Path $EvidenceRoot "$id.json";if(Test-Path -LiteralPath $p){throw 'Fixture overwrite refused'};[IO.File]::WriteAllText($p,($v|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false));return $p}
function ParentHash{$pairs=@([Environment]::GetEnvironmentVariables().GetEnumerator()|Sort-Object Key|ForEach-Object{[ordered]@{name=[string]$_.Key;value=[string]$_.Value}});$raw=[Text.Encoding]::UTF8.GetBytes(($pairs|ConvertTo-Json -Depth 5 -Compress));[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()}
function Resolve([string]$p,[string[]]$tools=@('cargo','rustc','rustup','pwsh','git'),[string[]]$targets=@(),[string]$channel=''){$args=@{ContextPath=$p;ContextSha256=(Sha $p);WorkingDirectory=$WorkingDirectory;RequiredTools=$tools;RequiredTargets=$targets};if($channel){$args.ToolchainChannel=$channel};Resolve-MorphospaceQuestBuildContext @args}
function Refusal([scriptblock]$action,[string]$code){$caught=$null;try{& $action|Out-Null}catch{$caught=$_};Assert ($null-ne$caught) 'Expected production refusal absent';Assert ([string]$caught.Exception.Data['ReasonCode']-ceq$code) "Wrong sanitized reason; expected $code"}
function Case([string]$id,[scriptblock]$body){$before=ParentHash;try{&$body;Assert ((ParentHash)-ceq$before) 'Parent environment was not restored';$results.Add([ordered]@{case=$id;status='passed'})}catch{$results.Add([ordered]@{case=$id;status='failed';error_type=$_.Exception.GetType().FullName;reason_code=[string]$_.Exception.Data['ReasonCode']});[Console]::Error.WriteLine("FAILED causal case: $id / $($_.Exception.Message)")}}

# Obviously synthetic literals live only in this owning test fixture. They are
# never profile/context/argv values or persisted environment observations.
function Get-PrivacyCanaries {
    return @('SYNTHETIC-NOT-A-CREDENTIAL::alpha-040::v1', 'SYNTHETIC-NOT-A-CREDENTIAL::bravo-041::v1')
}
function Assert-PrivacyPublicText([string]$Text) {
    foreach ($value in @(Get-PrivacyCanaries)) {
        $utf8 = [Text.Encoding]::UTF8.GetBytes($value)
        $utf16 = [Text.Encoding]::Unicode.GetBytes($value)
        $json = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $value -Compress))
        $forms = @($value, [Convert]::ToBase64String($utf8), [Convert]::ToBase64String($utf16))
        foreach ($bytes in @($utf8, $utf16, $json)) {
            $digest = [Security.Cryptography.SHA256]::HashData($bytes)
            $forms += [Convert]::ToHexString($digest).ToLowerInvariant()
            $forms += [Convert]::ToBase64String($digest)
        }
        foreach ($form in $forms) {
            if ($Text.IndexOf($form, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Synthetic credential representation leaked into public evidence' }
        }
    }
}
function Assert-PrivacyEvidence([object]$Value) {
    if ($null -eq $Value) { return }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ([string]$key -in @('value_sha256', 'environment_sha256', 'child_environment_sha256')) {
                if ($null -ne $Value[$key]) { throw 'Public environment value fingerprint must be JSON null' }
            }
            Assert-PrivacyEvidence $Value[$key]
        }
    } elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Assert-PrivacyEvidence $item }
    }
}
function Assert-PrivacyJson([string]$Text) {
    Assert-PrivacyPublicText $Text
    Assert-PrivacyEvidence (ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 100 -DateKind String)
}
function Set-PrivacyVariable([string]$Name, [AllowNull()][object]$Value) {
    if ($null -eq $Value) { [Environment]::SetEnvironmentVariable($Name, [System.Management.Automation.Language.NullString]::Value) }
    else { [Environment]::SetEnvironmentVariable($Name, [string]$Value) }
}

try{
 Assert ((Sha $SeedContextPath)-ceq$SeedContextSha256) 'Seed context identity differs'
 $seed=Get-Content -Raw -LiteralPath $SeedContextPath|ConvertFrom-Json -Depth 40 -DateKind String
 $seedRustcExecutable=[string]$seed.tools.rustc.path;$seedRustupExecutable=[string]$seed.tools.rustup.path;$seedPwshExecutable=[string]$seed.tools.pwsh.path
 Import-Module -Name $module -Force -ErrorAction Stop
 foreach($name in @('Resolve-MorphospaceQuestBuildContext','Invoke-MorphospaceQuestBuildEnvironment')){Assert ($null-ne(Get-Command $name -ErrorAction SilentlyContinue)) 'Production function missing'}
 $valid=Store 'valid' $seed
 Case 'stale-context-hash' {Refusal {Resolve-MorphospaceQuestBuildContext -ContextPath $valid -ContextSha256 ('0'*64) -WorkingDirectory $WorkingDirectory -RequiredTools @('cargo')} 'context-hash-mismatch'}
 Case 'missing-selected-rustup-despite-ambient' {$v=Clone $seed;$v.tools.PSObject.Properties.Remove('rustup');$p=Store 'missing-rustup' $v;Refusal {Resolve $p} 'tool-missing'}
 Case 'wrong-selected-tool-hash' {$v=Clone $seed;$v.tools.cargo.sha256='0'*64;$p=Store 'wrong-cargo-hash' $v;Refusal {Resolve $p} 'tool-hash-mismatch'}
 Case 'explicit-scalar-with-real-duplicate-path-applications' {
  $v=Clone $seed;$sep=[IO.Path]::PathSeparator
  $v.environment.PATH=((Split-Path $v.tools.cargo.path -Parent),(Split-Path $v.tools.rustup.path -Parent),[string]$v.environment.PATH)-join$sep
  $p=Store 'duplicate-path' $v;$c=Resolve $p
  Assert ($c.Tools.cargo.Path-is[string]) 'Cargo selection is not scalar'
  Assert ($c.Tools.cargo.Path-ceq[IO.Path]::GetFullPath($seed.tools.cargo.path)) 'Explicit Cargo changed'
  Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {param($selected)
   $matches=@(Get-Command cargo -CommandType Application -ErrorAction Stop|Select-Object -ExpandProperty Source -Unique)
   Assert ($matches.Count-ge2) 'Fixture requires actual distinct direct/proxy Cargo applications; no synthetic pass'
   Assert ($env:RUSTC-ceq$selected.Tools.rustc.Path) 'Effective RUSTC differs'
  } -ArgumentList @($c)
 }
 Case 'foreign-parent-variable-excluded-and-success-restored' {
  $old=[Environment]::GetEnvironmentVariable('MORPHOSPACE_CAUSAL_FOREIGN')
  try{[Environment]::SetEnvironmentVariable('MORPHOSPACE_CAUSAL_FOREIGN','owned-finite-sentinel');$c=Resolve $valid
   Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {Assert ($null-eq[Environment]::GetEnvironmentVariable('MORPHOSPACE_CAUSAL_FOREIGN')) 'Foreign variable leaked'}
   Assert ([Environment]::GetEnvironmentVariable('MORPHOSPACE_CAUSAL_FOREIGN')-ceq'owned-finite-sentinel') 'Parent marker missing after scope'
  }finally{if($null-eq$old){[Environment]::SetEnvironmentVariable('MORPHOSPACE_CAUSAL_FOREIGN',[System.Management.Automation.Language.NullString]::Value)}else{[Environment]::SetEnvironmentVariable('MORPHOSPACE_CAUSAL_FOREIGN',$old)}}
 }
 Case 'callback-exception-restores-parent' {$c=Resolve $valid;$expected='owned-callback-failure';$caught=$false;try{Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {throw 'owned-callback-failure'}}catch{$caught=$_.Exception.Message.Contains($expected)};Assert $caught 'Callback exception not propagated'}
 Case 'absent-target-refuses-before-action' {Refusal {Resolve $valid -targets @('causal-nonexistent-target-040')} 'target-missing'}
 Case 'declared-toolchain-mismatch-refuses' {Refusal {Resolve $valid -targets @('aarch64-linux-android') -channel 'causal-not-selected-channel'} 'toolchain-compiler-mismatch'}
 Case 'changed-context-after-resolve-refuses-before-action' {
  $p=Store 'change-after-resolve' $seed;$c=Resolve $p;[IO.File]::AppendAllText($p,"`n ");$script:unexpectedAction=$false
  Refusal {Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {$script:unexpectedAction=$true}} 'context-hash-mismatch'
  Assert (-not$script:unexpectedAction) 'Action dispatched on changed context'
 }
 Case 'explicit-inmemory-secret-overlay-not-serialized' {
  $old=[Environment]::GetEnvironmentVariable('MORPHOSPACE_CAUSAL_SECRET')
  try{[Environment]::SetEnvironmentVariable('MORPHOSPACE_CAUSAL_SECRET','owned-nonsecret-fixture-value');$c=Resolve-MorphospaceQuestBuildContext -ContextPath $valid -ContextSha256 (Sha $valid) -WorkingDirectory $WorkingDirectory -RequiredTools @('pwsh') -PassthroughVariables @('MORPHOSPACE_CAUSAL_SECRET')
   Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {Assert ([Environment]::GetEnvironmentVariable('MORPHOSPACE_CAUSAL_SECRET')-ceq'owned-nonsecret-fixture-value') 'Explicit transient overlay absent'}
   $marker=@($c.Evidence|Where-Object {$_.kind-ceq'environment'-and$_.variable-ceq'MORPHOSPACE_CAUSAL_SECRET'});Assert ($marker.Count-eq1-and$marker[0].present-and$null-eq$marker[0].value_sha256-and$null-eq$c.EnvironmentSha256) 'Explicit overlay must persist presence only'
   $evidence=$c.Evidence|ConvertTo-Json -Depth 40 -Compress;Assert (-not$evidence.Contains('owned-nonsecret-fixture-value')) 'Raw overlay value leaked into evidence'
  }finally{if($null-eq$old){[Environment]::SetEnvironmentVariable('MORPHOSPACE_CAUSAL_SECRET',[System.Management.Automation.Language.NullString]::Value)}else{[Environment]::SetEnvironmentVariable('MORPHOSPACE_CAUSAL_SECRET',$old)}}
 }
 Case 'mutated-resolved-environment-refuses' {$c=Resolve $valid;$c.EnvironmentValues['MORPHOSPACE_MUTATED']='refuse';Refusal {Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {throw 'unexpected action'}} 'resolved-context-mutated'}
 Case 'mutated-resolved-tool-refuses' {$c=Resolve $valid;$c.Tools.cargo.Sha256='0'*64;Refusal {Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {throw 'unexpected action'}} 'resolved-context-mutated'}
 Case 'wrong-first-bare-git-refuses' {
  $wrong=Join-Path $EvidenceRoot 'wrong-first-git';[void][IO.Directory]::CreateDirectory($wrong)
  [IO.File]::Copy($seed.tools.git.path,(Join-Path $wrong ([IO.Path]::GetFileName($seed.tools.git.path))))
  $v=Clone $seed;$v.environment.PATH=$wrong+[IO.Path]::PathSeparator+$v.environment.PATH
  $p=Store 'wrong-first-git' $v;Refusal {Resolve $p} 'context-binding-conflict'
 }
 Case 'held-context-bytes-cannot-change-unnoticed' {
  $p=Store 'held-context' $seed;$c=Resolve $p;$script:writeRefused=$false
  if($IsWindows){
   Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {param($path)try{[IO.File]::AppendAllText($path," ")}catch [IO.IOException]{$script:writeRefused=$true}} -ArgumentList @($p)
   Assert $script:writeRefused 'Live read hold permitted context write'
  }else{Refusal {Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {param($path)[IO.File]::AppendAllText($path," ")} -ArgumentList @($p)} 'context-hash-mismatch'}
 }
 Case 'mutated-evidence-refuses' {$c=Resolve $valid;$c.Evidence[0].sha256='0'*64;Refusal {Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {throw 'unexpected action'}} 'resolved-context-mutated'}
 Case 'native-nonzero-observer-retains-reason'  {
  $v=Clone $seed;$v.tools.pwsh.path=$v.tools.git.path;$v.tools.pwsh.sha256=$v.tools.git.sha256;$p=Store 'nonzero-observer' $v
  $oldPreference=$PSNativeCommandUseErrorActionPreference
  try{$PSNativeCommandUseErrorActionPreference=$true;Refusal {Resolve $p -tools @('pwsh')} 'tool-probe-failed'}finally{$PSNativeCommandUseErrorActionPreference=$oldPreference}
 }

 # Public serialization is intentionally a finite view, never the private map.
 function Privacy-Resolve {
  Resolve-MorphospaceQuestBuildContext -ContextPath $valid -ContextSha256 (Sha $valid) -WorkingDirectory $WorkingDirectory -RequiredTools @('pwsh') -PassthroughVariables @('WEF_PRIVACY_CANARY')
 }
 function Privacy-View([object]$Context) {
  ConvertTo-Json -InputObject ([ordered]@{context_sha256=$Context.ContextSha256;environment_sha256=$Context.EnvironmentSha256;evidence=@($Context.Evidence)}) -Depth 64 -Compress
 }
 Case 'privacy-value-only-change-keeps-public-evidence-and-exact-delivery' {
  $old=[Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY');$views=@()
  try {
   foreach($expected in @(Get-PrivacyCanaries)) {
    Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $expected
    $c=Privacy-Resolve
    Assert ($null-eq$c.EnvironmentSha256) 'Public selected-context environment digest must be null'
    $row=@($c.Evidence|Where-Object {$_.kind-ceq'environment'-and$_.variable-ceq'WEF_PRIVACY_CANARY'})
    Assert ($row.Count-eq1-and$row[0].present-and$null-eq$row[0].value_sha256) 'Synthetic passthrough presence row differs'
    Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {param($wanted)Assert ([Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')-ceq$wanted) 'Exact synthetic value was not delivered'} -ArgumentList @($expected)
    Assert ([Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')-ceq$expected) 'Synthetic parent overlay was not restored'
    $view=Privacy-View $c;Assert-PrivacyJson $view;$views+=,$view
   }
   Assert ($views.Count-eq2-and$views[0]-ceq$views[1]) 'Changing only a synthetic value changed permitted public evidence'
  }finally{Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $old}
 }
 Case 'privacy-private-map-mutation-refuses-before-callback' {
  $old=[Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')
  try {
   $values=@(Get-PrivacyCanaries);Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $values[0];$c=Privacy-Resolve
   $c.EnvironmentValues['WEF_PRIVACY_CANARY']=$values[1];$script:privacyCalled=$false
   Refusal {Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {$script:privacyCalled=$true}} 'resolved-context-mutated'
   Assert (-not$script:privacyCalled) 'Changed private value reached callback'
  }finally{Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $old}
 }
 Case 'privacy-public-null-field-is-still-integrity-bound' {
  $old=[Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')
  try {
   Set-PrivacyVariable 'WEF_PRIVACY_CANARY' (@(Get-PrivacyCanaries)[0]);$c=Privacy-Resolve
   Assert ($null-eq$c.EnvironmentSha256) 'Privacy policy absent before mutation'
   $c.EnvironmentSha256='0'*64;$script:privacyCalled=$false
   Refusal {Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {$script:privacyCalled=$true}} 'resolved-context-mutated'
   Assert (-not$script:privacyCalled) 'Changed public DTO reached callback'
  }finally{Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $old}
 }
 Case 'privacy-same-value-nesting-delivers-and-exception-restores' {
  $old=[Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')
  try {
   $expected=@(Get-PrivacyCanaries)[0];Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $expected;$c=Privacy-Resolve
   Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {
    param($bound,$wanted)
    Invoke-MorphospaceQuestBuildEnvironment -Context $bound -Action {param($value)Assert ([Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')-ceq$value) 'Identical private nested scope lost synthetic value'} -ArgumentList @($wanted)
   } -ArgumentList @($c,$expected)
   $caught=$false;try{Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {throw 'synthetic-private-callback-failure'}}catch{$caught=$_.Exception.Message.Contains('synthetic-private-callback-failure')}
   Assert $caught 'Synthetic callback failure was not propagated'
   Assert ([Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')-ceq$expected) 'Exception lost parent overlay'
  }finally{Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $old}
 }
 Case 'privacy-different-private-values-refuse-nesting-despite-equal-public-evidence' {
  $old=[Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')
  try {
   $values=@(Get-PrivacyCanaries);Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $values[0];$a=Privacy-Resolve
   Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $values[1];$b=Privacy-Resolve
   Assert ((Privacy-View $a)-ceq(Privacy-View $b)) 'Expected equal presence-only evidence absent'
   Invoke-MorphospaceQuestBuildEnvironment -Context $a -Action {
    param($nested,$wanted)
    Refusal {Invoke-MorphospaceQuestBuildEnvironment -Context $nested -Action {throw 'unexpected private nested action'}} 'environment-busy'
    Assert ([Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')-ceq$wanted) 'Refused nesting changed active outer value'
   } -ArgumentList @($b,$values[0])
  }finally{Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $old}
 }
 Case 'privacy-absent-passthrough-never-reports-present-or-a-value-hash' {
  $old=[Environment]::GetEnvironmentVariable('WEF_PRIVACY_CANARY')
  try {
   Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $null;$c=Privacy-Resolve
   Assert (-not$c.EnvironmentValues.ContainsKey('WEF_PRIVACY_CANARY')) 'Absent passthrough entered private map'
   $row=@($c.Evidence|Where-Object {$_.kind-ceq'environment'-and$_.variable-ceq'WEF_PRIVACY_CANARY'})
   Assert ($row.Count-le1-and@($row|Where-Object {$_.present-or$null-ne$_.value_sha256}).Count-eq0) 'Absent synthetic value was reported present'
   Assert-PrivacyJson (Privacy-View $c)
  }finally{Set-PrivacyVariable 'WEF_PRIVACY_CANARY' $old}
 }

 # Actual distinct installed compiler/sysroot, not a contradictory channel argument.
 $currentVersion=((& $seedRustcExecutable -vV)-join[Environment]::NewLine)
 $hostLine=@($currentVersion-split'\r?\n'|Where-Object{$_-match'^host: '})[0]
 $hostTarget=$hostLine.Substring(6)
 $foreignCompiler=$null
 foreach($entry in @(& $seedRustupExecutable toolchain list)){
  $otherChannel=([string]$entry).Split(' ')[0]
  if($otherChannel-ceq$seed.rust_toolchain.channel){continue}
  $candidate=((& $seedRustupExecutable which --toolchain $otherChannel rustc 2>$null)-join'').Trim()
  if($LASTEXITCODE-ne0-or-not$candidate){continue}
  if($candidate-cne$seed.tools.rustc.path){$foreignCompiler=$candidate;break}
 }
 $script:RealCompilerMismatchExercised=$false
 if($foreignCompiler){
  Case 'actual-compiler-versus-rustup-toolchain-mismatch' {
   $v=Clone $seed;$v.tools.rustc.path=$foreignCompiler;$v.tools.rustc.sha256=Sha $foreignCompiler
   if($null-ne$v.environment.PSObject.Properties['RUSTC']){$v.environment.RUSTC=$v.tools.rustc.path}
   $p=Store 'actual-foreign-compiler' $v
   Refusal {Resolve $p -targets @($hostTarget)} 'toolchain-compiler-mismatch'
   $script:RealCompilerMismatchExercised=$true
  }
 }elseif($RequireCompilerMismatch){Case 'actual-compiler-mismatch-fixture-required' {throw 'A distinct real installed compiler is required for this qualification; never provision or credit a missing fixture.'}}
 Case 'incompatible-same-thread-environment-scope-refuses' {
  $v=Clone $seed;$v.environment|Add-Member -NotePropertyName MORPHOSPACE_NESTED -NotePropertyValue different
  $p=Store 'incompatible-nested' $v;$other=Resolve $p;$c=Resolve $valid
  Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {
   param($nested)Refusal {Invoke-MorphospaceQuestBuildEnvironment -Context $nested -Action {throw 'unexpected nested action'}} 'environment-busy'
  } -ArgumentList @($other)
 }
 Case 'context-template-closed-schema' {
  $template=Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'templates/quest-build-context.example.json')
  Assert (Test-Json -Json $template -SchemaFile (Join-Path $RepoRoot 'schemas/local-quest-build-context-v1.schema.json')) 'Portable template schema differs'
 }
 Case 'cross-runspace-environment-scope-refuses-concurrency'  {
  $c=Resolve $valid
  Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {
   param($bound,$modulePath,$directory)
   $worker=[PowerShell]::Create()
   try{
    [void]$worker.AddScript('param($module,$path,$sha,$directory) Import-Module $module -Force; try{$selected=Resolve-MorphospaceQuestBuildContext -ContextPath $path -ContextSha256 $sha -WorkingDirectory $directory; Invoke-MorphospaceQuestBuildEnvironment -Context $selected -Action {throw "unexpected concurrent action"}}catch{[string]$_.Exception.Data["ReasonCode"]}')
    [void]$worker.AddArgument($modulePath);[void]$worker.AddArgument($bound.ContextPath);[void]$worker.AddArgument($bound.ContextSha256);[void]$worker.AddArgument($directory)
    $async=$worker.BeginInvoke();$out=@($worker.EndInvoke($async))
    Assert ($out.Count-eq1-and[string]$out[0]-ceq'environment-busy') 'Concurrent real runspace entered process environment scope'
   }finally{$worker.Dispose()}
  } -ArgumentList @($c,$module,$WorkingDirectory)
 }
 Case 'canonical-tool-alias-survives-alias-retarget' {
  $alias=Join-Path $EvidenceRoot 'tool-alias';$retained=Join-Path $EvidenceRoot 'tool-alias-original';$empty=Join-Path $EvidenceRoot 'empty-alias-target'
  [void][IO.Directory]::CreateDirectory($empty)
  $kind=if($IsWindows){'Junction'}else{'SymbolicLink'}
  try{
  $null=New-Item -ItemType $kind -Path $alias -Target (Split-Path $seed.tools.git.path -Parent)
  $v=Clone $seed;$v.tools.git.path=Join-Path $alias ([IO.Path]::GetFileName($seed.tools.git.path));$p=Store 'canonical-tool-alias' $v
  $c=Resolve $p -tools @('git')
  Assert ($c.Tools.git.Path-cne$v.tools.git.path) 'Selected alias was not resolved to canonical target'
  Assert ([IO.Path]::GetFullPath($alias).StartsWith([IO.Path]::GetFullPath($EvidenceRoot)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Owned alias boundary invalid'
  Rename-Item -LiteralPath $alias -NewName ([IO.Path]::GetFileName($retained))
  $null=New-Item -ItemType $kind -Path $alias -Target $empty
  Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {param($bound)$canonicalGitExecutable=[string]$bound.Tools.git.Path;$out=@(& $canonicalGitExecutable --version);Assert ($LASTEXITCODE-eq0-and$out.Count-gt0) 'Canonical target dispatch changed after alias retarget'} -ArgumentList @($c)
  Refusal {Resolve $p -tools @('git')} 'tool-missing'
  }finally{
   # Remove only the two links created by this case; never traverse their targets.
   foreach($link in @($alias,$retained)){
    if([IO.Directory]::Exists($link)){
     if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($link))-cne[IO.Path]::GetFullPath($EvidenceRoot)){throw 'Owned alias cleanup boundary differs'}
     if(([IO.File]::GetAttributes($link)-band[IO.FileAttributes]::ReparsePoint)-eq0){throw 'Owned alias cleanup requires a link'}
     [IO.Directory]::Delete($link)
    }
   }
  }
 }


 # A tiny owned Git fixture supplies honest source and ignored data-author outputs.
 $null=Fixture-Git @('init','-q')
 $null=Fixture-Git @('config','user.name','Quest Context Fixture')
 $null=Fixture-Git @('config','user.email','fixture@example.invalid')
 [IO.File]::WriteAllText((Join-Path $workingDirectory '.gitignore'),('*'+[Environment]::NewLine+'!.gitignore'+[Environment]::NewLine+'!build.ps1'+[Environment]::NewLine+'!unignored-context.json'+[Environment]::NewLine))
 $child=@'
param([string]$Output='.local/fixture.apk')
if(-not$env:RUSTC){throw 'Selected compiler environment missing'}
$path=Join-Path $PSScriptRoot $Output
[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
[IO.File]::WriteAllBytes($path,[byte[]]@(1,2,3,4))
[Console]::Out.WriteLine('finite-context-child')
[Console]::Error.WriteLine('finite-context-stderr')
'@
 [IO.File]::WriteAllText((Join-Path $workingDirectory 'build.ps1'),$child)
 $null=Fixture-Git @('add','--','.gitignore','build.ps1')
 $null=Fixture-Git @('commit','-q','-m','Owned finite build context fixture')
 $profile=[ordered]@{schema='rusty.morphospace.quest_build_profile.v1';profile_id='context-fixture';working_directory='.';executable='build.ps1';arguments=@('.local/fixture.apk');environment=@{};artifact=[ordered]@{relative_path='.local/fixture.apk';kind='single-base-apk'};preflight=[ordered]@{toolchain=[ordered]@{repository_files=@();required_targets=@($hostTarget)};environment_projection=[ordered]@{passthrough=@('PATH','HOME','SYSTEMROOT','SYSTEMDRIVE','USERPROFILE','COMSPEC','WINDIR','PATHEXT','TEMP','TMP','TMPDIR');prohibited_parent_variables=@()};output=[ordered]@{lane='warm';collision_policy='new-only';allow_source_root=$true}}}
 $profilePath=Store 'public-profile' $profile
 function Public([string]$mode,[string]$contextFile='', [string]$receipt=''){
  $argv=@('-NoProfile','-NonInteractive','-File',(Join-Path $RepoRoot 'scripts/Invoke-QuestBuildProfile.ps1'),'-Mode',$mode,'-ProfilePath',$profilePath,'-ProfileSha256',(Sha $profilePath),'-SourceRoot',$workingDirectory,'-WaitPolicy','Retained','-EstimatedWarningSeconds','30')
  if($contextFile){$argv+=@('-BuildContextPath',$contextFile,'-BuildContextSha256',(Sha $contextFile))}
  if($receipt){$argv+=@('-ReceiptPath',$receipt)}
  $lines=@(& $seedPwshExecutable @argv 2>&1);$exit=$LASTEXITCODE
  [pscustomobject]@{ExitCode=$exit;Result=(($lines|ForEach-Object{[string]$_})-join[Environment]::NewLine|ConvertFrom-Json -Depth 64 -DateKind String)}
 }
 Case 'public-context-preflight' {$r=Public 'Preflight' $valid;Assert ($r.ExitCode-eq0-and$r.Result.terminal_status-ceq'passed'-and-not$r.Result.child_process.started) 'Actual public context Preflight failed'}
 foreach($role in @('pwsh','rustup')){
  Case "public-compatibility-$role-path-precedence" {
   $duplicateDir=Join-Path $EvidenceRoot "duplicate-$role";[void][IO.Directory]::CreateDirectory($duplicateDir)
   $extension=[IO.Path]::GetExtension($seed.tools.$role.path)
   # Real executable files exercise multiple Application matches and the first selected tool.
   [IO.File]::Copy($seed.tools.git.path,(Join-Path $duplicateDir ($role+$extension)))
   $v=Clone $seed
   $entries=@((Split-Path $seed.tools.pwsh.path -Parent),(Split-Path $seed.tools.rustup.path -Parent),(Split-Path $seed.tools.git.path -Parent),$duplicateDir)
   if($IsWindows){$entries+=@((Join-Path $seed.environment.SYSTEMROOT 'System32'),[string]$seed.environment.SYSTEMROOT)}
   $v.environment.PATH=@($entries|Select-Object -Unique)-join[IO.Path]::PathSeparator
   $p=Store "compatibility-$role" $v;$c=Resolve $p -tools @('pwsh')
   $r=Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {param($name)$matches=@(Get-Command -Name $name -CommandType Application -ErrorAction Stop);Assert ($matches.Count-ge2) 'Actual multiple Application fixture absent';Public 'Preflight'} -ArgumentList @($role)
   Assert ($r.ExitCode-eq0-and$r.Result.terminal_status-ceq'passed'-and-not$r.Result.child_process.started) 'Ordinary no-context PATH precedence was not preserved'
   $explicit=Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {param($bound)Public 'Preflight' $bound} -ArgumentList @($p)
   Assert ($explicit.ExitCode-eq0-and$explicit.Result.terminal_status-ceq'passed') 'Explicit selection failed with actual lower-precedence Applications'
  }
 }
 Case 'same-module-ignored-data-author' {
  $toolPaths=@{};foreach($id in $seed.tools.PSObject.Properties.Name){$toolPaths[$id]=$seed.tools.$id.path}
  $c=Resolve $valid;$newPath=Join-Path $workingDirectory 'authored-context.json'
  $authored=Invoke-MorphospaceQuestBuildEnvironment -Context $c -Action {param($output,$tools,$channel)
   New-MorphospaceQuestBuildContext -OutputPath $output -SourceRoot $workingDirectory -EnvironmentVariableNames ([string[]]@($seed.environment.PSObject.Properties.Name)) -ToolPaths $tools -RustToolchainChannel $channel
  } -ArgumentList @($newPath,$toolPaths,[string]$seed.rust_toolchain.channel)
  Assert ((Sha $newPath)-ceq$authored.sha256-and-not$authored.execution_authority) 'Data author failed exact ignored output identity'
  $unignored=Join-Path $workingDirectory 'unignored-context.json'
  Refusal {New-MorphospaceQuestBuildContext -OutputPath $unignored -SourceRoot $workingDirectory -EnvironmentVariableNames @('PATH') -ToolPaths $toolPaths} 'context-output-not-ignored'
  Assert (-not(Test-Path -LiteralPath $unignored)) 'Refused unignored data was written'
  Refusal {New-MorphospaceQuestBuildContext -OutputPath $newPath -SourceRoot $workingDirectory -EnvironmentVariableNames @('PATH') -ToolPaths $toolPaths} 'context-input-invalid'
  $secretPath=Join-Path $workingDirectory 'secret-context.json'
  Refusal {New-MorphospaceQuestBuildContext -OutputPath $secretPath -SourceRoot $workingDirectory -EnvironmentVariableNames @('MORPHOSPACE_CAUSAL_SECRET') -ToolPaths $toolPaths} 'environment-invalid'
  Assert (-not(Test-Path -LiteralPath $secretPath)) 'Secret-named author input wrote output'
 }
 Case 'public-retained-finite-build' {
  $receipt=Join-Path $workingDirectory 'finite-build-receipt.json';$r=Public 'Build' $valid $receipt
  Assert ($r.ExitCode-eq0-and$r.Result.terminal_status-ceq'passed') 'Actual finite public Build failed'
  $cp=$r.Result.child_process
  Assert ($cp.started-and$cp.process_reaped-and$cp.stdout_eof-and$cp.stderr_eof-and$cp.raw_capture_complete-and$cp.exit_code-eq0) 'Actual retained finite closure incomplete'
  foreach($stream in @($r.Result.streams.stdout,$r.Result.streams.stderr)){Assert ((Sha $stream.path)-ceq$stream.sha256) 'Raw finite child stream differs'}
  Assert ((Get-Item -LiteralPath (Join-Path $workingDirectory '.local/fixture.apk')).Length-eq4) 'Fixture artifact missing; no APK proof claimed'
 }


}catch{$results.Add([ordered]@{case='production-api-bootstrap';status='failed';error_type=$_.Exception.GetType().FullName;reason_code=[string]$_.Exception.Data['ReasonCode']});[Console]::Error.WriteLine('Production API baseline unavailable or invalid; no causal cases credited.')}
$summary=[ordered]@{schema='task.durable_build_context_causal_cases.v1';production_module=$module;cases=@($results.ToArray());passed=@($results|Where-Object status -ceq passed).Count;failed=@($results|Where-Object status -ceq failed).Count;compiler_builds=0;device_actions=0;apk_proof=$false;real_compiler_mismatch_exercised=$script:RealCompilerMismatchExercised}
Assert-PrivacyJson ($summary|ConvertTo-Json -Depth 20 -Compress)
$p=Store 'RESULT' $summary
[Console]::Out.WriteLine(($summary|ConvertTo-Json -Depth 12 -Compress))
if($summary.failed-or$summary.passed-lt20){exit 1}
exit 0
