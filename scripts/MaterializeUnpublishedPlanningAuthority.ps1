param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$SourceRepository,
    [Parameter(Mandatory)][string]$PlanningRepository,
    [string]$Timestamp = '',
    [ValidateRange(0,5000)][int]$ObservationDelayMilliseconds = 0,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

function Invoke-GitReadOnly {
    param([string]$Repository, [string[]]$Arguments)
    $output = @(& git -C $Repository -c core.fsmonitor=false -c core.autocrlf=false @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "Git inspection failed: git $($Arguments -join ' ')`n$($output -join "`n")" }
    @($output)
}

function Get-Sha256Bytes { param([byte[]]$Bytes) ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant() }
function Get-Sha256File { param([string]$Path) Get-Sha256Bytes ([IO.File]::ReadAllBytes($Path)) }
function ConvertTo-CanonicalJson { param($Value) ($Value | ConvertTo-Json -Depth 32 -Compress) }

function Test-PortableRelativePath {
    param([string]$Path, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path.Contains('\') -or $Path.Contains(':') -or $Path.Length -gt 512) { throw "$Label is not a portable relative path." }
    $parts = @($Path.Split('/'))
    if ($parts.Count -eq 0 -or @($parts | Where-Object { $_ -ceq '' -or $_ -ceq '.' -or $_ -ceq '..' -or $_ -match '[\x00-\x1f]' -or $_ -ieq '.git' }).Count -ne 0) { throw "$Label contains a forbidden path segment." }
}

function Get-RepositoryIdentity {
    param([string]$Repository)
    $root = [IO.Path]::GetFullPath(([string](@(Invoke-GitReadOnly $Repository @('rev-parse','--show-toplevel'))[0])).Trim()).TrimEnd('\','/')
    $requested = [IO.Path]::GetFullPath($Repository).TrimEnd('\','/')
    if ($root -cne $requested) { throw "Repository path must be the exact Git worktree root: $requested" }
    $branch = ([string](@(Invoke-GitReadOnly $root @('symbolic-ref','--quiet','--short','HEAD'))[0])).Trim()
    $head = ([string](@(Invoke-GitReadOnly $root @('rev-parse','HEAD'))[0])).Trim().ToLowerInvariant()
    $tree = ([string](@(Invoke-GitReadOnly $root @('rev-parse','HEAD^{tree}'))[0])).Trim().ToLowerInvariant()
    $common = [IO.Path]::GetFullPath(([string](@(Invoke-GitReadOnly $root @('rev-parse','--git-common-dir'))[0])).Trim(), $root).TrimEnd('\','/')
    [ordered]@{ root=$root; branch=$branch; head=$head; tree=$tree; common=$common }
}

function Get-WorkspaceInventory {
    param([string]$Workspace)
    if (-not [IO.Directory]::Exists($Workspace)) { throw 'Selected source workspace does not exist as a directory.' }
    $rootItem = Get-Item -LiteralPath $Workspace -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Selected source workspace is a reparse point.' }
    $items = @(Get-ChildItem -LiteralPath $Workspace -Force -Recurse)
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Selected workspace contains a reparse point: $($item.Name)" }
        if (-not $item.PSIsContainer -and -not ($item -is [IO.FileInfo])) { throw "Selected workspace contains a non-regular file: $($item.Name)" }
    }
    $files = @($items | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        $relative = $_.FullName.Substring($Workspace.TrimEnd('\','/').Length + 1).Replace('\','/')
        Test-PortableRelativePath $relative 'Inventory path'
        [ordered]@{ path=$relative; type='file'; size=[int64]$_.Length; sha256=Get-Sha256File $_.FullName }
    } | Sort-Object -Property @{Expression={$_.path};Ascending=$true})
    if ($files.Count -eq 0) { throw 'Selected source workspace inventory is empty.' }
    $caseKeys = @($files | ForEach-Object { $_.path.ToUpperInvariant() })
    if (@($caseKeys | Group-Object | Where-Object Count -gt 1).Count -ne 0) { throw 'Selected workspace has case-ambiguous paths.' }
    for ($i=0; $i -lt $files.Count; $i++) { $files[$i] = [ordered]@{ ordinal=$i; path=$files[$i].path; type='file'; size=$files[$i].size; sha256=$files[$i].sha256 } }
    @($files)
}

function Test-JsonWorkspace {
    param([string]$Workspace, [object[]]$Inventory)
    foreach ($row in @($Inventory)) {
        $path = Join-Path $Workspace ([string]$row.path)
        if ([string]$row.path -match '\.json$') {
            try { $doc = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -ErrorAction Stop } catch { throw "Invalid JSON in selected workspace: $($row.path)" }
            if (-not $doc.PSObject.Properties['schema'] -or [string]$doc.schema -notmatch '^rusty\.morphospace\.workflow\.[a-z0-9_.-]+\.v[0-9]+$') { throw "Invalid or absent workflow schema ID: $($row.path)" }
        } elseif ([string]$row.path -match '\.jsonl$') {
            $lineNumber=0
            foreach ($line in [IO.File]::ReadLines($path)) { $lineNumber++; if ([string]::IsNullOrWhiteSpace($line)) { throw "Blank JSONL record: $($row.path):$lineNumber" }; try { $null=$line|ConvertFrom-Json -ErrorAction Stop } catch { throw "Invalid JSONL record: $($row.path):$lineNumber" } }
        }
    }
}

function Assert-InventoryEqual {
    param([object[]]$Expected,[object[]]$Actual,[string]$Label)
    $left=ConvertTo-CanonicalJson @($Expected);$right=ConvertTo-CanonicalJson @($Actual)
    if ($left -cne $right) { throw "$Label inventory differs from the signed-off input." }
}

function Test-PlanningStatusOwnedStage {
    param([string]$Repository,[string]$Stage)
    $stageRelative=$Stage.Substring($Repository.TrimEnd('\','/').Length+1).Replace('\','/')+'/'
    $rows=@(Invoke-GitReadOnly $Repository @('status','--porcelain=v1','--untracked-files=all'))
    foreach($row in $rows){if($row.Length-lt4-or-not$row.Substring(3).Replace('\','/').StartsWith($stageRelative,[StringComparison]::Ordinal)){return $false}}
    $true
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$inputSchema = Join-Path $repoRoot 'schemas\unpublished-workspace-materialization-v1.schema.json'
$receiptSchema = Join-Path $repoRoot 'schemas\unpublished-planning-authority-receipt-v1.schema.json'
$inputFull = [IO.Path]::GetFullPath($InputPath)
if (-not [IO.File]::Exists($inputFull)) { throw 'Materialization input does not exist.' }
$inputRaw = [IO.File]::ReadAllText($inputFull)
if (-not ($inputRaw | Test-Json -SchemaFile $inputSchema -ErrorAction Stop)) { throw 'Materialization input fails its schema.' }
$inputDocument = $inputRaw | ConvertFrom-Json -ErrorAction Stop
foreach ($path in @([string]$inputDocument.source.workspace_path,[string]$inputDocument.source.state_anchor.path,[string]$inputDocument.planning.destination_workspace_path,[string]$inputDocument.planning.receipt_path)) { Test-PortableRelativePath $path 'Input path' }

$source = Get-RepositoryIdentity ([IO.Path]::GetFullPath($SourceRepository).TrimEnd('\','/'))
$planning = Get-RepositoryIdentity ([IO.Path]::GetFullPath($PlanningRepository).TrimEnd('\','/'))
if ($source.common -ieq $planning.common) { throw 'Source and planning repositories must have distinct Git authority.' }
if ([string]$inputDocument.source.repo_id -ceq [string]$inputDocument.planning.repo_id) { throw 'Portable source and planning repository identities must be distinct.' }
if ($source.head -cne [string]$inputDocument.source.head -or $source.tree -cne [string]$inputDocument.source.tree -or $source.branch -cne [string]$inputDocument.source.branch) { throw 'Source repository HEAD/tree/branch differs from input.' }
if ($planning.head -cne [string]$inputDocument.planning.base_commit -or $planning.tree -cne [string]$inputDocument.planning.base_tree -or $planning.branch -cne [string]$inputDocument.planning.branch) { throw 'Planning repository base HEAD/tree/branch differs from input.' }
$planningStatus = @(Invoke-GitReadOnly $planning.root @('status','--porcelain=v1','--untracked-files=all'))
if ($planningStatus.Count -ne 0) { throw "Planning repository must be clean: $($planningStatus -join ', ')" }

$sourceWorkspace = [IO.Path]::GetFullPath((Join-Path $source.root ([string]$inputDocument.source.workspace_path)).TrimEnd('\','/'))
$destination = [IO.Path]::GetFullPath((Join-Path $planning.root ([string]$inputDocument.planning.destination_workspace_path)).TrimEnd('\','/'))
$sourcePrefix=$source.root+[IO.Path]::DirectorySeparatorChar;$planningPrefix=$planning.root+[IO.Path]::DirectorySeparatorChar
if (-not $sourceWorkspace.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase) -or $sourceWorkspace -ieq $source.root) { throw 'Source workspace must be below the source repository.' }
if (-not $destination.StartsWith($planningPrefix,[StringComparison]::OrdinalIgnoreCase) -or $destination -ieq $planning.root) { throw 'Destination workspace must be below the planning repository.' }
if ($sourceWorkspace.StartsWith($destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $destination.StartsWith($sourceWorkspace+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $sourceWorkspace -ieq $destination) { throw 'Source and destination overlap.' }
if (Test-Path -LiteralPath $destination) { throw 'Destination workspace already exists; materialization is one-time and no-overwrite.' }

$expected=@($inputDocument.source.inventory)
for($i=0;$i-lt$expected.Count;$i++){if([int]$expected[$i].ordinal-ne$i){throw 'Input inventory ordinals must be contiguous and ordered.'}}
$observed1=@(Get-WorkspaceInventory $sourceWorkspace);Assert-InventoryEqual $expected $observed1 'First source observation';Test-JsonWorkspace $sourceWorkspace $observed1
$anchor=@($observed1|Where-Object{[string]$_.path-ceq[string]$inputDocument.source.state_anchor.path})
if($anchor.Count-ne1-or[string]$anchor[0].sha256-cne[string]$inputDocument.source.state_anchor.sha256){throw 'Source state anchor differs from input.'}
if(@($expected|Where-Object{[string]$_.path-ceq[string]$inputDocument.planning.receipt_path}).Count-ne0){throw 'Receipt path collides with a selected workspace file.'}
if($ObservationDelayMilliseconds-gt0){Start-Sleep -Milliseconds $ObservationDelayMilliseconds}
$observed2=@(Get-WorkspaceInventory $sourceWorkspace);Assert-InventoryEqual $observed1 $observed2 'Repeated source observation'

$plan=[ordered]@{schema='rusty.morphospace.workflow.unpublished_planning_authority_plan.v1';materialization_id=[string]$inputDocument.materialization_id;source_inventory=@($observed2);destination_workspace_path=[string]$inputDocument.planning.destination_workspace_path;receipt_path=[string]$inputDocument.planning.receipt_path;execute_required=$true}
if(-not$Execute){ConvertTo-CanonicalJson $plan;return}

$parent=Split-Path -Parent $destination;[IO.Directory]::CreateDirectory($parent)|Out-Null
$stage=Join-Path $parent ('.'+[IO.Path]::GetFileName($destination)+'.materializing-'+[guid]::NewGuid().ToString('N'))
$parentVolume=[IO.Path]::GetPathRoot($parent);$stageVolume=[IO.Path]::GetPathRoot($stage)
if($parentVolume-cne$stageVolume){throw 'Staging and destination must be on the same volume.'}
[IO.Directory]::CreateDirectory($stage)|Out-Null
$installed=$false
try{
    foreach($row in $observed2){$target=Join-Path $stage ([string]$row.path);[IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null;[IO.File]::Copy((Join-Path $sourceWorkspace ([string]$row.path)),$target,$false)}
    $staged=@(Get-WorkspaceInventory $stage);Assert-InventoryEqual $expected $staged 'Staged destination'
    $inputHash=Get-Sha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes($inputRaw))
    $inventoryHash=Get-Sha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-CanonicalJson @($expected))))
    if(-not$Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('o')}
    $receipt=[ordered]@{
      '$schema'='../../../../schemas/unpublished-planning-authority-receipt-v1.schema.json';schema='rusty.morphospace.workflow.unpublished_planning_authority_receipt.v1';materialization_id=[string]$inputDocument.materialization_id;project_id=[string]$inputDocument.project_id;recorded_at=$Timestamp;status='materialized-and-read-back'
      input=[ordered]@{schema=[string]$inputDocument.schema;sha256=$inputHash}
      source=[ordered]@{repo_id=[string]$inputDocument.source.repo_id;head=$source.head;tree=$source.tree;branch=$source.branch;workspace_path=[string]$inputDocument.source.workspace_path;inventory_sha256=$inventoryHash;state_anchor=[ordered]@{path=[string]$inputDocument.source.state_anchor.path;sha256=[string]$inputDocument.source.state_anchor.sha256}}
      planning=[ordered]@{repo_id=[string]$inputDocument.planning.repo_id;base_commit=$planning.head;base_tree=$planning.tree;branch=$planning.branch;destination_workspace_path=[string]$inputDocument.planning.destination_workspace_path;receipt_path=[string]$inputDocument.planning.receipt_path}
      destination_inventory=@($staged);claims=@($inputDocument.claims)
      authority=[ordered]@{destination_workspace='sole-workspace-authority';source_workspace='preserved-historical-non-authoritative';source_bytes_preserved=$true;git_mutation_performed=$false}
      limitations=[ordered]@{ordinary_admission_required=$true;publication_projection='not-applicable';does_not_claim=@('workflow admission','state transition','validation','acceptance','source publication','remote operation','planning_workspace_projection v1-v3')}
    }
    $receiptTarget=Join-Path $stage ([string]$inputDocument.planning.receipt_path);[IO.Directory]::CreateDirectory((Split-Path -Parent $receiptTarget))|Out-Null
    [IO.File]::WriteAllText($receiptTarget,(ConvertTo-CanonicalJson $receipt)+"`n",[Text.UTF8Encoding]::new($false))
    if(-not((Get-Content -Raw $receiptTarget)|Test-Json -SchemaFile $receiptSchema -ErrorAction Stop)){throw 'Generated receipt fails its schema.'}
    if($ObservationDelayMilliseconds-gt0){Start-Sleep -Milliseconds $ObservationDelayMilliseconds}
    $finalSource=@(Get-WorkspaceInventory $sourceWorkspace);Assert-InventoryEqual $expected $finalSource 'Final source observation'
    $sourceFinal=Get-RepositoryIdentity $source.root;$planningFinal=Get-RepositoryIdentity $planning.root
    if($sourceFinal.head-cne$source.head-or$sourceFinal.tree-cne$source.tree-or$sourceFinal.branch-cne$source.branch){throw 'Source repository identity drifted before destination commit point.'}
    if($planningFinal.head-cne$planning.head-or$planningFinal.tree-cne$planning.tree-or$planningFinal.branch-cne$planning.branch-or-not(Test-PlanningStatusOwnedStage $planning.root $stage)){throw 'Planning repository drifted before destination commit point.'}
    if(Test-Path -LiteralPath $destination){throw 'Destination appeared before atomic install.'}
    [IO.Directory]::Move($stage,$destination);$installed=$true
    $readbackReceipt=Join-Path $destination ([string]$inputDocument.planning.receipt_path)
    if(-not((Get-Content -Raw $readbackReceipt)|Test-Json -SchemaFile $receiptSchema -ErrorAction Stop)){throw 'Installed receipt readback fails its schema.'}
    $readback=@(Get-WorkspaceInventory $destination|Where-Object{[string]$_.path-cne[string]$inputDocument.planning.receipt_path});for($i=0;$i-lt$readback.Count;$i++){$readback[$i].ordinal=$i};Assert-InventoryEqual $expected $readback 'Installed destination readback'
    ConvertTo-CanonicalJson $receipt
}catch{
    if($installed-and[IO.Directory]::Exists($destination)){Remove-Item -LiteralPath $destination -Recurse -Force}
    if([IO.Directory]::Exists($stage)){Remove-Item -LiteralPath $stage -Recurse -Force}
    throw
}
