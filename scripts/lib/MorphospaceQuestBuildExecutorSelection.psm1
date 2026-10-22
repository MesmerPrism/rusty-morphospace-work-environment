Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceValidationReceipt.psm1')

function Assert-QuestSelection([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Test-QuestSelectionEqual($Left,$Right){if($null-eq$Left-or$null-eq$Right){return $null-eq$Left-and$null-eq$Right};(ConvertTo-MorphospaceCanonicalJson $Left)-ceq(ConvertTo-MorphospaceCanonicalJson $Right)}
function Get-QuestSelectionPathComparer { if([IO.Path]::DirectorySeparatorChar-eq'\'){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal} }
function New-QuestSelectionObservation { [pscustomobject]@{files=[Collections.Generic.Dictionary[string,object]]::new((Get-QuestSelectionPathComparer))} }
function Get-QuestSelectionPath([string]$Path,[switch]$Directory){
    Assert-QuestSelection ([IO.Path]::IsPathFullyQualified($Path)) 'Selection paths must be explicit absolute paths.'
    $full=[IO.Path]::GetFullPath($Path)
    Assert-MorphospaceNoReparseAncestor -Root ([IO.Path]::GetPathRoot($full)) -Candidate $full
    Assert-QuestSelection $(if($Directory){[IO.Directory]::Exists($full)}else{[IO.File]::Exists($full)}) "Selection path is missing or has the wrong kind: $full"
    $full
}
function Get-QuestSelectionReference([string]$Path){
    $full=Get-QuestSelectionPath $Path
    [pscustomobject][ordered]@{path=$full;bytes=[long]([IO.FileInfo]::new($full)).Length;sha256=Get-MorphospaceFileSha256 $full}
}
function Read-QuestSelectionReference($Reference,$Observation){
    Assert-MorphospaceExactPropertySet $Reference @('path','bytes','sha256') @() 'Selection raw reference'
    Assert-QuestSelection ($Reference.bytes-is[long]-or$Reference.bytes-is[int]) 'Raw reference length must be an integer.'
    Assert-QuestSelection ($Reference.bytes-ge0-and[string]$Reference.sha256-cmatch'^[0-9a-f]{64}$') 'Raw reference has an invalid hash/length.'
    $full=Get-QuestSelectionPath ([string]$Reference.path)
    $stream=[IO.FileStream]::new($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        Assert-QuestSelection ($stream.Length-eq[long]$Reference.bytes-and(Get-MorphospaceStreamSha256 $stream)-ceq[string]$Reference.sha256) 'Selection proof bytes changed.'
        Assert-QuestSelection ($stream.Length-le67108864) 'Selection control file exceeds 64 MiB.'
        $bytes=[byte[]]::new([int]$stream.Length);$read=0
        while($read-lt$bytes.Length){$n=$stream.Read($bytes,$read,$bytes.Length-$read);if($n-le0){throw 'Short selection proof read.'};$read+=$n}
    }finally{$stream.Dispose()}
    if($Observation.files.ContainsKey($full)){Assert-QuestSelection (Test-QuestSelectionEqual $Observation.files[$full] $Reference) 'One proof path has conflicting references.'}else{$Observation.files.Add($full,$Reference)}
    return ,$bytes
}
function Read-QuestSelectionJson($Reference,$Observation){
    # Provider payloads include arrays and diagnostic numeric values. Parse the
    # checked bytes using the public authority-reader convention; owner protocol
    # admission remains with its own strict schema and committed-ledger readers.
    $text=[Text.UTF8Encoding]::new($false,$true).GetString((Read-QuestSelectionReference $Reference $Observation))
    return ,($text|ConvertFrom-Json -Depth 100 -DateKind String -NoEnumerate)
}
function Assert-QuestSelectionObservation($Observation){foreach($ref in $Observation.files.Values){Assert-QuestSelection (Test-QuestSelectionEqual (Get-QuestSelectionReference $ref.path) $ref) 'Selection proof drifted during observation.'}}
function Resolve-QuestSelectionRelative([string]$Root,[string]$Path){
    $canonical=ConvertTo-MorphospaceProtocolRelativePath $Path
    Assert-QuestSelection ($canonical-ceq$Path) 'Selection relative path is not canonical.'
    Resolve-MorphospaceWorkspacePath $Root $canonical -RequireLeaf
}
function Read-QuestSelectionRelative($Root,$Reference,$Observation){
    $absolute=[pscustomobject]@{path=Resolve-QuestSelectionRelative $Root ([string]$Reference.path);bytes=$Reference.bytes;sha256=$Reference.sha256}
    [void](Read-QuestSelectionReference $absolute $Observation);$absolute
}
function Get-QuestSelectionArgument([string[]]$Arguments,[string]$Name){
    $indices=@(for($i=0;$i-lt$Arguments.Count;$i++){if($Arguments[$i]-ceq$Name){$i}})
    Assert-QuestSelection ($indices.Count-eq1-and$indices[0]+1-lt$Arguments.Count) "Exactly one $Name argument is required."
    $Arguments[$indices[0]+1]
}
function Get-QuestSelectionActualArgumentPath($Intent,[string]$Name){
    $value=Get-QuestSelectionArgument $Intent.argv $Name
    if(-not[IO.Path]::IsPathFullyQualified($value)){$value=Join-Path ([string]$Intent.cwd) $value}
    [IO.Path]::GetFullPath($value)
}
function Test-MorphospaceQuestBuildExecutorApiGet {
    param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$Endpoint)
    Assert-QuestSelection ($Endpoint.StartsWith('repos/',[StringComparison]::Ordinal)-and$Endpoint-notmatch'[:\\\r\n\x00]'-and@($Endpoint.Split('/')|Where-Object{$_-cin@('','.','..')}).Count-eq0) 'Expected API endpoint must be relative and exact.'
    Assert-QuestSelection ($Arguments.Count-ge3-and[IO.Path]::GetFileNameWithoutExtension($Arguments[0])-ieq'gh'-and$Arguments[1]-ceq'api') 'Expected actual gh api argv.'
    $hostSeen=$false;$methodSeen=$false;$endpointSeen=$false
    for($i=2;$i-lt$Arguments.Count;$i++){
        $token=$Arguments[$i]
        if($token-cin@('--hostname','--method')){
            Assert-QuestSelection ($i+1-lt$Arguments.Count) 'API option lacks a value.';$i++;$value=$Arguments[$i]
            if($token-ceq'--hostname'){Assert-QuestSelection (-not$hostSeen-and$value-ceq'github.com') 'Only one literal github.com hostname is permitted.';$hostSeen=$true}
            else{Assert-QuestSelection (-not$methodSeen-and$value-ceq'GET') 'Only one literal GET method is permitted.';$methodSeen=$true}
        }else{Assert-QuestSelection (-not$endpointSeen-and$token-ceq$Endpoint) 'Only the expected GET endpoint and finite options are permitted.';$endpointSeen=$true}
    }
    Assert-QuestSelection $endpointSeen 'Expected GET endpoint is missing.'
}
function Read-QuestSelectionOriginal($Reference,$Observation){
    $c=Read-QuestSelectionJson $Reference $Observation
    Assert-QuestSelection ($c.schema-ceq'task.root.command_capture_completion.v2'-and$c.exit_code-eq0-and$c.genuine_full_eof-eq$true-and$c.raw_capture_complete-eq$true-and$c.process_reaped-eq$true-and$c.termination_requested-eq$false-and$c.automatic_retry-eq$false-and@($c.observer_errors).Count-eq0) 'Original did not genuinely close successfully.'
    $intent=Read-QuestSelectionJson $c.intent $Observation
    [void](Read-QuestSelectionReference $intent.capture_source $Observation)
    Assert-QuestSelection ($intent.no_timeout_or_retry-eq$true) 'Original retry/timeout policy differs.'
    foreach($name in @('stdout','stderr')){
        [void](Read-QuestSelectionReference $c.$name $Observation);$s=$c.streams.$name
        Assert-QuestSelection ($s.eof-eq$true-and$s.raw_capture_complete-eq$true-and$null-eq$s.storage_error-and$null-eq$s.read_error-and(Test-QuestSelectionEqual $s.raw $c.$name)-and$s.drained_bytes-eq$c.$name.bytes-and$s.stored_bytes-eq$c.$name.bytes) 'Original stream lacks complete joined EOF/bytes.'
    }
    [pscustomobject]@{completion=$c;intent=$intent}
}
function Read-QuestSelectionApi($Raw,$Original,$Producer,[string]$Endpoint,$Observation){
    $c=Read-QuestSelectionJson $Original $Observation;[void](Read-QuestSelectionReference $Producer $Observation)
    if($c.PSObject.Properties.Name-ccontains'schema'){
        $closed=Read-QuestSelectionOriginal $Original $Observation
        Assert-QuestSelection ((Test-QuestSelectionEqual $closed.completion.stdout $Raw)-and(Test-QuestSelectionEqual $closed.intent.capture_source $Producer)) 'GET raw/original/producer join differs.'
        $argv=$closed.intent.argv
    }else{
        Assert-MorphospaceExactPropertySet $c @('arguments','pid','started_utc','finished_utc','exit_code','process_reaped','stdout_eof','stderr_eof','automatic_retry','termination_requested','stdout','stderr','intent_sha256','collector_source_sha256') @() 'Retained GET completion'
        Assert-QuestSelection ($c.exit_code-eq0-and$c.process_reaped-eq$true-and$c.stdout_eof-eq$true-and$c.stderr_eof-eq$true-and$c.automatic_retry-eq$false-and$c.termination_requested-eq$false-and$c.collector_source_sha256-ceq$Producer.sha256) 'Retained GET original did not close.'
        $folder=Split-Path -Parent $Original.path;$ir=Get-QuestSelectionReference (Join-Path $folder 'INTENT.json');$intent=Read-QuestSelectionJson $ir $Observation
        Assert-QuestSelection ($ir.sha256-ceq$c.intent_sha256-and$intent.read_only-eq$true-and$intent.automatic_retry-eq$false-and(Test-QuestSelectionEqual $intent.arguments $c.arguments)) 'Retained GET intent/source differs.'
        foreach($name in @('stdout','stderr')){$r=Get-QuestSelectionReference (Join-Path $folder "$name.bin");[void](Read-QuestSelectionReference $r $Observation);Assert-QuestSelection ($r.bytes-eq$c.$name.bytes-and$r.sha256-ceq$c.$name.sha256) 'Retained GET stream differs.'}
        Assert-QuestSelection (Test-QuestSelectionEqual (Get-QuestSelectionReference (Join-Path $folder 'stdout.bin')) $Raw) 'GET raw is not the original stdout.'
        $argv=$c.arguments
    }
    Test-MorphospaceQuestBuildExecutorApiGet $argv $Endpoint
    Read-QuestSelectionJson $Raw $Observation
}
function Test-QuestSelectionDirect($Reference,$Artifacts){@($Artifacts|Where-Object{Test-QuestSelectionEqual $_ $Reference}).Count-eq1}
function Get-QuestSelectionAcceptedBoundary($Request,$Observation){
    $s=$Request.subject;$workspace=Get-QuestSelectionPath $s.workspace -Directory
    $stateRef=Get-QuestSelectionReference (Join-Path $workspace 'workspace.state.json');$state=Read-QuestSelectionJson $stateRef $Observation
    $unitRef=Get-QuestSelectionReference (Resolve-QuestSelectionRelative $workspace "iteration-units/$($s.unit_id).json");$unit=Read-QuestSelectionJson $unitRef $Observation
    Assert-QuestSelection ($unit.project_id-ceq$s.project_id-and$unit.unit_id-ceq$s.unit_id-and$unit.status-ceq'accepted'-and$state.project_id-ceq$s.project_id-and$null-eq$state.current_unit-and$null-eq$state.next_ready_unit) 'Current idle accepted owner boundary is required.'
    $original=Read-QuestSelectionOriginal $Request.accept_original $Observation;$receipt=Read-QuestSelectionJson $Request.accept_receipt $Observation
    Assert-QuestSelection ((Split-Path -Parent ([IO.Path]::GetFullPath($Request.accept_receipt.path)))-ceq(Join-Path $workspace 'receipts')) 'Accept receipt must be in its owner namespace.'
    foreach($pair in @(@('schema','rusty.morphospace.workflow.work_unit_automation_receipt.v1'),@('action','Accept'),@('project_id',$s.project_id),@('unit_id',$s.unit_id),@('transition','validating-to-accepted'),@('status_before','validating'),@('status_after','accepted'),@('current_unit_before',$s.unit_id))){Assert-QuestSelection ($receipt.($pair[0])-ceq$pair[1]) 'Actual public Accept subject/transition differs.'}
    Assert-QuestSelection ($receipt.executed-eq$true-and$null-eq$receipt.current_unit_after-and$state.last_event_id-ceq$receipt.event_id) 'Accept is not the actual current owner tail.'
    $argv=$original.intent.argv
    Assert-QuestSelection ((Get-QuestSelectionArgument $argv '-Action')-ceq'Accept'-and$argv-ccontains'-Execute'-and(Get-QuestSelectionActualArgumentPath $original.intent '-OutPath')-ceq[IO.Path]::GetFullPath($Request.accept_receipt.path)) 'Accept original dispatch/output differs.'
    foreach($ref in $Request.accept_dispatch_sources){[void](Read-QuestSelectionReference $ref $Observation)}
    $dispatch=Get-QuestSelectionActualArgumentPath $original.intent '-File'
    Assert-QuestSelection (@($Request.accept_dispatch_sources|Where-Object{[IO.Path]::GetFullPath($_.path)-ceq$dispatch}).Count-eq1) 'Public Accept dispatcher source is not pinned.'
    $stdout=[Text.UTF8Encoding]::new($false,$true).GetString((Read-QuestSelectionReference $original.completion.stdout $Observation));$payloads=@()
    foreach($match in [regex]::Matches($stdout,'(?m)^\{')){try{$p=ConvertFrom-MorphospaceProtocolJsonBytes ([Text.Encoding]::UTF8.GetBytes($stdout.Substring($match.Index))) 'Accept original payload';$payloads+=,$p}catch{}}
    Assert-QuestSelection ($payloads.Count-eq1-and(Test-QuestSelectionEqual $payloads[0] $receipt)) 'Accept captured payload differs from persisted receipt.'
    $ledgerRef=Get-QuestSelectionReference (Join-Path $workspace 'iteration-events.jsonl');$ledger=Read-QuestSelectionReference $ledgerRef $Observation
    $events=@([Text.UTF8Encoding]::new($false,$true).GetString($ledger).Split("`n")|Where-Object{$_}|ForEach-Object{ConvertFrom-MorphospaceProtocolJsonBytes ([Text.Encoding]::UTF8.GetBytes($_)) 'Owner event'})
    Assert-QuestSelection ($ledger.Length-gt0-and$ledger[-1]-eq10-and$events.Count-gt0-and@($events|Where-Object event_id -ceq $receipt.event_id).Count-eq1) 'Accept ledger is absent, partial or ambiguous.'
    $event=$events[-1];Assert-QuestSelection ($event.event_id-ceq$receipt.event_id-and$event.unit_id-ceq$s.unit_id-and$event.project_id-ceq$s.project_id) 'Accept differs from physical owner tail.'
    $proof=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId "$($event.event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$($s.unit_id).json" -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail
    Assert-QuestSelection ((Test-QuestSelectionEqual $proof.intent.event $event)-and(Test-QuestSelectionEqual $proof.intent.target.unit.document $unit)-and(Test-QuestSelectionEqual $proof.intent.target.state.document $state)) 'Public committed acceptance projections differ.'
    foreach($suffix in @('intent','completion')){[void](Read-QuestSelectionReference (Get-QuestSelectionReference (Join-Path $workspace "receipts/transactions/$($event.event_id)-transition.$suffix.json")) $Observation)}
    $validationRef=Get-QuestSelectionReference (Resolve-QuestSelectionRelative $workspace $state.last_accepted_receipt)
    $validation=Assert-MorphospaceValidationReceiptStructure -ReceiptPath $validationRef.path -AllowedSchemaIds @('rusty.morphospace.workflow.validation_receipt.v1');[void](Read-QuestSelectionReference $validationRef $Observation)
    Assert-QuestSelection (@($event.receipts).Count-eq1-and$event.receipts[0]-ceq$state.last_accepted_receipt-and$validation.project_id-ceq$s.project_id-and$validation.unit_id-ceq$s.unit_id-and$validation.result-ceq'pass'-and$validation.tier-ceq'deep') 'Actual accepted deep validation join differs.'
    Assert-QuestSelection (@($validation.criteria).Count-gt0-and@($validation.gates).Count-gt0-and@(@($validation.criteria)+@($validation.gates)|Where-Object status -cne pass).Count-eq0) 'Accepted criteria/gates are incomplete.'
    $revisions=@($validation.repository_revisions|Where-Object repo_id -ceq $Request.repository_id)
    Assert-QuestSelection ($revisions.Count-eq1-and$revisions[0].head_revision-ceq$Request.candidate_commit) 'Accepted source revision differs.'
    $artifacts=@();$ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($a in $validation.artifacts){Assert-QuestSelection ($ids.Add([string]$a.artifact_id)) 'Accepted artifact identity repeats.';$r=Get-QuestSelectionReference $a.path;Assert-QuestSelection ($r.sha256-ceq$a.sha256) 'Accepted artifact drifted.';[void](Read-QuestSelectionReference $r $Observation);$artifacts+=,$r}
    Assert-QuestSelection ($artifacts.Count-gt0) 'Accepted qualification closure is absent.'
    # Ordinary admission/preparation retains its own baseline, independently of CI base.
    $lockRef=Get-QuestSelectionReference (Resolve-QuestSelectionRelative $workspace $unit.source_composition.lock_path);$lock=Read-QuestSelectionJson $lockRef $Observation
    Assert-QuestSelection ($lock.schema-ceq'rusty.morphospace.workflow.development_envelope_source_composition.v1'-and$lock.status-ceq'locked'-and$lock.project_id-ceq$s.project_id) 'Ordinary source lock differs.'
    $baseline=@($lock.repositories|Where-Object repo_id -ceq $Request.repository_id)
    Assert-QuestSelection ($baseline.Count-eq1-and$baseline[0].commit-ceq$s.preparation_baseline.commit-and$baseline[0].tree-ceq$s.preparation_baseline.tree) 'Preparation baseline must remain distinct from qualification base.'
    $admissions=@()
    foreach($e in $events|Where-Object unit_id -ceq $s.unit_id){foreach($relative in $e.receipts){$r=Get-QuestSelectionReference (Resolve-QuestSelectionRelative $workspace $relative);$d=Read-QuestSelectionJson $r $Observation;if($d.PSObject.Properties.Name-ccontains'schema'-and$d.schema-ceq'rusty.morphospace.workflow.development_unit_admission.v1'){$admissions+=,$d}}}
    Assert-QuestSelection ($admissions.Count-eq1) 'Exactly one ordinary admission is required.';$admission=$admissions[0];$p=$admission.preparation
    Assert-QuestSelection ($admission.project_id-ceq$s.project_id-and$admission.unit_id-ceq$s.unit_id-and$p.preparation_kind-ceq'ordinary'-and$p.preparation_id-ceq$lock.preparation_id-and$p.source_composition_path-ceq$unit.source_composition.lock_path-and$p.source_composition_sha256-ceq$lockRef.sha256) 'Ordinary admission/source lock differs.'
    $preparation=Get-QuestSelectionReference (Resolve-QuestSelectionRelative $workspace $p.receipt_path);Assert-QuestSelection ($preparation.sha256-ceq$p.receipt_sha256) 'Ordinary preparation bytes differ.';[void](Read-QuestSelectionReference $preparation $Observation)
    [pscustomobject]@{receipt=$receipt;original=$original;artifacts=$artifacts;snapshots=@($unitRef,$stateRef,$ledgerRef)}
}

function Test-QuestSelectionLeafJoin($Row,$Receipt){
    Assert-QuestSelection ($Receipt.schema-ceq'rusty.morphospace.workflow.affected_validation_check_evidence.v1'-and$Receipt.result-ceq'pass'-and$Row.result-ceq'pass'-and$Receipt.mode-ceq$Row.mode-and$Receipt.binding.check_id-ceq$Row.check_id-and$Receipt.binding.platform-ceq$Row.platform) 'Selected leaf identity/mode/result differs.'
    Assert-QuestSelection ((Test-QuestSelectionEqual $Row.evidence_source $Receipt.source)-and(Test-QuestSelectionEqual $Row.immediate_reused_from $Receipt.reused_from)) 'Selected reused source/origin was relabelled.'
    $child=$Receipt.child
    Assert-QuestSelection ($child.exit_code-eq0-and$child.timed_out-eq$false-and$child.output_truncated-eq$false-and$child.post_kill_drain_timed_out-eq$false-and$null-eq$child.failure_kind) 'Selected leaf did not close with a genuine pass.'
    if($Row.mode-ceq'executed'){Assert-QuestSelection ($child.started-eq$true-and$null-eq$Receipt.reused_from) 'Executed leaf lacks its actual original.'}
    elseif($Row.mode-ceq'reused'){Assert-QuestSelection ($child.started-eq$false-and$null-ne$Receipt.reused_from-and$Receipt.reused_from.receipt_sha256-cmatch'^[0-9a-f]{64}$'-and(Test-QuestSelectionEqual $Receipt.reused_from.source_head $Receipt.source.head)) 'Reused leaf/origin must retain original source and nonexecution.'}
    else{throw 'Selected leaf mode is not supported.'}
}
function Get-QuestSelectionQualification($Request,$Artifacts,$Observation){
    $q=$Request.qualification;$head=[pscustomobject]@{commit=$Request.candidate_commit;tree=$Request.candidate_tree};$base=$Request.subject.qualification_base
    $keys=@('dynamic_raw','dynamic_original','dynamic_collector','static_raw','static_original','static_collector','protected_assessment','independent_review','dynamic_data_review','dynamic_collection','required_checks','required_checks_original','static_independent_review','public_authorization_proof')
    Assert-MorphospaceExactPropertySet $q $keys @() 'Qualification roles'
    $nested=@('dynamic_collector','static_raw','static_original','static_collector','protected_assessment')
    foreach($key in $keys){[void](Read-QuestSelectionReference $q.$key $Observation);if($key-cnotin$nested){Assert-QuestSelection (Test-QuestSelectionDirect $q.$key $Artifacts) "Qualification role needs a direct accepted root: $key"}}
    Assert-QuestSelection (Test-QuestSelectionEqual $q.dynamic_raw $q.dynamic_data_review) 'Shared hosted report roles must name the same accepted bytes.'
    $report=Read-QuestSelectionJson $q.dynamic_raw $Observation;$root=Split-Path -Parent $q.dynamic_raw.path
    Assert-QuestSelection ($report.schema-ceq'rusty.morphospace.diagnostic.affected_validation_hosted_intake.v1'-and$report.result-ceq'pass'-and$report.hosted_evidence_valid-eq$true-and$report.complete_leaf_union-eq$true-and$report.repository-ceq$Request.repository-and(Test-QuestSelectionEqual $report.head $head)-and(Test-QuestSelectionEqual $report.base $base)) 'Accepted hosted report source/outcome differs.'
    Assert-QuestSelection ($report.run.event-ceq'pull_request'-and$report.run.status-ceq'completed'-and$report.run.conclusion-ceq'success'-and$report.run.id-gt0-and$report.run.attempt-gt0-and$report.run.workflow_id-gt0-and$report.pull_request_number-gt0) 'Accepted actual candidate run is incomplete.'
    $expectedClaims=[pscustomobject]@{current_source_qualified_self_contained_evidence=$true;historical_genesis_reverified=$false;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false;device_used=$false}
    Assert-QuestSelection (Test-QuestSelectionEqual $report.claims $expectedClaims) 'Hosted intake authority limits differ.'
    $outer=Read-QuestSelectionOriginal $q.dynamic_original $Observation;$argv=$outer.intent.argv
    Assert-QuestSelection ((Get-QuestSelectionActualArgumentPath $outer.intent '-File')-ceq[IO.Path]::GetFullPath($q.dynamic_collector.path)-and@($argv|Where-Object{$_-ceq'-CandidateHosted'}).Count-eq1) 'Actual hosted producer entrypoint differs.'
    foreach($pair in @(@('-BeforeCommit',$base.commit),@('-HeadCommit',$head.commit),@('-Repository',$Request.repository),@('-PullRequestNumber',[string]$report.pull_request_number),@('-RunId',[string]$report.run.id))){Assert-QuestSelection ((Get-QuestSelectionArgument $argv $pair[0])-ceq$pair[1]) 'Hosted original source/run/PR differs.'}
    Assert-QuestSelection ((Get-QuestSelectionActualArgumentPath $outer.intent '-OutputDirectory')-ceq$root) 'Hosted original output directory differs.'
    $producerRoot=Get-QuestSelectionActualArgumentPath $outer.intent '-RepositoryRoot'
    Assert-QuestSelection ([IO.Path]::GetFullPath($q.dynamic_collector.path)-ceq(Join-Path $producerRoot 'scripts/Test-AffectedValidationReuse.ps1')) 'Hosted original source root differs.'
    $provider=Get-QuestSelectionReference (Get-QuestSelectionActualArgumentPath $outer.intent '-GhPath');[void](Read-QuestSelectionReference $provider $Observation)
    Assert-QuestSelection ($provider.sha256-ceq$report.producer.provider_executable_sha256-and$report.producer.entrypoint-ceq'scripts/Test-AffectedValidationReuse.ps1'-and$report.producer.commit-ceq$head.commit-and$report.producer.tree-ceq$head.tree) 'Hosted producer/provider source differs.'
    $stdout=Read-QuestSelectionReference $outer.completion.stdout $Observation;$raw=Read-QuestSelectionReference $q.dynamic_raw $Observation
    if((Get-MorphospaceSha256Bytes $stdout)-cne(Get-MorphospaceSha256Bytes $raw)){
        $envelope=ConvertFrom-MorphospaceProtocolJsonBytes $stdout 'Hosted original output'
        Assert-QuestSelection ($envelope.hosted_evidence_valid-eq$true-and$envelope.acceptance_authority-eq$false-and$envelope.publication_authority-eq$false-and[IO.Path]::GetFullPath($envelope.output_directory)-ceq$root-and(Test-QuestSelectionEqual (Read-QuestSelectionRelative $root $envelope.report $Observation) $q.dynamic_raw)) 'Hosted original stdout does not bind accepted report.'
    }
    $manifestRef=Read-QuestSelectionRelative $root $report.raw_manifest $Observation
    Assert-QuestSelection (Test-QuestSelectionEqual $manifestRef $q.dynamic_collection) 'Hosted report/raw manifest join differs.'
    $manifest=Read-QuestSelectionJson $manifestRef $Observation;$rawPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($ref in $manifest.files){Assert-QuestSelection ($rawPaths.Add([string]$ref.path)) 'Hosted raw manifest repeats a path.';[void](Read-QuestSelectionRelative $root $ref $Observation)}
    Assert-QuestSelection ($rawPaths.Count-gt0) 'Hosted raw manifest is empty.'
    $planRef=Read-QuestSelectionRelative $root $report.plan.file $Observation;$plan=Read-QuestSelectionJson $planRef $Observation
    Assert-QuestSelection ((Test-QuestSelectionEqual $plan.base $base)-and(Test-QuestSelectionEqual $plan.head $head)-and$plan.plan_sha256-ceq$report.plan.canonical_sha256-and$plan.execution_permitted-eq$true) 'Hosted exact selected plan differs.'
    $selected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($check in $plan.selected_checks){foreach($platform in $check.platforms){Assert-QuestSelection ($selected.Add("$platform|$($check.check_id)")) 'Selected plan row repeats.'}}
    $rowRoots=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($platform in $report.platforms){foreach($producerRoot in $platform.roots){
        $inventoryRef=Read-QuestSelectionRelative $root $producerRoot.inventory $Observation;$inventory=Read-QuestSelectionJson $inventoryRef $Observation
        Assert-QuestSelection ($inventory.schema-ceq'rusty.morphospace.workflow.affected_validation_check_inventory.v1'-and$inventory.platform-ceq$platform.platform-and$inventory.plan_sha256-ceq$plan.plan_sha256-and(Test-QuestSelectionEqual $inventory.source.head $head)-and(Test-QuestSelectionEqual $producerRoot.producer $inventory.producer)) 'Hosted inventory source/producer differs.'
        foreach($entry in $inventory.entries){$pair="$($platform.platform)|$($entry.check_id)";if(-not$selected.Contains($pair)){continue};$receiptRef=Read-QuestSelectionRelative (Split-Path -Parent $inventoryRef.path) $entry.receipt $Observation;Assert-QuestSelection ($rowRoots.TryAdd($pair,[pscustomobject]@{producer=$inventory.producer;entry=$entry;receipt=$receiptRef})) 'Hosted producer inventories repeat a selected row.'}
    }}
    $observed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$executed=0;$reused=0
    foreach($row in $report.rows){
        $pair="$($row.platform)|$($row.check_id)";Assert-QuestSelection ($selected.Contains($pair)-and$observed.Add($pair)) 'Hosted selected union is foreign or duplicate.'
        $ref=Read-QuestSelectionRelative $root $row.receipt $Observation;$leaf=Read-QuestSelectionJson $ref $Observation
        Test-QuestSelectionLeafJoin $row $leaf
        Assert-QuestSelection ($rowRoots.ContainsKey($pair)) 'Selected leaf has no actual producer inventory.';$owner=$rowRoots[$pair]
        Assert-QuestSelection ((Test-QuestSelectionEqual $owner.receipt $ref)-and$owner.entry.binding_sha256-ceq$leaf.binding_sha256-and$owner.entry.mode-ceq$row.mode-and$owner.entry.result-ceq$row.result-and(Test-QuestSelectionEqual $row.producer $owner.producer)-and$row.producer.repository-ceq$Request.repository-and[string]$row.producer.run_id-ceq[string]$report.run.id-and$row.producer.run_attempt-gt0-and$row.producer.run_attempt-le$report.run.attempt-and$row.producer.pull_request_number-eq$report.pull_request_number) 'Selected producer source/run/attempt differs.'
        if($row.mode-ceq'executed'){Assert-QuestSelection ((Test-QuestSelectionEqual $leaf.source.head $head)-and(Test-QuestSelectionEqual $leaf.source.base $base)) 'Executed leaf source differs.';$executed++}else{$reused++}
        # The accepted current-source report already qualified self-contained reuse;
        # retain the original receipt/source/plan, never replay its historical genesis.
        foreach($name in @('stdout','stderr')){$stream=$leaf.child.$name;$streamRef=Read-QuestSelectionRelative (Split-Path -Parent $ref.path) $stream $Observation;Assert-QuestSelection ($rawPaths.Contains($row.receipt.path.Replace('receipt.json',[string]$stream.path))) 'Leaf stream is not in accepted raw closure.'}
    }
    Assert-QuestSelection ($selected.Count-gt0-and$selected.SetEquals($observed)-and(Test-QuestSelectionEqual $report.counts ([pscustomobject]@{selected_rows=$observed.Count;executed=$executed;reused=$reused}))) 'Hosted exact union/counts differ.'
    $platforms=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($p in $report.platforms){Assert-QuestSelection ($platforms.Add([string]$p.platform)) 'Hosted platform repeats.';[void](Read-QuestSelectionRelative $root $p.aggregate $Observation);if($null-ne$p.selection){[void](Read-QuestSelectionRelative $root $p.selection $Observation)};Assert-QuestSelection (@($p.roots).Count-gt0) 'Hosted producer roots are absent.';foreach($r in $p.roots){Assert-QuestSelection ($r.attempt-gt0-and$r.attempt-le$report.run.attempt) 'Hosted producer attempt is foreign.';[void](Read-QuestSelectionRelative $root $r.payload $Observation);[void](Read-QuestSelectionRelative $root $r.inventory $Observation)}}
    Assert-QuestSelection ($platforms.SetEquals([string[]]@($report.rows.platform|Sort-Object -Unique))) 'Hosted platform coverage differs.'
    $producerRefs=@($report.producer.source_refs|Where-Object path -ceq 'scripts/Test-AffectedValidationReuse.ps1');$collectorBytes=Read-QuestSelectionReference $q.dynamic_collector $Observation
    Assert-QuestSelection ($producerRefs.Count-eq1-and$producerRefs[0].sha256-ceq$q.dynamic_collector.sha256-and$producerRefs[0].bytes-eq$collectorBytes.Length-and$producerRefs[0].git_blob_sha1-ceq(Get-QuestSelectionBlobSha $collectorBytes)) 'Hosted producer is not the accepted exact Git blob.'
    $checks=Read-QuestSelectionOriginal $q.required_checks_original $Observation
    Assert-QuestSelection (Test-QuestSelectionEqual $checks.completion.stdout $q.required_checks) 'Required-check original/raw differs.'
    Assert-QuestSelection ($checks.intent.argv[1]-ceq'pr'-and$checks.intent.argv[2]-ceq'checks'-and$checks.intent.argv[3]-ceq[string]$report.pull_request_number-and$checks.intent.argv-ccontains'--required'-and(Get-QuestSelectionArgument $checks.intent.argv '--repo')-ceq$Request.repository) 'Required checks are not for this exact PR.'
    $values=Read-QuestSelectionJson $q.required_checks $Observation
    Assert-QuestSelection (@($values).Count-gt0-and@($values|Where-Object state -cne SUCCESS).Count-eq0-and@($values|Where-Object name -ceq 'Static admission').Count-eq1) 'All actual required checks must pass.'
    Test-QuestSelectionStatic $Request $report $Observation
    $report
}
function Get-QuestSelectionBlobSha([byte[]]$Bytes){
    $header=[Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0");$all=[byte[]]::new($header.Length+$Bytes.Length);[Array]::Copy($header,0,$all,0,$header.Length);[Array]::Copy($Bytes,0,$all,$header.Length,$Bytes.Length)
    [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($all)).ToLowerInvariant()
}
function Test-QuestSelectionStatic($Request,$Report,$Observation){
    $q=$Request.qualification;$auth=Read-QuestSelectionJson $q.public_authorization_proof $Observation
    $head=[pscustomobject]@{commit=$Request.candidate_commit;tree=$Request.candidate_tree};$base=$Request.subject.qualification_base
    Assert-QuestSelection ($auth.schema-ceq'task.wef018d.actual_protected_static_authentication.v1'-and$auth.repository-ceq$Request.repository-and$auth.pull_request-eq$Report.pull_request_number-and(Test-QuestSelectionEqual $auth.base $base)-and(Test-QuestSelectionEqual $auth.head $head)-and$auth.actual_conclusion-ceq'success'-and$auth.public_signature_verified-eq$true-and$auth.candidate_code_executed-eq$false-and$auth.execution_attested-eq$false-and$auth.acceptance_or_publication_authority-eq$false) 'Accepted protected static source/outcome/limits differ.'
    Assert-QuestSelection ((Test-QuestSelectionEqual $auth.actual_raw_metadata $q.static_raw)-and(Test-QuestSelectionEqual $auth.actual_originals.run $q.static_original)-and(Test-QuestSelectionEqual $auth.actual_assessment $q.protected_assessment)) 'Static role detached from accepted typed proof.'
    $api="repos/$($Request.repository)"
    foreach($kind in @('run','jobs','log')){
        $original=if($kind-ceq'log'){$auth.actual_originals.'job-log'}else{$auth.actual_originals.$kind};$closure=$auth.actual_capture_closures.$kind
        Assert-QuestSelection (Test-QuestSelectionEqual $closure.completion $original) 'Static capture completion edge differs.'
        $closed=Read-QuestSelectionOriginal $original $Observation
        foreach($name in @('intent','stdout','stderr')){Assert-QuestSelection (Test-QuestSelectionEqual $closure.$name $closed.completion.$name) 'Static capture raw edge differs.'}
        Assert-QuestSelection (Test-QuestSelectionEqual $closed.intent.capture_source $q.static_collector) 'Static collector must be the actual capture implementation.'
        $endpoint=switch($kind){run{"$api/actions/runs/$($auth.run_id)"}jobs{"$api/actions/runs/$($auth.run_id)/attempts/$($auth.attempt)/jobs"}log{"$api/actions/jobs/$($auth.actual_job_id)/logs"}}
        Test-MorphospaceQuestBuildExecutorApiGet $closed.intent.argv $endpoint
        if($kind-ceq'run'){Assert-QuestSelection (Test-QuestSelectionEqual $closed.completion.stdout $q.static_raw) 'Static raw run differs.'}
        elseif($kind-ceq'jobs'){Assert-QuestSelection (Test-QuestSelectionEqual $closed.completion.stdout $auth.actual_raw_jobs) 'Static raw jobs differs.'}
        else{Assert-QuestSelection (Test-QuestSelectionEqual $closed.completion.stdout $auth.raw_log) 'Static raw log differs.'}
    }
    $run=Read-QuestSelectionJson $q.static_raw $Observation;$jobs=Read-QuestSelectionJson $auth.actual_raw_jobs $Observation
    Assert-QuestSelection ($run.id-eq$auth.run_id-and$run.run_attempt-eq$auth.attempt-and$run.status-ceq'completed'-and$run.conclusion-ceq'success'-and$run.event-ceq'pull_request_target'-and$run.head_sha-ceq$head.commit-and$jobs.total_count-eq@($jobs.jobs).Count) 'Actual static run/attempt/source is inconsistent.'
    $job=@($jobs.jobs|Where-Object id -eq $auth.actual_job_id)
    Assert-QuestSelection ($job.Count-eq1-and$job[0].run_id-eq$auth.run_id-and$job[0].run_attempt-eq$auth.attempt-and$job[0].head_sha-ceq$head.commit-and$job[0].status-ceq'completed'-and$job[0].conclusion-ceq'success') 'Actual static successful job differs.'
    $assessment=Read-QuestSelectionJson $q.protected_assessment $Observation;$signedRequest=Read-QuestSelectionJson $auth.exact_request $Observation
    Assert-QuestSelection ((Test-QuestSelectionEqual $assessment.base $base)-and(Test-QuestSelectionEqual $assessment.candidate $head)-and$assessment.candidate_code_executed-eq$false-and$assessment.execution_attested-eq$false-and$assessment.publication_authority-eq$false-and$assessment.decision-cin@('approved-change-set','external-owner-authorization')) 'Protected assessment exact source/limits differ.'
    Assert-QuestSelection ((Test-QuestSelectionEqual @($assessment.changed_paths|Sort-Object -CaseSensitive) @($Request.subject.changed_paths|Sort-Object -CaseSensitive))-and(Get-MorphospaceCanonicalJsonSha256 $assessment)-ceq$auth.assessment_canonical_sha256) 'Protected assessment exact paths/canonical hash differs.'
    Assert-QuestSelection ($signedRequest.schema-ceq'rusty.morphospace.workflow.external_owner_authorization_request.v1'-and$signedRequest.repository-ceq$Request.repository-and$signedRequest.pull_request_number-eq$Report.pull_request_number-and(Test-QuestSelectionEqual $signedRequest.base $base)-and(Test-QuestSelectionEqual $signedRequest.head $head)-and(Test-QuestSelectionEqual $signedRequest.assessment $assessment)-and$signedRequest.assessment_sha256-ceq$auth.assessment_canonical_sha256) 'Exact signed request is detached from assessment.'
    # Bind the emitted assessment bytes, stripping only the provider timestamp.
    $log=[Text.Encoding]::UTF8.GetString((Read-QuestSelectionReference $auth.raw_log $Observation));$lines=@($log.Split("`n")|ForEach-Object{if($_-cmatch'^[0-9]{4}-[0-9TZ:.+-]+ (.*)$'){$matches[1].TrimEnd("`r")}});$found=0
    for($i=0;$i-lt$lines.Count;$i++){if($lines[$i]-cne'{'){continue};for($j=$i+1;$j-lt$lines.Count;$j++){if($lines[$j]-cne'}'){continue};try{$text=($lines[$i..$j]-join"`n")+"`n";$parsed=ConvertFrom-MorphospaceProtocolJsonBytes ([Text.Encoding]::UTF8.GetBytes($text)) 'Emitted assessment';if(Test-QuestSelectionEqual $parsed $assessment){Assert-QuestSelection ((Get-MorphospaceSha256Bytes ([Text.Encoding]::UTF8.GetBytes($text)))-ceq$q.protected_assessment.sha256) 'Emitted assessment bytes differ.';$found++}}catch{if($_.Exception.Message-like'Emitted assessment bytes*'){throw}};break}}
    Assert-QuestSelection ($found-eq1) 'Exactly one actual emitted assessment is required.'
}

function Get-QuestSelectionPublication($Request,$Accepted,$Hosted,$Observation){
    $p=$Request.publication;$api="repos/$($Request.repository)";$base=$Request.subject.qualification_base.commit
    Assert-MorphospaceExactPropertySet $p @('pr_number','pr_raw','pr_original','pr_collector','merge_original','postmerge_raw','postmerge_original','postmerge_collector','postmerge_report','postmerge_manifest','postmerge_independent_review') @() 'Publication roles'
    Assert-QuestSelection ($p.pr_number-eq$Hosted.pull_request_number) 'Publication PR differs from accepted qualification.'
    foreach($name in $p.PSObject.Properties.Name|Where-Object{$_-cne'pr_number'}){[void](Read-QuestSelectionReference $p.$name $Observation)}
    $pull=Read-QuestSelectionApi $p.pr_raw $p.pr_original $p.pr_collector "$api/pulls/$($p.pr_number)" $Observation
    Assert-QuestSelection ($pull.number-eq$p.pr_number-and$pull.merged-eq$true-and$pull.merge_commit_sha-ceq$Request.executor_commit-and$pull.head.sha-ceq$Request.candidate_commit-and$pull.base.sha-ceq$base) 'Actual merged PR source differs.'
    $merge=Read-QuestSelectionOriginal $p.merge_original $Observation;$argv=$merge.intent.argv
    Assert-QuestSelection ($argv[1]-ceq'pr'-and$argv[2]-ceq'merge'-and$argv[3]-ceq[string]$p.pr_number-and$argv-ccontains'--merge'-and(Get-QuestSelectionArgument $argv '--match-head-commit')-ceq$Request.candidate_commit-and(Get-QuestSelectionArgument $argv '--repo')-ceq$Request.repository) 'Actual ordinary exact-head merge original differs.'
    $acceptedAt=ConvertFrom-MorphospaceInvariantTimestamp $Accepted.original.completion.finished_utc;$mergeStarted=ConvertFrom-MorphospaceInvariantTimestamp $merge.intent.started_utc;$mergedAt=ConvertFrom-MorphospaceInvariantTimestamp $pull.merged_at
    Assert-QuestSelection ($acceptedAt-le$mergeStarted-and$mergedAt-ge$mergeStarted.AddTicks(-($mergeStarted.Ticks%[TimeSpan]::TicksPerSecond))) 'Actual Accept must finish before ordinary merge.'
    $report=Read-QuestSelectionJson $p.postmerge_report $Observation;$manifest=Read-QuestSelectionJson $p.postmerge_manifest $Observation
    Assert-QuestSelection ($report.schema-cin@('task.actual_accepted_supplier_postmerge_readback.v1','task.wef018d.actual-postmerge-readback.v1')-and$report.merge-ceq$Request.executor_commit-and$report.tree-ceq$Request.candidate_tree-and(Test-QuestSelectionEqual $report.ordered_parents @($base,$Request.candidate_commit))-and$report.conclusion-ceq'success'-and$report.premerge_actual_run-eq$Hosted.run.id) 'Actual independently reviewed postmerge tuple differs.'
    Assert-QuestSelection ((Test-QuestSelectionEqual $report.premerge_data_review $Request.qualification.dynamic_raw)-and(Test-QuestSelectionEqual $report.premerge_manifest $Request.qualification.dynamic_collection)-and(Test-QuestSelectionEqual $report.premerge_independent_review $Request.qualification.independent_review)) 'Postmerge readback detached from accepted qualification.'
    $members=@();foreach($ref in $manifest.files){[void](Read-QuestSelectionReference $ref $Observation);$members+=,$ref}
    Assert-QuestSelection (Test-QuestSelectionDirect $p.postmerge_report $members) 'Postmerge report is absent from actual raw manifest.'
    $run=Read-QuestSelectionApi $p.postmerge_raw $p.postmerge_original $p.postmerge_collector "$api/actions/runs/$($report.run_id)" $Observation
    $branch=$Request.remote_ref.Substring('refs/heads/'.Length)
    Assert-QuestSelection ($run.id-eq$report.run_id-and$run.run_attempt-eq$report.attempt-and$run.head_sha-ceq$Request.executor_commit-and$run.event-ceq'push'-and$run.head_branch-ceq$branch-and$run.path-ceq'.github/workflows/validate.yml'-and$run.status-ceq'completed'-and$run.conclusion-ceq'success'-and(ConvertFrom-MorphospaceInvariantTimestamp $run.created_at)-ge$mergedAt) 'Actual successful published workflow run differs.'
    $folder=Split-Path -Parent $p.postmerge_report.path
    foreach($pair in @(@('jobs',"$api/actions/runs/$($run.id)/jobs?per_page=100"),@('merge-commit',"$api/git/commits/$($Request.executor_commit)"))){
        $raw=Get-QuestSelectionReference (Join-Path $folder "$($pair[0])/stdout.bin");$original=Get-QuestSelectionReference (Join-Path $folder "$($pair[0])/COMPLETION.json")
        Assert-QuestSelection ((Test-QuestSelectionDirect $raw $members)-and(Test-QuestSelectionDirect $original $members)) 'Postmerge typed metadata is outside its manifest.'
        $data=Read-QuestSelectionApi $raw $original $p.postmerge_collector $pair[1] $Observation
        if($pair[0]-ceq'jobs'){$jobs=$data}else{$commit=$data}
    }
    Assert-QuestSelection ($commit.sha-ceq$Request.executor_commit-and$commit.tree.sha-ceq$Request.candidate_tree-and(Test-QuestSelectionEqual @($commit.parents.sha) @($base,$Request.candidate_commit))) 'Published Git commit tree/ordered parents differ.'
    Assert-QuestSelection ($jobs.total_count-eq@($jobs.jobs).Count-and@($jobs.jobs).Count-gt0) 'Actual postmerge job inventory is incomplete.'
    $seen=[Collections.Generic.HashSet[long]]::new();$passed=@();$skipped=@()
    foreach($job in $jobs.jobs){Assert-QuestSelection ($seen.Add([long]$job.id)-and$job.run_id-eq$run.id-and$job.run_attempt-eq$run.run_attempt-and$job.head_sha-ceq$Request.executor_commit-and$job.status-ceq'completed') 'Actual published job source/identity differs.';if($job.conclusion-ceq'success'){$passed+=,[pscustomobject]@{id=$job.id;name=$job.name;conclusion=$job.conclusion}}elseif($job.conclusion-ceq'skipped'){$skipped+=,[pscustomobject]@{id=$job.id;name=$job.name}}else{throw 'Actual postmerge job did not pass or skip.'}}
    Assert-QuestSelection ((Test-QuestSelectionEqual @($passed|Sort-Object id) @($report.actual_executed_jobs|Sort-Object id))-and(Test-QuestSelectionEqual @($skipped|Sort-Object id) @($report.actual_skipped_jobs|Sort-Object id))) 'Postmerge report relabelled actual job outcomes.'
    Assert-QuestSelection ((Test-QuestSelectionEqual @($passed.name|Sort-Object -CaseSensitive) @('infrastructure','post-merge-attestation','select'))-and$report.push_platform_rows-eq$Hosted.counts.selected_rows) 'Supported postmerge attestation branch differs; use the actual normal-delta owner route.'
    $report
}
function Invoke-QuestSelectionGit([string]$Git,[string]$Root,[string[]]$Arguments){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Git;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($a in @('-C',$Root)+$Arguments){[void]$start.ArgumentList.Add($a)}
    foreach($name in @($start.Environment.Keys)){if($name.StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase)){$start.Environment.Remove($name)|Out-Null}}
    $start.Environment['GIT_OPTIONAL_LOCKS']='0';$start.Environment['GIT_TERMINAL_PROMPT']='0'
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$stdout=$null
    try{Assert-QuestSelection ($process.Start()) 'Git observation did not start.';$stdout=[IO.MemoryStream]::new();$copy=$process.StandardOutput.BaseStream.CopyToAsync($stdout);$errorRead=$process.StandardError.ReadToEndAsync();$process.WaitForExit();[void]$copy.GetAwaiter().GetResult();$errorText=$errorRead.GetAwaiter().GetResult();Assert-QuestSelection ($process.ExitCode-eq0) "Git observation failed: $errorText";return ,$stdout.ToArray()}finally{if($null-ne$stdout){$stdout.Dispose()};$process.Dispose()}
}
function Get-QuestSelectionSource($Request,$Hosted,$Observation,[switch]$FreshRemote){
    $root=Get-QuestSelectionPath $Request.executor_root -Directory;[void](Read-QuestSelectionReference $Request.git $Observation);$git=$Request.git.path
    function Read-GitText([string[]]$Arguments){[Text.Encoding]::UTF8.GetString((Invoke-QuestSelectionGit $git $root $Arguments)).TrimEnd("`r","`n")}
    Assert-QuestSelection ((Read-GitText @('rev-parse','HEAD'))-ceq$Request.executor_commit-and(Read-GitText @('rev-parse','HEAD^{tree}'))-ceq$Request.candidate_tree-and(Read-GitText @('status','--porcelain=v1','--untracked-files=all'))-ceq'') 'Selected supplier must be exact and tracked-clean.'
    Assert-QuestSelection ((Read-GitText @('config','--get','remote.origin.url'))-ceq$Request.origin-and(Read-GitText @('rev-parse',"$($Request.candidate_commit)^{tree}"))-ceq$Request.candidate_tree) 'Selected publication origin/candidate tree differs.'
    Assert-QuestSelection ((Read-GitText @('rev-list','--parents','-n','1',$Request.executor_commit))-ceq(@($Request.executor_commit,$Request.subject.qualification_base.commit,$Request.candidate_commit)-join' ')) 'Exact ordered ordinary merge parents are required.'
    Assert-QuestSelection ((Read-GitText @('rev-parse',"$($Request.subject.preparation_baseline.commit)^{tree}"))-ceq$Request.subject.preparation_baseline.tree) 'Actual ordinary preparation baseline tree differs.'
    $paths=[Text.Encoding]::UTF8.GetString((Invoke-QuestSelectionGit $git $root @('diff','--name-only','--no-renames','-z',$Request.subject.qualification_base.commit,$Request.candidate_commit))).Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)
    Assert-QuestSelection (Test-QuestSelectionEqual @($paths|Sort-Object -CaseSensitive) @($Request.subject.changed_paths|Sort-Object -CaseSensitive)) 'Actual candidate change set differs.'
    $rows=@();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $tree=[Text.Encoding]::UTF8.GetString((Invoke-QuestSelectionGit $git $root @('ls-tree','-r','-z','HEAD')))
    foreach($entry in $tree.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)){
        Assert-QuestSelection ($entry-cmatch'^(100644|100755) blob ([0-9a-f]{40})\t(.+)$') 'Only regular source blobs are selectable.'
        $mode=$matches[1];$blob=$matches[2];$path=$matches[3];Assert-QuestSelection ($seen.Add($path)) 'Selected source repeats a path.'
        $absolute=Resolve-QuestSelectionRelative $root $path;$ref=Get-QuestSelectionReference $absolute;$bytes=Read-QuestSelectionReference $ref $Observation
        Assert-QuestSelection ((Get-QuestSelectionBlobSha $bytes)-ceq$blob) 'Selected physical bytes differ from Git blob.'
        $rows+=,[pscustomobject][ordered]@{path=$path;bytes=$ref.bytes;sha256=$ref.sha256;git_blob_sha1=$blob;mode=$mode}
    }
    Assert-QuestSelection ($rows.Count-gt0) 'Selected source tree is empty.'
    if($null-ne$Hosted){$map=@{};foreach($r in $rows){$map[$r.path]=$r};$producerPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($r in $Hosted.producer.source_refs){Assert-QuestSelection ($producerPaths.Add([string]$r.path)-and$map.ContainsKey([string]$r.path)) 'Hosted producer source is duplicate or absent from supplier.';$actual=$map[$r.path];Assert-QuestSelection ($actual.bytes-eq$r.bytes-and$actual.sha256-ceq$r.sha256-and$actual.git_blob_sha1-ceq$r.git_blob_sha1) 'Hosted producer/source Git closure differs.'}}
    $remote=$null;if($FreshRemote){$remote=Read-GitText @('ls-remote','--heads','origin',$Request.remote_ref);Assert-QuestSelection ($remote-ceq($Request.executor_commit+"`t"+$Request.remote_ref)) 'Fresh published remote is not the selected executor.'}
    [pscustomobject]@{root=$root;head=$Request.executor_commit;tree=$Request.candidate_tree;files=$rows;remote=$remote}
}
function Assert-QuestSelectionSourceIdentity([string]$Git,[string]$Root,[string]$Commit,[string]$Tree){
    $head=[Text.Encoding]::UTF8.GetString((Invoke-QuestSelectionGit $Git $Root @('rev-parse','HEAD'))).Trim()
    $actualTree=[Text.Encoding]::UTF8.GetString((Invoke-QuestSelectionGit $Git $Root @('rev-parse','HEAD^{tree}'))).Trim()
    $status=Invoke-QuestSelectionGit $Git $Root @('status','--porcelain=v1','--untracked-files=all')
    Assert-QuestSelection ($head-ceq$Commit-and$actualTree-ceq$Tree-and$status.Length-eq0) 'Selected source Git identity or clean status changed during observation.'
}
function Write-QuestSelectionNewJson([string]$Path,$Value){
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-MorphospaceCanonicalJson $Value)+"`n")
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};Get-QuestSelectionReference $Path
}
function Get-QuestSelectionRetainedProofs($Observation,$Snapshots){
    # Current state/unit/ledger authenticate the fresh selection and remain in
    # Observation for final drift checks. Retained consumers bind their immutable
    # captured bytes instead, so a legitimate successor can advance the owner.
    Assert-QuestSelection (@($Snapshots).Count-eq3) 'Expected three owner projection snapshots.'
    $mapping=[Collections.Generic.Dictionary[string,object]]::new((Get-QuestSelectionPathComparer))
    foreach($snapshot in $Snapshots){$source=[IO.Path]::GetFullPath($snapshot.source_path);Assert-QuestSelection ($Observation.files.ContainsKey($source)-and$mapping.TryAdd($source,$snapshot.snapshot)) 'Projection snapshot source is absent or duplicate.';Assert-QuestSelection ($Observation.files[$source].sha256-ceq$snapshot.snapshot.sha256-and$Observation.files[$source].bytes-eq$snapshot.snapshot.bytes) 'Projection snapshot differs from observed owner bytes.'}
    $proofs=@();foreach($ref in $Observation.files.Values){if($mapping.ContainsKey([IO.Path]::GetFullPath($ref.path))){$proofs+=,$mapping[[IO.Path]::GetFullPath($ref.path)]}else{$proofs+=,$ref}}
    $proofs
}
function New-MorphospaceQuestBuildExecutorSelection {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$ExpectedInputSha256,[Parameter(Mandatory)][string]$OutputDirectory)
    $observation=New-QuestSelectionObservation;$inputRef=Get-QuestSelectionReference $InputPath
    Assert-QuestSelection ($inputRef.sha256-ceq$ExpectedInputSha256) 'Reviewed selection input bytes differ.'
    $request=ConvertFrom-MorphospaceProtocolJsonBytes (Read-QuestSelectionReference $inputRef $observation) 'Selection request';$schemaPath=Join-Path $PSScriptRoot '../../schemas/quest-build-executor-selection-v1.schema.json'
    Assert-QuestSelection (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson $request) -SchemaFile $schemaPath) 'Selection request fails its closed schema.'
    Assert-QuestSelection ($request.schema-ceq'rusty.morphospace.quest_build_executor_selection_request.v1'-and$request.origin-ceq("https://github.com/$($request.repository).git")) 'Selection request repository/origin differs.'
    foreach($path in @($PSCommandPath,$schemaPath,(Join-Path $PSScriptRoot '../New-QuestBuildExecutorSelection.ps1'))){[void](Read-QuestSelectionReference (Get-QuestSelectionReference $path) $observation)}
    # Refuse wrong/currently active authority before Git, remote observation or output.
    $accepted=Get-QuestSelectionAcceptedBoundary $request $observation
    $hosted=Get-QuestSelectionQualification $request $accepted.artifacts $observation
    [void](Get-QuestSelectionPublication $request $accepted $hosted $observation)
    $source=Get-QuestSelectionSource $request $hosted $observation -FreshRemote
    Assert-QuestSelectionObservation $observation
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    Assert-QuestSelection ([IO.Path]::IsPathFullyQualified($OutputDirectory)-and-not(Test-Path -LiteralPath $out)) 'Selection output must be a fresh absolute directory.'
    $parent=Get-QuestSelectionPath (Split-Path -Parent $out) -Directory
    Assert-QuestSelection (@($out.Replace('\','/').Split('/')|Where-Object{$_-cin@('local','artifacts')}).Count-gt0) 'Selection output belongs in local/ or artifacts/ evidence storage.'
    foreach($protected in @($source.root,$request.subject.workspace)){Assert-QuestSelection (-not$out.StartsWith($protected.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Selection output cannot mutate supplier or owner state.'}
    [void][IO.Directory]::CreateDirectory($out)
    $snapshots=@();foreach($ref in $accepted.snapshots){$target=Join-Path $out ('accepted-'+[IO.Path]::GetFileName($ref.path));$bytes=Read-QuestSelectionReference $ref $observation;$stream=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};$snapshots+=,[pscustomobject]@{source_path=$ref.path;snapshot=Get-QuestSelectionReference $target}}
    $pins=Write-QuestSelectionNewJson (Join-Path $out 'EXECUTOR_PINS.json') ([pscustomobject]@{root=$source.root;head=$source.head;tree=$source.tree;files=$source.files})
    $retainedProofs=@(Get-QuestSelectionRetainedProofs $observation $snapshots)
    $accept=Write-QuestSelectionNewJson (Join-Path $out 'ACCEPTANCE_OBSERVATION.json') ([pscustomobject]@{accepted_event=$accepted.receipt.event_id;unit_id=$request.subject.unit_id;snapshots_are_evidence_only=$true;snapshot_sources=$snapshots;producer_contract='rusty.morphospace.quest_build_executor_selection_request.v1';compatibility_wire='task.actual_legacy_executor_selection.v1';proof_files=$retainedProofs})
    $qualified=Write-QuestSelectionNewJson (Join-Path $out 'QUALIFICATION_OBSERVATION.json') ([pscustomobject]@{remote_ref=$request.remote_ref;fresh_remote_observation=$source.remote;accepted_candidate_commit=$request.candidate_commit;accepted_candidate_tree=$request.candidate_tree;proof_files=$retainedProofs})
    $selection=[pscustomobject][ordered]@{schema='task.actual_legacy_executor_selection.v1';selected_utc=[DateTimeOffset]::UtcNow.ToString('o');executor_root=$source.root;executor_commit=$source.head;executor_tree=$source.tree;executor_pins_sha256=$pins.sha256;acceptance_observation_sha256=$accept.sha256;qualification_observation_sha256=$qualified.sha256;actual_acceptance_event=$accepted.receipt.event_id;remote_ref=$request.remote_ref;fresh_remote_observation=$source.remote;current039_tooling_context_created=$false;owner_state_mutated=$false;installed_skills_changed=$false;publication_or_device_authority=$false}
    Assert-QuestSelection (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson $selection) -SchemaFile $schemaPath) 'Selection output fails compatibility schema.'
    Assert-QuestSelectionObservation $observation
    Assert-QuestSelectionSourceIdentity $request.git.path $source.root $source.head $source.tree
    Write-QuestSelectionNewJson (Join-Path $out 'SELECTION.json') $selection
}
function Read-MorphospaceQuestBuildExecutorSelection {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedSha256)
    $observation=New-QuestSelectionObservation;$ref=Get-QuestSelectionReference $Path;Assert-QuestSelection ($ref.sha256-ceq$ExpectedSha256) 'Retained selection hash differs.'
    $selection=Read-QuestSelectionJson $ref $observation
    Assert-QuestSelection (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson $selection) -SchemaFile (Join-Path $PSScriptRoot '../../schemas/quest-build-executor-selection-v1.schema.json')) 'Retained selection closed compatibility wire differs.'
    Assert-QuestSelection ($selection.schema-ceq'task.actual_legacy_executor_selection.v1') 'Expected retained selection, not a producer request.'
    $root=Split-Path -Parent $ref.path;$proofs=@{}
    foreach($pair in @(@('EXECUTOR_PINS.json','executor_pins_sha256'),@('ACCEPTANCE_OBSERVATION.json','acceptance_observation_sha256'),@('QUALIFICATION_OBSERVATION.json','qualification_observation_sha256'))){$p=Get-QuestSelectionReference (Join-Path $root $pair[0]);Assert-QuestSelection ($p.sha256-ceq$selection.($pair[1])) 'Retained selection sibling proof differs.';$proofs[$pair[0]]=Read-QuestSelectionJson $p $observation}
    $pins=$proofs['EXECUTOR_PINS.json'];$accept=$proofs['ACCEPTANCE_OBSERVATION.json'];$qualified=$proofs['QUALIFICATION_OBSERVATION.json']
    Assert-QuestSelection ($accept.accepted_event-ceq$selection.actual_acceptance_event-and$qualified.remote_ref-ceq$selection.remote_ref-and$qualified.fresh_remote_observation-ceq$selection.fresh_remote_observation-and$selection.fresh_remote_observation-ceq($selection.executor_commit+"`t"+$selection.remote_ref)-and$pins.head-ceq$selection.executor_commit-and$pins.tree-ceq$selection.executor_tree-and[IO.Path]::GetFullPath($pins.root)-ceq[IO.Path]::GetFullPath($selection.executor_root)) 'Retained acceptance/source/remote joins differ.'
    foreach($proof in @($accept.proof_files)+@($qualified.proof_files)){[void](Read-QuestSelectionReference $proof $observation)}
    Assert-QuestSelection ($accept.snapshots_are_evidence_only-eq$true-and@($accept.snapshot_sources).Count-eq3) 'Retained owner snapshots must remain evidence only.'
    $snapshotSources=[Collections.Generic.HashSet[string]]::new((Get-QuestSelectionPathComparer));$stateSnapshot=$null;$unitSnapshot=$null;$eventsSnapshot=$null
    foreach($snapshot in $accept.snapshot_sources){
        Assert-QuestSelection ($snapshotSources.Add([IO.Path]::GetFullPath($snapshot.source_path))-and(Test-QuestSelectionDirect $snapshot.snapshot @($accept.proof_files))) 'Retained owner snapshot is duplicate or absent from proof closure.'
        $name=[IO.Path]::GetFileName($snapshot.source_path)
        if($name-ceq'workspace.state.json'){$stateSnapshot=Read-QuestSelectionJson $snapshot.snapshot $observation}
        elseif($name-ceq'iteration-events.jsonl'){$eventsBytes=Read-QuestSelectionReference $snapshot.snapshot $observation;$last=@([Text.Encoding]::UTF8.GetString($eventsBytes).Split("`n")|Where-Object{$_})[-1];$eventsSnapshot=$last|ConvertFrom-Json -Depth 100 -DateKind String}
        else{$unitSnapshot=Read-QuestSelectionJson $snapshot.snapshot $observation}
    }
    Assert-QuestSelection ($null-ne$stateSnapshot-and$null-ne$unitSnapshot-and$null-ne$eventsSnapshot-and$stateSnapshot.last_event_id-ceq$selection.actual_acceptance_event-and$unitSnapshot.unit_id-ceq$accept.unit_id-and$unitSnapshot.status-ceq'accepted'-and$eventsSnapshot.event_id-ceq$selection.actual_acceptance_event-and$eventsSnapshot.unit_id-ceq$accept.unit_id) 'Retained owner snapshot acceptance joins differ.'
    # Consumer readback verifies the whole clean Git closure, without new remote
    # access, current acceptance relabelling, tooling adoption or build execution.
    $git=@(Get-Command git -CommandType Application -ErrorAction Stop)[0];$supplier=Get-QuestSelectionPath $selection.executor_root -Directory
    $head=[Text.Encoding]::UTF8.GetString((Invoke-QuestSelectionGit $git.Source $supplier @('rev-parse','HEAD'))).Trim();$tree=[Text.Encoding]::UTF8.GetString((Invoke-QuestSelectionGit $git.Source $supplier @('rev-parse','HEAD^{tree}'))).Trim();$status=Invoke-QuestSelectionGit $git.Source $supplier @('status','--porcelain=v1','--untracked-files=all')
    Assert-QuestSelection ($head-ceq$pins.head-and$tree-ceq$pins.tree-and$status.Length-eq0) 'Retained supplier source moved or is dirty.'
    $lines=[Text.Encoding]::UTF8.GetString((Invoke-QuestSelectionGit $git.Source $supplier @('ls-tree','-r','-z','HEAD'))).Split([char]0,[StringSplitOptions]::RemoveEmptyEntries);$map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($r in $pins.files){Assert-QuestSelection ($map.TryAdd([string]$r.path,$r)) 'Retained source pins repeat a path.'}
    Assert-QuestSelection ($map.Count-eq$lines.Count) 'Retained source pins omit/add Git files.'
    foreach($entry in $lines){Assert-QuestSelection ($entry-cmatch'^(100644|100755) blob ([0-9a-f]{40})\t(.+)$') 'Retained source is not a regular Git blob.';$mode=$matches[1];$blob=$matches[2];$relative=$matches[3];Assert-QuestSelection ($map.ContainsKey($relative)) 'Retained source path absent.';$r=$map[$relative];$actual=Get-QuestSelectionReference (Resolve-QuestSelectionRelative $supplier $relative);$bytes=Read-QuestSelectionReference $actual $observation;Assert-QuestSelection ($r.mode-ceq$mode-and$r.git_blob_sha1-ceq$blob-and(Get-QuestSelectionBlobSha $bytes)-ceq$blob-and$r.sha256-ceq$actual.sha256-and$r.bytes-eq$actual.bytes) 'Retained physical/Git source closure differs.'}
    Assert-QuestSelectionObservation $observation
    Assert-QuestSelectionSourceIdentity $git.Source $supplier $pins.head $pins.tree
    [pscustomobject]@{selection=$selection;source=$pins;acceptance=$accept;qualification=$qualified;build_runner=(Join-Path $supplier 'scripts/Invoke-QuestBuildProfile.ps1');tooling_context_created=$false;publication_or_device_authority=$false}
}
Export-ModuleMember -Function New-MorphospaceQuestBuildExecutorSelection,Read-MorphospaceQuestBuildExecutorSelection,Test-MorphospaceQuestBuildExecutorApiGet
