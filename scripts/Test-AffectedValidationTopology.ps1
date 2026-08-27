[CmdletBinding(DefaultParameterSetName = 'verify')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$RepositoryRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$BeforeCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$HeadCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'self')][switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($SelfTest) {
    function Invoke-TopologySelfGit([string]$Root, [string[]]$Arguments) { $value = & git -C $Root @Arguments 2>&1; if ($LASTEXITCODE -ne 0) { throw "Topology self-test git failure: $($value -join "`n")" }; return ($value -join "`n").Trim() }
    function Write-TopologySelfUtf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-topology-' + [Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($fixture)
    try {
        [void](Invoke-TopologySelfGit $fixture @('init', '--initial-branch=main')); [void](Invoke-TopologySelfGit $fixture @('config', 'user.name', 'Topology Test')); [void](Invoke-TopologySelfGit $fixture @('config', 'user.email', 'topology@example.invalid'))
        Write-TopologySelfUtf8 (Join-Path $fixture 'base.txt') "base`n"; [void](Invoke-TopologySelfGit $fixture @('add','.')); [void](Invoke-TopologySelfGit $fixture @('commit','-m','base')); $base = Invoke-TopologySelfGit $fixture @('rev-parse','HEAD')
        [void](Invoke-TopologySelfGit $fixture @('checkout','-b','candidate')); Write-TopologySelfUtf8 (Join-Path $fixture 'candidate.txt') "candidate`n"; [void](Invoke-TopologySelfGit $fixture @('add','.')); [void](Invoke-TopologySelfGit $fixture @('commit','-m','candidate')); $candidate = Invoke-TopologySelfGit $fixture @('rev-parse','HEAD')
        [void](Invoke-TopologySelfGit $fixture @('checkout','main')); Write-TopologySelfUtf8 (Join-Path $fixture 'main.txt') "main`n"; [void](Invoke-TopologySelfGit $fixture @('add','.')); [void](Invoke-TopologySelfGit $fixture @('commit','-m','main')); $before = Invoke-TopologySelfGit $fixture @('rev-parse','HEAD')
        [void](Invoke-TopologySelfGit $fixture @('merge','--no-ff','candidate','-m','merge candidate')); $merge = Invoke-TopologySelfGit $fixture @('rev-parse','HEAD')
        $attestation = & $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $before -HeadCommit $merge
        if ($attestation.mode -cne 'main-delta' -or $attestation.candidate.commit -cne $candidate -or [bool]$attestation.claims.reuse_eligible) { throw 'Topology self-test accepted a changed merge tree for reuse.' }
        $wrongBeforeRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge) } catch { $wrongBeforeRejected = $true }; if (-not $wrongBeforeRejected) { throw 'Topology self-test accepted a mismatched first parent.' }
        Write-Host 'Affected-validation topology self-test passed.'
    } finally { if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
    return
}
$root = [IO.Path]::GetFullPath($RepositoryRoot)
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
function Invoke-TopologyGit([string[]]$Arguments) {
    $value = & git -C $root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Topology attestation git failure: $($Arguments -join ' ')`n$($value -join "`n")" }
    return ($value -join "`n").Trim()
}
function Get-TopologyIdentity([string]$Revision) {
    $commit = Invoke-TopologyGit @('rev-parse', "$Revision^{commit}")
    $tree = Invoke-TopologyGit @('rev-parse', "$Revision^{tree}")
    return [pscustomobject][ordered]@{ commit=$commit; tree=$tree }
}

if ($BeforeCommit -notmatch '^[0-9a-f]{40}$' -or $HeadCommit -notmatch '^[0-9a-f]{40}$') { throw 'Topology attestation requires full lowercase commit identities.' }
$before = Get-TopologyIdentity $BeforeCommit
$head = Get-TopologyIdentity $HeadCommit
if ((Get-TopologyIdentity 'HEAD').commit -cne $head.commit) { throw 'Topology attestation requires the checked out HEAD to equal the supplied head.' }
$parentText = Invoke-TopologyGit @('show', '-s', '--format=%P', $head.commit)
$parents = @($parentText -split '\s+' | Where-Object { $_ })
$candidate = $null
$mode = 'main-delta'
if ($parents.Count -eq 2) {
    $firstParent = Get-TopologyIdentity $parents[0]
    $candidate = Get-TopologyIdentity $parents[1]
    if ($before.commit -cne $firstParent.commit) { throw 'Merge topology does not bind the event before commit to the first parent.' }
    if ($head.tree -ceq $candidate.tree) { $mode = 'exact-tree-premerge-reuse' }
} elseif ($parents.Count -eq 1) {
    $ancestor = & git -C $root merge-base --is-ancestor $before.commit $head.commit
    if ($LASTEXITCODE -ne 0) { throw 'Main delta topology requires before to be an ancestor of head.' }
} else { throw 'Topology attestation rejects root commits.' }
$attestation = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.affected_validation_topology_attestation.v1'
    before=$before
    head=$head
    mode=$mode
    candidate=$candidate
    claims=[pscustomobject][ordered]@{ reuse_eligible=($mode -ceq 'exact-tree-premerge-reuse'); historical_aggregate_reused=$false; acceptance_authority=$false; publication_authority=$false }
}
$json = ConvertTo-MorphospaceCanonicalJson -Value $attestation
$schema = Join-Path $PSScriptRoot '..\schemas\affected-validation-topology-attestation-v1.schema.json'
if (-not (Test-Json -Json $json -SchemaFile $schema -ErrorAction Stop)) { throw 'Topology attestation fails its closed schema.' }
$attestation
