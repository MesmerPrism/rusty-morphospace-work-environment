param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ExecutorRoot,[Parameter(Mandatory)][string]$PreparationTemplatePath,[Parameter(Mandatory)][string]$AdmissionTemplatePath,[Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($WorkspaceRoot);$fixture=[IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
if(-not$workspace.StartsWith($fixture,[StringComparison]::OrdinalIgnoreCase)){throw 'The retirement continuation fixture must remain under its explicit disposable root.'}
$protocolModule=Import-Module (Join-Path $ExecutorRoot 'scripts/lib/MorphospaceProtocolCommon.psm1') -PassThru
. (Join-Path $ExecutorRoot 'scripts/test-support/DevelopmentAdmissionFixture.ps1')
. (Join-Path $ExecutorRoot 'scripts/test-support/ActiveUnitRetirementFixture.ps1')
$state=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')
if([string]$state.project_id-cne'envelope-test'-or[string]$state.current_unit-cne'u002'){throw 'The retirement continuation fixture refuses non-fixture owner state.'}
$unit=Read-EnvelopeProtocolJson (Join-Path $workspace 'iteration-units/u002.json');$recovery=Read-EnvelopeProtocolJson (Join-Path $workspace ([string]$unit.candidate_freeze.receipt_path))
if([string]$recovery.schema-cne'rusty.morphospace.workflow.candidate_freeze.v4'){throw 'The retirement continuation fixture requires a genuine committed v4.'}
$retirement=Import-Module (Join-Path $ExecutorRoot 'scripts/ActiveUnitRetirement.psm1') -PassThru
$request=New-ActiveUnitRetirementRequest -WorkspaceRoot $workspace -RetirementId 'nonpass-fixture-retirement' -ReplacementUnitId 'u003'
$input=Join-Path $FixtureRoot ('retirement-input-'+[guid]::NewGuid().ToString('N')+'.json');Write-EnvelopeJson $input $request
$out=Join-Path $workspace 'receipts/nonpass-fixture-retirement.json'
&$retirement {param($a)Invoke-MorphospaceRetireActive @a} @{WorkspaceRoot=$workspace;UnitId='u002';RepoMapPath=(Join-Path $workspace 'repository-map.json');ActiveUnitRetirement=$input;ExpectedActiveUnitRetirementSha256=(Get-EnvelopeFileSha256 $input);OutPath=$out;Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');Execute=$true}|Out-Null
$idle=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')
Assert-Envelope ($null-eq$idle.current_unit-and$null-eq$idle.next_ready_unit-and[string]$idle.last_accepted_receipt-ceq[string]$state.last_accepted_receipt) 'post-v4 retirement changed the accepted checkpoint or retained ownership'
$preparation=Read-EnvelopeProtocolJson $PreparationTemplatePath
$preparation.preparation_id='u003-fresh-envelope'
$project=Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json');$lock=Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json')
$preparation.envelope.project=Copy-Envelope $project;$preparation.envelope.project.revision=[int]$project.revision+1
$preparation.envelope.feature_lock=Copy-Envelope $lock;$preparation.envelope.feature_lock.project_revision=$preparation.envelope.project.revision;$preparation.envelope.feature_lock.revision=[int]$lock.revision+1;$preparation.envelope.feature_lock.generated_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');$preparation.envelope.feature_lock.lock_fingerprint=Get-EnvelopeLockFingerprint $preparation.envelope.feature_lock
$preparation.envelope.source_composition.path='source-compositions/u003-fresh-envelope.json'
$events=Join-Path $workspace 'iteration-events.jsonl'
foreach($pair in @(@('project_sha256',$project),@('state_sha256',$idle),@('feature_lock_sha256',$lock))){$preparation.expected.($pair[0])=Get-EnvelopeCanonicalJsonSha256 $pair[1]}
$preparation.expected.events_sha256=Get-EnvelopeFileSha256 $events;$preparation.expected.events_length=([IO.FileInfo]$events).Length;$preparation.expected.event_tail_id=[string]$idle.last_event_id
$preparationPath=Join-Path $FixtureRoot ('fresh-preparation-'+[guid]::NewGuid().ToString('N')+'.json');Write-EnvelopeJson $preparationPath $preparation
$preparationOut=Join-Path $workspace 'receipts/u003-fresh-envelope.json'
$prepare=Import-Module (Join-Path $ExecutorRoot 'scripts/DevelopmentEnvelopePreparation.psm1') -PassThru
&$prepare {param($a)Invoke-MorphospacePrepareDevelopmentEnvelope @a} @{WorkspaceRoot=$workspace;DevelopmentEnvelopePreparation=$preparationPath;ExpectedDevelopmentEnvelopePreparationSha256=(Get-EnvelopeFileSha256 $preparationPath);OutPath=$preparationOut;Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');Execute=$true}|Out-Null
$prepared=Read-EnvelopeProtocolJson $preparationOut;$after=Read-EnvelopeProtocolJson (Join-Path $workspace 'workspace.state.json')
$admission=Read-EnvelopeProtocolJson $AdmissionTemplatePath
$admission.admission_id='u003-fresh-admission';$admission.unit_id='u003';$admission.unit.unit_id='u003';$admission.unit.status='proposed';$admission.unit.objective='Continue ordinary ownership after explicit nonaccepting v4 retirement.';$admission.unit.source_composition.lock_path=[string]$prepared.source_composition.path
$admission.preparation.preparation_id='u003-fresh-envelope';$admission.preparation.receipt_path='receipts/u003-fresh-envelope.json';$admission.preparation.receipt_sha256=Get-EnvelopeFileSha256 $preparationOut;$admission.preparation.source_composition_path=[string]$prepared.source_composition.path;$admission.preparation.source_composition_sha256=Get-EnvelopeFileSha256 (Join-Path $workspace ([string]$prepared.source_composition.path))
$admission.expected.project_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'project.spec.json'));$admission.expected.state_sha256=Get-EnvelopeCanonicalJsonSha256 $after;$admission.expected.feature_lock_sha256=Get-EnvelopeCanonicalJsonSha256 (Read-EnvelopeProtocolJson (Join-Path $workspace 'feature.lock.json'));$admission.expected.source_composition_path=[string]$prepared.source_composition.path;$admission.expected.source_composition_sha256=$admission.preparation.source_composition_sha256;$admission.expected.events_sha256=Get-EnvelopeFileSha256 $events;$admission.expected.events_length=([IO.FileInfo]$events).Length;$admission.expected.event_tail_id=[string]$after.last_event_id
$admissionPath=Join-Path $FixtureRoot ('fresh-admission-'+[guid]::NewGuid().ToString('N')+'.json');Write-EnvelopeJson $admissionPath $admission
$admit=Import-Module (Join-Path $ExecutorRoot 'scripts/DevelopmentUnitAdmission.psm1') -PassThru
&$admit {param($a)Invoke-MorphospaceAdmitDevelopmentUnit @a} @{WorkspaceRoot=$workspace;DevelopmentUnitAdmission=$admissionPath;ExpectedDevelopmentUnitAdmissionSha256=(Get-EnvelopeFileSha256 $admissionPath);OutPath=(Join-Path $workspace 'receipts/u003-fresh-admission.json');Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');Execute=$true}|Out-Null
$automation=Import-Module (Join-Path $ExecutorRoot 'scripts/WorkUnitAutomation.psm1') -PassThru
foreach($action in @('Ready','Claim')){&$automation {param($a)Invoke-MorphospaceWorkUnitAutomation @a} @{Action=$action;WorkspaceRoot=$workspace;UnitId='u003';RepoMapPath=(Join-Path $workspace 'repository-map.json');Timestamp=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');Execute=$true}|Out-Null}
$history=Import-Module (Join-Path $ExecutorRoot 'scripts/lib/MorphospaceCurrentWorkHistory.psm1') -PassThru
$read=&$history {param($w)Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $w} $workspace
Assert-Envelope ($read.retired_active_ids.Contains('u002')-and[string]$read.units.u003.status-ceq'active') 'mandatory current-work reader lost retirement or fresh ownership'
Assert-Envelope (@($read.audit_only|Where-Object classification -CEQ 'nonpass-audit-inert-unavailable').Count-ge2) 'fresh ownership lost its exact audit-only custody dispositions'
Write-Host 'PASS genuine v4 -> RetireActive -> fresh Prepare/Admit/Ready/Claim and mandatory current-work reader; no old acceptance or resurrection.'
