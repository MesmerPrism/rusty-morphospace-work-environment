[CmdletBinding()]
param([switch]$ProofMeasurementOnly,[switch]$ProvenanceIntentReuseOnly)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -Force
$protocolModule = Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$compatibilityModule = Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkCompatibility.psm1') -Force -PassThru
$repreparationModule = Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeRepreparation.psm1') -PassThru
$automationModule = Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force -PassThru
$transitionLedgerModule = Get-Module -All | Where-Object { $_.Path -eq (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') } | Select-Object -Last 1
. (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wef-current-work-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$passed = 0
function Invoke-ActualValidator([string]$OwnerRoot, [string]$Workspace, [bool]$LiveOnly) {
    $arguments = @('-NoProfile','-File',(Join-Path $OwnerRoot 'scripts/Test-WorkflowContracts.ps1'),'-RepoRoot',$OwnerRoot,'-SkipOwnerSelfTests')
    if ($Workspace) { $arguments += @('-WorkspaceRoot',$Workspace,'-RepositoryMapPath',(Join-Path $Workspace 'repository-map.json'),'-CurrentWorkOnly') }
    if ($LiveOnly) { $arguments += '-CurrentWorkspaceOnly' }
    $text = (& pwsh @arguments 2>&1 | Out-String)
    return [pscustomobject]@{ exit_code=$LASTEXITCODE; text=$text }
}
function Add-OwnerAuthenticationCount([string]$Name,[string]$TransactionId=''){
    $counts=$global:WefProofMeasurement017.calls
    if(-not$counts.ContainsKey($Name)){$counts[$Name]=0};$counts[$Name]++
    if($TransactionId){$transactions=$global:WefProofMeasurement017.transactions;if(-not$transactions.ContainsKey($TransactionId)){$transactions[$TransactionId]=0};$transactions[$TransactionId]++}
}
function Measure-OwnerAuthentication([string]$Name,[scriptblock]$Action){
    # Test-only command breakpoints count the real owner calls. They never supply
    # an authority observation and are removed even when the measured call fails.
    if(Get-Variable WefProofMeasurement017 -Scope Global -ErrorAction SilentlyContinue){throw 'Proof measurement cannot be nested.'}
    $global:WefProofMeasurement017=[ordered]@{calls=@{};transactions=@{}}
    $breakpoints=@();$watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        # Literal breakpoint actions keep the dependency closure static. The
        # intent action reads the actual debuggee transaction parameter.
        $actions=@{
            'Assert-MorphospaceLedgerIntent'={
                $frame=@(Get-PSCallStack|Where-Object FunctionName -CEQ 'Assert-MorphospaceLedgerIntent')[0]
                $id=[string]$frame.InvocationInfo.BoundParameters['TransactionId']
                if(-not$id){throw 'Actual intent breakpoint has no bound transaction identity.'}
                Add-OwnerAuthenticationCount 'Assert-MorphospaceLedgerIntent' $id
            }
            'Assert-MorphospaceLedgerCommittedCompletion'={Add-OwnerAuthenticationCount 'Assert-MorphospaceLedgerCommittedCompletion'}
            'Assert-MorphospaceLedgerEventPlacement'={Add-OwnerAuthenticationCount 'Assert-MorphospaceLedgerEventPlacement'}
            'Get-MorphospaceLedgerSnapshot'={Add-OwnerAuthenticationCount 'Get-MorphospaceLedgerSnapshot'}
            'Get-MorphospaceCurrentWorkHistory'={Add-OwnerAuthenticationCount 'Get-MorphospaceCurrentWorkHistory'}
            'Get-ActiveRetirementPlanningTransition'={Add-OwnerAuthenticationCount 'Get-ActiveRetirementPlanningTransition'}
            'Get-ActiveRetirementRepositories'={Add-OwnerAuthenticationCount 'Get-ActiveRetirementRepositories'}
            'Assert-ActiveRetirementPreserved'={Add-OwnerAuthenticationCount 'Assert-ActiveRetirementPreserved'}
            'Test-MorphospaceDevelopmentUnitPreparation'={Add-OwnerAuthenticationCount 'Test-MorphospaceDevelopmentUnitPreparation'}
        }
        foreach($command in $actions.Keys){$breakpoints+=Set-PSBreakpoint -Command $command -Action $actions[$command]}
        & $Action
    }finally{
        $watch.Stop()
        foreach($breakpoint in $breakpoints){Remove-PSBreakpoint -Breakpoint $breakpoint}
        $observed=$global:WefProofMeasurement017
        Remove-Variable WefProofMeasurement017 -Scope Global
        if($observed.calls.ContainsKey('')-or-not$observed.calls.ContainsKey('Assert-MorphospaceLedgerIntent')-or$observed.transactions.Count-eq0){throw 'Actual owner proof instrumentation did not capture named intent calls.'}
        [ordered]@{schema='rusty.morphospace.test.owner_proof_measurement.v1';action=$Name;elapsed_ms=[math]::Round($watch.Elapsed.TotalMilliseconds,3);call_counts=$observed.calls;transaction_intent_checks=$observed.transactions;test_only_instrumentation=$true}|ConvertTo-Json -Depth 12 -Compress|Write-Host
    }
}

function Assert-Result($Result,[bool]$Pass,[string]$Name) {
    if (($Result.exit_code -eq 0) -ne $Pass) { throw "Current workspace validation case '$Name' failed: $($Result.text)" }
    $script:passed++
}
function Test-ProvenanceIntentReuse([string]$Workspace) {
    $provenance=Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeProvenance.psm1') -PassThru
    $transaction='u002-admission-admitted-transition'
    function Invoke-ProvenanceCheck([string]$Root,[switch]$Historical) {
        & $provenance {param($root,$id,$historical) Assert-PreparationProvenanceCommittedTransaction -Workspace $root -TransactionId $id -AllowHistorical:$historical} $Root $transaction ([bool]$Historical)
    }
    function Assert-ProvenanceCount([string]$Name,[int]$Expected) {
        $actual=if($global:WefProofMeasurement017.calls.ContainsKey($Name)){$global:WefProofMeasurement017.calls[$Name]}else{0}
        if($actual-ne$Expected){throw "Provenance reuse counter $Name expected $Expected, observed $actual."}
    }
    Measure-OwnerAuthentication 'Provenance-standalone-fresh' {
        Invoke-ProvenanceCheck $Workspace;Invoke-ProvenanceCheck $Workspace
        Assert-ProvenanceCount 'Assert-MorphospaceLedgerIntent' 2
        Assert-ProvenanceCount 'Assert-MorphospaceLedgerCommittedCompletion' 2
    }
    foreach($iteration in 1..2){
        Measure-OwnerAuthentication "Provenance-owned-nested-scope-$iteration" {
            $outer=&$transitionLedgerModule {param($root) New-MorphospaceReadOnlyLedgerBatch $root} $Workspace
            $inner=$null
            try{
                Invoke-ProvenanceCheck $Workspace
                $inner=&$transitionLedgerModule {param($root) New-MorphospaceReadOnlyLedgerBatch $root} $Workspace
                Invoke-ProvenanceCheck $Workspace
                Invoke-ProvenanceCheck $Workspace -Historical
                Assert-ProvenanceCount 'Assert-MorphospaceLedgerIntent' 1
                Assert-ProvenanceCount 'Assert-MorphospaceLedgerCommittedCompletion' 2
                Assert-ProvenanceCount 'Assert-MorphospaceLedgerEventPlacement' 3
            }finally{
                if($inner){&$transitionLedgerModule {param($token) Close-MorphospaceReadOnlyLedgerBatch $token} $inner}
                &$transitionLedgerModule {param($token) Close-MorphospaceReadOnlyLedgerBatch $token} $outer
            }
        }
    }
    $sibling=Join-Path $testRoot 'provenance-sibling';Copy-Item -LiteralPath $Workspace -Destination $sibling -Recurse
    Measure-OwnerAuthentication 'Provenance-sibling-isolation' {
        $token=&$transitionLedgerModule {param($root) New-MorphospaceReadOnlyLedgerBatch $root} $Workspace
        try{Invoke-ProvenanceCheck $Workspace;Invoke-ProvenanceCheck $sibling;Assert-ProvenanceCount 'Assert-MorphospaceLedgerIntent' 2}
        finally{&$transitionLedgerModule {param($token) Close-MorphospaceReadOnlyLedgerBatch $token} $token}
    }
    foreach($damage in @('intent','completion','artifact','state')){
        $intentPath=Join-Path $Workspace "receipts/transactions/$transaction.intent.json"
        $intent=Read-EnvelopeProtocolJson $intentPath
        $path=switch($damage){'intent'{$intentPath}'completion'{Join-Path $Workspace "receipts/transactions/$transaction.completion.json"}'artifact'{Join-Path $Workspace ([string]$intent.artifacts[0].path)}'state'{Join-Path $Workspace 'workspace.state.json'}}
        $original=[IO.File]::ReadAllBytes($path)
        Measure-OwnerAuthentication "Provenance-late-$damage-drift" {
            $token=&$transitionLedgerModule {param($root) New-MorphospaceReadOnlyLedgerBatch $root} $Workspace
            try{
                Invoke-ProvenanceCheck $Workspace
                if($damage-eq'intent'-or$damage-eq'artifact'){[IO.File]::AppendAllText($path,' ',[Text.UTF8Encoding]::new($false))}
                else{$document=Read-EnvelopeProtocolJson $path;if($damage-eq'completion'){$document.event_id='changed'}else{$document.plan_revision=[int]$document.plan_revision+1};Write-EnvelopeJson $path $document}
                $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace
                $refused=$false;$message='';try{Invoke-ProvenanceCheck $Workspace}catch{$refused=$true;$message=$_.Exception.Message}
                if(-not$refused-or$before-cne(Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)){throw "Late $damage drift was accepted or wrote workspace bytes."}
                if($damage-eq'intent'-and$message-cne'Read-only committed intent changed during authentication.'){throw "Intent drift failed at an unexpected guard: $message"}
                Assert-ProvenanceCount 'Assert-MorphospaceLedgerIntent' 1
            }finally{[IO.File]::WriteAllBytes($path,$original);&$transitionLedgerModule {param($token) Close-MorphospaceReadOnlyLedgerBatch $token} $token}
        }
    }
    $outer=&$transitionLedgerModule {param($root) New-MorphospaceReadOnlyLedgerBatch $root} $Workspace
    $inner=&$transitionLedgerModule {param($root) New-MorphospaceReadOnlyLedgerBatch $root} $Workspace
    $shared=$null
    try{
        $shared=&$transitionLedgerModule {param($token) $value=$script:readOnlyLedgerBatches[$token].intents;$script:readOnlyLedgerBatches[$token].intents=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal);return ,$value} $inner
        $before=Get-EnvelopeWorkspaceByteInventorySha256 $Workspace
        $refused=$false;try{Invoke-ProvenanceCheck $Workspace}catch{$refused=$_.Exception.Message-ceq'Prepared-envelope intent proof scope is ambiguous.'}
        if(-not$refused-or$before-cne(Get-EnvelopeWorkspaceByteInventorySha256 $Workspace)){throw 'Ambiguous private proof scopes were accepted or wrote workspace bytes.'}
    }finally{
        if($null-ne$shared){&$transitionLedgerModule {param($token,$value) $script:readOnlyLedgerBatches[$token].intents=$value} $inner $shared}
        &$transitionLedgerModule {param($token) Close-MorphospaceReadOnlyLedgerBatch $token} $inner
        &$transitionLedgerModule {param($token) Close-MorphospaceReadOnlyLedgerBatch $token} $outer
    }
    Write-Host 'Provenance immutable intent reuse: standalone/reset/nested/sibling and late drift/no-write controls passed.'
}
try {
    # The shared fixture uses real preparation/admission and transition producers.
    $fixture = New-EnvelopeAdmissionPreparedFixture -Root (Join-Path $testRoot 'fixture') -RepositoryRoot $repoRoot -TransitionLedgerModule $transitionLedgerModule -OwnerProducedPreparation
    $workspace = $fixture.workspace
    $admissionPath = Join-Path $testRoot 'admission.json'
    Write-EnvelopeJson $admissionPath $fixture.admission_template
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts/u002-admission.json') -Execute | Out-Null
    if($ProvenanceIntentReuseOnly-or-not$ProofMeasurementOnly){
        Test-ProvenanceIntentReuse $workspace
        if($ProvenanceIntentReuseOnly){return}
    }
    foreach ($action in @('Ready','Claim')) {
        Invoke-MorphospaceWorkUnitAutomation -Action $action -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath (Join-Path $workspace 'repository-map.json') -OutPath (Join-Path $workspace "receipts/$action-action.json") -Execute | Out-Null
    }
    if($ProofMeasurementOnly){
        Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkHistory.psm1') -Force
        $history=Measure-OwnerAuthentication 'GetCurrentWorkHistory-prepared-current' {Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $workspace}
        if(-not$history.authenticated){throw 'Measured actual current-history action failed.'}
        return
    }
    Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $true 'live prepared current owner'
    Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkHistory.psm1') -Force
    $history=Measure-OwnerAuthentication 'GetCurrentWorkHistory-prepared-current' {Get-MorphospaceCurrentWorkHistory -WorkspaceRoot $workspace}
    if(-not$history.authenticated){throw 'Measured actual current-history action failed.'}
    $eventPath = Join-Path $workspace 'iteration-events.jsonl'
    $eventBytes = [IO.File]::ReadAllBytes($eventPath)
    try {
        [IO.File]::AppendAllText($eventPath, "{`"schema`":`"invalid`"}`n", [Text.UTF8Encoding]::new($false))
        Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $false 'changed event suffix'
    } finally { [IO.File]::WriteAllBytes($eventPath,$eventBytes) }
    $receiptPath = Join-Path $workspace 'receipts/u002-envelope.json'
    $receiptBytes = [IO.File]::ReadAllBytes($receiptPath)
    try {
        [IO.File]::AppendAllText($receiptPath,' ',[Text.UTF8Encoding]::new($false))
        Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $false 'changed raw owner receipt'
    } finally { [IO.File]::WriteAllBytes($receiptPath,$receiptBytes) }
    $dependencyPath = Join-Path $workspace 'source-composition.json'
    $dependencyBytes = [IO.File]::ReadAllBytes($dependencyPath)
    try {
        [IO.File]::AppendAllText($dependencyPath,' ',[Text.UTF8Encoding]::new($false))
        Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $false 'changed source-composition pin'
    } finally { [IO.File]::WriteAllBytes($dependencyPath,$dependencyBytes) }
    Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $true 'restored live closure'
    # A pointer with an absent resolver is denied by the early production check.
    $unitPath = Join-Path $workspace 'iteration-units/u002.json'
    $unitBytes = [IO.File]::ReadAllBytes($unitPath)
    try {
        $unit = Read-EnvelopeProtocolJson $unitPath
        $contextPath = Join-Path $workspace 'local/precheck-context.json'
        Write-EnvelopeJson $contextPath @{resolver=@{path='local/absent-resolver.json';sha256=('0'*64)}}
        $unit | Add-Member -NotePropertyName tooling_context -NotePropertyValue @{path='local/precheck-context.json';sha256=(Get-EnvelopeFileSha256 $contextPath)}
        Write-EnvelopeJson $unitPath $unit
        $result = Invoke-ActualValidator $repoRoot $workspace $true
        Assert-Result $result $false 'absent resolver early denial'
        if ($result.text -notmatch 'absent-resolver.json') { throw 'Missing resolver did not fail at the required input check.' }
    } finally { [IO.File]::WriteAllBytes($unitPath,$unitBytes) }
    # Materialize only tracked owner inputs; overlay the exact candidate validator.
    $ownerCopy = Join-Path $testRoot 'owner'
    [void][IO.Directory]::CreateDirectory($ownerCopy)
    $archive = Join-Path $testRoot 'owner.tar'
    & git -C $repoRoot archive --format=tar --output=$archive HEAD scripts schemas templates manifests examples skills
    if ($LASTEXITCODE -ne 0) { throw 'Owner fixture archive failed.' }
    & tar -xf $archive -C $ownerCopy
    if ($LASTEXITCODE -ne 0) { throw 'Owner fixture extraction failed.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -Destination (Join-Path $ownerCopy 'scripts/Test-WorkflowContracts.ps1')
    Invoke-EnvelopeGit $ownerCopy @('-c','init.defaultBranch=fixture','-c','init.templateDir=','init') | Out-Null
    Invoke-EnvelopeGit $ownerCopy @('add','scripts','schemas','templates','manifests','examples','skills') | Out-Null
    $emptyHooks = Join-Path $testRoot 'empty-hooks'
    [void][IO.Directory]::CreateDirectory($emptyHooks)
    Invoke-EnvelopeGit $ownerCopy @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c',"core.hooksPath=$emptyHooks",'commit','-m','owner-fixture') | Out-Null
    Assert-Result (Invoke-ActualValidator $ownerCopy '' $false) $true 'default owner conformance'
    [IO.File]::WriteAllText((Join-Path $ownerCopy 'templates/project.spec.v2.example.json'),'{}',[Text.UTF8Encoding]::new($false))
    Assert-Result (Invoke-ActualValidator $ownerCopy '' $false) $false 'default retains static negative fixtures'
    Assert-Result (Invoke-ActualValidator $ownerCopy $workspace $true) $true 'live mode does not repeat owner fixtures'
    Assert-Result (Invoke-ActualValidator $repoRoot '' $true) $false 'live mode requires explicit workspace flags'
    Write-Host "Current workspace validation: $passed production cases passed; static owner conformance remains separate from fresh live guards."
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
