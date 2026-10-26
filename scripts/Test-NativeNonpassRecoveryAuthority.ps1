param([switch]$SelfTest,[string]$RecoveryAdapterPath='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path $PSScriptRoot -Parent
$modulePath=Join-Path $PSScriptRoot 'lib/NativeNonpassRecoveryAuthority.psm1'
if(-not(Test-Path -LiteralPath $modulePath)){throw 'Native recovery authority is missing: exact signed source-qualified recovery cannot be verified.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wef-native-authority-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
function Write-TestJson([string]$Path,[object]$Value){[IO.Directory]::CreateDirectory((Split-Path $Path -Parent))|Out-Null;[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 50 -Compress),[Text.UTF8Encoding]::new($false))}
function Copy-TestValue([object]$Value){$Value|ConvertTo-Json -Depth 50|ConvertFrom-Json -Depth 50 -DateKind String}
function Git([string]$At,[string[]]$Argv){$command=Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1;$result=@(& $command.Source -C $At @Argv 2>&1);if($LASTEXITCODE-ne0){throw "Fixture Git failed: $($result-join' ')"};($result-join"`n").Trim()}
function Init-Git([string]$At){[IO.Directory]::CreateDirectory($At)|Out-Null;Git $At @('init','-b','main')|Out-Null;Git $At @('config','user.name','Fixture')|Out-Null;Git $At @('config','user.email','fixture@example.invalid')|Out-Null;Git $At @('config','core.autocrlf','false')|Out-Null;Git $At @('remote','add','origin','https://github.com/MesmerPrism/rusty-morphospace-work-environment.git')|Out-Null}
function Commit-Git([string]$At,[string]$Message){Git $At @('add','--all')|Out-Null;Git $At @('commit','-m',$Message)|Out-Null;Git $At @('rev-parse','HEAD')}
function Assert-Test([bool]$Condition,[string]$Name){if(-not$Condition){throw "Authority self-test failed: $Name"}}
$script:cases=[Collections.Generic.List[string]]::new()
function Refuses([string]$Name,[scriptblock]$Action){$caught=$null;try{&$Action|Out-Null}catch{$caught=$_};if($caught-and$caught.Exception-is[Management.Automation.CommandNotFoundException]){throw $caught};Assert-Test ($null-ne$caught) "accepted $Name";$script:cases.Add($Name)}
function Invoke-TestAuthority([switch]$Execute){&$am {param($w,$r,$b,$run)Invoke-NativeNonpassRecoveryAuthority -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b -Execute:$run} $w $reqpath $b $Execute.IsPresent}
$rsa=[Security.Cryptography.RSA]::Create(2048)
try{
    $a=Join-Path $root 'authority';$b=Join-Path $root 'executor';$w=Join-Path $root 'workspace';$e=Join-Path $root 'evidence'
    Init-Git $a;Init-Git $b;[IO.Directory]::CreateDirectory($w)|Out-Null;[IO.Directory]::CreateDirectory($e)|Out-Null
    foreach($path in @('scripts/lib/NativeNonpassRecoveryAuthority.psm1','scripts/lib/ExternalOwnerAuthorization.psm1','scripts/Invoke-NativeNonpassRecoveryAuthority.ps1','config/native-nonpass-recovery-authority.json','schemas/native-nonpass-recovery-request-v1.schema.json','schemas/native-nonpass-recovery-authorization-v1.schema.json','schemas/native-nonpass-repair-qualification-v1.schema.json')){[IO.Directory]::CreateDirectory((Split-Path (Join-Path $a $path) -Parent))|Out-Null;[IO.File]::Copy((Join-Path $sourceRoot $path),(Join-Path $a $path))}
    $policy=Get-Content -LiteralPath (Join-Path $a 'config/native-nonpass-recovery-authority.json') -Raw|ConvertFrom-Json -DateKind String
    $policy.issuer_id='fixture-native-owner-v1';$policy.public_key_pem=$rsa.ExportSubjectPublicKeyInfoPem().Replace("`r",'');$policy.public_key_spki_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    Write-TestJson (Join-Path $a 'config/native-nonpass-recovery-authority.json') $policy
    Commit-Git $a 'independently adopted fixture policy'|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $b 'scripts'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $b 'README.md'),"original`n")
    [IO.Directory]::CreateDirectory((Join-Path $b 'admitted-subroot'))|Out-Null;[IO.File]::WriteAllText((Join-Path $b 'admitted-subroot/README.md'),"admitted product view`n")
    $base=Commit-Git $b 'base';Git $b @('checkout','-b','repair')|Out-Null
    # A real isolated process writes a marker; this is dispatcher evidence only,
    # never a substitute native lifecycle writer or an acceptance assertion.
    [IO.File]::WriteAllText((Join-Path $b 'scripts/Invoke-WorkUnitAutomation.ps1'),"param([string]`$Action,[string]`$WorkspaceRoot,[string]`$UnitId,[string]`$CandidateFreeze,[string]`$ExpectedCandidateFreezeSha256,[string]`$OutPath,[switch]`$Execute)`nif(-not`$Execute-or`$Action-cne'FreezeCandidate'){throw 'Unexpected dispatch'}`n[IO.File]::WriteAllText((Join-Path `$WorkspaceRoot 'dispatched.txt'),'actual isolated child')`n")
    $head=Commit-Git $b 'reviewed fixture repair';Git $b @('checkout','main')|Out-Null;Git $b @('merge','--no-ff','repair','-m','normal source landing')|Out-Null;$landing=Git $b @('rev-parse','HEAD');Git $b @('checkout','repair')|Out-Null
    $am=Import-Module (Join-Path $a 'scripts/lib/NativeNonpassRecoveryAuthority.psm1') -Force -PassThru
    $crypto=Import-Module (Join-Path $a 'scripts/lib/ExternalOwnerAuthorization.psm1') -Force -PassThru
    function Hash-File([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
    function Sign-Test([string]$Schema,[object]$Payload,[string]$Path){$canonical=&$crypto {param($v)Get-CanonicalAuthorizationBytes $v} $Payload;$signature=$rsa.SignData($canonical,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss);Write-TestJson $Path ([ordered]@{schema=$Schema;payload=$Payload;signature=[ordered]@{algorithm='RSA-PSS-SHA256';public_key_spki_sha256=$policy.public_key_spki_sha256;value_base64=[Convert]::ToBase64String($signature)}})}
    $now=[DateTimeOffset]::UtcNow;$issued=$now.AddSeconds(-5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");$expires=$now.AddMinutes(30).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    if($RecoveryAdapterPath){
        $fixtureAdapterPath=Join-Path (Join-Path $b 'scripts/lib') ([IO.Path]::GetFileName($RecoveryAdapterPath))
        [IO.Directory]::CreateDirectory((Join-Path $b 'scripts/lib'))|Out-Null;[IO.File]::Copy([IO.Path]::GetFullPath($RecoveryAdapterPath),$fixtureAdapterPath)
        [IO.File]::Copy((Join-Path $sourceRoot 'scripts/lib/MorphospaceProtocolCommon.psm1'),(Join-Path $b 'scripts/lib/MorphospaceProtocolCommon.psm1'))
        $allA=&$am {param($p)Get-NativeRecoverySourceIdentity $p} $a
        $anchor=[ordered]@{repository=$allA.repository;commit=$allA.commit;tree=$allA.tree;entrypoint='scripts/lib/NativeNonpassRecoveryAuthority.psm1';artifacts=@($allA.artifacts|ForEach-Object{[ordered]@{path=$_.path;mode=$_.mode;size_bytes=$_.size_bytes;sha256=$_.sha256}})}
        Write-TestJson (Join-Path $b 'config/native-nonpass-recovery-authority-binding.json') @{schema='rusty.morphospace.workflow.native_nonpass_recovery_authority_binding.v2';authorities=@($anchor)}
        $head=Commit-Git $b 'bind independently adopted fixture A';Git $b @('checkout','main')|Out-Null;Git $b @('reset','--hard',$base)|Out-Null;Git $b @('merge','--no-ff','repair','-m','normal bound source landing')|Out-Null;$landing=Git $b @('rev-parse','HEAD');Git $b @('checkout','repair')|Out-Null
        $adapter=Import-Module $fixtureAdapterPath -Force -PassThru
    }
    $sourceIdentity=&$am {param($p)Get-NativeRecoverySourceIdentity $p} $b
    $historicalIdentity=@(&$am {param($p,$h)Get-NativeRecoveryObjectSourceIdentity $p $h} $b $sourceIdentity.commit)
    Assert-Test ($historicalIdentity.Count-eq1) 'historical Git lookup emitted a task completion value'
    &$am {param($actual,$expected)Assert-NativeRecoveryEqual $actual $expected 'immutable Git versus physical executor closure'} $historicalIdentity[0] $sourceIdentity
    $script:cases.Add('immutable historical Git closure')
    $authorityIdentity=&$am {Get-NativeRecoveryAuthorityIdentity}
    $proofs=@();foreach($kind in $policy.required_qualification_evidence){$path=Join-Path $e "$kind.txt";[IO.File]::WriteAllText($path,"retained actual fixture $kind evidence`n");$proofs+=,[ordered]@{kind=$kind;path=[IO.Path]::GetFileName($path);size_bytes=([IO.FileInfo]$path).Length;sha256=Hash-File $path}}
    $qualification=[ordered]@{schema='rusty.morphospace.workflow.native_nonpass_repair_qualification_payload.v1';issuer_id=$policy.issuer_id;authorization_id='fixture-source-qualified-0001';issued_at=$issued;expires_at=$expires;decision='qualify-native-nonpass-repair-source';authority=$authorityIdentity;executor=$sourceIdentity;qualification_base_commit=$base;changed_artifacts=@(&$am {param($p,$r)Get-NativeRecoveryChangedArtifacts $p $r} $b $base);landing=[ordered]@{commit=$landing;tree=(Git $b @('rev-parse',"$landing`^{tree}"));parents=@($base,$head)};evidence=$proofs;limitations=@('source-qualification-only','no-native-state-change','no-unit-acceptance')}
    $qpath=Join-Path $e 'qualification.json';Sign-Test 'rusty.morphospace.workflow.native_nonpass_repair_qualification.v1' $qualification $qpath
    # These are signature/CAS boundary fixtures. Native origin/transaction proofs
    # remain mandatory in the independently tested B consumer, not claimed here.
    Write-TestJson (Join-Path $w 'project.spec.json') @{project_id='fixture-project'}
    Write-TestJson (Join-Path $w 'workspace.state.json') @{current_unit='u002';last_event_id='return-0138';next_ready_unit=$null}
    Write-TestJson (Join-Path $w 'iteration-units/u002.json') @{unit_id='u002';status='active'}
    Write-TestJson (Join-Path $w 'feature.lock.json') @{revision=1}
    [IO.File]::WriteAllText((Join-Path $w 'iteration-events.jsonl'),'{"event_id":"freeze-0136"}'+"`n"+'{"event_id":"begin-0137"}'+"`n"+'{"event_id":"return-0138"}'+"`n")
    Write-TestJson (Join-Path $w 'source-compositions/lock.json') @{lock_id='fixture-lock'};Write-TestJson (Join-Path $w 'local/map.json') @{repositories=@(@{repo_id='fixture';path=(Join-Path $b 'admitted-subroot')})}
    Write-TestJson (Join-Path $w 'receipts/old-freeze.json') @{freeze_id='old-freeze'};Write-TestJson (Join-Path $w 'receipts/retained-fail.json') @{result='fail';project_id='fixture-project';unit_id='u002';artifacts=@()}
    Init-Git $w;Commit-Git $w 'retained fixture preimage'|Out-Null
    $reqpath=Join-Path $e 'candidate.json';$cpath=Join-Path $e 'authorization.json'
    $request=[ordered]@{schema='rusty.morphospace.workflow.candidate_freeze.v4';freeze_id='fixture-corrective-freeze';project_id='fixture-project';unit_id='u002';expected=[ordered]@{source_composition_path='source-compositions/lock.json';repository_map_path='local/map.json'};final_repositories=@(@{repo_id='fixture';commit=$head;tree=$sourceIdentity.tree});predecessor=[ordered]@{freeze=@{freeze_id='old-freeze';receipt_path='receipts/old-freeze.json';receipt_sha256=Hash-File (Join-Path $w 'receipts/old-freeze.json')};return_event_id='return-0138';validation_receipt=@{path='receipts/retained-fail.json';sha256=Hash-File (Join-Path $w 'receipts/retained-fail.json')}};nonpass_custody_defect=@{artifacts=@(@{artifact_id='old-source';disposition='audit-inert-unavailable';validation_credit=$false;acceptance_credit=$false})};recovery_authorization=@{trusted_authority_root=$a;authorization_path=$cpath;source_qualification_path=$qpath}}
    Write-TestJson $reqpath $request
    $derived=New-NativeNonpassRecoveryAuthorizationRequest -WorkspaceRoot $w -RequestPath $reqpath -ExecutorRoot $b
    $payload=[ordered]@{schema='rusty.morphospace.workflow.native_nonpass_recovery_authorization_payload.v1';issuer_id=$policy.issuer_id;authorization_id='fixture-native-recovery-0001';issued_at=$issued;expires_at=$expires;decision='authorize-native-nonpass-custody-recovery';purpose='nonaccepting-corrective-freeze';request=$derived;limitations=@('no-pass-or-acceptance-credit','no-source-scope-extension','no-publication-or-runtime-authority')}
    Sign-Test 'rusty.morphospace.workflow.native_nonpass_recovery_authorization.v1' $payload $cpath
    $assessment=Invoke-TestAuthority
    Assert-Test ($assessment.schema-ceq'rusty.morphospace.workflow.native_nonpass_recovery_assessment.v1'-and-not$assessment.executed) 'verification result is typed and nonexecuting'
    Assert-Test (-not(Test-Path (Join-Path $w 'dispatched.txt'))) 'verify-only dispatched candidate';$script:cases.Add('verify-only no dispatch')
    $bindings=$derived.current_bindings;$bindings|Add-Member request_path $reqpath
    &$am {param($w,$r,$c,$b)Assert-MorphospaceNativeNonpassRecoveryAuthorization -WorkspaceRoot $w -Request $r -CurrentBindings $c -ExecutorRoot $b} $w $request $bindings $b|Out-Null
    if($RecoveryAdapterPath){
        &$adapter {param($w,$r,$c,$b)Assert-MorphospaceNativeNonpassRecoveryAuthorization -WorkspaceRoot $w -Request $r -CurrentBindings $c -ExecutorRoot $b} $w $request $bindings $b|Out-Null;$script:cases.Add('independently pinned B adapter')
        $bindingPath=Join-Path $b 'config/native-nonpass-recovery-authority-binding.json';$savedBinding=[IO.File]::ReadAllBytes($bindingPath);$savedPolicy=[IO.File]::ReadAllBytes((Join-Path $a 'config/native-nonpass-recovery-authority.json'));$savedModule=[IO.File]::ReadAllBytes((Join-Path $a 'scripts/lib/NativeNonpassRecoveryAuthority.psm1'))
        foreach($damage in @('missing-adopted-A','tampered-A-module','tampered-A-policy','fake-locator')){
            try{
                $badRequest=Copy-TestValue $request
                switch($damage){
                    'missing-adopted-A'{Write-TestJson $bindingPath @{schema='rusty.morphospace.workflow.native_nonpass_recovery_authority_binding.v1';authorities=@()}}
                    'tampered-A-module'{[IO.File]::AppendAllText((Join-Path $a 'scripts/lib/NativeNonpassRecoveryAuthority.psm1'),' ')}
                    'tampered-A-policy'{[IO.File]::AppendAllText((Join-Path $a 'config/native-nonpass-recovery-authority.json'),' ')}
                    'fake-locator'{$badRequest.recovery_authorization.trusted_authority_root=$b}
                }
                Refuses $damage {&$adapter {param($w,$r,$c,$b)Assert-MorphospaceNativeNonpassRecoveryAuthorization -WorkspaceRoot $w -Request $r -CurrentBindings $c -ExecutorRoot $b} $w $badRequest $bindings $b}
            }finally{[IO.File]::WriteAllBytes($bindingPath,$savedBinding);[IO.File]::WriteAllBytes((Join-Path $a 'config/native-nonpass-recovery-authority.json'),$savedPolicy);[IO.File]::WriteAllBytes((Join-Path $a 'scripts/lib/NativeNonpassRecoveryAuthority.psm1'),$savedModule)}
        }
    }
    foreach($case in @('wrong-purpose','wrong-head','wrong-tree','wrong-pathset','changed-defect','extra-defect','wrong-policy','expiry','wrong-signer','missing-authorization','accepted-target','stale-state','replay')){
        $oldRequest=[IO.File]::ReadAllBytes($reqpath);$oldAuth=[IO.File]::ReadAllBytes($cpath);$oldQ=[IO.File]::ReadAllBytes($qpath);$oldState=[IO.File]::ReadAllBytes((Join-Path $w 'workspace.state.json'));$oldUnit=[IO.File]::ReadAllBytes((Join-Path $w 'iteration-units/u002.json'))
        try{
            $changed=Copy-TestValue $payload;$qr=Copy-TestValue $qualification;$rr=Copy-TestValue $request
            switch($case){
                'wrong-purpose'{$changed.purpose='accept-current-unit';Sign-Test 'rusty.morphospace.workflow.native_nonpass_recovery_authorization.v1' $changed $cpath}
                'wrong-head'{$qr.executor.commit='1'*40;Sign-Test 'rusty.morphospace.workflow.native_nonpass_repair_qualification.v1' $qr $qpath}
                'wrong-tree'{$qr.executor.tree='2'*40;Sign-Test 'rusty.morphospace.workflow.native_nonpass_repair_qualification.v1' $qr $qpath}
                'wrong-pathset'{$qr.changed_artifacts=@();Sign-Test 'rusty.morphospace.workflow.native_nonpass_repair_qualification.v1' $qr $qpath}
                'changed-defect'{$rr.nonpass_custody_defect.artifacts[0].artifact_id='other';Write-TestJson $reqpath $rr}
                'extra-defect'{$rr.nonpass_custody_defect.artifacts+=@{artifact_id='extra'};Write-TestJson $reqpath $rr}
                'wrong-policy'{$qr.authority.policy_sha256='3'*64;Sign-Test 'rusty.morphospace.workflow.native_nonpass_repair_qualification.v1' $qr $qpath}
                'expiry'{$changed.issued_at=$now.AddDays(-2).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");$changed.expires_at=$now.AddDays(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");Sign-Test 'rusty.morphospace.workflow.native_nonpass_recovery_authorization.v1' $changed $cpath}
                'wrong-signer'{$bad=Get-Content $cpath -Raw|ConvertFrom-Json -Depth 50;$bad.signature.public_key_spki_sha256='4'*64;Write-TestJson $cpath $bad}
                'missing-authorization'{[IO.File]::Delete($cpath)}
                'accepted-target'{Write-TestJson (Join-Path $w 'iteration-units/u002.json') @{unit_id='u002';status='accepted'}}
                'stale-state'{[IO.File]::AppendAllText((Join-Path $w 'workspace.state.json'),' ')}
                'replay'{Write-TestJson (Join-Path $w 'workspace.state.json') @{current_unit='u002';last_event_id='corrected-0139';next_ready_unit=$null}}
            }
            Refuses $case {Invoke-TestAuthority -Execute}
            Assert-Test (-not(Test-Path (Join-Path $w 'dispatched.txt'))) "refusal dispatched $case"
        }finally{[IO.File]::WriteAllBytes($reqpath,$oldRequest);[IO.File]::WriteAllBytes($cpath,$oldAuth);[IO.File]::WriteAllBytes($qpath,$oldQ);[IO.File]::WriteAllBytes((Join-Path $w 'workspace.state.json'),$oldState);[IO.File]::WriteAllBytes((Join-Path $w 'iteration-units/u002.json'),$oldUnit)}
    }
    $executed=Invoke-TestAuthority -Execute
    Assert-Test ($executed.executed-and$executed.exit_code-eq0-and(Test-Path (Join-Path $w 'dispatched.txt'))) 'valid exact authorization did not dispatch isolated child';$script:cases.Add('exact qualified isolated child')
    [ordered]@{schema='rusty.morphospace.test.native_nonpass_recovery_authority.v1';result='pass';cases=@($script:cases);native_lifecycle_acceptance_claim=$false}|ConvertTo-Json -Depth 8
}finally{$rsa.Dispose();$full=[IO.Path]::GetFullPath($root);if([IO.Path]::GetDirectoryName($full)-cne[IO.Path]::GetTempPath().TrimEnd('\','/')-or[IO.Path]::GetFileName($full)-cnotmatch'^wef-native-authority-[0-9a-f]{32}$'){throw 'Unsafe fixture cleanup'};if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}}
