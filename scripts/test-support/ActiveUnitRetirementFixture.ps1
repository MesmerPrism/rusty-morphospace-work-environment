# Test-only construction of an exact reviewed request; the public writer reobserves every field.
function New-ActiveUnitRetirementRequest {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[string]$RepoMapPath='', [string]$RetirementId='retire-u002', [string]$ReplacementUnitId='u003',[object[]]$RetainedLifecycleDiagnostics=@(),[switch]$Supersession,[object]$RetainedRootDiagnostics=$null)
    if(-not$RepoMapPath){$RepoMapPath=Join-Path $WorkspaceRoot 'repository-map.json'}
    # Root diagnostics validate the complete request shape during repository
    # observation. Seed that construction-only shape from actual Git objects;
    # the compiled owner then fully reobserves/qualifies and replaces this list.
    $repositoryDrafts=@()
    if($RetainedRootDiagnostics){
        $mapDocument=Get-Content -LiteralPath $RepoMapPath -Raw|ConvertFrom-Json -Depth 100 -DateKind String
        $repositoryDrafts=@(foreach($row in @($mapDocument.repositories|Sort-Object repo_id)){
            [pscustomobject]@{repo_id=[string]$row.repo_id;head=(@(Invoke-EnvelopeGit $row.path @('rev-parse','HEAD'))[0]).Trim();tree=(@(Invoke-EnvelopeGit $row.path @('rev-parse','HEAD^{tree}'))[0]).Trim();branch=(@(Invoke-EnvelopeGit $row.path @('branch','--show-current'))-join'').Trim();clean=$true}
        })
    }
    $retirementModule=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1') -PassThru
    $lineage=$null
    if($Supersession){
        # Keep the import and fixed export in this defining fixture scope.
        # Only construction data crosses into the retirement-module block;
        # the public writer and repository observer reauthenticate it below.
        $lineageModule=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceActiveRetirementLineage.psm1') -PassThru
        $observedState=Get-Content -LiteralPath (Join-Path $WorkspaceRoot 'workspace.state.json') -Raw|ConvertFrom-Json -Depth 100 -DateKind String
        $observedId=[string]$observedState.current_unit
        $observedUnit=Get-Content -LiteralPath (Join-Path $WorkspaceRoot "iteration-units/$observedId.json") -Raw|ConvertFrom-Json -Depth 100 -DateKind String
        $observedEvents=@(Get-Content -LiteralPath (Join-Path $WorkspaceRoot 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String})
        try{
            $lineage=& $lineageModule {
                param($root,$unitId,$prefix,$current,$map)
                Get-MorphospaceActiveRetirementSupersessionLineage -WorkspaceRoot $root -UnitId $unitId -Events $prefix -CurrentUnit $current -RepositoryMapPath $map
            } $WorkspaceRoot $observedId $observedEvents $observedUnit $RepoMapPath
        }finally{
            & $retirementModule { Restore-ActiveRetirementLineageCallerModules }
        }
    }
    & $retirementModule {
        param($workspace,$mapPath,$retirementId,$replacement,$diagnostics,$supersession,$rootDiagnostics,$lineage,$repositoryDrafts)
        $state=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json');$id=[string]$state.current_unit
        $unitPath="iteration-units/$id.json";$unit=Read-MorphospaceProtocolJson (Join-Path $workspace $unitPath)
        $unitBinding=Get-ActiveRetirementFileBinding $workspace $unitPath
        $events=Get-ActiveRetirementEvents $workspace
        $expected=[ordered]@{}
        foreach($pair in @(@('project','project.spec.json'),@('feature_lock','feature.lock.json'),@('state','workspace.state.json'))){
            $binding=Get-ActiveRetirementFileBinding $workspace $pair[1];$expected["$($pair[0])_raw_sha256"]=$binding.raw_sha256;$expected["$($pair[0])_canonical_sha256"]=$binding.canonical_sha256
        }
        $expected.events_sha256=$events.sha256;$expected.events_length=$events.length;$expected.event_tail_id=$events.tail_id;$expected.repository_map_sha256=Get-MorphospaceFileSha256 $mapPath
        $request=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.active_unit_retirement.v1';retirement_id=$retirementId;project_id=[string]$state.project_id;unit_id=$id;replacement_unit_id=$replacement;reason='scope-replanned';old_unit=[pscustomobject]@{unit_id=$id;path=$unitPath;raw_sha256=$unitBinding.raw_sha256;canonical_sha256=$unitBinding.canonical_sha256;status='active'};expected=[pscustomobject]$expected;source_composition=Get-ActiveRetirementFileBinding $workspace ([string]$unit.source_composition.lock_path);claim=$null;repositories=@($repositoryDrafts);accepted_receipt=[pscustomobject]@{path=[string]$state.last_accepted_receipt;sha256=Get-MorphospaceFileSha256 (Join-Path $workspace ([string]$state.last_accepted_receipt))}}
        if($supersession){
            if($diagnostics.Count){throw 'Supersession v2 does not borrow optional v1 inert diagnostic fields.'}
            if($null-eq$lineage){throw 'Supersession fixture lacks its actual owner-produced lineage observation.'}
            $request.schema='rusty.morphospace.workflow.active_unit_retirement.v2'
            $request.PSObject.Properties.Remove('claim')
            $request|Add-Member -NotePropertyName ownership -NotePropertyValue $lineage.ownership
        }else{$request.claim=Get-ActiveRetirementClaim $workspace $request $events.events}
        if($rootDiagnostics){foreach($name in @('retained_claim_diagnostic','retained_ready_diagnostic')){if($rootDiagnostics.PSObject.Properties.Name-ccontains$name){$request|Add-Member -NotePropertyName $name -NotePropertyValue $rootDiagnostics.$name}}}
        $source=Read-MorphospaceProtocolJson (Join-Path $workspace ([string]$request.source_composition.path))
        $request|Add-Member -NotePropertyName retained_lifecycle_diagnostics -NotePropertyValue $diagnostics -Force
        if($diagnostics.Count-eq0){$request.PSObject.Properties.Remove('retained_lifecycle_diagnostics')}
        $request.repositories=@(Get-ActiveRetirementRepositories $unit $source $mapPath $workspace -Request $request)
        return $request
    } $WorkspaceRoot $RepoMapPath $RetirementId $ReplacementUnitId $RetainedLifecycleDiagnostics $Supersession.IsPresent $RetainedRootDiagnostics $lineage $repositoryDrafts
}

function New-RetirementNonpassFreezeRequest {
    param([string]$Workspace,[string]$RepositoryMapPath,[string]$RequestPath,[string]$UnitId='u002')
    $project=Read-EnvelopeProtocolJson (Join-Path $Workspace 'project.spec.json');$lock=Read-EnvelopeProtocolJson (Join-Path $Workspace 'feature.lock.json');$state=Read-EnvelopeProtocolJson (Join-Path $Workspace 'workspace.state.json');$unit=Read-EnvelopeProtocolJson (Join-Path $Workspace "iteration-units/$UnitId.json")
    $eventsPath=Join-Path $Workspace 'iteration-events.jsonl';$events=@(Get-Content -LiteralPath $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String});$map=Read-EnvelopeProtocolJson $RepositoryMapPath;$mapRows=@{};foreach($row in @($map.repositories)){$mapRows[[string]$row.repo_id]=$row}
    $final=[Collections.Generic.List[object]]::new();$changed=[Collections.Generic.List[object]]::new()
    foreach($scope in @($unit.allowed_repositories)){
        $id=[string]$scope.repo_id;if(-not$mapRows.ContainsKey($id)){throw "Freeze fixture writable repository '$id' is absent from the effective map."};$root=[string]$mapRows[$id].path
        $head=(@(Invoke-EnvelopeGit $root @('rev-parse','HEAD'))[0]).Trim().ToLowerInvariant();$tree=(@(Invoke-EnvelopeGit $root @('rev-parse','HEAD^{tree}'))[0]).Trim().ToLowerInvariant()
        $final.Add([pscustomobject][ordered]@{repo_id=$id;commit=$head;tree=$tree})|Out-Null;$changed.Add([pscustomobject][ordered]@{repo_id=$id;paths=@($scope.allowed_paths)})|Out-Null
    }
    $sourceRelative=[string]$unit.source_composition.lock_path;$sourcePath=Join-Path $Workspace $sourceRelative;$mapRelative=[IO.Path]::GetRelativePath($Workspace,$RepositoryMapPath).Replace('\','/');$deviceUse=@(if(@($unit.agent_scope_assessment.device_envelope.allowed_kinds).Count){@($unit.agent_scope_assessment.device_envelope.allowed_kinds)}else{@('none')})
    $freeze=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.candidate_freeze.v1';freeze_id="$UnitId-extension-freeze";project_id=[string]$project.project_id;unit_id=$UnitId
        expected=[pscustomobject][ordered]@{project_sha256=Get-EnvelopeCanonicalJsonSha256 $project;state_sha256=Get-EnvelopeCanonicalJsonSha256 $state;unit_sha256=Get-EnvelopeCanonicalJsonSha256 $unit;feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 $lock;source_composition_path=$sourceRelative;source_composition_sha256=Get-EnvelopeFileSha256 $sourcePath;repository_map_path=$mapRelative;repository_map_sha256=Get-EnvelopeFileSha256 $RepositoryMapPath;events_sha256=Get-EnvelopeFileSha256 $eventsPath;events_length=([IO.FileInfo]$eventsPath).Length;event_tail_id=[string]$events[-1].event_id}
        final_repositories=@($final.ToArray());changed_paths=@($changed.ToArray());cleanliness_policy='clean-only';instruction_surfaces=@([pscustomobject][ordered]@{path='README.md';disposition='reviewed-no-change'});feature_lock=[pscustomobject][ordered]@{revision=[int]$lock.revision;sha256=Get-EnvelopeCanonicalJsonSha256 $lock};effects=@($unit.agent_scope_assessment.allowed_effect_categories);permissions=@($unit.agent_scope_assessment.allowed_permission_categories);device_use=@($deviceUse);test_matrix=@([pscustomobject][ordered]@{test_id='extension';command='pwsh -NoProfile -File scripts/Test-ActiveDevelopmentEnvelopeExtension.ps1'});cleanup_evidence=@('All source repositories are clean at their exact candidate identities.');source_composition=[pscustomobject][ordered]@{path=$sourceRelative;sha256=Get-EnvelopeFileSha256 $sourcePath};does_not_prove=@('Does not validate, accept, publish, mutate Git, or operate a device.')
    }
    Write-EnvelopeJson $RequestPath $freeze
    return $freeze
}

# New ownership is always produced by the real public Supersede writer. These
# helpers author only proposed input units and reviewed exact-byte requests.
function Add-ActiveRetirementSupersession {
    param([object]$Seed,[string]$ReplacementUnitId,[string]$Timestamp,[switch]$OwnSourceLock,[switch]$InstructionReview,[string]$RepoMapPath='')
    $workspace=$Seed.workspace;$mapPath=if($RepoMapPath){$RepoMapPath}else{Join-Path $workspace 'repository-map.json'}
    $state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$oldId=[string]$state.current_unit
    $replacement=Copy-Envelope $Seed.admission_template.unit
    $replacement.unit_id=$ReplacementUnitId;$replacement.status='proposed';$replacement.objective="Model inherited ownership continuation for $ReplacementUnitId."
    # Carry the exact current admitted contract/assessment/source without a new
    # admission or Claim, including any supported root continuation corrections.
    $current=Read-EnvelopeProtocolJson (Join-Path $workspace "iteration-units/$oldId.json")
    foreach($field in @('agent_scope_assessment','source_composition','allowed_repositories','read_only_dependencies')){
        if($current.PSObject.Properties.Name-ccontains$field){
            if($field-cin@('allowed_repositories','read_only_dependencies')){
                # Copy each entry and preserve the collection even when the
                # real owner has exactly one repository/dependency (or none).
                $value=@(foreach($row in @($current.$field)){Copy-Envelope $row})
            }else{$value=Copy-Envelope $current.$field}
            $replacement|Add-Member -NotePropertyName $field -NotePropertyValue $value -Force
        }
    }
    if($InstructionReview){
        $replacement.instruction_impact='review';$replacement.instruction_none_justification=$null
        $replacement.instruction_surfaces=@([pscustomobject]@{surface_kind='readme';path='<read-only-dependency>/dependency/README.md';owner='read-only-dependency';change_reason='Review the actual unchanged fixture source after ownership supersession.';action='review-no-change';status='planned';validation='Observe exact stable fixture file bytes.';skill_id=$null})
    }
    if($OwnSourceLock){$replacement.source_composition.lock_path="source-compositions/$ReplacementUnitId-source.json"}
    Write-EnvelopeJson (Join-Path $workspace "iteration-units/$ReplacementUnitId.json") $replacement
    if($OwnSourceLock){
        # The real source writer observes a clean repository containing the
        # proposed input. Its output owns no lifecycle/admission authority.
        Invoke-EnvelopeGit $Seed.source_repository @('add','morphospace')|Out-Null;Invoke-EnvelopeGit $Seed.source_repository @('commit','-qm',"Checkpoint $ReplacementUnitId proposed source-lock input")|Out-Null
        $null=& (Join-Path $PSScriptRoot '../New-SourceCompositionLock.ps1') -WorkspaceRoot $workspace -UnitId $ReplacementUnitId -RepositoryMapPath $mapPath -OutRelativePath $replacement.source_composition.lock_path -Execute
    }
    $owner=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitSupersession.psm1') -PassThru
    $request=&$owner {
        param($workspace,$mapPath,$oldId,$newId)
        $old=Get-ActiveSupersessionUnitBinding $workspace $oldId;$new=Get-ActiveSupersessionUnitBinding $workspace $newId
        $events=Get-ActiveSupersessionEventsSnapshot (Join-Path $workspace 'iteration-events.jsonl');$map=Get-ActiveSupersessionRepositoryMap $mapPath
        $project=Read-MorphospaceProtocolJson (Join-Path $workspace 'project.spec.json');$state=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
        [pscustomobject][ordered]@{
            schema='rusty.morphospace.workflow.active_unit_supersession.v1';supersession_id="$oldId-superseded-by-$newId";project_id=$state.project_id
            old_unit=[ordered]@{unit_id=$oldId;path=$old.path;raw_sha256=$old.raw_sha256;canonical_sha256=$old.canonical_sha256;status='active'}
            replacement_unit=[ordered]@{unit_id=$newId;path=$new.path;raw_sha256=$new.raw_sha256;canonical_sha256=$new.canonical_sha256;status='proposed'};companion_units=@()
            expected=[ordered]@{project_raw_sha256=Get-MorphospaceFileSha256 (Join-Path $workspace 'project.spec.json');project_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $project;state_raw_sha256=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json');state_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $state;events_sha256=$events.sha256;events_length=$events.length;event_tail_id=$events.tail_id;repository_map_sha256=$map.sha256}
            repositories=@(Get-ActiveSupersessionRepositoryObservation $old.document @([pscustomobject]@{unit_id=$newId;role='replacement';document=$new.document;binding=$new}) $map.map)
            does_not_authorize=@('Modeled host-only workflow ownership; no product acceptance, build, device, publication, or remote operation.')
        }
    } $workspace $mapPath $oldId $ReplacementUnitId
    $requestPath=Join-Path $workspace "receipts/$oldId-superseded-by-$ReplacementUnitId-request.json";Write-EnvelopeJson $requestPath $request
    $args=@{Action='SupersedeActive';WorkspaceRoot=$workspace;UnitId=$ReplacementUnitId;RepoMapPath=$mapPath;ActiveUnitSupersession=$requestPath;OutPath=(Join-Path $workspace "receipts/$oldId-superseded-by-$ReplacementUnitId.json");Timestamp=$Timestamp}
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace
    $dry=& (Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1') @args|ConvertFrom-Json
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) 'Supersede dry run changed fixture bytes'
    $null=& (Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1') @args -ExpectedActiveUnitSupersessionSha256 $dry.audit_receipt.sha256 -Execute
}

function Add-ActiveRetirementRootNonpass {
    param([object]$Seed,[string]$TestRoot,[switch]$ReturnToActive,[ValidateSet('Committed','Untracked','Ignored')][string]$AttemptDisposition='Committed')
    $workspace=$Seed.workspace;$mapPath=Join-Path $workspace 'repository-map.json';$planning=$Seed.source_repository
    Invoke-EnvelopeGit $planning @('add','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','--allow-empty','-qm','Modeled admitted Claim checkpoint')|Out-Null
    $freezePath=Join-Path $TestRoot 'root-freeze.json';$null=New-RetirementNonpassFreezeRequest $workspace $mapPath $freezePath
    $automation=Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1';$common=@{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=$mapPath;ValidationTier='quick'}
    $null=&$automation @common -Action FreezeCandidate -CandidateFreeze $freezePath -ExpectedCandidateFreezeSha256 (Get-EnvelopeFileSha256 $freezePath) -OutPath (Join-Path $workspace 'receipts/u002-extension-freeze.json') -Timestamp '2026-08-25T00:00:44.0000000Z' -Execute
    # Omit optional diagnostic OutPaths: the real ledger remains the authority.
    $null=&$automation @common -Action BeginValidation -Timestamp '2026-08-25T00:00:45.0000000Z' -Execute
    $unit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json');$owner=Import-Module (Join-Path $PSScriptRoot '../WorkUnitAutomation.psm1') -PassThru
    $matrix=@(&$owner {param($u)New-MorphospaceValidationMatrix -Unit $u -DeviceSerials @()} $unit)
    $evidencePath=Join-Path $TestRoot 'modeled-root-failure.txt';[IO.File]::WriteAllText($evidencePath,'Modeled host-only failure to exercise real owner nonpass transitions. No device or product acceptance.')
    $evidence=[pscustomobject]@{receipt_id='u002-modeled-nonpass';tier='quick';result='fail';artifacts=@([pscustomobject]@{artifact_id='fixture';kind='host-control';path=$evidencePath});criteria=@($unit.acceptance|ForEach-Object{[pscustomobject]@{acceptance_id=$_.acceptance_id;status='fail';command=$_.command;evidence_refs=@('fixture')}});gates=@($matrix|Where-Object disposition -CNE 'forbidden'|ForEach-Object{[pscustomobject]@{gate_id=$_.gate_id;status='fail';command=$_.command;evidence_refs=@('fixture')}});device_validation=$null}
    Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceValidationReceipt.psm1')
    $null=New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath $mapPath -Evidence $evidence -OutPath (Join-Path $workspace 'receipts/root-nonpass.json') -CreatedAt '2026-08-25T00:00:46.0000000Z'
    if($ReturnToActive){
        if($AttemptDisposition-cne'Committed'){
            # Untracked input needs an explicit pathspec exclusion; ignored
            # input is already excluded by its literal private ignore rule.
            if($AttemptDisposition-ceq'Untracked'){$Seed|Add-Member -NotePropertyName excluded_attempt_git_path -NotePropertyValue 'morphospace/receipts/root-nonpass.json' -Force}
            if($AttemptDisposition-ceq'Ignored'){
                $exclude=Join-Path $planning '.git/info/exclude';[IO.File]::AppendAllText($exclude,"`n/morphospace/receipts/root-nonpass.json`n",[Text.UTF8Encoding]::new($false))
            }
        }
        $null=&$automation @common -Action ReturnToActive -ValidationReceipt 'receipts/root-nonpass.json' -ValidationResult fail -Timestamp '2026-08-25T00:00:47.0000000Z' -Execute
        Save-ActiveRetirementFixtureCheckpoint -Seed $Seed -Message 'Retain actual modeled ReturnToActive failure'
        return
    }
    $null=&$automation @common -Action RecordValidation -ValidationReceipt 'receipts/root-nonpass.json' -ValidationResult fail -Timestamp '2026-08-25T00:00:47.0000000Z' -Execute
    $null=&$automation @common -Action Resume -Timestamp '2026-08-25T00:00:48.0000000Z' -Execute
    $state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json');$heads=@();$sources=@()
    foreach($entry in @((Read-EnvelopeProtocolJson $mapPath).repositories)){
        $heads+=,[pscustomobject]@{repo_id=$entry.repo_id;revision=(@(Invoke-EnvelopeGit $entry.path @('rev-parse','HEAD'))[0]).Trim();branch=(@(Invoke-EnvelopeGit $entry.path @('branch','--show-current'))-join'').Trim()}
        $file=@(Get-ChildItem -LiteralPath $entry.path -Recurse -File|Where-Object FullName -NotMatch '[\\/]\.git[\\/]'|Select-Object -First 1)[0]
        $sources+=,[pscustomobject]@{repo_id=$entry.repo_id;sources=@([pscustomobject]@{path=[IO.Path]::GetRelativePath($entry.path,$file.FullName).Replace('\','/');sha256=Get-EnvelopeFileSha256 $file.FullName})}
    }
    $resolution=[pscustomobject]@{schema='rusty.morphospace.workflow.blocker_resolution_receipt.v1';receipt_id='u002-modeled-disposition';project_id=$state.project_id;unit_id='u002';blocker=$state.blockers[0];result='pass';evidence=@([pscustomobject]@{path='receipts/root-nonpass.json';sha256=Get-EnvelopeFileSha256 (Join-Path $workspace 'receipts/root-nonpass.json')});repository_heads=$heads;repository_sources=$sources;preserve_blocker_ids=@()}
    $resolutionPath=Join-Path $TestRoot 'root-resolution.json';Write-EnvelopeJson $resolutionPath $resolution
    $null=&$automation @common -Action ResolveBlocker -BlockerResolutionReceipt $resolutionPath -OutPath (Join-Path $workspace 'receipts/u002-modeled-disposition.json') -Timestamp '2026-08-25T00:00:49.0000000Z' -Execute
    Invoke-EnvelopeGit $planning @('add','morphospace')|Out-Null;Invoke-EnvelopeGit $planning @('commit','-qm','Retain modeled nonpass and actual continuation')|Out-Null
}

function Add-ActiveRetirementRootDiagnostics {
    param([object]$Request,[object]$Seed)
    $retirementModule=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1') -PassThru
    foreach($action in @('ready','claim')){
        $relative="receipts/u002-$action.json";$absolute=Join-Path $Seed.workspace $relative;$document=Read-EnvelopeProtocolJson $absolute
        $introduced=[string]$Seed."root_${action}_introduced_commit";$gitPath=[IO.Path]::GetRelativePath($Seed.source_repository,$absolute).Replace('\','/')
        # Git's clean filters can transport the live CRLF receipt as an LF blob.
        # These are independent raw-byte domains; read the actual original blob
        # through the owner's binary reader rather than a text command pipeline.
        $blobSha256=&$retirementModule {param($repo,$head,$path)
            [byte[]]$bytes=Read-ActiveRetirementCommittedBytes -Repository $repo -Head $head -Path $path
            Get-MorphospaceSha256Bytes $bytes
        } $Seed.source_repository $introduced $gitPath
        $blobOid=(@(Invoke-EnvelopeGit $Seed.source_repository @('rev-parse',"$($introduced):$gitPath"))[0]).Trim()
        $binding=[pscustomobject][ordered]@{role="inert-$action-diagnostic";producer_schema='rusty.morphospace.workflow.work_unit_automation_receipt.v1';path=$relative;raw_sha256=Get-EnvelopeFileSha256 $absolute;canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $document;git_blob_sha1=$blobOid;git_blob_sha256=$blobSha256;introduced_commit=$introduced;tooling_context=$null}
        if($action-ceq'ready'){
            $transaction="$($document.event_id)-transition"
            foreach($pair in @(@('event_id',[string]$document.event_id),@('transaction_id',$transaction),@('intent_sha256',(Get-EnvelopeFileSha256 (Join-Path $Seed.workspace "receipts/transactions/$transaction.intent.json"))),@('completion_sha256',(Get-EnvelopeFileSha256 (Join-Path $Seed.workspace "receipts/transactions/$transaction.completion.json"))))){$binding|Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1]}
        }
        $Request|Add-Member -NotePropertyName "retained_${action}_diagnostic" -NotePropertyValue $binding
    }
}

function Add-ActiveRetirementSupersededLifecycle {
    param([object]$Seed,[string]$UnitId='u003',[string]$RepoMapPath='',[switch]$DirtyInstructionObservation)
    $workspace=$Seed.workspace;if(-not$RepoMapPath){$RepoMapPath=Join-Path $workspace 'repository-map.json'}
    $automation=Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1';$common=@{WorkspaceRoot=$workspace;UnitId=$UnitId;RepoMapPath=$RepoMapPath;ValidationTier='quick'}
    $instruction=@{Action='CompleteInstructionSurfaces';InstructionCompletionId="$UnitId-review";OutPath=(Join-Path $workspace "receipts/$UnitId-review.json");Timestamp='2026-08-25T00:00:51.1000000Z'}
    $probePath=$null;$probeBytes=$null;$untrackedPath=$null
    if($DirtyInstructionObservation){
        $probePath=Join-Path $Seed.dependency_repository 'dependency/instruction-observation-probe.txt'
        $untrackedPath=Join-Path $Seed.dependency_repository 'dependency/instruction-observation-untracked.txt'
        Assert-Envelope ((Test-Path -LiteralPath $probePath -PathType Leaf)-and-not(Test-Path -LiteralPath $untrackedPath)) 'dirty instruction fixture lacks its exact tracked probe or has an unrelated untracked probe'
        $probeBytes=[IO.File]::ReadAllBytes($probePath)
        [IO.File]::AppendAllText($probePath,"`nMODELED temporary tracked instruction-observation dirt.",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($untrackedPath,'MODELED temporary untracked instruction-observation dirt.',[Text.UTF8Encoding]::new($false))
    }
    try{
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$dry=&$automation @common @instruction|ConvertFrom-Json
        Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) 'post-Supersede instruction dry run wrote bytes'
        $null=&$automation @common @instruction -InstructionSurfaceIds @($dry.instruction_surface_completion.surfaces.surface_id) -ExpectedUnitSha256 $dry.instruction_surface_completion.expected_unit_sha256 -ExpectedInstructionObservationSha256 $dry.instruction_surface_completion.observation_sha256 -Execute
        if($DirtyInstructionObservation){
            $receipt=Read-EnvelopeProtocolJson $instruction.OutPath
            $observed=@($receipt.preservation.repository_states|Where-Object repo_id -CEQ 'read-only-dependency')
            $preflight=@($receipt.claim_preflight.writable_repositories|Where-Object repo_id -CEQ 'read-only-dependency')
            Assert-Envelope ($observed.Count-eq1-and$preflight.Count-eq1-and$observed[0].dirty-eq$true-and$observed[0].tracked_changes-ge1-and$observed[0].untracked_changes-ge1-and[string]$observed[0].head-ceq[string]$preflight[0].head-and[string]$observed[0].tree-ceq[string]$preflight[0].tree) 'actual CompleteInstructions did not retain genuine dirty tracked/untracked observation and matching preflight'
        }
    }finally{
        if($DirtyInstructionObservation){[IO.File]::WriteAllBytes($probePath,$probeBytes);Remove-Item -LiteralPath $untrackedPath -Force}
    }
    if($DirtyInstructionObservation){Assert-Envelope (@(Invoke-EnvelopeGit $Seed.dependency_repository @('status','--porcelain=v1','--untracked-files=all')).Count-eq0) 'temporary instruction dirt was not restored before the genuine Freeze'}
    # Keep the reviewed input outside the source worktree. The genuine source
    # lock pins its clean proposed-input HEAD; own-planning transport stays at
    # that HEAD while real lifecycle files are written before this Freeze.
    $freezePath=Join-Path (Split-Path $Seed.source_repository -Parent) "$UnitId-after-supersede-freeze.json"
    $null=New-RetirementNonpassFreezeRequest -Workspace $workspace -RepositoryMapPath $RepoMapPath -RequestPath $freezePath -UnitId $UnitId
    $call=@{Action='FreezeCandidate';CandidateFreeze=$freezePath;OutPath=(Join-Path $workspace "receipts/$UnitId-extension-freeze.json");Timestamp='2026-08-25T00:00:51.2000000Z'}
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$dry=&$automation @common @call|ConvertFrom-Json
    Assert-Envelope ($before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) 'post-Supersede Freeze dry run wrote bytes'
    $null=&$automation @common @call -ExpectedCandidateFreezeSha256 $dry.audit_receipt.sha256 -Execute
}

# A tracked file distinct from the reviewed instruction keeps that instruction's
# bytes unchanged. Its real commit is inside the already-owned dependency/ scope,
# before the successor's genuine source-lock writer captures the new clean HEAD.
function Initialize-ActiveRetirementInstructionDirtFixture {
    param([object]$Seed)
    $relative='dependency/instruction-observation-probe.txt';$path=Join-Path $Seed.dependency_repository $relative
    Assert-Envelope (-not(Test-Path -LiteralPath $path)) 'instruction dirt probe already exists'
    [IO.File]::WriteAllText($path,'MODELED stable tracked source for historical observation controls.'+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    Invoke-EnvelopeGit $Seed.dependency_repository @('add','--',$relative)|Out-Null
    Invoke-EnvelopeGit $Seed.dependency_repository @('commit','-qm','Retain tracked historical instruction observation probe')|Out-Null
}

# Generic ledger binding is validated before each semantic refusal, so a malformed
# artifact/completion cannot masquerade as coverage for the historical branch.
function Test-ActiveRetirementDirtyInstructionSemantics {
    param([object]$Case)
    $retirementModule=Import-Module (Join-Path $PSScriptRoot '../ActiveUnitRetirement.psm1') -PassThru
    $lineage=Get-SupersessionSemanticLineage $Case
    $records=@($lineage.planning_projection|Where-Object{[string]$_.event.event_id-ceq'u003-review-recorded'})
    Assert-Envelope ($records.Count-eq1) 'dirty fixture lacks its genuine instruction transaction'
    $record=$records[0];$binding=@($record.intent.artifacts)[0]
    $receiptPath=Join-Path $Case.workspace ([string]$binding.path);$receipt=Read-EnvelopeProtocolJson $receiptPath
    $observed=@($receipt.preservation.repository_states|Where-Object repo_id -CEQ 'read-only-dependency')[0]
    Assert-Envelope ($observed.dirty-eq$true-and$observed.tracked_changes-ge1-and$observed.untracked_changes-ge1) 'historical instruction receipt was not actually dirty'
    $prior=&$retirementModule {param($w,$id)Get-ActiveRetirementPlanningTransition $w $id -HistoricalProjection} $Case.workspace "$([string]$record.intent.expected.event_tail_id)-transition"
    $ordinaryMessage=''
    try{$null=&$retirementModule {param($s,$u,$r)Set-ActiveRetirementInstructionRepositoryProjection $s $u $r} (Copy-Envelope $prior.intent.target.state.document) $prior.intent.target.unit.document $receipt}catch{$ordinaryMessage=$_.Exception.Message}
    Assert-Envelope ($ordinaryMessage-ceq'Active retirement instruction repository observation/preflight join is invalid.') 'ordinary v1 replay stopped refusing a dirty historical instruction observation'
    $intentPath=Join-Path $Case.workspace "receipts/transactions/$($record.intent.transaction_id).intent.json"
    $completionPath=Join-Path $Case.workspace "receipts/transactions/$($record.intent.transaction_id).completion.json"
    $receiptBytes=[IO.File]::ReadAllBytes($receiptPath);$intentBytes=[IO.File]::ReadAllBytes($intentPath);$completionBytes=[IO.File]::ReadAllBytes($completionPath)
    foreach($damage in @('preflight-head','preflight-paths','detached-receipt-event')){
        try{
            $badReceipt=Copy-Envelope $receipt;$badIntent=Copy-Envelope $record.intent;$completion=Copy-Envelope $record.completion
            switch($damage){
                'preflight-head'{$badReceipt.claim_preflight.writable_repositories[0].head='0'*40;$expected='Active retirement instruction repository observation/preflight join is invalid.'}
                'preflight-paths'{$badReceipt.claim_preflight.writable_repositories[0].allowed_paths=@('dependency/foreign/');$expected='Active retirement instruction repository paths binding drifted.'}
                'detached-receipt-event'{$badReceipt.event_id='u099-review-recorded';$expected='Development continuation instruction-completion receipt is detached.'}
            }
            Write-EnvelopeJson $receiptPath $badReceipt
            $badIntent.artifacts[0].sha256=Get-EnvelopeFileSha256 $receiptPath
            $badIntent.artifacts[0].bytes_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($receiptPath))
            Write-SupersessionSemanticTransition $Case.workspace $badIntent $completion
            $null=Get-SupersessionGenericHistoricalProof $Case.workspace $badIntent.transaction_id
            $before=Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace;$message=''
            try{$null=Get-SupersessionSemanticLineage $Case}catch{$message=$_.Exception.Message}
            Assert-Envelope ($message-ceq$expected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace)) "dirty instruction $damage did not reach its exact semantic refusal: $message"
        }finally{[IO.File]::WriteAllBytes($receiptPath,$receiptBytes);[IO.File]::WriteAllBytes($intentPath,$intentBytes);[IO.File]::WriteAllBytes($completionPath,$completionBytes)}
        $null=Get-SupersessionSemanticLineage $Case
    }
    # This case deliberately relocated its dependency after the first source
    # lock. Damage the currently selected materialization, not the preserved
    # original checkout that no longer supplies the current repository row.
    $currentMap=Read-EnvelopeProtocolJson $Case.arguments.RepoMapPath
    $currentDependency=@($currentMap.repositories|Where-Object repo_id -CEQ 'read-only-dependency')
    Assert-Envelope ($currentDependency.Count-eq1) 'current dirty-source control lacks its actual dependency materialization'
    $probe=Join-Path $currentDependency[0].path 'dependency/instruction-observation-probe.txt';$probeBytes=[IO.File]::ReadAllBytes($probe)
    try{
        [IO.File]::AppendAllText($probe,"`nMODELED current dirty source must still refuse.",[Text.UTF8Encoding]::new($false))
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace;$rejected=$false
        try{$null=Invoke-SupersessionRetirement $Case -Execute}catch{$rejected=$true}
        Assert-Envelope ($rejected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace)) 'historical dirty observation waived current source cleanliness or wrote a retirement'
    }finally{[IO.File]::WriteAllBytes($probe,$probeBytes)}
    $null=Invoke-SupersessionRetirement $Case
}

# Semantic adverse controls derive from authenticated real writer outputs. Only
# negative copies/files are changed, with all outer byte/hash joins kept exact
# where necessary so the specific new semantic guard is actually exercised.
function Test-ActiveRetirementSupersessionSemantics {
    param([object]$Case)
    $protocolModule=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceProtocolCommon.psm1') -PassThru
    $module=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceActiveRetirementLineage.psm1') -PassThru
    $workspace=$Case.workspace;$unit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u004.json');$events=@(Get-Content -LiteralPath (Join-Path $workspace 'iteration-events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -DateKind String})
    $lineage=&$module {param($w,$u,$e,$m,$paths)Get-MorphospaceActiveRetirementSupersessionLineage -WorkspaceRoot $w -UnitId u004 -CurrentUnit $u -Events $e -RepositoryMapPath $m -HistoricalRepositoryMapPaths $paths} $workspace $unit $events $Case.arguments.RepoMapPath @($Case.request.ownership.repository_maps.path)
    $records=@($lineage.planning_projection);$index=0;for($i=0;$i-lt$records.Count;$i++){if([string]$records[$i].event.event_id-ceq'u003-superseded-by-u004'){$index=$i}}
    Assert-Envelope ($index-gt0) 'semantic fixture lacks actual final Supersede and predecessor'
    $record=$records[$index];$previous=$records[$index-1].intent;$beforeUnit=$record.intent.supersession.old_unit.document
    $map=Read-EnvelopeProtocolJson $Case.arguments.RepoMapPath
    $null=&$module {param($w,$p,$old,$prev,$map,$project)Assert-RetirementLineageSupersession $w $p $old $prev $map $project} $workspace $record $beforeUnit $previous $map $lineage.project
    $edge=$Case.request.ownership.supersessions[-1];$requestPath=Join-Path $workspace $edge.request.path;$receiptPath=Join-Path $workspace $edge.receipt.path
    $requestBytes=[IO.File]::ReadAllBytes($requestPath);$receiptBytes=[IO.File]::ReadAllBytes($receiptPath)
    foreach($damage in @('case-widening','dotdot-path','double-slash-path','duplicate-repository','duplicate-path')){
        try{
            $proof=Copy-Envelope $record;$target=$proof.intent.target.unit.document
            switch($damage){
                'case-widening'{$target.allowed_repositories[0].allowed_paths=@('Dependency/')}
                'dotdot-path'{$target.allowed_repositories[0].allowed_paths=@('dependency/../outside/')}
                'double-slash-path'{$target.allowed_repositories[0].allowed_paths=@('dependency//nested/')}
                'duplicate-repository'{$target.allowed_repositories=@($target.allowed_repositories)+@((Copy-Envelope $target.allowed_repositories[0]))}
                'duplicate-path'{$target.allowed_repositories[0].allowed_paths=@('dependency/','dependency/')}
            }
            $proposed=Copy-Envelope $target;$proposed.status='proposed'
            $request=Read-EnvelopeProtocolJson $requestPath;$request.replacement_unit.canonical_sha256=Get-EnvelopeCanonicalJsonSha256 $proposed
            $request.replacement_unit.raw_sha256=&$protocolModule {param($v)Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $v)} $proposed
            Write-EnvelopeJson $requestPath $request
            $receipt=Read-EnvelopeProtocolJson $receiptPath;$receipt.audit_receipt.sha256=Get-EnvelopeFileSha256 $requestPath;Write-EnvelopeJson $receiptPath $receipt
            $proof.intent.pre.unit.sha256=$request.replacement_unit.canonical_sha256;$proof.intent.target.unit.sha256=Get-EnvelopeCanonicalJsonSha256 $target
            $proof.intent.artifacts[0].sha256=Get-EnvelopeFileSha256 $receiptPath;$proof.intent.artifacts[0].bytes_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($receiptPath))
            $before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$rejected=$false
            try{$null=&$module {param($w,$p,$old,$prev,$map,$project)Assert-RetirementLineageSupersession $w $p $old $prev $map $project} $workspace $proof $beforeUnit $previous $map $lineage.project}catch{$rejected=$_.Exception.Message-cmatch'(replacement unit schema|repeats a repository|widens source ownership|source path is not canonical)'-or($damage-ceq'duplicate-path'-and[string]$_.InvocationInfo.MyCommand.Name-ceq'Test-Json')}
            Assert-Envelope ($rejected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) "semantic Supersede guard accepted or wrote $damage"
        }finally{[IO.File]::WriteAllBytes($requestPath,$requestBytes);[IO.File]::WriteAllBytes($receiptPath,$receiptBytes)}
    }
    # Remove a declared read-only source while preserving valid fresh-lock
    # schema/fingerprint. This targets closure completeness, not a raw CAS typo.
    foreach($sourceId in @('u003','u004')){
        $path=Join-Path $workspace "source-compositions/$sourceId-source.json";$saved=[IO.File]::ReadAllBytes($path)
        try{
            $source=Read-EnvelopeProtocolJson $path;$source.repositories=@($source.repositories|Where-Object repo_id -CNE 'project-shell')
            $identity=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceSourceCompositionIdentity.psm1') -PassThru
            $source.fingerprint=&$identity {param($s)Get-MorphospaceSourceCompositionFingerprint -ProjectId $s.project_id -UnitId $s.unit_id -Repositories @($s.repositories)} $source
            Write-EnvelopeJson $path $source;$before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$rejected=$false
            try{$null=&$module {param($w,$u,$e,$m,$paths)Get-MorphospaceActiveRetirementSupersessionLineage -WorkspaceRoot $w -UnitId u004 -CurrentUnit $u -Events $e -RepositoryMapPath $m -HistoricalRepositoryMapPaths $paths} $workspace $unit $events $Case.arguments.RepoMapPath @($Case.request.ownership.repository_maps.path)}catch{$rejected=$_.Exception.Message-like'*declared read-only dependency*'}
            Assert-Envelope ($rejected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) "lineage accepted or wrote omitted read-only source at $sourceId"
        }finally{[IO.File]::WriteAllBytes($path,$saved)}
    }
    # The intermediate lock has a real Freeze raw-byte pin; this does not
    # invent an original raw pin for an otherwise unfrozen fresh Supersede.
    $path=Join-Path $workspace 'source-compositions/u003-source.json';$saved=[IO.File]::ReadAllBytes($path)
    try{
        [IO.File]::AppendAllText($path,"`n");$before=Get-EnvelopeWorkspaceByteInventorySha256 $workspace;$rejected=$false
        try{$null=&$module {param($w,$u,$e,$m,$paths)Get-MorphospaceActiveRetirementSupersessionLineage -WorkspaceRoot $w -UnitId u004 -CurrentUnit $u -Events $e -RepositoryMapPath $m -HistoricalRepositoryMapPaths $paths} $workspace $unit $events $Case.arguments.RepoMapPath @($Case.request.ownership.repository_maps.path)}catch{$rejected=$_.Exception.Message-cmatch'(Freeze|[Ss]ource.*(bytes|composition|pin|drift|differ))'}
        Assert-Envelope ($rejected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $workspace)) 'retained intermediate Freeze source raw-byte pin accepted drift or wrote bytes'
    }finally{[IO.File]::WriteAllBytes($path,$saved)}
    return $lineage
}

function Test-ActiveRetirementEndpointAuthoritySemantics {
    param([object]$Case,[object]$Lineage)
    $protocolModule=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceProtocolCommon.psm1') -PassThru
    $module=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceActiveRetirementLineage.psm1') -PassThru
    $intent=Read-EnvelopeProtocolJson (Join-Path $Case.workspace 'receipts/transactions/retire-u004-active-retired-transition.intent.json')
    $null=&$module {param($e,$p,$f)Assert-RetirementLineageEndpointAuthority $e $p $f} $intent $Lineage.project $Lineage.feature_lock
    foreach($name in @('project','feature_lock')){
        $bad=Copy-Envelope $intent;$relative=if($name-ceq'project'){'project.spec.json'}else{'feature.lock.json'};$projection=@($bad.additional_projections|Where-Object path -CEQ $relative)[0]
        $projection.document.revision=[int]$projection.document.revision+1
        if($name-ceq'feature_lock'){$projection.document.lock_fingerprint=Get-EnvelopeLockFingerprint $projection.document}
        $canonical=Get-EnvelopeCanonicalJsonSha256 $projection.document;$raw=&$protocolModule {param($v)Get-MorphospaceSha256Bytes (ConvertTo-MorphospaceProtocolJsonBytes $v)} $projection.document
        $projection.pre_sha256=$canonical;$projection.target_sha256=$canonical;$projection.pre_raw_sha256=$raw
        $artifact=@($bad.artifacts|Where-Object path -CEQ 'receipts/retire-u004-request.json')[0];$request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($artifact.bytes_base64))|ConvertFrom-Json -Depth 100 -DateKind String
        $request.expected."${name}_canonical_sha256"=$canonical;$request.expected."${name}_raw_sha256"=$raw
        $bytes=&$protocolModule {param($v)ConvertTo-MorphospaceProtocolJsonBytes $v} $request;$artifact.bytes_base64=[Convert]::ToBase64String($bytes);$artifact.sha256=&$protocolModule {param($b)Get-MorphospaceSha256Bytes $b} $bytes
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace;$rejected=$false
        try{$null=&$module {param($e,$p,$f)Assert-RetirementLineageEndpointAuthority $e $p $f} $bad $Lineage.project $Lineage.feature_lock}catch{$rejected=$_.Exception.Message-like'*authority pins do not join*'}
        Assert-Envelope ($rejected-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $Case.workspace)) "reconstructed endpoint accepted or wrote substituted $name authority"
    }
}

function Save-ActiveRetirementFixtureCheckpoint {
    param([object]$Seed,[string]$Message)
    if($Seed.PSObject.Properties.Name-ccontains'excluded_attempt_git_path'){
        Invoke-EnvelopeGit $Seed.source_repository @('add','--all','--','morphospace',(':(exclude)'+[string]$Seed.excluded_attempt_git_path))|Out-Null
    }else{Invoke-EnvelopeGit $Seed.source_repository @('add','morphospace')|Out-Null}
    Invoke-EnvelopeGit $Seed.source_repository @('commit','-qm',$Message)|Out-Null
}

function Add-ActiveRetirementSecondReturn {
    param([object]$Seed,[string]$TestRoot,[string]$UnitId)
    $workspace=$Seed.workspace;$mapPath=Join-Path $workspace 'repository-map.json';$automation=Join-Path $PSScriptRoot '../Invoke-WorkUnitAutomation.ps1'
    $common=@{WorkspaceRoot=$workspace;UnitId=$UnitId;RepoMapPath=$mapPath;ValidationTier='quick'}
    $null=&$automation @common -Action BeginValidation -Timestamp '2026-08-25T00:00:51.3000000Z' -Execute
    $unit=Read-EnvelopeProtocolJson (Join-Path $workspace "iteration-units/$UnitId.json");$owner=Import-Module (Join-Path $PSScriptRoot '../WorkUnitAutomation.psm1') -PassThru
    $matrix=@(&$owner {param($u)New-MorphospaceValidationMatrix -Unit $u -DeviceSerials @()} $unit)
    $artifact=Join-Path $TestRoot 'modeled-second-failure.txt';[IO.File]::WriteAllText($artifact,'Second MODELED host-only attempt, for exact actual ReturnToActive event ordering. No product validation or acceptance.')
    $evidence=[pscustomobject]@{receipt_id="$UnitId-second-modeled-nonpass";tier='quick';result='fail';artifacts=@([pscustomobject]@{artifact_id='fixture';kind='host-control';path=$artifact});criteria=@($unit.acceptance|ForEach-Object{[pscustomobject]@{acceptance_id=$_.acceptance_id;status='fail';command=$_.command;evidence_refs=@('fixture')}});gates=@($matrix|Where-Object disposition -CNE 'forbidden'|ForEach-Object{[pscustomobject]@{gate_id=$_.gate_id;status='fail';command=$_.command;evidence_refs=@('fixture')}});device_validation=$null}
    Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceValidationReceipt.psm1')
    $receiptRelative="receipts/$UnitId-second-nonpass.json"
    $null=New-MorphospaceValidationReceiptV1 -WorkspaceRoot $workspace -UnitId $UnitId -RepoMapPath $mapPath -Evidence $evidence -OutPath (Join-Path $workspace $receiptRelative) -CreatedAt '2026-08-25T00:00:51.4000000Z'
    $null=&$automation @common -Action ReturnToActive -ValidationReceipt $receiptRelative -ValidationResult fail -Timestamp '2026-08-25T00:00:51.5000000Z' -Execute
    Save-ActiveRetirementFixtureCheckpoint -Seed $Seed -Message 'Retain second actual modeled ReturnToActive attempt'
}

function Assert-ActiveRetirementAttemptDisposition {
    param([object]$Case,[ValidateSet('Untracked','Ignored')][string]$Disposition)
    $gitPath='morphospace/receipts/root-nonpass.json'
    $status=@(Invoke-EnvelopeGit $Case.seed.source_repository @('status','--porcelain=v1','--untracked-files=all','--',$gitPath))
    if($Disposition-ceq'Untracked'){
        Assert-Envelope ($status.Count-eq1-and[string]$status[0]-ceq("?? "+$gitPath)) 'retained attempt is not genuinely untracked'
    }else{
        $ignored=@(Invoke-EnvelopeGit $Case.seed.source_repository @('check-ignore','--',$gitPath))
        Assert-Envelope ($status.Count-eq0-and$ignored.Count-eq1-and[string]$ignored[0]-ceq$gitPath) 'retained attempt is not genuinely ignored by its literal private exclude rule'
    }
    $attempts=@($Case.request.ownership.validation_attempts)
    Assert-Envelope ($attempts.Count-eq1-and[string]$attempts[0].path-ceq'receipts/root-nonpass.json') 'retained attempt binding does not exactly name its actual producer-referenced input'
}
