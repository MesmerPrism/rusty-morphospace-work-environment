[CmdletBinding(DefaultParameterSetName = 'verify')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][Parameter(Mandatory = $true, ParameterSetName = 'hosted')][string]$RepositoryRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][Parameter(Mandatory = $true, ParameterSetName = 'hosted')][string]$BeforeCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][Parameter(Mandatory = $true, ParameterSetName = 'hosted')][string]$HeadCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$ReusePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = 'hosted')][switch]$CandidateHosted,
    [Parameter(Mandatory = $true, ParameterSetName = 'hosted')][string]$Repository,
    [Parameter(Mandatory = $true, ParameterSetName = 'hosted')][int]$PullRequestNumber,
    [Parameter(Mandatory = $true, ParameterSetName = 'hosted')][long]$RunId,
    [Parameter(Mandatory = $true, ParameterSetName = 'hosted')][string]$GhPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'hosted')][string]$OutputDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = 'self')][switch]$SelfTest,
    [Parameter(Mandatory = $true, ParameterSetName = 'selfPhase')]
    [ValidateSet('plan-base-admission','evidence-binding','run-job-coverage')]
    [string]$SelfTestPhase
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-ReuseWorkflowTokenContract([string]$Expected,[string]$Observed) {
    $sets=@()
    foreach($source in @($Expected,$Observed)) {
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Reuse Linux-direct source contract does not parse.'}
        $sets+=,@($tokens|Where-Object{$_.Kind -notin @('Comment','NewLine','EndOfInput')})
    }
    if($sets[0].Count-ne$sets[1].Count){throw 'Reuse Linux-direct source contract has extra or missing tokens.'}
    for($index=0;$index-lt$sets[0].Count;$index++) {
        if($sets[0][$index].Kind-ne$sets[1][$index].Kind-or$sets[0][$index].Text-cne$sets[1][$index].Text){throw 'Reuse Linux-direct source contract changed its exact token identity.'}
    }
}
function Get-ReuseWorkflowStepSource([string]$Body,[string]$Name) {
    $steps=[regex]::Matches($Body,'(?ms)^      - name: '+[regex]::Escape($Name)+'\r?\n(?<body>.*?)(?=^      - |\z)')
    if($steps.Count-ne1){throw "Reuse Linux-direct step is missing or duplicate: $Name"}
    $run=[regex]::Match($steps[0].Groups['body'].Value,'(?ms)^        run: \|\r?\n(?<code>.*)\z')
    if(-not$run.Success){throw "Reuse Linux-direct step has no literal script: $Name"}
    $lines=@(foreach($line in @($run.Groups['code'].Value -split '\r?\n')){if($line.Length){if(-not$line.StartsWith('          ',[StringComparison]::Ordinal)){throw 'Reuse Linux-direct script indentation changed.'};$line.Substring(10)}})
    return ($lines-join"`n")
}
function Get-ReuseWorkflowExecutorCalls([string]$Body) {
    $runs=[regex]::Matches($Body,'(?ms)^        run: (?:\|\r?\n(?<block>.*?)(?=^      - |\z)|(?<inline>[^\r\n]+))')
    if($runs.Count-ne([regex]::Matches($Body,'(?m)^        run:')).Count){throw 'Linux workflow contains an unsupported run-script shape.'}
    $allCalls=[Collections.Generic.List[object]]::new()
    foreach($run in $runs) {
        $source=if($run.Groups['inline'].Success){$run.Groups['inline'].Value}else{(@(foreach($line in @($run.Groups['block'].Value-split'\r?\n')){if($line.Length){if(-not$line.StartsWith('          ',[StringComparison]::Ordinal)){throw 'Linux workflow script indentation changed.'};$line.Substring(10)}})-join"`n")}
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Linux workflow run script does not parse.'}
        foreach($call in @($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$null-ne$node.GetCommandName()-and$node.GetCommandName()-match'(?i)(?:^|[/\\])Invoke-AffectedValidation\.ps1$'},$true))){$allCalls.Add($call)}
    }
    return [pscustomobject]@{run_count=$runs.Count;calls=@($allCalls)}
}
function Test-ReuseWorkflowHasPlatformExecutor([string]$Body) {
    return (Get-ReuseWorkflowExecutorCalls $Body).calls.Count-gt0
}
function Get-ReuseCandidateLinuxExecutionMode([string]$Workflow) {
    # Read only the already Git-bound candidate workflow, never receipt flags,
    # current checkout policy, job aliases or the provider's runner label.
    $parts=[regex]::Split($Workflow,'(?m)^jobs:\r?$')
    if($parts.Count-ne2){throw 'Reuse candidate workflow has no unique jobs mapping.'}
    $matches=[regex]::Matches($parts[1],'(?m)^  ([a-z0-9-]+):\r?$')
    $jobs=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $names=[Collections.Generic.List[string]]::new()
    for($index=0;$index-lt$matches.Count;$index++) {
        $name=$matches[$index].Groups[1].Value
        $end=if($index+1-lt$matches.Count){$matches[$index+1].Index}else{$parts[1].Length}
        if(-not$jobs.TryAdd($name,$parts[1].Substring($matches[$index].Index,$end-$matches[$index].Index))){throw "Reuse candidate workflow repeats a job: $name"}
        $names.Add($name)
    }
    if($jobs.ContainsKey('affected-linux-segments')) {
        if($jobs.ContainsKey('quick-linux')-and(Test-ReuseWorkflowHasPlatformExecutor $jobs['quick-linux'])){throw 'Reuse candidate workflow ambiguously combines direct Linux and segmented producers.'}
        return 'segmented'
    }
    $expected=@('infrastructure','select','quick-linux','affected-windows-segments','standard-windows','quick-windows','post-merge-attestation','main-windows-segments','main-linux-delta','main-windows-delta','deep')
    if((@($names)-join',')-cne($expected-join',')){throw 'Reuse Linux-direct candidate job identities/order differ from the exact topology.'}
    if($jobs['quick-linux']-cnotmatch'(?m)^    needs: \[infrastructure, select\]\r?$'-or
       $jobs['main-linux-delta']-cnotmatch'(?m)^    needs: \[select, post-merge-attestation\]\r?$'-or
       $jobs['quick-linux']-match'(?m)^    (?:strategy|matrix):'-or
       $jobs['main-linux-delta']-match'(?m)^    (?:strategy|matrix):') {throw 'Reuse Linux-direct candidate prerequisites or single-parent topology differ.'}
    $gate=Get-ReuseWorkflowStepSource $jobs['quick-linux'] 'Bind required Linux selection results'
    $expectedGate=@'
if ($env:INFRA_RESULT -cne 'success' -or $env:SELECT_RESULT -cne 'success') { throw 'Required Linux selection prerequisites did not succeed.' }
if ($env:LINUX_SELECTED -cnotin @('true','false')) { throw 'Required Linux selection output must be exactly true or false.' }
'@
    Assert-ReuseWorkflowTokenContract $expectedGate $gate
    $expectedInvocation=@'
& ./scripts/Invoke-AffectedValidation.ps1 -RepositoryRoot . -BaseCommit $base -HeadCommit $head -PlanPath "$env:RUNNER_TEMP/affected-plan.json" -Platform linux -OutPath $evidencePath -CheckEvidenceDirectory $currentRoot -PriorEvidenceDirectory $priorRoot
'@
    foreach($pair in @(@('quick-linux','Execute exact selected Linux union on this runner'),@('main-linux-delta','Execute exact current Linux delta on this runner'))) {
        $jobCalls=Get-ReuseWorkflowExecutorCalls $jobs[$pair[0]]
        if($jobCalls.run_count-ne2-or$jobCalls.calls.Count-ne1){throw 'Reuse Linux-direct job has an extra or hidden producer run step.'}
        $source=Get-ReuseWorkflowStepSource $jobs[$pair[0]] $pair[1]
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Reuse Linux-direct execution source does not parse.'}
        $calls=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$null-ne$node.GetCommandName()-and$node.GetCommandName()-match'(?i)(?:^|[/\\])Invoke-AffectedValidation\.ps1$'},$true))
        if($calls.Count-ne1){throw 'Reuse Linux-direct source lacks exactly one actual whole-platform executor call.'}
        Assert-ReuseWorkflowTokenContract $expectedInvocation $calls[0].Extent.Text
        foreach($required in @('if (-not [bool]$plan.execution_permitted -or $selected.Count -eq 0)',"@(`$_.platforms) -ccontains 'linux'",'Test-Json','evidence.plan_sha256','evidence.base.commit','evidence.head.commit',"evidence.result -cne 'pass'",'cache_inventory_sha256')) {
            if(-not$source.Contains($required)){throw "Reuse Linux-direct source lacks an exact union guard: $required"}
        }
    }
    return 'linux-direct'
}

function Assert-ReuseHostedRun {
    param([object]$Run,[string]$Repository,[int]$PullRequestNumber,[long]$RunId,[string]$BaseCommit,[string]$HeadCommit)
    if($Repository-cnotmatch'\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z'-or$RunId-lt1-or$PullRequestNumber-lt1-or$BaseCommit-cnotmatch'\A[0-9a-f]{40}\z'-or$HeadCommit-cnotmatch'\A[0-9a-f]{40}\z'){throw 'Hosted candidate identity is not canonical.'}
    if([long]$Run.id-ne$RunId-or[string]$Run.head_sha-cne$HeadCommit-or[string]$Run.event-cne'pull_request'-or[string]$Run.path-cne'.github/workflows/validate.yml'-or[int]$Run.run_attempt-lt1-or[string]$Run.status-cne'completed'-or[string]$Run.conclusion-cne'success'-or[long]$Run.workflow_id-lt1){throw 'Hosted candidate run is not the exact successful terminal provider run.'}
    $prs=@($Run.pull_requests)
    if($prs.Count-ne1-or[int]$prs[0].number-ne$PullRequestNumber-or[string]$prs[0].head.sha-cne$HeadCommit-or[string]$prs[0].base.sha-cne$BaseCommit){throw 'Hosted candidate run PR/base/head differs.'}
}
function Get-ReuseHostedRawRef([string]$Path,[string]$Root) {
    $full=[IO.Path]::GetFullPath($Path)
    $bytes=[IO.File]::ReadAllBytes($full)
    return [pscustomobject][ordered]@{path=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root),$full).Replace('\','/');bytes=[long]$bytes.Length;sha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()}
}
function Write-ReuseHostedJson([string]$Path,[object]$Value) {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 100 -Compress)+"`n")
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Assert-ReuseHostedNoReparse([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path)
    while(-not[string]::IsNullOrEmpty($p)){
        if((Test-Path -LiteralPath $p)-and(([IO.File]::GetAttributes($p)-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw 'Hosted intake rejects reparse-point paths.'}
        $p=[IO.Path]::GetDirectoryName($p)
    }
}
function Expand-ReuseHostedArchive {
    param([string]$ArchivePath,[string]$Destination,[string]$ExpectedDigest)
    if($ExpectedDigest-cnotmatch'\Asha256:[0-9a-f]{64}\z'-or('sha256:'+(Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant())-cne$ExpectedDigest){throw 'Hosted artifact ZIP digest differs from provider metadata.'}
    Assert-ReuseHostedNoReparse $Destination
    if(Test-Path -LiteralPath $Destination){throw 'Hosted ZIP destination already exists.'}
    $archive=[IO.Compression.ZipFile]::OpenRead($ArchivePath);$records=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$aliases=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase);$total=0L
    try{
        if($archive.Entries.Count-gt100000){throw 'Hosted ZIP entry ceiling exceeded.'}
        foreach($entry in $archive.Entries){
            $name=[string]$entry.FullName;$parts=$name.TrimEnd('/').Split('/')
            if([string]::IsNullOrEmpty($name)-or$name-match'[\\:\x00-\x1f<>"|?*]'-or$name.StartsWith('/')-or(($entry.ExternalAttributes-shr16)-band0xF000)-notin@(0,0x8000,0x4000)-or($entry.ExternalAttributes-band0x400)-ne0){throw 'Hosted ZIP has an unsafe path or symlink.'}
            foreach($part in $parts){if([string]::IsNullOrEmpty($part)-or$part-in@('.','..')-or$part-match'[. ]$'-or$part-match'(?i)\A(?:CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|\z)'){throw 'Hosted ZIP has an unsafe Windows path segment.'}}
            for($length=1;$length-le$parts.Count;$length++){
                $prefix=($parts[0..($length-1)]-join'/')
                if($aliases.ContainsKey($prefix)-and$aliases[$prefix]-cne$prefix){throw 'Hosted ZIP has case-aliased parent paths.'}
                $aliases[$prefix]=$prefix
            }
            if(-not$seen.Add($name.TrimEnd('/'))){throw 'Hosted ZIP has duplicate or aliased paths.'}
            $total+=$entry.Length;if($entry.Length-gt268435456-or$total-gt2147483648){throw 'Hosted ZIP expanded-size ceiling exceeded.'}
        }
        [void][IO.Directory]::CreateDirectory($Destination)
        foreach($entry in $archive.Entries){
            $path=Join-Path $Destination $entry.FullName
            if($entry.FullName.EndsWith('/')){[void][IO.Directory]::CreateDirectory($path);continue}
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));$input=$entry.Open();$output=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            try{$input.CopyTo($output);$output.Flush($true)}finally{$output.Dispose();$input.Dispose()}
            if((Get-Item -LiteralPath $path).Length-ne$entry.Length){throw 'Hosted ZIP extracted length differs.'}
            $records.Add((Get-ReuseHostedRawRef $path $Destination))
        }
    }finally{$archive.Dispose()}
    return @($records.ToArray())
}
function Get-ReuseHostedProviderArguments {
    param([string[]]$Arguments)
    if($Arguments.Count-ne2-or$Arguments[0]-cne'api'-or$Arguments[1]-cnotmatch'\Arepos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:pulls/[1-9][0-9]*|actions/artifacts/[1-9][0-9]*/zip|actions/runs/[1-9][0-9]*(?:/(?:jobs|artifacts)\?per_page=100&page=[1-9][0-9]*|/attempts/[1-9][0-9]*/jobs\?per_page=100&page=[1-9][0-9]*)?)\z'){throw 'Hosted provider requires its closed GET route.'}
    return @('api','--hostname','github.com',$Arguments[1])
}
function Invoke-ReuseHostedGet {
    param([object]$Context,[string[]]$Arguments,[string]$Name)
    if($Name-cnotmatch'\A[a-z0-9][a-z0-9-]{1,95}\z'){throw 'Hosted capture name is invalid.'}
    $path=Join-Path $Context.Output ('provider/'+$Name);[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $providerArguments=@(Get-ReuseHostedProviderArguments -Arguments $Arguments)
    $intent=[pscustomobject][ordered]@{executable=$Context.Gh;executable_sha256=$Context.GhSha;arguments=@($providerArguments);producer_sha256=$Context.ScriptSha;started_at=[DateTimeOffset]::UtcNow.ToString('o');automatic_retry=$false;termination_requested=$false}
    Write-ReuseHostedJson ($path+'.intent.json') $intent
    $execution=[pscustomobject]@{FileName=$Context.Gh;WorkingDirectory=$Context.RepositoryRoot;Arguments=@($providerArguments)}
    $result=Invoke-MorphospaceRetainedBuildProcess -Execution $execution -EnvironmentValues $Context.Environment -BaseReceiptPath $path -EstimatedWarningSeconds 60
    Write-ReuseHostedJson ($path+'.completion.json') $result
    $child=$result.ChildProcess
    if($result.ExitCode-ne0-or-not$child.process_reaped-or-not$child.stdout_eof-or-not$child.stderr_eof-or-not$child.raw_capture_complete-or$child.automatic_retry-or$child.termination_requested-or@($child.observer_errors).Count){throw 'Hosted provider original did not close successfully; raw failure retained.'}
    foreach($stream in @($result.Streams.stdout,$result.Streams.stderr)){
        if(-not$stream.eof-or$null-ne$stream.read_error-or$null-ne$stream.storage_error-or$stream.drained_bytes-ne$stream.stored_bytes-or$stream.stored_bytes-ne$stream.size_bytes-or(Get-FileHash -LiteralPath $stream.path -Algorithm SHA256).Hash.ToLowerInvariant()-cne$stream.sha256){throw 'Hosted provider raw stream closure differs.'}
    }
    return [string]$result.Streams.stdout.path
}
function Read-ReuseHostedGetJson {
    param([object]$Context,[string]$Endpoint,[string]$Name)
    $path=Invoke-ReuseHostedGet $Context @('api',$Endpoint) $Name
    return ([Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path))|ConvertFrom-Json -Depth 100 -DateKind String)
}
function Get-ReuseHostedPages {
    param([object]$Context,[string]$Endpoint,[string]$Property,[string]$Name)
    $rows=[Collections.Generic.List[object]]::new();$ids=[Collections.Generic.HashSet[long]]::new();$total=-1
    for($page=1;$page-le100;$page++){
        $value=Read-ReuseHostedGetJson $Context ($Endpoint+'?per_page=100&page='+$page) ($Name+'-'+$page)
        if($total-eq-1){$total=[long]$value.total_count}elseif([long]$value.total_count-ne$total){throw 'Hosted paginated inventory changed total_count.'}
        $batch=@($value.$Property);if($batch.Count-gt100){throw 'Hosted provider page exceeds its bound.'}
        foreach($item in $batch){if([long]$item.id-lt1-or-not$ids.Add([long]$item.id)){throw 'Hosted provider inventory repeats an ID.'};$rows.Add($item)}
        if($batch.Count-lt100){if($rows.Count-ne$total){throw 'Hosted provider inventory is incomplete.'};return @($rows.ToArray())}
    }
    throw 'Hosted provider page ceiling exceeded.'
}

function Read-ReuseHostedPayload {
    param([object]$Artifact,[string]$FileName,[string]$Schema,[string]$RepositoryRoot)
    $files=@($Artifact.files|Where-Object path -ceq $FileName)
    if($files.Count-ne1-or$Artifact.files.Count-ne1){throw 'Hosted single-payload artifact has an unexpected complete layout.'}
    $path=Join-Path $Artifact.directory $FileName;$raw=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path))
    if(-not(Test-Json -Json $raw -SchemaFile (Join-Path $RepositoryRoot ('schemas/'+$Schema)) -ErrorAction Stop)){throw 'Hosted payload fails its closed public schema.'}
    return ($raw|ConvertFrom-Json -Depth 100 -DateKind String)
}
function Assert-ReuseHostedExactSet([string[]]$Actual,[string[]]$Expected,[string]$Context) {
    $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($id in $Actual){if(-not$set.Add($id)){throw "Hosted $Context repeats a key."}}
    if(-not$set.SetEquals($Expected)){throw "Hosted $Context has missing or extra keys."}
}
function Get-ReuseHostedProducerJob {
    param([object[]]$Jobs,[long]$RunId,[int]$Attempt,[string]$HeadCommit,[string]$Name)
    foreach($job in $Jobs){if([long]$job.run_id-ne$RunId-or[int]$job.run_attempt-ne$Attempt-or[string]$job.head_sha-cne$HeadCommit){throw 'Hosted producer-attempt jobs differ from requested provider run/source.'}}
    $matched=@($Jobs|Where-Object name -ceq $Name)
    if($matched.Count-ne1-or[long]$matched[0].id-lt1-or[string]$matched[0].status-cne'completed'-or[string]$matched[0].conclusion-cne'success'){throw 'Hosted selected producer lacks exactly one successful provider job in its actual attempt.'}
    return $matched[0]
}
function Get-ReuseHostedRootBindingState {
    param([hashtable]$States,[object]$Root,[object]$Runner,[object]$AggregateRunner)
    # Called only after provider/artifact/staging/inventory joins authenticate
    # this root. The two producer APIs intentionally expose distinct OS strings.
    $key=[string]$Root.logical_id
    if(-not$States.ContainsKey($key)){$States[$key]=[pscustomobject]@{path=$Root.path;attempt=$Root.attempt;job=$Root.job;runner=$Runner;bindings=@{}}}
    $state=$States[$key]
    if([string]$state.path-cne[string]$Root.path-or[int]$state.attempt-ne[int]$Root.attempt-or[string]$state.job-cne[string]$Root.job-or(Get-MorphospaceCanonicalJsonSha256 $state.runner)-cne(Get-MorphospaceCanonicalJsonSha256 $Runner)-or[string]$Runner.powershell_version-cne[string]$AggregateRunner.powershell_version){throw 'Hosted selected leaf runner differs within its authenticated root or common PowerShell projection.'}
    return $state
}
function Get-ReuseHostedSelectedRows {
    param([object]$Context,[object]$Plan,[object[]]$Artifacts,[object[]]$Jobs)
    $registry=Read-MorphospaceProtocolJson (Join-Path $Context.RepositoryRoot 'manifests/affected-validation-registry.json')
    $compiled=Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $Context.RepositoryRoot -SchemaPath (Join-Path $Context.RepositoryRoot 'schemas/affected-validation-registry-v1.schema.json')
    $tree=Get-MorphospaceAffectedTreeInventory -RepositoryRoot $Context.RepositoryRoot -Commit $Context.Head
    $runnerSources=@(Get-MorphospaceAffectedCheckRunnerSourceManifest -Inventory $tree)
    $checkMap=@{};foreach($check in @($registry.checks)){$checkMap[[string]$check.check_id]=$check}
    $closures=@{};$allRows=[Collections.Generic.List[object]]::new();$platforms=[Collections.Generic.List[object]]::new();$expectedJobs=[Collections.Generic.List[string]]::new()
    foreach($name in @('infrastructure','select','quick-linux','quick-windows','standard-windows')){$expectedJobs.Add($name)}
    foreach($platform in @('linux','windows')){
        $selected=@($Plan.selected_checks|Where-Object{@($_.platforms)-ccontains$platform});if($selected.Count-eq0){continue}
        $aggregateCandidates=@($Artifacts|Where-Object{[string]$_.metadata.name-match('^affected-'+$platform+'-[0-9a-f]{64}-')})
        $selectedAggregate=@(Select-MorphospaceAffectedArtifactAttempts -Artifacts @($aggregateCandidates.metadata) -ExpectedIds @($platform) -RunId ([string]$Context.RunId) -CurrentAttempt $Context.Attempt)
        if($selectedAggregate.Count-ne1){throw 'Hosted platform lacks its unique winning aggregate.'}
        $aggregateArtifact=@($aggregateCandidates|Where-Object{[long]$_.metadata.id-eq[long]$selectedAggregate[0].artifact.id});if($aggregateArtifact.Count-ne1){throw 'Hosted aggregate lookup is ambiguous.'};$aggregateArtifact=$aggregateArtifact[0]
        $identity=$selectedAggregate[0].identity;$aggregate=Read-ReuseHostedPayload $aggregateArtifact $identity.file_name 'affected-validation-evidence-v1.schema.json' $Context.RepositoryRoot
        if([string]$aggregate.repository-cne$Context.Repository-or[string]$aggregate.plan_sha256-cne[string]$Plan.plan_sha256-or[string]$aggregate.platform-cne$platform-or[string]$aggregate.result-cne'pass'-or(Get-MorphospaceCanonicalJsonSha256 $aggregate.base)-cne(Get-MorphospaceCanonicalJsonSha256 $Plan.base)-or(Get-MorphospaceCanonicalJsonSha256 $aggregate.head)-cne(Get-MorphospaceCanonicalJsonSha256 $Plan.head)){throw 'Hosted aggregate source/plan/result differs.'}
        $aggregatePath=Join-Path $aggregateArtifact.directory $identity.file_name
        if((Get-FileHash -LiteralPath $aggregatePath -Algorithm SHA256).Hash.ToLowerInvariant()-cne$identity.digest){throw 'Hosted aggregate payload digest differs from its artifact name.'}
        $segmentArtifacts=@($Artifacts|Where-Object{([string]$_.metadata.name).StartsWith('affected-segment-'+$platform+'-',[StringComparison]::Ordinal)})
        if($platform-ceq'linux'-and$Context.LinuxMode-ceq'linux-direct'-and$segmentArtifacts.Count){throw 'Hosted direct Linux ambiguously contains segment producers.'}
        $segmented=$segmentArtifacts.Count-gt0
        if($platform-ceq'linux'-and$Context.LinuxMode-ceq'segmented'-and-not$segmented){throw 'Hosted source-qualified Linux segments are absent.'}
        $roots=[Collections.Generic.List[object]]::new();$selectionRef=$null
        if($segmented){
            $segments=@(Get-MorphospaceAffectedValidationSegments -Plan $Plan -Registry $registry -Platform $platform);$segmentIds=@($segments|ForEach-Object{[string]$_.segment_id})
            foreach($id in $segmentIds){$expectedJobs.Add('segment-'+$id)}
            $winners=@(Select-MorphospaceAffectedArtifactAttempts -Artifacts @($segmentArtifacts.metadata) -ExpectedIds $segmentIds -RunId ([string]$Context.RunId) -CurrentAttempt ([int]$identity.attempt))
            $selectionArtifacts=@($Artifacts|Where-Object{[string]$_.metadata.name-ceq('affected-selection-'+$platform+'-'+$Context.RunId+'-'+$identity.attempt)})
            if($selectionArtifacts.Count-ne1){throw 'Hosted segmented aggregate lacks its exact staging selection receipt.'}
            $selectionName='affected-'+$platform+'-selection.json';$selection=Read-ReuseHostedPayload $selectionArtifacts[0] $selectionName 'affected-validation-segment-selection-v1.schema.json' $Context.RepositoryRoot
            if([string]$selection.repository-cne$Context.Repository-or[string]$selection.run.id-cne[string]$Context.RunId-or[int]$selection.run.current_attempt-ne[int]$identity.attempt-or[string]$selection.source.platform-cne$platform-or[string]$selection.source.plan_sha256-cne[string]$Plan.plan_sha256-or(Get-MorphospaceCanonicalJsonSha256 $selection.source.base)-cne(Get-MorphospaceCanonicalJsonSha256 $Plan.base)-or(Get-MorphospaceCanonicalJsonSha256 $selection.source.head)-cne(Get-MorphospaceCanonicalJsonSha256 $Plan.head)){throw 'Hosted staging receipt source/run differs.'}
            Assert-ReuseHostedExactSet @($selection.selected.segment_id) $segmentIds 'selected logical segments'
            $selectionRef=Get-ReuseHostedRawRef (Join-Path $selectionArtifacts[0].directory $selectionName) $Context.Output
            foreach($winner in $winners){
                $a=@($segmentArtifacts|Where-Object{[long]$_.metadata.id-eq[long]$winner.artifact.id});if($a.Count-ne1){throw 'Hosted segment artifact lookup is ambiguous.'}
                $payload=Read-ReuseHostedPayload $a[0] $winner.identity.file_name 'affected-validation-evidence-v1.schema.json' $Context.RepositoryRoot
                $path=Join-Path $a[0].directory $winner.identity.file_name;$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();$declared=@($selection.selected|Where-Object segment_id -ceq $winner.identity.logical_id)
                if($declared.Count-ne1-or[string]$declared[0].artifact_name-cne[string]$winner.artifact.name-or[int]$declared[0].attempt-ne[int]$winner.identity.attempt-or[string]$declared[0].payload_sha256-cne$hash-or$hash-cne[string]$winner.identity.digest){throw 'Hosted staged winner does not equal its unique highest available raw segment.'}
                if([string]$payload.result-cne'pass'-or[string]$payload.platform-cne$platform-or[string]$payload.repository-cne$Context.Repository-or[string]$payload.plan_sha256-cne[string]$Plan.plan_sha256-or(Get-MorphospaceCanonicalJsonSha256 $payload.base)-cne(Get-MorphospaceCanonicalJsonSha256 $Plan.base)-or(Get-MorphospaceCanonicalJsonSha256 $payload.head)-cne(Get-MorphospaceCanonicalJsonSha256 $Plan.head)-or(Get-MorphospaceCanonicalJsonSha256 $payload.runner)-cne(Get-MorphospaceCanonicalJsonSha256 $aggregate.runner)){throw 'Hosted selected segment source/result/runner differs.'}
                $roots.Add([pscustomobject]@{logical_id=[string]$winner.identity.logical_id;attempt=[int]$winner.identity.attempt;payload=$payload;path=$path;job=('affected-'+$platform+'-segments')})
            }
        }else{
            $roots.Add([pscustomobject]@{logical_id=$platform;attempt=[int]$identity.attempt;payload=$aggregate;path=$aggregatePath;job=if($platform-ceq'linux'){'quick-linux'}else{'standard-windows'}})
        }
        $summaries=@($roots|ForEach-Object{@($_.payload.check_results)})
        Assert-ReuseHostedExactSet @($summaries.check_id) @($selected.check_id) ($platform+' selected root checks')
        if((Get-MorphospaceCanonicalJsonSha256 @($aggregate.check_results|Sort-Object check_id))-cne(Get-MorphospaceCanonicalJsonSha256 @($summaries|Sort-Object check_id))){throw 'Hosted aggregate records differ from selected roots.'}
        $snapshots=@{};$rowRoots=@{};$rootReports=[Collections.Generic.List[object]]::new()
        foreach($r in @($roots)){
            $name='affected-checks-'+$r.logical_id+'-'+$Context.MergeSha+'-'+$r.attempt
            $candidates=@($Artifacts|Where-Object{[string]$_.metadata.name-ceq$name})
            if($candidates.Count-ne1){throw 'Hosted selected root lacks exactly one finalized per-check artifact.'}
            $a=$candidates[0];$producer=[pscustomobject]@{context='github-actions';repository=$Context.Repository;event_name='pull_request';pull_request_number=$Context.PullRequestNumber;workflow_path='.github/workflows/validate.yml'}
            $validated=Read-MorphospaceAffectedCheckInventory -EvidenceDirectory $a.directory -ExpectedProducerContext $producer -InventorySchemaPath (Join-Path $Context.RepositoryRoot 'schemas/affected-validation-check-inventory-v1.schema.json')
            $inv=$validated.inventory
            if([string]$inv.producer.run_id-cne[string]$Context.RunId-or[int]$inv.producer.run_attempt-ne$r.attempt-or[string]$inv.producer.job-cne$r.job-or[string]$inv.platform-cne$platform-or[string]$inv.plan_sha256-cne[string]$Plan.plan_sha256-or(Get-MorphospaceCanonicalJsonSha256 $inv.source)-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{base=$Plan.base;head=$Plan.head}))){throw 'Hosted selected inventory producer attempt/job/platform/source differs.'}
            Assert-ReuseHostedExactSet @($inv.entries.check_id) @($r.payload.check_results.check_id) 'selected inventory root checks'
            foreach($snapshot in @($validated.candidate_snapshots)){
                $id=[string]$snapshot.check_id;if($snapshots.ContainsKey($id)){throw 'Hosted selected inventory repeats a current root.'};$snapshots[$id]=$snapshot;$rowRoots[$id]=[pscustomobject]@{root=$r;inventory=$inv;artifact=$a}
            }
            $rootReports.Add([pscustomobject]@{logical_id=$r.logical_id;attempt=$r.attempt;payload=Get-ReuseHostedRawRef $r.path $Context.Output;inventory=Get-ReuseHostedRawRef (Join-Path $a.directory 'inventory.json') $Context.Output;producer=$inv.producer})
        }
        $rootStates=@{};$counts=[ordered]@{executed=0;reused=0}
        foreach($selection in $selected){
            $id=[string]$selection.check_id;$check=$checkMap[$id];$snapshot=$snapshots[$id];$raw=[Convert]::FromBase64String($snapshot.receipt_base64);$receipt=[Text.UTF8Encoding]::new($false,$true).GetString($raw)|ConvertFrom-Json -Depth 100 -DateKind String
            $rootState=Get-ReuseHostedRootBindingState -States $rootStates -Root $rowRoots[$id].root -Runner $receipt.binding.runner -AggregateRunner $aggregate.runner
            $runner=$rootState.runner;$bindings=$rootState.bindings
            $key=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{command=$check.command_path;arguments=@($check.arguments);path_sets=@($check.consume_path_sets)})
            if(-not$closures.ContainsKey($key)){$closures[$key]=Get-MorphospaceAffectedCheckDependencyClosure -Check $check -CompiledRegistry $compiled -Inventory $tree -RepositoryRoot $Context.RepositoryRoot}
            $closure=$closures[$key];$prerequisites=@(foreach($prereq in @($check.prerequisite_checks)){if(-not$bindings.ContainsKey([string]$prereq)){throw 'Hosted current binding order omits a prerequisite.'};[pscustomobject]@{check_id=[string]$prereq;binding_sha256=[string]$bindings[[string]$prereq]}})
            $binding=New-MorphospaceAffectedCheckBinding -Repository $Context.Repository -Platform $platform -Check $check -Runner $runner -RunnerSourceManifest $runnerSources -DependencyManifest @($closure.manifest) -DependencyResolution $closure.resolution -PrerequisiteBindings $prerequisites
            $bindingSha=Get-MorphospaceCanonicalJsonSha256 $binding;$bindings[$id]=$bindingSha
            if([string]$receipt.mode-ceq'reused'){
                [void](Test-MorphospaceAffectedCheckReceipt -ReceiptPath $snapshot.receipt_path -SchemaPath (Join-Path $Context.RepositoryRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $binding -ExpectedBindingSha256 $bindingSha -RepositoryRoot $Context.RepositoryRoot -CurrentHeadCommit $Context.Head -PriorEvidenceRoot $rowRoots[$id].artifact.directory -CandidateSnapshot $snapshot)
                if((Get-MorphospaceCanonicalJsonSha256 $receipt.reused_from.source_head)-cne(Get-MorphospaceCanonicalJsonSha256 $receipt.source.head)){throw 'Hosted reused pointer source differs from retained evidence source.'}
            }elseif([string]$receipt.mode-ceq'executed'){
                if([string]$receipt.result-cne'pass'-or(Get-MorphospaceCanonicalJsonSha256 $receipt.binding)-cne(Get-MorphospaceCanonicalJsonSha256 $binding)-or[string]$receipt.binding_sha256-cne$bindingSha-or(Get-MorphospaceCanonicalJsonSha256 $receipt.source)-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{base=$Plan.base;head=$Plan.head}))-or[string]$receipt.plan_sha256-cne[string]$Plan.plan_sha256){throw 'Hosted executed current receipt binding/source differs.'}
                $phaseRoot=Join-Path ([IO.Path]::GetDirectoryName($snapshot.receipt_path)) 'artifacts'
                $phaseArtifacts=@(Get-MorphospaceAffectedCheckPhaseArtifacts -Check $check -PhaseEvidenceRoot $phaseRoot -ExpectedBinding $binding -ExpectedSource $receipt.source -ExpectedPlanSha256 ([string]$receipt.plan_sha256))
                [void](New-MorphospaceAffectedCheckSnapshot -Receipt $receipt -Stdout ([Convert]::FromBase64String($snapshot.stdout_base64)) -Stderr ([Convert]::FromBase64String($snapshot.stderr_base64)) -Artifacts $phaseArtifacts -SchemaPath (Join-Path $Context.RepositoryRoot 'schemas/affected-validation-check-evidence-v1.schema.json'))
            }else{throw 'Hosted selected current receipt is not passing executed or reused evidence.'}
            $entry=@($rowRoots[$id].inventory.entries|Where-Object check_id -ceq $id);$summary=@($rowRoots[$id].root.payload.check_results|Where-Object check_id -ceq $id)
            if($entry.Count-ne1-or$summary.Count-ne1-or[string]$entry[0].binding_sha256-cne$bindingSha-or[string]$entry[0].mode-cne[string]$receipt.mode-or[string]$entry[0].result-cne[string]$receipt.result){throw 'Hosted finalized inventory and leaf disagree.'}
            foreach($field in @('started','exit_code','failure_kind','timed_out','post_kill_drain_timed_out','output_truncated')){if($summary[0].$field-cne$receipt.child.$field){throw 'Hosted root summary child field differs from leaf.'}}
            foreach($stream in @('stdout','stderr')){if([long]$summary[0].($stream+'_bytes')-ne[long]$receipt.child.$stream.bytes-or[string]$summary[0].($stream+'_sha256')-cne[string]$receipt.child.$stream.sha256){throw 'Hosted root summary raw stream differs from leaf.'}}
            if([string]$summary[0].mode-cne[string]$receipt.mode-or[string]$summary[0].result-cne'pass'-or[string]$summary[0].command_path-cne[string]$binding.command_path-or[string]$summary[0].command_blob_sha1-cne[string]$binding.command_blob_sha1){throw 'Hosted summary command/mode/result differs from leaf.'}
            $counts[[string]$receipt.mode]++
            $allRows.Add([pscustomobject]@{platform=$platform;check_id=$id;mode=[string]$receipt.mode;result=[string]$receipt.result;producer=$rowRoots[$id].inventory.producer;receipt=Get-ReuseHostedRawRef $snapshot.receipt_path $Context.Output;evidence_source=$receipt.source;immediate_reused_from=$receipt.reused_from})
        }
        $platforms.Add([pscustomobject]@{platform=$platform;topology=if($segmented){'segmented'}else{'direct'};aggregate=Get-ReuseHostedRawRef $aggregatePath $Context.Output;selection=$selectionRef;roots=@($rootReports.ToArray());runner=[pscustomobject]@{aggregate=$aggregate.runner;roots=@(foreach($key in @($rootStates.Keys|Sort-Object)){[pscustomobject]@{logical_id=$key;check_binding=$rootStates[$key].runner}})};counts=$counts})
    }
    Assert-ReuseHostedExactSet @($Jobs|Where-Object conclusion -ceq 'success'|ForEach-Object{[string]$_.name}) @($expectedJobs.ToArray()) 'successful job identities'
    foreach($job in $Jobs){if([string]$job.status-cne'completed'-or[string]$job.conclusion-cnotin@('success','skipped')){throw 'Hosted run contains incomplete or nonpassing jobs.'}}
    return [pscustomobject]@{rows=@($allRows.ToArray());platforms=@($platforms.ToArray())}
}

function Invoke-ReuseHostedIntake {
    param([string]$RepositoryRoot,[string]$BeforeCommit,[string]$HeadCommit,[string]$Repository,[int]$PullRequestNumber,[long]$RunId,[string]$GhPath,[string]$OutputDirectory)
    if($Repository-cnotmatch'\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z'-or$PullRequestNumber-lt1-or$RunId-lt1-or$BeforeCommit-cnotmatch'\A[0-9a-f]{40}\z'-or$HeadCommit-cnotmatch'\A[0-9a-f]{40}\z'){throw 'Hosted candidate arguments must be exact canonical identities.'}
    $candidateRoot=[IO.Path]::GetFullPath($RepositoryRoot);$out=[IO.Path]::GetFullPath($OutputDirectory);$tool=[IO.Path]::GetFullPath($GhPath);$ownerRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    if(-not[IO.Path]::IsPathFullyQualified($GhPath)-or-not[IO.File]::Exists($tool)-or-not[IO.Path]::IsPathFullyQualified($OutputDirectory)){throw 'Hosted intake requires absolute existing provider and absolute fresh output.'}
    Assert-ReuseHostedNoReparse $out;Assert-ReuseHostedNoReparse $tool
    if(Test-Path -LiteralPath $out){throw 'Hosted output directory already exists.'}
    foreach($sourceRoot in @($candidateRoot,$ownerRoot)){
        $prefix=$out.TrimEnd('/','\')+[IO.Path]::DirectorySeparatorChar
        if($sourceRoot.Equals($out,[StringComparison]::OrdinalIgnoreCase)-or$sourceRoot.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Hosted output may not contain a source root.'}
        $gitPrefix=(Join-Path $sourceRoot '.git').TrimEnd('/','\')+[IO.Path]::DirectorySeparatorChar
        if($out.StartsWith($gitPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Hosted output may not enter Git control storage.'}
    }
    $holds=[Collections.Generic.List[object]]::new();$sourceRecords=[Collections.Generic.List[object]]::new();$producerHead='';$producerTree=''
    try{
        foreach($sourceRoot in @($candidateRoot,$ownerRoot)|Select-Object -Unique){
            $status=& git -C $sourceRoot status --porcelain --untracked-files=all 2>&1;if($LASTEXITCODE-ne0-or@($status).Count){throw 'Hosted intake requires clean source/producer checkouts.'}
            $sourceHead=(& git -C $sourceRoot rev-parse HEAD).Trim();if($LASTEXITCODE-ne0){throw 'Hosted source identity unavailable.'}
            if($sourceRoot-ceq$candidateRoot-and$sourceHead-cne$HeadCommit){throw 'Hosted candidate checkout HEAD differs.'}
            if($sourceRoot-ceq$ownerRoot){$producerHead=$sourceHead;$producerTree=(& git -C $sourceRoot rev-parse 'HEAD^{tree}').Trim()}
            $sourcePrefix=$sourceRoot.TrimEnd('/','\')+[IO.Path]::DirectorySeparatorChar
            if($out.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)){
                & git -C $sourceRoot check-ignore --quiet -- $out
                if($LASTEXITCODE-ne0){throw 'Hosted output inside a checkout must be ignored.'}
            }
        }
        # Hold exact existing owner libraries, entrypoint and schemas, not caller DTOs.
        $paths=@('scripts/Test-AffectedValidationReuse.ps1')+@(& git -C $ownerRoot ls-files 'scripts/*.ps1' 'scripts/lib/*.psm1' 'schemas/affected-validation-*.schema.json' 'manifests/affected-validation-registry.json' '.github/workflows/validate.yml')
        if($LASTEXITCODE-ne0){throw 'Hosted producer source inventory unavailable.'}
        foreach($relative in @($paths|Sort-Object -Unique)){
            $path=Join-Path $ownerRoot $relative;Assert-ReuseHostedNoReparse $path
            $hold=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($hold)
            $blob=(& git -C $ownerRoot rev-parse ('HEAD:'+$relative)).Trim();$observedBlob=(& git -C $ownerRoot hash-object --no-filters -- $path).Trim()
            if($LASTEXITCODE-ne0-or$blob-cne$observedBlob){throw 'Hosted producer working bytes differ from tracked source.'}
            $raw=Get-ReuseHostedRawRef $path $ownerRoot;$sourceRecords.Add([pscustomobject]@{path=$relative;bytes=$raw.bytes;sha256=$raw.sha256;git_blob_sha1=$blob})
        }
        if($candidateRoot-cne$ownerRoot){
            foreach($relative in @(& git -C $candidateRoot ls-files '.github/workflows/validate.yml' 'manifests/affected-validation-registry.json' 'scripts/*.ps1' 'scripts/lib/*.psm1' 'schemas/affected-validation-*.schema.json')){
                $path=Join-Path $candidateRoot $relative;Assert-ReuseHostedNoReparse $path;$holds.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
                $blob=(& git -C $candidateRoot rev-parse ('HEAD:'+$relative)).Trim();$physical=(& git -C $candidateRoot hash-object --no-filters -- $path).Trim();if($LASTEXITCODE-ne0-or$blob-cne$physical){throw 'Hosted candidate input differs from exact Git source.'}
            }
        }
        $toolHold=[IO.File]::Open($tool,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($toolHold)
        $toolSha=(Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash.ToLowerInvariant();$scriptSha=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationArtifactTransport.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationCheckEvidence.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceRetainedBuildProcess.psm1') -Force -DisableNameChecking
        [void][IO.Directory]::CreateDirectory($out)
        $environment=@{};foreach($key in [Environment]::GetEnvironmentVariables('Process').Keys){$environment[[string]$key]=[string][Environment]::GetEnvironmentVariable([string]$key,'Process')};[void]$environment.Remove('GH_DEBUG')
        $context=[pscustomobject]@{Output=$out;RepositoryRoot=$candidateRoot;Gh=$tool;GhSha=$toolSha;ScriptSha=$scriptSha;Environment=$environment;Repository=$Repository;Head=$HeadCommit;RunId=$RunId;PullRequestNumber=$PullRequestNumber;Attempt=0;MergeSha='';LinuxMode=''}
        $prefix='repos/'+$Repository
        $run=Read-ReuseHostedGetJson $context ($prefix+'/actions/runs/'+$RunId) 'run-initial'
        Assert-ReuseHostedRun -Run $run -Repository $Repository -PullRequestNumber $PullRequestNumber -RunId $RunId -BaseCommit $BeforeCommit -HeadCommit $HeadCommit
        $context.Attempt=[int]$run.run_attempt
        $pr=Read-ReuseHostedGetJson $context ($prefix+'/pulls/'+$PullRequestNumber) 'pull-request'
        if([int]$pr.number-ne$PullRequestNumber-or[string]$pr.head.sha-cne$HeadCommit-or[string]$pr.base.sha-cne$BeforeCommit-or[string]$pr.state-cne'open'-or[string]$pr.head.repo.full_name-cne$Repository-or[string]$pr.base.repo.full_name-cne$Repository-or[string]$pr.merge_commit_sha-cnotmatch'\A[0-9a-f]{40}\z'){throw 'Hosted provider PR source/merge context differs.'}
        $context.MergeSha=[string]$pr.merge_commit_sha
        $jobs=@(Get-ReuseHostedPages $context ($prefix+'/actions/runs/'+$RunId+'/jobs') 'jobs' 'jobs')
        foreach($job in $jobs){if([long]$job.run_id-ne$RunId-or[string]$job.head_sha-cne$HeadCommit-or[int]$job.run_attempt-ne$context.Attempt){throw 'Hosted latest job observation run/head/attempt differs.'}}
        $metadata=@(Get-ReuseHostedPages $context ($prefix+'/actions/runs/'+$RunId+'/artifacts') 'artifacts' 'artifacts')
        $artifacts=[Collections.Generic.List[object]]::new();$names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($item in $metadata){
            if(-not$names.Add([string]$item.name)){throw 'Hosted provider artifact names are duplicated.'}
            if(-not(([string]$item.name).StartsWith('affected-',[StringComparison]::Ordinal))){continue}
            # Diagnostics are retained provider data, never candidate PASS roots.
            if([string]$item.name-match'-diagnostic-'){continue}
            if([long]$item.workflow_run.id-ne$RunId-or[string]$item.workflow_run.head_sha-cne$HeadCommit-or$item.expired-isnot[bool]-or$item.expired-or[DateTimeOffset]::Parse([string]$item.expires_at)-le[DateTimeOffset]::UtcNow){throw 'Hosted artifact provider source/expiry differs.'}
            $folder=Join-Path $out ('artifacts/'+$item.id);[void][IO.Directory]::CreateDirectory($folder)
            $zip=Invoke-ReuseHostedGet $context @('api',($prefix+'/actions/artifacts/'+$item.id+'/zip')) ('artifact-'+$item.id)
            $destination=Join-Path $folder 'files';$entries=@(Expand-ReuseHostedArchive $zip $destination ([string]$item.digest))
            Write-ReuseHostedJson (Join-Path $folder 'artifact.json') $item;Write-ReuseHostedJson (Join-Path $folder 'members.json') $entries
            $artifacts.Add([pscustomobject]@{metadata=$item;directory=$destination;files=$entries})
        }
        foreach($file in @(Get-ChildItem -LiteralPath $out -File -Recurse)){$holds.Add([IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))}
        $planArtifacts=@($artifacts|Where-Object{[string]$_.metadata.name-match'^affected-plan-[0-9a-f]{64}-'})
        $planWinner=@(Select-MorphospaceAffectedArtifactAttempts -Artifacts @($planArtifacts.metadata) -ExpectedIds @('plan') -RunId ([string]$RunId) -CurrentAttempt $context.Attempt)
        if($planWinner.Count-ne1){throw 'Hosted uploaded plan is not unique.'}
        $planArtifact=@($planArtifacts|Where-Object{[long]$_.metadata.id-eq[long]$planWinner[0].artifact.id})
        if($planArtifact.Count-ne1){throw 'Hosted uploaded plan is not unique.'}
        $plan=Read-ReuseHostedPayload $planArtifact[0] 'affected-plan.json' 'affected-validation-plan-v2.schema.json' $candidateRoot
        $planPath=Join-Path $planArtifact[0].directory 'affected-plan.json'
        if(-not$plan.execution_permitted-or[string]$plan.selection_mode-ceq'mapping-incomplete'-or[string]$plan.repository-cne$Repository-or[string]$plan.base.commit-cne$BeforeCommit-or[string]$plan.head.commit-cne$HeadCommit-or[string]$plan.plan_sha256-cne[string]$planWinner[0].identity.digest){throw 'Hosted uploaded plan does not bind executable exact source.'}
        $recomputed=Resolve-MorphospaceAffectedValidation -RepositoryRoot $candidateRoot -BaseRevision $BeforeCommit -HeadRevision $HeadCommit -RegistryPath (Join-Path $candidateRoot 'manifests/affected-validation-registry.json') -RequestedTier ([string]$plan.requested_tier)
        if((Get-MorphospaceCanonicalJsonSha256 $plan)-cne(Get-MorphospaceCanonicalJsonSha256 $recomputed)){throw 'Hosted plan differs from exact public selector.'}
        $workflowPath=Join-Path $candidateRoot '.github/workflows/validate.yml';$context.LinuxMode=Get-ReuseCandidateLinuxExecutionMode ([IO.File]::ReadAllText($workflowPath,[Text.UTF8Encoding]::new($false,$true)))
        $selected=Get-ReuseHostedSelectedRows -Context $context -Plan $plan -Artifacts @($artifacts.ToArray()) -Jobs $jobs
        $jobsByAttempt=@{};$jobsByAttempt[[string]$context.Attempt]=$jobs
        foreach($platform in @($selected.platforms)){
            foreach($root in @($platform.roots)){
                $attempt=[int]$root.attempt;$label=if($attempt-eq$context.Attempt){'jobs'}else{'jobs-attempt-'+$attempt}
                if(-not$jobsByAttempt.ContainsKey([string]$attempt)){$jobsByAttempt[[string]$attempt]=@(Get-ReuseHostedPages $context ($prefix+'/actions/runs/'+$RunId+'/attempts/'+$attempt+'/jobs') 'jobs' $label)}
                $name=if([string]$root.logical_id-ceq'linux'){'quick-linux'}elseif([string]$root.logical_id-ceq'windows'){'standard-windows'}else{'segment-'+$root.logical_id}
                $job=Get-ReuseHostedProducerJob -Jobs @($jobsByAttempt[[string]$attempt]) -RunId $RunId -Attempt $attempt -HeadCommit $HeadCommit -Name $name
                $root|Add-Member -NotePropertyName provider_job -NotePropertyValue ([pscustomobject]@{id=[long]$job.id;run_id=$RunId;run_attempt=$attempt;name=[string]$job.name;head_sha=[string]$job.head_sha;status=[string]$job.status;conclusion=[string]$job.conclusion;observation=$label})
            }
        }
        foreach($artifact in @($artifacts.ToArray())){
            $actual=@(Get-ChildItem -LiteralPath $artifact.directory -File -Recurse|ForEach-Object{[IO.Path]::GetRelativePath($artifact.directory,$_.FullName).Replace('\','/')})
            Assert-ReuseHostedExactSet $actual @($artifact.files.path) 'extracted artifact postimage'
            foreach($member in @($artifact.files)){$path=Join-Path $artifact.directory $member.path;Assert-ReuseHostedNoReparse $path;$observed=Get-ReuseHostedRawRef $path $artifact.directory;if($observed.bytes-ne$member.bytes-or$observed.sha256-cne$member.sha256){throw 'Hosted extracted member changed during verification.'}}
        }
        $final=Read-ReuseHostedGetJson $context ($prefix+'/actions/runs/'+$RunId) 'run-final'
        Assert-ReuseHostedRun -Run $final -Repository $Repository -PullRequestNumber $PullRequestNumber -RunId $RunId -BaseCommit $BeforeCommit -HeadCommit $HeadCommit
        if([int]$final.run_attempt-ne$context.Attempt-or[long]$final.workflow_id-ne[long]$run.workflow_id){throw 'Hosted run changed attempt/workflow during intake.'}
        foreach($r in $sourceRecords){$path=Join-Path $ownerRoot $r.path;if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()-cne$r.sha256){throw 'Hosted producer source changed.'}}
        if((Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash.ToLowerInvariant()-cne$toolSha){throw 'Hosted provider executable changed.'}
        foreach($sourceRoot in @($candidateRoot,$ownerRoot)|Select-Object -Unique){$status=& git -C $sourceRoot status --porcelain --untracked-files=all 2>&1;if($LASTEXITCODE-ne0-or@($status).Count){throw 'Hosted source changed during intake.'}}
        if((& git -C $candidateRoot rev-parse HEAD).Trim()-cne$HeadCommit-or(& git -C $ownerRoot rev-parse HEAD).Trim()-cne$producerHead){throw 'Hosted source HEAD changed during intake.'}
        $rawFiles=@(Get-ChildItem -LiteralPath $out -File -Recurse|Sort-Object FullName|ForEach-Object{Get-ReuseHostedRawRef $_.FullName $out});$manifestPath=Join-Path $out 'raw-manifest.json';Write-ReuseHostedJson $manifestPath ([pscustomobject]@{files=$rawFiles})
        $report=[pscustomobject][ordered]@{schema='rusty.morphospace.diagnostic.affected_validation_hosted_intake.v1';result='pass';hosted_evidence_valid=$true;complete_leaf_union=$true;observed_at=[DateTimeOffset]::UtcNow.ToString('o');repository=$Repository;base=$plan.base;head=$plan.head;pull_request_number=$PullRequestNumber;run=[pscustomobject]@{id=$RunId;attempt=$context.Attempt;event=$run.event;status=$run.status;conclusion=$run.conclusion;workflow_id=$run.workflow_id};plan=[pscustomobject]@{file=Get-ReuseHostedRawRef $planPath $out;canonical_sha256=$plan.plan_sha256};platforms=$selected.platforms;rows=$selected.rows;counts=[pscustomobject]@{selected_rows=$selected.rows.Count;executed=@($selected.rows|Where-Object mode -ceq 'executed').Count;reused=@($selected.rows|Where-Object mode -ceq 'reused').Count};raw_manifest=Get-ReuseHostedRawRef $manifestPath $out;producer=[pscustomobject]@{entrypoint='scripts/Test-AffectedValidationReuse.ps1';commit=$producerHead;tree=$producerTree;source_refs=@($sourceRecords.ToArray());provider_executable_sha256=$toolSha;provider_hostname='github.com'};claims=[pscustomobject]@{current_source_qualified_self_contained_evidence=$true;historical_genesis_reverified=$false;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}}
        $reportPath=Join-Path $out 'hosted-intake.json';Write-ReuseHostedJson $reportPath $report
        return [pscustomobject]@{hosted_evidence_valid=$true;report=Get-ReuseHostedRawRef $reportPath $out;output_directory=$out;acceptance_authority=$false;publication_authority=$false}
    }finally{foreach($hold in $holds){$hold.Dispose()}}
}

function Invoke-ReuseHostedProviderControls {
    param([string]$Fixture)
    $endpoint='repos/MesmerPrism/rusty-morphospace-work-environment/actions/runs/101'
    $arguments=@(Get-ReuseHostedProviderArguments @('api',$endpoint))
    if(($arguments-join'|')-cne('api|--hostname|github.com|'+$endpoint)){throw 'Hosted GET provider host/argv binding differs.'}
    foreach($bad in @(@('api','https://foreign.invalid/route'),@('run','watch'),@('api',$endpoint,'--method','POST'),@('api',$endpoint+'/jobs?per_page=100&page=0'),@('api','repos/MesmerPrism/rusty-morphospace-work-environment/issues/1'))){$refused=$false;try{[void](Get-ReuseHostedProviderArguments $bad)}catch{$refused=$true};if(-not$refused){throw 'Hosted provider accepted a foreign host, command or non-GET route.'}}
    [void](Get-ReuseHostedProviderArguments @('api',($endpoint+'/attempts/1/jobs?per_page=100&page=1')))
    $producerJob=[pscustomobject]@{id=77;run_id=101;run_attempt=1;head_sha=('a'*40);name='segment-windows-001';status='completed';conclusion='success'}
    [void](Get-ReuseHostedProducerJob @($producerJob) 101 1 ('a'*40) 'segment-windows-001')
    foreach($damage in @('attempt','head','run','name','status','result','duplicate','missing')){
        $job=$producerJob|ConvertTo-Json|ConvertFrom-Json;$values=@($job)
        switch($damage){attempt{$job.run_attempt=2}head{$job.head_sha=('b'*40)}run{$job.run_id=102}name{$job.name='segment-windows-002'}status{$job.status='in_progress'}result{$job.conclusion='failure'}duplicate{$values=@($job,$job)}missing{$values=@()}}
        $refused=$false;try{[void](Get-ReuseHostedProducerJob $values 101 1 ('a'*40) 'segment-windows-001')}catch{$refused=$true};if(-not$refused){throw "Hosted producer-attempt control accepted $damage drift."}
    }
    $run=[pscustomobject]@{id=101;head_sha=('a'*40);event='pull_request';path='.github/workflows/validate.yml';run_attempt=3;status='completed';conclusion='success';workflow_id=11;pull_requests=@([pscustomobject]@{number=7;head=[pscustomobject]@{sha=('a'*40)};base=[pscustomobject]@{sha=('b'*40)}})}
    Assert-ReuseHostedRun -Run $run -Repository 'MesmerPrism/rusty-morphospace-work-environment' -PullRequestNumber 7 -RunId 101 -BaseCommit ('b'*40) -HeadCommit ('a'*40)
    foreach($name in @('head','base','pr','event','workflow','attempt','nonpass','pending','run')){
        $damaged=$run|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
        switch($name){head{$damaged.head_sha=('c'*40)}base{$damaged.pull_requests[0].base.sha=('c'*40)}pr{$damaged.pull_requests[0].number=8}event{$damaged.event='push'}workflow{$damaged.path='.github/workflows/foreign.yml'}attempt{$damaged.run_attempt=0}nonpass{$damaged.conclusion='failure'}pending{$damaged.status='in_progress'}run{$damaged.id=102}}
        $refused=$false
        try{Assert-ReuseHostedRun -Run $damaged -Repository 'MesmerPrism/rusty-morphospace-work-environment' -PullRequestNumber 7 -RunId 101 -BaseCommit ('b'*40) -HeadCommit ('a'*40)}catch{$refused=$true}
        if(-not$refused){throw "Hosted provider control accepted $name drift."}
    }
    $zipRoot=Join-Path $Fixture 'hosted-zip-controls';[void][IO.Directory]::CreateDirectory($zipRoot)
    function New-HostedControlZip([string]$Path,[string[]]$Names){
        $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew);$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
        try{foreach($name in $Names){$entry=$zip.CreateEntry($name);$target=$entry.Open();try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes('fixture');$target.Write($bytes,0,$bytes.Length)}finally{$target.Dispose()}}}finally{$zip.Dispose();$stream.Dispose()}
    }
    $zipPath=Join-Path $zipRoot 'safe.zip';New-HostedControlZip $zipPath @('nested/safe.json')
    $digest='sha256:'+(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $rows=@(Expand-ReuseHostedArchive -ArchivePath $zipPath -Destination (Join-Path $zipRoot 'safe') -ExpectedDigest $digest)
    if($rows.Count-ne1-or$rows[0].path-cne'nested/safe.json'-or$rows[0].bytes-ne7){throw 'Hosted ZIP positive did not consume actual ZIP bytes.'}
    $badNames=@(@('../escape.json'),@('/absolute.json'),@('drive:c.json'),@('a\b.json'),@('CON.json'),@('a./b'),@('same.json','SAME.json'),@('Upper/a.json','upper/b.json'),@('question?.json'),@('pipe|.json'),@(('COM'+[char]0x00b9+'.json')),@(('LPT'+[char]0x00b2+'.json')),@(('COM'+[char]0x00b3+'.json')))
    for($index=0;$index-lt$badNames.Count;$index++){
        $path=Join-Path $zipRoot ('bad-'+$index+'.zip');New-HostedControlZip $path $badNames[$index]
        $hash='sha256:'+(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();$refused=$false
        try{[void](Expand-ReuseHostedArchive $path (Join-Path $zipRoot ('bad-'+$index)) $hash)}catch{$refused=$true}
        if(-not$refused){throw "Hosted ZIP control accepted unsafe path case $index."}
    }
    $refused=$false;try{[void](Expand-ReuseHostedArchive $zipPath (Join-Path $zipRoot 'wrong-digest') ('sha256:'+('0'*64)))}catch{$refused=$true};if(-not$refused){throw 'Hosted ZIP control accepted changed digest.'}
    # Two independently assigned Windows producers may have the same enforced
    # aggregate OSVersion/PS tuple and different legal full binding tool tuples.
    $states=@{};$aggregateRunner=[pscustomobject]@{os_description='Microsoft Windows NT modeled';powershell_version=$PSVersionTable.PSVersion.ToString()}
    $runnerA=[pscustomobject]@{os_description='Microsoft Windows modeled';powershell_version=$PSVersionTable.PSVersion.ToString();process_architecture='x64';git_version='modeled-git-A';git_executable_sha256=('a'*64);powershell_executable_sha256=('b'*64)}
    $runnerB=$runnerA|ConvertTo-Json|ConvertFrom-Json;$runnerB.git_version='modeled-git-B';$runnerB.git_executable_sha256=('c'*64)
    $rootA=[pscustomobject]@{logical_id='windows-001';path='modeled-windows-001';attempt=1;job='affected-windows-segments'};$rootB=[pscustomobject]@{logical_id='windows-002';path='modeled-windows-002';attempt=2;job='affected-windows-segments'}
    $stateA=Get-ReuseHostedRootBindingState $states $rootA $runnerA $aggregateRunner;$stateA.bindings['prerequisite']=('d'*64)
    $stateB=Get-ReuseHostedRootBindingState $states $rootB $runnerB $aggregateRunner
    if($stateB.bindings.ContainsKey('prerequisite')){throw 'Hosted root borrowed another producer prerequisite binding.'}
    [void](Get-ReuseHostedRootBindingState $states $rootA $runnerA $aggregateRunner)
    $refused=$false;try{[void](Get-ReuseHostedRootBindingState $states $rootA $runnerB $aggregateRunner)}catch{$refused=$true};if(-not$refused){throw 'Hosted root accepted another producer full runner tuple.'}
    $wrongRoot=$rootA|ConvertTo-Json|ConvertFrom-Json;$wrongRoot.attempt=3;$refused=$false;try{[void](Get-ReuseHostedRootBindingState $states $wrongRoot $runnerA $aggregateRunner)}catch{$refused=$true};if(-not$refused){throw 'Hosted root accepted another attempt identity.'}
    Write-Host 'Candidate-hosted provider controls passed (modeled provider, no GitHub or product credit).'
}

function Invoke-ReuseHostedProducerControls {
    param([string]$Fixture,[string]$SourceRoot)
    # The provider is modeled, but every leaf/inventory is emitted by the real
    # production runner. No historical receipt is supplied to the intake reader.
    $retainedRoot=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-hosted-producer-'+[Guid]::NewGuid().ToString('N'));$repo=Join-Path $retainedRoot 'source';[void][IO.Directory]::CreateDirectory($repo)
    foreach($relative in @(& git -C $Fixture ls-files)){
        $source=Join-Path $Fixture $relative;$target=Join-Path $repo $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::WriteAllBytes($target,[IO.File]::ReadAllBytes($source))
    }
    foreach($relative in @('scripts/Invoke-AffectedValidation.ps1')+@(& git -C $SourceRoot ls-files 'scripts/lib/*.psm1' 'schemas/affected-validation-*.schema.json')){
        $target=Join-Path $repo $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::WriteAllBytes($target,[IO.File]::ReadAllBytes((Join-Path $SourceRoot $relative)))
    }
    foreach($relative in @('scripts/Test-DocumentationLinks.ps1','scripts/Test-PublicBoundary.ps1')){Write-ReuseSelfUtf8 (Join-Path $repo $relative) "Write-Output 'modeled ordinary leaf'`n"}
    Write-ReuseSelfUtf8 (Join-Path $repo '.gitignore') ".local/`n"
    [void](Invoke-ReuseSelfGit $repo @('init','-b','main'));[void](Invoke-ReuseSelfGit $repo @('config','user.email','fixture@example.invalid'));[void](Invoke-ReuseSelfGit $repo @('config','user.name','Hosted intake fixture'))
    [void](Invoke-ReuseSelfGit $repo @('add','.'));[void](Invoke-ReuseSelfGit $repo @('commit','-m','fixture source'));$before=Invoke-ReuseSelfGit $repo @('rev-parse','HEAD')
    $changePath='docs/hosted-intake-'+[Guid]::NewGuid().ToString('N')+'.md';Write-ReuseSelfUtf8 (Join-Path $repo $changePath) "ordinary source change`n";[void](Invoke-ReuseSelfGit $repo @('add',$changePath));[void](Invoke-ReuseSelfGit $repo @('commit','-m','fixture input'));$head=Invoke-ReuseSelfGit $repo @('rev-parse','HEAD')
    $plan=Resolve-MorphospaceAffectedValidation -RepositoryRoot $repo -BaseRevision $before -HeadRevision $head -RegistryPath (Join-Path $repo 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-ReuseHostedExactSet @($plan.selected_checks.check_id) @('public-boundary','documentation-links') 'real producer fixture selection'
    Import-Module (Join-Path $SourceRoot 'scripts/lib/MorphospaceAffectedValidationCheckEvidence.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $SourceRoot 'scripts/lib/MorphospaceRetainedBuildProcess.psm1') -Force -DisableNameChecking
    $envMap=@{};foreach($key in [Environment]::GetEnvironmentVariables('Process').Keys){$envMap[[string]$key]=[string][Environment]::GetEnvironmentVariable([string]$key,'Process')}
    $envMap['GITHUB_ACTIONS']='true';$envMap['GITHUB_REPOSITORY']=[string]$plan.repository;$envMap['GITHUB_EVENT_NAME']='pull_request';$envMap['GITHUB_RUN_ID']='101';$envMap['GITHUB_WORKFLOW_REF']=([string]$plan.repository+'/.github/workflows/validate.yml@refs/pull/7/merge');$envMap['GITHUB_JOB']='quick-linux';$envMap['PR_NUMBER']='7';$envMap['RUNNER_TEMP']=[IO.Path]::GetTempPath()
    $jobs=@(foreach($name in @('infrastructure','select','quick-linux','quick-windows','standard-windows')){[pscustomobject]@{name=$name;status='completed';conclusion='success'}})
    $prior='';$output=Join-Path $retainedRoot 'output';[void][IO.Directory]::CreateDirectory($output);Write-Host ('Hosted producer fixture evidence: '+$output)
    for($attempt=1;$attempt-le3;$attempt++){
        $stage=Join-Path $output ('attempt-'+$attempt);[void][IO.Directory]::CreateDirectory($stage);$planPath=Join-Path $stage 'affected-plan.json';Write-ReuseSelfUtf8 $planPath (($plan|ConvertTo-Json -Depth 100 -Compress)+"`n")
        $evidencePath=Join-Path $stage 'aggregate.json';$inventoryRoot=Join-Path $stage 'checks';$envMap['GITHUB_RUN_ATTEMPT']=[string]$attempt
        $args=@('-NoProfile','-File',(Join-Path $repo 'scripts/Invoke-AffectedValidation.ps1'),'-RepositoryRoot',$repo,'-BaseCommit',$before,'-HeadCommit',$head,'-PlanPath',$planPath,'-Platform','linux','-OutPath',$evidencePath,'-CheckEvidenceDirectory',$inventoryRoot)
        if($prior){$args+=@('-PriorEvidenceDirectory',$prior)}
        $execution=[pscustomobject]@{FileName=(Get-Process -Id $PID).Path;Arguments=$args;WorkingDirectory=$repo}
        $original=Invoke-MorphospaceRetainedBuildProcess -Execution $execution -EnvironmentValues $envMap -BaseReceiptPath (Join-Path $stage 'original') -EstimatedWarningSeconds 60
        Write-ReuseHostedJson (Join-Path $stage 'original.completion.json') $original
        if($original.ExitCode-ne0-or-not$original.ChildProcess.process_reaped-or-not$original.ChildProcess.stdout_eof-or-not$original.ChildProcess.stderr_eof-or-not$original.ChildProcess.raw_capture_complete){[Console]::Error.WriteLine([IO.File]::ReadAllText($original.Streams.stderr.path));throw "Hosted real producer fixture did not close successfully: $stage"}
        $payload=Read-MorphospaceProtocolJson $evidencePath;$hash=Get-ReuseSelfHash $evidencePath
        $aggregateName='affected-linux-'+$hash+'-101-'+$attempt;$aggregateFile='affected-linux-evidence.json';$aggregateDir=Join-Path $stage 'aggregate-artifact';[void][IO.Directory]::CreateDirectory($aggregateDir);[IO.File]::Copy($evidencePath,(Join-Path $aggregateDir $aggregateFile))
        $artifacts=@([pscustomobject]@{metadata=[pscustomobject]@{id=1;name=$aggregateName};directory=$aggregateDir;files=@(Get-ReuseHostedRawRef (Join-Path $aggregateDir $aggregateFile) $aggregateDir)},[pscustomobject]@{metadata=[pscustomobject]@{id=2;name=('affected-checks-linux-'+$head+'-'+$attempt)};directory=$inventoryRoot;files=@(Get-ChildItem -LiteralPath $inventoryRoot -File -Recurse|ForEach-Object{Get-ReuseHostedRawRef $_.FullName $inventoryRoot})})
        $context=[pscustomobject]@{RepositoryRoot=$repo;Head=$head;Repository=$plan.repository;RunId=101;Attempt=$attempt;PullRequestNumber=7;LinuxMode='linux-direct';MergeSha=$head;Output=$output}
        $selected=Get-ReuseHostedSelectedRows -Context $context -Plan $plan -Artifacts $artifacts -Jobs $jobs
        $expectedMode=if($attempt-eq1){'executed'}else{'reused'}
        if($selected.rows.Count-ne2-or@($selected.rows|Where-Object mode -cne $expectedMode).Count){throw 'Hosted reader did not retain the real self-contained producer disposition.'}
        if($attempt-eq3){
            foreach($damage in @('attempt','job','source','raw','binding','runner','pointer','summary','extra-job')){
                $inventoryPath=Join-Path $inventoryRoot 'inventory.json';$inventoryBytes=[IO.File]::ReadAllBytes($inventoryPath);$damagedJobs=$jobs;$restorePath='';$restoreBytes=$null
                try{
                    if($damage-ceq'extra-job'){$damagedJobs=@($jobs)+[pscustomobject]@{name='foreign';status='completed';conclusion='success'}}
                    elseif($damage-cin@('attempt','job','source')){
                        $inv=[Text.Encoding]::UTF8.GetString($inventoryBytes)|ConvertFrom-Json -Depth 100
                        switch($damage){attempt{$inv.producer.run_attempt=2}job{$inv.producer.job='foreign'}source{$inv.source.head.commit=('c'*40)}}
                        [IO.File]::WriteAllText($inventoryPath,($inv|ConvertTo-Json -Depth 100 -Compress),[Text.UTF8Encoding]::new($false))
                    }elseif($damage-ceq'summary'){
                        $restorePath=Join-Path $aggregateDir $aggregateFile;$restoreBytes=[IO.File]::ReadAllBytes($restorePath);$changed=Read-MorphospaceProtocolJson $restorePath;$changed.check_results[0].stdout_sha256=('0'*64);[IO.File]::WriteAllText($restorePath,($changed|ConvertTo-Json -Depth 100 -Compress),[Text.UTF8Encoding]::new($false))
                    }else{
                        $inv=Read-MorphospaceProtocolJson $inventoryPath;$receiptPath=Join-Path $inventoryRoot $inv.entries[0].receipt.path;$receipt=Read-MorphospaceProtocolJson $receiptPath
                        $restorePath=if($damage-ceq'raw'){Join-Path $inventoryRoot $inv.entries[0].stdout.path}else{$receiptPath};$restoreBytes=[IO.File]::ReadAllBytes($restorePath)
                        if($damage-ceq'raw'){[IO.File]::AppendAllText($restorePath,'damage')}else{
                            switch($damage){binding{$receipt.binding.command_blob_sha1=('0'*40)}runner{$receipt.binding.runner.os_description='foreign'}pointer{$receipt.reused_from.source_head.commit=('c'*40)}}
                            [IO.File]::WriteAllText($restorePath,($receipt|ConvertTo-Json -Depth 100 -Compress),[Text.UTF8Encoding]::new($false))
                            # Refresh the raw wrapper so semantic damage reaches the
                            # actual binding/pointer predicates, not just a stale hash.
                            $inv.entries[0].receipt.bytes=[long]([IO.FileInfo]$restorePath).Length;$inv.entries[0].receipt.sha256=Get-ReuseSelfHash $restorePath
                            [IO.File]::WriteAllText($inventoryPath,($inv|ConvertTo-Json -Depth 100 -Compress),[Text.UTF8Encoding]::new($false))
                        }
                    }
                    $refused=$false;try{[void](Get-ReuseHostedSelectedRows -Context $context -Plan $plan -Artifacts $artifacts -Jobs $damagedJobs)}catch{$refused=$true};if(-not$refused){throw "Hosted real producer control accepted $damage drift."}
                }finally{[IO.File]::WriteAllBytes($inventoryPath,$inventoryBytes);if($restorePath){[IO.File]::WriteAllBytes($restorePath,$restoreBytes)}}
            }
        }
        $prior=$inventoryRoot
    }
    Write-Host 'Candidate-hosted real producer controls passed (executed -> reused -> reused; provider modeled; no historical genesis or hosted execution claim).'
}

if ($SelfTest) {
    $source = Get-Content -LiteralPath $PSCommandPath -Raw
    foreach ($partition in @(
        [pscustomobject]@{phase='plan-base-admission';variable='$runPlanBaseAdmission'},
        [pscustomobject]@{phase='evidence-binding';variable='$runEvidenceBinding'},
        [pscustomobject]@{phase='run-job-coverage';variable='$runRunJobCoverage'}
    )) {
        if (-not $source.Contains("[ValidateSet('plan-base-admission','evidence-binding','run-job-coverage')]") -or -not $source.Contains([string]$partition.variable)) {
            throw "Affected-validation reuse compatibility self-test is missing its exact '$([string]$partition.phase)' partition."
        }
    }
    Write-Host 'Affected-validation reuse compatibility self-test passed.'
    return
}

if (-not [string]::IsNullOrWhiteSpace($SelfTestPhase)) {
    $runPlanBaseAdmission = $SelfTestPhase -ceq 'plan-base-admission'
    $runEvidenceBinding = $SelfTestPhase -ceq 'evidence-binding'
    $runRunJobCoverage = $SelfTestPhase -ceq 'run-job-coverage'
    $sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationArtifactTransport.psm1') -Force
    function Invoke-ReuseSelfGit([string]$Root, [string[]]$Arguments) { $value = & git -C $Root @Arguments 2>&1; if ($LASTEXITCODE -ne 0) { throw "Reuse self-test git failure: $($value -join "`n")" }; return ($value -join "`n").Trim() }
    function Write-ReuseSelfUtf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
    function Get-ReuseSelfHash([string]$Path) { ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path)))).ToLowerInvariant() }
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-reuse-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fixture)
    try {
        [void](Invoke-ReuseSelfGit $fixture @('init', '--initial-branch=main')); [void](Invoke-ReuseSelfGit $fixture @('config', 'user.name', 'Affected Reuse Test')); [void](Invoke-ReuseSelfGit $fixture @('config', 'user.email', 'affected-reuse@example.invalid'))
        foreach ($relative in @('manifests/affected-validation-registry.json','schemas/affected-validation-registry-v1.schema.json','schemas/affected-validation-plan-v1.schema.json','schemas/affected-validation-plan-v2.schema.json','schemas/affected-validation-evidence-v1.schema.json','.github/workflows/validate.yml','scripts/lib/MorphospaceProtocolCommon.psm1','scripts/lib/MorphospaceAffectedValidation.psm1')) { $destination = Join-Path $fixture ($relative -replace '/', [IO.Path]::DirectorySeparatorChar); [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)); Copy-Item -LiteralPath (Join-Path $sourceRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)) -Destination $destination }
        $registry = Read-MorphospaceProtocolJson -Path (Join-Path $sourceRoot 'manifests/affected-validation-registry.json')
        $fixtureScripts = @(
            @($registry.checks | ForEach-Object { [string]$_.command_path }) +
            @($registry.dependency_declarations | ForEach-Object { [string]$_.importer }) +
            @($registry.dependency_declarations | ForEach-Object { if ($_.PSObject.Properties.Name -ccontains 'target_paths') { @($_.target_paths) | ForEach-Object { [string]$_ } } }) |
                Sort-Object -Unique
        )
        foreach ($command in $fixtureScripts) { $destination = Join-Path $fixture ($command -replace '/', [IO.Path]::DirectorySeparatorChar); [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)); Copy-Item -LiteralPath (Join-Path $sourceRoot ($command -replace '/', [IO.Path]::DirectorySeparatorChar)) -Destination $destination }
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'docs')); Write-ReuseSelfUtf8 (Join-Path $fixture 'docs/base.md') "base`n"; [void](Invoke-ReuseSelfGit $fixture @('add','.')); [void](Invoke-ReuseSelfGit $fixture @('commit','-m','seed')); $alternateBase = Invoke-ReuseSelfGit $fixture @('rev-parse','HEAD')
        Write-ReuseSelfUtf8 (Join-Path $fixture 'docs/observed-base.md') "observed base`n"; [void](Invoke-ReuseSelfGit $fixture @('add','docs/observed-base.md')); [void](Invoke-ReuseSelfGit $fixture @('commit','-m','observed base')); $base = Invoke-ReuseSelfGit $fixture @('rev-parse','HEAD')
        [void](Invoke-ReuseSelfGit $fixture @('checkout','-b','candidate')); Write-ReuseSelfUtf8 (Join-Path $fixture 'docs/reuse.md') "candidate`n"; [void](Invoke-ReuseSelfGit $fixture @('add','docs/reuse.md')); [void](Invoke-ReuseSelfGit $fixture @('commit','-m','candidate')); $candidate = Invoke-ReuseSelfGit $fixture @('rev-parse','HEAD')
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $base -HeadRevision $candidate -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        $alternatePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $alternateBase -HeadRevision $candidate -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        $artifacts = Join-Path $fixture 'artifacts'; [void][IO.Directory]::CreateDirectory($artifacts); $planPath = Join-Path $artifacts 'affected-plan.json'; Write-ReuseSelfUtf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $plan) + "`n")
        $checkMap = @{}; foreach ($check in @($registry.checks)) { $checkMap[[string]$check.check_id] = $check }
        $results = [Collections.Generic.List[object]]::new(); $coverage = [Collections.Generic.List[object]]::new()
        foreach ($selected in @($plan.selected_checks | Where-Object { @($_.platforms) -ccontains 'linux' })) { $check = $checkMap[[string]$selected.check_id]; $blob = Invoke-ReuseSelfGit $fixture @('rev-parse', "${candidate}:$($check.command_path)"); $results.Add([pscustomobject][ordered]@{check_id=[string]$check.check_id;command_path=[string]$check.command_path;command_blob_sha1=$blob;mode='executed';result='pass';started=$true;failure_kind=$null;exit_code=0;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout_sha256=('0'*64);stderr_sha256=('0'*64);stdout_bytes=0;stderr_bytes=0}); $coverage.Add([pscustomobject][ordered]@{platform='linux';check_id=[string]$check.check_id;command_path=[string]$check.command_path;command_blob_sha1=$blob}) }
        if ($results.Count -eq 0) { throw 'Reuse self-test expected a Linux candidate selection.' }
        $candidateIdentity = [pscustomobject][ordered]@{commit=$candidate;tree=(Invoke-ReuseSelfGit $fixture @('rev-parse',"$candidate^{tree}"))}; $baseIdentity = [pscustomobject][ordered]@{commit=$base;tree=(Invoke-ReuseSelfGit $fixture @('rev-parse',"$base^{tree}"))}
        $evidence = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_evidence.v1';repository=[string]$plan.repository;base=$baseIdentity;head=$candidateIdentity;plan_sha256=[string]$plan.plan_sha256;platform='linux';runner=[pscustomobject][ordered]@{os_description='synthetic';powershell_version='7.6.0'};check_results=@($results.ToArray());result='pass';claims=[pscustomobject][ordered]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}
        $evidencePath = Join-Path $artifacts 'affected-linux-evidence.json'; Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $evidence) + "`n")
        [void](Invoke-ReuseSelfGit $fixture @('checkout','main')); [void](Invoke-ReuseSelfGit $fixture @('merge','--no-ff','candidate','-m','merge candidate')); $merge = Invoke-ReuseSelfGit $fixture @('rev-parse','HEAD')
        $expiry = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $planHash = Get-ReuseSelfHash $planPath; $evidenceHash = Get-ReuseSelfHash $evidencePath
        $runId = 101; $runAttempt = 3; $planAttempt = 1; $evidenceAttempt = 2
        $planRemoteName = "affected-plan-$($plan.plan_sha256)-$runId-$planAttempt"
        $evidenceRemoteName = "affected-linux-$evidenceHash-$runId-$evidenceAttempt"
        $receipt = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_reuse.v1';repository=[string]$plan.repository;event=[pscustomobject][ordered]@{name='pull_request';head_sha=$candidate;base_sha=$base};pull_request=[pscustomobject][ordered]@{number=1;head_sha=$candidate;base_sha=$base};run=[pscustomobject][ordered]@{id=$runId;attempt=$runAttempt;event='pull_request';head_sha=$candidate;workflow_id=1;check_names=@('infrastructure','quick-linux','quick-windows','select','standard-windows')};base=$baseIdentity;head=$candidateIdentity;tree=$candidateIdentity.tree;workflow=[pscustomobject][ordered]@{id=1;path='.github/workflows/validate.yml';blob_sha1=(Invoke-ReuseSelfGit $fixture @('rev-parse',"${candidate}:.github/workflows/validate.yml"))};plan=[pscustomobject][ordered]@{artifact_name=$planRemoteName;file_sha256=$planHash;canonical_sha256=[string]$plan.plan_sha256};artifacts=@([pscustomobject][ordered]@{id=1;remote_name=$planRemoteName;name='affected-plan.json';platform='plan';sha256=$planHash;size=[long](Get-Item -LiteralPath $planPath).Length;expires_utc=$expiry},[pscustomobject][ordered]@{id=2;remote_name=$evidenceRemoteName;name='affected-linux-evidence.json';platform='linux';sha256=$evidenceHash;size=[long](Get-Item -LiteralPath $evidencePath).Length;expires_utc=$expiry});coverage=@($coverage.ToArray());freshness=[pscustomobject][ordered]@{created_utc=[DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture);max_age_minutes=60};claims=[pscustomobject][ordered]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}
        $receiptPath = Join-Path $artifacts 'reuse.json'; Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts)
        if ($runPlanBaseAdmission) {
        function Assert-ReuseSelfPlanRejected([object]$RejectedPlan,[string]$Expected,[string]$Context) {
            Write-ReuseSelfUtf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $RejectedPlan)+"`n")
            $damagedReceipt=$receipt|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64;$artifact=@($damagedReceipt.artifacts|Where-Object name -ceq 'affected-plan.json')[0]
            $artifact.sha256=Get-ReuseSelfHash $planPath;$artifact.size=[long](Get-Item -LiteralPath $planPath).Length;$artifact.remote_name="affected-plan-$([string]$RejectedPlan.plan_sha256)-$runId-$planAttempt";$damagedReceipt.plan.file_sha256=$artifact.sha256;$damagedReceipt.plan.canonical_sha256=[string]$RejectedPlan.plan_sha256;$damagedReceipt.plan.artifact_name=$artifact.remote_name
            Write-ReuseSelfUtf8 $receiptPath (($damagedReceipt|ConvertTo-Json -Depth 64 -Compress)+"`n")
            $failure=$null;try{[void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts)}catch{$failure=$_.Exception.Message}
            if($failure-notlike$Expected){throw "Reuse self-test did not reject $Context before materialization: $failure"}
        }
        $historicalPlan=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_plan.v1';repository=$plan.repository;base=$plan.base;head=$plan.head;registry=[pscustomobject][ordered]@{schema=$plan.head_registry.schema;registry_id=$plan.head_registry.registry_id;revision=$plan.head_registry.revision;sha256=$plan.head_registry.sha256};changed_paths=$plan.changed_paths;changed_paths_sha256=$plan.changed_paths_sha256;requested_tier=$plan.requested_tier;effective_tier=$plan.effective_tier;selection_mode=$plan.selection_mode;reason_codes=$plan.reason_codes;selected_checks=$plan.selected_checks;skipped_checks=$plan.skipped_checks;estimated_budget_seconds=$plan.budget.actual;plan_sha256=('1'*64);claims=$plan.claims}
        Assert-ReuseSelfPlanRejected $historicalPlan '*historical-only*' 'historical v1 plan'
        $mappingPlan=$plan|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64;$mappingPlan.selection_mode='mapping-incomplete';$mappingPlan.execution_permitted=$false;$mappingPlan.selected_checks=@();$mappingPlan.mapping_diagnostics=@([pscustomobject][ordered]@{path='unknown.bin';side='new';issue_kind='unmapped';matching_path_set_ids=@()});$mappingPlan.reason_codes=@('unmapped-path');$mappingPlan.budget.actual=0;$mappingPlan.plan_sha256=('2'*64)
        Assert-ReuseSelfPlanRejected $mappingPlan '*non-executable mapping-incomplete*' 'mapping-incomplete plan'
        Write-ReuseSelfUtf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $plan)+"`n");Write-ReuseSelfUtf8 $receiptPath (($receipt|ConvertTo-Json -Depth 64 -Compress)+"`n")
        $alternateCheckIds = (@($alternatePlan.selected_checks.check_id) -join ','); $observedCheckIds = (@($plan.selected_checks.check_id) -join ',')
        if ($alternateCheckIds -cne $observedCheckIds) { throw 'Reuse self-test alternate base unexpectedly changes the selected checks.' }
        $alternateBaseIdentity = [pscustomobject][ordered]@{commit=$alternateBase;tree=(Invoke-ReuseSelfGit $fixture @('rev-parse',"$alternateBase^{tree}"))}
        $alternateEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $alternateEvidence.base = $alternateBaseIdentity; $alternateEvidence.plan_sha256 = [string]$alternatePlan.plan_sha256
        Write-ReuseSelfUtf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $alternatePlan) + "`n"); Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $alternateEvidence) + "`n")
        $alternateReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $alternateReceipt.base = $alternateBaseIdentity; $alternateReceipt.event.base_sha = $alternateBase; $alternateReceipt.pull_request.base_sha = $alternateBase; $alternateReceipt.plan.canonical_sha256 = [string]$alternatePlan.plan_sha256
        $alternatePlanArtifact = @($alternateReceipt.artifacts | Where-Object { $_.name -ceq 'affected-plan.json' })[0]; $alternatePlanArtifact.sha256 = Get-ReuseSelfHash $planPath; $alternatePlanArtifact.size = [long](Get-Item -LiteralPath $planPath).Length; $alternatePlanArtifact.remote_name = "affected-plan-$($alternatePlan.plan_sha256)-$runId-$planAttempt"; $alternateReceipt.plan.file_sha256 = $alternatePlanArtifact.sha256; $alternateReceipt.plan.artifact_name = $alternatePlanArtifact.remote_name
        $alternateEvidenceArtifact = @($alternateReceipt.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $alternateEvidenceArtifact.sha256 = Get-ReuseSelfHash $evidencePath; $alternateEvidenceArtifact.size = [long](Get-Item -LiteralPath $evidencePath).Length; $alternateEvidenceArtifact.remote_name = "affected-linux-$($alternateEvidenceArtifact.sha256)-$runId-$evidenceAttempt"
        Write-ReuseSelfUtf8 $receiptPath (($alternateReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $alternateBaseError = $null; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $alternateBaseError = $_.Exception.Message }
        if ($alternateBaseError -notlike '*observed before*') { throw 'Reuse self-test did not reject the coherent alternate base through the observed-base comparison.' }
        Write-ReuseSelfUtf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $plan) + "`n"); Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $evidence) + "`n"); Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        }
        if ($runEvidenceBinding) {
        function Assert-ReuseSelfEvidenceBindingRejected([string]$Name, [string[]]$Expected, [scriptblock]$Mutate) {
            $damagedEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            & $Mutate $damagedEvidence
            Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $damagedEvidence) + "`n")
            $damagedReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            $artifact = @($damagedReceipt.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]
            $artifact.sha256 = Get-ReuseSelfHash $evidencePath; $artifact.size = [long](Get-Item -LiteralPath $evidencePath).Length; $artifact.remote_name = "affected-linux-$($artifact.sha256)-$runId-$evidenceAttempt"
            Write-ReuseSelfUtf8 $receiptPath (($damagedReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            $reason = $null; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $reason = $_.Exception.Message }
            Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $evidence) + "`n"); Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            if (@($Expected | Where-Object { $reason -like $_ }).Count -eq 0) { throw "Reuse self-test did not reject $Name through its intended evidence-binding reason: $reason" }
        }
        $bindingReason = "*Reuse 'linux' evidence does not bind its exact plan, platform, trees, and artifact.*"
        Assert-ReuseSelfEvidenceBindingRejected -Name 'repository' -Expected $bindingReason -Mutate { param($value) $value.repository = 'example.invalid/other' }
        Assert-ReuseSelfEvidenceBindingRejected -Name 'platform' -Expected $bindingReason -Mutate { param($value) $value.platform = 'windows' }
        Assert-ReuseSelfEvidenceBindingRejected -Name 'base tree' -Expected $bindingReason -Mutate { param($value) $value.base.tree = ('0' * 40) }
        Assert-ReuseSelfEvidenceBindingRejected -Name 'head tree' -Expected $bindingReason -Mutate { param($value) $value.head.tree = ('1' * 40) }
        Assert-ReuseSelfEvidenceBindingRejected -Name 'typed failure inconsistency' -Expected @("*JSON is not valid with the schema:*at '/result'*","Reuse 'linux' evidence fails its closed schema.") -Mutate { param($value) $value.check_results[0].failure_kind = 'exit-code' }
        Assert-ReuseSelfEvidenceBindingRejected -Name 'combined stream ceiling' -Expected "*Reuse 'linux' result exceeds the combined stream bound.*" -Mutate { param($value) $value.check_results[0].stdout_bytes = 6291456; $value.check_results[0].stderr_bytes = 5242880 }
        function Assert-ReuseSelfArtifactNameRejected([string]$Name, [scriptblock]$Mutate) {
            $damagedReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            & $Mutate $damagedReceipt
            Write-ReuseSelfUtf8 $receiptPath (($damagedReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            $rejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $rejected = $true }
            Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            if (-not $rejected) { throw "Reuse self-test accepted $Name." }
        }
        Assert-ReuseSelfArtifactNameRejected -Name 'a legacy plan artifact name' -Mutate { param($value) $legacy = "affected-plan-$($value.plan.canonical_sha256)"; $value.plan.artifact_name = $legacy; @($value.artifacts | Where-Object { $_.name -ceq 'affected-plan.json' })[0].remote_name = $legacy }
        Assert-ReuseSelfArtifactNameRejected -Name 'a plan artifact from another run' -Mutate { param($value) $name = "affected-plan-$($value.plan.canonical_sha256)-$([long]$value.run.id + 1)-1"; $value.plan.artifact_name = $name; @($value.artifacts | Where-Object { $_.name -ceq 'affected-plan.json' })[0].remote_name = $name }
        Assert-ReuseSelfArtifactNameRejected -Name 'a plan artifact from a future attempt' -Mutate { param($value) $name = "affected-plan-$($value.plan.canonical_sha256)-$($value.run.id)-$([long]$value.run.attempt + 1)"; $value.plan.artifact_name = $name; @($value.artifacts | Where-Object { $_.name -ceq 'affected-plan.json' })[0].remote_name = $name }
        Assert-ReuseSelfArtifactNameRejected -Name 'a legacy evidence artifact name' -Mutate { param($value) $item = @($value.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $item.remote_name = "affected-linux-$($item.sha256)" }
        Assert-ReuseSelfArtifactNameRejected -Name 'an evidence artifact from another run' -Mutate { param($value) $item = @($value.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $item.remote_name = "affected-linux-$($item.sha256)-$([long]$value.run.id + 1)-2" }
        Assert-ReuseSelfArtifactNameRejected -Name 'an evidence artifact from a future attempt' -Mutate { param($value) $item = @($value.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $item.remote_name = "affected-linux-$($item.sha256)-$($value.run.id)-$([long]$value.run.attempt + 1)" }
        Assert-ReuseSelfArtifactNameRejected -Name 'an evidence artifact with attempt zero' -Mutate { param($value) $item = @($value.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $item.remote_name = "affected-linux-$($item.sha256)-$($value.run.id)-0" }
        Assert-ReuseSelfArtifactNameRejected -Name 'an evidence artifact with a malformed attempt' -Mutate { param($value) $item = @($value.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $item.remote_name = "affected-linux-$($item.sha256)-$($value.run.id)-two" }
        Assert-ReuseSelfArtifactNameRejected -Name 'an evidence artifact with the wrong digest' -Mutate { param($value) $item = @($value.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $item.remote_name = "affected-linux-$('f' * 64)-$($value.run.id)-2" }
        Assert-ReuseSelfArtifactNameRejected -Name 'an evidence artifact with the wrong kind' -Mutate { param($value) $item = @($value.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $item.remote_name = "affected-windows-$($item.sha256)-$($value.run.id)-2" }
        $baseTreeReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $baseTreeReceipt.base.tree = ('0' * 40); Write-ReuseSelfUtf8 $receiptPath (($baseTreeReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $baseTreeRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $baseTreeRejected = $true }; if (-not $baseTreeRejected) { throw 'Reuse self-test accepted receipt base-tree drift.' }
        Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        }
        if ($runRunJobCoverage) {
        Invoke-ReuseHostedProviderControls -Fixture $fixture
        Invoke-ReuseHostedProducerControls -Fixture $fixture -SourceRoot $sourceRoot
        $currentWorkflow=[IO.File]::ReadAllText((Join-Path $sourceRoot '.github/workflows/validate.yml'))
        if((Get-ReuseCandidateLinuxExecutionMode $currentWorkflow)-cne'linux-direct'){throw 'Reuse fixture did not exercise actual Linux-direct candidate source.'}
        $legacyWorkflow="jobs:`n  affected-linux-segments:`n    runs-on: ubuntu-latest`n  quick-linux:`n    needs: [infrastructure, select, affected-linux-segments]`n"
        if((Get-ReuseCandidateLinuxExecutionMode $legacyWorkflow)-cne'segmented'){throw 'Reuse topology lost historical segmented candidate dispatch.'}
        $directCommand='& ./scripts/Invoke-AffectedValidation.ps1 -RepositoryRoot . -BaseCommit $base -HeadCommit $head -PlanPath "$env:RUNNER_TEMP/affected-plan.json" -Platform linux -OutPath $evidencePath -CheckEvidenceDirectory $currentRoot -PriorEvidenceDirectory $priorRoot'
        $sourceDamages=[ordered]@{
            missing=$currentWorkflow.Replace('  quick-linux:','  removed-linux:')
            duplicate=$currentWorkflow+"`n  quick-linux:`n    needs: [infrastructure, select]`n"
            foreign=$currentWorkflow.Replace('./scripts/Invoke-AffectedValidation.ps1','./foreign/Invoke-AffectedValidation.ps1')
            partial=$currentWorkflow.Replace('-Platform linux -OutPath','-Platform linux -SegmentId linux-001 -OutPath')
            wrongPlatform=$currentWorkflow.Replace('-Platform linux -OutPath','-Platform windows -OutPath')
            ambiguous=$currentWorkflow+"`n  affected-linux-segments:`n    runs-on: ubuntu-latest`n"
            ambiguousRenamedStep=$currentWorkflow.Replace('Execute exact selected Linux union on this runner','Renamed direct step')+"`n  affected-linux-segments:`n    runs-on: ubuntu-latest`n"
            bypass=$currentWorkflow.Replace("`$env:SELECT_RESULT -cne 'success'","`$env:SELECT_RESULT -ceq 'success'")
            commented=$currentWorkflow.Replace($directCommand,('# '+$directCommand+"`n          `$execution = `$null"))
            extraCall=$currentWorkflow.Replace($directCommand,($directCommand+"`n          "+$directCommand))
        }
        foreach($extraJob in @('quick-linux','main-linux-delta')) {
            $jobPattern='(?ms)(^  '+[regex]::Escape($extraJob)+':\r?\n)(?<body>.*?)(?=^  [a-z0-9-]+:|\z)'
            $jobMatch=[regex]::Match($currentWorkflow,$jobPattern)
            $extraStep="      - name: Undeclared second Linux producer`n        shell: pwsh`n        run: |`n          "+$directCommand+"`n"
            $insertAt=$jobMatch.Groups['body'].Index+$jobMatch.Groups['body'].Length
            $sourceDamages['extraStep-'+$extraJob]=$currentWorkflow.Insert($insertAt,$extraStep)
            $sourceDamages['extraInline-'+$extraJob]=$currentWorkflow.Insert($insertAt,('      - name: Undeclared inline Linux producer'+"`n        shell: pwsh`n        run: "+$directCommand+"`n"))
        }
        foreach($name in $sourceDamages.Keys){$refused=$false;try{[void](Get-ReuseCandidateLinuxExecutionMode ([string]$sourceDamages[$name]))}catch{$refused=$true};if(-not$refused){throw "Reuse Linux-direct source policy accepted '$name' damage."}}
        function Assert-ReuseSelfRunChecksRejected([string]$Name, [string[]]$CheckNames) {
            $damagedReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            $damagedReceipt.run.check_names = @($CheckNames)
            Write-ReuseSelfUtf8 $receiptPath (($damagedReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            $reason = $null; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $reason = $_.Exception.Message }
            Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            if ($reason -notlike '*run check identities differs from the exact expected set*') { throw "Reuse self-test did not reject $Name through the exact run check identity contract." }
        }
        Assert-ReuseSelfRunChecksRejected -Name 'artifact aliases as job identities' -CheckNames @('affected-linux','infrastructure','quick-windows','segment-linux-001','select','standard-windows')
        Assert-ReuseSelfRunChecksRejected -Name 'an extra successful job identity' -CheckNames @('infrastructure','quick-linux','quick-windows','segment-linux-001','select','standard-windows','unexpected-success')
        Assert-ReuseSelfRunChecksRejected -Name 'missing required Linux result' -CheckNames @('infrastructure','quick-windows','select','standard-windows')
        Assert-ReuseSelfRunChecksRejected -Name 'misnamed required Linux result' -CheckNames @('infrastructure','quick-linux-renamed','quick-windows','select','standard-windows')
        Assert-ReuseSelfRunChecksRejected -Name 'direct plus segmented success ambiguity' -CheckNames @('infrastructure','quick-linux','quick-windows','segment-linux-001','select','standard-windows')
        $duplicateReceipt=$receipt|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64
        $duplicateReceipt.run.check_names=@('infrastructure','quick-linux','quick-linux','quick-windows','select','standard-windows')
        Write-ReuseSelfUtf8 $receiptPath (($duplicateReceipt|ConvertTo-Json -Depth 64 -Compress)+"`n")
        $duplicateRefused=$false;try{[void](& (Join-Path $PSScriptRoot 'Test-AffectedValidationReuse.ps1') -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts)}catch{$duplicateRefused=$true}
        Write-ReuseSelfUtf8 $receiptPath (($receipt|ConvertTo-Json -Depth 64 -Compress)+"`n")
        if(-not$duplicateRefused){throw 'Reuse accepted duplicate actual successful job identities.'}
        $damaged = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $damaged.coverage = @(); Write-ReuseSelfUtf8 $receiptPath (($damaged | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $coverageRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $coverageRejected = $true }; if (-not $coverageRejected) { throw 'Reuse self-test accepted absent selected coverage.' }
        $stale = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $stale.freshness.created_utc = [DateTimeOffset]::UtcNow.AddMinutes(-61).ToString('o',[Globalization.CultureInfo]::InvariantCulture); Write-ReuseSelfUtf8 $receiptPath (($stale | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $staleRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $staleRejected = $true }; if (-not $staleRejected) { throw 'Reuse self-test accepted stale evidence.' }
        $impossibleEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $impossibleEvidence.check_results[0].exit_code = 1; Write-ReuseSelfUtf8 $evidencePath (($impossibleEvidence | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $impossibleHash = Get-ReuseSelfHash $evidencePath; $impossibleReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $impossibleArtifact = @($impossibleReceipt.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $impossibleArtifact.sha256 = $impossibleHash; $impossibleArtifact.size = [long](Get-Item -LiteralPath $evidencePath).Length; $impossibleArtifact.remote_name = "affected-linux-$impossibleHash-$runId-$evidenceAttempt"; Write-ReuseSelfUtf8 $receiptPath (($impossibleReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $impossibleRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $impossibleRejected = $true }; if (-not $impossibleRejected) { throw 'Reuse self-test accepted pass evidence with a nonzero exit.' }
        Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $evidence) + "`n"); Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n"); Write-ReuseSelfUtf8 $planPath "tampered`n"
        $artifactRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $artifactRejected = $true }; if (-not $artifactRejected) { throw 'Reuse self-test accepted tampered artifact bytes.' }
        }
        Write-Host "Affected-validation reuse self-test phase '$SelfTestPhase' passed."
    } finally { if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
    return
}

if ($CandidateHosted) {
    $hostedResult=Invoke-ReuseHostedIntake -RepositoryRoot $RepositoryRoot -BeforeCommit $BeforeCommit -HeadCommit $HeadCommit -Repository $Repository -PullRequestNumber $PullRequestNumber -RunId $RunId -GhPath $GhPath -OutputDirectory $OutputDirectory
    $hostedResult|ConvertTo-Json -Depth 100 -Compress
    return
}

$root = [IO.Path]::GetFullPath($RepositoryRoot)
$artifacts = [IO.Path]::GetFullPath($ArtifactDirectory)
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationArtifactTransport.psm1') -Force

function Invoke-ReuseGit([string[]]$Arguments) {
    $value = & git -C $root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Reuse git failed: $($Arguments -join ' ')`n$($value -join "`n")" }
    return ($value -join "`n").Trim()
}
function Get-ReuseIdentity([string]$Revision) {
    return [pscustomobject][ordered]@{
        commit = Invoke-ReuseGit @('rev-parse', "$Revision^{commit}")
        tree = Invoke-ReuseGit @('rev-parse', "$Revision^{tree}")
    }
}
function Get-ReuseFileHash([string]$Path) {
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path)))).ToLowerInvariant()
}
function Get-ReuseUtc([string]$Value, [string]$Name) {
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { throw "Reuse $Name is not an RFC3339 timestamp." }
    return $parsed.ToUniversalTime()
}
function Assert-ReuseExactSet([string[]]$Actual, [string[]]$Expected, [string]$Name) {
    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in @($Actual)) { if (-not $actualSet.Add([string]$value)) { throw "Reuse $Name repeats '$value'." } }
    $expectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in @($Expected)) { [void]$expectedSet.Add([string]$value) }
    if (-not $actualSet.SetEquals($expectedSet)) { throw "Reuse $Name differs from the exact expected set." }
}
function Assert-ReusePassingCheck([object]$Result, [string]$Platform) {
    if ([string]$Result.result -cne 'pass' -or $null -eq $Result.exit_code -or [int]$Result.exit_code -ne 0 -or [bool]$Result.timed_out -or [bool]$Result.output_truncated -or [bool]$Result.post_kill_drain_timed_out) {
        throw "Reuse '$Platform' result is not a complete passing check."
    }
}

$reuseRaw = Get-Content -LiteralPath $ReusePath -Raw
$reuseSchema = Join-Path $PSScriptRoot '..\schemas\affected-validation-reuse-v1.schema.json'
if (-not (Test-Json -Json $reuseRaw -SchemaFile $reuseSchema -ErrorAction Stop)) { throw 'Reuse receipt fails its closed schema.' }
$reuse = $reuseRaw | ConvertFrom-Json -Depth 64
$before = Get-ReuseIdentity $BeforeCommit
$merge = Get-ReuseIdentity $HeadCommit
if ((Get-ReuseIdentity 'HEAD').commit -cne $merge.commit) { throw 'Reuse requires checkout HEAD to equal merge head.' }
$parents = @((Invoke-ReuseGit @('show', '-s', '--format=%P', $merge.commit)) -split '\s+' | Where-Object { $_ })
if ($parents.Count -ne 2) { throw 'Reuse requires an ordered two-parent merge.' }
$first = Get-ReuseIdentity $parents[0]
$candidate = Get-ReuseIdentity $parents[1]
if ($before.commit -cne $first.commit) { throw 'Reuse before does not equal merge first parent.' }
if ($reuse.base.commit -cne $before.commit -or $reuse.base.tree -cne $before.tree) { throw 'Reuse receipt base does not equal the observed before commit and tree.' }
if ($candidate.commit -cne $reuse.head.commit -or $candidate.tree -cne $reuse.head.tree -or $merge.tree -cne $candidate.tree -or $reuse.tree -cne $candidate.tree) { throw 'Reuse does not bind the exact PR candidate tree.' }
if ($reuse.event.head_sha -cne $candidate.commit -or $reuse.pull_request.head_sha -cne $candidate.commit -or $reuse.run.head_sha -cne $candidate.commit) { throw 'Reuse receipt does not bind the PR event head SHA.' }
if ($reuse.event.base_sha -cne $reuse.base.commit -or $reuse.pull_request.base_sha -cne $reuse.base.commit) { throw 'Reuse receipt does not bind its exact PR base SHA.' }
if ([long]$reuse.workflow.id -ne [long]$reuse.run.workflow_id) { throw 'Reuse workflow identity does not match the authenticated run.' }
& git -C $root merge-base --is-ancestor $reuse.base.commit $candidate.commit
if ($LASTEXITCODE -ne 0) { throw 'Reuse base is not an ancestor of candidate.' }
$created = Get-ReuseUtc -Value ([string]$reuse.freshness.created_utc) -Name 'created_utc'
$age = ([DateTimeOffset]::UtcNow - $created).TotalMinutes
if ($age -lt 0 -or $age -gt [double]$reuse.freshness.max_age_minutes) { throw 'Reuse receipt is stale or future-dated.' }

$artifactByName = @{}
$artifactIdentityByName = @{}
$artifactIds = [Collections.Generic.HashSet[long]]::new()
foreach ($artifact in @($reuse.artifacts)) {
    $name = [string]$artifact.name
    if ($artifactByName.ContainsKey($name) -or -not $artifactIds.Add([long]$artifact.id)) { throw 'Reuse receipt repeats an artifact identity.' }
    $artifactIdentity = ConvertFrom-MorphospaceAffectedArtifactName -Name ([string]$artifact.remote_name) -RunId ([string]$reuse.run.id) -CurrentAttempt ([long]$reuse.run.attempt)
    if ([string]$artifactIdentity.file_name -cne $name -or [string]$artifactIdentity.kind -cne [string]$artifact.platform -or [string]$artifactIdentity.logical_id -cne [string]$artifact.platform) { throw "Reuse artifact '$name' remote identity has the wrong kind, logical identity, or payload file name." }
    if ($name -ceq 'affected-plan.json') {
        if ([string]$artifactIdentity.digest -cne [string]$reuse.plan.canonical_sha256) { throw 'Reuse plan artifact remote identity has the wrong canonical digest.' }
    } elseif ([string]$artifactIdentity.digest -cne [string]$artifact.sha256) { throw "Reuse artifact '$name' remote identity has the wrong file digest." }
    $path = Join-Path $artifacts $name
    if (-not [IO.File]::Exists($path)) { throw "Reuse artifact is absent: $name" }
    if ((Get-ReuseFileHash $path) -cne [string]$artifact.sha256 -or (Get-Item -LiteralPath $path).Length -ne [long]$artifact.size) { throw "Reuse artifact bytes drifted: $name" }
    if ((Get-ReuseUtc -Value ([string]$artifact.expires_utc) -Name "artifact '$name' expiry") -le [DateTimeOffset]::UtcNow) { throw "Reuse artifact '$name' is expired." }
    $artifactByName[$name] = $artifact
    $artifactIdentityByName[$name] = $artifactIdentity
}
if (-not $artifactByName.ContainsKey('affected-plan.json')) { throw 'Reuse receipt lacks the plan artifact.' }
$planArtifact = $artifactByName['affected-plan.json']
if ($planArtifact.platform -cne 'plan' -or $planArtifact.remote_name -cne $reuse.plan.artifact_name -or $reuse.plan.file_sha256 -cne $planArtifact.sha256) { throw 'Reuse plan artifact binding differs from its receipt.' }
$planPath = Join-Path $artifacts 'affected-plan.json'
$planRaw = Get-Content -LiteralPath $planPath -Raw
$planProbe = $planRaw | ConvertFrom-Json -Depth 64 -ErrorAction Stop
if ([string]$planProbe.schema -ceq 'rusty.morphospace.workflow.affected_validation_plan.v1') { throw 'Affected-validation plan v1 is historical-only and cannot be reused.' }
$planSchema = Join-Path $PSScriptRoot '..\schemas\affected-validation-plan-v2.schema.json'
if (-not (Test-Json -Json $planRaw -SchemaFile $planSchema -ErrorAction Stop)) { throw 'Reuse plan fails its closed schema.' }
$plan = $planRaw | ConvertFrom-Json -Depth 64
if (-not [bool]$plan.execution_permitted -or [string]$plan.selection_mode -ceq 'mapping-incomplete') { throw 'Affected-validation reuse rejects a non-executable mapping-incomplete plan.' }
if ($plan.plan_sha256 -cne $reuse.plan.canonical_sha256 -or [string]$artifactIdentityByName['affected-plan.json'].digest -cne [string]$plan.plan_sha256) { throw 'Reuse plan digest domains are not exact.' }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ("codex-affected-reuse-" + [Guid]::NewGuid().ToString('N'))
$worktreeAdded = $false
try {
    & git -C $root worktree add --detach $temporary $candidate.commit
    if ($LASTEXITCODE -ne 0) { throw 'Reuse cannot materialize the candidate tree.' }
    $worktreeAdded = $true
    $candidateWorkflowBlob = Invoke-ReuseGit @('rev-parse', "$($candidate.commit):$($reuse.workflow.path)")
    if ($candidateWorkflowBlob -cne [string]$reuse.workflow.blob_sha1) { throw 'Reuse workflow Git-object identity differs from the exact candidate receipt.' }
    $recomputed = Resolve-MorphospaceAffectedValidation -RepositoryRoot $temporary -BaseRevision $before.commit -HeadRevision $candidate.commit -RegistryPath (Join-Path $temporary 'manifests/affected-validation-registry.json') -RequestedTier ([string]$plan.requested_tier)
    if ((ConvertTo-MorphospaceCanonicalJson -Value $recomputed) -cne (ConvertTo-MorphospaceCanonicalJson -Value $plan) -or [string]$recomputed.plan_sha256 -cne [string]$reuse.plan.canonical_sha256) { throw 'Reuse plan differs from the exact candidate delta.' }
    if ([string]$reuse.repository -cne [string]$plan.repository -or [string]$plan.repository -cne [string]$recomputed.repository -or [string]$reuse.base.tree -cne [string]$recomputed.base.tree) { throw 'Reuse receipt does not bind the exact recomputed repository and base tree.' }
    $registry = Read-MorphospaceProtocolJson -Path (Join-Path $temporary 'manifests/affected-validation-registry.json')
    [void](Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $temporary -SchemaPath (Join-Path $temporary 'schemas/affected-validation-registry-v1.schema.json'))
    $checkMap = @{}; foreach ($check in @($registry.checks)) { $checkMap[[string]$check.check_id] = $check }
    $expectedCoverage = [Collections.Generic.List[string]]::new()
    $expectedJobs = [Collections.Generic.List[string]]::new()
    foreach ($jobName in @('infrastructure', 'quick-linux', 'quick-windows', 'select', 'standard-windows')) { [void]$expectedJobs.Add($jobName) }
    # The workflow bytes come from the exact candidate temporary checkout after
    # its Git-object join above. This finite topology branch grants no receipt
    # flag, extra-job or source/runner/coverage exception.
    $candidateWorkflowSource=[IO.File]::ReadAllText((Join-Path $temporary ([string]$reuse.workflow.path)),[Text.UTF8Encoding]::new($false,$true))
    $linuxMode=Get-ReuseCandidateLinuxExecutionMode $candidateWorkflowSource
    foreach ($platform in @('linux','windows')) {
        if($platform-ceq'linux'-and$linuxMode-ceq'linux-direct'){continue}
        foreach ($segment in @(Get-MorphospaceAffectedValidationSegments -Plan $plan -Registry $registry -Platform $platform)) { [void]$expectedJobs.Add("segment-$([string]$segment.segment_id)") }
    }
    foreach ($platform in @('linux', 'windows')) {
        $platformChecks = @($plan.selected_checks | Where-Object { @($_.platforms) -ccontains $platform })
        if ($platformChecks.Count -gt 0) {
            $evidenceName = "affected-$platform-evidence.json"
            if (-not $artifactByName.ContainsKey($evidenceName)) { throw "Reuse receipt lacks '$platform' evidence." }
            $artifact = $artifactByName[$evidenceName]
            if ($artifact.platform -cne $platform) { throw "Reuse artifact platform differs for '$platform'." }
            $evidenceRaw = Get-Content -LiteralPath (Join-Path $artifacts $evidenceName) -Raw
            $evidenceSchema = Join-Path $PSScriptRoot '..\schemas\affected-validation-evidence-v1.schema.json'
            if (-not (Test-Json -Json $evidenceRaw -SchemaFile $evidenceSchema -ErrorAction Stop)) { throw "Reuse '$platform' evidence fails its closed schema." }
            $evidence = $evidenceRaw | ConvertFrom-Json -Depth 64
            if ($evidence.result -cne 'pass' -or $evidence.repository -cne $plan.repository -or $evidence.repository -cne $reuse.repository -or $evidence.platform -cne $platform -or $evidence.base.commit -cne $before.commit -or $evidence.base.tree -cne $before.tree -or $evidence.head.commit -cne $candidate.commit -or $evidence.head.tree -cne $recomputed.head.tree -or $evidence.plan_sha256 -cne $reuse.plan.canonical_sha256 -or [string]$artifactIdentityByName[$evidenceName].digest -cne [string]$artifact.sha256) { throw "Reuse '$platform' evidence does not bind its exact plan, platform, trees, and artifact." }
            $expectedIds = @($platformChecks | ForEach-Object { [string]$_.check_id })
            Assert-ReuseExactSet -Actual @($evidence.check_results | ForEach-Object { [string]$_.check_id }) -Expected $expectedIds -Name "$platform evidence check set"
            foreach ($result in @($evidence.check_results)) {
                $check = $checkMap[[string]$result.check_id]
                if ($null -eq $check) { throw "Reuse '$platform' result names an unknown check." }
                if ([long]$result.stdout_bytes + [long]$result.stderr_bytes -gt 10485760) { throw "Reuse '$platform' result exceeds the combined stream bound." }
                Assert-ReusePassingCheck -Result $result -Platform $platform
                $commandBlob = Invoke-ReuseGit @('rev-parse', "$($candidate.commit):$($check.command_path)")
                if ($result.command_path -cne $check.command_path -or $result.command_blob_sha1 -cne $commandBlob) { throw "Reuse '$platform' command identity drifted." }
                [void]$expectedCoverage.Add("$platform$([char]0x1f)$($result.check_id)$([char]0x1f)$($result.command_path)$([char]0x1f)$($result.command_blob_sha1)")
            }
        } elseif ($artifactByName.ContainsKey("affected-$platform-evidence.json")) { throw "Reuse supplies unexpected '$platform' evidence." }
    }
    $actualCoverage = @($reuse.coverage | ForEach-Object { "$($_.platform)$([char]0x1f)$($_.check_id)$([char]0x1f)$($_.command_path)$([char]0x1f)$($_.command_blob_sha1)" })
    Assert-ReuseExactSet -Actual $actualCoverage -Expected @($expectedCoverage.ToArray()) -Name 'coverage'
    Assert-ReuseExactSet -Actual @($reuse.run.check_names) -Expected @($expectedJobs.ToArray()) -Name 'run check identities'
} finally {
    if ($worktreeAdded) { & git -C $root worktree remove --force $temporary | Out-Null; if ($LASTEXITCODE -ne 0) { throw "Reuse could not remove its exact temporary worktree '$temporary'." } }
}
[pscustomobject][ordered]@{ reuse_valid=$true; candidate=$candidate; receipt_sha256=(Get-ReuseFileHash $ReusePath); artifact_names=@($artifactByName.Keys | Sort-Object) }
