# Real native initial-owner fixture; no synthetic preparation/admission/history.
function New-NativeBootstrapEnvelopeFixture {
    param([string]$Root)
    if(Test-Path -LiteralPath $Root){throw 'Bootstrap fixture root must be fresh.'}
    [void][IO.Directory]::CreateDirectory($Root)
    $source=Join-Path $Root 'source';$skills=Join-Path $Root 'skill-surfaces'
    $paths=@('docs/one.md','docs/two.md','docs/three.md','docs/four.md','docs/five.md')
    $skillPaths=@('rusty-morphospace/SKILL.md','system-engineering/SKILL.md','rust-work-graph/SKILL.md')
    foreach($entry in @(@{root=$source;paths=$paths},@{root=$skills;paths=$skillPaths})){
        [void][IO.Directory]::CreateDirectory($entry.root)
        Invoke-EnvelopeGit $entry.root @('init','--quiet')|Out-Null
        Invoke-EnvelopeGit $entry.root @('config','user.name','Bootstrap fixture')|Out-Null
        Invoke-EnvelopeGit $entry.root @('config','user.email','bootstrap@example.invalid')|Out-Null
        Invoke-EnvelopeGit $entry.root @('config','commit.gpgsign','false')|Out-Null
        foreach($path in $entry.paths){$absolute=Join-Path $entry.root $path;[void][IO.Directory]::CreateDirectory((Split-Path $absolute -Parent));[IO.File]::WriteAllText($absolute,"# Native fixture input`n",[Text.UTF8Encoding]::new($false))}
        Invoke-EnvelopeGit $entry.root @('add','.')|Out-Null;Invoke-EnvelopeGit $entry.root @('commit','--quiet','-m','native-bootstrap-inputs')|Out-Null
    }
    $owner=Join-Path $Root 'owner'
    & (Join-Path $PSScriptRoot '../New-ProjectWorkspace.ps1') -ProjectRoot $owner -ProjectId 'envelope-test' -Purpose 'Exercise a native initial-owner exact additive documentation dependency.' -Execute|Out-Null
    $workspace=Join-Path $owner 'morphospace'
    $project=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json')
    $project.repositories=@([pscustomobject]@{repo_id='project-shell';role='application';path=$source;allowed_paths=$paths},[pscustomobject]@{repo_id='skill-surfaces';role='tool';path=$skills;allowed_paths=$skillPaths})
    $project.validation_profiles=@([pscustomobject]@{profile_id='workflow';commands=@('test')})
    Write-EnvelopeCanonicalJson (Join-Path $workspace 'project.spec.json') $project
    $map=[pscustomobject]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([pscustomobject]@{repo_id='project-shell';role='source';path=$source},[pscustomobject]@{repo_id='skill-surfaces';role='source';path=$skills})}
    $mapPath=Join-Path $workspace 'repository-map.json';Write-EnvelopeCanonicalJson $mapPath $map
    $unit=Read-EnvelopeProtocolJson (Join-Path $repoRoot 'examples/hello-morphospace-v2/morphospace/iteration-units/hello-001.json')
    $unit.project_id='envelope-test';$unit.unit_id='u001';$unit.objective='Complete the same bounded documentation objective after discovering one exact extra path.';$unit.allowed_repositories=@([pscustomobject]@{repo_id='project-shell';allowed_paths=$paths});$unit.prerequisites=@();$unit.validation=@([pscustomobject]@{profile_id='workflow';command='test'});$unit.acceptance=@([pscustomobject]@{acceptance_id='bounded';proof='The native owner retains exact source and scope.';command='test'})
    $unit.instruction_impact='none';$unit.instruction_surfaces=@();$unit.instruction_none_justification='The fixture edits no instruction decision or portable guidance.'
    $unit|Add-Member -Force work_mode 'feature';$unit|Add-Member -Force guard_profile 'fast'
    $unit|Add-Member -Force architecture_decision ([pscustomobject]@{selected='Retain native bootstrap authority and exact sources.';material_advance='Prove additive path ownership.';deferred='Runtime and external effects.';deferred_reason='Host-only conformance.'})
    $unit|Add-Member -Force claim_requirements ([pscustomobject]@{minimum_free_disk_mib=1;required_tools=@();product_inputs=@()})
    $unit|Add-Member -Force read_only_dependencies @([pscustomobject]@{repo_id='skill-surfaces';paths=$skillPaths;purpose='Independent retained read-only skill input.';verification='Exact original native source lock identity.'})
    $unit|Add-Member -Force source_composition ([pscustomobject]@{mode='exact-lock';lock_path='source-compositions/u001.lock.json';materialization_receipt=$null})
    $unit|Add-Member -Force agent_scope_assessment ([pscustomobject]@{schema='rusty.morphospace.workflow.agent_scope_assessment.v1';objective=$unit.objective;owner_repositories=@([pscustomobject]@{repo_id='project-shell';source_roots=$paths});public_private_boundary='mixed';allowed_change_categories=@('documentation-only');allowed_effect_categories=@('none');allowed_permission_categories=@('none');build_envelope=[pscustomobject]@{class='none';allowed_profiles=@('workflow')};device_envelope=[pscustomobject]@{requirement='none';allowed_kinds=@()};non_scope=@('Runtime and external effects.');prerequisites=@();validation_class='quick';evidence_expectations=@('Real native owner transactions.');cleanup_expectations=@('Retain fixture evidence.')})
    $unitPath=Join-Path $workspace 'iteration-units/u001.json';Write-EnvelopeCanonicalJson $unitPath $unit
    & (Join-Path $PSScriptRoot '../New-SourceCompositionLock.ps1') -WorkspaceRoot $workspace -UnitId u001 -RepositoryMapPath $mapPath -OutRelativePath 'source-compositions/u001.lock.json' -Execute|Out-Null
    $lifecycle=@{WorkspaceRoot=$workspace;UnitId='u001';RepoMapPath=$mapPath;ValidationTier='quick'}
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Ready -Execute} $lifecycle|Out-Null
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action WithdrawReady -OutPath (Join-Path $a.WorkspaceRoot 'receipts/withdrawn.json') -Execute} $lifecycle|Out-Null
    $unit.unit_id='u002';$unit.source_composition.lock_path='source-compositions/u002.lock.json';Write-EnvelopeCanonicalJson (Join-Path $workspace 'iteration-units/u002.json') $unit
    & (Join-Path $PSScriptRoot '../New-SourceCompositionLock.ps1') -WorkspaceRoot $workspace -UnitId u002 -RepositoryMapPath $mapPath -OutRelativePath 'source-compositions/u002.lock.json' -Execute|Out-Null
    $lifecycle.UnitId='u002'
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Ready -Execute} $lifecycle|Out-Null
    &$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Claim -Execute} $lifecycle|Out-Null
    [pscustomobject]@{workspace=$workspace;map=$mapPath;source=$source;skills=$skills;lifecycle=$lifecycle}
}

function Test-NativeBootstrapEnvelopeExtension {
    param([string]$Root)
    $fixture=New-NativeBootstrapEnvelopeFixture $Root
    $workspace=$fixture.workspace
    $unit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json')
    Assert-ActiveEnvelopeTest (@($unit.agent_scope_assessment.owner_repositories).Count-eq1-and@($unit.read_only_dependencies).Count-eq1) 'bootstrap fixture must preserve writable-only assessment plus independent retained readonly input'
    $initialLockPath=Join-Path $workspace 'feature.lock.json';$initialLockHash=Get-EnvelopeFileSha256 $initialLockPath;$initialLock=Read-EnvelopeProtocolJson $initialLockPath
    $request=New-ActiveEnvelopeExtensionRequest -Workspace $workspace -RequestPath (Join-Path $Root 'root-extension.json') -AddedOwnerRoot 'docs/six.md'
    # Preserve the genuine scaffold lock, including its legacy fingerprint.
    # Canonical request transport loses producer property order without changing
    # the authenticated before-lock values, just like the retained real caller.
    Write-EnvelopeCanonicalJson $request.request_path $request.request
    $capturedRequest=Read-EnvelopeProtocolJson $request.request_path
    Assert-ActiveEnvelopeTest ((Get-EnvelopeFileSha256 $initialLockPath)-ceq$initialLockHash-and[string]$capturedRequest.before.feature_lock.lock_fingerprint-ceq[string]$initialLock.lock_fingerprint-and(Get-EnvelopeCanonicalJsonSha256 $capturedRequest.before.feature_lock)-ceq(Get-EnvelopeCanonicalJsonSha256 $initialLock)) 'canonical bootstrap request preserves the original native legacy lock and fingerprint'
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    $recoveryWorkspace=Join-Path $Root 'recovery-workspace';Copy-Item -LiteralPath $workspace -Destination $recoveryWorkspace -Recurse
    $pendingWorkspace=Join-Path $Root 'after-intent-workspace';Copy-Item -LiteralPath $workspace -Destination $pendingWorkspace -Recurse
    $arguments=@{WorkspaceRoot=$workspace;UnitId='u002';ActiveDevelopmentEnvelopeExtension=$request.request_path;RepositoryMapPath=$request.map_path;OutPath=$request.receipt_path;SourceCompositionOutPath=$request.source_path}
    $dry=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @arguments
    Assert-ActiveEnvelopeTest (-not$dry.executed-and(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)-ceq$before) 'bootstrap extension DRY changed bytes'
    foreach($damage in @('readonly-path','readonly-write','assessment-owner','map-raw','objective')){
        $bad=Copy-Envelope $request.request
        switch($damage){
            'readonly-path'{$bad.target.read_only_dependencies[0].paths=@('different/SKILL.md')}
            'readonly-write'{$bad.target.allowed_repositories+=,[pscustomobject]@{repo_id='skill-surfaces';allowed_paths=@('rusty-morphospace/SKILL.md')}}
            'assessment-owner'{$bad.target.agent_scope_assessment.owner_repositories+=,[pscustomobject]@{repo_id='skill-surfaces';source_roots=@('rusty-morphospace/SKILL.md')}}
            'map-raw'{$bad.effective_repository_map.raw_sha256='0'*64}
            'objective'{$bad.target.agent_scope_assessment.objective='Different objective.'}
        }
        $badPath=Join-Path $Root "$damage-request.json";Write-EnvelopeJson $badPath $bad;$negative=$arguments.Clone();$negative.ActiveDevelopmentEnvelopeExtension=$badPath
        $message='';try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope @negative|Out-Null}catch{$message=$_.Exception.Message}
        $pattern=switch($damage){'readonly-path'{"*read-only dependencies removes 'skill-surfaces/*"};'readonly-write'{"*cannot be both writable and read-only*"};'assessment-owner'{'*bootstrap target assessment owners*'};'map-raw'{'*map raw hash differs*'};'objective'{'*assessment outside owner roots*'}}
        Assert-ActiveEnvelopeTest ($message-like$pattern-and(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)-ceq$before) "bootstrap $damage refused its exact obligation without writes: $message"
    }
    $claimCompletion=Join-Path $workspace 'receipts/transactions/u002-claimed-0004-transition.completion.json';$original=[IO.File]::ReadAllBytes($claimCompletion)
    try{
        [IO.File]::AppendAllText($claimCompletion,' ',[Text.UTF8Encoding]::new($false))
        # A syntactically equivalent completion is still not the later origin's
        # exact bytes. The first origin captures them only after ledger proof.
        $damaged=Read-EnvelopeProtocolJson $claimCompletion;$damaged.event_id='wrong-event';Write-EnvelopeJson $claimCompletion $damaged
        $message='';try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope @arguments|Out-Null}catch{$message=$_.Exception.Message}
        Assert-ActiveEnvelopeTest ($message-like'*completion*') "bootstrap damaged native completion rejected: $message"
    }finally{[IO.File]::WriteAllBytes($claimCompletion,$original)}
    foreach($relative in @('receipts/withdrawn.json','receipts/transactions/u001-ready-withdrawn-0002-transition.completion.json')){
        $absolute=Join-Path $workspace $relative;$bytes=[IO.File]::ReadAllBytes($absolute)
        try{
            [IO.File]::Delete($absolute);$damagedBefore=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$message=''
            try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope @arguments|Out-Null}catch{$message=$_.Exception.Message}
            Assert-ActiveEnvelopeTest ($message-and(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)-ceq$damagedBefore) "bootstrap missing withdrawn prefix proof refused without writes: $relative/$message"
        }finally{[IO.File]::WriteAllBytes($absolute,$bytes)}
    }
    # Rebind the historical completion to a damaged intent so these controls
    # reach semantic reconstruction rather than merely detecting raw drift.
    foreach($damage in @('proposed-preimage','ready-selector')){
        $intentPath=Join-Path $workspace 'receipts/transactions/u002-ready-0003-transition.intent.json';$completionPath=Join-Path $workspace 'receipts/transactions/u002-ready-0003-transition.completion.json';$intentBytes=[IO.File]::ReadAllBytes($intentPath);$completionBytes=[IO.File]::ReadAllBytes($completionPath)
        try{
            $intent=Read-EnvelopeProtocolJson $intentPath;$completion=Read-EnvelopeProtocolJson $completionPath
            if($damage-ceq'proposed-preimage'){$intent.pre.unit.sha256='0'*64;$intent.expected.unit_sha256='0'*64}
            else{$intent.target.state.document.next_ready_unit='wrong-owner';$intent.target.state.sha256=Get-EnvelopeCanonicalJsonSha256 $intent.target.state.document;$completion.state_sha256=$intent.target.state.sha256}
            Write-EnvelopeCanonicalJson $intentPath $intent;$completion.intent.sha256=Get-EnvelopeFileSha256 $intentPath;Write-EnvelopeCanonicalJson $completionPath $completion
            $damagedBefore=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$message='';try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope @arguments|Out-Null}catch{$message=$_.Exception.Message}
            $pattern=if($damage-ceq'proposed-preimage'){'*Ready proposed-unit preimage*'}else{'*Ready selector semantics*'}
            Assert-ActiveEnvelopeTest ($message-like$pattern-and(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)-ceq$damagedBefore) "bootstrap native $damage refused without writes: $message"
        }finally{[IO.File]::WriteAllBytes($intentPath,$intentBytes);[IO.File]::WriteAllBytes($completionPath,$completionBytes)}
    }
    $unrelated=Join-Path $fixture.source 'unrelated.txt'
    try{
        [IO.File]::WriteAllText($unrelated,'Unrelated source dirt.',[Text.UTF8Encoding]::new($false))
        $message='';try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope @arguments|Out-Null}catch{$message=$_.Exception.Message}
        Assert-ActiveEnvelopeTest ($message-like'*outside the pre-extension active scope*'-and(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)-ceq$before) "bootstrap unrelated source dirt denied without workspace writes: $message"
    }finally{if([IO.File]::Exists($unrelated)){[IO.File]::Delete($unrelated)}}
    $arguments.ExpectedActiveDevelopmentEnvelopeExtensionSha256=Get-EnvelopeFileSha256 $request.request_path;$arguments.Execute=$true
    $done=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @arguments
    Assert-ActiveEnvelopeTest $done.executed 'native bootstrap root extension did not execute'
    $effective=&$scopeProvenanceModule {param($w,$m)Test-MorphospaceEffectiveDevelopmentEnvelope $w u002 $m} $workspace $fixture.map
    Assert-ActiveEnvelopeTest (@($effective.effective.unit.agent_scope_assessment.owner_repositories).Count-eq1-and@($effective.effective.unit.read_only_dependencies).Count-eq1-and@($effective.continuation.records).Count-eq3) 'bootstrap reader invented readonly assessment ownership or lost native records'
    foreach($relative in @('receipts/transactions/u002-ready-0003-transition.completion.json','receipts/transactions/u002-claimed-0004-transition.completion.json','receipts/transactions/u001-ready-withdrawn-0002-transition.completion.json','source-compositions/u002.lock.json','repository-map.json')){
        $absolute=Join-Path $workspace $relative;$bytes=[IO.File]::ReadAllBytes($absolute)
        try{
            [IO.File]::AppendAllText($absolute,' ',[Text.UTF8Encoding]::new($false));$damagedBefore=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$message=''
            try{&$scopeProvenanceModule {param($w,$m)Test-MorphospaceEffectiveDevelopmentEnvelope $w u002 $m} $workspace $fixture.map|Out-Null}catch{$message=$_.Exception.Message}
            Assert-ActiveEnvelopeTest ($message-like'*Native bootstrap retained origin bytes or map drifted*'-and(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)-ceq$damagedBefore) "bootstrap retained raw input damage refused without writes: $relative/$message"
        }finally{[IO.File]::WriteAllBytes($absolute,$bytes)}
    }
    # Reuse the native Ready/WithdrawReady/Ready/Claim setup for a real pending
    # v6 intent. Resume the exact same request and intent; never reseal them.
    $pending=New-ActiveEnvelopeExtensionRequest -Workspace $pendingWorkspace -RequestPath (Join-Path $Root 'after-intent-extension.json') -AddedOwnerRoot 'docs/six.md'
    Write-EnvelopeCanonicalJson $pending.request_path $pending.request
    $pendingRequestHash=Get-EnvelopeFileSha256 $pending.request_path
    $pendingArgs=@{WorkspaceRoot=$pendingWorkspace;UnitId='u002';ActiveDevelopmentEnvelopeExtension=$pending.request_path;RepositoryMapPath=$pending.map_path;OutPath=$pending.receipt_path;SourceCompositionOutPath=$pending.source_path;ExpectedActiveDevelopmentEnvelopeExtensionSha256=$pendingRequestHash;Execute=$true}
    $preimageHashes=@{};foreach($relative in @('project.spec.json','feature.lock.json','workspace.state.json','iteration-units/u002.json','iteration-events.jsonl','repository-map.json','source-compositions/u002.lock.json')){$preimageHashes[$relative]=Get-EnvelopeFileSha256 (Join-Path $pendingWorkspace $relative)}
    $faulted=$false;try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope @pendingArgs -FaultAfter after-intent|Out-Null}catch{$faulted=$_.Exception.Message-like'*Injected interruption after intent publication*'}
    Assert-ActiveEnvelopeTest $faulted 'canonical legacy-lock bootstrap did not retain a genuine after-intent interruption'
    $pendingIntentPath=Join-Path $pendingWorkspace 'receipts/transactions/u002-add-root-recorded-transition.intent.json';$pendingIntentHash=Get-EnvelopeFileSha256 $pendingIntentPath
    $pendingCompletionPath=Join-Path $pendingWorkspace 'receipts/transactions/u002-add-root-recorded-transition.completion.json'
    Assert-ActiveEnvelopeTest (-not(Test-Path -LiteralPath $pendingCompletionPath)-and-not(Test-Path -LiteralPath $pending.receipt_path)-and-not(Test-Path -LiteralPath $pending.source_path)) 'after-intent interruption installed an extension artifact or completion'
    foreach($relative in $preimageHashes.Keys){Assert-ActiveEnvelopeTest ((Get-EnvelopeFileSha256 (Join-Path $pendingWorkspace $relative))-ceq[string]$preimageHashes[$relative]) "after-intent interruption changed native preimage $relative"}
    $stageHashes=@{};foreach($index in @(0,1)){$stage=Join-Path $pendingWorkspace "receipts/transactions/u002-add-root-recorded-transition.artifact-$index.pending";$stageHashes[$stage]=Get-EnvelopeFileSha256 $stage}
    Assert-ActiveEnvelopeTest ([string]$stageHashes[(Join-Path $pendingWorkspace 'receipts/transactions/u002-add-root-recorded-transition.artifact-0.pending')]-ceq$pendingRequestHash) 'pending request stage is not the exact canonical caller bytes'
    $pendingLockPath=Join-Path $pendingWorkspace 'feature.lock.json';$pendingLockBytes=[IO.File]::ReadAllBytes($pendingLockPath)
    try{
        [IO.File]::AppendAllText($pendingLockPath,' ',[Text.UTF8Encoding]::new($false));$damagedBefore=Get-EnvelopeWorkspaceByteInventorySha256 $pendingWorkspace;$message=''
        try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope @pendingArgs|Out-Null}catch{$message=$_.Exception.Message}
        Assert-ActiveEnvelopeTest ($message-like'*durable raw additional-projection byte-hash CAS*'-and(Get-EnvelopeWorkspaceByteInventorySha256 $pendingWorkspace)-ceq$damagedBefore) "pending canonical legacy-lock recovery waived raw preimage CAS or wrote on refusal: $message"
    }finally{[IO.File]::WriteAllBytes($pendingLockPath,$pendingLockBytes)}
    Assert-ActiveEnvelopeTest ((Get-EnvelopeFileSha256 $pendingIntentPath)-ceq$pendingIntentHash-and(Get-EnvelopeFileSha256 $pending.request_path)-ceq$pendingRequestHash) 'pending negative changed the immutable intent or caller request'
    foreach($stage in $stageHashes.Keys){Assert-ActiveEnvelopeTest ((Get-EnvelopeFileSha256 $stage)-ceq[string]$stageHashes[$stage]) 'pending negative changed an exact staged artifact'}
    $resumed=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @pendingArgs
    Assert-ActiveEnvelopeTest ($resumed.executed-and(Test-Path -LiteralPath $pendingCompletionPath)-and(Get-EnvelopeFileSha256 $pendingIntentPath)-ceq$pendingIntentHash-and(Get-EnvelopeFileSha256 $pending.request_path)-ceq$pendingRequestHash-and(Get-EnvelopeFileSha256 $pending.receipt_path)-ceq$pendingRequestHash) 'same-input native replay did not complete the immutable canonical legacy-lock intent'
    $recovery=New-ActiveEnvelopeExtensionRequest -Workspace $recoveryWorkspace -RequestPath (Join-Path $Root 'recovery-extension.json') -AddedOwnerRoot 'docs/six.md'
    Write-EnvelopeCanonicalJson $recovery.request_path $recovery.request
    $faulted=$false
    try{Invoke-MorphospaceExtendActiveDevelopmentEnvelope -WorkspaceRoot $recoveryWorkspace -UnitId u002 -ActiveDevelopmentEnvelopeExtension $recovery.request_path -RepositoryMapPath $recovery.map_path -OutPath $recovery.receipt_path -SourceCompositionOutPath $recovery.source_path -ExpectedActiveDevelopmentEnvelopeExtensionSha256 (Get-EnvelopeFileSha256 $recovery.request_path) -Execute -FaultAfter after-projection|Out-Null}catch{$faulted=$_.Exception.Message-like'*Injected interruption*'}
    Assert-ActiveEnvelopeTest $faulted 'bootstrap genuine extension interruption was not reached'
    $competing=Join-Path $recoveryWorkspace 'receipts/competing-admission.json'
    try{
        Write-EnvelopeJson $competing ([pscustomobject]@{schema='rusty.morphospace.workflow.development_unit_admission.v1';unit_id='u002'})
        $damagedBefore=Get-EnvelopeWorkspaceByteInventorySha256 $recoveryWorkspace;$message=''
        try{&$transitionModule {param($w)Complete-MorphospaceTransitionLedger -WorkspaceRoot $w -TransactionId 'u002-add-root-recorded-transition' -Repair} $recoveryWorkspace|Out-Null}catch{$message=$_.Exception.Message}
        Assert-ActiveEnvelopeTest ($message-like'*zero current-unit admissions*'-and(Get-EnvelopeWorkspaceByteInventorySha256 $recoveryWorkspace)-ceq$damagedBefore) "bootstrap competing admission during genuine recovery refused without writes: $message"
    }finally{if([IO.File]::Exists($competing)){[IO.File]::Delete($competing)}}
    &$transitionModule {param($w)Complete-MorphospaceTransitionLedger -WorkspaceRoot $w -TransactionId 'u002-add-root-recorded-transition' -Repair} $recoveryWorkspace|Out-Null
    try{
        Write-EnvelopeJson $competing ([pscustomobject]@{schema='rusty.morphospace.workflow.development_unit_admission.v1';unit_id='u002'})
        $damagedBefore=Get-EnvelopeWorkspaceByteInventorySha256 $recoveryWorkspace;$message=''
        try{&$continuationModule {param($w,$m)Get-MorphospaceDevelopmentEnvelopeContinuation -WorkspaceRoot $w -BootstrapUnitId u002 -BootstrapRepositoryMapPath $m} $recoveryWorkspace $recovery.map_path|Out-Null}catch{$message=$_.Exception.Message}
        Assert-ActiveEnvelopeTest ($message-like'*zero current-unit admissions*'-and(Get-EnvelopeWorkspaceByteInventorySha256 $recoveryWorkspace)-ceq$damagedBefore) "bootstrap direct continuation competing admission refused without writes: $message"
    }finally{if([IO.File]::Exists($competing)){[IO.File]::Delete($competing)}}
    $null=&$scopeProvenanceModule {param($w,$m)Test-MorphospaceEffectiveDevelopmentEnvelope $w u002 $m} $recoveryWorkspace $recovery.map_path
    $next=New-ActiveEnvelopeExtensionRequest -Workspace $workspace -RequestPath (Join-Path $Root 'second-extension.json') -AddedOwnerRoot 'docs/seven.md'
    $next.request.extension_id='u002-add-second-root';$next.request.target.state.last_event_id='u002-add-second-root-recorded';$next.request.source_composition.path='source-composition-locks/u002-add-second-root.json'
    $next.request.expected.original_source_composition_path=$request.request.expected.original_source_composition_path;$next.request.expected.original_source_composition_raw_sha256=$request.request.expected.original_source_composition_raw_sha256;Write-EnvelopeJson $next.request_path $next.request
    $nextArgs=@{WorkspaceRoot=$workspace;UnitId='u002';ActiveDevelopmentEnvelopeExtension=$next.request_path;RepositoryMapPath=$next.map_path;OutPath=(Join-Path $workspace 'receipts/u002-add-second-root.json');SourceCompositionOutPath=(Join-Path $workspace $next.request.source_composition.path)}
    $null=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @nextArgs;$nextArgs.ExpectedActiveDevelopmentEnvelopeExtensionSha256=Get-EnvelopeFileSha256 $next.request_path;$nextArgs.Execute=$true;$null=Invoke-MorphospaceExtendActiveDevelopmentEnvelope @nextArgs
    $null=&$scopeProvenanceModule {param($w,$m)Test-MorphospaceEffectiveDevelopmentEnvelope $w u002 $m} $workspace $fixture.map
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../Test-WorkflowContracts.ps1') -RepoRoot $repoRoot -WorkspaceRoot $workspace -RepositoryMapPath $fixture.map -CurrentWorkOnly -CurrentWorkspaceOnly -SkipOwnerSelfTests
    if($LASTEXITCODE-ne0){throw 'Fresh active native bootstrap current-work reader failed.'}
    # Earn a real source checkpoint in the newly authorized sixth path.
    [IO.File]::WriteAllText((Join-Path $fixture.source 'docs/six.md'),"Newly discovered bounded source dependency.`n",[Text.UTF8Encoding]::new($false));Invoke-EnvelopeGit $fixture.source @('add','docs/six.md')|Out-Null;Invoke-EnvelopeGit $fixture.source @('commit','--quiet','-m','implement-sixth-path')|Out-Null
    $freezePath=Join-Path $Root 'bootstrap-freeze.json';$null=New-ActiveEnvelopeFreezeRequest -Workspace $workspace -RepositoryMapPath $fixture.map -RequestPath $freezePath
    $freezeArgs=@{WorkspaceRoot=$workspace;UnitId='u002';CandidateFreeze=$freezePath;OutPath=(Join-Path $workspace 'receipts/u002-extension-freeze.json')}
    $freezeDry=&$freezeModule {param($a)Invoke-MorphospaceFreezeCandidate @a} $freezeArgs;$freezeArgs.ExpectedCandidateFreezeSha256=[string]$freezeDry.audit_receipt.sha256;$freezeArgs.Execute=$true;$null=&$freezeModule {param($a)Invoke-MorphospaceFreezeCandidate @a} $freezeArgs
    $null=&$scopeProvenanceModule {param($w,$m)Test-MorphospaceEffectiveDevelopmentEnvelope $w u002 $m} $workspace $fixture.map
    $begin=&$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action BeginValidation -Execute} $fixture.lifecycle
    $current=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json');$matrix=@($begin.validation_matrix)
    $log=Join-Path $Root 'host-evidence.txt';[IO.File]::WriteAllText($log,'Host fixture checks the native contract; no product or device validation credit.',[Text.UTF8Encoding]::new($false))
    $evidence=[pscustomobject]@{receipt_id='bootstrap-native-pass';tier='quick';result='pass';artifacts=@([pscustomobject]@{artifact_id='host';kind='test-log';path=$log});criteria=@($current.acceptance|ForEach-Object{[pscustomobject]@{acceptance_id=$_.acceptance_id;status='pass';command=$_.command;evidence_refs=@('host')}});gates=@($matrix|Where-Object disposition -CNE 'forbidden'|ForEach-Object{[pscustomobject]@{gate_id=$_.gate_id;status='pass';command=$_.command;evidence_refs=@('host')}});device_validation=$null}
    $evidencePath=Join-Path $Root 'receipt-evidence.json';Write-EnvelopeJson $evidencePath $evidence
    & (Join-Path $PSScriptRoot '../New-ValidationReceipt.ps1') -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath $fixture.map -EvidencePath $evidencePath -OutPath (Join-Path $workspace 'receipts/native-pass.json')|Out-Null
    $null=&$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action RecordValidation -ValidationReceipt 'receipts/native-pass.json' -ValidationResult pass -Execute} $fixture.lifecycle
    $null=&$automationModule {param($a)Invoke-MorphospaceWorkUnitAutomation @a -Action Accept -Execute} $fixture.lifecycle
    $null=&$scopeProvenanceModule {param($w,$m)Test-MorphospaceEffectiveDevelopmentEnvelope $w u002 $m} $workspace $fixture.map
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../Test-WorkflowContracts.ps1') -RepoRoot $repoRoot -WorkspaceRoot $workspace -RepositoryMapPath $fixture.map -CurrentWorkOnly -CurrentWorkspaceOnly -SkipOwnerSelfTests
    if($LASTEXITCODE-ne0){throw 'Fresh accepted native bootstrap current-work reader failed.'}
    [pscustomobject]@{result='pass';native_ready_withdraw_ready_claim=$true;actual_readonly_shape=$true;canonical_legacy_lock_request=$true;after_intent_same_input_replay=$true;pending_raw_cas_refusal=$true;root_extension=$true;generic_recovery=$true;second_extension=$true;freeze_begin_native_receipt_record_accept=$true;later_reader=$true;modeled_host_validation=$true;workspace=$workspace}|ConvertTo-Json -Compress
}
