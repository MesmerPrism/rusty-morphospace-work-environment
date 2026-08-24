param(
    [string]$ConfigPath = "",
    [ValidateSet("Core", "Quest", "Full")][string]$Profile = "Core",
    [switch]$Strict,
    [switch]$SelfTest,
    [ValidateSet("Quick", "Standard", "Deep")][string]$Tier = "Quick",
    [switch]$CheckQuestDevice
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$results = New-Object System.Collections.Generic.List[object]

function Add-CheckResult {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail,
        [bool]$Required = $false
    )

    $results.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Required = $Required
        Detail = $Detail
    })
}

function Test-CommandAvailable {
    param(
        [string]$Name,
        [bool]$Required = $false
    )

    $cmd = @(Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($cmd) {
        Add-CheckResult -Name $Name -Status "ok" -Required $Required -Detail $cmd[0].Source
    } else {
        $status = if ($Required) { "missing" } else { "optional-missing" }
        Add-CheckResult -Name $Name -Status $status -Required $Required -Detail "Command not found on PATH."
    }
}

function Test-CommandVersion {
    param(
        [string]$Name,
        [string]$Command,
        [string[]]$Arguments,
        [version]$Minimum,
        [bool]$Required = $false
    )

    $cmd = @(Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $cmd) {
        $status = if ($Required) { "missing" } else { "optional-missing" }
        Add-CheckResult -Name $Name -Status $status -Required $Required -Detail "$Command was not found on PATH."
        return
    }

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        if ([System.IO.Path]::GetExtension($cmd[0].Source) -in @(".cmd", ".bat")) {
            $startInfo.FileName = $env:ComSpec
            $startInfo.Arguments = "/d /c `"$($cmd[0].Source)`" $($Arguments -join ' ')"
        } else {
            $startInfo.FileName = $cmd[0].Source
            $startInfo.Arguments = ($Arguments -join " ")
        }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $output = (($process.StandardOutput.ReadToEnd() + " " + $process.StandardError.ReadToEnd()).Trim())
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "$Command version probe exited $($process.ExitCode): $output"
        }
        $match = [regex]::Match($output, "(?<![0-9])([0-9]+)\.([0-9]+)(?:\.([0-9]+))?")
        if (-not $match.Success) {
            throw "Could not parse a version from: $output"
        }
        $patch = if ($match.Groups[3].Success) { $match.Groups[3].Value } else { "0" }
        $actual = [version]("{0}.{1}.{2}" -f $match.Groups[1].Value, $match.Groups[2].Value, $patch)
        if ($actual -lt $Minimum) {
            Add-CheckResult -Name $Name -Status "version-too-old" -Required $Required -Detail "Found $actual; require $Minimum or newer."
        } else {
            Add-CheckResult -Name $Name -Status "ok" -Required $Required -Detail "Found $actual; require $Minimum or newer."
        }
    } catch {
        $status = if ($Required) { "missing" } else { "optional-missing" }
        Add-CheckResult -Name $Name -Status $status -Required $Required -Detail $_.Exception.Message
    }
}

function Test-PlaceholderValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return $true
    }

    $text = [string]$Value
    return ($text.Trim().Length -eq 0 -or $text.Trim().StartsWith("<"))
}

function Test-ConfiguredPath {
    param(
        [string]$Name,
        [object]$Value,
        [bool]$Required = $false
    )

    if (Test-PlaceholderValue $Value) {
        Add-CheckResult -Name $Name -Status "placeholder" -Required $Required -Detail "No local path configured."
        return
    }

    $path = [string]$Value
    if (Test-Path -LiteralPath $path) {
        Add-CheckResult -Name $Name -Status "ok" -Required $Required -Detail $path
    } else {
        $status = if ($Required) { "missing" } else { "optional-missing" }
        Add-CheckResult -Name $Name -Status $status -Required $Required -Detail $path
    }
}

function Invoke-JsonParseCheck {
    param([string]$Path)

    try {
        Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json | Out-Null
        Add-CheckResult -Name "json:$Path" -Status "ok" -Detail "Parsed JSON."
    } catch {
        Add-CheckResult -Name "json:$Path" -Status "missing" -Required $true -Detail $_.Exception.Message
    }
}

function Invoke-JsonLinesParseCheck {
    param([string]$Path)

    try {
        $lineNumber = 0
        foreach ($line in @(Get-Content -LiteralPath $Path)) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $line | ConvertFrom-Json | Out-Null
        }
        Add-CheckResult -Name "jsonl:$Path" -Status "ok" -Detail "Parsed JSON Lines."
    } catch {
        Add-CheckResult -Name "jsonl:$Path" -Status "missing" -Required $true -Detail "Line $lineNumber`: $($_.Exception.Message)"
    }
}

& (Join-Path $PSScriptRoot "Test-PowerShellHost.ps1") -Quiet

if ($SelfTest) {
    $singleFailureProbe = @([pscustomobject]@{ Name = "probe"; Status = "missing"; Required = $true })
    $singleFailureCount = @($singleFailureProbe | Where-Object { $_.Required -and $_.Status -eq "missing" }).Count
    if ($singleFailureCount -eq 1) {
        Add-CheckResult -Name "aggregate:single-failure" -Status "ok" -Required $true -Detail "A scalar required failure remains countable."
    } else {
        Add-CheckResult -Name "aggregate:single-failure" -Status "missing" -Required $true -Detail "Expected one aggregate failure, found $singleFailureCount."
    }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "manifests") -Filter "*.json" -File |
        ForEach-Object { Invoke-JsonParseCheck -Path $_.FullName }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "templates") -Filter "*.json" -File |
        ForEach-Object { Invoke-JsonParseCheck -Path $_.FullName }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "schemas") -Filter "*.json" -File |
        ForEach-Object { Invoke-JsonParseCheck -Path $_.FullName }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "templates") -Filter "*.jsonl" -File |
        ForEach-Object { Invoke-JsonLinesParseCheck -Path $_.FullName }

    try {
        & (Join-Path $PSScriptRoot "Test-PowerShellHost.ps1") -SelfTest -Quiet
        Add-CheckResult -Name "powershell:host-policy" -Status "ok" -Required $true -Detail "Validated the PowerShell 7.6 Core host contract and rejected legacy command hosts."
    } catch {
        Add-CheckResult -Name "powershell:host-policy" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "scripts") -Filter "*.ps1" -File |
        ForEach-Object {
            try {
                [scriptblock]::Create((Get-Content -Raw -LiteralPath $_.FullName)) | Out-Null
                Add-CheckResult -Name "powershell:$($_.Name)" -Status "ok" -Detail "Parsed script."
            } catch {
                Add-CheckResult -Name "powershell:$($_.Name)" -Status "missing" -Required $true -Detail $_.Exception.Message
            }
        }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "scripts\lib") -Filter "*.psm1" -File |
        ForEach-Object {
            try {
                [scriptblock]::Create((Get-Content -Raw -LiteralPath $_.FullName)) | Out-Null
                Add-CheckResult -Name "powershell-module:$($_.Name)" -Status "ok" -Detail "Parsed module."
            } catch {
                Add-CheckResult -Name "powershell-module:$($_.Name)" -Status "missing" -Required $true -Detail $_.Exception.Message
            }
        }

    try {
        & (Join-Path $RepoRoot "scripts\Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot -SkipOwnerSelfTests
        & (Join-Path $RepoRoot "scripts\Test-HistoricalUnitAdoption.ps1") -SelfTest
        Add-CheckResult -Name "workflow:contracts" -Status "ok" -Detail "Validated lifecycle, schemas, and examples."
    } catch {
        Add-CheckResult -Name "workflow:contracts" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\Test-ExecutedPushReceipt.ps1") -SelfTest
        Add-CheckResult -Name "workflow:executed-push-receipt" -Status "ok" -Detail "Validated exact readback, ordering, ancestry, validation, force-push, and rollback invariants."
    } catch {
        Add-CheckResult -Name "workflow:executed-push-receipt" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\Test-PlannedPublicationAccounting.ps1") -SelfTest
        Add-CheckResult -Name "workflow:planned-publication-accounting" -Status "ok" -Detail "Validated commit/unit accounting, carried-unit non-acceptance, chronology, planning suffix, no-force, and readback invariants."
    } catch {
        Add-CheckResult -Name "workflow:planned-publication-accounting" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\Test-UnplannedPublicationClosure.ps1") -SelfTest
        Add-CheckResult -Name "workflow:unplanned-publication-closure" -Status "ok" -Detail "Validated truthful recovery for an already-published source without a retrospective push plan."
    } catch {
        Add-CheckResult -Name "workflow:unplanned-publication-closure" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\Test-PublishedPlanningAuthorityAdoption.ps1") -SelfTest
        Add-CheckResult -Name "workflow:published-planning-authority-adoption" -Status "ok" -Detail "Validated exact stale embedded-state adoption into the external planning authority and damaged-case rejection."
    } catch {
        Add-CheckResult -Name "workflow:published-planning-authority-adoption" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\Test-PublishedPrerequisiteSuffixReconciliation.ps1") -SelfTest
        Add-CheckResult -Name "workflow:published-prerequisite-suffix" -Status "ok" -Detail "Validated bounded one- and two-commit planning suffix reconciliation and damaged-case rejection."
    } catch {
        Add-CheckResult -Name "workflow:published-prerequisite-suffix" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\Test-ExecutedPreparedPublicationReconciliation.ps1") -SelfTest
        Add-CheckResult -Name "workflow:executed-prepared-publication-reconciliation" -Status "ok" -Detail "Validated immutable chronology classification, exact linear and merge-parent history, path-set fingerprints, live refs, and one-bundle consumption."
    } catch {
        Add-CheckResult -Name "workflow:executed-prepared-publication-reconciliation" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\Test-PreparedPushTransactionSuffixReconciliation.ps1") -SelfTest
        Add-CheckResult -Name "workflow:prepared-push-transaction-suffix-reconciliation" -Status "ok" -Detail "Validated signed exact-bundle authority, the normal linear owner shape, one planning receipt suffix, exactly five dirty PreparePush paths, and one-bundle consumption."
    } catch {
        Add-CheckResult -Name "workflow:prepared-push-transaction-suffix-reconciliation" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\Test-ReleaseCapsule.ps1") -SelfTest
        Add-CheckResult -Name "workflow:release-capsule" -Status "ok" -Detail "Validated immutable candidate cuts, historical descendant closure, isolated trees, preserved dirty overlays, and damaged evidence rejection."
    } catch {
        Add-CheckResult -Name "workflow:release-capsule" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\Test-FeatureLockResolver.ps1")
        Add-CheckResult -Name "workflow:feature-lock-v2" -Status "ok" -Detail "Validated descriptor closure, hashes, effect union, activation, and damaged-lock rejection."
    } catch {
        Add-CheckResult -Name "workflow:feature-lock-v2" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\New-ProjectWorkspace.ps1") -SelfTest
        Add-CheckResult -Name "scaffold:project-workspace" -Status "ok" -Detail "Created, validated, and protected a temporary scaffold."
    } catch {
        Add-CheckResult -Name "scaffold:project-workspace" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    foreach ($quickTest in @(
        [pscustomobject]@{ name = "workflow:public-boundary"; script = "Test-PublicBoundary.ps1"; detail = "Validated the portable public/private boundary." },
        [pscustomobject]@{ name = "workflow:documentation-links"; script = "Test-DocumentationLinks.ps1"; detail = "Validated relative Markdown links." },
        [pscustomobject]@{ name = "workflow:skill-templates"; script = "Test-SkillTemplates.ps1"; detail = "Validated the four local skill routers, external Meta ownership boundary, and locator contract." },
        [pscustomobject]@{ name = "workflow:external-validation-authority"; script = "Test-ExternalValidationAuthoritySelfTest.ps1"; detail = "Validated base-owned exact change-set admission without candidate checkout or execution." },
        [pscustomobject]@{ name = "workflow:external-owner-authorization"; script = "Test-ExternalOwnerAuthorization.ps1"; arguments = @("-SelfTest"); detail = "Validated canonical RSA-PSS external-owner authorization with ephemeral keys, exact-evidence idempotence, and negative identity, duplicate, time, changed-evidence, signature, key, and strict-policy cases." },
        [pscustomobject]@{ name = "workflow:external-validation-github-adapter"; script = "Test-ExternalValidationAuthorityGitHubAdapterSelfTest.ps1"; detail = "Validated exact PR object identities, ordered merge parents, pinned base verifier bytes, and no candidate checkout or execution." },
        [pscustomobject]@{ name = "workflow:environment-validation"; script = "Test-EnvironmentValidation.ps1"; detail = "Validated strict placeholders, repo paths, and Python/JDK minimum versions." },
        [pscustomobject]@{ name = "workflow:local-skill-bootstrap"; script = "Test-LocalSkillBootstrap.ps1"; detail = "Validated plan, install, verify, drift, backup, update, and local-file preservation." },
        [pscustomobject]@{ name = "workflow:quest-file-manager-provider"; script = "Test-QuestFileManagerCliResolver.ps1"; detail = "Validated exact provider resolution, immutable deployment inputs, typed vectors, mismatch rejection, and failure evidence retention." },
        [pscustomobject]@{ name = "workflow:quest-file-manager-runtime-adapters"; script = "Test-QuestFileManagerRuntimeObservationAdapter.ps1"; detail = "Validated legacy/current QFM runtime fact adapters, explicit unknown outcomes, and FocusPlaceholder readiness non-inference." },
        [pscustomobject]@{ name = "workflow:project-isolation"; script = "Test-ProjectIsolation.ps1"; detail = "Validated exact source locks, detached materializations, no-overwrite content addresses, and conflicting resource claims." },
        [pscustomobject]@{ name = "workflow:repository-lifecycle-advisory"; script = "Test-RepositoryLifecycleInventory.ps1"; arguments = @("-SelfTest"); detail = "Validated strict ref/worktree consumer evidence, candidate/hold/incomplete dispositions, exact-tip drift, deterministic output, and no Git mutation." },
        [pscustomobject]@{ name = "workflow:canonical-text-bytes"; script = "Test-CanonicalTextBytes.ps1"; arguments = @("-SelfTest"); detail = "Validated explicit LF enrollment, byte-exact legacy and binary paths, evidence preflight, and core.autocrlf true/false parity." },
        [pscustomobject]@{ name = "workflow:unpublished-planning-authority-materialization"; script = "Test-UnpublishedPlanningAuthorityMaterialization.ps1"; detail = "Validated one-time exact dirty-source workspace materialization into a distinct clean planning authority, preservation, atomic no-overwrite installation, receipt binding, and damaged-case rejection." },
        [pscustomobject]@{ name = "workflow:work-unit-handoff"; script = "Test-WorkUnitHandoff.ps1"; detail = "Validated exact unit/state/event/repository bindings and verbatim validation and acceptance commands." },
        [pscustomobject]@{ name = "workflow:completed-transition-semantic-correction"; script = "Test-CompletedTransitionSemanticCorrection.ps1"; detail = "Validated derived legacy-v1 supersession correction, historical-byte preservation, authenticated projection, interruption repair, replay, path, CAS, and damaged-evidence rejection." },
        [pscustomobject]@{ name = "workflow:historical-blocker-resolution-intent-binding-correction"; script = "Test-HistoricalBlockerResolutionIntentBindingCorrection.ps1"; detail = "Validated exact cross-unit current authority, terminal CRLF-to-LF hash recovery, historical-byte preservation, transactional projection, replay integration, and damaged-evidence rejection." },
        [pscustomobject]@{ name = "workflow:blocked-supersession-terminal-validation"; script = "Test-BlockedSupersessionTerminalValidation.ps1"; detail = "Validated exact owner-authenticated blocked supersession failure history, strict v1/v2 preservation, owner-produced v3 one/two-projection and chained continuations, and fail-closed adversarial rejection." },
        [pscustomobject]@{ name = "workflow:historical-unit-compatibility-projection"; script = "Test-HistoricalUnitCompatibilityProjection.ps1"; arguments = @("-SelfTest"); detail = "Validated the atomic dual-target historical compatibility projection, exact owner Ready/WithdrawReady and v2 supersession provenance, immutable historical bytes, and fail-closed damage/recovery behavior." },
        [pscustomobject]@{ name = "workflow:historical-validation-debt-baseline"; script = "Test-HistoricalValidationDebtBaseline.ps1"; arguments = @("-SelfTest"); detail = "Validated cold aggregate capture, immutable signed historical-debt baseline ratcheting, explicit debt-bearing current success, receipt binding, and damaged-set rejection." },
        [pscustomobject]@{ name = "workflow:active-read-only-dependency-correction"; script = "Test-CorrectActiveReadOnlyDependencies.ps1"; detail = "Validated exact active/current CAS, bounded dependency changes, project paths, Git commit/tree identities, transaction ownership, and no Git/device/remote mutation." },
        [pscustomobject]@{ name = "workflow:active-project-repository-scope-correction"; script = "Test-CorrectActiveProjectRepositoryScope.ps1"; detail = "Validated exact active/current CAS, additive unit-bounded project scope, atomic project/lock/state projections, recovery, and no Git/device/remote mutation." },
        [pscustomobject]@{ name = "workflow:active-unit-contract-correction"; script = "Test-CorrectActiveUnitContract.ps1"; arguments = @("-SelfTest"); detail = "Validated the exact Unit058 legacy architecture and absent-skill failure shape, raw/canonical active-unit CAS, fixed planned surfaces, atomic receipt/event projection, and no Git/device/remote mutation." },
        [pscustomobject]@{ name = "workflow:active-write-scope-amendment"; script = "Test-ActiveWriteScopeAmendment.ps1"; detail = "Validated additive project-bounded active feature-unit write-scope amendments, exact CAS, transaction ownership, and no Git/device/remote mutation." }
    )) {
        try {
            $quickTestPath = Join-Path (Join-Path $RepoRoot "scripts") $quickTest.script
            [string[]]$quickTestArguments = if ($null -ne $quickTest.PSObject.Properties["arguments"]) {
                @($quickTest.arguments | ForEach-Object { [string]$_ })
            } else { @() }
            if ($quickTest.name -eq "workflow:public-boundary") {
                if ($quickTestArguments.Count -ne 0) {
                    throw "Public-boundary Quick test declares unsupported additional arguments."
                }
                & $quickTestPath -Root $RepoRoot
            } elseif ($quickTestArguments.Count -eq 0) {
                & $quickTestPath
            } elseif ($quickTestArguments.Count -eq 1 -and $quickTestArguments[0] -ceq "-SelfTest") {
                & $quickTestPath -SelfTest
            } else {
                throw "Quick test '$($quickTest.name)' declares unsupported arguments."
            }
            Add-CheckResult -Name $quickTest.name -Status "ok" -Detail $quickTest.detail
        } catch {
            Add-CheckResult -Name $quickTest.name -Status "missing" -Required $true -Detail $_.Exception.Message
        }
    }

    if ($Tier -in @("Standard", "Deep")) {
        try {
            & (Join-Path $RepoRoot "scripts\Test-WorkUnitAutomation.ps1")
            Add-CheckResult -Name "automation:work-unit" -Status "ok" -Detail "Validated transitions, preservation, routing, push preparation, and recovery."
        } catch {
            Add-CheckResult -Name "automation:work-unit" -Status "missing" -Required $true -Detail $_.Exception.Message
        }
    }

    if ($Tier -eq "Deep") {
        foreach ($authorityTest in @(
            [pscustomobject]@{ name = 'authority:record-readiness'; script = 'Test-AuthorityRecordReadiness.ps1'; detail = 'Validated host probe, capsule identity, content-addressed clean-room reuse, typed v2 validator admission, stale-preflight rejection, typed failures, and ambient-hash rejection.' },
            [pscustomobject]@{ name = 'authority:runner-fast'; script = 'Test-ValidationAuthorityRunnerFast.ps1'; detail = 'Drove the real pinned admission-only Preflight and full Validate branches through a bounded fixture and validated the published receipt through the full consumer.' },
            [pscustomobject]@{ name = 'authority:launcher'; script = 'Test-ValidationAuthorityLauncher.ps1'; detail = 'Validated pinned child launch, timeout, no-overwrite outputs, and captured streams.' },
            [pscustomobject]@{ name = 'authority:handoff'; script = 'Test-AuthorityRunnerHandoff.ps1'; detail = 'Validated pinned runner selection, arguments, nonce, and child failure propagation.' },
            [pscustomobject]@{ name = 'authority:trust-migration'; script = 'Test-TrustMigrationAuthority.ps1'; detail = 'Validated tracked authority migration and substitution rejection.' },
            [pscustomobject]@{ name = 'authority:validation-execution'; script = 'Test-ValidationExecutionAuthority.ps1'; detail = 'Validated schema-pure late publication, strict ownership re-observation, nonce-bound execution, workspace/repository receipt normalization, exact receipt references, and forged receipt rejection.' },
            [pscustomobject]@{ name = 'authority:ownership'; script = 'Test-OwnershipAuthority.ps1'; detail = 'Validated ownership, clean-room closure, historical blobs, and damaged input rejection.' },
            [pscustomobject]@{ name = 'authority:transition-ledger'; script = 'Test-TransitionLedger.ps1'; detail = 'Validated interruption repair and idempotent transition completion.' }
        )) {
            try {
                & (Join-Path (Join-Path $RepoRoot 'scripts') ([string]$authorityTest.script))
                Add-CheckResult -Name ([string]$authorityTest.name) -Status 'ok' -Detail ([string]$authorityTest.detail)
            } catch {
                Add-CheckResult -Name ([string]$authorityTest.name) -Status 'missing' -Required $true -Detail $_.Exception.Message
            }
        }
    }
}

$questProfile = $Profile -in @("Quest", "Full")
$fullProfile = $Profile -eq "Full"

Test-CommandAvailable -Name "git" -Required $true
Test-CommandAvailable -Name "pwsh" -Required $true
Test-CommandAvailable -Name "rustup" -Required $true
Test-CommandAvailable -Name "cargo" -Required $true
Test-CommandAvailable -Name "python" -Required $true
Test-CommandAvailable -Name "rg" -Required $true
Test-CommandVersion -Name "python.version" -Command "python" -Arguments @("--version") -Minimum ([version]"3.11") -Required $true
Test-CommandVersion -Name "pwsh.version" -Command "pwsh" -Arguments @("--version") -Minimum ([version]"7.6") -Required $true

Test-CommandAvailable -Name "adb" -Required $questProfile
Test-CommandAvailable -Name "java" -Required $questProfile
Test-CommandAvailable -Name "javac" -Required $questProfile
Test-CommandVersion -Name "java.version" -Command "java" -Arguments @("-version") -Minimum ([version]"17.0") -Required $questProfile
Test-CommandAvailable -Name "node" -Required $fullProfile
Test-CommandAvailable -Name "npm" -Required $fullProfile
Test-CommandAvailable -Name "npx" -Required $fullProfile
Test-CommandAvailable -Name "dotnet" -Required $fullProfile

if ($ConfigPath) {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
            Add-CheckResult -Name "config" -Status "ok" -Required $true -Detail $ConfigPath

            Test-ConfiguredPath -Name "workspace_root" -Value $config.workspace_root -Required $Strict.IsPresent
            Test-ConfiguredPath -Name "repos_root" -Value $config.repos_root -Required $Strict.IsPresent
            Test-ConfiguredPath -Name "artifacts_root" -Value $config.artifacts_root -Required $false
            Test-ConfiguredPath -Name "skills_root" -Value $config.skills_root -Required $false
            Test-ConfiguredPath -Name "work_environment_root" -Value $config.work_environment_root -Required $Strict.IsPresent

            if ($config.repos) {
                foreach ($repoProperty in @($config.repos.PSObject.Properties)) {
                    Test-ConfiguredPath -Name ("repos." + $repoProperty.Name) -Value $repoProperty.Value -Required $Strict.IsPresent
                }
            }

            if ($config.android) {
                Test-ConfiguredPath -Name "android.sdk_root" -Value $config.android.sdk_root -Required ($Strict.IsPresent -and $questProfile)
                Test-ConfiguredPath -Name "android.ndk_root" -Value $config.android.ndk_root -Required ($Strict.IsPresent -and $questProfile)
                Test-ConfiguredPath -Name "android.jdk_root" -Value $config.android.jdk_root -Required ($Strict.IsPresent -and $questProfile)
                Test-ConfiguredPath -Name "android.openxr_loader_quest" -Value $config.android.openxr_loader_quest -Required $false
            }
        } catch {
            Add-CheckResult -Name "config" -Status "missing" -Required $true -Detail $_.Exception.Message
        }
    } else {
        Add-CheckResult -Name "config" -Status "missing" -Required $Strict.IsPresent -Detail $ConfigPath
    }
}

if ($CheckQuestDevice) {
    $adb = Get-Command adb -ErrorAction SilentlyContinue
    if ($adb) {
        try {
            $devices = & $adb.Source devices -l
            Add-CheckResult -Name "adb.devices" -Status "ok" -Detail ($devices -join " | ")
        } catch {
            Add-CheckResult -Name "adb.devices" -Status "optional-missing" -Detail $_.Exception.Message
        }
    } else {
        Add-CheckResult -Name "adb.devices" -Status "optional-missing" -Detail "adb not found."
    }
}

$results | Sort-Object Name | Format-Table -AutoSize

$failedRequired = @($results | Where-Object { $_.Required -and $_.Status -in @("missing", "placeholder", "version-too-old", "invalid") })
if ($Strict -and $failedRequired.Count -gt 0) {
    Write-Error "Required checks failed in strict mode."
    exit 1
}

if ($SelfTest) {
    $selfTestFailures = @($results | Where-Object { $_.Name -match "^(aggregate|json|jsonl|powershell|workflow|scaffold|automation|authority):" -and $_.Status -ne "ok" })
    if ($selfTestFailures.Count -gt 0) {
        Write-Host "Self-test failures:"
        foreach ($failure in $selfTestFailures) {
            Write-Host (" - {0} [{1}]: {2}" -f $failure.Name, $failure.Status, $failure.Detail)
        }
        Write-Error "Self-test failed."
        exit 1
    }
}

Write-Host "Environment check complete."
