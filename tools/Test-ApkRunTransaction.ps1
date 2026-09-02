[CmdletBinding(DefaultParameterSetName = 'Audit')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Audit')][string]$Path,
    [Parameter(Mandatory = $true, ParameterSetName = 'Audit')][string]$ReceiptRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'SelfTest')][switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$phaseOrder = @(
    'host-validation',
    'snapshot',
    'build',
    'inspect',
    'install',
    'launch',
    'app-ready',
    'wearer-acceptance'
)
$phaseProperty = [ordered]@{
    'host-validation' = 'host_validation'
    'snapshot' = 'snapshot'
    'build' = 'build'
    'inspect' = 'inspect'
    'install' = 'install'
    'launch' = 'launch'
    'app-ready' = 'app_ready'
    'wearer-acceptance' = 'wearer_acceptance'
    'cleanup' = 'cleanup'
}

function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "APK run transaction invalid: $Message" }
}

function Get-Sha256([string]$FilePath) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $FilePath).Hash.ToLowerInvariant()
}

function Read-Json([string]$FilePath) {
    return (Get-Content -Raw -LiteralPath $FilePath | ConvertFrom-Json -DateKind String)
}

function Test-JsonSchema([string]$FilePath, [string]$SchemaPath, [string]$Label) {
    try {
        $valid = Test-Json -Json (Get-Content -Raw -LiteralPath $FilePath) -SchemaFile $SchemaPath
    } catch {
        throw "APK run transaction invalid: $Label does not satisfy its schema. $($_.Exception.Message)"
    }
    Require $valid "$Label does not satisfy its schema."
}

function Assert-NoReparsePoint([string]$FilePath, [string]$Label) {
    Require (Test-Path -LiteralPath $FilePath) "$Label does not exist: $FilePath"
    $item = Get-Item -LiteralPath $FilePath -Force
    Require (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "$Label may not be a reparse point: $FilePath"
}

function Resolve-ArtifactPath([string]$ReceiptPath, [string]$ArtifactPath) {
    if ([IO.Path]::IsPathFullyQualified($ArtifactPath)) {
        return [IO.Path]::GetFullPath($ArtifactPath)
    }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ReceiptPath) $ArtifactPath))
}

function Test-ApkRunTransactionDocument {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ReceiptsPath
    )

    $manifest = [IO.Path]::GetFullPath($ManifestPath)
    $receiptRootPath = [IO.Path]::GetFullPath($ReceiptsPath)
    Require (Test-Path -LiteralPath $manifest -PathType Leaf) "manifest does not exist: $manifest"
    Require (Test-Path -LiteralPath $receiptRootPath -PathType Container) "receipt root does not exist: $receiptRootPath"
    Assert-NoReparsePoint $manifest 'Manifest'
    Assert-NoReparsePoint $receiptRootPath 'Receipt root'

    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    $transactionSchema = Join-Path $repositoryRoot 'schemas\apk-run-transaction-v1.schema.json'
    $receiptSchema = Join-Path $repositoryRoot 'schemas\apk-run-phase-receipt-v1.schema.json'
    Test-JsonSchema $manifest $transactionSchema 'Manifest'
    $document = Read-Json $manifest
    $manifestSha256 = Get-Sha256 $manifest

    $receiptLeaves = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($propertyName in @($phaseProperty.Values)) {
        $leaf = [string]$document.phase_receipts.$propertyName
        Require ([IO.Path]::GetFileName($leaf) -ceq $leaf) "receipt mapping for '$propertyName' must be a leaf file name."
        Require ($receiptLeaves.Add($leaf)) "receipt file names must be unique."
    }

    $observed = [Collections.Generic.List[object]]::new()
    foreach ($phase in @($phaseOrder + 'cleanup')) {
        $propertyName = [string]$phaseProperty[$phase]
        $leaf = [string]$document.phase_receipts.$propertyName
        $receiptPath = Join-Path $receiptRootPath $leaf
        if (-not (Test-Path -LiteralPath $receiptPath)) { continue }
        Require (Test-Path -LiteralPath $receiptPath -PathType Leaf) "phase receipt is not a file: $leaf"
        Assert-NoReparsePoint $receiptPath "Phase receipt '$phase'"
        Test-JsonSchema $receiptPath $receiptSchema "Phase receipt '$phase'"
        $receipt = Read-Json $receiptPath
        Require ([string]$receipt.transaction_id -ceq [string]$document.transaction_id) "phase '$phase' names a different transaction."
        Require ([string]$receipt.transaction_sha256 -ceq $manifestSha256) "phase '$phase' does not bind the current manifest bytes."
        Require ([string]$receipt.phase -ceq $phase) "receipt '$leaf' declares phase '$([string]$receipt.phase)' instead of '$phase'."

        $artifactIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($artifact in @($receipt.artifacts)) {
            $artifactId = [string]$artifact.artifact_id
            Require ($artifactIds.Add($artifactId)) "phase '$phase' repeats artifact '$artifactId'."
            $artifactPath = Resolve-ArtifactPath $receiptPath ([string]$artifact.path)
            Require (Test-Path -LiteralPath $artifactPath -PathType Leaf) "artifact '$artifactId' for phase '$phase' does not exist."
            Assert-NoReparsePoint $artifactPath "Artifact '$artifactId'"
            Require ((Get-Sha256 $artifactPath) -ceq [string]$artifact.sha256) "artifact '$artifactId' for phase '$phase' failed SHA-256 readback."
        }

        $observed.Add([pscustomobject][ordered]@{
            phase = $phase
            path = $receiptPath
            sha256 = Get-Sha256 $receiptPath
            document = $receipt
        }) | Out-Null
    }

    $ordered = @($observed | Sort-Object { [int]$_.document.attempt_ordinal })
    $receiptIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previous = $null
    $expectedPhaseIndex = 0
    $primaryResult = $null
    $cleanupReceipt = $null
    $cleanupObligation = $false

    for ($index = 0; $index -lt $ordered.Count; $index++) {
        $entry = $ordered[$index]
        $receipt = $entry.document
        $phase = [string]$entry.phase
        Require ([int]$receipt.attempt_ordinal -eq ($index + 1)) "attempt ordinals must be unique and contiguous from one."
        Require ($receiptIds.Add([string]$receipt.receipt_id)) "receipt IDs must be unique."

        if ($index -eq 0) {
            Require ($null -eq $receipt.predecessor) "the first receipt must have a null predecessor."
        } else {
            Require ($null -ne $receipt.predecessor) "phase '$phase' must bind its predecessor receipt."
            Require (
                [string]$receipt.predecessor.receipt_id -ceq [string]$previous.document.receipt_id -and
                [string]$receipt.predecessor.sha256 -ceq [string]$previous.sha256
            ) "phase '$phase' predecessor binding is stale or incorrect."
        }

        if ($phase -ceq 'cleanup') {
            Require ($null -eq $cleanupReceipt) 'cleanup may be recorded only once.'
            Require (($null -ne $primaryResult) -or ($expectedPhaseIndex -eq $phaseOrder.Count)) 'cleanup may follow only a non-passing phase or all passing regular phases.'
            Require $cleanupObligation 'cleanup cannot appear when no prior phase required it.'
            Require ([bool]$receipt.cleanup_required) 'cleanup receipt must bind a required cleanup.'
            if ([string]$receipt.result -ceq 'pass') {
                Require ([bool]$receipt.cleanup_complete) 'passing cleanup must report cleanup_complete=true.'
            } else {
                Require (-not [bool]$receipt.cleanup_complete) 'non-passing cleanup cannot report complete cleanup.'
            }
            $cleanupReceipt = $entry
        } else {
            Require ($null -eq $cleanupReceipt) "regular phase '$phase' cannot follow cleanup."
            Require ($null -eq $primaryResult) "regular phase '$phase' cannot follow a non-passing phase."
            Require ($expectedPhaseIndex -lt $phaseOrder.Count -and $phase -ceq $phaseOrder[$expectedPhaseIndex]) "phase '$phase' is out of order or crosses a missing phase."
            Require ($null -eq $receipt.cleanup_complete) "regular phase '$phase' must report cleanup_complete=null."
            if ($cleanupObligation) {
                Require ([bool]$receipt.cleanup_required) "phase '$phase' dropped an existing cleanup obligation."
            }
            if ($expectedPhaseIndex -ge [Array]::IndexOf($phaseOrder, 'install') -and [string]$receipt.result -ceq 'pass') {
                Require ([bool]$receipt.cleanup_required) "passing phase '$phase' occurs after device mutation begins and must require cleanup."
            }
            $cleanupObligation = $cleanupObligation -or [bool]$receipt.cleanup_required
            if ([string]$receipt.result -ceq 'pass') {
                $expectedPhaseIndex++
            } else {
                $primaryResult = [string]$receipt.result
            }
        }
        $previous = $entry
    }

    $terminal = $false
    $nextPhase = $null
    $result = 'pending'
    $cleanupRequired = $cleanupObligation
    $cleanupResult = $null
    if ($null -ne $cleanupReceipt) {
        $cleanupResult = [string]$cleanupReceipt.document.result
        $terminal = $true
        if ($cleanupResult -ceq 'pass') {
            $result = if ($null -ne $primaryResult) { $primaryResult } else { 'pass' }
        } else {
            $result = 'blocked'
        }
    } elseif ($null -ne $primaryResult) {
        $cleanupRequired = [bool]$ordered[-1].document.cleanup_required
        if ($cleanupRequired) {
            $nextPhase = 'cleanup'
            $result = $primaryResult
        } else {
            $terminal = $true
            $result = $primaryResult
        }
    } elseif ($expectedPhaseIndex -lt $phaseOrder.Count) {
        $nextPhase = $phaseOrder[$expectedPhaseIndex]
    } else {
        Require ($ordered.Count -gt 0 -and [bool]$ordered[-1].document.cleanup_required) 'a fully passing run must require final cleanup.'
        $cleanupRequired = $true
        $nextPhase = 'cleanup'
    }

    return [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.quest.apk_run_transaction_audit.v1'
        transaction_id = [string]$document.transaction_id
        transaction_sha256 = $manifestSha256
        status = if ($terminal) { 'terminal' } elseif ($nextPhase -ceq 'cleanup') { 'cleanup-required' } else { 'ready' }
        result = $result
        terminal = $terminal
        next_phase = $nextPhase
        cleanup_required = $cleanupRequired
        cleanup_result = $cleanupResult
        observed_receipts = @($ordered | ForEach-Object {
            [pscustomobject][ordered]@{
                attempt_ordinal = [int]$_.document.attempt_ordinal
                phase = [string]$_.phase
                result = [string]$_.document.result
                receipt_id = [string]$_.document.receipt_id
                sha256 = [string]$_.sha256
            }
        })
        does_not_authorize = @(
            'This audit does not execute, approve, or authorize any phase.'
            'Phase receipts remain evidence from their named owners; chain validity is not product, device, wearer, acceptance, publication, or cleanup authority.'
        )
    }
}

function Write-TestJson([string]$FilePath, [object]$Value) {
    [IO.File]::WriteAllText($FilePath, (($Value | ConvertTo-Json -Depth 32) + "`n"), [Text.UTF8Encoding]::new($false))
}

function New-TestScenario([string]$Root, [string]$Name) {
    $scenarioRoot = Join-Path $Root $Name
    [IO.Directory]::CreateDirectory($scenarioRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $scenarioRoot 'evidence.txt'), "bounded test evidence`n", [Text.UTF8Encoding]::new($false))
    $manifestPath = Join-Path $scenarioRoot 'transaction.json'
    $receiptNames = [ordered]@{
        host_validation = '01-host-validation.json'
        snapshot = '02-snapshot.json'
        build = '03-build.json'
        inspect = '04-inspect.json'
        install = '05-install.json'
        launch = '06-launch.json'
        app_ready = '07-app-ready.json'
        wearer_acceptance = '08-wearer-acceptance.json'
        cleanup = '09-cleanup.json'
    }
    Write-TestJson $manifestPath ([ordered]@{
        schema = 'rusty.morphospace.quest.apk_run_transaction.v1'
        transaction_id = "apk-run-$Name"
        created_at = '2026-09-03T00:00:00Z'
        run_identity = [ordered]@{
            source_kind = 'composition-lock'
            source_identity_sha256 = ('a' * 64)
            build_lane = 'candidate'
            package = 'org.example.test'
            activity = 'org.example.test.MainActivity'
        }
        phase_receipts = $receiptNames
        does_not_authorize = @('Test manifest only; no operation is authorized.')
    })
    return [pscustomobject]@{
        root = $scenarioRoot
        manifest = $manifestPath
        transaction_id = "apk-run-$Name"
        transaction_sha256 = Get-Sha256 $manifestPath
        receipt_names = $receiptNames
        evidence_sha256 = Get-Sha256 (Join-Path $scenarioRoot 'evidence.txt')
        ordinal = 0
        previous_id = $null
        previous_sha256 = $null
    }
}

function Add-TestReceipt {
    param(
        [Parameter(Mandatory = $true)][object]$Scenario,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'blocked')][string]$Result,
        [Parameter(Mandatory = $true)][bool]$CleanupRequired,
        [AllowNull()][object]$CleanupComplete = $null,
        [switch]$BadPredecessor
    )
    $Scenario.ordinal++
    $receiptId = "$($Scenario.transaction_id)-$($Scenario.ordinal)-$Phase"
    $predecessor = if ($Scenario.ordinal -eq 1) {
        $null
    } else {
        [ordered]@{
            receipt_id = [string]$Scenario.previous_id
            sha256 = if ($BadPredecessor) { '0' * 64 } else { [string]$Scenario.previous_sha256 }
        }
    }
    $propertyName = [string]$phaseProperty[$Phase]
    $receiptPath = Join-Path $Scenario.root ([string]$Scenario.receipt_names.$propertyName)
    Write-TestJson $receiptPath ([ordered]@{
        schema = 'rusty.morphospace.quest.apk_run_phase_receipt.v1'
        receipt_id = $receiptId
        transaction_id = [string]$Scenario.transaction_id
        transaction_sha256 = [string]$Scenario.transaction_sha256
        phase = $Phase
        attempt_ordinal = [int]$Scenario.ordinal
        completed_at = '2026-09-03T00:00:00Z'
        result = $Result
        predecessor = $predecessor
        cleanup_required = $CleanupRequired
        cleanup_complete = $CleanupComplete
        artifacts = @([ordered]@{
            artifact_id = "$Phase-evidence"
            kind = 'test-evidence'
            path = 'evidence.txt'
            sha256 = [string]$Scenario.evidence_sha256
        })
        summary = "Synthetic $Phase $Result receipt."
        does_not_prove = @('Synthetic self-test evidence proves no product or device behavior.')
    })
    $Scenario.previous_id = $receiptId
    $Scenario.previous_sha256 = Get-Sha256 $receiptPath
}

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "APK run transaction self-test failed: $Message" }
}

function Invoke-SelfTest {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ("apk-run-transaction-" + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    try {
        $empty = New-TestScenario $testRoot 'empty'
        $audit = Test-ApkRunTransactionDocument $empty.manifest $empty.root
        Assert-Test ($audit.status -ceq 'ready' -and $audit.next_phase -ceq 'host-validation') 'empty transaction did not select host-validation.'

        $resume = New-TestScenario $testRoot 'resume'
        Add-TestReceipt $resume 'host-validation' 'pass' $false
        Add-TestReceipt $resume 'snapshot' 'pass' $false
        $audit = Test-ApkRunTransactionDocument $resume.manifest $resume.root
        Assert-Test ($audit.status -ceq 'ready' -and $audit.next_phase -ceq 'build' -and $audit.observed_receipts.Count -eq 2) 'passing prefix did not resume at build.'

        $failed = New-TestScenario $testRoot 'failed-app-ready'
        foreach ($phase in @('host-validation', 'snapshot', 'build', 'inspect')) { Add-TestReceipt $failed $phase 'pass' $false }
        foreach ($phase in @('install', 'launch')) { Add-TestReceipt $failed $phase 'pass' $true }
        Add-TestReceipt $failed 'app-ready' 'fail' $true
        $audit = Test-ApkRunTransactionDocument $failed.manifest $failed.root
        Assert-Test ($audit.status -ceq 'cleanup-required' -and $audit.next_phase -ceq 'cleanup' -and $audit.result -ceq 'fail') 'post-install failure did not select cleanup.'
        Add-TestReceipt $failed 'cleanup' 'pass' $true $true
        $audit = Test-ApkRunTransactionDocument $failed.manifest $failed.root
        Assert-Test ($audit.terminal -and $audit.result -ceq 'fail' -and $audit.cleanup_result -ceq 'pass') 'cleanup did not preserve the primary failure.'

        $early = New-TestScenario $testRoot 'early-fail'
        Add-TestReceipt $early 'host-validation' 'pass' $false
        Add-TestReceipt $early 'snapshot' 'pass' $false
        Add-TestReceipt $early 'build' 'blocked' $false
        $audit = Test-ApkRunTransactionDocument $early.manifest $early.root
        Assert-Test ($audit.terminal -and $audit.result -ceq 'blocked' -and $null -eq $audit.next_phase) 'pre-install blocker should be terminal without cleanup.'

        $complete = New-TestScenario $testRoot 'complete'
        foreach ($phase in @('host-validation', 'snapshot', 'build', 'inspect')) { Add-TestReceipt $complete $phase 'pass' $false }
        foreach ($phase in @('install', 'launch', 'app-ready', 'wearer-acceptance')) { Add-TestReceipt $complete $phase 'pass' $true }
        $audit = Test-ApkRunTransactionDocument $complete.manifest $complete.root
        Assert-Test ($audit.status -ceq 'cleanup-required' -and $audit.next_phase -ceq 'cleanup') 'fully passing regular phases did not require cleanup.'
        Add-TestReceipt $complete 'cleanup' 'pass' $true $true
        $audit = Test-ApkRunTransactionDocument $complete.manifest $complete.root
        Assert-Test ($audit.terminal -and $audit.result -ceq 'pass') 'complete passing transaction was not terminal pass.'

        $tampered = New-TestScenario $testRoot 'tampered'
        Add-TestReceipt $tampered 'host-validation' 'pass' $false
        Add-TestReceipt $tampered 'snapshot' 'pass' $false -BadPredecessor
        $rejected = $false
        try { $null = Test-ApkRunTransactionDocument $tampered.manifest $tampered.root } catch { $rejected = $_.Exception.Message -match 'predecessor binding' }
        Assert-Test $rejected 'stale predecessor binding was not rejected.'

        $gap = New-TestScenario $testRoot 'gap'
        Add-TestReceipt $gap 'host-validation' 'pass' $false
        Add-TestReceipt $gap 'build' 'pass' $false
        $rejected = $false
        try { $null = Test-ApkRunTransactionDocument $gap.manifest $gap.root } catch { $rejected = $_.Exception.Message -match 'out of order|missing phase' }
        Assert-Test $rejected 'receipt after a missing phase was not rejected.'

        $manifestDrift = New-TestScenario $testRoot 'manifest-drift'
        Add-TestReceipt $manifestDrift 'host-validation' 'pass' $false
        $changedManifest = Read-Json $manifestDrift.manifest
        $changedManifest.run_identity.activity = 'org.example.test.OtherActivity'
        Write-TestJson $manifestDrift.manifest $changedManifest
        $rejected = $false
        try { $null = Test-ApkRunTransactionDocument $manifestDrift.manifest $manifestDrift.root } catch { $rejected = $_.Exception.Message -match 'current manifest bytes' }
        Assert-Test $rejected 'manifest drift after a receipt was not rejected.'

        $artifactDrift = New-TestScenario $testRoot 'artifact-drift'
        Add-TestReceipt $artifactDrift 'host-validation' 'pass' $false
        [IO.File]::WriteAllText((Join-Path $artifactDrift.root 'evidence.txt'), "changed evidence`n", [Text.UTF8Encoding]::new($false))
        $rejected = $false
        try { $null = Test-ApkRunTransactionDocument $artifactDrift.manifest $artifactDrift.root } catch { $rejected = $_.Exception.Message -match 'SHA-256 readback' }
        Assert-Test $rejected 'artifact drift after a receipt was not rejected.'

        $cleanupDrop = New-TestScenario $testRoot 'cleanup-drop'
        Add-TestReceipt $cleanupDrop 'host-validation' 'pass' $true
        Add-TestReceipt $cleanupDrop 'snapshot' 'pass' $false
        $rejected = $false
        try { $null = Test-ApkRunTransactionDocument $cleanupDrop.manifest $cleanupDrop.root } catch { $rejected = $_.Exception.Message -match 'dropped an existing cleanup obligation' }
        Assert-Test $rejected 'a later phase dropped an existing cleanup obligation.'

        Write-Output 'APK run transaction self-test: PASS'
    } finally {
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $resolvedTest = [IO.Path]::GetFullPath($testRoot)
        if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTest)) {
            Remove-Item -LiteralPath $resolvedTest -Recurse -Force
        }
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$result = Test-ApkRunTransactionDocument -ManifestPath $Path -ReceiptsPath $ReceiptRoot
$result | ConvertTo-Json -Depth 16
