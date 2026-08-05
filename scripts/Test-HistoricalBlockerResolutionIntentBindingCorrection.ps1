param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalBlockerResolutionIntentBindingCorrection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CorrectHistoricalBlockerResolutionIntentBinding.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ResolveBlocker.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Assert-HistoricalCorrectionTest([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "Historical blocker-resolution intent-binding correction self-test failed: $Message" }
}
function Assert-HistoricalCorrectionRejected([scriptblock]$Action,[string]$Message,[string]$Like='*') {
    $rejected=$false;$detail=''
    try { & $Action } catch { $rejected=$true;$detail=$_.Exception.Message }
    Assert-HistoricalCorrectionTest ($rejected -and $detail -like $Like) "$Message (observed: $detail)"
}
function Get-HistoricalCorrectionTestByteSha256([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Copy-HistoricalCorrectionTestDocument([object]$Value) {
    $Value|ConvertTo-Json -Depth 100 -Compress|ConvertFrom-Json
}
function Restore-HistoricalCorrectionTestModules {
    Import-Module (Join-Path $PSScriptRoot 'CorrectHistoricalBlockerResolutionIntentBinding.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'ResolveBlocker.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalBlockerResolutionIntentBindingCorrection.psm1') -Force -Global
}
function Write-HistoricalCorrectionTestJson([string]$Path,[object]$Value) {
    $parent=Split-Path -Parent $Path;if($parent){[IO.Directory]::CreateDirectory($parent)|Out-Null}
    [IO.File]::WriteAllText($Path,(ConvertTo-MorphospaceCanonicalJson $Value)+"`n",[Text.UTF8Encoding]::new($false))
}
function Write-HistoricalCorrectionTestLooseJson([string]$Path,[object]$Value) {
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 100 -Compress)+"`n",[Text.UTF8Encoding]::new($false))
}
function Write-HistoricalCorrectionTestLedger([string]$Path,[object[]]$Events) {
    $text=(@($Events|ForEach-Object{$_|ConvertTo-Json -Depth 32 -Compress})-join"`n")+"`n"
    [IO.File]::WriteAllText($Path,$text,[Text.UTF8Encoding]::new($false))
}
function Expand-HistoricalCorrectionTestTerminalLfToCrLf([string]$Path) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($bytes.Length-lt1-or$bytes[$bytes.Length-1]-ne0x0a){throw 'test fixture expected terminal LF'}
    $expanded=[byte[]]::new($bytes.Length+1)
    if($bytes.Length-gt1){[Array]::Copy($bytes,0,$expanded,0,$bytes.Length-1)}
    $expanded[$expanded.Length-2]=0x0d;$expanded[$expanded.Length-1]=0x0a
    [IO.File]::WriteAllBytes($Path,$expanded)
}
function Invoke-HistoricalCorrectionTestGit([string]$Path,[string[]]$Arguments) {
    $output=@(& git -C $Path @Arguments 2>&1);if($LASTEXITCODE-ne0){throw "test git failed: $($Arguments-join' '): $($output-join' ')"};(($output|ForEach-Object{[string]$_})-join"`n").Trim()
}
function New-HistoricalCorrectionFixture([string]$Root) {
    $workspace=Join-Path $Root 'workspace';$repo=Join-Path $Root 'repo'
    foreach($directory in @($workspace,(Join-Path $workspace 'iteration-units'),(Join-Path $workspace 'receipts\transactions'),(Join-Path $workspace 'receipts\evidence'),$repo)){[IO.Directory]::CreateDirectory($directory)|Out-Null}
    $old=Read-MorphospaceProtocolJson (Join-Path $repoRoot 'templates\iteration-unit.example.json')
    $current=Copy-HistoricalCorrectionTestDocument $old
    $old.unit_id='historical-unit';$old.project_id='example-project';$old.status='active';$old.objective='Historical unit with a retained blocker-resolution transaction.'
    $current.unit_id='current-unit';$current.project_id='example-project';$current.status='active';$current.objective='Current unit that owns only the additive historical evidence correction.'
    Write-HistoricalCorrectionTestJson (Join-Path $workspace 'iteration-units\historical-unit.json') $old
    Write-HistoricalCorrectionTestJson (Join-Path $workspace 'iteration-units\current-unit.json') $current

    $originalReceipt=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.blocker_resolution_receipt.v1';receipt_id='historical-resolution';project_id='example-project';unit_id='historical-unit'
        blocker=[pscustomobject][ordered]@{blocker_id='historical-blocker';condition='Historical condition.';resume_when='Historical evidence passes.'}
        result='pass';evidence=@([pscustomobject]@{path='receipts/evidence/historical.txt';sha256=('a'*64)})
        repository_heads=@([pscustomobject]@{repo_id='example-repo';branch='main';revision=('b'*40)})
        repository_sources=@([pscustomobject]@{repo_id='example-repo';sources=@([pscustomobject]@{path='tracked.txt';sha256=('c'*64)})})
        preserve_blocker_ids=@()
    }
    $originalReceiptRelative='receipts/historical-resolution.json';$originalReceiptPath=Join-Path $workspace 'receipts\historical-resolution.json'
    Write-HistoricalCorrectionTestJson $originalReceiptPath $originalReceipt
    $historicalEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='historical-unit-blocker-resolved-0001';sequence=1;timestamp='2026-08-05T10:00:00Z';project_id='example-project';unit_id='historical-unit';event_type='state-transition';summary="Resolved blocker 'historical-blocker' from retained evidence.";receipts=@($originalReceiptRelative)}
    $currentEvent=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='current-unit-resumed-0002';sequence=2;timestamp='2026-08-05T10:01:00Z';project_id='example-project';unit_id='current-unit';event_type='state-transition';summary='Made the current correction-owning unit active.';receipts=@()}
    $ledgerPath=Join-Path $workspace 'iteration-events.jsonl';Write-HistoricalCorrectionTestLedger $ledgerPath @($historicalEvent,$currentEvent)

    $historicalState=Read-MorphospaceProtocolJson (Join-Path $repoRoot 'templates\workspace.state.example.json')
    $historicalState.project_id='example-project';$historicalState.current_unit='historical-unit';$historicalState.last_event_id=[string]$historicalEvent.event_id;$historicalState.blockers=@();$historicalState.pending_push_bundle=$null;$historicalState.validation_checkpoint=$null
    $empty=[byte[]]::new(0);$transactionId="$([string]$historicalEvent.event_id)-transition";$intentRelative="receipts/transactions/$transactionId.intent.json";$completionRelative="receipts/transactions/$transactionId.completion.json"
    $receiptBytes=[IO.File]::ReadAllBytes($originalReceiptPath)
    $intent=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.transition_ledger_intent.v1';transaction_id=$transactionId;created_at='2026-08-05T09:59:59.0000000Z'
        state=[pscustomobject]@{path='workspace.state.json'};unit=[pscustomobject]@{path='iteration-units/historical-unit.json'};events=[pscustomobject]@{path='iteration-events.jsonl'}
        pre=[pscustomobject]@{state=[pscustomobject]@{sha256=('d'*64)};unit=[pscustomobject]@{sha256=('e'*64)}}
        target=[pscustomobject]@{state=[pscustomobject]@{sha256=Get-MorphospaceCanonicalJsonSha256 $historicalState;document=$historicalState};unit=[pscustomobject]@{sha256=Get-MorphospaceCanonicalJsonSha256 $old;document=$old}}
        expected=[pscustomobject]@{state_sha256=('d'*64);unit_sha256=('e'*64);event_tail_id=$null;events_sha256=Get-MorphospaceSha256Bytes $empty;events_length=0}
        artifacts=@([pscustomobject]@{path=$originalReceiptRelative;sha256=Get-MorphospaceSha256Bytes $receiptBytes;bytes_base64=[Convert]::ToBase64String($receiptBytes)})
        event=$historicalEvent;status='prepared'
    }
    $intentPath=Join-Path $workspace ($intentRelative-replace'/','\');Write-HistoricalCorrectionTestJson $intentPath $intent
    $recordedIntentHash=Get-MorphospaceFileSha256 $intentPath
    $completion=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.transition_ledger_completion.v1';transaction_id=$transactionId;completed_at='2026-08-05T10:00:01.0000000Z'
        intent=[pscustomobject]@{role='transition-ledger-intent';path=$intentRelative;schema=[string]$intent.schema;sha256=$recordedIntentHash}
        state_sha256=[string]$intent.target.state.sha256;unit_sha256=[string]$intent.target.unit.sha256;event_id=[string]$historicalEvent.event_id;status='committed'
    }
    $completionPath=Join-Path $workspace ($completionRelative-replace'/','\');Write-HistoricalCorrectionTestJson $completionPath $completion
    Expand-HistoricalCorrectionTestTerminalLfToCrLf $originalReceiptPath
    Expand-HistoricalCorrectionTestTerminalLfToCrLf $intentPath

    $state=Copy-HistoricalCorrectionTestDocument $historicalState;$state.current_unit='current-unit';$state.last_event_id=[string]$currentEvent.event_id
    $state.blockers=@([pscustomobject][ordered]@{blocker_id='current-blocker';condition='Current blocker condition.';resume_when='Current evidence passes.'})
    Write-HistoricalCorrectionTestJson (Join-Path $workspace 'workspace.state.json') $state
    [IO.File]::WriteAllText((Join-Path $workspace 'receipts\evidence\current.txt'),'pass',[Text.UTF8Encoding]::new($false))

    Invoke-HistoricalCorrectionTestGit $repo @('init','-b','main')|Out-Null
    Invoke-HistoricalCorrectionTestGit $repo @('config','user.email','selftest@example.invalid')|Out-Null;Invoke-HistoricalCorrectionTestGit $repo @('config','user.name','Self Test')|Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'),'current',[Text.UTF8Encoding]::new($false));Invoke-HistoricalCorrectionTestGit $repo @('add','tracked.txt')|Out-Null;Invoke-HistoricalCorrectionTestGit $repo @('commit','-m','fixture')|Out-Null
    $head=Invoke-HistoricalCorrectionTestGit $repo @('rev-parse','HEAD')
    $mapPath=Join-Path $Root 'repository-map.json';Write-HistoricalCorrectionTestJson $mapPath ([pscustomobject]@{repositories=@([pscustomobject]@{repo_id='example-repo';path=$repo})})
    $resolveInput=Join-Path $Root 'resolve-input.json';Write-HistoricalCorrectionTestJson $resolveInput ([pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.blocker_resolution_receipt.v1';receipt_id='current-resolution';project_id='example-project';unit_id='current-unit'
        blocker=[pscustomobject][ordered]@{blocker_id='current-blocker';condition='Current blocker condition.';resume_when='Current evidence passes.'};result='pass'
        evidence=@([pscustomobject]@{path='receipts/evidence/current.txt';sha256=Get-MorphospaceFileSha256 (Join-Path $workspace 'receipts\evidence\current.txt')})
        repository_heads=@([pscustomobject]@{repo_id='example-repo';branch='main';revision=$head})
        repository_sources=@([pscustomobject]@{repo_id='example-repo';sources=@([pscustomobject]@{path='tracked.txt';sha256=Get-MorphospaceFileSha256 (Join-Path $repo 'tracked.txt')})})
        preserve_blocker_ids=@()
    })
    [pscustomobject]@{workspace=$workspace;repo=$repo;ledger=$ledgerPath;state=(Join-Path $workspace 'workspace.state.json');unit=(Join-Path $workspace 'iteration-units\current-unit.json');receipt=$originalReceiptPath;intent=$intentPath;completion=$completionPath;map=$mapPath;resolve_input=$resolveInput}
}

$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath());$testRoot=Join-Path $tempBase ('rusty-morphospace-historical-resolution-correction-'+[guid]::NewGuid().ToString('N'))
try {
    $fixture=New-HistoricalCorrectionFixture $testRoot
    $negativeRoot=Join-Path $testRoot 'negative-historical-intent-property';$negative=New-HistoricalCorrectionFixture $negativeRoot
    $damaged=Get-Content -Raw -LiteralPath $negative.intent|ConvertFrom-Json -DateKind String;$damaged|Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    Write-HistoricalCorrectionTestLooseJson $negative.intent $damaged;Expand-HistoricalCorrectionTestTerminalLfToCrLf $negative.intent
    Assert-HistoricalCorrectionRejected {
        & (Join-Path $PSScriptRoot 'New-HistoricalBlockerResolutionIntentBindingCorrection.ps1') -WorkspaceRoot $negative.workspace `
            -HistoricalEventId 'historical-unit-blocker-resolved-0001' -ReceiptId 'rejected-extra-intent-property' `
            -Timestamp '2026-08-05T10:02:00Z' -OutPath (Join-Path $negativeRoot 'correction.json') | Out-Null
    } 'Builder accepted an extra historical intent property.' '*property set*'

    $negativeRoot=Join-Path $testRoot 'negative-historical-extra-artifact';$negative=New-HistoricalCorrectionFixture $negativeRoot
    $damaged=Get-Content -Raw -LiteralPath $negative.intent|ConvertFrom-Json -DateKind String
    $damaged.artifacts=@($damaged.artifacts)+@([pscustomobject]@{path='receipts/unexpected.json';sha256=Get-HistoricalCorrectionTestByteSha256 ([byte[]](1,2,3));bytes_base64=[Convert]::ToBase64String([byte[]](1,2,3))})
    Write-HistoricalCorrectionTestLooseJson $negative.intent $damaged;Expand-HistoricalCorrectionTestTerminalLfToCrLf $negative.intent
    Assert-HistoricalCorrectionRejected {
        & (Join-Path $PSScriptRoot 'New-HistoricalBlockerResolutionIntentBindingCorrection.ps1') -WorkspaceRoot $negative.workspace `
            -HistoricalEventId 'historical-unit-blocker-resolved-0001' -ReceiptId 'rejected-extra-historical-artifact' `
            -Timestamp '2026-08-05T10:02:00Z' -OutPath (Join-Path $negativeRoot 'correction.json') | Out-Null
    } 'Builder accepted an extra historical intent artifact.' '*exactly one artifact*'

    $negativeRoot=Join-Path $testRoot 'negative-historical-completion-property';$negative=New-HistoricalCorrectionFixture $negativeRoot
    $damaged=Get-Content -Raw -LiteralPath $negative.completion|ConvertFrom-Json -DateKind String;$damaged|Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    Write-HistoricalCorrectionTestLooseJson $negative.completion $damaged
    Assert-HistoricalCorrectionRejected {
        & (Join-Path $PSScriptRoot 'New-HistoricalBlockerResolutionIntentBindingCorrection.ps1') -WorkspaceRoot $negative.workspace `
            -HistoricalEventId 'historical-unit-blocker-resolved-0001' -ReceiptId 'rejected-extra-completion-property' `
            -Timestamp '2026-08-05T10:02:00Z' -OutPath (Join-Path $negativeRoot 'correction.json') | Out-Null
    } 'Builder accepted an extra historical completion property.' '*property set*'

    $negativeRoot=Join-Path $testRoot 'negative-historical-completion-time';$negative=New-HistoricalCorrectionFixture $negativeRoot
    $damaged=Get-Content -Raw -LiteralPath $negative.completion|ConvertFrom-Json -DateKind String;$damaged.completed_at='not-a-timestamp'
    Write-HistoricalCorrectionTestLooseJson $negative.completion $damaged
    Assert-HistoricalCorrectionRejected {
        & (Join-Path $PSScriptRoot 'New-HistoricalBlockerResolutionIntentBindingCorrection.ps1') -WorkspaceRoot $negative.workspace `
            -HistoricalEventId 'historical-unit-blocker-resolved-0001' -ReceiptId 'rejected-completion-time' `
            -Timestamp '2026-08-05T10:02:00Z' -OutPath (Join-Path $negativeRoot 'correction.json') | Out-Null
    } 'Builder accepted an invalid historical completion timestamp.' '*seven-digit UTC*'

    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceResolveBlocker -WorkspaceRoot $fixture.workspace -UnitId current-unit -RepoMapPath $fixture.map -BlockerResolutionReceipt $fixture.resolve_input | Out-Null
    } 'ResolveBlocker accepted the uncorrected historical intent mismatch.' '*cryptographically inconsistent*'

    $correctionInput=Join-Path $testRoot 'inspected-correction.json'
    $builderJson=& (Join-Path $PSScriptRoot 'New-HistoricalBlockerResolutionIntentBindingCorrection.ps1') -WorkspaceRoot $fixture.workspace `
        -HistoricalEventId 'historical-unit-blocker-resolved-0001' -ReceiptId 'historical-resolution-intent-binding-correction' `
        -Timestamp '2026-08-05T10:02:00Z' -OutPath $correctionInput
    $builder=$builderJson|ConvertFrom-Json
    Assert-HistoricalCorrectionTest ([string]$builder.historical_event_id-ceq'historical-unit-blocker-resolved-0001') 'Builder selected the wrong historical event.'
    $receipt=Read-MorphospaceHistoricalBlockerResolutionIntentBindingCorrection $correctionInput
    $output=Join-Path $fixture.workspace ([string]$receipt.document.correction_event.receipt_path-replace'/','\')
    $dry=Invoke-MorphospaceCorrectHistoricalBlockerResolutionIntentBinding -WorkspaceRoot $fixture.workspace -UnitId current-unit -CorrectionReceipt $correctionInput -OutPath $output
    Assert-HistoricalCorrectionTest (-not$dry.executed-and$null-eq$dry.event_id-and[string]$dry.audit_receipt.sha256-ceq[string]$receipt.sha256) 'Typed dry-run did not return the reviewed correction hash.'
    $wrapperJson=& (Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1') -Action CorrectHistoricalBlockerResolutionIntentBinding -WorkspaceRoot $fixture.workspace -UnitId current-unit `
        -HistoricalBlockerResolutionIntentBindingCorrection $correctionInput -OutPath $output
    $wrapper=$wrapperJson|ConvertFrom-Json
    Assert-HistoricalCorrectionTest ([string]$wrapper.action-ceq'CorrectHistoricalBlockerResolutionIntentBinding'-and-not$wrapper.executed) 'Public router did not dispatch the historical correction dry run.'
    Restore-HistoricalCorrectionTestModules

    $patched=Get-Content -Raw -LiteralPath $correctionInput|ConvertFrom-Json;$patched.historical_resolution.intent_binding.completion_recorded_sha256=[string]$patched.historical_resolution.intent_binding.observed_file_sha256
    $patchedPath=Join-Path $testRoot 'patched.json';[IO.File]::WriteAllText($patchedPath,($patched|ConvertTo-Json -Depth 32)+"`n",[Text.UTF8Encoding]::new($false))
    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceCorrectHistoricalBlockerResolutionIntentBinding -WorkspaceRoot $fixture.workspace -UnitId current-unit -CorrectionReceipt $patchedPath -OutPath $output | Out-Null
    } 'A receipt that erased the exact mismatch was accepted.' '*differs*'
    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceCorrectHistoricalBlockerResolutionIntentBinding -WorkspaceRoot $fixture.workspace -UnitId current-unit -CorrectionReceipt $correctionInput -OutPath $output -Execute | Out-Null
    } 'Execution without the dry-run hash was accepted.' '*ExpectedCorrectionSha256*'
    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceCorrectHistoricalBlockerResolutionIntentBinding -WorkspaceRoot $fixture.workspace -UnitId current-unit -CorrectionReceipt $correctionInput -ExpectedCorrectionSha256 ('0'*64) -OutPath $output -Execute | Out-Null
    } 'Execution with a wrong reviewed hash was accepted.' '*differs*'

    $before=@{};foreach($path in @($fixture.ledger,$fixture.unit,$fixture.receipt,$fixture.intent,$fixture.completion)){$before[$path]=[IO.File]::ReadAllBytes($path)}
    $executed=Invoke-MorphospaceCorrectHistoricalBlockerResolutionIntentBinding -WorkspaceRoot $fixture.workspace -UnitId current-unit -CorrectionReceipt $correctionInput `
        -ExpectedCorrectionSha256 ([string]$receipt.sha256) -OutPath $output -Execute
    Restore-HistoricalCorrectionTestModules
    Assert-HistoricalCorrectionTest ($executed.executed-and[string]$executed.event_id-ceq[string]$receipt.document.correction_event.event_id) 'Positive execution did not append the reviewed correction event.'
    foreach($path in @($fixture.unit,$fixture.receipt,$fixture.intent,$fixture.completion)){
        Assert-HistoricalCorrectionTest ((Get-HistoricalCorrectionTestByteSha256 ([IO.File]::ReadAllBytes($path)))-ceq(Get-HistoricalCorrectionTestByteSha256 $before[$path])) "Execution changed retained bytes at '$path'."
    }
    $afterLedger=[IO.File]::ReadAllBytes($fixture.ledger);for($index=0;$index-lt$before[$fixture.ledger].Length;$index++){Assert-HistoricalCorrectionTest ($afterLedger[$index]-eq$before[$fixture.ledger][$index]) 'Execution rewrote the historical ledger prefix.'}
    $state=Get-Content -Raw -LiteralPath $fixture.state|ConvertFrom-Json
    Assert-HistoricalCorrectionTest ([string]$state.current_unit-ceq'current-unit'-and[string]$state.last_event_id-ceq[string]$receipt.document.correction_event.event_id-and@($state.blockers).Count-eq1) 'Execution changed state beyond last_event_id.'
    $historicalModule=Get-Module MorphospaceHistoricalBlockerResolutionIntentBindingCorrection|Select-Object -First 1
    $fullLedger=& $historicalModule { param($Path) Get-HistoricalCorrectionLedgerEvents $Path } $fixture.ledger
    $boundPrefix=& $historicalModule { param($Ledger,$Binding) Get-HistoricalCorrectionBoundLedgerPrefix -Ledger $Ledger -Binding $Binding } $fullLedger $receipt.document.current_authority.event_ledger
    $futureEvent=Copy-HistoricalCorrectionTestDocument $boundPrefix.events[0];$futureEvent.event_id='future-unit-blocker-resolved-0003';$futureEvent.sequence=3;$futureEvent.timestamp='2026-08-05T10:03:00Z'
    $futureReceipt=Copy-HistoricalCorrectionTestDocument $receipt.document;$futureReceipt.historical_resolution.event.event_id=[string]$futureEvent.event_id;$futureReceipt.historical_resolution.event.sequence=3;$futureReceipt.historical_resolution.event.sha256=(& $historicalModule { param($Event) Get-MorphospaceCanonicalJsonSha256 $Event } $futureEvent)
    $ledgerWithFuture=[pscustomobject]@{events=@($boundPrefix.events)+@($futureEvent)}
    Assert-HistoricalCorrectionTest (@($ledgerWithFuture.events|Where-Object{[string]$_.event_id-ceq[string]$futureEvent.event_id}).Count-eq1) 'Future-target fixture did not place the target after the correction-bound prefix.'
    Assert-HistoricalCorrectionRejected {
        & $historicalModule { param($Workspace,$Receipt,$Ledger) Assert-HistoricalResolutionIntentBindingFault -Workspace $Workspace -Receipt $Receipt -Ledger $Ledger } $fixture.workspace $futureReceipt $boundPrefix | Out-Null
    } 'A historical target outside the correction-bound pre-append prefix was accepted.' '*exactly one target*'
    $index=Get-MorphospaceHistoricalBlockerResolutionIntentBindingCorrectionIndex -WorkspaceRoot $fixture.workspace
    Assert-HistoricalCorrectionTest ($index.ContainsKey('historical-unit-blocker-resolved-0001')) 'Authenticated correction index did not project the target event.'
    $resolveDry=Invoke-MorphospaceResolveBlocker -WorkspaceRoot $fixture.workspace -UnitId current-unit -RepoMapPath $fixture.map -BlockerResolutionReceipt $fixture.resolve_input
    Assert-HistoricalCorrectionTest (-not$resolveDry.executed-and[string]$resolveDry.transition-ceq'blocker-resolved') 'ResolveBlocker did not accept the exact additive historical correction.'
    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceCorrectHistoricalBlockerResolutionIntentBinding -WorkspaceRoot $fixture.workspace -UnitId current-unit -CorrectionReceipt $correctionInput -ExpectedCorrectionSha256 ([string]$receipt.sha256) -OutPath $output -Execute | Out-Null
    } 'Correction replay was accepted.' '*already consumed*'

    $correctionTransactionId="$([string]$receipt.document.correction_event.event_id)-transition"
    $correctionIntent=Join-Path $fixture.workspace "receipts\transactions\$correctionTransactionId.intent.json"
    $correctionCompletion=Join-Path $fixture.workspace "receipts\transactions\$correctionTransactionId.completion.json"
    $intentBytes=[IO.File]::ReadAllBytes($correctionIntent);$damaged=Get-Content -Raw -LiteralPath $correctionIntent|ConvertFrom-Json -DateKind String;$damaged|Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    Write-HistoricalCorrectionTestLooseJson $correctionIntent $damaged
    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceResolveBlocker -WorkspaceRoot $fixture.workspace -UnitId current-unit -RepoMapPath $fixture.map -BlockerResolutionReceipt $fixture.resolve_input | Out-Null
    } 'ResolveBlocker accepted an extra additive correction-intent property.' '*property set*'
    [IO.File]::WriteAllBytes($correctionIntent,$intentBytes)

    $damaged=Get-Content -Raw -LiteralPath $correctionIntent|ConvertFrom-Json -DateKind String
    $damaged.artifacts=@($damaged.artifacts)+@([pscustomobject]@{path='receipts/unexpected-correction-artifact.json';sha256=Get-HistoricalCorrectionTestByteSha256 ([byte[]](4,5,6));bytes_base64=[Convert]::ToBase64String([byte[]](4,5,6))})
    Write-HistoricalCorrectionTestLooseJson $correctionIntent $damaged
    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceResolveBlocker -WorkspaceRoot $fixture.workspace -UnitId current-unit -RepoMapPath $fixture.map -BlockerResolutionReceipt $fixture.resolve_input | Out-Null
    } 'ResolveBlocker accepted an extra additive correction artifact.' '*exactly one artifact*'
    [IO.File]::WriteAllBytes($correctionIntent,$intentBytes)

    $completionBytes=[IO.File]::ReadAllBytes($correctionCompletion);$damaged=Get-Content -Raw -LiteralPath $correctionCompletion|ConvertFrom-Json -DateKind String;$damaged|Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    Write-HistoricalCorrectionTestLooseJson $correctionCompletion $damaged
    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceResolveBlocker -WorkspaceRoot $fixture.workspace -UnitId current-unit -RepoMapPath $fixture.map -BlockerResolutionReceipt $fixture.resolve_input | Out-Null
    } 'ResolveBlocker accepted an extra additive correction-completion property.' '*property set*'
    [IO.File]::WriteAllBytes($correctionCompletion,$completionBytes)

    $damaged=Get-Content -Raw -LiteralPath $correctionCompletion|ConvertFrom-Json -DateKind String;$damaged.completed_at='not-a-timestamp'
    Write-HistoricalCorrectionTestLooseJson $correctionCompletion $damaged
    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceResolveBlocker -WorkspaceRoot $fixture.workspace -UnitId current-unit -RepoMapPath $fixture.map -BlockerResolutionReceipt $fixture.resolve_input | Out-Null
    } 'ResolveBlocker accepted an invalid additive correction-completion timestamp.' '*seven-digit UTC*'
    [IO.File]::WriteAllBytes($correctionCompletion,$completionBytes)

    $completionBytes=[IO.File]::ReadAllBytes($correctionCompletion);$damaged=Get-Content -Raw -LiteralPath $correctionCompletion|ConvertFrom-Json -DateKind String;$damaged.state_sha256='0'*64
    [IO.File]::WriteAllText($correctionCompletion,($damaged|ConvertTo-Json -Depth 32 -Compress)+"`n",[Text.UTF8Encoding]::new($false))
    Assert-HistoricalCorrectionRejected {
        Invoke-MorphospaceResolveBlocker -WorkspaceRoot $fixture.workspace -UnitId current-unit -RepoMapPath $fixture.map -BlockerResolutionReceipt $fixture.resolve_input | Out-Null
    } 'ResolveBlocker ignored damage to the additive correction chain.' '*Correction transition completion*'
    [IO.File]::WriteAllBytes($correctionCompletion,$completionBytes)

    Write-Host 'Historical blocker-resolution intent-binding correction self-test passed.'
} finally {
    if([IO.Directory]::Exists($testRoot)-and$env:MORPHOSPACE_KEEP_HISTORICAL_CORRECTION_TEST-cne'1'){
        $resolved=[IO.Path]::GetFullPath($testRoot)
        if(-not$resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to clean historical correction self-test path outside the system temporary directory.'}
        Get-ChildItem -LiteralPath $resolved -Force -Recurse | ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
