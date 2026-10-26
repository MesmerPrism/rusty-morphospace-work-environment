[CmdletBinding(DefaultParameterSetName='Compose')]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory,ParameterSetName='Compose')][ValidatePattern('^[0-9a-f]{40}$')][string]$BaseCommit,
    [Parameter(Mandatory,ParameterSetName='Compose')][ValidatePattern('^[0-9a-f]{40}$')][string]$HeadCommit,
    [Parameter(Mandatory,ParameterSetName='Compose')][string]$EvidenceDirectory,
    [Parameter(Mandatory,ParameterSetName='SelfTest')][switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$ownerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd([IO.Path]::DirectorySeparatorChar)
$comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not $root.Equals($ownerRoot,$comparison)) { throw 'Publication interface diagnostics must run from the selected source checkout itself.' }
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationCheckEvidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'test-support/IsolatedWorkflowSelfTest.psm1')

function Get-PublicationInterfaceSteps([object]$Registry) {
    $steps = [Collections.Generic.List[object]]::new()
    foreach ($spec in @(
        @{id='affected-validation-ownership';phase=''},
        @{id='affected-selector-graph-import-closure';phase='graph-import-closure'},
        @{id='affected-selector-dependency-closure';phase='dependency-closure'},
        @{id='affected-selector-trust-phase-artifact-contract';phase='trust-phase-artifact-contract'}
    )) {
        $matches = @($Registry.checks | Where-Object { [string]$_.check_id -ceq $spec.id })
        if ($matches.Count -ne 1) { throw "Publication interface requires one fixed registry check: $($spec.id)" }
        $check = $matches[0]
        [string[]]$arguments = @($check.arguments)
        if ($spec.phase -eq '') {
            if ($check.command_path -cne 'scripts/Test-AffectedValidationOwnership.ps1' -or ($arguments -join '|') -cne '-SelfTest') { throw 'Publication ownership registration changed its supported command/arguments.' }
            $command = [string]$check.command_path
        } else {
            if ($check.command_path -cne 'scripts/Invoke-AffectedValidationSelfTestPhase.ps1' -or $arguments.Count -ne 4 -or $arguments[0] -cne '-Phase' -or $arguments[1] -cne $spec.phase -or $arguments[2] -cne '-BudgetSeconds' -or $arguments[3] -cnotmatch '^[1-9][0-9]{0,2}$' -or [int]$arguments[3] -gt 600) { throw "Publication phase registration changed its supported command/arguments: $($spec.id)" }
            # The exact standalone child used by the managed CI phase, without
            # inventing its parent's projection, guard or publication evidence.
            $command = 'scripts/Test-AffectedValidation.ps1'
            $arguments = @('-SelfTestPhase',[string]$spec.phase)
        }
        $steps.Add([pscustomobject][ordered]@{id=[string]$spec.id;command_path=$command;arguments=$arguments;registered_command_path=[string]$check.command_path;registered_arguments=@($check.arguments)})
    }
    $steps.Insert(3,[pscustomobject][ordered]@{id='phase-binding-selftest';command_path='scripts/Invoke-AffectedValidationSelfTestPhase.ps1';arguments=@('-BindingSelfTest');registered_command_path='';registered_arguments=@()})
    return @($steps.ToArray())
}

function Write-PublicationInterfaceBytes([string]$Path,[byte[]]$Bytes) {
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    return [pscustomobject][ordered]@{path=[IO.Path]::GetFileName($Path);bytes=[long]$Bytes.Length;sha256=Get-MorphospaceAffectedCheckBytesSha256 -Bytes $Bytes}
}

function Write-PublicationInterfaceJson([string]$Path,[object]$Value) {
    return Write-PublicationInterfaceBytes -Path $Path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $Value)+"`n"))
}

function Invoke-PublicationInterfaceStep([object]$Step,[string]$Root,[string]$EvidenceRoot,[Collections.Generic.List[object]]$Observations) {
    $observation = [ordered]@{id=$Step.id;command_path=$Step.command_path;arguments=@($Step.arguments);registered_command_path=$Step.registered_command_path;registered_arguments=@($Step.registered_arguments);result='failed';stdout=$null;stderr=$null;failure_detail=$null}
    try {
        $result = Invoke-IsolatedWorkflowSelfTest -RepositoryRoot $Root -Path (Join-Path $Root $Step.command_path) -Arguments $Step.arguments -CompletionPreserving
        $observation.stdout = Write-PublicationInterfaceBytes -Path (Join-Path $EvidenceRoot ($Step.id+'.stdout.bin')) -Bytes $result.stdout
        $observation.stderr = Write-PublicationInterfaceBytes -Path (Join-Path $EvidenceRoot ($Step.id+'.stderr.bin')) -Bytes $result.stderr
        $observation.result = 'pass'
    } catch {
        # The shared launcher exposes decoded details on failure, not its
        # original failed-child byte arrays. Do not claim those are raw logs.
        $observation.failure_detail = Write-PublicationInterfaceBytes -Path (Join-Path $EvidenceRoot ($Step.id+'.failure.txt')) -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($_.ToString()))
        throw
    } finally { $Observations.Add([pscustomobject]$observation) }
}

if ($SelfTest) {
    function Assert-PublicationInterfaceRefusal([scriptblock]$Action,[string]$Pattern) {
        $refused = $false
        try { & $Action | Out-Null } catch { $refused = $_.Exception.Message -like $Pattern }
        if (-not $refused) { throw "Publication interface self-test did not observe refusal: $Pattern" }
    }
    $registry = Read-MorphospaceProtocolJson -Path (Join-Path $root 'manifests/affected-validation-registry.json')
    $steps = @(Get-PublicationInterfaceSteps -Registry $registry)
    if ($steps.Count -ne 5 -or @($steps | Where-Object { $_.arguments -contains '-BindingSelfTest' }).Count -ne 1) { throw 'Publication interface fixed standalone step set changed.' }
    $damage = $registry | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
    @($damage.checks | Where-Object check_id -CEQ 'affected-selector-graph-import-closure')[0].arguments = @('-Phase','executor-pass-schema','-BudgetSeconds','45')
    Assert-PublicationInterfaceRefusal { Get-PublicationInterfaceSteps $damage } '*phase registration changed*'

    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('publication-interface-parser-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'scripts'))
    try {
        $aggregatePath = Join-Path $fixture 'scripts/Test-WorkEnvironment.ps1'
        [IO.File]::WriteAllText((Join-Path $fixture 'scripts/Test-WorkUnitAutomation.ps1'),'# Parser fixture only; never executed.')
        $inventory = [pscustomobject]@{records=@([pscustomobject]@{path='scripts/Test-WorkUnitAutomation.ps1'})}
        $valid = @'
param([switch]$SelfTest)
if ($SelfTest) {
    $automationTest = [pscustomobject]@{name='automation:work-unit';script='Test-WorkUnitAutomation.ps1';arguments=@();detail='fixture'}
    $automationTestPath = Join-Path (Join-Path $RepoRoot 'scripts') $automationTest.script
    [void](Invoke-IsolatedWorkflowSelfTest -RepositoryRoot $RepoRoot -Path $automationTestPath -Arguments $automationTest.arguments -TimeoutSeconds 900)
}
'@
        [IO.File]::WriteAllText($aggregatePath,$valid)
        $audit = Assert-MorphospaceAffectedWorkEnvironmentLeafRegistration -Root $fixture -Registry $registry -Inventory $inventory
        if ($audit.owner_entrypoint_count -ne 1 -or $audit.owner_entrypoints[0] -cne 'scripts/Test-WorkUnitAutomation.ps1') { throw 'Actual aggregate ownership parser did not recognize the finite WUA data row.' }
        [IO.File]::WriteAllText($aggregatePath,"param([switch]`$SelfTest); if (`$SelfTest) { [void](Invoke-IsolatedWorkflowSelfTest -RepositoryRoot `$RepoRoot -Path (Join-Path `$RepoRoot 'scripts/Test-WorkUnitAutomation.ps1') -TimeoutSeconds 900) }")
        Assert-PublicationInterfaceRefusal { Assert-MorphospaceAffectedWorkEnvironmentLeafRegistration -Root $fixture -Registry $registry -Inventory $inventory } '*unclassified invocation form*'
        [IO.File]::WriteAllText($aggregatePath,$valid.Replace('arguments=@()','arguments=@(''-SelfTest'')'))
        Assert-PublicationInterfaceRefusal { Assert-MorphospaceAffectedWorkEnvironmentLeafRegistration -Root $fixture -Registry $registry -Inventory $inventory } '*invocation differs from its focused registration*'
        $selfTestHead = (& git -C $root rev-parse 'HEAD^{commit}').Trim()
        if ($LASTEXITCODE -ne 0 -or $selfTestHead -cnotmatch '^[0-9a-f]{40}$') { throw 'Publication interface self-test requires an exact Git HEAD.' }
        $actualInventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $root -Commit $selfTestHead
        [void](Assert-MorphospaceAffectedWorkEnvironmentLeafRegistration -Root $root -Registry $registry -Inventory $actualInventory)

        [IO.File]::WriteAllText((Join-Path $fixture 'scripts/StreamProbe.ps1'),"[Console]::Out.Write('success-bytes'); [Console]::Error.Write('diagnostic-bytes')")
        $captures = [Collections.Generic.List[object]]::new()
        $probe = [pscustomobject]@{id='success-probe';command_path='scripts/StreamProbe.ps1';arguments=@();registered_command_path='';registered_arguments=@()}
        Invoke-PublicationInterfaceStep -Step $probe -Root $fixture -EvidenceRoot $fixture -Observations $captures
        if ($captures.Count -ne 1 -or $captures[0].result -cne 'pass' -or [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $fixture $captures[0].stdout.path))) -cne 'success-bytes' -or [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $fixture $captures[0].stderr.path))) -cne 'diagnostic-bytes') { throw 'Publication interface step did not retain the actual successful child streams.' }
        [IO.File]::WriteAllText((Join-Path $fixture 'scripts/StreamProbe.ps1'),"[Console]::Out.Write('failed-out'); [Console]::Error.Write('failed-err'); exit 23")
        $probe.id = 'failure-probe'
        Assert-PublicationInterfaceRefusal { Invoke-PublicationInterfaceStep -Step $probe -Root $fixture -EvidenceRoot $fixture -Observations $captures } '*exit 23*failed-out*failed-err*'
        if ($captures.Count -ne 2 -or $captures[1].result -cne 'failed' -or $null -ne $captures[1].stdout -or $null -ne $captures[1].stderr -or $null -eq $captures[1].failure_detail) { throw 'Publication interface step misrepresented failed-child raw bytes or failure disposition.' }
    } finally {
        # Delete only this exact, newly created fixture, with no shell expansion.
        $expected = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetFileName($fixture))))
        if ([IO.Path]::GetFullPath($fixture) -cne $expected) { throw 'Publication interface fixture cleanup escaped its task directory.' }
        [IO.Directory]::Delete($fixture,$true)
    }
    Write-Host 'Publication interface self-test passed: actual finite-row parser, inline/argument damage, fixed phase routing and real child success/failure capture.'
    return
}

if (-not [OperatingSystem]::IsLinux()) { throw 'Publication interface composition requires a real Linux host; use -SelfTest for portable focused controls.' }
$runtime = (Get-Process -Id $PID).Path
$nestedRuntime = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
if ((Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $nestedRuntime -Algorithm SHA256).Hash) { throw 'Prepend this Linux PowerShell runtime to PATH for this invocation so nested pwsh uses the same executable bytes.' }
$evidenceRoot = [IO.Path]::GetFullPath($EvidenceDirectory)
if ($evidenceRoot.Equals($root,$comparison) -or $evidenceRoot.StartsWith($root+[IO.Path]::DirectorySeparatorChar,$comparison)) { throw 'Retain publication interface diagnostics outside the source checkout.' }
if ([IO.Directory]::Exists($evidenceRoot) -or [IO.File]::Exists($evidenceRoot)) { throw 'Publication interface evidence directory must be new.' }
[void][IO.Directory]::CreateDirectory($evidenceRoot)
$observations = [Collections.Generic.List[object]]::new()
$plan = $null; $inventory = $null; $paths = $null; $failure = $null; $sourceEvidence = $null
$claims = [pscustomobject][ordered]@{diagnostic_only=$true;ci_credit=$false;managed_candidate_execution=$false;acceptance_authority=$false;publication_authority=$false;native_execution_authority=$false}
try {
    $selector = [pscustomobject]@{id='canonical-selector';command_path='scripts/Resolve-AffectedValidation.ps1';arguments=@('-RepositoryRoot',$root,'-BaseCommit',$BaseCommit,'-HeadCommit',$HeadCommit,'-Tier','Quick','-OutPath',(Join-Path $evidenceRoot 'plan.json'));registered_command_path='';registered_arguments=@()}
    Invoke-PublicationInterfaceStep -Step $selector -Root $root -EvidenceRoot $evidenceRoot -Observations $observations
    $plan = Read-MorphospaceProtocolJson -Path (Join-Path $evidenceRoot 'plan.json')
    if (-not $plan.execution_permitted) { throw 'Canonical selector did not permit execution; retain its unchanged diagnostic plan.' }
    $registry = Read-MorphospaceProtocolJson -Path (Join-Path $root 'manifests/affected-validation-registry.json')
    $compiled = Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $root -SchemaPath (Join-Path $root 'schemas/affected-validation-registry-v1.schema.json')
    $steps = @(Get-PublicationInterfaceSteps $registry)
    $inventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $root -Commit $HeadCommit
    if (-not $inventory.by_path.ContainsKey('scripts/Test-AffectedPublicationInterfaces.ps1')) { throw 'Publication interface runner must be committed in the selected exact head.' }
    $paths = @($inventory.records | Where-Object { @('100644','100755') -ccontains [string]$_.mode } | ForEach-Object { [string]$_.path })
    [void](Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $root -ExpectedHead $plan.head -Inventory $inventory -Paths $paths)
    $checkIds = @($steps | Where-Object { $_.id -cne 'phase-binding-selftest' } | ForEach-Object { $_.id })
    $checks = @($registry.checks | Where-Object { $checkIds -ccontains [string]$_.check_id })
    $closures = Get-MorphospaceAffectedCheckDependencyClosures -Checks $checks -CompiledRegistry $compiled -Inventory $inventory -RepositoryRoot $root
    $sourceEvidence = Write-PublicationInterfaceJson -Path (Join-Path $evidenceRoot 'source-manifests.json') -Value ([pscustomobject][ordered]@{base=$plan.base;head=$plan.head;runner=Get-MorphospaceAffectedCheckRunnerBinding;source_artifacts=@($inventory.records);runner_source_manifest=@(Get-MorphospaceAffectedCheckRunnerSourceManifest -Inventory $inventory);check_dependency_closures=$closures;claims=$claims})
    foreach ($step in $steps) {
        Invoke-PublicationInterfaceStep -Step $step -Root $root -EvidenceRoot $evidenceRoot -Observations $observations
    }
} catch { $failure = $_ }
if ($null -ne $inventory -and $null -ne $plan -and $null -ne $paths) {
    try { [void](Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $root -ExpectedHead $plan.head -Inventory $inventory -Paths $paths) } catch { $failure = $_ }
}
$report = [pscustomobject][ordered]@{
    diagnostic='affected-publication-interfaces-v1';base_commit=$BaseCommit;head_commit=$HeadCommit
    result=$(if($null -eq $failure){'pass'}else{'failed'});runner=Get-MorphospaceAffectedCheckRunnerBinding
    plan_sha256=$(if($null -ne $plan){$plan.plan_sha256}else{$null});source_manifests=$sourceEvidence;steps=@($observations.ToArray())
    failure=$(if($null -ne $failure){$failure.ToString()}else{$null})
    limits=@('Standalone production children and fixture binding/artifact readers only; no managed candidate projection publisher, guarded launch, leaf snapshot/cache publication, required CI or merge.','Successful child stdout/stderr are raw bytes. Shared-launcher failures retain decoded details only; outer command capture is not the original failed-child streams.','Quick selector escalation and full selected check set remain in the unchanged plan; this command does not execute that full set.');claims=$claims
}
[void](Write-PublicationInterfaceJson -Path (Join-Path $evidenceRoot 'diagnostic.json') -Value $report)
if ($null -ne $failure) { throw $failure }
Write-Host 'Publication interface diagnostic composition passed on this exact Linux candidate; no CI, lifecycle or publication credit.'
