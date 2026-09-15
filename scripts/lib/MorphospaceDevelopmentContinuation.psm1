Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')

function Assert-DevelopmentContinuationEqual {
    param([object]$Expected, [object]$Actual, [string]$Context)
    if ($null -eq $Expected -or $null -eq $Actual) {
        if ($null -eq $Expected -and $null -eq $Actual) { return }
        throw "Development continuation $Context is detached."
    }
    if ((Get-MorphospaceCanonicalJsonSha256 $Expected) -cne (Get-MorphospaceCanonicalJsonSha256 $Actual)) {
        throw "Development continuation $Context is detached."
    }
}

function Read-DevelopmentContinuationBinding {
    param([string]$Workspace, [string]$Path, [string]$RawSha256)
    $absolute = Resolve-MorphospaceWorkspacePath $Workspace $Path -RequireLeaf
    if ((Get-MorphospaceFileSha256 $absolute) -cne $RawSha256) { throw "Development continuation immutable binding changed: $Path" }
    Read-MorphospaceProtocolJson $absolute
}

function Get-DevelopmentContinuationArtifact {
    param([object]$Intent, [string]$Schema)
    $matches = @()
    foreach ($artifact in @($Intent.artifacts)) {
        $bytes = [Convert]::FromBase64String([string]$artifact.bytes_base64)
        if ((Get-MorphospaceSha256Bytes $bytes) -cne [string]$artifact.sha256) { throw 'Development continuation artifact bytes are detached.' }
        $document = ConvertFrom-MorphospaceProtocolJsonBytes $bytes
        if ([string]$document.schema -ceq $Schema) { $matches += ,[pscustomobject]@{ binding=$artifact; document=$document } }
    }
    if ($matches.Count -gt 1) { throw "Development continuation repeats an artifact schema: $Schema" }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Assert-DevelopmentContinuationStableAuthority {
    param([object]$Before, [object]$After, [string[]]$Mutable, [string]$Context)
    $beforeNames = @($Before.PSObject.Properties.Name | Where-Object { $Mutable -cnotcontains $_ } | Sort-Object -CaseSensitive)
    $afterNames = @($After.PSObject.Properties.Name | Where-Object { $Mutable -cnotcontains $_ } | Sort-Object -CaseSensitive)
    Assert-DevelopmentContinuationEqual $beforeNames $afterNames "$Context property set"
    foreach ($name in $beforeNames) { Assert-DevelopmentContinuationEqual $Before.$name $After.$name "$Context/$name" }
}

function Assert-DevelopmentContinuationRetainedAuthority {
    param([object]$Before, [object]$After, [object]$Intent, [object]$Event)
    Assert-DevelopmentContinuationStableAuthority $Before $After @('status','instruction_surfaces') 'retained authority'
    $beforeProperty=$Before.PSObject.Properties['instruction_surfaces']
    $afterProperty=$After.PSObject.Properties['instruction_surfaces']
    if(($null-eq$beforeProperty)-ne($null-eq$afterProperty)){throw 'Development continuation changes the instruction surface property set.'}
    if($null-eq$beforeProperty){return}
    if((Get-MorphospaceCanonicalJsonSha256 $beforeProperty.Value)-ceq(Get-MorphospaceCanonicalJsonSha256 $afterProperty.Value)){return}
    $expected=ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes(($Before|ConvertTo-Json -Depth 100)))
    $planned=@($expected.instruction_surfaces|Where-Object{[string]$_.status-ceq'planned'})
    if($planned.Count-eq0){throw 'Development continuation changes completed instruction surfaces.'}
    foreach($surface in @($expected.instruction_surfaces)){
        if([string]$surface.status-ceq'planned'){$surface.status='complete'}
        elseif([string]$surface.status-cne'complete'){throw 'Development continuation has an unsupported instruction status.'}
    }
    Assert-DevelopmentContinuationEqual $expected.instruction_surfaces $After.instruction_surfaces 'completed instruction surface identities'
    Assert-DevelopmentContinuationEqual $Before.status $After.status 'instruction completion status'
    $receiptArtifact=Get-DevelopmentContinuationArtifact $Intent 'rusty.morphospace.workflow.work_unit_automation_receipt.v1'
    if($null-eq$receiptArtifact-or@($Intent.artifacts).Count-ne1){throw 'Development continuation instruction completion requires exactly one owner receipt.'}
    $receipt=$receiptArtifact.document
    $ownerRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if(-not(Test-Json -Json ($receipt|ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $ownerRoot 'schemas/work-unit-automation-receipt.schema.json') -ErrorAction SilentlyContinue)){
        throw 'Development continuation instruction-completion receipt schema is invalid.'
    }
    $binding=$receipt.instruction_surface_completion
    if([string]$receipt.action-cne'CompleteInstructionSurfaces'-or$receipt.executed-ne$true-or
        [string]$receipt.transition-cne'planned-instruction-surfaces-to-complete'-or
        [string]$receipt.unit_id-cne[string]$Event.unit_id-or[string]$receipt.project_id-cne[string]$Event.project_id-or
        [string]$receipt.event_id-cne[string]$Event.event_id-or[string]$Event.event_id-cne"$([string]$binding.completion_id)-recorded"-or
        [string]$Event.event_type-cne'state-transition'-or
        [string]$Event.summary-cne'Completed the exact declared instruction-surface set after stable content observation without executing validation commands.'-or
        @($Event.receipts).Count-ne1-or[string]$Event.receipts[0]-cne[string]$receiptArtifact.binding.path-or
        $binding.all_planned_surfaces_completed-ne$true-or$binding.surface_files_observed_stable-ne$true-or$binding.validation_commands_executed-ne$false-or
        [string]$binding.expected_unit_sha256-cne[string]$Intent.pre.unit.sha256-or[string]$binding.resulting_unit_sha256-cne[string]$Intent.target.unit.sha256){
        throw 'Development continuation instruction-completion receipt is detached.'
    }
}

function Get-MorphospaceDevelopmentEnvelopeContinuation {
    <# Authenticates the active owner's continuation, not acceptance or publication.
       The preparation reader separately authenticates the immutable origin.
       No caller can supply a substituted origin, projection, or skip predicate. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [Parameter(Mandatory)][object]$Admission)
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $ownerRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not (Test-Json -Json ($Admission | ConvertTo-Json -Depth 100) -SchemaFile (Join-Path $ownerRoot 'schemas/development-unit-admission-v1.schema.json'))) { throw 'Development continuation admission schema is invalid.' }
    $unitId = [string]$Admission.unit_id
    $projectId = [string]$Admission.project_id
    $unitPath = "iteration-units/$unitId.json"
    $liveUnit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace $unitPath -RequireLeaf)
    $liveState = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
    $original = Read-DevelopmentContinuationBinding $workspace ([string]$Admission.preparation.receipt_path) ([string]$Admission.preparation.receipt_sha256)
    $sourcePath = [string]$Admission.preparation.source_composition_path
    $source = Read-DevelopmentContinuationBinding $workspace $sourcePath ([string]$Admission.preparation.source_composition_sha256)
    $sourceSha = [string]$Admission.preparation.source_composition_sha256
    $mapPath = [string]$Admission.expected.repository_map_path
    $mapSha = [string]$Admission.expected.repository_map_sha256
    $null = Read-DevelopmentContinuationBinding $workspace $mapPath $mapSha
    $project = $original.envelope.project
    $featureLock = $original.envelope.feature_lock
    $events = @(Get-Content -LiteralPath (Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf) | Where-Object { $_ } | ForEach-Object {
        ConvertFrom-MorphospaceProtocolJsonBytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$_))
    })
    $admissionEventId = "$([string]$Admission.admission_id)-admitted"
    $indices = @(for ($index=0; $index -lt $events.Count; $index++) { if ([string]$events[$index].event_id -ceq $admissionEventId) { $index } })
    if ($indices.Count -ne 1) { throw 'Development continuation admission event is missing or ambiguous.' }
    $admissionIndex = [int]$indices[0]
    $admissionProof = Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId "$admissionEventId-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $unitPath -ExpectedEventsPath 'iteration-events.jsonl'
    Assert-DevelopmentContinuationEqual $events[$admissionIndex] $admissionProof.intent.event 'admission event'
    Assert-DevelopmentContinuationEqual $Admission.unit $admissionProof.intent.target.unit.document 'admitted unit'
    $admissionArtifact = Get-DevelopmentContinuationArtifact $admissionProof.intent 'rusty.morphospace.workflow.development_unit_admission.v1'
    if ($null -eq $admissionArtifact) { throw 'Development continuation lacks its transaction-owned admission receipt.' }
    Assert-DevelopmentContinuationEqual $Admission $admissionArtifact.document 'admission receipt'
    $previous = $admissionProof.intent
    $currentUnit = $previous.target.unit.document
    $records = @()
    $extensions = @()
    $toolingUpgrades = @()
    $frozen = $false
    for ($index=$admissionIndex+1; $index -lt $events.Count; $index++) {
        $event = $events[$index]
        if ([string]$event.unit_id -cne $unitId -or [string]$event.project_id -cne $projectId) { throw 'Development continuation interleaves another owner unit.' }
        if ([int]$event.sequence -ne ([int]$previous.event.sequence+1)) { throw 'Development continuation is not contiguous.' }
        $proof = Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId "$([string]$event.event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $unitPath -ExpectedEventsPath 'iteration-events.jsonl'
        $intent = $proof.intent
        Assert-DevelopmentContinuationEqual $event $intent.event 'event'
        if ([string]$intent.pre.state.sha256 -cne [string]$previous.target.state.sha256 -or [string]$intent.pre.unit.sha256 -cne [string]$previous.target.unit.sha256) { throw 'Development continuation state/unit chain is detached.' }
        $targetUnit = $intent.target.unit.document
        $targetState = $intent.target.state.document
        $offset = $index-$admissionIndex
        $kind = ''
        if ($offset -le 2) {
            $slug = if ($offset -eq 1) { 'ready' } else { 'claimed' }
            $status = if ($offset -eq 1) { 'ready' } else { 'active' }
            $summary = if ($offset -eq 1) { 'Reviewed the bounded proposal and made it claimable without expanding its repositories, paths, or prerequisites.' } else { 'Claimed one ready iteration unit without expanding repository or path scope.' }
            if ([string]$event.event_type -cne 'state-transition' -or [string]$event.event_id -cnotmatch ('^'+[regex]::Escape($unitId)+'-'+$slug+'-[0-9]{4}$') -or [string]$event.summary -cne $summary -or @($event.receipts).Count -ne 0 -or [string]$targetUnit.status -cne $status) { throw "Development continuation $slug is not the ordinary owner transition." }
            Assert-DevelopmentContinuationStableAuthority $currentUnit $targetUnit @('status') $slug
            if ($offset -eq 1 -and ($null -ne $targetState.current_unit -or [string]$targetState.next_ready_unit -cne $unitId)) { throw 'Development continuation Ready selector is detached.' }
            if ($offset -eq 2 -and ([string]$targetState.current_unit -cne $unitId -or $null -ne $targetState.next_ready_unit)) { throw 'Development continuation Claim ownership is detached.' }
            $kind = $slug
        } else {
            $extension = Get-DevelopmentContinuationArtifact $intent 'rusty.morphospace.workflow.active_development_envelope_extension.v1'
            $upgrade = Get-DevelopmentContinuationArtifact $intent 'rusty.morphospace.workflow.tooling_context_upgrade.v1'
            $amendment = Get-DevelopmentContinuationArtifact $intent 'rusty.morphospace.workflow.active_write_scope_amendment.v1'
            if(@(@($extension,$upgrade,$amendment)|Where-Object{$null-ne$_}).Count-gt1){throw 'Development continuation mixes distinct owner actions.'}
            if ($null -ne $extension) {
                if ($frozen) { throw 'Development continuation extends an already frozen envelope.' }
                $extensionModule = Import-Module (Join-Path $PSScriptRoot '../ActiveDevelopmentEnvelopeExtension.psm1') -PassThru
                $null = & $extensionModule { param($root,$expected,$transition) Assert-ActiveEnvelopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $expected -Transition $transition } $workspace $event $proof
                $request = $extension.document
                if ((Get-MorphospaceCanonicalJsonSha256 $project) -cne [string]$request.expected.project_sha256 -or
                    (Get-MorphospaceCanonicalJsonSha256 $featureLock) -cne [string]$request.expected.feature_lock_sha256) { throw 'Development continuation extension project or feature-lock preimage is detached.' }
                $project = $request.target.project
                $featureLock = $request.target.feature_lock
                $derived = Get-DevelopmentContinuationArtifact $intent 'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'
                if ($null -eq $derived -or [string]$derived.document.parent.path -cne $sourcePath -or [string]$derived.document.parent.raw_sha256 -cne $sourceSha) { throw 'Development continuation source parent is detached.' }
                $source = $derived.document
                $sourcePath = [string]$derived.binding.path
                $sourceSha = [string]$derived.binding.sha256
                $mapPath = [string]$source.repository_map.path
                $mapSha = [string]$source.repository_map.raw_sha256
                $null = Read-DevelopmentContinuationBinding $workspace $mapPath $mapSha
                $extensions += ,$proof
                $kind = 'extension'
            } elseif ($null -ne $upgrade) {
                if ($frozen) { throw 'Development continuation upgrades frozen tooling.' }
                $expectedProjection=[pscustomobject][ordered]@{
                    source_composition=[pscustomobject]@{path=$sourcePath;sha256=$sourceSha}
                    repository_map=[pscustomobject]@{path=$mapPath;sha256=$mapSha}
                    feature_lock=[pscustomobject]@{path='feature.lock.json';sha256=(Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $featureLock))}
                }
                Assert-DevelopmentContinuationEqual $expectedProjection $upgrade.document.product_projection 'tooling upgrade effective product projection'
                $newContext=Get-DevelopmentContinuationArtifact $intent 'rusty.morphospace.workflow.tooling_context.v1'
                if($null-eq$newContext){throw 'Development continuation tooling upgrade has no new context.'}
                Assert-DevelopmentContinuationEqual $expectedProjection $newContext.document.product_projection 'new tooling context effective product projection'
                $toolingUpgradeModule = Import-Module (Join-Path $PSScriptRoot '../ToolingContextUpgrade.psm1') -PassThru
                $null = & $toolingUpgradeModule { param($root,$expected,$transition,$projection) Assert-ToolingContextHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $expected -Transition $transition -ExpectedProductProjection $projection } $workspace $event $proof $expectedProjection
                Assert-DevelopmentContinuationStableAuthority $currentUnit $targetUnit @('tooling_context') 'tooling upgrade'
                $toolingUpgrades += ,$proof
                $kind = 'tooling-upgrade'
            } elseif ($null -ne $amendment) {
                if ($frozen) { throw 'Development continuation amends frozen scope.' }
                $amendmentModule = Import-Module (Join-Path $PSScriptRoot '../ActiveWriteScopeAmendment.psm1') -PassThru
                $null = & $amendmentModule { param($root,$expected,$transition) Assert-ActiveWriteScopeHistoricalTransition -WorkspaceRoot $root -ExpectedEvent $expected -Transition $transition } $workspace $event $proof
                $kind = 'amendment'
            } elseif ($targetUnit.PSObject.Properties.Name -contains 'candidate_freeze' -and -not ($currentUnit.PSObject.Properties.Name -contains 'candidate_freeze')) {
                if ([string]$event.event_id -cne "$([string]$targetUnit.candidate_freeze.freeze_id)-recorded" -or [string]$event.summary -cne 'Froze the exact candidate closure before validation.' -or @($event.receipts).Count -ne 1 -or [string]$event.receipts[0] -cne [string]$targetUnit.candidate_freeze.receipt_path) { throw 'Development continuation candidate Freeze is detached.' }
                Assert-DevelopmentContinuationStableAuthority $currentUnit $targetUnit @('candidate_freeze') 'Freeze'
                $frozen = $true
                $kind = 'freeze'
            } else {
                # Later lifecycle readers retain their own validation and acceptance
                # predicates. This view never permits them to rewrite the envelope.
                Assert-DevelopmentContinuationRetainedAuthority $currentUnit $targetUnit $intent $event
                $kind = 'retained-envelope'
            }
        }
        $projections = @(if ($intent.PSObject.Properties.Name -contains 'additional_projections') { $intent.additional_projections })
        if ($kind -eq 'extension') {
            foreach ($pair in @(@('project.spec.json',$project),@('feature.lock.json',$featureLock))) {
                $matches = @($projections | Where-Object { [string]$_.path -ceq [string]$pair[0] })
                if ($matches.Count -ne 1) { throw 'Development continuation extension projection set is incomplete.' }
                Assert-DevelopmentContinuationEqual $pair[1] $matches[0].document 'extension target'
            }
            if ($projections.Count -ne 2) { throw 'Development continuation extension has an extra projection.' }
        } elseif ($projections.Count -ne 0) {
            # Freeze and retirement fence these documents with unchanged
            # projections. An unchanged fence is not a new envelope authority.
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($projection in $projections){
                $path=[string]$projection.path
                if(-not$seen.Add($path)){throw 'Development continuation repeats a retained projection.'}
                $expected=switch -CaseSensitive ($path){'project.spec.json'{$project};'feature.lock.json'{$featureLock};default{throw 'Development continuation adds an unknown retained projection.'}}
                $hash=Get-MorphospaceCanonicalJsonSha256 $expected
                if([string]$projection.pre_sha256-cne$hash-or[string]$projection.target_sha256-cne$hash){throw 'Development continuation changes the envelope outside its extension action.'}
                Assert-DevelopmentContinuationEqual $expected $projection.document 'retained projection'
            }
        }
        $records += ,[pscustomobject]@{kind=$kind;event=$event;transition=$proof}
        $previous = $intent
        $currentUnit = $targetUnit
    }
    if ($records.Count -lt 2) { throw 'Development continuation requires the completed ordinary Ready and Claim chain.' }
    Assert-DevelopmentContinuationEqual $liveUnit $currentUnit 'live unit'
    Assert-DevelopmentContinuationEqual $liveState $previous.target.state.document 'live state'
    Assert-DevelopmentContinuationEqual $project (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf)) 'live project'
    Assert-DevelopmentContinuationEqual $featureLock (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf)) 'live feature lock'
    if ([string]$liveUnit.source_composition.lock_path -cne $sourcePath) { throw 'Development continuation live source pointer is detached.' }
    [pscustomobject]@{
        admission=$Admission; preparation=$original; admission_proof=$admissionProof
        project=$project; feature_lock=$featureLock; source_composition=$source
        source_composition_binding=[pscustomobject]@{path=$sourcePath;raw_sha256=$sourceSha}
        repository_map=[pscustomobject]@{path=$mapPath;raw_sha256=$mapSha}
        unit=$liveUnit; state=$liveState; event_tail=$events[-1]
        records=@($records); extensions=@($extensions); tooling_upgrades=@($toolingUpgrades)
    }
}

Export-ModuleMember -Function Get-MorphospaceDevelopmentEnvelopeContinuation
