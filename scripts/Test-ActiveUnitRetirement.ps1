param([switch]$SelfTest,[switch]$InertProposalsOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if(-not$SelfTest){throw 'Test-ActiveUnitRetirement requires -SelfTest.'}
$repository=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementContinuation.ps1')
. (Join-Path $PSScriptRoot 'test-support/ActiveUnitRetirementFixture.ps1')
Import-Module (Join-Path $PSScriptRoot 'ActiveUnitRetirement.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
function Assert-RetirementTest([bool]$Value,[string]$Message){if(-not$Value){throw "Active retirement test: $Message"}}
function Get-RetirementInventory([string]$Workspace){
    $rows=@(Get-ChildItem -LiteralPath $Workspace -Recurse -File|Sort-Object FullName|ForEach-Object{[pscustomobject]@{path=[IO.Path]::GetRelativePath($Workspace,$_.FullName).Replace('\','/');sha256=Get-MorphospaceFileSha256 $_.FullName}})
    Get-MorphospaceCanonicalJsonSha256 $rows
}
function Write-RetirementRequest([string]$Workspace,[object]$Request){Write-EnvelopeJson ($Workspace+'.request.json') $Request}
function Invoke-RetirementTest([string]$Workspace,[bool]$Execute=$true,[string]$FaultAfter='none',[string]$RepoMapPath=''){
    $requestPath=$Workspace+'.request.json'
    if(-not$RepoMapPath){$RepoMapPath=Join-Path $Workspace 'repository-map.json'}
    Invoke-MorphospaceRetireActive -WorkspaceRoot $Workspace -UnitId u002 -RepoMapPath $RepoMapPath -ActiveUnitRetirement $requestPath -ExpectedActiveUnitRetirementSha256 (Get-MorphospaceFileSha256 $requestPath) -OutPath (Join-Path $Workspace 'receipts/retire-u002.json') -Timestamp '2026-08-25T00:00:43.0000000Z' -Execute:$Execute -FaultAfter $FaultAfter
}
function Assert-RetirementRejects([string]$Workspace,[string]$Label,[string]$Pattern='*'){
    $before=Get-RetirementInventory $Workspace;$message='';$rejected=$false
    try{Invoke-RetirementTest $Workspace|Out-Null}catch{$rejected=$true;$message=$_.Exception.Message}
    Assert-RetirementTest ($rejected-and$message-like$Pattern) "$Label was not rejected: $message"
    Assert-RetirementTest ((Get-RetirementInventory $Workspace)-ceq$before) "$Label mutated workspace bytes"
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-active-retirement-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
try{
    $seed=New-ActiveRetirementContinuationSeed -Root (Join-Path $temp 'seed') -RepositoryRoot $repository
    $template=$seed.workspace
    $request=New-ActiveUnitRetirementRequest -WorkspaceRoot $template
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
    Write-RetirementRequest $template $request
    $requestSchema=Join-Path $repository 'schemas/active-unit-retirement-v1.schema.json'
    Assert-RetirementTest (Test-Json -Json ($request|ConvertTo-Json -Depth 100) -SchemaFile $requestSchema) 'exact request schema'
    function Copy-RetirementWorkspace([string]$Name){$path=Join-Path $temp $Name;Copy-Item -LiteralPath $template -Destination $path -Recurse;Write-RetirementRequest $path $request;return $path}
    # Authentic Prepare/Admit/Ready/Claim authority may coexist with an unrelated
    # never-admitted draft. It grants no ownership and must survive retirement.
    $draft=$seed.u002|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
    $draft.unit_id='u015';$draft.status='proposed'
    foreach($name in @($draft.PSObject.Properties.Name|Where-Object{$_-match'admission|preparation|^candidate_freeze$|^inherited_candidate'})){$draft.PSObject.Properties.Remove($name)}
    $inert=Copy-RetirementWorkspace 'inert-draft'
    $draftPath=Join-Path $inert 'iteration-units/u015.json';Write-EnvelopeJson $draftPath $draft
    $draftHash=Get-MorphospaceFileSha256 $draftPath;$before=Get-RetirementInventory $inert
    $null=Invoke-RetirementTest $inert $false
    Assert-RetirementTest ((Get-RetirementInventory $inert)-ceq$before) 'inert-draft dry run wrote bytes'
    $done=Invoke-RetirementTest $inert
    Assert-RetirementTest ($done.executed-and$null-eq$done.current_unit_after-and(Get-MorphospaceFileSha256 $draftPath)-ceq$draftHash) 'inert draft was rejected or rewritten'
    foreach($kind in @('admitted','ready','active','validating','prerequisite','queued','receipt-reference','named-replacement')){
        $workspace=Copy-RetirementWorkspace "draft-$kind"
        $proposal=$draft|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String
        if($kind-ceq'admitted'){$proposal|Add-Member -NotePropertyName admission -NotePropertyValue ([pscustomobject]@{admission_id='u015-admission'})}
        if(@('ready','active','validating')-ccontains$kind){$proposal.status=$kind}
        Write-EnvelopeJson (Join-Path $workspace 'iteration-units/u015.json') $proposal
        if($kind-ceq'prerequisite'){
            $dependent=$draft|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$dependent.unit_id='u016';$dependent.prerequisites=@('u015')
            Write-EnvelopeJson (Join-Path $workspace 'iteration-units/u016.json') $dependent
        }
        if($kind-ceq'queued'){
            $state=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json');$state.next_ready_unit='u015';Write-EnvelopeJson (Join-Path $workspace 'workspace.state.json') $state
            $bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.expected.state_raw_sha256=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json');$bad.expected.state_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $state;Write-RetirementRequest $workspace $bad
        }
        if($kind-ceq'receipt-reference'){Write-EnvelopeJson (Join-Path $workspace 'receipts/u015-observation.json') ([ordered]@{unit_id='u015'})}
        if($kind-ceq'named-replacement'){$bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.replacement_unit_id='u015';Write-RetirementRequest $workspace $bad}
        Assert-RetirementRejects $workspace "non-inert $kind proposal"
    }
    if($InertProposalsOnly){[pscustomobject]@{status='pass';check='active-unit-retirement-inert-proposals';negative_cases=8;inert_draft_bytes_preserved=$true}|ConvertTo-Json -Compress;return}
    $success=Copy-RetirementWorkspace 'success';$before=Get-RetirementInventory $success
    $dry=Invoke-RetirementTest $success $false
    Assert-RetirementTest (-not$dry.executed-and$dry.current_unit_after-ceq'u002') 'dry observation grants no idle ownership'
    Assert-RetirementTest ((Get-RetirementInventory $success)-ceq$before) 'dry observation wrote files'
    $preserved=@{};foreach($file in @(Get-ChildItem -LiteralPath $success -Recurse -File)){$relative=[IO.Path]::GetRelativePath($success,$file.FullName).Replace('\','/');$preserved[$relative]=[IO.File]::ReadAllBytes($file.FullName)}
    $done=Invoke-RetirementTest $success
    Assert-RetirementTest ($done.executed-and$null-eq$done.current_unit_after-and$done.status_after-ceq'active') 'nonaccepting active-to-idle result'
    $state=Read-MorphospaceProtocolJson (Join-Path $success 'workspace.state.json')
    Assert-RetirementTest ($null-eq$state.current_unit-and$state.last_event_id-ceq'retire-u002-active-retired') 'idle target'
    foreach($relative in $preserved.Keys){
        $bytes=[IO.File]::ReadAllBytes((Join-Path $success $relative))
        if($relative-ceq'workspace.state.json'){continue}
        if($relative-ceq'iteration-events.jsonl'){$prefix=[byte[]]::new($preserved[$relative].Length);[Array]::Copy($bytes,$prefix,$prefix.Length);$bytes=$prefix}
        Assert-RetirementTest ((Get-MorphospaceSha256Bytes $bytes)-ceq(Get-MorphospaceSha256Bytes $preserved[$relative])) "preserved $relative"
    }
    $event=Get-Content -LiteralPath (Join-Path $success 'iteration-events.jsonl')|Select-Object -Last 1|ConvertFrom-Json -DateKind String
    $proof=Test-MorphospaceHistoricalActiveUnitRetirement -WorkspaceRoot $success -ExpectedEvent $event
    Assert-RetirementTest ($proof.receipt.replacement_unit_id-ceq'u003'-and-not$proof.receipt.accepted) 'authenticated named replacement lineage'
    $post=Get-RetirementInventory $success;Invoke-RetirementTest $success|Out-Null
    Assert-RetirementTest ((Get-RetirementInventory $success)-ceq$post) 'completed replay changed bytes'
    foreach($phase in @('after-intent','after-artifact','after-projection','after-event')){
        $workspace=Copy-RetirementWorkspace "fault-$phase";$interrupted=$false
        try{Invoke-RetirementTest $workspace $true $phase|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption*'}
        Assert-RetirementTest $interrupted "fault $phase not reached"
        Invoke-RetirementTest $workspace|Out-Null
        Assert-RetirementTest ($null-eq(Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')).current_unit) "fault $phase did not resume"
    }
    foreach($field in @('project_raw_sha256','feature_lock_raw_sha256','state_raw_sha256','events_sha256','repository_map_sha256')){
        $workspace=Copy-RetirementWorkspace "bad-$field";$bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.expected.$field='0'*64;Write-RetirementRequest $workspace $bad
        Assert-RetirementRejects $workspace $field
    }
    $workspace=Copy-RetirementWorkspace 'same-replacement';$bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.replacement_unit_id='u002';Write-RetirementRequest $workspace $bad;Assert-RetirementRejects $workspace 'same replacement'
    $workspace=Copy-RetirementWorkspace 'occupied-replacement';Copy-Item -LiteralPath (Join-Path $workspace 'iteration-units/u002.json') -Destination (Join-Path $workspace 'iteration-units/u003.json');Assert-RetirementRejects $workspace 'occupied replacement'
    foreach($field in @('next_ready_unit','pending_push_bundle','normal_validation_selection')){
        $workspace=Copy-RetirementWorkspace "conflict-$field";$state=Read-MorphospaceProtocolJson (Join-Path $workspace 'workspace.state.json')
        $value=if($field-ceq'next_ready_unit'){'u099'}elseif($field-ceq'pending_push_bundle'){[pscustomobject]@{bundle_id='pending';unit_ids=@('u002');repo_ids=@('fixture-source');ready=$true}}else{[pscustomobject]@{selector_id='pending'}}
        $state|Add-Member -NotePropertyName $field -NotePropertyValue $value -Force;Write-EnvelopeJson (Join-Path $workspace 'workspace.state.json') $state
        $bad=$request|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$bad.expected.state_raw_sha256=Get-MorphospaceFileSha256 (Join-Path $workspace 'workspace.state.json');$bad.expected.state_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 $state;Write-RetirementRequest $workspace $bad
        Assert-RetirementRejects $workspace $field
    }
    $workspace=Copy-RetirementWorkspace 'claim-damage';$path=Join-Path $workspace "receipts/transactions/$($request.claim.transaction_id).completion.json";[IO.File]::AppendAllText($path,' ');Assert-RetirementRejects $workspace 'Claim completion raw drift'
    $workspace=Copy-RetirementWorkspace 'intent-damage';try{Invoke-RetirementTest $workspace $true 'after-intent'|Out-Null}catch{}
    $intentPath=Join-Path $workspace 'receipts/transactions/retire-u002-active-retired-transition.intent.json';$intent=Read-MorphospaceProtocolJson $intentPath;$intent.target.state.document.plan_revision++;Write-EnvelopeJson $intentPath $intent
    Assert-RetirementRejects $workspace 'interrupted target damage'
    $workspace=Copy-RetirementWorkspace 'raw-unit-damage';[IO.File]::AppendAllText((Join-Path $workspace 'iteration-units/u002.json'),' ');Assert-RetirementRejects $workspace 'active raw unit drift'
    $sourceMap=Read-MorphospaceProtocolJson (Join-Path $template 'repository-map.json');$sourcePath=[string]@($sourceMap.repositories|Where-Object{[string]$_.repo_id-ceq[string]$request.repositories[0].repo_id})[0].path
    $dirtyPath=Join-Path $sourcePath 'unowned-retirement-test.txt';[IO.File]::WriteAllText($dirtyPath,'unowned')
    try{$workspace=Copy-RetirementWorkspace 'dirty-source';Assert-RetirementRejects $workspace 'untracked source dirt' '*clean available source*'}finally{[IO.File]::Delete($dirtyPath)}
    # A real planning-role source contains the workspace. The external input must not
    # dirty its observed checkpoint, and only the interrupted owner's files may resume.
    $planning=Join-Path $temp 'in-place-planning'
    $sourceMap=Read-MorphospaceProtocolJson (Join-Path $template 'repository-map.json')
    $planningRow=@($sourceMap.repositories|Where-Object{[string]$_.role-ceq'planning'})[0]
    Invoke-EnvelopeGit $temp @('clone','--no-hardlinks',[string]$planningRow.path,$planning)|Out-Null
    Invoke-EnvelopeGit $planning @('config','user.name','Retirement Fixture')|Out-Null
    Invoke-EnvelopeGit $planning @('config','user.email','fixture@example.invalid')|Out-Null
    $inPlace=Join-Path $planning 'morphospace';[IO.Directory]::CreateDirectory($inPlace)|Out-Null
    foreach($entry in @(Get-ChildItem -LiteralPath $template -Force)){Copy-Item -LiteralPath $entry.FullName -Destination $inPlace -Recurse -Force}
    Invoke-EnvelopeGit $planning @('add','morphospace')|Out-Null
    Invoke-EnvelopeGit $planning @('commit','-m','clean planning checkpoint')|Out-Null
    $planningRow.path=$planning;$externalMap=Join-Path $temp 'in-place-map.json';Write-EnvelopeJson $externalMap $sourceMap
    $inPlaceRequest=New-ActiveUnitRetirementRequest -WorkspaceRoot $inPlace -RepoMapPath $externalMap
    # Place input outside the Git repository as well as outside the workspace.
    $externalInput=Join-Path $temp 'in-place-request.json';Write-EnvelopeJson $externalInput $inPlaceRequest
    $invoke=@{WorkspaceRoot=$inPlace;UnitId='u002';RepoMapPath=$externalMap;ActiveUnitRetirement=$externalInput;ExpectedActiveUnitRetirementSha256=Get-MorphospaceFileSha256 $externalInput;OutPath=(Join-Path $inPlace 'receipts/retire-u002.json');Timestamp='2026-08-25T00:00:43.0000000Z'}
    $initialHead=(@(& git -C $planning rev-parse HEAD)-join'').Trim()
    $null=Invoke-MorphospaceRetireActive @invoke
    Assert-RetirementTest (@(& git -C $planning status --porcelain=v1 --untracked-files=all).Count-eq0) 'external dry request dirtied planning checkout'
    $interrupted=$false;try{Invoke-MorphospaceRetireActive @invoke -Execute -FaultAfter after-projection|Out-Null}catch{$interrupted=$_.Exception.Message-like'*Injected interruption*'}
    Assert-RetirementTest $interrupted 'in-place planning fault not reached'
    $unowned=Join-Path $planning 'unowned.txt';[IO.File]::WriteAllText($unowned,'unowned')
    try{
        $rejected=$false;try{Invoke-MorphospaceRetireActive @invoke -Execute|Out-Null}catch{$rejected=$_.Exception.Message-like'*clean available source*'}
        Assert-RetirementTest $rejected 'in-place recovery accepted unrelated dirt'
    }finally{[IO.File]::Delete($unowned)}
    $null=Invoke-MorphospaceRetireActive @invoke -Execute
    Assert-RetirementTest ((@(& git -C $planning rev-parse HEAD)-join'').Trim()-ceq$initialHead) 'retirement changed planning Git checkpoint'
    Assert-RetirementTest ((Get-MorphospaceFileSha256 (Join-Path $inPlace 'receipts/retire-u002-request.json'))-ceq(Get-MorphospaceFileSha256 $externalInput)) 'retained external request bytes differ'
    [pscustomobject]@{status='pass';check='active-unit-retirement';fault_boundaries=4;old_unit_and_prior_evidence_bytes_preserved=$true;source_mutation_performed=$false}|ConvertTo-Json -Compress
}finally{
    # The entire target is a unique fixture directory generated above.
    $resolved=[IO.Path]::GetFullPath($temp);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)-or-not[IO.Path]::GetFileName($resolved).StartsWith('morphospace-active-retirement-')){throw 'Unsafe fixture cleanup target.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
