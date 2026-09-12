[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationArtifactTransport.psm1') -Force

function Assert-Transport([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-TransportThrows([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    try { & $Action } catch { if ($_.Exception.Message -like $Pattern) { return }; throw "$Message Actual error: $($_.Exception.Message)" }
    throw $Message
}
function New-TestArtifact([string]$Name, [string]$Payload = 'preserved') { [pscustomobject][ordered]@{ name=$Name; payload=$Payload; source='test' } }
function Invoke-TransportFixtureGit([string]$Root, [string[]]$Arguments) {
    $result = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Transport fixture git command failed: $($Arguments -join ' ')`n$($result -join "`n")" }
    return (@($result | ForEach-Object { [string]$_ }) -join "`n").Trim()
}
function Write-TransportFixtureUtf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
function Assert-TransportScratchChild([string]$Root, [string]$Path, [string]$Context) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith(($rootFull + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { throw "Transport fixture $Context escaped its scratch root: $pathFull" }
}

function Invoke-TransportDownloadFixture([object[]]$Rows, [hashtable]$Sources, [string]$Destination, [string]$Platform = 'linux', [switch]$FailDownload) {
    $fixtureRemoteRows = $Rows
    $fixtureSources = $Sources
    $fixtureDownloads = [Collections.Generic.List[string]]::new()
    function gh {
        $global:LASTEXITCODE = 0
        if ($args[0] -ceq 'api') {
            Assert-Transport ($args.Count -eq 2 -and $args[1] -match '^/repos/example/transport-fixture/actions/runs/77/artifacts\?per_page=100&page=([1-9][0-9]*)$') 'Downloader did not enumerate the exact repository/run.'
            $page = [int]$Matches[1]
            return (@{total_count=($fixtureRemoteRows.Count + $page - 1);artifacts=@($fixtureRemoteRows | Select-Object -Skip (($page - 1) * 100) -First 100)} | ConvertTo-Json -Depth 32)
        }
        Assert-Transport ($args.Count -eq 9 -and $args[0] -ceq 'run' -and $args[1] -ceq 'download' -and $args[2] -ceq '77' -and $args[3] -ceq '--repo' -and $args[4] -ceq 'example/transport-fixture' -and $args[5] -ceq '--name' -and $args[7] -ceq '--dir') 'Downloader did not bind one exact name and run per download.'
        $name = [string]$args[6]; $target = [string]$args[8]
        Assert-Transport ([IO.Path]::GetFileName($target) -ceq $name) 'Downloader lost the real artifact directory identity.'
        $fixtureDownloads.Add($name)
        if ($FailDownload) { $global:LASTEXITCODE = 1; return }
        # Reproduce the actual CLI/action singleton behavior: payload directly
        # in the requested directory, with no automatic artifact-name wrapper.
        [void][IO.Directory]::CreateDirectory($target)
        foreach ($source in @(Get-ChildItem -LiteralPath $fixtureSources[$name])) { Copy-Item -LiteralPath $source.FullName -Destination $target }
    }
    & (Join-Path $PSScriptRoot 'Download-AffectedValidationSegmentArtifacts.ps1') -Repository 'example/transport-fixture' -RunId 77 -CurrentAttempt 2 -Platform $Platform -DestinationRoot $Destination | Out-Null
    return @($fixtureDownloads.ToArray())
}

function Invoke-TransportDownloadDamageFixture([string]$ScratchRoot) {
    $goodName = "affected-segment-linux-001-$('a' * 64)-77-2"
    $olderName = "affected-segment-linux-001-$('b' * 64)-77-1"
    foreach ($kind in @('name','run','future','id','duplicate-id','duplicate-name','duplicate-winner','expired-winner','empty')) {
        $good = [pscustomobject]@{name=$goodName;id=1;expired=$false}
        $rows = @($good)
        $pattern = '*artifact name is invalid*'
        switch ($kind) {
            'name' { $good.name = 'affected-segment-linux-../escape' }
            'run' { $good.name = $goodName -replace '-77-2$', '-78-2'; $pattern = '*wrong run*' }
            'future' { $good.name = $goodName -replace '-77-2$', '-77-3'; $pattern = '*future attempt*' }
            'id' { $good.id = '../1'; $pattern = '*artifact ID is invalid*' }
            'duplicate-id' { $rows += [pscustomobject]@{name=$olderName;id=1;expired=$false}; $pattern = '*duplicate names or IDs*' }
            'duplicate-name' { $rows += [pscustomobject]@{name=$goodName;id=2;expired=$false}; $pattern = '*duplicate names or IDs*' }
            'duplicate-winner' { $rows += [pscustomobject]@{name=($goodName -replace ('a' * 64), ('b' * 64));id=2;expired=$false}; $pattern = '*duplicate candidates at winning attempt*' }
            'expired-winner' { $good.expired=$true; $rows += [pscustomobject]@{name=$olderName;id=2;expired=$false}; $pattern = '*expired*' }
            'empty' { $rows=@(); $pattern = '*No linux segment artifacts*' }
        }
        $output = Join-Path $ScratchRoot "download-damage-$kind"
        Assert-TransportThrows { Invoke-TransportDownloadFixture -Rows $rows -Sources @{} -Destination $output | Out-Null } $pattern "Downloader accepted '$kind' metadata."
        Assert-Transport (-not (Test-Path -LiteralPath $output)) "Downloader created output before rejecting '$kind' metadata."
    }
    $good = [pscustomobject]@{name=$goodName;id=1;expired=$false}
    $source = Join-Path $ScratchRoot 'download-fixture-source'; [void][IO.Directory]::CreateDirectory($source)
    Write-TransportFixtureUtf8 (Join-Path $source 'linux-001.json') 'byte-exact download'
    # The selected artifact is on page two; unrelated uploads change total_count.
    $rows = @(1..100 | ForEach-Object { [pscustomobject]@{name="unrelated-$_";id=($_+1);expired=$false} }) + @($good)
    $output = Join-Path $ScratchRoot 'download-paginated'
    $calls = @(Invoke-TransportDownloadFixture -Rows $rows -Sources @{$goodName=$source} -Destination $output)
    Assert-Transport ($calls.Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $output "$goodName/linux-001.json")) -ceq 'byte-exact download') 'Paginated download lost identity or bytes.'
    Assert-TransportThrows { Invoke-TransportDownloadFixture -Rows @($good) -Sources @{$goodName=$source} -Destination $output | Out-Null } '*destination already exists*' 'Downloader accepted an existing destination.'
    Assert-TransportThrows { Invoke-TransportDownloadFixture -Rows @($good) -Sources @{} -Destination (Join-Path $ScratchRoot 'download-failed') -FailDownload | Out-Null } '*Could not download selected*' 'Downloader hid a CLI download failure.'
}

function Invoke-TransportStageMergeFixture([string]$ScratchRoot, [int]$SegmentCount = 2) {
    $fixture = Join-Path $ScratchRoot 'stage-merge-fixture'
    [void][IO.Directory]::CreateDirectory($fixture)
    foreach ($directory in @('manifests','schemas','scripts')) { [void][IO.Directory]::CreateDirectory((Join-Path $fixture $directory)) }
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/affected-validation-registry-v1.schema.json') -Destination (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')
    $checks = [Collections.Generic.List[object]]::new()
    $pathSets = [Collections.Generic.List[object]]::new()
    foreach ($platform in @('linux','windows')) {
        foreach ($suffix in @('alpha','beta') | Select-Object -First $SegmentCount) {
            $id = "$platform-$suffix"; $commandPath = "scripts/Test-$platform-$suffix.ps1"; $pathSetId = "$id-path"
            Write-TransportFixtureUtf8 (Join-Path $fixture $commandPath) '# transport fixture'
            $pathSets.Add([pscustomobject][ordered]@{path_set_id=$pathSetId;patterns=@($commandPath)})
            $checks.Add([pscustomobject][ordered]@{check_id=$id;command_path=$commandPath;arguments=@();platforms=@($platform);minimum_tier='quick';trigger_path_sets=@($pathSetId);consume_path_sets=@($pathSetId);prerequisite_checks=@();provides_contracts=@();consumes_contracts=@();always_run=$true;authority_class='ordinary';cache_policy='disabled';budget_seconds=3600;external_state='none'})
        }
    }
    Write-TransportFixtureUtf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') '# transport fixture public boundary'
    Write-TransportFixtureUtf8 (Join-Path $fixture 'scripts/Test-FixtureSupport.ps1') '# transport fixture support'
    $pathSets.Add([pscustomobject][ordered]@{path_set_id='fixture-support-path';patterns=@('scripts/Test-PublicBoundary.ps1','scripts/Test-FixtureSupport.ps1')})
    $checks.Add([pscustomobject][ordered]@{check_id='fixture-support';command_path='scripts/Test-FixtureSupport.ps1';arguments=@();platforms=@('linux');minimum_tier='quick';trigger_path_sets=@('fixture-support-path');consume_path_sets=@('fixture-support-path');prerequisite_checks=@();provides_contracts=@();consumes_contracts=@();always_run=$false;authority_class='ordinary';cache_policy='portable';budget_seconds=30;external_state='none'})
    $publicPathSetIds = @($pathSets.ToArray() | ForEach-Object { [string]$_.path_set_id })
    $checks.Add([pscustomobject][ordered]@{check_id='public-boundary';command_path='scripts/Test-PublicBoundary.ps1';arguments=@();platforms=@('linux');minimum_tier='quick';trigger_path_sets=$publicPathSetIds;consume_path_sets=$publicPathSetIds;prerequisite_checks=@();provides_contracts=@('public-boundary');consumes_contracts=@();always_run=$false;authority_class='ordinary';cache_policy='portable';budget_seconds=30;external_state='none'})
    $registry = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_registry.v1';registry_id='transport-fixture';repository_id='example/transport-fixture';revision=1;historical_aggregate=[pscustomobject][ordered]@{tier='deep';reusable_evidence=$false;full_history_required=$true};dependency_declarations=@();path_sets=@($pathSets.ToArray());checks=@($checks.ToArray());always_run_check_ids=@($checks.ToArray()|Where-Object{[bool]$_.always_run}|ForEach-Object{[string]$_.check_id});deep_escalation_path_sets=@();claims=[pscustomobject][ordered]@{selection_only=$true;executes_checks=$false;acceptance_authority=$false;publication_authority=$false}}
    Write-TransportFixtureUtf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson -Value $registry)+"`n")
    [void](Invoke-TransportFixtureGit $fixture @('init'));[void](Invoke-TransportFixtureGit $fixture @('config','user.email','transport@example.invalid'));[void](Invoke-TransportFixtureGit $fixture @('config','user.name','Transport Fixture'));[void](Invoke-TransportFixtureGit $fixture @('add','.'));[void](Invoke-TransportFixtureGit $fixture @('commit','-m','transport fixture'))
    $head=Invoke-TransportFixtureGit $fixture @('rev-parse','HEAD')
    $plan=Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $head -HeadRevision $head -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    $planPath=Join-Path $ScratchRoot 'transport-plan.json';Write-TransportFixtureUtf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $plan)+"`n")
    $inventory=Get-MorphospaceAffectedTreeInventory -RepositoryRoot $fixture -Commit $head;$checkMap=@{};foreach($check in @($registry.checks)){$checkMap[[string]$check.check_id]=$check}
    function New-StageEvidence([object]$Segment,[string]$Platform,[string]$Result='pass'){
        $rows=[Collections.Generic.List[object]]::new();foreach($id in @($Segment.check_ids)){$check=$checkMap[[string]$id];$entry=$inventory.by_path[[string]$check.command_path];$failed=$Result-cne'pass';$rows.Add([pscustomobject][ordered]@{check_id=[string]$id;command_path=[string]$check.command_path;command_blob_sha1=[string]$entry.blob;mode='executed';result=$Result;started=$true;failure_kind=if($failed){'exit-code'}else{$null};exit_code=if($failed){1}else{0};timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout_sha256=('0'*64);stderr_sha256=('0'*64);stdout_bytes=0;stderr_bytes=0})}
        $doc=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_evidence.v1';repository=[string]$plan.repository;base=$plan.base;head=$plan.head;plan_sha256=[string]$plan.plan_sha256;platform=$Platform;runner=[pscustomobject][ordered]@{os_description='transport-self-test';powershell_version='7.6.0'};check_results=@($rows.ToArray());result=$Result;claims=[pscustomobject][ordered]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}
        return [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $doc)+"`n")
    }
    function Add-StageArtifact([string]$Root,[string]$SegmentId,[byte[]]$Bytes,[int]$Attempt,[string]$Nested='',[switch]$HashDamage){$hash=Get-MorphospaceSha256Bytes -Bytes $Bytes;$dir=Join-Path $Root "affected-segment-$SegmentId-$hash-77-$Attempt";[void][IO.Directory]::CreateDirectory($dir);$payloadRoot=if($Nested){Join-Path $dir $Nested}else{$dir};if($Nested){[void][IO.Directory]::CreateDirectory($payloadRoot)};$written=if($HashDamage){$Bytes+[byte[]](10)}else{$Bytes};[IO.File]::WriteAllBytes((Join-Path $payloadRoot "$SegmentId.json"),$written);return $dir}

    foreach($platform in @('linux','windows')){
        $segments=@(Get-MorphospaceAffectedValidationSegments -Plan $plan -Registry $registry -Platform $platform)
        Assert-Transport ($segments.Count-eq$SegmentCount-and@($segments|ForEach-Object{@($_.check_ids).Count}|Where-Object{$_-ne1}).Count-eq0) "Transport fixture did not produce $SegmentCount independent $platform segments."
        if ($SegmentCount -eq 1) {
            $serverRoot = Join-Path $ScratchRoot "$platform-server"
            $payload = New-StageEvidence $segments[0] $platform
            $serverArtifact = Add-StageArtifact $serverRoot $segments[0].segment_id $payload 1
            $name = [IO.Path]::GetFileName($serverArtifact)
            $download = Join-Path $ScratchRoot "$platform-singleton-download"
            $calls = @(Invoke-TransportDownloadFixture -Rows @([pscustomobject]@{name=$name;id=1;expired=$false}) -Sources @{$name=$serverArtifact} -Destination $download -Platform $platform)
            Assert-Transport ($calls.Count -eq 1) 'Singleton download did not request exactly one artifact.'
            $stage = Join-Path $ScratchRoot "$platform-singleton-stage"
            & (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot $fixture -BaseCommit $head -HeadCommit $head -PlanPath $planPath -Platform $platform -DownloadedArtifactRoot $download -RunId 77 -CurrentAttempt 2 -StagingDirectory $stage -SelectionReceiptPath (Join-Path $ScratchRoot "$platform-singleton-selection.json") | Out-Null
            Assert-Transport ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $stage "$($segments[0].segment_id).json"))) -ceq [Convert]::ToBase64String($payload)) 'Singleton staging changed payload bytes.'
            $merged = & (Join-Path $PSScriptRoot 'Merge-AffectedValidationSegments.ps1') -RepositoryRoot $fixture -BaseCommit $head -HeadCommit $head -PlanPath $planPath -Platform $platform -SegmentEvidenceDirectory $stage -OutPath (Join-Path $ScratchRoot "$platform-singleton-merged.json")
            Assert-Transport ($merged.result -ceq 'pass' -and @($merged.check_results).Count -eq 1) 'Singleton download/stage/merge failed.'
            # The previous pattern-download layout must remain rejected.
            $flatRoot = Join-Path $ScratchRoot "$platform-flat-download"; [void][IO.Directory]::CreateDirectory($flatRoot)
            [IO.File]::WriteAllBytes((Join-Path $flatRoot "$($segments[0].segment_id).json"), $payload)
            Assert-TransportThrows { & (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot $fixture -BaseCommit $head -HeadCommit $head -PlanPath $planPath -Platform $platform -DownloadedArtifactRoot $flatRoot -RunId 77 -CurrentAttempt 2 -StagingDirectory (Join-Path $ScratchRoot "$platform-flat-stage") -SelectionReceiptPath (Join-Path $ScratchRoot "$platform-flat-selection.json") | Out-Null } '*download layout contains a file*' 'Stage accepted anonymous singleton payload.'
            continue
        }
        $transportRoot=Join-Path $ScratchRoot "$platform-transport";[void][IO.Directory]::CreateDirectory($transportRoot);$first=$segments[0];$second=$segments[1];$firstPass=New-StageEvidence $first $platform;$secondPass=New-StageEvidence $second $platform
        [void](Add-StageArtifact $transportRoot $first.segment_id (New-StageEvidence $first $platform 'code-fail') 1);$winner=Add-StageArtifact $transportRoot $first.segment_id $firstPass 2;[void](Add-StageArtifact $transportRoot $second.segment_id $secondPass 1)
        $remoteRows = @(); $sources = @{}; $remoteId = 1
        foreach ($artifact in @(Get-ChildItem -LiteralPath $transportRoot -Directory)) {
            $remoteRows += [pscustomobject]@{name=$artifact.Name;id=$remoteId++;expired=($artifact.Name -like "affected-segment-$($first.segment_id)-*-77-1")}
            $sources[$artifact.Name] = $artifact.FullName
        }
        $transportRoot = Join-Path $ScratchRoot "$platform-real-download"
        $calls = @(Invoke-TransportDownloadFixture -Rows $remoteRows -Sources $sources -Destination $transportRoot -Platform $platform)
        Assert-Transport ($calls.Count -eq 2) 'Multi download did not select only the fresh winner and retained sibling; expired loser must not block.'
        $winner = Join-Path $transportRoot ([IO.Path]::GetFileName($winner))
        $stage=Join-Path $ScratchRoot "$platform-stage";$receipt=Join-Path $ScratchRoot "$platform-selection.json";$selection=& (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot $fixture -BaseCommit $head -HeadCommit $head -PlanPath $planPath -Platform $platform -DownloadedArtifactRoot $transportRoot -RunId 77 -CurrentAttempt 2 -StagingDirectory $stage -SelectionReceiptPath $receipt
        Assert-Transport ((@($selection.selected|Where-Object{[string]$_.segment_id-ceq[string]$first.segment_id})[0].attempt-eq2)) "Transport fixture did not select the new $platform retry."
        Assert-Transport ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $stage "$($first.segment_id).json"))) -ceq [Convert]::ToBase64String($firstPass) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $stage "$($second.segment_id).json"))) -ceq [Convert]::ToBase64String($secondPass)) "Transport fixture did not preserve byte-exact staged $platform evidence."
        $merged=& (Join-Path $PSScriptRoot 'Merge-AffectedValidationSegments.ps1') -RepositoryRoot $fixture -BaseCommit $head -HeadCommit $head -PlanPath $planPath -Platform $platform -SegmentEvidenceDirectory $stage -OutPath (Join-Path $ScratchRoot "$platform-merged.json");Assert-Transport ([string]$merged.result-ceq'pass'-and@($merged.check_results).Count-eq2) "Transport fixture did not preserve the earlier $platform sibling."
        $winnerBytes=[IO.File]::ReadAllBytes((Join-Path $winner "$($first.segment_id).json"));$duplicate=Add-StageArtifact $transportRoot $first.segment_id ($winnerBytes+[byte[]](10)) 2
        Assert-TransportThrows {& (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot $fixture -BaseCommit $head -HeadCommit $head -PlanPath $planPath -Platform $platform -DownloadedArtifactRoot $transportRoot -RunId 77 -CurrentAttempt 2 -StagingDirectory (Join-Path $ScratchRoot "$platform-duplicate-stage") -SelectionReceiptPath (Join-Path $ScratchRoot "$platform-duplicate-selection.json")|Out-Null} '*duplicate candidates at winning attempt*' "Transport fixture accepted duplicate $platform winners.";Assert-TransportScratchChild $transportRoot $duplicate 'duplicate cleanup';Remove-Item -LiteralPath $duplicate -Recurse -Force
        $wrong=Join-Path $transportRoot (([IO.Path]::GetFileName($winner))-replace'-77-2$','-78-2');Move-Item -LiteralPath $winner -Destination $wrong;Assert-TransportThrows {& (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot $fixture -BaseCommit $head -HeadCommit $head -PlanPath $planPath -Platform $platform -DownloadedArtifactRoot $transportRoot -RunId 77 -CurrentAttempt 2 -StagingDirectory (Join-Path $ScratchRoot "$platform-wrong-stage") -SelectionReceiptPath (Join-Path $ScratchRoot "$platform-wrong-selection.json")|Out-Null} '*wrong run*' "Transport fixture accepted wrong-run $platform evidence.";Move-Item -LiteralPath $wrong -Destination $winner
        foreach($kind in @('new-failure','plan','source','platform','hash','nested-payload','extra-payload')){$damage=[Text.UTF8Encoding]::new($false).GetString($winnerBytes)|ConvertFrom-Json -Depth 64 -DateKind String;$expected='*identity or result differs*';switch($kind){'new-failure'{$damage.result='code-fail';$damage.check_results[0].result='code-fail';$damage.check_results[0].failure_kind='exit-code';$damage.check_results[0].exit_code=1}'plan'{$damage.plan_sha256='0'*64}'source'{$damage.head.commit='0'*40;$expected='*source differs*'}'platform'{$damage.platform=if($platform-ceq'linux'){'windows'}else{'linux'}}'hash'{$expected='*SHA-256 differs*'}'nested-payload'{$expected='*payload layout is not exact*'}'extra-payload'{$expected='*payload layout is not exact*'}};$bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $damage)+"`n");$dir=Add-StageArtifact $transportRoot $first.segment_id $bytes 3 $(if($kind-ceq'nested-payload'){'nested'}else{''}) -HashDamage:($kind-ceq'hash');if($kind-ceq'extra-payload'){Write-TransportFixtureUtf8 (Join-Path $dir 'extra.txt') 'unexpected'};$damageStage=Join-Path $ScratchRoot "$platform-$kind-stage";$damageReceipt=Join-Path $ScratchRoot "$platform-$kind-selection.json";try{Assert-TransportThrows {& (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot $fixture -BaseCommit $head -HeadCommit $head -PlanPath $planPath -Platform $platform -DownloadedArtifactRoot $transportRoot -RunId 77 -CurrentAttempt 3 -StagingDirectory $damageStage -SelectionReceiptPath $damageReceipt|Out-Null} $expected "Transport fixture accepted $platform '$kind' evidence.";Assert-Transport (-not(Test-Path $damageStage)-and-not(Test-Path $damageReceipt)) "Transport fixture published partial $platform '$kind' output."}finally{Assert-TransportScratchChild $transportRoot $dir 'damage cleanup';Remove-Item -LiteralPath $dir -Recurse -Force}}
    }
}

$digestA = 'a' * 64
$digestB = 'b' * 64
$digestC = 'c' * 64
$segmentOne = "affected-segment-linux-001-$digestA-77-1"
$segmentTwo = "affected-segment-linux-002-$digestB-77-1"
$segmentRetry = "affected-segment-linux-001-$digestC-77-2"
$identity = ConvertFrom-MorphospaceAffectedArtifactName -Name $segmentRetry -RunId '77' -CurrentAttempt 2
Assert-Transport ($identity.kind -ceq 'segment' -and $identity.logical_id -ceq 'linux-001' -and $identity.digest -ceq $digestC -and $identity.run_id -ceq '77' -and [UInt64]$identity.attempt -eq 2 -and $identity.file_name -ceq 'linux-001.json') 'Segment artifact identity did not parse exactly.'

$plan = "affected-plan-$digestA-77-2"
$linux = "affected-linux-$digestB-77-2"
$windows = "affected-windows-$digestC-77-2"
$aggregate = Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $windows),(New-TestArtifact $plan),(New-TestArtifact $linux)) -ExpectedIds @('plan','linux','windows') -RunId '77' -CurrentAttempt 2
Assert-Transport ((@($aggregate | ForEach-Object { $_.identity.logical_id }) -join '|') -ceq 'plan|linux|windows') 'Aggregate artifacts were not selected in expected-ID order.'
Assert-Transport ([string]$aggregate[0].artifact.payload -ceq 'preserved') 'Selection did not retain the original artifact object.'
Assert-Transport ((@($aggregate | ForEach-Object { $_.identity.file_name }) -join '|') -ceq 'affected-plan.json|affected-linux-evidence.json|affected-windows-evidence.json') 'Aggregate payload basenames are not exact.'
$olderPlan = "affected-plan-$digestB-77-1"
$olderLinux = "affected-linux-$digestA-77-1"
$olderWindows = "affected-windows-$digestB-77-1"
$mixedAggregate = Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $olderLinux 'linux-first-attempt'),(New-TestArtifact $olderPlan 'plan-first-attempt'),(New-TestArtifact $olderWindows 'windows-first-attempt'),(New-TestArtifact $plan 'plan-retry')) -ExpectedIds @('plan','linux','windows') -RunId '77' -CurrentAttempt 2
Assert-Transport ((@($mixedAggregate | ForEach-Object { [string]$_.identity.attempt }) -join '|') -ceq '2|1|1') 'Aggregate mixed retry selection did not preserve the greatest allowed attempt.'

$selected = Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $segmentOne 'old'),(New-TestArtifact $segmentTwo 'sibling'),(New-TestArtifact $segmentRetry 'new')) -ExpectedIds @('linux-001','linux-002') -RunId '77' -CurrentAttempt 2
Assert-Transport ([string]$selected[0].artifact.name -ceq $segmentRetry -and [string]$selected[1].artifact.payload -ceq 'sibling') 'Newer retry or unchanged sibling selection is wrong.'
$reversed = Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $segmentRetry),(New-TestArtifact $segmentTwo),(New-TestArtifact $segmentOne)) -ExpectedIds @('linux-001','linux-002') -RunId '77' -CurrentAttempt 2
Assert-Transport ([string]$reversed[0].artifact.name -ceq $segmentRetry) 'Artifact order changed selection.'
$thirdRetry = "affected-segment-linux-001-$digestB-77-3"
$multipleRetries = Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $segmentOne),(New-TestArtifact $segmentRetry),(New-TestArtifact $thirdRetry)) -ExpectedIds @('linux-001') -RunId '77' -CurrentAttempt 3
Assert-Transport ([string]$multipleRetries[0].artifact.name -ceq $thirdRetry) 'Multiple retries did not choose the greatest allowed attempt.'

Assert-TransportThrows { Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $segmentRetry),(New-TestArtifact "affected-segment-linux-001-$digestA-77-2")) -ExpectedIds @('linux-001') -RunId '77' -CurrentAttempt 2 } '*duplicate candidates at winning attempt*' 'Duplicate winners were accepted.'
Assert-TransportThrows { Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $segmentOne),(New-TestArtifact "affected-segment-linux-003-$digestC-77-1")) -ExpectedIds @('linux-001') -RunId '77' -CurrentAttempt 2 } '*unexpected logical ID*' 'Unexpected segment was accepted.'
Assert-TransportThrows { Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $segmentOne)) -ExpectedIds @('linux-001','linux-002') -RunId '77' -CurrentAttempt 2 } "*missing 'linux-002'*" 'Missing segment was accepted.'
Assert-TransportThrows { ConvertFrom-MorphospaceAffectedArtifactName -Name "affected-plan-$digestA-78-1" -RunId '77' -CurrentAttempt 2 } '*wrong run*' 'Wrong run was accepted.'
Assert-TransportThrows { ConvertFrom-MorphospaceAffectedArtifactName -Name "affected-plan-$digestA-77-3" -RunId '77' -CurrentAttempt 2 } '*future attempt*' 'Future attempt was accepted.'
Assert-TransportThrows { ConvertFrom-MorphospaceAffectedArtifactName -Name "affected-plan-$digestA-77-0" -RunId '77' -CurrentAttempt 2 } '*name is invalid*' 'Zero attempt was accepted.'
Assert-TransportThrows { ConvertFrom-MorphospaceAffectedArtifactName -Name "affected-plan-$digestA-18446744073709551616-1" -RunId '77' -CurrentAttempt 2 } '*exceeds UInt64*' 'Overflowing run was accepted.'
Assert-TransportThrows { ConvertFrom-MorphospaceAffectedArtifactName -Name "affected-plan-$digestA-77-18446744073709551616" -RunId '77' -CurrentAttempt 2 } '*exceeds UInt64*' 'Overflowing attempt was accepted.'
Assert-TransportThrows { ConvertFrom-MorphospaceAffectedArtifactName -Name "affected-plan-$digestA" -RunId '77' -CurrentAttempt 2 } '*name is invalid*' 'Legacy content-only artifact form was accepted.'
Assert-TransportThrows { ConvertFrom-MorphospaceAffectedArtifactName -Name "affected-segment-linux-01-$digestA-77-1" -RunId '77' -CurrentAttempt 2 } '*name is invalid*' 'Malformed segment name was accepted.'
Assert-TransportThrows { Select-MorphospaceAffectedArtifactAttempts -Artifacts @([pscustomobject]@{ payload='missing-name' }) -ExpectedIds @('linux-001') -RunId '77' -CurrentAttempt 2 } '*no name member*' 'Artifact input without a name member was accepted.'
Assert-TransportThrows { Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $segmentOne),(New-TestArtifact "affected-segment-linux-001-$digestB-77-3")) -ExpectedIds @('linux-001') -RunId '77' -CurrentAttempt 2 } '*future attempt*' 'Selection fell back after a future-attempt artifact.'
Assert-TransportThrows { Select-MorphospaceAffectedArtifactAttempts -Artifacts @((New-TestArtifact $segmentOne),(New-TestArtifact "affected-segment-linux-001-$digestB-78-1")) -ExpectedIds @('linux-001') -RunId '77' -CurrentAttempt 2 } '*wrong run*' 'Selection fell back after a wrong-run artifact.'

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-transport-' + [Guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($scratch)
    $downloadRoot = Join-Path $scratch 'download'; [void][IO.Directory]::CreateDirectory($downloadRoot)
    $preexistingStage = Join-Path $scratch 'preexisting-stage'; [void][IO.Directory]::CreateDirectory($preexistingStage)
    Assert-TransportThrows {
        & (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot (Split-Path -Parent $PSScriptRoot) -BaseCommit ('0' * 40) -HeadCommit ('1' * 40) -PlanPath (Join-Path $scratch 'absent-plan.json') -Platform linux -DownloadedArtifactRoot $downloadRoot -RunId 77 -CurrentAttempt 1 -StagingDirectory $preexistingStage -SelectionReceiptPath (Join-Path $scratch 'preexisting-receipt.json') | Out-Null
    } '*staging directory already exists*' 'Stage transport did not reject a pre-existing output before source processing.'

    $testRepositoryRoot = Split-Path -Parent $PSScriptRoot
    $ordinaryRepositoryStage = Join-Path $testRepositoryRoot ('.transport-scratch-' + [Guid]::NewGuid().ToString('N'))
    Assert-TransportThrows {
        & (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot $testRepositoryRoot -BaseCommit ('0' * 40) -HeadCommit ('1' * 40) -PlanPath (Join-Path $scratch 'ordinary-absent-plan.json') -Platform linux -DownloadedArtifactRoot $downloadRoot -RunId 77 -CurrentAttempt 1 -StagingDirectory $ordinaryRepositoryStage -SelectionReceiptPath (Join-Path $scratch 'ordinary-receipt.json') | Out-Null
    } '*plan is absent*' 'Stage transport rejected an ordinary uncreated repository descendant before source processing.'
    $metadataPaths = @(
        (& git -C $testRepositoryRoot rev-parse --path-format=absolute --git-dir).Trim()
        (& git -C $testRepositoryRoot rev-parse --path-format=absolute --git-common-dir).Trim()
        (Join-Path $testRepositoryRoot '.git')
    )
    if ($LASTEXITCODE -ne 0) { throw 'Transport self-test could not resolve Git metadata paths.' }
    foreach ($metadataPath in @($metadataPaths | Select-Object -Unique)) {
        Assert-TransportThrows {
            & (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot $testRepositoryRoot -BaseCommit ('0' * 40) -HeadCommit ('1' * 40) -PlanPath (Join-Path $scratch 'metadata-absent-plan.json') -Platform linux -DownloadedArtifactRoot $downloadRoot -RunId 77 -CurrentAttempt 1 -StagingDirectory (Join-Path $metadataPath ('transport-stage-' + [Guid]::NewGuid().ToString('N'))) -SelectionReceiptPath (Join-Path $scratch 'metadata-receipt.json') | Out-Null
        } '*overlaps Git metadata*' 'Stage transport accepted an output in Git metadata.'
    }

    $reparseDownloadRoot = Join-Path $scratch 'download-link'
    if ($IsWindows) {
        [void](New-Item -ItemType Junction -Path $reparseDownloadRoot -Target $downloadRoot -ErrorAction Stop)
    } else {
        [void][IO.Directory]::CreateSymbolicLink($reparseDownloadRoot, $downloadRoot)
    }
    Assert-TransportThrows {
        & (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot (Split-Path -Parent $PSScriptRoot) -BaseCommit ('0' * 40) -HeadCommit ('1' * 40) -PlanPath (Join-Path $scratch 'still-absent-plan.json') -Platform linux -DownloadedArtifactRoot $reparseDownloadRoot -RunId 77 -CurrentAttempt 1 -StagingDirectory (Join-Path $scratch 'reparse-stage') -SelectionReceiptPath (Join-Path $scratch 'reparse-receipt.json') | Out-Null
    } '*reparse-point ancestor*' 'Stage transport accepted a reparse-point input before source processing.'

    $oversizedPlan = Join-Path $scratch 'oversized-plan.json'
    [IO.File]::WriteAllBytes($oversizedPlan, [byte[]]::new(16777217))
    $freshStage = Join-Path $scratch 'fresh-stage'
    $freshReceipt = Join-Path $scratch 'fresh-receipt.json'
    Assert-TransportThrows {
        & (Join-Path $PSScriptRoot 'Stage-AffectedValidationSegmentEvidence.ps1') -RepositoryRoot (Split-Path -Parent $PSScriptRoot) -BaseCommit ('0' * 40) -HeadCommit ('1' * 40) -PlanPath $oversizedPlan -Platform linux -DownloadedArtifactRoot $downloadRoot -RunId 77 -CurrentAttempt 1 -StagingDirectory $freshStage -SelectionReceiptPath $freshReceipt | Out-Null
    } '*plan exceeds the 16 MiB bound*' 'Stage transport accepted an oversized plan input.'
    Assert-Transport (-not [IO.Directory]::Exists($freshStage) -and -not [IO.File]::Exists($freshReceipt)) 'Stage transport created outputs before bounded input validation.'
    Invoke-TransportDownloadDamageFixture -ScratchRoot $scratch
    $singletonScratch = Join-Path $scratch 'singleton'; [void][IO.Directory]::CreateDirectory($singletonScratch)
    Invoke-TransportStageMergeFixture -ScratchRoot $singletonScratch -SegmentCount 1
    Invoke-TransportStageMergeFixture -ScratchRoot $scratch
} finally {
    $scratchFull = [IO.Path]::GetFullPath($scratch)
    $tempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if (-not $scratchFull.StartsWith(($tempFull + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { throw "Transport self-test scratch cleanup target escaped its temp root: $scratchFull" }
    if ([IO.Directory]::Exists($scratchFull)) { Remove-Item -LiteralPath $scratchFull -Recurse -Force }
}

Write-Output 'Affected-validation artifact transport self-test passed.'
