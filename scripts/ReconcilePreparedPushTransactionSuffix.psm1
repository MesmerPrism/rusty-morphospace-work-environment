Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlannedPublication.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\ExternalOwnerAuthorization.psm1') -Force

function Copy-PreparedPushSuffixValue {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String)
}

function Invoke-PreparedPushSuffixGit {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Repository @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Prepared-push suffix Git observation failed: git $($Arguments -join ' ')"
    }
    return [pscustomobject]@{
        code = $code
        lines = @($output | ForEach-Object { ([string]$_).TrimEnd("`r") })
        text = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    }
}

function Get-PreparedPushSuffixGitBlobBytes {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][string]$Path
    )
    $blob = (Invoke-PreparedPushSuffixGit $Repository @('rev-parse',"$Revision`:$Path")).text
    if ($blob -cnotmatch '^[0-9a-f]{40}$') { throw "Git blob identity is invalid for '$Path'." }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $start.ArgumentList.Add('-C')
    $start.ArgumentList.Add($Repository)
    $start.ArgumentList.Add('cat-file')
    $start.ArgumentList.Add('blob')
    $start.ArgumentList.Add($blob)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "Could not start Git blob read for '$Path'." }
    $memory = [IO.MemoryStream]::new()
    try {
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [void]$copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Git blob read failed for '$Path': $errorText" }
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Get-PreparedPushSuffixAuthorizationScope {
    param([Parameter(Mandatory)][object]$Document)
    return [pscustomobject][ordered]@{
        '$schema' = [string]$Document.'$schema'
        schema = [string]$Document.schema
        reconciliation_id = [string]$Document.reconciliation_id
        project_id = [string]$Document.project_id
        unit_id = [string]$Document.unit_id
        bundle_id = [string]$Document.bundle_id
        reason = [string]$Document.reason
        expected = Copy-PreparedPushSuffixValue $Document.expected
        prepared_plan = Copy-PreparedPushSuffixValue $Document.prepared_plan
        prepared_event = Copy-PreparedPushSuffixValue $Document.prepared_event
        executed_push_receipt = Copy-PreparedPushSuffixValue $Document.executed_push_receipt
        planned_publication_accounting = Copy-PreparedPushSuffixValue $Document.planned_publication_accounting
        source_repositories = @(Copy-PreparedPushSuffixValue @($Document.source_repositories))
        planning_transport = Copy-PreparedPushSuffixValue $Document.planning_transport
        workspace_transition = Copy-PreparedPushSuffixValue $Document.workspace_transition
        preservation = Copy-PreparedPushSuffixValue $Document.preservation
        failure = $null
    }
}

function Assert-PreparedPushSuffixFileBinding {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][object]$Binding,
        [Parameter(Mandatory)][string]$Context
    )
    $relative = ConvertTo-MorphospaceProtocolRelativePath ([string]$Binding.path)
    if ($relative -cne [string]$Binding.path) { throw "$Context path is not canonical." }
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath $relative
    if (-not [IO.File]::Exists($path)) { throw "$Context is missing: $relative" }
    if ([IO.FileInfo]::new($path).Length -ne [int64]$Binding.bytes) { throw "$Context byte length mismatch." }
    if ((Get-MorphospaceFileSha256 $path) -cne [string]$Binding.sha256) { throw "$Context SHA-256 mismatch." }
    return $path
}

function Assert-PreparedPushSuffixJsonSchema {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$Context
    )
    $raw = Get-Content -Raw -LiteralPath $Path
    if (-not (Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction Stop)) { throw "$Context failed its schema." }
}

function Get-PreparedPushSuffixEvents {
    param([Parameter(Mandatory)][string]$Path)
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $bytes = [Text.UTF8Encoding]::new($false,$true).GetBytes($line)
        $events.Add((ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context 'iteration event line')) | Out-Null
    }
    if ($events.Count -eq 0) { throw 'Prepared-push suffix reconciliation requires a non-empty event ledger.' }
    return @($events.ToArray())
}

function Get-PreparedPushSuffixRepositoryMap {
    param(
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    $resolved = (Resolve-Path -LiteralPath $RepoMapPath).Path
    Assert-PreparedPushSuffixJsonSchema $resolved (Join-Path $RepositoryRoot 'schemas\repository-map.schema.json') 'Repository map'
    $document = Read-MorphospaceProtocolJson $resolved
    $map = @{}
    $folded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($document.repositories)) {
        $id = [string]$entry.repo_id
        if (-not $folded.Add($id)) { throw 'Repository map contains duplicate or case-fold duplicate IDs.' }
        $path = (Resolve-Path -LiteralPath ([string]$entry.path)).Path
        $map[$id] = [pscustomobject]@{ repo_id=$id; role=[string]$entry.role; path=$path }
    }
    return $map
}

function Assert-PreparedPushSuffixAuthorization {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$PolicyPath = '',
        [string]$PolicySchemaPath = '',
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )
    if (-not $PolicyPath) { $PolicyPath = Join-Path $RepositoryRoot 'config\external-owner-authorization.json' }
    if (-not $PolicySchemaPath) { $PolicySchemaPath = Join-Path $RepositoryRoot 'schemas\external-owner-authorization-policy-v1.schema.json' }
    $policy = Read-ExternalOwnerAuthorizationPolicy -Path $PolicyPath -SchemaPath $PolicySchemaPath
    $scope = Get-PreparedPushSuffixAuthorizationScope $Document
    [byte[]]$scopeBytes = Get-CanonicalAuthorizationBytes $scope
    $scopeHash = Get-ExternalOwnerSha256 $scopeBytes
    $payload = $Document.authorization.payload
    foreach ($pair in @(
        @('issuer',[string]$policy.issuer_id,[string]$payload.issuer_id),
        @('project',[string]$Document.project_id,[string]$payload.project_id),
        @('unit',[string]$Document.unit_id,[string]$payload.unit_id),
        @('bundle',[string]$Document.bundle_id,[string]$payload.bundle_id),
        @('scope SHA-256',$scopeHash,[string]$payload.scope_sha256)
    )) { if ($pair[1] -cne $pair[2]) { throw "Prepared-push suffix authorization $($pair[0]) mismatch." } }
    $expectedLimitations = @(
        'matching_pending_bundle_only',
        'preserve_existing_evidence_bytes',
        'workflow_state_only',
        'git_mutation=false',
        'acceptance_mutation=false',
        'publication_authority=false'
    )
    if ((@($payload.limitations) -join '|') -cne ($expectedLimitations -join '|')) { throw 'Prepared-push suffix authorization limitations are not exact.' }
    if ([string]$Document.authorization.signature.algorithm -cne 'RSA-PSS-SHA256' -or
        [string]$Document.authorization.signature.public_key_spki_sha256 -cne [string]$policy.public_key_spki_sha256) {
        throw 'Prepared-push suffix authorization signature identity is not pinned.'
    }
    try {
        $issued = [datetimeoffset]::ParseExact([string]$payload.issued_at,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $expires = [datetimeoffset]::ParseExact([string]$payload.expires_at,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
    } catch { throw 'Prepared-push suffix authorization timestamps are not strict UTC seconds.' }
    if ($issued -gt $Now.AddSeconds([int]$policy.max_future_skew_seconds) -or
        $issued -lt $Now.AddSeconds(-[int]$policy.max_authorization_age_seconds) -or
        $expires -le $Now -or $expires -le $issued -or
        $expires -gt $issued.AddSeconds([int]$policy.max_authorization_age_seconds)) {
        throw 'Prepared-push suffix authorization freshness is invalid.'
    }
    try { [byte[]]$signature = [Convert]::FromBase64String([string]$Document.authorization.signature.value_base64) }
    catch { throw 'Prepared-push suffix authorization signature is not base64.' }
    if ([Convert]::ToBase64String($signature) -cne [string]$Document.authorization.signature.value_base64) { throw 'Prepared-push suffix authorization signature is not canonical base64.' }
    [byte[]]$payloadBytes = Get-CanonicalAuthorizationBytes $payload
    if (-not [RustyMorphospace.ExternalOwnerCrypto]::Verify([string]$policy.public_key_pem,$payloadBytes,$signature)) {
        throw 'Prepared-push suffix authorization signature verification failed.'
    }
    return [pscustomobject]@{ scope=$scope; scope_sha256=$scopeHash; authorization_id=[string]$payload.authorization_id }
}

function Assert-PreparedPushSuffixExactBytePrefix {
    param([Parameter(Mandatory)][byte[]]$Prefix,[Parameter(Mandatory)][byte[]]$Value)
    if ($Value.Length -le $Prefix.Length) { throw 'Current event ledger does not contain one appended PreparePush event.' }
    for ($index=0; $index -lt $Prefix.Length; $index++) {
        if ($Prefix[$index] -ne $Value[$index]) { throw 'PreparePush changed historical event-ledger bytes.' }
    }
    [byte[]]$suffix = $Value[$Prefix.Length..($Value.Length-1)]
    if ($suffix.Length -lt 3 -or $suffix[-1] -ne 10 -or $suffix -contains 13) { throw 'PreparePush event suffix must be one LF-terminated line.' }
    $text = [Text.UTF8Encoding]::new($false,$true).GetString($suffix)
    if (($text.Substring(0,$text.Length-1)).Contains("`n")) { throw 'PreparePush event suffix contains more than one line.' }
    return ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $suffix[0..($suffix.Length-2)] -Context 'PreparePush event suffix'
}

function Test-MorphospacePreparedPushTransactionSuffixReconciliation {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$Reconciliation,
        [string]$AuthorizationPolicyPath = '',
        [string]$AuthorizationPolicySchemaPath = '',
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $inputPath = (Resolve-Path -LiteralPath $Reconciliation).Path
    if ([IO.FileInfo]::new($inputPath).Length -gt 16777216) { throw 'Prepared-push suffix reconciliation exceeds 16 MiB.' }
    Assert-PreparedPushSuffixJsonSchema $inputPath (Join-Path $repositoryRoot 'schemas\prepared-push-transaction-suffix-reconciliation-v1.schema.json') 'Prepared-push suffix reconciliation'
    $document = Read-MorphospaceProtocolJson $inputPath
    if ([string]$document.unit_id -cne $UnitId) { throw 'Prepared-push suffix reconciliation unit does not match the requested unit.' }
    $authorization = Assert-PreparedPushSuffixAuthorization $document $repositoryRoot $AuthorizationPolicyPath $AuthorizationPolicySchemaPath $Now

    $map = Get-PreparedPushSuffixRepositoryMap $RepoMapPath $repositoryRoot
    $sourceIds = @($document.source_repositories | ForEach-Object { [string]$_.repo_id })
    if (($sourceIds -join '|') -cne (@($sourceIds | Sort-Object -CaseSensitive -Unique) -join '|')) { throw 'Source repository bindings must be unique and ordinal sorted.' }
    $planningId = [string]$document.planning_transport.repo_id
    if ($sourceIds -contains $planningId) { throw 'Planning transport cannot also be a source repository.' }
    foreach ($id in @($sourceIds) + @($planningId)) {
        if (-not $map.ContainsKey($id)) { throw "Repository '$id' is not mapped." }
    }
    if ([string]$map[$planningId].role -cne 'planning') { throw 'Planning transport repository must use the planning map role.' }
    foreach ($id in $sourceIds) { if ([string]$map[$id].role -cne 'source') { throw "Source repository '$id' must use the source map role." } }
    $planningRoot = [string]$map[$planningId].path
    $planningPrefix = $planningRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $workspace.StartsWith($planningPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Workspace is not contained by the declared planning transport repository.' }
    $workspaceRelative = [IO.Path]::GetRelativePath($planningRoot,$workspace).Replace('\','/')
    if (-not $inputPath.StartsWith((Join-Path $planningRoot 'local').TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Signed reconciliation input must be in the planning repository local control space.'
    }
    Assert-MorphospaceNoReparseAncestor -Root $planningRoot -Candidate $inputPath

    $projectPath = Join-Path $workspace 'project.spec.json'
    $statePath = Join-Path $workspace 'workspace.state.json'
    $eventsPath = Join-Path $workspace 'iteration-events.jsonl'
    $unitRelative = "iteration-units/$UnitId.json"
    $unitPath = Join-Path $workspace ($unitRelative -replace '/','\')
    $project = Read-MorphospaceProtocolJson $projectPath
    $state = Read-MorphospaceProtocolJson $statePath
    $unit = Read-MorphospaceProtocolJson $unitPath
    $projectSchema = switch ([string]$project.schema) {
        'rusty.morphospace.workflow.project_spec.v1' { 'project-spec.schema.json' }
        'rusty.morphospace.workflow.project_spec.v2' { 'project-spec-v2.schema.json' }
        default { throw 'Prepared-push suffix project specification schema is unsupported.' }
    }
    $stateSchema = switch ([string]$state.schema) {
        'rusty.morphospace.workflow.workspace_state.v1' { 'workspace-state.schema.json' }
        'rusty.morphospace.workflow.workspace_state.v2' { 'workspace-state-v2.schema.json' }
        default { throw 'Prepared-push suffix workspace state schema is unsupported.' }
    }
    Assert-PreparedPushSuffixJsonSchema $projectPath (Join-Path $repositoryRoot "schemas\$projectSchema") 'Project specification'
    Assert-PreparedPushSuffixJsonSchema $statePath (Join-Path $repositoryRoot "schemas\$stateSchema") 'Workspace state'
    Assert-PreparedPushSuffixJsonSchema $unitPath (Join-Path $repositoryRoot 'schemas\iteration-unit.schema.json') 'Iteration unit'
    if ([string]$document.project_id -cne [string]$project.project_id -or [string]$state.project_id -cne [string]$project.project_id -or [string]$unit.project_id -cne [string]$project.project_id) { throw 'Prepared-push suffix project identity mismatch.' }
    if ([string]$unit.unit_id -cne $UnitId -or [string]$unit.status -cne 'accepted' -or $null -ne $state.current_unit) { throw 'Prepared-push suffix reconciliation requires the exact accepted non-current unit.' }
    if ($null -eq $state.pending_push_bundle -or [string]$state.pending_push_bundle.bundle_id -cne [string]$document.bundle_id -or [string]$document.workspace_transition.pending_push_bundle_before -cne [string]$document.bundle_id) { throw 'Prepared-push suffix reconciliation does not match the pending bundle.' }

    $unitRawHash = Get-MorphospaceFileSha256 $unitPath
    $unitCanonicalHash = Get-MorphospaceCanonicalJsonSha256 $unit
    $stateRawHash = Get-MorphospaceFileSha256 $statePath
    $stateCanonicalHash = Get-MorphospaceCanonicalJsonSha256 $state
    $eventsHash = Get-MorphospaceFileSha256 $eventsPath
    $eventsLength = [IO.FileInfo]::new($eventsPath).Length
    $events = Get-PreparedPushSuffixEvents $eventsPath
    $tail = $events[-1]
    foreach ($binding in @(
        @('unit raw SHA-256',[string]$document.expected.unit_raw_sha256,$unitRawHash),
        @('unit canonical SHA-256',[string]$document.expected.unit_canonical_sha256,$unitCanonicalHash),
        @('state raw SHA-256',[string]$document.expected.state_raw_sha256,$stateRawHash),
        @('state canonical SHA-256',[string]$document.expected.state_canonical_sha256,$stateCanonicalHash),
        @('event-ledger SHA-256',[string]$document.expected.events_sha256,$eventsHash),
        @('event tail',[string]$document.expected.event_tail_id,[string]$tail.event_id)
    )) { if ($binding[1] -cne $binding[2]) { throw "Prepared-push suffix expected $($binding[0]) mismatch." } }
    if ([int64]$document.expected.events_length -ne $eventsLength -or [string]$state.last_event_id -cne [string]$tail.event_id) { throw 'Prepared-push suffix event length or state-tail binding mismatch.' }

    $planPath = Assert-PreparedPushSuffixFileBinding $workspace $document.prepared_plan.container 'PreparePush plan container'
    $intentPath = Assert-PreparedPushSuffixFileBinding $workspace $document.prepared_event.intent 'PreparePush transition intent'
    $completionPath = Assert-PreparedPushSuffixFileBinding $workspace $document.prepared_event.completion 'PreparePush transition completion'
    $executedPath = Assert-PreparedPushSuffixFileBinding $workspace $document.executed_push_receipt 'Executed-push receipt'
    $accountingPath = Assert-PreparedPushSuffixFileBinding $workspace $document.planned_publication_accounting 'Planned-publication accounting'
    $planContainer = Read-MorphospaceProtocolJson $planPath
    $intent = Read-MorphospaceProtocolJson $intentPath
    $completion = Read-MorphospaceProtocolJson $completionPath
    $executed = Read-MorphospaceProtocolJson $executedPath
    $accountingValidation = Test-MorphospacePlannedPublicationDocument -Path $accountingPath -WorkspaceRoot $workspace
    $accounting = $accountingValidation.document
    if ([string]$planContainer.action -cne 'PreparePush' -or $planContainer.executed -ne $true -or [string]$planContainer.unit_id -cne $UnitId -or [string]$planContainer.push_plan.bundle_id -cne [string]$document.bundle_id) { throw 'PreparePush plan container identity is invalid.' }
    if ([string]$accounting.trigger_unit_id -cne $UnitId -or [string]$accounting.bundle_id -cne [string]$document.bundle_id -or [string]$executed.bundle_id -cne [string]$document.bundle_id) { throw 'Publication evidence bundle/unit identity mismatch.' }
    if ((@($state.pending_push_bundle.unit_ids) -join '|') -cne (@($planContainer.push_plan.unit_ids) -join '|') -or (@($state.pending_push_bundle.repo_ids) -join '|') -cne (@($planContainer.push_plan.dependency_order) -join '|')) { throw 'Pending bundle does not exactly match the prepared plan.' }
    $expectedOrder = @($sourceIds) + @($planningId)
    if ((@($planContainer.push_plan.dependency_order) -join '|') -cne ($expectedOrder -join '|') -or (@($executed.dependency_order) -join '|') -cne ($expectedOrder -join '|') -or (@($executed.execution_order) -join '|') -cne ($expectedOrder -join '|')) { throw 'Prepared/executed repository order is not exact.' }

    if ([string]$document.prepared_event.transaction_id -cne [string]$intent.transaction_id -or [string]$intent.transaction_id -cne [string]$completion.transaction_id -or [string]$document.prepared_event.event_id -cne [string]$intent.event.event_id -or [string]$intent.event.event_id -cne [string]$completion.event_id -or [string]$tail.event_id -cne [string]$intent.event.event_id) { throw 'PreparePush transition event/transaction identity mismatch.' }
    if ([string]$completion.status -cne 'committed' -or [string]$completion.intent.path -cne [string]$document.prepared_event.intent.path -or [string]$completion.intent.sha256 -cne [string]$document.prepared_event.intent.sha256) { throw 'PreparePush transition completion is not exact and committed.' }
    if ((Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document) -cne $stateCanonicalHash -or [string]$intent.target.state.sha256 -cne $stateCanonicalHash -or [string]$completion.state_sha256 -cne $stateCanonicalHash -or (Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document) -cne $unitCanonicalHash -or [string]$intent.target.unit.sha256 -cne $unitCanonicalHash -or [string]$completion.unit_sha256 -cne $unitCanonicalHash) { throw 'PreparePush transition target hashes do not equal the current state/unit.' }
    if (@($intent.artifacts).Count -ne 1 -or [string]$intent.artifacts[0].path -cne [string]$document.prepared_plan.container.path -or [string]$intent.artifacts[0].sha256 -cne [string]$document.prepared_plan.container.sha256) { throw 'PreparePush transition does not own exactly the bound plan artifact.' }

    [byte[]]$baseStateBytes = Get-PreparedPushSuffixGitBlobBytes $planningRoot 'HEAD' "$workspaceRelative/workspace.state.json"
    [byte[]]$baseEventsBytes = Get-PreparedPushSuffixGitBlobBytes $planningRoot 'HEAD' "$workspaceRelative/iteration-events.jsonl"
    $baseState = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baseStateBytes -Context 'planning HEAD workspace state'
    $projectedState = Copy-PreparedPushSuffixValue $baseState
    $projectedState.pending_push_bundle = Copy-PreparedPushSuffixValue $state.pending_push_bundle
    $projectedState.last_event_id = [string]$state.last_event_id
    if ((Get-MorphospaceCanonicalJsonSha256 $projectedState) -cne $stateCanonicalHash) { throw 'Current state differs from planning HEAD by more than the exact PreparePush bundle and last event.' }
    [byte[]]$currentEventsBytes = [IO.File]::ReadAllBytes($eventsPath)
    $suffixEvent = Assert-PreparedPushSuffixExactBytePrefix $baseEventsBytes $currentEventsBytes
    if ((Get-MorphospaceCanonicalJsonSha256 $suffixEvent) -cne (Get-MorphospaceCanonicalJsonSha256 $intent.event)) { throw 'PreparePush ledger suffix does not equal the transition event.' }
    if ([string]$intent.pre.state.sha256 -cne (Get-MorphospaceCanonicalJsonSha256 $baseState) -or [string]$intent.pre.unit.sha256 -cne $unitCanonicalHash -or [string]$intent.expected.events_sha256 -cne (Get-MorphospaceSha256Bytes $baseEventsBytes) -or [int64]$intent.expected.events_length -ne $baseEventsBytes.Length) { throw 'PreparePush transition pre-state or pre-ledger binding mismatch.' }

    foreach ($source in @($document.source_repositories)) {
        $id = [string]$source.repo_id
        $root = [string]$map[$id].path
        $statusResult = Invoke-PreparedPushSuffixGit $root @('status','--porcelain=v1','--untracked-files=all')
        $status = @($statusResult.lines | Where-Object { $_ })
        if ($status.Count -ne 0) { throw "Source repository '$id' is dirty." }
        foreach ($pair in @(
            @('branch',[string]$source.branch,(Invoke-PreparedPushSuffixGit $root @('branch','--show-current')).text),
            @('head',[string]$source.revision,(Invoke-PreparedPushSuffixGit $root @('rev-parse','HEAD')).text),
            @('tree',[string]$source.tree,(Invoke-PreparedPushSuffixGit $root @('show','-s','--format=%T','HEAD')).text),
            @('upstream',[string]$source.upstream,(Invoke-PreparedPushSuffixGit $root @('rev-parse','--abbrev-ref','@{upstream}')).text),
            @('remote readback',[string]$source.revision,(Invoke-PreparedPushSuffixGit $root @('rev-parse','@{upstream}')).text)
        )) { if ($pair[1] -cne $pair[2]) { throw "Source repository '$id' $($pair[0]) mismatch." } }
        $parents = @((Invoke-PreparedPushSuffixGit $root @('show','-s','--format=%P','HEAD')).text -split ' ' | Where-Object { $_ })
        if ($parents.Count -ne 1 -or $parents[0] -cne [string]$source.parent_revision) { throw "Source repository '$id' is not the exact one-parent commit." }
        $planRepo = @($planContainer.push_plan.repositories | Where-Object { [string]$_.repo_id -ceq $id })
        $executedRepo = @($executed.repositories | Where-Object { [string]$_.repo_id -ceq $id })
        $accountingRepo = @($accounting.repositories | Where-Object { [string]$_.repo_id -ceq $id })
        if ($planRepo.Count -ne 1 -or $executedRepo.Count -ne 1 -or $accountingRepo.Count -ne 1 -or
            [string]$planRepo[0].commit -cne [string]$source.revision -or
            [string]$executedRepo[0].role -cne 'source-owner' -or [string]$executedRepo[0].action -cne 'pushed' -or
            [string]$executedRepo[0].branch -cne [string]$source.branch -or [string]$executedRepo[0].upstream -cne [string]$source.upstream -or
            [string]$executedRepo[0].old_revision -cne [string]$source.parent_revision -or
            [string]$executedRepo[0].new_revision -cne [string]$source.revision -or [string]$executedRepo[0].observed_remote_revision -cne [string]$source.revision -or
            [string]$accountingRepo[0].role -cne 'source' -or [string]$accountingRepo[0].branch -cne [string]$source.branch -or [string]$accountingRepo[0].upstream -cne [string]$source.upstream -or
            [string]$accountingRepo[0].old_revision -cne [string]$source.parent_revision -or [string]$accountingRepo[0].prepared_revision -cne [string]$source.revision -or
            [string]$accountingRepo[0].final_revision -cne [string]$source.revision -or [string]$accountingRepo[0].remote_readback_revision -cne [string]$source.revision -or
            @($accountingRepo[0].commits).Count -ne 1 -or [string]$accountingRepo[0].commits[0].revision -cne [string]$source.revision) {
            throw "Source repository '$id' plan/execution/accounting binding mismatch."
        }
        $remoteName = [string]$executedRepo[0].remote
        if (-not $remoteName -or -not ([string]$source.upstream).StartsWith("$remoteName/",[StringComparison]::Ordinal) -or
            (Invoke-PreparedPushSuffixGit $root @('rev-parse',"$remoteName/$([string]$source.branch)")).text -cne [string]$source.revision) {
            throw "Source repository '$id' remote identity/readback mismatch."
        }
    }

    $planning = $document.planning_transport
    foreach ($pair in @(
        @('branch',[string]$planning.branch,(Invoke-PreparedPushSuffixGit $planningRoot @('branch','--show-current')).text),
        @('head',[string]$planning.receipt_suffix_revision,(Invoke-PreparedPushSuffixGit $planningRoot @('rev-parse','HEAD')).text),
        @('tree',[string]$planning.receipt_suffix_tree,(Invoke-PreparedPushSuffixGit $planningRoot @('show','-s','--format=%T','HEAD')).text),
        @('upstream',[string]$planning.upstream,(Invoke-PreparedPushSuffixGit $planningRoot @('rev-parse','--abbrev-ref','@{upstream}')).text),
        @('remote readback',[string]$planning.execution_final_revision,(Invoke-PreparedPushSuffixGit $planningRoot @('rev-parse','@{upstream}')).text)
    )) { if ($pair[1] -cne $pair[2]) { throw "Planning transport $($pair[0]) mismatch." } }
    $planningPlanRepo = @($planContainer.push_plan.repositories | Where-Object { [string]$_.repo_id -ceq $planningId })
    $planningExecutedRepo = @($executed.repositories | Where-Object { [string]$_.repo_id -ceq $planningId })
    $planningAccountingRepo = @($accounting.repositories | Where-Object { [string]$_.repo_id -ceq $planningId })
    if ($planningPlanRepo.Count -ne 1 -or $planningExecutedRepo.Count -ne 1 -or $planningAccountingRepo.Count -ne 1 -or
        [string]$planningPlanRepo[0].commit -cne [string]$planning.execution_final_revision -or
        [string]$planningExecutedRepo[0].role -cne 'planning' -or [string]$planningExecutedRepo[0].action -cne 'pushed' -or
        [string]$planningExecutedRepo[0].branch -cne [string]$planning.branch -or [string]$planningExecutedRepo[0].upstream -cne [string]$planning.upstream -or
        [string]$planningExecutedRepo[0].new_revision -cne [string]$planning.execution_final_revision -or [string]$planningExecutedRepo[0].observed_remote_revision -cne [string]$planning.execution_final_revision -or
        [string]$planningAccountingRepo[0].role -cne 'planning-transport' -or [string]$planningAccountingRepo[0].branch -cne [string]$planning.branch -or [string]$planningAccountingRepo[0].upstream -cne [string]$planning.upstream -or
        [string]$planningAccountingRepo[0].old_revision -cne [string]$planningExecutedRepo[0].old_revision -or
        [string]$planningAccountingRepo[0].prepared_revision -cne [string]$planning.execution_final_revision -or [string]$planningAccountingRepo[0].final_revision -cne [string]$planning.execution_final_revision -or [string]$planningAccountingRepo[0].remote_readback_revision -cne [string]$planning.execution_final_revision -or
        @($planningAccountingRepo[0].commits).Count -ne 1 -or [string]$planningAccountingRepo[0].commits[0].revision -cne [string]$planning.execution_final_revision) {
        throw 'Planning transport plan/execution/accounting binding mismatch.'
    }
    $planningRemoteName = [string]$planningExecutedRepo[0].remote
    if (-not $planningRemoteName -or -not ([string]$planning.upstream).StartsWith("$planningRemoteName/",[StringComparison]::Ordinal) -or
        (Invoke-PreparedPushSuffixGit $planningRoot @('rev-parse',"$planningRemoteName/$([string]$planning.branch)")).text -cne [string]$planning.execution_final_revision) {
        throw 'Planning transport remote identity/readback mismatch.'
    }
    $executionFinalParents = @((Invoke-PreparedPushSuffixGit $planningRoot @('show','-s','--format=%P',[string]$planning.execution_final_revision)).text -split ' ' | Where-Object { $_ })
    if ($executionFinalParents.Count -ne 1 -or $executionFinalParents[0] -cne [string]$planningExecutedRepo[0].old_revision) { throw 'Planning execution final is not the exact one-parent owner commit.' }
    if ((Invoke-PreparedPushSuffixGit $planningRoot @('show','-s','--format=%P','HEAD')).text -cne [string]$planning.receipt_suffix_parent -or [string]$planning.receipt_suffix_parent -cne [string]$planning.execution_final_revision) { throw 'Planning receipt suffix is not the exact one-parent commit on the executed final.' }
    if ([int](Invoke-PreparedPushSuffixGit $planningRoot @('rev-list','--count',"$($planning.execution_final_revision)..HEAD")).text -ne 1) { throw 'Planning receipt suffix commit count is not exactly one.' }
    $planningTree = (Invoke-PreparedPushSuffixGit $planningRoot @('show','-s','--format=%T',[string]$planning.execution_final_revision)).text
    if ($planningTree -cne [string]$planning.execution_final_tree) { throw 'Planning executed-final tree mismatch.' }
    $suffixPaths = @((Invoke-PreparedPushSuffixGit $planningRoot @('diff-tree','--no-commit-id','--name-only','-r','HEAD')).lines | Where-Object { $_ } | Sort-Object -CaseSensitive)
    $declaredSuffixPaths = @($planning.receipt_suffix_paths | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
    if (($suffixPaths -join '|') -cne ($declaredSuffixPaths -join '|') -or $suffixPaths.Count -ne 2) { throw 'Planning receipt suffix paths are not exact.' }
    $expectedReceiptSuffixPaths = @(
        "$workspaceRelative/$([string]$document.executed_push_receipt.path)",
        "$workspaceRelative/$([string]$document.planned_publication_accounting.path)"
    ) | Sort-Object -CaseSensitive
    if (($declaredSuffixPaths -join '|') -cne ($expectedReceiptSuffixPaths -join '|')) { throw 'Planning receipt suffix is not exactly the executed and accounting receipts.' }

    $actualStatus = [Collections.Generic.List[object]]::new()
    foreach ($line in @((Invoke-PreparedPushSuffixGit $planningRoot @('status','--porcelain=v1','--untracked-files=all')).lines | Where-Object { $_ })) {
        if ($line.Length -lt 4 -or $line.Substring(2,1) -cne ' ' -or $line.Contains(' -> ')) { throw 'Planning worktree status contains an unsupported entry.' }
        $code = $line.Substring(0,2)
        $statusName = switch ($code) { ' M' { 'modified' } '??' { 'untracked' } default { throw "Planning worktree status '$code' is not allowed." } }
        $actualStatus.Add([pscustomobject]@{ path=$line.Substring(3).Replace('\','/'); status=$statusName }) | Out-Null
    }
    $actualStatusArray = @($actualStatus.ToArray() | Sort-Object path -CaseSensitive)
    $declaredDirty = @($planning.dirty_prepare_paths)
    if (($declaredDirty.path -join '|') -cne (@($declaredDirty.path | Sort-Object -CaseSensitive -Unique) -join '|')) { throw 'Declared dirty PreparePush paths must be unique and ordinal sorted.' }
    $expectedDirtyPaths = @(
        [pscustomobject]@{path="$workspaceRelative/workspace.state.json";status='modified'},
        [pscustomobject]@{path="$workspaceRelative/iteration-events.jsonl";status='modified'},
        [pscustomobject]@{path="$workspaceRelative/$([string]$document.prepared_plan.container.path)";status='untracked'},
        [pscustomobject]@{path="$workspaceRelative/$([string]$document.prepared_event.intent.path)";status='untracked'},
        [pscustomobject]@{path="$workspaceRelative/$([string]$document.prepared_event.completion.path)";status='untracked'}
    ) | Sort-Object path -CaseSensitive
    if ((@($expectedDirtyPaths | ForEach-Object { "$($_.status):$($_.path)" }) -join '|') -cne (@($actualStatusArray | ForEach-Object { "$($_.status):$($_.path)" }) -join '|') -or (@($declaredDirty | ForEach-Object { "$($_.status):$($_.path)" }) -join '|') -cne (@($actualStatusArray | ForEach-Object { "$($_.status):$($_.path)" }) -join '|')) { throw 'Planning worktree is not exactly the five-path PreparePush suffix.' }
    foreach ($entry in $declaredDirty) {
        $absolute = Join-Path $planningRoot ([string]$entry.path -replace '/','\')
        if (-not [IO.File]::Exists($absolute) -or [IO.FileInfo]::new($absolute).Length -ne [int64]$entry.bytes -or (Get-MorphospaceFileSha256 $absolute) -cne [string]$entry.sha256) { throw "Dirty PreparePush file binding mismatch: $([string]$entry.path)" }
    }

    return [pscustomobject]@{
        document=$document
        input_path=$inputPath
        input_sha256=Get-MorphospaceFileSha256 $inputPath
        authorization=$authorization
        workspace=$workspace
        unit=$unit
        state=$state
        events=$events
        state_canonical_sha256=$stateCanonicalHash
        unit_canonical_sha256=$unitCanonicalHash
        events_sha256=$eventsHash
        events_length=$eventsLength
        tail_id=[string]$tail.event_id
        unit_relative=$unitRelative
        source_ids=$sourceIds
        planning_id=$planningId
        map=$map
    }
}

function Invoke-PreparedPushTransactionSuffixReconciliationCore {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$Reconciliation,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedReconciliationSha256 = '',
        [string]$Timestamp = '',
        [string]$AuthorizationPolicyPath = '',
        [string]$AuthorizationPolicySchemaPath = '',
        [datetimeoffset]$AuthorizationNow = [datetimeoffset]::UtcNow,
        [scriptblock]$BeforeTransitionHook,
        [switch]$Execute
    )
    $validated = Test-MorphospacePreparedPushTransactionSuffixReconciliation -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -RepoMapPath $RepoMapPath -Reconciliation $Reconciliation -AuthorizationPolicyPath $AuthorizationPolicyPath -AuthorizationPolicySchemaPath $AuthorizationPolicySchemaPath -Now $AuthorizationNow
    if ($ExpectedReconciliationSha256 -and $ExpectedReconciliationSha256 -cne [string]$validated.input_sha256) { throw 'Expected reconciliation SHA-256 does not match the signed input.' }
    if ($Execute -and -not $ExpectedReconciliationSha256) { throw 'Executed ReconcilePreparedPushTransactionSuffix requires ExpectedReconciliationSha256 from the dry run.' }
    $workspace = [string]$validated.workspace
    $outAbsolute = [IO.Path]::GetFullPath($OutPath)
    $workspacePrefix = $workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $outAbsolute.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Reconciliation output must stay inside the workspace.' }
    Assert-MorphospaceNoReparseAncestor -Root $workspace -Candidate $outAbsolute
    $outRelative = $outAbsolute.Substring($workspacePrefix.Length).Replace('\','/')
    $expectedOutRelative = "receipts/$([string]$validated.document.reconciliation_id).json"
    if ($outRelative -cne $expectedOutRelative) { throw "Reconciliation output must be '$expectedOutRelative'." }
    if ([IO.File]::Exists($outAbsolute)) { throw 'Reconciliation output already exists.' }
    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    if (-not (Test-MorphospaceStrictUtcTimestamp $Timestamp)) { throw 'Timestamp must be a strict UTC timestamp.' }
    $eventId = "$([string]$validated.document.reconciliation_id)-recorded"
    $targetState = Copy-PreparedPushSuffixValue $validated.state
    $targetState.pending_push_bundle = $null
    $targetState.last_event_id = $eventId
    $event = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1'
        event_id=$eventId
        sequence=[int]$validated.events[-1].sequence + 1
        timestamp=$Timestamp
        project_id=[string]$validated.document.project_id
        unit_id=$UnitId
        event_type='push'
        summary='Consumed one exact signed dirty PreparePush transaction suffix after byte-exact evidence, clean source-ref, and planning-receipt-suffix verification; no Git, validation, acceptance, device, or publication mutation was performed.'
        receipts=@($outRelative,[string]$validated.document.executed_push_receipt.path,[string]$validated.document.planned_publication_accounting.path,[string]$validated.document.prepared_plan.container.path)
    }
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    if (-not (Test-Json -Json ($event | ConvertTo-Json -Depth 16) -SchemaFile (Join-Path $repositoryRoot 'schemas\iteration-event.schema.json'))) { throw 'Reconciliation event failed its schema.' }
    if ($Execute) {
        if ($BeforeTransitionHook) { & $BeforeTransitionHook }
        $revalidated = Test-MorphospacePreparedPushTransactionSuffixReconciliation -WorkspaceRoot $WorkspaceRoot -UnitId $UnitId -RepoMapPath $RepoMapPath -Reconciliation $Reconciliation -AuthorizationPolicyPath $AuthorizationPolicyPath -AuthorizationPolicySchemaPath $AuthorizationPolicySchemaPath -Now $AuthorizationNow
        if ([string]$revalidated.input_sha256 -cne [string]$validated.input_sha256) { throw 'Signed reconciliation input changed after dry validation.' }
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" `
            -StatePath 'workspace.state.json' -UnitPath ([string]$validated.unit_relative) -EventsPath 'iteration-events.jsonl' `
            -TargetState $targetState -TargetUnit $validated.unit -Event $event `
            -ExpectedStateSha256 ([string]$validated.state_canonical_sha256) -ExpectedUnitSha256 ([string]$validated.unit_canonical_sha256) `
            -ExpectedEventTailId ([string]$validated.tail_id) -ExpectedEventsSha256 ([string]$validated.events_sha256) -ExpectedEventsLength ([int64]$validated.events_length) `
            -Artifacts @([pscustomobject]@{source_path=[string]$validated.input_path;path=$outRelative;sha256=[string]$validated.input_sha256}) | Out-Null
    }
    $result = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2'
        project_id=[string]$validated.document.project_id
        unit_id=$UnitId
        action='ReconcilePreparedPushTransactionSuffix'
        timestamp=$Timestamp
        executed=$Execute.IsPresent
        transition='prepared-push-transaction-suffix-reconciled'
        status_before=[string]$validated.unit.status
        status_after=[string]$validated.unit.status
        current_unit_before=$validated.state.current_unit
        current_unit_after=$targetState.current_unit
        preservation=[pscustomobject][ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false}
        audit_receipt=[pscustomobject][ordered]@{path=$outRelative;sha256=[string]$validated.input_sha256}
        event_id=$(if ($Execute) { $eventId } else { $null })
    }
    if (-not (Test-Json -Json ($result | ConvertTo-Json -Depth 16) -SchemaFile (Join-Path $repositoryRoot 'schemas\work-unit-automation-receipt-v2.schema.json'))) { throw 'ReconcilePreparedPushTransactionSuffix emitted an invalid automation receipt.' }
    return $result
}

function Invoke-MorphospaceReconcilePreparedPushTransactionSuffix {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$UnitId,
        [Parameter(Mandatory)][string]$RepoMapPath,
        [Parameter(Mandatory)][string]$Reconciliation,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$ExpectedReconciliationSha256 = '',
        [string]$Timestamp = '',
        [scriptblock]$BeforeTransitionHook,
        [switch]$Execute
    )
    return Invoke-PreparedPushTransactionSuffixReconciliationCore @PSBoundParameters
}

Export-ModuleMember -Function Get-PreparedPushSuffixAuthorizationScope,Test-MorphospacePreparedPushTransactionSuffixReconciliation,Invoke-MorphospaceReconcilePreparedPushTransactionSuffix
