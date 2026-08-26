param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'InheritedCandidateMaterialization.psm1') -Force

function Assert-InheritedCandidateTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Inherited-candidate materialization self-test failed: $Message" }
}

function Write-InheritedCandidateTestJson {
    param([string]$Path, [object]$Value)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 32 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-InheritedCandidateTestHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-InheritedCandidateTestArchive {
    param([string]$Path, [hashtable]$Files)
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in @($Files.Keys | Sort-Object)) {
            $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::NoCompression)
            $entry.ExternalAttributes = -2119958528 # 0100644 in the ZIP Unix external-attribute field.
            $stream = $entry.Open()
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$Files[$name])
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Invoke-InheritedCandidateTestGit {
    param([string]$Repository, [string[]]$Arguments)
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $output = @(& git -C $Repository @Arguments 2>&1); $exitCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($exitCode -ne 0) { throw "Inherited-candidate test git command failed: git -C $Repository $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)" }
    return @($output)
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-inherited-candidate-' + [guid]::NewGuid().ToString('N'))
try {
    $projectRoot = Join-Path $testRoot 'project'
    & (Join-Path $PSScriptRoot 'New-ProjectWorkspace.ps1') -ProjectRoot $projectRoot -ProjectId 'inherited-candidate-test' -Purpose 'Synthetic inherited-candidate materialization fixture.' -Execute | Out-Null
    $workspace = Join-Path $projectRoot 'morphospace'
    $unitId = 'unit-inherited-001'; $bindingId = 'ic-test-001'
    $evidenceRoot = Join-Path $workspace "inherited-candidates\$bindingId"
    [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
    $archivePath = Join-Path $evidenceRoot 'candidate.zip'
    $files = [ordered]@{ 'docs/note.txt' = "portable candidate note`n"; 'src/lib.rs' = "pub fn inherited() {}\n" }
    New-InheritedCandidateTestArchive -Path $archivePath -Files $files
    $patchPath = Join-Path $evidenceRoot 'candidate.patch'
    [IO.File]::WriteAllText($patchPath, "diff --git a/src/lib.rs b/src/lib.rs`n", [Text.UTF8Encoding]::new($false))
    $inventoryPath = Join-Path $evidenceRoot 'inventory.json'
    $inventoryRows = New-Object System.Collections.Generic.List[object]
    $ordinal = 0
    foreach ($name in @($files.Keys | Sort-Object)) {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$files[$name])
        $inventoryRows.Add([ordered]@{ ordinal = $ordinal; path = $name; sha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant(); length = [int64]$bytes.Length; file_mode = '100644' }) | Out-Null
        $ordinal++
    }
    Write-InheritedCandidateTestJson -Path $inventoryPath -Value ([ordered]@{ schema = 'rusty.morphospace.workflow.inherited_candidate_file_inventory.v1'; binding_id = $bindingId; files = @($inventoryRows.ToArray()) })
    $relative = @{ archive = "inherited-candidates/$bindingId/candidate.zip"; patch = "inherited-candidates/$bindingId/candidate.patch"; file_inventory = "inherited-candidates/$bindingId/inventory.json"; manifest = "inherited-candidates/$bindingId/manifest.json"; binding = "inherited-candidates/$bindingId/binding.json" }
    $reference = @{}
    $evidencePaths = @{ archive = $archivePath; patch = $patchPath; file_inventory = $inventoryPath }
    foreach ($name in @('archive', 'patch', 'file_inventory')) {
        $path = [string]$evidencePaths[$name]
        $reference[$name] = [ordered]@{ path = $relative[$name]; sha256 = Get-InheritedCandidateTestHash $path; length = [int64](Get-Item -LiteralPath $path).Length }
    }
    $source = [ordered]@{ base = [ordered]@{ commit = ('a' * 40); tree = ('b' * 40) }; head = [ordered]@{ commit = ('c' * 40); tree = ('d' * 40) }; cleanliness = 'clean' }
    $nonClaims = @('Does not make inherited bytes live product inputs.', 'Does not authorize validation.', 'Does not authorize acceptance.')
    $manifestPath = Join-Path $evidenceRoot 'manifest.json'
    Write-InheritedCandidateTestJson -Path $manifestPath -Value ([ordered]@{ schema = 'rusty.morphospace.workflow.inherited_candidate_manifest.v1'; binding_id = $bindingId; project_id = 'inherited-candidate-test'; unit_id = $unitId; source = $source; archive = $reference.archive; patch = $reference.patch; file_inventory = $reference.file_inventory; does_not_prove = $nonClaims })
    $reference.manifest = [ordered]@{ path = $relative.manifest; sha256 = Get-InheritedCandidateTestHash $manifestPath; length = [int64](Get-Item -LiteralPath $manifestPath).Length }
    $bindingPath = Join-Path $evidenceRoot 'binding.json'
    Write-InheritedCandidateTestJson -Path $bindingPath -Value ([ordered]@{ schema = 'rusty.morphospace.workflow.inherited_candidate_evidence_binding.v1'; binding_id = $bindingId; project_id = 'inherited-candidate-test'; unit_id = $unitId; manifest = $reference.manifest; archive = $reference.archive; patch = $reference.patch; file_inventory = $reference.file_inventory; source = $source; materialization = [ordered]@{ destination_leaf = $bindingId; archive_applied = $true; raw_patch_applied = $false; product_inputs_used = $false }; does_not_prove = $nonClaims })

    $unit = [ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_unit.v1'; unit_id = $unitId; project_id = 'inherited-candidate-test'; status = 'ready'; objective = 'Validate isolated inherited candidate evidence.'; change_categories = @('implementation'); instruction_impact = 'none'; instruction_surfaces = @(); instruction_none_justification = 'Synthetic fixture.'; prerequisites = @(); allowed_repositories = @([ordered]@{ repo_id = 'project-shell'; allowed_paths = @('src/') }); non_scope = @('Real product source.'); acceptance = @([ordered]@{ acceptance_id = 'self-test'; proof = 'Synthetic test.'; command = 'Test-InheritedCandidateMaterialization.ps1' }); risk_tier = 'standard'; device_requirement = 'none'; validation = @([ordered]@{ profile_id = 'synthetic'; command = 'none' }); outputs = @('marker'); commit_policy = 'none'; push_checkpoint = 'none'; inherited_candidate = [ordered]@{ binding_path = $relative.binding; binding_sha256 = Get-InheritedCandidateTestHash $bindingPath }
    }
    $unitPath = Join-Path $workspace "iteration-units\$unitId.json"
    Write-InheritedCandidateTestJson -Path $unitPath -Value $unit
    Assert-InheritedCandidateTest (Test-Json -Json (Get-Content -LiteralPath $unitPath -Raw) -SchemaFile (Join-Path $repoRoot 'schemas\iteration-unit.schema.json')) 'initial inherited-candidate unit did not satisfy the strict iteration-unit schema'
    [IO.Directory]::CreateDirectory((Join-Path $projectRoot 'src')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectRoot 'src\fixture.rs'), "pub fn fixture() {}\n", [Text.UTF8Encoding]::new($false))
    Invoke-InheritedCandidateTestGit -Repository $projectRoot -Arguments @('init', '--initial-branch=main') | Out-Null
    Invoke-InheritedCandidateTestGit -Repository $projectRoot -Arguments @('config', 'user.email', 'inherited-candidate-test@example.invalid') | Out-Null
    Invoke-InheritedCandidateTestGit -Repository $projectRoot -Arguments @('config', 'user.name', 'Inherited Candidate Test') | Out-Null
    Invoke-InheritedCandidateTestGit -Repository $projectRoot -Arguments @('add', '--all') | Out-Null
    Invoke-InheritedCandidateTestGit -Repository $projectRoot -Arguments @('commit', '--quiet', '--message', 'Synthetic clean Claim fixture') | Out-Null
    $statePath = Join-Path $workspace 'workspace.state.json'; $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.current_unit = $null; $state.next_ready_unit = $unitId
    Write-InheritedCandidateTestJson -Path $statePath -Value $state
    $materializationRoot = Join-Path $testRoot 'task-local-reference'; [IO.Directory]::CreateDirectory($materializationRoot) | Out-Null
    $repoMapPath = Join-Path $testRoot 'repository-map.json'
    Write-InheritedCandidateTestJson -Path $repoMapPath -Value ([ordered]@{ schema = 'rusty.morphospace.workflow.repository_map.v1'; repositories = @([ordered]@{ repo_id = 'project-shell'; path = $projectRoot; role = 'source' }) })
    $markerPath = Join-Path $workspace "receipts\$bindingId-materialized.json"
    $claim = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action Claim -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $repoMapPath -Timestamp '2030-01-02T03:04:05.0000000Z' -Execute | ConvertFrom-Json
    $claimEvent = @(Get-Content -LiteralPath (Join-Path $workspace 'iteration-events.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })[-1]
    Assert-InheritedCandidateTest ($claim.transition -eq 'ready-to-active' -and $claimEvent.event_id -match "^$unitId-claimed-[0-9]{4}$" -and @($claimEvent.receipts | Where-Object { $_ -ceq $relative.binding }).Count -eq 1) 'public Claim did not bind the exact inherited evidence declaration'
    $preMaterializationBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $repoMapPath -Timestamp '2030-01-02T03:04:05.5000000Z' -Execute | Out-Null } catch { $preMaterializationBlocked = $_.Exception.Message -like 'Inherited-candidate evidence requires exact post-Claim materialization before source work.' }
    Assert-InheritedCandidateTest $preMaterializationBlocked 'public source-work transition bypassed post-Claim materialization'

    # Each interruption starts from the exact same post-Claim workspace. The production
    # materializer must leave external bytes coupled to the authenticated progress record
    # until the transition ledger owns the marker, state, unit, and event projections.
    Import-Module (Join-Path $PSScriptRoot 'InheritedCandidateMaterialization.psm1') -Force
    $claimedSnapshot = Join-Path $testRoot 'claimed-workspace-snapshot'
    Copy-Item -LiteralPath $workspace -Destination $claimedSnapshot -Recurse
    foreach ($fault in @('after-staged-extraction', 'after-destination-install', 'after-marker-install', 'after-ledger-commit')) {
        $scenarioWorkspace = Join-Path $testRoot ("fault-" + $fault)
        Copy-Item -LiteralPath $claimedSnapshot -Destination $scenarioWorkspace -Recurse
        $scenarioRoot = Join-Path $testRoot ("task-local-" + $fault)
        [IO.Directory]::CreateDirectory($scenarioRoot) | Out-Null
        $scenarioMarker = Join-Path $scenarioWorkspace "receipts\$bindingId-materialized.json"
        $scenarioProgress = Join-Path $scenarioWorkspace "receipts\$bindingId-materialized-progress.json"
        $scenarioStage = Join-Path $scenarioRoot ('.' + $bindingId + '.materializing')
        $scenarioDestination = Join-Path $scenarioRoot $bindingId
        $scenarioIntent = Join-Path $scenarioWorkspace "receipts\transactions\$bindingId-materialized-recorded-transition.intent.json"
        $scenarioCompletion = Join-Path $scenarioWorkspace "receipts\transactions\$bindingId-materialized-recorded-transition.completion.json"
        $interrupted = $false
        $interruptionMessage = ''
        try {
            Invoke-MorphospaceMaterializeInheritedCandidate -WorkspaceRoot $scenarioWorkspace -UnitId $unitId -RepoMapPath $repoMapPath -MaterializationRoot $scenarioRoot -OutPath $scenarioMarker -Timestamp '2030-01-02T03:04:06.0000000Z' -FaultAfter $fault -Execute | Out-Null
        } catch { $interruptionMessage = $_.Exception.Message; $interrupted = $interruptionMessage -like 'Injected interruption after*' }
        Assert-InheritedCandidateTest $interrupted "production materializer did not cut at '$fault': $interruptionMessage"
        Assert-InheritedCandidateTest (Test-Path -LiteralPath $scenarioProgress -PathType Leaf) "interruption '$fault' left external bytes without authenticated progress"
        $scenarioUnit = Get-Content -LiteralPath (Join-Path $scenarioWorkspace "iteration-units\$unitId.json") -Raw | ConvertFrom-Json
        $scenarioEventCount = @((Get-Content -LiteralPath (Join-Path $scenarioWorkspace 'iteration-events.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) | Where-Object { $_.event_id -eq "$bindingId-materialized-recorded" }).Count
        switch ($fault) {
            'after-staged-extraction' {
                Assert-InheritedCandidateTest ((Test-Path -LiteralPath $scenarioStage -PathType Container) -and -not (Test-Path -LiteralPath $scenarioDestination) -and -not (Test-Path -LiteralPath $scenarioMarker) -and -not (Test-Path -LiteralPath $scenarioIntent) -and $scenarioEventCount -eq 0 -and -not ($scenarioUnit.PSObject.Properties.Name -contains 'inherited_candidate_materialization')) 'staged-extraction interruption has an unauthenticated or advanced projection'
            }
            'after-destination-install' {
                Assert-InheritedCandidateTest (-not (Test-Path -LiteralPath $scenarioStage) -and (Test-Path -LiteralPath $scenarioDestination -PathType Container) -and -not (Test-Path -LiteralPath $scenarioMarker) -and -not (Test-Path -LiteralPath $scenarioIntent) -and $scenarioEventCount -eq 0 -and -not ($scenarioUnit.PSObject.Properties.Name -contains 'inherited_candidate_materialization')) 'destination-install interruption has an unauthenticated or advanced projection'
            }
            'after-marker-install' {
                Assert-InheritedCandidateTest (-not (Test-Path -LiteralPath $scenarioStage) -and (Test-Path -LiteralPath $scenarioDestination -PathType Container) -and (Test-Path -LiteralPath $scenarioMarker -PathType Leaf) -and (Test-Path -LiteralPath $scenarioIntent -PathType Leaf) -and -not (Test-Path -LiteralPath $scenarioCompletion) -and $scenarioEventCount -eq 0 -and -not ($scenarioUnit.PSObject.Properties.Name -contains 'inherited_candidate_materialization')) 'marker-install interruption has an unauthenticated or advanced projection'
            }
            'after-ledger-commit' {
                Assert-InheritedCandidateTest (-not (Test-Path -LiteralPath $scenarioStage) -and (Test-Path -LiteralPath $scenarioDestination -PathType Container) -and (Test-Path -LiteralPath $scenarioMarker -PathType Leaf) -and (Test-Path -LiteralPath $scenarioIntent -PathType Leaf) -and (Test-Path -LiteralPath $scenarioCompletion -PathType Leaf) -and $scenarioEventCount -eq 1 -and ($scenarioUnit.PSObject.Properties.Name -contains 'inherited_candidate_materialization')) 'ledger-commit interruption has an unauthenticated or incomplete committed projection'
            }
        }
        if ($fault -eq 'after-staged-extraction') {
            Copy-Item -LiteralPath $scenarioStage -Destination $scenarioDestination -Recurse
            $conflictRejected = $false
            try { Invoke-MorphospaceMaterializeInheritedCandidate -WorkspaceRoot $scenarioWorkspace -UnitId $unitId -RepoMapPath $repoMapPath -MaterializationRoot $scenarioRoot -OutPath $scenarioMarker -Timestamp '2030-01-02T03:04:06.0000000Z' -Execute | Out-Null } catch { $conflictRejected = $_.Exception.Message -like 'Inherited-candidate recovery has both stage and destination*' }
            Assert-InheritedCandidateTest $conflictRejected 'recovery accepted conflicting staged and destination bytes'
            Remove-Item -LiteralPath $scenarioDestination -Recurse -Force
        }
        $recovered = Invoke-MorphospaceMaterializeInheritedCandidate -WorkspaceRoot $scenarioWorkspace -UnitId $unitId -RepoMapPath $repoMapPath -MaterializationRoot $scenarioRoot -OutPath $scenarioMarker -Timestamp '2030-01-02T03:04:06.0000000Z' -Execute
        Assert-InheritedCandidateTest (@('inherited-candidate-materialized', 'inherited-candidate-already-materialized') -contains $recovered.transition) "recovery after '$fault' did not complete the authenticated materialization"
        $finalScenarioUnit = Get-Content -LiteralPath (Join-Path $scenarioWorkspace "iteration-units\$unitId.json") -Raw | ConvertFrom-Json
        Assert-InheritedCandidateTest (-not (Test-Path -LiteralPath $scenarioProgress) -and (Test-MorphospaceInheritedCandidateMaterializationGate -WorkspaceRoot $scenarioWorkspace -Unit $finalScenarioUnit) -and ((Get-Content -LiteralPath (Join-Path $scenarioDestination 'src\lib.rs') -Raw) -eq $files['src/lib.rs'])) "recovery after '$fault' did not leave the exact verified final materialization"
        $finalEventCount = @((Get-Content -LiteralPath (Join-Path $scenarioWorkspace 'iteration-events.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) | Where-Object { $_.event_id -eq "$bindingId-materialized-recorded" }).Count
        Assert-InheritedCandidateTest ($finalEventCount -eq 1) "recovery after '$fault' duplicated or omitted the materialization event"
        $finalReplay = Invoke-MorphospaceMaterializeInheritedCandidate -WorkspaceRoot $scenarioWorkspace -UnitId $unitId -RepoMapPath $repoMapPath -MaterializationRoot $scenarioRoot -OutPath $scenarioMarker -Timestamp '2030-01-02T03:04:06.0000000Z' -Execute
        Assert-InheritedCandidateTest ($finalReplay.transition -eq 'inherited-candidate-already-materialized') "final replay after '$fault' was not idempotent"
    }
    $dry = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action MaterializeInheritedCandidate -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $repoMapPath -MaterializationRoot $materializationRoot -OutPath $markerPath -Timestamp '2030-01-02T03:04:06.0000000Z' | ConvertFrom-Json
    Assert-InheritedCandidateTest (-not $dry.executed -and (Test-Json -Json ($dry | ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json')) -and -not (Test-Path -LiteralPath $markerPath)) 'materialization dry run did not return a schema-valid exact marker projection without writing'
    $result = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action MaterializeInheritedCandidate -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $repoMapPath -MaterializationRoot $materializationRoot -OutPath $markerPath -Timestamp '2030-01-02T03:04:06.0000000Z' -Execute | ConvertFrom-Json
    Assert-InheritedCandidateTest ($result.transition -eq 'inherited-candidate-materialized' -and $result.action -eq 'MaterializeInheritedCandidate' -and $result.audit_receipt.sha256 -eq $dry.audit_receipt.sha256 -and (Test-Json -Json ($result | ConvertTo-Json -Depth 32) -SchemaFile (Join-Path $repoRoot 'schemas\work-unit-automation-receipt-v2.schema.json')) -and (Test-Path -LiteralPath $markerPath -PathType Leaf)) 'post-Claim materialization did not produce a schema-valid public receipt and exact dry-run marker projection'
    $materialized = Join-Path $materializationRoot $bindingId
    Assert-InheritedCandidateTest ((Get-Content -LiteralPath (Join-Path $materialized 'src\lib.rs') -Raw) -eq $files['src/lib.rs']) 'archive did not materialize exact task-local reference bytes'
    Assert-InheritedCandidateTest (Test-Json -Json (Get-Content -LiteralPath $unitPath -Raw) -SchemaFile (Join-Path $repoRoot 'schemas\iteration-unit.schema.json')) 'materialized inherited-candidate unit did not satisfy the strict iteration-unit schema'
    Assert-InheritedCandidateTest (Test-MorphospaceInheritedCandidateMaterializationGate -WorkspaceRoot $workspace -Unit (Get-Content -LiteralPath $unitPath -Raw | ConvertFrom-Json)) 'exact marker did not satisfy the source-work gate'
    $replay = & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action MaterializeInheritedCandidate -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $repoMapPath -MaterializationRoot $materializationRoot -OutPath $markerPath -Timestamp '2030-01-02T03:04:07.0000000Z' -Execute | ConvertFrom-Json
    Assert-InheritedCandidateTest ($replay.transition -eq 'inherited-candidate-already-materialized') 'exact replay was not idempotent'
    [IO.File]::AppendAllText((Join-Path $materialized 'src\lib.rs'), 'damage', [Text.UTF8Encoding]::new($false))
    $doubleMaterializationRejected = $false
    try { Invoke-MorphospaceMaterializeInheritedCandidate -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $repoMapPath -MaterializationRoot $materializationRoot -OutPath $markerPath -Execute | Out-Null } catch { $doubleMaterializationRejected = $_.Exception.Message -like 'Inherited-candidate materialized file differs*' }
    Assert-InheritedCandidateTest $doubleMaterializationRejected 'damaged replay did not fail closed instead of rematerializing'
    [IO.File]::AppendAllText($patchPath, 'substitution', [Text.UTF8Encoding]::new($false))
    $substitutionRejected = $false
    try { & (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action Claim -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $repoMapPath -Timestamp '2030-01-02T03:04:08.0000000Z' -Execute | Out-Null } catch { $substitutionRejected = $_.Exception.Message -like 'Inherited-candidate patch * differs*' }
    Assert-InheritedCandidateTest $substitutionRejected 'substituted task-local raw patch did not fail Claim-time evidence binding'
    Write-Output 'InheritedCandidateMaterialization self-test passed.'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
