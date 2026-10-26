param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ExecutorRoot,[Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$FixtureRoot,[string]$ConsumerSourceRoot,[switch]$AllShapes,[string]$PassReceiptPath)
$ErrorActionPreference='Stop'
if($ConsumerSourceRoot){
    $fixture=[IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not[IO.Path]::GetFullPath($ExecutorRoot).StartsWith($fixture,[StringComparison]::OrdinalIgnoreCase)){throw 'The historical consumer source escaped its disposable fixture.'}
    $consumer=Join-Path $FixtureRoot ('historical-reader-'+[guid]::NewGuid().ToString('N'))
    function Invoke-HistoricalShapeGit([string]$At,[string[]]$Argv){
        $process=[Diagnostics.Process]::new();$process.StartInfo=[Diagnostics.ProcessStartInfo]::new()
        $process.StartInfo.FileName=(@(Get-Command git -CommandType Application)[0]).Source;$process.StartInfo.WorkingDirectory=$At;$process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
        $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
        foreach($name in @($process.StartInfo.Environment.Keys)){if($name-match'^GIT_'){$process.StartInfo.Environment.Remove($name)|Out-Null}}
        $process.StartInfo.Environment['GIT_CONFIG_NOSYSTEM']='1';$process.StartInfo.Environment['GIT_CONFIG_GLOBAL']=if($IsWindows){'NUL'}else{'/dev/null'}
        foreach($arg in @('--no-optional-locks','--no-replace-objects','-c','core.hooksPath=')+$Argv){$process.StartInfo.ArgumentList.Add($arg)}
        try{$null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit();$result=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult();if($process.ExitCode-ne0){throw "Historical fixture Git failed: $errorText"};$result.Trim()}finally{$process.Dispose()}
    }
    Invoke-HistoricalShapeGit $FixtureRoot @('clone','--no-hardlinks','--config','core.autocrlf=false',$ExecutorRoot,$consumer)|Out-Null
    Invoke-HistoricalShapeGit $consumer @('config','user.name','Historical reader fixture')|Out-Null;Invoke-HistoricalShapeGit $consumer @('config','user.email','fixture@example.invalid')|Out-Null
    Invoke-HistoricalShapeGit $consumer @('remote','set-url','origin','https://github.com/MesmerPrism/rusty-morphospace-work-environment.git')|Out-Null
    [IO.File]::Copy((Join-Path $ConsumerSourceRoot 'scripts/lib/MorphospaceNonpassCustodyCorrection.psm1'),(Join-Path $consumer 'scripts/lib/MorphospaceNonpassCustodyCorrection.psm1'),$true)
    Invoke-HistoricalShapeGit $consumer @('add','scripts/lib/MorphospaceNonpassCustodyCorrection.psm1')|Out-Null
    Invoke-HistoricalShapeGit $consumer @('commit','-m','Fixture historical reader evolution only; no new source qualification or native effect')|Out-Null
    Invoke-HistoricalShapeGit $consumer @('checkout-index','--all','--force')|Out-Null
    Write-Host "Historical consumer fixture commit $(Invoke-HistoricalShapeGit $consumer @('rev-parse','HEAD')); original C-qualified executor objects and native history retained."
    $ExecutorRoot=$consumer
}
$owner=Import-Module (Join-Path $ExecutorRoot 'scripts/lib/MorphospaceNonpassCustodyCorrection.psm1') -PassThru
$adapter=Import-Module (Join-Path $ExecutorRoot 'scripts/lib/MorphospaceNativeNonpassRecoveryAuthorization.psm1') -PassThru
&$adapter {param($w,$p,$e)Open-MorphospaceNativeNonpassRecoverySourceScope -WorkspaceRoot $w -RequestPath $p -ExecutorRoot $e} $WorkspaceRoot $RequestPath $ExecutorRoot
try{&$owner {param($w,$p,$fixture,$all,$pass)
    $candidate=Read-MorphospaceProtocolJson $p
    if([string]$candidate.project_id-cne'envelope-test'-or[string]$candidate.unit_id-cne'u002'){throw 'The historical shape fixture refuses non-fixture input.'}
    $root=[IO.Path]::GetFullPath($fixture).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    foreach($child in @($w,$p)){if(-not[IO.Path]::GetFullPath($child).StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'The historical shape fixture escaped its disposable root.'}}
    $row=@($candidate.nonpass_custody_defect.artifacts|Where-Object artifact_class -CEQ 'mutable-source')[0]
    $path=[IO.Path]::GetFullPath([string]$row.path)
    if(-not$path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)-or-not[IO.File]::Exists($path)){throw 'The historical shape fixture requires its own existing ordinary source payload.'}
    $modes=if($all){@('directory','absent','reparse','source-root-absent')}else{@('directory')}
    foreach($mode in $modes){
        $saved=$path+'.shape-fixture-'+[guid]::NewGuid().ToString('N');$moved=$false;$created=$false;$target=$null;$repo=$null;$savedRepo=$null
        try{
            if($mode-ceq'source-root-absent'){
                $map=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $w ([string]$candidate.expected.repository_map_path) -RequireLeaf)
                $mapped=@($map.repositories|Where-Object repo_id -CEQ ([string]$row.repo_id));if($mapped.Count-ne1){throw 'Historical source-root map is ambiguous.'}
                $repo=[IO.Path]::GetFullPath([string]$mapped[0].path)
                if(-not$repo.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Historical source-root transition escaped its disposable fixture.'}
                $savedRepo=$repo+'.shape-fixture-'+[guid]::NewGuid().ToString('N');[IO.Directory]::Move($repo,$savedRepo)
            }else{
                [IO.File]::Move($path,$saved);$moved=$true
                if($mode-ceq'directory'){[IO.Directory]::CreateDirectory($path)|Out-Null;$created=$true}
                elseif($mode-ceq'reparse'){
                    $target=Join-Path $fixture ('shape-target-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($target)|Out-Null
                    if($IsWindows){New-Item -ItemType Junction -Path $path -Target $target|Out-Null}else{[IO.Directory]::CreateSymbolicLink($path,$target)|Out-Null};$created=$true
                }
            }
            $inventory=@(Get-NonpassCustodyCommittedInventory $w)
            if($inventory.Count-lt2-or@($inventory|Where-Object return_event_id -CEQ ([string]$candidate.nonpass_custody_defect.return.event_id)).Count-ne2){throw 'Historical shape transition lost its exact independently authenticated C inventory.'}
            Assert-NonpassCustodyReceiptArtifacts $w ([string]$candidate.nonpass_custody_defect.original_receipt.path) '' ([string]$candidate.nonpass_custody_defect.return.event_id)
            Write-Host "PASS genuine committed C historical inventory and receipt with old payload $mode."
        }finally{
            if($created){[IO.Directory]::Delete($path)}
            if($moved){[IO.File]::Move($saved,$path)}
            if($target){[IO.Directory]::Delete($target)}
            if($savedRepo){[IO.Directory]::Move($savedRepo,$repo)}
        }
    }
    $receipt=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $w ([string]$candidate.nonpass_custody_defect.original_receipt.path) -RequireLeaf)
    $unmatched=@($receipt.artifacts|Where-Object artifact_id -CEQ 'source-evidence')[0]
    $unmatchedPath=Get-NonpassCustodyArtifactPath $w ([string]$candidate.nonpass_custody_defect.original_receipt.path) ([string]$unmatched.path);$unmatchedBytes=[IO.File]::ReadAllBytes($unmatchedPath)
    try{
        [IO.File]::WriteAllText($unmatchedPath,'Deliberately damaged unmatched fixture evidence.')
        $caught=$null;try{Assert-NonpassCustodyReceiptArtifacts $w ([string]$candidate.nonpass_custody_defect.original_receipt.path) '' ([string]$candidate.nonpass_custody_defect.return.event_id)}catch{$caught=$_}
        if($null-eq$caught-or-not$caught.Exception.Message.Contains('Historical nonpass evidence bytes drifted')){throw 'An unmatched artifact acquired the historical shape disposition.'}
    }finally{[IO.File]::WriteAllBytes($unmatchedPath,$unmatchedBytes)}
    $candidate.nonpass_custody_defect.original_receipt.sha256='0'*64;$events=Get-NonpassCustodyEvents $w
    $caught=$null;try{Read-NonpassCustodyDefect $w $candidate @($events.events)|Out-Null}catch{$caught=$_}
    if($null-eq$caught-or-not$caught.Exception.Message.Contains('immutable bytes drifted')){throw 'Historical shape disposition skipped immutable original receipt bytes.'}
    if($pass){
        $passed=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $w $pass -RequireLeaf)
        if([string]$passed.result-cne'pass'){throw 'Historical PASS control lacks its real PASS receipt.'}
        $caught=$null;try{Assert-NonpassCustodyReceiptArtifacts $w $pass '' ([string]$candidate.nonpass_custody_defect.return.event_id)}catch{$caught=$_}
        if($null-eq$caught-or-not$caught.Exception.Message.Contains('cannot consume PASS or accepted evidence')){throw 'A genuine PASS entered the historical audit-only predicate.'}
    }
    Write-Host 'PASS unmatched payload and immutable original receipt bindings remain strict.'
} $WorkspaceRoot $RequestPath $FixtureRoot $AllShapes $PassReceiptPath}finally{&$adapter {Close-MorphospaceNativeNonpassRecoverySourceScope}}
