Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force

$script:HucSchema = 'rusty.morphospace.workflow.historical_unit_compatibility_projection.v1'
$script:HucSummary = 'Recorded one authenticated historical work-unit compatibility projection without rewriting history or inferring completion, validation, acceptance, or publication authority.'

function Copy-HucDocument {
    param([Parameter(Mandatory)][object]$Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 100 -Compress))
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'historical compatibility document copy'
}

function Get-HucLineBytes {
    param([Parameter(Mandatory)][object]$Event)
    [Text.UTF8Encoding]::new($false).GetBytes(($Event | ConvertTo-Json -Depth 64 -Compress))
}

function Test-HucBytesEqual {
    param([byte[]]$Left,[byte[]]$Right)
    if ($Left.LongLength -ne $Right.LongLength) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) { if ($Left[$index] -ne $Right[$index]) { return $false } }
    return $true
}

function Get-HucLedger {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)
    $path = Resolve-MorphospaceWorkspacePath $WorkspaceRoot 'iteration-events.jsonl' -RequireLeaf
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.LongLength -lt 2 -or $bytes.LongLength -gt 67108864 -or $bytes[$bytes.Length - 1] -ne 0x0a) {
        throw 'Historical compatibility requires a non-empty LF-terminated event ledger within 64 MiB.'
    }
    $rows = [Collections.Generic.List[object]]::new()
    $offset = 0
    $index = 0
    while ($offset -lt $bytes.Length) {
        $lf = [Array]::IndexOf[byte]($bytes,0x0a,$offset)
        if ($lf -lt 0) { throw 'Historical compatibility event ledger lacks a terminal line ending.' }
        $contentLength = $lf - $offset
        if ($contentLength -gt 0 -and $bytes[$lf - 1] -eq 0x0d) { $contentLength-- }
        if ($contentLength -lt 1) { throw "Historical compatibility event ledger line $($index + 1) is blank." }
        $lineBytes = [byte[]]::new($contentLength)
        [Array]::Copy($bytes,$offset,$lineBytes,0,$contentLength)
        try { [void][Text.UTF8Encoding]::new($false,$true).GetString($lineBytes) }
        catch { throw "Historical compatibility event ledger line $($index + 1) is not strict UTF-8." }
        $event = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $lineBytes -Context "historical compatibility event line $($index + 1)"
        if ([int]$event.sequence -ne $index + 1) { throw 'Historical compatibility event sequence does not equal physical order.' }
        $prefix = [byte[]]::new($offset)
        if ($offset) { [Array]::Copy($bytes,0,$prefix,0,$offset) }
        $rows.Add([pscustomobject][ordered]@{
            ordinal=$index; offset=$offset; document=$event
            line_sha256=Get-MorphospaceSha256Bytes $lineBytes
            prefix_sha256=Get-MorphospaceSha256Bytes $prefix
            prefix_length=[int64]$offset
        }) | Out-Null
        $offset = $lf + 1
        $index++
    }
    [pscustomobject][ordered]@{path=$path;bytes=$bytes;sha256=Get-MorphospaceSha256Bytes $bytes;length=[int64]$bytes.LongLength;rows=@($rows)}
}

function Get-HucBoundJson {
    param([string]$WorkspaceRoot,[string]$RelativePath,[string]$ExpectedSha256,[string]$Label)
    $relative = ConvertTo-MorphospaceProtocolRelativePath $RelativePath
    if ($relative -cne $RelativePath) { throw "$Label path is not canonical." }
    $path = Resolve-MorphospaceWorkspacePath $WorkspaceRoot $relative -RequireLeaf
    $actual = Get-MorphospaceFileSha256 $path
    if ($actual -cne $ExpectedSha256) { throw "$Label file hash drifted." }
    [pscustomobject][ordered]@{path=$path;relative=$relative;sha256=$actual;bytes=[IO.File]::ReadAllBytes($path);document=Read-MorphospaceProtocolJson $path}
}

function Assert-HucSameDocument {
    param([object]$Expected,[object]$Actual,[string]$Label)
    if ((Get-MorphospaceCanonicalJsonSha256 $Expected) -cne (Get-MorphospaceCanonicalJsonSha256 $Actual)) { throw "$Label document drifted." }
}

function Assert-HucTransitionBinding {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][object]$Binding,
        [Parameter(Mandatory)][string]$ExpectedSchema,
        [string]$ExpectedArtifactPath = '',
        [string]$ExpectedReferencedReceiptPath = ''
    )
    Assert-MorphospaceExactPropertySet $Binding @('event_id','sequence','event_sha256','intent_path','intent_sha256','completion_path','completion_sha256') @() 'Historical compatibility event binding'
    $eventId = [string]$Binding.event_id
    $matches = @($Ledger.rows | Where-Object { [string]$_.document.event_id -ceq $eventId })
    if ($matches.Count -ne 1) { throw "Historical compatibility event '$eventId' is missing or ambiguous." }
    $row = $matches[0]
    if ([int]$Binding.sequence -ne [int]$row.document.sequence -or [string]$Binding.event_sha256 -cne [string]$row.line_sha256) {
        throw "Historical compatibility event '$eventId' sequence or immutable line hash drifted."
    }
    $transactionId = "$eventId-transition"
    $expectedIntentPath = "receipts/transactions/$transactionId.intent.json"
    $expectedCompletionPath = "receipts/transactions/$transactionId.completion.json"
    if ([string]$Binding.intent_path -cne $expectedIntentPath -or [string]$Binding.completion_path -cne $expectedCompletionPath) {
        throw "Historical compatibility event '$eventId' transaction paths are not canonical."
    }
    $intentFile = Get-HucBoundJson $WorkspaceRoot $expectedIntentPath ([string]$Binding.intent_sha256) "Historical compatibility event '$eventId' intent"
    $completionFile = Get-HucBoundJson $WorkspaceRoot $expectedCompletionPath ([string]$Binding.completion_sha256) "Historical compatibility event '$eventId' completion"
    $intent = $intentFile.document
    $completion = $completionFile.document
    $requiredIntent = @('schema','transaction_id','created_at','state','unit','events','pre','target','expected','artifacts','event','status')
    if ($ExpectedSchema -ceq 'rusty.morphospace.workflow.transition_ledger_intent.v2') { $requiredIntent += 'supersession' }
    Assert-MorphospaceExactPropertySet $intent $requiredIntent @() "Historical compatibility event '$eventId' intent"
    if ([string]$intent.schema -cne $ExpectedSchema -or [string]$intent.transaction_id -cne $transactionId -or [string]$intent.status -cne 'prepared') {
        throw "Historical compatibility event '$eventId' intent identity is invalid."
    }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at))
    foreach ($referenceName in @('state','unit','events')) {
        Assert-MorphospaceExactPropertySet $intent.$referenceName @('path') @() "Historical compatibility event '$eventId' $referenceName reference"
    }
    if ([string]$intent.state.path -cne 'workspace.state.json' -or [string]$intent.events.path -cne 'iteration-events.jsonl' -or
        [string]$intent.unit.path -cnotmatch '^iteration-units/[a-z0-9][a-z0-9-]{1,127}\.json$') {
        throw "Historical compatibility event '$eventId' intent paths are invalid."
    }
    Assert-MorphospaceExactPropertySet $intent.pre @('state','unit') @() "Historical compatibility event '$eventId' preimage"
    Assert-MorphospaceExactPropertySet $intent.target @('state','unit') @() "Historical compatibility event '$eventId' target"
    Assert-MorphospaceExactPropertySet $intent.expected @('state_sha256','unit_sha256','event_tail_id','events_sha256','events_length') @() "Historical compatibility event '$eventId' expected"
    foreach ($name in @('state','unit')) {
        Assert-MorphospaceExactPropertySet $intent.pre.$name @('sha256') @() "Historical compatibility event '$eventId' pre-$name"
        Assert-MorphospaceExactPropertySet $intent.target.$name @('sha256','document') @() "Historical compatibility event '$eventId' target-$name"
        if ([string]$intent.pre.$name.sha256 -cne [string]$intent.expected."${name}_sha256" -or
            [string]$intent.target.$name.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $intent.target.$name.document)) {
            throw "Historical compatibility event '$eventId' $name hashes are inconsistent."
        }
    }
    if ([int64]$intent.expected.events_length -ne [int64]$row.prefix_length -or
        [string]$intent.expected.events_sha256 -cne [string]$row.prefix_sha256) {
        throw "Historical compatibility event '$eventId' is detached from its exact ledger prefix."
    }
    $expectedPredecessor = if ([int]$row.ordinal -gt 0) { [string]$Ledger.rows[[int]$row.ordinal - 1].document.event_id } else { $null }
    if ([string]$intent.expected.event_tail_id -cne [string]$expectedPredecessor) { throw "Historical compatibility event '$eventId' predecessor drifted." }
    Assert-HucSameDocument $intent.event $row.document "Historical compatibility event '$eventId'"

    $artifactPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($artifact in @($intent.artifacts)) {
        Assert-MorphospaceExactPropertySet $artifact @('path','sha256','bytes_base64') @() "Historical compatibility event '$eventId' artifact"
        $artifactPath = ConvertTo-MorphospaceProtocolRelativePath ([string]$artifact.path)
        if ([string]$artifact.path -cne $artifactPath -or -not $artifactPaths.Add($artifactPath)) { throw "Historical compatibility event '$eventId' artifact path is duplicated or noncanonical." }
        try { $artifactBytes = [Convert]::FromBase64String([string]$artifact.bytes_base64) } catch { throw "Historical compatibility event '$eventId' artifact base64 is malformed." }
        if ([Convert]::ToBase64String($artifactBytes) -cne [string]$artifact.bytes_base64 -or (Get-MorphospaceSha256Bytes $artifactBytes) -cne [string]$artifact.sha256) {
            throw "Historical compatibility event '$eventId' artifact encoding or hash is invalid."
        }
        $liveArtifact = Resolve-MorphospaceWorkspacePath $WorkspaceRoot $artifactPath -RequireLeaf
        if (-not (Test-HucBytesEqual $artifactBytes ([IO.File]::ReadAllBytes($liveArtifact)))) { throw "Historical compatibility event '$eventId' artifact live bytes drifted." }
    }
    if ($ExpectedArtifactPath -and $ExpectedReferencedReceiptPath) {
        throw "Historical compatibility event '$eventId' cannot bind one receipt as both a transaction artifact and an existing reference."
    }
    if ($ExpectedArtifactPath) {
        if (@($intent.artifacts).Count -ne 1 -or -not $artifactPaths.Contains($ExpectedArtifactPath) -or
            @($row.document.receipts).Count -ne 1 -or [string]@($row.document.receipts)[0] -cne $ExpectedArtifactPath) {
            throw "Historical compatibility event '$eventId' does not bind its exact receipt artifact."
        }
    } elseif ($ExpectedReferencedReceiptPath) {
        if (@($intent.artifacts).Count -ne 0 -or @($row.document.receipts).Count -ne 1 -or
            [string]@($row.document.receipts)[0] -cne $ExpectedReferencedReceiptPath) {
            throw "Historical compatibility event '$eventId' does not bind its exact existing receipt reference."
        }
    } elseif (@($intent.artifacts).Count -ne 0 -or @($row.document.receipts).Count -ne 0) {
        throw "Historical compatibility event '$eventId' unexpectedly carries receipt artifacts."
    }

    Assert-MorphospaceExactPropertySet $completion @('schema','transaction_id','completed_at','intent','state_sha256','unit_sha256','event_id','status') @() "Historical compatibility event '$eventId' completion"
    Assert-MorphospaceExactPropertySet $completion.intent @('role','path','schema','sha256') @() "Historical compatibility event '$eventId' completion intent"
    if ([string]$completion.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or [string]$completion.transaction_id -cne $transactionId -or
        [string]$completion.status -cne 'committed' -or [string]$completion.event_id -cne $eventId -or
        [string]$completion.intent.role -cne 'transition-ledger-intent' -or [string]$completion.intent.path -cne $expectedIntentPath -or
        [string]$completion.intent.schema -cne $ExpectedSchema -or [string]$completion.intent.sha256 -cne [string]$Binding.intent_sha256 -or
        [string]$completion.state_sha256 -cne [string]$intent.target.state.sha256 -or [string]$completion.unit_sha256 -cne [string]$intent.target.unit.sha256) {
        throw "Historical compatibility event '$eventId' completion is detached from its intent or targets."
    }
    $created = Test-MorphospaceStrictUtcTimestamp ([string]$intent.created_at)
    $completed = Test-MorphospaceStrictUtcTimestamp ([string]$completion.completed_at)
    if ($completed -lt $created) { throw "Historical compatibility event '$eventId' completion predates its intent." }
    [pscustomobject][ordered]@{row=$row;intent=$intent;completion=$completion;intent_file=$intentFile;completion_file=$completionFile}
}

function Assert-HucStateOnlyTailChanged {
    param([object]$Before,[object]$After,[string]$ExpectedTail,[string]$Label)
    $expected = Copy-HucDocument $Before
    $expected.last_event_id = $ExpectedTail
    Assert-HucSameDocument $expected $After $Label
}

function Assert-HucOwnerClosureContinuation {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][object]$Projection,
        [Parameter(Mandatory)][object]$Receipt,
        [Parameter(Mandatory)][object]$LiveState,
        [Parameter(Mandatory)][object]$LiveAuthorityUnit
    )
    $authorityUnitId = [string]$Receipt.authority_unit_id
    $laterRows = @($Ledger.rows | Where-Object { [int]$_.ordinal -gt [int]$Projection.row.ordinal })
    if ($laterRows.Count -gt 4) { throw 'Historical compatibility authority continuation exceeds the exact local closure suffix.' }

    $priorState = $Projection.intent.target.state.document
    $priorStateSha256 = [string]$Projection.intent.target.state.sha256
    $priorUnit = $Projection.intent.target.unit.document
    $priorUnitSha256 = [string]$Projection.intent.target.unit.sha256
    $validationReceiptPath = ''

    for ($index = 0; $index -lt $laterRows.Count; $index++) {
        $row = $laterRows[$index]
        $event = $row.document
        $eventId = [string]$event.event_id
        if ([string]$event.project_id -cne [string]$Receipt.project_id -or [string]$event.unit_id -cne $authorityUnitId) {
            throw "Historical compatibility authority continuation '$eventId' has a detached project or unit identity."
        }
        $intentPath = "receipts/transactions/$eventId-transition.intent.json"
        $completionPath = "receipts/transactions/$eventId-transition.completion.json"
        $binding = [pscustomobject][ordered]@{
            event_id=$eventId;sequence=[int]$event.sequence;event_sha256=[string]$row.line_sha256
            intent_path=$intentPath;intent_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $WorkspaceRoot $intentPath -RequireLeaf)
            completion_path=$completionPath;completion_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $WorkspaceRoot $completionPath -RequireLeaf)
        }

        $expectedState = Copy-HucDocument $priorState
        $expectedUnit = Copy-HucDocument $priorUnit
        $transition = $null
        switch ($index) {
            0 {
                $instructionReceiptPath = if (@($event.receipts).Count -eq 1) { [string]@($event.receipts)[0] } else { '' }
                if ($eventId -cne "$authorityUnitId-instructions-recorded" -or [string]$event.event_type -cne 'state-transition' -or
                    [string]$event.summary -cne 'Completed the exact declared instruction-surface set after stable content observation without executing validation commands.' -or
                    -not $instructionReceiptPath) {
                    throw "Historical compatibility authority continuation '$eventId' is not the exact instruction-completion event."
                }
                $transition = Assert-HucTransitionBinding $WorkspaceRoot $Ledger $binding 'rusty.morphospace.workflow.transition_ledger_intent.v1' $instructionReceiptPath
                $instructionReceipt = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $WorkspaceRoot $instructionReceiptPath -RequireLeaf)
                if ([string]$instructionReceipt.schema -cne 'rusty.morphospace.workflow.work_unit_automation_receipt.v1' -or
                    [string]$instructionReceipt.project_id -cne [string]$Receipt.project_id -or [string]$instructionReceipt.unit_id -cne $authorityUnitId -or
                    [string]$instructionReceipt.action -cne 'CompleteInstructionSurfaces' -or $instructionReceipt.executed -ne $true -or
                    [string]$instructionReceipt.transition -cne 'planned-instruction-surfaces-to-complete' -or
                    [string]$instructionReceipt.status_before -cne 'active' -or [string]$instructionReceipt.status_after -cne 'active' -or
                    [string]$instructionReceipt.current_unit_before -cne $authorityUnitId -or [string]$instructionReceipt.current_unit_after -cne $authorityUnitId -or
                    [string]$instructionReceipt.event_id -cne $eventId -or
                    $instructionReceipt.instruction_surface_completion.all_planned_surfaces_completed -ne $true -or
                    $instructionReceipt.instruction_surface_completion.surface_files_observed_stable -ne $true -or
                    $instructionReceipt.instruction_surface_completion.validation_commands_executed -ne $false -or
                    [string]$instructionReceipt.instruction_surface_completion.expected_unit_sha256 -cne $priorUnitSha256 -or
                    [string]$instructionReceipt.instruction_surface_completion.resulting_unit_sha256 -cne [string]$transition.intent.target.unit.sha256) {
                    throw 'Historical compatibility instruction-completion receipt is detached or overclaims validation.'
                }
                foreach ($surface in @($expectedUnit.instruction_surfaces)) {
                    if ([string]$surface.status -cne 'planned') { throw 'Historical compatibility instruction continuation did not begin from an all-planned surface set.' }
                    $surface.status = 'complete'
                }
                $repoStates = @($instructionReceipt.preservation.repository_states)
                if ($repoStates.Count -lt 1) { throw 'Historical compatibility instruction receipt has no repository observation.' }
                $dirtySet = @{}
                foreach ($repoId in @($expectedState.dirty_repositories)) { $dirtySet[[string]$repoId] = $true }
                $headMap = @{}
                foreach ($head in @($expectedState.repository_heads)) { $headMap[[string]$head.repo_id] = $head }
                $seenRepos = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($repoState in $repoStates) {
                    $repoId = [string]$repoState.repo_id
                    if (-not $repoId -or -not $seenRepos.Add($repoId) -or $repoState.available -ne $true -or $repoState.is_git -ne $true -or $repoState.dirty -ne $false) {
                        throw 'Historical compatibility instruction receipt repository observations are missing, duplicated, unavailable, non-Git, or dirty.'
                    }
                    $dirtySet.Remove($repoId)
                    $headMap[$repoId] = [pscustomobject][ordered]@{
                        repo_id=$repoId;head=[string]$repoState.head;branch=$repoState.branch
                        dirty_fingerprint='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
                    }
                }
                $expectedState.dirty_repositories = @($dirtySet.Keys | Sort-Object)
                $expectedState.repository_heads = @($headMap.Values | Sort-Object repo_id)
                $expectedState.last_event_id = $eventId
            }
            1 {
                $expectedId = "$authorityUnitId-validating-$('{0:D4}' -f [int]$event.sequence)"
                if ($eventId -cne $expectedId -or [string]$event.event_type -cne 'state-transition' -or
                    [string]$event.summary -cne 'Entered validation with a deterministic command, instruction, graph, and device-impact plan.' -or @($event.receipts).Count -ne 0) {
                    throw "Historical compatibility authority continuation '$eventId' is not the exact BeginValidation event."
                }
                $transition = Assert-HucTransitionBinding $WorkspaceRoot $Ledger $binding 'rusty.morphospace.workflow.transition_ledger_intent.v1'
                $expectedState.last_event_id = $eventId
                if ([string]$expectedUnit.status -cne 'active') { throw 'Historical compatibility BeginValidation does not follow the active instruction-complete unit.' }
                $expectedUnit.status = 'validating'
            }
            2 {
                $validationReceiptPath = if (@($event.receipts).Count -eq 1) { [string]@($event.receipts)[0] } else { '' }
                $expectedId = "$authorityUnitId-validation-pass-$('{0:D4}' -f [int]$event.sequence)"
                if ($eventId -cne $expectedId -or [string]$event.event_type -cne 'validation' -or
                    [string]$event.summary -cne 'Recorded passing validation; acceptance remains a separate explicit transition.' -or -not $validationReceiptPath) {
                    throw "Historical compatibility authority continuation '$eventId' is not the exact passing RecordValidation event."
                }
                $transition = Assert-HucTransitionBinding -WorkspaceRoot $WorkspaceRoot -Ledger $Ledger -Binding $binding `
                    -ExpectedSchema 'rusty.morphospace.workflow.transition_ledger_intent.v1' -ExpectedReferencedReceiptPath $validationReceiptPath
                $validationReceiptAbsolute = Resolve-MorphospaceWorkspacePath $WorkspaceRoot $validationReceiptPath -RequireLeaf
                $validationRaw = Get-Content -Raw -LiteralPath $validationReceiptAbsolute
                $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
                if (-not (Test-Json -Json $validationRaw -SchemaFile (Join-Path $repoRoot 'schemas\validation-receipt.schema.json'))) {
                    throw 'Historical compatibility authority continuation validation receipt does not satisfy its closed schema.'
                }
                $validationReceipt = Read-MorphospaceProtocolJson $validationReceiptAbsolute
                if ([string]$validationReceipt.project_id -cne [string]$Receipt.project_id -or [string]$validationReceipt.unit_id -cne $authorityUnitId -or
                    [string]$validationReceipt.result -cne 'pass' -or [string]$validationReceipt.tier -cne 'deep') {
                    throw 'Historical compatibility authority continuation validation receipt identity/result/tier drifted.'
                }
                $expectedState.last_event_id = $eventId
                $expectedState.validation_checkpoint = [pscustomobject][ordered]@{tier='deep';receipt=$validationReceiptPath;result='pass'}
            }
            3 {
                if (-not $validationReceiptPath) {
                    $priorCheckpoint = $priorState.validation_checkpoint
                    $validationReceiptPath = if ([string]$priorCheckpoint.result -ceq 'pass') { [string]$priorCheckpoint.receipt } else { '' }
                }
                $expectedId = "$authorityUnitId-accepted-$('{0:D4}' -f [int]$event.sequence)"
                if ($eventId -cne $expectedId -or [string]$event.event_type -cne 'state-transition' -or
                    [string]$event.summary -cne 'Accepted the unit after passing validation and instruction synchronization.' -or -not $validationReceiptPath) {
                    throw "Historical compatibility authority continuation '$eventId' is not the exact Accept event."
                }
                $transition = Assert-HucTransitionBinding -WorkspaceRoot $WorkspaceRoot -Ledger $Ledger -Binding $binding `
                    -ExpectedSchema 'rusty.morphospace.workflow.transition_ledger_intent.v1' -ExpectedReferencedReceiptPath $validationReceiptPath
                if ([string]$priorState.validation_checkpoint.result -cne 'pass' -or [string]$priorState.validation_checkpoint.tier -cne 'deep' -or
                    [string]$priorState.validation_checkpoint.receipt -cne $validationReceiptPath -or [string]$expectedUnit.status -cne 'validating') {
                    throw 'Historical compatibility Accept does not follow its exact deep passing checkpoint.'
                }
                $expectedState.last_event_id = $eventId
                $expectedState.current_unit = $null
                $expectedState.next_ready_unit = $null
                $expectedState.last_accepted_receipt = $validationReceiptPath
                $expectedUnit.status = 'accepted'
            }
        }
        if ([string]$transition.intent.pre.state.sha256 -cne $priorStateSha256 -or [string]$transition.intent.pre.unit.sha256 -cne $priorUnitSha256) {
            throw "Historical compatibility authority continuation '$eventId' is detached from its predecessor target."
        }
        Assert-HucSameDocument $expectedState $transition.intent.target.state.document "Historical compatibility authority continuation '$eventId' state"
        Assert-HucSameDocument $expectedUnit $transition.intent.target.unit.document "Historical compatibility authority continuation '$eventId' unit"
        $priorState = $transition.intent.target.state.document
        $priorStateSha256 = [string]$transition.intent.target.state.sha256
        $priorUnit = $transition.intent.target.unit.document
        $priorUnitSha256 = [string]$transition.intent.target.unit.sha256
    }

    Assert-HucSameDocument $priorState $LiveState 'Historical compatibility derived live state'
    Assert-HucSameDocument $priorUnit $LiveAuthorityUnit 'Historical compatibility derived live authority unit'
    [pscustomobject][ordered]@{count=$laterRows.Count;terminal_accepted=($laterRows.Count -eq 4)}
}

function Get-HucProfileHash {
    param([object]$Profile)
    Get-MorphospaceCanonicalJsonSha256 $Profile
}

function Get-HucCommandHash {
    param([string]$Command)
    Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Command))
}

function Assert-HucInstructionActionProjection {
    param([Parameter(Mandatory)][object]$Unit,[Parameter(Mandatory)][object[]]$Mappings,[Parameter(Mandatory)][string]$Label)
    $expectedSkills = @('rusty-morphospace','system-engineering')
    if ($Mappings.Count -ne 2) { throw "$Label instruction mappings are missing or broadened." }
    for ($index=0;$index -lt 2;$index++) {
        $mapping = $Mappings[$index]
        $skillId = $expectedSkills[$index]
        if ([string]$mapping.skill_id -cne $skillId -or [string]$mapping.raw_action -cne 'review-no-change' -or
            [string]$mapping.effective_action -cne 'update' -or [string]$mapping.retained_status -cne 'planned') {
            throw "$Label instruction mappings are missing, reordered, or broadened."
        }
        $surfaces = @($Unit.instruction_surfaces | Where-Object { [string]$_.surface_kind -ceq 'skill' -and [string]$_.skill_id -ceq $skillId })
        if ($surfaces.Count -ne 1 -or [string]$surfaces[0].action -cne 'review-no-change' -or [string]$surfaces[0].status -cne 'planned') {
            throw "$Label instruction mapping '$skillId' raw action/status drifted."
        }
    }
}

function New-HucEventBinding {
    param([string]$WorkspaceRoot,[object]$Ledger,[string]$EventId)
    $rows = @($Ledger.rows | Where-Object { [string]$_.document.event_id -ceq $EventId })
    if ($rows.Count -ne 1) { throw "Historical compatibility builder requires one event '$EventId'." }
    $row = $rows[0]
    $transactionId = "$EventId-transition"
    $intent = "receipts/transactions/$transactionId.intent.json"
    $completion = "receipts/transactions/$transactionId.completion.json"
    [pscustomobject][ordered]@{
        event_id=$EventId;sequence=[int]$row.document.sequence;event_sha256=[string]$row.line_sha256
        intent_path=$intent;intent_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $WorkspaceRoot $intent -RequireLeaf)
        completion_path=$completion;completion_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $WorkspaceRoot $completion -RequireLeaf)
    }
}

function New-MorphospaceHistoricalUnitCompatibilityProjection {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ValidationUnitId,
        [Parameter(Mandatory)][string]$WithdrawnUnitId,
        [Parameter(Mandatory)][string]$ReceiptId,
        [string]$Timestamp = ''
    )
    $workspace = (Resolve-Path $WorkspaceRoot).Path
    $projectPath = Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf
    $statePath = Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
    $project = Read-MorphospaceProtocolJson $projectPath
    $state = Read-MorphospaceProtocolJson $statePath
    $authorityUnitId = [string]$state.current_unit
    if (-not $authorityUnitId -or $null -ne $state.next_ready_unit -or $authorityUnitId -in @($ValidationUnitId,$WithdrawnUnitId)) {
        throw 'Historical compatibility builder requires one distinct current unit and no next-ready unit.'
    }
    $authorityPath = "iteration-units/$authorityUnitId.json"
    $validationPath = "iteration-units/$ValidationUnitId.json"
    $withdrawnPath = "iteration-units/$WithdrawnUnitId.json"
    $authorityUnit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $authorityPath -RequireLeaf)
    $validationUnitFile = Resolve-MorphospaceWorkspacePath $workspace $validationPath -RequireLeaf
    $withdrawnUnitFile = Resolve-MorphospaceWorkspacePath $workspace $withdrawnPath -RequireLeaf
    $validationUnit = Read-MorphospaceProtocolJson $validationUnitFile
    $withdrawnUnit = Read-MorphospaceProtocolJson $withdrawnUnitFile
    $ledger = Get-HucLedger $workspace
    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    [void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    $supersessionEventId = "$ValidationUnitId-superseded-by-$authorityUnitId"
    $readyRows = @($ledger.rows | Where-Object { [string]$_.document.unit_id -ceq $WithdrawnUnitId -and [string]$_.document.event_id -cmatch ('^' + [Regex]::Escape($WithdrawnUnitId) + '-ready-[0-9]{4,}$') })
    $withdrawRows = @($ledger.rows | Where-Object { [string]$_.document.unit_id -ceq $WithdrawnUnitId -and [string]$_.document.event_id -cmatch ('^' + [Regex]::Escape($WithdrawnUnitId) + '-ready-withdrawn-[0-9]{4,}$') })
    if ($readyRows.Count -ne 1 -or $withdrawRows.Count -ne 1) { throw 'Historical compatibility builder requires one Ready and one WithdrawReady event for the withdrawn target.' }
    $hostProfiles = @($project.validation_profiles | Where-Object { [string]$_.profile_id -ceq 'host' })
    if ($hostProfiles.Count -ne 1) { throw 'Historical compatibility builder requires exactly one registered host profile.' }
    $focused = @($validationUnit.validation | Where-Object { [string]$_.profile_id -ceq 'focused' })
    $windows = @($validationUnit.validation | Where-Object { [string]$_.profile_id -ceq 'windows-integration' })
    if ($focused.Count -ne 1 -or $windows.Count -ne 1) { throw 'Historical compatibility builder requires the exact focused/windows-integration validation pair.' }
    $eventId = "$ReceiptId-recorded"
    $receiptPath = "receipts/$ReceiptId.json"
    $document = [pscustomobject][ordered]@{
        schema=$script:HucSchema;receipt_id=$ReceiptId;project_id=[string]$project.project_id;authority_unit_id=$authorityUnitId;created_at=$Timestamp
        expected=[pscustomobject][ordered]@{
            project_sha256=Get-MorphospaceCanonicalJsonSha256 $project;state_sha256=Get-MorphospaceCanonicalJsonSha256 $state
            authority_unit_sha256=Get-MorphospaceCanonicalJsonSha256 $authorityUnit;events_sha256=[string]$ledger.sha256;events_length=[int64]$ledger.length
            event_tail_id=[string]$state.last_event_id;current_unit=$authorityUnitId;next_ready_unit=$null
        }
        registered_host_profile=[pscustomobject][ordered]@{profile_id='host';profile_sha256=Get-HucProfileHash $hostProfiles[0]}
        authority_instruction_actions=@(
            [pscustomobject][ordered]@{skill_id='rusty-morphospace';raw_action='review-no-change';effective_action='update';retained_status='planned'},
            [pscustomobject][ordered]@{skill_id='system-engineering';raw_action='review-no-change';effective_action='update';retained_status='planned'}
        )
        targets=@(
            [pscustomobject][ordered]@{
                unit_id=$ValidationUnitId;unit_path=$validationPath;unit_raw_sha256=Get-MorphospaceFileSha256 $validationUnitFile;unit_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $validationUnit
                projection_kind='validation-profile-compatibility';supersession=New-HucEventBinding $workspace $ledger $supersessionEventId
                validation_profiles=@(
                    [pscustomobject][ordered]@{legacy='focused';current='host';command_sha256=Get-HucCommandHash ([string]$focused[0].command)},
                    [pscustomobject][ordered]@{legacy='windows-integration';current='host';command_sha256=Get-HucCommandHash ([string]$windows[0].command)}
                )
            },
            [pscustomobject][ordered]@{
                unit_id=$WithdrawnUnitId;unit_path=$withdrawnPath;unit_raw_sha256=Get-MorphospaceFileSha256 $withdrawnUnitFile;unit_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $withdrawnUnit
                projection_kind='instruction-action-compatibility';ready=New-HucEventBinding $workspace $ledger ([string]$readyRows[0].document.event_id)
                withdraw_ready=New-HucEventBinding $workspace $ledger ([string]$withdrawRows[0].document.event_id)
                instruction_actions=@(
                    [pscustomobject][ordered]@{skill_id='rusty-morphospace';raw_action='review-no-change';effective_action='update';retained_status='planned'},
                    [pscustomobject][ordered]@{skill_id='system-engineering';raw_action='review-no-change';effective_action='update';retained_status='planned'}
                )
            }
        )
        projection_event=[pscustomobject][ordered]@{event_id=$eventId;sequence=[int]$ledger.rows[-1].document.sequence + 1;timestamp=$Timestamp;receipt_path=$receiptPath}
        limitations=[pscustomobject][ordered]@{historical_bytes_mutated=$false;status_inferred=$false;instruction_completion_inferred=$false;instruction_execution_inferred=$false;validation_inferred=$false;acceptance_inferred=$false;publication_authority=$false}
    }
    $document
}

function Test-MorphospaceHistoricalUnitCompatibilityProjection {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [ValidateSet('PreApply','PostApply')][string]$Mode = 'PostApply'
    )
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $workspace = (Resolve-Path $WorkspaceRoot).Path
    $receiptAbsolute = [IO.Path]::GetFullPath($ReceiptPath)
    if (-not [IO.File]::Exists($receiptAbsolute)) { throw 'Historical compatibility receipt is missing.' }
    $raw = Get-Content -Raw -LiteralPath $receiptAbsolute
    if (-not (Test-Json -Json $raw -SchemaFile (Join-Path $repoRoot 'schemas\historical-unit-compatibility-projection-v1.schema.json'))) {
        throw 'Historical compatibility receipt does not satisfy its closed schema.'
    }
    $receipt = Read-MorphospaceProtocolJson $receiptAbsolute
    $workspacePrefix = $workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $expectedReceiptAbsolute = Resolve-MorphospaceWorkspacePath $workspace ([string]$receipt.projection_event.receipt_path)
    if ($Mode -ceq 'PostApply' -and $receiptAbsolute -cne $expectedReceiptAbsolute) { throw 'Applied historical compatibility receipt path is not its declared workspace path.' }
    $project = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf)
    $state = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
    if ([string]$receipt.schema -cne $script:HucSchema -or [string]$receipt.project_id -cne [string]$project.project_id -or
        [string]$receipt.expected.project_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $project)) { throw 'Historical compatibility project identity or hash drifted.' }
    if ([string]$receipt.expected.current_unit -cne [string]$receipt.authority_unit_id -or $null -ne $receipt.expected.next_ready_unit) {
        throw 'Historical compatibility receipt current/next preimage drifted.'
    }
    if ($Mode -ceq 'PreApply' -and ([string]$state.current_unit -cne [string]$receipt.authority_unit_id -or $null -ne $state.next_ready_unit)) {
        throw 'Historical compatibility current/next projection drifted.'
    }
    $authorityPath = "iteration-units/$([string]$receipt.authority_unit_id).json"
    $authorityUnit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $authorityPath -RequireLeaf)
    if ($Mode -ceq 'PreApply' -and ([string]$authorityUnit.status -cnotin @('active','validating') -or
        [string]$receipt.expected.authority_unit_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $authorityUnit))) {
        throw 'Historical compatibility authority unit is not the exact current in-flight unit.'
    }
    if ($Mode -ceq 'PreApply') {
        Assert-HucInstructionActionProjection -Unit $authorityUnit -Mappings @($receipt.authority_instruction_actions) -Label 'Historical compatibility authority'
    }
    $hostProfiles = @($project.validation_profiles | Where-Object { [string]$_.profile_id -ceq 'host' })
    if ($hostProfiles.Count -ne 1 -or [string]$receipt.registered_host_profile.profile_id -cne 'host' -or
        [string]$receipt.registered_host_profile.profile_sha256 -cne (Get-HucProfileHash $hostProfiles[0])) { throw 'Historical compatibility registered host contract drifted.' }
    $ledger = Get-HucLedger $workspace
    $validationTarget = @($receipt.targets)[0]
    $instructionTarget = @($receipt.targets)[1]
    foreach ($target in @($validationTarget,$instructionTarget)) {
        if ([string]$target.unit_id -in @([string]$state.current_unit,[string]$state.next_ready_unit)) { throw "Historical compatibility target '$([string]$target.unit_id)' is current or next-ready." }
        if ([string]$target.unit_path -cne "iteration-units/$([string]$target.unit_id).json") { throw "Historical compatibility target '$([string]$target.unit_id)' path drifted." }
        $targetPath = Resolve-MorphospaceWorkspacePath $workspace ([string]$target.unit_path) -RequireLeaf
        $targetUnit = Read-MorphospaceProtocolJson $targetPath
        if ([string]$target.unit_raw_sha256 -cne (Get-MorphospaceFileSha256 $targetPath) -or [string]$target.unit_canonical_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $targetUnit)) {
            throw "Historical compatibility target '$([string]$target.unit_id)' immutable bytes drifted."
        }
    }

    $validationUnit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$validationTarget.unit_path) -RequireLeaf)
    if ([string]$validationUnit.status -cnotin @('active','validating')) { throw 'Historical validation target is not an immutable superseded in-flight unit.' }
    $expectedLegacyProfiles = @('focused','windows-integration')
    for ($index=0;$index -lt 2;$index++) {
        $mapping = @($validationTarget.validation_profiles)[$index]
        if ([string]$mapping.legacy -cne $expectedLegacyProfiles[$index] -or [string]$mapping.current -cne 'host') { throw 'Historical validation-profile mappings are missing, reordered, or broadened.' }
        $matches = @($validationUnit.validation | Where-Object { [string]$_.profile_id -ceq [string]$mapping.legacy })
        if ($matches.Count -ne 1 -or [string]$mapping.command_sha256 -cne (Get-HucCommandHash ([string]$matches[0].command))) { throw "Historical validation mapping '$([string]$mapping.legacy)' command bytes drifted." }
    }
    $unknownProfiles = @($validationUnit.validation | Where-Object { @($project.validation_profiles.profile_id) -cnotcontains [string]$_.profile_id } | ForEach-Object { [string]$_.profile_id })
    if (($unknownProfiles -join '|') -cne 'focused|windows-integration') { throw 'Historical validation mappings do not exactly cover the unknown profile set.' }
    $supersession = Assert-HucTransitionBinding $workspace $ledger $validationTarget.supersession 'rusty.morphospace.workflow.transition_ledger_intent.v2'
    $supEventId = [string]$validationTarget.supersession.event_id
    if ($supEventId -cne "$([string]$validationTarget.unit_id)-superseded-by-$([string]$receipt.authority_unit_id)" -or
        [string]$supersession.row.document.unit_id -cne [string]$validationTarget.unit_id) { throw 'Historical validation target supersession endpoints drifted.' }
    $supIntent = $supersession.intent
    Assert-MorphospaceExactPropertySet $supIntent.supersession @('old_unit_id','new_unit_id','pre_state','old_unit','target_unit_path') @() 'Historical compatibility supersession binding'
    if ([string]$supIntent.supersession.old_unit_id -cne [string]$validationTarget.unit_id -or [string]$supIntent.supersession.new_unit_id -cne [string]$receipt.authority_unit_id -or
        [string]$supIntent.supersession.target_unit_path -cne $authorityPath -or [string]$supIntent.unit.path -cne $authorityPath) { throw 'Historical compatibility supersession identity binding drifted.' }
    foreach ($bindingName in @('pre_state','old_unit')) { Assert-MorphospaceExactPropertySet $supIntent.supersession.$bindingName @('path','sha256','document') @() "Historical compatibility supersession $bindingName" }
    if ([string]$supIntent.supersession.pre_state.path -cne 'workspace.state.json' -or
        [string]$supIntent.supersession.pre_state.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $supIntent.supersession.pre_state.document) -or
        [string]$supIntent.supersession.pre_state.sha256 -cne [string]$supIntent.pre.state.sha256 -or
        [string]$supIntent.supersession.old_unit.path -cne [string]$validationTarget.unit_path -or
        [string]$supIntent.supersession.old_unit.sha256 -cne [string]$validationTarget.unit_canonical_sha256 -or
        (Get-MorphospaceCanonicalJsonSha256 $supIntent.supersession.old_unit.document) -cne [string]$validationTarget.unit_canonical_sha256) {
        throw 'Historical compatibility supersession pre-state or immutable old-unit binding drifted.'
    }
    if ([string]$supIntent.supersession.pre_state.document.current_unit -cne [string]$validationTarget.unit_id -or
        [string]$supIntent.supersession.pre_state.document.next_ready_unit -cne [string]$receipt.authority_unit_id -or
        [string]$supIntent.target.state.document.current_unit -cne [string]$receipt.authority_unit_id -or $null -ne $supIntent.target.state.document.next_ready_unit -or
        [string]$supIntent.target.unit.document.unit_id -cne [string]$receipt.authority_unit_id -or [string]$supIntent.target.unit.document.status -cne 'active') {
        throw 'Historical compatibility supersession state/unit target is not the exact ready-to-active replacement projection.'
    }
    $readyAuthority = Copy-HucDocument $supIntent.target.unit.document
    $readyAuthority.status = 'ready'
    if ((Get-MorphospaceCanonicalJsonSha256 $readyAuthority) -cne [string]$supIntent.pre.unit.sha256) { throw 'Historical compatibility supersession pre-unit is not the exact ready form of its replacement.' }

    $instructionUnit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace ([string]$instructionTarget.unit_path) -RequireLeaf)
    if ([string]$instructionUnit.status -cne 'proposed') { throw 'Historical instruction target is not the exact withdrawn proposed unit.' }
    Assert-HucInstructionActionProjection -Unit $instructionUnit -Mappings @($instructionTarget.instruction_actions) -Label 'Historical withdrawn-unit'
    $ready = Assert-HucTransitionBinding $workspace $ledger $instructionTarget.ready 'rusty.morphospace.workflow.transition_ledger_intent.v1'
    $withdrawReceiptPath = if (@($ledger.rows | Where-Object { [string]$_.document.event_id -ceq [string]$instructionTarget.withdraw_ready.event_id }).Count -eq 1) {
        [string]@(@($ledger.rows | Where-Object { [string]$_.document.event_id -ceq [string]$instructionTarget.withdraw_ready.event_id })[0].document.receipts)[0]
    } else { '' }
    if (-not $withdrawReceiptPath) { throw 'Historical WithdrawReady event lacks its one receipt.' }
    $withdraw = Assert-HucTransitionBinding $workspace $ledger $instructionTarget.withdraw_ready 'rusty.morphospace.workflow.transition_ledger_intent.v1' $withdrawReceiptPath
    if ([int]$withdraw.row.ordinal -ne [int]$ready.row.ordinal + 1 -or [string]$withdraw.intent.pre.state.sha256 -cne [string]$ready.intent.target.state.sha256 -or
        [string]$withdraw.intent.pre.unit.sha256 -cne [string]$ready.intent.target.unit.sha256) { throw 'Historical Ready-to-WithdrawReady chain is detached.' }
    $expectedReadyId = "$([string]$instructionTarget.unit_id)-ready-$('{0:D4}' -f [int]$ready.row.document.sequence)"
    $expectedWithdrawId = "$([string]$instructionTarget.unit_id)-ready-withdrawn-$('{0:D4}' -f [int]$withdraw.row.document.sequence)"
    if ([string]$ready.row.document.event_id -cne $expectedReadyId -or [string]$withdraw.row.document.event_id -cne $expectedWithdrawId -or
        [string]$ready.row.document.unit_id -cne [string]$instructionTarget.unit_id -or [string]$withdraw.row.document.unit_id -cne [string]$instructionTarget.unit_id -or
        [string]$ready.intent.target.unit.document.status -cne 'ready' -or [string]$withdraw.intent.target.unit.document.status -cne 'proposed' -or
        [string]$ready.intent.target.state.document.next_ready_unit -cne [string]$instructionTarget.unit_id -or $null -ne $withdraw.intent.target.state.document.next_ready_unit -or
        [string]$ready.intent.target.state.document.current_unit -cne [string]$withdraw.intent.target.state.document.current_unit) {
        throw 'Historical Ready/WithdrawReady endpoint projection drifted.'
    }
    $expectedWithdrawUnit = Copy-HucDocument $ready.intent.target.unit.document
    $expectedWithdrawUnit.status = 'proposed'
    Assert-HucSameDocument $expectedWithdrawUnit $withdraw.intent.target.unit.document 'Historical WithdrawReady target unit'
    $expectedWithdrawState = Copy-HucDocument $ready.intent.target.state.document
    $expectedWithdrawState.next_ready_unit = $null
    $expectedWithdrawState.last_event_id = [string]$withdraw.row.document.event_id
    Assert-HucSameDocument $expectedWithdrawState $withdraw.intent.target.state.document 'Historical WithdrawReady target state'
    $withdrawReceipt = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $withdrawReceiptPath -RequireLeaf)
    if ([string]$withdrawReceipt.schema -cne 'rusty.morphospace.workflow.work_unit_automation_receipt.v1' -or [string]$withdrawReceipt.action -cne 'WithdrawReady' -or
        [string]$withdrawReceipt.unit_id -cne [string]$instructionTarget.unit_id -or [string]$withdrawReceipt.event_id -cne [string]$withdraw.row.document.event_id -or
        [string]$withdrawReceipt.ready_withdrawal.original_ready_event.event_id -cne [string]$ready.row.document.event_id -or
        [string]$withdrawReceipt.ready_withdrawal.original_ready_event.sha256 -cne [string]$ready.row.line_sha256 -or
        [string]$withdrawReceipt.ready_withdrawal.original_ready_transaction.intent.sha256 -cne [string]$instructionTarget.ready.intent_sha256 -or
        [string]$withdrawReceipt.ready_withdrawal.original_ready_transaction.completion.sha256 -cne [string]$instructionTarget.ready.completion_sha256 -or
        $withdrawReceipt.ready_withdrawal.original_ready_event_preserved -ne $true) {
        throw 'Historical WithdrawReady receipt does not authenticate the exact original Ready transaction.'
    }

    $eventId = [string]$receipt.projection_event.event_id
    $receiptRelative = [string]$receipt.projection_event.receipt_path
    if ($eventId -cne "$([string]$receipt.receipt_id)-recorded" -or $receiptRelative -cne "receipts/$([string]$receipt.receipt_id).json") {
        throw 'Historical compatibility projection event identity/path drifted.'
    }
    if ($Mode -ceq 'PreApply') {
        if ([string]$receipt.expected.state_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $state) -or [string]$receipt.expected.events_sha256 -cne [string]$ledger.sha256 -or
            [int64]$receipt.expected.events_length -ne [int64]$ledger.length -or [string]$receipt.expected.event_tail_id -cne [string]$state.last_event_id -or
            [int]$receipt.projection_event.sequence -ne [int]$ledger.rows[-1].document.sequence + 1) { throw 'Historical compatibility pre-apply current-state or ledger CAS drifted.' }
        if (@($ledger.rows | Where-Object { [string]$_.document.event_id -ceq $eventId }).Count -ne 0) { throw 'Historical compatibility projection event already exists.' }
    } else {
        $projectionRows = @($ledger.rows | Where-Object { [string]$_.document.event_id -ceq $eventId })
        if ($projectionRows.Count -ne 1) { throw 'Historical compatibility projection event is missing or ambiguous.' }
        $projectionEvent = $projectionRows[0].document
        if ([string]$projectionEvent.schema -cne 'rusty.morphospace.workflow.iteration_event.v1' -or
            [int]$projectionEvent.sequence -ne [int]$receipt.projection_event.sequence -or
            [string]$projectionEvent.timestamp -cne [string]$receipt.projection_event.timestamp -or
            [string]$projectionEvent.project_id -cne [string]$receipt.project_id -or
            [string]$projectionEvent.unit_id -cne [string]$receipt.authority_unit_id -or
            [string]$projectionEvent.event_type -cne 'state-transition' -or [string]$projectionEvent.summary -cne $script:HucSummary -or
            @($projectionEvent.receipts).Count -ne 1 -or [string]@($projectionEvent.receipts)[0] -cne $receiptRelative) {
            throw 'Historical compatibility projection event fields drifted.'
        }
        $projectionBinding = [pscustomobject][ordered]@{
            event_id=$eventId;sequence=[int]$receipt.projection_event.sequence
            event_sha256=[string]$projectionRows[0].line_sha256
            intent_path="receipts/transactions/$eventId-transition.intent.json";intent_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$eventId-transition.intent.json" -RequireLeaf)
            completion_path="receipts/transactions/$eventId-transition.completion.json";completion_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $workspace "receipts/transactions/$eventId-transition.completion.json" -RequireLeaf)
        }
        $projection = Assert-HucTransitionBinding $workspace $ledger $projectionBinding 'rusty.morphospace.workflow.transition_ledger_intent.v1' $receiptRelative
        if ([string]$projection.intent.pre.state.sha256 -cne [string]$receipt.expected.state_sha256 -or [string]$projection.intent.pre.unit.sha256 -cne [string]$receipt.expected.authority_unit_sha256 -or
            [string]$projection.intent.expected.events_sha256 -cne [string]$receipt.expected.events_sha256 -or [int64]$projection.intent.expected.events_length -ne [int64]$receipt.expected.events_length -or
            [string]$projection.intent.expected.event_tail_id -cne [string]$receipt.expected.event_tail_id) { throw 'Historical compatibility projection transaction detached from receipt preimages.' }
        if ([string]$receipt.expected.state_sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $supIntent.target.state.document)) {
            throw 'Historical compatibility projection pre-state is detached from the authenticated supersession target.'
        }
        Assert-HucStateOnlyTailChanged $supIntent.target.state.document $projection.intent.target.state.document $eventId 'Historical compatibility projected state'
        if ([string]$projection.intent.target.state.document.current_unit -cne [string]$receipt.authority_unit_id -or
            $null -ne $projection.intent.target.state.document.next_ready_unit -or
            [string]$projection.intent.target.unit.document.status -cne 'active' -or
            [string]$projection.intent.target.unit.sha256 -cne [string]$receipt.expected.authority_unit_sha256) {
            throw 'Historical compatibility projection does not preserve the exact active authority target.'
        }
        Assert-HucInstructionActionProjection -Unit $projection.intent.target.unit.document -Mappings @($receipt.authority_instruction_actions) -Label 'Historical compatibility authority'
        $continuation = Assert-HucOwnerClosureContinuation -WorkspaceRoot $workspace -Ledger $ledger -Projection $projection `
            -Receipt $receipt -LiveState $state -LiveAuthorityUnit $authorityUnit
    }
    [pscustomobject][ordered]@{
        receipt=$receipt;receipt_sha256=Get-MorphospaceFileSha256 $receiptAbsolute
        validation_unit_id=[string]$validationTarget.unit_id;validation_profiles=@($validationTarget.validation_profiles)
        instruction_unit_id=[string]$instructionTarget.unit_id;instruction_actions=@($instructionTarget.instruction_actions)
        authority_instruction_actions=@($receipt.authority_instruction_actions)
        authority_unit_id=[string]$receipt.authority_unit_id;authenticated=$true;mode=$Mode
        continuation_event_count=$(if($Mode -ceq 'PostApply'){[int]$continuation.count}else{0})
        terminal_accepted=$(if($Mode -ceq 'PostApply'){[bool]$continuation.terminal_accepted}else{$false})
        acceptance_inferred=$false;instruction_execution_inferred=$false;publication_authority=$false
    }
}

function Get-MorphospaceHistoricalUnitCompatibilityProjectionMap {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ProjectId)
    $workspace = (Resolve-Path $WorkspaceRoot).Path
    $ledgerPath = Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
    if ([IO.FileInfo]::new($ledgerPath).Length -eq 0) { return @{} }
    $ledger = Get-HucLedger $workspace
    $map = @{}
    $events = @($ledger.rows | Where-Object { [string]$_.document.summary -ceq $script:HucSummary })
    foreach ($row in $events) {
        if (@($row.document.receipts).Count -ne 1 -or @($row.document.receipts)[0] -isnot [string]) { throw "Historical compatibility event '$([string]$row.document.event_id)' lacks one receipt path." }
        $receiptRelative = ConvertTo-MorphospaceProtocolRelativePath ([string]@($row.document.receipts)[0])
        $validated = Test-MorphospaceHistoricalUnitCompatibilityProjection -WorkspaceRoot $workspace -ReceiptPath (Resolve-MorphospaceWorkspacePath $workspace $receiptRelative -RequireLeaf) -Mode PostApply
        if ([string]$validated.receipt.project_id -cne $ProjectId) { throw "Historical compatibility receipt '$receiptRelative' belongs to another project." }
        foreach ($entry in @(
            [pscustomobject]@{unit_id=[string]$validated.validation_unit_id;kind='validation';mappings=@($validated.validation_profiles);receipt=$receiptRelative},
            [pscustomobject]@{unit_id=[string]$validated.instruction_unit_id;kind='instruction';mappings=@($validated.instruction_actions);receipt=$receiptRelative},
            [pscustomobject]@{unit_id=[string]$validated.authority_unit_id;kind='instruction';mappings=@($validated.authority_instruction_actions);receipt=$receiptRelative}
        )) {
            if ($map.ContainsKey([string]$entry.unit_id)) { throw "Historical compatibility unit '$([string]$entry.unit_id)' has more than one projection." }
            $map[[string]$entry.unit_id] = $entry
        }
    }
    $map
}

Export-ModuleMember -Function New-MorphospaceHistoricalUnitCompatibilityProjection,Test-MorphospaceHistoricalUnitCompatibilityProjection,Get-MorphospaceHistoricalUnitCompatibilityProjectionMap
