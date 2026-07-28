Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceProtocolCommon.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceTransitionLedger.psm1") -Force

function Invoke-PreparedPushGit {
    param([string]$Path, [string[]]$Arguments, [switch]$AllowFailure)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git -C $Path @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Prepared-push retirement Git observation failed in '$Path': git $($Arguments -join ' ')"
    }
    [pscustomobject]@{ code = $code; text = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim() }
}

function Resolve-PreparedPushRetirementFile {
    param([string]$WorkspaceRoot, [object]$Reference)
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath ([string]$Reference.path) -RequireLeaf
    $actual = Get-MorphospaceFileSha256 $path
    if ($actual -cne [string]$Reference.sha256) {
        throw "Prepared-push retirement evidence hash mismatch for '$($Reference.path)'."
    }
    $path
}

function Get-PreparedPushRepositoryObservation {
    param([object]$PlanRepository, [object]$MapEntry, [string[]]$AllowedPreparationPaths = @(),[switch]$SourceLike)
    $repoId = [string]$PlanRepository.repo_id
    $path = [IO.Path]::GetFullPath([string]$MapEntry.path)
    if (-not [IO.Directory]::Exists($path)) { throw "Prepared-push retirement repository '$repoId' is unavailable." }
    if ((Invoke-PreparedPushGit $path @("rev-parse", "--is-inside-work-tree")).text -ne "true") {
        throw "Prepared-push retirement repository '$repoId' is not a Git worktree."
    }
    $head = (Invoke-PreparedPushGit $path @("rev-parse", "HEAD")).text
    $branchResult = Invoke-PreparedPushGit $path @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
    if ($branchResult.code -ne 0) { throw "Prepared-push retirement repository '$repoId' is detached." }
    $branch = $branchResult.text
    $upstreamResult = Invoke-PreparedPushGit $path @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}") -AllowFailure
    if ($upstreamResult.code -ne 0) { throw "Prepared-push retirement repository '$repoId' has no upstream." }
    $upstream = $upstreamResult.text
    $status = (Invoke-PreparedPushGit $path @("status", "--porcelain=v1", "--untracked-files=all")).text
    if ($status) { throw "Prepared-push retirement repository '$repoId' is dirty." }
    $counts = (Invoke-PreparedPushGit $path @("rev-list", "--left-right", "--count", "HEAD...@{upstream}")).text -split "\s+"
    if ($counts.Count -ne 2) { throw "Prepared-push retirement repository '$repoId' has malformed divergence observations." }
    $ahead = [int]$counts[0]; $behind = [int]$counts[1]
    if ($behind -ne 0) { throw "Prepared-push retirement repository '$repoId' is behind or divergent." }
    if ($branch -cne [string]$PlanRepository.branch -or $upstream -cne [string]$PlanRepository.upstream) {
        throw "Prepared-push retirement repository '$repoId' branch/upstream does not match the immutable plan."
    }
    $prepared = (Invoke-PreparedPushGit $path @("rev-parse", "$([string]$PlanRepository.commit)^{commit}")).text
    $preparedToHead = Invoke-PreparedPushGit $path @("merge-base", "--is-ancestor", $prepared, $head) -AllowFailure
    if ($preparedToHead.code -ne 0) { throw "Prepared-push retirement repository '$repoId' current HEAD is not a descendant of its prepared revision." }
    $remoteName = (Invoke-PreparedPushGit $path @("config", "--get", "branch.$branch.remote")).text
    $mergeRef = (Invoke-PreparedPushGit $path @("config", "--get", "branch.$branch.merge")).text
    if (-not $remoteName -or $remoteName -eq "." -or $mergeRef -notmatch "^refs/heads/") {
        throw "Prepared-push retirement repository '$repoId' has no remotely readable branch upstream."
    }
    $remoteLookup = Invoke-PreparedPushGit $path @("ls-remote", "--exit-code", $remoteName, $mergeRef) -AllowFailure
    if ($remoteLookup.code -ne 0) { throw "Prepared-push retirement remote lookup failed for '$repoId'." }
    $remoteFields = $remoteLookup.text -split "\s+"
    if ($remoteFields.Count -lt 2 -or $remoteFields[0] -notmatch "^[0-9a-f]{40}$") {
        throw "Prepared-push retirement remote lookup was malformed for '$repoId'."
    }
    $remoteRevision = $remoteFields[0]
    $trackingRevision = (Invoke-PreparedPushGit $path @("rev-parse", "@{upstream}^{commit}")).text
    if ($remoteRevision -cne $trackingRevision) {
        throw "Prepared-push retirement repository '$repoId' has stale remote-tracking observations."
    }
    $reachable = Invoke-PreparedPushGit $path @("merge-base", "--is-ancestor", $prepared, $remoteRevision) -AllowFailure
    if ($reachable.code -notin @(0,1)) { throw "Prepared-push retirement reachability lookup failed for '$repoId'." }
    $preparedReachable = ($reachable.code -eq 0)
    if (-not $preparedReachable) {
        if ($SourceLike -and $head -cne $prepared) {
            throw "Prepared-push retirement source repository '$repoId' advanced after preparation."
        }
        if ($head -cne $prepared) {
            $changedPaths = @((Invoke-PreparedPushGit $path @("diff", "--name-only", "$prepared..$head")).text -split "`n" | Where-Object { $_ })
            $unexpected = @($changedPaths | Where-Object { $AllowedPreparationPaths -notcontains $_ })
            if ($unexpected.Count -or $changedPaths.Count -eq 0) {
                throw "Prepared-push retirement planning repository '$repoId' has an unrelated post-preparation suffix."
            }
        }
    }
    $result=[pscustomobject][ordered]@{
        repo_id = $repoId
        role = [string]$PlanRepository.role
        branch = $branch
        upstream = $upstream
        prepared_revision = $prepared
        local_head = $head
        remote_readback_revision = $remoteRevision
        worktree_clean = $true
        detached = $false
        ahead = $ahead
        behind = $behind
        diverged = $false
        prepared_reachable = $preparedReachable
        physical_key = "$([IO.Path]::GetFullPath($path).ToLowerInvariant())|$remoteName|$mergeRef"
    }
    $result
}

function Assert-PreparedPushObservationEqual {
    param([object]$Declared, [object]$Observed)
    foreach ($name in @("repo_id","role","branch","upstream","prepared_revision","local_head","remote_readback_revision","worktree_clean","detached","ahead","behind","diverged")) {
        if ([string]$Declared.$name -cne [string]$Observed.$name) {
            throw "Prepared-push retirement stale or mismatched repository observation for '$($Observed.repo_id)' field '$name'."
        }
    }
}
function Get-PreparedPushBundleBindings {
    param([AllowNull()][object]$Node)
    if($null-eq$Node){return}
    if($Node-is[pscustomobject]){
        foreach($property in $Node.PSObject.Properties){
            if($property.Name-ceq'bundle_id'){[string]$property.Value}
            Get-PreparedPushBundleBindings $property.Value
        }
    }elseif($Node-is[System.Collections.IEnumerable]-and$Node-isnot[string]){
        foreach($item in $Node){Get-PreparedPushBundleBindings $item}
    }
}

function Test-PreparedPushConflictingEvidence {
    param([string]$WorkspaceRoot, [string]$BundleId, [string[]]$ExcludedPaths)
    $recognized = @(
        "rusty.morphospace.workflow.executed_push_receipt.v1",
        "rusty.morphospace.workflow.planned_publication_accounting.v1",
        "rusty.morphospace.workflow.published_prerequisite_suffix_reconciliation.v1",
        "rusty.morphospace.workflow.published_prerequisite_suffix_reconciliation.v2",
        "rusty.morphospace.workflow.planning_suffix_rewrite_recovery.v1",
        "rusty.morphospace.workflow.unplanned_publication_closure.v1",
        "rusty.morphospace.workflow.unplanned_publication_closure.v2"
    )
    $receiptsRoot = Join-Path $WorkspaceRoot "receipts"
    foreach ($file in @(Get-ChildItem -LiteralPath $receiptsRoot -File -Recurse -Filter *.json -ErrorAction Stop)) {
        $relative = [IO.Path]::GetRelativePath($WorkspaceRoot, $file.FullName).Replace("\","/")
        if ($ExcludedPaths -contains $relative) { continue }
        try { $document = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json } catch {
            throw "Prepared-push retirement evidence search encountered malformed JSON at '$relative'."
        }
        $schema = [string]$document.schema
        $bundleValues = @(Get-PreparedPushBundleBindings $document)
        if ($bundleValues -contains $BundleId -and $recognized -contains $schema) {
            throw "Prepared-push retirement found workflow-recognized execution/publication evidence for bundle '$BundleId' at '$relative'."
        }
        if ($schema -like "rusty.morphospace.workflow.work_unit_automation_receipt.v*" -and
            [string]$document.action -in @("RecordPublication","ReconcilePublication","ReconcilePlanningSuffixRewrite","ReconcilePublishedPrerequisiteSuffix") -and
            $bundleValues -contains $BundleId) {
            throw "Prepared-push retirement found a consuming automation receipt for bundle '$BundleId' at '$relative'."
        }
    }
    $eventsPath = Join-Path $WorkspaceRoot "iteration-events.jsonl"
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $eventsPath -ErrorAction Stop)) {
        $lineNumber++
        if (-not $line) { continue }
        try { $event = $line | ConvertFrom-Json } catch {
            throw "Prepared-push retirement evidence search encountered malformed event JSON at iteration-events.jsonl:$lineNumber."
        }
        if ([string]$event.event_type -eq "push" -and @($event.receipts).Count) {
            $bound=$false
            foreach($reference in @($event.receipts)){
                try{$resolved=Resolve-MorphospaceWorkspacePath $WorkspaceRoot ([string]$reference) -RequireLeaf;$owned=Read-MorphospaceProtocolJson $resolved;if(@($owned.bundle_id,$owned.audit_receipt.bundle_id)-contains$BundleId){$bound=$true}}catch{}
            }
            if(-not$bound){continue}
            throw "Prepared-push retirement found a bundle-bound publication event at iteration-events.jsonl:$lineNumber."
        }
    }
}

function Invoke-MorphospacePreparedPushRetirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][string]$RepoMapPath,
        [Parameter(Mandatory=$true)][string]$RetirementReceipt,
        [string]$Timestamp = "",
        [string]$OutPath = "",
        [switch]$Execute
    )
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $receiptPath = (Resolve-Path -LiteralPath $RetirementReceipt).Path
    $receiptRelative = $null
    if ($Execute) {
        if (-not $OutPath) { throw "Executed prepared-push retirement requires OutPath for the retained receipt." }
        $retainedPath = [IO.Path]::GetFullPath($OutPath)
        $workspacePrefix = $workspace.TrimEnd("\","/") + [IO.Path]::DirectorySeparatorChar
        if (-not $retainedPath.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Prepared-push retirement OutPath must stay inside the workspace."
        }
        $receiptRelative = [IO.Path]::GetRelativePath($workspace,$retainedPath).Replace("\","/")
        if ($receiptRelative -notmatch "^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$") {
            throw "Prepared-push retirement OutPath must be a portable top-level receipts path."
        }
        if ([IO.File]::Exists($retainedPath)) { throw "Prepared-push retirement OutPath already exists." }
    }
    $receipt = Read-MorphospaceProtocolJson $receiptPath
    $schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\prepared-push-retirement-v1.schema.json"
    if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $receiptPath) -SchemaFile $schemaPath)) {
        throw "Prepared-push retirement receipt does not satisfy its schema."
    }
    $statePath = Join-Path $workspace "workspace.state.json"
    $state = Read-MorphospaceProtocolJson $statePath
    $spec = Read-MorphospaceProtocolJson (Join-Path $workspace "project.spec.json")
    $unitPath = "iteration-units/$UnitId.json"
    $unit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    $currentUnitBefore = $state.current_unit
    if ([string]$receipt.project_id -cne [string]$state.project_id -or [string]$receipt.project_id -cne [string]$spec.project_id) {
        throw "Prepared-push retirement project identity mismatch."
    }
    if ($null -eq $state.pending_push_bundle) { throw "Prepared-push retirement bundle was already consumed or is not pending." }
    if ([string]$state.pending_push_bundle.bundle_id -cne [string]$receipt.bundle_id) { throw "Prepared-push retirement bundle identity mismatch." }
    $pendingUnits = @($state.pending_push_bundle.unit_ids | ForEach-Object {[string]$_} | Sort-Object)
    $receiptUnits = @($receipt.unit_ids | ForEach-Object {[string]$_} | Sort-Object)
    if (($pendingUnits -join "`n") -cne ($receiptUnits -join "`n") -or $pendingUnits -notcontains $UnitId) {
        throw "Prepared-push retirement unit identities do not exactly match the pending bundle."
    }
    if((Get-MorphospaceCanonicalJsonSha256 $state.pending_push_bundle)-cne[string]$receipt.pending_bundle.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $receipt.pending_bundle.value)-cne[string]$receipt.pending_bundle.sha256){
        throw "Prepared-push retirement pending bundle canonical hash mismatch."
    }

    $planContainerPath = Resolve-PreparedPushRetirementFile $workspace $receipt.prepared_plan.container
    $planContainer = Read-MorphospaceProtocolJson $planContainerPath
    if ([string]$planContainer.schema -cne "rusty.morphospace.workflow.work_unit_automation_receipt.v1" -or
        [string]$planContainer.action -cne "PreparePush" -or -not $planContainer.executed -or
        [string]$planContainer.transition -cne "push-bundle-prepared" -or $null -eq $planContainer.push_plan) {
        throw "Prepared-push retirement plan owner is not an executed immutable PreparePush container."
    }
    $plan = $planContainer.push_plan
    $planSchemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) "schemas\legacy-embedded-push-bundle-plan-v1.schema.json"
    if (-not (Test-Json -Json ($plan | ConvertTo-Json -Depth 32) -SchemaFile $planSchemaPath)) {
        throw "Prepared-push retirement retained historical embedded plan is malformed or outside the additive legacy compatibility contract."
    }
    if ([string]$plan.schema -cne "rusty.morphospace.workflow.push_bundle_plan.v1" -or
        [string]$plan.execution -cne "not-performed" -or $plan.force_push_allowed -ne $false) {
        throw "Prepared-push retirement plan does not preserve the non-executing/no-force boundary."
    }
    if ([string]$plan.bundle_id -cne [string]$receipt.bundle_id -or [string]$plan.project_id -cne [string]$receipt.project_id -or
        (@($plan.unit_ids | Sort-Object) -join "`n") -cne ($receiptUnits -join "`n")) {
        throw "Prepared-push retirement immutable plan identities mismatch."
    }
    if ([string]$planContainer.event_id -cne [string]$receipt.prepared_event.event_id) {
        throw "Prepared-push retirement preparation event identity mismatch."
    }
    $intentPath = Resolve-PreparedPushRetirementFile $workspace $receipt.prepared_event.intent
    $completionPath = Resolve-PreparedPushRetirementFile $workspace $receipt.prepared_event.completion
    $intent = Read-MorphospaceProtocolJson $intentPath
    $completion = Read-MorphospaceProtocolJson $completionPath
    $eventChecks = [ordered]@{
        intent_schema = ([string]$intent.schema -ceq "rusty.morphospace.workflow.transition_ledger_intent.v1")
        intent_status = ([string]$intent.status -ceq "prepared")
        intent_event = ([string]$intent.event.event_id -ceq [string]$receipt.prepared_event.event_id)
        event_project = ([string]$intent.event.project_id -ceq [string]$receipt.project_id)
        event_unit = ([string]$intent.event.unit_id -ceq $UnitId)
        event_type = ([string]$intent.event.event_type -ceq "commit")
        completion_schema = ([string]$completion.schema -ceq "rusty.morphospace.workflow.transition_ledger_completion.v1")
        completion_status = ([string]$completion.status -ceq "committed")
        transaction = ([string]$completion.transaction_id -ceq [string]$intent.transaction_id)
        completion_event = ([string]$completion.event_id -ceq [string]$receipt.prepared_event.event_id)
        intent_hash = ([string]$completion.intent.sha256 -ceq (Get-MorphospaceFileSha256 $intentPath))
    }
    $failedEventChecks = @($eventChecks.Keys | Where-Object { -not $eventChecks[$_] })
    if ($failedEventChecks.Count) {
        throw "Prepared-push retirement preparation event owner containers do not form the committed original event: $($failedEventChecks -join ', ')."
    }
    if (@($intent.event.receipts) -notcontains [string]$receipt.prepared_plan.container.path) {
        throw "Prepared-push retirement preparation event does not link to the exact plan owner container."
    }

    $repoMap = Read-MorphospaceProtocolJson (Resolve-Path -LiteralPath $RepoMapPath)
    if ([string]$repoMap.schema -cne "rusty.morphospace.workflow.repository_map.v1") { throw "Prepared-push retirement repository map schema mismatch." }
    $map = @{}; foreach ($entry in @($repoMap.repositories)) {
        if ($map.ContainsKey([string]$entry.repo_id)) { throw "Prepared-push retirement repository map repeats an identity." }
        $map[[string]$entry.repo_id] = $entry
    }
    $planIds = @($plan.repositories | ForEach-Object {[string]$_.repo_id} | Sort-Object)
    $pendingIds = @($state.pending_push_bundle.repo_ids | ForEach-Object {[string]$_} | Sort-Object)
    $receiptIds = @($receipt.repositories | ForEach-Object {[string]$_.repo_id} | Sort-Object)
    if (($planIds -join "`n") -cne ($pendingIds -join "`n") -or ($planIds -join "`n") -cne ($receiptIds -join "`n") -or
        @($planIds | Select-Object -Unique).Count -ne $planIds.Count) {
        throw "Prepared-push retirement repository coverage is incomplete or mismatched."
    }
    $physicalGroups=@{}
    foreach($planRepo in @($plan.repositories)){
        if([string]$planRepo.role -notin @('application','adapter','source','planning')){throw "Prepared-push retirement plan has unsupported legacy role."}
        $mapPath=[IO.Path]::GetFullPath([string]$map[[string]$planRepo.repo_id].path).ToLowerInvariant()
        $key="$mapPath|$([string]$planRepo.branch)|$([string]$planRepo.upstream)"
        if(-not$physicalGroups.ContainsKey($key)){$physicalGroups[$key]=@()}
        $physicalGroups[$key]=@($physicalGroups[$key])+$planRepo
    }
    $first = @(); foreach ($planRepo in @($plan.repositories)) {
        $repoId = [string]$planRepo.repo_id
        if (-not $map.ContainsKey($repoId)) { throw "Prepared-push retirement repository '$repoId' is not mapped." }
        $allowedPreparationPaths = @()
        if ([string]$planRepo.role -eq "planning") {
            $repoRoot = [IO.Path]::GetFullPath([string]$map[$repoId].path)
            foreach ($relative in @(
                [string]$receipt.prepared_plan.container.path,
                [string]$receipt.prepared_event.intent.path,
                [string]$receipt.prepared_event.completion.path,
                "workspace.state.json", "iteration-events.jsonl"
            )) {
                $absolute = Resolve-MorphospaceWorkspacePath $workspace $relative
                $allowedPreparationPaths += [IO.Path]::GetRelativePath($repoRoot, $absolute).Replace("\","/")
            }
        }
        $mapPath=[IO.Path]::GetFullPath([string]$map[$repoId].path).ToLowerInvariant();$groupKey="$mapPath|$([string]$planRepo.branch)|$([string]$planRepo.upstream)"
        $aliases=@($physicalGroups[$groupKey]);$sourceLike=@($aliases|Where-Object{[string]$_.role-ne'planning'}).Count-gt0
        if(@($aliases|ForEach-Object{[string]$_.commit}|Sort-Object -Unique).Count-ne1){throw "Prepared-push retirement alias revision mismatch."}
        $existing=@($first|Where-Object physical_key -eq "$mapPath|$((Invoke-PreparedPushGit ([string]$map[$repoId].path) @('config','--get',"branch.$([string]$planRepo.branch).remote")).text)|$((Invoke-PreparedPushGit ([string]$map[$repoId].path) @('config','--get',"branch.$([string]$planRepo.branch).merge")).text)")
        $observed=if($existing.Count){$clone=$existing[0].psobject.Copy();$clone.repo_id=$repoId;$clone.role=[string]$planRepo.role;$clone}else{Get-PreparedPushRepositoryObservation $planRepo $map[$repoId] $allowedPreparationPaths -SourceLike:$sourceLike}
        $declared = @($receipt.repositories | Where-Object {[string]$_.repo_id -eq $repoId})
        if ($declared.Count -ne 1) { throw "Prepared-push retirement repository '$repoId' is not declared exactly once." }
        Assert-PreparedPushObservationEqual $declared[0] $observed
        $first += $observed
    }
    if(@($first|Group-Object physical_key|Where-Object{$_.Group[0].prepared_reachable-ne$true}).Count-eq0){
        throw "Prepared-push retirement requires at least one distinct prepared revision that is not remotely reachable; use prepared-publication reconstruction."
    }
    Test-PreparedPushConflictingEvidence $workspace ([string]$receipt.bundle_id) @(
        [string]$receipt.prepared_plan.container.path,
        [string]$receipt.prepared_event.intent.path, [string]$receipt.prepared_event.completion.path
    )
    foreach ($planRepo in @($plan.repositories)) {
        $allowedPreparationPaths = @()
        if ([string]$planRepo.role -eq "planning") {
            $repoRoot = [IO.Path]::GetFullPath([string]$map[[string]$planRepo.repo_id].path)
            foreach ($relative in @([string]$receipt.prepared_plan.container.path,[string]$receipt.prepared_event.intent.path,[string]$receipt.prepared_event.completion.path,"workspace.state.json","iteration-events.jsonl")) {
                $allowedPreparationPaths += [IO.Path]::GetRelativePath($repoRoot,(Resolve-MorphospaceWorkspacePath $workspace $relative)).Replace("\","/")
            }
        }
        $aliases=@($physicalGroups.Values|Where-Object{@($_|Where-Object{[string]$_.repo_id-eq[string]$planRepo.repo_id}).Count})
        $sourceLike=@($aliases|ForEach-Object{$_}|Where-Object{[string]$_.role-ne'planning'}).Count-gt0
        $second = Get-PreparedPushRepositoryObservation $planRepo $map[[string]$planRepo.repo_id] $allowedPreparationPaths -SourceLike:$sourceLike
        Assert-PreparedPushObservationEqual (@($first | Where-Object repo_id -eq ([string]$planRepo.repo_id))[0]) $second
    }

    $blockerId = [string]$receipt.stale_blocker.value.blocker_id
    $blockers=@($state.blockers|Where-Object{[string]$_.blocker_id-ceq$blockerId})
    if($blockers.Count-ne1-or(Get-MorphospaceCanonicalJsonSha256 $blockers[0])-cne[string]$receipt.stale_blocker.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $receipt.stale_blocker.value)-cne[string]$receipt.stale_blocker.sha256){throw "Prepared-push retirement stale blocker canonical hash mismatch."}
    if($null-ne$receipt.mutation.blocker_id-and[string]$receipt.mutation.blocker_id-cne$blockerId){throw "Prepared-push retirement blocker identity mismatch."}
    $receiptHash = Get-MorphospaceFileSha256 $receiptPath
    $eventsPath = Join-Path $workspace "iteration-events.jsonl"
    $events = @(Get-Content -LiteralPath $eventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $sequence = if ($events.Count) { [int](($events | Sort-Object sequence | Select-Object -Last 1).sequence) + 1 } else { 1 }
    $eventId = "$UnitId-prepared-push-retired-$('{0:d4}' -f $sequence)"
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString("o") }
    $event = [pscustomobject][ordered]@{
        schema = "rusty.morphospace.workflow.iteration_event.v1"; event_id = $eventId; sequence = $sequence
        timestamp = $Timestamp; project_id = [string]$receipt.project_id; unit_id = $UnitId; event_type = "push"
        summary = "Retired one exact unexecuted prepared push bundle without asserting historical non-publication or mutating Git, remotes, validation, acceptance, or unit history."
        receipts = @($receiptRelative)
    }
    if ($Execute) {
        $preStateHash=Get-MorphospaceCanonicalJsonSha256 $state
        $preTail=if($events.Count){[string]$events[-1].event_id}else{$null}
        $state.pending_push_bundle = $null
        if ($null -ne $blockerId) { $state.blockers = @($state.blockers | Where-Object {[string]$_.blocker_id -cne [string]$blockerId}) }
        $state.last_event_id = $eventId
        Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$eventId-transition" `
            -StatePath "workspace.state.json" -UnitPath $unitPath -EventsPath "iteration-events.jsonl" `
            -TargetState $state -TargetUnit $unit -Event $event -ExpectedStateSha256 $preStateHash -ExpectedEventTailId $preTail `
            -Artifacts @([pscustomobject]@{source_path=$receiptPath;path=$receiptRelative;sha256=$receiptHash}) | Out-Null
    }
    $result=[pscustomobject][ordered]@{
        schema = "rusty.morphospace.workflow.work_unit_automation_receipt.v2"
        project_id = [string]$receipt.project_id; unit_id = $UnitId; action = "RetirePreparedPush"
        timestamp = $Timestamp; executed = $Execute.IsPresent; transition = "prepared-push-retired"
        status_before = [string]$unit.status; status_after = [string]$unit.status
        current_unit_before = $currentUnitBefore; current_unit_after = $state.current_unit
        preservation = [pscustomobject][ordered]@{ git_mutation_performed=$false; device_mutation_performed=$false; remote_mutation_performed=$false }
        audit_receipt=[pscustomobject]@{path=$(if($receiptRelative){$receiptRelative}else{"receipts/$([string]$receipt.retirement_id).json"});sha256=$receiptHash}
        event_id = if ($Execute) {$eventId} else {$null}
    }
    $outputSchema=Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\work-unit-automation-receipt-v2.schema.json'
    if(-not(Test-Json -Json ($result|ConvertTo-Json -Depth 32) -SchemaFile $outputSchema)){throw 'Prepared-push retirement emitted an invalid automation receipt.'}
    $result
}

Export-ModuleMember -Function Invoke-MorphospacePreparedPushRetirement
