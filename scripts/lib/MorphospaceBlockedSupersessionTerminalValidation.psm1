Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force

function Get-MorphospaceBlockedSupersessionSha256Slice {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Count
    )
    if ($Offset -lt 0 -or $Count -lt 0 -or ($Offset + $Count) -gt $Bytes.Length) {
        throw 'Byte-slice bounds are invalid.'
    }
    $slice = [byte[]]::new($Count)
    if ($Count -gt 0) { [Array]::Copy($Bytes, $Offset, $slice, 0, $Count) }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($slice)).ToLowerInvariant()
}

function Get-MorphospaceBlockedSupersessionLedger {
    param([Parameter(Mandatory = $true)][string]$WorkspaceRoot)

    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath 'iteration-events.jsonl' -RequireLeaf
    $bytes = [IO.File]::ReadAllBytes($path)
    $rows = [Collections.Generic.List[object]]::new()
    $start = 0
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -ne 10) { continue }
        $contentEnd = $index
        if ($contentEnd -gt $start -and $bytes[$contentEnd - 1] -eq 13) { $contentEnd-- }
        if ($contentEnd -eq $start) { throw "Event ledger contains a blank record at byte offset $start." }
        $lineBytes = [byte[]]::new($contentEnd - $start)
        [Array]::Copy($bytes, $start, $lineBytes, 0, $lineBytes.Length)
        $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $lineBytes -Context "event ledger byte offset $start"
        $rows.Add([pscustomobject][ordered]@{
            ordinal = $rows.Count
            start_offset = $start
            end_offset = $index + 1
            prefix_sha256 = Get-MorphospaceBlockedSupersessionSha256Slice -Bytes $bytes -Offset 0 -Count $start
            line_sha256 = Get-MorphospaceSha256Bytes -Bytes $lineBytes
            document = $document
        }) | Out-Null
        $start = $index + 1
    }
    if ($start -lt $bytes.Length) {
        $lineBytes = [byte[]]::new($bytes.Length - $start)
        [Array]::Copy($bytes, $start, $lineBytes, 0, $lineBytes.Length)
        $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $lineBytes -Context "event ledger byte offset $start"
        $rows.Add([pscustomobject][ordered]@{
            ordinal = $rows.Count
            start_offset = $start
            end_offset = $bytes.Length
            prefix_sha256 = Get-MorphospaceBlockedSupersessionSha256Slice -Bytes $bytes -Offset 0 -Count $start
            line_sha256 = Get-MorphospaceSha256Bytes -Bytes $lineBytes
            document = $document
        }) | Out-Null
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previousSequence = 0
    foreach ($row in $rows) {
        $event = $row.document
        if ([string]$event.schema -cnotin @('rusty.morphospace.workflow.iteration_event.v1', 'rusty.morphospace.workflow.iteration_event.v2')) {
            throw "Event '$([string]$event.event_id)' has an unsupported schema."
        }
        if (-not $ids.Add([string]$event.event_id)) { throw "Event '$([string]$event.event_id)' is duplicated." }
        if ([int]$event.sequence -le $previousSequence) { throw "Event '$([string]$event.event_id)' does not advance sequence." }
        $previousSequence = [int]$event.sequence
    }
    return [pscustomobject][ordered]@{ path = $path; bytes = $bytes; rows = @($rows.ToArray()) }
}

function Read-MorphospaceBlockedSupersessionJson {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -RequireLeaf
    $bytes = [IO.File]::ReadAllBytes($path)
    return [pscustomobject][ordered]@{
        path = $path
        relative_path = (ConvertTo-MorphospaceProtocolRelativePath -Path $RelativePath)
        bytes = $bytes
        sha256 = Get-MorphospaceSha256Bytes -Bytes $bytes
        document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context $Context
    }
}

function Assert-MorphospaceBlockedSupersessionHash {
    param([object]$Value, [string]$Context)
    if ([string]$Value -cnotmatch '^[0-9a-f]{64}$') { throw "$Context is not a lowercase SHA-256." }
}

function Assert-MorphospaceBlockedSupersessionEventEqual {
    param([object]$Expected, [object]$Actual, [string]$Context)
    $expectedHash = Get-MorphospaceCanonicalJsonSha256 -Value $Expected
    $actualHash = Get-MorphospaceCanonicalJsonSha256 -Value $Actual
    if ($expectedHash -cne $actualHash) { throw "$Context does not match the immutable event-ledger record." }
}

function Test-MorphospaceBlockedSupersessionProjectionDocument {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectionPath,
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $schemaName = switch ([string]$Document.schema) {
        'rusty.morphospace.workflow.feature_lock.v1' {
            if ($ProjectionPath -cne 'feature.lock.json') { throw "$Context uses a feature-lock schema on the wrong path." }
            'feature-lock.schema.json'
        }
        'rusty.morphospace.workflow.feature_lock.v2' {
            if ($ProjectionPath -cne 'feature.lock.json') { throw "$Context uses a feature-lock schema on the wrong path." }
            'feature-lock-v2.schema.json'
        }
        'rusty.morphospace.workflow.project_spec.v1' {
            if ($ProjectionPath -cne 'project.spec.json') { throw "$Context uses a project-spec schema on the wrong path." }
            'project-spec.schema.json'
        }
        'rusty.morphospace.workflow.project_spec.v2' {
            if ($ProjectionPath -cne 'project.spec.json') { throw "$Context uses a project-spec schema on the wrong path." }
            'project-spec-v2.schema.json'
        }
        default { throw "$Context uses an unsupported projection-document schema." }
    }
    if ([string]$Document.project_id -cne $ProjectId) { throw "$Context has a mismatched project identity." }
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $schemaPath = Join-Path $repositoryRoot "schemas\$schemaName"
    if (-not (Test-Json -Json ($Document | ConvertTo-Json -Depth 64) -SchemaFile $schemaPath)) {
        throw "$Context does not satisfy '$schemaName'."
    }
}

function Get-MorphospaceBlockedSupersessionArtifactTargetPath {
    param(
        [object]$Artifact,
        [string]$Context
    )
    Assert-MorphospaceExactPropertySet $Artifact @('bytes_base64', 'path', 'sha256') @() $Context
    $relative = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$Artifact.path)
    if ([string]$Artifact.path -cne $relative) { throw "$Context path is not canonical." }
    return $relative
}

function Test-MorphospaceBlockedSupersessionArtifact {
    param(
        [string]$WorkspaceRoot,
        [object]$Artifact,
        [string]$CanonicalPath,
        [string]$Context
    )
    Assert-MorphospaceExactPropertySet $Artifact @('bytes_base64', 'path', 'sha256') @() $Context
    if ([string]$Artifact.path -cne $CanonicalPath) { throw "$Context canonical target changed between validation passes." }
    Assert-MorphospaceBlockedSupersessionHash $Artifact.sha256 "$Context hash"
    $embedded = try { [Convert]::FromBase64String([string]$Artifact.bytes_base64) } catch { throw "$Context has invalid base64 bytes." }
    if ([Convert]::ToBase64String($embedded) -cne [string]$Artifact.bytes_base64) {
        throw "$Context base64 bytes are not canonical."
    }
    $embeddedHash = Get-MorphospaceSha256Bytes -Bytes $embedded
    if ($embeddedHash -cne [string]$Artifact.sha256) { throw "$Context embedded-byte hash drifted." }
    $livePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $CanonicalPath -RequireLeaf
    $liveBytes = [IO.File]::ReadAllBytes($livePath)
    if ((Get-MorphospaceSha256Bytes -Bytes $liveBytes) -cne $embeddedHash -or $liveBytes.Length -ne $embedded.Length) {
        throw "$Context live artifact bytes drifted."
    }
    return [pscustomobject][ordered]@{ path = $CanonicalPath; sha256 = $embeddedHash }
}

function Test-MorphospaceBlockedSupersessionRematerializationV6 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][object]$Transition,
        [Parameter(Mandatory = $true)][object]$PriorState,
        [Parameter(Mandatory = $true)][string]$PriorStateSha256,
        [Parameter(Mandatory = $true)][object]$PriorUnit,
        [Parameter(Mandatory = $true)][string]$PriorUnitSha256
    )
    $intent = $Transition.intent
    $event = $Transition.event
    $eventId = [string]$event.event_id
    $summary = 'Rematerialized only the exact source and candidate-freeze bindings of the current validating unit while invalidating its stale selector.'
    if ([string]$event.event_type -cne 'state-transition' -or [string]$event.summary -cne $summary -or
        [string]$event.project_id -cne $ProjectId -or [string]$event.unit_id -cne $UnitId) {
        throw "Transition intent v6 '$eventId' is not the exact validating-candidate rematerialization action."
    }

    $artifacts = @($intent.artifacts)
    $receipts = @($event.receipts)
    if ($artifacts.Count -ne 2 -or $receipts.Count -ne 2) {
        throw "Rematerialization v6 '$eventId' must bind exactly two artifacts and receipts."
    }
    $candidate = $null
    $candidateArtifact = $null
    $source = $null
    $sourceArtifact = $null
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    for ($index = 0; $index -lt 2; $index++) {
        $artifact = $artifacts[$index]
        if ([string]$receipts[$index] -cne [string]$artifact.path) {
            throw "Rematerialization v6 '$eventId' artifact/receipt order drifted."
        }
        $bytes = try { [Convert]::FromBase64String([string]$artifact.bytes_base64) } catch { throw "Rematerialization v6 '$eventId' artifact bytes are invalid." }
        $document = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context "rematerialization v6 '$eventId' artifact '$([string]$artifact.path)'"
        switch ([string]$document.schema) {
            'rusty.morphospace.workflow.candidate_freeze.v2' {
                if ($null -ne $candidate) { throw "Rematerialization v6 '$eventId' repeats its candidate-freeze artifact." }
                if (-not (Test-Json -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes)) -SchemaFile (Join-Path $repositoryRoot 'schemas\candidate-freeze-v2.schema.json'))) {
                    throw "Rematerialization v6 '$eventId' candidate-freeze artifact fails its owner schema."
                }
                $candidate = $document
                $candidateArtifact = $artifact
            }
            'rusty.morphospace.workflow.source_composition_lock.v1' {
                if ($null -ne $source) { throw "Rematerialization v6 '$eventId' repeats its source-composition artifact." }
                if (-not (Test-Json -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes)) -SchemaFile (Join-Path $repositoryRoot 'schemas\source-composition-lock.schema.json'))) {
                    throw "Rematerialization v6 '$eventId' source-composition artifact fails its owner schema."
                }
                $source = $document
                $sourceArtifact = $artifact
            }
            default { throw "Rematerialization v6 '$eventId' owns an unsupported artifact schema." }
        }
    }
    if ($null -eq $candidate -or $null -eq $source) { throw "Rematerialization v6 '$eventId' lacks its exact candidate/source artifact pair." }
    if ([StringComparer]::Ordinal.Compare([string]$artifacts[0].path, [string]$artifacts[1].path) -ge 0) {
        throw "Rematerialization v6 '$eventId' artifacts and receipts are not ordinal sorted."
    }

    $candidatePath = "receipts/$([string]$candidate.freeze_id).json"
    $sourcePath = "source-compositions/$([string]$source.lock_id).lock.json"
    if ([string]$candidateArtifact.path -cne $candidatePath -or [string]$sourceArtifact.path -cne $sourcePath -or
        [string]$candidate.project_id -cne $ProjectId -or [string]$candidate.unit_id -cne $UnitId -or
        [string]$source.project_id -cne $ProjectId -or [string]$source.unit_id -cne $UnitId -or
        $eventId -cne "$([string]$candidate.lineage.rematerialization_id)-recorded" -or
        [string]$candidate.source_composition.path -cne $sourcePath -or [string]$candidate.source_composition.sha256 -cne [string]$sourceArtifact.sha256 -or
        [string]$candidate.lineage.target_source_composition.path -cne $sourcePath -or [string]$candidate.lineage.target_source_composition.sha256 -cne [string]$sourceArtifact.sha256) {
        throw "Rematerialization v6 '$eventId' artifact identity or target-source binding drifted."
    }
    if ([string]$candidate.expected.state_sha256 -cne $PriorStateSha256 -or [string]$candidate.expected.unit_sha256 -cne $PriorUnitSha256 -or
        [string]$candidate.expected.state_raw_sha256 -cne [string]$intent.pre_state_raw.sha256 -or
        [string]$candidate.expected.unit_raw_sha256 -cne [string]$intent.pre_unit_raw.sha256 -or
        [string]$candidate.expected.events_sha256 -cne [string]$intent.expected.events_sha256 -or
        [int64]$candidate.expected.events_length -ne [int64]$intent.expected.events_length -or
        [string]$candidate.expected.event_tail_id -cne [string]$intent.expected.event_tail_id) {
        throw "Rematerialization v6 '$eventId' candidate preimage binding drifted."
    }
    if ([string]$candidate.expected.source_composition_path -cne [string]$candidate.lineage.predecessor_source_composition.path -or
        [string]$candidate.expected.source_composition_sha256 -cne [string]$candidate.lineage.predecessor_source_composition.sha256) {
        throw "Rematerialization v6 '$eventId' candidate predecessor-source binding drifted."
    }

    $projectionMap = @{}
    foreach ($projection in @($intent.additional_projections)) { $projectionMap[[string]$projection.path] = $projection }
    if ($projectionMap.Count -ne 2 -or -not $projectionMap.ContainsKey('feature.lock.json') -or -not $projectionMap.ContainsKey('project.spec.json')) {
        throw "Rematerialization v6 '$eventId' lacks its exact feature/project projection pair."
    }
    foreach ($binding in @(
        [pscustomobject]@{ path='feature.lock.json'; canonical=[string]$candidate.expected.feature_lock_sha256; raw=[string]$candidate.expected.feature_lock_raw_sha256 },
        [pscustomobject]@{ path='project.spec.json'; canonical=[string]$candidate.expected.project_sha256; raw=[string]$candidate.expected.project_raw_sha256 }
    )) {
        $projection = $projectionMap[[string]$binding.path]
        if ([string]$projection.pre_sha256 -cne [string]$binding.canonical -or [string]$projection.target_sha256 -cne [string]$binding.canonical -or
            [string]$projection.pre_raw_sha256 -cne [string]$binding.raw) {
            throw "Rematerialization v6 '$eventId' projection '$([string]$binding.path)' is not an unchanged canonical raw-bound preimage."
        }
    }

    if ([string]$PriorUnit.status -cne 'validating' -or [string]$Transition.unit_document.status -cne 'validating' -or
        [string]$PriorState.current_unit -cne $UnitId -or [string]$Transition.state_document.current_unit -cne $UnitId -or
        $null -eq $PriorState.normal_validation_selection -or $null -ne $Transition.state_document.normal_validation_selection) {
        throw "Rematerialization v6 '$eventId' does not preserve the validating captain while clearing exactly one stale selector."
    }
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $candidate.lineage.invalidated_normal_validation_selection) -cne
        (Get-MorphospaceCanonicalJsonSha256 -Value $PriorState.normal_validation_selection)) {
        throw "Rematerialization v6 '$eventId' candidate does not bind the invalidated selector preimage."
    }
    if ($null -eq $PriorUnit.candidate_freeze -or $null -eq $PriorUnit.source_composition -or
        (Get-MorphospaceCanonicalJsonSha256 -Value $candidate.lineage.predecessor_freeze) -cne (Get-MorphospaceCanonicalJsonSha256 -Value $PriorUnit.candidate_freeze) -or
        [string]$candidate.lineage.predecessor_source_composition.path -cne [string]$PriorUnit.source_composition.lock_path) {
        throw "Rematerialization v6 '$eventId' candidate does not bind the predecessor unit source/freeze markers."
    }
    $predecessorFreeze = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$candidate.lineage.predecessor_freeze.receipt_path) -Context "rematerialization v6 '$eventId' predecessor freeze"
    $predecessorSource = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$candidate.lineage.predecessor_source_composition.path) -Context "rematerialization v6 '$eventId' predecessor source"
    if ($predecessorFreeze.sha256 -cne [string]$candidate.lineage.predecessor_freeze.receipt_sha256 -or
        $predecessorSource.sha256 -cne [string]$candidate.lineage.predecessor_source_composition.sha256) {
        throw "Rematerialization v6 '$eventId' predecessor artifact bytes drifted."
    }
    $predecessorFreezeSchema = [string]$predecessorFreeze.document.schema
    if ($predecessorFreezeSchema -cnotin @('rusty.morphospace.workflow.candidate_freeze.v1','rusty.morphospace.workflow.candidate_freeze.v2')) {
        throw "Rematerialization v6 '$eventId' predecessor freeze has an unsupported schema."
    }
    $predecessorFreezeSchemaPath = if ($predecessorFreezeSchema -ceq 'rusty.morphospace.workflow.candidate_freeze.v2') { 'schemas\candidate-freeze-v2.schema.json' } else { 'schemas\candidate-freeze-v1.schema.json' }
    if (-not (Test-Json -Json ([Text.UTF8Encoding]::new($false,$true).GetString($predecessorFreeze.bytes)) -SchemaFile (Join-Path $repositoryRoot $predecessorFreezeSchemaPath))) {
        throw "Rematerialization v6 '$eventId' predecessor freeze fails its owner schema."
    }
    if ([string]$predecessorSource.document.schema -cnotin @('rusty.morphospace.workflow.source_composition_lock.v1','rusty.morphospace.workflow.development_envelope_source_composition.v1')) {
        throw "Rematerialization v6 '$eventId' predecessor source has an unsupported schema."
    }
    $predecessorSourceSchemaPath = if ([string]$predecessorSource.document.schema -ceq 'rusty.morphospace.workflow.source_composition_lock.v1') { 'schemas\source-composition-lock.schema.json' } else { 'schemas\development-envelope-source-composition-v1.schema.json' }
    if (-not (Test-Json -Json ([Text.UTF8Encoding]::new($false,$true).GetString($predecessorSource.bytes)) -SchemaFile (Join-Path $repositoryRoot $predecessorSourceSchemaPath))) {
        throw "Rematerialization v6 '$eventId' predecessor source fails its owner schema."
    }

    $restoredUnit = $Transition.unit_document | ConvertTo-Json -Depth 96 | ConvertFrom-Json -Depth 96 -DateKind String
    $restoredUnit.candidate_freeze = $PriorUnit.candidate_freeze
    $restoredUnit.source_composition = $PriorUnit.source_composition
    if ([string]$Transition.unit_document.candidate_freeze.freeze_id -cne [string]$candidate.freeze_id -or
        [string]$Transition.unit_document.candidate_freeze.receipt_path -cne $candidatePath -or
        [string]$Transition.unit_document.candidate_freeze.receipt_sha256 -cne [string]$candidateArtifact.sha256 -or
        [string]$Transition.unit_document.source_composition.mode -cne 'exact-lock' -or
        [string]$Transition.unit_document.source_composition.lock_path -cne $sourcePath -or
        $null -ne $Transition.unit_document.source_composition.materialization_receipt -or
        (Get-MorphospaceCanonicalJsonSha256 -Value $restoredUnit) -cne $PriorUnitSha256) {
        throw "Rematerialization v6 '$eventId' changed the unit outside exact source/freeze replacement."
    }

    $restoredState = $Transition.state_document | ConvertTo-Json -Depth 96 | ConvertFrom-Json -Depth 96 -DateKind String
    $restoredState.last_event_id = [string]$intent.expected.event_tail_id
    $restoredState.normal_validation_selection = $candidate.lineage.invalidated_normal_validation_selection
    $headProjectionMap = @{}
    foreach ($projection in @($candidate.lineage.repository_head_projections)) {
        $repoId = [string]$projection.repo_id
        if (-not $repoId -or $headProjectionMap.ContainsKey($repoId)) { throw "Rematerialization v6 '$eventId' repeats a repository-head projection." }
        $headProjectionMap[$repoId] = $projection
    }
    foreach ($head in @($restoredState.repository_heads)) {
        $repoId = [string]$head.repo_id
        if (-not $headProjectionMap.ContainsKey($repoId)) { continue }
        $projection = $headProjectionMap[$repoId]
        $targetHead = @($Transition.state_document.repository_heads | Where-Object { [string]$_.repo_id -ceq $repoId })
        if ($targetHead.Count -ne 1 -or
            (Get-MorphospaceCanonicalJsonSha256 -Value $targetHead[0]) -cne (Get-MorphospaceCanonicalJsonSha256 -Value ([pscustomobject][ordered]@{repo_id=$repoId;head=[string]$projection.target.head;branch=$projection.target.branch;dirty_fingerprint=$projection.target.dirty_fingerprint}))) {
            throw "Rematerialization v6 '$eventId' target repository-head projection '$repoId' drifted."
        }
        $head.head = [string]$projection.predecessor.head
        $head.branch = $projection.predecessor.branch
        $head.dirty_fingerprint = $projection.predecessor.dirty_fingerprint
        [void]$headProjectionMap.Remove($repoId)
    }
    if ($headProjectionMap.Count -ne 0 -or (Get-MorphospaceCanonicalJsonSha256 -Value $restoredState) -cne $PriorStateSha256) {
        throw "Rematerialization v6 '$eventId' changed state outside event tail, selector invalidation, and exact repository-head projection."
    }
}

function Test-MorphospaceBlockedSupersessionTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][object]$Row,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [string]$ExpectedPreStateSha256 = '',
        [string]$ExpectedPreUnitSha256 = '',
        [string]$ExpectedTargetUnitId = '',
        [ValidateSet(
            'rusty.morphospace.workflow.transition_ledger_intent.v1',
            'rusty.morphospace.workflow.transition_ledger_intent.v2',
            'rusty.morphospace.workflow.transition_ledger_intent.v3',
            'rusty.morphospace.workflow.transition_ledger_intent.v4',
            'rusty.morphospace.workflow.transition_ledger_intent.v5',
            'rusty.morphospace.workflow.transition_ledger_intent.v6'
        )][string]$ExpectedIntentSchema = 'rusty.morphospace.workflow.transition_ledger_intent.v1'
    )

    $event = $Row.document
    $eventId = [string]$event.event_id
    $transactionId = "$eventId-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"
    $intentFile = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath $intentRelative -Context "transition intent '$eventId'"
    $completionFile = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath $completionRelative -Context "transition completion '$eventId'"
    $intent = $intentFile.document
    $completion = $completionFile.document

    $intentProperties = @('artifacts','created_at','event','events','expected','pre','schema','state','status','target','transaction_id','unit')
    $isProjectionIntent = $ExpectedIntentSchema -cin @(
        'rusty.morphospace.workflow.transition_ledger_intent.v3',
        'rusty.morphospace.workflow.transition_ledger_intent.v4',
        'rusty.morphospace.workflow.transition_ledger_intent.v6'
    )
    $isRawArtifactIntent = $ExpectedIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v5'
    $isRawPreimageProjectionIntent = $ExpectedIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v6'
    $projectionIntentVersion = if ($isRawPreimageProjectionIntent) { 'v6' } elseif ($ExpectedIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v4') { 'v4' } else { 'v3' }
    if ($ExpectedIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2') {
        $intentProperties += 'supersession'
    } elseif ($isRawPreimageProjectionIntent) {
        $intentProperties += @('pre_state_raw','pre_unit_raw','additional_projections')
    } elseif ($ExpectedIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v4') {
        $intentProperties += @('pre_unit_raw','additional_projections')
    } elseif ($isRawArtifactIntent) {
        $intentProperties += 'pre_unit_raw'
    } elseif ($isProjectionIntent) {
        $intentProperties += 'additional_projections'
    }
    Assert-MorphospaceExactPropertySet $intent $intentProperties @() "transition intent '$eventId'"
    if ([string]$intent.schema -cne $ExpectedIntentSchema -or [string]$intent.status -cne 'prepared') {
        throw "Transition intent '$eventId' is not the expected prepared owner transaction."
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))
    if ([string]$intent.transaction_id -cne $transactionId) { throw "Transition intent '$eventId' has a mismatched transaction ID." }
    Assert-MorphospaceExactPropertySet $intent.events @('path') @() "transition intent '$eventId' events reference"
    Assert-MorphospaceExactPropertySet $intent.state @('path') @() "transition intent '$eventId' state reference"
    Assert-MorphospaceExactPropertySet $intent.unit @('path') @() "transition intent '$eventId' unit reference"
    if ([string]$intent.events.path -cne 'iteration-events.jsonl' -or [string]$intent.state.path -cne 'workspace.state.json') {
        throw "Transition intent '$eventId' does not target the canonical state and ledger paths."
    }
    $eventUnitId = [string]$event.unit_id
    $targetUnitId = if ($ExpectedTargetUnitId) { $ExpectedTargetUnitId } else { $eventUnitId }
    if (-not $eventUnitId -or -not $targetUnitId -or [string]$intent.unit.path -cne "iteration-units/$targetUnitId.json") {
        throw "Transition intent '$eventId' does not target its exact unit path."
    }
    if ($ExpectedIntentSchema -cin @('rusty.morphospace.workflow.transition_ledger_intent.v4','rusty.morphospace.workflow.transition_ledger_intent.v5','rusty.morphospace.workflow.transition_ledger_intent.v6')) {
        $rawIntentVersion = if ($isRawArtifactIntent) { 'v5' } elseif ($isRawPreimageProjectionIntent) { 'v6' } else { 'v4' }
        Assert-MorphospaceExactPropertySet $intent.pre_unit_raw @('path','sha256') @() "transition intent $rawIntentVersion '$eventId' raw pre-unit binding"
        $rawUnitPath = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$intent.pre_unit_raw.path)
        if ([string]$intent.pre_unit_raw.path -cne $rawUnitPath -or
            $rawUnitPath -cne [string]$intent.unit.path -or
            [string]$intent.pre_unit_raw.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Transition intent $rawIntentVersion '$eventId' raw pre-unit binding is malformed or detached."
        }
    }
    if ($isRawPreimageProjectionIntent) {
        Assert-MorphospaceExactPropertySet $intent.pre_state_raw @('path','sha256') @() "transition intent v6 '$eventId' raw pre-state binding"
        $rawStatePath = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$intent.pre_state_raw.path)
        if ([string]$intent.pre_state_raw.path -cne $rawStatePath -or
            $rawStatePath -cne [string]$intent.state.path -or
            [string]$intent.pre_state_raw.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Transition intent v6 '$eventId' raw pre-state binding is malformed or detached."
        }
    }

    Assert-MorphospaceExactPropertySet $intent.expected @('event_tail_id','events_length','events_sha256','state_sha256','unit_sha256') @() "transition intent '$eventId' expected preimage"
    Assert-MorphospaceExactPropertySet $intent.pre @('state','unit') @() "transition intent '$eventId' preimage"
    Assert-MorphospaceExactPropertySet $intent.pre.state @('sha256') @() "transition intent '$eventId' pre-state"
    Assert-MorphospaceExactPropertySet $intent.pre.unit @('sha256') @() "transition intent '$eventId' pre-unit"
    foreach ($hash in @($intent.expected.events_sha256, $intent.expected.state_sha256, $intent.expected.unit_sha256, $intent.pre.state.sha256, $intent.pre.unit.sha256)) {
        Assert-MorphospaceBlockedSupersessionHash $hash "Transition intent '$eventId' preimage hash"
    }
    if ([int64]$intent.expected.events_length -ne [int64]$Row.start_offset -or [string]$intent.expected.events_sha256 -cne [string]$Row.prefix_sha256) {
        throw "Transition intent '$eventId' does not bind the exact ledger prefix before its event."
    }
    $previousEventId = if ([int]$Row.ordinal -eq 0) { $null } else { [string]$Ledger.rows[[int]$Row.ordinal - 1].document.event_id }
    if ([string]$intent.expected.event_tail_id -cne [string]$previousEventId) { throw "Transition intent '$eventId' has a mismatched predecessor event." }
    if ([string]$intent.expected.state_sha256 -cne [string]$intent.pre.state.sha256 -or [string]$intent.expected.unit_sha256 -cne [string]$intent.pre.unit.sha256) {
        throw "Transition intent '$eventId' expected and preimage hashes disagree."
    }
    if ($ExpectedPreStateSha256 -and [string]$intent.pre.state.sha256 -cne $ExpectedPreStateSha256) {
        throw "Transition intent '$eventId' is detached from the preceding state target."
    }
    if ($ExpectedPreUnitSha256 -and [string]$intent.pre.unit.sha256 -cne $ExpectedPreUnitSha256) {
        throw "Transition intent '$eventId' is detached from the preceding unit target."
    }
    Assert-MorphospaceBlockedSupersessionEventEqual -Expected $intent.event -Actual $event -Context "Transition intent '$eventId' event"
    if ([string]$intent.event.project_id -cne $ProjectId -or [string]$intent.event.unit_id -cne $eventUnitId) {
        throw "Transition intent '$eventId' project or unit identity drifted."
    }

    Assert-MorphospaceExactPropertySet $intent.target @('state','unit') @() "transition intent '$eventId' target"
    foreach ($targetName in @('state','unit')) {
        $target = $intent.target.$targetName
        Assert-MorphospaceExactPropertySet $target @('document','sha256') @() "transition intent '$eventId' target $targetName"
        Assert-MorphospaceBlockedSupersessionHash $target.sha256 "Transition intent '$eventId' target $targetName hash"
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $target.document) -cne [string]$target.sha256) {
            throw "Transition intent '$eventId' target $targetName document hash drifted."
        }
    }
    if ([string]$intent.target.state.document.project_id -cne $ProjectId -or
        [string]$intent.target.unit.document.project_id -cne $ProjectId -or
        [string]$intent.target.unit.document.unit_id -cne $targetUnitId -or
        [string]$intent.target.state.document.last_event_id -cne $eventId) {
        throw "Transition intent '$eventId' target identity or event projection drifted."
    }
    if ($ExpectedIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2') {
        $delimiter = '-superseded-by-'
        $oldUnitId = $eventUnitId
        if ($eventId -cne "$oldUnitId$delimiter$targetUnitId" -or
            [string]$event.event_type -cne 'state-transition' -or
            @($event.receipts).Count -notin @(0,1)) {
            throw "Supersession transaction '$eventId' does not carry the exact old-to-replacement event."
        }
        $binding = $intent.supersession
        Assert-MorphospaceExactPropertySet $binding @('new_unit_id','old_unit','old_unit_id','pre_state','target_unit_path') @() "supersession binding '$eventId'"
        Assert-MorphospaceExactPropertySet $binding.pre_state @('document','path','sha256') @() "supersession pre-state binding '$eventId'"
        Assert-MorphospaceExactPropertySet $binding.old_unit @('document','path','sha256') @() "supersession old-unit binding '$eventId'"
        $oldUnitPath = "iteration-units/$oldUnitId.json"
        $targetUnitPath = "iteration-units/$targetUnitId.json"
        if ([string]$binding.old_unit_id -cne $oldUnitId -or
            [string]$binding.new_unit_id -cne $targetUnitId -or
            [string]$binding.pre_state.path -cne 'workspace.state.json' -or
            [string]$binding.old_unit.path -cne $oldUnitPath -or
            [string]$binding.target_unit_path -cne $targetUnitPath) {
            throw "Supersession transaction '$eventId' has detached paths or endpoint identities."
        }
        foreach ($hash in @($binding.pre_state.sha256, $binding.old_unit.sha256)) {
            Assert-MorphospaceBlockedSupersessionHash $hash "Supersession transaction '$eventId' binding hash"
        }
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $binding.pre_state.document) -cne [string]$binding.pre_state.sha256 -or
            [string]$binding.pre_state.sha256 -cne [string]$intent.pre.state.sha256 -or
            [string]$binding.pre_state.document.project_id -cne $ProjectId -or
            [string]$binding.pre_state.document.current_unit -cne $oldUnitId -or
            (@($event.receipts).Count -eq 0 -and [string]$binding.pre_state.document.next_ready_unit -cne $targetUnitId) -or
            [string]$binding.pre_state.document.last_event_id -cne [string]$intent.expected.event_tail_id) {
            throw "Supersession transaction '$eventId' has an invalid authenticated pre-state."
        }
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $binding.old_unit.document) -cne [string]$binding.old_unit.sha256 -or
            [string]$binding.old_unit.document.project_id -cne $ProjectId -or
            [string]$binding.old_unit.document.unit_id -cne $oldUnitId -or
            [string]$binding.old_unit.document.status -cnotin @('active','validating')) {
            throw "Supersession transaction '$eventId' has an invalid authenticated old unit."
        }
        $liveOldUnit = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath $oldUnitPath -Context "superseded unit '$oldUnitId'"
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $liveOldUnit.document) -cne [string]$binding.old_unit.sha256) {
            throw "Supersession transaction '$eventId' old-unit bytes no longer match the immutable binding."
        }
        if ([string]$intent.target.state.document.current_unit -cne $targetUnitId -or
            $null -ne $intent.target.state.document.next_ready_unit -or
            [string]$intent.target.unit.document.status -cne 'active' -or
            [string]$intent.target.state.document.last_accepted_receipt -cne [string]$binding.pre_state.document.last_accepted_receipt) {
            throw "Supersession transaction '$eventId' target is not the exact non-accepting current replacement projection."
        }
        if (@($event.receipts).Count -eq 1) {
            Assert-MorphospaceReceiptBearingSupersession -WorkspaceRoot $WorkspaceRoot -Intent $intent -EventId $eventId -ProjectId $ProjectId -OldUnitId $oldUnitId -ReplacementUnitId $targetUnitId
        } else {
            $readyReplacement = $intent.target.unit.document | ConvertTo-Json -Depth 64 | ConvertFrom-Json
            $readyReplacement.status = 'ready'
            if ((Get-MorphospaceCanonicalJsonSha256 -Value $readyReplacement) -cne [string]$intent.pre.unit.sha256) {
                throw "Supersession transaction '$eventId' pre-unit hash is not the exact ready form of its active replacement target."
            }
        }
    } elseif ($isProjectionIntent) {
        if ($eventId.Contains('-superseded-by-', [StringComparison]::Ordinal)) {
            throw "Transition intent $projectionIntentVersion '$eventId' may not authenticate a supersession."
        }
        $projections = @($intent.additional_projections)
        if ($projections.Count -lt 1 -or $projections.Count -gt 2) {
            throw "Transition intent $projectionIntentVersion '$eventId' must bind one or two additional projections."
        }
        $projectionPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $previousProjectionPath = $null
        foreach ($projection in $projections) {
            $projectionProperties = if ($isRawPreimageProjectionIntent) { @('document','path','pre_raw_sha256','pre_sha256','target_sha256') } else { @('document','path','pre_sha256','target_sha256') }
            Assert-MorphospaceExactPropertySet $projection $projectionProperties @() "transition intent '$eventId' additional projection"
            $projectionPath = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$projection.path)
            if ([string]$projection.path -cne $projectionPath -or -not $projectionPaths.Add($projectionPath)) {
                throw "Transition intent $projectionIntentVersion '$eventId' repeats or mis-canonicalizes an additional projection path."
            }
            if ($projectionPath -cnotin @('feature.lock.json','project.spec.json')) {
                throw "Transition intent $projectionIntentVersion '$eventId' does not authorize additional projection '$projectionPath'."
            }
            if ($null -ne $previousProjectionPath -and [StringComparer]::Ordinal.Compare([string]$previousProjectionPath, $projectionPath) -ge 0) {
                throw "Transition intent $projectionIntentVersion '$eventId' additional projections are not in canonical path order."
            }
            $previousProjectionPath = $projectionPath
            Assert-MorphospaceBlockedSupersessionHash $projection.pre_sha256 "Transition intent $projectionIntentVersion '$eventId' projection preimage"
            if ($isRawPreimageProjectionIntent) {
                Assert-MorphospaceBlockedSupersessionHash $projection.pre_raw_sha256 "Transition intent v6 '$eventId' projection raw preimage"
            }
            Assert-MorphospaceBlockedSupersessionHash $projection.target_sha256 "Transition intent $projectionIntentVersion '$eventId' projection target"
            if ((Get-MorphospaceCanonicalJsonSha256 -Value $projection.document) -cne [string]$projection.target_sha256) {
                throw "Transition intent $projectionIntentVersion '$eventId' projection '$projectionPath' target document hash drifted."
            }
            Test-MorphospaceBlockedSupersessionProjectionDocument -ProjectionPath $projectionPath -Document $projection.document -ProjectId $ProjectId -Context "Transition intent $projectionIntentVersion '$eventId' projection '$projectionPath'"
        }
    }
    $artifactPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $artifactRecords = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @($intent.artifacts)) {
        $context = "transition intent '$eventId' artifact"
        $artifactPath = Get-MorphospaceBlockedSupersessionArtifactTargetPath -Artifact $artifact -Context $context
        if (-not $artifactPaths.Add($artifactPath)) {
            throw "Transition intent '$eventId' repeats an artifact target path."
        }
        $artifactRecords.Add([pscustomobject][ordered]@{ artifact = $artifact; path = $artifactPath; context = $context }) | Out-Null
    }
    foreach ($record in $artifactRecords) {
        [void](Test-MorphospaceBlockedSupersessionArtifact `
            -WorkspaceRoot $WorkspaceRoot `
            -Artifact $record.artifact `
            -CanonicalPath ([string]$record.path) `
            -Context ([string]$record.context))
    }
    if ($isRawArtifactIntent) {
        $eventUnitId = [string]$event.unit_id
        if ($eventId.Contains('-superseded-by-', [StringComparison]::Ordinal)) {
            throw "Transition intent v5 '$eventId' may not authenticate a supersession identity."
        }
        if ($eventUnitId -and $eventId -cmatch ('^' + [regex]::Escape("$eventUnitId-proposal-retired-") + '[0-9]{4}$')) {
            throw "Transition intent v5 '$eventId' may not replace proposed-unit retirement v1 receipt binding."
        }
        if ([string]$intent.pre.unit.sha256 -cne [string]$intent.target.unit.sha256) {
            throw "Transition intent v5 '$eventId' changed the canonical unit projection."
        }
        if ($artifactRecords.Count -lt 1 -or $artifactRecords.Count -gt 2 -or @($event.receipts).Count -ne $artifactRecords.Count) {
            throw "Transition intent v5 '$eventId' must bind one or two exact event artifacts."
        }
        $previousArtifactPath = $null
        for ($artifactIndex = 0; $artifactIndex -lt $artifactRecords.Count; $artifactIndex++) {
            $artifactPath = [string]$artifactRecords[$artifactIndex].path
            if (($null -ne $previousArtifactPath -and [StringComparer]::Ordinal.Compare([string]$previousArtifactPath, $artifactPath) -ge 0) -or
                @($event.receipts)[$artifactIndex] -isnot [string] -or [string]@($event.receipts)[$artifactIndex] -cne $artifactPath) {
                throw "Transition intent v5 '$eventId' artifacts and event receipts are not exact and ordinal sorted."
            }
            $previousArtifactPath = $artifactPath
        }
    }
    if ($isProjectionIntent) {
        $eventReceiptPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($receipt in @($event.receipts)) {
            if ($receipt -isnot [string]) { throw "Transition intent $projectionIntentVersion '$eventId' event receipt is not a canonical path string." }
            $receiptPath = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$receipt)
            if ([string]$receipt -cne $receiptPath -or -not $eventReceiptPaths.Add($receiptPath)) {
                throw "Transition intent $projectionIntentVersion '$eventId' repeats or mis-canonicalizes an event receipt path."
            }
        }
        if ($eventReceiptPaths.Count -ne $artifactPaths.Count) {
            throw "Transition intent $projectionIntentVersion '$eventId' event receipts do not exactly match its artifact targets."
        }
        foreach ($receiptPath in $eventReceiptPaths) {
            if (-not $artifactPaths.Contains($receiptPath)) {
                throw "Transition intent $projectionIntentVersion '$eventId' event receipt '$receiptPath' is not bound as an exact artifact target."
            }
        }
    }

    Assert-MorphospaceExactPropertySet $completion @('completed_at','event_id','intent','schema','state_sha256','status','transaction_id','unit_sha256') @() "transition completion '$eventId'"
    if ([string]$completion.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or [string]$completion.status -cne 'committed') {
        throw "Transition completion '$eventId' is not committed v1 evidence."
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at))
    if ([string]$completion.event_id -cne $eventId -or [string]$completion.transaction_id -cne $transactionId) {
        throw "Transition completion '$eventId' identity drifted."
    }
    Assert-MorphospaceExactPropertySet $completion.intent @('path','role','schema','sha256') @() "transition completion '$eventId' intent reference"
    if ([string]$completion.intent.path -cne $intentRelative -or
        [string]$completion.intent.role -cne 'transition-ledger-intent' -or
        [string]$completion.intent.schema -cne [string]$intent.schema -or
        [string]$completion.intent.sha256 -cne [string]$intentFile.sha256) {
        throw "Transition completion '$eventId' does not bind its exact intent bytes."
    }
    if ([string]$completion.state_sha256 -cne [string]$intent.target.state.sha256 -or
        [string]$completion.unit_sha256 -cne [string]$intent.target.unit.sha256) {
        throw "Transition completion '$eventId' does not bind its target state and unit."
    }
    return [pscustomobject][ordered]@{
        event = $event
        intent = $intent
        intent_sha256 = $intentFile.sha256
        completion = $completion
        state_document = $intent.target.state.document
        state_sha256 = [string]$intent.target.state.sha256
        unit_document = $intent.target.unit.document
        unit_sha256 = [string]$intent.target.unit.sha256
        additional_projections = @($(if ($isProjectionIntent) { $intent.additional_projections } else { @() }))
    }
}

function Test-MorphospaceBlockedSupersessionValidationReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [ValidateSet('partial','fail','blocked')][string]$ExpectedResult = 'fail'
    )
    $file = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -Context "blocked supersession validation receipt '$UnitId'"
    $schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) '..\schemas\validation-receipt.schema.json'
    $json = [Text.UTF8Encoding]::new($false, $true).GetString($file.bytes)
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath)) { throw "Validation receipt '$RelativePath' fails its owner schema." }
    $receipt = $file.document
    if ([string]$receipt.schema -cne 'rusty.morphospace.workflow.validation_receipt.v1' -or
        [string]$receipt.project_id -cne $ProjectId -or
        [string]$receipt.unit_id -cne $UnitId -or
        [string]$receipt.result -cne $ExpectedResult) {
        throw "Validation receipt '$RelativePath' is not an exact same-unit $ExpectedResult result."
    }
    return $receipt
}

# Closed ordinary-producer conformance with no caller authenticity callback.
function ConvertTo-MorphospaceTerminalSupersessionSourcePath {
    param([string]$Path)
    $value=$Path.Replace('\','/').Trim()
    if(-not$value-or[IO.Path]::IsPathRooted($value)-or$value-cmatch'(^|/)\.\.(/|$)'-or$value-cmatch'(^|/)\.(/|$)'-or$value.Contains('//',[StringComparison]::Ordinal)){
        throw 'Receipt-bearing supersession source scope has a noncanonical path.'
    }
    return $value
}

function Assert-MorphospaceTerminalSupersessionNoSourceWidening {
    param([object]$OldUnit,[object]$ReplacementUnit)
    $oldMap=@{}
    foreach($repo in @($OldUnit.allowed_repositories)){
        $id=[string]$repo.repo_id
        if($oldMap.ContainsKey($id)){throw 'Receipt-bearing supersession source scope repeats an old repository.'}
        $oldMap[$id]=@($repo.allowed_paths)
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($repo in @($ReplacementUnit.allowed_repositories)){
        $id=[string]$repo.repo_id
        if(-not$seen.Add($id)){throw 'Receipt-bearing supersession source scope repeats a replacement repository.'}
        if(-not$oldMap.ContainsKey($id)){throw 'Receipt-bearing supersession source scope widens repository authority.'}
        foreach($path in @($repo.allowed_paths)){
            $candidate=ConvertTo-MorphospaceTerminalSupersessionSourcePath ([string]$path)
            $contained=$false
            foreach($oldPath in @($oldMap[$id])){
                $allowed=(ConvertTo-MorphospaceTerminalSupersessionSourcePath ([string]$oldPath)).TrimEnd('/')
                if($candidate.Equals($allowed,[StringComparison]::Ordinal)-or$candidate.StartsWith($allowed+'/',[StringComparison]::Ordinal)){$contained=$true;break}
            }
            if(-not$contained){throw 'Receipt-bearing supersession source scope widens path authority.'}
        }
    }
}

function Assert-MorphospaceReceiptBearingSupersession {
    param([string]$WorkspaceRoot,[object]$Intent,[string]$EventId,[string]$ProjectId,[string]$OldUnitId,[string]$ReplacementUnitId)
    if (@($Intent.event.receipts).Count -ne 1 -or @($Intent.artifacts).Count -ne 1 -or
        [string]$Intent.event.receipts[0] -cne [string]$Intent.artifacts[0].path) {
        throw 'Receipt-bearing supersession requires exactly one owned receipt artifact.'
    }
    $bytes=[Convert]::FromBase64String([string]$Intent.artifacts[0].bytes_base64)
    if((Get-MorphospaceSha256Bytes $bytes)-cne[string]$Intent.artifacts[0].sha256){throw 'Receipt-bearing supersession artifact hash differs.'}
    $receipt=ConvertFrom-MorphospaceProtocolJsonBytes $bytes
    if([string]$Intent.artifacts[0].path-cnotmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'-or
        [string]$receipt.audit_receipt.path-cnotmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'-or
        [string]$Intent.event.summary-cne'Superseded the exact active unit with one reviewed proposed replacement while preserving the old unit and all acceptance evidence.'){
        throw 'Receipt-bearing supersession requires exact owner namespace and event semantics.'
    }
    if([string]$receipt.schema-cne'rusty.morphospace.workflow.work_unit_automation_receipt.v2'-or
        [string]$receipt.action-cne'SupersedeActive'-or$receipt.executed-ne$true-or
        [string]$receipt.project_id-cne$ProjectId-or[string]$receipt.unit_id-cne$ReplacementUnitId-or
        [string]$receipt.event_id-cne$EventId){throw 'Receipt-bearing supersession requires exact executed SupersedeActive output.'}
    $requestFile=Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$receipt.audit_receipt.path) -Context 'SupersedeActive archived request'
    if([string]$receipt.audit_receipt.sha256-cne[string]$requestFile.sha256){throw 'Receipt-bearing supersession request raw binding differs.'}
    $ownerRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if(-not(Test-Json -Json ([Text.UTF8Encoding]::new($false,$true).GetString($requestFile.bytes)) -SchemaFile (Join-Path $ownerRoot 'schemas/active-unit-supersession-v1.schema.json'))){throw 'Receipt-bearing supersession request schema differs.'}
    $request=$requestFile.document
    if([string]$request.supersession_id-cne$EventId-or[string]$request.project_id-cne$ProjectId-or
        [string]$request.old_unit.status-cne'active'-or[string]$request.replacement_unit.status-cne'proposed'-or
        [string]$request.old_unit.unit_id-cne$OldUnitId-or[string]$request.replacement_unit.unit_id-cne$ReplacementUnitId-or
        [string]$request.old_unit.path-cne"iteration-units/$OldUnitId.json"-or
        [string]$request.replacement_unit.path-cne"iteration-units/$ReplacementUnitId.json"){
        throw 'Receipt-bearing supersession request endpoints differ.'
    }
    $oldFile=Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$request.old_unit.path) -Context 'SupersedeActive immutable predecessor'
    if([string]$oldFile.sha256-cne[string]$request.old_unit.raw_sha256-or
        (Get-MorphospaceCanonicalJsonSha256 $oldFile.document)-cne[string]$request.old_unit.canonical_sha256-or
        [string]$oldFile.document.status-cne'active') {throw 'Receipt-bearing supersession immutable predecessor differs.'}
    if([string]$Intent.supersession.pre_state.document.current_unit-cne$OldUnitId-or
        ($null-ne$Intent.supersession.pre_state.document.next_ready_unit-and
         [string]$Intent.supersession.pre_state.document.next_ready_unit-cne$ReplacementUnitId)){
        throw 'Receipt-bearing supersession predecessor captain/readiness differs.'
    }
    # Historical producer conformance; no producer import or live re-observation.
    if([string]$request.expected.state_canonical_sha256-cne[string]$Intent.pre.state.sha256-or
        [string]$request.replacement_unit.canonical_sha256-cne[string]$Intent.pre.unit.sha256-or
        [string]$request.old_unit.canonical_sha256-cne[string]$Intent.supersession.old_unit.sha256-or
        [string]$request.expected.events_sha256-cne[string]$Intent.expected.events_sha256-or
        [int64]$request.expected.events_length-ne[int64]$Intent.expected.events_length-or
        [string]$request.expected.event_tail_id-cne[string]$Intent.expected.event_tail_id){
        throw 'Receipt-bearing supersession preimage differs from the reviewed request.'
    }
    $preReplacement=$Intent.target.unit.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $preReplacement.status='proposed'
    if((Get-MorphospaceCanonicalJsonSha256 $preReplacement)-cne[string]$request.replacement_unit.canonical_sha256){
        throw 'Receipt-bearing supersession target is not the exact proposed-to-active projection.'
    }
    Assert-MorphospaceTerminalSupersessionNoSourceWidening $oldFile.document $preReplacement
    $targetState=$Intent.supersession.pre_state.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $targetState.current_unit=$ReplacementUnitId;$targetState.next_ready_unit=$null;$targetState.last_event_id=$EventId
    if((Get-MorphospaceCanonicalJsonSha256 $targetState)-cne[string]$Intent.target.state.sha256){throw 'Receipt-bearing supersession target state differs from its exact owner transform.'}
    $expectedReceipt=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id=$ProjectId;unit_id=$ReplacementUnitId;action='SupersedeActive'
        timestamp=[string]$Intent.event.timestamp;executed=$true
        transition='active-superseded-by-proposed-to-active';status_before='proposed';status_after='active'
        current_unit_before=$OldUnitId;current_unit_after=$ReplacementUnitId
        preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt=[pscustomobject][ordered]@{path=[string]$receipt.audit_receipt.path;sha256=[string]$requestFile.sha256}
        event_id=$EventId
    }
    if((Get-MorphospaceCanonicalJsonSha256 $receipt)-cne(Get-MorphospaceCanonicalJsonSha256 $expectedReceipt)){throw 'Receipt-bearing supersession output differs from its exact producer result.'}
}

function Assert-MorphospaceTerminalOrdinaryState {
    param([string]$WorkspaceRoot,[object]$ExpectedState,[object]$TargetState)
    # These slots are observations refreshed by ordinary owner actions; neither supplies
    # lifecycle/source/validation authority. The entire target remains ledger/hash-bound.
    $schemaName = switch ([string]$TargetState.schema) {
        'rusty.morphospace.workflow.workspace_state.v1' { 'workspace-state.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v2' { 'workspace-state-v2.schema.json' }
        default { throw 'Pre-validation ordinary state uses an unsupported schema.' }
    }
    $ownerRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if(-not(Test-Json -Json ($TargetState|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $ownerRoot "schemas/$schemaName"))){throw 'Pre-validation ordinary state schema differs.'}
    $projectFile=Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $WorkspaceRoot -RelativePath 'project.spec.json' -Context 'ordinary state observation repository identities'
    if([string]$projectFile.document.project_id-cne[string]$TargetState.project_id){throw 'Pre-validation observation project identity differs.'}
    $declared=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($repo in @($projectFile.document.repositories)){[void]$declared.Add([string]$repo.repo_id)}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($id in @($TargetState.dirty_repositories)){
        if(-not$declared.Contains([string]$id)-or-not$seen.Add([string]$id)){throw 'Pre-validation dirty observation has an undeclared or repeated repository.'}
    }
    if([string]$TargetState.schema-ceq'rusty.morphospace.workflow.workspace_state.v2'){
        $seen.Clear()
        foreach($head in @($TargetState.repository_heads)){
            if(-not$declared.Contains([string]$head.repo_id)-or-not$seen.Add([string]$head.repo_id)){throw 'Pre-validation head observation has an undeclared or repeated repository.'}
        }
    }
    $expected=$ExpectedState|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $expected.dirty_repositories=@($TargetState.dirty_repositories)
    if([string]$expected.schema-ceq'rusty.morphospace.workflow.workspace_state.v2'){$expected.repository_heads=@($TargetState.repository_heads)}
    if((Get-MorphospaceCanonicalJsonSha256 $expected)-cne(Get-MorphospaceCanonicalJsonSha256 $TargetState)){
        throw 'Pre-validation ordinary transition changes authority-bearing state beyond its producer transform.'
    }
}

function Assert-MorphospaceTerminalInstructionCompletion {
    param([string]$WorkspaceRoot,[object]$BeforeUnit,[object]$BeforeState,[object]$Transition,[object]$Event)
    if([string]$Transition.intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or
        @($Transition.intent.artifacts).Count-ne1-or@($Event.receipts).Count-ne1-or
        [string]$Event.receipts[0]-cne[string]$Transition.intent.artifacts[0].path){
        throw 'Pre-validation continuation requires exact ordinary instruction completion.'
    }
    $after=$Transition.unit_document
    if((Get-MorphospaceCanonicalJsonSha256 $BeforeUnit.instruction_surfaces)-ceq(Get-MorphospaceCanonicalJsonSha256 $after.instruction_surfaces)-or
        [string]$BeforeUnit.status-cne'active'-or[string]$after.status-cne'active'){
        throw 'Pre-validation instruction completion must complete actual planned surfaces without status change.'
    }
    $unit=$BeforeUnit|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $planned=@($unit.instruction_surfaces|Where-Object {[string]$_.status-ceq'planned'})
    if($planned.Count-eq0){throw 'Pre-validation instruction completion has no planned surface.'}
    foreach($surface in @($unit.instruction_surfaces)){
        if([string]$surface.status-ceq'planned'){$surface.status='complete'}
        elseif([string]$surface.status-cne'complete'){throw 'Pre-validation instruction completion has an unsupported surface status.'}
    }
    if((Get-MorphospaceCanonicalJsonSha256 $unit)-cne[string]$Transition.unit_sha256){throw 'Pre-validation instruction completion changes retained authority/objective or surface identities.'}
    $artifact=$Transition.intent.artifacts[0]
    $receipt=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$artifact.bytes_base64))
    $ownerRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if(-not(Test-Json -Json ($receipt|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $ownerRoot 'schemas/work-unit-automation-receipt.schema.json') -ErrorAction SilentlyContinue)){throw 'Pre-validation instruction-completion receipt schema differs.'}
    $binding=$receipt.instruction_surface_completion
    if([string]$receipt.action-cne'CompleteInstructionSurfaces'-or$receipt.executed-ne$true-or
        [string]$receipt.transition-cne'planned-instruction-surfaces-to-complete'-or
        [string]$receipt.unit_id-cne[string]$Event.unit_id-or[string]$receipt.project_id-cne[string]$Event.project_id-or
        [string]$receipt.event_id-cne[string]$Event.event_id-or[string]$Event.event_id-cne"$([string]$binding.completion_id)-recorded"-or
        [string]$Event.event_type-cne'state-transition'-or
        [string]$Event.summary-cne'Completed the exact declared instruction-surface set after stable content observation without executing validation commands.'-or
        $binding.all_planned_surfaces_completed-ne$true-or$binding.surface_files_observed_stable-ne$true-or$binding.validation_commands_executed-ne$false-or
        [string]$binding.expected_unit_sha256-cne[string]$Transition.intent.pre.unit.sha256-or[string]$binding.resulting_unit_sha256-cne[string]$Transition.intent.target.unit.sha256){
        throw 'Pre-validation instruction-completion receipt is detached.'
    }
    if([string]$receipt.timestamp-cne[string]$Event.timestamp-or
        [string]$receipt.status_before-cne[string]$BeforeUnit.status-or[string]$receipt.status_after-cne[string]$after.status-or
        (Get-MorphospaceCanonicalJsonSha256 $receipt.current_unit_before)-cne(Get-MorphospaceCanonicalJsonSha256 $BeforeState.current_unit)-or
        (Get-MorphospaceCanonicalJsonSha256 $receipt.current_unit_after)-cne(Get-MorphospaceCanonicalJsonSha256 $Transition.state_document.current_unit)-or
        $receipt.preservation.git_mutation_performed-ne$false-or$receipt.preservation.device_mutation_performed-ne$false-or$receipt.preservation.force_push_allowed-ne$false){
        throw 'Pre-validation instruction-completion receipt transition fields differ.'
    }
    $rows=@($binding.surfaces)
    if($rows.Count-ne$planned.Count){throw 'Pre-validation instruction-completion surface count differs from the planned set.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previousId=$null
    foreach($row in $rows){
        $matches=@($planned|Where-Object {([string]$_.path).Replace('\','/')-ceq[string]$row.declared_path})
        if($matches.Count-ne1-or-not$paths.Add([string]$row.declared_path)){throw 'Pre-validation instruction-completion surface declaration differs from the planned set.'}
        $surface=$matches[0]
        $skillId=if($surface.PSObject.Properties.Name-contains'skill_id'){$surface.skill_id}else{$null}
        $identity=[pscustomobject][ordered]@{
            surface_kind=[string]$surface.surface_kind;declared_path=([string]$surface.path).Replace('\','/')
            repo_id=[string]$row.repo_id;relative_path=[string]$row.relative_path
            owner=[string]$surface.owner;action=[string]$surface.action;validation=[string]$surface.validation;skill_id=$skillId
        }
        foreach($name in @('surface_kind','declared_path','owner','action','validation','skill_id')){
            if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject][ordered]@{value=$row.$name}))-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject][ordered]@{value=$identity.$name}))){throw 'Pre-validation instruction-completion surface identity differs from the planned declaration.'}
        }
        if([string]$row.surface_id-cne(Get-MorphospaceCanonicalJsonSha256 $identity)-or-not$ids.Add([string]$row.surface_id)-or
            ($null-ne$previousId-and[StringComparer]::Ordinal.Compare([string]$previousId,[string]$row.surface_id)-ge0)){
            throw 'Pre-validation instruction-completion surface IDs are not exact, unique and sorted.'
        }
        $previousId=[string]$row.surface_id
        if([string]$row.previous_status-cne'planned'-or[string]$row.resulting_status-cne'complete'){throw 'Pre-validation instruction-completion surface status differs.'}
        # Routing/content remain historical observations in the same bound artifact.
        # No current repository-map or live instruction file is re-observed here.
        $observed=@($receipt.claim_preflight.instruction_surfaces|Where-Object {[string]$_.path-ceq[string]$row.declared_path})
        if($observed.Count-ne1-or[string]$observed[0].repo_id-cne[string]$row.repo_id-or
            [string]$observed[0].relative_path-cne[string]$row.relative_path-or[string]$observed[0].sha256-cne[string]$row.sha256){
            throw 'Pre-validation instruction-completion retained observation differs.'
        }
    }
    $observation=[pscustomobject][ordered]@{surfaces=$rows}
    if([string]$binding.observation_sha256-cne(Get-MorphospaceCanonicalJsonSha256 $observation)){throw 'Pre-validation instruction-completion observation hash differs.'}
    $expected=$BeforeState|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $expected.last_event_id=[string]$Event.event_id
    Assert-MorphospaceTerminalOrdinaryState $WorkspaceRoot $expected $Transition.state_document
}

function Assert-MorphospaceTerminalBeginValidation {
    param([string]$WorkspaceRoot,[object]$BeforeUnit,[object]$BeforeState,[object]$Transition,[object]$Event)
    $id='{0}-validating-{1:D4}'-f[string]$BeforeUnit.unit_id,[int]$Event.sequence
    if([string]$Transition.intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or
        @($Transition.intent.artifacts).Count-ne0-or@($Event.receipts).Count-ne0-or
        [string]$Event.event_id-cne$id-or[string]$Event.event_type-cne'state-transition'-or
        [string]$Event.summary-cne'Entered validation with a deterministic command, instruction, graph, and device-impact plan.'-or
        [string]$BeforeUnit.status-cne'active'-or[string]$BeforeState.current_unit-cne[string]$BeforeUnit.unit_id){
        throw 'Pre-validation cycle requires exact ordinary BeginValidation.'
    }
    $unit=$BeforeUnit|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $unit.status='validating'
    if((Get-MorphospaceCanonicalJsonSha256 $unit)-cne[string]$Transition.unit_sha256){throw 'Pre-validation BeginValidation changes unit contract beyond status.'}
    $state=$BeforeState|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $state.last_event_id=[string]$Event.event_id
    Assert-MorphospaceTerminalOrdinaryState $WorkspaceRoot $state $Transition.state_document
}

function Assert-MorphospaceTerminalReturnToActive {
    param([string]$WorkspaceRoot,[object]$BeforeUnit,[object]$BeforeState,[object]$Transition,[object]$Event)
    if([string]$Transition.intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or
        @($Transition.intent.artifacts).Count-ne0-or@($Event.receipts).Count-ne1-or
        [string]$Event.event_type-cne'validation'-or
        [string]$Event.summary-cne'Retained a non-passing validation attempt and returned the same feature unit to active for an in-scope correction.'-or
        [string]$BeforeUnit.status-cne'validating'-or[string]$BeforeState.current_unit-cne[string]$BeforeUnit.unit_id-or
        (($BeforeUnit.PSObject.Properties.Name-contains'work_mode')-and[string]$BeforeUnit.work_mode-cne'feature')-or
        (($BeforeUnit.PSObject.Properties.Name-contains'tags')-and@($BeforeUnit.tags|Where-Object {[string]$_-ceq'receipt-security'}).Count-ne0)){
        throw 'Pre-validation cycle requires exact ordinary non-passing ReturnToActive.'
    }
    $checkpoint=$Transition.state_document.validation_checkpoint
    $result=[string]$checkpoint.result
    if($result-cnotin@('partial','fail','blocked')){throw 'Pre-validation ReturnToActive requires a non-passing checkpoint.'}
    $id='{0}-validation-{1}-return-{2:D4}'-f[string]$BeforeUnit.unit_id,$result,[int]$Event.sequence
    $receiptPath=ConvertTo-MorphospaceProtocolRelativePath ([string]$Event.receipts[0])
    if([string]$Event.event_id-cne$id-or[string]$Event.receipts[0]-cne$receiptPath-or[string]$checkpoint.receipt-cne$receiptPath){throw 'Pre-validation ReturnToActive event/checkpoint differs.'}
    $receipt=Test-MorphospaceBlockedSupersessionValidationReceipt -WorkspaceRoot $WorkspaceRoot -RelativePath $receiptPath -ProjectId ([string]$BeforeUnit.project_id) -UnitId ([string]$BeforeUnit.unit_id) -ExpectedResult $result
    if([string]$checkpoint.tier-cne[string]$receipt.tier){throw 'Pre-validation ReturnToActive receipt tier differs.'}
    $unit=$BeforeUnit|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $unit.status='active'
    if((Get-MorphospaceCanonicalJsonSha256 $unit)-cne[string]$Transition.unit_sha256){throw 'Pre-validation ReturnToActive changes unit contract beyond status.'}
    $state=$BeforeState|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $state.last_event_id=[string]$Event.event_id
    $state.validation_checkpoint=[pscustomobject][ordered]@{tier=[string]$receipt.tier;receipt=$receiptPath;result=$result}
    Assert-MorphospaceTerminalOrdinaryState $WorkspaceRoot $state $Transition.state_document
}

function Test-MorphospaceBlockedSupersessionTerminalValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$SupersessionEventId,
        [Parameter(Mandatory = $true)][string]$ReplacementUnitId
    )

    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $ledger = Get-MorphospaceBlockedSupersessionLedger -WorkspaceRoot $workspace
    $supersessionRows = @($ledger.rows | Where-Object { [string]$_.document.event_id -ceq $SupersessionEventId })
    if ($supersessionRows.Count -ne 1) { throw "Supersession event '$SupersessionEventId' is not one exact ledger record." }
    $supersessionRow = $supersessionRows[0]

    $escapedUnit = [Regex]::Escape($ReplacementUnitId)
    $failRows = @($ledger.rows | Where-Object { [string]$_.document.event_id -cmatch "^$escapedUnit-validation-fail-[0-9]{4,}$" })
    if ($failRows.Count -eq 0) {
        return [pscustomobject][ordered]@{
            history_present = $false
            authenticated = $false
            replacement_unit_id = $ReplacementUnitId
            fail_event_id = $null
            continuation_event_count = 0
        }
    }
    if ($failRows.Count -ne 1) { throw "Replacement '$ReplacementUnitId' has more than one candidate validation-fail terminal chain." }
    $supersessionEvent = $supersessionRow.document
    $oldUnitId = [string]$supersessionEvent.unit_id
    if (-not $oldUnitId -or
        [string]$supersessionEvent.project_id -cne $ProjectId -or
        [string]$supersessionEvent.event_type -cne 'state-transition' -or
        [string]$supersessionEvent.event_id -cne "$oldUnitId-superseded-by-$ReplacementUnitId") {
        throw "Supersession event '$SupersessionEventId' does not exactly bind its old and replacement identities."
    }
    $supersession = Test-MorphospaceBlockedSupersessionTransaction `
        -WorkspaceRoot $workspace `
        -Ledger $ledger `
        -Row $supersessionRow `
        -ProjectId $ProjectId `
        -ExpectedTargetUnitId $ReplacementUnitId `
        -ExpectedIntentSchema 'rusty.morphospace.workflow.transition_ledger_intent.v2'
    $failRow = $failRows[0]
    if ([int]$supersessionRow.ordinal -ge [int]$failRow.ordinal) { throw "Replacement '$ReplacementUnitId' failed before its supersession edge." }
    $failEvent = $failRow.document
    $expectedFailId = '{0}-validation-fail-{1:D4}' -f $ReplacementUnitId, [int]$failEvent.sequence
    if ([string]$failEvent.event_id -cne $expectedFailId -or
        [string]$failEvent.project_id -cne $ProjectId -or
        [string]$failEvent.unit_id -cne $ReplacementUnitId -or
        [string]$failEvent.event_type -cne 'blocker' -or
        [string]$failEvent.summary -cne 'Recorded non-passing validation and blocked further acceptance.') {
        throw "Replacement '$ReplacementUnitId' has a malformed validation-fail event."
    }
    if ([int]$failRow.ordinal -eq 0) { throw "Replacement '$ReplacementUnitId' has no BeginValidation predecessor." }
    $beginRow = $ledger.rows[[int]$failRow.ordinal - 1]
    $beginEvent = $beginRow.document
    $expectedBeginId = '{0}-validating-{1:D4}' -f $ReplacementUnitId, [int]$beginEvent.sequence
    if ([string]$beginEvent.event_id -cne $expectedBeginId -or
        [string]$beginEvent.project_id -cne $ProjectId -or
        [string]$beginEvent.unit_id -cne $ReplacementUnitId -or
        [string]$beginEvent.event_type -cne 'state-transition' -or
        [string]$beginEvent.summary -cne 'Entered validation with a deterministic command, instruction, graph, and device-impact plan.' -or
        @($beginEvent.receipts).Count -ne 0 -or
        [int]$failEvent.sequence -ne ([int]$beginEvent.sequence + 1)) {
        throw "Replacement '$ReplacementUnitId' does not have the exact BeginValidation-to-fail event pair."
    }
    $prior = $supersession
    for ($ordinal = [int]$supersessionRow.ordinal + 1; $ordinal -lt [int]$beginRow.ordinal; $ordinal++) {
        $row = $ledger.rows[$ordinal]
        $event = $row.document
        if ([string]$event.project_id -cne $ProjectId -or [string]$event.unit_id -cne $ReplacementUnitId) {
            throw 'Pre-validation continuation crosses the replacement project/unit.'
        }
        $step = Test-MorphospaceBlockedSupersessionTransaction -WorkspaceRoot $workspace -Ledger $ledger -Row $row -ProjectId $ProjectId -ExpectedTargetUnitId $ReplacementUnitId -ExpectedPreStateSha256 $prior.state_sha256 -ExpectedPreUnitSha256 $prior.unit_sha256
        $beginId = '{0}-validating-{1:D4}' -f $ReplacementUnitId, [int]$event.sequence
        if ([string]$event.event_id -ceq $beginId) {
            Assert-MorphospaceTerminalBeginValidation $workspace $prior.unit_document $prior.state_document $step $event
        } elseif ([string]$event.event_type -ceq 'validation') {
            Assert-MorphospaceTerminalReturnToActive $workspace $prior.unit_document $prior.state_document $step $event
        } else {
            Assert-MorphospaceTerminalInstructionCompletion $workspace $prior.unit_document $prior.state_document $step $event
        }
        $prior = $step
    }

    $begin = Test-MorphospaceBlockedSupersessionTransaction `
        -WorkspaceRoot $workspace `
        -Ledger $ledger `
        -Row $beginRow `
        -ProjectId $ProjectId `
        -ExpectedPreStateSha256 $prior.state_sha256 `
        -ExpectedPreUnitSha256 $prior.unit_sha256
    Assert-MorphospaceTerminalBeginValidation $workspace $prior.unit_document $prior.state_document $begin $beginEvent

    $fail = Test-MorphospaceBlockedSupersessionTransaction -WorkspaceRoot $workspace -Ledger $ledger -Row $failRow -ProjectId $ProjectId -ExpectedPreStateSha256 $begin.state_sha256 -ExpectedPreUnitSha256 $begin.unit_sha256
    if ([string]$fail.intent.expected.event_tail_id -cne [string]$beginEvent.event_id) {
        throw "Validation-fail intent is not attached directly to BeginValidation."
    }
    if ([string]$fail.unit_document.status -cne 'blocked' -or
        $null -ne $fail.state_document.current_unit -or
        $null -ne $fail.state_document.next_ready_unit -or
        [string]$fail.state_document.last_event_id -cne [string]$failEvent.event_id) {
        throw "Validation-fail target is not the exact terminal blocked projection."
    }
    if (@($failEvent.receipts).Count -ne 1 -or @($failEvent.receipts)[0] -isnot [string]) {
        throw "Validation-fail event must reference exactly one v1 validation receipt path."
    }
    $receiptPath = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]@($failEvent.receipts)[0])
    $receipt = Test-MorphospaceBlockedSupersessionValidationReceipt -WorkspaceRoot $workspace -RelativePath $receiptPath -ProjectId $ProjectId -UnitId $ReplacementUnitId
    $checkpoint = $fail.state_document.validation_checkpoint
    if ($null -eq $checkpoint -or
        [string]$checkpoint.receipt -cne $receiptPath -or
        [string]$checkpoint.result -cne 'fail' -or
        [string]$checkpoint.tier -cne [string]$receipt.tier) {
        throw "Validation-fail target checkpoint does not bind its same-unit fail receipt."
    }
    $blockerId = "$ReplacementUnitId-validation-fail"
    $blockers = @($fail.state_document.blockers | Where-Object { [string]$_.blocker_id -ceq $blockerId })
    if ($blockers.Count -ne 1 -or
        [string]$blockers[0].condition -cne "Validation result is fail in $receiptPath." -or
        [string]$blockers[0].resume_when -cne 'Correct the failure and explicitly resume the unit.') {
        throw "Validation-fail target lacks its exact owner-defined blocker projection."
    }
    if ([string]$fail.state_document.last_accepted_receipt -cne [string]$begin.state_document.last_accepted_receipt) {
        throw "Validation-fail target inferred or changed acceptance state."
    }

    $stateProjection = $fail.state_document
    $stateProjectionSha256 = $fail.state_sha256
    $unitProjection = @{}
    $unitProjection[$ReplacementUnitId] = [pscustomobject][ordered]@{ document = $fail.unit_document; sha256 = $fail.unit_sha256 }
    $additionalProjection = @{}
    $continuationCount = 0
    for ($ordinal = [int]$failRow.ordinal + 1; $ordinal -lt $ledger.rows.Count; $ordinal++) {
        $row = $ledger.rows[$ordinal]
        $eventUnitId = [string]$row.document.unit_id
        if (-not $eventUnitId) { throw "Later event '$([string]$row.document.event_id)' lacks a unit identity required for historical derivation." }
        $laterEventId = [string]$row.document.event_id
        $laterIntent = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $workspace -RelativePath "receipts/transactions/$laterEventId-transition.intent.json" -Context "later transition intent '$laterEventId' schema dispatch"
        $laterIntentSchema = [string]$laterIntent.document.schema
        if ($laterIntentSchema -cnotin @(
            'rusty.morphospace.workflow.transition_ledger_intent.v1',
            'rusty.morphospace.workflow.transition_ledger_intent.v2',
            'rusty.morphospace.workflow.transition_ledger_intent.v3',
            'rusty.morphospace.workflow.transition_ledger_intent.v4',
            'rusty.morphospace.workflow.transition_ledger_intent.v5',
            'rusty.morphospace.workflow.transition_ledger_intent.v6'
        )) {
            throw "Later transition '$laterEventId' uses an unsupported owner-intent schema."
        }
        $transitionUnitId = $eventUnitId
        if ($laterIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2') {
            $delimiter = '-superseded-by-'
            $firstDelimiter = $laterEventId.IndexOf($delimiter,[StringComparison]::Ordinal)
            if ($firstDelimiter -lt 1 -or $firstDelimiter -ne $laterEventId.LastIndexOf($delimiter,[StringComparison]::Ordinal)) {
                throw "Later transition intent v2 '$laterEventId' is not one exact supersession identity."
            }
            if ($null -eq $laterIntent.document.PSObject.Properties['supersession']) {
                throw "Later transition intent v2 '$laterEventId' lacks its owner supersession binding."
            }
            $transitionUnitId = [string]$laterIntent.document.supersession.new_unit_id
            if (-not $transitionUnitId -or [string]$laterIntent.document.supersession.old_unit_id -cne $eventUnitId -or
                $laterEventId -cne "$eventUnitId$delimiter$transitionUnitId") {
                throw "Later transition intent v2 '$laterEventId' detaches its old or replacement identity."
            }
        }
        $knownUnitSha = if ($unitProjection.ContainsKey($transitionUnitId)) { [string]$unitProjection[$transitionUnitId].sha256 } else { '' }
        $laterProjectionIntent = $laterIntentSchema -cin @(
            'rusty.morphospace.workflow.transition_ledger_intent.v3',
            'rusty.morphospace.workflow.transition_ledger_intent.v4',
            'rusty.morphospace.workflow.transition_ledger_intent.v6'
        )
        $laterArtifactPaths = @($laterIntent.document.artifacts | ForEach-Object { [string]$_.path })
        $laterRematerializationArtifactShape = (
            $laterArtifactPaths.Count -eq 2 -and
            @($laterArtifactPaths | Where-Object { $_ -cmatch '^receipts/[^/]+\.json$' }).Count -eq 1 -and
            @($laterArtifactPaths | Where-Object { $_ -cmatch '^source-compositions/[^/]+\.lock\.json$' }).Count -eq 1
        )
        $laterRematerializationV6 = (
            $laterIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v6' -and
            ($laterRematerializationArtifactShape -or
             [string]$row.document.summary -ceq 'Rematerialized only the exact source and candidate-freeze bindings of the current validating unit while invalidating its stale selector.')
        )
        $laterRawArtifactIntent = $laterIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v5'
        $laterProjectionVersion = if ($laterIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v6') { 'v6' } elseif ($laterIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v4') { 'v4' } else { 'v3' }
        if (($laterProjectionIntent -or $laterRawArtifactIntent) -and -not $knownUnitSha) {
            throw "Later transition intent $laterProjectionVersion '$laterEventId' does not continue a previously authenticated unit projection."
        }
        if ($laterIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2' -and
            (-not $knownUnitSha -or -not $unitProjection.ContainsKey($eventUnitId))) {
            throw "Later transition intent v2 '$laterEventId' does not continue authenticated old and replacement unit projections."
        }
        $priorStateProjection = $stateProjection
        $priorUnitProjection = if ($unitProjection.ContainsKey($transitionUnitId)) { $unitProjection[$transitionUnitId].document } else { $null }
        $transitionArguments = @{
            WorkspaceRoot=$workspace;Ledger=$ledger;Row=$row;ProjectId=$ProjectId
            ExpectedPreStateSha256=$stateProjectionSha256;ExpectedPreUnitSha256=$knownUnitSha;ExpectedIntentSchema=$laterIntentSchema
        }
        if ($laterIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2') { $transitionArguments.ExpectedTargetUnitId = $transitionUnitId }
        $transition = Test-MorphospaceBlockedSupersessionTransaction @transitionArguments
        if ($laterRematerializationV6) {
            if ($null -eq $priorUnitProjection) {
                throw "Rematerialization v6 '$laterEventId' does not continue an authenticated validating unit projection."
            }
            Test-MorphospaceBlockedSupersessionRematerializationV6 -WorkspaceRoot $workspace -ProjectId $ProjectId -UnitId $eventUnitId `
                -Transition $transition -PriorState $priorStateProjection -PriorStateSha256 $stateProjectionSha256 `
                -PriorUnit $priorUnitProjection -PriorUnitSha256 $knownUnitSha
            foreach ($projection in @($transition.additional_projections)) {
                $projectionPath = [string]$projection.path
                if ($additionalProjection.ContainsKey($projectionPath)) {
                    if ([string]$projection.pre_sha256 -cne [string]$additionalProjection[$projectionPath].sha256) {
                        throw "Rematerialization v6 '$laterEventId' detaches projection '$projectionPath' from its authenticated predecessor target."
                    }
                } elseif ([string]$projection.pre_sha256 -cne [string]$projection.target_sha256) {
                    throw "Rematerialization v6 '$laterEventId' changes unanchored projection '$projectionPath'."
                }
                $additionalProjection[$projectionPath] = [pscustomobject][ordered]@{
                    document = $projection.document
                    sha256 = [string]$projection.target_sha256
                }
            }
        } elseif ($laterProjectionIntent) {
            if ($null -eq $priorUnitProjection -or
                [string]$priorUnitProjection.status -cne 'active' -or
                [string]$transition.unit_document.status -cne [string]$priorUnitProjection.status -or
                [string]$transition.unit_document.unit_id -cne $eventUnitId -or
                [string]$priorStateProjection.current_unit -cne $eventUnitId -or
                [string]$transition.state_document.current_unit -cne $eventUnitId -or
                [string]$transition.state_document.next_ready_unit -cne [string]$priorStateProjection.next_ready_unit -or
                [string]$transition.state_document.last_accepted_receipt -cne [string]$priorStateProjection.last_accepted_receipt) {
                throw "Later transition intent $laterProjectionVersion '$laterEventId' changed captain, status, readiness, or acceptance projection."
            }
            $expectedState = $priorStateProjection | ConvertTo-Json -Depth 64 | ConvertFrom-Json
            $expectedState.last_event_id = $laterEventId
            if ((Get-MorphospaceCanonicalJsonSha256 -Value $expectedState) -cne [string]$transition.state_sha256) {
                throw "Later transition intent $laterProjectionVersion '$laterEventId' changed workspace state beyond its authenticated event tail."
            }
            foreach ($projection in @($transition.additional_projections)) {
                $projectionPath = [string]$projection.path
                if ($additionalProjection.ContainsKey($projectionPath)) {
                    if ([string]$projection.pre_sha256 -cne [string]$additionalProjection[$projectionPath].sha256) {
                        throw "Later transition intent $laterProjectionVersion '$laterEventId' detaches projection '$projectionPath' from its authenticated predecessor target."
                    }
                } elseif ([string]$projection.pre_sha256 -cne [string]$projection.target_sha256) {
                    throw "Later transition intent $laterProjectionVersion '$laterEventId' changes unanchored projection '$projectionPath'."
                }
                $additionalProjection[$projectionPath] = [pscustomobject][ordered]@{
                    document = $projection.document
                    sha256 = [string]$projection.target_sha256
                }
            }
        } elseif ($laterRawArtifactIntent) {
            if ($null -eq $priorUnitProjection -or [string]$transition.unit_sha256 -cne $knownUnitSha) {
                throw "Later transition intent v5 '$laterEventId' changed or detached its authenticated unit projection."
            }
            $expectedState = $priorStateProjection | ConvertTo-Json -Depth 64 | ConvertFrom-Json
            $expectedState.last_event_id = $laterEventId
            if ((Get-MorphospaceCanonicalJsonSha256 -Value $expectedState) -cne [string]$transition.state_sha256) {
                throw "Later transition intent v5 '$laterEventId' changed workspace state beyond its authenticated event tail."
            }
        } elseif ($laterIntentSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2') {
            $priorOldUnit = $unitProjection[$eventUnitId].document
            if ([string]$priorOldUnit.status -cnotin @('active','validating') -or
                [string]$priorUnitProjection.status -cne 'ready' -or
                [string]$priorStateProjection.current_unit -cne $eventUnitId -or
                [string]$priorStateProjection.next_ready_unit -cne $transitionUnitId -or
                [string]$transition.state_document.current_unit -cne $transitionUnitId -or
                $null -ne $transition.state_document.next_ready_unit -or
                [string]$transition.unit_document.unit_id -cne $transitionUnitId -or
                [string]$transition.unit_document.status -cne 'active' -or
                [string]$transition.state_document.last_accepted_receipt -cne [string]$priorStateProjection.last_accepted_receipt) {
                throw "Later transition intent v2 '$laterEventId' changed status, readiness, endpoints, or acceptance beyond exact supersession."
            }
            $expectedState = $priorStateProjection | ConvertTo-Json -Depth 64 | ConvertFrom-Json
            $expectedState.current_unit = $transitionUnitId
            $expectedState.next_ready_unit = $null
            $expectedState.last_event_id = $laterEventId
            if ((Get-MorphospaceCanonicalJsonSha256 -Value $expectedState) -cne [string]$transition.state_sha256) {
                throw "Later transition intent v2 '$laterEventId' changed workspace state beyond exact supersession."
            }
        }
        $stateProjection = $transition.state_document
        $stateProjectionSha256 = $transition.state_sha256
        $unitProjection[$transitionUnitId] = [pscustomobject][ordered]@{ document = $transition.unit_document; sha256 = $transition.unit_sha256 }
        $continuationCount++
    }

    $liveStateFile = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $workspace -RelativePath 'workspace.state.json' -Context 'live workspace state'
    if ((Get-MorphospaceCanonicalJsonSha256 -Value $liveStateFile.document) -cne $stateProjectionSha256) {
        throw "Live workspace state is not derivable from the authenticated fail transition and later event chain."
    }
    foreach ($unitId in @($unitProjection.Keys)) {
        $liveUnit = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $workspace -RelativePath "iteration-units/$unitId.json" -Context "live iteration unit '$unitId'"
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $liveUnit.document) -cne [string]$unitProjection[$unitId].sha256) {
            throw "Live unit '$unitId' is not derivable from the authenticated fail transition and later event chain."
        }
    }
    foreach ($projectionPath in @($additionalProjection.Keys)) {
        $liveProjection = Read-MorphospaceBlockedSupersessionJson -WorkspaceRoot $workspace -RelativePath $projectionPath -Context "live additional projection '$projectionPath'"
        if ((Get-MorphospaceCanonicalJsonSha256 -Value $liveProjection.document) -cne [string]$additionalProjection[$projectionPath].sha256) {
            throw "Live additional projection '$projectionPath' is not derivable from the authenticated v3 continuation chain."
        }
    }
    $liveReplacement = $unitProjection[$ReplacementUnitId].document
    if ([string]$liveReplacement.status -cnotin @('blocked','active','validating','accepted')) {
        throw "Replacement '$ReplacementUnitId' has an illegal live status after its authenticated fail history."
    }
    return [pscustomobject][ordered]@{
        history_present = $true
        authenticated = $true
        replacement_unit_id = $ReplacementUnitId
        fail_event_id = [string]$failEvent.event_id
        begin_event_id = [string]$beginEvent.event_id
        supersession_event_id = [string]$supersessionEvent.event_id
        validation_receipt = $receiptPath
        continuation_event_count = $continuationCount
        continuation_projection_count = $additionalProjection.Count
        final_state_sha256 = $stateProjectionSha256
        live_replacement_status = [string]$liveReplacement.status
        acceptance_inferred = $false
    }
}

Export-ModuleMember -Function Test-MorphospaceBlockedSupersessionTerminalValidation
