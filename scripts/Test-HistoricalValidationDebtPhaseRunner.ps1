param(
    [switch]$SelfTest,
    [string]$EvidenceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceHistoricalValidationDebtPhaseRunner.psm1') -Force

function Assert-PhaseRunner {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Historical validation-debt phase-runner self-test failed: $Message" }
}

function New-PhaseRunnerBaselineFixture {
    $zero='0'*64;$one='1'*64;$two='2'*64;$three='3'*64;$four='4'*64;$five='5'*64;$six='6'*64;$seven='7'*64;$eight='8'*64;$nine='9'*64
    return [ordered]@{
        schema='rusty.morphospace.workflow.historical_validation_debt_baseline.v1'
        baseline_id='focused-byte-0001';created_at='2026-08-29T00:00:00.0000000Z';status='unresolved';project_id='focused-byte-project'
        validator=[ordered]@{environment_commit='0'*40;environment_tree='1'*40;files=@([ordered]@{path='scripts/Test-HistoricalValidationDebtPhaseRunner.ps1';sha256=$two});identity_sha256=$three}
        workspace_anchor=[ordered]@{
            planning_state=[ordered]@{path='workspace.state.json';sha256=$four;length=10;canonical_sha256=$five}
            event_ledger_prefix=[ordered]@{path='iteration-events.jsonl';sha256=$six;length=10;tail_event_id='focused-byte-tail';tail_event_sha256=$seven}
            identity_sha256=$eight
        }
        source_composition=[ordered]@{
            project_spec=[ordered]@{path='project.spec.json';sha256=$zero;revision=1}
            source_lock=[ordered]@{path='feature.lock.json';sha256=$one;revision=1}
            repository_map=[ordered]@{sha256=$two;repository_ids_sha256=$three}
            identity_sha256=$four
        }
        current_unit=[ordered]@{unit_id='focused-current';status='active';path='iteration-units/focused-current.json';raw_sha256=$five;canonical_sha256=$six}
        failure_records=@([ordered]@{
            failure_code='historical-unit-contract'
            locus=[ordered]@{kind='historical-unit';unit_id='focused-legacy';path='iteration-units/focused-legacy.json';raw_sha256=$seven;canonical_sha256=$eight}
            message_sha256=$nine;evidence_sha256=$zero;record_sha256=$one
        })
        failure_set=[ordered]@{count=1;sha256=$two}
        authorization=[ordered]@{path='receipts/historical-validation-debt/focused-byte-0001/authorization.json';schema='rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1';required=$true}
    }
}

function Write-PhaseRunnerRawCreateNew {
    param([string]$Path,[byte[]]$Bytes)
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

if (-not $SelfTest) { throw 'Test-HistoricalValidationDebtPhaseRunner.ps1 requires -SelfTest.' }
if (-not $EvidenceRoot) {
    $EvidenceRoot = Join-Path $repoRoot ('local/validation/historical-validation-debt-phase-runner-' + [guid]::NewGuid().ToString('N'))
}
$evidence = Initialize-MorphospaceHistoricalDebtEvidenceSession -EvidenceRoot $EvidenceRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('historical-validation-debt-phase-runner-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$hostPath = [Environment]::ProcessPath
if ([string]::IsNullOrWhiteSpace($hostPath) -or -not [IO.File]::Exists($hostPath)) { $hostPath=(Get-Command pwsh -ErrorAction Stop).Source }

try {
    $pass = Invoke-MorphospaceHistoricalDebtChildPhase -EvidenceRoot $evidence -Sequence 1 -PhaseId 'stream-pass' -FilePath $hostPath -WorkingDirectory $repoRoot -TimeoutSeconds 10 -Arguments @('-NoProfile','-NonInteractive','-Command',"[Console]::Out.Write('bounded-out');[Console]::Error.Write('bounded-err');exit 0")
    Assert-PhaseRunner ([string]$pass.terminal.result -ceq 'pass' -and [string]$pass.terminal.category -ceq 'completed' -and [int]$pass.terminal.exit_code -eq 0) 'Passing child did not produce a completed terminal receipt.'
    Assert-PhaseRunner (([IO.File]::ReadAllText($pass.stdout_path) -ceq 'bounded-out') -and ([IO.File]::ReadAllText($pass.stderr_path) -ceq 'bounded-err')) 'Passing child streams were not preserved exactly.'
    $passStartedAt=Test-MorphospaceStrictUtcTimestamp -Value ([string]$pass.terminal.started_at)
    $passEndedAt=Test-MorphospaceStrictUtcTimestamp -Value ([string]$pass.terminal.ended_at)
    Assert-PhaseRunner ($passStartedAt.GetType() -eq [DateTimeOffset] -and $passEndedAt.GetType() -eq [DateTimeOffset] -and $passEndedAt -ge $passStartedAt) 'Ordinary phase timestamps were not a consistent DateTimeOffset interval.'
    Assert-PhaseRunner ([long]$pass.terminal.elapsed_ms -eq [long][Math]::Ceiling(($passEndedAt-$passStartedAt).TotalMilliseconds)) 'Ordinary phase elapsed time does not match its serialized DateTimeOffset interval.'

    $fail = Invoke-MorphospaceHistoricalDebtChildPhase -EvidenceRoot $evidence -Sequence 2 -PhaseId 'code-fail' -FilePath $hostPath -WorkingDirectory $repoRoot -TimeoutSeconds 10 -Arguments @('-NoProfile','-NonInteractive','-Command','exit 7')
    Assert-PhaseRunner ([string]$fail.terminal.result -ceq 'fail' -and [string]$fail.terminal.category -ceq 'code-fail' -and [int]$fail.terminal.exit_code -eq 7) 'Nonzero child exit was not classified as code-fail.'

    $readyPath = Join-Path $scratch 'nested-child-ready.json'
    $readyId = [guid]::NewGuid().ToString('N')
    $readyPendingPath = $readyPath + ".${readyId}.pending"
    $unrelatedReadinessPath = Join-Path $scratch 'unrelated-readiness-evidence.txt'
    [byte[]]$unrelatedReadinessBytes = [Text.UTF8Encoding]::new($false).GetBytes('preserve-unrelated-readiness-evidence')
    Write-PhaseRunnerRawCreateNew -Path $unrelatedReadinessPath -Bytes $unrelatedReadinessBytes
    $nestedCommand = 'Start-Sleep -Seconds 600'
    $nestedEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($nestedCommand))
    $phaseModulePath = Join-Path $PSScriptRoot 'lib/MorphospaceHistoricalValidationDebtPhaseRunner.psm1'
    $parentCommand = @"
`$ErrorActionPreference='Stop'
Import-Module '$($phaseModulePath.Replace("'","''"))' -Force
`$child=Start-Process -FilePath '$($hostPath.Replace("'","''"))' -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand','$nestedEncoded') -PassThru -WindowStyle Hidden
`$published=`$false
try {
    `$null=Write-MorphospaceHistoricalDebtReadyHandshake -Path '$($readyPath.Replace("'","''"))' -HandshakeId '$readyId' -ParentPid `$PID -ChildPid `$child.Id -ReadyAt ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
    `$published=`$true
    while(`$true){Start-Sleep -Seconds 1}
} finally {
    if(-not `$published -and -not `$child.HasExited){`$child.Kill(`$true);`$null=`$child.WaitForExit(10000)}
}
"@
    $parentEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parentCommand))
    $timeout = Invoke-MorphospaceHistoricalDebtChildPhase -EvidenceRoot $evidence -Sequence 3 -PhaseId 'timeout-tree' -FilePath $hostPath -WorkingDirectory $repoRoot -TimeoutSeconds 2 -ReadyHandshakePath $readyPath -ReadyHandshakeId $readyId -StartupTimeoutSeconds 10 -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',$parentEncoded)
    Assert-PhaseRunner ([string]$timeout.terminal.category -ceq 'timeout' -and $timeout.terminal.timed_out -eq $true -and $timeout.terminal.child_tree_cleanup.attempted -eq $true -and $timeout.terminal.child_tree_cleanup.succeeded -eq $true) 'Timed-out child did not report successful child-tree cleanup.'
    Assert-PhaseRunner ($null -ne $timeout.readiness -and [string]$timeout.readiness.record.handshake_id -ceq $readyId) 'Nested-child ready handshake was not retained by the timeout phase.'
    $parentPid = [int]$timeout.readiness.record.parent_pid
    $nestedPid = [int]$timeout.readiness.record.child_pid
    $readyAt = Test-MorphospaceStrictUtcTimestamp -Value ([string]$timeout.readiness.record.ready_at)
    $phaseStartedAt = Test-MorphospaceStrictUtcTimestamp -Value ([string]$timeout.terminal.started_at)
    Assert-PhaseRunner ($phaseStartedAt -ge $readyAt) 'Timeout phase began before the nested-child ready handshake.'
    Start-Sleep -Milliseconds 250
    Assert-PhaseRunner ($null -eq (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) 'Parent child survived timeout tree cleanup.'
    Assert-PhaseRunner ($null -eq (Get-Process -Id $nestedPid -ErrorAction SilentlyContinue)) 'Nested child survived timeout tree cleanup.'
    Assert-PhaseRunner (-not [IO.File]::Exists($readyPath) -and -not [IO.File]::Exists($readyPendingPath)) 'Owned ready-handshake final or pending artifact survived timeout cleanup.'
    Assert-PhaseRunner ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($unrelatedReadinessBytes,[IO.File]::ReadAllBytes($unrelatedReadinessPath))) 'Ready-handshake cleanup altered an unrelated artifact.'

    $collisionPath = Join-Path $evidence '004-collision.stdout.log'
    [byte[]]$collisionBytes = [Text.UTF8Encoding]::new($false).GetBytes('preserve-collision')
    $collisionStream = [IO.FileStream]::new($collisionPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $collisionStream.Write($collisionBytes,0,$collisionBytes.Length);$collisionStream.Flush($true) } finally { $collisionStream.Dispose() }
    $collisionRejected=$false
    try {
        $null=Invoke-MorphospaceHistoricalDebtChildPhase -EvidenceRoot $evidence -Sequence 4 -PhaseId 'collision' -FilePath $hostPath -WorkingDirectory $repoRoot -TimeoutSeconds 10 -Arguments @('-NoProfile','-NonInteractive','-Command','exit 0')
    } catch {
        $collisionRejected=$_.Exception.Data.Contains('morphospace_phase_category') -and [string]$_.Exception.Data['morphospace_phase_category'] -ceq 'evidence-collision'
    }
    Assert-PhaseRunner $collisionRejected 'Create-new stream collision was not rejected.'
    Assert-PhaseRunner ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($collisionBytes,[IO.File]::ReadAllBytes($collisionPath))) 'Create-new collision altered existing bytes.'

    $missing = Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 5 -PhaseId 'cache-miss' -OwnerPath $PSCommandPath -Action {
        Install-MorphospaceHistoricalDebtBaselineEvidence -EvidencePath (Join-Path $scratch 'missing.json') -WorkspaceRoot $scratch -RepoRoot $repoRoot -RepositoryMapPath (Join-Path $scratch 'missing-map.json') -ExpectedEvidenceSha256 ('0'*64)
    }
    Assert-PhaseRunner ([string]$missing.terminal.category -ceq 'cache-miss' -and [string]$missing.terminal.result -ceq 'fail') 'Missing reusable evidence was not classified as cache-miss.'

    $invalidEvidence = Join-Path $scratch 'invalid-evidence.json'
    [IO.File]::WriteAllText($invalidEvidence,'{}',[Text.UTF8Encoding]::new($false))
    $invalidEvidenceSha=(Get-FileHash -LiteralPath $invalidEvidence -Algorithm SHA256).Hash.ToLowerInvariant()
    $rejected = Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 6 -PhaseId 'reuse-rejection' -OwnerPath $PSCommandPath -Action {
        Install-MorphospaceHistoricalDebtBaselineEvidence -EvidencePath $invalidEvidence -WorkspaceRoot $scratch -RepoRoot $repoRoot -RepositoryMapPath (Join-Path $scratch 'missing-map.json') -ExpectedEvidenceSha256 $invalidEvidenceSha
    }
    Assert-PhaseRunner ([string]$rejected.terminal.category -ceq 'evidence-reuse-rejection' -and [string]$rejected.terminal.result -ceq 'fail') 'Malformed reusable evidence was not classified as evidence-reuse-rejection.'

    $cleanupDamage = Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 7 -PhaseId 'cleanup-damage' -OwnerPath $PSCommandPath -FailureCategory 'fixture-cleanup' -Action {
        throw 'Injected fixture cleanup failure.'
    }
    Assert-PhaseRunner ([string]$cleanupDamage.terminal.category -ceq 'fixture-cleanup' -and [string]$cleanupDamage.terminal.result -ceq 'fail') 'Fixture cleanup failure did not retain its typed category.'

    $baselineFixture=New-PhaseRunnerBaselineFixture
    $canonicalPath=Join-Path $scratch 'canonical-baseline.json'
    $canonicalPhase=Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 8 -PhaseId 'canonical-lf' -OwnerPath $PSCommandPath -SuccessCategory 'evidence-reused' -Action {
        $written=Write-MorphospaceHistoricalDebtCanonicalBaselineEvidence -EvidencePath $canonicalPath -Baseline $baselineFixture
        $read=Read-MorphospaceHistoricalDebtCanonicalBaselineEvidence -EvidencePath $canonicalPath -ExpectedSha256 ([string]$written.sha256)
        return [pscustomobject]@{written=$written;read=$read}
    }
    Assert-PhaseRunner ([string]$canonicalPhase.terminal.result -ceq 'pass' -and [string]$canonicalPhase.terminal.category -ceq 'evidence-reused') 'Canonical UTF-8 LF baseline evidence was not accepted.'
    [byte[]]$canonicalBytes=[IO.File]::ReadAllBytes($canonicalPath)
    Assert-PhaseRunner ($canonicalBytes.Length -gt 4 -and $canonicalBytes[-1] -eq 10 -and $canonicalBytes[-2] -ne 13 -and -not($canonicalBytes[0]-eq239-and$canonicalBytes[1]-eq187-and$canonicalBytes[2]-eq191)) 'Canonical baseline evidence is not UTF-8 without BOM with a single LF terminator.'
    $canonicalSha=(Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $collisionPhase=Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 9 -PhaseId 'baseline-collision' -OwnerPath $PSCommandPath -Action {
        Write-MorphospaceHistoricalDebtCanonicalBaselineEvidence -EvidencePath $canonicalPath -Baseline $baselineFixture
    }
    Assert-PhaseRunner ([string]$collisionPhase.terminal.result -ceq 'fail' -and [string]$collisionPhase.terminal.category -ceq 'evidence-collision') 'Canonical baseline evidence CreateNew collision was not rejected.'
    Assert-PhaseRunner ((Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $canonicalSha) 'Canonical baseline evidence collision altered existing bytes.'

    [byte[]]$crlfBytes=[byte[]]::new($canonicalBytes.Length+1);[Array]::Copy($canonicalBytes,0,$crlfBytes,0,$canonicalBytes.Length-1);$crlfBytes[$crlfBytes.Length-2]=13;$crlfBytes[$crlfBytes.Length-1]=10
    [byte[]]$bomBytes=[byte[]]::new($canonicalBytes.Length+3);$bomBytes[0]=239;$bomBytes[1]=187;$bomBytes[2]=191;[Array]::Copy($canonicalBytes,0,$bomBytes,3,$canonicalBytes.Length)
    [byte[]]$trailingBytes=[byte[]]::new($canonicalBytes.Length+1);[Array]::Copy($canonicalBytes,0,$trailingBytes,0,$canonicalBytes.Length);$trailingBytes[-1]=32
    [byte[]]$baselineFixtureBytes=ConvertTo-MorphospaceProtocolJsonBytes -Value $baselineFixture
    $contentDrift=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineFixtureBytes -Context 'focused baseline content-drift fixture'
    $contentDrift.project_id='focused-byte-drift'
    [byte[]]$contentDriftBytes=ConvertTo-MorphospaceProtocolJsonBytes -Value $contentDrift
    $damageCases=@(
        [pscustomobject]@{sequence=10;id='crlf-rejection';bytes=$crlfBytes;expected=(Get-MorphospaceSha256Bytes -Bytes $crlfBytes)},
        [pscustomobject]@{sequence=11;id='bom-rejection';bytes=$bomBytes;expected=(Get-MorphospaceSha256Bytes -Bytes $bomBytes)},
        [pscustomobject]@{sequence=12;id='trailing-rejection';bytes=$trailingBytes;expected=(Get-MorphospaceSha256Bytes -Bytes $trailingBytes)},
        [pscustomobject]@{sequence=13;id='content-drift';bytes=$contentDriftBytes;expected=$canonicalSha}
    )
    foreach($damage in $damageCases){
        $damagePath=Join-Path $scratch ($damage.id+'.json');Write-PhaseRunnerRawCreateNew -Path $damagePath -Bytes $damage.bytes
        $before=[IO.File]::ReadAllBytes($damagePath)
        $damagePhase=Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence $damage.sequence -PhaseId $damage.id -OwnerPath $PSCommandPath -Action {
            Read-MorphospaceHistoricalDebtCanonicalBaselineEvidence -EvidencePath $damagePath -ExpectedSha256 ([string]$damage.expected)
        }
        Assert-PhaseRunner ([string]$damagePhase.terminal.result -ceq 'fail' -and [string]$damagePhase.terminal.category -ceq 'evidence-reuse-rejection') "Damaged baseline evidence was not rejected: $($damage.id)"
        Assert-PhaseRunner ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($before,[IO.File]::ReadAllBytes($damagePath))) "Damaged baseline evidence bytes changed during rejection: $($damage.id)"
    }

    $handshakeWindowStart=[DateTimeOffset]::UtcNow
    $handshakeWindowEnd=$handshakeWindowStart.AddSeconds(10)
    $missingHandshakeId=[guid]::NewGuid().ToString('N')
    $missingHandshakePath=Join-Path $scratch 'handshake-absent.json'
    $missingHandshake=Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 14 -PhaseId 'handshake-absent' -OwnerPath $PSCommandPath -Action {
        Read-MorphospaceHistoricalDebtReadyHandshake -Path $missingHandshakePath -ExpectedHandshakeId $missingHandshakeId -ExpectedParentPid $PID -StartupStartedAt $handshakeWindowStart -StartupDeadline $handshakeWindowEnd
    }
    Assert-PhaseRunner ([string]$missingHandshake.terminal.result -ceq 'fail' -and [string]$missingHandshake.terminal.category -ceq 'handshake-missing') 'Absent child-ready handshake was not rejected.'

    $malformedHandshakePath=Join-Path $scratch 'handshake-malformed.json'
    [byte[]]$malformedHandshakeBytes=[Text.UTF8Encoding]::new($false).GetBytes("{}`n")
    Write-PhaseRunnerRawCreateNew -Path $malformedHandshakePath -Bytes $malformedHandshakeBytes
    $malformedHandshake=Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 15 -PhaseId 'handshake-malformed' -OwnerPath $PSCommandPath -Action {
        Read-MorphospaceHistoricalDebtReadyHandshake -Path $malformedHandshakePath -ExpectedHandshakeId ([guid]::NewGuid().ToString('N')) -ExpectedParentPid $PID -StartupStartedAt $handshakeWindowStart -StartupDeadline $handshakeWindowEnd
    }
    Assert-PhaseRunner ([string]$malformedHandshake.terminal.result -ceq 'fail' -and [string]$malformedHandshake.terminal.category -ceq 'handshake-invalid') 'Malformed child-ready handshake was not rejected.'
    Assert-PhaseRunner ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($malformedHandshakeBytes,[IO.File]::ReadAllBytes($malformedHandshakePath))) 'Malformed child-ready handshake bytes changed during rejection.'

    $staleHandshakePath=Join-Path $scratch 'handshake-stale.json'
    $staleHandshakeId=[guid]::NewGuid().ToString('N')
    $null=Write-MorphospaceHistoricalDebtReadyHandshake -Path $staleHandshakePath -HandshakeId $staleHandshakeId -ParentPid $PID -ChildPid ([int]::MaxValue) -ReadyAt $handshakeWindowStart.AddSeconds(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    $staleHandshakeBefore=[IO.File]::ReadAllBytes($staleHandshakePath)
    $staleHandshake=Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 16 -PhaseId 'handshake-stale' -OwnerPath $PSCommandPath -Action {
        Read-MorphospaceHistoricalDebtReadyHandshake -Path $staleHandshakePath -ExpectedHandshakeId $staleHandshakeId -ExpectedParentPid $PID -StartupStartedAt $handshakeWindowStart -StartupDeadline $handshakeWindowEnd
    }
    Assert-PhaseRunner ([string]$staleHandshake.terminal.result -ceq 'fail' -and [string]$staleHandshake.terminal.category -ceq 'handshake-stale') 'Stale child-ready handshake was not rejected.'
    Assert-PhaseRunner ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($staleHandshakeBefore,[IO.File]::ReadAllBytes($staleHandshakePath))) 'Stale child-ready handshake bytes changed during rejection.'

    $wrongPidHandshakePath=Join-Path $scratch 'handshake-wrong-pid.json'
    $wrongPidHandshakeId=[guid]::NewGuid().ToString('N')
    $null=Write-MorphospaceHistoricalDebtReadyHandshake -Path $wrongPidHandshakePath -HandshakeId $wrongPidHandshakeId -ParentPid $PID -ChildPid ([int]::MaxValue) -ReadyAt ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
    $wrongPidHandshakeBefore=[IO.File]::ReadAllBytes($wrongPidHandshakePath)
    $wrongPidHandshake=Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 17 -PhaseId 'handshake-wrong-pid' -OwnerPath $PSCommandPath -Action {
        Read-MorphospaceHistoricalDebtReadyHandshake -Path $wrongPidHandshakePath -ExpectedHandshakeId $wrongPidHandshakeId -ExpectedParentPid $PID -StartupStartedAt $handshakeWindowStart -StartupDeadline $handshakeWindowEnd
    }
    Assert-PhaseRunner ([string]$wrongPidHandshake.terminal.result -ceq 'fail' -and [string]$wrongPidHandshake.terminal.category -ceq 'handshake-invalid') 'Wrong-PID child-ready handshake was not rejected.'
    Assert-PhaseRunner ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($wrongPidHandshakeBefore,[IO.File]::ReadAllBytes($wrongPidHandshakePath))) 'Wrong-PID child-ready handshake bytes changed during rejection.'

    $collisionHandshakePath=Join-Path $scratch 'handshake-collision.json'
    $collisionHandshakeId=[guid]::NewGuid().ToString('N')
    $null=Write-MorphospaceHistoricalDebtReadyHandshake -Path $collisionHandshakePath -HandshakeId $collisionHandshakeId -ParentPid $PID -ChildPid ([int]::MaxValue) -ReadyAt ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
    $collisionHandshakeBefore=[IO.File]::ReadAllBytes($collisionHandshakePath)
    $collisionHandshake=Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 18 -PhaseId 'handshake-collision' -OwnerPath $PSCommandPath -Action {
        Write-MorphospaceHistoricalDebtReadyHandshake -Path $collisionHandshakePath -HandshakeId $collisionHandshakeId -ParentPid $PID -ChildPid ([int]::MaxValue) -ReadyAt ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
    }
    Assert-PhaseRunner ([string]$collisionHandshake.terminal.result -ceq 'fail' -and [string]$collisionHandshake.terminal.category -ceq 'evidence-collision') 'Child-ready handshake CreateNew collision was not rejected.'
    Assert-PhaseRunner ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($collisionHandshakeBefore,[IO.File]::ReadAllBytes($collisionHandshakePath))) 'Child-ready handshake collision altered existing bytes.'
    Assert-PhaseRunner (-not [IO.File]::Exists($collisionHandshakePath + ".${collisionHandshakeId}.pending")) 'Final-path collision left its owned ready-handshake pending artifact behind.'

    $abandonedFinalPath=Join-Path $scratch 'handshake-abandoned-final.json'
    $abandonedHandshakeId=[guid]::NewGuid().ToString('N')
    $abandonedPendingPath=$abandonedFinalPath + ".${abandonedHandshakeId}.pending"
    [byte[]]$abandonedPendingBytes=[Text.UTF8Encoding]::new($false).GetBytes('abandoned-ready-handshake-pending')
    Write-PhaseRunnerRawCreateNew -Path $abandonedPendingPath -Bytes $abandonedPendingBytes
    $abandonedPending=Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 19 -PhaseId 'handshake-abandoned-pending' -OwnerPath $PSCommandPath -Action {
        Read-MorphospaceHistoricalDebtReadyHandshake -Path $abandonedFinalPath -ExpectedHandshakeId $abandonedHandshakeId -ExpectedParentPid $PID -StartupStartedAt $handshakeWindowStart -StartupDeadline $handshakeWindowEnd
    }
    Assert-PhaseRunner ([string]$abandonedPending.terminal.result -ceq 'fail' -and [string]$abandonedPending.terminal.category -ceq 'handshake-missing') 'An abandoned pending handshake was admitted without its final publication.'
    Assert-PhaseRunner (-not [IO.File]::Exists($abandonedFinalPath) -and [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($abandonedPendingBytes,[IO.File]::ReadAllBytes($abandonedPendingPath))) 'The ready-handshake reader parsed or altered an abandoned pending artifact.'

    $partialFinalPath=Join-Path $scratch 'handshake-partial-producer.json'
    $partialHandshakeId=[guid]::NewGuid().ToString('N')
    $partialPendingPath=$partialFinalPath + ".${partialHandshakeId}.pending"
    $partialBytesBase64=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes('{"schema":'))
    $partialProducerCommand=@"
`$bytes=[Convert]::FromBase64String('$partialBytesBase64')
`$stream=[IO.FileStream]::new('$($partialPendingPath.Replace("'","''"))',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
try{`$stream.Write(`$bytes,0,`$bytes.Length);`$stream.Flush(`$true)}finally{`$stream.Dispose()}
exit 0
"@
    $partialProducer=Invoke-MorphospaceHistoricalDebtChildPhase -EvidenceRoot $evidence -Sequence 20 -PhaseId 'handshake-partial-producer-exit' -FilePath $hostPath -WorkingDirectory $repoRoot -TimeoutSeconds 2 -ReadyHandshakePath $partialFinalPath -ReadyHandshakeId $partialHandshakeId -StartupTimeoutSeconds 5 -Arguments @('-NoProfile','-NonInteractive','-Command',$partialProducerCommand)
    Assert-PhaseRunner ([string]$partialProducer.terminal.result -ceq 'fail' -and [string]$partialProducer.terminal.category -ceq 'handshake-missing' -and $partialProducer.terminal.timed_out -eq $false -and [int]$partialProducer.terminal.exit_code -eq 0) 'Producer exit before atomic ready publication did not produce a typed startup failure.'
    Assert-PhaseRunner ($null -eq $partialProducer.readiness -and -not [IO.File]::Exists($partialFinalPath) -and -not [IO.File]::Exists($partialPendingPath)) 'A partial pending handshake was admitted or survived owned-artifact cleanup.'

    $expiryFinalPath=Join-Path $scratch 'handshake-startup-expiry.json'
    $expiryHandshakeId=[guid]::NewGuid().ToString('N')
    $expiryPendingPath=$expiryFinalPath + ".${expiryHandshakeId}.pending"
    $startupExpiry=Invoke-MorphospaceHistoricalDebtChildPhase -EvidenceRoot $evidence -Sequence 21 -PhaseId 'handshake-startup-expiry' -FilePath $hostPath -WorkingDirectory $repoRoot -TimeoutSeconds 2 -ReadyHandshakePath $expiryFinalPath -ReadyHandshakeId $expiryHandshakeId -StartupTimeoutSeconds 1 -Arguments @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30')
    Assert-PhaseRunner ([string]$startupExpiry.terminal.result -ceq 'fail' -and [string]$startupExpiry.terminal.category -ceq 'handshake-missing' -and $startupExpiry.terminal.timed_out -eq $true -and $startupExpiry.terminal.child_tree_cleanup.attempted -eq $true -and $startupExpiry.terminal.child_tree_cleanup.succeeded -eq $true) 'Ready-handshake startup expiry did not produce a typed bounded failure with tree cleanup.'
    Assert-PhaseRunner ($null -eq $startupExpiry.readiness -and -not [IO.File]::Exists($expiryFinalPath) -and -not [IO.File]::Exists($expiryPendingPath)) 'Startup-expiry ready-handshake artifacts survived cleanup.'
    $startupReceipt=Get-Content -Raw -LiteralPath (Join-Path $evidence ([string]$startupExpiry.terminal.start_receipt.path))|ConvertFrom-Json -DateKind String -ErrorAction Stop
    $startupFailureStartedAt=Test-MorphospaceStrictUtcTimestamp -Value ([string]$startupExpiry.terminal.started_at)
    $startupFailureEndedAt=Test-MorphospaceStrictUtcTimestamp -Value ([string]$startupExpiry.terminal.ended_at)
    Assert-PhaseRunner ($startupFailureStartedAt.GetType() -eq [DateTimeOffset] -and $startupFailureEndedAt.GetType() -eq [DateTimeOffset] -and $startupFailureEndedAt -ge $startupFailureStartedAt) 'Startup-failure timestamps were not a consistent DateTimeOffset interval.'
    Assert-PhaseRunner ([string]$startupReceipt.started_at -ceq [string]$startupExpiry.terminal.started_at -and [int]$startupReceipt.timeout_seconds -eq 1) 'Startup-failure terminal did not retain the supplied bounded startup timestamp and timeout.'
    Assert-PhaseRunner ([long]$startupExpiry.terminal.elapsed_ms -eq [long][Math]::Ceiling(($startupFailureEndedAt-$startupFailureStartedAt).TotalMilliseconds)) 'Startup-failure elapsed time does not match its serialized DateTimeOffset interval.'
    Assert-PhaseRunner ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($unrelatedReadinessBytes,[IO.File]::ReadAllBytes($unrelatedReadinessPath))) 'Ready-handshake damage cleanup altered an unrelated artifact.'

    $schemaPath = Join-Path $repoRoot 'schemas/historical-validation-debt-phase-receipt-v1.schema.json'
    foreach ($receipt in @(Get-ChildItem -LiteralPath $evidence -Filter '*.json' -File)) {
        Assert-PhaseRunner (Test-Json -Json (Get-Content -Raw -LiteralPath $receipt.FullName) -SchemaFile $schemaPath -ErrorAction Stop) "Phase receipt failed its closed schema: $($receipt.Name)"
    }
} finally {
    $cleanup = Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $evidence -Sequence 999 -PhaseId 'fixture-cleanup' -OwnerPath $PSCommandPath -SuccessCategory 'fixture-cleanup' -FailureCategory 'fixture-cleanup' -Action {
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) }
        if ([IO.Directory]::Exists($scratch)) { throw 'Focused phase-runner scratch fixture still exists after cleanup.' }
        return [pscustomobject]@{cleanup='complete';path=$scratch}
    }
    if ([string]$cleanup.terminal.result -cne 'pass') { throw 'Historical validation-debt phase-runner fixture cleanup failed.' }
}

Write-Output ("Historical validation-debt phase-runner tests passed: evidence_root={0}; ready_handshake=true; parent_child_timeout_cleanup=true; handshake_damage=true; collision_preserved=true; cache_miss=true; reuse_rejection=true." -f $evidence)
