Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Keep the caller's stable protocol/authorization command bindings.  A forced
# nested reload can remove commands that a long aggregate script still calls.
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'ExternalOwnerAuthorization.psm1')

function Get-MorphospaceHistoricalDebtRelativePath {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Path
    )

    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\\','/')
    $absolute = [IO.Path]::GetFullPath($Path)
    $prefix = $workspace + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Historical debt artifact is outside its workspace: $Path"
    }
    return ConvertTo-MorphospaceProtocolRelativePath -Path ($absolute.Substring($prefix.Length).Replace('\','/'))
}

function Get-MorphospaceHistoricalDebtFileRecord {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -RequireLeaf
    $item = Get-Item -LiteralPath $path -Force
    return [pscustomobject][ordered]@{
        path = ConvertTo-MorphospaceProtocolRelativePath -Path $RelativePath
        sha256 = Get-MorphospaceFileSha256 -Path $path
        length = [long]$item.Length
    }
}

function Get-MorphospaceHistoricalDebtValidatorIdentity {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $root = [IO.Path]::GetFullPath($RepoRoot)
    $commit = (& git -C $root rev-parse HEAD).Trim()
    $tree = (& git -C $root show -s --format='%T' HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[0-9a-f]{40}$' -or $tree -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
        throw 'Historical-debt validation requires an exact Git commit/tree identity for the Work Environment validator.'
    }
    # The full cold Test-WorkflowContracts aggregate executes validator scripts,
    # parses schemas/templates, and imports helpers. The ratchet must therefore
    # bind a closed manifest of every executable or validated input, not merely
    # the baseline helper itself. A new file in a validator-owned surface
    # requires a new baseline.
    $requiredFiles = [Collections.Generic.List[string]]::new()
    foreach ($relative in @(
        'scripts/Test-WorkflowContracts.ps1',
        'scripts/Test-ExecutedPushReceipt.ps1',
        'scripts/Test-ReleaseCapsule.ps1',
        'manifests/workflow-lifecycle.portable.json',
        'config/external-owner-authorization.json',
        'schemas/external-owner-authorization-policy-v1.schema.json'
    )) { $requiredFiles.Add($relative) | Out-Null }
    foreach ($directory in @('scripts/lib','schemas','templates')) {
        $absoluteDirectory = Join-Path $root ($directory -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not [IO.Directory]::Exists($absoluteDirectory)) { throw "Historical-debt validator directory is missing: $directory" }
        $filter = if ($directory -ceq 'scripts/lib') { '*.psm1' } else { '*.json' }
        foreach ($item in @(Get-ChildItem -LiteralPath $absoluteDirectory -Filter $filter -File -Recurse)) {
            $relative = ([IO.Path]::GetRelativePath($root, $item.FullName)).Replace('\','/')
            $requiredFiles.Add($relative) | Out-Null
        }
    }
    foreach ($surface in @(
        @{ directory='scripts'; filter='*.ps1' },
        @{ directory='scripts'; filter='*.psm1' },
        @{ directory='templates'; filter='*.jsonl' }
    )) {
        $absoluteDirectory = Join-Path $root (([string]$surface.directory) -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not [IO.Directory]::Exists($absoluteDirectory)) { throw "Historical-debt validator directory is missing: $($surface.directory)" }
        foreach ($item in @(Get-ChildItem -LiteralPath $absoluteDirectory -Filter ([string]$surface.filter) -File -Recurse)) {
            $relative = ([IO.Path]::GetRelativePath($root, $item.FullName)).Replace('\','/')
            $requiredFiles.Add($relative) | Out-Null
        }
    }
    $requiredFiles = @($requiredFiles.ToArray() | Sort-Object -Unique -CaseSensitive)
    if ($requiredFiles.Count -eq 0 -or $requiredFiles.Count -gt 512) { throw 'Historical-debt validator manifest is empty or exceeds its closed safety bound.' }
    $files = [Collections.Generic.List[object]]::new()
    foreach ($relative in $requiredFiles) {
        $path = Join-Path $root ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not [IO.File]::Exists($path)) { throw "Historical-debt validator file is missing: $relative" }
        $files.Add([pscustomobject][ordered]@{ path=$relative; sha256=Get-MorphospaceFileSha256 -Path $path }) | Out-Null
    }
    $orderedFiles = @($files.ToArray() | Sort-Object { [string]$_.path } -CaseSensitive)
    $identityCore = [ordered]@{ environment_commit=$commit; environment_tree=$tree; files=$orderedFiles }
    return [pscustomobject][ordered]@{
        environment_commit = $commit
        environment_tree = $tree
        files = $orderedFiles
        identity_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $identityCore
    }
}

function Get-MorphospaceHistoricalDebtEventPrefix {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath 'iteration-events.jsonl' -RequireLeaf
    [byte[]]$bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -gt 16777216) { throw 'Historical-debt event ledger exceeds the 16 MiB safety bound.' }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $tailEventId = $null
    $tailEventSha = $null
    foreach ($line in @($text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line)) -Context 'historical-debt event-ledger prefix line'
        $tailEventId = [string]$event.event_id
        $tailEventSha = Get-MorphospaceSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line))
    }
    if ($null -eq $tailEventId -or $null -eq $tailEventSha) { throw 'Historical-debt capture requires a non-empty exact event-ledger tail.' }
    return [pscustomobject][ordered]@{
        path = 'iteration-events.jsonl'
        sha256 = Get-MorphospaceSha256Bytes -Bytes $bytes
        length = [long]$bytes.Length
        tail_event_id = $tailEventId
        tail_event_sha256 = $tailEventSha
    }
}

function Get-MorphospaceHistoricalDebtCurrentUnit {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$State
    )

    if ($null -eq $State.current_unit) { throw 'Historical-debt capture requires one current active/validating unit.' }
    $unitId = [string]$State.current_unit
    if ($unitId -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') { throw 'Historical-debt capture needs one canonical current unit ID.' }
    $relative = "iteration-units/$unitId.json"
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $relative -RequireLeaf
    $unit = Read-MorphospaceProtocolJson -Path $path
    $status = [string]$unit.status
    if ([string]$unit.unit_id -cne $unitId -or $status -notin @('active','validating')) {
        throw 'Historical-debt capture current unit does not exactly match the active/validating workspace state.'
    }
    return [pscustomobject][ordered]@{
        unit_id = $unitId
        status = $status
        path = $relative
        raw_sha256 = Get-MorphospaceFileSha256 -Path $path
        canonical_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $unit
    }
}

function Get-MorphospaceHistoricalDebtSourceComposition {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RepositoryMapPath
    )

    $specPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath 'project.spec.json' -RequireLeaf
    $lockPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath 'feature.lock.json' -RequireLeaf
    $spec = Read-MorphospaceProtocolJson -Path $specPath
    $lock = Read-MorphospaceProtocolJson -Path $lockPath
    if ([int]$spec.revision -lt 1 -or [int]$lock.revision -lt 1) { throw 'Historical-debt source composition has an invalid project or source-lock revision.' }
    $mapPath = [IO.Path]::GetFullPath($RepositoryMapPath)
    if (-not [IO.File]::Exists($mapPath)) { throw "Historical-debt repository map is missing: $RepositoryMapPath" }
    $map = Read-MorphospaceProtocolJson -Path $mapPath
    $ids = @($map.repositories | ForEach-Object { [string]$_.repo_id } | Sort-Object -Unique -CaseSensitive)
    if ($ids.Count -eq 0 -or $ids.Count -ne @($map.repositories).Count) { throw 'Historical-debt repository map has missing or duplicate repository identities.' }
    $compositionCore = [ordered]@{
        project_spec = [ordered]@{ path='project.spec.json'; sha256=Get-MorphospaceFileSha256 -Path $specPath; revision=[int]$spec.revision }
        source_lock = [ordered]@{ path='feature.lock.json'; sha256=Get-MorphospaceFileSha256 -Path $lockPath; revision=[int]$lock.revision }
        repository_map = [ordered]@{
            sha256 = Get-MorphospaceFileSha256 -Path $mapPath
            repository_ids_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $ids
        }
    }
    return [pscustomobject][ordered]@{
        project_spec = $compositionCore.project_spec
        source_lock = $compositionCore.source_lock
        repository_map = $compositionCore.repository_map
        identity_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $compositionCore
    }
}

function Get-MorphospaceHistoricalDebtFailureSet {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FailureRecords,
        [Parameter(Mandatory)][object]$CapturedCurrentUnit
    )

    if ($FailureRecords.Count -eq 0) { throw 'A historical-debt baseline requires at least one observed failure.' }
    if ($FailureRecords.Count -gt 4096) { throw 'Historical-debt failure count exceeds the fixed bound.' }
    $rows = [Collections.Generic.List[object]]::new()
    $keys = [Collections.Generic.List[string]]::new()
    foreach ($record in @($FailureRecords)) {
        Assert-MorphospaceExactPropertySet -Value $record -Required @('failure_code','locus','message_sha256','evidence_sha256','record_sha256') -Context 'Historical-debt failure record'
        $code = [string]$record.failure_code
        if ($code -notin @('historical-unit-contract','legacy-workspace-state-contract')) {
            throw "Historical-debt baseline cannot cover failure code '$code'."
        }
        foreach ($hashName in @('message_sha256','evidence_sha256','record_sha256')) {
            if ([string]$record.$hashName -cnotmatch '^[0-9a-f]{64}$') { throw "Historical-debt failure record has an invalid $hashName." }
        }
        $locus = $record.locus
        $kind = [string]$locus.kind
        if ($code -ceq 'historical-unit-contract') {
            Assert-MorphospaceExactPropertySet -Value $locus -Required @('kind','unit_id','path','raw_sha256','canonical_sha256') -Context 'Historical-debt historical-unit locus'
            if ($kind -cne 'historical-unit' -or [string]$locus.unit_id -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$' -or
                [string]$locus.path -cnotmatch '^iteration-units/[a-z0-9][a-z0-9-]{1,127}\.json$' -or
                [string]$locus.raw_sha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]$locus.canonical_sha256 -cnotmatch '^[0-9a-f]{64}$') {
                throw 'Historical-debt historical-unit locus is malformed.'
            }
            if ($null -ne $CapturedCurrentUnit.unit_id -and [string]$locus.unit_id -ceq [string]$CapturedCurrentUnit.unit_id) {
                throw 'Historical-debt baseline cannot cover a failure attributable to the capture current unit.'
            }
            $key = "$code|$kind|$([string]$locus.unit_id)|$([string]$record.message_sha256)|$([string]$record.evidence_sha256)"
        } else {
            Assert-MorphospaceExactPropertySet -Value $locus -Required @('kind','path','raw_sha256','canonical_sha256') -Context 'Historical-debt workspace-state locus'
            if ($kind -cne 'legacy-workspace-state' -or [string]$locus.path -cne 'workspace.state.json' -or
                [string]$locus.raw_sha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]$locus.canonical_sha256 -cnotmatch '^[0-9a-f]{64}$') {
                throw 'Historical-debt workspace-state locus is malformed.'
            }
            $key = "$code|$kind|$([string]$locus.raw_sha256)|$([string]$record.message_sha256)|$([string]$record.evidence_sha256)"
        }
        $core = [ordered]@{
            failure_code = $code
            locus = $locus
            message_sha256 = [string]$record.message_sha256
            evidence_sha256 = [string]$record.evidence_sha256
        }
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $core) -cne [string]$record.record_sha256) {
            throw 'Historical-debt failure record digest does not bind its exact normalized evidence.'
        }
        $rows.Add([pscustomobject][ordered]@{
            failure_code = $core.failure_code
            locus = $core.locus
            message_sha256 = $core.message_sha256
            evidence_sha256 = $core.evidence_sha256
            record_sha256 = [string]$record.record_sha256
        }) | Out-Null
        $keys.Add($key) | Out-Null
    }
    [string[]]$orderedKeys = $keys.ToArray()
    [Array]::Sort($orderedKeys, [StringComparer]::Ordinal)
    if (($keys.ToArray() -join "`n") -cne ($orderedKeys -join "`n")) { throw 'Historical-debt failure records are not in canonical ordinal order.' }
    if (@($orderedKeys | Select-Object -Unique).Count -ne $orderedKeys.Count) { throw 'Historical-debt failure records are duplicated.' }
    $records = @($rows.ToArray())
    return [pscustomobject][ordered]@{
        records = $records
        count = $records.Count
        sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $records
    }
}

function Assert-MorphospaceHistoricalDebtFailureLoci {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$CapturedCurrentUnit,
        [Parameter(Mandatory)][object]$CapturedState,
        [Parameter(Mandatory)][object]$FailureSet
    )

    foreach ($record in @($FailureSet.records)) {
        $locus = $record.locus
        if ([string]$record.failure_code -ceq 'historical-unit-contract') {
            $unitId = [string]$locus.unit_id
            $expectedPath = "iteration-units/$unitId.json"
            if ([string]$locus.path -cne $expectedPath) { throw 'Historical-debt unit locus is not its canonical unit path.' }
            if ($unitId -ceq [string]$CapturedCurrentUnit.unit_id -or $unitId -ceq [string]$State.current_unit -or $unitId -ceq [string]$State.next_ready_unit) {
                throw 'Historical-debt baseline cannot cover a current or next unit locus.'
            }
            $unitPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $expectedPath -RequireLeaf
            $unit = Read-MorphospaceProtocolJson -Path $unitPath
            if ([string]$unit.unit_id -cne $unitId -or [string]$unit.status -notin @('accepted','blocked')) {
                throw 'Historical-debt unit locus is not a terminal non-current historical unit.'
            }
            if ([string]$locus.raw_sha256 -cne (Get-MorphospaceFileSha256 -Path $unitPath) -or
                [string]$locus.canonical_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 -Value $unit)) {
                throw 'Historical-debt unit locus raw or canonical identity drifted.'
            }
            continue
        }
        if ([string]$record.failure_code -ceq 'legacy-workspace-state-contract') {
            if ([string]$locus.raw_sha256 -cne [string]$CapturedState.sha256 -or
                [string]$locus.canonical_sha256 -cne [string]$CapturedState.canonical_sha256) {
                throw 'Historical-debt workspace-state locus does not bind the frozen workspace-state anchor.'
            }
            continue
        }
        throw 'Historical-debt failure locus has an unsupported failure code.'
    }
}

function New-MorphospaceHistoricalValidationDebtBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepositoryMapPath,
        [Parameter(Mandatory)][string]$BaselineId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FailureRecords,
        [datetimeoffset]$CreatedAt = [datetimeoffset]::UtcNow
    )

    if ($BaselineId -cnotmatch '^[a-z0-9][a-z0-9-]{7,127}$') { throw 'Historical-debt baseline ID is invalid.' }
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $statePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'workspace.state.json' -RequireLeaf
    $state = Read-MorphospaceProtocolJson -Path $statePath
    $current = Get-MorphospaceHistoricalDebtCurrentUnit -WorkspaceRoot $workspace -State $state
    $failureSet = Get-MorphospaceHistoricalDebtFailureSet -FailureRecords $FailureRecords -CapturedCurrentUnit $current
    $stateRecord = Get-MorphospaceHistoricalDebtFileRecord -WorkspaceRoot $workspace -RelativePath 'workspace.state.json'
    $stateFile = [pscustomobject][ordered]@{
        path = [string]$stateRecord.path
        sha256 = [string]$stateRecord.sha256
        length = [long]$stateRecord.length
        canonical_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $state
    }
    $ledger = Get-MorphospaceHistoricalDebtEventPrefix -WorkspaceRoot $workspace
    $anchorCore = [ordered]@{ planning_state=$stateFile; event_ledger_prefix=$ledger }
    $anchor = [pscustomobject][ordered]@{
        planning_state = $stateFile
        event_ledger_prefix = $ledger
        identity_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $anchorCore
    }
    $validator = Get-MorphospaceHistoricalDebtValidatorIdentity -RepoRoot $RepoRoot
    $composition = Get-MorphospaceHistoricalDebtSourceComposition -WorkspaceRoot $workspace -RepositoryMapPath $RepositoryMapPath
    $authorizationPath = "receipts/historical-validation-debt/$BaselineId/authorization.json"
    $baseline = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.historical_validation_debt_baseline.v1'
        baseline_id = $BaselineId
        created_at = ConvertTo-MorphospaceUtcTimestamp -Value $CreatedAt
        status = 'unresolved'
        project_id = [string]$state.project_id
        validator = $validator
        workspace_anchor = $anchor
        source_composition = $composition
        current_unit = $current
        failure_records = @($failureSet.records)
        failure_set = [pscustomobject][ordered]@{ count=$failureSet.count; sha256=$failureSet.sha256 }
        authorization = [pscustomobject][ordered]@{
            path = $authorizationPath
            schema = 'rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1'
            required = $true
        }
    }
    return $baseline
}

function New-MorphospaceHistoricalValidationDebtAuthorizationPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Baseline,
        [Parameter(Mandatory)][string]$BaselineSha256,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$AuditId,
        [Parameter(Mandatory)][string]$IssuedAt,
        [Parameter(Mandatory)][string]$ExpiresAt,
        [Parameter(Mandatory)][string]$IssuerId
    )

    if ($BaselineSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Historical-debt baseline SHA-256 is invalid.' }
    foreach ($pair in @(@{name='AuthorizationId';value=$AuthorizationId}, @{name='AuditId';value=$AuditId})) {
        if ([string]$pair.value -cnotmatch '^[a-z0-9][a-z0-9-]{7,127}$') { throw "Historical-debt $($pair.name) is invalid." }
    }
    return [ordered]@{
        schema = 'rusty.morphospace.workflow.historical_validation_debt_baseline_authorization_payload.v1'
        issuer_id = $IssuerId
        authorization_id = $AuthorizationId
        audit_id = $AuditId
        project_id = [string]$Baseline.project_id
        baseline_id = [string]$Baseline.baseline_id
        baseline_sha256 = $BaselineSha256
        validator_identity_sha256 = [string]$Baseline.validator.identity_sha256
        workspace_anchor_sha256 = [string]$Baseline.workspace_anchor.identity_sha256
        source_composition_sha256 = [string]$Baseline.source_composition.identity_sha256
        current_unit_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $Baseline.current_unit
        failure_set_sha256 = [string]$Baseline.failure_set.sha256
        failure_count = [int]$Baseline.failure_set.count
        issued_at = $IssuedAt
        expires_at = $ExpiresAt
        decision = 'authorize-historical-validation-debt-baseline'
        limitations = @(
            'historical_debt_remains_unresolved=true',
            'current_unit_validation_authority=false',
            'acceptance_authority=false',
            'source_or_workspace_mutation_authority=false'
        )
    }
}

function Assert-MorphospaceHistoricalDebtAuthorizationIdentityUniqueness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ExpectedAuthorizationRelative,
        [Parameter(Mandatory)][byte[]]$AuthorizationBytes,
        [Parameter(Mandatory)][object]$AuthorizationDocument,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$AuthorizationSchemaPath
    )

    $root = Join-Path ([IO.Path]::GetFullPath($WorkspaceRoot)) 'receipts/historical-validation-debt'
    if (-not [IO.Directory]::Exists($root)) { throw 'Historical-debt authorization receipt root is missing.' }
    $authorizationId = [string]$AuthorizationDocument.payload.authorization_id
    $auditId = [string]$AuthorizationDocument.payload.audit_id
    $authorizationSchema = [IO.Path]::GetFullPath($AuthorizationSchemaPath)
    $baselineSchema = Join-Path $moduleRoot 'schemas/historical-validation-debt-baseline-v1.schema.json'
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory)) {
        $baselineId = [string]$directory.Name
        if ($baselineId -cnotmatch '^[a-z0-9][a-z0-9-]{7,127}$') {
            throw "Historical-debt authorization receipt directory has an invalid baseline ID: $baselineId"
        }
        $authorizationRelative = "receipts/historical-validation-debt/$baselineId/authorization.json"
        $authorizationPath = Join-Path $directory.FullName 'authorization.json'
        if (-not [IO.File]::Exists($authorizationPath)) { continue }
        [byte[]]$peerAuthorizationBytes = [IO.File]::ReadAllBytes($authorizationPath)
        if ($authorizationRelative -ceq $ExpectedAuthorizationRelative) {
            if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($peerAuthorizationBytes, $AuthorizationBytes)) {
                throw 'Historical-debt authorization sibling bytes changed during uniqueness verification.'
            }
            continue
        }

        $peerAuthorization = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $peerAuthorizationBytes -Context 'Historical-debt peer authorization'
        if (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $peerAuthorization) -SchemaFile $authorizationSchema -ErrorAction Stop)) {
            throw "Historical-debt peer authorization '$authorizationRelative' failed its closed schema."
        }
        $baselineRelative = "receipts/historical-validation-debt/$baselineId/baseline.json"
        $baselinePath = Join-Path $directory.FullName 'baseline.json'
        if (-not [IO.File]::Exists($baselinePath)) {
            throw "Historical-debt peer authorization '$authorizationRelative' lacks its canonical baseline sibling."
        }
        [byte[]]$peerBaselineBytes = [IO.File]::ReadAllBytes($baselinePath)
        $peerBaseline = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $peerBaselineBytes -Context 'Historical-debt peer baseline'
        if (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $peerBaseline) -SchemaFile $baselineSchema -ErrorAction Stop)) {
            throw "Historical-debt peer baseline '$baselineRelative' failed its closed schema."
        }
        if ([string]$peerAuthorization.payload.project_id -cne $ProjectId -or
            [string]$peerAuthorization.payload.baseline_id -cne $baselineId -or
            [string]$peerBaseline.baseline_id -cne $baselineId -or
            [string]$peerAuthorization.payload.baseline_sha256 -cne (Get-MorphospaceSha256Bytes -Bytes $peerBaselineBytes)) {
            throw "Historical-debt peer authorization '$authorizationRelative' is not bound to its canonical project/baseline sibling."
        }
        if ([string]$peerAuthorization.payload.authorization_id -ceq $authorizationId -or [string]$peerAuthorization.payload.audit_id -ceq $auditId) {
            throw 'Historical-debt authorization_id or audit_id was already consumed by another canonical baseline sibling.'
        }
    }
}

function Test-MorphospaceHistoricalValidationDebtBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepositoryMapPath,
        [Parameter(Mandatory)][string]$BaselinePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FailureRecords,
        [string]$PolicyPath = '',
        [string]$PolicySchemaPath = '',
        [string]$AuthorizationSchemaPath = '',
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $baselineRelative = if ([IO.Path]::IsPathRooted($BaselinePath)) {
        Get-MorphospaceHistoricalDebtRelativePath -WorkspaceRoot $workspace -Path $BaselinePath
    } else {
        ConvertTo-MorphospaceProtocolRelativePath -Path $BaselinePath
    }
    if ($baselineRelative -cnotmatch '^receipts/historical-validation-debt/(?<id>[a-z0-9][a-z0-9-]{7,127})/baseline\.json$') {
        throw 'Historical-debt baseline path is not its canonical immutable receipt path.'
    }
    $baselineIdFromPath = $Matches['id']
    $baselineAbsolute = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative -RequireLeaf
    [byte[]]$baselineBytes = [IO.File]::ReadAllBytes($baselineAbsolute)
    $baseline = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineBytes -Context 'Historical-debt baseline'
    $baselineSchema = Join-Path $moduleRoot 'schemas/historical-validation-debt-baseline-v1.schema.json'
    $baselineCanonical = ConvertTo-MorphospaceCanonicalJson -Value $baseline
    if (-not (Test-Json -Json $baselineCanonical -SchemaFile $baselineSchema -ErrorAction Stop)) { throw 'Historical-debt baseline failed its closed schema.' }
    Assert-MorphospaceExactPropertySet -Value $baseline -Required @('schema','baseline_id','created_at','status','project_id','validator','workspace_anchor','source_composition','current_unit','failure_records','failure_set','authorization') -Context 'Historical-debt baseline'
    if ([string]$baseline.baseline_id -cne $baselineIdFromPath -or [string]$baseline.status -cne 'unresolved') {
        throw 'Historical-debt baseline identity or unresolved status is invalid.'
    }
    [void](Test-MorphospaceStrictUtcTimestamp -Value ([string]$baseline.created_at))

    $statePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'workspace.state.json' -RequireLeaf
    $state = Read-MorphospaceProtocolJson -Path $statePath
    if ([string]$baseline.project_id -cne [string]$state.project_id) { throw 'Historical-debt baseline belongs to another project.' }
    $expectedValidator = Get-MorphospaceHistoricalDebtValidatorIdentity -RepoRoot $RepoRoot
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $baseline.validator) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $expectedValidator)) {
        throw 'Historical-debt baseline validator commit/tree or relevant script/schema identity drifted.'
    }
    $expectedComposition = Get-MorphospaceHistoricalDebtSourceComposition -WorkspaceRoot $workspace -RepositoryMapPath $RepositoryMapPath
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $baseline.source_composition) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $expectedComposition)) {
        throw 'Historical-debt baseline project/source-lock/repository-map composition drifted.'
    }
    Assert-MorphospaceExactPropertySet -Value $baseline.workspace_anchor -Required @('planning_state','event_ledger_prefix','identity_sha256') -Context 'Historical-debt workspace anchor'
    $anchorCore = [ordered]@{ planning_state=$baseline.workspace_anchor.planning_state; event_ledger_prefix=$baseline.workspace_anchor.event_ledger_prefix }
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $anchorCore) -cne [string]$baseline.workspace_anchor.identity_sha256) {
        throw 'Historical-debt workspace-anchor digest is inconsistent.'
    }
    $ledger = $baseline.workspace_anchor.event_ledger_prefix
    Assert-MorphospaceExactPropertySet -Value $ledger -Required @('path','sha256','length','tail_event_id','tail_event_sha256') -Context 'Historical-debt event-ledger prefix'
    if ([string]$ledger.path -cne 'iteration-events.jsonl' -or [string]$ledger.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$ledger.length -lt 1 -or
        [string]$ledger.tail_event_id -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$' -or [string]$ledger.tail_event_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Historical-debt event-ledger prefix identity is malformed.'
    }
    $ledgerPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'iteration-events.jsonl' -RequireLeaf
    [byte[]]$liveLedgerBytes = [IO.File]::ReadAllBytes($ledgerPath)
    if ($liveLedgerBytes.Length -lt [long]$ledger.length) { throw 'Historical-debt event-ledger prefix was truncated.' }
    [byte[]]$prefixBytes = [byte[]]::new([int]$ledger.length)
    if ($prefixBytes.Length -gt 0) { [Array]::Copy($liveLedgerBytes, 0, $prefixBytes, 0, $prefixBytes.Length) }
    if ((Get-MorphospaceSha256Bytes -Bytes $prefixBytes) -cne [string]$ledger.sha256) { throw 'Historical-debt event-ledger prefix drifted.' }
    $capturedPrefixText = [Text.UTF8Encoding]::new($false, $true).GetString($prefixBytes)
    $actualTailId = $null; $actualTailSha = $null
    foreach ($line in @($capturedPrefixText -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line)) -Context 'Historical-debt captured event prefix line'
        $actualTailId = [string]$event.event_id
        $actualTailSha = Get-MorphospaceSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($line))
    }
    if ([string]$actualTailId -cne [string]$ledger.tail_event_id -or [string]$actualTailSha -cne [string]$ledger.tail_event_sha256) {
        throw 'Historical-debt event-ledger tail identity drifted.'
    }
    $prefixIsCurrentLedger = $liveLedgerBytes.Length -eq [long]$ledger.length

    $capturedCurrent = $baseline.current_unit
    Assert-MorphospaceExactPropertySet -Value $capturedCurrent -Required @('unit_id','status','path','raw_sha256','canonical_sha256') -Context 'Historical-debt capture current unit'
    if ([string]$capturedCurrent.unit_id -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$' -or [string]$capturedCurrent.status -notin @('active','validating') -or
        [string]$capturedCurrent.path -cne "iteration-units/$([string]$capturedCurrent.unit_id).json" -or [string]$capturedCurrent.raw_sha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]$capturedCurrent.canonical_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Historical-debt capture current-unit identity is malformed.'
    }
    $capturedState = $baseline.workspace_anchor.planning_state
    Assert-MorphospaceExactPropertySet -Value $capturedState -Required @('path','sha256','length','canonical_sha256') -Context 'Historical-debt workspace-state anchor'
    if ([string]$capturedState.path -cne 'workspace.state.json' -or [string]$capturedState.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$capturedState.length -lt 0 -or [string]$capturedState.canonical_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Historical-debt workspace-state anchor is malformed.'
    }
    $baselineSet = Get-MorphospaceHistoricalDebtFailureSet -FailureRecords @($baseline.failure_records) -CapturedCurrentUnit $capturedCurrent
    if ($baselineSet.count -ne [int]$baseline.failure_set.count -or $baselineSet.sha256 -cne [string]$baseline.failure_set.sha256) {
        throw 'Historical-debt baseline failure-set count or digest is inconsistent.'
    }
    Assert-MorphospaceHistoricalDebtFailureLoci -WorkspaceRoot $workspace -State $state -CapturedCurrentUnit $capturedCurrent -CapturedState $capturedState -FailureSet $baselineSet
    $hasStateDebt = @($baselineSet.records | Where-Object { [string]$_.failure_code -ceq 'legacy-workspace-state-contract' }).Count -gt 0
    $liveStateRecord = Get-MorphospaceHistoricalDebtFileRecord -WorkspaceRoot $workspace -RelativePath 'workspace.state.json'
    $liveState = [pscustomobject][ordered]@{
        path = [string]$liveStateRecord.path
        sha256 = [string]$liveStateRecord.sha256
        length = [long]$liveStateRecord.length
        canonical_sha256 = Get-MorphospaceCanonicalJsonSha256 -Value $state
    }
    if ($hasStateDebt -or $prefixIsCurrentLedger) {
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $capturedState) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $liveState)) {
            throw 'Historical-debt workspace-state binding drifted before a valid post-baseline ledger suffix, or is frozen by covered legacy workspace-state debt.'
        }
    }
    $recomputedSet = Get-MorphospaceHistoricalDebtFailureSet -FailureRecords $FailureRecords -CapturedCurrentUnit $capturedCurrent
    if ($recomputedSet.count -ne $baselineSet.count -or $recomputedSet.sha256 -cne $baselineSet.sha256) {
        throw 'Historical-debt ratchet contradiction: complete recomputed failure set differs from the authorized baseline.'
    }

    Assert-MorphospaceExactPropertySet -Value $baseline.authorization -Required @('path','schema','required') -Context 'Historical-debt authorization reference'
    $expectedAuthorizationRelative = "receipts/historical-validation-debt/$baselineIdFromPath/authorization.json"
    if ([string]$baseline.authorization.path -cne $expectedAuthorizationRelative -or
        [string]$baseline.authorization.schema -cne 'rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1' -or
        $baseline.authorization.required -ne $true) {
        throw 'Historical-debt authorization reference is not the canonical required sibling.'
    }
    $authorizationAbsolute = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $expectedAuthorizationRelative -RequireLeaf
    [byte[]]$authorizationBytes = [IO.File]::ReadAllBytes($authorizationAbsolute)
    $policyFile = if ($PolicyPath) { $PolicyPath } else { Join-Path $moduleRoot 'config/external-owner-authorization.json' }
    $policySchemaFile = if ($PolicySchemaPath) { $PolicySchemaPath } else { Join-Path $moduleRoot 'schemas/external-owner-authorization-policy-v1.schema.json' }
    $authorizationSchemaFile = if ($AuthorizationSchemaPath) { $AuthorizationSchemaPath } else { Join-Path $moduleRoot 'schemas/historical-validation-debt-baseline-authorization-v1.schema.json' }
    $policy = Read-ExternalOwnerAuthorizationPolicy -Path $policyFile -SchemaPath $policySchemaFile
    $authorizationDocument = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $authorizationBytes -Context 'Historical-debt authorization'
    $expectedPayload = New-MorphospaceHistoricalValidationDebtAuthorizationPayload `
        -Baseline $baseline `
        -BaselineSha256 (Get-MorphospaceSha256Bytes -Bytes $baselineBytes) `
        -AuthorizationId ([string]$authorizationDocument.payload.authorization_id) `
        -AuditId ([string]$authorizationDocument.payload.audit_id) `
        -IssuedAt ([string]$authorizationDocument.payload.issued_at) `
        -ExpiresAt ([string]$authorizationDocument.payload.expires_at) `
        -IssuerId ([string]$policy.issuer_id)
    $payload = Test-ExternalOwnerSignedPayload `
        -DocumentText ([Text.UTF8Encoding]::new($false, $true).GetString($authorizationBytes)) `
        -ExpectedPayload $expectedPayload -Policy $policy -SchemaPath $authorizationSchemaFile -Now $Now
    if ([string]$payload.audit_id -cnotmatch '^[a-z0-9][a-z0-9-]{7,127}$') { throw 'Historical-debt authorization audit ID is invalid.' }
    Assert-MorphospaceHistoricalDebtAuthorizationIdentityUniqueness `
        -WorkspaceRoot $workspace -ExpectedAuthorizationRelative $expectedAuthorizationRelative `
        -AuthorizationBytes $authorizationBytes -AuthorizationDocument $authorizationDocument `
        -ProjectId ([string]$state.project_id) -AuthorizationSchemaPath $authorizationSchemaFile

    $liveCurrent = Get-MorphospaceHistoricalDebtCurrentUnit -WorkspaceRoot $workspace -State $state
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $liveCurrent) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $capturedCurrent)) {
        throw 'Historical-debt capture current-unit identity drifted; a ratchet cannot cover any current-unit transition or rewrite.'
    }
    $baselineReference = [pscustomobject][ordered]@{
        role = 'historical-validation-debt-baseline'
        path = $baselineRelative
        schema = 'rusty.morphospace.workflow.historical_validation_debt_baseline.v1'
        sha256 = Get-MorphospaceSha256Bytes -Bytes $baselineBytes
    }
    $authorizationReference = [pscustomobject][ordered]@{
        role = 'historical-validation-debt-authorization'
        path = $expectedAuthorizationRelative
        schema = 'rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1'
        sha256 = Get-MorphospaceSha256Bytes -Bytes $authorizationBytes
    }
    return [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.historical_validation_debt_result.v1'
        project_id = [string]$state.project_id
        current_unit = $liveCurrent
        baseline = $baselineReference
        authorization = $authorizationReference
        validator_identity_sha256 = [string]$expectedValidator.identity_sha256
        current_validation = 'passed'
        historical_debt_present = $true
        historical_debt = [pscustomobject][ordered]@{
            baseline_id = [string]$baseline.baseline_id
            count = $baselineSet.count
            sha256 = $baselineSet.sha256
            status = 'unresolved'
        }
        recomputed_failure_set = [pscustomobject][ordered]@{ count=$recomputedSet.count; sha256=$recomputedSet.sha256 }
        status = 'debt-bearing-success'
    }
}

function Test-MorphospaceHistoricalValidationDebtReceiptBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$Binding,
        [string]$PolicyPath = '',
        [string]$PolicySchemaPath = '',
        [string]$AuthorizationSchemaPath = '',
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    Assert-MorphospaceExactPropertySet -Value $Binding -Required @('baseline','authorization','result') -Context 'Historical-debt receipt binding'
    foreach ($pair in @(
        @{ value=$Binding.baseline; role='historical-validation-debt-baseline'; schema='rusty.morphospace.workflow.historical_validation_debt_baseline.v1'; label='baseline' },
        @{ value=$Binding.authorization; role='historical-validation-debt-authorization'; schema='rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1'; label='authorization' },
        @{ value=$Binding.result; role='historical-validation-debt-result'; schema='rusty.morphospace.workflow.historical_validation_debt_result.v1'; label='result' }
    )) {
        Assert-MorphospaceExactPropertySet -Value $pair.value -Required @('role','path','schema','sha256') -Context "Historical-debt receipt $($pair.label) reference"
        if ([string]$pair.value.role -cne $pair.role -or [string]$pair.value.schema -cne $pair.schema -or [string]$pair.value.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Historical-debt receipt $($pair.label) reference is invalid."
        }
    }
    $baseline = Read-MorphospaceTypedFileSnapshot -WorkspaceRoot $WorkspaceRoot -Reference $Binding.baseline -Context 'Historical-debt receipt baseline'
    $authorization = Read-MorphospaceTypedFileSnapshot -WorkspaceRoot $WorkspaceRoot -Reference $Binding.authorization -Context 'Historical-debt receipt authorization'
    $result = Read-MorphospaceTypedFileSnapshot -WorkspaceRoot $WorkspaceRoot -Reference $Binding.result -Context 'Historical-debt receipt result'
    try {
        $baselineSchema = Join-Path $moduleRoot 'schemas/historical-validation-debt-baseline-v1.schema.json'
        $resultSchema = Join-Path $moduleRoot 'schemas/historical-validation-debt-result-v1.schema.json'
        if (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $baseline.document) -SchemaFile $baselineSchema -ErrorAction Stop)) {
            throw 'Historical-debt receipt baseline failed its closed schema.'
        }
        if (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $result.document) -SchemaFile $resultSchema -ErrorAction Stop)) {
            throw 'Historical-debt receipt result failed its closed schema.'
        }
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $result.document.baseline) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $Binding.baseline) -or
            (Get-MorphospaceCanonicalJsonSha256 -Value $result.document.authorization) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $Binding.authorization)) {
            throw 'Historical-debt receipt result does not bind the exact baseline and authorization references.'
        }
        $expectedBaselinePath = "receipts/historical-validation-debt/$([string]$baseline.document.baseline_id)/baseline.json"
        $expectedResultPath = "receipts/historical-validation-debt/$([string]$baseline.document.baseline_id)/results/$([string]$result.document.current_unit.raw_sha256).json"
        if ([string]$Binding.baseline.path -cne $expectedBaselinePath -or [string]$Binding.result.path -cne $expectedResultPath) {
            throw 'Historical-debt receipt result is not at its canonical baseline/current-unit location.'
        }
        if ([string]$result.document.validator_identity_sha256 -cne [string]$baseline.document.validator.identity_sha256) {
            throw 'Historical-debt receipt result validator identity does not match its baseline.'
        }
        $liveValidator = Get-MorphospaceHistoricalDebtValidatorIdentity -RepoRoot $moduleRoot
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $baseline.document.validator) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $liveValidator) -or
            [string]$result.document.validator_identity_sha256 -cne [string]$liveValidator.identity_sha256) {
            throw 'Historical-debt receipt validator identity drifted from the live Work Environment validator.'
        }
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $result.document.current_unit) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $baseline.document.current_unit)) {
            throw 'Historical-debt receipt result current unit does not match its baseline.'
        }
        if ([string]$result.document.current_validation -cne 'passed' -or $result.document.historical_debt_present -ne $true -or
            [string]$result.document.status -cne 'debt-bearing-success' -or [string]$result.document.historical_debt.status -cne 'unresolved') {
            throw 'Historical-debt receipt result misstates the debt-bearing validation outcome.'
        }
        if ([string]$result.document.historical_debt.baseline_id -cne [string]$baseline.document.baseline_id -or
            [string]$result.document.historical_debt.sha256 -cne [string]$baseline.document.failure_set.sha256 -or
            [int]$result.document.historical_debt.count -ne [int]$baseline.document.failure_set.count -or
            [string]$result.document.recomputed_failure_set.sha256 -cne [string]$baseline.document.failure_set.sha256 -or
            [int]$result.document.recomputed_failure_set.count -ne [int]$baseline.document.failure_set.count) {
            throw 'Historical-debt receipt result does not bind the baseline failure set.'
        }
        Assert-MorphospaceExactPropertySet -Value $baseline.document.authorization -Required @('path','schema','required') -Context 'Historical-debt receipt baseline authorization reference'
        $expectedAuthorizationPath = "receipts/historical-validation-debt/$([string]$baseline.document.baseline_id)/authorization.json"
        if ([string]$baseline.document.authorization.path -cne $expectedAuthorizationPath -or
            [string]$baseline.document.authorization.schema -cne 'rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1' -or
            $baseline.document.authorization.required -ne $true -or [string]$Binding.authorization.path -cne $expectedAuthorizationPath) {
            throw 'Historical-debt receipt authorization is not the canonical required sibling.'
        }
        $policyFile = if ($PolicyPath) { $PolicyPath } else { Join-Path $moduleRoot 'config/external-owner-authorization.json' }
        $policySchemaFile = if ($PolicySchemaPath) { $PolicySchemaPath } else { Join-Path $moduleRoot 'schemas/external-owner-authorization-policy-v1.schema.json' }
        $authorizationSchemaFile = if ($AuthorizationSchemaPath) { $AuthorizationSchemaPath } else { Join-Path $moduleRoot 'schemas/historical-validation-debt-baseline-authorization-v1.schema.json' }
        $policy = Read-ExternalOwnerAuthorizationPolicy -Path $policyFile -SchemaPath $policySchemaFile
        $authorizationDocument = $authorization.document
        $expectedPayload = New-MorphospaceHistoricalValidationDebtAuthorizationPayload `
            -Baseline $baseline.document -BaselineSha256 ([string]$Binding.baseline.sha256) `
            -AuthorizationId ([string]$authorizationDocument.payload.authorization_id) `
            -AuditId ([string]$authorizationDocument.payload.audit_id) `
            -IssuedAt ([string]$authorizationDocument.payload.issued_at) `
            -ExpiresAt ([string]$authorizationDocument.payload.expires_at) `
            -IssuerId ([string]$policy.issuer_id)
        $null = Test-ExternalOwnerSignedPayload `
            -DocumentText ([Text.UTF8Encoding]::new($false, $true).GetString($authorization.bytes)) `
            -ExpectedPayload $expectedPayload -Policy $policy -SchemaPath $authorizationSchemaFile -Now $Now
        Assert-MorphospaceHistoricalDebtAuthorizationIdentityUniqueness `
            -WorkspaceRoot $WorkspaceRoot -ExpectedAuthorizationRelative $expectedAuthorizationPath `
            -AuthorizationBytes $authorization.bytes -AuthorizationDocument $authorizationDocument `
            -ProjectId ([string]$baseline.document.project_id) -AuthorizationSchemaPath $authorizationSchemaFile
        return $result.document
    } finally {
        foreach ($snapshot in @($baseline, $authorization, $result)) {
            if ($null -ne $snapshot.stream) { $snapshot.stream.Dispose() }
        }
    }
}

function Get-MorphospaceHistoricalValidationDebtReceiptRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$CurrentUnit,
        [string]$PolicyPath = '',
        [string]$PolicySchemaPath = '',
        [string]$AuthorizationSchemaPath = '',
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $unitId = [string]$CurrentUnit.unit_id
    if ($unitId -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') { throw 'Historical-debt receipt requirement has an invalid current unit ID.' }
    $unitPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath "iteration-units/$unitId.json" -RequireLeaf
    $rawSha = Get-MorphospaceFileSha256 -Path $unitPath
    $canonicalSha = Get-MorphospaceCanonicalJsonSha256 -Value $CurrentUnit
    $root = Join-Path $workspace 'receipts/historical-validation-debt'
    if (-not [IO.Directory]::Exists($root)) { return $null }

    $bindings = [Collections.Generic.List[object]]::new()
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory)) {
        $baselineId = [string]$directory.Name
        if ($baselineId -cnotmatch '^[a-z0-9][a-z0-9-]{7,127}$') { throw "Historical-debt receipt directory has an invalid baseline ID: $baselineId" }
        $resultRelative = "receipts/historical-validation-debt/$baselineId/results/$rawSha.json"
        $resultPath = Join-Path $workspace ($resultRelative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not [IO.File]::Exists($resultPath)) { continue }
        $resultDocument = Read-MorphospaceProtocolJson -Path $resultPath
        $binding = [pscustomobject][ordered]@{
            baseline = $resultDocument.baseline
            authorization = $resultDocument.authorization
            result = [pscustomobject][ordered]@{
                role = 'historical-validation-debt-result'
                path = $resultRelative
                schema = 'rusty.morphospace.workflow.historical_validation_debt_result.v1'
                sha256 = Get-MorphospaceFileSha256 -Path $resultPath
            }
        }
        $result = Test-MorphospaceHistoricalValidationDebtReceiptBinding `
            -WorkspaceRoot $workspace -Binding $binding -PolicyPath $PolicyPath -PolicySchemaPath $PolicySchemaPath `
            -AuthorizationSchemaPath $AuthorizationSchemaPath -Now $Now
        if ([string]$result.current_unit.unit_id -cne $unitId -or [string]$result.current_unit.raw_sha256 -cne $rawSha -or
            [string]$result.current_unit.canonical_sha256 -cne $canonicalSha) {
            throw 'Historical-debt result does not bind the exact current unit required by its receipt path.'
        }
        $bindings.Add($binding) | Out-Null
    }
    if ($bindings.Count -gt 1) { throw 'More than one valid historical-debt result applies to the exact current unit; receipt authority is ambiguous.' }
    if ($bindings.Count -eq 0) { return $null }
    return $bindings[0]
}

function Assert-MorphospaceHistoricalValidationDebtReceiptRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$CurrentUnit,
        [Parameter(Mandatory)][object]$Receipt,
        [string]$PolicyPath = '',
        [string]$PolicySchemaPath = '',
        [string]$AuthorizationSchemaPath = '',
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    $required = Get-MorphospaceHistoricalValidationDebtReceiptRequirement `
        -WorkspaceRoot $WorkspaceRoot -CurrentUnit $CurrentUnit -PolicyPath $PolicyPath -PolicySchemaPath $PolicySchemaPath `
        -AuthorizationSchemaPath $AuthorizationSchemaPath -Now $Now
    if ($null -eq $required) { return $null }
    if ($Receipt.PSObject.Properties.Name -cnotcontains 'historical_validation_debt') {
        throw 'Validation receipt must bind the exact historical-debt result that ratcheted this current unit.'
    }
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $Receipt.historical_validation_debt) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $required)) {
        throw 'Validation receipt historical-debt binding differs from the exact current ratchet result.'
    }
    return $required
}

Export-ModuleMember -Function `
    Get-MorphospaceHistoricalDebtFailureSet, New-MorphospaceHistoricalValidationDebtBaseline, `
    New-MorphospaceHistoricalValidationDebtAuthorizationPayload, Test-MorphospaceHistoricalValidationDebtBaseline, `
    Test-MorphospaceHistoricalValidationDebtReceiptBinding, Get-MorphospaceHistoricalValidationDebtReceiptRequirement, `
    Assert-MorphospaceHistoricalValidationDebtReceiptRequirement
