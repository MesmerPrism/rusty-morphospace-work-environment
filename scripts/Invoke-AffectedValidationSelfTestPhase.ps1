[CmdletBinding(DefaultParameterSetName='Phase')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Phase')]
    [ValidateSet('graph-import-closure','dependency-closure','executor-pass-schema','executor-native-failure-damage','executor-native-exit125-damage','executor-forged-terminal-damage','executor-parent-containment-damage','executor-descendant-containment-damage','executor-output-ceiling-damage','executor-timeout-damage','executor-dual-stream-damage','executor-source-integrity-damage','executor-publication-collision-damage','selection-scenarios','trust-self-executor','trust-routing-contracts','trust-proportional-mappings','trust-damage-final')]
    [string]$Phase,
    [Parameter(Mandatory=$true,ParameterSetName='Phase')][ValidateRange(1,600)][int]$BudgetSeconds,
    [Parameter(Mandatory=$true,ParameterSetName='Verify')][switch]$Verify,
    [Parameter(Mandatory=$true,ParameterSetName='BindingSelfTest')][switch]$BindingSelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force

$phaseIds = @('graph-import-closure','dependency-closure','executor-pass-schema','executor-native-failure-damage','executor-native-exit125-damage','executor-forged-terminal-damage','executor-parent-containment-damage','executor-descendant-containment-damage','executor-output-ceiling-damage','executor-timeout-damage','executor-dual-stream-damage','executor-source-integrity-damage','executor-publication-collision-damage','selection-scenarios','trust-self-executor','trust-routing-contracts','trust-proportional-mappings','trust-damage-final')
$checkIds = [ordered]@{
    'graph-import-closure'='affected-selector-graph-import-closure'
    'dependency-closure'='affected-selector-dependency-closure'
    'executor-pass-schema'='affected-selector-executor-pass-schema'
    'executor-native-failure-damage'='affected-selector-executor-native-failure-damage'
    'executor-native-exit125-damage'='affected-selector-executor-native-exit125-damage'
    'executor-forged-terminal-damage'='affected-selector-executor-forged-terminal-damage'
    'executor-parent-containment-damage'='affected-selector-executor-parent-containment-damage'
    'executor-descendant-containment-damage'='affected-selector-executor-descendant-containment-damage'
    'executor-output-ceiling-damage'='affected-selector-executor-output-ceiling-damage'
    'executor-timeout-damage'='affected-selector-executor-timeout-damage'
    'executor-dual-stream-damage'='affected-selector-executor-dual-stream-damage'
    'executor-source-integrity-damage'='affected-selector-executor-source-integrity-damage'
    'executor-publication-collision-damage'='affected-selector-executor-publication-collision-damage'
    'selection-scenarios'='affected-selector-selection-scenarios'
    'trust-self-executor'='affected-selector-trust-self-executor'
    'trust-routing-contracts'='affected-selector-trust-routing-contracts'
    'trust-proportional-mappings'='affected-selector-trust-proportional-mappings'
    'trust-damage-final'='affected-selector-trust-damage-final'
}
function Get-RequiredEnvironment([string]$Name,[string]$Pattern) {
    $value = [Environment]::GetEnvironmentVariable($Name,'Process')
    if ([string]::IsNullOrWhiteSpace($value) -or $value -cnotmatch $Pattern) { throw "Affected phase runner requires canonical environment '$Name'." }
    return $value
}
function Get-Sha256([byte[]]$Bytes) { ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant() }
function Get-FileReference([string]$Root,[string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($full)) { throw 'Affected phase stream/output is absent or outside its evidence root.' }
    $bytes = [IO.File]::ReadAllBytes($full)
    return [pscustomobject][ordered]@{path=[IO.Path]::GetRelativePath($Root,$full).Replace('\','/');bytes=[long]$bytes.Length;sha256=Get-Sha256 $bytes}
}
function Assert-FileReference([string]$Root,[object]$Reference) {
    $properties = @($Reference.PSObject.Properties.Name)
    [Array]::Sort($properties,[StringComparer]::Ordinal)
    if (($properties -join ',') -cne 'bytes,path,sha256') { throw 'Affected phase stream/output reference has unknown or missing properties.' }
    $full = [IO.Path]::GetFullPath((Join-Path $Root (([string]$Reference.path).Replace('/',[IO.Path]::DirectorySeparatorChar))))
    $observed = Get-FileReference -Root $Root -Path $full
    if ([string]$observed.path -cne [string]$Reference.path -or [long]$observed.bytes -ne [long]$Reference.bytes -or [string]$observed.sha256 -cne [string]$Reference.sha256) { throw "Affected phase stream/output reference drifted: $($Reference.path)" }
}
function Write-NewBytes([string]$Path,[byte[]]$Bytes) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    try {
        $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    } catch [IO.IOException] { throw "Affected phase evidence path already exists: $Path" }
}
function Write-NewJson([string]$Path,[object]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $Value) + "`n")
    Write-NewBytes -Path $Path -Bytes $bytes
}
function Read-DependencyProjectionFile([string]$Path,[string]$ExpectedSha256) {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not[IO.File]::Exists($full)){throw 'Affected phase dependency projection file is absent.'}
    $info=[IO.FileInfo]::new($full)
    if($info.Length -le 0 -or $info.Length -gt 134217728){throw 'Affected phase dependency projection file exceeds its bound.'}
    [byte[]]$bytes=[IO.File]::ReadAllBytes($full)
    if((Get-Sha256 $bytes)-cne$ExpectedSha256){throw 'Affected phase dependency projection file differs from its parent-owned hash.'}
    try { $json = [Text.UTF8Encoding]::new($false,$true).GetString($bytes) } catch { throw 'Affected phase dependency projection is not strict UTF-8.' }
    $schemaPath = Join-Path $repoRoot 'schemas/affected-validation-self-test-dependency-projection-v1.schema.json'
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'Affected phase dependency projection fails its closed schema.' }
    return $json | ConvertFrom-Json -Depth 64 -DateKind String
}
function Get-DependencyProjection([string]$ExpectedHead,[string]$ExpectedTree,[string]$ExpectedCheckId) {
    $projection = Read-DependencyProjectionFile -Path (Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_PATH' '^.+$') -ExpectedSha256 (Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_SHA256' '^[0-9a-f]{64}$')
    $module = Get-Module MorphospaceAffectedValidation
    $head = & $module { param($Root) Get-MorphospaceAffectedGitIdentity -RepositoryRoot $Root -Revision HEAD } $repoRoot
    if ([string]$head.commit -cne $ExpectedHead -or [string]$head.tree -cne $ExpectedTree) { throw 'Affected phase repository HEAD/tree differs from the managed execution identity.' }
    $inventory = & $module { param($Root,$Commit) Get-MorphospaceAffectedTreeInventory -RepositoryRoot $Root -Commit $Commit } $repoRoot $ExpectedHead
    $registry = Read-MorphospaceProtocolJson -Path (Join-Path $repoRoot 'manifests/affected-validation-registry.json')
    $compiledRegistry = Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $repoRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json')
    $registrySha = Get-MorphospaceCanonicalJsonSha256 -Value $registry
    $check = $compiledRegistry.checks[$ExpectedCheckId]
    if ($null -eq $check -or [string]$check.command_path -cne 'scripts/Invoke-AffectedValidationSelfTestPhase.ps1') { throw 'Affected phase dependency projection does not resolve its exact managed check.' }
    $commonInputSha = Get-MorphospaceCanonicalJsonSha256 -Value ([pscustomobject][ordered]@{command_path=[string]$check.command_path;consume_path_sets=@($check.consume_path_sets | ForEach-Object { [string]$_ })})
    foreach ($selectorCheckId in @(@($checkIds.Values) + @('affected-selector-selftest'))) {
        $selectorCheck = $compiledRegistry.checks[[string]$selectorCheckId]
        if ($null -eq $selectorCheck) { throw 'Affected phase selector checks do not share one exact dependency-closure input.' }
        $selectorInputSha = Get-MorphospaceCanonicalJsonSha256 -Value ([pscustomobject][ordered]@{command_path=[string]$selectorCheck.command_path;consume_path_sets=@($selectorCheck.consume_path_sets | ForEach-Object { [string]$_ })})
        if ($selectorInputSha -cne $commonInputSha) { throw 'Affected phase selector checks do not share one exact dependency-closure input.' }
    }
    if ([string]$projection.repository -cne 'MesmerPrism/rusty-morphospace-work-environment' -or [string]$projection.head_commit -cne $ExpectedHead -or [string]$projection.head_tree -cne $ExpectedTree -or [string]$projection.registry_sha256 -cne $registrySha -or [string]$projection.check_id -cne $ExpectedCheckId -or [string]$projection.command_path -cne [string]$check.command_path -or (Get-MorphospaceCanonicalJsonSha256 -Value @($projection.consume_path_sets)) -cne (Get-MorphospaceCanonicalJsonSha256 -Value @($check.consume_path_sets))) { throw 'Affected phase dependency projection differs from its exact current head/registry/check input.' }
    $previous = $null
    foreach ($record in @($projection.dependency_manifest)) {
        $path = [string]$record.path
        if ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$path) -ge 0) { throw 'Affected phase dependency projection manifest is not unique and ordinal sorted.' }
        $entry = $inventory.by_path[$path]
        if ($null -eq $entry -or [string]$entry.type -cne 'blob' -or [string]$entry.mode -cne [string]$record.mode -or [string]$entry.blob -cne [string]$record.blob) { throw "Affected phase dependency projection differs from the exact-head tree: $path" }
        $previous = $path
    }
    [void](& $module { param($Root,$Head,$Inventory,$Paths) Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $Root -ExpectedHead $Head -Inventory $Inventory -Paths $Paths } $repoRoot $head $inventory @($projection.dependency_manifest.path))
    return $projection
}
function Get-RunnerBinding {
    $powerShellPath = [IO.Path]::GetFullPath((Get-Process -Id $PID).Path)
    $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace([string]$gitCommand.Source)) { throw 'Affected phase runner could not resolve the Git executable.' }
    $gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Source)
    $gitVersion = (& $gitPath --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $gitVersion -cnotmatch '^git version [0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[A-Za-z0-9.-]+)?$') { throw 'Affected phase runner could not resolve a canonical Git version.' }
    return [pscustomobject][ordered]@{
        os_description=[Runtime.InteropServices.RuntimeInformation]::OSDescription
        process_architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
        powershell_version=$PSVersionTable.PSVersion.ToString()
        powershell_executable_sha256=Get-Sha256 ([IO.File]::ReadAllBytes($powerShellPath))
        git_version=$gitVersion
        git_executable_sha256=Get-Sha256 ([IO.File]::ReadAllBytes($gitPath))
    }
}
function Get-Binding([string]$PhaseId,[string]$CheckId,[string]$Base,[string]$Head,[string]$Tree,[string]$Plan,[string]$Platform,[object[]]$Manifest,[object]$Runner) {
    return [pscustomobject][ordered]@{repository='MesmerPrism/rusty-morphospace-work-environment';base_commit=$Base;head_commit=$Head;head_tree=$Tree;plan_sha256=$Plan;platform=$Platform;check_id=$CheckId;phase_id=$PhaseId;runner=$Runner;dependency_manifest=@($Manifest)}
}
function Assert-ReusableBinding([string]$RepositoryRoot,[object]$Observed,[object]$Expected) {
    foreach ($name in @('repository','platform','check_id','phase_id')) {
        if ([string]$Observed.$name -cne [string]$Expected.$name) { throw "Affected phase ancestor binding changed '$name'." }
    }
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $Observed.runner) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $Expected.runner)) { throw 'Affected phase ancestor binding changed the exact runner identity.' }
    if ((Get-MorphospaceCanonicalJsonSha256 -Value @($Observed.dependency_manifest)) -cne (Get-MorphospaceCanonicalJsonSha256 -Value @($Expected.dependency_manifest))) { throw 'Affected phase ancestor binding changed the exact dependency manifest.' }
    $observedTree = (& git -C $RepositoryRoot rev-parse "$([string]$Observed.head_commit)^{tree}" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $observedTree -cne [string]$Observed.head_tree) { throw 'Affected phase ancestor binding source tree is invalid.' }
    $expectedTree = (& git -C $RepositoryRoot rev-parse "$([string]$Expected.head_commit)^{tree}" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $expectedTree -cne [string]$Expected.head_tree) { throw 'Affected phase current binding tree is invalid.' }
    & git -C $RepositoryRoot merge-base --is-ancestor ([string]$Observed.base_commit) ([string]$Observed.head_commit) 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Affected phase ancestor binding base is not an ancestor of its source head.' }
    & git -C $RepositoryRoot merge-base --is-ancestor ([string]$Observed.head_commit) ([string]$Expected.head_commit) 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Affected phase source head is not an ancestor of the current head.' }
}
function Test-Terminal([string]$Root,[string]$Path,[object]$ExpectedBinding,[string]$ExpectedBindingSha,[bool]$RequirePass,[switch]$AllowCompatibleAncestor) {
    $schemaPath = Join-Path $repoRoot 'schemas/affected-validation-self-test-phase-receipt-v1.schema.json'
    $raw = [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    if (-not (Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'Affected phase terminal fails its closed schema.' }
    $terminal = Read-MorphospaceProtocolJson -Path $Path
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $terminal.binding) -cne [string]$terminal.binding_sha256) { throw 'Affected phase terminal binding hash is damaged.' }
    $observedBindingSha = Get-MorphospaceCanonicalJsonSha256 -Value $terminal.binding
    $expectedCanonicalSha = Get-MorphospaceCanonicalJsonSha256 -Value $ExpectedBinding
    if ([string]$terminal.binding_sha256 -cne $ExpectedBindingSha -or $observedBindingSha -cne $expectedCanonicalSha) {
        if (-not $AllowCompatibleAncestor) { throw 'Affected phase terminal does not match the exact current binding.' }
        Assert-ReusableBinding -RepositoryRoot $repoRoot -Observed $terminal.binding -Expected $ExpectedBinding
    }
    Assert-FileReference -Root $Root -Reference $terminal.child.stdout
    Assert-FileReference -Root $Root -Reference $terminal.child.stderr
    foreach ($output in @($terminal.outputs)) { Assert-FileReference -Root $Root -Reference $output }
    if ($RequirePass -and [string]$terminal.result -cne 'pass') { throw "Affected phase terminal is not passing: $($terminal.phase_id)=$($terminal.result)" }
    return $terminal
}

function Invoke-BindingCompatibilitySelfTest {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('affected-phase-binding-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fixture)
    function Invoke-FixtureGit([string[]]$Arguments) {
        $output = @(& git -C $fixture @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Affected phase binding fixture Git failed: git $($Arguments -join ' ') :: $($output -join ' ')" }
        return ($output -join "`n").Trim()
    }
    function Write-Fixture([string]$Path,[string]$Value) { [IO.File]::WriteAllText((Join-Path $fixture $Path),$Value,[Text.UTF8Encoding]::new($false)) }
    function Copy-Binding([object]$Value) { $Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json -Depth 32 -DateKind String }
    function Assert-Rejected([scriptblock]$Action,[string]$Pattern,[string]$Context) { $rejected=$false;try{&$Action}catch{$rejected=[string]$_.Exception.Message-like$Pattern};if(-not$rejected){throw $Context} }
    function Write-FixtureProjection([object]$Value,[string]$Leaf) {
        $path=Join-Path $fixture $Leaf
        [byte[]]$bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $Value)+"`n")
        [IO.File]::WriteAllBytes($path,$bytes)
        return [pscustomobject][ordered]@{path=$path;sha256=Get-Sha256 $bytes}
    }
    try {
        [void](Invoke-FixtureGit @('init','--initial-branch=main'))
        [void](Invoke-FixtureGit @('config','user.name','Affected Phase Binding Test'))
        [void](Invoke-FixtureGit @('config','user.email','affected-phase-binding@example.invalid'))
        Write-Fixture 'fixture.txt' "base`n";[void](Invoke-FixtureGit @('add','fixture.txt'));[void](Invoke-FixtureGit @('commit','-m','base'))
        $base=Invoke-FixtureGit @('rev-parse','HEAD')
        Write-Fixture 'source.txt' "source`n";[void](Invoke-FixtureGit @('add','source.txt'));[void](Invoke-FixtureGit @('commit','-m','source'))
        $source=Invoke-FixtureGit @('rev-parse','HEAD');$sourceTree=Invoke-FixtureGit @('rev-parse','HEAD^{tree}')
        [void](Invoke-FixtureGit @('branch','nonancestor',$base))
        Write-Fixture 'unrelated.txt' "current`n";[void](Invoke-FixtureGit @('add','unrelated.txt'));[void](Invoke-FixtureGit @('commit','-m','unrelated descendant'))
        $current=Invoke-FixtureGit @('rev-parse','HEAD');$currentTree=Invoke-FixtureGit @('rev-parse','HEAD^{tree}')
        [void](Invoke-FixtureGit @('checkout','nonancestor'));Write-Fixture 'sibling.txt' "sibling`n";[void](Invoke-FixtureGit @('add','sibling.txt'));[void](Invoke-FixtureGit @('commit','-m','nonancestor sibling'))
        $sibling=Invoke-FixtureGit @('rev-parse','HEAD');$siblingTree=Invoke-FixtureGit @('rev-parse','HEAD^{tree}');[void](Invoke-FixtureGit @('checkout','main'))
        $runner=[pscustomobject][ordered]@{os_description='fixture';process_architecture='x64';powershell_version='7.5.0';powershell_executable_sha256=('1'*64);git_version='git version 2.50.0';git_executable_sha256=('2'*64)}
        $manifestPaths=@(
            '.github/workflows/validate.yml',
            'manifests/affected-validation-registry.json',
            'schemas/affected-validation-check-evidence-v1.schema.json',
            'schemas/affected-validation-check-inventory-v1.schema.json',
            'schemas/affected-validation-plan-v1.schema.json',
            'scripts/Invoke-AffectedValidation.ps1',
            'scripts/Invoke-AffectedValidationSelfTestPhase.ps1',
            'scripts/Test-AffectedValidation.ps1',
            'scripts/lib/MorphospaceAffectedValidationCheckEvidence.psm1',
            'scripts/lib/MorphospaceAffectedValidationDependencyClosure.psm1'
        )
        $manifest=[Collections.Generic.List[object]]::new()
        for($manifestIndex=0;$manifestIndex -lt $manifestPaths.Count;$manifestIndex++){
            $hex=('{0:x}' -f (($manifestIndex % 14)+1))
            $manifest.Add([pscustomobject][ordered]@{path=[string]$manifestPaths[$manifestIndex];mode='100644';blob=($hex*40)})
        }
        $manifest=@($manifest.ToArray())
        $projection=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_self_test_dependency_projection.v1';repository='MesmerPrism/rusty-morphospace-work-environment';head_commit=$current;head_tree=$currentTree;registry_sha256=('4'*64);check_id='affected-selector-trust-self-executor';command_path='scripts/Invoke-AffectedValidationSelfTestPhase.ps1';consume_path_sets=@('affected-validation-contract','protocol-common','selector-trust-root');dependency_manifest=$manifest}
        $projectionFile=Write-FixtureProjection $projection 'projection.json'
        $projectionRoundTrip=Read-DependencyProjectionFile -Path $projectionFile.path -ExpectedSha256 $projectionFile.sha256
        if((Get-MorphospaceCanonicalJsonSha256 -Value $projectionRoundTrip)-cne(Get-MorphospaceCanonicalJsonSha256 -Value $projection)){throw 'Affected phase dependency projection transport roundtrip changed canonical bytes.'}
        Assert-Rejected {Read-DependencyProjectionFile -Path $projectionFile.path -ExpectedSha256 ('f'*64)} '*parent-owned hash*' 'Affected phase dependency projection accepted a wrong parent hash.'
        $schemaDamage=Copy-Binding $projection;$schemaDamage.repository='Different/Repository';$schemaDamageFile=Write-FixtureProjection $schemaDamage 'projection-damage.json';Assert-Rejected {Read-DependencyProjectionFile -Path $schemaDamageFile.path -ExpectedSha256 $schemaDamageFile.sha256} '*' 'Affected phase dependency projection accepted a schema-invalid payload.'
        $observed=Get-Binding -PhaseId 'trust-self-executor' -CheckId 'affected-selector-trust-self-executor' -Base $base -Head $source -Tree $sourceTree -Plan ('5'*64) -Platform linux -Manifest $manifest -Runner $runner
        $expected=Get-Binding -PhaseId 'trust-self-executor' -CheckId 'affected-selector-trust-self-executor' -Base $base -Head $current -Tree $currentTree -Plan ('6'*64) -Platform linux -Manifest $manifest -Runner $runner
        Assert-ReusableBinding -RepositoryRoot $fixture -Observed $observed -Expected $expected
        Assert-ReusableBinding -RepositoryRoot $fixture -Observed $expected -Expected $expected
        $runnerDamage=Copy-Binding $observed;$runnerDamage.runner.git_executable_sha256=('f'*64);Assert-Rejected {Assert-ReusableBinding -RepositoryRoot $fixture -Observed $runnerDamage -Expected $expected} '*runner identity*' 'Affected phase binding self-test accepted runner drift.'
        foreach ($dependencyPath in @($manifest.path)) {
            $dependencyDamage=Copy-Binding $observed
            $dependencyRecord=@($dependencyDamage.dependency_manifest | Where-Object path -CEQ $dependencyPath)
            if ($dependencyRecord.Count -ne 1) { throw "Affected phase binding self-test lacks exact dependency damage target: $dependencyPath" }
            $dependencyRecord[0].blob=('f'*40)
            Assert-Rejected {Assert-ReusableBinding -RepositoryRoot $fixture -Observed $dependencyDamage -Expected $expected} '*dependency manifest*' "Affected phase binding self-test accepted dependency drift for $dependencyPath."
        }
        $omissionDamage=Copy-Binding $observed;$omissionDamage.dependency_manifest=@($omissionDamage.dependency_manifest | Select-Object -SkipLast 1);Assert-Rejected {Assert-ReusableBinding -RepositoryRoot $fixture -Observed $omissionDamage -Expected $expected} '*dependency manifest*' 'Affected phase binding self-test accepted a dependency omission.'
        $additionDamage=Copy-Binding $observed;$additionDamage.dependency_manifest=@($additionDamage.dependency_manifest)+@([pscustomobject][ordered]@{path='scripts/z-extra.ps1';mode='100644';blob=('e'*40)});Assert-Rejected {Assert-ReusableBinding -RepositoryRoot $fixture -Observed $additionDamage -Expected $expected} '*dependency manifest*' 'Affected phase binding self-test accepted a dependency addition.'
        $treeDamage=Copy-Binding $observed;$treeDamage.head_tree=('f'*40);Assert-Rejected {Assert-ReusableBinding -RepositoryRoot $fixture -Observed $treeDamage -Expected $expected} '*source tree*' 'Affected phase binding self-test accepted a wrong source tree.'
        $nonancestorDamage=Copy-Binding $observed;$nonancestorDamage.head_commit=$sibling;$nonancestorDamage.head_tree=$siblingTree;Assert-Rejected {Assert-ReusableBinding -RepositoryRoot $fixture -Observed $nonancestorDamage -Expected $expected} '*not an ancestor of the current head*' 'Affected phase binding self-test accepted a nonancestor source.'
        Write-Output 'Affected-validation phase ancestor-binding compatibility self-test passed.'
    } finally { if([IO.Directory]::Exists($fixture)){Remove-Item -LiteralPath $fixture -Recurse -Force} }
}

if($BindingSelfTest){Invoke-BindingCompatibilitySelfTest;return}

$evidenceRoot = [IO.Path]::GetFullPath((Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_PHASE_ROOT' '^.+$'))
$baseCommit = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_BASE_COMMIT' '^[0-9a-f]{40}$'
$headCommit = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_HEAD_COMMIT' '^[0-9a-f]{40}$'
$planSha256 = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_PLAN_SHA256' '^[0-9a-f]{64}$'
$platform = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_PLATFORM' '^(windows|linux)$'
$headTree = (& git -C $repoRoot rev-parse "$headCommit^{tree}").Trim()
if ($LASTEXITCODE -ne 0 -or $headTree -cnotmatch '^[0-9a-f]{40}$') { throw 'Affected phase runner could not resolve the exact head tree.' }
$runnerBinding = Get-RunnerBinding

if ($Verify) {
    $managedVerifierCheckId = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_CHECK_ID' '^[a-z0-9][a-z0-9-]{1,95}$'
    if ($managedVerifierCheckId -cne 'affected-selector-selftest') { throw "Affected phase verifier/check routing mismatch: $managedVerifierCheckId" }
    $dependencyProjection = Get-DependencyProjection -ExpectedHead $headCommit -ExpectedTree $headTree -ExpectedCheckId $managedVerifierCheckId
    $dependencyManifest = @($dependencyProjection.dependency_manifest)
    $terminalFiles = @(Get-ChildItem -LiteralPath $evidenceRoot -File -Filter '*.terminal.json' -ErrorAction SilentlyContinue)
    if ($terminalFiles.Count -ne $phaseIds.Count) { throw 'Affected phase verifier requires exactly one terminal for every phase.' }
    foreach ($phaseId in $phaseIds) {
        $terminalPath = Join-Path $evidenceRoot "$phaseId.terminal.json"
        if (-not [IO.File]::Exists($terminalPath)) { throw "Affected phase verifier is missing '$phaseId'." }
        $binding = Get-Binding -PhaseId $phaseId -CheckId ([string]$checkIds[$phaseId]) -Base $baseCommit -Head $headCommit -Tree $headTree -Plan $planSha256 -Platform $platform -Manifest $dependencyManifest -Runner $runnerBinding
        $bindingSha = Get-MorphospaceCanonicalJsonSha256 -Value $binding
        [void](Test-Terminal -Root $evidenceRoot -Path $terminalPath -ExpectedBinding $binding -ExpectedBindingSha $bindingSha -RequirePass $true -AllowCompatibleAncestor)
    }
    $module = Get-Module MorphospaceAffectedValidation
    $inventory = & $module { param($Root,$Commit) Get-MorphospaceAffectedTreeInventory -RepositoryRoot $Root -Commit $Commit } $repoRoot $headCommit
    $head = [pscustomobject][ordered]@{commit=$headCommit;tree=$headTree}
    [void](& $module { param($Root,$Head,$Inventory,$Paths) Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $Root -ExpectedHead $Head -Inventory $Inventory -Paths $Paths } $repoRoot $head $inventory @($dependencyManifest.path))
    Write-Host 'Affected-validation phased selector receipt set passed without replay.'
    return
}

$expectedCheckId = [string]$checkIds[$Phase]
$managedCheckId = Get-RequiredEnvironment 'RUSTY_AFFECTED_VALIDATION_CHECK_ID' '^[a-z0-9][a-z0-9-]{1,95}$'
if ($managedCheckId -cne $expectedCheckId) { throw "Affected phase/check routing mismatch: phase=$Phase check=$managedCheckId expected=$expectedCheckId" }
$dependencyProjection = Get-DependencyProjection -ExpectedHead $headCommit -ExpectedTree $headTree -ExpectedCheckId $managedCheckId
$dependencyManifest = @($dependencyProjection.dependency_manifest)
$binding = Get-Binding -PhaseId $Phase -CheckId $managedCheckId -Base $baseCommit -Head $headCommit -Tree $headTree -Plan $planSha256 -Platform $platform -Manifest $dependencyManifest -Runner $runnerBinding
$bindingSha = Get-MorphospaceCanonicalJsonSha256 -Value $binding
$terminalPath = Join-Path $evidenceRoot "$Phase.terminal.json"
if ([IO.File]::Exists($terminalPath)) {
    [void](Test-Terminal -Root $evidenceRoot -Path $terminalPath -ExpectedBinding $binding -ExpectedBindingSha $bindingSha -RequirePass $true)
    Write-Host "Affected-validation phase '$Phase' reused its exact passing terminal."
    return
}

$startPath = Join-Path $evidenceRoot "$Phase.start.json"
$stdoutPath = Join-Path $evidenceRoot "$Phase.stdout.bin"
$stderrPath = Join-Path $evidenceRoot "$Phase.stderr.bin"
$started = [DateTimeOffset]::UtcNow
Write-NewJson -Path $startPath -Value ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_self_test_phase_start.v1';phase_id=$Phase;binding=$binding;binding_sha256=$bindingSha;started_at=$started.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture);budget_seconds=$BudgetSeconds})

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = (Get-Process -Id $PID).Path
$startInfo.WorkingDirectory = $repoRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$phaseChildEnvironment = @{}
foreach ($name in @('COMSPEC','HOME','PATH','PATHEXT','SYSTEMROOT','TEMP','TMP','TMPDIR','WINDIR','GITHUB_ACTIONS','GITHUB_REPOSITORY','GITHUB_EVENT_NAME','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_WORKFLOW_REF','GITHUB_JOB','RUNNER_TEMP','PR_NUMBER','RUSTY_AFFECTED_VALIDATION_PHASE_ROOT','RUSTY_AFFECTED_VALIDATION_BASE_COMMIT','RUSTY_AFFECTED_VALIDATION_HEAD_COMMIT','RUSTY_AFFECTED_VALIDATION_PLAN_SHA256','RUSTY_AFFECTED_VALIDATION_PLATFORM','RUSTY_AFFECTED_VALIDATION_CHECK_ID','RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_PATH','RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_SHA256','RUSTY_AFFECTED_VALIDATION_GUARD_SID','RUSTY_AFFECTED_VALIDATION_TRUSTED_ANCESTORS','RUSTY_AFFECTED_VALIDATION_PARENT_FUTURE_THREAD_ID','RUSTY_AFFECTED_VALIDATION_REMOVED_PRIVILEGE_LUID','RUSTY_AFFECTED_VALIDATION_FUTURE_THREAD_ID')) {
    $value = [Environment]::GetEnvironmentVariable($name,'Process')
    if ($null -ne $value) { $phaseChildEnvironment[$name] = $value }
}
$startInfo.Environment.Clear()
[string[]]$phaseChildNames=@($phaseChildEnvironment.Keys);if($phaseChildNames.Count-gt1){[Array]::Sort($phaseChildNames,[StringComparer]::Ordinal)}
foreach($name in $phaseChildNames){$startInfo.Environment.Add($name,[string]$phaseChildEnvironment[$name])}
foreach ($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Test-AffectedValidation.ps1'),'-SelfTestPhase',$Phase)) { [void]$startInfo.ArgumentList.Add($argument) }
if ($Phase -ceq 'selection-scenarios') { [void]$startInfo.ArgumentList.Add('-SelectionScenarioEvidenceRoot'); [void]$startInfo.ArgumentList.Add((Join-Path $evidenceRoot 'selection-scenarios')) }
$process = [Diagnostics.Process]::new(); $process.StartInfo = $startInfo
$stdoutMemory = [IO.MemoryStream]::new(); $stderrMemory = [IO.MemoryStream]::new()
$childStarted = $false; $timedOut = $false; $drainTimedOut = $false; $exitCode = $null; $launchError = $null
try {
    try {
        if (-not $process.Start()) { throw 'Affected phase child did not start.' }
        $childStarted = $true
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutMemory)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrMemory)
        if (-not $process.WaitForExit($BudgetSeconds * 1000)) { $timedOut = $true; try { $process.Kill($true) } catch {}; [void]$process.WaitForExit(15000) }
        if (-not [Threading.Tasks.Task]::WaitAll(@($stdoutTask,$stderrTask),15000)) { $drainTimedOut = $true }
        if ($process.HasExited -and -not $timedOut) { $exitCode = [int]$process.ExitCode }
    } catch { $launchError = [string]$_.Exception.Message }
    [byte[]]$stdoutBytes = @($stdoutMemory.ToArray())
    [byte[]]$stderrBytes = @(if ([string]::IsNullOrWhiteSpace($launchError)) { $stderrMemory.ToArray() } else { [Text.UTF8Encoding]::new($false).GetBytes($launchError) })
    Write-NewBytes -Path $stdoutPath -Bytes $stdoutBytes
    Write-NewBytes -Path $stderrPath -Bytes $stderrBytes
} finally {
    $process.Dispose(); $stdoutMemory.Dispose(); $stderrMemory.Dispose()
}
$ended = [DateTimeOffset]::UtcNow
$result = if (-not $childStarted -or -not [string]::IsNullOrWhiteSpace($launchError)) { 'infra-fail' } elseif ($timedOut -or $drainTimedOut -or $exitCode -ne 0) { 'code-fail' } else { 'pass' }
$outputs = [Collections.Generic.List[object]]::new()
if ($Phase -ceq 'graph-import-closure') {
    $graphOutputPath = Join-Path $evidenceRoot 'graph-import-closure.output.json'
    if ([IO.File]::Exists($graphOutputPath)) { $outputs.Add((Get-FileReference -Root $evidenceRoot -Path $graphOutputPath)) }
}
$terminal = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.affected_validation_self_test_phase_receipt.v1';phase_id=$Phase;binding=$binding;binding_sha256=$bindingSha
    started_at=$started.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture);ended_at=$ended.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
    budget_seconds=$BudgetSeconds;elapsed_ms=[long]($ended-$started).TotalMilliseconds;result=$result
    child=[pscustomobject][ordered]@{started=$childStarted;exit_code=$exitCode;timed_out=$timedOut;post_kill_drain_timed_out=$drainTimedOut;stdout=Get-FileReference -Root $evidenceRoot -Path $stdoutPath;stderr=Get-FileReference -Root $evidenceRoot -Path $stderrPath}
    outputs=@($outputs.ToArray());claims=[pscustomobject][ordered]@{phase_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}
}
$terminalJson = ConvertTo-MorphospaceCanonicalJson -Value $terminal
if (-not (Test-Json -Json $terminalJson -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-self-test-phase-receipt-v1.schema.json') -ErrorAction Stop)) { throw 'Affected phase terminal fails its closed schema.' }
Write-NewJson -Path $terminalPath -Value $terminal
if ($result -cne 'pass') { throw "Affected-validation phase '$Phase' failed with '$result'; typed evidence is preserved." }
Write-Host "Affected-validation phase '$Phase' passed in $($terminal.elapsed_ms)ms."
