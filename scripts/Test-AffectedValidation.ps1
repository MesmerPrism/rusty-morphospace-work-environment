[CmdletBinding()]
param(
    [switch]$BatchSelfTestOnly,
    [switch]$GraphSelfTestOnly,
    [switch]$DependencyClosureSelfTestOnly,
    [ValidateSet('graph-import-closure','dependency-closure','executor-pass-schema','executor-native-failure-damage','executor-native-exit125-damage','executor-forged-terminal-damage','executor-parent-containment-damage','executor-descendant-containment-damage','executor-output-ceiling-damage','executor-timeout-damage','executor-dual-stream-damage','executor-source-integrity-damage','executor-publication-collision-damage','selection-scenarios','trust-self-executor','trust-routing-contracts','trust-proportional-mappings','trust-damage-final')]
    [string]$SelfTestPhase,
    [string]$SelectionScenarioEvidenceRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationCheckEvidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidationDependencyClosure.psm1') -Force

$selectorPhaseCheckIds = @(
    'affected-selector-graph-import-closure',
    'affected-selector-dependency-closure',
    'affected-selector-executor-pass-schema',
    'affected-selector-executor-native-failure-damage',
    'affected-selector-executor-native-exit125-damage',
    'affected-selector-executor-forged-terminal-damage',
    'affected-selector-executor-parent-containment-damage',
    'affected-selector-executor-descendant-containment-damage',
    'affected-selector-executor-output-ceiling-damage',
    'affected-selector-executor-timeout-damage',
    'affected-selector-executor-dual-stream-damage',
    'affected-selector-executor-source-integrity-damage',
    'affected-selector-executor-publication-collision-damage',
    'affected-selector-selection-scenarios',
    'affected-selector-trust-self-executor',
    'affected-selector-trust-routing-contracts',
    'affected-selector-trust-proportional-mappings',
    'affected-selector-trust-damage-final',
    'affected-selector-selftest'
)
$selectorTrustRootCheckIds = @($selectorPhaseCheckIds + @('affected-topology-selftest','affected-reuse-selftest'))

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-TestEnvironmentDigest { [string[]]$names=@([Environment]::GetEnvironmentVariables('Process').Keys|ForEach-Object{[string]$_});if($names.Count-gt1){[Array]::Sort($names,[StringComparer]::Ordinal)};$text=[Text.StringBuilder]::new();foreach($name in $names){[void]$text.Append($name);[void]$text.Append("`0");[void]$text.Append([string][Environment]::GetEnvironmentVariable($name,'Process'));[void]$text.Append("`0")};return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($text.ToString())))).ToLowerInvariant() }
function Get-AffectedSupervisorResidueIdentity {
    $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$roots.Add([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
    $runnerTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP','Process')
    if (-not [string]::IsNullOrWhiteSpace($runnerTemp) -and [IO.Path]::IsPathRooted($runnerTemp) -and [IO.Directory]::Exists($runnerTemp)) { [void]$roots.Add([IO.Path]::GetFullPath($runnerTemp)) }
    $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $roots) {
        foreach ($pattern in @('w017-affected-child-*','w7-*')) {
            foreach ($path in @(Get-ChildItem -LiteralPath $root -Directory -Filter $pattern -ErrorAction SilentlyContinue)) { [void]$found.Add([IO.Path]::GetFullPath($path.FullName)) }
        }
    }
    [string[]]$paths = @($found)
    if ($paths.Count -gt 1) { [Array]::Sort($paths,[StringComparer]::Ordinal) }
    return ($paths -join "`0")
}
function Invoke-TestGit([string]$Root, [string[]]$Arguments) {
    $result = & git -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git test fixture failed: $($Arguments -join ' ')`n$($result -join "`n")" }
    return ($result -join "`n").Trim()
}
function Invoke-TestGitInput([string]$Root, [string[]]$Arguments, [string]$InputText) {
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.WorkingDirectory = [System.IO.Path]::GetFullPath($Root)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $start.StandardInputEncoding = $strictUtf8
    $start.StandardOutputEncoding = $strictUtf8
    $start.StandardErrorEncoding = $strictUtf8
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'git fixture process did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { try { $process.Kill($true) } catch {}; throw 'git fixture process timed out.' }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "git test fixture with input failed: $($Arguments -join ' ')`n$stderr" }
        return $stdout.Trim()
    } finally { $process.Dispose() }
}
function Write-Utf8([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false)) }
function Update-AffectedInventoryFileRecord([string]$InventoryRoot,[string]$FilePath) {
    $root = [IO.Path]::GetFullPath($InventoryRoot)
    $full = [IO.Path]::GetFullPath($FilePath)
    $relative = [IO.Path]::GetRelativePath($root,$full).Replace('\','/')
    $inventoryPath = Join-Path $root 'inventory.json'
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -Depth 64 -DateKind String
    $matched = 0
    foreach ($entry in @($inventory.entries)) {
        foreach ($property in @('receipt','stdout','stderr')) {
            if ([string]$entry.$property.path -cne $relative) { continue }
            [byte[]]$bytes = [IO.File]::ReadAllBytes($full)
            $entry.$property.bytes = [long]$bytes.Length
            $entry.$property.sha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
            $matched++
        }
    }
    if ($matched -ne 1) { throw "Affected inventory fixture did not bind exactly one file '$relative'." }
    Write-Utf8 $inventoryPath ((ConvertTo-MorphospaceCanonicalJson -Value $inventory) + "`n")
}
function Assert-AffectedThrows([scriptblock]$Action,[string]$Pattern,[string]$Message) {
    $reason = $null
    try { & $Action | Out-Null } catch { $reason = [string]$_.Exception.Message }
    if ([string]::IsNullOrWhiteSpace($reason) -or $reason -notlike $Pattern) { throw "$Message :: observed='$reason'" }
}
function Assert-AffectedExecutorContainmentSource([string]$Source) {
    $forbidden = @('TryReadControl','ControlPath','leaf.stdout.bin','leaf.stderr.bin','ReadAllBytes($stdoutPath)','disableMaxPrivilege','0x000f0fff','CreateRestrictedLeafToken','RUSTY_AFFECTED_VALIDATION_RESTRICTING_SIDS','ProcessStartInfo]::new($unshare.Source)','--map-root-user','ConvertSecurityDescriptorToStringSecurityDescriptor','"w017-affected-child-"','''leaf-temp''','Get-ChildItem Env:','Remove-Item -LiteralPath ("Env:$name")','--preserve-env')
    foreach ($fragment in $forbidden) { Assert-True ($Source.IndexOf($fragment,[StringComparison]::Ordinal) -lt 0) "Affected executor retains forbidden containment fragment '$fragment'." }
    $envPath = '$envPath'
    $required = @('AnonymousPipeServerStream','ApplySupervisorCompletion','W017SupervisorProtection','ProtectAncestors','ProtectThreads','SnapshotAncestorSecurity','RestoreProtectedFutureThreads','RetainFutureThread','retainedThreadIds','restoredThreadHandles','RunRestorationCollisionSelfTests','RUSTY_AFFECTED_VALIDATION_RESTORATION_COLLISION_SELFTEST','RunPublishedControlReadSelfTests','RunOwnedSupervisorDeletionSelfTests','DeleteOwnedSupervisorDirectory','FileAttributes.ReadOnly','ContainmentCleanupSucceeded','SupervisorEvidenceCleanupSucceeded','TryReadExactPublishedControl','IsPublishedControlReadPending','code == 32 || code == 33','FileShare.Read','SecurityDescriptorOwnerMatchesToken','GetSecurityDescriptorOwner','EqualSid','ResolveSupervisorBaseDirectory','GITHUB_ACTIONS','RUNNER_TEMP','FileAttributes.ReparsePoint','"w7-"','''l'';Initialize-LeafWritableRoot','stable residue-free thread set','trusted ancestor fallback process/thread restoration readback differs','trusted ancestor process/thread owner/DACL restoration readback differs','token-default-DACL restoration readback differs','RCWDWO;;;OW','RUSTY_AFFECTED_VALIDATION_GUARD_SID','guard-disabled leaf token did not retain the authority group as deny-only','0x1000','0x2000','OwnerSecurityInformation|DaclSecurityInformation','CreateRestrictedToken','CreatePrivilegeStrippedToken','SetTokenDefaultDacl','OpenThread','Thread32First','RUSTY_AFFECTED_VALIDATION_FUTURE_THREAD_ID','RUSTY_AFFECTED_VALIDATION_PARENT_FUTURE_THREAD_ID','ReadPrivileges','RUSTY_AFFECTED_VALIDATION_REMOVED_PRIVILEGE_LUID','privilege-deleted leaf token retained a non-allowlisted privilege','AssertAncestorIsolation','ImpersonateLoggedOnUser','exact two-process completion authority chain','Initialize-LeafWritableRoot','SetKernelObjectSecurity','W017SupervisorInnerJob','StartupInfoEx','InitializeProcThreadAttributeList','UpdateProcThreadAttribute','DeleteProcThreadAttributeList','0x00020002','ExtendedStartupInfoPresent','closed inner stdin pipe','CreatePipe','TerminateJobObject(state.job,1)','function Resolve-ExactApplication','[Array]::Sort($ordered,[StringComparer]::Ordinal)','ProcessStartInfo]::new($sudoPath)','Environment.Clear()','Get-AffectedValidationChildEnvironmentProjection','parent_environment_unchanged','failure_kind',"Resolve-ExactApplication 'env'","$envPath,'-i'","'--pid','--fork','--kill-child=KILL','--mount-proc'","'--keep-groups'",'geteuid()','getegid()','Complete-Pump','process.Kill(true)','RunForSetupFailureTest')
    foreach ($fragment in $required) { Assert-True ($Source.IndexOf($fragment,[StringComparison]::Ordinal) -ge 0) "Affected executor is missing required containment fragment '$fragment'." }
    Assert-True ([regex]::Matches($Source,'private static bool IsTransientThreadOpenError\(int error\)').Count -eq 2) 'Affected executor does not define the closed transient thread-open classifier in both embedded containment classes.'
    Assert-True ([regex]::Matches($Source,'public static void RunTransientThreadOpenErrorSelfTests\(\)').Count -eq 2) 'Affected executor does not exercise both embedded transient thread-open classifiers.'
    Assert-True ([regex]::Matches($Source,'if\(IsTransientThreadOpenError\(error\)\)continue;').Count -eq 2) 'Affected executor cleanup loops do not both use the closed transient thread-open classifier.'
    Assert-True ([regex]::Matches($Source,'if\(IsTransientThreadOpenError\(error\)\)\{entry\.').Count -eq 2) 'Affected executor initial thread snapshots do not both use the closed transient thread-open classifier.'
    Assert-True ([regex]::Matches($Source,'if\(count==0\)throw new InvalidOperationException').Count -eq 2) 'Affected executor lost the nonempty retained/protected thread requirement.'
}
function Invoke-AffectedBatchSelfTest {
    $fixture = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-batch-' + [guid]::NewGuid().ToString('N'))))
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fixture.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Focused affected batch fixture is outside the exact temporary root.' }
    foreach ($directory in @('scripts','manifests','schemas')) { [void][IO.Directory]::CreateDirectory((Join-Path $fixture $directory)) }
    try {
        [void](Invoke-TestGit $fixture @('init','--initial-branch=main'))
        [void](Invoke-TestGit $fixture @('config','user.name','Affected Batch Test'))
        [void](Invoke-TestGit $fixture @('config','user.email','affected-batch@example.invalid'))
        Write-Utf8 (Join-Path $fixture '.gitattributes') "* text eol=lf`n"
        Write-Utf8 (Join-Path $fixture 'scripts/A.ps1') "'alpha'`n"
        Write-Utf8 (Join-Path $fixture 'scripts/B.ps1') "'beta'`n"
        Write-Utf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') "{}`n"
        Write-Utf8 (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json') "{}`n"
        [void](Invoke-TestGit $fixture @('add','.'))
        [void](Invoke-TestGit $fixture @('commit','-m','batch fixture'))
        $affectedModule = Get-Module MorphospaceAffectedValidation
        $head = & $affectedModule { param($Root) Get-MorphospaceAffectedGitIdentity -RepositoryRoot $Root -Revision HEAD } $fixture
        $inventory = & $affectedModule { param($Root,$Commit) Get-MorphospaceAffectedTreeInventory -RepositoryRoot $Root -Commit $Commit } $fixture $head.commit
        $batch = & $affectedModule { param($Root,$Head,$Inventory) Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $Root -ExpectedHead $Head -Inventory $Inventory -Paths @('scripts/B.ps1','scripts/A.ps1') } $fixture $head $inventory
        Assert-True ($batch.path_count -eq 2 -and (@($batch.paths) -join ',') -ceq 'scripts/A.ps1,scripts/B.ps1') 'Batched working-byte proof did not retain exact ordinal path order/count.'
        Assert-True (@($batch.records | Where-Object { $_.tree_blob -cne $_.working_blob }).Count -eq 0) 'Batched working-byte proof did not bind every returned hash to its exact tree blob.'

        $entryA = $inventory.by_path['scripts/A.ps1']
        $entryB = $inventory.by_path['scripts/B.ps1']
        $validHashOutput = "$($entryA.blob)`n$($entryB.blob)`n"
        $parsedHashes = @(& $affectedModule { param($Text,$Paths,$Inventory) ConvertFrom-MorphospaceAffectedBatchHashOutput -Stdout $Text -Paths $Paths -Inventory $Inventory } $validHashOutput @('scripts/A.ps1','scripts/B.ps1') $inventory)
        Assert-True ($parsedHashes.Count -eq 2 -and $parsedHashes[0].path -ceq 'scripts/A.ps1' -and $parsedHashes[1].path -ceq 'scripts/B.ps1') 'Positive batch hash parser changed record order/path identity.'
        Assert-AffectedThrows { & $affectedModule { param($Text,$Paths,$Inventory) ConvertFrom-MorphospaceAffectedBatchHashOutput -Stdout $Text -Paths $Paths -Inventory $Inventory } "$($entryA.blob)`n" @('scripts/A.ps1','scripts/B.ps1') $inventory } '*missing or extra record*' 'Batch hash parser accepted a missing record.'
        Assert-AffectedThrows { & $affectedModule { param($Text,$Paths,$Inventory) ConvertFrom-MorphospaceAffectedBatchHashOutput -Stdout $Text -Paths $Paths -Inventory $Inventory } "$validHashOutput$($entryA.blob)`n" @('scripts/A.ps1','scripts/B.ps1') $inventory } '*missing or extra record*' 'Batch hash parser accepted an extra record.'
        Assert-AffectedThrows { & $affectedModule { param($Text,$Paths,$Inventory) ConvertFrom-MorphospaceAffectedBatchHashOutput -Stdout $Text -Paths $Paths -Inventory $Inventory } "not-a-hash`n$($entryB.blob)`n" @('scripts/A.ps1','scripts/B.ps1') $inventory } '*malformed hash*' 'Batch hash parser accepted malformed output.'
        Assert-AffectedThrows { & $affectedModule { param($Text,$Paths,$Inventory) ConvertFrom-MorphospaceAffectedBatchHashOutput -Stdout $Text -Paths $Paths -Inventory $Inventory } "$($entryB.blob)`n$($entryA.blob)`n" @('scripts/A.ps1','scripts/B.ps1') $inventory } '*do not match*' 'Batch hash parser accepted reordered path/blob identities.'
        Assert-AffectedThrows { & $affectedModule { ConvertTo-MorphospaceAffectedBatchPathSet -Paths @('scripts/A.ps1','scripts/A.ps1') } } '*repeats exact path*' 'Batch path set accepted an exact duplicate.'
        Assert-AffectedThrows { & $affectedModule { ConvertTo-MorphospaceAffectedBatchPathSet -Paths @('scripts/A.ps1','scripts/a.ps1') } } '*case-colliding*' 'Batch path set accepted a case-colliding path.'
        Assert-AffectedThrows { & $affectedModule { param($Root,$Head,$Inventory) Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $Root -ExpectedHead $Head -Inventory $Inventory -Paths @('scripts/missing.ps1') } $fixture $head $inventory } '*not a tracked regular file in the exact head*' 'Batch verifier accepted a missing command path.'

        $treeOutput = "100644 blob $($entryA.blob)`tscripts/A.ps1`0100644 blob $($entryB.blob)`tscripts/B.ps1`0"
        $parsedTree = & $affectedModule { param($Text,$Commit) ConvertFrom-MorphospaceAffectedTreeInventoryOutput -Stdout $Text -Commit $Commit } $treeOutput $head.commit
        Assert-True ($parsedTree.count -eq 2 -and -not $parsedTree.case_collision) 'Positive exact-head tree inventory parser changed record count/order.'
        Assert-AffectedThrows { & $affectedModule { param($Text,$Commit) ConvertFrom-MorphospaceAffectedTreeInventoryOutput -Stdout $Text -Commit $Commit } ($treeOutput.TrimEnd([char]0)) $head.commit } '*terminal NUL*' 'Tree inventory parser accepted a missing terminal boundary.'
        Assert-AffectedThrows { & $affectedModule { param($Text,$Commit) ConvertFrom-MorphospaceAffectedTreeInventoryOutput -Stdout $Text -Commit $Commit } ("$treeOutput`0") $head.commit } '*malformed or empty*' 'Tree inventory parser accepted an extra empty record.'
        Assert-AffectedThrows { & $affectedModule { param($Text,$Commit) ConvertFrom-MorphospaceAffectedTreeInventoryOutput -Stdout $Text -Commit $Commit } "bogus`0" $head.commit } '*malformed or empty*' 'Tree inventory parser accepted malformed output.'
        Assert-AffectedThrows { & $affectedModule { param($Text,$Commit,$Blob) ConvertFrom-MorphospaceAffectedTreeInventoryOutput -Stdout $Text -Commit $Commit } "100644 blob $($entryA.blob)`tscripts/A.ps1`0100644 blob $($entryA.blob)`tscripts/A.ps1`0" $head.commit $entryA.blob } '*strict ordinal path order*' 'Tree inventory parser accepted duplicate path/order damage.'
        $caseTree = & $affectedModule { param($Text,$Commit) ConvertFrom-MorphospaceAffectedTreeInventoryOutput -Stdout $Text -Commit $Commit } "100644 blob $($entryA.blob)`tscripts/A.ps1`0100644 blob $($entryB.blob)`tscripts/a.ps1`0" $head.commit
        Assert-True $caseTree.case_collision 'Tree inventory parser did not retain case-collision fail-closed evidence.'

        $before = & $affectedModule { param($Root) Get-MorphospaceAffectedWorktreeObservation -RepositoryRoot $Root } $fixture
        $rootDrift = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8; $rootDrift.repository_root = $before.repository_root + '-alias'
        Assert-AffectedThrows { & $affectedModule { param($Before,$After,$Head) Assert-MorphospaceAffectedStableObservation -Before $Before -After $After -ExpectedHead $Head } $before $rootDrift $head } '*root drifted*' 'Stable observation accepted repository-root drift.'
        $headDrift = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8; $headDrift.head_tree = ('0' * 40)
        Assert-AffectedThrows { & $affectedModule { param($Before,$After,$Head) Assert-MorphospaceAffectedStableObservation -Before $Before -After $After -ExpectedHead $Head } $before $headDrift $head } '*HEAD commit/tree drifted*' 'Stable observation accepted HEAD drift.'
        $dirtyDrift = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8; $dirtyDrift.clean = $false; $dirtyDrift.tracked_status = ' M scripts/A.ps1'
        Assert-AffectedThrows { & $affectedModule { param($Before,$After,$Head) Assert-MorphospaceAffectedStableObservation -Before $Before -After $After -ExpectedHead $Head } $before $dirtyDrift $head } '*tracked worktree dirt*' 'Stable observation accepted tracked dirt.'
        Assert-AffectedThrows { & $affectedModule { param($Root) Get-MorphospaceAffectedTreeInventory -RepositoryRoot $Root -Commit ('f' * 40) } $fixture } '*git failed*' 'Tree inventory accepted a missing Git object.'

        [IO.File]::WriteAllText((Join-Path $fixture 'scripts/A.ps1'),"'alpha'`r`n",[Text.UTF8Encoding]::new($false))
        Assert-True (-not [string]::IsNullOrEmpty((Invoke-TestGit $fixture @('status','--porcelain=v1','--untracked-files=no')))) 'Canonical-LF worktree damage was not visible to the tracked-dirty observation.'
        $filteredHash = & $affectedModule { param($Root) Invoke-MorphospaceAffectedGit -RepositoryRoot $Root -Arguments @('hash-object','--stdin-paths') -StandardInputText "scripts/A.ps1`n" } $fixture
        $filteredRecords = @(& $affectedModule { param($Text,$Inventory) ConvertFrom-MorphospaceAffectedBatchHashOutput -Stdout $Text -Paths @('scripts/A.ps1') -Inventory $Inventory } $filteredHash.stdout $inventory)
        Assert-True ($filteredRecords.Count -eq 1 -and $filteredRecords[0].working_blob -ceq $entryA.blob) 'Batched Git working-byte command did not apply the path-specific canonical-LF filter.'
        Assert-AffectedThrows { & $affectedModule { param($Root,$Head,$Inventory) Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $Root -ExpectedHead $Head -Inventory $Inventory -Paths @('scripts/A.ps1') } $fixture $head $inventory } '*tracked worktree dirt*' 'Batched working-byte proof accepted filter-normalizable tracked dirt.'
        Write-Utf8 (Join-Path $fixture 'scripts/A.ps1') "'alpha'`n"
        Write-Utf8 (Join-Path $fixture 'scripts/B.ps1') "dirty`n"
        Assert-AffectedThrows { & $affectedModule { param($Root,$Head,$Inventory) Assert-MorphospaceAffectedBatchedWorkingBytes -RepositoryRoot $Root -ExpectedHead $Head -Inventory $Inventory -Paths @('scripts/B.ps1') } $fixture $head $inventory } '*do not match*' 'Batched working-byte proof accepted dirty content drift.'
        Write-Utf8 (Join-Path $fixture 'scripts/B.ps1') "'beta'`n"

        $scenarioRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-scenario-damage-' + [guid]::NewGuid().ToString('N'))))
        $duplicateRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-scenario-duplicate-' + [guid]::NewGuid().ToString('N'))))
        $damagedRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-scenario-damaged-' + [guid]::NewGuid().ToString('N'))))
        try {
            $fakePlan = [pscustomobject][ordered]@{plan_sha256=('1' * 64);selection_mode='affected';reason_codes=@('focused');changed_paths_sha256=('2' * 64);selected_checks=@([pscustomobject][ordered]@{check_id='focused-check'})}
            $emptyPlan = [pscustomobject][ordered]@{plan_sha256=('3' * 64);selection_mode='affected';reason_codes=@('no-changed-paths');changed_paths_sha256=('4' * 64);selected_checks=@()}
            $emptySummary = Get-AffectedSelectionScenarioPlanSummary -Plan $emptyPlan
            Assert-True (@($emptySummary.selected_check_ids).Count -eq 0) 'Selection-scenario summary did not preserve an empty selected-check set.'
            $firstContext = New-AffectedSelectionScenarioContext -RequestedRoot $scenarioRoot
            $first = Invoke-AffectedSelectionScenario -Context $firstContext -Scenario automation -Fixture $fixture -BaseCommit $head.commit -HeadCommit $head.commit -Action { return $fakePlan }
            Assert-True ($first.result -ceq 'pass' -and @($firstContext.results).Count -eq 1) 'Selection-scenario positive terminal was not emitted exactly once.'
            $terminalPath = @(Get-ChildItem -LiteralPath $firstContext.run_root -File -Filter 'automation-*.terminal.json')
            Assert-True ($terminalPath.Count -eq 1) 'Selection-scenario positive terminal identity is not singular.'

            $reuseObservation = [pscustomobject]@{ invoked=$false }
            $reuseContext = New-AffectedSelectionScenarioContext -RequestedRoot $scenarioRoot
            $reuse = Invoke-AffectedSelectionScenario -Context $reuseContext -Scenario automation -Fixture $fixture -BaseCommit $head.commit -HeadCommit $head.commit -Action { $reuseObservation.invoked = $true; throw 'Reusable scenario action must not execute.' }
            Assert-True ($reuse.result -ceq 'reused-pass' -and -not $reuseObservation.invoked -and @(Get-ChildItem -LiteralPath $reuseContext.run_root -File -Filter '*.reuse.json').Count -eq 1) 'Selection-scenario exact binding did not reuse one prior passing terminal.'

            $collisionPath = Join-Path $firstContext.run_root 'create-new-collision.json'
            Write-AffectedScenarioJsonCreateNew -Path $collisionPath -Value ([pscustomobject][ordered]@{value='original'})
            $collisionBytes = [IO.File]::ReadAllBytes($collisionPath)
            Assert-AffectedThrows { Write-AffectedScenarioJsonCreateNew -Path $collisionPath -Value ([pscustomobject][ordered]@{value='replacement'}) } '*already exists*' 'Selection-scenario receipt writer overwrote an existing path.'
            Assert-True ([Linq.Enumerable]::SequenceEqual[byte]($collisionBytes,[IO.File]::ReadAllBytes($collisionPath))) 'Selection-scenario collision rejection altered existing bytes.'

            Write-Utf8 (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json') "{`"drift`":true}`n"
            $driftObservation = [pscustomobject]@{ invoked=$false }
            $driftContext = New-AffectedSelectionScenarioContext -RequestedRoot $scenarioRoot
            $drift = Invoke-AffectedSelectionScenario -Context $driftContext -Scenario automation -Fixture $fixture -BaseCommit $head.commit -HeadCommit $head.commit -Action { $driftObservation.invoked = $true; return $fakePlan }
            Assert-True ($drift.result -ceq 'pass' -and $driftObservation.invoked -and $drift.binding_sha256 -cne $first.binding_sha256) 'Selection-scenario fixture identity drift reused an earlier terminal.'
            Write-Utf8 (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json') "{}`n"

            foreach ($copyIndex in 1..2) {
                $copyRoot = Join-Path $duplicateRoot "run-$copyIndex"
                [void][IO.Directory]::CreateDirectory($copyRoot)
                Copy-Item -LiteralPath $terminalPath[0].FullName -Destination (Join-Path $copyRoot $terminalPath[0].Name)
            }
            $duplicateContext = New-AffectedSelectionScenarioContext -RequestedRoot $duplicateRoot
            $binding = Get-AffectedSelectionScenarioBinding -Scenario automation -Fixture $fixture -BaseCommit $head.commit -HeadCommit $head.commit
            $bindingSha = Get-MorphospaceCanonicalJsonSha256 -Value $binding
            Assert-AffectedThrows { Read-AffectedReusableSelectionScenarioTerminal -Context $duplicateContext -Scenario automation -Binding $binding -BindingSha256 $bindingSha } '*duplicate exact terminals*' 'Selection-scenario reuse accepted duplicate terminals.'

            $damagedRun = Join-Path $damagedRoot 'run-damaged'
            [void][IO.Directory]::CreateDirectory($damagedRun)
            $damagedTerminalPath = Join-Path $damagedRun $terminalPath[0].Name
            Copy-Item -LiteralPath $terminalPath[0].FullName -Destination $damagedTerminalPath
            $damagedTerminal = Read-MorphospaceProtocolJson -Path $damagedTerminalPath
            $damagedTerminal.binding_sha256 = ('0' * 64)
            Write-Utf8 $damagedTerminalPath ((ConvertTo-MorphospaceCanonicalJson -Value $damagedTerminal) + "`n")
            $damagedContext = New-AffectedSelectionScenarioContext -RequestedRoot $damagedRoot
            Assert-AffectedThrows { Read-AffectedReusableSelectionScenarioTerminal -Context $damagedContext -Scenario automation -Binding $binding -BindingSha256 $bindingSha } '*damaged or mismatched*' 'Selection-scenario reuse accepted a damaged binding.'
        } finally {
            foreach ($root in @($scenarioRoot,$duplicateRoot,$damagedRoot)) { if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force } }
        }
        Write-Host 'Affected-validation exact-head inventory and batched working-byte damage self-test passed.'
    } finally {
        if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
}
function Write-AffectedScenarioJsonCreateNew([string]$Path,[object]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $Value) + "`n")
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Assert-AffectedScenarioProperties([object]$Value,[string[]]$Expected,[string]$Context) {
    [string[]]$actual = @($Value.PSObject.Properties.Name)
    [string[]]$expectedOrdered = @($Expected)
    [Array]::Sort($actual,[StringComparer]::Ordinal)
    [Array]::Sort($expectedOrdered,[StringComparer]::Ordinal)
    if (($actual -join "`0") -cne ($expectedOrdered -join "`0")) { throw "$Context property set is not exact." }
}
function New-AffectedSelectionScenarioContext([string]$RequestedRoot) {
    $ephemeral = [string]::IsNullOrWhiteSpace($RequestedRoot)
    if ($ephemeral) { $root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-scenario-evidence-' + [guid]::NewGuid().ToString('N')))) }
    else {
        if (-not [IO.Path]::IsPathFullyQualified($RequestedRoot)) { throw 'Selection-scenario evidence root must be an absolute external path.' }
        $root = [IO.Path]::GetFullPath($RequestedRoot)
    }
    if (-not [IO.Directory]::Exists($root)) { [void][IO.Directory]::CreateDirectory($root) }
    $runId = 'run-' + [guid]::NewGuid().ToString('N')
    $runRoot = Join-Path $root $runId
    if ([IO.Directory]::Exists($runRoot)) { throw 'Selection-scenario create-new run root collided.' }
    [void][IO.Directory]::CreateDirectory($runRoot)
    return [pscustomobject][ordered]@{ root=$root; run_id=$runId; run_root=$runRoot; ephemeral=$ephemeral; results=[Collections.Generic.List[object]]::new() }
}
function Get-AffectedSelectionScenarioBinding([string]$Scenario,[string]$Fixture,[string]$BaseCommit,[string]$HeadCommit) {
    if ($Scenario -cnotmatch '^(?:automation|unmapped-script|owner-commands|unknown|rename|repeat|no-change|delete)$') { throw "Selection-scenario identity is unsupported: $Scenario" }
    [void](Invoke-TestGit $Fixture @('merge-base','--is-ancestor',$BaseCommit,$HeadCommit))
    $baseTree = Invoke-TestGit $Fixture @('rev-parse',"$BaseCommit^{tree}")
    $headTree = Invoke-TestGit $Fixture @('rev-parse',"$HeadCommit^{tree}")
    return [pscustomobject][ordered]@{
        schema='rusty.morphospace.diagnostic.affected_selection_scenario_input.v1'
        authority='non-authoritative-local-validation'
        scenario=$Scenario
        selector_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        resolver_sha256=(Get-FileHash -LiteralPath (Join-Path $repoRoot 'scripts/lib/MorphospaceAffectedValidation.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        fixture_registry_sha256=(Get-FileHash -LiteralPath (Join-Path $Fixture 'manifests/affected-validation-registry.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        fixture_schema_sha256=(Get-FileHash -LiteralPath (Join-Path $Fixture 'schemas/affected-validation-registry-v1.schema.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        base_tree=$baseTree; head_tree=$headTree
        git_version=(Invoke-TestGit $Fixture @('--version'))
        powershell_version=$PSVersionTable.PSVersion.ToString()
    }
}
function Get-AffectedSelectionScenarioPlanSummary([object]$Plan) {
    [string[]]$reasonCodes = @($Plan.reason_codes | ForEach-Object { [string]$_ }); [Array]::Sort($reasonCodes,[StringComparer]::Ordinal)
    [string[]]$checkIds = @($Plan.selected_checks | ForEach-Object { [string]$_.check_id }); [Array]::Sort($checkIds,[StringComparer]::Ordinal)
    return [pscustomobject][ordered]@{ plan_sha256=[string]$Plan.plan_sha256;selection_mode=[string]$Plan.selection_mode;reason_codes=@($reasonCodes);changed_paths_sha256=[string]$Plan.changed_paths_sha256;selected_check_ids=@($checkIds) }
}
function Read-AffectedReusableSelectionScenarioTerminal([object]$Context,[string]$Scenario,[object]$Binding,[string]$BindingSha256) {
    $leaf = "$Scenario-$BindingSha256.terminal.json"
    $candidates = @(Get-ChildItem -LiteralPath $Context.root -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue | Where-Object { -not $_.FullName.StartsWith($Context.run_root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) })
    if ($candidates.Count -gt 1) { throw "Selection-scenario evidence contains duplicate exact terminals: $Scenario" }
    if ($candidates.Count -eq 0) { return $null }
    $terminal = Read-MorphospaceProtocolJson -Path $candidates[0].FullName
    Assert-AffectedScenarioProperties $terminal @('schema','authority','scenario','binding_sha256','input','observed_base_commit','observed_head_commit','started_at','ended_at','elapsed_ms','result','plan') "Selection-scenario terminal '$Scenario'"
    Assert-AffectedScenarioProperties $terminal.input @('schema','authority','scenario','selector_sha256','resolver_sha256','fixture_registry_sha256','fixture_schema_sha256','base_tree','head_tree','git_version','powershell_version') "Selection-scenario input '$Scenario'"
    Assert-AffectedScenarioProperties $terminal.plan @('plan_sha256','selection_mode','reason_codes','changed_paths_sha256','selected_check_ids') "Selection-scenario plan '$Scenario'"
    if ([string]$terminal.schema -cne 'rusty.morphospace.diagnostic.affected_selection_scenario_terminal.v1' -or
        [string]$terminal.authority -cne 'non-authoritative-local-validation' -or [string]$terminal.scenario -cne $Scenario -or
        [string]$terminal.binding_sha256 -cne $BindingSha256 -or [string]$terminal.result -cne 'pass' -or
        (Get-MorphospaceCanonicalJsonSha256 -Value $terminal.input) -cne $BindingSha256 -or
        (ConvertTo-MorphospaceCanonicalJson -Value $terminal.input) -cne (ConvertTo-MorphospaceCanonicalJson -Value $Binding)) {
        throw "Selection-scenario reusable terminal is damaged or mismatched: $Scenario"
    }
    return [pscustomobject][ordered]@{ path=$candidates[0].FullName; sha256=(Get-FileHash -LiteralPath $candidates[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant(); terminal=$terminal }
}
function Invoke-AffectedSelectionScenario([object]$Context,[string]$Scenario,[string]$Fixture,[string]$BaseCommit,[string]$HeadCommit,[scriptblock]$Action) {
    $binding = Get-AffectedSelectionScenarioBinding -Scenario $Scenario -Fixture $Fixture -BaseCommit $BaseCommit -HeadCommit $HeadCommit
    $bindingSha256 = Get-MorphospaceCanonicalJsonSha256 -Value $binding
    $reusable = Read-AffectedReusableSelectionScenarioTerminal -Context $Context -Scenario $Scenario -Binding $binding -BindingSha256 $bindingSha256
    if ($null -ne $reusable) {
        $reuse = [pscustomobject][ordered]@{schema='rusty.morphospace.diagnostic.affected_selection_scenario_reuse.v1';authority='non-authoritative-local-validation';scenario=$Scenario;binding_sha256=$bindingSha256;result='reused-pass';source_terminal_sha256=$reusable.sha256;source_terminal_path=[IO.Path]::GetRelativePath($Context.root,$reusable.path).Replace('\','/')}
        Write-AffectedScenarioJsonCreateNew (Join-Path $Context.run_root "$Scenario-$BindingSha256.reuse.json") $reuse
        $result = [pscustomobject][ordered]@{scenario=$Scenario;result='reused-pass';elapsed_ms=0;binding_sha256=$bindingSha256;value=$null}
        $Context.results.Add($result) | Out-Null
        Write-Host "Affected selection scenario reused: $Scenario binding=$BindingSha256."
        return $result
    }
    $startedAt = [DateTimeOffset]::UtcNow
    $start = [pscustomobject][ordered]@{schema='rusty.morphospace.diagnostic.affected_selection_scenario_start.v1';authority='non-authoritative-local-validation';scenario=$Scenario;binding_sha256=$bindingSha256;input=$binding;observed_base_commit=$BaseCommit;observed_head_commit=$HeadCommit;started_at=$startedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')}
    Write-AffectedScenarioJsonCreateNew (Join-Path $Context.run_root "$Scenario-$BindingSha256.start.json") $start
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $values = @(& $Action)
        if ($values.Count -ne 1) { throw "Selection scenario '$Scenario' did not return exactly one plan." }
        $plan = $values[0]
        $clock.Stop(); $endedAt=[DateTimeOffset]::UtcNow
        $terminal = [pscustomobject][ordered]@{schema='rusty.morphospace.diagnostic.affected_selection_scenario_terminal.v1';authority='non-authoritative-local-validation';scenario=$Scenario;binding_sha256=$bindingSha256;input=$binding;observed_base_commit=$BaseCommit;observed_head_commit=$HeadCommit;started_at=$startedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');ended_at=$endedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');elapsed_ms=[long]$clock.Elapsed.TotalMilliseconds;result='pass';plan=(Get-AffectedSelectionScenarioPlanSummary $plan)}
        Write-AffectedScenarioJsonCreateNew (Join-Path $Context.run_root "$Scenario-$BindingSha256.terminal.json") $terminal
        $result = [pscustomobject][ordered]@{scenario=$Scenario;result='pass';elapsed_ms=[long]$clock.Elapsed.TotalMilliseconds;binding_sha256=$bindingSha256;value=$plan}
        $Context.results.Add($result) | Out-Null
        Write-Host "Affected selection scenario passed: $Scenario elapsed_ms=$($result.elapsed_ms)."
        return $result
    } catch {
        $clock.Stop(); $endedAt=[DateTimeOffset]::UtcNow
        $failure = [pscustomobject][ordered]@{schema='rusty.morphospace.diagnostic.affected_selection_scenario_failure.v1';authority='non-authoritative-local-validation';scenario=$Scenario;binding_sha256=$bindingSha256;input=$binding;observed_base_commit=$BaseCommit;observed_head_commit=$HeadCommit;started_at=$startedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');ended_at=$endedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');elapsed_ms=[long]$clock.Elapsed.TotalMilliseconds;result='code-fail';error_type=$_.Exception.GetType().FullName;error=$_.Exception.Message}
        Write-AffectedScenarioJsonCreateNew (Join-Path $Context.run_root "$Scenario-$BindingSha256.failure.json") $failure
        throw
    }
}
function ConvertTo-AffectedOrdinalUniqueStrings([object[]]$Values) {
    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in @($Values)) { [void]$unique.Add([string]$value) }
    $result = @($unique)
    [Array]::Sort($result,[StringComparer]::Ordinal)
    return $result
}
function Get-AffectedPowerShellAst([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($Path),[ref]$tokens,[ref]$errors)
    if (@($errors).Count -ne 0) { throw "PowerShell owner source does not parse: $Path :: $(@($errors | ForEach-Object Message) -join '; ')" }
    return $ast
}
function ConvertTo-AffectedOwnerEntrypoint([string]$Value) {
    $normalized = $Value.Replace('\','/')
    $leaf = @($normalized.Split('/') | Where-Object { $_ -ne '' })[-1]
    if ($leaf -cnotmatch '^Test-[A-Za-z0-9-]+\.ps1$') { throw "Work Environment owner entrypoint is not a canonical Test-*.ps1 leaf: $Value" }
    return "scripts/$leaf"
}
function Get-AffectedWorkEnvironmentOwnerEntrypoints([string]$Root, [Collections.Generic.HashSet[string]]$TrackedPaths = $null) {
    $root = [IO.Path]::GetFullPath($Root)
    if ($null -eq $TrackedPaths) {
        $TrackedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($trackedPath in @(& git -C $root ls-files)) { [void]$TrackedPaths.Add(([string]$trackedPath).Replace('\','/')) }
        if ($LASTEXITCODE -ne 0) { throw 'Work Environment owner-entrypoint audit could not enumerate tracked paths.' }
    }
    $ownerPath = Join-Path $root 'scripts/Test-WorkEnvironment.ps1'
    $ast = Get-AffectedPowerShellAst $ownerPath
    $references = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        ([string]$node.Value).Replace('\','/') -match '(?:^|/)Test-[A-Za-z0-9-]+\.ps1$'
    },$true))
    $classifiedOffsets = [Collections.Generic.HashSet[int]]::new()
    $entrypoints = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($hashtable in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] },$true))) {
        foreach ($pair in @($hashtable.KeyValuePairs)) {
            if ([string]$pair.Item1.Extent.Text -cne 'script') { continue }
            $values = @($pair.Item2.FindAll({
                param($node)
                $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                ([string]$node.Value).Replace('\','/') -match '(?:^|/)Test-[A-Za-z0-9-]+\.ps1$'
            },$true))
            if ($values.Count -ne 1) { throw "Work Environment script table entry is not one literal Test-*.ps1 entrypoint: $($pair.Item2.Extent.Text)" }
            [void]$classifiedOffsets.Add([int]$values[0].Extent.StartOffset)
            [void]$entrypoints.Add((ConvertTo-AffectedOwnerEntrypoint ([string]$values[0].Value)))
        }
    }

    foreach ($reference in $references) {
        $node = $reference.Parent
        $direct = $false
        while ($null -ne $node) {
            if ($node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand) { $direct = $true; break }
            $node = $node.Parent
        }
        if ($direct) {
            [void]$classifiedOffsets.Add([int]$reference.Extent.StartOffset)
            [void]$entrypoints.Add((ConvertTo-AffectedOwnerEntrypoint ([string]$reference.Value)))
        }
    }
    foreach ($reference in $references) {
        if (-not $classifiedOffsets.Contains([int]$reference.Extent.StartOffset)) { throw "Work Environment Test-*.ps1 reference uses an unclassified invocation form: $($reference.Extent.Text)" }
    }
    if ($entrypoints.Count -eq 0) { throw 'Work Environment owner-entrypoint audit found no Test-*.ps1 invocations.' }
    $result = @($entrypoints)
    [Array]::Sort($result,[StringComparer]::Ordinal)
    foreach ($relative in $result) {
        if (-not $TrackedPaths.Contains($relative) -or -not [IO.File]::Exists((Join-Path $root $relative))) { throw "Work Environment owner entrypoint is not one tracked regular file: $relative" }
    }
    return $result
}
function Get-AffectedLexicalImportScope([Management.Automation.Language.Ast]$Node) {
    $current = $Node.Parent
    if ($Node -is [Management.Automation.Language.ScriptBlockAst] -and $current -is [Management.Automation.Language.ScriptBlockExpressionAst]) { $current = $current.Parent }
    while ($null -ne $current) {
        if ($current -is [Management.Automation.Language.FunctionDefinitionAst]) { return $current }
        if ($current -is [Management.Automation.Language.ScriptBlockExpressionAst]) { return $current.ScriptBlock }
        $current = $current.Parent
    }
    $current = $Node
    while ($null -ne $current.Parent) { $current = $current.Parent }
    return $current
}
function ConvertTo-AffectedParameterAstArray([object[]]$Candidates) {
    $parameters = [Collections.Generic.List[Management.Automation.Language.ParameterAst]]::new()
    foreach ($candidate in @($Candidates)) {
        if ($candidate -is [Management.Automation.Language.ParameterAst]) { $parameters.Add($candidate) | Out-Null }
    }
    return $parameters.ToArray()
}
function Get-AffectedScopeParameterAsts([object]$Scope) {
    $candidates = [Collections.Generic.List[object]]::new()
    if ($Scope -is [Management.Automation.Language.FunctionDefinitionAst]) {
        foreach ($candidate in @($Scope.Parameters)) { $candidates.Add($candidate) | Out-Null }
        if ($null -ne $Scope.Body.ParamBlock) { foreach ($candidate in @($Scope.Body.ParamBlock.Parameters)) { $candidates.Add($candidate) | Out-Null } }
    } elseif ($Scope -is [Management.Automation.Language.ScriptBlockAst]) {
        if ($null -ne $Scope.ParamBlock) { foreach ($candidate in @($Scope.ParamBlock.Parameters)) { $candidates.Add($candidate) | Out-Null } }
    }
    return @(ConvertTo-AffectedParameterAstArray @($candidates.ToArray()))
}
function Get-AffectedOwnerFileSha256([string]$Path) {
    $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Get-AffectedIndexedLiteralScriptPaths([Management.Automation.Language.Ast]$Node) {
    return @(ConvertTo-AffectedOrdinalUniqueStrings @($Node.FindAll({
        param($candidate)
        $candidate -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$candidate.Value -match '(?i)\.ps(?:m)?1$'
    },$true) | ForEach-Object { [string]$_.Value }))
}
function Get-AffectedIndexedVariables([Management.Automation.Language.Ast]$Node,[bool]$ExcludePSScriptRoot) {
    return @(ConvertTo-AffectedOrdinalUniqueStrings @($Node.FindAll({
        param($candidate)
        $candidate -is [Management.Automation.Language.VariableExpressionAst]
    },$true) | ForEach-Object { [string]$_.VariablePath.UserPath } | Where-Object { -not $ExcludePSScriptRoot -or $_ -cne 'PSScriptRoot' }))
}
function New-AffectedTrackedFileAnalysisIndex([string]$Importer,[string]$AbsolutePath,[string]$SourceSha256) {
    $ast = Get-AffectedPowerShellAst $AbsolutePath
    $assignmentRecords = [Collections.Generic.List[object]]::new()
    $assignmentsByScope = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $parametersByScope = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $memberPairsByName = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $getCommandVariables = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $imports = [Collections.Generic.List[object]]::new()
    $invocations = [Collections.Generic.List[object]]::new()
    $assignmentNodes = [Collections.Generic.List[object]]::new()
    $hashtableNodes = [Collections.Generic.List[object]]::new()
    $demandedVariablesByScope = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $demandedMemberNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $demandedGetCommandVariables = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $observedMemberPairOffsets = [Collections.Generic.HashSet[int]]::new()
    $literalAssignmentScans = 0
    $metadataAssignmentScans = 0
    $memberValueScans = 0
    $analysisNodes = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -or
        $node -is [Management.Automation.Language.CommandAst] -or
        $node -is [Management.Automation.Language.HashtableAst]
    },$true))
    function Add-AffectedDemandedVariable([object]$Scope,[string]$Variable) {
        if ($null -eq $Scope -or [string]::IsNullOrWhiteSpace($Variable)) { return }
        if (-not $demandedVariablesByScope.ContainsKey($Scope)) { $demandedVariablesByScope[$Scope] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
        [void]$demandedVariablesByScope[$Scope].Add($Variable)
    }

    # Pass one collects the exact command candidates and the variable/member
    # bindings that those commands can consume. Assignment and hashtable value
    # subtrees are deliberately not inspected in this pass.
    foreach ($node in $analysisNodes) {
        if ($node -is [Management.Automation.Language.AssignmentStatementAst]) {
            $assignmentNodes.Add($node) | Out-Null
            continue
        }
        if ($node -is [Management.Automation.Language.HashtableAst]) {
            $hashtableNodes.Add($node) | Out-Null
            continue
        }
        if ($node -isnot [Management.Automation.Language.CommandAst]) { continue }
        $scope = Get-AffectedLexicalImportScope $node
        if ($node.GetCommandName() -match '(?i)(?:^|\\)Import-Module$') {
            $importPathValues = @(if ($node.Extent.Text -match '(?i)\.ps(?:m)?1') { @(Get-AffectedIndexedLiteralScriptPaths $node) } else { @() })
            $importVariables = @(if ($importPathValues.Count -eq 0) { @(Get-AffectedIndexedVariables $node $true) } else { @() })
            foreach ($variable in $importVariables) { Add-AffectedDemandedVariable -Scope $scope -Variable ([string]$variable) }
            $imports.Add([pscustomobject][ordered]@{
                ast = $node
                scope = $scope
                path_values = $importPathValues
                variables = $importVariables
            }) | Out-Null
        }
        if ($node.InvocationOperator -in @([Management.Automation.Language.TokenKind]::Ampersand,[Management.Automation.Language.TokenKind]::Dot)) {
            $firstElement = @($node.CommandElements)[0]
            $invocationPathValues = @(if ($firstElement.Extent.Text -match '(?i)\.ps(?:m)?1') { @(Get-AffectedIndexedLiteralScriptPaths $firstElement) } else { @() })
            $invocationVariables = @(if ($invocationPathValues.Count -eq 0 -and $firstElement -is [Management.Automation.Language.VariableExpressionAst]) { @([string]$firstElement.VariablePath.UserPath) } else { @() })
            $memberAsts = @(if ($firstElement -is [Management.Automation.Language.MemberExpressionAst] -or $firstElement.Extent.Text.Contains('.') -or $firstElement.Extent.Text.Contains('::')) { @($firstElement.FindAll({
                param($candidate)
                $candidate -is [Management.Automation.Language.MemberExpressionAst] -and
                $candidate.Member -is [Management.Automation.Language.StringConstantExpressionAst]
            },$true)) } else { @() })
            $scriptMemberCount = 0
            foreach ($memberAst in $memberAsts) {
                $memberName = [string]$memberAst.Member.Value
                [void]$demandedMemberNames.Add($memberName)
                if ($memberName -ceq 'script') { $scriptMemberCount++ }
            }
            foreach ($variable in $invocationVariables) {
                $searchedScopes = [Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
                $candidateScope = $scope
                while ($null -ne $candidateScope -and $searchedScopes.Add($candidateScope)) {
                    Add-AffectedDemandedVariable -Scope $candidateScope -Variable ([string]$variable)
                    $nextScope = Get-AffectedLexicalImportScope $candidateScope
                    if ($nextScope -eq $candidateScope) { break }
                    $candidateScope = $nextScope
                }
            }
            if ($firstElement -is [Management.Automation.Language.MemberExpressionAst] -and
                $firstElement.Expression -is [Management.Automation.Language.VariableExpressionAst] -and
                $firstElement.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                [string]$firstElement.Member.Value -ceq 'Source') {
                [void]$demandedGetCommandVariables.Add([string]$firstElement.Expression.VariablePath.UserPath)
            }
            $invocations.Add([pscustomobject][ordered]@{
                ast = $node
                scope = $scope
                first_element = $firstElement
                path_values = $invocationPathValues
                variables = $invocationVariables
                script_member_count = $scriptMemberCount
                has_scriptblock_argument = @($node.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] }).Count -ne 0
            }) | Out-Null
        }
    }

    # Pass two indexes only bindings demanded above. Literal script paths remain
    # conservative for every assignment, but an extent prefilter avoids a
    # subtree walk for unrelated data assignments.
    foreach ($node in @($assignmentNodes)) {
        $rightText = [string]$node.Right.Extent.Text
        $pathValues = @()
        if ($rightText -match '(?i)\.ps(?:m)?1') {
            $literalAssignmentScans++
            $pathValues = @(Get-AffectedIndexedLiteralScriptPaths $node.Right)
        }
        $scope = $null
        $variable = $null
        $variableDemanded = $false
        $getCommandDemanded = $false
        if ($node.Left -is [Management.Automation.Language.VariableExpressionAst]) {
            $variable = [string]$node.Left.VariablePath.UserPath
            $scope = Get-AffectedLexicalImportScope $node
            $variableDemanded = $demandedVariablesByScope.ContainsKey($scope) -and $demandedVariablesByScope[$scope].Contains($variable)
            $getCommandDemanded = $demandedGetCommandVariables.Contains($variable)
        }
        if ($pathValues.Count -eq 0 -and -not $variableDemanded -and -not $getCommandDemanded) { continue }
        if ($null -eq $scope) { $scope = Get-AffectedLexicalImportScope $node }
        $hasNonPathBinding = $false
        if ($variableDemanded) {
            $metadataAssignmentScans++
            $hasNonPathBinding = $rightText -match '(?i)\b(?:Get-Module|Import-Module|Get-Command|Get-Process)\b'
            if (-not $hasNonPathBinding -and $rightText.Contains('{')) {
                $hasNonPathBinding = @($node.Right.FindAll({ param($candidate) $candidate -is [Management.Automation.Language.ScriptBlockExpressionAst] },$true)).Count -ne 0
            }
        }
        $record = [pscustomobject][ordered]@{ ast=$node; scope=$scope; path_values=$pathValues; has_non_path_binding=$hasNonPathBinding }
        $assignmentRecords.Add($record) | Out-Null
        if ($variableDemanded) {
            if (-not $assignmentsByScope.ContainsKey($scope)) { $assignmentsByScope[$scope] = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal) }
            $byVariable = $assignmentsByScope[$scope]
            if (-not $byVariable.ContainsKey($variable)) { $byVariable[$variable] = [Collections.Generic.List[object]]::new() }
            $byVariable[$variable].Add($record) | Out-Null
        }
        if ($getCommandDemanded -and $rightText -match '(?i)\bGet-Command\b') { [void]$getCommandVariables.Add($variable) }
    }

    foreach ($hashtable in @($hashtableNodes)) {
        foreach ($pair in @($hashtable.KeyValuePairs)) {
            $memberName = [string]$pair.Item1.Extent.Text
            if (-not $demandedMemberNames.Contains($memberName)) { continue }
            $pairOffset = [int]$pair.Item2.Extent.StartOffset
            if (-not $observedMemberPairOffsets.Add($pairOffset)) { continue }
            $memberValueScans++
            $valueText = [string]$pair.Item2.Extent.Text
            $memberPathValues = @(if ($valueText -match '(?i)\.ps(?:m)?1') { @(Get-AffectedIndexedLiteralScriptPaths $pair.Item2) } else { @() })
            $scriptblockCount = if ($valueText.Contains('{')) { @($pair.Item2.FindAll({ param($candidate) $candidate -is [Management.Automation.Language.ScriptBlockExpressionAst] },$true)).Count } else { 0 }
            if (-not $memberPairsByName.ContainsKey($memberName)) { $memberPairsByName[$memberName] = [Collections.Generic.List[object]]::new() }
            $memberPairsByName[$memberName].Add([pscustomobject][ordered]@{ extent_text=$valueText; path_values=$memberPathValues; scriptblock_count=$scriptblockCount }) | Out-Null
        }
    }

    foreach ($scope in @($demandedVariablesByScope.Keys)) {
        $byName = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($parameter in @(Get-AffectedScopeParameterAsts $scope)) {
            $name = [string]$parameter.Name.VariablePath.UserPath
            if (-not $demandedVariablesByScope[$scope].Contains($name)) { continue }
            if (-not $byName.ContainsKey($name)) { $byName[$name] = [Collections.Generic.List[object]]::new() }
            $byName[$name].Add([pscustomobject][ordered]@{ static_type = $parameter.StaticType; extent_text = [string]$parameter.Extent.Text }) | Out-Null
        }
        $parametersByScope[$scope] = $byName
    }
    return [pscustomobject][ordered]@{
        key = "$Importer|$SourceSha256"
        importer = $Importer
        absolute_path = [IO.Path]::GetFullPath($AbsolutePath)
        source_sha256 = $SourceSha256
        ast = $ast
        assignment_records = $assignmentRecords.ToArray()
        assignments_by_scope = $assignmentsByScope
        parameters_by_scope = $parametersByScope
        member_pairs_by_name = $memberPairsByName
        get_command_variables = $getCommandVariables
        imports = $imports.ToArray()
        invocations = $invocations.ToArray()
        analysis_metrics = [pscustomobject][ordered]@{
            analysis_nodes = $analysisNodes.Count
            demanded_variable_scopes = $demandedVariablesByScope.Count
            demanded_member_names = $demandedMemberNames.Count
            literal_assignment_subtree_scans = $literalAssignmentScans
            metadata_assignment_subtree_scans = $metadataAssignmentScans
            member_value_subtree_scans = $memberValueScans
        }
    }
}
function Get-AffectedIndexedScopeAssignmentRecords([object]$Index,[object]$Scope,[string]$Variable) {
    if (-not $Index.assignments_by_scope.ContainsKey($Scope)) { return @() }
    $byVariable = $Index.assignments_by_scope[$Scope]
    if (-not $byVariable.ContainsKey($Variable)) { return @() }
    return @($byVariable[$Variable])
}
function Test-AffectedIndexedScriptBlockParameter([object]$Index,[object]$Scope,[string]$Variable) {
    if (-not $Index.parameters_by_scope.ContainsKey($Scope)) { return $false }
    $byName = $Index.parameters_by_scope[$Scope]
    if (-not $byName.ContainsKey($Variable)) { return $false }
    return @($byName[$Variable] | Where-Object { $_.static_type -eq [scriptblock] }).Count -eq 1
}
function Assert-AffectedTrackedFileAnalysisIndexStable([object]$Index) {
    $observed = Get-AffectedOwnerFileSha256 $Index.absolute_path
    if ($observed -cne [string]$Index.source_sha256) { throw "Owner import graph source bytes changed during construction: $($Index.importer)" }
}
function New-AffectedTrackedImportGraph([string]$Root, [string[]]$Entrypoints, [object[]]$DynamicImportDeclarations = @(), [Collections.Generic.HashSet[string]]$TrackedPaths = $null) {
    $root = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    if ($null -eq $TrackedPaths) {
        $TrackedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($trackedPath in @(& git -C $root ls-files)) { [void]$TrackedPaths.Add(([string]$trackedPath).Replace('\','/')) }
        if ($LASTEXITCODE -ne 0) { throw 'Owner import closure could not enumerate tracked paths.' }
    }
    $declarations = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($declaration in @($DynamicImportDeclarations)) {
        $properties = @($declaration.PSObject.Properties.Name)
        $singleTarget = ($properties -join ',') -ceq 'importer,variable,count,import_path'
        $multipleTargets = ($properties -join ',') -ceq 'importer,variable,count,import_paths'
        $nonTrackedTarget = ($properties -join ',') -ceq 'importer,variable,count,classification'
        if (-not $singleTarget -and -not $multipleTargets -and -not $nonTrackedTarget) { throw 'Dynamic import declaration does not use one exact importer/variable/count/import_path(s)/classification shape.' }
        $key = "$([string]$declaration.importer)|$([string]$declaration.variable)"
        if ($declarations.ContainsKey($key) -or [int]$declaration.count -lt 1) { throw "Dynamic import declaration is duplicate or has an invalid count: $key" }
        if ($nonTrackedTarget) {
            if ([string]$declaration.classification -cne 'authenticated-external-script') { throw "Dynamic non-tracked invocation declaration has an unsupported classification: $key" }
        } else {
            $declaredTargets = @(if ($singleTarget) { @([string]$declaration.import_path) } else { @(ConvertTo-AffectedOrdinalUniqueStrings @($declaration.import_paths)) })
            if ($declaredTargets.Count -eq 0 -or ($multipleTargets -and $declaredTargets.Count -ne @($declaration.import_paths).Count)) { throw "Dynamic import declaration has an empty or ordinal-duplicate target set: $key" }
        }
        $declarations[$key] = $declaration
    }
    $observedDeclarations = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $nodes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Queue[string]]::new()
    $edges = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $identities = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $analysisByKey = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $analysisKeyByPath = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    function Add-AffectedTrackedImportPath([string]$RelativePath) {
        $normalized = $RelativePath.Replace('\','/')
        if ($normalized -cnotmatch '^scripts/[^:]+\.ps(?:m)?1$' -or $normalized -match '(?:^|/)\.\.?/') { throw "Owner import is not a canonical repository-relative .ps1/.psm1 path: $RelativePath" }
        $absolute = [IO.Path]::GetFullPath((Join-Path $root $normalized))
        if (-not $absolute.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Owner import escapes the repository: $RelativePath" }
        if (-not $TrackedPaths.Contains($normalized) -or -not [IO.File]::Exists($absolute)) { throw "Owner import is absent or untracked: $normalized" }
        if ($nodes.Add($normalized)) { $pending.Enqueue($normalized) }
    }
    foreach ($entrypoint in @($Entrypoints)) { Add-AffectedTrackedImportPath $entrypoint }
    while ($pending.Count -gt 0) {
        $importer = $pending.Dequeue()
        $absolute = Join-Path $root $importer
        $directory = [IO.Path]::GetDirectoryName($absolute)
        $identities[$importer] = Get-AffectedOwnerFileSha256 $absolute
        $analysis = New-AffectedTrackedFileAnalysisIndex -Importer $importer -AbsolutePath $absolute -SourceSha256 $identities[$importer]
        if ($analysisByKey.ContainsKey([string]$analysis.key) -or $analysisKeyByPath.ContainsKey($importer)) { throw "Owner import graph analysis index repeated an exact path/SHA identity: $($analysis.key)" }
        $analysisByKey[[string]$analysis.key] = $analysis
        $analysisKeyByPath[$importer] = [string]$analysis.key
        $importEdges = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        # Nested child launchers frequently bind a tracked script/module path
        # in the outer owner before handing it to generated child source.
        # Conservatively close over every such exact tracked static binding;
        # untracked fixture-local paths remain outside the tracked-byte graph.
        foreach ($assignmentRecord in @($analysis.assignment_records)) {
            foreach ($assignmentValue in @($assignmentRecord.path_values)) {
                $assignmentFull = if ($assignmentValue.Replace('\','/') -match '^scripts/') { [IO.Path]::GetFullPath((Join-Path $root $assignmentValue)) } else { [IO.Path]::GetFullPath((Join-Path $directory $assignmentValue)) }
                if ($assignmentFull.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
                    $assignmentRelative = [IO.Path]::GetRelativePath($root,$assignmentFull).Replace('\','/')
                    if ($TrackedPaths.Contains($assignmentRelative)) { [void]$importEdges.Add($assignmentRelative) }
                }
            }
        }
        foreach ($importRecord in @($analysis.imports)) {
            $import = $importRecord.ast
            $pathValues = @($importRecord.path_values)
            $importValue = $null
            if ($pathValues.Count -eq 1) {
                $importValue = [string]$pathValues[0]
            } elseif ($pathValues.Count -gt 1) {
                throw "Owner import contains multiple literal tracked-script candidates: $importer :: $($import.Extent.Text)"
            } else {
                $variables = @($importRecord.variables)
                if ($variables.Count -ne 1) { throw "Owner Import-Module is neither a literal nor one statically/audit-bound variable edge: $importer :: $($import.Extent.Text)" }
                $variable = [string]$variables[0]
                $scope = $importRecord.scope
                $boundValues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($assignmentRecord in @(Get-AffectedIndexedScopeAssignmentRecords -Index $analysis -Scope $scope -Variable $variable)) {
                    if (@($assignmentRecord.path_values).Count -ne 1) { throw "Static import variable assignment is not one literal script path: $importer|$variable" }
                    [void]$boundValues.Add([string]$assignmentRecord.path_values[0])
                }
                if ($boundValues.Count -eq 1) {
                    $importValue = @($boundValues)[0]
                } elseif ($boundValues.Count -gt 1) {
                    throw "Static import variable has multiple literal path bindings: $importer|$variable"
                } else {
                    $key = "$importer|$variable"
                    if (-not $declarations.ContainsKey($key)) { throw "Dynamic owner import lacks an exact declaration: $key" }
                    $declaration = $declarations[$key]
                    $importValue = [string]$declaration.import_path
                    $observedDeclarations[$key] = 1 + $(if ($observedDeclarations.ContainsKey($key)) { [int]$observedDeclarations[$key] } else { 0 })
                }
            }
            $importFull = if ($importValue.Replace('\','/') -match '^scripts/') { [IO.Path]::GetFullPath((Join-Path $root $importValue)) } else { [IO.Path]::GetFullPath((Join-Path $directory $importValue)) }
            if (-not $importFull.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Owner import escapes the repository: $importer :: $importValue" }
            [void]$importEdges.Add([IO.Path]::GetRelativePath($root,$importFull).Replace('\','/'))
        }
        foreach ($invocationRecord in @($analysis.invocations)) {
            $invocation = $invocationRecord.ast
            $firstElement = $invocationRecord.first_element
            $pathValues = @($invocationRecord.path_values)
            $invocationValues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if ($pathValues.Count -eq 1) {
                [void]$invocationValues.Add([string]$pathValues[0])
            } elseif ($pathValues.Count -gt 1) {
                throw "Owner invocation contains multiple literal tracked-script candidates: $importer :: $($invocation.Extent.Text)"
            } else {
                $staticMemberPathValues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                if ([int]$invocationRecord.script_member_count -ne 0) {
                    $scriptMemberPairs = @(if ($analysis.member_pairs_by_name.ContainsKey('script')) { @($analysis.member_pairs_by_name['script']) } else { @() })
                    foreach ($pairRecord in $scriptMemberPairs) {
                        if (@($pairRecord.path_values).Count -ne 1) { throw "Static invocation member does not bind one literal script path: $importer :: $($pairRecord.extent_text)" }
                        [void]$staticMemberPathValues.Add([string]$pairRecord.path_values[0])
                    }
                    if ($staticMemberPathValues.Count -eq 0) { throw "Static invocation member has no literal tracked-script table bindings: $importer :: $($invocation.Extent.Text)" }
                }
                if ($staticMemberPathValues.Count -ne 0) {
                    foreach ($memberPathValue in @($staticMemberPathValues)) { [void]$invocationValues.Add([string]$memberPathValue) }
                } elseif ($firstElement -isnot [Management.Automation.Language.VariableExpressionAst]) {
                    $nonPathLiteral = $firstElement -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$firstElement.Value -cnotmatch '(?i)\.ps(?:m)?1$'
                    $nonPathScriptBlock = $firstElement -is [Management.Automation.Language.ScriptBlockExpressionAst]
                    $moduleScopeInvocation = [bool]$invocationRecord.has_scriptblock_argument -and $firstElement.Extent.Text -match '(?i)Get-Module'
                    $nonPathCommandMember = $false
                    if ($firstElement -is [Management.Automation.Language.MemberExpressionAst] -and
                        $firstElement.Expression -is [Management.Automation.Language.VariableExpressionAst] -and
                        $firstElement.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                        [string]$firstElement.Member.Value -ceq 'Source') {
                        $commandVariable = [string]$firstElement.Expression.VariablePath.UserPath
                        $nonPathCommandMember = $analysis.get_command_variables.Contains($commandVariable)
                    }
                    $nonPathScriptBlockMember = $false
                    if ($firstElement -is [Management.Automation.Language.MemberExpressionAst] -and $firstElement.Member -is [Management.Automation.Language.StringConstantExpressionAst]) {
                        $memberName = [string]$firstElement.Member.Value
                        $memberDefinitions = @(if ($analysis.member_pairs_by_name.ContainsKey($memberName)) { @($analysis.member_pairs_by_name[$memberName]) } else { @() })
                        if ($memberDefinitions.Count -ne 0) {
                            $nonPathScriptBlockMember = $true
                            foreach ($definition in $memberDefinitions) { if ([int]$definition.scriptblock_count -ne 1) { $nonPathScriptBlockMember = $false } }
                        }
                    }
                    if ($nonPathLiteral -or $nonPathScriptBlock -or $nonPathScriptBlockMember -or $nonPathCommandMember -or $moduleScopeInvocation) { continue }
                    throw "Owner invocation is neither a tracked script path nor an audited non-path callable: $importer :: $($invocation.Extent.Text)"
                } else {
                    $variables = @($invocationRecord.variables)
                    if ($variables.Count -ne 1) { throw "Dynamic owner invocation does not contain one exact callable variable: $importer :: $($invocation.Extent.Text)" }
                    $variable = [string]$variables[0]
                    $scope = $invocationRecord.scope
                    $boundValues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    $nonPathBinding = $false
                    $searchedScopes = [Collections.Generic.HashSet[object]]::new()
                    $candidateScope = $scope
                    while ($null -ne $candidateScope -and $searchedScopes.Add($candidateScope)) {
                        foreach ($assignmentRecord in @(Get-AffectedIndexedScopeAssignmentRecords -Index $analysis -Scope $candidateScope -Variable $variable)) {
                            if (@($assignmentRecord.path_values).Count -eq 1) { [void]$boundValues.Add([string]$assignmentRecord.path_values[0]) }
                            elseif ([bool]$assignmentRecord.has_non_path_binding) { $nonPathBinding = $true }
                        }
                        if ($boundValues.Count -ne 0 -or $nonPathBinding) { break }
                        $nextScope = Get-AffectedLexicalImportScope $candidateScope
                        if ($nextScope -eq $candidateScope) { break }
                        $candidateScope = $nextScope
                    }
                    if ($boundValues.Count -eq 1) {
                        [void]$invocationValues.Add(@($boundValues)[0])
                    } elseif ($boundValues.Count -gt 1) {
                        throw "Static invocation variable has multiple literal script bindings: $importer|$variable"
                    } else {
                        $scriptBlockParameter = Test-AffectedIndexedScriptBlockParameter -Index $analysis -Scope $scope -Variable $variable
                        $moduleScopeInvocation = [bool]$invocationRecord.has_scriptblock_argument
                        if ($nonPathBinding -or $scriptBlockParameter -or $moduleScopeInvocation -or $variable -match '(?i)(?:git|pwsh|powershell|python|executable|command)$') { continue }
                        $key = "$importer|$variable"
                        if (-not $declarations.ContainsKey($key)) { throw "Dynamic owner invocation lacks an exact declaration: $key" }
                        $declaration = $declarations[$key]
                        if ($declaration.PSObject.Properties.Name -ccontains 'import_path') { [void]$invocationValues.Add([string]$declaration.import_path) }
                        elseif ($declaration.PSObject.Properties.Name -ccontains 'import_paths') { foreach ($target in @($declaration.import_paths)) { [void]$invocationValues.Add([string]$target) } }
                        $observedDeclarations[$key] = 1 + $(if ($observedDeclarations.ContainsKey($key)) { [int]$observedDeclarations[$key] } else { 0 })
                    }
                }
            }
            foreach ($invocationValue in @(ConvertTo-AffectedOrdinalUniqueStrings @($invocationValues))) {
                $invocationFull = if ($invocationValue.Replace('\','/') -match '^scripts/') { [IO.Path]::GetFullPath((Join-Path $root $invocationValue)) } else { [IO.Path]::GetFullPath((Join-Path $directory $invocationValue)) }
                if (-not $invocationFull.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Owner invocation escapes the repository: $importer :: $invocationValue" }
                [void]$importEdges.Add([IO.Path]::GetRelativePath($root,$invocationFull).Replace('\','/'))
            }
        }
        $orderedEdges = @($importEdges)
        [Array]::Sort($orderedEdges,[StringComparer]::Ordinal)
        $edges[$importer] = $orderedEdges
        foreach ($edge in $orderedEdges) { Add-AffectedTrackedImportPath $edge }
    }
    foreach ($key in @($declarations.Keys)) {
        $declaration = $declarations[$key]
        if (-not $nodes.Contains([string]$declaration.importer)) { continue }
        $observed = if ($observedDeclarations.ContainsKey($key)) { [int]$observedDeclarations[$key] } else { 0 }
        if ($observed -ne [int]$declaration.count) { throw "Dynamic owner import declaration count changed: $key expected=$($declaration.count) observed=$observed" }
    }
    foreach ($node in @($nodes)) {
        if (-not $analysisKeyByPath.ContainsKey($node) -or -not $analysisByKey.ContainsKey([string]$analysisKeyByPath[$node])) { throw "Owner import graph analysis index is absent for a tracked node: $node" }
        $analysis = $analysisByKey[[string]$analysisKeyByPath[$node]]
        if ([string]$analysis.key -cne "$node|$([string]$identities[$node])") { throw "Owner import graph analysis index identity drifted: $node" }
        Assert-AffectedTrackedFileAnalysisIndexStable $analysis
    }
    $orderedNodes = @($nodes)
    [Array]::Sort($orderedNodes,[StringComparer]::Ordinal)
    return [pscustomobject][ordered]@{ nodes=$orderedNodes; edges=$edges; sha256_by_path=$identities }
}
function Get-AffectedGraphAdjacencyRecords([object]$Graph) {
    $records = [Collections.Generic.List[object]]::new()
    $orderedNodes = @(ConvertTo-AffectedOrdinalUniqueStrings @($Graph.nodes))
    if ($orderedNodes.Count -ne @($Graph.nodes).Count) { throw 'Owner import graph digest input repeats an ordinal node identity.' }
    foreach ($node in $orderedNodes) {
        if (-not $Graph.edges.ContainsKey([string]$node)) { throw "Owner import graph digest input lacks adjacency for: $node" }
        $orderedEdges = @(ConvertTo-AffectedOrdinalUniqueStrings @($Graph.edges[[string]$node]))
        if ($orderedEdges.Count -ne @($Graph.edges[[string]$node]).Count) { throw "Owner import graph digest input repeats an ordinal edge: $node" }
        $records.Add([pscustomobject][ordered]@{ path=[string]$node; imports=$orderedEdges }) | Out-Null
    }
    return @($records.ToArray())
}
function Get-AffectedGraphAdjacencySha256([object]$Graph) {
    return Get-MorphospaceCanonicalJsonSha256 -Value ([pscustomobject][ordered]@{ schema='affected_owner_adjacency.v1'; nodes=@(Get-AffectedGraphAdjacencyRecords $Graph) })
}
function Get-AffectedProtocolConsumerSha256([string[]]$Consumers,[string[]]$CheckIds) {
    $orderedConsumers = @(ConvertTo-AffectedOrdinalUniqueStrings @($Consumers))
    $orderedChecks = @(ConvertTo-AffectedOrdinalUniqueStrings @($CheckIds))
    if ($orderedConsumers.Count -ne @($Consumers).Count -or $orderedChecks.Count -ne @($CheckIds).Count) { throw 'ProtocolCommon consumer digest input repeats an ordinal identity.' }
    return Get-MorphospaceCanonicalJsonSha256 -Value ([pscustomobject][ordered]@{ schema='protocol_common_owner_consumers.v1'; consumers=$orderedConsumers; check_ids=$orderedChecks })
}
function Assert-AffectedProtocolCommonGraphProjection([object]$Value,[string]$Context) {
    $ownerPaths = @(ConvertTo-AffectedOrdinalUniqueStrings @($Value.owner_entrypoint_paths))
    Assert-True ($ownerPaths.Count -eq @($Value.owner_entrypoint_paths).Count -and ($ownerPaths -join "`n") -ceq (@($Value.owner_entrypoint_paths) -join "`n")) "$Context owner entrypoints are not ordinal, unique, and canonical."
    Assert-True ([int]$Value.owner_entrypoints -eq $ownerPaths.Count) "$Context owner-entrypoint count does not match its canonical paths."

    $adjacencyRecords = @($Value.tracked_graph_adjacency)
    $nodePaths = [Collections.Generic.List[string]]::new()
    $edges = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($record in $adjacencyRecords) {
        Assert-AffectedScenarioProperties -Value $record -Expected @('path','imports') -Context "$Context adjacency record"
        $path = [string]$record.path
        if ([string]::IsNullOrWhiteSpace($path) -or $edges.ContainsKey($path)) { throw "$Context adjacency repeats or omits a node path." }
        $imports = @(ConvertTo-AffectedOrdinalUniqueStrings @($record.imports))
        Assert-True ($imports.Count -eq @($record.imports).Count -and ($imports -join "`n") -ceq (@($record.imports) -join "`n")) "$Context adjacency imports are not ordinal, unique, and canonical: $path"
        $nodePaths.Add($path) | Out-Null
        $edges[$path] = $imports
    }
    $orderedNodes = @(ConvertTo-AffectedOrdinalUniqueStrings @($nodePaths.ToArray()))
    Assert-True ($orderedNodes.Count -eq $nodePaths.Count -and ($orderedNodes -join "`n") -ceq ($nodePaths.ToArray() -join "`n")) "$Context adjacency nodes are not ordinal, unique, and canonical."
    Assert-True ([int]$Value.tracked_graph_nodes -eq $orderedNodes.Count) "$Context tracked-node count does not match its canonical adjacency."
    foreach ($path in $orderedNodes) {
        foreach ($import in @($edges[$path])) { if ($orderedNodes -cnotcontains [string]$import) { throw "$Context adjacency imports an absent node: $path -> $import" } }
    }
    foreach ($owner in $ownerPaths) { if ($orderedNodes -cnotcontains $owner) { throw "$Context owner entrypoint is absent from its adjacency: $owner" } }
    $projectionGraph = [pscustomobject][ordered]@{ nodes=$orderedNodes; edges=$edges }
    Assert-True ((Get-AffectedGraphAdjacencySha256 $projectionGraph) -ceq [string]$Value.adjacency_sha256) "$Context canonical adjacency digest does not match its records."

    $consumerPaths = @(ConvertTo-AffectedOrdinalUniqueStrings @($Value.protocol_consumer_paths))
    $checkIds = @(ConvertTo-AffectedOrdinalUniqueStrings @($Value.check_ids))
    Assert-True ($consumerPaths.Count -eq @($Value.protocol_consumer_paths).Count -and ($consumerPaths -join "`n") -ceq (@($Value.protocol_consumer_paths) -join "`n")) "$Context consumer paths are not ordinal, unique, and canonical."
    Assert-True ($checkIds.Count -eq @($Value.check_ids).Count -and ($checkIds -join "`n") -ceq (@($Value.check_ids) -join "`n")) "$Context check IDs are not ordinal, unique, and canonical."
    Assert-True ([int]$Value.protocol_consumers -eq $consumerPaths.Count) "$Context consumer count does not match its canonical paths."
    foreach ($consumer in $consumerPaths) { if ($orderedNodes -cnotcontains $consumer) { throw "$Context ProtocolCommon consumer is absent from its tracked adjacency: $consumer" } }
    Assert-True ((Get-AffectedProtocolConsumerSha256 -Consumers $consumerPaths -CheckIds $checkIds) -ceq [string]$Value.consumer_sha256) "$Context canonical consumer digest does not match its paths/checks."
}
function Get-AffectedGraphReachability([object]$Graph, [string]$Entrypoint, [Collections.Generic.Dictionary[string,object]]$Cache) {
    if ($Cache.ContainsKey($Entrypoint)) { return @($Cache[$Entrypoint]) }
    if (@($Graph.nodes) -cnotcontains $Entrypoint) { throw "Owner entrypoint is absent from the tracked import graph: $Entrypoint" }
    $reachable = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($Entrypoint)
    while ($pending.Count -gt 0) {
        $node = $pending.Dequeue()
        if (-not $reachable.Add($node)) { continue }
        if ($node -cne $Entrypoint -and $Cache.ContainsKey($node)) {
            foreach ($cachedNode in @($Cache[$node])) { [void]$reachable.Add([string]$cachedNode) }
            continue
        }
        foreach ($edge in @($Graph.edges[$node])) { if (-not $reachable.Contains([string]$edge)) { $pending.Enqueue([string]$edge) } }
    }
    $result = @($reachable)
    [Array]::Sort($result,[StringComparer]::Ordinal)
    $Cache[$Entrypoint] = $result
    return $result
}
function Get-AffectedProtocolCommonOwnerChecks([string]$Root, [object]$Registry) {
    $auditClock = [Diagnostics.Stopwatch]::StartNew()
    $trackedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($trackedPath in @(& git -C $Root ls-files)) { [void]$trackedPaths.Add(([string]$trackedPath).Replace('\','/')) }
    if ($LASTEXITCODE -ne 0) { throw 'ProtocolCommon owner audit could not enumerate tracked paths.' }
    $registryByCommand = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($check in @($Registry.checks)) {
        $commandPath = [string]$check.command_path
        if (-not $registryByCommand.ContainsKey($commandPath)) { $registryByCommand[$commandPath] = [Collections.Generic.List[object]]::new() }
        ([Collections.Generic.List[object]]$registryByCommand[$commandPath]).Add($check)
    }
    $ownerEntrypoints = @(Get-AffectedWorkEnvironmentOwnerEntrypoints -Root $Root -TrackedPaths $trackedPaths)
    $dynamicImports = @(
        [pscustomobject][ordered]@{ importer='scripts/Test-TransitionLedger.ps1'; variable='ModulePath'; count=2; import_path='scripts/lib/MorphospaceTransitionLedger.psm1' },
        [pscustomobject][ordered]@{ importer='scripts/Test-WorkflowContracts.ps1'; variable='focusedRecoveryPath'; count=1; import_paths=@('scripts/Test-HistoricalUnitAdoptionReconstruction.ps1','scripts/Test-PlanningWorkspaceProjection.ps1','scripts/Test-PublishedPlanningAuthorityAdoption.ps1') },
        [pscustomobject][ordered]@{ importer='scripts/Test-WorkEnvironment.ps1'; variable='quickTestPath'; count=3; import_paths=$ownerEntrypoints },
        [pscustomobject][ordered]@{ importer='scripts/Invoke-ExternalValidationAuthorityForGitHub.ps1'; variable='verifierFullPath'; count=1; classification='authenticated-external-script' }
    )
    $consumerCheckIds = [Collections.Generic.List[string]]::new()
    $consumers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $missingChecks = [Collections.Generic.List[string]]::new()
    # This owner self-test is not currently dispatched by Test-WorkEnvironment,
    # but its independently reviewed receipt is invalidated by the same
    # InheritedCandidateMaterialization -> ProtocolCommon tracked-byte edge.
    # Keep that review-bound supplementary entrypoint explicit and narrow.
    $supplementaryEntrypoints = @('scripts/Test-InheritedCandidateMaterialization.ps1')
    foreach ($supplementary in $supplementaryEntrypoints) {
        if (-not $trackedPaths.Contains($supplementary)) { throw "Supplementary ProtocolCommon owner entrypoint is absent or untracked: $supplementary" }
    }
    $graphEntrypoints = @(ConvertTo-AffectedOrdinalUniqueStrings @($ownerEntrypoints + $supplementaryEntrypoints))
    $graphClock = [Diagnostics.Stopwatch]::StartNew()
    $graph = New-AffectedTrackedImportGraph -Root $Root -Entrypoints $graphEntrypoints -DynamicImportDeclarations $dynamicImports -TrackedPaths $trackedPaths
    $graphClock.Stop()
    foreach ($requiredInvocationEdge in @(
        @('scripts/Test-HistoryArchiveValidation.ps1','scripts/Test-HistoryArchiveCheckpoint.ps1'),
        @('scripts/Test-BlockedSupersessionTerminalValidation.ps1','scripts/Test-WorkflowContracts.ps1'),
        @('scripts/Test-CorrectActiveUnitContract.ps1','scripts/Test-WorkflowContracts.ps1')
    )) {
        $source = [string]$requiredInvocationEdge[0]
        $target = [string]$requiredInvocationEdge[1]
        if (-not $graph.edges.ContainsKey($source) -or @($graph.edges[$source]) -cnotcontains $target) { throw "Tracked owner invocation edge is absent from the import graph: $source -> $target" }
    }
    $reachabilityCache = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $orderedCandidateEntrypoints = @($graphEntrypoints)
    [Array]::Sort($orderedCandidateEntrypoints,[StringComparer]::Ordinal)
    foreach ($entrypoint in $orderedCandidateEntrypoints) {
        $closure = @(Get-AffectedGraphReachability -Graph $graph -Entrypoint $entrypoint -Cache $reachabilityCache)
        if ($closure -cnotcontains 'scripts/lib/MorphospaceProtocolCommon.psm1') { continue }
        [void]$consumers.Add([string]$entrypoint)
        if (-not $registryByCommand.ContainsKey([string]$entrypoint)) { $missingChecks.Add([string]$entrypoint) | Out-Null; continue }
        foreach ($check in @($registryByCommand[[string]$entrypoint])) {
            if (@($check.trigger_path_sets) -cnotcontains 'protocol-common') { throw "ProtocolCommon transitive Work Environment owner lacks its protocol-common trigger: $entrypoint -> $($check.check_id)" }
            $consumerCheckIds.Add([string]$check.check_id) | Out-Null
        }
    }
    if ($missingChecks.Count -ne 0) {
        $missing = @($missingChecks)
        [Array]::Sort($missing,[StringComparer]::Ordinal)
        throw "ProtocolCommon transitive Work Environment owners lack registered focused checks: $($missing -join ',')"
    }
    foreach ($required in @('scripts/Test-PublishedPrerequisiteSuffixReconciliation.ps1','scripts/Test-UnplannedPublicationClosure.ps1','scripts/Test-InheritedCandidateMaterialization.ps1','scripts/Test-DevelopmentUnitAdmission.ps1','scripts/Test-NormalValidationSelector.ps1')) {
        if (-not $consumers.Contains($required)) { throw "Known ProtocolCommon transitive owner is absent from the derived closure: $required" }
    }
    $result = @(ConvertTo-AffectedOrdinalUniqueStrings @($consumerCheckIds.ToArray()))
    $orderedOwnerEntrypoints = @(ConvertTo-AffectedOrdinalUniqueStrings @($ownerEntrypoints))
    $orderedConsumers = @($consumers)
    [Array]::Sort($orderedConsumers,[StringComparer]::Ordinal)
    $adjacencyRecords = @(Get-AffectedGraphAdjacencyRecords $graph)
    $auditClock.Stop()
    return [pscustomobject][ordered]@{
        check_ids = $result
        owner_entrypoints = $orderedOwnerEntrypoints.Count
        owner_entrypoint_paths = $orderedOwnerEntrypoints
        tracked_graph_nodes = @($graph.nodes).Count
        tracked_graph_adjacency = $adjacencyRecords
        protocol_consumers = $consumers.Count
        protocol_consumer_paths = $orderedConsumers
        adjacency_sha256 = Get-AffectedGraphAdjacencySha256 $graph
        consumer_sha256 = Get-AffectedProtocolConsumerSha256 -Consumers $orderedConsumers -CheckIds $result
        graph_elapsed_ms = [long]$graphClock.Elapsed.TotalMilliseconds
        total_elapsed_ms = [long]$auditClock.Elapsed.TotalMilliseconds
    }
}
function Invoke-AffectedGraphIndexSelfTest([string]$Root,[object]$Registry) {
    $audit = Get-AffectedProtocolCommonOwnerChecks -Root $Root -Registry $Registry
    Assert-AffectedProtocolCommonGraphProjection -Value $audit -Context 'Real-tree ProtocolCommon graph'
    foreach ($requiredNode in @('scripts/New-ValidatingCandidateRematerializationInput.ps1','scripts/Test-ValidatingCandidateRematerialization.ps1','scripts/ValidatingCandidateRematerialization.psm1','scripts/lib/MorphospaceSourceCompositionIdentity.psm1')) {
        Assert-True (@($audit.tracked_graph_adjacency.path) -ccontains $requiredNode) "Real-tree ProtocolCommon graph omitted the rematerialization node: $requiredNode"
    }
    Assert-True ([long]$audit.total_elapsed_ms -le 45000) "ProtocolCommon transitive owner audit exceeded its measured 45-second bound: $($audit.total_elapsed_ms)ms."

    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-index-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'scripts/lib'))
    try {
        $workEnvironmentSource = @'
& (Join-Path $PSScriptRoot 'Test-Conditional.ps1')
$checks = @(
    [pscustomobject]@{ script = 'Test-Dynamic.ps1' },
    [pscustomobject]@{ script = 'Test-Member.ps1' },
    [pscustomobject]@{ script = 'Test-Scope.ps1' },
    [pscustomobject]@{ script = 'Test-Typed.ps1' }
)
'@
        $conditionalSource = "`$ModulePath = Join-Path `$PSScriptRoot 'middle.psm1'`nif (`$true) { Import-Module `$ModulePath -Force }`n& (Join-Path `$PSScriptRoot 'Test-Invoked.ps1')`n. (Join-Path `$PSScriptRoot 'Test-Dot.ps1')`n"
        $dynamicSource = "param([string]`$ModulePath)`nif (`$true) { Import-Module `$ModulePath -Force }`n"
        $memberSource = "`$checks = @([pscustomobject]@{ script = 'Test-MemberLeaf.ps1' })`n`$actions = [pscustomobject]@{ Run = { 'ok' | Out-Null } }`n& `$checks[0].script`n& `$actions.Run`n"
        $memberManySource = "`$checks = @([pscustomobject]@{ script = 'Test-Outer.ps1' },[pscustomobject]@{ script = 'Test-Inner.ps1' })`n`$actions = @([pscustomobject]@{ Run = { 'one' | Out-Null } },[pscustomobject]@{ Run = { 'two' | Out-Null } })`n& `$checks[0].script`n& `$actions[0].Run`n"
        $memberEmptySource = "`$empty = [pscustomobject]@{}`n& `$empty.Run`n"
        $scopeSource = "`$RunnerPath = Join-Path `$PSScriptRoot 'Test-Outer.ps1'`n`$RunnerPath = Join-Path `$PSScriptRoot 'Test-Outer.ps1'`nfunction Invoke-Scoped([scriptblock]`$Action) {`n    `$RunnerPath = Join-Path `$PSScriptRoot 'Test-Inner.ps1'`n    & `$RunnerPath`n    & `$Action`n}`n& `$RunnerPath`nInvoke-Scoped { 'ok' | Out-Null }`n"
        $typedSource = "function Invoke-Typed([scriptblock]`$Action) { & `$Action }`nInvoke-Typed { 'ok' | Out-Null }`n"
        $unrelatedRelevantSource = "`$RunnerPath = Join-Path `$PSScriptRoot 'Test-Outer.ps1'`n`$Command = Get-Command pwsh`n`$Actions = [pscustomobject]@{ Run = { 'ok' | Out-Null } }`n& `$RunnerPath`n& `$Actions.Run`n& `$Command.Source`n"
        $smallUnrelatedSource = $unrelatedRelevantSource + "`$NoiseTable = @{ Noise000 = @{ Value = 'noise' } }`n`$Noise000 = @('alpha','beta')`n"
        $largeUnrelatedBuilder = [Text.StringBuilder]::new($unrelatedRelevantSource)
        [void]$largeUnrelatedBuilder.Append("`$NoiseTable = @{`n")
        foreach ($ordinal in 0..299) { [void]$largeUnrelatedBuilder.Append((('    Noise{0:D3} = @{{ Value = ''noise-{0:D3}'' }}' -f $ordinal) + "`n")) }
        [void]$largeUnrelatedBuilder.Append("}`n")
        foreach ($ordinal in 0..299) { [void]$largeUnrelatedBuilder.Append((('$Noise{0:D3} = @(''alpha'',''beta'',''gamma'')' -f $ordinal) + "`n")) }
        $largeUnrelatedSource = $largeUnrelatedBuilder.ToString()
        Write-Utf8 (Join-Path $fixture 'scripts/Test-WorkEnvironment.ps1') $workEnvironmentSource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Conditional.ps1') $conditionalSource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Dynamic.ps1') $dynamicSource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Member.ps1') $memberSource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-MemberMany.ps1') $memberManySource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-MemberEmpty.ps1') $memberEmptySource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Scope.ps1') $scopeSource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Typed.ps1') $typedSource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-UnrelatedSmall.ps1') $smallUnrelatedSource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-UnrelatedLarge.ps1') $largeUnrelatedSource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Ambiguous.ps1') "Import-Module @((Join-Path `$PSScriptRoot 'middle.psm1'),(Join-Path `$PSScriptRoot 'MIDDLE.psm1')) -Force`n"
        foreach ($leaf in @('Test-Dot.ps1','Test-Invoked.ps1','Test-MemberLeaf.ps1','Test-Outer.ps1','Test-Inner.ps1')) { Write-Utf8 (Join-Path $fixture "scripts/$leaf") "Import-Module (Join-Path `$PSScriptRoot 'middle.psm1') -Force`n" }
        Write-Utf8 (Join-Path $fixture 'scripts/middle.psm1') "if (`$true) { Import-Module (Join-Path `$PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force }`n"
        Write-Utf8 (Join-Path $fixture 'scripts/lib/MorphospaceProtocolCommon.psm1') "Set-StrictMode -Version 2.0`n"
        [void](Invoke-TestGit $fixture @('init','--initial-branch=main'))
        [void](Invoke-TestGit $fixture @('config','user.name','Affected Index Test'))
        [void](Invoke-TestGit $fixture @('config','user.email','affected-index@example.invalid'))
        [void](Invoke-TestGit $fixture @('add','.'))
        [void](Invoke-TestGit $fixture @('commit','-m','index fixture'))
        $tracked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($path in @(& git -C $fixture ls-files)) { [void]$tracked.Add(([string]$path).Replace('\','/')) }
        $owners = @(Get-AffectedWorkEnvironmentOwnerEntrypoints -Root $fixture -TrackedPaths $tracked)
        Assert-True (($owners -join ',') -ceq 'scripts/Test-Conditional.ps1,scripts/Test-Dynamic.ps1,scripts/Test-Member.ps1,scripts/Test-Scope.ps1,scripts/Test-Typed.ps1') 'Focused index fixture did not derive its exact direct/table owner roots.'
        $dynamicDeclaration = [pscustomobject][ordered]@{ importer='scripts/Test-Dynamic.ps1'; variable='ModulePath'; count=1; import_path='scripts/lib/MorphospaceProtocolCommon.psm1' }
        $graph = New-AffectedTrackedImportGraph -Root $fixture -Entrypoints $owners -DynamicImportDeclarations @($dynamicDeclaration) -TrackedPaths $tracked

        $expectedAdjacency = [pscustomobject][ordered]@{ schema='affected_owner_adjacency.v1'; nodes=@(
            [pscustomobject][ordered]@{ path='scripts/Test-Conditional.ps1'; imports=@('scripts/Test-Dot.ps1','scripts/Test-Invoked.ps1','scripts/middle.psm1') },
            [pscustomobject][ordered]@{ path='scripts/Test-Dot.ps1'; imports=@('scripts/middle.psm1') },
            [pscustomobject][ordered]@{ path='scripts/Test-Dynamic.ps1'; imports=@('scripts/lib/MorphospaceProtocolCommon.psm1') },
            [pscustomobject][ordered]@{ path='scripts/Test-Inner.ps1'; imports=@('scripts/middle.psm1') },
            [pscustomobject][ordered]@{ path='scripts/Test-Invoked.ps1'; imports=@('scripts/middle.psm1') },
            [pscustomobject][ordered]@{ path='scripts/Test-Member.ps1'; imports=@('scripts/Test-MemberLeaf.ps1') },
            [pscustomobject][ordered]@{ path='scripts/Test-MemberLeaf.ps1'; imports=@('scripts/middle.psm1') },
            [pscustomobject][ordered]@{ path='scripts/Test-Outer.ps1'; imports=@('scripts/middle.psm1') },
            [pscustomobject][ordered]@{ path='scripts/Test-Scope.ps1'; imports=@('scripts/Test-Inner.ps1','scripts/Test-Outer.ps1') },
            [pscustomobject][ordered]@{ path='scripts/Test-Typed.ps1'; imports=@() },
            [pscustomobject][ordered]@{ path='scripts/lib/MorphospaceProtocolCommon.psm1'; imports=@() },
            [pscustomobject][ordered]@{ path='scripts/middle.psm1'; imports=@('scripts/lib/MorphospaceProtocolCommon.psm1') }
        ) }
        $expectedAdjacencySha256 = Get-MorphospaceCanonicalJsonSha256 -Value $expectedAdjacency
        $observedAdjacencySha256 = Get-AffectedGraphAdjacencySha256 $graph
        Assert-True ($observedAdjacencySha256 -ceq $expectedAdjacencySha256) "Focused index adjacency digest changed: expected=$expectedAdjacencySha256 observed=$observedAdjacencySha256."

        $swappedEdges = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($node in @($graph.nodes)) { $swappedEdges[[string]$node] = @($graph.edges[[string]$node]) }
        $swappedEdges['scripts/Test-Conditional.ps1'] = @('scripts/Test-Inner.ps1','scripts/Test-Invoked.ps1','scripts/middle.psm1')
        $sameCardinalitySwap = [pscustomobject][ordered]@{ nodes=@($graph.nodes); edges=$swappedEdges }
        Assert-True ((Get-AffectedGraphAdjacencySha256 $sameCardinalitySwap) -cne $observedAdjacencySha256) 'Cardinality-preserving owner-edge substitution retained the canonical adjacency digest.'

        $scopePath = Join-Path $fixture 'scripts/Test-Scope.ps1'
        $scopeSha256 = Get-AffectedOwnerFileSha256 $scopePath
        $scopeIndex = New-AffectedTrackedFileAnalysisIndex -Importer 'scripts/Test-Scope.ps1' -AbsolutePath $scopePath -SourceSha256 $scopeSha256
        Assert-True ([string]$scopeIndex.key -ceq "scripts/Test-Scope.ps1|$scopeSha256") 'Per-file analysis index is not keyed to the exact path and captured working SHA.'
        $runnerAssignments = @($scopeIndex.assignment_records | Where-Object { $_.ast.Left -is [Management.Automation.Language.VariableExpressionAst] -and [string]$_.ast.Left.VariablePath.UserPath -ceq 'RunnerPath' })
        Assert-True ($runnerAssignments.Count -eq 3 -and $runnerAssignments[0].ast.Extent.StartOffset -lt $runnerAssignments[1].ast.Extent.StartOffset -and $runnerAssignments[1].ast.Extent.StartOffset -lt $runnerAssignments[2].ast.Extent.StartOffset) 'Indexed assignment capture changed exact source ordering.'
        Assert-True ($runnerAssignments[0].scope -eq $runnerAssignments[1].scope -and $runnerAssignments[2].scope -ne $runnerAssignments[0].scope) 'Indexed assignment capture collapsed lexical scope shadowing.'
        $rootBindings = @(Get-AffectedIndexedScopeAssignmentRecords -Index $scopeIndex -Scope $runnerAssignments[0].scope -Variable 'RunnerPath')
        $innerBindings = @(Get-AffectedIndexedScopeAssignmentRecords -Index $scopeIndex -Scope $runnerAssignments[2].scope -Variable 'RunnerPath')
        Assert-True ($rootBindings.Count -eq 2 -and $innerBindings.Count -eq 1 -and [string]$innerBindings[0].path_values[0] -ceq 'Test-Inner.ps1') 'Indexed lexical assignment lookup changed exact scope/variable binding.'

        $memberIndex = New-AffectedTrackedFileAnalysisIndex -Importer 'scripts/Test-Member.ps1' -AbsolutePath (Join-Path $fixture 'scripts/Test-Member.ps1') -SourceSha256 (Get-AffectedOwnerFileSha256 (Join-Path $fixture 'scripts/Test-Member.ps1'))
        Assert-True ($memberIndex.member_pairs_by_name.ContainsKey('script') -and @($memberIndex.member_pairs_by_name['script']).Count -eq 1 -and [string]$memberIndex.member_pairs_by_name['script'][0].path_values[0] -ceq 'Test-MemberLeaf.ps1') 'Indexed member-table lookup changed its exact member/path binding.'
        $typedIndex = New-AffectedTrackedFileAnalysisIndex -Importer 'scripts/Test-Typed.ps1' -AbsolutePath (Join-Path $fixture 'scripts/Test-Typed.ps1') -SourceSha256 (Get-AffectedOwnerFileSha256 (Join-Path $fixture 'scripts/Test-Typed.ps1'))
        $memberManyIndex = New-AffectedTrackedFileAnalysisIndex -Importer 'scripts/Test-MemberMany.ps1' -AbsolutePath (Join-Path $fixture 'scripts/Test-MemberMany.ps1') -SourceSha256 (Get-AffectedOwnerFileSha256 (Join-Path $fixture 'scripts/Test-MemberMany.ps1'))
        $emptyScriptMemberPairs = @(if ($typedIndex.member_pairs_by_name.ContainsKey('script')) { @($typedIndex.member_pairs_by_name['script']) } else { @() })
        $oneScriptMemberPair = @(if ($memberIndex.member_pairs_by_name.ContainsKey('script')) { @($memberIndex.member_pairs_by_name['script']) } else { @() })
        $manyScriptMemberPairs = @(if ($memberManyIndex.member_pairs_by_name.ContainsKey('script')) { @($memberManyIndex.member_pairs_by_name['script']) } else { @() })
        $emptyMemberDefinitions = @(if ($typedIndex.member_pairs_by_name.ContainsKey('Run')) { @($typedIndex.member_pairs_by_name['Run']) } else { @() })
        $oneMemberDefinition = @(if ($memberIndex.member_pairs_by_name.ContainsKey('Run')) { @($memberIndex.member_pairs_by_name['Run']) } else { @() })
        $manyMemberDefinitions = @(if ($memberManyIndex.member_pairs_by_name.ContainsKey('Run')) { @($memberManyIndex.member_pairs_by_name['Run']) } else { @() })
        Assert-True ($emptyScriptMemberPairs.Count -eq 0 -and $oneScriptMemberPair.Count -eq 1 -and $manyScriptMemberPairs.Count -eq 2) 'Indexed script-member-pair capture did not retain explicit empty/one/many array shapes.'
        Assert-True ($emptyMemberDefinitions.Count -eq 0 -and $oneMemberDefinition.Count -eq 1 -and $manyMemberDefinitions.Count -eq 2) 'Indexed member-definition capture did not retain explicit empty/one/many array shapes.'
        [void](New-AffectedTrackedImportGraph -Root $fixture -Entrypoints @('scripts/Test-MemberMany.ps1') -TrackedPaths $tracked)
        Assert-AffectedThrows { New-AffectedTrackedImportGraph -Root $fixture -Entrypoints @('scripts/Test-MemberEmpty.ps1') -TrackedPaths $tracked } '*neither a tracked script path nor an audited non-path callable*' 'Indexed graph accepted an empty member-definition callable.'
        $typedInvocation = @($typedIndex.invocations | Where-Object { [string]$_.first_element.Extent.Text -ceq '$Action' })[0]
        Assert-True (Test-AffectedIndexedScriptBlockParameter -Index $typedIndex -Scope $typedInvocation.scope -Variable 'Action') 'Indexed typed-scriptblock exemption was not exact to scope/name/type.'

        $smallUnrelatedPath = Join-Path $fixture 'scripts/Test-UnrelatedSmall.ps1'
        $largeUnrelatedPath = Join-Path $fixture 'scripts/Test-UnrelatedLarge.ps1'
        $smallUnrelatedClock = [Diagnostics.Stopwatch]::StartNew()
        $smallUnrelatedIndex = New-AffectedTrackedFileAnalysisIndex -Importer 'scripts/Test-UnrelatedSmall.ps1' -AbsolutePath $smallUnrelatedPath -SourceSha256 (Get-AffectedOwnerFileSha256 $smallUnrelatedPath)
        $smallUnrelatedClock.Stop()
        $largeUnrelatedClock = [Diagnostics.Stopwatch]::StartNew()
        $largeUnrelatedIndex = New-AffectedTrackedFileAnalysisIndex -Importer 'scripts/Test-UnrelatedLarge.ps1' -AbsolutePath $largeUnrelatedPath -SourceSha256 (Get-AffectedOwnerFileSha256 $largeUnrelatedPath)
        $largeUnrelatedClock.Stop()
        Assert-True ($largeUnrelatedIndex.analysis_metrics.analysis_nodes -gt ($smallUnrelatedIndex.analysis_metrics.analysis_nodes + 500)) 'Large unrelated-data fixture did not materially expand the parsed AST surface.'
        foreach ($metric in @('literal_assignment_subtree_scans','metadata_assignment_subtree_scans','member_value_subtree_scans')) {
            Assert-True ([long]$largeUnrelatedIndex.analysis_metrics.$metric -eq [long]$smallUnrelatedIndex.analysis_metrics.$metric) "Large unrelated data changed demanded subtree work: metric=$metric small=$($smallUnrelatedIndex.analysis_metrics.$metric) large=$($largeUnrelatedIndex.analysis_metrics.$metric)."
        }
        Assert-True ($largeUnrelatedIndex.get_command_variables.Contains('Command') -and $smallUnrelatedIndex.get_command_variables.Contains('Command')) 'Demand-first index omitted the exact .Source/Get-Command binding.'
        Assert-True ([long]$largeUnrelatedClock.Elapsed.TotalMilliseconds -le 5000) "Large unrelated-data index dominated focused work: $([long]$largeUnrelatedClock.Elapsed.TotalMilliseconds)ms."
        $smallUnrelatedGraph = New-AffectedTrackedImportGraph -Root $fixture -Entrypoints @('scripts/Test-UnrelatedSmall.ps1') -TrackedPaths $tracked
        $largeUnrelatedGraph = New-AffectedTrackedImportGraph -Root $fixture -Entrypoints @('scripts/Test-UnrelatedLarge.ps1') -TrackedPaths $tracked
        $smallUnrelatedClosure = @(Get-AffectedGraphReachability -Graph $smallUnrelatedGraph -Entrypoint 'scripts/Test-UnrelatedSmall.ps1' -Cache ([Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)) | Where-Object { $_ -cne 'scripts/Test-UnrelatedSmall.ps1' })
        $largeUnrelatedClosure = @(Get-AffectedGraphReachability -Graph $largeUnrelatedGraph -Entrypoint 'scripts/Test-UnrelatedLarge.ps1' -Cache ([Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)) | Where-Object { $_ -cne 'scripts/Test-UnrelatedLarge.ps1' })
        $smallUnrelatedDigest = Get-MorphospaceCanonicalJsonSha256 -Value ([pscustomobject][ordered]@{ imports=@($smallUnrelatedGraph.edges['scripts/Test-UnrelatedSmall.ps1']); closure=$smallUnrelatedClosure })
        $largeUnrelatedDigest = Get-MorphospaceCanonicalJsonSha256 -Value ([pscustomobject][ordered]@{ imports=@($largeUnrelatedGraph.edges['scripts/Test-UnrelatedLarge.ps1']); closure=$largeUnrelatedClosure })
        Assert-True ($largeUnrelatedDigest -ceq $smallUnrelatedDigest) 'Large unrelated assignments/hashtables changed normalized adjacency or reachability digest.'
        Write-Host "Demand-first unrelated-data fixture passed: small_nodes=$($smallUnrelatedIndex.analysis_metrics.analysis_nodes) large_nodes=$($largeUnrelatedIndex.analysis_metrics.analysis_nodes) small_ms=$([long]$smallUnrelatedClock.Elapsed.TotalMilliseconds) large_ms=$([long]$largeUnrelatedClock.Elapsed.TotalMilliseconds) digest=$largeUnrelatedDigest."

        Assert-AffectedThrows { New-AffectedTrackedImportGraph -Root $fixture -Entrypoints $owners -DynamicImportDeclarations @() -TrackedPaths $tracked } '*lacks an exact declaration*' 'Indexed graph accepted an undeclared conditional dynamic import.'
        Assert-AffectedThrows { New-AffectedTrackedImportGraph -Root $fixture -Entrypoints $owners -DynamicImportDeclarations @($dynamicDeclaration,$dynamicDeclaration) -TrackedPaths $tracked } '*duplicate*' 'Indexed graph accepted a duplicate dynamic declaration.'
        Assert-AffectedThrows { New-AffectedTrackedImportGraph -Root $fixture -Entrypoints @('scripts/Test-Ambiguous.ps1') -TrackedPaths $tracked } '*multiple literal tracked-script candidates*' 'Indexed graph accepted ambiguous/case-colliding literal targets.'
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Typed.ps1') "function Invoke-Typed(`$Action) { & `$Action }`nInvoke-Typed { 'ok' | Out-Null }`n"
        Assert-AffectedThrows { New-AffectedTrackedImportGraph -Root $fixture -Entrypoints $owners -DynamicImportDeclarations @($dynamicDeclaration) -TrackedPaths $tracked } '*Dynamic owner invocation*' 'Indexed graph accepted an untyped dynamically bound scriptblock invocation.'
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Typed.ps1') $typedSource
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Member.ps1') "`$checks = @([pscustomobject]@{ script = @('Test-MemberLeaf.ps1','Test-Outer.ps1') })`n& `$checks[0].script`n"
        Assert-AffectedThrows { New-AffectedTrackedImportGraph -Root $fixture -Entrypoints $owners -DynamicImportDeclarations @($dynamicDeclaration) -TrackedPaths $tracked } '*Static invocation member does not bind one literal script path: scripts/Test-Member.ps1*' 'Indexed graph accepted an ambiguous member-table script binding.'
        Write-Utf8 (Join-Path $fixture 'scripts/Test-Member.ps1') $memberSource
        Write-Utf8 $scopePath ($scopeSource + "# drift`n")
        Assert-AffectedThrows { Assert-AffectedTrackedFileAnalysisIndexStable $scopeIndex } '*source bytes changed during construction*' 'Indexed graph accepted source drift after the captured working SHA.'
        Write-Utf8 $scopePath $scopeSource
        Assert-AffectedTrackedFileAnalysisIndexStable $scopeIndex
        Write-Host "Focused graph index passed: fixture_adjacency_sha256=$observedAdjacencySha256 real_adjacency_sha256=$($audit.adjacency_sha256) real_consumer_sha256=$($audit.consumer_sha256) graph_ms=$($audit.graph_elapsed_ms) total_ms=$($audit.total_elapsed_ms)."
    } finally {
        if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
    return $audit
}
function Invoke-AffectedPerCheckDependencyClosureSelfTest([string]$Root,[object]$Registry) {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-per-check-closure-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'scripts'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'tools'))
    try {
        Write-Utf8 (Join-Path $fixture 'scripts/Entry.ps1') "Import-Module (Join-Path `$PSScriptRoot 'Static.psm1') -Force`nif (`$true) { Import-Module `$DynamicPath -Force }`n"
        Write-Utf8 (Join-Path $fixture 'scripts/Static.psm1') "Set-StrictMode -Version 2.0`n"
        Write-Utf8 (Join-Path $fixture 'scripts/Dynamic.psm1') "Set-StrictMode -Version 2.0`n"
        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "& `$UnknownRunner`n"
        Write-Utf8 (Join-Path $fixture 'scripts/Unrelated.ps1') "'unrelated'`n"
        Write-Utf8 (Join-Path $fixture 'tools/Test-Tool.ps1') "Import-Module 'scripts/Static.psm1' -Force`n"
        $records = @('scripts/Dynamic.psm1','scripts/Entry.ps1','scripts/Fallback.ps1','scripts/Static.psm1','scripts/Unrelated.ps1','tools/Test-Tool.ps1') | ForEach-Object {
            [pscustomobject][ordered]@{mode='100644';type='blob';blob=('0' * 40);path=$_}
        }
        $inventory = [pscustomobject][ordered]@{records=@($records)}
        $declaration = [pscustomobject][ordered]@{importer='scripts/Entry.ps1';variable='DynamicPath';count=1;target_paths=@('scripts/Dynamic.psm1')}
        $exact = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Entry.ps1' -Inventory $inventory -DynamicDeclarations @($declaration)
        Assert-True (($exact.paths -join ',') -ceq 'scripts/Dynamic.psm1,scripts/Entry.ps1,scripts/Static.psm1') 'Per-check dependency closure did not retain only its exact static and declared dynamic script closure.'
        Assert-True ([string]$exact.resolution.mode -ceq 'exact' -and @($exact.resolution.used_declarations).Count -eq 1 -and @($exact.resolution.fallback_reasons).Count -eq 0) 'Per-check exact dependency resolution did not bind its used declaration and empty fallback reason set.'
        $toolExact = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'tools/Test-Tool.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True (($toolExact.paths -join ',') -ceq 'scripts/Static.psm1,tools/Test-Tool.ps1' -and [string]$toolExact.resolution.mode -ceq 'exact') 'Tracked tools entrypoint did not retain its exact static script closure.'
        Write-Utf8 (Join-Path $fixture 'tools/Test-Tool.ps1') "& `$UnknownToolRunner`n"
        $toolFallback = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'tools/Test-Tool.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$toolFallback.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($toolFallback.resolution.fallback_reasons | Where-Object { [string]$_.importer -ceq 'tools/Test-Tool.ps1' -and [string]$_.variable -ceq 'UnknownToolRunner' }).Count -eq 1) 'Tracked tools fallback omitted its tool-origin reason.'
        Write-Utf8 (Join-Path $fixture 'tools/Test-Tool.ps1') "Import-Module 'scripts/Static.psm1' -Force`n"
        $fallback = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$fallback.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($fallback.paths).Count -eq 6) 'Unknown per-check dispatch did not conservatively bind every tracked script.'
        Assert-True (@($fallback.resolution.fallback_reasons | Where-Object { [string]$_.importer -ceq 'scripts/Fallback.ps1' -and [string]$_.variable -ceq 'UnknownRunner' -and [string]$_.kind -ceq 'unresolved-invocation' }).Count -eq 1) 'Unknown per-check dispatch did not publish its exact fallback reason.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = 'Static.psm1'`n`$Runner = `$RuntimePath`n& `$Runner`n"
        $mixed = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$mixed.resolution.mode -ceq 'all-tracked-scripts-fallback' -and ($mixed.paths -join ',') -ceq 'scripts/Dynamic.psm1,scripts/Entry.ps1,scripts/Fallback.ps1,scripts/Static.psm1,scripts/Unrelated.ps1,tools/Test-Tool.ps1') 'Mixed literal and unclassified assignment under-bound the imported-byte closure.'
        Assert-True (@($mixed.resolution.fallback_reasons | Where-Object { [string]$_.importer -ceq 'scripts/Fallback.ps1' -and [string]$_.variable -ceq 'Runner' -and [string]$_.kind -ceq 'ambiguous-static-binding' }).Count -eq 1) 'Mixed literal and unclassified assignment did not publish its conservative ambiguity reason.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = 'Static.psm1'`nfunction Invoke-Mixed {`n    `$Runner = `$RuntimePath`n    & `$Runner`n}`nInvoke-Mixed`n"
        $nestedInnerDynamic = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$nestedInnerDynamic.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($nestedInnerDynamic.paths).Count -eq 6) 'Nested unclassified assignment over an outer literal under-bound the imported-byte closure.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = `$RuntimePath`nfunction Invoke-Mixed {`n    `$Runner = 'Static.psm1'`n    & `$Runner`n}`nInvoke-Mixed`n"
        $nestedOuterDynamic = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$nestedOuterDynamic.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($nestedOuterDynamic.paths).Count -eq 6) 'Outer unclassified assignment below a nested literal under-bound the imported-byte closure.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = 'Static.psm1'`n& `$rUnNeR`n"
        $caseVariantExact = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$caseVariantExact.resolution.mode -ceq 'exact' -and ($caseVariantExact.paths -join ',') -ceq 'scripts/Fallback.ps1,scripts/Static.psm1') 'Case-variant assignment and invocation did not retain one PowerShell variable identity.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = 'Static.psm1'`n`$rUNNER = `$RuntimePath`n& `$runner`n"
        $caseVariantMixed = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$caseVariantMixed.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($caseVariantMixed.paths).Count -eq 6) 'Case-variant mixed assignments under-bound one PowerShell variable identity.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$rUnNeR = @('Static.psm1', `$RuntimePath)`n& `$RUNNER`n"
        $singleRhsMixed = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$singleRhsMixed.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($singleRhsMixed.paths).Count -eq 6) 'One RHS containing a literal path and unknown expression under-bound the imported-byte closure.'

        $singleRhsIncompleteDeclaration = [pscustomobject][ordered]@{importer='scripts/Fallback.ps1';variable='runner';count=1;target_paths=@('scripts/Dynamic.psm1')}
        Assert-AffectedThrows { Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @($singleRhsIncompleteDeclaration) } '*omits observed static target*' 'Incomplete declaration omitted the literal member of a mixed single-RHS dispatch.'
        $singleRhsCompleteDeclaration = [pscustomobject][ordered]@{importer='scripts/Fallback.ps1';variable='RUNNER';count=1;target_paths=@('scripts/Dynamic.psm1','scripts/Static.psm1')}
        $singleRhsDeclared = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @($singleRhsCompleteDeclaration)
        Assert-True ([string]$singleRhsDeclared.resolution.mode -ceq 'exact' -and ($singleRhsDeclared.paths -join ',') -ceq 'scripts/Dynamic.psm1,scripts/Fallback.ps1,scripts/Static.psm1') 'Complete declaration did not retain the literal and dynamic members of a mixed single-RHS dispatch.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = @('Static.psm1', `$RuntimePath)`nfunction Invoke-Mixed {`n    & `$rUnNeR`n}`nInvoke-Mixed`n"
        $nestedSingleRhsMixed = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$nestedSingleRhsMixed.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($nestedSingleRhsMixed.paths).Count -eq 6) 'Nested invocation ignored a case-variant outer mixed RHS assignment.'
        $nestedSingleRhsDeclared = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @($singleRhsCompleteDeclaration)
        Assert-True ([string]$nestedSingleRhsDeclared.resolution.mode -ceq 'exact' -and ($nestedSingleRhsDeclared.paths -join ',') -ceq 'scripts/Dynamic.psm1,scripts/Fallback.ps1,scripts/Static.psm1') 'Complete declaration did not resolve the entire nested mixed dispatch.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "function Invoke-Typed([scriptblock]`$Action) { & `$aCtIoN }`nInvoke-Typed { 'typed' | Out-Null }`n"
        $typedCaseVariant = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$typedCaseVariant.resolution.mode -ceq 'exact' -and ($typedCaseVariant.paths -join ',') -ceq 'scripts/Fallback.ps1') 'Case-variant typed-scriptblock lookup lost its exact callable classification.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = 'Static.psm1'`n& `$Runner`n`$Runner = 'Dynamic.psm1'`n"
        $afterUseAssignment = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$afterUseAssignment.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($afterUseAssignment.paths).Count -eq 6) 'Assignment after invocation was treated as a definitely prior dispatch binding.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "function Invoke-Conditional(`$Condition) {`n    if (`$Condition) { `$Runner = 'Static.psm1' }`n    & `$runner`n}`nInvoke-Conditional `$true`n"
        $conditionalAssignment = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$conditionalAssignment.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($conditionalAssignment.paths).Count -eq 6) 'Conditional assignment was treated as an unconditional dispatch binding.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "try {`n    `$Runner = 'Static.psm1'`n    & `$runner`n} finally {}`n"
        $sameBlockAssignment = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$sameBlockAssignment.resolution.mode -ceq 'exact' -and ($sameBlockAssignment.paths -join ',') -ceq 'scripts/Fallback.ps1,scripts/Static.psm1') 'A definitely prior assignment in the invocation block was treated as conditional or out of scope.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$script:Runner = 'Static.psm1'`nfunction Invoke-RootScriptRunner { & `$script:runner }`nInvoke-RootScriptRunner`n"
        $rootScriptAssignment = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$rootScriptAssignment.resolution.mode -ceq 'exact' -and ($rootScriptAssignment.paths -join ',') -ceq 'scripts/Fallback.ps1,scripts/Static.psm1') 'A definitely prior root script-scoped assignment did not bind the same explicitly script-scoped function invocation.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "function Invoke-Parameter(`$Command) { & `$cOmMaNd }`nInvoke-Parameter 'Static.psm1'`n"
        $untypedCommandParameter = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$untypedCommandParameter.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($untypedCommandParameter.paths).Count -eq 6) 'Untyped Command parameter received name-only external-command trust.'
        $untypedCommandDeclaration = [pscustomobject][ordered]@{importer='scripts/Fallback.ps1';variable='command';count=1;target_paths=@('scripts/Static.psm1')}
        $declaredUntypedCommand = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @($untypedCommandDeclaration)
        Assert-True ([string]$declaredUntypedCommand.resolution.mode -ceq 'exact' -and ($declaredUntypedCommand.paths -join ',') -ceq 'scripts/Fallback.ps1,scripts/Static.psm1') 'Closed declaration did not resolve an untyped case-variant Command parameter.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = Get-Command 'Static.psm1'`n& `$runner`n"
        $literalGetCommand = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$literalGetCommand.resolution.mode -ceq 'exact' -and ($literalGetCommand.paths -join ',') -ceq 'scripts/Fallback.ps1,scripts/Static.psm1') 'Literal tracked Get-Command assignment did not retain its script dependency.'
        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = Get-Command `$RuntimePath`n& `$runner`n"
        $dynamicGetCommand = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$dynamicGetCommand.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($dynamicGetCommand.paths).Count -eq 6) 'Dynamic Get-Command assignment received an unconditional non-path exemption.'
        $dynamicGetCommandDeclaration = [pscustomobject][ordered]@{importer='scripts/Fallback.ps1';variable='runner';count=1;target_paths=@('scripts/Dynamic.psm1')}
        $declaredDynamicGetCommand = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @($dynamicGetCommandDeclaration)
        Assert-True ([string]$declaredDynamicGetCommand.resolution.mode -ceq 'exact' -and ($declaredDynamicGetCommand.paths -join ',') -ceq 'scripts/Dynamic.psm1,scripts/Fallback.ps1') 'Closed declaration did not resolve a dynamic Get-Command assignment.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "& (Get-Command (Join-Path `$PSScriptRoot 'Static.psm1')).Source`n"
        $literalGetCommandMember = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$literalGetCommandMember.resolution.mode -ceq 'exact' -and ($literalGetCommandMember.paths -join ',') -ceq 'scripts/Fallback.ps1,scripts/Static.psm1') 'Direct Get-Command.Source literal invocation omitted its tracked script dependency.'
        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "& (Get-Command `$RuntimePath).Source`n"
        $dynamicGetCommandMember = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$dynamicGetCommandMember.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($dynamicGetCommandMember.paths).Count -eq 6) 'Direct dynamic Get-Command.Source invocation bypassed conservative closure.'
        $dynamicGetCommandMemberDeclaration = [pscustomobject][ordered]@{importer='scripts/Fallback.ps1';variable='runtimepath';count=1;target_paths=@('scripts/Dynamic.psm1')}
        $declaredDynamicGetCommandMember = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @($dynamicGetCommandMemberDeclaration)
        Assert-True ([string]$declaredDynamicGetCommandMember.resolution.mode -ceq 'exact' -and ($declaredDynamicGetCommandMember.paths -join ',') -ceq 'scripts/Dynamic.psm1,scripts/Fallback.ps1') 'Closed declaration did not resolve a direct dynamic Get-Command.Source invocation.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$first = @{ script = { 'safe' | Out-Null } }`n`$second = @{ other = { 'other' | Out-Null } }`n& `$first.script`n"
        $exactMemberReceiver = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$exactMemberReceiver.resolution.mode -ceq 'exact' -and ($exactMemberReceiver.paths -join ',') -ceq 'scripts/Fallback.ps1') 'Exact receiver/member scriptblock proof was not retained.'
        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$first = @{ script = { 'safe' | Out-Null } }`n`$second = @{ script = `$RuntimePath }`n& `$second.script`n"
        $memberReceiverCollision = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$memberReceiverCollision.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($memberReceiverCollision.paths).Count -eq 6) 'Unrelated receiver with the same member name inherited another receiver scriptblock exemption.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "`$Runner = 'Static.psm1'`n`$Runner = `$RuntimePath`n& `$Runner`n"
        $mixedDeclaration = [pscustomobject][ordered]@{importer='scripts/Fallback.ps1';variable='Runner';count=1;target_paths=@('scripts/Dynamic.psm1','scripts/Static.psm1')}
        $declaredMixed = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @($mixedDeclaration)
        Assert-True ([string]$declaredMixed.resolution.mode -ceq 'exact' -and ($declaredMixed.paths -join ',') -ceq 'scripts/Dynamic.psm1,scripts/Fallback.ps1,scripts/Static.psm1' -and @($declaredMixed.resolution.used_declarations).Count -eq 1) 'Closed mixed-dispatch declaration did not retain the exact complete imported-byte closure.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "& `$ArgumentRunner { 'argument' | Out-Null }`n"
        $scriptBlockArgumentFallback = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$scriptBlockArgumentFallback.resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($scriptBlockArgumentFallback.paths).Count -eq 6) 'Variable invocation with a scriptblock argument bypassed conservative dependency fallback.'
        Assert-True (@($scriptBlockArgumentFallback.resolution.fallback_reasons | Where-Object { [string]$_.importer -ceq 'scripts/Fallback.ps1' -and [string]$_.variable -ceq 'ArgumentRunner' -and [string]$_.kind -ceq 'unresolved-invocation' }).Count -eq 1) 'Variable invocation with a scriptblock argument omitted its exact fallback reason.'

        $scriptBlockArgumentDeclaration = [pscustomobject][ordered]@{importer='scripts/Fallback.ps1';variable='ArgumentRunner';count=1;target_paths=@('scripts/Dynamic.psm1')}
        $declaredScriptBlockArgument = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @($scriptBlockArgumentDeclaration)
        Assert-True ([string]$declaredScriptBlockArgument.resolution.mode -ceq 'exact' -and ($declaredScriptBlockArgument.paths -join ',') -ceq 'scripts/Dynamic.psm1,scripts/Fallback.ps1' -and @($declaredScriptBlockArgument.resolution.used_declarations).Count -eq 1) 'Closed variable invocation declaration with a scriptblock argument did not retain its exact imported-byte closure.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "& { 'literal command target' | Out-Null } 'argument'`n"
        $literalScriptBlockTarget = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Fallback.ps1' -Inventory $inventory -DynamicDeclarations @()
        Assert-True ([string]$literalScriptBlockTarget.resolution.mode -ceq 'exact' -and ($literalScriptBlockTarget.paths -join ',') -ceq 'scripts/Fallback.ps1') 'Literal scriptblock command target lost its exact non-importing exemption.'

        Write-Utf8 (Join-Path $fixture 'scripts/Fallback.ps1') "& `$UnknownRunner`n"
        $countDamage = $declaration | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8 -DateKind String; $countDamage.count = 2
        Assert-AffectedThrows { Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Entry.ps1' -Inventory $inventory -DynamicDeclarations @($countDamage) } '*declaration count changed*' 'Per-check dependency closure accepted dynamic declaration count drift.'
        $duplicateDamage = @($declaration,$declaration)
        Assert-AffectedThrows { Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Entry.ps1' -Inventory $inventory -DynamicDeclarations $duplicateDamage } '*invalid or duplicate identity*' 'Per-check dependency closure accepted a duplicate dynamic declaration.'
        $aliasDeclaration = $declaration | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8 -DateKind String; $aliasDeclaration.variable = 'dynamicpath'
        $aliasExact = Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Entry.ps1' -Inventory $inventory -DynamicDeclarations @($aliasDeclaration)
        Assert-True ([string]$aliasExact.resolution.mode -ceq 'exact' -and ($aliasExact.paths -join ',') -ceq 'scripts/Dynamic.psm1,scripts/Entry.ps1,scripts/Static.psm1' -and @($aliasExact.resolution.used_declarations).Count -eq 1) 'Case-variant declaration alias did not resolve the PowerShell variable invocation.'
        $aliasCountDamage = $aliasDeclaration | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8 -DateKind String; $aliasCountDamage.count = 2
        Assert-AffectedThrows { Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Entry.ps1' -Inventory $inventory -DynamicDeclarations @($aliasCountDamage) } '*declaration count changed*' 'Case-variant declaration alias bypassed exact observation count validation.'
        Assert-AffectedThrows { Resolve-MorphospaceAffectedCheckDependencyClosure -RepositoryRoot $fixture -Entrypoint 'scripts/Entry.ps1' -Inventory $inventory -DynamicDeclarations @($declaration,$aliasDeclaration) } '*invalid or duplicate identity*' 'Case-variant duplicate declarations were treated as distinct PowerShell variable identities.'

        $compiled = Test-MorphospaceAffectedValidationRegistry -Registry $Registry -RepositoryRoot $Root -SchemaPath (Join-Path $Root 'schemas/affected-validation-registry-v1.schema.json')
        $head = (& git -C $Root rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[0-9a-f]{40}$') { throw 'Per-check PR134 regression could not resolve the exact adopted HEAD.' }
        $realInventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $Root -Commit $head
        $ledgerCorrectionPaths = @(
            'scripts/Test-BlockedSupersessionTerminalValidation.ps1',
            'scripts/Test-OwnershipAuthority.ps1',
            'scripts/Test-TransitionLedger.ps1',
            'scripts/lib/MorphospaceBlockedSupersessionTerminalValidation.psm1',
            'scripts/lib/MorphospaceOwnership.psm1',
            'scripts/lib/MorphospaceTransitionLedger.psm1',
            'scripts/lib/MorphospaceValidationAuthority.psm1'
        )
        $safeIds = @('project-isolation','protocol-foundation','skill-templates')
        $digests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $timings = [Collections.Generic.List[object]]::new()
        foreach ($checkId in $safeIds) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $closure = Get-MorphospaceAffectedCheckDependencyClosure -Check $compiled.checks[$checkId] -CompiledRegistry $compiled -Inventory $realInventory -RepositoryRoot $Root
            $clock.Stop()
            $intersection = @($closure.manifest.path | Where-Object { $ledgerCorrectionPaths -ccontains [string]$_ })
            Assert-True ($intersection.Count -eq 0 -and [string]$closure.resolution.mode -ceq 'exact' -and @($closure.manifest).Count -lt 50) "PR134-style ledger-only correction over-invalidated unchanged check '$checkId'."
            [void]$digests.Add((Get-MorphospaceCanonicalJsonSha256 -Value @($closure.manifest)))
            [void]$timings.Add([pscustomobject][ordered]@{check_id=$checkId;elapsed_ms=[long]$clock.Elapsed.TotalMilliseconds;dependency_count=@($closure.manifest).Count})
        }
        Assert-True ($digests.Count -eq $safeIds.Count) 'Per-check safe corpus collapsed to one common aggregate dependency identity.'

        # Validating-candidate rematerialization is deliberately a focused
        # producer/consumer owner. Its test loads the two owner modules through
        # script-scoped variables, so those invocations must remain completely
        # and exactly declared instead of falling back to every tracked script.
        $rematerializationClock = [Diagnostics.Stopwatch]::StartNew()
        $rematerializationClosure = Get-MorphospaceAffectedCheckDependencyClosure -Check $compiled.checks['validating-candidate-rematerialization'] -CompiledRegistry $compiled -Inventory $realInventory -RepositoryRoot $Root
        $rematerializationClock.Stop()
        $rematerializationPaths = @($rematerializationClosure.manifest.path)
        $rematerializationDeclarations = @($rematerializationClosure.resolution.used_declarations)
        $rematerializationDeclarationIdentities = @($rematerializationDeclarations | ForEach-Object { "$([string]$_.importer)|$([string]$_.variable)|$([int]$_.count)|$(@($_.target_paths) -join ',')" })
        Assert-True ([string]$rematerializationClosure.resolution.mode -ceq 'exact' -and @($rematerializationClosure.resolution.fallback_reasons).Count -eq 0) 'Validating-candidate rematerialization did not retain exact dependency resolution with no fallback.'
        Assert-True (($rematerializationDeclarationIdentities -join ';') -ceq 'scripts/Test-ValidatingCandidateRematerialization.ps1|script:RematerializationOwnerModule|2|scripts/ValidatingCandidateRematerialization.psm1') 'Validating-candidate rematerialization did not consume exactly its one remaining dynamic owner declaration.'
        foreach ($requiredPath in @(
            'schemas/candidate-freeze-v2.schema.json',
            'scripts/New-SourceCompositionLock.ps1',
            'scripts/New-ValidatingCandidateRematerializationInput.ps1',
            'scripts/Test-ValidatingCandidateRematerialization.ps1',
            'scripts/ValidatingCandidateRematerialization.psm1',
            'scripts/lib/MorphospaceSourceCompositionIdentity.psm1'
        )) {
            Assert-True ($rematerializationPaths -ccontains $requiredPath) "Validating-candidate rematerialization dependency closure omitted '$requiredPath'."
        }
        Assert-True ($rematerializationPaths -cnotcontains 'scripts/Test-WorkEnvironment.ps1') 'Validating-candidate rematerialization dependency closure expanded into the cumulative Work Environment aggregate.'
        [void]$timings.Add([pscustomobject][ordered]@{check_id='validating-candidate-rematerialization';elapsed_ms=[long]$rematerializationClock.Elapsed.TotalMilliseconds;dependency_count=@($rematerializationClosure.manifest).Count})

        $ledgerCheck = @($Registry.checks | Where-Object { [string]$_.check_id -ceq 'transition-ledger' })
        Assert-True ($ledgerCheck.Count -eq 1) 'The PR134-style correction proof lacks one transition-ledger check.'
        $triggerPatterns = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($pathSetId in @($ledgerCheck[0].trigger_path_sets)) {
            foreach ($pathSet in @($Registry.path_sets | Where-Object { [string]$_.path_set_id -ceq [string]$pathSetId })) {
                foreach ($pattern in @($pathSet.patterns)) { [void]$triggerPatterns.Add([string]$pattern) }
            }
        }
        $directlyMappedCorrectionPaths = @($ledgerCorrectionPaths | Where-Object { $triggerPatterns.Contains([string]$_) })
        Assert-True ($directlyMappedCorrectionPaths.Count -ge 3) 'The transition-ledger owner lost direct path-set invalidation for the PR134-style ledger/authority correction.'
        [void]$timings.Add([pscustomobject][ordered]@{check_id='transition-ledger-direct-map';elapsed_ms=0;dependency_count=$directlyMappedCorrectionPaths.Count})
        Write-Host "Per-check dependency closure passed: corpus=$((@($timings | ForEach-Object { "$($_.check_id):$($_.dependency_count):$($_.elapsed_ms)ms" }) -join ','))"
    } finally {
        if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
}
function Invoke-WorkflowSelectionGate([string]$JobBody, [string]$SelectionVariable, [string]$SelectionValue, [string]$SegmentResultVariable) {
    $run = [regex]::Match($JobBody, '(?ms)^        run: \|\r?\n(?<script>.*?)(?=^      - |\z)')
    if (-not $run.Success) { throw 'Workflow job lacks a first run script.' }
    $lines = @($run.Groups['script'].Value -split "`r?`n" | Select-Object -First 3)
    if ($lines.Count -ne 3) { throw 'Workflow job lacks the closed selection gate.' }
    $gate = ($lines -join [Environment]::NewLine).Replace('exit 0', 'return')
    $saved = @{}
    foreach ($name in @('INFRA_RESULT','SELECT_RESULT',$SelectionVariable,$SegmentResultVariable)) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $env:INFRA_RESULT = 'success'; $env:SELECT_RESULT = 'success'
        [Environment]::SetEnvironmentVariable($SelectionVariable, $SelectionValue, 'Process')
        [Environment]::SetEnvironmentVariable($SegmentResultVariable, 'success', 'Process')
        & ([scriptblock]::Create($gate))
    } finally {
        foreach ($name in @('INFRA_RESULT','SELECT_RESULT',$SelectionVariable,$SegmentResultVariable)) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

if ($BatchSelfTestOnly) {
    Invoke-AffectedBatchSelfTest
    return
}
if ($DependencyClosureSelfTestOnly) {
    $focusedRegistry = Read-MorphospaceProtocolJson -Path (Join-Path $repoRoot 'manifests/affected-validation-registry.json')
    Invoke-AffectedPerCheckDependencyClosureSelfTest -Root $repoRoot -Registry $focusedRegistry
    return
}
if ($GraphSelfTestOnly) {
    $focusedRegistry = Read-MorphospaceProtocolJson -Path (Join-Path $repoRoot 'manifests/affected-validation-registry.json')
    [void](Test-MorphospaceAffectedValidationRegistry -Registry $focusedRegistry -RepositoryRoot $repoRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json'))
    [void](Invoke-AffectedGraphIndexSelfTest -Root $repoRoot -Registry $focusedRegistry)
    Invoke-AffectedPerCheckDependencyClosureSelfTest -Root $repoRoot -Registry $focusedRegistry
    return
}

$runFullSelector = [string]::IsNullOrWhiteSpace($SelfTestPhase)
$runGraphPhase = $SelfTestPhase -ceq 'graph-import-closure'
$runDependencyClosurePhase = $SelfTestPhase -ceq 'dependency-closure'
$runExecutorPassPhase = $SelfTestPhase -ceq 'executor-pass-schema'
$runExecutorNativeFailureDamagePhase = $SelfTestPhase -ceq 'executor-native-failure-damage'
$runExecutorNativeExit125DamagePhase = $SelfTestPhase -ceq 'executor-native-exit125-damage'
$runExecutorForgedTerminalDamagePhase = $SelfTestPhase -ceq 'executor-forged-terminal-damage'
$runExecutorParentContainmentDamagePhase = $SelfTestPhase -ceq 'executor-parent-containment-damage'
$runExecutorDescendantContainmentDamagePhase = $SelfTestPhase -ceq 'executor-descendant-containment-damage'
$runExecutorOutputCeilingDamagePhase = $SelfTestPhase -ceq 'executor-output-ceiling-damage'
$runExecutorTimeoutDamagePhase = $SelfTestPhase -ceq 'executor-timeout-damage'
$runExecutorDualStreamDamagePhase = $SelfTestPhase -ceq 'executor-dual-stream-damage'
$runExecutorSourceIntegrityDamagePhase = $SelfTestPhase -ceq 'executor-source-integrity-damage'
$runExecutorPublicationCollisionDamagePhase = $SelfTestPhase -ceq 'executor-publication-collision-damage'
$runExecutorDamagePhase = $runExecutorNativeFailureDamagePhase -or $runExecutorNativeExit125DamagePhase -or $runExecutorForgedTerminalDamagePhase -or $runExecutorParentContainmentDamagePhase -or $runExecutorDescendantContainmentDamagePhase -or $runExecutorOutputCeilingDamagePhase -or $runExecutorTimeoutDamagePhase -or $runExecutorDualStreamDamagePhase -or $runExecutorSourceIntegrityDamagePhase -or $runExecutorPublicationCollisionDamagePhase
$runSelectionPhase = $SelfTestPhase -ceq 'selection-scenarios'
$runTrustSelfPhase = $SelfTestPhase -ceq 'trust-self-executor'
$runTrustRoutingPhase = $SelfTestPhase -ceq 'trust-routing-contracts'
$runTrustMappingsPhase = $SelfTestPhase -ceq 'trust-proportional-mappings'
$runTrustDamagePhase = $SelfTestPhase -ceq 'trust-damage-final'
$runTrustPhase = $runTrustSelfPhase -or $runTrustRoutingPhase -or $runTrustMappingsPhase -or $runTrustDamagePhase
$phaseRoot = [Environment]::GetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_PHASE_ROOT','Process')

if ($runGraphPhase) {
    $focusedRegistry = Read-MorphospaceProtocolJson -Path (Join-Path $repoRoot 'manifests/affected-validation-registry.json')
    [void](Test-MorphospaceAffectedValidationRegistry -Registry $focusedRegistry -RepositoryRoot $repoRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json'))
    $focusedAudit = Invoke-AffectedGraphIndexSelfTest -Root $repoRoot -Registry $focusedRegistry
    if (-not [string]::IsNullOrWhiteSpace($phaseRoot)) {
        $phaseRoot = [IO.Path]::GetFullPath($phaseRoot)
        if (-not [IO.Directory]::Exists($phaseRoot)) { [void][IO.Directory]::CreateDirectory($phaseRoot) }
        $graphOutputPath = Join-Path $phaseRoot 'graph-import-closure.output.json'
        Write-AffectedScenarioJsonCreateNew -Path $graphOutputPath -Value ([pscustomobject][ordered]@{
            schema='rusty.morphospace.diagnostic.affected_validation_graph_output.v1'
            owner_entrypoints=[int]$focusedAudit.owner_entrypoints
            owner_entrypoint_paths=@($focusedAudit.owner_entrypoint_paths)
            tracked_graph_nodes=[int]$focusedAudit.tracked_graph_nodes
            tracked_graph_adjacency=@($focusedAudit.tracked_graph_adjacency)
            protocol_consumers=[int]$focusedAudit.protocol_consumers
            protocol_consumer_paths=@($focusedAudit.protocol_consumer_paths)
            adjacency_sha256=[string]$focusedAudit.adjacency_sha256
            consumer_sha256=[string]$focusedAudit.consumer_sha256
            check_ids=@($focusedAudit.check_ids)
        })
    }
    return
}

if ($runDependencyClosurePhase) {
    $focusedRegistry = Read-MorphospaceProtocolJson -Path (Join-Path $repoRoot 'manifests/affected-validation-registry.json')
    [void](Test-MorphospaceAffectedValidationRegistry -Registry $focusedRegistry -RepositoryRoot $repoRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json'))
    Invoke-AffectedPerCheckDependencyClosureSelfTest -Root $repoRoot -Registry $focusedRegistry
    return
}

$selectorSelfTestClock = [Diagnostics.Stopwatch]::StartNew()
$registryPath = Join-Path $repoRoot 'manifests/affected-validation-registry.json'
$registry = Read-MorphospaceProtocolJson -Path $registryPath
[void](Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $repoRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json'))
$executorContainmentSource = if ($runFullSelector -or $runExecutorPassPhase -or $runExecutorDamagePhase) { Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -Raw } else { $null }
if ($null -ne $executorContainmentSource) { Assert-AffectedExecutorContainmentSource -Source $executorContainmentSource }
$protocolCommonConsumerChecks = @()
if ($runTrustMappingsPhase) {
    if ([string]::IsNullOrWhiteSpace($phaseRoot)) { throw 'Trust proportional-mapping phase requires the exact graph-phase evidence root.' }
    $graphOutputPath = Join-Path ([IO.Path]::GetFullPath($phaseRoot)) 'graph-import-closure.output.json'
    if (-not [IO.File]::Exists($graphOutputPath)) { throw 'Trust proportional-mapping phase requires the graph/import-closure output.' }
    $graphOutput = Read-MorphospaceProtocolJson -Path $graphOutputPath
    Assert-AffectedScenarioProperties -Value $graphOutput -Expected @('schema','owner_entrypoints','owner_entrypoint_paths','tracked_graph_nodes','tracked_graph_adjacency','protocol_consumers','protocol_consumer_paths','adjacency_sha256','consumer_sha256','check_ids') -Context 'Graph/import-closure output'
    Assert-True ([string]$graphOutput.schema -ceq 'rusty.morphospace.diagnostic.affected_validation_graph_output.v1') 'Trust proportional-mapping phase rejected the graph output schema.'
    Assert-AffectedProtocolCommonGraphProjection -Value $graphOutput -Context 'Trust proportional-mapping graph output'
    $protocolCommonConsumerChecks = @($graphOutput.check_ids)
}

if ($runFullSelector) {
    $protocolCommonAudit = Get-AffectedProtocolCommonOwnerChecks -Root $repoRoot -Registry $registry
    Assert-True ([long]$protocolCommonAudit.total_elapsed_ms -le 45000) "ProtocolCommon transitive owner audit exceeded its measured 45-second bound: $($protocolCommonAudit.total_elapsed_ms)ms."
    $protocolCommonConsumerChecks = @($protocolCommonAudit.check_ids)
    Write-Host "ProtocolCommon owner graph passed: roots=$($protocolCommonAudit.owner_entrypoints) nodes=$($protocolCommonAudit.tracked_graph_nodes) consumers=$($protocolCommonAudit.protocol_consumers) graph_ms=$($protocolCommonAudit.graph_elapsed_ms) total_ms=$($protocolCommonAudit.total_elapsed_ms)."
    Invoke-AffectedPerCheckDependencyClosureSelfTest -Root $repoRoot -Registry $registry

    $savedOrdinalCulture = [Globalization.CultureInfo]::CurrentCulture
    try {
        [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
        $ordinalCollisionValues = @(ConvertTo-AffectedOrdinalUniqueStrings @('scripts/I.ps1','scripts/i.ps1','scripts/İ.ps1','scripts/ı.ps1','scripts/I.ps1'))
        Assert-True (($ordinalCollisionValues -join ',') -ceq 'scripts/I.ps1,scripts/i.ps1,scripts/İ.ps1,scripts/ı.ps1') 'Authority-path uniqueness or ordering culture/case-folded distinct ordinal identities.'
    } finally { [Globalization.CultureInfo]::CurrentCulture = $savedOrdinalCulture }

    $ownerGraphFixture = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-owner-graph-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $ownerGraphFixture 'scripts/lib'))
    try {
        $workEnvironmentFixtureSource = @'
& (Join-Path $PSScriptRoot 'Test-Direct.ps1')
$checks = @(
    [pscustomobject]@{ script = 'Test-Table.ps1' },
    [pscustomobject]@{ script = 'Test-Dynamic.ps1' },
    [pscustomobject]@{ script = 'Test-DynamicInvocation.ps1' },
    [pscustomobject]@{ script = 'Test-TypedScriptBlock.ps1' }
)
'@
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-WorkEnvironment.ps1') $workEnvironmentFixtureSource
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-Direct.ps1') "`$modulePath = Join-Path `$PSScriptRoot 'middle.psm1'`nif (`$true) { Import-Module `$modulePath -Force }`n& (Join-Path `$PSScriptRoot 'Test-Nested.ps1')`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-Nested.ps1') ". (Join-Path `$PSScriptRoot 'NestedLeaf.ps1')`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/NestedLeaf.ps1') "Import-Module (Join-Path `$PSScriptRoot 'middle.psm1') -Force`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-Table.ps1') "`$childPath = Join-Path `$PSScriptRoot 'Test-StaticChild.ps1'`n& `$childPath`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-StaticChild.ps1') "Import-Module (Join-Path `$PSScriptRoot 'middle.psm1') -Force`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-Dynamic.ps1') "param([string]`$ModulePath)`nif (`$true) { Import-Module `$ModulePath -Force }`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-DynamicInvocation.ps1') "param([string]`$RunnerPath)`n& `$RunnerPath`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-DynamicTarget.ps1') "Import-Module (Join-Path `$PSScriptRoot 'middle.psm1') -Force`n"
        $typedScriptBlockFixtureSource = "function Invoke-Fixture([scriptblock]`$Action) { & `$Action }`nInvoke-Fixture { 'ok' | Out-Null }`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-TypedScriptBlock.ps1') $typedScriptBlockFixtureSource
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-Unclassified.ps1') "Set-StrictMode -Version 2.0`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/middle.psm1') "if (`$true) { Import-Module (Join-Path `$PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force }`n"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/lib/MorphospaceProtocolCommon.psm1') "Set-StrictMode -Version 2.0`n"
        [void](Invoke-TestGit $ownerGraphFixture @('init','--initial-branch=main'))
        [void](Invoke-TestGit $ownerGraphFixture @('config','user.name','Affected Owner Graph Test'))
        [void](Invoke-TestGit $ownerGraphFixture @('config','user.email','affected-owner-graph@example.invalid'))
        [void](Invoke-TestGit $ownerGraphFixture @('add','.'))
        [void](Invoke-TestGit $ownerGraphFixture @('commit','-m','owner graph fixture'))
        $fixtureTrackedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($trackedPath in @(& git -C $ownerGraphFixture ls-files)) { [void]$fixtureTrackedPaths.Add(([string]$trackedPath).Replace('\','/')) }
        $fixtureOwners = @(Get-AffectedWorkEnvironmentOwnerEntrypoints -Root $ownerGraphFixture -TrackedPaths $fixtureTrackedPaths)
        Assert-True (($fixtureOwners -join ',') -ceq 'scripts/Test-Direct.ps1,scripts/Test-Dynamic.ps1,scripts/Test-DynamicInvocation.ps1,scripts/Test-Table.ps1,scripts/Test-TypedScriptBlock.ps1') 'Owner-entrypoint AST audit did not classify direct and table/list invocations exactly.'
        $scopeFixtureAst = Get-AffectedPowerShellAst (Join-Path $ownerGraphFixture 'scripts/Test-TypedScriptBlock.ps1')
        $scopeFixtureFunction = @($scopeFixtureAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-Fixture' },$true))[0]
        $scopeFixtureParameter = @($scopeFixtureFunction.Parameters)[0]
        $emptyScopeParameters = @(ConvertTo-AffectedParameterAstArray @())
        $mixedScopeParameters = @(ConvertTo-AffectedParameterAstArray @($null,'not-a-parameter',$scopeFixtureParameter))
        Assert-True ($emptyScopeParameters.Count -eq 0) 'Empty function-scope candidate collection did not remain an empty ParameterAst array.'
        Assert-True ($mixedScopeParameters.Count -eq 1 -and $mixedScopeParameters[0] -is [Management.Automation.Language.ParameterAst] -and $mixedScopeParameters[0].StaticType -eq [scriptblock]) 'Mixed function-scope candidates were not filtered to the one typed scriptblock ParameterAst.'
        $fixtureImportDeclaration = [pscustomobject][ordered]@{ importer='scripts/Test-Dynamic.ps1'; variable='ModulePath'; count=1; import_path='scripts/lib/MorphospaceProtocolCommon.psm1' }
        $fixtureInvocationDeclaration = [pscustomobject][ordered]@{ importer='scripts/Test-DynamicInvocation.ps1'; variable='RunnerPath'; count=1; import_paths=@('scripts/Test-DynamicTarget.ps1','scripts/Test-StaticChild.ps1') }
        $fixtureDeclarations = @($fixtureImportDeclaration,$fixtureInvocationDeclaration)
        $fixtureGraphClock = [Diagnostics.Stopwatch]::StartNew()
        $fixtureGraph = New-AffectedTrackedImportGraph -Root $ownerGraphFixture -Entrypoints $fixtureOwners -DynamicImportDeclarations $fixtureDeclarations -TrackedPaths $fixtureTrackedPaths
        $fixtureReachability = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $fixtureDirectClosure = @(Get-AffectedGraphReachability -Graph $fixtureGraph -Entrypoint 'scripts/Test-Direct.ps1' -Cache $fixtureReachability)
        $fixtureTableClosure = @(Get-AffectedGraphReachability -Graph $fixtureGraph -Entrypoint 'scripts/Test-Table.ps1' -Cache $fixtureReachability)
        $fixtureDynamicClosure = @(Get-AffectedGraphReachability -Graph $fixtureGraph -Entrypoint 'scripts/Test-Dynamic.ps1' -Cache $fixtureReachability)
        $fixtureDynamicInvocationClosure = @(Get-AffectedGraphReachability -Graph $fixtureGraph -Entrypoint 'scripts/Test-DynamicInvocation.ps1' -Cache $fixtureReachability)
        $fixtureGraphClock.Stop()
        Assert-True ($fixtureDirectClosure -ccontains 'scripts/middle.psm1' -and $fixtureDirectClosure -ccontains 'scripts/lib/MorphospaceProtocolCommon.psm1') 'Tracked .ps1 -> .psm1 -> .psm1 closure was not derived through conditional/static-variable import syntax.'
        Assert-True ($fixtureDirectClosure -ccontains 'scripts/Test-Nested.ps1' -and $fixtureDirectClosure -ccontains 'scripts/NestedLeaf.ps1') 'Literal invocation and dot-source edges were omitted from transitive closure.'
        Assert-True ($fixtureTableClosure -ccontains 'scripts/Test-StaticChild.ps1') 'Statically bound invocation-variable edge was omitted from transitive closure.'
        Assert-True ($fixtureDynamicClosure -ccontains 'scripts/lib/MorphospaceProtocolCommon.psm1') 'Exact dynamic import declaration did not contribute its tracked edge.'
        Assert-True ($fixtureDynamicInvocationClosure -ccontains 'scripts/Test-DynamicTarget.ps1' -and $fixtureDynamicInvocationClosure -ccontains 'scripts/Test-StaticChild.ps1' -and $fixtureDynamicInvocationClosure -ccontains 'scripts/lib/MorphospaceProtocolCommon.psm1') 'Exact multiple-target dynamic invocation declaration did not retain stable cardinality or contribute every tracked edge.'
        Assert-True ($fixtureDynamicClosure -ccontains 'scripts/lib/MorphospaceProtocolCommon.psm1' -and $fixtureDynamicInvocationClosure.Count -gt $fixtureDynamicClosure.Count) 'StrictMode one-target and multiple-target declaration cardinalities were not both retained as arrays.'
        Assert-True ([long]$fixtureGraphClock.Elapsed.TotalMilliseconds -le 10000) "Fixture import graph and memoized reachability exceeded 10 seconds: $([long]$fixtureGraphClock.Elapsed.TotalMilliseconds)ms."

        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-WorkEnvironment.ps1') ($workEnvironmentFixtureSource + "`n`$unclassified = 'Test-Unclassified.ps1'`n")
        $unclassifiedRejected = $false
        try { [void](Get-AffectedWorkEnvironmentOwnerEntrypoints -Root $ownerGraphFixture -TrackedPaths $fixtureTrackedPaths) } catch { $unclassifiedRejected = $_.Exception.Message -like '*unclassified invocation form*' }
        Assert-True $unclassifiedRejected 'Owner-entrypoint audit accepted an unclassified Test-*.ps1 reference.'
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-WorkEnvironment.ps1') $workEnvironmentFixtureSource

        foreach ($damage in @(
            [pscustomobject]@{ name='absent declaration'; declarations=@() },
            [pscustomobject]@{ name='missing import declaration'; declarations=@($fixtureInvocationDeclaration) },
            [pscustomobject]@{ name='missing invocation declaration'; declarations=@($fixtureImportDeclaration) },
            [pscustomobject]@{ name='wrong variable'; declarations=@($fixtureInvocationDeclaration,[pscustomobject][ordered]@{ importer='scripts/Test-Dynamic.ps1'; variable='OtherPath'; count=1; import_path='scripts/lib/MorphospaceProtocolCommon.psm1' }) },
            [pscustomobject]@{ name='wrong count'; declarations=@($fixtureInvocationDeclaration,[pscustomobject][ordered]@{ importer='scripts/Test-Dynamic.ps1'; variable='ModulePath'; count=2; import_path='scripts/lib/MorphospaceProtocolCommon.psm1' }) },
            [pscustomobject]@{ name='wrong target'; declarations=@($fixtureInvocationDeclaration,[pscustomobject][ordered]@{ importer='scripts/Test-Dynamic.ps1'; variable='ModulePath'; count=1; import_path='scripts/missing.psm1' }) },
            [pscustomobject]@{ name='duplicate declaration'; declarations=@(
                $fixtureInvocationDeclaration,$fixtureImportDeclaration,
                [pscustomobject][ordered]@{ importer='scripts/Test-Dynamic.ps1'; variable='ModulePath'; count=1; import_path='scripts/lib/MorphospaceProtocolCommon.psm1' }
            ) }
        )) {
            $damageRejected = $false
            try { [void](New-AffectedTrackedImportGraph -Root $ownerGraphFixture -Entrypoints $fixtureOwners -DynamicImportDeclarations @($damage.declarations) -TrackedPaths $fixtureTrackedPaths) } catch { $damageRejected = $true }
            Assert-True $damageRejected "Owner import graph accepted dynamic-import damage '$($damage.name)'."
        }
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-TypedScriptBlock.ps1') "function Invoke-Fixture(`$Action) { & `$Action }`nInvoke-Fixture { 'not-a-path' | Out-Null }`n"
        $untypedInvocationRejected = $false
        $untypedInvocationReason = $null
        try { [void](New-AffectedTrackedImportGraph -Root $ownerGraphFixture -Entrypoints $fixtureOwners -DynamicImportDeclarations $fixtureDeclarations -TrackedPaths $fixtureTrackedPaths) } catch {
            $untypedInvocationReason = [string]$_.Exception.Message
            $untypedInvocationRejected =
                ($untypedInvocationReason -ceq 'Dynamic owner invocation lacks an exact declaration: scripts/Test-TypedScriptBlock.ps1|Action') -or
                ($untypedInvocationReason -ceq 'Dynamic owner invocation does not contain one exact callable variable: scripts/Test-TypedScriptBlock.ps1 :: & $Action')
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($untypedInvocationReason)) 'Untyped dynamic invocation damage did not preserve its caught rejection reason.'
        Assert-True $untypedInvocationRejected 'Untyped dynamically bound invocation was exempted as a non-path callable.'
        Write-Host "Untyped dynamic invocation rejected: $untypedInvocationReason"
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-TypedScriptBlock.ps1') $typedScriptBlockFixtureSource
        $savedGraphCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-Direct.ps1') "Import-Module @((Join-Path `$PSScriptRoot 'middle.psm1'),(Join-Path `$PSScriptRoot 'MIDDLE.psm1')) -Force`n"
            $caseCollisionRejected = $false
            try { [void](New-AffectedTrackedImportGraph -Root $ownerGraphFixture -Entrypoints $fixtureOwners -DynamicImportDeclarations $fixtureDeclarations -TrackedPaths $fixtureTrackedPaths) } catch { $caseCollisionRejected = $_.Exception.Message -like '*multiple literal tracked-script candidates*' }
            Assert-True $caseCollisionRejected 'Owner import graph culture/case-folded distinct literal script candidates before cardinality rejection.'
        } finally { [Globalization.CultureInfo]::CurrentCulture = $savedGraphCulture }
        Write-Utf8 (Join-Path $ownerGraphFixture 'scripts/Test-Direct.ps1') "Import-Module (Join-Path `$PSScriptRoot 'absent.psm1') -Force`n"
        $missingStaticRejected = $false
        try { [void](New-AffectedTrackedImportGraph -Root $ownerGraphFixture -Entrypoints $fixtureOwners -DynamicImportDeclarations $fixtureDeclarations -TrackedPaths $fixtureTrackedPaths) } catch { $missingStaticRejected = $_.Exception.Message -like '*absent or untracked*' }
        Assert-True $missingStaticRejected 'Owner import graph accepted a missing tracked static edge.'
    } finally {
        if ([IO.Directory]::Exists($ownerGraphFixture)) { Remove-Item -LiteralPath $ownerGraphFixture -Recurse -Force }
    }
}

if ($runFullSelector -or $runExecutorPassPhase) {
    $workflowSource = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/validate.yml') -Raw
    $workflowContractsSource = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Test-WorkflowContracts.ps1') -Raw
    $executorSource = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -Raw
    $phaseRunnerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Invoke-AffectedValidationSelfTestPhase.ps1') -Raw
    $phaseReceiptSchema = Read-MorphospaceProtocolJson -Path (Join-Path $repoRoot 'schemas/affected-validation-self-test-phase-receipt-v1.schema.json')
    $phaseProjectionSchema = Read-MorphospaceProtocolJson -Path (Join-Path $repoRoot 'schemas/affected-validation-self-test-dependency-projection-v1.schema.json')
    $checkEvidenceSchema = Read-MorphospaceProtocolJson -Path (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json')
    $phaseRunnerSchema = $phaseReceiptSchema.properties.binding.properties.runner
    $expectedPhaseIds = @('dependency-closure','executor-descendant-containment-damage','executor-dual-stream-damage','executor-forged-terminal-damage','executor-native-exit125-damage','executor-native-failure-damage','executor-output-ceiling-damage','executor-parent-containment-damage','executor-pass-schema','executor-publication-collision-damage','executor-source-integrity-damage','executor-timeout-damage','graph-import-closure','selection-scenarios','trust-damage-final','trust-proportional-mappings','trust-routing-contracts','trust-self-executor')
    $topLevelPhaseIds = @($phaseReceiptSchema.properties.phase_id.enum)
    $bindingPhaseIds = @($phaseReceiptSchema.properties.binding.properties.phase_id.enum)
    [Array]::Sort($topLevelPhaseIds,[StringComparer]::Ordinal)
    [Array]::Sort($bindingPhaseIds,[StringComparer]::Ordinal)
    Assert-True (($topLevelPhaseIds -join ',') -ceq ($expectedPhaseIds -join ',') -and ($bindingPhaseIds -join ',') -ceq ($expectedPhaseIds -join ',')) 'Affected phase receipt schema does not exactly match the runner phase set.'
    $requiredRunnerFields = @('git_executable_sha256','git_version','os_description','powershell_executable_sha256','powershell_version','process_architecture')
    $observedRunnerFields = @($phaseRunnerSchema.required)
    [Array]::Sort($observedRunnerFields,[StringComparer]::Ordinal)
    Assert-True (@($phaseReceiptSchema.properties.binding.required) -ccontains 'runner' -and ($observedRunnerFields -join ',') -ceq ($requiredRunnerFields -join ',')) 'Affected phase schema does not require the exact closed runner identity.'
    Assert-True ([int]$phaseReceiptSchema.properties.binding.properties.dependency_manifest.maxItems -eq 2048 -and [int]$phaseProjectionSchema.properties.dependency_manifest.maxItems -eq 2048) 'Affected phase schemas do not share the bounded outer dependency-manifest capacity.'
    $phaseManifestCanonicalUpperBound = ([long]2048 * (([long]4096 * 12) + 256)) + 1048576
    Assert-True ([long]$checkEvidenceSchema.'$defs'.artifact.properties.bytes.maximum -eq 134217728 -and [long]$checkEvidenceSchema.'$defs'.artifact.properties.bytes.maximum -gt $phaseManifestCanonicalUpperBound -and [int]$checkEvidenceSchema.'$defs'.artifact.allOf[0].else.properties.bytes.maximum -eq 10485760) 'Outer evidence does not cover the maximum escaped-Unicode phase receipt domain while retaining the ordinary artifact ceiling.'
    Assert-True (@($checkEvidenceSchema.required) -ccontains 'plan_sha256') 'Affected check evidence does not retain the original plan identity required by inner phase artifacts.'
    Assert-True ($phaseRunnerSource.Contains('$startInfo.Environment.Clear()') -and $phaseRunnerSource.Contains('$phaseChildEnvironment') -and -not $phaseRunnerSource.Contains("Environment.Remove('GIT_PAGER')")) 'Affected phase runner does not rebuild its second-hop child from the closed projection.'
    Assert-True ($workflowContractsSource.Contains('$start.Environment.Clear()') -and $workflowContractsSource.Contains("`$runtimeNames=@('COMSPEC','HOME','PATH','PATHEXT','SYSTEMROOT','TEMP','TMP','TMPDIR','WINDIR')") -and $workflowContractsSource.Contains("@('GIT_PAGER','WEF002_UNOWNED_MARKER','PSExecutionPolicyPreference','PSModulePath')") -and $workflowContractsSource.Contains('$process.StandardOutput.BaseStream.ReadAsync') -and $workflowContractsSource.Contains('$process.StandardError.BaseStream.ReadAsync') -and $workflowContractsSource.Contains('$stdout.Length+$stderr.Length-gt10485760') -and $workflowContractsSource.Contains("if(`$StandardDeltaOnly)") -and $workflowContractsSource.Contains("-TimeoutSeconds 900") -and $workflowContractsSource.Contains('[void](Invoke-IsolatedWorkflowSelfTest -Path (Join-Path $RepoRoot "scripts\$selfTest"))') -and -not $workflowContractsSource.Contains('[Environment]::SetEnvironmentVariable') -and -not $workflowContractsSource.Contains('Get-ChildItem Env:') -and -not $workflowContractsSource.Contains('Remove-Item -LiteralPath "Env:')) 'Workflow-contract owner/Standard launcher does not retain one closed, bounded, nonrecursive child environment path.'
    Assert-True (@($checkEvidenceSchema.required) -ccontains 'environment' -and @($checkEvidenceSchema.properties.child.required) -ccontains 'failure_kind') 'Affected check evidence does not bind the closed child environment and typed failure distinction.'
    $trackedPowerShellPattern = [string]$checkEvidenceSchema.'$defs'.trackedPowerShellPath.pattern
    $declarationScriptPattern = [string]$checkEvidenceSchema.'$defs'.scriptPath.pattern
    Assert-True ([string]$checkEvidenceSchema.'$defs'.dependencyResolution.properties.entrypoint.'$ref' -ceq '#/$defs/trackedPowerShellPath' -and [string]$checkEvidenceSchema.'$defs'.dependencyResolution.properties.fallback_reasons.items.properties.importer.'$ref' -ceq '#/$defs/trackedPowerShellPath' -and $trackedPowerShellPattern.StartsWith('^(?:scripts|tools)/',[StringComparison]::Ordinal) -and $trackedPowerShellPattern.Replace('^(?:scripts|tools)/','^scripts/') -ceq $declarationScriptPattern) 'Affected check evidence does not distinguish tracked script/tool closure paths from scripts-only dynamic declarations.'
    foreach ($manifestSchema in @($phaseReceiptSchema.properties.binding.properties.dependency_manifest.items,$phaseProjectionSchema.'$defs'.manifestRecord)) {
        $manifestFields=@($manifestSchema.required);[Array]::Sort($manifestFields,[StringComparer]::Ordinal)
        Assert-True (($manifestFields -join ',') -ceq 'blob,mode,path') 'Affected phase dependency manifest does not retain the exact outer tree-record shape.'
    }
    Assert-True ($phaseRunnerSource -match 'function Get-RunnerBinding' -and $phaseRunnerSource -match 'powershell_executable_sha256=Get-Sha256' -and $phaseRunnerSource -match 'git_executable_sha256=Get-Sha256' -and $phaseRunnerSource -match 'phase_id=\$PhaseId;runner=\$Runner;dependency_manifest=') 'Affected phase runner does not bind exact PowerShell/Git executable identities into phase reuse.'
    Assert-True ($phaseRunnerSource -match 'function Assert-ReusableBinding' -and $phaseRunnerSource -match 'merge-base --is-ancestor' -and $phaseRunnerSource -match 'changed the exact runner identity' -and $phaseRunnerSource -match 'changed the exact dependency manifest' -and $phaseRunnerSource -match 'source tree is invalid') 'Affected phase verifier does not retain the closed ancestor-source compatibility boundary.'
    Assert-True ($phaseRunnerSource -notmatch [regex]::Escape("Import-Module (Join-Path `$PSScriptRoot 'lib/MorphospaceAffectedValidationCheckEvidence.psm1') -Force") -and $phaseRunnerSource -notmatch 'Get-MorphospaceAffectedCheckDependencyClosure' -and $phaseRunnerSource -match 'function Read-DependencyProjectionFile' -and $phaseRunnerSource -match 'function Get-DependencyProjection' -and $phaseRunnerSource -match 'Assert-MorphospaceAffectedBatchedWorkingBytes') 'Affected phase runner re-analyzes dependency closure or omits validation of its parent-projected closure.'
    Assert-True ($executorSource -match 'function New-AffectedValidationDependencyProjectionFile' -and $executorSource -match 'RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_PATH' -and $executorSource -match 'RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_SHA256' -and $executorSource -match 'FileShare\]::Read' -and $executorSource -match 'DependencyManifest @\(\$binding\.dependency_manifest\)') 'Affected executor does not publish and project its exact parent-held dependency closure to phase children.'
    Assert-True ($executorSource -match '\.rusty-affected-dependency-projection-.*\$PID' -and $executorSource -match 'projectionCleanupError' -and $executorSource -match 'publicationCleanupError' -and $executorSource -match 'publication failed and cleanup did not complete' -and $executorSource -match 'dependency projection file cleanup failed' -and $executorSource -match 'Remove-Item -LiteralPath (?:\$path|\(\[string\]\$dependencyProjectionFile\.path\)) -Force -ErrorAction Stop') 'Affected executor does not use an owner-identifiable projection path or fail closed on projection cleanup at both publication and post-child boundaries.'
    Assert-True ($executorSource -match 'function Get-AffectedValidationDependencyProjectionIOException' -and $executorSource -match 'function Test-AffectedValidationDependencyProjectionSharingViolation' -and $executorSource -match 'function Read-AffectedValidationDependencyProjectionFile' -and $executorSource -match '\[Diagnostics\.Stopwatch\]::StartNew\(\)' -and $executorSource -match 'Platform -ceq ''windows''.*@\(32,33\) -ccontains \$NativeCode' -and $executorSource -match 'Platform -ceq ''linux''.*NativeCode -eq 11' -and $executorSource -match '\[OperatingSystem\]::IsWindows\(\)' -and $executorSource -match '\[OperatingSystem\]::IsLinux\(\)' -and $executorSource -match '\$remainingMilliseconds = \[long\]\$SharingRetryMilliseconds - \[long\]\$retryClock\.ElapsedMilliseconds' -and $executorSource -match '\[Math\]::Min\(10,\[int\]\$remainingMilliseconds\)' -and $executorSource -match 'sharing-locked after bounded \$\{SharingRetryMilliseconds\}ms post-child readback' -and $executorSource -match '\$dependencyProjectionFile\.stream\.Dispose\(\); \$dependencyProjectionFile\.stream = \$null' -and $executorSource -match 'Read-AffectedValidationDependencyProjectionFile -Path') 'Affected executor does not close its publisher handle and use a cross-platform monotonic bounded sharing-aware post-child projection readback.'
    $innerHandleLauncher=[regex]::Match($executorSource,'(?s)private static bool CreateProcessAsUser\(.*?\n    \}\r?\n    private static LuidAttributes').Value
    $expectedHandleWrites='Marshal.WriteIntPtr(handles,0,stdinRead);Marshal.WriteIntPtr(handles,IntPtr.Size,startup.stdout);Marshal.WriteIntPtr(handles,IntPtr.Size*2,startup.stderr);'
    Assert-True (-not[string]::IsNullOrWhiteSpace($innerHandleLauncher) -and ([regex]::Matches($innerHandleLauncher,'Marshal\.WriteIntPtr\(handles,')).Count -eq 3 -and $innerHandleLauncher.Contains('handles=Marshal.AllocHGlobal(IntPtr.Size*3);'+$expectedHandleWrites) -and $innerHandleLauncher.Contains('startup.stdin=stdinRead;') -and $innerHandleLauncher.Contains('CloseHandle(stdinWrite)') -and $innerHandleLauncher.Contains('new IntPtr(0x00020002),handles,new UIntPtr(unchecked((uint)(IntPtr.Size*3)))') -and $innerHandleLauncher.Contains('CreateProcessAsUserNative(token,application,command,processAttributes,threadAttributes,true,flags|ExtendedStartupInfoPresent') -and $innerHandleLauncher.Contains('DeleteProcThreadAttributeList(list)')) 'Windows inner launch does not restrict STARTUPINFOEX inheritance to exact EOF stdin, stdout, and stderr handles in that order.'
    Assert-True (([regex]::Matches($executorSource,'CreateProcessAsUser\(restrictedToken,executable,command,IntPtr\.Zero,IntPtr\.Zero,true,suspended\|noWindow')).Count -eq 1) 'Windows inner launch does not request the explicit three-handle inheritance wrapper exactly once.'
    $executorAst = [Management.Automation.Language.Parser]::ParseInput($executorSource,[ref]$null,[ref]$null)
    $projectionIoFunction = @($executorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-AffectedValidationDependencyProjectionIOException' },$true))
    $projectionSharingFunction = @($executorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-AffectedValidationDependencyProjectionSharingViolation' },$true))
    $projectionReadFunction = @($executorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-AffectedValidationDependencyProjectionFile' },$true))
    Assert-True ($projectionIoFunction.Count -eq 1 -and $projectionSharingFunction.Count -eq 1) 'Affected executor does not define exactly one closed sharing-exception classifier pair.'
    Assert-True ($projectionReadFunction.Count -eq 1) 'Affected executor does not define exactly one dependency-projection readback function.'
    . ([scriptblock]::Create([string]$projectionIoFunction[0].Extent.Text))
    . ([scriptblock]::Create([string]$projectionSharingFunction[0].Extent.Text))
    . ([scriptblock]::Create([string]$projectionReadFunction[0].Extent.Text))
    $innerProjectionIoException = [IO.IOException]::new('inner sharing failure')
    $wrappedProjectionIoException = [Exception]::new('PowerShell invocation wrapper',$innerProjectionIoException)
    Assert-True ([object]::ReferenceEquals((Get-AffectedValidationDependencyProjectionIOException -Exception $wrappedProjectionIoException),$innerProjectionIoException)) 'Affected dependency-projection readback does not unwrap a genuine nested IOException.'
    Assert-True ($null -eq (Get-AffectedValidationDependencyProjectionIOException -Exception ([Exception]::new('not I/O')))) 'Affected dependency-projection readback classified a non-I/O exception as retryable.'
    Assert-True ((Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 32 -Platform windows) -and (Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 33 -Platform windows) -and -not (Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 11 -Platform windows) -and -not (Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 13 -Platform windows)) 'Affected dependency-projection Windows sharing classifier is not closed to sharing/lock violations.'
    Assert-True ((Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 11 -Platform linux) -and -not (Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 32 -Platform linux) -and -not (Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 33 -Platform linux) -and -not (Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 13 -Platform linux)) 'Affected dependency-projection Linux sharing classifier is not closed to EAGAIN/EWOULDBLOCK.'
    Assert-True (-not (Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 11 -Platform unsupported)) 'Affected dependency-projection sharing classifier retries on an unsupported platform.'
    Assert-AffectedThrows { Test-AffectedValidationDependencyProjectionSharingViolation -NativeCode 11 -Platform invalid } '*sharing platform is invalid*' 'Affected dependency-projection sharing classifier accepted an unknown platform.'
    $projectionReadbackFixture = Join-Path ([IO.Path]::GetTempPath()) ('.rusty-affected-dependency-projection-readback-test-' + [Guid]::NewGuid().ToString('N') + '.json')
    [byte[]]$projectionReadbackBytes = [Text.UTF8Encoding]::new($false).GetBytes("projection-readback`n")
    [IO.File]::WriteAllBytes($projectionReadbackFixture,$projectionReadbackBytes)
    try {
        $projectionLock = [IO.FileStream]::new($projectionReadbackFixture,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $projectionLockClock = [Diagnostics.Stopwatch]::StartNew()
        try {
            Assert-AffectedThrows { Read-AffectedValidationDependencyProjectionFile -Path $projectionReadbackFixture -ExpectedLength $projectionReadbackBytes.Length -SharingRetryMilliseconds 30 } '*remained sharing-locked after bounded 30ms post-child readback*' 'Affected dependency-projection readback did not fail closed after its finite sharing retry bound.'
        } finally { $projectionLockClock.Stop(); $projectionLock.Dispose() }
        Assert-True ($projectionLockClock.ElapsedMilliseconds -le 1000) "Affected dependency-projection sharing-lock rejection exceeded its practical bounded tolerance: $($projectionLockClock.ElapsedMilliseconds)ms."
        [byte[]]$projectionReadback = Read-AffectedValidationDependencyProjectionFile -Path $projectionReadbackFixture -ExpectedLength $projectionReadbackBytes.Length -SharingRetryMilliseconds 30
        Assert-True ((Get-MorphospaceAffectedCheckBytesSha256 $projectionReadback) -ceq (Get-MorphospaceAffectedCheckBytesSha256 $projectionReadbackBytes)) 'Affected dependency-projection readback changed bytes after sharing-lock release.'
        Assert-AffectedThrows { Read-AffectedValidationDependencyProjectionFile -Path $projectionReadbackFixture -ExpectedLength ($projectionReadbackBytes.Length+1) -SharingRetryMilliseconds 30 } '*byte length changed*' 'Affected dependency-projection readback accepted an unexpected byte length.'
    } finally {
        if ([IO.File]::Exists($projectionReadbackFixture)) { Remove-Item -LiteralPath $projectionReadbackFixture -Force }
    }
    $checkEvidenceSource = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/lib/MorphospaceAffectedValidationCheckEvidence.psm1') -Raw
    Assert-True ($checkEvidenceSource -match '\(\?:start\|terminal\)' -and $checkEvidenceSource -match '134217728' -and $checkEvidenceSource -match '10485760') 'Affected evidence implementation does not align maximum-domain phase receipts with the ordinary artifact bound.'
    Assert-True ($executorSource -match 'function Get-AffectedValidationDependencyClosureCacheKey' -and $executorSource -match '\$dependencyClosuresByInput\.ContainsKey\(\$dependencyClosureKey\)' -and $executorSource -match 'head_tree=\[string\]\$plan\.head\.tree' -and $executorSource -match 'registry_sha256=\[string\]\$registrySha256') 'Affected executor does not reuse exact identical closure inputs inside one bounded process.'
    Assert-True ($phaseRunnerSource -notmatch '(?m)^\$dependencyPaths\s*=\s*@\(') 'Affected phase runner retains a manually enumerated dependency manifest.'
    $phaseCompiledRegistry = Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $repoRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json')
    $phaseHead = (& git -C $repoRoot rev-parse HEAD).Trim()
    $phaseTree = (& git -C $repoRoot rev-parse 'HEAD^{tree}').Trim()
    $phaseInventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $repoRoot -Commit $phaseHead
    foreach($trustCheckId in $selectorTrustRootCheckIds){
        Assert-True ([string]$phaseCompiledRegistry.checks[$trustCheckId].cache_policy -ceq 'exact-host') "Deterministic selector trust check '$trustCheckId' is not eligible for exact-host reuse."
    }
    $selectorPhaseCheckIds=@('affected-selector-graph-import-closure','affected-selector-dependency-closure','affected-selector-executor-pass-schema','affected-selector-executor-native-failure-damage','affected-selector-executor-native-exit125-damage','affected-selector-executor-forged-terminal-damage','affected-selector-executor-parent-containment-damage','affected-selector-executor-descendant-containment-damage','affected-selector-executor-output-ceiling-damage','affected-selector-executor-timeout-damage','affected-selector-executor-dual-stream-damage','affected-selector-executor-source-integrity-damage','affected-selector-executor-publication-collision-damage','affected-selector-selection-scenarios','affected-selector-trust-self-executor','affected-selector-trust-routing-contracts','affected-selector-trust-proportional-mappings','affected-selector-trust-damage-final','affected-selector-selftest')
    $phaseDependencyInput=$null
    foreach($phaseCheckId in $selectorPhaseCheckIds){
        $phaseCheck=$phaseCompiledRegistry.checks[$phaseCheckId]
        Assert-True ($null-ne$phaseCheck) "Affected phase registry omits '$phaseCheckId'."
        $candidateInput=Get-MorphospaceCanonicalJsonSha256 -Value ([pscustomobject][ordered]@{command_path=[string]$phaseCheck.command_path;consume_path_sets=@($phaseCheck.consume_path_sets|ForEach-Object{[string]$_})})
        if($null-eq$phaseDependencyInput){$phaseDependencyInput=$candidateInput}else{Assert-True ($candidateInput-ceq$phaseDependencyInput) "Affected phase '$phaseCheckId' does not share the exact projected closure input."}
    }
    $executorPassCheck=$phaseCompiledRegistry.checks['affected-selector-executor-pass-schema']
    $executorPassBudgetIndex=[array]::IndexOf(@($executorPassCheck.arguments),'-BudgetSeconds')
    $executorPassInnerBudget=0
    Assert-True ($executorPassBudgetIndex-ge0-and$executorPassBudgetIndex+1-lt@($executorPassCheck.arguments).Count-and[int]::TryParse([string]$executorPassCheck.arguments[$executorPassBudgetIndex+1],[ref]$executorPassInnerBudget)-and$executorPassInnerBudget-ge180-and[long]$executorPassCheck.budget_seconds-ge[long]$executorPassInnerBudget+15) 'Executor pass/schema phase lacks its measured hosted-Linux budget and bounded 15-second containment headroom.'
    $derivedPhaseManifest=@($phaseInventory.records | Where-Object { [string]$_.type -ceq 'blob' -and @('100644','100755') -ccontains [string]$_.mode } | Select-Object -First 24 | ForEach-Object { [pscustomobject][ordered]@{path=[string]$_.path;mode=[string]$_.mode;blob=[string]$_.blob} })
    Assert-True ($derivedPhaseManifest.Count -gt 16 -and $derivedPhaseManifest.Count -le 2048) 'Representative exact-head phase closure does not fit the closed bounded phase-manifest domain.'
    $derivedProjection=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_self_test_dependency_projection.v1';repository='MesmerPrism/rusty-morphospace-work-environment';head_commit=$phaseHead;head_tree=$phaseTree;registry_sha256=Get-MorphospaceCanonicalJsonSha256 -Value $registry;check_id='affected-selector-executor-pass-schema';command_path='scripts/Invoke-AffectedValidationSelfTestPhase.ps1';consume_path_sets=@($phaseCompiledRegistry.checks['affected-selector-executor-pass-schema'].consume_path_sets);dependency_manifest=$derivedPhaseManifest}
    Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $derivedProjection) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-self-test-dependency-projection-v1.schema.json') -ErrorAction Stop) 'Representative exact-head dependency projection does not validate through its closed schema.'
    $derivedPhaseRunner = [pscustomobject][ordered]@{os_description='schema-positive';process_architecture='x64';powershell_version='7.5.0';powershell_executable_sha256=('b'*64);git_version='git version 2.50.0';git_executable_sha256=('c'*64)}
    $derivedPhaseBinding = [pscustomobject][ordered]@{repository='MesmerPrism/rusty-morphospace-work-environment';base_commit=$phaseHead;head_commit=$phaseHead;head_tree=$phaseTree;plan_sha256=('d'*64);platform='linux';check_id='affected-selector-executor-pass-schema';phase_id='executor-pass-schema';runner=$derivedPhaseRunner;dependency_manifest=$derivedPhaseManifest}
    $derivedPhaseTerminal = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_self_test_phase_receipt.v1';phase_id='executor-pass-schema';binding=$derivedPhaseBinding;binding_sha256=Get-MorphospaceCanonicalJsonSha256 -Value $derivedPhaseBinding;started_at='2026-09-01T00:00:00Z';ended_at='2026-09-01T00:00:01Z';budget_seconds=60;elapsed_ms=1000;result='pass';child=[pscustomobject][ordered]@{started=$true;exit_code=0;timed_out=$false;post_kill_drain_timed_out=$false;stdout=[pscustomobject][ordered]@{path='executor-pass-schema.stdout.bin';bytes=0;sha256=('e'*64)};stderr=[pscustomobject][ordered]@{path='executor-pass-schema.stderr.bin';bytes=0;sha256=('e'*64)}};outputs=@();claims=[pscustomobject][ordered]@{phase_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}}
    Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $derivedPhaseTerminal) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-self-test-phase-receipt-v1.schema.json') -ErrorAction Stop) 'Actual registry-derived phase manifest does not validate through the closed phase receipt schema.'
    $bindingCompatibilityOutput = @(& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidationSelfTestPhase.ps1') -BindingSelfTest)
    Assert-True (@($bindingCompatibilityOutput | Where-Object { [string]$_ -ceq 'Affected-validation phase ancestor-binding compatibility self-test passed.' }).Count -eq 1) 'Affected phase ancestor-binding positive/damage self-test did not pass exactly once.'
    $hostedActionPins = @{
        'actions/checkout'='3d3c42e5aac5ba805825da76410c181273ba90b1'
        'actions/upload-artifact'='043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
        'actions/download-artifact'='3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'
        'actions/cache/restore'='55cc8345863c7cc4c66a329aec7e433d2d1c52a9'
        'actions/cache/save'='55cc8345863c7cc4c66a329aec7e433d2d1c52a9'
    }
    $hostedActionUses = @([regex]::Matches($workflowSource,'(?m)^\s+-?\s*uses:\s+(?<action>actions/[a-z0-9-]+(?:/[a-z0-9-]+)?)@(?<commit>[0-9a-f]{40})\s*$'))
    Assert-True ($hostedActionUses.Count -gt 0) 'Workflow contains no immutable hosted action references.'
    foreach($use in $hostedActionUses){
        $action=[string]$use.Groups['action'].Value
        $commit=[string]$use.Groups['commit'].Value
        Assert-True ($hostedActionPins.ContainsKey($action) -and [string]$hostedActionPins[$action] -ceq $commit) "Workflow action '$action@$commit' is outside the exact Node 24 action set."
    }
    foreach($action in $hostedActionPins.Keys){ Assert-True (@($hostedActionUses | Where-Object { [string]$_.Groups['action'].Value -ceq $action }).Count -gt 0) "Workflow does not exercise the pinned '$action' action." }
    $workflowJobs = @{}
    foreach ($match in [regex]::Matches($workflowSource, '(?ms)^  (?<id>[a-z0-9-]+):\r?\n(?<body>.*?)(?=^  [a-z0-9-]+:|\z)')) { $workflowJobs[[string]$match.Groups['id'].Value] = [string]$match.Groups['body'].Value }
    $assertPreEvidenceFailureContract = {
        param([string]$JobBody,[string]$Platform)
        $label = [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($Platform)
        foreach ($required in @(
            '$capturedExecutorFailure = $null -ne $failure',
            'rusty.morphospace.diagnostic.affected_validation_pre_evidence_failure.v1',
            "platform='$Platform'",
            '[IO.FileMode]::CreateNew',
            '$diagnosticBytes.Length -gt 65536',
            'captured_executor_exception=$capturedExecutorFailure',
            'fully_qualified_error_id=& $bounded $failure.FullyQualifiedErrorId',
            '$errorDetails = $failure.ErrorDetails',
            "error_details=if (`$null -eq `$errorDetails) { '' } else { & `$bounded `$errorDetails.Message }",
            '$invocationInfo = $failure.InvocationInfo',
            "position_message=if (`$null -eq `$invocationInfo) { '' } else { & `$bounded `$invocationInfo.PositionMessage }",
            'script_stack_trace=& $bounded $failure.ScriptStackTrace',
            '"pre_evidence_failure=true" | Add-Content -LiteralPath $env:GITHUB_OUTPUT',
            "name: affected-pre-evidence-`${{ matrix.segment_id }}-`${{ github.sha }}-`${{ github.run_attempt }}",
            "path: `${{ runner.temp }}/pre-evidence-`${{ matrix.segment_id }}.json",
            "steps.execute.outputs.pre_evidence_failure == 'true'",
            "steps.execute.outputs.evidence_ready == 'true'"
        )) {
            if (-not $JobBody.Contains($required)) { throw "Workflow $Platform segment pre-evidence contract is missing '$required'." }
        }
        $orderedTokens = @(
            'if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf))',
            '$capturedExecutorFailure = $null -ne $failure',
            "[InvalidOperationException]::new('Affected $label segment returned without producing typed evidence.')",
            'rusty.morphospace.diagnostic.affected_validation_pre_evidence_failure.v1',
            '"pre_evidence_failure=true" | Add-Content -LiteralPath $env:GITHUB_OUTPUT',
            'throw $failure',
            '"evidence_ready=true" | Add-Content -LiteralPath $env:GITHUB_OUTPUT',
            '"evidence_sha256=$((Get-FileHash'
        )
        $cursor = 0
        foreach ($token in $orderedTokens) {
            $index = $JobBody.IndexOf($token,$cursor,[StringComparison]::Ordinal)
            if ($index -lt 0) { throw "Workflow $Platform segment can mask a captured executor exception or bind successful evidence out of order at '$token'." }
            $cursor = $index + $token.Length
        }
    }
    foreach ($requiredContext in @('quick-linux','quick-windows','standard-windows')) { Assert-True $workflowJobs.ContainsKey($requiredContext) "PR workflow lacks the required '$requiredContext' context." }
    foreach ($segmentJobId in @('affected-linux-segments','affected-windows-segments','main-linux-segments','main-windows-segments')) { Assert-True $workflowJobs.ContainsKey($segmentJobId) "Workflow lacks the required '$segmentJobId' segmented execution job." }
    foreach ($selectedContext in @(
        @{ id = 'quick-linux'; selected = 'LINUX_SELECTED'; segment_result = 'SEGMENT_RESULT'; segment_job = 'affected-linux-segments'; platform = 'linux' },
        @{ id = 'standard-windows'; selected = 'WINDOWS_SELECTED'; segment_result = 'SEGMENT_RESULT'; segment_job = 'affected-windows-segments'; platform = 'windows' }
    )) {
        $body = [string]$workflowJobs[[string]$selectedContext.id]
        Assert-True ($body -match "(?m)^    needs: \[infrastructure, select, $([regex]::Escape([string]$selectedContext.segment_job))\]$" -and $body -match "\`$env:$($selectedContext.selected) -cnotin @\('true','false'\)" -and $body -match "\`$env:$($selectedContext.selected) -ceq 'true'.*\`$env:$($selectedContext.segment_result) -cne 'success'") "Required '$($selectedContext.id)' context does not close its platform-selection and segment-result domains."
        Assert-True ($body -match "\`$env:INFRA_RESULT -cne 'success'" -and $body -match "\`$env:SELECT_RESULT -cne 'success'") "Required '$($selectedContext.id)' context can bypass failed selection prerequisites."
        foreach ($selectionValue in @('', 'unexpected')) {
            $rejected = $false
            try { Invoke-WorkflowSelectionGate -JobBody $body -SelectionVariable ([string]$selectedContext.selected) -SelectionValue $selectionValue -SegmentResultVariable ([string]$selectedContext.segment_result) } catch { $rejected = $_.Exception.Message -like '*must be exactly true or false*' }
            Assert-True $rejected "Required '$($selectedContext.id)' context accepted '$selectionValue' as a platform selection."
        }
        Invoke-WorkflowSelectionGate -JobBody $body -SelectionVariable ([string]$selectedContext.selected) -SelectionValue 'true' -SegmentResultVariable ([string]$selectedContext.segment_result)
        Invoke-WorkflowSelectionGate -JobBody $body -SelectionVariable ([string]$selectedContext.selected) -SelectionValue 'false' -SegmentResultVariable ([string]$selectedContext.segment_result)
        $segmentBody = [string]$workflowJobs[[string]$selectedContext.segment_job]
        & $assertPreEvidenceFailureContract $segmentBody ([string]$selectedContext.platform)
        Assert-AffectedThrows { & $assertPreEvidenceFailureContract ($segmentBody.Replace('[IO.FileMode]::CreateNew','[IO.FileMode]::Create')) ([string]$selectedContext.platform) } '*CreateNew*' "Workflow '$($selectedContext.segment_job)' damage test accepted overwrite-capable diagnostic publication."
        Assert-AffectedThrows { & $assertPreEvidenceFailureContract ($segmentBody.Replace('$capturedExecutorFailure = $null -ne $failure','$capturedExecutorFailure = $false')) ([string]$selectedContext.platform) } '*capturedExecutorFailure*' "Workflow '$($selectedContext.segment_job)' damage test accepted loss of captured-exception classification."
        Assert-AffectedThrows { & $assertPreEvidenceFailureContract ($segmentBody.Replace('throw $failure','throw ''masked failure''')) ([string]$selectedContext.platform) } '*mask a captured executor exception*' "Workflow '$($selectedContext.segment_job)' damage test accepted captured-exception replacement."
        Assert-AffectedThrows { & $assertPreEvidenceFailureContract ($segmentBody.Replace('$diagnosticBytes.Length -gt 65536','$diagnosticBytes.Length -gt 65537')) ([string]$selectedContext.platform) } '*65536*' "Workflow '$($selectedContext.segment_job)' damage test accepted a widened diagnostic byte ceiling."
        Assert-True ($segmentBody.Contains('name: segment-${{ matrix.segment_id }}') -and $segmentBody.Contains("matrix: `${{ fromJSON(needs.select.outputs.$($selectedContext.platform)_matrix) }}") -and $segmentBody.Contains('-SegmentId $env:SEGMENT_ID')) "Workflow '$($selectedContext.segment_job)' does not execute the deterministic $($selectedContext.platform) segment matrix."
        Assert-True ($segmentBody.Contains('affected-checks-${{ matrix.segment_id }}-') -and $segmentBody.Contains('affected-check-${{ matrix.segment_id }}-pr-')) "Workflow '$($selectedContext.segment_job)' does not preserve segment-scoped exact-check streams and caches."
        $digestIndex = $segmentBody.IndexOf('"evidence_sha256=$((Get-FileHash', [StringComparison]::Ordinal)
        $throwIndex = $segmentBody.IndexOf('if ($null -ne $failure) { throw $failure }', [StringComparison]::Ordinal)
        Assert-True ($segmentBody.Contains('$failure = $null') -and $digestIndex -ge 0 -and $throwIndex -gt $digestIndex) "Workflow '$($selectedContext.segment_job)' can signal execution failure before binding its segment evidence digest."
        Assert-True ($segmentBody.Contains('PR_NUMBER: ${{ github.event.pull_request.number }}') -and $segmentBody.Contains("steps.execute.outputs.cache_ready == 'true'") -and $segmentBody.Contains('AffectedCacheFinalized') -and $segmentBody.Contains('actualInventorySha256 -cne $inventorySha256')) "Workflow '$($selectedContext.segment_job)' does not retain exact producer and parent-finalized cache binding."
        Assert-True ($body.Contains('Merge-AffectedValidationSegments.ps1') -and $body.Contains("-Platform $($selectedContext.platform)")) "Required '$($selectedContext.id)' context does not verify the exact $($selectedContext.platform) segment union."
    }
    $quickWindowsBody = [string]$workflowJobs['quick-windows']
    Assert-True ($quickWindowsBody -match '(?m)^    needs: \[infrastructure, select, standard-windows\]$' -and $quickWindowsBody -match "\`$env:STANDARD_RESULT -cne 'success'") 'Required quick-windows context is not bound to the selected Windows result.'
    Assert-True ($quickWindowsBody -notmatch 'Invoke-AffectedValidation') 'Required quick-windows context replays the selected Windows suite.'
    $postMergeBody = [string]$workflowJobs['post-merge-attestation']
    Assert-True ($postMergeBody.Contains("if ([string]`$run.path -cne `$workflowPath)")) 'Post-merge evidence reuse does not bind the exact GitHub workflow path representation.'
    foreach ($platform in @('linux','windows')) {
        $artifactMarker = "affected-$platform-evidence.json"
        $artifactIndex = $workflowSource.IndexOf($artifactMarker, [StringComparison]::Ordinal)
        Assert-True ($artifactIndex -ge 0) "PR workflow lacks the $platform evidence artifact."
        Assert-True ($workflowSource.Contains("pattern: affected-segment-$platform-*") -and $workflowSource.Contains("-Platform $platform -SegmentEvidenceDirectory")) "PR workflow does not download and merge the exact $platform segment evidence set."
    }
    foreach ($platform in @('linux','windows')) {
        $mainSegmentBody = [string]$workflowJobs["main-$platform-segments"]
        $mainFinalBody = [string]$workflowJobs["main-$platform-delta"]
        Assert-True ($mainSegmentBody.Contains("matrix: `${{ fromJSON(needs.select.outputs.$($platform)_matrix) }}") -and $mainSegmentBody.Contains('-SegmentId $env:SEGMENT_ID')) "Post-merge $platform fallback is not segmented."
        Assert-True ($mainFinalBody.Contains("needs: [select, post-merge-attestation, main-$platform-segments]") -and $mainFinalBody.Contains('Merge-AffectedValidationSegments.ps1')) "Post-merge $platform final context does not require and verify its exact segment union."
    }
    $deepBody = [string]$workflowJobs['deep']
    Assert-True ($deepBody.Contains('needs: [infrastructure, select, quick-linux, standard-windows]') -and $deepBody.Contains('full-history segmented Deep evidence') -and $deepBody -notmatch 'Test-WorkEnvironment') 'Scheduled/manual Deep does not bind the fresh segmented leaf evidence or still reruns the cumulative aggregate.'
    $selectBody = [string]$workflowJobs['select']
    Assert-True ($selectBody.Contains("'schedule','workflow_dispatch'") -and $selectBody.Contains("{ 'Deep' }") -and $selectBody.Contains('Get-MorphospaceAffectedValidationSegments')) 'Schedule/manual selection does not resolve the complete Deep plan and deterministic segment matrices.'
    $executorSource = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -Raw
    $inventorySchema = Get-Content -LiteralPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json') -Raw | ConvertFrom-Json -Depth 64
    $producerEvents = @($inventorySchema.properties.producer.properties.event_name.enum)
    [Array]::Sort($producerEvents,[StringComparer]::Ordinal)
    Assert-True (($producerEvents -join ',') -ceq 'local,pull_request,push,schedule,workflow_dispatch') 'Affected check inventory does not close the exact local/PR/push/schedule/manual producer event domain.'
    Assert-True ([int64]$inventorySchema.'$defs'.artifactFile.properties.bytes.maximum -eq 134217728) 'Affected check inventory does not admit the reviewed phase-receipt size ceiling.'
    Assert-True ([int64]$inventorySchema.'$defs'.artifactFile.allOf[0].else.properties.bytes.maximum -eq 10485760) 'Affected check inventory widened ordinary artifact files beyond 10 MiB.'
    $artifactFileSchemaWrapper = [ordered]@{}
    $artifactFileSchemaWrapper.Add('$schema','https://json-schema.org/draft/2020-12/schema')
    $artifactFileSchemaWrapper.Add('$defs',$inventorySchema.'$defs')
    $artifactFileSchemaWrapper.Add('$ref','#/$defs/artifactFile')
    $artifactFileSchemaJson = ConvertTo-MorphospaceCanonicalJson -Value $artifactFileSchemaWrapper
    $maximumPhaseInventoryArtifact = [pscustomobject][ordered]@{phase_path='trust-self-executor.start.json';path='affected-selector/artifacts/trust-self-executor.start.json';bytes=134217728;sha256=('0' * 64)}
    Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $maximumPhaseInventoryArtifact) -Schema $artifactFileSchemaJson) 'Affected check inventory rejected a phase artifact at the reviewed 128 MiB ceiling.'
    $oversizedOrdinaryInventoryArtifact = $maximumPhaseInventoryArtifact | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16 -DateKind String
    $oversizedOrdinaryInventoryArtifact.phase_path = 'trust-self-executor.output.bin'
    $oversizedOrdinaryInventoryArtifact.bytes = 10485761
    Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $oversizedOrdinaryInventoryArtifact) -Schema $artifactFileSchemaJson -ErrorAction SilentlyContinue)) 'Affected check inventory admitted an ordinary artifact above 10 MiB.'
    $oversizedPhaseInventoryArtifact = $maximumPhaseInventoryArtifact | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16 -DateKind String
    $oversizedPhaseInventoryArtifact.bytes = 134217729
    Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $oversizedPhaseInventoryArtifact) -Schema $artifactFileSchemaJson -ErrorAction SilentlyContinue)) 'Affected check inventory admitted a phase artifact above 128 MiB.'
    Assert-True ($executorSource.Contains("@('pull_request','push','schedule','workflow_dispatch') -cnotcontains `$eventName") -and $executorSource.Contains("Affected check non-pull-request producer unexpectedly inherited a pull-request number.")) 'Affected executor does not distinguish the closed PR/push/schedule/manual producer identities.'
    Assert-True ($executorSource.Contains("source=`$reusable.receipt.source;plan_sha256=[string]`$reusable.receipt.plan_sha256;binding=`$binding") -and $executorSource.Contains("plan_sha256=[string]`$plan.plan_sha256;binding=`$binding")) 'Affected executor does not preserve the original receipt source and plan transitively when materializing reused evidence.'
    $producerTokens = $null
    $producerParseErrors = $null
    $executorAst = [Management.Automation.Language.Parser]::ParseInput($executorSource,[ref]$producerTokens,[ref]$producerParseErrors)
    Assert-True (@($producerParseErrors).Count -eq 0) 'Affected executor producer-binding source does not parse.'
    $producerFunctions = @($executorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-AffectedValidationProducerBinding' },$true))
    Assert-True ($producerFunctions.Count -eq 1) 'Affected executor does not define exactly one producer-binding function.'
    . ([scriptblock]::Create($producerFunctions[0].Extent.Text))
    $producerEnvironmentNames = @('GITHUB_ACTIONS','GITHUB_REPOSITORY','GITHUB_EVENT_NAME','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_WORKFLOW_REF','GITHUB_JOB','PR_NUMBER')
    $producerEnvironmentBefore = @{}
    foreach ($name in $producerEnvironmentNames) { $producerEnvironmentBefore[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
    $priorPlanVariable = Get-Variable -Name plan -Scope Script -ErrorAction SilentlyContinue
    try {
        $script:plan = [pscustomobject]@{repository='MesmerPrism/rusty-morphospace-work-environment'}
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REPOSITORY = 'MesmerPrism/rusty-morphospace-work-environment'
        $env:GITHUB_RUN_ID = '1234'
        $env:GITHUB_RUN_ATTEMPT = '1'
        $env:GITHUB_WORKFLOW_REF = 'MesmerPrism/rusty-morphospace-work-environment/.github/workflows/validate.yml@refs/heads/main'
        $env:GITHUB_JOB = 'main-linux-delta'
        $env:GITHUB_EVENT_NAME = 'push'
        Remove-Item -LiteralPath 'Env:PR_NUMBER' -ErrorAction SilentlyContinue
        $pushProducer = Get-AffectedValidationProducerBinding
        Assert-True ($pushProducer.context -ceq 'github-actions' -and $pushProducer.event_name -ceq 'push' -and [int]$pushProducer.pull_request_number -eq 0) 'Affected executor did not emit a closed push producer identity without PR_NUMBER.'
        $env:PR_NUMBER = '128'
        Assert-AffectedThrows { Get-AffectedValidationProducerBinding | Out-Null } '*unexpectedly inherited a pull-request number*' 'Affected executor accepted a push producer with PR_NUMBER.'
        $env:GITHUB_EVENT_NAME = 'pull_request'
        Remove-Item -LiteralPath 'Env:PR_NUMBER' -ErrorAction SilentlyContinue
        Assert-AffectedThrows { Get-AffectedValidationProducerBinding | Out-Null } '*pull-request identity is incomplete*' 'Affected executor accepted a pull-request producer without PR_NUMBER.'
        $env:PR_NUMBER = '128'
        $pullProducer = Get-AffectedValidationProducerBinding
        Assert-True ($pullProducer.event_name -ceq 'pull_request' -and [int]$pullProducer.pull_request_number -eq 128) 'Affected executor did not retain the exact pull-request producer identity.'
        foreach ($eventName in @('schedule','workflow_dispatch')) {
            $env:GITHUB_EVENT_NAME = $eventName
            Remove-Item -LiteralPath 'Env:PR_NUMBER' -ErrorAction SilentlyContinue
            $deepProducer = Get-AffectedValidationProducerBinding
            Assert-True ($deepProducer.event_name -ceq $eventName -and [int]$deepProducer.pull_request_number -eq 0) "Affected executor did not emit a closed $eventName producer identity without PR_NUMBER."
            $env:PR_NUMBER = '128'
            Assert-AffectedThrows { Get-AffectedValidationProducerBinding | Out-Null } '*non-pull-request producer unexpectedly inherited*' "Affected executor accepted a $eventName producer with PR_NUMBER."
        }
    } finally {
        foreach ($name in $producerEnvironmentNames) {
            $before = $producerEnvironmentBefore[$name]
            if ($null -eq $before) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($name,[string]$before,'Process') }
        }
        if ($null -eq $priorPlanVariable) { Remove-Variable -Name plan -Scope Script -ErrorAction SilentlyContinue } else { $script:plan = $priorPlanVariable.Value }
        Remove-Item -LiteralPath Function:Get-AffectedValidationProducerBinding -ErrorAction SilentlyContinue
    }
    foreach ($environmentName in @('GITHUB_OUTPUT','GITHUB_ENV','GITHUB_PATH','GITHUB_STEP_SUMMARY')) { Assert-True ($executorSource -notmatch [regex]::Escape("'$environmentName'")) "Affected child projection admits hosted command channel '$environmentName'." }
    Assert-True ($executorSource -match 'ChildTreeCleanupAttempted' -and $executorSource -match 'ChildTreeCleanupSucceeded' -and $executorSource -match 'execution\.integrity_failed' -and $executorSource -match 'terminalIntegrityFailure') 'Affected executor does not fail closed from universal child-tree cleanup/readback into cache publication.'
    Assert-AffectedExecutorContainmentSource -Source $executorSource
}

$selectionScenarioContext = $null
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('morphospace-affected-validation-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($fixture)
try {
    [void](Invoke-TestGit $fixture @('init', '--initial-branch=main'))
    [void](Invoke-TestGit $fixture @('config', 'user.name', 'Affected Validation Test'))
    [void](Invoke-TestGit $fixture @('config', 'user.email', 'affected-validation@example.invalid'))
    foreach ($directory in @('docs', 'scripts', 'scripts/lib', 'schemas', 'manifests', 'skills/example')) { [void][System.IO.Directory]::CreateDirectory((Join-Path $fixture $directory)) }
    foreach ($command in @(ConvertTo-AffectedOrdinalUniqueStrings @($registry.checks.command_path))) { $target = Join-Path $fixture ([string]$command); [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)); Write-Utf8 $target "# fixture`n" }
    $fixturePhaseRunner = @'
param([string]$Phase,[int]$BudgetSeconds,[switch]$Verify)
if ($Verify) { return }
if ([string]::IsNullOrWhiteSpace($Phase)) { throw 'Fixture phase identity is absent.' }
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
$root = [IO.Path]::GetFullPath([string]$env:RUSTY_AFFECTED_VALIDATION_PHASE_ROOT)
if (-not [IO.Directory]::Exists($root)) { [void][IO.Directory]::CreateDirectory($root) }
function Get-FixtureSha256([byte[]]$Bytes) { ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant() }
function Read-FixtureProjectionBytes([string]$Path) {
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $length = $stream.Length
        if ($length -le 0 -or $length -gt 134217728) { throw 'Fixture phase dependency projection exceeds its byte bound.' }
        [byte[]]$bytes = [byte[]]::new([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($read -le 0) { throw 'Fixture phase dependency projection ended before its declared length.' }
            $offset += $read
        }
        if ($stream.Length -ne $length) { throw 'Fixture phase dependency projection length changed during read.' }
        return $bytes
    } finally { $stream.Dispose() }
}
function Get-FixtureEnvironment([string]$Name,[string]$Pattern) {
    $value = [string][Environment]::GetEnvironmentVariable($Name,'Process')
    if ([string]::IsNullOrWhiteSpace($value) -or $value -cnotmatch $Pattern) { throw "Fixture phase environment is invalid: $Name" }
    return $value
}
function Write-FixtureBytes([string]$Path,[byte[]]$Bytes) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Write-FixtureJson([string]$Path,[object]$Value) {
    Write-FixtureBytes -Path $Path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $Value) + "`n"))
}
function Get-FixtureFileReference([string]$Path) {
    [byte[]]$bytes = [IO.File]::ReadAllBytes((Join-Path $root $Path))
    return [pscustomobject][ordered]@{path=$Path;bytes=[long]$bytes.Length;sha256=Get-FixtureSha256 $bytes}
}
$baseCommit = Get-FixtureEnvironment 'RUSTY_AFFECTED_VALIDATION_BASE_COMMIT' '^[0-9a-f]{40}$'
$headCommit = Get-FixtureEnvironment 'RUSTY_AFFECTED_VALIDATION_HEAD_COMMIT' '^[0-9a-f]{40}$'
$planSha256 = Get-FixtureEnvironment 'RUSTY_AFFECTED_VALIDATION_PLAN_SHA256' '^[0-9a-f]{64}$'
$platform = Get-FixtureEnvironment 'RUSTY_AFFECTED_VALIDATION_PLATFORM' '^(windows|linux)$'
$checkId = Get-FixtureEnvironment 'RUSTY_AFFECTED_VALIDATION_CHECK_ID' '^[a-z0-9][a-z0-9-]{1,95}$'
$projectionPath = Get-FixtureEnvironment 'RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_PATH' '^.+$'
$projectionSha256 = Get-FixtureEnvironment 'RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_SHA256' '^[0-9a-f]{64}$'
[byte[]]$projectionBytes = Read-FixtureProjectionBytes $projectionPath
if ((Get-FixtureSha256 $projectionBytes) -cne $projectionSha256) { throw 'Fixture phase dependency projection differs from its parent hash.' }
$projection = [Text.UTF8Encoding]::new($false,$true).GetString($projectionBytes) | ConvertFrom-Json -Depth 64 -DateKind String
if ([string]$projection.repository -cne 'MesmerPrism/rusty-morphospace-work-environment' -or [string]$projection.head_commit -cne $headCommit -or [string]$projection.check_id -cne $checkId) { throw 'Fixture phase dependency projection identity is invalid.' }
$powerShellPath = [IO.Path]::GetFullPath((Get-Process -Id $PID).Path)
$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Source)
$gitVersion = (& $gitPath --version).Trim()
$runner = [pscustomobject][ordered]@{
    os_description=[Runtime.InteropServices.RuntimeInformation]::OSDescription
    process_architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    powershell_version=$PSVersionTable.PSVersion.ToString()
    powershell_executable_sha256=Get-FixtureSha256 ([IO.File]::ReadAllBytes($powerShellPath))
    git_version=$gitVersion
    git_executable_sha256=Get-FixtureSha256 ([IO.File]::ReadAllBytes($gitPath))
}
$binding = [pscustomobject][ordered]@{
    repository='MesmerPrism/rusty-morphospace-work-environment'
    base_commit=$baseCommit
    head_commit=$headCommit
    head_tree=[string]$projection.head_tree
    plan_sha256=$planSha256
    platform=$platform
    check_id=$checkId
    phase_id=$Phase
    runner=$runner
    dependency_manifest=@($projection.dependency_manifest)
}
$bindingSha256 = Get-MorphospaceCanonicalJsonSha256 -Value $binding
$now = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
Write-FixtureJson -Path (Join-Path $root "$Phase.start.json") -Value ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_self_test_phase_start.v1';phase_id=$Phase;binding=$binding;binding_sha256=$bindingSha256;started_at=$now;budget_seconds=$BudgetSeconds})
Write-FixtureBytes -Path (Join-Path $root "$Phase.stdout.bin") -Bytes ([byte[]]@())
Write-FixtureBytes -Path (Join-Path $root "$Phase.stderr.bin") -Bytes ([byte[]]@())
$terminal = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.affected_validation_self_test_phase_receipt.v1'
    phase_id=$Phase
    binding=$binding
    binding_sha256=$bindingSha256
    started_at=$now
    ended_at=$now
    budget_seconds=$BudgetSeconds
    elapsed_ms=0
    result='pass'
    child=[pscustomobject][ordered]@{started=$true;exit_code=0;timed_out=$false;post_kill_drain_timed_out=$false;stdout=Get-FixtureFileReference "$Phase.stdout.bin";stderr=Get-FixtureFileReference "$Phase.stderr.bin"}
    outputs=@()
    claims=[pscustomobject][ordered]@{phase_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}
}
Write-FixtureJson -Path (Join-Path $root "$Phase.terminal.json") -Value $terminal
'@
    Write-Utf8 (Join-Path $fixture 'scripts/Invoke-AffectedValidationSelfTestPhase.ps1') $fixturePhaseRunner
    foreach ($runnerSourcePath in @(
        'schemas/affected-validation-check-evidence-v1.schema.json',
        'schemas/affected-validation-check-inventory-v1.schema.json',
        'schemas/affected-validation-plan-v1.schema.json',
        'schemas/affected-validation-registry-v1.schema.json',
        'schemas/affected-validation-self-test-phase-receipt-v1.schema.json',
        'schemas/development-unit-admission-v1.schema.json',
        'scripts/Invoke-AffectedValidation.ps1',
        'scripts/lib/MorphospaceAffectedValidation.psm1',
        'scripts/lib/MorphospaceAffectedValidationCheckEvidence.psm1',
        'scripts/lib/MorphospaceAffectedValidationDependencyClosure.psm1',
        'scripts/lib/MorphospaceProtocolCommon.psm1'
    )) {
        $target = Join-Path $fixture $runnerSourcePath
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        Copy-Item -LiteralPath (Join-Path $repoRoot $runnerSourcePath) -Destination $target
    }
    Write-Utf8 (Join-Path $fixture 'scripts/lib/DocumentationLinksDependency.psm1') "function Get-DocumentationLinksDependency { 'bound' }`nExport-ModuleMember -Function Get-DocumentationLinksDependency`n"
    Write-Utf8 (Join-Path $fixture 'schemas/DocumentationLinksInput.schema.json') "{}`n"
    Write-Utf8 (Join-Path $fixture 'schemas/FallbackDynamicInput.schema.json') "{}`n"
    Write-Utf8 (Join-Path $fixture 'scripts/FallbackDynamicTarget.ps1') "[void](Get-Content -LiteralPath (Join-Path `$PSScriptRoot '../schemas/FallbackDynamicInput.schema.json') -Raw)`n"
    Write-Utf8 (Join-Path $fixture 'scripts/Test-DocumentationLinks.ps1') "param([string]`$UnresolvedModulePath)`nif (@(Get-ChildItem Env: | Where-Object { ([string]`$_.Name).StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase) }).Count -ne 0 -or `$null-ne`$env:RUSTY_UNOWNED_DAMAGE -or `$null-ne`$env:WEF002_AMBIENT_DAMAGE) { throw 'Affected child retained an ambient environment override.' }`nif([string]::IsNullOrWhiteSpace(`$env:RUSTY_AFFECTED_VALIDATION_CHECK_ID)){throw 'Affected child omitted its launcher-owned identity.'}`n`$ModulePath = Join-Path `$PSScriptRoot 'lib/DocumentationLinksDependency.psm1'`nImport-Module `$ModulePath -Force`nif (-not [string]::IsNullOrWhiteSpace(`$UnresolvedModulePath)) { Import-Module `$UnresolvedModulePath -Force }`n`$SchemaRoot = Join-Path `$PSScriptRoot '../schemas'`n[void](Join-Path `$SchemaRoot 'DocumentationLinksInput.schema.json')`n[void](Get-DocumentationLinksDependency)`n"
    Write-Utf8 (Join-Path $fixture 'scripts/Test-AffectedLeafBindingFixture.ps1') "'leaf binding fixture'`n"
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "`$prior=Join-Path ([IO.Path]::GetFullPath((Get-Location).Path)) 'affected-check-evidence-snapshot-prior';if([IO.Directory]::Exists(`$prior)){`$targets=@(Get-ChildItem -LiteralPath `$prior -Filter receipt.json -File -Recurse|Where-Object{(Get-Content -LiteralPath `$_.FullName -Raw|ConvertFrom-Json -Depth 64).binding.check_id -ceq 'documentation-links'});if(`$targets.Count-ne1){throw 'snapshot mutation target is not exact'};[IO.File]::WriteAllText(`$targets[0].FullName,'mutated after parent snapshot',[Text.UTF8Encoding]::new(`$false))}`n"
    $fixtureRegistry = Read-MorphospaceProtocolJson -Path $registryPath
    $fixtureRegistry.dependency_declarations = @()
    $leafBindingCheck = @($fixtureRegistry.checks | Where-Object check_id -ceq 'documentation-links')[0] | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
    $leafBindingCheck.check_id = 'leaf-binding-fixture'
    $leafBindingCheck.command_path = 'scripts/Test-AffectedLeafBindingFixture.ps1'
    $leafBindingCheck.consume_path_sets = @('leaf-binding-fixture')
    $leafBindingCheck.provides_contracts = @()
    $fixtureRegistry.path_sets = @($fixtureRegistry.path_sets) + @([pscustomobject][ordered]@{path_set_id='leaf-binding-fixture';patterns=@('scripts/Test-AffectedLeafBindingFixture.ps1')})
    $fixtureRegistry.checks = @($fixtureRegistry.checks) + @($leafBindingCheck)
    $fixtureRegistry.checks | Where-Object check_id -ceq 'public-boundary' | ForEach-Object {
        $_.trigger_path_sets = @($_.trigger_path_sets) + @('leaf-binding-fixture')
        $_.consume_path_sets = @($_.consume_path_sets) + @('leaf-binding-fixture')
    }
    $fixtureRegistry.path_sets | Where-Object path_set_id -ceq 'documentation' | ForEach-Object { $_.patterns = @($_.patterns) + @('scripts/Test-AffectedLeafBindingFixture.ps1') }
    # Keep the timeout damage cell bounded while leaving headroom above the
    # executor's 15-second containment/drain contract. The deliberate
    # twenty-five-second command below must still time out under this exact
    # twenty-second fixture budget.
    $fixtureRegistry.checks | Where-Object { $_.check_id -ceq 'public-boundary' } | ForEach-Object { $_.budget_seconds = 20 }
    Write-Utf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson -Value $fixtureRegistry) + "`n")
    Copy-Item -LiteralPath (Join-Path $repoRoot 'schemas/history-archive-root-v1.schema.json') -Destination (Join-Path $fixture 'schemas/history-archive-root-v1.schema.json')
    Write-Utf8 (Join-Path $fixture 'docs/base.md') "base`n"
    [void](Invoke-TestGit $fixture @('add', '.'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'base'))
    $base = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $runnerDriftHead = $base
    $runnerDriftTree = Invoke-TestGit $fixture @('rev-parse', 'HEAD^{tree}')

    $docsHead = $base
    $planPath = Join-Path $fixture 'affected-plan.json'
    if ($runFullSelector -or $runExecutorPassPhase -or $runExecutorDamagePhase) {
        $runnerDriftPath = Join-Path $fixture 'scripts/lib/MorphospaceAffectedValidationCheckEvidence.psm1'
        [byte[]]$runnerExactBytes = [IO.File]::ReadAllBytes($runnerDriftPath)
        [IO.File]::WriteAllBytes($runnerDriftPath,([byte[]]($runnerExactBytes + [Text.UTF8Encoding]::new($false).GetBytes("# source-commit drift fixture`n"))))
        [void](Invoke-TestGit $fixture @('add', 'scripts/lib/MorphospaceAffectedValidationCheckEvidence.psm1'))
        [void](Invoke-TestGit $fixture @('commit', '-m', 'runner source drift ancestor'))
        $runnerDriftHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
        $runnerDriftTree = Invoke-TestGit $fixture @('rev-parse', 'HEAD^{tree}')
        [IO.File]::WriteAllBytes($runnerDriftPath,$runnerExactBytes)
        Write-Utf8 (Join-Path $fixture 'docs/base.md') "changed`n"
        [void](Invoke-TestGit $fixture @('add', 'docs/base.md', 'scripts/lib/MorphospaceAffectedValidationCheckEvidence.psm1'))
        [void](Invoke-TestGit $fixture @('commit', '-m', 'docs'))
        $docsHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
        $docsPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $base -HeadRevision $docsHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $docsPlan) + "`n")
        if ($runFullSelector -or $runExecutorPassPhase) {
            Assert-True ($docsPlan.selection_mode -ceq 'affected') 'Documentation change did not remain affected-only.'
            Assert-True (@($docsPlan.selected_checks.check_id) -ccontains 'documentation-links') 'Documentation check was not selected.'
            $docsBoundaryIndex = [array]::IndexOf(@($docsPlan.selected_checks.check_id), 'public-boundary')
            $docsLinksIndex = [array]::IndexOf(@($docsPlan.selected_checks.check_id), 'documentation-links')
            Assert-True ($docsBoundaryIndex -ge 0 -and $docsLinksIndex -gt $docsBoundaryIndex) 'Execution-order dependency did not order two independently selected checks.'
            Assert-True (@($docsPlan.selected_checks.check_id) -cnotcontains 'work-unit-automation') 'Unrelated automation check was selected for documentation.'
            Assert-True ([bool]$docsPlan.claims.selection_only -and -not [bool]$docsPlan.claims.checks_executed) 'Selection plan claimed check execution or lifecycle authority.'
            Assert-True (@($docsPlan.selected_checks | Where-Object { @($_.platforms) -ccontains 'windows' }).Count -eq 0) 'Documentation change unnecessarily selected a Windows suite.'
            $docsSegments = @(Get-MorphospaceAffectedValidationSegments -Plan $docsPlan -Registry $fixtureRegistry -Platform linux)
            Assert-True ($docsSegments.Count -eq 1 -and [string]$docsSegments[0].segment_id -ceq 'linux-001' -and (Get-MorphospaceCanonicalJsonSha256 -Value @($docsSegments[0].check_ids)) -ceq (Get-MorphospaceCanonicalJsonSha256 -Value @($docsPlan.selected_checks.check_id))) 'Documentation selection did not produce one exact deterministic Linux segment.'
            $explicitDeepPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $base -HeadRevision $docsHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier deep
            Assert-True ($explicitDeepPlan.selection_mode -ceq 'full-deep' -and @($explicitDeepPlan.reason_codes) -ccontains 'deep-requested' -and @($explicitDeepPlan.selected_checks.check_id) -cnotcontains 'work-environment-deep') 'Explicit Deep request did not select independent leaves or retained the redundant cumulative aggregate.'
            Assert-AffectedThrows { & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -SegmentId 'windows-001' -OutPath (Join-Path $fixture 'affected-evidence-wrong-platform.json') | Out-Null } '*differs from its requested platform*' 'Affected executor accepted a segment ID for another platform.'
            Assert-AffectedThrows { & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -SegmentId 'linux-999' -OutPath (Join-Path $fixture 'affected-evidence-unknown-segment.json') | Out-Null } '*not present in the exact plan partition*' 'Affected executor accepted a segment ID outside the exact partition.'
            $evidencePath = Join-Path $fixture 'affected-evidence.json'
            $priorGitPager = [Environment]::GetEnvironmentVariable('GIT_PAGER','Process')
            $priorGitTestOverride = [Environment]::GetEnvironmentVariable('GIT_AFFECTED_VALIDATION_TEST','Process')
            $priorRustyDamage = [Environment]::GetEnvironmentVariable('RUSTY_UNOWNED_DAMAGE','Process');$priorOtherDamage=[Environment]::GetEnvironmentVariable('WEF002_AMBIENT_DAMAGE','Process')
            $projectionResiduePattern = ".rusty-affected-dependency-projection-$PID-*.json"
            [string[]]$projectionResidueBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -File -Filter $projectionResiduePattern -ErrorAction SilentlyContinue | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
            if ($projectionResidueBefore.Count -gt 1) { [Array]::Sort($projectionResidueBefore,[StringComparer]::Ordinal) }
            try {
                $env:GIT_PAGER = 'affected-parent-pager-must-not-reach-child'
                $env:GIT_AFFECTED_VALIDATION_TEST = 'affected-parent-git-override-must-not-reach-child'
                $env:RUSTY_UNOWNED_DAMAGE='unowned-rusty-must-not-reach-child';$env:WEF002_AMBIENT_DAMAGE='ambient-must-not-reach-child';$parentEnvironmentBefore=Get-TestEnvironmentDigest
                $evidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -SegmentId ([string]$docsSegments[0].segment_id) -OutPath $evidencePath -RunRestorationCollisionSelfTest:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows))
                Assert-True ((Get-TestEnvironmentDigest)-ceq$parentEnvironmentBefore) 'Affected executor changed parent process environment bytes.'
            } finally {
                if ($null -eq $priorGitPager) { Remove-Item -LiteralPath 'Env:GIT_PAGER' -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable('GIT_PAGER',$priorGitPager,'Process') }
                if ($null -eq $priorGitTestOverride) { Remove-Item -LiteralPath 'Env:GIT_AFFECTED_VALIDATION_TEST' -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable('GIT_AFFECTED_VALIDATION_TEST',$priorGitTestOverride,'Process') }
                [Environment]::SetEnvironmentVariable('RUSTY_UNOWNED_DAMAGE',$priorRustyDamage,'Process');[Environment]::SetEnvironmentVariable('WEF002_AMBIENT_DAMAGE',$priorOtherDamage,'Process')
            }
            Assert-True ([Environment]::GetEnvironmentVariable('GIT_PAGER','Process') -ceq $priorGitPager -and [Environment]::GetEnvironmentVariable('GIT_AFFECTED_VALIDATION_TEST','Process') -ceq $priorGitTestOverride) 'Affected executor did not restore inherited Git environment overrides exactly.'
            [string[]]$projectionResidueAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -File -Filter $projectionResiduePattern -ErrorAction SilentlyContinue | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
            if ($projectionResidueAfter.Count -gt 1) { [Array]::Sort($projectionResidueAfter,[StringComparer]::Ordinal) }
            Assert-True (($projectionResidueAfter -join "`0") -ceq ($projectionResidueBefore -join "`0")) 'Affected executor left an owned dependency-projection file after successful child execution.'
            if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { [W017BoundedChildCapture]::RunRestorationCollisionSelfTests() }
            Assert-True ([IO.File]::Exists($evidencePath)) 'Affected executor did not publish evidence.'
            Assert-True ($evidence.result -ceq 'pass' -and @($evidence.check_results).Count -ge 2) 'Affected executor did not bind selected checks into pass evidence.'
            Assert-True (@($evidence.check_results | Where-Object { $_.stdout_sha256 -notmatch '^[0-9a-f]{64}$' -or $_.stderr_sha256 -notmatch '^[0-9a-f]{64}$' -or $_.timed_out -or $_.output_truncated -or $_.post_kill_drain_timed_out }).Count -eq 0) 'Affected executor omitted bounded child-output evidence.'
            $firstCheckRoot = Join-Path $fixture "affected-check-evidence-$($docsPlan.plan_sha256)-linux-001"
            $firstInventoryPath = Join-Path $firstCheckRoot 'inventory.json'
            Assert-True ([IO.File]::Exists($firstInventoryPath)) 'Affected executor did not finalize a parent-owned check inventory.'
            Assert-True ([string]$evidence.cache_inventory_sha256 -match '^[0-9a-f]{64}$' -and [string]$evidence.cache_inventory_sha256 -ceq (Get-FileHash -LiteralPath $firstInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Passing executor did not return the exact materialized inventory SHA-256.'
            $firstInventory = Get-Content -LiteralPath $firstInventoryPath -Raw | ConvertFrom-Json -Depth 64 -DateKind String
            $firstReceipts = @(Get-ChildItem -LiteralPath $firstCheckRoot -Filter receipt.json -File -Recurse)
            Assert-True ($firstReceipts.Count -eq @($evidence.check_results).Count) 'Affected executor did not preserve one typed leaf receipt per executed check.'
            Assert-True (@($firstInventory.entries).Count -eq $firstReceipts.Count) 'Affected check inventory does not bind every leaf receipt.'
            $expectedProducerContext = if ([string][Environment]::GetEnvironmentVariable('GITHUB_ACTIONS','Process') -ceq 'true') { 'github-actions' } else { 'local' }
            Assert-True ([string]$firstInventory.producer.context -ceq $expectedProducerContext) "Affected check inventory producer context does not match the ambient '$expectedProducerContext' execution context."
            foreach ($receiptFile in $firstReceipts) {
                $receipt = Get-Content -LiteralPath $receiptFile.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String
                Assert-True ($receipt.mode -ceq 'executed' -and $receipt.result -ceq 'pass' -and $receipt.binding_sha256 -match '^[0-9a-f]{64}$') 'Initial affected leaf receipt is not exact executed passing evidence.'
                Assert-True ([bool]$receipt.environment.projected -and [bool]$receipt.environment.parent_environment_unchanged -and [int]$receipt.environment.supervisor_variable_count -eq @($receipt.environment.supervisor_variables).Count -and [int]$receipt.environment.leaf_variable_count -eq @($receipt.environment.leaf_variables).Count -and @($receipt.environment.leaf_variables|Where-Object{$_.name -like 'GIT_*' -or $_.name -ceq 'RUSTY_UNOWNED_DAMAGE' -or $_.name -ceq 'WEF002_AMBIENT_DAMAGE'}).Count-eq0) 'Affected leaf receipt does not prove its closed two-hop environment projection.'
                foreach ($stream in @('stdout','stderr')) { $streamPath = Join-Path $receiptFile.DirectoryName "$stream.bin"; Assert-True ([IO.File]::Exists($streamPath) -and (Get-FileHash -LiteralPath $streamPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$receipt.child.$stream.sha256) "Affected leaf $stream bytes are not bound by their receipt." }
            }
            $publicBoundaryReceipt = @($firstReceipts | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String).binding.check_id -ceq 'public-boundary' })
            $documentationReceipt = @($firstReceipts | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String).binding.check_id -ceq 'documentation-links' })
            $leafBindingReceipt = @($firstReceipts | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String).binding.check_id -ceq 'leaf-binding-fixture' })
            Assert-True ($publicBoundaryReceipt.Count -eq 1 -and $documentationReceipt.Count -eq 1 -and $leafBindingReceipt.Count -eq 1) 'Documentation/order-anchor/leaf-binding receipt identities are not unique.'
            $publicBoundaryReceiptValue = Get-Content -LiteralPath $publicBoundaryReceipt[0].FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String
            $documentationReceiptValue = Get-Content -LiteralPath $documentationReceipt[0].FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String
            $leafBindingReceiptValue = Get-Content -LiteralPath $leafBindingReceipt[0].FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String
            $missingLeafFailureKind = $documentationReceiptValue | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
            $missingLeafFailureKind.child.PSObject.Properties.Remove('failure_kind')
            Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $missingLeafFailureKind) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Leaf evidence schema accepted missing typed failure data.'
            $failureKindCases = @(
                [pscustomobject]@{kind='launch';result='infra-fail';started=$false;exit_code=$null;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;bound=@('mode','result','started','exit_code','timed_out','output_truncated','post_kill_drain_timed_out')},
                [pscustomobject]@{kind='timeout';result='code-fail';started=$true;exit_code=137;timed_out=$true;output_truncated=$true;post_kill_drain_timed_out=$true;bound=@('mode','result','started','timed_out')},
                [pscustomobject]@{kind='output-limit';result='code-fail';started=$true;exit_code=137;timed_out=$false;output_truncated=$true;post_kill_drain_timed_out=$true;bound=@('mode','result','started','timed_out','output_truncated')},
                [pscustomobject]@{kind='drain-timeout';result='code-fail';started=$true;exit_code=137;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$true;bound=@('mode','result','started','timed_out','output_truncated','post_kill_drain_timed_out')},
                [pscustomobject]@{kind='infrastructure';result='infra-fail';started=$true;exit_code=125;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;bound=@('mode','result','timed_out','output_truncated','post_kill_drain_timed_out')},
                [pscustomobject]@{kind='exit-code';result='code-fail';started=$true;exit_code=17;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;bound=@('mode','result','started','exit_code','timed_out','output_truncated','post_kill_drain_timed_out')}
            )
            $allFailureKinds=@($null,'launch','timeout','output-limit','drain-timeout','infrastructure','exit-code')
            foreach ($case in $failureKindCases) {
                $validLeafFailure = $documentationReceiptValue | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                $validLeafFailure.mode='executed';$validLeafFailure.result=$case.result;$validLeafFailure.blocked_by=@();$validLeafFailure.reused_from=$null;$validLeafFailure.artifacts=@()
                foreach($field in @('started','exit_code','timed_out','output_truncated','post_kill_drain_timed_out')){$validLeafFailure.child.$field=$case.$field};$validLeafFailure.child.failure_kind=$case.kind
                Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $validLeafFailure) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction Stop) "Leaf evidence schema rejected truthful '$($case.kind)' precedence evidence."
                if($case.kind-ceq'infrastructure'){$preExecutionInfrastructure=$validLeafFailure|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;$preExecutionInfrastructure.child.started=$false;$preExecutionInfrastructure.child.exit_code=$null;Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $preExecutionInfrastructure) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction Stop) 'Leaf evidence schema rejected pre-execution infrastructure failure.'}
                foreach ($field in @($case.bound)) {
                    $damagedLeafFailure = $validLeafFailure | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                    switch ($field) {
                        'mode' { $damagedLeafFailure.mode='reused' }
                        'result' { $damagedLeafFailure.result='pass' }
                        'started' { $damagedLeafFailure.child.started=-not[bool]$damagedLeafFailure.child.started }
                        'exit_code' { $damagedLeafFailure.child.exit_code=0 }
                        'timed_out' { $damagedLeafFailure.child.timed_out=-not[bool]$damagedLeafFailure.child.timed_out }
                        'output_truncated' { $damagedLeafFailure.child.output_truncated=-not[bool]$damagedLeafFailure.child.output_truncated }
                        'post_kill_drain_timed_out' { $damagedLeafFailure.child.post_kill_drain_timed_out=-not[bool]$damagedLeafFailure.child.post_kill_drain_timed_out }
                    }
                    Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $damagedLeafFailure) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) "Leaf evidence schema accepted '$($case.kind)' contradiction in '$field'."
                }
                foreach($candidateKind in $allFailureKinds){if([string]$candidateKind-ceq[string]$case.kind){continue};$crossKind=$validLeafFailure|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;$crossKind.child.failure_kind=$candidateKind;$crossKindValid=Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $crossKind) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction SilentlyContinue;$intentionalPreIntegrityOverlap=$case.kind-ceq'launch'-and$candidateKind-ceq'infrastructure';Assert-True ($crossKindValid-eq$intentionalPreIntegrityOverlap) "Leaf evidence cross-kind matrix mismatch: $($case.kind) -> $(if($null-eq$candidateKind){'null'}else{$candidateKind})."}
            }
            $executedPassWithoutStart=$documentationReceiptValue|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;$executedPassWithoutStart.child.started=$false
            Assert-True (-not(Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $executedPassWithoutStart) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Leaf schema accepted executed pass with child.started=false.'
            $reusedPass=$documentationReceiptValue|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;$reusedPass.mode='reused';$reusedPass.elapsed_ms=0;$reusedPass.child.started=$false;$reusedPass.reused_from=[pscustomobject][ordered]@{receipt_sha256=('a'*64);source_head=$documentationReceiptValue.source.head}
            Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $reusedPass) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction Stop) 'Leaf schema rejected the intentional reused-pass/started=false shape.'
            $reusedPreprojection=$reusedPass|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;$reusedPreprojection.environment=[pscustomobject][ordered]@{projected=$false;parent_variable_count_before=0;parent_sha256_before=$null;parent_variable_count_after=0;parent_sha256_after=$null;parent_environment_unchanged=$true;supervisor_variable_count=0;supervisor_sha256=$null;supervisor_variables=@();leaf_variable_count=0;leaf_sha256=$null;leaf_variables=@()}
            Assert-True (-not(Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $reusedPreprojection) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Leaf schema accepted reused evidence without a projected environment.'
            $blockedShape=$documentationReceiptValue|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;$blockedShape.mode='blocked';$blockedShape.result='blocked';$blockedShape.elapsed_ms=0;$blockedShape.blocked_by=@('public-boundary');$blockedShape.reused_from=$null;$blockedShape.artifacts=@();$blockedShape.child.started=$false;$blockedShape.child.exit_code=$null;$blockedShape.child.failure_kind='blocked';$blockedShape.child.timed_out=$false;$blockedShape.child.output_truncated=$false;$blockedShape.child.post_kill_drain_timed_out=$false;foreach($stream in @('stdout','stderr')){$blockedShape.child.$stream.bytes=0;$blockedShape.child.$stream.sha256=('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')};$blockedShape.environment=$reusedPreprojection.environment
            Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $blockedShape) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction Stop) 'Leaf schema rejected the exact blocked shape.'
            foreach($damage in @('mode','result','started')){$damagedBlocked=$blockedShape|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;if($damage-ceq'mode'){$damagedBlocked.mode='executed'}elseif($damage-ceq'result'){$damagedBlocked.result='pass'}else{$damagedBlocked.child.started=$true};Assert-True (-not(Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $damagedBlocked) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) "Leaf schema accepted blocked contradiction in '$damage'."}
            Assert-True (@($documentationReceiptValue.binding.prerequisite_bindings).Count -eq 0) 'Execution-order dependency entered the reusable documentation evidence binding.'
            Assert-True (@($leafBindingReceiptValue.binding.prerequisite_bindings).Count -eq 0) 'Execution-order dependency entered the reusable focused leaf evidence binding.'
            Assert-True ([string]$leafBindingReceiptValue.binding.dependency_resolution.mode -ceq 'exact' -and @($leafBindingReceiptValue.binding.dependency_resolution.fallback_reasons).Count -eq 0 -and @($leafBindingReceiptValue.binding.dependency_manifest.path) -cnotcontains 'scripts/Test-PublicBoundary.ps1') 'Independent leaf binding retained the aggregate all-scripts closure.'
            Assert-True (@($leafBindingReceiptValue.binding.runner_source_manifest.path) -cnotcontains 'manifests/affected-validation-registry.json' -and @($leafBindingReceiptValue.binding.runner_source_manifest.path) -ccontains 'schemas/affected-validation-plan-v1.schema.json') 'Leaf runner-source binding retained raw registry bytes or omitted the consumed plan schema.'
            $originalRegistry = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
            $originalReceiptSha256 = Get-MorphospaceAffectedCheckBytesSha256 ([IO.File]::ReadAllBytes($leafBindingReceipt[0].FullName))
            try {
                [void](Invoke-TestGit $fixture @('checkout','-b','leaf-binding-two-head-fixture'))
                $schedulingRegistry = $originalRegistry | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                $schedulingRegistry.checks | Where-Object check_id -ceq 'leaf-binding-fixture' | ForEach-Object { $_.execution_after_checks = @() }
                Write-Utf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson -Value $schedulingRegistry) + "`n")
                [void](Invoke-TestGit $fixture @('add','manifests/affected-validation-registry.json'))
                [void](Invoke-TestGit $fixture @('commit','-m','scheduling metadata only'))
                $schedulingHead = Invoke-TestGit $fixture @('rev-parse','HEAD')
                $schedulingTree = Invoke-TestGit $fixture @('rev-parse','HEAD^{tree}')
                $docsTree = Invoke-TestGit $fixture @('rev-parse',"$docsHead^{tree}")
                $schedulingPaths = @((Invoke-TestGit $fixture @('diff','--name-only',$docsHead,$schedulingHead)).Split("`n",[StringSplitOptions]::RemoveEmptyEntries))
                Assert-True ($schedulingHead -cne $docsHead -and $schedulingTree -cne $docsTree -and $schedulingPaths.Count -eq 1 -and $schedulingPaths[0] -ceq 'manifests/affected-validation-registry.json') 'Scheduling-only fixture did not create two distinct heads/trees with exactly one registry path change.'
                $expectedSchedulingRegistry = $originalRegistry | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                $expectedSchedulingRegistry.checks | Where-Object check_id -ceq 'leaf-binding-fixture' | ForEach-Object { $_.execution_after_checks = @() }
                Assert-True ((ConvertTo-MorphospaceCanonicalJson -Value $schedulingRegistry) -ceq (ConvertTo-MorphospaceCanonicalJson -Value $expectedSchedulingRegistry)) 'Scheduling fixture changed more than execution_after_checks metadata.'
                $schedulingPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $docsHead -HeadRevision $schedulingHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
                Assert-True ([string]$schedulingPlan.registry.sha256 -cne [string]$docsPlan.registry.sha256 -and [string]$schedulingPlan.plan_sha256 -cne [string]$docsPlan.plan_sha256) 'Full plan validation did not retain the changed raw registry identity.'
                $schedulingCompiled = Test-MorphospaceAffectedValidationRegistry -Registry $schedulingRegistry -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')
                $schedulingInventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $fixture -Commit $schedulingHead
                $schedulingRunnerManifest = @(Get-MorphospaceAffectedCheckRunnerSourceManifest -Inventory $schedulingInventory)
                $schedulingLeafCheck = @($schedulingRegistry.checks | Where-Object check_id -ceq 'leaf-binding-fixture')[0]
                $schedulingDependencyClosure = Get-MorphospaceAffectedCheckDependencyClosure -Check $schedulingLeafCheck -CompiledRegistry $schedulingCompiled -Inventory $schedulingInventory -RepositoryRoot $fixture
                $schedulingDependencyManifest = @($schedulingDependencyClosure.manifest)
                $schedulingBinding = New-MorphospaceAffectedCheckBinding -Repository ([string]$leafBindingReceiptValue.binding.repository) -Platform ([string]$leafBindingReceiptValue.binding.platform) -Check $schedulingLeafCheck -Runner $leafBindingReceiptValue.binding.runner -RunnerSourceManifest $schedulingRunnerManifest -DependencyManifest $schedulingDependencyManifest -DependencyResolution $schedulingDependencyClosure.resolution -PrerequisiteBindings @()
                $schedulingBindingSha256 = Get-MorphospaceCanonicalJsonSha256 -Value $schedulingBinding
                Assert-True ((ConvertTo-MorphospaceCanonicalJson -Value $schedulingRunnerManifest) -ceq (ConvertTo-MorphospaceCanonicalJson -Value @($leafBindingReceiptValue.binding.runner_source_manifest))) 'Scheduling-only second head changed the rebuilt leaf-compatible runner manifest.'
                Assert-True ((ConvertTo-MorphospaceCanonicalJson -Value $schedulingDependencyManifest) -ceq (ConvertTo-MorphospaceCanonicalJson -Value @($leafBindingReceiptValue.binding.dependency_manifest))) 'Scheduling-only second head changed the rebuilt leaf dependency manifest.'
                Assert-True ($schedulingBindingSha256 -ceq [string]$leafBindingReceiptValue.binding_sha256) 'Scheduling-only second head changed the complete rebuilt leaf binding.'
                $schedulingReuse = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $firstCheckRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $schedulingBinding -ExpectedBindingSha256 $schedulingBindingSha256 -RepositoryRoot $fixture -CurrentHeadCommit $schedulingHead -CandidateReceiptPaths @($leafBindingReceipt[0].FullName)
                Assert-True ($null -ne $schedulingReuse -and [string]$schedulingReuse.receipt_sha256 -ceq $originalReceiptSha256) 'Scheduling-only second head/tree did not reuse the same complete passing receipt.'

                $semanticRegistry = $schedulingRegistry | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                $semanticRegistry.checks | Where-Object check_id -ceq 'leaf-binding-fixture' | ForEach-Object { $_.prerequisite_checks = @('public-boundary') }
                Write-Utf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson -Value $semanticRegistry) + "`n")
                [void](Invoke-TestGit $fixture @('add','manifests/affected-validation-registry.json'))
                [void](Invoke-TestGit $fixture @('commit','-m','semantic prerequisite metadata'))
                $semanticHead = Invoke-TestGit $fixture @('rev-parse','HEAD')
                $semanticExpectedCheck = $schedulingLeafCheck | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                $semanticExpectedCheck.prerequisite_checks = @('public-boundary')
                $semanticLeafCheck = @($semanticRegistry.checks | Where-Object check_id -ceq 'leaf-binding-fixture')[0]
                Assert-True ((ConvertTo-MorphospaceCanonicalJson -Value $semanticLeafCheck) -ceq (ConvertTo-MorphospaceCanonicalJson -Value $semanticExpectedCheck)) 'Semantic two-head fixture changed more than prerequisite_checks.'
                $semanticCompiled = Test-MorphospaceAffectedValidationRegistry -Registry $semanticRegistry -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')
                $semanticInventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $fixture -Commit $semanticHead
                $semanticDependencyClosure = Get-MorphospaceAffectedCheckDependencyClosure -Check $semanticLeafCheck -CompiledRegistry $semanticCompiled -Inventory $semanticInventory -RepositoryRoot $fixture
                $semanticBinding = New-MorphospaceAffectedCheckBinding -Repository ([string]$leafBindingReceiptValue.binding.repository) -Platform ([string]$leafBindingReceiptValue.binding.platform) -Check $semanticLeafCheck -Runner $leafBindingReceiptValue.binding.runner -RunnerSourceManifest @(Get-MorphospaceAffectedCheckRunnerSourceManifest -Inventory $semanticInventory) -DependencyManifest @($semanticDependencyClosure.manifest) -DependencyResolution $semanticDependencyClosure.resolution -PrerequisiteBindings @([pscustomobject][ordered]@{check_id='public-boundary';binding_sha256=[string]$publicBoundaryReceiptValue.binding_sha256})
                $semanticBindingSha256 = Get-MorphospaceCanonicalJsonSha256 -Value $semanticBinding
                $semanticReuse = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $firstCheckRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $semanticBinding -ExpectedBindingSha256 $semanticBindingSha256 -RepositoryRoot $fixture -CurrentHeadCommit $semanticHead -CandidateReceiptPaths @($leafBindingReceipt[0].FullName)
                Assert-True ($semanticBindingSha256 -cne [string]$leafBindingReceiptValue.binding_sha256 -and $null -eq $semanticReuse) 'Semantic prerequisite change at a second head reused earlier leaf evidence.'

                $executionRegistry = $schedulingRegistry | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                $executionRegistry.checks | Where-Object check_id -ceq 'leaf-binding-fixture' | ForEach-Object { $_.budget_seconds = [long]$_.budget_seconds + 1 }
                Write-Utf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson -Value $executionRegistry) + "`n")
                [void](Invoke-TestGit $fixture @('add','manifests/affected-validation-registry.json'))
                [void](Invoke-TestGit $fixture @('commit','-m','execution relevant check metadata'))
                $executionHead = Invoke-TestGit $fixture @('rev-parse','HEAD')
                $executionExpectedCheck = $schedulingLeafCheck | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                $executionExpectedCheck.budget_seconds = [long]$executionExpectedCheck.budget_seconds + 1
                $executionLeafCheck = @($executionRegistry.checks | Where-Object check_id -ceq 'leaf-binding-fixture')[0]
                Assert-True ((ConvertTo-MorphospaceCanonicalJson -Value $executionLeafCheck) -ceq (ConvertTo-MorphospaceCanonicalJson -Value $executionExpectedCheck)) 'Execution-relevant two-head fixture changed more than budget_seconds from the scheduling head.'
                $executionCompiled = Test-MorphospaceAffectedValidationRegistry -Registry $executionRegistry -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')
                $executionInventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $fixture -Commit $executionHead
                $executionDependencyClosure = Get-MorphospaceAffectedCheckDependencyClosure -Check $executionLeafCheck -CompiledRegistry $executionCompiled -Inventory $executionInventory -RepositoryRoot $fixture
                $executionBinding = New-MorphospaceAffectedCheckBinding -Repository ([string]$leafBindingReceiptValue.binding.repository) -Platform ([string]$leafBindingReceiptValue.binding.platform) -Check $executionLeafCheck -Runner $leafBindingReceiptValue.binding.runner -RunnerSourceManifest @(Get-MorphospaceAffectedCheckRunnerSourceManifest -Inventory $executionInventory) -DependencyManifest @($executionDependencyClosure.manifest) -DependencyResolution $executionDependencyClosure.resolution -PrerequisiteBindings @()
                $executionBindingSha256 = Get-MorphospaceCanonicalJsonSha256 -Value $executionBinding
                $executionReuse = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $firstCheckRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $executionBinding -ExpectedBindingSha256 $executionBindingSha256 -RepositoryRoot $fixture -CurrentHeadCommit $executionHead -CandidateReceiptPaths @($leafBindingReceipt[0].FullName)
                Assert-True ($executionBindingSha256 -cne [string]$leafBindingReceiptValue.binding_sha256 -and $null -eq $executionReuse) 'Execution-relevant change at a second head reused earlier leaf evidence.'
            } finally {
                [void](Invoke-TestGit $fixture @('checkout','main'))
            }
            Assert-True (@($documentationReceiptValue.binding.dependency_manifest.path) -ccontains 'scripts/lib/DocumentationLinksDependency.psm1') 'Affected leaf dependency manifest omitted a tracked transitive imported module.'
            Assert-True (@($documentationReceiptValue.binding.dependency_manifest.path) -ccontains 'schemas/DocumentationLinksInput.schema.json') 'Affected leaf dependency manifest omitted a tracked schema/data input.'
            Assert-True ([string]$documentationReceiptValue.binding.dependency_resolution.mode -ceq 'all-tracked-scripts-fallback' -and @($documentationReceiptValue.binding.dependency_resolution.fallback_reasons | Where-Object { $_.importer -ceq 'scripts/Test-DocumentationLinks.ps1' -and $_.variable -ceq 'UnresolvedModulePath' -and $_.kind -ceq 'unresolved-import' }).Count -eq 1) 'Unknown dynamic Import-Module did not bind its exact all-scripts fallback reason.'
            Assert-True (@($documentationReceiptValue.binding.dependency_manifest.path) -ccontains 'scripts/Test-PublicBoundary.ps1') 'Dynamic Import-Module did not conservatively bind unresolved tracked PowerShell sources.'
            Assert-True (@($documentationReceiptValue.binding.dependency_manifest.path) -ccontains 'scripts/FallbackDynamicTarget.ps1' -and @($documentationReceiptValue.binding.dependency_manifest.path) -ccontains 'schemas/FallbackDynamicInput.schema.json') 'Dynamic fallback did not traverse its added target into the tracked non-PowerShell input.'
            $schemaDamagedBinding = $documentationReceiptValue.binding | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
            $schemaRecord = @($schemaDamagedBinding.dependency_manifest | Where-Object path -ceq 'schemas/FallbackDynamicInput.schema.json')
            Assert-True ($schemaRecord.Count -eq 1) 'Schema-drift fixture did not resolve one dependency record.'
            $schemaRecord[0].blob = ('f' * 40)
            $schemaDamagedSha = Get-MorphospaceCanonicalJsonSha256 -Value $schemaDamagedBinding
            $schemaReuse = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $firstCheckRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $schemaDamagedBinding -ExpectedBindingSha256 $schemaDamagedSha -RepositoryRoot $fixture -CurrentHeadCommit $docsHead -CandidateReceiptPaths @($documentationReceipt[0].FullName)
            Assert-True ($null -eq $schemaReuse) 'Tracked schema/input drift reused evidence from a different dependency binding.'
            $resolutionDamagedBinding = $documentationReceiptValue.binding | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
            $resolutionDamageTargets = @($resolutionDamagedBinding.dependency_resolution.fallback_reasons | Where-Object {
                [string]$_.importer -ceq 'scripts/Test-DocumentationLinks.ps1' -and
                [string]$_.variable -ceq 'UnresolvedModulePath' -and
                [string]$_.kind -ceq 'unresolved-import'
            })
            Assert-True ($resolutionDamageTargets.Count -eq 1) 'Dynamic dependency-resolution damage fixture did not select exactly one keyed fallback reason.'
            $resolutionDamageTargets[0].kind = 'unresolved-invocation'
            $resolutionDamagedSha = Get-MorphospaceCanonicalJsonSha256 -Value $resolutionDamagedBinding
            $resolutionReuse = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $firstCheckRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $resolutionDamagedBinding -ExpectedBindingSha256 $resolutionDamagedSha -RepositoryRoot $fixture -CurrentHeadCommit $docsHead -CandidateReceiptPaths @($documentationReceipt[0].FullName)
            Assert-True ($null -eq $resolutionReuse) 'Dynamic dependency-resolution reason drift reused evidence from a different binding.'
            $singleReadInventory = Read-MorphospaceAffectedCheckInventory -EvidenceDirectory $firstCheckRoot -ExpectedProducerContext $firstInventory.producer -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json')
            $singleReadDocumentationSnapshot = @($singleReadInventory.candidate_snapshots | Where-Object check_id -ceq 'documentation-links')
            Assert-True ($singleReadDocumentationSnapshot.Count -eq 1) 'Parent inventory did not snapshot exactly one documentation receipt.'
            $singleReadValidated = Test-MorphospaceAffectedCheckReceipt -ReceiptPath $documentationReceipt[0].FullName -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $documentationReceiptValue.binding -ExpectedBindingSha256 ([string]$documentationReceiptValue.binding_sha256) -RepositoryRoot $fixture -CurrentHeadCommit $docsHead -PriorEvidenceRoot $firstCheckRoot -CandidateSnapshot $singleReadDocumentationSnapshot[0]
            Assert-True ($null -ne $singleReadValidated -and [string]$singleReadValidated.receipt.binding.check_id -ceq 'documentation-links') 'Inventory-snapshotted receipt did not validate from its already-read bytes.'

            # Current-run evidence stays in immutable parent snapshots until
            # every child exits.  Mutating the source object after retention
            # must not turn a captured code failure into a passing cache row.
            $immutableFailureReceipt = $documentationReceiptValue | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
            $immutableFailureReceipt.mode = 'executed'; $immutableFailureReceipt.result = 'code-fail'; $immutableFailureReceipt.child.failure_kind = 'exit-code'; $immutableFailureReceipt.child.exit_code = 17; $immutableFailureReceipt.artifacts = @(); $immutableFailureReceipt.reused_from = $null
            foreach ($stream in @('stdout','stderr')) { $immutableFailureReceipt.child.$stream.bytes = 0; $immutableFailureReceipt.child.$stream.sha256 = Get-MorphospaceAffectedCheckBytesSha256 ([byte[]]::new(0)) }
            $immutableSnapshot = New-MorphospaceAffectedCheckSnapshot -Receipt $immutableFailureReceipt -Stdout ([byte[]]::new(0)) -Stderr ([byte[]]::new(0)) -Artifacts @() -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json')
            $immutableFailureReceipt.result = 'pass'; $immutableFailureReceipt.child.exit_code = 0
            $immutableRoot = Join-Path $fixture 'affected-check-evidence-parent-snapshot-immutable'
            [void](Write-MorphospaceAffectedCheckCache -EvidenceDirectory $immutableRoot -Snapshots @($immutableSnapshot) -Producer $firstInventory.producer -Source $firstInventory.source -PlanSha256 ([string]$firstInventory.plan_sha256) -Platform linux -ReceiptSchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json'))
            $immutableMaterialized = Get-Content -LiteralPath (Join-Path $immutableRoot 'documentation-links/receipt.json') -Raw | ConvertFrom-Json -Depth 64 -DateKind String
            Assert-True ($immutableMaterialized.result -ceq 'code-fail' -and $immutableMaterialized.child.exit_code -eq 17) 'A later mutation changed a parent-retained current-run receipt before cache materialization.'
            $wrongPlanReceipt = $documentationReceiptValue | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
            $wrongPlanReceipt.plan_sha256 = ('f' * 64)
            $wrongPlanSnapshot = New-MorphospaceAffectedCheckSnapshot -Receipt $wrongPlanReceipt -Stdout ([IO.File]::ReadAllBytes((Join-Path $documentationReceipt[0].DirectoryName 'stdout.bin'))) -Stderr ([IO.File]::ReadAllBytes((Join-Path $documentationReceipt[0].DirectoryName 'stderr.bin'))) -Artifacts @() -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json')
            Assert-AffectedThrows { [void](Write-MorphospaceAffectedCheckCache -EvidenceDirectory (Join-Path $fixture 'affected-check-evidence-wrong-fresh-plan') -Snapshots @($wrongPlanSnapshot) -Producer $firstInventory.producer -Source $firstInventory.source -PlanSha256 ([string]$firstInventory.plan_sha256) -Platform linux -ReceiptSchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json')) } '*fresh receipt plan identity differs*' 'A fresh receipt with a different plan identity was materialized under the current inventory plan.'

            # A failed first attempt may retain exact passing selector sibling
            # artifacts even when its verifier never runs.  A fresh attempt
            # restores those bound bytes before verifier dispatch.
            $phaseArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($phase in @('trust-self-executor','trust-routing-contracts','trust-proportional-mappings','trust-damage-final')) {
                $phaseBinding = [pscustomobject][ordered]@{repository=[string]$documentationReceiptValue.binding.repository;base_commit=[string]$documentationReceiptValue.source.base.commit;head_commit=$docsHead;head_tree=(Invoke-TestGit $fixture @('rev-parse','HEAD^{tree}'));plan_sha256=[string]$documentationReceiptValue.plan_sha256;platform=[string]$documentationReceiptValue.binding.platform;check_id=[string]$documentationReceiptValue.binding.check_id;phase_id=$phase;runner=$documentationReceiptValue.binding.runner;dependency_manifest=@($documentationReceiptValue.binding.dependency_manifest)}
                $phaseBindingSha = Get-MorphospaceCanonicalJsonSha256 -Value $phaseBinding
                $phaseStdoutBytes=[Text.UTF8Encoding]::new($false).GetBytes("$phase stdout")
                $phaseStderrBytes=[byte[]]::new(0)
                $phaseStarted='2026-09-01T00:00:00Z'
                $startDocument=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_self_test_phase_start.v1';phase_id=$phase;binding=$phaseBinding;binding_sha256=$phaseBindingSha;started_at=$phaseStarted;budget_seconds=75}
                $terminalDocument=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_self_test_phase_receipt.v1';phase_id=$phase;binding=$phaseBinding;binding_sha256=$phaseBindingSha;started_at=$phaseStarted;ended_at='2026-09-01T00:00:01Z';budget_seconds=75;elapsed_ms=1000;result='pass';child=[pscustomobject][ordered]@{started=$true;exit_code=0;timed_out=$false;post_kill_drain_timed_out=$false;stdout=[pscustomobject][ordered]@{path="$phase.stdout.bin";bytes=[long]$phaseStdoutBytes.Length;sha256=Get-MorphospaceAffectedCheckBytesSha256 $phaseStdoutBytes};stderr=[pscustomobject][ordered]@{path="$phase.stderr.bin";bytes=0;sha256=Get-MorphospaceAffectedCheckBytesSha256 $phaseStderrBytes}};outputs=@();claims=[pscustomobject][ordered]@{phase_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}}
                $startBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $startDocument) + "`n")
                $terminalBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $terminalDocument) + "`n")
                $phaseArtifacts.Add([pscustomobject][ordered]@{path="$phase.start.json";bytes=$startBytes})
                $phaseArtifacts.Add([pscustomobject][ordered]@{path="$phase.stdout.bin";bytes=$phaseStdoutBytes})
                $phaseArtifacts.Add([pscustomobject][ordered]@{path="$phase.stderr.bin";bytes=$phaseStderrBytes})
                $phaseArtifacts.Add([pscustomobject][ordered]@{path="$phase.terminal.json";bytes=$terminalBytes})
            }
            $artifactReceipt = $documentationReceiptValue | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
            $artifactReceipt.artifacts = @(Get-MorphospaceAffectedCheckArtifactReferences -Artifacts @($phaseArtifacts.ToArray()))
            $artifactSnapshot = New-MorphospaceAffectedCheckSnapshot -Receipt $artifactReceipt -Stdout ([IO.File]::ReadAllBytes((Join-Path $documentationReceipt[0].DirectoryName 'stdout.bin'))) -Stderr ([IO.File]::ReadAllBytes((Join-Path $documentationReceipt[0].DirectoryName 'stderr.bin'))) -Artifacts @($phaseArtifacts.ToArray()) -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json')
            $artifactCacheRoot = Join-Path $fixture 'affected-check-evidence-phase-artifacts-attempt1'
            [void](Write-MorphospaceAffectedCheckCache -EvidenceDirectory $artifactCacheRoot -Snapshots @($artifactSnapshot) -Producer $firstInventory.producer -Source $firstInventory.source -PlanSha256 ([string]$firstInventory.plan_sha256) -Platform linux -ReceiptSchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json'))
            $artifactInventory = Read-MorphospaceAffectedCheckInventory -EvidenceDirectory $artifactCacheRoot -ExpectedProducerContext $firstInventory.producer -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json')
            $artifactReusable = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $artifactCacheRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $documentationReceiptValue.binding -ExpectedBindingSha256 ([string]$documentationReceiptValue.binding_sha256) -RepositoryRoot $fixture -CurrentHeadCommit $docsHead -CandidateEvidenceSnapshots @($artifactInventory.candidate_snapshots)
            Assert-True ($null -ne $artifactReusable -and @($artifactReusable.artifacts).Count -eq 16) 'First-attempt selector sibling artifacts were not reusable from immutable inventory snapshots.'
            $phaseEvidenceModule = Get-Module -Name MorphospaceAffectedValidationCheckEvidence | Select-Object -First 1
            Assert-True ($null -ne $phaseEvidenceModule) 'Affected phase-artifact verifier module is not loaded for focused damage validation.'
            $phaseReceiptSchemaPath = Join-Path $repoRoot 'schemas/affected-validation-self-test-phase-receipt-v1.schema.json'
            $trustPhaseArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($phaseArtifact in @($phaseArtifacts.ToArray() | Where-Object { [string]$_.path -like 'trust-self-executor.*' })) { $trustPhaseArtifacts.Add([pscustomobject][ordered]@{path=[string]$phaseArtifact.path;bytes=[byte[]]([byte[]]$phaseArtifact.bytes).Clone()}) }
            [void](& $phaseEvidenceModule { param($Artifacts,$Binding,$Source,$PlanSha256,$SchemaPath) Assert-MorphospaceAffectedCheckPhaseArtifactSet -Artifacts $Artifacts -Phase 'trust-self-executor' -ExpectedBinding $Binding -ExpectedSource $Source -ExpectedPlanSha256 $PlanSha256 -PhaseReceiptSchemaPath $SchemaPath } @($trustPhaseArtifacts.ToArray()) $documentationReceiptValue.binding $documentationReceiptValue.source $documentationReceiptValue.plan_sha256 $phaseReceiptSchemaPath)
            Assert-AffectedThrows { [void](& $phaseEvidenceModule { param($Artifacts,$Binding,$Source,$PlanSha256,$SchemaPath) Assert-MorphospaceAffectedCheckPhaseArtifactSet -Artifacts $Artifacts -Phase 'trust-self-executor' -ExpectedBinding $Binding -ExpectedSource $Source -ExpectedPlanSha256 $PlanSha256 -PhaseReceiptSchemaPath $SchemaPath } @($trustPhaseArtifacts.ToArray()) $documentationReceiptValue.binding $documentationReceiptValue.source ('f'*64) $phaseReceiptSchemaPath) } '*original plan identity*' 'Phase-artifact verifier accepted a phase receipt under a different enclosing original plan.'

            $chronologyDamagedPhaseArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($phaseArtifact in @($trustPhaseArtifacts.ToArray())) {
                [byte[]]$phaseBytes = [byte[]]([byte[]]$phaseArtifact.bytes).Clone()
                if ([string]$phaseArtifact.path -ceq 'trust-self-executor.terminal.json') {
                    $chronologyDamage = [Text.UTF8Encoding]::new($false,$true).GetString($phaseBytes) | ConvertFrom-Json -Depth 64 -DateKind String
                    $chronologyDamage.ended_at = '2025-12-31T23:59:59Z'
                    $phaseBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $chronologyDamage) + "`n")
                }
                $chronologyDamagedPhaseArtifacts.Add([pscustomobject][ordered]@{path=[string]$phaseArtifact.path;bytes=$phaseBytes})
            }
            Assert-AffectedThrows { [void](& $phaseEvidenceModule { param($Artifacts,$Binding,$Source,$PlanSha256,$SchemaPath) Assert-MorphospaceAffectedCheckPhaseArtifactSet -Artifacts $Artifacts -Phase 'trust-self-executor' -ExpectedBinding $Binding -ExpectedSource $Source -ExpectedPlanSha256 $PlanSha256 -PhaseReceiptSchemaPath $SchemaPath } @($chronologyDamagedPhaseArtifacts.ToArray()) $documentationReceiptValue.binding $documentationReceiptValue.source $documentationReceiptValue.plan_sha256 $phaseReceiptSchemaPath) } '*chronology or budget*' 'Phase-artifact verifier accepted an impossible terminal chronology.'

            $streamDamagedPhaseArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($phaseArtifact in @($trustPhaseArtifacts.ToArray())) {
                [byte[]]$phaseBytes = [byte[]]([byte[]]$phaseArtifact.bytes).Clone()
                if ([string]$phaseArtifact.path -ceq 'trust-self-executor.stdout.bin') { $phaseBytes = @($phaseBytes + [byte]33) }
                $streamDamagedPhaseArtifacts.Add([pscustomobject][ordered]@{path=[string]$phaseArtifact.path;bytes=$phaseBytes})
            }
            Assert-AffectedThrows { [void](& $phaseEvidenceModule { param($Artifacts,$Binding,$Source,$PlanSha256,$SchemaPath) Assert-MorphospaceAffectedCheckPhaseArtifactSet -Artifacts $Artifacts -Phase 'trust-self-executor' -ExpectedBinding $Binding -ExpectedSource $Source -ExpectedPlanSha256 $PlanSha256 -PhaseReceiptSchemaPath $SchemaPath } @($streamDamagedPhaseArtifacts.ToArray()) $documentationReceiptValue.binding $documentationReceiptValue.source $documentationReceiptValue.plan_sha256 $phaseReceiptSchemaPath) } '*terminal reference differs from artifact bytes*' 'Phase-artifact verifier accepted stream bytes that differ from the inner terminal reference.'

            $startDamagedPhaseArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($phaseArtifact in @($trustPhaseArtifacts.ToArray())) {
                [byte[]]$phaseBytes = [byte[]]([byte[]]$phaseArtifact.bytes).Clone()
                if ([string]$phaseArtifact.path -ceq 'trust-self-executor.start.json') {
                    $startDamage = [Text.UTF8Encoding]::new($false,$true).GetString($phaseBytes) | ConvertFrom-Json -Depth 64 -DateKind String
                    $startDamage | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
                    $phaseBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $startDamage) + "`n")
                }
                $startDamagedPhaseArtifacts.Add([pscustomobject][ordered]@{path=[string]$phaseArtifact.path;bytes=$phaseBytes})
            }
            Assert-AffectedThrows { [void](& $phaseEvidenceModule { param($Artifacts,$Binding,$Source,$PlanSha256,$SchemaPath) Assert-MorphospaceAffectedCheckPhaseArtifactSet -Artifacts $Artifacts -Phase 'trust-self-executor' -ExpectedBinding $Binding -ExpectedSource $Source -ExpectedPlanSha256 $PlanSha256 -PhaseReceiptSchemaPath $SchemaPath } @($startDamagedPhaseArtifacts.ToArray()) $documentationReceiptValue.binding $documentationReceiptValue.source $documentationReceiptValue.plan_sha256 $phaseReceiptSchemaPath) } '*exact closed shape*' 'Phase-artifact verifier accepted an unknown start-receipt field.'

            $terminalDamagedPhaseArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($phaseArtifact in @($trustPhaseArtifacts.ToArray())) {
                [byte[]]$phaseBytes = [byte[]]([byte[]]$phaseArtifact.bytes).Clone()
                if ([string]$phaseArtifact.path -ceq 'trust-self-executor.terminal.json') {
                    $terminalDamage = [Text.UTF8Encoding]::new($false,$true).GetString($phaseBytes) | ConvertFrom-Json -Depth 64 -DateKind String
                    $terminalDamage.claims.candidate_admission = $true
                    $phaseBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $terminalDamage) + "`n")
                }
                $terminalDamagedPhaseArtifacts.Add([pscustomobject][ordered]@{path=[string]$phaseArtifact.path;bytes=$phaseBytes})
            }
            Assert-AffectedThrows { [void](& $phaseEvidenceModule { param($Artifacts,$Binding,$Source,$PlanSha256,$SchemaPath) Assert-MorphospaceAffectedCheckPhaseArtifactSet -Artifacts $Artifacts -Phase 'trust-self-executor' -ExpectedBinding $Binding -ExpectedSource $Source -ExpectedPlanSha256 $PlanSha256 -PhaseReceiptSchemaPath $SchemaPath } @($terminalDamagedPhaseArtifacts.ToArray()) $documentationReceiptValue.binding $documentationReceiptValue.source $documentationReceiptValue.plan_sha256 $phaseReceiptSchemaPath) } '*schema*' 'Phase-artifact verifier accepted a terminal that claimed candidate admission.'

            $orphanPhaseArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($phaseArtifact in @($trustPhaseArtifacts.ToArray())) { $orphanPhaseArtifacts.Add([pscustomobject][ordered]@{path=[string]$phaseArtifact.path;bytes=[byte[]]([byte[]]$phaseArtifact.bytes).Clone()}) }
            $orphanPhaseArtifacts.Add([pscustomobject][ordered]@{path='trust-self-executor.orphan.bin';bytes=[Text.UTF8Encoding]::new($false).GetBytes('orphan')})
            Assert-AffectedThrows { [void](& $phaseEvidenceModule { param($Artifacts,$Binding,$Source,$PlanSha256,$SchemaPath) Assert-MorphospaceAffectedCheckPhaseArtifactSet -Artifacts $Artifacts -Phase 'trust-self-executor' -ExpectedBinding $Binding -ExpectedSource $Source -ExpectedPlanSha256 $PlanSha256 -PhaseReceiptSchemaPath $SchemaPath } @($orphanPhaseArtifacts.ToArray()) $documentationReceiptValue.binding $documentationReceiptValue.source $documentationReceiptValue.plan_sha256 $phaseReceiptSchemaPath) } '*unreferenced bytes*' 'Phase-artifact verifier accepted an artifact not referenced by the inner terminal.'
            $artifactCrossHeadReusable = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $artifactCacheRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $documentationReceiptValue.binding -ExpectedBindingSha256 ([string]$documentationReceiptValue.binding_sha256) -RepositoryRoot $fixture -CurrentHeadCommit $schedulingHead -CandidateEvidenceSnapshots @($artifactInventory.candidate_snapshots)
            Assert-True ($null -ne $artifactCrossHeadReusable -and @($artifactCrossHeadReusable.artifacts).Count -eq 16) 'Scheduling-only descendant head did not reuse phase artifacts bound to the exact receipt source head.'
            $generation2Receipt = $artifactCrossHeadReusable.receipt | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
            $generation2Receipt.mode = 'reused'
            $generation2Receipt.elapsed_ms = 0
            $generation2Receipt.result = 'pass'
            $generation2Receipt.blocked_by = @()
            $generation2Receipt.child.started = $false
            $generation2Receipt.child.exit_code = 0
            $generation2Receipt.child.timed_out = $false
            $generation2Receipt.child.output_truncated = $false
            $generation2Receipt.child.post_kill_drain_timed_out = $false
            $generation2Receipt.source = $artifactCrossHeadReusable.receipt.source
            $generation2Receipt.reused_from = [pscustomobject][ordered]@{receipt_sha256=[string]$artifactCrossHeadReusable.receipt_sha256;source_head=$artifactCrossHeadReusable.receipt.source.head}
            $generation2Snapshot = New-MorphospaceAffectedCheckSnapshot -Receipt $generation2Receipt -Stdout ([byte[]]$artifactCrossHeadReusable.stdout) -Stderr ([byte[]]$artifactCrossHeadReusable.stderr) -Artifacts @($artifactCrossHeadReusable.artifacts) -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json')
            $generation2Root = Join-Path $fixture 'affected-check-evidence-phase-artifacts-attempt2'
            [void](Write-MorphospaceAffectedCheckCache -EvidenceDirectory $generation2Root -Snapshots @($generation2Snapshot) -Producer $firstInventory.producer -Source ([pscustomobject][ordered]@{base=$schedulingPlan.base;head=$schedulingPlan.head}) -PlanSha256 ([string]$schedulingPlan.plan_sha256) -Platform linux -ReceiptSchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json'))
            $generation2Inventory = Read-MorphospaceAffectedCheckInventory -EvidenceDirectory $generation2Root -ExpectedProducerContext $firstInventory.producer -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json')
            $generation3Reusable = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $generation2Root -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $documentationReceiptValue.binding -ExpectedBindingSha256 ([string]$documentationReceiptValue.binding_sha256) -RepositoryRoot $fixture -CurrentHeadCommit $semanticHead -CandidateEvidenceSnapshots @($generation2Inventory.candidate_snapshots)
            Assert-True ($null -ne $generation3Reusable -and [string]$generation3Reusable.receipt.mode -ceq 'reused' -and [string]$generation3Reusable.receipt.source.head.commit -ceq $docsHead -and @($generation3Reusable.artifacts).Count -eq 16) 'A second-generation reused receipt relabeled ancestor phase artifacts or could not be reused by a third descendant generation.'
            $wrongHeadPhaseArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($phaseArtifact in @($phaseArtifacts.ToArray())) {
                [byte[]]$wrongHeadBytes = [byte[]]$phaseArtifact.bytes
                if ([string]$phaseArtifact.path -match '\.(?:start|terminal)\.json$') {
                    $wrongHeadDocument = [Text.UTF8Encoding]::new($false,$true).GetString($wrongHeadBytes) | ConvertFrom-Json -Depth 64 -DateKind String
                    $wrongHeadDocument.binding.head_commit = $schedulingHead
                    $wrongHeadDocument.binding.head_tree = $schedulingTree
                    $wrongHeadBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $wrongHeadDocument) + "`n")
                }
                $wrongHeadPhaseArtifacts.Add([pscustomobject][ordered]@{path=[string]$phaseArtifact.path;bytes=$wrongHeadBytes})
            }
            $wrongHeadArtifactReceipt = $documentationReceiptValue | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
            $wrongHeadArtifactReceipt.artifacts = @(Get-MorphospaceAffectedCheckArtifactReferences -Artifacts @($wrongHeadPhaseArtifacts.ToArray()))
            $wrongHeadArtifactSnapshot = New-MorphospaceAffectedCheckSnapshot -Receipt $wrongHeadArtifactReceipt -Stdout ([IO.File]::ReadAllBytes((Join-Path $documentationReceipt[0].DirectoryName 'stdout.bin'))) -Stderr ([IO.File]::ReadAllBytes((Join-Path $documentationReceipt[0].DirectoryName 'stderr.bin'))) -Artifacts @($wrongHeadPhaseArtifacts.ToArray()) -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json')
            $wrongHeadArtifactCacheRoot = Join-Path $fixture 'affected-check-evidence-phase-artifacts-wrong-source-head'
            [void](Write-MorphospaceAffectedCheckCache -EvidenceDirectory $wrongHeadArtifactCacheRoot -Snapshots @($wrongHeadArtifactSnapshot) -Producer $firstInventory.producer -Source $firstInventory.source -PlanSha256 ([string]$firstInventory.plan_sha256) -Platform linux -ReceiptSchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json'))
            $wrongHeadArtifactInventory = Read-MorphospaceAffectedCheckInventory -EvidenceDirectory $wrongHeadArtifactCacheRoot -ExpectedProducerContext $firstInventory.producer -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json')
            $wrongHeadArtifactReuse = Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $wrongHeadArtifactCacheRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $documentationReceiptValue.binding -ExpectedBindingSha256 ([string]$documentationReceiptValue.binding_sha256) -RepositoryRoot $fixture -CurrentHeadCommit $schedulingHead -CandidateEvidenceSnapshots @($wrongHeadArtifactInventory.candidate_snapshots)
            Assert-True ($null -eq $wrongHeadArtifactReuse) 'Phase artifacts rebound to a descendant current head were accepted under an older receipt source identity.'
            $attempt2PhaseRoot = Join-Path $fixture 'affected-selector-phases-attempt2'
            Restore-MorphospaceAffectedCheckArtifacts -PhaseEvidenceRoot $attempt2PhaseRoot -Artifacts @($artifactReusable.artifacts)
            foreach ($phase in @('trust-self-executor','trust-routing-contracts','trust-proportional-mappings','trust-damage-final')) {
                $terminal = Get-Content -LiteralPath (Join-Path $attempt2PhaseRoot "$phase.terminal.json") -Raw | ConvertFrom-Json -Depth 64 -DateKind String
                Assert-True ($terminal.phase_id -ceq $phase -and $terminal.result -ceq 'pass' -and $terminal.binding.head_commit -ceq $docsHead) "Attempt-two verifier could not consume rehydrated '$phase' evidence."
            }
            $capturedTrustA = @(Get-MorphospaceAffectedCheckPhaseArtifacts -Check ([pscustomobject][ordered]@{command_path='scripts/Invoke-AffectedValidationSelfTestPhase.ps1';arguments=@('-Phase','trust-self-executor','-BudgetSeconds','75')}) -PhaseEvidenceRoot $attempt2PhaseRoot -ExpectedBinding $documentationReceiptValue.binding -ExpectedSource $documentationReceiptValue.source -ExpectedPlanSha256 ([string]$documentationReceiptValue.plan_sha256))
            Assert-True ($capturedTrustA.Count -eq 4 -and @($capturedTrustA.path) -ccontains 'trust-self-executor.terminal.json') 'Outer executor did not capture the exact inner selector phase artifact set.'
            $collisionPath = Join-Path $attempt2PhaseRoot 'trust-damage-final.stdout.bin'
            [byte[]]$collisionBytes = [Text.UTF8Encoding]::new($false).GetBytes('collision-preserved')
            [IO.File]::WriteAllBytes($collisionPath,$collisionBytes)
            Assert-AffectedThrows { Restore-MorphospaceAffectedCheckArtifacts -PhaseEvidenceRoot $attempt2PhaseRoot -Artifacts @($artifactReusable.artifacts) } '*collision differs*' 'Phase-artifact restoration overwrote a differing existing artifact.'
            Assert-True ((Get-MorphospaceAffectedCheckBytesSha256 ([IO.File]::ReadAllBytes($collisionPath))) -ceq (Get-MorphospaceAffectedCheckBytesSha256 $collisionBytes)) 'Phase-artifact collision changed existing bytes.'
            $restoreEscapeBytes = [Text.UTF8Encoding]::new($false).GetBytes('must-not-escape')
            $restoreOutsideRoot = Join-Path $fixture 'affected-selector-phase-restore-outside'
            [void][IO.Directory]::CreateDirectory($restoreOutsideRoot)
            $restoreRootLink = Join-Path $fixture 'affected-selector-phase-restore-root-link'
            try {
                if ($IsWindows) { [void](New-Item -ItemType Junction -Path $restoreRootLink -Target $restoreOutsideRoot) }
                else { [void](New-Item -ItemType SymbolicLink -Path $restoreRootLink -Target $restoreOutsideRoot) }
                Assert-AffectedThrows {
                    Restore-MorphospaceAffectedCheckArtifacts -PhaseEvidenceRoot $restoreRootLink -Artifacts @([pscustomobject][ordered]@{path='root-escape.bin';bytes=$restoreEscapeBytes})
                } '*reparse point*' 'Phase-artifact restoration accepted a reparse-point evidence root.'
                Assert-True (-not [IO.File]::Exists((Join-Path $restoreOutsideRoot 'root-escape.bin'))) 'Phase-artifact restoration wrote through a reparse-point evidence root.'
            } finally { if ([IO.Directory]::Exists($restoreRootLink)) { Remove-Item -LiteralPath $restoreRootLink -Force } }
            $restoreSafeRoot = Join-Path $fixture 'affected-selector-phase-restore-safe-root'
            [void][IO.Directory]::CreateDirectory($restoreSafeRoot)
            $restoreParentLink = Join-Path $restoreSafeRoot 'nested'
            try {
                if ($IsWindows) { [void](New-Item -ItemType Junction -Path $restoreParentLink -Target $restoreOutsideRoot) }
                else { [void](New-Item -ItemType SymbolicLink -Path $restoreParentLink -Target $restoreOutsideRoot) }
                Assert-AffectedThrows {
                    Restore-MorphospaceAffectedCheckArtifacts -PhaseEvidenceRoot $restoreSafeRoot -Artifacts @([pscustomobject][ordered]@{path='nested/parent-escape.bin';bytes=$restoreEscapeBytes})
                } '*reparse point*' 'Phase-artifact restoration accepted a reparse-point destination parent.'
                Assert-True (-not [IO.File]::Exists((Join-Path $restoreOutsideRoot 'parent-escape.bin'))) 'Phase-artifact restoration wrote through a reparse-point destination parent.'
            } finally { if ([IO.Directory]::Exists($restoreParentLink)) { Remove-Item -LiteralPath $restoreParentLink -Force } }
            $restoreAncestorLink = Join-Path $fixture 'affected-selector-phase-restore-ancestor-link'
            $restoreMissingRoot = Join-Path $restoreAncestorLink 'missing-root'
            try {
                if ($IsWindows) { [void](New-Item -ItemType Junction -Path $restoreAncestorLink -Target $restoreOutsideRoot) }
                else { [void](New-Item -ItemType SymbolicLink -Path $restoreAncestorLink -Target $restoreOutsideRoot) }
                Assert-AffectedThrows {
                    Restore-MorphospaceAffectedCheckArtifacts -PhaseEvidenceRoot $restoreMissingRoot -Artifacts @([pscustomobject][ordered]@{path='ancestor-escape.bin';bytes=$restoreEscapeBytes})
                } '*reparse point*' 'Phase-artifact restoration created a missing evidence root through a reparse-point ancestor.'
                Assert-True (-not [IO.Directory]::Exists((Join-Path $restoreOutsideRoot 'missing-root'))) 'Phase-artifact restoration created a missing root through a reparse-point ancestor.'
                Assert-True (-not [IO.File]::Exists((Join-Path $restoreOutsideRoot 'missing-root/ancestor-escape.bin'))) 'Phase-artifact restoration wrote through a reparse-point ancestor outside its evidence root.'
            } finally { if ([IO.Directory]::Exists($restoreAncestorLink)) { Remove-Item -LiteralPath $restoreAncestorLink -Force } }
            $reuseEvidencePath = Join-Path $fixture 'affected-evidence-reused.json'
            $reuseCheckRoot = Join-Path $fixture 'affected-check-evidence-reused'
            $reusedEvidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -OutPath $reuseEvidencePath -CheckEvidenceDirectory $reuseCheckRoot -PriorEvidenceDirectory $firstCheckRoot
            Assert-True ($reusedEvidence.result -ceq 'pass') 'Affected executor did not accept exact dependency-bound reusable leaves.'
            $reusedReceipts = @(Get-ChildItem -LiteralPath $reuseCheckRoot -Filter receipt.json -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String })
            Assert-True ($reusedReceipts.Count -eq @($reusedEvidence.check_results).Count -and @($reusedReceipts | Where-Object mode -cne 'reused').Count -eq 0) 'Exact unchanged leaf evidence was replayed instead of reused.'
            Assert-True ([IO.File]::Exists((Join-Path $reuseCheckRoot 'inventory.json'))) 'Fully reused execution did not finalize a new parent-owned inventory.'

            # Snapshot every prior receipt before any child can run.  The first
            # leaf executes because its prior stream is invalid; that child
            # then mutates the future documentation receipt on disk.  The
            # documentation leaf must still consume the immutable in-memory
            # bytes captured by the parent before the first child started.
            $snapshotPriorRoot = Join-Path $fixture 'affected-check-evidence-snapshot-prior'
            Copy-Item -LiteralPath $firstCheckRoot -Destination $snapshotPriorRoot -Recurse
            $snapshotReceiptFiles = @(Get-ChildItem -LiteralPath $snapshotPriorRoot -Filter receipt.json -File -Recurse)
            $snapshotPublicReceipt = @($snapshotReceiptFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String).binding.check_id -ceq 'public-boundary' })
            $snapshotDocumentationReceipt = @($snapshotReceiptFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String).binding.check_id -ceq 'documentation-links' })
            Assert-True ($snapshotPublicReceipt.Count -eq 1 -and $snapshotDocumentationReceipt.Count -eq 1) 'Prior-snapshot mutation fixture did not resolve its two exact receipts.'
            $snapshotPublicStream = Join-Path $snapshotPublicReceipt[0].DirectoryName 'stdout.bin'
            [IO.File]::WriteAllBytes($snapshotPublicStream,[Text.UTF8Encoding]::new($false).GetBytes('force public-boundary execution'))
            Update-AffectedInventoryFileRecord -InventoryRoot $snapshotPriorRoot -FilePath $snapshotPublicStream
            $snapshotOutputRoot = Join-Path $fixture 'affected-check-evidence-snapshot-output'
            $snapshotEvidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture 'affected-evidence-snapshot.json') -CheckEvidenceDirectory $snapshotOutputRoot -PriorEvidenceDirectory $snapshotPriorRoot
            $snapshotOutputReceipts = @(Get-ChildItem -LiteralPath $snapshotOutputRoot -Filter receipt.json -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String })
            Assert-True ($snapshotEvidence.result -ceq 'pass' -and @($snapshotOutputReceipts | Where-Object { $_.binding.check_id -ceq 'public-boundary' -and $_.mode -ceq 'executed' }).Count -eq 1 -and @($snapshotOutputReceipts | Where-Object { $_.binding.check_id -ceq 'documentation-links' -and $_.mode -ceq 'reused' }).Count -eq 1) 'A child mutation changed a future reuse decision after the parent prior snapshot.'
            Assert-True ((Get-Content -LiteralPath $snapshotDocumentationReceipt[0].FullName -Raw) -ceq 'mutated after parent snapshot') 'Prior-snapshot fixture did not actually mutate the future on-disk receipt.'

            Assert-AffectedThrows {
                [void](Find-MorphospaceAffectedReusableCheckReceipt -PriorEvidenceDirectory $firstCheckRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ExpectedBinding $documentationReceiptValue.binding -ExpectedBindingSha256 ([string]$documentationReceiptValue.binding_sha256) -RepositoryRoot $fixture -CurrentHeadCommit $docsHead -CandidateReceiptPaths @($documentationReceipt[0].FullName,$documentationReceipt[0].FullName))
            } '*duplicate exact-binding*' 'Affected executor selected one of multiple exact-binding reusable receipts.'
            $sourceDamagedPriorRoot = Join-Path $fixture 'affected-check-evidence-source-damaged-prior'
            Copy-Item -LiteralPath $firstCheckRoot -Destination $sourceDamagedPriorRoot -Recurse
            $sourceDamagedReceiptFiles = @(Get-ChildItem -LiteralPath $sourceDamagedPriorRoot -Filter receipt.json -File -Recurse | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String).binding.check_id -ceq 'documentation-links' })
            Assert-True ($sourceDamagedReceiptFiles.Count -eq 1) 'Source-commit damage fixture did not select one documentation receipt.'
            $sourceDamagedReceiptPath = $sourceDamagedReceiptFiles[0].FullName
            $sourceDamagedReceipt = Get-Content -LiteralPath $sourceDamagedReceiptPath -Raw | ConvertFrom-Json -Depth 64 -DateKind String
            $sourceDamagedReceipt.source.head.commit = $runnerDriftHead
            $sourceDamagedReceipt.source.head.tree = $runnerDriftTree
            Write-Utf8 $sourceDamagedReceiptPath ((ConvertTo-MorphospaceCanonicalJson -Value $sourceDamagedReceipt) + "`n")
            Update-AffectedInventoryFileRecord -InventoryRoot $sourceDamagedPriorRoot -FilePath $sourceDamagedReceiptPath
            $sourceFallbackEvidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture 'affected-evidence-source-damaged.json') -CheckEvidenceDirectory (Join-Path $fixture 'affected-check-evidence-source-damaged-output') -PriorEvidenceDirectory $sourceDamagedPriorRoot
            $sourceFallbackReceipts = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'affected-check-evidence-source-damaged-output') -Filter receipt.json -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String })
            Assert-True ($sourceFallbackEvidence.result -ceq 'pass' -and @($sourceFallbackReceipts | Where-Object mode -ceq 'executed').Count -eq 1 -and @($sourceFallbackReceipts | Where-Object mode -ceq 'reused').Count -eq ($sourceFallbackReceipts.Count - 1)) 'Receipt source-commit blob damage did not rerun only the affected leaf.'
            foreach ($environmentDamage in @('count','hash','order','second-hop','unreviewed','leaf-count','leaf-hash','leaf-empty')) {
                $environmentPriorRoot = Join-Path $fixture "affected-check-evidence-environment-$environmentDamage-prior"
                Copy-Item -LiteralPath $firstCheckRoot -Destination $environmentPriorRoot -Recurse
                $environmentReceiptFiles = @(Get-ChildItem -LiteralPath $environmentPriorRoot -Filter receipt.json -File -Recurse | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String).binding.check_id -ceq 'documentation-links' })
                Assert-True ($environmentReceiptFiles.Count -eq 1) "Environment $environmentDamage damage fixture did not select one documentation receipt."
                $environmentReceiptPath = $environmentReceiptFiles[0].FullName
                $environmentReceipt = Get-Content -LiteralPath $environmentReceiptPath -Raw | ConvertFrom-Json -Depth 64 -DateKind String
                switch ($environmentDamage) {
                    'count' { $environmentReceipt.environment.supervisor_variable_count = [int]$environmentReceipt.environment.supervisor_variable_count + 1 }
                    'hash' { $environmentReceipt.environment.supervisor_sha256 = ('f' * 64) }
                    'order' {
                        Assert-True (@($environmentReceipt.environment.supervisor_variables).Count -gt 1) 'Environment order damage fixture has fewer than two supervisor variables.'
                        $variables=@($environmentReceipt.environment.supervisor_variables);$first=$variables[0];$variables[0]=$variables[1];$variables[1]=$first;$environmentReceipt.environment.supervisor_variables=$variables;$environmentReceipt.environment.supervisor_sha256=Get-MorphospaceCanonicalJsonSha256 -Value $variables
                    }
                    'second-hop' {
                        $exactSupervisor = @($environmentReceipt.environment.supervisor_variables | Where-Object { $_.source -ceq 'hosted-producer' -or $_.source -ceq 'launcher-owned' } | Select-Object -First 1)
                        Assert-True ($exactSupervisor.Count -eq 1) 'Environment second-hop damage fixture has no exact projected supervisor variable.'
                        $exactLeaf = @($environmentReceipt.environment.leaf_variables | Where-Object name -CEQ ([string]$exactSupervisor[0].name))
                        Assert-True ($exactLeaf.Count -eq 1) 'Environment second-hop damage fixture has no matching leaf variable.'
                        $exactLeaf[0].value_sha256 = if ([string]$exactLeaf[0].value_sha256 -ceq ('f' * 64)) { 'e' * 64 } else { 'f' * 64 }
                        $environmentReceipt.environment.leaf_sha256=Get-MorphospaceCanonicalJsonSha256 -Value @($environmentReceipt.environment.leaf_variables)
                    }
                    'unreviewed' {
                        $environmentReceipt.environment.supervisor_variables=@($environmentReceipt.environment.supervisor_variables)+[pscustomobject][ordered]@{name='ZZZ_WEF002_UNREVIEWED';source='host-runtime';value_sha256=('0'*64)}
                        $environmentReceipt.environment.supervisor_variable_count=@($environmentReceipt.environment.supervisor_variables).Count
                        $environmentReceipt.environment.supervisor_sha256=Get-MorphospaceCanonicalJsonSha256 -Value @($environmentReceipt.environment.supervisor_variables)
                    }
                    'leaf-count' { $environmentReceipt.environment.leaf_variable_count=[int]$environmentReceipt.environment.leaf_variable_count+1 }
                    'leaf-hash' { $environmentReceipt.environment.leaf_sha256=('f'*64) }
                    'leaf-empty' {
                        $environmentReceipt.environment.leaf_variable_count=0
                        $environmentReceipt.environment.leaf_sha256=$null
                        $environmentReceipt.environment.leaf_variables=@()
                    }
                }
                $environmentReceiptJson=ConvertTo-MorphospaceCanonicalJson -Value $environmentReceipt
                $environmentSchemaValid=Test-Json -Json $environmentReceiptJson -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction SilentlyContinue
                Assert-True ($(if($environmentDamage-ceq'leaf-empty'){-not$environmentSchemaValid}else{$environmentSchemaValid})) "Environment $environmentDamage schema classification differs from its closed damage contract."
                Write-Utf8 $environmentReceiptPath ($environmentReceiptJson + "`n")
                Update-AffectedInventoryFileRecord -InventoryRoot $environmentPriorRoot -FilePath $environmentReceiptPath
                $environmentOutputRoot = Join-Path $fixture "affected-check-evidence-environment-$environmentDamage-output"
                $environmentFallbackEvidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture "affected-evidence-environment-$environmentDamage.json") -CheckEvidenceDirectory $environmentOutputRoot -PriorEvidenceDirectory $environmentPriorRoot
                $environmentFallbackReceipts = @(Get-ChildItem -LiteralPath $environmentOutputRoot -Filter receipt.json -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String })
                Assert-True ($environmentFallbackEvidence.result -ceq 'pass' -and @($environmentFallbackReceipts | Where-Object { $_.binding.check_id -ceq 'documentation-links' -and $_.mode -ceq 'executed' }).Count -eq 1 -and @($environmentFallbackReceipts | Where-Object mode -ceq 'reused').Count -eq ($environmentFallbackReceipts.Count - 1)) "Schema-valid environment $environmentDamage damage aborted reuse instead of rerunning only its leaf."
            }
            $combinedStreamPriorRoot = Join-Path $fixture 'affected-check-evidence-combined-stream-prior'
            Copy-Item -LiteralPath $firstCheckRoot -Destination $combinedStreamPriorRoot -Recurse
            $combinedStreamReceiptFile = @(Get-ChildItem -LiteralPath $combinedStreamPriorRoot -Filter receipt.json -File -Recurse | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String).binding.check_id -ceq 'documentation-links' })
            Assert-True ($combinedStreamReceiptFile.Count -eq 1) 'Combined-stream damage fixture did not select one documentation receipt.'
            $combinedStreamReceiptPath=$combinedStreamReceiptFile[0].FullName;$combinedStreamDirectory=$combinedStreamReceiptFile[0].DirectoryName
            $combinedStreamReceipt=Get-Content -LiteralPath $combinedStreamReceiptPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
            [byte[]]$combinedStdout=[byte[]]::new(6291456);[byte[]]$combinedStderr=[byte[]]::new(5242880)
            $combinedStdoutPath=Join-Path $combinedStreamDirectory 'stdout.bin';$combinedStderrPath=Join-Path $combinedStreamDirectory 'stderr.bin'
            [IO.File]::WriteAllBytes($combinedStdoutPath,$combinedStdout);[IO.File]::WriteAllBytes($combinedStderrPath,$combinedStderr)
            $combinedStreamReceipt.child.stdout.bytes=$combinedStdout.Length;$combinedStreamReceipt.child.stdout.sha256=Get-MorphospaceAffectedCheckBytesSha256 $combinedStdout
            $combinedStreamReceipt.child.stderr.bytes=$combinedStderr.Length;$combinedStreamReceipt.child.stderr.sha256=Get-MorphospaceAffectedCheckBytesSha256 $combinedStderr
            $combinedStreamReceiptJson=ConvertTo-MorphospaceCanonicalJson -Value $combinedStreamReceipt
            Assert-True (Test-Json -Json $combinedStreamReceiptJson -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-check-evidence-v1.schema.json') -ErrorAction Stop) 'Combined-stream damage is not schema-valid as required by the semantic-cache test.'
            Write-Utf8 $combinedStreamReceiptPath ($combinedStreamReceiptJson+"`n")
            foreach($combinedPath in @($combinedStreamReceiptPath,$combinedStdoutPath,$combinedStderrPath)){Update-AffectedInventoryFileRecord -InventoryRoot $combinedStreamPriorRoot -FilePath $combinedPath}
            $combinedStreamOutputRoot=Join-Path $fixture 'affected-check-evidence-combined-stream-output'
            $combinedStreamFallbackEvidence=& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture 'affected-evidence-combined-stream.json') -CheckEvidenceDirectory $combinedStreamOutputRoot -PriorEvidenceDirectory $combinedStreamPriorRoot
            $combinedStreamFallbackReceipts=@(Get-ChildItem -LiteralPath $combinedStreamOutputRoot -Filter receipt.json -File -Recurse|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json -Depth 64 -DateKind String})
            Assert-True ($combinedStreamFallbackEvidence.result-ceq'pass'-and@($combinedStreamFallbackReceipts|Where-Object{$_.binding.check_id-ceq'documentation-links'-and$_.mode-ceq'executed'}).Count-eq1-and@($combinedStreamFallbackReceipts|Where-Object mode -ceq 'reused').Count-eq($combinedStreamFallbackReceipts.Count-1)) 'Schema-valid combined-stream cache damage aborted reuse instead of rerunning only its leaf.'
            $reparsePriorRoot = Join-Path $fixture 'affected-check-evidence-reparse-prior'
            try {
                if ($IsWindows) { [void](New-Item -ItemType Junction -Path $reparsePriorRoot -Target $firstCheckRoot) }
                else { [void](New-Item -ItemType SymbolicLink -Path $reparsePriorRoot -Target $firstCheckRoot) }
                Assert-AffectedThrows {
                    [void](Read-MorphospaceAffectedCheckInventory -EvidenceDirectory $reparsePriorRoot -ExpectedProducerContext $firstInventory.producer -InventorySchemaPath (Join-Path $repoRoot 'schemas/affected-validation-check-inventory-v1.schema.json'))
                } '*reparse point*' 'Affected executor accepted reusable evidence through a reparse-point root.'
            } finally { if ([IO.Directory]::Exists($reparsePriorRoot)) { Remove-Item -LiteralPath $reparsePriorRoot -Force } }
            $damagedPriorRoot = Join-Path $fixture 'affected-check-evidence-damaged-prior'
            Copy-Item -LiteralPath $firstCheckRoot -Destination $damagedPriorRoot -Recurse
            $damagedReceiptPath = @(Get-ChildItem -LiteralPath $damagedPriorRoot -Filter receipt.json -File -Recurse | Sort-Object FullName | Select-Object -First 1).FullName
            $damagedStreamPath = Join-Path ([IO.Path]::GetDirectoryName($damagedReceiptPath)) 'stdout.bin'
            [IO.File]::WriteAllBytes($damagedStreamPath,[Text.UTF8Encoding]::new($false).GetBytes('damaged prior stream'))
            Update-AffectedInventoryFileRecord -InventoryRoot $damagedPriorRoot -FilePath $damagedStreamPath
            $fallbackEvidencePath = Join-Path $fixture 'affected-evidence-damaged-prior.json'
            $fallbackCheckRoot = Join-Path $fixture 'affected-check-evidence-damaged-fallback'
            $fallbackEvidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -OutPath $fallbackEvidencePath -CheckEvidenceDirectory $fallbackCheckRoot -PriorEvidenceDirectory $damagedPriorRoot
            $fallbackReceipts = @(Get-ChildItem -LiteralPath $fallbackCheckRoot -Filter receipt.json -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String })
            Assert-True ($fallbackEvidence.result -ceq 'pass' -and @($fallbackReceipts | Where-Object mode -ceq 'executed').Count -eq 1 -and @($fallbackReceipts | Where-Object mode -ceq 'reused').Count -eq ($fallbackReceipts.Count - 1)) 'Damaged prior stream did not rerun only its exact leaf while reusing unaffected leaves.'
            $persistedEvidence = Read-MorphospaceProtocolJson -Path $evidencePath
            foreach ($case in $failureKindCases) {
                $validAggregateFailure = $persistedEvidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                $validAggregateFailure.result=$case.result
                $record=$validAggregateFailure.check_results[0];$record.mode='executed';$record.result=$case.result;$record.failure_kind=$case.kind
                foreach($field in @('started','exit_code','timed_out','output_truncated','post_kill_drain_timed_out')){$record.$field=$case.$field}
                Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $validAggregateFailure) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction Stop) "Aggregate evidence schema rejected truthful '$($case.kind)' precedence evidence."
                if($case.kind-ceq'infrastructure'){$preExecutionAggregate=$validAggregateFailure|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;$preExecutionAggregate.check_results[0].started=$false;$preExecutionAggregate.check_results[0].exit_code=$null;Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $preExecutionAggregate) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction Stop) 'Aggregate evidence schema rejected pre-execution infrastructure failure.'}
                foreach ($field in @($case.bound | Where-Object { $_ -cne 'mode' })) {
                    $damagedAggregateFailure = $validAggregateFailure | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
                    $damagedRecord=$damagedAggregateFailure.check_results[0]
                    switch ($field) {
                        'result' { $damagedRecord.result='pass' }
                        'started' { $damagedRecord.started=-not[bool]$damagedRecord.started }
                        'exit_code' { $damagedRecord.exit_code=0 }
                        'timed_out' { $damagedRecord.timed_out=-not[bool]$damagedRecord.timed_out }
                        'output_truncated' { $damagedRecord.output_truncated=-not[bool]$damagedRecord.output_truncated }
                        'post_kill_drain_timed_out' { $damagedRecord.post_kill_drain_timed_out=-not[bool]$damagedRecord.post_kill_drain_timed_out }
                        'failure_kind' { $damagedRecord.failure_kind=$case.competing }
                    }
                    Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $damagedAggregateFailure) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) "Aggregate evidence schema accepted '$($case.kind)' contradiction in '$field'."
                }
                foreach($candidateKind in $allFailureKinds){if([string]$candidateKind-ceq[string]$case.kind){continue};$crossKind=$validAggregateFailure|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64 -DateKind String;$crossKind.check_results[0].failure_kind=$candidateKind;$crossKindValid=Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $crossKind) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue;$intentionalPreIntegrityOverlap=$case.kind-ceq'launch'-and$candidateKind-ceq'infrastructure';Assert-True ($crossKindValid-eq$intentionalPreIntegrityOverlap) "Aggregate evidence cross-kind matrix mismatch: $($case.kind) -> $(if($null-eq$candidateKind){'null'}else{$candidateKind})."}
            }
            $aggregateExecutedPassWithoutStart=$persistedEvidence|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64;$aggregateExecutedPassWithoutStart.check_results[0].started=$false
            Assert-True (-not(Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $aggregateExecutedPassWithoutStart) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Aggregate schema accepted executed pass with started=false.'
            $aggregateReusedPass=$persistedEvidence|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64;$aggregateReusedPass.check_results[0].mode='reused';$aggregateReusedPass.check_results[0].started=$false
            Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $aggregateReusedPass) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction Stop) 'Aggregate schema rejected reused pass with started=false.'
            foreach($damage in @('started','result')){$damagedAggregateReused=$aggregateReusedPass|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64;if($damage-ceq'started'){$damagedAggregateReused.check_results[0].started=$true}else{$damagedAggregateReused.check_results[0].result='code-fail';$damagedAggregateReused.result='code-fail'};Assert-True (-not(Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $damagedAggregateReused) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) "Aggregate schema accepted reused contradiction in '$damage'."}
            $impossiblePass = $persistedEvidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            $impossiblePass.check_results[0].exit_code = 1
            Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $impossiblePass) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Evidence schema accepted pass with a nonzero child exit.'
            $impossibleDrainPass = $persistedEvidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            $impossibleDrainPass.check_results[0].post_kill_drain_timed_out = $true
            Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $impossibleDrainPass) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Evidence schema accepted pass with a post-kill drain timeout.'
            $drainCodeFailure = $persistedEvidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            $drainCodeFailure.result = 'code-fail'; $drainCodeFailure.check_results[0].result = 'code-fail'; $drainCodeFailure.check_results[0].started=$true; $drainCodeFailure.check_results[0].failure_kind='drain-timeout'; $drainCodeFailure.check_results[0].exit_code = $null; $drainCodeFailure.check_results[0].timed_out=$false; $drainCodeFailure.check_results[0].output_truncated=$false; $drainCodeFailure.check_results[0].post_kill_drain_timed_out = $true
            Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $drainCodeFailure) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction Stop) 'Evidence schema rejected the required code-fail post-kill drain shape.'
            $mixedFailure = $persistedEvidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            $mixedFailure.result = 'code-fail'; $mixedFailure.check_results[0].result = 'code-fail'; $mixedFailure.check_results[0].started=$true; $mixedFailure.check_results[0].failure_kind='exit-code'; $mixedFailure.check_results[0].exit_code = 1; $mixedFailure.check_results[1].result = 'infra-fail'; $mixedFailure.check_results[1].started=$false; $mixedFailure.check_results[1].failure_kind='launch'; $mixedFailure.check_results[1].exit_code = $null
            Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $mixedFailure) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Evidence schema accepted mixed code-fail and infra-fail aggregate precedence.'
            $impossiblePending = $persistedEvidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
            $impossiblePending.check_results[0].result = 'pending-infra'; $impossiblePending.result = 'pending-infra'
            Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $impossiblePending) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Check evidence accepted pending-infra outside the typed pre-job classifier.'
            $boundaryIndex = [array]::IndexOf(@($docsPlan.selected_checks.check_id), 'public-boundary')
            $documentationIndex = [array]::IndexOf(@($docsPlan.selected_checks.check_id), 'documentation-links')
            Assert-True ($boundaryIndex -ge 0 -and $documentationIndex -gt $boundaryIndex) 'Selected checks were not in deterministic prerequisite-first order.'
            $zeroFailed = $false
            try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform windows -OutPath (Join-Path $fixture 'zero-evidence.json')) } catch { $zeroFailed = $_.Exception.Message -like '*empty*selection*' }
            Assert-True $zeroFailed 'Affected executor accepted an empty platform selection.'
            $tamperedPlan = Read-MorphospaceProtocolJson -Path $planPath
            $tamperedPlan.plan_sha256 = ('0' * 64)
            Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $tamperedPlan) + "`n")
            $tamperFailed = $false
            try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture 'tampered-evidence.json')) } catch { $tamperFailed = $_.Exception.Message -like '*differs*' }
            Assert-True $tamperFailed 'Affected executor accepted a caller-tampered selection plan.'
            Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $docsPlan) + "`n")
        }
    }

    if ($runFullSelector -or $runExecutorNativeFailureDamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "exit 17`n"
    Write-Utf8 (Join-Path $fixture 'docs/executor-terminal-independent.md') "independent terminal-damage sibling`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1', 'docs/executor-terminal-independent.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'failing affected command'))
    $failingHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $failingPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $docsHead -HeadRevision $failingHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True (@($failingPlan.selected_checks.check_id) -ccontains 'documentation-links') 'Combined documentation/boundary fixture did not select the independent documentation check.'
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $failingPlan) + "`n")
    $failingEvidencePath = Join-Path $fixture 'failing-evidence.json'
    $codeFailed = $false
    $codeFailureRecord = $null
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $docsHead -HeadCommit $failingHead -PlanPath $planPath -Platform linux -OutPath $failingEvidencePath) } catch { $codeFailureRecord = $_; $codeFailed = $_.Exception.Message -like '*code-fail*' }
    $codeFailureObserved = if ($null -eq $codeFailureRecord) { '<no exception>' } else { [string]$codeFailureRecord.Exception.Message }
    Assert-True $codeFailed "Affected executor swallowed or reclassified a native nonzero exit. Observed: $codeFailureObserved"
    $failingEvidence = Read-MorphospaceProtocolJson -Path $failingEvidencePath
    Assert-True ($failingEvidence.result -ceq 'code-fail' -and @($failingEvidence.check_results | Where-Object { $_.exit_code -eq 17 -and $_.result -ceq 'code-fail' }).Count -eq 1) 'Affected executor did not preserve the native nonzero exit in evidence.'
    $failingCheckRoot = Join-Path $fixture "affected-check-evidence-$($failingPlan.plan_sha256)-linux"
    Assert-True ([IO.File]::Exists((Join-Path $failingCheckRoot 'inventory.json')) -and [string]$codeFailureRecord.Exception.Data['AffectedCacheFinalized'] -ceq 'true' -and [string]$codeFailureRecord.Exception.Data['AffectedInventorySha256'] -match '^[0-9a-f]{64}$') 'Ordinary code failure did not finalize independent leaf evidence for a later retry.'
    $failingReceipts = @(Get-ChildItem -LiteralPath $failingCheckRoot -Filter receipt.json -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String })
    $executedFailure = @($failingReceipts | Where-Object { $_.mode -ceq 'executed' -and $_.result -ceq 'code-fail' -and $_.child.exit_code -eq 17 })
    $blockedDependents = @($failingReceipts | Where-Object { $_.mode -ceq 'blocked' -and @($_.blocked_by).Count -gt 0 })
    Assert-True ($executedFailure.Count -eq 1) 'Affected executor did not preserve the exact failed leaf.'
    Assert-True ($blockedDependents.Count -eq 0) 'Execution-order-only anchor failure produced semantic blocked descendants.'
    $independentDocumentation = @($failingReceipts | Where-Object { $_.binding.check_id -ceq 'documentation-links' })
    Assert-True ($independentDocumentation.Count -eq 1 -and $independentDocumentation[0].mode -ceq 'executed' -and $independentDocumentation[0].result -ceq 'pass' -and @($independentDocumentation[0].blocked_by).Count -eq 0) 'Failed execution-order anchor blocked an independent documentation leaf.'
    $failedReceiptPath = @(Get-ChildItem -LiteralPath $failingCheckRoot -Filter receipt.json -File -Recurse | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 64 -DateKind String).result -ceq 'code-fail' } | Select-Object -First 1).FullName
    $failedReceipt = Get-Content -LiteralPath $failedReceiptPath -Raw | ConvertFrom-Json -Depth 64 -DateKind String
    foreach ($stream in @('stdout','stderr')) { $streamPath = Join-Path ([IO.Path]::GetDirectoryName($failedReceiptPath)) "$stream.bin"; Assert-True ([IO.File]::Exists($streamPath) -and (Get-FileHash -LiteralPath $streamPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$failedReceipt.child.$stream.sha256) "Failed leaf $stream bytes are unavailable or not receipt-bound." }
    $failedEvidenceDigest = (Get-FileHash -LiteralPath $failingEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($failedEvidenceDigest -match '^[0-9a-f]{64}$') 'Failed executor evidence did not receive a content digest.'
    }

    if ($runFullSelector -or $runExecutorParentContainmentDamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    $supervisorResidueBaseline = Get-AffectedSupervisorResidueIdentity
    $protectedParentSource = @'
if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { exit 91 }
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class W017TerminateParentDamage {
    [StructLayout(LayoutKind.Sequential)] private struct BasicInformation { public IntPtr exitStatus,peb,affinity,basePriority,processId,parentProcessId; }
    [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint low; public int high; }
    [StructLayout(LayoutKind.Sequential)] private struct LuidAttributes { public Luid luid; public uint attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct TokenPrivileges { public uint count; public LuidAttributes privilege; }
    [StructLayout(LayoutKind.Sequential)] private struct ThreadEntry32 { public uint size,usage,threadId,ownerProcessId; public int basePriority,deltaPriority; public uint flags; }
    [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(IntPtr process,int information,ref BasicInformation value,int length,IntPtr returned);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll",SetLastError=true)] private static extern IntPtr OpenProcess(uint access,bool inherit,int processId);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern IntPtr OpenThread(uint access,bool inherit,uint threadId);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags,uint processId);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool Thread32First(IntPtr snapshot,ref ThreadEntry32 entry);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool Thread32Next(IntPtr snapshot,ref ThreadEntry32 entry);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool TerminateProcess(IntPtr process,uint exitCode);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll",SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool LookupPrivilegeValue(string system,string name,out Luid value);
    [DllImport("advapi32.dll",SetLastError=true)] private static extern bool AdjustTokenPrivileges(IntPtr token,bool disableAll,ref TokenPrivileges value,uint length,IntPtr previous,IntPtr returned);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text,uint revision,out IntPtr descriptor,out uint length);
    [DllImport("advapi32.dll",SetLastError=true)] private static extern bool SetKernelObjectSecurity(IntPtr handle,uint information,IntPtr descriptor);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr value);
    [DllImport("kernel32.dll")] private static extern void SetLastError(uint value);
    private static int ParentId(){var value=new BasicInformation();if(NtQueryInformationProcess(GetCurrentProcess(),0,ref value,Marshal.SizeOf(typeof(BasicInformation)),IntPtr.Zero)!=0)throw new InvalidOperationException("parent identity unavailable");return value.parentProcessId.ToInt32();}
    private static bool TryReplace(IntPtr handle,string sddl,uint information){IntPtr descriptor;uint length;if(!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out descriptor,out length))return false;try{return SetKernelObjectSecurity(handle,information,descriptor);}finally{LocalFree(descriptor);}}
    private static bool CanEnable(Luid luid){IntPtr token;if(!OpenProcessToken(GetCurrentProcess(),0x28,out token))throw new InvalidOperationException("leaf token unavailable");try{var privileges=new TokenPrivileges{count=1,privilege=new LuidAttributes{luid=luid,attributes=2}};SetLastError(0);if(!AdjustTokenPrivileges(token,false,ref privileges,0,IntPtr.Zero,IntPtr.Zero))return false;return Marshal.GetLastWin32Error()!=1300;}finally{CloseHandle(token);}}
    private static bool CanEnable(string name){Luid luid;if(!LookupPrivilegeValue(null,name,out luid))throw new InvalidOperationException("privilege identity unavailable: "+name);return CanEnable(luid);}
    public static bool CanEnableRemoved(string encoded){var parts=(encoded??String.Empty).Split(':');if(parts.Length!=2)throw new InvalidOperationException("removed source privilege identity is malformed");var luid=new Luid{high=int.Parse(parts[0],System.Globalization.CultureInfo.InvariantCulture),low=uint.Parse(parts[1],System.Globalization.CultureInfo.InvariantCulture)};return CanEnable(luid);}
    public static string TryAttackAncestors(int[] ancestors){
        var parent=ParentId();
        if(ancestors==null||ancestors.Length<2||ancestors[0]!=parent)return "ANCESTOR_IDENTITY";
        uint futureThread,parentFutureThread;
        if(!uint.TryParse(Environment.GetEnvironmentVariable("RUSTY_AFFECTED_VALIDATION_FUTURE_THREAD_ID"),System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out futureThread)||futureThread==0)return "FUTURE_THREAD_IDENTITY";
        if(!uint.TryParse(Environment.GetEnvironmentVariable("RUSTY_AFFECTED_VALIDATION_PARENT_FUTURE_THREAD_ID"),System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out parentFutureThread)||parentFutureThread==0)return "PARENT_FUTURE_THREAD_IDENTITY";
        var seen=new System.Collections.Generic.HashSet<int>();
        var trusted=new System.Collections.Generic.HashSet<uint>();
        var ordinal=0;
        foreach(var target in ancestors){
            if(target<=0||!seen.Add(target))continue;
            trusted.Add(unchecked((uint)target));
            var writeDac=OpenProcess(0x00040000,false,target);
            if(writeDac!=IntPtr.Zero){try{TryReplace(writeDac,"D:(A;;GA;;;WD)",4);}finally{CloseHandle(writeDac);}return "PID_"+target+"_WRITE_DAC";}
            var writeOwner=OpenProcess(0x00080000,false,target);
            if(writeOwner!=IntPtr.Zero){try{TryReplace(writeOwner,"O:WD",1);}finally{CloseHandle(writeOwner);}return "PID_"+target+"_WRITE_OWNER";}
            var accesses=ordinal++==0?new uint[]{1,2,8,16,32,64,0x200,0x400,0x800,0x1000,0x2000}:new uint[]{1,2,8,32,64,0x200,0x400,0x800,0x1000,0x2000};
            foreach(var access in accesses){
                var handle=OpenProcess(access,false,target);
                if(handle==IntPtr.Zero)continue;
                try{if(access==0x400||access==0x1000||access==0x2000){foreach(var tokenAccess in new uint[]{0x8,0x2,0x4,0x20,0x2e}){IntPtr targetToken;if(OpenProcessToken(handle,tokenAccess,out targetToken)){CloseHandle(targetToken);return "PID_"+target+"_TOKEN_ACCESS_0x"+tokenAccess.ToString("x8");}}}if(access==1)TerminateProcess(handle,0);}
                finally{CloseHandle(handle);}
                return "PID_"+target+"_ACCESS_0x"+access.ToString("x8");
            }
        }
        var snapshot=CreateToolhelp32Snapshot(4,0);
        if(snapshot==new IntPtr(-1))return "THREAD_SNAPSHOT";
        var futureSeen=false;
        var parentFutureSeen=false;
        try{
            var entry=new ThreadEntry32();
            entry.size=(uint)Marshal.SizeOf(typeof(ThreadEntry32));
            if(Thread32First(snapshot,ref entry)){do{
                if(trusted.Contains(entry.ownerProcessId)){
                    if(entry.threadId==futureThread)futureSeen=true;
                    if(entry.threadId==parentFutureThread)parentFutureSeen=true;
                    foreach(var access in new uint[]{1,2,8,16,32,64,0x80,0x100,0x200,0x400,0x800,0x00040000,0x00080000}){
                        var thread=OpenThread(access,false,entry.threadId);
                        if(thread==IntPtr.Zero)continue;
                        CloseHandle(thread);
                        return "TID_"+entry.threadId+"_ACCESS_0x"+access.ToString("x8");
                    }
                }
                entry.size=(uint)Marshal.SizeOf(typeof(ThreadEntry32));
            }while(Thread32Next(snapshot,ref entry));}
        }finally{CloseHandle(snapshot);}
        if(!futureSeen)return "FUTURE_THREAD_NOT_OBSERVED";
        if(!parentFutureSeen)return "PARENT_FUTURE_THREAD_NOT_OBSERVED";
        foreach(var privilege in new string[]{"SeDebugPrivilege","SeTakeOwnershipPrivilege","SeRestorePrivilege"})if(CanEnable(privilege))return privilege;
        return null;
    }
}
"@
[int[]]$trustedAncestors = @($env:RUSTY_AFFECTED_VALIDATION_TRUSTED_ANCESTORS -split ',' | ForEach-Object { [int]::Parse($_,[Globalization.CultureInfo]::InvariantCulture) })
$attack = [W017TerminateParentDamage]::TryAttackAncestors($trustedAncestors)
if (-not [string]::IsNullOrWhiteSpace($attack)) { [Console]::Error.WriteLine("supervisor attack remained available: $attack"); Start-Sleep -Seconds 30; exit 90 }
$removedPrivilege = [Environment]::GetEnvironmentVariable('RUSTY_AFFECTED_VALIDATION_REMOVED_PRIVILEGE_LUID','Process')
if ([string]::IsNullOrWhiteSpace($removedPrivilege) -or [W017TerminateParentDamage]::CanEnableRemoved($removedPrivilege)) { [Console]::Error.WriteLine("a privilege enumerated on the source token was not proven irreversibly absent from the leaf token"); exit 90 }
exit 91
'@
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') $protectedParentSource
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'supervisor termination damage'))
    $protectedParentHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $protectedParentPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $docsHead -HeadRevision $protectedParentHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $protectedParentPlan) + "`n")
    $protectedParentEvidencePath = Join-Path $fixture 'protected-parent-evidence.json'
    $protectedParentFailure = $null
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $docsHead -HeadCommit $protectedParentHead -PlanPath $planPath -Platform linux -OutPath $protectedParentEvidencePath) } catch { $protectedParentFailure = $_ }
    $protectedParentObserved = if ($null -eq $protectedParentFailure) { '<no exception>' } else { "$($protectedParentFailure.Exception.ToString())`n$([string]$protectedParentFailure.ScriptStackTrace)" }
    Assert-True ([IO.File]::Exists($protectedParentEvidencePath)) "Protected-ancestor damage execution did not publish typed evidence. Observed: $protectedParentObserved"
    $protectedParentEvidence = Read-MorphospaceProtocolJson -Path $protectedParentEvidencePath
    $protectedParentResultSummary=@($protectedParentEvidence.check_results|ForEach-Object{"$($_.check_id):result=$($_.result),kind=$($_.failure_kind),exit=$($_.exit_code),stderr=$($_.stderr_sha256)"})-join'; '
    Assert-True ($null -ne $protectedParentFailure -and $protectedParentEvidence.result -ceq 'code-fail' -and @($protectedParentEvidence.check_results | Where-Object { $_.check_id -ceq 'public-boundary' -and $_.exit_code -eq 91 -and $_.result -ceq 'code-fail' }).Count -eq 1 -and (Get-AffectedSupervisorResidueIdentity) -ceq $supervisorResidueBaseline) "A Windows leaf retained process or thread owner/DACL rewrite, terminate/suspend/context/impersonation, handle duplication, process-query/token-open, or privilege re-enable access—including the post-probe sentinel thread—or changed the enclosing supervisor-residue identity. Observed: $protectedParentResultSummary Failure: $protectedParentObserved"
    $setupProbeExecutable = (Get-Process -Id $PID).Path
    $preContainmentProbe = [W017BoundedChildCapture]::RunForSetupFailureTest($setupProbeExecutable,$fixture,'before-containment',15000)
    Assert-True ($preContainmentProbe.Started -and $preContainmentProbe.ChildTreeCleanupAttempted -and $preContainmentProbe.ChildTreeCleanupSucceeded -and [string]$preContainmentProbe.Error -like '*injected pre-containment setup failure*') 'Pre-containment setup failure did not directly terminate and read back the unassigned supervisor.'
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        [W017BoundedChildCapture]::RunPublishedControlReadSelfTests()
        [W017BoundedChildCapture]::RunOwnedSupervisorDeletionSelfTests()
        $postJobProbe = [W017BoundedChildCapture]::RunForSetupFailureTest($setupProbeExecutable,$fixture,'after-job-create',15000)
        Assert-True ($postJobProbe.Started -and $postJobProbe.ChildTreeCleanupAttempted -and $postJobProbe.ChildTreeCleanupSucceeded -and [string]$postJobProbe.Error -like '*injected post-job-create setup failure*') 'Post-job-create assignment-boundary failure did not directly terminate and read back the unassigned supervisor.'
        $missingCompletionProbe = [W017BoundedChildCapture]::RunForSetupFailureTest($setupProbeExecutable,$fixture,'terminate-supervisor-after-go',15000)
        $missingCompletionObserved = "started=$($missingCompletionProbe.Started);cleanup_attempted=$($missingCompletionProbe.ChildTreeCleanupAttempted);cleanup_succeeded=$($missingCompletionProbe.ChildTreeCleanupSucceeded);exit=$($missingCompletionProbe.ExitCode);error=$([string]$missingCompletionProbe.Error)"
        Assert-True ($missingCompletionProbe.Started -and $missingCompletionProbe.ChildTreeCleanupAttempted -and $missingCompletionProbe.ChildTreeCleanupSucceeded -and [string]$missingCompletionProbe.Error -like '*tagged completion*') "A supervisor terminated with exit code zero was accepted without its private tagged completion. Observed: $missingCompletionObserved"
    }
    }

    if ($runFullSelector -or $runExecutorNativeExit125DamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "exit 125`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'leaf exit 125 damage'))
    $exit125Head = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $exit125Plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $docsHead -HeadRevision $exit125Head -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $exit125Plan) + "`n")
    $exit125EvidencePath = Join-Path $fixture 'exit-125-evidence.json'
    $exit125Failure = $null
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $docsHead -HeadCommit $exit125Head -PlanPath $planPath -Platform linux -OutPath $exit125EvidencePath) } catch { $exit125Failure = $_ }
    $exit125Evidence = Read-MorphospaceProtocolJson -Path $exit125EvidencePath
    Assert-True ($null -ne $exit125Failure -and $exit125Evidence.result -ceq 'code-fail' -and @($exit125Evidence.check_results | Where-Object { $_.check_id -ceq 'public-boundary' -and $_.exit_code -eq 125 -and $_.result -ceq 'code-fail' }).Count -eq 1 -and [string]$exit125Failure.Exception.Message -notlike '*infra-fail*') 'A native leaf exit 125 collided with the supervisor infrastructure-error domain.'
    }

    if ($runFullSelector -or $runExecutorForgedTerminalDamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    $forgedTerminalSource = @'
$supervisorRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($env:TEMP))
if(-not[IO.File]::Exists((Join-Path $supervisorRoot 'supervisor.ps1'))-or-not[IO.File]::Exists((Join-Path $supervisorRoot 'go.control'))){throw 'forged-terminal fixture did not resolve its exact supervisor directory'}
$forgedPath = Join-Path $supervisorRoot 'terminal.control'
[IO.File]::WriteAllText($forgedPath,"exit:0`n",[Text.UTF8Encoding]::new($false))
exit 23
'@
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') $forgedTerminalSource
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'forged terminal control damage'))
    $forgedHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $forgedPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $docsHead -HeadRevision $forgedHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $forgedPlan) + "`n")
    $forgedEvidencePath = Join-Path $fixture 'forged-terminal-evidence.json'
    $forgedFailure = $null
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $docsHead -HeadCommit $forgedHead -PlanPath $planPath -Platform linux -OutPath $forgedEvidencePath) } catch { $forgedFailure = $_ }
    $forgedEvidence = Read-MorphospaceProtocolJson -Path $forgedEvidencePath
    $forgedObserved = @($forgedEvidence.check_results | ForEach-Object { "$($_.check_id):result=$($_.result),exit=$($_.exit_code),timeout=$($_.timed_out),truncated=$($_.output_truncated),stdout=$($_.stdout_bytes),stderr=$($_.stderr_bytes)" }) -join '; '
    Assert-True ($null -ne $forgedFailure -and $forgedEvidence.result -ceq 'code-fail' -and @($forgedEvidence.check_results | Where-Object { $_.check_id -ceq 'public-boundary' -and $_.exit_code -eq 23 -and $_.result -ceq 'code-fail' }).Count -eq 1) "A leaf-forged terminal control file produced or obscured the real supervisor terminal. Observed: $forgedObserved"
    }

    if ($runFullSelector -or $runExecutorOutputCeilingDamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    $supervisorResidueBaseline = Get-AffectedSupervisorResidueIdentity
    $sustainedOutputSource = @'
for($index=0;$index-lt 4096;$index++){
    [Console]::Out.Write(('x'*65536));[Console]::Out.Flush()
    [Console]::Error.Write(('y'*65536));[Console]::Error.Flush()
}
throw 'sustained output unexpectedly reached its natural terminal'
'@
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') $sustainedOutputSource
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'oversized affected output'))
    $oversizedHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $oversizedPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $docsHead -HeadRevision $oversizedHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $oversizedPlan) + "`n")
    $oversizedEvidencePath = Join-Path $fixture 'oversized-evidence.json'
    $oversizedFailed = $false
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $docsHead -HeadCommit $oversizedHead -PlanPath $planPath -Platform linux -OutPath $oversizedEvidencePath) } catch { $oversizedFailed = $_.Exception.Message -like '*code-fail*' }
    Assert-True $oversizedFailed 'Affected executor accepted an over-ceiling child output.'
    $oversizedEvidence = Read-MorphospaceProtocolJson -Path $oversizedEvidencePath
    $oversizedObserved = @($oversizedEvidence.check_results | ForEach-Object { "$($_.check_id):result=$($_.result),exit=$($_.exit_code),timeout=$($_.timed_out),truncated=$($_.output_truncated),drain=$($_.post_kill_drain_timed_out),stdout=$($_.stdout_bytes),stderr=$($_.stderr_bytes)" }) -join '; '
    Assert-True ($oversizedEvidence.result -ceq 'code-fail' -and @($oversizedEvidence.check_results | Where-Object { $_.result -ceq 'code-fail' -and $_.output_truncated -and ($_.stdout_bytes + $_.stderr_bytes) -le 10485760 }).Count -eq 1 -and (Get-AffectedSupervisorResidueIdentity) -ceq $supervisorResidueBaseline) "Affected executor did not enforce the combined live output ceiling without unbounded staging or a changed enclosing supervisor-residue identity. Observed: $oversizedObserved"
    }

    if ($runFullSelector -or $runExecutorTimeoutDamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "Start-Sleep -Seconds 25`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'timed-out affected command'))
    $timeoutHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $timeoutPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $docsHead -HeadRevision $timeoutHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $timeoutPlan) + "`n")
    $timeoutEvidencePath = Join-Path $fixture 'timeout-evidence.json'
    $timeoutFailed = $false; $timeoutFailure = $null
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $docsHead -HeadCommit $timeoutHead -PlanPath $planPath -Platform linux -OutPath $timeoutEvidencePath) } catch { $timeoutFailure = $_; $timeoutFailed = $_.Exception.Message -like '*code-fail*' }
    $timeoutObserved = if ($null -eq $timeoutFailure) { '<no exception>' } else { [string]$timeoutFailure.Exception.Message }
    Assert-True $timeoutFailed "Affected executor accepted or misclassified a timed-out child. Observed: $timeoutObserved"
    $timeoutEvidence = Read-MorphospaceProtocolJson -Path $timeoutEvidencePath
    Assert-True ($timeoutEvidence.result -ceq 'code-fail' -and @($timeoutEvidence.check_results | Where-Object { $_.result -ceq 'code-fail' -and $_.timed_out }).Count -eq 1) 'Affected executor did not classify a child timeout as code-fail.'
    }

    if ($runFullSelector -or $runExecutorDualStreamDamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    $restoredHead = $docsHead
    $dualStreamSource = @'
for($index=0;$index-lt 8;$index++){
    [Console]::Out.Write(('o'*65536));[Console]::Out.Flush()
    [Console]::Error.Write(('e'*65536));[Console]::Error.Flush()
    [Threading.Thread]::Sleep(50)
}
'@
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') $dualStreamSource
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'bounded dual-stream drain proof'))
    $dualStreamHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $dualStreamPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $restoredHead -HeadRevision $dualStreamHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $dualStreamPlan) + "`n")
    $dualStreamCheckRoot = Join-Path $fixture 'affected-check-evidence-dual-stream'
    $dualStreamEvidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $restoredHead -HeadCommit $dualStreamHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture 'dual-stream-evidence.json') -CheckEvidenceDirectory $dualStreamCheckRoot
    [byte[]]$expectedDualStdout = [Text.Encoding]::UTF8.GetBytes(('o' * 524288))
    [byte[]]$expectedDualStderr = [Text.Encoding]::UTF8.GetBytes(('e' * 524288))
    $dualStdoutPath = Join-Path $dualStreamCheckRoot 'public-boundary/stdout.bin'; $dualStderrPath = Join-Path $dualStreamCheckRoot 'public-boundary/stderr.bin'
    Assert-True ($dualStreamEvidence.result -ceq 'pass' -and [IO.File]::Exists($dualStdoutPath) -and [IO.File]::Exists($dualStderrPath) -and (Get-MorphospaceAffectedCheckBytesSha256 ([IO.File]::ReadAllBytes($dualStdoutPath))) -ceq (Get-MorphospaceAffectedCheckBytesSha256 $expectedDualStdout) -and (Get-MorphospaceAffectedCheckBytesSha256 ([IO.File]::ReadAllBytes($dualStderrPath))) -ceq (Get-MorphospaceAffectedCheckBytesSha256 $expectedDualStderr)) 'Passing bounded dual-stream leaf lost or changed stdout/stderr bytes before cache publication.'
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "# fixture`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'restore after dual-stream proof'))
    $restoredHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    }

    if ($runFullSelector -or $runExecutorDescendantContainmentDamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    $restoredHead = $docsHead
    $survivorCheckRoot = Join-Path $fixture 'affected-check-evidence-surviving-descendant'
    $survivorInventoryPath = Join-Path $survivorCheckRoot 'inventory.json'
    $survivorReadyPath = Join-Path $fixture 'surviving-descendant.ready'
    $survivorPidPath = Join-Path $fixture 'surviving-descendant.pid'
    $survivorMarkerPath = Join-Path $fixture 'surviving-descendant.tampered'
    $survivorRedirectedPath = Join-Path $fixture 'surviving-descendant.redirected'
    $survivorModePath = Join-Path $fixture 'surviving-descendant.mode'
    $escapeLiteral = { param([string]$Value) $Value.Replace("'","''") }
    $descendantSource = @"
[IO.File]::WriteAllText('$(& $escapeLiteral $survivorReadyPath)','ready',[Text.UTF8Encoding]::new(`$false))
while (-not [IO.File]::Exists('$(& $escapeLiteral $survivorInventoryPath)')) { [Threading.Thread]::Sleep(20) }
[IO.File]::WriteAllText('$(& $escapeLiteral $survivorInventoryPath)','tampered',[Text.UTF8Encoding]::new(`$false))
[IO.File]::WriteAllText('$(& $escapeLiteral $survivorMarkerPath)','tampered',[Text.UTF8Encoding]::new(`$false))
[Threading.Thread]::Sleep(30000)
"@
    $descendantEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($descendantSource))
    $survivorCommand = @"
`$childExecutable = (Get-Process -Id `$PID).Path
`$start = [Diagnostics.ProcessStartInfo]::new()
`$start.UseShellExecute = `$false
`$start.CreateNoWindow = `$true
`$start.RedirectStandardOutput = `$true
`$start.RedirectStandardError = `$true
if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    `$start.FileName = `$childExecutable
    `$mode = 'job-descendant'
} else {
    `$setsidPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach (`$command in @(Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue)) {
        `$path = [IO.Path]::GetFullPath([string]`$command.Source)
        if (-not [IO.File]::Exists(`$path)) { throw 'resolved setsid executable does not exist' }
        [void]`$setsidPaths.Add(`$path)
    }
    if (`$setsidPaths.Count -eq 0) { throw 'required setsid executable is unavailable for descendant containment damage' }
    [string[]]`$orderedSetsidPaths = @(`$setsidPaths)
    [Array]::Sort(`$orderedSetsidPaths,[StringComparer]::Ordinal)
    `$start.FileName = `$orderedSetsidPaths[0]
    [void]`$start.ArgumentList.Add(`$childExecutable)
    `$mode = 'setsid-session-escape-attempt'
}
foreach (`$argument in @('-NoProfile','-NonInteractive','-EncodedCommand','$descendantEncoded')) { [void]`$start.ArgumentList.Add(`$argument) }
`$process = [Diagnostics.Process]::Start(`$start)
[IO.File]::WriteAllText('$(& $escapeLiteral $survivorPidPath)',[string]`$process.Id,[Text.UTF8Encoding]::new(`$false))
[IO.File]::WriteAllText('$(& $escapeLiteral $survivorRedirectedPath)','stdout=true;stderr=true',[Text.UTF8Encoding]::new(`$false))
[IO.File]::WriteAllText('$(& $escapeLiteral $survivorModePath)',`$mode,[Text.UTF8Encoding]::new(`$false))
`$deadline = [DateTime]::UtcNow.AddSeconds(5)
while (-not [IO.File]::Exists('$(& $escapeLiteral $survivorReadyPath)') -and [DateTime]::UtcNow -lt `$deadline) { [Threading.Thread]::Sleep(20) }
if (-not [IO.File]::Exists('$(& $escapeLiteral $survivorReadyPath)')) {
    `$childExit = if (`$process.HasExited) { [string]`$process.ExitCode } else { 'running' }
    throw "surviving descendant did not publish readiness: child_exit=`$childExit"
}
[Environment]::Exit(0)
"@
    Assert-True ($survivorCommand.IndexOf('$setsid.Source',[StringComparison]::Ordinal) -lt 0 -and $survivorCommand.IndexOf('[Array]::Sort($orderedSetsidPaths,[StringComparer]::Ordinal)',[StringComparison]::Ordinal) -ge 0) 'Surviving-descendant fixture does not resolve duplicate setsid applications deterministically.'
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') $survivorCommand
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'surviving descendant cache-tamper damage'))
    $survivorHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $survivorPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $restoredHead -HeadRevision $survivorHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $survivorPlan) + "`n")
    $survivorEvidencePath = Join-Path $fixture 'surviving-descendant-evidence.json'
    $survivorFailure = $null
    try {
        $survivorEvidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $restoredHead -HeadCommit $survivorHead -PlanPath $planPath -Platform linux -OutPath $survivorEvidencePath -CheckEvidenceDirectory $survivorCheckRoot
    } catch {
        $survivorFailure = $_
        if ([IO.File]::Exists($survivorEvidencePath)) { $survivorEvidence = Read-MorphospaceProtocolJson -Path $survivorEvidencePath }
    }
    $survivorCacheStderrPath = Join-Path $survivorCheckRoot 'public-boundary/stderr.bin'
    $survivorStderrText = if ([IO.File]::Exists($survivorCacheStderrPath)) { [Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($survivorCacheStderrPath)).Trim() } else { '<absent>' }
    $survivorObserved = if ($null -eq $survivorEvidence) { 'no evidence' } else { @($survivorEvidence.check_results | ForEach-Object { "$($_.check_id):result=$($_.result),exit=$($_.exit_code),timeout=$($_.timed_out),truncated=$($_.output_truncated),drain=$($_.post_kill_drain_timed_out),stdout=$($_.stdout_bytes)/$($_.stdout_sha256),stderr=$($_.stderr_bytes)/$($_.stderr_sha256),stderr_text=$survivorStderrText" }) -join '; ' }
    Assert-True ($null -eq $survivorFailure -and $null -ne $survivorEvidence -and $survivorEvidence.result -ceq 'pass') "Surviving-descendant fixture did not complete its parent leaf successfully. Observed: $survivorObserved"
    $survivorPid = [int](Get-Content -LiteralPath $survivorPidPath -Raw)
    $survivorExitDeadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    do {
        $survivorProcess = Get-Process -Id $survivorPid -ErrorAction SilentlyContinue
        if ($null -eq $survivorProcess -and -not [IO.File]::Exists($survivorMarkerPath)) { break }
        [Threading.Thread]::Sleep(20)
    } while ([DateTimeOffset]::UtcNow -lt $survivorExitDeadline)
    Assert-True ([IO.File]::Exists($survivorReadyPath) -and [IO.File]::Exists($survivorRedirectedPath) -and (Get-Content -LiteralPath $survivorRedirectedPath -Raw) -ceq 'stdout=true;stderr=true') 'Surviving-descendant fixture did not establish a privately redirected live child before the leaf exited.'
    $expectedSurvivorMode = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { 'job-descendant' } else { 'setsid-session-escape-attempt' }
    Assert-True ([IO.File]::Exists($survivorModePath) -and (Get-Content -LiteralPath $survivorModePath -Raw) -ceq $expectedSurvivorMode) 'Surviving-descendant fixture did not exercise the expected platform containment escape attempt.'
    Assert-True ($null -eq $survivorProcess -and -not [IO.File]::Exists($survivorMarkerPath)) 'A descendant survived universal child-tree cleanup and reached the later cache materialization.'
    Assert-True ($survivorEvidence.result -ceq 'pass' -and [string]$survivorEvidence.cache_inventory_sha256 -ceq (Get-FileHash -LiteralPath $survivorInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Surviving-descendant damage did not retain an exact executor-bound cache inventory.'
    $survivorInventory = Get-Content -LiteralPath $survivorInventoryPath -Raw | ConvertFrom-Json -Depth 64 -DateKind String
    Assert-True ([string]$survivorInventory.schema -ceq 'rusty.morphospace.workflow.affected_validation_check_inventory.v1') 'Surviving-descendant damage changed the parent-owned inventory bytes.'
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "# fixture`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'restore after surviving descendant damage'))
    $restoredHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    }

    if ($runFullSelector -or $runExecutorSourceIntegrityDamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    $restoredHead = $docsHead
    [byte[]]$protocolBytesBeforeIntegrityDamage = [IO.File]::ReadAllBytes((Join-Path $fixture 'scripts/lib/MorphospaceProtocolCommon.psm1'))
    $failureClassifierSource=Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -Raw;$failureClassifierAst=[Management.Automation.Language.Parser]::ParseInput($failureClassifierSource,[ref]$null,[ref]$null);$failureClassifierFunction=@($failureClassifierAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Get-AffectedValidationFailureKind'},$true));Assert-True ($failureClassifierFunction.Count-eq1) 'Affected executor does not expose one closed failure-kind classifier.';. ([scriptblock]::Create([string]$failureClassifierFunction[0].Extent.Text))
    $notStartedChild=[pscustomobject]@{Started=$false;TimedOut=$false;OutputTruncated=$false;PostKillDrainTimedOut=$false;Error='pre-execution integrity failure'}
    Assert-True ((Get-AffectedValidationFailureKind -Result infra-fail -Child $notStartedChild -IntegrityError 'known pre-execution integrity failure')-ceq'infrastructure'-and(Get-AffectedValidationFailureKind -Result infra-fail -Child $notStartedChild -IntegrityError $null)-ceq'launch') 'Known pre-execution integrity failure was not classified before genuine launch failure.'
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "[IO.File]::AppendAllText((Join-Path `$PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1'),'# child mutation',[Text.UTF8Encoding]::new(`$false))`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'post-execution integrity damage'))
    $integrityDamageHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $integrityDamagePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $restoredHead -HeadRevision $integrityDamageHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $integrityDamagePlan) + "`n")
    $integrityDamageRoot = Join-Path $fixture 'affected-check-evidence-integrity-damage'
    $integrityFailure = $null
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $restoredHead -HeadCommit $integrityDamageHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture 'integrity-damage-evidence.json') -CheckEvidenceDirectory $integrityDamageRoot) } catch { $integrityFailure = $_ }
    Assert-True ($null -ne $integrityFailure -and [string]$integrityFailure.Exception.Message -like '*Post-execution affected-check input integrity failed*') 'Tracked child source mutation was not classified as a typed post-execution integrity failure.'
    $integrityEvidence = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'integrity-damage-evidence.json')
    Assert-True ($integrityEvidence.result -ceq 'infra-fail' -and -not [IO.File]::Exists((Join-Path $integrityDamageRoot 'inventory.json')) -and [string]$integrityFailure.Exception.Data['AffectedCacheFinalized'] -cne 'true') 'Input-integrity failure published a reusable cache inventory.'
    [IO.File]::WriteAllBytes((Join-Path $fixture 'scripts/lib/MorphospaceProtocolCommon.psm1'),$protocolBytesBeforeIntegrityDamage)
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "# fixture`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'restore after integrity damage'))
    $restoredHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    }

    if ($runFullSelector -or $runExecutorPublicationCollisionDamagePhase) {
    [void](Invoke-TestGit $fixture @('checkout','--detach',$docsHead))
    $restoredHead = $docsHead
    $precreatedRoot = Join-Path $fixture 'affected-check-evidence-precreated-output'
    $precreatedLeaf = Join-Path $precreatedRoot 'public-boundary'
    $escapedPrecreatedLeaf = $precreatedLeaf.Replace("'","''")
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "[void][IO.Directory]::CreateDirectory('$escapedPrecreatedLeaf')`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'future receipt collision damage'))
    $precreatedHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $precreatedPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $restoredHead -HeadRevision $precreatedHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $precreatedPlan) + "`n")
    $precreatedFailure = $null
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $restoredHead -HeadCommit $precreatedHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture 'precreated-evidence.json') -CheckEvidenceDirectory $precreatedRoot) } catch { $precreatedFailure = $_ }
    Assert-True ($null -ne $precreatedFailure -and [string]$precreatedFailure.Exception.Message -like '*already exists*' -and -not [IO.File]::Exists((Join-Path $precreatedRoot 'inventory.json')) -and [string]$precreatedFailure.Exception.Data['AffectedCacheFinalized'] -cne 'true') 'Child precreation/collision was published as a reusable cache.'
    if ([IO.Directory]::Exists($precreatedRoot)) { Remove-Item -LiteralPath $precreatedRoot -Recurse -Force }
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "# fixture`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'restore after receipt collision'))
    $restoredHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    }
    $restoredHead = $docsHead
    if ($runFullSelector -or $runExecutorPassPhase) {
        foreach ($invalidPath in @('docs/', '   ')) {
            $damagedPlan = ConvertFrom-Json -InputObject (ConvertTo-MorphospaceCanonicalJson -Value $docsPlan) -Depth 64
            $damagedPlan.changed_paths[0].new_path = $invalidPath
            $damagedAccepted = Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $damagedPlan) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-plan-v1.schema.json') -ErrorAction SilentlyContinue
            Assert-True (-not $damagedAccepted) "Plan schema accepted noncanonical path '$invalidPath'."
        }
    }

    if ($runFullSelector -or $runSelectionPhase) {
    $selectionScenarioContext = New-AffectedSelectionScenarioContext -RequestedRoot $SelectionScenarioEvidenceRoot

    Write-Utf8 (Join-Path $fixture 'scripts/WorkUnitAutomation.psm1') "# automation`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/WorkUnitAutomation.psm1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'automation'))
    $automationHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    [void](Invoke-AffectedSelectionScenario -Context $selectionScenarioContext -Scenario automation -Fixture $fixture -BaseCommit $restoredHead -HeadCommit $automationHead -Action {
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $restoredHead -HeadRevision $automationHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        Assert-True ($plan.selection_mode -ceq 'affected') 'Mapped automation change did not retain affected selection.'
        Assert-True (@($plan.selected_checks.check_id) -ccontains 'public-boundary') 'Automation change did not trigger the public-boundary gate.'
        Assert-True (@($plan.selected_checks | Where-Object { @($_.platforms) -ccontains 'windows' }).Count -ge 2) 'Automation change did not select its Windows integration closure.'
        return $plan
    })

    Write-Utf8 (Join-Path $fixture 'scripts/new-owner.ps1') "# owner`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/new-owner.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'script'))
    $scriptHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    [void](Invoke-AffectedSelectionScenario -Context $selectionScenarioContext -Scenario unmapped-script -Fixture $fixture -BaseCommit $automationHead -HeadCommit $scriptHead -Action {
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $automationHead -HeadRevision $scriptHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        Assert-True ($plan.selection_mode -ceq 'full-deep') 'An unmapped script did not fail closed to Deep.'
        Assert-True (@($plan.reason_codes) -ccontains 'unmapped-path') 'Unmapped script lacks its explicit reason.'
        return $plan
    })

    Write-Utf8 (Join-Path $fixture 'scripts/Test-DocumentationLinks.ps1') "# changed documentation owner`n"
    Write-Utf8 (Join-Path $fixture 'scripts/Test-SkillTemplates.ps1') "# changed skill owner`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-DocumentationLinks.ps1', 'scripts/Test-SkillTemplates.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'owner commands'))
    $commandHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    [void](Invoke-AffectedSelectionScenario -Context $selectionScenarioContext -Scenario owner-commands -Fixture $fixture -BaseCommit $scriptHead -HeadCommit $commandHead -Action {
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $scriptHead -HeadRevision $commandHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        foreach ($ownerId in @('documentation-links', 'skill-templates')) {
            Assert-True ((@($plan.selected_checks.check_id) -ccontains $ownerId)) "Changed command did not select owning check '$ownerId'."
            Assert-True ((@($plan.selected_checks | Where-Object check_id -ceq $ownerId).reasons -ccontains 'command-path-changed')) "Changed command lacks owning reason for '$ownerId'."
        }
        return $plan
    })

    Write-Utf8 (Join-Path $fixture 'unknown.bin') "unknown`n"
    [void](Invoke-TestGit $fixture @('add', 'unknown.bin'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'unknown'))
    $unknownHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    [void](Invoke-AffectedSelectionScenario -Context $selectionScenarioContext -Scenario unknown -Fixture $fixture -BaseCommit $commandHead -HeadCommit $unknownHead -Action {
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $commandHead -HeadRevision $unknownHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        Assert-True ($plan.selection_mode -ceq 'full-deep') 'Unmapped change did not fail closed to Deep.'
        Assert-True (@($plan.reason_codes) -ccontains 'unmapped-path') 'Unmapped change lacks reason code.'
        $ordinaryDeepCount = @($fixtureRegistry.checks | Where-Object { $null -eq $_.PSObject.Properties['aggregate_role'] }).Count
        Assert-True (@($plan.selected_checks).Count -eq $ordinaryDeepCount -and @($plan.selected_checks.check_id) -cnotcontains 'work-environment-deep') 'Deep fallback did not select every independent leaf or selected the redundant cumulative aggregate.'
        return $plan
    })

    [void](Invoke-TestGit $fixture @('mv', 'docs/base.md', 'docs/renamed.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'rename'))
    $renameHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $renameResult = Invoke-AffectedSelectionScenario -Context $selectionScenarioContext -Scenario rename -Fixture $fixture -BaseCommit $unknownHead -HeadCommit $renameHead -Action {
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $unknownHead -HeadRevision $renameHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        Assert-True (@($plan.changed_paths)[0].status.StartsWith('R')) 'Rename identity was not retained.'
        Assert-True ($null -ne @($plan.changed_paths)[0].old_blob -and $null -ne @($plan.changed_paths)[0].new_blob) 'Rename blobs were not bound.'
        return $plan
    }
    $renamePlan = $renameResult.value

    [void](Invoke-AffectedSelectionScenario -Context $selectionScenarioContext -Scenario repeat -Fixture $fixture -BaseCommit $unknownHead -HeadCommit $renameHead -Action {
        $referencePlan = if ($null -ne $renamePlan) { $renamePlan } else { Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $unknownHead -HeadRevision $renameHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick }
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $unknownHead -HeadRevision $renameHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        Assert-True ($plan.plan_sha256 -ceq $referencePlan.plan_sha256) 'Repeated plan was not deterministic.'
        $referencePlanBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $referencePlan) + "`n")
        $repeatPlanBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $plan) + "`n")
        Assert-True ([System.Linq.Enumerable]::SequenceEqual[byte]($referencePlanBytes, $repeatPlanBytes)) 'Repeated canonical plan bytes were not identical.'
        return $plan
    })

    [void](Invoke-AffectedSelectionScenario -Context $selectionScenarioContext -Scenario no-change -Fixture $fixture -BaseCommit $renameHead -HeadCommit $renameHead -Action {
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $renameHead -HeadRevision $renameHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        Assert-True (@($plan.changed_paths).Count -eq 0) 'Base=head did not emit an empty changed-path inventory.'
        Assert-True (@($plan.reason_codes) -ccontains 'no-changed-paths') 'Base=head lacks its reason code.'
        return $plan
    })

    Remove-Item -LiteralPath (Join-Path $fixture 'docs/renamed.md')
    [void](Invoke-TestGit $fixture @('add', '--update', 'docs/renamed.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'delete'))
    $deleteHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    [void](Invoke-AffectedSelectionScenario -Context $selectionScenarioContext -Scenario delete -Fixture $fixture -BaseCommit $renameHead -HeadCommit $deleteHead -Action {
        $plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $renameHead -HeadRevision $deleteHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        Assert-True (@($plan.changed_paths).Count -eq 1 -and @($plan.changed_paths)[0].status -ceq 'D') 'Delete identity was not retained.'
        Assert-True ($null -ne @($plan.changed_paths)[0].old_blob -and $null -eq @($plan.changed_paths)[0].new_blob) 'Delete blob boundary was not bound.'
        Assert-True (@($plan.selected_checks.check_id) -ccontains 'documentation-links') 'Deleted documentation did not retain its owner check.'
        return $plan
    })
    Write-Host "Affected selection scenario receipts passed: $(@($selectionScenarioContext.results | ForEach-Object { "$($_.scenario)=$($_.result):$($_.elapsed_ms)ms" }) -join ', ')."
    } else {
        $deleteHead = $restoredHead
    }

    if ($runFullSelector -or $runTrustPhase) {
    if ($runFullSelector -or $runTrustSelfPhase) {
    $trustSegmentClock = [Diagnostics.Stopwatch]::StartNew()
    $fixtureContractPhase = 'trust-self-executor'
    $fixtureContractCheckId = 'affected-selector-trust-self-executor'
    $fixtureContractPlanSha256 = 'a' * 64
    $fixtureContractTree = Invoke-TestGit $fixture @('rev-parse', "$deleteHead^{tree}")
    $fixtureContractCommandPath = 'scripts/Invoke-AffectedValidationSelfTestPhase.ps1'
    $fixtureContractManifest = @([pscustomobject][ordered]@{
        path=$fixtureContractCommandPath
        mode='100644'
        blob=Invoke-TestGit $fixture @('rev-parse', "${deleteHead}:$fixtureContractCommandPath")
    })
    $fixtureContractProjection = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.affected_validation_self_test_dependency_projection.v1'
        repository='MesmerPrism/rusty-morphospace-work-environment'
        head_commit=$deleteHead
        head_tree=$fixtureContractTree
        registry_sha256=Get-MorphospaceCanonicalJsonSha256 -Value $fixtureRegistry
        check_id=$fixtureContractCheckId
        command_path=$fixtureContractCommandPath
        consume_path_sets=@('affected-validation-contract')
        dependency_manifest=$fixtureContractManifest
    }
    $fixtureContractProjectionPath = Join-Path $fixture 'fixture-phase-projection.json'
    [byte[]]$fixtureContractProjectionBytes = [Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $fixtureContractProjection) + "`n")
    [IO.File]::WriteAllBytes($fixtureContractProjectionPath,$fixtureContractProjectionBytes)
    $fixtureContractProjectionSha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($fixtureContractProjectionBytes))).ToLowerInvariant()
    $fixtureContractPhaseRoot = Join-Path $fixture 'fixture-phase-contract'
    [void][IO.Directory]::CreateDirectory($fixtureContractPhaseRoot)
    $fixtureContractEnvironment = [ordered]@{
        RUSTY_AFFECTED_VALIDATION_PHASE_ROOT=$fixtureContractPhaseRoot
        RUSTY_AFFECTED_VALIDATION_BASE_COMMIT=$deleteHead
        RUSTY_AFFECTED_VALIDATION_HEAD_COMMIT=$deleteHead
        RUSTY_AFFECTED_VALIDATION_PLAN_SHA256=$fixtureContractPlanSha256
        RUSTY_AFFECTED_VALIDATION_PLATFORM=$(if($IsWindows){'windows'}else{'linux'})
        RUSTY_AFFECTED_VALIDATION_CHECK_ID=$fixtureContractCheckId
        RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_PATH=$fixtureContractProjectionPath
        RUSTY_AFFECTED_VALIDATION_DEPENDENCY_PROJECTION_SHA256=$fixtureContractProjectionSha256
    }
    $fixtureContractEnvironmentBefore = @{}
    try {
        foreach ($entry in $fixtureContractEnvironment.GetEnumerator()) {
            $fixtureContractEnvironmentBefore[[string]$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key,'Process')
            [Environment]::SetEnvironmentVariable([string]$entry.Key,[string]$entry.Value,'Process')
        }
        $fixtureContractOutput = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture $fixtureContractCommandPath) -Phase $fixtureContractPhase -BudgetSeconds 75 2>&1)
        Assert-True ($LASTEXITCODE -eq 0) "Schema-valid fixture phase runner failed: $($fixtureContractOutput -join ' ')"
    } finally {
        foreach ($entry in $fixtureContractEnvironment.GetEnumerator()) {
            $before = $fixtureContractEnvironmentBefore[[string]$entry.Key]
            if ($null -eq $before) { [Environment]::SetEnvironmentVariable([string]$entry.Key,$null,'Process') }
            else { [Environment]::SetEnvironmentVariable([string]$entry.Key,[string]$before,'Process') }
        }
    }
    $fixtureContractArtifacts = [Collections.Generic.List[object]]::new()
    foreach ($suffix in @('start.json','stdout.bin','stderr.bin','terminal.json')) {
        $relative = "$fixtureContractPhase.$suffix"
        $fixtureContractArtifacts.Add([pscustomobject][ordered]@{path=$relative;bytes=[IO.File]::ReadAllBytes((Join-Path $fixtureContractPhaseRoot $relative))})
    }
    $fixtureContractRunner = Get-MorphospaceAffectedCheckRunnerBinding
    $fixtureContractExpectedBinding = [pscustomobject][ordered]@{repository='MesmerPrism/rusty-morphospace-work-environment';platform=$(if($IsWindows){'windows'}else{'linux'});check_id=$fixtureContractCheckId;runner=$fixtureContractRunner;dependency_manifest=$fixtureContractManifest}
    $fixtureContractExpectedSource = [pscustomobject][ordered]@{base=[pscustomobject][ordered]@{commit=$deleteHead;tree=$fixtureContractTree};head=[pscustomobject][ordered]@{commit=$deleteHead;tree=$fixtureContractTree}}
    $fixtureContractEvidenceModule = Get-Module MorphospaceAffectedValidationCheckEvidence
    [void](& $fixtureContractEvidenceModule {
        param($Artifacts,$Phase,$Binding,$Source,$PlanSha256,$SchemaPath)
        Assert-MorphospaceAffectedCheckPhaseArtifactSet -Artifacts $Artifacts -Phase $Phase -ExpectedBinding $Binding -ExpectedSource $Source -ExpectedPlanSha256 $PlanSha256 -PhaseReceiptSchemaPath $SchemaPath
    } @($fixtureContractArtifacts.ToArray()) $fixtureContractPhase $fixtureContractExpectedBinding $fixtureContractExpectedSource $fixtureContractPlanSha256 (Join-Path $repoRoot 'schemas/affected-validation-self-test-phase-receipt-v1.schema.json'))
    Remove-Item -LiteralPath $fixtureContractProjectionPath -Force
    Remove-Item -LiteralPath $fixtureContractPhaseRoot -Recurse -Force
    Write-Host 'Schema-valid fixture phase receipt and artifact-set contract passed.'
    Write-Utf8 (Join-Path $fixture 'scripts/Test-AffectedValidation.ps1') "# selector changed`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-AffectedValidation.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'selector self change'))
    $selectorHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $selectorPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $deleteHead -HeadRevision $selectorHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($selectorPlan.selection_mode -ceq 'affected') 'Selector self-change did not retain current-delta selection.'
    Assert-True (@($selectorPlan.selected_checks.check_id) -ccontains 'affected-selector-selftest') 'Selector self-change did not retain the selector self-test.'
    Assert-True (@($selectorPlan.selected_checks.check_id) -cnotcontains 'work-environment-deep') 'Selector self-change incorrectly selected the historical Deep aggregate.'
    Assert-True (@($selectorPlan.reason_codes) -cnotcontains 'trust-root-path-changed') 'Selector self-change incorrectly recorded a Deep-escalation reason.'
    foreach ($selfTestId in $selectorTrustRootCheckIds) { Assert-True (@($selectorPlan.selected_checks.check_id) -ccontains $selfTestId) "Selector trust-root change does not execute '$selfTestId' through the PR-owned selection path." }
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $selectorPlan) + "`n")
    $selectorEvidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $deleteHead -HeadCommit $selectorHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture 'selector-evidence.json')
    Assert-True ($selectorEvidence.result -ceq 'pass') 'Actual bounded executor did not complete the trust-root self-test closure.'
    foreach ($selfTestId in $selectorTrustRootCheckIds) { Assert-True (@($selectorEvidence.check_results.check_id) -ccontains $selfTestId) "Actual bounded executor did not run '$selfTestId'." }
    Write-Utf8 (Join-Path $fixture 'scripts/Test-AffectedValidationInfrastructure.ps1') "# changed infrastructure classifier`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-AffectedValidationInfrastructure.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'infrastructure classifier'))
    $infrastructureHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $infrastructurePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $selectorHead -HeadRevision $infrastructureHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($infrastructurePlan.selection_mode -ceq 'affected' -and @($infrastructurePlan.selected_checks.check_id) -ccontains 'affected-selector-selftest') 'Infrastructure classifier change did not retain bounded selector coverage.'
    Write-Host "Trust self/executor checks passed in $([long]$trustSegmentClock.Elapsed.TotalMilliseconds)ms."
    }

    if ($runFullSelector -or $runTrustRoutingPhase) {
    $trustSegmentClock = [Diagnostics.Stopwatch]::StartNew()
    $routingBaseHead = if ($runFullSelector) { $infrastructureHead } else { $deleteHead }
    $contractRegistry = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $contractRegistry.revision = [long]$contractRegistry.revision + 1
    Write-Utf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson -Value $contractRegistry) + "`n")
    [void](Invoke-TestGit $fixture @('add', 'manifests/affected-validation-registry.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'affected validation registry contract'))
    $registryContractHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $registryContractPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $routingBaseHead -HeadRevision $registryContractHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($registryContractPlan.selection_mode -ceq 'full-deep' -and @($registryContractPlan.selected_checks.check_id) -ccontains 'workflow-contracts') 'Affected-validation registry change did not retain its one-time Deep workflow-contract coverage.'
    foreach ($checkId in $selectorTrustRootCheckIds) { Assert-True (@($registryContractPlan.selected_checks.check_id) -ccontains $checkId) "Affected-validation registry change did not retain '$checkId'." }
    Assert-True (@($registryContractPlan.selected_checks.check_id) -cnotcontains 'work-environment-deep' -and @($registryContractPlan.reason_codes) -ccontains 'trust-root-path-changed' -and @($registryContractPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'Affected-validation registry change did not retain independent-leaf Deep escalation or selected the redundant aggregate.'
    $segmentOwner = @{}
    foreach ($platform in @('linux','windows')) {
        $platformSelections = @($registryContractPlan.selected_checks | Where-Object { @($_.platforms) -ccontains $platform })
        $segments = @(Get-MorphospaceAffectedValidationSegments -Plan $registryContractPlan -Registry $contractRegistry -Platform $platform)
        Assert-True ($segments.Count -gt 0 -and ($platform -cne 'windows' -or $segments.Count -gt 1)) "Affected-validation $platform Deep partition did not produce its bounded segment set."
        $covered = [Collections.Generic.List[string]]::new()
        foreach ($segment in $segments) {
            Assert-True ([long]$segment.estimated_budget_seconds -le 3600 -and [int]$segment.segment_count -eq $segments.Count -and @($segment.check_ids).Count -gt 0) "Affected-validation segment '$($segment.segment_id)' exceeds its one-hour target or has invalid cardinality."
            foreach ($id in @($segment.check_ids)) {
                $ownerKey = "$platform/$id"
                Assert-True (-not $segmentOwner.ContainsKey($ownerKey)) "Affected-validation $platform segment partition repeats '$id'."
                $segmentOwner[$ownerKey] = [string]$segment.segment_id
                $covered.Add([string]$id)
            }
        }
        Assert-True ((Get-MorphospaceCanonicalJsonSha256 -Value @($covered.ToArray() | Sort-Object)) -ceq (Get-MorphospaceCanonicalJsonSha256 -Value @($platformSelections.check_id | Sort-Object))) "Affected-validation $platform segments do not cover the exact platform selection."
    }
    $contractCheckMap = @{}; foreach ($check in @($contractRegistry.checks)) { $contractCheckMap[[string]$check.check_id] = $check }
    foreach ($selection in @($registryContractPlan.selected_checks)) {
        $id = [string]$selection.check_id
        $executionAfter = if ($null -eq $contractCheckMap[$id].PSObject.Properties['execution_after_checks']) { @() } else { @($contractCheckMap[$id].execution_after_checks) }
        foreach ($platform in @($selection.platforms)) {
            $ownerKey = "$platform/$id"
            foreach ($dependency in @(@($contractCheckMap[$id].prerequisite_checks) + @($executionAfter))) {
                $dependencyKey = "$platform/$dependency"
                if ($segmentOwner.ContainsKey($dependencyKey)) { Assert-True ([string]$segmentOwner[$ownerKey] -ceq [string]$segmentOwner[$dependencyKey]) "Affected-validation $platform segment split ordered dependency '$dependency' from '$id'." }
            }
        }
    }

    $segmentMergeRoot = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-segment-merge-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($segmentMergeRoot)
    try {
        $segmentPlanPath = Join-Path $segmentMergeRoot 'affected-plan.json'
        Write-Utf8 $segmentPlanPath ((ConvertTo-MorphospaceCanonicalJson -Value $registryContractPlan) + "`n")
        $segmentInventory = Get-MorphospaceAffectedTreeInventory -RepositoryRoot $fixture -Commit $registryContractHead
        $segmentRunner = [pscustomobject][ordered]@{os_description='segment-merge-self-test';powershell_version='7.6.0'}
        foreach ($platform in @('linux','windows')) {
            $platformSegments = @(Get-MorphospaceAffectedValidationSegments -Plan $registryContractPlan -Registry $contractRegistry -Platform $platform)
            $segmentEvidenceRoot = Join-Path $segmentMergeRoot "$platform-segments"
            [void][IO.Directory]::CreateDirectory($segmentEvidenceRoot)
            foreach ($segment in $platformSegments) {
                $segmentResults = [Collections.Generic.List[object]]::new()
                foreach ($id in @($segment.check_ids)) {
                    $commandPath = [string]$contractCheckMap[[string]$id].command_path
                    $entry = $segmentInventory.by_path[$commandPath]
                    Assert-True ($null -ne $entry -and [string]$entry.type -ceq 'blob') "Segment merge fixture lacks exact command blob '$commandPath'."
                    $segmentResults.Add([pscustomobject][ordered]@{check_id=[string]$id;command_path=$commandPath;command_blob_sha1=[string]$entry.blob;mode='executed';result='pass';started=$true;failure_kind=$null;exit_code=0;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout_sha256=('0'*64);stderr_sha256=('0'*64);stdout_bytes=0;stderr_bytes=0})
                }
                $segmentEvidence = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_evidence.v1';repository=[string]$registryContractPlan.repository;base=$registryContractPlan.base;head=$registryContractPlan.head;plan_sha256=[string]$registryContractPlan.plan_sha256;platform=$platform;runner=$segmentRunner;check_results=@($segmentResults.ToArray());result='pass';claims=[pscustomobject][ordered]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}
                Write-Utf8 (Join-Path $segmentEvidenceRoot "$([string]$segment.segment_id).json") ((ConvertTo-MorphospaceCanonicalJson -Value $segmentEvidence) + "`n")
            }
            $mergedPath = Join-Path $segmentMergeRoot "$platform-merged.json"
            $merged = & (Join-Path $repoRoot 'scripts/Merge-AffectedValidationSegments.ps1') -RepositoryRoot $fixture -BaseCommit $routingBaseHead -HeadCommit $registryContractHead -PlanPath $segmentPlanPath -Platform $platform -SegmentEvidenceDirectory $segmentEvidenceRoot -OutPath $mergedPath
            $expectedPlatformIds = @($registryContractPlan.selected_checks | Where-Object { @($_.platforms) -ccontains $platform } | ForEach-Object { [string]$_.check_id })
            Assert-True ([string]$merged.result -ceq 'pass' -and (Get-MorphospaceCanonicalJsonSha256 -Value @($merged.check_results.check_id)) -ceq (Get-MorphospaceCanonicalJsonSha256 -Value $expectedPlatformIds)) "Affected-validation $platform segment merger did not emit the exact ordered platform union."
            $firstSegmentFile = Get-ChildItem -LiteralPath $segmentEvidenceRoot -File | Sort-Object Name | Select-Object -First 1
            $firstSegmentOriginal = [IO.File]::ReadAllText($firstSegmentFile.FullName,[Text.UTF8Encoding]::new($false,$true))
            $typedDamage = $firstSegmentOriginal | ConvertFrom-Json -Depth 64 -DateKind String
            $typedDamage.check_results[0].failure_kind = 'exit-code'
            Write-Utf8 $firstSegmentFile.FullName ((ConvertTo-MorphospaceCanonicalJson -Value $typedDamage) + "`n")
            Assert-AffectedThrows { & (Join-Path $repoRoot 'scripts/Merge-AffectedValidationSegments.ps1') -RepositoryRoot $fixture -BaseCommit $routingBaseHead -HeadCommit $registryContractHead -PlanPath $segmentPlanPath -Platform $platform -SegmentEvidenceDirectory $segmentEvidenceRoot -OutPath (Join-Path $segmentMergeRoot "$platform-typed-damaged.json") | Out-Null } '*not valid with the schema*' "Affected-validation $platform segment merger accepted inconsistent typed failure data."
            Write-Utf8 $firstSegmentFile.FullName $firstSegmentOriginal
            $combinedStreamDamage=$firstSegmentOriginal|ConvertFrom-Json -Depth 64 -DateKind String
            $combinedStreamDamage.check_results[0].stdout_bytes=6291456;$combinedStreamDamage.check_results[0].stderr_bytes=5242880
            $combinedStreamDamageJson=ConvertTo-MorphospaceCanonicalJson -Value $combinedStreamDamage
            Assert-True (Test-Json -Json $combinedStreamDamageJson -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction Stop) "Affected-validation $platform combined-stream damage is not schema-valid."
            Write-Utf8 $firstSegmentFile.FullName ($combinedStreamDamageJson+"`n")
            Assert-AffectedThrows { & (Join-Path $repoRoot 'scripts/Merge-AffectedValidationSegments.ps1') -RepositoryRoot $fixture -BaseCommit $routingBaseHead -HeadCommit $registryContractHead -PlanPath $segmentPlanPath -Platform $platform -SegmentEvidenceDirectory $segmentEvidenceRoot -OutPath (Join-Path $segmentMergeRoot "$platform-combined-stream-damaged.json") | Out-Null } '*combined stream bound*' "Affected-validation $platform segment merger accepted evidence above the combined stream bound."
            Write-Utf8 $firstSegmentFile.FullName $firstSegmentOriginal
            Copy-Item -LiteralPath $firstSegmentFile.FullName -Destination (Join-Path $segmentEvidenceRoot 'unexpected-segment.json')
            Assert-AffectedThrows { & (Join-Path $repoRoot 'scripts/Merge-AffectedValidationSegments.ps1') -RepositoryRoot $fixture -BaseCommit $routingBaseHead -HeadCommit $registryContractHead -PlanPath $segmentPlanPath -Platform $platform -SegmentEvidenceDirectory $segmentEvidenceRoot -OutPath (Join-Path $segmentMergeRoot "$platform-invented.json") | Out-Null } '*inventory is not exact*' "Affected-validation $platform segment merger accepted invented segment evidence."
            Remove-Item -LiteralPath (Join-Path $segmentEvidenceRoot 'unexpected-segment.json') -Force
            $orderDamage = $firstSegmentOriginal | ConvertFrom-Json -Depth 64 -DateKind String
            if(@($orderDamage.check_results).Count-gt1){$orderDamage.check_results=@($orderDamage.check_results[1..($orderDamage.check_results.Count-1)]+$orderDamage.check_results[0]);Write-Utf8 $firstSegmentFile.FullName ((ConvertTo-MorphospaceCanonicalJson -Value $orderDamage)+"`n");Assert-AffectedThrows { & (Join-Path $repoRoot 'scripts/Merge-AffectedValidationSegments.ps1') -RepositoryRoot $fixture -BaseCommit $routingBaseHead -HeadCommit $registryContractHead -PlanPath $segmentPlanPath -Platform $platform -SegmentEvidenceDirectory $segmentEvidenceRoot -OutPath (Join-Path $segmentMergeRoot "$platform-order-damaged.json") | Out-Null } '*coverage or order is invalid*' "Affected-validation $platform segment merger accepted reordered check evidence.";Write-Utf8 $firstSegmentFile.FullName $firstSegmentOriginal}
            Remove-Item -LiteralPath $firstSegmentFile.FullName -Force
            Assert-AffectedThrows { & (Join-Path $repoRoot 'scripts/Merge-AffectedValidationSegments.ps1') -RepositoryRoot $fixture -BaseCommit $routingBaseHead -HeadCommit $registryContractHead -PlanPath $segmentPlanPath -Platform $platform -SegmentEvidenceDirectory $segmentEvidenceRoot -OutPath (Join-Path $segmentMergeRoot "$platform-damaged.json") | Out-Null } '*inventory is not exact*' "Affected-validation $platform segment merger accepted an incomplete evidence inventory."
        }
    } finally {
        if ([IO.Directory]::Exists($segmentMergeRoot)) { Remove-Item -LiteralPath $segmentMergeRoot -Recurse -Force }
    }

    $affectedSchemaPath = Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json'
    Write-Utf8 $affectedSchemaPath ((Get-Content -LiteralPath $affectedSchemaPath -Raw) + "`n")
    [void](Invoke-TestGit $fixture @('add', 'schemas/affected-validation-registry-v1.schema.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'affected validation schema contract'))
    $schemaContractHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $schemaContractPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $registryContractHead -HeadRevision $schemaContractHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($schemaContractPlan.selection_mode -ceq 'full-deep' -and @($schemaContractPlan.selected_checks.check_id) -ccontains 'workflow-contracts') 'Affected-validation schema change did not retain its one-time Deep workflow-contract coverage.'
    foreach ($checkId in $selectorTrustRootCheckIds) { Assert-True (@($schemaContractPlan.selected_checks.check_id) -ccontains $checkId) "Affected-validation schema change did not retain '$checkId'." }
    Assert-True (@($schemaContractPlan.selected_checks.check_id) -cnotcontains 'work-environment-deep' -and @($schemaContractPlan.reason_codes) -ccontains 'trust-root-path-changed' -and @($schemaContractPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'Affected-validation schema change did not retain independent-leaf Deep escalation or selected the redundant aggregate.'

    Write-Utf8 (Join-Path $fixture 'schemas/work-unit-event.schema.json') "{} `n"
    [void](Invoke-TestGit $fixture @('add', 'schemas/work-unit-event.schema.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'ordinary schema contract'))
    $ordinarySchemaHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $ordinarySchemaPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $schemaContractHead -HeadRevision $ordinarySchemaHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($ordinarySchemaPlan.selection_mode -ceq 'affected' -and @($ordinarySchemaPlan.selected_checks.check_id) -ccontains 'workflow-contracts' -and @($ordinarySchemaPlan.selected_checks.check_id) -ccontains 'public-boundary') 'Ordinary schema change did not retain bounded workflow-contract/public-boundary routing.'
    foreach ($checkId in @($selectorTrustRootCheckIds + @('work-environment-deep'))) { Assert-True (@($ordinarySchemaPlan.selected_checks.check_id) -cnotcontains $checkId) "Ordinary schema change incorrectly selected '$checkId'." }
    Assert-True (@($ordinarySchemaPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'Ordinary schema change became ambiguous.'

    Write-Utf8 (Join-Path $fixture 'manifests/public-action-policy.json') "{} `n"
    [void](Invoke-TestGit $fixture @('add', 'manifests/public-action-policy.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'ordinary manifest contract'))
    $ordinaryManifestHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $ordinaryManifestPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $ordinarySchemaHead -HeadRevision $ordinaryManifestHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($ordinaryManifestPlan.selection_mode -ceq 'affected' -and @($ordinaryManifestPlan.selected_checks.check_id) -ccontains 'workflow-contracts' -and @($ordinaryManifestPlan.selected_checks.check_id) -ccontains 'public-boundary') 'Ordinary manifest change did not retain bounded workflow-contract/public-boundary routing.'
    foreach ($checkId in @($selectorTrustRootCheckIds + @('work-environment-deep'))) { Assert-True (@($ordinaryManifestPlan.selected_checks.check_id) -cnotcontains $checkId) "Ordinary manifest change incorrectly selected '$checkId'." }
    Assert-True (@($ordinaryManifestPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'Ordinary manifest change became ambiguous.'

    $archiveSchemaPath = Join-Path $fixture 'schemas/history-archive-root-v1.schema.json'
    Write-Utf8 $archiveSchemaPath ((Get-Content -LiteralPath $archiveSchemaPath -Raw) + "`n")
    [void](Invoke-TestGit $fixture @('add', 'schemas/history-archive-root-v1.schema.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'history archive root contract'))
    $archiveSchemaHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $archiveSchemaPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $ordinaryManifestHead -HeadRevision $archiveSchemaHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier standard
    foreach ($checkId in @('public-boundary','workflow-contracts','history-archive-checkpoint')) { Assert-True (@($archiveSchemaPlan.selected_checks.check_id) -ccontains $checkId) "History archive schema change did not retain bounded '$checkId' coverage." }
    foreach ($checkId in @($selectorTrustRootCheckIds + @('work-environment-deep'))) { Assert-True (@($archiveSchemaPlan.selected_checks.check_id) -cnotcontains $checkId) "History archive schema change incorrectly selected '$checkId'." }
    Assert-True (@($archiveSchemaPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'History archive schema change became ambiguous.'

    $archiveRouterPath = Join-Path $fixture 'scripts/Invoke-WorkUnitAutomation.ps1'
    Write-Utf8 $archiveRouterPath "# public automation router contract`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Invoke-WorkUnitAutomation.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'history archive router contract'))
    $archiveRouterHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $archiveRouterPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $archiveSchemaHead -HeadRevision $archiveRouterHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier standard
    foreach ($checkId in @('public-boundary','workflow-contracts','history-archive-checkpoint','work-unit-automation')) { Assert-True (@($archiveRouterPlan.selected_checks.check_id) -ccontains $checkId) "History archive router change did not retain bounded '$checkId' coverage." }
    foreach ($checkId in @($selectorTrustRootCheckIds + @('active-unit-supersession','blocked-successor-preparation','work-environment-deep'))) { Assert-True (@($archiveRouterPlan.selected_checks.check_id) -cnotcontains $checkId) "Public automation router change incorrectly selected '$checkId'." }
    Assert-True (@($archiveRouterPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'Public automation router change became ambiguous.'

    # A W-017B-shaped archive/schema/router change remains ordinary affected
    # Standard work: shared archive owner schemas plus the automation router
    # must retain their bounded closure without selecting the aggregate Deep
    # command.
    $archiveEnvelopePaths = @(
        'schemas/validation-receipt.schema.json',
        'schemas/work-unit-automation-receipt-v2.schema.json',
        'schemas/workspace-state-v2.schema.json'
    )
    foreach ($relativePath in $archiveEnvelopePaths) { Write-Utf8 (Join-Path $fixture $relativePath) "archive envelope base`n" }
    [void](Invoke-TestGit $fixture (@('add') + $archiveEnvelopePaths))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'history archive shared contract base'))
    $archiveEnvelopeBase = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    foreach ($relativePath in $archiveEnvelopePaths) { Write-Utf8 (Join-Path $fixture $relativePath) "archive envelope change`n" }
    Write-Utf8 $archiveRouterPath "# archive router envelope change`n"
    [void](Invoke-TestGit $fixture (@('add') + $archiveEnvelopePaths + @('scripts/Invoke-WorkUnitAutomation.ps1')))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'history archive sealed envelope change'))
    $archiveEnvelopeHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $archiveEnvelopePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $archiveEnvelopeBase -HeadRevision $archiveEnvelopeHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier standard
    Assert-True ($archiveEnvelopePlan.selection_mode -ceq 'affected') 'W-017B-shaped archive envelope change did not retain affected selection.'
    Assert-True ($archiveEnvelopePlan.effective_tier -ceq 'standard') 'W-017B-shaped archive envelope change did not retain Standard effective tier.'
    foreach ($checkId in @('public-boundary','workflow-contracts','history-archive-checkpoint','work-unit-automation')) { Assert-True (@($archiveEnvelopePlan.selected_checks.check_id) -ccontains $checkId) "W-017B-shaped archive envelope change did not retain bounded '$checkId' coverage." }
    foreach ($checkId in @($selectorTrustRootCheckIds + @('work-environment-deep'))) { Assert-True (@($archiveEnvelopePlan.selected_checks.check_id) -cnotcontains $checkId) "W-017B-shaped archive envelope change incorrectly selected '$checkId'." }
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($archiveEnvelopePlan.reason_codes) -cnotcontains $reasonCode) "W-017B-shaped archive envelope change retained '$reasonCode'." }

    # Preparation-only files retain their exact owner without pulling in the
    # neighboring admission owner or the historical Deep aggregate.
    $developmentEnvelopeBase = $archiveEnvelopeHead
    Write-Utf8 (Join-Path $fixture 'scripts/CandidateFreeze.psm1') "# preparation-owned candidate freeze change`n"
    Write-Utf8 (Join-Path $fixture 'scripts/DevelopmentEnvelopePreparation.psm1') "# development envelope owner change`n"
    Write-Utf8 (Join-Path $fixture 'scripts/Test-DevelopmentEnvelopePreparation.ps1') "# development envelope focused test change`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/CandidateFreeze.psm1', 'scripts/DevelopmentEnvelopePreparation.psm1', 'scripts/Test-DevelopmentEnvelopePreparation.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'development envelope preparation change'))
    $developmentEnvelopeHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $developmentEnvelopePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $developmentEnvelopeBase -HeadRevision $developmentEnvelopeHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($developmentEnvelopePlan.selection_mode -ceq 'affected') 'Development-envelope preparation change did not retain affected selection.'
    Assert-True ($developmentEnvelopePlan.effective_tier -ceq 'standard') 'Development-envelope preparation change did not retain Standard effective tier.'
    foreach ($checkId in @('public-boundary','workflow-contracts','development-envelope-preparation','work-unit-automation')) { Assert-True (@($developmentEnvelopePlan.selected_checks.check_id) -ccontains $checkId) "Development-envelope preparation change did not retain bounded '$checkId' coverage." }
    foreach ($checkId in @('development-unit-admission','work-environment-deep')) { Assert-True (@($developmentEnvelopePlan.selected_checks.check_id) -cnotcontains $checkId) "Development-envelope preparation change incorrectly selected '$checkId'." }
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($developmentEnvelopePlan.reason_codes) -cnotcontains $reasonCode) "Development-envelope preparation change retained '$reasonCode'." }

    # The shared provenance module has one unique path class and triggers both
    # consumers without making every admission-only change a preparation change.
    $developmentProvenanceBase = $developmentEnvelopeHead
    Write-Utf8 (Join-Path $fixture 'scripts/DevelopmentEnvelopeProvenance.psm1') "# shared development envelope provenance change`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/DevelopmentEnvelopeProvenance.psm1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'development envelope provenance change'))
    $developmentProvenanceHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $developmentProvenancePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $developmentProvenanceBase -HeadRevision $developmentProvenanceHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($developmentProvenancePlan.selection_mode -ceq 'affected' -and $developmentProvenancePlan.effective_tier -ceq 'standard') 'Development-envelope provenance change did not retain affected Standard selection.'
    foreach ($checkId in @('public-boundary','workflow-contracts','development-envelope-preparation','development-unit-admission','work-unit-automation')) { Assert-True (@($developmentProvenancePlan.selected_checks.check_id) -ccontains $checkId) "Development-envelope provenance change did not retain bounded '$checkId' coverage." }
    Assert-True (@($developmentProvenancePlan.selected_checks.check_id) -cnotcontains 'work-environment-deep') 'Development-envelope provenance change selected the cumulative Deep aggregate.'
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($developmentProvenancePlan.reason_codes) -cnotcontains $reasonCode) "Development-envelope provenance change retained '$reasonCode'." }

    # Development-unit admission owns its schema, module, and focused test as
    # one exact path class.  Admission-only changes must run that owner without
    # replaying the neighboring envelope-preparation integration.
    $developmentAdmissionBase = $developmentProvenanceHead
    $developmentAdmissionSchemaPath = Join-Path $fixture 'schemas/development-unit-admission-v1.schema.json'
    Write-Utf8 $developmentAdmissionSchemaPath ((Get-Content -LiteralPath $developmentAdmissionSchemaPath -Raw).TrimEnd() + "`n `n")
    Write-Utf8 (Join-Path $fixture 'scripts/DevelopmentUnitAdmission.psm1') "# development unit admission change`n"
    Write-Utf8 (Join-Path $fixture 'scripts/Test-DevelopmentUnitAdmission.ps1') "# development unit admission test change`n"
    [void](Invoke-TestGit $fixture @('add', 'schemas/development-unit-admission-v1.schema.json', 'scripts/DevelopmentUnitAdmission.psm1', 'scripts/Test-DevelopmentUnitAdmission.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'development unit admission change'))
    $developmentAdmissionHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $developmentAdmissionPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $developmentAdmissionBase -HeadRevision $developmentAdmissionHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($developmentAdmissionPlan.selection_mode -ceq 'affected') 'Development-unit admission change did not retain affected selection.'
    Assert-True ($developmentAdmissionPlan.effective_tier -ceq 'standard') 'Development-unit admission change did not retain Standard effective tier.'
    foreach ($checkId in @('public-boundary','development-unit-admission')) { Assert-True (@($developmentAdmissionPlan.selected_checks.check_id) -ccontains $checkId) "Development-unit admission change did not retain bounded '$checkId' coverage." }
    foreach ($checkId in @('development-envelope-preparation','work-environment-deep')) { Assert-True (@($developmentAdmissionPlan.selected_checks.check_id) -cnotcontains $checkId) "Development-unit admission change incorrectly selected '$checkId'." }
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($developmentAdmissionPlan.reason_codes) -cnotcontains $reasonCode) "Development-unit admission change retained '$reasonCode'." }

    # The validating-candidate input producer is a non-mutating authority
    # constructor. A producer-only change must retain its six-check focused
    # Standard closure, including the declared WorkUnitAutomation consumer of
    # the shared workflow contract, and must never route through cumulative Deep.
    $rematerializationProducerBase = $developmentAdmissionHead
    Write-Utf8 (Join-Path $fixture 'scripts/New-ValidatingCandidateRematerializationInput.ps1') "# validating-candidate rematerialization input producer change`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/New-ValidatingCandidateRematerializationInput.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'validating candidate input producer change'))
    $rematerializationProducerHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $rematerializationProducerPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $rematerializationProducerBase -HeadRevision $rematerializationProducerHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    $rematerializationExpectedChecks = @('automation-receipt-v2-compatibility','normal-validation-selector','public-boundary','validating-candidate-rematerialization','work-unit-automation','workflow-contracts')
    $rematerializationActualChecks = @($rematerializationProducerPlan.selected_checks.check_id); [Array]::Sort($rematerializationActualChecks, [StringComparer]::Ordinal)
    Assert-True ($rematerializationProducerPlan.selection_mode -ceq 'affected' -and $rematerializationProducerPlan.effective_tier -ceq 'standard') 'Validating-candidate input producer change did not retain affected Standard selection.'
    Assert-True (($rematerializationActualChecks -join ',') -ceq ($rematerializationExpectedChecks -join ',')) "Validating-candidate input producer selected the wrong exact closure: $($rematerializationActualChecks -join ',')."
    $rematerializationWorkflowConsumerReasons = @($rematerializationProducerPlan.selected_checks | Where-Object { [string]$_.check_id -ceq 'work-unit-automation' -and @($_.reasons) -ccontains 'consumer-of:workflow-contracts:workflow-contracts' })
    Assert-True ($rematerializationWorkflowConsumerReasons.Count -eq 1) 'Validating-candidate input producer lost the intended work-unit-automation workflow-contract consumer reason.'
    Assert-True (@($rematerializationProducerPlan.selected_checks.check_id) -cnotcontains 'work-environment-deep') 'Validating-candidate input producer selected the cumulative Deep aggregate.'
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($rematerializationProducerPlan.reason_codes) -cnotcontains $reasonCode) "Validating-candidate input producer change retained '$reasonCode'." }

    # The shared v2 automation receipt has a fast direct compatibility owner
    # and is also consumed by validating-candidate rematerialization.  A
    # receipt-only change must therefore retain its exact compatibility and
    # dependent selector/workflow closure, without paying for history or the
    # cumulative Deep gate.
    $automationReceiptPath = Join-Path $fixture 'schemas/work-unit-automation-receipt-v2.schema.json'
    Write-Utf8 $automationReceiptPath ((Get-Content -LiteralPath $automationReceiptPath -Raw).TrimEnd() + "`n `n")
    [void](Invoke-TestGit $fixture @('add', 'schemas/work-unit-automation-receipt-v2.schema.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'shared automation receipt contract'))
    $automationReceiptHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $automationReceiptPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $rematerializationProducerHead -HeadRevision $automationReceiptHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    $automationReceiptExpectedChecks = @('automation-receipt-v2-compatibility','normal-validation-selector','public-boundary','validating-candidate-rematerialization','work-unit-automation','workflow-contracts')
    $automationReceiptActualChecks = @($automationReceiptPlan.selected_checks.check_id); [Array]::Sort($automationReceiptActualChecks, [System.StringComparer]::Ordinal)
    Assert-True (($automationReceiptActualChecks -join ',') -ceq ($automationReceiptExpectedChecks -join ',')) "Shared automation receipt selected the wrong exact closure: $($automationReceiptActualChecks -join ',')."
    foreach ($checkId in @('history-archive-checkpoint','history-archive-checkpoint-selftest','work-environment-deep')) { Assert-True (@($automationReceiptPlan.selected_checks.check_id) -cnotcontains $checkId) "Shared automation receipt change incorrectly selected '$checkId'." }
    $retiredArchiveSelection = @($automationReceiptPlan.selected_checks | Where-Object { [string]$_.check_id -ceq 'history-archive-checkpoint' })
    $retiredArchiveSkip = @($automationReceiptPlan.skipped_checks | Where-Object { [string]$_.check_id -ceq 'history-archive-checkpoint' })
    $intendedWorkflowConsumerReasons = @($automationReceiptPlan.selected_checks | Where-Object { [string]$_.check_id -ceq 'work-unit-automation' -and @($_.reasons) -ccontains 'consumer-of:workflow-contracts:workflow-contracts' })
    Assert-True ($intendedWorkflowConsumerReasons.Count -eq 1) 'Shared automation receipt lost the intended work-unit-automation workflow-contract consumer reason.'
    $retiredHistoryExpansionReasons = @($automationReceiptPlan.selected_checks | Where-Object { @('history-archive-checkpoint','historical-validation-debt-baseline') -ccontains [string]$_.check_id -and @($_.reasons) -ccontains 'consumer-of:workflow-contracts:workflow-contracts' })
    Assert-True ($retiredArchiveSelection.Count -eq 0 -and $retiredArchiveSkip.Count -eq 1 -and (@($retiredArchiveSkip[0].reasons) -join ',') -ceq 'not-selected') 'Shared automation receipt allowed the retired archive path to reappear through selection expansion.'
    Assert-True ($retiredHistoryExpansionReasons.Count -eq 0) 'Shared automation receipt retained the retired workflow-contract consumer expansion reason.'
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($automationReceiptPlan.reason_codes) -cnotcontains $reasonCode) "Shared automation receipt change retained '$reasonCode'." }

    # The generic active-supersession and blocked-successor owners remain
    # independent focused Standard leaves.  Both consume the ordinary
    # automation integration contract; the blocked successor additionally
    # consumes the development-envelope and exact normal-selector contracts.
    $activeLifecyclePaths = @('schemas/active-unit-supersession-v1.schema.json','scripts/ActiveUnitSupersession.psm1','scripts/Test-ActiveUnitSupersession.ps1')
    foreach ($relativePath in $activeLifecyclePaths) { Write-Utf8 (Join-Path $fixture $relativePath) $(if ($relativePath -like '*.json') { "{}`n" } else { "# active-unit supersession fixture`n" }) }
    [void](Invoke-TestGit $fixture (@('add') + $activeLifecyclePaths))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'active unit supersession contract'))
    $activeLifecycleHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $activeLifecyclePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $automationReceiptHead -HeadRevision $activeLifecycleHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    foreach ($checkId in @('public-boundary','workflow-contracts','work-unit-automation','active-unit-supersession')) { Assert-True (@($activeLifecyclePlan.selected_checks.check_id) -ccontains $checkId) "Active-unit supersession change did not retain bounded '$checkId' coverage." }
    foreach ($checkId in @('blocked-successor-preparation','work-environment-deep')) { Assert-True (@($activeLifecyclePlan.selected_checks.check_id) -cnotcontains $checkId) "Active-unit supersession change incorrectly selected '$checkId'." }
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($activeLifecyclePlan.reason_codes) -cnotcontains $reasonCode) "Active-unit supersession change retained '$reasonCode'." }

    $blockedLifecyclePaths = @('schemas/blocked-successor-preparation-receipt-v1.schema.json','schemas/blocked-successor-preparation-v1.schema.json','scripts/BlockedSuccessorPreparation.psm1','scripts/Test-BlockedSuccessorPreparation.ps1')
    foreach ($relativePath in $blockedLifecyclePaths) { Write-Utf8 (Join-Path $fixture $relativePath) $(if ($relativePath -like '*.json') { "{}`n" } else { "# blocked-successor preparation fixture`n" }) }
    [void](Invoke-TestGit $fixture (@('add') + $blockedLifecyclePaths))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'blocked successor preparation contract'))
    $blockedLifecycleHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $blockedLifecyclePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $activeLifecycleHead -HeadRevision $blockedLifecycleHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    foreach ($checkId in @('public-boundary','workflow-contracts','development-envelope-preparation','normal-validation-selector','work-unit-automation','blocked-successor-preparation')) { Assert-True (@($blockedLifecyclePlan.selected_checks.check_id) -ccontains $checkId) "Blocked-successor preparation change did not retain bounded '$checkId' coverage." }
    foreach ($checkId in @('active-unit-supersession','work-environment-deep')) { Assert-True (@($blockedLifecyclePlan.selected_checks.check_id) -cnotcontains $checkId) "Blocked-successor preparation change incorrectly selected '$checkId'." }
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($blockedLifecyclePlan.reason_codes) -cnotcontains $reasonCode) "Blocked-successor preparation change retained '$reasonCode'." }

    $releaseV2Path = Join-Path $fixture 'schemas/terminal-validation-selection-release-v2.schema.json'
    Write-Utf8 $releaseV2Path "{}`n"
    [void](Invoke-TestGit $fixture @('add', 'schemas/terminal-validation-selection-release-v2.schema.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'terminal validation selection release v2'))
    $releaseV2Head = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $releaseV2Plan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $blockedLifecycleHead -HeadRevision $releaseV2Head -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    foreach ($checkId in @('public-boundary','workflow-contracts','normal-validation-selector')) { Assert-True (@($releaseV2Plan.selected_checks.check_id) -ccontains $checkId) "Terminal validation-selection release v2 change did not retain bounded '$checkId' coverage." }
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($releaseV2Plan.reason_codes) -cnotcontains $reasonCode) "Terminal validation-selection release v2 change retained '$reasonCode'." }
    Assert-True (@($releaseV2Plan.selected_checks.check_id) -cnotcontains 'work-environment-deep') 'Terminal validation-selection release v2 change selected the cumulative Deep aggregate.'
    Write-Host "Trust routing-contract checks passed in $([long]$trustSegmentClock.Elapsed.TotalMilliseconds)ms."
    }

    if ($runFullSelector -or $runTrustMappingsPhase) {
    $trustSegmentClock = [Diagnostics.Stopwatch]::StartNew()
    # Every path from the combined raw-CAS and historical-debt candidate has a
    # single exact owner class.  Test each path independently so command-path
    # selection cannot conceal an unmapped or ambiguous shared-module route.
    $proportionalMappings = @(
        [pscustomobject]@{ path='schemas/historical-validation-debt-phase-receipt-v1.schema.json'; checks=@('historical-validation-debt-baseline','historical-validation-debt-phase-runner','work-unit-automation') },
        [pscustomobject]@{ path='scripts/Test-BlockedSupersessionTerminalValidation.ps1'; checks=@('blocked-supersession-terminal-validation') },
        [pscustomobject]@{ path='scripts/Test-CorrectActiveUnitContract.ps1'; checks=@('correct-active-unit-contract') },
        [pscustomobject]@{ path='schemas/active-unit-supersession-v1.schema.json'; checks=@('active-unit-supersession','work-unit-automation') },
        [pscustomobject]@{ path='scripts/ActiveUnitSupersession.psm1'; checks=@('active-unit-supersession','work-unit-automation') },
        [pscustomobject]@{ path='scripts/Test-ActiveUnitSupersession.ps1'; checks=@('active-unit-supersession','work-unit-automation') },
        [pscustomobject]@{ path='schemas/blocked-successor-preparation-receipt-v1.schema.json'; checks=@('blocked-successor-preparation','work-unit-automation') },
        [pscustomobject]@{ path='schemas/blocked-successor-preparation-v1.schema.json'; checks=@('blocked-successor-preparation','work-unit-automation') },
        [pscustomobject]@{ path='scripts/BlockedSuccessorPreparation.psm1'; checks=@('blocked-successor-preparation','work-unit-automation') },
        [pscustomobject]@{ path='scripts/Test-BlockedSuccessorPreparation.ps1'; checks=@('blocked-successor-preparation','work-unit-automation') },
        [pscustomobject]@{ path='schemas/terminal-validation-selection-release-v2.schema.json'; checks=@('normal-validation-selector') },
        [pscustomobject]@{ path='schemas/apk-run-phase-receipt-v1.schema.json'; checks=@('apk-run-transaction'); expected_tier='quick' },
        [pscustomobject]@{ path='schemas/apk-run-transaction-v1.schema.json'; checks=@('apk-run-transaction'); expected_tier='quick' },
        [pscustomobject]@{ path='tools/Test-ApkRunTransaction.ps1'; checks=@('apk-run-transaction'); expected_tier='quick' },
        [pscustomobject]@{ path='schemas/work-unit-automation-receipt-v2.schema.json'; checks=@('automation-receipt-v2-compatibility') },
        [pscustomobject]@{ path='scripts/Test-AutomationReceiptV2Compatibility.ps1'; checks=@('automation-receipt-v2-compatibility') },
        [pscustomobject]@{ path='scripts/WorkUnitAutomation.psm1'; checks=@('automation-receipt-v2-compatibility','normal-validation-selector','work-unit-automation','workflow-contracts') },
        [pscustomobject]@{ path='scripts/DevelopmentEnvelopeProvenance.psm1'; checks=@('development-envelope-preparation','development-unit-admission','public-boundary','workflow-contracts','work-unit-automation') },
        [pscustomobject]@{ path='scripts/DevelopmentEnvelopeRepreparation.psm1'; checks=@('automation-receipt-v2-compatibility','development-unit-admission','public-boundary','workflow-contracts','development-envelope-preparation','normal-validation-selector','work-unit-automation','validating-candidate-rematerialization') },
        [pscustomobject]@{ path='scripts/Test-HistoricalValidationDebtBaseline.ps1'; checks=@('historical-validation-debt-baseline') },
        [pscustomobject]@{ path='scripts/Test-HistoricalValidationDebtPhaseRunner.ps1'; checks=@('historical-validation-debt-phase-runner') },
        [pscustomobject]@{ path='scripts/Test-OwnershipAuthority.ps1'; checks=@('ownership-authority') },
        [pscustomobject]@{ path='scripts/Test-TransitionLedger.ps1'; checks=@('transition-ledger') },
        [pscustomobject]@{ path='schemas/development-unit-admission-v1.schema.json'; checks=@('development-unit-admission') },
        [pscustomobject]@{ path='scripts/DevelopmentUnitAdmission.psm1'; checks=@('development-unit-admission') },
        [pscustomobject]@{ path='scripts/Test-DevelopmentUnitAdmission.ps1'; checks=@('development-unit-admission') },
        [pscustomobject]@{ path='scripts/lib/MorphospaceBlockedSupersessionTerminalValidation.psm1'; checks=@('blocked-supersession-terminal-validation','workflow-contracts') },
        [pscustomobject]@{ path='scripts/lib/MorphospaceHistoricalValidationDebtPhaseRunner.psm1'; checks=@('historical-validation-debt-baseline','historical-validation-debt-phase-runner','work-unit-automation') },
        [pscustomobject]@{ path='scripts/lib/MorphospaceOwnership.psm1'; checks=@('authority-record-readiness','authority-runner-fast','ownership-authority','validation-execution-authority','work-unit-automation') },
        [pscustomobject]@{ path='scripts/lib/MorphospaceProtocolCommon.psm1'; checks=$protocolCommonConsumerChecks },
        [pscustomobject]@{ path='scripts/lib/MorphospaceTransitionLedger.psm1'; checks=@('blocked-supersession-terminal-validation','correct-active-unit-contract','development-unit-admission','transition-ledger','work-unit-automation') },
        [pscustomobject]@{ path='scripts/lib/MorphospaceValidationAuthority.psm1'; checks=@('authority-record-readiness','authority-runner-fast','authority-runner-handoff','transition-ledger','trust-migration-authority','validation-authority-launcher','validation-execution-authority','work-unit-automation') }
    )
    foreach ($mapping in $proportionalMappings) {
        $mappingPath = Join-Path $fixture ([string]$mapping.path)
        if (-not [IO.File]::Exists($mappingPath)) {
            Write-Utf8 $mappingPath $(if ([string]$mapping.path -like '*.json') { "{}`n" } else { "# proportional mapping fixture`n" })
        }
    }
    [void](Invoke-TestGit $fixture (@('add') + @($proportionalMappings.path)))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'proportional mapping fixture base'))
    $proportionalMappingHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $mappingOrdinal = 0
    foreach ($mapping in $proportionalMappings) {
        $mappingOrdinal++
        $mappingPath = Join-Path $fixture ([string]$mapping.path)
        $mappingBytes = Get-Content -LiteralPath $mappingPath -Raw
        if ([string]$mapping.path -like '*.json') { Write-Utf8 $mappingPath ($mappingBytes.TrimEnd() + "`n$(' ' * ($mappingOrdinal + 1))`n") }
        else { Write-Utf8 $mappingPath ($mappingBytes + "# proportional mapping probe $mappingOrdinal`n") }
        [void](Invoke-TestGit $fixture @('add', [string]$mapping.path))
        $stagedMappingPath = Invoke-TestGit $fixture @('diff', '--cached', '--name-only', '--')
        Assert-True ($stagedMappingPath -ceq [string]$mapping.path) "Proportional mapping probe '$mappingOrdinal' did not create one exact staged path: $stagedMappingPath"
        [void](Invoke-TestGit $fixture @('commit', '-m', "proportional mapping $mappingOrdinal"))
        $nextMappingHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
        $mappingPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $proportionalMappingHead -HeadRevision $nextMappingHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        $expectedTierProperty = $mapping.PSObject.Properties['expected_tier']
        $expectedMappingTier = if ($null -eq $expectedTierProperty -or [string]::IsNullOrWhiteSpace([string]$expectedTierProperty.Value)) { 'standard' } else { [string]$expectedTierProperty.Value }
        Assert-True ($mappingPlan.selection_mode -ceq 'affected' -and $mappingPlan.effective_tier -ceq $expectedMappingTier) "Proportional mapping for '$($mapping.path)' did not remain affected $expectedMappingTier."
        foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path','trust-root-path-changed')) { Assert-True (@($mappingPlan.reason_codes) -cnotcontains $reasonCode) "Proportional mapping for '$($mapping.path)' retained '$reasonCode'." }
        Assert-True (@($mappingPlan.selected_checks.check_id) -cnotcontains 'work-environment-deep') "Proportional mapping for '$($mapping.path)' selected the cumulative Deep aggregate."
        foreach ($checkId in @($mapping.checks)) { Assert-True (@($mappingPlan.selected_checks.check_id) -ccontains [string]$checkId) "Proportional mapping for '$($mapping.path)' omitted '$checkId'." }
        $proportionalMappingHead = $nextMappingHead
    }
    Write-Host "Trust proportional-mapping checks passed in $([long]$trustSegmentClock.Elapsed.TotalMilliseconds)ms."
    }

    if ($runFullSelector -or $runTrustDamagePhase) {
    $trustSegmentClock = [Diagnostics.Stopwatch]::StartNew()
    # The aggregate command is itself a distinct bounded path set.  Its direct
    # change must still select the registered Deep aggregate route without an
    # ambiguous or unmapped fallback.
    $workEnvironmentAggregateBase = if ($runFullSelector) { $proportionalMappingHead } else { $deleteHead }
    Write-Utf8 (Join-Path $fixture 'scripts/Test-WorkEnvironment.ps1') "# work environment aggregate change`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-WorkEnvironment.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'work environment aggregate change'))
    $workEnvironmentAggregateHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $workEnvironmentAggregatePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $workEnvironmentAggregateBase -HeadRevision $workEnvironmentAggregateHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier standard
    Assert-True ($workEnvironmentAggregatePlan.selection_mode -ceq 'affected') 'Work Environment aggregate change did not retain affected selection.'
    Assert-True ($workEnvironmentAggregatePlan.effective_tier -ceq 'deep') 'Work Environment aggregate change did not select its registered Deep tier.'
    foreach ($checkId in @('public-boundary','workflow-contracts','work-unit-automation','work-environment-deep')) { Assert-True (@($workEnvironmentAggregatePlan.selected_checks.check_id) -ccontains $checkId) "Work Environment aggregate change did not retain '$checkId' coverage." }
    foreach ($reasonCode in @('ambiguous-path-mapping','unmapped-path')) { Assert-True (@($workEnvironmentAggregatePlan.reason_codes) -cnotcontains $reasonCode) "Work Environment aggregate change retained '$reasonCode'." }

    $collisionBlobPath = Join-Path $fixture 'collision-blob.txt'
    Write-Utf8 $collisionBlobPath "collision`n"
    $collisionBlob = Invoke-TestGit $fixture @('hash-object', '-w', '--no-filters', $collisionBlobPath)
    $collisionBaseDocsTree = Invoke-TestGitInput $fixture @('mktree') "100644 blob $collisionBlob`tcollision.md`n"
    $collisionBaseTree = Invoke-TestGitInput $fixture @('mktree') "040000 tree $collisionBaseDocsTree`tdocs`n"
    $collisionBase = Invoke-TestGit $fixture @('commit-tree', $collisionBaseTree, '-p', $workEnvironmentAggregateBase, '-m', 'collision base')
    $collisionHeadDocsTree = Invoke-TestGitInput $fixture @('mktree') "100644 blob $collisionBlob`tCollision.md`n100644 blob $collisionBlob`tcollision.md`n"
    $collisionHeadTree = Invoke-TestGitInput $fixture @('mktree') "040000 tree $collisionHeadDocsTree`tdocs`n"
    $collisionHead = Invoke-TestGit $fixture @('commit-tree', $collisionHeadTree, '-p', $collisionBase, '-m', 'collision head')
    $affectedModule = Get-Module MorphospaceAffectedValidation
    $headTreeCollision = & $affectedModule { param($Root, $Commit) Test-MorphospaceAffectedTreeCaseCollision -RepositoryRoot $Root -Commit $Commit } $fixture $collisionHead
    Assert-True $headTreeCollision 'Changed path colliding with an unchanged case-folded head-tree path was not detected.'

    $invalid = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $invalid.checks[0].platforms = @('macos')
    $invalidFailed = $false
    try { [void](Test-MorphospaceAffectedValidationRegistry -Registry $invalid -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } catch { $invalidFailed = $true }
    Assert-True $invalidFailed 'Schema-invalid registry was accepted by the runtime validator.'

    $duplicateInvocation = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $duplicateInvocation.checks[1].command_path = [string]$duplicateInvocation.checks[0].command_path
    $duplicateInvocation.checks[1].arguments = @($duplicateInvocation.checks[0].arguments)
    $duplicateInvocationFailed = $false
    try { [void](Test-MorphospaceAffectedValidationRegistry -Registry $duplicateInvocation -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } catch { $duplicateInvocationFailed = $_.Exception.Message -like '*repeat exact command/argument invocation*' }
    Assert-True $duplicateInvocationFailed 'Registry accepted a duplicate exact command/argument invocation.'

    $aggregateRoleDamage = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $aggregateRoleDamage.checks | Where-Object { $_.check_id -ceq 'documentation-links' } | ForEach-Object { $_ | Add-Member -NotePropertyName aggregate_role -NotePropertyValue 'work-environment-deep-v1' }
    $aggregateRoleFailed = $false
    try { [void](Test-MorphospaceAffectedValidationRegistry -Registry $aggregateRoleDamage -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } catch { $aggregateRoleFailed = $_.Exception.Message -like '*exact closed Work Environment Deep aggregate*' }
    Assert-True $aggregateRoleFailed 'Registry allowed an independent leaf to impersonate the cumulative Deep aggregate role.'

    $crossPlatform = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $crossPlatform.checks | Where-Object { $_.check_id -ceq 'work-unit-automation' } | ForEach-Object { $_.prerequisite_checks = @('documentation-links') }
    $crossPlatformFailed = $false
    try { [void](Test-MorphospaceAffectedValidationRegistry -Registry $crossPlatform -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } catch { $crossPlatformFailed = $_.Exception.Message -like '*cross-platform*' }
    Assert-True $crossPlatformFailed 'Registry accepted an unsatisfied cross-platform prerequisite.'

    $unknownExecutionOrder = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $unknownExecutionOrder.checks | Where-Object { $_.check_id -ceq 'documentation-links' } | ForEach-Object { $_.execution_after_checks = @('missing-order-anchor') }
    Assert-AffectedThrows { [void](Test-MorphospaceAffectedValidationRegistry -Registry $unknownExecutionOrder -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } '*unknown execution-order dependency*' 'Registry accepted an unknown execution-order dependency.'

    $crossPlatformExecutionOrder = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $crossPlatformExecutionOrder.checks | Where-Object { $_.check_id -ceq 'work-unit-automation' } | ForEach-Object { $_ | Add-Member -NotePropertyName execution_after_checks -NotePropertyValue @('documentation-links') }
    Assert-AffectedThrows { [void](Test-MorphospaceAffectedValidationRegistry -Registry $crossPlatformExecutionOrder -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } '*cross-platform execution-order dependency*' 'Registry accepted an unsatisfied cross-platform execution-order dependency.'

    $duplicateExecutionOrder = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $duplicateExecutionOrder.checks | Where-Object { $_.check_id -ceq 'documentation-links' } | ForEach-Object { $_.execution_after_checks = @('public-boundary','public-boundary') }
    Assert-AffectedThrows { [void](Test-MorphospaceAffectedValidationRegistry -Registry $duplicateExecutionOrder -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } '*repeats execution-order dependency*' 'Registry accepted a duplicate execution-order dependency.'

    $executionOrderSelf = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $executionOrderSelf.checks | Where-Object { $_.check_id -ceq 'documentation-links' } | ForEach-Object { $_.execution_after_checks = @('documentation-links') }
    Assert-AffectedThrows { [void](Test-MorphospaceAffectedValidationRegistry -Registry $executionOrderSelf -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } '*cannot depend on itself*' 'Registry accepted a self-referential execution-order dependency.'

    $duplicateDependencyKind = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $duplicateDependencyKind.checks | Where-Object { $_.check_id -ceq 'documentation-links' } | ForEach-Object { $_.prerequisite_checks = @('public-boundary') }
    Assert-AffectedThrows { [void](Test-MorphospaceAffectedValidationRegistry -Registry $duplicateDependencyKind -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } '*both a semantic prerequisite and an execution-order dependency*' 'Registry accepted the same dependency in both semantic and execution-order fields.'

    $contractMislabel = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $contractMislabel.checks | Where-Object { $_.check_id -ceq 'documentation-links' } | ForEach-Object { $_.consumes_contracts = @('public-boundary') }
    Assert-AffectedThrows { [void](Test-MorphospaceAffectedValidationRegistry -Registry $contractMislabel -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } '*must be a semantic prerequisite*' 'Registry accepted a contract-carrying dependency as execution order only.'

    $executionOrderCycle = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $executionOrderCycle.checks | Where-Object { $_.check_id -ceq 'public-boundary' } | ForEach-Object { $_ | Add-Member -NotePropertyName execution_after_checks -NotePropertyValue @('documentation-links') }
    Assert-AffectedThrows { [void](Test-MorphospaceAffectedValidationRegistry -Registry $executionOrderCycle -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } '*cycle*' 'Registry accepted a cycle spanning execution-order dependencies.'

    $uncovered = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $uncovered.checks | Where-Object { $_.check_id -ceq 'public-boundary' } | ForEach-Object { $_.consume_path_sets = @($_.consume_path_sets | Where-Object { $_ -cne 'automation' }) }
    $uncoveredFailed = $false
    try { [void](Test-MorphospaceAffectedValidationRegistry -Registry $uncovered -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } catch { $uncoveredFailed = $_.Exception.Message -like '*public-boundary*automation*' }
    Assert-True $uncoveredFailed 'Registry accepted automation outside public-boundary coverage.'

    $untriggered = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $untriggered.checks | Where-Object { $_.check_id -ceq 'public-boundary' } | ForEach-Object { $_.trigger_path_sets = @($_.trigger_path_sets | Where-Object { $_ -cne 'automation' }) }
    $untriggeredFailed = $false
    try { [void](Test-MorphospaceAffectedValidationRegistry -Registry $untriggered -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } catch { $untriggeredFailed = $_.Exception.Message -like '*Public-boundary does not trigger*automation*' }
    Assert-True $untriggeredFailed 'Registry accepted automation outside public-boundary triggers.'

    $cycle = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $cycle.checks[0].prerequisite_checks = @([string]$cycle.checks[1].check_id)
    $cycle.checks[1].prerequisite_checks = @([string]$cycle.checks[0].check_id)
    $cycleFailed = $false
    try { [void](Test-MorphospaceAffectedValidationRegistry -Registry $cycle -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } catch { $cycleFailed = $_.Exception.Message -like '*cycle*' }
    Assert-True $cycleFailed 'Prerequisite cycle was not rejected.'

    Write-Utf8 (Join-Path $fixture 'docs/ä.md') "a umlaut`n"
    Write-Utf8 (Join-Path $fixture 'docs/z.md') "z`n"
    [void](Invoke-TestGit $fixture @('add', 'docs/ä.md', 'docs/z.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'unicode paths'))
    $cultureHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $savedCulture = [System.Globalization.CultureInfo]::CurrentCulture
    $savedUiCulture = [System.Globalization.CultureInfo]::CurrentUICulture
    try {
        [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
        [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
        $englishPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $workEnvironmentAggregateBase -HeadRevision $cultureHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('sv-SE')
        [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('sv-SE')
        $swedishPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $workEnvironmentAggregateBase -HeadRevision $cultureHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        Assert-True ($englishPlan.plan_sha256 -ceq $swedishPlan.plan_sha256) 'Unicode path plan changed with host culture.'
        $englishPlanBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $englishPlan) + "`n")
        $swedishPlanBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $swedishPlan) + "`n")
        Assert-True ([System.Linq.Enumerable]::SequenceEqual[byte]($englishPlanBytes, $swedishPlanBytes)) 'Unicode canonical plan bytes changed with host culture.'
    } finally {
        [System.Globalization.CultureInfo]::CurrentCulture = $savedCulture
        [System.Globalization.CultureInfo]::CurrentUICulture = $savedUiCulture
    }

    $ambiguousRegistry = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $ambiguousRegistry.path_sets = @($ambiguousRegistry.path_sets) + @([pscustomobject][ordered]@{ path_set_id = 'documentation-overlap'; patterns = @('docs/**') })
    $ambiguousRegistry.checks | Where-Object { $_.check_id -ceq 'public-boundary' } | ForEach-Object { $_.consume_path_sets = @($_.consume_path_sets) + @('documentation-overlap'); $_.trigger_path_sets = @($_.trigger_path_sets) + @('documentation-overlap') }
    Write-Utf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson -Value $ambiguousRegistry) + "`n")
    [void](Invoke-TestGit $fixture @('add', 'manifests/affected-validation-registry.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'ambiguous registry baseline'))
    $ambiguousBase = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    Write-Utf8 (Join-Path $fixture 'docs/z.md') "ambiguous mapping`n"
    [void](Invoke-TestGit $fixture @('add', 'docs/z.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'ambiguous path'))
    $ambiguousHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $ambiguousPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $ambiguousBase -HeadRevision $ambiguousHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($ambiguousPlan.selection_mode -ceq 'full-deep') 'Ambiguous path-set mapping did not fail closed to Deep.'
    Assert-True (@($ambiguousPlan.reason_codes) -ccontains 'ambiguous-path-mapping') 'Ambiguous path-set mapping lacks its explicit reason.'

    $headDriftFailed = $false
    try { [void](Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $deleteHead -HeadRevision $workEnvironmentAggregateBase -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick) } catch { $headDriftFailed = $_.Exception.Message -like '*worktree HEAD*' }
    Assert-True $headDriftFailed 'Clean worktree HEAD drift was not rejected explicitly.'

    [void](Invoke-TestGit $fixture @('checkout', '--detach', $base))
    Write-Utf8 (Join-Path $fixture 'docs/side.md') "side`n"
    [void](Invoke-TestGit $fixture @('add', 'docs/side.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'non-ancestor side'))
    $sideHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $nonAncestorFailed = $false
    try { [void](Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $ambiguousHead -HeadRevision $sideHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick) } catch { $nonAncestorFailed = $_.Exception.Message -like '*base to be an ancestor*' }
    Assert-True $nonAncestorFailed 'Non-ancestor comparison was not rejected.'
    Write-Host "Trust damage/culture checks passed in $([long]$trustSegmentClock.Elapsed.TotalMilliseconds)ms."
    }
    }
} finally {
    if ([System.IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    if ($null -ne $selectionScenarioContext -and $selectionScenarioContext.ephemeral -and [IO.Directory]::Exists($selectionScenarioContext.root)) {
        Remove-Item -LiteralPath $selectionScenarioContext.root -Recurse -Force
    }
}

$selectorSelfTestClock.Stop()
if ($runFullSelector) {
    Write-Host "Legacy cumulative selector diagnostic passed in $([long]$selectorSelfTestClock.Elapsed.TotalMilliseconds)ms; admission uses the finite phased registry DAG."
} else {
    Write-Host "Affected-validation self-test phase '$SelfTestPhase' passed in $([long]$selectorSelfTestClock.Elapsed.TotalMilliseconds)ms."
}
