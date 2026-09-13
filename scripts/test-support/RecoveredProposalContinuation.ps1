# Called with an admission produced by the shared preparation, retirement,
# repreparation and admission fixture through the ordinary owner writers.
function New-RecoveredProposalContinuationFixture {
    param([string]$BaseRepository, [string]$FixtureRoot, [object]$RepreparationTemplate, [object]$AdmissionTemplate, [object]$RepreparationModule)
    $fixture = New-EnvelopeRepreparationFixture $BaseRepository $FixtureRoot $RepreparationTemplate
    $workspace = $fixture.workspace
    $repreparationOut = Join-Path $workspace 'receipts/u003-envelope-recovery-repreparation.json'
    $repreparationHash = Get-EnvelopeFileSha256 $fixture.input_path
    &$RepreparationModule { param($arguments) Invoke-MorphospaceReprepareRetiredDevelopmentEnvelope @arguments } @{
        WorkspaceRoot=$workspace; DevelopmentEnvelopeRepreparation=$fixture.input_path
        ExpectedDevelopmentEnvelopeRepreparationSha256=$repreparationHash; OutPath=$repreparationOut
        Timestamp='2026-08-25T00:01:40.0000000Z'; Execute=$true
    } | Out-Null
    $admission = New-EnvelopeReplacementAdmission -Template $AdmissionTemplate -Workspace $workspace -AdmissionId 'u003-admission' -UnitId 'u003'
    $admission.preparation = [ordered]@{
        preparation_kind='recovered'; preparation_id='u003-envelope'; receipt_path='receipts/u003-envelope.json'
        receipt_sha256=(Get-EnvelopeFileSha256 (Join-Path $workspace 'receipts/u003-envelope.json'))
        source_composition_path='source-composition-locks/u003-envelope.json'
        source_composition_sha256=(Get-EnvelopeFileSha256 (Join-Path $workspace 'source-composition-locks/u003-envelope.json'))
        recovery_receipt_path='receipts/u003-envelope-recovery-repreparation.json'; recovery_receipt_sha256=(Get-EnvelopeFileSha256 $repreparationOut)
    }
    $admission.unit.source_composition.lock_path = 'source-composition-locks/u003-envelope.json'
    $admission.expected.project_sha256 = Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json'))
    $admission.expected.feature_lock_sha256 = Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json'))
    $admission.expected.source_composition_path = 'source-composition-locks/u003-envelope.json'
    $admission.expected.source_composition_sha256 = $admission.preparation.source_composition_sha256
    $admission.expected.repository_map_sha256 = Get-EnvelopeFileSha256 (Join-Path $workspace 'repository-map.json')
    $admissionPath = Join-Path $FixtureRoot 'u003-recovered-admission.json'
    Write-EnvelopeJson $admissionPath $admission
    $admissionOut = Join-Path $workspace 'receipts/u003-admission.json'
    $dry = Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -OutPath $admissionOut -Timestamp '2026-08-25T00:01:50.0000000Z'
    $run = Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 $dry.audit_receipt.sha256 -OutPath $admissionOut -Timestamp '2026-08-25T00:01:50.0000000Z' -Execute
    Assert-Envelope ($run.transition -ceq 'development-unit-admitted' -and (Test-Path (Join-Path $workspace 'iteration-units/u003.json'))) 'isolated continuation fixture did not admit the recovered proposal'
    [pscustomobject]@{ workspace=$workspace; repository=$fixture.repository; admission=$admission; admission_path=$admissionPath }
}

function Invoke-RecoveredContinuationPublicValidation {
    param([string]$WorkspaceRoot, [string]$ScriptsRoot)
    $pwshPath = (Get-Process -Id $PID).Path
    $validatorPath = Join-Path $ScriptsRoot 'Test-WorkflowContracts.ps1'
    $repoRoot = Split-Path $ScriptsRoot -Parent
    $childArguments = @(
        '-NoProfile', '-File', $validatorPath,
        '-RepoRoot', $repoRoot,
        '-WorkspaceRoot', $WorkspaceRoot,
        '-RepositoryMapPath', (Join-Path $WorkspaceRoot 'repository-map.json'),
        '-CurrentWorkOnly', '-SkipOwnerSelfTests'
    )
    $PSNativeCommandUseErrorActionPreference = $false
    $output = (& $pwshPath @childArguments 2>&1 | Out-String).Trim()
    [pscustomobject]@{ exit_code = $LASTEXITCODE; output = $output }
}

function Test-RecoveredPreparedAdmission {
    param([string]$RetiredWorkspace,[string]$TestRoot,[string]$ScriptsRoot,[string]$RecoveryRelative)
    # Branch before the later acceptance fixture can seal the malformed admission.
    $workspace = Join-Path $TestRoot 'prepared-from-original-checkpoint'
    Copy-Item -LiteralPath $RetiredWorkspace -Destination $workspace -Recurse
    $originalAccepted = [string](Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')).last_accepted_receipt
    $preservedPaths = @(
        'iteration-units/u001.json','iteration-units/u003.json',$originalAccepted,
        'receipts/u003-admission.json','receipts/u003-recovered-retirement.json',
        'receipts/transactions/u003-admission-admitted-transition.intent.json',
        'receipts/transactions/u003-admission-admitted-transition.completion.json',
        $RecoveryRelative
    )
    $preserved = @($preservedPaths | ForEach-Object { [pscustomobject]@{path=$_;sha256=(Get-EnvelopeFileSha256 (Join-Path $workspace $_))} })
    $map = Read-EnvelopeProtocolJson (Join-Path $workspace 'repository-map.json')
    $planning = @($map.repositories | Where-Object { [string]$_.repo_id -ceq 'project-shell' })
    Assert-Envelope ($planning.Count -eq 1) 'fresh continuation lacks its one fixture planning owner'
    $repository = [IO.Path]::GetFullPath([string]$planning[0].path)
    $testPrefix = [IO.Path]::GetFullPath($TestRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    Assert-Envelope (($repository + [IO.Path]::DirectorySeparatorChar).StartsWith($testPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath (Join-Path $repository '.git'))) 'fresh continuation planning repository escaped its test root'
    Get-ChildItem -LiteralPath $workspace -Force | Copy-Item -Destination (Join-Path $repository 'morphospace') -Recurse -Force
    Invoke-EnvelopeGit $repository @('add','morphospace') | Out-Null
    Invoke-EnvelopeGit $repository @('commit','-m','fixture original checkpoint recovered retirement') | Out-Null

    $project = Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json')
    $state = Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')
    $featureLock = Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json')
    $targetProject = Copy-Envelope $project; $targetProject.revision = [int]$project.revision + 1
    $targetLock = Copy-Envelope $featureLock; $targetLock.revision = [int]$featureLock.revision + 1
    $targetLock.project_revision = [int]$targetProject.revision
    $targetLock.generated_at = '2026-08-25T00:02:03.0000000Z'; $targetLock.lock_fingerprint = Get-EnvelopeLockFingerprint $targetLock
    $envelope = Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $workspace 'receipts/u003-envelope.json')).envelope
    $envelope.project = $targetProject; $envelope.feature_lock = $targetLock
    $envelope.PSObject.Properties.Remove('schema_pin_revision')
    $envelope.source_composition.path = 'source-composition-locks/u004-envelope.json'
    $eventsPath = Join-Path $workspace 'iteration-events.jsonl'
    $tail = @(Get-Content -LiteralPath $eventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })[-1]
    $predecessor = Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u001.json')
    $preparation = [ordered]@{
        schema='rusty.morphospace.workflow.development_envelope_preparation.v1'; preparation_id='u004-envelope'
        project_id=[string]$project.project_id; predecessor_unit_id='u001'; envelope=$envelope
        expected=[ordered]@{
            project_sha256=(Get-EnvelopeCanonicalJsonSha256 $project); state_sha256=(Get-EnvelopeCanonicalJsonSha256 $state)
            feature_lock_sha256=(Get-EnvelopeCanonicalJsonSha256 $featureLock); repository_map_path='repository-map.json'
            repository_map_sha256=(Get-EnvelopeFileSha256 (Join-Path $workspace 'repository-map.json'))
            predecessor_unit_path='iteration-units/u001.json'; predecessor_unit_sha256=(Get-EnvelopeCanonicalJsonSha256 $predecessor)
            events_sha256=(Get-EnvelopeFileSha256 $eventsPath); events_length=([IO.FileInfo]$eventsPath).Length; event_tail_id=[string]$tail.event_id
        }
        does_not_prove=@('Does not admit a unit or grant validation credit.')
    }
    $preparationPath = Join-Path $TestRoot 'original-checkpoint-preparation.json'
    Write-EnvelopeJson $preparationPath $preparation
    $automation = Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1'
    $prepared = & $automation -Action PrepareDevelopmentEnvelope -WorkspaceRoot $workspace -DevelopmentEnvelopePreparation $preparationPath -ExpectedDevelopmentEnvelopePreparationSha256 (Get-EnvelopeFileSha256 $preparationPath) -OutPath (Join-Path $workspace 'receipts/u004-envelope.json') -Timestamp '2026-08-25T00:02:03.0000000Z' -Execute | ConvertFrom-Json
    Assert-Envelope $prepared.executed 'fresh continuation preparation did not execute'
    $publicBefore = Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    $public = Invoke-RecoveredContinuationPublicValidation -WorkspaceRoot $workspace -ScriptsRoot $ScriptsRoot
    Assert-Envelope ($public.exit_code -eq 0 -and $publicBefore -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) "fresh preparation failed public current-work validation or changed bytes:`n$($public.output)"
    Assert-Envelope ([string](Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')).last_accepted_receipt -ceq $originalAccepted -and -not (Test-Path -LiteralPath (Join-Path $workspace 'iteration-units/u004.json'))) 'fresh preparation replaced the original accepted checkpoint or pre-created its future unit'

    $admission = New-EnvelopeReplacementAdmission -Template (Read-EnvelopeProtocolJson (Join-Path $workspace 'receipts/u003-admission.json')) -Workspace $workspace -AdmissionId 'u004-admission' -UnitId 'u004'
    $admission.preparation = [ordered]@{
        preparation_kind='ordinary'; preparation_id='u004-envelope'; receipt_path='receipts/u004-envelope.json'
        receipt_sha256=(Get-EnvelopeFileSha256 (Join-Path $workspace 'receipts/u004-envelope.json'))
        source_composition_path='source-composition-locks/u004-envelope.json'
        source_composition_sha256=(Get-EnvelopeFileSha256 (Join-Path $workspace 'source-composition-locks/u004-envelope.json'))
    }
    $admission.unit.source_composition.lock_path = $admission.preparation.source_composition_path
    $admission.unit.prerequisites = @('u001')
    $admission.expected.project_sha256 = Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json'))
    $admission.expected.feature_lock_sha256 = Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json'))
    $admission.expected.source_composition_path = $admission.preparation.source_composition_path
    $admission.expected.source_composition_sha256 = $admission.preparation.source_composition_sha256
    $admissionPath = Join-Path $TestRoot 'original-checkpoint-admission.json'; Write-EnvelopeJson $admissionPath $admission
    $admissionArguments = @{Action='AdmitDevelopmentUnit'; WorkspaceRoot=$workspace; DevelopmentUnitAdmission=$admissionPath; OutPath=(Join-Path $workspace 'receipts/u004-admission.json'); Timestamp='2026-08-25T00:02:04.0000000Z'}

    foreach ($damage in @('missing-recovery','uncommitted-recovery','altered-recovery','altered-recovery-completion','detached-recovery','ambiguous-recovery','original-completion','intervening-event')) {
        $damagedWorkspace = Join-Path $TestRoot "fresh-admission-$damage"
        Copy-Item -LiteralPath $workspace -Destination $damagedWorkspace -Recurse
        $receiptPath = Join-Path $damagedWorkspace $RecoveryRelative
        $recoveryReceipt = Read-EnvelopeProtocolJson $receiptPath
        $recoveryCompletion = Join-Path $damagedWorkspace "receipts/transactions/$([string]$recoveryReceipt.recovery_id)-transition.completion.json"
        switch ($damage) {
            'missing-recovery' { Remove-Item -LiteralPath $receiptPath }
            'uncommitted-recovery' { Remove-Item -LiteralPath $recoveryCompletion }
            'altered-recovery' { [IO.File]::AppendAllText($receiptPath,' ') }
            'altered-recovery-completion' { $completion=Read-EnvelopeProtocolJson $recoveryCompletion; $completion.state_sha256='0'*64; Write-EnvelopeJson $recoveryCompletion $completion }
            'detached-recovery' { $recoveryReceipt.evidence.admission_intent.path='receipts/transactions/other-admitted-transition.intent.json'; Write-EnvelopeJson $receiptPath $recoveryReceipt }
            'original-completion' { [IO.File]::AppendAllText((Join-Path $damagedWorkspace 'receipts/transactions/u003-admission-admitted-transition.completion.json'),' ') }
            default {
                $damagedEventsPath=Join-Path $damagedWorkspace 'iteration-events.jsonl'
                $rows=@(Get-Content -LiteralPath $damagedEventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
                $correction=@($rows | Where-Object { [string]$_.event_id -ceq [string]$recoveryReceipt.recovery_id })[0]
                if($damage -ceq 'ambiguous-recovery') { $rows += ,$correction }
                else {
                    $insert=Copy-Envelope $correction; $insert.event_id='intervening-recovery-event'; $insert.receipts=@(); $insert.summary='Intervening fixture event.'
                    $rows=@(foreach($row in $rows){if([string]$row.event_id -ceq [string]$correction.event_id){$insert};$row})
                }
                [IO.File]::WriteAllText($damagedEventsPath,(($rows | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
            }
        }
        $damagedAdmission=Copy-Envelope $admission
        $damagedEventsPath=Join-Path $damagedWorkspace 'iteration-events.jsonl'
        $damagedAdmission.expected.events_sha256=Get-EnvelopeFileSha256 $damagedEventsPath
        $damagedAdmission.expected.events_length=([IO.FileInfo]$damagedEventsPath).Length
        $damagedAdmissionPath=Join-Path $TestRoot "fresh-admission-$damage.json"; Write-EnvelopeJson $damagedAdmissionPath $damagedAdmission
        $damagedArguments=$admissionArguments.Clone(); $damagedArguments.WorkspaceRoot=$damagedWorkspace
        $damagedArguments.DevelopmentUnitAdmission=$damagedAdmissionPath; $damagedArguments.OutPath=Join-Path $damagedWorkspace 'receipts/u004-admission.json'
        $damagedArguments.ExpectedDevelopmentUnitAdmissionSha256=Get-EnvelopeFileSha256 $damagedAdmissionPath
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace; $rejected=$false
        try { & $automation @damagedArguments -Execute | Out-Null } catch { $rejected=$true }
        Assert-Envelope ($rejected -and $before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace)) "fresh admission accepted or mutated $damage"
    }
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    $dry = & $automation @admissionArguments | ConvertFrom-Json
    Assert-Envelope ($before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) 'fresh admission dry run changed workspace bytes'
    $admitted = & $automation @admissionArguments -ExpectedDevelopmentUnitAdmissionSha256 $dry.audit_receipt.sha256 -Execute | ConvertFrom-Json
    $lifecycle=@{WorkspaceRoot=$workspace;UnitId='u004';RepoMapPath=(Join-Path $workspace 'repository-map.json');ValidationTier='quick'}
    $ready=& $automation @lifecycle -Action Ready -Timestamp '2026-08-25T00:02:05.0000000Z' -Execute | ConvertFrom-Json
    $inspect=& $automation @lifecycle -Action Inspect -Timestamp '2026-08-25T00:02:06.0000000Z' | ConvertFrom-Json
    $claim=& $automation @lifecycle -Action Claim -Timestamp '2026-08-25T00:02:07.0000000Z' -Execute | ConvertFrom-Json
    Assert-Envelope ($admitted.transition -ceq 'development-unit-admitted' -and $ready.transition -ceq 'proposed-to-ready' -and $inspect.claim_preflight.ready_to_claim -and $claim.transition -ceq 'ready-to-active') 'original-checkpoint recovered retirement did not continue through fresh Admit, Ready, Inspect and Claim'
    foreach($file in $preserved){Assert-Envelope ((Get-EnvelopeFileSha256 (Join-Path $workspace $file.path)) -ceq $file.sha256) 'fresh continuation rewrote accepted, malformed, recovered or retired historical bytes'}
    Assert-Envelope ([string](Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')).last_accepted_receipt -ceq $originalAccepted) 'fresh continuation advanced its accepted checkpoint'
}

function Test-RepreparationEventClassification {
    param([string]$Workspace,[string]$TestRoot,[string]$ScriptsRoot,[string]$UnitId,[string]$ReplacementUnitId)
    Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceCurrentWorkHistory.psm1')
    $recovery=Read-EnvelopeProtocolJson (Join-Path $Workspace 'receipts/u003-envelope-recovery-repreparation.json')
    $intentPath=Join-Path $Workspace $recovery.original_preparation.intent.path
    $intent=Read-EnvelopeProtocolJson $intentPath
    $events=@(Get-Content -LiteralPath (Join-Path $Workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    $originalEvent=@($events|Where-Object event_id -CEQ $recovery.original_preparation.event_id)[0]
    $evidenceArguments=@{Workspace=$Workspace;IntentPath=$intentPath;Intent=$intent;Events=$events;ExpectedEvent=$originalEvent}
    # Unrelated later events may own JSON, plain text, or another receipt shape.
    # Candidate selection must not parse or schema-test those artifacts.
    $textReceipt=Join-Path $Workspace 'receipts/unrelated-observation.txt'
    [IO.File]::WriteAllText($textReceipt,"Non-JSON observation.`n",[Text.UTF8Encoding]::new($false))
    foreach($kind in @('state-transition','decision')){
        foreach($first in @("receipts/$UnitId-admission.json",'receipts/unrelated-observation.txt')){
            $unrelated=Copy-Envelope $events[-1];$unrelated.sequence=[int]$events[-1].sequence+1
            $unrelated.event_type=$kind;$unrelated.event_id='unrelated-prepared'
            $unrelated.receipts=@($first,'receipts/unrelated.json')
            $arguments=$evidenceArguments.Clone();$arguments.Events=@($events)+@($unrelated)
            $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace
            $null=Get-MorphospacePreparationStepEvidence @arguments
            Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)) 'unrelated two-receipt classification changed workspace bytes'
        }
    }
    Remove-Item -LiteralPath $textReceipt
    # A real owner-shaped candidate remains strict, including schema damage
    # and duplicate candidates for the exact original preparation.
    $recoveryPath=Join-Path $Workspace 'receipts/u003-envelope-recovery-repreparation.json'
    $recoveryBytes=[IO.File]::ReadAllBytes($recoveryPath)
    foreach($damage in @('schema','binding','ambiguous')){
        $arguments=$evidenceArguments.Clone()
        try{
            if($damage-ceq'ambiguous'){
                $candidate=@($events|Where-Object{@($_.receipts).Count-gt0-and[string]$_.receipts[0]-ceq'receipts/u003-envelope-recovery-repreparation.json'})[0]
                $arguments.Events=@($events)+@($candidate)
            }else{
                $damaged=Copy-Envelope $recovery
                if($damage-ceq'schema'){$damaged.schema='unrelated.receipt.v1'}else{$damaged.original_preparation.intent.sha256='0'*64}
                Write-EnvelopeJson $recoveryPath $damaged
            }
            $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace;$rejected=$false
            try{$null=Get-MorphospacePreparationStepEvidence @arguments}catch{$rejected=$true}
            Assert-Envelope ($rejected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)) "preparation recovery accepted or mutated $damage"
        }finally{[IO.File]::WriteAllBytes($recoveryPath,$recoveryBytes)}
    }
    . (Join-Path $PSScriptRoot 'ActiveUnitRetirementFixture.ps1')
    $request=New-ActiveUnitRetirementRequest -WorkspaceRoot $Workspace -RetirementId "retire-$UnitId" -ReplacementUnitId $ReplacementUnitId
    $requestPath=Join-Path $TestRoot "retire-$UnitId-request.json";Write-EnvelopeJson $requestPath $request
    $unitHash=Get-EnvelopeFileSha256 (Join-Path $Workspace "iteration-units/$UnitId.json")
    $automation=Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1'
    $retired=& $automation -Action RetireActive -WorkspaceRoot $Workspace -UnitId $UnitId -RepoMapPath (Join-Path $Workspace 'repository-map.json') -ActiveUnitRetirement $requestPath -ExpectedActiveUnitRetirementSha256 (Get-EnvelopeFileSha256 $requestPath) -OutPath (Join-Path $Workspace "receipts/retire-$UnitId.json") -Timestamp '2026-08-25T00:02:08.0000000Z' -Execute|ConvertFrom-Json
    Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceCurrentWorkHistory.psm1')
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace
    $history=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $Workspace -RequireIdle
    Assert-Envelope ($retired.executed-and$history.authenticated-and$history.retired_active_ids.Contains($UnitId)-and$unitHash-ceq(Get-EnvelopeFileSha256 (Join-Path $Workspace "iteration-units/$UnitId.json"))-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)) 'real active retirement after recovered preparation did not preserve readable idle history'
    $public=Invoke-RecoveredContinuationPublicValidation -WorkspaceRoot $Workspace -ScriptsRoot $ScriptsRoot
    Assert-Envelope ($public.exit_code-eq0-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)) "retired recovered-preparation history failed public validation or changed bytes: $($public.output)"
}

function Test-RecoveredProposalRetirement {
    param([string]$AdmittedWorkspace, [string]$TestRoot, [string]$ScriptsRoot,[ValidateSet('All','PreparedAdmission','LaterAcceptance')][string]$Scenario='All')
    Import-Module (Join-Path $PSScriptRoot '../AdmissionCompletionTimestampRecovery.psm1')
    Import-Module (Join-Path $PSScriptRoot '../ProposedUnitRetirement.psm1')
    $workspace = Join-Path $TestRoot 'recovered-proposal-retirement'
    Copy-Item -LiteralPath $AdmittedWorkspace -Destination $workspace -Recurse
    $requestPath = Join-Path $workspace 'local/u003-admission.json'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($requestPath))
    Copy-Item -LiteralPath (Join-Path $workspace 'receipts/u003-admission.json') -Destination $requestPath
    $intentPath = Join-Path $workspace 'receipts/transactions/u003-admission-admitted-transition.intent.json'
    $completionPath = Join-Path $workspace 'receipts/transactions/u003-admission-admitted-transition.completion.json'
    $intent = Read-EnvelopeProtocolJson $intentPath
    $completion = Read-EnvelopeProtocolJson $completionPath
    # Reproduce the historical writer's single known chronology fault. All
    # other bytes below come from the existing real owner writers.
    $completion.completed_at = ([DateTimeOffset]::Parse([string]$intent.created_at)).AddSeconds(-1).UtcDateTime.ToString('o')
    Write-EnvelopeJson $completionPath $completion
    $recovery = New-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $workspace -Timestamp '2026-08-25T00:02:01.0000000Z'
    $recoveryInput = Join-Path $workspace 'local/recovery-input.json'
    Write-EnvelopeJson $recoveryInput $recovery
    $recoveryOut = Join-Path $workspace ([string]$recovery.correction_event.receipt_path)
    $null = Invoke-MorphospaceAdmissionCompletionTimestampRecovery -WorkspaceRoot $workspace -Recovery $recoveryInput -ExpectedRecoverySha256 (Get-EnvelopeFileSha256 $recoveryInput) -OutPath $recoveryOut -Execute
    $preserved = @($intentPath,$completionPath,$requestPath,$recoveryOut | ForEach-Object { [pscustomobject]@{path=$_;sha256=(Get-EnvelopeFileSha256 $_)} })
    $arguments = @{
        WorkspaceRoot=$workspace; UnitId='u003'; ReplacementUnitId='u004'
        RetirementReason='contract-invalid'; OutPath=(Join-Path $workspace 'receipts/u003-recovered-retirement.json')
        Timestamp='2026-08-25T00:02:02.0000000Z'
    }
    $before = Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    $dry = Invoke-MorphospaceProposedUnitRetirement @arguments
    Assert-Envelope ($before -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) 'recovered proposal retirement dry run mutated bytes'
    Assert-Envelope ([string]$dry.proposed_retirement.authenticated_admission.transaction.target_state_sha256 -cne [string]$dry.proposed_retirement.authenticated_preimage.state_sha256) 'recovered retirement lost the distinct original and recovered state bindings'
    if ($Scenario -ne 'PreparedAdmission') {
    foreach ($damage in @('recovery-receipt','original-completion','intervening-event')) {
        $damagedWorkspace = Join-Path $TestRoot "recovered-retirement-$damage"
        Copy-Item -LiteralPath $workspace -Destination $damagedWorkspace -Recurse
        switch ($damage) {
            'recovery-receipt' { [IO.File]::AppendAllText((Join-Path $damagedWorkspace ([string]$recovery.correction_event.receipt_path)), ' ') }
            'original-completion' { [IO.File]::AppendAllText((Join-Path $damagedWorkspace 'receipts/transactions/u003-admission-admitted-transition.completion.json'), ' ') }
            'intervening-event' {
                $statePath = Join-Path $damagedWorkspace 'workspace.state.json'
                $state = Read-EnvelopeProtocolJson $statePath
                $event = Read-EnvelopeProtocolJson $recoveryInput
                $row = [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='unrelated-event';sequence=([int]$event.correction_event.sequence+1);timestamp='2026-08-25T00:02:01.5000000Z';project_id=$state.project_id;unit_id='u003';event_type='state-transition';summary='Unrelated event.';receipts=@()}
                [IO.File]::AppendAllText((Join-Path $damagedWorkspace 'iteration-events.jsonl'), (($row | ConvertTo-Json -Compress)+"`n"))
                $state.last_event_id = 'unrelated-event'; Write-EnvelopeJson $statePath $state
            }
        }
        $damagedArguments = $arguments.Clone(); $damagedArguments.WorkspaceRoot = $damagedWorkspace
        $damagedArguments.OutPath = Join-Path $damagedWorkspace 'receipts/u003-recovered-retirement.json'
        $damageBefore = Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace
        $rejected = $false
        try { Invoke-MorphospaceProposedUnitRetirement @damagedArguments | Out-Null } catch { $rejected = $true }
        Assert-Envelope ($rejected -and $damageBefore -ceq (Get-EnvelopeWorkspaceByteInventorySha256 $damagedWorkspace)) "recovered retirement accepted or mutated $damage"
    }
    }
    $pre = $dry.proposed_retirement.authenticated_preimage
    $arguments.ExpectedStateSha256=$pre.state_sha256; $arguments.ExpectedUnitSha256=$pre.unit_sha256
    $arguments.ExpectedUnitRawSha256=$pre.unit_raw_sha256; $arguments.ExpectedEventsSha256=$pre.events_sha256
    $arguments.ExpectedEventsLength=[long]$pre.events_length; $arguments.ExpectedEventTailId=$pre.event_tail_id
    $arguments.ExpectedProposedRetirementBindingSha256=$dry.proposed_retirement.binding_sha256; $arguments.Execute=$true
    $run = Invoke-MorphospaceProposedUnitRetirement @arguments
    Assert-Envelope ($run.transition -ceq 'proposed-to-superseded-retired' -and [string](Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u003.json')).status -ceq 'superseded') 'recovered proposal did not retire through the ordinary owner writer'
    foreach ($file in $preserved) { Assert-Envelope ((Get-EnvelopeFileSha256 $file.path) -ceq $file.sha256) 'retirement rewrote preserved admission or recovery evidence' }
    if ($Scenario -eq 'PreparedAdmission') {
        Test-RecoveredPreparedAdmission -RetiredWorkspace $workspace -TestRoot $TestRoot -ScriptsRoot $ScriptsRoot -RecoveryRelative ([string]$recovery.correction_event.receipt_path)
        return
    }
    $retiredPublicBefore=Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    $retiredPublic = Invoke-RecoveredContinuationPublicValidation -WorkspaceRoot $workspace -ScriptsRoot $ScriptsRoot
    Assert-Envelope ($retiredPublic.exit_code-eq0-and$retiredPublicBefore-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) "public current-work validation rejected or mutated the recovered retirement before a later accepted boundary:`n$($retiredPublic.output)"
    $publicDamageWorkspace=Join-Path $TestRoot 'retired-public-completion-damage';Copy-Item -LiteralPath $workspace -Destination $publicDamageWorkspace -Recurse
    [IO.File]::AppendAllText((Join-Path $publicDamageWorkspace 'receipts/transactions/u003-admission-admitted-transition.completion.json'), ' ')
    $publicDamageBefore=Get-EnvelopeWorkspaceByteInventorySha256 $publicDamageWorkspace
    $publicDamage=Invoke-RecoveredContinuationPublicValidation -WorkspaceRoot $publicDamageWorkspace -ScriptsRoot $ScriptsRoot
    Assert-Envelope ($publicDamage.exit_code-ne0-and$publicDamage.output-clike'*Admission recovery malformed completion bytes differ from their recovery binding.*'-and$publicDamageBefore-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $publicDamageWorkspace)) "public current-work validation did not reject a damaged retained completion at its exact evidence-hash predicate or mutated the workspace:`n$($publicDamage.output)"
    if ($Scenario -eq 'All') {
        Test-RecoveredPreparedAdmission -RetiredWorkspace $workspace -TestRoot $TestRoot -ScriptsRoot $ScriptsRoot -RecoveryRelative ([string]$recovery.correction_event.receipt_path)
    }
    $transitionModule=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceTransitionLedger.psm1') -PassThru
    function Add-ContinuationAcceptedBoundary([string]$Root){$acceptedUnit=Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $Root 'iteration-units/u001.json'));$acceptedUnit.unit_id='u004';$acceptedUnit.status='proposed';$acceptedUnit.prerequisites=@('u001');$acceptedUnit.objective='Establish a later owner-written accepted boundary for continuation testing.';Write-EnvelopeCanonicalJson (Join-Path $Root 'iteration-units/u004.json') $acceptedUnit;$acceptedSequence=@(Get-Content -LiteralPath (Join-Path $Root 'iteration-events.jsonl')|Where-Object{$_}).Count+1;$acceptedEventId=('u004-accepted-{0:d4}'-f$acceptedSequence);$acceptedReceiptRelative='receipts/u004-accepted.json';Write-EnvelopeJson (Join-Path $Root $acceptedReceiptRelative) ([ordered]@{schema='fixture.owner.validation.v1';result='pass'});$acceptedState=Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $Root 'workspace.state.json'));$acceptedState.last_accepted_receipt=$acceptedReceiptRelative;$acceptedState.last_event_id=$acceptedEventId;$acceptedUnit.status='accepted';$acceptedEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$acceptedEventId;sequence=$acceptedSequence;timestamp='2026-08-25T00:02:02.5000000Z';project_id=[string]$acceptedState.project_id;unit_id='u004';event_type='state-transition';summary='Accepted later continuation checkpoint.';receipts=@($acceptedReceiptRelative)};&$transitionModule {param($root,$targetState,$targetUnit,$event,$transaction)Start-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId $transaction -StatePath 'workspace.state.json' -UnitPath 'iteration-units/u004.json' -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event} $Root $acceptedState $acceptedUnit $acceptedEvent "$acceptedEventId-transition"|Out-Null}
    $resurrectionWorkspace=Join-Path $TestRoot 'retired-proposal-resurrection-before-boundary';Copy-Item -LiteralPath $workspace -Destination $resurrectionWorkspace -Recurse;$resurrectionUnit=Read-EnvelopeProtocolJson (Join-Path $resurrectionWorkspace 'iteration-units/u003.json');$resurrectionState=Copy-Envelope (Read-EnvelopeProtocolJson (Join-Path $resurrectionWorkspace 'workspace.state.json'));$resurrectionSequence=@(Get-Content -LiteralPath (Join-Path $resurrectionWorkspace 'iteration-events.jsonl')|Where-Object{$_}).Count+1;$resurrectionEventId=('u003-ready-{0:d4}'-f$resurrectionSequence);$resurrectionState.last_event_id=$resurrectionEventId;$resurrectionEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$resurrectionEventId;sequence=$resurrectionSequence;timestamp='2026-08-25T00:02:02.2500000Z';project_id=[string]$resurrectionState.project_id;unit_id='u003';event_type='state-transition';summary='Damaged resurrection row retained before a later accepted boundary.';receipts=@()};&$transitionModule {param($root,$targetState,$targetUnit,$event,$transaction)Start-MorphospaceTransitionLedger -WorkspaceRoot $root -TransactionId $transaction -StatePath 'workspace.state.json' -UnitPath 'iteration-units/u003.json' -EventsPath 'iteration-events.jsonl' -TargetState $targetState -TargetUnit $targetUnit -Event $event} $resurrectionWorkspace $resurrectionState $resurrectionUnit $resurrectionEvent "$resurrectionEventId-transition"|Out-Null;Add-ContinuationAcceptedBoundary $resurrectionWorkspace
    Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceCurrentWorkHistory.psm1') -Force;$resurrectionMessage='';try{Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $resurrectionWorkspace|Out-Null}catch{$resurrectionMessage=$_.Exception.Message};Assert-Envelope ($resurrectionMessage-ceq'Current-work proposed retirement cannot hide a resurrected owner.') "current-work reader did not reject a retired proposal resurrected inside a later accepted prefix at the intended predicate (observed: '$resurrectionMessage')"
    Add-ContinuationAcceptedBoundary $workspace
    $repositoryMap=Read-EnvelopeProtocolJson (Join-Path $workspace 'repository-map.json');$planningRows=@($repositoryMap.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'});Assert-Envelope ($planningRows.Count-eq1) 'continuation fixture lacks one mapped planning repository';$repositoryRoot=(Resolve-Path -LiteralPath ([string]$planningRows[0].path)).Path;$repositoryWorkspace=Join-Path $repositoryRoot 'morphospace';$testRootFull=[IO.Path]::GetFullPath($TestRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;Assert-Envelope (([IO.Path]::GetFullPath($repositoryRoot)+[IO.Path]::DirectorySeparatorChar).StartsWith($testRootFull,[StringComparison]::OrdinalIgnoreCase)) 'continuation fixture mapped a planning repository outside its exact test root';Assert-Envelope ((Test-Path -LiteralPath (Join-Path $repositoryRoot '.git'))-and(Test-Path -LiteralPath $repositoryWorkspace)) 'continuation fixture planning repository is not a Git worktree containing morphospace'
    Invoke-EnvelopeGit $repositoryRoot @('config','core.longpaths','true')|Out-Null;Get-ChildItem -LiteralPath $workspace -Force|Copy-Item -Destination $repositoryWorkspace -Recurse -Force;Invoke-EnvelopeGit $repositoryRoot @('add','morphospace')|Out-Null;Invoke-EnvelopeGit $repositoryRoot @('commit','-m','fixture recovered retirement checkpoint')|Out-Null
    Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceCurrentWorkHistory.psm1') -Force
    $retiredHistory=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $workspace
    Assert-Envelope ($retiredHistory.historically_retired_proposed_ids.Contains('u003')) 'current-work reader did not authenticate the recovered proposed retirement as audit-only history'

    # Continue through the ordinary owner preparation writer. The new envelope
    # expands one existing repository only by roots explicitly named by its
    # owner row, while the retired proposal remains audit-only history.
    Import-Module (Join-Path $PSScriptRoot '../DevelopmentEnvelopePreparation.psm1') -Force
    $project=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json');$state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$lock=Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json');$map=Read-EnvelopeProtocolJson (Join-Path $workspace 'repository-map.json');$predecessor=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u004.json')
    $targetProject=Copy-Envelope $project;$targetProject.revision=[int]$project.revision+1;$projectShell=@($targetProject.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0];$projectShell.allowed_paths=@($projectShell.allowed_paths)+@('model/','peer/','runtime-host/')
    $targetLock=Copy-Envelope $lock;$targetLock.revision=[int]$lock.revision+1;$targetLock.project_revision=[int]$targetProject.revision;$targetLock.generated_at='2026-08-25T00:02:03.0000000Z';$targetLock.lock_fingerprint=Get-EnvelopeLockFingerprint $targetLock
    $latestPreparation=Read-EnvelopeProtocolJson (Join-Path $workspace 'receipts/u003-envelope.json');$envelope=Copy-Envelope $latestPreparation.envelope;$envelope.project=$targetProject;$envelope.feature_lock=$targetLock;$envelope.PSObject.Properties.Remove('schema_pin_revision');$envelope.source_composition.path='source-composition-locks/u005-envelope.json';$envelope.owner_repositories=@($targetProject.repositories|ForEach-Object{[pscustomobject][ordered]@{repo_id=[string]$_.repo_id;source_roots=@($_.allowed_paths)}})
    $eventsPath=Join-Path $workspace 'iteration-events.jsonl';$tail=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})[-1]
    $preparation=[ordered]@{schema='rusty.morphospace.workflow.development_envelope_preparation.v1';preparation_id='u005-envelope';project_id=[string]$project.project_id;predecessor_unit_id='u004';envelope=$envelope;expected=[ordered]@{project_sha256=(Get-EnvelopeCanonicalJsonSha256 $project);state_sha256=(Get-EnvelopeCanonicalJsonSha256 $state);feature_lock_sha256=(Get-EnvelopeCanonicalJsonSha256 $lock);repository_map_path='repository-map.json';repository_map_sha256=(Get-EnvelopeFileSha256 (Join-Path $workspace 'repository-map.json'));predecessor_unit_path='iteration-units/u004.json';predecessor_unit_sha256=(Get-EnvelopeCanonicalJsonSha256 $predecessor);events_sha256=(Get-EnvelopeFileSha256 $eventsPath);events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$tail.event_id};does_not_prove=@('Does not admit a future unit or execute a device action.')}
    $preparationPath=Join-Path $TestRoot 'u005-envelope.json';Write-EnvelopeJson $preparationPath $preparation;$preparationOut=Join-Path $workspace 'receipts/u005-envelope.json';$preparationHash=Get-EnvelopeFileSha256 $preparationPath
    $prepared=Invoke-MorphospacePrepareDevelopmentEnvelope -WorkspaceRoot $workspace -DevelopmentEnvelopePreparation $preparationPath -ExpectedDevelopmentEnvelopePreparationSha256 $preparationHash -OutPath $preparationOut -Timestamp '2026-08-25T00:02:03.0000000Z' -Execute
    Assert-Envelope ($prepared.executed-and@((Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json')).repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'}|ForEach-Object{$_.allowed_paths}|Where-Object{$_-in@('model/','peer/','runtime-host/')}).Count-eq3) 'ordinary preparation did not add the exact owner-declared repository roots'
    $continuedHistory=Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $workspace
    Assert-Envelope ($continuedHistory.historically_retired_proposed_ids.Contains('u003')-and[string](Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')).last_event_id-ceq'u005-envelope-prepared') 'current-work reader did not authenticate ordinary preparation after recovered retirement'
    $preparedPublicBefore=Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    $preparedPublic = Invoke-RecoveredContinuationPublicValidation -WorkspaceRoot $workspace -ScriptsRoot $ScriptsRoot
    Assert-Envelope ($preparedPublic.exit_code-eq0-and$preparedPublicBefore-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) "public current-work validation rejected or mutated ordinary preparation after recovered retirement:`n$($preparedPublic.output)"

    $damageWorkspace=Join-Path $TestRoot 'prepared-root-rewrite-damage';Copy-Item -LiteralPath $workspace -Destination $damageWorkspace -Recurse
    $damageReceiptPath=Join-Path $damageWorkspace 'receipts/u005-envelope.json';$damageReceipt=Read-EnvelopeProtocolJson $damageReceiptPath;$damageRepo=@($damageReceipt.envelope.project.repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0];$damageRepo.allowed_paths=@($damageRepo.allowed_paths|Where-Object{$_-cne'morphospace/'})+@('rewritten/');$damageOwner=@($damageReceipt.envelope.owner_repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0];$damageOwner.source_roots=@($damageRepo.allowed_paths);$damageReceipt.project_sha256=Get-EnvelopeCanonicalJsonSha256 $damageReceipt.envelope.project
    $damageReceiptBytes=[Text.UTF8Encoding]::new($false).GetBytes(($damageReceipt|ConvertTo-Json -Depth 64));[IO.File]::WriteAllBytes($damageReceiptPath,$damageReceiptBytes)
    $damageIntentPath=Join-Path $damageWorkspace 'receipts/transactions/u005-envelope-prepared-transition.intent.json';$damageIntent=Read-EnvelopeProtocolJson $damageIntentPath;$damageIntent.target.project.document=$damageReceipt.envelope.project;$damageIntent.target.project.sha256=$damageReceipt.project_sha256;$damageIntent.artifacts[0].sha256=Get-EnvelopeCanonicalJsonSha256 $damageReceipt;$damageIntent.artifacts[0].bytes_base64=[Convert]::ToBase64String($damageReceiptBytes);Write-EnvelopeCanonicalJson $damageIntentPath $damageIntent
    Write-EnvelopeCanonicalJson (Join-Path $damageWorkspace 'project.spec.json') $damageReceipt.envelope.project;$damageCompletionPath=Join-Path $damageWorkspace 'receipts/transactions/u005-envelope-prepared-transition.completion.json';$damageCompletion=Read-EnvelopeProtocolJson $damageCompletionPath;$damageCompletion.intent_sha256=Get-EnvelopeFileSha256 $damageIntentPath;$damageCompletion.target_project_sha256=$damageReceipt.project_sha256;Write-EnvelopeCanonicalJson $damageCompletionPath $damageCompletion
    $damageRejected=$false;$damageMessage='';try{Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $damageWorkspace|Out-Null}catch{$damageRejected=$true;$damageMessage=$_.Exception.Message};Assert-Envelope ($damageRejected-and$damageMessage-ceq"Preparation removes an existing allowed path from repository 'project-shell'.") 'current-work reader did not reject the otherwise coherent preparation at the existing-root rewrite predicate'

    $ownerDamageWorkspace=Join-Path $TestRoot 'prepared-owner-root-authority-damage';Copy-Item -LiteralPath $workspace -Destination $ownerDamageWorkspace -Recurse
    $ownerDamageReceiptPath=Join-Path $ownerDamageWorkspace 'receipts/u005-envelope.json';$ownerDamageReceipt=Read-EnvelopeProtocolJson $ownerDamageReceiptPath;$ownerDamageRow=@($ownerDamageReceipt.envelope.owner_repositories|Where-Object{[string]$_.repo_id-ceq'project-shell'})[0];$ownerDamageRow.source_roots=@($ownerDamageRow.source_roots)+@('outside/');$ownerDamageReceiptBytes=[Text.UTF8Encoding]::new($false).GetBytes(($ownerDamageReceipt|ConvertTo-Json -Depth 64));[IO.File]::WriteAllBytes($ownerDamageReceiptPath,$ownerDamageReceiptBytes)
    $ownerDamageIntentPath=Join-Path $ownerDamageWorkspace 'receipts/transactions/u005-envelope-prepared-transition.intent.json';$ownerDamageIntent=Read-EnvelopeProtocolJson $ownerDamageIntentPath;$ownerDamageIntent.artifacts[0].sha256=Get-EnvelopeCanonicalJsonSha256 $ownerDamageReceipt;$ownerDamageIntent.artifacts[0].bytes_base64=[Convert]::ToBase64String($ownerDamageReceiptBytes);Write-EnvelopeCanonicalJson $ownerDamageIntentPath $ownerDamageIntent;$ownerDamageCompletionPath=Join-Path $ownerDamageWorkspace 'receipts/transactions/u005-envelope-prepared-transition.completion.json';$ownerDamageCompletion=Read-EnvelopeProtocolJson $ownerDamageCompletionPath;$ownerDamageCompletion.intent_sha256=Get-EnvelopeFileSha256 $ownerDamageIntentPath;Write-EnvelopeCanonicalJson $ownerDamageCompletionPath $ownerDamageCompletion
    $ownerDamageMessage='';try{Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $ownerDamageWorkspace|Out-Null}catch{$ownerDamageMessage=$_.Exception.Message};Assert-Envelope ($ownerDamageMessage-ceq"Preparation root 'project-shell/outside/' exceeds project authority.") 'current-work reader did not reject the otherwise coherent preparation at the owner-root authority predicate'
    $replayed = $false
    try { Invoke-MorphospaceProposedUnitRetirement @arguments | Out-Null } catch { $replayed = $true }
    Assert-Envelope $replayed 'recovered proposal retirement replay was accepted'
}
