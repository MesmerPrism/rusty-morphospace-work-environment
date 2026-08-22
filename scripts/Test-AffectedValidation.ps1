[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceAffectedValidation.psm1') -Force

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
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

$registryPath = Join-Path $repoRoot 'manifests/affected-validation-registry.json'
$registry = Read-MorphospaceProtocolJson -Path $registryPath
[void](Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $repoRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json'))

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('morphospace-affected-validation-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($fixture)
try {
    [void](Invoke-TestGit $fixture @('init', '--initial-branch=main'))
    [void](Invoke-TestGit $fixture @('config', 'user.name', 'Affected Validation Test'))
    [void](Invoke-TestGit $fixture @('config', 'user.email', 'affected-validation@example.invalid'))
    foreach ($directory in @('docs', 'scripts', 'scripts/lib', 'schemas', 'manifests', 'skills/example')) { [void][System.IO.Directory]::CreateDirectory((Join-Path $fixture $directory)) }
    foreach ($command in @($registry.checks.command_path | Sort-Object -Unique)) { $target = Join-Path $fixture ([string]$command); [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)); Write-Utf8 $target "# fixture`n" }
    Copy-Item -LiteralPath $registryPath -Destination (Join-Path $fixture 'manifests/affected-validation-registry.json')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json') -Destination (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')
    Write-Utf8 (Join-Path $fixture 'docs/base.md') "base`n"
    [void](Invoke-TestGit $fixture @('add', '.'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'base'))
    $base = Invoke-TestGit $fixture @('rev-parse', 'HEAD')

    Write-Utf8 (Join-Path $fixture 'docs/base.md') "changed`n"
    [void](Invoke-TestGit $fixture @('add', 'docs/base.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'docs'))
    $docsHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $docsPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $base -HeadRevision $docsHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($docsPlan.selection_mode -ceq 'affected') 'Documentation change did not remain affected-only.'
    Assert-True (@($docsPlan.selected_checks.check_id) -ccontains 'documentation-links') 'Documentation check was not selected.'
    Assert-True (@($docsPlan.selected_checks.check_id) -cnotcontains 'work-unit-automation') 'Unrelated automation check was selected for documentation.'
    Assert-True (-not [bool]$docsPlan.claims.checks_executed) 'Shadow plan claimed check execution.'
    foreach ($invalidPath in @('docs/', '   ')) {
        $damagedPlan = ConvertFrom-Json -InputObject (ConvertTo-MorphospaceCanonicalJson -Value $docsPlan) -Depth 64
        $damagedPlan.changed_paths[0].new_path = $invalidPath
        $damagedAccepted = Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $damagedPlan) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-plan-v1.schema.json') -ErrorAction SilentlyContinue
        Assert-True (-not $damagedAccepted) "Plan schema accepted noncanonical path '$invalidPath'."
    }

    Write-Utf8 (Join-Path $fixture 'scripts/new-owner.ps1') "# owner`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/new-owner.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'script'))
    $scriptHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $scriptPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $docsHead -HeadRevision $scriptHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True (@($scriptPlan.selected_checks.check_id) -ccontains 'workflow-contracts') 'Workflow check was not selected for scripts.'
    Assert-True (@($scriptPlan.selected_checks.check_id) -ccontains 'work-unit-automation') 'Automation consumer was not selected for scripts.'
    Assert-True ((@($scriptPlan.selected_checks | Where-Object check_id -ceq 'work-unit-automation').reasons) -clike 'consumer-of:workflow-contracts:*') 'Automation consumer lacks transitive consumer reason.'
    Assert-True ($scriptPlan.effective_tier -ceq 'standard') 'Script change did not escalate to Standard.'

    Write-Utf8 (Join-Path $fixture 'unknown.bin') "unknown`n"
    [void](Invoke-TestGit $fixture @('add', 'unknown.bin'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'unknown'))
    $unknownHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $unknownPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $scriptHead -HeadRevision $unknownHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($unknownPlan.selection_mode -ceq 'full-deep') 'Unmapped change did not fail closed to Deep.'
    Assert-True (@($unknownPlan.reason_codes) -ccontains 'unmapped-path') 'Unmapped change lacks reason code.'
    Assert-True (@($unknownPlan.selected_checks).Count -eq @($registry.checks).Count) 'Deep fallback did not select every check.'

    [void](Invoke-TestGit $fixture @('mv', 'docs/base.md', 'docs/renamed.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'rename'))
    $renameHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $renamePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $unknownHead -HeadRevision $renameHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True (@($renamePlan.changed_paths)[0].status.StartsWith('R')) 'Rename identity was not retained.'
    Assert-True ($null -ne @($renamePlan.changed_paths)[0].old_blob -and $null -ne @($renamePlan.changed_paths)[0].new_blob) 'Rename blobs were not bound.'

    $repeatPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $unknownHead -HeadRevision $renameHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($repeatPlan.plan_sha256 -ceq $renamePlan.plan_sha256) 'Repeated plan was not deterministic.'
    $renamePlanBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $renamePlan) + "`n")
    $repeatPlanBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $repeatPlan) + "`n")
    Assert-True ([System.Linq.Enumerable]::SequenceEqual[byte]($renamePlanBytes, $repeatPlanBytes)) 'Repeated canonical plan bytes were not identical.'

    $noChangePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $renameHead -HeadRevision $renameHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True (@($noChangePlan.changed_paths).Count -eq 0) 'Base=head did not emit an empty changed-path inventory.'
    Assert-True (@($noChangePlan.reason_codes) -ccontains 'no-changed-paths') 'Base=head lacks its reason code.'

    Remove-Item -LiteralPath (Join-Path $fixture 'docs/renamed.md')
    [void](Invoke-TestGit $fixture @('add', '--update', 'docs/renamed.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'delete'))
    $deleteHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $deletePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $renameHead -HeadRevision $deleteHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True (@($deletePlan.changed_paths).Count -eq 1 -and @($deletePlan.changed_paths)[0].status -ceq 'D') 'Delete identity was not retained.'
    Assert-True ($null -ne @($deletePlan.changed_paths)[0].old_blob -and $null -eq @($deletePlan.changed_paths)[0].new_blob) 'Delete blob boundary was not bound.'
    Assert-True (@($deletePlan.selected_checks.check_id) -ccontains 'documentation-links') 'Deleted documentation did not retain its owner check.'

    Write-Utf8 (Join-Path $fixture 'scripts/Test-AffectedValidation.ps1') "# selector changed`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-AffectedValidation.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'selector self change'))
    $selectorHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $selectorPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $deleteHead -HeadRevision $selectorHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($selectorPlan.selection_mode -ceq 'full-deep') 'Selector self-change did not fail closed to Deep.'
    Assert-True (@($selectorPlan.reason_codes) -ccontains 'trust-root-path-changed') 'Selector self-change lacks its trust-root reason.'
    Assert-True (@($selectorPlan.selected_checks).Count -eq @($registry.checks).Count) 'Selector self-change did not select every check.'

    $collisionBlobPath = Join-Path $fixture 'collision-blob.txt'
    Write-Utf8 $collisionBlobPath "collision`n"
    $collisionBlob = Invoke-TestGit $fixture @('hash-object', '-w', '--no-filters', $collisionBlobPath)
    $collisionBaseDocsTree = Invoke-TestGitInput $fixture @('mktree') "100644 blob $collisionBlob`tcollision.md`n"
    $collisionBaseTree = Invoke-TestGitInput $fixture @('mktree') "040000 tree $collisionBaseDocsTree`tdocs`n"
    $collisionBase = Invoke-TestGit $fixture @('commit-tree', $collisionBaseTree, '-p', $selectorHead, '-m', 'collision base')
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
        $englishPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $selectorHead -HeadRevision $cultureHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
        [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('sv-SE')
        [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('sv-SE')
        $swedishPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $selectorHead -HeadRevision $cultureHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
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
    try { [void](Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $deleteHead -HeadRevision $selectorHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick) } catch { $headDriftFailed = $_.Exception.Message -like '*worktree HEAD*' }
    Assert-True $headDriftFailed 'Clean worktree HEAD drift was not rejected explicitly.'

    [void](Invoke-TestGit $fixture @('checkout', '--detach', $base))
    Write-Utf8 (Join-Path $fixture 'docs/side.md') "side`n"
    [void](Invoke-TestGit $fixture @('add', 'docs/side.md'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'non-ancestor side'))
    $sideHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $nonAncestorFailed = $false
    try { [void](Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $ambiguousHead -HeadRevision $sideHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick) } catch { $nonAncestorFailed = $_.Exception.Message -like '*base to be an ancestor*' }
    Assert-True $nonAncestorFailed 'Non-ancestor comparison was not rejected.'
} finally {
    if ([System.IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

Write-Host 'Affected-validation shadow selector self-test passed.'
