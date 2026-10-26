param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('nonpass-binding-origin-'+[guid]::NewGuid().ToString('N'))
function Binding-Git([string]$At,[string[]]$Argv){$command=Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1;$out=@(& $command.Source -C $At @Argv 2>&1);if($LASTEXITCODE-ne0){throw "Binding fixture Git failed: $($out-join' ')"};($out-join"`n").Trim()}
function Binding-Init([string]$At){[IO.Directory]::CreateDirectory($At)|Out-Null;Binding-Git $At @('init','-b','main')|Out-Null;Binding-Git $At @('config','user.name','Fixture')|Out-Null;Binding-Git $At @('config','user.email','fixture@example.invalid')|Out-Null;Binding-Git $At @('config','core.autocrlf','false')|Out-Null;Binding-Git $At @('remote','add','origin','https://github.com/MesmerPrism/rusty-morphospace-work-environment.git')|Out-Null}
try{
    $a=Join-Path $fixture 'untrusted-authority';$b=Join-Path $fixture 'executor';$w=Join-Path $fixture 'workspace';$marker=Join-Path $fixture 'UNTRUSTED_IMPORT'
    Binding-Init $a;Binding-Init $b;[IO.Directory]::CreateDirectory($w)|Out-Null
    $relative='scripts/lib/NativeNonpassRecoveryAuthority.psm1';$path=Join-Path $a $relative
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null
    $escaped=$marker.Replace("'","''")
    [IO.File]::WriteAllText($path,"[IO.File]::WriteAllText('$escaped','untrusted import')`nfunction Assert-MorphospaceNativeNonpassRecoveryAuthorization { param(`$WorkspaceRoot,`$Request,`$CurrentBindings,`$ExecutorRoot) }`nExport-ModuleMember -Function Assert-MorphospaceNativeNonpassRecoveryAuthorization`n",[Text.UTF8Encoding]::new($false))
    Binding-Git $a @('add','.')|Out-Null;Binding-Git $a @('commit','-qm','Deliberately untrusted authority damage fixture')|Out-Null
    $anchor=[ordered]@{repository='MesmerPrism/rusty-morphospace-work-environment';commit=Binding-Git $a @('rev-parse','HEAD');tree=Binding-Git $a @('rev-parse','HEAD^{tree}');artifacts=@([ordered]@{path=$relative;mode='100644';size_bytes=([IO.FileInfo]$path).Length;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()})}
    foreach($file in @('scripts/lib/MorphospaceNativeNonpassRecoveryAuthorization.psm1','scripts/lib/MorphospaceProtocolCommon.psm1')){$target=Join-Path $b $file;[IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null;[IO.File]::Copy((Join-Path $source $file),$target)}
    $bindingPath=Join-Path $b 'config/native-nonpass-recovery-authority-binding.json';[IO.Directory]::CreateDirectory((Split-Path $bindingPath -Parent))|Out-Null
    $binding=[ordered]@{schema='rusty.morphospace.workflow.native_nonpass_recovery_authority_binding.v2';authorities=@()}
    [IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    Binding-Git $b @('add','.')|Out-Null;Binding-Git $b @('commit','-qm','Genuine committed unconfigured program binding')|Out-Null
    # Only after the real program checkpoint, substitute uncommitted policy.
    $binding.authorities=@($anchor);[IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $module=Import-Module (Join-Path $b 'scripts/lib/MorphospaceNativeNonpassRecoveryAuthorization.psm1') -PassThru -Force
    foreach($hideFromStatus in @($false,$true)){
        if($hideFromStatus){Binding-Git $b @('update-index','--assume-unchanged','--','config/native-nonpass-recovery-authority-binding.json')|Out-Null}
        $caught=$null
        try{&$module {param($w,$a,$b) Assert-MorphospaceNativeNonpassRecoveryAuthorization -WorkspaceRoot $w -Request ([pscustomobject]@{recovery_authorization=[pscustomobject]@{trusted_authority_root=$a}}) -CurrentBindings ([pscustomobject]@{}) -ExecutorRoot $b} $w $a $b}catch{$caught=$_}
        if([IO.File]::Exists($marker)){throw 'Mutable B binding imported its attacker-selected authority before program-origin authentication.'}
        if($null-eq$caught){throw 'Mutable B authority binding was not refused.'}
    }
    # Commit the owner data for each case. No request can choose this entrypoint.
    $anchor.entrypoint=$relative
    $validBinding=$binding|ConvertTo-Json -Depth 12
    Binding-Git $b @('update-index','--no-assume-unchanged','--','config/native-nonpass-recovery-authority-binding.json')|Out-Null
    foreach($case in @('configured-v1','missing-entrypoint','unsafe-entrypoint','nonmodule-entrypoint','absent-entrypoint')){
        $damaged=$validBinding|ConvertFrom-Json -Depth 12
        switch($case){
            'configured-v1'{$damaged.schema='rusty.morphospace.workflow.native_nonpass_recovery_authority_binding.v1'}
            'missing-entrypoint'{$damaged.authorities[0].PSObject.Properties.Remove('entrypoint')}
            'unsafe-entrypoint'{$damaged.authorities[0].entrypoint='../outside.psm1'}
            'nonmodule-entrypoint'{$damaged.authorities[0].entrypoint='scripts/lib/authority.json'}
            'absent-entrypoint'{$damaged.authorities[0].entrypoint='scripts/lib/AbsentAuthority.psm1'}
        }
        [IO.File]::WriteAllText($bindingPath,($damaged|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        Binding-Git $b @('add','.')|Out-Null;Binding-Git $b @('commit','--allow-empty','-qm',"Committed binding denial $case")|Out-Null
        $caught=$null
        try{&$module {param($w,$a) $opened=Open-PinnedRecoveryAuthority ([pscustomobject]@{recovery_authorization=[pscustomobject]@{trusted_authority_root=$a}}) $w;foreach($hold in $opened.holds){$hold.Dispose()}} $w $a}catch{$caught=$_}
        if($null-eq$caught-or[IO.File]::Exists($marker)){throw "Binding entrypoint denial failed before import: $case"}
    }
    # A positive source-only fixture exports the exact finite interface. It
    # proves the selected committed entrypoint, not a native authorization.
    $names=@('New-NativeNonpassRecoveryAuthorizationRequest','Assert-MorphospaceNativeNonpassRecoveryAuthorization','Assert-MorphospaceNativeNonpassRecoveryHistory','Invoke-NativeNonpassRecoveryAuthority')
    $body="[IO.File]::WriteAllText('$escaped','verified import')`n"+(@($names|ForEach-Object{"function $_ { }"})-join"`n")+"`nExport-ModuleMember -Function "+($names-join',')+"`n"
    [IO.File]::WriteAllText($path,$body,[Text.UTF8Encoding]::new($false));Binding-Git $a @('add','.')|Out-Null;Binding-Git $a @('commit','-qm','Finite adopted entrypoint source fixture')|Out-Null
    $anchor.commit=Binding-Git $a @('rev-parse','HEAD');$anchor.tree=Binding-Git $a @('rev-parse','HEAD^{tree}');$anchor.artifacts[0].size_bytes=([IO.FileInfo]$path).Length;$anchor.artifacts[0].sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    $binding.authorities=@($anchor);[IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));Binding-Git $b @('add','.')|Out-Null;Binding-Git $b @('commit','-qm','Adopt exact protected entrypoint data')|Out-Null
    $opened=$null
    try{$opened=&$module {param($w,$a) Open-PinnedRecoveryAuthority ([pscustomobject]@{recovery_authorization=[pscustomobject]@{trusted_authority_root=$a;entrypoint='ignored-request-path.psm1'}}) $w} $w $a;if(-not[IO.File]::Exists($marker)-or$opened.module.Path-cne$path){throw 'Protected binding did not select its exact verified entrypoint.'}}finally{if($null-ne$opened){foreach($hold in $opened.holds){$hold.Dispose()}}}
    $probe=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$probe.Dispose()
    [IO.File]::WriteAllText($path,$body.Replace(',Invoke-NativeNonpassRecoveryAuthority',''),[Text.UTF8Encoding]::new($false));Binding-Git $a @('add','.')|Out-Null;Binding-Git $a @('commit','-qm','Missing fixed export damage')|Out-Null
    $anchor.commit=Binding-Git $a @('rev-parse','HEAD');$anchor.tree=Binding-Git $a @('rev-parse','HEAD^{tree}');$anchor.artifacts[0].size_bytes=([IO.FileInfo]$path).Length;$anchor.artifacts[0].sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));Binding-Git $b @('add','.')|Out-Null;Binding-Git $b @('commit','-qm','Adopt fixed export damage source')|Out-Null
    $caught=$null
    try{&$module {param($w,$a) $opened=Open-PinnedRecoveryAuthority ([pscustomobject]@{recovery_authorization=[pscustomobject]@{trusted_authority_root=$a}}) $w;foreach($hold in $opened.holds){$hold.Dispose()}} $w $a}catch{$caught=$_}
    if($null-eq$caught-or$caught.Exception.Message-cne'Recovery authority entrypoint lacks its fixed native function interface.'){throw 'Missing fixed native export was not refused.'}
    $probe=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$probe.Dispose()
    [ordered]@{schema='rusty.morphospace.test.nonpass_binding_origin.v1';result='pass';untrusted_import=$false;committed_entrypoint_import=$true;entrypoint_denials=5;fixed_export_refusal=$true;source_holds_released=$true;native_effect=$false}|ConvertTo-Json
}finally{
    if(Test-Path -LiteralPath $fixture){$full=[IO.Path]::GetFullPath((Get-Item -LiteralPath $fixture).FullName);if([IO.Path]::GetDirectoryName($full)-cne[IO.Path]::GetTempPath().TrimEnd('\','/')-or[IO.Path]::GetFileName($full)-cnotmatch'^nonpass-binding-origin-[0-9a-f]{32}$'){throw 'Unsafe binding-origin fixture cleanup.'};Remove-Item -LiteralPath $full -Recurse -Force}
}
