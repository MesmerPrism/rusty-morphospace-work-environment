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
function Invoke-WorkflowSelectionGate([string]$JobBody, [string]$SelectionVariable, [string]$SelectionValue) {
    $run = [regex]::Match($JobBody, '(?ms)^        run: \|\r?\n(?<script>.*?)(?=^      - |\z)')
    if (-not $run.Success) { throw 'Workflow job lacks a first run script.' }
    $lines = @($run.Groups['script'].Value -split "`r?`n" | Select-Object -First 3)
    if ($lines.Count -ne 3) { throw 'Workflow job lacks the closed selection gate.' }
    $gate = ($lines -join [Environment]::NewLine).Replace('exit 0', 'return')
    $saved = @{}
    foreach ($name in @('INFRA_RESULT','SELECT_RESULT',$SelectionVariable)) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $env:INFRA_RESULT = 'success'; $env:SELECT_RESULT = 'success'
        [Environment]::SetEnvironmentVariable($SelectionVariable, $SelectionValue, 'Process')
        & ([scriptblock]::Create($gate))
    } finally {
        foreach ($name in @('INFRA_RESULT','SELECT_RESULT',$SelectionVariable)) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

    $registryPath = Join-Path $repoRoot 'manifests/affected-validation-registry.json'
    $registry = Read-MorphospaceProtocolJson -Path $registryPath
    [void](Test-MorphospaceAffectedValidationRegistry -Registry $registry -RepositoryRoot $repoRoot -SchemaPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json'))
    $selectorBudget = @($registry.checks | Where-Object { $_.check_id -ceq 'affected-selector-selftest' })[0].budget_seconds
    Assert-True ([int]$selectorBudget -eq 180) 'Selector self-test lacks its independently measured three-minute budget.'
    $workflowSource = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/validate.yml') -Raw
    $workflowJobs = @{}
    foreach ($match in [regex]::Matches($workflowSource, '(?ms)^  (?<id>[a-z0-9-]+):\r?\n(?<body>.*?)(?=^  [a-z0-9-]+:|\z)')) { $workflowJobs[[string]$match.Groups['id'].Value] = [string]$match.Groups['body'].Value }
    foreach ($requiredContext in @('quick-linux','quick-windows','standard-windows')) { Assert-True $workflowJobs.ContainsKey($requiredContext) "PR workflow lacks the required '$requiredContext' context." }
    foreach ($selectedContext in @(@{ id = 'quick-linux'; selected = 'LINUX_SELECTED' }, @{ id = 'standard-windows'; selected = 'WINDOWS_SELECTED' })) {
        $body = [string]$workflowJobs[[string]$selectedContext.id]
        Assert-True ($body -match '(?m)^    needs: \[infrastructure, select\]$' -and $body -match "\`$env:$($selectedContext.selected) -cnotin @\('true','false'\)" -and $body -match "\`$env:$($selectedContext.selected) -ceq 'false'") "Required '$($selectedContext.id)' context does not close its platform-selection domain."
        Assert-True ($body -match "\`$env:INFRA_RESULT -cne 'success'" -and $body -match "\`$env:SELECT_RESULT -cne 'success'") "Required '$($selectedContext.id)' context can bypass failed selection prerequisites."
        foreach ($selectionValue in @('', 'unexpected')) {
            $rejected = $false
            try { Invoke-WorkflowSelectionGate -JobBody $body -SelectionVariable ([string]$selectedContext.selected) -SelectionValue $selectionValue } catch { $rejected = $_.Exception.Message -like '*must be exactly true or false*' }
            Assert-True $rejected "Required '$($selectedContext.id)' context accepted '$selectionValue' as a platform selection."
        }
        Invoke-WorkflowSelectionGate -JobBody $body -SelectionVariable ([string]$selectedContext.selected) -SelectionValue 'true'
        Invoke-WorkflowSelectionGate -JobBody $body -SelectionVariable ([string]$selectedContext.selected) -SelectionValue 'false'
    }
    $quickWindowsBody = [string]$workflowJobs['quick-windows']
    Assert-True ($quickWindowsBody -match '(?m)^    needs: \[infrastructure, select, standard-windows\]$' -and $quickWindowsBody -match "\`$env:STANDARD_RESULT -cne 'success'") 'Required quick-windows context is not bound to the selected Windows result.'
    Assert-True ($quickWindowsBody -notmatch 'Invoke-AffectedValidation') 'Required quick-windows context replays the selected Windows suite.'
    foreach ($platform in @('linux','windows')) {
        $artifactMarker = "affected-$platform-evidence.json"
        $artifactIndex = $workflowSource.IndexOf($artifactMarker, [StringComparison]::Ordinal)
        Assert-True ($artifactIndex -ge 0) "PR workflow lacks the $platform evidence artifact."
        $beforeArtifact = $workflowSource.Substring(0, $artifactIndex)
        $afterArtifact = $workflowSource.Substring($artifactIndex)
        Assert-True ($beforeArtifact.LastIndexOf('$failure = $null', [StringComparison]::Ordinal) -ge 0 -and $afterArtifact.IndexOf('if ($null -ne $failure) { throw $failure }', [StringComparison]::Ordinal) -ge 0) "PR workflow can signal $platform execution failure before binding its evidence digest."
    }

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('morphospace-affected-validation-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($fixture)
try {
    [void](Invoke-TestGit $fixture @('init', '--initial-branch=main'))
    [void](Invoke-TestGit $fixture @('config', 'user.name', 'Affected Validation Test'))
    [void](Invoke-TestGit $fixture @('config', 'user.email', 'affected-validation@example.invalid'))
    foreach ($directory in @('docs', 'scripts', 'scripts/lib', 'schemas', 'manifests', 'skills/example')) { [void][System.IO.Directory]::CreateDirectory((Join-Path $fixture $directory)) }
    foreach ($command in @($registry.checks.command_path | Sort-Object -Unique)) { $target = Join-Path $fixture ([string]$command); [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)); Write-Utf8 $target "# fixture`n" }
    $fixtureRegistry = Read-MorphospaceProtocolJson -Path $registryPath
    # Keep the timeout damage cell bounded while preserving the production
    # selector's independently reviewed three-minute self-test budget.
    $fixtureRegistry.checks | Where-Object { $_.check_id -ceq 'public-boundary' } | ForEach-Object { $_.budget_seconds = 1 }
    Write-Utf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson -Value $fixtureRegistry) + "`n")
    Copy-Item -LiteralPath (Join-Path $repoRoot 'schemas/affected-validation-registry-v1.schema.json') -Destination (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'schemas/history-archive-root-v1.schema.json') -Destination (Join-Path $fixture 'schemas/history-archive-root-v1.schema.json')
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
    Assert-True ([bool]$docsPlan.claims.selection_only -and -not [bool]$docsPlan.claims.checks_executed) 'Selection plan claimed check execution or lifecycle authority.'
    Assert-True (@($docsPlan.selected_checks | Where-Object { @($_.platforms) -ccontains 'windows' }).Count -eq 0) 'Documentation change unnecessarily selected a Windows suite.'
    $planPath = Join-Path $fixture 'affected-plan.json'
    $evidencePath = Join-Path $fixture 'affected-evidence.json'
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $docsPlan) + "`n")
    $evidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $base -HeadCommit $docsHead -PlanPath $planPath -Platform linux -OutPath $evidencePath
    Assert-True ([IO.File]::Exists($evidencePath)) 'Affected executor did not publish evidence.'
    Assert-True ($evidence.result -ceq 'pass' -and @($evidence.check_results).Count -ge 2) 'Affected executor did not bind selected checks into pass evidence.'
    Assert-True (@($evidence.check_results | Where-Object { $_.stdout_sha256 -notmatch '^[0-9a-f]{64}$' -or $_.stderr_sha256 -notmatch '^[0-9a-f]{64}$' -or $_.timed_out -or $_.output_truncated -or $_.post_kill_drain_timed_out }).Count -eq 0) 'Affected executor omitted bounded child-output evidence.'
    $impossiblePass = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
    $impossiblePass.check_results[0].exit_code = 1
    Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $impossiblePass) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Evidence schema accepted pass with a nonzero child exit.'
    $impossibleDrainPass = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
    $impossibleDrainPass.check_results[0].post_kill_drain_timed_out = $true
    Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $impossibleDrainPass) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Evidence schema accepted pass with a post-kill drain timeout.'
    $drainCodeFailure = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
    $drainCodeFailure.result = 'code-fail'; $drainCodeFailure.check_results[0].result = 'code-fail'; $drainCodeFailure.check_results[0].exit_code = $null; $drainCodeFailure.check_results[0].post_kill_drain_timed_out = $true
    Assert-True (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $drainCodeFailure) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction Stop) 'Evidence schema rejected the required code-fail post-kill drain shape.'
    $mixedFailure = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
    $mixedFailure.result = 'code-fail'; $mixedFailure.check_results[0].result = 'code-fail'; $mixedFailure.check_results[0].exit_code = 1; $mixedFailure.check_results[1].result = 'infra-fail'; $mixedFailure.check_results[1].exit_code = $null
    Assert-True (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $mixedFailure) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) 'Evidence schema accepted mixed code-fail and infra-fail aggregate precedence.'
    $impossiblePending = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
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

    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "exit 17`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'failing affected command'))
    $failingHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $failingPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $docsHead -HeadRevision $failingHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $failingPlan) + "`n")
    $failingEvidencePath = Join-Path $fixture 'failing-evidence.json'
    $codeFailed = $false
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $docsHead -HeadCommit $failingHead -PlanPath $planPath -Platform linux -OutPath $failingEvidencePath) } catch { $codeFailed = $_.Exception.Message -like '*code-fail*' }
    Assert-True $codeFailed 'Affected executor swallowed a native nonzero exit.'
    $failingEvidence = Read-MorphospaceProtocolJson -Path $failingEvidencePath
    Assert-True ($failingEvidence.result -ceq 'code-fail' -and @($failingEvidence.check_results | Where-Object { $_.exit_code -eq 17 -and $_.result -ceq 'code-fail' }).Count -eq 1) 'Affected executor did not preserve the native nonzero exit in evidence.'
    $failedEvidenceDigest = (Get-FileHash -LiteralPath $failingEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($failedEvidenceDigest -match '^[0-9a-f]{64}$') 'Failed executor evidence did not receive a content digest.'
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "[Console]::Out.Write(('x' * 10485761) -join '')`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'oversized affected output'))
    $oversizedHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $oversizedPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $failingHead -HeadRevision $oversizedHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $oversizedPlan) + "`n")
    $oversizedEvidencePath = Join-Path $fixture 'oversized-evidence.json'
    $oversizedFailed = $false
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $failingHead -HeadCommit $oversizedHead -PlanPath $planPath -Platform linux -OutPath $oversizedEvidencePath) } catch { $oversizedFailed = $_.Exception.Message -like '*code-fail*' }
    Assert-True $oversizedFailed 'Affected executor accepted an over-ceiling child output.'
    $oversizedEvidence = Read-MorphospaceProtocolJson -Path $oversizedEvidencePath
    Assert-True ($oversizedEvidence.result -ceq 'code-fail' -and @($oversizedEvidence.check_results | Where-Object { $_.result -ceq 'code-fail' -and $_.output_truncated -and $_.stdout_bytes -le 10485760 -and $_.stderr_bytes -le 10485760 }).Count -eq 1) 'Affected executor did not bind the output-ceiling check failure.'
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "Start-Sleep -Seconds 3`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'timed-out affected command'))
    $timeoutHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $timeoutPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $oversizedHead -HeadRevision $timeoutHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $timeoutPlan) + "`n")
    $timeoutEvidencePath = Join-Path $fixture 'timeout-evidence.json'
    $timeoutFailed = $false
    try { [void](& (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $oversizedHead -HeadCommit $timeoutHead -PlanPath $planPath -Platform linux -OutPath $timeoutEvidencePath) } catch { $timeoutFailed = $_.Exception.Message -like '*code-fail*' }
    Assert-True $timeoutFailed 'Affected executor accepted a timed-out child.'
    $timeoutEvidence = Read-MorphospaceProtocolJson -Path $timeoutEvidencePath
    Assert-True ($timeoutEvidence.result -ceq 'code-fail' -and @($timeoutEvidence.check_results | Where-Object { $_.result -ceq 'code-fail' -and $_.timed_out }).Count -eq 1) 'Affected executor did not classify a child timeout as code-fail.'
    Write-Utf8 (Join-Path $fixture 'scripts/Test-PublicBoundary.ps1') "# fixture`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-PublicBoundary.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'restore bounded affected command'))
    $restoredHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    foreach ($invalidPath in @('docs/', '   ')) {
        $damagedPlan = ConvertFrom-Json -InputObject (ConvertTo-MorphospaceCanonicalJson -Value $docsPlan) -Depth 64
        $damagedPlan.changed_paths[0].new_path = $invalidPath
        $damagedAccepted = Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $damagedPlan) -SchemaFile (Join-Path $repoRoot 'schemas/affected-validation-plan-v1.schema.json') -ErrorAction SilentlyContinue
        Assert-True (-not $damagedAccepted) "Plan schema accepted noncanonical path '$invalidPath'."
    }

    Write-Utf8 (Join-Path $fixture 'scripts/WorkUnitAutomation.psm1') "# automation`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/WorkUnitAutomation.psm1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'automation'))
    $automationHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $automationPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $restoredHead -HeadRevision $automationHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($automationPlan.selection_mode -ceq 'affected') 'Mapped automation change did not retain affected selection.'
    Assert-True (@($automationPlan.selected_checks.check_id) -ccontains 'public-boundary') 'Automation change did not trigger the public-boundary gate.'
    Assert-True (@($automationPlan.selected_checks | Where-Object { @($_.platforms) -ccontains 'windows' }).Count -ge 2) 'Automation change did not select its Windows integration closure.'

    Write-Utf8 (Join-Path $fixture 'scripts/new-owner.ps1') "# owner`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/new-owner.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'script'))
    $scriptHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $scriptPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $automationHead -HeadRevision $scriptHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($scriptPlan.selection_mode -ceq 'full-deep') 'An unmapped script did not fail closed to Deep.'
    Assert-True (@($scriptPlan.reason_codes) -ccontains 'unmapped-path') 'Unmapped script lacks its explicit reason.'

    Write-Utf8 (Join-Path $fixture 'scripts/Test-DocumentationLinks.ps1') "# changed documentation owner`n"
    Write-Utf8 (Join-Path $fixture 'scripts/Test-SkillTemplates.ps1') "# changed skill owner`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-DocumentationLinks.ps1', 'scripts/Test-SkillTemplates.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'owner commands'))
    $commandHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $commandPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $scriptHead -HeadRevision $commandHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    foreach ($ownerId in @('documentation-links', 'skill-templates')) {
        Assert-True ((@($commandPlan.selected_checks.check_id) -ccontains $ownerId)) "Changed command did not select owning check '$ownerId'."
        Assert-True ((@($commandPlan.selected_checks | Where-Object check_id -ceq $ownerId).reasons -ccontains 'command-path-changed')) "Changed command lacks owning reason for '$ownerId'."
    }

    Write-Utf8 (Join-Path $fixture 'unknown.bin') "unknown`n"
    [void](Invoke-TestGit $fixture @('add', 'unknown.bin'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'unknown'))
    $unknownHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $unknownPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $commandHead -HeadRevision $unknownHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
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
    Assert-True ($selectorPlan.selection_mode -ceq 'affected') 'Selector self-change did not retain current-delta selection.'
    Assert-True (@($selectorPlan.selected_checks.check_id) -ccontains 'affected-selector-selftest') 'Selector self-change did not retain the selector self-test.'
    Assert-True (@($selectorPlan.selected_checks.check_id) -cnotcontains 'work-environment-deep') 'Selector self-change incorrectly selected the historical Deep aggregate.'
    Assert-True (@($selectorPlan.reason_codes) -cnotcontains 'trust-root-path-changed') 'Selector self-change incorrectly recorded a Deep-escalation reason.'
    foreach ($selfTestId in @('affected-selector-selftest','affected-topology-selftest','affected-reuse-selftest')) { Assert-True (@($selectorPlan.selected_checks.check_id) -ccontains $selfTestId) "Selector trust-root change does not execute '$selfTestId' through the PR-owned selection path." }
    Write-Utf8 $planPath ((ConvertTo-MorphospaceCanonicalJson -Value $selectorPlan) + "`n")
    $selectorEvidence = & (Join-Path $repoRoot 'scripts/Invoke-AffectedValidation.ps1') -RepositoryRoot $fixture -BaseCommit $deleteHead -HeadCommit $selectorHead -PlanPath $planPath -Platform linux -OutPath (Join-Path $fixture 'selector-evidence.json')
    Assert-True ($selectorEvidence.result -ceq 'pass') 'Actual bounded executor did not complete the trust-root self-test closure.'
    foreach ($selfTestId in @('affected-selector-selftest','affected-topology-selftest','affected-reuse-selftest')) { Assert-True (@($selectorEvidence.check_results.check_id) -ccontains $selfTestId) "Actual bounded executor did not run '$selfTestId'." }
    Write-Utf8 (Join-Path $fixture 'scripts/Test-AffectedValidationInfrastructure.ps1') "# changed infrastructure classifier`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Test-AffectedValidationInfrastructure.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'infrastructure classifier'))
    $infrastructureHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $infrastructurePlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $selectorHead -HeadRevision $infrastructureHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($infrastructurePlan.selection_mode -ceq 'affected' -and @($infrastructurePlan.selected_checks.check_id) -ccontains 'affected-selector-selftest') 'Infrastructure classifier change did not retain bounded selector coverage.'

    $contractRegistry = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $contractRegistry.revision = [long]$contractRegistry.revision + 1
    Write-Utf8 (Join-Path $fixture 'manifests/affected-validation-registry.json') ((ConvertTo-MorphospaceCanonicalJson -Value $contractRegistry) + "`n")
    [void](Invoke-TestGit $fixture @('add', 'manifests/affected-validation-registry.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'affected validation registry contract'))
    $registryContractHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $registryContractPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $infrastructureHead -HeadRevision $registryContractHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($registryContractPlan.selection_mode -ceq 'affected' -and @($registryContractPlan.selected_checks.check_id) -ccontains 'workflow-contracts') 'Affected-validation registry change did not retain workflow-contract coverage.'
    foreach ($checkId in @('affected-selector-selftest','affected-topology-selftest','affected-reuse-selftest')) { Assert-True (@($registryContractPlan.selected_checks.check_id) -ccontains $checkId) "Affected-validation registry change did not retain '$checkId'." }
    Assert-True (@($registryContractPlan.selected_checks.check_id) -cnotcontains 'work-environment-deep' -and @($registryContractPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'Affected-validation registry change incorrectly selected historical Deep or became ambiguous.'

    $affectedSchemaPath = Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json'
    Write-Utf8 $affectedSchemaPath ((Get-Content -LiteralPath $affectedSchemaPath -Raw) + "`n")
    [void](Invoke-TestGit $fixture @('add', 'schemas/affected-validation-registry-v1.schema.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'affected validation schema contract'))
    $schemaContractHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $schemaContractPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $registryContractHead -HeadRevision $schemaContractHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($schemaContractPlan.selection_mode -ceq 'affected' -and @($schemaContractPlan.selected_checks.check_id) -ccontains 'workflow-contracts') 'Affected-validation schema change did not retain workflow-contract coverage.'
    foreach ($checkId in @('affected-selector-selftest','affected-topology-selftest','affected-reuse-selftest')) { Assert-True (@($schemaContractPlan.selected_checks.check_id) -ccontains $checkId) "Affected-validation schema change did not retain '$checkId'." }
    Assert-True (@($schemaContractPlan.selected_checks.check_id) -cnotcontains 'work-environment-deep' -and @($schemaContractPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'Affected-validation schema change incorrectly selected historical Deep or became ambiguous.'

    Write-Utf8 (Join-Path $fixture 'schemas/work-unit-event.schema.json') "{} `n"
    [void](Invoke-TestGit $fixture @('add', 'schemas/work-unit-event.schema.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'ordinary schema contract'))
    $ordinarySchemaHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $ordinarySchemaPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $schemaContractHead -HeadRevision $ordinarySchemaHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($ordinarySchemaPlan.selection_mode -ceq 'affected' -and @($ordinarySchemaPlan.selected_checks.check_id) -ccontains 'workflow-contracts' -and @($ordinarySchemaPlan.selected_checks.check_id) -ccontains 'public-boundary') 'Ordinary schema change did not retain bounded workflow-contract/public-boundary routing.'
    foreach ($checkId in @('affected-selector-selftest','affected-topology-selftest','affected-reuse-selftest','work-environment-deep')) { Assert-True (@($ordinarySchemaPlan.selected_checks.check_id) -cnotcontains $checkId) "Ordinary schema change incorrectly selected '$checkId'." }
    Assert-True (@($ordinarySchemaPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'Ordinary schema change became ambiguous.'

    Write-Utf8 (Join-Path $fixture 'manifests/public-action-policy.json') "{} `n"
    [void](Invoke-TestGit $fixture @('add', 'manifests/public-action-policy.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'ordinary manifest contract'))
    $ordinaryManifestHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $ordinaryManifestPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $ordinarySchemaHead -HeadRevision $ordinaryManifestHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier quick
    Assert-True ($ordinaryManifestPlan.selection_mode -ceq 'affected' -and @($ordinaryManifestPlan.selected_checks.check_id) -ccontains 'workflow-contracts' -and @($ordinaryManifestPlan.selected_checks.check_id) -ccontains 'public-boundary') 'Ordinary manifest change did not retain bounded workflow-contract/public-boundary routing.'
    foreach ($checkId in @('affected-selector-selftest','affected-topology-selftest','affected-reuse-selftest','work-environment-deep')) { Assert-True (@($ordinaryManifestPlan.selected_checks.check_id) -cnotcontains $checkId) "Ordinary manifest change incorrectly selected '$checkId'." }
    Assert-True (@($ordinaryManifestPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'Ordinary manifest change became ambiguous.'

    $archiveSchemaPath = Join-Path $fixture 'schemas/history-archive-root-v1.schema.json'
    Write-Utf8 $archiveSchemaPath ((Get-Content -LiteralPath $archiveSchemaPath -Raw) + "`n")
    [void](Invoke-TestGit $fixture @('add', 'schemas/history-archive-root-v1.schema.json'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'history archive root contract'))
    $archiveSchemaHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $archiveSchemaPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $ordinaryManifestHead -HeadRevision $archiveSchemaHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier standard
    foreach ($checkId in @('public-boundary','workflow-contracts','history-archive-checkpoint')) { Assert-True (@($archiveSchemaPlan.selected_checks.check_id) -ccontains $checkId) "History archive schema change did not retain bounded '$checkId' coverage." }
    foreach ($checkId in @('affected-selector-selftest','affected-topology-selftest','affected-reuse-selftest','work-environment-deep')) { Assert-True (@($archiveSchemaPlan.selected_checks.check_id) -cnotcontains $checkId) "History archive schema change incorrectly selected '$checkId'." }
    Assert-True (@($archiveSchemaPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'History archive schema change became ambiguous.'

    $archiveRouterPath = Join-Path $fixture 'scripts/Invoke-WorkUnitAutomation.ps1'
    Write-Utf8 $archiveRouterPath "# archive router contract`n"
    [void](Invoke-TestGit $fixture @('add', 'scripts/Invoke-WorkUnitAutomation.ps1'))
    [void](Invoke-TestGit $fixture @('commit', '-m', 'history archive router contract'))
    $archiveRouterHead = Invoke-TestGit $fixture @('rev-parse', 'HEAD')
    $archiveRouterPlan = Resolve-MorphospaceAffectedValidation -RepositoryRoot $fixture -BaseRevision $archiveSchemaHead -HeadRevision $archiveRouterHead -RegistryPath (Join-Path $fixture 'manifests/affected-validation-registry.json') -RequestedTier standard
    foreach ($checkId in @('public-boundary','workflow-contracts','history-archive-checkpoint','work-unit-automation')) { Assert-True (@($archiveRouterPlan.selected_checks.check_id) -ccontains $checkId) "History archive router change did not retain bounded '$checkId' coverage." }
    foreach ($checkId in @('affected-selector-selftest','affected-topology-selftest','affected-reuse-selftest','work-environment-deep')) { Assert-True (@($archiveRouterPlan.selected_checks.check_id) -cnotcontains $checkId) "History archive router change incorrectly selected '$checkId'." }
    Assert-True (@($archiveRouterPlan.reason_codes) -cnotcontains 'ambiguous-path-mapping') 'History archive router change became ambiguous.'

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

    $crossPlatform = Read-MorphospaceProtocolJson -Path (Join-Path $fixture 'manifests/affected-validation-registry.json')
    $crossPlatform.checks | Where-Object { $_.check_id -ceq 'work-unit-automation' } | ForEach-Object { $_.prerequisite_checks = @('documentation-links') }
    $crossPlatformFailed = $false
    try { [void](Test-MorphospaceAffectedValidationRegistry -Registry $crossPlatform -RepositoryRoot $fixture -SchemaPath (Join-Path $fixture 'schemas/affected-validation-registry-v1.schema.json')) } catch { $crossPlatformFailed = $_.Exception.Message -like '*cross-platform*' }
    Assert-True $crossPlatformFailed 'Registry accepted an unsatisfied cross-platform prerequisite.'

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

Write-Host 'Affected-validation selector and executor self-test passed.'
