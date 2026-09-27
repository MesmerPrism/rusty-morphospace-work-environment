$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$warningPreferenceBeforeImports = $WarningPreference
try {
    $WarningPreference = 'SilentlyContinue'
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceOwnership.psm1') -Force
    $script:OwnershipModule = Get-Module MorphospaceOwnership
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceContentObservation.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
} finally {
    $WarningPreference = $warningPreferenceBeforeImports
}

function Assert-RunnerFast {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Fast validation-authority runner self-test failed: $Message" }
}

function Write-TestText {
    param([string]$Path,[string]$Text)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

function Write-TestJson {
    param([string]$Path,[object]$Value)
    Write-TestText $Path (($Value | ConvertTo-Json -Depth 100 -Compress) + "`n")
}

function Invoke-TestGit {
    param([string]$Git,[string]$Repository,[string[]]$Arguments)
    $output = @(& $Git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($Arguments -join ' ') $($output -join ' ')" }
    return [string]($output -join '')
}

function Get-RunnerFastFixtureImportCommands {
    param([string]$Path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw "Authority runner fixture module is not parseable: $Path"}
    return @($ast.FindAll({param($node) $node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ieq'Import-Module'},$true))
}
function Get-RunnerFastFixtureClosedRootPath {
    param([Management.Automation.Language.Ast]$Expression)
    if($Expression-is[Management.Automation.Language.PipelineAst]){if(-not$Expression.Background-and$Expression.PipelineElements.Count-eq1){return Get-RunnerFastFixtureClosedRootPath $Expression.PipelineElements[0]};return $null}
    if($Expression-is[Management.Automation.Language.CommandExpressionAst]){return Get-RunnerFastFixtureClosedRootPath $Expression.Expression}
    if($Expression-is[Management.Automation.Language.ParenExpressionAst]){return Get-RunnerFastFixtureClosedRootPath $Expression.Pipeline}
    if($Expression-is[Management.Automation.Language.CommandAst]){
        if($Expression.GetCommandName()-ine'Join-Path'-or$Expression.CommandElements.Count-ne3-or$Expression.Redirections.Count-ne0-or$Expression.InvocationOperator-ne[Management.Automation.Language.TokenKind]::Unknown){return $null}
        $root=$Expression.CommandElements[1];$child=$Expression.CommandElements[2]
        if($root-isnot[Management.Automation.Language.VariableExpressionAst]-or$root.VariablePath.UserPath-ine'PSScriptRoot'-or$child-isnot[Management.Automation.Language.StringConstantExpressionAst]){return $null}
        if($child.Value.EndsWith('.psm1',[StringComparison]::OrdinalIgnoreCase)){return [string]$child.Value};return $null
    }
    if($Expression-is[Management.Automation.Language.InvokeMemberExpressionAst]){
        if(-not$Expression.Static-or$Expression.Expression-isnot[Management.Automation.Language.TypeExpressionAst]-or$Expression.Expression.TypeName.FullName-ine'IO.Path'-or$Expression.Member-isnot[Management.Automation.Language.StringConstantExpressionAst]){return $null}
        if($Expression.Member.Value-ieq'GetFullPath'-and$Expression.Arguments.Count-eq1){return Get-RunnerFastFixtureClosedRootPath $Expression.Arguments[0]}
        if($Expression.Member.Value-ieq'Combine'-and$Expression.Arguments.Count-eq2){
            $root=$Expression.Arguments[0];$child=$Expression.Arguments[1]
            if($root-is[Management.Automation.Language.VariableExpressionAst]-and$root.VariablePath.UserPath-ieq'PSScriptRoot'-and$child-is[Management.Automation.Language.StringConstantExpressionAst]-and$child.Value.EndsWith('.psm1',[StringComparison]::OrdinalIgnoreCase)){return [string]$child.Value}
        }
    }
    return $null
}
function Get-RunnerFastFixtureModuleClosure {
    param(
        [string]$Git,
        [string]$SourceRoot,
        [string[]]$SeedPaths
    )

    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Queue[string]]::new()
    $auditedDynamicImportCounts = @{
        # These two imports are literal child-fixture bodies that intentionally
        # receive a temporary damage-test module path at runtime. They are not
        # repository module edges, and their exact file/variable/count is part
        # of this clean-room closure contract.
        'scripts/Test-TransitionLedger.ps1|modulepath' = 2
        # The AST storage identity includes the exact using-variable component.
        'scripts/Test-AuthorityRecordReadiness.ps1|using:processmodule' = 1
    }
    $observedAuditedDynamicImports = @{}
    # These runtime imports use an authenticated historical executor root. The
    # current logical target is a recursive fixture copy dependency, not an
    # assertion that the historical runtime root is the current repository.
    $auditedDynamicTargetImports=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $auditedDynamicTargetImports.Add('scripts/CandidateFreeze.psm1|Get-FrozenContinuationObservationModule|scriptsroot|lib/MorphospaceRepositoryObservation.psm1',@{count=1;target='scripts/lib/MorphospaceRepositoryObservation.psm1'})
    $observedDynamicTargetImports=@{}

    function Add-RunnerFastFixturePath {
        param([string]$RelativePath)

        $normalized = $RelativePath.Replace('\','/')
        if ($normalized -notmatch '^(?:scripts|schemas)/[^:]+$' -or $normalized -match '(?:^|/)\.\.?/') {
            throw "Authority runner fixture import path is not repository-relative: $RelativePath"
        }
        $absolute = [IO.Path]::GetFullPath((Join-Path $root $normalized))
        if (-not $absolute.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Authority runner fixture import escapes the repository: $RelativePath"
        }
        if (-not [IO.File]::Exists($absolute)) {
            throw "Authority runner fixture import is absent: $normalized"
        }
        $tracked = @(& $Git -C $root ls-files --error-unmatch -- $normalized 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Authority runner fixture import is not tracked: $normalized $($tracked -join ' ')"
        }
        if ($paths.Add($normalized) -and
            ($normalized.EndsWith('.psm1',[StringComparison]::OrdinalIgnoreCase) -or
             $normalized.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase))) {
            $pending.Enqueue($normalized)
        }
    }

    foreach ($seed in @($SeedPaths)) { Add-RunnerFastFixturePath $seed }
    $importPattern = '[''"](?<path>[^''"]+\.psm1)[''"]'
    while ($pending.Count -gt 0) {
        $modulePath = $pending.Dequeue()
        $moduleAbsolute = Join-Path $root $modulePath
        $moduleDirectory = [IO.Path]::GetDirectoryName($moduleAbsolute)
        $tokens=$null;$errors=$null
        $moduleAst=[Management.Automation.Language.Parser]::ParseFile($moduleAbsolute,[ref]$tokens,[ref]$errors)
        if(@($errors).Count){throw "Authority runner fixture module is not parseable: $modulePath"}
        $variableWrites=@{}
        foreach($write in @($moduleAst.FindAll({param($node) $node-is[Management.Automation.Language.AssignmentStatementAst]},$true))){
            $leaves=@($write.Left.FindAll({param($node) $node-is[Management.Automation.Language.VariableExpressionAst]},$true))
            foreach($leaf in $leaves){
                $name=[string]$leaf.VariablePath.UserPath
                $owner=$write.Parent;while($null-ne$owner-and$owner-isnot[Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
                $scriptStorage=$name.StartsWith('script:',[StringComparison]::OrdinalIgnoreCase)
                if($scriptStorage){$name=$name.Substring(7)}elseif($name.StartsWith('local:',[StringComparison]::OrdinalIgnoreCase)){$name=$name.Substring(6)}elseif($name.StartsWith('private:',[StringComparison]::OrdinalIgnoreCase)){$name=$name.Substring(8)}elseif($name.Contains(':')){continue}
                $name=$name.ToLowerInvariant()
                $scope=if($scriptStorage-or$null-eq$owner){'module'}else{[string]$owner.Extent.StartOffset}
                $key="$scope|$name"
                if(-not$variableWrites.ContainsKey($key)){$variableWrites[$key]=[Collections.Generic.List[object]]::new()}
                $path=$null
                if($write.Left-is[Management.Automation.Language.VariableExpressionAst]-and$write.Operator-eq[Management.Automation.Language.TokenKind]::Equals){
                    $path=Get-RunnerFastFixtureClosedRootPath $write.Right
                }
                $variableWrites[$key].Add([pscustomobject]@{assignment=$write;path=$path})
            }
        }
        foreach ($importCommand in @(Get-RunnerFastFixtureImportCommands $moduleAbsolute)) {
            $line = $importCommand.Extent.Text
            if($importCommand.CommandElements.Count-lt2){throw "Authority runner fixture import lacks a closed module argument: $modulePath"}
            $argument=$importCommand.CommandElements[1]
            foreach($extra in @($importCommand.CommandElements|Select-Object -Skip 2)){
                $extraModules=@($extra.FindAll({param($node) $node-is[Management.Automation.Language.StringConstantExpressionAst]-and$node.Value.EndsWith('.psm1',[StringComparison]::OrdinalIgnoreCase)},$true))
                if($extraModules.Count){throw "Authority runner fixture import has an unrelated module literal argument: $modulePath"}
            }
            $importPath=$null
            if($argument-is[Management.Automation.Language.StringConstantExpressionAst]){
                $importPath=[string]$argument.Value
            }elseif($argument-is[Management.Automation.Language.VariableExpressionAst]-or$argument-is[Management.Automation.Language.UsingExpressionAst]){
                $usingStorage=$argument-is[Management.Automation.Language.UsingExpressionAst]
                $variableName=if($usingStorage){'using:'+([string]$argument.SubExpression.VariablePath.UserPath).ToLowerInvariant()}else{([string]$argument.VariablePath.UserPath).ToLowerInvariant()}
                $scriptStorage=$variableName.StartsWith('script:',[StringComparison]::Ordinal)
                $name=if($scriptStorage){$variableName.Substring(7)}else{$variableName}
                if(-not$usingStorage-and$name.Contains(':')){throw "Authority runner fixture import variable scope is not closed: $modulePath"}
                $importOwner=$importCommand.Parent;while($null-ne$importOwner-and$importOwner-isnot[Management.Automation.Language.FunctionDefinitionAst]){$importOwner=$importOwner.Parent}
                $scope=if($scriptStorage-or$null-eq$importOwner){'module'}else{[string]$importOwner.Extent.StartOffset}
                $key="$scope|$name"
                if(-not$variableWrites.ContainsKey($key)){$key="module|$name"}
                if(-not$usingStorage-and$variableWrites.ContainsKey($key)){
                    $definitions=$variableWrites[$key]
                    if($definitions.Count-ne1-or$null-eq$definitions[0].path){throw "Authority runner fixture module variable has unknown or ambiguous writes: $modulePath|$variableName"}
                    $definition=$definitions[0].assignment
                    if($definition.Extent.EndOffset-ge$importCommand.Extent.StartOffset){throw "Authority runner fixture module variable definition does not precede its import: $modulePath|$variableName"}
                    $container=$importCommand.Parent;$dominates=$false
                    while($null-ne$container){if($container.Extent.StartOffset-eq$definition.Parent.Extent.StartOffset-and$container.Extent.EndOffset-eq$definition.Parent.Extent.EndOffset){$dominates=$true;break};$container=$container.Parent}
                    if(-not$dominates){throw "Authority runner fixture module variable definition does not dominate its import: $modulePath|$variableName"}
                    if($key.StartsWith('module|',[StringComparison]::Ordinal)-and-not$scriptStorage){
                        $enclosing=$importCommand.Parent
                        while($null-ne$enclosing){
                            if($enclosing-is[Management.Automation.Language.FunctionDefinitionAst]){
                                $parameters=@($enclosing.Parameters);if($null-ne$enclosing.Body.ParamBlock){$parameters+=@($enclosing.Body.ParamBlock.Parameters)}
                                foreach($parameter in $parameters){if($parameter.Name.VariablePath.UserPath-ieq$name){throw "Authority runner fixture module variable is shadowed by an import-scope parameter: $modulePath|$variableName"}}
                                if($variableWrites.ContainsKey("$($enclosing.Extent.StartOffset)|$name")){throw "Authority runner fixture module variable is shadowed by an enclosing function write: $modulePath|$variableName"}
                            }
                            $enclosing=$enclosing.Parent
                        }
                    }
                    $importPath=[string]$definitions[0].path
                }else{
                    $auditKey="$modulePath|$variableName"
                    if(-not$auditedDynamicImportCounts.ContainsKey($auditKey)){throw "Authority runner fixture import has no audited dynamic declaration: $auditKey"}
                    $observedAuditedDynamicImports[$auditKey]=1+$(if($observedAuditedDynamicImports.ContainsKey($auditKey)){[int]$observedAuditedDynamicImports[$auditKey]}else{0})
                    continue
                }
            }else{
                $expression=$argument.Extent.Text
                $importPath=Get-RunnerFastFixtureClosedRootPath $argument
                if($null-eq$importPath){
                    $dynamicTarget=[regex]::Match($expression,'^\(\s*Join-Path\s+\$(?<root>[A-Za-z_][A-Za-z0-9_]*)\s+[''"](?<suffix>[^''"]+\.psm1)[''"]\s*\)$')
                    $owner=$importCommand.Parent;while($null-ne$owner-and$owner-isnot[Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
                    $functionName=if($null-ne$owner){[string]$owner.Name}else{''}
                    $targetKey="$modulePath|$functionName|$($dynamicTarget.Groups['root'].Value.ToLowerInvariant())|$($dynamicTarget.Groups['suffix'].Value)"
                    if(-not$dynamicTarget.Success-or-not$auditedDynamicTargetImports.ContainsKey($targetKey)){throw "Authority runner fixture import root expression is not closed: $modulePath $expression"}
                    $observedDynamicTargetImports[$targetKey]=1+$(if($observedDynamicTargetImports.ContainsKey($targetKey)){[int]$observedDynamicTargetImports[$targetKey]}else{0})
                    Add-RunnerFastFixturePath ([string]$auditedDynamicTargetImports[$targetKey].target)
                    continue
                }
            }
            $importAbsolute = [IO.Path]::GetFullPath((Join-Path $moduleDirectory $importPath))
            if (-not $importAbsolute.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
                throw "Authority runner fixture module import escapes the repository: $modulePath"
            }
            $importRelative = [IO.Path]::GetRelativePath($root,$importAbsolute).Replace('\','/')
            Add-RunnerFastFixturePath $importRelative
        }
    }
    foreach ($auditKey in @($auditedDynamicImportCounts.Keys)) {
        $auditPath = $auditKey.Substring(0,$auditKey.LastIndexOf('|',[StringComparison]::Ordinal))
        if (-not $paths.Contains($auditPath)) { continue }
        $observedCount = if ($observedAuditedDynamicImports.ContainsKey($auditKey)) { [int]$observedAuditedDynamicImports[$auditKey] } else { 0 }
        if ($observedCount -ne [int]$auditedDynamicImportCounts[$auditKey]) {
            throw "Authority runner fixture audited dynamic import count changed: $auditKey expected=$($auditedDynamicImportCounts[$auditKey]) observed=$observedCount"
        }
    }

    foreach($targetKey in @($auditedDynamicTargetImports.Keys)){
        $declaringPath=$targetKey.Substring(0,$targetKey.IndexOf('|',[StringComparison]::Ordinal))
        if(-not$paths.Contains($declaringPath)){continue}
        $observedCount=if($observedDynamicTargetImports.ContainsKey($targetKey)){[int]$observedDynamicTargetImports[$targetKey]}else{0}
        if($observedCount-ne[int]$auditedDynamicTargetImports[$targetKey].count){throw "Authority runner fixture dynamic target import count changed: $targetKey expected=$($auditedDynamicTargetImports[$targetKey].count) observed=$observedCount"}
    }

    $result = @($paths)
    [Array]::Sort($result,[StringComparer]::Ordinal)
    return $result
}

function Initialize-TestGitRepository {
    param([string]$Git,[string]$Repository,[string]$Message)
    Invoke-TestGit $Git $Repository @('init','--quiet') | Out-Null
    Invoke-TestGit $Git $Repository @('config','user.name','Authority Runner Fixture') | Out-Null
    Invoke-TestGit $Git $Repository @('config','user.email','authority-runner@example.invalid') | Out-Null
    Invoke-TestGit $Git $Repository @('config','core.autocrlf','false') | Out-Null
    Invoke-TestGit $Git $Repository @('add','--','.') | Out-Null
    Invoke-TestGit $Git $Repository @('commit','--quiet','-m',$Message) | Out-Null
}

function Get-TestObservedEntries {
    param([object]$Observation,[switch]$Baseline)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Observation.entries)) {
        $normalized = & $script:OwnershipModule { param($RepositoryObservation,$RepositoryEntry) New-MorphospaceObservedEntry $RepositoryObservation $RepositoryEntry } $Observation $entry
        $core = $normalized.core
        if ($Baseline) {
            $rows.Add([pscustomobject][ordered]@{path=[string]$core.path;entry_fingerprint_sha256=[string]$normalized.fingerprint_sha256;state=[string]$core.state;sha256=$core.sha256;length=$core.length;mode=$core.mode;patch_sha256=$core.patch_sha256;hunks=@($core.hunks)}) | Out-Null
        } else {
            $rows.Add($normalized) | Out-Null
        }
    }
    $array = @($rows.ToArray())
    [Array]::Sort($array,[Comparison[object]]{
        param($Left,$Right)
        $leftPath = if ($Baseline) { [string]$Left.path } else { [string]$Left.core.path }
        $rightPath = if ($Baseline) { [string]$Right.path } else { [string]$Right.core.path }
        [StringComparer]::Ordinal.Compare($leftPath,$rightPath)
    })
    return $array
}

function Get-TestOrdinalSha256 {
    param([object]$Value)
    return Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{value=$Value})
}

function Get-TestComparableObservation {
    param([object]$Observation,[object[]]$AutomationOutputs)
    return & $script:OwnershipModule {
        param($RepositoryObservation,$Outputs)
        ConvertTo-MorphospaceComparableRepositoryObservation -Observation $RepositoryObservation -AutomationOutputs $Outputs
    } $Observation $AutomationOutputs
}

function Get-TestAutomationOutputContract {
    param([object]$Ownership,[object]$Unit)
    $scopes = @{}
    foreach ($scope in @($Unit.allowed_repositories)) { $scopes[[string]$scope.repo_id] = $scope }
    return @(& $script:OwnershipModule {
        param($Owned,$IterationUnit,$AllowedScopes)
        Get-MorphospaceAutomationOutputContract -Ownership $Owned -Unit $IterationUnit -Scopes $AllowedScopes
    } $Ownership $Unit $scopes)
}

function Invoke-TestAutomationOutputCheck {
    param([object[]]$AutomationOutputs,[hashtable]$RepositoryMap,[string]$Expected,[string]$Phase)
    & $script:OwnershipModule {
        param($Outputs,$Map,$ExpectedState,$OutputPhase)
        Test-MorphospaceAutomationOutputSet -AutomationOutputs $Outputs -RepositoryMap $Map -Expected $ExpectedState -Phase $OutputPhase
    } $AutomationOutputs $RepositoryMap $Expected $Phase
}

function Remove-TestContentAddressedCache {
    param([string]$CapsuleSha256)
    & $script:OwnershipModule {
        param($Capsule)
        $cached = Open-MorphospaceContentAddressedCleanRoom -CapsuleSha256 $Capsule -MaterializedInputsSha256 $Capsule
        if ($null -ne $cached) { Remove-MorphospaceContentAddressedCleanRoom $cached -RemoveManifest }
    } $CapsuleSha256
}

function New-TestBaselineRow {
    param([object]$Observation,[string[]]$AllowedPaths)
    $entries = @(Get-TestObservedEntries $Observation -Baseline)
    $instructionSha = Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=@()})
    return [pscustomobject][ordered]@{
        repo_id=[string]$Observation.repo_id;kind=[string]$Observation.kind;head_revision=if([string]$Observation.kind-ceq'git'){[string]$Observation.head_revision}else{$null};head_tree_oid=if([string]$Observation.kind-ceq'git'){[string]$Observation.head_tree}else{$null};branch=if([string]$Observation.kind-ceq'git'){[string]$Observation.branch}else{$null}
        allowed_paths=@($AllowedPaths);content_observation_sha256=Get-MorphospaceCanonicalJsonSha256 $Observation;status_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.status_sha256}else{$null};overlay_fingerprint_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.overlay_fingerprint_sha256}else{[string]$Observation.tree_fingerprint_sha256}
        commit_manifest_fingerprint_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.commit_fingerprint_sha256}else{$null};instruction_observation_sha256=$instructionSha;entries_fingerprint_sha256=Get-TestOrdinalSha256 $entries;entries=$entries
        instructions_fingerprint_sha256=$instructionSha;instructions=@()
    }
}

function New-TestOwnershipRow {
    param([object]$BaselineRow,[object]$Observation)
    $baseline = @{}
    foreach ($entry in @($BaselineRow.entries)) { $baseline[[string]$entry.path] = $entry }
    $preserved = [Collections.Generic.List[string]]::new()
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($normalized in @(Get-TestObservedEntries $Observation)) {
        $core = $normalized.core
        $path = [string]$core.path
        $prior = if ($baseline.ContainsKey($path)) { $baseline[$path] } else { $null }
        if ($null -ne $prior -and [string]$prior.entry_fingerprint_sha256 -ceq [string]$normalized.fingerprint_sha256) {
            $preserved.Add([string]$prior.entry_fingerprint_sha256) | Out-Null
            continue
        }
        $entries.Add([pscustomobject][ordered]@{
            path=$path;final_entry_fingerprint_sha256=[string]$normalized.fingerprint_sha256;baseline_entry_fingerprint_sha256=if($null -eq $prior){$null}else{[string]$prior.entry_fingerprint_sha256}
            state=[string]$core.state;sha256=$core.sha256;length=$core.length;mode=$core.mode;patch_sha256=$core.patch_sha256;hunks=@($core.hunks);attribution=if($null -eq $prior){'unit'}else{'shared'}
        }) | Out-Null
    }
    foreach ($prior in @($BaselineRow.entries)) {
        if (@($Observation.entries | Where-Object { [string]$_.path -ceq [string]$prior.path }).Count -eq 0) { $preserved.Add([string]$prior.entry_fingerprint_sha256) | Out-Null }
    }
    $entryArray = @($entries.ToArray())
    [Array]::Sort($entryArray,[Comparison[object]]{param($Left,$Right)[StringComparer]::Ordinal.Compare([string]$Left.path,[string]$Right.path)})
    $preservedArray = @($preserved.ToArray() | Sort-Object -Unique)
    return [pscustomobject][ordered]@{
        repo_id=[string]$Observation.repo_id;kind=[string]$Observation.kind;base_revision=if([string]$Observation.kind-ceq'git'){[string]$BaselineRow.head_revision}else{$null};head_revision=if([string]$Observation.kind-ceq'git'){[string]$Observation.head_revision}else{$null};head_tree_oid=if([string]$Observation.kind-ceq'git'){[string]$Observation.head_tree}else{$null};branch=if([string]$Observation.kind-ceq'git'){[string]$Observation.branch}else{$null}
        allowed_paths=@($BaselineRow.allowed_paths);live_content_observation_sha256=Get-MorphospaceCanonicalJsonSha256 $Observation;live_status_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.status_sha256}else{$null};live_overlay_fingerprint_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.overlay_fingerprint_sha256}else{[string]$Observation.tree_fingerprint_sha256}
        live_commit_manifest_fingerprint_sha256=if([string]$Observation.kind-ceq'git'){[string]$Observation.commit_fingerprint_sha256}else{$null};baseline_entries_sha256=[string]$BaselineRow.entries_fingerprint_sha256;preserved_baseline_entries_sha256=Get-TestOrdinalSha256 $preservedArray
        preserved_baseline_count=$preservedArray.Count;instruction_observation_sha256=[string]$BaselineRow.instruction_observation_sha256;entries=$entryArray
    }
}

function ConvertTo-TestProcessArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"','\"') + '"'
}

function Get-TestPowerShellHost {
    $property = [Environment].GetProperty('ProcessPath')
    if ($null -ne $property) {
        $candidate = [string]$property.GetValue($null,$null)
        if ($candidate) { return $candidate }
    }
    return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

function Invoke-TestRunnerProcess {
    param(
        [string]$Runner,
        [string[]]$Arguments,
        [ValidateRange(30,900)]
        [int]$TimeoutSeconds=480
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Get-TestPowerShellHost
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $processArguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Runner) + $Arguments
    if ($start.PSObject.Properties.Name -contains 'ArgumentList') {
        foreach ($argument in $processArguments) { [void]$start.ArgumentList.Add([string]$argument) }
    } else {
        $start.Arguments = (@($processArguments | ForEach-Object { ConvertTo-TestProcessArgument ([string]$_) }) -join ' ')
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            } catch {
                try { & taskkill.exe /PID $process.Id /T /F | Out-Null } catch {}
                try { $process.Kill() } catch {}
            }
            try { $process.WaitForExit(5000) | Out-Null } catch {}
            throw "Authority runner fixture exceeded ${TimeoutSeconds}s."
        }
        $exitCode = [int]$process.ExitCode
    } finally {
        if (-not $process.HasExited) {
            try {
                $process.Kill($true)
            } catch {
                try { & taskkill.exe /PID $process.Id /T /F | Out-Null } catch {}
                try { $process.Kill() } catch {}
            }
        }
    }
    $stdout = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { '' }
    $stderr = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { '' }
    $process.Dispose()
    $stopwatch.Stop()
    return [pscustomobject]@{
        exit_code=$exitCode
        elapsed_ms=[long]$stopwatch.ElapsedMilliseconds
        stdout=$stdout
        stderr=$stderr
    }
}

function New-TestNonce {
    $bytes = [byte[]]::new(32)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
}

function Remove-TestTree {
    param([string]$Path,[string]$ExpectedParent)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $resolved = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing fixture cleanup outside $ExpectedParent" }
    foreach ($file in [IO.Directory]::EnumerateFiles($resolved,'*',[IO.SearchOption]::AllDirectories)) { try { [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal) } catch {} }
    [IO.Directory]::Delete($resolved,$true)
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$root = Join-Path $tempRoot ('morphospace-authority-runner-fast-' + [guid]::NewGuid().ToString('N'))
$capsuleSha256 = ''
$reportRoots = [Collections.Generic.List[string]]::new()
try {
    $git = (Get-MorphospaceBoundExecutable git).path
    $closureFixture = Join-Path $root 'module-closure'
    [IO.Directory]::CreateDirectory((Join-Path $closureFixture 'scripts')) | Out-Null
    Write-TestText (Join-Path $closureFixture 'scripts\root.ps1') "Import-Module (Join-Path `$PSScriptRoot 'middle.psm1') -Force`n"
    Write-TestText (Join-Path $closureFixture 'scripts\middle.psm1') "Import-Module (Join-Path `$PSScriptRoot 'leaf.psm1') -Force`n"
    Write-TestText (Join-Path $closureFixture 'scripts\leaf.psm1') "Set-StrictMode -Version 2.0`n"
    Write-TestText (Join-Path $closureFixture 'scripts\missing-entry.ps1') "Import-Module (Join-Path `$PSScriptRoot 'absent.psm1') -Force`n"
    Write-TestText (Join-Path $closureFixture 'scripts\dynamic-entry.ps1') "`$module = 'leaf.psm1'`nImport-Module `$module -Force`n"
    Write-TestText (Join-Path $closureFixture 'scripts\scoped-entry.ps1') "`$script:ScopedModulePath = Join-Path `$PSScriptRoot 'leaf.psm1'`nImport-Module `$script:ScopedModulePath`n"
    Write-TestText (Join-Path $closureFixture 'scripts\full-path-entry.ps1') "`$path = [IO.Path]::GetFullPath((Join-Path `$PSScriptRoot 'leaf.psm1'))`nImport-Module `$path`n"
    Initialize-TestGitRepository $git $closureFixture 'fixture module closure'
    $closureProbe = @(Get-RunnerFastFixtureModuleClosure -Git $git -SourceRoot $closureFixture -SeedPaths @('scripts/root.ps1'))
    Assert-RunnerFast (($closureProbe -join ',') -ceq 'scripts/leaf.psm1,scripts/middle.psm1,scripts/root.ps1') 'tracked entrypoint and module import closure was not derived exactly'
    $literalVariableProbe = @(Get-RunnerFastFixtureModuleClosure -Git $git -SourceRoot $closureFixture -SeedPaths @('scripts/scoped-entry.ps1','scripts/full-path-entry.ps1'))
    Assert-RunnerFast (($literalVariableProbe -join ',') -ceq 'scripts/full-path-entry.ps1,scripts/leaf.psm1,scripts/scoped-entry.ps1') 'scoped or normalized literal module import closure was not derived exactly'
    foreach ($damagePath in @('scripts/missing-entry.ps1','scripts/dynamic-entry.ps1')) {
        $damageRejected = $false
        try { [void](Get-RunnerFastFixtureModuleClosure -Git $git -SourceRoot $closureFixture -SeedPaths @($damagePath)) } catch { $damageRejected = $true }
        Assert-RunnerFast $damageRejected "module import closure accepted damaged edge '$damagePath'"
    }
    # Import discovery is actual command syntax, not quoted comparison data.
    $scannerCases=@(
        @{id='quoted-data';body='if ($value -ceq ''Import-Module (Join-Path $PSScriptRoot ''''missing.psm1'''')'') {}';valid=$true},
        @{id='comment-data';body='# Import-Module ''missing.psm1''';valid=$true},
        @{id='here-string-data';body="`$text=@'`nImport-Module 'missing.psm1'`n'@";valid=$true},
        @{id='multiline-import';body="Import-Module (`n Join-Path `$PSScriptRoot 'leaf.psm1'`n)";valid=$true},
        @{id='same-line-imports';body="Import-Module 'leaf.psm1'; Import-Module 'leaf.psm1'";valid=$true},
        @{id='foreign-root';body="Import-Module (Join-Path `$oldRoot 'leaf.psm1')";valid=$false},
        @{id='unrelated-module-argument';body="Import-Module (Join-Path `$PSScriptRoot 'leaf.psm1') -ArgumentList 'unrelated.psm1'";valid=$false}
    )
    foreach($case in $scannerCases){Write-TestText (Join-Path $closureFixture ("scripts/$($case.id).ps1")) ([string]$case.body)}
    Invoke-TestGit $git $closureFixture @('add','--','scripts')|Out-Null
    foreach($case in $scannerCases){
        $rejected=$false;try{[void](Get-RunnerFastFixtureModuleClosure $git $closureFixture @("scripts/$($case.id).ps1"))}catch{$rejected=$true}
        Assert-RunnerFast ($rejected-ne[bool]$case.valid) "actual import scanner case '$($case.id)' disagreed with its closed syntax contract"
    }
    $bindingCases=@(
        @{id='computed-suffix';body="`$path=Join-Path `$PSScriptRoot 'leaf.psm1' + `$suffix`nImport-Module `$path";category='unknown or ambiguous writes'},
        @{id='unknown-reassignment';body="`$path=Join-Path `$PSScriptRoot 'leaf.psm1'`n`$path=`$foreign`nImport-Module `$path";category='unknown or ambiguous writes'},
        @{id='future-definition';body="Import-Module `$path`n`$path=Join-Path `$PSScriptRoot 'leaf.psm1'";category='does not precede'},
        @{id='branch-definition';body="if (`$condition) { `$path=Join-Path `$PSScriptRoot 'leaf.psm1' }`nImport-Module `$path";category='does not dominate'},
        @{id='script-storage-alias';body="`$path=Join-Path `$PSScriptRoot 'leaf.psm1'`nfunction Set-Damage { `$script:path=`$foreign }`nImport-Module `$path";category='unknown or ambiguous writes'}
    )
    $bindingCases+=@(
        @{id='expandable-path';body="`$path=Join-Path `$PSScriptRoot `"leaf`$part.psm1`"`nImport-Module `$path";category='unknown or ambiguous writes'},
        @{id='local-storage-alias';body="`$path=Join-Path `$PSScriptRoot 'leaf.psm1'`n`$local:path=`$foreign`nImport-Module `$path";category='unknown or ambiguous writes'},
        @{id='private-storage-alias';body="`$path=Join-Path `$PSScriptRoot 'leaf.psm1'`n`$private:path=`$foreign`nImport-Module `$path";category='unknown or ambiguous writes'},
        @{id='header-parameter-shadow';body="`$path=Join-Path `$PSScriptRoot 'leaf.psm1'`nfunction Child(`$path) { Import-Module `$path }";category='shadowed by an import-scope parameter'},
        @{id='outer-parameter-shadow';body="`$path=Join-Path `$PSScriptRoot 'leaf.psm1'`nfunction Outer(`$path) { function Inner { Import-Module `$path } }";category='shadowed by an import-scope parameter'},
        @{id='outer-write-shadow';body="`$path=Join-Path `$PSScriptRoot 'leaf.psm1'`nfunction Outer { `$path=`$foreign; function Inner { Import-Module `$path } }";category='shadowed by an enclosing function write'}
    )
    # A raw dollar-sign filename prevents interpolation damage from passing by
    # merely failing a later missing-file check.
    Write-TestText (Join-Path $closureFixture 'scripts/leaf$part.psm1') 'Set-StrictMode -Version 2.0'
    foreach($case in $bindingCases){Write-TestText (Join-Path $closureFixture ("scripts/$($case.id).ps1")) $case.body}
    Invoke-TestGit $git $closureFixture @('add','--','scripts')|Out-Null
    foreach($case in $bindingCases){$rejected=$false;try{[void](Get-RunnerFastFixtureModuleClosure $git $closureFixture @("scripts/$($case.id).ps1"))}catch{if($_.Exception.Message-notlike("*"+$case.category+"*")){throw};$rejected=$true};Assert-RunnerFast $rejected "module variable binding accepted '$($case.id)'"}
    $usingSeed='scripts/Test-AuthorityRecordReadiness.ps1'
    foreach($case in @(
        @{body='& { Import-Module $using:otherModule -Force }';category='no audited dynamic declaration'},
        @{body='& { Import-Module $using:processModule -Force; Import-Module $using:processModule -Force }';category='audited dynamic import count changed'},
        @{body='& {}';category='audited dynamic import count changed'}
    )){Write-TestText (Join-Path $closureFixture $usingSeed) $case.body;Invoke-TestGit $git $closureFixture @('add','--',$usingSeed)|Out-Null;$rejected=$false;try{[void](Get-RunnerFastFixtureModuleClosure $git $closureFixture @($usingSeed))}catch{if($_.Exception.Message-notlike("*"+$case.category+"*")){throw};$rejected=$true};Assert-RunnerFast $rejected 'audited using-variable accepted changed identity or count'}
    Write-TestText (Join-Path $closureFixture $usingSeed) '& { Import-Module $using:processModule -Force }'
    [void](Get-RunnerFastFixtureModuleClosure $git $closureFixture @($usingSeed))
    $targetSeed='scripts/CandidateFreeze.psm1';$targetFile=Join-Path $closureFixture 'scripts/lib/MorphospaceRepositoryObservation.psm1'
    $targetBody='function Get-FrozenContinuationObservationModule { Import-Module (Join-Path $scriptsRoot ''lib/MorphospaceRepositoryObservation.psm1'') -PassThru }'
    Write-TestText (Join-Path $closureFixture $targetSeed) $targetBody
    Write-TestText $targetFile "Import-Module (Join-Path `$PSScriptRoot 'target-child.psm1')"
    Write-TestText (Join-Path $closureFixture 'scripts/lib/target-child.psm1') 'Set-StrictMode -Version 2.0'
    Invoke-TestGit $git $closureFixture @('add','--','scripts')|Out-Null
    $targetClosure=@(Get-RunnerFastFixtureModuleClosure $git $closureFixture @($targetSeed))
    Assert-RunnerFast (($targetClosure-join',')-ceq'scripts/CandidateFreeze.psm1,scripts/lib/MorphospaceRepositoryObservation.psm1,scripts/lib/target-child.psm1') 'declared historical-root target was not added and recursively closed'
    foreach($mutation in @(
        @{body=$targetBody.Replace('$scriptsRoot','$otherRoot');category='root expression is not closed'},
        @{body=$targetBody.Replace('lib/MorphospaceRepositoryObservation.psm1','lib/other.psm1');category='root expression is not closed'},
        @{body=$targetBody.Replace('Get-FrozenContinuationObservationModule','Get-OtherObservationModule');category='root expression is not closed'},
        @{body=$targetBody.Replace('Join-Path $scriptsRoot','Join-Path (Get-OtherRoot)');category='root expression is not closed'},
        @{body=($targetBody+"`n"+$targetBody);category='dynamic target import count changed'},
        @{body='function Get-FrozenContinuationObservationModule {}';category='dynamic target import count changed'}
    )){
        Write-TestText (Join-Path $closureFixture $targetSeed) $mutation.body
        $rejected=$false;try{[void](Get-RunnerFastFixtureModuleClosure $git $closureFixture @($targetSeed))}catch{if($_.Exception.Message-notlike("*"+$mutation.category+"*")){throw};$rejected=$true}
        Assert-RunnerFast $rejected 'declared dynamic target accepted altered root, suffix, owner, expression or count'
    }
    Write-TestText (Join-Path $closureFixture $targetSeed) $targetBody
    [IO.File]::Delete($targetFile)
    $rejected=$false;try{[void](Get-RunnerFastFixtureModuleClosure $git $closureFixture @($targetSeed))}catch{if($_.Exception.Message-notlike'*fixture import is absent:*'){throw};$rejected=$true}
    Assert-RunnerFast $rejected 'declared dynamic target accepted a missing target file'
    Write-TestText $targetFile "Import-Module (Join-Path `$PSScriptRoot 'target-child.psm1')"
    Invoke-TestGit $git $closureFixture @('rm','--cached','--','scripts/lib/MorphospaceRepositoryObservation.psm1')|Out-Null
    $rejected=$false;try{[void](Get-RunnerFastFixtureModuleClosure $git $closureFixture @($targetSeed))}catch{if($_.Exception.Message-notlike'*fixture import is not tracked:*'){throw};$rejected=$true}
    Assert-RunnerFast $rejected 'declared dynamic target accepted an untracked target file'
    Invoke-TestGit $git $closureFixture @('add','--','scripts/lib/MorphospaceRepositoryObservation.psm1')|Out-Null
    $planning = Join-Path $root 'planning'
    $quest = Join-Path $root 'quest'
    $workEnvironment = Join-Path $root 'work-environment'
    $workspaceRelative = 'workspaces/morphospace-platform-iteration/morphospace'
    $workspace = Join-Path $planning ($workspaceRelative.Replace('/','\'))
    foreach ($directory in @($planning,$quest,$workEnvironment,$workspace,(Join-Path $quest 'fixture'))) { [IO.Directory]::CreateDirectory($directory) | Out-Null }

    $authoritySeedPaths = @(
        'scripts/Invoke-MorphospaceValidationAuthority.ps1','scripts/Invoke-WorkUnitAutomation.ps1','scripts/Invoke-Wf005OwnerValidator.ps1','scripts/Test-ValidationAuthorityLauncher.ps1',
        'scripts/Test-AuthorityRunnerHandoff.ps1','scripts/Test-AuthorityRecordReadiness.ps1','scripts/Test-TrustMigrationAuthority.ps1','scripts/Test-ValidationExecutionAuthority.ps1',
        'scripts/Test-TransitionLedger.ps1','scripts/WorkUnitAutomation.psm1','scripts/lib/MorphospaceAuthorityReadiness.psm1','scripts/lib/MorphospaceContentObservation.psm1','scripts/lib/MorphospaceActiveUnitContractReviewCompatibility.psm1',
        'scripts/lib/MorphospaceOwnership.psm1','scripts/lib/MorphospacePlannedPublication.psm1','scripts/lib/MorphospacePlanningProjection.psm1',
        'scripts/lib/MorphospacePlanningSuffixRewrite.psm1','scripts/lib/MorphospaceProtocolCommon.psm1','scripts/lib/MorphospacePublicationRecovery.psm1',
        'scripts/lib/MorphospaceExecutedPreparedPublication.psm1','scripts/lib/MorphospacePublishedPlanningAuthorityAdoption.psm1','scripts/lib/MorphospacePublishedPrerequisiteSuffix.psm1',
        'scripts/lib/MorphospaceTransitionLedger.psm1','scripts/lib/MorphospaceValidationAuthority.psm1',
        # WorkUnitAutomation imports this baseline verifier even when the fixture
        # does not exercise a debt-bearing receipt. Keep the clean-room copy
        # closed over that module and its canonical external-owner verifier.
        'scripts/lib/MorphospaceHistoricalValidationDebtBaseline.psm1','scripts/lib/ExternalOwnerAuthorization.psm1'
    )
    $authorityPaths = @(Get-RunnerFastFixtureModuleClosure -Git $git -SourceRoot $repoRoot -SeedPaths $authoritySeedPaths)
    foreach ($requiredClosurePath in @('scripts/InheritedCandidateMaterialization.psm1','scripts/CandidateFreeze.psm1','scripts/DevelopmentEnvelopeProvenance.psm1','scripts/lib/MorphospaceAuthorityProcess.psm1')) {
        Assert-RunnerFast ($authorityPaths -ccontains $requiredClosurePath) "derived clean-room closure omitted '$requiredClosurePath'"
    }
    $validatorPath = 'scripts/Invoke-Wf005OwnerValidator.ps1'
    foreach ($relative in $authorityPaths) {
        $source = Join-Path $repoRoot $relative
        $target = Join-Path $workEnvironment ($relative.Replace('/','\'))
        $parent = [IO.Path]::GetDirectoryName($target)
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        [IO.File]::Copy($source,$target,$true)
    }
    $fixtureValidator = @'
param([string]$WorkspaceRoot,[string]$QuestRoot,[string]$RoadmapPath,[string]$UnitId,[string]$OutPath,[switch]$ProbeOnly)
$ErrorActionPreference='Stop'
if($UnitId-ne'wf-005'){throw 'fixture unit mismatch'}
$write={param($value)[IO.File]::WriteAllText($OutPath,(($value|ConvertTo-Json -Depth 20 -Compress)+"`n"),[Text.UTF8Encoding]::new($false));$value|ConvertTo-Json -Depth 20 -Compress}
if($ProbeOnly){
  $contract="quick`nnone`ncriterion-a"
  $canonical=([pscustomobject]@{value=$contract}|ConvertTo-Json -Compress)
  $sha=[Security.Cryptography.SHA256]::Create();try{$contractSha=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
  $probe=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.owner_validator_admission_probe.v1';validator_id='fixture-owner';created_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');project_id='fixture-project';unit_id=$UnitId;unit_contract_sha256=$contractSha;commands=@([pscustomobject][ordered]@{command_id='fixture-owner';command_name='fixture-owner.ps1';command_sha256=('1'*64)});acceptance_bindings=@([pscustomobject][ordered]@{acceptance_id='criterion-a';command_id='fixture-owner'});status='pass';does_not_prove=@('Admission-only fixture probe does not execute or prove acceptance.')}
  &$write $probe
  exit 0
}
$criterion=[pscustomobject][ordered]@{acceptance_id='criterion-a';status='pass';command_id='fixture-owner';command_path='fixture-owner.ps1';command_sha256=('1'*64);output_sha256=('2'*64);exit_code=0}
$document=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.owner_validation.v1';validator_id='fixture-owner';created_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');project_id='fixture-project';unit_id=$UnitId;acceptance_ids=@('criterion-a');status='pass';criteria=@($criterion);does_not_prove=@('Fixture evidence proves only the bounded authority-runner test.')}
&$write $document
'@
    Write-TestText (Join-Path $workEnvironment 'scripts\Invoke-Wf005OwnerValidator.ps1') $fixtureValidator
    Initialize-TestGitRepository $git $workEnvironment 'fixture authority release'
    $workEnvironmentHead = (Invoke-TestGit $git $workEnvironment @('rev-parse','HEAD')).Trim()
    $workEnvironmentTree = (Invoke-TestGit $git $workEnvironment @('rev-parse','HEAD^{tree}')).Trim()

    Write-TestText (Join-Path $quest 'fixture\input.txt') "quest-input`n"

    $unit = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';project_id='fixture-project';unit_id='wf-005';status='validating';risk_tier='quick';device_requirement='none';instruction_impact='none';instruction_surfaces=@()
        allowed_repositories=@(
            [pscustomobject]@{repo_id='planning';allowed_paths=@($workspaceRelative)},
            [pscustomobject]@{repo_id='quest';allowed_paths=@('fixture')},
            [pscustomobject]@{repo_id='work-environment';allowed_paths=@($validatorPath)}
        )
        acceptance=@([pscustomobject]@{acceptance_id='criterion-a';proof='fixture';command='fixture-owner'})
        validation=@([pscustomobject]@{profile_id='quick';command='fixture-owner'})
    }
    $repositoryMap = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.repository_map.v1';repositories=@(
            [pscustomobject]@{repo_id='planning';path=$planning;role='planning';aliases=@()},
            [pscustomobject]@{repo_id='quest';path=$quest;role='source';aliases=@()},
            [pscustomobject]@{repo_id='work-environment';path=$workEnvironment;role='source';aliases=@()}
        )
    }
    Write-TestJson (Join-Path $workspace 'project.spec.json') ([pscustomobject]@{schema='rusty.morphospace.workflow.project_spec.v2';project_id='fixture-project'})
    Write-TestJson (Join-Path $workspace 'workspace.state.json') ([pscustomobject]@{schema='rusty.morphospace.workflow.workspace_state.v2';project_id='fixture-project';current_unit='wf-005'})
    Write-TestJson (Join-Path $workspace 'iteration-units\wf-005.json') $unit
    Write-TestJson (Join-Path $workspace 'repository-map.json') $repositoryMap
    Write-TestText (Join-Path $workspace 'fixture-input.txt') "planning-input`n"

    $map = @{
        planning=[pscustomobject]@{repo_id='planning';path=$planning;role='planning';aliases=@()}
        quest=[pscustomobject]@{repo_id='quest';path=$quest;role='source';aliases=@()}
        'work-environment'=[pscustomobject]@{repo_id='work-environment';path=$workEnvironment;role='source';aliases=@()}
    }
    $mapReference = Get-MorphospaceAuthorityReference $workspace (Join-Path $workspace 'repository-map.json') 'repository-map' 'rusty.morphospace.workflow.repository_map.v1'
    $planningBaselineObservation = Get-MorphospaceNonGitTreeObservation planning $planning @($workspaceRelative)
    $questBaselineObservation = Get-MorphospaceNonGitTreeObservation quest $quest @('fixture')
    $workEnvironmentBaselineObservation = Get-MorphospaceGitRepositoryObservation work-environment $workEnvironment $workEnvironmentHead @($validatorPath) $git
    $baselineRows = @(
        New-TestBaselineRow $planningBaselineObservation @($workspaceRelative)
        New-TestBaselineRow $questBaselineObservation @('fixture')
        New-TestBaselineRow $workEnvironmentBaselineObservation @($validatorPath)
    )
    $claim = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.claim_baseline.v1';baseline_id='fixture-claim';created_at='2026-07-13T10:00:00.0000000Z';project_id='fixture-project';unit_id='wf-005';repository_map=$mapReference;repositories=$baselineRows;status='frozen'}
    $claimPath = Join-Path $workspace 'receipts\fixture\claim-baseline.json'
    Write-TestJson $claimPath $claim
    $claimReference = Get-MorphospaceAuthorityReference $workspace $claimPath 'claim-baseline' 'rusty.morphospace.workflow.claim_baseline.v1'

    $automationOutputs = @(
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/registry.json";phase='bootstrap';role='owner-validator-registry';schema='rusty.morphospace.workflow.owner_validator_registry.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/ownership.json";phase='bootstrap';role='unit-ownership';schema='rusty.morphospace.workflow.unit_ownership.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/anchor.json";phase='bootstrap';role='legacy-prefix-anchor';schema='rusty.morphospace.workflow.legacy_event_prefix_anchor.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/migration.json";phase='bootstrap';role='validator-trust-anchor-migration';schema='rusty.morphospace.workflow.validator_trust_anchor_migration.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/protocol.json";phase='bootstrap';role='current-unit-protocol';schema='rusty.morphospace.workflow.current_unit_protocol.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/action.json";phase='bootstrap';role='validation-action';schema='rusty.morphospace.workflow.validation_action.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/runner-release.json";phase='readiness';role='authority-runner-release';schema='rusty.morphospace.workflow.authority_runner_release.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/capsule.json";phase='readiness';role='authority-input-capsule';schema='rusty.morphospace.workflow.authority_input_capsule.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/host.json";phase='readiness';role='authority-host-capabilities';schema='rusty.morphospace.workflow.authority_host_capabilities.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/preflight.json";phase='readiness';role='authority-preflight-result';schema='rusty.morphospace.workflow.authority_preflight_result.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/owner.json";phase='validation';role='owner-validation';schema='rusty.morphospace.workflow.owner_validation.v1';validator_id='fixture-owner'},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/evidence.json";phase='validation';role='validation-evidence';schema='rusty.morphospace.workflow.validation_evidence.v2';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/execution.json";phase='validation';role='validation-execution';schema='rusty.morphospace.workflow.validation_execution.v1';validator_id=$null},
        [pscustomobject]@{repo_id='planning';path="$workspaceRelative/receipts/fixture/receipt.json";phase='validation';role='validation-receipt';schema='rusty.morphospace.workflow.validation_receipt.v2';validator_id=$null}
    )

    $planningCurrent = Get-MorphospaceNonGitTreeObservation planning $planning @($workspaceRelative)
    $questCurrent = Get-MorphospaceNonGitTreeObservation quest $quest @('fixture')
    $workEnvironmentCurrent = Get-MorphospaceGitRepositoryObservation work-environment $workEnvironment $workEnvironmentHead @($validatorPath) $git
    $planningComparableCurrent = Get-TestComparableObservation $planningCurrent @($automationOutputs | Where-Object { [string]$_.repo_id -ceq 'planning' })
    $ownership = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.unit_ownership.v1';ownership_id='fixture-ownership';created_at='2026-07-13T10:01:00.0000000Z';project_id='fixture-project';unit_id='wf-005';claim_baseline=$claimReference
        repositories=@(
            New-TestOwnershipRow $baselineRows[0] $planningComparableCurrent
            New-TestOwnershipRow $baselineRows[1] $questCurrent
            New-TestOwnershipRow $baselineRows[2] $workEnvironmentCurrent
        )
        shared_overlaps=@();automation_outputs=$automationOutputs;status='assigned'
    }

    $validatorAbsolute = Join-Path $workEnvironment ($validatorPath.Replace('/','\'))
    $validatorBlob = (Invoke-TestGit $git $workEnvironment @('rev-parse',"HEAD:$validatorPath")).Trim()
    $validator = [pscustomobject][ordered]@{
        validator_id='fixture-owner';owner_repo_id='work-environment';owner_revision=$workEnvironmentHead;owner_tree_oid=$workEnvironmentTree;path=$validatorPath;sha256=Get-MorphospaceAuthoritySha256 $validatorAbsolute;git_blob_oid=$validatorBlob
        entrypoint='powershell-file';profiles=@('quick');acceptance_ids=@('criterion-a');evidence_schema='rusty.morphospace.workflow.owner_validation.v1'
        input_closure=@(
            [pscustomobject]@{repo_id='planning';kind='non-git-tree';paths=@("$workspaceRelative/fixture-input.txt")},
            [pscustomobject]@{repo_id='quest';kind='non-git-tree';paths=@('fixture/input.txt')},
            [pscustomobject]@{repo_id='work-environment';kind='git-tree';paths=@($validatorPath)}
        )
        history_blobs=@()
        timeout_seconds=30;max_output_bytes=1048576;mutation_policy='temp-output-only';device_policy='forbidden'
    }
    $registry = [pscustomobject][ordered]@{'$schema'='https://example.invalid/owner-validator-registry.schema.json';schema='rusty.morphospace.workflow.owner_validator_registry.v1';registry_id='fixture-registry';revision=1;created_at='2026-07-13T10:02:00.0000000Z';foundation_commit=$workEnvironmentHead;previous_registry=$null;validators=@($validator)}
    $registryPath = Join-Path $workspace 'receipts\fixture\registry.json'
    Write-TestJson $registryPath $registry
    $registryReference = Get-MorphospaceAuthorityReference $workspace $registryPath 'owner-validator-registry' 'rusty.morphospace.workflow.owner_validator_registry.v1'

    $anchor = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.legacy_event_prefix_anchor.v1';anchor_id='wf-005-legacy-prefix';created_at='2026-07-13T10:03:00.0000000Z';project_id='fixture-project';unit_id='wf-005';event_log_path='iteration-events.jsonl';last_sequence=1;prefix_sha256=('3'*64);status='frozen'}
    $anchorPath = Join-Path $workspace 'receipts\fixture\anchor.json'
    Write-TestJson $anchorPath $anchor
    $anchorReference = Get-MorphospaceAuthorityReference $workspace $anchorPath 'legacy-prefix-anchor' 'rusty.morphospace.workflow.legacy_event_prefix_anchor.v1'

    $artifacts = @($authorityPaths | ForEach-Object {
        $relative = [string]$_
        $absolute = Join-Path $workEnvironment ($relative.Replace('/','\'))
        $blob = (Invoke-TestGit $git $workEnvironment @('rev-parse',"HEAD:$relative")).Trim()
        [pscustomobject]@{repo_id='work-environment';path=$relative;sha256=Get-MorphospaceAuthoritySha256 $absolute;git_blob_oid=$blob}
    })
    $migration = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.validator_trust_anchor_migration.v1';project_id='fixture-project';unit_id='wf-005';status='accepted'
        bootstrap_exception=[pscustomobject]@{one_time=$true;non_promotional=$true;self_authorization_scope='authority-adoption-only';normal_ownership_after_commit=$true}
        lineage=@([pscustomobject]@{role='legacy-bootstrap'},[pscustomobject]@{role='protocol-v2'},[pscustomobject]@{role='foundation'},[pscustomobject]@{role='authority'})
        registry=$registryReference;prior_event_anchor=$anchorReference;authority_artifacts=$artifacts
    }
    $migrationPath = Join-Path $workspace 'receipts\fixture\migration.json'
    Write-TestJson $migrationPath $migration
    $migrationReference = Get-MorphospaceAuthorityReference $workspace $migrationPath 'validator-trust-anchor-migration' 'rusty.morphospace.workflow.validator_trust_anchor_migration.v1'

    $ownershipPath = Join-Path $workspace 'receipts\fixture\ownership.json'
    Write-TestJson $ownershipPath $ownership
    $ownershipReference = Get-MorphospaceAuthorityReference $workspace $ownershipPath 'unit-ownership' 'rusty.morphospace.workflow.unit_ownership.v1'
    $protocol = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.current_unit_protocol.v1';protocol_id='fixture-protocol';created_at='2026-07-13T10:04:00.0000000Z';project_id='fixture-project';unit_id='wf-005';authority_revision=$workEnvironmentHead
        registry=$registryReference;trust_anchor_migration=$migrationReference;repository_map=$mapReference;claim_baseline=$claimReference;unit_ownership=$ownershipReference;event_anchor=$anchorReference
        state_sha256=Get-MorphospaceAuthoritySha256 (Join-Path $workspace 'workspace.state.json');unit_sha256=Get-MorphospaceAuthoritySha256 (Join-Path $workspace 'iteration-units\wf-005.json');status='active'
    }
    $protocolPath = Join-Path $workspace 'receipts\fixture\protocol.json'
    Write-TestJson $protocolPath $protocol
    $protocolReference = Get-MorphospaceAuthorityReference $workspace $protocolPath 'current-unit-protocol' 'rusty.morphospace.workflow.current_unit_protocol.v1'

    $automationContract = @(Get-TestAutomationOutputContract -Ownership $ownership -Unit $unit)
    $preObservationDocument = [pscustomobject][ordered]@{repositories=@($planningComparableCurrent,$questCurrent,$workEnvironmentCurrent);instructions=@()}
    $observation = [pscustomobject]@{observation=[pscustomobject]@{document=$preObservationDocument;sha256=Get-MorphospaceCanonicalJsonSha256 $preObservationDocument};automation_outputs=$automationContract}
    $action = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.validation_action.v2';action_id='fixture-action';created_at='2026-07-13T10:05:00.0000000Z';project_id='fixture-project';unit_id='wf-005';attempt_id='fixture-attempt-001';profile_id='quick'
        current_protocol=$protocolReference;registry=$registryReference;ownership=$ownershipReference;claim_baseline=$claimReference;repository_map=$mapReference
        selected_validators=@([pscustomobject]@{validator_id='fixture-owner';registry_entry_sha256=Get-MorphospaceCanonicalJsonSha256 $validator})
        expected_outputs=@($observation.automation_outputs | Where-Object { [string]$_.phase -ceq 'validation' } | Sort-Object repo_id,path)
        pre_observation_sha256=[string]$observation.observation.sha256;device_validation=$null;status='authorized'
    }
    $actionPath = Join-Path $workspace 'receipts\fixture\action.json'
    Write-TestJson $actionPath $action
    Invoke-TestAutomationOutputCheck $observation.automation_outputs $map present bootstrap

    $runner = Join-Path $workEnvironment 'scripts\Invoke-MorphospaceValidationAuthority.ps1'
    $commonArguments = @(
        '-WorkspaceRoot',$workspace,'-UnitId','wf-005','-RegistryPath','receipts/fixture/registry.json','-RepositoryMapPath','repository-map.json',
        '-CurrentProtocolPath','receipts/fixture/protocol.json','-TrustMigrationPath','receipts/fixture/migration.json','-ClaimBaselinePath','receipts/fixture/claim-baseline.json',
        '-OwnershipPath','receipts/fixture/ownership.json','-ValidationActionPath','receipts/fixture/action.json'
    )
    $contextFailureNonce = New-TestNonce
    $contextFailureReport = Join-Path ([IO.Path]::GetTempPath()) "rusty-morphospace-authority-reports\fixture-project\wf-005\fixture-attempt-001\preflight-$contextFailureNonce"
    $reportRoots.Add($contextFailureReport) | Out-Null
    $contextDriftPath = Join-Path $workEnvironment 'unrelated-context-drift.txt'
    Write-TestText $contextDriftPath "context drift`n"
    try {
        $contextFailureRun = Invoke-TestRunnerProcess $runner (@('-Action','Preflight') + $commonArguments + @('-ExecutionNonce',$contextFailureNonce))
        Assert-RunnerFast ($contextFailureRun.exit_code -ne 0) 'stale-baseline context fixture did not fail closed'
        Assert-RunnerFast ([IO.File]::Exists((Join-Path $contextFailureReport 'failure-report.json'))) 'context-load failure did not retain a typed failure report'
        Assert-RunnerFast ([IO.File]::Exists((Join-Path $contextFailureReport 'stage-result.json'))) 'context-load failure did not retain a typed stage result'
        $contextStage = Get-Content -LiteralPath (Join-Path $contextFailureReport 'stage-result.json') -Raw | ConvertFrom-Json
        Assert-RunnerFast ([string]$contextStage.stage -ceq 'context-load' -and [string]$contextStage.result -ceq 'fail') 'context-load failure stage receipt was not bound to the failing stage'
    } finally {
        if ([IO.File]::Exists($contextDriftPath)) { [IO.File]::Delete($contextDriftPath) }
    }
    $preflightNonce = New-TestNonce
    $preflightReport = Join-Path ([IO.Path]::GetTempPath()) "rusty-morphospace-authority-reports\fixture-project\wf-005\fixture-attempt-001\preflight-$preflightNonce"
    $reportRoots.Add($preflightReport) | Out-Null
    $preflightRun = Invoke-TestRunnerProcess $runner (@('-Action','Preflight') + $commonArguments + @('-ExecutionNonce',$preflightNonce))
    Assert-RunnerFast ($preflightRun.exit_code -eq 0) "real Preflight branch failed: $($preflightRun.stderr)"
    $preflightResult = $preflightRun.stdout | ConvertFrom-Json
    Assert-RunnerFast ([string]$preflightResult.status -ceq 'ready-for-record') 'real Preflight branch did not publish ready-for-record'
    $capsule = Get-Content -LiteralPath (Join-Path $workspace 'receipts\fixture\capsule.json') -Raw | ConvertFrom-Json
    $capsuleSha256 = [string]$capsule.capsule_sha256

    $recordNonce = New-TestNonce
    $recordReport = Join-Path ([IO.Path]::GetTempPath()) "rusty-morphospace-authority-reports\fixture-project\wf-005\fixture-attempt-001\record-$recordNonce"
    $reportRoots.Add($recordReport) | Out-Null
    $recordRun = Invoke-TestRunnerProcess $runner (@('-Action','Validate') + $commonArguments + @('-ExecutionNonce',$recordNonce,'-EvidencePath','receipts/fixture/evidence.json','-OutPath','receipts/fixture/receipt.json'))
    Assert-RunnerFast ($recordRun.exit_code -eq 0) "real Validate branch failed: $($recordRun.stderr)"
    $receipt = $recordRun.stdout | ConvertFrom-Json
    Assert-RunnerFast ([string]$receipt.result -ceq 'pass') 'real Validate branch did not produce a passing receipt'
    try {
        $validatedReceipt = Test-MorphospaceValidationReceiptV2 -WorkspaceRoot $workspace -ReceiptReference 'receipts/fixture/receipt.json' -Unit $unit -RepositoryMap $map -ExpectedResult pass -ExpectedExecutionNonce $recordNonce
    } catch {
        throw "Full receipt consumer failed: $([string]$_.Exception.Message)`n$([string]$_.ScriptStackTrace)"
    }
    Assert-RunnerFast ([string]$validatedReceipt.status -ceq 'accepted-evidence') 'published receipt did not survive full consumer validation'

    Write-Host (
        'Fast validation-authority runner self-test passed ' +
        "(context-load=$($contextFailureRun.elapsed_ms)ms; " +
        "preflight=$($preflightRun.elapsed_ms)ms; " +
        "validate=$($recordRun.elapsed_ms)ms)."
    )
} finally {
    if ($capsuleSha256 -match '^[0-9a-f]{64}$') {
        try {
            Remove-TestContentAddressedCache $capsuleSha256
        } catch {}
    }
    foreach ($reportRoot in $reportRoots) {
        try { Remove-TestTree $reportRoot (Join-Path ([IO.Path]::GetTempPath()) 'rusty-morphospace-authority-reports') } catch {}
    }
    if ([IO.Directory]::Exists($root)) { Remove-TestTree $root $tempRoot }
}
