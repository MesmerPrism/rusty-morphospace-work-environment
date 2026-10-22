[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$EvidencePath)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$selectorModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceNormalValidationSelector.psm1') -PassThru
$captureModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceRetainedBuildProcess.psm1') -PassThru
$automation=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru
$toolingModule=Import-Module (Join-Path $PSScriptRoot 'ToolingContextProvenance.psm1') -PassThru

# Keep exact module objects: downstream owner imports may legitimately reload
# Common and retire caller-global export bindings. These are private calls,
# never a caller-supplied trusted context or an alternate producer interface.
function Read-CurrentProtocolJson([string]$Path){&$protocolModule {param($p)Read-MorphospaceProtocolJson $p} $Path}
function Get-CurrentFileSha256([string]$Path){&$protocolModule {param($p)Get-MorphospaceFileSha256 $p} $Path}
function Get-CurrentCanonicalSha256([object]$Value){&$protocolModule {param($v)Get-MorphospaceCanonicalJsonSha256 $v} $Value}
function Resolve-CurrentWorkspacePath([string]$WorkspaceRoot,[string]$RelativePath,[switch]$RequireLeaf){&$protocolModule {param($w,$p,$leaf)Resolve-MorphospaceWorkspacePath -WorkspaceRoot $w -RelativePath $p -RequireLeaf:$leaf} $WorkspaceRoot $RelativePath ([bool]$RequireLeaf)}

function Write-CurrentEvidence([string]$Path,[object]$Value) {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 100))
    $stream=[IO.File]::Open($Path,'CreateNew','Write','None')
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Read-CurrentDispatch {
    $state=Read-CurrentProtocolJson (Join-Path $WorkspaceRoot 'workspace.state.json')
    if (-not ($state.PSObject.Properties.Name -ccontains 'normal_validation_selection') -or $null -eq $state.normal_validation_selection -or
        [string]$state.current_unit -cne [string]$state.normal_validation_selection.unit_id) { throw 'Current validation requires an actual selected BeginValidation binding.' }
    $selection=$state.normal_validation_selection
    $unit=Read-CurrentProtocolJson (Resolve-CurrentWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath "iteration-units/$($selection.unit_id).json" -RequireLeaf)
    if ([string]$unit.status -cne 'validating') { throw 'Current validation requires the live validating selected unit.' }
    $spec=Read-CurrentProtocolJson (Join-Path $WorkspaceRoot 'project.spec.json')
    $matrix=@(&$automation {param($u)New-MorphospaceValidationMatrix -Unit $u -DeviceSerials @()} $unit)
    $resolveArgs=@{WorkspaceRoot=$WorkspaceRoot;SelectorReference=$selection.selector_path;ExpectedSelectorSha256=$selection.selector_sha256;EvidencePath=$EvidencePath;Spec=$spec;Unit=$unit;DeclaredValidationMatrix=$matrix;Action='BeginValidation';ValidationTier=$selection.tier;BoundSelection=$selection}
    $resolved=&$selectorModule {param($p)Resolve-MorphospaceNormalValidationSelector @p} $resolveArgs
    if ((Get-CurrentCanonicalSha256 $resolved.state_binding) -cne (Get-CurrentCanonicalSha256 $selection)) { throw 'Current validation selected dispatch tuple drifted.' }
    $selector=Read-CurrentProtocolJson (Resolve-CurrentWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $selection.selector_path -RequireLeaf)
    if ([string]$selector.schema -cne 'rusty.morphospace.workflow.normal_validation_selector.v2') { throw 'Current validation requires the declared-tier v2 contract.' }
    if ((Get-CurrentFileSha256 (Join-Path $WorkspaceRoot $selector.unit.path)) -cne [string]$selector.unit.raw_sha256) { throw 'Current validation live producer unit raw bytes drifted from its selected dispatch.' }
    # Reuse only the observation just produced by this exact resolver call.
    # Nothing is caller-supplied or retained across the child boundary.
    $producer=$resolved.producer_observation
    if ($null -eq $producer) { throw 'Current validation has no authenticated bound producer observation.' }
    foreach($loaded in @($protocolModule,$selectorModule,$captureModule,$automation,$toolingModule)){
        &$toolingModule {param($context,$root,$owner)Assert-MorphospaceToolingContextLoadedOwnerModule -Context $context -ExecutorRoot $root -OwnerModule $owner} $producer.context $producer.executor_root $loaded|Out-Null
    }
    if ([IO.Path]::GetFullPath($PSCommandPath) -cne [IO.Path]::GetFullPath($producer.producer_path)) { throw 'Current validation is executing outside its fixed bound producer.' }
    $raw=[ordered]@{}
    foreach($relative in @('workspace.state.json','project.spec.json','iteration-events.jsonl','feature.lock.json',[string]$selector.unit.path,[string]$producer.binding.path,[string]$producer.context.product_projection.repository_map.path,[string]$producer.context.product_projection.source_composition.path)){
        $raw[$relative]=Get-CurrentFileSha256 (Resolve-CurrentWorkspacePath $WorkspaceRoot $relative -RequireLeaf)
    }
    $command=&$selectorModule {param($w,$p)Get-MorphospaceCurrentValidationCommand -WorkspaceRoot $w -ProducerObservation $p} $WorkspaceRoot $producer
    [pscustomobject]@{selection=$selection;selector=$selector;producer=$producer;raw=$raw;command=$command}
}
$WorkspaceRoot=[IO.Path]::GetFullPath($WorkspaceRoot)
$EvidencePath=[IO.Path]::GetFullPath($EvidencePath)
foreach($suffix in @('','.terminal.json','.stdout.bin','.stderr.bin')){if(Test-Path -LiteralPath ($EvidencePath+$suffix)){throw 'Current validation requires fresh evidence and raw capture paths.'}}
$before=Read-CurrentDispatch
$environment=@{};foreach($item in [Environment]::GetEnvironmentVariables().GetEnumerator()){$environment[[string]$item.Key]=[string]$item.Value}
$execution=[pscustomobject]@{FileName=(Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'}));WorkingDirectory=$WorkspaceRoot;Arguments=@($before.command.arguments)}
$terminal=&$captureModule {param($execution,$environment,$path)Invoke-MorphospaceRetainedBuildProcess -Execution $execution -EnvironmentValues $environment -BaseReceiptPath $path -EstimatedWarningSeconds 60} $execution $environment $EvidencePath
Write-CurrentEvidence ($EvidencePath+'.terminal.json') $terminal
# The same live owner/source/raw checks run after the settled child; no cross-command cache grants authority.
$after=Read-CurrentDispatch
if ((Get-CurrentCanonicalSha256 $before) -cne (Get-CurrentCanonicalSha256 $after)) { throw 'Current validation live dispatch/source/context drifted while the child ran.' }
$selector=$before.selector
$evidence=[ordered]@{schema='rusty.morphospace.workflow.current_validation_evidence.v1';project_id=$selector.project.project_id;unit_id=$selector.unit.unit_id;tier=$selector.selection.tier;workspace_root=$WorkspaceRoot;selection=$before.selection;project_raw_sha256=$selector.project.spec_raw_sha256;declared_command_sha256=$selector.declared_gate.command_sha256;freeze_receipt_sha256=$selector.candidate_freeze.receipt_sha256;frozen_repositories=@($selector.candidate_freeze.final_repositories);tooling_context=$before.producer.binding;executor_commit=$before.producer.context.executor.commit;executor_tree=$before.producer.context.executor.tree;executed_command=$before.command;terminal=[ordered]@{path=$EvidencePath+'.terminal.json';sha256=Get-CurrentFileSha256 ($EvidencePath+'.terminal.json');capture=$terminal};result=$(if($terminal.Status -ceq 'passed'){'pass'}else{'fail'});does_not_authorize=@('No build, device, publication or inherited product acceptance authority.')}
Write-CurrentEvidence $EvidencePath $evidence
&$selectorModule {param($w,$path,$s,$selection,$producer)Assert-MorphospaceCurrentValidationEvidence -WorkspaceRoot $w -EvidencePath $path -Selector $s -Selection $selection -ProducerObservation $producer} $WorkspaceRoot $EvidencePath $selector $before.selection $before.producer
if($terminal.Status -cne 'passed'){throw 'Current validation child failed; authenticated non-passing evidence and raw closure are retained.'}
Write-Output $EvidencePath
