Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')

$script:ToolingContextProtocolId='tooling-context-v1'
function Get-ToolingContextProcessCache([string]$Name){$key="RustyMorphospace.ToolingContext.$Name.v1";$cache=[AppDomain]::CurrentDomain.GetData($key);if($null-eq$cache){$cache=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal);[AppDomain]::CurrentDomain.SetData($key,$cache)};$cache}
$script:ToolingClosureResolutionCache=Get-ToolingContextProcessCache resolution
$script:ToolingHistoricalClosureCache=Get-ToolingContextProcessCache historical
$script:ToolingContextActions=@('Inspect','PrepareDevelopmentEnvelope','ReprepareRetiredDevelopmentEnvelope','PrepareBlockedSuccessor','SupersedeActive','RetireActive','RecoverPreparationCompletionTimestamp','ArchiveHistoryCheckpoint','AdmitDevelopmentUnit','RecoverAdmissionCompletionTimestamp','RetireProposed','Ready','WithdrawReady','Claim','Resume','CompleteInstructionSurfaces','AmendActiveWriteScope','ExtendActiveDevelopmentEnvelope','UpgradeToolingContext','NarrowValidationOnlyWriteScope','FreezeCandidate','RematerializeValidatingCandidate','MaterializeInheritedCandidate','CorrectActiveReadOnlyDependencies','CorrectActiveProjectRepositoryScope','CorrectActiveUnitContract','BeginValidation','ReturnToActive','PreflightValidation','RecordValidation','Accept','PreparePush','PrepareSourceOnlyPublication','RecordSourceOnlyPublication','RetirePreparedPush','ReconcilePreparedPublication','ReconcilePreparedPushTransactionSuffix','ResolveBlocker','CorrectResolvedBlockerEvidence','CorrectHistoricalBlockerResolutionIntentBinding','CorrectCompletedTransitionSemantics','NormalizeEventLedgerPrefix','RecordPublication','Recover','ReconcilePublication','AdoptPublishedPlanningAuthority','ReconcilePlanningSuffixRewrite','ReconcilePublishedPrerequisiteSuffix','ReconcileExecutedPreparedPublication')
function Get-MorphospaceToolingContextProtocolId { $script:ToolingContextProtocolId }
function Get-MorphospaceToolingContextAllowedActions { @($script:ToolingContextActions) }
function Get-ToolingContextSha256 { param([object]$Value) Get-MorphospaceCanonicalJsonSha256 $Value }
function Copy-ToolingContextValue { param([object]$Value) $Value|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String }
function Get-ToolingContextSchema { param([string]$Name) Join-Path (Split-Path $PSScriptRoot -Parent) "schemas/$Name" }

function New-MorphospaceToolingContext {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ContextId,[Parameter(Mandatory)][string]$ProjectId,[Parameter(Mandatory)][string]$PreparationId,[Parameter(Mandatory)][object]$ProductProjection,[Parameter(Mandatory)][object]$Resolver,[Parameter(Mandatory)][object]$Executor,[Parameter(Mandatory)][object[]]$Routers,[Parameter(Mandatory)][object]$Compatibility)
    $context=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.tooling_context.v1';context_id=$ContextId;project_id=$ProjectId;preparation_id=$PreparationId;fingerprint='';product_projection=$ProductProjection;resolver=$Resolver;executor=$Executor;routers=@($Routers);compatibility=$Compatibility;limits=[pscustomobject][ordered]@{upgrade_before_freeze_only=$true;fallback_allowed=$false;product_mutation_authority=$false};status='bound';does_not_prove=@('Does not alter product source composition, repository-map authority, source write authority, device authority, acceptance, publication, or host installation.')}
    $identity=[ordered]@{context_id=$context.context_id;project_id=$context.project_id;preparation_id=$context.preparation_id;product_projection=$context.product_projection;resolver=$context.resolver;executor=$context.executor;routers=$context.routers;compatibility=$context.compatibility;limits=$context.limits;status=$context.status}
    $context.fingerprint=Get-ToolingContextSha256 $identity
    Assert-MorphospaceToolingContext $context
}

function Assert-MorphospaceToolingContext {
    [CmdletBinding()]param([Parameter(Mandatory)][object]$Context)
    $schema=Get-ToolingContextSchema 'tooling-context-v1.schema.json'
    if(-not(Test-Json -Json ($Context|ConvertTo-Json -Depth 64 -Compress) -SchemaFile $schema -ErrorAction Stop)){throw 'Tooling context does not satisfy its owner schema.'}
    $context=Copy-ToolingContextValue $Context
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($router in @($context.routers)){if(-not$ids.Add([string]$router.skill_id)){throw "Tooling context repeats router '$($router.skill_id)'."}}
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($blob in @($context.executor.closure)){if(-not$paths.Add([string]$blob.path)){throw "Tooling context repeats executor closure path '$($blob.path)'."}}
    foreach($router in @($context.routers)){$managed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($blob in @($router.managed_files)){if(-not$managed.Add(([string]$blob.path).Replace('\','/'))){throw "Tooling context repeats router managed file '$($router.skill_id)/$($blob.path)'."}}}
    if([string]$context.compatibility.protocol_id-cne$script:ToolingContextProtocolId-or(@($context.compatibility.allowed_actions)-join[char]0)-cne($script:ToolingContextActions-join[char]0)){throw 'Tooling context declares an unsupported lifecycle protocol.'}
    $identity=[ordered]@{context_id=$context.context_id;project_id=$context.project_id;preparation_id=$context.preparation_id;product_projection=$context.product_projection;resolver=$context.resolver;executor=$context.executor;routers=$context.routers;compatibility=$context.compatibility;limits=$context.limits;status=$context.status}
    if([string]$context.fingerprint-cne(Get-ToolingContextSha256 $identity)){throw 'Tooling context fingerprint is detached.'}
    $context
}

$script:ToolingGit=(@(Get-Command git -CommandType Application -ErrorAction Stop)[0]).Source
function Invoke-ToolingContextGit {
    param([string]$Root,[string[]]$Arguments,[string]$Name)
    $safe=@('--no-optional-locks','--no-replace-objects','--literal-pathspecs','-c','core.quotepath=false','-c','color.ui=false','-c','core.fsmonitor=false','-c','diff.external=','-c','core.hooksPath=NUL','-C',$Root)+$Arguments
    $rows=@(&$script:ToolingGit @safe 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "Tooling context Git $Name readback failed.`n$($rows-join"`n")"};@($rows)
}
function Get-ToolingContextGitScalar { param([string]$Root,[string[]]$Arguments,[string]$Name) $rows=@(Invoke-ToolingContextGit $Root $Arguments $Name);if($rows.Count-ne1){throw "Tooling context Git $Name did not return one row."};$rows[0].Trim() }
function Get-ToolingContextGitBlobBytes {
    param([string]$Root,[string]$Commit,[string]$Path)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$script:ToolingGit;$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('--no-optional-locks','--no-replace-objects','-C',$Root,'cat-file','blob',"$Commit`:$Path")){[void]$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;[void]$process.Start();$memory=[IO.MemoryStream]::new();$process.StandardOutput.BaseStream.CopyTo($memory);$errorText=$process.StandardError.ReadToEnd();$process.WaitForExit();if($process.ExitCode-ne0){throw "Tooling context historical blob '$Path' is absent: $errorText"};$memory.ToArray()
}
function Get-ToolingContextGitBlobMap {
    param([string]$Root,[string]$Commit,[string[]]$Paths)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$script:ToolingGit;$start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    foreach($arg in @('--no-optional-locks','--no-replace-objects','-C',$Root,'cat-file','--batch')){[void]$start.ArgumentList.Add($arg)};$process=[Diagnostics.Process]::new();$process.StartInfo=$start;[void]$process.Start();$inputText=(@($Paths|ForEach-Object{"$Commit`:$($_)"})-join"`n")+"`n";$writeTask=$process.StandardInput.WriteAsync($inputText);$stream=$process.StandardOutput.BaseStream;$map=@{}
    foreach($path in $Paths){$headerBytes=[Collections.Generic.List[byte]]::new();while($true){$value=$stream.ReadByte();if($value-lt0){throw 'Tooling context batch blob stream ended before its header.'};if($value-eq10){break};if($value-ne13){$headerBytes.Add([byte]$value)}};$header=[Text.Encoding]::ASCII.GetString($headerBytes.ToArray());if($header-cnotmatch'^[0-9a-f]{40} blob (?<size>[0-9]+)$'){throw "Tooling context historical blob '$path' is absent: $header"};$size=[int64]$Matches.size;if($size-gt[int]::MaxValue){throw 'Tooling context blob exceeds supported owner limits.'};$bytes=[byte[]]::new([int]$size);$offset=0;while($offset-lt$bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read-le0){throw 'Tooling context batch blob stream ended before its payload.'};$offset+=$read};if($stream.ReadByte()-ne10){throw 'Tooling context batch blob stream lacks its payload delimiter.'};$map[$path]=$bytes}
    [void]$writeTask.GetAwaiter().GetResult();$process.StandardInput.Close();$errorText=$process.StandardError.ReadToEnd();$process.WaitForExit();if($process.ExitCode-ne0-or$errorText.Length-ne0){throw "Tooling context batch historical blob read failed: $errorText"};$map
}
function Assert-ToolingContextClosureImports {
    param([string]$Root,[object]$Executor)
    $declared=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($row in @($Executor.closure)){[void]$declared.Add(([string]$row.path).Replace('\','/'))}
    if(-not$declared.Contains(([string]$Executor.entrypoint).Replace('\','/'))){throw 'Tooling context closure omits its executor entrypoint.'}
    $head=Get-ToolingContextGitScalar $Root @('rev-parse','HEAD') 'closure HEAD';$tree=Get-ToolingContextGitScalar $Root @('rev-parse','HEAD^{tree}') 'closure tree';$key="$([IO.Path]::GetFullPath($Root))|$head|$tree|$([string]$Executor.entrypoint)";$resolution=$script:ToolingClosureResolutionCache[$key]
    if($null-eq$resolution){$paths=[Collections.Generic.List[string]]::new();foreach($line in @(Invoke-ToolingContextGit $Root @('ls-tree','-r','--full-tree','HEAD') 'executor tree inventory')){if($line-cnotmatch'^(?<mode>[0-9]{6})\s+(?<type>blob|tree|commit)\s+(?<oid>[0-9a-f]{40})\t(?<path>.+)$'){throw 'Tooling context executor tree inventory is malformed.'};if([string]$Matches.type-ceq'blob'){$paths.Add(([string]$Matches.path).Replace('\','/'))}};$resolution=[pscustomobject]@{paths=@($paths);resolution=[pscustomobject]@{mode='full-tracked-executor-tree'}};$script:ToolingClosureResolutionCache[$key]=$resolution}
    foreach($required in @($resolution.paths)){if(-not$declared.Contains([string]$required)){throw "Tooling context closure omits owner-derived dependency '$required' ($([string]$resolution.resolution.mode))."}}
}

function Read-MorphospaceToolingContextResolver {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Context)
    $context=Assert-MorphospaceToolingContext $Context;$relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$context.resolver.path);if($relative-cnotmatch'^local/'){throw 'Tooling context resolver must be an ignored local/ binding.'}
    $path=Resolve-MorphospaceWorkspacePath ([IO.Path]::GetFullPath($WorkspaceRoot)) $relative -RequireLeaf;if((Get-MorphospaceFileSha256 $path)-cne[string]$context.resolver.sha256){throw 'Tooling context resolver raw hash drifted.'}
    $resolver=Read-MorphospaceProtocolJson $path;if(-not(Test-Json -Json ($resolver|ConvertTo-Json -Depth 32) -SchemaFile (Get-ToolingContextSchema 'tooling-context-resolver-v1.schema.json'))){throw 'Tooling context resolver violates its owner schema.'}
    if([string]$resolver.context_id-cne[string]$context.context_id){throw 'Tooling context resolver names another context.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($row in @($resolver.routers)){if(-not$ids.Add([string]$row.skill_id)){throw 'Tooling context resolver repeats a router.'};if(-not[IO.Path]::IsPathFullyQualified([string]$row.root)){throw 'Tooling context resolver router root is not absolute.'}}
    if(-not[IO.Path]::IsPathFullyQualified([string]$resolver.executor_root)){throw 'Tooling context resolver executor root is not absolute.'};$resolver
}

function Assert-ToolingContextOwnerValidationEvidence {
    param([string]$Workspace,[object]$Binding,[object]$Executor,[string]$Name)
    $path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$Binding.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $path)-cne[string]$Binding.sha256){throw "Tooling context $Name validation evidence drifted."}
    $evidence=Read-MorphospaceProtocolJson $path;if(-not(Test-Json -Json ($evidence|ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Get-ToolingContextSchema 'affected-validation-evidence-v1.schema.json'))){throw "Tooling context $Name validation evidence violates the owner schema."}
    if([string]$evidence.result-cne'pass'-or[string]$evidence.head.commit-cne[string]$Executor.commit-or[string]$evidence.head.tree-cne[string]$Executor.tree){throw "Tooling context $Name validation evidence detaches the executor revision."};$evidence
}
function Assert-MorphospaceToolingContextOwnerValidationEvidence {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][object]$Binding,[Parameter(Mandatory)][object]$Executor,[string]$Name='owner')
    Assert-ToolingContextOwnerValidationEvidence $WorkspaceRoot $Binding $Executor $Name
}
function Assert-ToolingContextPortableEvidence {
    param([string]$Workspace,[object]$Context)
    $publicationBinding=$Context.executor.publication_evidence;$publicationPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$publicationBinding.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $publicationPath)-cne[string]$publicationBinding.sha256){throw "Tooling context publication evidence '$($publicationBinding.path)' drifted."}
    $publication=Read-MorphospaceProtocolJson $publicationPath;if(-not(Test-Json -Json ($publication|ConvertTo-Json -Depth 32 -Compress) -SchemaFile (Get-ToolingContextSchema 'tooling-context-publication-evidence-v1.schema.json'))){throw 'Tooling context publication evidence violates its owner schema.'}
    foreach($field in @('repo_id','remote_url','commit','tree')){if([string]$publication.executor.$field-cne[string]$Context.executor.$field){throw "Tooling context publication evidence detaches executor $field."}}
    Assert-ToolingContextOwnerValidationEvidence $Workspace $publication.validation $Context.executor publication|Out-Null
    $receiptBinding=$Context.compatibility.receipt;$receiptPath=Resolve-MorphospaceWorkspacePath $Workspace ([string]$receiptBinding.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $receiptPath)-cne[string]$receiptBinding.sha256){throw "Tooling context protocol receipt '$($receiptBinding.path)' drifted."}
    $receipt=Read-MorphospaceProtocolJson $receiptPath;if(-not(Test-Json -Json ($receipt|ConvertTo-Json -Depth 64 -Compress) -SchemaFile (Get-ToolingContextSchema 'tooling-context-protocol-receipt-v1.schema.json'))){throw 'Tooling context protocol receipt violates its owner schema.'}
    foreach($field in @('repo_id','commit','tree')){if([string]$receipt.executor.$field-cne[string]$Context.executor.$field){throw "Tooling context protocol receipt detaches executor $field."}}
    foreach($field in @('protocol_id','product_lock_schema','repository_map_schema')){if([string]$receipt.protocol.$field-cne[string]$Context.compatibility.$field){throw "Tooling context protocol receipt detaches $field."}}
    if((Get-ToolingContextSha256 @($receipt.protocol.allowed_actions))-cne(Get-ToolingContextSha256 @($Context.compatibility.allowed_actions))){throw 'Tooling context protocol receipt detaches allowed actions.'}
    Assert-ToolingContextOwnerValidationEvidence $Workspace $receipt.validation $Context.executor protocol|Out-Null
}
function Assert-ToolingContextRouterLive {
    param([object]$Router,[string]$Root)
    $recordPath=Join-Path $Root '.morphospace-skill-source.json';if(-not[IO.File]::Exists($recordPath)){throw "Tooling context router '$($Router.skill_id)' lacks managed provenance."};$record=Read-MorphospaceProtocolJson $recordPath
    if([string]$record.schema-cne'rusty.morphospace.local_skill_source.v1'-or[string]$record.skill_id-cne[string]$Router.skill_id-or[string]$record.source_commit-cne[string]$Router.commit-or[string]$record.source_tree_sha256-cne[string]$Router.source_fingerprint-or[bool]$record.source_worktree_dirty){throw "Tooling context router '$($Router.skill_id)' provenance drifted."}
    $actual=@($record.source_files);if($actual.Count-ne@($Router.managed_files).Count){throw "Tooling context router '$($Router.skill_id)' managed file set drifted."};for($i=0;$i-lt$actual.Count;$i++){$a=([string]$actual[$i].path).Replace('\','/');$b=([string]$Router.managed_files[$i].path).Replace('\','/');if($a-cne$b-or[string]$actual[$i].sha256-cne[string]$Router.managed_files[$i].sha256){throw "Tooling context router '$($Router.skill_id)' managed provenance differs."};$path=Resolve-MorphospaceWorkspacePath $Root $b -RequireLeaf;if((Get-MorphospaceFileSha256 $path)-cne[string]$Router.managed_files[$i].sha256){throw "Tooling context router '$($Router.skill_id)' managed file '$b' drifted."}}
    if($record.PSObject.Properties.Name-contains'work_environment_root'-and[IO.Directory]::Exists([string]$record.work_environment_root)){$tree=(Get-ToolingContextGitScalar ([string]$record.work_environment_root) @('rev-parse',"$([string]$Router.commit)^{tree}") 'router tree').ToLowerInvariant();if($tree-cne[string]$Router.tree){throw "Tooling context router '$($Router.skill_id)' source tree drifted."}}
}
function Assert-ToolingContextHistoricalExecutorClosure {
    param([string]$Root,[object]$Context)
    $tree=(Get-ToolingContextGitScalar $root @('rev-parse',"$([string]$context.executor.commit)^{tree}") 'historical executor tree').ToLowerInvariant();if($tree-cne[string]$context.executor.tree){throw 'Tooling context historical executor tree is absent or detached.'}
    $cacheKey="$root|$([string]$context.executor.commit)|$([string]$context.fingerprint)";if(-not$script:ToolingHistoricalClosureCache.ContainsKey($cacheKey)){$paths=@($context.executor.closure|ForEach-Object{[string]$_.path});$treePaths=[Collections.Generic.List[string]]::new();foreach($line in @(Invoke-ToolingContextGit $root @('ls-tree','-r','--full-tree',[string]$context.executor.commit) 'historical executor tree inventory')){if($line-cnotmatch'^(?<mode>[0-9]{6})\s+(?<type>blob|tree|commit)\s+(?<oid>[0-9a-f]{40})\t(?<path>.+)$'){throw 'Tooling context historical executor tree inventory is malformed.'};if([string]$Matches.type-ceq'blob'){$treePaths.Add(([string]$Matches.path).Replace('\','/'))}};$declared=@($paths|Sort-Object -CaseSensitive);$historical=@($treePaths.ToArray()|Sort-Object -CaseSensitive);if($declared.Count-ne$historical.Count-or($declared-join[char]0)-cne($historical-join[char]0)){throw 'Tooling context historical executor closure is not the complete pinned tree blob inventory.'};$blobs=Get-ToolingContextGitBlobMap $root ([string]$context.executor.commit) $paths;foreach($blob in @($context.executor.closure)){if((Get-MorphospaceSha256Bytes ([byte[]]($blobs[[string]$blob.path])))-cne[string]$blob.sha256){throw "Tooling context historical executor closure '$($blob.path)' drifted."}};$script:ToolingHistoricalClosureCache[$cacheKey]=$true}
}
function Assert-MorphospaceToolingContextHistoricalObservation {
    [CmdletBinding()]param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][string]$WorkspaceRoot)
    $context=Assert-MorphospaceToolingContext $Context;$resolver=Read-MorphospaceToolingContextResolver $WorkspaceRoot $context;$root=[IO.Path]::GetFullPath([string]$resolver.executor_root)
    Assert-ToolingContextHistoricalExecutorClosure $root $context
    Assert-ToolingContextPortableEvidence $WorkspaceRoot $context;$true
}
function Assert-MorphospaceToolingContextLocalObservation {
    [CmdletBinding()]param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][string]$WorkspaceRoot)
    $context=Assert-MorphospaceToolingContext $Context;$resolver=Read-MorphospaceToolingContextResolver $WorkspaceRoot $context;$root=[IO.Path]::GetFullPath([string]$resolver.executor_root);if(-not[IO.Directory]::Exists($root)){throw 'Tooling context executor root is absent.'}
    $head=(Get-ToolingContextGitScalar $root @('rev-parse','HEAD') 'executor HEAD').ToLowerInvariant();$tree=(Get-ToolingContextGitScalar $root @('rev-parse','HEAD^{tree}') 'executor tree').ToLowerInvariant();$remote=Get-ToolingContextGitScalar $root @('remote','get-url','origin') 'executor remote';$status=@(Invoke-ToolingContextGit $root @('status','--porcelain=v1','--untracked-files=all') 'executor cleanliness')
    if($status.Count-ne0-or$head-cne[string]$context.executor.commit-or$tree-cne[string]$context.executor.tree-or$remote-cne[string]$context.executor.remote_url){throw 'Tooling context executor Git identity or cleanliness drifted.'}
    foreach($blob in @($context.executor.closure)){$path=Resolve-MorphospaceWorkspacePath $root ([string]$blob.path) -RequireLeaf;if((Get-MorphospaceFileSha256 $path)-cne[string]$blob.sha256){throw "Tooling context executor closure '$($blob.path)' drifted."}};Assert-ToolingContextClosureImports $root $context.executor
    Assert-ToolingContextHistoricalExecutorClosure $root $context
    $routerMap=@{};foreach($row in @($resolver.routers)){$routerMap[[string]$row.skill_id]=[string]$row.root};if($routerMap.Count-ne@($context.routers).Count){throw 'Tooling context resolver router set differs from context.'};foreach($router in @($context.routers)){if(-not$routerMap.ContainsKey([string]$router.skill_id)){throw "Tooling context router '$($router.skill_id)' is unresolved."};Assert-ToolingContextRouterLive $router ([string]$routerMap[[string]$router.skill_id])}
    Assert-MorphospaceToolingContextHistoricalObservation -Context $context -WorkspaceRoot $WorkspaceRoot|Out-Null;$true
}


function New-MorphospaceToolingContextResolver {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$ExecutorRoot,
        [Parameter(Mandatory)][string]$SnapshotRoot,
        [Parameter(Mandatory)][string[]]$RepositoryRoots,
        [Parameter(Mandatory)][object[]]$Routers,
        [Parameter(Mandatory)][object[]]$RouterLocations,
        [Parameter(Mandatory)][string]$ResolverPath,
        [switch]$Execute
    )
    # This host authoring step precedes preparation. It neither edits a context
    # nor changes the existing observed producer or its authority predicates.
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
    $relative=ConvertTo-MorphospaceProtocolRelativePath $ResolverPath
    if($relative-cnotmatch'^local/'){throw 'New tooling resolver must be an ignored local/ binding.'}
    if($ContextId-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){throw 'New tooling resolver context identity is invalid.'}
    if(-not[IO.Path]::IsPathFullyQualified($ExecutorRoot)-or-not[IO.Directory]::Exists($ExecutorRoot)){throw 'New tooling resolver executor must be an existing absolute directory.'}
    if(-not[IO.Path]::IsPathFullyQualified($SnapshotRoot)){throw 'Tooling router snapshot storage must be an explicit absolute retained directory.'}
    $snapshotBase=[IO.Path]::GetFullPath($SnapshotRoot).TrimEnd('\','/')
    $volume=[IO.Path]::GetPathRoot($snapshotBase)
    if($snapshotBase.Length-le$volume.Length-or[IO.File]::Exists($snapshotBase)){throw 'Tooling router snapshot storage must be a retained directory below its filesystem root.'}
    [void](ConvertTo-MorphospaceProtocolRelativePath ([IO.Path]::GetRelativePath($volume,$snapshotBase)))
    Assert-MorphospaceNoReparseAncestor -Root $snapshotBase -Candidate $snapshotBase
    if($RepositoryRoots.Count-eq0){throw 'Tooling router materialization requires the selected repository root locations.'}
    $pathComparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    foreach($declared in @($RepositoryRoots)+@($workspace,$ExecutorRoot)){
        if(-not[IO.Path]::IsPathFullyQualified($declared)){throw 'Tooling router repository root locations must be absolute.'}
        $protected=[IO.Path]::GetFullPath($declared)
        $protectedVolume=[IO.Path]::GetPathRoot($protected)
        if($protected.Length-gt$protectedVolume.Length){$protected=$protected.TrimEnd('\','/')}
        if($protected.Length-gt$protectedVolume.Length){[void](ConvertTo-MorphospaceProtocolRelativePath ([IO.Path]::GetRelativePath($protectedVolume,$protected)))}
        Assert-MorphospaceNoReparseAncestor -Root $protected -Candidate $protected
        if($snapshotBase.Equals($protected,$pathComparison)-or$snapshotBase.StartsWith($protected.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,$pathComparison)-or$protected.StartsWith($snapshotBase+[IO.Path]::DirectorySeparatorChar,$pathComparison)){throw 'Tooling router snapshot storage overlaps a declared repository, workspace or executor root.'}
    }
    $output=Resolve-MorphospaceWorkspacePath $workspace $relative
    $locations=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($row in $RouterLocations){
        if(-not$locations.TryAdd([string]$row.skill_id,[string]$row.root)){throw 'New tooling resolver repeats a router location.'}
    }
    if($Routers.Count-eq0-or$locations.Count-ne$Routers.Count){throw 'New tooling resolver router and location sets differ.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files=[Collections.Generic.List[object]]::new()
    foreach($router in @($Routers|Sort-Object -Property skill_id -CaseSensitive)){
        $id=[string]$router.skill_id
        if($id-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'-or-not$ids.Add($id)-or-not$locations.ContainsKey($id)){throw 'New tooling resolver router identity is invalid, duplicated or unresolved.'}
        $source=$locations[$id]
        if(-not[IO.Path]::IsPathFullyQualified($source)-or-not[IO.Directory]::Exists($source)){throw 'New tooling resolver router source must be an existing absolute directory.'}
        Assert-ToolingContextRouterLive $router $source
        $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($blob in @($router.managed_files)){
            $path=ConvertTo-MorphospaceProtocolRelativePath ([string]$blob.path)
            if(-not$paths.Add($path)){throw 'New tooling resolver repeats a managed file.'}
        }
        foreach($generated in @('.morphospace-skill-source.json','references/local-work-environment.json','references/local-meta-quest-playbooks.json')){
            if($paths.Contains($generated)){throw 'New tooling resolver managed source collides with generated provenance.'}
            $candidate=Resolve-MorphospaceWorkspacePath $source $generated
            if([IO.File]::Exists($candidate)){[void]$paths.Add($generated)}
        }
        foreach($path in @($paths|Sort-Object -CaseSensitive)){
            $absolute=Resolve-MorphospaceWorkspacePath $source $path -RequireLeaf
            $bytes=[IO.File]::ReadAllBytes($absolute)
            $files.Add([pscustomobject]@{path="$id/$path";source=$absolute;sha256=Get-MorphospaceSha256Bytes $bytes;bytes=$bytes})
        }
    }
    # Include exact provenance and generated locator bytes, not unmanaged files.
    $inventory=@($files|ForEach-Object{[pscustomobject][ordered]@{path=$_.path;sha256=$_.sha256}})
    $digest=Get-MorphospaceCanonicalJsonSha256 $inventory
    $snapshot=Resolve-MorphospaceWorkspacePath $snapshotBase $digest
    if($relative.StartsWith('local/tooling-router-snapshots/',[StringComparison]::OrdinalIgnoreCase)){throw 'New tooling resolver cannot be written inside its router copy.'}
    $resolver=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.tooling_context_resolver.v1';context_id=$ContextId
        executor_root=[IO.Path]::GetFullPath($ExecutorRoot)
        routers=@($Routers|ForEach-Object{[pscustomobject][ordered]@{skill_id=[string]$_.skill_id;root=Join-Path $snapshot ([string]$_.skill_id)}})
        status='resolved';does_not_prove=@('Locations and pre-seal managed copies only; no context upgrade, execution, acceptance or product authority.')
    }
    $resolverBytes=ConvertTo-MorphospaceProtocolJsonBytes $resolver
    function Assert-SnapshotFiles([string]$Root){
        $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($Root)
        $actual=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        while($pending.Count){
            foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Dequeue())){
                if(([IO.File]::GetAttributes($entry)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Tooling router copy contains a reparse point.'}
                if([IO.Directory]::Exists($entry)){$pending.Enqueue($entry)}else{[void]$actual.Add([IO.Path]::GetRelativePath($Root,$entry).Replace('\','/'))}
            }
        }
        if($actual.Count-ne$files.Count){throw 'Tooling router copy file set differs.'}
        foreach($file in $files){
            if(-not$actual.Contains([string]$file.path)){throw 'Tooling router copy file set differs.'}
            $path=Resolve-MorphospaceWorkspacePath $Root ([string]$file.path) -RequireLeaf
            if((Get-MorphospaceFileSha256 $path)-cne[string]$file.sha256){throw "Tooling router copy '$($file.path)' drifted."}
        }
    }
    $exists=[IO.Directory]::Exists($snapshot)
    if($exists){Assert-SnapshotFiles $snapshot}
    if([IO.File]::Exists($output)-and(Get-MorphospaceFileSha256 $output)-cne(Get-MorphospaceSha256Bytes $resolverBytes)){throw 'New tooling resolver output already contains different bytes.'}
    if(-not$Execute){return [pscustomobject]@{action='planned';resolver=[pscustomobject]@{path=$relative;sha256=Get-MorphospaceSha256Bytes $resolverBytes};router_root=$snapshot;executed=$false}}
    $mutex=Enter-MorphospaceWorkspaceMutex $workspace
    $stage=$null
    try{
        foreach($file in $files){if((Get-MorphospaceFileSha256 ([string]$file.source))-cne[string]$file.sha256){throw 'Tooling router source changed before materialization.'}}
        foreach($router in $Routers){Assert-ToolingContextRouterLive $router $locations[[string]$router.skill_id]}
        if([IO.File]::Exists($output)-and(Get-MorphospaceFileSha256 $output)-cne(Get-MorphospaceSha256Bytes $resolverBytes)){throw 'New tooling resolver output already contains different bytes.'}
        if([IO.Directory]::Exists($snapshot)){Assert-SnapshotFiles $snapshot}else{
            $stage=Resolve-MorphospaceWorkspacePath $snapshotBase ("staging-"+[guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($stage)
            foreach($file in $files){
                $destination=Resolve-MorphospaceWorkspacePath $stage ([string]$file.path)
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                [IO.File]::WriteAllBytes($destination,[byte[]]$file.bytes)
            }
            Assert-SnapshotFiles $stage
            foreach($file in $files){if((Get-MorphospaceFileSha256 ([string]$file.source))-cne[string]$file.sha256){throw 'Tooling router source changed before publication.'}}
            [IO.Directory]::Move($stage,$snapshot);$stage=$null
        }
        $current=[IO.File]::Exists($output)
        if(-not$current){Write-MorphospaceManagedProtocolJsonAtomic $workspace $relative $resolver -NoOverwrite}
        [pscustomobject]@{action=$(if($current){'current'}else{'materialized'});resolver=[pscustomobject]@{path=$relative;sha256=Get-MorphospaceFileSha256 $output};router_root=$snapshot;executed=$true}
    }finally{
        try{
            if($null-ne$stage-and[IO.Directory]::Exists($stage)){
                # Only the new staging directory inside explicitly selected storage.
                $checked=Resolve-MorphospaceWorkspacePath $snapshotBase ([IO.Path]::GetRelativePath($snapshotBase,$stage).Replace('\','/'))
                if(-not$checked.Equals($stage,$pathComparison)){throw 'Router materialization staging identity changed.'}
                Remove-Item -LiteralPath $stage -Recurse -Force
            }
        }finally{Exit-MorphospaceWorkspaceMutex $mutex}
    }
}

function New-MorphospaceObservedToolingContext {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ContextId,[Parameter(Mandatory)][string]$ProjectId,[Parameter(Mandatory)][string]$PreparationId,[Parameter(Mandatory)][object]$ProductProjection,[Parameter(Mandatory)][string]$ResolverPath,[Parameter(Mandatory)][object]$Executor,[Parameter(Mandatory)][object[]]$Routers,[Parameter(Mandatory)][object]$Compatibility)
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$relative=ConvertTo-MorphospaceProtocolRelativePath $ResolverPath;$absolute=Resolve-MorphospaceWorkspacePath $workspace $relative -RequireLeaf
    $context=New-MorphospaceToolingContext -ContextId $ContextId -ProjectId $ProjectId -PreparationId $PreparationId -ProductProjection $ProductProjection -Resolver ([pscustomobject][ordered]@{path=$relative;sha256=Get-MorphospaceFileSha256 $absolute}) -Executor $Executor -Routers $Routers -Compatibility $Compatibility
    Assert-MorphospaceToolingContextLocalObservation -Context $context -WorkspaceRoot $workspace|Out-Null;$context
}

function Test-MorphospaceToolingContextCompatibility {
    [CmdletBinding()]param([Parameter(Mandatory)][object]$OldContext,[Parameter(Mandatory)][object]$NewContext,[Parameter(Mandatory)][object]$ProductProjection)
    $old=Assert-MorphospaceToolingContext $OldContext;$new=Assert-MorphospaceToolingContext $NewContext
    if([string]$old.project_id-cne[string]$new.project_id-or[string]$old.preparation_id-cne[string]$new.preparation_id){throw 'Tooling context compatibility crosses project or preparation identity.'};if([string]$old.context_id-ceq[string]$new.context_id){throw 'Tooling context upgrade must name a distinct context.'}
    foreach($name in @('source_composition','repository_map','feature_lock')){if((Get-ToolingContextSha256 $new.product_projection.$name)-cne(Get-ToolingContextSha256 $ProductProjection.$name)){throw "New tooling context changes current product projection '$name'."}}
    foreach($field in @('protocol_id','product_lock_schema','repository_map_schema')){if([string]$old.compatibility.$field-cne[string]$new.compatibility.$field){throw 'Tooling context upgrade changes its exact consumer protocol declaration.'}}
    if((Get-ToolingContextSha256 @($old.compatibility.allowed_actions))-cne(Get-ToolingContextSha256 @($new.compatibility.allowed_actions))){throw 'Tooling context upgrade changes its exact consumer action protocol.'};$true
}

function Assert-MorphospaceToolingContextLoadedOwnerModule {
    [CmdletBinding()]param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][string]$ExecutorRoot,[Parameter(Mandatory)][Management.Automation.PSModuleInfo]$OwnerModule)
    $context=Assert-MorphospaceToolingContext $Context;$root=[IO.Path]::GetFullPath($ExecutorRoot).TrimEnd('\','/');$prefix=$root+[IO.Path]::DirectorySeparatorChar;$comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal};if([string]::IsNullOrEmpty([string]$OwnerModule.Path)-or-not[IO.Path]::GetFullPath([string]$OwnerModule.Path).StartsWith($prefix,$comparison)){throw 'Loaded owner module is outside the exact tooling-context executor root.'};$closure=@{};foreach($row in @($context.executor.closure)){$closure[[string]$row.path]=[string]$row.sha256};$pending=[Collections.Generic.Queue[Management.Automation.PSModuleInfo]]::new();$pending.Enqueue($OwnerModule);foreach($frame in @(Get-PSCallStack)){if($null-ne$frame.InvocationInfo-and$null-ne$frame.InvocationInfo.MyCommand-and$null-ne$frame.InvocationInfo.MyCommand.Module){$module=$frame.InvocationInfo.MyCommand.Module;if(-not[string]::IsNullOrEmpty([string]$module.Path)-and[IO.Path]::GetFullPath([string]$module.Path).StartsWith($prefix,$comparison)){$pending.Enqueue($module)}}};$seen=[Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    while($pending.Count){$module=$pending.Dequeue();if(-not$seen.Add($module)){continue};if([string]::IsNullOrEmpty([string]$module.Path)){continue};$path=[IO.Path]::GetFullPath([string]$module.Path);if(-not$path.StartsWith($prefix,$comparison)){continue};$relative=[IO.Path]::GetRelativePath($root,$path).Replace('\','/');$disk=[IO.File]::ReadAllText($path);if(-not[string]::Equals([string]$module.Definition,$disk,[StringComparison]::Ordinal)){throw "Loaded owner module '$relative' differs from the exact executor bytes on disk."};if(-not$closure.ContainsKey($relative)-or[string]$closure[$relative]-cne(Get-MorphospaceFileSha256 $path)){throw "Loaded owner module '$relative' differs from the tooling-context closure."};foreach($nested in @($module.NestedModules)){$pending.Enqueue($nested)}};$true
}

Export-ModuleMember -Function New-MorphospaceToolingContextResolver,Get-MorphospaceToolingContextProtocolId,Get-MorphospaceToolingContextAllowedActions,Get-ToolingContextSha256,New-MorphospaceToolingContext,New-MorphospaceObservedToolingContext,Assert-MorphospaceToolingContext,Read-MorphospaceToolingContextResolver,Assert-MorphospaceToolingContextLocalObservation,Assert-MorphospaceToolingContextHistoricalObservation,Assert-MorphospaceToolingContextOwnerValidationEvidence,Test-MorphospaceToolingContextCompatibility,Assert-MorphospaceToolingContextLoadedOwnerModule
