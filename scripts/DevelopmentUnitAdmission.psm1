Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1') -Force

function Copy-AdmissionValue { param([object]$Value) return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json) }
function Get-AdmissionTransactionId { param([string]$AdmissionId) "$AdmissionId-admitted-transition" }
function Get-AdmissionEventId { param([string]$AdmissionId) "$AdmissionId-admitted" }
function Assert-AdmissionJson { param([string]$Path,[string]$Schema,[string]$Message) if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $Path) -SchemaFile $Schema)) { throw $Message } }
function Get-AdmissionFileHash { param([string]$Workspace,[string]$Relative) Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $Workspace $Relative -RequireLeaf) }
function Assert-AdmissionPaths {
    param([object]$Unit,[object]$Assessment,[object]$Project)
    $projectById=@{}; foreach($r in @($Project.repositories)){$projectById[[string]$r.repo_id]=$r}
    $scopeById=@{}; foreach($r in @($Assessment.owner_repositories)){$scopeById[[string]$r.repo_id]=$r}
    foreach($r in @($Unit.allowed_repositories)){
        $id=[string]$r.repo_id
        if(-not $projectById.ContainsKey($id) -or -not $scopeById.ContainsKey($id)){throw "Admitted unit repository '$id' is undeclared by project or assessment."}
        foreach($path in @($r.allowed_paths)){
            $rawPath=[string]$path;$directory=$rawPath.EndsWith('/');$body=if($directory){$rawPath.TrimEnd('/')}else{$rawPath};$canonical=ConvertTo-MorphospaceProtocolRelativePath $body;if($directory){$canonical+='/' }
            if($canonical -cne $rawPath){throw "Admitted write path '$path' is not canonical."}
            $inProject=@($projectById[$id].allowed_paths|Where-Object{$canonical -eq $_ -or $canonical.StartsWith(([string]$_).TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0
            $inScope=@($scopeById[$id].source_roots|Where-Object{$canonical -eq $_ -or $canonical.StartsWith(([string]$_).TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0
            if(-not $inProject -or -not $inScope){throw "Admitted write path '$id/$canonical' exceeds project or agent source-root authority."}
        }
    }
    foreach($category in @($Unit.change_categories)){if(@($Assessment.allowed_change_categories)-cnotcontains [string]$category){throw "Unit change category '$category' exceeds admitted agent scope."}}
    if([string]$Unit.device_requirement -eq 'required' -and [string]$Assessment.device_envelope.requirement -in @('forbidden','none')){throw 'Unit device requirement exceeds the admitted device envelope.'}
}
function Invoke-AdmissionLedger {
    param([scriptblock]$Script,[object[]]$Arguments=@())
    $ledger=Get-Module MorphospaceTransitionLedger -All | Select-Object -First 1
    if($null-eq$ledger){throw 'Admission requires the transition-ledger validator.'}
    return & $ledger $Script @Arguments
}
function Get-MorphospaceAdmissionIntentBinding {
    param([string]$Workspace,[object]$Admission,[string]$InputHash,[object]$TargetState,[object]$ExpectedProject,[object]$ExpectedFeatureLock)
    $eventId=Get-AdmissionEventId ([string]$Admission.admission_id);$transactionId=Get-AdmissionTransactionId ([string]$Admission.admission_id)
    $unitPath="iteration-units/$([string]$Admission.unit_id).json";$outRelative="receipts/$([string]$Admission.admission_id).json"
    $binding=Invoke-AdmissionLedger {
        param($Root,$Id)
        $intentRelative=Get-MorphospaceLedgerPath $Root $Id intent;$intentAbsolute=Resolve-MorphospaceWorkspacePath $Root $intentRelative -RequireLeaf
        $intent=Read-MorphospaceLedgerJson $intentAbsolute;Assert-MorphospaceLedgerIntent $intent $Id;Assert-MorphospaceLedgerArtifactNamespace $Root $Id $intent
        [pscustomobject]@{intent=$intent;intent_relative=$intentRelative;intent_absolute=$intentAbsolute;completion_relative=(Get-MorphospaceLedgerPath $Root $Id completion);completion_absolute=(Resolve-MorphospaceWorkspacePath $Root (Get-MorphospaceLedgerPath $Root $Id completion))}
    } @($Workspace,$transactionId)
    $intent=$binding.intent;$expected=$Admission.expected
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or[string]$intent.transaction_id-cne$transactionId-or[string]$intent.state.path-cne'workspace.state.json'-or[string]$intent.unit.path-cne$unitPath-or[string]$intent.events.path-cne'iteration-events.jsonl'-or[string]$intent.event.event_id-cne$eventId-or[string]$intent.event.project_id-cne[string]$Admission.project_id-or[string]$intent.event.unit_id-cne[string]$Admission.unit_id){throw 'Admission intent identity is not exact.'}
    if([string]$intent.pre.state.sha256-cne[string]$expected.state_sha256-or[string]$intent.pre.unit.sha256-cne('0'*64)-or[string]$intent.expected.state_sha256-cne[string]$expected.state_sha256-or[string]$intent.expected.unit_sha256-cne('0'*64)-or[string]$intent.expected.events_sha256-cne[string]$expected.events_sha256-or[int64]$intent.expected.events_length-ne[int64]$expected.events_length-or[string]$intent.expected.event_tail_id-cne[string]$expected.event_tail_id){throw 'Admission intent preimage or ledger binding is not exact.'}
    if((Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document)-cne(Get-MorphospaceCanonicalJsonSha256 $TargetState)-or(Get-MorphospaceCanonicalJsonSha256 $intent.target.unit.document)-cne(Get-MorphospaceCanonicalJsonSha256 $Admission.unit)){throw 'Admission intent target state or unit differs from the requested admission.'}
    if(@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].path-cne$outRelative-or[string]$intent.artifacts[0].sha256-cne$InputHash){throw 'Admission intent receipt artifact is not exact.'}
    if([string]$intent.event.summary-cne'Admitted a bounded proposed development unit; normal Ready, Inspect, and Claim remain required.'-or@($intent.event.receipts).Count-ne1-or[string]@($intent.event.receipts)[0]-cne$outRelative){throw 'Admission intent event semantics or receipt path is not exact.'}
    return $binding
}
function Complete-MorphospaceDevelopmentUnitAdmission {
    param([string]$WorkspaceRoot,[object]$Admission,[string]$InputHash,[object]$TargetState,[object]$Project,[object]$FeatureLock,[ValidateSet('none','after-stage','after-intent','after-artifact','after-state','after-unit','after-event')][string]$FaultAfter='none')
    $workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$transactionId=Get-AdmissionTransactionId ([string]$Admission.admission_id);$unitPath="iteration-units/$([string]$Admission.unit_id).json"
    $lock=Enter-MorphospaceWorkspaceMutex $workspace
    try {
        $binding=Get-MorphospaceAdmissionIntentBinding $workspace $Admission $InputHash $TargetState $Project $FeatureLock;$intent=$binding.intent
        if([IO.File]::Exists($binding.completion_absolute)){
            Invoke-AdmissionLedger {
                param($Root,$Id,$IntentRelative,$IntentAbsolute,$Intent,$Completion)
                Assert-MorphospaceLedgerCommittedCompletion $Root $Id $IntentRelative $IntentAbsolute $Intent $Completion
            } @($workspace,$transactionId,$binding.intent_relative,$binding.intent_absolute,$intent,$binding.completion_absolute)|Out-Null
            return [pscustomobject]@{status='already-committed';transaction_id=$transactionId}
        }
        $statePath=Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf;$unitAbsolute=Resolve-MorphospaceWorkspacePath $workspace $unitPath;$eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
        $currentState=Read-MorphospaceProtocolJson $statePath;$currentStateHash=Get-MorphospaceCanonicalJsonSha256 $currentState
        if(@([string]$intent.pre.state.sha256,[string]$intent.target.state.sha256)-cnotcontains$currentStateHash){throw 'Admission recovery state CAS is stale or conflicting.'}
        if([IO.File]::Exists($unitAbsolute)){
            if((Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $unitAbsolute))-cne[string]$intent.target.unit.sha256){throw 'Admission recovery unit projection conflicts with its intent.'}
        }
        Invoke-AdmissionLedger { param($Path,$Intent) [void](Assert-MorphospaceLedgerEventPlacement $Path $Intent) } @($eventsPath,$intent)
        Invoke-AdmissionLedger { param($Root,$Id,$Intent) Install-MorphospaceLedgerArtifacts $Root $Id $Intent } @($workspace,$transactionId,$intent)
        if($FaultAfter-eq'after-artifact'){throw 'Injected admission interruption after artifact installation.'}
        if($currentStateHash-cne[string]$intent.target.state.sha256){Write-MorphospaceManagedProtocolJsonAtomic $workspace 'workspace.state.json' $intent.target.state.document}
        if($FaultAfter-eq'after-state'){throw 'Injected admission interruption after state projection.'}
        if(-not[IO.File]::Exists($unitAbsolute)){Write-MorphospaceManagedProtocolJsonAtomic $workspace $unitPath $intent.target.unit.document -NoOverwrite}
        if($FaultAfter-eq'after-unit'){throw 'Injected admission interruption after unit projection.'}
        $present=Invoke-AdmissionLedger { param($Path,$Intent) Assert-MorphospaceLedgerEventPlacement $Path $Intent } @($eventsPath,$intent)
        if(-not$present){Invoke-AdmissionLedger { param($Path,$Event) Add-MorphospaceLedgerEvent $Path $Event } @($eventsPath,$intent.event)}
        Invoke-AdmissionLedger { param($Path,$Intent) [void](Assert-MorphospaceLedgerEventPlacement $Path $Intent) } @($eventsPath,$intent)
        if($FaultAfter-eq'after-event'){throw 'Injected admission interruption after event append.'}
        $completion=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.transition_ledger_completion.v1';transaction_id=$transactionId;completed_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');intent=[pscustomobject]@{role='transition-ledger-intent';path=$binding.intent_relative;schema=$intent.schema;sha256=(Get-MorphospaceFileSha256 $binding.intent_absolute)};state_sha256=[string]$intent.target.state.sha256;unit_sha256=[string]$intent.target.unit.sha256;event_id=[string]$intent.event.event_id;status='committed'}
        Write-MorphospaceManagedProtocolJsonAtomic $workspace $binding.completion_relative $completion -NoOverwrite
        Invoke-AdmissionLedger {
            param($Root,$Id,$IntentRelative,$IntentAbsolute,$Intent,$Completion)
            Assert-MorphospaceLedgerCommittedCompletion $Root $Id $IntentRelative $IntentAbsolute $Intent $Completion
        } @($workspace,$transactionId,$binding.intent_relative,$binding.intent_absolute,$intent,$binding.completion_absolute)|Out-Null
        return [pscustomobject]@{status='committed';transaction_id=$transactionId}
    } finally {Exit-MorphospaceWorkspaceMutex $lock}
}
function Start-MorphospaceDevelopmentUnitAdmission {
    param([string]$Workspace,[object]$Admission,[string]$InputPath,[string]$InputHash,[object]$TargetState,[string]$Timestamp,[ValidateSet('none','after-stage','after-intent','after-artifact','after-state','after-unit','after-event')][string]$FaultAfter='none')
    $transactionId=Get-AdmissionTransactionId ([string]$Admission.admission_id);$eventId=Get-AdmissionEventId ([string]$Admission.admission_id);$unitPath="iteration-units/$([string]$Admission.unit_id).json";$outRelative="receipts/$([string]$Admission.admission_id).json";$expected=$Admission.expected
    $lock=Enter-MorphospaceWorkspaceMutex $Workspace
    try {
        $intentRelative=Invoke-AdmissionLedger { param($Root,$Id) Get-MorphospaceLedgerPath $Root $Id intent } @($Workspace,$transactionId);$intentPath=Resolve-MorphospaceWorkspacePath $Workspace $intentRelative
        if([IO.File]::Exists($intentPath)){return}
        Invoke-AdmissionLedger { param($Root,$Id) Assert-MorphospaceNoOutstandingTransitionIntent $Root $Id } @($Workspace,$transactionId)
        $eventsPath=Resolve-MorphospaceWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf;$events=@(Get-Content $eventsPath|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json});$tail=$events[-1]
        $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$eventId;sequence=[int]$tail.sequence+1;timestamp=$Timestamp;project_id=$Admission.project_id;unit_id=$Admission.unit_id;event_type='state-transition';summary='Admitted a bounded proposed development unit; normal Ready, Inspect, and Claim remain required.';receipts=@($outRelative)}
        $intent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.transition_ledger_intent.v1';transaction_id=$transactionId;created_at=$Timestamp;state=[pscustomobject]@{path='workspace.state.json'};unit=[pscustomobject]@{path=$unitPath};events=[pscustomobject]@{path='iteration-events.jsonl'};pre=[pscustomobject]@{state=[pscustomobject]@{sha256=$expected.state_sha256};unit=[pscustomobject]@{sha256=('0'*64)}};target=[pscustomobject]@{state=[pscustomobject]@{sha256=(Get-MorphospaceCanonicalJsonSha256 $TargetState);document=$TargetState};unit=[pscustomobject]@{sha256=(Get-MorphospaceCanonicalJsonSha256 $Admission.unit);document=$Admission.unit}};expected=[pscustomobject]@{state_sha256=$expected.state_sha256;unit_sha256=('0'*64);event_tail_id=$expected.event_tail_id;events_sha256=$expected.events_sha256;events_length=[int64]$expected.events_length};artifacts=@([pscustomobject]@{path=$outRelative;sha256=$InputHash;bytes_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($InputPath))});event=$event;status='prepared'}
        Invoke-AdmissionLedger { param($Intent,$Id) Assert-MorphospaceLedgerIntent $Intent $Id } @($intent,$transactionId)|Out-Null
        Invoke-AdmissionLedger { param($Path,$Intent) [void](Assert-MorphospaceLedgerEventPlacement $Path $Intent) } @($eventsPath,$intent)
        $stage=Invoke-AdmissionLedger { param($Root,$Id) Resolve-MorphospaceWorkspacePath $Root (Get-MorphospaceLedgerArtifactStagePath $Id 0) } @($Workspace,$transactionId)
        if([IO.Directory]::Exists($stage)){throw 'Admission transaction artifact stage is occupied before intent publication.'}
        $stageOwned=$false;$reusedStage=$false
        if([IO.File]::Exists($stage)){
            if((Get-MorphospaceFileSha256 $stage)-cne[string]$intent.artifacts[0].sha256){throw 'Admission transaction artifact stage conflicts with the exact admission receipt before intent publication.'}
            $reusedStage=$true
        }
        $intentPublished=$false
        try{
            if(-not$reusedStage){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stage))|Out-Null;$bytes=[Convert]::FromBase64String([string]$intent.artifacts[0].bytes_base64);$stream=[IO.FileStream]::new($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};$stageOwned=$true;if($FaultAfter-eq'after-stage'){throw 'Injected admission interruption after artifact staging before intent publication.'}}
            Write-MorphospaceManagedProtocolJsonAtomic $Workspace $intentRelative $intent -NoOverwrite;$intentPublished=$true
        }finally{
            if(-not$intentPublished-and$stageOwned-and[IO.File]::Exists($stage)){[IO.File]::Delete($stage)}
        }
        if($FaultAfter-eq'after-intent'){throw 'Injected admission interruption after intent publication.'}
    } finally {Exit-MorphospaceWorkspaceMutex $lock}
}
function Invoke-MorphospaceAdmitDevelopmentUnit {
    [CmdletBinding()]param([string]$WorkspaceRoot,[string]$DevelopmentUnitAdmission,[string]$OutPath,[string]$ExpectedDevelopmentUnitAdmissionSha256='',[string]$Timestamp='',[switch]$Execute,[ValidateSet('none','after-stage','after-intent','after-artifact','after-state','after-unit','after-event')][string]$FaultAfter='none')
    $repoRoot=Split-Path $PSScriptRoot -Parent;$workspace=(Resolve-Path $WorkspaceRoot).Path;$input=(Resolve-Path $DevelopmentUnitAdmission).Path
    Assert-AdmissionJson $input (Join-Path $repoRoot 'schemas\development-unit-admission-v1.schema.json') 'Development-unit admission does not satisfy its schema.'
    $admission=Read-MorphospaceProtocolJson $input;$inputHash=Get-MorphospaceFileSha256 $input;$unitPath="iteration-units/$([string]$admission.unit_id).json";$outRelative="receipts/$([string]$admission.admission_id).json";$outFull=Resolve-MorphospaceWorkspacePath $workspace $outRelative
    if(-not(Test-Json -Json ($admission.agent_scope_assessment|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repoRoot 'schemas\agent-scope-assessment-v1.schema.json'))){throw 'Admission agent scope assessment does not satisfy its schema.'}
    if(-not(Test-Json -Json ($admission.unit|ConvertTo-Json -Depth 64) -SchemaFile (Join-Path $repoRoot 'schemas\iteration-unit.schema.json'))){throw 'Admission unit does not satisfy the iteration-unit schema.'}
    $project=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf);$state=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf);$lockDoc=Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf)
    $eventPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf;$eventLines=@(Get-Content $eventPath|Where-Object{$_});if($eventLines.Count-lt1){throw 'Admission requires a non-empty predecessor ledger.'};$tail=($eventLines[-1]|ConvertFrom-Json)
    if([string]$project.project_id -cne [string]$admission.project_id -or [string]$state.project_id -cne [string]$admission.project_id -or [string]$admission.unit.project_id -cne [string]$admission.project_id -or [string]$admission.unit.unit_id -cne [string]$admission.unit_id){throw 'Admission project and unit identities must exactly agree.'}
    $expected=$admission.expected
    foreach($check in @(@{v=$expected.project_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $project);n='project'},@{v=$expected.feature_lock_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $lockDoc);n='feature lock'},@{v=$expected.source_composition_sha256;a=(Get-AdmissionFileHash $workspace $expected.source_composition_path);n='source composition'},@{v=$expected.repository_map_sha256;a=(Get-AdmissionFileHash $workspace $expected.repository_map_path);n='repository map'})){if([string]$check.v -cne [string]$check.a){throw "Admission stale $($check.n) preimage."}}
    if([string]$admission.unit.status -cne 'proposed'){throw 'Admission creates only a proposed successor; Ready/Claim remain normal owner actions.'}
    $assessment=$admission.agent_scope_assessment; if(($assessment|ConvertTo-Json -Depth 64 -Compress) -cne ($admission.unit.agent_scope_assessment|ConvertTo-Json -Depth 64 -Compress)){throw 'Unit admission scope differs from the authored assessment.'};Assert-AdmissionPaths $admission.unit $assessment $project
    foreach($prerequisite in @($admission.unit.prerequisites)){ $p=Resolve-MorphospaceWorkspacePath $workspace "iteration-units/$prerequisite.json" -RequireLeaf;$u=Read-MorphospaceProtocolJson $p;if([string]$u.status -cne 'accepted'){throw "Admission predecessor '$prerequisite' is not accepted."} }
    if(-not $Timestamp){$Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')};if(-not(Test-MorphospaceStrictUtcTimestamp $Timestamp)){throw 'Admission timestamp must be strict UTC.'}
    if($ExpectedDevelopmentUnitAdmissionSha256 -and $ExpectedDevelopmentUnitAdmissionSha256 -cne $inputHash){throw 'Expected development-unit admission hash does not match input.'};if($Execute -and -not $ExpectedDevelopmentUnitAdmissionSha256){throw 'Executed admission requires the dry-run admission SHA-256.'}
    if($OutPath -and [IO.Path]::GetFullPath($OutPath) -cne $outFull){throw "Admission output must be '$outRelative'."}
    $targetState=Copy-AdmissionValue $state;$eventId=Get-AdmissionEventId ([string]$admission.admission_id);$targetState.last_event_id=$eventId;$transactionId=Get-AdmissionTransactionId ([string]$admission.admission_id)
    $intentPath=Invoke-AdmissionLedger { param($Root,$Id) Resolve-MorphospaceWorkspacePath $Root (Get-MorphospaceLedgerPath $Root $Id intent) } @($workspace,$transactionId)
    if([IO.File]::Exists($intentPath)){
        [void](Test-MorphospaceDevelopmentUnitPreparation -WorkspaceRoot $workspace -Admission $admission -Phase Freeze)
        $binding=Get-MorphospaceAdmissionIntentBinding $workspace $admission $inputHash $targetState $project $lockDoc;$completed=[IO.File]::Exists($binding.completion_absolute)
        if($Execute){[void](Complete-MorphospaceDevelopmentUnitAdmission $workspace $admission $inputHash $targetState $project $lockDoc -FaultAfter $FaultAfter)}
        return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$admission.project_id;unit_id=$admission.unit_id;action='AdmitDevelopmentUnit';timestamp=$Timestamp;executed=$Execute.IsPresent;transition=$(if($completed){'development-unit-already-admitted'}else{'development-unit-admitted'});status_before=$null;status_after='proposed';current_unit_before=$null;current_unit_after=$null;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$outRelative;sha256=$inputHash};event_id=$(if($completed){$null}else{$eventId})}
    }
    [void](Test-MorphospaceDevelopmentUnitPreparation -WorkspaceRoot $workspace -Admission $admission -Phase Admission)
    if($null -ne $state.current_unit -or $null -ne $state.next_ready_unit){throw 'Admission requires an idle project with no current or ready unit.'}
    if(-not $state.last_accepted_receipt){throw 'Admission requires preserved accepted predecessor evidence.'}
    foreach($check in @(@{v=$expected.state_sha256;a=(Get-MorphospaceCanonicalJsonSha256 $state);n='state'},@{v=$expected.events_sha256;a=(Get-MorphospaceFileSha256 $eventPath);n='ledger'})){if([string]$check.v -cne [string]$check.a){throw "Admission stale $($check.n) preimage."}}
    if([int64]$expected.events_length -ne ([IO.FileInfo]$eventPath).Length -or [string]$expected.event_tail_id -cne [string]$tail.event_id){throw 'Admission stale ledger length or tail.'}
    if([IO.File]::Exists((Resolve-MorphospaceWorkspacePath $workspace $unitPath))){throw 'Admission duplicate unit identity conflicts with an existing unit document.'}
    if($Execute){
        Start-MorphospaceDevelopmentUnitAdmission $workspace $admission $input $inputHash $targetState $Timestamp -FaultAfter $FaultAfter
        [void](Complete-MorphospaceDevelopmentUnitAdmission $workspace $admission $inputHash $targetState $project $lockDoc -FaultAfter $FaultAfter)
    }
    return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.work_unit_automation_receipt.v2';project_id=$admission.project_id;unit_id=$admission.unit_id;action='AdmitDevelopmentUnit';timestamp=$Timestamp;executed=$Execute.IsPresent;transition='development-unit-admitted';status_before=$null;status_after='proposed';current_unit_before=$state.current_unit;current_unit_after=$targetState.current_unit;preservation=[ordered]@{git_mutation_performed=$false;device_mutation_performed=$false;remote_mutation_performed=$false};audit_receipt=[ordered]@{path=$outRelative;sha256=$inputHash};event_id=$(if($Execute){$eventId}else{$null})}
}
Export-ModuleMember -Function Invoke-MorphospaceAdmitDevelopmentUnit,Complete-MorphospaceDevelopmentUnitAdmission
