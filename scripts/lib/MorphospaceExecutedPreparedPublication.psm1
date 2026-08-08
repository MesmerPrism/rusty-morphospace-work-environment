Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -Force

function Invoke-ExecutedPreparedPublicationGit {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$Context,[switch]$AllowFailure)
    $output = @(& git -C $Repository @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) { throw "$Context failed: $($output -join ' ')" }
    [pscustomobject]@{ code = $code; lines = @($output | ForEach-Object { ([string]$_).TrimEnd() }) }
}

function Get-ExecutedPreparedPublicationPathSet {
    param([Parameter(Mandatory)][string[]]$Paths)
    $values = @($Paths | ForEach-Object { ([string]$_).Replace('\','/') } | Where-Object { $_ })
    $unique = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $values) { [void]$unique.Add($value) }
    $ordered = [string[]]@($unique)
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($ordered -join "`n") + "`n")
    [pscustomobject]@{ count = $ordered.Count; sha256 = Get-MorphospaceSha256Bytes $bytes; paths = $ordered }
}

function Get-ExecutedPreparedPublicationBinding {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][string]$Label)
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$Binding.path) -RequireLeaf
    $hash = Get-MorphospaceFileSha256 $path
    if ($hash -cne [string]$Binding.sha256) { throw "$Label hash mismatch." }
    [pscustomobject]@{ path = $path; relative = [string]$Binding.path; sha256 = $hash; document = Read-MorphospaceProtocolJson $path }
}

function Assert-ExecutedPreparedPublicationPathSet {
    param([Parameter(Mandatory)]$Expected,[Parameter(Mandatory)][string[]]$Actual,[Parameter(Mandatory)][string]$Label)
    $observed = Get-ExecutedPreparedPublicationPathSet $Actual
    if ($observed.count -ne [int]$Expected.count -or $observed.sha256 -cne [string]$Expected.sha256) {
        throw "$Label path-set binding mismatch."
    }
    $observed
}

function Test-MorphospaceExecutedPreparedPublicationDocument {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot)
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $document = Read-MorphospaceProtocolJson (Resolve-Path -LiteralPath $Path).Path
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $schemaPath = Join-Path $repoRoot 'schemas\executed-prepared-publication-reconciliation.schema.json'
    if (-not (Test-Json -Json ($document | ConvertTo-Json -Depth 64 -Compress) -SchemaFile $schemaPath)) {
        throw 'Executed prepared-publication reconciliation does not satisfy its schema.'
    }

    $prepared = Get-ExecutedPreparedPublicationBinding $workspace $document.prepared_plan.container 'Prepared-plan container'
    $owner = $prepared.document
    $plan = $owner.push_plan
    if ([string]$owner.schema -cne 'rusty.morphospace.workflow.work_unit_automation_receipt.v1' -or
        [string]$owner.project_id -cne [string]$document.project_id -or [string]$owner.unit_id -cne [string]$document.trigger_unit_id -or
        [string]$owner.action -cne 'PreparePush' -or [string]$owner.transition -cne 'push-bundle-prepared' -or
        $owner.executed -ne $true -or $null -eq $plan -or [string]$plan.schema -cne 'rusty.morphospace.workflow.push_bundle_plan.v1' -or
        [string]$plan.execution -cne 'not-performed' -or $plan.force_push_allowed -ne $false) {
        throw 'Prepared-plan binding is not the immutable non-executing PreparePush owner/member.'
    }

    $intent = Get-ExecutedPreparedPublicationBinding $workspace $document.prepared_event.intent 'PreparePush transition intent'
    $completion = Get-ExecutedPreparedPublicationBinding $workspace $document.prepared_event.completion 'PreparePush transition completion'
    $event = $intent.document.event
    if ([string]$intent.document.schema -cne 'rusty.morphospace.workflow.transition_ledger_intent.v1' -or
        [string]$completion.document.schema -cne 'rusty.morphospace.workflow.transition_ledger_completion.v1' -or
        [string]$completion.document.status -cne 'committed' -or
        [string]$intent.document.transaction_id -cne [string]$completion.document.transaction_id -or
        [string]$completion.document.intent.path -cne [string]$document.prepared_event.intent.path -or
        [string]$completion.document.intent.sha256 -cne [string]$document.prepared_event.intent.sha256 -or
        [string]$event.event_id -cne [string]$document.prepared_event.event_id -or
        [string]$completion.document.event_id -cne [string]$event.event_id -or
        [string]$event.project_id -cne [string]$document.project_id -or
        [string]$event.unit_id -cne [string]$document.trigger_unit_id -or
        [string]$event.event_type -cne 'commit' -or
        @($event.receipts).Count -ne 1 -or [string]$event.receipts[0] -cne [string]$document.prepared_plan.container.path -or
        [string]$owner.event_id -cne [string]$event.event_id) {
        throw 'PreparePush transition intent/completion is not exactly bound to the immutable plan.'
    }

    $executed = Get-ExecutedPreparedPublicationBinding $workspace $document.executed_push_receipt 'Executed-push receipt'
    $push = $executed.document
    if ([string]$push.schema -cne 'rusty.morphospace.workflow.executed_push_receipt.v1' -or
        [string]$push.status -cne 'validated-pushed' -or [string]$push.execution -cne 'externally-performed' -or
        $push.force_push_used -ne $false -or $push.remote_readback_complete -ne $true -or $null -ne $push.failure) {
        throw 'Executed-push receipt is not complete no-force external execution evidence.'
    }
    foreach ($value in @($document.project_id,$document.bundle_id,$document.trigger_unit_id)) {
        if (-not $value) { throw 'Reconciliation identity is incomplete.' }
    }
    if ([string]$plan.project_id -cne [string]$document.project_id -or [string]$push.project_id -cne [string]$document.project_id -or
        [string]$plan.bundle_id -cne [string]$document.bundle_id -or [string]$push.bundle_id -cne [string]$document.bundle_id -or
        [string]$push.prepared_plan_id -cne [string]$plan.bundle_id -or
        (@($plan.unit_ids) -join '|') -cne [string]$document.trigger_unit_id -or
        (@($push.unit_ids) -join '|') -cne [string]$document.trigger_unit_id) {
        throw 'Reconciliation project, bundle, prepared plan, or exact unit identity mismatch.'
    }

    $chronology = $document.chronology
    if ([string]$chronology.prepared_at -cne [string]$owner.timestamp -or [string]$chronology.prepared_at -cne [string]$plan.prepared_at -or [string]$chronology.prepared_at -cne [string]$event.timestamp -or
        [string]$chronology.push_started_at -cne [string]$push.started_at -or [string]$chronology.push_finished_at -cne [string]$push.finished_at) {
        throw 'Reconciliation chronology does not preserve the exact immutable timestamps.'
    }
    $preparedAt = [DateTimeOffset]::Parse([string]$chronology.prepared_at)
    $startedAt = [DateTimeOffset]::Parse([string]$chronology.push_started_at)
    $finishedAt = [DateTimeOffset]::Parse([string]$chronology.push_finished_at)
    if ($startedAt -ge $preparedAt -or $finishedAt -lt $startedAt) {
        throw 'This recovery requires execution to precede the recorded preparation timestamp while preserving a monotonic execution interval.'
    }

    $planOrder = @($plan.dependency_order | ForEach-Object { [string]$_ })
    $dependencyOrder = @($push.dependency_order | ForEach-Object { [string]$_ })
    $executionOrder = @($push.execution_order | ForEach-Object { [string]$_ })
    if (($planOrder -join '|') -cne ($dependencyOrder -join '|') -or ($dependencyOrder -join '|') -cne ($executionOrder -join '|') -or
        $plan.source_first -ne $true -or $plan.planning_last -ne $true -or $push.source_first -ne $true -or $push.planning_last -ne $true) {
        throw 'Reconciliation does not bind the exact prepared dependency order and observed source-first, planning-last execution order.'
    }

    $documents = @($document.repositories)
    $documentIds = @($documents | ForEach-Object { [string]$_.repo_id })
    $sortedDocumentIds = @($documentIds | Sort-Object)
    $sortedPlanIds = @($planOrder | Sort-Object)
    if (@($documentIds | Sort-Object -Unique).Count -ne $documentIds.Count -or ($sortedDocumentIds -join '|') -cne ($sortedPlanIds -join '|')) {
        throw 'Reconciliation repository coverage is incomplete or duplicated.'
    }
    $planning = @($documents | Where-Object { [string]$_.role -ceq 'planning' })
    if ($planning.Count -ne 1 -or [string]$planning[0].repo_id -cne [string]$document.planning_transport.repo_id -or
        [string]$planOrder[-1] -cne [string]$planning[0].repo_id) {
        throw 'Reconciliation must bind exactly one planning-last transport repository.'
    }
    $allowedUntracked = @($document.planning_transport.allowed_untracked_paths | ForEach-Object { [string]$_ })
    if (@($allowedUntracked | Sort-Object -Unique).Count -ne 2) {
        throw 'Planning transport must allow exactly two unique untracked pre-transition evidence paths.'
    }

    foreach ($repository in $documents) {
        $id = [string]$repository.repo_id
        $planned = @($plan.repositories | Where-Object { [string]$_.repo_id -ceq $id })
        $pushed = @($push.repositories | Where-Object { [string]$_.repo_id -ceq $id })
        if ($planned.Count -ne 1 -or $pushed.Count -ne 1) { throw "Repository '$id' is not uniquely bound by the plan and executed receipt." }
        $expectedRole = if ([string]$planned[0].role -ceq 'planning') { 'planning' } else { 'source' }
        $expectedExecutedRole = if ($expectedRole -ceq 'planning') { 'planning' } else { 'source-owner' }
        if ([string]$repository.role -cne $expectedRole -or [string]$repository.planned_revision -cne [string]$planned[0].commit -or
            [string]$repository.branch -cne [string]$planned[0].branch -or [string]$repository.branch -cne [string]$pushed[0].branch -or
            [string]$pushed[0].role -cne $expectedExecutedRole -or [string]$pushed[0].action -cne 'pushed' -or [string]$pushed[0].push_status -cne 'pass' -or
            [string]$repository.remote -cne [string]$pushed[0].remote -or [string]$repository.upstream -cne [string]$pushed[0].upstream -or
            [string]$repository.old_revision -cne [string]$pushed[0].old_revision -or [string]$repository.final_revision -cne [string]$pushed[0].new_revision -or
            [string]$repository.current_remote_readback_revision -cne [string]$pushed[0].observed_remote_revision -or
            $pushed[0].ancestry_verified -ne $true -or $pushed[0].remote_match -ne $true -or $pushed[0].force_push_used -ne $false -or
            $repository.force_push_used -ne $false) {
            throw "Repository '$id' does not preserve the exact plan/execution/readback identity."
        }
        if ([string]$repository.history.mode -ceq 'linear' -and $null -ne $repository.history.merge_integration) { throw "Linear repository '$id' declares merge integration." }
        if ([string]$repository.history.mode -ceq 'merge-integration' -and $null -eq $repository.history.merge_integration) { throw "Merge repository '$id' omits merge integration evidence." }
    }
    if (@($documents | Where-Object { [string]$_.history.mode -ceq 'merge-integration' }).Count -lt 1) {
        throw 'Executed prepared-publication reconciliation requires at least one exact merge-integration repository.'
    }

    [pscustomobject]@{
        document = $document; plan = $plan; executed = $push
        reconciliation_sha256 = Get-MorphospaceFileSha256 (Resolve-Path -LiteralPath $Path).Path
        reconciliation_path = (Resolve-Path -LiteralPath $Path).Path
    }
}

function Test-MorphospaceExecutedPreparedPublicationLive {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$State,[Parameter(Mandatory)][hashtable]$RepositoryMap,[Parameter(Mandatory)][object[]]$RepositoryStates)
    $validated = Test-MorphospaceExecutedPreparedPublicationDocument $Path $WorkspaceRoot
    $document = $validated.document
    if ([string]$Spec.project_id -cne [string]$document.project_id -or $null -ne $State.current_unit -or
        $null -eq $State.pending_push_bundle -or [string]$State.pending_push_bundle.bundle_id -cne [string]$document.bundle_id -or
        (@($State.pending_push_bundle.unit_ids) -join '|') -cne [string]$document.trigger_unit_id -or
        (@($State.pending_push_bundle.repo_ids) -join '|') -cne (@($validated.plan.dependency_order) -join '|')) {
        throw 'Reconciliation does not match the exact accepted unit and pending bundle.'
    }

    $planningId = [string]$document.planning_transport.repo_id
    foreach ($repository in @($document.repositories)) {
        $id = [string]$repository.repo_id
        if (-not $RepositoryMap.ContainsKey($id)) { throw "Repository '$id' is not mapped." }
        $state = @($RepositoryStates | Where-Object { [string]$_.repo_id -ceq $id })
        if ($state.Count -ne 1 -or -not $state[0].is_git -or $state[0].diverged -eq $true -or [int]$state[0].ahead -ne 0 -or [int]$state[0].behind -ne 0 -or
            [string]$state[0].head -cne [string]$repository.final_revision -or [string]$state[0].branch -cne [string]$repository.branch -or [string]$state[0].upstream -cne [string]$repository.upstream) {
            throw "Repository '$id' is not synchronized at the exact bound branch and revision."
        }
        $repo = [string]$RepositoryMap[$id].path
        $remote = (Invoke-ExecutedPreparedPublicationGit $repo @('rev-parse',[string]$repository.upstream) "Repository '$id' remote readback").lines[0]
        if ([string]$remote -cne [string]$repository.current_remote_readback_revision) { throw "Repository '$id' remote readback mismatch." }
        foreach ($revision in @($repository.old_revision,$repository.planned_revision,$repository.final_revision)) {
            [void](Invoke-ExecutedPreparedPublicationGit $repo @('cat-file','-e',"$revision^{commit}") "Repository '$id' bound object")
        }
        if ((Invoke-ExecutedPreparedPublicationGit $repo @('merge-base','--is-ancestor',[string]$repository.old_revision,[string]$repository.final_revision) "Repository '$id' old/final ancestry" -AllowFailure).code -ne 0 -or
            (Invoke-ExecutedPreparedPublicationGit $repo @('merge-base','--is-ancestor',[string]$repository.planned_revision,[string]$repository.final_revision) "Repository '$id' planned/final ancestry" -AllowFailure).code -ne 0) {
            throw "Repository '$id' prepared or old revision is not reachable from the final revision."
        }
        $tree = (Invoke-ExecutedPreparedPublicationGit $repo @('rev-parse',"$($repository.final_revision)^{tree}") "Repository '$id' final tree").lines[0]
        if ([string]$tree -cne [string]$repository.final_tree) { throw "Repository '$id' final tree mismatch." }

        $commits = @((Invoke-ExecutedPreparedPublicationGit $repo @('rev-list','--reverse',"$($repository.old_revision)..$($repository.final_revision)") "Repository '$id' exact history").lines | Where-Object { $_ })
        if ($commits.Count -ne [int]$repository.history.commit_count -or [string]$commits[-1] -cne [string]$repository.final_revision) { throw "Repository '$id' commit enumeration mismatch." }
        $changed = New-Object System.Collections.Generic.List[string]
        foreach ($commit in $commits) {
            $paths = @((Invoke-ExecutedPreparedPublicationGit $repo @('diff-tree','--no-commit-id','--name-only','-r',$commit) "Repository '$id' commit paths").lines | Where-Object { $_ })
            if (-not $paths.Count -and [string]$repository.history.mode -ceq 'linear') { throw "Linear repository '$id' contains an empty commit." }
            foreach ($item in $paths) { $changed.Add($item) }
        }
        [void](Assert-ExecutedPreparedPublicationPathSet ([pscustomobject]@{ count = [int]$repository.history.changed_path_count; sha256 = [string]$repository.history.changed_paths_sha256 }) @($changed) "Repository '$id' history")

        if ([string]$repository.history.mode -ceq 'linear') {
            $prior = [string]$repository.old_revision
            foreach ($commit in $commits) {
                $parents = @((Invoke-ExecutedPreparedPublicationGit $repo @('show','-s','--format=%P',$commit) "Repository '$id' linear parent").lines[0] -split ' ' | Where-Object { $_ })
                if ($parents.Count -ne 1 -or [string]$parents[0] -cne $prior) { throw "Linear repository '$id' contains a merge or gap." }
                $prior = $commit
            }
        } else {
            $merge = $repository.history.merge_integration
            if ([string]$repository.old_revision -cne [string]$merge.protected_parent -or [string]$repository.final_revision -cne [string]$commits[-1]) { throw "Merge repository '$id' does not use the protected parent as its old revision." }
            if ($commits.Count -ne 2 -or [string]$commits[0] -cne [string]$merge.side_parent -or [string]$commits[1] -cne [string]$repository.final_revision) { throw "Merge repository '$id' is not the exact one-side-commit plus merge-final integration shape." }
            $parents = @((Invoke-ExecutedPreparedPublicationGit $repo @('show','-s','--format=%P',[string]$repository.final_revision) "Repository '$id' merge parents").lines[0] -split ' ' | Where-Object { $_ })
            $expectedParents = @($merge.ordered_parents | ForEach-Object { [string]$_ })
            if (($parents -join '|') -cne ($expectedParents -join '|') -or $expectedParents[0] -cne [string]$merge.side_parent -or $expectedParents[1] -cne [string]$merge.protected_parent) { throw "Merge repository '$id' ordered parent binding mismatch." }
            $base = (Invoke-ExecutedPreparedPublicationGit $repo @('merge-base',[string]$merge.side_parent,[string]$merge.protected_parent) "Repository '$id' merge base").lines[0]
            if ([string]$base -cne [string]$merge.base_revision) { throw "Merge repository '$id' merge-base mismatch." }
            foreach ($pair in @(@($merge.base_revision,$merge.base_tree),@($merge.side_parent,$merge.side_parent_tree),@($merge.protected_parent,$merge.protected_parent_tree))) {
                $boundTree = (Invoke-ExecutedPreparedPublicationGit $repo @('rev-parse',"$($pair[0])^{tree}") "Repository '$id' merge tree").lines[0]
                if ([string]$boundTree -cne [string]$pair[1]) { throw "Merge repository '$id' bound tree mismatch." }
            }
            [void](Assert-ExecutedPreparedPublicationPathSet $merge.side_delta @((Invoke-ExecutedPreparedPublicationGit $repo @('diff','--name-only',[string]$merge.base_revision,[string]$merge.side_parent) "Repository '$id' side delta").lines) "Repository '$id' side delta")
            [void](Assert-ExecutedPreparedPublicationPathSet $merge.protected_delta @((Invoke-ExecutedPreparedPublicationGit $repo @('diff','--name-only',[string]$merge.base_revision,[string]$merge.protected_parent) "Repository '$id' protected delta").lines) "Repository '$id' protected delta")
            $finalAgainstProtected = Assert-ExecutedPreparedPublicationPathSet $merge.final_delta_against_protected @((Invoke-ExecutedPreparedPublicationGit $repo @('diff','--name-only',[string]$merge.protected_parent,[string]$repository.final_revision) "Repository '$id' final/protected delta").lines) "Repository '$id' final/protected delta"
            [void](Assert-ExecutedPreparedPublicationPathSet $merge.final_delta_against_side @((Invoke-ExecutedPreparedPublicationGit $repo @('diff','--name-only',[string]$merge.side_parent,[string]$repository.final_revision) "Repository '$id' final/side delta").lines) "Repository '$id' final/side delta")
            $side = Get-ExecutedPreparedPublicationPathSet @((Invoke-ExecutedPreparedPublicationGit $repo @('diff','--name-only',[string]$merge.base_revision,[string]$merge.side_parent) "Repository '$id' side unit projection").lines)
            if ($side.count -ne $finalAgainstProtected.count -or $side.sha256 -cne $finalAgainstProtected.sha256) { throw "Merge repository '$id' does not preserve the exact side change relative to protected main." }
        }

        $status = @((Invoke-ExecutedPreparedPublicationGit $repo @('status','--porcelain=v1','--untracked-files=all') "Repository '$id' status").lines | Where-Object { $_ })
        if ($id -cne $planningId) {
            if ($status.Count -ne 0 -or $state[0].dirty -ne $false) { throw "Source repository '$id' is not clean." }
        } else {
            $observed = @($status | ForEach-Object { if ($_ -cnotmatch '^\?\? (.+)$') { throw "Planning repository '$id' contains a tracked or non-untracked change: $_" }; $Matches[1].Replace('\','/') })
            $allowed = @($document.planning_transport.allowed_untracked_paths | ForEach-Object { [string]$_ })
            $orderedObserved = Get-ExecutedPreparedPublicationPathSet $observed
            $orderedAllowed = Get-ExecutedPreparedPublicationPathSet $allowed
            if ($orderedObserved.count -ne $orderedAllowed.count -or $orderedObserved.sha256 -cne $orderedAllowed.sha256) { throw 'Planning repository pre-transition evidence paths are not exact.' }
            $recoveryRelative = [IO.Path]::GetRelativePath($repo,(Resolve-Path -LiteralPath $Path).Path).Replace('\','/')
            $executedRelative = [IO.Path]::GetRelativePath($repo,(Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$document.executed_push_receipt.path) -RequireLeaf)).Replace('\','/')
            if ($allowed -cnotcontains $recoveryRelative -or $allowed -cnotcontains $executedRelative) { throw 'Planning untracked allowlist does not bind this recovery input and executed receipt exactly.' }
        }
    }
    $validated
}

Export-ModuleMember -Function Get-ExecutedPreparedPublicationPathSet,Test-MorphospaceExecutedPreparedPublicationDocument,Test-MorphospaceExecutedPreparedPublicationLive
