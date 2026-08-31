[CmdletBinding(DefaultParameterSetName = 'verify')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$RepositoryRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$BeforeCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$HeadCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$ReusePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = 'self')][switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($SelfTest) {
    $sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
    function Invoke-ReuseSelfGit([string]$Root, [string[]]$Arguments) { $value = & git -C $Root @Arguments 2>&1; if ($LASTEXITCODE -ne 0) { throw "Reuse self-test git failure: $($value -join "`n")" }; return ($value -join "`n").Trim() }
    function Write-ReuseSelfUtf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
    function Get-ReuseSelfHash([string]$Path) { ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path)))).ToLowerInvariant() }
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-reuse-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fixture)
    try {
        [void](Invoke-ReuseSelfGit $fixture @('init', '--initial-branch=main')); [void](Invoke-ReuseSelfGit $fixture @('config', 'user.name', 'Affected Reuse Test')); [void](Invoke-ReuseSelfGit $fixture @('config', 'user.email', 'affected-reuse@example.invalid'))
        foreach ($relative in @('manifests/affected-validation-registry.json','schemas/affected-validation-registry-v1.schema.json','schemas/affected-validation-plan-v1.schema.json','schemas/affected-validation-evidence-v1.schema.json','.github/workflows/validate.yml','scripts/lib/MorphospaceProtocolCommon.psm1','scripts/lib/MorphospaceAffectedValidation.psm1')) { $destination = Join-Path $fixture ($relative -replace '/', [IO.Path]::DirectorySeparatorChar); [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)); Copy-Item -LiteralPath (Join-Path $sourceRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)) -Destination $destination }
        $registry = Read-MorphospaceProtocolJson -Path (Join-Path $sourceRoot 'manifests/affected-validation-registry.json')
        foreach ($command in @($registry.checks | ForEach-Object { [string]$_.command_path } | Sort-Object -Unique)) { $destination = Join-Path $fixture ($command -replace '/', [IO.Path]::DirectorySeparatorChar); [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)); Copy-Item -LiteralPath (Join-Path $sourceRoot ($command -replace '/', [IO.Path]::DirectorySeparatorChar)) -Destination $destination }
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'docs')); Write-ReuseSelfUtf8 (Join-Path $fixture 'docs/base.md') "base`n"; [void](Invoke-ReuseSelfGit $fixture @('add','.')); [void](Invoke-ReuseSelfGit $fixture @('commit','-m','seed')); $alternateBase = Invoke-ReuseSelfGit $fixture @('rev-parse','HEAD')
        Write-ReuseSelfUtf8 (Join-Path $fixture 'docs/observed-base.md') "observed base`n"; [void](Invoke-ReuseSelfGit $fixture @('add','docs/observed-base.md')); [void](Invoke-ReuseSelfGit $fixture @('commit','-m','observed base')); $base = Invoke-ReuseSelfGit $fixture @('rev-parse','HEAD')
        [void](Invoke-ReuseSelfGit $fixture @('checkout','-b','candidate')); Write-ReuseSelfUtf8 (Join-Path $fixture 'docs/reuse.md') "candidate`n"; [void](Invoke-ReuseSelfGit $fixture @('add','docs/reuse.md')); [void](Invoke-ReuseSelfGit $fixture @('commit','-m','candidate')); $candidate = Invoke-ReuseSelfGit $fixture @('rev-parse','HEAD')
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $base -HeadRevision $candidate -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        $alternatePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $alternateBase -HeadRevision $candidate -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        $artifacts = Join-Path $fixture 'artifacts'; [void][IO.Directory]::CreateDirectory($artifacts); $planPath = Join-Path $artifacts 'affected-plan.json'; Write-ReuseSelfUtf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $plan) + "`n")
        $checkMap = @{}; foreach ($check in @($registry.checks)) { $checkMap[[string]$check.check_id] = $check }
        $results = [Collections.Generic.List[object]]::new(); $coverage = [Collections.Generic.List[object]]::new()
        foreach ($selected in @($plan.selected_checks | Where-Object { @($_.platforms) -ccontains 'linux' })) { $check = $checkMap[[string]$selected.check_id]; $blob = Invoke-ReuseSelfGit $fixture @('rev-parse', "${candidate}:$($check.command_path)"); $results.Add([pscustomobject][ordered]@{check_id=[string]$check.check_id;command_path=[string]$check.command_path;command_blob_sha1=$blob;result='pass';exit_code=0;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout_sha256=('0'*64);stderr_sha256=('0'*64);stdout_bytes=0;stderr_bytes=0}); $coverage.Add([pscustomobject][ordered]@{platform='linux';check_id=[string]$check.check_id;command_path=[string]$check.command_path;command_blob_sha1=$blob}) }
        if ($results.Count -eq 0) { throw 'Reuse self-test expected a Linux candidate selection.' }
        $candidateIdentity = [pscustomobject][ordered]@{commit=$candidate;tree=(Invoke-ReuseSelfGit $fixture @('rev-parse',"$candidate^{tree}"))}; $baseIdentity = [pscustomobject][ordered]@{commit=$base;tree=(Invoke-ReuseSelfGit $fixture @('rev-parse',"$base^{tree}"))}
        $evidence = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_evidence.v1';repository=[string]$plan.repository;base=$baseIdentity;head=$candidateIdentity;plan_sha256=[string]$plan.plan_sha256;platform='linux';runner=[pscustomobject][ordered]@{os_description='synthetic';powershell_version='7.6.0'};check_results=@($results.ToArray());result='pass';claims=[pscustomobject][ordered]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}
        $evidencePath = Join-Path $artifacts 'affected-linux-evidence.json'; Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $evidence) + "`n")
        [void](Invoke-ReuseSelfGit $fixture @('checkout','main')); [void](Invoke-ReuseSelfGit $fixture @('merge','--no-ff','candidate','-m','merge candidate')); $merge = Invoke-ReuseSelfGit $fixture @('rev-parse','HEAD')
        $expiry = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $planHash = Get-ReuseSelfHash $planPath; $evidenceHash = Get-ReuseSelfHash $evidencePath
        $receipt = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_reuse.v1';repository=[string]$plan.repository;event=[pscustomobject][ordered]@{name='pull_request';head_sha=$candidate;base_sha=$base};pull_request=[pscustomobject][ordered]@{number=1;head_sha=$candidate;base_sha=$base};run=[pscustomobject][ordered]@{id=1;attempt=1;event='pull_request';head_sha=$candidate;workflow_id=1;check_names=@('infrastructure','quick-linux','quick-windows','select','standard-windows')};base=$baseIdentity;head=$candidateIdentity;tree=$candidateIdentity.tree;workflow=[pscustomobject][ordered]@{id=1;path='.github/workflows/validate.yml';blob_sha1=(Invoke-ReuseSelfGit $fixture @('rev-parse',"${candidate}:.github/workflows/validate.yml"))};plan=[pscustomobject][ordered]@{artifact_name="affected-plan-$($plan.plan_sha256)";file_sha256=$planHash;canonical_sha256=[string]$plan.plan_sha256};artifacts=@([pscustomobject][ordered]@{id=1;remote_name="affected-plan-$($plan.plan_sha256)";name='affected-plan.json';platform='plan';sha256=$planHash;size=[long](Get-Item -LiteralPath $planPath).Length;expires_utc=$expiry},[pscustomobject][ordered]@{id=2;remote_name="affected-linux-$evidenceHash";name='affected-linux-evidence.json';platform='linux';sha256=$evidenceHash;size=[long](Get-Item -LiteralPath $evidencePath).Length;expires_utc=$expiry});coverage=@($coverage.ToArray());freshness=[pscustomobject][ordered]@{created_utc=[DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture);max_age_minutes=60};claims=[pscustomobject][ordered]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}
        $receiptPath = Join-Path $artifacts 'reuse.json'; Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts)
        $alternateCheckIds = (@($alternatePlan.selected_checks.check_id) -join ','); $observedCheckIds = (@($plan.selected_checks.check_id) -join ',')
        if ($alternateCheckIds -cne $observedCheckIds) { throw 'Reuse self-test alternate base unexpectedly changes the selected checks.' }
        $alternateBaseIdentity = [pscustomobject][ordered]@{commit=$alternateBase;tree=(Invoke-ReuseSelfGit $fixture @('rev-parse',"$alternateBase^{tree}"))}
        $alternateEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $alternateEvidence.base = $alternateBaseIdentity; $alternateEvidence.plan_sha256 = [string]$alternatePlan.plan_sha256
        Write-ReuseSelfUtf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $alternatePlan) + "`n"); Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $alternateEvidence) + "`n")
        $alternateReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $alternateReceipt.base = $alternateBaseIdentity; $alternateReceipt.event.base_sha = $alternateBase; $alternateReceipt.pull_request.base_sha = $alternateBase; $alternateReceipt.plan.canonical_sha256 = [string]$alternatePlan.plan_sha256
        $alternatePlanArtifact = @($alternateReceipt.artifacts | Where-Object { $_.name -ceq 'affected-plan.json' })[0]; $alternatePlanArtifact.sha256 = Get-ReuseSelfHash $planPath; $alternatePlanArtifact.size = [long](Get-Item -LiteralPath $planPath).Length; $alternatePlanArtifact.remote_name = "affected-plan-$($alternatePlan.plan_sha256)"; $alternateReceipt.plan.file_sha256 = $alternatePlanArtifact.sha256; $alternateReceipt.plan.artifact_name = $alternatePlanArtifact.remote_name
        $alternateEvidenceArtifact = @($alternateReceipt.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $alternateEvidenceArtifact.sha256 = Get-ReuseSelfHash $evidencePath; $alternateEvidenceArtifact.size = [long](Get-Item -LiteralPath $evidencePath).Length; $alternateEvidenceArtifact.remote_name = "affected-linux-$($alternateEvidenceArtifact.sha256)"
        Write-ReuseSelfUtf8 $receiptPath (($alternateReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $alternateBaseError = $null; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $alternateBaseError = $_.Exception.Message }
        if ($alternateBaseError -notlike '*observed before*') { throw 'Reuse self-test did not reject the coherent alternate base through the observed-base comparison.' }
        Write-ReuseSelfUtf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $plan) + "`n"); Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $evidence) + "`n"); Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        function Assert-ReuseSelfEvidenceBindingRejected([string]$Name, [scriptblock]$Mutate) {
            $damagedEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            & $Mutate $damagedEvidence
            Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $damagedEvidence) + "`n")
            $damagedReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            $artifact = @($damagedReceipt.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]
            $artifact.sha256 = Get-ReuseSelfHash $evidencePath; $artifact.size = [long](Get-Item -LiteralPath $evidencePath).Length; $artifact.remote_name = "affected-linux-$($artifact.sha256)"
            Write-ReuseSelfUtf8 $receiptPath (($damagedReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            $rejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $rejected = $true }
            Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $evidence) + "`n"); Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            if (-not $rejected) { throw "Reuse self-test accepted $Name evidence binding drift." }
        }
        Assert-ReuseSelfEvidenceBindingRejected -Name 'repository' -Mutate { param($value) $value.repository = 'example.invalid/other' }
        Assert-ReuseSelfEvidenceBindingRejected -Name 'platform' -Mutate { param($value) $value.platform = 'windows' }
        Assert-ReuseSelfEvidenceBindingRejected -Name 'base tree' -Mutate { param($value) $value.base.tree = ('0' * 40) }
        Assert-ReuseSelfEvidenceBindingRejected -Name 'head tree' -Mutate { param($value) $value.head.tree = ('1' * 40) }
        $baseTreeReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $baseTreeReceipt.base.tree = ('0' * 40); Write-ReuseSelfUtf8 $receiptPath (($baseTreeReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $baseTreeRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $baseTreeRejected = $true }; if (-not $baseTreeRejected) { throw 'Reuse self-test accepted receipt base-tree drift.' }
        Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        function Assert-ReuseSelfRunChecksRejected([string]$Name, [string[]]$CheckNames) {
            $damagedReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            $damagedReceipt.run.check_names = @($CheckNames)
            Write-ReuseSelfUtf8 $receiptPath (($damagedReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            $reason = $null; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $reason = $_.Exception.Message }
            Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
            if ($reason -notlike '*run check identities differs from the exact expected set*') { throw "Reuse self-test did not reject $Name through the exact run check identity contract." }
        }
        Assert-ReuseSelfRunChecksRejected -Name 'artifact aliases as job identities' -CheckNames @('affected-linux','infrastructure','quick-windows','select','standard-windows')
        Assert-ReuseSelfRunChecksRejected -Name 'an extra successful job identity' -CheckNames @('infrastructure','quick-linux','quick-windows','select','standard-windows','unexpected-success')
        $damaged = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $damaged.coverage = @(); Write-ReuseSelfUtf8 $receiptPath (($damaged | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $coverageRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $coverageRejected = $true }; if (-not $coverageRejected) { throw 'Reuse self-test accepted absent selected coverage.' }
        $stale = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $stale.freshness.created_utc = [DateTimeOffset]::UtcNow.AddMinutes(-61).ToString('o',[Globalization.CultureInfo]::InvariantCulture); Write-ReuseSelfUtf8 $receiptPath (($stale | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $staleRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $staleRejected = $true }; if (-not $staleRejected) { throw 'Reuse self-test accepted stale evidence.' }
        $impossibleEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $impossibleEvidence.check_results[0].exit_code = 1; Write-ReuseSelfUtf8 $evidencePath (($impossibleEvidence | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $impossibleHash = Get-ReuseSelfHash $evidencePath; $impossibleReceipt = $receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64; $impossibleArtifact = @($impossibleReceipt.artifacts | Where-Object { $_.name -ceq 'affected-linux-evidence.json' })[0]; $impossibleArtifact.sha256 = $impossibleHash; $impossibleArtifact.size = [long](Get-Item -LiteralPath $evidencePath).Length; $impossibleArtifact.remote_name = "affected-linux-$impossibleHash"; Write-ReuseSelfUtf8 $receiptPath (($impossibleReceipt | ConvertTo-Json -Depth 64 -Compress) + "`n")
        $impossibleRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $impossibleRejected = $true }; if (-not $impossibleRejected) { throw 'Reuse self-test accepted pass evidence with a nonzero exit.' }
        Write-ReuseSelfUtf8 $evidencePath ((ConvertTo-MorphospaceCanonicalJson -Value $evidence) + "`n"); Write-ReuseSelfUtf8 $receiptPath (($receipt | ConvertTo-Json -Depth 64 -Compress) + "`n"); Write-ReuseSelfUtf8 $planPath "tampered`n"
        $artifactRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge -ReusePath $receiptPath -ArtifactDirectory $artifacts) } catch { $artifactRejected = $true }; if (-not $artifactRejected) { throw 'Reuse self-test accepted tampered artifact bytes.' }
        Write-Host 'Affected-validation reuse self-test passed.'
    } finally { if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
    return
}

$root = [IO.Path]::GetFullPath($RepositoryRoot)
$artifacts = [IO.Path]::GetFullPath($ArtifactDirectory)
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force

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
$artifactIds = [Collections.Generic.HashSet[long]]::new()
foreach ($artifact in @($reuse.artifacts)) {
    $name = [string]$artifact.name
    if ($artifactByName.ContainsKey($name) -or -not $artifactIds.Add([long]$artifact.id)) { throw 'Reuse receipt repeats an artifact identity.' }
    $path = Join-Path $artifacts $name
    if (-not [IO.File]::Exists($path)) { throw "Reuse artifact is absent: $name" }
    if ((Get-ReuseFileHash $path) -cne [string]$artifact.sha256 -or (Get-Item -LiteralPath $path).Length -ne [long]$artifact.size) { throw "Reuse artifact bytes drifted: $name" }
    if ((Get-ReuseUtc -Value ([string]$artifact.expires_utc) -Name "artifact '$name' expiry") -le [DateTimeOffset]::UtcNow) { throw "Reuse artifact '$name' is expired." }
    $artifactByName[$name] = $artifact
}
if (-not $artifactByName.ContainsKey('affected-plan.json')) { throw 'Reuse receipt lacks the plan artifact.' }
$planArtifact = $artifactByName['affected-plan.json']
if ($planArtifact.platform -cne 'plan' -or $planArtifact.remote_name -cne $reuse.plan.artifact_name -or $reuse.plan.file_sha256 -cne $planArtifact.sha256) { throw 'Reuse plan artifact binding differs from its receipt.' }
$planPath = Join-Path $artifacts 'affected-plan.json'
$planRaw = Get-Content -LiteralPath $planPath -Raw
$planSchema = Join-Path $PSScriptRoot '..\schemas\affected-validation-plan-v1.schema.json'
if (-not (Test-Json -Json $planRaw -SchemaFile $planSchema -ErrorAction Stop)) { throw 'Reuse plan fails its closed schema.' }
$plan = $planRaw | ConvertFrom-Json -Depth 64
if ($plan.plan_sha256 -cne $reuse.plan.canonical_sha256 -or $planArtifact.remote_name -cne "affected-plan-$($plan.plan_sha256)") { throw 'Reuse plan digest domains are not exact.' }

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
            if ($evidence.result -cne 'pass' -or $evidence.repository -cne $plan.repository -or $evidence.repository -cne $reuse.repository -or $evidence.platform -cne $platform -or $evidence.base.commit -cne $before.commit -or $evidence.base.tree -cne $before.tree -or $evidence.head.commit -cne $candidate.commit -or $evidence.head.tree -cne $recomputed.head.tree -or $evidence.plan_sha256 -cne $reuse.plan.canonical_sha256 -or $artifact.remote_name -cne "affected-$platform-$($artifact.sha256)") { throw "Reuse '$platform' evidence does not bind its exact plan, platform, trees, and artifact." }
            $expectedIds = @($platformChecks | ForEach-Object { [string]$_.check_id })
            Assert-ReuseExactSet -Actual @($evidence.check_results | ForEach-Object { [string]$_.check_id }) -Expected $expectedIds -Name "$platform evidence check set"
            foreach ($result in @($evidence.check_results)) {
                $check = $checkMap[[string]$result.check_id]
                if ($null -eq $check) { throw "Reuse '$platform' result names an unknown check." }
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
