Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-MorphospacePublicationRecoverySha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Publication-recovery evidence does not exist: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-MorphospacePublicationRecoveryId {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Context)

    if ($Value -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') {
        throw "$Context is not a portable workflow ID."
    }
}

function Resolve-MorphospacePublicationWorkspaceFile {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$Reference,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ([System.IO.Path]::IsPathRooted($Reference)) {
        throw "$Context must use a workspace-relative path."
    }
    $normalized = $Reference.Replace('\', '/')
    if ($normalized -match '(^|/)\.\.(/|$)') {
        throw "$Context may not traverse outside the workspace."
    }
    $workspaceFull = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $workspaceFull $Reference))
    $prefix = $workspaceFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context resolves outside the workspace."
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "$Context does not exist: $Reference"
    }
    return $candidate
}

function Read-MorphospaceUnplannedPublicationClosure {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Unplanned-publication closure does not exist: $Path"
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Invalid unplanned-publication closure JSON: $($_.Exception.Message)"
    }
}

function Test-MorphospaceUnplannedPublicationClosureDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot
    )

    $document = Read-MorphospaceUnplannedPublicationClosure -Path $Path
    if ([string]$document.schema -cne 'rusty.morphospace.workflow.unplanned_publication_closure.v1') {
        throw 'Unplanned-publication closure has the wrong schema ID.'
    }
    foreach ($entry in @(
        @{ Value = [string]$document.closure_id; Context = 'closure_id' },
        @{ Value = [string]$document.project_id; Context = 'project_id' },
        @{ Value = [string]$document.unit_id; Context = 'unit_id' },
        @{ Value = [string]$document.repository.repo_id; Context = 'repository.repo_id' }
    )) {
        Test-MorphospacePublicationRecoveryId -Value $entry.Value -Context $entry.Context
    }
    if ([string]$document.status -cne 'independent-reconstruction-verified') {
        throw 'Unplanned-publication closure must be an independently verified reconstruction.'
    }
    if ([string]$document.chronology.classification -cne 'unplanned-push-before-prepare' -or
        $document.chronology.prepared_plan_present -ne $false -or
        $document.chronology.executed_push_receipt_present -ne $false) {
        throw 'Unplanned-publication closure must preserve the absence of pre-push planning and execution evidence.'
    }
    if (@($document.chronology.does_not_claim).Count -lt 1) {
        throw 'Unplanned-publication closure must state what it does not claim.'
    }
    if ([string]$document.repository.role -cne 'source-owner' -or [string]$document.repository.action -cne 'pushed') {
        throw 'Unplanned-publication closure must describe one pushed source-owner ref.'
    }
    foreach ($name in @('old_revision', 'new_revision', 'observed_remote_revision', 'rollback_revision')) {
        if ([string]$document.repository.$name -cnotmatch '^[0-9a-f]{40}$') {
            throw "Unplanned-publication closure has an invalid repository.$name."
        }
    }
    if ([string]$document.repository.old_revision -ceq [string]$document.repository.new_revision) {
        throw 'Unplanned-publication closure must describe an actual ref advance.'
    }
    if ([string]$document.repository.new_revision -cne [string]$document.repository.observed_remote_revision -or
        [string]$document.repository.old_revision -cne [string]$document.repository.rollback_revision) {
        throw 'Unplanned-publication closure remote readback or rollback revision does not match the observed advance.'
    }
    if ($document.repository.fast_forward_verified -ne $true -or
        $document.repository.remote_match -ne $true -or
        $document.repository.force_push_used -ne $false -or
        $document.repository.worktree_clean -ne $true -or
        $document.remote_readback_complete -ne $true -or
        [string]$document.recovery_scope -cne 'workflow-state-only' -or
        $null -ne $document.failure) {
        throw 'Unplanned-publication closure does not prove a clean, no-force, read-back workflow-only recovery.'
    }

    $workspaceBindingPath = Resolve-MorphospacePublicationWorkspaceFile -WorkspaceRoot $WorkspaceRoot -Reference ([string]$document.workspace_state_before.path) -Context 'workspace_state_before.path'
    $workspaceHash = Get-MorphospacePublicationRecoverySha256 -Path $workspaceBindingPath
    if ($workspaceHash -cne ([string]$document.workspace_state_before.sha256).ToLowerInvariant()) {
        throw 'Unplanned-publication closure workspace-state hash mismatch.'
    }

    $gateIds = @{}
    foreach ($gate in @($document.validation)) {
        $gateId = [string]$gate.gate_id
        Test-MorphospacePublicationRecoveryId -Value $gateId -Context 'validation.gate_id'
        if ($gateIds.ContainsKey($gateId)) { throw "Unplanned-publication closure repeats validation gate '$gateId'." }
        if ([string]$gate.status -cne 'pass') { throw "Unplanned-publication closure gate '$gateId' is not passing." }
        $evidencePath = Resolve-MorphospacePublicationWorkspaceFile -WorkspaceRoot $WorkspaceRoot -Reference ([string]$gate.evidence.path) -Context "validation '$gateId' evidence"
        $evidenceHash = Get-MorphospacePublicationRecoverySha256 -Path $evidencePath
        if ($evidenceHash -cne ([string]$gate.evidence.sha256).ToLowerInvariant()) {
            throw "Unplanned-publication closure validation hash mismatch for '$gateId'."
        }
        $gateIds[$gateId] = $true
    }
    if ($gateIds.Count -lt 1) { throw 'Unplanned-publication closure requires passing validation evidence.' }
    $validationRefs = @($document.repository.validation_refs | ForEach-Object { [string]$_ })
    if (@($validationRefs | Sort-Object -Unique).Count -ne $validationRefs.Count) {
        throw 'Unplanned-publication closure repository validation_refs are not unique.'
    }
    $validationRefKey = (@($validationRefs | Sort-Object) -join '|')
    $validationGateKey = (@($gateIds.Keys | Sort-Object) -join '|')
    if ($validationRefKey -cne $validationGateKey) {
        throw 'Unplanned-publication closure repository validation_refs must exactly cover its validation gates.'
    }
    if (@($document.observers).Count -lt 1) { throw 'Unplanned-publication closure requires an external observer.' }
    $observerIds = @{}
    foreach ($observer in @($document.observers)) {
        $observerId = [string]$observer.observer_id
        Test-MorphospacePublicationRecoveryId -Value $observerId -Context 'observers.observer_id'
        if ($observerIds.ContainsKey($observerId)) { throw "Unplanned-publication closure repeats observer '$observerId'." }
        if ([string]$observer.evidence_sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Observer '$observerId' has an invalid evidence hash." }
        $observerIds[$observerId] = $true
    }
    if ($document.workspace_transition.pending_push_bundle_after -ne $null) {
        throw 'Unplanned-publication recovery must clear, not replace, the stale pending push bundle.'
    }
    if ([string]$document.workspace_transition.repository_head_after -cne [string]$document.repository.new_revision) {
        throw 'Unplanned-publication recovery head must equal the observed remote revision.'
    }
    $dirtyIds = @($document.workspace_transition.dirty_repository_ids_to_clear | ForEach-Object { [string]$_ })
    if ($dirtyIds.Count -ne 1 -or $dirtyIds[0] -cne [string]$document.repository.repo_id) {
        throw 'Unplanned-publication recovery may clear only the observed source repository.'
    }
    return [pscustomobject][ordered]@{
        document = $document
        closure_sha256 = Get-MorphospacePublicationRecoverySha256 -Path $Path
    }
}

function Test-MorphospaceUnplannedPublicationClosureLive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][object]$Unit,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$RepositoryMap,
        [Parameter(Mandatory = $true)][object[]]$RepositoryStates
    )

    $validated = Test-MorphospaceUnplannedPublicationClosureDocument -Path $Path -WorkspaceRoot $WorkspaceRoot
    $document = $validated.document
    if ([string]$document.project_id -cne [string]$Spec.project_id -or [string]$document.unit_id -cne [string]$Unit.unit_id) {
        throw 'Unplanned-publication closure identity does not match the requested project and unit.'
    }
    if ([string]$Unit.status -cne 'accepted' -or $null -ne $State.current_unit) {
        throw 'Unplanned-publication recovery requires an accepted unit and no current in-flight unit.'
    }
    $repoId = [string]$document.repository.repo_id
    if (@($Unit.allowed_repositories | Where-Object { [string]$_.repo_id -ceq $repoId }).Count -ne 1 -or -not $RepositoryMap.ContainsKey($repoId)) {
        throw "Unplanned-publication closure repository '$repoId' is outside the accepted unit or local repository map."
    }
    $repoState = @($RepositoryStates | Where-Object { [string]$_.repo_id -ceq $repoId })
    if ($repoState.Count -ne 1 -or $repoState[0].is_git -ne $true) {
        throw "Unplanned-publication closure repository '$repoId' is not an available Git worktree."
    }
    $repoState = $repoState[0]
    if ($repoState.dirty -ne $false -or $null -eq $repoState.branch -or $repoState.diverged -eq $true -or [int]$repoState.ahead -ne 0 -or [int]$repoState.behind -ne 0) {
        throw "Unplanned-publication recovery requires a clean synchronized source repository '$repoId'."
    }
    if ([string]$repoState.head -cne [string]$document.repository.new_revision -or
        [string]$repoState.branch -cne [string]$document.repository.branch -or
        [string]$repoState.upstream -cne [string]$document.repository.upstream) {
        throw "Unplanned-publication closure no longer matches HEAD, branch, or upstream for '$repoId'."
    }
    $repoPath = [string]$RepositoryMap[$repoId].path
    & git -C $repoPath merge-base --is-ancestor ([string]$document.repository.old_revision) ([string]$document.repository.new_revision) 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Unplanned-publication closure old revision is not an ancestor of the observed new revision for '$repoId'." }
    if ($null -eq $State.pending_push_bundle -or [string]$State.pending_push_bundle.bundle_id -cne [string]$document.workspace_transition.pending_push_bundle_before) {
        throw 'Unplanned-publication closure does not match the stale pending push bundle.'
    }
    if (@($State.dirty_repositories | Where-Object { [string]$_ -ceq $repoId }).Count -ne 1) {
        throw "Unplanned-publication closure does not match dirty-repository state for '$repoId'."
    }
    return $validated
}

Export-ModuleMember -Function `
    Get-MorphospacePublicationRecoverySha256, `
    Test-MorphospaceUnplannedPublicationClosureDocument, `
    Test-MorphospaceUnplannedPublicationClosureLive
