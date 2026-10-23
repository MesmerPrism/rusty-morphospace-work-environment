[CmdletBinding()]
param([switch]$SelfTest, [switch]$DispositionOnly, [switch]$FixedSourcePathOnly, [switch]$ActiveEnvelopeReceiptOnly, [switch]$ReviewedIntegrationNativeOnly, [switch]$ReviewedIntegrationOnly)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$module = Import-Module (Join-Path $PSScriptRoot 'SourceOnlyPublicationInputs.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'SourceOnlyPublication.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationReceipt.psm1') -Force

$encoding = [Text.UTF8Encoding]::new($false)
$gitExecutable = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function Assert-Builder([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"), $encoding) }
function Copy-Document([object]$Value) { return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String) }
function Invoke-FixtureGit([string]$Repository, [string[]]$Arguments) {
    $output = @(& $gitExecutable -c commit.gpgsign=false -c core.hooksPath=NUL -c core.autocrlf=false -C $Repository @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "Synthetic Git failed: git -C $Repository $($Arguments -join ' ')`n$($output -join "`n")" }
    return @($output)
}
function Git-Value([string]$Repository, [string[]]$Arguments) { $rows = @(Invoke-FixtureGit $Repository $Arguments); if ($rows.Count -ne 1) { throw 'Synthetic Git did not return one value.' }; return $rows[0].Trim() }
function Assert-Rejected([scriptblock]$Action, [string]$Pattern, [string]$Label) {
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -like $Pattern) { return }; throw "$Label returned a different failure: $($_.Exception.Message)" }
    throw "$Label was not rejected."
}

function New-SyntheticSource([string]$Root, [string]$RepoId, [string]$Path, [string]$Secret) {
    $bare = Join-Path $Root "$RepoId-remote.git"; $repo = Join-Path $Root "$RepoId-work"
    [IO.Directory]::CreateDirectory($bare) | Out-Null
    & $gitExecutable init --bare --initial-branch=main $bare 2>&1 | Out-Null
    & $gitExecutable -c core.autocrlf=false clone $bare $repo 2>&1 | Out-Null
    Invoke-FixtureGit $repo @('config', 'user.email', 'fixture@example.invalid') | Out-Null; Invoke-FixtureGit $repo @('config', 'user.name', 'Fixture') | Out-Null; Invoke-FixtureGit $repo @('config', 'core.autocrlf', 'false') | Out-Null
    $file = Join-Path $repo $Path; [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null
    [IO.File]::WriteAllText($file, "baseline`n", $encoding); Invoke-FixtureGit $repo @('add', '--', $Path) | Out-Null; Invoke-FixtureGit $repo @('commit', '-m', 'baseline') | Out-Null; Invoke-FixtureGit $repo @('push', '-u', 'origin', 'main') | Out-Null
    $old = Git-Value $repo @('rev-parse', 'HEAD')
    [IO.File]::WriteAllText($file, "candidate $Secret`n", $encoding); Invoke-FixtureGit $repo @('add', '--', $Path) | Out-Null; Invoke-FixtureGit $repo @('commit', '-m', 'candidate') | Out-Null
    return [pscustomobject]@{ id = $RepoId; repo = $repo; remote = $bare; path = $Path; old = $old; candidate = Git-Value $repo @('rev-parse', 'HEAD') }
}

function Publish-SyntheticProviderMerge([object]$Source, [string]$Root) {
    Invoke-FixtureGit $Source.repo @('push', 'origin', "$($Source.candidate):refs/heads/candidate") | Out-Null
    $merger = Join-Path $Root "merge-$($Source.id)"; & $gitExecutable -c core.autocrlf=false clone $Source.remote $merger 2>&1 | Out-Null
    Invoke-FixtureGit $merger @('config', 'user.email', 'fixture@example.invalid') | Out-Null; Invoke-FixtureGit $merger @('config', 'user.name', 'Fixture') | Out-Null; Invoke-FixtureGit $merger @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-FixtureGit $merger @('checkout', 'main') | Out-Null; Invoke-FixtureGit $merger @('merge', '--no-ff', '--no-edit', 'origin/candidate') | Out-Null
    $pushOutput = @(Invoke-FixtureGit $merger @('push', 'origin', 'main'))
    Invoke-FixtureGit $Source.repo @('fetch', 'origin', 'main') | Out-Null
    $artifactPath = Join-Path $Root "inputs/$($Source.id)-push.log"
    [IO.File]::WriteAllText($artifactPath, (($pushOutput -join "`n") + "`n"), $encoding)
    return [pscustomobject]@{ final = Git-Value $merger @('rev-parse', 'HEAD'); artifact = $artifactPath }
}

function New-SyntheticOperationEvidence([object]$Start, [object]$Published, [string]$FinishedAt, [string]$OutPath) {
    # Only called after this harness's checked, non-force Git push completed.
    $document = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.source_only_publication_operation_evidence.v1'
        operation_start_sha256 = Get-MorphospaceFileSha256 $Start.path
        provider = [pscustomobject][ordered]@{ repo_id = $Start.document.repo_id; executor_id = 'synthetic-provider' }
        outcome = [pscustomobject][ordered]@{ operation_finished_at = $FinishedAt; push_mode = 'fast-forward'; force_used = $false; result = 'pass' }
        artifact = [pscustomobject][ordered]@{ path = [IO.Path]::GetFileName($Published.artifact); sha256 = Get-MorphospaceFileSha256 $Published.artifact }
    }
    Write-Json $OutPath $document
    return [pscustomobject]@{ path = $OutPath; sha256 = Get-MorphospaceFileSha256 $OutPath; document = $document }
}

function New-RehearsalFixture([string]$Root) {
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $provider = New-SyntheticSource $Root 'provider-source' 'provider.txt' 'SYNTHETIC-CONTENT-ONE'
    $consumer = New-SyntheticSource $Root 'consumer-source' 'consumer.txt' 'SYNTHETIC-CONTENT-TWO'
    $readonly = New-SyntheticSource $Root 'reference-source' 'reference.txt' 'SYNTHETIC-CONTENT-THREE'
    Invoke-FixtureGit $readonly.repo @('push', 'origin', 'main') | Out-Null
    $planning = Join-Path $Root 'planning'; $workspace = Join-Path $planning 'morphospace'; $inputs = Join-Path $Root 'inputs'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null; [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null; [IO.Directory]::CreateDirectory($inputs) | Out-Null
    & $gitExecutable init --initial-branch=main $planning 2>&1 | Out-Null; Invoke-FixtureGit $planning @('config', 'user.email', 'fixture@example.invalid') | Out-Null; Invoke-FixtureGit $planning @('config', 'user.name', 'Fixture') | Out-Null; Invoke-FixtureGit $planning @('config', 'core.autocrlf', 'false') | Out-Null
    $example = Join-Path (Split-Path $PSScriptRoot -Parent) 'examples\hello-morphospace-v2\morphospace'
    $project = Get-Content -Raw (Join-Path $example 'project.spec.json') | ConvertFrom-Json -Depth 64 -DateKind String
    $project.project_id = 'publication-rehearsal'; $project.purpose = 'Synthetic source-only publication builder rehearsal.'; $project.authority_map[0].owner = 'provider-source'
    $project.repositories = @(
        [pscustomobject][ordered]@{ repo_id = 'provider-source'; role = 'core'; path = '<provider-source>'; allowed_paths = @('provider.txt') },
        [pscustomobject][ordered]@{ repo_id = 'consumer-source'; role = 'application'; path = '<consumer-source>'; allowed_paths = @('consumer.txt') },
        [pscustomobject][ordered]@{ repo_id = 'reference-source'; role = 'core'; path = '<reference-source>'; allowed_paths = @('reference.txt') }
    )
    $project.validation_profiles = @([pscustomobject][ordered]@{ profile_id = 'snapshot'; commands = @('synthetic snapshot validation') })
    $lock = Get-Content -Raw (Join-Path $example 'feature.lock.json') | ConvertFrom-Json -Depth 64 -DateKind String; $lock.project_id = 'publication-rehearsal'; $lock.lock_fingerprint = Get-MorphospaceFeatureLockFingerprint $lock
    $unit = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_unit.v1'; unit_id = 'snapshot-unit'; project_id = 'publication-rehearsal'; status = 'validating'; objective = 'Validate an unchanged source snapshot before source-only publication.'
        work_mode = 'validation-only'; guard_profile = 'fast'; change_categories = @('validation'); instruction_impact = 'review'
        instruction_surfaces = @([pscustomobject][ordered]@{ surface_kind = 'agents'; path = 'AGENTS.md'; owner = 'fixture-owner'; change_reason = 'Review only.'; action = 'review-no-change'; status = 'complete'; validation = 'synthetic instruction review'; skill_id = $null }); instruction_none_justification = $null
        prerequisites = @(); allowed_repositories = @([pscustomobject][ordered]@{ repo_id = 'provider-source'; allowed_paths = @() }, [pscustomobject][ordered]@{ repo_id = 'consumer-source'; allowed_paths = @() })
        read_only_dependencies = @([pscustomobject][ordered]@{ repo_id = 'reference-source'; paths = @('reference.txt'); purpose = 'Synthetic pinned reference.'; verification = 'Exact candidate revision.' })
        claim_requirements = [pscustomobject][ordered]@{ minimum_free_disk_mib = 0; required_tools = @(); product_inputs = @() }
        non_scope = @('Source mutation.', 'Planning publication.', 'Runtime or wearer claims.'); acceptance = @([pscustomobject][ordered]@{ acceptance_id = 'source-review'; proof = 'Synthetic source snapshot is reviewed.'; command = 'synthetic source review' })
        risk_tier = 'standard'; device_requirement = 'none'; validation = @([pscustomobject][ordered]@{ profile_id = 'snapshot'; command = 'synthetic snapshot validation' }); outputs = @('validation receipt'); commit_policy = 'Synthetic fixture only.'; push_checkpoint = 'integration-batch'
    }
    foreach ($surface in @(
        @{kind='readme';path='README.md';skill=$null},
        @{kind='skill';path='skills/rusty-morphospace/SKILL.md';skill='rusty-morphospace'},
        @{kind='skill';path='skills/system-engineering/SKILL.md';skill='system-engineering'}
    )) {
        $unit.instruction_surfaces += [pscustomobject][ordered]@{ surface_kind=$surface.kind; path=$surface.path; owner='fixture-owner'; change_reason='Review only.'; action='review-no-change'; status='complete'; validation='synthetic instruction review'; skill_id=$surface.skill }
    }
    $state = Get-Content -Raw (Join-Path $example 'workspace.state.json') | ConvertFrom-Json -Depth 64 -DateKind String
    $state.project_id = 'publication-rehearsal'; $state.current_unit = 'snapshot-unit'; $state.next_ready_unit = $null; $state.last_event_id = 'snapshot-unit-validating-0001'; $state.last_accepted_receipt = $null; $state.validation_checkpoint = $null; $state.repository_heads = @(); $state.dirty_repositories = @(); $state.module_registry.lock_fingerprint = $lock.lock_fingerprint
    $event = [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.iteration_event.v1'; event_id = 'snapshot-unit-validating-0001'; sequence = 1; timestamp = '2026-09-08T09:00:00.0000000Z'; project_id = 'publication-rehearsal'; unit_id = 'snapshot-unit'; event_type = 'state-transition'; summary = 'Synthetic validating baseline.'; receipts = @() }
    Write-Json (Join-Path $workspace 'project.spec.json') $project; Write-Json (Join-Path $workspace 'feature.lock.json') $lock; Write-Json (Join-Path $workspace 'workspace.state.json') $state; Write-Json (Join-Path $workspace 'iteration-units\snapshot-unit.json') $unit
    $retired = Copy-Document $unit; $retired.unit_id = 'retired-unit'; $retired.status = 'superseded'
    Write-Json (Join-Path $workspace 'iteration-units\retired-unit.json') $retired
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'), (($event | ConvertTo-Json -Compress) + "`n"), $encoding)
    [IO.File]::WriteAllText((Join-Path $workspace 'receipts\validation-evidence.txt'), "synthetic validation evidence`n", $encoding)
    $evidence = [pscustomobject][ordered]@{
        receipt_id = 'snapshot-unit-pass-validation'; tier = 'standard'; result = 'pass'
        artifacts = @([pscustomobject][ordered]@{ artifact_id = 'validation-evidence'; kind = 'test-log'; path = 'validation-evidence.txt' })
        criteria = @([pscustomobject][ordered]@{ acceptance_id = 'source-review'; status = 'pass'; command = 'synthetic source review'; evidence_refs = @('validation-evidence') })
        gates = @(
            [pscustomobject][ordered]@{ gate_id = 'validation-snapshot'; status = 'pass'; command = 'synthetic snapshot validation'; evidence_refs = @('validation-evidence') },
            [pscustomobject][ordered]@{ gate_id = 'instruction-synchronization'; status = 'pass'; command = 'Verify every declared instruction surface is complete and validated.'; evidence_refs = @('validation-evidence') }
        ); device_validation = $null
    }
    $receiptPath = Join-Path $workspace 'receipts\snapshot-unit-pass-validation.json'
    $map = [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.repository_map.v1'; repositories = @(
        [pscustomobject][ordered]@{ repo_id = 'provider-source'; path = $provider.repo; role = 'source' }, [pscustomobject][ordered]@{ repo_id = 'consumer-source'; path = $consumer.repo; role = 'source' },
        [pscustomobject][ordered]@{ repo_id = 'reference-source'; path = $readonly.repo; role = 'source' }, [pscustomobject][ordered]@{ repo_id = 'planning-owner'; path = $planning; role = 'planning' },
        [pscustomobject][ordered]@{ repo_id = 'skill-surfaces'; path = $inputs; role = 'source' }
    ) }
    $mapPath = Join-Path $inputs 'repository-map.json'; Write-Json $mapPath $map
    New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId 'snapshot-unit' -RepoMapPath $mapPath -Evidence $evidence -OutPath $receiptPath -CreatedAt '2026-09-08T09:01:00.0000000Z' | Out-Null
    Invoke-FixtureGit $planning @('add', 'morphospace') | Out-Null; Invoke-FixtureGit $planning @('commit', '-m', 'validating snapshot') | Out-Null
    return [pscustomobject]@{ root = $Root; planning = $planning; workspace = $workspace; inputs = $inputs; map = $mapPath; provider = $provider; consumer = $consumer; readonly = $readonly; receipt = $receiptPath }
}

function Assert-CurrentWork([object]$Fixture, [string]$Phase) {
    $output = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -RepoRoot (Split-Path $PSScriptRoot -Parent) -WorkspaceRoot $Fixture.workspace -RepositoryMapPath $Fixture.map -CurrentWorkOnly -SkipOwnerSelfTests 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "Current-work validation failed after $Phase`: $($output -join ' ')" }
}

function New-DeliveryFixtureOriginal([string]$Root,[string]$Name,[string[]]$Argv,[string]$Cwd,[string]$Text,[int]$Minute) {
    # Explicitly MODELED provider/capture transport in a disposable namespace.
    # Production readers, committed owner transitions and Git objects remain real.
    # This grants no actual provider, product, CI, acceptance or adoption credit.
    $dir=Join-Path $Root $Name;[IO.Directory]::CreateDirectory($dir)|Out-Null
    $stdout=Join-Path $dir 'stdout.log';$stderr=Join-Path $dir 'stderr.log'
    [IO.File]::WriteAllText($stdout,$Text,$encoding);[IO.File]::WriteAllText($stderr,'',$encoding)
    $start=[DateTimeOffset]::Parse('2026-10-21T01:00:00Z').AddMinutes($Minute).ToString('o')
    $finish=[DateTimeOffset]::Parse($start).AddSeconds(1).ToString('o')
    [IO.File]::WriteAllText((Join-Path $dir 'MODELED_FIXTURE.txt'),'MODELED test transport only; no real provider execution or adoption credit.',$encoding)
    $intent=[ordered]@{schema='task.root.command_capture_intent.v2';argv=$Argv;cwd=$Cwd;started_utc=$start;no_timeout_or_retry=$true;capture_source=Delivery-Ref $PSCommandPath}
    $ip=Join-Path $dir 'INTENT.json';Write-Json $ip $intent
    $streams=[ordered]@{};foreach($n in @('stdout','stderr')){$p=Join-Path $dir "$n.log";$r=Delivery-Ref $p;$r|Add-Member bytes ([IO.FileInfo]::new($p).Length);$streams[$n]=[ordered]@{raw=$r;eof=$true;drained_bytes=$r.bytes;stored_bytes=$r.bytes;raw_capture_complete=$true;storage_error=$null;read_error=$null}}
    $cp=Join-Path $dir 'COMPLETION.json';Write-Json $cp ([ordered]@{schema='task.root.command_capture_completion.v2';exit_code=0;genuine_full_eof=$true;raw_capture_complete=$true;process_reaped=$true;finished_utc=$finish;intent=Delivery-Ref $ip;stdout=$streams.stdout.raw;stderr=$streams.stderr.raw;streams=$streams;observer_errors=@();termination_requested=$false;automatic_retry=$false})
    Delivery-Ref $cp
}
function Delivery-Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Delivery-Ref([string]$Path){[pscustomobject][ordered]@{path=[IO.Path]::GetFullPath($Path);sha256=Delivery-Hash $Path}}

function Invoke-FixedSourcePathControls {
    # Pure fixed-query contract: no Git, owner, filesystem or provider effects.
    & $module {
        $root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'source-delivery-fixed-query'))
        $argv=@('git','--no-optional-locks','--no-pager','--no-replace-objects','-C',$root,'status','--porcelain=v2','--branch','--untracked-files=all')
        Assert-SourceDeliveryFixedQueryArguments $argv $root
        if($IsWindows) {
            $forward=$root.Replace([char]92,[char]47)
            $backward=$forward.Replace([char]47,[char]92)
            if($forward -ceq $root -or -not $forward.Contains('/') -or $backward -ceq $forward -or -not $backward.Contains([char]92)){throw 'Fixture did not construct distinct slash/backslash spellings.'}
            foreach($spelling in @($forward,$backward,$root.ToUpperInvariant())) {
                $equivalent=@($argv);$equivalent[5]=$spelling
                Assert-SourceDeliveryFixedQueryArguments $equivalent $root
            }
        }
        foreach($damage in @('different-root','relative-root','changed-flag','extra-argument')) {
            $bad=@($argv)
            switch($damage) {
                'different-root'{$bad[5]=$root+'-other'}
                'relative-root'{$bad[5]='source-delivery-fixed-query'}
                'changed-flag'{$bad[9]='--untracked-files=no'}
                'extra-argument'{$bad+=@('--ignored')}
            }
            $rejected=$false
            try {Assert-SourceDeliveryFixedQueryArguments $bad $root} catch {$rejected=$_.Exception.Message -like '*fixed clean-head Git query*'}
            if(-not $rejected){throw "Fixed source query did not refuse $damage."}
        }
    }
    'Fixed source-query path controls passed: native root and Windows slash/backslash/case spelling; different/relative roots and changed/extra flags refuse.'
}

function Invoke-DeliveryComputeOriginal([string]$Root,[string]$Workspace,[string]$Map,[string]$RequestPath,[string]$OutPath,[string]$Name='actual-compute-original',[switch]$PermitFailure) {
    # Real fixed public child, not New-DeliveryFixtureOriginal's MODELED transport.
    $dir=Join-Path $Root $Name;Assert-Builder (-not(Test-Path -LiteralPath $dir)) 'Actual computation capture directory already exists.';[IO.Directory]::CreateDirectory($dir)|Out-Null
    $hostPath=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $argv=@($hostPath,'-NoProfile','-File',(Join-Path $PSScriptRoot 'New-SourceOnlyPublicationInput.ps1'),'-Action','ComputeReviewedIntegration','-WorkspaceRoot',$Workspace,'-RepoMapPath',$Map,'-RequestPath',$RequestPath,'-ExpectedRequestSha256',(Delivery-Hash $RequestPath),'-OutPath',$OutPath)
    $intent=[ordered]@{schema='task.root.command_capture_intent.v2';argv=$argv;cwd=$Root;started_utc=[DateTimeOffset]::UtcNow.ToString('o');no_timeout_or_retry=$true;capture_source=Delivery-Ref $PSCommandPath}
    $ip=Join-Path $dir 'INTENT.json';Write-Json $ip $intent
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$hostPath;$psi.WorkingDirectory=$Root;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($arg in @($argv|Select-Object -Skip 1)){$psi.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::new();$child.StartInfo=$psi;$stdout=[IO.MemoryStream]::new();$stderr=[IO.MemoryStream]::new()
    try {
        Assert-Builder ($child.Start()) 'Public Compute child did not start.'
        $outTask=$child.StandardOutput.BaseStream.CopyToAsync($stdout);$errTask=$child.StandardError.BaseStream.CopyToAsync($stderr)
        $child.WaitForExit();[void]$outTask.GetAwaiter().GetResult();[void]$errTask.GetAwaiter().GetResult();$exit=$child.ExitCode
        [IO.File]::WriteAllBytes((Join-Path $dir 'stdout.log'),$stdout.ToArray());[IO.File]::WriteAllBytes((Join-Path $dir 'stderr.log'),$stderr.ToArray())
        $streams=[ordered]@{};foreach($name in @('stdout','stderr')){$ref=Delivery-Ref (Join-Path $dir "$name.log");$ref|Add-Member bytes ([IO.FileInfo]::new($ref.path).Length);$streams[$name]=[ordered]@{raw=$ref;eof=$true;drained_bytes=$ref.bytes;stored_bytes=$ref.bytes;raw_capture_complete=$true;storage_error=$null;read_error=$null}}
        $completion=[ordered]@{schema='task.root.command_capture_completion.v2';exit_code=[int]$exit;genuine_full_eof=$true;raw_capture_complete=$true;process_reaped=$true;finished_utc=[DateTimeOffset]::UtcNow.ToString('o');intent=Delivery-Ref $ip;stdout=$streams.stdout.raw;stderr=$streams.stderr.raw;streams=$streams;observer_errors=@();termination_requested=$false;automatic_retry=$false}
        $cp=Join-Path $dir 'COMPLETION.json';Write-Json $cp $completion
        if(-not $PermitFailure){Assert-Builder ($exit -eq 0) "Actual public Compute failed: $([IO.File]::ReadAllText($streams.stderr.raw.path))"}
        return Delivery-Ref $cp
    } finally {$child.Dispose();$stdout.Dispose();$stderr.Dispose()}
}

function New-DeliveryIntegrationPublishedParent {
    # This is an independent ordinary bounded source subject. Its provider
    # observations remain explicitly MODELED; owner/Git and later Compute are real.
    $branch=Git-Value $source @('symbolic-ref','--short','HEAD')
    $remote=Join-Path $deliveryRoot 'integration-published.git'
    Invoke-FixtureGit $source @('init','--bare','--initial-branch=main',$remote)|Out-Null
    Invoke-FixtureGit $source @('remote','add','origin',$remote)|Out-Null
    Invoke-FixtureGit $source @('push','origin',"$($seed.source_commit):refs/heads/main")|Out-Null
    Invoke-FixtureGit $source @('checkout','-b','independent-published',$seed.source_commit)|Out-Null
    $baselineContent=[IO.File]::ReadAllText((Join-Path $source 'morphospace/README.md'))
    [IO.File]::WriteAllText((Join-Path $source 'morphospace/README.md'),"# independently published heading`n"+$baselineContent,$encoding)
    Invoke-FixtureGit $source @('commit','-am','independent published documentation')|Out-Null
    $candidate=Git-Value $source @('rev-parse','HEAD');$tree=Git-Value $source @('rev-parse','HEAD^{tree}')
    $pmap=Join-Path $deliveryRoot 'integration-parent-map.json';Write-Json $pmap ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='project-shell';path=$source;role='source'})})
    $parentRequest=Copy-Document $request;$parentRequest.disposition_id='independent-published-parent';$parentRequest.publication_map=Delivery-Ref $pmap
    $parentRequest.publication_subject.base_commit=$seed.source_commit;$parentRequest.publication_subject.base_tree=$seed.source_tree;$parentRequest.publication_subject.candidate_commit=$candidate;$parentRequest.publication_subject.candidate_tree=$tree;$parentRequest.publication_subject.allowed_paths=@('morphospace/README.md')
    $ppackage=Copy-Document (Read-EnvelopeProtocolJson $package);$ppackage.package_id='independent-published-parent';$ppackage.repositories[0].base_commit=$seed.source_commit;$ppackage.repositories[0].allowed_paths=@('morphospace/README.md')
    $pkg=Join-Path $deliveryRoot 'integration-parent-package.json';Write-Json $pkg $ppackage;$parentRequest.source_package=Delivery-Ref $pkg
    $parentRequest.source_check_commands=@(,@($gitExecutable,'-C',$source,'diff','--check',"$($seed.source_commit)..$candidate"))
    $rp=Join-Path $deliveryRoot 'integration-parent-request.json';Write-Json $rp $parentRequest
    $pd=New-MorphospaceSourceDeliveryDisposition -RequestPath $rp -ExpectedRequestSha256 (Delivery-Hash $rp) -WorkspaceRoot $ws -RepoMapPath $pmap -HumanDecisionPath $human -ExpectedHumanDecisionSha256 (Delivery-Hash $human) -OutPath (Join-Path $deliveryRoot 'integration-parent-disposition.json')
    $snapshotArgs=@($gitExecutable,'--no-optional-locks','--no-pager','--no-replace-objects','-C',$source,'status','--porcelain=v2','--branch','--untracked-files=all');$status=(Invoke-FixtureGit $source @('status','--porcelain=v2','--branch','--untracked-files=all')) -join "`n"
    $pre=New-DeliveryFixtureOriginal $deliveryRoot 'integration-parent-before' $snapshotArgs $source $status 20
    Invoke-FixtureGit $source @('diff','--check',"$($seed.source_commit)..$candidate")|Out-Null
    $check=New-DeliveryFixtureOriginal $deliveryRoot 'integration-parent-check' $parentRequest.source_check_commands[0] $source '' 21
    $post=New-DeliveryFixtureOriginal $deliveryRoot 'integration-parent-after' $snapshotArgs $source $status 22
    $published=Publish-SyntheticProviderMerge ([pscustomobject]@{id='integration-parent';repo=$source;remote=$remote;candidate=$candidate}) $deliveryRoot
    $merge=New-DeliveryFixtureOriginal $deliveryRoot 'integration-parent-merge' @($providerOrigin,'pr','merge','9','--repo','Example/ported-source','--merge','--match-head-commit',$candidate) $source '' 23
    $checks=New-DeliveryFixtureOriginal $deliveryRoot 'integration-parent-checks' @($providerOrigin,'pr','checks','9','--repo','Example/ported-source','--required','--json','name,state,link') $source '[{"name":"independent-source","state":"SUCCESS","link":"https://example.invalid/MODELED-parent"}]' 24
    $prText=[ordered]@{number=9;state='closed';merged=$true;merged_at='2026-10-21T01:23:01Z';merge_commit_sha=$published.final;head=[ordered]@{sha=$candidate;repo=[ordered]@{full_name='Example/ported-source'}};base=[ordered]@{ref='main';repo=[ordered]@{full_name='Example/ported-source'}}}|ConvertTo-Json -Depth 10
    $pr=New-DeliveryFixtureOriginal $deliveryRoot 'integration-parent-pr' @($providerOrigin,'api','--method','GET','repos/Example/ported-source/pulls/9') $source $prText 25
    $parentLanding=Copy-Document $lr;$parentLanding.disposition=Delivery-Ref $pd.path;$parentLanding.source_checks=@($check);$parentLanding.source_before_original=$pre;$parentLanding.source_after_original=$post;$parentLanding.pull_request_number=9;$parentLanding.pull_request_original=$pr;$parentLanding.required_checks_original=$checks;$parentLanding.merge_original=$merge
    $lp=Join-Path $deliveryRoot 'integration-parent-landing-request.json';Write-Json $lp $parentLanding
    $landed=New-MorphospaceSourceDeliveryLanding -RequestPath $lp -ExpectedRequestSha256 (Delivery-Hash $lp) -RepoMapPath $pmap -OutPath (Join-Path $deliveryRoot 'integration-parent-landing.json')
    Invoke-FixtureGit $source @('checkout',$branch)|Out-Null;Invoke-FixtureGit $source @('remote','remove','origin')|Out-Null
    [pscustomobject]@{landing=Delivery-Ref $landed.path;commit=$published.final;tree=$tree;baseline_content=$baselineContent;remote=$remote}
}

function Invoke-DeliveryAcceptedIntegrationControls($Published) {
    Invoke-FixtureGit $source @('checkout','-b','accepted-reviewed-integration',$acceptedRequest.source_reference.commit)|Out-Null
    Invoke-FixtureGit $source @('merge','--no-ff','--no-edit',$Published.commit)|Out-Null
    $candidate=Git-Value $source @('rev-parse','HEAD');$tree=Git-Value $source @('rev-parse','HEAD^{tree}')
    $literal="# independently published heading`n"+$Published.baseline_content+"delivery consumer source`n"
    Assert-Builder ([IO.File]::ReadAllText((Join-Path $source 'morphospace/README.md')) -ceq $literal) 'Real overlapping owner/published merge lost independently expected content.'
    $cr=[ordered]@{schema='rusty.morphospace.workflow.source_delivery_disposition.v1';kind='integration-computation-request';consumer=Copy-Document $acceptedRequest.consumer;source_reference=Copy-Document $acceptedRequest.source_reference;publication_subject=Copy-Document $acceptedRequest.publication_subject;publication_map=Copy-Document $acceptedRequest.publication_map;published_landing=$Published.landing}
    $cr.consumer.boundary_kind='accepted-source-owner-reviewed-integration';$cr.publication_subject.base_commit=$Published.commit;$cr.publication_subject.base_tree=$Published.tree;$cr.publication_subject.candidate_commit=$candidate;$cr.publication_subject.candidate_tree=$tree
    $cp=Join-Path $deliveryRoot 'computation-request.json';Write-Json $cp $cr;$out=Join-Path $deliveryRoot 'computation.json'
    $originalUrl=Git-Value $source @('remote','get-url','origin')
    try {Invoke-FixtureGit $source @('remote','set-url','origin','https://github.com/Example/ported-source.git')|Out-Null;$original=Invoke-DeliveryComputeOriginal $deliveryRoot $ws $ownerMap $cp $out}
    finally {Invoke-FixtureGit $source @('remote','set-url','origin',$originalUrl)|Out-Null}
    # A clean commit with the SAME ordered parents but manually altered source
    # must fail the actual public producer's computed-tree comparison.
    $readme=Join-Path $source 'morphospace/README.md';$sourceBytes=[IO.File]::ReadAllBytes($readme)
    try {[IO.File]::AppendAllText($readme,"unreviewed manual resolution`n",$encoding);Invoke-FixtureGit $source @('add','morphospace/README.md')|Out-Null;$manualTree=Git-Value $source @('write-tree')}
    finally {[IO.File]::WriteAllBytes($readme,$sourceBytes);Invoke-FixtureGit $source @('add','morphospace/README.md')|Out-Null}
    $manual=Git-Value $source @('commit-tree',$manualTree,'-p',$acceptedRequest.source_reference.commit,'-p',$Published.commit,'-m','manual-extra-source')
    Invoke-FixtureGit $source @('checkout','-b','manual-reviewed-integration',$manual)|Out-Null
    $manualRequest=Copy-Document $cr;$manualRequest.publication_subject.candidate_commit=$manual;$manualRequest.publication_subject.candidate_tree=$manualTree
    $manualPath=Join-Path $deliveryRoot 'manual-integration-request.json';Write-Json $manualPath $manualRequest;$manualOutput=Join-Path $deliveryRoot 'manual-integration-computation.json'
    try {Invoke-FixtureGit $source @('remote','set-url','origin','https://github.com/Example/ported-source.git')|Out-Null;$manualOriginal=Invoke-DeliveryComputeOriginal $deliveryRoot $ws $ownerMap $manualPath $manualOutput 'actual-manual-refusal' -PermitFailure}
    finally {Invoke-FixtureGit $source @('remote','set-url','origin',$originalUrl)|Out-Null;Invoke-FixtureGit $source @('checkout','accepted-reviewed-integration')|Out-Null}
    $manualCompletion=Read-EnvelopeProtocolJson $manualOriginal.path
    Assert-Builder ($manualCompletion.exit_code -ne 0 -and -not(Test-Path -LiteralPath $manualOutput) -and [IO.File]::ReadAllText($manualCompletion.stderr.path) -like '*exact computed tree*') 'Public producer accepted a manual source tree with otherwise correct parents.'
    $actualComputation=Read-EnvelopeProtocolJson $out;$actualCompletion=Read-EnvelopeProtocolJson $original.path
    $actualOuter=[pscustomobject]@{completion=$actualCompletion;intent=Read-EnvelopeProtocolJson $actualCompletion.intent.path}
    # Isolate the exact private native-reader predicates using genuine child
    # records. These altered DTOs are NOT public Compute/Disposition authority.
    foreach($damage in @('nonzero-tree-prefix','no-eof','string-eof','unknown-field','extra-option','reversed-time','wrong-stdin','custom-config','attribute-environment')) {
        $nativeCase=Copy-Document $actualComputation;$index=if($damage -ceq 'wrong-stdin'){8}else{11}
        $record=Read-EnvelopeProtocolJson $nativeCase.native.commands[$index].path
        switch($damage) {
            'nonzero-tree-prefix' {$record.exit_code=1}
            'no-eof' {$record.stdout_eof=$false}
            'string-eof' {$record.stdout_eof='true'}
            'unknown-field' {$record|Add-Member caller_pass $true}
            'extra-option' {$record.arguments+=,'-Xours'}
            'reversed-time' {$record.finished_utc=$actualOuter.intent.started_utc}
            'wrong-stdin' {$stdin=Join-Path $deliveryRoot 'wrong-native-stdin.bin';[IO.File]::WriteAllBytes($stdin,$encoding.GetBytes("unrelated.txt"+[char]0));$record.stdin=Delivery-Ref $stdin}
            'custom-config' {$config=Join-Path $deliveryRoot 'wrong-native-config.bin';[IO.File]::WriteAllText($config,"[core]`nrepositoryformatversion = 0`nbare = true`n[merge]`ndefault = forbidden`n",$encoding);$nativeCase.native.config=Delivery-Ref $config}
            'attribute-environment' {$envCase=Read-EnvelopeProtocolJson $nativeCase.native.environment.path;$envCase|Add-Member GIT_ATTR_SOURCE $seed.source_commit;$envPath=Join-Path $deliveryRoot 'wrong-native-environment.json';Write-Json $envPath $envCase;$nativeCase.native.environment=Delivery-Ref $envPath}
        }
        $recordPath=Join-Path $deliveryRoot "wrong-native-$damage.json";Write-Json $recordPath $record;$nativeCase.native.commands[$index]=Delivery-Ref $recordPath
        Assert-Rejected {&$module {param($c,$o) Read-SourceDeliveryIntegrationNative $c (New-SourceDeliveryObservation) $o @('morphospace/README.md')} $nativeCase $actualOuter} '*Native*' "private native $damage"
    }
    $integrated=Copy-Document $acceptedRequest;$integrated.consumer=$cr.consumer;$integrated.publication_subject=$cr.publication_subject;$integrated.disposition_id='accepted-reviewed-integration';$integrated.relationship.kind='reviewed-integration';$integrated.relationship.limits=@('Acceptance and validation remain original source only; new subject requires fresh qualification and ordinary publication.');$integrated.source_check_commands=@(,@($gitExecutable,'-C',$source,'diff','--check',"$($Published.commit)..$candidate"))
    $integrated|Add-Member integration ([pscustomobject]@{published_landing=$Published.landing;computation=Delivery-Ref $out;computation_original=$original})
    $ip=Join-Path $deliveryRoot 'integrated-request.json';Write-Json $ip $integrated
    $args=@{RequestPath=$ip;ExpectedRequestSha256=Delivery-Hash $ip;WorkspaceRoot=$ws;RepoMapPath=$ownerMap;HumanDecisionPath=$acceptedHuman;ExpectedHumanDecisionSha256=Delivery-Hash $acceptedHuman}
    $beforeOwner=Get-EnvelopeWorkspaceByteInventorySha256 $ws
    $disposition=New-MorphospaceSourceDeliveryDisposition @args -OutPath (Join-Path $deliveryRoot 'integrated-disposition.json')
    Assert-Builder (-not $disposition.document.source_landed -and -not $disposition.document.acceptance_credit -and (Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $beforeOwner) 'Integration disposition mutated or transferred owner credit.'
    foreach($damage in @('substituted-computation','wrong-source','wrong-parent','wrong-tree','old-branch','port-kind')) {
        $bad=Copy-Document $integrated
        switch($damage) {
            'substituted-computation' {$savedComputation=[IO.File]::ReadAllBytes($out);$changed=Copy-Document (Read-EnvelopeProtocolJson $out);$changed.native.result_tree='1'*40;Write-Json $out $changed;$bad.integration.computation=Delivery-Ref $out}
            'wrong-source' {$bad.source_reference.commit=$seed.source_commit}
            'wrong-parent' {$bad.publication_subject.base_commit=$seed.source_commit;$bad.publication_subject.base_tree=$seed.source_tree}
            'wrong-tree' {$bad.publication_subject.candidate_tree=$Published.tree}
            'old-branch' {$bad.consumer.boundary_kind='accepted-source-owner';$bad.relationship.kind='same-source'}
            'port-kind' {$bad.relationship.kind='reviewed-port'}
        }
        $bp=Join-Path $deliveryRoot "integrated-$damage-request.json";Write-Json $bp $bad;$a=$args.Clone();$a.RequestPath=$bp;$a.ExpectedRequestSha256=Delivery-Hash $bp
        $reason=if($damage -ceq 'substituted-computation'){'*Outer original does not bind this exact computation output*'}else{'*'}
        try {Assert-Rejected {New-MorphospaceSourceDeliveryDisposition @a -OutPath (Join-Path $deliveryRoot "refused-integrated-$damage.json")} $reason "integration $damage"}
        finally {if($damage -ceq 'substituted-computation'){[IO.File]::WriteAllBytes($out,$savedComputation)}}
        Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $beforeOwner) 'Refused integration changed owner history.'
    }
    $remote=Join-Path $deliveryRoot 'integrated-publication.git';Invoke-FixtureGit $source @('init','--bare','--initial-branch=main',$remote)|Out-Null
    Invoke-FixtureGit $source @('remote','set-url','origin',$remote)|Out-Null;Invoke-FixtureGit $source @('push','origin',"$($Published.commit):refs/heads/main")|Out-Null
    $statusArgs=@($gitExecutable,'--no-optional-locks','--no-pager','--no-replace-objects','-C',$source,'status','--porcelain=v2','--branch','--untracked-files=all');$status=(Invoke-FixtureGit $source @('status','--porcelain=v2','--branch','--untracked-files=all')) -join "`n"
    $pre=New-DeliveryFixtureOriginal $deliveryRoot 'integrated-before' $statusArgs $source $status 30
    Invoke-FixtureGit $source @('diff','--check',"$($Published.commit)..$candidate")|Out-Null
    $check=New-DeliveryFixtureOriginal $deliveryRoot 'integrated-check' $integrated.source_check_commands[0] $source '' 31
    $post=New-DeliveryFixtureOriginal $deliveryRoot 'integrated-after' $statusArgs $source $status 32
    $normal=Publish-SyntheticProviderMerge ([pscustomobject]@{id='integrated';repo=$source;remote=$remote;candidate=$candidate}) $deliveryRoot
    $merge=New-DeliveryFixtureOriginal $deliveryRoot 'integrated-merge' @($providerOrigin,'pr','merge','10','--repo','Example/ported-source','--merge','--match-head-commit',$candidate) $source '' 33
    $checks=New-DeliveryFixtureOriginal $deliveryRoot 'integrated-required-checks' @($providerOrigin,'pr','checks','10','--repo','Example/ported-source','--required','--json','name,state,link') $source '[{"name":"fresh-integrated-source","state":"SUCCESS","link":"https://example.invalid/MODELED-integrated"}]' 34
    $prText=[ordered]@{number=10;state='closed';merged=$true;merged_at='2026-10-21T01:33:01Z';merge_commit_sha=$normal.final;head=[ordered]@{sha=$candidate;repo=[ordered]@{full_name='Example/ported-source'}};base=[ordered]@{ref='main';repo=[ordered]@{full_name='Example/ported-source'}}}|ConvertTo-Json -Depth 10
    $pr=New-DeliveryFixtureOriginal $deliveryRoot 'integrated-pr' @($providerOrigin,'api','--method','GET','repos/Example/ported-source/pulls/10') $source $prText 35
    $landingRequest=Copy-Document $ownerLandingRequest;$landingRequest.disposition=Delivery-Ref $disposition.path;$landingRequest.source_checks=@($check);$landingRequest.source_before_original=$pre;$landingRequest.source_after_original=$post;$landingRequest.pull_request_number=10;$landingRequest.pull_request_original=$pr;$landingRequest.required_checks_original=$checks;$landingRequest.merge_original=$merge
    $lp=Join-Path $deliveryRoot 'integrated-landing-request.json';Write-Json $lp $landingRequest
    $landed=New-MorphospaceSourceDeliveryLanding -RequestPath $lp -ExpectedRequestSha256 (Delivery-Hash $lp) -RepoMapPath $ownerMap -OutPath (Join-Path $deliveryRoot 'integrated-landing.json')
    # Native execution and its private object database are unnecessary on retained
    # reads. Existing Git object observation remains read-only and available.
    $isolated=[IO.Path]::GetFullPath($out+'.native/isolated');$expected=[IO.Path]::GetFullPath((Join-Path ($out+'.native') 'isolated'))
    Assert-Builder ($isolated -ceq $expected -and [IO.Path]::GetDirectoryName($isolated) -ceq [IO.Path]::GetFullPath($out+'.native')) 'Unsafe private computation cleanup.'
    Assert-Builder (-not (Test-Path -LiteralPath $isolated)) 'Public computation left its obsolete private object database present.'
    &$module {param($r) $script:integrationSavedNative=${function:Invoke-SourceDeliveryIntegrationGit};$script:integrationSavedRemote=${function:Get-SourceOnlyInputRemoteReadback};function script:Invoke-SourceDeliveryIntegrationGit{throw 'Native recomputation forbidden in retained read.'};function script:Get-SourceOnlyInputRemoteReadback{throw 'Network forbidden in retained read.'}} $integrated
    try {Assert-Builder (Test-MorphospaceSourceDeliveryLanding -LandingPath $landed.path -ExpectedLandingSha256 $landed.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map) 'Retained integrated landing required a network/native recomputation.'}
    finally {&$module {Set-Item Function:script:Invoke-SourceDeliveryIntegrationGit $script:integrationSavedNative;Set-Item Function:script:Get-SourceOnlyInputRemoteReadback $script:integrationSavedRemote;Remove-Variable integrationSavedNative,integrationSavedRemote -Scope Script}}
    Invoke-FixtureGit $source @('checkout','--detach',$ownerPublished.final)|Out-Null
    Write-Host 'Accepted reviewed-integration controls passed: real accepted source and independent overlapping published parent; actual fixed public native producer/original; zero credit/no owner writes; immutable outer output substitution and source/parent/tree/old-variant refusals; retained native/network unavailable.'
    return Delivery-Ref $landed.path
}

function Invoke-DeliveryContractControls {
    $deliveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('source-delivery-contract-'+[guid]::NewGuid().ToString('N'))
    $ownerModule=Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -PassThru
    $freezeModule=Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -PassThru
    $protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
    $ledgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
    . (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')
    function Invoke-EnvelopeGit([string]$Path,[string[]]$Arguments){Invoke-FixtureGit $Path $Arguments}
    $savedGit=&$module { ${function:Get-SourceOnlyInputGitValue} };$savedRemote=&$module { ${function:Get-SourceOnlyInputRemoteReadback} }
    try {
        $seed=New-EnvelopeAdmissionPreparedFixture -Root $deliveryRoot -RepositoryRoot (Split-Path $PSScriptRoot -Parent) -TransitionLedgerModule $ledgerModule -OwnerProducedPreparation
        $seed.admission_template.unit|Add-Member -NotePropertyName guard_profile -NotePropertyValue locked -Force
        $ws=$seed.workspace;$map=Join-Path $ws 'repository-map.json';$source=$seed.source_repository
        $admit=Join-Path $deliveryRoot 'admit.json';Write-Json $admit $seed.admission_template
        Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $ws -DevelopmentUnitAdmission $admit -ExpectedDevelopmentUnitAdmissionSha256 (Delivery-Hash $admit) -OutPath (Join-Path $ws 'receipts/u002-admission.json') -Timestamp '2026-10-20T00:00:00.0000000Z' -Execute|Out-Null
        foreach($action in @('Ready','Claim')){Invoke-MorphospaceWorkUnitAutomation -Action $action -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard -Timestamp '2026-10-20T00:01:00.0000000Z' -Execute|Out-Null}
        [IO.File]::AppendAllText((Join-Path $source 'morphospace/README.md'),"delivery consumer source`n",$encoding)
        Invoke-FixtureGit $source @('add','morphospace/README.md')|Out-Null;Invoke-FixtureGit $source @('commit','-m','consumer snapshot')|Out-Null
        $unitPath=Join-Path $ws 'iteration-units/u002.json';$statePath=Join-Path $ws 'workspace.state.json';$eventsPath=Join-Path $ws 'iteration-events.jsonl'
        $u=Read-EnvelopeProtocolJson $unitPath;$st=Read-EnvelopeProtocolJson $statePath;$fl=Read-EnvelopeProtocolJson (Join-Path $ws 'feature.lock.json')
        $freeze=[ordered]@{schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id='delivery-consumer-a';project_id='envelope-test';unit_id='u002';expected=[ordered]@{project_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $ws 'project.spec.json'));state_sha256=Get-EnvelopeCanonicalJsonSha256 $st;unit_sha256=Get-EnvelopeCanonicalJsonSha256 $u;feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $fl;source_composition_path='source-composition.json';source_composition_sha256=Delivery-Hash (Join-Path $ws 'source-composition.json');repository_map_path='repository-map.json';repository_map_sha256=Delivery-Hash $map;events_sha256=Delivery-Hash $eventsPath;events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=$st.last_event_id};final_repositories=@([ordered]@{repo_id='project-shell';commit=Git-Value $source @('rev-parse','HEAD');tree=Git-Value $source @('rev-parse','HEAD^{tree}')});changed_paths=@([ordered]@{repo_id='project-shell';paths=@('morphospace/')});cleanliness_policy='clean-only';instruction_surfaces=@([ordered]@{path='morphospace/README.md';disposition='reviewed-no-change'});feature_lock=[ordered]@{revision=$fl.revision;sha256=Get-EnvelopeCanonicalJsonSha256 $fl};effects=@('none');permissions=@();device_use=@('none');test_matrix=@([ordered]@{test_id='source';command='Fixture source predicate.'});cleanup_evidence=@('Disposable MODELED namespace.');source_composition=[ordered]@{path='source-composition.json';sha256=Delivery-Hash (Join-Path $ws 'source-composition.json')};does_not_prove=@('No product or actual provider credit.')}
        $fp=Join-Path $deliveryRoot 'freeze.json';Write-Json $fp $freeze
        Invoke-MorphospaceFreezeCandidate -WorkspaceRoot $ws -UnitId u002 -CandidateFreeze $fp -ExpectedCandidateFreezeSha256 (Delivery-Hash $fp) -OutPath (Join-Path $ws 'receipts/delivery-consumer-a.json') -Timestamp '2026-10-20T00:02:00.0000000Z' -Execute|Out-Null
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard -Timestamp '2026-10-20T00:03:00.0000000Z' -Execute|Out-Null
        $st=Read-EnvelopeProtocolJson $statePath;$u=Read-EnvelopeProtocolJson $unitPath
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $ws
        $port=New-SyntheticSource $deliveryRoot 'independent-port' 'ported.txt' 'MODELED-PORT'
        $publicationMap=Join-Path $deliveryRoot 'publication-map.json';Write-Json $publicationMap ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='project-shell';path=$port.repo;role='source'})})
        # Only the modeled remote transport is replaced. Source/tree/path queries,
        # observation parsing, owner transactions and all evidence readers run production code.
        &$module {param($old,$bare) $script:deliverySavedGit=$old;$script:deliveryBare=$bare
            function script:Get-SourceOnlyInputGitValue {param($Repository,$Arguments,$Label) if(($Arguments -join '|') -ceq 'remote|get-url|origin'){return 'https://github.com/Example/ported-source.git'};&$script:deliverySavedGit $Repository $Arguments $Label}
            function script:Get-SourceOnlyInputRemoteReadback {param($Repository,$RemoteUrl,$TargetBranch) $v=&$script:deliverySavedGit $Repository @('rev-parse','refs/remotes/origin/main') 'MODELED remote';[pscustomobject]@{status='observed';revision=$v}}
        } $savedGit $port.remote
        $human=Join-Path $deliveryRoot 'human.txt';[IO.File]::WriteAllText($human,'MODELED explicit human supersession of source-before-adoption ordering only.',$encoding)
        $review=Join-Path $deliveryRoot 'relationship.txt';[IO.File]::WriteAllText($review,'MODELED reviewed port; built source and tests are not transferred.',$encoding)
        $package=Join-Path $deliveryRoot 'package.json';Write-Json $package ([ordered]@{schema='rusty.morphospace.workflow.direct_work_package.v1';package_id='bounded-port';objective='Qualify a bounded independent source port.';guard_profile='fast';risk_tier='standard';change_categories=@('implementation','validation');repositories=@([ordered]@{repository='Example/ported-source';base_commit=$port.old;allowed_paths=@('ported.txt')});validation=@('MODELED source predicate');recovery_checkpoints=@('local-commit-before-handoff','remote-update-before-handoff');history=[ordered]@{mode='rebuild-first';max_minutes=20}})
        $command=@($gitExecutable,'-C',$port.repo,'diff','--check',"$($port.old)..$($port.candidate)")
        $request=[ordered]@{schema='rusty.morphospace.workflow.source_delivery_disposition.v1';kind='request';disposition_id='bounded-port';consumer=[ordered]@{boundary_kind='frozen-consumer';workspace_root=$ws;project_id='envelope-test';unit_id='u002';freeze_id='delivery-consumer-a';freeze_receipt_sha256=$u.candidate_freeze.receipt_sha256;begin_event_id=$st.last_event_id;state_raw_sha256=Delivery-Hash $statePath;unit_raw_sha256=Delivery-Hash $unitPath;events_raw_sha256=Delivery-Hash $eventsPath;repository_map=Delivery-Ref $map};source_reference=$freeze.final_repositories[0];publication_subject=[ordered]@{repo_id='project-shell';repository='Example/ported-source';base_commit=$port.old;base_tree=Git-Value $port.repo @('rev-parse',"$($port.old)^{tree}");candidate_commit=$port.candidate;candidate_tree=Git-Value $port.repo @('rev-parse','HEAD^{tree}');allowed_paths=@('ported.txt')};publication_map=Delivery-Ref $publicationMap;ordering_supersession=[ordered]@{authority='direct-human';human_decision=Delivery-Ref $human;scope='source-before-adoption-ordering-only';prior_dependency_refs=@([ordered]@{unit_json_pointer='/outputs/0';value_sha256=Get-EnvelopeCanonicalJsonSha256 $u.outputs[0]})};relationship=[ordered]@{kind='reviewed-port';review=Delivery-Ref $review;limits=@('Original APK/source predicates and adoption remain pending. No content equivalence or test transfer.')};source_package=Delivery-Ref $package;source_check_commands=@(,$command)}
        $rp=Join-Path $deliveryRoot 'request.json';Write-Json $rp $request
         $dispositionArguments=@{RequestPath=$rp;ExpectedRequestSha256=Delivery-Hash $rp;WorkspaceRoot=$ws;RepoMapPath=$publicationMap;HumanDecisionPath=$human;ExpectedHumanDecisionSha256=Delivery-Hash $human}
        $disposition=New-MorphospaceSourceDeliveryDisposition @dispositionArguments -OutPath (Join-Path $deliveryRoot 'disposition.json')
        Assert-Builder (-not $disposition.document.source_landed -and $disposition.document.adoption_pending -and -not $disposition.document.acceptance_credit) 'Preparation inferred landed/adoption credit.'
        Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $before) 'Disposition changed the consumer.'
        Assert-Rejected {New-MorphospaceSourceDeliveryDisposition @dispositionArguments -OutPath $disposition.path} '*exists*' 'create-new disposition'
        $damaged=Copy-Document $request;$damaged.relationship.kind='same-source';Write-Json $rp $damaged;$badArgs=$dispositionArguments.Clone();$badArgs.ExpectedRequestSha256=Delivery-Hash $rp
        Assert-Rejected {New-MorphospaceSourceDeliveryDisposition @badArgs -OutPath (Join-Path $deliveryRoot 'false-same-source.json')} '*Same-source*' 'false source equivalence'
        Write-Json $rp $request
        $statusArgs=@($gitExecutable,'--no-optional-locks','--no-pager','--no-replace-objects','-C',$port.repo,'status','--porcelain=v2','--branch','--untracked-files=all')
        $statusText=(Invoke-FixtureGit $port.repo @('status','--porcelain=v2','--branch','--untracked-files=all')) -join "`n"
        $pre=New-DeliveryFixtureOriginal $deliveryRoot 'source-before' $statusArgs $port.repo $statusText 1
        Invoke-FixtureGit $port.repo @('diff','--check',"$($port.old)..$($port.candidate)")|Out-Null
        $check=New-DeliveryFixtureOriginal $deliveryRoot 'source-check' $command $port.repo '' 2
        $post=New-DeliveryFixtureOriginal $deliveryRoot 'source-after' $statusArgs $port.repo $statusText 3
        [IO.Directory]::CreateDirectory((Join-Path $deliveryRoot 'inputs'))|Out-Null
        $published=Publish-SyntheticProviderMerge $port $deliveryRoot
        $providerOrigin=Join-Path $deliveryRoot 'MODELED-provider-origin.ps1';[IO.File]::Copy($PSCommandPath,$providerOrigin)
        $providerSnapshot=Join-Path $deliveryRoot 'MODELED-provider-retained.ps1';[IO.File]::Copy($providerOrigin,$providerSnapshot)
        $provider=Delivery-Ref $providerSnapshot
        $gitSnapshot=Join-Path $deliveryRoot 'git-original-bytes.bin';[IO.File]::Copy($gitExecutable,$gitSnapshot)
        $merge=New-DeliveryFixtureOriginal $deliveryRoot 'merge' @($providerOrigin,'pr','merge','7','--repo','Example/ported-source','--merge','--match-head-commit',$port.candidate) $port.repo '' 4
        $checks=New-DeliveryFixtureOriginal $deliveryRoot 'required-checks' @($providerOrigin,'pr','checks','7','--repo','Example/ported-source','--required','--json','name,state,link') $port.repo '[{"name":"source-check","state":"SUCCESS","link":"https://example.invalid/MODELED"}]' 5
        $prText=[ordered]@{number=7;state='closed';merged=$true;merged_at='2026-10-21T01:04:01Z';merge_commit_sha=$published.final;head=[ordered]@{sha=$port.candidate;repo=[ordered]@{full_name='Example/ported-source'}};base=[ordered]@{ref='main';repo=[ordered]@{full_name='Example/ported-source'}}}|ConvertTo-Json -Depth 10
        $pr=New-DeliveryFixtureOriginal $deliveryRoot 'pr-readback' @($providerOrigin,'api','--method','GET','repos/Example/ported-source/pulls/7') $port.repo $prText 6
        $lr=[ordered]@{schema='rusty.morphospace.workflow.source_delivery_disposition.v1';kind='landing-request';disposition=Delivery-Ref $disposition.path;source_checks=@($check);source_review=Delivery-Ref $review;provider=$provider;provider_invocation_path=$providerOrigin;source_git=Delivery-Ref $gitSnapshot;source_git_invocation_path=$gitExecutable;source_before_original=$pre;source_after_original=$post;pull_request_number=7;pull_request_original=$pr;required_checks_original=$checks;merge_original=$merge}
        $lp=Join-Path $deliveryRoot 'landing-request.json';Write-Json $lp $lr
        $landing=New-MorphospaceSourceDeliveryLanding -RequestPath $lp -ExpectedRequestSha256 (Delivery-Hash $lp) -RepoMapPath $publicationMap -OutPath (Join-Path $deliveryRoot 'landing.json')
        Assert-Builder (Test-MorphospaceSourceDeliveryLanding -LandingPath $landing.path -ExpectedLandingSha256 $landing.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map) 'Earlier landing read failed.'
        Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $before) 'Landing observation/consumption changed the consumer.'
        $integrationPublished=New-DeliveryIntegrationPublishedParent
        $originalCheck=[IO.File]::ReadAllBytes($check.path)
        foreach($damage in @('nonzero','no-eof','not-reaped','string-flag','nested-string-flag','string-count','string-exit','false-byte-count','reversed-time')) {
            $bad=Copy-Document (Read-EnvelopeProtocolJson $check.path)
            switch($damage){'nonzero'{$bad.exit_code=1};'no-eof'{$bad.genuine_full_eof=$false};'not-reaped'{$bad.process_reaped=$false};'string-flag'{$bad.process_reaped='true'};'nested-string-flag'{$bad.streams.stdout.eof='true'};'string-count'{$bad.streams.stdout.stored_bytes='0'};'string-exit'{$bad.exit_code='0'};'reversed-time'{$bad.finished_utc='2026-10-21T00:00:00Z'};'false-byte-count'{$bad.stdout.bytes=1;$bad.streams.stdout.raw.bytes=1;$bad.streams.stdout.drained_bytes=1;$bad.streams.stdout.stored_bytes=1}}
            Write-Json $check.path $bad;$badRequest=Copy-Document $lr;$badRequest.source_checks=@(Delivery-Ref $check.path)
            $badPath=Join-Path $deliveryRoot "$damage-request.json";Write-Json $badPath $badRequest
            $pattern=if($damage -ceq 'false-byte-count'){'*Evidence length*'}else{'*Original*'}
            Assert-Rejected {New-MorphospaceSourceDeliveryLanding -RequestPath $badPath -ExpectedRequestSha256 (Delivery-Hash $badPath) -RepoMapPath $publicationMap -OutPath (Join-Path $deliveryRoot "$damage-landing.json")} $pattern "coherently rebound $damage original"
            [IO.File]::WriteAllBytes($check.path,$originalCheck)
        }
        $failedChecks=New-DeliveryFixtureOriginal $deliveryRoot 'failed-required-checks' @($providerOrigin,'pr','checks','7','--repo','Example/ported-source','--required','--json','name,state,link') $port.repo '[{"name":"source-check","state":"FAILURE","link":"https://example.invalid/MODELED"}]' 5
        $failedRequest=Copy-Document $lr;$failedRequest.required_checks_original=$failedChecks;$failedPath=Join-Path $deliveryRoot 'failed-ci-request.json';Write-Json $failedPath $failedRequest
        Assert-Rejected {New-MorphospaceSourceDeliveryLanding -RequestPath $failedPath -ExpectedRequestSha256 (Delivery-Hash $failedPath) -RepoMapPath $publicationMap -OutPath (Join-Path $deliveryRoot 'failed-ci-landing.json')} '*required checks*' 'failed provider-required CI'
        $originalUnit=[IO.File]::ReadAllBytes($unitPath);$detached=Copy-Document $u;$detached.objective='Detached authority change.';Write-Json $unitPath $detached
        Assert-Rejected {Test-MorphospaceSourceDeliveryLanding -LandingPath $landing.path -ExpectedLandingSha256 $landing.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map} '*target unit projection*' 'uncommitted consumer contract'
        [IO.File]::WriteAllBytes($unitPath,$originalUnit)
        $originalMap=[IO.File]::ReadAllBytes($publicationMap);[IO.File]::AppendAllText($publicationMap," `n",$encoding)
        Assert-Rejected {Test-MorphospaceSourceDeliveryLanding -LandingPath $landing.path -ExpectedLandingSha256 $landing.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map} '*Evidence bytes changed*' 'publication map raw drift'
        [IO.File]::WriteAllBytes($publicationMap,$originalMap)
        $completion=Read-EnvelopeProtocolJson $check.path;$completion.process_reaped=$false;Write-Json $check.path $completion
        Assert-Rejected {Test-MorphospaceSourceDeliveryLanding -LandingPath $landing.path -ExpectedLandingSha256 $landing.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map} '*Evidence bytes changed*' 'late original mutation'
        [IO.File]::WriteAllBytes($check.path,$originalCheck)
        # Consuming an earlier landing does not require a new delta or the
        # publication checkout to remain at the qualified pre-merge HEAD.
        Invoke-FixtureGit $port.repo @('checkout','--detach',$published.final)|Out-Null
        [IO.File]::WriteAllText($providerOrigin,'MODELED later installed provider changed; original bytes remain retained.',$encoding)
        Assert-Builder (Test-MorphospaceSourceDeliveryLanding -LandingPath $landing.path -ExpectedLandingSha256 $landing.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map) 'Already-landed source incorrectly required a second publication delta.'
        $workflowLog=Join-Path $deliveryRoot 'consumer-workflow.log'
        $workflowOutput=@(& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -WorkspaceRoot $ws -RepositoryMapPath $map -CurrentWorkOnly -SkipOwnerSelfTests 2>&1|ForEach-Object{[string]$_})
        Assert-Builder ($LASTEXITCODE -eq 0) "Consumer workflow predicate failed: $($workflowOutput -join ' ')"
        [IO.File]::WriteAllText($workflowLog,($workflowOutput -join "`n"),$encoding)
        $inspect=Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard
        [IO.File]::Copy($landing.path,(Join-Path $ws 'receipts/delivery-landing.json'));[IO.File]::Copy($workflowLog,(Join-Path $ws 'receipts/delivery-workflow.log'))
        $evidence=[ordered]@{receipt_id='delivery-consumer-validation';tier='standard';result='pass';artifacts=@([ordered]@{artifact_id='earlier-source';kind='source-delivery-landing';path='delivery-landing.json'},[ordered]@{artifact_id='workflow';kind='test-log';path='delivery-workflow.log'});criteria=@($u.acceptance|ForEach-Object{[ordered]@{acceptance_id=$_.acceptance_id;status='pass';command=$_.command;evidence_refs=@('earlier-source','workflow')}});gates=@($inspect.validation_matrix|Where-Object disposition -CNE forbidden|ForEach-Object{[ordered]@{gate_id=$_.gate_id;status='pass';command=$_.command;evidence_refs=@('workflow')}});device_validation=$null}
        $receiptOwner=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1') -PassThru
        foreach($damage in @('false-same-source','package-scope','package-locked','dependency-hash','package-raw')) {
            $evilRequest=Copy-Document $request;$packageBytes=[IO.File]::ReadAllBytes($package)
            switch($damage) {
                'false-same-source'{$evilRequest.relationship.kind='same-source'}
                'dependency-hash'{$evilRequest.ordering_supersession.prior_dependency_refs[0].value_sha256='0'*64}
                'package-raw'{[IO.File]::AppendAllText($package," `n",$encoding)}
                default{$evilPackage=Copy-Document (Read-EnvelopeProtocolJson $package);if($damage -ceq 'package-scope'){$evilPackage.repositories[0].allowed_paths=@('unrelated.txt')}else{$evilPackage.guard_profile='locked';$evilPackage.change_categories=@('workflow-automation')};$ep=Join-Path $deliveryRoot "$damage-package.json";Write-Json $ep $evilPackage;$evilRequest.source_package=Delivery-Ref $ep}
            }
            $er=Join-Path $deliveryRoot "$damage-request.json";Write-Json $er $evilRequest
            $evilDisposition=Copy-Document $disposition.document;$evilDisposition.request=$evilRequest;$evilDisposition.request_reference=Delivery-Ref $er
            $ed=Join-Path $deliveryRoot "$damage-disposition.json";Write-Json $ed $evilDisposition
            $evilLandingRequest=Copy-Document $lr;$evilLandingRequest.disposition=Delivery-Ref $ed
            $elr=Join-Path $deliveryRoot "$damage-landing-request.json";Write-Json $elr $evilLandingRequest
            $evilLanding=Copy-Document $landing.document;$evilLanding.request=$evilLandingRequest;$evilLanding.request_reference=Delivery-Ref $elr
            $el=Join-Path $deliveryRoot "$damage-landing.json";Write-Json $el $evilLanding
            $evilEvidence=Copy-Document $evidence;$evilEvidence.receipt_id="rebound-$damage";$evilEvidence.artifacts[0].path=$el
            $evilReceipt=Join-Path $ws "receipts/rebound-$damage.json"
            & $receiptOwner { param($w,$m,$e,$o) New-MorphospaceValidationReceiptV1 -WorkspaceRoot $w -UnitId u002 -RepoMapPath $m -Evidence $e -OutPath $o -CreatedAt '2026-10-21T02:00:00.0000000Z' } $ws $map $evilEvidence $evilReceipt|Out-Null
            $preRefusal=Get-EnvelopeWorkspaceByteInventorySha256 $ws
            Assert-Rejected {Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard -ValidationResult pass -ValidationReceipt "receipts/rebound-$damage.json" -Timestamp '2026-10-21T02:01:00.0000000Z' -Execute} '*Source delivery:*' "coherently rebound $damage at actual receipt hook"
            Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $preRefusal) 'Refused source artifact changed owner state or issued an intent.'
            [IO.File]::WriteAllBytes($package,$packageBytes)
        }
        $duplicate=Join-Path $deliveryRoot 'duplicate.txt';[IO.File]::WriteAllText($duplicate,'one',$encoding);$first=Delivery-Ref $duplicate
        $observation=&$module {New-SourceDeliveryObservation};[void](&$module {param($r,$o) Read-SourceDeliveryReference $r $o -Bytes} $first $observation)
        [IO.File]::WriteAllText($duplicate,'two',$encoding);$second=Delivery-Ref $duplicate
        Assert-Rejected {&$module {param($r,$o) Read-SourceDeliveryReference $r $o -Bytes} $second $observation} '*rebound during*' 'same-locator observation rebinding'
        $receiptPath=Join-Path $ws 'receipts/delivery-consumer-validation.json'
        & $receiptOwner { param($w,$m,$e,$o) New-MorphospaceValidationReceiptV1 -WorkspaceRoot $w -UnitId u002 -RepoMapPath $m -Evidence $e -OutPath $o -CreatedAt '2026-10-21T02:00:00.0000000Z' } $ws $map $evidence $receiptPath|Out-Null
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard -ValidationResult pass -ValidationReceipt 'receipts/delivery-consumer-validation.json' -Timestamp '2026-10-21T02:01:00.0000000Z' -Execute|Out-Null
        Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard -ValidationReceipt 'receipts/delivery-consumer-validation.json' -Timestamp '2026-10-21T02:02:00.0000000Z' -Execute|Out-Null
        Assert-Builder (Test-MorphospaceSourceDeliveryLanding -LandingPath $landing.path -ExpectedLandingSha256 $landing.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map) 'Accepted continuation lost the earlier source binding.'
        $fresh=@(& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -WorkspaceRoot $ws -RepositoryMapPath $map -CurrentWorkOnly -SkipOwnerSelfTests 2>&1|ForEach-Object{[string]$_})
        Assert-Builder ($LASTEXITCODE -eq 0) "Fresh accepted continuation failed: $($fresh -join ' ')"
        # A locked source owner has earned its own acceptance. It needs neither
        # a downstream adoption pass nor a planning-role/Git-layout fiction.
        $acceptedState=Read-EnvelopeProtocolJson $statePath;$acceptedUnit=Read-EnvelopeProtocolJson $unitPath
        $ownerMap=Join-Path $deliveryRoot 'accepted-publication-map.json';Write-Json $ownerMap ([ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='project-shell';path=$source;role='source'})})
        $acceptedHuman=Join-Path $deliveryRoot 'accepted-human.txt';[IO.File]::WriteAllText($acceptedHuman,'MODELED explicit accepted source-owner source-only disposition; no product adoption or planning publication.',$encoding)
        $acceptedReview=Join-Path $deliveryRoot 'accepted-source-review.txt';[IO.File]::WriteAllText($acceptedReview,'MODELED exact accepted owner source commit/tree, not a port or downstream adoption.',$encoding)
        $acceptedRequest=Copy-Document $request
        $acceptedRequest.consumer=[pscustomobject][ordered]@{boundary_kind='accepted-source-owner';workspace_root=$ws;project_id='envelope-test';unit_id='u002';accept_event_id=$acceptedState.last_event_id;accept_receipt=Delivery-Ref $receiptPath;unit_raw_sha256=Delivery-Hash $unitPath;state_raw_sha256=Delivery-Hash $statePath;events_raw_sha256=Delivery-Hash $eventsPath;repository_map=Delivery-Ref $map}
        $acceptedRequest.publication_subject.base_commit=$seed.source_commit;$acceptedRequest.publication_subject.base_tree=$seed.source_tree;$acceptedRequest.publication_subject.candidate_commit=$request.source_reference.commit;$acceptedRequest.publication_subject.candidate_tree=$request.source_reference.tree;$acceptedRequest.publication_subject.allowed_paths=@('morphospace/README.md');$acceptedRequest.publication_map=Delivery-Ref $ownerMap
        $acceptedRequest.relationship.kind='same-source';$acceptedRequest.relationship.review=Delivery-Ref $acceptedReview;$acceptedRequest.source_package=$null;$acceptedRequest.ordering_supersession.scope='accepted-source-owner-source-only';$acceptedRequest.ordering_supersession.human_decision=Delivery-Ref $acceptedHuman;$acceptedRequest.ordering_supersession.prior_dependency_refs=@()
        $acceptedRequest.source_check_commands=@(,@($gitExecutable,'-C',$source,'diff','--check',"$($seed.source_commit)..$($request.source_reference.commit)"))
        $arp=Join-Path $deliveryRoot 'accepted-request.json';Write-Json $arp $acceptedRequest
        $acceptedArgs=@{RequestPath=$arp;ExpectedRequestSha256=Delivery-Hash $arp;WorkspaceRoot=$ws;RepoMapPath=$ownerMap;HumanDecisionPath=$acceptedHuman;ExpectedHumanDecisionSha256=Delivery-Hash $acceptedHuman}
        $ownerBefore=Get-EnvelopeWorkspaceByteInventorySha256 $ws
        $acceptedDisposition=New-MorphospaceSourceDeliveryDisposition @acceptedArgs -OutPath (Join-Path $deliveryRoot 'accepted-disposition.json')
        Assert-Builder (-not $acceptedDisposition.document.source_landed -and -not $acceptedDisposition.document.acceptance_credit -and $acceptedUnit.guard_profile -ceq 'locked') 'Accepted source owner was downgraded or granted landed/adoption credit.'
        Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $ownerBefore) 'Accepted source disposition changed its owner.'
        $copiedMap=Join-Path $deliveryRoot 'copied-consumer-map.json';[IO.File]::Copy($map,$copiedMap)
        foreach($damage in @('accept-event','receipt-hash','source-head','source-path','fast-relabel','original-map')) {
            $badOwner=Copy-Document $acceptedRequest
            switch($damage){'accept-event'{$badOwner.consumer.accept_event_id='u002-accepted-9999'};'receipt-hash'{$badOwner.consumer.accept_receipt.sha256='0'*64};'source-head'{$badOwner.source_reference.commit=$seed.source_commit};'source-path'{$badOwner.publication_subject.allowed_paths=@('outside.txt')};'fast-relabel'{$badOwner.source_package=Delivery-Ref $package};'original-map'{$badOwner.consumer.repository_map=Delivery-Ref $copiedMap}}
            $bp=Join-Path $deliveryRoot "accepted-$damage-request.json";Write-Json $bp $badOwner;$badOwnerArgs=$acceptedArgs.Clone();$badOwnerArgs.RequestPath=$bp;$badOwnerArgs.ExpectedRequestSha256=Delivery-Hash $bp
            Assert-Rejected {New-MorphospaceSourceDeliveryDisposition @badOwnerArgs -OutPath (Join-Path $deliveryRoot "accepted-$damage-disposition.json")} '*' "accepted owner $damage"
            Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $ownerBefore) 'Refused accepted source disposition changed owner history.'
        }
        # The accepted-owner variant observes its own subject qualification and
        # normal merge. No provider or source-check result transfers from the port.
        $ownerBare=Join-Path $deliveryRoot 'accepted-owner-remote.git'
        Invoke-FixtureGit $source @('init','--bare','--initial-branch=main',$ownerBare)|Out-Null
        Invoke-FixtureGit $source @('remote','add','origin',$ownerBare)|Out-Null
        Invoke-FixtureGit $source @('push','origin',"$($seed.source_commit):refs/heads/main")|Out-Null
        $ownerStatusArgs=@($gitExecutable,'--no-optional-locks','--no-pager','--no-replace-objects','-C',$source,'status','--porcelain=v2','--branch','--untracked-files=all')
        $ownerStatus=(Invoke-FixtureGit $source @('status','--porcelain=v2','--branch','--untracked-files=all')) -join "`n"
        $ownerPre=New-DeliveryFixtureOriginal $deliveryRoot 'accepted-source-before' $ownerStatusArgs $source $ownerStatus 11
        Invoke-FixtureGit $source @('diff','--check',"$($seed.source_commit)..$($request.source_reference.commit)")|Out-Null
        $ownerCheck=New-DeliveryFixtureOriginal $deliveryRoot 'accepted-source-check' $acceptedRequest.source_check_commands[0] $source '' 12
        $ownerPost=New-DeliveryFixtureOriginal $deliveryRoot 'accepted-source-after' $ownerStatusArgs $source $ownerStatus 13
        $ownerSubject=[pscustomobject]@{id='accepted-owner';repo=$source;remote=$ownerBare;candidate=$request.source_reference.commit}
        $ownerPublished=Publish-SyntheticProviderMerge $ownerSubject $deliveryRoot
        [IO.File]::Copy($providerSnapshot,$providerOrigin,$true)
        $ownerMerge=New-DeliveryFixtureOriginal $deliveryRoot 'accepted-merge' @($providerOrigin,'pr','merge','8','--repo','Example/ported-source','--merge','--match-head-commit',$ownerSubject.candidate) $source '' 14
        $ownerChecks=New-DeliveryFixtureOriginal $deliveryRoot 'accepted-required-checks' @($providerOrigin,'pr','checks','8','--repo','Example/ported-source','--required','--json','name,state,link') $source '[{"name":"accepted-source-check","state":"SUCCESS","link":"https://example.invalid/MODELED-accepted"}]' 15
        $ownerPrDocument=[ordered]@{number=8;state='closed';merged=$true;merged_at='2026-10-21T01:14:01Z';merge_commit_sha=$ownerPublished.final;head=[ordered]@{sha=$ownerSubject.candidate;repo=[ordered]@{full_name='Example/ported-source'}};base=[ordered]@{ref='main';repo=[ordered]@{full_name='Example/ported-source'}}}
        $ownerPr=New-DeliveryFixtureOriginal $deliveryRoot 'accepted-pr-readback' @($providerOrigin,'api','--method','GET','repos/Example/ported-source/pulls/8') $source ($ownerPrDocument|ConvertTo-Json -Depth 10) 16
        $ownerLandingRequest=Copy-Document $lr;$ownerLandingRequest.disposition=Delivery-Ref $acceptedDisposition.path;$ownerLandingRequest.source_checks=@($ownerCheck);$ownerLandingRequest.source_review=Delivery-Ref $acceptedReview;$ownerLandingRequest.source_before_original=$ownerPre;$ownerLandingRequest.source_after_original=$ownerPost;$ownerLandingRequest.pull_request_number=8;$ownerLandingRequest.pull_request_original=$ownerPr;$ownerLandingRequest.required_checks_original=$ownerChecks;$ownerLandingRequest.merge_original=$ownerMerge
        $olp=Join-Path $deliveryRoot 'accepted-landing-request.json';Write-Json $olp $ownerLandingRequest
        $ownerLanding=New-MorphospaceSourceDeliveryLanding -RequestPath $olp -ExpectedRequestSha256 (Delivery-Hash $olp) -RepoMapPath $ownerMap -OutPath (Join-Path $deliveryRoot 'accepted-landing.json')
        # Rebind all outer raw references coherently: the original frozen map
        # must still be authenticated on the retained consumer path itself.
        $mapRequest=Copy-Document $acceptedRequest;$mapRequest.consumer.repository_map=Delivery-Ref $copiedMap
        $mrp=Join-Path $deliveryRoot 'rebound-owner-map-request.json';Write-Json $mrp $mapRequest
        $mapDisposition=Copy-Document $acceptedDisposition.document;$mapDisposition.request=$mapRequest;$mapDisposition.request_reference=Delivery-Ref $mrp
        $mdp=Join-Path $deliveryRoot 'rebound-owner-map-disposition.json';Write-Json $mdp $mapDisposition
        $mapLandingRequest=Copy-Document $ownerLandingRequest;$mapLandingRequest.disposition=Delivery-Ref $mdp
        $mlrp=Join-Path $deliveryRoot 'rebound-owner-map-landing-request.json';Write-Json $mlrp $mapLandingRequest
        $mapLanding=Copy-Document $ownerLanding.document;$mapLanding.request=$mapLandingRequest;$mapLanding.request_reference=Delivery-Ref $mlrp
        $mlp=Join-Path $deliveryRoot 'rebound-owner-map-landing.json';Write-Json $mlp $mapLanding
        Assert-Rejected {Test-MorphospaceSourceDeliveryLanding -LandingPath $mlp -ExpectedLandingSha256 (Delivery-Hash $mlp) -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map} '*original repository map*' 'coherently rebound accepted owner map'
        Invoke-FixtureGit $source @('checkout','--detach',$ownerPublished.final)|Out-Null
        Assert-Builder (Test-MorphospaceSourceDeliveryLanding -LandingPath $ownerLanding.path -ExpectedLandingSha256 $ownerLanding.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map) 'Accepted-owner earlier landing failed retained verification.'
        Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $ownerBefore) 'Accepted-owner landing observation/readback changed owner history.'
        $integrationLanding=Invoke-DeliveryAcceptedIntegrationControls $integrationPublished
        # Advance the disposable accepted owner through an existing, committed
        # evidence-relocation action. Historical landing readback must retain
        # the original Accept identity, without a caller-authored fake event.
        Invoke-FixtureGit $ws @('init')|Out-Null
        [IO.File]::WriteAllText((Join-Path $ws '.gitignore'),"local/`n",$encoding)
        $relocationModule=Import-Module (Join-Path $PSScriptRoot 'AcceptedValidationEvidenceRelocation.psm1') -PassThru
        $localEvidence=Join-Path $ws 'local/accepted-source-evidence';[IO.Directory]::CreateDirectory($localEvidence)|Out-Null
        foreach($name in @('delivery-landing.json','delivery-workflow.log')){[IO.File]::Copy((Join-Path $ws "receipts/$name"),(Join-Path $localEvidence $name))}
        $relocation=New-MorphospaceAcceptedEvidenceRelocationInput -WorkspaceRoot $ws -UnitId u002 -LocalDirectory 'local/accepted-source-evidence' -CreatedAt '2026-10-21T03:00:00.0000000Z' -OutPath (Join-Path $deliveryRoot 'accepted-relocation.json')
        Invoke-MorphospaceRelocateAcceptedValidationEvidence -WorkspaceRoot $ws -RelocationInput $relocation.path -ExpectedInputSha256 $relocation.sha256 -OutPath (Join-Path $ws "receipts/$($relocation.relocation_id).json") -Execute|Out-Null
        Assert-Builder ((Read-EnvelopeProtocolJson $statePath).last_event_id -cne $acceptedRequest.consumer.accept_event_id) 'Fixture did not earn a later committed owner tail.'
        Assert-Builder (Test-MorphospaceSourceDeliveryLanding -LandingPath $ownerLanding.path -ExpectedLandingSha256 $ownerLanding.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map) 'Later committed owner tail lost retained acceptance/source authority.'
        Assert-Builder (Test-MorphospaceSourceDeliveryLanding -LandingPath $integrationLanding.path -ExpectedLandingSha256 $integrationLanding.sha256 -WorkspaceRoot $ws -UnitId u002 -RepositoryMap $map) 'Later committed tail lost reviewed integration authority.'
        $historyBefore=Get-EnvelopeWorkspaceByteInventorySha256 $ws
        Assert-Rejected {New-MorphospaceSourceDeliveryDisposition @acceptedArgs -OutPath (Join-Path $deliveryRoot 'stale-accepted-disposition.json')} '*current acceptance tail*' 'stale accepted-owner creation'
        Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $historyBefore) 'Stale accepted-owner creation changed history.'
        'Source delivery controls passed: real prepared owner Freeze/Begin; separate port map/source; zero-credit disposition; actual temp Git merge; MODELED finite provider originals; retained earlier landing; no consumer writes; false-equivalence, coherently rebound nonzero/noEOF/not-reaped/string flags, failed required CI, detached consumer, map drift and late-stream drift refusal.'
    } finally {
        &$module {param($g,$r) Set-Item Function:script:Get-SourceOnlyInputGitValue $g;Set-Item Function:script:Get-SourceOnlyInputRemoteReadback $r;Remove-Variable deliverySavedGit,deliveryBare -Scope Script -ErrorAction SilentlyContinue} $savedGit $savedRemote
        $full=[IO.Path]::GetFullPath($deliveryRoot);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if([IO.Path]::GetDirectoryName($full).Equals($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full).StartsWith('source-delivery-contract-',[StringComparison]::Ordinal)){if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}}else{throw 'Unsafe delivery fixture cleanup root.'}
    }
}

function New-DeliveryActiveReceiptExtension {
    param([string]$Workspace,[string]$RequestPath)
    $project=Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json');$lock=Read-EnvelopeProtocolJson (Join-Path $Workspace 'feature.lock.json');$state=Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json');$unit=Read-EnvelopeProtocolJson (Join-Path $Workspace 'iteration-units/u002.json')
    $sourcePath=Join-Path $Workspace ([string]$unit.source_composition.lock_path);$source=Read-EnvelopeProtocolJson $sourcePath;$mapPath=Join-Path $Workspace 'repository-map.json';$root='delivery-extra/'
    $targetProject=Copy-Envelope $project;$targetProject.revision=[int]$project.revision+1
    @($targetProject.repositories|Where-Object repo_id -CEQ 'project-shell')[0].allowed_paths+=,$root
    $targetLock=Copy-Envelope $lock;$targetLock.project_revision=$targetProject.revision;$targetLock.revision=[int]$lock.revision+1;$targetLock.generated_at=[DateTime]::UtcNow.ToString('o');$targetLock.lock_fingerprint='0'*64;$targetLock.lock_fingerprint=Get-EnvelopeCanonicalJsonSha256 $targetLock
    $targetState=Copy-Envelope $state;$targetState.plan_revision=[int]$state.plan_revision+1;$targetState.last_event_id='delivery-native-add-root-recorded';$targetState.module_registry.lock_revision=$targetLock.revision;$targetState.module_registry.lock_fingerprint=$targetLock.lock_fingerprint
    $assessment=Copy-Envelope $unit.agent_scope_assessment;@($assessment.owner_repositories|Where-Object repo_id -CEQ 'project-shell')[0].source_roots+=,$root
    $allowed=@(Copy-Envelope @($unit.allowed_repositories));@($allowed|Where-Object repo_id -CEQ 'project-shell')[0].allowed_paths+=,$root
    $effects=[ordered]@{};foreach($axis in @('permissions','services','activities','queries','tools','assets','shaders','native_libraries','commands','routes','streams','inputs','scenes','markers')){$effects[$axis]=@()}
    $request=[ordered]@{
        schema='rusty.morphospace.workflow.active_development_envelope_extension.v1';extension_id='delivery-native-add-root';project_id='envelope-test';unit_id='u002';rationale='The unchanged fixture documentation objective needs one additional exact documentation root.'
        ownership_proof=@([ordered]@{repo_id='project-shell';source_roots=@($root);owner='project-shell';evidence='The existing documentation owner reviewed this exact new root for the unchanged objective.'})
        additions=[ordered]@{repository_ids=@();owner_roots=@([ordered]@{repo_id='project-shell';source_roots=@($root)});feature_ids=@();module_ids=@();authority_parameters=@();effects=$effects;permissions=@();validation_profile_ids=@();acceptance_profile_ids=@();build_profile_ids=@();device_kinds=@()}
        before=[ordered]@{project=$project;feature_lock=$lock;state=$state;agent_scope_assessment=$unit.agent_scope_assessment;allowed_repositories=@($unit.allowed_repositories);read_only_dependencies=@($unit.read_only_dependencies)}
        target=[ordered]@{project=$targetProject;feature_lock=$targetLock;state=$targetState;agent_scope_assessment=$assessment;allowed_repositories=@($allowed);read_only_dependencies=@($unit.read_only_dependencies)}
        source_composition=[ordered]@{path='source-composition-locks/delivery-native-add-root.json';repository_ids=@($source.repositories.repo_id)}
        effective_repository_map=[ordered]@{path='repository-map.json';raw_sha256=Get-EnvelopeFileSha256 $mapPath}
        expected=[ordered]@{status='active';current_unit='u002';project_revision=[int]$project.revision;feature_lock_revision=[int]$lock.revision;plan_revision=[int]$state.plan_revision;project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;project_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'project.spec.json');feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $lock;feature_lock_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'feature.lock.json');state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;state_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'workspace.state.json');unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;unit_raw_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'iteration-units/u002.json');events_sha256=Get-EnvelopeFileSha256 (Join-Path $Workspace 'iteration-events.jsonl');events_length=([IO.FileInfo](Join-Path $Workspace 'iteration-events.jsonl')).Length;event_tail_id=$state.last_event_id;source_composition_path=$unit.source_composition.lock_path;source_composition_raw_sha256=Get-EnvelopeFileSha256 $sourcePath;source_composition_canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $source;repository_map_path='repository-map.json';repository_map_raw_sha256=Get-EnvelopeFileSha256 $mapPath;original_source_composition_path=$unit.source_composition.lock_path;original_source_composition_raw_sha256=Get-EnvelopeFileSha256 $sourcePath;original_repository_map_path='repository-map.json';original_repository_map_raw_sha256=Get-EnvelopeFileSha256 $mapPath}
        does_not_prove=@('Temporary owner scope extension only; no validation, acceptance, publication or device credit.')
    }
    Write-EnvelopeJson $RequestPath $request
    [pscustomobject]@{request=$request;request_path=$RequestPath;map_path=$mapPath;receipt_path=(Join-Path $Workspace 'receipts/delivery-native-add-root.json');source_path=(Join-Path $Workspace 'source-composition-locks/delivery-native-add-root.json')}
}

function Invoke-ActiveEnvelopeReceiptControls {
    $fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('source-delivery-active-receipt-'+[guid]::NewGuid().ToString('N'))
    $ledgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
    $protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
    Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1')
    Import-Module (Join-Path $PSScriptRoot 'ActiveDevelopmentEnvelopeExtension.psm1')
    Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1')
    . (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')
    function Invoke-EnvelopeGit([string]$Path,[string[]]$Arguments){Invoke-FixtureGit $Path $Arguments}
    try {
        $seed=New-EnvelopeAdmissionPreparedFixture -Root $fixtureRoot -RepositoryRoot (Split-Path $PSScriptRoot -Parent) -TransitionLedgerModule $ledgerModule -OwnerProducedPreparation
        $seed.admission_template.unit|Add-Member -NotePropertyName guard_profile -NotePropertyValue locked -Force
        $ws=$seed.workspace;$source=$seed.source_repository;$map=Join-Path $ws 'repository-map.json';$admit=Join-Path $fixtureRoot 'admit.json';Write-Json $admit $seed.admission_template
        Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $ws -DevelopmentUnitAdmission $admit -ExpectedDevelopmentUnitAdmissionSha256 (Delivery-Hash $admit) -OutPath (Join-Path $ws 'receipts/u002-admission.json') -Execute|Out-Null
        foreach($action in @('Ready','Claim')){Invoke-MorphospaceWorkUnitAutomation -Action $action -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard -Execute|Out-Null}
        $originalBaseline=Git-Value $source @('rev-parse','HEAD')
        [IO.File]::AppendAllText((Join-Path $source 'morphospace/README.md'),"before genuine extension`n",$encoding);Invoke-FixtureGit $source @('add','morphospace/README.md')|Out-Null;Invoke-FixtureGit $source @('commit','-m','before extension')|Out-Null
        $extensionHead=Git-Value $source @('rev-parse','HEAD');Assert-Builder ($extensionHead-cne$originalBaseline) 'Fixture did not create a distinct before-extension head.'
        $extension=New-DeliveryActiveReceiptExtension $ws (Join-Path $fixtureRoot 'extension.json')
        Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $ws -UnitId u002 -ActiveDevelopmentEnvelopeExtension $extension.request_path -ExpectedActiveDevelopmentEnvelopeExtensionSha256 (Delivery-Hash $extension.request_path) -RepositoryMapPath $map -OutPath $extension.receipt_path -SourceCompositionOutPath $extension.source_path -Execute|Out-Null
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'delivery-extra'));[IO.File]::WriteAllText((Join-Path $source 'delivery-extra/README.md'),"after genuine extension`n",$encoding);Invoke-FixtureGit $source @('add','delivery-extra/README.md')|Out-Null;Invoke-FixtureGit $source @('commit','-m','after extension')|Out-Null
        $unit=Read-EnvelopeProtocolJson (Join-Path $ws 'iteration-units/u002.json');$state=Read-EnvelopeProtocolJson (Join-Path $ws 'workspace.state.json');$project=Read-EnvelopeProtocolJson (Join-Path $ws 'project.spec.json');$lock=Read-EnvelopeProtocolJson (Join-Path $ws 'feature.lock.json');$events=Join-Path $ws 'iteration-events.jsonl';$head=Git-Value $source @('rev-parse','HEAD')
        $freeze=[ordered]@{schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id='delivery-active-native';project_id='envelope-test';unit_id='u002';expected=[ordered]@{project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $lock;source_composition_path=$unit.source_composition.lock_path;source_composition_sha256=Delivery-Hash $extension.source_path;repository_map_path='repository-map.json';repository_map_sha256=Delivery-Hash $map;events_sha256=Delivery-Hash $events;events_length=([IO.FileInfo]$events).Length;event_tail_id=$state.last_event_id};final_repositories=@([ordered]@{repo_id='project-shell';commit=$head;tree=Git-Value $source @('rev-parse','HEAD^{tree}')});changed_paths=@([ordered]@{repo_id='project-shell';paths=@('morphospace/','delivery-extra/')});cleanliness_policy='clean-only';instruction_surfaces=@([ordered]@{path='morphospace/README.md';disposition='reviewed-no-change'});feature_lock=[ordered]@{revision=$lock.revision;sha256=Get-EnvelopeCanonicalJsonSha256 $lock};effects=@($unit.agent_scope_assessment.allowed_effect_categories);permissions=@($unit.agent_scope_assessment.allowed_permission_categories);device_use=@('none');test_matrix=@([ordered]@{test_id='source';command='Fixture source predicate.'});cleanup_evidence=@('Real temporary active-extension owner; modeled source predicate only.');source_composition=[ordered]@{path=$unit.source_composition.lock_path;sha256=Delivery-Hash $extension.source_path};does_not_prove=@('No product, actual provider CI or adoption credit.')}
        $freezePath=Join-Path $fixtureRoot 'freeze.json';Write-Json $freezePath $freeze
        Invoke-MorphospaceFreezeCandidate -WorkspaceRoot $ws -UnitId u002 -CandidateFreeze $freezePath -ExpectedCandidateFreezeSha256 (Delivery-Hash $freezePath) -OutPath (Join-Path $ws 'receipts/delivery-active-native.json') -Execute|Out-Null
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard -Execute|Out-Null
        $unit=Read-EnvelopeProtocolJson (Join-Path $ws 'iteration-units/u002.json');$inspect=Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard
        $log=Join-Path $ws 'receipts/modeled-source-predicate.log';[IO.File]::WriteAllText($log,'MODELED fixture source predicate; no real CI/product proof.',$encoding)
        $evidence=[ordered]@{receipt_id='delivery-active-native-pass';tier='standard';result='pass';artifacts=@([ordered]@{artifact_id='source';kind='test-log';path='modeled-source-predicate.log'});criteria=@($unit.acceptance|ForEach-Object{[ordered]@{acceptance_id=$_.acceptance_id;status='pass';command=$_.command;evidence_refs=@('source')}});gates=@($inspect.validation_matrix|Where-Object disposition -CNE forbidden|ForEach-Object{[ordered]@{gate_id=$_.gate_id;status='pass';command=$_.command;evidence_refs=@('source')}});device_validation=$null}
        $evidencePath=Join-Path $fixtureRoot 'evidence.json';Write-Json $evidencePath $evidence;$receiptPath=Join-Path $ws 'receipts/delivery-active-native-pass.json'
        foreach($damage in @('source-raw','source-baseline','physical-map','extension-authority')) {
            $damagedPath=switch($damage){'physical-map'{$map};'extension-authority'{$extension.receipt_path};default{$extension.source_path}}
            $originalBytes=[IO.File]::ReadAllBytes($damagedPath)
            try {
                if($damage -ceq 'source-baseline'){$bad=Read-EnvelopeProtocolJson $damagedPath;$bad.repositories[0].baseline_commit=$extensionHead;Write-Json $damagedPath $bad}
                else{[IO.File]::AppendAllText($damagedPath," `n",$encoding)}
                $beforeRefusal=Get-EnvelopeWorkspaceByteInventorySha256 $ws;$refusedPath=Join-Path $ws "receipts/refused-$damage.json"
                $refused=@(& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'New-ValidationReceipt.ps1') -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -EvidencePath $evidencePath -OutPath $refusedPath 2>&1|ForEach-Object{[string]$_})
                $reason=if($damage -ceq 'extension-authority'){'*Transition ledger committed artifact differs from its intent*'}else{'*candidate-freeze binding*'}
                Assert-Builder ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $refusedPath) -and ($refused -join ' ') -like $reason) "Active producer refusal for $damage did not reach its independently expected guard (exit=$LASTEXITCODE): $($refused -join ' ')"
                Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $beforeRefusal) 'Refused active receipt producer changed its owner.'
            } finally {[IO.File]::WriteAllBytes($damagedPath,$originalBytes)}
        }
        $activeReceiptModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1') -PassThru
        $receiptGit=&$activeReceiptModule {${function:Invoke-MorphospaceValidationReceiptGit}}
        $eventBytes=[IO.File]::ReadAllBytes($events);$beforeLate=Get-EnvelopeWorkspaceByteInventorySha256 $ws
        try {
            &$activeReceiptModule {param($original,$path) $script:deliveryOriginalReceiptGit=$original;$script:deliveryLedgerDrift=$path
                function script:Invoke-MorphospaceValidationReceiptGit {param($Repository,$Arguments,[switch]$AllowFailure)
                    if(($Arguments -join '|') -ceq 'rev-parse|HEAD' -and $null -ne $script:deliveryLedgerDrift){[IO.File]::AppendAllText($script:deliveryLedgerDrift,"`n",[Text.UTF8Encoding]::new($false));$script:deliveryLedgerDrift=$null}
                    &$script:deliveryOriginalReceiptGit $Repository $Arguments -AllowFailure:$AllowFailure
                }
            } $receiptGit $events
            Assert-Rejected {New-MorphospaceValidationReceiptV1 -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -Evidence $evidence -OutPath (Join-Path $ws 'receipts/refused-late-ledger.json')} '*changed*' 'late ledger drift'
            Assert-Builder (-not (Test-Path -LiteralPath (Join-Path $ws 'receipts/refused-late-ledger.json'))) 'Late ledger drift wrote a receipt.'
        } finally {
            &$activeReceiptModule {param($original) Set-Item Function:script:Invoke-MorphospaceValidationReceiptGit $original;Remove-Variable deliveryOriginalReceiptGit,deliveryLedgerDrift -Scope Script -ErrorAction SilentlyContinue} $receiptGit
            [IO.File]::WriteAllBytes($events,$eventBytes)
        }
        Assert-Builder ((Get-EnvelopeWorkspaceByteInventorySha256 $ws) -ceq $beforeLate) 'Late-refusal control changed owner data beyond its restored injected ledger bytes.'
        $orderScript=Join-Path $fixtureRoot 'receipt-import-order.ps1'
        [IO.File]::WriteAllText($orderScript,@'
param($Root,$Workspace,$Map,$EvidencePath,$OutPath,$Order)
$ErrorActionPreference='Stop'
$receipt=Join-Path $Root 'scripts/lib/MorphospaceValidationReceipt.psm1'
$provenance=Join-Path $Root 'scripts/DevelopmentEnvelopeProvenance.psm1'
if($Order -eq 'receipt-first'){Import-Module $receipt -DisableNameChecking;Import-Module $provenance -DisableNameChecking}else{Import-Module $provenance -DisableNameChecking;Import-Module $receipt -DisableNameChecking}
$evidence=Get-Content -LiteralPath $EvidencePath -Raw|ConvertFrom-Json -Depth 100 -DateKind String
New-MorphospaceValidationReceiptV1 -WorkspaceRoot $Workspace -UnitId u002 -RepoMapPath $Map -Evidence $evidence -OutPath $OutPath|Out-Null
'@,$encoding)
        foreach($order in @('receipt-first','provenance-first')) {
            & pwsh -NoProfile -File $orderScript -Root (Split-Path $PSScriptRoot -Parent) -Workspace $ws -Map $map -EvidencePath $evidencePath -OutPath (Join-Path $ws "receipts/import-$order.json") -Order $order
            Assert-Builder ($LASTEXITCODE -eq 0) "Active producer failed import order $order."
        }
        Write-Host 'ACTIVE RECEIPT causal seam: genuine Extend, Freeze and Begin complete; invoking public native producer.'
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'New-ValidationReceipt.ps1') -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -EvidencePath $evidencePath -OutPath $receiptPath
        Assert-Builder ($LASTEXITCODE-eq0-and(Test-Path -LiteralPath $receiptPath)) 'Public active-envelope native receipt producer failed after genuine owning extension.'
        $receipt=Read-EnvelopeProtocolJson $receiptPath;$revision=@($receipt.repository_revisions|Where-Object repo_id -CEQ 'project-shell')
        Assert-Builder ($revision.Count-eq1-and$revision[0].base_revision-ceq$originalBaseline-and$revision[0].head_revision-ceq$head-and$revision[0].base_revision-cne$extensionHead) 'Native receipt replaced original baseline with effective extension head.'
        $actualPaths=@($receipt.changed_paths|Where-Object repo_id -CEQ 'project-shell'|ForEach-Object path|Sort-Object)
        Assert-Builder (($actualPaths-join'|')-ceq'delivery-extra/README.md|morphospace/README.md') 'Native receipt omitted pre-extension or post-extension source changes.'
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard -ValidationResult pass -ValidationReceipt 'receipts/delivery-active-native-pass.json' -Execute|Out-Null
        Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $ws -UnitId u002 -RepoMapPath $map -ValidationTier standard -Execute|Out-Null
        Assert-Builder ((Read-EnvelopeProtocolJson (Join-Path $ws 'iteration-units/u002.json')).status-ceq'accepted') 'Real temporary active-envelope receipt did not reach acceptance.'
        Write-Host 'Active-envelope native receipt controls passed: real extension and public producer/Record/Accept, literal original baseline and both source intervals.'
    } finally {
        $full=[IO.Path]::GetFullPath($fixtureRoot);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if([IO.Path]::GetDirectoryName($full).Equals($parent,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full).StartsWith('source-delivery-active-receipt-',[StringComparison]::Ordinal)){if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}}else{throw 'Unsafe active receipt fixture cleanup root.'}
    }
}


function Invoke-ReviewedIntegrationNativeControls {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('source-integration-native-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $nativeControlsPassed=$false
    try {
        $repo=Join-Path $root 'source';[IO.Directory]::CreateDirectory($repo)|Out-Null
        Invoke-FixtureGit $repo @('init','--initial-branch=main')|Out-Null
        Invoke-FixtureGit $repo @('config','user.email','fixture@example.invalid')|Out-Null;Invoke-FixtureGit $repo @('config','user.name','Fixture')|Out-Null
        $overlapPaths=@('scripts/SourceOnlyPublicationInputs.psm1','scripts/lib/MorphospaceValidationReceipt.psm1','scripts/ActiveUnitRetirement.psm1')
        foreach($name in $overlapPaths){[IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $repo $name)))|Out-Null;[IO.File]::WriteAllText((Join-Path $repo $name),"anchor0`nline1=base`nanchor2`nanchor3`nline4=base`nanchor5`n",$encoding)}
        Invoke-FixtureGit $repo @('add','.')|Out-Null;Invoke-FixtureGit $repo @('commit','-m','base')|Out-Null;$base=Git-Value $repo @('rev-parse','HEAD')
        foreach($name in $overlapPaths){[IO.File]::WriteAllText((Join-Path $repo $name),"anchor0`nline1=accepted`nanchor2`nanchor3`nline4=base`nanchor5`n",$encoding)}
        Invoke-FixtureGit $repo @('commit','-am','accepted')|Out-Null;$accepted=Git-Value $repo @('rev-parse','HEAD')
        Invoke-FixtureGit $repo @('checkout','-b','published',$base)|Out-Null
        foreach($name in $overlapPaths){[IO.File]::WriteAllText((Join-Path $repo $name),"anchor0`nline1=base`nanchor2`nanchor3`nline4=published`nanchor5`n",$encoding)}
        Invoke-FixtureGit $repo @('commit','-am','published')|Out-Null;$published=Git-Value $repo @('rev-parse','HEAD')
        $before=Git-Value $repo @('rev-parse','HEAD');$beforeStatus=@(Invoke-FixtureGit $repo @('status','--porcelain=v1','--untracked-files=all')) -join "`n"
        $result=&$module {
            param($r,$s,$p,$o)
            $savedCopy=${function:Start-SourceDeliveryIntegrationCopy}
            try {
                foreach($fault in @('copy-start','copy-completion')) {
                    $script:integrationCopyFault=$fault;$script:integrationCopyCalls=0
                    function script:Start-SourceDeliveryIntegrationCopy([IO.Stream]$Source,[IO.Stream]$Destination) {
                        $script:integrationCopyCalls++
                        if($script:integrationCopyCalls -eq 1) {
                            if($script:integrationCopyFault -ceq 'copy-start'){throw 'Literal injected first-copy start failure.'}
                            return [Threading.Tasks.Task]::FromException([IO.IOException]::new('Literal injected first-copy completion failure.'))
                        }
                        if($script:integrationCopyCalls -eq 3){throw 'Literal injected fallback-copy start failure.'}
                        return $Source.CopyToAsync($Destination)
                    }
                    $faultOut=Join-Path (Split-Path -Parent $o) $fault
                    $refused=$false
                    try {Invoke-SourceDeliveryIntegrationComputation -Root $r -Accepted $s -Published $p -OutputDirectory $faultOut|Out-Null} catch {$refused=$true}
                    if(-not $refused){throw 'Faulted stream observation returned a computation result.'}
                    $diagnostic=Join-Path $faultOut '001-Version/native.json'
                    if(-not [IO.File]::Exists($diagnostic)){throw 'Issued native child has no retained settled diagnostic after fallback-copy failure.'}
                    $record=Read-MorphospaceProtocolJson $diagnostic
                    if($record.process_reaped -cne $true -or $record.exit_code -ne 0 -or $record.stdout_eof -cne $false -or $record.stderr_eof -cne $false -or @($record.observer_errors).Count -lt 2 -or ($record.observer_errors -join '|') -cnotlike '*Literal injected fallback-copy start failure*'){throw 'Faulted child diagnostic lost actual exit, refusal, partial-stream or settlement facts.'}
                }
            } finally {Set-Item Function:script:Start-SourceDeliveryIntegrationCopy $savedCopy;Remove-Variable integrationCopyFault,integrationCopyCalls -Scope Script -ErrorAction SilentlyContinue}
            Invoke-SourceDeliveryIntegrationComputation -Root $r -Accepted $s -Published $p -OutputDirectory $o
        } $repo $accepted $published (Join-Path $root 'clean-computation')
        Assert-Builder ($result.merge_base -ceq $base) 'Native integration did not use the real unique common ancestor.'
        foreach($name in $overlapPaths) {
            $actual=@($result.result_entries|Where-Object path -CEQ $name)[0].blob
            $literal=$encoding.GetBytes("anchor0`nline1=accepted`nanchor2`nanchor3`nline4=published`nanchor5`n");$header=$encoding.GetBytes("blob $($literal.Length)"+[char]0);$expected=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($header+$literal))).ToLowerInvariant();Assert-Builder ($actual -ceq $expected) 'Independent literal both-side content differs.'
        }
        Assert-Builder ((Git-Value $repo @('rev-parse','HEAD')) -ceq $before -and (@(Invoke-FixtureGit $repo @('status','--porcelain=v1','--untracked-files=all')) -join "`n") -ceq $beforeStatus) 'Computation changed its source.'
        $marker=Join-Path $root 'MUST-NOT-RUN.txt';$infoAttributes=Join-Path $repo '.git/info/attributes'
        Invoke-FixtureGit $repo @('config','merge.evil.driver',"cmd /c echo bad>$marker")|Out-Null
        [IO.File]::WriteAllText($infoAttributes,"*.psm1 merge=evil`n",$encoding)
        $isolated=&$module {param($r,$s,$p,$o) Invoke-SourceDeliveryIntegrationComputation -Root $r -Accepted $s -Published $p -OutputDirectory $o} $repo $accepted $published (Join-Path $root 'source-driver-isolated')
        Assert-Builder ($isolated.result_tree -ceq $result.result_tree -and -not (Test-Path -LiteralPath $marker)) 'Source merge driver/info attributes escaped the isolated computation.'
        [IO.File]::WriteAllText($infoAttributes,"*.psm1 filter=evil`n",$encoding)
        Invoke-FixtureGit $repo @('config','filter.evil.clean',"cmd /c echo bad>$marker")|Out-Null
        $file=Join-Path $repo 'scripts/SourceOnlyPublicationInputs.psm1';$raw=[IO.File]::ReadAllBytes($file)
        [IO.File]::WriteAllText($file,"dirty tracked input`n",$encoding)
        Assert-Rejected {&$module {param($r,$s,$p,$o) Invoke-SourceDeliveryIntegrationComputation -Root $r -Accepted $s -Published $p -OutputDirectory $o} $repo $accepted $published (Join-Path $root 'dirty-filter-refusal')} '*dirty*' 'dirty source with hostile clean filter'
        Assert-Builder (-not (Test-Path -LiteralPath $marker)) 'Safe source observation ran a clean driver.'
        [IO.File]::WriteAllBytes($file,$raw);[IO.File]::Delete($infoAttributes)
        Invoke-FixtureGit $repo @('config','--unset','filter.evil.clean')|Out-Null;Invoke-FixtureGit $repo @('config','--unset','merge.evil.driver')|Out-Null
        $oldAttrSource=[Environment]::GetEnvironmentVariable('GIT_ATTR_SOURCE');$oldAttrSourcePresent=Test-Path Env:GIT_ATTR_SOURCE
        try {
            [Environment]::SetEnvironmentVariable('GIT_ATTR_SOURCE',$base)
            Assert-Rejected {&$module {param($r,$s,$p,$o) Invoke-SourceDeliveryIntegrationComputation -Root $r -Accepted $s -Published $p -OutputDirectory $o} $repo $accepted $published (Join-Path $root 'ambient-attribute-refusal')} '*Ambient GIT_ATTR_SOURCE*' 'ambient source-observation selector'
            Assert-Builder (-not (Test-Path -LiteralPath (Join-Path $root 'ambient-attribute-refusal'))) 'Ambient selector refusal wrote output.'
        } finally {if($oldAttrSourcePresent){[Environment]::SetEnvironmentVariable('GIT_ATTR_SOURCE',$oldAttrSource)}else{Remove-Item Env:GIT_ATTR_SOURCE -ErrorAction SilentlyContinue}}
        foreach($damage in @('conflict','mode','deletion','attribute-addition','multiple-bases','add-add')) {
            Invoke-FixtureGit $repo @('checkout','-B',"damage-$damage",$base)|Out-Null
            $badAccepted=$accepted
            switch($damage) {
                'conflict' {[IO.File]::WriteAllText($file,"anchor0`nline1=conflicting-published`nanchor2`nanchor3`nline4=base`nanchor5`n",$encoding);Invoke-FixtureGit $repo @('add','.')|Out-Null}
                'mode' {Invoke-FixtureGit $repo @('update-index','--chmod=+x','scripts/SourceOnlyPublicationInputs.psm1')|Out-Null}
                'deletion' {Invoke-FixtureGit $repo @('rm','scripts/SourceOnlyPublicationInputs.psm1')|Out-Null}
                'attribute-addition' {[IO.File]::WriteAllText((Join-Path $repo '.gitattributes'),"*.psm1 merge=union`n",$encoding);Invoke-FixtureGit $repo @('add','.')|Out-Null}
                'multiple-bases' {
                    $baseTree=Git-Value $repo @('rev-parse',"$base^{tree}")
                    $one=Git-Value $repo @('commit-tree',$baseTree,'-p',$accepted,'-p',$published,'-m','criss-one');$two=Git-Value $repo @('commit-tree',$baseTree,'-p',$published,'-p',$accepted,'-m','criss-two')
                    $badAccepted=Git-Value $repo @('commit-tree',$baseTree,'-p',$one,'-m','child-one');$badPublished=Git-Value $repo @('commit-tree',$baseTree,'-p',$two,'-m','child-two')
                }
                'add-add' {
                    [IO.File]::WriteAllText((Join-Path $repo 'extra.txt'),"accepted addition`n",$encoding);Invoke-FixtureGit $repo @('add','.')|Out-Null;Invoke-FixtureGit $repo @('commit','-m','accepted-add')|Out-Null;$badAccepted=Git-Value $repo @('rev-parse','HEAD')
                    Invoke-FixtureGit $repo @('checkout','-B','damage-addadd-published',$base)|Out-Null;[IO.File]::WriteAllText((Join-Path $repo 'extra.txt'),"published addition`n",$encoding);Invoke-FixtureGit $repo @('add','.')|Out-Null;Invoke-FixtureGit $repo @('commit','-m','published-add')|Out-Null;$badPublished=Git-Value $repo @('rev-parse','HEAD')
                }
            }
            if($damage -cnotin @('multiple-bases','add-add')){Invoke-FixtureGit $repo @('commit','-m',$damage)|Out-Null;$badPublished=Git-Value $repo @('rev-parse','HEAD')}
            $pattern=switch($damage){'conflict'{'*conflicting*'};'attribute-addition'{'*attribute inventory*'};'multiple-bases'{'*unique merge base*'};'add-add'{'*add/add*'};default{'*deletion, rename or mode*'}}
            Assert-Rejected {&$module {param($r,$s,$p,$o) Invoke-SourceDeliveryIntegrationComputation -Root $r -Accepted $s -Published $p -OutputDirectory $o} $repo $badAccepted $badPublished (Join-Path $root "refused-$damage")} $pattern $damage
            if($damage -ceq 'conflict') {
                $native=Read-MorphospaceProtocolJson (Join-Path $root 'refused-conflict/012-Merge/native.json')
                Assert-Builder ($native.exit_code -eq 1 -and [IO.File]::ReadAllText($native.stdout.path) -cmatch '^[0-9a-f]{40}' -and [IO.File]::ReadAllBytes($native.stderr.path).Length -eq 0) 'Conflict control did not retain its actual nonzero/tree-prefix/empty-stderr distinction.'
            }
        }
        $nativeControlsPassed=$true
        'Reviewed integration native controls passed: three real overlaps/literal both-side blobs; unique base; source driver isolation; dirty clean-filter/ambient selector no-write refusals; conflict with tree-prefix/empty-stderr, mode, deletion and attribute-inventory refusal.'
    } finally {
        $full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if([IO.Path]::GetDirectoryName($full).Equals($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full).StartsWith('source-integration-native-',[StringComparison]::Ordinal)){if($nativeControlsPassed){Remove-Item -LiteralPath $full -Recurse -Force}else{Write-Host "Failed native control retained at $full"}}else{throw 'Unsafe native fixture cleanup.'}
    }
}

if ($ReviewedIntegrationNativeOnly) { Invoke-ReviewedIntegrationNativeControls; return }
if ($ReviewedIntegrationOnly) { Invoke-DeliveryContractControls; return }
if ($ActiveEnvelopeReceiptOnly) { Invoke-ActiveEnvelopeReceiptControls; return }
Invoke-FixedSourcePathControls
if ($FixedSourcePathOnly) { return }
if ($DispositionOnly) { Invoke-ReviewedIntegrationNativeControls; Invoke-ActiveEnvelopeReceiptControls; Invoke-DeliveryContractControls; return }
Invoke-ReviewedIntegrationNativeControls
Invoke-ActiveEnvelopeReceiptControls
Invoke-DeliveryContractControls
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1') -Force

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('source-only-input-builders-' + [guid]::NewGuid().ToString('N'))
try {
    $f = New-RehearsalFixture $testRoot
    $retiredPath = Join-Path $f.workspace 'iteration-units/retired-unit.json'; $retiredHash = Get-MorphospaceFileSha256 $retiredPath
    $malformed = Copy-Document (Get-Content -Raw $f.receipt | ConvertFrom-Json -Depth 64 -DateKind String); $malformed.criteria[0].evidence_refs = 'validation-evidence'
    $malformedPath = Join-Path $f.workspace 'receipts\malformed-validation.json'; Write-Json $malformedPath $malformed
    Assert-Rejected { Assert-MorphospaceValidationReceiptStructure -ReceiptPath $malformedPath -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1' } '*does not satisfy*' 'malformed v1 singleton receipt'
    $beforeStateHash = Get-MorphospaceFileSha256 (Join-Path $f.workspace 'workspace.state.json')
    Assert-Rejected { Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -ValidationTier standard -ValidationResult pass -ValidationReceipt 'receipts/malformed-validation.json' -Timestamp '2026-09-08T09:02:00.0000000Z' -Execute } '*does not satisfy*' 'malformed receipt at first workflow write boundary'
    Assert-Builder ((Get-MorphospaceFileSha256 (Join-Path $f.workspace 'workspace.state.json')) -ceq $beforeStateHash) 'Malformed receipt changed workflow state.'
    Remove-Item -LiteralPath $malformedPath
    Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -ValidationTier standard -ValidationResult pass -ValidationReceipt 'receipts/snapshot-unit-pass-validation.json' -Timestamp '2026-09-08T09:02:00.0000000Z' -Execute | Out-Null
    Assert-CurrentWork $f 'builder-backed validation recording'
    Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -Timestamp '2026-09-08T09:03:00.0000000Z' -Execute | Out-Null
    Assert-CurrentWork $f 'builder-backed acceptance'
    Invoke-FixtureGit $f.planning @('add', 'morphospace') | Out-Null; Invoke-FixtureGit $f.planning @('commit', '-m', 'accept snapshot') | Out-Null

    $publicationId = 'synthetic-source-publication'; $readinessPath = Join-Path $f.inputs 'readiness.json'
    $readiness = Get-MorphospaceSourceOnlyPublicationReadiness -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -PublicationId $publicationId -OutPath $readinessPath
    Assert-Builder ([string]$readiness.document.status -ceq 'supported') "Readiness did not support the neutral snapshot: $(@($readiness.document.reason_codes) -join ', ')."
    Assert-Builder (@($readiness.document.source_repositories).Count -eq 2) 'Readiness included a read-only dependency or non-project skill support map as a publication row.'
    $missingMap = Get-Content -Raw $f.map | ConvertFrom-Json -Depth 64 -DateKind String
    $missingMap.repositories = @($missingMap.repositories | Where-Object { $_.repo_id -cne 'consumer-source' })
    $missingMapPath = Join-Path $f.inputs 'missing-source-map.json'; Write-Json $missingMapPath $missingMap
    $missingReadiness = Get-MorphospaceSourceOnlyPublicationReadiness -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $missingMapPath -PublicationId $publicationId
    Assert-Builder ($missingReadiness.status -ceq 'unsupported' -and @($missingReadiness.reason_codes) -ccontains 'allowed-source-shape-unsupported:consumer-source') 'Missing project source was not rejected by readiness.'
    $readinessRaw = Get-Content -Raw $readinessPath
    foreach ($forbidden in @($f.provider.repo, $f.consumer.repo, 'SYNTHETIC-CONTENT-ONE', 'SYNTHETIC-CONTENT-TWO')) { Assert-Builder (-not $readinessRaw.Contains($forbidden)) 'Readiness leaked a local source path or payload.' }

    $noDeltaRoot = Join-Path $testRoot 'no-delta'; [IO.Directory]::CreateDirectory($noDeltaRoot) | Out-Null
    $candidateBytes = [IO.File]::ReadAllBytes((Join-Path $f.provider.repo 'provider.txt'))
    Invoke-FixtureGit $f.provider.repo @('push', 'origin', 'HEAD:main') | Out-Null
    $noDelta = Get-MorphospaceSourceOnlyPublicationReadiness -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -PublicationId 'unsupported-source-publication'
    Assert-Builder ([string]$noDelta.status -ceq 'unsupported' -and @($noDelta.reason_codes) -contains 'no-publication-delta:provider-source') 'Readiness did not expose the unsupported no-delta source shape.'
    & $gitExecutable -C $f.provider.remote update-ref refs/heads/main $f.provider.old | Out-Null
    & $gitExecutable -C $f.provider.repo update-ref refs/remotes/origin/main $f.provider.old | Out-Null

    $planInput = Join-Path $f.inputs 'plan.json'
    $planResult = New-MorphospaceSourceOnlyPublicationPlan -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -PublicationId $publicationId -OutPath $planInput
    Assert-Builder (@($planResult.document.source_repositories | Where-Object { @($_.trigger_unit_paths).Count -ne 0 }).Count -eq 0) 'Validation-only empty write scope gained trigger paths.'
    Assert-Builder (@($planResult.document.source_repositories | Where-Object { @($_.carried_paths).Count -ne 1 }).Count -eq 0) 'Builder did not retain both carried source deltas.'
    $planRaw = Get-Content -Raw $planInput; Assert-Builder (-not $planRaw.Contains('SYNTHETIC-CONTENT-ONE') -and -not $planRaw.Contains('SYNTHETIC-CONTENT-TWO')) 'Plan embedded source payload bytes.'
    $supportPlan = Copy-Document $planResult.document; $supportPlan.source_repositories[1].repo_id = 'skill-surfaces'
    $supportPlanPath = Join-Path $f.inputs 'support-source-plan.json'; Write-Json $supportPlanPath $supportPlan
    Assert-Rejected { Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationPlan $supportPlanPath -ExpectedSourceOnlyPublicationPlanSha256 (Get-MorphospaceFileSha256 $supportPlanPath) -OutPath (Join-Path $f.workspace "receipts/$publicationId-plan.json") } '*source*' 'external support entry used as a publication target'
    $artifactPath = Join-Path $f.workspace 'receipts/validation-evidence.txt'; $artifactBytes = [IO.File]::ReadAllBytes($artifactPath)
    [IO.File]::WriteAllText($artifactPath, 'altered evidence', $encoding)
    Assert-Rejected { New-MorphospaceSourceOnlyPublicationPlan -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -PublicationId $publicationId -OutPath (Join-Path $f.inputs 'altered-evidence-plan.json') } '*planning-owner-dirty*' 'altered committed validation evidence'
    [IO.File]::WriteAllBytes($artifactPath, $artifactBytes)

    [IO.File]::WriteAllText((Join-Path $f.provider.repo 'provider.txt'), "drift after plan`n", $encoding)
    Assert-Rejected { Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationPlan $planInput -ExpectedSourceOnlyPublicationPlanSha256 $planResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-plan.json") -Timestamp '2026-09-08T09:59:00.0000000Z' } "*Source repository 'provider-source' is dirty*" 'source drift after plan'
    [IO.File]::WriteAllBytes((Join-Path $f.provider.repo 'provider.txt'), $candidateBytes)
    Assert-Builder (@(Invoke-FixtureGit $f.provider.repo @('status', '--porcelain=v1', '--untracked-files=all')).Count -eq 0) 'Synthetic source drift cleanup did not restore exact bytes.'

    Assert-Rejected { Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationPlan $planInput -ExpectedSourceOnlyPublicationPlanSha256 $planResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-plan.json") -Timestamp '2026-09-08T09:59:00.0000000Z' -FaultAfter after-artifact -Execute } 'Injected interruption after artifact installation.' 'interrupted preparation'
    Invoke-MorphospacePrepareSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationPlan $planInput -ExpectedSourceOnlyPublicationPlanSha256 $planResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-plan.json") -Timestamp '2026-09-08T09:59:00.0000000Z' -Execute | Out-Null
    Assert-CurrentWork $f 'builder-backed preparation recovery'
    $preparedPlan = Join-Path $f.workspace "receipts/$publicationId-plan.json"

    $providerStart = Start-MorphospaceSourceOnlyPublicationOperation -PlanPath $preparedPlan -RepoId 'provider-source' -Timestamp '2026-09-08T10:00:00.0000000Z' -OutPath (Join-Path $f.inputs 'provider-start.json')
    $providerPublished = Publish-SyntheticProviderMerge $f.provider $testRoot
    $providerEvidence = New-SyntheticOperationEvidence $providerStart $providerPublished '2026-09-08T10:00:05.0000000Z' (Join-Path $f.inputs 'provider-evidence.json')
    foreach ($damage in @('force','unknown-force','wrong-provider','wrong-start','missing-artifact')) {
        $damaged = Copy-Document $providerEvidence.document
        switch ($damage) {
            'force' { $damaged.outcome.force_used = $true }
            'unknown-force' { $damaged.outcome.force_used = $null }
            'wrong-provider' { $damaged.provider.repo_id = 'consumer-source' }
            'wrong-start' { $damaged.operation_start_sha256 = '0' * 64 }
            'missing-artifact' { $damaged.artifact.path = 'absent-operation.log' }
        }
        $damagedPath = Join-Path $f.inputs "$damage-evidence.json"; Write-Json $damagedPath $damaged
        Assert-Rejected { Complete-MorphospaceSourceOnlyPublicationOperationObservation -PlanPath $preparedPlan -OperationStartPath $providerStart.path -OperationEvidencePath $damagedPath -ExpectedOperationEvidenceSha256 (Get-MorphospaceFileSha256 $damagedPath) -RepoMapPath $f.map -Timestamp '2026-09-08T10:00:10.0000000Z' -OutPath (Join-Path $f.inputs "$damage-observation.json") } '*evidence*' "operation evidence $damage"
    }
    $providerObservation = Complete-MorphospaceSourceOnlyPublicationOperationObservation -PlanPath $preparedPlan -OperationStartPath $providerStart.path -OperationEvidencePath $providerEvidence.path -ExpectedOperationEvidenceSha256 $providerEvidence.sha256 -RepoMapPath $f.map -Timestamp '2026-09-08T10:00:10.0000000Z' -OutPath (Join-Path $f.inputs 'provider-observation.json')
    $consumerStart = Start-MorphospaceSourceOnlyPublicationOperation -PlanPath $preparedPlan -RepoId 'consumer-source' -Timestamp '2026-09-08T10:00:11.0000000Z' -OutPath (Join-Path $f.inputs 'consumer-start.json')
    $consumerPublished = Publish-SyntheticProviderMerge $f.consumer $testRoot
    $consumerEvidence = New-SyntheticOperationEvidence $consumerStart $consumerPublished '2026-09-08T10:00:15.0000000Z' (Join-Path $f.inputs 'consumer-evidence.json')
    $consumerObservation = Complete-MorphospaceSourceOnlyPublicationOperationObservation -PlanPath $preparedPlan -OperationStartPath $consumerStart.path -OperationEvidencePath $consumerEvidence.path -ExpectedOperationEvidenceSha256 $consumerEvidence.sha256 -RepoMapPath $f.map -Timestamp '2026-09-08T10:00:20.0000000Z' -OutPath (Join-Path $f.inputs 'consumer-observation.json')
    $executionInput = Join-Path $f.inputs 'execution.json'
    Assert-Rejected { New-MorphospaceSourceOnlyPublicationExecution -PlanPath $preparedPlan -OperationObservationPaths @($consumerObservation.path, $providerObservation.path) -RepoMapPath $f.map -OutPath (Join-Path $f.inputs 'reordered-execution.json') } '*ordinal*' 'reordered operation observations'
    $operationBytes = [IO.File]::ReadAllBytes($providerPublished.artifact)
    [IO.File]::WriteAllText($providerPublished.artifact, 'changed after observation', $encoding)
    Assert-Rejected { New-MorphospaceSourceOnlyPublicationExecution -PlanPath $preparedPlan -OperationObservationPaths @($providerObservation.path, $consumerObservation.path) -RepoMapPath $f.map -OutPath (Join-Path $f.inputs 'altered-operation-execution.json') } '*evidence*' 'operation evidence changed after observation'
    [IO.File]::WriteAllBytes($providerPublished.artifact, $operationBytes)
    $executionResult = New-MorphospaceSourceOnlyPublicationExecution -PlanPath $preparedPlan -OperationObservationPaths @($providerObservation.path, $consumerObservation.path) -RepoMapPath $f.map -OutPath $executionInput
    Assert-Builder (@($executionResult.document.source_repositories).Count -eq 2) 'Execution builder did not preserve the ordered source set.'

    Assert-Rejected { Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationExecution $executionInput -ExpectedSourceOnlyPublicationExecutionSha256 $executionResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-execution.json") -Timestamp '2026-09-08T10:01:00.0000000Z' -FaultAfter after-projection -Execute } 'Injected interruption after projections.' 'interrupted recording'
    Invoke-MorphospaceRecordSourceOnlyPublication -WorkspaceRoot $f.workspace -UnitId 'snapshot-unit' -RepoMapPath $f.map -SourceOnlyPublicationExecution $executionInput -ExpectedSourceOnlyPublicationExecutionSha256 $executionResult.sha256 -OutPath (Join-Path $f.workspace "receipts/$publicationId-execution.json") -Timestamp '2026-09-08T10:01:00.0000000Z' -Execute | Out-Null
    Assert-CurrentWork $f 'builder-backed recording recovery'
    Assert-Builder ((Get-MorphospaceFileSha256 $retiredPath) -ceq $retiredHash) 'Publication changed a preserved superseded unit.'
    'Source-only publication input builder self-test passed.'
} finally {
    $cleanupRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\','/'); $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if (-not [IO.Path]::GetDirectoryName($cleanupRoot).Equals($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($cleanupRoot).StartsWith('source-only-input-builders-',[StringComparison]::Ordinal)) { throw 'Fixture cleanup target is outside the direct temporary namespace.' }
    if (Test-Path -LiteralPath $cleanupRoot) { Remove-Item -LiteralPath $cleanupRoot -Recurse -Force }
}
