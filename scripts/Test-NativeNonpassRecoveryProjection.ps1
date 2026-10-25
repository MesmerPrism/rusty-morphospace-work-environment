param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$core=Import-Module (Join-Path $PSScriptRoot 'lib/NativeNonpassRecoveryAuthority.psm1') -PassThru -Force
$native=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$legal=[pscustomobject]@{schema='projection-fixture';objective="Operator's <compatible> café λ";values=@('plain',"Apostrophe's",'<tag>')}
$expected=&$native {param($v)Get-MorphospaceCanonicalJsonSha256 $v} $legal
$actual=&$core {param($v)if(Get-Command Get-NativeRecoveryProjectionDigest -ErrorAction SilentlyContinue){Get-NativeRecoveryProjectionDigest $v}else{Get-NativeRecoveryValueDigest $v}} $legal
if($actual-cne$expected){throw 'Pending legal native projection was compared with the signing canonical hash.'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('native-recovery-context-denial-'+[guid]::NewGuid().ToString('N'))
try{
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'iteration-units'))|Out-Null
    $documents=[ordered]@{'project.spec.json'=@{project_id='scope-fixture'};'workspace.state.json'=@{current_unit='u002';last_event_id='return-0138';next_ready_unit=$null;blockers=@();pending_push_bundle=$null};'iteration-units/u002.json'=@{unit_id='u002';status='active';tooling_context=$null};'feature.lock.json'=@{revision=1};'source.json'=@{lock_id='fixture-source'};'map.json'=@{repositories=@()};'iteration-events.jsonl'=@{event_id='return-0138'}}
    foreach($path in $documents.Keys){[IO.File]::WriteAllText((Join-Path $fixture $path),($documents[$path]|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))}
    $before=@($documents.Keys|ForEach-Object{(Get-FileHash -LiteralPath (Join-Path $fixture $_) -Algorithm SHA256).Hash})-join'|'
    $request=[pscustomobject]@{project_id='scope-fixture';unit_id='u002';expected=[pscustomobject]@{source_composition_path='source.json';repository_map_path='map.json'}}
    $caught=$null;try{&$core {param($w,$r)Get-NativeRecoveryCurrentBindings $w $r} $fixture $request|Out-Null}catch{$caught=$_}
    if($null-eq$caught-or-not$caught.Exception.Message.Contains('supports only an uncontexted unit',[StringComparison]::Ordinal)){throw 'Contexted unit was not explicitly refused by the current-binding owner.'}
    $after=@($documents.Keys|ForEach-Object{(Get-FileHash -LiteralPath (Join-Path $fixture $_) -Algorithm SHA256).Hash})-join'|'
    if($before-cne$after-or@(Get-ChildItem -LiteralPath $fixture -File -Recurse).Count-ne$documents.Count){throw 'Unsupported context refusal wrote fixture controls.'}
}finally{
    $full=[IO.Path]::GetFullPath($fixture);if([IO.Path]::GetDirectoryName($full)-cne[IO.Path]::GetTempPath().TrimEnd('\','/')-or[IO.Path]::GetFileName($full)-cnotmatch'^native-recovery-context-denial-[0-9a-f]{32}$'){throw 'Unsafe context-denial fixture cleanup'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
[ordered]@{schema='rusty.morphospace.test.native_projection_hash.v1';result='pass';native_projection=$true;signing_canonicalization_changed=$false;unsupported_context_no_write=$true}|ConvertTo-Json
