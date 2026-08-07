param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$SourceRepository,
    [Parameter(Mandatory)][string]$PlanningRepository,
    [string]$Timestamp = '',
    [ValidateRange(0,5000)][int]$ObservationDelayMilliseconds = 0,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
$MaxInputBytes=1MB;$MaxFiles=512;$MaxFileBytes=4MB;$MaxAggregateBytes=32MB
$MaxJsonDepth=32;$MaxJsonlRecords=4096;$MaxJsonlLineBytes=256KB

if($IsWindows -and -not ('MorphospacePhysicalIdentityV1' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class MorphospacePhysicalIdentityV1 {
  [StructLayout(LayoutKind.Sequential)] public struct FILE_ID_128 { [MarshalAs(UnmanagedType.ByValArray, SizeConst=16)] public byte[] Identifier; }
  [StructLayout(LayoutKind.Sequential)] public struct FILE_ID_INFO { public UInt64 VolumeSerialNumber; public FILE_ID_128 FileId; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass, out FILE_ID_INFO info, uint size);
  public static string GetDirectoryIdentity(string path) {
    using(var handle=CreateFileW(path,0,0x00000001|0x00000002|0x00000004,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
      if(handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateFileW directory identity failed");
      FILE_ID_INFO info; if(!GetFileInformationByHandleEx(handle,18,out info,(uint)Marshal.SizeOf<FILE_ID_INFO>())) throw new Win32Exception(Marshal.GetLastWin32Error(),"GetFileInformationByHandleEx(FileIdInfo) failed");
      return info.VolumeSerialNumber.ToString("x16")+":"+BitConverter.ToString(info.FileId.Identifier).Replace("-","").ToLowerInvariant();
    }
  }
}
'@
}

function Invoke-GitReadOnly { param([string]$Repository,[string[]]$Arguments)
    $output=@(& git -C $Repository -c core.fsmonitor=false -c core.autocrlf=false @Arguments 2>&1|ForEach-Object{[string]$_})
    if($LASTEXITCODE-ne0){throw "Git inspection failed: git $($Arguments-join' ')`n$($output-join"`n")"};@($output)
}
function Get-Sha256File { param([string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))).ToLowerInvariant()}finally{$stream.Dispose()}
}
function Get-Sha256Text { param([string]$Text) ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant() }
function ConvertTo-CanonicalJson { param($Value) ($Value|ConvertTo-Json -Depth $MaxJsonDepth -Compress) }
function Read-BoundedUtf8 { param([string]$Path,[int64]$Maximum,[string]$Label)
    $item=Get-Item -LiteralPath $Path -Force
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$item.Length-gt$Maximum){throw "$Label is not a bounded regular file."}
    $stream=[IO.File]::Open($item.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true);try{$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$stream.Dispose()}
}
function Test-PortableRelativePath { param([string]$Path,[string]$Label)
    if([string]::IsNullOrWhiteSpace($Path)-or[IO.Path]::IsPathRooted($Path)-or$Path.Contains('\')-or$Path.Contains(':')-or$Path.Length-gt512){throw "$Label is not a portable relative path."}
    $reserved='^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)'
    $parts=@($Path.Split('/'));if($parts.Count-eq0){throw "$Label is empty."}
    foreach($part in $parts){if($part-ceq''-or$part-ceq'.'-or$part-ceq'..'-or$part-match'[\x00-\x1f]'-or$part-ieq'.git'-or$part.EndsWith('.')-or$part.EndsWith(' ')-or$part-match$reserved){throw "$Label contains a forbidden or Windows-equivalent segment."}}
}
function Get-NormalizedPortableKey { param([string]$Path) (($Path.Split('/')|ForEach-Object{$_.TrimEnd(' ','.').ToUpperInvariant()})-join'/') }
function Assert-SingleLinkFile { param([string]$Path)
    if($IsWindows){$links=@(& fsutil hardlink list $Path 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "Cannot establish hard-link count for source file: $Path"};if($links.Count-ne1){throw "Workspace file has multiple hard links: $Path"}}
    else{$count=([string]@(& stat -c '%h' -- $Path 2>&1)[0]).Trim();if($LASTEXITCODE-ne0-or$count-cne'1'){throw "Workspace file hard-link count is unsafe or unavailable: $Path"}}
}
function Assert-SafeExistingItem { param([string]$Path,[bool]$RequireDirectory=$true)
    $item=Get-Item -LiteralPath $Path -Force
    if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Path contains a reparse point: $Path"}
    if($RequireDirectory-and-not$item.PSIsContainer){throw "Path component is not a directory: $Path"}
    if(-not$RequireDirectory-and($item.PSIsContainer-or-not($item-is[IO.FileInfo]))){throw "Path is not a regular file: $Path"}
}
function Get-PhysicalDirectoryIdentity { param([string]$Path)
    if(-not$IsWindows){throw 'Stable physical directory identity is unavailable: execution requires Windows FileIdInfo support.'}
    try{[MorphospacePhysicalIdentityV1]::GetDirectoryIdentity([IO.Path]::GetFullPath($Path))}catch{throw "Stable physical directory identity failed for a bounded directory: $($_.Exception.Message)"}
}
function New-IdentityBinding { param([string]$Label,[string]$Path) [pscustomobject]@{label=$Label;path=[IO.Path]::GetFullPath($Path).TrimEnd('\','/');identity=Get-PhysicalDirectoryIdentity $Path} }
function Assert-IdentityBindings { param([object[]]$Bindings,[string]$Checkpoint)
    foreach($binding in @($Bindings)){if(-not[IO.Directory]::Exists([string]$binding.path)){throw "$Checkpoint physical identity path disappeared: $($binding.label)"};$actual=Get-PhysicalDirectoryIdentity ([string]$binding.path);if($actual-cne[string]$binding.identity){throw "$Checkpoint physical identity changed: $($binding.label)"}}
}
function Get-ExistingAncestorBindings { param([string]$Root,[string]$Target)
    $bindings=[Collections.Generic.List[object]]::new();$rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$targetFull=[IO.Path]::GetFullPath($Target).TrimEnd('\','/');$current=$rootFull;$index=0
    if($targetFull-ceq$rootFull){return @($bindings)};$relative=$targetFull.Substring($rootFull.Length+1)
    foreach($part in @($relative.Split([IO.Path]::DirectorySeparatorChar,[StringSplitOptions]::RemoveEmptyEntries))){$current=Join-Path $current $part;if(-not[IO.Directory]::Exists($current)){break};$bindings.Add((New-IdentityBinding "destination-ancestor-$index" $current));$index++};@($bindings)
}
function Assert-SafePathChain { param([string]$Root,[string]$Target,[switch]$AllowMissingLeaf)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$targetFull=[IO.Path]::GetFullPath($Target).TrimEnd('\','/')
    Assert-SafeExistingItem $rootFull
    if($targetFull-ceq$rootFull){return}
    $prefix=$rootFull+[IO.Path]::DirectorySeparatorChar;if(-not$targetFull.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Path escapes its declared repository root.'}
    $current=$rootFull;$missing=$false
    foreach($segment in @($targetFull.Substring($prefix.Length).Split([IO.Path]::DirectorySeparatorChar,[StringSplitOptions]::RemoveEmptyEntries))){
        Test-PortableRelativePath $segment 'Filesystem path segment'
        if($missing){$current=Join-Path $current $segment;continue}
        $matches=@(Get-ChildItem -LiteralPath $current -Force|Where-Object{$_.Name.TrimEnd(' ','.')-ieq$segment.TrimEnd(' ','.')})
        if($matches.Count -gt 1 -or ($matches.Count -eq 1 -and $matches[0].Name -cne $segment)){throw 'Filesystem path has an equivalent or case-normalized collision.'}
        $next=Join-Path $current $segment
        if(Test-Path -LiteralPath $next){Assert-SafeExistingItem $next}else{if(-not$AllowMissingLeaf){throw "Required path component is absent: $next"};$missing=$true;$current=$next;continue}
        $current=$next
    }
}
function Get-RepositoryIdentity { param([string]$Repository)
    $requested=[IO.Path]::GetFullPath($Repository).TrimEnd('\','/');Assert-SafeExistingItem $requested
    $root=[IO.Path]::GetFullPath(([string]@(Invoke-GitReadOnly $requested @('rev-parse','--show-toplevel'))[0]).Trim()).TrimEnd('\','/')
    if($root-cne$requested){if($IsWindows-and(Get-PhysicalDirectoryIdentity $root)-ceq(Get-PhysicalDirectoryIdentity $requested)){$root=$requested}else{throw 'Repository path must be the exact Git worktree root.'}};Assert-SafePathChain $root $root
    $branch=([string]@(Invoke-GitReadOnly $root @('symbolic-ref','--quiet','--short','HEAD'))[0]).Trim()
    $head=([string]@(Invoke-GitReadOnly $root @('rev-parse','HEAD'))[0]).Trim().ToLowerInvariant();$tree=([string]@(Invoke-GitReadOnly $root @('rev-parse','HEAD^{tree}'))[0]).Trim().ToLowerInvariant()
    $common=[IO.Path]::GetFullPath(([string]@(Invoke-GitReadOnly $root @('rev-parse','--git-common-dir'))[0]).Trim(),$root).TrimEnd('\','/')
    [ordered]@{root=$root;resolved=(Resolve-Path -LiteralPath $root).Path.TrimEnd('\','/');branch=$branch;head=$head;tree=$tree;common=$common}
}
function Get-WorkspaceInventory { param([string]$Workspace)
    Assert-SafePathChain $Workspace $Workspace
    $items=@(Get-ChildItem -LiteralPath $Workspace -Force -Recurse);$files=[Collections.Generic.List[object]]::new();$total=[int64]0
    foreach($item in $items){
        if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Workspace contains a reparse point: $($item.FullName)"}
        if($item.PSIsContainer){continue};if(-not($item-is[IO.FileInfo])){throw "Workspace contains a non-regular file: $($item.FullName)"}
        Assert-SingleLinkFile $item.FullName;if($item.Length-gt$MaxFileBytes){throw 'Workspace file exceeds the per-file byte bound.'};$total+=$item.Length
        if($total-gt$MaxAggregateBytes){throw 'Workspace exceeds the aggregate byte bound.'};if($files.Count-ge$MaxFiles){throw 'Workspace exceeds the inventory item bound.'}
        $relative=$item.FullName.Substring($Workspace.TrimEnd('\','/').Length+1).Replace('\','/');Test-PortableRelativePath $relative 'Inventory path'
        $files.Add([ordered]@{path=$relative;type='file';size=[int64]$item.Length;sha256=Get-Sha256File $item.FullName})
    }
    if($files.Count-eq0){throw 'Selected source workspace inventory is empty.'}
    $ordered=@($files|Sort-Object -Property @{Expression={$_.path};Ascending=$true});$keys=@($ordered|ForEach-Object{Get-NormalizedPortableKey $_.path})
    if(@($keys|Group-Object|Where-Object Count -gt 1).Count -ne 0){throw 'Workspace has equivalent or case-ambiguous paths.'}
    for($i=0;$i-lt$ordered.Count;$i++){$ordered[$i]=[ordered]@{ordinal=$i;path=$ordered[$i].path;type='file';size=$ordered[$i].size;sha256=$ordered[$i].sha256}}
    @($ordered)
}
function Test-JsonWorkspace { param([string]$Workspace,[object[]]$Inventory)
    foreach($row in @($Inventory)){$path=Join-Path $Workspace ([string]$row.path)
        if([string]$row.path-match'\.json$'){$raw=Read-BoundedUtf8 $path $MaxFileBytes 'Workspace JSON';try{$doc=$raw|ConvertFrom-Json -Depth $MaxJsonDepth -ErrorAction Stop}catch{throw "Invalid or over-depth JSON: $($row.path)"};if(-not$doc.PSObject.Properties['schema']-or[string]$doc.schema-notmatch'^rusty\.morphospace\.workflow\.[a-z0-9_.-]+\.v[0-9]+$'){throw "Invalid or absent workflow schema ID: $($row.path)"}}
        elseif([string]$row.path-match'\.jsonl$'){$count=0;$lines=[IO.File]::ReadLines($path).GetEnumerator();try{while($lines.MoveNext()){$line=[string]$lines.Current;$count++;if($count-gt$MaxJsonlRecords){throw 'JSONL record bound exceeded.'};if([Text.Encoding]::UTF8.GetByteCount($line)-gt$MaxJsonlLineBytes){throw 'JSONL line byte bound exceeded.'};if([string]::IsNullOrWhiteSpace($line)){throw 'Blank JSONL record.'};try{$null=$line|ConvertFrom-Json -Depth $MaxJsonDepth -ErrorAction Stop}catch{throw 'Invalid or over-depth JSONL record.'}}}finally{if($lines-is[IDisposable]){$lines.Dispose()}}}
    }
}
function Assert-InventoryEqual { param([object[]]$Expected,[object[]]$Actual,[string]$Label) if((ConvertTo-CanonicalJson @($Expected))-cne(ConvertTo-CanonicalJson @($Actual))){throw "$Label inventory differs from the signed-off input."} }
function Test-PinnedTreeInventoryEqual { param([string]$Repository,[object[]]$Inventory)
    $treePaths=@(Invoke-GitReadOnly $Repository @('ls-tree','-r','--name-only','HEAD','--','morphospace')|ForEach-Object{if($_.StartsWith('morphospace/')){$_.Substring(12)}})
    $livePaths=@($Inventory|ForEach-Object{[string]$_.path});if((ConvertTo-CanonicalJson $treePaths)-cne(ConvertTo-CanonicalJson $livePaths)){return $false}
    & git -C $Repository -c core.fsmonitor=false -c core.autocrlf=false diff --quiet --no-ext-diff HEAD -- morphospace
    if($LASTEXITCODE-eq0){return $true};if($LASTEXITCODE-eq1){return $false};throw 'Git tree comparison failed.'
}
function Test-PlanningStatusOwnedStage { param([string]$Repository,[string]$Stage)
    $relative=$Stage.Substring($Repository.TrimEnd('\','/').Length+1).Replace('\','/')+'/';foreach($row in @(Invoke-GitReadOnly $Repository @('status','--porcelain=v1','--untracked-files=all'))){if($row.Length-lt4-or-not$row.Substring(3).Replace('\','/').StartsWith($relative,[StringComparison]::Ordinal)){return $false}};$true
}
function New-OwnedParents { param([string]$Root,[string]$Parent)
    $created=[Collections.Generic.List[string]]::new();$relative=$Parent.Substring($Root.TrimEnd('\','/').Length+1);$current=$Root
    foreach($part in @($relative.Split([IO.Path]::DirectorySeparatorChar,[StringSplitOptions]::RemoveEmptyEntries))){$next=Join-Path $current $part;if(-not(Test-Path -LiteralPath $next)){[IO.Directory]::CreateDirectory($next)|Out-Null;$created.Add($next)};Assert-SafeExistingItem $next;$current=$next};@($created)
}

$repoRoot=Split-Path -Parent $PSScriptRoot;$inputSchema=Join-Path $repoRoot 'schemas\unpublished-workspace-materialization-v1.schema.json';$receiptSchema=Join-Path $repoRoot 'schemas\unpublished-planning-authority-receipt-v1.schema.json'
$inputFull=[IO.Path]::GetFullPath($InputPath);if(-not[IO.File]::Exists($inputFull)){throw 'Materialization input does not exist.'};$inputRaw=Read-BoundedUtf8 $inputFull $MaxInputBytes 'Materialization input'
try{$inputDocument=$inputRaw|ConvertFrom-Json -Depth $MaxJsonDepth -ErrorAction Stop}catch{throw 'Materialization input is invalid or exceeds JSON depth.'};if(-not($inputRaw|Test-Json -SchemaFile $inputSchema -ErrorAction Stop)){throw 'Materialization input fails its schema.'}
foreach($path in @([string]$inputDocument.source.workspace_path,[string]$inputDocument.source.state_anchor.path,[string]$inputDocument.planning.destination_workspace_path,[string]$inputDocument.planning.receipt_path)){Test-PortableRelativePath $path 'Input path'}
$source=Get-RepositoryIdentity ([IO.Path]::GetFullPath($SourceRepository).TrimEnd('\','/'));$planning=Get-RepositoryIdentity ([IO.Path]::GetFullPath($PlanningRepository).TrimEnd('\','/'))
$identityBindings=@();if($IsWindows){$identityBindings=@((New-IdentityBinding 'source-repository-root' $source.root),(New-IdentityBinding 'source-git-common-directory' $source.common),(New-IdentityBinding 'planning-repository-root' $planning.root),(New-IdentityBinding 'planning-git-common-directory' $planning.common));$sourceIds=@($identityBindings[0].identity,$identityBindings[1].identity);$planningIds=@($identityBindings[2].identity,$identityBindings[3].identity);if(@($sourceIds|Where-Object{$planningIds-contains$_}).Count-ne0){throw 'Source and planning repositories resolve to the same physical repository or Git authority.'}}
elseif($Execute){throw 'Stable physical directory identity is unavailable: execution requires Windows FileIdInfo support.'}
if($source.common-ieq$planning.common-or$source.resolved-ieq$planning.resolved){throw 'Source and planning repositories must have distinct resolved filesystem and Git authority.'};if([string]$inputDocument.source.repo_id-ceq[string]$inputDocument.planning.repo_id){throw 'Portable repository identities must be distinct.'}
if($source.head-cne[string]$inputDocument.source.head-or$source.tree-cne[string]$inputDocument.source.tree-or$source.branch-cne[string]$inputDocument.source.branch){throw 'Source repository identity differs from input.'};if($planning.head-cne[string]$inputDocument.planning.base_commit-or$planning.tree-cne[string]$inputDocument.planning.base_tree-or$planning.branch-cne[string]$inputDocument.planning.branch){throw 'Planning repository identity differs from input.'}
if(@(Invoke-GitReadOnly $planning.root @('status','--porcelain=v1','--untracked-files=all')).Count-ne0){throw 'Planning repository must be clean.'}
$sourceWorkspace=Join-Path $source.root 'morphospace';$destination=[IO.Path]::GetFullPath((Join-Path $planning.root ([string]$inputDocument.planning.destination_workspace_path)).TrimEnd('\','/'));$parent=Split-Path -Parent $destination
Assert-SafePathChain $source.root $sourceWorkspace;Assert-SafePathChain $planning.root $parent -AllowMissingLeaf
$ancestorBindings=if($IsWindows){@(Get-ExistingAncestorBindings $planning.root $parent)}else{@()};$identityBindings=@($identityBindings)+@($ancestorBindings)
if($sourceWorkspace.StartsWith($destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or$destination.StartsWith($sourceWorkspace+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or$sourceWorkspace-ieq$destination){throw 'Source and destination overlap.'};if(Test-Path -LiteralPath $destination){throw 'Destination already exists.'}
$expected=@($inputDocument.source.inventory);$declaredTotal=[int64]0;for($i=0;$i-lt$expected.Count;$i++){if([int]$expected[$i].ordinal-ne$i){throw 'Inventory ordinals must be contiguous.'};$declaredTotal+=[int64]$expected[$i].size};if($declaredTotal-gt$MaxAggregateBytes){throw 'Declared inventory exceeds aggregate byte bound.'}
$observed1=@(Get-WorkspaceInventory $sourceWorkspace);Assert-InventoryEqual $expected $observed1 'First source observation';Test-JsonWorkspace $sourceWorkspace $observed1
$anchor=@($observed1|Where-Object{$_.path-ceq'workspace.state.json'});if($anchor.Count-ne1-or$anchor[0].sha256-cne[string]$inputDocument.source.state_anchor.sha256){throw 'Exact workspace.state.json anchor differs from input.'}
$stateRaw=Read-BoundedUtf8 (Join-Path $sourceWorkspace 'workspace.state.json') $MaxFileBytes 'Workspace state';$state=$stateRaw|ConvertFrom-Json -Depth $MaxJsonDepth -ErrorAction Stop;if([string]$state.project_id-cne[string]$inputDocument.project_id-or[string]$state.schema-notmatch'^rusty\.morphospace\.workflow\.workspace_state\.v[12]$'){throw 'Workspace state does not bind the input project and supported state schema.'}
$pathStatus=@(Invoke-GitReadOnly $source.root @('status','--porcelain=v1','--untracked-files=all','--ignored=matching','--','morphospace'));if($pathStatus.Count-eq0){throw 'Selected morphospace is not dirty relative to the pinned source Git state.'};if(Test-PinnedTreeInventoryEqual $source.root $observed1){throw 'Selected bytes equal the pinned Git tree and are projection-eligible.'}
if(@($expected|Where-Object{$_.path-ceq[string]$inputDocument.planning.receipt_path}).Count-ne0){throw 'Receipt path collides with a workspace file.'};if($ObservationDelayMilliseconds-gt0){Start-Sleep -Milliseconds $ObservationDelayMilliseconds};$observed2=@(Get-WorkspaceInventory $sourceWorkspace);Assert-InventoryEqual $observed1 $observed2 'Repeated source observation'
$route=[ordered]@{workspace_scope='repository-root-morphospace';state_anchor='workspace.state.json';source_path_dirty=$true;pinned_tree_inventory_equal=$false;planning_workspace_projection_applicable=$false}
$plan=[ordered]@{schema='rusty.morphospace.workflow.unpublished_planning_authority_plan.v1';materialization_id=[string]$inputDocument.materialization_id;route_eligibility=$route;source_inventory=@($observed2);destination_workspace_path=[string]$inputDocument.planning.destination_workspace_path;receipt_path=[string]$inputDocument.planning.receipt_path;execute_required=$true};if(-not$Execute){ConvertTo-CanonicalJson $plan;return}
$createdParents=@();$stage=$null;$installed=$false
try{Assert-IdentityBindings $identityBindings 'Before staging';$createdParents=@(New-OwnedParents $planning.root $parent);Assert-SafePathChain $planning.root $parent;$parentBinding=New-IdentityBinding 'staging-parent' $parent;$stage=Join-Path $parent ('.'+[IO.Path]::GetFileName($destination)+'.materializing-'+[guid]::NewGuid().ToString('N'));if([IO.Path]::GetPathRoot($parent)-cne[IO.Path]::GetPathRoot($stage)){throw 'Stage is not same-volume.'};[IO.Directory]::CreateDirectory($stage)|Out-Null;Assert-SafePathChain $planning.root $stage;$stageBinding=New-IdentityBinding 'owned-stage' $stage
    foreach($row in $observed2){$target=Join-Path $stage ([string]$row.path);$targetParent=Split-Path -Parent $target;[IO.Directory]::CreateDirectory($targetParent)|Out-Null;Assert-SafePathChain $stage $targetParent;[IO.File]::Copy((Join-Path $sourceWorkspace ([string]$row.path)),$target,$false)}
    if($ObservationDelayMilliseconds-gt0){Start-Sleep -Milliseconds $ObservationDelayMilliseconds};$staged=@(Get-WorkspaceInventory $stage);Assert-InventoryEqual $expected $staged 'Staged destination';$inputHash=Get-Sha256Text $inputRaw;$inventoryHash=Get-Sha256Text (ConvertTo-CanonicalJson @($expected));if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('o')}
    $receipt=[ordered]@{'$schema'='../../../../schemas/unpublished-planning-authority-receipt-v1.schema.json';schema='rusty.morphospace.workflow.unpublished_planning_authority_receipt.v1';materialization_id=[string]$inputDocument.materialization_id;project_id=[string]$inputDocument.project_id;recorded_at=$Timestamp;status='materialized-and-read-back';input=[ordered]@{schema=[string]$inputDocument.schema;sha256=$inputHash};source=[ordered]@{repo_id=[string]$inputDocument.source.repo_id;head=$source.head;tree=$source.tree;branch=$source.branch;workspace_path='morphospace';inventory_sha256=$inventoryHash;state_anchor=[ordered]@{path='workspace.state.json';sha256=[string]$inputDocument.source.state_anchor.sha256}};planning=[ordered]@{repo_id=[string]$inputDocument.planning.repo_id;base_commit=$planning.head;base_tree=$planning.tree;branch=$planning.branch;destination_workspace_path=[string]$inputDocument.planning.destination_workspace_path;receipt_path=[string]$inputDocument.planning.receipt_path};destination_inventory=@($staged);route_eligibility=$route;authority=[ordered]@{destination_workspace='sole-workspace-authority';source_workspace='preserved-historical-non-authoritative';source_bytes_preserved=$true;git_mutation_performed=$false};limitations=[ordered]@{ordinary_admission_required=$true;publication_projection='not-applicable';does_not_claim=@('workflow admission','state transition','validation','acceptance','source publication','remote operation','planning_workspace_projection v1-v3')}}
    $receiptTarget=Join-Path $stage ([string]$inputDocument.planning.receipt_path);[IO.Directory]::CreateDirectory((Split-Path -Parent $receiptTarget))|Out-Null;[IO.File]::WriteAllText($receiptTarget,(ConvertTo-CanonicalJson $receipt)+"`n",[Text.UTF8Encoding]::new($false));$receiptRaw=Read-BoundedUtf8 $receiptTarget $MaxFileBytes 'Generated receipt';if(-not($receiptRaw|Test-Json -SchemaFile $receiptSchema -ErrorAction Stop)){throw 'Generated receipt fails its schema.'}
    if($ObservationDelayMilliseconds-gt0){Start-Sleep -Milliseconds $ObservationDelayMilliseconds};$finalSource=@(Get-WorkspaceInventory $sourceWorkspace);Assert-InventoryEqual $expected $finalSource 'Final source observation';$sourceFinal=Get-RepositoryIdentity $source.root;$planningFinal=Get-RepositoryIdentity $planning.root
    if($sourceFinal.head-cne$source.head-or$sourceFinal.tree-cne$source.tree-or$sourceFinal.branch-cne$source.branch){throw 'Source identity drifted before commit point.'};if($planningFinal.head-cne$planning.head-or$planningFinal.tree-cne$planning.tree-or$planningFinal.branch-cne$planning.branch-or-not(Test-PlanningStatusOwnedStage $planning.root $stage)){throw 'Planning repository drifted before commit point.'};Assert-IdentityBindings (@($identityBindings)+@($parentBinding,$stageBinding)) 'Commit point';Assert-SafePathChain $planning.root $parent;if(Test-Path -LiteralPath $destination){throw 'Destination appeared before atomic install.'}
    [IO.Directory]::Move($stage,$destination);$installed=$true;if((Get-PhysicalDirectoryIdentity $destination)-cne[string]$stageBinding.identity){throw 'Installed destination does not retain the staged physical directory identity.'};if($ObservationDelayMilliseconds-gt0){Start-Sleep -Milliseconds $ObservationDelayMilliseconds};Assert-SafePathChain $planning.root $destination;Assert-IdentityBindings (@($identityBindings)+@($parentBinding)) 'Installed readback';if((Get-PhysicalDirectoryIdentity $destination)-cne[string]$stageBinding.identity){throw 'Installed destination physical identity changed before readback.'}
    $readbackReceipt=Join-Path $destination ([string]$inputDocument.planning.receipt_path);$readbackRaw=Read-BoundedUtf8 $readbackReceipt $MaxFileBytes 'Installed receipt';if($readbackRaw-cne$receiptRaw-or-not($readbackRaw|Test-Json -SchemaFile $receiptSchema -ErrorAction Stop)){throw 'Installed receipt readback differs or fails schema.'};$readback=@(Get-WorkspaceInventory $destination|Where-Object{$_.path-cne[string]$inputDocument.planning.receipt_path});for($i=0;$i-lt$readback.Count;$i++){$readback[$i].ordinal=$i};Assert-InventoryEqual $expected $readback 'Installed destination readback';Assert-IdentityBindings (@($identityBindings)+@($parentBinding)) 'Final readback';if((Get-PhysicalDirectoryIdentity $destination)-cne[string]$stageBinding.identity){throw 'Installed destination physical identity changed during final readback.'};ConvertTo-CanonicalJson $receipt
}catch{if($installed-and[IO.Directory]::Exists($destination)){Remove-Item -LiteralPath $destination -Recurse -Force};if($stage-and[IO.Directory]::Exists($stage)){Remove-Item -LiteralPath $stage -Recurse -Force};foreach($created in @($createdParents|Sort-Object Length -Descending)){if([IO.Directory]::Exists($created)-and@(Get-ChildItem -LiteralPath $created -Force).Count-eq0){Remove-Item -LiteralPath $created -Force}};throw}
