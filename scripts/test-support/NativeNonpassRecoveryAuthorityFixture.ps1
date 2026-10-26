# Test-only ephemeral authority and signatures. Never dot-source from production
# code. Every Git write stays in an explicitly owned disposable fixture root.
Set-StrictMode -Version Latest
function Invoke-NativeAuthorityFixtureGit([string]$Root,[string[]]$Argv){$command=Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1;$output=@(& $command.Source -C $Root @Argv 2>&1);if($LASTEXITCODE-ne0){throw "Native authority fixture Git failed: $($output-join' ')"};($output-join"`n").Trim()}
function Write-NativeAuthorityFixtureJson([string]$Path,[object]$Value){[IO.Directory]::CreateDirectory((Split-Path $Path -Parent))|Out-Null;[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 60 -Compress),[Text.UTF8Encoding]::new($false))}
function Assert-NativeAuthorityFixtureChild([string]$Root,[string]$Path){$parent=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;$child=[IO.Path]::GetFullPath($Path);if(-not$child.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)){throw 'Native authority fixture refuses a write outside its explicit disposable parent.'};$child}
function New-NativeNonpassRecoveryAuthorityFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AuthoritySourceRoot,[Parameter(Mandatory)][string]$ExecutorRoot,[Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)][string]$RecoveryAdapterPath)
    $executor=Assert-NativeAuthorityFixtureChild $FixtureRoot $ExecutorRoot
    $a=Assert-NativeAuthorityFixtureChild $FixtureRoot (Join-Path $FixtureRoot ('authority-'+[guid]::NewGuid().ToString('N')))
    $e=Assert-NativeAuthorityFixtureChild $FixtureRoot (Join-Path $FixtureRoot ('authority-evidence-'+[guid]::NewGuid().ToString('N')))
    if([string]::Equals([IO.Path]::GetFullPath($AuthoritySourceRoot),$executor,[StringComparison]::OrdinalIgnoreCase)){throw 'Native authority fixture source and executor must be separate.'}
    [IO.Directory]::CreateDirectory($a)|Out-Null;[IO.Directory]::CreateDirectory($e)|Out-Null
    $selected=@((Invoke-NativeAuthorityFixtureGit $AuthoritySourceRoot @('ls-files','-z')).Split([char]0,[StringSplitOptions]::RemoveEmptyEntries))+@('config/native-nonpass-recovery-authority.json','schemas/native-nonpass-recovery-request-v1.schema.json','schemas/native-nonpass-recovery-authorization-v1.schema.json','schemas/native-nonpass-repair-qualification-v1.schema.json','scripts/lib/NativeNonpassRecoveryAuthority.psm1','scripts/Invoke-NativeNonpassRecoveryAuthority.ps1','scripts/Test-NativeNonpassRecoveryAuthority.ps1','scripts/test-support/NativeNonpassRecoveryAuthorityFixture.ps1','docs/NATIVE_NONPASS_RECOVERY_AUTHORITY.md')
    $selected+=@('scripts/Test-NativeNonpassRecoveryProjection.ps1','scripts/Test-NativeNonpassRecoverySourceScope.ps1')
    foreach($path in @($selected|Select-Object -Unique)){if($path-match'(^|/)\.\.(/|$)|^[\\/]|[\x00-\x1f]'){throw 'Native authority fixture source path is unsafe.'};$from=Join-Path $AuthoritySourceRoot $path;$to=Join-Path $a $path;if(-not[IO.File]::Exists($from)){throw 'Native authority fixture selected source is absent.'};[IO.Directory]::CreateDirectory((Split-Path $to -Parent))|Out-Null;[IO.File]::Copy($from,$to,$false)}
    $rsa=[Security.Cryptography.RSA]::Create(2048);$policy=Get-Content -LiteralPath (Join-Path $a 'config/native-nonpass-recovery-authority.json') -Raw|ConvertFrom-Json -DateKind String
    $policy.issuer_id='fixture-native-owner-v1';$policy.public_key_pem=$rsa.ExportSubjectPublicKeyInfoPem().Replace("`r",'');$policy.public_key_spki_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    Write-NativeAuthorityFixtureJson (Join-Path $a 'config/native-nonpass-recovery-authority.json') $policy
    foreach($root in @($a,$executor)){
        if(-not(Test-Path -LiteralPath (Join-Path $root '.git'))){Invoke-NativeAuthorityFixtureGit $root @('init','-b','main')|Out-Null}
        Invoke-NativeAuthorityFixtureGit $root @('config','user.name','Fixture')|Out-Null;Invoke-NativeAuthorityFixtureGit $root @('config','user.email','fixture@example.invalid')|Out-Null;Invoke-NativeAuthorityFixtureGit $root @('config','core.autocrlf','false')|Out-Null
        $remotes=Invoke-NativeAuthorityFixtureGit $root @('remote');if($remotes.Split("`n")-contains'origin'){Invoke-NativeAuthorityFixtureGit $root @('remote','set-url','origin','https://github.com/MesmerPrism/rusty-morphospace-work-environment.git')|Out-Null}else{Invoke-NativeAuthorityFixtureGit $root @('remote','add','origin','https://github.com/MesmerPrism/rusty-morphospace-work-environment.git')|Out-Null}
        Invoke-NativeAuthorityFixtureGit $root @('add','--all')|Out-Null;Invoke-NativeAuthorityFixtureGit $root @('commit','--allow-empty','-m','disposable independently reviewed source fixture')|Out-Null
        Invoke-NativeAuthorityFixtureGit $root @('checkout-index','--all','--force')|Out-Null
    }
    $module=Import-Module (Join-Path $a 'scripts/lib/NativeNonpassRecoveryAuthority.psm1') -Force -PassThru
    $source=&$module {param($r)Get-NativeRecoverySourceIdentity $r} $a
    $base=Invoke-NativeAuthorityFixtureGit $executor @('rev-parse','HEAD');$branch='authority-fixture-'+[guid]::NewGuid().ToString('N');Invoke-NativeAuthorityFixtureGit $executor @('checkout','-b',$branch)|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $executor 'scripts/lib'))|Out-Null;[IO.File]::Copy([IO.Path]::GetFullPath($RecoveryAdapterPath),(Join-Path $executor 'scripts/lib/MorphospaceNativeNonpassRecoveryAuthorization.psm1'),$true)
    $anchor=[ordered]@{repository=$source.repository;commit=$source.commit;tree=$source.tree;entrypoint='scripts/lib/NativeNonpassRecoveryAuthority.psm1';artifacts=@($source.artifacts|ForEach-Object{[ordered]@{path=$_.path;mode=$_.mode;size_bytes=$_.size_bytes;sha256=$_.sha256}})}
    Write-NativeAuthorityFixtureJson (Join-Path $executor 'config/native-nonpass-recovery-authority-binding.json') @{schema='rusty.morphospace.workflow.native_nonpass_recovery_authority_binding.v2';authorities=@($anchor)}
    Invoke-NativeAuthorityFixtureGit $executor @('add','--all')|Out-Null;Invoke-NativeAuthorityFixtureGit $executor @('commit','-m','independently pin complete ephemeral authority')|Out-Null;$head=Invoke-NativeAuthorityFixtureGit $executor @('rev-parse','HEAD')
    Invoke-NativeAuthorityFixtureGit $executor @('checkout-index','--all','--force')|Out-Null
    Invoke-NativeAuthorityFixtureGit $executor @('checkout','-b',($branch+'-landing'),$base)|Out-Null;Invoke-NativeAuthorityFixtureGit $executor @('merge','--no-ff',$branch,'-m','normal independent fixture source landing')|Out-Null;$landing=Invoke-NativeAuthorityFixtureGit $executor @('rev-parse','HEAD');Invoke-NativeAuthorityFixtureGit $executor @('checkout',$branch)|Out-Null
    [pscustomobject]@{authority_root=$a;executor_root=$executor;evidence_root=$e;fixture_root=[IO.Path]::GetFullPath($FixtureRoot);rsa=$rsa;policy=$policy;module=$module;qualification_base=$base;executor_commit=$head;landing_commit=$landing}
}

function Set-NativeNonpassRecoveryFixtureAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Fixture,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath)
    $null=Assert-NativeAuthorityFixtureChild $Fixture.fixture_root $WorkspaceRoot;$null=Assert-NativeAuthorityFixtureChild $Fixture.fixture_root $RequestPath
    $directory=Join-Path $Fixture.evidence_root ([guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($directory)|Out-Null
    $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json -Depth 60 -DateKind String
    $qpath=Join-Path $directory 'source-qualification.json';$cpath=Join-Path $directory 'recovery-authorization.json'
    $request.recovery_authorization=[pscustomobject]@{trusted_authority_root=$Fixture.authority_root;source_qualification_path=$qpath;authorization_path=$cpath};Write-NativeAuthorityFixtureJson $RequestPath $request
    $module=$Fixture.module;$crypto=Import-Module (Join-Path $Fixture.authority_root 'scripts/lib/ExternalOwnerAuthorization.psm1') -PassThru
    function Write-FixtureSignedDocument([string]$Schema,[object]$Payload,[string]$Path){$bytes=&$crypto {param($p)Get-CanonicalAuthorizationBytes $p} $Payload;$signed=$Fixture.rsa.SignData($bytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss);Write-NativeAuthorityFixtureJson $Path ([ordered]@{schema=$Schema;payload=$Payload;signature=[ordered]@{algorithm='RSA-PSS-SHA256';public_key_spki_sha256=$Fixture.policy.public_key_spki_sha256;value_base64=[Convert]::ToBase64String($signed)}})}
    $now=[datetimeoffset]::UtcNow;$issued=$now.AddSeconds(-5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");$expires=$now.AddHours(4).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $authority=&$module {Get-NativeRecoveryAuthorityIdentity};$executor=&$module {param($r)Get-NativeRecoverySourceIdentity $r} $Fixture.executor_root
    $evidence=@();foreach($kind in $Fixture.policy.required_qualification_evidence){$p=Join-Path $directory "$kind.txt";[IO.File]::WriteAllText($p,"Ephemeral fixture source qualification attestation: $kind. No production CI, source adoption or native acceptance claimed.`n");$evidence+=,[ordered]@{kind=$kind;path=[IO.Path]::GetFileName($p);size_bytes=([IO.FileInfo]$p).Length;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant()}}
    $q=[ordered]@{schema='rusty.morphospace.workflow.native_nonpass_repair_qualification_payload.v1';issuer_id=$Fixture.policy.issuer_id;authorization_id=('fixture-source-'+[guid]::NewGuid().ToString('N'));issued_at=$issued;expires_at=$expires;decision='qualify-native-nonpass-repair-source';authority=$authority;executor=$executor;qualification_base_commit=$Fixture.qualification_base;changed_artifacts=@(&$module {param($r,$b)Get-NativeRecoveryChangedArtifacts $r $b} $Fixture.executor_root $Fixture.qualification_base);landing=[ordered]@{commit=$Fixture.landing_commit;tree=$executor.tree;parents=@($Fixture.qualification_base,$Fixture.executor_commit)};evidence=$evidence;limitations=@('source-qualification-only','no-native-state-change','no-unit-acceptance')}
    Write-FixtureSignedDocument 'rusty.morphospace.workflow.native_nonpass_repair_qualification.v1' $q $qpath
    $derived=&$module {param($w,$r,$b)New-NativeNonpassRecoveryAuthorizationRequest -WorkspaceRoot $w -RequestPath $r -ExecutorRoot $b} $WorkspaceRoot $RequestPath $Fixture.executor_root
    $c=[ordered]@{schema='rusty.morphospace.workflow.native_nonpass_recovery_authorization_payload.v1';issuer_id=$Fixture.policy.issuer_id;authorization_id=('fixture-recovery-'+[guid]::NewGuid().ToString('N'));issued_at=$issued;expires_at=$expires;decision='authorize-native-nonpass-custody-recovery';purpose='nonaccepting-corrective-freeze';request=$derived;limitations=@('no-pass-or-acceptance-credit','no-source-scope-extension','no-publication-or-runtime-authority')}
    Write-FixtureSignedDocument 'rusty.morphospace.workflow.native_nonpass_recovery_authorization.v1' $c $cpath
    [pscustomobject]@{request_path=$RequestPath;request_raw_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $RequestPath).Hash.ToLowerInvariant();authorization_path=$cpath;source_qualification_path=$qpath;derived=$derived}
}
