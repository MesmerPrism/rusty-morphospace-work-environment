[CmdletBinding(DefaultParameterSetName = 'verify')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$RepositoryRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$BeforeCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$HeadCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'self')][switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function Assert-ValidateWorkflowContract([string]$Workflow) {
    $parts=[regex]::Split($Workflow,'(?m)^jobs:\r?$');if($parts.Count-ne2){throw 'Validate workflow must contain exactly one jobs mapping.'};$jobText=$parts[1]
    [string[]]$jobs=@([regex]::Matches($jobText,'(?m)^  ([a-z0-9-]+):\r?$')|ForEach-Object{$_.Groups[1].Value})
    $expected=@('infrastructure','select','affected-linux-segments','quick-linux','affected-windows-segments','standard-windows','quick-windows','post-merge-attestation','main-linux-segments','main-windows-segments','main-linux-delta','main-windows-delta','deep')
    if(($jobs-join',')-cne($expected-join',')){throw "Validate workflow job set/order is not exact: $($jobs-join',')"}
    $needs=@{infrastructure=@();select=@('infrastructure');'affected-linux-segments'=@('infrastructure','select');'quick-linux'=@('infrastructure','select','affected-linux-segments');'affected-windows-segments'=@('infrastructure','select');'standard-windows'=@('infrastructure','select','affected-windows-segments');'quick-windows'=@('infrastructure','select','standard-windows');'post-merge-attestation'=@('select');'main-linux-segments'=@('select','post-merge-attestation');'main-windows-segments'=@('select','post-merge-attestation');'main-linux-delta'=@('select','post-merge-attestation','main-linux-segments');'main-windows-delta'=@('select','post-merge-attestation','main-windows-segments');deep=@('infrastructure','select','quick-linux','standard-windows')}
    for($index=0;$index-lt$jobs.Count;$index++){$name=$jobs[$index];$start=$jobText.IndexOf("  ${name}:",[StringComparison]::Ordinal);$end=if($index+1-lt$jobs.Count){$jobText.IndexOf("  $($jobs[$index+1]):",$start+1,[StringComparison]::Ordinal)}else{$jobText.Length};$body=$jobText.Substring($start,$end-$start);$observed=@();$match=[regex]::Match($body,'(?m)^    needs: (.+)\r?$');if($match.Success){$raw=$match.Groups[1].Value.Trim();$observed=if($raw.StartsWith('[')){@($raw.Trim('[',']')-split ',\s*')}else{@($raw)}};if(($observed-join',')-cne(@($needs[$name])-join',')){throw "Validate workflow needs for '$name' are not exact."};foreach($dependency in $observed){if([Array]::IndexOf($jobs,$dependency)-ge$index){throw "Validate workflow edge is not strictly downward: $name -> $dependency"}};if($body-cnotmatch'(?m)^    timeout-minutes: (?:[1-9][0-9]*|\$\{\{ matrix\.timeout_minutes \}\})\r?$'){throw "Validate workflow job '$name' has no explicit bounded outer timeout."}}
    if($Workflow-cmatch'uses:\s*[^\r\n]*validate\.yml'){throw 'Validate workflow recursively invokes itself as a reusable workflow.'}
    foreach($fragment in @("format('validate-pr-{0}', github.event.pull_request.number)","format('validate-main-{0}', github.ref)","'validate-deep-schedule-manual'","cancel-in-progress: `${{ github.event_name == 'pull_request' }}",'estimated_budget_seconds+900','if($outer-ge360)','phase=''setup''','phase=''plan''','phase=''main-fallback''','FileMode]::CreateNew','bytes.Length-gt65536')){if(-not$Workflow.Contains($fragment)){throw "Validate workflow is missing required bounded/concurrency fragment '$fragment'."}}
}
if ($SelfTest) {
    function Invoke-TopologySelfGit([string]$Root, [string[]]$Arguments) { $value = & git -C $Root @Arguments 2>&1; if ($LASTEXITCODE -ne 0) { throw "Topology self-test git failure: $($value -join "`n")" }; return ($value -join "`n").Trim() }
    function Write-TopologySelfUtf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-topology-' + [Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($fixture)
    try {
        $currentWorkflow=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\.github\workflows\validate.yml'),[Text.UTF8Encoding]::new($false,$true));Assert-ValidateWorkflowContract $currentWorkflow
        $damages=[ordered]@{edge=$currentWorkflow.Replace('needs: infrastructure','needs: deep');concurrency=$currentWorkflow.Replace("'validate-deep-schedule-manual'","format('validate-deep-{0}', github.run_id)");timeout=$currentWorkflow.Replace('timeout-minutes: 10','timeout-minutes-removed: 10');recursion=$currentWorkflow.Replace('uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1','uses: ./.github/workflows/validate.yml')}
        foreach($damageName in $damages.Keys){$rejected=$false;try{Assert-ValidateWorkflowContract ([string]$damages[$damageName])}catch{$rejected=$true};if(-not$rejected){throw "Validate workflow contract self-test accepted $damageName damage."}}
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
$workflowPath=Join-Path $root '.github\workflows\validate.yml';if([IO.File]::Exists($workflowPath)){Assert-ValidateWorkflowContract ([IO.File]::ReadAllText($workflowPath,[Text.UTF8Encoding]::new($false,$true)))}
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
